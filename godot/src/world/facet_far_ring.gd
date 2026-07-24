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
const ENV_WARM_BATCH := 12           # FP_ENV_WARM_ASYNC: max uncached env facets ONE worker dispatch builds before it
                                     # emits the ready subset. Off-thread ⇒ never touches the frame budget; bounded ⇒
                                     # NEVER-OOM. The orbit reveal grows ~ENV_WARM_BATCH facets per worker cycle.

# FP_ENV_WARM_ASYNC instrumentation (telemetry-only, env_all path). Counts _env_weld_grid builds by the thread they
# ran on, so the perf fix is provable: OFF ⇒ all builds on MAIN; ON ⇒ builds on the WORKER, main count frozen.
static var env_build_main := 0
static var env_build_worker := 0

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
# COSMOS LOD-TEXTURE Phase 1 (§1.3): parallel tri-order UV/UV2 caches for the FAST assembler, built ONLY under
# FP_FACET_TEX (zero bytes / never touched with the flag off). UV = ((a+s)/K,(b+t)/K) is the facet-grid param;
# UV2 = (face, -1) selects the base-map layer (close-up slot is always -1 in Phase 1). Same push order as
# _tri_pos_cache so _build_fast's append_array carries them index-aligned into the mesh.
var _tri_uv_cache: Dictionary = {}   # fid -> PackedVector2Array (96 uvs, per _emit_cached order)
var _tri_uv2_cache: Dictionary = {}  # fid -> PackedVector2Array (96 uv2s: (face,-1))
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
# FP_ENV_WARM_ASYNC: the FROZEN "this worker warms its own uncached env caches" decision for the in-flight build.
# Snapshotted on the main thread at dispatch (orbit + env_all + async only) so the worker's warm/emit is stable for
# its lifetime; false ⇒ the shipped read-only worker (caches pre-warmed on main). Never changes mid-run.
var _async_env_warm := false
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
var _orbit_emitted_once := false            # FP_ENV_WARM_ASYNC: a worker-warm orbit dispatch has fired at least once this engage (fill the mesh even at 0 growth)
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

# COSMOS-PERF FALL-ALTRATE (FP_FALL_RING_HOLD): throttle state for the per-frame scaled-placement transform write.
# The 55k-triangle ring's scaled world transform changes its AABB → a culling-BVH re-insert every frame; hold it
# during a fast descent and re-apply ≤ 1/FALL_THROTTLE_MS. −1 sentinels ⇒ the first call always applies. DEAD off the flag.
var _ringhold_prev_d := -1.0
var _ringhold_prev_usec := -1
var _ringhold_apply_msec := -1

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
	var d := cam.distance_to(base.origin)
	var s := CosmosScale.scale_for(d, FacetAtlas.R_BLOCKS)
	_dbg_scale = s                                  # H-B telemetry: the SN3 clamp scale actually applied to the ring this frame
	# COSMOS-PERF FALL-ALTRATE (FP_FALL_RING_HOLD): off ⇒ the shipped every-frame transform write (byte-identical).
	if CubeSphere.FP_FALL_RING_HOLD:
		var now_usec := Time.get_ticks_usec()
		var vspeed := 0.0
		if _ringhold_prev_usec >= 0:
			vspeed = FallThrottle.radial_speed(_ringhold_prev_d, d, float(now_usec - _ringhold_prev_usec) / 1.0e6)
		_ringhold_prev_d = d
		_ringhold_prev_usec = now_usec
		var now_msec := Time.get_ticks_msec()
		var ms_since := (now_msec - _ringhold_apply_msec) if _ringhold_apply_msec >= 0 else 0x7fffffff
		if not FallThrottle.should_reapply(true, vspeed, ms_since):
			return                                  # hold the last scaled placement (no AABB/BVH churn this frame)
		_ringhold_apply_msec = now_msec
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
	# FP_ENV_WARM_ASYNC: the one-shot whole-planet warm fills the SAME _pos_cache the worker now builds off-thread. On
	# the main thread each env facet is ~16 ms, so this prewarm is exactly the second half of the orbit main-thread
	# stall — let the worker fill caches on demand (bounded batch/cycle) instead. No-op on the surface (offsurface false).
	if _env_warm_async_on():
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
		# FP_ENV_WARM_ASYNC: relocate the heavy env-cache build off the main thread. Instead of warming ~1 x 16 ms env
		# facet per frame on the main thread (the 51 ms orbit stall), dispatch a worker that warms a bounded batch and
		# emits the ready subset; the main thread only pays the cheap swap. Byte-identical heights (same builder) ⇒ the
		# no-protrusion gate is unmoved. Scoped to env_all + orbit + async; off ⇒ the shipped S1b path below runs verbatim.
		if _env_warm_async_on():
			_orbit_warm_async(p)
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

## FP_ENV_WARM_ASYNC: is the env-cache build relocated to the far-ring worker? Requires the flag, the env_all regime
## (the only path whose ~16 ms/facet EDGE-CANON build blows the warm budget), the ORBIT regime (where the whole planet
## is drawn coarse ⇒ the main-thread warm burst), and a real worker to build on. Off in any of those ⇒ the shipped
## main-thread warm runs verbatim (byte-identical). Read on the main thread; snapshotted into `_async_env_warm` at dispatch.
func _env_warm_async_on() -> bool:
	return CubeSphere.FP_ENV_WARM_ASYNC and TierPlace.env_all_on() and _shell_orbit() and _async_enabled()

## FP_ENV_WARM_ASYNC: the ORBIT driver when the env build lives on the worker. No main-thread warm at all — a cheap
## dot-scan counts uncached visible facets, then (when the worker is idle: _process guards this behind `not _async_building`)
## a worker dispatch warms a bounded batch + emits the ready subset. Re-dispatched each idle frame until the front is
## fully cached (`remaining == 0`), then idles like the shipped `_orbit_converged` short-circuit. The reveal grows
## ENV_WARM_BATCH facets per worker cycle — same total work as the shipped warm, but entirely off the frame budget.
func _orbit_warm_async(p: Array) -> void:
	_emit_cached_only = true
	var remaining := _count_uncached_visible(p)
	# Dispatch when: a fresh drift/engage (`_pending`), any facet still to warm (progressive reveal), or the mesh has
	# never been emitted this engage (fill it even at 0 growth). Each dispatch's worker warms the next batch off-thread.
	if _pending or remaining > 0 or not _orbit_emitted_once:
		_begin_rebuild()
		_orbit_emitted_once = true
	# Converged once every visible facet is cached AND the pending emit was consumed — the next drift re-sets `_pending`.
	_orbit_converged = remaining == 0 and not _pending

## FP_ENV_WARM_ASYNC: how many front-hemisphere facets still lack their emit cache. Cheap (front-cull dot + a dict
## `has()` per fid — NO profile sampling), so it is safe to run every idle frame. Mirrors visible_fids' cull + role.
func _count_uncached_visible(p: Array) -> int:
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var k := FacetAtlas.K
	var cnt := 0
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm, thresh):
					continue
				if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
					if not _bpos_cache.has(fid):
						cnt += 1
				elif not _pos_cache.has(fid):
					cnt += 1
	return cnt

## FP_ENV_WARM_ASYNC: is facet `fid`'s emit cache present, given its FROZEN backstop role? (worker-thread reader —
## uses the snapshot dict, never live `_is_backstop`, so it never races set_pool_excluded).
func _worker_cache_ready(fid: int) -> bool:
	if _async_backstop.has(fid):
		return _bpos_cache.has(fid)
	return _pos_cache.has(fid)

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
	# FP_ENV_WARM_ASYNC: when the worker builds its OWN env caches, hand it the FULL front set (uncached included) so it
	# can warm a bounded batch and emit them the same cycle. Frozen here so the worker's warm/emit is stable for its run
	# (main will not touch the caches while _async_building). Off ⇒ the shipped cache-filtered set (byte-identical).
	_async_env_warm = _env_warm_async_on()
	# S1b: in the true-orbit progressive path _emit_cached_only filters to cache-ready facets, so the worker (which reads
	# _pos_cache/_bpos_cache) never touches an uncached facet; every other path passes false ⇒ the shipped full front set.
	_async_fids = visible_fids(false) if _async_env_warm else visible_fids(_emit_cached_only)
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
	var warmed := 0
	for fid in _async_fids:
		# backstop role read from the FROZEN snapshot (never `_excluded` live) — the const read is thread-safe.
		var backstop := CubeSphere.FP_FARRING_FULL_COVER and _async_backstop.has(fid)
		# FP_ENV_WARM_ASYNC: build this facet's env cache HERE (off-thread) if it is missing, up to ENV_WARM_BATCH per
		# dispatch. `_async_env_warm` is the frozen main-thread decision (env_all + orbit + async), and while this worker
		# runs the main thread touches none of these caches (the `_async_building` gate in _process), so this single
		# writer + no concurrent reader is safe. A facet still uncached after the batch is skipped now, revealed a later
		# dispatch. Off ⇒ `_async_env_warm` false ⇒ this whole block is inert and the loop is the shipped read-only emit.
		if _async_env_warm and not _worker_cache_ready(fid):
			if warmed >= ENV_WARM_BATCH:
				continue
			if backstop:
				_ensure_backstop_cached(fid)
			else:
				_ensure_cached(fid)
			warmed += 1
		_emit_cached(st, fid, backstop)
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
		# FP_ENV_WARM_ASYNC: `fids` is the FULL front but the worker emitted only the facets whose cache was ready this
		# cycle (batch-bounded warm). Record ONLY those actually drawn so `_emitted` never claims an un-drawn facet. Off ⇒
		# every fid was cache-filtered before dispatch, so this guard is a no-op (byte-identical committed set).
		if _async_env_warm and not _worker_cache_ready(fid):
			continue
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
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): the tri-order UV/UV2 arrays, grown alongside pos/col ONLY under
	# FP_FACET_TEX (off ⇒ empty + never assigned to the surface → byte-identical mesh format).
	var tex := _tex_on()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	for fid in fids:
		# COSMOS far-ring full coverage (§4): a sunk backstop facet cannot ride the pre-triangulated memcpy (its
		# vertices are pushed radially inward per-vertex at BACKSTOP_CELLS). Under FULL_COVER it falls back to the
		# per-vertex sunk expansion (a handful of facets — §5); non-backstop facets keep the memcpy fast path. The
		# vertex order/winding matches _emit_cached exactly, so the later global generate_normals is bit-identical.
		if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
			_append_backstop_tris(pos, col, fid, uv, uv2)
		else:
			_ensure_tri_cached(fid)
			pos.append_array(_tri_pos_cache[fid])
			col.append_array(_tri_col_cache[fid])
			if tex:
				uv.append_array(_tri_uv_cache[fid])
				uv2.append_array(_tri_uv2_cache[fid])
	if pos.size() == 0:
		return ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_COLOR] = col
	if tex:
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
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

## NO-PROTRUSION G-NPT gate: the AS-RENDERED coarse-horizon vertex grid for facet `fid`. Under FP_ENV_ALL the coarse
## `_pos_cache` carries min-envelope heights AND the emit path sinks it by the ε guard (the coarse twin of the
## backstop sink), so this returns the same ε-sunk surface the live emit draws; with the flag off it returns the
## shipped raw exact-chord `_pos_cache` (what the un-enveloped horizon really renders — where R-A/R-B protrude).
func horizon_rendered_positions(fid: int) -> PackedVector3Array:
	_ensure_cached(fid)
	if TierPlace.env_all_on():
		return _sunk_positions(_pos_cache[fid])
	return _pos_cache[fid]

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
	# NO-PROTRUSION §0.3 (FP_ENV_ALL): the coarse HORIZON cache (R-A / R-B) becomes a min-envelope LOWER BOUND too —
	# every CELLS=4 vertex placed radially at env(v) = min near g over its dilated footprint, with EDGE-CANON on the
	# shared boundary so it still welds. Requires FP_SHELL_WELD (checked in env_all_on) — the enveloped surface is a
	# pure radial field. Textually separate so the flag-off path below is byte-identical.
	if TierPlace.env_all_on():
		var g := _env_weld_grid(fid, CELLS)
		_pos_cache[fid] = g[0]
		_col_cache[fid] = g[1]
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
	if TierPlace.envelope_on() or TierPlace.env_all_on():
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
	# NO-PROTRUSION §0.3 (FP_ENV_ALL): the dense backstop shares the SAME EDGE-CANON boundary rule as the coarse
	# horizon cache so the two tiers weld to each other (coarse-index boundary/corner values coincide). The shipped
	# FP_TIER_ENVELOPE-only path (plain 2-D footprint below) is left byte-identical — this branch only runs under env_all.
	if TierPlace.env_all_on():
		var g := _env_weld_grid(fid, CubeSphere.BACKSTOP_CELLS)
		_bpos_cache[fid] = g[0]
		_bcol_cache[fid] = g[1]
		return
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

# =====================================================================================================
# NO-PROTRUSION §0.3 (FP_ENV_ALL) — the GLOBAL ENVELOPE HEIGHT LAW builder, shared by the coarse horizon cache
# (cells=CELLS) and the dense backstop cache (cells=BACKSTOP_CELLS). Every vertex is placed RADIALLY from the
# shared corner dirs at a min-envelope height env(v) = min{ near g over v's dilated footprint }, so a rendered
# triangle (a convex combination of three vertex lower bounds) stays ≤ the true surface. Boundary vertices use
# the EDGE-CANON rule — their footprint is derived ONLY from the SHARED edge data at a resolution-INDEPENDENT
# canonical pitch/reach — so a coarse facet and an adjacent dense facet compute the SAME value at a shared
# corner/coarse-index edge node ⇒ the shell still welds (FP_SHELL_WELD preserved). Interior vertices use the
# cheap pre-sampled 2-D fine grid. The ε sink is applied at EMIT (not baked) so the raw caches keep welding
# (horizon_positions / backstop_raw_positions coincide). Returns [pos, col]; the caller stores into the right cache.
# =====================================================================================================
func _env_weld_grid(fid: int, cells: int) -> Array:
	# FP_ENV_WARM_ASYNC telemetry: attribute this (heavy) build to its thread, so the relocation is provable — OFF the
	# builds land on MAIN; ON they land on the far-ring worker while env_build_main stays frozen. Cheap thread-id compare.
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		env_build_main += 1
	else:
		env_build_worker += 1
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var stride := cells + 1
	var cstride := cells / CELLS                       # 1 for the coarse facet, BACKSTOP_CELLS/CELLS for the dense one
	var mult := TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Pre-sample the fine near-g grid along the SHARED corner dirs (interior 2-D footprint source; one profile per node).
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var d := _weld_unit(cd, float(fi) / float(fine), float(fj) / float(fine))
			fg[fj * fstride + fi] = int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS).x)
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	# The RADIAL-vs-NORMAL skew: a far vertex placed radially at height h projects along the near n̂ onto a column
	# displaced by ≈ h·tan(α), α ≤ the facet half-diagonal — up to ~relief·0.046 ≈ 6-8 blocks on a high mountain, and
	# MORE than the shipped ENV_DILATE_BLOCKS(6) covers (measured raw residual +6.2 at dilation 6 ⇒ the min missed
	# the truly-overlaid column). env_all dilates the footprint by a generous rescale-safe skew allowance (~0.3 of a
	# coarse cell ≈ 31 blocks at R=6371, covering relief up to ~650) so the min ALWAYS includes the projected column
	# ⇒ raw residual < ε. Env_all-LOCAL (does not touch the shipped ENV_DILATE_BLOCKS ⇒ FP_TIER_ENVELOPE unmoved).
	var skew := edge_blocks / float(CELLS) * 0.3
	var dil := int(ceil(skew / maxf(fine_pitch, 0.001)))
	var half := mult + dil                             # interior footprint = ±1 own-cell (±mult fine) + skew dilation
	# CANONICAL (resolution-independent) edge/corner extents: reach = 1 coarse (CELLS) cell + the skew allowance
	# (covers a boundary node's incident triangles on BOTH facets + the projected column); pitch derived from the
	# FINEST reference (BACKSTOP_CELLS) so a coarse and a dense facet sample the same set at a shared node — all fixed
	# constants, identical every facet ⇒ shared boundary/corner values coincide (weld preserved).
	var reach := edge_blocks / float(CELLS) + skew
	# Canonical boundary pitch ≈ half a BACKSTOP cell (~13 blocks): fine enough that the between-sample residual
	# (≈ step²·|h''|/8 ≲ 1 block on the worst mountain facet) stays well under the ε sink (G-NPT-BOUND pins it),
	# yet coarse enough that the disc/band sample counts stay bounded. Fixed constant ⇒ coarse and dense agree.
	var step := edge_blocks / float(2 * CubeSphere.BACKSTOP_CELLS)
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var d := _weld_unit(cd, float(gi) / float(cells), float(gj) / float(cells))
			var gmin := _env_node_min(cd, cells, cstride, gi, gj, fg, fstride, mult, half, reach, step)
			pos.append(_weld_place(d, gmin))            # ABSOLUTE, radial, envelope height, un-sunk (ε applied at emit)
			var vp := TerrainConfig.profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_weld_snap_edges(pos, cells)                        # dense: snap fine edge verts onto the EDGE-CANON coarse chord (no-op at CELLS)
	return [pos, col]

## The min near-g over grid node (gi,gj)'s envelope footprint. INTERIOR node → the cheap pre-sampled 2-D fine grid
## (±half). BOUNDARY node → EDGE-CANON (shared-derived, so both facets agree): a CORNER samples a rotationally-
## symmetric disc about the shared corner dir; a COARSE-INDEX edge node samples the shared 1-D edge line + a
## sign-symmetric perpendicular band. A non-coarse-index (fine) edge node falls back to the 2-D footprint because
## `_weld_snap_edges` overwrites it with the coarse chord anyway (so its value never renders).
func _env_node_min(cd: PackedFloat64Array, cells: int, cstride: int, gi: int, gj: int,
		fg: PackedInt32Array, fstride: int, mult: int, half: int, reach: float, step: float) -> int:
	var on_w := gi == 0
	var on_e := gi == cells
	var on_s := gj == 0
	var on_n := gj == cells
	var nb := int(on_w) + int(on_e) + int(on_s) + int(on_n)
	if nb >= 2:                                         # CORNER — canonical disc about the shared corner dir
		var dc := _weld_unit(cd, float(gi) / float(cells), float(gj) / float(cells))
		return _env_corner_min(dc, reach, step)
	if nb == 1:
		var along_idx := gj if (on_w or on_e) else gi
		if along_idx % cstride == 0:                    # coarse-index edge node — canonical line + perp band
			var ca: Vector3
			var cb: Vector3
			var u: float
			if on_s:
				ca = Vector3(cd[0], cd[1], cd[2]); cb = Vector3(cd[3], cd[4], cd[5]); u = float(gi) / float(cells)
			elif on_n:
				ca = Vector3(cd[9], cd[10], cd[11]); cb = Vector3(cd[6], cd[7], cd[8]); u = float(gi) / float(cells)
			elif on_w:
				ca = Vector3(cd[0], cd[1], cd[2]); cb = Vector3(cd[9], cd[10], cd[11]); u = float(gj) / float(cells)
			else:
				ca = Vector3(cd[3], cd[4], cd[5]); cb = Vector3(cd[6], cd[7], cd[8]); u = float(gj) / float(cells)
			return _env_edge_min(ca, cb, u, reach, step)
	# INTERIOR (or a fine edge node that will be snapped): 2-D footprint over the pre-sampled fine grid.
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
	return gmin

## EDGE-CANON corner: min near g over a rotationally-symmetric DISC of angular radius reach/R about the shared
## corner dir `d`. The tangent frame is a DETERMINISTIC function of d ONLY (pick the world axis least aligned with
## d, orthonormalize) — so every facet meeting at this corner (any arity) builds the identical sample set ⇒ the
## corner welds. Rings at the canonical pitch, angular samples densified with radius so no dip is missed.
func _env_corner_min(d: Vector3, reach: float, step: float) -> int:
	var ref := Vector3(0.0, 1.0, 0.0)
	if absf(d.y) >= absf(d.x) and absf(d.y) >= absf(d.z):
		ref = Vector3(1.0, 0.0, 0.0)                    # d ~ ±Y → use X as the reference so the cross is well-conditioned
	var u := (ref - d * ref.dot(d)).normalized()
	var v := d.cross(u).normalized()
	var r := FacetAtlas.R_BLOCKS
	var nr := int(ceil(reach / step))
	var gmin := int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, r).x)   # the corner itself (rad 0)
	for ri in range(1, nr + 1):
		var rad := float(ri) * step
		var na := maxi(6, int(ceil((2.0 * PI * rad) / step)))
		var ainc := (2.0 * PI) / float(na)
		var scale := rad / r                            # angular offset ≈ tan θ for the small facet-scale θ
		for ai in range(na):
			var ang := float(ai) * ainc
			var off := u * (cos(ang) * scale) + v * (sin(ang) * scale)
			var sd := (d + off).normalized()
			var g := int(TerrainConfig.profile_at_dir(sd.x, sd.y, sd.z, r).x)
			if g < gmin:
				gmin = g
	return gmin

## EDGE-CANON edge: min near g over the shared 1-D edge line (param a' ∈ [u±reach] along the corner-dir lerp) × a
## SIGN-SYMMETRIC perpendicular band (±p, p = normalize(edge_dir × radial)). The two facets sharing the edge pass
## the same corner dirs (possibly swapped) and the mirrored parameter (u'=1−u); commutative-add lerp + the ±p / ±off
## symmetry make the sample SET bit-identical either side ⇒ the coarse-index edge nodes weld. Clamped to the edge
## extent [0,1] so a near-corner footprint samples the corner dir (matches the neighbour's clamp — still symmetric).
func _env_edge_min(ca: Vector3, cb: Vector3, u: float, reach: float, step: float) -> int:
	var edge_dir := cb - ca
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var du := step / edge_blocks
	var r := FacetAtlas.R_BLOCKS
	var np := int(ceil(reach / step))
	var gmin := 1 << 30
	for ia in range(-np, np + 1):
		var ap := clampf(u + float(ia) * du, 0.0, 1.0)
		var d_e := (ca * (1.0 - ap) + cb * ap).normalized()          # = _weld_unit on the edge (bit-identical either side)
		var p := edge_dir.cross(d_e).normalized()                    # in-surface perpendicular (±symmetric across facets)
		for ip in range(-np, np + 1):
			var off := (float(ip) * step) / r
			var sd := (d_e + p * off).normalized()
			var g := int(TerrainConfig.profile_at_dir(sd.x, sd.y, sd.z, r).x)
			if g < gmin:
				gmin = g
	return gmin

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
func _append_backstop_tris(pos: PackedVector3Array, col: PackedColorArray, fid: int,
		uv: PackedVector2Array = PackedVector2Array(), uv2: PackedVector2Array = PackedVector2Array()) -> void:
	_ensure_backstop_cached(fid)
	var gp := _sunk_positions(_bpos_cache[fid])
	var gc: PackedColorArray = _bcol_cache[fid]
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): the dense backstop grid carries the SAME facet-param UVs (denser cells,
	# same [0,1]² span). Only under FP_FACET_TEX (the caller passes real uv/uv2 arrays); off ⇒ they stay empty.
	var tex := _tex_on()
	var t_a := 0; var t_b := 0; var t_k := 1
	var fuv2 := Vector2.ZERO; var inv_k := 0.0; var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		fuv2 = Vector2(float(d[0]), -1.0)
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k); inv_c = 1.0 / float(cells)
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
			if tex:
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				uv.push_back(Vector2(u0, v0)); uv.push_back(Vector2(u0, v1)); uv.push_back(Vector2(u1, v0))
				uv.push_back(Vector2(u1, v0)); uv.push_back(Vector2(u0, v1)); uv.push_back(Vector2(u1, v1))
				for _i in range(6):
					uv2.push_back(fuv2)

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
		# NO-PROTRUSION §0.3: under FP_ENV_ALL the coarse HORIZON cache is an envelope lower bound too — apply the
		# SAME ε sink the backstop gets so the retained emit-time sink covers the between-fine-sample residual (R-A).
		# Off ⇒ the shipped raw _pos_cache emit verbatim (byte-identical).
		pos = _sunk_positions(_pos_cache[fid]) if TierPlace.env_all_on() else _pos_cache[fid]
		col = _col_cache[fid]
	var stride := cells + 1
	var n := 0
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): decode the facet's texture params ONCE. With the flag off `tex` is false
	# and the emit runs the shipped set_color/add_vertex sequence VERBATIM (byte-identical, zero overhead).
	var tex := _tex_on()
	var t_a := 0
	var t_b := 0
	var t_k := 1
	var uv2 := Vector2.ZERO
	var inv_k := 0.0
	var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		uv2 = Vector2(float(d[0]), -1.0)   # (face, close-up slot: always -1 in Phase 1)
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k)
		inv_c = 1.0 / float(cells)
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			if tex:
				# UV = ((a + node_s)/K, (b + node_t)/K); node params: i0=(gi,gj) i1=(gi+1,gj) i2=(gi,gj+1) i3=(gi+1,gj+1)
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				var uv0 := Vector2(u0, v0); var uv1 := Vector2(u1, v0)
				var uv2c := Vector2(u0, v1); var uv3 := Vector2(u1, v1)
				st.set_uv(uv0); st.set_uv2(uv2); st.set_color(col[i0]); st.add_vertex(pos[i0])
				st.set_uv(uv2c); st.set_uv2(uv2); st.set_color(col[i2]); st.add_vertex(pos[i2])
				st.set_uv(uv1); st.set_uv2(uv2); st.set_color(col[i1]); st.add_vertex(pos[i1])
				st.set_uv(uv1); st.set_uv2(uv2); st.set_color(col[i1]); st.add_vertex(pos[i1])
				st.set_uv(uv2c); st.set_uv2(uv2); st.set_color(col[i2]); st.add_vertex(pos[i2])
				st.set_uv(uv3); st.set_uv2(uv2); st.set_color(col[i3]); st.add_vertex(pos[i3])
			else:
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
	# NO-PROTRUSION §0.3: the FAST (memcpy) assembler pre-triangulates the coarse cache; under FP_ENV_ALL bake the
	# same ε sink into that source so a fast rebuild draws the coarse envelope SUNK exactly like the SurfaceTool emit
	# path (_emit_cached). Off ⇒ the shipped raw _pos_cache (byte-identical). The raw _pos_cache itself is untouched
	# (horizon_positions / the weld gate still read the un-sunk envelope).
	var pos: PackedVector3Array = _sunk_positions(_pos_cache[fid]) if TierPlace.env_all_on() else _pos_cache[fid]
	var col: PackedColorArray = _col_cache[fid]
	var stride := CELLS + 1
	var tp := PackedVector3Array()
	var tc := PackedColorArray()
	# COSMOS LOD-TEXTURE Phase 1 (§1.3): build the parallel tri-order UV/UV2 arrays ONLY under FP_FACET_TEX
	# (off ⇒ these stay empty and _build_fast never reads them → byte-identical). Same push order as pos/col.
	var tex := _tex_on()
	var tu := PackedVector2Array()
	var tu2 := PackedVector2Array()
	var t_a := 0; var t_b := 0; var t_k := 1
	var uv2 := Vector2.ZERO; var inv_k := 0.0; var inv_c := 0.0
	if tex:
		var d := _tex_decode(fid)
		uv2 = Vector2(float(d[0]), -1.0)
		t_a = d[1]; t_b = d[2]; t_k = d[3]
		inv_k = 1.0 / float(t_k); inv_c = 1.0 / float(CELLS)
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
			if tex:
				var u0 := (float(t_a) + float(gi) * inv_c) * inv_k
				var u1 := (float(t_a) + float(gi + 1) * inv_c) * inv_k
				var v0 := (float(t_b) + float(gj) * inv_c) * inv_k
				var v1 := (float(t_b) + float(gj + 1) * inv_c) * inv_k
				var uv0 := Vector2(u0, v0); var uv1 := Vector2(u1, v0)
				var uv2c := Vector2(u0, v1); var uv3 := Vector2(u1, v1)
				tu.push_back(uv0); tu.push_back(uv2c); tu.push_back(uv1)
				tu.push_back(uv1); tu.push_back(uv2c); tu.push_back(uv3)
				for _i in range(6):
					tu2.push_back(uv2)
	_tri_pos_cache[fid] = tp
	_tri_col_cache[fid] = tc
	if tex:
		_tri_uv_cache[fid] = tu
		_tri_uv2_cache[fid] = tu2

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

## COSMOS LOD-TEXTURE Phase 1 (§1.3): decode `fid` → [face, a, b, k] in its body's local (face,a,b) indexing
## (Earth ⇒ base 0, k=K). The base-map layer is `face`; UV = ((a+s)/k, (b+t)/k). Mirrors FacetTexBaker._decode
## so the emitted UVs land exactly on the baked facet rect.
## COSMOS LOD-TEXTURE Phase 1 (§1.3 / LOW #3): UV/UV2 emission requires BOTH FP_FACET_TEX and FP_SHELL_ABSOLUTE.
## The textured sampler lives ONLY in the (unshaded) _SHELL_ABS_SHADER; under a LIT StandardMaterial the extra
## per-vertex UV/UV2 would split shared-corner verts in generate_normals (faint cube-edge creases) AND never be
## sampled. Gating on both keeps FP_FACET_TEX-alone byte-identical to shipped (no UV arrays, no creases).
func _tex_on() -> bool:
	return CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE

func _tex_decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]

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

# COSMOS LOD-TEXTURE Phase 1 (§1.3): the TEXTURED variant of _SHELL_ABS_SHADER, compiled ONLY under FP_FACET_TEX.
# Identical day/night shade·tint law (the shipped look), but ALBEDO is a per-fragment cross-fade from the raw
# vertex colour to the baked base-map texture, weighted by camera distance: wt = smoothstep(TEX_D0=600,
# TEX_D1=1800, cam_dist). At d < 600 wt = 0 ⇒ ALBEDO == COLOR.rgb·shade·tint EXACTLY (the shipped shell is
# bit-preserved near); above 1800 the smooth satellite image wins. ONE opaque draw — a fragment albedo blend,
# no transparency, no sorting. base_map is bound each session by set_facet_tex (null until then → black texels,
# irrelevant since wt≈0 near where it would show). Phase 1 has NO close-up branch (closeup_map compiled out).
const _SHELL_ABS_TEX_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.06;
uniform float term_mu = 0.12;
uniform sampler2DArray base_map : source_color, filter_linear_mipmap;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
varying vec3 v_col_raw;
varying vec3 v_st;
varying vec2 v_uv;
varying float v_face;
varying float v_cam;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	float mu = dot(n, normalize(sun_dir));
	float shade = night_floor + (1.0 - night_floor) * _day(mu);
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	v_col_raw = COLOR.rgb;
	v_st = vec3(shade) * tint;
	v_uv = UV;
	v_face = UV2.x;
	v_cam = distance(wp, CAMERA_POSITION_WORLD);
}
void fragment() {
	vec4 tx = texture(base_map, vec3(v_uv, v_face));
	// COVERAGE GATE + UN-PREMULTIPLY (§ live-fix 2): the base map is PREMULTIPLIED alpha, so recover the true
	// (un-darkened) colour by dividing rgb by coverage — near a bake frontier this cancels the mip/bilinear
	// average of an un-baked (rgb=0,a=0) neighbour so there is NO black bleed into the seam. tx.a is the bake
	// coverage: multiply wt by it so an un-baked facet (a≈0) shows the shipped vertex-colour far ring (NEVER
	// black from orbit) and the un-premultiply degenerate case falls back to v_col_raw (doubly safe). A baked
	// facet (a=1) cross-fades to the satellite image on the shipped 600..1800 distance ramp. One opaque draw.
	vec3 col = (tx.a > 0.0001) ? (tx.rgb / tx.a) : v_col_raw;
	float wt = smoothstep(600.0, 1800.0, v_cam) * tx.a;
	ALBEDO = mix(v_col_raw, col, wt) * v_st;
}
"

func _make_material() -> Material:
	# COSMOS ATMO-SKY A5: the absolute self-shaded globe shell v2 wins (supersedes the L3 terminator tint v1) —
	# sun_dir fed each frame via set_shell_absolute_sun_dir; the centre comes from MODEL_MATRIX (exact under scale).
	# Off → the shipped paths below verbatim (byte-identical; the shell is untouched).
	if CubeSphere.FP_SHELL_ABSOLUTE:
		var sh2 := Shader.new()
		# COSMOS LOD-TEXTURE Phase 1 (§1.3): pick the textured variant only when FP_FACET_TEX is on. Flag off ⇒
		# the shipped _SHELL_ABS_SHADER string VERBATIM (byte-identical material). base_map is bound later by
		# set_facet_tex (once the baker has built the array).
		sh2.code = _SHELL_ABS_TEX_SHADER if CubeSphere.FP_FACET_TEX else _SHELL_ABS_SHADER
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

## COSMOS LOD-TEXTURE Phase 1 (§1.3): bind the baker's 6-layer base map into the shell shader's `base_map`
## uniform. No-op unless FP_FACET_TEX is on and the material is the textured shader ⇒ flag-off is byte-identical
## (never wired; the shipped shader has no base_map sampler). Called once by WorldManager after the prewarm bake.
func set_facet_tex(tex: Texture) -> void:
	if not _tex_on() or _mi == null:
		return
	var mat := _mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("base_map", tex)

## COSMOS LOD-TEXTURE Phase 1 gate (G-FT-UV): facet `fid`'s tri-soup UVs (the emitted ARRAY_TEX_UV for that
## facet, in _emit_cached order). Empty unless FP_FACET_TEX is on. Lets the gate assert per-facet UV mapping +
## same-face neighbour continuity without dissecting the merged mesh.
func gate_facet_uvs(fid: int) -> PackedVector2Array:
	_ensure_tri_cached(fid)
	return _tri_uv_cache.get(fid, PackedVector2Array())

## COSMOS LOD-TEXTURE Phase 1 gate (G-FT-UV / G-FT-OFF): the committed ring surface's raw arrays (ARRAY_VERTEX,
## ARRAY_COLOR, ARRAY_TEX_UV, ARRAY_TEX_UV2, …). Empty when nothing is built. Read-only.
func mesh_arrays() -> Array:
	if _mi == null or _mi.mesh == null:
		return []
	var mesh: ArrayMesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return []
	return mesh.surface_get_arrays(0)

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
