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
static func ensure_ready() -> void:
	if _ready:
		return
	BlockCatalog.ensure_ready()
	_water = BlockCatalog.color_of(BlockCatalog.id_of(&"water"))
	_ice = BlockCatalog.color_of(BlockCatalog.id_of(&"ice"))
	_lava = BlockCatalog.color_of(BlockCatalog.id_of(&"lava"))
	_snow = BlockCatalog.color_of(BlockCatalog.id_of(&"snow_block"))
	_sand = BlockCatalog.color_of(BlockCatalog.id_of(&"sand"))
	_gravel = BlockCatalog.color_of(BlockCatalog.id_of(&"gravel"))
	_red_sand = BlockCatalog.color_of(BlockCatalog.id_of(&"red_sand"))
	_mud = BlockCatalog.color_of(BlockCatalog.id_of(&"mud"))
	_podzol = BlockCatalog.color_of(BlockCatalog.id_of(&"podzol"))
	_grass = BlockCatalog.color_of(BlockCatalog.GRASS)
	_leaf = BlockCatalog.color_of(BlockCatalog.LEAF)
	_stone = BlockCatalog.color_of(BlockCatalog.STONE)
	# Deterministic biome-mean tints (LOD-DESIGN §2.3.3): TAIGA is the 20% podzol / 80%
	# grass mean of _biome_top's hash; FOREST tints grass toward leaf to stand in for the
	# canopy the far field cannot draw as individual trees.
	_taiga = _grass.lerp(_podzol, 0.20)
	_forest = _grass.lerp(_leaf, 0.35)
	# B1 climate-biome bands (design §6.5): savanna reads as tan dry grassland (grass toward sand),
	# jungle as a deep saturated green (grass toward jungle_leaves). Both derive from catalog tints so
	# they follow a recolour, exactly like every other far colour. Shown on the GDScript far path; the
	# C++ skin path (frozen_colors, 14 entries) maps them to grass via its default until the enum extends.
	_savanna = _grass.lerp(_sand, 0.40)
	_jungle = _grass.lerp(BlockCatalog.color_of(BlockCatalog.id_of(&"jungle_leaves")), 0.55)
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
	if biome == TerrainConfig.B_MOON_MARIA:
		return _regolith.lerp(_basalt, 0.55)      # dark maria plains
	return _regolith.lerp(_anorthosite, 0.45)     # bright highlands / polar

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
