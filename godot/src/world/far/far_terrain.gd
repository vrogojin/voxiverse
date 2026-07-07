class_name FarTerrain
extends Node3D
## The far-distance terrain layer (LOD-DESIGN, the locked ADR). A render-only,
## collision-free, voxel-worker-free node owned by WorldManager that keeps 4
## concentric rings of world-anchored analytic heightmap tiles alive around the
## player, from INNER_HOLE (192 m) out to R_FAR (3,072 m). Every tile samples the
## SAME TerrainConfig.height_at / column_profile the near voxel world derives from,
## so the distant silhouette matches the near surface by construction (LOD-DESIGN §3).
##
## Nothing here needs compute/tessellation/geometry shaders — it is plain GDScript +
## MeshInstance3D + runtime ArrayMesh + one StandardMaterial3D, feasible in the GL
## Compatibility / WebGL2 renderer as-is (LOD-DESIGN §7.7). Tiles build on the MAIN
## thread under a per-frame budget, coarse ring first, so there is no load spike and
## the single web voxel worker is never touched (LOD-DESIGN §2.6). Physics is analytic
## through WorldManager and never sees this geometry (CLAUDE.md rule 2). Flipping
## ENABLED to false makes the node non-existent and restores today's behaviour exactly.

# --- Appendix A: locked constants (this file is the single source) ------------
## /lod REVIEW BUILD: ON by default so distant terrain is visible immediately.
## Set to false to restore today's behaviour bit-for-bit (no far node, original fog,
## original camera far — the SMOOTHING_ENABLED diagnostic-toggle pattern).
const ENABLED := true

const R_FAR := 3072.0
const INNER_HOLE := 192.0                 # RENDER_RADIUS_BLOCKS − 64

## Ring table (LOD-DESIGN §1.2): {outer_m, cell_m, tile_m, grid}. Each ring's cell is
## ≈ 2% of its inner radius (a constant screen-space-error target); cell doubles ring
## to ring; tile_m == grid × cell_m.
const RING_TABLE := [
	{"outer_m": 320.0, "cell_m": 4.0, "tile_m": 256.0, "grid": 64},
	{"outer_m": 768.0, "cell_m": 8.0, "tile_m": 512.0, "grid": 64},
	{"outer_m": 1792.0, "cell_m": 16.0, "tile_m": 1024.0, "grid": 64},
	{"outer_m": 3072.0, "cell_m": 32.0, "tile_m": 1024.0, "grid": 32},
]

const BIAS_LAND := 1.5                    # blocks below the walk surface (height_at + 1)
const BIAS_SEA := 0.25                     # far sea at SEA_LEVEL + 0.9375 − this = 0.6875
const SKIRT_CELLS := 4                     # skirt depth = 4 × ring cell
const FAR_RECENTER_STEP := 64.0            # m of XZ movement before re-evaluating the set
const FAR_BUILD_BUDGET_MS := 3.0           # main-thread sampling budget per frame
const MAX_COMMITS_PER_FRAME := 1
const SAMPLE_STEP_COLUMNS := 1024          # profiling slice size (LOD-DESIGN §2.6)
const FAR_MAX_TILES := 120                 # hard caps — trim outermost-first, warn
const FAR_MAX_TRIS := 450000
const FAR_MAX_DRAWS := 96
const FAR_CAMERA_FAR := 3840.0             # player.gd camera.far override when ENABLED
const FOG_BEGIN := 115.0                   # main.gd fog when ENABLED (LOD-DESIGN §3.4)
const FOG_END := 2750.0
const FOG_CURVE := 0.38

# --- runtime state ------------------------------------------------------------
var _material: StandardMaterial3D
var _live: Dictionary = {}                 # key Vector3i(ring,tx,tz) -> MeshInstance3D
var _live_tris: Dictionary = {}            # key -> int tri count (committed)
var _desired: Dictionary = {}              # key -> {ring, tc, min_dist, tris}
var _queue: Array = []                     # keys pending build (coarse-first, nearest-first)
var _eval_point := Vector2.ZERO
var _has_eval := false
var _warned_caps := false

# active (in-progress) sampling job — the one tile being sampled across frames.
var _active_key                            # Variant: Vector3i or null
var _active_job: Dictionary = {}
var _active_done := false

func _ready() -> void:
	if not ENABLED:
		return
	# Warm the noise/id/palette singletons on THIS (main) thread before any sampling —
	# the same discipline module_world.setup() uses, so it holds on the fallback path
	# where the module never ran (LOD-DESIGN §2.6).
	TerrainConfig.warm_up()
	FarPalette.ensure_ready()
	_material = make_material()
	set_process(true)

## The one shared far material (LOD-DESIGN §2.4). Static so ShaderPrewarm warms the
## exact same material/vertex-format pipeline this node draws with.
static func make_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0                # no sun in the scene → specular is moot; keep it off
	# CULL_DISABLED (was CULL_BACK): the far surface is a single-sided heightmap whose triangle
	# winding must otherwise exactly match Godot's front-face convention — a fragile dependency that,
	# if backwards, culls EVERY ground tile and leaves only the vertical skirt walls visible (a "grid
	# of vertical planes"). Double-siding a distant low-poly mesh is negligible and removes the
	# winding dependency entirely; there is no sun, so the missing back-face lighting is moot.
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

# --- streaming entry point (LOD-DESIGN §4.1) ----------------------------------

## Re-evaluate the desired tile set for the player position `pos`, but only when the
## XZ evaluation point has moved ≥ FAR_RECENTER_STEP (the 64 m step IS the hysteresis).
## Called every physics tick from WorldManager.update_streaming.
func update_center(pos: Vector3) -> void:
	if not ENABLED:
		return
	var e := Vector2(pos.x, pos.z)
	if _has_eval and e.distance_to(_eval_point) < FAR_RECENTER_STEP:
		return
	_eval_point = e
	_has_eval = true
	_recompute(e)

## LOD-DESIGN §1.6 extension point for future distant-edit visibility. Specified but
## deliberately NOT implemented in v1 (a dug pit subtends < 0.3° at 192 m).
func invalidate_tiles(_region: Rect2i) -> void:
	pass

# --- desired-set computation + reconciliation ---------------------------------

func _recompute(e: Vector2) -> void:
	_desired = _apply_caps(_compute_desired(e))
	# Enqueue keys not yet live and not the active job, coarse ring first then nearest
	# (so the full horizon silhouette appears first — LOD-DESIGN §2.6).
	var to_build: Array = []
	for key in _desired:
		if _live.has(key) or key == _active_key:
			continue
		to_build.append(key)
	var desired := _desired
	to_build.sort_custom(func(a, b):
		var ra: int = desired[a]["ring"]
		var rb: int = desired[b]["ring"]
		if ra != rb:
			return ra > rb
		return float(desired[a]["min_dist"]) < float(desired[b]["min_dist"]))
	_queue = to_build
	# Free stale tiles, but only where the replacement coverage is already live (no hole).
	_try_evictions()

## The desired tile set for evaluation point `e`: every ring's tiles whose AABB
## intersects that ring's annulus, excluding any tile entirely inside INNER_HOLE
## (covered by the near voxel field). LOD-DESIGN §1.5.
func _compute_desired(e: Vector2) -> Dictionary:
	var desired: Dictionary = {}
	for ring in range(RING_TABLE.size()):
		var rd: Dictionary = RING_TABLE[ring]
		var tile := float(rd["tile_m"])
		var outer := float(rd["outer_m"])
		var inner := INNER_HOLE if ring == 0 else float(RING_TABLE[ring - 1]["outer_m"])
		var tris := _tris_per_tile(rd)
		var lo_x := floori((e.x - outer) / tile)
		var hi_x := floori((e.x + outer) / tile)
		var lo_z := floori((e.y - outer) / tile)
		var hi_z := floori((e.y + outer) / tile)
		for tx in range(lo_x, hi_x + 1):
			for tz in range(lo_z, hi_z + 1):
				var blo := Vector2(float(tx) * tile, float(tz) * tile)
				var bhi := blo + Vector2(tile, tile)
				var maxd := _box_max_dist(e, blo, bhi)
				if maxd <= INNER_HOLE:
					continue                        # entirely inside the near-field hole
				var mind := _box_min_dist(e, blo, bhi)
				if mind <= outer and maxd >= inner:
					desired[Vector3i(ring, tx, tz)] = {
						"ring": ring, "tc": Vector2i(tx, tz), "min_dist": mind, "tris": tris,
					}
	return desired

## Enforce the hard caps by trimming outermost-first (LOD-DESIGN §1.2 / §4.4): sort by
## distance, keep while under tile/draw/tri caps, drop the rest and warn once.
func _apply_caps(desired: Dictionary) -> Dictionary:
	var keys := desired.keys()
	keys.sort_custom(func(a, b):
		return float(desired[a]["min_dist"]) < float(desired[b]["min_dist"]))
	var kept: Dictionary = {}
	var tris := 0
	var trimmed := false
	for key in keys:
		var info: Dictionary = desired[key]
		var t: int = info["tris"]
		if kept.size() >= FAR_MAX_TILES or kept.size() >= FAR_MAX_DRAWS or tris + t > FAR_MAX_TRIS:
			trimmed = true
			break                                   # sorted asc → everything left is farther
		kept[key] = info
		tris += t
	if trimmed and not _warned_caps:
		_warned_caps = true
		push_warning("[FarTerrain] desired set exceeded caps (tiles/%d draws/%d tris/%d); trimmed outermost."
			% [FAR_MAX_TILES, FAR_MAX_DRAWS, FAR_MAX_TRIS])
	return kept

static func _tris_per_tile(rd: Dictionary) -> int:
	var grid: int = rd["grid"]
	return grid * grid * 2 + 8 * grid           # surface + 4 edges × grid segments × 2

static func _box_min_dist(e: Vector2, lo: Vector2, hi: Vector2) -> float:
	var dx := maxf(maxf(lo.x - e.x, e.x - hi.x), 0.0)
	var dz := maxf(maxf(lo.y - e.y, e.y - hi.y), 0.0)
	return sqrt(dx * dx + dz * dz)

static func _box_max_dist(e: Vector2, lo: Vector2, hi: Vector2) -> float:
	var dx := maxf(absf(e.x - lo.x), absf(e.x - hi.x))
	var dz := maxf(absf(e.y - lo.y), absf(e.y - hi.y))
	return sqrt(dx * dx + dz * dz)

# --- no-hole eviction (LOD-DESIGN §4.2) ---------------------------------------

func _try_evictions() -> void:
	for key in _live.keys():
		if _desired.has(key):
			continue
		if _covered_by_live(key):
			_free_tile(key)

## True iff every desired tile overlapping `stale_key`'s footprint is already live —
## so freeing it opens no hole. A stale tile overlapping nothing desired is trivially safe.
func _covered_by_live(stale_key: Vector3i) -> bool:
	var srd: Dictionary = RING_TABLE[stale_key.x]
	var stile := float(srd["tile_m"])
	var slo := Vector2(float(stale_key.y) * stile, float(stale_key.z) * stile)
	var shi := slo + Vector2(stile, stile)
	for dk in _desired:
		if _live.has(dk):
			continue
		var drd: Dictionary = RING_TABLE[dk.x]
		var dtile := float(drd["tile_m"])
		var dlo := Vector2(float(dk.y) * dtile, float(dk.z) * dtile)
		var dhi := dlo + Vector2(dtile, dtile)
		if slo.x < dhi.x and shi.x > dlo.x and slo.y < dhi.y and shi.y > dlo.y:
			return false                            # an overlapping desired tile is not live yet
	return true

func _free_tile(key) -> void:
	var mi = _live.get(key)
	_live.erase(key)
	_live_tris.erase(key)
	if is_instance_valid(mi):
		remove_child(mi)
		mi.queue_free()

# --- build queue + per-frame budget (LOD-DESIGN §2.6) -------------------------

func _process(_delta: float) -> void:
	if not ENABLED:
		return
	_drain(FAR_BUILD_BUDGET_MS)

func _drain(budget_ms: float) -> void:
	var t0 := Time.get_ticks_usec()
	var commits := 0
	while commits < MAX_COMMITS_PER_FRAME:
		if _active_key == null and not _start_next():
			break
		while not _active_done:
			if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
				return                              # out of budget; resume this job next frame
			_active_done = FarMeshBuilder.sample_step(_active_job, SAMPLE_STEP_COLUMNS)
		_commit(_active_key, _active_job)           # the ≤ 1/frame ArrayMesh upload
		_active_key = null
		_active_job = {}
		_active_done = false
		commits += 1
		_try_evictions()

## Pop the next still-valid queued key and begin its sampling job. Returns false when
## the queue holds nothing to build (coalescing: superseded / already-live keys dropped).
func _start_next() -> bool:
	while not _queue.is_empty():
		var key = _queue.pop_front()
		if _live.has(key) or not _desired.has(key):
			continue
		_active_key = key
		_active_job = FarMeshBuilder.begin_tile(key.x, Vector2i(key.y, key.z))
		_active_done = false
		return true
	return false

func _commit(key, job: Dictionary) -> void:
	var arrays := FarMeshBuilder.assemble(job)
	var mesh := FarMeshBuilder.build_mesh(arrays, _material)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	_live[key] = mi
	_live_tris[key] = int(arrays["tri_count"])

# --- test / diagnostic hooks (verify_feature) ---------------------------------

## Synchronously build the whole queued/active set with no budget — for headless verify.
func drain_for_test() -> void:
	while true:
		if _active_key == null and not _start_next():
			break
		while not _active_done:
			_active_done = FarMeshBuilder.sample_step(_active_job, 1 << 20)
		_commit(_active_key, _active_job)
		_active_key = null
		_active_job = {}
		_active_done = false
		_try_evictions()

func live_tile_count() -> int:
	return _live.size()

func live_keys() -> Array:
	return _live.keys()

func desired_keys() -> Array:
	return _desired.keys()

func desired_info(key) -> Dictionary:
	return _desired.get(key, {})

func total_live_tris() -> int:
	var n := 0
	for k in _live_tris:
		n += int(_live_tris[k])
	return n

func has_pending_build() -> bool:
	return _active_key != null or not _queue.is_empty()
