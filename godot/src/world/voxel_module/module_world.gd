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

# --- appearance table (ARIDs, VOXEL-DATA-STRUCTURE §8.1) ------------------------
# The TYPE channel carries an Appearance Render ID (ARID) — a session-local, append-
# only dense id per (LRID, modifier) combination in use, equal by construction to its
# VoxelBlockyLibrary model index. Plain-cube ARIDs are allocated EAGERLY at material
# registration (bootstrap: cube ARID == LRID, so a flat all-cube world writes byte-
# identical TYPE buffers to today); shaped ARIDs are appended LAZILY on the MAIN thread
# on first `set_cell` of a shaped value, as a VoxelBlockyModelMesh built from ShapeMesh
# riding the batched bake(). The generator (voxel worker) only ever emits modifier 0,
# so it writes the cube ARID directly and never touches the lazy table.
var _library: Object                    # the VoxelBlockyLibrary (kept for lazy appends + re-bake)
var _cube_arid: PackedInt32Array        # LRID -> cube ARID (preallocated; == LRID for bootstrap)
var _arid_by_key: Dictionary = {}       # (lrid | modifier<<16) -> ARID (MAIN THREAD ONLY)
var _next_arid := 0                     # next free library model index / ARID to allocate

## Build the terrain. Returns true on success, false if the module is unusable.
func setup() -> bool:
	if not ClassDB.class_exists("VoxelTerrain"):
		return false

	# Warm the surface state machine, block catalog AND every terrain lazy
	# singleton (noise stack + material id cache + TreeGen species ids) on THIS
	# (main) thread before the generator runs on the voxel worker thread — a lazily
	# built noise/id table first touched on the worker thread is a data race and
	# the project's worst-case bug class (WGC §7.4).
	SurfaceModel.ensure_ready()
	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()

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
	# Each block model (ids 1..count()-1) carries its own material; no terrain-wide
	# material_override needed.
	add_child(_terrain)
	return true

## Set one voxel from a PACKED cell value (0 = air/break; >0 = place). Resolves the
## value's (material, modifier) to its ARID — allocating a shaped ARID lazily on this
## (main) thread if unseen (VDS §8.2) — and writes THAT into the TYPE channel, which
## triggers a local remesh. A plain full cube resolves to its cube ARID (== LRID for
## bootstrap), so this is byte-identical to the old id write for the current world.
## Driven through strings so this file still parses without the module present.
func set_cell(cell: Vector3i, packed: int) -> void:
	if _terrain == null or not _terrain.has_method("get_voxel_tool"):
		return
	var vt: Object = _terrain.call("get_voxel_tool")
	if vt == null:
		return
	var arid := arid_for(CellCodec.mat(packed), CellCodec.modifier(packed))
	# VoxelBuffer.CHANNEL_TYPE == 0; VoxelTool.MODE_SET == 0 (default).
	_set_if(vt, "channel", 0)
	_set_if(vt, "mode", 0)
	vt.call("set_voxel", cell, arid)

## Resolve (LRID, modifier) → ARID, allocating a shaped ARID lazily (MAIN THREAD).
## AIR → 0; a full cube → the eager cube ARID; a shaped value appends a
## VoxelBlockyModelMesh (built from ShapeMesh) whose model index MUST equal the ARID
## being allocated (the streaming anti-drift assert, VDS §8.1) and re-bakes. On any
## failure it falls back to the material's plain-cube ARID — a wrong silhouette but
## correct substance, never a hole. Returns the ARID (>= 0), or the cube ARID on drift.
func arid_for(mat: int, modifier: int) -> int:
	if mat == BlockCatalog.AIR:
		return 0
	if modifier == 0:
		return _cube_arid_of(mat)
	var key := mat | (modifier << 16)                  # vstate is 0 in P5b-1
	if _arid_by_key.has(key):
		return int(_arid_by_key[key])
	if _library == null:
		return _cube_arid_of(mat)
	var model: Object = _make_shape_model(modifier, BlockMaterials.get_for(mat))
	if model == null:
		return _cube_arid_of(mat)
	var expected := _next_arid
	var got: int = _add_model(_library, model)
	if got != expected:
		push_warning("[module_world] ARID drift: add_model returned %d, expected %d" % [got, expected])
		return _cube_arid_of(mat)
	_next_arid += 1
	_arid_by_key[key] = got
	if _library.has_method("bake"):
		_library.call("bake")                          # one batched re-bake per novel shape
	return got

## The eager plain-cube ARID for a material (== LRID for bootstrap materials).
func _cube_arid_of(mat: int) -> int:
	if mat >= 0 and mat < _cube_arid.size():
		return _cube_arid[mat]
	return mat                                         # defensive: table not built yet

## Total appearance ids allocated so far (cube ARIDs + lazily-baked shaped ARIDs) —
## == the library model count. Used by verify to fence the lazy append (VDS §8.1).
func appearance_count() -> int:
	return _next_arid

## Build a VoxelBlockyModelMesh for `modifier` from the shared ShapeMesh geometry (the
## one render seam — SVS §4). Returns null when the module lacks the mesh-model class.
func _make_shape_model(modifier: int, material: Material) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	var geom := ShapeMesh.build(modifier)
	var amesh := ArrayMesh.new()
	var surf := []
	surf.resize(Mesh.ARRAY_MAX)
	surf[Mesh.ARRAY_VERTEX] = geom["verts"]
	surf[Mesh.ARRAY_NORMAL] = geom["normals"]
	surf[Mesh.ARRAY_TEX_UV] = geom["uvs"]
	surf[Mesh.ARRAY_INDEX] = geom["indices"]
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, material)
	return model

## Append a model to the library and return its index (int return, else models-array
## size — mirrors _add_cube's version-robust read).
func _add_model(library: Object, model: Object) -> int:
	var id: Variant = library.call("add_model", model)
	if typeof(id) == TYPE_INT:
		return id
	var models: Variant = library.get("models")
	return ((models as Array).size() - 1) if models is Array else -1

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

## Build the library: air=0, then a cube model for EVERY BlockCatalog id in dense
## order (WGC §5.1). The model index MUST equal the BlockCatalog id (the generator +
## edit path write those ids), so each add is asserted over ALL ids — a mismatch
## silently recolours the world. Translucent materials (glass/water/ice, cull_group
## > 0) get their `transparency_index` set so the blocky mesher culls faces per the
## transparency-index rule (§5.1). Returns true on success.
func _configure_library(library: Object) -> bool:
	# Keep the library so shaped ARIDs can be appended + re-baked lazily (VDS §8.1).
	_library = library
	var total := BlockCatalog.count()
	# LRID -> cube ARID table; air (0) -> 0, each cube ARID == LRID for bootstrap.
	_cube_arid = PackedInt32Array()
	_cube_arid.resize(total)

	# Index 0 = air. Without this the first cube would land at id 0 (= air).
	if ClassDB.class_exists("VoxelBlockyModelEmpty"):
		library.call("add_model", ClassDB.instantiate("VoxelBlockyModelEmpty"))
	_cube_arid[BlockCatalog.AIR] = 0

	# Ids 1..count()-1 in order: each carries its own BlockMaterials material (textured
	# where a tile exists, else a flat swatch; translucent/emissive per the catalog). The
	# 1x1 atlas is uniform for all. The library-order invariant (cube ARID == LRID) is
	# machine-checked at every id, not just the frozen 5.
	for block_id in range(1, total):
		var cull_group: int = BlockCatalog.cull_group_of(block_id)
		var got: int = _add_cube(library, BlockMaterials.get_for(block_id), cull_group)
		if got != block_id:
			push_warning("[module_world] library order broke: model %d != id %d" % [got, block_id])
			return false
		_cube_arid[block_id] = got

	# Every model appended so far (air + the cubes) occupies indices 0..total-1, so the
	# next free ARID (the first lazily-baked shaped model) is `total`.
	_next_arid = total

	# bake() regenerates model geometry + UVs from the tile/atlas config; without
	# it the tile/atlas UV setup never takes effect.
	if library.has_method("bake"):
		library.call("bake")
	return true

## Add one textured cube model, returning its library id. `cull_group` (0 = opaque)
## maps 1:1 onto VoxelBlockyModel.transparency_index (WGC §5.1): the blocky mesher
## culls a face against a neighbour whose index is <= this model's, so glass-behind-
## glass culls but stone-behind-glass draws. The alpha blend itself lives on the
## material; the index only governs face culling.
func _add_cube(library: Object, material: Material, cull_group: int = 0) -> int:
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
	# Transparency index for face culling (WGC §5.1). Opaque (0) is the godot_voxel
	# default, so only translucent models need it; guarded so the call is harmless if
	# the module drops the setter between versions.
	if cull_group > 0 and cube.has_method("set_transparency_index"):
		cube.call("set_transparency_index", cull_group)
	var id: Variant = library.call("add_model", cube)
	if typeof(id) == TYPE_INT:
		return id
	var models: Variant = library.get("models")
	return ((models as Array).size() - 1) if models is Array else -1

## Compile the VoxelGeneratorScript subclass at runtime (see header for why it
## can't be a normal committed script). SINGLE SOURCE OF TRUTH (WGC §7.2): this
## does NOT re-implement the pipeline — it caches one TerrainConfig.column_profile
## (a value-type Vector4, no allocation) per column and calls
## TerrainConfig.resolve_cell per cell, the exact functions the analytic queries
## use, so the module path and TerrainConfig.generated_block agree by construction.
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
	var sea = TerrainConfig.SEA_LEVEL
	var max_above = TreeGen.MAX_ABOVE_SURFACE

	# Per-column profile cache: Vector4(g, biome, c, t). Value type -> no per-cell
	# noise sampling and no allocation.
	var profs = []
	profs.resize(size.x * size.z)
	var max_h = -0x7fffffff
	for z in range(size.z):
		for x in range(size.x):
			var p = TerrainConfig.column_profile(ox + x, oz + z)
			profs[z * size.x + x] = p
			if int(p.x) > max_h: max_h = int(p.x)

	# Whole block above every surface + tree cap AND above the sea cap -> all air
	# (leave buffer default 0). The sea term matters over deep ocean, where the
	# solid top is far below SEA_LEVEL but water still fills up to it.
	var top = max_h + max_above
	if sea > top: top = sea
	if oy > top:
		return

	for z in range(size.z):
		for x in range(size.x):
			var p = profs[z * size.x + x]
			var g = int(p.x)
			var biome = int(p.y)
			var cc = p.z
			var tt = p.w
			var wx = ox + x
			var wz = oz + z
			for y in range(size.y):
				var v = TerrainConfig.resolve_cell(wx, oy + y, wz, g, biome, cc, tt)
				var id = CellCodec.mat(v)
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
