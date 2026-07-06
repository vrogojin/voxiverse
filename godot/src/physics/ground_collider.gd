class_name GroundCollider
extends Node3D
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
## AMORTIZED, DOUBLE-BUFFERED REBUILD (the user-loop-priority rule): the region is
## ~841 columns / ~1300 shapes; rebuilding it all in one frame is a ~100 ms-on-wasm
## main-thread stall every REBUILD_DIST blocks of walking. Instead this node owns TWO
## child StaticBody3D bodies — the LIVE one (collision_layer set) keeps the last
## COMPLETED shape set attached while the STAGING one is (re)built INCREMENTALLY, a
## bounded slice of columns per update() (COLS_PER_FRAME) across frames. When the
## staging set is complete the two swap by toggling collision_layer (O(1)); no frame
## ever clears+rebuilds the whole set. Bodies collide with the slightly-stale live set
## during the transition — fine, the region is generous and loose bodies are near the
## player. Only the FIRST build (spawn/load, no collider yet) runs to completion in one
## call so the world has collision immediately. The SETTLED shape set is byte-identical
## to a full synchronous rebuild — only the scheduling changed.
##
## Shapes are attached directly to each body via PhysicsServer3D (no per-box nodes) from
## per-body pools reused across rebuilds, so a rebuild does no steady-state allocation —
## only PhysicsServer re-attach.

const R := 14                # region half-extent in columns (covers +/-14 blocks)
const REBUILD_DIST := 8       # (re)build once the player drifts this far from the LIVE centre
const DEPTH := 32             # emit solid this far below the region's lowest surface
## Half-extent (columns) of the immediate synchronous CORE built around a freshly-woken faller before
## the full R region fills incrementally behind it (see _build_core / core-then-fill). A break happens
## at reach distance and a chopped tree's pieces spread a few blocks, so ±4 (a 9×9 core) reliably
## covers the faller and its neighbours through the ~1.4 s the full fill takes; (2*CORE_R+1)^2 = 81
## columns is ~1/10 of the (2R+1)^2 = 841 region, turning the old ~368 ms whole-region synchronous
## stall into a ~one-frame core build.
const CORE_R := 4

const GROUND_FRICTION := 0.6  # grippy enough that dropped pieces rest, not slide
const GROUND_BOUNCE := 0.0    # no bouncing off the terrain
const TERRAIN_LAYER := 1 << 0 # the "terrain ground" collision layer loose bodies collide with

## Amortization budget for the HEIGHTS pass: columns (surface-noise queries) sampled per update().
## PHASE_HEIGHTS work is ~one column_profile() per unit, so bounding it by columns is exact. Sized so
## one height slice stays a low-single-digit ms on wasm.
const COLS_PER_FRAME := 32
## Amortization budget for the SHAPES/TRIM pass: PhysicsServer3D shape OPS (set/add/remove) per
## update(). This is the "breaking multiple blocks in succession is heavy" fix. PHASE_SHAPES emits a
## VARIABLE, unbounded number of shapes per column (a plain column is 1 box, but a tower / dug tunnel
## / tree column emits several), so bounding the slice by COLUMNS let a dense 32-column slice balloon
## to 60-100+ PhysicsServer ops ≈ 20-40 ms on wasm — and during a rapid strip-mine the debounced
## rebuilds ran back-to-back, so those op-heavy slices recurred every few frames and tanked FPS to
## 7-14 while debris was loose. Bounding the shape/trim pass by OPS instead makes each slice a FLAT
## low-single-digit ms regardless of terrain density: a slice yields as soon as it has performed this
## many ops (always after finishing the current column, so build state stays consistent). The SETTLED
## shape set is byte-identical — only the scheduling changed (the double-buffer contract). A tall
## single column can overshoot by its own height, which is tiny (a handful of runs).
##
## Sized for the WEAK target device (Intel HD via wasm, where a PhysicsServer op costs several times
## a fast host): 24 ops keeps a slice well under a 60 fps frame even there, with headroom for render.
## The cost is a marginally slower BACKGROUND fill (the full region settles over ~1.5 s of frames
## after a drift/edit) — invisible, because a covering live set keeps colliding during the slice and
## VoxelBody settling confirms support analytically (never trusting the in-progress set). Tunable.
const OPS_PER_FRAME := 24
## Only a LARGE jump (a teleport) re-anchors an in-progress build; a normal walk lets the build
## FINISH (the next drift then starts a fresh one), so a fast walk can't thrash the builder into
## never completing. 2*R ⇒ restart only once the player has left the region being built.
const RESTART_DRIFT := 2 * R
## Active-body gate radius (columns): the collider is maintained only while a loose VoxelBody is
## within this Chebyshev distance of the player. R + REBUILD_DIST so a body sitting at the region
## edge stays served across a full drift cycle; beyond it the collider idles (a body that far needs
## no collision here, and the player is analytic).
const _GATE_RADIUS := R + REBUILD_DIST

## EDIT-REBUILD DEBOUNCE (P2 — the "breaking each block is expensive" fix). A terrain edit only
## marks the collider dirty; the rebuild is deferred until edits PAUSE (DEBOUNCE_FRAMES with no new
## edit) or MAX_LATENCY_FRAMES elapse since the first edit of the burst — whichever comes first. So
## a fast strip-mine coalesces a burst of breaks into ≤ 1 incremental rebuild instead of restarting
## the dirty cycle per block. Frame-based (not wall-clock) so it is deterministic in the headless
## verify. At ~60 fps: 15 ≈ 0.25 s debounce, 60 ≈ 1.0 s max latency. Safe because settling confirms
## support ANALYTICALLY (VoxelBody._grounded), never trusting a briefly-stale collider.
const DEBOUNCE_FRAMES := 15
const MAX_LATENCY_FRAMES := 60

# Build phases: idle, sampling column heights (region floor), emitting shapes, trimming the
# staging body's surplus leftover shapes (when the new set is smaller than the previous one).
enum { PHASE_IDLE, PHASE_HEIGHTS, PHASE_SHAPES, PHASE_TRIM }

var world: WorldManager

# Double buffer: two static bodies. The LIVE one (index _live) carries TERRAIN_LAYER and the
# completed shapes; the other is inert (layer 0) and is the STAGING target being built.
var _body: Array[StaticBody3D] = []
var _live := -1                               # index of the live body; -1 = nothing built yet
# Per-body shape pools (reused across rebuilds → no steady-state allocation, only re-attach).
var _pool: Array = [[], []]                   # per-body Array[BoxShape3D]
var _cpool: Array = [[], []]                  # per-body Array[ConvexPolygonShape3D]

var _live_center := Vector2i(0x7fffffff, 0)   # centre of the LIVE shape set (sentinel = none)
var _target := Vector2i(0x7fffffff, 0)        # latest requested centre (player's column)
var _dirty := false                           # an edit asked for a rebuild at the current centre
var _gated := false                           # true while the active-body gate is OFF (idle; shapes RETAINED)
var _edit_age := 0                            # frames since the FIRST pending edit of the current burst
var _edit_idle := 0                           # frames since the LAST edit (resets to 0 on every rebuild_now)

# Incremental build state (valid while _phase != PHASE_IDLE).
var _phase := PHASE_IDLE
var _build_center := Vector2i(0, 0)
var _build_staging := 0                       # body index being built into this pass
var _build_i := 0                             # next column index into the span (0..span*span)
var _build_heights := PackedInt32Array()
var _build_min_h := 0
var _build_ylo := 0
var _build_used := 0                          # box POOL slots consumed so far this pass
var _build_cused := 0                         # prism POOL slots consumed so far this pass
var _build_pc: Dictionary = {}                # per-build column-profile memo (height + biome)
# Shape REUSE (no clear-all-then-add-all spike): each pass re-points the staging body's EXISTING
# shape slots in place (body_set_shape + body_set_shape_transform) instead of body_clear_shapes +
# re-add, then trims any surplus. _build_slot is the running body-slot index (boxes+prisms
# interleaved); _build_prev_count is how many slots the staging body already had at pass start.
var _build_slot := 0
var _build_prev_count := 0
var _build_trim := 0                          # next surplus slot to remove (during PHASE_TRIM)
var _slice_ops := 0                           # PhysicsServer shape ops in the most recent update()

func setup(world_ref: WorldManager) -> void:
	world = world_ref
	# The node stays at the origin; box transforms carry absolute world positions.
	global_position = Vector3.ZERO
	_build_heights.resize((2 * R + 1) * (2 * R + 1))
	for i in 2:
		var b := StaticBody3D.new()
		b.name = "GCBody%d" % i
		b.collision_layer = 0          # inert until it becomes the live body (first swap)
		b.collision_mask = 0           # static; it does not need to detect anything
		var pm := PhysicsMaterial.new()
		pm.friction = GROUND_FRICTION
		pm.bounce = GROUND_BOUNCE
		b.physics_material_override = pm
		add_child(b)
		_body.append(b)

## Follow the player; drive the incremental (re)build. Returns quickly every frame — a fast
## walk just keeps moving the target and the incremental build chases it (see RESTART_DRIFT).
##
## ACTIVE-BODY GATE (the exploration-jerkiness fix): the collider exists ONLY to catch loose
## VoxelBodies (falling/pushed debris) — the player is analytic and never uses it. So when NO loose
## body is near the player, this does ZERO work (early-return, collider left idle). Exploring /
## flying with nothing broken → no rebuild churn at all; the per-distance stutter (which scaled with
## movement speed = the rebuild-on-drift cycle) disappears. A body spawned by a break/place, or one
## that drifts within range, re-activates the collider and (from idle) bootstraps a small CORE so the
## falling body has ground THIS frame, while the full region fills incrementally behind it.
func update(player_pos: Vector3) -> void:
	if world == null:
		return
	_target = Vector2i(int(floor(player_pos.x)), int(floor(player_pos.z)))
	if not world.has_active_bodies_near(_target, _GATE_RADIUS):
		_gate_off()                         # nothing to collide with → stop work, KEEP shapes
		return
	var was_gated := _gated
	_gated = false
	if _phase != PHASE_IDLE:
		# A build is running: only a big jump re-anchors it; otherwise let it finish.
		if _drift(_target, _build_center) >= RESTART_DRIFT:
			_begin_build(_target)
		_advance_build(false)
		return
	# Session-first build: no collider exists yet → CORE-THEN-FILL. A small synchronous core centred on
	# the faller goes live THIS frame (ground immediately), then the full R region fills incrementally
	# behind it — replacing the old ~368 ms whole-region synchronous stall with a ~one-frame core build.
	if _live_center.x == 0x7fffffff:
		_bootstrap_core(_target)
		_begin_build(_target)
		_advance_build(false)
		return
	# Reopening from gated with the RETAINED live set too far to serve a freshly-woken faller during a
	# sliced rebuild → same core-then-fill: bootstrap immediate ground under the faller, fill the rest
	# incrementally. (The common case — break near where you already stand — keeps the covering live set
	# and pays NO core rebuild.)
	if was_gated and _drift(_target, _live_center) >= REBUILD_DIST:
		_bootstrap_core(_target)
		_begin_build(_target)
		_advance_build(false)
		return
	# Player-drift rebuild (walked far): incremental — the slightly-stale but nearby live set keeps
	# colliding during the slice (the existing double-buffer contract).
	if _drift(_target, _live_center) >= REBUILD_DIST:
		_begin_build(_target)
		_advance_build(false)
		return
	# Edit rebuild: DEBOUNCED. A burst of breaks coalesces into ≤ 1 incremental rebuild — no per-block
	# dirty-cycle restart, and NEVER a synchronous full rebuild from the edit path (that was the
	# ~100 ms stall). Build once edits pause (idle) or the max latency elapses.
	if _dirty:
		_edit_age += 1
		_edit_idle += 1
		if _edit_idle >= DEBOUNCE_FRAMES or _edit_age >= MAX_LATENCY_FRAMES:
			_begin_build(_target)
			_advance_build(false)

## Ask for a rebuild at the current centre (called after a terrain edit). Non-blocking and
## DEBOUNCED (P2): merely marks dirty and resets the "edits paused" counter, so a burst of breaks
## coalesces into one deferred incremental rebuild (see update()). An edit tolerates a slightly-stale
## collider for the few frames until it settles — VoxelBody settling confirms support analytically,
## never trusting the collider, so the staleness is safe.
func rebuild_now() -> void:
	if _live_center.x == 0x7fffffff:
		return                              # nothing built yet; the first update() builds it
	if not _dirty:
		_edit_age = 0                       # first edit of a burst: start the max-latency clock
	_dirty = true
	_edit_idle = 0                          # every new edit resets the debounce window

## Gate OFF (no loose body near): stop doing rebuild work but RETAIN the live shape set and all
## build state (P2 — the anti-stall change). The player is analytic and frozen debris never consults
## the collider, so a retained (possibly slightly-stale) live set costs nothing and is harmless while
## gated — and reactivation then needs no synchronous full rebuild (the old _go_idle() discarded the
## shapes, forcing a ~100 ms rebuild on the next wake). Any in-progress build is simply paused; it
## resumes (or re-anchors) when the gate reopens. Cheap idempotent no-op.
func _gate_off() -> void:
	_gated = true
	_slice_ops = 0                          # a gated frame does ZERO rebuild work

## Re-attach after re-entering the tree. Server-added shapes on a body are cleared by Godot on
## tree exit; if this collider is ever reparented, rebuild synchronously so bodies don't fall
## through. (First ENTER_TREE runs before setup(), when world is null, so it safely no-ops.)
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE and world != null and _live_center.x != 0x7fffffff:
		_live = -1
		_live_center = Vector2i(0x7fffffff, 0)
		_begin_build(_target)
		_advance_build(true)

static func _drift(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))    # Chebyshev distance in columns

# --- core-then-fill bootstrap --------------------------------------------------

## Find the faller and build the immediate CORE around it. The gate is open because an awake body is
## within _GATE_RADIUS of the player, so centre the core on THAT body (a break happens at reach
## distance — the faller can be a few blocks from the player); fall back to the player column if the
## body vanished between the gate check and here.
func _bootstrap_core(player_target: Vector2i) -> void:
	var fc := world.active_body_column_near(player_target, _GATE_RADIUS)
	_build_core(fc if fc.x != 0x7fffffff else player_target)

## Build a small (CORE_R) synchronous collider centred on `center` into the currently-inert double-
## buffer body and make it LIVE immediately, so a freshly-spawned/woken faller has ground THIS frame
## without paying the whole-region synchronous cost. The full R region then fills incrementally behind
## it (update() calls _begin_build + _advance_build right after this); when that completes the buffer
## swaps and this core body goes inert — the core is a transient bootstrap and the settled result is
## byte-identical to a full rebuild. Reuses _emit_column, so core shapes are byte-identical to the
## full build's shapes for the same columns (only y_lo differs: core uses the CORE's local floor,
## which is ≥ the region floor — still DEPTH deep under the faller, and irrelevant once the full set
## swaps in). Uses the shared build-state vars (_build_ylo/_build_staging/_build_used/_build_cused/
## _build_slot/_build_prev_count/_build_pc); all are re-initialised by _begin_build + the HEIGHTS→
## SHAPES transition before the incremental fill's shape pass touches them, so there is no carryover.
func _build_core(center: Vector2i) -> void:
	_build_pc.clear()
	var bidx := (_live + 1) % 2                       # build into the inert body (becomes live)
	var cspan := 2 * CORE_R + 1
	var hs := PackedInt32Array()
	hs.resize(cspan * cspan)
	var core_min := 0x7fffffff
	var k := 0
	for dz in range(-CORE_R, CORE_R + 1):
		for dx in range(-CORE_R, CORE_R + 1):
			var h := int(TerrainConfig.column_profile(center.x + dx, center.y + dz, _build_pc).x)
			hs[k] = h
			if h < core_min:
				core_min = h
			k += 1
	_build_ylo = core_min - DEPTH
	_build_staging = bidx
	_build_prev_count = PhysicsServer3D.body_get_shape_count(_body[bidx].get_rid())
	_build_used = 0
	_build_cused = 0
	_build_slot = 0
	k = 0
	for dz in range(-CORE_R, CORE_R + 1):
		for dx in range(-CORE_R, CORE_R + 1):
			_emit_column(bidx, center.x + dx, center.y + dz, hs[k])
			k += 1
	# Trim any surplus slots this body kept from a previous, larger life (index-stable from the end).
	while _build_prev_count > _build_slot:
		PhysicsServer3D.body_remove_shape(_body[bidx].get_rid(), _build_prev_count - 1)
		_build_prev_count -= 1
	# Swap the core live immediately (O(1) layer toggle); the old live body (if any) goes inert.
	_body[bidx].collision_layer = TERRAIN_LAYER
	if _live >= 0 and _live != bidx:
		_body[_live].collision_layer = 0
	_live = bidx

# --- incremental build --------------------------------------------------------

func _begin_build(center: Vector2i) -> void:
	_build_center = center
	_build_staging = (_live + 1) % 2                 # _live == -1 → staging 0
	_phase = PHASE_HEIGHTS
	_build_i = 0
	_build_min_h = 0x7fffffff
	_build_pc.clear()
	_dirty = false

## Advance the current build by one slice. PHASE_HEIGHTS samples every column's surface (to find the
## region floor y_lo); PHASE_SHAPES re-points the staging body's shape slots in place (reuse, no
## clear); PHASE_TRIM removes any surplus leftover slots. On completion, swaps live↔staging by
## toggling collision_layer.
##
## `sync == true` runs the whole build to completion in this one call (the first / reopen-too-far
## build, so a freshly-woken faller has ground immediately). `sync == false` is the AMORTIZED slice:
## HEIGHTS yields after COLS_PER_FRAME columns; SHAPES/TRIM yield after OPS_PER_FRAME PhysicsServer
## shape ops. Bounding the shape pass by OPS (not columns) is the multi-break-heaviness fix — see
## OPS_PER_FRAME: a dense column emits several shapes, so a fixed column budget produced 20-40 ms
## op-heavy slices, whereas a fixed OP budget keeps every slice flat regardless of terrain density.
## The slice always yields at a COLUMN boundary (after _emit_column returns), so build state is
## consistent; the settled shape set is byte-identical to a synchronous rebuild.
func _advance_build(sync: bool) -> void:
	var span := 2 * R + 1
	var total := span * span
	var x0 := _build_center.x - R
	var z0 := _build_center.y - R
	_slice_ops = 0
	var cols_done := 0
	while true:
		if _phase == PHASE_HEIGHTS:
			if _build_i < total:
				var i := _build_i / span
				var j := _build_i % span
				var h := int(TerrainConfig.column_profile(x0 + i, z0 + j, _build_pc).x)
				_build_heights[_build_i] = h
				if h < _build_min_h:
					_build_min_h = h
				_build_i += 1
				cols_done += 1
				if not sync and cols_done >= COLS_PER_FRAME:
					return                              # heights slice: bounded by column count
			else:
				# Heights done → region floor known. Begin the shape pass by REUSING the staging
				# body's existing slots in place (no body_clear_shapes spike). Its shapes are all
				# stale (from 2 builds ago) but the body is inert (layer 0), so re-pointing them
				# across frames is invisible to physics until the swap.
				_build_ylo = _build_min_h - DEPTH
				_build_prev_count = PhysicsServer3D.body_get_shape_count(_body[_build_staging].get_rid())
				_build_used = 0
				_build_cused = 0
				_build_slot = 0
				_phase = PHASE_SHAPES
				_build_i = 0
		elif _phase == PHASE_SHAPES:
			if _build_i < total:
				var i := _build_i / span
				var j := _build_i % span
				_emit_column(_build_staging, x0 + i, z0 + j, _build_heights[_build_i])
				_build_i += 1
				if not sync and _slice_ops >= OPS_PER_FRAME:
					return                              # shapes slice: bounded by PhysicsServer ops
			else:
				# All columns emitted. If the new set uses FEWER slots than the staging body had,
				# trim the surplus leftover slots (also budgeted); else it is complete.
				if _build_slot < _build_prev_count:
					_build_trim = _build_prev_count
					_phase = PHASE_TRIM
				else:
					_finish_build()
					return
		else:  # PHASE_TRIM — remove surplus slots from the end (index-stable for kept slots)
			if _build_trim > _build_slot:
				PhysicsServer3D.body_remove_shape(_body[_build_staging].get_rid(), _build_trim - 1)
				_build_trim -= 1
				_slice_ops += 1
				if not sync and _slice_ops >= OPS_PER_FRAME:
					return                              # trim slice: bounded by PhysicsServer ops
			else:
				_finish_build()
				return

## Swap: the freshly-built staging body goes LIVE (carries TERRAIN_LAYER); the old live body
## goes inert (layer 0) — it keeps its now-stale shapes until IT is the staging target of the
## next build (cleared then). O(1); loose bodies never see a partial set.
func _finish_build() -> void:
	_body[_build_staging].collision_layer = TERRAIN_LAYER
	if _live >= 0 and _live != _build_staging:
		_body[_live].collision_layer = 0
	_live = _build_staging
	_live_center = _build_center
	_phase = PHASE_IDLE

## Emit one column's boxes/prisms into body `bidx`. BYTE-IDENTICAL to the pre-amortization full
## rebuild's per-column logic, with one PERF shortcut: an UNEDITED column (no overlay entries —
## `world.is_edited_column` false) skips the per-cell overlay dict lookups entirely (their result
## is always "absent" there), collapsing the region's ~30k Vector3i lookups to the handful of
## genuinely-edited columns. The queries below are the LIGHT surface/cap ones (no generated_cell).
func _emit_column(bidx: int, x: int, z: int, h: int) -> void:
	var edited := world.is_edited_column(x, z)
	var y := _build_ylo
	# A shaft dug deeper than DEPTH below the region floor: descend to the true solid floor so
	# it still gets a floor box. Only edited columns can have removed cells, so only they pay it.
	if edited:
		while world.is_removed(Vector3i(x, y, z)):
			y -= 1
	var run_start := 0x7fffffff
	# Sub-surface: the heightmap fills every cell up to h; it is air only where dug out (overlay
	# 0). At the top (y == h) the LIGHT surface_modifier picks up a smoothed ramp/slab WITHOUT the
	# heavy generated_cell pipeline. Sub-surface generated cells are always full cubes.
	while y <= h:
		var ov := -1
		if edited:
			ov = world.placed_cells().get(Vector3i(x, y, z), -1)
		var modifier := 0
		if ov > 0:
			modifier = CellCodec.modifier(ov)
		elif ov < 0 and y == h:
			modifier = TerrainConfig.surface_modifier(x, z, _build_pc)
		if ov == 0:                                 # dug to air → no box here
			if run_start != 0x7fffffff:
				_add_box(bidx, x, z, run_start, y)
				run_start = 0x7fffffff
		elif modifier != 0:                         # shaped cell (placed or smoothed top) → prisms
			if run_start != 0x7fffffff:
				_add_box(bidx, x, z, run_start, y)
				run_start = 0x7fffffff
			_add_prisms(bidx, x, y, z, modifier)
		elif run_start == 0x7fffffff:
			run_start = y
		y += 1
	# Above the heightmap: a placed cell (overlay), a smoothed grass CAP lip at y==h+1 (light
	# query), sea fill for underwater columns, else the tree overlay hash — no generated_cell.
	var y_top := maxi(h + TreeGen.MAX_ABOVE_SURFACE, world.placed_top(x, z))
	while y <= y_top:
		var ov := -1
		if edited:
			ov = world.placed_cells().get(Vector3i(x, y, z), -1)
		var solid := false
		var modifier := 0
		if ov > 0:                                  # placed block (full cube or shaped)
			solid = true
			modifier = CellCodec.modifier(ov)
		elif ov == 0:                               # dug to air
			pass
		else:                                       # generated cell above the heightmap top
			if y == h + 1 and h >= TerrainConfig.SEA_LEVEL:
				modifier = TerrainConfig.surface_cap_modifier(x, z, _build_pc)
			if modifier != 0:
				solid = true                        # smoothed grass cap → prism
			elif y <= TerrainConfig.SEA_LEVEL:
				solid = true                        # sea fill (water/ice) → full-cube box
			elif TreeGen.block_at(x, y, z, _build_pc) != BlockCatalog.AIR:
				solid = true                        # tree wood/leaf → full-cube box
		if solid and modifier != 0:
			if run_start != 0x7fffffff:
				_add_box(bidx, x, z, run_start, y)
				run_start = 0x7fffffff
			_add_prisms(bidx, x, y, z, modifier)
		elif solid:
			if run_start == 0x7fffffff:
				run_start = y
		elif run_start != 0x7fffffff:
			_add_box(bidx, x, z, run_start, y)
			run_start = 0x7fffffff
		y += 1
	if run_start != 0x7fffffff:
		_add_box(bidx, x, z, run_start, y_top + 1)   # top run (surface / tree / tower)

## Attach one box covering the solid cells [y_bottom, y_top-1] of column (x, z) to body `bidx`,
## from that body's pool (resized in place → no allocation). Translation-only transform.
func _add_box(bidx: int, x: int, z: int, y_bottom: int, y_top: int) -> void:
	var pool: Array = _pool[bidx]
	var box: BoxShape3D
	if _build_used < pool.size():
		box = pool[_build_used]
	else:
		box = BoxShape3D.new()
		pool.append(box)
	box.size = Vector3(1.0, float(y_top - y_bottom), 1.0)
	_build_used += 1
	var t := Transform3D(Basis(), Vector3(x + 0.5, (float(y_bottom) + float(y_top)) * 0.5, z + 0.5))
	_attach(bidx, box.get_rid(), t)

## Attach a shape at the next body slot, REUSING an existing slot in place when the staging body
## still has one (body_set_shape + body_set_shape_transform → no clear/add churn), else appending.
## The pooled BoxShape3D/ConvexPolygonShape3D resource is edited before this, so re-pointing a
## reused slot at it updates the collision geometry with no allocation and no clear-all spike.
func _attach(bidx: int, shape_rid: RID, t: Transform3D) -> void:
	var rid := _body[bidx].get_rid()
	if _build_slot < _build_prev_count:
		PhysicsServer3D.body_set_shape(rid, _build_slot, shape_rid)
		PhysicsServer3D.body_set_shape_transform(rid, _build_slot, t)
	else:
		PhysicsServer3D.body_add_shape(rid, shape_rid, t)
	_build_slot += 1
	_slice_ops += 1

## Attach the ≤ 2 convex prisms of a shaped solid cell at (x, y, z) to body `bidx` (SVS §5.4):
## each surface triangle extruded to the anchor face is a convex triangular prism, so loose
## bodies rest/slide on a placed ramp correctly. World-space points, identity transform;
## degenerate (zero-height) triangles are skipped. Reuses the body's pooled shapes.
func _add_prisms(bidx: int, x: int, y: int, z: int, modifier: int) -> void:
	var pool: Array = _cpool[bidx]
	var base_y := 0.0 if ShapeCodec.anchor(modifier) == ShapeCodec.ANCHOR_BOTTOM else 1.0
	var origin := Vector3(x, y, z)
	for tri: Dictionary in ShapeCodec.surface_tris(modifier):
		var pts := PackedVector3Array()
		var nondegen := false
		for key in ["v0", "v1", "v2"]:
			var sp: Vector3 = tri[key]
			if absf(sp.y - base_y) > 1e-4:
				nondegen = true
			pts.append(origin + sp)
			pts.append(origin + Vector3(sp.x, base_y, sp.z))
		if not nondegen:
			continue
		var shape: ConvexPolygonShape3D
		if _build_cused < pool.size():
			shape = pool[_build_cused]
		else:
			shape = ConvexPolygonShape3D.new()
			pool.append(shape)
		shape.points = pts
		_build_cused += 1
		_attach(bidx, shape.get_rid(), Transform3D.IDENTITY)

# --- accessors (used by the headless verify to inspect the collider) -----------

## The RID of the currently LIVE body (the one loose bodies collide with), or an empty RID
## before the first build completes.
func active_rid() -> RID:
	return _body[_live].get_rid() if _live >= 0 else RID()

## True while an incremental (re)build is in progress (not yet swapped live).
func is_building() -> bool:
	return _phase != PHASE_IDLE

## True while the active-body gate is OFF: the collider is idle (doing no rebuild work) but RETAINS
## its last live shape set (P2). Distinct from the old discard-on-idle: active_rid() stays valid.
func is_gated() -> bool:
	return _gated

## True while an edit-triggered rebuild is PENDING but has not yet begun (debounce window, P2). A
## caller that must observe the post-edit shape set (e.g. the headless verify) has to pump update()
## until BOTH is_pending() and is_building() are false.
func is_pending() -> bool:
	return _dirty

## PhysicsServer shape ops (set/add/remove) performed in the most recent update() call — the
## per-frame collider churn. Bounded per frame (never the whole region); used by verify.
func last_slice_ops() -> int:
	return _slice_ops
