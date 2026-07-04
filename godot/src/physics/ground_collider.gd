class_name GroundCollider
extends StaticBody3D
## Physics collision for the terrain around the player, so voxel bodies (falling /
## pushed blocks) rest on and collide with the ground. The rendered terrain
## (godot_voxel or the GDScript fallback) has no colliders — the player moves and
## raycasts analytically — so this is the ONE piece of real terrain collision,
## kept small and local for cheapness. The player never touches it (its movement
## is analytic); it exists purely for the rigid bodies.
##
## It is a TRUE VOXEL collider: for every column in a region around the player we
## emit one box per CONTIGUOUS RUN of solid, non-broken cells. A plain column is a
## single tall box; a column with a horizontal tunnel dug through it becomes TWO
## boxes (floor run + ceiling run) with a real air gap between — so a block dropped
## over a tunnel falls INTO it instead of resting on a phantom shelf. (An earlier
## HeightMapShape stored one height per column and physically could not represent a
## tunnel; a per-quad trimesh hits Godot's "internal edge" fall-through bug. Convex
## boxes avoid both problems.)
##
## Shapes are attached directly to the body via PhysicsServer3D (one shared body,
## no per-box nodes) so rebuilds — on an 8-block move or a terrain edit — stay
## cheap even though there are ~R² boxes.

const R := 14                # region half-extent in columns (covers +/-14 blocks)
const REBUILD_DIST := 8       # rebuild once the player drifts this far from centre
const DEPTH := 32             # emit solid this far below the region's lowest surface

const GROUND_FRICTION := 0.6  # grippy enough that dropped pieces rest, not slide
const GROUND_BOUNCE := 0.0    # no bouncing off the terrain

var world: WorldManager
var _center := Vector2i(0x7fffffff, 0)   # force first build
# Pool of box shapes reused across rebuilds (resized in place) so a rebuild does
# no allocation — only PhysicsServer re-attach. Grows to the peak box count.
var _pool: Array[BoxShape3D] = []
var _used := 0                            # boxes attached this rebuild

func setup(world_ref: WorldManager) -> void:
	world = world_ref
	collision_layer = 1 << 0    # terrain ground layer
	collision_mask = 0          # static; it does not need to detect anything
	# The body stays at the origin; box transforms carry absolute world positions.
	global_position = Vector3.ZERO
	var pm := PhysicsMaterial.new()
	pm.friction = GROUND_FRICTION
	pm.bounce = GROUND_BOUNCE
	physics_material_override = pm

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

## Re-attach the shapes if we re-enter the tree. Server-added shapes on a node
## body are cleared by Godot on tree exit; if this collider is ever reparented,
## rebuild so bodies don't fall through until the next move/edit. (First ENTER_TREE
## runs before setup(), when world is null, so it safely no-ops then.)
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE and world != null and _center.x != 0x7fffffff:
		_rebuild()

func _rebuild() -> void:
	if world == null:
		return
	var rid := get_rid()
	PhysicsServer3D.body_clear_shapes(rid)
	_used = 0

	var span := 2 * R + 1
	var x0 := _center.x - R
	var z0 := _center.y - R

	# Cache column heights once (height_at re-evaluates noise, so don't call twice)
	# and find the lowest surface → how deep to make the solid floor.
	var heights := PackedInt32Array()
	heights.resize(span * span)
	var min_h := 0x7fffffff
	for i in span:
		for j in span:
			var h := TerrainConfig.height_at(x0 + i, z0 + j)
			heights[i * span + j] = h
			if h < min_h:
				min_h = h
	var y_lo := min_h - DEPTH

	# One box per contiguous run of solid, non-broken cells in each column.
	for i in span:
		var x := x0 + i
		for j in span:
			var z := z0 + j
			var h := heights[i * span + j]
			# Start at y_lo, but if the player dug a shaft deeper than DEPTH below the
			# region's lowest surface, descend to the true solid floor so the shaft
			# still gets a floor box. Only deep-dug columns pay for this loop.
			var y := y_lo
			while world.is_removed(Vector3i(x, y, z)):
				y -= 1
			var run_start := 0x7fffffff
			while y <= h:
				# y <= h ⇒ the heightmap fills this cell; it is air only if broken out.
				if world.is_removed(Vector3i(x, y, z)):
					if run_start != 0x7fffffff:
						_add_box(rid, x, z, run_start, y)   # run [run_start, y-1] → [run_start, y]
						run_start = 0x7fffffff
				elif run_start == 0x7fffffff:
					run_start = y
				y += 1
			# Continue ABOVE the heightmap for tree cells (trunk/canopy) and placed
			# blocks, using the composed cell query. A run left open at the surface
			# (grass top) merges straight into a trunk/placed block sitting on it.
			var y_top := maxi(h + TreeGen.MAX_ABOVE_SURFACE, world.placed_top(x, z))
			while y <= y_top:
				if world.block_id_at(Vector3i(x, y, z)) != 0:
					if run_start == 0x7fffffff:
						run_start = y
				elif run_start != 0x7fffffff:
					_add_box(rid, x, z, run_start, y)
					run_start = 0x7fffffff
				y += 1
			if run_start != 0x7fffffff:
				_add_box(rid, x, z, run_start, y_top + 1)   # top run (surface / tree / tower)

## Attach one box covering the solid cells [y_bottom, y_top-1] of column (x, z),
## i.e. the world volume [y_bottom, y_top]. Reuses a pooled BoxShape (resized in
## place) so a rebuild allocates nothing. Translation-only transform → no scaled
## collision shapes.
func _add_box(rid: RID, x: int, z: int, y_bottom: int, y_top: int) -> void:
	var box: BoxShape3D
	if _used < _pool.size():
		box = _pool[_used]
	else:
		box = BoxShape3D.new()
		_pool.append(box)
	box.size = Vector3(1.0, float(y_top - y_bottom), 1.0)
	_used += 1
	var t := Transform3D(Basis(), Vector3(x + 0.5, (float(y_bottom) + float(y_top)) * 0.5, z + 0.5))
	PhysicsServer3D.body_add_shape(rid, box.get_rid(), t)
