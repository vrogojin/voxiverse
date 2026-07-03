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
func setup(grass_material: Material, snow_material: Material) -> bool:
	if not ClassDB.class_exists("VoxelTerrain"):
		return false

	# Warm the surface state machine on THIS (main) thread before the generator
	# runs on the voxel worker thread — avoids a lazy-init race.
	SurfaceModel.ensure_ready()

	var library: Object = ClassDB.instantiate("VoxelBlockyLibrary")
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if library == null or mesher == null:
		return false

	if not _configure_library(library, grass_material, snow_material):
		return false

	var generator: Object = _make_generator()
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
	# NOTE: no terrain-wide material_override — that would mask the per-model snow
	# material. Each block model (grass id 1, snow id 2) carries its own material.
	add_child(_terrain)
	return true

## Carve one voxel to air (block breaking). Uses the terrain's VoxelTool to set
## the TYPE channel to 0 (the empty/air model), which triggers a local remesh.
## Driven through strings so this file still parses without the module present.
func remove_voxel(cell: Vector3i) -> void:
	if _terrain == null or not _terrain.has_method("get_voxel_tool"):
		return
	var vt: Object = _terrain.call("get_voxel_tool")
	if vt == null:
		return
	# VoxelBuffer.CHANNEL_TYPE == 0; VoxelTool.MODE_SET == 0 (default).
	_set_if(vt, "channel", 0)
	_set_if(vt, "mode", 0)
	vt.call("set_voxel", cell, 0)

## Attach a VoxelViewer to the player so the terrain streams around them.
func attach_viewer(player: Node3D) -> void:
	if _terrain == null:
		return
	_viewer = ClassDB.instantiate("VoxelViewer") as Node
	if _viewer == null:
		return
	_set_if(_viewer, "view_distance", TerrainConfig.RENDER_RADIUS_BLOCKS)
	# Stretch the stream vertically so tall mountain caps load without paying for
	# a bigger horizontal radius.
	_set_if(_viewer, "view_distance_vertical_ratio", TerrainConfig.VIEWER_VERTICAL_RATIO)
	_set_if(_viewer, "requires_collisions", false)
	player.add_child(_viewer)

## Build the library: air=0, grass cube=1, snow cube=2. Returns true on success.
func _configure_library(library: Object, grass_material: Material, snow_material: Material) -> bool:
	# Index 0 = air. Without this the first cube would land at id 0 (= air).
	if ClassDB.class_exists("VoxelBlockyModelEmpty"):
		library.call("add_model", ClassDB.instantiate("VoxelBlockyModelEmpty"))

	var grass_id: int = _add_cube(library, grass_material)
	var snow_id: int = _add_cube(library, snow_material)
	# bake() regenerates model geometry + UVs from the tile/atlas config; without
	# it the tile/atlas UV setup below never takes effect.
	if library.has_method("bake"):
		library.call("bake")

	# The generator writes SurfaceModel ids; the library order must match them.
	return grass_id == SurfaceModel.GRASS_ID and snow_id == SurfaceModel.SNOW_ID

## Add one textured cube model, returning its library id.
func _add_cube(library: Object, material: Material) -> int:
	var cube: Object = ClassDB.instantiate("VoxelBlockyModelCube")
	if cube == null:
		return -1
	# CRITICAL for a visible texture: 1x1 tile atlas with every face at tile
	# (0,0). The default atlas_size_in_tiles is (0,0) → DEGENERATE UVs (every
	# face samples one texel → flat solid colour). A 1x1 atlas gives 0..1 UVs so
	# the whole 64x64 texture shows per face.
	if cube.has_method("set_atlas_size_in_tiles"):
		cube.call("set_atlas_size_in_tiles", Vector2i(1, 1))
	if cube.has_method("set_tile"):
		for side in 6:  # VoxelBlockyModel.SIDE_* : 0..5 (all cube faces)
			cube.call("set_tile", side, Vector2i(0, 0))
	if cube.has_method("set_material_override"):
		cube.call("set_material_override", 0, material)
	var id: Variant = library.call("add_model", cube)
	if typeof(id) == TYPE_INT:
		return id
	var models: Variant = library.get("models")
	return ((models as Array).size() - 1) if models is Array else -1

## Compile the VoxelGeneratorScript subclass at runtime (see header for why it
## can't be a normal committed script). Fills grass below the shared heightmap
## and the temperature-chosen surface block (grass/snow) on top, so it matches
## the fallback exactly. The surface choice runs through SurfaceModel.
func _make_generator() -> Object:
	var src := """
extends VoxelGeneratorScript

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
	var grass_id = SurfaceModel.GRASS_ID

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
	# Whole block strictly below every surface -> all solid grass (fast path,
	# no surface voxel here so no snow).
	if (oy + size.y) <= min_h:
		buffer.fill(grass_id, ch)
		return
	# Mixed: grass below the surface, the temperature-chosen block on top.
	for z in range(size.z):
		for x in range(size.x):
			var h = heights[z * size.x + x]
			var surface_id = SurfaceModel.block_id_at(ox + x, oz + z)
			var top = clampi(h - oy + 1, 0, size.y)
			for y in range(top):
				var wy = oy + y
				buffer.set_voxel(surface_id if wy == h else grass_id, x, y, z, ch)
"""
	var gen_script := GDScript.new()
	gen_script.source_code = src
	var err := gen_script.reload()
	if err != OK:
		push_warning("[module_world] generator compile failed: %d" % err)
		return null
	return gen_script.new()

# --- helpers -------------------------------------------------------------------
# Set a property only if the object actually exposes it (avoids error spam if a
# module property name drifts between versions).
func _set_if(obj: Object, prop: String, value: Variant) -> void:
	for p in obj.get_property_list():
		if p.get("name", "") == prop:
			obj.set(prop, value)
			return
