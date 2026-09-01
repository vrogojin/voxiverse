codex
My conclusion: the persistent jerk is much more likely in the rendering path than in structure baking or mesh upload—but “240k fragments running `voxi_shade`” is not quite what the code does. The current tier is expensive through a combination of duplicated vertex work, disabled backface culling, lack of spatial culling, and—in the altitude shell—a surprisingly costly fragment-dither shader.

I analyzed commit `e911a64` from `feat/voxiverse-fartier-walk`, since the requested brief and sources are in that worktree rather than the currently checked-out branch.

## 1. GPU versus main thread

Most likely: GPU/rendering-bound while the mesh remains visible. Low probability that bake/rebuild is responsible for the stationary persistent jerk.

The decisive evidence is:

- Stationary rebuild count is zero.
- The measured merge/upload is only about 2 ms and occurs on membership changes, not continuously.
- The jerk persists every frame.
- The tier adds 80k triangles represented by roughly 240k non-indexed vertices.
- The whole batch is always considered potentially visible because of the enormous `custom_aabb`.
- `cull_disabled` prevents hardware backface rejection.

Two important corrections from the implementation:

1. The ordinary structure shader calls `voxi_shade` in `vertex()`, then passes a flat color to an almost empty fragment shader. It is therefore primarily a vertex cost, not a `voxi_shade` fragment cost. See [facet_far_structures.gd:90](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_structures.gd:90).

2. In the 256–600 altitude shell, the tier swaps to `_SHELL_SHADER`. That shader evaluates a `sin(dot(...))` screen-space dither in every fragment—even below altitude 520, where `tier_fade` is exactly 1 and no pixel can be rejected. See [facet_far_structures.gd:130](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_structures.gd:130). This is a credible explanation for why reducing geometry by 70% did not cure the jerk: roughly the same house-covered pixels still execute the expensive fragment hash.

So I would describe it as “GPU/render workload bound,” with the exact bottleneck potentially shifting:

- Surface: duplicated vertex shading/rasterization is the stronger suspect.
- Altitude 256–600: fragment dither plus overdraw is a strong suspect.
- Not bake/upload while stationary.

### The single cheapest definitive experiment

Add one local, relay-free debug toggle that changes only:

```gdscript
_mi.visible = not _mi.visible
```

Run it after all houses have baked, with the camera frozen and `_mesh` retained. Toggle automatically every 3–5 seconds and show the state on screen so no relay polling is required.

This preserves:

- Registry scans
- Probe passes
- Cached bakes
- Mesh memory
- All other world systems

It removes only submission/rasterization of the structure mesh.

If jerk follows visibility immediately, the bake/rebuild hypothesis is eliminated. If jerk continues while hidden, inspect the periodic structure step/probe path. Given one draw call, a visibility-correlated result is effectively a rendering/GPU verdict for the dichotomy posed.

I would run this before developing any redesign.

## 2. Buildings should get an impostor tier

Yes. Player-scale procedural houses should not remain voxel-surface meshes throughout `[near radius, 2400]`.

I would use a hybrid ladder:

```text
near voxel mesh → tiny parametric house mesh → directional impostor → roof pixels / culled
```

The near voxel tier remains exact. A very small gabled-box mesh can cover the short transition where a house is tens of pixels tall. Beyond that, use impostors.

### Concrete `FacetFarStructures` design

Retain the class’s existing:

- Registry query
- Distance membership
- Near-presence handoff
- Revision tracking
- Band fingerprint and hysteresis

Replace `_mesh`, `_mi`, `_baked`, `_ensure_bake()` and `_commit_mesh()` with:

- One shared indexed mesh: one vertical quad plus one horizontal roof cap, four triangles per house.
- One `MultiMeshInstance3D`.
- One RGBA atlas.
- One instance record per emitted house: radial basis/origin, width, height, archetype index and fade.

The vertical quad should be cylindrically camera-facing in the vertex shader: radial-up remains the house’s vertical axis while the horizontal axis faces the camera. The roof cap remains tangent to the planet.

Use eight azimuth views per archetype. Compute the view sector in the shader from `camera_pos`, the instance origin and its local house axes; this avoids rebuilding the instance buffer whenever the camera rotates.

The generated houses have fixed materials and a small parametric style space. Canonicalize them to approximately:

- Flat versus gabled roof
- Wall height 3 versus 4
- Four door orientations
- Actual width/depth supplied as instance scale

That is 16 visual archetypes. At eight side views plus one top view, 144 tiles. A 32×32 RGBA8 atlas is only about 576 KiB. It can be CPU-rasterized from `StructureGen` like the tree atlas, or preferably imported as a prebaked asset.

For 81 house instances:

- 324 triangles with side+cap, versus up to 80,000
- About 5 KiB of 16-float instance data
- One draw
- No per-house O(volume) decimation
- No mesh concatenation

The far-tree card machinery already demonstrates the viable WebGL2 pattern: indexed shared card, atlas, custom instance data and alpha scissor. See [facet_far_trees.gd:1125](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_trees.gd:1125) and [facet_far_trees.gd:1448](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_trees.gd:1448).

The MultiMesh color bug is not a reason to avoid this design. Tree cards are already safe because their shader does not read vertex `COLOR`. Either do the same, or enable instance colors and explicitly write white as the existing color fix does.

One caveat: Godot does not give useful per-instance frustum culling for one giant MultiMesh; its AABB is culled as a whole. With only a few hundred billboard triangles, that is acceptable. If instance counts grow substantially, split them into spatial village/facet batches.

Estimated engineering cost:

- Basic functional impostor tier: 2–4 focused days.
- Directional atlas, transitions, visual validation and gates: roughly one week.
- Runtime atlas generation: likely tens of milliseconds once; imported atlas: effectively zero runtime generation cost.

## 3. Decimation

`STRUCT_TARGET_RES=16` is wrong for this tier. It is a target that is larger than the objects it is supposed to simplify, so it often requests no simplification at all.

Even `STRUCT_COARSE_RES=8` still leaves every house with maximum extent ≤8 at pitch 1. That explains why a large aggregate triangle reduction does not mean every visible house became cheap.

If the cube mesh remains temporarily, use:

```text
pitch = max(2, next_power_of_two(ceil(max_extent / 6)))
```

For current 5–11-block houses, that normally means pitch 2 and a silhouette roughly 3–6 coarse cells across. I would also lower the aggregate cap into the 8–12k-triangle range.

But this is only an interim fix. OR-occupancy cube decimation is poor for one-block walls: it dilates them, destroys openings and still emits many coplanar voxel faces. A procedural house already has known walls, roof, door and dimensions; generating a 30–80-triangle parametric shell is both cheaper and visually better than coarse voxel occupancy.

Ultimately LOD should be screen-space driven, using the existing `ObjectLod` idea:

- Exact near voxels while close.
- Parametric shell while silhouette error would exceed about one device pixel.
- Directional card once its approximation error is sub-pixel or nearly so.
- Far-skin roof stamp or disappearance when the complete house is only a few pixels.

## 4. What was missed

The largest omissions are:

- `_SHELL_SHADER` runs a transcendental dither hash on every covered fragment even when `tier_fade == 1`.
- `cull_disabled` is unnecessary for correctly wound closed house geometry and increases raster work.
- The mesh is non-indexed: four logical quad vertices become six shaded vertices.
- Face culling is not greedy meshing. Every exposed voxel face remains its own quad; adjacent coplanar faces are never merged.
- One enormous `custom_aabb` plus one planet-scale batch defeats useful frustum culling. Houses behind the camera or horizon can still consume vertex work.
- The candidate statement that MultiMesh “can be GPU-culled” is misleading here: the renderer generally culls the MultiMesh as one object, not each house.
- The existing far-skin roof representation could take over earlier for steep/top-down views instead of retaining 3D houses until a fixed altitude.
- Lazy shader/pipeline compilation might explain a one-time first-appearance hitch, but cannot explain the continuing stationary jerk.

## Ranked recommendations

1. **Run the resident-mesh visibility A/B.** Cheapest definitive diagnosis; no relay and no reload/location variance.

2. **Replace the distant cube tier with directional impostors, selected by screen size.** Highest architectural leverage and best fit for WebGL2/WASM.

3. **Immediately fix the existing shell shader:** use a no-dither material while fade is 1, and use a cheap 4×4 Bayer pattern—not `sin()`—only during the 520–600 transition. Also enable backface culling where winding permits.

4. **Add a tiny parametric house-shell tier between near voxels and impostors.** Better fidelity and far fewer triangles than voxel decimation.

5. **Until that lands, force pitch ≥2, target roughly six cells, greedy-merge faces, and index the mesh.** This should reduce vertex count by much more than changing `STRUCT_TARGET_RES` alone.

6. **Use screen-space culling and the existing far-skin roof pixels earlier.** Especially effective for top-down altitude views; fade houses once their projected diameter is below roughly 1–2 device pixels.

7. **Spatially partition any retained geometry into a few village/facet batches.** This restores frustum/horizon culling at the cost of several more draws; 5–20 cheap draws are preferable to shading a planet-scale invisible batch.

8. **MultiMesh cube archetypes.** Useful only if keeping shared low-poly archetypes. MultiMesh is ideal for cards, but it does not cure excessive cube geometry or provide per-house culling by itself.

9. **Static per-facet bake.** Low leverage for the reported stationary problem: cached house bakes and zero stationary rebuilds already provide most of its benefit. Spatial static batches could still help culling.

10. **Off-thread decimation/merge.** Worthwhile only for entry spikes. Resource creation and GPU commit still return to the main thread, and it cannot fix the persistent visible-mesh cost.

The most telling immediate code change to test after the visibility A/B is not another triangle-cap adjustment: it is eliminating the always-running shell dither. The final architecture, however, should be impostors plus a very small parametric near bridge—not coarser voxel houses.
tokens used
120,874
My conclusion: the persistent jerk is much more likely in the rendering path than in structure baking or mesh upload—but “240k fragments running `voxi_shade`” is not quite what the code does. The current tier is expensive through a combination of duplicated vertex work, disabled backface culling, lack of spatial culling, and—in the altitude shell—a surprisingly costly fragment-dither shader.

I analyzed commit `e911a64` from `feat/voxiverse-fartier-walk`, since the requested brief and sources are in that worktree rather than the currently checked-out branch.

## 1. GPU versus main thread

Most likely: GPU/rendering-bound while the mesh remains visible. Low probability that bake/rebuild is responsible for the stationary persistent jerk.

The decisive evidence is:

- Stationary rebuild count is zero.
- The measured merge/upload is only about 2 ms and occurs on membership changes, not continuously.
- The jerk persists every frame.
- The tier adds 80k triangles represented by roughly 240k non-indexed vertices.
- The whole batch is always considered potentially visible because of the enormous `custom_aabb`.
- `cull_disabled` prevents hardware backface rejection.

Two important corrections from the implementation:

1. The ordinary structure shader calls `voxi_shade` in `vertex()`, then passes a flat color to an almost empty fragment shader. It is therefore primarily a vertex cost, not a `voxi_shade` fragment cost. See [facet_far_structures.gd:90](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_structures.gd:90).

2. In the 256–600 altitude shell, the tier swaps to `_SHELL_SHADER`. That shader evaluates a `sin(dot(...))` screen-space dither in every fragment—even below altitude 520, where `tier_fade` is exactly 1 and no pixel can be rejected. See [facet_far_structures.gd:130](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_structures.gd:130). This is a credible explanation for why reducing geometry by 70% did not cure the jerk: roughly the same house-covered pixels still execute the expensive fragment hash.

So I would describe it as “GPU/render workload bound,” with the exact bottleneck potentially shifting:

- Surface: duplicated vertex shading/rasterization is the stronger suspect.
- Altitude 256–600: fragment dither plus overdraw is a strong suspect.
- Not bake/upload while stationary.

### The single cheapest definitive experiment

Add one local, relay-free debug toggle that changes only:

```gdscript
_mi.visible = not _mi.visible
```

Run it after all houses have baked, with the camera frozen and `_mesh` retained. Toggle automatically every 3–5 seconds and show the state on screen so no relay polling is required.

This preserves:

- Registry scans
- Probe passes
- Cached bakes
- Mesh memory
- All other world systems

It removes only submission/rasterization of the structure mesh.

If jerk follows visibility immediately, the bake/rebuild hypothesis is eliminated. If jerk continues while hidden, inspect the periodic structure step/probe path. Given one draw call, a visibility-correlated result is effectively a rendering/GPU verdict for the dichotomy posed.

I would run this before developing any redesign.

## 2. Buildings should get an impostor tier

Yes. Player-scale procedural houses should not remain voxel-surface meshes throughout `[near radius, 2400]`.

I would use a hybrid ladder:

```text
near voxel mesh → tiny parametric house mesh → directional impostor → roof pixels / culled
```

The near voxel tier remains exact. A very small gabled-box mesh can cover the short transition where a house is tens of pixels tall. Beyond that, use impostors.

### Concrete `FacetFarStructures` design

Retain the class’s existing:

- Registry query
- Distance membership
- Near-presence handoff
- Revision tracking
- Band fingerprint and hysteresis

Replace `_mesh`, `_mi`, `_baked`, `_ensure_bake()` and `_commit_mesh()` with:

- One shared indexed mesh: one vertical quad plus one horizontal roof cap, four triangles per house.
- One `MultiMeshInstance3D`.
- One RGBA atlas.
- One instance record per emitted house: radial basis/origin, width, height, archetype index and fade.

The vertical quad should be cylindrically camera-facing in the vertex shader: radial-up remains the house’s vertical axis while the horizontal axis faces the camera. The roof cap remains tangent to the planet.

Use eight azimuth views per archetype. Compute the view sector in the shader from `camera_pos`, the instance origin and its local house axes; this avoids rebuilding the instance buffer whenever the camera rotates.

The generated houses have fixed materials and a small parametric style space. Canonicalize them to approximately:

- Flat versus gabled roof
- Wall height 3 versus 4
- Four door orientations
- Actual width/depth supplied as instance scale

That is 16 visual archetypes. At eight side views plus one top view, 144 tiles. A 32×32 RGBA8 atlas is only about 576 KiB. It can be CPU-rasterized from `StructureGen` like the tree atlas, or preferably imported as a prebaked asset.

For 81 house instances:

- 324 triangles with side+cap, versus up to 80,000
- About 5 KiB of 16-float instance data
- One draw
- No per-house O(volume) decimation
- No mesh concatenation

The far-tree card machinery already demonstrates the viable WebGL2 pattern: indexed shared card, atlas, custom instance data and alpha scissor. See [facet_far_trees.gd:1125](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_trees.gd:1125) and [facet_far_trees.gd:1448](/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats/godot/src/world/facet_far_trees.gd:1448).

The MultiMesh color bug is not a reason to avoid this design. Tree cards are already safe because their shader does not read vertex `COLOR`. Either do the same, or enable instance colors and explicitly write white as the existing color fix does.

One caveat: Godot does not give useful per-instance frustum culling for one giant MultiMesh; its AABB is culled as a whole. With only a few hundred billboard triangles, that is acceptable. If instance counts grow substantially, split them into spatial village/facet batches.

Estimated engineering cost:

- Basic functional impostor tier: 2–4 focused days.
- Directional atlas, transitions, visual validation and gates: roughly one week.
- Runtime atlas generation: likely tens of milliseconds once; imported atlas: effectively zero runtime generation cost.

## 3. Decimation

`STRUCT_TARGET_RES=16` is wrong for this tier. It is a target that is larger than the objects it is supposed to simplify, so it often requests no simplification at all.

Even `STRUCT_COARSE_RES=8` still leaves every house with maximum extent ≤8 at pitch 1. That explains why a large aggregate triangle reduction does not mean every visible house became cheap.

If the cube mesh remains temporarily, use:

```text
pitch = max(2, next_power_of_two(ceil(max_extent / 6)))
```

For current 5–11-block houses, that normally means pitch 2 and a silhouette roughly 3–6 coarse cells across. I would also lower the aggregate cap into the 8–12k-triangle range.

But this is only an interim fix. OR-occupancy cube decimation is poor for one-block walls: it dilates them, destroys openings and still emits many coplanar voxel faces. A procedural house already has known walls, roof, door and dimensions; generating a 30–80-triangle parametric shell is both cheaper and visually better than coarse voxel occupancy.

Ultimately LOD should be screen-space driven, using the existing `ObjectLod` idea:

- Exact near voxels while close.
- Parametric shell while silhouette error would exceed about one device pixel.
- Directional card once its approximation error is sub-pixel or nearly so.
- Far-skin roof stamp or disappearance when the complete house is only a few pixels.

## 4. What was missed

The largest omissions are:

- `_SHELL_SHADER` runs a transcendental dither hash on every covered fragment even when `tier_fade == 1`.
- `cull_disabled` is unnecessary for correctly wound closed house geometry and increases raster work.
- The mesh is non-indexed: four logical quad vertices become six shaded vertices.
- Face culling is not greedy meshing. Every exposed voxel face remains its own quad; adjacent coplanar faces are never merged.
- One enormous `custom_aabb` plus one planet-scale batch defeats useful frustum culling. Houses behind the camera or horizon can still consume vertex work.
- The candidate statement that MultiMesh “can be GPU-culled” is misleading here: the renderer generally culls the MultiMesh as one object, not each house.
- The existing far-skin roof representation could take over earlier for steep/top-down views instead of retaining 3D houses until a fixed altitude.
- Lazy shader/pipeline compilation might explain a one-time first-appearance hitch, but cannot explain the continuing stationary jerk.

## Ranked recommendations

1. **Run the resident-mesh visibility A/B.** Cheapest definitive diagnosis; no relay and no reload/location variance.

2. **Replace the distant cube tier with directional impostors, selected by screen size.** Highest architectural leverage and best fit for WebGL2/WASM.

3. **Immediately fix the existing shell shader:** use a no-dither material while fade is 1, and use a cheap 4×4 Bayer pattern—not `sin()`—only during the 520–600 transition. Also enable backface culling where winding permits.

4. **Add a tiny parametric house-shell tier between near voxels and impostors.** Better fidelity and far fewer triangles than voxel decimation.

5. **Until that lands, force pitch ≥2, target roughly six cells, greedy-merge faces, and index the mesh.** This should reduce vertex count by much more than changing `STRUCT_TARGET_RES` alone.

6. **Use screen-space culling and the existing far-skin roof pixels earlier.** Especially effective for top-down altitude views; fade houses once their projected diameter is below roughly 1–2 device pixels.

7. **Spatially partition any retained geometry into a few village/facet batches.** This restores frustum/horizon culling at the cost of several more draws; 5–20 cheap draws are preferable to shading a planet-scale invisible batch.

8. **MultiMesh cube archetypes.** Useful only if keeping shared low-poly archetypes. MultiMesh is ideal for cards, but it does not cure excessive cube geometry or provide per-house culling by itself.

9. **Static per-facet bake.** Low leverage for the reported stationary problem: cached house bakes and zero stationary rebuilds already provide most of its benefit. Spatial static batches could still help culling.

10. **Off-thread decimation/merge.** Worthwhile only for entry spikes. Resource creation and GPU commit still return to the main thread, and it cannot fix the persistent visible-mesh cost.

The most telling immediate code change to test after the visibility A/B is not another triangle-cap adjustment: it is eliminating the always-running shell dither. The final architecture, however, should be impostors plus a very small parametric near bridge—not coarser voxel houses.
