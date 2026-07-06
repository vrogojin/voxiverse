# VOXIVERSE — Water at the Shore: composite water-over-terrain cells, the 0.9 water surface, and underwater floor smoothing

Status: **DESIGN — approved for implementation.** Branch family: `feat/water-shore-*`.

> **ORCHESTRATOR DEVIATION (v1 scope, locked):** the **ZoneChunk `_liquid`
> serialization layer** and the associated bundle/load-path re-packs described in
> §6 and §9 are **DEFERRED out of v1** — provably dead code in v1 because liquid
> is worldgen-only and can never reach serialization (generated terrain is not
> stored in `_edits`; player placement rejects non-solid materials; `VoxelBody`
> capture strips liquid). What IS shipped and load-bearing:
> `CellCodec.pack()`/`canonical()` **preserve** bits 48..53 (fixing the historical
> ≥48 bit-drop), and `VoxelBody` capture strips liquid. `zone_chunk.gd`,
> `zone_bundle.gd`, and the load-path re-packs are **NOT changed**; verify does
> NOT test a ZoneChunk liquid round-trip. The ZoneChunk sparse liquid layer
> remains the documented future extension point when liquids become editable.

This document specifies three coupled features:

1. **Composite shore cells** — the first shipping use of the spec's "multiple
   materials may occupy one voxel" (DESIGN §7.9 / VOXEL-DATA-STRUCTURE reserved
   bits): a smoothed shore surface cell holds BOTH its terrain ramp (bottom) AND
   the water filling the remainder up to the water line, so the sea no longer
   ends in a notch against the beach ramp.
2. **The 0.9 water surface** — the top cell of every open-water column renders
   as a slightly-sunk slab (top at 0.9 blocks), not a full cube.
3. **Underwater floor smoothing** — lake/river/ocean bottoms get the same
   corner-height surface smoothing as land (currently explicitly disabled for
   `g < SEA_LEVEL`).

Everything here is designed around two hard constraints:

* **The non-solid-modifier invariant is untouched.** `CellCodec._canonical_modifier`
  keeps stripping any modifier on a material with `solidity < 0.5` ("no ramp of
  water"), and every physics/structural consumer keeps soundly ignoring
  modifiers on non-solid cells (INTEGRATION-DECISIONS §3). Water is expressed on
  a NEW, physics-invisible axis, never via the modifier.
* **The live web demo stays playable** (DESIGN §7 gate). All new worldgen is
  pure/deterministic, the module worker keeps its zero-allocation frozen-table
  discipline, and the manifest bake count grows by a sampled shore set + one
  water model, not a product.

Sibling ground truth verified while writing this design (line refs as of
`main` @ b168eea): `cell_codec.gd`, `terrain_config.gd`, `shape_codec.gd`,
`shape_mesh.gd`, `module_world.gd`, `chunk_mesher.gd`, `world_manager.gd`,
`ground_collider.gd:397-471`, `structural_solver.gd`, `per_voxel_environment.gd`,
`zone_chunk.gd`, `verify_feature.gd`, `blocks.json` (water cull_group 1,
solidity 0; ice cull_group 2, solidity 1).

---

## 1. Overview of the chosen approach

**One new orthogonal axis: LIQUID, in the packed cell value's reserved bits
48..53.** The primary (material, modifier, state) axes keep their exact meaning:
the material+modifier of a shore cell is its SOLID terrain (sand ramp), and the
liquid axis records "water also occupies this cell's remainder, with its top at
level/10 blocks". The liquid axis is:

* **a pure render + sim overlay** — no physics function reads it. `_occ_span`,
  `floor_under`, `blocked`, `aimed_voxel`, `GroundCollider`, `occludes_face`,
  and the structural solver all project mat/modifier exactly as today, so the
  merged analytic-physics contract is untouched by construction;
* **zero-cost by default** — field 0 = no liquid; every existing stored,
  generated, and edited value is already canonical; `is_plain(v)`
  (`v >> 16 == 0`) correctly reports a liquid-carrying cell as non-plain;
* **round-trip safe** — `pack()`/`canonical()` are extended to PRESERVE the
  field (⚠ today `pack()` ORs only the three low axes and `canonical()`
  re-packs through it, so bits ≥ 48 are silently DROPPED — extending both is
  mandatory, §2.2/§2.3), and ZoneChunk/zone bundles gain a sparse liquid layer
  mirroring the modifier/state layers (§6), so a saved or streamed cell can
  never silently lose its water. Player actions still never *produce* liquid
  values (placement rejects non-solid materials; break writes 0), and
  VoxelBody capture strips the field — a detaching ramp does not take the
  ocean with it.

The three requirements map onto it as:

| cell | encoding | render |
|---|---|---|
| open water, y < SEA_LEVEL | `pack(WATER)` — **byte-identical to today** | water cube (today's model, unchanged) |
| open water surface, y == SEA_LEVEL (not frozen) | `pack(WATER)` + liquid(WATER, **9**) | new baked 0.9-slab water model |
| frozen sea surface | `pack(ICE)` — unchanged | ice cube (unchanged) |
| shore composite, y == g == SEA_LEVEL, smoothed | `pack(sand, ramp)` + liquid(WATER, **9**) | two-surface model: terrain ShapeMesh + a translucent water fill up to y=0.9 that does NOT match the ramp corners (§4.3) |
| underwater floor composite, y == g < SEA_LEVEL, smoothed | `pack(sand/gravel/…, ramp)` + liquid(WATER, **10**) | the EXISTING dry shaped model (see §5.3 — the water part contributes no geometry) |
| underwater floor, flat (modifier 0) | `pack(sand/…)` — byte-identical to today | cube (unchanged) |

Water tops: **0.9 at the water line (both open water and shore composites — one
continuous surface plane at SEA_LEVEL + 0.9), 1.0 (full) for submerged
composites.**

### 1.1 Alternatives evaluated and rejected

* **Relax the modifier-strip for liquids** (give the water material a shape):
  rejected. Every physics consumer (span/floor/DDA/collider/solver) relies on
  "non-solid ⇒ modifier ignorable"; auditing and re-proving all of them for a
  cosmetic feature is the highest-risk option on the board, and it still cannot
  express *two* substances in one cell (the composite needs the terrain ramp
  AND water — one modifier field cannot carry both).
* **Composite materials** (`sand_with_water` catalog entries): rejected —
  catalog/id explosion (materials × shapes × wetness), breaks material identity
  ("a wet sand ramp IS sand"), collides with streaming's GMID model.
* **A parallel sparse water overlay dict**: rejected — the exact "second notion
  of what's here" architectural rule 1 forbids; also useless for *generated*
  water (millions of cells can't live in a dict; worldgen must stay a pure
  function).
* **Chosen: liquid axis in the reserved bits** — orthogonal, zero-cost default,
  generated functionally, invisible to physics, and the natural first tenant of
  the reserved band VDS §3.3 set aside for exactly this kind of growth.

---

## 2. Bit layout and CellCodec API

### 2.1 Layout (bits 48..62 were reserved; bit 63 stays 0)

```
 bit 63   62……54   53      50 49    48 47        32 31        16 15         0
┌───┬───────────┬────────────┬─────────┬────────────┬────────────┬────────────┐
│ 0 │ reserved  │ LIQ_LEVEL  │ LIQ_KIND│   STATE    │  MODIFIER  │  MATERIAL  │
│   │  (= 0)    │  (4 bits)  │ (2 bits)│            │            │    LRID    │
└───┴───────────┴────────────┴─────────┴────────────┴────────────┴────────────┘
LIQ_KIND:  0 = none (whole 6-bit field MUST be 0), 1 = WATER, 2..3 reserved (lava, …)
LIQ_LEVEL: liquid top height in TENTHS of a block, canonical range 1..10;
           9 = the sunk water surface (0.9), 10 = full (submerged).
value 0 == air, unchanged. A bare legacy id is still a canonical packed value.
```

The STATE axis (bits 32..47) is **already in live use** (`set_state`, verify's
state=5 round-trips) and must NOT be overloaded for this — the liquid field
lives strictly in the reserved band 48..62, which an Explore audit confirmed
is provably free today.

Why tenths (not eighths): the one shipped constant is exactly 0.9 — a tenths
field represents it exactly (an eighths code would quantize it to 0.875), costs
the same 4 bits, gives lava/flow features a future foothold, and makes the
level ↔ render-height relation trivially assertable (`level / 10.0 == top`).

### 2.2 CellCodec additions (godot/src/world/cell_codec.gd)

```gdscript
## Liquid axis (WATER-SHORE §2): bits 48..53. Kind in 48..49, level (tenths) in 50..53.
const LIQ_SHIFT := 48
const LIQ_FIELD_MASK := 0x3F
const LIQ_KIND_MASK := 0x3
const LIQ_NONE := 0
const LIQ_WATER := 1
const LIQ_LEVEL_SURFACE := 9      # top at 0.9 — the water-line cell
const LIQ_LEVEL_FULL := 10        # top at 1.0 — submerged composite

static func liquid_field(v: int) -> int:  return (v >> LIQ_SHIFT) & LIQ_FIELD_MASK
static func liquid_kind(v: int) -> int:   return (v >> LIQ_SHIFT) & LIQ_KIND_MASK
static func liquid_level(v: int) -> int:  return (v >> (LIQ_SHIFT + 2)) & 0xF
static func liquid_top(v: int) -> float:  return float(liquid_level(v)) / 10.0
static func strip_liquid(v: int) -> int:  return v & ~(LIQ_FIELD_MASK << LIQ_SHIFT)
static func make_liquid(kind: int, level: int) -> int:
    return (kind & LIQ_KIND_MASK) | ((level & 0xF) << 2)      # the 6-bit field value
static func with_liquid(v: int, kind: int, level: int) -> int:
    return strip_liquid(v) | (make_liquid(kind, level) << LIQ_SHIFT)
```

`pack()` gains an optional trailing arg: `pack(mat, modifier := 0, state := 0,
liquid := 0)` (`| ((liquid & 0x3F) << 48)`); all existing call sites compile
unchanged. Bits 54..62 and 63 are masked to 0 by construction.

⚠ **Load-bearing detail:** today's `pack()` composes ONLY the three low fields,
and `canonical()` returns `pack(m, cm, _validate_state(...))` — i.e. the
current code path **silently drops bits ≥ 48**. Both MUST be extended in the
same change that introduces the field (canonical carries the liquid field
through `_canonical_liquid`, §2.3), and verify pins a
`canonical(with_liquid(...)) preserves the field` assert so a future refactor
cannot regress this.

### 2.3 Canonicalization rules (`canonical()` gains a `_canonical_liquid` hook)

Applied after the existing air-zeroing / modifier / state steps, mirroring the
`_canonical_modifier` style (strip + `push_warning` on violations; silent strip
where 0 is simply "absent"):

1. `mat == AIR` → whole value 0 (unchanged rule; liquid cannot ride air — open
   water is the water MATERIAL, never air+liquid).
2. `kind == 0` → field := 0 (silently; level bits without a kind mean nothing).
3. `kind != 0 and level == 0` → field := 0 (silently).
4. `level > 10` → clamp to 10.
5. Host is **non-solid** (`solidity_of(mat) < 0.5`, i.e. the cell IS a liquid):
   the kind must equal the material's own liquid identity
   (`BlockCatalog.liquid_kind_of(mat)`, §2.4) — mismatch strips with a warning.
   `level == 10` strips to field 0: **the bare water id IS the canonical full
   water cell** (keeps today's stored/generated deep-water values canonical and
   equality-comparable; two encodings of the same cell are forbidden).
   Levels 1..9 are kept (level 9 = the surface cell).
6. Host is **solid**: `modifier == 0` (a full cube has no remainder) strips the
   field with a warning — waterlogged full cubes are explicitly out of v1 scope.
   Any `modifier != 0` (either anchor) may carry liquid.

The existing modifier-strip for non-solid materials (`_canonical_modifier`,
cell_codec.gd:80-103) is **not modified in any way**.

### 2.4 One tiny BlockCatalog accessor

```gdscript
## Liquid identity of a material: CellCodec.LIQ_WATER for the water material,
## LIQ_NONE otherwise. Resolved once in ensure_ready() (id_of(&"water")).
static func liquid_kind_of(block_id: int) -> int
```

(Data-driven `"liquid_kind"` in blocks.json is a future nicety; a name-keyed
resolve matches how TerrainConfig already caches `_ID_WATER`.)

---

## 3. Worldgen rule changes (terrain_config.gd, function by function)

New constant: `const WATER_SURFACE_HEIGHT := 0.9` — the render height of the
water surface; verify pins `roundi(WATER_SURFACE_HEIGHT * 10.0) ==
CellCodec.LIQ_LEVEL_SURFACE`.

**The generated-liquid rule (the one rule everything below implements):**

> A cell carries liquid(WATER, L) iff it is at or below the water line
> (`y <= SEA_LEVEL`) and is either (a) the open-water/sea-fill cell itself, or
> (b) the smoothed SOLID surface cell of its column (`y == g`,
> `modifier != 0`). L = `LIQ_LEVEL_SURFACE` (9) when `y == SEA_LEVEL`, else
> `LIQ_LEVEL_FULL` (10). Exception: in a frozen climate (`t < -0.55`) the
> `y == SEA_LEVEL` cell is the ice regime — no liquid overlay there (the ice
> cube for open sea, the bare ramp for a smoothed frozen shore; the sheet ends
> crisply as today). Water strictly below the ice (`y < SEA_LEVEL`) is liquid
> as normal.

### 3.1 `_sea_block(t, y)` — returns a packed value

```gdscript
static func _sea_block(t: float, y: int) -> int:
    if y == SEA_LEVEL:
        if t < -0.55:
            return _ID_ICE                                   # frozen cap (unchanged)
        return CellCodec.pack(_ID_WATER, 0, 0,
            CellCodec.make_liquid(CellCodec.LIQ_WATER, CellCodec.LIQ_LEVEL_SURFACE))
    return _ID_WATER                                          # deep water: byte-identical
```

Deep water (`y < SEA_LEVEL`) stays the bare id — canonical rule §2.3.5 makes
the bare id THE full-water encoding, so all existing deep-water output is
byte-identical.

### 3.2 `resolve_cell(...)` — two gate changes + liquid composition

* **Cap branch (y == g+1): UNCHANGED** — caps remain land-only
  (`g >= SEA_LEVEL`). Decision: **no underwater caps in v1** (§3.6).
* **Surface branch: the `g >= SEA_LEVEL` gate is REMOVED** and the result is
  composed with the liquid rule:

```gdscript
    if y == g:
        return _with_shore_water(_smoothed_surface(x, z, g, id, pcache), y, t)
    return id
```

```gdscript
## Compose the generated-liquid rule (WATER-SHORE §3) onto a SURFACE cell value.
## Pure: reads only (v, y, t). No-op above the water line, on a full-cube
## surface (no remainder), and in the frozen regime at the water line.
static func _with_shore_water(v: int, y: int, t: float) -> int:
    if y > SEA_LEVEL or CellCodec.modifier(v) == 0:
        return v
    if y == SEA_LEVEL and t < -0.55:
        return v                                              # frozen shore: ice regime
    var lvl := CellCodec.LIQ_LEVEL_SURFACE if y == SEA_LEVEL else CellCodec.LIQ_LEVEL_FULL
    return CellCodec.with_liquid(v, CellCodec.LIQ_WATER, lvl)
```

### 3.3 `_shape_entry(x, z)` — enable the underwater SURFACE modifier

```gdscript
    if SMOOTHING_ENABLED and TreeGen.block_at(x, g + 1, z) == BlockCatalog.AIR:
        var t := _corner_targets(x, z)
        sm = _modifier_from_targets(t, g)                     # now also for g < SEA_LEVEL
        if g >= SEA_LEVEL:                                    # caps stay LAND-ONLY (§3.6)
            cm = _modifier_from_targets(t, g + 1)
```

The memo packing (`g+bias | sm<<16 | cm<<24`) is unchanged (all emitted
modifiers stay BOTTOM-anchored `< 256`). The TreeGen probe on ocean columns
returns AIR (trees are biome-gated off ocean/beach), so the uniform check is
harmless and keeps one code path.

### 3.4 `surface_modifier` / `surface_cap_modifier` (the light collider queries)

* `surface_modifier`: **delete** the `if g < SEA_LEVEL: return 0` early-out
  (line 566-567). Both the memo and the direct branch must agree (the direct
  branch has no other underwater gate — deleting the early-out is the whole
  change).
* `surface_cap_modifier`: **keep** its `g < SEA_LEVEL → 0` gate (caps are
  land-only). The docstrings' "underwater floor is never smoothed" sentences
  are updated.
* The equality contract these queries advertise —
  `surface_modifier(x,z) == CellCodec.modifier(generated_cell(x, g, z))` — now
  holds over water too and is verified there (§7).

### 3.5 The appearance manifest

* `appearance_surface_materials()`: **add `_ID_GRAVEL`** (the only
  `_underwater_floor` material not already listed; sand/red_sand/mud are).
* `emitted_modifiers()`: the sample must (a) **stop skipping `g < SEA_LEVEL`
  columns** and (b) actually contain coastline/ocean. Refactor the body into
  `_sample_emitted(center: Vector2i, r: int, seen: Dictionary)` and run it for
  TWO deterministic centres: `find_spawn()` (as today) and a new
  `find_coast()`; union the results. Cap modifiers are still collected only
  for `g >= SEA_LEVEL` (matching §3.3).
* New `find_coast() -> Vector2i`: same outward scan pattern as `find_spawn`
  (radius 0..512 step 4, 15° steps), returning the first column with
  `g == SEA_LEVEL` (fallback `Vector2i(0, 0)`). Deterministic, main-thread,
  setup-time only.
* New `emitted_shore_pairs() -> PackedInt32Array`: the sampled set of
  **(surface material, modifier) pairs the shore composite actually emits**,
  encoded as the SAME slot the module manifest uses:
  `slot = mat * 256 + modifier`. Sampled over the `find_coast()`-centred
  region: for every column with `g == SEA_LEVEL`, non-frozen
  (`column_profile().w >= -0.55`), and `sm != 0`, record
  `_biome_top(biome, x, z) * 256 + sm`. Needs `column_profile` per qualifying
  column only (few); cached statically like `_emitted_mods`; a rare unsampled
  pair renders as the DRY shaped model on the worker (graceful, §5.2 — a notch,
  never a hole). Like `emitted_modifiers` it is a deliberate superset/sample:
  correctness never depends on completeness.

### 3.6 Decision: underwater floor smoothing is SURFACE-CELL ONLY (no caps)

With caps, a 1-block underwater step smooths fully; without, a half-block ledge
remains at step boundaries (the upper column's surface still ramps 0.5→1).
Underwater, viewed through low-alpha water, that residual is minor — while
underwater caps would drag in: the cap branch of `resolve_cell` displacing sea
fill, `_surface_cap` needing the `_underwater_floor` material (biome+t
plumbing), collider cap emission for submerged columns
(`ground_collider.gd:450` gate), cap composites needing their own wet handling,
and a bigger manifest. Cut for v1; re-evaluate after the floor smoothing ships
(the seam is one gate in §3.3/§3.4 plus `resolve_cell`'s cap condition).

### 3.7 What is deliberately NOT changed

`height_at`, `column_profile`, `_corner_targets`, `_modifier_from_targets`,
`_biome/_biome_top/_underwater_floor`, TreeGen, spawn logic, the memo threading
rules, `MAX_SURFACE_Y`, and the whole sub-surface pipeline. Underwater columns'
corner targets were always computed from the full 3×3 stencil (including
underwater neighbours), so shore/floor shapes need no new stencil math and are
crack-free against land smoothing by the same shared-corner argument.

---

## 4. Render path A — godot_voxel module (module_world.gd + new water_mesh.gd)

### 4.1 New geometry builders — `godot/src/world/water_mesh.gd` (new file)

Same `{verts, normals, uvs, indices}` dictionary format as `ShapeMesh.build`
(pure, static, deterministic). The 0.9 constant is read from
`TerrainConfig.WATER_SURFACE_HEIGHT`.

```gdscript
class_name WaterMesh
static func surface_slab() -> Dictionary
    # The open-water surface cell: top quad at y = 0.9, four side quads y in
    # [0, 0.9], bottom quad at y = 0. (Bottom/side faces are pattern-culled by
    # the mesher against seafloor/neighbour slabs; they exist so a slab exposed
    # by an edit — e.g. a drained hole beside it — still closes the volume.)
static func shore_fill() -> Dictionary
    # The shore-composite water overlay: a translucent BOX from the cell floor
    # up to y = 0.9 (full cell footprint) that deliberately does NOT match the
    # terrain ramp's corners. The opaque ramp (the primary axis) occupies the
    # bottom of the cell and shows THROUGH the translucent water; box geometry
    # below/inside the ramp is depth-hidden overdraw. The top face is the
    # visible water surface; side/bottom faces close the fill where the ramp
    # is cut away. MINIMAL FORM: the top quad alone is sufficient where every
    # lateral neighbour is water or taller land (the generated common case) —
    # implementers may ship the full box first (simplest, per the Explore
    # recommendation) and trim faces later; either form is per-modifier-
    # INDEPENDENT, so the mesh is shared across all modifiers and materials.
```

`ShapeCodec`/`ShapeMesh` are untouched — the Explore audit confirmed their
vertical granularity is HALF-BLOCK ONLY (corners ∈ {0,1,2}), so a 0.9 top is
NOT expressible in the corner-height family and must not be forced into it.
That is exactly why the water geometry is a dedicated lightweight builder
(option (a)) rather than a new fine-grained shape family (option (b),
rejected: it would multiply the codec, canonicalization, physics span math and
the manifest for one constant).

### 4.2 Manifest additions (`_build_gen_manifest`) and the frozen tables

Two new frozen publications to the worker, built and baked at setup **before**
the generator is wired (same thread/publish discipline as `_gen_arid`):

```gdscript
var _gen_wet_arid: PackedInt32Array   # slot = mat*_GEN_STRIDE + modifier -> ARID; -1 = not baked
var _water_surface_arid := -1         # the 0.9 water slab model's ARID
```

* For every slot in `TerrainConfig.emitted_shore_pairs()`: build a **wet
  composite model** (§4.3), append with the existing anti-drift assert
  (`add_model() == expected ARID`), record in `_gen_wet_arid`.
* Append ONE water-surface slab model: `VoxelBlockyModelMesh` from
  `WaterMesh.surface_slab()`, material `BlockMaterials.get_for(water)`,
  `set_transparency_index(BlockCatalog.cull_group_of(water))` (= 1, matching
  today's water cube so slab↔cube culling behaves).
* One batched `bake()` covers dry manifest + wet manifest + slab (extend the
  existing single-bake structure; keep the setup timing print).
* Bake-count control: wet models are `|emitted_shore_pairs|` (a sampled coastal
  set — expected tens, not hundreds) + 1. Any unbaked wet pair falls back to
  the DRY shaped model; an unbaked slab falls back to the water cube ARID —
  never a hole, wrong water top only, logged.

### 4.3 The wet composite model (`_make_wet_model(modifier, terrain_material)`)

One `VoxelBlockyModelMesh` whose ArrayMesh has **two surfaces**:
surface 0 = `ShapeMesh.build(modifier)` with `set_material_override(0,
terrain_material)`; surface 1 = `WaterMesh.shore_fill()` with
`set_material_override(1, BlockMaterials.get_for(water))`. Because the water
fill is modifier-independent (§4.1 — it never matches the ramp corners), mesh
resources are shared across materials via a cache keyed
`modifier | WET_MESH_FLAG` (the `_shape_mesh_cache` trick — the terrain
material differs only via the override), and the manifest stays one model per
emitted shore (mat, modifier) pair with no water-shape multiplier.

**Transparency index of the wet model: 0 (opaque), deliberately.** The model's
occlusion role is its terrain ramp; marking it translucent would let adjacent
water cull the ramp's side trapezoids (holes in the terrain seen through
water). Consequences audited in §4.4.

### 4.4 Module-path culling audit (VoxelMesherBlocky side patterns + transparency index)

| face pair | outcome |
|---|---|
| slab ↔ slab (lateral, both y = SEA_LEVEL) | identical baked side patterns + equal index (1) → culled ✓ |
| slab bottom ↔ water cube / solid floor below | neighbour's +Y pattern full, index ≤ 1 → culled ✓ |
| water cube top ↔ slab above | slab's −Y pattern full (bottom quad) → culled ✓ |
| slab side ↔ wet/dry shore composite | composite is opaque (0 ≤ 1) but its side pattern is only the ramp trapezoid → **slab side draws** where not covered: a vertical water pane closing the sea volume at the last full-water cell. Intended ✓ (the notch above the ramp renders as water via the composite's own 0.9 fill from above). With the full-box fill the composite's own side face doubles that pane (two coincident/adjacent translucent faces at the boundary — a slightly stronger tint line, accepted; trimming to the top-quad-only fill removes it). |
| composite faces ↔ any water neighbour | water (index 1) never occludes an opaque (0) model → terrain trapezoids always drawn ✓; the composite's water fill is visible surface where the ramp is below 0.9 and depth-tested away where the ramp rises above it ✓ |
| water-cube bottom face over an **underwater smoothed** floor cell | the floor cell's +Y pattern is no longer full (ramp) → the cube's bottom face draws: a faint level tint band across smoothed floor cells, visible only through/under water. **Accepted cosmetic cost (v1)** — the underwater composite deliberately carries no water geometry (adding a coincident sloped water skin would z-fight the terrain; adding a top quad would draw the identical plane). Noted refinement: a full-cover +Y pattern with no visible geometry, IF godot_voxel's baked-pattern semantics allow it — requires experimentation, out of scope. |

### 4.5 Worker generator (the runtime-compiled `_generate_block`)

Extend the per-cell ARID resolve (module_world.gd:580-599) — reads only the two
new frozen publications, zero allocation, no new branches on the deep-water /
sub-surface fast paths:

```gdscript
    var v = TerrainConfig.resolve_cell(wx, oy + y, wz, g, biome, cc, tt, pcache)
    var id = CellCodec.mat(v)
    if id == 0: continue
    var modifier = CellCodec.modifier(v)
    var arid = 0
    if CellCodec.liquid_level(v) == 9:
        if modifier == 0:
            # the open-water surface cell (mat == water by construction)
            arid = water_surface_arid if water_surface_arid >= 0 else (cube_arid[id] if id < ncube else id)
        else:
            var wslot = id * GEN_STRIDE + modifier
            if wslot < nwet and gen_wet_arid[wslot] >= 0: arid = gen_wet_arid[wslot]
            elif ...:  # dry-shape fallback, then cube fallback (existing chain)
    elif modifier == 0:
        arid = cube_arid[id] if id < ncube else id            # unchanged fast path
    else:
        ... existing dry-slot resolve ...                      # liquid level 10 lands here: DRY model (§4.4)
```

(Note `liquid_level == 10` intentionally falls into the existing dry resolve —
submerged composites render their terrain shape only.)

### 4.6 `set_cell` / `arid_for` / `gen_arid_for`

`set_cell` resolves through the same rule: if `liquid_level(packed) == 9`,
consult `_water_surface_arid` / `_gen_wet_arid` first, else the existing
resolve. `arid_for` keeps its signature for dry values; no lazy wet allocation
is added (nothing player-facing produces wet values — placement rejects
non-solid materials and never fabricates liquid bits; loaded zones carry none).
`gen_arid_for` (the verify mirror) is extended identically so
`_test_both_paths` can round-trip coastal blocks.

---

## 5. Render path B — GDScript fallback (chunk_mesher.gd) — OPTIONAL, LOWER PRIORITY

Ground truth (confirmed by the Explore pass): the fallback today renders **no
water at all** (it is a heightmap skin over `effective_height`; water is
non-solid, so the sea/ice cells above `g` are simply never emitted). The LIVE,
playable-web path is the module (`module_in_web=yes`), which draws water as a
translucent cube per id. **Therefore the behavioural-parity rule is already
relaxed for water on this path, and fallback water rendering is a
NICE-TO-HAVE, not a blocker**: §5.1 lands for free with Stream A; §5.2 is a
separate low-priority stream that must not gate the feature, the verify run,
or the deploy.

### 5.1 Existing passes — behaviour inherited for free

* `_emit_terrain_shapes` already emits ShapeMesh geometry for ANY shaped solid
  surface/cap cell it finds via `cell_value_at` — once worldgen emits
  underwater surface modifiers (§3), smoothed seafloor ramps render with no
  mesher change. `_emit_tops`' shaped-cell exclusion and `_emit_sides`'
  `wall_top` capping are keyed on the same modifier and also apply unchanged.
* `CellCodec.modifier()` masks bits 16..31 only, so liquid bits never perturb
  `topmods`/greedy keys.

### 5.2 New pass (optional): `_emit_water(tools, world, hmap, stride, n, x0, z0)`

Per interior column (h = the column's effective height from `hmap`):

1. `h < SEA_LEVEL` (open water / submerged column): read
   `id = world.block_id_at(Vector3i(x, SEA_LEVEL, z))`:
   * water → emit one horizontal quad at `SEA_LEVEL + WATER_SURFACE_HEIGHT`
     into `_tool_for(tools, water_id)` (world-planar UVs like the tops);
   * ice → emit the ice cube via the existing `_emit_cube` (fixes the frozen
     sea being invisible on the fallback, three lines);
   * anything else (player placed a block at the water line / dug column —
     the overlay projects through `block_id_at`) → emit nothing. This is what
     keeps dug shafts below sea level dry: their overlay cells are 0.
2. `h == SEA_LEVEL` (potential shore composite): read
   `v = world.cell_value_at(Vector3i(x, h, z))`; if
   `CellCodec.liquid_level(v) == CellCodec.LIQ_LEVEL_SURFACE` emit the same
   0.9 quad (the shore water surface — same plane as (1), continuous).

Simple per-column quads (no greedy merge) are acceptable for the safety-net
path (~≤1024 extra quads per fully-oceanic chunk); a follow-up may merge
equal-height water runs with the `_emit_tops` machinery. Known accepted gaps
(pre-existing fidelity class of this path, documented in the file header):
no vertical water side faces where water meets air laterally, no underwater
tint faces.

### 5.3 Both paths, one behaviour — the parity statement

Gameplay parity is exact by construction regardless of §5.2 (both paths read
the same `resolve_cell` output and the same physics queries; the fallback's
shaped-floor rendering in §5.1 needs no code). Visual parity for WATER is
explicitly relaxed on the fallback (it has never drawn water); if/when §5.2
lands, both paths draw the water surface at `SEA_LEVEL + 0.9` including over
shore composites, and residual deltas (the module's volume-boundary panes and
underwater tint band) remain within the fallback's documented "safety net"
fidelity class — called out in the chunk_mesher header comment.

---

## 6. Physics / sim / occlusion audit (nothing reads the liquid axis)

| consumer | verdict |
|---|---|
| `_occ_span` (world_manager.gd:165) | reads `mat` + `modifier` projections only → composite = its ramp interval; open water = empty span. **No change.** |
| `floor_under` / `blocked` / `_headroom_clear` / `ceiling_scan` | compose over `_occ_span` → wading over a shore composite stands on the ramp exactly as on dry land; water columns scanned through to the (now smoothed) floor, whose `local_top` is continuous. **No change.** |
| `aimed_voxel` / `_ray_vs_partial` | material gate skips water (incl. the 0.9 surface cell — you aim through it, unchanged); a composite is solid → the existing in-cell ramp test runs on its modifier. The water overlay is not aimable, matching water today. **No change.** |
| `GroundCollider` (`_emit_column`) | **zero code change.** Underwater surface cells now yield prisms instead of a full top box automatically via `surface_modifier` (line 422 — the light query whose underwater early-out §3.4 removes); the `y <= SEA_LEVEL` sea-fill box (line 454, debris floats on water — an existing, intentional behaviour) and the land-only cap query (line 450) are untouched. Verify extends the cheap-query equality sweep to underwater columns. |
| `StructuralSolver` / collapse | graph nodes via `cell_solid` (mat only); joints via `contact_area(modifier…)` — the composite participates as its ramp. A smoothed floor ramp rests on the full cube below with horizontal contact 1.0 (BOTTOM shape ⇒ full bottom region), same as land smoothing (live + verified). **No change.** |
| `VoxelBody` capture | `_structural_update`'s `comp_ids[c] = cell_value_at(c)` becomes `CellCodec.strip_liquid(cell_value_at(c))` — a detaching shore ramp does not take the ocean with it (one-line change, world_manager.gd:690). Mass/mesh already key off mat/modifier and would ignore the bits, but the contract is "liquid never leaves worldgen". |
| `occludes_face` | reads mat solidity + transparency index + `side_profile_full(modifier)` — composite occludes exactly as its ramp; water never occludes. **No change.** |
| `break_terrain` / `place_block` | break returns the composite's MATERIAL (sand — the hotbar contract); the cell becomes overlay-0 air and the overlay wins over generation, so a dug shore/floor hole is dry (consistent with today's no-flow water). Placement still rejects non-solid materials and writes values without liquid bits. **No change.** |
| `PerVoxelEnvironment` | derives from `height_at` only; y > g stays "air voxel" (incl. water/slab/composite-overlay space); the frozen-sea seam (surface < SEA_LEVEL, y ≤ SEA_LEVEL, w < −0.55 → −8 °C) is untouched and re-asserted. **No change.** |
| ZoneChunk / bundles | **extended to round-trip the liquid field.** `zone_chunk.gd` gains a third sparse layer `_liquid: Dictionary` (local_idx → 6-bit field, recorded only when non-zero — exactly the `_modifier`/`_state` pattern, so the zero-cost-default guarantee holds: an all-dry chunk allocates nothing) in `set_cell`/`set_cell_keyed`, a `liquid_at(idx)` reader, and serialization mirroring the state layer. `WorldManager.load_edits`/`load_bundle` re-pack via `CellCodec.pack(id, modifier, state, liquid)`. Player actions never produce liquid overlay values, but a bulk-injected/streamed zone that carries them can no longer silently lose water. |
| HUD / inventory | thermometer reads the environment; hotbar never holds water (placement gate). **No change.** |

---

## 7. Determinism & threading

* All new worldgen is a pure function of (SEED-derived noise, position):
  `_with_shore_water` reads only (v, y, t); `_sea_block` only (t, y);
  `find_coast`/`emitted_shore_pairs` only `column_profile`/`height_at`. No
  `randi()`, no `Time`, no per-run state.
* `_shape_memo` stays main-thread-only with its existing `pcache == null` +
  main-thread guards; the underwater surface modifier flows through the same
  memo slot (still 8 bits). The voxel worker keeps passing a non-null `pcache`
  and never touches the memo.
* `_gen_wet_arid` / `_water_surface_arid` follow the `_gen_arid` publish
  discipline exactly: built, asserted, baked and **frozen on the main thread in
  `setup()` before the generator object is wired**; the worker only reads.
  `emitted_shore_pairs()` (like `emitted_modifiers()`) is main-thread,
  setup/verify-only.
* Byte-identity: deep water, all sub-surface cells, all land cells, ice, and
  flat underwater floors generate byte-identical values to today. The ONLY
  changed generated values are (a) the y == SEA_LEVEL open-water cell (+liquid
  field), (b) smoothed surface cells with g ≤ SEA_LEVEL (new modifier and/or
  +liquid field). Existing verify sweeps that assert via `generated_block`
  (mat projection) are unaffected; sweeps asserting the OLD underwater
  suppression flip (§8, "existing-test impact").

---

## 8. Verification plan (verify_feature.gd)

New `_test_water_shore()` (plus targeted edits to existing tests), following
the `_ok()` pattern:

1. **Codec:** liquid pack/project round-trip over kinds×levels; canonical
   strips: liquid-on-air → 0; kind-0-with-level and level-0-with-kind → field
   0; level 11+ clamps to 10; (water, 10) on the water material → bare id;
   liquid on a solid FULL cube strips + warns; liquid kind ≠ host liquid on a
   non-solid host strips; bit 63 == 0 and bits 54..62 == 0 after any pack;
   modifier-on-water still strips (regression on the untouched invariant);
   `is_plain` false for any liquid-carrying value; `strip_liquid` exact;
   **preservation pin**: `canonical(with_liquid(valid composite))` keeps the
   liquid field bit-exactly (guards the historical `pack()`-drops-bits-≥48
   behaviour from regressing back in, §2.2).
2. **Constants:** `roundi(TerrainConfig.WATER_SURFACE_HEIGHT * 10) ==
   CellCodec.LIQ_LEVEL_SURFACE`.
3. **Worldgen — the composite exists:** locate via `find_coast()` a non-frozen
   column with `g == SEA_LEVEL` and `surface_modifier != 0`; assert its
   surface value has a solid material, `modifier != 0`,
   `liquid == (WATER, 9)`. Locate a smoothed underwater column
   (`g < SEA_LEVEL`, `sm != 0`): assert `liquid == (WATER, 10)`. Deep flat
   floor cell: bare id, liquid field 0 (byte-identity). Open water at
   SEA_LEVEL: mat water + level 9; at SEA_LEVEL−1: bare water id. Frozen ocean
   surface: ice, field 0; a frozen smoothed shore cell: modifier ≠ 0, field 0.
4. **Underwater smoothing engages & agrees:** over an ocean-crossing sweep, at
   least one `g < SEA_LEVEL` column has `sm != 0`;
   `surface_modifier(x, z) == CellCodec.modifier(generated_cell(x, g, z))` for
   underwater columns (extends `_test_collider_cheap_queries`' contract);
   memo path == direct path == worker-`pcache` path (extends
   `_test_shape_memo` to underwater columns); `generated_cell` sampled twice
   is identical including bits 48+.
5. **Physics through water (regression + new):** `floor_under` over a
   composite equals `g + local_top(sm, fx, fz)` and over open water reaches
   the smoothed seafloor; `blocked` false wading across the shore ramp;
   `aimed_voxel` from above water hits the composite's ramp in-cell (not the
   water); breaking the composite returns the terrain material and leaves the
   cell air; after the scripted world loop `_edits` contains no
   liquid-carrying value (player actions never fabricate liquid — placement
   rejects non-solid materials, break writes 0).
   **5b. Zone round-trip:** write a liquid-carrying composite through
   `_write_cell`, `save_edits` → serialize → `load_edits` into a fresh
   overlay: the liquid field survives bit-exactly (extends `_test_zonechunk`);
   an all-dry chunk's serialized payload stays byte-identical to pre-change
   output (the absent-layer zero-cost assert).
6. **Manifest coverage:** every (mat, modifier) emitted by an underwater
   surface sweep ∈ the dry emitted set ∪ per-material coverage (gravel now
   present in `appearance_surface_materials`); every non-frozen shore-emitted
   pair ∈ `emitted_shore_pairs()` over the sampled coast region (superset
   language mirroring the existing emitted-modifiers assert).
7. **Module path (guarded by `ClassDB.class_exists("VoxelTerrain")`, like
   `_test_both_paths`):** drive the generator over a coastal block; for each
   sampled cell, mapping its buffer ARID back through
   `gen_arid_for`-extended resolves to `resolve_cell`'s (mat, modifier,
   liquid-variant) — i.e. surface water cells carry `_water_surface_arid`,
   baked shore composites their wet ARID, level-10 composites their dry ARID;
   anti-drift held (`appearance_count()` == library models).
8. **Collider:** extend the collider sweep bands (the `is_sea` branches of
   `_test_collider_amortized`/`_test_collider_overlay_cases`) so underwater
   surface prisms are exercised; loose-debris-floats-on-water behaviour
   re-asserted unchanged.

**Existing-test impact (implementers: expect these, do not "fix" them by
weakening):** `_test_shape_memo` (line ~555) and `_test_smoothing`
(line ~654) contain explicit `g < SEA_LEVEL → modifier == 0` assertions —
these encode the OLD suppression and must be inverted/retargeted per §3. All
sea assertions in `_test_stackup`/`_test_worldgen` use `generated_block`
(mat projection) and stay green.

---

## 9. Implementation checklist — ordered, in independent work-streams

Contracts are frozen by this document; Stream A lands first (it owns the
shared contracts); B and D then proceed in parallel with no file overlap.
Stream C is optional/lower-priority (§5) and never gates the others.

### Stream A — Codec + worldgen core + persistence *(owns: `godot/src/world/cell_codec.gd`, `godot/src/world/terrain_config.gd`, `godot/src/sim/block_catalog.gd` (one accessor), `godot/src/world/zone_chunk.gd`, `godot/src/world/world_manager.gd` (capture strip + the two load-path re-packs))*

1. `CellCodec`: constants + `liquid_field/kind/level/top`, `make_liquid`,
   `with_liquid`, `strip_liquid`, `pack(..., liquid := 0)`; `_canonical_liquid`
   wired into `canonical()` per §2.3. ⚠ `pack()` and `canonical()` MUST now
   carry bits 48..53 through (today they drop everything ≥ 48 — §2.2). Header
   bit-diagram updated.
2. `BlockCatalog.liquid_kind_of()` (§2.4).
3. `TerrainConfig`: `WATER_SURFACE_HEIGHT`; `_sea_block` packing (§3.1);
   `resolve_cell` surface-gate removal + `_with_shore_water` (§3.2);
   `_shape_entry` underwater surface modifier (§3.3); `surface_modifier`
   early-out removal (§3.4); manifest additions — gravel,
   two-centre `emitted_modifiers`, `find_coast`, `emitted_shore_pairs` (§3.5).
   Update the stale "underwater floor is never smoothed" comments.
4. `ZoneChunk`: sparse `_liquid` layer (record-when-nonzero, `liquid_at(idx)`,
   serialization mirroring the state layer — §6 ZoneChunk row);
   `WorldManager.load_edits`/`load_bundle` re-pack with the liquid arg.
5. `WorldManager._structural_update`: strip liquid on `comp_ids` capture (§6).
6. Gate: full existing verify suite runs; the two known flipped assertions
   (§8 end) are retargeted in THIS stream (they guard Stream A's own change).

**Exports to B/C/D (the shared contract):** the §2 bit layout + accessor
names; `TerrainConfig.WATER_SURFACE_HEIGHT`; `emitted_shore_pairs()` slot
encoding (`mat * 256 + modifier`); the §3 generated-liquid rule.

### Stream B — Module render path (THE playable-web path — priority) *(owns: `godot/src/world/voxel_module/module_world.gd`, NEW `godot/src/world/water_mesh.gd`)*

1. `WaterMesh.surface_slab()` / `shore_fill()` (§4.1).
2. `_build_gen_manifest`: wet models + water slab, `_gen_wet_arid`,
   `_water_surface_arid`, anti-drift asserts, single batched bake, publication
   to the generator (§4.2/§4.3); wet-mesh cache keying.
3. Worker generator source: the §4.5 resolve (fast paths untouched).
4. `set_cell` + `gen_arid_for` wet resolve (§4.6).
5. Gate: native run over a coast — visually confirm the 0.9 surface, the
   composite shoreline (no notch), smoothed floor; setup timing print shows
   the wet-bake count (sanity: tens, not hundreds).

### Stream C — Fallback water render *(OPTIONAL, lower priority — must not gate A/B/D or the deploy; owns: `godot/src/world/fallback/chunk_mesher.gd`)*

1. `_emit_water` pass per §5.2 (water quads, ice cubes, shore quads), wired
   into `build()`; header comment updated with the §5.3 parity statement.
2. Gate: run with the module disabled (fallback forced) over a coast; sea
   surface + frozen sea render; no regression on land chunks.
3. Note: the fallback's shaped-floor rendering and the GroundCollider need NO
   changes regardless of this stream (§5.1, §6 collider row) — that audit
   belongs to Stream D's asserts, not here.

### Stream D — Verification *(owns: `godot/src/tools/verify_feature.gd`)*

1. `_test_water_shore()` implementing §8 items 1–5b, 6 + the collider
   extension (8); register it in the runner.
2. Extend `_test_both_paths` with §8 item 7 (module-guarded) and
   `_test_zonechunk` with the 5b round-trip.
3. Gate: `docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path
   godot --script res://src/tools/verify_feature.gd` exits 0.

### Integration (after A/B/D merge; C whenever it lands)

1. Cross-stream steelman (`/steelman`) with §4.4's culling table and §6's
   audit as the attack surface.
2. `scripts/export-web.sh` + `scripts/deploy.sh`; the DESIGN §7 gate: the live
   site loads, coastline playable in a desktop browser (walk into the sea,
   break a shore ramp, chop-and-float debris on water still works).

---

## 10. Decision log (locked by this doc)

1. **Liquid axis in bits 48..53** (kind 2b + level-in-tenths 4b); value 0 =
   none; bit 63 and 54..62 stay 0. The non-solid-modifier strip is untouched;
   no physics/structural consumer reads the axis.
2. **The bare water id remains THE canonical full-water cell**; level 9 marks
   the 0.9 surface (open water and shore composites alike — one continuous
   plane at SEA_LEVEL + 0.9); level 10 marks submerged composites.
3. **Frozen regime suppresses the liquid overlay at y == SEA_LEVEL** (ice cube
   / bare frozen-shore ramp); water below ice is normal.
4. **Underwater smoothing is surface-cell only in v1** — no underwater caps
   (§3.6 records the seam for revisiting).
5. **Submerged (level-10) composites render terrain-only geometry** on both
   paths; the faint water-bottom tint band over smoothed floors is an accepted
   cosmetic cost with a named refinement path (§4.4).
6. **Wet appearance = a sampled shore manifest** (`emitted_shore_pairs`, slot
   `mat*256+modifier`) + one water-slab model, frozen before the worker runs;
   unbaked combos degrade dry-shape → cube, never a hole.
7. **The liquid field is preserved by the codec, NOT round-tripped through
   persistence in v1** (superseded by the ORCHESTRATOR DEVIATION banner at the
   top of this doc): `pack()`/`canonical()` preserve bits 48..53 (they
   historically dropped bits ≥ 48 — pinned by verify) and VoxelBody capture
   strips liquid. ~~ZoneChunk gains a sparse liquid layer, and both load paths
   re-pack it.~~ **DEFERRED** — liquid is worldgen-only and never reaches
   serialization in v1, so the ZoneChunk layer is dead code; it is the
   documented future extension point when liquids become editable. Player
   actions never produce liquid values.
8. **Water geometry is a dedicated builder, never a shape family**: ShapeCodec/
   ShapeMesh are half-block-granular by design and stay untouched; the 0.9 top
   lives only in `WaterMesh` (one slab + one modifier-independent shore fill).
9. **The module path is the water-rendering priority; fallback water is
   optional** — the fallback has never drawn water (behavioural parity is
   explicitly relaxed for water there), and its stream must not gate the
   feature or the playable-web deploy.
10. **The STATE axis (bits 32..47) is in live use and is not overloaded** —
   the liquid field occupies only the audited-free reserved band 48..53.
