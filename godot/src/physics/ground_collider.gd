class_name GroundCollider
extends StaticBody3D
## Physics collision for the terrain around the player, so voxel bodies (falling /
## pushed wooden blocks) rest on and collide with the ground. The rendered terrain
## (godot_voxel or the GDScript fallback) has no colliders — the player moves and
## raycasts analytically — so this is the ONE piece of real terrain collision,
## kept small and local for cheapness.
##
## It is a single HeightMapShape3D covering a square region centred on the player.
## We deliberately use a heightfield, NOT a per-quad trimesh: a ConcavePolygonShape
## built from thousands of 1x1 quads has an "internal edge" problem — resting
## bodies fall through the seams between triangles. A HeightMapShape is a single
## seam-free surface, so pieces rest on it reliably. Sample heights come from
## WorldManager.effective_height (the noise heightmap MINUS blocks the player has
## broken), so a dug-out pit becomes a dip a block can settle into.
##
## Trade-off: a heightfield interpolates smoothly between samples, so tall steps
## read as short ramps rather than crisp voxel walls. On the gentle shallow hills
## this is invisible (the collider is not drawn) and worth it for rock-solid
## resting. The player never touches this collider (its movement is analytic); it
## exists purely for the wooden bodies.

const REGION := 65            # heightmap sample grid is REGION x REGION (odd -> centred)
const HALF := (REGION - 1) / 2
const REBUILD_DIST := 8       # rebuild once the player drifts this far from centre

const GROUND_FRICTION := 0.6  # grippy enough that dropped pieces rest, not slide
const GROUND_BOUNCE := 0.0    # no bouncing off the terrain

var world: WorldManager
var _shape: HeightMapShape3D
var _center := Vector2i(0x7fffffff, 0)   # force first build

func setup(world_ref: WorldManager) -> void:
	world = world_ref
	collision_layer = 1 << 0    # terrain ground layer
	collision_mask = 0          # static; it does not need to detect anything
	# No-bounce, medium-friction ground so dropped voxel pieces come to rest and
	# don't slide or bounce weirdly on impact.
	var pm := PhysicsMaterial.new()
	pm.friction = GROUND_FRICTION
	pm.bounce = GROUND_BOUNCE
	physics_material_override = pm
	_shape = HeightMapShape3D.new()
	_shape.map_width = REGION
	_shape.map_depth = REGION
	var cs := CollisionShape3D.new()
	cs.shape = _shape
	add_child(cs)

## Follow the player; rebuild when they cross out of the current region's core.
func update(player_pos: Vector3) -> void:
	var c := Vector2i(int(floor(player_pos.x)), int(floor(player_pos.z)))
	if absi(c.x - _center.x) < REBUILD_DIST and absi(c.y - _center.y) < REBUILD_DIST:
		return
	_center = c
	_rebuild()

## Rebuild in place (call after a terrain block is broken inside the region).
func rebuild_now() -> void:
	if _center.x != 0x7fffffff:
		_rebuild()

func _rebuild() -> void:
	if world == null:
		return
	# The heightfield is centred on the body origin, samples spaced 1 unit apart.
	# Place the body at the integer centre column so every grid vertex lands on an
	# integer world column, and fill each vertex with that column's walkable top
	# (effective height + 1). Body y stays 0, so stored heights ARE world y.
	global_position = Vector3(float(_center.x), 0.0, float(_center.y))
	var data := PackedFloat32Array()
	data.resize(REGION * REGION)
	for j in REGION:
		var wz := _center.y + j - HALF
		for i in REGION:
			var wx := _center.x + i - HALF
			data[j * REGION + i] = float(world.effective_height(wx, wz) + 1)
	_shape.map_data = data
