extends SceneTree
## COSMOS FALL-MESH-STALL / FALL C-lite gate — FP_REENTRY_BACKLOG_GATE + FP_REENTRY_REGROW_DEFER
## (docs/COSMOS-FALL-MESH-STALL-DESIGN.md §6 + docs/COSMOS-FALL-CLITE-DESIGN.md). Symptom: a de-orbit fall through
## alt ~870→450 collapses to fps ~2.5 for 20-25 s because the S1 approach-anchor re-growth law (FP_APPROACH_ANCHOR)
## re-grows the ground-pinned viewer 0→128 across that band and godot_voxel loads a full terrain-intersecting disc
## per growth step — a 6-7k GenerateBlock flood that starves the main thread (§1-§2). The two flags here gate the
## WRITTEN view growth. C-lite (arming rev 2) replaces the measured-dead `falling_fast` arming (the _fall_vy_ema
## EMA is speed-clamp frozen across the whole flood band) with a freeze-independent descent latch from Δ(radial
## altitude), and restructures the admit law: growth is ALWAYS step-clamped under the flag; the backlog HOLD applies
## only while descent-armed AND above h=128 (> 112 max terrain ⇒ a grounded player is structurally unwedgeable).
## Both default OFF ⇒ byte-identical (FLAT stays 6042/0).
##
## Two-layer pattern (as before):
##   • PURE MATH (flag-independent): the laws are pure statics on CubeSphere — reentry_admit_view (v2, 4-arg),
##     reentry_hold_view, reentry_descent_step — asserted directly PLUS via script-local mirrors (same body, the
##     FP_REENTRY_BACKLOG_GATE early-return removed) so the gated branches are exercised even with the const false.
##   • DRIVER (needs godot_voxel + FP_APPROACH_ANCHOR true): the OFF arm proves the flags-off write sequence is
##     byte-identical to the raw S1 law. Gracefully SKIPs otherwise.
##
## RUN — OFF arm (FACETED=true only): G-RP-LAW/DESCENT/DEFER/SWEEP/GROUNDED/REV (mirrors) + G-RP-OFF (driver).
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_reentry_pace.gd
## RUN — ON arm (FACETED + both flags true): additionally proves the real statics match the mirrors + REV==2.
##   sed -i 's/const FP_REENTRY_BACKLOG_GATE := false/const FP_REENTRY_BACKLOG_GATE := true/; s/const FP_REENTRY_REGROW_DEFER := false/const FP_REENTRY_REGROW_DEFER := true/' godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Script-local mirror of CubeSphere.reentry_admit_view v2 (§3.1) with the `FP_REENTRY_BACKLOG_GATE` early-return
## removed, so the gated branches (shrink verbatim / first-write / descent-armed backlog-hold / always step-clamp)
## are exercisable even with the const compiled false. Same consts, same body otherwise.
static func _mirror_admit(last_vd: int, want_vd: int, gen_backlog: int, descending: bool) -> int:
	if last_vd < 0 or want_vd <= last_vd:
		return want_vd
	if descending and gen_backlog > CubeSphere.REENTRY_GEN_BACKLOG_MAX:
		return last_vd
	return mini(want_vd, last_vd + CubeSphere.REENTRY_GROW_STEP)

## Script-local mirror of CubeSphere.reentry_hold_view (§3.2), same treatment; `descending` is the C-lite latch.
static func _mirror_hold(want_vd: float, alt: float, descending: bool) -> float:
	if not descending or alt <= CubeSphere.REENTRY_REGROW_DEFER_ALT:
		return want_vd
	return minf(want_vd, CubeSphere.REENTRY_HOLD_VIEW)

## Script-local mirror of the WIRING at world_manager.gd _apply_approach_anchor's backlog-gate call site (C-lite
## §5.2c): `if FP_REENTRY_BACKLOG_GATE: armed = descending and h > REENTRY_DESCENT_MIN_ALT; backlog = gen if armed
## else 0; near_vd = reentry_admit_view(last, want, backlog, armed)`. Uses the REAL compiled flag — it tests the
## call CONDITION + the h>128 structural floor, not the law body (which _mirror_admit covers).
static func _mirror_wired_near_vd(last_vd: int, want_vd: int, gen_backlog: int, descending: bool, h: float) -> int:
	if CubeSphere.FP_REENTRY_BACKLOG_GATE:
		var armed := descending and h > CubeSphere.REENTRY_DESCENT_MIN_ALT
		var bl := gen_backlog if armed else 0
		return CubeSphere.reentry_admit_view(last_vd, want_vd, bl, armed)
	return want_vd

## Radial altitude (blocks above the sphere) of a lattice point in facet `fid`'s frame — the WorldManager metric.
func _radial(fid: int, x: float, y: float, z: float) -> float:
	var w := FA.lattice_to_world64(fid, x, y, z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - FA.R_BLOCKS

func _initialize() -> void:
	print("=== verify_reentry_pace (FALL C-lite: G-RP-LAW/DESCENT/DEFER/SWEEP/GROUNDED/REV/OFF) ===")
	print("  flags: FP_REENTRY_BACKLOG_GATE=%s FP_REENTRY_REGROW_DEFER=%s FP_APPROACH_ANCHOR=%s FACETED=%s"
		% [str(CubeSphere.FP_REENTRY_BACKLOG_GATE), str(CubeSphere.FP_REENTRY_REGROW_DEFER),
		   str(CubeSphere.FP_APPROACH_ANCHOR), str(CubeSphere.FACETED)])
	print("  consts: GATE_REV=%d GEN_BACKLOG_MAX=%d GROW_STEP=%d REGROW_DEFER_ALT=%.0f HOLD_VIEW=%.0f VY_ON=%.0f VY_OFF=%.0f CALM_N=%d MIN_ALT=%.0f VY_CLAMP=%.0f"
		% [CubeSphere.REENTRY_GATE_REV, CubeSphere.REENTRY_GEN_BACKLOG_MAX, CubeSphere.REENTRY_GROW_STEP,
		   CubeSphere.REENTRY_REGROW_DEFER_ALT, CubeSphere.REENTRY_HOLD_VIEW, CubeSphere.REENTRY_DESCENT_VY_ON,
		   CubeSphere.REENTRY_DESCENT_VY_OFF, CubeSphere.REENTRY_DESCENT_CALM_N, CubeSphere.REENTRY_DESCENT_MIN_ALT,
		   CubeSphere.REENTRY_DESCENT_VY_CLAMP])
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return

	# G-RP-REV — the arming self-describes: rev 2 = the freeze-independent latch (rev 1 was the measured-dead
	# falling_fast keying). A served pck const dump / this gate's ON arm refuses to pass against a rev-1 build.
	_ok(CubeSphere.REENTRY_GATE_REV == 2, "G-RP-REV: REENTRY_GATE_REV == 2 (the C-lite freeze-independent descent arming; rev 1 = dead _fall_vy_ema)")

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-LAW — reentry_admit_view v2 (§3.1), via the flag-independent mirror. INLINE loops only.
	# ---------------------------------------------------------------------------------------------------------------
	var shrink_verbatim := true
	for i in range(0, 50):
		var last_vd := 50 + i
		var want_vd := last_vd - 1 - i               # always <= last_vd (a shrink or hold)
		for desc in [true, false]:
			if _mirror_admit(last_vd, want_vd, 999999, desc) != want_vd:   # huge backlog, either latch: shrink passes
				shrink_verbatim = false
	_ok(shrink_verbatim, "G-RP-LAW: shrink (want_vd <= last_vd) passes verbatim regardless of backlog OR descent latch")

	var first_write_passthrough := true
	for want in [0, 8, 64, 128, 5000]:
		for desc2 in [true, false]:
			if _mirror_admit(-1, want, 999999, desc2) != want:
				first_write_passthrough = false
	_ok(first_write_passthrough, "G-RP-LAW: last_vd == -1 (first write) passes want_vd through regardless of backlog/latch")

	var armed_gate_closed_holds := true
	for i in range(0, 30):
		var last_vd2 := 40 + i
		var r2 := _mirror_admit(last_vd2, last_vd2 + 20, CubeSphere.REENTRY_GEN_BACKLOG_MAX + 1 + i, true)  # descending
		if r2 != last_vd2:
			armed_gate_closed_holds = false
	_ok(armed_gate_closed_holds, "G-RP-LAW: DESCENT-ARMED + backlog > REENTRY_GEN_BACKLOG_MAX(%d) holds last_vd (no growth)" % CubeSphere.REENTRY_GEN_BACKLOG_MAX)

	# The C-lite no-wedge core: NOT descent-armed, growth is ALWAYS step-clamped — the backlog can HOLD nothing.
	# This is what makes a grounded player (whose latch is false and, structurally, h ≤ 112 < 128) unwedgeable at
	# the LAW level, independent of the wiring's h-floor.
	var unarmed_never_held := true
	for i in range(0, 30):
		var last_vd5 := 10 + i
		var r7 := _mirror_admit(last_vd5, last_vd5 + 500, CubeSphere.REENTRY_GEN_BACKLOG_MAX * 99, false)  # NOT descending, huge backlog
		if r7 != last_vd5 + CubeSphere.REENTRY_GROW_STEP:
			unarmed_never_held = false
	_ok(unarmed_never_held, "G-RP-LAW: NOT descent-armed ⇒ growth is ALWAYS +REENTRY_GROW_STEP(%d), never held, even at %dx the backlog cap (the no-wedge invariant)" % [CubeSphere.REENTRY_GROW_STEP, 99])

	var gate_open_step_clamped := true
	for i in range(0, 30):
		var last_vd3 := 10 + i
		var r3 := _mirror_admit(last_vd3, last_vd3 + 500, 0, true)   # armed, drained backlog ⇒ paced growth
		if r3 - last_vd3 != CubeSphere.REENTRY_GROW_STEP:
			gate_open_step_clamped = false
	_ok(gate_open_step_clamped, "G-RP-LAW: armed + drained backlog ⇒ growth clamped to exactly REENTRY_GROW_STEP(%d) per write, even for a huge want" % CubeSphere.REENTRY_GROW_STEP)

	var admit_monotone := true
	var prev_r := -1
	for want4 in range(0, 300, 5):
		var r4 := _mirror_admit(20, want4, 0, true)
		if r4 < prev_r:
			admit_monotone = false
		prev_r = r4
	_ok(admit_monotone, "G-RP-LAW: monotone non-decreasing in want_vd (armed, drained, fixed last_vd)")

	# Wrapper consistency: the REAL static must equal the mirror when the flag is compiled ON, and want_vd verbatim
	# when OFF — tying the const flag to the mirrored law body.
	if CubeSphere.FP_REENTRY_BACKLOG_GATE:
		var wrapper_matches_mirror := true
		for i in range(0, 40):
			var lv := 5 + i * 3
			var wv := lv + 40
			var bl := (i * 37) % (CubeSphere.REENTRY_GEN_BACKLOG_MAX * 2)
			for desc3 in [true, false]:
				if CubeSphere.reentry_admit_view(lv, wv, bl, desc3) != _mirror_admit(lv, wv, bl, desc3):
					wrapper_matches_mirror = false
		_ok(wrapper_matches_mirror, "G-RP-LAW(wrapper, flag ON): CubeSphere.reentry_admit_view matches the mirror across a swept table (both latch states)")
	else:
		var wrapper_passthrough := true
		for i in range(0, 40):
			var lv2 := 5 + i * 3
			var wv2 := lv2 + 40
			for desc4 in [true, false]:
				if CubeSphere.reentry_admit_view(lv2, wv2, CubeSphere.REENTRY_GEN_BACKLOG_MAX * 5, desc4) != wv2:
					wrapper_passthrough = false
		_ok(wrapper_passthrough, "G-RP-LAW(wrapper, flag OFF): CubeSphere.reentry_admit_view returns want_vd verbatim regardless of backlog/latch (byte-identical)")

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-DESCENT — reentry_descent_step (§3.3): the freeze-independent latch truth table. Pure static (no flag),
	# so both arms exercise it identically. INLINE.
	# ---------------------------------------------------------------------------------------------------------------
	# engage on a single write ≤ −VY_ON, from any prior state, resetting calm to 0.
	var engages := true
	for st in [false, true]:
		for cw in [0, 1, 2, 5]:
			var r: Array = CubeSphere.reentry_descent_step(-CubeSphere.REENTRY_DESCENT_VY_ON - 0.1, st, cw)
			if r[0] != true or r[1] != 0:
				engages = false
	# a write exactly at −VY_ON engages (≤).
	var r_edge: Array = CubeSphere.reentry_descent_step(-CubeSphere.REENTRY_DESCENT_VY_ON, false, 0)
	_ok(engages and r_edge[0] == true, "G-RP-DESCENT: vy ≤ −VY_ON(%.0f) engages the latch (calm→0) from any prior state" % CubeSphere.REENTRY_DESCENT_VY_ON)

	# dead zone (−VY_ON, −VY_OFF) holds the latch AND the calm counter unchanged (hysteresis).
	var deadzone_holds := true
	var mid := -(CubeSphere.REENTRY_DESCENT_VY_ON + CubeSphere.REENTRY_DESCENT_VY_OFF) * 0.5
	for st2 in [false, true]:
		for cw2 in [0, 2]:
			var rd: Array = CubeSphere.reentry_descent_step(mid, st2, cw2)
			if rd[0] != st2 or rd[1] != cw2:
				deadzone_holds = false
	_ok(deadzone_holds, "G-RP-DESCENT: dead zone (−VY_ON, −VY_OFF) keeps latch AND calm unchanged (Schmitt hysteresis)")

	# release ONLY after CALM_N consecutive calm (≥ −VY_OFF) writes; a calm run shorter than CALM_N does not release.
	# Feed calm (0 b/s) writes into an armed latch: it must stay latched for the first CALM_N-1 writes and release
	# exactly on the CALM_N-th.
	var releases_on_nth := false
	var no_early_release := true
	var latched := true
	var calm := 0
	for step_i in range(0, 10):
		var rr: Array = CubeSphere.reentry_descent_step(0.0, latched, calm)   # 0 b/s = calm (≥ −VY_OFF)
		latched = rr[0]
		calm = rr[1]
		if step_i < CubeSphere.REENTRY_DESCENT_CALM_N - 1 and latched == false:
			no_early_release = false                       # released too soon
		if step_i == CubeSphere.REENTRY_DESCENT_CALM_N - 1 and latched == false:
			releases_on_nth = true
	_ok(releases_on_nth and no_early_release, "G-RP-DESCENT: latch releases only ON the REENTRY_DESCENT_CALM_N(%d)-th consecutive calm write (never earlier)" % CubeSphere.REENTRY_DESCENT_CALM_N)

	# teleport/pause clamp: |vy| > VY_CLAMP keeps the latch+calm unchanged (relocation is not motion).
	var teleport_ignored := true
	for st3 in [false, true]:
		for cw3 in [0, 2]:
			for sgn in [1.0, -1.0]:
				var rt: Array = CubeSphere.reentry_descent_step(sgn * (CubeSphere.REENTRY_DESCENT_VY_CLAMP + 1.0), st3, cw3)
				if rt[0] != st3 or rt[1] != cw3:
					teleport_ignored = false
	_ok(teleport_ignored, "G-RP-DESCENT: |vy| > VY_CLAMP(%.0f) (teleport/pause) keeps latch+calm unchanged" % CubeSphere.REENTRY_DESCENT_VY_CLAMP)

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-GROUNDED (C-lite §2.3) — the structural grounded-safety: the wiring folds `h > REENTRY_DESCENT_MIN_ALT`
	# into `armed`, and MIN_ALT(128) > 112 max analytic terrain, so a grounded player (h ≤ ~114) can NEVER be
	# backlog-held — even with the latch spuriously true and the backlog far above the cap. Uses _mirror_wired_near_vd
	# (observes the REAL compiled flag). Growth is still step-clamped, so the assertion is "reaches full over writes,
	# never stuck at last_vd".
	# ---------------------------------------------------------------------------------------------------------------
	var huge_backlog := CubeSphere.REENTRY_GEN_BACKLOG_MAX * 50 + 10000
	var grounded_reaches_full := true
	for h_g in [0.0, 40.0, 80.0, 112.0, 114.0]:     # every reachable grounded altitude (≤ 112 max terrain + margin)
		var vd := 0
		var writes := 0
		while vd < 128 and writes < 64:
			vd = _mirror_wired_near_vd(vd, 128, huge_backlog, true, h_g)   # latch spuriously TRUE, huge backlog
			writes += 1
		if vd != 128:
			grounded_reaches_full = false
	_ok(grounded_reaches_full, "G-RP-GROUNDED: at every grounded altitude (h ≤ 114 < MIN_ALT 128), the wiring reaches full 128 despite latch=true and a backlog %dx the cap — structurally unwedgeable" % 50)

	# Contrast: high + descent-armed + saturated backlog DOES hold (the gate is genuinely doing something aloft).
	if CubeSphere.FP_REENTRY_BACKLOG_GATE:
		var high_armed_holds := false
		for i in range(0, 40):
			var lv6 := i
			var r8 := _mirror_wired_near_vd(lv6, 128, huge_backlog, true, 500.0)   # h=500 > 128, descending, saturated
			if r8 != 128:
				high_armed_holds = true
		_ok(high_armed_holds, "G-RP-GROUNDED: FALSIFY — at h=500 (aloft), descent-armed + saturated backlog (flag ON) DOES hold below full (the gate works where it should)")

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-DEFER — reentry_hold_view (§3.2), via the flag-independent mirror (param is now the C-lite `descending`).
	# ---------------------------------------------------------------------------------------------------------------
	var defer_alt := CubeSphere.REENTRY_REGROW_DEFER_ALT
	var hold_view := CubeSphere.REENTRY_HOLD_VIEW

	var clamps_when_descending_and_high := true
	for i in range(0, 40):
		var alt := defer_alt + 1.0 + float(i) * 20.0
		var want5 := hold_view + 10.0 + float(i)
		if not is_equal_approx(_mirror_hold(want5, alt, true), hold_view):
			clamps_when_descending_and_high = false
	_ok(clamps_when_descending_and_high, "G-RP-DEFER: descending AND alt > REGROW_DEFER_ALT(%.0f) ⇒ clamped to HOLD_VIEW(%.0f)" % [defer_alt, hold_view])

	var passthrough_when_not_descending := true
	for i in range(0, 40):
		var alt2 := defer_alt + 1.0 + float(i) * 20.0
		var want6 := hold_view + 10.0 + float(i)
		if not is_equal_approx(_mirror_hold(want6, alt2, false), want6):
			passthrough_when_not_descending = false
	_ok(passthrough_when_not_descending, "G-RP-DEFER: not descending (ascent/hover) ⇒ pass-through even high above REGROW_DEFER_ALT")

	var passthrough_when_low := true
	for i in range(0, 40):
		var alt3 := defer_alt - float(i)
		var want7 := hold_view + 10.0 + float(i)
		if not is_equal_approx(_mirror_hold(want7, alt3, true), want7):
			passthrough_when_low = false
	_ok(passthrough_when_low, "G-RP-DEFER: at/below REGROW_DEFER_ALT ⇒ pass-through even while descending (release ramp takes over)")

	var never_grows := true
	for i in range(0, 60):
		var alt4 := defer_alt - 100.0 + float(i) * 5.0
		for want8 in [0.0, 20.0, hold_view, hold_view + 50.0, 200.0]:
			for dsc in [true, false]:
				if _mirror_hold(want8, alt4, dsc) > want8 + 1.0e-6:
					never_grows = false
	_ok(never_grows, "G-RP-DEFER: the law only ever reduces want_vd, never grows it, across alt/descending combinations")

	if CubeSphere.FP_REENTRY_REGROW_DEFER:
		var wrapper_matches_mirror2 := true
		for i in range(0, 30):
			var altw := 100.0 + float(i) * 30.0
			for dscw in [true, false]:
				var w9 := 20.0 + float(i)
				if not is_equal_approx(CubeSphere.reentry_hold_view(w9, altw, dscw), _mirror_hold(w9, altw, dscw)):
					wrapper_matches_mirror2 = false
		_ok(wrapper_matches_mirror2, "G-RP-DEFER(wrapper, flag ON): CubeSphere.reentry_hold_view matches the mirror exactly")
	else:
		var wrapper_passthrough2 := true
		for i in range(0, 30):
			var altw2 := 100.0 + float(i) * 30.0
			var w10 := 20.0 + float(i)
			if not is_equal_approx(CubeSphere.reentry_hold_view(w10, altw2, true), w10):
				wrapper_passthrough2 = false
		_ok(wrapper_passthrough2, "G-RP-DEFER(wrapper, flag OFF): CubeSphere.reentry_hold_view returns want_vd verbatim (byte-identical)")

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-SWEEP — §3.3 composition, both laws via the mirrors: a simulated 38 b/s descent 2500→0 with a synthetic
	# generation-backlog model; the descent latch is armed throughout (a genuine fall). Now that growth is ALWAYS
	# step-clamped, the peak is bounded by cap + a couple of step-annuli regardless of the arming. INLINE.
	# ---------------------------------------------------------------------------------------------------------------
	var full := 128.0
	var re_lo := CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST
	var descent_speed := 38.0
	var drain_rate := 490.0
	const TASKS_PER_VD := 6800.0 / 128.0
	var dt := 0.1
	var t := 0.0
	var alt := 2500.0
	var admitted_vd := -1
	var backlog := 0.0
	var max_backlog := 0.0
	# drive the descent latch from Δalt too (proves the real latch stays armed on a 38 b/s fall).
	var sim_desc := false
	var sim_calm := 0
	var prev_alt := alt
	var step_annulus_tasks := float(CubeSphere.REENTRY_GROW_STEP) * TASKS_PER_VD
	while alt > 0.0:
		var vy_w := (alt - prev_alt) / dt
		prev_alt = alt
		var sr: Array = CubeSphere.reentry_descent_step(vy_w, sim_desc, sim_calm)
		sim_desc = sr[0]; sim_calm = sr[1]
		var want_raw := CubeSphere.approach_view_distance(alt, full, re_lo)
		var want_held := _mirror_hold(want_raw, alt, sim_desc)
		var want_vd11 := int(round(want_held))
		var admitted_next := _mirror_admit(admitted_vd, want_vd11, int(backlog), sim_desc)
		var issued := maxf(0.0, float(admitted_next - maxi(admitted_vd, 0))) * TASKS_PER_VD
		admitted_vd = admitted_next
		backlog = maxf(0.0, backlog + issued - drain_rate * dt)
		max_backlog = maxf(max_backlog, backlog)
		alt -= descent_speed * dt
		t += dt
	_ok(sim_desc, "G-RP-SWEEP: the descent latch stays ARMED across a simulated 38 b/s de-orbit (the arming is live, unlike the dead _fall_vy_ema)")
	# final settle: stationary catch-up to full (latch releases after CALM_N; growth still step-clamps).
	for _settle in range(0, 4000):
		if admitted_vd >= 128:
			break
		var sr2: Array = CubeSphere.reentry_descent_step(0.0, sim_desc, sim_calm)
		sim_desc = sr2[0]; sim_calm = sr2[1]
		var admitted_next2 := _mirror_admit(admitted_vd, 128, int(backlog), sim_desc)
		var issued2 := maxf(0.0, float(admitted_next2 - maxi(admitted_vd, 0))) * TASKS_PER_VD
		admitted_vd = admitted_next2
		backlog = maxf(0.0, backlog + issued2 - drain_rate * dt)
		max_backlog = maxf(max_backlog, backlog)
	var bound := float(CubeSphere.REENTRY_GEN_BACKLOG_MAX) + 2.0 * step_annulus_tasks
	_ok(max_backlog <= bound, "G-RP-SWEEP: simulated 38 b/s descent 2500→0 keeps modeled backlog (max %.0f) ≤ GEN_BACKLOG_MAX + 2 step-annuli (%.0f)" % [max_backlog, bound])
	_ok(admitted_vd >= 128, "G-RP-SWEEP: the admitted view still reaches full 128 by touchdown (settled at %d)" % admitted_vd)
	print("  G-RP-SWEEP: max_backlog=%.0f bound=%.0f admitted_at_alt0=%d fall_time=%.1fs" % [max_backlog, bound, admitted_vd, t])

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-TICK (adversarial-review Finding A, ON-arm only): execute the REAL runtime wrapper _reentry_descent_tick on
	# a live WorldManager with REAL elapsed wall-clock, so vy_w = Δh/Δt is computed from the clock exactly as in-game.
	# This is the class of coverage attempts #1/#2 LACKED — their wiring looked correct but the arming signal was
	# runtime-dead. Proves: first tick only baselines; a real-clock descent ARMS the latch; sustained calm RELEASES it.
	# Runs only with FP_REENTRY_BACKLOG_GATE ON (the tick is guarded off otherwise); needs FACETED (already asserted).
	# ---------------------------------------------------------------------------------------------------------------
	if CubeSphere.FP_REENTRY_BACKLOG_GATE:
		var wt := WorldManager.new(); wt.name = "ReentryTick"; get_root().add_child(wt)
		for _wf in range(2):
			await process_frame
		wt._reentry_descent_tick(2000.0)     # first call: baseline only, no rate
		_ok(not wt._reentry_descending and wt._reentry_prev_alt_ms >= 0, "G-RP-TICK: first tick samples the baseline only (no spurious arm)")
		var alt_t := 2000.0
		for _d in range(5):
			await create_timer(0.1).timeout
			alt_t -= 20.0                    # ~20 blk / ~0.1 s ⇒ vy_w ≈ −200 b/s (≤ −VY_ON, ≪ VY_CLAMP)
			wt._reentry_descent_tick(alt_t)
		_ok(wt._reentry_descending, "G-RP-TICK: a REAL-CLOCK descent (~−200 b/s via Δh/Δt) ARMS the latch — the runtime wrapper attempts #1/#2 never exercised (Finding A)")
		for _c in range(CubeSphere.REENTRY_DESCENT_CALM_N + 2):
			await create_timer(0.1).timeout
			wt._reentry_descent_tick(alt_t)  # constant h ⇒ Δh≈0 ⇒ calm
		_ok(not wt._reentry_descending, "G-RP-TICK: sustained calm (Δh≈0) RELEASES the latch (grounded un-arm at runtime)")
		wt.queue_free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-OFF — driver (needs godot_voxel + FP_APPROACH_ANCHOR true): both new flags OFF ⇒ the set_approach_anchor
	# write sequence is byte-identical to the raw S1 release law (no gating, no descent tick effect). SKIPs otherwise.
	# ---------------------------------------------------------------------------------------------------------------
	if CubeSphere.FP_REENTRY_BACKLOG_GATE or CubeSphere.FP_REENTRY_REGROW_DEFER:
		print("  SKIP(driver, G-RP-OFF): this check is specifically the OFF arm — the ON-arm wrapper-vs-mirror checks above cover the gated behaviour.")
	elif not CubeSphere.FP_APPROACH_ANCHOR:
		print("  SKIP(driver, G-RP-OFF): FP_APPROACH_ANCHOR is off — no anchor writes to record (pure-math + mirror layers stand).")
	elif not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP(driver, G-RP-OFF): godot_voxel module absent (no VoxelTerrain) — pure-math + mirror layers stand.")
	else:
		TC.warm_up()
		FA.warm_up()
		var A := FA.spawn_facet()
		TC.set_active_facet(A)
		var w := WorldManager.new(); w.name = "ReentryPace"; get_root().add_child(w)
		for _rf in range(4):
			await process_frame
		if not (w.using_module and w._module_world != null and w._module_world.has_method("set_approach_anchor")):
			print("  SKIP(driver, G-RP-OFF): module path not selected (using_module=%s)." % str(w.using_module))
		else:
			var cc := FA.centre_cell(A)
			var px := float(cc.x) + 0.5
			var pz := float(cc.y) + 0.5
			var player := Node3D.new(); player.name = "GatePlayer"
			get_root().add_child(player)
			player.global_position = Vector3(px, 6.0, pz)
			w.on_player_ready(player)

			var driver_matches_law := true
			var wrote_something := false
			for i in range(0, 121):
				var h := 1200.0 - float(i) * 10.0
				var pos := Vector3(px, h, pz)
				w.approach_anchor_step_now(pos)
				var applied_view := int(w._module_world.call("viewer_view_distance"))
				var full2 := float(TC.near_render_radius())
				var d_ref := maxf(_radial(A, px, h, pz), 0.0)
				var lo_ref := (CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST) if w._anchor_released else CubeSphere.ANCHOR_REL_LO
				var ref_view := int(round(CubeSphere.approach_view_distance(d_ref, full2, lo_ref)))
				if applied_view != ref_view:
					driver_matches_law = false
				if applied_view > 0:
					wrote_something = true
			_ok(wrote_something, "G-RP-OFF(driver): the anchor driver produced non-trivial writes across the descent sweep (sanity)")
			_ok(driver_matches_law, "G-RP-OFF(driver): both FP_REENTRY_* flags OFF ⇒ the applied view_distance sequence is byte-identical to the raw S1 release law (no gating)")

			player.queue_free(); w.queue_free()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
