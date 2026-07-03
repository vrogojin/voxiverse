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
	if world.call("setup", _grass_material):
		_module_world = world
		using_module = true
	else:
		world.queue_free()

func _setup_fallback_path() -> void:
	_streamer = ChunkStreamer.new()
	_streamer.name = "ChunkStreamer"
	add_child(_streamer)
	_streamer.setup(_grass_material, self)

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

## Break the terrain voxel at `cell` (PLAYER-INITIATED). Returns true if a solid
## block was removed. Mirrors the edit into the active render path, then runs a
## local support analysis so any terrain left floating by the dig drops as loose
## rigid bodies, and finally refreshes ground collision.
func break_terrain(cell: Vector3i) -> bool:
	if _removed.has(cell) or not TerrainConfig.is_solid(cell.x, cell.y, cell.z):
		return false
	_removed[cell] = true
	_carve_cell(cell)
	_collapse_unsupported(cell)   # only from the player break — never from a spawn
	if _ground != null:
		_ground.rebuild_now()
	return true

## Mark-free carve: remove `cell` from the active render path only (the caller owns
## the `_removed` overlay + ground rebuild). Shared by break_terrain and the
## collapse pass so the godot_voxel / fallback plumbing lives in one place.
func _carve_cell(cell: Vector3i) -> void:
	if using_module and _module_world != null:
		_module_world.call("remove_voxel", cell)
	elif _streamer != null:
		_streamer.remesh_cell(cell)

# --- terrain collapse (unsupported blocks fall) --------------------------------

## Half-extent of the square column region the collapse scan examines around a break.
const _COLLAPSE_RADIUS := 5

## The 6 axis neighbours, reused by the support flood-fill and the component grouping.
const _NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Local support analysis around a just-broken cell: any solid, non-broken terrain
## no longer connected (through solid cells) to the always-supported bottom row
## becomes falling rigid bodies. Cheap on the common case (flat digging undercuts
## nothing → the flood-fill reaches every cell → zero floaters → early return).
##
## MUST be called only from the player-initiated break_terrain, never from a spawn
## path, so it cannot recurse.
func _collapse_unsupported(center: Vector3i) -> void:
	var x0 := center.x - _COLLAPSE_RADIUS
	var x1 := center.x + _COLLAPSE_RADIUS
	var z0 := center.z - _COLLAPSE_RADIUS
	var z1 := center.z + _COLLAPSE_RADIUS

	# Vertical bounds: top = tallest column in the region; bottom = shortest column
	# minus 2, a row that is solid in every column and connects to the untouched bulk.
	var y_hi := -0x3FFFFFFF
	var y_lo_top := 0x3FFFFFFF
	var xi := x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var h := TerrainConfig.height_at(xi, zi)
			if h > y_hi:
				y_hi = h
			if h < y_lo_top:
				y_lo_top = h
			zi += 1
		xi += 1
	var y_lo := y_lo_top - 2

	# Seed support from every solid cell on the region BOUNDARY shell — the bottom
	# row (deep bulk) AND the 4 side faces. A cell touching a side face connects to
	# untouched terrain OUTSIDE the search box, which we conservatively treat as
	# supported. Seeding only the bottom row would wrongly flag a shelf propped from
	# outside the box as floating and carve it away; biasing toward "supported" at
	# the boundary means we never destroy genuinely-supported terrain (a floater
	# from the dig sits near the box CENTRE, so it is still detected).
	var supported: Dictionary = {}
	var stack: Array[Vector3i] = []
	xi = x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var on_boundary := xi == x0 or xi == x1 or zi == z0 or zi == z1
			var y := y_lo
			while y <= y_hi:
				if (on_boundary or y == y_lo) and _cell_solid(Vector3i(xi, y, zi)):
					var seed := Vector3i(xi, y, zi)
					if not supported.has(seed):
						supported[seed] = true
						stack.append(seed)
				y += 1
			zi += 1
		xi += 1
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		for d: Vector3i in _NEIGHBORS_6:
			var nc := c + d
			if nc.x < x0 or nc.x > x1 or nc.z < z0 or nc.z > z1 or nc.y < y_lo or nc.y > y_hi:
				continue
			if supported.has(nc):
				continue
			if _cell_solid(nc):
				supported[nc] = true
				stack.append(nc)

	# Collect solid cells the flood never reached — these are floating.
	var floating: Dictionary = {}
	xi = x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var y := y_lo
			while y <= y_hi:
				var c := Vector3i(xi, y, zi)
				if _cell_solid(c) and not supported.has(c):
					floating[c] = true
				y += 1
			zi += 1
		xi += 1
	if floating.is_empty():
		return   # common case: nothing undercut, spawn nothing

	# Group floaters into 6-neighbour connected components; each becomes one body.
	var seen: Dictionary = {}
	for start: Vector3i in floating.keys():
		if seen.has(start):
			continue
		var comp: Array[Vector3i] = []
		var cstack: Array[Vector3i] = [start]
		seen[start] = true
		while not cstack.is_empty():
			var c: Vector3i = cstack.pop_back()
			comp.append(c)
			for d: Vector3i in _NEIGHBORS_6:
				var nc := c + d
				if floating.has(nc) and not seen.has(nc):
					seen[nc] = true
					cstack.append(nc)
		# Carve every cell of the component out of the terrain, then drop it as a body
		# positioned exactly where those cells were (grass, since these are ground).
		for c: Vector3i in comp:
			_removed[c] = true
			_carve_cell(c)
		# Reuse the shared grass material (GrassMaterial.build() is uncached — it
		# would alloc a material + reload the texture on every collapse).
		VoxelBody.spawn_loose(self, comp, _grass_material, self)

# --- analytic world queries (path-agnostic) ------------------------------------

## Walkable surface height (world y of the top of the ground) at (x, z), accounting
## for broken blocks from the TOP — used for spawning pillars and the grounded test.
func surface_y(x: float, z: float) -> float:
	return float(effective_height(int(floor(x)), int(floor(z))) + 1)

## The y the player should stand at in column (x, z) given their current feet
## height. Plain, NO-CLIMB floor: scan DOWN from the feet for the first solid block
## that has AIR directly above it (the actual standable surface) and stand on its
## top. Crucially it does NOT pop the player up to the column top when the feet cell
## is buried — walling into a hillside must not teleport the player onto the hilltop.
## Horizontal movement into terrain is now stopped by blocked() (the player queries
## it per-axis), so the feet are always at or just above an air-topped surface and a
## valid floor is always found; the scan honours dug shafts/tunnels below as well.
func floor_under(x: float, z: float, feet_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	# Start at the feet, but never above the column's noise top (nothing solid lives
	# higher than that, so there is no point scanning empty air above the surface).
	var start := mini(int(floor(feet_y + 0.5)), TerrainConfig.height_at(xi, zi))
	var y := start
	while y > -1024:
		if _cell_solid(Vector3i(xi, y, zi)) and not _cell_solid(Vector3i(xi, y + 1, zi)):
			return float(y + 1)
		y -= 1
	return float(effective_height(xi, zi) + 1)

## True if any solid, non-broken terrain cell overlaps the player's vertical body
## span at column (floor(x), floor(z)). The player is ~1.8 m tall standing with feet
## at feet_y; the player agent calls this per-axis to stop horizontal movement into
## a wall (the terrain itself is collider-less, so nothing else does).
func blocked(x: float, z: float, feet_y: float) -> bool:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var y_lo := int(floor(feet_y + 0.1))
	var y_hi := int(floor(feet_y + 1.7))
	var y := y_lo
	while y <= y_hi:
		if _cell_solid(Vector3i(xi, y, zi)):
			return true
		y += 1
	return false

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
