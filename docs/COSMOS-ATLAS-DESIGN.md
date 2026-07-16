# COSMOS-ATLAS-DESIGN — Texture atlas + single opaque material (Perf L3)

> **Status:** DESIGN ONLY. Not implemented. This is the "Step 2" draw-call cut from
> `docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md` §4 (option **L3**, ~1–2 weeks). It needs
> no engine rebuild.
>
> **One-line goal:** every terrain block id gets its own `StandardMaterial3D` today, and
> `VoxelMesherBlocky` emits **one surface (= one draw call) per distinct material per mesh
> block**, so materials MULTIPLY the draw count. Pack every block-face texture into ONE
> atlas behind ONE opaque material, move per-face texture selection into per-model UVs, and
> the terrain collapses from `mesh_blocks × ~2.1 materials` to `mesh_blocks × 1`. Draws
> **~204 → ~110**, which puts the true frame cost across the 16.7 ms boundary on
> GL-compatibility: mid clients reach the 45–60 fps rung, weak clients get a clean 30.
>
> **Flag:** `CubeSphere.FP_ATLAS_MATERIAL` (does not exist yet), default **OFF**. OFF ⇒ the
> shipped per-model-material path, byte-identical (`verify_feature` FLAT stays 6035/0). ON ⇒
> the atlas path. A/B-able live through the remote bridge.

---

## 1. How the blocky library + materials work TODAY

### 1.1 The material owner: `block_materials.gd`

`BlockMaterials.get_for(block_id) -> Material` is the ONE place a block id becomes a
render material, cached per id in `_cache` (`block_materials.gd:24-43`). In the FLAT /
`M5_REAL` world (the near render on the faceted planet is `M5_REAL`, so it returns the
plain `StandardMaterial3D` — `block_materials.gd:38`), it builds via `_standard`
(`:46-61`):

- **textured** (`_textured`, `:163-172`) — `SHADING_MODE_UNSHADED`, `albedo_texture =
  BlockTextures.texture_for(id)`, `TEXTURE_FILTER_NEAREST_WITH_MIPMAPS`,
  `texture_repeat = true`, `CULL_DISABLED` (double-sided), `vertex_color_use_as_albedo`.
- **flat swatch** (`_solid`, `:176-182`) — no tile → unshaded solid `albedo_color =
  BlockCatalog.color_of(id)`.
- **translucent** (`_translucent`, `:190-200`) — glass/water/ice (`cull_group > 0`):
  `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`, tint carries alpha, optional tile.
- **emissive** — lava: `emission_enabled` + a scalar `emission_energy_multiplier`
  (`_standard` `:57-60`).

There is also a **snow-capped variant** material per base id (`snow_capped_for`,
`:107-121`, cached in `_snow_cache`) — the `snow_block` tile tinted toward the base hue —
for the 4 cappable materials.

**So today's live material count for the terrain near field is one StandardMaterial3D per
distinct block id present, plus one snow-variant per cappable base id.** Every one is a
distinct `Material` instance ⇒ every one is a distinct mesher surface.

### 1.2 The texture set: `block_textures.gd` + `assets/textures/pack/`

`BlockTextures.TILES` (`block_textures.gd:22-45`) maps 38 material names to tile stems;
**~30 distinct PNG tiles** exist on disk (many names share a stem: `coarse_dirt→dirt`,
`powder_snow→snow_block`, `dark_oak_leaves→leaf`, all 6 glass variants → `glass`,
`tinted_glass→glass`). Tiles are the enhanced CC0 pack (`TexturePackBaker`, 16 px source →
128 px output, `FACTOR = 8`). A material with no `TILES` row falls back to its flat
`BlockCatalog` swatch.

### 1.3 The catalog: `block_catalog.gd`

77 bootstrap ids (0..76), dense (`assets/blocks.json`). AIR = 0. Of the 76 solids:

| Family | Count | Blocks |
|---|---:|---|
| Opaque solids | **67** | grass, dirt, stone, wood, leaf, the stone family, soils, sands, snow, logs/leaves, … |
| Translucent (`cull_group > 0`) | **8** | water, ice, glass, tinted_glass, {white,red,blue,green}_stained_glass |
| Emissive | **1** | lava |

The **cube ARID == block id** invariant (VOXEL-DATA-STRUCTURE §8.1) is load-bearing: the
generator and edit path write these ids into the voxel TYPE channel, and the library model
index must equal the id. The atlas MUST preserve this (§4.1).

### 1.4 The library build: `module_world.gd`

`_configure_library` (`module_world.gd:2401-2444`):

1. index 0 = `VoxelBlockyModelEmpty` (air).
2. For every block id 1..76: a `VoxelBlockyModelCube` via `_add_cube` (`:2451-2475`), OR a
   `VoxelBlockyModelFluid` for a native-waterlog liquid LRID. Each `_add_cube`:
   - `set_atlas_size_in_tiles(Vector2i(1, 1))` — a **1×1 atlas** (the whole per-model
     texture is one tile).
   - `set_tile(side, Vector2i(0, 0))` for all 6 faces → UVs 0..1 over that model's texture.
   - **`set_material_override(0, BlockMaterials.get_for(id))`** — the per-id material. **This
     is the line that gives every block id its own material and therefore its own surface.**
   - `set_transparency_index(cull_group)` when translucent.
3. `bake()` — regenerates model geometry + UVs from the tile/atlas config.

Then `_build_gen_manifest` (`:737-…`) pre-bakes the **shaped** model families (smoothed
terrain), each also carrying a per-material `set_material_override`:

| Family | Builder | Material source | Rough model count |
|---|---|---|---:|
| Generated corner-height shapes | `_make_shape_model` (`:2092-2110`) | `get_for(mat)` per surface material | `appearance_surface_materials()` (8: grass, sand, red_sand, mud, snow, podzol, gravel, stone) × `emitted_modifiers()` (~61) |
| Snow-cap variants | `_build_snow_manifest` | `snow_capped_for(base)` | 4 cappable × (cube + emitted modifiers) |
| Snow LAYER | `_build_layer_manifest` | snow material | ~8 levels |
| Snow-FILL composites | `_build_comp_manifest` | 2-surface (terrain ramp + snow slab) | 4 levels × mats |
| Sharp slopes | `_build_slope_manifest` | dry + snow twin | per emitted (mat, payload) |
| Carve sentinels | `_build_carve_manifest` | per-material cube | ~mats |
| Water: waterlog twins / wet composites / slab | `_make_waterlogged_model` / `_make_wet_model` / `_make_slab_model` | terrain + water materials | per emitted pair |

Total baked models ≈ **280–420** (below the manifest budget). Crucially, the **ArrayMesh
geometry** for a shape is shared per-modifier across materials (`_shape_mesh_cache`,
`:246`) — the geometry does not multiply by palette — but the **material** does, via the
per-model `set_material_override`. So a smoothed grass ramp and a smoothed stone ramp share
one ArrayMesh but are two distinct materials ⇒ two surfaces if both appear in one mesh block.

### 1.5 The mesher rule and today's draw composition

`VoxelMesherBlocky` merges every voxel in a 32³ mesh block whose model carries the **same
material** into **one surface**, and emits **one draw call per surface**
(`docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md` §2.3). Because each block id (and each shaped
variant) has its own material:

```
draws = mesh_blocks × materials_present_per_block + far_ring + misc
```

Measured at radius 128, fully streamed (perf analysis §2.3, verified against code):

- **~90 surface mesh blocks** (surface columns 1–2 deep; bulk-underground keeps interiors
  solid → fully occluded → not meshed).
- **~2.1 materials/block** — a typical surface chunk holds grass + dirt + stone ± sand ±
  snow-cap, i.e. ~2–3 distinct materials, averaging ~2.1.
- **+1** far ring (`facet_far_ring.gd` — a single `MeshInstance3D`, its own
  vertex-color `StandardMaterial3D`, `:319-324`).
- **+~15** misc (sky, water surface elsewhere, UI, prewarm, VoxelBody debris).

```
204 ≈ 90 × 2.1  +  1  +  15
```

**Materials are the cheaper axis to attack** (block count is fixed by view distance; the
`× 2.1` multiplier is pure per-material surface splitting). At ~50 µs/draw on GL-compat →
ANGLE → D3D11, 204 draws ≈ 30 fps (clean 2-vsync frames); 44 draws ≈ 55–60 fps.

---

## 2. The atlas scheme

### 2.1 Core idea

Replace "N textures behind N materials" with "**one atlas texture behind one opaque
material**, per-face tile selection in per-model UVs." The cube models already have the
exact API for this — `set_atlas_size_in_tiles` + per-face `set_tile` — we just:

1. Build ONE atlas image (grid of all opaque tiles) and ONE opaque `StandardMaterial3D`
   pointing at it (the "atlas material").
2. Give EVERY opaque cube model that **same shared material instance** and set each face's
   `set_tile(side, atlas_cell_of(id, side))` instead of a 1×1 (0,0).
3. For shaped opaque models, bake atlas-remapped UVs into the ArrayMesh (§2.4).

Because all opaque models now reference the one atlas material, the mesher merges them into
**one opaque surface per mesh block**. The `× 2.1` multiplier collapses to `× 1`.

### 2.2 Atlas layout, size, NEVER-OOM

- **Tiles:** each source tile is 128×128 (`TexturePackBaker` output). The atlas packs the
  ~30 distinct opaque tiles. A **grass-style top/side/bottom split** wants a few extra
  cells (grass, podzol, snow-capped, sand top vs side) — budget generously for **≤ 64
  cells**.
- **Padding / gutter (mandatory — see §4.3):** each cell needs a border gutter to stop
  mip-level bleed. Use a **half-tile power-of-two cell with an edge-extend gutter**: place
  the 128×128 tile in a 128-pixel cell but replicate its border pixels into a gutter, OR
  drop to a fixed small mip chain. Simplest robust layout: **8×8 grid of 128 px cells =
  1024×1024**, with a 4–8 px edge-clamp gutter baked per cell (the tiles are designed
  TILEABLE, so edge-replication is seam-free). 1024² RGBA = **4 MB** uncompressed.
- **`atlas_size_in_tiles`:** set the **library-wide** cube atlas to the grid dimensions
  (e.g. `Vector2i(8, 8)`); each `set_tile(side, Vector2i(col, row))` then addresses a cell.
- **NEVER-OOM (memory-neutral-to-positive):** ONE 1024² atlas (4 MB) REPLACES ~30 separate
  128² textures (~30 × 64 KB = ~2 MB) plus their per-material GPU state. The GPU-resident
  byte delta is small and bounded; the win is fewer material/texture *bindings*, not bytes.
  No per-frame allocation. The flag-OFF path keeps today's separate textures exactly.
  **Build the atlas ONCE at `setup()` on the main thread**, next to `_configure_library`,
  and cache it; never rebuild per frame or per crossing.

### 2.3 UV-rect per block-id / per-face (the cube path — LOW risk)

The cube path is trivial because `VoxelBlockyModelCube` already generates per-face UVs from
`(atlas_size_in_tiles, set_tile)` at `bake()`. Plumbing:

1. Assign each distinct **tile** an atlas cell `(col, row)`. Build `atlas_cell: {tile_stem
   → Vector2i}` at atlas-build time.
2. For each opaque block id, resolve its face tiles. Today all 6 faces share one tile; the
   atlas is the natural moment to introduce **per-face tiles** (grass top vs side vs dirt
   bottom) as an optional data extension in `BlockTextures` — but **v1 keeps all 6 faces on
   the same cell** (byte-identical appearance to today, minimal risk).
3. In `_add_cube` (atlas branch): `set_atlas_size_in_tiles(GRID)`, then
   `set_tile(side, atlas_cell_of(id, side))` for each of the 6 sides, and
   `set_material_override(0, ATLAS_OPAQUE_MATERIAL)` — the **shared** instance.

`bake()` emits UVs pointing into the correct atlas cell; every opaque cube now shares one
material.

### 2.4 UV-rect for the shaped model families (the plumbing — the RISK)

Shaped models (`VoxelBlockyModelMesh`) carry UVs baked into the ArrayMesh by
`ShapeMesh.build` (`shape_mesh.gd`), which uses **planar UVs**: top/bottom → `(x, z)`,
sides → `(tangent, y)` — i.e. a unit-cell 0..1 range (`_uvxz` `:_`, `_face_uv` `:260-267`,
`_side` `:279-281`). To atlas these, each UV must be **affine-remapped into the model's
atlas cell**:

```
uv_atlas = cell_origin(material, face) + uv_unit × cell_size
```

where `cell_size = 1 / GRID` and `cell_origin` is the cell's top-left in atlas UV space.

**The sharing tension.** Today `_shape_mesh_cache` shares ONE ArrayMesh per modifier across
ALL materials (geometry is material-independent). Atlas-remapped UVs are
**material-dependent** (the cell differs per material), so a naively remapped ArrayMesh can
no longer be shared across materials. Three resolution options, in preference order:

- **(A) Per-(material, modifier) ArrayMesh with baked atlas UVs.** Drop the cross-material
  sharing for shaped models: cache keyed `(material_cell, modifier)`. The geometry
  (verts/normals/indices) is still built once per modifier and cloned; only the UV array is
  offset. Memory cost: the ArrayMesh count for shapes rises from ~79 (distinct shapes) to
  ~`shape_materials × modifiers` (≈ 8 × 61 ≈ 500). Each shape mesh is tiny (a unit cell,
  a few dozen verts), so ~500 × a few KB ≈ **1–2 MB** — bounded, ledgered, acceptable under
  NEVER-OOM. **This is the recommended path**: it keeps ALL shaped opaque models on the one
  atlas material, so they collapse into the same opaque surface as the cubes.
- **(B) Keep shaped models on their own per-material materials.** Do NOT atlas the shapes;
  only cubes go on the atlas. Simpler, but a mesh block containing a smoothed ramp still
  emits `atlas surface + ramp-material surface`. Since shaped cells are a MINORITY of
  surface cells, this captures most of the win but leaves a residual `× ~1.3` on
  shape-bearing blocks. **This is the Stage-1 fallback** (see §5) — ship it if (A) is not
  ready, measure, then complete (A).
- **(C) Per-model UV transform.** If the linked `godot_voxel` exposes a per-model UV
  offset/scale on `VoxelBlockyModelMesh` (it does NOT in v1.4.1 — confirmed absent), a
  single shared ArrayMesh + per-model UV transform would avoid the mesh multiply. **Not
  available; do not rely on it.**

**Per-family plumbing under (A):**

| Family | UV remap |
|---|---|
| Corner-height shapes (`_make_shape_model`) | remap the shared `ShapeMesh.build(modifier)` UVs into the material's opaque cell; cache `(cell, modifier)`. |
| Snow-cap variants | same geometry, but the material is `snow_capped_for` → the **snow atlas cell**. The snow tile lives in the atlas; the base-hue tint moves from `albedo_color` into a **per-cell tint baked into the atlas** OR a vertex color (see §2.6 tint caveat). |
| Snow LAYER / snow-FILL composites | the snow slab surface → snow cell; the terrain ramp surface → the terrain material's cell. These are **2-surface** meshes today (`_make_wet_model`, comp builders); under the atlas both surfaces reference the one opaque atlas material with different cells, merging to one surface. |
| Sharp slopes | as corner-height shapes, per (mat, payload). |
| Carve sentinels | plain-cube atlas cell per material; the C++ mesher clips them (facet-independent) — UVs are cube UVs, so trivial. |

### 2.5 Water / transparent / emissive keep a SECOND (and third) material

Blocks that genuinely need a different **blend mode** or **emission** cannot share the
opaque material. Enumerated (from `blocks.json`):

- **Translucent family — 8 ids:** `water`, `ice`, `glass`, `tinted_glass`,
  `{white,red,blue,green}_stained_glass`. These need `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`
  and a transparency index for face culling. They go on a **second, translucent atlas
  material** (one shared alpha-blended `StandardMaterial3D` over a small translucent atlas
  — glass, ice, water tiles + the stained-glass tint via vertex color). Native
  waterlogging keeps its `VoxelBlockyModelFluid` path unchanged (water renders as a fluid
  model, not a cube — `module_world.gd:2422-2428`); the translucent atlas covers glass/ice
  and the legacy water slab/composite path.
- **Emissive — 1 id:** `lava`. `emission_energy_multiplier` is a per-material scalar; a
  single lava cell type does not justify atlasing. **Lava keeps its own material.** (Any
  future emissive palette could get an emission-atlas, out of scope.)

**So the terminal material budget is ~2–3 materials total** (1 opaque atlas + 1 translucent
atlas + lava), versus one-per-id today. The DOMINANT terrain (all 67 opaque solids + their
shaped variants) is **1 material**.

### 2.6 Tint caveat (must resolve in Stage 2)

Two current looks come from `albedo_color` on a per-material basis, which a shared atlas
material cannot carry per-cell:

- **Flat-swatch blocks** (no tile) — today `albedo_color = color_of(id)`. Under the atlas,
  bake a **solid-color cell into the atlas** for each swatch-only id (cheap; a few cells),
  OR move the color into **per-voxel vertex color** (the mesher supports it;
  `vertex_color_use_as_albedo` is already on). Recommended: **bake a swatch cell** — it is
  exact and needs no worker change.
- **Snow-cap base-hue tint** (`lerp(WHITE, base_color, 0.18)`) — today per snow-variant
  material. Under the atlas, either bake a **per-base snow cell** (4 cells) or fold the
  0.18 tint into vertex color. Recommended: **4 baked snow cells** (grass/podzol/sand/stone
  snow variants) — exact, no worker change.

This is why the atlas cell count budgets to ≤ 64, not ~30: swatch-only ids and the 4 snow
variants each take a cell.

---

## 3. Draw-call math AFTER the atlas

With all opaque terrain (cubes + shaped variants) on ONE opaque material:

```
draws_after ≈ mesh_blocks × 1  +  translucent_surface_in_blocks_that_have_it
            + far_ring + misc
```

- **~90 opaque surfaces** (one per surface mesh block; the `× 2.1` is gone).
- **+ ~5** translucent surfaces — only mesh blocks that actually contain glass/ice/legacy
  water get the second (translucent-atlas) surface; these are a minority (coast/water
  fringe, player-placed glass). Native-waterlog water is its own fluid surface as today.
- **+1** far ring (unchanged — keeps its own vertex-color material).
- **+~15** misc (unchanged).

```
draws_after ≈ 90 + 5 + 1 + 15 ≈ 111
```

Matches the perf analysis target (**204 → ~110**). fps-rung implication (perf §2.2/§4):

- Non-draw base cost ≈ 10–12 ms (physics + GDScript + voxel tick + submit/compose).
- At ~50 µs/draw, 110 draws ≈ 5.5 ms of draw cost.
- **True frame cost ≈ 16–18 ms** → crosses the 16.7 ms (1-vsync) boundary.
- **Mid clients snap to the 45–60 fps rung; weak clients get a clean 30** (worst ≈ 32 ms,
  no hitch). The FP-M2 `StreamLoadController` credit (pinned at 0 all session per
  `[[voxiverse-web-time-process-invalid]]`) can begin to recover once the floor drops.

This is the single highest engineering-value change on gl_compatibility that needs no
engine rebuild. It **stacks** with a later 64³ mesh-block or settled-terrain bake (L4 →
~40 draws, robust 60 fps).

---

## 4. Correctness + gates

### 4.1 Flag-OFF byte-identity (the non-negotiable)

`FP_ATLAS_MATERIAL` default **OFF** ⇒ `_add_cube` / `_make_shape_model` take today's
per-model-material path verbatim, the atlas is never built, `BlockMaterials.get_for`
returns today's per-id materials. **`verify_feature` FLAT must stay 6035/0**, and the
faceted gates green, with the flag off. The cube-ARID == block-id invariant is untouched
(the atlas changes materials + UVs, not model indices).

### 4.2 Flag-ON rendered-equivalence — a NEW gate is needed

The existing baked-model identity gates (**G-M2-ID** etc.) assert the voxel **TYPE** the
worker emits (which ARID), NOT its **appearance**. The atlas changes appearance plumbing
(which atlas cell a face samples), so those gates pass unchanged and do not cover the
atlas. Add:

- **G-ATLAS-UV (new):** for every opaque block id and face, assert the baked cube model's
  face UVs sample the atlas cell assigned to that id's tile (compute the expected cell rect
  from `atlas_cell_of(id, face)` and compare the model's baked UV rect). For each shaped
  `(material, modifier)`, assert the remapped ArrayMesh UVs lie within the material's cell
  rect and match `cell_origin + unit_uv × cell_size` for a sample of vertices.
- **G-ATLAS-MAT (new):** assert every opaque model's `material_override(0)` is the ONE
  shared atlas material instance (identity check), and every translucent model's is the ONE
  translucent atlas instance — i.e. the mesher will actually merge them.
- **G-ATLAS-COVER (new):** assert every tile referenced by any block id (opaque + swatch +
  snow variant) has an atlas cell (no id maps to an unbaked/out-of-range cell → would
  render the wrong tile or a hole).

These run headless in the module verify (extend `verify_feature.gd` / the FP-M2 verifier),
asserting the built library, not by eye. A **visual A/B** through the remote bridge (same
scene, flag OFF vs ON, compare frames) confirms no appearance regression on real GPU.

### 4.3 Mip / bleed / filtering caveats

- **Mip bleed:** an atlas + mipmaps bleeds adjacent cells at coarse mip levels (a face's
  texels average across the cell border into the neighbour). Mitigations, in order:
  1. **Edge-extend gutter** per cell (replicate border pixels). The tiles are TILEABLE, so
     edge replication is seam-free. A 4–8 px gutter covers ~2–3 mip levels — enough for the
     near field (blocks are viewed at ~1 texel/pixel to a few pixels).
  2. **Limit the mip chain** on the atlas material (fewer mips → less bleed, mild shimmer).
     Today's materials use `NEAREST_WITH_MIPMAPS`; the atlas keeps it but with the gutter.
  3. **Alternative to evaluate: `Texture2DArray`** (one layer per tile) eliminates bleed
     entirely and mips cleanly. BUT `VoxelBlockyModelCube`'s atlas API is 2D-tile-based
     (`atlas_size_in_tiles` + `set_tile`), so a texture array would need per-face UV-W
     plumbing the cube model may not expose — **prototype-gate this before committing**; the
     padded 2D atlas is the safe default.
- **Filtering:** keep `TEXTURE_FILTER_NEAREST_WITH_MIPMAPS` for the pixel-art look; NEAREST
  within a cell does not sample across the gutter at mip 0, so bleed is a coarse-mip-only
  concern the gutter handles.
- **`texture_repeat`:** must be **OFF / CLAMP** on the atlas material (repeat would wrap a
  cell's UVs into neighbours). The module's unit-cell UVs are 0..1 within a cell, so clamp
  is correct. (The fallback mesher, which tiles per world-metre and NEEDS repeat, is a
  DIFFERENT path and is out of scope — it keeps its per-id materials.)

---

## 5. Effort / risk / sequencing

**Overall: M (medium).** The library build + manifest bakes in `module_world.gd` plus a new
atlas builder; water/transparents keep a second material. The RISK is concentrated in the
**UV plumbing across the shaped model families** (§2.4) — everything else is mechanical.

Sequence so the draw-cut is proven before the risky plumbing lands:

- **Stage 0 — Atlas builder + flag.** Add `FP_ATLAS_MATERIAL` (default OFF). Build the
  padded opaque atlas image + shared opaque material at `setup()`; build `atlas_cell` map.
  Add G-ATLAS-COVER. No rendering change yet (nothing consumes the atlas). *Gate: FLAT
  6035/0 unchanged.*
- **Stage 1 — Plain cubes onto the atlas (proves the cut).** Atlas-branch `_add_cube`:
  shared opaque material + per-face `set_tile` into the atlas cell; bake swatch cells for
  swatch-only ids (§2.6). Shaped models STAY on their per-material materials (option B).
  This alone collapses the cube-dominated blocks. *Measure via the bridge: expect
  204 → ~130–150 draws (cubes merged, shapes still split). Gate: G-ATLAS-UV/-MAT on cubes;
  visual A/B.* This is the checkpoint that de-risks the whole effort — if the cube merge
  does not move draws as predicted, stop and re-measure before touching shapes.
- **Stage 2 — Shaped opaque families onto the atlas (option A).** Per-(material, modifier)
  atlas-UV ArrayMeshes for corner-height shapes, snow variants, layers, comps, slopes,
  carve sentinels; bake the 4 snow cells + move flat-swatch tint to atlas cells. Now ALL
  opaque terrain is one material. *Measure: expect ~110 draws. Gate: G-ATLAS-UV on shapes;
  ledger the shape-mesh memory delta (~1–2 MB); visual A/B on smoothed terrain + snow line.*
- **Stage 3 — Translucent atlas.** Second shared alpha-blended material over a small
  translucent atlas (glass/ice + legacy water slab/composite). Keep lava on its own
  material; keep native-waterlog fluids unchanged. *Gate: G-ATLAS-UV on translucent models;
  visual A/B on water/glass (sorting + culling intact).*

**Interactions:**

- **Far ring** (`facet_far_ring.gd`) — unaffected; keeps its own vertex-color
  `StandardMaterial3D` and its 1 draw. No atlas plumbing.
- **Just-removed near-LOD** (`FP_NO_NEAR_LOD`) — the atlas applies to the module
  `VoxelTerrain` near field only; there is no near-LOD mesh layer to also atlas. If near-LOD
  is ever re-introduced, its `FacetLodBuilder` meshes would need the same atlas material +
  remapped UVs to avoid re-splitting the surface — note it, out of scope now.
- **Native waterlogging** — orthogonal; water stays a fluid model. The atlas only touches
  the solid opaque + legacy-translucent paths.
- **Runtime material streaming** (`BlockMaterials.refresh` / `reset_cache`) — a streamed
  LRID that late-resolves would need an atlas cell allocated on the fly (append a cell +
  re-bake the atlas image, or reserve a "streamed" region). v1 assumes the bootstrap
  palette (the shipped world); streamed-material atlasing is a follow-up, and until then a
  streamed id can fall back to its own per-id material (a residual surface, never a hole).

**Riskiest isolated item:** the **per-(material, modifier) atlas-UV ArrayMesh remap for the
shaped families** (§2.4 option A) — it is where cross-material mesh sharing breaks, where
the memory ledger moves, and where G-ATLAS-UV must be exact. Stage 1 deliberately defers it
so the draw-cut hypothesis is validated on cubes first; if Stage 1's numbers hold, Stage 2
is mechanical remapping with a clear gate.
