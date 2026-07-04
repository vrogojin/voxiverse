class_name TerrainConfig
extends RefCounted
## Single source of truth for the world's shape.
##
## Both the pure-GDScript fallback mesher AND the godot_voxel module generator
## build the terrain from these functions, and the per-voxel environment model
## and the player's analytic ground/ray logic sample the same functions. This is
## what keeps "the world" one concept regardless of which rendering path runs.
##
## Convention: 1 voxel = 1 metre. A voxel at integer cell (x, y, z) is SOLID
## when y <= height_at(x, z); everything above is air. The world is a pure
## heightmap (no overhangs), which keeps the player and raycasts fully analytic.
## Because every column is solid all the way down, the ground is NOT hollow: dig
## a block out from under yourself and there is always another block beneath.
##
## Shape is intentionally CALM now: gentle, open, shallow rolling hills only (the
## craggy mountain archipelagos were removed so the physics sandbox — falling and
## breakable blocks — plays out on near-flat, walkable ground). The world is
## uniformly grass. Deterministic (fixed seeds); infinite/streaming.

const SEED := 20260702

# --- gentle, shallow base hills ------------------------------------------------
const BASE_HEIGHT := 5.0        # average ground height
const HILLS_AMPLITUDE := 3.0    # shallow rolling hills (open, walkable)
const DETAIL_AMPLITUDE := 1.0   # small-scale bumpiness on top

# --- stone layer (its OWN, decorrelated relief) --------------------------------
const STONE_BASE := 3.0         # average stone-surface height
const STONE_AMPLITUDE := 3.5    # stone's own hills
const DIRT_MIN_DEPTH := 3       # stone top is at least this far below the grass top

## Render radius around the player, in blocks (DESIGN §1). Drives the fallback
## chunk radius and the fog reference distance.
const RENDER_RADIUS_BLOCKS := 256

## The godot_voxel viewer streams a (vertically stretched) sphere. The terrain is
## now shallow, so no vertical stretch is needed — keep it at 1.0.
const VIEWER_VERTICAL_RATIO := 1.0

## Chunk edge length in voxels for the fallback streamer.
const CHUNK_SIZE := 32

# Lazily-created noise stack shared by every consumer.
static var _hills: FastNoiseLite     # gentle base terrain
static var _detail: FastNoiseLite    # small-scale bumpiness
static var _stone: FastNoiseLite     # stone surface, own relief (decorrelated)

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

	# Decorrelated from _hills in BOTH seed and frequency, so stone hills do not
	# coincide with grass hills — the stone surface follows its own relief.
	_stone = FastNoiseLite.new()
	_stone.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_stone.seed = SEED + 4443
	_stone.frequency = 0.017
	_stone.fractal_type = FastNoiseLite.FRACTAL_FBM
	_stone.fractal_octaves = 2
	_stone.fractal_gain = 0.5

## Surface height (integer y of the topmost surface block) at world column (x, z).
static func height_at(x: int, z: int) -> int:
	_ensure_noise()
	var fx := float(x)
	var fz := float(z)

	# Gentle, open, shallow base hills + a touch of fine bumpiness.
	var h := BASE_HEIGHT + _hills.get_noise_2d(fx, fz) * HILLS_AMPLITUDE
	h += _detail.get_noise_2d(fx, fz) * DETAIL_AMPLITUDE
	return int(floor(h))

## Raw stone-surface height from stone's OWN noise, BEFORE the grass clamp
## (ranges ≈ -1..6). generated_block clamps this to at least DIRT_MIN_DEPTH below
## the grass top, so stone never pokes through the dirt band.
static func stone_height_at(x: int, z: int) -> int:
	_ensure_noise()
	return int(floor(STONE_BASE + _stone.get_noise_2d(float(x), float(z)) * STONE_AMPLITUDE))

## Pure generation (no edits): which block id the WORLD GENERATOR puts at (x,y,z).
## THE terrain function — both render paths, the analytic queries, the collider
## and the collapse pass all derive from it, so they agree by construction.
## Per column: grass ONLY at the surface cell y==g; a dirt band of thickness >= 2
## between grass and stone_top = min(stone_height, g-3); stone all the way down
## (columns are never hollow); wood/leaf trees above the surface.
static func generated_block(x: int, y: int, z: int) -> int:
	var g := height_at(x, z)
	if y > g:
		return TreeGen.block_at(x, y, z)            # wood/leaf above the surface, else AIR
	if y == g:
		return BlockCatalog.GRASS                    # grass ONLY at the surface cell
	var stone_top := mini(stone_height_at(x, z), g - DIRT_MIN_DEPTH)
	return BlockCatalog.STONE if y <= stone_top else BlockCatalog.DIRT

## True when cell (x, y, z) is solid; false for air. Now the composed terrain +
## tree query, so tree cells are solid for every existing consumer (floor,
## blocked, DDA, collider). height_at keeps its meaning (grass heightmap top).
static func is_solid(x: int, y: int, z: int) -> bool:
	return generated_block(x, y, z) != BlockCatalog.AIR

## Convenience: solidity from a world-space position (floored to a cell).
static func is_solid_pos(p: Vector3) -> bool:
	return is_solid(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
