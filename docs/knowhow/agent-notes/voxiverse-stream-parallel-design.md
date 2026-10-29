---
name: voxiverse-stream-parallel-design
description: "2026-08-10 fresh-reload 2-3min root cause = G2 DEM bake gate-not-bounded duty-cycle on main thread; design COSMOS-STREAM-PARALLEL-DESIGN.md (FP_DEM_DEFER/ASYNC, FP_NB_FULLRES, one bg token)"
metadata: 
  node_type: memory
  type: project
---

2026-08-10 (task #102, doc `docs/COSMOS-STREAM-PARALLEL-DESIGN.md`, committed 5eb3bc2 on deploy/cheats-eyeball):

**Reload root cause:** `GlobalReliefData.step` (G2 DEM, main thread, world_manager.gd:1239-1249) is frame-budget **gated** (last-frame delta < 22ms) but the admitted unit is **unbounded**: O(3456) allocating `_next_unbaked` scan (~10-30ms web) + `bake_smooth_tile` (~5-25ms web) + 1089-node GDScript hillshade ⇒ 20-60ms per admitted frame. Gate-on-last-frame ⇒ duty-cycle sawtooth: every recovering frame re-spiked ⇒ the 4-28fps 2-3min window until the view cone bakes. First call has frame_ms=0 (always admits). G3's on-surface suspend (facet_orbit_relief WS1a) covers the relief MESH only, NOT the DEM. On-surface the DEM's only consumer is far-ring shade multiply which self-degrades to 1.0 ⇒ deferring costs nothing visible.

**Design:** Phase A `FP_DEM_DEFER` (no bake before settle; demand-driven want-list from far-ring shade misses; alloc-free centre-dir table) = the reload win. Phase B `FP_DEM_ASYNC` + `FP_BG_ONE_TOKEN` (DEM via JobLane worker, own C++ gen instance reader-parallel; ONE background WTP task total on-surface, 2 off-surface). Phase C `FP_NB_FULLRES`: all-4 edge neighbours live via existing Z1 pool (POOL_MAX_NEIGHBOURS=4 already the cap; no-distance-retire; NB_BAND_BLOCKS=64 view target for non-imminent; FP_COLBULK+FP_STAMP stone-fill for neighbour gens; NB_POOL_BYTES_CAP=32MB ledger). Nearest-first preserved by construction: all pool terrains share the ONE player viewer localized per slot.

**Gotchas found:** project.godot:102 `ratio_over_max=0.7` contradicts its own comment arguing 0.4/N=3 (the [[voxiverse-walk-perf-root-cause]] A/B) — re-check. Crossing `redesignate` transform spike scales with live mesh blocks ⇒ Phase C gated on measured redesig_ms; structural fix stays [[voxiverse-crossing-phys-spike]] fixed-frame.
