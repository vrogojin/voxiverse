class_name FarPalette
extends RefCounted
## Data-driven per-vertex colours for the far-field terrain (LOD-DESIGN §2.3).
##
## Every colour is looked up ONCE from BlockCatalog.color_of(id) — there is NO
## hard-coded RGB here, so if the catalog recolours a block the far field follows
## by construction (LOD-DESIGN §2.3). The sea regime (ice / lava / water) mirrors
## TerrainConfig._sea_liquid_kind + the frozen threshold, and the snow-cap override
## reuses ClimateModel.surface_temperature — the exact predicate worldgen stamps
## altitude caps with — so the distant silhouette's colours match the near voxel
## world's ice caps, molten seas and snowy peaks by construction.
##
## Pure + deterministic (only catalog tints + climate curve; no randi/Time), so the
## far mesh is a pure function of (ring, tile_coord, SEED) like the rest of worldgen.

static var _ready := false
static var _water: Color
static var _ice: Color
static var _lava: Color
static var _snow: Color
static var _sand: Color
static var _gravel: Color
static var _red_sand: Color
static var _mud: Color
static var _grass: Color
static var _podzol: Color
static var _leaf: Color
static var _stone: Color
static var _taiga: Color      # deterministic mean of the 20% podzol hash (LOD-DESIGN §2.3.3)
static var _forest: Color     # canopy tint — the locked no-distant-trees compensation
static var _savanna: Color    # B1: tan grassland (grass↔sand lerp)
static var _jungle: Color     # B1: deep-green rainforest canopy (grass↔jungle_leaves lerp)

## Resolve every far-field colour from the catalog once. Idempotent; call before any
## lookup (FarTerrain warms it, but every accessor guards too).
# FP_SKIN_TEXTURE_MEAN: resolve a surface colour from the block's TEXTURE-TILE MEAN (what the near textured
# block averages to) instead of the flat catalog swatch, so the far skin's land colours match the near field.
# Tile-less ids (water/lava/red_sand) fall back to the swatch inside mean_color_of ⇒ unchanged. Flag off ⇒ the
# shipped color_of path exactly (byte-identical).
static func _top_color(id: int) -> Color:
	if CubeSphere.FP_SKIN_TEXTURE_MEAN:
		return BlockTextures.mean_color_of(id)
	return BlockCatalog.color_of(id)

## FP_FAR_COLOR_UNIFIED (docs/COSMOS-FACET-COLOUR-SEAM-DESIGN.md §3.1) — the fraction of a biome's columns a
## TreeGen tree's TOP-DOWN canopy decoration covers, derived from TreeGen's OWN density constants (not eyeballed):
##   coverage = PATCH_CHANCE · TREE_CHANCE · [species-select gate] · canopy_footprint_columns / G²
## PATCH_CHANCE(0.30)/TREE_CHANCE(0.45) gate whether a tree-grid cell hosts ANY tree at all (tree_gen.gd
## has_tree); G²=100 is the column count of one grid cell (tree_gen.gd G=10). FOREST (oak/birch) and JUNGLE
## species are never gated to SP_NONE for their biome (tree_gen.gd _species_for), so they omit the bracketed
## term; SAVANNA's acacia is additionally thinned by ACACIA_DENSITY (TreeGen's own "sparse savanna" factor).
## canopy_footprint_columns is the union of the shape function's top-down-visible columns (tree_gen.gd
## _oak_block/_jungle_block/_acacia_block): oak/birch's 3×3-ring + diamond cap covers the FULL 3×3 = 9 columns;
## jungle's and acacia's 5×5-wide-square + diamond cap both cover the FULL 5×5 = 25 columns. TAIGA is NOT listed
## here — its existing tint (below) is already the exact mean of the 20% podzol hash _biome_top stamps; adding a
## spruce-canopy term (≈13/100 footprint × 0.135 existence ≈ 1.8% coverage) moves it by ≈2/255, inside the gate's
## 4/255 tolerance, so the design leaves it untouched.
const _FOREST_CANOPY_COLS := 9.0
const _JUNGLE_CANOPY_COLS := 25.0
const _SAVANNA_CANOPY_COLS := 25.0
const _GRID_COLUMNS := float(TreeGen.G * TreeGen.G)
const FOREST_TREE_COVER := TreeGen.PATCH_CHANCE * TreeGen.TREE_CHANCE * _FOREST_CANOPY_COLS / _GRID_COLUMNS
const JUNGLE_TREE_COVER := TreeGen.PATCH_CHANCE * TreeGen.TREE_CHANCE * _JUNGLE_CANOPY_COLS / _GRID_COLUMNS
const SAVANNA_TREE_COVER := TreeGen.PATCH_CHANCE * TreeGen.TREE_CHANCE * TreeGen.ACACIA_DENSITY * _SAVANNA_CANOPY_COLS / _GRID_COLUMNS

## The four biome blend tints, factored out of `ensure_ready` as a pure function of the `unified` flag (instead of
## reading `CubeSphere.FP_FAR_COLOR_UNIFIED` directly) so verify_far_color_unified.gd can drive BOTH branches in one
## run without sed-toggling the compile-time const. `ensure_ready` below calls this with the real flag. Returns
## [taiga, forest, savanna, jungle] — TAIGA is identical on both branches (see the coverage-const comment above).
static func _biome_tints(unified: bool) -> Array[Color]:
	var taiga := _grass.lerp(_podzol, 0.20)          # TAIGA-DESIGN §2.3.3: 20% podzol / 80% grass hash mean; unchanged by the flag
	if unified:
		# The EXPECTED colour of the block-exact fine-map law (§3.1): grass blended toward the biome's REAL canopy
		# colour by its REAL tree-canopy coverage — not a hand-tuned lerp factor. Forest's canopy mixes oak (70%)
		# and birch (30%) leaf colour, mirroring TreeGen._species_for's own oak/birch split (tree_gen.gd:108),
		# so the derived tint matches the fine map's true species mix, not just the oak-only swatch.
		var oak_leaf := _leaf                          # BlockCatalog.LEAF == the oak leaf tile (tree_gen.gd SP_OAK)
		var birch_leaf := _top_color(BlockCatalog.id_of(&"birch_leaves"))
		var forest_canopy := oak_leaf.lerp(birch_leaf, 0.30)
		var acacia_leaf := _top_color(BlockCatalog.id_of(&"acacia_leaves"))
		var jungle_leaf := _top_color(BlockCatalog.id_of(&"jungle_leaves"))
		var forest := _grass.lerp(forest_canopy, FOREST_TREE_COVER)
		var savanna := _grass.lerp(acacia_leaf, SAVANNA_TREE_COVER)
		var jungle := _grass.lerp(jungle_leaf, JUNGLE_TREE_COVER)
		return [taiga, forest, savanna, jungle]
	# Shipped hand-tuned lerps, verbatim (byte-identical when the flag is off).
	var forest_off := _grass.lerp(_leaf, 0.35)
	var savanna_off := _grass.lerp(_sand, 0.40)
	var jungle_off := _grass.lerp(_top_color(BlockCatalog.id_of(&"jungle_leaves")), 0.55)
	return [taiga, forest_off, savanna_off, jungle_off]

static func ensure_ready() -> void:
	if _ready:
		return
	BlockCatalog.ensure_ready()
	_water = _top_color(BlockCatalog.id_of(&"water"))
	_ice = _top_color(BlockCatalog.id_of(&"ice"))
	_lava = _top_color(BlockCatalog.id_of(&"lava"))
	_snow = _top_color(BlockCatalog.id_of(&"snow_block"))
	_sand = _top_color(BlockCatalog.id_of(&"sand"))
	_gravel = _top_color(BlockCatalog.id_of(&"gravel"))
	_red_sand = _top_color(BlockCatalog.id_of(&"red_sand"))
	_mud = _top_color(BlockCatalog.id_of(&"mud"))
	_podzol = _top_color(BlockCatalog.id_of(&"podzol"))
	_grass = _top_color(BlockCatalog.GRASS)
	_leaf = _top_color(BlockCatalog.LEAF)
	_stone = _top_color(BlockCatalog.STONE)
	# Deterministic biome-mean tints (LOD-DESIGN §2.3.3): TAIGA is the 20% podzol / 80%
	# grass mean of _biome_top's hash; FOREST tints grass toward leaf to stand in for the
	# canopy the far field cannot draw as individual trees.
	# B1 climate-biome bands (design §6.5): savanna/forest/jungle/taiga tints (see _biome_tints).
	# FP_FAR_COLOR_UNIFIED (COLOUR-SEAM-DESIGN §3.1): off ⇒ the shipped hand-tuned lerps verbatim;
	# on ⇒ the block-exact fine-map law's expected colour, killing the tier-frontier colour seam.
	# Shown on the GDScript far path; the C++ skin path (frozen_colors, 14 entries) maps
	# savanna/jungle to grass via its default until the enum extends.
	var tints := _biome_tints(CubeSphere.FP_FAR_COLOR_UNIFIED)
	_taiga = tints[0]
	_forest = tints[1]
	_savanna = tints[2]
	_jungle = tints[3]
	_ready = true

## The sea-surface colour for a clamped (open-water) vertex of climate temperature `t`
## (LOD-DESIGN §2.3.1). Mirrors the sea regime: frozen → ice (white), molten → lava
## (orange), else water. Thresholds are the SAME named constants worldgen keys the sea
## fill off (ClimateModel.CLIMATE_FROZEN, TerrainConfig.LAVA_SEA_T), so a frozen ocean
## reads white and a lava sea orange at every distance.
static func sea_color(t: float) -> Color:
	ensure_ready()
	if t < ClimateModel.CLIMATE_FROZEN:
		return _ice
	if t >= TerrainConfig.LAVA_SEA_T:
		return _lava
	return _water

## The base biome colour for a dry-land vertex (LOD-DESIGN §2.3.3), keyed on the public
## B_* biome consts and mirroring _biome_top / _underwater_floor. `t` disambiguates the
## warm/cold ocean-floor sediment.
static func biome_base(biome: int, t: float) -> Color:
	ensure_ready()
	match biome:
		TerrainConfig.B_OCEAN:
			return _sand if t > 0.0 else _gravel     # unclamped shallow floor
		TerrainConfig.B_BEACH, TerrainConfig.B_DESERT:
			return _sand
		TerrainConfig.B_BADLANDS:
			return _red_sand
		TerrainConfig.B_SWAMP:
			return _mud
		TerrainConfig.B_SNOWY:
			return _snow
		TerrainConfig.B_TAIGA:
			return _taiga
		TerrainConfig.B_FOREST:
			return _forest
		TerrainConfig.B_SAVANNA:
			return _savanna
		TerrainConfig.B_JUNGLE:
			return _jungle
		TerrainConfig.B_MOUNTAINS:
			return _stone
		TerrainConfig.B_PILLAR:
			return Color(0.20, 0.20, 0.23)           # COSMOS M5c: bedrock-grey corner monument in the LOD horizon
		_:
			return _grass                            # B_PLAINS (and any unmapped)

## SEAMLESS-SCALES §7.2 item 2: the 14 far-field colours in the FIXED order VoxelGeneratorCosmos'
## far_color() (the C++ FarColor enum) indexes. The C++ port applies FarPalette.color_for's BRANCH
## logic over these, so a skin tile comes back render-ready in ONE sample_columns call. This is the
## SINGLE source of the order — both verify_cppgen's colour gate and module_world's frozen epoch
## build the config from this, so the C++/GDScript colours cannot drift on ordering.
static func frozen_colors() -> PackedColorArray:
	ensure_ready()
	return PackedColorArray([
		_water, _ice, _lava, _snow, _sand, _gravel, _red_sand, _mud,
		_podzol, _grass, _leaf, _stone, _taiga, _forest])

# FP_SKIN_FLATCOLOR: classify a colour / block to its index in frozen_colors() (0..13). The flat-color band stores
# this index (L8, +1; 0 = un-baked); the shell shader's far_lut = frozen_colors() maps it back to the flat colour.
# Both the LUT and this classifier resolve through frozen_colors() → _top_color, so under FP_SKIN_TEXTURE_MEAN every
# far map texel == the near textured block's 16×16 tile-mean colour (interior texels classify exactly, distance 0).
static var _fc_ready := false
static var _fc_rgb := PackedFloat32Array()
static var _block_idx := PackedInt32Array()   # block_id -> far colour index (0..13), precomputed on the MAIN thread

static func ensure_far_index_ready() -> void:
	if _fc_ready:
		return
	ensure_ready()
	var fc := frozen_colors()
	_fc_rgb.resize(fc.size() * 3)
	for i in range(fc.size()):
		_fc_rgb[i * 3] = fc[i].r
		_fc_rgb[i * 3 + 1] = fc[i].g
		_fc_rgb[i * 3 + 2] = fc[i].b
	# CRITICAL (worker-safety): precompute block_id -> far colour index HERE (main thread only). _top_color routes
	# through BlockTextures.mean_color_of, which load()s a PNG + get_image() the first time per tile — that MUST NOT
	# run on the offloaded band-bake worker (it stalls/faults). The worker then only INDEXES _block_idx (pure read).
	BlockCatalog.ensure_ready()
	var n := BlockCatalog.count()
	_block_idx.resize(n)
	for id in range(n):
		var c := _top_color(id)                 # main-thread mean_color_of (cached per tile stem)
		var best := 0
		var best_d := 1.0e30
		for j in range(fc.size()):
			var dr := c.r - _fc_rgb[j * 3]
			var dg := c.g - _fc_rgb[j * 3 + 1]
			var db := c.b - _fc_rgb[j * 3 + 2]
			var d := dr * dr + dg * dg + db * db
			if d < best_d:
				best_d = d
				best = j
		_block_idx[id] = best
	_fc_ready = true

static func far_color_index(c: Color) -> int:
	ensure_far_index_ready()
	var best := 0
	var best_d := 1.0e30
	var n := _fc_rgb.size() / 3
	for i in range(n):
		var j := i * 3
		var dr := c.r - _fc_rgb[j]
		var dg := c.g - _fc_rgb[j + 1]
		var db := c.b - _fc_rgb[j + 2]
		var d := dr * dr + dg * dg + db * db
		if d < best_d:
			best_d = d
			best = i
	return best

## Worker-safe: a PURE index into the precomputed _block_idx LUT (built on the main thread by ensure_far_index_ready
## during the baker setup prewarm). NEVER loads a texture, so the offloaded band bake can call it per texel.
static func far_color_index_of_block(block_id: int) -> int:
	if block_id >= 0 and block_id < _block_idx.size():
		return _block_idx[block_id]
	return 0                                        # AIR / out of range → index 0 (no texture load on the worker)

## FP_SKIN_BLOCK_COLOR (docs/COSMOS-SKIN-BLOCK-COLOR-DESIGN.md): the worker-safe block-exact Color for a
## block id — quantised to the SAME frozen 14-entry palette the fine map / tile-bake tier already draws
## from, via far_color_index_of_block's precomputed LUT. Deliberately NOT _top_color()/mean_color_of()
## (that path load()s a texture on first touch — unsafe on the WorkerThreadPool tasks facet_far_ring.gd /
## facet_smooth_v2.gd / facet_block_lod_ring.gd build on, per the CRITICAL comment on ensure_far_index_ready
## above). Pure array reads only.
static func color_for_block(block_id: int) -> Color:
	var idx := far_color_index_of_block(block_id)
	var j := idx * 3
	return Color(_fc_rgb[j], _fc_rgb[j + 1], _fc_rgb[j + 2])

## FP_SKIN_BLOCK_COLOR (docs/COSMOS-SKIN-BLOCK-COLOR-DESIGN.md §1.3): THE per-vertex colour law swap, the single
## home shared by every color_for consumer this flag reaches (facet_far_ring.gd's 7 sites incl. _weld_node,
## facet_smooth_v2.gd's build_tile, facet_block_lod_ring.gd's _build_facet_arrays). Off (shipped) ⇒ color_for's
## biome-blend verbatim — byte-identical. On ⇒ resolve the ACTUAL top block at lattice column (lx,lz):
## TerrainConfig.top_block_id resolves the block (already subsumes sea/snow — no separate clamped_sea branch
## needed) and color_for_block above supplies the WORKER-SAFE quantised colour (never _top_color/mean_color_of —
## every one of this flag's consumers builds on WorkerThreadPool). `g/biome/t` are the SAME profile values the
## shipped color_for call already consumes. Use this overload directly when the caller already has an integer
## lattice column (e.g. facet_block_lod_ring.gd's decimated-pyramid loop); use `skin_color` below when the
## caller only has a world-space sample point. `on` defaults to the compiled const so every production call
## site is unaffected; it is an explicit param (not read internally) ONLY so verify_skin_block_color.gd can
## drive both branches in one run without sed-toggling the compile-time flag — the SAME idiom
## FarPalette._biome_tints(unified: bool) already established for FP_FAR_COLOR_UNIFIED's gate.
static func skin_color_at(fid: int, lx: int, lz: int, g: int, biome: int, t: float, on := CubeSphere.FP_SKIN_BLOCK_COLOR) -> Color:
	if on:
		var top_id := TerrainConfig.top_block_id(g, biome, t, lx, lz)
		return color_for_block(top_id)
	return color_for(g, biome, t, g < TerrainConfig.SEA_LEVEL)

## As `skin_color_at`, for callers that only have a world-space sample point (`wx,wy,wz`, any point on the sample
## ray at radius ~R_BLOCKS — a planar bilerp's bx,by,bz, or a welded direction's d*R) instead of an integer
## lattice column. The taiga-podzol hash speckle (`_biome_top`'s only per-column dependency) needs a
## representative (x,z), not sub-block precision, so the round-trip through FacetAtlas.world_to_lattice64 (the
## SAME inverse-lattice tool facet_tex_baker.gd already uses for its fine-map bake) is exact enough.
static func skin_color(fid: int, wx: float, wy: float, wz: float, g: int, biome: int, t: float, on := CubeSphere.FP_SKIN_BLOCK_COLOR) -> Color:
	if not on:
		return color_for(g, biome, t, g < TerrainConfig.SEA_LEVEL)
	var l := FacetAtlas.world_to_lattice64(fid, wx, wy, wz)
	return skin_color_at(fid, int(round(l[0])), int(round(l[2])), g, biome, t, on)

## The whole block_id → far-palette-index LUT (== _block_idx). FP_CPP_TILE_BAKE hands this frozen to the C++
## generator (config "deco_far_idx") so bake_far_tile's tree branch resolves a decoration id → palette index in C++
## with zero GDScript, byte-equal to far_color_index_of_block. Built main-thread by ensure_far_index_ready.
static func far_index_lut() -> PackedInt32Array:
	ensure_far_index_ready()
	return _block_idx

## COSMOS-LOD-SKY M2 (docs/COSMOS-LOD-SKY-DESIGN.md §3) — the airless Moon far-ring palette, generalized per
## body exactly like the Earth colours above: every RGB is a BlockCatalog tint (regolith / basalt maria /
## anorthosite highlands), so a recolour follows by construction. The surface is a regolith blanket over the
## host rock, so each vertex reads as regolith tinted toward its host: maria darker (toward basalt), highlands
## brighter (toward anorthosite). Resolved once, lazily; the moon materials are registered only under MULTI_BODY,
## so this is called only from the Moon ring (FP_MOON_RING) and never perturbs the Earth palette above.
static var _moon_ready := false
static var _regolith: Color
static var _basalt: Color
static var _anorthosite: Color
static func ensure_moon_ready() -> void:
	if _moon_ready:
		return
	BlockCatalog.ensure_moon_materials()
	_regolith = BlockCatalog.color_of(BlockCatalog.id_of(&"regolith"))
	_basalt = BlockCatalog.color_of(BlockCatalog.id_of(&"basalt"))
	_anorthosite = BlockCatalog.color_of(BlockCatalog.id_of(&"anorthosite"))
	_moon_ready = true

## The per-vertex Moon far-ring colour for a moon biome (B_MOON_MARIA / _HIGHLANDS / _POLAR). Regolith blended
## toward the host rock: maria toward dark basalt, highlands (and the polar hook, routed as highlands v1) toward
## bright anorthosite — a desaturated grey scale that matches the near voxel world's regolith/basalt/anorthosite.
static func moon_color_for(biome: int) -> Color:
	ensure_moon_ready()
	# COSMOS-TREE-BUGS Bug 1 fix: routed through moon_biome_id (not the raw B_MOON_MARIA const) so this still
	# matches the ids TerrainConfig actually emits under FP_BIOME_SPACE_FIX (11 off / 21 on). Byte-identical off.
	if biome == TerrainConfig.moon_biome_id(0):
		return _regolith.lerp(_basalt, 0.55)      # dark maria plains
	return _regolith.lerp(_anorthosite, 0.45)     # bright highlands / polar

## COSMOS TEXTURED-LOD T1b (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2R.1) — the SINGLE material-classifier for the far
## detail (FP_BLOCK_DETAIL). The 12 detail PATTERNS the id_map indexes (a block-face tile in FacetDetailAtlas). Kept
## HERE (not in the atlas) so the id a texel gets and the colour a texel gets both derive from the one FarPalette
## palette — a recolour cannot make id and colour disagree. Stored id = pattern + 1 (0 reserved for un-baked).
const P_GRASS := 0
const P_STONE := 1
const P_SAND := 2
const P_SNOW := 3
const P_DIRT := 4
const P_LEAF := 5
const P_GRAVEL := 6
const P_MUD := 7
const P_ICE := 8
const P_JUNGLE := 9
const P_WATER := 10
const P_LAVA := 11
const DETAIL_PATTERNS := 12

static var _detail_ready := false
static var _detail_rgb := PackedFloat32Array()     # classifier keys FLATTENED (r,g,b triples) — hot-loop friendly
static var _detail_pat := PackedInt32Array()       # parallel: the pattern each key maps to

## Resolve the classifier table once (idempotent). Each entry maps a palette colour → the block-face pattern that
## SHARES its texture in the near atlas; the tint (which distinguishes taiga/savanna/grass, red_sand/sand, …) rides
## the colour page, so several palette colours can share one pattern texture without losing their hue on screen. The
## keys are stored as flat floats so the per-texel bake classify (thousands/facet) has no Color-object overhead.
static func ensure_detail_ready() -> void:
	if _detail_ready:
		return
	ensure_ready()
	var keys := [
		[_grass, P_GRASS], [_taiga, P_GRASS], [_savanna, P_GRASS], [_forest, P_LEAF], [_jungle, P_JUNGLE],
		[_snow, P_SNOW], [_sand, P_SAND], [_red_sand, P_SAND], [_gravel, P_GRAVEL], [_mud, P_MUD],
		[_podzol, P_DIRT], [_leaf, P_LEAF], [_stone, P_STONE], [_water, P_WATER], [_ice, P_ICE], [_lava, P_LAVA],
	]
	_detail_rgb.resize(keys.size() * 3)
	_detail_pat.resize(keys.size())
	for i in range(keys.size()):
		var pc: Color = keys[i][0]
		_detail_rgb[i * 3] = pc.r; _detail_rgb[i * 3 + 1] = pc.g; _detail_rgb[i * 3 + 2] = pc.b
		_detail_pat[i] = keys[i][1]
	_detail_ready = true

## Classify a baked (top-block) colour to its detail PATTERN (0..DETAIL_PATTERNS-1) by nearest palette key. color_for
## returns EXACTLY one of these palette colours for a fine texel, so an interior texel classifies to its true material
## exactly; a box-averaged boundary texel picks the nearer of the two (the disclosed 1-texel shore transition, §2R.6 D4).
static func detail_pattern(c: Color) -> int:
	if not _detail_ready:
		ensure_detail_ready()
	var cr := c.r; var cg := c.g; var cb := c.b
	var best := P_GRASS
	var best_d := 1.0e30
	var n := _detail_pat.size()
	for i in range(n):
		var j := i * 3
		var dr := cr - _detail_rgb[j]; var dg := cg - _detail_rgb[j + 1]; var db := cb - _detail_rgb[j + 2]
		var d := dr * dr + dg * dg + db * db
		if d < best_d:
			best_d = d; best = _detail_pat[i]
	return best

## THE per-vertex colour (LOD-DESIGN §2.3). A clamped sea vertex takes the sea regime
## colour; a dry-land vertex above the freeze line whitens (the altitude snow line — the
## exact ClimateModel.surface_temperature < 0 predicate worldgen stamps caps with, gated
## on g >= SEA_LEVEL to match _with_snow_state's underwater guard); otherwise the biome base.
static func color_for(g: int, biome: int, t: float, clamped_sea: bool) -> Color:
	ensure_ready()
	if clamped_sea:
		return sea_color(t)
	if g >= TerrainConfig.SEA_LEVEL and ClimateModel.surface_temperature(g, t) < 0.0:
		return _snow
	return biome_base(biome, t)
