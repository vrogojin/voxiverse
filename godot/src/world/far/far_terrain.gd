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
const INNER_HOLE := 192.0                 # flat: RENDER_RADIUS_BLOCKS − 64 (near voxel field covers 0..256)
## Curved near hole: the planet streams a smaller near voxel field (CURVED_RENDER_RADIUS_BLOCKS = 128),
## so the far LOD must start filling closer in — just inside the near radius (128 − 16 overlap) so no
## gap-ring opens between the near field and ring 0. inner_hole() picks the right one per world mode.
const INNER_HOLE_CURVED := 112.0
static func inner_hole() -> float:
	return INNER_HOLE if CubeSphere.FLAT_WORLD else INNER_HOLE_CURVED

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
# COSMOS M4 (§4/§8): the seam-cross HANDOFF TURBO. At a home-face flip WorldManager opens a bounded
# time window during which _drain runs at a raised main-thread budget + commit rate and the build stays
# NEAREST-first, so the new frame's ring-0 tiles under the player appear in ~0.2–0.5 s while the near
# field restreams behind them. It changes only WHEN tiles build, never WHAT — the desired set, caps, and
# per-tile geometry are unchanged, so it costs bounded main-thread ms and ZERO memory (the §0 never-OOM
# invariant). Flip HANDOFF_ENABLED to false to restore today's post-bug-B behaviour byte-for-byte (§7
# rung 2, the SMOOTHING_ENABLED discipline); the §5.4 edit re-mirror in WorldManager is independent of it.
const HANDOFF_ENABLED := true
const HANDOFF_BUDGET_MS := 8.0             # _drain sampling budget while the handoff window is open (vs 3.0)
const HANDOFF_COMMITS := 2                 # ArrayMesh uploads per frame while open (vs 1)
const HANDOFF_MAX_SECONDS := 10.0          # hard close of the window (starvation backstop / headless / fallback path)
const SAMPLE_STEP_COLUMNS := 1024          # profiling slice size (LOD-DESIGN §2.6)
const FAR_MAX_TILES := 120                 # hard caps — trim outermost-first, warn
## Raised from 450k: double-sided skirts (LOD-DESIGN §1.4) lift per-tile tris, so the pure
## geometric worst case (every tile full-mesh, worst boundary alignment, no ocean collapse)
## is ≈ 554k (measured by sweep); the mountain-foothill spawn is ≈ 478k. 600k clears that
## absolute worst with headroom so no inland mountain position trims the horizon silhouette,
## while still catching genuine runaway. Web-safe: skirt-doubling adds only INDICES (16-bit,
## ≤ 4,485 verts/tile unchanged), so GPU memory stays in the 10–20 MB envelope (LOD-DESIGN
## §1.2/§6.6); tile/draw counts are separately capped below (89 desired max < 96 draws).
const FAR_MAX_TRIS := 600000
const FAR_MAX_DRAWS := 96
const FAR_CAMERA_FAR := 3840.0             # player.gd camera.far override when ENABLED
const FOG_BEGIN := 115.0                   # main.gd fog when ENABLED (LOD-DESIGN §3.4)
const FOG_END := 2750.0
const FOG_CURVE := 0.38

# --- runtime state ------------------------------------------------------------
var _material: Material                     # StandardMaterial3D (FLAT) or the CosmosBend far ShaderMaterial (curved)
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

# COSMOS M3: after a home-face flip re-bases the chart onto a neighbour face, this node's global-index
# frame (its `position` offset) jumps by a large delta. The OLD-HOME-FACE tiles from the old frame are
# reparented here as a WORLD-FIXED cover so the horizon never blanks while the new frame streams in; it
# is freed the moment the new frame has produced coverage (or after COVER_MAX_SECONDS, whichever first).
# Only OLD-HOME-FACE tiles are kept: a tile straddling a face edge (neighbouring side face) or the corner
# quadrant was placed by the OLD home face's unfold convention, which differs from the new one, so it
# would render VISIBLY DISPLACED against the (correctly restreamed) near field — Fable's bug-B root
# cause. Those tiles are dropped here, not stashed, and heal from fresh nearest-first tiles behind the
# cover. FLAT_WORLD / no chart never flips, so this stays null and the node stays at position ZERO.
var _cover: Node3D = null
## Cover lifetime backstop (s). The queue-drained retirement below can be starved indefinitely by a
## moving player (every 64 m re-enqueues the whole far set under a 3 ms/frame budget), so force-retire
## after this long regardless. With the freeze fixed the fresh frame rebuilds in a couple of seconds.
const COVER_MAX_SECONDS := 12.0
var _cover_age := 0.0

# COSMOS M4 (§5.1): seconds left in the open handoff turbo window (0 = closed). Set by begin_handoff at a
# flip, cleared by end_handoff at the near-ramp handshake, and self-decremented in _process so a missed
# handshake (headless, or the fallback path that never calls end_handoff) still closes it at
# HANDOFF_MAX_SECONDS. Never set in FLAT_WORLD play — begin_handoff is only reached through a flip.
var _handoff_left := 0.0

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
##
## COSMOS Stage 3: in curved mode return the CosmosBend far ShaderMaterial so distant tiles bend with
## the planet exactly like the near voxel field (no near-bent/far-flat seam at the hole). FLAT_WORLD
## keeps the StandardMaterial3D below byte-identical — and because ShaderPrewarm builds through THIS
## function, the bend pipeline is warmed at load, not on the first far tile drawn in gameplay.
static func make_material() -> Material:
	if not CubeSphere.FLAT_WORLD:
		CosmosBend.ensure_globals()
		var sm := ShaderMaterial.new()
		sm.shader = CosmosBend.far_shader()
		return sm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0                # no sun in the scene → specular is moot; keep it off
	# CULL_BACK with the top-surface winding fixed to face UP (see FarMeshBuilder). The original
	# winding faced DOWN: CULL_BACK culled the whole surface → only the vertical skirts showed ("grid
	# of bars"); CULL_DISABLED then rendered its underside ("terrain from underground"). With the
	# winding reversed, CULL_BACK draws the correct top surface viewed from above and drops the
	# underside/back-face clutter. The SKIRTS are made double-sided in geometry (both windings, see
	# FarMeshBuilder._wall_quad), NOT via the material — so the top stays single-sided and cheap
	# while the skirt still seals rising-boundary cracks from the centre viewer (LOD-DESIGN §1.4).
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m

# --- streaming entry point (LOD-DESIGN §4.1) ----------------------------------

## Re-evaluate the desired tile set for the player position `pos`, but only when the
## XZ evaluation point has moved ≥ FAR_RECENTER_STEP (the 64 m step IS the hysteresis).
## Called every physics tick from WorldManager.update_streaming.
func update_center(pos: Vector3) -> void:
	if not ENABLED:
		return
	# COSMOS: this node lives in the GLOBAL-index frame (its `position` is −(i_org, 0, j_org), kept in
	# lockstep with the near voxel field by WorldManager on every re-anchor/flip). So the eval point —
	# and thus every tile lattice point sampled from it — must be expressed in that same global frame,
	# `player_world − position`, exactly the column the near field renders at this world spot. In
	# FLAT_WORLD `position` is permanently ZERO, so this is `Vector2(pos.x, pos.z)` byte-for-byte.
	var e := Vector2(pos.x - position.x, pos.z - position.z)
	if _has_eval and e.distance_to(_eval_point) < FAR_RECENTER_STEP:
		return
	_eval_point = e
	_has_eval = true
	_recompute(e)

## LOD-DESIGN §1.6 extension point for future distant-edit visibility. Specified but
## deliberately NOT implemented in v1 (a dug pit subtends < 0.3° at 192 m).
func invalidate_tiles(_region: Rect2i) -> void:
	pass

## COSMOS M3 home-face flip handoff (Fable Stage 1 + bug-B fix). The chart re-based onto a neighbour
## face, so this node's global-index frame jumped to `new_pos` = −(i_org, 0, j_org) on the new face.
## Only OLD-HOME-FACE tiles stay WORLD-correct across the flip; edge-straddling and corner-quadrant
## tiles were placed by the old unfold convention and would render displaced against the restreamed
## near field, so we KEEP only fully-in-old-face tiles as a world-fixed cover (horizon stays up behind
## the new frame) and FREE the rest. Then adopt the new frame and force a full recompute. Main-thread
## only, touches no voxel worker. No-op with no live tiles.
func rebase_to(new_pos: Vector3) -> void:
	if not ENABLED:
		return
	var old_pos := position
	# Drop any prior cover first (its terrain is now two flips stale — no longer trustworthy).
	if _cover != null and is_instance_valid(_cover):
		_cover.queue_free()
	_cover = null
	_cover_age = 0.0
	if not _live.is_empty():
		var n := CubeSphere.n_for(CubeSphere.HOME_BODY)   # face-edge cells; old-frame global range is [0, n)
		var cover := Node3D.new()
		cover.name = "FarStaleCover"
		add_child(cover)
		# Keep every reparented tile at its exact current WORLD position. After self.position = new_pos
		# below, the cover's world origin must remain old_pos, so cover.position = old_pos − new_pos and
		# each tile's local (old-frame global) coords are left untouched: world = new_pos + (old_pos −
		# new_pos) + global_old = old_pos + global_old, its original world spot.
		cover.position = old_pos - new_pos
		var kept := 0
		for key in _live.keys():
			var mi = _live[key]
			if not is_instance_valid(mi):
				continue
			remove_child(mi)
			if _tile_fully_in_face(key, n):
				cover.add_child(mi)                          # trustworthy old-home-face tile → cover
				kept += 1
			else:
				mi.queue_free()                              # edge/corner tile → displaced under new frame; drop
		if kept > 0:
			_cover = cover
		else:
			cover.queue_free()                               # nothing trustworthy to bridge with
	_live.clear()
	_live_tris.clear()
	_desired.clear()
	_queue.clear()
	_active_key = null
	_active_job = {}
	_active_done = false
	position = new_pos
	_has_eval = false                          # next update_center recomputes in the new frame

# COSMOS M4 (§5.1): the handoff turbo window. begin_handoff is called by WorldManager right after
# rebase_to at a flip; end_handoff at the near-ramp handshake (module ramp_done()). handoff_active gates
# BOTH the raised _drain budget/commit rate (§2.2 throughput) and the nearest-first sort (§2.2 priority).
# Opening a window on an already-open one simply resets its clock — nothing stacks (§5.2 re-entrancy). It
# spends only main-thread ms; the desired set, caps and per-tile geometry are untouched, so ZERO memory.
func begin_handoff() -> void:
	if ENABLED and HANDOFF_ENABLED:
		_handoff_left = HANDOFF_MAX_SECONDS

func end_handoff() -> void:
	if _handoff_left > 0.0:
		print("[far] handoff window closed (handshake) after %.1fs" % (HANDOFF_MAX_SECONDS - _handoff_left))
	_handoff_left = 0.0

func handoff_active() -> bool:
	return _handoff_left > 0.0

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
	# Normally coarse ring first (full horizon silhouette appears first — LOD-DESIGN §2.6). But while a
	# post-flip cover is bridging OR the M4 handoff window is open, sort NEAREST-first instead: ring 0
	# abuts the near field where the handoff mismatch is most visible, so healing it first puts real
	# terrain under the player fastest and lets the cover retire sooner (Fable bug-B / COSMOS M4 §2.2).
	var cover_active := _cover != null or handoff_active()
	to_build.sort_custom(func(a, b):
		if cover_active:
			return float(desired[a]["min_dist"]) < float(desired[b]["min_dist"])
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
	var hole := inner_hole()                 # flat 192 / curved 112 (matches the near voxel radius)
	for ring in range(RING_TABLE.size()):
		var rd: Dictionary = RING_TABLE[ring]
		var tile := float(rd["tile_m"])
		var outer := float(rd["outer_m"])
		var inner := hole if ring == 0 else float(RING_TABLE[ring - 1]["outer_m"])
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
				if maxd <= hole:
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
	# surface (grid²×2) + double-sided skirts (4 edges × grid segments × 2 tris × 2 faces).
	return grid * grid * 2 + 16 * grid

static func _box_min_dist(e: Vector2, lo: Vector2, hi: Vector2) -> float:
	var dx := maxf(maxf(lo.x - e.x, e.x - hi.x), 0.0)
	var dz := maxf(maxf(lo.y - e.y, e.y - hi.y), 0.0)
	return sqrt(dx * dx + dz * dz)

static func _box_max_dist(e: Vector2, lo: Vector2, hi: Vector2) -> float:
	var dx := maxf(absf(e.x - lo.x), absf(e.x - hi.x))
	var dz := maxf(absf(e.y - lo.y), absf(e.y - hi.y))
	return sqrt(dx * dx + dz * dz)

## True iff tile `key`'s global-index footprint lies ENTIRELY within the current home face's cell range
## [0, n) on both axes — i.e. it is pure old-home-face content that survives a flip world-unchanged. A
## tile that straddles a face edge (folds onto a neighbouring side face) or the corner quadrant is
## placed by the home face's unfold CONVENTION, which differs after the flip, so it must not be stashed
## as cover (Fable bug-B). Footprint units are blocks = tile_m (1 m per cell), same as n.
static func _tile_fully_in_face(key: Vector3i, n: int) -> bool:
	var tile := float(RING_TABLE[key.x]["tile_m"])
	var lo_x := float(key.y) * tile
	var lo_z := float(key.z) * tile
	return lo_x >= 0.0 and lo_x + tile <= float(n) and lo_z >= 0.0 and lo_z + tile <= float(n)

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

func _process(delta: float) -> void:
	if not ENABLED:
		return
	# COSMOS M4 (§5.1): tick the handoff window down first, then drain at the turbo budget while it is
	# open. It self-closes at HANDOFF_MAX_SECONDS so a missed WorldManager handshake (headless, or the
	# fallback path which never calls end_handoff) never leaves it stuck open — a timeout closure is the
	# telemetry anomaly signal (§9.2 step 4). The default 3.0 ms / 1-commit constants are untouched, so
	# flat play (which never opens a window) is byte-identical.
	if _handoff_left > 0.0:
		_handoff_left = maxf(_handoff_left - delta, 0.0)
		if _handoff_left == 0.0:
			print("[far] handoff window closed (timeout) after %.1fs" % HANDOFF_MAX_SECONDS)
	_drain(HANDOFF_BUDGET_MS if handoff_active() else FAR_BUILD_BUDGET_MS)
	# Retire the post-flip stale cover once the new frame has produced real coverage (queue drained AND
	# at least one new tile is live), OR after COVER_MAX_SECONDS as a starvation backstop (a moving
	# player re-enqueues the far set faster than the 3 ms/frame budget drains it, so "queue drained"
	# can never arrive) — so the handoff shows no blank yet nothing lingers/misaligns indefinitely.
	if _cover != null:
		_cover_age += delta
		var covered := _live.size() > 0 and not has_pending_build()
		if covered or _cover_age >= COVER_MAX_SECONDS:
			if is_instance_valid(_cover):
				_cover.queue_free()
			_cover = null

func _drain(budget_ms: float) -> void:
	var t0 := Time.get_ticks_usec()
	var commits := 0
	# COSMOS M4 (§2.2): raise the per-frame commit ceiling while the handoff window is open so the
	# nearest-first ring-0 tiles reach the GPU sooner; back to 1/frame in steady state.
	var commit_limit := HANDOFF_COMMITS if handoff_active() else MAX_COMMITS_PER_FRAME
	while commits < commit_limit:
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
