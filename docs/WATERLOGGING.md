# WATERLOGGING — native solid+fluid co-fill in godot_voxel's blocky mesher

**Status: DESIGN (no code written). Verdict: FEASIBLE in a bounded, local patch.**

Goal: one voxel (one TYPE-channel id) renders an opaque partial solid (a terrain
ramp) **and** a fluid (water), with the fluid seamlessly culling against
neighbouring water and other waterlogged cells — no border, no holes in the
terrain. This is the capability whose absence forces today's "wet composite"
models (`module_world.gd` `_make_wet_model`) and causes the visible water border
at shore/ramp cells, and which broke the earlier native-fluid experiment
(fluids cannot co-fill: water stopped filling slopes and drew edges).

All paths below are relative to `docker/engine/cache/godot/modules/voxel/`
(godot_voxel **v1.4.1**, the pinned `VOXEL_REF` in `docker/engine/versions.env`)
unless prefixed with `godot/` (game) or `scripts/`/`docker/` (toolchain).

---

## 1. Verified source facts (what the stock engine actually does)

These confirm — and in two places sharpen — the prior investigation.

### 1.1 One model id per voxel; fluid XOR regular

- The mesher reads **only** `VoxelBuffer::CHANNEL_TYPE`
  (`meshers/blocky/voxel_mesher_blocky.cpp:551`, and
  `get_used_channels_mask()` returns `1 << CHANNEL_TYPE` at
  `voxel_mesher_blocky.cpp:802-804`). 8- or 16-bit depth (638-666); the game
  uses 16-bit (`module_world.gd:226`), max 65536 models
  (`blocky_baked_library.h:22`).
- Per voxel, the id indexes `BakedLibrary::models`
  (`voxel_mesher_blocky.cpp:136-143`). The baked model carries
  `fluid_index` (255 = `NULL_FLUID_INDEX`) and `fluid_level`
  (`blocky_baked_library.h:127-128`).
- **The XOR**: at `voxel_mesher_blocky.cpp:181-197`, if
  `voxel.fluid_index != NULL_FLUID_INDEX` the mesher calls
  `generate_fluid_model(...)` which **replaces** `model_surfaces` and
  `model_sides_surfaces` with procedurally generated fluid geometry and forces
  `model_surface_count = 1` (197). The regular surfaces of that model are never
  emitted. There is no "both" path — this is the exact wall we hit.

### 1.2 Face culling is per-model side patterns; no override API

- Visibility: `voxel_mesher_blocky.h:119-152`.
  `is_face_visible_regardless_of_shape` (119-122): neighbour B never culls A if
  B is empty, strictly more transparent (`transparency_index >`), or
  `!culls_neighbors`. Otherwise `is_face_visible_according_to_shape` (125-135):
  A's face is culled iff A's side pattern equals B's opposite pattern, or B's
  pattern fully occludes A's per the baked matrix
  (`BakedLibrary::get_side_pattern_occlusion`, `blocky_baked_library.h:189-195`).
- Patterns are 32×32 rasterizations of the model's actual side geometry
  (`voxel_blocky_library_base.cpp:679-767`, raster at 606-661). Side pattern ==
  geometry; nothing lets a model *claim* a different occlusion footprint.

### 1.3 Native fluids: full occlusion bitmaps + procedural geometry

- In `generate_side_culling_matrix`, a model with `fluid_index != NULL` skips
  rasterization and gets a **full bitmap on all six sides**
  (`voxel_blocky_library_base.cpp:711-721`, `bitmap.set()` at 717), plus
  `contributes_to_ao = false` (720). That is why adjacent same-fluid voxels
  auto-cull laterally — full pattern vs full pattern — giving the borderless
  surface.
- `generate_fluid_model` (`blocky_fluids_meshing_impl.h:166-398`):
  - Top covered iff the voxel above has the **same `fluid_index`** (178-193);
    covered + `visible_sides_mask == 0` is the ocean-interior fast path (186-190).
  - Lateral/bottom sides are copies of full cube sides
    (`voxel_blocky_fluid.cpp:49-54`) with UV.x = axis, UV.y = flow state
    (216-237).
  - When not covered, it builds the top surface (245-252, collision disabled)
    and samples the 3×3 neighbourhood: a neighbour counts as fluid iff
    `nm.fluid_index == voxel.fluid_index`, contributing `nm.fluid_level`
    (272-273) and "covered" state (277-285); corner heights lerp
    `BOTTOM_HEIGHT..TOP_HEIGHT` = **0.0625..0.9375**
    (`blocky_baked_library.h:141-142`) by `level / max_level` (120-144), with
    covered corners forced to 1.0 (333-344).
  - **Sharpened fact (a real hazard for us):** when the top is covered, the
    function returns the *model's own* surfaces span purely to provide a
    material id — `out_model_surfaces = to_span(voxel.model.surfaces)` with the
    comment "Expected to be empty, but also provides material ID. Not great tho"
    (388-391). For a pure fluid model those baked surfaces are geometry-empty
    (only `material_id` is set, `voxel_blocky_model_fluid.cpp:148-149`). For a
    waterlogged model they would be the **solid's real geometry** → the solid
    would be emitted twice. §3.4 fixes this.
- `VoxelBlockyModelFluid::bake` → `bake_fluid_model`
  (`voxel_blocky_model_fluid.cpp:95-150`): registers the `VoxelBlockyFluid` in
  `indexed_fluids` (find-or-append, 111-121), sets `fluid_index`/`fluid_level`
  (123, 135), raises `BakedFluid::max_level` (136), marks the top side empty
  (`empty_sides_mask = 1 << SIDE_POSITIVE_Y`, 146) so the generic visibility
  loop never emits a top side, and sets `surface_count = 1` with the fluid
  material (148-149). Note: **`surface_count == 1` for pure fluids too**, so it
  cannot distinguish "pure fluid" from "waterlogged" — we need an explicit flag.
- Library bake: `voxel_blocky_library.cpp:55-101` — every model's `bake(ctx)`
  runs with a shared `ModelBakingContext` (`blocky_model_baking_context.h:12-19`)
  carrying `indexed_fluids` + `baked_fluids`; then fluids bake (85-89); then
  `generate_side_culling_matrix` (93). Everything is main-thread; the mesher
  reads baked data under an RWLock (`voxel_mesher_blocky.cpp:627-628`).
- **Latent stock bug that becomes live for us:** `BakedModel::clear()`
  (`blocky_baked_library.h:134-137`) resets only `model` and `empty` — *not*
  `fluid_index`/`fluid_level`. Baked models are reused across re-bakes
  (`_baked_data.models.resize(...)`, `voxel_blocky_library.cpp:69`), and the
  game re-bakes the library repeatedly (lazy ARID appends,
  `module_world.gd:287`). If a model slot ever changes class, stale fluid state
  survives. The patch resets these fields in `clear()`.

### 1.4 Subclass bake() funnels through the base — one clean hook point

`VoxelBlockyModelMesh::bake` ends with `VoxelBlockyModel::bake(ctx)`
(`voxel_blocky_model_mesh.cpp:497-505`), as do Cube
(`voxel_blocky_model_cube.cpp:275-281`) and Empty
(`voxel_blocky_model_empty.cpp:10-12`). The base bake sets the common fields
(`voxel_blocky_model.cpp:220-234`). Adding waterlog properties to the **base
class** therefore covers Mesh and Cube models with a single hook and zero new
classes to register.

---

## 2. Encoding decision — waterlogged model *variants* on the TYPE channel

**Chosen: (a/c) — a regular model additionally carrying `fluid_index` +
`fluid_level` in its `BakedModel`, registered as its own model id ("waterlogged
twin" of a dry shape).** One voxel id fully encodes "solid shape X + fluid F at
level L".

Why not the alternatives:

- **(b) A second voxel data channel** for fluid level: `VoxelMesherBlocky`
  reads exactly one channel (§1.1). A second channel means threading a second
  `Span` through `generate_mesh`, extending `get_used_channels_mask`, teaching
  the generator/worker and `bulk_inject`/`_seeded_block_buffer`
  (`module_world.gd:220-231`, channel-mask copy at 230) and the streaming
  format to carry it. It is the "right" encoding at Minecraft scale, but it is
  a cross-cutting change through mesher, storage, generator and game — 5-10×
  the patch we need.
- **A wrapper class `VoxelBlockyModelWaterlogged`** holding an inner model:
  more API surface, a new registered class, awkward `_gen_arid`-style caching
  game-side, and it still bakes down to the same `BakedModel` fields. The base
  class hook (§1.4) is strictly smaller.

Cost of (a): extra model ids. The game already pays exactly this cost for wet
composites — `_gen_wet_arid` allocates one model per emitted (material,
modifier) shore pair (`module_world.gd:394-429`), a sampled coastal set of
**tens**. Waterlogged twins replace those 1:1 (§5), so the manifest does **not
grow**; with 16-bit TYPE (65536 ids) headroom is a non-issue. General bound:
`|waterloggable shapes| × |distinct waterlog levels|`; today levels = {max}.

---

## 3. The engine patch

Seven files, all inside `meshers/blocky/`. No new registered classes; no
changes outside the module.

### 3.1 `blocky_baked_library.h` — new baked fields (~8 LOC)

```cpp
struct BakedModel {
    ...
    uint8_t fluid_index = NULL_FLUID_INDEX;      // exists (line 127)
    uint8_t fluid_level;                          // exists (line 128)
    // NEW: model has BOTH regular surfaces and a fluid (waterlogging).
    bool waterlogged = false;
    // NEW: transparency used for the FLUID faces' visibility test (the model's
    // own transparency_index describes the solid part, which is opaque).
    uint8_t fluid_transparency_index = 0;

    inline void clear() {
        model.clear();
        empty = true;
        // NEW: stock leaves these stale across re-bakes (see §1.3).
        fluid_index = NULL_FLUID_INDEX;
        fluid_level = 0;
        waterlogged = false;
        fluid_transparency_index = 0;
    }
};

struct BakedLibrary {
    ...
    // NEW: index of the all-set 32x32 side pattern (the "full face" pattern),
    // used as the fluid's side pattern in the waterlogged fluid pass.
    // 0xFFFFFFFF (NULL) if no model produced it and none needed it.
    uint32_t full_side_pattern_index = 0xFFFFFFFF;
};
```

Semantics: `fluid_index != NULL && !waterlogged` ⇒ pure fluid (stock
behaviour, bit-identical). `fluid_index != NULL && waterlogged` ⇒ both passes.

### 3.2 `voxel_blocky_library_base.cpp` — culling matrix (~15 LOC)

In `generate_side_culling_matrix`:

1. Line 711: the full-bitmap branch becomes
   `if (model_data.fluid_index != NULL_FLUID_INDEX && !model_data.waterlogged)`.
   A **waterlogged model's side patterns are its solid geometry** (the `else`
   rasterize branch, 722) — its ramp culls and is culled exactly as the dry
   shape would be. This is what keeps terrain hole-free: neighbours judge the
   cell by its opaque solid, never by its water.
2. The function already tracks `full_side_pattern_index` as a local (700,
   756-758). Persist it: `baked_data.full_side_pattern_index = full_side_pattern_index`
   after the gather loop. If it is still NULL and any model is waterlogged,
   append one full pattern (patterns are deduplicated; in practice any full
   cube or pure fluid model already created it — VOXIVERSE always has both).
3. `contributes_to_ao` for waterlogged models: no code needed — non-full-pattern
   models are already forced to `false` (759-762), matching today's wet
   composites.

### 3.3 `voxel_mesher_blocky.cpp` — the core change (~90-120 net LOC)

Two edits inside `generate_mesh`.

**(i) Same-fluid short-circuit for pure fluids** — in the existing visibility
loop (148-169), immediately after fetching the neighbour model:

```cpp
// NEW: a fluid voxel's faces are never drawn against a neighbour carrying the
// same fluid — including waterlogged neighbours, whose side patterns describe
// their solid, not their water. Solid faces of waterlogged voxels must NOT be
// affected, hence the !voxel.waterlogged guard (their fluid runs in pass 1).
if (voxel.fluid_index != NULL_FLUID_INDEX && !voxel.waterlogged &&
        other_vt.fluid_index == voxel.fluid_index) {
    continue;
}
```

Without this, a pure water voxel W adjacent to a waterlogged cell L computes
visibility from L's *solid* (partial) pattern and draws its lateral face — the
exact border we are killing. Between two pure fluids the check is redundant
(full-vs-full patterns already cull), so stock scenes are unchanged.

**(ii) The waterlogged two-pass loop** — restructure 171-197 + the emission
block. The emission code (sides 199-408, inside 410-471) reads only four
locals: `visible_sides_mask`, `model_surface_count`, `model_surfaces`,
`model_sides_surfaces`. That makes a minimal-diff wrapper possible: run the
body up to twice, reassigning those locals per pass, keeping the long emission
block byte-identical (only its indentation/loop context changes):

```cpp
const bool waterlogged = voxel.waterlogged;
const int pass_count = waterlogged ? 2 : 1;
for (int pass = 0; pass < pass_count; ++pass) {
    uint8_t model_surface_count = model.surface_count;
    Span<const BakedModel::Surface> model_surfaces = to_span(model.surfaces);
    const FixedArray<...> *model_sides_surfaces = &model.sides_surfaces;
    uint32_t pass_sides_mask = visible_sides_mask;      // pass 0: solid mask

    if (pass == 1 || (voxel.fluid_index != NULL_FLUID_INDEX && !waterlogged)) {
        if (pass == 1) {
            // FLUID visibility mask: independent of the solid's patterns and
            // of the solid's empty_sides_mask. The fluid's own pattern is the
            // full face; its top is generated inside generate_fluid_model.
            pass_sides_mask = 0;
            for (unsigned int side = 0; side < Cube::SIDE_COUNT; ++side) {
                if (side == Cube::SIDE_POSITIVE_Y) continue;   // like baked fluid empty_sides_mask
                const uint32_t nid = type_buffer[voxel_index + side_neighbor_lut[side]];
                if (nid < library.models.size()) {
                    const BakedModel &other = library.models[nid];
                    if (other.fluid_index == voxel.fluid_index) continue;  // borderless rule
                    if (!(other.empty ||
                          other.transparency_index > voxel.fluid_transparency_index ||
                          !other.culls_neighbors)) {
                        const unsigned int ai = library.full_side_pattern_index;
                        const unsigned int bi =
                                other.model.side_pattern_indices[Cube::g_opposite_side[side]];
                        if (ai == bi || library.get_side_pattern_occlusion(bi, ai)) continue;
                    }
                }
                pass_sides_mask |= (1 << side);
            }
        }
        if (!generate_fluid_model(voxel, type_buffer, voxel_index, 1, row_size,
                    deck_size, pass_sides_mask, library,
                    model_surfaces, model_sides_surfaces)) {
            continue;   // ocean-interior fast path: skip fluid pass only
        }
        model_surface_count = 1;
    }

    ... existing sides + inside emission, with two pass-guards:
        - the cutout branch (211-235) additionally requires `pass == 0`
          (cutouts belong to the solid; fluids never cut);
        - everything else unchanged (AO, colors, collision flags — fluid
          surfaces already carry collision_enabled=false, see §1.3/§3.4).
}
```

Behavioural review of the mask logic (`ai` = full pattern):

| Waterlogged cell L's **fluid** face toward… | Result | Why |
|---|---|---|
| air / invalid id | drawn | `nid >= models.size()` or `other.empty` |
| same fluid (pure water W or waterlogged L′) | **culled** | `fluid_index` equality — the borderless rule |
| opaque full cube | culled | `bi == ai` (full == full) |
| dry partial solid (beach ramp above waterline) | drawn | partial `bi` cannot occlude full `ai` — correct: water needs a face there |
| more-transparent model (glass with higher index) | drawn | transparency test |

And the **solid** side of the story is untouched: L's ramp faces use the stock
loop with the stock solid patterns (visible through water because water's
`transparency_index > 0` — `is_face_visible_regardless_of_shape`); neighbours
cull against L via its solid patterns only (§3.2), so a cube under a
full-footprint ramp still culls its top face, and nothing ever sees "water" as
an occluder. No holes.

Fluid continuity across the L↔W boundary is then automatic: `generate_fluid_model`
already treats any neighbour with the same `fluid_index` as fluid for top-cover,
corner levels and covered-corner forcing (§1.3), and L carries `fluid_level`,
so the top surface height is continuous — same height, same material, same
mesh surface (same `material_id` ⇒ same `arrays_per_material` bucket), zero
seam.

### 3.4 `blocky_fluids_meshing_impl.h` — covered-top material fix (~8 LOC)

Replace the hack at 388-393:

```cpp
if (fluid_top_covered) {
    // Provide the fluid material through an empty surface. Using
    // voxel.model.surfaces here (stock) would re-emit the SOLID's geometry
    // for waterlogged models (their surfaces are not empty).
    BakedModel::Surface &empty_top = get_tls_fluid_top();
    empty_top.clear();
    empty_top.material_id = fluid.material_id;
    empty_top.collision_enabled = false;
    out_model_surfaces = to_single_element_span(empty_top);
} else {
    out_model_surfaces = to_single_element_span(fluid_top_surface);
}
```

For pure fluids this is value-identical to stock (their model surfaces were
geometry-empty with the same material id, and it also stops fluid lateral
faces from leaking into the collision surface via the default
`collision_enabled = true` — harmless for VOXIVERSE, which disables terrain
collision, `module_world.gd:141`, but correct generally).

### 3.5 `voxel_blocky_model.h/.cpp` — the authoring API (~75 LOC)

On the **base** `VoxelBlockyModel` (covers Mesh + Cube via §1.4):

```cpp
// Members
Ref<VoxelBlockyFluid> _waterlog_fluid;                 // null = not waterlogged
uint8_t _waterlog_level = 0;
uint8_t _waterlog_fluid_transparency_index = 1;

// Methods (+ _bind_methods entries + grouped properties "waterlog_*")
void set_waterlog_fluid(Ref<VoxelBlockyFluid> fluid);  // connects/disconnects `changed`, emit_changed
Ref<VoxelBlockyFluid> get_waterlog_fluid() const;
void set_waterlog_level(int level);                    // clamped to VoxelBlockyModelFluid::MAX_LEVELS-1
int get_waterlog_level() const;
void set_waterlog_fluid_transparency_index(int i);     // what the FLUID faces compare against neighbours
int get_waterlog_fluid_transparency_index() const;
```

Hook at the end of `VoxelBlockyModel::bake(ctx)` (`voxel_blocky_model.cpp:220`):

```cpp
if (_waterlog_fluid.is_valid() && !ctx.model.empty) {
    const unsigned int fluid_index =
            blocky::get_or_register_fluid(_waterlog_fluid, ctx.indexed_fluids, ctx.baked_fluids);
    if (fluid_index != NULL_FLUID_INDEX) {
        blocky::BakedModel &m = ctx.model;
        m.fluid_index = fluid_index;
        m.fluid_level = _waterlog_level;
        m.waterlogged = true;
        m.fluid_transparency_index = _waterlog_fluid_transparency_index;
        blocky::BakedFluid &bf = ctx.baked_fluids[fluid_index];
        bf.max_level = math::max(static_cast<uint8_t>(_waterlog_level), bf.max_level);
    }
}
```

`get_or_register_fluid` is the find-or-append block factored out of
`bake_fluid_model` (`voxel_blocky_model_fluid.cpp:111-128`) so pure-fluid and
waterlog baking share one registration path (~20 LOC moved, one caller
rewritten).

GDScript surface the game calls (all string-driven, so `module_world.gd` still
parses without the module): `set_waterlog_fluid(fluid)`, `set_waterlog_level(n)`,
`set_waterlog_fluid_transparency_index(n)` on any `VoxelBlockyModelMesh`/`Cube`,
plus the pre-existing `VoxelBlockyFluid` (`set_material`,
`set_dip_when_flowing_down`) and `VoxelBlockyModelFluid` (`set_fluid`,
`set_level`) for pure water cells.

### 3.6 Docs XML (optional polish, ~30 LOC)

Add the three properties to `doc/classes/VoxelBlockyModel.xml`. Missing doc
entries do not fail the build; include for hygiene.

### 3.7 What is deliberately NOT touched

- `is_face_visible` in the header (used by cutout baking,
  `voxel_blocky_library_base.cpp:508`, and preview paths) — waterlogged models
  present their solid there, which is right.
- LOD skirts (`blocky_lod_skirts.h`) — only run at `lod_index > 0`
  (`voxel_mesher_blocky.cpp:647-665`); the game uses `VoxelTerrain` at LOD 0.
- Shadow occluders — off by default (`shadow_occluders_mask == 0`), and
  waterlogged `full_sides_mask` comes from the solid raster anyway.
- Storage, streaming, generator API, `_get_used_channels_mask` — unchanged.
- `register_types` — no new classes.

**Patch size estimate: ~220-280 added/changed LOC** across
`blocky_baked_library.h`, `voxel_blocky_library_base.cpp`,
`voxel_mesher_blocky.cpp`, `blocky_fluids_meshing_impl.h`,
`voxel_blocky_model.h/.cpp`, `voxel_blocky_model_fluid.cpp`
(+ ~30 LOC XML, + ~15 LOC build scripting from §6.1). The emission block in
`generate_mesh` is *moved into a loop*, not rewritten — the review diff should
be read with `--ignore-all-space` for that hunk.

---

## 4. Game-side integration (`godot/src/world/voxel_module/module_world.gd`)

All feature-detected (`ClassDB.class_exists("VoxelBlockyModelFluid")` +
`model.has_method("set_waterlog_fluid")`), so an old engine binary silently
keeps today's composite renderer — the safe-rollout property we rely on in §6.

1. **One `VoxelBlockyFluid`** created in `setup()`: water material from
   `BlockMaterials.get_for(water_id)`, `dip_when_flowing_down = false`.
2. **Water LRID becomes a pure fluid model.** `_configure_library`
   (`module_world.gd:611-644`) currently adds a cube for every catalog id with
   the index==LRID invariant. For the water id, add a `VoxelBlockyModelFluid`
   (fluid, `level = 1`) instead of a cube — same index discipline. With a
   single registered level, `BakedFluid::max_level == 1`, so every water cell
   renders its surface at `TOP_HEIGHT = 0.9375` and `dip_when_flowing_down`
   logic is inert (level == max). Deep/submerged water columns now cull to
   nothing inside the body (the ocean fast path, §1.3) — strictly fewer
   triangles than today's cube water.
3. **Wet composites → waterlogged twins.** `_make_wet_model`
   (`module_world.gd:498-524`) becomes: `VoxelBlockyModelMesh` with the **dry**
   `ShapeMesh.build(modifier)` (reuse `_shape_mesh_cache[modifier]` directly —
   the `_WET_MESH_FLAG` mesh variants and `WaterMesh.shore_fill()` are no
   longer needed), terrain material, `set_transparency_index(0)` (unchanged,
   still load-bearing for the solid), plus `set_waterlog_fluid(fluid)`,
   `set_waterlog_level(1)`,
   `set_waterlog_fluid_transparency_index(BlockCatalog.cull_group_of(water))`.
4. **The 0.9 slab dies.** `_make_slab_model` / `_water_surface_arid`
   (`module_world.gd:526-551`): open-water surface cells (liquid 9, modifier 0)
   simply resolve to the water LRID's fluid model — set
   `_water_surface_arid = _cube_arid[water_id]` and delete the slab builder.
   `WaterMesh` becomes dead code on the module path (keep for the GDScript
   fallback path, which is untouched).
5. **Worker: zero structural change.** The runtime generator
   (`module_world.gd:776-787`) and `arid_for_cell` (241-252) already route
   liquid-9 cells through `_water_surface_arid` / `_gen_wet_arid`; only the
   tables' *contents* change (now pointing at fluid/waterlogged ids). The
   frozen-manifest discipline (bake on main thread before the worker attaches)
   is preserved. Optional follow-up: map **submerged** composites
   (liquid 10, modifier ≠ 0) to the same waterlogged ids too, which removes the
   last underwater seam (today a water cube next to a submerged dry ramp draws
   a wall; same-fluid culling would erase it) — a two-line condition change in
   `arid_for_cell`/`gen_arid_for`/the worker.
6. **Model-count bound:** unchanged from today —
   `|emitted_shore_pairs|` waterlogged twins (tens; they *replace* the wet
   composites 1:1) + 1 pure fluid model (replacing slab + water cube). The
   liquid axis (CellCodec bits 48..53, tenths, `cell_codec.gd:40-51`) maps
   {9, 10} → fluid level 1 (= max); if per-level water ever ships, register
   `VoxelBlockyModelFluid`s at levels 1..10 (`max_level` auto-raises,
   `voxel_blocky_model_fluid.cpp:136`) and waterlogged twins per used level —
   bound `|shapes| × |levels| + |levels|`, still trivially inside 65536.
7. **Height constant:** native fluid tops sit at 0.9375, not 0.9.
   `TerrainConfig.WATER_SURFACE_HEIGHT := 0.9` (`terrain_config.gd:52`) feeds
   sim/gameplay (thermometer band, swim-line checks). Either bump the constant
   to 0.9375 or accept a 0.0375 visual-vs-logic offset; recommend bumping and
   letting verify re-assert the water-line invariants.
8. **verify_feature.gd additions** (the checkpoint of §6): assert
   `ClassDB.class_exists("VoxelBlockyModelFluid")` and
   `VoxelBlockyModelMesh` instance `has_method("set_waterlog_fluid")`; build a
   3×3×3 `VoxelBuffer` (waterlogged ramp beside pure water beside air) through
   `VoxelMesherBlocky.build_mesh`, and assert (a) both terrain and water
   materials appear, (b) the face count matches the hand-derived expectation —
   in particular **no** fluid quad on the shared waterlogged↔water wall and
   **no** missing ramp faces.

---

## 5. Correctness & risk analysis

| # | Risk / interaction | Analysis & mitigation |
|---|---|---|
| 1 | **Border re-appears** (a fluid face survives between same-fluid cells) | Two independent rules must both hold: pass-1 mask culls on `fluid_index` equality (§3.3-ii) and pure-fluid loop gets the same short-circuit (§3.3-i). Both directions of every boundary pair (W↔L, L↔L′, W↔W) enumerated in §3.3's table; verify asserts exact face counts. |
| 2 | **Holes in terrain** (solid culled by water) | Solid culling never consults fluid state: waterlogged side patterns are the solid raster (§3.2), the short-circuit excludes `waterlogged` (§3.3-i), and neighbours see `transparency_index = 0`. Equivalent to today's opaque wet composite (`module_world.gd:518-523`). |
| 3 | **Solid double-emission when top covered** | The §3.4 fix; without it every submerged waterlogged cell emits its ramp twice (z-fighting). Verify's face-count assertion catches it. |
| 4 | **Stale fluid fields across re-bake** | `BakedModel::clear()` reset (§3.1). Live for us because the game re-bakes on every lazy ARID append (`module_world.gd:287`). |
| 5 | **`full_side_pattern_index` missing** | Guard in §3.2 appends the pattern when needed. In practice always present (full cubes exist). |
| 6 | **Transparency sorting** of added fluid surfaces | Waterlogged fluid geometry lands in the *same* material bucket (`arrays_per_material[fluid.material_id]`) as neighbouring pure water — one alpha surface per chunk, exactly like stock fluids and today's water material. No new sorting class of artifact; intra-surface triangle order remains scan-order-deterministic. |
| 7 | **Fluid height 0.9375 vs game 0.9** | Engine constants (`blocky_baked_library.h:141-142`) are internal; game adapts one constant (§4.7). Not worth making TOP_HEIGHT configurable in this patch. |
| 8 | **Frozen sea / ice** | Ice is a solid LRID; nothing changes. A water cell under ice is "not covered" (ice has no fluid_index) → its 0.9375 top surface draws under the ice cube, visible only through translucent ice — same as today's slab-under-ice. If it reads as a gap, game-side option: map under-ice water to a full-level cell whose top is then culled by… nothing — accept, or extend `fluid_top_covered` to full-bottom-pattern solids later (out of scope, flagged). |
| 9 | **AO** | Waterlogged cells: `contributes_to_ao = false` (non-full patterns, §3.2) — identical to today's composites. Fluid surfaces *receive* AO exactly as stock fluids do (same emission block). |
| 10 | **Cutout sides** (`cutout_side_surfaces`, hot-path hashmap 211-235) | Pass-guarded to the solid pass; the game never enables cutout. |
| 11 | **Determinism** | Mesh output is a pure function of (type buffer, baked library); the pass loop adds no ordering dependence; TLS scratch (`get_tls_fluid_*`) is consumed before the next voxel, same as stock. Bake stays main-thread (`voxel_blocky_library.cpp:58` write-lock). |
| 12 | **Web/Emscripten threading** | No new threads, no new statics beyond existing TLS pattern, no atomics: the mesher already runs on the (web: single) voxel worker reading immutable baked data. The 1-thread web cap (`module_world.gd:18-22`) is unaffected. |
| 13 | **Performance** | Pure fluids: +1 branch per side. Waterlogged cells: one extra 6-side mask loop + one `generate_fluid_model` — only on shore cells (sparse). Ocean interiors get *cheaper* (§4.2). |
| 14 | **GDScript fallback path** | Untouched — it has its own mesher and keeps the composite look. Behaviour divergence between paths (border on fallback, none on module) is accepted and documented; the fallback is already visually degraded by design. |

---

## 6. Build & rollout

### 6.1 Where the patch lives — NOT in the cache

`docker/engine/cache/` is a git-ignored clone, and `clone_pinned` runs
`git checkout -f "${ref}"` on **every** build (`docker/engine/build-engine.sh:53`),
discarding local edits. The patch must be committed in-repo and applied at
build time:

- New: `docker/engine/patches/godot_voxel/0001-native-waterlogging.patch`
  (git-format patch against `v1.4.1`).
- `build-engine.sh`: after the `clone_pinned` of `VOXEL_DIR` (line 59), apply
  `git -C "${VOXEL_DIR}" apply /patches/godot_voxel/*.patch` (the preceding
  `checkout -f` makes this idempotent per run); record the patch list + sha256
  in `BUILD-INFO.txt`.
- `scripts/build.sh`: add `-v "${ENGINE_DIR}/patches:/patches:ro"` to the
  `docker run` (mounts at lines 50-63).

~15 LOC of build scripting, and the patch is provenance-tracked like the
version pins.

### 6.2 Rebuild scope

**Both** the native editor and the Web templates must be rebuilt —
`scripts/build.sh` with no flags. A module-source change invalidates only the
module's objects (the `.o` files sitting in the cache dir confirm incremental
state), so expect **minutes warm**, ~24 min only from a cold cache. If the
**web** template is not rebuilt (or the patched module fails the web compile
and `build-engine.sh:126-133` auto-falls back to stock, `module_in_web=no`),
the deployed game feature-detects the missing API and keeps the composite
renderer — degraded visuals, not a crash. Still: treat `module_in_web=yes` as
a release gate.

### 6.3 Phases

1. **Engine patch** — author §3 on a `feat/`-branch as
   `docker/engine/patches/godot_voxel/0001-*.patch` + the §6.1 build wiring.
   No game changes yet.
2. **Rebuild** — `scripts/build.sh`.
3. **CHECKPOINT — new API exists in BOTH binaries** (do not proceed otherwise):
   - Editor: headless one-liner asserting
     `ClassDB.instantiate("VoxelBlockyModelMesh").has_method("set_waterlog_fluid")`.
   - Web: `BUILD-INFO.txt` shows `module_in_web=yes` **and** the patch sha; then
     `unzip -p docker/engine/templates/web_release.zip | strings | grep -c set_waterlog_fluid`
     ≥ 1 (ClassDB method names are retained in the wasm).
4. **Game wiring** — §4 changes to `module_world.gd` (+`terrain_config.gd`
   constant), feature-detected.
5. **Verify** — extend `godot/src/tools/verify_feature.gd` per §4.8; run the
   headless verify against the new editor binary; exit 0 required.
6. **Export + deploy** — `scripts/export-web.sh`, local smoke
   (`crossOriginIsolated` + shoreline visual check), `scripts/deploy.sh`,
   confirm live HTTP 200 + headers, then eyeball a shoreline in the browser.

Each phase is independently revertible; before phase 4 lands, the new engine
binaries run the unmodified game identically (stock paths are bit-compatible,
§3.1/§3.4).

---

## 7. Fallback / escape hatches

- **If the two-pass restructure fights back** (unexpected coupling in the
  emission block): *minimal viable waterlogging* — keep the XOR dispatch, but
  give waterlogged models pass 1 **only**, and bake their solid ramp with a
  ~1e-3 **inset** so all its geometry lands in the "inside" surfaces (inner
  geometry bypasses side culling entirely, `voxel_blocky_model_mesh.cpp`
  classifies by `_side_vertex_tolerance`). Engine change shrinks to ~40 LOC
  (mask loop + additive fluid dispatch); cost: shore ramps never cull their
  side trapezoids (a few always-drawn hidden triangles per shore cell — the
  ocean floor is the worst case, still bounded by shore-pair density) and
  slightly weaker AO. Game-side: an inset variant of `ShapeMesh.build`.
- **If the fluid mask misbehaves in a corner case**: ship with the mask
  simplified to `air-or-different-fluid ⇒ draw` (drop the pattern/transparency
  refinements). Overdraws a water face against opaque cubes (hidden anyway
  behind opaque geometry — visual no-op, minor fill cost), cannot create
  borders or holes.
- **If the engine patch slips entirely**: the investigation confirms no
  stock-API workaround exists (side patterns are geometry-derived with no
  override, §1.2; fluids are XOR, §1.1), so the alternative is accepting
  today's bordered composite — this document then stands as the recorded
  reason.
