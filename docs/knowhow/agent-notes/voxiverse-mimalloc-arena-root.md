---
name: voxiverse-mimalloc-arena-root
description: 2026-08-23 arena_reserve hypothesis MEASURED-REFUTED — capping 128→16MiB did NOT cut mimalloc peak heap (fall peak 842MB ≈ uncapped 834, +430 over dlmalloc); arena_reserve is per-step SIZE not total; mimalloc stays rejected, dlmalloc ships
metadata: 
  node_type: memory
  type: project
---

**MEASURED VERDICT 2026-08-23 (supersedes the hypothesis below): mimalloc-FIT REJECTED.** Built the arena cap
(128→16 MiB) into the live web template ([[voxiverse-mimalloc-fit-build]]) and ran a live consent-gated
de-orbit fall A/B. **PEAK heap_mb = 842 MB @ alt 94** (near-field flood on descent) vs dlmalloc baseline 412 =
**+430 MB, 3.6× the +120 NEVER-OOM ceiling — and ~IDENTICAL to the UNCAPPED mimalloc peak (~834).** The arena
cap saved essentially nothing at peak. WHY the hypothesis was wrong: `arena_reserve` is the per-step *size*, so
capping it only trims per-step rounding slack (matters at low/idle demand — rest heap did drop 834→706), but at
PEAK flood the allocator needs its full per-thread working set across 24 workers (~+420 MB) regardless of step
granularity. So the +422 is REAL mimalloc segment/thread-heap working set, NOT arena stepping. **dlmalloc stays;
do not ship mimalloc (FIT or not).** The −23% walk-frame win cannot be bought within NEVER-OOM. Pivot the
de-orbit perf work to the streaming/gen convoy levers (C-lite gen gating, godot_voxel patch 0015 gen admission
control) which don't touch the allocator. LESSON: a heap hypothesis on wasm must be validated by a PEAK-flood
live measurement before a design doc treats it as root cause — the rest-heap drop (834→706) looked like progress
but the peak (the NEVER-OOM gate point) was unchanged.

--- ORIGINAL HYPOTHESIS (now refuted — kept for the mechanism detail, which is real but not the heap driver) ---

2026-08-23 deep-perf investigation (docs/COSMOS-PERF-ENGINE-DEEP-DESIGN.md): the P6 mimalloc
heap veto (+398-422 MB, [[voxiverse-mimalloc-reab-rejected]]) was MISATTRIBUTED. Measured inside
the pinned toolchain image (voxiverse/godot-build:4.4, emsdk 3.1.64, mimalloc VENDORED at
system/lib/mimalloc, v2.1.2):
- wasm32 MI_SEGMENT_SIZE = **4 MiB** (types.h `#if MI_INTPTR_SIZE>4` → 32MiB is the 64-bit
  branch) → per-thread cost small; idle preallocated pool workers have NO heap. 24 workers ≲
  100 MB worst case — NOT the +422 driver. Lowering WEB_PTHREAD_POOL is NOT a heap lever
  (keep 24; exhaustion = blank-world deadlock; ledger floor ~18).
- REAL driver: options.c 32-bit `arena_reserve` default = **128 MiB per arena growth step**,
  allocated via prim/emscripten/prim.c `emmalloc_memalign` on sbrk → reserve==committed REAL
  wasmMemory, `_mi_prim_decommit` is a no-op, sbrk never shrinks. +422 ≈ 3×128 MiB steps +
  alignment + ~14 live threads × 4 MiB.
- Fix vehicle: guarded sed of the options.c literal (pattern-count==1 else hard-fail, emsdk-bump
  canary) + purge cached libmimalloc*.a + versions.env pin WEB_MIMALLOC_ARENA_RESERVE_KIB=16384
  + WEB_MALLOC=mimalloc; ~4 min warm template rebuild. Runtime alt: MIMALLOC_ARENA_RESERVE env
  works (_mi_prim_getenv exists; option latches at first arena growth, post-init) — A/B iteration
  only, not the ship vehicle. Fallback knobs: arena 8 MiB, eager_commit_delay 1→4.
- Predicted Δ ≈ +60-100 MB vs the +120 ceiling — TIGHT; ship gate must measure PEAK heap_mb on
  the WARM continuous-fall FLOOD (sbrk high-water is permanent), not just steady walk/orbit.

**Why:** the frame win is real (walk worst p50 −23% proven; the de-orbit 6-7k GenerateBlock
flood is the same convoy) and was only ever blocked by a tunable default misread as structural.
**How to apply:** before any allocator/pool heap reasoning on web, remember wasm32 mimalloc =
4 MiB segments + 128 MiB arena steps on sbrk-that-never-shrinks; tune arena_reserve first.
[[voxiverse-walk-perf-root-cause]] [[voxiverse-fall-mesh-stall]] [[voxiverse-never-oom-web]]
