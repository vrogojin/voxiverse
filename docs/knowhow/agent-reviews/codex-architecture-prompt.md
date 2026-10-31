DEEP ARCHITECTURE REVIEW — second, broader pass. Your first analysis (saved at
docs/CODEX-BUILDING-RENDER-ANALYSIS-1.md) correctly found the render-path wastes (shell dither, cull_disabled,
non-indexed, planet-scale AABB). We shipped the shader-dither fix + backface-cull toggle. IT DID NOT HELP — the
user reports the far-village jerk is unchanged, still spikes ~twice per second at ~alt 500 over villages, and the
game is "blazingly fast" with villages off. So the per-fragment dither was NOT the dominant cost. We need to go
DEEPER and question the whole architecture, not tune it.

Read first (all in this repo):
- docs/COSMOS-BUILDING-RENDER-PERF-STRUGGLE.md  (the full brief + measurements)
- docs/CODEX-BUILDING-RENDER-ANALYSIS-1.md       (your first pass)
- godot/src/world/facet_far_structures.gd        (the far-building tier — ONE merged ArrayMesh of cube voxels)
- godot/src/world/struct_decimator.gd            (the decimate + cube-mesh bake)
- godot/src/world/facet_far_trees.gd             (the far-TREE tier — impostor cards; the pattern that WORKS)
- godot/src/cosmos/cube_sphere.gd                (STRUCT_* consts, FP_STRUCT_* flags)

NEW DATA since your first pass:
- The "twice per second" spike cadence is a STRONG clue. STRUCT_STEP_MS=250 (4Hz rebuild cap); walk_calm gates
  rebuilds on membership-change. What runs at ~2Hz over a STATIONARY village view? Trace EVERY periodic action in
  the far-structure step/probe/cull/bake path (facet_far_structures.gd _process/_rebuild/_probe_pass/_drain_bakes/
  _cull_emit) and the ring that drives it (facet_far_ring.gd). Is something re-baking, re-probing, re-committing,
  or re-evicting on a timer even when nothing changed? The user is STATIONARY yet sees 2Hz spikes.
- We measured: stationary st_rb Δ0, merge ~2ms, prims +240k with villages. But "st_rb Δ0" was over a short window
  and may have missed a slow oscillation. Question that measurement.

Your job — be ruthless and fundamental:
1. WHY does adding villages instantly kill perf when terrain+trees at the same distance are fast? What is the FbO
   the far-tree tier has that the far-structure tier lacks? (trees = MultiMesh cards; structures = merged unique mesh.)
2. Is the merged-unique-ArrayMesh-of-cube-voxels approach FUNDAMENTALLY WRONG for many custom structures on
   gl_compatibility/WASM? If so, exactly why (draw submission, buffer re-upload, vertex count, culling, overdraw,
   state changes, shader recompiles on rebuild)?
3. Trace the 2Hz spike to a specific line/mechanism. That periodic hitch is the smoking gun — find it.
4. What is the CORRECT architecture? Give a concrete, staged migration plan (not just "use impostors") that fits
   this codebase — reusing the far-tree MultiMesh/atlas machinery, with exact integration points and the flag
   discipline (byte-off FP_* + FLAT verify_feature 6042/0).

This is READ-ONLY reasoning — do not modify files. Produce a definitive root-cause + architecture recommendation,
and explicitly reconcile it with the fact that the shader-dither fix changed nothing.
