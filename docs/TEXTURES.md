# VOXIVERSE — Block Textures

How block faces are textured: the source art pack and its licence, the
detail-enhancement bake, the id→texture pipeline, the Godot import settings and
why, and how to add textures for new blocks. Rendering conventions (unshaded,
flat ambient, no sun) come from DESIGN §1; the id→material contract is DESIGN §1.2.

## 1. The pack and its licence

| | |
|---|---|
| Pack | "16\*16 Block Textures" / "16x16 Block Texture Set" |
| Author | ARoachIFoundOnMyPillow |
| Source | https://opengameart.org/content/1616-block-textures · https://opengameart.org/content/16x16-block-texture-set |
| Download | `blocks_2.zip` — https://opengameart.org/sites/default/files/blocks_2.zip |
| Licence | **CC0 1.0 Universal** (public domain dedication) — https://creativecommons.org/publicdomain/zero/1.0/ |
| Attribution | **Not required** (CC0). Credited anyway in `godot/assets/textures/pack/LICENSE.txt` for provenance. |

CC0 permits redistribution, modification and commercial use with no conditions —
so the tiles can live in-repo and ship in the web build freely. The base pack is
16×16 pixel-art covering far more than the current five blocks (grass, dirt,
stone/granite/diorite/slate/…, oak/pine/beech/eucalyptus/maple logs+planks+leaves,
sand, gravel, sandstone, glass, ice, snow, cobblestone, ores, …) — headroom for the
Minecraft-parity catalog workstream (`docs/WORLDGEN-CATALOG.md`).

## 2. The "16×16 with high-res detail" look

The product owner wanted textures that **read as blocky 16×16 pixel-art** but where
each "pixel" carries **higher-resolution internal detail** — a green pixel varies
within itself, a near-black pixel is textured dark noise rather than a flat fill.
Off-the-shelf packs are either flat 16× (no sub-pixel detail) or smooth HD (no
16× silhouette), so this is produced by a deterministic **enhancement bake**:

`src/world/texture_pack_baker.gd` (`TexturePackBaker`) upscales each 16×16 base
tile by **8× → 128×128** and, per output pixel, keeps the source pixel's colour
(nearest — so the hard 16× silhouette survives exactly) while modulating brightness
with tileable multi-octave value-noise, plus a "dark-lift" term that injects noise
into dark pixels so blacks read as texture, not a void. It is:

- **Deterministic** (fixed `SEED`) — re-baking is reproducible.
- **Tileable** over the 128 px output (noise lattice wraps) — so the fallback
  mesher, which tiles one texture per world-metre, shows **no seam** between faces.
- **Alpha-aware** — opaque blocks (all five today) fill any source holes (e.g. leaf
  cut-outs) with a solid backing colour so the block stays solid; a future block can
  set `keep_alpha` in the spec to preserve cut-outs (e.g. glass).

Re-bake after editing the spec or the algorithm:

```bash
docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
    -s res://src/tools/bake_textures.gd        # writes pack/<name>.png
```

## 3. Folder layout

```
godot/assets/textures/pack/
  LICENSE.txt          CC0 dedication + source + provenance
  grass.png dirt.png stone.png wood.png leaf.png   ENHANCED 128×128 — the engine loads THESE
  *.png.import         import settings (§5) — committed; .ctex regenerates at export
  src/
    .gdignore          Godot skips this dir (not imported, not scanned, not exported)
    *.png              CC0 16×16 base tiles (80) — bake input only, read via raw Image.load
```

The enhanced files are named by **material**, not by id — `pack/grass.png`, not
`pack/1.png`. That stable, content-descriptive name is the key the
runtime-material-streaming workstream (`docs/RUNTIME-MATERIAL-STREAMING.md`) can
content-address on. `src/` is excluded from the web export twice over (`.gdignore`
+ `exclude_filter` in `export_presets.cfg`), so only the five ~19 KB enhanced tiles
(~100 KB total) ship.

## 4. id → texture → material pipeline

One data table, one builder — nothing special-cases a block:

```
BlockTextures.TILES     block id -> "grass" | "dirt" | ...   (src/world/block_textures.gd)
        │  path_for(id) -> res://assets/textures/pack/<name>.png
        ▼
BlockMaterials.get_for(id)                                    (src/world/block_materials.gd)
        │  textured StandardMaterial3D if a tile exists, else a flat solid swatch
        ▼
   module library (module_world._add_cube, 1×1 atlas)
   fallback mesher (chunk_mesher, per-metre UVs)
   VoxelBody (detached bodies)                ← all read the SAME material
```

`BlockMaterials.get_for(id)` is THE id→material query (cached per id). It builds a
textured material for any id `BlockTextures` maps, and falls back to a flat
`BlockCatalog.color_of(id)` swatch for any id it doesn't — so an un-textured new
block still renders (in its swatch colour) instead of crashing. The sim layer
(`SurfaceModel`) reads the grass tile through the same `BlockTextures.path_for`, so
the look never diverges between render and sim.

**id → tile map (today):**

| id | block | tile (`pack/…`) | source (`src/…`) |
|---|---|---|---|
| 1 | grass | `grass.png` | `grass_top.png` |
| 2 | dirt | `dirt.png` | `dirt.png` |
| 3 | stone | `stone.png` | `stone_generic.png` |
| 4 | wood | `wood.png` | `oak_log_side.png` |
| 5 | leaf | `leaf.png` | `oak_leaves.png` |

Each cube model uses **one material for all six faces** (see `module_world._add_cube`
— a 1×1 tile atlas showing the whole texture per face). Grass therefore shows
`grass_top` (green) on every face, matching the previous all-green grass look.

## 5. Import settings (and why)

Set on `pack/*.png.import` (committed; the `.ctex` in `.godot/imported/` is
git-ignored and regenerated at export):

| Param | Value | Why |
|---|---|---|
| `compress/mode` | `0` (Lossless) | **Crisp pixels.** VRAM/BCn compression bleeds colour across the hard 16× pixel edges — fatal to the pixel-art look. Tiles are tiny (~19 KB) so there is nothing to gain from compressing. |
| `detect_3d/compress_to` | `0` | The default (`1`) silently **re-imports to VRAM-compressed the first time a texture is used in 3D** — which would undo the Lossless choice. Disabled. |
| `mipmaps/generate` | `true` | The fallback mesher tiles one texture per world-metre; mipmaps tame distant shimmer. |

Filtering is set on the **material**, not the import: `texture_filter =
NEAREST_WITH_MIPMAPS` (nearest for crisp near pixels, mipmapped far). Materials are
also `SHADING_MODE_UNSHADED`, `CULL_DISABLED` (double-sided), `texture_repeat = true`
(per-metre tiling) — matching the DESIGN §1 flat-ambient conventions.

### Web-build caveats

- The web preset is threaded and needs COOP/COEP (see root `CLAUDE.md`); textures
  don't change that, but do **not** switch these tiles to VRAM compression — the
  `vram_texture_compression/for_desktop=true` export flag only affects textures
  imported as VRAM-compressed, and Lossless is what keeps the look intact on WebGL2.
- Both render paths were verified: module path (1×1 atlas → whole texture per face)
  and fallback (per-metre tiling → seamless because the detail noise is tileable).

## 6. Adding textures for a new block

1. Drop (or bake) the tile into `pack/` as `pack/<name>.png`. If you have a 16×16
   base, add a row to `TexturePackBaker._spec()` and re-bake (§2); otherwise commit a
   128×128 tile directly and give it the §5 import settings.
2. Add `BlockCatalog.<ID>: "<name>"` to `BlockTextures.TILES`.
3. Done — `BlockMaterials`, both meshers and `VoxelBody` pick it up automatically.

**Mapping stub for the Minecraft-parity catalog** (`docs/WORLDGEN-CATALOG.md`) — CC0
base tiles already in `src/` for the naturals that workstream is likely to add:

| block | candidate `src/` tile | notes |
|---|---|---|
| sand | `sand_ugly.png` | rename on bake to `sand` |
| gravel | `gravel.png` | |
| sandstone | `sandstone.png` | |
| cobblestone | `cobblestone.png` | |
| glass | `glass.png` | set `keep_alpha=true` in the spec |
| snow | `snow.png` | |
| ice | `ice_glacier.png` | translucent → `keep_alpha` |
| coal/iron/… ore | `stone_generic_ore_nuggets.png`, `…_crystalline.png` | |
| granite / diorite / slate / basalt / marble / limestone | same-named tiles | stone variants |
| pine / beech / maple / eucalyptus log/planks/leaves | `<species>_log_side.png` etc. | more tree species |

## 7. Known follow-ups

- **Per-face grass** (green top, dirt-fringe sides): the base pack ships
  `grass_side.png` / `grass_snowy_side.png`. `VoxelBlockyModelCube` supports per-face
  tiles via a multi-tile atlas, but the current `_add_cube` uses one 1×1 tile for all
  faces — wiring per-face top/side is the follow-up.
- **Log end grain**: same story — `oak_log_top.png` (rings) is in `src/`; wood
  currently uses the bark side on all faces.
- **Transparent blocks** (glass, leaves-with-cut-outs): the baker supports
  `keep_alpha`; the material would need alpha-scissor/transparency wired for the
  authentic see-through look (deferred to keep the web build robust).
