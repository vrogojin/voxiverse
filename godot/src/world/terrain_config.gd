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

# --- vertical structure (WGC §6.1, our scale) ---------------------------------
const WORLD_BOTTOM_Y := -64      # world floor; below is void (unreachable)
const BEDROCK_TOP_Y := -59       # bedrock gradient: 100% at -64 -> 0% at -59
const DEEPSLATE_FULL_Y := -24    # below here: always deepslate
const DEEPSLATE_TOP_Y := -16     # above here: always stone; dithered band between
const SEA_LEVEL := 0             # air below SEA_LEVEL fills with water (ice cap when cold)

# --- gentle, shallow base hills (unchanged; the c~0 plains preserve today's look)
const BASE_HEIGHT := 5.0        # average ground height at the coast/plains
const HILLS_AMPLITUDE := 3.0    # shallow rolling hills (open, walkable)
const DETAIL_AMPLITUDE := 1.0   # small-scale bumpiness on top

## Render radius around the player, in blocks (DESIGN §1). Drives the fallback
## chunk radius and the fog reference distance.
const RENDER_RADIUS_BLOCKS := 256

## The godot_voxel viewer streams a (vertically stretched) sphere. Terrain is
## shallow, so no vertical stretch is needed — keep it at 1.0.
const VIEWER_VERTICAL_RATIO := 1.0

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
	var h := base + _hills.get_noise_2d(fx, fz) * HILLS_AMPLITUDE
	h += _detail.get_noise_2d(fx, fz) * DETAIL_AMPLITUDE
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
		# Smoothing CAP cell (SUB-VOXEL-SMOOTHING §8.1): a land column whose neighbours
		# rise grows a partial grass lip one cell above its surface, bridging a 1-block
		# step up into a continuous slope. Land only (g >= SEA_LEVEL) so a cap never
		# displaces the sea fill. Returns AIR (falls through) when no cap grows here.
		if y == g + 1 and g >= SEA_LEVEL:
			var cap := _surface_cap(x, z, g, biome, pcache)
			if cap != BlockCatalog.AIR:
				return cap
		# Above the solid ground: sea fill (g < y <= SEA_LEVEL) else the tree overlay.
		if y <= SEA_LEVEL:
			return _sea_block(t, y)
		return TreeGen.block_at(x, y, z, pcache)
	var id := _surface_rule(x, y, z, g, biome, c, t)
	if id == BlockCatalog.STONE:
		id = _deep_family(x, y, z)      # stone -> deepslate gradient + strata blobs
		id = _ore_at(x, y, z, id, biome, c)   # host-aware ore lattice
	# Smoothing SURFACE shape (SVS §8.1): reshape the walkable top cell of a land column
	# into a corner-height ramp/slab whose surface fits the four neighbouring column
	# tops. Only the MODIFIER changes — the material projection (generated_block) is
	# untouched, so every material/stackup invariant holds; cells below the surface stay
	# solid full cubes, so the analytic floor scan can never fall through.
	if y == g and g >= SEA_LEVEL:
		return _smoothed_surface(x, z, g, id, pcache)
	return id

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

## The packed SURFACE cell value at (x, g, z): the biome-top material `mat` reshaped by
## the smoothing modifier, or the plain material when flat OR under a tree base (a tree
## cell resting on the surface forces it FULL so trunks never float on a ramp corner —
## SVS §8.1 tree exception).
static func _smoothed_surface(x: int, z: int, g: int, mat: int, pcache = null) -> int:
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return mat                                    # a tree cell rests here → keep FULL
	var m := _modifier_from_targets(_corner_targets(x, z, pcache), g)
	if m == 0:
		return mat
	return CellCodec.pack(mat, m)

## The packed CAP cell value at (x, g+1, z), or AIR (0) when no cap grows here (flat
## ground, a >1-block cliff that saturates to a full block, or a tree cell owning the
## cell). The cap is the column's surface material, shaped by the SAME corner targets as
## the surface cell below it, so the two form one crack-free continuous slope.
static func _surface_cap(x: int, z: int, g: int, biome: int, pcache = null) -> int:
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return BlockCatalog.AIR                       # tree overlay owns this cell
	var m := _modifier_from_targets(_corner_targets(x, z, pcache), g + 1)
	if m == 0:
		return BlockCatalog.AIR                       # no lip (flat) or a full-block step (kept blocky)
	return CellCodec.pack(_biome_top(biome, x, z), m)

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
## would emit for the top cell (0 == FULL cube: underwater floor, a tree-owned top, or flat/steep
## ground; nonzero == a ramp/slab). No material/biome/strata/ore branches are evaluated.
static func surface_modifier(x: int, z: int, pcache = null) -> int:
	var g := _col_h(x, z, pcache)
	if g < SEA_LEVEL:
		return 0                                      # underwater floor is never smoothed (full cube)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return 0                                      # a tree cell rests on the top → kept FULL
	return _modifier_from_targets(_corner_targets(x, z, pcache), g)

## The smoothing MODIFIER of the CAP cell at (x, height_at(x,z)+1, z), or 0 when no cap
## grows here (flat/steep, tree-owned, or underwater). Equals
## CellCodec.modifier(generated_cell(x, height_at(x,z)+1, z)) — when nonzero the cap's material
## is a non-air biome top, so the collider needs only this modifier (nonzero → shaped prism cell;
## 0 → the cap cell is AIR/handed to the tree overlay).
static func surface_cap_modifier(x: int, z: int, pcache = null) -> int:
	var g := _col_h(x, z, pcache)
	if g < SEA_LEVEL:
		return 0
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return 0
	return _modifier_from_targets(_corner_targets(x, z, pcache), g + 1)

## The appearance manifest (RUNTIME-MATERIAL-STREAMING §6.5 / VOXEL-DATA-STRUCTURE
## §8.1/§8.3): the exact set of (surface material, modifier) pairs this smoothing
## generator can emit. The module path pre-allocates + bakes + FREEZES their ARIDs at
## path activation (before the voxel worker runs), so the worker maps (mat, modifier) →
## ARID by reading a frozen array and never allocates or bakes a model itself.

## The land surface materials smoothing can shape — every biome top `_biome_top` can
## return for a land column. Ocean/underwater floors are never smoothed (g < SEA_LEVEL).
static func appearance_surface_materials() -> PackedInt32Array:
	_ensure_ids()
	return PackedInt32Array([
		BlockCatalog.GRASS, _ID_SAND, _ID_RED_SAND, _ID_MUD, _ID_SNOW, _ID_PODZOL,
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
static func _sea_block(t: float, y: int) -> int:
	if y == SEA_LEVEL and t < -0.55:
		return _ID_ICE
	return _ID_WATER

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
