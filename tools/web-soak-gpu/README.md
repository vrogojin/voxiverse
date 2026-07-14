# web-soak-gpu — Tier B cloud-GPU web-soak harness (SPIKE)

Measures the **real threaded WASM/WebGL2 web build** of VOXIVERSE the way a player's
desktop browser runs it: worst-frame time, hitches, streaming backlog, heap growth,
and a real-GPU renderer check — automated with headful Chromium + Playwright.

This is the **Tier B** gate from the headless-GPU testing research. Tier A
(`Xvfb + llvmpipe` native) catches *software*-rendered regressions cheaply; Tier B
runs the **actual web export on a real GPU** and is the only tier that reproduces the
WASM-heap / worker-timing / GPU numbers that only exist on live web.

> **Standalone.** Everything here is new files under `tools/web-soak-gpu/`. It reads
> `build/web/` (the export) and mirrors the deploy COOP/COEP headers; it does **not**
> touch game source, the export, or the deploy. It provisions no cloud resource.

---

## What it does

1. **Serves `build/web/`** (`server.mjs`) with the production
   `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`
   on **every** response — the source of truth is `lib/coop-headers.mjs`, kept in
   lockstep with `docker/server/voxiverse.conf.template`. Without both headers
   `crossOriginIsolated` is false and the threaded engine refuses to boot (the #1 web
   gotcha). You can also point the harness at the live origin with `--url`.
2. **Launches Chromium** (`soak.mjs`) with the documented GPU flags, then, in order:
   - asserts `crossOriginIsolated === true`;
   - reads `UNMASKED_RENDERER_WEBGL` and **asserts a real GPU** — SwiftShader / llvmpipe
     is a **hard fail** (the load-bearing gate; Chrome 137+ fails closed, so software
     here means the GPU path is broken, not "good enough");
   - waits for engine boot (first `[PERF]` console line);
   - **auto-walks the planet** via synthetic keyboard input;
   - scrapes the in-game `[PERF]` / `[PERF-HITCH]` console lines into a time series
     (`lib/perf-parse.mjs`);
   - samples the heap (`performance.measureUserAgentSpecificMemory()`, with a
     `performance.memory` fallback — see *Heap measurement* below);
   - captures screenshots (best-effort — see *Screenshots*);
   - asserts thresholds (worst-frame ≤ 18 ms floor for ≥ 99 % of frames, hitch count,
     heap ceiling, no-SwiftShader), diffs a stored baseline, and **exits 0 / 1**;
   - writes `results/latest.json` (the sign-off artefact).

The `[PERF]` series + heap are the **hard** signal. Screenshots are best-effort.

---

## Install

```bash
cd tools/web-soak-gpu
npm install
npx playwright install chromium        # ~180 MB browser download
# On a fresh Linux box you also need Chromium's system libs:
npx playwright install-deps chromium   # needs root; or apt-get install the .debs
```

`build/web/` must exist first — produce it with `scripts/export-web.sh` (from repo
root). If it is absent the harness exits 2 and tells you.

---

## Run it

### Local CPU-fallback smoke (no GPU box) — proves the plumbing only

```bash
./smoke.sh          # runs all four checks below
# or individually:
node soak.mjs --cpu-fallback                        # GPU-gate self-test (exit 0)
node soak.mjs --cpu-fallback --require-gpu          # strict gate on SwiftShader (exit 1, expected)
node soak.mjs --cpu-fallback --allow-software --duration 20   # full software smoke (exit 0)
```

CPU-fallback forces the SwiftShader software rasteriser. It is **not** a perf
measurement — it exists to prove the harness end-to-end on a machine with no GPU, and
to self-test that the real-GPU gate rejects software.

### The real test — GPU mode on a T4 box

```bash
xvfb-run -a node soak.mjs --gpu --duration 900
```

**Headful under `xvfb-run` — NOT `--headless`.** See *Why headful* below.

---

## Chrome flags (the hard-won 2026 recipe)

Source of truth: `lib/chrome-flags.mjs`.

### GPU mode (the real test)

```
--use-gl=angle --use-angle=vulkan --enable-features=Vulkan
--disable-gpu-blocklist --ignore-gpu-blocklist
--no-sandbox --disable-dev-shm-usage --enable-precise-memory-info
```

launched **headful** (`headless:false`) under `xvfb-run -a`.

**Traps this recipe avoids (do not "simplify"):**

- **Chrome 137+ no longer auto-falls-back to SwiftShader** — it *fails closed*. No
  silent software path. So either the real GPU works or WebGL is unavailable; the
  `UNMASKED_RENDERER` gate is what makes that visible.
- **`--headless=new --use-angle=vulkan --disable-vulkan-surface` DISABLES canvas
  drawing** — wrong for us, we render to a canvas. Never add `--disable-vulkan-surface`,
  and don't use `--headless` for the GPU run.
- **The recipe that works** on a Linux GPU box is headful Chrome under `xvfb-run`, with
  ANGLE-over-Vulkan. Playwright launches headful when `headless:false`; you wrap the
  whole `node soak.mjs --gpu` invocation in `xvfb-run -a` so the headful browser has a
  virtual X display.

### CPU-fallback mode (local smoke only)

```
--use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader
--no-sandbox --disable-dev-shm-usage --enable-precise-memory-info
```

`--enable-unsafe-swiftshader` is required on Chrome 137+ to opt software WebGL back on.

---

## Why headful (not `--headless`)

The threaded WASM export needs a real GL context drawing to a canvas. The old
`chrome-headless-shell` (what Playwright's `headless:true` launches) cannot drive
ANGLE-over-Vulkan against a real GPU and lacks the site isolation the heap API needs
(below). Headful Chrome under a virtual X server (`xvfb-run`) is a real browser with a
real window on a real GPU — the faithful reproduction of a player's session.

---

## Heap measurement (and its one environment gotcha)

- **Primary:** `performance.measureUserAgentSpecificMemory()` — async, returns the
  **real WASM + worker breakdown** (`bytes` + per-realm `breakdown`). Requires
  `crossOriginIsolated` (we have it) **and full site isolation**. Available in
  **full/headful Chrome** — i.e. the `--gpu` cloud run.
- **Fallback:** `performance.memory.usedJSHeapSize` (launch with
  `--enable-precise-memory-info` for un-bucketed values). The **local headless-shell
  smoke** falls back to this automatically — `chrome-headless-shell` throws
  `SecurityError: not available` for the measure-memory API. This is a headless-shell
  limitation, **not** a code bug; the real GPU run uses the primary API.

The artefact records `heap_source` so you always know which produced each number. For
the NEVER-OOM (§11) sign-off the binding number is the primary API's `bytes` from the
real GPU run.

---

## Driving the soak

The harness walks the player with **synthetic keyboard input** (`page.keyboard`): it
focuses the canvas, holds `KeyW` (forward), and periodically strafes (`A`/`D`), hops
(`Space`), and issues mouse-move turn deltas. Walking forward on the cube-sphere planet
crosses facet seams (the streaming / LOD stress the soak exists to measure).

**Limitation (documented, not blocking):** yaw turning needs **pointer lock**
(`MOUSE_MODE_CAPTURED`), which is best-effort under headful/xvfb; if it doesn't engage,
the walk still crosses seams by holding forward, it just can't freely re-aim. The clean
game-side fix is a **`?websoak=1` in-game auto-walk driver** (a scripted planet path) —
see *One game-side tweak we recommend* below. This spike does **not** add it (no game-src
edits); it drives via input, which is enough to exercise streaming and prove the harness.

---

## Screenshots

`page.screenshot()` captures the composited page. For a WebGL canvas it reliably
captures pixels only when the context was created with `preserveDrawingBuffer: true`;
Godot's HTML5 export does **not** set that, so screenshots are **best-effort** (may be
blank/last-frame at arbitrary times). Treat `[PERF]` + heap as the hard signal and
screenshots as a sanity glance. See the game-side tweak below for clean shots.

---

## One game-side tweak we recommend (NOT applied in this spike)

For clean, deterministic screenshots the web export would set
`preserveDrawingBuffer: true` on the WebGL context (Godot: the HTML5 canvas GL context
options / a `--rendering-driver` shim). It has a small VRAM/perf cost, so gate it behind
the same soak flag. This spike deliberately leaves game source untouched; it is a
one-line documented recommendation for whoever wires the in-game `?websoak=1` driver.

---

## Cloud T4 run recipes

Both give an NVIDIA T4. Verify a real GPU **before** trusting any run (checklist below).

### AWS spot `g4dn.xlarge` (T4) via RunsOn / plain EC2

1. Launch a `g4dn.xlarge` spot instance, Ubuntu 22.04, NVIDIA driver AMI (or install
   `nvidia-driver-535`). Confirm `nvidia-smi` lists the T4.
2. Install prereqs:
   ```bash
   sudo apt-get update
   sudo apt-get install -y xvfb vulkan-tools mesa-vulkan-drivers libnss3 libasound2 libgbm1
   # NVIDIA Vulkan ICD ships with the driver; confirm:
   vulkaninfo | grep -i "deviceName"      # must show "Tesla T4", NOT llvmpipe
   ```
3. Get the repo + export, install the harness:
   ```bash
   cd tools/web-soak-gpu && npm ci && npx playwright install --with-deps chromium
   ```
4. Run:
   ```bash
   xvfb-run -a node soak.mjs --gpu --duration 900 --out results
   echo "exit=$?"      # 0 = all gates pass
   ```

### Vast.ai T4 (cheapest)

1. Rent a T4 instance with a CUDA/Vulkan image (e.g. an `nvidia/vulkan` or CUDA base).
   Ensure `nvidia-smi` and `vulkaninfo` both see the T4.
2. Same package + harness install as above (`apt-get install xvfb vulkan-tools
   mesa-vulkan-drivers`; `npx playwright install --with-deps chromium`).
3. `xvfb-run -a node soak.mjs --gpu --duration 900`.

### Driver / Vulkan prereqs (both platforms)

- NVIDIA proprietary driver (≥ 535) with its Vulkan ICD (`/usr/share/vulkan/icd.d/nvidia_icd.json`).
- `xvfb` (virtual X display for headful Chrome).
- `vulkan-tools` (`vulkaninfo`) to confirm the ICD sees the T4.
- Chromium system libs via `npx playwright install --with-deps chromium`.

---

## FIRST-RUN VALIDATION CHECKLIST (do this BEFORE trusting a full run)

A run that silently fell back to software renders *plausible-looking* numbers that are
lies. Validate the GPU path first:

1. **`vulkaninfo | grep deviceName`** → shows **Tesla T4** (or your GPU), NOT `llvmpipe`
   / `SwiftShader`. If it shows software, the driver/ICD is wrong — fix before running.
2. **GPU smoke, short:** `xvfb-run -a node soak.mjs --gpu --duration 20`. In the log:
   - `UNMASKED_RENDERER_WEBGL = …` must name the **real GPU** (e.g. "ANGLE (NVIDIA,
     … Tesla T4 …)"), and the **real-GPU gate PASSES**. If it prints SwiftShader the
     harness **exits 1** — that is the gate doing its job; fix the GPU, don't bypass it.
   - `crossOriginIsolated === true` PASS, `engine boots ([PERF] line seen)` PASS.
   - `heap API returns … via measureUserAgentSpecificMemory` (the primary, not the
     fallback) — confirms full-Chrome heap breakdown is live.
3. **Non-black screenshot:** open `results/screenshots/shot-00.png`. Expect terrain /
   HUD, not solid black. (If black, it's the `preserveDrawingBuffer` caveat, not
   necessarily a GPU failure — cross-check `[PERF]` `draws`/`prims` > 0.)
4. Only after 1–3 pass, run the full `--duration 900` and **promote** its
   `results/latest.json` to `baseline/baseline.json` to arm the regression diff.

---

## Thresholds & flags

| Flag | Default | Meaning |
|---|---|---|
| `--gpu` / `--cpu-fallback` | — | real GPU test / local software smoke |
| `--allow-software` | off | proceed on software (smoke only) |
| `--require-gpu` | off | apply strict GPU gate even in `--cpu-fallback` (proves exit 1) |
| `--duration <s>` | 900 gpu / 30 cpu | soak-walk length |
| `--url <u>` | — | test an external origin instead of the local server |
| `--floor-ms <ms>` | 18 | worst-frame budget (CTRL_FRAME_BUDGET_MS) |
| `--min-pct <pct>` | 99 | min % of frames ≤ floor |
| `--max-hitches <n>` | 0 | extra hitches (>33 ms) allowed during the walk |
| `--heap-ceiling-mb <mb>` | 900 | hard heap ceiling (NEVER-OOM guard) |
| `--[no-]enforce-perf` | on in `--gpu` | fail on perf thresholds |
| `--regress-pct <pct>` | 20 | baseline regression tolerance |
| `--shots <n>` | 6 | screenshots |
| `--baseline <file>` | `baseline/baseline.json` | regression baseline |

Exit codes: **0** all gates pass · **1** a gate/threshold failed · **2** setup error
(no build, browser missing, …).

---

## Files

```
server.mjs            COOP/COEP static server for build/web/
soak.mjs              the Playwright driver (gates, boot, walk, scrape, assert)
smoke.sh              local CPU-fallback proof (all four checks)
lib/coop-headers.mjs  COOP/COEP header source of truth (mirrors nginx template)
lib/chrome-flags.mjs  GPU vs CPU-fallback flag recipes + software-renderer detector
lib/perf-parse.mjs    [PERF] / [PERF-HITCH] console-line parser + summary
baseline/             promote a green GPU run's latest.json here to arm regression diff
results/              run artefacts (gitignored)
```
