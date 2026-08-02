# COSMOS far-skin BLOCK-EXACT colour classification (FP_SKIN_BLOCK_EXACT)

Fable design, 2026-08-02. Driven by the user directive:
> "Colors MUST correspond exactly to the original block textures only. Biomes define block
> textures, block textures define pixel colors for FAR skin."

## The one law (both paths, GDScript + C++)

```
texel_index = far_color_index_of_block( top_block_id(column) )

top_block_id(g, biome, t, x, z):
    g < SEA_LEVEL                 -> ice | lava | water     (t vs CLIMATE_FROZEN / LAVA_SEA_T)
    surface_temperature(g,t) < 0  -> snow_block             (g >= SEA_LEVEL)
    biome == B_PILLAR             -> bedrock
    else                          -> _biome_top(biome, x, z)   (beach/desert->sand, badlands->red_sand,
                                        swamp->mud, snowy->snow, taiga->podzol/grass hash, mountains->stone,
                                        ocean->sand, DEFAULT incl. plains/forest/savanna/jungle -> GRASS)
```

Byte-equality is by SHARED LUT, not parallel math: for a colour that is an exact `frozen_colors` entry,
`FarPalette.far_color_index(colour)` returns its canonical index with the same first-min tie rule as C++
`nearest_far_index`, so C++ `deco_far_idx[id]` == GDScript `far_color_index_of_block(id)`.

Trees differentiate the biomes (acacia/jungle canopies) via the TREE branch, which is already block-exact
on the C++ side (`deco_far_idx[deco]`) and becomes `far_color_index_of_block(deco)` on the GDScript side.

## Investigation verdicts
- Q1: savanna(11)/jungle(12) surface as GRASS (terrain_config.gd `_biome_top` default); they carry their own
  TREE species. Far ground colour == grass texture mean, legitimately.
- Q2: the C++ generator has NO Whittaker classifier and NO acacia/jungle tree species (cosmos_terrain.h
  `biome_of` legacy chain only; `tree_species_for` has no SP_ACACIA/SP_JUNGLE). Under FP_CLIMATE_BIOMES it
  computes different biome ids AND emits no savanna/jungle trees. Both must be ported. Bonus: closes a latent
  FP_CPPGEN+FP_CLIMATE_BIOMES near-terrain divergence.
- Q3: `far_color_index_of_block` under FP_SKIN_TEXTURE_MEAN == texture-mean nearest-index (distance-0 exact for
  the 14 canonical top blocks). Non-canonical blocks (jungle/acacia/birch leaves, bedrock) quantise to nearest
  of 14 (full canopy exactness needs a palette-extension — separate design).

## Plan
- New const `FP_SKIN_BLOCK_EXACT := false` (cube_sphere.gd, next to FP_SKIN_TEXTURE_MEAN). NOT byte-identical to
  shipped even flags-off (taiga speckle, forest->grass, pillar, dry-ocean-floor) -> its own flag; repo default
  off keeps every existing gate untouched; deploy bakes it ON with FP_CLIMATE_BIOMES + FP_SKIN_TEXTURE_MEAN.

### P0 GDScript (no rebuild)
1. `terrain_config.gd` after `_biome_top`: `static func top_block_id(g,biome,t,x,z) -> int` per the law.
2. `facet_tex_baker.gd` `_pbm_compute`: tree branch -> `far_color_index_of_block(deco)`; terrain branch ->
   `far_color_index_of_block(TerrainConfig.top_block_id(g, int(prof.y), prof.w, lx, lz))` (under the flag).
3. `surface_shot.gd` `top_far_index`: same two substitutions under the flag.

### P1 C++ (patch 0011 regenerate; engine rebuild)
1. `cosmos_terrain.h`: add B_SAVANNA=11, B_JUNGLE=12; `whittaker_biome(t,h)` (verbatim port of
   terrain_config.gd `_whittaker_biome` 688-709); `biome_of` gains `bool climate_biomes` -> Whittaker after
   ocean/beach/mountain guards.
2. `Parameters`: `bool climate_biomes`, `bool skin_block_exact`, `int id_acacia_log/id_acacia_leaf/
   id_jungle_log/id_jungle_leaf`.
3. `tree_species_for`: port tree_gen.gd 105-122 (ACACIA_DENSITY hash salt 124) under climate_biomes; port
   `_jungle_block`/`_acacia_block` (tree_gen.gd 286-330) incl. trunk-height hashes; wire into `tree_block_at`.
4. `top_block_id(p,g,biome,t,x,z)` (reuses sea_liquid_kind/surface_temperature/biome_top/id_bedrock).
   `bake_far_tile`: under `p.skin_block_exact` -> `fi = p.deco_far_idx[top_block_id(...)]`. `far_color`/
   `far_index`: under the flag, terrain result routes through deco_far_idx[top_block_id] so sample_columns
   "colors" stay byte-consistent (band + fine-cpp branches need no change).
5. Config plumb from the TerrainConfig config dict so module_world FP_CPPGEN, facet_skin_tier `_build_cpp_gen`,
   and verify_cppgen all agree: climate_biomes, skin_block_exact, 4 tree-species ids.

### P2 gates
- `verify_tile_bake.gd` `_gd_ref`: mirror the flag; add coverage assert (sampled facets contain >0
  savanna/jungle columns and >0 jungle-tree texels) under live flags.
- `verify_cppgen.gd` G-CG-COLUMNS `want` + `gd_sample` oracle: mirror the flag branch.
- Flag-matrix: all-off byte-identical to shipped (diff one facet's bake bytes old-vs-new); live trio on C++≡GD.

## color_for KEEP (caller migration)
Migrate ONLY: facet_tex_baker terrain+tree, surface_shot.top_far_index, facet_skin_tier gd_sample oracle.
KEEP color_for/biome_base/sea_color/_savanna/_jungle for: far-ring vertex colours, block-LOD vertex colours,
V2 shot tint pages (surface_shot), FP_FAR_SMOOTH, warm-ups, verify_climate G-B1-PAL. frozen_colors stays 14.

## Shipped-look changes when flags ON (direct consequence of the directive)
1. Savanna/jungle far GROUND -> grass (biomes visible via acacia/jungle canopy texels, which C++ will now draw).
2. Forest far tint (_forest blend row) gone from the skin -> forest ground reads as grass; canopy only from
   real TreeGen columns.
3. Taiga -> per-column podzol/grass speckle (near-matching) instead of a uniform blend.
4. Pillar -> bedrock-texture-mean; dry cold ocean floor gravel -> sand (now matches the near surface).
5. Residual near/far disagreement (out of scope): far-ring/smooth/block-LOD VERTEX colours + V2 shot tint pages
   still use synthetic color_for; non-canonical leaf/bedrock blocks quantise to nearest-of-14.

NEVER-OOM: two bools + four ints + branch logic, zero new runtime allocations (deco_far_idx already resident).
With this landed, FP_CLIMATE_BIOMES / FP_SKIN_TEXTURE_MEAN no longer force the fast tile bake off.
