extends Node3D
## godot_voxel (Zylann) rendering path — the PRIMARY path from DESIGN §2 and the
## path that runs in the browser (Stream A's web template includes godot_voxel).
##
## API is pinned to godot_voxel v1.4.1 (verified against the built engine):
##   * VoxelBlockyLibrary starts empty; add_model() appends and returns the id.
##     Index 0 MUST be an air/empty model, grass gets index 1 — the generator
##     writes that same id, so air (buffer default 0) stays empty.
##   * Per-model material via VoxelBlockyModel.set_material_override(0, mat).
##   * VoxelBuffer.CHANNEL_TYPE == 0; the generator also reports it via
##     _get_used_channels_mask() so the blocky mesher reads the type channel.
##
## This file references NO godot_voxel class statically (only ClassDB + strings)
## and compiles its VoxelGeneratorScript from source at runtime, so it still
## loads cleanly when the module is absent (setup() just returns false and the
## WorldManager uses the GDScript fallback).
##
## WEB THREADING: on Emscripten the pthread pool is fixed-size. godot_voxel's
## VoxelEngine sizes its task pool from CPU count and would exhaust the pool
## (deadlock -> no meshes -> blank world). We cap it to 1 thread via the
## `voxel/threads/count/*` project settings (see project.godot); that pool is
## created at engine start from those settings.

var _terrain: Node3D
var _viewer: Node

## Build the terrain. Returns true on success, false if the module is unusable.
func setup(grass_material: Material) -> bool:
	if not ClassDB.class_exists("VoxelTerrain"):
		return false

	var library: Object = ClassDB.instantiate("VoxelBlockyLibrary")
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if library == null or mesher == null:
		return false

	var grass_id := _configure_library(library, grass_material)
	if grass_id < 1:
		return false

	var generator: Object = _make_generator(grass_id)
	if generator == null:
		return false

	if mesher.has_method("set_library"):
		mesher.call("set_library", library)
	else:
		_set_if(mesher, "library", library)

	_terrain = ClassDB.instantiate("VoxelTerrain") as Node3D
	if _terrain == null:
		return false
	_set_if(_terrain, "mesher", mesher)
	_set_if(_terrain, "generator", generator)
	_set_if(_terrain, "max_view_distance", TerrainConfig.RENDER_RADIUS_BLOCKS)
	# We move/raycast analytically, so terrain colliders aren't needed — and
	# skipping them keeps the (web-capped) single voxel thread free for meshing.
	_set_if(_terrain, "generate_collisions", false)
	# Terrain-wide override guarantees the grass texture even if a per-model
	# material path differs; it overrides all library materials.
	_set_if(_terrain, "material_override", grass_material)
	add_child(_terrain)
	return true

## Attach a VoxelViewer to the player so the terrain streams around them.
func attach_viewer(player: Node3D) -> void:
	if _terrain == null:
		return
	_viewer = ClassDB.instantiate("VoxelViewer") as Node
	if _viewer == null:
		return
	_set_if(_viewer, "view_distance", TerrainConfig.RENDER_RADIUS_BLOCKS)
	_set_if(_viewer, "requires_collisions", false)
	player.add_child(_viewer)

## Build the library: air (empty) at id 0, grass cube at id 1. Returns grass id.
func _configure_library(library: Object, grass_material: Material) -> int:
	# Index 0 = air. Without this the cube would land at id 0 and render AS air.
	if ClassDB.class_exists("VoxelBlockyModelEmpty"):
		library.call("add_model", ClassDB.instantiate("VoxelBlockyModelEmpty"))

	var cube: Object = ClassDB.instantiate("VoxelBlockyModelCube")
	if cube == null:
		return -1
	if cube.has_method("set_material_override"):
		cube.call("set_material_override", 0, grass_material)

	var id: Variant = library.call("add_model", cube)
	if typeof(id) == TYPE_INT:
		return id
	# Fallback: derive from the models array (cube is the last entry).
	var models: Variant = library.get("models")
	if models is Array and (models as Array).size() > 0:
		return (models as Array).size() - 1
	return 1

## Compile the VoxelGeneratorScript subclass at runtime (see header for why it
## can't be a normal committed script). Fills grass below the shared heightmap
## into CHANNEL_TYPE, so it matches the fallback exactly. `grass_id` is injected
## so it always agrees with the library index.
func _make_generator(grass_id: int) -> Object:
	var src := """
extends VoxelGeneratorScript

var grass_id := 1

func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE

func _generate_block(buffer, origin_in_voxels, lod):
	if lod != 0:
		return
	var size = buffer.get_size()
	var ox = origin_in_voxels.x
	var oy = origin_in_voxels.y
	var oz = origin_in_voxels.z
	var ch = VoxelBuffer.CHANNEL_TYPE

	# Surface heights for this block's columns, plus the block's height range.
	var heights = []
	heights.resize(size.x * size.z)
	var min_h = 0x7fffffff
	var max_h = -0x7fffffff
	for z in range(size.z):
		for x in range(size.x):
			var h = TerrainConfig.height_at(ox + x, oz + z)
			heights[z * size.x + x] = h
			if h < min_h: min_h = h
			if h > max_h: max_h = h

	# Whole block above every surface -> all air (leave buffer default 0).
	if oy > max_h:
		return
	# Whole block at/below every surface -> all solid grass (fast path).
	if (oy + size.y - 1) <= min_h:
		buffer.fill(grass_id, ch)
		return
	# Mixed: fill each column up to its surface height.
	for z in range(size.z):
		for x in range(size.x):
			var top = clampi(heights[z * size.x + x] - oy + 1, 0, size.y)
			for y in range(top):
				buffer.set_voxel(grass_id, x, y, z, ch)
"""
	var gen_script := GDScript.new()
	gen_script.source_code = src
	var err := gen_script.reload()
	if err != OK:
		push_warning("[module_world] generator compile failed: %d" % err)
		return null
	var gen: Object = gen_script.new()
	gen.set("grass_id", grass_id)
	return gen

# --- helpers -------------------------------------------------------------------
# Set a property only if the object actually exposes it (avoids error spam if a
# module property name drifts between versions).
func _set_if(obj: Object, prop: String, value: Variant) -> void:
	for p in obj.get_property_list():
		if p.get("name", "") == prop:
			obj.set(prop, value)
			return
