# COSMOS-OBJECT-LOD — physical-object far-render + LOD ladder (DESIGN)

Authoritative design for rendering **discrete physical objects** (chopped-tree / dropped-block
`VoxelBody`s today; ships, stations, asteroids later) at distance with an automatic LOD ladder and an
angular-size-driven LOD-select + cull. Synthesises `docs/RESEARCH-OBJECT-LOD.md` (Fable research) and
`docs/RESEARCH-OBJECT-LOD-REVIEW.md` (Fable adversarial review) plus the four locked user decisions below.
Both Fable passes + an independent code spot-check agree the core is grounded in shipped machinery.

## Problem
Detached `VoxelBody`s have **no far representation** — they vanish the instant they leave near-render range
(the far-structure baker only handles planet-attached villages; `body_lod.gd` is whole-celestial-body LOD).
A large part of the game is space travel: distant stations / ships / asteroids must stay visible down to a
speck, so objects need a size-driven LOD ladder and a principled "when to stop drawing" rule.

## Locked user decisions
1. **General framework now** — a `PhysicalObjectFarRender` subsystem validated on today's `VoxelBody`s;
   ships/stations/asteroids plug into the same path (a registry API) later.
2. **Sub-pixel → fade to a dot** — the ladder terminates in a cheap beacon dot that persists far past the
   last mesh; space objects are never hard-culled, only clamped to a 2 px dot.
3. **Auto-scaling budget (small→large)** — self-calibrating VRAM budget, never-OOM is the hard ceiling.
4. **Dynamic per-frame transform** — far reps follow each object's live transform (movers + tumblers).

## The law (reuse `body_lod.gd` verbatim — CONFIRMED at body_lod.gd:96-113, :66-68, :135-144)
All lengths in **blocks**, all screen quantities in **device px** (DPR-corrected once at init + on resize):

```
K_px      = viewport_height_device_px / (2·tan(fov/2))     # px per radian; recompute on resize AND zoom
p(r,d)    = 2·r / d · K_px                                  # object's projected disc Ø in device px
sse(e,d)  = e / d · K_px                                    # a rung's silhouette error in device px
```

- `r` = object bounding radius (½·extent). `e` = the rung's max silhouette error (below).
- **fov MUST be the live `Camera3D.fov`** — NOT BodyLod's `LOD_NOMINAL_FOV_DEG=70` constant (review SHOULD-FIX)
  — so a telescope/zoom promotes distant objects with no LOD-specific code.
- Thresholds (mirror BodyLod): `TAU_OBJ = 1.0 px` (rung SSE), `P_POINT = 2.0 px` (dot floor),
  `HYST = 0.25` one-sided (promote-only knee → sub-pixel, no-pop).

## The ladder (built almost entirely from shipped machinery)
Pick the **coarsest rung whose `sse ≤ TAU_OBJ`**; closed-form switch distance `d = e·K_px / TAU_OBJ`.

| Rung | Representation | `e` (silhouette err) | Source |
|------|----------------|----------------------|--------|
| L0   | full `VoxelBody` mesh | 0 (exact) | the body's own mesh (hidden by the tier, not a copy) |
| L1..Lk | `StructDecimator` mesh at pitch `c=2^k` | ≈ `c` | `struct_decimator.gd` reuse, worker-baked |
| C    | camera-facing cross+cap cards (1 MultiMesh) | ≈ `r/2` | far-tree card pattern (`facet_far_trees.gd`) |
| D    | unlit dot (1 MultiMesh) | ≈ `r` | new; clamps to `P_POINT`, brightness ∝ `p²` |

- **Auto LOD-step count from size**: mesh steps `= clamp(floor(log2(extent)), 0, MESH_STEP_MAX)`. A 2-block
  chip → 0 mesh steps (L0→C→D); a 10–30-block object → ~2–3 steps; a 512-block station → ~8 (capped).
- **Card basis = camera-facing, not body rotation** — a body tumbling at ≤20 px is unreadable and edge-on
  cards flicker (research). Body spin is dropped once it's card-sized.

## Object classes (cull policy)
- **CLASS_DEBRIS** (`VoxelBody`s): dither-fade out below `0.5 px` (they are ephemeral clutter).
- **CLASS_SPACE** (ships/stations/asteroids): **never hard-culled** — clamp to a `P_POINT` (2 px) beacon dot,
  brightness ∝ `p²` (photometrically correct for a sub-pixel emitter — review CONFIRMED), with
  **clamped-distance angular-size-preserving placement** (no reversed-Z / log-depth exists on gl_compat).

## Amendments from the adversarial review (MUST-FIX, folded in)
1. **VoxelBody L0-hide is not free.** `_rebuild()` (voxel_body.gd:633-663) `queue_free()`s every
   `MeshInstance3D` child and recreates them `visible=true`, so a latched hide is silently undone by any
   `break_cell`/`add_cell`. → add a **flag-gated `_rev` counter** bumped in `_rebuild()` + the tier
   **re-applies L0 visibility on rev change**; `id = get_instance_id()`; `is_awake()` exists (:407). The
   hook is inert unless the object-LOD registry owns the body → byte-off holds.
2. **Frame/space mapping.** Debris transforms are ActiveFrame-lattice (voxel_body.gd:130-137); the far tier
   under `FacetFarRing` inherits ring/SN3 scaled space. A raw `transform→MultiMesh row` copy misplaces cards
   (the #131 frame-weld class). → explicit map of body world-transform into the tier's parent space +
   facet-fold gate. (Same PLAY↔CELL-style frame discipline that just bit chop_tree — audit every seam.)
3. **Budget → boot-time proxy ladder, DEMOTE-ONLY.** WebGL2 can't read VRAM and over-alloc = context loss,
   so grow-until-pressure is **rejected** (violates never-OOM). Instead: pick a ledger tier
   `∈ {2,4,8,16} MB` at boot from proxies (`WEBGL_debug_renderer_info` GPU string + `navigator.deviceMemory`
   + `hardwareConcurrency`); **hard compile-time max 16 MB** the gate proves the worst state at; mid-session
   adaptation may **only demote**. This realises decision (3) safely. Priority = `p` descending (one sort
   serves both budget eviction and rung selection).
4. **Space-dot planet occlusion.** A clamped-distance beacon behind a planet would shine through terrain. →
   analytic ray-sphere test vs Earth/Moon per row (precedent `cosmos_sky.gd:415-433 occlusion_factor`).
5. **Worker bake safety.** `cells` store **packed** values (voxel_body.gd:89) and mutate live. → snapshot
   cells on the main thread, `CellCodec` mat-decode in the worker sampler; cache LRU by `(id, rev, pitch)`.

SHOULD-FIX also folded: cap **unique card tiles ~256** with an archetype-tinted fallback (a per-rev atlas at
the 2048 instance cap would be ~8 MB of tiles alone); regenerate the worked example table (chip row conflates
the `p=2 px` point with the SSE card-onset) before it seeds gate expectations.

CONFIRMED-CLEAN (no action): merged-ArrayMesh rejection for movers (facet_far_structures.gd:5-11 pre-bakes
verts ring-local), the `set_instance_transform`-after-`set_buffer` no-op trap (facet_far_trees.gd:704-706 →
**whole-buffer `set_buffer` only**), stride-20 colors+custom INSTANCE law (:375-378), brightness ∝ p², P0-first
staging, no `FP_OBJ_LOD` namespace collision.

## Staging (every stage default-OFF, byte-identical, FLAT `verify_feature.gd` 6042/0)
- **P0 `FP_OBJ_LOD`** — `object_lod.gd`: the pure-static law (k_px, p, sse, rung select, switch distances,
  size→step-count, boot proxy→budget-tier as a pure function of proxy inputs) + `verify_object_lod.gd` gate.
  **No renderer change** — the safe first byte-off step (BodyLod precedent).
- **P1 `FP_OBJ_LOD_DEBRIS`** — object registry + card & dot MultiMesh tiers + flag-gated VoxelBody rev/hide
  hook + dormant-snapshot / awake-lazy-rewrite (skip when screen-motion < 0.5 px) + frame mapping.
- **P2 `FP_OBJ_LOD_MESH`** — `StructDecimator` mesh rung for `extent ≥ 16` (worker-baked, snapshot + decode,
  LRU `(id,rev,pitch)`).
- **P3 `FP_OBJ_LOD_SPACE`** — CLASS_SPACE no-cull beacon dots + ray-sphere planet occlusion +
  clamped-distance placement + ship/station registry API.
- **P4 (deferred)** — offline octahedral impostor atlas for hero ships only if P2 proves insufficient
  (runtime viewport bakes are too risky on threaded web).

## Verification
Per-stage `verify_*.gd` gate + FLAT 6042/0 byte-off. Live A/B: fly up and confirm a felled canopy / a test
object renders **mesh → decimated → cards → dot**, holds a beacon at extreme range, dither-fades (debris) or
clamps (space), and occludes correctly behind a planet — proven by screenshots + `query_box` diffs, not
inference (the lesson from chop_tree).
