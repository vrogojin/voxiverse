# VOXIVERSE — Engine Build (Godot 4.4 + godot_voxel, native + Web)

This document describes the reproducible, Docker-based toolchain that builds a
custom **Godot 4.4.1** engine with the **Zylann `godot_voxel`** C++ module and,
critically, the **Web (Emscripten) export templates** that include the module —
so the game can be exported to a browser build that uses `godot_voxel`.

> **godot_voxel WEB template build status: SUCCEEDED.** The Web (Emscripten)
> export templates were compiled **with** the `godot_voxel` module
> (`module_in_web=yes`). A real headless Web export of the game produced a
> **44 MB threaded `index.wasm`**. The DESIGN §2 GDScript fallback is NOT
> needed for web. See the Result section at the bottom.

---

## 1. Pinned versions (and why)

| Component | Pinned value | Why exactly this |
|---|---|---|
| **Godot** | `4.4.1-stable` (git tag) | godot_voxel v1.4.1 targets Godot 4.4.1.stable. 4.4.1 is the patch release of the 4.4 line named in DESIGN.md §2. |
| **godot_voxel** | `v1.4.1` (git tag, Zylann/godot_voxel) | The release paired with Godot 4.4.1. Built as a **module** (compiled into the engine), not GDExtension. |
| **Emscripten (emsdk)** | `3.1.64` | **The single most important pin.** Godot 4.4.1 CI (`.github/workflows/web_builds.yml`) builds its web templates with `EM_VERSION=3.1.64`. The engine and its web template must be built with the *same* emscripten version; a mismatch is the #1 cause of web build/runtime failure. |
| Renderer target | **GL Compatibility** | The game project uses the Compatibility renderer (best web support). This is a project/export setting; the templates support it. |
| Threads | **enabled** (Godot 4.4 web default `threads=yes`) | `godot_voxel` is heavily multithreaded. Requires `SharedArrayBuffer`, which needs the COOP/COEP isolation headers served by the runtime container (Stream C). |

The pins live in one place: [`docker/engine/versions.env`](../docker/engine/versions.env).

## 2. What gets built

```
docker/engine/bin/godot.linuxbsd.editor.x86_64   # native headless EDITOR (with godot_voxel)
docker/engine/templates/web_release.zip          # Web export template, threaded (production/LTO)
docker/engine/templates/web_debug.zip            # Web export template, threaded (debug)
docker/engine/templates/BUILD-INFO.txt           # provenance: refs, emcc, module_in_web=yes|no
```

- The **Linux headless editor** includes `godot_voxel` and is what runs
  `--headless --export-release "Web"`. Stream B can also use it to open/test the
  project headlessly.
- The **web templates** are renamed from SCons' output
  (`godot.web.template_release.wasm32.zip`) to the names Godot's exporter expects
  in `export_templates/<version>/`: `web_release.zip` / `web_debug.zip` (these are
  the *threaded* variant names in Godot 4.4).

## 3. How to build

Prerequisite: Docker only (24 cores / ~34 GiB free is plenty; ~2–3 GiB disk for the image, more for caches).

```bash
# Full build: toolchain image + native editor + web templates (with godot_voxel)
./scripts/build.sh

# Force a fresh toolchain image first
./scripts/build.sh --rebuild

# Only one target
SKIP_WEB=1   ./scripts/build.sh     # native editor only
SKIP_LINUX=1 ./scripts/build.sh     # web templates only

# Deliberately build STOCK web templates (no module) — the DESIGN §2 fallback path
FORCE_STOCK_WEB=1 ./scripts/build.sh
```

Everything runs inside the container as your host UID, so all artifacts stay
owned by you (no root-owned files).

### Fallback behaviour (DESIGN.md §2)

`build-engine.sh` first tries to compile the web templates **with** `godot_voxel`.
If that compile/link fails, it automatically:
1. logs the failure,
2. moves `modules/voxel` aside,
3. rebuilds **stock** web templates (no module), and
4. records `module_in_web=no` in `BUILD-INFO.txt`.

In that case the game must use its **pure-GDScript fallback mesher** on web while
still using `godot_voxel` natively. The native Linux editor always keeps the
module regardless of the web outcome.

## 4. Exporting the game to Web

Once Stream B's project exists at `godot/` with an export preset named **`Web`**:

```bash
./scripts/export-web.sh
```

This runs the custom editor headless inside the toolchain container, installs the
custom templates into `export_templates/4.4.1.stable/`, imports the project, and
writes `build/web/{index.html,index.wasm,index.pck,index.js,...}`.

If the project or the `Web` preset does not exist yet, the script prints a clear
message and exits cleanly (it is correct and ready to re-run).

**Equivalent raw command** (what the script runs inside the container):

```bash
godot --headless --path /project --import
godot --headless --path /project --export-release "Web" /out/index.html
```

## 5. Caching & timings

Heavy state is cached under `docker/engine/cache/` (git-ignored) and reused:

| Cache | Path | Purpose |
|---|---|---|
| Godot + module source | `docker/engine/cache/godot` | shallow git checkouts, pinned to tags |
| SCons object cache | `docker/engine/cache/scons-cache` | incremental relinks / rebuilds |
| Emscripten cache | `docker/engine/cache/emcache` | compiled system libs / ports |

**Timings (24 cores):**

| Step | Cold | Warm (cached) |
|---|---|---|
| Toolchain image build | ~15–40 s | skipped |
| Native linuxbsd editor | ~8–15 min | seconds–minutes |
| Web template_release (LTO) | ~15–25 min | minutes |
| Web template_debug | ~5–10 min | minutes |
| **Total (cold)** | **~30–50 min** | **a few minutes** |

_(Actual measured total is recorded in the Result section.)_

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Web export at runtime shows a blank page / `SharedArrayBuffer is not defined` | The server is not sending `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`. That is the runtime container's job (Stream C). |
| Export fails: `No export template found for version 4.4.1.stable` | Templates not installed / version-string mismatch. `export-web.sh` installs them into `export_templates/4.4.1.stable/`; confirm the editor reports version `4.4.1.stable` (`godot --version`). |
| Web build fails with emscripten link errors | Almost always an **emsdk version mismatch**. Confirm the image is emsdk `3.1.64` (`docker run --rm voxiverse/godot-build:4.4 bash -c 'emcc --version'`). Do not bump emsdk without matching Godot's pin. |
| `scons: *** [bin/...] Error` in the voxel module on web | The DESIGN §2 fallback kicks in automatically → stock web template + GDScript mesher. See `BUILD-INFO.txt` `module_in_web=no`. |
| `dubious ownership` git error | Handled: the build marks the tree safe (`safe.directory '*'`). If it recurs, delete `docker/engine/cache/godot` and rebuild. |
| Editor build fails on missing X11/GL headers | The toolchain image installs them; rebuild the image with `./scripts/build.sh --rebuild`. |
| Rebuild from absolute scratch | `rm -rf docker/engine/cache docker/engine/templates/*.zip docker/engine/bin/* && ./scripts/build.sh --rebuild` |

## 7. Files

| File | Role |
|---|---|
| `docker/engine/Dockerfile` | toolchain image: emsdk 3.1.64 + Linux/web build deps |
| `docker/engine/build-engine.sh` | in-container: clone + compile both targets, fallback logic, manifest |
| `docker/engine/versions.env` | single source of truth for all version pins |
| `scripts/build.sh` | host: build image + run compile, deposit artifacts |
| `scripts/export-web.sh` | host: headless Web export of `godot/` → `build/web/` |

---

## Result (from the actual build)

Build performed 2026-07-02 on a 24-core host, cold (no caches).

- **godot_voxel WEB template build succeeded: YES.** The web templates were
  compiled *with* the module and the game exported cleanly against them.
- **module_in_web: `yes`** (from `docker/engine/templates/BUILD-INFO.txt`).
- **Resolved commits:**
  - Godot `4.4.1-stable` → `49a5bc7b616bd04689a2c89e89bda41f50241464`
  - godot_voxel `v1.4.1` → `903d1fb3ee6e06df4c3bf52bb9e035f3a83a245c`
  - emcc `3.1.64`
- **Measured cold build time: ≈ 24 min total** on 24 cores
  (native linuxbsd editor ≈ 14 min; both web templates ≈ 10 min). Toolchain
  image build ≈ 15 s. Warm rebuilds are minutes.
- **Artifacts present:**
  - `docker/engine/bin/godot.linuxbsd.editor.x86_64` — 149 MB (with godot_voxel)
  - `docker/engine/templates/web_release.zip` — 10 MB
  - `docker/engine/templates/web_debug.zip` — 11 MB
  - `docker/engine/templates/BUILD-INFO.txt`
- **Verified Web export** (`./scripts/export-web.sh` → `build/web/`), ~9 s:
  - `index.html` 5.3 KB, `index.js` 365 KB, `index.pck` 45 KB,
    **`index.wasm` 44 MB** (module-inclusive; a stock template would be far
    smaller), plus audio worklets + icons.
  - `index.wasm` carries the WASM magic (`\0asm`); `index.js` contains the
    threaded-runtime markers (`SharedArrayBuffer`, `pthread`,
    `crossOriginIsolated`) → this is the **threaded** template and therefore
    **requires the COOP/COEP isolation headers** served by the runtime
    container (Stream C).

### Exact command to export the game to Web

```bash
./scripts/export-web.sh          # project at godot/ , preset "Web" -> build/web/
```

(equivalently, inside the toolchain image with the custom templates installed:
`godot --headless --path /project --import && godot --headless --path /project --export-release "Web" /out/index.html`)
