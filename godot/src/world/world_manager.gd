class_name WorldManager
extends Node3D
## Owns "the world": picks the rendering path, drives streaming, and exposes the
## analytic queries (solidity, surface height, voxel raycast) that the player and
## HUD use regardless of path. Also holds the decoupled sim layer (material
## registry + per-voxel environment) so gameplay reads simulation, not geometry.
##
## Path selection (DESIGN §2): if the Zylann godot_voxel module is compiled into
## the running engine (ClassDB has VoxelTerrain), use it; otherwise fall back to
## the pure-GDScript chunk streamer. Both render the same infinite grass hills
## from TerrainConfig, so everything downstream is identical.

signal path_selected(using_module: bool)

var environment: PerVoxelEnvironment
var materials: MaterialRegistry
var using_module: bool = false

var _grass_material: StandardMaterial3D
var _snow_material: StandardMaterial3D
var _streamer: ChunkStreamer          # fallback path
var _module_world: Node3D             # godot_voxel path
var _ground: GroundCollider           # local blocky physics collider

# Terrain edit overlay: cells the player has broken out of the heightmap. This is
# the gameplay source of truth (floor + raycast consult it); each render path
# mirrors it (godot_voxel carves via VoxelTool, the fallback remeshes the chunk).
var _removed: Dictionary = {}         # Vector3i -> true

func _ready() -> void:
	environment = PerVoxelEnvironment.new()
	materials = MaterialRegistry.build_default()
	SurfaceModel.ensure_ready()
	_grass_material = GrassMaterial.build()
	_snow_material = GrassMaterial.build_snow()

	if ClassDB.class_exists("VoxelTerrain"):
		_setup_module_path()
	if not using_module:
		_setup_fallback_path()

	# Local terrain physics collider (both render paths are collider-less).
	_ground = GroundCollider.new()
	_ground.name = "GroundCollider"
	add_child(_ground)
	_ground.setup(self)

	path_selected.emit(using_module)
	print("[WorldManager] rendering path: ",
		"godot_voxel module" if using_module else "GDScript fallback")

func _setup_module_path() -> void:
	# module_world.gd touches godot_voxel only via ClassDB/strings and a
	# runtime-compiled generator, so loading it is safe even when the module is
	# absent (it just returns false from setup()).
	var script: Script = load("res://src/world/voxel_module/module_world.gd")
	if script == null:
		return
	var world := script.new() as Node3D
	add_child(world)
	if world.call("setup", _grass_material, _snow_material):
		_module_world = world
		using_module = true
	else:
		world.queue_free()

func _setup_fallback_path() -> void:
	_streamer = ChunkStreamer.new()
	_streamer.name = "ChunkStreamer"
	add_child(_streamer)
	_streamer.setup(_grass_material, _snow_material, self)

## Called once the player exists (module path attaches its VoxelViewer here).
func on_player_ready(player: Node3D) -> void:
	if using_module and _module_world != null:
		_module_world.call("attach_viewer", player)

## Called every frame with the player's world position (fallback streaming +
## keeping the local ground collider centred on the player).
func update_streaming(player_pos: Vector3) -> void:
	if _streamer != null:
		_streamer.update_center(player_pos)
	if _ground != null:
		_ground.update(player_pos)

# --- terrain editing (block breaking) ------------------------------------------

## True if cell has been broken out of the terrain heightmap.
func is_removed(cell: Vector3i) -> bool:
	return _removed.has(cell)

## Topmost still-solid column height at (x, z): the noise height, lowered past any
## blocks the player has broken from the top. Because every column is solid all
## the way down, this always finds a block — the ground is never hollow.
func effective_height(x: int, z: int) -> int:
	var h := TerrainConfig.height_at(x, z)
	while _removed.has(Vector3i(x, h, z)):
		h -= 1
	return h

## Break the terrain voxel at `cell`. Returns true if a solid block was removed.
## Mirrors the edit into the active render path and refreshes ground collision.
func break_terrain(cell: Vector3i) -> bool:
	if _removed.has(cell) or not TerrainConfig.is_solid(cell.x, cell.y, cell.z):
		return false
	_removed[cell] = true
	if using_module and _module_world != null:
		_module_world.call("remove_voxel", cell)
	elif _streamer != null:
		_streamer.remesh_cell(cell)
	if _ground != null:
		_ground.rebuild_now()
	return true

# --- analytic world queries (path-agnostic) ------------------------------------

## Walkable surface height (world y of the top of the ground) at (x, z), accounting
## for broken blocks from the TOP — used for spawning pillars and the grounded test.
func surface_y(x: float, z: float) -> float:
	return float(effective_height(int(floor(x)), int(floor(z))) + 1)

## Analytic step height: the player can walk UP a step this tall (≈ one block).
const STEP_UP := 1.1

## The y the player should stand at in column (x, z) given their current feet
## height. Unlike surface_y (always the column TOP), this scans DOWNWARD from just
## above the feet for the first solid, non-broken block — so the player can descend
## into a pit or shaft they dug and walk INTO a tunnel, instead of being snapped
## back up to the original surface. Blocks whose top is more than STEP_UP above the
## feet (walls, tunnel ceilings) are never treated as floor, so you don't teleport
## up onto them. Ground is solid all the way down, so this always finds a floor.
func floor_under(x: float, z: float, feet_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	# Highest block whose TOP (y+1) can be at most STEP_UP above the feet.
	var y := int(floor(feet_y + (STEP_UP - 1.0)))
	y = mini(y, TerrainConfig.height_at(xi, zi))   # nothing solid above the surface
	while y > -1024:
		if TerrainConfig.is_solid(xi, y, zi) and not _removed.has(Vector3i(xi, y, zi)):
			return float(y + 1)
		y -= 1
	return float(y + 1)

func is_solid(pos: Vector3) -> bool:
	var cell := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
	return TerrainConfig.is_solid_pos(pos) and not _removed.has(cell)

## Voxel-DDA ray (Amanatides & Woo) against the heightmap. Returns
## {hit, voxel:Vector3i, normal:Vector3i, position:Vector3}.
func aimed_voxel(origin: Vector3, dir: Vector3, max_dist: float = 8.0) -> Dictionary:
	var d := dir.normalized()
	var cell := Vector3i(int(floor(origin.x)), int(floor(origin.y)), int(floor(origin.z)))
	var step := Vector3i(signi(int(sign(d.x))), signi(int(sign(d.y))), signi(int(sign(d.z))))
	var t_max := Vector3(_first_cross(origin.x, d.x), _first_cross(origin.y, d.y), _first_cross(origin.z, d.z))
	var t_delta := Vector3(
		INF if d.x == 0.0 else 1.0 / absf(d.x),
		INF if d.y == 0.0 else 1.0 / absf(d.y),
		INF if d.z == 0.0 else 1.0 / absf(d.z))
	var t := 0.0
	var normal := Vector3i.ZERO

	# The starting cell could already be solid (e.g. camera clipping ground).
	if _cell_solid(cell):
		return {"hit": true, "voxel": cell, "normal": Vector3i.UP,
			"position": origin}

	while t <= max_dist:
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x; t = t_max.x; t_max.x += t_delta.x
			normal = Vector3i(-step.x, 0, 0)
		elif t_max.y < t_max.z:
			cell.y += step.y; t = t_max.y; t_max.y += t_delta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			cell.z += step.z; t = t_max.z; t_max.z += t_delta.z
			normal = Vector3i(0, 0, -step.z)
		if _cell_solid(cell):
			return {"hit": true, "voxel": cell, "normal": normal,
				"position": origin + d * t}
	return {"hit": false, "voxel": Vector3i.ZERO, "normal": Vector3i.ZERO,
		"position": origin + d * max_dist}

# A cell is a solid ray target only if the heightmap fills it AND it has not been
# broken out (removed cells are air the ray passes through).
func _cell_solid(cell: Vector3i) -> bool:
	return TerrainConfig.is_solid(cell.x, cell.y, cell.z) and not _removed.has(cell)

# Distance along one axis to the first integer boundary in the ray's direction.
static func _first_cross(o: float, dir: float) -> float:
	if dir == 0.0:
		return INF
	var cell := floorf(o)
	if dir > 0.0:
		return (cell + 1.0 - o) / dir
	return (o - cell) / -dir
