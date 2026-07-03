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
## breakable blocks — plays out on near-flat, walkable ground). Heights stay well
## below the snowline, so the world is uniformly grass. Deterministic (fixed
## seeds); infinite/streaming.

const SEED := 20260702

# --- gentle, shallow base hills ------------------------------------------------
const BASE_HEIGHT := 5.0        # average ground height
const HILLS_AMPLITUDE := 3.0    # shallow rolling hills (open, walkable)
const DETAIL_AMPLITUDE := 1.0   # small-scale bumpiness on top

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

## Surface height (integer y of the topmost surface block) at world column (x, z).
static func height_at(x: int, z: int) -> int:
	_ensure_noise()
	var fx := float(x)
	var fz := float(z)

	# Gentle, open, shallow base hills + a touch of fine bumpiness.
	var h := BASE_HEIGHT + _hills.get_noise_2d(fx, fz) * HILLS_AMPLITUDE
	h += _detail.get_noise_2d(fx, fz) * DETAIL_AMPLITUDE
	return int(floor(h))

## True when cell (x, y, z) is solid; false for air.
static func is_solid(x: int, y: int, z: int) -> bool:
	return y <= height_at(x, z)

## Convenience: solidity from a world-space position (floored to a cell).
static func is_solid_pos(p: Vector3) -> bool:
	return is_solid(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
