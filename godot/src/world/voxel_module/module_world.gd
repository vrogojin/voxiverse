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
## (deadlock -> no meshes -> blank world). We pin it to a FIXED 2 worker threads
## via the `voxel/threads/count/*` project settings (project.godot:63,
## minimum=2, ratio_over_max=0.0 → device-independent); that pool is created at
## engine start from those settings. Worldgen is per-block independent and (in
## curved mode) a pure function of the frozen gen_face, so >=2 workers parallelise
## it race-free (COSMOS-AUDIT §3.2).

var _terrain: Node3D
var _viewer: Node
var _mesher: Object                     # the VoxelMesherBlocky (kept so restream can rebuild the terrain)
# COSMOS frozen-epoch (docs/COSMOS-AUDIT.md §3.2 items 3–4): the cube face this generator epoch is
# homed on. Frozen onto each generator instance as `gen_face` at creation; a home-face flip creates a
# NEW generator (new face) and restreams, rather than mutating the face workers are reading.
var _gen_face := CubeSphere.HOME_FACE

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

# --- snow-cap state variant table (M1 snowy-world ADR §5) -----------------------
# A PARALLEL per-state frozen table (the liquid-twin discipline), NOT a re-keyed _gen_arid: for
# each cappable material (grass/podzol/sand) and each emitted modifier (incl. the plain cube at
# modifier 0), the snow-VARIANT model's ARID, keyed `mat*_GEN_STRIDE + modifier`. Baked + FROZEN
# at setup before the worker wires, sampled/dense, dry/plain fallback on an unbaked slot — never a
# hole (a bare cap, wrong skin but correct substance). Shaped variants REUSE _shape_mesh_cache
# (zero new ArrayMeshes / GPU readbacks); the cube variant is a fresh cube with the snow material.
var _snow_arid: PackedInt32Array         # (mat*_GEN_STRIDE + modifier) -> snow-variant ARID; -1 = not baked; frozen at setup

# --- snow LAYER shape family table (SNOW-ACCUMULATION §1.5) ----------------------
# The FAM LAYER modifier is >= 0x8000 (bit 15) and CANNOT slot the 256-stride _gen_arid (re-keying to
# 65536 would balloon every table). So a DEDICATED tiny table keyed by LEVEL (the M1 _snow_arid
# discipline: a parallel per-value frozen table, not a re-keyed stride): index = level (1..4, 6..9),
# snow_block ONLY (the curated LAYER material). Level 5 == the corner slab (85, in _gen_arid) and level
# 10 == the full cube (0), so those two indices stay -1 and resolve via the cube/gen tables instead.
# Baked + FROZEN at setup before the worker wires, published to the worker generator; an unbaked slot
# falls back to the snow cube (too-tall, right substance, never a hole — the §1.5 safety default).
var _layer_arid: PackedInt32Array        # level -> snow_block LAYER ARID; -1 = not baked; frozen at setup
var _snow_id := -1                        # cached BlockCatalog.id_of(&"snow_block") (main thread)

# --- snow-FILL composite tables (SNOW-ACCUMULATION §2.6/§2.7) --------------------
# Curated 2-surface baked composites — surface 0 the snow-capped terrain ramp, surface 1 the snow LAYER
# fill (the wet-composite pattern, but snow instead of water). ONE table per curated fill level
# L∈{3,5,8,10}, keyed `mat*_GEN_STRIDE + modifier` (corner modifiers < 256, so the stride is valid).
# The render maps the true tenth-level UP to the nearest baked level (feet slightly dusted, never
# floating). A -1 slot (unbaked pair) degrades on the worker to the M1 snow-cap SKIN → the dry ramp →
# the cube (the §2.7 ladder, never a hole). Baked + FROZEN at setup before the worker wires.
var _comp_arid_l3: PackedInt32Array
var _comp_arid_l5: PackedInt32Array
var _comp_arid_l8: PackedInt32Array
var _comp_arid_l10: PackedInt32Array
const _COMP_MESH_FLAG := 1 << 22         # _shape_mesh_cache key bit for snow-fill composite meshes
# --- SHARP-SLOPE dedicated frozen tables (SHARP-SLOPE §4.1) ----------------------
# FAM SLOPE modifiers are >= 0x8000 so they can NEVER slot the 256-stride _gen_arid table; a dense
# per-family stride (the 12-bit payload) is cheap (~count()×4096×4B ≈ 1.2 MB each). Baked + FROZEN at
# setup over emitted_slope_pairs(); -1 (unbaked) → plain cube fallback on the worker (never a hole).
# The snow twin reuses the SAME per-payload ArrayMesh (BlockMaterials.snow_capped_for override, zero
# extra GPU readbacks), the _snow_arid discipline.
const _SLOPE_STRIDE := 4096
var _slope_arid: PackedInt32Array        # (mat*_SLOPE_STRIDE + payload) -> ARID; -1 = not baked; frozen at setup
var _snow_slope_arid: PackedInt32Array   # (mat*_SLOPE_STRIDE + payload) -> snow-capped slope ARID; -1 = not baked

# --- liquid appearance, PER KIND (WATER-SHORE §4.2 / WATERLOGGING §4 / MULTI-LIQUID §2.2) -----
# Generalized from the water-only wiring to one set of tables PER liquid kind (CellCodec
# LIQ_WATER=1, LIQ_LAVA=2, a third reserved at 3); index 0 (LIQ_NONE) is unused, so every table
# is a tiny fixed 4-element Array. All are frozen publications baked at setup (same discipline as
# `_gen_arid`), BEFORE the generator is wired, so the worker only reads them (zero allocation,
# race-free). A kind with no declared liquid material leaves its slot null/-1.
#   * `_gen_twin_arid[kind]` — a PackedInt32Array (keyed `mat * _GEN_STRIDE + modifier`) giving the
#     WATERLOGGED-TWIN model ARID for each co-filled (surface material, modifier) composite pair
#     worldgen emits FOR THAT KIND. Two engine-dependent flavours:
#       - NATIVE WATERLOGGING (WATERLOGGING.md, `_waterlog_enabled`): a VoxelBlockyModelMesh of the
#         DRY terrain ramp that ADDITIONALLY carries that kind's shared fluid (set_waterlog_*), so
#         its liquid culls seamlessly against every other cell of the same kind (pure and composite,
#         shore AND submerged) — no border. ONE twin per shape covers BOTH the liquid-line (level 9)
#         and submerged (level 10) composites (the engine picks the fill height from the cell above).
#       - LEGACY composite (old engine): WATER ONLY — the wet composite (terrain ramp + a 0.9 water
#         slab surface) at the water line; other kinds stay null → they render as plain liquid cubes
#         (degraded, never a hole, NEVER water-skinned — MULTI-LIQUID §2.2.4).
#     A slot left -1 (unbaked pair) falls back to the DRY shaped model then the cube — a notch,
#     never a hole.
#   * `_surface_arid[kind]` — the open-liquid surface cell's model ARID for that kind. Native: the
#     kind's LRID PURE FLUID model (== `_cube_arid[lrid]`); legacy: `_surface_arid[LIQ_WATER]` is the
#     ONE 0.9 water slab and every other kind stays -1 (legacy renders their surface as a plain cube).
# The legacy wet fill is modifier-INDEPENDENT (WATER-SHORE §4.3), so its ArrayMesh is shared across
# materials via `_shape_mesh_cache` keyed `modifier | _WET_MESH_FLAG`. The native twins instead REUSE
# the dry `_shape_mesh_cache[modifier]` ArrayMesh directly (their solid IS the dry ramp — shared
# across kinds too), so no liquid-shape mesh multiplier at all.
var _gen_twin_arid: Array = [null, null, null, null]     # kind -> PackedInt32Array; null = no such liquid
var _surface_arid := PackedInt32Array([-1, -1, -1, -1])  # kind -> liquid-surface model ARID; -1 = not baked
var _water_id := -1                      # cached BlockCatalog.id_of(&"water") (main thread; legacy water path)
const _WET_MESH_FLAG := 1 << 20          # _shape_mesh_cache key bit for LEGACY wet composite meshes
# --- NATIVE WATERLOGGING (WATERLOGGING.md §4 / MULTI-LIQUID §2.2) ---------------
# Feature-detected in setup(): true when the running engine exposes godot_voxel's native
# solid+fluid co-fill (VoxelBlockyModelFluid + VoxelBlockyModel.set_waterlog_fluid). When true,
# each declared liquid renders as a VoxelBlockyModelFluid and every co-filled composite as a
# waterlogged twin, so all cells of a kind share ONE fluid_index and cull together (no shore/
# submerged border). When false (old binary), the LEGACY water-only slab+wet-composite path is
# used unchanged (graceful degrade; non-water liquids fall to plain cubes).
var _waterlog_enabled := false
var _fluids: Array = [null, null, null, null]            # kind -> VoxelBlockyFluid; null = no such liquid
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

	# Feature-detect native waterlogging (WATERLOGGING.md §4). When present, build ONE
	# VoxelBlockyFluid PER declared liquid kind NOW — before _configure_library (which turns each
	# liquid LRID into a pure fluid model referencing it) and _build_gen_manifest (which bakes
	# waterlogged twins referencing it). On any instantiate failure (no fluid at all) we fall back
	# to the legacy composite path (never a crash).
	_waterlog_enabled = _detect_waterlog()
	if _waterlog_enabled:
		_build_fluids()
		var any_fluid := false
		for k in range(1, _fluids.size()):
			if _fluids[k] != null:
				any_fluid = true
				break
		if not any_fluid:
			_waterlog_enabled = false
	print("[module_world] native waterlogging: %s" % ("ENABLED" if _waterlog_enabled else "absent (legacy composite path)"))
	if _waterlog_enabled:
		print("[module_world] fluids registered: water=%s lava=%s (ascending-kind order → deterministic fluid_index)"
			% [_fluids[CellCodec.LIQ_WATER] != null, _fluids[CellCodec.LIQ_LAVA] != null])

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
	_mesher = mesher

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
					# VoxelBuffer.CHANNEL_TYPE == 0. arid_for_cell (not arid_for) so a bundle-loaded capped /
					# liquid cell renders its full look — arid_for drops the state axis (M1 ADR §5.2).
					buf.call("set_voxel", arid_for_cell(packed),
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

## Resolve a full PACKED cell value → ARID, honouring the WATER-SHORE liquid rule (§4.6),
## generalized PER liquid kind (MULTI-LIQUID §2.2.5). A level-9 value (the liquid line) consults
## that kind's frozen tables first — `_surface_arid[kind]` for the open-liquid surface cell
## (modifier 0), the kind's twin table ARID for a shore composite (modifier != 0) — then falls
## through to the DRY resolve (`arid_for`) when the liquid model was not baked (graceful: liquid
## cube / dry shape, never a hole). Level-10 (submerged) resolves to the SAME waterlogged twin (of
## its kind) as its level-9 sibling when native waterlogging is enabled (so submerged liquid culls
## seamlessly — the last underwater border); on a legacy engine it falls through to the dry resolve.
## Player edits never produce liquid values (placement rejects non-solid materials, break writes 0),
## so this is worldgen-mirror only.
func arid_for_cell(packed: int) -> int:
	var lf := CellCodec.liquid_field(packed)
	if lf != 0:
		var lk := lf & CellCodec.LIQ_KIND_MASK
		var lvl := lf >> 2
		if lvl == CellCodec.LIQ_LEVEL_SURFACE:
			var mat := CellCodec.mat(packed)
			var modifier := CellCodec.modifier(packed)
			if modifier == 0:
				if lk < _surface_arid.size() and _surface_arid[lk] >= 0:
					return _surface_arid[lk]               # else fall through: liquid cube via arid_for
			else:
				var twin = _gen_twin_arid[lk] if lk < _gen_twin_arid.size() else null
				if twin != null:
					var wslot := mat * _GEN_STRIDE + modifier
					if modifier < _GEN_STRIDE and wslot < twin.size() and twin[wslot] >= 0:
						return twin[wslot]                 # else fall through: dry shape via arid_for
		elif _waterlog_enabled and lvl == CellCodec.LIQ_LEVEL_FULL:
			# Native waterlogging (WATERLOGGING §4.5): a SUBMERGED composite (level 10, modifier != 0)
			# resolves to the SAME waterlogged twin (of its kind) as its liquid-line (level 9) sibling,
			# so submerged liquid culls seamlessly against the surrounding cells of that kind — the last
			# underwater border. -1 (unbaked) falls through to the dry shape (a border, never a hole).
			var mat := CellCodec.mat(packed)
			var modifier := CellCodec.modifier(packed)
			if modifier != 0:
				var twin = _gen_twin_arid[lk] if lk < _gen_twin_arid.size() else null
				if twin != null:
					var wslot := mat * _GEN_STRIDE + modifier
					if modifier < _GEN_STRIDE and wslot < twin.size() and twin[wslot] >= 0:
						return twin[wslot]
	# Snow-FILL composite (SNOW-ACCUMULATION §2.6): a terrain ramp buried/filled by the snow plane wins
	# over the plain snow-cap skin (a filled cell is always cold ⇒ also capped). The true level rounds UP
	# to a baked {3,5,8,10}; an unbaked composite falls through to the snow-cap skin below (the ladder).
	if lf == 0:
		var ffill := CellCodec.snow_fill(packed)
		if ffill != 0:
			var ca := _comp_arid_of(CellCodec.mat(packed), CellCodec.modifier(packed), ffill)
			if ca >= 0:
				return ca
	# SHARP-SLOPE (§4.2): a generated SLOPE cell (FAM bit 15, land-only so lf==0) resolves through the
	# dedicated frozen slope tables — the snow-capped twin when capped, else the dry slope model; an
	# unbaked payload falls through to arid_for → plain cube (wrong silhouette, right substance).
	if lf == 0 and CellCodec.is_slope(CellCodec.modifier(packed)):
		var pmat := CellCodec.mat(packed)
		var payload := CellCodec.modifier(packed) & 0xFFF
		var pslot := pmat * _SLOPE_STRIDE + payload
		if CellCodec.has_state(packed, CellCodec.STATE_SNOW_CAPPED) \
				and pslot < _snow_slope_arid.size() and _snow_slope_arid[pslot] >= 0:
			return _snow_slope_arid[pslot]
		if pslot < _slope_arid.size() and _slope_arid[pslot] >= 0:
			return _slope_arid[pslot]
		# else fall through to arid_for (lazy placement path / cube fallback)
	# Snow-cap state variant (M1 ADR §5.2): a capped cell (state bit set, no liquid — liquid wins if
	# both ever coexist) resolves to its frozen snow-variant ARID; an unbaked (mat, modifier) snow
	# slot falls through to the plain look (a bare cap, wrong skin but correct substance, never a hole).
	if lf == 0 and CellCodec.has_state(packed, CellCodec.STATE_SNOW_CAPPED):
		var smat := CellCodec.mat(packed)
		var smod := CellCodec.modifier(packed)
		var sslot := smat * _GEN_STRIDE + smod
		if smod < _GEN_STRIDE and sslot < _snow_arid.size() and _snow_arid[sslot] >= 0:
			return _snow_arid[sslot]
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
	# FAM LAYER (SNOW-ACCUMULATION §1.5): snow depth on the modifier axis. A snow_block layer reuses
	# the pre-baked LEVEL table; any other material or an uncached level falls through to the lazy
	# ShapeMesh append below (ShapeMesh.build handles LAYER), keyed on the raw FAM modifier.
	if CellCodec.is_layer(modifier):
		var lvl := CellCodec.layer_level(modifier)
		if mat == _snow_id_of() and lvl >= 0 and lvl < _layer_arid.size() and _layer_arid[lvl] >= 0:
			return _layer_arid[lvl]
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

	# Snow-cap state variants (M1 ADR §5.2): a snow-variant cube + snow-variant shape per emitted
	# modifier for each cappable material, frozen into `_snow_arid`. Reuses _shape_mesh_cache for the
	# shapes (zero new ArrayMeshes / GPU readbacks). Same anti-drift discipline; a drift leaves the
	# rest -1 (plain-look fallback, never a hole).
	var snow := _build_snow_manifest(library, total)
	appended += snow

	# Snow LAYER shape family (SNOW-ACCUMULATION §1.5): the variable-height snow depth on the FAM
	# modifier axis, keyed by LEVEL in the dedicated `_layer_arid` table (snow_block only).
	var layers := _build_layer_manifest(library)
	appended += layers

	# Snow-FILL composites (SNOW-ACCUMULATION §2.6/§2.7): the curated 2-surface baked models for a
	# terrain ramp buried/filled by the snow plane, at levels {3,5,8,10} — the largest bake line item.
	var comps := _build_comp_manifest(library, total)
	appended += comps
	# SHARP-SLOPE dedicated slope tables (§4.1): dry + snow-capped variants per emitted (mat, payload).
	var slope := _build_slope_manifest(library, total)
	appended += slope

	if appended > 0 and library.has_method("bake"):
		library.call("bake")                             # one batched bake: dry shapes + water + snow + slope models
	print("[module_world] baked appearance manifest: %d (material,modifier) generated shapes (%d materials x %d emitted modifiers; full set would be %d)"
		% [appended - wet - snow - layers - comps - slope, mats.size(), mods.size(), mats.size() * TerrainConfig.appearance_modifiers().size()])
	print("[module_world] baked snow manifest: %d snow-cap variant models for %d cappable materials"
		% [snow, TerrainConfig.snow_cappable_materials().size()])
	print("[module_world] baked snow LAYER manifest: %d snow_block depth-level models (SNOW-ACCUMULATION §1.5)" % layers)
	print("[module_world] baked snow-FILL composites: %d models over %d cold (mat,modifier) pairs x levels {3,5,8,10} (SNOW-ACCUMULATION §2.7)"
		% [comps, TerrainConfig.emitted_cold_pairs().size()])
	print("[module_world] baked slope manifest: %d SHARP-SLOPE models (%d emitted (mat,payload) pairs, incl. snow twins)"
		% [slope, TerrainConfig.emitted_slope_pairs().size()])
	if _waterlog_enabled:
		print("[module_world] baked waterlog manifest: %d waterlogged composite twins total; surface ARIDs water=%d lava=%d"
			% [wet, _surface_arid[CellCodec.LIQ_WATER], _surface_arid[CellCodec.LIQ_LAVA]])
	else:
		print("[module_world] baked legacy water manifest: %d models (water slab ARID=%d; non-water liquids render as plain cubes)"
			% [wet, _surface_arid[CellCodec.LIQ_WATER]])

## Bake the snow-cap state VARIANT models and freeze them into `_snow_arid` (M1 ADR §5.2). For each
## cappable material (grass/podzol/sand/stone — stone tops B_MOUNTAINS peaks) it appends: a snow-variant
## CUBE at slot `mat*_GEN_STRIDE+0`
## (a full capped cell), then a snow-variant SHAPE at each emitted modifier (`mat*_GEN_STRIDE+mod`),
## REUSING `_shape_mesh_cache[modifier]` so no new ArrayMesh / GPU readback is created — only the
## per-model material override differs (BlockMaterials.snow_capped_for). Returns the count appended.
## Same anti-drift discipline as the dry loop (add_model() == expected ARID); a drift aborts, leaving
## the rest -1 (the plain look falls back on the worker — a bare cap, never a hole, §5.5). Called on
## the MAIN thread inside setup(); appends but does not bake (the caller does one batched bake).
func _build_snow_manifest(library: Object, total: int) -> int:
	_snow_arid = PackedInt32Array()
	_snow_arid.resize(total * _GEN_STRIDE)
	_snow_arid.fill(-1)
	var mods := TerrainConfig.emitted_modifiers()
	var appended := 0
	for mat: int in TerrainConfig.snow_cappable_materials():
		if mat <= BlockCatalog.AIR or mat >= total:
			continue
		var variant: Material = BlockMaterials.snow_capped_for(mat)
		# The snow-variant CUBE (a full capped cell) at modifier 0.
		var expected := _next_arid
		var got: int = _add_cube(library, variant, BlockCatalog.cull_group_of(mat))
		if got != expected:
			push_warning("[module_world] snow manifest cube ARID drift: add_model %d != expected %d" % [got, expected])
			return appended                              # abort snow manifest; dry + water manifests stand
		_next_arid += 1
		_snow_arid[mat * _GEN_STRIDE + 0] = got
		appended += 1
		# The snow-variant SHAPES (reuse the shared dry ArrayMesh; only the material override differs).
		for modifier: int in mods:
			if modifier <= 0 or modifier >= _GEN_STRIDE:
				continue
			var model: Object = _make_shape_model(modifier, variant)
			if model == null:
				continue                                 # no mesh-model class → cube/plain fallback
			var exp2 := _next_arid
			var got2: int = _add_model(library, model)
			if got2 != exp2:
				push_warning("[module_world] snow manifest ARID drift: add_model %d != expected %d" % [got2, exp2])
				return appended
			_next_arid += 1
			_snow_arid[mat * _GEN_STRIDE + modifier] = got2
			appended += 1
	return appended

## Bake the snow LAYER shape models and freeze them into `_layer_arid` (SNOW-ACCUMULATION §1.5). For
## each canonical FAM level (1..4, 6..9 — level 5 == the corner slab 85 already in `_gen_arid`, level
## 10 == the full cube) it appends a snow_block LAYER model (a thin flat slab at level/10) and records
## its ARID at index = level. Returns the count appended. The ArrayMesh is shared via `_shape_mesh_cache`
## keyed on the raw FAM modifier (bit 15 keeps it disjoint from every corner/wet/slab key). Same
## anti-drift discipline as the dry loop; a drift aborts, leaving the rest -1 (the snow cube falls back
## on the worker — a too-tall block, never a hole). Called on the MAIN thread inside setup(); appends
## but does not bake (the caller does one batched bake).
func _build_layer_manifest(library: Object) -> int:
	_layer_arid = PackedInt32Array()
	_layer_arid.resize(11)                               # index = level 0..10
	_layer_arid.fill(-1)
	var snow_id := _snow_id_of()
	if snow_id <= BlockCatalog.AIR:
		return 0
	var variant: Material = BlockMaterials.get_for(snow_id)
	var appended := 0
	for level in [1, 2, 3, 4, 6, 7, 8, 9]:
		var modifier := CellCodec.make_layer(level)      # the raw FAM modifier for this level
		var model: Object = _make_shape_model(modifier, variant)
		if model == null:
			continue                                     # no mesh-model class → snow-cube fallback
		var expected := _next_arid
		var got: int = _add_model(library, model)
		if got != expected:
			push_warning("[module_world] layer manifest ARID drift: add_model %d != expected %d" % [got, expected])
			return appended                              # abort layer manifest; dry/water/snow stand
		_next_arid += 1
		_layer_arid[level] = got
		appended += 1
	return appended

## Bake the snow-FILL composite models and freeze them into `_comp_arid_l{3,5,8,10}` (SNOW-ACCUMULATION
## §2.6/§2.7). For each cold (surface/cap material, corner modifier) pair TerrainConfig.emitted_cold_pairs()
## samples, appends ONE 2-surface model per curated level: surface 0 = the snow-CAPPED terrain ramp (a
## filled cell is always cold ⇒ capped, so the exposed ramp reads white), surface 1 = the snow LAYER fill
## at the level. Meshes are shared across materials per (modifier, level) via `_shape_mesh_cache`; only the
## per-surface material override differs. Same anti-drift discipline as the dry loop; a drift aborts,
## leaving the rest -1 (the M1 cap skin / dry ramp falls back on the worker — never a hole). Called on the
## MAIN thread inside setup(); appends but does not bake (the caller does one batched bake). Returns the
## count appended. This is the §2.7 bake-budget line item; the trim ladder is levels {5,10} then dropping
## stone composites (safe because the fallback ends at the M1 skin, not a hole).
func _build_comp_manifest(library: Object, total: int) -> int:
	_comp_arid_l3 = PackedInt32Array(); _comp_arid_l3.resize(total * _GEN_STRIDE); _comp_arid_l3.fill(-1)
	_comp_arid_l5 = PackedInt32Array(); _comp_arid_l5.resize(total * _GEN_STRIDE); _comp_arid_l5.fill(-1)
	_comp_arid_l8 = PackedInt32Array(); _comp_arid_l8.resize(total * _GEN_STRIDE); _comp_arid_l8.fill(-1)
	_comp_arid_l10 = PackedInt32Array(); _comp_arid_l10.resize(total * _GEN_STRIDE); _comp_arid_l10.fill(-1)
	var snow_mat: Material = BlockMaterials.get_for(_snow_id_of())
	var appended := 0
	for slot: int in TerrainConfig.emitted_cold_pairs():
		var mat := slot / _GEN_STRIDE
		var modifier := slot % _GEN_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total or modifier <= 0 or modifier >= _GEN_STRIDE:
			continue
		if CellCodec.is_layer(modifier):
			continue                                     # a LAYER cap is baked in _layer_arid, not here
		var skin: Material = BlockMaterials.snow_capped_for(mat)   # surface-0 = the capped ramp (cold ⇒ white)
		for level in [3, 5, 8, 10]:
			var model: Object = _make_composite_model(modifier, level, skin, snow_mat)
			if model == null:
				continue                                 # no mesh-model class → cap-skin/dry fallback
			var expected := _next_arid
			var got: int = _add_model(library, model)
			if got != expected:
				push_warning("[module_world] comp manifest ARID drift (L%d): add_model %d != expected %d" % [level, got, expected])
				return appended                          # abort composites; dry/snow/layer manifests stand
			_next_arid += 1
			match level:
				3: _comp_arid_l3[slot] = got
				5: _comp_arid_l5[slot] = got
				8: _comp_arid_l8[slot] = got
				10: _comp_arid_l10[slot] = got
			appended += 1
	return appended

## Build a snow-FILL composite VoxelBlockyModelMesh (SNOW-ACCUMULATION §2.6): surface 0 = the terrain
## ramp (ShapeMesh.build(modifier), the snow-capped skin material), surface 1 = the snow LAYER fill at
## `level` (ShapeMesh.build(make_layer(level)), the snow_block material). The snow surface is lifted a
## deterministic +0.001 to kill the coplanar z-fight when a ramp triangle sits exactly at the plane. The
## model stays OPAQUE (transparency_index 0) — its occlusion role is the terrain ramp, so adjacent snow
## can never cull it. The combined ArrayMesh is shared across materials per (modifier, level) via
## `_shape_mesh_cache` (the _COMP_MESH_FLAG keyspace, disjoint from corner/FAM/wet keys). Null when the
## module lacks the mesh-model class.
func _make_composite_model(modifier: int, level: int, terrain_material: Material, snow_material: Material) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	var key := modifier | (level << 8) | _COMP_MESH_FLAG
	var amesh: ArrayMesh = _shape_mesh_cache.get(key, null)
	if amesh == null:
		amesh = ArrayMesh.new()
		_add_surface(amesh, ShapeMesh.build(modifier))          # surface 0: the (capped) terrain ramp
		_add_surface(amesh, _snow_fill_geom(level))             # surface 1: the snow LAYER fill (eps-lifted)
		_shape_mesh_cache[key] = amesh
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, terrain_material)
		model.call("set_material_override", 1, snow_material)
	if model.has_method("set_transparency_index"):
		model.call("set_transparency_index", 0)                 # opaque: the ramp is the occlusion role
	return model

## The snow LAYER fill geometry at `level`, lifted +0.001 in y so a coplanar ramp triangle (only at
## level 5 vs corners-1) never z-fights the snow plane (SNOW-ACCUMULATION §2.6 epsilon). make_layer(10)
## == 0 → a full cube (the buried case); make_layer(5) == 85 → the half-slab; 3/8 → thin FAM slabs.
func _snow_fill_geom(level: int) -> Dictionary:
	var geom := ShapeMesh.build(CellCodec.make_layer(level))
	var verts: PackedVector3Array = geom["verts"]
	var lifted := PackedVector3Array()
	lifted.resize(verts.size())
	for i in verts.size():
		lifted[i] = verts[i] + Vector3(0.0, 0.001, 0.0)
	geom["verts"] = lifted
	return geom

## The snow_block LRID, resolved once (main thread; BlockCatalog.ensure_ready() ran in setup()).
func _snow_id_of() -> int:
	if _snow_id < 0:
		_snow_id = BlockCatalog.id_of(&"snow_block")
	return _snow_id

## Bake the SHARP-SLOPE models into `_slope_arid` (and snow twins into `_snow_slope_arid`), keyed
## `mat * _SLOPE_STRIDE + payload` over TerrainConfig.emitted_slope_pairs() (§4.1). ONE ArrayMesh per
## payload is shared across materials AND the snow twin via `_shape_mesh_cache[raw FAM modifier]`
## (bit 15 keeps slope keys disjoint from all corner/LAYER/wet keys). Same anti-drift discipline
## (add_model() == expected ARID); a drift aborts, leaving the rest -1 (cube fallback, never a hole).
func _build_slope_manifest(library: Object, total: int) -> int:
	_slope_arid = PackedInt32Array()
	_slope_arid.resize(total * _SLOPE_STRIDE)
	_slope_arid.fill(-1)
	_snow_slope_arid = PackedInt32Array()
	_snow_slope_arid.resize(total * _SLOPE_STRIDE)
	_snow_slope_arid.fill(-1)
	var capset := {}
	for cm: int in TerrainConfig.snow_cappable_materials():
		capset[cm] = true
	var appended := 0
	for pair: int in TerrainConfig.emitted_slope_pairs():
		var mat := pair / _SLOPE_STRIDE
		var payload := pair % _SLOPE_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total:
			continue
		var modifier := CellCodec.MOD_FAM_BIT | (CellCodec.FAM_SLOPE << CellCodec.MOD_FAM_KIND_SHIFT) | payload
		var model: Object = _make_shape_model(modifier, BlockMaterials.get_for(mat))
		if model == null:
			continue                                     # no mesh-model class → cube fallback
		var expected := _next_arid
		var got: int = _add_model(library, model)
		if got != expected:
			push_warning("[module_world] slope manifest ARID drift: add_model %d != expected %d" % [got, expected])
			return appended
		_next_arid += 1
		_slope_arid[mat * _SLOPE_STRIDE + payload] = got
		appended += 1
		# Snow-capped twin (reuses the SAME per-payload ArrayMesh; only the material override differs).
		if capset.has(mat):
			var vmodel: Object = _make_shape_model(modifier, BlockMaterials.snow_capped_for(mat))
			if vmodel == null:
				continue
			var exp2 := _next_arid
			var got2: int = _add_model(library, vmodel)
			if got2 != exp2:
				push_warning("[module_world] slope-snow manifest ARID drift: add_model %d != expected %d" % [got2, exp2])
				return appended
			_next_arid += 1
			_snow_slope_arid[mat * _SLOPE_STRIDE + payload] = got2
			appended += 1
	return appended

## Allocate + zero-init (`-1`) a kind's twin table (`total * _GEN_STRIDE`) and publish it into
## `_gen_twin_arid[kind]`. Returns the fresh PackedInt32Array so the caller can fill it in place.
func _ensure_twin_table(kind: int, total: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(total * _GEN_STRIDE)
	arr.fill(-1)
	_gen_twin_arid[kind] = arr
	return arr

## Bake the liquid appearance into the per-kind `_gen_twin_arid` + `_surface_arid` tables,
## appending (but NOT baking — the caller does one batched bake) to `library`. Returns the total
## number of models appended across all kinds. Each append asserts `add_model()` returns the
## expected ARID (anti-drift); a drift aborts THAT kind, leaving the rest -1 (graceful dry-shape/
## cube fallback). Two flavours by `_waterlog_enabled`:
##   * NATIVE (WATERLOGGING §4 / MULTI-LIQUID §2.2.3): one waterlogged-twin manifest PER kind with a
##     registered fluid, each over the UNION of that kind's shore (level 9) and submerged (level 10)
##     emitted pairs, so every cell of a kind (pure, shore, submerged) shares one fluid_index. Open
##     surface cells reuse the kind's LRID pure fluid model (no slab appended).
##   * LEGACY (WATER-SHORE §4.2): WATER ONLY — a wet composite per shore pair + the ONE 0.9 slab;
##     other kinds stay null/-1 (they render as plain liquid cubes — degraded, never water-skinned).
## Called on the MAIN thread inside setup().
func _build_wet_manifest(library: Object, total: int) -> int:
	if _waterlog_enabled:
		var appended := 0
		for kind in range(1, _fluids.size()):
			if _fluids[kind] == null:
				continue
			appended += _build_waterlog_manifest(library, total, kind)
		return appended
	return _build_legacy_water_manifest(library, total)

## LEGACY water-only manifest (WATER-SHORE §4.2): a wet composite per emitted shore pair into
## `_gen_twin_arid[LIQ_WATER]`, plus the ONE 0.9 open-water slab into `_surface_arid[LIQ_WATER]`.
## Non-water kinds are left untouched (null/-1) so a legacy engine renders their surface + composites
## as plain liquid cubes/dry shapes — degraded, never a hole, and NEVER water-skinned (MULTI-LIQUID
## §2.2.4). Anti-drift as elsewhere; a drift aborts the water manifest (dry manifest stands).
func _build_legacy_water_manifest(library: Object, total: int) -> int:
	var twin := _ensure_twin_table(CellCodec.LIQ_WATER, total)
	var water_mat: Material = BlockMaterials.get_for(_water_id_of())
	var appended := 0
	for slot: int in TerrainConfig.emitted_shore_pairs(CellCodec.LIQ_WATER):
		var mat := slot / _GEN_STRIDE                    # decode: slot = mat*256 + modifier
		var modifier := slot % _GEN_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total or modifier <= 0 or modifier >= _GEN_STRIDE:
			continue
		if twin[slot] >= 0:
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
		twin[slot] = got
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
		_surface_arid[CellCodec.LIQ_WATER] = got
		appended += 1
	return appended

## Native-waterlogging manifest for ONE liquid `kind` (WATERLOGGING §4.3-4.5 / MULTI-LIQUID §2.2.3).
## Bakes ONE waterlogged twin per co-filled composite (surface material, modifier) pair — the DRY
## terrain ramp additionally carrying THIS KIND's shared fluid — over the UNION of the kind's shore
## (level 9) and submerged (level 10) emitted pairs, so every cell of the kind (pure, shore,
## submerged) shares one fluid_index and culls together (no border at the line OR below it). Open
## surface cells resolve to the kind's LRID pure fluid model (`_cube_arid[lrid]`), so NO slab is
## appended. Anti-drift as above; a drift aborts, leaving unbaked pairs -1 (dry-shape fallback: a
## border, never a hole). Twin count printed per kind. Called on the MAIN thread inside setup();
## appends but does not bake. Twins keep `culls_neighbors` default TRUE — their side patterns are
## their solid ramp (MULTI-LIQUID §2.3); only the PURE opaque fluid gets culls_neighbors false.
func _build_waterlog_manifest(library: Object, total: int, kind: int) -> int:
	var twin := _ensure_twin_table(kind, total)
	# Union the shore pairs and the submerged floor pairs FOR THIS KIND (dedup by slot). ONE twin per
	# shape serves both level 9 and level 10 (the engine fills to 0.9375 at the line, full when
	# covered), so a shared set is exactly right.
	var pairs := {}
	for slot: int in TerrainConfig.emitted_shore_pairs(kind):
		pairs[slot] = true
	for slot: int in TerrainConfig.emitted_submerged_pairs(kind):
		pairs[slot] = true
	var appended := 0
	for slot: int in pairs.keys():
		var mat := slot / _GEN_STRIDE                    # decode: slot = mat*256 + modifier
		var modifier := slot % _GEN_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total or modifier <= 0 or modifier >= _GEN_STRIDE:
			continue
		if twin[slot] >= 0:
			continue                                     # a duplicate pair (shore ∩ submerged)
		var model: Object = _make_waterlogged_model(modifier, BlockMaterials.get_for(mat), kind)
		if model == null:
			continue                                     # no mesh/waterlog API → dry-shape fallback
		var expected := _next_arid
		var got: int = _add_model(library, model)
		if got != expected:
			push_warning("[module_world] waterlog manifest ARID drift (kind %d): add_model %d != expected %d" % [kind, got, expected])
			return appended                              # abort this kind; dry manifest + other kinds stand
		_next_arid += 1
		twin[slot] = got
		appended += 1
	# Open surface cells (level 9, modifier 0) of this kind render as the kind's LRID pure fluid model.
	_surface_arid[kind] = _cube_arid_of(BlockCatalog.liquid_lrid_of(kind))
	print("[module_world] waterlog twins baked (kind %d): %d (of %d unique composite pairs; surface → fluid ARID %d)"
		% [kind, appended, pairs.size(), _surface_arid[kind]])
	return appended

## The snow-FILL composite ARID for (mat, modifier) at true fill `level` (tenths), rounding the level UP
## to the nearest baked {3,5,8,10}, or -1 when that composite pair was never baked (→ the §2.7 fallback
## ladder). Shared by arid_for_cell + gen_arid_for (the main-thread mirrors of the worker's fill branch).
func _comp_arid_of(mat: int, modifier: int, level: int) -> int:
	if modifier <= 0 or modifier >= _GEN_STRIDE:
		return -1
	var table := _comp_table_for(_comp_round_up(level))
	if table.is_empty():
		return -1
	var slot := mat * _GEN_STRIDE + modifier
	if slot < table.size() and table[slot] >= 0:
		return table[slot]
	return -1

## The nearest baked composite level ≥ `level` (render never lower than physics — §2.7 round-UP).
func _comp_round_up(level: int) -> int:
	if level <= 3:
		return 3
	if level <= 5:
		return 5
	if level <= 8:
		return 8
	return 10

## The frozen composite table for a rounded level {3,5,8,10}.
func _comp_table_for(rounded_level: int) -> PackedInt32Array:
	match rounded_level:
		3: return _comp_arid_l3
		5: return _comp_arid_l5
		8: return _comp_arid_l8
		_: return _comp_arid_l10

## Forward (mat, modifier) → ARID exactly as the voxel worker resolves it: AIR → 0, a
## full cube → its eager cube ARID, a shaped value → the frozen manifest ARID (cube
## fallback when that slot was never baked). Main-thread mirror of the generator's inline
## resolve — verify asserts the generated TYPE buffer equals this over a sample grid.
func gen_arid_for(mat: int, modifier: int, liquid_level := 0, liquid_kind := CellCodec.LIQ_WATER, state := 0) -> int:
	if mat == BlockCatalog.AIR:
		return 0
	# Level-9 (the liquid line) resolves through the KIND's frozen tables, exactly as the worker does.
	# Level-10 (submerged): NATIVE waterlogging routes it to the SAME twin table (WATERLOGGING §4.5)
	# so submerged liquid culls seamlessly; the LEGACY path leaves it to the dry resolve. Level-0
	# always falls to the dry resolve. `liquid_kind` defaults to water so pre-liquid 3-arg callers are
	# unchanged; verify passes LIQ_LAVA to mirror a lava cell.
	if liquid_level == CellCodec.LIQ_LEVEL_SURFACE:
		if modifier == 0:
			if liquid_kind < _surface_arid.size() and _surface_arid[liquid_kind] >= 0:
				return _surface_arid[liquid_kind]
			return _cube_arid_of(mat)
		var twin = _gen_twin_arid[liquid_kind] if liquid_kind < _gen_twin_arid.size() else null
		if twin != null:
			var wslot := mat * _GEN_STRIDE + modifier
			if modifier < _GEN_STRIDE and wslot < twin.size() and twin[wslot] >= 0:
				return twin[wslot]
		# unbaked wet pair → dry shape (fall through)
	elif _waterlog_enabled and liquid_level == CellCodec.LIQ_LEVEL_FULL and modifier != 0:
		var twin = _gen_twin_arid[liquid_kind] if liquid_kind < _gen_twin_arid.size() else null
		if twin != null:
			var wslot := mat * _GEN_STRIDE + modifier
			if modifier < _GEN_STRIDE and wslot < twin.size() and twin[wslot] >= 0:
				return twin[wslot]
		# unbaked submerged twin → dry shape (fall through)
	# Snow-FILL composite mirror (SNOW-ACCUMULATION §2.6): a filled ramp resolves to its curated composite
	# ARID (rounding the level UP), exactly as arid_for_cell / the worker do — checked BEFORE the snow-cap
	# skin (a filled cell is always also capped). `state` carries the fill nibble (bits 1..4).
	if liquid_level == 0:
		var gfill := (state >> CellCodec.STATE_SNOW_FILL_SHIFT) & 0xF
		if gfill != 0:
			var gca := _comp_arid_of(mat, modifier, gfill)
			if gca >= 0:
				return gca
	# SHARP-SLOPE (§4.2) mirror: a generated SLOPE cell (FAM bit 15, land-only) → the dedicated slope
	# tables (snow twin when capped), exactly as arid_for_cell / the worker do.
	if liquid_level == 0 and CellCodec.is_slope(modifier):
		var pslot := mat * _SLOPE_STRIDE + (modifier & 0xFFF)
		if (state & CellCodec.STATE_SNOW_CAPPED) != 0 and pslot < _snow_slope_arid.size() and _snow_slope_arid[pslot] >= 0:
			return _snow_slope_arid[pslot]
		if pslot < _slope_arid.size() and _slope_arid[pslot] >= 0:
			return _slope_arid[pslot]
		return _cube_arid_of(mat)                        # unbaked payload → cube fallback (never a hole)
	# Snow-cap state variant mirror (M1 ADR §5.2): a capped cell (state bit set, no liquid) resolves
	# to its frozen snow-variant ARID, exactly as arid_for_cell / the worker do. `state` defaults 0 so
	# pre-M1 callers are unchanged; verify passes STATE_SNOW_CAPPED to mirror a capped cell.
	if liquid_level == 0 and (state & CellCodec.STATE_SNOW_CAPPED) != 0:
		var sslot := mat * _GEN_STRIDE + modifier
		if modifier < _GEN_STRIDE and sslot < _snow_arid.size() and _snow_arid[sslot] >= 0:
			return _snow_arid[sslot]
		# unbaked snow slot → plain look (fall through)
	# FAM LAYER mirror (SNOW-ACCUMULATION §1.5): a snow depth level resolves through the dedicated
	# level table exactly as the worker does; snow_block only, cube fallback for any other material /
	# unbaked level (a too-tall snow cube, never a hole).
	if CellCodec.is_layer(modifier):
		var lvl := CellCodec.layer_level(modifier)
		if mat == _snow_id_of() and lvl < _layer_arid.size() and _layer_arid[lvl] >= 0:
			return _layer_arid[lvl]
		return _cube_arid_of(mat)
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
	# FAM LAYER (SNOW-ACCUMULATION §1.5): baked iff snow_block AND its level table slot is set.
	if CellCodec.is_layer(modifier):
		var lvl := CellCodec.layer_level(modifier)
		return mat == _snow_id_of() and lvl >= 0 and lvl < _layer_arid.size() and _layer_arid[lvl] >= 0
	if CellCodec.is_slope(modifier):                      # SHARP-SLOPE: dedicated slope table (kind 1 only)
		var pslot := mat * _SLOPE_STRIDE + (modifier & 0xFFF)
		return pslot < _slope_arid.size() and _slope_arid[pslot] >= 0
	var slot := mat * _GEN_STRIDE + modifier
	return modifier < _GEN_STRIDE and slot < _gen_arid.size() and _gen_arid[slot] >= 0

## The runtime generator instance (verify's both-path ARID round-trip drives it
## directly). Null until setup() succeeds.
func get_generator() -> Object:
	return _generator

## COSMOS frozen-epoch home-face flip (COSMOS-AUDIT §3.2 item 4, F3). Install a NEW generator epoch
## homed on `face` and hard-restream. NEVER mutates the live generator's gen_face (workers read it):
## the old generator is discarded, any in-flight worker task holding it finishes harmlessly and its
## block is dropped by the restream. This is exactly the shape M4's dual-window handoff needs (two
## generators, two frozen faces, concurrently). WorldManager also repositions this node so the new
## voxel coordinate frame maps to the new face's global indices.
func set_home_face(face: int) -> void:
	_gen_face = face
	restream()

## Drop the streamed near region and rebuild it with a FRESH generator snapshot (frozen on the current
## _gen_face). This is the module restream the home-face flip (and M4) needs — previously ONLY the
## GDScript fallback had one, so a module flip left stale face-A meshes standing (COSMOS-AUDIT F3).
## Recreating the VoxelTerrain node guarantees old-epoch blocks are gone and the new generator is used.
## The player's global VoxelViewer keeps streaming the new terrain (viewers are engine-global). A no-op
## if the module is unavailable.
func restream() -> void:
	if not ClassDB.class_exists("VoxelTerrain") or _mesher == null:
		return
	var generator: Object = _make_generator()
	if generator == null:
		return
	var old_terrain := _terrain
	var new_terrain := ClassDB.instantiate("VoxelTerrain") as Node3D
	if new_terrain == null:
		return
	_set_if(new_terrain, "mesher", _mesher)
	_set_if(new_terrain, "generator", generator)
	_set_if(new_terrain, "max_view_distance", TerrainConfig.RENDER_RADIUS_BLOCKS)
	_set_if(new_terrain, "mesh_block_size", 32)
	_set_if(new_terrain, "generate_collisions", false)
	if old_terrain != null:
		new_terrain.position = old_terrain.position   # preserve the module's coordinate offset
		remove_child(old_terrain)
		old_terrain.queue_free()
	add_child(new_terrain)
	_terrain = new_terrain
	_generator = generator

## Whether the OOB fence has clamped a stale/unbaked ARID this session (COSMOS-AUDIT F8 telemetry — a
## real out-of-range must never pass silently). Verify asserts this stays false over a clean run.
func oob_seen() -> bool:
	return _generator != null and bool(_generator.get("oob_seen"))

## The generator's frozen home face (COSMOS-AUDIT §3.2 item 3) — for verify / the dual-window handoff.
func gen_home_face() -> int:
	return _gen_face

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

## Build ONE VoxelBlockyFluid per declared liquid kind (MULTI-LIQUID §2.2.1), ASCENDING so
## registration order — hence the engine's fluid_index — is deterministic. Each kind's fluid is
## referenced by that kind's pure fluid model AND its waterlogged twins, so all cells of the kind
## land in one fluid_index / material bucket (borderless within the kind, crisp against others).
func _build_fluids() -> void:
	for kind in range(1, _fluids.size()):
		var lrid := BlockCatalog.liquid_lrid_of(kind)
		if lrid <= 0:
			continue
		_fluids[kind] = _make_fluid(lrid)

## One VoxelBlockyFluid for liquid LRID `lrid` (WATERLOGGING §4.1 / MULTI-LIQUID §2.2.1): the
## liquid's material + no downhill dip (a single registered level renders every cell flat at
## TOP_HEIGHT). BlockMaterials.get_for already builds the glow for an emissive liquid (lava), so
## the same path yields translucent water and emissive-opaque lava. Returns null if the class is
## unavailable (setup() then disables waterlogging when NO fluid at all could be built).
func _make_fluid(lrid: int) -> Object:
	var fluid: Object = ClassDB.instantiate("VoxelBlockyFluid")
	if fluid == null:
		return null
	if fluid.has_method("set_material"):
		fluid.call("set_material", BlockMaterials.get_for(lrid))
	if fluid.has_method("set_dip_when_flowing_down"):
		fluid.call("set_dip_when_flowing_down", false)
	return fluid

## The PURE-FLUID model for liquid `block_id` of `kind` (WATERLOGGING §4.2 / MULTI-LIQUID §2.2.2):
## a VoxelBlockyModelFluid at level 1 (= max, surface at the engine TOP_HEIGHT 0.9375) carrying the
## kind's shared fluid. Its material comes from the fluid; transparency_index == the block's cull
## group (water 1, lava 0), matching the legacy cube. Replaces the liquid LRID's cube in
## _configure_library, keeping the index==LRID invariant. Deep liquid columns cull to nothing inside
## the body (ocean fast path). Returns null if the class is unavailable.
##
## SLIVER FIX (MULTI-LIQUID §2.3): an OPAQUE fluid (cull_group 0 — lava) at transparency_index 0
## would be mutually culled with adjacent opaque solids (full-vs-full at equal index), opening a
## see-through band 0.9375..1.0 at every steep pool wall. Disabling neighbour culling on the PURE
## fluid model closes it (solids draw their face toward the fluid — hidden overdraw below the
## surface, same cost class as solids under water). The same-fluid_index short-circuit fires BEFORE
## this test, so borderless fluid↔fluid is preserved; and a translucent fluid (water, index 1) does
## NOT need it (solids already draw against a higher index). Data-driven: any future opaque liquid
## gets it automatically. Twins are unaffected (their solid ramp keeps culling normally).
func _make_fluid_model(block_id: int, kind: int) -> Object:
	var fluid: Object = _fluids[kind]
	if fluid == null or not ClassDB.class_exists("VoxelBlockyModelFluid"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelFluid")
	if model == null:
		return null
	if model.has_method("set_fluid"):
		model.call("set_fluid", fluid)
	if model.has_method("set_level"):
		model.call("set_level", 1)
	var cull_group: int = BlockCatalog.cull_group_of(block_id)
	if cull_group > 0 and model.has_method("set_transparency_index"):
		model.call("set_transparency_index", cull_group)
	if cull_group == 0 and model.has_method("set_culls_neighbors"):
		model.call("set_culls_neighbors", false)         # opaque-fluid sliver fix (§2.3)
	return model

## Build a WATERLOGGED TWIN of liquid `kind` (WATERLOGGING §4.3 / MULTI-LIQUID §2.2.3): a
## VoxelBlockyModelMesh of the DRY terrain ramp (reusing the SAME `_shape_mesh_cache[modifier]`
## ArrayMesh the dry shape uses — the solid IS the dry ramp, shared across kinds, no liquid geometry
## baked in) that ADDITIONALLY carries the kind's shared fluid via the native waterlog properties.
## The SOLID stays opaque (transparency_index 0 — load-bearing: neighbours judge this cell by its
## solid ramp, never its liquid, so no terrain holes) while its FLUID faces use the LIQUID's cull
## group (water 1, lava 0), so they cull seamlessly against every other cell of the kind (pure,
## shore, submerged) sharing the fluid — the border-killer. Twins keep `culls_neighbors` default
## TRUE (their side patterns are their solid ramp; only the pure opaque fluid gets it false — §2.3).
## `set_waterlog_level(1)` = full fill (engine drops it to 0.9375 uncovered, forces 1.0 covered).
## Returns null when the mesh-model class or the waterlog API is unavailable (→ dry-shape fallback,
## a border not a hole).
func _make_waterlogged_model(modifier: int, terrain_material: Material, kind: int) -> Object:
	var fluid: Object = _fluids[kind]
	if fluid == null or not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null or not model.has_method("set_waterlog_fluid"):
		return null
	# Reuse the DRY shape mesh (plain `modifier` key), shared with _make_shape_model (and across kinds).
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
	# never the liquid (no terrain holes, WATERLOGGING §5 risk 2). Set explicitly, not by default.
	if model.has_method("set_transparency_index"):
		model.call("set_transparency_index", 0)
	var fluid_cull_group: int = BlockCatalog.cull_group_of(BlockCatalog.liquid_lrid_of(kind))
	model.call("set_waterlog_fluid", fluid)
	if model.has_method("set_waterlog_level"):
		model.call("set_waterlog_level", 1)
	if model.has_method("set_waterlog_fluid_transparency_index"):
		model.call("set_waterlog_fluid_transparency_index", fluid_cull_group)
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
	for block_id in range(1, total):
		var cull_group: int = BlockCatalog.cull_group_of(block_id)
		var got: int
		var lk := BlockCatalog.liquid_kind_of(block_id)
		if _waterlog_enabled and lk != CellCodec.LIQ_NONE and _fluids[lk] != null:
			# A liquid LRID renders as a PURE FLUID model (WATERLOGGING §4.2 / MULTI-LIQUID §2.2.2),
			# not a cube — so deep liquid culls internally and every cell of that kind shares its one
			# fluid_index. Falls back to a cube if the fluid model can't be built, preserving the
			# index==LRID invariant either way.
			var fluid_model: Object = _make_fluid_model(block_id, lk)
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
var gen_twin_arid: Array                # kind -> PackedInt32Array (mat*GEN_STRIDE+mod -> twin ARID); null = no such liquid
var surface_arid: PackedInt32Array      # kind -> liquid-surface cell model ARID; -1 = not baked
var snow_arid: PackedInt32Array         # (mat*GEN_STRIDE + modifier) -> snow-cap variant ARID; -1 = not baked (M1)
var layer_arid: PackedInt32Array        # level -> snow_block LAYER ARID; -1 = not baked (SNOW-ACCUMULATION §1.5)
var comp_l3: PackedInt32Array           # (mat*GEN_STRIDE+mod) -> snow-fill composite ARID at level 3 (SNOW-ACCUMULATION §2.6)
var comp_l5: PackedInt32Array
var comp_l8: PackedInt32Array
var comp_l10: PackedInt32Array
var snow_id := -1                        # snow_block LRID (the curated LAYER material)
var slope_arid: PackedInt32Array        # (mat*SLOPE_STRIDE + payload) -> SHARP-SLOPE ARID; -1 = not baked
var snow_slope_arid: PackedInt32Array   # (mat*SLOPE_STRIDE + payload) -> snow-capped slope ARID; -1 = not baked
var waterlog := false                   # native waterlogging on → submerged composites route to twins
var model_count := 0                     # actual baked library model count — the OOB fence upper bound (VDS §8.1)
# COSMOS frozen-epoch (COSMOS-AUDIT §3.2 items 2–3): the IMMUTABLE home face + face-edge cell count this
# generator epoch is homed on, set once by the loader before this generator runs. The worker folds each
# column with `gen_face` (NEVER the mutable TerrainConfig._active_face), so home-face flips can never
# race generation — a flip installs a NEW generator with a new gen_face and restreams (module_world).
var gen_face := 0
var gen_n := 0
var flat_world := true                   # CubeSphere.FLAT_WORLD snapshot: flat → no fold (byte-identical)
# OOB-fence telemetry (COSMOS-AUDIT §3.2 item 6, F8): a benign write-once flag so a clamped/stale ARID
# is never SILENT. Set true the first time the fence fires; surfaced via module_world.oob_seen(). The
# write is idempotent (only ever false→true) so it is race-safe even though workers share this instance.
var oob_seen := false
const GEN_STRIDE := 256
const SLOPE_STRIDE := 4096
const FAM_BIT := 1 << 15                 # a modifier with bit 15 set is a FAM shape
const FAM_KIND_SHIFT := 12               # bits 14..12 select the FAM family kind
const FAM_KIND_MASK := 0x7
const FAM_SLOPE := 1                     # kind 1 = SLOPE; only kind 1 routes to the slope table (a future
                                        # kind-0 LAYER modifier must NOT be mis-indexed here)

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
	# max_above bounds the above-surface content the early-outs must not skip: the tallest tree AND the
	# deepest snow accumulation (SNOW-ACCUMULATION §3.2 raises it by SNOW_FILL_MAX_CELLS). Trees dominate
	# today, but taking the max keeps the all-air early-out sound if either bound ever changes.
	var max_above = max(TreeGen.MAX_ABOVE_SURFACE, TerrainConfig.SNOW_FILL_MAX_CELLS)
	var ncube = cube_arid.size()
	var mcount = model_count                 # actual baked library model count — the OOB fence (see write site)
	var ngen = gen_arid.size()
	var nsnow = snow_arid.size()
	var nlayer = layer_arid.size()
	var nslope = slope_arid.size()
	var nsnowslope = snow_slope_arid.size()
	# Hoist the per-kind twin tables into block-frame locals ONCE (MULTI-LIQUID §2.2.5): the worker
	# then selects among these locals per cell (a branch on the kind), never indexing the untyped
	# `gen_twin_arid` Array per cell — zero allocation. null = that kind has no registered fluid.
	var twin_w = gen_twin_arid[1]           # LIQ_WATER
	var twin_l = gen_twin_arid[2]           # LIQ_LAVA
	var twin_3 = gen_twin_arid[3]           # reserved third liquid

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
	# Per-block generation context (LOCAL to this _generate_block frame → each voxel worker owns its
	# own; NEVER shared across threads). FLAT: a plain Dictionary column memo (Vector2i → Vector4),
	# byte-identical to before. CURVED (COSMOS-AUDIT §3.2 items 2–3, F1/F2): a GenCtx carrying the
	# FROZEN gen_face — the worker folds every column to its TRUE global (face, i, j) with THIS
	# immutable face (never TerrainConfig._active_face) and hashes bedrock/ore/strata/tree/smoothing on
	# the true column, so a module-generated cell is byte-identical to the analytic generated_cell_global
	# (render == physics across a seam) and no home-face flip can race generation.
	var pcache
	var rxs   # per-column resolve i (true global column i) — curved only
	var rzs   # per-column resolve j
	var rfs   # per-column true face
	if flat_world:
		pcache = {}
		for z in range(size.z):
			for x in range(size.x):
				var p = TerrainConfig.column_profile(ox + x, oz + z, pcache)
				profs[z * size.x + x] = p
				if int(p.x) > max_h: max_h = int(p.x)
	else:
		pcache = TerrainConfig.GenCtx.new(gen_face)
		rxs = PackedInt32Array(); rxs.resize(size.x * size.z)
		rzs = PackedInt32Array(); rzs.resize(size.x * size.z)
		rfs = PackedInt32Array(); rfs.resize(size.x * size.z)
		for z in range(size.z):
			for x in range(size.x):
				var idx = z * size.x + x
				# Fold (gen_face, voxel column) → true global column ONCE; sets pcache.face to the true face.
				var tc = TerrainConfig.worker_fold_column(gen_face, ox + x, oz + z, pcache)
				rfs[idx] = tc.x; rxs[idx] = tc.y; rzs[idx] = tc.z
				var p = TerrainConfig.column_profile(tc.y, tc.z, pcache)
				profs[idx] = p
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
			var idx2 = z * size.x + x
			var p = profs[idx2]
			var g = int(p.x)
			var biome = int(p.y)
			var cc = p.z
			var tt = p.w
			var wx
			var wz
			if flat_world:
				wx = ox + x
				wz = oz + z
			else:
				# The TRUE global column this voxel column folds to; restore its face for the nested
				# smoothing/snow/tree stencil folds inside resolve_cell (COSMOS-AUDIT §3.2 items 2–3).
				wx = rxs[idx2]
				wz = rzs[idx2]
				pcache.face = rfs[idx2]
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
				# Liquid axis, PER KIND (MULTI-LIQUID §2.2.5). Read the kind + level from the liquid field.
				# Level-9 (the liquid line): the kind's frozen tables — the open surface model for
				# modifier 0 (native: the kind's pure fluid ARID; legacy water: the 0.9 slab), the twin
				# model for a composite (modifier != 0) — degrading to dry-shape then cube, never a hole.
				# Level-10 (submerged composite): NATIVE waterlogging routes it to the SAME twin table of
				# its kind (WATERLOGGING §4.5) so submerged liquid culls seamlessly (last underwater
				# border); LEGACY leaves it to the dry-shape resolve (a border). Field 0 (deep liquid /
				# sub-surface, incl. bare liquid ids whose cube ARID IS the pure fluid model): the
				# UNCHANGED cube/shape fast paths.
				var lf = CellCodec.liquid_field(v)
				if lf != 0:
					var lk = lf & 3                          # LIQ_KIND_MASK inline
					var lvl = lf >> 2                        # level in tenths
					var twins = twin_w                       # this kind's twin table (block-frame local)
					if lk == 2:
						twins = twin_l
					elif lk == 3:
						twins = twin_3
					if lvl == 9:
						if modifier == 0:
							var sa = surface_arid[lk] if lk < surface_arid.size() else -1
							arid = sa if sa >= 0 else (cube_arid[id] if id < ncube else id)
						else:
							var wslot = id * GEN_STRIDE + modifier
							if twins != null and modifier < GEN_STRIDE and wslot < twins.size() and twins[wslot] >= 0:
								arid = twins[wslot]
							elif modifier < GEN_STRIDE and wslot < ngen and gen_arid[wslot] >= 0:
								arid = gen_arid[wslot]
							else:
								arid = cube_arid[id] if id < ncube else id
					elif waterlog and lvl == 10 and modifier != 0:
						var wslot = id * GEN_STRIDE + modifier
						if twins != null and modifier < GEN_STRIDE and wslot < twins.size() and twins[wslot] >= 0:
							arid = twins[wslot]
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
				elif ((v >> 33) & 0xF) != 0:
					# Snow-FILL composite (SNOW-ACCUMULATION 2.6): a terrain ramp buried/filled by the snow
					# plane. The fill nibble (STATE bits 1..4 = value bits 33..36) rounds UP to a curated
					# level {3,5,8,10}; checked BEFORE snow_capped/slope (a filled cell is always also capped).
					# Ladder: composite -> snow-cap skin -> dry ramp -> cube (never a hole -- 2.7).
					var flvl = (v >> 33) & 0xF
					var ctab = comp_l3
					if flvl > 8: ctab = comp_l10
					elif flvl > 5: ctab = comp_l8
					elif flvl > 3: ctab = comp_l5
					var cslot = id * GEN_STRIDE + modifier
					if modifier < GEN_STRIDE and cslot < ctab.size() and ctab[cslot] >= 0:
						arid = ctab[cslot]
					elif modifier < GEN_STRIDE and cslot < nsnow and snow_arid[cslot] >= 0:
						arid = snow_arid[cslot]            # ladder: the M1 snow-cap skin
					elif modifier < GEN_STRIDE and cslot < ngen and gen_arid[cslot] >= 0:
						arid = gen_arid[cslot]             # ladder: the dry ramp
					else:
						arid = cube_arid[id] if id < ncube else id
				elif (modifier & FAM_BIT) != 0 and ((modifier >> FAM_KIND_SHIFT) & FAM_KIND_MASK) == FAM_SLOPE:
					# SHARP-SLOPE (4.2): a generated SLOPE cell (FAM bit 15 + kind 1, land-only) -> the dedicated
					# slope tables (snow-capped twin when capped, else dry slope); an unbaked payload cube-
					# falls-back (never a hole). BEFORE the generic snow-cap arm AND the FAM LAYER arm (a SLOPE
					# modifier also has bit 15) so a capped slope routes to the slope table, never the layer table.
					var pslot = id * SLOPE_STRIDE + (modifier & 0xFFF)
					if ((v >> 32) & 1) != 0 and pslot < nsnowslope and snow_slope_arid[pslot] >= 0:
						arid = snow_slope_arid[pslot]
					elif pslot < nslope and slope_arid[pslot] >= 0:
						arid = slope_arid[pslot]
					else:
						arid = cube_arid[id] if id < ncube else id
				elif ((v >> 32) & 1) != 0:
					# Snow-cap state variant (M1 ADR §5.2): a capped cell (state bit 0 set, no liquid) → its
					# frozen snow-variant ARID; an unbaked snow slot falls back to the plain cube/shape (a bare
					# cap, never a hole). One masked shift on the hot path; taken only for the rare stated cells.
					var sslot = id * GEN_STRIDE + modifier
					if modifier < GEN_STRIDE and sslot < nsnow and snow_arid[sslot] >= 0:
						arid = snow_arid[sslot]
					elif modifier == 0:
						arid = cube_arid[id] if id < ncube else id
					else:
						var gslot = id * GEN_STRIDE + modifier
						if modifier < GEN_STRIDE and gslot < ngen and gen_arid[gslot] >= 0:
							arid = gen_arid[gslot]
						else:
							arid = cube_arid[id] if id < ncube else id
				elif (modifier & 0x8000) != 0:
					# FAM LAYER (SNOW-ACCUMULATION 1.5): snow depth level (tenths) resolves through the
					# dedicated LEVEL table (a FAM modifier is >= 0x8000 and can't slot the 256-stride).
					# snow_block only; any other material or an unbaked level falls back to the snow cube
					# (too-tall, right substance, NEVER a hole -- the 1.5 safety default).
					var lvl = modifier & 0xF
					if id == snow_id and lvl < nlayer and layer_arid[lvl] >= 0:
						arid = layer_arid[lvl]
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
				# OOB FENCE (VDS 8.1 exhaustion policy) — runs for EVERY cell after the arid resolve: a
				# stray/unbaked payload degrades to a valid cube, NEVER an out-of-range model index. The
				# blocky mesher (C++/wasm) indexes its baked-model array by this value, so any arid outside
				# [0, model_count) is an out-of-bounds worker crash. Every branch above already cube-falls-
				# back; this only fires if a table held a stale index or a web bake truncated the library
				# below _next_arid, clamping to the material cube, else air (model 0 is always empty).
				if arid < 0 or arid >= mcount:
					var cf = cube_arid[id] if id < ncube else 0
					arid = cf if (cf >= 0 and cf < mcount) else 0
					if not oob_seen:
						oob_seen = true       # write-once telemetry (idempotent → race-safe); surfaced by verify
						push_warning("[module_world] OOB fence clamped a stale/unbaked ARID (mat=%d modifier=%d) to a cube" % [id, CellCodec.modifier(v)])
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
	gen.set("gen_twin_arid", _gen_twin_arid)             # kind -> waterlogged-twin / wet composites
	gen.set("surface_arid", _surface_arid)               # kind -> open-liquid surface model (slab or fluid)
	gen.set("snow_arid", _snow_arid)                     # M1 §5.2: (mat*STRIDE+mod) -> snow-cap variant ARID
	gen.set("layer_arid", _layer_arid)                   # SNOW-ACCUMULATION §1.5: level -> snow_block LAYER ARID
	gen.set("comp_l3", _comp_arid_l3)                    # SNOW-ACCUMULATION §2.6: snow-fill composite ARIDs
	gen.set("comp_l5", _comp_arid_l5)
	gen.set("comp_l8", _comp_arid_l8)
	gen.set("comp_l10", _comp_arid_l10)
	gen.set("snow_id", _snow_id_of())                    # the curated LAYER material (snow_block LRID)
	gen.set("slope_arid", _slope_arid)                   # SHARP-SLOPE §4.2: (mat*SLOPE_STRIDE+payload) -> ARID
	gen.set("snow_slope_arid", _snow_slope_arid)         # SHARP-SLOPE §4.2: snow-capped slope ARID
	gen.set("waterlog", _waterlog_enabled)               # WATERLOGGING §4.5: route submerged → twins
	# COSMOS frozen-epoch (COSMOS-AUDIT §3.2 items 2–3): freeze this epoch's home face + n + flat flag
	# onto the generator instance. The worker reads these IMMUTABLE snapshots (never _active_face), so a
	# home-face flip creates a fresh generator (new gen_face) + restream rather than mutating under workers.
	gen.set("flat_world", CubeSphere.FLAT_WORLD)
	gen.set("gen_face", _gen_face)
	gen.set("gen_n", CubeSphere.n_for(CubeSphere.HOME_BODY))
	# The OOB fence upper bound (VDS §8.1): the ACTUAL baked model count, read back from the library
	# (not _next_arid) so that if a web bake ever truncated the models array below what we appended, the
	# generator still never writes an index past what the mesher can address. Falls back to _next_arid
	# when the library doesn't expose its models array.
	gen.set("model_count", _library_model_count())
	return gen

## The actual number of models in the baked library (the arid upper bound for the worker's OOB fence).
## Reads the live `models` array size when exposed; else the append count `_next_arid`.
func _library_model_count() -> int:
	if _library != null:
		var models: Variant = _library.get("models")
		if models is Array:
			return (models as Array).size()
	return _next_arid

# --- helpers -------------------------------------------------------------------
# Set a property only if the object actually exposes it (avoids error spam if a
# module property name drifts between versions).
func _set_if(obj: Object, prop: String, value: Variant) -> void:
	for p in obj.get_property_list():
		if p.get("name", "") == prop:
			obj.set(prop, value)
			return
