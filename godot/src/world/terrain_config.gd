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
## (grass) when y <= height_at(x, z); everything above is air. The world is a
## pure heightmap (no overhangs), which lets the player and raycasts stay fully
## analytic and cheap on the web.

## World generation seed.
const SEED := 20260702

## Vertical span of the hills, in metres, above/below the base line.
const AMPLITUDE := 14.0

## Base ground height (the y of the average surface).
const BASE_HEIGHT := 8.0

## Render radius around the player, in blocks (DESIGN §1).
const RENDER_RADIUS_BLOCKS := 256

## Chunk edge length in voxels for the fallback streamer.
const CHUNK_SIZE := 32

# Lazily-created noise stack shared by every consumer.
static var _noise: FastNoiseLite
static var _detail: FastNoiseLite

static func _ensure_noise() -> void:
	if _noise != null:
		return
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = SEED
	_noise.frequency = 0.0125            # broad rolling hills (~80 m features)
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = 0.5

	_detail = FastNoiseLite.new()
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail.seed = SEED + 7919
	_detail.frequency = 0.05             # small-scale bumpiness

## Surface height (integer y of the topmost grass block) at world column (x, z).
static func height_at(x: int, z: int) -> int:
	_ensure_noise()
	var h := BASE_HEIGHT
	h += _noise.get_noise_2d(float(x), float(z)) * AMPLITUDE
	h += _detail.get_noise_2d(float(x), float(z)) * 2.0
	return int(floor(h))

## True when cell (x, y, z) is grass (solid); false for air.
static func is_solid(x: int, y: int, z: int) -> bool:
	return y <= height_at(x, z)

## Convenience: solidity from a world-space position (floored to a cell).
static func is_solid_pos(p: Vector3) -> bool:
	return is_solid(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
