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

# --- generator appearance manifest (VDS §8.1/§8.3, RMS §6.5) --------------------
# Every (surface material, modifier) pair worldgen can emit (P5b-2 terrain smoothing)
# is pre-allocated + baked + FROZEN into this flat array at PATH ACTIVATION (setup(),
# before the viewer/worker attaches), keyed by `mat * _GEN_STRIDE + modifier`. The
# voxel worker (the runtime generator) reads ONLY this array + `_cube_arid` — both
# fixed-size, never resized after freeze — so it maps a shaped generated cell to a baked
# ARID with zero allocation/bake (removing P5b-1's flagged concurrent-bake risk for
# generated shapes). A slot left -1 renders that shape as the material's plain cube
# (wrong silhouette, correct substance, never a hole — VDS §8.1 exhaustion policy).
const _GEN_STRIDE := 256                 # max BOTTOM corner-height modifier (0xAA) + margin
var _gen_arid: PackedInt32Array          # (mat*_GEN_STRIDE + modifier) -> ARID; frozen at setup
var _generator: Object                   # the runtime-compiled generator (kept for verify)

# --- water appearance (WATER-SHORE §4.2 / WATERLOGGING §4) ----------------------
# Two frozen publications baked at setup (same discipline as `_gen_arid`), BEFORE the
# generator is wired, so the worker only reads them (zero allocation, race-free):
#   * `_gen_wet_arid` — the WATERLOGGED-TWIN model for each co-filled (surface material,
#     modifier) composite pair worldgen emits, keyed `mat * _GEN_STRIDE + modifier`. Two
#     engine-dependent flavours:
#       - NATIVE WATERLOGGING (WATERLOGGING.md, `_waterlog_enabled`): a VoxelBlockyModelMesh
#         of the DRY terrain ramp that ADDITIONALLY carries the shared fluid (set_waterlog_*),
#         so its water culls seamlessly against every other water cell (pure and composite,
#         shore AND submerged) — no border. ONE twin per shape covers BOTH the water-line
#         (liquid 9) and submerged (liquid 10) composites (the engine picks the fill height
#         from the cell above), so BOTH route here.
#       - LEGACY composite (old engine): the WET COMPOSITE model (terrain ramp + a 0.9 water
#         slab surface) as before — used only at the water line (liquid 9); submerged stays dry.
#     A slot left -1 (unbaked pair) falls back to the DRY shaped model then the cube — a
#     notch/border, never a hole.
#   * `_water_surface_arid` — the open-water surface cell's model ARID. Native: the water LRID's
#     PURE FLUID model (== `_cube_arid[water]`); legacy: the ONE 0.9 water-slab model. -1 falls
#     back to the water cube ARID (wrong water top only, never a hole).
# The legacy wet fill is modifier-INDEPENDENT (WATER-SHORE §4.3), so its ArrayMesh is shared
# across materials via `_shape_mesh_cache` keyed `modifier | _WET_MESH_FLAG`. The native twin
# instead REUSES the dry `_shape_mesh_cache[modifier]` ArrayMesh directly (its solid IS the dry
# ramp), so no water-shape mesh multiplier at all.
var _gen_wet_arid: PackedInt32Array      # (mat*_GEN_STRIDE + modifier) -> wet/twin ARID; -1 = not baked
var _water_surface_arid := -1            # open-water surface cell model ARID; -1 = not baked
var _water_id := -1                      # cached BlockCatalog.id_of(&"water") (main thread)
const _WET_MESH_FLAG := 1 << 20          # _shape_mesh_cache key bit for LEGACY wet composite meshes
# --- NATIVE WATERLOGGING (WATERLOGGING.md §4) ----------------------------------
# Feature-detected in setup(): true when the running engine exposes godot_voxel's native
# solid+fluid co-fill (VoxelBlockyModelFluid + VoxelBlockyModel.set_waterlog_fluid). When true,
# pure water renders as a VoxelBlockyModelFluid and every co-filled composite as a waterlogged
# twin, so all water shares ONE fluid_index and culls together (no shore/submerged border). When
# false (old binary), the LEGACY slab+wet-composite path below is used unchanged (graceful degrade).
var _waterlog_enabled := false
var _water_fluid: Object = null          # the ONE shared VoxelBlockyFluid (water material); null unless enabled
# One shared ArrayMesh per shape modifier, reused across every material (geometry
# depends only on the modifier). Keeps the manifest's mesh RESOURCES at distinct-shape
# count (<=79) instead of materials×shapes (474) — the material differs only via the
# per-model override, so mesh allocation/upload is not multiplied by the palette.
var _shape_mesh_cache: Dictionary = {}   # int modifier -> ArrayMesh

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

	# Feature-detect native waterlogging (WATERLOGGING.md §4). When present, build the ONE shared
	# VoxelBlockyFluid NOW — before _configure_library (which turns the water LRID into a pure fluid
	# model referencing it) and _build_gen_manifest (which bakes waterlogged twins referencing it).
	# On any instantiate failure we fall back to the legacy composite path (never a crash).
	_waterlog_enabled = _detect_waterlog()
	if _waterlog_enabled:
		_water_fluid = _make_water_fluid()
		if _water_fluid == null:
			_waterlog_enabled = false
	print("[module_world] native waterlogging: %s" % ("ENABLED" if _waterlog_enabled else "absent (legacy composite path)"))

	var library: Object = ClassDB.instantiate("VoxelBlockyLibrary")
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if library == null or mesher == null:
		return false

	# Per-phase timing (printed to the JS console on web) — pinpoints any load stall.
	var _t_warm := Time.get_ticks_msec()
	if not _configure_library(library):
		return false
	var _t_lib := Time.get_ticks_msec()

	# Pre-bake + FREEZE the generator appearance manifest (RMS §6.5 / VDS §8.3) BEFORE the
	# generator is wired in and the worker can run: every (surface material, modifier)
	# pair worldgen smoothing can emit gets an ARID + baked VoxelBlockyModelMesh now, on
	# this (main) thread. After this the worker only reads the frozen `_gen_arid` array.
	_build_gen_manifest(library)
	var _t_manifest := Time.get_ticks_msec()
	print("[module_world] setup timing: configure_library=%d ms  manifest(bake+meshes)=%d ms" % [
		_t_lib - _t_warm, _t_manifest - _t_lib])

	var generator: Object = _make_generator()
	if generator == null:
		return false
	_generator = generator

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
	# Coarse (32³) mesh blocks instead of the 16³ default. At a 256-block view distance
	# with no LOD, 16³ mesh blocks produce ~1000+ surface meshes = ~1000+ draw calls, and
	# on GL Compatibility via ANGLE→D3D11 (Intel HD in a browser) per-draw-call overhead —
	# not triangle count — is what collapses the frame rate once the full radius streams
	# in. 32³ blocks cover 2×2×2 as much ground each, cutting the draw-call count ~4-8×
	# for the SAME view distance and the SAME smoothing. Trade-off: a block edit remeshes
	# a larger block, but that runs on the voxel worker and the main-thread mesh APPLY is
	# already capped (voxel/threads/main/time_budget_ms=4), so it is not a frame stall.
	# Data blocks stay 16³ (bulk_inject groups by data block), so edit injection is
	# unaffected. Valid values are 16 or 32 only.
	_set_if(_terrain, "mesh_block_size", 32)
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
	var arid := arid_for_cell(packed)
	# VoxelBuffer.CHANNEL_TYPE == 0; VoxelTool.MODE_SET == 0 (default).
	_set_if(vt, "channel", 0)
	_set_if(vt, "mode", 0)
	vt.call("set_voxel", cell, arid)

## Bulk-inject a set of edited cells into the render path (RMS §3.4, F10 — the module-path
## primitive for whole-zone injection without per-voxel VoxelTool calls). `cells` maps world
## Vector3i → PACKED cell value; the caller (WorldManager.load_bundle) has ALREADY written the
## overlay (rule-1 truth), so this only mirrors the render. Cells are grouped by godot_voxel
## DATA BLOCK; a block that is already loaded (in a viewer's range) is seeded from its current
## voxels (VoxelTool.copy — so untouched generated/edited cells keep their value), has the
## injected cells' ARIDs written into that buffer, and is handed to `try_set_block_data` in ONE
## call (F10). Blocks not yet loaded (e.g. headless verify, or outside every viewer) can't take
## a block-data set (try_set_block_data would ignore them), so they fall back to per-cell
## `set_cell`; the overlay remains the truth regardless. Safe when the module lacks any needed
## method (falls back to per-cell). Driven through strings so this file parses without the module.
func bulk_inject(cells: Dictionary) -> void:
	if _terrain == null or cells.is_empty():
		return
	var can_bulk := ClassDB.class_exists("VoxelBuffer") \
		and _terrain.has_method("try_set_block_data") and _terrain.has_method("voxel_to_data_block") \
		and _terrain.has_method("data_block_to_voxel") and _terrain.has_method("get_data_block_size") \
		and _terrain.has_method("has_data_block") and _terrain.has_method("get_voxel_tool")
	if not can_bulk:
		for cell: Vector3i in cells.keys():
			set_cell(cell, int(cells[cell]))
		return
	var bs := int(_terrain.call("get_data_block_size"))
	# Group world cells by their data-block coordinate.
	var by_block := {}
	for cell: Vector3i in cells.keys():
		var bpos: Vector3i = _terrain.call("voxel_to_data_block", cell)
		if not by_block.has(bpos):
			by_block[bpos] = ([] as Array)
		(by_block[bpos] as Array).append(cell)
	var vt: Object = _terrain.call("get_voxel_tool")
	for bpos: Vector3i in by_block.keys():
		var block_cells: Array = by_block[bpos]
		var applied := false
		# Only attempt the bulk set for a LOADED block (else try_set_block_data ignores it and
		# copy would read empty data — clobbering the block to air). Loaded ⇒ copy reads the real
		# voxels, we overwrite our cells, and try_set_block_data replaces the block in one call.
		if bs > 0 and vt != null and bool(_terrain.call("has_data_block", bpos)):
			var buf: Object = _seeded_block_buffer(bs, bpos, vt)
			if buf != null:
				var origin: Vector3i = _terrain.call("data_block_to_voxel", bpos)
				for cell: Vector3i in block_cells:
					var packed := int(cells[cell])
					var lc := cell - origin
					# VoxelBuffer.CHANNEL_TYPE == 0.
					buf.call("set_voxel", arid_for(CellCodec.mat(packed), CellCodec.modifier(packed)),
						lc.x, lc.y, lc.z, 0)
				applied = bool(_terrain.call("try_set_block_data", bpos, buf))
		if not applied:
			for cell: Vector3i in block_cells:
				set_cell(cell, int(cells[cell]))

## Build a VoxelBuffer for data block `bpos` seeded from its CURRENT voxels (VoxelTool.copy on
## the TYPE channel), so cells we do not touch keep their value after `try_set_block_data`
## replaces the whole block. 16-bit TYPE depth (F6) so ARIDs up to 65535 fit. Null on failure.
func _seeded_block_buffer(bs: int, bpos: Vector3i, vt: Object) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	if buf == null or not buf.has_method("create"):
		return null
	buf.call("create", bs, bs, bs)
	if buf.has_method("set_channel_depth"):
		buf.call("set_channel_depth", 0, 1)          # CHANNEL_TYPE, DEPTH_16_BIT
	if vt.has_method("copy"):
		_set_if(vt, "channel", 0)
		var origin: Vector3i = _terrain.call("data_block_to_voxel", bpos)
		vt.call("copy", origin, buf, 1 << 0)         # channels mask: TYPE only
	return buf

## Resolve a full PACKED cell value → ARID, honouring the WATER-SHORE liquid rule (§4.6).
## A liquid-9 value (the water line) consults the frozen water tables first —
## `_water_surface_arid` for the open-water surface cell (modifier 0), the wet composite ARID
## for a shore composite (modifier != 0) — then falls through to the DRY resolve (`arid_for`)
## when the water model was not baked (graceful: water cube / dry shape, never a hole).
## Liquid-10 (submerged) resolves to the SAME waterlogged twin as its liquid-9 sibling when
## native waterlogging is enabled (so submerged water culls seamlessly — the last underwater
## border); on a legacy engine it falls through to the dry resolve. Player edits never produce liquid values
## (placement rejects non-solid materials, break writes 0), so this is worldgen-mirror only.
func arid_for_cell(packed: int) -> int:
	var lvl := CellCodec.liquid_level(packed)
	if lvl == CellCodec.LIQ_LEVEL_SURFACE:
		var mat := CellCodec.mat(packed)
		var modifier := CellCodec.modifier(packed)
		if modifier == 0:
			if _water_surface_arid >= 0:
				return _water_surface_arid                 # else fall through: water cube via arid_for
		else:
			var wslot := mat * _GEN_STRIDE + modifier
			if modifier < _GEN_STRIDE and wslot < _gen_wet_arid.size() and _gen_wet_arid[wslot] >= 0:
				return _gen_wet_arid[wslot]                # else fall through: dry shape via arid_for
	elif _waterlog_enabled and lvl == CellCodec.LIQ_LEVEL_FULL:
		# Native waterlogging (WATERLOGGING §4.5): a SUBMERGED composite (liquid 10, modifier != 0)
		# resolves to the SAME waterlogged twin as its water-line (liquid 9) sibling, so submerged
		# water culls seamlessly against the surrounding water cubes/composites — the last underwater
		# border. -1 (unbaked) falls through to the dry shape (a border, never a hole).
		var mat := CellCodec.mat(packed)
		var modifier := CellCodec.modifier(packed)
		if modifier != 0:
			var wslot := mat * _GEN_STRIDE + modifier
			if modifier < _GEN_STRIDE and wslot < _gen_wet_arid.size() and _gen_wet_arid[wslot] >= 0:
				return _gen_wet_arid[wslot]
	return arid_for(CellCodec.mat(packed), CellCodec.modifier(packed))

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
	# Reuse a manifest-baked generated shape (no duplicate model/bake) when the placed
	# (material, modifier) is one worldgen already emits — e.g. placing a grass ramp
	# identical to a smoothed terrain ramp.
	var gslot := mat * _GEN_STRIDE + modifier
	if modifier < _GEN_STRIDE and gslot < _gen_arid.size() and _gen_arid[gslot] >= 0:
		return _gen_arid[gslot]
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

## The plain-cube ARID for a material (== LRID for the bootstrap set). A material
## registered AFTER setup (runtime streaming, RMS §3.1) has no cube model yet — allocate
## one lazily so writing its ARID never renders a hole (F5 safety net). Cube ARIDs of
## streamed LRIDs may drift from the LRID (shaped ARIDs already occupy the low model
## indices) — harmless: nothing outside this module mirror ever sees an ARID (VDS §8.1).
func _cube_arid_of(mat: int) -> int:
	if mat >= 0 and mat < _cube_arid.size() and _cube_arid[mat] >= 0:
		return _cube_arid[mat]
	return _append_cube_for(mat)

## Lazily append + bake a plain-cube model for a streamed LRID (MAIN THREAD ONLY —
## `set_cell`/`arid_for` never run on the voxel worker). Grows the LRID→cube-ARID table
## to cover `mat`, asserts `add_model()` returns the expected model index (the anti-drift
## guard, VDS §8.1), and re-bakes. Returns the new ARID, or a defensive fallback on
## drift/absent library (never crashes).
func _append_cube_for(mat: int) -> int:
	if _library == null:
		return mat
	if mat >= _cube_arid.size():
		var old := _cube_arid.size()
		_cube_arid.resize(mat + 1)
		for i in range(old, mat + 1):
			_cube_arid[i] = -1
	if _cube_arid[mat] >= 0:
		return _cube_arid[mat]
	var expected := _next_arid
	var got: int = _add_cube(_library, BlockMaterials.get_for(mat), BlockCatalog.cull_group_of(mat))
	if got != expected:
		push_warning("[module_world] streamed cube ARID drift: add_model %d != expected %d" % [got, expected])
		return got if got >= 0 else mat
	_next_arid += 1
	_cube_arid[mat] = got
	if _library.has_method("bake"):
		_library.call("bake")                          # one batched re-bake per streamed material
	return got

## True when `arid` is baked into the live library and therefore safe to write into the
## voxel TYPE channel (RMS §3.1 paint gate). All appended models are baked eagerly, so
## the baked count equals the appended count (`_next_arid`).
func can_render(arid: int) -> bool:
	return arid >= 0 and arid < _next_arid

## Total appearance ids allocated so far (cube ARIDs + lazily-baked shaped ARIDs) —
## == the library model count. Used by verify to fence the lazy append (VDS §8.1).
func appearance_count() -> int:
	return _next_arid

## Pre-allocate + bake the generator's appearance manifest and FREEZE it into
## `_gen_arid` (VDS §8.1/§8.3, RMS §6.5). Each (surface material, modifier) pair the
## smoothing worldgen can emit becomes a once-baked VoxelBlockyModelMesh whose library
## index MUST equal the ARID being allocated (the anti-drift assert, generalised from
## `_add_cube`). After this returns, the voxel worker maps (mat, modifier) → ARID via
## `_gen_arid[mat*_GEN_STRIDE + modifier]` with zero allocation/bake. Best-effort: a
## slot left -1 (e.g. the module lacks VoxelBlockyModelMesh, or an ARID drift aborts the
## build) renders that shape as the material's plain cube — never a hole.
func _build_gen_manifest(library: Object) -> void:
	var total := _cube_arid.size()                       # == BlockCatalog.count()
	_gen_arid = PackedInt32Array()
	_gen_arid.resize(total * _GEN_STRIDE)
	_gen_arid.fill(-1)
	var mats := TerrainConfig.appearance_surface_materials()
	# Bake materials × only the modifiers the smoother ACTUALLY emits (a wide-area sample), NOT
	# all 79 corner tuples — each baked model triggers a GPU geometry readback (getBufferSubData),
	# so this cuts the load stall. Unbaked shapes cube-fall-back on the worker (never a hole).
	var mods := TerrainConfig.emitted_modifiers()
	var appended := 0
	for mat: int in mats:
		if mat <= BlockCatalog.AIR or mat >= total:
			continue
		var material: Material = BlockMaterials.get_for(mat)
		for modifier: int in mods:
			if modifier <= 0 or modifier >= _GEN_STRIDE:
				continue
			var model: Object = _make_shape_model(modifier, material)
			if model == null:
				continue                                 # no mesh-model class → cube fallback
			var expected := _next_arid
			var got: int = _add_model(library, model)
			if got != expected:
				push_warning("[module_world] manifest ARID drift: add_model %d != expected %d" % [got, expected])
				return                                   # leave the rest -1 (cube fallback)
			_next_arid += 1
			_gen_arid[mat * _GEN_STRIDE + modifier] = got
			appended += 1

	# Water models: NATIVE waterlogged twins (WATERLOGGING §4) or LEGACY wet composites + slab
	# (WATER-SHORE §4.2). Same anti-drift discipline (add_model() == expected ARID); any drift aborts
	# the water manifest (leaving -1 / cube fallback) but keeps the dry manifest intact.
	var wet := _build_wet_manifest(library, total)
	appended += wet

	if appended > 0 and library.has_method("bake"):
		library.call("bake")                             # one batched bake: dry shapes + water models
	print("[module_world] baked appearance manifest: %d (material,modifier) generated shapes (%d materials x %d emitted modifiers; full set would be %d)"
		% [appended - wet, mats.size(), mods.size(), mats.size() * TerrainConfig.appearance_modifiers().size()])
	if _waterlog_enabled:
		print("[module_world] baked waterlog manifest: %d waterlogged composite twins + pure-fluid water (surface ARID=%d)"
			% [wet, _water_surface_arid])
	else:
		print("[module_world] baked water manifest: %d wet shore composites + %d water slab (slab ARID=%d)"
			% [wet - (1 if _water_surface_arid >= 0 else 0), 1 if _water_surface_arid >= 0 else 0, _water_surface_arid])

## Bake the water appearance into `_gen_wet_arid` + `_water_surface_arid`, appending (but NOT
## baking — the caller does one batched bake) to `library`. Returns the number of models appended.
## Each append asserts `add_model()` returns the expected ARID (anti-drift); a drift aborts,
## leaving the rest -1 (graceful dry-shape/cube fallback). Two flavours by `_waterlog_enabled`:
##   * NATIVE (WATERLOGGING §4): one waterlogged twin per co-filled composite pair — the UNION of
##     the water-line shore pairs (TerrainConfig.emitted_shore_pairs, liquid 9) and the SUBMERGED
##     floor pairs (emitted_submerged_pairs, liquid 10) — so BOTH cull as one fluid (no border).
##     Open-water surface cells reuse the water LRID's pure fluid model (no slab appended).
##   * LEGACY (WATER-SHORE §4.2): a wet composite per shore pair + the ONE 0.9 open-water slab.
## Called on the MAIN thread inside setup().
func _build_wet_manifest(library: Object, total: int) -> int:
	_gen_wet_arid = PackedInt32Array()
	_gen_wet_arid.resize(total * _GEN_STRIDE)
	_gen_wet_arid.fill(-1)
	if _waterlog_enabled:
		return _build_waterlog_manifest(library, total)
	var water_mat: Material = BlockMaterials.get_for(_water_id_of())
	var appended := 0
	for slot: int in TerrainConfig.emitted_shore_pairs():
		var mat := slot / _GEN_STRIDE                    # decode: slot = mat*256 + modifier
		var modifier := slot % _GEN_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total or modifier <= 0 or modifier >= _GEN_STRIDE:
			continue
		if _gen_wet_arid[slot] >= 0:
			continue                                     # a duplicate sample pair
		var model: Object = _make_wet_model(modifier, BlockMaterials.get_for(mat), water_mat)
		if model == null:
			continue                                     # no mesh-model class → dry-shape fallback
		var expected := _next_arid
		var got: int = _add_model(library, model)
		if got != expected:
			push_warning("[module_world] wet manifest ARID drift: add_model %d != expected %d" % [got, expected])
			return appended                              # abort water manifest; dry manifest stands
		_next_arid += 1
		_gen_wet_arid[slot] = got
		appended += 1
	# The one open-water surface slab.
	var slab: Object = _make_slab_model(water_mat)
	if slab != null:
		var expected := _next_arid
		var got: int = _add_model(library, slab)
		if got != expected:
			push_warning("[module_world] water slab ARID drift: add_model %d != expected %d" % [got, expected])
			return appended
		_next_arid += 1
		_water_surface_arid = got
		appended += 1
	return appended

## Native-waterlogging water manifest (WATERLOGGING §4.3-4.5). Bakes ONE waterlogged twin per
## co-filled composite (surface material, modifier) pair — the DRY terrain ramp additionally
## carrying the shared fluid — over the UNION of the shore (liquid 9) and submerged (liquid 10)
## emitted pairs, so every water cell (pure, shore, submerged) shares one fluid_index and culls
## together (the whole point: no border at the water line OR below it). Open-water surface cells
## resolve to the water LRID's pure fluid model (`_cube_arid[water]`), so NO slab is appended.
## Anti-drift as above; a drift aborts, leaving unbaked pairs -1 (dry-shape fallback: a border,
## never a hole). Twin count printed (bound: hundreds — |uw floor mats| × |emitted modifiers| +
## the shore pairs). Called on the MAIN thread inside setup(); appends but does not bake.
func _build_waterlog_manifest(library: Object, total: int) -> int:
	# Union the water-line shore pairs and the submerged floor pairs (dedup by slot). ONE twin per
	# shape serves both liquid 9 and liquid 10 (the engine fills to 0.9375 at the line, full when
	# covered), so a shared set is exactly right.
	var pairs := {}
	for slot: int in TerrainConfig.emitted_shore_pairs():
		pairs[slot] = true
	for slot: int in TerrainConfig.emitted_submerged_pairs():
		pairs[slot] = true
	var appended := 0
	for slot: int in pairs.keys():
		var mat := slot / _GEN_STRIDE                    # decode: slot = mat*256 + modifier
		var modifier := slot % _GEN_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total or modifier <= 0 or modifier >= _GEN_STRIDE:
			continue
		if _gen_wet_arid[slot] >= 0:
			continue                                     # a duplicate pair (shore ∩ submerged)
		var model: Object = _make_waterlogged_model(modifier, BlockMaterials.get_for(mat))
		if model == null:
			continue                                     # no mesh/waterlog API → dry-shape fallback
		var expected := _next_arid
		var got: int = _add_model(library, model)
		if got != expected:
			push_warning("[module_world] waterlog manifest ARID drift: add_model %d != expected %d" % [got, expected])
			return appended                              # abort water manifest; dry manifest stands
		_next_arid += 1
		_gen_wet_arid[slot] = got
		appended += 1
	# Open-water surface cells (liquid 9, modifier 0) render as the water LRID's pure fluid model.
	_water_surface_arid = _cube_arid_of(_water_id_of())
	print("[module_world] waterlog twins baked: %d (of %d unique composite pairs; water surface → fluid ARID %d)"
		% [appended, pairs.size(), _water_surface_arid])
	return appended

## Forward (mat, modifier) → ARID exactly as the voxel worker resolves it: AIR → 0, a
## full cube → its eager cube ARID, a shaped value → the frozen manifest ARID (cube
## fallback when that slot was never baked). Main-thread mirror of the generator's inline
## resolve — verify asserts the generated TYPE buffer equals this over a sample grid.
func gen_arid_for(mat: int, modifier: int, liquid_level := 0) -> int:
	if mat == BlockCatalog.AIR:
		return 0
	# Liquid-9 (the water line) resolves through the frozen water tables, exactly as the worker does.
	# Liquid-10 (submerged): NATIVE waterlogging routes it to the SAME twin table (WATERLOGGING §4.5)
	# so submerged water culls seamlessly; the LEGACY path leaves it to the dry resolve. Liquid-0
	# always falls to the dry resolve.
	if liquid_level == CellCodec.LIQ_LEVEL_SURFACE:
		if modifier == 0:
			return _water_surface_arid if _water_surface_arid >= 0 else _cube_arid_of(mat)
		var wslot := mat * _GEN_STRIDE + modifier
		if modifier < _GEN_STRIDE and wslot < _gen_wet_arid.size() and _gen_wet_arid[wslot] >= 0:
			return _gen_wet_arid[wslot]
		# unbaked wet pair → dry shape (fall through)
	elif _waterlog_enabled and liquid_level == CellCodec.LIQ_LEVEL_FULL and modifier != 0:
		var wslot := mat * _GEN_STRIDE + modifier
		if modifier < _GEN_STRIDE and wslot < _gen_wet_arid.size() and _gen_wet_arid[wslot] >= 0:
			return _gen_wet_arid[wslot]
		# unbaked submerged twin → dry shape (fall through)
	if modifier == 0:
		return _cube_arid_of(mat)
	var slot := mat * _GEN_STRIDE + modifier
	if modifier > 0 and modifier < _GEN_STRIDE and slot < _gen_arid.size() and _gen_arid[slot] >= 0:
		return _gen_arid[slot]
	return _cube_arid_of(mat)

## True if (mat, modifier) is pre-baked in the frozen manifest (or is a plain cube,
## always baked) — so the voxel worker never needs a lazy bake for it (VDS §8.3 gate).
func is_manifest_baked(mat: int, modifier: int) -> bool:
	if modifier == 0:
		return mat >= 0 and mat < _cube_arid.size()
	var slot := mat * _GEN_STRIDE + modifier
	return modifier < _GEN_STRIDE and slot < _gen_arid.size() and _gen_arid[slot] >= 0

## The runtime generator instance (verify's both-path ARID round-trip drives it
## directly). Null until setup() succeeds.
func get_generator() -> Object:
	return _generator

## Build a VoxelBlockyModelMesh for `modifier` from the shared ShapeMesh geometry (the
## one render seam — SVS §4). Returns null when the module lacks the mesh-model class.
func _make_shape_model(modifier: int, material: Material) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	# Share one ArrayMesh per shape across all materials (see _shape_mesh_cache).
	var amesh: ArrayMesh = _shape_mesh_cache.get(modifier, null)
	if amesh == null:
		amesh = ArrayMesh.new()
		_add_surface(amesh, ShapeMesh.build(modifier))
		_shape_mesh_cache[modifier] = amesh
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, material)
	return model

## True when the running godot_voxel exposes NATIVE waterlogging (WATERLOGGING.md §4): the
## VoxelBlockyModelFluid class (pure water) AND VoxelBlockyModel.set_waterlog_fluid (co-fill).
## Probed via ClassDB + a live has_method so the check is exact against the linked binary, not a
## version guess — an old editor/web template silently keeps the legacy composite path.
func _detect_waterlog() -> bool:
	if not ClassDB.class_exists("VoxelBlockyModelFluid") or not ClassDB.class_exists("VoxelBlockyFluid"):
		return false
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return false
	var probe: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	return probe != null and probe.has_method("set_waterlog_fluid")

## The ONE shared VoxelBlockyFluid (WATERLOGGING §4.1): water material + no downhill dip (a single
## registered level renders every water cell flat at TOP_HEIGHT). Referenced by the pure fluid
## water model AND every waterlogged twin, so all water lands in one fluid_index / material bucket.
## Returns null if the class is unavailable (setup() then disables waterlogging).
func _make_water_fluid() -> Object:
	var fluid: Object = ClassDB.instantiate("VoxelBlockyFluid")
	if fluid == null:
		return null
	if fluid.has_method("set_material"):
		fluid.call("set_material", BlockMaterials.get_for(_water_id_of()))
	if fluid.has_method("set_dip_when_flowing_down"):
		fluid.call("set_dip_when_flowing_down", false)
	return fluid

## The PURE-FLUID water model (WATERLOGGING §4.2): a VoxelBlockyModelFluid at level 1 (= max, so
## its surface sits at the engine TOP_HEIGHT 0.9375) carrying the shared fluid. Its material comes
## from the fluid; transparency_index == the water cull group (matching the legacy water cube) so
## fluid↔opaque culling is unchanged. Replaces the water LRID's cube in _configure_library, keeping
## the index==LRID invariant. Deep water columns cull to nothing inside the body (ocean fast path —
## fewer triangles than cube water). Returns null if the class is unavailable.
func _make_water_fluid_model() -> Object:
	if _water_fluid == null or not ClassDB.class_exists("VoxelBlockyModelFluid"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelFluid")
	if model == null:
		return null
	if model.has_method("set_fluid"):
		model.call("set_fluid", _water_fluid)
	if model.has_method("set_level"):
		model.call("set_level", 1)
	var cull_group: int = BlockCatalog.cull_group_of(_water_id_of())
	if cull_group > 0 and model.has_method("set_transparency_index"):
		model.call("set_transparency_index", cull_group)
	return model

## Build a WATERLOGGED TWIN (WATERLOGGING §4.3): a VoxelBlockyModelMesh of the DRY terrain ramp
## (reusing the SAME `_shape_mesh_cache[modifier]` ArrayMesh the dry shape uses — the solid IS the
## dry ramp, no water geometry baked in) that ADDITIONALLY carries the shared fluid via the native
## waterlog properties. The SOLID stays opaque (transparency_index 0 — load-bearing: neighbours
## judge this cell by its solid ramp, never its water, so no terrain holes) while its FLUID faces
## use the water cull group, so they cull seamlessly against every other water cell (pure, shore,
## submerged) sharing the fluid — the border-killer. `set_waterlog_level(1)` = full fill (the engine
## drops it to the 0.9375 line when uncovered, forces 1.0 when covered). Returns null when the
## mesh-model class or the waterlog API is unavailable (→ dry-shape fallback, a border not a hole).
func _make_waterlogged_model(modifier: int, terrain_material: Material) -> Object:
	if _water_fluid == null or not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null or not model.has_method("set_waterlog_fluid"):
		return null
	# Reuse the DRY shape mesh (plain `modifier` key), shared with _make_shape_model.
	var amesh: ArrayMesh = _shape_mesh_cache.get(modifier, null)
	if amesh == null:
		amesh = ArrayMesh.new()
		_add_surface(amesh, ShapeMesh.build(modifier))
		_shape_mesh_cache[modifier] = amesh
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, terrain_material)
	# The solid part is opaque (transparency_index 0) — keeps neighbours culling against the ramp,
	# never the water (no terrain holes, WATERLOGGING §5 risk 2). Set explicitly, not by default.
	if model.has_method("set_transparency_index"):
		model.call("set_transparency_index", 0)
	var cull_group: int = BlockCatalog.cull_group_of(_water_id_of())
	model.call("set_waterlog_fluid", _water_fluid)
	if model.has_method("set_waterlog_level"):
		model.call("set_waterlog_level", 1)
	if model.has_method("set_waterlog_fluid_transparency_index"):
		model.call("set_waterlog_fluid_transparency_index", cull_group)
	return model

## Build the WET COMPOSITE model (WATER-SHORE §4.3): a VoxelBlockyModelMesh whose ArrayMesh
## has TWO surfaces — surface 0 = the terrain ramp (ShapeMesh.build(modifier), terrain
## material), surface 1 = the water fill (WaterMesh.shore_fill(), water material). The model
## stays OPAQUE (transparency_index 0, the godot_voxel default — NOT set): its occlusion role
## is the terrain ramp, so adjacent water (index 1) can never cull the ramp's side trapezoids
## (no holes in terrain seen through water, §4.4). The water fill is modifier-independent, so
## the combined ArrayMesh is shared across every material for a given modifier via
## `_shape_mesh_cache` keyed `modifier | _WET_MESH_FLAG` (the material differs only via the
## per-surface override). Returns null when the module lacks the mesh-model class.
func _make_wet_model(modifier: int, terrain_material: Material, water_material: Material) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	var key := modifier | _WET_MESH_FLAG
	var amesh: ArrayMesh = _shape_mesh_cache.get(key, null)
	if amesh == null:
		amesh = ArrayMesh.new()
		_add_surface(amesh, ShapeMesh.build(modifier))    # surface 0: terrain ramp
		_add_surface(amesh, WaterMesh.shore_fill())       # surface 1: water fill to 0.9
		_shape_mesh_cache[key] = amesh
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, terrain_material)
		model.call("set_material_override", 1, water_material)
	# Make the OPAQUE role explicit (transparency_index 0). This is load-bearing: it is what
	# stops adjacent water (index 1) from culling the terrain ramp's side trapezoids (§4.4 —
	# no holes seen through water). Setting it here rather than relying on the godot_voxel
	# default guards against a future default change silently opening those holes.
	if model.has_method("set_transparency_index"):
		model.call("set_transparency_index", 0)
	return model

## Build the open-water surface SLAB model (WATER-SHORE §4.2): a VoxelBlockyModelMesh from
## WaterMesh.surface_slab() (top at y=0.9), water material, transparency_index ==
## BlockCatalog.cull_group_of(water) (== 1, matching the water cube) so slab↔cube face culling
## behaves. Returns null when the module lacks the mesh-model class.
func _make_slab_model(water_material: Material) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	var key := _WET_MESH_FLAG | 0xFFFF                    # a fixed slab key, distinct from any modifier
	var amesh: ArrayMesh = _shape_mesh_cache.get(key, null)
	if amesh == null:
		amesh = ArrayMesh.new()
		_add_surface(amesh, WaterMesh.surface_slab())
		_shape_mesh_cache[key] = amesh
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, water_material)
	var cull_group: int = BlockCatalog.cull_group_of(_water_id_of())
	if cull_group > 0 and model.has_method("set_transparency_index"):
		model.call("set_transparency_index", cull_group)
	return model

## Append one {verts, normals, uvs, indices} geometry dict as a triangle surface on `amesh`.
## Shared by the shape/wet/slab builders so the ShapeMesh/WaterMesh dict format is unpacked
## in exactly one place.
func _add_surface(amesh: ArrayMesh, geom: Dictionary) -> void:
	var surf := []
	surf.resize(Mesh.ARRAY_MAX)
	surf[Mesh.ARRAY_VERTEX] = geom["verts"]
	surf[Mesh.ARRAY_NORMAL] = geom["normals"]
	surf[Mesh.ARRAY_TEX_UV] = geom["uvs"]
	surf[Mesh.ARRAY_INDEX] = geom["indices"]
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)

## The water material's BlockCatalog id, resolved once (main thread; BlockCatalog.ensure_ready()
## already ran in setup()). Used for the water material + cull group of both water models.
func _water_id_of() -> int:
	if _water_id < 0:
		_water_id = BlockCatalog.id_of(&"water")
	return _water_id

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

## True once every mesh block intersecting the axis-aligned box of half-extents `half` around world
## point `center` has been MESHED (its surface applied to the scene, so it renders next frame). Used by
## ShaderPrewarm's PHASE 2 to hold the "Loading…" overlay until the near view has actually drawn —
## letting the module's VoxelMesherBlocky pipeline compile hidden. Returns false if the module lacks
## is_area_meshed (older build → prewarm falls back to its timeout).
func area_meshed(center: Vector3, half: Vector3) -> bool:
	if _terrain == null or not _terrain.has_method("is_area_meshed"):
		return false
	return bool(_terrain.call("is_area_meshed", AABB(center - half, half * 2.0)))

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
	var water_id := _water_id_of()
	for block_id in range(1, total):
		var cull_group: int = BlockCatalog.cull_group_of(block_id)
		var got: int
		if _waterlog_enabled and block_id == water_id:
			# The water LRID renders as a PURE FLUID model (WATERLOGGING §4.2), not a cube — so deep
			# water culls internally and every water cell shares the one fluid. Falls back to a cube
			# if the fluid model can't be built, preserving the index==LRID invariant either way.
			var fluid_model: Object = _make_water_fluid_model()
			got = _add_model(library, fluid_model) if fluid_model != null else _add_cube(library, BlockMaterials.get_for(block_id), cull_group)
		else:
			got = _add_cube(library, BlockMaterials.get_for(block_id), cull_group)
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

# Frozen appearance tables set by the loader (main thread) BEFORE this generator runs.
# The worker reads them ONLY (never resized/mutated after freeze), so mapping a shaped
# generated cell to its baked ARID is allocation-free and race-free (VDS §8.3).
var cube_arid: PackedInt32Array         # LRID -> cube ARID
var gen_arid: PackedInt32Array          # (mat*GEN_STRIDE + modifier) -> ARID; -1 = not baked
var gen_wet_arid: PackedInt32Array      # (mat*GEN_STRIDE + modifier) -> wet/twin ARID; -1 = not baked
var water_surface_arid := -1            # open-water surface cell model ARID; -1 = not baked
var waterlog := false                   # native waterlogging on → submerged composites route to twins
const GEN_STRIDE := 256

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
	var ncube = cube_arid.size()
	var ngen = gen_arid.size()
	var nwet = gen_wet_arid.size()

	# CHEAP all-air early-outs, BEFORE the per-column profile pass (PERF): a block entirely above
	# ALL possible content (the proven surface bound + tallest tree, and above the sea cap) or
	# entirely below the bedrock floor generates nothing, so it must not pay the ~column-profile
	# pass at all. Uses only CONSTANTS (no noise). MAX_SURFACE_Y is a proven upper bound on
	# height_at (verify asserts it), so this can never skip a block that holds real content.
	if oy > TerrainConfig.MAX_SURFACE_Y + max_above and oy > sea:
		return
	if oy + size.y <= TerrainConfig.BEDROCK_FLOOR:
		return

	# Per-column profile cache: Vector4(g, biome, c, t). Value type -> no per-cell
	# noise sampling and no allocation.
	var profs = []
	profs.resize(size.x * size.z)
	var max_h = -0x7fffffff
	# Per-block column-profile memo (Vector2i -> Vector4) for the smoothing corner-target
	# stencil AND the tree overlay (PERF): each surface/cap cell samples a 3x3 column-top
	# stencil that overlaps its neighbours', and TreeGen re-derives its base-column biome per
	# cell — so without a memo columns are re-noised many times per block. Seeded here from the
	# profile pass and reused by resolve_cell -> smoothing + TreeGen.block_at; it only pads +1
	# at block edges. LOCAL to this _generate_block frame -> each voxel worker owns its own dict;
	# never shared across threads. Values are the exact column_profile -> output byte-identical.
	var pcache = {}
	for z in range(size.z):
		for x in range(size.x):
			var p = TerrainConfig.column_profile(ox + x, oz + z, pcache)
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
				var v = TerrainConfig.resolve_cell(wx, oy + y, wz, g, biome, cc, tt, pcache)
				var id = CellCodec.mat(v)
				if id == 0:
					continue
				# Map (material, modifier) -> baked ARID via the frozen tables (VDS §8.1).
				# A full cube (the overwhelming common case, incl. all sub-surface + flat
				# terrain) writes its cube ARID (== LRID for bootstrap) -> byte-identical
				# TYPE to the pre-smoothing world. A smoothed surface/cap cell writes its
				# pre-baked manifest ARID; -1 (unbaked) falls back to the plain cube.
				var modifier = CellCodec.modifier(v)
				var arid = 0
				# Liquid-9 (the water line): the frozen water tables — the open-water surface model for
				# modifier 0 (native: the pure fluid ARID; legacy: the 0.9 slab), the wet/twin model for
				# a composite (modifier != 0) — degrading to dry-shape then cube, never a hole.
				# Liquid-10 (submerged composite): NATIVE waterlogging routes it to the SAME twin table
				# (WATERLOGGING §4.5) so submerged water culls seamlessly against the water around it (the
				# last underwater border); LEGACY leaves it to the dry-shape resolve below (a border).
				# Liquid-0 (deep water / sub-surface): the UNCHANGED cube/shape fast paths.
				var lvl = CellCodec.liquid_level(v)
				if lvl == CellCodec.LIQ_LEVEL_SURFACE:
					if modifier == 0:
						arid = water_surface_arid if water_surface_arid >= 0 else (cube_arid[id] if id < ncube else id)
					else:
						var wslot = id * GEN_STRIDE + modifier
						if modifier < GEN_STRIDE and wslot < nwet and gen_wet_arid[wslot] >= 0:
							arid = gen_wet_arid[wslot]
						elif modifier < GEN_STRIDE and wslot < ngen and gen_arid[wslot] >= 0:
							arid = gen_arid[wslot]
						else:
							arid = cube_arid[id] if id < ncube else id
				elif waterlog and lvl == CellCodec.LIQ_LEVEL_FULL and modifier != 0:
					var wslot = id * GEN_STRIDE + modifier
					if modifier < GEN_STRIDE and wslot < nwet and gen_wet_arid[wslot] >= 0:
						arid = gen_wet_arid[wslot]
					elif modifier < GEN_STRIDE and wslot < ngen and gen_arid[wslot] >= 0:
						arid = gen_arid[wslot]
					else:
						arid = cube_arid[id] if id < ncube else id
				elif modifier == 0:
					arid = cube_arid[id] if id < ncube else id
				else:
					var slot = id * GEN_STRIDE + modifier
					if modifier < GEN_STRIDE and slot < ngen and gen_arid[slot] >= 0:
						arid = gen_arid[slot]
					else:
						arid = cube_arid[id] if id < ncube else id
				buffer.set_voxel(arid, x, y, z, ch)
"""
	var gen_script := GDScript.new()
	gen_script.source_code = src
	var err := gen_script.reload()
	if err != OK:
		push_warning("[module_world] generator compile failed: %d" % err)
		return null
	var gen: Object = gen_script.new()
	# Publish the frozen tables to the worker-side generator (read-only from here on).
	gen.set("cube_arid", _cube_arid)
	gen.set("gen_arid", _gen_arid)
	gen.set("gen_wet_arid", _gen_wet_arid)               # wet composites / waterlogged twins
	gen.set("water_surface_arid", _water_surface_arid)   # open-water surface model (slab or fluid)
	gen.set("waterlog", _waterlog_enabled)               # WATERLOGGING §4.5: route submerged → twins
	return gen

# --- helpers -------------------------------------------------------------------
# Set a property only if the object actually exposes it (avoids error spam if a
# module property name drifts between versions).
func _set_if(obj: Object, prop: String, value: Variant) -> void:
	for p in obj.get_property_list():
		if p.get("name", "") == prop:
			obj.set(prop, value)
			return
