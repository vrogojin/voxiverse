# VOXIVERSE — Sub-Voxel Partial-Fill Shapes & Terrain Smoothing (DESIGN)

> **⚠ Partially superseded — read alongside the authoritative reconciliation.**
> `docs/VOXEL-DATA-STRUCTURE.md` supersedes this doc's **§3 cell encoding** (shape+anchor
> move out of the packed material int onto a separate 16-bit **modifier** axis; `ShapeCodec`
> splits — packing → `CellCodec`, geometry/physics math stays in `ShapeCodec` re-keyed to the
> 16-bit modifier — see VDS §3.3 & §13.1) and the **§4.1 `lib_id = 1+(mat−1)·S+shape` formula**
> (deleted, incl. the 404-material cap; replaced by lazily-allocated **ARIDs**, VDS §8.1).
> The merged analytic-physics contract (material-solidity gate before shape tests) is normative in
> `docs/INTEGRATION-DECISIONS.md` §3. The shape set, mass/fill-fraction, and contact-area math here
> stand as designed.

Status: **design, not implemented**. Branch `feat/voxiverse-sim-extensions`.

Voxels may be partially filled with wedge/slab/corner shapes of their material so
the terrain surface smooths into ramps instead of hard stair-steps. Partial cells
carry **reduced mass** (`density × fill_fraction` — the `VoxelState.density` field
exists for exactly this) and attach to neighbours **only through overlapping
filled surface area** on the shared cell face (zero overlap ⇒ no joint ⇒ no
support). This document specifies the shape set, the cell encoding, both render
paths, the analytic physics, mass/contact math, deterministic terrain smoothing,
dig/place semantics, and the verify plan.

Sibling workstreams (in-flight, docs may not exist yet — every assumption about
them is flagged inline with **SEAM**):

* `docs/STRUCTURAL-INTEGRITY.md` — owns the attachment/durability *model*. We
  feed it a **contact-area factor** and a **reduced mass**; we do not define
  strength math here.
* `docs/WORLDGEN-CATALOG.md` — owns the material catalog and worldgen surfaces we
  smooth.
* `docs/RUNTIME-MATERIAL-STREAMING.md` — owns global/local material ids. Our rule:
  **shape+orientation live OUTSIDE the material id**, in separate high bits.

---

## 1. Goals & non-goals

Goals:

1. A cell can hold a **partial-fill shape** of one material (not just full cube /
   air), sufficient to represent smooth slopes, half-steps, and diagonal terrain.
2. **Mass** of a partial cell = `density × fill_fraction`; durability/attachment
   scale with the shape (via contact area, consumed by structural integrity).
3. **Attachment only via matching filled surfaces**: the joint between two cells
   is proportional to the *overlap area* of their filled cross-sections on the
   shared face; zero overlap ⇒ no joint.
4. Preserve the three architectural rules (root `CLAUDE.md`): one cell query
   (rule 1), sim-not-geometry (rule 2), two render paths one behaviour (rule 3),
   and the analytic (collider-less, web-cheap) physics model.
5. Full backward compatibility: a full cube is the default shape; every existing
   stored/generated plain block id keeps meaning "full cube of that material".

Non-goals:

* Not marching-cubes / not a signed-distance-field surface (see §4.4 for why the
  Transvoxel alternative is rejected).
* No overhang smoothing (cave mouths / cliff undersides stay blocky); smoothing
  targets the walkable heightmap surface.
* No per-shape textures/UV art pass (shapes reuse the material's existing
  texture, planar-mapped).

---

## 2. Shape model: quantized corner heights (the key idea)

Instead of a zoo of named primitives each with bespoke math, every partial shape
is parameterized by **four corner heights** on the cell's top surface, quantized
to half-blocks, plus an **anchor**:

* `c00, c10, c11, c01` ∈ {0, 1, 2} — heights in **half-block units** (0, ½, 1) at
  the four column corners of the cell, in the order (x0,z0), (x1,z0), (x1,z1),
  (x0,z1).
* `anchor` ∈ {BOTTOM, TOP} — BOTTOM: material fills from the cell floor **up to**
  the surface `H(x,z)`; TOP: the same shape mirrored vertically (material hangs
  from the ceiling **down to** `1 − H(x,z)`), which supplies top slabs and
  ceiling ramps for building.

The surface `H(x,z)` over the cell is **piecewise planar**: the unit square is
split along one diagonal into two triangles, and `H` is the linear interpolation
of the three corner heights on each triangle.

**Diagonal rule (deterministic, rotation/mirror-consistent):** split along the
diagonal whose two corner heights sum larger — `sA = c00 + c11` vs
`sB = c10 + c01`; if `sA >= sB` use the (0,0)–(1,1) diagonal, else (1,0)–(0,1).
On ties the two triangulations enclose *identical volume* (proof: the volumes
differ by `(sA − sB)/12`, see §6), so mass is well-defined regardless; the tie
break just fixes the render fold. This rule makes every rotation of a shape have
the same volume — a corner block does not change mass when rotated (a fixed
diagonal would make it 1/3 vs 1/6 depending on which corner is raised; that
asymmetry is the reason the max-sum rule exists).

Why this model instead of an enumerated primitive list:

* It **is** a discrete, enumerable set — `3^4 × 2 anchors = 162` codes, of which
  every named primitive the requirements ask for is a member (table below). This
  is *not* marching cubes: shapes are discrete, axis-aligned, catalogued, and
  each bakes to a fixed small mesh.
* **Rotation is corner permutation** — no separate orientation field, no
  orientation⇄shape consistency bugs. Rotating a wedge 90° = cyclically shifting
  `(c00, c10, c11, c01)`.
* One closed-form family replaces per-shape case analysis: *one* surface-height
  function, *one* volume formula, *one* face-profile/contact formula cover every
  shape, which is what keeps the analytic physics and both meshers provably in
  agreement.
* It naturally includes the *half-step* shapes (rise ½ over a cell) that gentle
  terrain (slopes ≪ 1 block/cell) needs — a wedge-only set would leave most of
  the map stair-stepped anyway.

### 2.1 Canonical named shapes (subset of the 162)

Corner tuples are BOTTOM-anchored representatives; each has 4 yaw rotations
(cyclic shifts) unless symmetric. `V` = fill fraction from the §6 formula.

| Name | (c00,c10,c11,c01) | Fill V | Rotations | Notes |
|---|---|---|---|---|
| FULL (cube) | (2,2,2,2) | 1 | 1 | the default; shape code 0 |
| SLAB_BOTTOM | (1,1,1,1) | 1/2 | 1 | half-block floor |
| SLAB_TOP | TOP-anchor (1,1,1,1) | 1/2 | 1 | half-block ceiling |
| RAMP (wedge) | (2,2,0,0) | 1/2 | 4 | full-rise ramp; the "vertical wedge" |
| HALF_RAMP_LO | (1,1,0,0) | 1/4 | 4 | rise 0→½ (gentle slope, lower half) |
| HALF_RAMP_HI | (2,2,1,1) | 3/4 | 4 | rise ½→1 (gentle slope, upper half) |
| CORNER (outer) | (2,0,0,0) | 1/3 | 4 | corner "tetra" (diagonal through peak) |
| ANTICORNER (inner) | (2,2,2,0) | 5/6 | 4 | inner corner of two meeting ramps |
| HALF_CORNER | (1,0,0,0) | 1/6 | 4 | true tetrahedron volume |
| HALF_ANTICORNER | (1,1,1,0) | 5/12 | 4 | |
| RIDGE (diag) | (2,0,2,0) | 2/3 | 2 | diagonal crest |
| CEIL_RAMP | TOP-anchor (2,2,0,0) | 1/2 | 4 | ramp hanging from ceiling |

The requirement's "horizontal wedge" (a vertical diagonal wall slice, e.g. a
prism that is full-height but triangular in plan) is **not** in this family and
is deliberately deferred: it cannot be walked on differently from a full cube,
contributes nothing to terrain smoothing, and would break the
"columnar occupancy interval" property that keeps the physics analytic (§5).
If building later wants it, it becomes a third anchor family with its own
occupancy function; the encoding reserves bits for that (§3).

---

## 3. Cell encoding

### 3.1 Recommended: one packed int, `block_id_at` becomes a projection

`WorldManager.block_id_at(cell)` stays THE cell query (rule 1) — but the
canonical cell **value** becomes a packed 64-bit GDScript int, and
`block_id_at` returns its low bits. There is still exactly *one* composed
overlay-else-generated query; material and shape are two projections of it, so
they can never disagree.

Bit layout (`ShapeCodec` constants; 25 bits used of 64):

```
bits  0..15   material/block id        (BlockCatalog id; 16 bits)
bits 16..23   corner heights           (c00 | c10<<2 | c11<<4 | c01<<6, each 0..2)
bit  24       anchor                   (0 = BOTTOM, 1 = TOP)
bits 25..31   reserved                 (future: reinforcement, damage, 3rd family)
```

Semantics and normalization (enforced by `ShapeCodec.canonical(v)` at every
write — generator output, `place_block`, collapse capture):

* **Shape field 0 (all corners 0, anchor 0) means FULL CUBE.** Every existing
  plain id already stored in `_edits`, produced by `generated_block`, or held in
  `VoxelBody.cells` is therefore already a valid packed value meaning "full cube
  of that material" — zero migration, zero behaviour change.
* Whole value 0 = AIR (air never carries a shape).
* All-corners-0 with a nonzero shape-field encoding is normalized to AIR; a
  BOTTOM shape with all corners 2 is normalized to shape 0 (FULL). TOP anchor
  with all corners 2 normalizes to FULL too. This keeps every geometric shape a
  *unique* int (needed for equality tests and the mesher keying).

New/changed API (all in `WorldManager` + a new `src/world/shape_codec.gd`):

```gdscript
# ShapeCodec (static, pure — the single source of shape math)
static func mat(v: int) -> int:            return v & 0xFFFF
static func shape(v: int) -> int:          return (v >> 16) & 0x1FF
static func pack(mat: int, shape: int) -> int
static func canonical(v: int) -> int
static func corners(v: int) -> Vector4i    # (c00, c10, c11, c01), FULL -> (2,2,2,2)
static func is_full(v: int) -> bool        # shape field == 0
static func volume(v: int) -> float        # §6
static func local_top(v: int, fx: float, fz: float) -> float      # §5
static func occupied(v: int, fx: float, fy: float, fz: float) -> bool
static func side_profile(v: int, face: int) -> Vector3i           # §7 (anchor, e0, e1)
static func contact_area(v_a: int, v_b: int, axis: int) -> float  # §7

# WorldManager
func cell_value_at(cell: Vector3i) -> int:      # THE query (packed)
    var e: int = _edits.get(cell, -1)
    if e >= 0: return e
    return TerrainConfig.generated_cell(cell.x, cell.y, cell.z)

func block_id_at(cell: Vector3i) -> int:        # unchanged contract: material id
    return ShapeCodec.mat(cell_value_at(cell))

func cell_solid(cell: Vector3i) -> bool:        # unchanged: any material present
    return block_id_at(cell) != BlockCatalog.AIR
```

`_edits` stores packed values (0 = dug air, as today). `TerrainConfig` gains
`generated_cell(x,y,z) -> int` (packed); `generated_block` remains as
`ShapeCodec.mat(generated_cell(...))` for existing callers.

Call sites that must mask (audit list — everything else keeps calling
`block_id_at` and is untouched by construction): `place_block` id validation
(validate `ShapeCodec.mat`, store canonical packed), `break_terrain` return
(return material for the hotbar, volume separately — §9),
`VoxelBody._has_wood` / mass loop / mesh keying (mask for material, read shape
for geometry), `chunk_mesher._cell_id` (already material via `block_id_at`),
module `set_cell` (translate packed → library id, §4.1).

### 3.2 Rejected alternatives

* **Parallel sparse shape overlay** (`_shapes: Vector3i -> int` beside
  `_edits`): violates the spirit of rule 1 — two dictionaries that must be
  written in lockstep on every break/place/collapse is exactly the "parallel
  notion of what's here" the architecture forbids; a missed write desyncs mass
  from rendering silently.
* **Struct/Dictionary cell value**: GDScript dictionaries per cell are
  allocation-heavy on web, break `==` fast paths, and can't flow through the
  godot_voxel TYPE channel or `VoxelBody.cells` without conversion layers.
* **Shape encoded inside the material id space** (e.g. "grass_ramp_ne" as its
  own BlockCatalog id): explodes the catalog (materials × 162), breaks
  `mass_of`/`name_of`/inventory identity ("a ramp of grass IS grass"), and
  collides head-on with the streaming workstream's id model. **SEAM
  (streaming):** our contract is the inverse — the material id (bits 0..15) is
  the *only* part streaming's global/local palette maps; shape bits pass through
  verbatim. If streaming needs >16-bit global material ids, the shape field
  shifts up — coordinate before either side freezes widths.

---

## 4. Rendering — one geometry source, two paths

A single static geometry builder is the render seam:

```gdscript
# ShapeMesh.build(shape_code) -> {verts, normals, uvs, indices} for the UNIT cell
# Faces: 1-2 top triangles (or bottom, TOP anchor), up to 4 boundary side
# polygons (trapezoids), and the anchor face. Uses ShapeCodec's diagonal rule.
```

Both paths consume `ShapeMesh` output, so "two paths, one behaviour" holds by
construction — there is no second copy of the shape geometry anywhere.

### 4.1 godot_voxel path (`module_world.gd`)

Stay on **VoxelMesherBlocky**; add partial shapes as **`VoxelBlockyModelMesh`**
models (supported in the pinned godot_voxel v1.4.1 — it is the mechanism the
module ships for stairs-like non-cube blocky models; built via ClassDB strings
exactly like `VoxelBlockyModelCube` today, then `library.bake()`).

* **Library layout (dense, derived, asserted):** model id
  `lib_id(mat, shape_index) = 1 + (mat − 1) * S + shape_index`, where
  `shape_index` 0 = FULL (a `VoxelBlockyModelCube`, exactly today's model) and
  1..S−1 enumerate the 161 partial codes in a fixed canonical order owned by
  `ShapeCodec`. `S = 162`. With 5 materials that is 811 models — well inside the
  16-bit TYPE channel (no `VoxelBuffer` depth change), and bake cost is trivial
  (each model ≤ ~10 triangles). The mapping and its inverse live *only* in
  `ShapeCodec.lib_id(v)` / `ShapeCodec.from_lib_id(id)` and are
  roundtrip-asserted at setup (same style as today's `_add_cube` id assert) —
  this remap is the one place the module path could diverge, so it is fenced by
  verify (§10).
* **Generator:** the runtime-compiled `VoxelGeneratorScript` calls
  `TerrainConfig.generated_cell` and writes `ShapeCodec.lib_id(...)` into the
  TYPE channel (today it writes the raw id, which equals `lib_id(mat, FULL)` by
  the layout above — flat ground produces byte-identical buffers to today).
* **`set_cell`:** translate the packed value through `ShapeCodec.lib_id` before
  `VoxelTool.set_voxel`.
* Face culling between partial neighbours uses godot_voxel's baked side-pattern
  matching (the same machinery that culls stairs). It culls a side only when the
  neighbour's side pattern fully covers it; partially-covered pairs keep both
  faces (hidden overdraw inside slopes — cosmetically invisible, noted as
  accepted cost).
* **SEAM (streaming):** the module TYPE channel now carries `mat × shape`
  products. 16-bit caps at ~404 materials × 162 shapes. If
  RUNTIME-MATERIAL-STREAMING introduces per-chunk local palettes for the module
  path, palette entries must be (local material, shape) pairs *or* the TYPE
  channel widened to 32-bit; either works, but it must be decided in that doc.

### 4.2 GDScript fallback (`chunk_mesher.gd`)

* **Tops:** the greedy top-merge keys on `(effective_height, top id)` today; it
  additionally keys on `shape == FULL`. Only full-flat runs merge (identical
  output to today on flat ground); each partial surface cell emits its 1–2 top
  triangles from `ShapeMesh` (world-planar UVs, as the tops use now).
* **Sides:** the per-step wall between columns becomes, for the segment's top
  cell, a trapezoid clipped by the cell's side profile (§7): wall height at the
  two corners = neighbour-profile difference. Full-cube segments below are
  today's quads unchanged.
* **Cull rule for the cell UNDER a partial:** every nonempty BOTTOM-anchored
  shape covers its full bottom face (an all-zero triangle would force `sA = 0 ≤
  sB`, so the max-sum rule never leaves one on a nonempty shape) — so the lower
  cell's top face is culled under any BOTTOM partial or FULL, and emitted only
  under air or a TOP-anchored partial. No holes, no z-fighting under ramps; a
  TOP shape resting directly on ground can coplanar-overlap where its thickness
  reaches 1 — rare, cosmetic, accepted.
* Trees/placed cubes: unchanged; placed *partial* cells emit via `ShapeMesh`
  like the terrain ones.

### 4.3 `VoxelBody` (loose pieces)

* Mesh: `_rebuild()` keys faces by material as today; a partial cell's exposed
  geometry comes from `ShapeMesh` (its boundary-face polygons replace the cube
  quads; interior-face suppression only applies between two FULL cells or where
  the shared-face profiles fully cover each other — use
  `contact_area == full-face` as the cull predicate, one rule for cubes and
  partials).
* Collider: partial cells are **not convex in general** (anticorner/valley
  folds), so each partial cell contributes one `ConvexPolygonShape3D` **per top
  triangle** (triangle extruded to the anchor face — always convex), i.e. ≤ 2
  convex shapes instead of one box. FULL cells keep the BoxShape3D.
* Mass: `Σ density(mat) × volume(v)` (§6) — a detached half-ramp of stone
  genuinely weighs 375 kg, not 1500.

### 4.4 Considered & rejected: smooth mesher (VoxelMesherTransvoxel)

Transvoxel + the SDF channel would give genuinely smooth (non-faceted) terrain,
and godot_voxel ships it. Rejected because it breaks four project invariants at
once: (1) the owner's model is *discrete enumerable partial shapes* with
face-overlap attachment — an SDF isosurface has no discrete faces to compute
contact area on, so requirement 3 has no natural definition; (2) the analytic
physics would need SDF root-finding instead of closed-form per-cell functions,
and the GDScript fallback would need a marching-cubes mesher (large, slow on
web) — "two paths one behaviour" dies; (3) materials on Transvoxel need
texture-array/weights plumbing — a rendering rework far beyond this feature;
(4) the edit overlay's crisp `Vector3i → id` semantics don't map to SDF blending
(digging becomes sphere-subtraction, not block removal). The corner-height set
delivers ~90 % of the visual smoothing (C0-continuous ramps; facets remain,
which fits the game's blocky art direction) at ~10 % of the architectural cost.
Revisit only if the art direction changes to organic terrain.

---

## 5. Analytic physics (stays analytic)

The whole point: no trimesh, closed form, identical across paths. The key
property of the corner-height family (both anchors) is **columnar occupancy** —
at any footprint point `(fx, fz)` inside a cell, the filled set is a single
vertical interval:

```
BOTTOM:  [0, H(fx,fz)]            TOP:  [1 − H(fx,fz), 1]         FULL: [0,1]
```

where `H(fx,fz)` interpolates the corner heights (in blocks, = c/2) linearly on
the triangle containing `(fx,fz)` under the §2 diagonal rule. Everything below
derives from three per-cell functions on `ShapeCodec`:

```gdscript
local_top(v, fx, fz)     # walkable top at that footprint: BOTTOM -> H; TOP -> 1.0 if H > 0 else 0.0; FULL -> 1
occupied(v, fx, fy, fz)  # point-in-fill: interval test above
span(v, fx, fz)          # the (lo, hi) occupancy interval, for headroom checks
```

### 5.1 `floor_under(x, z, feet_y)` — ramps become continuous floors

Same downward scan as today, but the "solid with air above" test becomes
interval-based at the query footprint:

```gdscript
func floor_under(x, z, feet_y) -> float:
    xi = floori(x); zi = floori(z); fx = x - xi; fz = z - zi
    y = floori(feet_y + 0.5)
    while y > -1024:
        v = cell_value_at(Vector3i(xi, y, zi))
        t = ShapeCodec.local_top(v, fx, fz)
        if t > 0.0 and _headroom_clear(xi, zi, fx, fz, y + t):
            return float(y) + t
        y -= 1
    return surface fallback (unchanged)
```

`_headroom_clear` checks that the occupancy intervals of the cells overlapping
`[floor, floor + 1.8]` at `(fx, fz)` are empty in that range (a TOP-anchored
slab two cells up correctly blocks standing; the *same* ramp cell whose top you
stand on trivially passes since its interval ends at the floor). As the player
walks across a ramp cell, `local_top` varies linearly with `(fx, fz)` — the
floor height is a continuous function inside the cell, which is exactly the
smooth walk-up. Cost: unchanged O(scan length), a few multiplies per cell.

### 5.2 `blocked(x, z, feet_y)` — step allowance instead of binary solid

Today any solid cell in the body span blocks. A ramp ahead *is* solid at feet
level, so unmodified `blocked` would forbid walking uphill. New rule: an
obstruction low enough to step onto is not a wall.

```gdscript
const STEP_MAX := 0.55   # allows ramp progression and half-slab auto-step; a full 1.0 ledge still blocks

func blocked(x, z, feet_y) -> bool:
    top = floor_under(x, z, feet_y + STEP_MAX)       # standable height at the target column
    if top - feet_y > STEP_MAX: return true          # rise too big -> wall
    # headroom above the (possibly raised) floor, interval-tested per cell:
    return not _headroom_clear(floori(x), floori(z), frac(x), frac(z), top)
```

The player then snaps feet to `floor_under` as it already does each frame, so
crossing into a ramp cell raises the feet by ≤ slope × step ≈ 0.1 m/frame —
smooth ascent with zero new player-side machinery beyond the constant.
Deliberate side effect: half-slabs (rise 0.5 ≤ STEP_MAX) act as stairs. Full
cubes (rise 1.0) still block, exactly as today on flat/blocky ground.

### 5.3 `aimed_voxel` — DDA with an in-cell surface test

The DDA cell walk is unchanged. On reaching a non-FULL, non-air cell, instead of
"hit at the cell boundary", run a closed-form in-cell test. **Completeness
argument:** every boundary face of a corner-height shape lies either *on* the
cell's own boundary (sides, anchor face) — covered by testing occupancy at the
ray's entry point `t_in` — or on the 1–2 surface triangles — covered by two
ray/plane tests. There are no other surfaces, so:

```gdscript
func _ray_vs_partial(v, cell, origin, d, t_in, t_out) -> Dictionary:
    p_in = origin + d * t_in - Vector3(cell)
    if ShapeCodec.occupied(v, p_in.x, p_in.y, p_in.z):
        return hit at t_in, normal = the DDA face normal (unchanged contract)
    for tri in ShapeCodec.surface_tris(v):          # 1 or 2 planes
        t = ray_plane(tri.plane, origin, d)
        if t_in <= t <= t_out and tri.contains_xz(origin + d * t - cell):
            return hit at t, voxel = cell,
                   normal = UP (BOTTOM) / DOWN (TOP),      # cell-adjacency contract for placement
                   surface_normal = tri.plane.normal       # true normal, new optional field
    return miss  # DDA continues to the next cell
```

Keeping `normal` axis-aligned (UP/DOWN for surface hits) preserves the
break/place adjacency contract the Player relies on; the true sloped normal is
exposed separately for future use (particles, decals). Misses matter: a ray can
pass *through* the empty part of a ramp cell and hit the cell behind — the DDA
naturally handles this because a miss just continues the walk.

### 5.4 `GroundCollider`

Boxes stay for FULL cells. Partial cells within the collider radius contribute
the same ≤ 2 convex prisms as VoxelBody cells (§4.3), so loose `VoxelBody`
pieces rest/slide on ramps correctly. The *player* never touches these (player
ground contact is `floor_under`/`blocked`, unchanged policy).

### 5.5 Collapse & support scan

`_collapse_unsupported` keeps its flood fill, but adjacency between two solid
cells requires `ShapeCodec.contact_area(vA, vB, axis) > AREA_EPS` (§7) instead
of mere mutual solidity — a ramp resting its zero-height edge against a
neighbour gives no support and correctly detaches. `AREA_EPS = 1/64` (see §11).
**SEAM (structural integrity):** that doc owns what "support" means beyond
binary connectivity (strength thresholds, mass-weighted attachment). Our
deliverables into it are exactly: `contact_area(vA, vB, axis) ∈ [0,1]` (fraction
of the shared face), `volume(v) ∈ (0,1]`, and `mass(v) = density × volume`. The
collapse flood fill described here is the *interim* binary consumer; when the
structural model lands, it replaces the predicate, not the geometry functions.

---

## 6. Mass & fill fraction

With half-unit corners and the max-sum diagonal rule, the fill fraction has one
closed form (derivation: two triangular prisms, each `½ × mean of 3 corner
heights`; diagonal corners are shared by both triangles):

```
sA = c00 + c11        sB = c10 + c01
V  = (2 * max(sA, sB) + min(sA, sB)) / 12          # BOTTOM anchor
V_top(c) = V(c)                                     # TOP anchor: same field, mirrored
```

Checks: FULL (2,2,2,2) → 12/12 = 1. RAMP (2,2,0,0) → (2·2+2)/12 = ½. SLAB
(1,1,1,1) → (2·2+2)/12 = ½. CORNER (2,0,0,0) → (2·2+0)/12 = 1/3 for **every**
rotation (the max-sum rule routes the diagonal through the peak). HALF_CORNER
(1,0,0,0) → 1/6 (a true tetrahedron). Complement invariant: for a **fixed
shared diagonal** D, `V_D(c) + V_D(2−c) = 1` exactly (asserted in verify — it
fences the formula). Subtlety: with each shape picking its *own* max-sum
diagonal, a shape and its complement can fold along different diagonals (CORNER
1/3 but its complement 5/6, not 2/3) — general complements do not tile a cell
exactly, which is why §9 restricts in-cell merging to diagonal-agreeing pairs.

```
mass(cell)      = VoxelState.density(mat) * V(shape)        # kg (1 m³ cell)
```

`VoxelState.mass` remains the *full-cell* convenience (`density × 1`);
`BlockCatalog.mass_of(id)` keeps its meaning. New:
`BlockCatalog.mass_of_value(packed) = density × ShapeCodec.volume(packed)`, used
by `VoxelBody._rebuild()` and anything mass-aware. Durability: **SEAM
(structural)** — we recommend break effort scale with `V` too (breaking a sliver
is easier), but the scaling law belongs to STRUCTURAL-INTEGRITY.md; we only
guarantee `volume(v)` is available per cell.

---

## 7. Attachment: contact area on the shared face

### 7.1 Vertical (side) faces — 1-D profile overlap

The filled cross-section of a corner-height shape on any of its 4 vertical
boundary faces is fully described by a **side profile** `(anchor, e0, e1)`: the
two corner heights (half-units) on that face's edge, linearly interpolated
between them (the interpolation is linear along every cell edge regardless of
the diagonal choice, because the diagonal is interior — this is also what makes
neighbouring cells crack-free). FULL = `(B,2,2)`, AIR = `(B,0,0)`; 18 distinct
profiles total.

Overlap of neighbouring profiles A, B across their shared face, as a fraction
of the 1×1 face (`hA(t) = lerp(a0,a1,t)/2`, similarly `hB`):

```
both BOTTOM (or both TOP):  area = ∫₀¹ min(hA, hB) dt
BOTTOM vs TOP:              area = ∫₀¹ max(0, hA + hB − 1) dt
```

Both integrands are piecewise linear with at most one break, so:

```gdscript
static func _integral_min(a0, a1, b0, b1) -> float:   # heights in blocks
    d0 = a0 - b0; d1 = a1 - b1
    if d0 * d1 >= 0.0:                                # no crossing: one line is min throughout
        return (minf(a0, b0) + minf(a1, b1)) * 0.5
    ts = d0 / (d0 - d1)                               # crossing point
    m0 = minf(a0, b0); mc = lerp(a0, a1, ts)          # = lerp(b0, b1, ts)
    m1 = minf(a1, b1)
    return (m0 + mc) * 0.5 * ts + (mc + m1) * 0.5 * (1.0 - ts)
# BOTTOM-vs-TOP reduces to _integral_min via g(t) = hA + hB - 1 clipped at 0 (same 1-break pattern).
```

Since profiles are quantized, all 18×18 pair results are **precomputed into a
LUT** at `ensure_ready()` — the collapse flood fill and the structural model pay
a table lookup, not an integral. Orientation care: the two cells parameterize
the shared face with opposite handedness; the LUT accessor flips one profile's
`(e0, e1)` before lookup (a classic silent bug — verify has a dedicated case).

Examples the requirements call out:

* Bottom slab `(B,1,1)` beside top slab `(T,1,1)`: `∫ max(0, ½+½−1) = 0` — 
  **zero overlap ⇒ no joint**, even though both cells are 50 % full.
* Ramp `(2,2,0,0)` seen from its high side: profile `(B,2,2)` — full-face
  contact with a neighbouring cube (area 1). From its zero edge: `(B,0,0)` —
  area 0, no joint. The ramp hangs off its high side only, as intuition says.

### 7.2 Horizontal faces — coverage-polygon intersection

On the shared horizontal plane between lower cell L and upper cell U:

* L's filled region on its **top** face: `{H_L = 1}` — for quantized corners this
  is exactly the union of L's triangles whose three corners are all 2 (a partial
  top touches the plane only along edges/points otherwise — measure zero, no
  contact; e.g. a cube on a RAMP gets **no** horizontal joint, per the owner's
  rule).
* U's filled region on its **bottom** face: BOTTOM anchor (nonempty) → the full
  square (see §4.2: the max-sum diagonal guarantees no all-zero triangle);
  TOP anchor → `{H_U = 1}` = U's all-2 triangles; FULL → the square.
* `contact_area = area(topRegion(L) ∩ bottomRegion(U))`. Both regions are unions
  of half-square triangles (possibly with different diagonals), so the
  intersection comes from a 4-entry triangle-pair LUT (same-diagonal pair: ½ or
  0; crossed-diagonal pair: ¼).

Consequence worth stating loudly (fed to structural + gameplay): **a full cube
placed in the cell above a bottom slab has zero contact** — geometrically there
is a ½-block air gap; the cube is unsupported and (once structural integrity
lands) falls. Flush stacking on a bottom slab requires a *top-anchored* shape in
the cell above (bottom face at the shared plane) or filling the slab to a cube.
Placement UX may want to warn/auto-pick; that is a Player-layer nicety, not a
physics exception.

---

## 8. Deterministic terrain smoothing (`TerrainConfig`)

### 8.1 Scheme (recommended): smooth the existing integer columns

Keep `height_at(x, z)` and all material/layer logic **unchanged** (grass top,
dirt band, stone, trees, `effective_height`, spawn logic — zero semantic
ripple). Smoothing is a *reshaping of the surface cells only*, derived
deterministically from the integer column tops both generators already share:

```
top(x, z)   = height_at(x, z) + 1                          # walk surface, integer
T(X, Z)     = ( top(X-1,Z-1) + top(X,Z-1) + top(X-1,Z) + top(X,Z) ) / 4.0
              # corner target height at lattice corner (X, Z) — mean of the 4 columns
              # sharing that corner. Local (4 noise samples), deterministic, and
              # IDENTICAL for both generators because it only uses height_at.
```

For column `(x, z)` with `g = height_at(x, z)`:

| y | cell value |
|---|---|
| `y < g` | unchanged (full dirt/stone per today's rules) |
| `y == g` | GRASS with corners `c_k = clamp(roundi((T_k − g) * 2), 0, 2)`; if all `c_k == 2` → plain FULL grass id (canonical form — flat ground generates *byte-identical* values to today) |
| `y == g + 1` | if any `T_k > g + 1` **and** no tree cell there: GRASS **cap cell**, corners `clamp(roundi((T_k − (g+1)) * 2), 0, 2)`; else air/tree as today |
| `y > g + 1` | unchanged (`TreeGen.block_at`) |

Properties:

* **Flat ground regression-safe:** `T = g + 1` at every corner ⇒ surface cell
  FULL, no cap cell ⇒ output identical to current `generated_block`.
* **A 1-block step smooths into a ramp pair:** boundary corners average to
  `g + 1.5`, so the lower column grows a HALF_RAMP cap (`0→½`) and the upper
  column's surface cell becomes `½→1` — a continuous slope, no ledge. Slopes up
  to 1 block/cell smooth fully; steeper terrain saturates the clamp and stays
  blocky (accepted: cliffs read as cliffs).
* **Crack-free:** neighbouring cells share lattice corners and therefore corner
  heights; `H` is linear along shared edges (diagonals are interior), so the
  composed surface is C0. Where clamping differs across a seam (steep ground),
  the meshers' side-profile walls (§4.2) fill the vertical gap by construction.
* **Trees:** the surface cell under a trunk base and the 3×3 footprint's `g+1`
  cells are forced FULL / left to `TreeGen` respectively (deterministic
  exception), so trunks never float on a ramp corner. Cheap: TreeGen lookups the
  generator already performs.
* Grass invariants hold: grass appears only at `y == g` and the cap `y == g+1`
  (both "surface"); nothing below `g` changes, ground stays non-hollow.

**SEAM (catalog/worldgen):** WORLDGEN-CATALOG owns `height_at` and the surface
material choice. Our assumptions: (a) the surface remains a per-column
heightmap with a single surface material per column (the `T` averaging needs
only integer column tops — any new heightmap plugs in unchanged); (b) if that
workstream introduces overhangs/caves, smoothing still applies per-column to the
*top* surface and cave interiors stay blocky — acceptable, but they should not
route cave ceilings through `height_at`. Surface material of the cap cell = the
column's surface material (grass today; whatever the catalog says tomorrow).

### 8.2 Rejected: true fractional noise sampling

Sampling the pre-floor noise `height_f` at lattice corners and deriving both the
integer surface *and* the shapes from it gives marginally better fidelity but
redefines `height_at`'s relationship to the surface (floor-of-center vs
floor-of-corner-min can disagree), rippling into `effective_height`, spawn
logic, tree bases, the stackup verify tests, and the module generator's column
loop. The column-top averaging above smooths every visible stair-step for
strictly less risk; fractional sampling can be a later refinement inside the
same encoding.

---

## 9. Digging & placing partial cells

* **Breaking** a partial cell: `break_terrain` semantics unchanged (cell → air,
  mirror, collapse pass). It returns the material id (hotbar contract intact)
  and credits the inventory with the cell's **volume**, not "1":
  `Inventory` stores a float volume per material internally; the hotbar shows
  `floori(volume)` and placement of shape s requires `volume >= V(s)`. This is
  what makes mass genuinely conserved: dig a ramp, you hold half a block —
  breaking a ramp and re-placing cubes can never mint material.
  *(Alternative rejected: "any partial breaks to 1 full item" — a material
  duplication exploit; "partials drop nothing" — punishes terraforming.)*
* **Placing:** `place_block(cell, value)` accepts a packed value; validation
  masks the material for the catalog range-check and canonicalizes the shape.
  Phase 1 places FULL only (today's behaviour). Phase 4 adds a shape selector:
  the hotbar material + a cycled shape (FULL / SLAB / RAMP / CORNER /
  ANTICORNER), yaw from the player's facing (corner rotation = cyclic shift),
  anchor from the aimed face (clicking a ceiling face places TOP-anchored).
  In-cell merging (placing into a cell that already holds a partial of the same
  material) is allowed only for pairs whose union is *exactly* a valid code with
  agreeing diagonals — practically: bottom slab + top slab → FULL. General
  complements don't tile exactly under per-shape max-sum diagonals (§6), so
  everything else requires air, as today.
* **Collapse / loose bodies:** the collapse pass captures packed values into
  `comp_ids`; `VoxelBody` carries them, so a detaching slope chunk keeps its
  ramp faces and its reduced mass (a broken ramp genuinely drops a
  half-mass partial body — requirement 2 end-to-end). `VoxelBody.break_cell`
  connectivity uses the same `contact_area > AREA_EPS` adjacency as the world
  collapse (one rule everywhere).
* **Aiming:** the DDA already returns the sub-cell hit (§5.3); breaking targets
  the hit cell regardless of where on the ramp surface the ray landed.

---

## 10. Verify plan (`godot/src/tools/verify_feature.gd` additions)

New test funcs, same `_ok` pattern; all pure-logic + live WorldManager, headless:

1. **`_test_shape_codec`** — for all 162 codes × a material:
   `canonical(pack(...))` roundtrips; all-corners-0 → AIR; all-corners-2 BOTTOM
   → FULL (shape field 0); plain legacy ids decode as FULL of that material;
   `lib_id`/`from_lib_id` roundtrip for every (material, shape) pair (fences the
   module remap, §4.1).
2. **`_test_partial_mass`** — `volume(FULL)=1`, `SLAB=½`, `RAMP=½` for all 4
   rotations, `CORNER=1/3` for all 4 rotations (the max-sum rule),
   `HALF_CORNER=1/6`; rotation invariance `V(rot(c)) == V(c)` over all codes ×
   4 rotations; fixed-diagonal complement invariant `V_D(c) + V_D(2−c) = 1`
   over all codes for each diagonal D;
   a `VoxelBody` spawned with one stone RAMP cell has
   `mass == density(STONE) * 0.5` (requirement 2 assert).
3. **`_test_ramp_analytic_surface`** — write a grass RAMP into the overlay on
   flat ground; assert `floor_under` at 4 interior footprints is strictly
   monotone along the ramp axis and equals `cell.y + H(fx,fz)` within 1e-6;
   assert `blocked` is false approaching from the low side (walk-up) and true
   against the high side's neighbouring full cube stack; assert an `aimed_voxel`
   ray from above hits *inside* the cell at `position.y ≈ cell.y + H` and a ray
   skimming through the empty half passes to the cell behind (tunneling guard).
4. **`_test_contact_area`** — LUT vs direct integral agreement over all 18×18
   side-profile pairs; bottom-slab‖top-slab area == 0 (requirement 3's zero-
   overlap case); ramp high-side‖cube == 1; cube-above-bottom-slab horizontal
   area == 0; the orientation-flip case (two identical wedges nose-to-nose vs
   nose-to-tail give different areas — catches the handedness bug of §7.1);
   collapse behaviour: break the single supporting neighbour of a zero-overlap
   pair and assert the unsupported partial detaches as a VoxelBody while a
   full-overlap twin stays. **SEAM:** strength-threshold asserts live in the
   structural workstream's tests; we assert only area/connectivity.
5. **`_test_smoothing_determinism`** — `generated_cell` sampled twice over a
   grid is identical; on a detected flat patch every surface value is the plain
   FULL id (regression guard: flat world byte-identical to today); over a
   ±300-cell sweep at least one non-FULL surface cell exists (smoothing engages);
   every generated corner code obeys the clamp range; tree-base columns are
   FULL-topped.
6. **`_test_paths_agree`** — only one render path exists per binary, so path
   agreement is asserted at the *shared sources*: the module generator writes
   `lib_id(generated_cell(...))` (assert on a sample grid that decoding the
   generator's buffer values reproduces `generated_cell` exactly), and both
   meshers consume the same `ShapeMesh.build` (assert its vertex set for
   canonical shapes matches the expected geometry table).

---

## 11. Adversarial review — how this breaks, and the countermeasures

* **Tunneling through a ramp (fast fall):** the player's ground contact is the
  downward `floor_under` scan, not sweep-tests — a scan cannot skip a surface,
  so no fall-through. The DDA's in-cell test is complete by the §5.3 boundary
  argument; the residual risks are float-edge cases: a ray exactly along the
  fold diagonal (both triangle-containment tests reject by epsilon → miss →
  walks to the next cell — hits the neighbouring triangle there; worst case a
  hairline miss on a measure-zero line), and `t_in` exactly on a face plane
  (occupancy uses `<=` on the filled side, biasing to "hit" — the same bias the
  current DDA has for the starting-cell-solid case).
* **Step-allowance exploits:** STEP_MAX 0.55 auto-climbs half-steps by design;
  a 1.0 rise still blocks. Two ramps stacked to make a 1.0 effective rise inside
  one horizontal cell step: `floor_under(feet + STEP_MAX)` finds the *lower*
  standable surface first, rise check fails, blocked — no double-step. Sprint
  speed × frame time (≈0.1 m) stays ≪ STEP_MAX, so no frame-rate-dependent
  climbing.
* **Encoding overflow / aliasing:** material must fit 16 bits — `place_block`
  masks before range-checking, `canonical()` rejects corner value 3 (2-bit slot
  allows it) by clamping at write. The one true divergence risk is the module
  library remap (`lib_id`), which is why it is a pure `ShapeCodec` function with
  an exhaustive roundtrip in verify and a setup-time assert (mirroring today's
  `_add_cube` assert). Legacy `_edits` ints and `VoxelBody.cells` are valid
  packed values by construction (shape 0 = FULL) — no migration path to get
  wrong.
* **Path divergence:** every shape-dependent computation (geometry, volume,
  profiles, occupancy) lives in `ShapeCodec`/`ShapeMesh` and is consumed by both
  paths + physics; nothing is duplicated. The remaining divergence surface is
  godot_voxel's own baked-mesh handling of `VoxelBlockyModelMesh` (e.g. side
  culling differences vs the fallback's `covers_bottom` rule) — cosmetic only,
  never gameplay, because gameplay never reads geometry (rule 2).
* **Contact-area epsilons:** float areas near zero (two ramps sharing one corner
  point) must not create phantom joints — `AREA_EPS = 1/64` of a face; the
  quantized LUT makes every legitimate nonzero overlap ≥ 1/16, so the gap
  between "real joint" and "epsilon noise" is wide. Edge/corner line-contact is
  exactly 0 by the integral — no epsilon needed there.
* **Collapse cost:** adjacency now costs a LUT lookup per neighbour pair —
  O(1), table built once; the flood fill's asymptotics are unchanged. Horizontal
  coverage regions are cached per shape code (162-entry table), not recomputed.
* **The slab-stacking surprise (§7.2):** players *will* place a cube on a bottom
  slab and be confused when it has no support. This is the owner's rule working
  as specified, but it needs UX handling (placement preview showing "no
  contact", or auto-selecting the TOP-anchored variant). Flagged to gameplay;
  physics must not special-case it.
* **Cap cells above the heightmap (§8.1):** `effective_height` ignores cells
  above `g` by design; the cap grass cell at `g+1` is found by `floor_under`'s
  scan (it goes through `cell_value_at`) but NOT by `surface_y` (spawn height
  may be ≤ ½ low on a slope — spawn then settles via floor_under; harmless).
  The fallback mesher's greedy tops key on effective_height and would miss cap
  cells — they render via the partial-cell pass instead (explicitly in §4.2's
  implementation notes).
* **Saddle folds:** the max-sum diagonal on tie codes (saddles) picks a fixed
  fold; a 90° world rotation of the same terrain would fold the other way.
  Volume/physics are tie-invariant (proved §2/§6); only the render facet
  direction differs, and terrain generated by §8.1 is rotation-consistent with
  itself (corner heights rotate with it). Accepted.
* **Web perf:** +156 baked library models per material at setup (sub-second,
  once), fallback mesher gains ≤ 2 triangles per *surface* cell only, physics
  adds a handful of lerps per query. Nothing per-frame-per-voxel. The 16-bit
  TYPE channel keeps buffer memory unchanged.

---

## 12. Implementation phases

1. **P1 — pure math, no behaviour change:** `ShapeCodec` (pack/canonical/
   volume/local_top/occupied/profiles/contact LUTs) + verify tests 1, 2, 4
   (contact-area asserts only). Ships dark: nothing produces partial values yet.
2. **P2 — world + physics:** `cell_value_at`, packed `_edits`,
   `TerrainConfig.generated_cell` with §8.1 smoothing, `floor_under`/`blocked`/
   `aimed_voxel` upgrades, collapse adjacency via contact area. Verify tests 3,
   5. (Terrain smooths but renders stair-stepped until P3 — physics may briefly
   lead rendering; keep P2+P3 in one PR if that reads as a bug.)
3. **P3 — rendering:** `ShapeMesh`, fallback mesher partial tops/side profiles/
   cull rule, module `VoxelBlockyModelMesh` library + generator/`set_cell`
   remap. Verify test 6. Live-site gate: web export must still load (model bake
   happens at setup on the main thread — measure once).
4. **P4 — gameplay:** volume inventory, partial `VoxelBody` mesh/colliders/mass,
   shape placement UI, structural-integrity integration (their model consumes
   our area/mass through the §5.5/§7 interfaces).
