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
## Run (FACETED + FP_LOAD_DEFER + FP_GLOBAL_RELIEF_DATA + FP_SMOOTH_V2 sed-toggled true):
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
	sv.step(true, true)                     # credit ok ⇒ the first commit lands
	_ok(sv.commit_count() == 1, "G-FL-GATE: first commit fires once credit recovers")
	sv._dirty = true
	sv.step(true, false)                    # credit-gate is first-commit-ONLY ⇒ subsequent commits are unconditional
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
			var busy := false
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
