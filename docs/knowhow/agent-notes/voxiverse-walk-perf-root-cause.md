---
name: voxiverse-walk-perf-root-cause
description: "2026-07-17 walking-perf root cause — WASM runtime serialization (dlmalloc convoy), NOT worker count / apply budget / movement; fix = mimalloc engine build + alloc diet"
metadata: 
  node_type: memory
  type: project
---

Fable analysis 2026-07-17 (`docs/COSMOS-WALK-PERF-DESIGN.md`, branch deploy/perf-plus-sky) settled the walking-perf question from live telemetry re-analysis:

- **Movement is FREE** (moving+gen-idle worst p50 23.4 ≈ standing 23.2). All walking jank tracks streaming ACTIVITY: even standing during a backlog drain reads worst p50 43.8–60.9.
- **Root cause: threaded-WASM shared serializer** — workers and main thread throttle each other (drain↔worst_ms r=−0.47; phys_ms of unchanged code 7.4→31 ms when workers busy; measured live pool_active=6/6 saturated on GenerateBlock yet only ~40 blocks/s ≈ 1–1.5 workers' worth). Prime suspect: Emscripten dlmalloc single global lock (web.dev shows malloc-heavy WASM anti-scales with threads). NOTE: the user's browser runs on their LAPTOP (hw≈8 → 6 voxel workers), NOT the 24-core dev host — never use dev-host load/ps as browser evidence.
- **Superseded framings** (do not resurrect): the "2-worker web gen ceiling" ([[voxiverse-web-perf-architecture]], module_world.gd:18-25 stale comment); the project.godot:74-91 "6 ms apply budget = downstream choke" (vox_main ≈ 0 — the budgeted queue is empty; gen-result apply is unbounded and has no back-pressure to vox_gen).
- **E5 mimalloc A/B RESULT (2026-07-17 PM): tested and DEMOTED** — worst p50 −23%, drain/phys/fps flat. dlmalloc convoy = real but minor. Leading explanation now: genuine per-block GDScript-VM-on-WASM cost (~150–240 worker-ms; VM interpreter on WASM ≈5–10× native, not 2–3×) + physical-core oversubscription (laptop ≈4 physical cores + SMT; 6 workers + main). Decisive next: E9 per-block wall-time inside `_generate_block` (GDScript, no rebuild) × E2 worker A/B (N=6 vs 3): per-block unchanged at N=3 ⇒ C++ port (L5a) is the main event; collapses ⇒ contention ⇒ device-aware worker cap (L4b, tune for main-thread smoothness not drain).
- **Fix ladder (revised):** E9+E2 → L4b worker cap → L3 `FP_GEN_ALLOC_DIET` (memo Dictionary → flat arrays) → L5a C++ port of resolve_cell/column_profile/slope_run_of if E9 confirms → L4 demand audit (walk at 3.4 vox/s demands ~90–100 blocks/s gross; bare viewer ellipsoid explains only 15–20).
- **Heap instrument for NEVER-OOM gates on web release builds:** `MEMORY_STATIC`=0 (debug-only) and Module is closure-hidden from JavaScriptBridge.eval; use `performance.measureUserAgentSpecificMemory()` (needs crossOriginIsolated — we always have it) stashed on a window global, or patch godot_voxel get_stats to add `emscripten_get_heap_size()`.
- **Architecture verdict: no change needed** — faceted stack, physics, draws, meshing, apply queue all exonerated by measurement.

**Why:** months of work targeted worker count and pacing; the binding constraint is the runtime allocator. **How to apply:** before any new perf work, check whether the mimalloc build (L2) landed and what E1/E2 showed; measure with the §5 comparability protocol (fixed spawn-drain + fixed walk route).
