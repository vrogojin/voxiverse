# SHARP-SLOPE — locked build ADR (sub-voxel steep-face shapes: clean diagonal mountain slopes)

Status: **LOCKED, implementation-ready.** Consolidated ADR for the sharp-slope feature: a second
FAM sub-voxel shape family that renders STEEP terrain faces (relief the ≤45° corner-height
smoothing cannot grade) as one clean planar diagonal spanning several vertical cells, instead of
today's staircase of hip-roof caps ("stacked pyramids"). It builds on and specializes
`docs/SUB-VOXEL-SMOOTHING.md` (the corner-height family and its §8 "cliffs read as cliffs"
saturation), `docs/SNOW-ACCUMULATION.md` Decision 1 (the exact precedent for adding a FAM family:
bit layout, canonicalization, query-branch table, dedicated frozen manifest tables), and
`docs/M1-SNOWY-WORLD.md` (snow-capped stone peaks, the collider cheap-query discipline §6.3).
Decisions those documents locked are cited, not relitigated.

**Engine-patch verdict, stated up front: NO godot_voxel C++ patch is required.** Every mechanism
is existing, shipped module API: `VoxelBlockyModelMesh` built from `ShapeMesh` geometry
(`module_world.gd:703-721`), frozen per-family ARID tables published to the worker generator
(`module_world.gd:41-61, 1216-1221`), and the pattern-based face culling the blocky mesher already
performs on baked models. The two conceivable native alternatives are priced and rejected in §8:
(a) a native "steep-slope pass" inside the blocky mesher's hot loops (~600–1000 C++ LOC, ≥2× the
waterlogging patch — the class MULTI-MATERIAL §3b already rejected at 400–600 LOC), and (b)
switching mountains to the module's SDF/Transvoxel smooth mesher — not a patch but a full
render-path re-architecture (channel, materials, analytic-physics contract, per-cell edit model
all change). The full sharp look is achievable game-side; §7 also names the minimal scope that
removes the stacked pyramids if budget forces a cut.

**The problem, verified in source.** The Mountains biome (`MOUNTAIN_AMPLITUDE := 92`,
`terrain_config.gd:97`; full peaks ≈ y98–112 against `MAX_SURFACE_Y := 116`, `:134-141`) produces
faces of ~1–3 blocks of rise per cell. The smoothing pipeline reshapes ONLY the surface cell at
y = g and one cap cell at y = g+1 (`resolve_cell` branches, `terrain_config.gd:491-497, 518-523`),
each quantized to four corner heights in {0,1,2} half-blocks (`_corner_targets` `:620-634`,
`_modifier_from_targets` `:640-650`, `ShapeCodec` corners `shape_codec.gd:71-81`). One cell can
therefore express at most a 1-block rise; a 2-block-per-cell face saturates: the surface cell
clamps to a FULL cube, the cap clamps to a saturated 4-corner lip — a hip roof — and tiling those
up a face is exactly the "stacked pyramids". The rise itself lives in the full-cube stack below
each column's surface (`resolve_cell` `y < g` cells are unconditionally full), which nothing
carves. Fixing this requires shapes that (i) can be *empty over a positive-area region* of the
footprint (the corner family cannot: linear interpolation of corners ≥ 0 is zero only at
corners/edges) and (ii) tile *vertically* without gaps — hence a new family, not new corner tuples.

**The model in one paragraph.** Where the smoothed corner-target plane escapes the two-cell
[g, g+2] window the legacy family can grade, the column becomes a **slope column**: its corner
targets are quantized to WHOLE blocks (shared with every neighbouring cell, so no cracks), and a
vertical **run** of 1–3 cells — possibly reaching below g (carving the formerly-full stack) and
above g+1 — each carries a **FAM SLOPE modifier**: four signed whole-block corner deltas relative
to the cell floor. Each cell's shape is the corner plane **clipped to the unit cube**
(`H = clamp(D, 0, 1)`); stacked run cells share one corner tuple shifted by −1 per cell, so the
clipped shapes tile into one exact planar face — full below it, air above it, never a gap and
never a floating sliver. Physics, DDA, collider, mesher and mass all read the shape through the
same `ShapeCodec` queries the LAYER family extended, so render/physics parity — the entire point
of the feature — holds by construction.

---

## Decision 1 — FAM kind 1 "SLOPE": bit layout and canonicalization

**1.1 Distinct family kind (locked).** `MOD_FAM_BIT` (bit 15) with **`FAM_SLOPE := 1`** in the
kind field (bits 14..12, `cell_codec.gd:36-37`) — disjoint from `FAM_LAYER = 0` (`:38`). Note
`is_layer` (`:61-62`) tests `((m >> 4) & 0x7FF) == 0`, which includes the kind bits, so it is
already false for every SLOPE value — no LAYER call site changes.

**1.2 Payload (locked): four 3-bit signed corner deltas, WHOLE blocks, bias +3.**

```
bit 15         bits 14..12     bits 11..9   bits 8..6   bits 5..3   bits 2..0
MOD_FAM_BIT    FAM_KIND (=1)   k01          k11         k10         k00
```

`k_i = d_i + 3`, `d_i ∈ {−3..+4}` whole blocks — the height of corner i's terrain plane above
this cell's FLOOR, in ShapeCodec corner order (c00, c10, c11, c01; low-bits-first mirrors the
legacy corner packing, `shape_codec.gd:24-26`). Always BOTTOM-anchored (no TOP slopes in v1;
there is no anchor bit — bit semantics are family-local under FAM). The encoding is *total*:
all 4096 payloads decode to a valid tuple; there is no malformed-payload case.

*Why whole blocks, and why this range:* vertical tiling demands that cell y+1's tuple be cell y's
minus 1 exactly, so the quantization grid must be closed under −1 block — half-blocks satisfy that
too, but 3 bits of half-blocks cover a spread of only 1.5 blocks/cell, below the ~3 blocks/cell
mountains actually produce, while {−3..+4} whole blocks covers it exactly: a run cell is non-full
iff min d ≤ 0 and non-air iff max d ≥ 1, so with corner spread ≤ 3 every run cell's deltas land in
[−2, +4] ⊂ {−3..+4} (proof in 3.3). Steeper than 3 blocks/cell stays a blocky cliff (§8 non-goal
preserved). The half-block finesse is worth < ¼ block on a multi-block face and is *not* worth
losing exact vertical tiling.

New codec surface (in `cell_codec.gd`, beside the LAYER helpers `:48-67`):

```
const FAM_SLOPE := 1
const MOD_SLOPE_BIAS := 3
static func make_slope(d00: int, d10: int, d11: int, d01: int) -> int   # canonical (see 1.3)
static func is_slope(m: int) -> bool    # (m & MOD_FAM_BIT) != 0 and ((m >> 12) & 7) == FAM_SLOPE
static func slope_deltas(m: int) -> Vector4i                            # biased-decode, in blocks
```

**1.3 Canonicalization (locked)** — extend `_canonical_modifier`'s FAM branch
(`cell_codec.gd:222-229`) from "kind != FAM_LAYER → strip + warn" to a **kind dispatch**: kind 0 →
the existing LAYER rules; **kind 1 → the SLOPE rules below**; any other kind (or, for LAYER,
nonzero reserved bits) → strip to full cube + warn, unchanged. The non-solid material gate
(`:211-214`, "no ramp of water") runs first, unchanged. SLOPE rules, preserving the one-int-per-
shape uniqueness discipline (`:198-206`):

1. **all d_i ≥ 1 → 0** (full cube: the plane is at/above the ceiling everywhere — no dual
   encoding of a full cell; the LAYER level-10 rule's twin).
2. **all d_i ≤ 0 → `MOD_FAM_BIT`** (the shared empty-FAM marker; `canonical()` already collapses
   it to AIR, `:191-192`).
3. **all d_i ∈ {0, 1} → the legacy corner modifier** `ShapeCodec.make_modifier(2·d00, 2·d10,
   2·d11, 2·d01, ANCHOR_BOTTOM)` — with every delta inside [0,1] the clamp is inert and the
   clipped plane IS the legacy linear ramp (both families use the same max-sum diagonal, 2.1), so
   the shape is legacy-expressible and must have its legacy encoding (the LAYER level-5 → 85
   rule's twin). This also reuses the already-baked, collider-proven legacy models for those cells.
4. **else keep the tuple as-is.** Uniqueness holds: the clipped surface determines the unclamped
   plane per max-sum triangle (the band gradient and the 0/1 crossing lines fix it; a fully
   clamped triangle forces rule 1/2/3 first), and the plane determines the corner values —
   verify pins spot pairs (5.2 item 1).

**1.4 Persistence and mass come free.** ZoneChunk's sparse `_modifier` layer stores the full
16-bit field (`zone_chunk.gd:68, 242-243` `_put_sparse_u16`), so SLOPE values round-trip
`save_edits`/`load_edits` with no format change (the Decision-1 argument of SNOW-ACCUMULATION
§1.1 verbatim). `BlockCatalog.mass_of_value = mass × ShapeCodec.volume(modifier)` composes the
new `volume` closed form (2.2) with zero call-site changes; `break_terrain` on a SLOPE cell
removes the whole cell (one `_write_cell(cell, 0)`, `world_manager.gd:315-326`) and yields its
material at the fractional mass.

---

## Decision 2 — ShapeCodec: the clipped-plane query set (every closed form)

**2.1 The shape function.** Let `d = slope_deltas(m)` (blocks, ints) and let `D(fx, fz)` be the
piecewise-planar interpolation of `d` under the **same max-sum diagonal rule** as the legacy
family (`_height_half`, `shape_codec.gd:151-168`, generalized to signed block values as a parallel
`_plane_at(d, fx, fz)` — the comparison `d00+d11 ≥ d10+d01` is invariant under the uniform −1
shift between run cells, so every cell of a run splits on the SAME diagonal: vertical tiling is
exact). The occupied shape is bottom-anchored with top surface

```
H(fx, fz) = clampf(D(fx, fz), 0.0, 1.0)
```

Horizontal crack-freeness: along any cell edge H is the clamp of a linear function of the two
shared corner deltas only — identical for both flanking cells (the §8.1 argument, one clamp
deeper). Vertical gap-freeness: cell y is full-height exactly where D ≥ 1, which is exactly where
cell y+1 (deltas −1) has D ≥ 0, i.e. exactly where it holds material — no floating sliver, no
internal hole, by construction.

**2.2 The query table (locked).** Every public query branches `is_slope` FIRST (beside the
existing `is_layer` branches; the LAYER discipline of SNOW-ACCUMULATION §1.4):

| query (`shape_codec.gd`) | SLOPE closed form |
|---|---|
| `corners` (:71) | **defensive quantization**: per corner `clampi(2·d_i, 0, 2)` — any consumer missed by the sweep degrades to the nearest legacy shape, never nonsense (the LAYER `:74-80` pattern) |
| `anchor` (:88) | `ANCHOR_BOTTOM` (0) — always |
| `is_full` (:92) | unchanged (m == 0 only; rule 1.3.1 guarantees no full SLOPE encoding exists) |
| `bottom_face_covers` (:103) | `false` — a canonical SLOPE has min d ≤ 0, so its floor is exposed (or corner-touched) somewhere; mirrors the legacy any-0-corner rule |
| `make_modifier` (:114) | unchanged (legacy builder); `make_slope` is the SLOPE builder in CellCodec |
| `volume` (:121) | `Σ_tri [ I⁺(a,b,c) − I⁺(a−1,b−1,c−1) ]` over the two max-sum triangles with vertex values from d, where `I⁺(a,b,c) = ∫_tri max(0, linear)` over the half-unit-square triangle: all ≥ 0 → `(a+b+c)/6`; all ≤ 0 → `0`; exactly one positive value p (others q, r) → `p³ / (6·(p−q)·(p−r))`; exactly one negative value n (others p, q) → `(a+b+c)/6 − n³ / (6·(n−p)·(n−q))`. (This identity is `∫max(0,f) = ∫f + ∫max(0,−f)` applied to the one-positive case.) Verify pins it against a Monte-Carlo sample — the SNOW-ACCUMULATION §2.5 `fill_volume` precedent: sign/monotonicity pinned hard, precision pinned loosely |
| `height_at` (:173) | `H(fx, fz)` = `clampf(_plane_at(d, fx, fz), 0, 1)` |
| `local_top` (:184) | `H` (BOTTOM-anchored) |
| `span` (:195) | `Vector2(0, H)` when `H > 0`, else `Vector2.ZERO` |
| `occupied` (:208) | `H > 0 and fy ≥ −_EPS and fy ≤ H + _EPS` |
| `side_profile` (:222) | defensive `(ANCHOR_BOTTOM, clampi(2·e0, 0, 2), clampi(2·e1, 0, 2))` from that face's edge deltas — approximate by design; every precise consumer branches directly (LAYER `:64` discipline) |
| `side_profile_full` (:241) | lateral faces: `e0 ≥ 1 and e1 ≥ 1` (H ≡ 1 along that edge). `FACE_PY`: `false` (needs all d ≥ 1 — canonically full, impossible). `FACE_NY`: `min(d) ≥ 0` (floor touched everywhere except measure-zero corners; min ≤ −1 leaves a positive-area exposed region → must NOT occlude the cell below) |
| `contact_area` (:280) | lateral axes: **bypass the 18-entry LUT** (`:47-64`, half-quantized profiles only). Each SLOPE edge profile is `clamp(lerp(e0, e1), 0, 1)` — piecewise linear with ≤ 2 knots. Subdivide [0,1] at the union of both profiles' 0/1-crossing parameters (≤ 4 knots) and apply the existing `_integral_min` (`:324`, same anchor) / `_integral_pos` (`:336`, opposite anchor) per linear segment — exact, pure, tiny. AXIS_Y: bypass the region machinery (`:357-421`): lower's top region is the polygon `{D_a ≥ 1}`, upper's bottom region `{D_b > 0}`; per shared max-sum triangle, clip the triangle against both half-planes (Sutherland–Hodgman on a 3-gon → ≤ 5-gon) and shoelace the area. A legacy/LAYER partner converts to the same per-triangle linear representation (a legacy BOTTOM top region is its all-2 triangles — the degenerate case of the same clip). Verify pins against dense sampling |
| `surface_tris` (:428) | per max-sum footprint triangle, clip into: **plateau** `{D ≥ 1}` → flat triangles at y = 1, normal UP; **band** `{0 < D < 1}` → triangles on the plane y = D (true sloped normal); the empty region emits nothing. Each clipped polygon (≤ 5 vertices) fan-triangulates; ≤ ~10 tris total. **The plateau polygon is load-bearing**: `GroundCollider._add_prisms` extrudes every surface tri to the anchor face (`ground_collider.gd:506-529`), so the plateau tris become the full-height prisms — without them the uphill part of a run cell would have NO collision. For the DDA (`world_manager.gd:957-978`) the plateau tris are coincident with the cell above's material and unreachable from outside — harmless, and they make the in-cell test complete |

**2.3 `ShapeMesh.build` SLOPE branch** (`shape_mesh.gd:21-69`): surface polygons exactly as
`surface_tris` (plateau + band); the **bottom face is the `{D > 0}` clipped polygon** at y = 0
(not the full square — the empty region has no underside); side faces per lateral edge are the
region under the clamped edge profile (a ≤ 5-vertex polygon: base corners + the profile's 0/1
knots), degenerate faces skipped (`_EPS` discipline `:73-79`). Same `{verts, normals, uvs,
indices}` dict; UV convention unchanged (top → (x,z), sides → (tangent, y)). Mesh cache key on
the module path: the **raw FAM modifier** (`_shape_mesh_cache[m]`, `module_world.gd:106`) — bit 15
keeps SLOPE keys disjoint from all corner keys, from LAYER keys, and from `_WET_MESH_FLAG`
(1 << 20, `:92`) — the SNOW-ACCUMULATION §1.4 keying rule verbatim.

---

## Decision 3 — Worldgen: steepness detector, whole-block corner quantization, the run emitter

**3.1 Quantized corner targets — one shared grid for BOTH families (the crack-killer).** Corner
targets stay `_corner_targets` (`terrain_config.gd:620-634`; exact multiples of 0.25). Introduce
`_quantized_targets(x, z, pcache) -> Vector4`: each corner is quantized to the **WHOLE-block grid**
(`roundf(T)`) iff `corner_whole` holds there, else to the **half-block grid** (`roundf(2·T)/2` —
byte-identical to today, because `_modifier_from_targets`'s `roundi((T − by)·2)` with integer `by`
equals `roundi(2T) − 2by`). Both `_smoothed_surface`/`_surface_cap` (via `_modifier_from_targets`)
and the SLOPE emitter consume `_quantized_targets`, so **a corner shared between a slope cell and
a legacy ramp cell has ONE value → no seam, ever** (whole values are exactly representable on the
half grid, so the legacy encoder accepts them unchanged).

```
corner_whole(cx, cz) := any of the 4 columns meeting at the corner is slope-EMITTING (3.2)
```

Column classification is computed from RAW targets (pass 1), quantization applied after (pass 2)
— no circularity. Cost: a cell's 4 corners consult 4 columns' emission predicates, each a 3×3
column-top stencil → a 5×5 stencil worst case; absorbed by the per-column memo on the analytic
path (3.5) and `pcache` on the worker (both stencils overlap heavily across a block).

**3.2 The emission predicate (locked)** — pure, deterministic, from `height_at` + `TreeGen` only
(the SVS §8.1 purity discipline):

```
const SLOPE_MAX_SPREAD := 3     # blocks of corner-target relief across one cell; steeper stays a cliff

_slope_fires(x, z, g, pcache) :=
    SMOOTHING_ENABLED                                             # rides the smoothing path (M1 §6 note)
    and g >= SEA_LEVEL                                            # v1: land only (no wet-twin bake multiplier)
    and TreeGen.block_at(x, g + 1, z, pcache) == AIR              # tree-rest suppression, same as smoothing
    and ( min_i(T_i) < g  or  max_i(T_i) > g + 2 )                # the plane ESCAPES the legacy 2-cell window
    and ( max_i(Tw_i) − min_i(Tw_i) <= SLOPE_MAX_SPREAD )         # encodable; steeper → legacy saturation (cliff)
```

where `T_i` are the raw targets (compare in integer quarter-units, `roundi(4T)`, so the predicate
is float-robust) and `Tw_i := roundi(T_i)` the whole-quantized ones. **Byte-identity outside steep
regions is structural**: a 1-block step keeps all raw targets inside [g, g+2] (corner = mean of
four walk-surfaces; worst case `(g+1 + 3·(g+2))/4 = g+1.75` rising, `g+0.25` descending), so the
predicate first fires exactly at ≥ 2-block local steps — the temperate/gentle world, every shore,
and every underwater floor generate byte-identical cells (verify-pinned, 5.2 item 3e).

**3.3 The run (locked).** For a slope column let `lo := min_i(Tw_i)`, `hi := max_i(Tw_i)`
(integers, `hi − lo ≤ 3`). The run is cells `y ∈ [lo, hi − 1]` (≤ 3 cells); cell y carries
`make_slope(Tw − y)` (component-wise). Encodability is automatic: at y = lo the max delta is
`hi − lo ≤ 3 ≤ 4`; at y = hi−1 the min delta is `lo − hi + 1 ≥ −2 ≥ −3`. Cells below `lo` are
FULL (their deltas are all ≥ 1); cells above `hi − 1` hold no slope material. The run may extend
**below g** (the carve — three low neighbours pull a corner target under the column's own surface)
and **above g + 1** (a multi-cell cap). At any footprint the column is solid from bedrock to
exactly `clamp`-plane height — contiguous, no hole, the floor scan can never fall through
(retargets the `resolve_cell:513-516` "cells below the surface stay full" comment, which becomes
"…stay full below the slope run; the run itself is gap-free by the clipped-plane construction").

**3.4 `resolve_cell` integration (`terrain_config.gd:475-524`).** Resolve the column's slope data
once (3.5's shared predicate) and branch:

* **y > g, y ≤ hi−1 (slope cap cells):** return
  `_with_snow_state(_with_shore_liquid(pack(_cap_material(biome, x, z, t, g), make_slope(Tw − y)), y, t), g, t)`
  — the existing cap composition (`:491-497`) generalized to the run; the legacy `y == g+1` cap
  branch is suppressed on slope columns (the run replaces it). Sea/tree branches below it
  unchanged.
* **y == g:** slope column → `pack(surface material, make_slope(Tw − g))` when g is in the run,
  else the plain FULL material (the face buried this column's own top); composed with both
  wrappers exactly like today's surface return (`:518-523`). `_smoothed_surface` is bypassed.
* **y < g, y ≥ lo (the carve):** the cell KEEPS its generated material from `_surface_rule`
  (grass/dirt/stone banding — material projection untouched, the SVS §8.1 discipline), gains
  `make_slope(Tw − y)`, and **skips the stone → deepslate/strata/ore rewrite** (`:508-510` gains
  `and not slope_run` — a face cell is exposed skin; an ore-block slope pair would also be an
  unbaked appearance). Both wrappers composed (they no-op on dry land cells). Documented
  consequence: a thin sliver of near-face ore stops generating on steep mountain skins (Risk 6).
* Snow interaction is free: `_with_snow_state` (`:556-566`) keys on `(g, t)` and the catalog's
  cappable declaration — stone is declared and baked (M1 §2.2, `appearance_surface_materials`
  `:842-852`, `snow_cappable_materials` `:862-864`) — so every run cell above the freeze line
  carries `STATE_SNOW_CAPPED` and renders the white variant (4.2).

**3.5 The collider cheap-query contract, generalized WITHOUT divergence (the central problem).**
Today's machine-checked contract is `surface_cap_modifier(x,z) == CellCodec.modifier(
generated_cell(x, g+1, z))` (`verify_feature.gd:1059-1077`, M1 §6.3), and it assumes ≤ 1 shaped
cell above g. It is **generalized, not weakened**:

* **One shared predicate.** A single pure function `_slope_entry_data(x, z, pcache)` computes
  `(fires, Tw)` from `_quantized_targets` + `_slope_fires`. `resolve_cell` (worker, pcache ≠ null),
  the light queries, and the memo ALL call it — the `_slab_fires` single-predicate pattern
  (`:578-585`), so memo vs worker-direct cannot diverge by construction.
* **Memo repack** (`_shape_entry`, `:686-716`): the packed int gains **bit 56 = slope flag** and
  **bits 40..55 = four 4-bit biased corner codes `(Tw_i − g) + 4`** (deltas ∈ [−3..+4] fit;
  `lo/hi` and every run cell's modifier are pure arithmetic on these). Bits 0..32 keep today's
  layout (g+bias, sm, cm, slab); **bits 33..39 stay reserved for SNOW-ACCUMULATION §3.4's snow
  byte** (that ADR plans bits 32..39; the two features must land on one agreed layout — recorded
  as a cross-ADR coordination point, Risk 7). Pure functions of SEED → the memo stays
  byte-identical to recompute (the thread-safety reasoning at `:668-676` unchanged).
* **The generalized light query — THE new contract:**

  ```
  static func generated_modifier_at(x: int, y: int, z: int, pcache = null) -> int
  ```

  returns the generated cell's modifier for ANY y (0 outside shaped cells), from the memo on the
  analytic main thread and from `_slope_entry_data` + the legacy modifiers worker-direct — **zero
  `generated_cell` calls** (the light-query family contract, `:771-780`). `surface_modifier` /
  `surface_cap_modifier` (`:788-825`) become thin y = g / g+1 projections of it (existing pins
  retargeted, not weakened). Machine-checked contract (5.2 item 4):
  `∀ y ∈ [g−4, g+4]: generated_modifier_at(x,y,z) == CellCodec.modifier(generated_cell(x,y,z))`
  over wide mountain AND temperate sweeps, memo AND worker-direct branches.
* **A packed run query for loops:** `slope_run_of(x, z, pcache) -> int` (flag + biased corner
  codes, the memo's slope bits verbatim) so per-column consumers derive all run modifiers
  arithmetically instead of calling the per-cell query per cell — **no per-cell generated_cell
  storm and no per-cell light-query storm either**.

**3.6 GroundCollider** (`ground_collider.gd:402-471`): `_emit_column` fetches `slope_run_of`
once per column. Sub-surface loop: the `y == h → surface_modifier` special case (`:422`)
generalizes to "y in the run → the run modifier" (runs can start below h); above-surface loop: the
`y == h+1 → surface_cap_modifier` branch (`:450-451`) generalizes to "y ≤ hi−1 → run modifier".
Prisms come free via `_add_prisms` ← `surface_tris` (2.2: band prisms + full-height plateau
prisms). The run top `hi−1 ≤ g+3` is inside the existing `h + TreeGen.MAX_ABOVE_SURFACE` scan
bound (`MAX_ABOVE_SURFACE = 10`, `tree_gen.gd:30`) — no loop-bound change; the cheap-query
soundness test's "above the cap only tree/sea, modifier 0" clause (`verify_feature.gd:1063-1073`)
is retargeted to "above the RUN".

**3.7 Generator bounds.** Run tops sit ≤ g+3 ≤ `max_h + max_above` in the worker's per-block
early-out (`module_world.gd:1111-1114`) and ≤ `MAX_SURFACE_Y + max_above` in the constant
early-out (`:1084`) — no constant changes; verify re-proves the bound over a mountain sample
(a too-low bound punches holes — the loudest failure class, SNOW-ACCUMULATION §3.2 note).

---

## Decision 4 — Render: both paths, FAM manifest keying, never a hole

**4.1 Module path — dedicated frozen tables (the SNOW-ACCUMULATION §1.5 discipline: FAM
modifiers ≥ 0x8000 can never slot the `_GEN_STRIDE = 256` tables, `module_world.gd:50`; re-keying
the stride to 65536 was priced and rejected at ~19.6 MB/table there).** The SLOPE payload is 12
bits, so a dense per-family stride is cheap:

```
const _SLOPE_STRIDE := 4096
var _slope_arid: PackedInt32Array        # mat*_SLOPE_STRIDE + payload -> ARID; -1 unbaked; FROZEN at setup
var _snow_slope_arid: PackedInt32Array   # the snow-capped VARIANT twin (the _snow_arid discipline, :54-61)
```

≈ `count()` × 4096 × 4 B ≈ 1.2 MB each — trivially affordable, dense, worker-readable with zero
allocation. Baked in `_build_gen_manifest` (`:426-480`) over **`TerrainConfig.
emitted_slope_pairs()`** — a deterministic spatial (surface-mat, payload) sample over
`find_mountains(6)` (`terrain_config.gd:1241-1262`) ∪ `find_spawn()` ∪ `find_coast()` centres
(the `emitted_shore_pairs` pattern `:1315-1370`; mountains dominate, but 2-block steps in hills/
badlands fire too). Meshes: ONE ArrayMesh per payload shared across materials via
`_shape_mesh_cache[raw modifier]` (2.3); snow variants **reuse the same mesh** with
`BlockMaterials.snow_capped_for` overrides — zero extra GPU readbacks (the `_build_snow_manifest`
discipline, `:491-525`). Same anti-drift `add_model() == expected ARID` rule throughout.

**Budget estimate:** emitted payloads realistically ~100–300 (spread ≤ 3 tuples actually produced
by real relief); materials in practice stone + grass + podzol + sand + dirt (carve cells expose
dirt banding) → ~150–300 mesh readbacks, ~400–900 models incl. snow variants — the same class as
the snow-composite budget SNOW-ACCUMULATION §2.7 accepted, gated by the existing setup timing
print (`module_world.gd:159-160`). **Trim ladder** (each rung safe because of the fallback below):
(1) bake stone + grass only; (2) bake snow variants only for stone (the visible steep skin above
the snow line is capped); (3) shrink the sample radius.

**4.2 Resolve/worker wiring.** `arid_for_cell` (`:294-333`), `gen_arid_for` (`:647-686`),
`is_manifest_baked` (`:690-694`) and the runtime-compiled worker generator (`:1042-1206`) each
gain ONE arm keyed on bit 15 **before** the existing `modifier < GEN_STRIDE` guards: kind 1 →
`_snow_slope_arid[slot]` when the cell carries `STATE_SNOW_CAPPED` (the `:1183-1197` snow-arm
order), else `_slope_arid[slot]`, `slot = mat*_SLOPE_STRIDE + (modifier & 0xFFF)`; −1 → **plain
cube fallback**. Note the safety default already holds today: an unhandled FAM modifier falls
through every `modifier < GEN_STRIDE` test to `cube_arid[id]` (`:1160-1205`) — wrong silhouette,
right substance, **never a hole**. Tables published to the worker like `snow_arid` (`:1216-1221`).
Player-placed SLOPE cells (Phase S1) need no manifest: `arid_for` (`:341-369`) reaches its lazy
`_arid_by_key` append (key `mat | modifier<<16` — 16-bit modifiers fit) and `_make_shape_model` →
`ShapeMesh.build` already handles any modifier the codec accepts.

**Occlusion**: baked `VoxelBlockyModelMesh` side patterns are rasterized from the actual geometry,
so a slope cell's partial sides cull/get-culled truthfully against neighbours (the MULTI-MATERIAL
§3a "geometric truth" argument); the model's partial bottom face is culled natively against a full
cube below. Composed-query occlusion (`WorldManager.occludes_face`, `world_manager.gd:1021-1027`)
routes through `side_profile_full` — table 2.2 keeps it honest (a carved region never occludes the
cell below).

**4.3 Fallback path (parity, relaxed fidelity as documented, `chunk_mesher.gd:26-32`).**
* Greedy tops: a slope surface cell already has `topmods != 0` (`:79, 117-124`) → excluded. A
  slope column whose surface cell is FULL (buried under the run) gets its run cells emitted above;
  the flat top quad at h+1's floor would z-fight the run cell's coincident partial bottom face —
  since `bottom_face_covers` is false the M1 §6.4 suppression cannot fire; instead the fallback
  `_emit_shaped` for SLOPE cells **omits the bottom polygon when the cell below is solid-full**
  (one composed-query check; the quad below already draws) — z-fight killed, hole-free.
* Side walls (`:168-204`): the `wall_top` rule (`:185`) generalizes — a slope column caps its flat
  wall at the RUN BASE `lo` (not h/h+1) so the wall never covers the carved face; the run cells'
  own side polygons (2.3) draw the banded slope sides.
* `_emit_terrain_shapes` (`:212-229`) iterates the run `[lo, hi−1]` (via `slope_run_of`) instead
  of only h and h+1; `_emit_shaped` (`:366-377`) is reused verbatim (ShapeMesh is the one seam).
* Water pass untouched (v1 slopes are land-only, 3.2).

**4.4 Parity statement.** Both paths key appearance off the same (mat, modifier-family, state)
projection of one packed value; physics reads none of it (rule 2). The module path is frozen
tables; the fallback is direct ShapeMesh emission — "two render paths, one behaviour" holds
exactly as for LAYER/snow (SNOW-ACCUMULATION §5.1).

---

## Decision 5 — Physics/walkability intent, and the verify plan

**5.1 Physics intent (locked).** The collider, the analytic queries and the render all derive
from ONE corner tuple — **parity is the feature**; there is no approximation anywhere in the
chain (`_occ_span` composes `ShapeCodec.span`, `world_manager.gd:165-168`; `floor_under`/
`blocked`/`ceiling_scan` `:797-892`; DDA in-cell test ← `surface_tris` `:957-978`; collider
prisms ← `surface_tris`, `ground_collider.gd:506-529`; `VoxelBody` mass ← `volume`).
Walkability falls out of the existing per-frame semantics: `blocked` gates each step on
`rise > STEP_MAX (0.55)` (`:823, 836-847`) — since per-frame horizontal displacement is small, a
continuous slope of any gradient is technically ascendable in nibbles, exactly as today's 45°
ramps are; a discrete ≥ 1-block ledge still walls. **v1 locks: no slide mechanic, no explicit
steepness gate** — if "faces above 45° are unclimbable" is wanted later it is one gradient clamp
in `Player` (sample `floor_under` fore/aft), out of scope here. What the user actually reported —
the collider disagreeing with the render on steep faces — is eliminated by construction, and
that is the acceptance bar.

**5.2 Verify plan (`verify_feature.gd`, new `_test_sharp_slope()` + retargets; patterns:
`_test_snow_layer_codec` `:3877`, `_test_shapes_live` `:2756`, `_test_collider_cheap_queries`
`:1041`, `_test_mountains` `:4195`, `_test_both_paths` `:490`):**

1. **Codec/shape sweep — ALL 4096 payloads** through every query: no NaN, `span.y ∈ [0,1]`,
   `volume ∈ [0,1]` and equal to a Monte-Carlo sample within tolerance, `occupied` consistent with
   `span`, `surface_tris` non-degenerate and single-valued over XZ; canonical rules 1.3.1–1.3.4
   pinned (full / empty / legacy-collapse / uniqueness spot pairs); `canonical(pack(stone,
   make_slope(...))) == itself` for a kept tuple; junk FAM kind still strips + warns;
   `mass_of_value` pin for one tuple.
2. **Tiling proofs:** for a sampled set of tuples, stack the run (d, d−1, d−2): assert per random
   footprint the union of spans is one contiguous interval topped at `clamp(plane)` — no gap, no
   overlap; horizontal edge continuity between adjacent generated slope cells (equal H along the
   shared edge at sampled parameters).
3. **Worldgen:** (a) at a `find_mountains(1)` face: slope runs present (loud-fail-on-not-found),
   every run cell's `canonical(v) == v`, materials = surface skin above g / banded below g, ore
   absent in runs; (b) snow: a run cell above the freeze line carries `STATE_SNOW_CAPPED`;
   (c) crack audit: shared corners between slope and legacy cells quantize identically
   (`_quantized_targets` agreement over a rim sweep); (d) no-hole: sampled columns are solid from
   bedrock to the clamp plane (compose `_occ_span` up the column); (e) **wide temperate + shore +
   underwater sweeps byte-identical** (the steep predicate false ⇒ every cell equal to the
   pre-slope build, modifier axis included); (f) generator bound re-proven (3.7).
4. **The generalized collider contract:** `generated_modifier_at(x,y,z) ==
   CellCodec.modifier(generated_cell(x,y,z))` for y ∈ [g−4, g+4] over mountain AND spawn sweeps;
   memo == worker-direct (`(x,z,{})`) — the `:4141-4151` slab-contract pattern retargeted;
   collider: prisms cover a run cell (drop a VoxelBody on a face → rests on the plane, not inside
   it); `_test_collider_cheap_queries`' above-cap clause retargeted to above-run.
5. **Physics:** `floor_under` on a run cell == plane height at several footprints; `blocked` walls
   a ≥1-block discrete ledge and admits a graded face per-frame; DDA into a face hits the run cell
   with a sloped `surface_normal`; break a run cell → yields at fractional mass; detached body
   keeps its FAM modifier and meshes.
6. **Both-path mirror (module-guarded):** `arid_for_cell(pack(stone, make_slope(...)))` ==
   `gen_arid_for` mirror == the worker TYPE buffer over a mountain block (extend `_test_both_paths`
   sampling into a mountain region); unbaked payload → cube ARID (never 0); snow-capped run cell →
   `_snow_slope_arid` slot; `appearance_count` stable across resolves (frozen). Fallback: a chunk
   over a face commits slope surfaces, suppresses the z-fight bottom face, caps walls at `lo`.
7. **Retargets:** `:1059` cap contract (now a projection of item 4); the `resolve_cell` full-cube-
   below-surface comment test if any; `_test_mountains`' "stone flanks smooth" expectations
   updated from saturated-lip to slope-run (expect the NEW shapes — do not weaken).

---

## Decision 6 — PHASED build order (review gates between phases)

| Phase | Contents | Game-side? | Rough cost | Demo payoff / review gate |
|---|---|---|---|---|
| **S1 — the SLOPE family, hand-placeable** | CellCodec kind dispatch + rules 1.3; ShapeCodec branch set 2.2 (+ `_plane_at`, clip/integral helpers); ShapeMesh branch 2.3; lazy `arid_for` placement path; verify items 1–2 + placement/physics pins (place a slope cell from a verify script: stand, aim, drop a body, break) | 100% | ~2–3 days | Slope cells exist, render, collide and weigh correctly — zero worldgen change, zero regression risk. Gate: verify all-green incl. the 4096-payload sweep. |
| **S2 — worldgen emission** | 3.1 quantized targets + 3.2 predicate; 3.3/3.4 resolve_cell runs (carve + cap + wrappers + ore skip); 3.5 memo repack + `generated_modifier_at`/`slope_run_of`; 3.6 collider loop; 4.1–4.3 manifests + worker arm + fallback; verify items 3–7 | 100% | ~4–6 days | **The mountains**: steep faces read as clean diagonal slopes on the live web build; the staircase of pyramids is gone. Gate: contract + byte-identity sweeps green; setup timing print within budget. |
| **S3 — polish** | Trim-ladder measurement on the web export; snow-line visual pass (capped slope skin); fallback wall/bottom-face edge cases; optional: extend emission to badlands/underwater (re-opens the wet-twin budget — explicitly deferred) | 100% | ~1–2 days | Tuned budget, documented visuals; risks re-audited. |

Each phase independently shippable and `/steelman`-gated per standing policy. Conventional
Commits, scope `voxiverse`, on a `feat/voxiverse-sharp-slope` branch off the current integration
branch.

---

## Decision 7 — Minimal scope (pre-authorized fallback) 

If the S2 budget or schedule forces a cut, the minimal scope that still removes the "stacked
pyramids" is: **S1 + S2 with materials {stone} only and snow variants {stone} only**, dry land
only, `SLOPE_MAX_SPREAD = 2` (runs ≤ 2 cells). Mountains — the only place the artifact is
prominent — get exact planar faces; rare steep spots in other biomes keep today's saturated look
(unchanged, not worse). Everything else in this ADR is unchanged by the cut; widening back is
data (constants + sample sets), not design.

---

## Decision 8 — Engine-patch analysis (verdict: none needed)

* **Native "steep-slope pass" in the blocky mesher** — rejected. It would live in the same
  hottest mesher loops as the fluid pass; the waterlogging patch class was priced at ~400–600 LOC
  in MULTI-MATERIAL §3b and rejected there for snow; this is strictly larger (~600–1000 LOC:
  per-cell family decode, clip triangulation, side-pattern generation) and buys nothing the baked
  `VoxelBlockyModelMesh` route (shipped and proven for 79 legacy shapes + wet twins + snow
  variants) doesn't already deliver. Rebuild cost alone (~24 min cold builds, web-template risk,
  `module_in_web` regression surface) outweighs the 1.2 MB table it would save.
* **SDF/Transvoxel smooth mesher for mountains** — rejected. godot_voxel ships it, but it is not
  a patch: the TYPE-channel blocky pipeline, the ARID appearance model, per-cell edits, the
  analytic-physics contract and both manifests are all built on blocky cells. Mixing meshers per
  region is unsupported; converting is a re-architecture, not a feature.
* **Game-side residual** (the honest cost of no-patch): unbaked (mat, payload) pairs render as
  cubes until sampled into the manifest — bounded by the verify sample-completeness assert (the
  `emitted_modifiers` mountain discipline, `terrain_config.gd:909-917`) and by the dense 4096
  stride making the table itself never the limit.

---

## Decision 9 — Risks / open issues

1. **Bake budget** (the #1 line item, as in every manifest feature): ~150–300 readbacks /
   ~400–900 models. Bounded by the spatial sample + the 4.1 trim ladder; measured at the S2 gate
   by the existing timing print; every rung degrades to the cube fallback, never a hole.
2. **Cube-fallback silhouette mismatch on unbaked pairs** — the one place a render/physics
   mismatch can transiently reappear. Bounded by verify's sample-completeness assert over a wide
   mountain scan; the physics is still exact (the mismatch is render-larger-than-physics, the
   benign direction).
3. **Rim reshaping**: whole-block quantization at slope-adjacent corners coarsens neighbouring
   legacy ramps by ≤ 0.5 block — deterministic, crack-free (3.1), byte-changing ONLY within one
   cell of emitting columns; documented visual class, verified by the crack audit (5.2.3c).
4. **Memo/worker drift** — the perennial contract risk; killed structurally by the ONE shared
   `_slope_entry_data` predicate + the widened machine check (5.2.4). Do not implement the two
   branches separately.
5. **Clip/fan geometry epsilons** (degenerate polygons, sliver triangles at knot coincidence) —
   the `_EPS` discipline + the all-4096-payload sweep (5.2.1) fence it before any consumer ships.
6. **Ore/strata sliver removed on carved faces** (3.4) — accepted; interior ore below the run is
   untouched.
7. **Cross-ADR memo layout**: SNOW-ACCUMULATION §3.4 plans memo bits 32..39; SHARP-SLOPE takes
   40..56. Whichever lands second must honour the other's reservation (recorded in both places by
   the S2 implementer).
8. **Faces steeper than `SLOPE_MAX_SPREAD` stay blocky cliffs** — deliberate (§8 non-goal
   preserved); raising the cap later is a constant + a wider sample, not a design change.
9. **Scope guard**: no TOP-anchored slopes, no overhangs, no slide mechanic, no underwater/wet
   slope twins in v1, no SDF path, no third FAM kind, no engine patch. Anything reaching for
   those re-opens this ADR.

---

## File-by-file touch list (implementation order)

| # | file | change |
|---|---|---|
| 1 | `godot/src/world/cell_codec.gd` | `FAM_SLOPE`/`MOD_SLOPE_BIAS`, `make_slope`/`is_slope`/`slope_deltas`, `_canonical_modifier` kind dispatch + SLOPE rules 1.3 |
| 2 | `godot/src/world/shape_codec.gd` | `is_slope` branch in every public query (table 2.2); `_plane_at`, the positive-part triangle integral, the clamped-profile segment integrals, the AXIS_Y triangle clip |
| 3 | `godot/src/world/shape_mesh.gd` | SLOPE builder branch (plateau + band surface, clipped bottom, knotted sides) |
| 4 | `godot/src/world/terrain_config.gd` | `SLOPE_MAX_SPREAD`; `_quantized_targets` + `corner_whole`; `_slope_fires` + `_slope_entry_data`; resolve_cell run branches (carve/surface/cap, ore-skip guard); memo repack (bits 40..56); `generated_modifier_at` + `slope_run_of`; `surface_modifier`/`surface_cap_modifier` as projections; `emitted_slope_pairs()` |
| 5 | `godot/src/world/voxel_module/module_world.gd` | `_SLOPE_STRIDE`, `_slope_arid`/`_snow_slope_arid` bake/freeze/publish; bit-15 arm in `arid_for_cell`/`gen_arid_for`/`is_manifest_baked` + the worker generator; mesh-cache keys by raw FAM modifier |
| 6 | `godot/src/world/fallback/chunk_mesher.gd` | run iteration in `_emit_terrain_shapes`; wall_top at run base; SLOPE bottom-face suppression on solid-full below |
| 7 | `godot/src/physics/ground_collider.gd` | `_emit_column` run loop via `slope_run_of` (prisms free via `surface_tris`) |
| 8 | `godot/src/tools/verify_feature.gd` | `_test_sharp_slope()` (5.2), contract-test generalization, `_test_mountains`/cheap-query retargets |
| 9 | `docs/` | this ADR as `docs/SHARP-SLOPE.md`; SUB-VOXEL-SMOOTHING annotated ("§8 saturation superseded for spread ≤ 3 by SHARP-SLOPE"); SNOW-ACCUMULATION §3.4 memo-bits coordination note |

---

*Key sources verified while writing: `cell_codec.gd:24-67, 182-241`; `shape_codec.gd:24-129,
151-214, 222-306, 324-458`; `shape_mesh.gd:21-79`; `terrain_config.gd:39, 85-141, 368-396,
475-524, 578-650, 653-716, 722-825, 842-953, 1007-1035, 1241-1262, 1315-1370`;
`world_manager.gd:134-168, 315-391, 745-754, 797-892, 907-1027`; `module_world.gd:41-106,
159-160, 294-369, 426-525, 647-694, 703-721, 1042-1221`; `chunk_mesher.gd:66-124, 168-229,
366-377, 399-404`; `ground_collider.gd:38, 402-529`; `tree_gen.gd:30`; `zone_chunk.gd:68,
242-243`; `verify_feature.gd:1041-1077, 2756, 3877, 4141-4151, 4195`; `docs/SNOW-ACCUMULATION.md`
Decisions 1/2.7/3.4; `docs/M1-SNOWY-WORLD.md` Decisions 1-3/§6; `docs/SUB-VOXEL-SMOOTHING.md` §2,
§5, §8; `docs/MULTI-MATERIAL.md` §3a-c.*
