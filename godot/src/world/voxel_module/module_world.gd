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
# COSMOS R1 DEV (DEV_HIDE_NEAR): when true, hide the near render by collapsing the module's own streaming
# radius to DEV_HIDDEN_VIEW_BLOCKS. Godot node visibility does NOT propagate to godot_voxel's RID mesh-block
# instances, so `.visible=false` on the wrapper leaves chunks drawn — but max_view_distance is the module's
# own lever, so shrinking it unloads the near field reliably (a tiny platform remains under the player). The
# ramp (_process) respects this flag so the handoff never re-grows it while hidden. Render-only; analytic
# physics/GroundCollider are untouched. Never set in normal play (only the dev toggle turns it on).
var _render_hidden := false
const DEV_HIDDEN_VIEW_BLOCKS := 8
# COSMOS frozen-epoch (docs/COSMOS-AUDIT.md §3.2 items 3–4): the cube face this generator epoch is
# homed on. Frozen onto each generator instance as `gen_face` at creation; a home-face flip creates a
# NEW generator (new face) and restreams, rather than mutating the face workers are reading.
var _gen_face := CubeSphere.HOME_FACE
# COSMOS-FRAME-ORIENTATION §5.1: the epoch's FROZEN window orientation M_win (row-major [a,b,c,d]). The
# worker recovers the raw home-face index p = gen_mwin·v from the terrain-local voxel index v (= M_win⁻¹·p)
# before folding, so the near render lands in the master-face orientation. Identity at spawn → byte-identical.
var _gen_mwin: Array = [1, 0, 0, 1]

# ============================ FP-M1c Planet Assembly (flag: CubeSphere.FP_M1_POOL) ============================
# docs/COSMOS-FP-M1-DESIGN.md §4. A PlanetRoot node holds one FacetSlot per live facet terrain: the ACTIVE facet
# (composite transform = T_active⁻¹·T_active = identity → axis-aligned + editable → physics/DDA/collider untouched)
# and ≤ POOL_MAX_NEIGHBOURS render-only rotated neighbours (composite = T_active⁻¹·T_nb = the dihedral turn — the
# SAME T_active⁻¹ convention the FacetFarRing uses, so the two live fields WELD at the shared ridge). Every slot
# terrain streams from the ONE global player VoxelViewer (attach_viewer) and is `bounds`-clamped to its own facet
# domain slab (§3.2 — no foreign block ever exists). A crossing = redesignate(): ONE PlanetRoot.transform write +
# a view-distance rebalance; NO teardown, NO restream, NO new generator. All of it dormant unless FP_M1_POOL.
var _planet_root: Node3D = null              # holds the FacetSlots; transform = T_active⁻¹ (rigid re-place on cross)
# COSMOS FP-FIXED-FRAME re-anchor (docs/COSMOS-FIXED-FRAME-DESIGN.md §3): the accumulated floating-origin integer shift.
# Under the fixed frame PlanetRoot pins @ (identity − _anchor_offset); a re-anchor (WorldManager) pushes shift_anchor()
# to slide every FacetSlot/LOD tile back toward the render origin. ZERO (byte-identical) with the flag off.
var _anchor_offset: Vector3 = Vector3.ZERO
var _pool: Dictionary = {}                   # fid -> FacetSlot dict {terrain, slot, mesher, generator, spawn_ms, view, editable}
var _pool_active := -1                        # the currently-active (editable, composite-identity) facet id
# A1 CROSSING INSTRUMENTATION (#114): the last redesignate()'s attribution metrics, populated ONLY inside
# redesignate() and drained by WorldManager.maybe_cross_facet (take_last_redesignate). Empty until a crossing
# occurs; redesignate runs on the crossing path only (FACETED+FP_M1_POOL), so this adds ZERO per-frame cost and
# is unreachable when the faceted flags are off (FLAT byte-identity preserved).
var _last_redesignate: Dictionary = {}
# COSMOS FP-M2b (docs/COSMOS-FP-M2-DESIGN.md §5): the LOD-mesh layer, a child of PlanetRoot @ identity that draws
# the near rings of non-active facets as blocky LOD meshes (+ ridge aprons) instead of far-ring quads. Owns ONE
# FacetLodBuilder (the M2a off-thread build primitive). null unless FP_M2_LOD (dead code → FP-M1c byte-identical).
var _lod_mesher = null
# COSMOS FP-M2c (§6.5.3 surface 3): the load-adaptive view-ramp pace ∈ [0,1] pushed by the StreamLoadController via
# set_stream_pace. Multiplies the per-frame GROW leg of every view ramp (single-terrain + pool), so RAMP_SECONDS is
# the MINIMUM leg duration, stretched (never compressed) under load; pace 0 fully HOLDS a grow. Shrinks (unloads) are
# never throttled. Default 1.0 → byte-identical to the shipped fixed ramp (M2c never calls it with <1; M2d does).
var _stream_pace := 1.0
var _voxel_engine: Object = null              # FP_INFLIGHT_GATE (P1): lazily-cached VoxelEngine singleton for the main-thread apply-queue read
var _load_ctrl = null                         # the StreamLoadController (stored; forwarded to _lod_mesher, §6.5)
var _imminent_fid := -1                       # CONTROLLER-FIX §P3c: the committed imminent-ridge fid — its pool ramp slot
                                              # is paced at maxf(_stream_pace, RELIEF_FLOOR) so a geometric-commit spawn
                                              # still streams when surface-3 pace is held at 0; forwarded to _lod_mesher
var _imminent_committed := false              # CROSSING-JERKINESS FIX: true once the imminent ridge_dist < POOL_D_COMMIT
                                              # (published by WorldManager) → its ramp uses CTRL_IMMINENT_COMMIT_PACE (full)
# §10 memory ledger anchors (per-terrain FP-R0 live measurement 18 MB @ view96 unclamped; clamp strictly reduces).
const POOL_NEIGHBOUR_MEM_BUDGET_MB := 20      # per neighbour, view 96, bounds-clamped
const POOL_ACTIVE_MEM_BUDGET_MB := 40         # active, view 128, bounds-clamped

# COSMOS Stage 4 — post-flip view-distance ramp (kills the seam-cross freeze without moving spawn).
# A home-face flip recreates the VoxelTerrain; jamming its max_view_distance to the full near radius in
# one step re-queues the ENTIRE near disk (~2.6k blocks) in a single process pass → the 2 web workers +
# the main-thread mesh-apply flood → the multi-second input-dead freeze. Instead the fresh terrain starts
# at RAMP_START_BLOCKS and grows to the target over RAMP_SECONDS, so the nearest ring meshes first and
# worker load ramps in instead of spiking (the far LOD, now frame-correct, covers the gap). The FINAL
# view is identical — this is pure load-shaping. Active only in the ~1-2s after a flip restream.
# FP-M1c (§5) GENERALIZES this same load-shaping to the neighbour POOL: each FacetSlot carries its own view ramp
# (view_f/view_target/ramp_from) so a spawned neighbour fills 48→96 over RAMP_SECONDS and a crossing's `to` fills
# 96→128 over RAMP_SECONDS — both spread across frames instead of a one-pass burst at the facet border. The pool
# ramp (_ramp_pool_step) advances at most ONE slot per frame; this single-terrain _ramp_* state stays for the
# flag-OFF (FP-S1) restream path only, which the pool never takes (redesignate replaces restream).
const RAMP_START_BLOCKS := 48.0
const RAMP_SECONDS := 1.5
var _ramp_active := false
var _ramp_view := 0.0
var _ramp_target := 0.0

# COSMOS M4 Stage 2 (§3.1/§4): the OPT-IN freeze-in-place near cover. At a home-face flip, instead of
# freeing the old VoxelTerrain immediately (the shipped default), pin it at its old WORLD position and
# freeze it (PROCESS_MODE_DISABLED) so its meshes bridge the seam crossing at full near-field fidelity
# while the fresh terrain ramps in behind it. DEFAULT OFF (§0 never-OOM): the const is the ONE-LINE
# production flip; `cover_enabled` mirrors it per-instance so verify can assert BOTH states headless while
# prod stays a const flip. Only enabled in production through the §9.3 A/B gate. The far bridge runs at
# every flip regardless, as the safety net behind the cover (§2.2).
const NEAR_COVER_ENABLED := false          # DEFAULT OFF — the single production flip (§3.1)
var cover_enabled := NEAR_COVER_ENABLED    # instance mirror: verify overrides it; prod never writes it
const NEAR_COVER_MAX_SECONDS := 10.0       # hard transient bound (≤ far COVER_MAX_SECONDS = 12)
## Retirement is_area_meshed half-extent: 96 blocks, NOT the full 128 disk — one laggard outer mesh block
## must not pin the cover to its timeout, and the 96→128 annulus sits behind the far layer's curved inner
## hole (INNER_HOLE_CURVED = 112) plus fog, so retiring there is invisible (§4).
const NEAR_COVER_MESHED_HALF := Vector3(96.0, 32.0, 96.0)
var _cover_terrain: Node3D = null          # the frozen old VoxelTerrain (flag ON only); null in the default
var _cover_age := 0.0                       # seconds the current cover has lived
var _cover_released := false                # WorldManager's handshake fired (re-mirror done) — safe to retire on meshed

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
# COSMOS-ATLAS Stage 1 (docs/COSMOS-ATLAS-DESIGN.md, flag CubeSphere.FP_ATLAS_MATERIAL): the shared OPAQUE atlas.
# Built ONCE at setup() (main thread) before _configure_library when the flag is on; null otherwise (and null =>
# every code path takes the shipped per-id-material branch, byte-identical). Holds the ONE shared opaque material +
# the per-(opaque block-id) → atlas-cell map that _add_cube routes onto instead of a per-id set_material_override.
# Loaded via load().new() (like the other path-activated components here) so a freshly-added file needs no global
# class-cache rescan to parse; block_atlas.gd still carries `class_name BlockAtlas` for the exported build.
var _atlas = null                       # BlockAtlas instance (untyped: avoids a class-cache parse dependency)
const _ATLAS_SCRIPT := "res://src/world/voxel_module/block_atlas.gd"
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
var _gen_script_cache: GDScript = null   # FP-S1(e): the generator SOURCE compiled once (the src literal is constant —
                                         # facet/lod/frame are per-instance properties), reused across restreams/crossings

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
# COSMOS FP-CARVE (docs/COSMOS-FACETED-CARVE.md, patch 0004): the seam junction bevel is now a MESHER-side
# per-facet clip (VoxelMesherBlocky.set_facet_carve), not a per-facet baked manifest. The worker/mirrors
# write a plain carve-SENTINEL cube per material; the compiled mesher clips it by the active facet's ridge
# planes. Two per-material tables (dry + snow-capped) into a CONTIGUOUS ARID range [_carve_base, +_carve_count)
# so the C++ mesher identifies sentinels by a cheap range test. A -1 slot / unpatched binary cube-falls-back
# (the full-cube lip — never a hole). Facet-INDEPENDENT (plain cubes), so a crossing only re-pushes the planes.
var _carve_arid: PackedInt32Array        # mat -> dry carve-sentinel cube ARID; -1 = not baked
var _carve_snow_arid: PackedInt32Array   # mat -> snow-capped carve-sentinel cube ARID; -1 = not baked
var _carve_base := 0                      # first carve-sentinel ARID (contiguous range start)
var _carve_count := 0                     # number of carve-sentinel ARIDs baked

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
# COSMOS-ATLAS Stage 2 (docs/COSMOS-ATLAS-DESIGN.md §2.4): when FP_ATLAS_MATERIAL routes a shaped OPAQUE family onto
# the shared atlas material, the per-surface UVs are affine-remapped into the material's atlas CELL, which makes them
# material-dependent — so the cross-material `_shape_mesh_cache[modifier]` sharing (geometry-only) can no longer serve
# them. These atlas-remapped meshes cache in a SEPARATE dict keyed by (cell, modifier[, surface-variant]) so the
# shipped `_shape_mesh_cache` (flag-off path + the water twins that reuse the dry ramp) keeps its exact semantics. The
# geometry is rebuilt+UV-offset per distinct cell (design §2.4 option A: ~+1–2 MB of tiny meshes, flag-ON only).
var _atlas_shape_mesh_cache: Dictionary = {}   # String key -> ArrayMesh (atlas-remapped; only populated under the flag)
# G-ATLAS-UV/-MAT gate capture (verify_atlas.gd). Off in production (zero overhead): the gate sets this true BEFORE
# setup() so the manifest bake records, per atlas-routed shaped ARID, the expected atlas cell(s) it was baked into —
# the authoritative source the gate replays (material_override(i) == atlas.material AND every surface-i UV ∈ cell i).
var capture_atlas_probes := false
var _atlas_probes: Array = []            # [{arid:int, cells:Array[Vector2i]}] — one per atlas-routed shaped model

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

	# COSMOS-ATLAS Stage 1: build the shared OPAQUE atlas (image + one material + per-id cell map) BEFORE the library
	# so _configure_library can route opaque cubes onto it. Flag OFF (or a build that placed nothing) ⇒ _atlas stays
	# null and every cube takes the shipped per-id-material path (byte-identical). Main-thread, once — never per frame.
	if CubeSphere.FP_ATLAS_MATERIAL:
		var atlas = load(_ATLAS_SCRIPT).new()
		if atlas.build():
			_atlas = atlas
		else:
			print("[module_world] FP_ATLAS_MATERIAL on but atlas placed no opaque cells — staying on per-id materials")

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
	# Near-field radius: full 256 flat, cheaper CURVED_RENDER_RADIUS_BLOCKS on the planet (curved
	# per-column worldgen is ~8× costlier, so the full radius overwhelms the 2 web threads — the far
	# LOD covers the rest). near_render_radius() returns 256 in flat mode (byte-identical).
	_set_if(_terrain, "max_view_distance",
		DEV_HIDDEN_VIEW_BLOCKS if _render_hidden else TerrainConfig.near_render_radius())
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
	# COSMOS FP-CARVE (patch 0004): push the active facet's ridge planes into the mesher's carve blob BEFORE
	# the terrain starts streaming, so the first meshed block already clips its seam junction sentinels.
	_push_facet_carve()
	# FP-M1c (§4.1): under the pool flag the active terrain lives in a FacetSlot under PlanetRoot (composite
	# identity — byte-identical world placement to the direct-child path, just reparented), bounds-clamped to
	# its own facet slab. Flag OFF ⇒ the shipped single-terrain scene graph (add_child at ZERO), untouched.
	if CubeSphere.FACETED and CubeSphere.FP_M1_POOL:
		_pool_init_active()
		# FP-M2b (§5): stand up the LOD-mesh layer under PlanetRoot. Dead unless FP_M2_LOD (setup returns false).
		_lod_setup()
	else:
		add_child(_terrain)
	# The initial load flooding the full disk is hidden by the ShaderPrewarm overlay hold, so only the
	# post-flip restream needs the ramp — keep _process idle until restream() turns it on (Stage 4).
	set_process(false)
	return true

## COSMOS Stage 4 — drive the post-flip view-distance ramp. Grows the fresh terrain's max_view_distance
## from RAMP_START_BLOCKS to the near radius over RAMP_SECONDS so the near field streams in smoothly
## after a home-face flip instead of freezing on a single full-disk request pass. Self-disables when the
## target is reached; dormant (processing off) at every other time.
func _process(delta: float) -> void:
	# Ramp step (unchanged): grow the fresh terrain's view distance from RAMP_START_BLOCKS to the target.
	# DEV_HIDE_NEAR: while the near render is hidden, never re-grow the view distance (keep it collapsed).
	if _ramp_active:
		var span := maxf(_ramp_target - RAMP_START_BLOCKS, 1.0)
		_ramp_view = minf(_ramp_view + span * delta * _stream_pace / RAMP_SECONDS, _ramp_target)
		if _terrain != null and not _render_hidden:
			_set_if(_terrain, "max_view_distance", int(round(_ramp_view)))
		if _ramp_view >= _ramp_target:
			_ramp_active = false
	# COSMOS M4 Stage 2 (§5.1): age + retire the frozen near cover. Retire on "meshed" once WorldManager has
	# released it (edits re-mirrored) AND the fresh field has meshed under the player; else at the hard cap.
	if _cover_terrain != null:
		_cover_age += delta
		if _cover_released and not _ramp_active and _new_field_meshed():
			_free_cover("meshed")
		elif _cover_age >= NEAR_COVER_MAX_SECONDS:
			_free_cover("timeout")
	# FP-M1c per-slot pool view ramp (§5). Independent of the single-terrain _ramp_active (which the pool crossing
	# never uses — redesignate replaces restream). Bounded to ONE growing slot per frame (see _ramp_pool_step), so
	# several slots ramping at once can never collectively burst the workers + main-thread mesh-apply.
	var pool_ramping := false
	if CubeSphere.FACETED and CubeSphere.FP_M1_POOL and not _render_hidden and not _pool.is_empty():
		pool_ramping = _ramp_pool_step(delta)
	# FP-M2b: drain + apply finished LOD meshes/aprons under the mesher's own per-frame budget (off the voxel pool).
	if _lod_mesher != null:
		_lod_mesher.tick()
	# Stay processing only while there is still ramp / cover / pool-ramp / LOD work to do; otherwise go dormant.
	set_process(_ramp_active or _cover_terrain != null or pool_ramping or _lod_mesher != null)

## FP-M1c: (re)enable per-frame processing so the per-slot pool view ramp advances. Safe to call repeatedly; a no-op
## when the pool flag is off or the near render is dev-hidden (the ramp must never re-grow a deliberately hidden field).
func _pool_ramp_kick() -> void:
	if CubeSphere.FACETED and CubeSphere.FP_M1_POOL and not _render_hidden:
		set_process(true)

## FP-M1c per-slot view-distance ramp step (§5 — the border-hitch fix). Grows AT MOST ONE slot's max_view_distance
## per frame — the ACTIVE facet first (so a crossing's `to` reaches full stream ASAP), else the OLDEST neighbour (so
## it finishes and frees the single grow channel before the next starts). Serializing the grows bounds the total
## newly-requested view volume per frame to a single slot's RAMP_SECONDS-paced step, so N slots ramping concurrently
## can never collectively flood the 2 web workers + the main-thread mesh-apply. Shrinks (view_f > target) only UNLOAD,
## so every shrinking slot snaps immediately the same frame. Returns true while any slot still has growing to do.
func _ramp_pool_step(delta: float) -> bool:
	# FP_LANDING_STREAM_KICK: after a de-orbit LAND the active facet is the RESIDENT pool slot with no imminent
	# successor (no crossing is pending), so the grow leg below runs at the raw _stream_pace — which the load
	# controller pins at 0 whenever its backlog/apply gate is held closed (a far-ring/shell rebuild churning
	# in-flight work). The active near field then never grows and issues zero load requests. Repair a collapsed
	# view_target (a churned crossing may have left the active slot below the full near radius) so the pace floor
	# below has a real goal to reach. NEVER-OOM: target is capped at near_render_radius (the existing active cap).
	if CubeSphere.FP_LANDING_STREAM_KICK and _pool_active >= 0 and _pool.has(_pool_active) \
			and (_imminent_fid < 0 or _imminent_fid == _pool_active):
		var a: Dictionary = _pool[_pool_active]
		var full := float(TerrainConfig.near_render_radius())
		if float(a["view_target"]) < full - 0.5 and float(a["view_f"]) < full - 0.5:
			a["ramp_from"] = float(a["view_f"])
			a["view_target"] = full
	var up_fid := -1
	var up_spawn := 0
	var up_active := false
	for fid in _pool:
		var s: Dictionary = _pool[fid]
		var cur: float = s["view_f"]
		var tgt: float = s["view_target"]
		if cur > tgt + 0.5:
			# Shrink = pure unload → snap now (cheap), for every shrinking slot the same frame.
			s["view_f"] = tgt
			s["view"] = int(round(tgt))
			_set_if(s["terrain"], "max_view_distance", int(s["view"]))
		elif cur < tgt - 0.5:
			# Grow candidate — pick ONE: active wins; else the oldest (smallest spawn_ms).
			var is_active := (int(fid) == _pool_active)
			if up_fid < 0 or (is_active and not up_active) \
					or (is_active == up_active and int(s["spawn_ms"]) < up_spawn):
				up_fid = int(fid)
				up_spawn = int(s["spawn_ms"])
				up_active = is_active
	if up_fid < 0:
		return false
	# Advance ONLY the chosen slot this frame (RAMP_SECONDS to traverse ramp_from → view_target).
	var sc: Dictionary = _pool[up_fid]
	var span := maxf(float(sc["view_target"]) - float(sc["ramp_from"]), 1.0)
	# FP-M2c surface 3: the GROW leg is paced by the load controller (RAMP_SECONDS = the min duration, stretched under
	# load; pace 0 holds the grow). Default pace 1.0 → the shipped ramp math verbatim. Shrinks above snapped separately.
	# CONTROLLER-FIX §P3c: the committed imminent slot must keep streaming even when surface-3 pace is held at 0 (else a
	# geometric-commit spawn sits at RAMP_START_BLOCKS forever) — floor ONLY that slot at RELIEF_FLOOR (worst-case ramp
	# RAMP_SECONDS/0.25 = 6 s, inside the commit lead time); every other slot keeps the fully-gated pace for optional volume.
	var pace := _stream_pace
	if up_fid == _imminent_fid:
		# CROSSING-JERKINESS FIX: the COMMITTED imminent (ridge < POOL_D_COMMIT) ramps at the full commit pace so the
		# crossing target finishes filling DURING the approach instead of bursting at the seam; an uncommitted imminent
		# keeps the shipped RELIEF_FLOOR trickle. Memory-neutral (same view_target); only the fill RATE changes.
		pace = maxf(pace, CubeSphere.CTRL_IMMINENT_COMMIT_PACE if _imminent_committed else CubeSphere.CTRL_RELIEF_FLOOR)
	# FP_INFLIGHT_GATE (P1) feed-forward: cut the ramp pace by the main-thread apply-queue depth so admission never
	# outruns the apply/upload stage (the post-port choke). Applied AFTER the imminent floor so the committed imminent
	# slot keeps its priority ORDER but is still throttled by the apply queue (its old exemption assumed gen was the
	# choke). Off ⇒ pace is untouched — the shipped ramp math verbatim, byte-identical.
	if CubeSphere.FP_INFLIGHT_GATE:
		pace *= clampf(1.0 - float(_inflight_main_q()) / float(CubeSphere.APPLY_CHOKE), 0.0, 1.0)
	# FP_LANDING_STREAM_KICK: floor the RESIDENT active slot's grow pace (no imminent successor) at CTRL_RELIEF_FLOOR —
	# AFTER the FP_INFLIGHT_GATE cut, so a load gate held at 0 (backlog/apply/shell thrash) can never freeze the near
	# field. The committed-imminent slot keeps its own floor above; this closes the ONLY remaining unfloored grow path
	# (the settled/landed active). Bounded: RAMP_SECONDS/0.25 ≈ 6 s to fill, view_target already capped (NEVER-OOM).
	if CubeSphere.FP_LANDING_STREAM_KICK and up_fid == _pool_active \
			and (_imminent_fid < 0 or _imminent_fid == _pool_active):
		pace = maxf(pace, CubeSphere.CTRL_RELIEF_FLOOR)
	sc["view_f"] = minf(float(sc["view_f"]) + span * delta * pace / RAMP_SECONDS, float(sc["view_target"]))
	sc["view"] = int(round(float(sc["view_f"])))
	_set_if(sc["terrain"], "max_view_distance", int(sc["view"]))
	return true

## FP_INFLIGHT_GATE (P1): the current main-thread apply/free queue depth (VoxelEngine tasks.main_thread) for the
## feed-forward ramp pace cut. Lazy cached-singleton lookup; returns 0 when the engine/stat is unavailable (⇒ no
## throttle). Called only from _ramp_pool_step under the flag, i.e. only while a slot is actively growing — at most
## once per frame, so the extra get_stats() is negligible and never runs with the flag off.
func _inflight_main_q() -> int:
	if _voxel_engine == null:
		if Engine.has_singleton("VoxelEngine"):
			_voxel_engine = Engine.get_singleton("VoxelEngine")
		else:
			return 0
	if not _voxel_engine.has_method("get_stats"):
		return 0
	var st: Dictionary = _voxel_engine.call("get_stats")
	return int((st.get("tasks", {}) as Dictionary).get("main_thread", 0))

## COSMOS R1 DEV (DEV_HIDE_NEAR): hide/show the near render by collapsing the module's streaming radius.
## Node visibility can't hide godot_voxel's RID mesh blocks, so we shrink max_view_distance instead — the
## module unloads the near field, leaving only a tiny platform under the player so the baked far layer can
## be assessed without the near overlap. Render-only; analytic physics is untouched.
func set_render_hidden(hidden: bool) -> void:
	_render_hidden = hidden
	if _terrain != null:
		_set_if(_terrain, "max_view_distance",
			DEV_HIDDEN_VIEW_BLOCKS if hidden else TerrainConfig.near_render_radius())

## COSMOS R2.2: install/clear the frozen-per-epoch near-field true-geometry bake on the mesher (the C++
## VoxelMesherBlocky.set_cosmos_bake). `flat_params` is CosmosTruePlace.pack_bake_params_flat, or an empty
## Dictionary / {enabled:false} to restore the plain flat mesher. No-op if the module lacks the method (an
## engine built without patch 0003) — so the game still runs (near renders flat-window) on an old binary.
func set_cosmos_bake(flat_params: Dictionary) -> void:
	if _mesher != null and _mesher.has_method("set_cosmos_bake"):
		_mesher.call("set_cosmos_bake", flat_params)

# COSMOS R2.2 NOTE: an earlier design rotated the VoxelTerrain by the per-frame F to render the static baked
# near field around the window-space camera. That is NOT viable — godot_voxel inverts a singular basis when
# its transform is rotated (Basis.invert det==0 spam every streaming query). The shipped design (Design Z)
# instead leaves the terrain unrotated (blocks render at their baked epoch coords via identity placement)
# and moves the CAMERA into the epoch frame (see WorldManager.m5_epoch_camera + Player.set_render_camera).

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
	# COSMOS FP-CARVE (patch 0004): a seam junction cell (produced by junction_modify) → its carve-SENTINEL
	# cube (the mesher clips it); the snow-capped variant when capped. FIRST lf==0 arm — junction_modify
	# discards the original modifier, so snow-fill/slope/snow-cap never apply. Unbaked → cube (via arid_for).
	# Keeps this main-thread mirror in lockstep with the worker + gen_arid_for (the equality discipline, B5).
	if lf == 0 and CellCodec.is_junction(CellCodec.modifier(packed)):
		var jmat := CellCodec.mat(packed)
		if CellCodec.has_state(packed, CellCodec.STATE_SNOW_CAPPED) and jmat < _carve_snow_arid.size() and _carve_snow_arid[jmat] >= 0:
			return _carve_snow_arid[jmat]
		if jmat < _carve_arid.size() and _carve_arid[jmat] >= 0:
			return _carve_arid[jmat]
		# else fall through to arid_for → cube lip (never a hole)
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
	# Stage 2: a runtime-placed opaque shape rides the shared atlas cell too (else it would emit its own
	# residual surface). _shape_cell → (-1,-1) for the atlas-off path or a non-opaque material → per-id fallback.
	var model: Object = _make_shape_model(modifier, BlockMaterials.get_for(mat), _shape_cell(mat))
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

## COSMOS-ATLAS gate accessors (verify_atlas.gd). `atlas()` is the built BlockAtlas (null when FP_ATLAS_MATERIAL is
## off / the atlas placed nothing). `library_model(arid)` returns the baked VoxelBlockyModel at a library index, so
## the gate can read back a cube's `get_material_override(0)` / `get_tile(side)` / `get_atlas_size_in_tiles()` and
## assert the opaque cubes actually share the one atlas material + point at the right cell. `cube_arid_of(id)` maps a
## bootstrap block id to its library model index (== id for the bootstrap set).
func atlas():
	return _atlas

func library_model(arid: int) -> Object:
	if _library == null:
		return null
	var models: Variant = _library.get("models")
	if models is Array and arid >= 0 and arid < (models as Array).size():
		return (models as Array)[arid]
	return null

func cube_arid_of(id: int) -> int:
	if id >= 0 and id < _cube_arid.size():
		return _cube_arid[id]
	return -1

## COSMOS-ATLAS Stage 2 — null-safe atlas-cell lookups the shaped-family builders use. `_shape_cell` is the OPAQUE cube
## cell for surface material `mat` (dry shapes, snow LAYER, slopes ride their material's cube cell); `_snowcap_cell` is
## the snow-CAP variant cell (snow variants, composites, slope twins). Both return Vector2i(-1,-1) when the atlas is off
## / the id has no cell, so the caller falls back to the shipped per-material path (byte-identical). Static-safe: never
## dereference a null `_atlas`.
func _shape_cell(mat: int) -> Vector2i:
	return _atlas.cell_of(mat) if _atlas != null else Vector2i(-1, -1)

func _snowcap_cell(mat: int) -> Vector2i:
	return _atlas.snow_cap_cell_of(mat) if _atlas != null else Vector2i(-1, -1)

## An ArrayMesh with ONE surface = ShapeMesh.build(modifier) UV-remapped into atlas `cell` (design §2.4). Cached per
## (cell, modifier) so a re-emitted (mat,modifier) at the same cell reuses it. Only called under the flag with a valid
## cell.
func _atlas_shape_mesh(modifier: int, cell: Vector2i) -> ArrayMesh:
	var key := "s:%d:%d:%d" % [modifier, cell.x, cell.y]
	var amesh: ArrayMesh = _atlas_shape_mesh_cache.get(key, null)
	if amesh == null:
		amesh = ArrayMesh.new()
		_add_surface(amesh, _atlas_remap_geom(ShapeMesh.build(modifier), cell))
		_atlas_shape_mesh_cache[key] = amesh
	return amesh

## Return a COPY of a {verts,normals,uvs,indices} geometry dict with its unit-cell UVs affine-folded into atlas `cell`:
## uv_atlas = cell_origin + clamp(uv_unit, 0, 1) × cell_size (design §2.4). ShapeMesh's planar UVs are all in [0,1]²
## (corner heights are half-block ∈{0,0.5,1}, slope/layer heights clamp to [0,1], junction/carve verts are in the unit
## cube), so the clamp is a defensive no-op that GUARANTEES no cell overrun / neighbour bleed under the CLAMP-sampled
## atlas material. verts/normals/indices are shared by reference (read-only in the ArrayMesh); only the UVs are new.
func _atlas_remap_geom(geom: Dictionary, cell: Vector2i) -> Dictionary:
	var g: Vector2i = _atlas.grid
	var sx := 1.0 / float(g.x)
	var sy := 1.0 / float(g.y)
	var ox := float(cell.x) * sx
	var oy := float(cell.y) * sy
	var src: PackedVector2Array = geom["uvs"]
	var out := PackedVector2Array()
	out.resize(src.size())
	for i in src.size():
		var u: Vector2 = src[i]
		out[i] = Vector2(ox + clampf(u.x, 0.0, 1.0) * sx, oy + clampf(u.y, 0.0, 1.0) * sy)
	return {"verts": geom["verts"], "normals": geom["normals"], "uvs": out, "indices": geom["indices"]}

## Record (gate-only) that library model `arid` is an atlas-routed shaped model whose surface i was baked into
## `cells[i]`. No-op unless the gate armed `capture_atlas_probes` and the atlas is live. See verify_atlas.gd.
func _atlas_probe(arid: int, cells: Array) -> void:
	if not (capture_atlas_probes and _atlas != null):
		return
	# Only a model whose EVERY surface got a real cell was actually routed onto the atlas; an invalid cell means the
	# builder fell back to the per-id material (a residual surface, correct look), which the gate must NOT flag.
	for c: Vector2i in cells:
		if c.x < 0 or c.y < 0:
			return
	_atlas_probes.append({"arid": arid, "cells": cells})

## The recorded atlas probes (verify_atlas.gd G-ATLAS-UV/-MAT over the shaped families).
func atlas_shaped_probes() -> Array:
	return _atlas_probes

## The mesh a library model carries (VoxelBlockyModelMesh) — for the gate's shaped-UV read-back. Null when the model
## has no mesh (cube / fluid) or the index is out of range.
func library_model_mesh(arid: int) -> Mesh:
	var model := library_model(arid)
	if model == null:
		return null
	if model.has_method("get_mesh"):
		return model.call("get_mesh") as Mesh
	var m: Variant = model.get("mesh")
	return m as Mesh if m is Mesh else null

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
		var cell := _shape_cell(mat)                     # atlas cube cell for this surface material (Stage 2)
		for modifier: int in mods:
			if modifier <= 0 or modifier >= _GEN_STRIDE:
				continue
			var model: Object = _make_shape_model(modifier, material, cell)
			if model == null:
				continue                                 # no mesh-model class → cube fallback
			var expected := _next_arid
			var got: int = _add_model(library, model)
			if got != expected:
				push_warning("[module_world] manifest ARID drift: add_model %d != expected %d" % [got, expected])
				return                                   # leave the rest -1 (cube fallback)
			_next_arid += 1
			_gen_arid[mat * _GEN_STRIDE + modifier] = got
			_atlas_probe(got, [cell])
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
	# COSMOS FP-CARVE (patch 0004): the seam junction carve-SENTINEL cubes (empty/no-op when not faceted).
	var junctions := _build_carve_manifest(library, total)
	appended += junctions

	if appended > 0 and library.has_method("bake"):
		library.call("bake")                             # one batched bake: dry shapes + water + snow + slope models
	# COSMOS-ATLAS Stage 2 NEVER-OOM ledger. Atlas-remapped UVs are per (cell, modifier), which drops the shipped
	# cross-material geometry sharing, so the shape-mesh COUNT rises. Report BOTH caches so the DELTA is explicit: the
	# shipped `_shape_mesh_cache` (shared; also holds the still-per-material water twins under the flag) and the
	# `_atlas_shape_mesh_cache` (flag-ON, per-cell). The atlas IMAGE is a separate ~5.3 MB (see block_atlas).
	print("[module_world] ATLAS ledger: shared shape meshes %d ≈ %.2f MB; atlas shape meshes %d ≈ %.2f MB (dry/snow/layer + composites; slopes stay shared per-material)"
		% [_shape_mesh_cache.size(), _mesh_cache_mb(_shape_mesh_cache),
			_atlas_shape_mesh_cache.size(), _mesh_cache_mb(_atlas_shape_mesh_cache)])
	print("[module_world] baked appearance manifest: %d (material,modifier) generated shapes (%d materials x %d emitted modifiers; full set would be %d)"
		% [appended - wet - snow - layers - comps - slope, mats.size(), mods.size(), mats.size() * TerrainConfig.appearance_modifiers().size()])
	print("[module_world] baked snow manifest: %d snow-cap variant models for %d cappable materials"
		% [snow, TerrainConfig.snow_cappable_materials().size()])
	print("[module_world] baked snow LAYER manifest: %d snow_block depth-level models (SNOW-ACCUMULATION §1.5)" % layers)
	print("[module_world] baked snow-FILL composites: %d models over %d cold (mat,modifier) pairs x levels {3,5,8,10} (SNOW-ACCUMULATION §2.7)"
		% [comps, TerrainConfig.emitted_cold_pairs().size()])
	print("[module_world] baked slope manifest: %d SHARP-SLOPE models (%d emitted (mat,payload) pairs, incl. snow twins)"
		% [slope, TerrainConfig.emitted_slope_pairs().size()])
	if CubeSphere.FACETED:
		print("[module_world] baked carve manifest: %d seam-junction sentinel cubes (facet %d, ARID range [%d,%d))"
			% [junctions, TerrainConfig.active_facet(), _carve_base, _carve_base + _carve_count])
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
		var scell := _snowcap_cell(mat)                  # atlas snow-CAP cell for this cappable base (Stage 2)
		# The snow-variant CUBE (a full capped cell) at modifier 0.
		var expected := _next_arid
		var got: int = _add_cube(library, variant, BlockCatalog.cull_group_of(mat), scell)
		if got != expected:
			push_warning("[module_world] snow manifest cube ARID drift: add_model %d != expected %d" % [got, expected])
			return appended                              # abort snow manifest; dry + water manifests stand
		_next_arid += 1
		_snow_arid[mat * _GEN_STRIDE + 0] = got
		_atlas_probe(got, [scell])
		appended += 1
		# The snow-variant SHAPES (reuse the shared dry ArrayMesh; only the material override differs).
		for modifier: int in mods:
			if modifier <= 0 or modifier >= _GEN_STRIDE:
				continue
			var model: Object = _make_shape_model(modifier, variant, scell)
			if model == null:
				continue                                 # no mesh-model class → cube/plain fallback
			var exp2 := _next_arid
			var got2: int = _add_model(library, model)
			if got2 != exp2:
				push_warning("[module_world] snow manifest ARID drift: add_model %d != expected %d" % [got2, exp2])
				return appended
			_next_arid += 1
			_snow_arid[mat * _GEN_STRIDE + modifier] = got2
			_atlas_probe(got2, [scell])
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
	var scell := _shape_cell(snow_id)                    # atlas cube cell for snow_block (the LAYER material, Stage 2)
	var appended := 0
	for level in [1, 2, 3, 4, 6, 7, 8, 9]:
		var modifier := CellCodec.make_layer(level)      # the raw FAM modifier for this level
		var model: Object = _make_shape_model(modifier, variant, scell)
		if model == null:
			continue                                     # no mesh-model class → snow-cube fallback
		var expected := _next_arid
		var got: int = _add_model(library, model)
		if got != expected:
			push_warning("[module_world] layer manifest ARID drift: add_model %d != expected %d" % [got, expected])
			return appended                              # abort layer manifest; dry/water/snow stand
		_next_arid += 1
		_layer_arid[level] = got
		_atlas_probe(got, [scell])
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
	var snow_cell := _shape_cell(_snow_id_of())          # surface-1 snow-fill atlas cell (plain snow, Stage 2)
	var appended := 0
	for slot: int in TerrainConfig.emitted_cold_pairs():
		var mat := slot / _GEN_STRIDE
		var modifier := slot % _GEN_STRIDE
		if mat <= BlockCatalog.AIR or mat >= total or modifier <= 0 or modifier >= _GEN_STRIDE:
			continue
		if CellCodec.is_layer(modifier):
			continue                                     # a LAYER cap is baked in _layer_arid, not here
		var skin: Material = BlockMaterials.snow_capped_for(mat)   # surface-0 = the capped ramp (cold ⇒ white)
		var skin_cell := _snowcap_cell(mat)              # surface-0 snow-CAP atlas cell (Stage 2)
		for level in [3, 5, 8, 10]:
			var model: Object = _make_composite_model(modifier, level, skin, snow_mat, skin_cell, snow_cell)
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
			_atlas_probe(got, [skin_cell, snow_cell])
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
## COSMOS-ATLAS Stage 2: with valid `skin_cell` (surface-0 snow-capped ramp) + `snow_cell` (surface-1 snow fill) both
## surfaces ride the ONE shared atlas material with UVs remapped into their respective cells, so the composite MERGES
## into the block's single opaque surface (both surfaces same material). Without cells it is the shipped 2-material
## per-surface path (shared `_shape_mesh_cache`).
func _make_composite_model(modifier: int, level: int, terrain_material: Material, snow_material: Material,
		skin_cell := Vector2i(-1, -1), snow_cell := Vector2i(-1, -1)) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	var use_atlas := skin_cell.x >= 0 and snow_cell.x >= 0 and _atlas != null
	var amesh: ArrayMesh
	if use_atlas:
		var akey := "c:%d:%d:%d:%d:%d:%d" % [modifier, level, skin_cell.x, skin_cell.y, snow_cell.x, snow_cell.y]
		amesh = _atlas_shape_mesh_cache.get(akey, null)
		if amesh == null:
			amesh = ArrayMesh.new()
			_add_surface(amesh, _atlas_remap_geom(ShapeMesh.build(modifier), skin_cell))   # surface 0: capped ramp
			_add_surface(amesh, _atlas_remap_geom(_snow_fill_geom(level), snow_cell))       # surface 1: snow fill
			_atlas_shape_mesh_cache[akey] = amesh
	else:
		var key := modifier | (level << 8) | _COMP_MESH_FLAG
		amesh = _shape_mesh_cache.get(key, null)
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
		model.call("set_material_override", 0, _atlas.material if use_atlas else terrain_material)
		model.call("set_material_override", 1, _atlas.material if use_atlas else snow_material)
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
		# COSMOS-ATLAS Stage 2 — the SLOPE family stays PER-MATERIAL (NOT atlassed): atlas-remapped UVs are per (cell,
		# payload), and the emitted (mat,payload) product here is huge (~3440 pairs × dry+snow-twin ⇒ ~5160 distinct
		# meshes ≈ 5.9 MB), which blows the NEVER-OOM ≤-few-MB budget for a MINORITY (steep-terrain) surface. So a
		# slope-bearing block keeps a residual slope-material surface (an extra draw only where sharp slopes appear); the
		# dominant smoothed-terrain (dry corner shapes + snow caps + layers + snow-fill composites) IS atlassed. Passing
		# no cell → the shipped shared-`_shape_mesh_cache` per-material path (byte-identical to pre-atlas).
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

## COSMOS FP-CARVE (patch 0004) — bake the seam junction carve-SENTINEL cubes into a CONTIGUOUS ARID range.
## The per-facet bevel geometry now lives in the COMPILED mesher (VoxelMesherBlocky.set_facet_carve), which
## clips a plain cube by the active facet's ridge planes at mesh time — so the manifest shrinks to ONE plain
## cube per candidate material (dry) plus its snow-capped variant (~20-30 models vs the old 1152 per-facet
## bevels). Facet-INDEPENDENT (plain cubes), so a crossing re-pushes only the planes (_push_facet_carve), no
## re-bake. Records _carve_arid / _carve_snow_arid (per material) + _carve_base/_carve_count (the range the
## mesher range-tests). Empty/no-op when not faceted. Same anti-drift discipline; a drift aborts (leaving the
## rest -1 → the full-cube lip on the worker, never a hole). Reads active_facet (set before the generator).
func _build_carve_manifest(library: Object, total: int) -> int:
	_carve_arid = PackedInt32Array()
	_carve_snow_arid = PackedInt32Array()
	_carve_base = 0
	_carve_count = 0
	if not CubeSphere.FACETED:
		return 0
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return 0
	_carve_arid.resize(total)
	_carve_arid.fill(-1)
	_carve_snow_arid.resize(total)
	_carve_snow_arid.fill(-1)
	# Only the TERRAIN materials touch a facet seam — the surface set, the shaped (slope) set (sub-surface
	# stone/dirt), plus STONE (mountain peaks). Ores, wood, crafted blocks never reach a ridge.
	var matset := {}
	for m: int in TerrainConfig.appearance_surface_materials():
		matset[m] = true
	for pair: int in TerrainConfig.emitted_slope_pairs():
		matset[pair / _SLOPE_STRIDE] = true
	matset[BlockCatalog.STONE] = true
	_carve_base = _next_arid                              # contiguous range start (set now → valid on early return)
	var appended := 0
	for mat: int in matset.keys():
		if mat <= BlockCatalog.AIR or mat >= total or BlockCatalog.solidity_of(mat) < 0.5:
			continue
		# dry carve-sentinel cube
		var expected := _next_arid
		var got: int = _add_cube(library, BlockMaterials.get_for(mat), BlockCatalog.cull_group_of(mat))
		if got != expected:
			push_warning("[module_world] carve manifest ARID drift: add_cube %d != expected %d" % [got, expected])
			_carve_count = appended
			return appended
		_next_arid += 1
		_carve_arid[mat] = got
		appended += 1
		# snow-capped carve-sentinel cube (upgrades a capped straddle from cube-lip to carved, B5)
		var expected2 := _next_arid
		var got2: int = _add_cube(library, BlockMaterials.snow_capped_for(mat), BlockCatalog.cull_group_of(mat))
		if got2 != expected2:
			push_warning("[module_world] carve snow manifest ARID drift: add_cube %d != expected %d" % [got2, expected2])
			_carve_count = appended
			return appended
		_next_arid += 1
		_carve_snow_arid[mat] = got2
		appended += 1
	_carve_count = appended
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
	# COSMOS FP-CARVE (patch 0004) mirror: a seam junction cell → its carve-SENTINEL cube (the mesher clips
	# it), the snow-capped variant when capped. FIRST liquid_level==0 arm, exactly as the worker / arid_for_cell
	# (equality discipline, B5). `state` carries the snow_capped bit. Unbaked → cube (never a hole).
	if liquid_level == 0 and CellCodec.is_junction(modifier):
		if (state & CellCodec.STATE_SNOW_CAPPED) != 0 and mat < _carve_snow_arid.size() and _carve_snow_arid[mat] >= 0:
			return _carve_snow_arid[mat]
		if mat < _carve_arid.size() and _carve_arid[mat] >= 0:
			return _carve_arid[mat]
		return _cube_arid_of(mat)                        # unbaked → cube lip (never a hole)
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
## COSMOS M4 Stage 2 (§3.2): `old_wrapper_pos` is this wrapper's position in the OLD frame, captured by
## WorldManager BEFORE it repositions the node to the new frame. It is forwarded to restream so the flag-on
## path can pin the old terrain at its old world spot. The default Vector3.INF means "no old frame supplied"
## (the free-immediately path) — keeping the 1-arg call in verify_cosmos_race.gd valid.
func set_home_face(face: int, old_wrapper_pos: Vector3 = Vector3.INF, mwin: Array = [1, 0, 0, 1]) -> void:
	_gen_face = face
	_gen_mwin = mwin                                  # COSMOS-FRAME-ORIENTATION §5.1: freeze the new epoch's M_win
	restream(old_wrapper_pos)

## COSMOS FACETED §6.1 / FP-CARVE (patch 0004) — the crossing restream. Install a fresh generator epoch homed
## on facet `fid` (its gen_facet reads TerrainConfig.active_facet(), which WorldManager sets to `fid` BEFORE
## this call) and hard-restream (the M4 cover + view-distance ramp hides the swap). FP-CARVE makes the seam
## bevel a MESHER-side per-facet clip, so a crossing just RE-PUSHES the new facet's ridge planes — the carve
## sentinel cubes are facet-independent, so no library re-bake (which is all-or-nothing, ~13s web stall). The
## push happens BEFORE restream() (B7) so no in-flight block can mesh a junction cell with stale planes.
func set_facet(fid: int, old_wrapper_pos: Vector3 = Vector3.INF) -> void:
	_push_facet_carve()                               # push the NEW facet's ridge planes (B7: before restream)
	restream(old_wrapper_pos)

## COSMOS FP-CARVE (patch 0004) — push the active facet's own-side ridge planes into the compiled mesher's
## carve blob (VoxelMesherBlocky.set_facet_carve). has_method-guarded (B12): an unpatched binary ignores it and
## the sentinels bake as plain cubes (the full-cube lip — never a hole). No-op (disables the carve) when not
## faceted, no active facet, or nothing baked. Called at setup (after the manifest) and at each crossing.
func _push_facet_carve() -> void:
	if _mesher == null or not _mesher.has_method("set_facet_carve"):
		return
	var fid := TerrainConfig.active_facet()
	if not CubeSphere.FACETED or _carve_count <= 0 or fid < 0:
		_mesher.call("set_facet_carve", {"enabled": false})
		return
	_mesher.call("set_facet_carve", {
		"enabled": true,
		"planes": FacetAtlas.seam_planes_f64(fid),
		"arid_base": _carve_base,
		"arid_count": _carve_count,
	})

# ============================ FP-M1c Planet Assembly pool (flag: CubeSphere.FP_M1_POOL) ============================
# The pooled rotated-neighbour terrains + re-designation crossing (docs/COSMOS-FP-M1-DESIGN.md §4, §5). Reuses THIS
# module's ONE baked VoxelBlockyLibrary + generator factory + carve tables; each pool terrain gets its OWN mesher
# (own carve blob) + OWN generator frozen on its fid (the frozen-epoch discipline — each worker reads its own
# immutable gen_facet). Exactly ONE VoxelViewer (attach_viewer) serves all of them; NO static/extra viewers ever.

## Build a bounds-clamped VoxelTerrain frozen on `fid` with its own mesher+carve+generator, parented under a
## FacetSlot @ facet_transform(fid) below PlanetRoot. Returns the FacetSlot dict, or {} on failure. Shared by the
## active-facet init and every neighbour spawn (the ONE construction path — §4.1). Adds NO viewer.
func _pool_build_slot(fid: int, view_blocks: int, editable: bool) -> Dictionary:
	if _library == null or not ClassDB.class_exists("VoxelTerrain"):
		return {}
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if mesher == null:
		return {}
	if mesher.has_method("set_library"):
		mesher.call("set_library", _library)
	else:
		_set_if(mesher, "library", _library)
	# The facet's OWN-side ridge planes into ITS OWN carve blob (patch 0004, per-mesher, facet-static). Guarded:
	# an unpatched binary lacks set_facet_carve → the sentinels bake as plain cubes (full-cube lip, never a hole).
	if mesher.has_method("set_facet_carve"):
		if _carve_count > 0 and fid >= 0:
			mesher.call("set_facet_carve", {
				"enabled": true,
				"planes": FacetAtlas.seam_planes_f64(fid),
				"arid_base": _carve_base,
				"arid_count": _carve_count,
			})
		else:
			mesher.call("set_facet_carve", {"enabled": false})
	var generator: Object = _make_generator(fid)   # OWN generator frozen on this fid's gen_facet (worker-safe)
	if generator == null:
		return {}
	var terrain := ClassDB.instantiate("VoxelTerrain") as Node3D
	if terrain == null:
		return {}
	_set_if(terrain, "mesher", mesher)
	_set_if(terrain, "generator", generator)
	_set_if(terrain, "max_view_distance", view_blocks)
	_set_if(terrain, "mesh_block_size", 32)
	_set_if(terrain, "generate_collisions", false)
	_apply_bounds(terrain, fid)                     # §3.2: clamp to this facet's domain slab — no foreign block exists
	var slot := Node3D.new()
	slot.name = "FacetSlot_%d" % fid
	slot.transform = FacetAtlas.facet_transform(fid)
	_planet_root.add_child(slot)
	slot.add_child(terrain)
	return {
		"terrain": terrain, "slot": slot, "mesher": mesher, "generator": generator,
		"spawn_ms": Time.get_ticks_msec(), "view": view_blocks, "editable": editable, "fid": fid,
		# FP-M1c per-slot view-distance ramp (§5 load-shaping). view_f is the live FLOAT radius the ramp advances;
		# view_target its goal; ramp_from the radius the current leg started at (a leg takes RAMP_SECONDS from
		# ramp_from → view_target regardless of target size). Defaults = NO ramp (target == current == view_blocks):
		# only pool_spawn / redesignate opt a slot into a ramp, so the active-init and pool_reset paths stay full-view.
		"view_f": float(view_blocks), "view_target": float(view_blocks), "ramp_from": float(view_blocks),
	}

## Clamp a terrain's streaming to its facet's domain slab (§3.2). The engine clips every view box against `bounds`
## (voxel_terrain.cpp:1296,1314), so no data/mesh block outside the slab is ever requested, allocated, or meshed —
## a GEOMETRIC per-terrain memory ceiling independent of viewer behaviour (the spike's missing clamp, §2 defect 2).
func _apply_bounds(terrain: Object, fid: int) -> void:
	if terrain == null or not (terrain.has_method("set_bounds") or _has_prop(terrain, "bounds")):
		return
	var dmin: Vector2i = FacetAtlas.dom_min(fid)    # facet-lattice (x,z); domain already includes MARGIN_CELLS
	var dmax: Vector2i = FacetAtlas.dom_max(fid)
	var y_min := float(TerrainConfig.BEDROCK_FLOOR)
	var y_max := float(TerrainConfig.MAX_SURFACE_Y + max(TreeGen.MAX_ABOVE_SURFACE, TerrainConfig.SNOW_FILL_MAX_CELLS))
	var pos := Vector3(float(dmin.x) - 2.0, y_min, float(dmin.y) - 2.0)   # +2 seam strip (§3.2)
	var size := Vector3(float(dmax.x - dmin.x) + 4.0, y_max - y_min, float(dmax.y - dmin.y) + 4.0)
	_set_if(terrain, "bounds", AABB(pos, size))

## RENDER-SIMPLIFY (docs/COSMOS-RENDER-SIMPLIFY-DESIGN.md §1) — the single near-LOD predicate (mirrors WorldManager's).
## FP_NO_NEAR_LOD is the inverse of FP_M2_LOD: with it off this equals FP_M2_LOD exactly (byte-identical), with it on the
## LOD mesher is never created here. The passive lod_* generator/terrain accessors below stay on raw FP_M2_LOD.
func _near_lod_on() -> bool:
	return CubeSphere.FP_M2_LOD and not CubeSphere.FP_NO_NEAR_LOD

## FP-M2b (§5): create the FacetLodMesher under PlanetRoot and prime its static tiers on the active facet. Safe
## no-op unless FP_M2_LOD (mesher.setup returns false → _lod_mesher stays null and the LOD path is fully dead).
func _lod_setup() -> void:
	# RENDER-SIMPLIFY §2.1: FP_NO_NEAR_LOD bypasses the whole LOD stack at its creation site — return early so
	# _lod_mesher stays null (the builder Thread never starts, the 96 MB ledger never allocates). _near_lod_on() ==
	# FP_M2_LOD with the flag off → byte-identical.
	if not _near_lod_on() or _planet_root == null:
		return
	var scr: Script = load("res://src/world/facet_lod_mesher.gd")
	if scr == null:
		return
	var m = scr.new()
	m.name = "FacetLodMesher"
	_planet_root.add_child(m)
	if not bool(m.call("setup", self)):
		_planet_root.remove_child(m)
		m.free()
		return
	_lod_mesher = m
	_lod_mesher.call("set_active_facet", _pool_active)
	if _load_ctrl != null:                            # FP-M2c: a pool_reset rebuild re-forwards the controller (§6.5)
		_lod_mesher.call("set_load_controller", _load_ctrl)
	set_process(true)

## FP-M2b: join the builder Thread before the node tree tears down (a bare free would leak the running Thread).
func _exit_tree() -> void:
	if _lod_mesher != null:
		_lod_mesher.call("shutdown")
		_lod_mesher = null

## FP-M2b far-ring merge (§5.5): the facets whose LOD mesh is APPLIED (excluded from the quad ring). [] with the
## flag off / no mesher — the WorldManager merge then reduces to the shipped pool-neighbour exclusion.
func lod_covered_fids() -> Array:
	return _lod_mesher.call("covered_fids") if _lod_mesher != null else []

## FP-M2b gate accessor: the live FacetLodMesher (verify_fp_m2 drives caps/frame/seam through it). null with the flag off.
func lod_mesher():
	return _lod_mesher

## FP-M2d (§9.1): drop the held LOD cover for promoting facet `fid` — WorldManager calls this once `fid`'s live terrain
## seam band has meshed (pool_seam_meshed) or the promote timeout expires. No-op without a mesher (flag off).
func lod_evict(fid: int) -> void:
	if _lod_mesher != null:
		_lod_mesher.call("evict", fid)

## FP-M2d (§9.1): lift the promote HOLD without evicting — the facet retired before its promote completed, so its LOD
## mesh stays but normal want-management resumes. WorldManager calls this from _lod_promote_pass. No-op without a mesher.
func lod_end_promote(fid: int) -> void:
	if _lod_mesher != null:
		_lod_mesher.call("end_promote", fid)

## FP-M2d (§6.5.4): sustained-overload relief — coarsen one least-wanted LOD facet a tier (pause-first; live terrains
## untouched). WorldManager calls this only while StreamLoadController.demote_pressure() holds. No-op without a mesher.
func lod_demote_pressure() -> void:
	if _lod_mesher != null:
		_lod_mesher.call("demote_pressure_relief")

## FP-M2d M2e-WIRE hook: the FacetLodMesher stats snapshot (facet/tri/byte ledgers, in-flight, aprons) — forwarded up
## through WorldManager.lod_stats() for the soak/heap-A/B harness. {} without a mesher (flag off).
func lod_stats() -> Dictionary:
	return _lod_mesher.call("stats") if _lod_mesher != null else {}

## FP-M2d (§9.1): has PROMOTING neighbour `fid`'s seam-side band (the strip of `fid` nearest the player) finished
## MESHING? The player's ACTIVE-facet-lattice position is reframed into `fid`'s lattice (= `fid`'s terrain LOCAL space,
## since the slot applies facet_transform(fid) over fid-lattice geometry) and probed with is_area_meshed. Returns true
## when `fid` is not live / the terrain lacks is_area_meshed (never block a promote's completion on a missing probe).
func pool_seam_meshed(fid: int, player_active_pos: Vector3) -> bool:
	if not _pool.has(fid):
		return true
	var t: Object = _pool[fid]["terrain"]
	if t == null or not t.has_method("is_area_meshed"):
		return true
	var lp := FacetAtlas.reframe_position64(_pool_active, fid,
		player_active_pos.x, player_active_pos.y, player_active_pos.z)
	var c := Vector3(float(lp[0]), float(lp[1]), float(lp[2]))
	var half := Vector3(32.0, 40.0, 32.0)
	return bool(t.call("is_area_meshed", AABB(c - half, half * 2.0)))

## FP-M2c (§6.5.3 surface 3): set the pool view-ramp pace ∈ [0,1] from the StreamLoadController. The GROW leg of every
## view ramp is stretched by `f` (RAMP_SECONDS the min duration; f=0 holds it). Clamped; default 1.0 → the shipped
## fixed ramp. M2d calls this each frame with the controller's stream_pace(); M2c leaves it at 1.0 (byte-identical).
func set_stream_pace(f: float) -> void:
	_stream_pace = clampf(f, 0.0, 1.0)

## FP-M2c (§6.5): store the StreamLoadController (owned by WorldManager) and forward it to the FacetLodMesher, which
## scales its LOD apply-ms + build grants by the credit (surfaces 1-2). No-op if the mesher is absent (flag off).
func set_load_controller(c) -> void:
	_load_ctrl = c
	if _lod_mesher != null:
		_lod_mesher.call("set_load_controller", c)

## CONTROLLER-FIX §P3c: WorldManager forwards the committed imminent-ridge fid each pool pass (−1 = none). Stored here to
## floor THAT slot's view-ramp pace in _ramp_pool_step, and forwarded to the mesher (relief-mode budgeter + demote sparing).
func set_imminent_fid(fid: int, committed: bool = false) -> void:
	var prev := _imminent_fid
	_imminent_fid = fid
	_imminent_committed = committed
	if _lod_mesher != null:
		_lod_mesher.call("set_imminent_fid", fid)
	# COSMOS-FP-CROSSING-PREGEN (#114): pre-grow the COMMITTED imminent slot to the ACTIVE near radius during the approach
	# so redesignate's 96→128 fill is already done at the seam (zero new generation on the crossing frame). The relief-
	# floored imminent leg of _ramp_pool_step paces the extra annulus across the ~6 s approach. A slot that STOPS being the
	# imminent (reverse / corner-switch) and is not the active drops back to 96 (a shrink → snapped unload) so the enlarged
	# live volume is held ONLY for the facet we are crossing to (NEVER-OOM: at most one 128-view neighbour). Gated on the
	# fixed frame — a fuller imminent is free there (O(1) crossing, §9) but would enlarge the redesignate transform write
	# otherwise. Off ⇒ this whole block is skipped and view_target stays 96 (byte-identical to the shipped FP-M2d ramp).
	if not (CubeSphere.POOL_CROSSING_PREGEN and _fixed_frame_on()):
		return
	if prev == fid:
		return
	var target := minf(CubeSphere.imminent_prefill_blocks(), float(TerrainConfig.near_render_radius()))
	# Demote the OUTGOING imminent (if it is a live non-active neighbour) back to the neighbour radius.
	if prev >= 0 and prev != _pool_active and _pool.has(prev):
		var ps: Dictionary = _pool[prev]
		if float(ps["view_target"]) > 96.0:
			ps["view_target"] = 96.0
			ps["ramp_from"] = float(ps["view_f"])       # shrink leg → snapped by the next _ramp_pool_step (cheap unload)
			_pool_ramp_kick()
	# Promote the INCOMING imminent (if already spawned; a fresh spawn is handled in pool_spawn) to the active radius.
	if fid >= 0 and fid != _pool_active and _pool.has(fid):
		var s: Dictionary = _pool[fid]
		if float(s["view_target"]) < target:
			s["view_target"] = target
			s["ramp_from"] = float(s["view_f"])          # grow leg from wherever it sits now; paced (relief-floored) grow
			_pool_ramp_kick()

## FP-M1c (§4.1) init: create PlanetRoot @ T_active⁻¹ and reparent the setup()-built active terrain into a
## composite-identity FacetSlot, bounds-clamped to its slab. The active terrain keeps its already-set view
## (near_render_radius = 128) + already-pushed carve; it just moves under PlanetRoot. Called once from setup().
## COSMOS FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §10 decision 5) — the fixed frame is active only with
## its flag AND both prerequisites on. When on, PlanetRoot is PINNED @ identity (the scene frame IS the planet-
## absolute frame) so each FacetSlot's global == its own T_fid (its true place) and a crossing NEVER re-writes
## PlanetRoot (no NOTIFICATION_TRANSFORM_CHANGED). Off ⇒ PlanetRoot @ T_active⁻¹ exactly as today (byte-identical).
func _fixed_frame_on() -> bool:
	return CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL

## The PlanetRoot transform for `active_fid`: identity (minus the re-anchor offset) under the fixed frame (absolute
## scene frame), else the shipped T_active⁻¹ that re-centres the active facet at the lattice origin.
func _planet_root_placement(active_fid: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, -_anchor_offset) if _fixed_frame_on() else FacetAtlas.facet_transform(active_fid).affine_inverse()

## COSMOS FP-FIXED-FRAME re-anchor (docs/COSMOS-FIXED-FRAME-DESIGN.md §3 / §10 decision 1) — slide PlanetRoot (hence
## EVERY child FacetSlot AND the LOD-tile layer) by −A so the rendered planet-absolute coords stay near the origin
## for large-planet f32 headroom. This is the ONE transform write that fires godot_voxel's NOTIFICATION_TRANSFORM_
## CHANGED per-mesh-block re-place — ACCEPTED because a re-anchor fires FAR less often than a crossing (only when
## |player_abs| > REANCHOR_TRIGGER_BLOCKS, i.e. never at R = 3072), so it is one rare re-place, never on the hot
## crossing path. No-op unless the fixed frame is on and PlanetRoot exists (byte-identical off).
func shift_anchor(a: Vector3) -> void:
	if not _fixed_frame_on() or _planet_root == null:
		return
	_anchor_offset += a
	_planet_root.position = -_anchor_offset

func _pool_init_active() -> void:
	_pool_active = TerrainConfig.active_facet()
	_planet_root = Node3D.new()
	_planet_root.name = "PlanetRoot"
	_planet_root.transform = _planet_root_placement(_pool_active)
	add_child(_planet_root)
	_apply_bounds(_terrain, _pool_active)
	var slot := Node3D.new()
	slot.name = "FacetSlot_%d" % _pool_active
	slot.transform = FacetAtlas.facet_transform(_pool_active)
	_planet_root.add_child(slot)
	slot.add_child(_terrain)
	var arv := TerrainConfig.near_render_radius()
	_pool[_pool_active] = {
		"terrain": _terrain, "slot": slot, "mesher": _mesher, "generator": _generator,
		"spawn_ms": Time.get_ticks_msec(), "view": arv,
		"editable": true, "fid": _pool_active,
		# Active at init keeps its already-set full near view — NO ramp (target == current). (§5)
		"view_f": float(arv), "view_target": float(arv), "ramp_from": float(arv),
	}

## Spawn a render-only neighbour terrain for facet `fid` (view 96). Enforces the caps: FP_M1_POOL on, faceted, a
## live PlanetRoot, `fid` not already pooled, and the neighbour count below POOL_MAX_NEIGHBOURS. Returns true on a
## successful spawn. Adds NO viewer. Amortization (≤1/s) + the D_WARM trigger are the caller's (WorldManager §4.3).
func pool_spawn(fid: int) -> bool:
	if not (CubeSphere.FACETED and CubeSphere.FP_M1_POOL) or _planet_root == null:
		return false
	if fid < 0 or _pool.has(fid):
		return false
	if pool_neighbour_count() >= CubeSphere.POOL_MAX_NEIGHBOURS:
		return false
	# Build the neighbour at a SMALL start view and RAMP it up to 96 over RAMP_SECONDS (§5 load-shaping): a fresh
	# terrain jammed straight to view 96 requests its WHOLE view sphere in one process pass → a generation burst →
	# the main-thread mesh-apply (voxel/threads/main/time_budget_ms) spikes → the border hitch. The ramp spreads that
	# fill across frames, exactly like the active-facet restream ramp; the far-ring quad covers the rim until it meshes.
	var start := int(minf(RAMP_START_BLOCKS, 96.0))
	var s := _pool_build_slot(fid, start, false)
	if s.is_empty():
		return false
	# COSMOS-FP-CROSSING-PREGEN (#114): if THIS spawn is the committed imminent (set by WorldManager just before this
	# call, same pool pass), ramp straight to the ACTIVE near radius instead of 96 — the crossing-target facet fully
	# streams during the approach, so redesignate adds no generation at the seam. Relief-floored in _ramp_pool_step, so
	# the wider 48→128 fill still SPREADS across the approach (never a burst). Gated on the fixed frame; off ⇒ 96 (shipped).
	var nb_target := 96.0
	if CubeSphere.POOL_CROSSING_PREGEN and _fixed_frame_on() and fid == _imminent_fid:
		nb_target = minf(CubeSphere.imminent_prefill_blocks(), float(TerrainConfig.near_render_radius()))
	s["view_target"] = nb_target
	s["ramp_from"] = float(start)
	_pool[fid] = s
	_pool_ramp_kick()
	if _lod_mesher != null:                          # FP-M2d (§9.1): `fid` is now live — HOLD its LOD cover (no gap)
		_lod_mesher.call("on_promote", fid)          #   until WorldManager evicts it on seam-band-meshed (lod_evict).
	return true

## Retire (free) a neighbour terrain. Never frees the active facet. queue_free's the whole slot (terrain → its
## mesher + generator drop with it) and erases every GDScript ref so nothing pins the freed maps (§10 leak class #1).
func pool_retire(fid: int) -> bool:
	if not _pool.has(fid) or fid == _pool_active:
		return false
	var s: Dictionary = _pool[fid]
	var slot: Node3D = s.get("slot")
	_pool.erase(fid)                                # drop OUR refs first
	if slot != null and is_instance_valid(slot):
		if slot.get_parent() != null:
			slot.get_parent().remove_child(slot)
		slot.queue_free()                           # frees the terrain + its mesher/generator
	if _lod_mesher != null:                          # FP-M2b: `fid` went dormant → it may re-enter LOD coverage
		_lod_mesher.call("notify_pool_changed")
	return true

## Re-designation crossing (§5.1): make `to` the active (editable, composite-identity) facet and the old active a
## rotated render-only neighbour, in ONE PlanetRoot transform write + a view rebalance. NO teardown, NO restream,
## NO new generator, NO terrain freed. Returns true on a POOL HIT; false on a POOL MISS (`to` not pooled — the
## caller falls back to the FP-S1 set_facet teardown). Requires `to` to already be a spawned neighbour.
func redesignate(to: int) -> bool:
	if not (CubeSphere.FACETED and CubeSphere.FP_M1_POOL) or _planet_root == null:
		return false
	if not _pool.has(to) or to == _pool_active:
		return false
	var from := _pool_active
	# A1 CROSSING INSTRUMENTATION (#114): time the whole redesignate + bracket the SINGLE transform write, which is
	# what fires godot_voxel's NOTIFICATION_TRANSFORM_CHANGED → per-mesh-block instance_set_transform across all live
	# terrains (the 200–772 ms spike). Only executes on a real crossing (this is the crossing path), so zero cost off.
	var _redesig_t0 := Time.get_ticks_usec()
	# ONE assignment — the engine re-places every child slot's mesh blocks rigidly (voxel_terrain.cpp:867-882),
	# sub-frame, no meshing. `to`'s composite becomes T_to⁻¹·T_to = identity (axis-aligned, editable); `from`'s
	# becomes T_to⁻¹·T_from (the dihedral turn — the rotated neighbour, same weld as the far ring).
	var _xform_t0 := Time.get_ticks_usec()
	# FP-FIXED-FRAME (§2.2 step 3, THE keystone): under the fixed frame PlanetRoot is pinned @ identity forever, so we
	# SKIP this write entirely — no NOTIFICATION_TRANSFORM_CHANGED, no per-mesh-block instance_set_transform re-place,
	# no 200–772 ms deferred spike. The crossing instead re-frames only the ~10 ActiveFrame children (WorldManager).
	if not _fixed_frame_on():
		_planet_root.transform = FacetAtlas.facet_transform(to).affine_inverse()
	var _transform_us := Time.get_ticks_usec() - _xform_t0
	# View-distance rebalance (§5). `to` RAMPS up 96 → near radius: jamming that 96→128 delta annulus in ONE pass is
	# the SECOND crossing burst — spread it over RAMP_SECONDS like every other grow (the ramp step drives it from the
	# next frame; the far ring covers the delta rim meanwhile). `from` shrinks to the neighbour radius, and a shrink
	# only UNLOADS blocks → cheap → snapped immediately. bounds/carve/generator are facet-static → untouched.
	var to_target := float(TerrainConfig.near_render_radius())
	_pool[to]["view_target"] = to_target
	_pool[to]["ramp_from"] = float(_pool[to]["view_f"])   # ramp from wherever `to` sits now (96 warm, or mid-ramp)
	_pool[to]["editable"] = true
	if _pool.has(from):
		_set_if(_pool[from]["terrain"], "max_view_distance", 96)
		_pool[from]["view"] = 96
		_pool[from]["view_f"] = 96.0
		_pool[from]["view_target"] = 96.0
		_pool[from]["ramp_from"] = 96.0
		_pool[from]["editable"] = false
	_pool_ramp_kick()
	# Designate edits + statistics + set_cell onto `to` (edit keys are (fid,cell)-global — nothing migrates, §5.1.d).
	_pool_active = to
	_terrain = _pool[to]["terrain"]
	_mesher = _pool[to]["mesher"]
	_generator = _pool[to]["generator"]
	# FP-M2b: the LOD layer moved rigidly with the ONE PlanetRoot write (no rebuild). Re-tier for the new active
	# facet — `to` is now live (dropped from LOD coverage), the old active becomes the nearest LOD ring next tick.
	if _lod_mesher != null:
		_lod_mesher.call("set_active_facet", to)
	# A1 CROSSING INSTRUMENTATION (#114): stash the attribution metrics for WorldManager to drain. blocks_replaced is
	# the loaded mesh-block count re-placed by the transform write (summed across every live pool terrain); the two µs
	# figures split the transform write out of the total redesignate cost. Measured AFTER the write — the block SET is
	# unchanged by a rigid re-place, only re-positioned. This whole tail is on the crossing path (runs once per cross).
	_last_redesignate = {
		"transform_us": _transform_us,
		"redesignate_us": Time.get_ticks_usec() - _redesig_t0,
		"blocks_replaced": _pool_block_sum(),
		"live_neighbours": pool_neighbour_count(),
		"lod_tiles": _lod_tile_count(),
	}
	return true

## A1 CROSSING INSTRUMENTATION (#114): return the last redesignate()'s metrics and CLEAR the latch (so a drain never
## re-reports a stale crossing). {} when no crossing has occurred since the last drain. Crossing-path only — never
## called in normal play (WorldManager.maybe_cross_facet is the sole caller, right after a committed redesignate).
func take_last_redesignate() -> Dictionary:
	var out := _last_redesignate
	_last_redesignate = {}
	return out

## Sum the loaded mesh-block counters across every LIVE pool terrain (active + neighbours) via godot_voxel's
## get_statistics() — this is the block population the ONE PlanetRoot transform write re-places. get_statistics
## exposes a flat dict of counters; we sum the int entries whose key mentions "block" (the same shape the cosmos
## gates read). Called once per crossing only, so the per-terrain stat probe never costs a per-frame anything.
func _pool_block_sum() -> int:
	var total := 0
	for fid in _pool.keys():
		var t: Object = _pool[fid]["terrain"]
		if t == null or not t.has_method("get_statistics"):
			continue
		var st = t.call("get_statistics")
		if st is Dictionary:
			for k in (st as Dictionary).keys():
				var v = st[k]
				if v is int and String(k).findn("block") >= 0:
					total += int(v)
	return total

## The FP-M2 LOD layer's covered-facet count (each is a re-tiered LOD mesh set moved by the same PlanetRoot write).
## 0 when the LOD layer is absent (FP_M2_LOD off) — cheap stats() read, crossing-path only.
func _lod_tile_count() -> int:
	if _lod_mesher == null or not _lod_mesher.has_method("stats"):
		return 0
	var ls = _lod_mesher.call("stats")
	return int((ls as Dictionary).get("facets", 0)) if ls is Dictionary else 0

## FP-M1c pathological POOL-MISS fallback (§5.1.a): the destination `to` could not be re-designated NOR spawned
## (e.g. a teleport past the neighbour cap). Rather than the FP-S1 set_facet teardown (which would rebuild OUTSIDE
## PlanetRoot and desync the pool), REBUILD the pool fresh on `to`: free the whole PlanetRoot (all live terrains)
## and construct a new active `to` slot. Degraded (neighbours re-spawn as the player walks) but NEVER corrupt/blank.
## Keeps the world-frame invariant (composite identity for `to`). No-op unless FP_M1_POOL.
func pool_reset(to: int) -> bool:
	if not (CubeSphere.FACETED and CubeSphere.FP_M1_POOL):
		return false
	# FP-M2b: the mesher is a child of the PlanetRoot we are about to free — join its builder Thread FIRST (a bare
	# free would leak the running Thread), then it frees with the old PlanetRoot; a fresh one stands up below.
	if _lod_mesher != null:
		_lod_mesher.call("shutdown")
		_lod_mesher = null
	if _planet_root != null and is_instance_valid(_planet_root):
		remove_child(_planet_root)
		_planet_root.queue_free()
	_planet_root = null
	_pool.clear()
	_planet_root = Node3D.new()
	_planet_root.name = "PlanetRoot"
	_planet_root.transform = _planet_root_placement(to)   # FP-FIXED-FRAME: identity under the flag (absolute frame)
	add_child(_planet_root)
	var s := _pool_build_slot(to, TerrainConfig.near_render_radius(), true)
	if s.is_empty():
		return false
	_pool[to] = s
	_pool_active = to
	_terrain = s["terrain"]
	_mesher = s["mesher"]
	_generator = s["generator"]
	_push_facet_carve()                              # re-point the (module-level) active mesher carve at `to`
	_lod_setup()                                     # FP-M2b: rebuild the LOD layer under the fresh PlanetRoot
	return true

# --- pool introspection (WorldManager policy + the FP-M1c gates) ---
func pool_has(fid: int) -> bool:
	return _pool.has(fid)
func pool_active() -> int:
	return _pool_active
## MAIN-THREAD BREAKDOWN (streaming-hitch instrumentation, 2026-07-17). VoxelTerrain::_b_get_statistics
## (voxel_terrain.cpp:603) returns godot_voxel's OWN "breakdown of time spent in _process" — the four
## time_* fields are MAIN-THREAD microseconds per _process call, plus the drop/update counters. This is
## the only way to localise the streaming hitch: live telemetry shows worst_ms 117-136 ms whenever
## vox_gen > 0 (even STANDING STILL) while the mesh/apply queues read 0 — so either that main-thread
## cost lives inside VoxelTerrain::_process (these fields will show it) or it lives OUTSIDE it (they
## will all be small, and the hitch is render/upload — a completely different fix). Telemetry-only,
## read-only, no behaviour change; guarded so a missing method/terrain simply yields {}.
## T2b (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): SUM VoxelTerrain::_process timings over ALL live pool slots, not just
## the active _terrain — the imminent-prefill slot is where a crossing's apply burst lands and its main-thread cost was
## invisible (the shipped read saw only _terrain). The active slot IS a _pool entry (the module keeps _terrain ==
## _pool[_pool_active]["terrain"]), so iterating the pool alone avoids double-counting; the single _terrain is the
## fallback on the non-pool path. Every returned key is a per-frame numeric field, so a plain per-key sum is correct and
## the RemoteBridge consumer (which reads by key name) sees each field aggregated across the whole live pool.
func terrain_main_thread_stats() -> Dictionary:
	var terrains: Array = []
	if not _pool.is_empty():
		for fid in _pool.keys():
			var t = _pool[fid].get("terrain")
			if t != null:
				terrains.append(t)
	elif _terrain != null:
		terrains.append(_terrain)
	var out: Dictionary = {}
	for t in terrains:
		if not (t as Object).has_method("get_statistics"):
			continue
		var d = t.call("get_statistics")
		if not (d is Dictionary):
			continue
		for k in (d as Dictionary).keys():
			var v = (d as Dictionary)[k]
			if v is int or v is float:
				out[k] = out.get(k, 0) + v
	return out

## STREAM-SCHED T1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §9.1) — the per-class generation histogram, summed over
## EVERY live generator (the active slot + each pool slot owns its own instance, frozen on its own facet epoch;
## _generator is the active slot's, so dedupe by instance id or a crossing double-counts it). Returns
## {ct: [4 ints], us: [4 ints]} — class 0 air/cheap, 1 whole-block bulk, 2 underground per-cell (the
## gate-failed class R1 targets), 3 surface-crossing. Counters are CUMULATIVE per epoch and telemetry-grade
## (racy across the workers sharing one generator — see the generator's gen_ct_* comment); an epoch install
## resets them to 0, so a consumer differencing windows must floor negative deltas at 0. Empty on the fallback
## path / before setup.
func gen_class_stats() -> Dictionary:
	var ct := [0, 0, 0, 0]
	var us := [0, 0, 0, 0]
	var seen := {}
	var gens: Array = []
	if _generator != null:
		gens.append(_generator)
	for fid in _pool.keys():
		var g = _pool[fid].get("generator")
		if g != null:
			gens.append(g)
	var any := false
	for g in gens:
		var gid := (g as Object).get_instance_id()
		if seen.has(gid):
			continue
		seen[gid] = true
		if not (g as Object).has_method("gen_stats"):
			continue
		var d = (g as Object).call("gen_stats")
		if not (d is Dictionary):
			continue
		any = true
		var dct: Array = (d as Dictionary).get("ct", [])
		var dus: Array = (d as Dictionary).get("us", [])
		for i in range(4):
			if i < dct.size():
				ct[i] += int(dct[i])
			if i < dus.size():
				us[i] += int(dus[i])
	return {"ct": ct, "us": us} if any else {}

func pool_neighbour_count() -> int:
	return maxi(0, _pool.size() - (1 if _pool.has(_pool_active) else 0))
## Every LIVE facet id in the pool (active + neighbours) — the far-ring excluded set + the gate's ≤1+4 cap check.
func pool_fids() -> Array:
	return _pool.keys()
## The render-only NEIGHBOUR fids (active excluded) — the FacetFarRing exclusion set (no flat-quad double-draw).
func pool_neighbour_fids() -> Array:
	var out: Array = []
	for fid in _pool.keys():
		if fid != _pool_active:
			out.append(fid)
	return out
## Seconds `fid` has been live (WorldManager's MIN_LIVE_S anti-thrash gate). -1 if not pooled.
func pool_age_s(fid: int) -> float:
	if not _pool.has(fid):
		return -1.0
	return float(Time.get_ticks_msec() - int(_pool[fid]["spawn_ms"])) / 1000.0
## A pool terrain's live `bounds` AABB (the gate asserts bounds ⊆ facet slab). AABB() if absent.
func pool_bounds(fid: int) -> AABB:
	if not _pool.has(fid):
		return AABB()
	var t: Object = _pool[fid]["terrain"]
	if t == null or not _has_prop(t, "bounds"):
		return AABB()
	return t.get("bounds")
## A pool terrain node (the gate's is_area_meshed / statistics probes). null if absent.
func pool_terrain(fid: int) -> Node3D:
	return _pool[fid]["terrain"] if _pool.has(fid) else null

## COSMOS SEAMLESS-SCALES C3 (skin overdraw fix): is facet `fid`'s near voxel field fully meshed over the
## fid-LATTICE box `aabb`? The skin builds tiles in fid-lattice, and a VoxelTerrain's is_area_meshed operates
## in its OWN voxel (= fid-lattice) coordinates regardless of the slot's Node3D transform — the SAME reason
## pool_seam_meshed reframes into fid-lattice before probing — so the tile AABB maps in directly, no reframe.
## Returns false (→ the skin RENDERS the tile) whenever the fid is not live, its terrain lacks the probe, or
## the box is not fully meshed (a streaming hole). This is the underlay coverage the skin's covered-tile skip
## consumes; it is a pure read, so it adds no streaming/apply cost.
func skin_near_meshed(fid: int, aabb: AABB) -> bool:
	var t: Object = null
	if _pool.has(fid):
		t = _pool[fid]["terrain"]
	elif fid == _pool_active or fid == TerrainConfig.active_facet():
		t = _terrain
	if t == null or not t.has_method("is_area_meshed"):
		return false
	return bool(t.call("is_area_meshed", aabb))
## FP-M1c view-ramp introspection (§5). pool_view: the LIVE engine-applied max_view_distance (read off the terrain,
## not the bookkeeping int — the honest value the ramp gate asserts). pool_view_target: the ramp goal. -1 if absent.
func pool_view(fid: int) -> int:
	if not _pool.has(fid):
		return -1
	var t: Object = _pool[fid]["terrain"]
	return int(t.get("max_view_distance")) if (t != null and _has_prop(t, "max_view_distance")) else -1
func pool_view_target(fid: int) -> int:
	return int(round(float(_pool[fid]["view_target"]))) if _pool.has(fid) else -1
## FP-M1c gate hook: advance the per-slot pool view ramp by `delta` seconds deterministically (headless frames carry
## no stable dt, and _process may be dormant). Returns true while any slot is still growing. Test-only; production
## drives the ramp from _process. No-op-safe: just calls the same step _process uses.
func pool_ramp_tick(delta: float) -> bool:
	return _ramp_pool_step(delta)
## The shared baked library / a fid-frozen generator / a fid-carve mesher / the carve range — the SEAM gates build
## meshes with these directly (the spike_* accessors' pool-flag twins; available whenever FP_M1_POOL is on).
func pool_library() -> Object:
	return _library if (CubeSphere.FP_M1_POOL or CubeSphere.FP_R0) else null
func pool_generator(fid: int) -> Object:
	return _make_generator(fid) if (CubeSphere.FP_M1_POOL or CubeSphere.FP_R0) else null
func pool_carve_mesher(fid: int) -> Object:
	if not (CubeSphere.FP_M1_POOL or CubeSphere.FP_R0) or _library == null:
		return null
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if mesher == null:
		return null
	if mesher.has_method("set_library"):
		mesher.call("set_library", _library)
	else:
		_set_if(mesher, "library", _library)
	if mesher.has_method("set_facet_carve") and _carve_count > 0 and fid >= 0:
		mesher.call("set_facet_carve", {
			"enabled": true, "planes": FacetAtlas.seam_planes_f64(fid),
			"arid_base": _carve_base, "arid_count": _carve_count,
		})
	return mesher
func pool_carve_range() -> Vector2i:
	return Vector2i(_carve_base, _carve_count)

## True iff `obj` exposes a settable property named `name` (bounds feature-detect without has_method churn).
func _has_prop(obj: Object, name: String) -> bool:
	for p in obj.get_property_list():
		if String(p.get("name", "")) == name:
			return true
	return false

# ============================ FP-R0 SPIKE (flag-gated: CubeSphere.FP_R0) ============================
# The multi-facet rotation kill-shot (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §3, §8 FP-R0). All methods
# below no-op unless CubeSphere.FP_R0 is on (sed-toggled by verify_fp_r0), so the shipped build is untouched.
# They reuse THIS module's ONE baked VoxelBlockyLibrary and generator factory to build extra terrains, keeping
# the frozen-epoch discipline (each terrain's worker reads its own frozen gen_facet, never a mutable global).

## Build a SECOND VoxelTerrain homed on `neighbour_fid`, parented under a Node3D carrying that facet's REAL
## orthonormal placement transform (det=+1), with its OWN VoxelMesherBlocky + OWN carve blob (the neighbour's
## ridge planes) but the SAME shared baked library. Served by the same single global VoxelViewer (attach_viewer).
## Returns {terrain, parent, mesher, generator, carve_enabled} or {} if unavailable. This proves godot_voxel
## streams+meshes under a rigid rotation (the falsified "cannot be rotated" constraint).
func spike_rotated_neighbour(neighbour_fid: int, view_blocks: int = 96) -> Dictionary:
	if not CubeSphere.FP_R0 or _library == null or not ClassDB.class_exists("VoxelTerrain"):
		return {}
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if mesher == null:
		return {}
	if mesher.has_method("set_library"):
		mesher.call("set_library", _library)
	else:
		_set_if(mesher, "library", _library)
	# The neighbour's OWN-side ridge planes into ITS OWN mesher carve blob (patch 0004, per-mesher). Guarded:
	# an unpatched binary lacks set_facet_carve → the sentinels bake as plain cubes (full-cube lip, never a hole).
	var carve_enabled := false
	if mesher.has_method("set_facet_carve"):
		if _carve_count > 0 and neighbour_fid >= 0:
			mesher.call("set_facet_carve", {
				"enabled": true,
				"planes": FacetAtlas.seam_planes_f64(neighbour_fid),
				"arid_base": _carve_base,
				"arid_count": _carve_count,
			})
			carve_enabled = true
		else:
			mesher.call("set_facet_carve", {"enabled": false})
	# OWN generator frozen on the NEIGHBOUR facet (the worker reads this immutable gen_facet, never _active_facet).
	var generator: Object = _make_generator(neighbour_fid)
	if generator == null:
		return {}
	var terrain := ClassDB.instantiate("VoxelTerrain") as Node3D
	if terrain == null:
		return {}
	_set_if(terrain, "mesher", mesher)
	_set_if(terrain, "generator", generator)
	_set_if(terrain, "max_view_distance", view_blocks)
	_set_if(terrain, "mesh_block_size", 32)
	_set_if(terrain, "generate_collisions", false)
	# The rotated parent: FacetAtlas.facet_transform(neighbour) is orthonormal det=+1 (verify_frame asserts it).
	# The terrain streams an axis-aligned box in ITS OWN lattice; the parent rigidly rotates the rendered mesh
	# blocks (§3.1). module_world sits at ZERO in faceted mode, so parent.global == facet_transform(neighbour).
	var parent := Node3D.new()
	parent.transform = FacetAtlas.facet_transform(neighbour_fid)
	parent.add_child(terrain)
	add_child(parent)
	return {
		"terrain": terrain, "parent": parent, "mesher": mesher,
		"generator": generator, "carve_enabled": carve_enabled,
	}

## FP-R0 SPIKE (live-scene wiring): plant a STATIC VoxelViewer at a fixed WORLD point so a spiked neighbour
## streams+meshes its OWN surface band regardless of where the player stands (the player's single global viewer
## localises ~edge/2 beyond a neighbour's ridge, out of a 96-block reach — the gate placed a dedicated viewer for
## exactly this reason). module_world sits at zero in faceted mode, so `world_pos` is also this node's local pos.
## Returns the viewer node (or null). No-op unless FP_R0 — the shipped build never plants extra viewers.
func spike_static_viewer(world_pos: Vector3, view_blocks: int = 96) -> Node:
	if not CubeSphere.FP_R0 or not ClassDB.class_exists("VoxelViewer"):
		return null
	var v: Node = ClassDB.instantiate("VoxelViewer")
	if v == null:
		return null
	_set_if(v, "view_distance", view_blocks)
	_set_if(v, "view_distance_vertical_ratio", TerrainConfig.VIEWER_VERTICAL_RATIO)
	_set_if(v, "requires_collisions", false)
	add_child(v)
	(v as Node3D).position = world_pos
	return v

## The shared baked VoxelBlockyLibrary (FP-R0: for a standalone build_mesh probe and neighbour meshers).
func spike_library() -> Object:
	return _library if CubeSphere.FP_R0 else null

## A LOD-probe generator frozen on `facet_fid` with lod>0 stride sampling enabled (FP-R0 §B). NOT wired to any
## terrain — the caller drives it directly via generate_block(buffer, origin, lod) + a mesher's build_mesh.
func spike_lod_generator(facet_fid: int) -> Object:
	return _make_generator(facet_fid, true) if CubeSphere.FP_R0 else null

## The active-facet generator (FP-R0: to prove the neighbour field differs from the active field).
func spike_active_generator() -> Object:
	return _generator if CubeSphere.FP_R0 else null

## The contiguous carve-sentinel ARID range [base, base+count) (FP-R0 diagnostics).
func spike_carve_range() -> Vector2i:
	return Vector2i(_carve_base, _carve_count) if CubeSphere.FP_R0 else Vector2i.ZERO

# ========================== end FP-R0 SPIKE ==========================

# ========================== FP-M2 LOD build hookup (docs/COSMOS-FP-M2-DESIGN.md §4.1, §13) ==========================
# Productized access to the probe recipe FP-R0 proved, for FacetLodBuilder / FacetLodMesher. Gated on FP_M2_LOD
# (NOT FP_R0) so with the flag off these return null and the whole LOD path is dead code. The builder thread
# reads the returned frozen generator ONLY (never a mutable global) — the frozen-epoch discipline, §4.3.

## The shared baked VoxelBlockyLibrary — the builder's own VoxelMesherBlocky shares it for build_mesh.
func lod_library() -> Object:
	return _library if CubeSphere.FP_M2_LOD else null

## A per-facet frozen probe generator (lod>0 stride enabled) homed on `fid`. Built on the MAIN thread (compiles
## the generator source + freezes the appearance tables); handed to the builder thread which only calls
## generate_block(buffer, origin, ℓ) on it. At ℓ0 stride==1 → byte-identical to the shipped generator (G-M2-ID).
func lod_probe_generator(fid: int) -> Object:
	return _make_generator(fid, true) if CubeSphere.FP_M2_LOD else null

## The SHIPPED active-facet generator (lod>0 early-out, no stride) — the byte-identity reference for G-M2-ID
## (probe-stride generator at ℓ0 must equal this voxel-for-voxel). null with the flag off.
func lod_shipped_generator() -> Object:
	return _generator if CubeSphere.FP_M2_LOD else null

## The active-facet VoxelTerrain — the gate samples its statistics to prove a pure-LOD build leaves the voxel
## worker pool's task counts untouched (G-M2-BUILD; the builder never touches any terrain). null with the flag off.
func lod_active_terrain() -> Node3D:
	return _terrain if CubeSphere.FP_M2_LOD else null

# ========================== end FP-M2 LOD build hookup ==========================

## Drop the streamed near region and rebuild it with a FRESH generator snapshot (frozen on the current
## _gen_face). This is the module restream the home-face flip (and M4) needs — previously ONLY the
## GDScript fallback had one, so a module flip left stale face-A meshes standing (COSMOS-AUDIT F3).
## Recreating the VoxelTerrain node guarantees old-epoch blocks are gone and the new generator is used.
## The player's global VoxelViewer keeps streaming the new terrain (viewers are engine-global). A no-op
## if the module is unavailable.
func restream(old_wrapper_pos: Vector3 = Vector3.INF) -> void:
	if not ClassDB.class_exists("VoxelTerrain") or _mesher == null:
		return
	var generator: Object = _make_generator()
	if generator == null:
		return
	# COSMOS M4 Stage 2 (§5.2): free any prior frozen cover FIRST so a flip storm never stacks covers — the
	# single-cover invariant (≤ 1 frozen + 1 live volume ever). No-op in the default state (no cover exists).
	_free_cover("superseded")
	var old_terrain := _terrain
	var new_terrain := ClassDB.instantiate("VoxelTerrain") as Node3D
	if new_terrain == null:
		return
	_set_if(new_terrain, "mesher", _mesher)
	_set_if(new_terrain, "generator", generator)
	# Stage 4: start small and ramp up in _process (below) instead of flooding the full disk at once.
	_set_if(new_terrain, "max_view_distance", int(RAMP_START_BLOCKS))
	_set_if(new_terrain, "mesh_block_size", 32)
	_set_if(new_terrain, "generate_collisions", false)
	if old_terrain != null:
		# Capture the old terrain's LOCAL offset BEFORE any cover compensation, so the FRESH terrain inherits
		# the module's coordinate offset — not the pinned cover's compensated position (§3.2).
		var base_pos: Vector3 = old_terrain.position
		new_terrain.position = base_pos
		# COSMOS M4 Stage 2 (§3.2/§3.3): flag ON and a real old frame supplied → keep the old terrain in place
		# as a frozen cover: pin its world transform at the OLD spot, THEN disable processing (order matters —
		# the transform notification applies immediately, independent of process mode). Else free it right away
		# (the shipped default — byte-for-byte today's teardown). ONLY this flag test picks cover-vs-free.
		if cover_enabled and old_wrapper_pos.is_finite() and old_wrapper_pos != position:
			_cover_terrain = old_terrain
			_cover_age = 0.0
			_cover_released = false
			old_terrain.position += old_wrapper_pos - position   # pin at the old WORLD spot (§3.2) …
			old_terrain.process_mode = Node.PROCESS_MODE_DISABLED  # … THEN freeze (§3.3)
		else:
			remove_child(old_terrain)
			old_terrain.queue_free()
	add_child(new_terrain)
	_terrain = new_terrain
	_generator = generator
	# Kick off the view-distance ramp so the near field fills in over ~RAMP_SECONDS rather than in one
	# freezing pass. If the target is already within the start radius (never, at radius 128/256) it is a
	# no-op. FLAT_WORLD only reaches restream() via a flip, which never fires without a chart — so flat
	# play never ramps and stays byte-identical.
	_ramp_target = float(TerrainConfig.near_render_radius())
	_ramp_view = RAMP_START_BLOCKS
	_ramp_active = _ramp_target > RAMP_START_BLOCKS
	# Keep processing while the ramp runs OR a frozen cover is aging toward retirement (§5.1).
	set_process(_ramp_active or _cover_terrain != null)

## Whether the OOB fence has clamped a stale/unbaked ARID this session (COSMOS-AUDIT F8 telemetry — a
## real out-of-range must never pass silently). Verify asserts this stays false over a clean run.
func oob_seen() -> bool:
	return _generator != null and bool(_generator.get("oob_seen"))

## The generator's frozen home face (COSMOS-AUDIT §3.2 item 3) — for verify / the dual-window handoff.
func gen_home_face() -> int:
	return _gen_face

## COSMOS M4 (§8 step 3): has the post-restream view-distance ramp finished? WorldManager polls this to
## learn when the fresh near field's data blocks are loaded, so it can re-mirror player edits into the
## render (§5.4) and end the far handoff turbo. Read-only; _ramp_active is false in steady state, so this
## returns true whenever no restream ramp is in flight.
func ramp_done() -> bool:
	return not _ramp_active

## Build a VoxelBlockyModelMesh for `modifier` from the shared ShapeMesh geometry (the
## one render seam — SVS §4). Returns null when the module lacks the mesh-model class.
##
## COSMOS-ATLAS Stage 2 (§2.4): with a valid `atlas_cell` (and the atlas live) the model rides the ONE shared atlas
## material and its ArrayMesh carries UVs remapped into that cell (per-(cell,modifier) cache), so the mesher MERGES it
## into the block's single opaque surface. Without a cell (flag off / a non-atlassed material) it takes the shipped
## path verbatim: the cross-material shared `_shape_mesh_cache[modifier]` geometry + the caller's per-id material.
func _make_shape_model(modifier: int, material: Material, atlas_cell := Vector2i(-1, -1)) -> Object:
	if not ClassDB.class_exists("VoxelBlockyModelMesh"):
		return null
	var model: Object = ClassDB.instantiate("VoxelBlockyModelMesh")
	if model == null:
		return null
	var use_atlas := atlas_cell.x >= 0 and _atlas != null
	var amesh: ArrayMesh
	if use_atlas:
		amesh = _atlas_shape_mesh(modifier, atlas_cell)
	else:
		# Share one ArrayMesh per shape across all materials (see _shape_mesh_cache).
		amesh = _shape_mesh_cache.get(modifier, null)
		if amesh == null:
			amesh = ArrayMesh.new()
			_add_surface(amesh, ShapeMesh.build(modifier))
			_shape_mesh_cache[modifier] = amesh
	if model.has_method("set_mesh"):
		model.call("set_mesh", amesh)
	else:
		_set_if(model, "mesh", amesh)
	if model.has_method("set_material_override"):
		model.call("set_material_override", 0, _atlas.material if use_atlas else material)
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

## Approx resident CPU vertex+index MB of a {key -> ArrayMesh} cache (NEVER-OOM ledger, verify/telemetry only).
func _mesh_cache_mb(cache: Dictionary) -> float:
	var bytes := 0
	for k: Variant in cache.keys():
		var am: ArrayMesh = cache[k]
		for s in am.get_surface_count():
			var a := am.surface_get_arrays(s)
			bytes += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * (12 + 12 + 8)   # pos+normal+uv
			bytes += (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() * 4
	return float(bytes) / 1048576.0

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
	_set_if(_viewer, "view_distance", TerrainConfig.near_render_radius())
	# A2 UNDERGROUND DOWNWARD-REACH CLAMP. VoxelViewer has NO asymmetric up/down extent — only a single
	# view_distance_vertical_ratio, a SYMMETRIC world-Y ellipsoid centred on the viewer node. To keep the
	# full UPWARD reach (mountains) while trimming the DOWNWARD reach to a modest band, offset the viewer
	# +Y and shrink the ratio (TerrainConfig helpers): on the composite-identity active facet world +Y =
	# radial up = the player's local up (the body only yaws), so a (0, O, 0) LOCAL offset is a pure radial
	# +O in world. FACETED-gated + toggle-gated so the FLAT world keeps its byte-identical symmetric slab.
	var use_clamp := CubeSphere.FACETED and TerrainConfig.DOWNWARD_REACH_CLAMP_ENABLED
	if use_clamp:
		_set_if(_viewer, "view_distance_vertical_ratio", TerrainConfig.clamped_viewer_vertical_ratio())
	else:
		# Un-clamped vertical stream ratio (byte-identical to the pre-A2 viewer).
		_set_if(_viewer, "view_distance_vertical_ratio", TerrainConfig.VIEWER_VERTICAL_RATIO)
	_set_if(_viewer, "requires_collisions", false)
	player.add_child(_viewer)
	if use_clamp:
		# LOCAL offset (child of the player) → radial +O on the active facet; unaffected by yaw.
		(_viewer as Node3D).position = Vector3(0.0, TerrainConfig.clamped_viewer_offset_y(), 0.0)

## True once every mesh block intersecting the axis-aligned box of half-extents `half` around world
## point `center` has been MESHED (its surface applied to the scene, so it renders next frame). Used by
## ShaderPrewarm's PHASE 2 to hold the "Loading…" overlay until the near view has actually drawn —
## letting the module's VoxelMesherBlocky pipeline compile hidden. Returns false if the module lacks
## is_area_meshed (older build → prewarm falls back to its timeout).
func area_meshed(center: Vector3, half: Vector3) -> bool:
	if _terrain == null or not _terrain.has_method("is_area_meshed"):
		return false
	return bool(_terrain.call("is_area_meshed", AABB(center - half, half * 2.0)))

## COSMOS M4 Stage 2 (§5.1): has the FRESH near field meshed under the player? Unlike area_meshed() (whose
## raw-world centre is a FLAT-only convention where the wrapper sits at the origin), the curved wrapper sits
## at a non-zero position, so convert the viewer's WORLD point into the new terrain's local voxel frame
## (viewer.global − wrapper.global) before the is_area_meshed box. Returns false (never retire on "meshed",
## fall through to the timeout cap) when there is no viewer/terrain or the module lacks is_area_meshed.
func _new_field_meshed() -> bool:
	var v := _viewer as Node3D
	if _terrain == null or v == null or not _terrain.has_method("is_area_meshed"):
		return false
	# FP-FIXED-FRAME (§4/§1.6 audit): the `viewer.global − node.global` translation-only shortcut assumes the active
	# terrain sits composite-identity (no rotation) under module_world. Under the fixed frame the active slot sits at
	# its true rotated T_active, so map the viewer world point through the terrain's real frame with to_local(). Off ⇒
	# the shortcut is exact (module_world @ 0, composite identity) → byte-identical. (Pool-path only reaches here in the
	# never-taken FP-S1 fallback, but the audit keeps it frame-correct regardless.)
	var center: Vector3 = (_terrain as Node3D).to_local(v.global_position) if _fixed_frame_on() \
		else v.global_position - global_position
	var half := NEAR_COVER_MESHED_HALF
	return bool(_terrain.call("is_area_meshed", AABB(center - half, half * 2.0)))

## COSMOS M4 Stage 2: free the frozen near cover (null-safe) and print one retirement telemetry line (§9.3
## watches these). The cover is a child of the wrapper, so queue_free drops its ~+50 MB static transient.
func _free_cover(reason: String) -> void:
	if _cover_terrain == null:
		return
	if is_instance_valid(_cover_terrain):
		remove_child(_cover_terrain)
		_cover_terrain.queue_free()
	print("[module_world] near cover retired (%s) after %.1fs" % [reason, _cover_age])
	_cover_terrain = null
	_cover_age = 0.0
	_cover_released = false

## COSMOS M4 Stage 2: true while a frozen near cover is bridging a flip (verify / diagnostics).
func cover_active() -> bool:
	return _cover_terrain != null

## COSMOS M4 Stage 2 (§5.1): WorldManager's handshake — the fresh terrain has ramped and player edits are
## re-mirrored, so the cover may retire as soon as the new field meshes under the player. No-op with no cover.
func release_cover() -> void:
	_cover_released = true

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
		# COSMOS-ATLAS Stage 1: an OPAQUE cube with an atlas cell renders on the SHARED atlas material + a per-face
		# tile pointing at its cell, so the mesher merges all opaque cubes in a block into one surface. Non-opaque
		# (translucent/emissive/fluid) ids have no cell (has_cell false) ⇒ per-id material path, unchanged (Stage 2+).
		var use_atlas: bool = _atlas != null and bool(_atlas.has_cell(block_id))
		var cube_mat: Material = _atlas.material if use_atlas else BlockMaterials.get_for(block_id)
		var atlas_cell: Vector2i = _atlas.cell_of(block_id) if use_atlas else Vector2i(-1, -1)
		if _waterlog_enabled and lk != CellCodec.LIQ_NONE and _fluids[lk] != null:
			# A liquid LRID renders as a PURE FLUID model (WATERLOGGING §4.2 / MULTI-LIQUID §2.2.2),
			# not a cube — so deep liquid culls internally and every cell of that kind shares its one
			# fluid_index. Falls back to a cube if the fluid model can't be built, preserving the
			# index==LRID invariant either way. (Liquids are never opaque, so use_atlas is false here.)
			var fluid_model: Object = _make_fluid_model(block_id, lk)
			got = _add_model(library, fluid_model) if fluid_model != null else _add_cube(library, cube_mat, cull_group, atlas_cell)
		else:
			got = _add_cube(library, cube_mat, cull_group, atlas_cell)
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
func _add_cube(library: Object, material: Material, cull_group: int = 0, atlas_cell := Vector2i(-1, -1)) -> int:
	var cube: Object = ClassDB.instantiate("VoxelBlockyModelCube")
	if cube == null:
		return -1
	# COSMOS-ATLAS Stage 1: with a valid atlas cell (col,row >= 0) the model uses the LIBRARY-WIDE atlas grid and
	# points every face at THIS id's cell — so the shared atlas `material` samples the id's tile and the mesher
	# merges all opaque cubes into one surface. Without a cell (the shipped path / non-opaque ids) it keeps the 1×1
	# per-model atlas: the default atlas_size_in_tiles is (0,0) → DEGENERATE UVs (every face samples one texel → a
	# flat solid colour); a 1×1 atlas gives 0..1 UVs so the whole per-model texture shows per face.
	var use_atlas := atlas_cell.x >= 0 and _atlas != null
	if cube.has_method("set_atlas_size_in_tiles"):
		cube.call("set_atlas_size_in_tiles", _atlas.grid if use_atlas else Vector2i(1, 1))
	if cube.has_method("set_tile"):
		for side in 6:  # VoxelBlockyModel.SIDE_* : 0..5 (all cube faces)
			cube.call("set_tile", side, atlas_cell if use_atlas else Vector2i(0, 0))
	if cube.has_method("set_material_override"):
		# A valid atlas cell ALWAYS means the shared atlas material (the tile samples the atlas). Stage-1 callers
		# already pass _atlas.material; Stage-2 snow-cap-cube callers pass the per-id snow material — force it here so
		# the tile+material agree (else the face would sample the atlas cell through the wrong per-id texture / not merge).
		cube.call("set_material_override", 0, _atlas.material if use_atlas else material)
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
## `facet_override` (>= -1) freezes the epoch on a SPECIFIC facet instead of TerrainConfig.active_facet() —
## the FP-R0 spike uses it to home a neighbour terrain's generator on a neighbour facet without mutating the
## global active facet (the frozen-epoch discipline: the worker reads the frozen gen_facet, never a mutable
## global). `lod_probe` publishes gen_lod_probe=true so lod>0 strides instead of early-returning (FP-R0 §B);
## default false keeps the shipped generator's lod!=0 early-out — and at lod0 the stride is 1, byte-identical.
func _make_generator(facet_override := -999, lod_probe := false) -> Object:
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
var carve_arid: PackedInt32Array        # COSMOS FP-CARVE: mat -> carve-sentinel cube ARID; -1 = not baked
var carve_snow_arid: PackedInt32Array   # COSMOS FP-CARVE: mat -> snow-capped carve-sentinel cube ARID; -1 = not baked
var snow_slope_arid: PackedInt32Array   # (mat*SLOPE_STRIDE + payload) -> snow-capped slope ARID; -1 = not baked
var waterlog := false                   # native waterlogging on → submerged composites route to twins
var model_count := 0                     # actual baked library model count — the OOB fence upper bound (VDS §8.1)
# COSMOS frozen-epoch (COSMOS-AUDIT §3.2 items 2–3): the IMMUTABLE home face + face-edge cell count this
# generator epoch is homed on, set once by the loader before this generator runs. The worker folds each
# column with `gen_face` (NEVER the mutable TerrainConfig._active_face), so home-face flips can never
# race generation — a flip installs a NEW generator with a new gen_face and restreams (module_world).
var gen_face := 0
var gen_n := 0
# COSMOS FACETED (docs/COSMOS-FACETED-IMPL.md §3.3): the IMMUTABLE facet this generator epoch is homed on
# (−1 = non-faceted / cube-lattice). Frozen by the loader from TerrainConfig.active_facet(), symmetric with
# gen_face — the worker threads it through GenCtx.facet so column_profile samples the sphere terrain at this
# facet's directions (NEVER the mutable TerrainConfig._active_facet). A facet change installs a new generator.
var gen_facet := -1
# COSMOS-FRAME-ORIENTATION §5.1: this epoch's FROZEN window orientation M_win (row-major ints). The worker
# recovers the raw index p = M_win·v from the terrain-local voxel index v before folding. Identity at spawn.
var gen_mwin_a := 1
var gen_mwin_b := 0
var gen_mwin_c := 0
var gen_mwin_d := 1
var flat_world := true                   # CubeSphere.FLAT_WORLD snapshot: flat → no fold (byte-identical)
var gen_lod_probe := false               # FP-R0 §B: when true, lod>0 samples at stride 2^lod (else early-out). Default false → shipped path unchanged; at lod0 stride==1 so byte-identical.
# GEN-EFFICIENCY Fix A (docs/COSMOS-GEN-EFFICIENCY-DESIGN.md §1): FP_BULK_UNDERGROUND snapshot + the two fill
# ARIDs a plain deep STONE / DEEPSLATE cube writes (frozen by the loader from the baked cube_arid table). When
# fp_bulk and a block is provably interior stone/deepslate, the worker VoxelBuffer.fill()s it with one of these
# instead of the per-cell pass — the SAME cube ARID a non-ore/non-strata deep cell would emit (byte-matching an
# exposed non-ore wall). -1 = not baked → the block falls back to per-cell (never fills a stale index).
var fp_bulk := false
var bulk_stone_arid := -1
var bulk_deepslate_arid := -1
# STREAM-SCHED R1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.3 / §9.2): CubeSphere.FP_COLBULK's snapshot — the
# column-granular twin of fp_bulk. Reuses the SAME two frozen fill ARIDs (a column's deep run writes exactly
# the cube a whole-block fill would), so it needs no extra table. Frozen by the loader, read-only on workers.
var fp_colbulk := false
# STREAM-SCHED R7 (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.5 / §9.6): CubeSphere.FP_STAMP's snapshot — the
# scatter pass that puts the strata/ore variants back into fp_colbulk's deep fill runs, making the column
# bulk fill BYTE-IDENTICAL to the per-cell path instead of an accepted appearance loss. Meaningless without
# fp_colbulk (it stamps exactly the cells fp_colbulk's fill_area runs wrote) → the emit gate ANDs the two.
var fp_stamp := false
# STREAM-SCHED T1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §7 row T1 / §9.1) — the per-class generation timer. §2.3's
# supply model rests on an ASSUMED block-class mix (30% air/cheap, 25% bulk-qualified, 25% gate-failed, 20%
# surface); the doc itself names that its soft spot. These count blocks + accumulate usec per class so the mix is
# MEASURED before R1 is judged. Classes: 0 = air / cheap early-out, 1 = whole-block bulk fill
# (FP_BULK_UNDERGROUND), 2 = underground per-cell (the min_h-gate-FAILED class R1 targets), 3 = surface-crossing
# per-cell.
#
# THREADING (read this before "fixing" it): several voxel workers share ONE generator instance, so these `+= `
# are racing read-modify-writes and WILL lose updates under contention. That is deliberate and bounded:
#   • they are plain ints (never Packed*Array) — a Variant int store is a word write with no refcount, so the
#     race costs LOST UPDATES only, never corruption. A Packed*Array member would be far worse here: a
#     main-thread read bumps its refcount and the next worker write silently CoW-detaches the buffer.
#   • no lock, ever: this is the hot path R1 exists to shrink; a mutex here would measure the mutex.
# ⇒ these are TELEMETRY-GRADE (undercounts under load, monotonic, ratios stable — mix shares are what T1 is for),
# NOT an accounting ledger. Same tolerated-race class as `oob_seen` below. Read via gen_stats().
var gen_ct_0 := 0
var gen_ct_1 := 0
var gen_ct_2 := 0
var gen_ct_3 := 0
var gen_us_0 := 0
var gen_us_1 := 0
var gen_us_2 := 0
var gen_us_3 := 0
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
# GEN-EFFICIENCY Fix A: the qualification constants, mirrored from TerrainConfig so the worker never reaches
# outside its frozen instance. BULK_MAX_FILLER = max _filler_depth over all biomes (badlands, 12): a block whose
# top cell sits deeper than this under EVERY column is interior stone (no dirt/biome-top skipped). The DEEPSLATE
# band bounds (TerrainConfig.DEEPSLATE_TOP_Y / _FULL_Y): above -16 is pure stone, below -24 is pure deepslate,
# -24..-16 is a dithered mix (fall back). BULK_BEDROCK_TOP_Y (TerrainConfig.BEDROCK_TOP_Y): no bedrock at y >= -59.
const BULK_MAX_FILLER := 12
const BULK_DEEPSLATE_TOP_Y := -16
const BULK_DEEPSLATE_FULL_Y := -24
const BULK_BEDROCK_TOP_Y := -59

func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_TYPE

## STREAM-SCHED T1: this generator epoch's per-class block counts + usec. Cumulative since the epoch was
## installed (a facet/face flip builds a FRESH generator → the counters restart at 0; the reader must treat a
## decrease as an epoch change, not as negative work). Telemetry-grade — see the gen_ct_* declaration.
func gen_stats() -> Dictionary:
	return {
		"ct": [gen_ct_0, gen_ct_1, gen_ct_2, gen_ct_3],
		"us": [gen_us_0, gen_us_1, gen_us_2, gen_us_3],
	}

## Add one block's elapsed usec into class `cls`. Racy by design (see gen_ct_* above).
func _gen_acc(cls: int, t0: int) -> void:
	var d = Time.get_ticks_usec() - t0
	match cls:
		0:
			gen_ct_0 += 1
			gen_us_0 += d
		1:
			gen_ct_1 += 1
			gen_us_1 += d
		2:
			gen_ct_2 += 1
			gen_us_2 += d
		_:
			gen_ct_3 += 1
			gen_us_3 += d

func _generate_block(buffer, origin_in_voxels, lod):
	# FP-R0 §B stride: shipped path early-outs on lod!=0 (gen_lod_probe=false). The probe generator strides the
	# LOD0 sampling by s=2^lod so a coarse buffer cell (x,y,z) reads LOD0 voxel (ox+x*s, oy+y*s, oz+z*s). At
	# lod0 s==1 so every `*s` below is a no-op → byte-identical to the shipped generator (gated by verify_fp_r0).
	var s = 1
	if lod != 0:
		if not gen_lod_probe:
			return
		s = 1 << lod
	# STREAM-SCHED T1 (§9.1): start the per-class timer AFTER the lod early-out (that return is not a block
	# generation at all, it is the shipped "this generator only serves lod0" contract — counting it would
	# dilute the mix with zero-cost no-ops). Every return below routes through _gen_acc exactly once.
	var _t0 = Time.get_ticks_usec()
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
	var ncarve = carve_arid.size()
	var ncarvesnow = carve_snow_arid.size()
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
	# COSMOS FS2 (docs/COSMOS-FACET-SEAMS-DESIGN.md §3): the per-column datum re-index is active on this facet.
	# The surface rises by up to DATUM_SHIFT_MAX, so the y-envelope bounds gain that headroom; and the bulk/colbulk/
	# stamp optimisations (which assume the surface is at true g) are FORCED OFF so the plain per-cell path — the one
	# the C++ generator mirrors — runs and resolves each cell at true y − S. _rd false ⇒ every branch below is the
	# shipped code verbatim (byte-identical when FP_RADIAL_DATUM is off / non-faceted).
	var _rd := CubeSphere.FP_RADIAL_DATUM and gen_facet >= 0
	var _ds_head := FacetAtlas.DATUM_SHIFT_MAX if _rd else 0
	if oy > TerrainConfig.MAX_SURFACE_Y + max_above + _ds_head and oy > sea:
		_gen_acc(0, _t0)                                  # T1 class 0: constant air early-out
		return
	if oy + size.y * s <= TerrainConfig.BEDROCK_FLOOR:
		_gen_acc(0, _t0)
		return
	# FP-S1(b) COSMOS FACETED (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §5(a)/§8) — BLOCK-level facet-domain
	# early-out, BEFORE the per-column profile pass. junction_modify() (the buffer-write exit below) masks every
	# beyond-ridge cell to AIR one at a time — but only AFTER this block pays the full column-profile + resolve_cell
	# work. On a facet the near box overlaps foreign territory, so whole blocks generate nothing but masked air.
	# block_all_air() is the exact per-cell mask's supremum over the block: true ONLY when a single ridge alone
	# masks every cell (never skips a block with any interior/straddle cell → identical voxels emitted, just faster).
	# Gated by gen_facet >= 0 (faceted only) → flat / non-faceted byte-identical. Frozen gen_facet → worker-safe.
	if gen_facet >= 0 and FacetAtlas.block_all_air(gen_facet, ox, oy, oz, size.x, size.y, size.z, s):
		_gen_acc(0, _t0)                                  # T1 class 0: beyond-ridge all-air early-out
		return

	# Per-column profile cache: Vector4(g, biome, c, t). Value type -> no per-cell
	# noise sampling and no allocation.
	var profs = []
	profs.resize(size.x * size.z)
	var max_h = -0x7fffffff
	var min_h = 0x7fffffff                   # GEN-EFFICIENCY Fix A: the shallowest surface over the block's columns
	                                         # (flat branch only) — bounds the Fix A "block fully below filler" gate.
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
	var rjinv # per-column render-frame J⁻¹ quarter-turn (COSMOS-FRAME-ORIENTATION §6)
	if flat_world:
		# FACETED (§3.3): a GenCtx carrying the FROZEN gen_facet so column_profile takes the faceted branch
		# and samples the sphere terrain at THIS facet's true cell directions — worker-safe (never reads the
		# mutable _active_facet). jinv stays 0 (no window rotation in flat/faceted), so it's the flat pipeline
		# with a facet-sourced profile. Non-faceted flat: the plain Dictionary memo, byte-identical to before.
		pcache = TerrainConfig.GenCtx.new(0, gen_facet) if gen_facet >= 0 else {}
		for z in range(size.z):
			for x in range(size.x):
				var p = TerrainConfig.column_profile(ox + x * s, oz + z * s, pcache)
				profs[z * size.x + x] = p
				if int(p.x) > max_h: max_h = int(p.x)
				if int(p.x) < min_h: min_h = int(p.x)
	else:
		pcache = TerrainConfig.GenCtx.new(gen_face)
		# COSMOS-FRAME-ORIENTATION §6: this epoch's M_win quarter-turn, once per block — worker_fold_column
		# folds each column and records J⁻¹ = −(strip_d4 + gen_mwin_d4) so resolve_cell rotates the shape.
		var gen_mwin_d4 = CubeSphere.d4_of([gen_mwin_a, gen_mwin_b, gen_mwin_c, gen_mwin_d])
		rxs = PackedInt32Array(); rxs.resize(size.x * size.z)
		rzs = PackedInt32Array(); rzs.resize(size.x * size.z)
		rfs = PackedInt32Array(); rfs.resize(size.x * size.z)
		rjinv = PackedInt32Array(); rjinv.resize(size.x * size.z)   # §6: per-column J⁻¹ (worker_fold_column sets it)
		for z in range(size.z):
			for x in range(size.x):
				var idx = z * size.x + x
				# COSMOS-FRAME-ORIENTATION §5.1: recover the raw home-face index p = gen_mwin·v from the
				# terrain-local voxel index v = (ox+x, oz+z). Identity M_win → (ox+x, oz+z), byte-identical.
				var vx = ox + x
				var vz = oz + z
				var pi = gen_mwin_a * vx + gen_mwin_b * vz
				var pj = gen_mwin_c * vx + gen_mwin_d * vz
				# Fold (gen_face, raw column) → true global column ONCE; sets pcache.face + jinv_d4.
				var tc = TerrainConfig.worker_fold_column(gen_face, pi, pj, pcache, gen_mwin_d4)
				rfs[idx] = tc.x; rxs[idx] = tc.y; rzs[idx] = tc.z; rjinv[idx] = pcache.jinv_d4
				var p = TerrainConfig.column_profile(tc.y, tc.z, pcache)
				profs[idx] = p
				if int(p.x) > max_h: max_h = int(p.x)

	# GEN-EFFICIENCY Fix A (docs/COSMOS-GEN-EFFICIENCY-DESIGN.md §1) — bulk-fill a provably-interior underground
	# block with ONE material via VoxelBuffer.fill() instead of the per-cell resolve_cell pass (~27× on that
	# block; the 4096 resolve_cell calls + the slope_run pass are skipped). Qualifies (LOD0 flat branch only) when:
	#   • the block's TOP cell is deeper than the max biome filler under EVERY column
	#     (oy+size.y <= min_h - BULK_MAX_FILLER) → _surface_rule returns STONE for all cells, no dirt/biome-top or
	#     surface cell is ever inside the block (this is ALSO the no-fall-through guarantee: the walkable surface is
	#     never bulk-filled), and
	#   • exactly ONE fill material is well-defined: the whole block is strictly ABOVE the -24..-16 deepslate dither
	#     band (oy > -16 → pure STONE) OR strictly BELOW it and clear of bedrock (oy+size.y <= -24 and oy >= -59 →
	#     pure DEEPSLATE). Blocks straddling the dither band, the dirt layer, or bedrock fall back to per-cell.
	# resolve_cell for such a cell is a full STONE/DEEPSLATE cube (modifier 0, lf 0) → the fill writes the SAME cube
	# ARID a per-cell non-ore/non-strata cell would (an exposed non-ore wall matches byte-for-byte); the block's
	# ore/strata VARIANTS are the accepted appearance loss (physics + the broken/dropped block read block_id_at →
	# resolve_cell directly, never this buffer). FACETED: gated on the WHOLE block box being interior to all four
	# ridges (cell_interior_scaled over [ox..ox+size]) so no beyond-ridge cell that junction_modify masks to AIR is
	# wrongly filled — a straddling/edge block falls back to per-cell. Flag OFF → this is skipped entirely → the
	# generator is byte-identical per-cell (FLAT 6035/0; G-M2-ID compares two module generators that share the
	# const flag, so both bulk-fill identically → still equal).
	if fp_bulk and not _rd and s == 1 and flat_world and size.x == size.y and size.y == size.z:
		var by_top = oy + size.y                      # one past the top cell (cells are oy .. by_top-1)
		if by_top <= min_h - BULK_MAX_FILLER:
			var fill_arid := -1
			if oy > BULK_DEEPSLATE_TOP_Y:                                  # whole block above the dither band → STONE
				fill_arid = bulk_stone_arid
			elif by_top <= BULK_DEEPSLATE_FULL_Y and oy >= BULK_BEDROCK_TOP_Y:  # below -24, above bedrock → DEEPSLATE
				fill_arid = bulk_deepslate_arid
			if fill_arid >= 0 and fill_arid < mcount:
				var interior := true
				if gen_facet >= 0:
					interior = FacetAtlas.cell_interior_scaled(gen_facet, ox, oy, oz, size.x)
				if interior:
					buffer.fill(fill_arid, ch)
					_gen_acc(1, _t0)                      # T1 class 1: whole-block bulk fill
					return

	# Whole block above every surface + tree cap AND above the sea cap -> all air
	# (leave buffer default 0). The sea term matters over deep ocean, where the
	# solid top is far below SEA_LEVEL but water still fills up to it.
	var top = max_h + max_above + _ds_head               # FS2: +S headroom (the surface rises by ≤ DATUM_SHIFT_MAX)
	if sea > top: top = sea
	if oy > top:
		_gen_acc(0, _t0)                                  # T1 class 0: profiled all-air block
		return

	# STREAM-SCHED R1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.3 / §9.2) — FP_COLBULK: the block-level hoist.
	# Everything that is constant over the block is decided ONCE here; the per-column work is in the emit loop.
	# Preconditions mirror the whole-block fill above (LOD0, flat branch, cubic block) plus the OOB fence: a
	# fill_area write bypasses the per-cell fence, so BOTH fill ARIDs must be baked and in range or the whole
	# optimisation stays off (never fill a stale index). FACETED: v1 requires the WHOLE block box to be interior
	# to all four ridges — exactly the whole-block fill's gate — so no beyond-ridge cell that junction_modify
	# would mask to AIR is ever filled; ridge straddlers stay fully per-cell.
	var cb_on = fp_colbulk and not _rd and s == 1 and flat_world and size.x == size.y and size.y == size.z \
		and bulk_stone_arid >= 0 and bulk_stone_arid < mcount \
		and bulk_deepslate_arid >= 0 and bulk_deepslate_arid < mcount
	if cb_on and gen_facet >= 0:
		cb_on = FacetAtlas.cell_interior_scaled(gen_facet, ox, oy, oz, size.x)
	var cb_top = oy + size.y                              # one past the block's top cell (s == 1 whenever cb_on)
	# R1 NEIGHBOUR-AWARE DEEP BOUND — a 1-wide ring of column heights around the block (18×18 for a 16³).
	# Being deep is a property of CONTENT, but being INVISIBLE is a property of the NEIGHBOURHOOD: a cell 13
	# below its OWN g is still on a visible face if an adjacent column's surface drops below it. So the deep
	# bound is min(g over the 3×3) − BULK_MAX_FILLER, not the doc's per-column `g − 12` (§2.3/§9.2 specifies
	# the per-column form; it is unsound in the general case and this deviates deliberately). At y < min3x3(g)
	# − 12 every face-neighbour is >12 below its own surface, hence a FULL opaque cube (a SLOPE run reaches at
	# most 3 below g, so it can never carve that deep) ⇒ the cell has no visible face, by construction rather
	# than by luck. MEASURED on this terrain: max adjacent-column |Δg| is 1 near spawn and 3 across mountain
	# massifs, so this costs ≤3 cells of fill per column — but the bound no longer RESTS on that measurement.
	# The ring reads through the same per-block pcache memo, so the 256 in-block columns are memo hits and only
	# the ~68 ring columns sample noise. Built only when cb_on; worker-local (never shared).
	# STREAM-SCHED R7 (§2.5/§9.6) — FP_STAMP: record each column's deep-region top so the scatter pass below
	# knows EXACTLY which cells the fill runs wrote (dtop is PER-COLUMN: it depends on that column's 3×3 gmin).
	# The stamp must never touch a cell the per-cell path resolved — that cell is already exact, and a stamp
	# would overwrite it with a deep-only guess. Init to oy = "this column filled nothing"; the emit loop
	# overwrites it wherever cb_on computes a real dtop. NEVER-OOM ledger: ONE worker-local PackedInt32Array
	# of size.x*size.z (1 KiB for a 16³ block), allocated only when stamping is on, freed with the frame.
	# No cache, no cross-block retention, no growth with view distance.
	var stamp_on = cb_on and fp_stamp
	var cdtop: PackedInt32Array
	if stamp_on:
		cdtop = PackedInt32Array()
		cdtop.resize(size.x * size.z)
		cdtop.fill(oy)
	var gring: PackedInt32Array
	var grw = size.x + 2
	if cb_on:
		gring = PackedInt32Array()
		gring.resize(grw * (size.z + 2))
		for j in range(size.z + 2):
			for i in range(grw):
				gring[j * grw + i] = int(TerrainConfig.column_profile(ox + i - 1, oz + j - 1, pcache).x)

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
				wx = ox + x * s
				wz = oz + z * s
			else:
				# The TRUE global column this voxel column folds to; restore its face for the nested
				# smoothing/snow/tree stencil folds inside resolve_cell (COSMOS-AUDIT §3.2 items 2–3).
				wx = rxs[idx2]
				wz = rzs[idx2]
				pcache.face = rfs[idx2]
			# STREAM-SCHED R1/R1b (§2.3/§2.4, §9.2) — this column's three y-regions, when FP_COLBULK is on:
			#   deep run  [oy, min(cb_top, g − 12))  → fill_area stone (above −16) / deepslate (below −24);
			#                                          the −24..−16 dither rows and any row below −59 (where
			#                                          bedrock can hash in) are EXCLUDED and stay per-cell.
			#   exact band [g − 12, col_hi)          → the per-cell body below, verbatim and BYTE-EXACT.
			#   air        [col_hi, cb_top)          → skipped (R1b).
			# Why min3x3(g) − 12: _surface_rule returns STONE for depth > _filler_depth(biome), whose max over
			# all biomes is 12 (badlands). So every cell strictly below g − 12 is stone/deepslate/strata/ore —
			# the exact material class the whole-block fill already approximates, and the SAME accepted loss
			# (interior ore/strata variants). Cells at or above that can be filler/biome-top/cap/slope/snow/
			# tree/sea and are never guessed. Taking the MIN over the 3×3 additionally makes the cell provably
			# INVISIBLE (see the gring comment): content-deep is not the same claim as unseen, and only the
			# second one licenses guessing the cell.
			var col_hi = cb_top                       # one past the last cell this column must resolve
			var deep_top = -0x40000000                # cells with wy < deep_top are provably deep AND unseen
			if cb_on:
				var gmin = g
				for dz1 in range(-1, 2):
					for dx1 in range(-1, 2):
						var gn = gring[(z + 1 + dz1) * grw + (x + 1 + dx1)]
						if gn < gmin: gmin = gn
				deep_top = gmin - BULK_MAX_FILLER
				var dtop = mini(cb_top, deep_top)     # exclusive top of this column's deep region in the block
				if stamp_on:
					cdtop[idx2] = dtop                # R7: the scatter's per-column deep bound (see below)
				if dtop > oy:
					# Two runs at most; both are half-open [lo, hi) in WORLD y, written in BUFFER-local
					# coords. Stone: wy > −16. Deepslate: wy < −24 AND wy >= −59 (below −59 bedrock can
					# hash in per-cell, so those rows are left out of the run entirely).
					var s0 = maxi(oy, BULK_DEEPSLATE_TOP_Y + 1)
					if dtop > s0:
						buffer.fill_area(bulk_stone_arid, Vector3i(x, s0 - oy, z), Vector3i(x + 1, dtop - oy, z + 1), ch)
					var d0 = maxi(oy, BULK_BEDROCK_TOP_Y)
					var d1 = mini(dtop, BULK_DEEPSLATE_FULL_Y)
					if d1 > d0:
						buffer.fill_area(bulk_deepslate_arid, Vector3i(x, d0 - oy, z), Vector3i(x + 1, d1 - oy, z + 1), ch)
				# R1b, the per-column air ceiling. Everything resolve_cell can emit ABOVE a column's own g is
				# bounded by max_above over the columns that can REACH this one: the smoothing cap (own g+1),
				# the snow stack (own g + SNOW_FILL_MAX_CELLS), the SLOPE run (corner targets over the 3×3),
				# and a TREE canopy. The tree term is why this stencil is 5×5 and NOT the 3×3 the design doc
				# names: TreeGen.block_at consults the tree of (x,z)'s OWN G=10 grid cell, whose base column
				# is jittered anywhere in [gx·10+2, gx·10+7] — but a canopy has radius ≤ 2, so only a base
				# within ±2 columns can place a cell here, and that base's g is what the height is measured
				# from. A 3×3 max would therefore MISS a tall neighbour's overhang and silently clip canopy.
				# Maxed with SEA_LEVEL because an underwater column emits sea fill up to it regardless of g.
				# Interior columns only (the 5×5 must be inside profs[]); edge columns keep the full loop.
				if x >= 2 and x < size.x - 2 and z >= 2 and z < size.z - 2:
					var gmax = g
					for dz2 in range(-2, 3):
						for dx2 in range(-2, 3):
							var gg = int(profs[(z + dz2) * size.x + (x + dx2)].x)
							if gg > gmax: gmax = gg
					col_hi = mini(cb_top, maxi(gmax + max_above, sea) + 1)
			# S1 throughput hoist: the SLOPE run is column-invariant, so compute it ONCE here (worker-
			# direct pack, byte-identical to the analytic memo) and pass it into every resolve_cell of
			# this column — else resolve_cell re-runs the _corner_targets noise stencil + TreeGen.block_at
			# tree-gate on all ~100 sub-surface y's of a tall land column (the steady-state gen cost).
			# R1 (§9.2) makes it LAZY: a column whose every in-block cell was fill_area'd or skipped calls
			# resolve_cell zero times, so the noise stencil it feeds is pure waste. The three terms are the
			# three per-cell regions left: the exact band, the dither rows, and the bedrock rows.
			if cb_on:
				var dtop2 = mini(cb_top, deep_top)
				var need_cells = mini(cb_top, col_hi) > maxi(oy, deep_top) \
					or mini(dtop2, BULK_DEEPSLATE_TOP_Y + 1) > maxi(oy, BULK_DEEPSLATE_FULL_Y) \
					or mini(dtop2, BULK_BEDROCK_TOP_Y) > oy
				if not need_cells:
					continue
			var srun = TerrainConfig.slope_run_of(wx, wz, pcache)
			# COSMOS FS2 (design 3.2): this column's datum shift. resolve_cell runs in TRUE-height space at
			# wy - S, so the cell at lattice wy renders worldgen's true wy - S (the whole column raised by S).
			# cb_on is forced OFF under _rd, so the col_hi/deep-fill R1 branches never run with the datum shift.
			var col_ds := FacetAtlas.datum_shift(gen_facet, wx, wz) if _rd else 0
			var col_jinv = 0 if flat_world else rjinv[idx2]   # COSMOS-FRAME-ORIENTATION §6: this column's window J⁻¹
			for y in range(size.y):
				var wy = oy + y * s
				if cb_on:
					if wy >= col_hi:
						break                         # R1b: above this column's content ceiling — nothing but air
					if wy < deep_top and (wy > BULK_DEEPSLATE_TOP_Y \
							or (wy < BULK_DEEPSLATE_FULL_Y and wy >= BULK_BEDROCK_TOP_Y)):
						continue                      # R1: already emitted by this column's deep fill runs
				var v = TerrainConfig.resolve_cell(wx, wy - col_ds, wz, g, biome, cc, tt, pcache, srun)
				# §6: resolve_cell is CANONICAL; rotate the directional modifier into the WINDOW render frame at
				# this buffer-write exit by the column's frozen J⁻¹. No-op for full cubes / identity → byte-identical.
				if col_jinv != 0:
					var vmod = CellCodec.modifier(v)
					if vmod != 0:
						v = CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(vmod, col_jinv))
				# COSMOS FACETED §3.5.4/§5.3: the junction/mask authority at the module worker buffer-write exit
				# (mirrors WM.cell_value_at). Masks beyond-ridge cells to AIR (id==0 → skipped) and turns
				# straddling cells into kind-2 partials. Frozen gen_facet (never _active_facet) → worker-safe.
				# COSMOS FP-M2 §7.2: at ℓ>0 (s>1, the LOD probe path) a single sampled LOD0 cell cannot cut an s³
				# megablock, so junction sentinels are NOT emitted — instead the megablock is kept only if its whole
				# s-cube footprint is interior to all 4 ridges (conservative erosion), else AIR. At ℓ0 (s==1) the
				# shipped junction_modify runs verbatim → LOD0 byte-identical (G-M2-ID pins it).
				if gen_facet >= 0:
					if s == 1:
						v = FacetAtlas.junction_modify(gen_facet, Vector3i(wx, wy, wz), v)
					elif not FacetAtlas.cell_interior_scaled(gen_facet, wx, wy, wz, s):
						v = 0
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
				elif CellCodec.is_junction(modifier):
					# COSMOS FP-CARVE (patch 0004): a seam junction cell (produced by junction_modify) -> its
					# plain carve-SENTINEL cube; the compiled mesher clips it by the active facet's ridge planes.
					# The snow-capped variant when capped (bit 32). HOISTED to the FIRST lf==0 arm -- junction_modify
					# discards the original modifier, so snow-fill/slope/snow-cap never apply to a junction cell.
					# Unbaked / unpatched binary -> the full-cube lip (the mask already carved beyond-ridge cells to
					# AIR upstream, so this is never a hole).
					if ((v >> 32) & 1) != 0 and id < ncarvesnow and carve_snow_arid[id] >= 0:
						arid = carve_snow_arid[id]
					elif id < ncarve and carve_arid[id] >= 0:
						arid = carve_arid[id]
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

	# ---- STREAM-SCHED R7 (§2.5/§9.6) — FP_STAMP: the gather→scatter inversion --------------------------
	# The emit loop above fill_area'd every column's deep run with PLAIN stone/deepslate, which is the whole
	# of R1's appearance loss: the strata blobs and ore pockets that the per-cell path would have written
	# there are gone. Rather than ask each of 4096 cells "is a blob here?" (the gather, and the single
	# biggest term in the 11.9 ms per-cell pass), enumerate the blobs that can REACH this block and stamp
	# them. That is exact and LOCAL because a blob is confined to its own lattice cell:
	# TerrainConfig.strata_blob/ore_blob clamp the centre jitter so centre−r >= cell_lo and
	# centre+r <= cell_lo+L. Note the PLUS face touches cell_lo+L, which is the next lattice cell's first
	# cell — the sphere bleeds by exactly ONE cell in +x/+y/+z, and the gather truncates that bleed
	# implicitly (a query there derives the NEXT lattice cell and never consults this blob). So the scatter
	# clips every stamp to the blob's OWN lattice cell; that clip is not an optimisation, it is what makes
	# the scatter equal the gather. Byte-identity is otherwise structural: every blob parameter comes from
	# the same TerrainConfig statics both paths call, so the two cannot drift.
	#
	# The stamp writes ONLY cells the fill runs actually wrote (the `wy < cdtop and (above −16 or below −24
	# and >= −59)` test mirrors the emit loop's `continue` verbatim). Cells the per-cell path resolved are
	# already exact and are never touched; the −24..−16 dither rows and the sub-−59 bedrock rows were never
	# filled and are never stamped. Every stamped cell is a deep interior full cube (modifier 0, no liquid,
	# no state), so its ARID is cube_arid[id] — the same table the per-cell write site resolves it through,
	# behind the same OOB fence. flat_world + s == 1 + cubic block are cb_on preconditions, so there is no
	# folding, no J⁻¹ rotation (modifier 0) and no junction_modify (cb_on already proved the whole block
	# interior to all four ridges) to reproduce here.
	if stamp_on:
		var bx1 = ox + size.x - 1
		var by1 = oy + size.y - 1
		var bz1 = oz + size.z - 1
		# --- strata: 16³ lattice → 1-8 cells over a 16³ block ---
		var sl = TerrainConfig.strata_lattice()
		for lx in range(floori(ox / float(sl)), floori(bx1 / float(sl)) + 1):
			for ly in range(floori(oy / float(sl)), floori(by1 / float(sl)) + 1):
				for lz in range(floori(oz / float(sl)), floori(bz1 / float(sl)) + 1):
					var sb = TerrainConfig.strata_blob(lx, ly, lz)
					if sb.w == 0:
						continue
					var sr = sb.w
					# sphere bbox ∩ the blob's OWN lattice cell ∩ this block
					var sx0 = maxi(maxi(sb.x - sr, lx * sl), ox)
					var sx1 = mini(mini(sb.x + sr, lx * sl + sl - 1), bx1)
					var sy0 = maxi(maxi(sb.y - sr, ly * sl), oy)
					var sy1 = mini(mini(sb.y + sr, ly * sl + sl - 1), by1)
					var sz0 = maxi(maxi(sb.z - sr, lz * sl), oz)
					var sz1 = mini(mini(sb.z + sr, lz * sl + sl - 1), bz1)
					if sx0 > sx1 or sy0 > sy1 or sz0 > sz1:
						continue
					var svar = TerrainConfig.strata_variant_of(lx, ly, lz, sb.y)
					# The deepslate-region rule (TerrainConfig._deep_family): a variant replaces STONE, but in
					# the deepslate region deepslate stays dominant and only the sulfur/cinnabar pockets punch
					# through. Inside a fill run the base is decided by y ALONE (the dither band is excluded
					# from the runs), so a non-pocket variant simply cannot write below −24 — skip those rows
					# instead of testing every cell.
					var punches = TerrainConfig.deep_pocket_variant(svar)
					var sa = cube_arid[svar] if svar < ncube else svar
					if sa < 0 or sa >= mcount:
						continue                      # unbaked → leave the plain fill (never a stale index)
					for wy in range(sy0, sy1 + 1):
						if wy < BULK_DEEPSLATE_FULL_Y and not punches:
							continue                  # deepslate region, ordinary strata → deepslate wins
						var dy = wy - sb.y
						for wz in range(sz0, sz1 + 1):
							var dz = wz - sb.z
							var dyz = dy * dy + dz * dz
							if dyz > sr * sr:
								continue
							for wx in range(sx0, sx1 + 1):
								var dx = wx - sb.x
								if dx * dx + dyz > sr * sr:
									continue
								var ci = (wz - oz) * size.x + (wx - ox)
								if wy >= cdtop[ci]:
									continue          # per-cell territory — already exact
								if wy > BULK_DEEPSLATE_TOP_Y or (wy < BULK_DEEPSLATE_FULL_Y and wy >= BULK_BEDROCK_TOP_Y):
									buffer.set_voxel(sa, wx - ox, wy - oy, wz - oz, ch)
		# --- ore: 6³ lattice → up to 4³ cells over a 16³ block, ~45 % populated ---
		var ol = TerrainConfig.ore_lattice()
		for lx in range(floori(ox / float(ol)), floori(bx1 / float(ol)) + 1):
			for ly in range(floori(oy / float(ol)), floori(by1 / float(ol)) + 1):
				for lz in range(floori(oz / float(ol)), floori(bz1 / float(ol)) + 1):
					var ob = TerrainConfig.ore_blob(lx, ly, lz)
					if ob.w == 0:
						continue
					var orr = ob.w
					var ox0 = maxi(maxi(ob.x - orr, lx * ol), ox)
					var ox1 = mini(mini(ob.x + orr, lx * ol + ol - 1), bx1)
					var oy0 = maxi(maxi(ob.y - orr, ly * ol), oy)
					var oy1 = mini(mini(ob.y + orr, ly * ol + ol - 1), by1)
					var oz0 = maxi(maxi(ob.z - orr, lz * ol), oz)
					var oz1 = mini(mini(ob.z + orr, lz * ol + ol - 1), bz1)
					if ox0 > ox1 or oy0 > oy1 or oz0 > oz1:
						continue
					# Ore TYPE is per (blob, QUERY COLUMN): the weights read the column's biome/c (emerald
					# needs c > 0.4, badlands quadruples gold), so it is hoisted per column — never per blob
					# (a different world) and never per cell (the cost R7 exists to remove).
					for wz in range(oz0, oz1 + 1):
						var dz = wz - ob.z
						for wx in range(ox0, ox1 + 1):
							var dx = wx - ob.x
							var dxz = dx * dx + dz * dz
							if dxz > orr * orr:
								continue
							var ci = (wz - oz) * size.x + (wx - ox)
							var pc = profs[ci]
							var ore = TerrainConfig.ore_pick_for(lx, ly, lz, ob.y, int(pc.y), pc.z)
							if ore < 0:
								continue
							var ctop = cdtop[ci]
							for wy in range(oy0, oy1 + 1):
								if wy >= ctop:
									continue          # per-cell territory — already exact
								if not (wy > BULK_DEEPSLATE_TOP_Y or (wy < BULK_DEEPSLATE_FULL_Y and wy >= BULK_BEDROCK_TOP_Y)):
									continue          # dither / bedrock rows: never filled, never stamped
								var dy = wy - ob.y
								if dxz + dy * dy > orr * orr:
									continue
								# The HOST (base gradient + any strata blob just stamped) decides both whether
								# ore may replace it at all and which variant it takes — read from the SAME
								# _deep_family the gather uses rather than re-deriving it here.
								var host = TerrainConfig.deep_family_at(wx, wy, wz)
								if not TerrainConfig.ore_hosts(host):
									continue
								var oid = TerrainConfig.ore_apply(ore, wy, host)
								if oid == host:
									continue          # outside the ore's own y-band → host stands
								var oa = cube_arid[oid] if oid < ncube else oid
								if oa < 0 or oa >= mcount:
									continue          # unbaked → leave the host (never a stale index)
								buffer.set_voxel(oa, wx - ox, wy - oy, wz - oz, ch)
	# STREAM-SCHED T1 (§9.1): the per-cell emit loop finished. Class 2 = the block sits wholly BELOW every
	# column's surface, i.e. the UNDERGROUND block that failed the whole-block bulk gate — exactly the class
	# R1 targets, and the share §2.3 models at 25%. Class 3 = it crosses a surface. min_h is only computed on
	# the flat branch (curved leaves it at its +inf init), so curved blocks report as surface-crossing rather
	# than silently landing in class 2.
	_gen_acc(2 if (flat_world and oy + size.y * s <= min_h) else 3, _t0)
"""
	# FP-S1(e) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §4-R2 defect 4 note / §8): `src` is a CONSTANT literal —
	# the facet epoch, lod-probe flag, frame M_win and all frozen tables are set as INSTANCE properties below, never
	# baked into the source. So compiling it (the ~expensive GDScript.reload() parse) on EVERY restream/crossing was
	# pure waste. Compile ONCE, cache the compiled class, and instantiate a fresh generator per epoch. The compiled
	# class carries no per-epoch state (all state is instance vars set on `gen`), so reuse is byte-identical.
	if _gen_script_cache == null:
		var gen_script := GDScript.new()
		gen_script.source_code = src
		var err := gen_script.reload()
		if err != OK:
			push_warning("[module_world] generator compile failed: %d" % err)
			return null
		_gen_script_cache = gen_script
	var gen: Object = _gen_script_cache.new()
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
	gen.set("carve_arid", _carve_arid)                   # COSMOS FP-CARVE (patch 0004): carve-sentinel cube ARIDs
	gen.set("carve_snow_arid", _carve_snow_arid)         # COSMOS FP-CARVE: snow-capped carve-sentinel cube ARIDs
	gen.set("snow_slope_arid", _snow_slope_arid)         # SHARP-SLOPE §4.2: snow-capped slope ARID
	gen.set("waterlog", _waterlog_enabled)               # WATERLOGGING §4.5: route submerged → twins
	# COSMOS frozen-epoch (COSMOS-AUDIT §3.2 items 2–3): freeze this epoch's home face + n + flat flag
	# onto the generator instance. The worker reads these IMMUTABLE snapshots (never _active_face), so a
	# home-face flip creates a fresh generator (new gen_face) + restream rather than mutating under workers.
	gen.set("flat_world", CubeSphere.FLAT_WORLD)
	gen.set("gen_face", _gen_face)
	gen.set("gen_n", CubeSphere.n_for(CubeSphere.HOME_BODY))
	gen.set("gen_facet", facet_override if facet_override != -999 else (TerrainConfig.active_facet() if CubeSphere.FACETED else -1))   # FACETED §3.3: frozen facet epoch (FP-R0 override)
	gen.set("gen_lod_probe", lod_probe)                  # FP-R0 §B: lod>0 stride sampling (default false → shipped early-out)
	gen.set("radial_datum", CubeSphere.FP_RADIAL_DATUM)  # COSMOS FS2 §3.2: the C++ mirror resolves each cell at true y − S
	# GEN-EFFICIENCY Fix A: freeze the bulk-underground flag + the two fill ARIDs (the cube ARID a plain deep STONE /
	# DEEPSLATE cell writes — modifier-0 cube, so exposed non-ore walls match byte-for-byte). Read off the SAME baked
	# cube_arid table the per-cell path uses; -1 when a material isn't baked → that branch never fills (per-cell).
	gen.set("fp_bulk", CubeSphere.FP_BULK_UNDERGROUND)
	gen.set("fp_colbulk", CubeSphere.FP_COLBULK)         # STREAM-SCHED R1 (§9.2): column-granular bulk fill
	gen.set("fp_stamp", CubeSphere.FP_STAMP)             # STREAM-SCHED R7 (§9.6): lossless blob scatter over R1's fills
	var _bstone := BlockCatalog.STONE
	gen.set("bulk_stone_arid", _cube_arid[_bstone] if _bstone >= 0 and _bstone < _cube_arid.size() else -1)
	var _bdeep := BlockCatalog.id_of(&"deepslate")
	gen.set("bulk_deepslate_arid", _cube_arid[_bdeep] if _bdeep >= 0 and _bdeep < _cube_arid.size() else -1)
	# COSMOS-FRAME-ORIENTATION §5.1: freeze this epoch's window orientation M_win (row-major [a,b,c,d]).
	gen.set("gen_mwin_a", int(_gen_mwin[0]))
	gen.set("gen_mwin_b", int(_gen_mwin[1]))
	gen.set("gen_mwin_c", int(_gen_mwin[2]))
	gen.set("gen_mwin_d", int(_gen_mwin[3]))
	# The OOB fence upper bound (VDS §8.1): the ACTUAL baked model count, read back from the library
	# (not _next_arid) so that if a web bake ever truncated the models array below what we appended, the
	# generator still never writes an index past what the mesher can address. Falls back to _next_arid
	# when the library doesn't expose its models array.
	gen.set("model_count", _library_model_count())

	# COSMOS L5(a) S4 (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.6) — under FP_CPPGEN, the voxel workers run
	# the COMPILED VoxelGeneratorCosmos instead of this GDScript generator. Same frozen tables, same epoch,
	# byte-identical output (verify_cppgen's buffer gate), but ~x25 faster on web (compiled wasm vs the
	# interpreter). We build it here — AFTER `gen` is fully configured — so it reuses every already-baked
	# table rather than re-deriving one. On ANY failure (class absent, setup refused) we fall back to the
	# GDScript `gen`, so a missing/older binary degrades to the shipped path instead of breaking. Default
	# OFF ⇒ this whole block is skipped ⇒ byte-identical to shipped.
	if CubeSphere.FP_CPPGEN and ClassDB.class_exists("VoxelGeneratorCosmos"):
		var cgen: Object = _make_cpp_generator(gen)
		if cgen != null:
			return cgen
	return gen

## S4: construct the compiled VoxelGeneratorCosmos for this epoch, frozen from the SAME tables the
## GDScript generator `src_gen` just received (so the two are byte-identical by shared inputs, not a
## parallel bake). Returns null on any failure so the caller falls back to the GDScript generator.
func _make_cpp_generator(src_gen: Object) -> Object:
	var cgen: Object = ClassDB.instantiate("VoxelGeneratorCosmos")
	if cgen == null:
		return null
	var twin: Array = _gen_twin_arid
	var empty := PackedInt32Array()
	var cfg := TerrainConfig.noise_stack()
	for k in TerrainConfig.material_tables():
		cfg[k] = TerrainConfig.material_tables()[k]
	# Epoch + flags (mirrors the gen.set(...) calls above; read the frozen epoch off src_gen so the two
	# generators are on the SAME facet/face/window — never re-read a mutable global here).
	cfg["gen_face"] = src_gen.get("gen_face")
	cfg["gen_n"] = src_gen.get("gen_n")
	cfg["gen_facet"] = src_gen.get("gen_facet")
	cfg["flat_world"] = src_gen.get("flat_world")
	cfg["faceted"] = CubeSphere.FACETED
	cfg["m5c_corner"] = CubeSphere.M5C_CORNER
	cfg["radial_datum"] = CubeSphere.FP_RADIAL_DATUM     # COSMOS FS2 §3.2
	cfg["model_count"] = src_gen.get("model_count")
	cfg["waterlog"] = src_gen.get("waterlog")
	# TreeGen ids. id_wood/id_leaf are the oak (bootstrap) log/leaf — NOT in material_tables(), so set
	# them here explicitly; omitting them defaults p.id_wood to 0 (air) and every oak tree emits air.
	cfg["id_wood"] = BlockCatalog.WOOD
	cfg["id_leaf"] = BlockCatalog.LEAF
	cfg["id_spruce_log"] = BlockCatalog.id_of(&"spruce_log")
	cfg["id_spruce_leaf"] = BlockCatalog.id_of(&"spruce_leaves")
	cfg["id_birch_log"] = BlockCatalog.id_of(&"birch_log")
	cfg["id_birch_leaf"] = BlockCatalog.id_of(&"birch_leaves")
	# The frozen appearance/ARID tables (reuse the exact instances set on src_gen).
	cfg["block_ids"] = TerrainConfig.appearance_surface_materials()   # setup sanity field (unused by emit)
	cfg["cube_arid"] = src_gen.get("cube_arid")
	cfg["gen_arid"] = src_gen.get("gen_arid")
	cfg["snow_arid"] = src_gen.get("snow_arid")
	cfg["layer_arid"] = src_gen.get("layer_arid")
	cfg["slope_arid"] = src_gen.get("slope_arid")
	cfg["snow_slope_arid"] = src_gen.get("snow_slope_arid")
	cfg["carve_arid"] = src_gen.get("carve_arid")
	cfg["carve_snow_arid"] = src_gen.get("carve_snow_arid")
	cfg["surface_arid"] = src_gen.get("surface_arid")
	cfg["twin_w"] = twin[1] if twin.size() > 1 and twin[1] != null else empty
	cfg["twin_l"] = twin[2] if twin.size() > 2 and twin[2] != null else empty
	cfg["twin_3"] = twin[3] if twin.size() > 3 and twin[3] != null else empty
	cfg["comp_l3"] = src_gen.get("comp_l3")
	cfg["comp_l5"] = src_gen.get("comp_l5")
	cfg["comp_l8"] = src_gen.get("comp_l8")
	cfg["comp_l10"] = src_gen.get("comp_l10")
	cfg["snow_lrid"] = _snow_id_of()
	if CubeSphere.FACETED:
		for k in FacetAtlas.frozen_atlas():
			cfg[k] = FacetAtlas.frozen_atlas()[k]
	if not cgen.call("setup", cfg):
		push_warning("[module_world] VoxelGeneratorCosmos.setup refused — falling back to GDScript generator")
		return null
	return cgen

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
