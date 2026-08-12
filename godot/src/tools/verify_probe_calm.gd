extends SceneTree
## COSMOS-APPLIED-PROBE-CALM-DESIGN.md §R2.5.5 gate (FP_APPLIED_PROBE_CALM) — proves the sink-side `_pending`
## coalescer: the choke-point sensor, the SAFETY/LUXURY partition, the net-zero debounce (the live win), the ladder
## per-climb single-arm, and the forward luxury rail. Runs in BOTH compile states and passes in both:
##
##   flag OFF (G-APC-7 parity): `_arm_pending(any, any)` is exactly the shipped `_pending = true` write (no counter,
##      no latch, no rail); `_pending_src` stays empty; `_applied_probe_step` runs the shipped ladder body verbatim;
##      `_calm_try_promote_luxury` is inert. This is the byte-off proof (arm-for-arm identical behaviour).
##   flag ON: the full CALM behaviour —
##      G-APC-8 sensor exactness   — driving tags 0..SRC_COUNT-1 once each bumps exactly its own slot, in enum order.
##      G-APC-2 safety-immediate   — every SAFETY tag arms `_pending` the SAME frame; every LUXURY tag parks instead.
##      G-APC-4 default-safety      — an unknown/OOB tag arms SAFETY (luxury defaults false), no crash.
##      G-APC-5 ladder fixpoint     — a 0→MAX climb arms SRC_LADDER_GROW exactly ONCE, same-frame at the fixpoint.
##      G-APC-6 net-zero            — a 1-frame AND a 5-frame shrink/unsink transient that REVERTS ⇒ 0 arms, 0 state
##                                    change; a change that STANDS past CALM_NETZERO_HOLD_MS ⇒ commit + one SAFETY arm.
##      G-APC-1 luxury coalesce     — a parked luxury arm promotes ≤1× per settle+rate window.
##      G-APC-3 credit gate         — `_stream_credit_ok=false` ⇒ a luxury arm NEVER promotes; flip true ⇒ it promotes.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

# The live degraded INPUT the design pins (mirrors verify_applied_slab): (r=128, O=0, H=128).
const PROBE_PARAMS := Vector3(128.0, 0.0, 128.0)

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# --- synthetic coverage callables (decouple the ladder from FP_APPLIED_PROBE_SLAB: return the same for any AABB) ---
func _cover_true(_fid: int, _aabb: AABB) -> bool:
	return true
func _cover_false(_fid: int, _aabb: AABB) -> bool:
	return false

# Fresh far-ring for a fixture: new + parent + set active. Under the flag, seed the per-source sensor to SRC_COUNT
# zeroes (setup() does this live; the gate skips setup()'s node/material build and seeds directly).
func _fresh_ring(fid: int) -> Node3D:
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", fid)
	if CubeSphere.FP_APPLIED_PROBE_CALM:
		var z := PackedInt32Array()
		z.resize(FFR.SRC_COUNT)
		ring.set("_pending_src", z)
	return ring

func _initialize() -> void:
	print("=== verify_probe_calm (COSMOS-APPLIED-PROBE-CALM — FP_APPLIED_PROBE_CALM) ===")
	TC.warm_up()
	FA.warm_up()
	var on := CubeSphere.FP_APPLIED_PROBE_CALM
	print("  FP_APPLIED_PROBE_CALM = %s ; SRC_COUNT = %d ; NETZERO_HOLD = %d ms ; SETTLE = %d ms ; APPLY_MIN = %d ms" % [
		str(on), FFR.SRC_COUNT, CubeSphere.CALM_NETZERO_HOLD_MS, CubeSphere.CALM_SETTLE_MS, CubeSphere.CALM_APPLY_MIN_MS])
	# The sensor enum order the design pins (index = position in sh_pending_src). Asserted here so a reorder is caught.
	_ok(FFR.SRC_BOOT == 0 and FFR.SRC_CROSS == 1 and FFR.SRC_SMOOTH_CHG == 2 and FFR.SRC_SMOOTH_INC == 3
		and FFR.SRC_CAM == 4 and FFR.SRC_POOL == 5 and FFR.SRC_NB_BUILT == 6 and FFR.SRC_NB_UNCOVER == 7
		and FFR.SRC_NB_RESINK == 8 and FFR.SRC_NB_NOTEMIT == 9 and FFR.SRC_UNSINK == 10
		and FFR.SRC_LADDER_SHRINK == 11 and FFR.SRC_LADDER_GROW == 12 and FFR.SRC_CULL_FLUSH == 13
		and FFR.SRC_CULL_APPLY == 14 and FFR.SRC_SLOTS == 15 and FFR.SRC_RELIEF == 16 and FFR.SRC_FORCE == 17
		and FFR.SRC_COUNT == 18,
		"fixture: SRC_* enum order matches the design's fixed sh_pending_src layout (0..17)")

	var fid := 0
	if on:
		_gate_sensor_and_partition(fid)
		_gate_default_safety(fid)
		_gate_ladder_fixpoint(fid)
		_gate_netzero_ladder(fid)
		_gate_netzero_noblack(fid)
		_gate_luxury_rail(fid)
	else:
		_gate_off_parity(fid)

	print("=== verify_probe_calm: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# The SAFETY vs LUXURY partition from R2.5.2 (luxury = SMOOTH_CHG, CULL_APPLY, RELIEF; everything else SAFETY).
func _is_luxury(tag: int) -> bool:
	return tag == FFR.SRC_SMOOTH_CHG or tag == FFR.SRC_CULL_APPLY or tag == FFR.SRC_RELIEF

# ---------- G-APC-8 + G-APC-2: sensor exactness + safety/luxury immediacy ----------
func _gate_sensor_and_partition(fid: int) -> void:
	print("  --- G-APC-8/2: sensor bumps exactly its tag (enum order); SAFETY arms now, LUXURY parks ---")
	var ring := _fresh_ring(fid)
	ring.call("set_stream_credit_ok", false)   # keep the luxury rail from draining during the drive
	# Drive every tag once, in order, with its correct class, from ONE ring: the sensor must end all-ones.
	var order_ok := true
	var immediate_ok := true
	for tag in range(FFR.SRC_COUNT):
		var lux := _is_luxury(tag)
		ring.set("_pending", false)            # isolate the same-frame effect of THIS arm
		ring.call("_arm_pending", tag, lux)
		var src: PackedInt32Array = ring.get("_pending_src")
		if src[tag] != 1:
			order_ok = false
		if lux:
			if bool(ring.get("_pending")):     # LUXURY must NOT set _pending immediately
				immediate_ok = false
		else:
			if not bool(ring.get("_pending")): # SAFETY must set _pending the same frame
				immediate_ok = false
	var src_final: PackedInt32Array = ring.get("_pending_src")
	var all_ones := true
	for tag in range(FFR.SRC_COUNT):
		if src_final[tag] != 1:
			all_ones = false
	_ok(order_ok, "G-APC-8: each tag bumps exactly its own sensor slot")
	_ok(all_ones, "G-APC-8: after driving all 18 tags once, sh_pending_src is all-ones (fixed order)")
	_ok(immediate_ok, "G-APC-2: SAFETY tags arm _pending same-frame; LUXURY tags park (no _pending)")
	_ok(bool(ring.get("_pending_luxury")), "G-APC-2: a LUXURY arm sets _pending_luxury")
	ring.free()

# ---------- G-APC-4: default-safety for an unknown tag ----------
func _gate_default_safety(fid: int) -> void:
	print("  --- G-APC-4: an unknown/OOB tag arms SAFETY (no crash, no sensor OOB write) ---")
	var ring := _fresh_ring(fid)
	ring.set("_pending", false)
	ring.call("_arm_pending", 999)             # unknown future tag, luxury defaults false ⇒ SAFETY
	_ok(bool(ring.get("_pending")), "G-APC-4: unknown tag (no luxury flag) arms _pending immediately (default SAFETY)")
	_ok(not bool(ring.get("_pending_luxury")), "G-APC-4: unknown tag does not touch the luxury rail")
	ring.free()

# ---------- G-APC-5: ladder climb 0→MAX arms GROW exactly once, same-frame at the fixpoint ----------
func _gate_ladder_fixpoint(fid: int) -> void:
	print("  --- G-APC-5: 0→MAX climb ⇒ exactly ONE SRC_LADDER_GROW arm, same-frame at the fixpoint ---")
	var ring := _fresh_ring(fid)
	ring.call("set_cover_query", Callable(self, "_cover_true"))  # every grow probe passes
	ring.call("set_player_column", Vector3(FA.R_BLOCKS, 0.0, 0.0))
	var step := float(CubeSphere.APPLIED_PROBE_STEP)
	var max_r := float(CubeSphere.APPLIED_PROBE_MAX)
	var calls := ceili(max_r / step) + 3
	var grew_ok := true
	var prev := 0.0
	var grow_arm_seen_before_fixpoint := false
	for i in range(calls):
		ring.set("_pending", false)
		ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)
		var cur := float(ring.get("_applied_r"))
		if cur - prev > step + 0.001 or cur < prev - 0.001:
			grew_ok = false
		# while still growing (cur > prev) there must be NO grow arm yet (silent climb)
		var g: PackedInt32Array = ring.get("_pending_src")
		if cur > prev + 0.001 and g[FFR.SRC_LADDER_GROW] > 0:
			grow_arm_seen_before_fixpoint = true
		prev = cur
	var src: PackedInt32Array = ring.get("_pending_src")
	_ok(grew_ok, "G-APC-5: ladder grows ≤1 step/call, monotone up (silent climb)")
	_ok(is_equal_approx(prev, max_r), "G-APC-5: ladder converges to APPLIED_PROBE_MAX (%d), got %.1f" % [int(max_r), prev])
	_ok(not grow_arm_seen_before_fixpoint, "G-APC-5: NO grow arm fires while the ladder is still climbing")
	_ok(src[FFR.SRC_LADDER_GROW] == 1, "G-APC-5: exactly ONE SRC_LADDER_GROW arm for the whole 0→MAX climb (got %d)" % src[FFR.SRC_LADDER_GROW])
	# same-frame: the fixpoint call that armed GROW also set _pending true (no deferred grey window).
	# Re-drive one more step at the fixpoint (already at MAX, cover still true) ⇒ no NEW arm (dedup by emitted_r).
	ring.set("_pending", false)
	ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)
	_ok(src[FFR.SRC_LADDER_GROW] == 1 and not bool(ring.get("_pending")),
		"G-APC-5: at the fixpoint no further grow arms (emitted_r dedup) — steady state is silent")
	ring.free()

# ---------- G-APC-6a: ladder SHRINK net-zero debounce ----------
func _gate_netzero_ladder(fid: int) -> void:
	print("  --- G-APC-6a: ladder shrink — a reverting transient ⇒ 0 arms; a standing failure ⇒ 1 arm ---")
	var ring := _fresh_ring(fid)
	ring.call("set_cover_query", Callable(self, "_cover_true"))
	ring.call("set_player_column", Vector3(FA.R_BLOCKS, 0.0, 0.0))
	var max_r := float(CubeSphere.APPLIED_PROBE_MAX)
	# climb to MAX first
	for i in range(ceili(max_r / float(CubeSphere.APPLIED_PROBE_STEP)) + 3):
		ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)
	_ok(is_equal_approx(float(ring.get("_applied_r")), max_r), "G-APC-6a: pre-state — ladder at MAX")
	# reset the sensor to isolate the shrink counting
	var z := PackedInt32Array(); z.resize(FFR.SRC_COUNT); ring.set("_pending_src", z)

	# (1) 1-frame transient: cover fails for ONE call, then reverts. Deadline (250ms) is far in the future.
	ring.call("set_cover_query", Callable(self, "_cover_false"))
	ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)   # re-verify fails ⇒ hold begins, NOT dropped
	_ok(is_equal_approx(float(ring.get("_applied_r")), max_r) and bool(ring.get("_calm_ladder_shrink_active")),
		"G-APC-6a: 1-frame — shrink HELD (radius still MAX, hold armed), not dropped")
	ring.call("set_cover_query", Callable(self, "_cover_true"))
	ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)   # revert ⇒ cancel
	var s1: PackedInt32Array = ring.get("_pending_src")
	_ok(is_equal_approx(float(ring.get("_applied_r")), max_r) and not bool(ring.get("_calm_ladder_shrink_active"))
		and s1[FFR.SRC_LADDER_SHRINK] == 0,
		"G-APC-6a: 1-frame reverting transient ⇒ 0 shrink arms, radius unchanged (net-zero cancel)")

	# (2) 5-frame transient: cover fails for 5 calls (all < 250ms real), then reverts ⇒ still 0 arms.
	ring.call("set_cover_query", Callable(self, "_cover_false"))
	for i in range(5):
		ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)
	ring.call("set_cover_query", Callable(self, "_cover_true"))
	ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)
	var s2: PackedInt32Array = ring.get("_pending_src")
	_ok(is_equal_approx(float(ring.get("_applied_r")), max_r) and s2[FFR.SRC_LADDER_SHRINK] == 0,
		"G-APC-6a: 5-frame reverting transient ⇒ still 0 shrink arms (deadline not reached)")

	# (3) standing failure: cover fails and STANDS past the hold ⇒ commit to 0 + one SAFETY arm.
	ring.call("set_cover_query", Callable(self, "_cover_false"))
	ring.set("_pending", false)
	ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)   # hold begins
	ring.set("_calm_ladder_shrink_deadline", Time.get_ticks_msec() - 1)  # force the hold to have expired
	ring.call("_applied_probe_step_calm", true, PROBE_PARAMS)   # deadline passed ⇒ commit + arm
	var s3: PackedInt32Array = ring.get("_pending_src")
	_ok(is_equal_approx(float(ring.get("_applied_r")), 0.0) and s3[FFR.SRC_LADDER_SHRINK] == 1
		and bool(ring.get("_pending")),
		"G-APC-6a: a standing shrink ⇒ radius drops to 0, exactly ONE SRC_LADDER_SHRINK arm, _pending same frame")
	ring.free()

# ---------- G-APC-6b: noblack unsink FLIP net-zero debounce (only under NOBLACK+FULL_COVER) ----------
func _gate_netzero_noblack(fid: int) -> void:
	if not (CubeSphere.FP_FARRING_ACTIVE_NOBLACK and CubeSphere.FP_FARRING_FULL_COVER):
		print("  --- G-APC-6b: noblack net-zero SKIPPED (FP_FARRING_ACTIVE_NOBLACK/FULL_COVER off this build; ladder covers the mechanism) ---")
		return
	print("  --- G-APC-6b: noblack unsink flip — reverting transient ⇒ 0 arms/no flip; standing ⇒ commit + 1 arm ---")
	var ring := _fresh_ring(fid)
	ring.call("set_cover_query", Callable(self, "_cover_true"))
	ring.call("set_player_column", Vector3(FA.R_BLOCKS, 0.0, 0.0))
	ring.set("_bpos_cache", {fid: PackedVector3Array()})   # built_now=false (skip the NB_BUILT arm)
	ring.set("_emitted", {fid: true})                      # not-emitted disjunct false (skip NB_NOTEMIT)
	var p := [[0.0, 0.0, 1.0], 0.0]                        # dummy cull params (front_visible short-circuits on active)
	# steady meshed: uncovered=false ⇒ new_unsink=-1 == committed(-1) ⇒ no flip
	ring.call("_noblack_guarantee", p, false, true)
	_ok(int(ring.get("_noblack_unsink_fid")) == -1, "G-APC-6b: pre-state — meshed ⇒ unsink stays -1")
	var z := PackedInt32Array(); z.resize(FFR.SRC_COUNT); ring.set("_pending_src", z)

	# (1) transient un-mesh for ONE call then revert ⇒ flip HELD, then cancelled: 0 arms, unsink still -1.
	ring.call("set_cover_query", Callable(self, "_cover_false"))
	ring.call("_noblack_guarantee", p, false, true)        # uncovered ⇒ new_unsink=fid; flip held (not committed)
	_ok(int(ring.get("_noblack_unsink_fid")) == -1 and bool(ring.get("_calm_nb_hold_active")),
		"G-APC-6b: 1-frame — flip HELD (unsink still -1, hold armed)")
	ring.call("set_cover_query", Callable(self, "_cover_true"))
	ring.call("_noblack_guarantee", p, false, true)        # revert ⇒ cancel
	var s1: PackedInt32Array = ring.get("_pending_src")
	_ok(int(ring.get("_noblack_unsink_fid")) == -1 and s1[FFR.SRC_NB_UNCOVER] == 0 and s1[FFR.SRC_NB_RESINK] == 0,
		"G-APC-6b: 1-frame reverting transient ⇒ 0 unsink arms, no flip (net-zero cancel)")

	# (2) standing un-mesh past the hold ⇒ commit the flip (unsink=fid) + one SRC_NB_UNCOVER arm.
	ring.call("set_cover_query", Callable(self, "_cover_false"))
	ring.set("_pending", false)
	ring.call("_noblack_guarantee", p, false, true)        # hold begins
	ring.set("_calm_nb_hold_deadline", Time.get_ticks_msec() - 1)
	ring.call("_noblack_guarantee", p, false, true)        # deadline passed ⇒ commit + arm
	var s2: PackedInt32Array = ring.get("_pending_src")
	_ok(int(ring.get("_noblack_unsink_fid")) == fid and s2[FFR.SRC_NB_UNCOVER] == 1 and bool(ring.get("_pending")),
		"G-APC-6b: a standing un-mesh ⇒ unsink commits to fid, ONE SRC_NB_UNCOVER arm, _pending same frame")
	ring.free()

# ---------- G-APC-1 + G-APC-3: luxury rail (coalesce + credit gate) ----------
func _gate_luxury_rail(fid: int) -> void:
	print("  --- G-APC-1/3: luxury promotes ≤1×/window, only when credit ok + settled + rate-limited ---")
	var ring := _fresh_ring(fid)
	# G-APC-3: credit off ⇒ never promotes even when settled+rate-satisfied.
	ring.call("set_stream_credit_ok", false)
	ring.call("_arm_pending", FFR.SRC_CULL_APPLY, true)      # park a luxury arm
	var t0 := int(ring.get("_calm_last_lux_arm_ms"))
	var t_ok := t0 + CubeSphere.CALM_SETTLE_MS + CubeSphere.CALM_APPLY_MIN_MS + 1
	_ok(not bool(ring.call("_calm_try_promote_luxury", t_ok)) and not bool(ring.get("_pending")),
		"G-APC-3: credit OFF ⇒ a settled+rate-satisfied luxury arm does NOT promote")
	# flip credit on ⇒ the same instant promotes.
	ring.call("set_stream_credit_ok", true)
	_ok(bool(ring.call("_calm_try_promote_luxury", t_ok)) and bool(ring.get("_pending")),
		"G-APC-3: credit ON ⇒ the parked luxury arm promotes (settled + rate-limited)")

	# G-APC-1: re-park, then a second promote is rate-limited within the same window, allowed after it.
	ring.set("_pending", false)
	ring.call("_arm_pending", FFR.SRC_RELIEF, true)          # re-park (updates last_lux_arm_ms)
	_ok(not bool(ring.call("_calm_try_promote_luxury", t_ok + 5)),
		"G-APC-1: a second luxury arm is RATE-LIMITED within CALM_APPLY_MIN_MS of the last promotion")
	_ok(bool(ring.call("_calm_try_promote_luxury", t_ok + CubeSphere.CALM_APPLY_MIN_MS + 1)),
		"G-APC-1: it promotes once the rate window elapses (≤1 promotion/window)")

	# a not-yet-settled luxury arm (armed 'now', probed immediately) must not promote.
	ring.set("_pending", false)
	ring.call("_arm_pending", FFR.SRC_SMOOTH_CHG, true)
	var t_now := int(ring.get("_calm_last_lux_arm_ms"))
	_ok(not bool(ring.call("_calm_try_promote_luxury", t_now + 1)),
		"G-APC-1: an unsettled luxury arm (probed immediately) does not promote (settle gate)")
	ring.free()

# ---------- G-APC-7: flag-OFF parity (byte-off behaviour) ----------
func _gate_off_parity(fid: int) -> void:
	print("  --- G-APC-7: flag OFF ⇒ _arm_pending == shipped `_pending=true`; sensor empty; ladder shipped body ---")
	var ring := _fresh_ring(fid)
	# every arm — SAFETY or LUXURY tag — just sets _pending; the sensor is never allocated.
	ring.set("_pending", false)
	ring.call("_arm_pending", FFR.SRC_CULL_APPLY, true)     # a 'luxury' tag, but flag off ⇒ plain _pending
	_ok(bool(ring.get("_pending")), "G-APC-7: _arm_pending(luxury) sets _pending immediately with the flag off")
	_ok(not bool(ring.get("_pending_luxury")), "G-APC-7: no luxury rail state written with the flag off")
	var src: PackedInt32Array = ring.get("_pending_src")
	_ok(src.size() == 0, "G-APC-7: sensor _pending_src never allocated with the flag off (0 bytes)")
	ring.set("_pending", false)
	ring.call("_arm_pending", FFR.SRC_BOOT)
	_ok(bool(ring.get("_pending")), "G-APC-7: a SAFETY tag sets _pending with the flag off (shipped write)")
	# the luxury promoter is inert.
	_ok(not bool(ring.call("_calm_try_promote_luxury", 999999999)), "G-APC-7: _calm_try_promote_luxury is inert with the flag off")
	# the ladder runs the SHIPPED body: with a live cover it grows one step/tick and arms via _pending (not the sensor).
	ring.call("set_cover_query", Callable(self, "_cover_true"))
	ring.call("set_player_column", Vector3(FA.R_BLOCKS, 0.0, 0.0))
	ring.set("_pending", false)
	ring.call("_applied_probe_step", true, PROBE_PARAMS)
	_ok(float(ring.get("_applied_r")) > 0.0 and bool(ring.get("_pending")),
		"G-APC-7: shipped ladder body — one step grows _applied_r and sets _pending (per-step, as shipped)")
	ring.free()
