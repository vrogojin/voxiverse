---
name: voxiverse-web-core-count
description: "TRUE core count on VOXIVERSE web = navigator.hardwareConcurrency (telemetry cores=8); OS.get_processor_count() UNDER-REPORTS on Godot web (telemetry os_cores=2 — do NOT use it for sizing/offload decisions). Fixed in 622a5c5."
metadata:
  node_type: memory
  type: reference
---

**On the Godot 4.4 web/WASM export, `OS.get_processor_count()` UNDER-REPORTS the core count** (returns ~2 regardless of the real machine). The TRUE logical core count is `navigator.hardwareConcurrency`. This was root-caused + fixed: diag trail 395b773 (force _pbm_n=6 probe) → 112d3bf (revert, "browser reports 2 cores") → **622a5c5 "detect TRUE cores via navigator.hardwareConcurrency (web OS.get_processor_count under-reports)"**. The worker pool (_pbm_n / voxel mesher) is sized off the TRUE count.

**Telemetry key mapping (do not confuse them):**
- `cores` = `navigator.hardwareConcurrency` = the TRUE logical count (e.g. 8). USE THIS for any threading / offload / worker-sizing decision.
- `os_cores` = `OS.get_processor_count()` = the web UNDER-REPORT (e.g. 2). A diagnostic only — NEVER use it to conclude "the host has 2 cores."

**Why this matters / the trap:** I twice reasoned "os_cores=2 ⇒ ~2 real cores ⇒ offloading to worker threads will convoy/hurt." WRONG — the user's host (and typical desktop browsers) have 4-8+ logical cores. Offloading main-thread work to workers IS viable. When weighing thread offload, read `cores` (hardwareConcurrency), not `os_cores`.

**FP_TRUE_CORES was a NON-ISSUE (dropped 2026-08-12):** the thread-offload design claimed facet_smooth_v2.gd / facet_orbit_relief.gd size worker pools off OS.get_processor_count() (→ 1 slot on web) — but those FILES DO NOT EXIST (hallucinated citations). Verified: the only two OS.get_processor_count() uses in non-test GDScript (facet_far_ring.gd:712, remote_bridge.gd:906) are `> 1` "is-multicore?" boolean gates, NOT worker sizing. The GDScript far-tier bakers use Godot's GLOBAL `WorkerThreadPool.add_task` (facet_far_ring.gd:752, remote_bridge.gd:892) which the ENGINE sizes from the true core count; the C++ voxel pool (telemetry pool_threads=6) is engine-sized too. So there is NOTHING mis-sized to fix. LESSON: Fable/agent file:line citations can be hallucinated — VERIFY the cited site exists (grep) before building a fix from a design doc.

**Honest nuances that DO still apply** (not a core-count wall): hardwareConcurrency counts HYPERTHREADS, so CPU-bound WASM scales ~1.2-1.4× per HT pair (not 2×); godot_voxel's mesher pool already uses cores while the player MOVES (free at rest → good for stationary wins); the WASM dlmalloc convoy ([[voxiverse-walk-perf-root-cause]]) is about heavy per-task ALLOCATION contending the allocator lock, NOT core count — prefer pre-allocated/reused buffers in offloaded tasks. Related: [[voxiverse-gen-class-costs]] [[voxiverse-stream-parallel-design]] [[voxiverse-forest-fps-root]] [[voxiverse-web-testing-host]].
