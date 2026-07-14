class_name FacetLodMesher
extends Node3D
## COSMOS FP-M2b (docs/COSMOS-FP-M2-DESIGN.md §5, §6.2, §7.4) — the LOD-mesh layer that REPLACES the FacetFarRing
## coloured quads for the near rings of facets around the active facet. A child of module_world's PlanetRoot (@
## identity), so a crossing's ONE PlanetRoot.transform write re-places every LOD mesh rigidly (zero rebuild). Owns
## exactly ONE FacetLodBuilder (the M2a off-terrain build primitive — one persistent background Thread, NEVER the
## voxel worker pool). Each covered facet's LOD mesh lives under a LodFacet_<fid> node @ facet_transform(fid); a
## per-tile MeshInstance is placed at Transform3D(Basis.from_scale(ONE·s), tile-lattice-corner) so uniform scale s
## + lattice translation land the megablocks exactly where the live terrain's blocks would (§8 / G-M2-FRAME).
##
## M2b SCOPE (static): tier assignment is a fixed per-ring rule (§13) — ring-1 → ℓ1, ring-2 → ℓ2, ring-3 → ℓ3,
## beyond → the ℓ=∞ coloured quad (still drawn by the FacetFarRing, the universal fallback). The camera-driven SSE
## selector, the request-grant budgeter and the load-adaptive controller are M2c — NOT here. The Z1-hybrid pool
## policy / promote-demote is M2d. Here the ladder pace is immediate; only the NEVER-OOM caps (§6.2/§11) bind.
##
## NEVER-OOM: every cap below is HARD and asserted headless (G-M2-CAPS). Admission is estimate-based + synchronous
## (§1.3 per-tier estimates) so an over-cap request storm can never enqueue past the ceiling; LRU evicts only
## NON-wanted facets (a still-wanted facet degrades its grant one tier instead of evicting another wanted one), and
## an evicted facet drops OUT of covered_fids() so the far-ring quad stays behind it — never a hole. The ridge
## apron (§7.4) is counted in the SAME tri/byte ledgers (bounded ≈ 128 aprons ≈ 65k tris / ≤ 2 MB worst).
##
## Everything here is DEAD unless CubeSphere.FP_M2_LOD (requires FACETED + FP_M1_POOL + the module binary). With
## the flag off the mesher is never created, tick() never runs, and covered_fids() is never consulted → the game
## is byte-identical to FP-M1c (FLAT 6027/0; faceted pool 137/0).

const FLB := preload("res://src/world/facet_lod_builder.gd")

# ---- policy consts (§5 — asserted by verify_fp_m2 G-M2-CAPS) ----
const LOD_MAX_TIER := 3            # shipped tiers ℓ∈{1..3}; the quad is the ℓ=∞ tier (ℓ0 is live-terrain only)
const LOD_APPLY_BUDGET_MS := 2.0   # main-thread per-frame apply budget (never a synchronous whole-facet apply)
const LOD_MAX_FACETS := 64         # HARD cap: facets holding an applied LOD mesh (+ in-flight builds)
const LOD_MAX_TRIS := 3_000_000    # HARD cap: total LOD triangles (meshes + aprons)
const LOD_MAX_BYTES_MB := 96       # HARD cap: CPU-side mesh bytes (§11 ledger; ×1024×1024 below)
const LOD_QUEUE_MAX_JOBS := 16     # tiles queued but not yet building (feed-forward bound; M2c budgeter refines)
const LOD_IDLE_DEMOTE_S := 30.0    # (M2c uses proactively; present here for the const ledger)
const LOD_COVER_RINGS := 3         # LEGACY (M2b static rule) — SUPERSEDED by the M2c SSE selector; kept for the const ledger
const APRON_SKIRT := 1             # outer-skirt depth in s_max units (tuck under megablock walls)
const LOD_REQUESTS_PER_TICK := 2   # new facet builds admitted per tick — PACES probe-generator creation + enqueues
                                   # across frames (never a set-time/crossing-time flood of ~48 generators, §6.4)
const LOD_PENDING_MAX := 48        # W5 bound: drained-but-unapplied tiles retained before draining pauses (each is
                                   # est-reserved via _building, so this is the backstop against unbounded _pending growth)

# ---- state ----
var _mod: Object = null                    # module_world (probe generators + baked library + pool membership)
var _builder = null                        # the ONE FacetLodBuilder this mesher owns
var _active_fid := -1
var _cam: Camera3D = null                   # M2c selector input (stored, unused in M2b)
var _controller = null                      # M2c/d StreamLoadController (stored, unused in M2b)
var _apron_mat: StandardMaterial3D = null

var _cache: Dictionary = {}                 # fid -> {lod,node,tris,bytes,last_want_ms, apron:{slot->{mi,s_max,tris,bytes}}}
var _building: Dictionary = {}              # fid -> {lod,expected,got,staging:Node3D,tris,bytes,est_tris,est_bytes}
var _apron_building: Dictionary = {}        # "owner:slot" -> {s_max,tris,bytes} (in-flight apron jobs + their ledger reservation, W4)
var _want: Dictionary = {}                  # fid -> desired tier (the target rung; recomputed on active/pool change)
var _promoting: Dictionary = {}             # M2d (§9.1): fids whose LOD mesh is HELD while their live terrain streams —
                                            # NOT evicted/idled/rebuilt until WorldManager calls evict() on seam-band-meshed
                                            # (or the promote timeout). Cleared when the fid leaves the pool or goes active.
var _pending: Array = []                    # drained-but-not-yet-applied items (carried across apply budgets)
var _ledger_tris := 0                       # running sum: applied + in-flight (estimated) triangles
var _ledger_bytes := 0                      # running sum: applied + in-flight (estimated) bytes
var _epoch_seq := 0                         # W9(c): monotonic build-epoch stamp — a DRAINED tile is applied only if
                                            # its epoch matches the facet's CURRENT in-flight build (a rapid tier
                                            # ping-pong at the SAME lod cannot premature-swap a stale/holey partial)

# W8: per-fid RENDER-space geometry cache. facet_transform(fid)·centre and the outward normal are FROZEN atlas data;
# only the mesher's own global_transform (PlanetRoot @ T_active⁻¹) changes, and only on a CROSSING. So the planet-
# ABSOLUTE centre/normal are computed ONCE (facet geometry never moves) and the per-frame selector just maps them
# through global_transform — no ~3456 Transform3D constructions per frame on the main thread (the FP-M2c cost trap).
var _geo_cached := false
var _abs_centre := PackedVector3Array()     # planet-absolute facet centres, indexed by fid
var _abs_normal := PackedVector3Array()     # planet-absolute facet outward normals, indexed by fid

# C2/C3 — the admission estimate is an UPPER FENCE derived from the facet's ACTUAL tile count × a per-tile worst-case
# (a flat facet's ℓ1 top alone is 16 tiles × 2048 = 32768 tris, so a fixed 30000 UNDER-counted — admission could then
# over-admit). _PER_TILE_TRIS is the per-surface-tile fence (a full TILE_MAX² top layer × a rugged-wall margin); bytes
# are COUPLED to tris at the builder's own 140 B/tri (verts·64 + tris·3·4 ≈ 140·tris), so the two cannot drift. This
# fence bounds only IN-FLIGHT concurrency; a swap reconciles est→actual (actual ≤ fence) so the applied ledger tracks
# real mesh bytes, and C1 re-checks the caps on the REAL bytes at spend regardless.
const _BYTES_PER_TRI := 140                 # verts·64 + tris·3·4 ≈ 140·tris (kept == the builder's byte formula, C3)
const _PER_TILE_TRIS := FLB.TILE_MAX * FLB.TILE_MAX * 3   # 32²·3 = 3072: full top layer (2048) × 1.5 rugged-wall margin
const _APRON_EST_TRIS := 800                # W4 apron reservation fence: ≤500 tris at ℓ1 (§7.4) + margin; bytes ×140

# ============================ setup / teardown ============================

## Wire the builder + warm the off-thread readers. Returns false (safe no-op) when the flag is off or the module /
## mesher class is unavailable — module_world then leaves _lod_mesher null and the whole LOD path is dead.
func setup(module_world: Object) -> bool:
	if not CubeSphere.FP_M2_LOD:
		return false
	if module_world == null:
		return false
	_mod = module_world
	# W9(a) — freeze EVERY reader the builder thread touches BEFORE the thread exists (order matters: a reader warmed
	# after the thread starts is a first-touch race). generate_block's readers (frozen atlas/edge/noise/catalog tables)
	# + the APRON path's FarPalette tints, TerrainConfig.profile_at_dir noise singletons, and the FacetAtlas packed
	# arrays. All idempotent + frozen after this → the builder is one more pure reader (§4.3/§7.4 thread-safety class).
	FarPalette.ensure_ready()
	TerrainConfig.warm_up()
	if not FacetAtlas.is_ready():
		FacetAtlas.warm_up()
	_builder = FLB.new()
	if not bool(_builder.setup(module_world)):
		_builder = null
		return false
	_apron_mat = StandardMaterial3D.new()
	_apron_mat.vertex_color_use_as_albedo = true
	_apron_mat.cull_mode = BaseMaterial3D.CULL_DISABLED     # winding-agnostic (the dihedral turn can flip a strip)
	_apron_mat.roughness = 1.0
	return true

## M2c selector input (fov, viewport, camera position). Stored now; the SSE selector that consumes it is M2c.
func set_camera(cam: Camera3D) -> void:
	_cam = cam

## M2c/d admission controller. Stored now; the credit that scales apply-ms + grants is M2c.
func set_load_controller(c) -> void:
	_controller = c

## Join the builder thread and free every LOD node. MUST run before this node (or its PlanetRoot parent) is freed —
## a bare queue_free would leak the running builder Thread. module_world calls this on pool_reset + _exit_tree.
func shutdown() -> void:
	if _builder != null:
		_builder.shutdown()
		_builder = null
	for fid in _cache.keys():
		var n: Node3D = _cache[fid]["node"]
		if n != null and is_instance_valid(n):
			n.queue_free()
	for fid in _building.keys():
		var s: Node3D = _building[fid]["staging"]
		if s != null and is_instance_valid(s):
			s.free()                                        # never entered the tree → free() not queue_free()
	_cache.clear(); _building.clear(); _apron_building.clear(); _want.clear(); _promoting.clear(); _pending.clear()
	_ledger_tris = 0; _ledger_bytes = 0

## W9(b) — self-join the builder Thread on PREDELETE regardless of WHO frees the node (a bare free of this node or its
## PlanetRoot parent that skipped shutdown() would otherwise leak the running Thread). shutdown() is idempotent, so a
## normal shutdown()-then-free path calls it twice harmlessly (the second call sees _builder == null and no-ops).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		shutdown()

# ============================ tier policy (SSE SELECTOR + request-grant BUDGETER, M2c §6) ============================

# §1.3 per-tier build-time estimates (native seconds) — the FIXED, load-independent est-seconds admission bound
# (§6.5.7: deterministic, machine-speed cannot perturb a gate; the EWMA self-calibration of §6.4 is live-only polish,
# deliberately NOT wired so the headless gates stay bit-reproducible). The budgeter denies a grant that would push
# the in-flight sum past CubeSphere.LOD_QUEUE_MAX_EST_S.
const _EST_BUILD_S := {1: 15.0, 2: 4.0, 3: 1.0}

## A crossing / pool change happened. Under the SSE selector the target rung is pure camera math (recomputed every
## tick from the moving camera), so this just re-points the active facet + refreshes the want set and drops any facet
## the new geometry no longer wants (cheap unload; the far-ring quad covers it). No build is enqueued here — tick()'s
## budgeter paces every grant, so a crossing never floods ~48 probe-generator creations onto the crossing frame.
func set_active_facet(active: int) -> void:
	_active_fid = active
	# M2d (§9.1): the new active facet must NEVER carry a held LOD mesh (it is now the live editable terrain). Force-drop
	# any promote-hold + cached mesh for it, so a crossing to a still-promoting `to` cannot leave double geometry on the
	# active facet. (Normally the promote-hold is already evicted during the D_WARM approach — this is the backstop.)
	_promoting.erase(active)
	if _cache.has(active):
		evict(active)
	_recompute_wants()
	for fid in _cache.keys():
		if not _want.has(fid) and not _promoting.has(fid):     # M2d: never evict a promoting facet's held cover
			evict(fid)
	for fid in _building.keys():
		if not _want.has(fid) and not _promoting.has(fid):
			_cancel_build(fid)

## The live pool (spawn/retire/redesignate) changed — a facet may have gone live (exclude it) or freed (re-cover).
func notify_pool_changed() -> void:
	_recompute_wants()
	for fid in _cache.keys():
		if not _want.has(fid) and not _promoting.has(fid):     # M2d: hold a promoting facet's LOD cover (no gap, §9.1)
			evict(fid)

## M2d (§9.1) — PROMOTE: facet `fid` just went LIVE (pool_spawn). HOLD its LOD mesh (do not evict/idle/rebuild it) so
## there is no gap while its full-res terrain streams; WorldManager calls evict(fid) once the terrain's seam band has
## meshed (or the PROMOTE_EVICT_MAX_S timeout). Everything else (excluding the now-live fid from `_want`, re-covering
## any freed facet) is exactly notify_pool_changed — this is that, made hold-aware for `fid`.
func on_promote(fid: int) -> void:
	if fid >= 0:
		_promoting[fid] = true
	notify_pool_changed()                                     # exclude the now-live fid from _want; hold protects its mesh

## M2d — lift the promote HOLD without evicting the mesh: the facet retired before its live promote completed (it is a
## normal LOD neighbour again). WorldManager calls this when a pending promote's facet has left the pool. The mesh stays;
## only the no-evict protection lifts, so normal want-management (idle demote / LRU) resumes. evict() lifts the hold too.
func end_promote(fid: int) -> void:
	_promoting.erase(fid)

## M2d (§6.5.4) — sustained-overload relief (pause-first): coarsen ONE least-recently-wanted covered LOD facet by one
## tier (frees memory + future apply cost as it swaps). Live terrains are NEVER retired by the controller (pool
## retirement stays purely geometric). A no-op when every covered facet is already at the coarsest tier. Called by
## WorldManager only while StreamLoadController.demote_pressure() holds (≥ CTRL_OVERLOAD_SUSTAIN_S of credit-0 overload).
func demote_pressure_relief() -> void:
	var victim := -1
	var oldest := 0x7fffffffffffffff
	var vlod := 0
	for fid in _cache.keys():
		if _promoting.has(fid):
			continue                                           # never coarsen a facet whose live promote is in flight
		var lod := int(_cache[fid]["lod"])
		if lod >= LOD_MAX_TIER:
			continue                                           # already the coarsest LOD tier — nothing to give
		var w := int(_cache[fid]["last_want_ms"])
		if w < oldest:
			oldest = w; victim = fid; vlod = lod
	if victim >= 0:
		request(victim, vlod + 1)                              # rebuild one tier coarser

# ---- the SSE selector (§6.1/§6.2/§6.3): pure camera math, testable stand-alone (G-M2-SEL drives these directly) ----

## The continuous SSE tier ℓ_c for a facet at distance `d` under a vertical fov (radians) + viewport height (px):
## the largest ℓ with the projected megablock size p(ℓ)=(2^ℓ·h)/(2·d·tan(fov/2)) ≤ τ solves to
## ℓ_c = log2(τ · 2 · d · tan(fov/2) / h). Monotone increasing in d (a farther facet tolerates a coarser tier).
func sse_lc(d: float, fov_v_rad: float, viewport_h: float) -> float:
	var dd := maxf(d, 1.0)
	var coeff := 2.0 * dd * tan(fov_v_rad * 0.5) / maxf(viewport_h, 1.0)
	return log(CubeSphere.LOD_TAU_PX * coeff) / log(2.0)

## The stateless desired LOD tier = clamp(floor(ℓ_c), 1, LOD_MAX_TIER). A true desired 0 is representable ONLY by a
## live terrain (§6.1), so the LOD grant FLOOR is 1; the coarsest tier is capped at LOD_MAX_TIER (the quad is ℓ=∞).
func desired_tier(d: float, fov_v_rad: float, viewport_h: float) -> int:
	return clampi(int(floor(sse_lc(d, fov_v_rad, viewport_h))), 1, LOD_MAX_TIER)

## Hysteresis (§6.3): hold the current tier `cur` while ℓ_c stays inside its widened band [cur−HYST, cur+1+HYST];
## only when ℓ_c LEAVES the band does the tier snap to the stateless desired. A camera oscillating on a boundary
## flips at two different thresholds (promote-to-finer at cur−HYST, demote at cur+1+HYST) → no thrash. cur<1 (no
## mesh) → the desired directly. G-M2-SEL sweeps ℓ_c both ways and asserts ≤1 transition per direction.
func hyst_tier(lc: float, cur: int) -> int:
	var des := clampi(int(floor(lc)), 1, LOD_MAX_TIER)
	if cur < 1:
		return des
	var lo := float(cur) - CubeSphere.LOD_HYST_BAND
	var hi := float(cur) + 1.0 + CubeSphere.LOD_HYST_BAND
	if lc >= lo and lc <= hi:
		return cur                                              # inside the hysteresis band → hold
	return des

## The live camera driving the selector: the injected one (gates / M2d), else the viewport's active Camera3D so the
## selector is self-wiring on the live path. null in headless with no camera → the SSE recompute is a no-op (the
## caps/frame/seam gates drive request() directly and their wants are left untouched).
func _selector_camera() -> Camera3D:
	if _cam != null and is_instance_valid(_cam):
		return _cam
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

## The RENDER-space centre of facet `fid`: facet_transform(fid)·(centre lattice) is the planet-absolute centre; the
## mesher's own global_transform (it sits @ identity under PlanetRoot @ T_active⁻¹) maps it into render/world space,
## the SAME space the camera lives in — so distance is frame-consistent for every viewer and rides a crossing rigidly.
func _facet_render_centre(fid: int) -> Vector3:
	_ensure_geo_cache()
	if fid >= 0 and fid < _abs_centre.size():
		return global_transform * _abs_centre[fid]
	var cc: Vector2i = FacetAtlas.centre_cell(fid)
	return global_transform * (FacetAtlas.facet_transform(fid) * Vector3(float(cc.x), 0.0, float(cc.y)))

## SSE want recompute (§6.4.1): every front-hemisphere, camera-facing, in-frustum facet not live in the pool gets
## its hysteresis target tier stamped in _want. Live-only (needs a camera); a no-op without one so direct-request
## gates keep their wants. The budgeter — never this — allocates; this only sets targets (pure geometry/camera).
func _recompute_wants() -> void:
	var cam := _selector_camera()
	if cam == null or not FacetAtlas.is_ready() or _active_fid < 0:
		return                                                 # SSE is live-only; leave existing wants untouched
	_want.clear()
	var live := {}
	if _mod != null and _mod.has_method("pool_fids"):
		for f in _mod.call("pool_fids"):
			live[int(f)] = true
	var cam_pos := cam.global_position
	var fov_v := deg_to_rad(cam.fov)
	var vp := get_viewport()
	var vh := float(vp.get_visible_rect().size.y) if vp != null else 1080.0
	if vh < 1.0:
		vh = 1080.0
	var nf := FacetAtlas.facet_count()
	_ensure_geo_cache()                                        # W8: cheap per-frame map of FROZEN abs centres/normals
	var gt := global_transform
	for fid in range(nf):
		if fid == _active_fid or live.has(fid):
			continue
		var ctr := gt * _abs_centre[fid]                        # W8: no per-facet Transform3D construction on the main thread
		var to_cam := cam_pos - ctr
		var nrm_w: Vector3 = gt.basis * _abs_normal[fid]        # planet-absolute outward normal, mapped to render space
		if to_cam.dot(nrm_w) <= 0.0:
			continue                                            # camera is behind the facet's plane — quad suffices
		# W7: a facet seen EDGE-ON / at a corner can have its CENTRE off-frustum while a corner is on-screen. Test the
		# centre AND the 4 planar corners; cull only when NONE is in the frustum → no close-range quad pop-in. Corners
		# are computed only for the few facets that fail the centre test (bounded), so the common path stays cheap.
		var visible := cam.is_position_in_frustum(ctr)
		if not visible:
			for corner in _facet_render_corners(fid, gt):
				if cam.is_position_in_frustum(corner):
					visible = true
					break
		if not visible:
			continue                                            # off-screen — the far-ring quad covers it
		var d := maxf(to_cam.length(), 1.0)
		var lc := sse_lc(d, fov_v, vh)
		var cur := int(_cache[fid]["lod"]) if _cache.has(fid) else -1
		_want[fid] = hyst_tier(lc, cur)

# ---- the request-grant BUDGETER (§6.4): the selector REQUESTS, only this ALLOCATES ----

## Total estimated in-flight build seconds (the FIXED feed-forward est-seconds bound, §6.5.7).
func _inflight_est_s() -> float:
	var s := 0.0
	for fid in _building.keys():
		s += float(_EST_BUILD_S.get(int(_building[fid]["lod"]), 1.0))
	return s

## Per tick (§6.4): drive each wanted facet from its current representation toward its target tier, WORST-LOOKING
## first, admitting at most `grant_count` (credit-scaled, surface 2) grants under the queue + est-seconds bounds.
## Progressive refinement (§6.4.4): a facet with no mesh is covered at max(target,3) FIRST (≈2 s instant cover), then
## refined one tier finer per pass — but a FINE grant (< ℓ3) is an idle-time luxury, taken only while the queue is
## shallow, so under sustained pressure everything converges to ℓ3 + quads, never to OOM. Admission (§6.2 caps / LRU)
## still bounds every grant. A facet already building is left to land (one build in flight per facet — no thrash).
func _run_budgeter() -> void:
	if _builder == null or int(_builder.queued()) > LOD_QUEUE_MAX_JOBS:
		return
	var grants := LOD_REQUESTS_PER_TICK
	if _controller != null:
		grants = int(_controller.call("grant_count", LOD_REQUESTS_PER_TICK))
	if grants <= 0:
		return
	var queue_idle := int(_builder.queued()) < int(0.25 * float(LOD_QUEUE_MAX_JOBS))
	var cands: Array = []
	for fid in _want.keys():
		var target := int(_want[fid])
		if _building.has(fid):
			continue                                            # one build in flight per facet — let it land
		var cur := int(_cache[fid]["lod"]) if _cache.has(fid) else -1
		if cur == target:
			continue                                            # already at target
		var grant_lod := target
		if cur < 1:
			grant_lod = maxi(target, 3)                         # instant coarse cover first (progressive refinement)
		else:
			grant_lod = maxi(cur - 1, target)                   # refine one tier finer toward the target
			if grant_lod < 3 and not queue_idle:
				continue                                        # fine tiers are an idle-only luxury (§6.4.4)
		if _inflight_est_s() + float(_EST_BUILD_S.get(grant_lod, 1.0)) > CubeSphere.LOD_QUEUE_MAX_EST_S:
			continue                                            # est-seconds bound (§6.4.3)
		# error excess p_current/τ — worst first (a facet with no mesh scores highest so uncovered facets win).
		var excess := 1.0e12 if cur < 1 else pow(2.0, float(cur))
		cands.append({"fid": fid, "lod": grant_lod, "excess": excess})
	cands.sort_custom(func(a, b): return float(a["excess"]) > float(b["excess"]))
	var made := 0
	for c in cands:
		if made >= grants or int(_builder.queued()) > LOD_QUEUE_MAX_JOBS:
			break
		request(int(c["fid"]), int(c["lod"]))
		made += 1

## Idle demote / eviction (§5.1 / LOD_IDLE_DEMOTE_S): a covered facet the selector stopped wanting (off-screen /
## behind the horizon) is freed once it has been unwanted for LOD_IDLE_DEMOTE_S — memory returns WITHOUT pressure,
## and the far-ring quad covers it (never a hole). Wanted facets keep their last_want_ms fresh so they never idle out.
func _idle_sweep() -> void:
	var now := Time.get_ticks_msec()
	var stale: Array = []
	for fid in _cache.keys():
		if _want.has(fid) or _promoting.has(fid):              # M2d: a held (promoting) facet never idles out
			_cache[fid]["last_want_ms"] = now
		elif now - int(_cache[fid]["last_want_ms"]) > int(LOD_IDLE_DEMOTE_S * 1000.0):
			stale.append(fid)
	for fid in stale:
		evict(fid)

# ============================ request / admission (NEVER-OOM) ============================

## Request facet `fid` at tier `lod`. Marks it wanted, then admits it against the hard caps (evicting NON-wanted
## LRU facets to fund, degrading the grant one tier when only wanted facets remain, denying to quad at the coarsest
## tier). Public so G-M2-CAPS can storm it directly. A no-op for the active facet or a live pool facet. `dry` =
## admit + track WITHOUT enqueuing a real build (the caps/LRU gate exercises admission synchronously; real builds
## are covered by G-M2-BUILD/FRAME/SEAM). Returns the granted tier, or −1 when denied to quad.
func request(fid: int, lod: int, dry: bool = false) -> int:
	if fid < 0 or fid == _active_fid:
		return -1
	if _mod != null and _mod.has_method("pool_has") and bool(_mod.call("pool_has", fid)):
		return -1
	lod = clampi(lod, 1, LOD_MAX_TIER)
	_want[fid] = lod
	if _cache.has(fid):
		_cache[fid]["last_want_ms"] = Time.get_ticks_msec()
		if int(_cache[fid]["lod"]) == lod:
			return lod                                        # already applied at this tier
	if _building.has(fid) and int(_building[fid]["lod"]) == lod:
		return lod                                            # already in flight at this tier
	var granted := _admit(fid, lod)
	if granted < 0:
		return -1                                             # denied → stays quad (never a hole)
	_start_build(fid, granted, dry)
	return granted

## Estimate-based admission. Returns the granted tier (≥ lod, coarser under pressure) or -1 (deny → quad).
func _admit(fid: int, lod: int) -> int:
	var cap_bytes := LOD_MAX_BYTES_MB * 1024 * 1024
	var cand := lod
	while cand <= LOD_MAX_TIER:
		# Subtract fid's own current contribution (a re-tier replaces, not adds).
		var cur_tris := _ledger_tris - _fid_tris(fid)
		var cur_bytes := _ledger_bytes - _fid_bytes(fid)
		var tracked := _tracked_count(fid)                    # count with fid included once
		# facet-count cap (tier-independent): evict a NON-wanted LRU facet if full, else deny.
		while tracked > LOD_MAX_FACETS:
			if not _evict_one_non_wanted(fid):
				return -1
			cur_tris = _ledger_tris - _fid_tris(fid)
			cur_bytes = _ledger_bytes - _fid_bytes(fid)
			tracked = _tracked_count(fid)
		var proj_tris := cur_tris + _est_tris_for(fid, cand)
		var proj_bytes := cur_bytes + _est_bytes_for(fid, cand)
		if proj_tris <= LOD_MAX_TRIS and proj_bytes <= cap_bytes:
			return cand
		# Over a tri/byte cap: evict NON-wanted LRU to fund; if none left, degrade one tier coarser.
		if not _evict_one_non_wanted(fid):
			cand += 1
	return -1

func _start_build(fid: int, lod: int, dry: bool = false) -> void:
	_cancel_build(fid)                                        # supersede any in-flight build at a different tier
	if _builder == null and not dry:
		return
	var staging := Node3D.new()
	staging.name = "LodFacet_%d" % fid
	staging.transform = FacetAtlas.facet_transform(fid)
	_epoch_seq += 1                                           # W9(c): stamp this build so a stale same-lod drain can't swap
	var epoch := _epoch_seq
	var tiles: int = 1 if dry else int(_builder.enqueue_facet(fid, lod, epoch))
	if tiles <= 0:
		staging.free()
		return
	var est_t := _est_tris_for(fid, lod)
	var est_b := _est_bytes_for(fid, lod)
	_building[fid] = {
		"lod": lod, "epoch": epoch, "expected": tiles, "got": 0, "staging": staging, "dry": dry,
		"tris": 0, "bytes": 0, "est_tris": est_t, "est_bytes": est_b,
	}
	_ledger_tris += est_t
	_ledger_bytes += est_b

## Drop an in-flight build (superseded / evicted). Its still-queued tiles are dropped at the builder's dequeue; any
## already-drained tiles for it fall through the lod/tracking guard in tick(). Frees the staging node + est ledger.
func _cancel_build(fid: int) -> void:
	if not _building.has(fid):
		return
	var b: Dictionary = _building[fid]
	_ledger_tris -= int(b["est_tris"]); _ledger_bytes -= int(b["est_bytes"])
	var s: Node3D = b["staging"]
	if s != null and is_instance_valid(s):
		s.free()
	_building.erase(fid)

# ============================ per-frame tick (drain + apply + apron) ============================

## Per frame (module_world._process): drain the builder, apply finished meshes under LOD_APPLY_BUDGET_MS (atomic
## whole-facet swap — never a half-applied facet), then reconcile the apron coverage. Cheap when idle.
func tick() -> void:
	if _builder == null:
		return
	for item in _builder.drain_done():
		_pending.append(item)
	# W5 — purge stale drained TILES unconditionally (this is NOT budget-gated: it only FREES memory). When the
	# controller pauses applies (credit 0 → apply_ms 0), _pending accumulates real built ArrayMeshes across frames;
	# a tile whose facet was superseded/evicted (its est reservation already released at _cancel_build) would then sit
	# there UNLEDGERED. Dropping it here bounds _pending to live builds' tiles (each still est-reserved via _building).
	# Aprons self-manage (their reservation is released at apply/evict), so they are carried through untouched.
	if not _pending.is_empty():
		var kept: Array = []
		for it in _pending:
			if it.get("kind", "tile") == "apron":
				kept.append(it)
			elif _building.has(int(it["fid"])) and int(_building[int(it["fid"])]["lod"]) == int(it["lod"]) \
					and int(_building[int(it["fid"])].get("epoch", 0)) == int(it.get("epoch", 0)):
				kept.append(it)
			# else: stale tile (superseded / evicted / epoch-mismatched) → drop so its ArrayMesh is freed
		_pending = kept
	# FP-M2c surface 1 (§6.5.3.1): the apply budget is scaled by the controller credit — 0 → applies PAUSE (the
	# finished meshes wait in _pending, bounded because they are already built). Default (no controller) = the M2b
	# fixed LOD_APPLY_BUDGET_MS. Credit-scaled ms/frame governs how fast built meshes swap into the scene.
	var apply_ms := LOD_APPLY_BUDGET_MS
	if _controller != null:
		apply_ms = float(_controller.call("apply_budget_ms", LOD_APPLY_BUDGET_MS))
	if apply_ms > 0.0:
		var t0 := Time.get_ticks_usec()
		var budget_us := int(apply_ms * 1000.0)
		while not _pending.is_empty():
			_apply_one(_pending.pop_front())
			if Time.get_ticks_usec() - t0 > budget_us:
				break
	_recompute_wants()                                        # SSE selector: refresh target rungs (live-only, §6.1/§6.3)
	_run_budgeter()                                           # request-grant: allocate a few grants, credit-scaled (§6.4)
	_idle_sweep()                                             # free facets the selector stopped wanting (§5.1)
	_apron_pass()

func _apply_one(item: Dictionary) -> void:
	if item.get("kind", "tile") == "apron":
		_apply_apron(item)
		return
	var fid: int = item["fid"]
	if not _building.has(fid) or int(_building[fid]["lod"]) != int(item["lod"]) \
			or int(_building[fid].get("epoch", 0)) != int(item.get("epoch", 0)):
		return                                                # W9(c): stale (superseded / evicted / epoch-mismatched) — drop
	var b: Dictionary = _building[fid]
	var mesh: Mesh = item["mesh"]
	if mesh != null and int(item["tris"]) > 0:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var s := 1 << int(item["lod"])
		var tile: Vector3i = item["tile"]
		mi.transform = Transform3D(Basis.from_scale(Vector3.ONE * float(s)), Vector3(tile))
		(b["staging"] as Node3D).add_child(mi)
		b["tris"] = int(b["tris"]) + int(item["tris"])
		b["bytes"] = int(b["bytes"]) + int(item["bytes"])
	b["got"] = int(b["got"]) + 1
	if int(b["got"]) >= int(b["expected"]):
		_swap_in(fid)

## §4.4 atomic swap: the facet's finished LodFacet staging node (built hidden, off-tree) becomes visible in ONE
## frame and the old tier is freed — no partial-facet frame, no flicker. Reconciles the estimated ledger to actual.
func _swap_in(fid: int) -> void:
	var b: Dictionary = _building[fid]
	var new_node: Node3D = b["staging"]
	var actual_tris: int = int(b["tris"]); var actual_bytes: int = int(b["bytes"])
	# ledger: remove the in-flight estimate, remove any old applied tier, add the new actual.
	_ledger_tris -= int(b["est_tris"]); _ledger_bytes -= int(b["est_bytes"])
	if _cache.has(fid):
		var old: Dictionary = _cache[fid]
		_ledger_tris -= int(old["tris"]); _ledger_bytes -= int(old["bytes"])
		for slot in old["apron"].keys():                      # carry the aprons over rather than double-free
			var ap: Dictionary = old["apron"][slot]
			_ledger_tris -= int(ap["tris"]); _ledger_bytes -= int(ap["bytes"])
			(ap["mi"] as MeshInstance3D).queue_free()
		var on: Node3D = old["node"]
		if on != null and is_instance_valid(on):
			if on.get_parent() != null:
				on.get_parent().remove_child(on)
			on.queue_free()
	add_child(new_node)                                       # rigid under PlanetRoot @ facet_transform(fid)
	_ledger_tris += actual_tris; _ledger_bytes += actual_bytes
	_cache[fid] = {
		"lod": int(b["lod"]), "node": new_node, "tris": actual_tris, "bytes": actual_bytes,
		"last_want_ms": Time.get_ticks_msec(), "apron": {},
	}
	_building.erase(fid)
	_enforce_caps_after_spend(fid)                            # C1: the cap binds on the REAL bytes just materialized

# ============================ ridge apron reconciliation (§7.4) ============================

## Reconcile aprons to the current LOD coverage: one apron per LOD↔LOD seam, owned by the LOWER fid; free aprons
## whose neighbour is no longer covered; enqueue (bounded) aprons that are missing or whose s_max changed.
func _apron_pass() -> void:
	if _builder == null:
		return
	var cap_bytes := LOD_MAX_BYTES_MB * 1024 * 1024
	for owner in _cache.keys():
		if _is_live_or_promoting(owner):
			continue                                          # W6: never emit an apron FROM a live/promoting facet
		var lodO := int(_cache[owner]["lod"])
		var aprons: Dictionary = _cache[owner]["apron"]
		for slot in range(4):
			var nb: int = FacetAtlas.seam_neighbour(owner, slot)
			# W6: the neighbour must be a genuine LOD facet — NOT live and NOT promote-held. A live/promoting neighbour's
			# carve bevel already reaches the welded plane; an apron there extends INTO the live facet and z-fights it.
			var desired: bool = nb >= 0 and nb != owner and owner < nb and _cache.has(nb) and not _is_live_or_promoting(nb)
			var key := "%d:%d" % [owner, slot]
			if desired:
				var s_max: int = 1 << maxi(lodO, int(_cache[nb]["lod"]))
				var have_ok: bool = aprons.has(slot) and int(aprons[slot]["s_max"]) == s_max
				if not have_ok and not _apron_building.has(key):
					# W4: RESERVE the apron's cost in the ledger before enqueue (an apron is a real build job that lands
					# in the SAME tri/byte caps). DEFER (retry a later pass once headroom frees) rather than overrun a
					# cap — an apron is the lowest-priority LOD work, never worth evicting a real facet for.
					var est_t := _APRON_EST_TRIS
					var est_b := _APRON_EST_TRIS * _BYTES_PER_TRI
					if _ledger_tris + est_t <= LOD_MAX_TRIS and _ledger_bytes + est_b <= cap_bytes:
						if _builder.enqueue_apron(owner, slot, s_max):
							_ledger_tris += est_t; _ledger_bytes += est_b
							_apron_building[key] = {"s_max": s_max, "tris": est_t, "bytes": est_b}
			else:
				if aprons.has(slot):
					_free_apron(owner, slot)
				_release_apron_reservation(key)

func _apply_apron(item: Dictionary) -> void:
	var owner: int = item["fid"]
	var slot: int = item["slot"]
	var key := "%d:%d" % [owner, slot]
	_release_apron_reservation(key)                          # W4: the in-flight reservation is now replaced by the real mesh
	if not _cache.has(owner) or _is_live_or_promoting(owner):
		return                                                # owner evicted / went live mid-build — drop (reservation freed)
	var mesh: Mesh = item["mesh"]
	if mesh == null or int(item["tris"]) <= 0:
		return
	var aprons: Dictionary = _cache[owner]["apron"]
	if aprons.has(slot):
		_free_apron(owner, slot)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _apron_mat
	(_cache[owner]["node"] as Node3D).add_child(mi)
	aprons[slot] = {"mi": mi, "s_max": int(item["s_max"]), "tris": int(item["tris"]), "bytes": int(item["bytes"])}
	_ledger_tris += int(item["tris"]); _ledger_bytes += int(item["bytes"])
	_enforce_caps_after_spend(owner)                         # C1: the cap binds on the real apron bytes too

func _free_apron(owner: int, slot: int) -> void:
	var aprons: Dictionary = _cache[owner]["apron"]
	if not aprons.has(slot):
		return
	var ap: Dictionary = aprons[slot]
	_ledger_tris -= int(ap["tris"]); _ledger_bytes -= int(ap["bytes"])
	var mi: MeshInstance3D = ap["mi"]
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	aprons.erase(slot)

# ============================ eviction / LRU ============================

## Free facet `fid`'s LOD node + aprons and subtract its ledger. Used by LRU funding, crossing shifts, promote
## completion (M2d). An evicted facet drops out of covered_fids() → the far-ring quad covers it (never a hole).
func evict(fid: int) -> void:
	_promoting.erase(fid)                                      # M2d: completing/aborting a promote lifts the hold
	_cancel_build(fid)
	for slot in range(4):
		_release_apron_reservation("%d:%d" % [fid, slot])      # W4: release any of fid's in-flight (unapplied) apron reservations
	if not _cache.has(fid):
		return
	var c: Dictionary = _cache[fid]
	for slot in c["apron"].keys():
		var ap: Dictionary = c["apron"][slot]
		_ledger_tris -= int(ap["tris"]); _ledger_bytes -= int(ap["bytes"])
	_ledger_tris -= int(c["tris"]); _ledger_bytes -= int(c["bytes"])
	var n: Node3D = c["node"]
	if n != null and is_instance_valid(n):
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
	_cache.erase(fid)

## Evict the least-recently-wanted NON-wanted tracked facet (never `keep`, never a currently-wanted facet).
## Returns false when every tracked facet is wanted (the caller then degrades the grant instead — §6.4).
func _evict_one_non_wanted(keep: int) -> bool:
	var victim := -1
	var oldest := 0x7fffffffffffffff
	for fid in _cache.keys():
		if fid == keep or _want.has(fid):
			continue
		var w := int(_cache[fid]["last_want_ms"])
		if w < oldest:
			oldest = w; victim = fid
	if victim < 0:
		# no evictable applied facet — also consider dropping a non-wanted in-flight build
		for fid in _building.keys():
			if fid != keep and not _want.has(fid):
				_cancel_build(fid)
				return true
		return false
	evict(victim)
	return true

# ---- admission-estimate helpers (C2/C3: derive from the facet's ACTUAL tile count × a per-tile worst-case) ----

## The number of xz tiles the builder tiles facet `fid` into at tier `lod` — the SURFACE-bearing tile count (the y
## tiles above/below the surface early-out to all-air). Pure FacetAtlas domain arithmetic, no builder/thread needed
## (so it also drives the caps gate's `dry` admission). Mirrors FacetLodBuilder.enqueue_facet's xz tiling.
func _facet_xz_tiles(fid: int, lod: int) -> int:
	var span := FLB.TILE_MAX * (1 << lod)                     # LOD0 lattice cells one full tile covers per axis
	var dmn: Vector2i = FacetAtlas.dom_min(fid)
	var dmx: Vector2i = FacetAtlas.dom_max(fid)
	var nx := maxi(1, int(ceil(float(dmx.x - dmn.x) / float(span))))
	var nz := maxi(1, int(ceil(float(dmx.y - dmn.y) / float(span))))
	return nx * nz

## The admission tri estimate for (fid, lod): xz tile count × the per-surface-tile worst-case. An UPPER FENCE over
## the flat case (C2 — a flat ℓ1 facet is ~16 tiles × 2048 = 32768; this returns ~16 × 3072 = 49152 > flat) that
## scales down for small-domain facets. Extreme ruggedness beyond the fence is caught by the C1 spend-time reconcile.
func _est_tris_for(fid: int, lod: int) -> int:
	return _facet_xz_tiles(fid, lod) * _PER_TILE_TRIS

## Bytes COUPLED to tris at the builder's own formula (C3: verts·64 + tris·3·4 ≈ 140·tris) so the two cannot drift.
func _est_bytes_for(fid: int, lod: int) -> int:
	return _est_tris_for(fid, lod) * _BYTES_PER_TRI

# ---- W8 geometry cache: FROZEN planet-absolute facet centres/normals (built once; per-frame map is cheap) ----
func _ensure_geo_cache() -> void:
	if _geo_cached or not FacetAtlas.is_ready():
		return
	var nf := FacetAtlas.facet_count()
	_abs_centre.resize(nf)
	_abs_normal.resize(nf)
	for fid in range(nf):
		var cc: Vector2i = FacetAtlas.centre_cell(fid)
		_abs_centre[fid] = FacetAtlas.facet_transform(fid) * Vector3(float(cc.x), 0.0, float(cc.y))
		var n: Array = FacetAtlas.facet_normal64(fid)
		_abs_normal[fid] = Vector3(n[0], n[1], n[2])
	_geo_cached = true

## W7: facet `fid`'s 4 planar (y=0) domain corners in RENDER space (gt = the mesher's global_transform). Only called
## for facets whose centre failed the frustum test, so the per-call facet_transform build is bounded.
func _facet_render_corners(fid: int, gt: Transform3D) -> Array:
	var dmn: Vector2i = FacetAtlas.dom_min(fid)
	var dmx: Vector2i = FacetAtlas.dom_max(fid)
	var tf: Transform3D = FacetAtlas.facet_transform(fid)
	var out: Array = []
	for c in [Vector2i(dmn.x, dmn.y), Vector2i(dmx.x, dmn.y), Vector2i(dmx.x, dmx.y), Vector2i(dmn.x, dmx.y)]:
		out.append(gt * (tf * Vector3(float(c.x), 0.0, float(c.y))))
	return out

## W6: is `fid` a live pool terrain OR a promote-held facet (its live terrain is streaming under a held LOD cover)?
## An apron must never be emitted from OR toward such a facet — the live carve bevel already reaches the welded plane.
func _is_live_or_promoting(fid: int) -> bool:
	if _promoting.has(fid):
		return true
	return _mod != null and _mod.has_method("pool_has") and bool(_mod.call("pool_has", fid))

## C1 — the HARD cap binds on REAL bytes at the moment memory is spent (swap / apron apply). Admission used an upper
## fence, but a rugged facet's actual mesh could still exceed the remaining headroom; evict LRU NON-wanted facets
## until the ACTUAL ledger is under the caps. If only wanted (or `keep` itself) remain and we are still over, drop
## `keep` to the quad — never exceed the ceiling (memory safety outranks the momentary pop; the quad covers it).
func _enforce_caps_after_spend(keep: int) -> void:
	var cap_bytes := LOD_MAX_BYTES_MB * 1024 * 1024
	while _ledger_tris > LOD_MAX_TRIS or _ledger_bytes > cap_bytes:
		if _evict_one_non_wanted(keep):
			continue
		# nothing non-wanted left to give — the just-materialized facet itself must go to quad (unless it is a held
		# promote cover, where dropping it would gap a streaming crossing; that overlap is bounded by the §9 timeouts).
		if _promoting.has(keep):
			return
		evict(keep)
		return

## W4: release an in-flight apron reservation (subtract its est from the ledger) — on apply (replaced by actual), on
## the owner going undesired/evicted, or on the owner going live. Tolerates a legacy int value defensively.
func _release_apron_reservation(key: String) -> void:
	if not _apron_building.has(key):
		return
	var r = _apron_building[key]
	if typeof(r) == TYPE_DICTIONARY:
		_ledger_tris -= int(r["tris"])
		_ledger_bytes -= int(r["bytes"])
	_apron_building.erase(key)

# ---- ledger helpers ----
func _fid_tris(fid: int) -> int:
	if _cache.has(fid): return int(_cache[fid]["tris"])
	if _building.has(fid): return int(_building[fid]["est_tris"])
	return 0

func _fid_bytes(fid: int) -> int:
	if _cache.has(fid): return int(_cache[fid]["bytes"])
	if _building.has(fid): return int(_building[fid]["est_bytes"])
	return 0

func _tracked_count(include: int) -> int:
	var seen := {}
	for fid in _cache.keys(): seen[fid] = true
	for fid in _building.keys(): seen[fid] = true
	seen[include] = true
	return seen.size()

# ============================ introspection (far-ring merge + gates + M2c HUD) ============================

## The facets holding an APPLIED LOD mesh — merged with the live pool into the FacetFarRing exclusion set (§5.5).
## Building-but-not-yet-applied facets are DELIBERATELY excluded so the quad stays until the LOD mesh is really up.
func covered_fids() -> Array:
	return _cache.keys()

func is_covered(fid: int) -> bool:
	return _cache.has(fid)

## M2d gate (G-M2-XPD): is `fid`'s LOD mesh currently HELD through a live-terrain promote (§9.1)?
func is_promoting(fid: int) -> bool:
	return _promoting.has(fid)

func active_facet() -> int:
	return _active_fid

func want_of(fid: int) -> int:
	return int(_want.get(fid, -1))

## Gate + PerfHUD snapshot: applied facet count, running tri/byte ledgers, in-flight builds, apron count, caps.
func stats() -> Dictionary:
	var aprons := 0
	for fid in _cache.keys():
		aprons += int((_cache[fid]["apron"] as Dictionary).size())
	return {
		"facets": _cache.size(), "building": _building.size(), "aprons": aprons,
		"tris": _ledger_tris, "bytes": _ledger_bytes,
		"max_facets": LOD_MAX_FACETS, "max_tris": LOD_MAX_TRIS, "max_bytes": LOD_MAX_BYTES_MB * 1024 * 1024,
		"builder_queued": int(_builder.queued()) if _builder != null else 0,
		"builder_built": int(_builder.build_count()) if _builder != null else 0,
	}

## Gate helper: the FacetLodBuilder this mesher owns (G-M2-BUILD / SEAM drive it directly for apron/tile builds).
func builder():
	return _builder

## Gate helpers (G-M2-FRAME / SEAM introspection). tile instances = the LOD megablock MeshInstances (material
## override null); apron instances carry _apron_mat. lod_of returns the applied tier (−1 if not covered).
func facet_tile_instances(fid: int) -> Array:
	var out: Array = []
	if not _cache.has(fid):
		return out
	for c in (_cache[fid]["node"] as Node3D).get_children():
		if c is MeshInstance3D and c.mesh != null and c.material_override != _apron_mat:
			out.append(c)
	return out

func lod_of(fid: int) -> int:
	return int(_cache[fid]["lod"]) if _cache.has(fid) else -1

func apron_slots(fid: int) -> Array:
	return (_cache[fid]["apron"] as Dictionary).keys() if _cache.has(fid) else []

func apron_mesh(fid: int, slot: int) -> Mesh:
	if _cache.has(fid) and (_cache[fid]["apron"] as Dictionary).has(slot):
		return (_cache[fid]["apron"][slot]["mi"] as MeshInstance3D).mesh
	return null

func is_building(fid: int) -> bool:
	return _building.has(fid)
