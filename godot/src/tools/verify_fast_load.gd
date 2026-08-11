extends SceneTree
## docs/COSMOS-FAST-LOAD-DESIGN.md Phase 1 gate (task #103) — FP_LOAD_DEFER, the fresh-load pile-up fix. Proves the
## ONE settle latch + its broadcast defers the DEFERRABLE far-tier / background work until the near view meshes, and
## that with the flag off every path is the shipped behaviour verbatim.
##
## Self-describes on FP_LOAD_DEFER's COMPILED value (mirrors verify_stream_parallel.gd / verify_orbit_relief.gd):
##
##   G-FL-OFF      — FP_LOAD_DEFER off ⇒ inert: FacetSmoothV2.step(settled=false) does NOT freeze (dispatches/commits
##                   as shipped), and WorldManager._load_defer_tick never settles. (The real byte-off pin is external:
##                   FLAT verify_feature.gd stays 6042/0 with the flag false.)
##   G-FL-GATE     — FP_LOAD_DEFER on: pre-settle FacetSmoothV2.step reaps ONLY (ZERO dispatch, ZERO commit), the first
##                   post-settle commit waits for stream_credit, the WorldManager latch flips ONCE off initial_view_meshed
##                   and broadcasts to the ring (set_load_settled → env load-hold release, read in the `hold` OR-term) and
##                   GlobalReliefData (mark_settled ⇒ DEM bakes nothing pre-settle), and the snow step is skipped until settle.
##   G-FL-FAILSAFE — the latch force-flips at LOAD_DEFER_FAILSAFE_MS even when initial_view_meshed never trips.
##
## Phase 2 (docs/COSMOS-FAST-LOAD-DESIGN.md §2.1.2/§2.1.3 — self-describes on the compiled FP_SMOOTH_V2_PACE /
## FP_SMOOTH_V2_ASYNC_MERGE flags):
##   G-FL-PACE     — FP_SMOOTH_V2_PACE on: the commit is rate-capped — the pure G3 decision (FacetOrbitRelief.
##                   should_commit) honours SMOOTH_V2_COMMIT_MS at the boundary, and a burst of rapid reaps collapses
##                   to ONE commit (not one-per-reap): the falsifier is 36 rapid step()s ⇒ commit_count == 1, not 36.
##   G-FL-MERGE-EQ — FP_SMOOTH_V2_ASYNC_MERGE on (CRITICAL): the off-thread `merge_tiles` produces BYTE-IDENTICAL
##                   pos/nrm/col/idx to the synchronous `merge_tiles` for the same tile set — run hard across many
##                   tile sets / insertion orders + a mutate-during-merge COW stress; plus the instance async path
##                   dispatches+reaps ONE commit that lands a surface. Any COW/thread race surfaces as byte-inequality.
##
## Run (FACETED + FP_LOAD_DEFER + FP_GLOBAL_RELIEF_DATA + FP_SMOOTH_V2 [+ FP_SMOOTH_V2_PACE + FP_SMOOTH_V2_ASYNC_MERGE
## for the Phase-2 gates] sed-toggled true):
##   godot --headless --path godot --script res://src/tools/verify_fast_load.gd 2>/dev/null | grep VERIFY

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# A SnowfallSystem subclass that only COUNTS process() calls (so the snow-gate assertion needs no real weather sim).
class _SnowStub extends SnowfallSystem:
	var writes := 0
	func process(_delta: float, _pos: Vector3) -> void:
		writes += 1

# A minimal module stand-in with a controllable area_meshed (drives WorldManager.initial_view_meshed on the module path).
class _ModStub extends Node3D:
	var meshed := false
	func area_meshed(_center, _half) -> bool:
		return meshed

func _initialize() -> void:
	print("=== verify_fast_load (task #103 Phase 1 — FP_LOAD_DEFER, compiled FP_LOAD_DEFER=%s) ===" % str(CubeSphere.FP_LOAD_DEFER))
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	if CubeSphere.FP_LOAD_DEFER:
		_gate_smooth_freeze()
		_gate_env_hold_wiring()
		_gate_snow_gate()
		_gate_settle_latch()
		_gate_failsafe()
	else:
		_gate_off()

	# Phase 2 (docs/COSMOS-FAST-LOAD-DESIGN.md §2.1.2/§2.1.3) — self-describe on the COMPILED flag, like Phase 1 above.
	if CubeSphere.FP_SMOOTH_V2_PACE:
		_gate_pace()
	if CubeSphere.FP_SMOOTH_V2_ASYNC_MERGE:
		_gate_merge_eq()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-FL-OFF: FP_LOAD_DEFER off ⇒ the freeze machinery is inert (settled param ignored, latch never settles) --------
func _gate_off() -> void:
	# FacetSmoothV2.step(settled=false) must NOT freeze off the flag: a queued commit still fires.
	var ring := Node3D.new()
	var sv := FacetSmoothV2.new()
	sv.setup_instance(ring, 12)
	sv._want = {}; sv._want_order = []      # isolate the commit path (no dispatch)
	sv._dirty = true
	sv.step(false, false)                   # settled=false, credit=false — but the flag is off ⇒ no freeze
	_ok(sv.commit_count() == 1, "G-FL-OFF: step(settled=false) still commits off the flag (freeze inert)")
	ring.free()
	# WorldManager latch is inert off the flag.
	var wm := WorldManager.new()
	_ok(not wm._load_defer_tick(Vector3.ZERO), "G-FL-OFF: _load_defer_tick never flips off the flag")
	_ok(not wm._load_settled, "G-FL-OFF: _load_settled stays false off the flag (gates nothing)")
	wm.free()
	print("  [G-FL-OFF] NOTE: the authoritative byte-off pin is external — FLAT verify_feature.gd 6042/0 with FP_LOAD_DEFER false.")

# --- G-FL-GATE (smooth-v2): pre-settle reap-only (0 dispatch, 0 commit); resume paced; first commit waits on credit ---
func _gate_smooth_freeze() -> void:
	# (1) COMMIT freeze + first-commit credit gate. Isolate the commit path (empty want ⇒ no dispatch either way).
	var ring := Node3D.new()
	var sv := FacetSmoothV2.new()
	sv.setup_instance(ring, 12)
	sv._want = {}; sv._want_order = []
	sv._dirty = true
	sv.step(false, true)                    # PRE-SETTLE: reap-only, return before commit
	_ok(sv.commit_count() == 0, "G-FL-GATE: pre-settle step commits NOTHING (WS1a freeze)")
	_ok(sv.dispatch_count() == 0, "G-FL-GATE: pre-settle step dispatches NOTHING")
	_ok(sv._dirty, "G-FL-GATE: `_dirty` accumulates across the freeze (commit deferred, not lost)")
	sv.step(true, false)                    # POST-SETTLE, credit NOT ok: first commit still held
	_ok(sv.commit_count() == 0, "G-FL-GATE: first post-settle commit WAITS for stream_credit>0")
	_ok(sv._merge_task < 0, "G-FL-GATE: pre-credit NOTHING is dispatched (async merge held too)")
	# credit ok ⇒ the first commit lands. `_open_pace`/`_settle_async` make this robust when FP_SMOOTH_V2_PACE /
	# FP_SMOOTH_V2_ASYNC_MERGE are ALSO compiled on (combined Phase-2 toggle): pace can't false-block the commit, and
	# the async merge is driven to completion deterministically (step()'s is_task_completed reap is unreliable in a
	# frame-less headless SceneTree — see _settle_async; the LIVE reap uses the same idiom as the shipped build reap).
	_open_pace(sv)
	sv.step(true, true)
	_settle_async(sv)
	_ok(sv.commit_count() == 1, "G-FL-GATE: first commit fires once credit recovers")
	sv._dirty = true
	_open_pace(sv)
	sv.step(true, false)                    # credit-gate is first-commit-ONLY ⇒ subsequent commits are unconditional
	_settle_async(sv)
	_ok(sv.commit_count() == 2, "G-FL-GATE: the credit wait is spent after the first commit (later commits unconditional)")
	ring.free()

	# (2) DISPATCH freeze + resume. A populated want-set with nothing resident ⇒ dispatch is wanted.
	var ring2 := Node3D.new()
	var sv2 := FacetSmoothV2.new()
	sv2.setup_instance(ring2, 12)           # setup_instance seeds _want/_want_order (the crossing annulus)
	if sv2._want_order.is_empty():
		_ok(true, "G-FL-GATE: dispatch-freeze skipped (empty annulus this fixture) — commit-freeze above covers the WS1a return")
	else:
		sv2._dispatch_count = 0
		sv2.step(false, true)               # PRE-SETTLE: frozen before the dispatch loop
		_ok(sv2._dispatch_count == 0, "G-FL-GATE: pre-settle dispatches ZERO builds (worker seats belong to the near field)")
		sv2.step(true, true)                # POST-SETTLE: dispatch resumes
		_ok(sv2._dispatch_count > 0, "G-FL-GATE: post-settle dispatch resumes")
		# DRAIN in-flight worker tasks before sv2 (RefCounted, bound into the worker Callable) drops — clear want so no re-dispatch.
		sv2._want = {}; sv2._want_order = []
		for _i in range(4000):
			sv2.step(true, true)
			var busy := sv2._merge_task >= 0
			for s in range(sv2._sn):
				if int(sv2._s_fid[s]) >= 0:
					busy = true
					break
			if not busy:
				break
	ring2.free()

# --- G-FL-GATE (env hold): the surface env warm-converge `hold` reads the settle latch; set_load_settled releases it --
func _gate_env_hold_wiring() -> void:
	# Functional: a fresh ring defaults NOT-settled (the pre-settle hold-active state); set_load_settled releases it.
	var ring := FacetFarRing.new()
	_ok(not ring._load_settled, "G-FL-GATE: a fresh ring defaults NOT-settled (env load-hold active pre-settle)")
	ring.set_load_settled(true)
	_ok(ring._load_settled, "G-FL-GATE: set_load_settled(true) releases the load-hold / unfreezes smooth-v2")
	ring.free()
	# Source: the ONE surface-env-converge `hold` test site ORs the load latch (the floored-async path can't be cheaply
	# driven headless; this pins the wiring that makes the load-hold reuse the FP_ENV_FALL_HOLD chord-only branch).
	var f := FileAccess.open("res://src/world/facet_far_ring.gd", FileAccess.READ)
	_ok(f != null, "G-FL-GATE: opened facet_far_ring.gd for the env-hold wiring check")
	if f != null:
		var src := f.get_as_text()
		f.close()
		_ok(src.find("CubeSphere.FP_LOAD_DEFER and not _load_settled") != -1,
			"G-FL-GATE: the env warm-converge `hold` ORs (FP_LOAD_DEFER and not _load_settled) — chord-only load-hold")

# --- G-FL-GATE (snow): the main-thread snow step is skipped pre-settle, runs post-settle ------------------------------
func _gate_snow_gate() -> void:
	var wm := WorldManager.new()
	var snow := _SnowStub.new()
	wm._snowfall = snow
	wm._have_player_pos = true
	wm._last_player_pos = Vector3.ZERO      # alt 0 ⇒ snow_skip_airborne() false regardless of its flag
	# everything else (_weather/_job_lane/_load_ctrl/_facet_ring/_module_world) stays null ⇒ only the snow branch runs
	wm._load_settled = false
	wm._process(0.1)
	_ok(snow.writes == 0, "G-FL-GATE: pre-settle the main-thread snow step is SKIPPED (zero snow writes)")
	wm._load_settled = true
	wm._process(0.1)
	_ok(snow.writes == 1, "G-FL-GATE: post-settle the snow step resumes (one write)")
	wm.free()

# --- G-FL-GATE (settle latch + broadcast): flips ONCE off initial_view_meshed; broadcasts ring + relief; boot-once ----
func _gate_settle_latch() -> void:
	var wm := WorldManager.new()
	var mod := _ModStub.new()
	wm.add_child(mod)
	wm.using_module = true
	wm._module_world = mod
	var ring := FacetFarRing.new()
	wm._facet_ring = ring
	var rd := GlobalReliefData.new()
	rd.setup()
	wm._relief_data = rd

	mod.meshed = false
	_ok(not wm._load_defer_tick(Vector3.ZERO), "G-FL-GATE: not flipped while the near view is unmeshed (deferred)")
	_ok(not wm._load_settled and not ring._load_settled, "G-FL-GATE: pre-settle both latches false")
	_ok(not rd.is_settled(), "G-FL-GATE: pre-settle GlobalReliefData is NOT settled (DEM deferred — verify_stream_parallel proves it bakes nothing)")

	mod.meshed = true
	_ok(wm._load_defer_tick(Vector3.ZERO), "G-FL-GATE: flips the frame the near view meshes")
	_ok(wm._load_settled, "G-FL-GATE: WorldManager latch set")
	_ok(ring._load_settled, "G-FL-GATE: broadcast reached the ring (set_load_settled) — smooth-v2 unfreeze + env-hold release")
	_ok(rd.is_settled(), "G-FL-GATE: broadcast reached GlobalReliefData (mark_settled) — DEM resumes")
	# Boot-once: never re-flips (no re-arm on crossings).
	mod.meshed = false
	_ok(not wm._load_defer_tick(Vector3.ZERO), "G-FL-GATE: boot-once — the latch does not re-arm after settle")
	_ok(wm._load_settled, "G-FL-GATE: stays settled (no re-freeze on crossings)")

	ring.free()
	wm.free()

# --- G-FL-FAILSAFE: the latch force-flips at LOAD_DEFER_FAILSAFE_MS even if initial_view_meshed never trips -----------
func _gate_failsafe() -> void:
	var wm := WorldManager.new()
	var mod := _ModStub.new()
	wm.add_child(mod)
	wm.using_module = true
	wm._module_world = mod
	mod.meshed = false                      # the near view NEVER meshes on this fixture

	# A huge cap ⇒ the failsafe term can't have elapsed yet (headless clock < the real 45 s): stays deferred.
	_ok(not wm._load_defer_tick(Vector3.ZERO, 999999999), "G-FL-FAILSAFE: not flipped before the cap (view unmeshed)")
	_ok(wm._load_defer_start_ms >= 0, "G-FL-FAILSAFE: the wall-clock anchor is armed on first tick")
	# A zero cap forces the wall-clock term true ⇒ the failsafe must flip the latch despite meshed==false (proving the
	# backstop path; the real cap is LOAD_DEFER_FAILSAFE_MS=%d, exercised live). Overriding the budget avoids a 45 s wait.
	_ok(wm._load_defer_tick(Vector3.ZERO, 0), "G-FL-FAILSAFE: the wall-clock backstop flips the latch even though the view never meshed")
	_ok(wm._load_settled, "G-FL-FAILSAFE: settled by the failsafe (far field can't defer forever)")
	wm.free()

# --- G-FL-PACE (FP_SMOOTH_V2_PACE): the commit is rate-capped to SMOOTH_V2_COMMIT_MS; a burst collapses to 1 commit --
func _gate_pace() -> void:
	# (a) the PURE G3 boundary — SMOOTH_V2_COMMIT_MS honoured exactly (synthetic timestamps, no wall-clock wait).
	var iv := CubeSphere.SMOOTH_V2_COMMIT_MS
	_ok(FacetOrbitRelief.should_commit(true, iv, 0, iv), "G-FL-PACE: should_commit TRUE at exactly SMOOTH_V2_COMMIT_MS since last")
	_ok(not FacetOrbitRelief.should_commit(true, iv - 1, 0, iv), "G-FL-PACE: should_commit FALSE one ms before the window opens")
	_ok(not FacetOrbitRelief.should_commit(true, 600 + iv - 1, 600, iv), "G-FL-PACE: the window is measured from the LAST commit")
	_ok(not FacetOrbitRelief.should_commit(false, iv + 1000, 0, iv), "G-FL-PACE: never commits when NOT dirty (no work)")

	# (b) FUNCTIONAL falsifier: 36 rapid reaps inside one wall-clock window ⇒ ONE commit, not 36. `_settle_async` makes
	# it robust whether or not FP_SMOOTH_V2_ASYNC_MERGE is ALSO compiled on (the combined Phase-2 toggle): it drives the
	# single in-flight async merge to completion deterministically so its commit counts inside the same <500ms window.
	var ring := Node3D.new()
	var sv := FacetSmoothV2.new()
	sv.setup_instance(ring, 12)
	sv._want = {}; sv._want_order = []          # isolate the commit path (no build dispatch)
	var gen = FacetSkinTier._build_cpp_gen(12)
	var t := FacetSmoothV2.build_tile(12, CubeSphere.V2_CELLS, gen)
	if not t.is_empty():
		sv._tiles[12] = t                       # a real resident tile so the commit builds a surface
	for _i in range(36):
		sv._dirty = true
		sv.step(true, true)                     # rapid — all inside one SMOOTH_V2_COMMIT_MS window
		_settle_async(sv)                       # complete the single async merge into its commit (no-op when async off)
	_ok(sv.commit_count() == 1, "G-FL-PACE: 36 rapid reaps collapse to ONE commit (rate-capped), not 36 [got %d]" % sv.commit_count())
	_ok(sv._dirty, "G-FL-PACE: the pace-blocked dirties accumulate (commit deferred, not lost)")
	ring.free()

# --- G-FL-MERGE-EQ (FP_SMOOTH_V2_ASYNC_MERGE, CRITICAL): off-thread merge == sync merge_tiles, byte-for-byte --------
func _gate_merge_eq() -> void:
	var gen = FacetSkinTier._build_cpp_gen(12)
	var pool := {}
	for fid in [10, 11, 12, 13, 14, 15, 20, 21]:
		var tt := FacetSmoothV2.build_tile(int(fid), CubeSphere.V2_CELLS, gen)
		if not tt.is_empty():
			pool[int(fid)] = tt
	if pool.size() < 4:
		_ok(false, "G-FL-MERGE-EQ: could not bake >=4 real tiles (module absent?) — byte-eq unprovable this run")
		return
	_ok(true, "G-FL-MERGE-EQ: baked %d real tiles for the byte-eq stress" % pool.size())
	var pfids := pool.keys()

	# Many tile sets: every prefix (varying resident-set size) + its reversed-insertion twin (same fids, different
	# Dictionary order ⇒ the canonical ascending-fid sort must erase the difference). Each merged off-thread vs sync.
	var n_sets := 0
	var all_eq := true
	for n in range(2, pfids.size() + 1):
		var d := {}
		for i in range(n):
			d[int(pfids[i])] = pool[int(pfids[i])]
		var dr := {}
		for i in range(n - 1, -1, -1):
			dr[int(pfids[i])] = pool[int(pfids[i])]
		var sync_d := FacetSmoothV2.merge_tiles(d)
		if not _arrays_equal(sync_d, _merge_on_worker(d, {})):
			all_eq = false
		if not _arrays_equal(sync_d, _merge_on_worker(dr, {})):
			all_eq = false
		n_sets += 2
	_ok(all_eq, "G-FL-MERGE-EQ: off-thread merge == sync merge_tiles byte-for-byte across %d tile sets/orders" % n_sets)

	# COW stress: churn the ORIGINAL dict on MAIN (erase + re-add + a transient insert/erase) WHILE the worker merges
	# its snapshot — the snapshot merge must still equal a sync merge of the pre-mutation set (the snapshot's own refs
	# keep the shared tile arrays alive; any refcount/CoW race corrupting the result would surface as byte-inequality).
	var base := {}
	for i in range(pfids.size()):
		base[int(pfids[i])] = pool[int(pfids[i])]
	var expect := FacetSmoothV2.merge_tiles(base)
	var cow_eq := true
	for _rep in range(8):
		if not _arrays_equal(expect, _merge_on_worker(base, pool)):
			cow_eq = false
	_ok(cow_eq, "G-FL-MERGE-EQ: snapshot merge survives main-thread mutation during flight (CoW / refcount safe)")

	# Instance path: a step() DISPATCHES the merge off-thread (never commits inline), the worker's own result is the
	# SAME arrays as the sync merge of the instance's resident set, and applying it lands exactly one real surface.
	# (Driven via wait_for_task_completion rather than step()'s is_task_completed reap — the latter is unreliable in a
	# frame-less headless SceneTree; the LIVE reap uses the shipped build-reap idiom and is exercised in the browser.)
	var ring := Node3D.new()
	var sv := FacetSmoothV2.new()
	sv.setup_instance(ring, 12)
	sv._want = {}; sv._want_order = []
	for i in range(pfids.size()):
		sv._tiles[int(pfids[i])] = pool[int(pfids[i])]
	sv._dirty = true
	sv.step(true, true)                         # dispatches the merge, does NOT commit inline
	_ok(sv._merge_task >= 0, "G-FL-MERGE-EQ: instance step() dispatches the merge off-thread (no inline commit)")
	_ok(sv.commit_count() == 0, "G-FL-MERGE-EQ: the main thread has NOT committed yet (merge still off-thread)")
	WorkerThreadPool.wait_for_task_completion(sv._merge_task)
	sv._merge_mutex.lock(); var got = sv._merge_result; sv._merge_mutex.unlock()
	_ok(got != null and _arrays_equal(got, FacetSmoothV2.merge_tiles(sv._tiles)),
		"G-FL-MERGE-EQ: the instance worker's merged arrays == sync merge_tiles of its resident set")
	sv._build_and_swap(got)
	_ok(sv._mi.mesh != null and sv._mi.mesh.get_surface_count() == 1, "G-FL-MERGE-EQ: the merged arrays apply to ONE real surface on main")
	sv._merge_task = -1; sv._merge_result = null   # slot cleared — free() is clean
	ring.free()

# Merge a shallow snapshot of `src` on a WorkerThreadPool task (mirrors FacetSmoothV2._merge_worker). If `mutate_pool`
# is non-empty, churn the ORIGINAL `src` on MAIN between dispatch and reap (the CoW stress) — the snapshot is
# independent (duplicate taken before the churn), so a correct result is unchanged by the mutation.
var _mm_mutex: Mutex = null
var _mm_result = null
func _merge_task_fn(snapshot: Dictionary) -> void:
	var r := FacetSmoothV2.merge_tiles(snapshot)
	_mm_mutex.lock(); _mm_result = r; _mm_mutex.unlock()

func _merge_on_worker(src: Dictionary, mutate_pool: Dictionary) -> Dictionary:
	if _mm_mutex == null:
		_mm_mutex = Mutex.new()
	var snapshot := src.duplicate()             # shallow — mirrors FacetSmoothV2's `_tiles.duplicate()` dispatch
	_mm_result = null
	var task := WorkerThreadPool.add_task(Callable(self, "_merge_task_fn").bind(snapshot), true, "gatemerge")
	if not mutate_pool.is_empty():
		var keys := src.keys()
		if keys.size() > 0:
			var victim := int(keys[0])
			var saved = src[victim]
			src.erase(victim); src[victim] = saved          # move victim to the end (key-order churn)
			for k in mutate_pool.keys():
				if not src.has(int(k)):
					src[int(k)] = mutate_pool[k]; src.erase(int(k))  # transient insert then drop
					break
	WorkerThreadPool.wait_for_task_completion(task)
	_mm_mutex.lock(); var r = _mm_result; _mm_result = null; _mm_mutex.unlock()
	return r

func _arrays_equal(a, b) -> bool:
	if a == null or b == null:
		return false
	return (a["pos"] == b["pos"] and a["nrm"] == b["nrm"] and a["col"] == b["col"] and a["idx"] == b["idx"])

# Deterministically complete an in-flight FacetSmoothV2 async merge into its commit — the SAME work step()'s async
# reap does, but driven via wait_for_task_completion instead of is_task_completed (the latter is unreliable in a
# frame-less headless SceneTree, so a step()-driven reap can never be relied on here; the LIVE reap uses the shipped
# build-reap idiom and is exercised in the browser). No-op when FP_SMOOTH_V2_ASYNC_MERGE is off (sync `_commit`
# already incremented the count inline) or when no merge is in flight.
func _settle_async(sv) -> void:
	if not CubeSphere.FP_SMOOTH_V2_ASYNC_MERGE or sv._merge_task < 0:
		return
	WorkerThreadPool.wait_for_task_completion(sv._merge_task)
	sv._merge_task = -1
	sv._merge_mutex.lock(); var merged = sv._merge_result; sv._merge_result = null; sv._merge_mutex.unlock()
	if merged != null:
		sv._build_and_swap(merged)
		sv._first_commit_done = true
		sv._commit_count += 1

# Open the FP_SMOOTH_V2_PACE rate-cap window so the NEXT step() commits (isolates credit/commit-accounting from the
# pace cadence, which G-FL-PACE asserts separately). No-op semantics when pace is off (the field is simply unread).
func _open_pace(sv) -> void:
	sv._last_commit_wall_ms = Time.get_ticks_msec() - CubeSphere.SMOOTH_V2_COMMIT_MS - 1
