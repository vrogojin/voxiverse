---
name: voxiverse-mimalloc-fit-build
description: 2026-08-23 mimalloc-FIT engine build (arena_reserve 128→16 MiB) — the 3 build-plumbing traps that silently ship a STALE web template, and how build-engine.sh guards them
metadata:
  node_type: memory
  type: project
---

2026-08-23. Implemented mimalloc-FIT (COSMOS-PERF-ENGINE-DEEP §3): cap mimalloc's 32-bit `arena_reserve`
128→16 MiB so its −23% worst-frame convoy win fits the +120 MB NEVER-OOM ceiling (the P6 +422 MB veto was
arena-step permanence on wasm sbrk, NOT per-thread segments). The one-line source change is trivial; getting
it to ACTUALLY land in the served `.wasm` hit THREE silent-staleness traps — each produced a green exit-0
build with the OLD binary. All now guarded in docker/engine/build-engine.sh (mimalloc-only block at ~L158).

TRAP 1 — build-engine.sh is BAKED into the image, not bind-mounted. Dockerfile `COPY build-engine.sh
/usr/local/bin/... ; ENTRYPOINT [...]`. Editing the host file does NOTHING at runtime. FIX: scripts/build.sh
now bind-mounts it: `-v "${ENGINE_DIR}/build-engine.sh:/usr/local/bin/build-engine.sh:ro"` (+ passes
`-e WEB_MIMALLOC_ARENA_RESERVE_KIB`). Host script is now authoritative, no image re-bake needed. (Dockerfile
COPY still picks it up for cold CI.)

TRAP 2 — `source /emsdk/emsdk_env.sh` UNSETS EM_CACHE. Under `set -Eeuo pipefail`, any `${EM_CACHE}` ref
AFTER the source (build-engine.sh L156) aborts the script with "unbound variable" — mine aborted at the find
BEFORE scons ran (yet exit code was still reported 0 via the `|| true`). FIX: reference the two deterministic
cache roots literally — `/work/emcache` and `/emsdk/upstream/emscripten/cache` — never the clobbered var.

TRAP 3 (the big one) — libmimalloc.a is a SYSTEM lib INVISIBLE to scons's content hash, so an unchanged
`malloc=mimalloc` command line = identical link signature = the stale link is served from EITHER (a) the
scons CacheDir (`Retrieved bin/.web_zip/godot.wasm from cache`) OR (b) the warm build tree — `git clean -fdq`
(NO `-x`) KEEPS git-ignored `bin/godot.web.*.wasm`, so scons just re-zips it in ~5s (`Install file ...`, no
Linking line). Purging libmimalloc*.a alone is NOT enough — embuilder rebuilds the .a but scons never relinks.
FIX (both, in the FIT block): purge `libmimalloc*.a` from both cache roots AND
`rm -f /work/godot/bin/godot.web.template_*.wasm32.*` to force a real relink from surviving .o (~1m45s,
shows `Linking Program bin/godot.web...`). A one-time `rm -rf docker/engine/cache/scons-cache` was needed
locally to evict build1's poison entry; committed script handles cold caches correctly.

VERIFICATION that the link is FRESH (not stale): log MUST show `Linking Program bin/godot.web.template_release`
+ wasm-ld warnings + `Time elapsed: ~1-2min` (NOT 5s, NOT `Retrieved ...godot.wasm from cache`). The FIT sed
canary `==> mimalloc-FIT: capped arena_reserve 128 MiB -> 16384 KiB` proves the guarded sed found exactly the
`128L * 1024L` literal once (hard-fails as an emsdk-bump canary otherwise). Ultimate proof is the heap A/B:
FIT peak heap must be ≈ dlmalloc + a few×16 MiB, NOT P6's +422 MB.

versions.env: WEB_MALLOC=mimalloc + WEB_MIMALLOC_ARENA_RESERVE_KIB=16384. Revert knob: WEB_MALLOC=dlmalloc
(whole FIT block skipped). [[voxiverse-mimalloc-arena-root]] [[voxiverse-mimalloc-reab-rejected]]
[[voxiverse-walk-perf-root-cause]] [[voxiverse-never-oom-web]]

**OUTCOME 2026-08-23: FIT REJECTED on the heap A/B.** The build plumbing all worked (FIT engine verified live,
served index.wasm byte-match), but the measured live de-orbit-fall PEAK heap = **842 MB** (@ alt 94), vs
dlmalloc 412 = +430 MB = 3.6× the +120 ceiling, and ~identical to the UNCAPPED mimalloc peak (~834). The
prediction above ("FIT peak ≈ dlmalloc + a few×16 MiB") was FALSIFIED — arena_reserve is the per-step size, so
the cap only trimmed the REST heap (834→706), not the PEAK. versions.env reverted to WEB_MALLOC=dlmalloc; live
rebuilt+redeployed on dlmalloc. The FIT block in build-engine.sh is dormant (WEB_MALLOC≠mimalloc) but kept as a
guarded record. All three build-plumbing traps + guards above remain valid engineering for any future
system-lib source patch. See [[voxiverse-mimalloc-arena-root]] for the corrected mechanism.
