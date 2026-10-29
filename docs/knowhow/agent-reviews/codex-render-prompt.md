Read `docs/COSMOS-BUILDING-RENDER-PERF-STRUGGLE.md` first — it is a self-contained brief on our one
unsolved performance problem: rendering player-scale custom buildings (procedural village houses) at a
distance makes this Godot 4.4.1 voxel game jerky the instant they appear, while everything else (terrain,
trees, sky, orbit) stays smooth. Target runtime: Web export, WASM, WebGL2 **gl_compatibility** (GLES3-class),
threaded. The jerk is a hard threshold — it begins exactly when the first far-rendered house appears at
~alt 500, and villages-off is "blazingly fast."

Then read the key source the brief references, and compare it against the far-TREE tier that already solved
the analogous problem a different way:
- `godot/src/world/facet_far_structures.gd` — the far-building render tier: ONE merged `ArrayMesh` of
  decimated cube-voxels, custom `voxi_shade` ShaderMaterial, rebuilt on the main thread.
- `godot/src/world/struct_decimator.gd` — the decimate + face-culled cube-mesh bake.
- The far-tree tier (grep `FacetFarTrees`, `far_trees`, "card", "impostor") — trees are drawn as cheap
  camera-facing impostor cards, NOT voxel geometry.
- `godot/src/cosmos/cube_sphere.gd` — the `STRUCT_*` constants and the `FP_STRUCT_*` feature flags.

I want your INDEPENDENT architectural assessment — not a rehash of the brief. Be concrete and opinionated:

1. **GPU vs main-thread.** Measured data: with 81 far-villages in view (stationary), prims jump ~820k → 1.06M
   (villages add ~240k, pinned at the 80k-tri cap), `wf_draws` only ~58, no rebuild churn while still, and the
   merge/concat+commit is ~2 ms. Is the far-village cost most likely **GPU-fragment-bound** (240k prims under
   the `voxi_shade` fragment shader) or **main-thread-bound** (rebuild/upload + the O(volume) decimate bake)?
   Propose the SINGLE cheapest experiment that decides this definitively on gl_compatibility (we have no GPU
   frame timer and a relay observer-effect that pollutes wall-clock frame time).

2. **Impostor tier?** Should far buildings abandon the cube-mesh approach for an impostor/billboard tier like
   the far-trees? If yes, sketch the concrete design — baked sprite atlas per house style/roof, camera-facing
   quads, exactly how it slots into `FacetFarStructures` (replacing the merged cube mesh), and a rough build
   cost. If no, say why the cube mesh is actually right and what to fix instead.

3. **Decimation.** `STRUCT_TARGET_RES=16` means houses ≤16 blocks render at FULL 1:1 voxel resolution (no
   decimation) in the far model. Is that simply wrong — should far houses always decimate to a small fixed
   silhouette regardless of size? What target/scheme?

4. **What did we miss?** Anything the brief's candidate list (§6: impostors / static-bake / MultiMesh /
   off-thread / cull-fade) overlooks. Rank ALL your recommendations by expected leverage × fit to
   gl_compatibility + WASM.

This is a READ-ONLY reasoning task — do not modify any files; produce an analysis + a ranked recommendation.
