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
func setup() -> bool:
	if not ClassDB.class_exists("VoxelTerrain"):
		return false

	# Warm the surface state machine, block catalog AND the terrain noise stack on
	# THIS (main) thread before the generator runs on the voxel worker thread —
	# avoids a lazy-init race (the generator now samples the stone noise too).
	SurfaceModel.ensure_ready()
	BlockCatalog.ensure_ready()
	TerrainConfig.height_at(0, 0)   # forces _ensure_noise() (hills + detail + stone)

	var library: Object = ClassDB.instantiate("VoxelBlockyLibrary")
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if library == null or mesher == null:
		return false

	if not _configure_library(library):
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
	# Each block model (ids 1..5) carries its own material; no terrain-wide
	# material_override needed.
	add_child(_terrain)
	return true

## Set one voxel to `block_id` (0 = air/break, >0 = place). Uses the terrain's
## VoxelTool to write the TYPE channel, which triggers a local remesh. Driven
## through strings so this file still parses without the module present.
func set_cell(cell: Vector3i, block_id: int) -> void:
	if _terrain == null or not _terrain.has_method("get_voxel_tool"):
		return
	var vt: Object = _terrain.call("get_voxel_tool")
	if vt == null:
		return
	# VoxelBuffer.CHANNEL_TYPE == 0; VoxelTool.MODE_SET == 0 (default).
	_set_if(vt, "channel", 0)
	_set_if(vt, "mode", 0)
	vt.call("set_voxel", cell, block_id)

## Attach a VoxelViewer to the player so the terrain streams around them.
func attach_viewer(player: Node3D) -> void:
	if _terrain == null:
		return
	_viewer = ClassDB.instantiate("VoxelViewer") as Node
	if _viewer == null:
		return
	_set_if(_viewer, "view_distance", TerrainConfig.RENDER_RADIUS_BLOCKS)
	# Vertical stream ratio (1.0 now that terrain is shallow; kept configurable in
	# TerrainConfig should tall terrain return).
	_set_if(_viewer, "view_distance_vertical_ratio", TerrainConfig.VIEWER_VERTICAL_RATIO)
	_set_if(_viewer, "requires_collisions", false)
	player.add_child(_viewer)

## Build the library: air=0, then grass/dirt/stone/wood/leaf cubes at ids 1..5.
## The model index MUST equal the BlockCatalog id (the generator + edit path write
## those ids), so each add is asserted — a mismatch silently recolours the world.
## Returns true on success.
func _configure_library(library: Object) -> bool:
	# Index 0 = air. Without this the first cube would land at id 0 (= air).
	if ClassDB.class_exists("VoxelBlockyModelEmpty"):
		library.call("add_model", ClassDB.instantiate("VoxelBlockyModelEmpty"))

	# EXACT order after air: grass, dirt, stone, wood, leaf. grass/wood carry the
	# textured materials; dirt/stone/leaf carry flat solid-colour materials. The
	# 1x1 atlas is harmless for the solid ones and uniform for all.
	var ids: Array[int] = [
		BlockCatalog.GRASS, BlockCatalog.DIRT, BlockCatalog.STONE,
		BlockCatalog.WOOD, BlockCatalog.LEAF,
	]
	for block_id: int in ids:
		var got: int = _add_cube(library, BlockMaterials.get_for(block_id))
		if got != block_id:
			return false

	# bake() regenerates model geometry + UVs from the tile/atlas config; without
	# it the tile/atlas UV setup never takes effect.
	if library.has_method("bake"):
		library.call("bake")
	return true

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
## can't be a normal committed script). Writes the layered stackup (stone / dirt /
## grass) and the tree overlay (wood / leaf) exactly as TerrainConfig.generated_block
## defines it, so the module path and the analytic queries agree by construction.
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
	var grass_id = BlockCatalog.GRASS
	var dirt_id = BlockCatalog.DIRT
	var stone_id = BlockCatalog.STONE
	var max_above = TreeGen.MAX_ABOVE_SURFACE
	var dirt_min = TerrainConfig.DIRT_MIN_DEPTH

	# Per-column grass top g and stone top st = min(stone_noise, g - dirt_min).
	var gs = []
	gs.resize(size.x * size.z)
	var sts = []
	sts.resize(size.x * size.z)
	var max_h = -0x7fffffff
	for z in range(size.z):
		for x in range(size.x):
			var wx = ox + x
			var wz = oz + z
			var g = TerrainConfig.height_at(wx, wz)
			var st = min(TerrainConfig.stone_height_at(wx, wz), g - dirt_min)
			var idx = z * size.x + x
			gs[idx] = g
			sts[idx] = st
			if g > max_h: max_h = g

	# Whole block above every surface + tree cap -> all air (leave buffer default 0).
	if oy > max_h + max_above:
		return

	for z in range(size.z):
		for x in range(size.x):
			var idx = z * size.x + x
			var g = gs[idx]
			var st = sts[idx]
			var wx = ox + x
			var wz = oz + z
			for y in range(size.y):
				var wy = oy + y
				var id = 0
				if wy < g:
					id = stone_id if wy <= st else dirt_id
				elif wy == g:
					id = grass_id
				elif wy <= g + max_above:
					id = TreeGen.block_at(wx, wy, wz)
				if id != 0:
					buffer.set_voxel(id, x, y, z, ch)
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
