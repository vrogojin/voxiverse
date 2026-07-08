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

## Snow-ACCUMULATION baseline (SNOW-ACCUMULATION Decision 3.2): the STATIC, pure-SEED snow depth D
## (tenths of a block above the solid top g) — the feature has its look with the sim OFF. Two composed
## terms, both keyed on the ONE temperature authority (ClimateModel.surface_temperature, the same zero
## crossing as the M1 cap/melt), so all three snow authorities agree at the boundary. This REPLACES the
## fixed all-corners-1 half-slab (M1 Decision 6): every column that slabbed now carries D ≥ 5.
const SNOW_T0 := 0.0                 # depth begins strictly below freezing (matches the cap stamp)
const SNOW_BLANKET_PER_C := 0.4      # blanket tenths per °C below zero (a thin terrain-following crust)
const SNOW_BLANKET_MAX := 3          # blanket cap: a 0.3 dusting-to-crust (what dusts peaks that poke through)
const SNOW_FILL_PER_C := 1.5         # fill-plane tenths per °C below zero (the flatness term)
const SNOW_FILL_MAX_CELLS := 4       # fill never exceeds 4 blocks above g (deep-gully clamp)
const SNOW_REF_LATTICE := 8          # smoothed-terrain reference lattice pitch (blocks) for h_ref

## The 0.5 uniform layer's canonical modifier == CellCodec.LAYER_SLAB_MODIFIER (an all-corners-1 BOTTOM
## slab, ShapeCodec.make_modifier(1,1,1,1,BOTTOM) == 85). REPURPOSED from the removed fixed slab to "the
## canonical encoding of snow LAYER level 5" (SNOW-ACCUMULATION §1.3 rule 5); it stays baked (level 5 of
## the snow stack emits it on snow_block) and the emitted-modifier union keeps it in the manifest.
const SNOW_SLAB_MODIFIER := 85

## SHARP-SLOPE §3.2: max corner-target relief (whole blocks) across one cell that the SLOPE family
## can express as one clean planar diagonal. Steeper terrain saturates the corner-height family
## (legacy) and stays a blocky cliff (the §8 non-goal preserved). A run spans ≤ this many cells.
const SLOPE_MAX_SPREAD := 3

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

# --- Mountains biome (a SEPARATE, TALL biome — does NOT touch hills/plains) --------------------
# A dedicated LOW-frequency mask noise (_mountain, seed SEED+104, freq 0.0008 — broader than the
# 0.0015 continent noise, so ranges are coherent, not speckled) carves a few broad ranges. Where the
# mask (smoothstepped to [0,1]) AND an inland guard (smoothstep on continentalness) are BOTH nonzero,
# _height_c ADDS mountain_uplift = factor * MOUNTAIN_AMPLITUDE. The factor is EXACTLY 0 outside
# mountain regions (mask <= MASK_LO, OR coastal c <= C_LO), so `h` there is bit-for-bit unchanged and
# the whole non-mountain world stays BYTE-IDENTICAL (proven in verify). A full-mask inland peak reaches
# base(6..16) + 92 ≈ y=98..112 — ABOVE the y=96 freezing altitude (ClimateModel.ALT_ZERO_Y) — so the
# ALREADY-WIRED altitude snow cap (a surface caps iff surface_temperature < 0) whitens the peaks with
# NO new cap code. Mountain tops are bare `stone` (rock peaks), added to the baked cappable set so a
# high stone cap renders white on BOTH paths. Lower flanks (factor below the biome threshold) keep
# their surrounding climate biome (grass/forest slopes), below the freeze line, bare.
const MOUNTAIN_AMPLITUDE := 92.0    # full-mask uplift in blocks (a full peak ≈ inland base + this)
const MOUNTAIN_MASK_LO := 0.35      # mask noise <= this -> factor 0 (world byte-identical); a flank begins here
const MOUNTAIN_MASK_HI := 0.68      # mask noise >= this -> full peak (factor's mask term = 1)
const MOUNTAIN_C_LO := 0.05         # continentalness <= this (coast/ocean) -> no uplift (mountains are inland)
const MOUNTAIN_C_HI := 0.35         # ...fully inland (mask term ungated) at/above this
const MOUNTAIN_BIOME_T := 0.35      # a column whose mountain FACTOR exceeds this is classified B_MOUNTAINS

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

## Curved (COSMOS) near-field render radius. The flat world's per-column worldgen is one cheap 2D
## noise stack; the CURVED world's is a ~8× get_noise_3d + f64 cube-sphere fold per column (§3.5), so
## streaming the full 256-block near sphere on the web's 2 voxel worker threads takes minutes ("chunks
## generate veeery slowly"). The far LOD field (FarTerrain) already draws everything past the near hole
## from a cheap coarse height mesh, so the near voxel field only needs to cover the walk-around
## neighbourhood. 128 blocks of full-detail voxels ≈ (128/256)³ ≈ 1/8 the data blocks of 256 → ~8×
## faster curved streaming, with the far LOD (its inner hole moved to match — see FarTerrain) filling
## the rest seamlessly. FLAT_WORLD is unaffected (near_render_radius() returns the full 256).
const CURVED_RENDER_RADIUS_BLOCKS := 128

## THE near-field render radius the module viewer/terrain actually use: the full 256 in the flat world,
## the cheaper CURVED_RENDER_RADIUS_BLOCKS on the planet. Flat callers get the byte-identical 256.
static func near_render_radius() -> int:
	return RENDER_RADIUS_BLOCKS if CubeSphere.FLAT_WORLD else CURVED_RENDER_RADIUS_BLOCKS

## The godot_voxel viewer streams a vertically-scaled ellipsoid: the vertical view radius is
## VIEWER_VERTICAL_RATIO * view_distance (RENDER_RADIUS_BLOCKS = 256). Before the Mountains biome the
## world was only ~94 blocks tall (bedrock y=-64 .. treetops ~y=30) and 0.2 (±51-block slab) sufficed.
## Mountains now reach y≈112, so a SEA-LEVEL player (y≈5) must stream ~107 blocks UP to SEE a peak
## within the render radius; 0.5 gives a ±128-block slab (0.5·256) that covers the tallest peak from
## sea level with margin AND, when the player stands ON a peak (y≈108), still streams down past sea
## level. PERF TRADE-OFF (bounded, deliberate): the streamed vertical slab grows 2×51→2×128 ≈ 2.5×, so
## ~2.5× more DATA/MESH blocks stream vertically — but the extra blocks are mostly air above the terrain
## (cheap early-out, below) or interior stone (faces culled); the meshed SURFACE area grows only by the
## mountains themselves. Horizontal radius is UNCHANGED. PURE CONFIG: a block streams identically
## whenever it DOES stream (only WHEN changes), so determinism/output are unaffected; analytic physics +
## the collider read TerrainConfig directly (not the mesh), so collision is unchanged.
const VIEWER_VERTICAL_RATIO := 0.5

## PROVEN upper bound on height_at(x,z) over the whole (infinite) domain — the module generator
## uses it to CHEAPLY skip all-air blocks far above the terrain BEFORE the column-profile pass.
## Analytic max height_at = BASE_HEIGHT(5) + max _continent_offset(11) + HILLS_AMPLITUDE(3) +
## DETAIL_AMPLITUDE(1) + max mountain_uplift (MOUNTAIN_AMPLITUDE(92) · full factor 1.0) = 112 (each
## FastNoiseLite term is bounded to [-1,1]; Godot normalizes FBM; the mountain factor is a product of
## two smoothsteps in [0,1]), + 4 margin. A large-sample assert in verify_feature confirms the bound so
## the early-out can NEVER skip real content (a too-low bound would punch holes in the world). PERF
## NOTE: raising this from 24 to 116 means the CHEAP constant early-out no longer catches mid-altitude
## air blocks over FLAT terrain — they pay one column-profile pass before the tighter per-block max_h
## early-out rejects them. Bounded by the streamed vertical slab; accepted for the Mountains milestone.
const MAX_SURFACE_Y := 116

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
const B_MOUNTAINS := 9   # SEPARATE tall biome: stone peaks that cross the y=96 freeze line (altitude snow caps)

# --- salt registry (WGC §7.1 — one place, no collisions) ----------------------
# TreeGen owns 11/22/33/44/55/66/88. TerrainConfig owns 101-103 (noise seeds), 104
# (Mountains mask), and the 7xx hashing salts below. SnowfallSystem owns 105 (the
# SEED+105 weather-gate noise, SNOW-ACCUMULATION §4.3) — recorded here so the one-place
# registry stays collision-free even though the noise object lives in the sim class.
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
static var _mountain: FastNoiseLite    # Mountains-biome mask (broad, low-frequency ranges)

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

	# Mountains-biome mask (SEPARATE from hills): its OWN low-frequency noise (freq 0.0008 < the 0.0015
	# continent noise) so mountain ranges are BROAD and coherent rather than speckled. Warmed here on the
	# MAIN thread (WGC §7.4) before the voxel worker runs — a lazily-built noise first-touched on the
	# worker is the project's worst data-race class.
	_mountain = _make_climate(SEED + 104, 0.0008)

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
	# COSMOS crash-fix (WGC §7.4): in curved mode the worldgen fold (LatticeNav → CubeSphere.fold_cell)
	# reads a lazily-built static edge-remap table. If the voxel WORKER first-touches that build while a
	# main-thread fold (FarTerrain / collider / HUD / player query) runs concurrently, the shared static
	# Dictionary/Array corrupts → the worker dies with "index out of bounds" (the browser hang). Build it
	# NOW on the main thread (warm_up runs in module setup before the worker attaches) so every later fold
	# is a pure concurrent READ of a frozen table. FLAT_WORLD never folds, so this is skipped there.
	if not CubeSphere.FLAT_WORLD:
		CubeSphere.warm_edge_tables(CubeSphere.n_for(CubeSphere.HOME_BODY))

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

## The Mountains-biome uplift FACTOR in [0,1] at column (fx, fz) of continentalness `c`: the mask noise
## smoothstepped over [MASK_LO, MASK_HI], gated by an inland smoothstep over [C_LO, C_HI]. It is EXACTLY
## 0.0 wherever the mask noise <= MASK_LO (Godot's smoothstep returns 0 at/below edge0) OR the column is
## coastal (c <= C_LO) — so `_height_c` adds nothing there and those columns stay BYTE-IDENTICAL. PURE +
## DETERMINISTIC (one FastNoiseLite sample + two smoothsteps of SEED/position; no randi/Time), so both
## render paths and the analytic queries agree by construction. Callers _ensure_noise() first.
static func _mountain_factor(c: float, fx: float, fz: float) -> float:
	var m := smoothstep(MOUNTAIN_MASK_LO, MOUNTAIN_MASK_HI, _mountain.get_noise_2d(fx, fz))
	if m <= 0.0:
		return 0.0                                   # not a mountain here -> uplift 0 (byte-identical world)
	return m * smoothstep(MOUNTAIN_C_LO, MOUNTAIN_C_HI, c)

## COSMOS 3D twin of _mountain_factor (§3.5): the same mask + inland gate, sampling the mountain mask
## from get_noise_3d at the sphere point (px, py, pz) instead of get_noise_2d. Feeds the Mountains
## biome + uplift into the CURVED worldgen so the sphere carries real mountains. Only reached when
## FLAT_WORLD is false; the flat path uses the 2D _mountain_factor above and stays byte-identical.
static func _mountain_factor3(c: float, px: float, py: float, pz: float) -> float:
	var m := smoothstep(MOUNTAIN_MASK_LO, MOUNTAIN_MASK_HI, _mountain.get_noise_3d(px, py, pz))
	if m <= 0.0:
		return 0.0
	return m * smoothstep(MOUNTAIN_C_LO, MOUNTAIN_C_HI, c)

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
	# Mountains biome (SEPARATE tall term; does NOT touch the hills above). Added AFTER the beach shelf —
	# mountains are inland (C_LO gate) so their shelf `w` is 0 anyway, keeping every coastal column
	# byte-identical. The factor is exactly 0 outside mountain regions, so `h` is bit-for-bit unchanged
	# there; a full-mask inland peak gains up to MOUNTAIN_AMPLITUDE blocks, crossing the y=96 freeze line.
	h += _mountain_factor(c, fx, fz) * MOUNTAIN_AMPLITUDE
	return int(floor(h))

## Surface height (integer y of the topmost SOLID ground cell) at column (x, z).
## Water/ice sit ABOVE this, up to SEA_LEVEL. UNCHANGED contract for every caller
## (PerVoxelEnvironment depth model, effective_height, floor scans, TreeGen).
static func height_at(x: int, z: int) -> int:
	_ensure_noise()
	# COSMOS M1 (§3.5): when the planet is on, (x, z) is the face-4 window column (i, j) and the
	# surface height is derived from the 3D noise domain along d̂. FLAT_WORLD (default) skips this
	# branch entirely, so the flat world is byte-identical.
	if not CubeSphere.FLAT_WORLD:
		# Route through the shared analytic memo (PERF): far terrain, snowfall, per-voxel-env and the
		# structural solver all call height_at every frame; without the memo each recomputed the full
		# _curved_profile. Same value as the direct _curved_profile(_active_face, x, z).x, just cached.
		return int(analytic_column_profile(x, z).x)
	var fx := float(x)
	var fz := float(z)
	return _height_c(_continent.get_noise_2d(fx, fz), fx, fz)

## Biome enum (B_*) at column (x, z) — ordered first-match rule chain (WGC §6.4). `mountain` is the
## precomputed Mountains-biome factor (0 outside mountain regions); a column whose factor exceeds
## MOUNTAIN_BIOME_T is a mountain regardless of climate (a tall peak reads as rock; its snow cap then
## depends on altitude+climate via the existing surface_temperature predicate). Checked AFTER ocean/beach
## so the coast is never a mountain, and BEFORE the climate biomes so tall inland ground of ANY climate
## becomes B_MOUNTAINS. Below the threshold (foothills/flanks) the column keeps its climate biome.
static func _biome(c: float, t: float, h: float, g: int, mountain: float) -> int:
	if c < -0.32:
		return B_OCEAN
	# Beaches ring the coast: near sea level AND continentally coastal (the c gate
	# keeps inland lowland dips from speckling as sand — WGC §9 noise-smoothness).
	if c < 0.25 and g >= SEA_LEVEL - 2 and g <= SEA_LEVEL + 2:
		return B_BEACH
	if mountain > MOUNTAIN_BIOME_T:
		return B_MOUNTAINS
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
	# COSMOS frozen-epoch (F1): a GenCtx (the worker path) carries the immutable face + a memo keyed by
	# (face, x, z); a plain Dictionary (legacy / analytic worker) or null memoizes by (x, z) and reads
	# `_active_face` (main-thread only). In FLAT_WORLD a GenCtx is never used, so the flat path below is
	# reached only through the Dictionary/null branch and stays byte-identical.
	var memo: Variant = pcache
	var face := _active_face
	var ck: Variant
	if pcache is GenCtx:
		memo = pcache.memo
		face = pcache.face
		ck = Vector3i(face, x, z)
	else:
		ck = Vector2i(x, z)
	if memo != null:
		if memo.has(ck):
			return memo[ck]
	_ensure_noise()
	var prof: Vector4
	if not CubeSphere.FLAT_WORLD:
		# COSMOS M1 (§3.5)/M3 (§4.5): the home-face lattice column (i, j) = (x, z), sampled from 3D noise
		# along d̂. `face` is `ctx.face` on the worker (an immutable snapshot) or `_active_face` on the
		# main thread — never a mutable global read from a worker. The curved profile threads the SAME
		# feature pipeline (mountains/climate/biome) and folds across an edge — see _curved_profile.
		prof = _curved_profile(face, x, z)
	else:
		var fx := float(x)
		var fz := float(z)
		var c := _continent.get_noise_2d(fx, fz)
		var t := _temperature.get_noise_2d(fx, fz)
		var hh := _humidity.get_noise_2d(fx, fz)
		var g := _height_c(c, fx, fz)
		var mtn := _mountain_factor(c, fx, fz)
		prof = Vector4(float(g), float(_biome(c, t, hh, g, mtn)), c, t)
	if memo != null:
		memo[ck] = prof
	return prof

# ------------------------------------------------------------------------------
# COSMOS M1 — the curved face-window worldgen (docs/COSMOS-PLANET-TOPOLOGY.md §3.5). Only ever
# reached when CubeSphere.FLAT_WORLD is false; the flat path above is untouched (byte-identical).
#
# The domain adapter: a lattice column (face, i, j) maps to the unit direction d̂ =
# face_cell_to_dir(face, i, j) (§1.2), and every get_noise_2d(x, z) becomes get_noise_3d(d̂ · R) —
# seam-free 3D noise on the sphere (§3.5), sampled at the datum-surface block point R·d̂ so feature
# sizes match the flat world's per-block frequencies. The result feeds the SAME climate/biome/
# height pipeline (y ↦ r), so resolve_cell — bedrock, strata, ores, smoothing — is verbatim on the
# lattice coords (i, r, j). DETERMINISTIC: a pure function of (SEED, face, i, j) only (no window,
# no randi/Time). face_cell_to_dir is f64; FastNoiseLite quantizes to f32 internally (§8.2).

# COSMOS M3 (§4.5) — the ACTIVE home face for the 2-arg (x, z) curved queries. The choke point
# passes the true (folded) face explicitly to _curved_profile/generated_cell_global, but the
# analytic + main-thread-generated smoothing stencils reach worldgen through the 2-arg height_at/
# column_profile, which must follow the player when the home face flips (§4.5). WorldManager keeps
# this in sync with the chart's face (install/flip). FLAT_WORLD never reads it (default HOME_FACE).
static var _active_face := CubeSphere.HOME_FACE

## COSMOS frozen-epoch contract (docs/COSMOS-AUDIT.md §3.2 item 2, F1): the immutable per-generation
## snapshot the curved worldgen reads INSTEAD of the mutable global `_active_face`. It carries the cube
## face the query is homed on plus a per-pass column memo. A voxel worker builds ONE of these per
## `_generate_block` frame (LOCAL to that stack frame, never shared across threads) and threads it as
## the `pcache` argument through every column query; the curved branches then read `ctx.face` — a
## VALUE captured on the worker — so no worker ever reads the main-thread-mutated `_active_face`. The
## analytic main-thread path keeps passing a plain Dictionary / null and reads `_active_face` (which
## only the main thread ever mutates, on a home-face flip). This is the whole race fix: the face stops
## being a hidden mutable global on the worker hot path and becomes an immutable parameter.
class GenCtx extends RefCounted:
	var face: int = CubeSphere.HOME_FACE
	var memo: Dictionary = {}
	func _init(p_face: int = CubeSphere.HOME_FACE) -> void:
		face = p_face

## The active home face (read-only accessor).
static func active_face() -> int:
	return _active_face

## Set the active home face (called by WorldManager on chart install / home-face flip, §4.5). A
## real change CLEARS the per-column shape memo — its entries are keyed by column (i, j) for ONE
## face, so a stale face-A entry must not answer a face-B query after the flip (byte-identical
## behaviour: recomputing against the new face). No-op when the face is unchanged (zero cost).
static func set_active_face(f: int) -> void:
	if f == _active_face:
		return
	_active_face = f
	_shape_memo.clear()

## The per-column profile Vector4(g, biome, c, t) for lattice column (face, i, j) via 3D noise.
## COSMOS M3 (§4.3/§4.4): the direction is taken through LatticeNav, which FOLDS a column that has
## spilled past a face edge onto its true neighbour face before sampling d̂ — so a stencil that
## steps across an edge reads the real across-seam column and worldgen is seam-continuous (no
## cliff/gap at an edge). In-range (i, j) fold to the identity, so this is byte-identical to the
## M2 single-face profile there (verify-pinned).
static func _curved_profile(face: int, i: int, j: int) -> Vector4:
	_ensure_noise()
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var rr := float(CubeSphere.radius_for(CubeSphere.HOME_BODY))
	var d: CubeSphere.DVec3 = LatticeNav.dir_of(face, i, j, n)
	var px := d.x * rr
	var py := d.y * rr
	var pz := d.z * rr
	var c := _continent.get_noise_3d(px, py, pz)
	var t := _latitude_temperature(d.z, _temperature.get_noise_3d(px, py, pz))
	var hh := _humidity.get_noise_3d(px, py, pz)
	var mtn := _mountain_factor3(c, px, py, pz)
	var g := _height_c3(c, px, py, pz, mtn)
	# Feature worldgen on the sphere: the mountain factor feeds BOTH the biome (B_MOUNTAINS) and the
	# uplift baked into _height_c3, so a mountain-latitude column reaches mountain heights and reads as
	# rock; snow accumulation + sharp-slope then flow through resolve_cell exactly as in the flat world.
	return Vector4(float(g), float(_biome(c, t, hh, g, mtn)), c, t)

## Latitude climate (COSMOS §3.5: the `asin(d.z)` climate term). The spin axis is +Z, so the
## latitude is φ = asin(d.z) and |d.z| = |sin φ| runs 0 at the equator to 1 at a pole. The climate
## temperature `t` (the Vector4.w that drives biome selection AND PerVoxelEnvironment) is anchored
## to latitude — warm (+1) at the equator, cold (−1) at the poles (face-4/5 centres, §5.2) — and
## only gently perturbed by the low-frequency temperature noise so biomes still vary within a band.
## PURE + DETERMINISTIC: a function of (d.z, SEED noise) only, replacing the flat world's pure-noise
## `t`. LATITUDE_GAIN dominates so the profile is monotonic-ish in latitude (verify-pinned, §9 M2);
## NOISE_GAIN keeps enough spread that a pole reads frozen (t < −0.55) and the equator temperate.
const _LAT_GAIN := 0.80          # weight of the latitude term (dominant → monotonic-ish climate)
const _LAT_NOISE_GAIN := 0.30    # weight of the temperature noise (local variety within the band)
static func _latitude_temperature(dz: float, noise_t: float) -> float:
	var lat_term := 1.0 - 2.0 * absf(dz)        # +1 at the equator (|z|=0) … −1 at a pole (|z|=1)
	return clampf(_LAT_GAIN * lat_term + _LAT_NOISE_GAIN * noise_t, -1.0, 1.0)

## The 3D-noise twin of _height_c (§3.5): identical spline + shelf shaping, sampling hills/detail
## from get_noise_3d at the sphere point (px, py, pz) instead of get_noise_2d(fx, fz). `mtn` is the
## precomputed 3D mountain factor (0 outside mountain regions) so the CURVED world gains the SAME tall
## mountain uplift as the flat world (mirrors _height_c's `h += factor * MOUNTAIN_AMPLITUDE` line).
static func _height_c3(c: float, px: float, py: float, pz: float, mtn: float) -> int:
	var base := BASE_HEIGHT + _continent_offset(c)
	var hills := _hills.get_noise_3d(px, py, pz) * HILLS_AMPLITUDE
	var h := base + hills + _detail.get_noise_3d(px, py, pz) * DETAIL_AMPLITUDE
	var depth := float(SEA_LEVEL) - h
	var w := clampf(smoothstep(-SHELF_TOP, 0.5, depth) - smoothstep(SHELF_DEPTH - 1.5, SHELF_DEPTH, depth), 0.0, 1.0)
	if w > 0.0:
		h = lerp(h, base + hills * SHELF_HILLS_KEEP, w)
	# Mountains: tall inland uplift added AFTER the beach shelf (mountains gate on C_LO, so their shelf
	# `w` is 0 anyway). Exactly 0 outside mountain regions → those columns match the pre-mountain curve.
	h += mtn * MOUNTAIN_AMPLITUDE
	return int(floor(h))

## THE terrain-function adapter (§3.5): the PACKED generated cell for global lattice cell
## (face, i, j, r). In FLAT_WORLD mode `to_global` is the identity — window space (x, y, z) =
## (i, r, j) (§3.1) — so this is byte-identical to generated_cell(i, r, j). In curved mode it
## resolves the 3D-noise column profile for the given face and runs the verbatim per-cell pipeline
## on the lattice coords (i, r, j). This is the single choke point COSMOS §3.5 names.
static func generated_cell_global(face: int, i: int, j: int, r: int) -> int:
	if CubeSphere.FLAT_WORLD:
		return generated_cell(i, r, j)
	if not _ids_ready:
		_ensure_ids()
	# COSMOS frozen-epoch (F1/F2): thread the TRUE face through a GenCtx so every nested stencil / snow /
	# tree read inside resolve_cell folds neighbours on THIS cell's face (not the mutable `_active_face`).
	# The worker path (`_generate_block`) does the identical thing with its own frozen ctx, so a
	# module-generated cell is byte-identical to this analytic cell — render == physics across seams.
	var ctx := _acquire_ctx(face)
	var p := column_profile(i, j, ctx)
	return resolve_cell(i, r, j, int(p.x), int(p.y), p.z, p.w, ctx)

## A GenCtx for a single face-explicit query. On the main thread it reuses ONE cleared scratch context
## (no per-call allocation on the hot analytic cell path); off the main thread (e.g. a verify worker)
## it allocates a fresh one so the scratch is never shared across threads.
# Bound on the persistent analytic column memo (columns are Vector4, ~65k entries ≈ a few MB). When the
# player explores past this many distinct columns the memo is dropped and rebuilt; spatial locality means
# the working set (the near neighbourhood the player/collider/far-mesh sample each frame) is tiny, so the
# hit rate stays ~1.0 well under the cap.
const _ANALYTIC_MEMO_CAP := 1 << 16
static var _analytic_ctx: GenCtx = null
static func _acquire_ctx(face: int) -> GenCtx:
	if _on_main_thread():
		if _analytic_ctx == null:
			_analytic_ctx = GenCtx.new(face)
		else:
			# PERF (curved analytic hot path): PERSIST the per-column memo across calls. Worldgen is a pure
			# function of (face, i, j) and the memo key ENCODES the face (Vector3i(face, i, j)), so entries
			# are never stale and entries for different faces never collide. Clearing it every call (as
			# before) forced every generated_cell_global to recompute the full _curved_profile (~8× noise3d +
			# f64 direction math), so a single vertical column scan (surface_y, floor_under, collider, far
			# mesh) paid it once PER CELL instead of once per column. We do NOT clear on a face change —
			# seam-adjacent queries legitimately alternate between the home face and a neighbour face
			# (cell_value_at folds to g.face near an edge), and face-distinct keys let both coexist; clearing
			# there would thrash exactly at seams. Clear ONLY past the cap (bound memory). Output is
			# byte-identical — this removes redundant recomputation, nothing else. `face` is still assigned
			# every call so column_profile computes a MISSING entry against the correct face.
			if _analytic_ctx.memo.size() > _ANALYTIC_MEMO_CAP:
				_analytic_ctx.memo.clear()
			_analytic_ctx.face = face
		return _analytic_ctx
	return GenCtx.new(face)

## THE main-thread analytic column profile (PERF). Every main-thread curved query that needs a column
## profile — the 2-arg height_at, the far LOD mesh builder, the sim fields — must route through this so
## they SHARE the persistent per-column memo and never recompute _curved_profile for a column already
## resolved this frame (or a recent frame). FLAT_WORLD keeps the exact pre-COSMOS path (plain
## column_profile, no shared ctx) so the shipped flat game stays byte-identical in behaviour. Curved
## threads the shared _analytic_ctx (memoised, face-scoped key). Output is identical either way.
static func analytic_column_profile(x: int, z: int) -> Vector4:
	if CubeSphere.FLAT_WORLD:
		return column_profile(x, z)
	return column_profile(x, z, _acquire_ctx(_active_face))

## THE curved worker generator entry (COSMOS-AUDIT §3.2 items 2–3, F1/F2). The voxel worker calls this
## per column with its FROZEN home face `gen_face` (an immutable per-generator snapshot — NEVER the
## mutable `_active_face`) and the raw voxel column (vx, vz), which is the global home-face index
## column (the floating origin is folded into the terrain-node transform, §3.2). It FOLDS the column to
## its true global (face, i, j) ONCE via `ctx`, resolves it, and returns BOTH the profile (for the
## block's air/height early-outs) and the packed cell — hashing every position feature (bedrock, ore,
## strata, tree, smoothing) on the TRUE global column so it is window-independent and identical to the
## analytic generated_cell_global. `ctx.face` is set to the folded true face here; the caller reuses
## the same ctx (its memo is shared across the block, keyed by (face, i, j)).
static func worker_fold_column(gen_face: int, vx: int, vz: int, ctx: GenCtx) -> Vector3i:
	# COSMOS-CORNER-CANONICAL (#69): fold (gen_face, vx, vz) → the CANONICAL true global column, EXACTLY as
	# CosmosChart.to_global_column does for the analytic path (render == physics, rule 1). Single-edge
	# strips use the exact D4 fold; the corner quadrant resolves to the nearest REAL cell of its physical
	# direction (position-only, home-face-INDEPENDENT) instead of the old raw home-face overshoot — so the
	# wedge generates real neighbour terrain identically from any gen_face epoch (§8.2 restored). ctx.face
	# is always a real face now (never < 0), so every nested stencil/tree/snow read folds on the true face.
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var g := CubeSphere.fold_cell_canonical(gen_face, vx, vz, n)
	ctx.face = int(g["face"])
	return Vector3i(int(g["face"]), int(g["i"]), int(g["j"]))

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
static func resolve_cell(x: int, y: int, z: int, g: int, biome: int, c: float, t: float, pcache = null, slope_run: int = -1) -> int:
	if not _ids_ready:
		_ensure_ids()
	if y < WORLD_BOTTOM_Y:
		return BlockCatalog.AIR
	if _bedrock_at(x, y, z):
		return _ID_BEDROCK
	# SHARP-SLOPE §3.4: a steep SLOPE column carves/caps a vertical RUN [lo, hi−1] of SLOPE cells
	# (possibly reaching BELOW g and ABOVE g+1), replacing today's saturated hip-roof caps. The run
	# is gap-free by the clipped-plane construction; the column is solid from bedrock to the plane.
	# PERF (S1 throughput): the slope run is COLUMN-invariant (no y dependence), yet resolve_cell runs
	# once per y down a ~100-tall column — so the module worker HOISTS it, computing the packed run once
	# per column and passing it in via `slope_run` (>= 0). This kills a per-y _corner_targets noise
	# stencil + TreeGen.block_at tree-gate on every sub-surface cell. slope_run < 0 (the analytic path /
	# default) recomputes exactly as before → BYTE-IDENTICAL. A passed run decodes fires/targets from the
	# SAME pack the analytic memo + generated_modifier_at already round-trip through (verify-pinned;
	# SLOPE_MAX_SPREAD=3 ⇒ Tw−g ∈ [−3,4] ⊂ the pack's lossless [−4,11] → no clamp loss).
	var _slope_fires: bool
	var tw: Vector4i
	if slope_run >= 0:
		_slope_fires = slope_run_fires(slope_run)
		if _slope_fires:
			tw = _slope_run_targets(slope_run, g)
	else:
		_slope_fires = _slope_fires_only(x, z, g, pcache)
		if _slope_fires:
			tw = _slope_whole_targets(x, z, pcache)
	if _slope_fires:
		var lo := mini(mini(tw.x, tw.y), mini(tw.z, tw.w))
		var hi := maxi(maxi(tw.x, tw.y), maxi(tw.z, tw.w))
		if y >= lo and y <= hi - 1:
			var smod := CellCodec.make_slope(tw.x - y, tw.y - y, tw.z - y, tw.w - y)
			var smat: int
			if y >= g:
				smat = _cap_material(biome, x, z, t, g)         # surface/cap skin (biome top on land)
			else:
				smat = _surface_rule(x, y, z, g, biome, c, t)   # carve: generated banding, NO ore/deepslate
			return _with_snow_state(_with_shore_liquid(CellCodec.pack(smat, smod), y, t), g, t)
		if y >= hi:
			if y <= SEA_LEVEL:
				return _sea_block(t, y)
			return TreeGen.block_at(x, y, z, pcache)
		# y < lo: full solid interior below the run — the stackup, NO smoothing (the run owns the top)
		var idlo := _surface_rule(x, y, z, g, biome, c, t)
		if idlo == BlockCatalog.STONE and y < g:
			idlo = _deep_family(x, y, z)
			idlo = _ore_at(x, y, z, idlo, biome, c)
		return idlo
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
				# _surface_cap emits a smoothing lip (which gains the snow-cap STATE on a cold column).
				# The lip keeps PRIORITY over snow at g+1 (SNOW-ACCUMULATION §3.3), and Phase B fills the
				# lip's own remainder with the in-cell snow plane so a capped snowy slope reads continuous
				# (snow then stacks from g+2). Composed BESIDE _with_snow_state (one regime authority).
				return _with_lip_snow_fill(_with_snow_state(_with_shore_liquid(cap, y, t), g, t), x, z, g, t, pcache)
		# Snow accumulation (SNOW-ACCUMULATION Decision 3): on a COLD column the AIR cells above g fill
		# with snow up to the climate baseline — full snow_block cubes below, one fractional LAYER at the
		# top. Composed AFTER the cap check (the lip owns g+1) and BEFORE the sea/tree returns.
		var snow := _snow_stack(x, y, z, g, t, pcache)
		if snow != BlockCatalog.AIR:
			return snow
		# Above the solid ground: sea fill (g < y <= SEA_LEVEL) else the tree overlay.
		if y <= SEA_LEVEL:
			return _sea_block(t, y)
		return TreeGen.block_at(x, y, z, pcache)
	var id := _surface_rule(x, y, z, g, biome, c, t)
	# The stone -> deepslate/strata/ore rewrite applies to INTERIOR stone only (y < g). A B_MOUNTAINS
	# column tops with STONE at y == g (its cappable rock peak); guarding on `y < g` keeps that top a
	# PLAIN, cappable stone cell (a strata blob or surface ore would silently break its snow cap). This
	# is BYTE-IDENTICAL for every pre-existing biome — no _biome_top / _underwater_floor ever returns
	# STONE, so the y == g branch was never a stone cell before Mountains (only interior fill was).
	if id == BlockCatalog.STONE and y < g:
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
		# Snow-cap STATE (M1 ADR §2.3): composed OUTSIDE _with_shore_liquid on the surface cell.
		# A cold-enough cappable surface (surface_temperature < 0) gains the snow_capped bit; wet
		# shore composites and underwater columns are excluded (disjointness), so this is a no-op
		# for every temperate/wet column (byte-identical state axis). Phase B then buries the ramp's
		# remainder with the snow fill nibble (SNOW-ACCUMULATION §3.1) — closing the A2 lip↔snow gap so
		# SLOPED cold terrain reads as one continuous snow plane instead of a dry ramp under floating snow.
		return _with_surface_snow_fill(
			_with_snow_state(_with_shore_liquid(_smoothed_surface(x, z, g, id, pcache), y, t), g, t),
			x, z, g, t, pcache)
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

## Compose the snow-cap STATE (M1 ADR §2.3) onto a surface-appearance cell value `v` whose
## column surface is at `g`, climate `t`. THE one regime authority for the state axis (the
## `_with_shore_liquid` pattern), keyed on the column's SURFACE temperature: a cell is
## `snow_capped` iff ClimateModel.surface_temperature(g, t) < 0. The cap and melt predicates
## then share ONE zero crossing on ONE field (worldgen stamps `< 0`, the transition melts
## `>= 0`), so they agree at the boundary. Guards, in order:
##   * underwater column (g < SEA_LEVEL): no land cap;
##   * wet shore composite (liquid_field != 0): state ⊥ liquid at the stamping level (§1.6);
##   * material not declared cappable (state_mask_of(mat) & STATE_SNOW_CAPPED == 0): bare —
##     the catalog declaration is the one authority; stone IS now produced (B_MOUNTAINS tops columns
##     with stone, so high stone peaks cap), while snow_block/red_sand/mud stay excluded;
##   * warm surface (surface_temperature ≥ 0): bare.
## Any column that returns `v` unchanged keeps its byte-identical state-0 value. Reads only
## scalars already in resolve_cell → no extra noise sampling on the hot path.
static func _with_snow_state(v: int, g: int, t: float) -> int:
	if g < SEA_LEVEL:
		return v
	if CellCodec.liquid_field(v) != 0:
		return v
	var mat := CellCodec.mat(v)
	if BlockCatalog.state_mask_of(mat) & CellCodec.STATE_SNOW_CAPPED == 0:
		return v
	if ClimateModel.surface_temperature(g, t) >= 0.0:
		return v
	return CellCodec.with_state(v, CellCodec.STATE_SNOW_CAPPED)

## The SURFACE-cell snow fill (SNOW-ACCUMULATION Decision 2 / §3.1). On a cold column the ramp surface
## cell is BURIED: the snow plane sits at/above g+1 (the A2 snow surface = g+1 + D/10 ≥ g+1), so the
## ramp's whole remainder fills with snow (fill 10). This makes the walkable/rendered surface flush with
## the snow STACK that begins at g+1 — closing the A2 lip↔snow gap — while the snow-capped skin (already
## composed) shows on the ramp's exposed faces. No-op on a full-cube surface (modifier 0, no remainder;
## canonical would strip anyway) and on any warm/sea/tree-gated column (D == 0), so the non-snow world
## stays BYTE-IDENTICAL. canonical() keeps generated == canonical (a fill below the terrain min strips).
static func _with_surface_snow_fill(v: int, x: int, z: int, g: int, t: float, pcache) -> int:
	if CellCodec.modifier(v) == 0:
		return v
	if _snow_depth(x, z, g, t, pcache) <= 0:
		return v
	return CellCodec.canonical(CellCodec.with_snow_fill(v, 10))

## The smoothing-LIP snow fill (SNOW-ACCUMULATION §3.3): a cold lip (the g+1 corner-height cap) fills to
## the snow plane WITHIN its own cell — min(D, 10) tenths (D = the column snow depth in tenths above g+1)
## — so a capped snowy slope reads as one continuous plane and the snow stack above the lip starts from
## g+2. Partial when the snow is thin (the fringe), full (buried) when the plane clears the lip. No-op on
## a full-cube cap / warm column, and canonical() strips a fill ≤ the lip's own terrain minimum.
static func _with_lip_snow_fill(v: int, x: int, z: int, g: int, t: float, pcache) -> int:
	if CellCodec.modifier(v) == 0:
		return v
	var d := _snow_depth(x, z, g, t, pcache)
	if d <= 0:
		return v
	return CellCodec.canonical(CellCodec.with_snow_fill(v, mini(d, 10)))

# ------------------------------------------------------------------------------
# Snow accumulation baseline (SNOW-ACCUMULATION Decision 3). PURE SEED functions: the static snow
# depth is a deterministic function of climate + the smoothed terrain lattice, so the module worker
# (pcache != null), the analytic main-thread queries (pcache == null), the shape memo AND both render
# paths agree by construction, and re-running with the same SEED is byte-identical. The non-snow world
# stays BYTE-IDENTICAL: every function early-outs to 0/AIR unless surface_temperature(g, t) < 0.

## The column's total snow depth D in TENTHS above the solid top g (§3.2), or 0 when the column carries
## no snow. Gates, in order: the sea gate (no snow fill on underwater floors — the _with_snow_state
## guard), the temperature gate (D=0 unless surface_temperature < SNOW_T0 — the ONE authority the cap/
## melt share), and the tree gate (bare under a canopy). Then D = max(blanket, fill): a thin
## terrain-following crust, and a fill that converges low spots toward the slowly-varying snow plane P
## over the SNOW_REF_LATTICE-smoothed h_ref — the flatness term. `pcache` threads the shared height memo.
static func _snow_depth(x: int, z: int, g: int, t: float, pcache) -> int:
	if g < SEA_LEVEL:
		return 0                                      # no snow fill on underwater floors
	var ts := ClimateModel.surface_temperature(g, t)
	if ts >= SNOW_T0:
		return 0                                      # warm surface → no snow (temperate world byte-identical)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return 0                                      # bare under a tree canopy (the tree gate)
	var neg := -ts                                     # > 0 here
	var d_blanket := clampi(roundi(SNOW_BLANKET_PER_C * neg), 0, SNOW_BLANKET_MAX)
	var p := _h_ref(x, z, pcache) + 1.0 + minf(SNOW_FILL_PER_C * neg, 10.0 * float(SNOW_FILL_MAX_CELLS)) / 10.0
	var fill_blocks := clampf(p - float(g + 1), 0.0, float(SNOW_FILL_MAX_CELLS))
	var d_fill := roundi(fill_blocks * 10.0)
	return maxi(d_blanket, d_fill)

## The slowly-varying reference terrain height at (x,z): height_at bilinearly interpolated over a
## SNOW_REF_LATTICE lattice of samples (§3.2). Deterministic, 4 lattice height reads (memoized through
## the shared column_profile pcache when non-null), so a low spot's h_ref sits ABOVE its own g and the
## fill plane P rises above it — the mechanism that fills gullies flat while ridges keep only a blanket.
static func _h_ref(x: int, z: int, pcache) -> float:
	var l := SNOW_REF_LATTICE
	var x0 := floori(x / float(l)) * l
	var z0 := floori(z / float(l)) * l
	var x1 := x0 + l
	var z1 := z0 + l
	var h00 := float(_col_h(x0, z0, pcache))
	var h10 := float(_col_h(x1, z0, pcache))
	var h01 := float(_col_h(x0, z1, pcache))
	var h11 := float(_col_h(x1, z1, pcache))
	var tx := float(x - x0) / float(l)
	var tz := float(z - z0) / float(l)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

## The generated snow CELL at (x,y,z) above the solid top g of a cold column, or AIR when this cell holds
## no snow. Depth D (tenths) fills the air cells above g up to the plane [g+1, g+1+D/10]: a cell whose
## remaining depth ≥ 10 is a full snow_block cube (modifier 0), the fractional top is a snow LAYER
## (make_layer). resolve_cell handles the g+1 cap BEFORE this (the lip keeps priority), so on a capped
## column this is reached only for y ≥ g+2 — its `below` term then already accounts for the g+1 cell the
## lip occupies (the plane is absolute, so the stack above the lip is exactly the plane's remainder).
static func _snow_stack(x: int, y: int, z: int, g: int, t: float, pcache) -> int:
	var d := _snow_depth(x, z, g, t, pcache)
	if d <= 0:
		return BlockCatalog.AIR
	var remaining := d - (y - (g + 1)) * 10           # tenths of snow whose bottom is at/above this cell's floor
	if remaining <= 0:
		return BlockCatalog.AIR
	if remaining >= 10:
		return CellCodec.pack(_ID_SNOW, 0)             # a full snow cube
	return CellCodec.pack(_ID_SNOW, CellCodec.make_layer(remaining))   # the fractional top LAYER

## The column's snow byte (§3.4): (whole << 4) | top, where whole = D/10 (full snow cubes, 0..
## SNOW_FILL_MAX_CELLS) and top = D % 10 (the fractional top LAYER level, 0..9). The ONE shared predicate
## the memo and the worker-direct path both derive from, so they cannot diverge. 0 = no snow.
static func _snow_stack_byte(x: int, z: int, g: int, t: float, pcache) -> int:
	var d := _snow_depth(x, z, g, t, pcache)
	if d <= 0:
		return 0
	return ((d / 10) << 4) | (d % 10)

## The MODIFIER of the g+1 snow cell for a column with snow byte `byte` and NO smoothing lip (the uncapped
## case): a full snow cube (whole ≥ 1 ⇒ D ≥ 10) → 0; a fractional-only stack (top > 0) → make_layer(top);
## no snow → 0. Equals CellCodec.modifier(generated_cell(g+1)) by construction — the collider cheap-query
## contract for a snowy uncapped column (§3.4).
static func _cap_snow_modifier(byte: int) -> int:
	if ((byte >> 4) & 0xF) >= 1:
		return 0                                       # g+1 is a full snow cube (D >= 10)
	var top := byte & 0xF
	return CellCodec.make_layer(top) if top > 0 else 0

## The MODIFIER of the snow accumulation cell at height `y` (y >= g+1, no smoothing lip owning that y)
## over a column with snow byte `byte` and solid top `g` (SNOW-ACCUMULATION §3.4). The generalized form
## of _cap_snow_modifier for ANY stack height: the absolute snow plane is [g+1, g+1+D/10], so the cell's
## remaining depth is `D − (y − (g+1))·10` tenths — a full snow cube (≥ 10) → 0, the fractional top LAYER
## (1..9) → make_layer, none (≤ 0) → 0. Equals CellCodec.modifier(generated_cell(x,y,z)) on a snowy
## column (matches resolve_cell._snow_stack). y == g+1 reproduces _cap_snow_modifier(byte) exactly.
static func _snow_cell_modifier(byte: int, g: int, y: int) -> int:
	var d := ((byte >> 4) & 0xF) * 10 + (byte & 0xF)
	if d <= 0:
		return 0
	var remaining := d - (y - (g + 1)) * 10
	if remaining <= 0 or remaining >= 10:
		return 0                                       # no snow at this height, or a full snow cube
	return CellCodec.make_layer(remaining)             # the fractional top LAYER

## The collider's LIGHT snow query (§3.4): the column's snow stack packed as (capped << 8) | (whole << 4)
## | top — capped = a smoothing lip owns g+1 (snow then stacks from g+2), whole/top the full-cube count +
## fractional top LAYER level. 0 = no snow. NO generated_cell calls (the light-query family contract).
## Main thread with pcache == null reads the shape memo; a non-null pcache (the collider rebuild / worker)
## computes directly — both byte-identical (pure SEED functions).
static func snow_stack_at(x: int, z: int, pcache = null) -> int:
	if pcache == null and _on_main_thread():
		var e := _shape_entry(x, z)
		var byte: int = (e >> 32) & 0xFF
		if byte == 0:
			return 0
		var capped := 1 if (((e >> 24) & 0xFF) != 0) else 0
		return (capped << 8) | byte
	var g := _col_h(x, z, pcache)
	var byte2 := _snow_stack_byte(x, z, g, column_profile(x, z, pcache).w, pcache)
	if byte2 == 0:
		return 0
	var cm := 0
	if SMOOTHING_ENABLED and TreeGen.block_at(x, g + 1, z, pcache) == BlockCatalog.AIR:
		cm = _modifier_from_targets(_corner_targets(x, z, pcache), g + 1)
	return ((1 if cm != 0 else 0) << 8) | byte2

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
# SHARP-SLOPE worldgen (docs/SHARP-SLOPE.md §3): where the smoothed corner-target plane escapes the
# legacy 2-cell [g, g+2] window, a steep column becomes a SLOPE COLUMN — its corner targets quantize
# to WHOLE blocks (shared with neighbours → crack-free) and a vertical RUN of cells each carries a
# FAM SLOPE modifier (four signed whole-block corner deltas). ONE shared predicate _slope_entry_data
# feeds resolve_cell, the light queries and the memo, so memo == worker-direct by construction.

## The SLOPE emission predicate (SHARP-SLOPE §3.2) — pure/deterministic (height_at + TreeGen only),
## NON-ALLOCATING (bool, so the neighbour-fires stencil in _quantized_targets stays cheap on the hot
## worker/collider path). fires ⇒ the plane ESCAPES the legacy [g,g+2] window AND is encodable
## (spread ≤ SLOPE_MAX_SPREAD); below that the world stays byte-identical on today's smoothing path.
static func _slope_fires_only(x: int, z: int, g: int, pcache) -> bool:
	if not SMOOTHING_ENABLED or g < SEA_LEVEL:
		return false                                  # v1: land only; rides the smoothing path
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return false                                  # a tree rests here → keep the top FULL
	var raw := _corner_targets(x, z, pcache)
	# Which legacy smoothing window the corner-target plane ESCAPES decides firing (SHARP-SLOPE §3.2,
	# DEFECT 2 — "don't touch hills"). Compare raw targets in integer quarter-units (float-robust):
	#   * plane escapes the TWO-cell window [g, g+2] (a >2 block/cell face the legacy cap can't grade)
	#     → fire in ANY biome (the original predicate — steep relief, e.g. badlands mesa walls); else
	#   * plane escapes only the ONE-cell window [g, g+1] (the 1–2 block/cell, ~45° band) → fire ONLY
	#     in the Mountains biome. The half-block corner grid clamps a g+1.5 target down to g+1.0, so a
	#     >45° face develops a 0.5-block riser per cell — the mountain "ladder"/stacked-pyramid look
	#     the widening kills. Confining the widening to B_MOUNTAINS leaves every hill/temperate 45°
	#     step BYTE-IDENTICAL to the pre-widening build (whole-block quantization never reaches them).
	# The biome probe (column_profile.y) is reached ONLY for the narrow 1–2 block/cell band, so the hot
	# path stays cheap; it is pure + pcache-memoized, preserving the single-predicate collider contract.
	var r0 := roundi(raw.x * 4.0)
	var r1 := roundi(raw.y * 4.0)
	var r2 := roundi(raw.z * 4.0)
	var r3 := roundi(raw.w * 4.0)
	var lo_r := mini(mini(r0, r1), mini(r2, r3))
	var hi_r := maxi(maxi(r0, r1), maxi(r2, r3))
	if lo_r >= g * 4 and hi_r <= (g + 2) * 4:
		# within the two-cell window → NOT a >2 block/cell face.
		if lo_r >= g * 4 and hi_r <= (g + 1) * 4:
			return false                              # within [g, g+1] → today's smoothing (all biomes)
		if int(column_profile(x, z, pcache).y) != B_MOUNTAINS:
			return false                              # 1–2 block/cell band off the mountains → leave hills alone
	var tw0 := roundi(raw.x)
	var tw1 := roundi(raw.y)
	var tw2 := roundi(raw.z)
	var tw3 := roundi(raw.w)
	var lo := mini(mini(tw0, tw1), mini(tw2, tw3))
	var hi := maxi(maxi(tw0, tw1), maxi(tw2, tw3))
	if hi - lo < 1 or hi - lo > SLOPE_MAX_SPREAD:
		return false                                  # a flat plane (nothing to grade) OR too steep (cliff)
	# The run [lo, hi−1] must stay within [g−3, g+4] so (a) the memo's 4-bit (Tw−g) codes are EXACT
	# and (b) a lone spike/pit whose smoothed plane is far from its own surface falls back to legacy
	# saturation (a full cube) — never carved down into a hole. Steeper relief stays a blocky cliff.
	return lo >= g - SLOPE_MAX_SPREAD and hi <= g + SLOPE_MAX_SPREAD + 1

## The four WHOLE-block corner targets Tw of a firing SLOPE column (call only when _slope_fires_only).
static func _slope_whole_targets(x: int, z: int, pcache) -> Vector4i:
	var raw := _corner_targets(x, z, pcache)
	return Vector4i(roundi(raw.x), roundi(raw.y), roundi(raw.z), roundi(raw.w))

## True iff column (X, Z) is slope-EMITTING (its own predicate fires).
static func _col_fires(X: int, Z: int, pcache) -> bool:
	return _slope_fires_only(X, Z, _col_h(X, Z, pcache), pcache)

## The corner targets of cell (x, z) quantized on ONE shared grid (SHARP-SLOPE §3.1): whole-block at
## a corner touching a slope-emitting column, else half-block. Half-block quantization is a NO-OP
## through _modifier_from_targets (roundi((T−by)·2) already rounds to the half grid), so a cell with
## no slope-emitting neighbour is BYTE-IDENTICAL to today. The crack-killer for slope↔legacy seams.
## The 3×3 fires stencil (columns x−1..x+1 × z−1..z+1) is evaluated ONCE — each of the 4 corners is
## whole iff any of its 4 touching columns fires — so a rim cell pays 9 predicate evals, not 16.
static func _quantized_targets(x: int, z: int, pcache) -> Vector4:
	var raw := _corner_targets(x, z, pcache)
	var f := [
		_col_fires(x - 1, z - 1, pcache), _col_fires(x - 1, z, pcache), _col_fires(x - 1, z + 1, pcache),
		_col_fires(x,     z - 1, pcache), _col_fires(x,     z, pcache), _col_fires(x,     z + 1, pcache),
		_col_fires(x + 1, z - 1, pcache), _col_fires(x + 1, z, pcache), _col_fires(x + 1, z + 1, pcache)]
	# f[i*3 + j] is column (x−1+i, z−1+j). A corner is whole iff any of its 4 columns fires.
	var w00: bool = f[0] or f[3] or f[1] or f[4]      # corner (x,   z):   cols (x−1,z−1),(x,z−1),(x−1,z),(x,z)
	var w10: bool = f[3] or f[6] or f[4] or f[7]      # corner (x+1, z):   cols (x,z−1),(x+1,z−1),(x,z),(x+1,z)
	var w11: bool = f[4] or f[7] or f[5] or f[8]      # corner (x+1, z+1): cols (x,z),(x+1,z),(x,z+1),(x+1,z+1)
	var w01: bool = f[1] or f[4] or f[2] or f[5]      # corner (x,   z+1): cols (x−1,z),(x,z),(x−1,z+1),(x,z+1)
	return Vector4(_q(raw.x, w00), _q(raw.y, w10), _q(raw.z, w11), _q(raw.w, w01))

static func _q(raw_t: float, whole: bool) -> float:
	if whole:
		return float(roundi(raw_t))                   # whole block (shared, exact on the half grid)
	return roundf(raw_t * 2.0) / 2.0                  # half block (byte-identical to legacy)

## Pack a slope run for column consumers (collider/fallback/memo, SHARP-SLOPE §3.5): fires flag in
## bit 16, four 4-bit biased corner codes (Tw_i − g + 4) in bits 0..15 — enough to derive lo/hi and
## every run cell's modifier by arithmetic, no per-cell query storm. 0 when the column does not fire.
static func _slope_run_pack(fires: bool, tw: Vector4i, g: int) -> int:
	if not fires:
		return 0
	var c0 := clampi(tw.x - g + 4, 0, 15)
	var c1 := clampi(tw.y - g + 4, 0, 15)
	var c2 := clampi(tw.z - g + 4, 0, 15)
	var c3 := clampi(tw.w - g + 4, 0, 15)
	return (1 << 16) | (c3 << 12) | (c2 << 8) | (c1 << 4) | c0

## Decode the whole corner targets Tw from a packed slope run + the column's surface g.
static func _slope_run_targets(r: int, g: int) -> Vector4i:
	return Vector4i((r & 15) - 4 + g, ((r >> 4) & 15) - 4 + g, ((r >> 8) & 15) - 4 + g, ((r >> 12) & 15) - 4 + g)

## True iff a packed slope run is a firing column.
static func slope_run_fires(r: int) -> bool:
	return (r >> 16) & 1 != 0

## The [lo, hi) run cell range of a packed slope run given g (cells [lo, hi−1] carry slope material).
static func slope_run_range(r: int, g: int) -> Vector2i:
	var tw := _slope_run_targets(r, g)
	return Vector2i(mini(mini(tw.x, tw.y), mini(tw.z, tw.w)), maxi(maxi(tw.x, tw.y), maxi(tw.z, tw.w)))

## The generated SLOPE modifier of run `r` at world-y `y` (0 = full cube below the run / air above).
static func slope_run_modifier_at(r: int, g: int, y: int) -> int:
	var tw := _slope_run_targets(r, g)
	var lo := mini(mini(tw.x, tw.y), mini(tw.z, tw.w))
	var hi := maxi(maxi(tw.x, tw.y), maxi(tw.z, tw.w))
	if y >= lo and y <= hi - 1:
		return CellCodec.make_slope(tw.x - y, tw.y - y, tw.z - y, tw.w - y)
	return 0

## The packed slope run for column (x, z): the memo's slope bits on the analytic main thread, the
## shared predicate worker-direct (SHARP-SLOPE §3.5). ONE authority → memo == worker-direct.
static func slope_run_of(x: int, z: int, pcache = null) -> int:
	if not SMOOTHING_ENABLED:
		return 0
	if pcache == null and _on_main_thread():
		return (_shape_entry(x, z) >> 40) & 0x1FFFF
	var g := _col_h(x, z, pcache)
	if not _slope_fires_only(x, z, g, pcache):
		return 0
	return _slope_run_pack(true, _slope_whole_targets(x, z, pcache), g)

## THE generalized light query (SHARP-SLOPE §3.5): the generated cell's MODIFIER at ANY (x,y,z) —
## from the memo on the analytic main thread, from the shared predicate worker-direct — with ZERO
## generated_cell calls. Machine-checked == CellCodec.modifier(generated_cell(x,y,z)) (verify).
## surface_modifier / surface_cap_modifier are thin y=g / y=g+1 projections of this.
static func generated_modifier_at(x: int, y: int, z: int, pcache = null) -> int:
	if not SMOOTHING_ENABLED:
		return 0
	if pcache == null and _on_main_thread():
		var e := _shape_entry(x, z)
		var g := (e & 0xFFFF) - _MEMO_G_BIAS
		var r := (e >> 40) & 0x1FFFF
		if (r >> 16) & 1 != 0:
			return slope_run_modifier_at(r, g, y)     # slope run cell (0 outside [lo, hi−1])
		if y == g:
			return (e >> 16) & 0xFF                    # surface smoothing modifier
		if y >= g + 1:
			var cmm: int = (e >> 24) & 0xFF
			if y == g + 1 and cmm != 0:
				return cmm                             # the smoothing grass CAP lip owns g+1
			return _snow_cell_modifier((e >> 32) & 0xFF, g, y)   # snow accumulation cell (SNOW-ACCUMULATION §3.4)
		return 0
	# worker / other thread: direct compute (byte-identical to the memo — pure functions of SEED)
	var gg := _col_h(x, z, pcache)
	if _slope_fires_only(x, z, gg, pcache):
		return slope_run_modifier_at(_slope_run_pack(true, _slope_whole_targets(x, z, pcache), gg), gg, y)
	if TreeGen.block_at(x, gg + 1, z, pcache) != BlockCatalog.AIR:
		return 0
	if y == gg:
		return _modifier_from_targets(_quantized_targets(x, z, pcache), gg)
	if y >= gg + 1:
		if y == gg + 1:
			var cmw := _modifier_from_targets(_quantized_targets(x, z, pcache), gg + 1)
			if cmw != 0:
				return cmw                             # the smoothing grass CAP lip owns g+1
		return _snow_cell_modifier(_snow_stack_byte(x, z, gg, column_profile(x, z, pcache).w, pcache), gg, y)
	return 0

# ------------------------------------------------------------------------------
# Per-column SHAPE MEMO (analytic-path PERF, the smoothing-jerkiness fix). The analytic queries
# (WorldManager.floor_under/blocked → cell_value_at → generated_cell, pcache == null) hit a surface
# (y==g) or cap (y==g+1) cell on nearly every probe; each recomputes the 3×3 corner-target stencil
# = 9 height_at = 27 fresh noise samples (a surface cell measured 2.9 → 13.2 µs, 4.2×). While the
# player MOVES it fires ~6 such probes per tick → ms-scale on wasm → the "smoothing stutter". This
# memo caches, per column, the (g, surface_modifier, cap_modifier, snow_byte, slope_run) tuple — PURE
# functions of SEED (immutable at runtime; player edits live in the overlay, never in generated
# modifiers), so it is byte-identical to recomputing. Packed int: (g + _MEMO_G_BIAS) | surface_mod<<16
# | cap_mod<<24 | snow_byte<<32 | slope_run<<40. The two mods are BOTTOM corner-height codes < 256; g
# is biased so its low 16 bits stay positive. MERGE (SNOW-ACCUMULATION §3.4 + SHARP-SLOPE §3.5): bits
# 32..39 hold the snow accumulation byte ((whole<<4)|top) and bits 40..56 the packed SLOPE run (bit 56
# fires, 40..55 four biased corner codes) — DISJOINT axes (a firing slope column carries a run and no
# snow byte; a snow column carries a snow byte and no run), so no bit is ever read for both. The
# obsolete fixed snow-slab flag is GONE — graded snow accumulation supersedes it. M1 ADR §6.3: the cap
# byte / snow byte / run now depend on climate+altitude, but those are STILL pure deterministic
# functions of SEED (no randi/Time), so the memo remains byte-identical to recompute — the memo's old
# "shape is biome-independent" note is amended, but the thread-safety reasoning is unchanged.
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
	# MAIN-THREAD ONLY (the memo is a plain Dictionary — not thread-safe). Every caller already gates on
	# `pcache == null and _on_main_thread()`; this assert makes a violated invariant fail LOUDLY in a
	# debug/verify build instead of silently racing the Dictionary (COSMOS-AUDIT §3.2 items 4–5). The
	# voxel worker always threads a non-null GenCtx, so it never reaches this function.
	assert(_on_main_thread(), "TerrainConfig._shape_entry reached off the main thread — memo race")
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
	var snow_byte := 0
	var run := 0
	if SMOOTHING_ENABLED and TreeGen.block_at(x, g + 1, z) == BlockCatalog.AIR:
		# SHARP-SLOPE §3.5: a STEEP column emits a SLOPE run — cache its packed run in bits 40..56
		# (bit 56 = fires, bits 40..55 = four 4-bit biased corner codes); sm/cm stay 0 (the run owns
		# the shape). Else today's smoothing surface/cap on the shared whole/half-quantized target grid.
		if _slope_fires_only(x, z, g, null):
			run = _slope_run_pack(true, _slope_whole_targets(x, z, null), g)
		else:
			var t := _quantized_targets(x, z, null)   # the shared-grid stencil — computed ONCE, cached
			sm = _modifier_from_targets(t, g)
			cm = _modifier_from_targets(t, g + 1)
	# Snow accumulation byte (SNOW-ACCUMULATION §3.4): bits 32..39 = (whole << 4) | top — the column's
	# full-cube count + fractional top LAYER level above g (the fixed-slab bit is GONE; graded snow
	# accumulation supersedes it). Slope columns carry the run instead (they cap their own top), so snow
	# is computed only OFF the slope path (run == 0) — matching resolve_cell, which never stacks snow on a
	# slope column. Derived from the ONE shared _snow_stack_byte predicate (its sea/warm/tree gates make
	# it 0 on the non-snow world), pure SEED functions → byte-identical to a worker-direct recompute.
	if run == 0:
		snow_byte = _snow_stack_byte(x, z, g, column_profile(x, z).w, null)
	if _shape_memo.size() >= _MEMO_MAX:
		_shape_memo.clear()                 # bound memory over a marathon session
	e = (g + _MEMO_G_BIAS) | (sm << 16) | (cm << 24) | (snow_byte << 32) | (run << 40)
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
	var m := _modifier_from_targets(_quantized_targets(x, z, pcache), g)
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
		var e := _shape_entry(x, z)
		var cm := (e >> 24) & 0xFF
		return BlockCatalog.AIR if cm == 0 else CellCodec.pack(_cap_material(biome, x, z, t, g), cm)
	if TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
		return BlockCatalog.AIR                       # tree overlay owns this cell
	var m := _modifier_from_targets(_quantized_targets(x, z, pcache), g + 1)
	# No smoothing lip → AIR (resolve_cell then stacks the snow accumulation at g+1); a nonzero lip owns
	# the cell (snow stacks from g+2 on a capped column — SNOW-ACCUMULATION §3.3). The interim fixed snow
	# half-slab is GONE — graded snow accumulation (resolve_cell._snow_stack) supersedes it. _quantized_targets
	# (not raw _corner_targets) so a cap ADJACENT to a slope run snaps its shared corners whole → crack-free.
	return BlockCatalog.AIR if m == 0 else CellCodec.pack(_cap_material(biome, x, z, t, g), m)

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
	# SHARP-SLOPE §3.5: a thin y=g projection of generated_modifier_at (the ONE light query). On a
	# slope column this returns the run's surface-cell modifier; else today's smoothing modifier.
	return generated_modifier_at(x, _col_h(x, z, pcache), z, pcache)

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
	# A thin y=g+1 projection of the ONE light query generated_modifier_at (SHARP-SLOPE §3.5), now snow
	# aware (SNOW-ACCUMULATION §3.4): on a slope column it is the run's g+1 cell; on a smoothing column the
	# grass cap lip; else the snow accumulation cell (a full snow cube 0, a fractional LAYER, or nothing).
	# One authority so memo == worker-direct by construction; matches modifier(generated_cell(g+1)).
	return generated_modifier_at(x, _col_h(x, z, pcache) + 1, z, pcache)

## The appearance manifest (RUNTIME-MATERIAL-STREAMING §6.5 / VOXEL-DATA-STRUCTURE
## §8.1/§8.3): the exact set of (surface material, modifier) pairs this smoothing
## generator can emit. The module path pre-allocates + bakes + FREEZES their ARIDs at
## path activation (before the voxel worker runs), so the worker maps (mat, modifier) →
## ARID by reading a frozen array and never allocates or bakes a model itself.

## The surface materials smoothing can shape — every material `_biome_top` (land) OR
## `_underwater_floor` (WATER-SHORE §3: underwater floors now smooth too) can return.
## Gravel is the one `_underwater_floor` material not already a land top; sand/red_sand/
## mud are shared. The module bakes these × emitted_modifiers() at setup. STONE (the
## `_biome_top(B_MOUNTAINS)` rock peak) is DELIBERATELY excluded from the DRY set: a SNOW-CAPPED
## stone cell is baked via `_snow_arid` (snow_cappable_materials, so visible peaks smooth), while an
## UNCAPPED shaped stone cell (the bare lower flank, below the freeze line) cube-falls-back on the
## worker — a natural blocky-rock look, a documented graceful degrade (§5.5) that keeps the pre-baked
## model count (and web load pause) down and preserves stone's lazy-append path (_test_shapes_live).
static func appearance_surface_materials() -> PackedInt32Array:
	_ensure_ids()
	return PackedInt32Array([
		BlockCatalog.GRASS, _ID_SAND, _ID_RED_SAND, _ID_MUD, _ID_SNOW, _ID_PODZOL, _ID_GRAVEL,
		# STONE tops the Mountains biome (bare rock). Without it, the smoothing that shapes a
		# mountain's corner-height surface cells has no baked DRY model, so uncapped rock slopes
		# cube-fall-back and render BLOCKY while the analytic collider sees the smooth ramp — a
		# visible render/physics mismatch on the flanks below the snow line. Baking stone smooths
		# them (shape meshes are shared per-modifier across materials → +models, no new readbacks).
		BlockCatalog.STONE,
	])

## The BAKED snow-cap material set (M1 ADR §2.2, extended by the Mountains biome): the cappable surface
## materials the module path bakes a snow-VARIANT model for (cube + each emitted modifier). grass /
## podzol / sand top cold LOW columns; STONE now tops B_MOUNTAINS peaks (`_biome_top(B_MOUNTAINS)`), and
## those peaks cross the y=96 freeze line, so stone is a REAL cappable top — baking its snow variant is
## what makes high stone caps render WHITE (an unbaked cap would silently fall back to plain rock, §5.5).
## The STAMP gate is still the catalog declaration (state_mask_of & STATE_SNOW_CAPPED); this list only
## governs which variants get baked. Budget: 4 mats × (cube + ~emitted modifiers + slab) ≈ 170–250
## models, below the 280–420 manifest budget.
static func snow_cappable_materials() -> PackedInt32Array:
	_ensure_ids()
	return PackedInt32Array([BlockCatalog.GRASS, _ID_PODZOL, _ID_SAND, BlockCatalog.STONE])

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
	# COSMOS perf (curved-demo load stall): the spatial sample below runs find_spawn/find_coast/
	# find_mountains + several 160-radius height scans, each ~3× costlier in curved mode (every
	# height_at is a 3D-noise fold, and find_coast_of scans to radius 512/1024). It exists only to
	# catch stray corner modifiers, but the unconditional union of the FULL corner-tuple family +
	# the snow slab (below) is already a SUPERSET of everything it can find (every _modifier_from_
	# targets output is a member of appearance_modifiers()). So in curved mode we SKIP the sample
	# entirely — the emitted set is identical (union-dominated) and the ~6 s scan is gone. FLAT_WORLD
	# keeps the exact sample path → byte-identical.
	if CubeSphere.FLAT_WORLD:
		_sample_emitted(find_spawn(), _EMIT_SAMPLE_R, seen)      # inland land shapes
		_sample_emitted(find_coast(), _EMIT_SAMPLE_R, seen)      # coastline + underwater floor shapes (§3.5)
	# Mountains biome: its gently-sloped stone flanks emit corner-height modifiers NOT present in the
	# temperate spawn/coast samples — mountains alone reach ~60 of the 61 globally-emitted modifiers
	# (every gentle-slope orientation occurs). A snow-capped stone peak cell whose modifier is unbaked
	# would fall back to a plain cube: an INVISIBLE cap AND a lost shape (§5.5). So sample SEVERAL
	# angularly-spread mountain massifs — enough that emitted_modifiers() reaches the complete reachable
	# set (verify asserts a wide mountain scan emits NO modifier missing from this set). One-time setup
	# cost (main thread); never the voxel worker.
		for mc: Vector2i in find_mountains(6):
			_sample_emitted(mc, _EMIT_SAMPLE_R, seen)
	# The snow half-slab modifier (M1 ADR §6.4): worldgen emits (snow_block, 85) on deep-frozen
	# flats, but this spatial sample is temperate and won't contain 85 — union it in so the module
	# path always bakes (snow_block, 85) and (grass/sand/… , 85). A superset is always safe here.
	seen[SNOW_SLAB_MODIFIER] = true
	# The widened slope threshold (a slope >1 block/cell now emits SLOPE) leaves the ADJACENT legacy
	# cells with whole-block-quantized corner modifiers whose exact orientations a spatial sample can
	# miss — a missed one cube-falls-back (a stray pyramid). Union the FULL corner-height tuple set so
	# NO smoothed cell can ever fall back. +~18 unique meshes over the sample → a small one-time
	# main-thread bake cost, never the voxel worker.
	for m: int in appearance_modifiers():
		seen[m] = true
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
		B_MOUNTAINS:
			return BlockCatalog.STONE     # bare rock peak (cappable — declared in blocks.json + baked set)
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
		B_MOUNTAINS:
			return 0        # bare rock: no dirt filler, straight to stone/deepslate under the surface
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

## The nearest TALL B_MOUNTAINS column (a real peak, g well above sea) scanned outward from origin with
## the find_spawn pattern. Used ONLY at setup/verify (never the voxel worker) to seed emitted_modifiers()
## with the mountain-flank stone shapes so snow-capped peaks bake their variant models (visible caps).
## Mountains cover ~3% of the world for this seed, so the scan resolves quickly; the fallback (no
## mountain in range — not the case for this seed) re-samples spawn, which is harmless (superset-safe).
static func find_mountain() -> Vector2i:
	var ms := find_mountains(1)
	return ms[0] if ms.size() > 0 else find_spawn()

## Up to `count` DISTINCT tall B_MOUNTAINS massifs (peaks g > SEA_LEVEL + 40), one per angular sector,
## scanned outward from origin. Angularly spread + de-duplicated (>= 400 blocks apart) so the returned
## centres land on DIFFERENT massifs with different slope orientations — together their emitted-modifier
## sample reaches the complete reachable set (no invisible caps). Falls back to spawn if none found (not
## the case for this seed). Setup/verify only (calls column_profile widely); never the voxel worker.
static var _mountains_cache: Dictionary = {}          # count -> Array (pure deterministic; setup/verify only)
static func find_mountains(count: int) -> Array:
	if _mountains_cache.has(count):
		return _mountains_cache[count]
	var out := _find_mountains_scan(count)
	_mountains_cache[count] = out
	return out

static func _find_mountains_scan(count: int) -> Array:
	var out: Array = []
	for radius in range(0, 3072, 8):
		for a in range(0, 360, 6):
			var rad := deg_to_rad(float(a))
			var x := int(round(cos(rad) * float(radius)))
			var z := int(round(sin(rad) * float(radius)))
			var p := column_profile(x, z)
			if int(p.y) != B_MOUNTAINS or int(p.x) <= SEA_LEVEL + 40:
				continue
			var far := true
			for c: Vector2i in out:
				if Vector2(x - c.x, z - c.y).length() < 400.0:
					far = false
					break
			if far:
				out.append(Vector2i(x, z))
				if out.size() >= count:
					return out
	if out.is_empty():
		out.append(find_spawn())
	return out

## The nearest COLD LAND column — the first B_SNOWY surface above the sea, scanned outward from origin
## with the find_spawn pattern (SNOW-ACCUMULATION §2.7). Its region seeds emitted_cold_pairs() with the
## snow-fill composite pairs so the module path bakes them (else a filled ramp degrades to the M1 cap
## skin — never a hole). Setup/verify only (calls column_profile widely); never the voxel worker. Falls
## back to find_mountains(1)'s peak (always cold above the freeze line) then spawn if no snowy biome.
static func find_cold() -> Vector2i:
	_ensure_noise()
	for radius in range(0, 2048, 4):
		for a in range(0, 360, 15):
			var rad := deg_to_rad(float(a))
			var x := int(round(cos(rad) * float(radius)))
			var z := int(round(sin(rad) * float(radius)))
			var p := column_profile(x, z)
			if int(p.y) == B_SNOWY and int(p.x) >= SEA_LEVEL:
				return Vector2i(x, z)
	return find_mountain()

## The materials whose blocks.json state_layout DECLARES the snow-fill nibble (SNOW-ACCUMULATION §2.2):
## grass, stone, podzol, sand, snow_block. Only on these does a stamped fill survive canonicalization and
## reach physics (_occ_span reads snow_fill only after _validate_state masks undeclared bits), so ONLY
## these can render — or, when their composite is unbaked, FLOAT — a snow-fill COMPOSITE. Superset of
## snow_cappable_materials() by snow_block (whose own B_SNOWY ramps fill, but which is not a snow-CAP
## base). The module bakes this set × appearance_modifiers() × {3,5,8,10}. Keep in lockstep with the
## `state_layout` entries in blocks.json (verify pins the layout on exactly these five).
static func snow_fill_materials() -> PackedInt32Array:
	_ensure_ids()
	return PackedInt32Array([BlockCatalog.GRASS, BlockCatalog.STONE, _ID_PODZOL, _ID_SAND, _ID_SNOW])

## The COMPLETE, bounded set of (surface/cap material, corner modifier) pairs a SNOW-FILL composite can
## emit ANYWHERE in the infinite world (SNOW-ACCUMULATION §2.7), each encoded `mat * _SHORE_STRIDE +
## modifier` (the slot the module bake decodes). This REPLACES the earlier find_cold()+find_mountains(6)
## SPATIAL SAMPLE within `_EMIT_SAMPLE_R`: that sample baked only composites occurring inside those
## windows, so a cold (cap_material, cm) composite OUTSIDE them degraded on the module worker to the M1
## snow-cap skin (a white ramp with NO fill plane) while physics used the true fill nibble — the walkable
## snow surface then FLOATED up to ~0.9 block above the rendered ramp on any distant cold partial lip (a
## module-vs-fallback parity break: the fallback mesher dual-emits the fill plane unconditionally). The
## fix mirrors the DRY manifest's material × emitted_modifiers completeness and the sharp-slope
## enumeration: the FULL Cartesian product of snow_fill_materials() (the fill-carrying materials — the
## only ones that can float) × appearance_modifiers() (the complete 79-shape BOTTOM-anchored corner family
## the smoother can emit; every one is < 256, a dense slot). The bake consumer applies the four render
## levels {3,5,8,10} per pair. Bounded (5 × 79 = 395 pairs) and material-complete: every exposed
## partial-lip composite anywhere resolves to a baked model (render >= physics, never floating). Cached
## statically; main-thread setup/verify only, never the voxel worker.
static var _cold_pairs_ready := false
static var _cold_pairs := PackedInt32Array()
static func emitted_cold_pairs() -> PackedInt32Array:
	if not SMOOTHING_ENABLED:
		return PackedInt32Array()
	if _cold_pairs_ready:
		return _cold_pairs
	_ensure_ids()
	var out := PackedInt32Array()
	for mat: int in snow_fill_materials():
		for modifier: int in appearance_modifiers():
			out.append(mat * _SHORE_STRIDE + modifier)  # every modifier < 256 → a valid dense slot
	out.sort()
	_cold_pairs = out
	_cold_pairs_ready = true
	return _cold_pairs

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
	# COSMOS perf (curved-demo load stall): this spatial sample calls find_coast_of (a radius-512/1024
	# scan) + a 160-radius region scan, each ~3× costlier per column in curved mode, purely to catch
	# SHORE (level-9) composite pairs. The waterlog manifest ALSO unions emitted_submerged_pairs, which
	# is analytically material-complete (every fill material × the full corner family), so every real
	# co-filled cell still gets a baked twin without this sample; an unsampled shore pair degrades to
	# the dry border (a notch, never a hole). Skip it in curved mode (the pole home face has no nearby
	# unfrozen coast anyway → the scan finds none and wastes the full radius). FLAT keeps it exact.
	if not CubeSphere.FLAT_WORLD:
		_shore_pairs_by_kind[kind] = out
		return out
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

## Every canonical SLOPE payload worldgen can emit (SHARP-SLOPE §4.1 completeness, DEFECT 1 fix) —
## enumerated ANALYTICALLY, not spatially sampled, so NO emitted slope can cube-fall-back on the
## module (web) path (the pre-DEFECT sample of find_mountains(6)∪find_spawn() at r=32 baked ~83 of
## these and left ~25% of worldgen's real payloads unbaked → pyramids reappeared on far mountains).
## A run cell carries make_slope(Tw − y); across a run [lo, hi−1] its deltas span
## [−(SLOPE_MAX_SPREAD−1), SLOPE_MAX_SPREAD] with corner spread ≤ SLOPE_MAX_SPREAD (subtracting the
## per-cell y is spread-invariant). So enumerate EVERY delta tuple in that closed box with spread ≤
## SLOPE_MAX_SPREAD, canonicalize (rules 1/2/3 drop the full/empty/legacy-collapsible tuples — those
## are NOT slope cells), and keep the 12-bit payloads that stay SLOPE. Deterministic, biome/seed-
## independent, complete: 430 payloads for SLOPE_MAX_SPREAD = 3. Cached; main-thread setup/verify only.
const _SLOPE_STRIDE := 4096
static var _slope_payloads_ready := false
static var _slope_payloads := PackedInt32Array()
static func all_slope_payloads() -> PackedInt32Array:
	if _slope_payloads_ready:
		return _slope_payloads
	var seen := {}
	for d00 in range(-SLOPE_MAX_SPREAD, SLOPE_MAX_SPREAD + 1):
		for d10 in range(-SLOPE_MAX_SPREAD, SLOPE_MAX_SPREAD + 1):
			for d11 in range(-SLOPE_MAX_SPREAD, SLOPE_MAX_SPREAD + 1):
				for d01 in range(-SLOPE_MAX_SPREAD, SLOPE_MAX_SPREAD + 1):
					var mn := mini(mini(d00, d10), mini(d11, d01))
					var mx := maxi(maxi(d00, d10), maxi(d11, d01))
					if mx - mn > SLOPE_MAX_SPREAD:
						continue                          # steeper than a run cell can carry
					var m := CellCodec.make_slope(d00, d10, d11, d01)
					if CellCodec.is_slope(m):             # canonical: not full/empty/legacy-collapsed
						seen[m & 0xFFF] = true
	var out := PackedInt32Array()
	for p: int in seen.keys():
		out.append(p)
	out.sort()
	_slope_payloads = out
	_slope_payloads_ready = true
	return _slope_payloads

## Every SURFACE material worldgen can skin a SLOPE cell with (SHARP-SLOPE §4.1). A slope cell's
## material is the biome top skin (y ≥ g, via _cap_material → _biome_top, LAND biomes only since
## slopes are land-only, g ≥ SEA_LEVEL) or the carve banding (y < g, via _surface_rule → _biome_filler,
## depth ≤ 3). Land tops give GRASS / SAND / RED_SAND / MUD / SNOW / PODZOL / STONE (GRAVEL is
## underwater-only, so never a land slope skin); the carve adds DIRT (the default forest/taiga/snowy
## filler) and STONE (bare Mountains rock). The rare badlands terracotta / sandstone carve bands (a
## >2-block/cell badlands-wall edge, Risk 2) are left to the cube fallback to keep the bake bounded —
## the physics stays EXACT there (render-larger-than-physics, the benign direction).
static func all_slope_materials() -> PackedInt32Array:
	_ensure_ids()
	return PackedInt32Array([
		BlockCatalog.GRASS, BlockCatalog.DIRT, BlockCatalog.STONE,
		_ID_SAND, _ID_RED_SAND, _ID_MUD, _ID_SNOW, _ID_PODZOL,
	])

## The (surface material, SLOPE payload) pairs the module path pre-bakes + FREEZES into
## `_slope_arid`/`_snow_slope_arid` — the COMPLETE cross product `all_slope_materials() ×
## all_slope_payloads()` (SHARP-SLOPE §4.1, DEFECT 1). Encoded `mat * _SLOPE_STRIDE + payload`.
## Complete for every worldgen-reachable payload on every dense slope skin, so no generated slope
## cell (mountains especially) silhouette-mismatches the collider by cube-falling-back. Cached;
## main-thread setup/verify only.
static var _slope_pairs_ready := false
static var _slope_pairs := PackedInt32Array()
static func emitted_slope_pairs() -> PackedInt32Array:
	if not SMOOTHING_ENABLED:
		return PackedInt32Array()                     # diagnostic: no slope meshes to bake
	if _slope_pairs_ready:
		return _slope_pairs
	_ensure_ids()
	var payloads := all_slope_payloads()
	var out := PackedInt32Array()
	for mat: int in all_slope_materials():
		for p: int in payloads:
			out.append(mat * _SLOPE_STRIDE + p)
	out.sort()
	_slope_pairs = out
	_slope_pairs_ready = true
	return _slope_pairs
