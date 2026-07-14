# COSMOS-FACETED-CARVE — mesher-side per-facet junction bevels (FP-CARVE milestone)

## Why this milestone exists

FP2/FP3 render seam **junction bevels** as pre-baked `VoxelBlockyModelMesh` models,
one per `(material, slot, q)`. That cannot be made per-facet on a crossing:

- The bevel's clip plane lives in each facet's **lattice frame**, and the cube-sphere
  warp shears facets so differently that the per-slot seam orientation spans **~53°**
  across the planet (proven: `verify_faceted` `_gate_bevel_reuse`). A single manifest
  reused across facets visibly mis-tilts and **cracks** most seams.
- Per-facet models would need a **per-facet re-bake**, but `VoxelBlockyLibrary.bake()`
  is **all-or-nothing** (~13 s web GL-sync stall — patch 0002) and **append-only**, so
  a per-crossing re-bake stalls and accumulation leaks.
- A dynamic overlay mesh can only **add** geometry — it can't **carve** the voxel
  field's cubes into a bevel.

**The fix: move the junction clip from bake-time to mesh-time.** Have the C++ blocky
mesher clip junction cells on the fly against the **frozen active-facet seam planes**,
instead of looking up a pre-baked model. Then a crossing just re-pushes ~64 floats to
the mesher (instant, no bake, no leak, no stall), and every facet renders its **exact**
per-facet bevel. This is the same architecture patch 0003 (`set_cosmos_bake`) already
established for near-field geometry — a frozen per-epoch params blob under
`_parameters_lock` + pure-arithmetic C++ that mirrors proven GDScript.

Net result also **removes** the 1152-model junction bake (→ ~15 plain carve cubes), so
startup gets *faster*, not slower.

## The precedent (patch 0003, reuse verbatim)

`docker/engine/patches/godot_voxel/0003-cosmos-near-bake.patch` already:
- adds `meshers/blocky/cosmos_bake.h` — a `CosmosBakeParams` blob + inline pure-math
  transforms (a **direct transcription** of GDScript, gate-proven `== ` the GDScript);
- adds `VoxelMesherBlocky::set_cosmos_bake(Dictionary)` — parses a flat-packed blob and
  stores it in `_parameters.cosmos` under `_parameters_lock` (worker-safe immutable copy);
- reads it in the build loop to transform emitted vertices.

FP-CARVE is a sibling patch **0004** with the identical shape.

## Design

### 1. `meshers/blocky/facet_carve.h` (new, pure arithmetic)

Mirror of `FacetAtlas` clip math, C++, no topology logic (all numbers pushed from
GDScript):

```
struct FacetCarveParams {
    bool  enabled = false;
    float plane[4][4];   // 4 seams (E/W/N/S) × (A,B,C,D) — the active facet's own-side ridge planes,
                         // in LATTICE coords: own(x,y,z) = A·x + B·y + C·z + D ≥ 0 is interior
    // voxel-index → lattice mapping (faceted renders at identity; carries the floating-origin offset):
    long  origin[3];     // add to the block-local voxel index to get the lattice (x,y,z) the planes use
};
```

Inline functions (each a 1:1 transcription of the GDScript already gate-proven in
`FacetAtlas`, so no new geometry logic can go wrong):
- `facet_cell_state(p, x,y,z) → {air, straddle_mask}` — mirror `cell_seam_state` (min/max
  of each plane over the 8 cube corners → air-masked / interior / straddling slots).
- `facet_clip_cube(p, x,y,z, straddle_mask, out)` — mirror `junction_prism_verts` +
  `shape_mesh._build_junction`: Sutherland–Hodgman clip the unit cube by the straddling
  planes, emit faces (the surviving cube faces + the tilted cut cap). LOCAL cell coords.

### 2. `VoxelMesherBlocky::set_facet_carve(Dictionary)` (new setter)

Verbatim shape of `set_cosmos_bake`: parse the flat blob, store `_parameters.facet_carve`
under `_parameters_lock`. Called from `module_world` on setup **and** on every crossing —
cheap (64 floats + 3 longs), no bake. `enabled=false` (non-faceted) → zero overhead.

### 3. Carve-sentinel ARIDs (GDScript, `module_world.gd`)

- Bake **one plain-cube model per material** into a reserved `_carve_arid[material]` range
  (~15 models, once) — the mesher overrides their geometry; they carry only the material's
  texture/atlas mapping (reuse `_add_cube`).
- The worker's junction exit writes `_carve_arid[mat]` for a straddling cell (NOT a
  `(mat,slot,q)` ARID — slot/q are derived at mesh time from the cell position + frozen
  planes). Air-masked cells still write 0; interior cells still write the full cube.
- **Delete** `_build_junction_manifest` (the 1152-model bake) and the FAM-kind-2 baked-model
  lookup arm in the worker — the carve replaces both.

### 4. Mesher build-loop injection (`voxel_mesher_blocky.cpp` — the hard part)

At the per-cell model-emit site (`generate_blocky_mesh`, the
`for surface_index < model_surface_count` loops, ~L337/472): if the cell's type is a
carve-ARID and `facet_carve.enabled`:
- compute `facet_cell_state`; `air` → emit nothing (already masked upstream, defensive),
  `interior` → emit the material's full cube (fast path), else → `facet_clip_cube` and emit
  the clipped geometry with the material's atlas UVs (taken from the material's cube model).
- **Side-culling**: the cut face (toward the masked-air neighbour) is never culled — the
  neighbour is AIR, which the mesher already never occludes. Axis-aligned carve faces reuse
  the cube's side pattern where the clip leaves them full, and are dropped where the clip
  removes them. This cull integration is the milestone's #1 complexity.

### 5. Physics / collision — UNCHANGED

`WorldManager._occ_span` and `GroundCollider` already use `FacetAtlas.own_dist` (exact,
per-facet), so render==collision holds automatically once render becomes exact too. No
GDScript physics change.

## Stages & gates

| Stage | Work | Gate |
|---|---|---|
| **C1** | `facet_carve.h` (params + clip arithmetic) | C++↔GDScript parity: the C++ clip verts == `FacetAtlas.junction_prism_verts` to 1e-4 over a cell sample (a `cosmos_debug`-style const method + a headless verify, mirroring `verify_cosmos_bake_mirror`) |
| **C2** | `set_facet_carve` setter + `_parameters.facet_carve` + GDScript push | the blob round-trips (debug getter == pushed values) |
| **C3** | mesher build-loop carve emission + side-culling | a carved cell's emitted mesh == `shape_mesh._build_junction` for that facet's exact plane |
| **C4** | GDScript wiring: `_carve_arid` cubes, worker writes carve-ARIDs, `set_facet_carve` on setup/cross, delete the bevel manifest | `verify_faceted` still green; startup manifest drops ~1152 models |
| **C5** | live: bevels correct on the spawn facet AND after a crossing; render==collision; crossing re-push instant | deploy; walk across a seam and confirm both facets show correct bevels, no crack, no per-cross stall |

## Risks & cost

- **C++ build cadence** — every C++ iteration is a `scripts/build.sh` (custom Godot editor
  **+ Web export templates**, the emsdk 3.1.64 pin) at ~24 min cold / minutes warm, then
  `export-web.sh` + `deploy.sh`. This dominates the milestone's wall-clock. Mitigation:
  keep **all** geometry logic in `facet_carve.h` as pure math transcribed 1:1 from the
  gate-proven GDScript (the cosmos_bake.h discipline), so C++ iterations are for the
  build-loop wiring only, not for getting geometry right.
- **Mesher build-loop complexity (#1 risk)** — `generate_blocky_mesh` is the trickiest
  code in godot_voxel (side-pattern occlusion, per-surface atlas UVs, the fluid/waterlog
  passes). Injecting dynamic per-cell geometry + cull there is the real work. Keep the
  carve path a clean branch that falls back to the plain cube on any uncertainty (never a
  hole), exactly like the existing ARID fallbacks.
- **Crest + corner cells** — a junction cell that is also a surface (slope-top) cell must
  clip the slope geometry, not just a cube; corner cells clip by 2 planes. Both already
  handled by the GDScript clip (`junction_prism_verts` does ≤3 planes; the crest composite
  is the `_make_composite_model` precedent) — transcribe the same into `facet_carve.h`.
- **Web-template rebuild** — because it changes the mesher, the milestone requires a full
  `build.sh` (not just an export), and the `module_in_web=yes` path must still link/run
  (the COOP/COEP threaded gate). The auto-fallback to stock templates would silently drop
  the carve on web, so the build must be verified `module_in_web=yes` after.

## Why carve is the right (and only cheap) answer

- **Baked per-facet models** → per-facet re-bake → 13 s stall or leak. Rejected.
- **Reference-facet reuse** → 53° orientation variation → cracks. Proven invalid.
- **Dynamic overlay** → can only add geometry, can't carve cubes. Rejected.
- **Mesher-carve** → the clip is computed per-cell at mesh time from the *live* seam
  planes, so it is exact on every facet, a crossing is a 64-float re-push, and there is no
  bake, no leak, no stall. It also deletes the 1152-model junction bake (faster startup).

The cost is a C++ engine patch on the hardest file in godot_voxel with a ~24 min build
cadence — hence its own milestone rather than an FPx GDScript stage.
