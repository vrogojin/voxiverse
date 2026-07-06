class_name TerrainConfig
extends RefCounted
## Single source of truth for the world's shape (WORLDGEN-CATALOG §6, the
## Minecraft-adapted worldgen pipeline).
##
## Both the pure-GDScript fallback mesher AND the godot_voxel module generator
## build the terrain from these functions, and the per-voxel environment model
## and the player's analytic ground/ray logic sample the same functions. This is
## what keeps "the world" one concept regardless of which rendering path runs.
##
## SINGLE SOURCE OF TRUTH (WGC §7.2): the pipeline lives entirely in this file.
## The module generator does NOT re-implement any of it — it caches one
## `column_profile()` (a value-type Vector4, no allocation) per column and calls
## `resolve_cell()` per cell, the exact same functions `generated_cell()` uses.
## Both render paths therefore agree by construction; there is no second copy of
## the logic that could drift.
##
## Convention: 1 voxel = 1 metre. `height_at(x,z)` is the y of the topmost SOLID
## ground cell `g` (water/ice sit ABOVE it, up to SEA_LEVEL). The world is a pure
## heightmap above bedrock — no 3D caves/overhangs (WGC §6.8 staged decision: we
## stay heightmap-only so the analytic, collider-less player physics stays sound;
## the player can never fall through the world). Below y = WORLD_BOTTOM_Y is void,
## unreachable because the bedrock floor is unbreakable.
##
## DETERMINISM (WGC §7): every decision is FastNoiseLite with a const seed derived
## from SEED + a documented salt, or a hash-of-position (`_hash01_3d`). No
## randi()/randf(), no per-run state. Intra-process agreement (module generator vs
## analytic queries vs collapse) is exact — same functions, same binary.

const SEED := 20260702

## DIAGNOSTIC A/B TOGGLE (SUB-VOXEL-SMOOTHING). When false, terrain smoothing is fully OFF:
## the surface cell is a plain FULL cube (no ramp/slab reshape), no grass CAP lip grows, and the
## appearance manifest bakes ZERO shaped models — the world is cube-only like pre-P5. Flip to false
## to disable smoothing (a genuine one-line change; no smoothing math is altered, only gated).
## Now ON: the smoothing "jerkiness" was NOT the renderer (measured identical to cubes) but the
## analytic main-thread queries recomputing the 9-height_at corner stencil per surface/cap probe;
## the per-column shape memo below (_shape_entry) makes that ~free, so smoothing is cheap again.
const SMOOTHING_ENABLED := true

# --- vertical structure (WGC §6.1, our scale) ---------------------------------
const WORLD_BOTTOM_Y := -64      # world floor; below is void (unreachable)
const BEDROCK_TOP_Y := -59       # bedrock gradient: 100% at -64 -> 0% at -59
const DEEPSLATE_FULL_Y := -24    # below here: always deepslate
const DEEPSLATE_TOP_Y := -16     # above here: always stone; dithered band between
const SEA_LEVEL := 0             # air below SEA_LEVEL fills with liquid (ice cap when cold, lava when hot)

## Climate regime thresholds for the sea fill (MULTI-LIQUID §2.4). Frozen (t < -0.55) → ice cap;
## molten (t >= LAVA_SEA_T) → the sea fill IS lava; temperate in between → water. Frozen and molten
## are DISJOINT bands, so _sea_liquid_kind (the single regime authority) never has to reconcile them.
const LAVA_SEA_T := 0.60         # extreme-hot ocean regions: the sea fill IS lava (molten seas)

## The render height of the water surface: the top cell of every open-water column and every
## smoothed shore composite renders its water at SEA_LEVEL + WATER_SURFACE_HEIGHT, a slightly sunk
## surface rather than a full cube. Set to 0.9375 = godot_voxel's native fluid TOP_HEIGHT
## (blocky_baked_library.h) so the LEGACY GDScript fallback water plane and the NATIVE-waterlogging
## fluid surface (WATERLOGGING.md §4.7) sit at the SAME height. Still rounds to
## CellCodec.LIQ_LEVEL_SURFACE=9 tenths (roundi(0.9375*10)=9), the water-line level pinned by verify.
const WATER_SURFACE_HEIGHT := 0.9375

# --- gentle, shallow base hills (unchanged; the c~0 plains preserve today's look)
const BASE_HEIGHT := 5.0        # average ground height at the coast/plains
const HILLS_AMPLITUDE := 3.0    # shallow rolling hills (open, walkable)
const DETAIL_AMPLITUDE := 1.0   # small-scale bumpiness on top

# --- beach shelf (WATER-SHORE follow-up): a smooth near-shore seafloor gradient -----------------
# Across a shallow window around the water line, _height_c fades out the high-frequency surface
# noise so the near-shore floor follows the gentle continental slope — a smooth shallow shelf the
# surface+cap smoothing grades into a continuous descent — instead of noisy >1-block steps that
# saturate the half-block corner codec. Zero on inland land and in deep water (both byte-identical).
const SHELF_TOP := 1.0          # blend begins 1 block ABOVE the water line (includes the beach)
const SHELF_DEPTH := 5.0        # ...and fades back out by 5 blocks BELOW it (deep water untouched)
const SHELF_HILLS_KEEP := 0.35  # fraction of the low-frequency hills kept in the shelf (soft texture)

## Render radius around the player, in blocks (DESIGN §1). Drives the fallback
## chunk radius and the fog reference distance.
const RENDER_RADIUS_BLOCKS := 256

## The godot_voxel viewer streams a vertically-scaled sphere: the vertical view radius is
## VIEWER_VERTICAL_RATIO * view_distance (RENDER_RADIUS_BLOCKS). The world content is only
## ~94 blocks tall (bedrock y=-64 .. treetops ~y=30), so a 1.0 ratio streamed a ±256 vertical
## sphere that is mostly empty air — thousands of blocks each paying the per-column profile pass
## on the single (web-capped) voxel thread. 0.2 limits streaming to a ~±51-block slab around the
## viewer, deferring the deep subsurface until the player descends. PURE CONFIG: a block streams
## identically whenever it DOES stream (only WHEN it streams changes), so determinism and the
## generated output are unaffected; analytic physics + the collider read TerrainConfig directly
## (not the mesh), so collision below the streamed slab is unchanged.
const VIEWER_VERTICAL_RATIO := 0.2

## PROVEN upper bound on height_at(x,z) over the whole (infinite) domain — the module generator
## uses it to CHEAPLY skip all-air blocks far above the terrain BEFORE the column-profile pass.
## Analytic max height_at = BASE_HEIGHT(5) + max _continent_offset(11) + HILLS_AMPLITUDE(3) +
## DETAIL_AMPLITUDE(1) = 20 (each FastNoiseLite term is bounded to [-1,1]; Godot normalizes FBM),
## + 4 margin. A large-sample assert in verify_feature confirms the bound so the early-out can
## NEVER skip real content (a too-low bound would punch holes in the world).
const MAX_SURFACE_Y := 24

## The world floor: the lowest SOLID cell is bedrock at y = WORLD_BOTTOM_Y; y < WORLD_BOTTOM_Y is
## void (air). A block whose whole extent is below this generates nothing (generator skips it).
const BEDROCK_FLOOR := WORLD_BOTTOM_Y

## Chunk edge length in voxels for the fallback streamer.
const CHUNK_SIZE := 32

# --- biomes (WGC §6.4) --------------------------------------------------------
# Plain int consts (not an enum) so the runtime-compiled module generator and
# TreeGen can reference TerrainConfig.B_* directly.
const B_OCEAN := 0
const B_BEACH := 1
const B_BADLANDS := 2
const B_DESERT := 3
const B_SWAMP := 4
const B_SNOWY := 5
const B_TAIGA := 6
const B_FOREST := 7
const B_PLAINS := 8

# --- salt registry (WGC §7.1 — one place, no collisions) ----------------------
# TreeGen owns 11/22/33/44/55/66/88. TerrainConfig owns 101-103 (noise seeds) and
# the 7xx hashing salts below.
const _SALT_BEDROCK := 701
const _SALT_DEEP := 702
const _SALT_STRATA_EXIST := 711
const _SALT_STRATA_JX := 712
const _SALT_STRATA_JY := 713
const _SALT_STRATA_JZ := 714
const _SALT_STRATA_VAR := 715
const _SALT_STRATA_R := 716
const _SALT_ORE_EXIST := 721
const _SALT_ORE_JX := 722
const _SALT_ORE_JY := 723
const _SALT_ORE_JZ := 724
const _SALT_ORE_PICK := 725
const _SALT_ORE_R := 726
const _SALT_BAND := 731
const _SALT_PODZOL := 741

# --- ore depth table (WGC §6.6; y-range/peak/weight, triangle distributions) ---
# index: 0 coal, 1 copper, 2 iron, 3 gold, 4 redstone, 5 lapis, 6 diamond, 7 emerald
const _ORE_YMIN := [-8, -16, -56, -60, -64, -52, -64, -8]
const _ORE_YMAX := [16, 12, 12, -8, -24, -6, -40, 16]
const _ORE_PEAK := [8, 4, -8, -32, -56, -28, -58, 12]
const _ORE_WEIGHT := [30.0, 25.0, 25.0, 10.0, 14.0, 8.0, 6.0, 3.0]
const _ORE_EMERALD := 7           # emerald ore index in the table
const _ORE_GOLD := 3              # gold ore index in the table

const _STRATA_L := 16            # strata lattice cell size (WGC §6.5)
const _ORE_L := 6                # ore-attempt lattice cell size (WGC §6.6)

# --- lazily-built noise stack shared by every consumer ------------------------
static var _hills: FastNoiseLite       # gentle base terrain
static var _detail: FastNoiseLite      # small-scale bumpiness
static var _continent: FastNoiseLite   # continentalness (ocean <-> inland)
static var _temperature: FastNoiseLite # climate temperature
static var _humidity: FastNoiseLite    # climate humidity

# --- cached material ids (resolved once from the data-driven catalog) ---------
static var _ids_ready := false
static var _ID_BEDROCK := 0
static var _ID_DEEPSLATE := 0
static var _ID_WATER := 0
static var _ID_LAVA := 0
static var _ID_ICE := 0
static var _ID_SAND := 0
static var _ID_RED_SAND := 0
static var _ID_GRAVEL := 0
static var _ID_SANDSTONE := 0
static var _ID_RED_SANDSTONE := 0
static var _ID_SNOW := 0
static var _ID_MUD := 0
static var _ID_PODZOL := 0
static var _ID_SULFUR := 0
static var _ID_CINNABAR := 0
static var _STRATA_SEQ: Array[int] = []   # granite,diorite,andesite,tuff,calcite,dripstone
static var _BAND_SEQ: Array[int] = []      # 7 terracotta ids (badlands strata)
static var _ORE_STONE: Array[int] = []     # ids 18..25
static var _ORE_DEEP: Array[int] = []      # ids 26..33

# ------------------------------------------------------------------------------
# Warm-up + lazy init (WGC §7.4 — MUST run on the main thread before the voxel
# worker thread generates, or a lazily-built singleton is a data race).

static func _ensure_noise() -> void:
	if _hills != null:
		return
	_hills = FastNoiseLite.new()
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hills.seed = SEED
	_hills.frequency = 0.008
	_hills.fractal_type = FastNoiseLite.FRACTAL_FBM
	_hills.fractal_octaves = 3
	_hills.fractal_gain = 0.5

	_detail = FastNoiseLite.new()
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail.seed = SEED + 7919
	_detail.frequency = 0.05

	# Three low-frequency climate/shape noises (WGC §6.4).
	_continent = _make_climate(SEED + 101, 0.0015)
	_temperature = _make_climate(SEED + 102, 0.002)
	_humidity = _make_climate(SEED + 103, 0.002)

static func _make_climate(sd: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = sd
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 2
	n.fractal_gain = 0.5
	return n

## Resolve every material id the generator can emit, once, from the catalog.
static func _ensure_ids() -> void:
	if _ids_ready:
		return
	BlockCatalog.ensure_ready()
	_ID_BEDROCK = BlockCatalog.id_of(&"bedrock")
	_ID_DEEPSLATE = BlockCatalog.id_of(&"deepslate")
	_ID_WATER = BlockCatalog.id_of(&"water")
	_ID_LAVA = BlockCatalog.id_of(&"lava")
	_ID_ICE = BlockCatalog.id_of(&"ice")
	_ID_SAND = BlockCatalog.id_of(&"sand")
	_ID_RED_SAND = BlockCatalog.id_of(&"red_sand")
	_ID_GRAVEL = BlockCatalog.id_of(&"gravel")
	_ID_SANDSTONE = BlockCatalog.id_of(&"sandstone")
	_ID_RED_SANDSTONE = BlockCatalog.id_of(&"red_sandstone")
	_ID_SNOW = BlockCatalog.id_of(&"snow_block")
	_ID_MUD = BlockCatalog.id_of(&"mud")
	_ID_PODZOL = BlockCatalog.id_of(&"podzol")
	_ID_SULFUR = BlockCatalog.id_of(&"sulfur_block")
	_ID_CINNABAR = BlockCatalog.id_of(&"cinnabar_block")
	_STRATA_SEQ = [
		BlockCatalog.id_of(&"granite"), BlockCatalog.id_of(&"diorite"),
		BlockCatalog.id_of(&"andesite"), BlockCatalog.id_of(&"tuff"),
		BlockCatalog.id_of(&"calcite"), BlockCatalog.id_of(&"dripstone_block"),
	]
	_BAND_SEQ = [
		BlockCatalog.id_of(&"terracotta"), BlockCatalog.id_of(&"white_terracotta"),
		BlockCatalog.id_of(&"orange_terracotta"), BlockCatalog.id_of(&"yellow_terracotta"),
		BlockCatalog.id_of(&"brown_terracotta"), BlockCatalog.id_of(&"red_terracotta"),
		BlockCatalog.id_of(&"light_gray_terracotta"),
	]
	# Ore ids are contiguous: stone hosts 18..25, deepslate hosts 26..33, both in
	# the coal/copper/iron/gold/redstone/lapis/diamond/emerald order of the table.
	_ORE_STONE = [
		BlockCatalog.id_of(&"coal_ore"), BlockCatalog.id_of(&"copper_ore"),
		BlockCatalog.id_of(&"iron_ore"), BlockCatalog.id_of(&"gold_ore"),
		BlockCatalog.id_of(&"redstone_ore"), BlockCatalog.id_of(&"lapis_ore"),
		BlockCatalog.id_of(&"diamond_ore"), BlockCatalog.id_of(&"emerald_ore"),
	]
	_ORE_DEEP = [
		BlockCatalog.id_of(&"deepslate_coal_ore"), BlockCatalog.id_of(&"deepslate_copper_ore"),
		BlockCatalog.id_of(&"deepslate_iron_ore"), BlockCatalog.id_of(&"deepslate_gold_ore"),
		BlockCatalog.id_of(&"deepslate_redstone_ore"), BlockCatalog.id_of(&"deepslate_lapis_ore"),
		BlockCatalog.id_of(&"deepslate_diamond_ore"), BlockCatalog.id_of(&"deepslate_emerald_ore"),
	]
	_ids_ready = true

## Warm EVERY lazy singleton on the calling (main) thread (WGC §7.4). module_world
## calls this before creating the terrain so the voxel worker thread never races a
## half-built noise/id/species table into existence.
static func warm_up() -> void:
	_ensure_noise()
	_ensure_ids()
	TreeGen.warm_up()

## Deterministic hash in [0,1) for an integer lattice + salt (3D form of the
## TreeGen._hash01 integer-mix family; no floats until the final divide).
static func _hash01_3d(ix: int, iy: int, iz: int, salt: int) -> float:
	var n := (ix * 374761393 + iy * 668265263 + iz * 2246822519 + salt * 362437) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65536.0

# ------------------------------------------------------------------------------
# Stage 1-2: continent spline height + biome selection.

## Continentalness noise at (x, z), roughly [-1, 1] (ocean <-> inland).
static func continent_at(x: int, z: int) -> float:
	_ensure_noise()
	return _continent.get_noise_2d(float(x), float(z))

## Continental height offset via the 4-knot spline (WGC §6.4). Plains (c ~ 0) map
## to offset ~0 so the c~0 world is a subset of today's demo terrain.
static func _continent_offset(c: float) -> float:
	if c <= -1.0:
		return -14.0
	if c < -0.45:
		return _knot(c, -1.0, -0.45, -14.0, -6.0)
	if c < -0.15:
		return _knot(c, -0.45, -0.15, -6.0, 0.0)
	if c < 0.4:
		return _knot(c, -0.15, 0.4, 0.0, 2.0)
	if c < 1.0:
		return _knot(c, 0.4, 1.0, 2.0, 11.0)
	return 11.0

static func _knot(c: float, c0: float, c1: float, v0: float, v1: float) -> float:
	return v0 + (v1 - v0) * (c - c0) / (c1 - c0)

static func _height_c(c: float, fx: float, fz: float) -> int:
	var base := BASE_HEIGHT + _continent_offset(c)
	var hills := _hills.get_noise_2d(fx, fz) * HILLS_AMPLITUDE
	var h := base + hills + _detail.get_noise_2d(fx, fz) * DETAIL_AMPLITUDE
	# Beach shelf (WATER-SHORE follow-up, see the SHELF_* consts): a smooth window around the water
	# line blends the noisy height toward the gentle continental slope (base + a little hills, no
	# detail), so the near-shore seafloor descends smoothly instead of in noisy >1-block steps the
	# corner-height smoothing can't grade. `w` is a smooth bump: 0 on inland land (depth < -SHELF_TOP)
	# AND in deep water (depth > SHELF_DEPTH) — both stay BYTE-IDENTICAL — peaking in the shallow band
	# between. PURE/DETERMINISTIC: a smooth function of the same noise + position (no randi/Time).
	var depth := float(SEA_LEVEL) - h
	var w := clampf(smoothstep(-SHELF_TOP, 0.5, depth) - smoothstep(SHELF_DEPTH - 1.5, SHELF_DEPTH, depth), 0.0, 1.0)
	if w > 0.0:
		h = lerp(h, base + hills * SHELF_HILLS_KEEP, w)
	return int(floor(h))

## Surface height (integer y of the topmost SOLID ground cell) at column (x, z).
## Water/ice sit ABOVE this, up to SEA_LEVEL. UNCHANGED contract for every caller
## (PerVoxelEnvironment depth model, effective_height, floor scans, TreeGen).
static func height_at(x: int, z: int) -> int:
	_ensure_noise()
	var fx := float(x)
	var fz := float(z)
	return _height_c(_continent.get_noise_2d(fx, fz), fx, fz)

## Biome enum (B_*) at column (x, z) — ordered first-match rule chain (WGC §6.4).
static func _biome(c: float, t: float, h: float, g: int) -> int:
	if c < -0.32:
		return B_OCEAN
	# Beaches ring the coast: near sea level AND continentally coastal (the c gate
	# keeps inland lowland dips from speckling as sand — WGC §9 noise-smoothness).
	if c < 0.25 and g >= SEA_LEVEL - 2 and g <= SEA_LEVEL + 2:
		return B_BEACH
	if t > 0.45 and h < -0.45:
		return B_BADLANDS
	if t > 0.45 and h < 0.0:
		return B_DESERT
	if t > 0.15 and h > 0.5:
		return B_SWAMP
	if t < -0.55:
		return B_SNOWY
	if t < -0.15:
		return B_TAIGA
	if h > 0.1:
		return B_FOREST
	return B_PLAINS

## Biome enum at column (x, z). Public: TreeGen (species) and PerVoxelEnvironment
## (surface temperature) key off it. `pcache` (optional) is the shared per-pass column
## memo (see column_profile) so a hot caller — the collider, the module worker — resolves
## the biome without re-running the climate noises.
static func biome_at(x: int, z: int, pcache = null) -> int:
	return int(column_profile(x, z, pcache).y)

## The per-column profile every downstream stage needs, as a VALUE-TYPE Vector4
## (no heap allocation, so it is cheap to cache per column in the module
## generator): (g = solid height, biome enum, c = continentalness, t = temperature).
## `pcache` (optional): a per-pass memo (Dictionary Vector2i -> Vector4) owned by ONE
## caller's stack frame (a module worker's _generate_block, a collider rebuild) — never
## shared across threads. It only avoids RE-running the (continent/temperature/humidity +
## height) noise stack for a column already resolved this pass; the returned value is
## exactly the uncached column_profile, so worldgen output stays byte-identical and
## deterministic. Non-null -> memoize; null -> compute directly (the analytic path).
static func column_profile(x: int, z: int, pcache = null) -> Vector4:
	if pcache != null:
		var ck := Vector2i(x, z)
		if pcache.has(ck):
			return pcache[ck]
	_ensure_noise()
	var fx := float(x)
	var fz := float(z)
	var c := _continent.get_noise_2d(fx, fz)
	var t := _temperature.get_noise_2d(fx, fz)
	var hh := _humidity.get_noise_2d(fx, fz)
	var g := _height_c(c, fx, fz)
	var prof := Vector4(float(g), float(_biome(c, t, hh, g)), c, t)
	if pcache != null:
		pcache[Vector2i(x, z)] = prof
	return prof

# ------------------------------------------------------------------------------
# The composed cell function (WGC §6.2). generated_cell derives the column
# profile then delegates to resolve_cell; the module generator caches the profile
# and calls resolve_cell directly. Both go through the SAME resolve_cell.

## Pure generation (no edits): the PACKED cell value the WORLD GENERATOR puts at
## (x,y,z) — VOXEL-DATA-STRUCTURE §7.1 tier 2. THE terrain function.
static func generated_cell(x: int, y: int, z: int) -> int:
	var p := column_profile(x, z)
	return resolve_cell(x, y, z, int(p.x), int(p.y), p.z, p.w)

## The per-cell pipeline given a column's precomputed profile scalars (g, biome,
## c, t). Returns the PACKED cell value (== bare material id today; sub-voxel adds
## modifiers later). This is the single hot function both render paths share.
static func resolve_cell(x: int, y: int, z: int, g: int, biome: int, c: float, t: float, pcache = null) -> int:
	if not _ids_ready:
		_ensure_ids()
	if y < WORLD_BOTTOM_Y:
		return BlockCatalog.AIR
	if _bedrock_at(x, y, z):
		return _ID_BEDROCK
	if y > g:
		# Smoothing CAP cell (SUB-VOXEL-SMOOTHING §8.1): a column whose neighbours rise grows a
		# partial lip one cell above its surface, bridging a 1-block step up into a continuous slope.
		# WATER-SHORE §3.6: underwater caps are now ON — a submerged step descends smoothly over
		# multiple cells instead of ending in an abrupt half-block ledge. An underwater cap is the
		# UNDERWATER-FLOOR material (via _surface_cap) and fills its remainder with liquid through
		# _with_shore_liquid (level 9 exactly at the water line, level 10 below). A LAND cap
		# (g >= SEA_LEVEL ⇒ y = g+1 > SEA_LEVEL) is a NO-OP under _with_shore_liquid (its y > SEA_LEVEL
		# guard), so land caps stay byte-identical. Returns AIR (falls through) when no cap grows here.
		if y == g + 1:
			var cap := _surface_cap(x, z, g, biome, t, pcache)
			if cap != BlockCatalog.AIR:
				return _with_shore_liquid(cap, y, t)
		# Above the solid ground: sea fill (g < y <= SEA_LEVEL) else the tree overlay.
		if y <= SEA_LEVEL:
			return _sea_block(t, y)
		return TreeGen.block_at(x, y, z, pcache)
	var id := _surface_rule(x, y, z, g, biome, c, t)
	if id == BlockCatalog.STONE:
		id = _deep_family(x, y, z)      # stone -> deepslate gradient + strata blobs
		id = _ore_at(x, y, z, id, biome, c)   # host-aware ore lattice
	# Smoothing SURFACE shape (SVS §8.1): reshape the walkable top cell of a column into a
	# corner-height ramp/slab whose surface fits the four neighbouring column tops. Only the
	# MODIFIER changes — the material projection (generated_block) is untouched, so every
	# material/stackup invariant holds; cells below the surface stay solid full cubes, so the
	# analytic floor scan can never fall through. WATER-SHORE §3: the g >= SEA_LEVEL gate is
	# GONE (underwater floors smooth too), and the smoothed surface is composed with the
	# generated-liquid rule so a shore/floor cell also records the liquid filling its remainder.
	if y == g:
		return _with_shore_liquid(_smoothed_surface(x, z, g, id, pcache), y, t)
	return id

## Compose the generated-liquid rule (WATER-SHORE §3, MULTI-LIQUID §2.4) onto a SURFACE cell value:
## a cell at or below the water line whose solid surface leaves a remainder (modifier != 0) also
## holds LIQUID filling that remainder, top at 0.9 (level 9) when it IS the water line, else full
## (level 10). The liquid KIND is the column's sea regime (_sea_liquid_kind(t)), so shore AND
## submerged composites of a molten sea carry LIQ_LAVA. PURE: reads only (v, y, t). No-op above the
## water line, on a full-cube surface (no remainder), and in the frozen regime at the water line
## (ice cube / bare frozen ramp — the sheet ends crisply). Liquid strictly below the ice
## (y < SEA_LEVEL) fills as normal. Byte-identical to the water-only predecessor for t < LAVA_SEA_T.
static func _with_shore_liquid(v: int, y: int, t: float) -> int:
	if y > SEA_LEVEL or CellCodec.modifier(v) == 0:
		return v
	if y == SEA_LEVEL and t < -0.55:
		return v                                          # frozen shore: ice regime, no liquid overlay
	var lvl := CellCodec.LIQ_LEVEL_SURFACE if y == SEA_LEVEL else CellCodec.LIQ_LEVEL_FULL
	return CellCodec.with_liquid(v, _sea_liquid_kind(t), lvl)

# ------------------------------------------------------------------------------
# Deterministic terrain smoothing (SUB-VOXEL-SMOOTHING §8.1). The walkable surface
# cell — and, on a rising neighbour, a one-cell cap above it — is reshaped into a
# corner-height partial fill whose top fits the four surrounding integer column tops,
# so a 1-block stair-step reads as a continuous ramp. PURE + DETERMINISTIC: derived
# only from height_at (the integer column tops both render paths already share) and
# the TreeGen overlay — NO noise resampling, NO randi()/Time — so the module generator
# (which calls resolve_cell) and the analytic generated_cell agree by construction, and
# re-running with the same SEED yields identical modifiers. Slopes up to 1 block/cell
# smooth fully; steeper terrain saturates the {0,1,2} half-block clamp and stays blocky
# (§8 non-goal: cliffs read as cliffs).

## The four corner target heights T (world-y, in blocks) at the lattice corners of the
## cell column (x, z): (T00, T10, T11, T01) at corners (x,z),(x+1,z),(x+1,z+1),(x,z+1)
## in the ShapeCodec corner order. Each corner target is the mean of the walk-surfaces
## (height_at + 1) of the four columns meeting at that corner (SVS §8.1). Local (a 3×3
## column-top stencil), crack-free (neighbouring cells share these corner targets so the
## composed surface is C0), and IDENTICAL for both generators (only height_at is read).
## The column's SOLID surface height with the OPTIONAL per-pass memo (PERF). `pcache`, when
## non-null, is the shared column_profile memo (see column_profile) — so the smoothing
## corner-target stencil, which samples a 3x3 of column tops that overlaps its neighbours',
## reuses each column top instead of re-noising it. Returns exactly height_at(x, z) either
## way (int(column_profile.x) == height_at by construction), so worldgen output is unchanged.
## `pcache == null` -> the cheap direct height_at (the analytic path — no profile allocation).
static func _col_h(x: int, z: int, pcache) -> int:
	if pcache == null:
		return height_at(x, z)
	return int(column_profile(x, z, pcache).x)

## Public cache-aware column top for TreeGen (so its base-column height read shares the memo).
static func column_top(x: int, z: int, pcache = null) -> int:
	return _col_h(x, z, pcache)

static func _corner_targets(x: int, z: int, pcache = null) -> Vector4:
	var t_nn := float(_col_h(x - 1, z - 1, pcache) + 1)
	var t_0n := float(_col_h(x,     z - 1, pcache) + 1)
	var t_pn := float(_col_h(x + 1, z - 1, pcache) + 1)
	var t_n0 := float(_col_h(x - 1, z,     pcache) + 1)
	var t_00 := float(_col_h(x,     z,     pcache) + 1)
	var t_p0 := float(_col_h(x + 1, z,     pcache) + 1)
	var t_np := float(_col_h(x - 1, z + 1, pcache) + 1)
	var t_0p := float(_col_h(x,     z + 1, pcache) + 1)
	var t_pp := float(_col_h(x + 1, z + 1, pcache) + 1)
	return Vector4(
		(t_nn + t_0n + t_n0 + t_00) * 0.25,   # corner (x, z)
		(t_0n + t_pn + t_00 + t_p0) * 0.25,   # corner (x+1, z)
		(t_00 + t_p0 + t_0p + t_pp) * 0.25,   # corner (x+1, z+1)
		(t_n0 + t_00 + t_np + t_0p) * 0.25)   # corner (x, z+1)

## The BOTTOM-anchored corner-height modifier for a cell whose floor is at `base_y`,
## quantized to half-blocks and clamped to {0,1,2}. Returns 0 (FULL cube) when the
## surface reaches the ceiling at every corner (flat ground → byte-identical to a plain
## block) OR is cut to the floor at every corner (empty).
static func _modifier_from_targets(targets: Vector4, base_y: int) -> int:
	var by := float(base_y)
	var c00 := clampi(roundi((targets.x - by) * 2.0), 0, 2)
	var c10 := clampi(roundi((targets.y - by) * 2.0), 0, 2)
	var c11 := clampi(roundi((targets.z - by) * 2.0), 0, 2)
	var c01 := clampi(roundi((targets.w - by) * 2.0), 0, 2)
	if c00 == 2 and c10 == 2 and c11 == 2 and c01 == 2:
		return 0
	if c00 == 0 and c10 == 0 and c11 == 0 and c01 == 0:
		return 0
	return ShapeCodec.make_modifier(c00, c10, c11, c01, ShapeCodec.ANCHOR_BOTTOM)

# ------------------------------------------------------------------------------
# Per-column SHAPE MEMO (analytic-path PERF, the smoothing-jerkiness fix). The analytic queries
# (WorldManager.floor_under/blocked → cell_value_at → generated_cell, pcache == null) hit a surface
# (y==g) or cap (y==g+1) cell on nearly every probe; each recomputes the 3×3 corner-target stencil
# = 9 height_at = 27 fresh noise samples (a surface cell measured 2.9 → 13.2 µs, 4.2×). While the
# player MOVES it fires ~6 such probes per tick → ms-scale on wasm → the "smoothing stutter". This
# memo caches, per column, the (g, surface_modifier, cap_modifier) triple — PURE functions of SEED
# (immutable at runtime; player edits live in the overlay, never in generated modifiers), so it is
# byte-identical to recomputing. Packed int: (g + _MEMO_G_BIAS) | surface_mod<<16 | cap_mod<<24
# (both mods are BOTTOM corner-height codes < 256; g biased so its low 16 bits stay positive).
#
# THREAD SAFETY — READ THIS: GDScript Dictionaries are NOT thread-safe. This memo is MAIN-THREAD-
# ONLY by construction. The module voxel WORKER always calls resolve_cell/_smoothed_surface/… with
# a NON-NULL pcache (its per-block cache), so it never reaches the memo. The memo is consulted only
# when pcache == null AND the caller is the main thread; any other threaded caller lacking a pcache
# falls back to the direct (uncached, correct) compute. So no worker thread ever reads or writes
# `_shape_memo`. Do NOT remove the pcache==null + main-thread guards.
const _MEMO_G_BIAS := 512          # keeps (g + bias) positive in the packed low 16 bits (g >= -512)
const _MEMO_MAX := 262144          # ~256k columns; cleared past this to bound a marathon session
static var _shape_memo: Dictionary = {}

static func _on_main_thread() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()

## The cached packed (g, surface_mod, cap_mod) for column (x, z), computing + storing it on first
## access. MAIN-THREAD ONLY (see the memo header). surface_mod/cap_mod are the EXACT smoothing
## modifiers _smoothed_surface/_surface_cap (and surface_modifier/surface_cap_modifier) emit for
## this column — BOTH surface_mod AND cap_mod cover underwater floors (WATER-SHORE §3.3/§3.6:
## underwater caps are ON), WITH the tree-rest suppression — so any consulting query is exact.
static func _shape_entry(x: int, z: int) -> int:
	var k := Vector2i(x, z)
	var e: int = _shape_memo.get(k, -1)
	if e != -1:
		return e
	var g := height_at(x, z)
	var sm := 0
	var cm := 0
	# Smoothing on and no tree cell resting on the top → the reshape applies. WATER-SHORE §3.3/§3.6:
	# BOTH the SURFACE and the CAP modifier are now computed for underwater floors (g < SEA_LEVEL)
	# too — underwater caps are ON, so a submerged step descends smoothly over several cells rather
	# than an abrupt half-block ledge. Otherwise both modifiers stay 0 (plain cube / no cap). The
	# TreeGen probe returns AIR over ocean columns (trees are biome-gated off ocean/beach), so the
	# uniform check keeps one code path.
	if SMOOTHING_ENABLED and TreeGen.block_at(x, g + 1, z) == BlockCatalog.AIR:
		var t := _corner_targets(x, z)      # the 9-height_at stencil — computed ONCE, then cached
		sm = _modifier_from_targets(t, g)
		cm = _modifier_from_targets(t, g + 1)
	if _shape_memo.size() >= _MEMO_MAX:
		_shape_memo.clear()                 # bound memory over a marathon session
	e = (g + _MEMO_G_BIAS) | (sm << 16) | (cm << 24)
	_shape_memo[k] = e
	return e

## The packed SURFACE cell value at (x, g, z): the biome-top material `mat` reshaped by
## the smoothing modifier, or the plain material when flat OR under a tree base (a tree
## cell resting on the surface forces it FULL so trunks never float on a ramp corner —
## SVS §8.1 tree exception).
static func _smoothed_surface(x: int, z: int, g: int, mat: int, pcache = null) -> int:
	if not SMOOTHING_ENABLED:
		return mat                                    # diagnostic: cube-only surface
	# Analytic main-thread path (pcache == null): the cached surface modifier avoids the 9-height_at
	# corner stencil. The worker (pcache != null) and any other thread fall through to direct compute.
	if pcache == null and _on_main_thread():
		var sm := (_shape_entry(x, z) >> 16) & 0xFF
		return mat if sm == 0 else CellCodec.pack(mat, sm)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return mat                                    # a tree cell rests here → keep FULL
	var m := _modifier_from_targets(_corner_targets(x, z, pcache), g)
	if m == 0:
		return mat
	return CellCodec.pack(mat, m)

## The packed CAP cell value at (x, g+1, z), or AIR (0) when no cap grows here (flat
## ground, a >1-block cliff that saturates to a full block, or a tree cell owning the
## cell). The cap is the column's surface material (biome top on land, underwater-floor material
## when submerged — WATER-SHORE §3.6), shaped by the SAME corner targets as the surface cell below
## it, so the two form one crack-free continuous slope. Above the water line _with_shore_liquid (in
## resolve_cell) is a no-op, so land caps stay byte-identical; underwater it fills the remainder
## with the sea's liquid (level 9 at the water line, 10 below).
static func _surface_cap(x: int, z: int, g: int, biome: int, t: float, pcache = null) -> int:
	if not SMOOTHING_ENABLED:
		return BlockCatalog.AIR                       # diagnostic: no cap cells
	if pcache == null and _on_main_thread():
		var cm := (_shape_entry(x, z) >> 24) & 0xFF
		return BlockCatalog.AIR if cm == 0 else CellCodec.pack(_cap_material(biome, x, z, t, g), cm)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return BlockCatalog.AIR                       # tree overlay owns this cell
	var m := _modifier_from_targets(_corner_targets(x, z, pcache), g + 1)
	if m == 0:
		return BlockCatalog.AIR                       # no lip (flat) or a full-block step (kept blocky)
	return CellCodec.pack(_cap_material(biome, x, z, t, g), m)

## The cap cell's MATERIAL. A LAND cap (g >= SEA_LEVEL, so the cap cell y=g+1 sits above the water
## line) is the column's biome top; an UNDERWATER cap (g < SEA_LEVEL) is the underwater-floor
## material of the surface cell below it, so a submerged descending slope reads as one continuous
## seafloor (WATER-SHORE §3.6 — underwater caps ON).
static func _cap_material(biome: int, x: int, z: int, t: float, g: int) -> int:
	return _biome_top(biome, x, z) if g >= SEA_LEVEL else _underwater_floor(biome, x, z, t)

# ------------------------------------------------------------------------------
# LIGHT collider queries (PERF, GroundCollider freeze fix). The ground collider needs,
# per surface cell, ONLY the smoothing SHAPE (modifier) — never the material, ores,
# strata, biome or deepslate gradient. These reproduce the smoothing modifier of the
# top (and cap) cell WITHOUT running the ~12x-heavier generated_cell/resolve_cell
# pipeline: they touch only height_at (via the shared corner-target stencil) and the
# TreeGen overlay hash. By construction each equals CellCodec.modifier(generated_cell(...))
# at that cell (proven in verify_feature._test_collider_cheap_queries), so collision
# geometry stays byte-identical while a rebuild makes ZERO generated_cell calls.
# `hcache` (optional) is the same per-pass height memo _corner_targets uses.

## The smoothing MODIFIER of the SURFACE cell at (x, height_at(x,z), z). Equals
## CellCodec.modifier(generated_cell(x, height_at(x,z), z)) — the exact shape _smoothed_surface
## would emit for the top cell (0 == FULL cube: a tree-owned top or flat/steep ground; nonzero ==
## a ramp/slab). WATER-SHORE §3.4: underwater floors (g < SEA_LEVEL) now smooth too, so this has
## no sea-level gate — both this direct branch and the memo agree over water. No material/biome/
## strata/ore branches are evaluated.
static func surface_modifier(x: int, z: int, pcache = null) -> int:
	if not SMOOTHING_ENABLED:
		return 0                                      # diagnostic: cube-only surface
	if pcache == null and _on_main_thread():
		return (_shape_entry(x, z) >> 16) & 0xFF
	var g := _col_h(x, z, pcache)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return 0                                      # a tree cell rests on the top → kept FULL
	return _modifier_from_targets(_corner_targets(x, z, pcache), g)

## The smoothing MODIFIER of the CAP cell at (x, height_at(x,z)+1, z), or 0 when no cap
## grows here (flat/steep or tree-owned). Equals
## CellCodec.modifier(generated_cell(x, height_at(x,z)+1, z)) — when nonzero the cap's material is a
## non-air surface material (biome top on land, underwater-floor material when submerged), so the
## collider needs only this modifier (nonzero → shaped prism cell; 0 → the cap cell is AIR/sea-fill/
## handed to the tree overlay). WATER-SHORE §3.6: this now smooths UNDERWATER too (no g < SEA_LEVEL
## gate) — underwater caps are ON, so a submerged step descends smoothly instead of ending in an
## abrupt half-block ledge. The query is material-independent, so the same value holds on land and
## underwater; both the memo and the direct branch agree over water.
static func surface_cap_modifier(x: int, z: int, pcache = null) -> int:
	if not SMOOTHING_ENABLED:
		return 0                                      # diagnostic: no cap cells
	if pcache == null and _on_main_thread():
		return (_shape_entry(x, z) >> 24) & 0xFF
	var g := _col_h(x, z, pcache)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return 0
	return _modifier_from_targets(_corner_targets(x, z, pcache), g + 1)

## The appearance manifest (RUNTIME-MATERIAL-STREAMING §6.5 / VOXEL-DATA-STRUCTURE
## §8.1/§8.3): the exact set of (surface material, modifier) pairs this smoothing
## generator can emit. The module path pre-allocates + bakes + FREEZES their ARIDs at
## path activation (before the voxel worker runs), so the worker maps (mat, modifier) →
## ARID by reading a frozen array and never allocates or bakes a model itself.

## The surface materials smoothing can shape — every material `_biome_top` (land) OR
## `_underwater_floor` (WATER-SHORE §3: underwater floors now smooth too) can return.
## Gravel is the one `_underwater_floor` material not already a land top; sand/red_sand/
## mud are shared. The module bakes these × emitted_modifiers() at setup.
static func appearance_surface_materials() -> PackedInt32Array:
	_ensure_ids()
	return PackedInt32Array([
		BlockCatalog.GRASS, _ID_SAND, _ID_RED_SAND, _ID_MUD, _ID_SNOW, _ID_PODZOL, _ID_GRAVEL,
	])

## Every corner-height modifier the smoothing can emit: all BOTTOM-anchored corner
## tuples in {0,1,2}⁴ except all-2 (the FULL cube — served by the eager cube ARID) and
## all-0 (also the FULL-cube encoding 0). 79 shapes; the module bakes materials × these
## once at setup. All BOTTOM-anchored, so each modifier is < 256 (dense manifest slot).
static func appearance_modifiers() -> PackedInt32Array:
	var out := PackedInt32Array()
	for c00 in 3:
		for c10 in 3:
			for c11 in 3:
				for c01 in 3:
					if c00 == 2 and c10 == 2 and c11 == 2 and c01 == 2:
						continue
					if c00 == 0 and c10 == 0 and c11 == 0 and c01 == 0:
						continue
					out.append(ShapeCodec.make_modifier(c00, c10, c11, c01, ShapeCodec.ANCHOR_BOTTOM))
	return out

## The modifier subset the smoother ACTUALLY emits — the module path bakes materials × THIS
## (not × all 79 of appearance_modifiers()), so it pre-bakes far fewer VoxelBlockyModelMesh at
## load. Each bake reads the model's geometry back from the GPU (getBufferSubData → WebGL pipeline
## stall), so 474 → this-count cuts the load pause proportionally. Any modifier NOT in this set
## cube-falls-back on the worker (graceful, never a hole; verify asserts this set covers the
## smoother's real output). Computed ONCE (main thread) by a deterministic wide-area sample of the
## surface + cap smoothing modifiers: the modifier is a pure function of the LOCAL height stencil
## (biome-independent), so a wide patch captures essentially the whole set. WATER-SHORE §3.5: the
## sample now (a) no longer skips underwater columns — SURFACE and CAP modifiers are collected for
## g < SEA_LEVEL too (underwater caps are ON, §3.6) — and (b) unions TWO deterministic centres, find_spawn()
## (inland) and find_coast() (coastline/ocean), so the coastal floor shapes are covered. It is a
## SUPERSET of the truly-emitted set — it ignores the tree-suppression exception (a shape a tree
## would force to full cube is still baked; harmless, just unused). Cached statically; only ever
## called from the manifest bake (main thread) + verify, never the voxel worker.
const _EMIT_SAMPLE_R := 160
static var _emitted_ready := false
static var _emitted_mods := PackedInt32Array()
static func emitted_modifiers() -> PackedInt32Array:
	if not SMOOTHING_ENABLED:
		return PackedInt32Array()                     # diagnostic: no shaped meshes to bake
	if _emitted_ready:
		return _emitted_mods
	_ensure_noise()
	var seen := {}
	_sample_emitted(find_spawn(), _EMIT_SAMPLE_R, seen)   # inland land shapes
	_sample_emitted(find_coast(), _EMIT_SAMPLE_R, seen)   # coastline + underwater floor shapes (§3.5)
	var out := PackedInt32Array()
	for m: int in seen.keys():
		out.append(m)
	out.sort()
	_emitted_mods = out
	_emitted_ready = true
	return _emitted_mods

## Accumulate into `seen` every surface AND cap smoothing modifier emitted over the (2r+1)² region
## centred on `center`. Both SURFACE and CAP modifiers are collected at every column including
## underwater (WATER-SHORE §3.5/§3.6: underwater caps are ON). Cap modifiers are the same corner-
## height family as surface modifiers, so folding them in is superset-safe for the dry manifest.
static func _sample_emitted(center: Vector2i, r: int, seen: Dictionary) -> void:
	var span := 2 * r + 3                              # +1 stencil padding on each side
	# One height_at per column over the padded region (adjacent columns share stencil samples,
	# so a shared grid turns the 9-per-column corner stencil into O(1) lookups).
	var hg := PackedInt32Array()
	hg.resize(span * span)
	for i in span:
		var wx := center.x - r - 1 + i
		for j in span:
			hg[i * span + j] = height_at(wx, center.y - r - 1 + j)
	for i in range(1, span - 1):
		for j in range(1, span - 1):
			var g: int = hg[i * span + j]
			var t := _corner_targets_grid(hg, span, i, j)
			var sm := _modifier_from_targets(t, g)        # surface cell (land OR underwater floor)
			if sm != 0:
				seen[sm] = true
			var cm := _modifier_from_targets(t, g + 1)    # cap cell (same corner targets) — land OR underwater
			if cm != 0:
				seen[cm] = true

## _corner_targets for grid column (i, j) — identical corner formula to _corner_targets(x, z),
## reading the precomputed height grid instead of re-sampling height_at.
static func _corner_targets_grid(hg: PackedInt32Array, span: int, i: int, j: int) -> Vector4:
	var t_nn := float(hg[(i - 1) * span + (j - 1)] + 1)
	var t_0n := float(hg[i * span + (j - 1)] + 1)
	var t_pn := float(hg[(i + 1) * span + (j - 1)] + 1)
	var t_n0 := float(hg[(i - 1) * span + j] + 1)
	var t_00 := float(hg[i * span + j] + 1)
	var t_p0 := float(hg[(i + 1) * span + j] + 1)
	var t_np := float(hg[(i - 1) * span + (j + 1)] + 1)
	var t_0p := float(hg[i * span + (j + 1)] + 1)
	var t_pp := float(hg[(i + 1) * span + (j + 1)] + 1)
	return Vector4(
		(t_nn + t_0n + t_n0 + t_00) * 0.25,
		(t_0n + t_pn + t_00 + t_p0) * 0.25,
		(t_00 + t_p0 + t_0p + t_pp) * 0.25,
		(t_n0 + t_00 + t_np + t_0p) * 0.25)

# --- stage: bedrock floor (WGC §6.1) ------------------------------------------
static func _bedrock_at(x: int, y: int, z: int) -> bool:
	if y <= WORLD_BOTTOM_Y:
		return true                          # y == -64: 100%
	if y >= BEDROCK_TOP_Y:
		return false                         # y >= -59: 0% (no bedrock above -59)
	var p := float(BEDROCK_TOP_Y - y) / float(BEDROCK_TOP_Y - WORLD_BOTTOM_Y)
	return _hash01_3d(x, y, z, _SALT_BEDROCK) < p

# --- stage: sea / ice (WGC §6.7) ----------------------------------------------
# Ice caps the very surface of COLD columns (t < -0.55, i.e. snowy biomes and
# frozen oceans); water fills the rest. Cold columns also report sub-zero surface
# air (PerVoxelEnvironment), so the generated sheet is structurally sound ice
# rather than tissue-paper (INTEGRATION-DECISIONS §1.5 frozen-sea seam).
## The liquid KIND of the sea fill for climate t (MULTI-LIQUID §2.4). THE single regime authority
## consumed by _sea_block AND _with_shore_liquid, so open-water, shore and submerged composites of
## one column can never disagree on kind. Frozen handling (t < -0.55 → an ice cap at the surface
## cell) stays where it is: ice is a SOLID regime, disjoint from LAVA_SEA_T, not a liquid kind.
static func _sea_liquid_kind(t: float) -> int:
	return CellCodec.LIQ_LAVA if t >= LAVA_SEA_T else CellCodec.LIQ_WATER

static func _sea_block(t: float, y: int) -> int:
	var kind := _sea_liquid_kind(t)                   # water / molten regime (frozen handled below)
	var lrid := BlockCatalog.liquid_lrid_of(kind)     # water → 44, lava → 45
	if y == SEA_LEVEL:
		if t < -0.55:
			return _ID_ICE                            # frozen cap (unchanged; no liquid overlay)
		# The open surface cell: the liquid MATERIAL carrying a liquid(kind, 9) overlay so the
		# renderer draws the sunk 0.9 slab instead of a full cube (WATER-SHORE §3.1, kind-parameterized).
		return CellCodec.pack(lrid, 0, 0,
			CellCodec.make_liquid(kind, CellCodec.LIQ_LEVEL_SURFACE))
	return lrid                                       # deep liquid: bare id (§2.3.5 canonical full liquid)

# --- stage: surface rule (WGC §6.5) -------------------------------------------
static func _surface_rule(x: int, y: int, z: int, g: int, biome: int, c: float, t: float) -> int:
	var underwater := g < SEA_LEVEL
	if y == g:
		if underwater:
			return _underwater_floor(biome, x, z, t)   # no grass below sea level
		return _biome_top(biome, x, z)
	var depth := g - y                                  # >= 1 here
	if depth <= _filler_depth(biome):
		return _biome_filler(biome, x, y, z, depth, t)
	return BlockCatalog.STONE

static func _biome_top(biome: int, x: int, z: int) -> int:
	match biome:
		B_BEACH, B_DESERT:
			return _ID_SAND
		B_BADLANDS:
			return _ID_RED_SAND
		B_SWAMP:
			return _ID_MUD
		B_SNOWY:
			return _ID_SNOW
		B_TAIGA:
			return _ID_PODZOL if _hash01_3d(x, 0, z, _SALT_PODZOL) < 0.20 else BlockCatalog.GRASS
		B_OCEAN:
			return _ID_SAND
		_:
			return BlockCatalog.GRASS

static func _underwater_floor(biome: int, x: int, z: int, t: float) -> int:
	match biome:
		B_OCEAN:
			return _ID_SAND if t > 0.0 else _ID_GRAVEL
		B_BEACH, B_DESERT:
			return _ID_SAND
		B_BADLANDS:
			return _ID_RED_SAND
		B_SWAMP:
			return _ID_MUD
		_:
			return _ID_GRAVEL

static func _filler_depth(biome: int) -> int:
	match biome:
		B_BADLANDS:
			return 12       # terracotta bands(8) + red_sandstone(4)
		B_DESERT:
			return 7        # sand(3) + sandstone(4)
		B_BEACH:
			return 6        # sand(3) + sandstone(3)
		B_SWAMP:
			return 5        # mud(3) + dirt(2)
		B_OCEAN:
			return 3        # a few blocks of floor sediment
		_:
			return 3        # snowy/taiga/forest/plains: dirt(3)

static func _biome_filler(biome: int, x: int, y: int, z: int, depth: int, t: float) -> int:
	match biome:
		B_BEACH, B_DESERT:
			return _ID_SAND if depth <= 3 else _ID_SANDSTONE
		B_BADLANDS:
			return _band_color(x, y, z) if depth <= 8 else _ID_RED_SANDSTONE
		B_SWAMP:
			return _ID_MUD if depth <= 3 else BlockCatalog.DIRT
		B_OCEAN:
			return _underwater_floor(B_OCEAN, x, z, t)
		_:
			return BlockCatalog.DIRT

## Badlands terracotta banding: a slowly-drifting stack of the 7 terracotta ids,
## shifted by a 512-column hash lattice (MC-style). posmod (not %) so bands do not
## mirror-glitch below y = 0 (WGC §11.11).
static func _band_color(x: int, y: int, z: int) -> int:
	var shift := int(_hash01_3d(floori(x / 512.0), 0, floori(z / 512.0), _SALT_BAND) * 7.0)
	return _BAND_SEQ[posmod(y + shift, _BAND_SEQ.size())]

# --- stage: deepslate gradient + strata blobs (WGC §6.5) ----------------------
static func _deep_family(x: int, y: int, z: int) -> int:
	var base := BlockCatalog.STONE
	if y < DEEPSLATE_FULL_Y:
		base = _ID_DEEPSLATE
	elif y <= DEEPSLATE_TOP_Y:
		var band := DEEPSLATE_TOP_Y - DEEPSLATE_FULL_Y   # 8
		if _hash01_3d(x, y, z, _SALT_DEEP) < float(DEEPSLATE_TOP_Y - y) / float(band):
			base = _ID_DEEPSLATE
	var variant := _strata_at(x, y, z)
	if variant >= 0:
		if base == BlockCatalog.STONE:
			return variant                       # granite/diorite/... replace stone
		# In the deepslate region deepslate stays dominant; only the deep sulfur/
		# cinnabar pockets punch through it (WGC §6.5).
		if variant == _ID_SULFUR or variant == _ID_CINNABAR:
			return variant
	return base

## Strata blob at (x,y,z) or -1. One 16^3 lattice; the blob centre is jitter-
## clamped so centre +/- radius stays inside its lattice cell (the TreeGen
## containment trick), so a query consults exactly ONE lattice cell.
static func _strata_at(x: int, y: int, z: int) -> int:
	var lx := floori(x / float(_STRATA_L))
	var ly := floori(y / float(_STRATA_L))
	var lz := floori(z / float(_STRATA_L))
	if _hash01_3d(lx, ly, lz, _SALT_STRATA_EXIST) >= 0.25:
		return -1
	var r := 3 + int(_hash01_3d(lx, ly, lz, _SALT_STRATA_R) * 5.0)    # 3..7
	var span := maxi(_STRATA_L - 2 * r, 0)
	var cx := lx * _STRATA_L + r + int(_hash01_3d(lx, ly, lz, _SALT_STRATA_JX) * float(span + 1))
	var cy := ly * _STRATA_L + r + int(_hash01_3d(lx, ly, lz, _SALT_STRATA_JY) * float(span + 1))
	var cz := lz * _STRATA_L + r + int(_hash01_3d(lx, ly, lz, _SALT_STRATA_JZ) * float(span + 1))
	var dx := x - cx
	var dy := y - cy
	var dz := z - cz
	if dx * dx + dy * dy + dz * dz > r * r:
		return -1
	# Deep pockets (below -32): rare sulfur/cinnabar; otherwise a common stone strata.
	if cy < -32:
		var d := _hash01_3d(lx, ly, lz, _SALT_STRATA_VAR + 1)
		if d < 0.10:
			return _ID_SULFUR
		if d < 0.20:
			return _ID_CINNABAR
	var h := _hash01_3d(lx, ly, lz, _SALT_STRATA_VAR)
	return _STRATA_SEQ[int(h * float(_STRATA_SEQ.size())) % _STRATA_SEQ.size()]

# --- stage: ores (WGC §6.6) — deterministic lattice, triangle distributions ---
static func _ore_at(x: int, y: int, z: int, host: int, biome: int, c: float) -> int:
	if host != BlockCatalog.STONE and host != _ID_DEEPSLATE:
		return host                              # ore only replaces stone/deepslate
	var lx := floori(x / float(_ORE_L))
	var ly := floori(y / float(_ORE_L))
	var lz := floori(z / float(_ORE_L))
	if _hash01_3d(lx, ly, lz, _SALT_ORE_EXIST) >= 0.55:
		return host
	var r := 1 + int(_hash01_3d(lx, ly, lz, _SALT_ORE_R) * 2.0)   # 1..2
	var span := maxi(_ORE_L - 2 * r, 0)
	var cx := lx * _ORE_L + r + int(_hash01_3d(lx, ly, lz, _SALT_ORE_JX) * float(span + 1))
	var cy := ly * _ORE_L + r + int(_hash01_3d(lx, ly, lz, _SALT_ORE_JY) * float(span + 1))
	var cz := lz * _ORE_L + r + int(_hash01_3d(lx, ly, lz, _SALT_ORE_JZ) * float(span + 1))
	var dx := x - cx
	var dy := y - cy
	var dz := z - cz
	if dx * dx + dy * dy + dz * dz > r * r:
		return host
	# Ore TYPE is decided once per blob (at its centre y); the individual voxel is
	# clipped to that ore's own y-band, so e.g. diamond never appears above -40.
	var ore := _pick_ore(cy, biome, c, lx, ly, lz)
	if ore < 0 or _ore_density(ore, y) <= 0.0:
		return host
	return _ORE_DEEP[ore] if host == _ID_DEEPSLATE else _ORE_STONE[ore]

## Triangle (or edge) distribution density for ore `i` at world y, in [0,1].
static func _ore_density(i: int, y: int) -> float:
	var ymin: int = _ORE_YMIN[i]
	var ymax: int = _ORE_YMAX[i]
	var peak: int = _ORE_PEAK[i]
	if y < ymin or y > ymax:
		return 0.0
	if y <= peak:
		return 1.0 if peak == ymin else float(y - ymin) / float(peak - ymin)
	return 1.0 if ymax == peak else float(ymax - y) / float(ymax - peak)

static func _eff_weight(i: int, y: int, biome: int, c: float) -> float:
	if i == _ORE_EMERALD and c <= 0.4:
		return 0.0                               # emerald: highlands (c>0.4) only
	var w: float = _ORE_WEIGHT[i] * _ore_density(i, y)
	if i == _ORE_GOLD and biome == B_BADLANDS:
		w *= 4.0                                 # badlands gold bonus (MC parity)
	return w

static func _pick_ore(y: int, biome: int, c: float, lx: int, ly: int, lz: int) -> int:
	var total := 0.0
	for i in 8:
		total += _eff_weight(i, y, biome, c)
	if total <= 0.0:
		return -1
	var r := _hash01_3d(lx, ly, lz, _SALT_ORE_PICK) * total
	var acc := 0.0
	for i in 8:
		acc += _eff_weight(i, y, biome, c)
		if r < acc:
			return i
	return 7

# ------------------------------------------------------------------------------
# Material projection + solidity helpers (unchanged contract).

## Material id the generator puts at (x,y,z) — the material projection of the
## packed generated_cell(). Every existing caller reads this exact 0..COUNT-1 id.
static func generated_block(x: int, y: int, z: int) -> int:
	return CellCodec.mat(generated_cell(x, y, z))

## True when cell (x, y, z) is a SOLID material (solidity gate, WGC §6.3): water/
## lava/powder_snow are non-solid even though generated_block returns their id.
static func is_solid(x: int, y: int, z: int) -> bool:
	return BlockCatalog.solidity_of(generated_block(x, y, z)) >= 0.5

## Convenience: solidity from a world-space position (floored to a cell).
static func is_solid_pos(p: Vector3) -> bool:
	return is_solid(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))

# ------------------------------------------------------------------------------
# Spawn selection (WGC §8): origin is seed-dependent and may be ocean, so scan
# outward from (0,0) for the first temperate land column above the sea.
static func find_spawn() -> Vector2i:
	for radius in range(0, 512, 4):
		for a in range(0, 360, 15):
			var rad := deg_to_rad(float(a))
			var x := int(round(cos(rad) * float(radius)))
			var z := int(round(sin(rad) * float(radius)))
			var p := column_profile(x, z)
			var g := int(p.x)
			var b := int(p.y)
			if g > SEA_LEVEL + 1 and (b == B_PLAINS or b == B_FOREST):
				return Vector2i(x, z)
	return Vector2i(0, 0)

## Sentinel returned by find_coast_of when no coast of the requested kind is found in range.
const _COAST_NONE := Vector2i(0x7fffffff, 0x7fffffff)

## The first column at exactly the water line (g == SEA_LEVEL) whose SEA REGIME is `kind`
## (MULTI-LIQUID §2.4) — i.e. non-frozen (t >= -0.55) AND _sea_liquid_kind(t) == kind — scanned
## outward from origin with the find_spawn pattern (radius step 4, 15° steps). Water coasts are
## common (radius 512); lava coasts are rare (temperature freq 0.002 → hundreds-of-blocks climate
## regions, same rarity class as frozen oceans), so the lava scan extends to 1024. Returns
## _COAST_NONE if none is found, in which case per-kind SHORE-pair sampling is skipped — safe,
## because emitted_submerged_pairs is material-complete regardless (distant seas still get their
## submerged twins; only unsampled shore pairs degrade to the dry border, never a hole).
## Deterministic, main-thread, setup/verify-time only.
static func find_coast_of(kind: int) -> Vector2i:
	var max_r := 1024 if kind == CellCodec.LIQ_LAVA else 512
	for radius in range(0, max_r, 4):
		for a in range(0, 360, 15):
			var rad := deg_to_rad(float(a))
			var x := int(round(cos(rad) * float(radius)))
			var z := int(round(sin(rad) * float(radius)))
			if height_at(x, z) != SEA_LEVEL:
				continue
			var t := column_profile(x, z).w
			if t < -0.55:
				continue                              # frozen: ice regime, not a liquid coast
			if _sea_liquid_kind(t) != kind:
				continue                              # a different liquid regime
			return Vector2i(x, z)
	return _COAST_NONE

## The nearest WATER coastline centre, for the coastal manifest sample
## (emitted_modifiers()/emitted_shore_pairs()) and verify. Water-compat wrapper over find_coast_of;
## preserves the historical Vector2i(0, 0) fallback for callers that index into the result.
static func find_coast() -> Vector2i:
	var c := find_coast_of(CellCodec.LIQ_WATER)
	return Vector2i(0, 0) if c == _COAST_NONE else c

## The sampled set of (surface material, modifier) pairs a SHORE composite actually emits at the
## LEVEL-9 water line (WATER-SHORE §3.5/§3.6), each encoded as the SAME slot the module manifest
## uses: mat * 256 + modifier. Two families, sampled over the find_coast()-centred region:
##  (1) SURFACE composites — every column at exactly the water line (g == SEA_LEVEL), non-frozen
##      (column_profile().w >= -0.55), with a nonzero surface modifier records
##      `_biome_top(biome, x, z) * 256 + sm` (a surface composite's material is its biome top).
##  (2) Underwater CAP composites (§3.6) — every column ONE below the water line (g == SEA_LEVEL-1),
##      non-frozen, with a nonzero CAP modifier records `_underwater_floor(...) * 256 + cm`: that
##      cap lands AT the water line (y = g+1 = SEA_LEVEL) as a LEVEL-9 wet composite whose material
##      is the underwater-floor material below it, so it needs the wet model baked too. Deeper caps
##      (g < SEA_LEVEL-1) land below the water line as LEVEL-10 DRY composites, covered by the dry
##      manifest (appearance_surface_materials × emitted_modifiers), not here.
## Like emitted_modifiers() it is a deliberate superset/sample — correctness never depends on
## completeness (a rare unsampled pair renders as the DRY shaped model on the worker: a notch,
## never a hole). Cached statically; main-thread setup/verify only, never the voxel worker.
const _SHORE_STRIDE := 256
static var _shore_pairs_by_kind: Dictionary = {}     # liquid kind -> cached PackedInt32Array of shore pairs
static func emitted_shore_pairs(kind := CellCodec.LIQ_WATER) -> PackedInt32Array:
	if not SMOOTHING_ENABLED:
		return PackedInt32Array()                     # diagnostic: no shaped meshes to bake
	if _shore_pairs_by_kind.has(kind):
		return _shore_pairs_by_kind[kind]
	_ensure_noise()
	_ensure_ids()
	var out := PackedInt32Array()
	var c := find_coast_of(kind)
	if c == _COAST_NONE:
		# No coast of this kind in range (e.g. a lava sea outside the scan radius for this seed):
		# skip shore-pair sampling. emitted_submerged_pairs is material-complete regardless, so the
		# sea still gets its submerged twins; only unsampled shore pairs degrade to the dry border.
		_shore_pairs_by_kind[kind] = out
		return out
	var r := _EMIT_SAMPLE_R
	var seen := {}
	# (1) SURFACE composites — columns exactly at the water line (g == SEA_LEVEL) whose sea regime
	# is `kind` (non-frozen AND _sea_liquid_kind == kind, generalizing the old frozen-only skip; this
	# also stops water sampling from wandering into a molten shore). Their material is the biome top.
	for dx in range(-r, r + 1):
		var x := c.x + dx
		for dz in range(-r, r + 1):
			var z := c.y + dz
			if height_at(x, z) != SEA_LEVEL:
				continue                              # shore composites live exactly at the water line
			var p := column_profile(x, z)             # climate noise only for the few water-line columns
			if p.w < -0.55 or _sea_liquid_kind(p.w) != kind:
				continue                              # ice regime, or a different liquid regime
			var sm := surface_modifier(x, z, {})      # direct compute (a fresh pcache avoids memo pollution)
			if sm == 0:
				continue
			seen[_biome_top(int(p.y), x, z) * _SHORE_STRIDE + sm] = true
	# (2) Underwater CAP composites (WATER-SHORE §3.6): a column one below the water line
	# (g == SEA_LEVEL - 1) that grows a cap places that cap AT the water line (y = g+1 = SEA_LEVEL)
	# as a LEVEL-9 wet composite of the underwater-floor material — so it needs the wet model baked.
	for dx in range(-r, r + 1):
		var x := c.x + dx
		for dz in range(-r, r + 1):
			var z := c.y + dz
			if height_at(x, z) != SEA_LEVEL - 1:
				continue                              # water-line caps grow from the column just below
			var p := column_profile(x, z)
			if p.w < -0.55 or _sea_liquid_kind(p.w) != kind:
				continue                              # ice regime, or a different liquid regime
			var cm := surface_cap_modifier(x, z, {})  # direct compute (a fresh pcache avoids memo pollution)
			if cm == 0:
				continue
			seen[_underwater_floor(int(p.y), x, z, p.w) * _SHORE_STRIDE + cm] = true
	for s: int in seen.keys():
		out.append(s)
	out.sort()
	_shore_pairs_by_kind[kind] = out
	return out

## The (surface material, modifier) pairs a SUBMERGED composite emits BELOW the water line — the
## companion set to emitted_shore_pairs() that NATIVE WATERLOGGING needs (WATERLOGGING.md §4.3
## COVERAGE / §4.5). A submerged composite is a solid ramp filled with water to the top (liquid 10):
## its surface cell (y == g, g < SEA_LEVEL) and any cap cell landing below the line are always the
## UNDERWATER-FLOOR material — sand / gravel / red_sand / mud — shaped by a corner-height modifier.
## So the complete material axis is those four, and the modifier axis is the smoother's emitted set
## (emitted_modifiers, a superset sample); their cross-product is the pairs whose waterlogged twin
## must be baked so submerged water culls seamlessly against the surrounding water (no border).
## Deterministic + material-COMPLETE (unlike a spatial sample, all four floor materials are always
## covered regardless of which biomes ring the found coast). A rare truly-unemitted pair just bakes
## an unused twin (harmless); a missing pair falls back to the dry shape (a border, never a hole).
## Encoded as mat * _SHORE_STRIDE + modifier, matching emitted_shore_pairs()/the module manifest slot.
## Main-thread setup/verify only (calls emitted_modifiers, which is not worker-safe); never the worker.
## MULTI-LIQUID §2.4: the `kind` argument is accepted so Stream C can call this per liquid, but the
## CONTENT is kind-independent — a molten sea's underwater floor reuses _underwater_floor (hot ocean
## → sand), so the four floor materials × emitted modifiers cover every submerged composite of ANY
## liquid. Kept material-complete (never a spatial sample) so distant/unfound seas still get twins.
static func emitted_submerged_pairs(_kind := CellCodec.LIQ_WATER) -> PackedInt32Array:
	if not SMOOTHING_ENABLED:
		return PackedInt32Array()                     # diagnostic: no shaped meshes to bake
	_ensure_ids()
	var mats := PackedInt32Array([_ID_SAND, _ID_GRAVEL, _ID_RED_SAND, _ID_MUD])
	var mods := emitted_modifiers()
	var out := PackedInt32Array()
	for mat: int in mats:
		for m: int in mods:
			out.append(mat * _SHORE_STRIDE + m)
	return out
