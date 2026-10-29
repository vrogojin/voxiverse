---
name: voxiverse-forest-fps-root
description: 2026-08-12
metadata: 
  node_type: memory
  type: project
---

2026-08-12, task #119 (stationary warm forest facet 1754, fps p50 30). ROOT CAUSE
measured from 3,642 telemetry windows: `FacetFarTrees.step()` (facet_far_trees.gd:442-478)
runs `_rebuild_meshes` + `_rebuild_cards` UNCONDITIONALLY every FAR_TREES_STEP_MS=250 —
no change gate. Each rebuild: 3,456-facet `_wanted_facets` scan + sort_custom lambda,
40-75k cached tree records walked ×2 rungs (per-record sqrt + `_is_chopped` Callable +
Vector3i alloc), ~0.76MB buffer realloc + MultiMesh.set_buffer upload ≈ **57ms
main-thread**, bit-identical output when camera static. Evidence: worst_ms BIMODAL
(39.8 vs 97.3ms modes); **P(stall|stream_credit>0)=0.96 vs 0.24** (credit precedes,
lag-1 0.84); corr(fps,credit)=−0.35 — fps WORSE when credit flows.

**Limit cycle**: rebuild stall → frame_worst_ema > adaptive setpoint (~39ms) →
controller cuts credit → step():452 credit gate turns tier OFF → clean frames → credit
back → stall resumes. Controller PWM-modulates its own attacker (obs-2 feedback-trap
class, one layer out). Exonerated: vsync lock (fps continuous 22-47, NOT quantized),
draws (constant 171-179), snow/env/vt/smooth (all ≈0), frame-capture observer (cap=0
windows still bimodal), farring build_ms 1093 event (absent from capture — red herring).

Fix designed (NOT implemented): **FP_FAR_TREES_DELTA** — skip rebuild unless cam moved
≥2 blk OR cache epoch OR WorldManager.edit_count() (:607, plumb like chop query
world_manager.gd:414→facet_far_ring.gd:5150) OR _stale latch; cache _wanted_facets to
64-blk motion. Pixel-identical skip (fades are dist-only). Est p50 30→38-42.
Residual floor 19.4ms (floor_p10): phys ~8.4ms = 60Hz full-fat update_streaming per
tick, no idle guard (world_manager.gd:1155-1264) → P2 FP_STREAM_IDLE_DIET; ~14ms
render/GPU residual — decompose via live visibility-toggle probes (backstop 489k verts).
LESSON: when a load controller's credit CORRELATES with stalls, suspect a credit-gated
consumer in a limit cycle — check P(stall|credit) contingency before averaging fps.
Related: [[voxiverse-far-trees-design]] [[voxiverse-web-time-process-invalid]]
[[voxiverse-walk-perf-root-cause]]
