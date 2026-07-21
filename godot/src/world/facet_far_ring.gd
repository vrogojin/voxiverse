class_name FacetFarRing
extends Node3D
## COSMOS FP2 §5.2 / FP3 §6.1 — the planet rendered AROUND the active facet. Every non-active facet is drawn as
## a flat, low-res, terrain-coloured quad built (ONCE, cached) from its PLANARIZED corners in ABSOLUTE planet
## coords with radial relief (FP0's seam-glue). This node's transform = T_active⁻¹ (facet_transform(active)
## inverse), so the whole planet is re-placed into the active facet's flat render frame by ONE rigid transform —
## the player on the flat facet sees the faceted planet curve away, faces JOINING at the seams (no wedge).
##
## FP-S1(d) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §4-R2 defect 4 / §8): a crossing's set_active USED to do a
## synchronous full 3456-facet rescan + re-emit + generate_normals + commit (plus first-time 25-noise-profile
## caching for every newly-front-hemisphere facet) in ONE main-thread frame — the same frame as the restream
## kickoff. That is a large part of the crossing stall. Now set_active is O(1): it updates ONLY the node transform
## (the mesh is in ABSOLUTE coords, so a rigid re-place keeps every cached facet correctly positioned) and marks a
## deferred rebuild. _process completes it OFF the crossing frame: it cache-warms newly-front-hemisphere facets
## under a per-frame ms budget (mirroring FarTerrain's discipline), then re-emits once. The headless gate drives it
## synchronously via force_rebuild(). Render-only, collision-free, voxel-worker-free (like FarTerrain).

const ENABLED := true
const CELLS := 4                     # heightmap cells per facet edge (far LOD) — k=24 facets are small
const RELIEF := 1.0                  # blocks of radial relief per (g − SEA_LEVEL)
const BACK_CULL := 0.0               # front hemisphere only — back-side facets sit below the surface horizon
const CAMERA_FAR := 9000.0           # the planet spans ~2R; the player camera far must reach it in faceted mode
const FOG_BEGIN := 2200.0            # fog only far out, so the whole planet reads
const WARM_BUDGET_MS := 3.0          # FP-S1(d): per-frame cache-warm budget for newly-front-hemisphere facets

var _active_fid := -1
# COSMOS FP-FIXED-FRAME re-anchor (§3): the accumulated floating-origin shift. Under the fixed frame the ring pins @
# (identity − _anchor_offset) so its ABSOLUTE mesh rides the same re-anchor as PlanetRoot. ZERO with the flag off.
var _anchor_offset: Vector3 = Vector3.ZERO
var _mi: MeshInstance3D
var _pos_cache: Dictionary = {}      # fid -> PackedVector3Array (ABSOLUTE planet coords; built once per facet)
var _col_cache: Dictionary = {}      # fid -> PackedColorArray
# COSMOS far-ring full coverage (docs/COSMOS-FARRING-COVERAGE-DESIGN.md §3): the SEPARATE dense caches for "backstop"
# facets (the active facet + the live-pool `_excluded` set) under FP_FARRING_FULL_COVER. Built lazily at BACKSTOP_CELLS
# (denser than the shipped CELLS=4) by _ensure_backstop_cached; the shipped _pos_cache/_col_cache stay at CELLS for the
# non-backstop horizon facets. Positions are ABSOLUTE + radial with NO sink baked in — the BACKSTOP_SINK radial push is
# applied PER EMITTED VERTEX in _emit_cached, so a facet that transitions backstop→distant across a crossing drops the
# sink automatically on the next rebuild (the cache is role-agnostic). NEVER populated with the flag off (zero cost).
var _bpos_cache: Dictionary = {}     # fid -> PackedVector3Array (dense, ABSOLUTE, un-sunk)
var _bcol_cache: Dictionary = {}     # fid -> PackedColorArray
# COSMOS-PERF L1 (§3.1): pre-TRIANGULATED per-facet caches for FP_FARRING_FAST_REBUILD. Built lazily from the grid
# caches above (only when the fast path or the equivalence gate runs → zero cost/memory with the flag off). Each holds
# the facet's 32 tris EXPANDED to 96 vertices in the EXACT order/winding _emit_cached emits — so the fast rebuild is a
# straight append_array memcpy per facet (~1728 C++ memcpys) instead of ~332k per-vertex GDScript→C++ round-trips.
# NORMALS are NOT cached: the mesh's GLOBAL smoothing (generate_normals merges vertices across facet SEAMS — proven by
# G-L1-FARRING) depends on the whole visible set, so the fast path assembles pos/col, then runs create_from +
# generate_normals (both C++, no GDScript per-vertex calls) → the normal array is BIT-IDENTICAL to the SurfaceTool path.
var _tri_pos_cache: Dictionary = {}  # fid -> PackedVector3Array (96 verts: the facet's tri soup, ABSOLUTE coords)
var _tri_col_cache: Dictionary = {}  # fid -> PackedColorArray   (96 colors, per _emit_cached order)
var _centre_cache: Dictionary = {}   # FP-S1(d): fid -> Array[3] cached centre dir (cheap; no planar-corner recompute per rebuild)
# FP-S1(d) deferred-rebuild state
var _pending := false                # a crossing requested a rebuild; _process (or force_rebuild) completes it off-frame
var _emitted: Dictionary = {}        # fid -> true: the facets in the CURRENTLY committed mesh (visible-set gate check)
var _reemit_count := 0               # diagnostics: full re-emits done (gate: set_active does NOT re-emit synchronously)
# COSMOS FP-R0 SPIKE: facets rendered as REAL rotated voxel terrains (WorldManager fills this behind
# CubeSphere.FP_R0). Their flat quad is suppressed here so the real voxels don't z-fight the ring. Empty
# on the shipped build (FP_R0 off) → the ring draws every non-active facet exactly as before, byte-identical.
var _excluded: Dictionary = {}       # fid -> true (skipped in the visible set, same as the active facet is skipped)
# COSMOS TIER-DEPTH-PRIORITY P1 (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.3): the STICKY backstop set under
# FP_TIER_STICKY_BACKSTOP. Grown EAGERLY to active ∪ ring-1 (make-before-break: a facet is drawn sunk BEFORE it
# enters the pool) and shrunk LAZILY (a departing facet holds its backstop role STICKY_HOLD role-events so it never
# reverts to an unsunk coarse quad while near meshes may still be applied). `_is_backstop` unions this. Empty with
# the flag off → `_is_backstop` is the shipped active∪`_excluded`, byte-identical. `_sticky_hold` is the per-fid
# remaining-hold countdown driving the lazy shrink; recomputed on every set_active/set_pool_excluded (a role-event).
var _sticky: Dictionary = {}         # fid -> true (currently a sticky backstop)
var _sticky_hold: Dictionary = {}    # fid -> int (role-events left before this ex-target may drop out of _sticky)
# COSMOS TIER-DEPTH-PRIORITY P1 gate visibility: which fids were emitted AS BACKSTOP (sunk) in the CURRENTLY committed
# mesh — the make-before-break invariant is "every pool facet is an emitted backstop at the moment near meshes apply",
# and that is a property of the LAST rebuild's roles, not the live `_is_backstop`. Recorded at each rebuild/swap.
var _emitted_backstop: Dictionary = {}   # fid -> true (drawn sunk in the committed mesh)
# COSMOS-PERF STEP 2 (FP_FARRING_ASYNC_REBUILD): off-main-thread rebuild state. The worker assembles the mesh DATA
# (per-vertex emit + generate_normals + commit_to_arrays — pure CPU, NO RenderingServer) on the WARMED, read-only
# per-facet caches; the main thread swaps the finished ArrayMesh in (the only RenderingServer touch). Single-flight
# (_async_building), double-buffered (the old _mi.mesh stays visible until the swap), happens-before via the worker
# pool's is_task_completed (main writes _async_fids before add_task; worker writes _async_arrays before returning).
var _async_task_id := -1
var _async_building := false
var _async_fids := PackedInt32Array()   # the visible set the in-flight worker is building (main → worker; read-only during)
var _async_arrays: Array = []           # worker → main: the committed surface arrays (built off-thread, swapped on main)
# COSMOS far-ring full coverage (§4): the FROZEN backstop set for the in-flight worker. `_is_backstop` reads `_excluded`,
# which set_pool_excluded MUTATES on the main thread mid-crossing — so the worker must NOT evaluate the role live (that
# would race the dict). The role is snapshotted here on the main thread at dispatch (fid -> true); the worker only reads
# this frozen dict, preserving the existing "worker reads read-only per-facet state" contract. Empty with the flag off.
var _async_backstop: Dictionary = {}
# T2e (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-rebuild build/swap timing records, drained by WorldManager →
# RemoteBridge (take_events) so the §2.2c "zero-queue crossing stall" (far-ring re-emit prime suspect) is convicted or
# acquitted in one run. Bounded FIFO (NEVER-OOM: a drain-less headless session can never grow it). `_async_build_us` is
# the off-thread worker build wall time, written by the worker before it returns and read by main after is_task_completed
# (same happens-before as _async_arrays), so the async event carries a real build_ms alongside its main-thread swap_ms.
const EVENTS_MAX := 16
var _events: Array = []
var _async_build_us := 0

# COSMOS-ORBITAL-SHELL S1 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3): the CAMERA-radial emitted-set law under
# FP_SHELL_CAMERA_SET. Off-surface the emit cull axis becomes the sub-camera direction ĉ (ABSOLUTE planet space)
# with an altitude-derived cap θ_emit, re-emitted on angular drift — so the whole VISIBLE cap renders from any
# altitude/longitude (fixing the far-hemisphere-blank-from-orbit bug), not just the active facet's hemisphere.
# `_cam_set` false ⇒ the shipped active-facet law runs verbatim (byte-identical). ĉ + cap are a plain [x,y,z]
# Array + a cos threshold so _front_visible's dot test is unchanged. The re-emit reuses the EXISTING
# _pending/_warm_front/_process/async/swap pipeline (only the cull axis + refresh trigger change).
var _cam_set := false                       # the camera-set law currently governs the emitted set (off-surface, flag on)
var _emit_axis: Array = [0.0, 0.0, 0.0]     # ĉ (ABSOLUTE): the emit cull axis when _cam_set
var _emit_cos := BACK_CULL                  # cos(θ_emit): the emit threshold when _cam_set
var _emit_dir_last: Array = [0.0, 0.0, 0.0] # ĉ at the last re-emit (angular-drift trigger)
var _emit_thetah_last := -1.0               # θ_h at the last re-emit (radial-drift trigger)
var _emit_floored_last := false             # the surface-floor state at the last re-emit (re-emit crisply on the OFFSURFACE_Y crossing)
# COSMOS-ORBITAL-SHELL S2 (§4): one-shot whole-planet coarse-cache warm, armed after a sustained off-surface dwell.
var _offsurface := false                    # set by the per-frame driver: camera radial altitude > OFFSURFACE_Y
var _offsurface_dwell := 0.0                # seconds sustained off-surface (the S2 warm arms after SHELL_PREWARM_DWELL_S)
var _prewarm_cursor := -1                   # -1 = not started; 0..6·K² = next fid to warm; ≥ total = done (one-shot)
# COSMOS-ORBITAL-SHELL S1b (§3): progressive cached-subset emit in the true-orbit regime (see SHELL_REEMIT_GROWTH).
var _emit_cached_only := false              # the current rebuild emits ONLY cache-ready facets (true-orbit progressive path)
var _last_emit_cache_size := 0             # total cached facets at the last progressive re-emit (re-emit-on-growth throttle)
var _was_done := false                      # _warm_front returned true last orbit frame (fire ONE final full emit on completion, no prewarm-churn)
# COSMOS-PERF FALL-COLLAPSE FIX A (FP_SHELL_ORBIT_IDLE): the off-surface (true-orbit) analogue of `_srf_converged`.
# The orbit branch re-ran the full 6·K² _warm_front dot scan EVERY airborne frame (the ~67 ms proc baseline the live
# fall-from-orbit telemetry shows with draws=32). Once the front is fully warmed + emitted with nothing pending, the
# scan can be skipped until the next drift snapshot re-sets `_pending` — matching the shipped surface idle frame.
var _orbit_converged := false               # front fully cached + emitted, nothing pending → skip the per-frame warm scan (FP_SHELL_ORBIT_IDLE)
# COSMOS-PERF FALL-COLLAPSE FIX A2 (FP_SHELL_FALL_HOLD): hold the cap during a fall — suppress the per-frame radial
# re-snapshot (the near-surface acos(R/d) blow-up) + throttle the off-surface re-emit so the synchronous rebuild
# can't fire every frame. `_snapshot_count` is the thrash diagnostic (times a re-emit was SCHEDULED) the gate reads.
var _last_snapshot_ms := 0                   # wall-ms of the last shell snapshot (throttle base for the fall-hold re-emit)
var _last_rebuild_ms := 0                    # wall-ms of the last orbit-branch _begin_rebuild (throttle base for grew re-emits)
var _snapshot_count := 0                     # diagnostics: times _shell_snapshot fired (a scheduled re-emit) — flat during a held fall
# COSMOS-PERF FALL-COLLAPSE FIX D (FP_WARM_TRUE_BUDGET, R1): O(visible) scan support. `_centre_pack` is a lazily-built
# packed array of all 6·K² facet centre-dirs — iterated inline in _warm_front_true_budget so the per-frame scan avoids
# the per-fid _centre_dir DICT lookup + the _front_visible function-call overhead (the ×25 web scan cost). Bounded (one
# fixed-size array ≤ 6·K² Vector3 ⇒ NEVER-OOM), built once. Empty (never built) off-flag.
var _centre_pack := PackedVector3Array()
# COSMOS TIER-DEPTH-PRIORITY warm-converge (FP_TIER_WARM_CONVERGE): the SURFACE progressive-emit state (isolated from the
# orbit S1b vars above so the two paths never alias). `_srf_converged` gates the idle short-circuit (no per-frame warm scan
# once the whole front is cached + emitted); `_srf_last_bcache`/`_srf_last_ccache` are the dense/coarse cache sizes at the
# last progressive emit — a grown dense cache (a new sunk backstop) re-emits immediately (kills the stale over-near quad),
# coarse growth batches at SHELL_REEMIT_GROWTH (far-horizon holes are benign). All scalars → NEVER-OOM.
var _srf_converged := false
var _srf_was_done := false
var _srf_last_bcache := 0
var _srf_last_ccache := 0
# Live-path telemetry counters/values (remote_bridge streams shell_telemetry() → disambiguate the live driver→warm→emit chain).
var _begin_rebuild_count := 0               # times _begin_rebuild fired (0 post-engage ⇒ the emit never runs = warm-gate stall)
var _warm_pass_count := 0                   # _warm_front returned true (cap fully cached in one frame)
var _warm_fail_count := 0                   # _warm_front returned false (budget spent before the cap was fully cached)
var _dbg_true_dir: Array = [0.0, 0.0, 0.0]  # the latest ABSOLUTE sub-camera direction (driver input) — compare to _emit_axis for H-C
var _dbg_d := 0.0                           # latest camera distance from the body centre
var _dbg_h := 0.0                           # latest radial altitude h = d − R
var _dbg_theta_emit_deg := 0.0              # latest θ_emit (deg)
var _dbg_scale := 1.0                       # latest SN3 scaled-body scale s (1.0 = no clamp) — H-B far-plane/placement signal

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_recompute_sticky()              # TIER-DEPTH P1: seed the sticky backstop set so ring-1 is sunk from the first build (no-op with the flag off)
	_mi = MeshInstance3D.new()
	_mi.name = "FacetFarRingMesh"
	_mi.material_override = _make_material()
	add_child(_mi)
	_rebuild_full()                  # initial build — synchronous (spawn is masked by the ShaderPrewarm hold)
	set_process(true)

## FP3 §6.1 / FP-S1(d) crossing: re-place the planet into facet `new_fid`'s render frame (rigid, O(1)) and DEFER the
## exclusion/terminator re-emit + any new-facet noise caching to _process (off the crossing frame, under a budget).
## The existing merged mesh is in ABSOLUTE coords, so the transform update alone keeps every cached facet correctly
## placed; only B's quad (now the active facet → should be excluded) and the just-left A's quad (now visible) plus a
## thin terminator band are transiently stale for the ≤1-2 frames until the deferred re-emit lands.
func set_active(new_fid: int) -> void:
	_active_fid = new_fid
	transform = _placement_xform()   # rigid re-place (cheap); identity under FP-FIXED-FRAME (no re-place)
	_recompute_sticky()              # TIER-DEPTH P1: grow the sticky set to the NEW active's ring-1 (no-op with the flag off)
	# COSMOS-ORBITAL-SHELL live fix: in orbit the emitted set is CAMERA-axis-driven (not active-facet-driven), and the
	# mesh is absolute (the transform re-place above already follows the new active facet), so a facet crossing does
	# NOT change the emitted set — its _pending would force a redundant full rebuild every ~3 frames as the active
	# facet churns under the orbit ground-track. Skip it off-surface; the camera driver re-emits on real drift. On the
	# surface / flag-off _shell_orbit() is false ⇒ the shipped deferred re-emit fires exactly as today (byte-identical).
	if not _shell_orbit():
		_pending = true

## FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §1.4/§2.2 step 8): the ring mesh is built in ABSOLUTE planet
## coords. When the fixed frame pins the scene @ the absolute frame (PlanetRoot @ identity) this node stays @
## identity — a crossing does NO transform write here (only the deferred exclusion/terminator re-emit remains). Off
## ⇒ T_active⁻¹, re-placing the absolute mesh into the active facet's render frame exactly as today (byte-identical).
func _placement_xform() -> Transform3D:
	if CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL:
		return Transform3D(Basis.IDENTITY, -_anchor_offset)
	return FacetAtlas.facet_transform(_active_fid).affine_inverse()

## COSMOS SPACE-NAV SN3 (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.2): the planet centre in the CURRENT render
## frame. The ring mesh is absolute + body-centred (the planet centre is v_abs = 0), so its world position is
## _placement_xform() applied to the origin — i.e. the shipped placement's translation. Frame-agnostic (folds
## in T_active⁻¹ or the fixed-frame −anchor). The SN3 driver uses this to derive d = |camera − centre| and the
## radial altitude h. DEAD unless FP_SCALED_BODY is on (only the SN3 per-frame driver calls it).
func render_centre() -> Vector3:
	return _placement_xform().origin

## COSMOS SPACE-NAV SN3 (§5.2): apply the angular-size-preserving distance clamp. Above D_ENGAGE the whole ring
## is uniformly scaled by s = min(1, D_ENGAGE/d) ABOUT the camera — screen image invariant, geometry pulled into
## the depth range at d·s = D_ENGAGE. Below D_ENGAGE s == 1 exactly ⇒ transform == _placement_xform() (the
## shipped placement, byte-identical to the near regime). The ring mesh/nodes are untouched (ZERO bytes) — only
## this node's transform changes, and only when the SN3 driver calls this (FP_SCALED_BODY on). Called per frame
## on the main thread (like set_active's rigid re-place); the async worker is unaffected (it reads only caches).
func apply_scaled_placement(cam: Vector3) -> void:
	var base := _placement_xform()
	var s := CosmosScale.scale_for(cam.distance_to(base.origin), FacetAtlas.R_BLOCKS)
	_dbg_scale = s                                  # H-B telemetry: the SN3 clamp scale actually applied to the ring this frame
	transform = CosmosScale.scale_about_camera(cam, s) * base   # s == 1 ⇒ identity·base == base (near regime unchanged)

## COSMOS-ORBITAL-SHELL S1/S2 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3/§4): the per-frame camera-set driver. `cam`
## is the camera position in the CURRENT render frame (as apply_scaled_placement receives it). The mesh is in
## ABSOLUTE planet coords placed by _placement_xform() (a rigid transform), so the sub-camera radial direction in
## the mesh's ABSOLUTE space is base.basis⁻¹·(cam − render_centre) and the TRUE (unclamped, scale-free) distance is
## |cam − render_centre| — both fold through _placement_xform for either placement path (fixed-frame or legacy),
## and the SN3 scale (scale_about_camera) is screen-invariant so it never enters ĉ or d. Updates the emitted-set
## law (S1) and the off-surface flag driving the one-shot prewarm (S2). No allocation beyond the transient dir
## Array; never rebuilds inline (only sets _pending — the crossing-pipeline discipline). Called per frame by
## WorldManager under (FP_SHELL_CAMERA_SET or FP_SHELL_PREWARM); DEAD (never called) with both flags off.
func apply_camera_set(cam: Vector3) -> void:
	var base := _placement_xform()
	var rel := cam - base.origin                      # camera relative to the body centre, RENDER frame
	var d := rel.length()
	var h := d - FacetAtlas.R_BLOCKS
	_offsurface = h > CubeSphere.OFFSURFACE_Y         # S2 prewarm arming (drives the dwell in _prewarm_step)
	_dbg_d = d
	_dbg_h = h
	if not CubeSphere.FP_SHELL_CAMERA_SET:
		return                                        # S2-only run: prewarm the cache without changing the emitted-set law
	var abs_rel := base.basis.inverse() * rel         # rotate the render-frame offset back into ABSOLUTE mesh space
	if abs_rel.length() < 1.0e-6:
		return                                        # camera at the body centre (degenerate) — keep the last axis
	var u := abs_rel.normalized()
	_dbg_true_dir = [u.x, u.y, u.z]                   # H-C telemetry: the TRUE sub-camera direction the driver fed in
	shell_set_camera_abs([u.x, u.y, u.z], d, h < CubeSphere.OFFSURFACE_Y)

## COSMOS-ORBITAL-SHELL S1 (§3): the emitted-set law core, driven from the ABSOLUTE sub-camera direction `dir`
## (unit [x,y,z]), the camera distance `d` from the body centre, and whether the surface floor applies. Snapshots
## the cull axis (ĉ) + cap cos(θ_emit) and marks a deferred re-emit on first engage, on the OFFSURFACE_Y floor
## crossing, or when ĉ drifts past SHELL_SLACK_DEG − 2° / θ_h shifts > 5° (fast radial move). θ_emit is floored to
## 90° below OFFSURFACE_Y so the on-foot regime is byte-VISUALLY identical to shipped (the facets that then differ
## from the active-facet law all sit behind the limb). Pure state update + a possible _pending flag; the actual
## warm + rebuild + swap ride the EXISTING _process/async pipeline. Split out so headless gates drive it directly.
func shell_set_camera_abs(dir: Array, d: float, floored: bool) -> void:
	var r := FacetAtlas.R_BLOCKS
	var theta_h := acos(clampf(r / maxf(d, r), -1.0, 1.0))   # visible-cap angular radius (0 at/below the surface, < 90° always)
	# COSMOS-PERF FALL-COLLAPSE FIX A2 (FP_SHELL_FALL_HOLD): off-surface (airborne) carry a GENEROUS extra margin so a
	# shrinking visible cap during a descent stays inside the held cap ⇒ no radial re-emit needed. Byte-identical off
	# (extra == 0) and on the floored surface. See shell_fall_should_reemit for the matching suppressed radial trigger.
	var fall_hold := CubeSphere.FP_SHELL_FALL_HOLD and not floored
	var extra := deg_to_rad(CubeSphere.SHELL_FALL_MARGIN_DEG) if fall_hold else 0.0
	var theta_emit := minf(theta_h + deg_to_rad(CubeSphere.SHELL_RELIEF_DEG + CubeSphere.SHELL_SLACK_DEG) + extra,
			deg_to_rad(CubeSphere.SHELL_CAP_MAX_DEG))
	if floored:
		theta_emit = maxf(theta_emit, deg_to_rad(90.0))       # surface floor: keep the shipped hemisphere while near tiers are live
	_dbg_theta_emit_deg = rad_to_deg(theta_emit)
	var new_cos := cos(theta_emit)
	if not _cam_set:
		_cam_set = true                                       # first engage → snapshot + force a re-emit onto the camera axis
		_shell_snapshot(dir, new_cos, theta_h, floored)
		_last_snapshot_ms = Time.get_ticks_msec()
		return
	var drift := acos(clampf(dir[0] * _emit_dir_last[0] + dir[1] * _emit_dir_last[1] + dir[2] * _emit_dir_last[2], -1.0, 1.0))
	var dtheta := theta_h - _emit_thetah_last                 # SIGNED: > 0 = the visible cap grew (a climb); < 0 = shrank (a descent)
	if shell_fall_should_reemit(fall_hold, floored != _emit_floored_last, dtheta, drift, Time.get_ticks_msec() - _last_snapshot_ms):
		_shell_snapshot(dir, new_cos, theta_h, floored)
		_last_snapshot_ms = Time.get_ticks_msec()

## COSMOS-PERF FALL-COLLAPSE FIX A2 (FP_SHELL_FALL_HOLD) — the re-emit-trigger decision, split out PURE + static so
## the descent gate (G-SHELL-FALLHOLD) drives it directly with synthetic inputs (no wall-clock, no node). A floor/regime
## change ALWAYS re-emits. With `hold` OFF: the shipped reactive triggers verbatim (axis drift past slack − 2°, OR
## |Δθ_h| > 5°) — byte-identical. With `hold` ON: the per-frame radial trigger is SUPPRESSED for a shrinking cap (the
## near-surface acos blow-up during a fall) — re-emit ONLY when the cap must GROW past the held generous margin
## (a climb — else holes appear at the limb), or the axis SWEEPS past slack AND the throttle (SHELL_FALL_REEMIT_MS) has
## elapsed. `dtheta` is SIGNED (> 0 = grew); `drift` is the axis angle since the last snapshot (rad); `elapsed_ms` is
## the wall-ms since the last snapshot. Bounds the far-ring re-emit (⇒ the synchronous _rebuild_full) to ≤ 1/throttle.
static func shell_fall_should_reemit(hold: bool, floor_changed: bool, dtheta: float, drift: float, elapsed_ms: int) -> bool:
	if floor_changed:
		return true
	var swept := drift > deg_to_rad(CubeSphere.SHELL_SLACK_DEG - 2.0)
	if not hold:
		return swept or absf(dtheta) > deg_to_rad(5.0)       # shipped reactive trigger (byte-identical)
	if dtheta > deg_to_rad(CubeSphere.SHELL_FALL_MARGIN_DEG):
		return true                                          # visible cap OUTGREW the held cap (a climb) — re-emit to avoid limb holes
	return swept and elapsed_ms >= CubeSphere.SHELL_FALL_REEMIT_MS

## COSMOS-ORBITAL-SHELL S1 (§3): commit a new emit axis/cap and schedule the deferred re-emit (the warm + async
## build + single swap are the shipped pipeline; only _pending + the axis/cap snapshot change here).
func _shell_snapshot(dir: Array, cap_cos: float, theta_h: float, floored: bool) -> void:
	_emit_axis = dir
	_emit_cos = cap_cos
	_emit_dir_last = dir
	_emit_thetah_last = theta_h
	_emit_floored_last = floored
	_pending = true
	_snapshot_count += 1                                       # FIX A2 diagnostic: a scheduled re-emit (flat during a held fall)

## COSMOS-ORBITAL-SHELL S2 (§4): the one-shot whole-planet coarse-cache warm. After SHELL_PREWARM_DWELL_S sustained
## off-surface, fill the SHIPPED _pos_cache/_col_cache for every uncached facet under the existing WARM_BUDGET_MS
## per frame, advancing a cursor across all 6·K² fids exactly once per session — so an orbital re-emit over a
## never-visited longitude is a pure cached emit (no warm lag). NEVER-OOM: it fills only the fid-keyed coarse caches
## the ring already uses (hard cap 6·K² ≈ 2.4 MB), never a parallel store; the cursor makes it strictly one-shot and
## the byte ceiling is reachable today on foot. Skipped while a worker reads the caches (_async_building) — same
## quiescence contract as force_rebuild. No-op unless FP_SHELL_PREWARM (⇒ flag-off _process is byte-identical).
func _prewarm_step(dt: float) -> void:
	if not CubeSphere.FP_SHELL_PREWARM:
		return
	var total := FacetAtlas.K * FacetAtlas.K * 6
	if _prewarm_cursor >= total:
		return                                # done this session (one-shot)
	if not _offsurface:
		_offsurface_dwell = 0.0
		return
	_offsurface_dwell += dt
	if _offsurface_dwell < CubeSphere.SHELL_PREWARM_DWELL_S:
		return
	if _async_building:
		return                                # a worker is reading the caches — resume next frame (quiescence)
	if _prewarm_cursor < 0:
		_prewarm_cursor = 0
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	while _prewarm_cursor < total:
		if not _pos_cache.has(_prewarm_cursor):
			_ensure_cached(_prewarm_cursor)
		_prewarm_cursor += 1
		if Time.get_ticks_usec() - t0 > budget_us:
			return                            # budget spent — resume next frame

## COSMOS FP-FIXED-FRAME re-anchor (§3): slide the absolute ring mesh by −A in lockstep with PlanetRoot + the
## ActiveFrame so the whole rendered planet stays continuous through a floating-origin shift. The offset survives a
## crossing (set_active re-applies _placement_xform, which now folds it in). No-op unless the fixed frame is on.
func shift_anchor(a: Vector3) -> void:
	if not (CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL):
		return
	_anchor_offset += a
	transform = _placement_xform()

## COSMOS FP-R0 SPIKE: hide these facets' flat quads (they are drawn as real rotated voxel terrains instead).
## Called only behind CubeSphere.FP_R0; on the shipped build nothing calls this so `_excluded` stays empty and the
## ring is byte-identical. Synchronous (a one-time spawn-setup call), unlike a crossing's deferred re-emit.
func set_excluded(fids: Array) -> void:
	_excluded.clear()
	for f in fids:
		_excluded[int(f)] = true
	force_rebuild()

## FP-M1c (docs/COSMOS-FP-M1-DESIGN.md §4.1): set the excluded flat-quad facets to the live neighbour pool and
## rebuild DEFERRED (budgeted _process) rather than synchronously — a pool spawn/retire/crossing must never pay a
## full ring regen on its own frame (§12.1c). No-op re-sets that leave the set unchanged skip the pending flag.
func set_pool_excluded(fids: Array) -> void:
	var next := {}
	for f in fids:
		next[int(f)] = true
	if next == _excluded:
		return
	_excluded = next
	_recompute_sticky()   # TIER-DEPTH P1: fold the new pool set into the sticky backstop (no-op with the flag off)
	_pending = true   # deferred rebuild (the crossing's set_active already re-placed the mesh rigidly)

## FP-S1(d): drive the deferred rebuild off the crossing frame. Cache-warm the newly-front-hemisphere facets under a
## per-frame ms budget; once they are all cached, do the single re-emit. Only active while a crossing is pending.
## COSMOS-PERF STEP 2: first drain any finished off-thread build (swap it in on the main thread). A new crossing that
## arrives while a build is in flight keeps _pending set but does NOT re-dispatch (_async_building gate) — it is served
## once the in-flight build lands, so the worker's read-only cache snapshot is never mutated under it.
func _process(_dt: float) -> void:
	_poll_async_rebuild()
	_prewarm_step(_dt)               # COSMOS-ORBITAL-SHELL S2: one-shot whole-planet warm (no-op unless FP_SHELL_PREWARM + off-surface)
	if _async_building:
		return
	# COSMOS-ORBITAL-SHELL S1: the emit cull axis + threshold — ĉ + cos(θ_emit) when the camera-set law is engaged,
	# else the shipped active-facet normal + BACK_CULL (byte-identical). Both _warm_front and the rebuild's
	# visible_fids() consume THIS pair, so the warmed set and the emitted set can never disagree.
	var p := _cull_params()
	if _shell_orbit():
		# COSMOS-PERF FALL-COLLAPSE FIX A (FP_SHELL_ORBIT_IDLE): idle short-circuit — once the front is fully warmed AND
		# emitted with nothing pending, skip the per-frame full 6·K² _warm_front scan (the ~67 ms airborne proc baseline)
		# until the next drift snapshot re-sets `_pending`. Mirrors the surface `_srf_converged` gate. Off ⇒ the scan runs
		# every frame exactly as today (byte-identical). The next drift (shell_set_camera_abs) clears it via `_pending`.
		if CubeSphere.FP_SHELL_ORBIT_IDLE and not _pending and _orbit_converged:
			return
		# COSMOS-ORBITAL-SHELL S1b (§3): TRUE ORBIT — progressive cached-subset emit. Never block the whole rebuild on
		# the ~1900-facet cap being cached in ONE frame (impossible under web ×25 warm cost → the live far-side stall).
		# Warm cumulatively under budget, emit the cache-ready subset now, re-emit as coverage grows (throttled by
		# SHELL_REEMIT_GROWTH). The async worker still reads only cache-ready facets (visible_fids cache-filters here).
		var done := _warm_front_step(p[0], p[1])
		if done:
			_warm_pass_count += 1
		else:
			_warm_fail_count += 1
		var sz := _pos_cache.size() + _bpos_cache.size()
		# Re-emit: on a fresh drift/engage (_pending); every SHELL_REEMIT_GROWTH newly-cached facets WHILE still filling
		# the front cap (progressive reveal); and ONCE when the front cap just finished caching (done ↑) to capture the
		# tail. Once done, the growth trigger is gated off so background prewarm back-filling never churns re-emits.
		var grew := (not done) and (sz - _last_emit_cache_size) >= CubeSphere.SHELL_REEMIT_GROWTH
		# FIX A2 (FP_SHELL_FALL_HOLD): a `_pending` (a genuine, now-throttled snapshot) or a floor-tail (done↑) re-emits
		# immediately; the PROGRESSIVE `grew` re-emit is throttled to ≤ 1/SHELL_FALL_REEMIT_MS so a cap that can't fully
		# warm within budget on web (done never true) cannot fire a SYNCHRONOUS _rebuild_full every few frames (the spikes).
		var grew_ok := grew
		if CubeSphere.FP_SHELL_FALL_HOLD and grew and not _pending:
			grew_ok = Time.get_ticks_msec() - _last_rebuild_ms >= CubeSphere.SHELL_FALL_REEMIT_MS
		if _pending or grew_ok or (done and not _was_done):
			_last_emit_cache_size = sz
			_emit_cached_only = true
			_begin_rebuild()
			_last_rebuild_ms = Time.get_ticks_msec()
		_was_done = done
		# FIX A: converged once the front is fully warmed AND the pending emit has been consumed (async clears _pending
		# in _dispatch_async_rebuild). The next drift snapshot re-sets _pending, which the top-of-branch gate honours.
		_orbit_converged = done and not _pending
	elif TierPlace.warm_converge_on():
		# TIER-DEPTH warm-converge: the SURFACE path adopts the progressive discipline so a stale un-sunk backstop quad
		# never lingers over live near meshes while the dense caches warm (the over-near strip / sh_wfail thrash).
		_surface_converge_emit(p)
	else:
		# SURFACE (floored) / shipped: the all-or-nothing warm gate (byte-identical; the worker never sees an uncached facet).
		if not _pending:
			return
		_emit_cached_only = false
		if _warm_front_step(p[0], p[1]):   # all front-hemisphere facets cached → safe to re-emit this frame
			_warm_pass_count += 1
			_begin_rebuild()
		else:
			_warm_fail_count += 1

## COSMOS TIER-DEPTH-PRIORITY warm-converge (FP_TIER_WARM_CONVERGE, §5.3 / §7 P1): the SURFACE progressive-emit driver
## that replaces the all-or-nothing warm gate. Warm cumulatively under WARM_BUDGET_MS, then emit the cache-ready subset
## (visible_fids(true) filters an uncached backstop OUT — it is never drawn as a stale un-sunk quad), re-emitting the
## MOMENT a new dense backstop cache lands so a just-entered pool facet flips to SUNK the frame it is ready (kills the
## over-near strip); far-horizon coarse growth batches at SHELL_REEMIT_GROWTH (its transient holes sit behind the near
## disk). Idle short-circuit preserves the shipped zero-cost steady state: once the whole front is cached AND emitted
## (`_srf_converged`) it does no work until the next role-event (`_pending`). `p` = [cull axis, cos threshold] (shipped
## active-facet law on the surface). Bounded re-emits (≤ backstop count) + scalar state ⇒ NEVER-OOM.
func _surface_converge_emit(p: Array) -> void:
	if not _pending and _srf_converged:
		return                                    # steady state — no per-frame warm scan (matches the shipped idle frame)
	_emit_cached_only = true
	var done := _warm_front_step(p[0], p[1])
	if done:
		_warm_pass_count += 1
	else:
		_warm_fail_count += 1
	var b_ready := _bpos_cache.size()             # a grown dense cache == a new sunk backstop ready to replace a stale quad
	var c_ready := _pos_cache.size()
	var back_grew := b_ready > _srf_last_bcache
	var horizon_grew := (c_ready - _srf_last_ccache) >= CubeSphere.SHELL_REEMIT_GROWTH
	if _pending or back_grew or horizon_grew or (done and not _srf_was_done):
		_srf_last_bcache = b_ready
		_srf_last_ccache = c_ready
		_begin_rebuild()                          # emits visible_fids(true) — cache-ready facets only, sunk backstops included
	_srf_was_done = done
	_srf_converged = done                         # fully cached + emitted ⇒ idle until the next role-event re-sets _pending

## COSMOS-ORBITAL-SHELL S1 (§3): the current emit cull axis + cos-threshold. With the camera-set law engaged
## (FP_SHELL_CAMERA_SET, driver called) it is [ĉ_abs, cos(θ_emit)]; otherwise the SHIPPED [active-facet normal,
## BACK_CULL] — so with the flag off the emitted set is computed exactly as today (byte-identical), and on the
## floored surface (θ_emit ≥ 90° ⇒ cos ≈ BACK_CULL) it differs from the active-facet law only in facets behind
## the limb (byte-visually identical). Called on the main thread only (the async worker snapshots visible_fids()).
func _cull_params() -> Array:
	if _cam_set:
		return [_emit_axis, _emit_cos]
	return [FacetAtlas.facet_normal64(_active_fid), BACK_CULL]

## COSMOS-ORBITAL-SHELL (live fix 2026-07-19): the TRUE-ORBIT regime — the camera-set law engaged AND off-surface
## (not floored). Off-surface there is NO near voxel field over the ground under the camera (the near disk sits at
## the player's FLIGHT altitude, hundreds of blocks up, not on the ground), so the "backstop" role (sunk, meant to
## hide BEHIND near voxels) and the active/`_excluded` EXCLUSION (near voxels own that facet) are both WRONG here:
## they leave a HOLE at the sub-camera facet that SWEEPS as the active facet churns (~1 facet / 3 frames in orbit) —
## the live "facets under me disappear" flicker. In this regime the shell OWNS the sub-camera facet, drawn as a
## regular coarse facet from the prewarm-filled coarse cache (always ready ⇒ no warm hole; un-sunk ⇒ true surface).
## Byte-identical off (flag off ⇒ `_cam_set` false) and on the surface (floored ⇒ shipped exclusion / backstop).
func _shell_orbit() -> bool:
	return _cam_set and not _emit_floored_last

## COSMOS-PERF STEP 2: whether the off-main-thread rebuild path is live (flag on AND real background workers exist —
## a single-core build has no worker to flip is_task_completed, so it must fall back to the synchronous rebuild).
func _async_enabled() -> bool:
	return CubeSphere.FP_FARRING_ASYNC_REBUILD and OS.get_processor_count() > 1

## Complete a warmed pending rebuild: dispatch it to a worker (async path) or build it inline (synchronous fallback).
func _begin_rebuild() -> void:
	_begin_rebuild_count += 1        # S1b telemetry: prove the emit actually runs post-engage (0 ⇒ warm-gate stall)
	if _async_enabled():
		_dispatch_async_rebuild()
	else:
		_rebuild_full()

## MAIN THREAD: snapshot the (already-warmed) visible set and hand the whole mesh-DATA build to a worker. The caches the
## worker reads are frozen for its lifetime — _process will not warm/dispatch again while _async_building (the gate in
## _process), and force_rebuild/set_excluded join first — so the worker only ever READS _pos_cache/_col_cache.
func _dispatch_async_rebuild() -> void:
	transform = _placement_xform()   # rigid re-place is cheap + main-thread-only (same as _rebuild_full's first line)
	# S1b: in the true-orbit progressive path _emit_cached_only filters to cache-ready facets, so the worker (which reads
	# _pos_cache/_bpos_cache) never touches an uncached facet; every other path passes false ⇒ the shipped full front set.
	_async_fids = visible_fids(_emit_cached_only)
	# COSMOS far-ring full coverage (§4): freeze the backstop role on the MAIN thread so the worker never reads `_excluded`
	# live (set_pool_excluded may mutate it mid-run). Only populated under FULL_COVER; empty otherwise → worker sinks nothing.
	_async_backstop = {}
	if CubeSphere.FP_FARRING_FULL_COVER:
		for fid in _async_fids:
			if _is_backstop(fid):
				_async_backstop[fid] = true
	_async_arrays = []
	_pending = false                 # consumed — a fresh crossing sets it again and is served after this build lands
	_async_building = true
	_async_task_id = WorkerThreadPool.add_task(Callable(self, "_async_build_worker"), false, "far-ring mesh rebuild")

## WORKER THREAD: pure CPU. Emits the visible facets' cached pos/col into a SurfaceTool, computes the GLOBAL smooth
## normals, and extracts the raw surface arrays via commit_to_arrays — which, unlike commit(), creates NO mesh RID and
## touches NO RenderingServer. The arrays are BIT-IDENTICAL to what the synchronous commit() would store (proven by
## G-L1-FARRING-ASYNC). NOTHING here reads the scene tree or a rendering server.
func _async_build_worker() -> void:
	var t0 := Time.get_ticks_usec()   # T2e: off-thread build wall time (read on main after is_task_completed)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in _async_fids:
		# backstop role read from the FROZEN snapshot (never `_excluded` live) — the const read is thread-safe.
		_emit_cached(st, fid, CubeSphere.FP_FARRING_FULL_COVER and _async_backstop.has(fid))
	st.generate_normals()
	_async_arrays = st.commit_to_arrays()
	_async_build_us = Time.get_ticks_usec() - t0

## MAIN THREAD: swap a finished off-thread build onto the MeshInstance3D. The double-buffer is implicit — the previous
## _mi.mesh stayed assigned (and visible) for the whole worker run; here we replace it with the freshly built one. This
## is the ONLY RenderingServer touch of the async path (the add_surface_from_arrays / mesh RID create + assignment).
func _poll_async_rebuild() -> void:
	if not _async_building:
		return
	if not WorkerThreadPool.is_task_completed(_async_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_async_task_id)   # already done — reclaims the handle (never blocks here)
	_swap_in_arrays(_async_arrays, _async_fids)
	_async_task_id = -1
	_async_arrays = []
	_async_building = false

## MAIN THREAD: build the ArrayMesh from the worker's surface arrays and assign it, then update the committed-set gate
## state exactly as _rebuild_full does (so emitted_count/reemit_count/_emitted are identical to the synchronous path).
## An empty visible set (fully back-facing) yields an empty ArrayMesh — matching _build_fast's empty-mesh contract.
func _swap_in_arrays(arrays: Array, fids: PackedInt32Array) -> void:
	var t_swap := Time.get_ticks_usec()   # T2e: main-thread swap (add_surface_from_arrays / RID create + instance update)
	var mesh := ArrayMesh.new()
	var verts := 0
	if arrays.size() == Mesh.ARRAY_MAX and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		verts = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_mi.mesh = mesh
	_emitted.clear()
	_emitted_backstop.clear()   # TIER-DEPTH P1: the async build drew the FROZEN `_async_backstop` roles as sunk
	for fid in fids:
		_emitted[fid] = true
		if _async_backstop.has(fid):
			_emitted_backstop[fid] = true
	_reemit_count += 1
	_push_event("async", _async_build_us, Time.get_ticks_usec() - t_swap, verts)

## Warm (noise-cache) every uncached front-hemisphere facet under WARM_BUDGET_MS. Returns true once none remain
## uncached (rebuild may proceed), false when the frame budget is spent (resume next frame). The scan itself is a
## cheap cached-dot classification; only _ensure_cached (25 sphere-profile samples) is budgeted.
func _warm_front(nrm: Array, thresh: float) -> bool:
	var k := FacetAtlas.K
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				# COSMOS far-ring full coverage (§4): backstop facets warm their DENSE cache; every other facet the
				# shipped grid cache. Warming on the MAIN thread here (before any async dispatch) keeps the worker's
				# read-only cache contract — the worker only ever reads _bpos_cache/_pos_cache, never builds them.
				if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
					if not _bpos_cache.has(fid):
						_ensure_backstop_cached(fid)
				elif not _pos_cache.has(fid):
					_ensure_cached(fid)
				if Time.get_ticks_usec() - t0 > budget_us:
					return false     # budget spent — finish warming next frame
	return true

## COSMOS-PERF FALL-COLLAPSE FIX D (FP_WARM_TRUE_BUDGET, R1) — the warm-path dispatcher. Off ⇒ the shipped _warm_front
## verbatim (byte-identical). On ⇒ the "true budget" scan below. All three _process warm sites route through here so
## surface (walk) + orbit (fall) both get the convergence fix.
func _warm_front_step(nrm: Array, thresh: float) -> bool:
	if CubeSphere.FP_WARM_TRUE_BUDGET:
		return _warm_front_true_budget(nrm, thresh)
	return _warm_front(nrm, thresh)

## COSMOS-PERF FALL-COLLAPSE FIX D (R1) — build the packed centre-dir array ONCE (6·K² Vector3). Iterated inline by
## _warm_front_true_budget so the scan avoids the per-fid _centre_dir dict lookup. Idempotent; bounded ⇒ NEVER-OOM.
func _ensure_centre_pack() -> void:
	var total := 6 * FacetAtlas.K * FacetAtlas.K
	if _centre_pack.size() == total:
		return
	_centre_pack.resize(total)
	for fid in range(total):
		var cd := _facet_centre_dir(fid)
		_centre_pack[fid] = Vector3(cd[0], cd[1], cd[2])

## COSMOS-PERF FALL-COLLAPSE FIX D (R1) — the "true warm budget" front-hemisphere warm. Scans the whole front (inline
## over the packed centre-dir array — no per-fid dict lookup / function call) and warms uncached facets, but charges
## ONLY the actual _ensure_cached WORK against WARM_BUDGET_MS, never the read-only scan. Returns true the moment a full
## scan finds NOTHING uncached — regardless of elapsed time. That is the R1 fix: the shipped _warm_front charges the
## whole 3456-facet scan against the budget, so on web ×25 the scan alone exceeds 3 ms and it returns false FOREVER even
## when every facet is cached (`done` unreachable → the idle gates never engage → ~3 ms/frame + sh_wfail burned in every
## mode). Here `done` becomes reachable, so the warm CONVERGES and the caller's idle short-circuit then stops the scan.
## `_front_visible`'s active/excluded skip is inlined (surface only, per the shipped law). NEVER-OOM: caches only grow,
## one fixed packed array. Returns false when the WARM budget is spent mid-scan (uncached facets remain — resume next frame).
func _warm_front_true_budget(nrm: Array, thresh: float) -> bool:
	_ensure_centre_pack()
	var total := 6 * FacetAtlas.K * FacetAtlas.K
	var nv := Vector3(nrm[0], nrm[1], nrm[2])
	var full_cover := CubeSphere.FP_FARRING_FULL_COVER
	var surface_skip := not full_cover and not _shell_orbit()   # the shipped active/excluded skip applies on the surface only
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	var warm_us := 0                                            # ONLY real _ensure_cached time is charged (R1)
	var clean := true                                          # no uncached front facet met this scan ⇒ converged
	for fid in range(total):
		if _centre_pack[fid].dot(nv) < thresh:                 # back-hemisphere cull (cheapest, rejects most fids) — read-only, not budgeted
			continue
		if surface_skip and (fid == _active_fid or _excluded.has(fid)):
			continue
		if full_cover and _is_backstop(fid):
			if not _bpos_cache.has(fid):
				clean = false
				var w0 := Time.get_ticks_usec()
				_ensure_backstop_cached(fid)
				warm_us += Time.get_ticks_usec() - w0
				if warm_us > budget_us:
					return false                              # WARM budget spent (not the scan) — more to warm next frame
		elif not _pos_cache.has(fid):
			clean = false
			var w1 := Time.get_ticks_usec()
			_ensure_cached(fid)
			warm_us += Time.get_ticks_usec() - w1
			if warm_us > budget_us:
				return false
	return clean                                              # full scan, nothing left to warm ⇒ CONVERGED (regardless of scan time)

## `thresh` is the emit cut on cd·nrm: the shipped BACK_CULL (front-hemisphere) under the active-facet law, or
## cos(θ_emit) under the COSMOS-ORBITAL-SHELL S1 camera-set law. The active/excluded skip is axis-independent
## (near voxels cover those facets), so the shell law changes only the axis (nrm) + the cut (thresh), never this.
func _front_visible(fid: int, nrm: Array, thresh: float) -> bool:
	# COSMOS far-ring full coverage (§2): with FP_FARRING_FULL_COVER on, the active facet + `_excluded` set are NO
	# LONGER skipped — they are drawn as sunk "backstop" facets (see _is_backstop / _emit_cached) so the near-disk
	# annular hole is filled. Only the back-hemisphere cull remains. With the flag off, the shipped exclusions apply
	# verbatim (byte-identical: active + `_excluded` absent from the visible set).
	# COSMOS-ORBITAL-SHELL live fix: the active/`_excluded` skip is a SURFACE assumption (near voxels cover those
	# facets). OFF-SURFACE (_shell_orbit) there are no near voxels over the ground under the camera, so skipping them
	# leaves a sweeping hole — the shell must draw the sub-camera facet. So the skip applies only on the surface /
	# flag-off (byte-identical). Under FULL_COVER the skip is already bypassed (they draw as backstops on the surface).
	if not CubeSphere.FP_FARRING_FULL_COVER and not _shell_orbit():
		if fid == _active_fid:
			return false                 # the near voxel world already covers the active facet (surface only)
		if _excluded.has(fid):
			return false                 # FP-R0 SPIKE: drawn as a real rotated voxel terrain, not a flat quad
	var cd := _centre_dir(fid)
	return cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] >= thresh

## COSMOS far-ring full coverage (§2): a "backstop" facet is one the near voxel world / live pool overlaps (the active
## facet or a live-pool-`_excluded` facet). Under FP_FARRING_FULL_COVER these are drawn from the dense `_bpos_cache` at
## BACKSTOP_CELLS and sunk radially by BACKSTOP_SINK at emit; every other front-hemisphere facet keeps its exact shipped
## CELLS geometry. Role is decided at emit time (keyed by the current active/excluded state), never baked into a cache.
func _is_backstop(fid: int) -> bool:
	# COSMOS-ORBITAL-SHELL live fix: OFF-SURFACE (_shell_orbit) there are no near voxels to sink behind, and the dense
	# backstop cache churns/holes as the active facet sweeps in orbit. Draw the sub-camera facet as a regular coarse
	# facet instead (coarse cache is prewarm-filled ⇒ never a warm hole; un-sunk ⇒ true surface). On the surface /
	# flag-off _shell_orbit() is false ⇒ the shipped backstop set (active ∪ `_excluded` ∪ `_sticky`), byte-identical.
	if _shell_orbit():
		return false
	return fid == _active_fid or _excluded.has(fid) or _sticky.has(fid)

## COSMOS TIER-DEPTH-PRIORITY P1 (§5.3): recompute the sticky backstop set on a role-event (set_active / set_pool_excluded
## / setup). Make-before-break: the TARGET = active ∪ ring-1 neighbours (the design's set; a facet the player can cross into
## is a seam neighbour = ring-1, so it is already drawn sunk BEFORE it enters the pool and near meshes arrive). Unsink-late
## ("recently-active"): a facet that WAS sticky but is no longer a target keeps its role for STICKY_HOLD more role-events (a
## hold countdown), so a just-departed facet never reverts to a coarse unsunk quad while its near meshes may still be
## applied. Pool facets OUTSIDE ring-1 are already backstop via `_excluded.has` (unioned in `_is_backstop`) and revert
## benignly (a dip) when they leave — so they are deliberately NOT unioned into the TARGET, keeping `_sticky` rigorously
## bounded by ring-1 (≤ STICKY_RING1_MAX, the +96 kB dense-cache ceiling). No-op (empty `_sticky`) unless the flag is on.
func _recompute_sticky() -> void:
	if not TierPlace.sticky_on():
		return
	var target := {}
	for f in TierPlace.ring1(_active_fid):
		target[int(f)] = true
	# Grow eagerly: every target is sticky now, hold refreshed to full.
	for f in target.keys():
		_sticky[int(f)] = true
		_sticky_hold[int(f)] = CubeSphere.STICKY_HOLD
	# Shrink lazily: a sticky facet no longer targeted decrements its hold; only at 0 does it drop.
	for f in _sticky.keys():
		if target.has(int(f)):
			continue
		var h := int(_sticky_hold.get(int(f), 0)) - 1
		if h <= 0:
			_sticky.erase(int(f))
			_sticky_hold.erase(int(f))
		else:
			_sticky_hold[int(f)] = h

## The full scan + re-emit + commit (the OLD _rebuild). Runs at setup, from _process once warming completes, and
## from force_rebuild (the gate). NOT called synchronously by a crossing — that is the whole point of FP-S1(d).
func _rebuild_full() -> void:
	transform = _placement_xform()   # absolute → active-lattice render frame (identity under FP-FIXED-FRAME)
	var fids := visible_fids(_emit_cached_only)   # S1b: cache-filtered in the true-orbit progressive path, full set otherwise (shipped)
	_emitted.clear()
	_emitted_backstop.clear()   # TIER-DEPTH P1: record which fids this build draws SUNK (the make-before-break gate reads it)
	for fid in fids:
		_ensure_emit_cached(fid)
		_emitted[fid] = true
		if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
			_emitted_backstop[fid] = true
	# COSMOS-PERF L1: pick the mesh assembler. FAST = packed-array memcpy + one add_surface_from_arrays; the shipped
	# SurfaceTool path stays the default (byte-identical mesh). Both consume the SAME visible fids in the SAME order.
	# T2e: time the mesh BUILD (assembler) and the SWAP (mesh assign / RID create + instance update) separately — two
	# ticks_usec reads either side of the split assignment, telemetry-only, no behavioural change.
	var t_build := Time.get_ticks_usec()
	var new_mesh: Mesh = _build_fast(fids) if CubeSphere.FP_FARRING_FAST_REBUILD else _build_surfacetool(fids)
	var build_us := Time.get_ticks_usec() - t_build
	var t_swap := Time.get_ticks_usec()
	_mi.mesh = new_mesh
	var swap_us := Time.get_ticks_usec() - t_swap
	_reemit_count += 1
	_pending = false
	# 32 tris/facet at CELLS=4; under FULL_COVER the backstop facets are denser (2·BACKSTOP_CELLS²) — count them exactly.
	var tris := fids.size() * CELLS * CELLS * 2
	if CubeSphere.FP_FARRING_FULL_COVER:
		var extra := (CubeSphere.BACKSTOP_CELLS * CubeSphere.BACKSTOP_CELLS - CELLS * CELLS) * 2
		for fid in fids:
			if _is_backstop(fid):
				tris += extra
	_push_event("sync", build_us, swap_us, tris * 3)   # T2e: verts = 3·tris (cheap; no surface read-back on the crossing frame)
	print("[FP2] facet far ring: %d triangles around facet %d (%d facets cached, %d backstop)" % [tris, _active_fid, _pos_cache.size(), _bpos_cache.size()])

## The front-hemisphere visible fid set (front-facing, non-active, non-excluded), in canonical face/a/b order. Both
## mesh assemblers + the equivalence gate consume this so their vertex/color/normal arrays are index-aligned.
func visible_fids(cached_only := false) -> PackedInt32Array:
	var out := PackedInt32Array()
	var k := FacetAtlas.K
	# COSMOS-ORBITAL-SHELL S1: the same cull axis + threshold _warm_front consumed, so the warmed and emitted sets agree.
	var p := _cull_params()
	var nrm: Array = p[0]
	var thresh: float = p[1]
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				# S1b: the true-orbit progressive path emits only cache-ready facets (grows as the cache fills); every
				# other caller passes cached_only=false ⇒ the shipped full front set (byte-identical).
				if cached_only and not _emit_cache_ready(fid):
					continue
				out.append(fid)
	return out

## COSMOS-ORBITAL-SHELL S1b (§3): is facet `fid`'s emit cache present? Backstop facets (FULL_COVER) render from the
## dense _bpos_cache; every other facet from the shipped coarse _pos_cache. Used to filter the progressive orbit set
## so the async worker (and the sync assembler) only ever touch a facet whose cache exists.
func _emit_cache_ready(fid: int) -> bool:
	if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
		return _bpos_cache.has(fid)
	return _pos_cache.has(fid)

## SHIPPED assembler: per-vertex SurfaceTool emission + generate_normals (the ~332k GDScript→C++ round-trip path).
func _build_surfacetool(fids: PackedInt32Array) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in fids:
		_ensure_emit_cached(fid)
		_emit_cached(st, fid, CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid))   # main thread — live role is safe
	st.generate_normals()
	return st.commit()

## FAST assembler (L1): concat the pre-triangulated per-facet pos/col caches into two big packed arrays (C++ memcpy),
## build a normal-less mesh, then let SurfaceTool COMPUTE the normals via create_from + generate_normals — both C++,
## so NONE of the ~332k per-vertex GDScript→C++ round-trips of the shipped path remain, yet the normals are the SAME
## GLOBALLY-smoothed array (create_from replays the identical vertex list into the identical generate_normals, seams
## and all). A few ms of memcpy + one C++ normal pass, vs 300–700 ms of GDScript emission.
func _build_fast(fids: PackedInt32Array) -> Mesh:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for fid in fids:
		# COSMOS far-ring full coverage (§4): a sunk backstop facet cannot ride the pre-triangulated memcpy (its
		# vertices are pushed radially inward per-vertex at BACKSTOP_CELLS). Under FULL_COVER it falls back to the
		# per-vertex sunk expansion (a handful of facets — §5); non-backstop facets keep the memcpy fast path. The
		# vertex order/winding matches _emit_cached exactly, so the later global generate_normals is bit-identical.
		if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
			_append_backstop_tris(pos, col, fid)
		else:
			_ensure_tri_cached(fid)
			pos.append_array(_tri_pos_cache[fid])
			col.append_array(_tri_col_cache[fid])
	if pos.size() == 0:
		return ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_COLOR] = col
	var flat := ArrayMesh.new()
	flat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)   # normal-less; positions + colors only
	var st := SurfaceTool.new()
	st.create_from(flat, 0)                                       # C++ read-back of the vertex list (no GDScript per-vert)
	st.generate_normals()                                        # C++ GLOBAL smoothing — bit-identical to the shipped path
	return st.commit()

## FP-S1(d) gate helper: synchronously complete a pending deferred rebuild (what _process does over budgeted frames)
## so headless gates — which do not step frames — can assert the post-crossing visible set. COSMOS-PERF STEP 2: joins
## any in-flight off-thread build first (so the caches are quiescent), then rebuilds synchronously — force_rebuild is
## always immediate + main-thread, regardless of the async flag.
func force_rebuild() -> void:
	_join_async_rebuild()
	_emit_cached_only = false        # S1b: force_rebuild always emits the FULL front set (warms as needed) — gate + set_excluded semantics
	_rebuild_full()

## COSMOS-PERF STEP 2: block until any in-flight worker finishes and discard its result (a synchronous rebuild is about
## to overwrite it). Called before force_rebuild/set_excluded (which rebuild inline) and on _exit_tree (the worker reads
## this node's caches — it must not outlive the node). No-op when nothing is in flight.
func _join_async_rebuild() -> void:
	if not _async_building:
		return
	WorkerThreadPool.wait_for_task_completion(_async_task_id)
	_async_task_id = -1
	_async_arrays = []
	_async_building = false

## COSMOS-PERF STEP 2: never free while a worker is still reading our caches.
func _exit_tree() -> void:
	_join_async_rebuild()

# --- T2e far-ring build/swap timing events ---
## Push one rebuild's timing record. `path` = "sync"|"async"; build_ms = mesh assembly (off-thread for async), swap_ms =
## the main-thread RID create/instance update, verts = the committed vertex count. Main-thread only in both paths.
func _push_event(path: String, build_us: int, swap_us: int, verts: int) -> void:
	_events.append({
		"type": "farring", "path": path,
		"build_ms": snappedf(float(build_us) / 1000.0, 0.01),
		"swap_ms": snappedf(float(swap_us) / 1000.0, 0.01),
		"verts": verts,
	})
	while _events.size() > EVENTS_MAX:
		_events.pop_front()   # NEVER-OOM: drop the oldest if no bridge is draining

## Drain the pending far-ring timing records (FIFO), clearing the queue. WorldManager.take_farring_events() delegates here.
func take_events() -> Array:
	if _events.is_empty():
		return []
	var out := _events
	_events = []
	return out

# --- gate diagnostics ---
func is_rebuild_pending() -> bool: return _pending
func reemit_count() -> int: return _reemit_count
func snapshot_count() -> int: return _snapshot_count            # FIX A2 (G-SHELL-FALLHOLD): scheduled re-emits — flat during a held fall
func warm_fail_count() -> int: return _warm_fail_count          # FIX D (G-WARM-TRUE-BUDGET): sh_wfail — must FLATLINE once the warm converges
func warm_front_step(nrm: Array, thresh: float) -> bool: return _warm_front_step(nrm, thresh)   # FIX D: gate driver entry
func is_emitted(fid: int) -> bool: return _emitted.has(fid)
func emitted_count() -> int: return _emitted.size()
func is_backstop(fid: int) -> bool: return _is_backstop(fid)     # COSMOS far-ring full coverage — gate visibility
func backstop_cache_size() -> int: return _bpos_cache.size()     # G-FRC-BOUND: dense caches ≤ 5-facet bound
func is_emitted_backstop(fid: int) -> bool: return _emitted_backstop.has(fid)   # TIER-DEPTH P1: fid drawn SUNK in the committed mesh
func is_sticky(fid: int) -> bool: return _sticky.has(fid)        # TIER-DEPTH P1 gate visibility
func sticky_count() -> int: return _sticky.size()               # TIER-DEPTH P1: sticky set ≤ STICKY_RING1_MAX bound
# COSMOS-ORBITAL-SHELL S1/S2 gate visibility
func shell_cam_set() -> bool: return _cam_set                   # is the camera-set law currently governing the emit set
func shell_emit_axis() -> Array: return _emit_axis              # ĉ (ABSOLUTE): the current emit cull axis
func shell_emit_cos() -> float: return _emit_cos                # cos(θ_emit): the current emit threshold
func coarse_cache_size() -> int: return _pos_cache.size()       # S2: how many facets' coarse caches are warmed (prewarm ≤ 6·K²)
func prewarm_cursor() -> int: return _prewarm_cursor            # S2: prewarm progress (≥ 6·K² ⇒ one-shot complete)

## COSMOS-ORBITAL-SHELL live-path telemetry (remote_bridge streams this) — disambiguates the driver→warm→emit→draw
## chain the direct-call gates never exercised. Returns {} when the camera-set law is NOT engaged (flag off / never
## driven) so a shipped/flag-off build stamps NOTHING (byte-identical telemetry). Fields:
##  sh_cam       camera-set law engaged
##  sh_emit      emitted facet count (H-A: small/stuck; H-B: ~= visN but the far side is still blank ⇒ a DRAW problem)
##  sh_visN      front-visible target count under the current axis (what SHOULD be emitted)
##  sh_cachedN   how many of the target are cache-ready right now (H-A: cachedN << visN ⇒ warm/prewarm is the bottleneck)
##  sh_cached / sh_bcached / sh_prewarm   coarse+dense cache fill + the one-shot prewarm cursor (→ 6·K² = complete)
##  sh_off / sh_dwell / sh_pend / sh_build   driver arming + pipeline state
##  sh_reemit / sh_begin / sh_wpass / sh_wfail   re-emit + begin_rebuild counts + warm pass/fail (H-A: wfail≫0, begin≈0)
##  sh_axdot     dot(_emit_axis, true sub-camera dir) — ~1 aligned; low/negative ⇒ H-C (wrong emit hemisphere)
##  sh_theta / sh_d / sh_h / sh_scale   θ_emit(deg), distance, altitude, SN3 clamp scale (H-B far-plane/placement signal)
func shell_telemetry() -> Dictionary:
	if not _cam_set:
		return {}
	var p := _cull_params()
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var visN := 0
	var cachedN := 0
	var k := FacetAtlas.K
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if _front_visible(fid, nrm, thresh):
					visN += 1
					if _emit_cache_ready(fid):
						cachedN += 1
	var axdot: float = _emit_axis[0] * _dbg_true_dir[0] + _emit_axis[1] * _dbg_true_dir[1] + _emit_axis[2] * _dbg_true_dir[2]
	return {
		"sh_cam": _cam_set,
		"sh_emit": _emitted.size(),
		"sh_visN": visN,
		"sh_cachedN": cachedN,
		"sh_cached": _pos_cache.size(),
		"sh_bcached": _bpos_cache.size(),
		"sh_prewarm": _prewarm_cursor,
		"sh_off": _offsurface,
		"sh_dwell": snappedf(_offsurface_dwell, 0.1),
		"sh_pend": _pending,
		"sh_build": _async_building,
		"sh_reemit": _reemit_count,
		"sh_begin": _begin_rebuild_count,
		"sh_wpass": _warm_pass_count,
		"sh_wfail": _warm_fail_count,
		"sh_axdot": snappedf(axdot, 0.001),
		"sh_theta": snappedf(_dbg_theta_emit_deg, 0.1),
		"sh_d": snappedf(_dbg_d, 0.1),
		"sh_h": snappedf(_dbg_h, 0.1),
		"sh_scale": snappedf(_dbg_scale, 0.0001),
	}

## COSMOS FS1 gate (G-SHELL-WELD): the horizon (CELLS) ABSOLUTE positions for facet `fid` — warms + returns the cache.
func horizon_positions(fid: int) -> PackedVector3Array:
	_ensure_cached(fid)
	return _pos_cache[fid]

## TIER-DEPTH P2 gate: the SUNK (as-rendered) dense backstop vertex positions for facet `fid` — the cache (envelope or
## constant-relief) pushed in by the current emit sink (TierPlace.backstop_sink). The gate projects these onto the near
## height field (world_to_lattice64) to prove the rendered coarse surface never rises above the near block tops.
func backstop_rendered_positions(fid: int) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _sunk_positions(_bpos_cache[fid])

## TIER-DEPTH P2 gate: the RAW (un-sunk) dense backstop cache for facet `fid` — the ENVELOPE heights under FP_TIER_ENVELOPE,
## the plain profile_at_dir relief otherwise. The gate applies its OWN fixed ε sink to this so it can prove the ENVELOPE
## property in isolation (a lower bound at a small sink) vs the plain sample (which needs the full 6-block sink to hold).
func backstop_raw_positions(fid: int) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _bpos_cache[fid]

# Compute + cache facet `fid`'s ABSOLUTE-coord terrain quad once (built from its planarized corners + radial relief).
func _ensure_cached(fid: int) -> void:
	if _pos_cache.has(fid):
		return
	# COSMOS FS1 (§4.1): the WELD path emits every vertex RADIALLY from the SHARED cube-sphere corner dirs, so a
	# facet's edge welds bit-identically to its neighbour's (One-Surface Law). Textually separate from the shipped
	# planar-corner path so flag-off is byte-identical.
	if CubeSphere.FP_SHELL_WELD:
		var cd := FacetAtlas.facet_corner_dirs(fid)
		var pos := PackedVector3Array()
		var col := PackedColorArray()
		var stride := CELLS + 1
		for gj in range(stride):
			for gi in range(stride):
				_weld_node(cd, float(gi) / float(CELLS), float(gj) / float(CELLS), pos, col)
		# CELLS is the coarse resolution — the coarse-owns-edge snap is a no-op here (cstride==1).
		_pos_cache[fid] = pos
		_col_cache[fid] = col
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var stride := CELLS + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(CELLS)
			var t := float(gj) / float(CELLS)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE (node placed by transform)
			# far water iff g < SEA_LEVEL — STRICT, matching near's sea fill (g < y <= SEA_LEVEL, so g==SEA_LEVEL is DRY
			# beach/shelf sand, not water). `<=` painted the flattened beach shelf (a wide band quantized to g==SEA_LEVEL)
			# as water over near's sand. Matches the already-correct far_mesh_builder.gd classifier.
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	_pos_cache[fid] = pos
	_col_cache[fid] = col

## COSMOS far-ring full coverage (§4): ensure the emit cache appropriate to facet `fid`'s CURRENT role — the dense
## backstop cache for a backstop facet under FULL_COVER, else the shipped CELLS grid. Called by every synchronous
## assembler path before it emits; the async path warms these on the main thread in _warm_front instead.
func _ensure_emit_cached(fid: int) -> void:
	if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
		_ensure_backstop_cached(fid)
	else:
		_ensure_cached(fid)

## COSMOS far-ring full coverage (§3): compute + cache facet `fid`'s DENSE (BACKSTOP_CELLS) ABSOLUTE-coord terrain quad
## once. Identical construction to _ensure_cached (planar corners + radial relief + FarPalette colour) but at the denser
## resolution so the between-sample chord error stays below the near mountain relief. The BACKSTOP_SINK radial push is
## NOT baked here — it is applied per emitted vertex (so the cache is role-agnostic and survives a crossing unchanged).
func _ensure_backstop_cached(fid: int) -> void:
	if _bpos_cache.has(fid):
		return
	# TIER-DEPTH P2 (§5.1): under the min-envelope rule each vertex height becomes a PROVABLE lower bound of the near
	# surface over its dilated footprint, replacing the constant sink. Separate builder so the flag-off path is textually
	# the shipped per-vertex profile sample (byte-identical).
	if TierPlace.envelope_on():
		_ensure_backstop_cached_env(fid)
		return
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	# COSMOS FS1 (§4.1/§4.2): radial weld from shared corner dirs + the coarse-owns-edge T-junction (the dense
	# BACKSTOP_CELLS outer ring is snapped onto the CELLS=4 coarse chord so it welds a horizon 4-edge crack-free).
	if CubeSphere.FP_SHELL_WELD:
		var cd := FacetAtlas.facet_corner_dirs(fid)
		for gj in range(stride):
			for gi in range(stride):
				_weld_node(cd, float(gi) / float(cells), float(gj) / float(cells), pos, col)
		_weld_snap_edges(pos, cells)
		_bpos_cache[fid] = pos
		_bcol_cache[fid] = col
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE, un-sunk
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## TIER-DEPTH P2 (§5.1): the MIN-ENVELOPE dense backstop cache. Each of the (BACKSTOP_CELLS+1)² coarse vertices keeps its
## own planar position b and radial direction d̂ (grid unchanged — NOT a re-mesh), but its HEIGHT becomes a provable lower
## bound of the near surface: the MINIMUM near g over the vertex's 2×2-coarse-cell footprint DILATED by the radial-vs-
## normal skew reach, sampled on a fine grid at ENV_FINE_MULT × the coarse resolution. A rendered backstop triangle is a
## convex combination of three such corner minima, so it stays ≤ the near surface everywhere in the overlap BY
## CONSTRUCTION (no tuned constant — the proof). The small radial ε sink at emit (TierPlace.backstop_sink) covers the
## sub-fine-sample residual + f32 rounding. Colour is the vertex's OWN direct biome/water sample (cosmetic). Costs
## ~(ENV_FINE_MULT·cells+1)² transient profile_at_dir samples at cache build; ZERO persistent bytes (same 17² grid). Uses
## the far ring's own profile_at_dir funnel (byte-equal to sample_columns by the one-sampler law), so no facet-param→
## lattice remap is introduced. NEVER-OOM: the fine grid is transient and bounded; no cache grows with walk distance.
func _ensure_backstop_cached_env(fid: int) -> void:
	# COSMOS FS1 (§4): the WELD path — fine near-g grid sampled along the SHARED corner dirs, each coarse vertex
	# placed RADIALLY at the min-envelope height, outer ring snapped to the coarse chord. env(i) ≤ direct g, so an
	# env backstop always sits AT-OR-BELOW a welded horizon neighbour (no see-through); env↔env welds exactly.
	if CubeSphere.FP_SHELL_WELD:
		_ensure_backstop_cached_env_weld(fid)
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var mult := TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Fine near-g grid over the facet (pitch = edge/fine ≈ 3 blocks): one profile_at_dir per fine node.
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var s := float(fi) / float(fine)
			var t := float(fj) / float(fine)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var prof := TerrainConfig.profile_at_dir(bx / ln, by / ln, bz / ln, FacetAtlas.R_BLOCKS)
			fg[fj * fstride + fi] = int(prof.x)
	# Skew dilation, in fine-sample units: the far vertex lands displaced ≤ ENV_DILATE_BLOCKS from its footprint b.
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	var dil := int(ceil(TierPlace.ENV_DILATE_BLOCKS / maxf(fine_pitch, 0.001)))
	var half := mult + dil                       # footprint = ±1 coarse cell (±mult fine) + the skew dilation
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var fic := gi * mult
			var fjc := gj * mult
			var gmin := 1 << 30
			for wj in range(fjc - half, fjc + half + 1):
				if wj < 0 or wj >= fstride:
					continue
				var rowoff := wj * fstride
				for wi in range(fic - half, fic + half + 1):
					if wi < 0 or wi >= fstride:
						continue
					var gg: int = fg[rowoff + wi]
					if gg < gmin:
						gmin = gg
			var relief := maxf(0.0, float(gmin - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE, envelope height, un-sunk
			var vp := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## COSMOS FS1 (§4) — the WELD twin of _ensure_backstop_cached_env: identical min-envelope construction, but every
## direction comes from the SHARED corner dirs and every vertex is placed RADIALLY (d̂·(R+relief)), then the outer
## ring is snapped to the coarse chord. Kept a separate function so the shipped envelope path stays byte-identical.
func _ensure_backstop_cached_env_weld(fid: int) -> void:
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var mult := TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Fine near-g grid over the facet, sampled along the shared corner dirs (one profile_at_dir per fine node).
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var d := _weld_unit(cd, float(fi) / float(fine), float(fj) / float(fine))
			fg[fj * fstride + fi] = int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS).x)
	# Skew dilation (identical derivation to the shipped env builder).
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	var dil := int(ceil(TierPlace.ENV_DILATE_BLOCKS / maxf(fine_pitch, 0.001)))
	var half := mult + dil
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var d := _weld_unit(cd, float(gi) / float(cells), float(gj) / float(cells))
			var fic := gi * mult
			var fjc := gj * mult
			var gmin := 1 << 30
			for wj in range(fjc - half, fjc + half + 1):
				if wj < 0 or wj >= fstride:
					continue
				var rowoff := wj * fstride
				for wi in range(fic - half, fic + half + 1):
					if wi < 0 or wi >= fstride:
						continue
					var gg: int = fg[rowoff + wi]
					if gg < gmin:
						gmin = gg
			pos.append(_weld_place(d, gmin))                     # ABSOLUTE, radial, envelope height, un-sunk
			var vp := TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_weld_snap_edges(pos, cells)
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## COSMOS far-ring full coverage (§2): return a copy of grid positions `p` pushed radially inward by BACKSTOP_SINK
## blocks (p − p̂·BACKSTOP_SINK) so the coarse backstop sits strictly behind the opaque near voxels. Computed once per
## emit so a shared grid vertex is not re-normalized per triangle. Pure math — safe on the async worker thread.
func _sunk_positions(p: PackedVector3Array) -> PackedVector3Array:
	var sink := TierPlace.backstop_sink()   # TIER-DEPTH P2: ε guard under the envelope, else the shipped BACKSTOP_SINK
	var out := PackedVector3Array()
	out.resize(p.size())
	for i in range(p.size()):
		var v: Vector3 = p[i]
		out[i] = v - v.normalized() * sink
	return out

## COSMOS far-ring full coverage (§4): expand backstop facet `fid`'s dense sunk grid into the tri soup (same two tris
## per cell, same winding, same per-vertex colours as _emit_cached) and append it to the fast path's packed arrays. Used
## only by _build_fast under FULL_COVER for the handful of backstop facets that cannot ride the pre-triangulated memcpy.
func _append_backstop_tris(pos: PackedVector3Array, col: PackedColorArray, fid: int) -> void:
	_ensure_backstop_cached(fid)
	var gp := _sunk_positions(_bpos_cache[fid])
	var gc: PackedColorArray = _bcol_cache[fid]
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			pos.push_back(gp[i0]); pos.push_back(gp[i2]); pos.push_back(gp[i1])
			pos.push_back(gp[i1]); pos.push_back(gp[i2]); pos.push_back(gp[i3])
			col.push_back(gc[i0]); col.push_back(gc[i2]); col.push_back(gc[i1])
			col.push_back(gc[i1]); col.push_back(gc[i2]); col.push_back(gc[i3])

## COSMOS far-ring full coverage (§2/§4): emit facet `fid`'s tri soup into `st`. A backstop facet (under FULL_COVER)
## emits its DENSE cache with the BACKSTOP_SINK radial push applied per vertex (pre-computed once here via _sunk_positions
## so a shared grid vertex is not re-normalized per triangle); every other facet emits the shipped CELLS grid verbatim.
## Pure CPU + const reads only — safe on the async worker thread (no scene-tree / RenderingServer access). `sunk` is
## decided by the CALLER (live `_is_backstop` on the main-thread sync path; the frozen `_async_backstop` snapshot on the
## worker) so this function never reads the mutable `_excluded` off-thread.
func _emit_cached(st: SurfaceTool, fid: int, sunk: bool) -> int:
	var pos: PackedVector3Array
	var col: PackedColorArray
	var cells := CELLS
	if sunk:
		pos = _sunk_positions(_bpos_cache[fid])
		col = _bcol_cache[fid]
		cells = CubeSphere.BACKSTOP_CELLS
	else:
		pos = _pos_cache[fid]
		col = _col_cache[fid]
	var stride := cells + 1
	var n := 0
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			st.set_color(col[i0]); st.add_vertex(pos[i0])
			st.set_color(col[i2]); st.add_vertex(pos[i2])
			st.set_color(col[i1]); st.add_vertex(pos[i1])
			st.set_color(col[i1]); st.add_vertex(pos[i1])
			st.set_color(col[i2]); st.add_vertex(pos[i2])
			st.set_color(col[i3]); st.add_vertex(pos[i3])
			n += 2
	return n

## COSMOS-PERF L1: derive facet `fid`'s pre-triangulated pos/col soup from its grid caches, ONCE (cached forever). Expands
## the (CELLS+1)² vertex grid into the SAME 32-tri soup _emit_cached emits (same two tris per cell, same winding, same
## per-vertex colors) so a fast rebuild is a straight append_array of these arrays. Normals are computed later, globally,
## by _build_fast's create_from + generate_normals (they depend on the whole visible set via cross-facet seam smoothing).
func _ensure_tri_cached(fid: int) -> void:
	if _tri_pos_cache.has(fid):
		return
	_ensure_cached(fid)
	var pos: PackedVector3Array = _pos_cache[fid]
	var col: PackedColorArray = _col_cache[fid]
	var stride := CELLS + 1
	var tp := PackedVector3Array()
	var tc := PackedColorArray()
	for gj in range(CELLS):
		for gi in range(CELLS):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			tp.push_back(pos[i0]); tp.push_back(pos[i2]); tp.push_back(pos[i1])
			tp.push_back(pos[i1]); tp.push_back(pos[i2]); tp.push_back(pos[i3])
			tc.push_back(col[i0]); tc.push_back(col[i2]); tc.push_back(col[i1])
			tc.push_back(col[i1]); tc.push_back(col[i2]); tc.push_back(col[i3])
	_tri_pos_cache[fid] = tp
	_tri_col_cache[fid] = tc

func _centre_dir(fid: int) -> Array:
	if _centre_cache.has(fid):
		return _centre_cache[fid]
	var cd := _facet_centre_dir(fid)
	_centre_cache[fid] = cd
	return cd

func _facet_centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

## COSMOS FS1 (§4.1): the unit sphere direction at grid node (s,t) from the SHARED cube-sphere corner dirs `cd`
## (12 f64). The bilerp + normalize stay f64; only the final Vector3 is f32 — so two facets sharing a grid edge
## (identical corner dirs, identical s,t) cast to the SAME f32 direction ⇒ their shared-edge vertices weld.
func _weld_unit(cd: PackedFloat64Array, s: float, t: float) -> Vector3:
	var ux := _bilerp(cd[0], cd[3], cd[6], cd[9], s, t)
	var uy := _bilerp(cd[1], cd[4], cd[7], cd[10], s, t)
	var uz := _bilerp(cd[2], cd[5], cd[8], cd[11], s, t)
	var ln := sqrt(ux * ux + uy * uy + uz * uz)
	return Vector3(ux / ln, uy / ln, uz / ln)

## COSMOS FS1 (§4.1 / One-Surface Law): the ABSOLUTE radial world point of unit direction `d` at surface height
## `g` — d·(R + relief). The SAME altitude law the datum-shifted near field (FS2) and skin use, so near↔far agree.
func _weld_place(d: Vector3, g: int) -> Vector3:
	var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
	return d * (FacetAtlas.R_BLOCKS + relief)

## COSMOS FS1 (§4.1): emit grid node (s,t)'s welded radial position + far-palette colour into pos/col.
func _weld_node(cd: PackedFloat64Array, s: float, t: float, pos: PackedVector3Array, col: PackedColorArray) -> void:
	var d := _weld_unit(cd, s, t)
	var prof := TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
	var g := int(prof.x)
	pos.append(_weld_place(d, g))
	col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))

## COSMOS FS1 (§4.2): the COARSE-OWNS-EDGE T-junction rule. A dense facet (cells > CELLS) snaps each outer-ring
## INTERIOR vertex onto the CELLS=4 coarse chord (a straight-line interp of the ring's own coarse-index vertices),
## so its shared edge is colinear with — and welds crack-free to — a horizon 4-edge (and to another dense facet
## that snapped the same way). No-op for a horizon facet (cells == CELLS ⇒ cstride 1). Corners are left exact.
func _weld_snap_edges(pos: PackedVector3Array, cells: int) -> void:
	var cstride := cells / CELLS
	if cstride <= 1:
		return
	var stride := cells + 1
	for i in range(1, cells):
		var c0 := (i / cstride) * cstride                # lower coarse index on the edge
		var c1 := mini(c0 + cstride, cells)              # upper coarse index
		var lo := float(i - c0) / float(cstride)
		pos[i * stride + 0] = pos[c0 * stride + 0].lerp(pos[c1 * stride + 0], lo)            # West (gi=0)
		pos[i * stride + cells] = pos[c0 * stride + cells].lerp(pos[c1 * stride + cells], lo)  # East (gi=cells)
		pos[0 * stride + i] = pos[0 * stride + c0].lerp(pos[0 * stride + c1], lo)             # South (gj=0)
		pos[cells * stride + i] = pos[cells * stride + c0].lerp(pos[cells * stride + c1], lo)  # North (gj=cells)

# COSMOS-LOD-SKY L3 (SHELL_TERMINATOR_TINT, §6b): the space-side terminator band. A lit vertex-colour spatial
# shader (same render class as the StandardMaterial3D / the P3 bias shader) plus a `sun_dir` uniform: per VERTEX
# μ = normalize(world_pos)·sun_dir and ALBEDO *= mix(1, scatter_tint(μ), band(μ)). The scatter_tint/band GLSL MIRRORS
# CosmosSky.scatter_tint/scatter_band EXACTLY (the gate pins the GDScript twin; this shader render is live-only). The
# ONE VISUAL-RISK stage (P3 shader-failure class on gl_compat) — default-off, screenshot-gated; the StandardMaterial
# fallback below is retained permanently. planet centre = scene origin (fixed frame) so normalize(world) is the surface dir.
const _SHELL_TINT_SHADER := "shader_type spatial;
render_mode cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
varying vec3 v_col;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float mu = dot(normalize(wp), normalize(sun_dir));
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col = COLOR.rgb * tint;
}
void fragment() { ALBEDO = v_col; ROUGHNESS = 1.0; }
"

# COSMOS ATMO-SKY A5 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C2): the absolute self-shaded globe shell v2. UNSHADED
# (immune to the global light/ambient, so the globe's look stops tracking the camera) + per-vertex darkening
# NIGHT_FLOOR + (1−NIGHT_FLOOR)·day(n̂), n̂ = normalize(wp − centre) with centre = (MODEL_MATRIX·0) so it is EXACT
# under scale-about-camera (a uniform scale about the camera cancels in the normalize), × the kept terminator
# band tint. Mirrors CosmosSky.day_factor / scatter_tint / scatter_band EXACTLY (gate G-AS-TERM pins the twins).
# Supersedes _SHELL_TINT_SHADER v1; the StandardMaterial fallback below stays permanent (P3 gl_compat class).
const _SHELL_ABS_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.06;
uniform float term_mu = 0.12;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
varying vec3 v_col;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	float mu = dot(n, normalize(sun_dir));
	float shade = night_floor + (1.0 - night_floor) * _day(mu);
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col = COLOR.rgb * shade * tint;
}
void fragment() { ALBEDO = v_col; }
"

func _make_material() -> Material:
	# COSMOS ATMO-SKY A5: the absolute self-shaded globe shell v2 wins (supersedes the L3 terminator tint v1) —
	# sun_dir fed each frame via set_shell_absolute_sun_dir; the centre comes from MODEL_MATRIX (exact under scale).
	# Off → the shipped paths below verbatim (byte-identical; the shell is untouched).
	if CubeSphere.FP_SHELL_ABSOLUTE:
		var sh2 := Shader.new()
		sh2.code = _SHELL_ABS_SHADER
		var sm2 := ShaderMaterial.new()
		sm2.shader = sh2
		sm2.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		sm2.set_shader_parameter("night_floor", CosmosSky.SHELL_NIGHT_FLOOR)
		sm2.set_shader_parameter("term_mu", CosmosSky.TERMINATOR_MU)
		return sm2
	# COSMOS-LOD-SKY L3: the terminator-tint shell shader wins when its flag is on (it subsumes the plain lit
	# vertex-colour look; sun_dir is fed each frame via set_terminator_sun_dir). Off → the shipped paths verbatim.
	if CubeSphere.SHELL_TERMINATOR_TINT:
		var sh := Shader.new()
		sh.code = _SHELL_TINT_SHADER
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		return sm
	# TIER-DEPTH P3 (§5.2): the far ring is the coarsest overlapping tier → an 8-quantum window-space depth bias so it
	# loses every coincident-depth tie to the skin and near blocks at ANY distance. The biased material is a LIT
	# vertex-colour spatial shader equivalent to the StandardMaterial3D below (fog/tonemap applied by the environment).
	# Flag off → the shipped StandardMaterial3D verbatim (byte-identical).
	if TierPlace.depth_bias_on():
		return TierPlace.make_biased_material(TierPlace.far_bias())
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # far ring: winding-agnostic (transforms may flip facets)
	m.roughness = 1.0
	return m

## COSMOS-LOD-SKY L3: feed the current Sun direction into the shell tint shader's `sun_dir` uniform (main.gd forwards
## it from CosmosSky each frame). No-op unless SHELL_TERMINATOR_TINT is on and the material is the tint shader — so
## flag-off is byte-identical (the setter is never wired) and it can never touch the StandardMaterial/bias paths.
func set_terminator_sun_dir(sun_dir: Vector3) -> void:
	if not CubeSphere.SHELL_TERMINATOR_TINT or _mi == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("sun_dir", sun_dir)

## COSMOS ATMO-SKY A5 (FP_SHELL_ABSOLUTE): feed the current Sun direction into the shell v2 shader's `sun_dir`
## uniform each frame (main.gd forwards it from CosmosSky). The planet centre needs no uniform — the v2 shader
## reads it from MODEL_MATRIX so it is exact under the scaled placement. No-op unless the flag is on and the
## material is the v2 shader ⇒ flag-off is byte-identical (never wired; the StandardMaterial path is untouched).
func set_shell_absolute_sun_dir(sun_dir: Vector3) -> void:
	if not CubeSphere.FP_SHELL_ABSOLUTE or _mi == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("sun_dir", sun_dir)

## Triangle count of the built ring mesh (gate).
func triangle_count() -> int:
	if _mi == null or _mi.mesh == null:
		return 0
	var mesh: ArrayMesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return 0
	var arr := mesh.surface_get_arrays(0)
	var vv: Variant = arr[Mesh.ARRAY_VERTEX]
	return (vv as PackedVector3Array).size() / 3
