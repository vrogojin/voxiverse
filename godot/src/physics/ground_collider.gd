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

const GROUND_FRICTION := 0.6  # grippy enough that dropped pieces rest, not slide
const GROUND_BOUNCE := 0.0    # no bouncing off the terrain
const TERRAIN_LAYER := 1 << 0 # the "terrain ground" collision layer loose bodies collide with

## Amortization budget: columns processed per update() (per physics frame). The build has two
## passes (all heights → find the region floor → then shapes), so the full region settles in
## ~ceil(2*(2R+1)^2 / COLS_PER_FRAME) frames. Sized so one slice (column queries + PhysicsServer
## shape adds) stays a low-single-digit ms on wasm — the whole point is that no ONE frame pays
## the full cost. Tunable.
const COLS_PER_FRAME := 32
## Only a LARGE jump (a teleport) re-anchors an in-progress build; a normal walk lets the build
## FINISH (the next drift then starts a fresh one), so a fast walk can't thrash the builder into
## never completing. 2*R ⇒ restart only once the player has left the region being built.
const RESTART_DRIFT := 2 * R

# Build phases: idle, sampling column heights (to find the region floor), emitting shapes.
enum { PHASE_IDLE, PHASE_HEIGHTS, PHASE_SHAPES }

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

# Incremental build state (valid while _phase != PHASE_IDLE).
var _phase := PHASE_IDLE
var _build_center := Vector2i(0, 0)
var _build_staging := 0                       # body index being built into this pass
var _build_i := 0                             # next column index into the span (0..span*span)
var _build_heights := PackedInt32Array()
var _build_min_h := 0
var _build_ylo := 0
var _build_used := 0                          # boxes attached to staging so far this pass
var _build_cused := 0                         # prisms attached to staging so far this pass
var _build_pc: Dictionary = {}                # per-build column-profile memo (height + biome)

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
func update(player_pos: Vector3) -> void:
	if world == null:
		return
	_target = Vector2i(int(floor(player_pos.x)), int(floor(player_pos.z)))
	if _phase != PHASE_IDLE:
		# A build is running: only a big jump re-anchors it; otherwise let it finish.
		if _drift(_target, _build_center) >= RESTART_DRIFT:
			_begin_build(_target)
		_advance_build(COLS_PER_FRAME)
		return
	var first := _live_center.x == 0x7fffffff
	var need := first or _dirty or _drift(_target, _live_center) >= REBUILD_DIST
	if not need:
		return
	_begin_build(_target)
	# The very first build (no collider exists yet) completes NOW so spawn/load has collision
	# immediately; every later rebuild is sliced across frames.
	_advance_build(0x7fffffff if first else COLS_PER_FRAME)

## Ask for a rebuild at the current centre (called after a terrain edit). Non-blocking: the
## next update() frames build it incrementally — an edit tolerates a slightly-stale collider
## for the few frames it takes to settle (the live set keeps colliding meanwhile).
func rebuild_now() -> void:
	if _live_center.x != 0x7fffffff:
		_dirty = true

## Re-attach after re-entering the tree. Server-added shapes on a body are cleared by Godot on
## tree exit; if this collider is ever reparented, rebuild synchronously so bodies don't fall
## through. (First ENTER_TREE runs before setup(), when world is null, so it safely no-ops.)
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE and world != null and _live_center.x != 0x7fffffff:
		_live = -1
		_live_center = Vector2i(0x7fffffff, 0)
		_begin_build(_target)
		_advance_build(0x7fffffff)

static func _drift(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))    # Chebyshev distance in columns

# --- incremental build --------------------------------------------------------

func _begin_build(center: Vector2i) -> void:
	_build_center = center
	_build_staging = (_live + 1) % 2                 # _live == -1 → staging 0
	_phase = PHASE_HEIGHTS
	_build_i = 0
	_build_min_h = 0x7fffffff
	_build_pc.clear()
	_dirty = false

## Process up to `budget` column-ops of the current build. PHASE_HEIGHTS samples every column's
## surface (to find the region floor y_lo); PHASE_SHAPES emits each column's boxes/prisms into
## the staging body. On completion, swaps live↔staging by toggling collision_layer.
func _advance_build(budget: int) -> void:
	var span := 2 * R + 1
	var total := span * span
	var x0 := _build_center.x - R
	var z0 := _build_center.y - R
	var done := 0
	while done < budget:
		if _phase == PHASE_HEIGHTS:
			if _build_i < total:
				var i := _build_i / span
				var j := _build_i % span
				var h := int(TerrainConfig.column_profile(x0 + i, z0 + j, _build_pc).x)
				_build_heights[_build_i] = h
				if h < _build_min_h:
					_build_min_h = h
				_build_i += 1
				done += 1
			else:
				# Heights done → region floor known. Clear the staging body's OLD shapes (one
				# call; the pooled shape resources persist) and start the shape pass.
				_build_ylo = _build_min_h - DEPTH
				PhysicsServer3D.body_clear_shapes(_body[_build_staging].get_rid())
				_build_used = 0
				_build_cused = 0
				_phase = PHASE_SHAPES
				_build_i = 0
		else:  # PHASE_SHAPES
			if _build_i < total:
				var i := _build_i / span
				var j := _build_i % span
				_emit_column(_build_staging, x0 + i, z0 + j, _build_heights[_build_i])
				_build_i += 1
				done += 1
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
	PhysicsServer3D.body_add_shape(_body[bidx].get_rid(), box.get_rid(), t)

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
		PhysicsServer3D.body_add_shape(_body[bidx].get_rid(), shape.get_rid(), Transform3D.IDENTITY)

# --- accessors (used by the headless verify to inspect the collider) -----------

## The RID of the currently LIVE body (the one loose bodies collide with), or an empty RID
## before the first build completes.
func active_rid() -> RID:
	return _body[_live].get_rid() if _live >= 0 else RID()

## True while an incremental (re)build is in progress (not yet swapped live).
func is_building() -> bool:
	return _phase != PHASE_IDLE
