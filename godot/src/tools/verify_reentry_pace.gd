extends SceneTree
## COSMOS FALL-MESH-STALL gate — FP_REENTRY_BACKLOG_GATE + FP_REENTRY_REGROW_DEFER
## (docs/COSMOS-FALL-MESH-STALL-DESIGN.md §6). Symptom: a de-orbit fall through alt ~870→450 collapses to fps ~2.5
## for 20-25 s because the S1 approach-anchor re-growth law (FP_APPROACH_ANCHOR) re-grows the ground-pinned viewer
## 0→128 across that band and godot_voxel loads a full terrain-intersecting disc per growth step — a 6-7k
## GenerateBlock flood that starves the main thread (§1-§2). The two flags here gate the WRITTEN view growth: by
## the live generation backlog (§3.1, closed-loop — never time/rate) and by deferring early re-growth to the proven
## landing disc while plunging fast (§3.2). Both default OFF ⇒ byte-identical (FLAT stays 6042/0).
##
## Modeled on verify_approach_anchor.gd's two-layer pattern:
##   • PURE MATH (flag-independent, always runs): the two laws are pure statics on CubeSphere, asserted directly,
##     PLUS "script-local mirror" reimplementations (same body, gate-check removed) so the gated BRANCHES (gate-open/
##     gate-closed/step-clamp/defer-clamp) are exercised even when the const flags are compiled false — the const
##     itself can only be flipped by a sed+re-import, not at runtime (the verify pattern for const flags).
##   • DRIVER (needs the godot_voxel module + FP_APPROACH_ANCHOR compiled true): proves the wiring in
##     WorldManager._apply_approach_anchor produces a set_approach_anchor write sequence consistent with the pure
##     laws. Gracefully SKIPs (not a failure) when FP_APPROACH_ANCHOR is off or the module is absent — the pure-math
##     + mirror layers below fully pin the two laws regardless.
##
## RUN — OFF arm (FACETED=true only; FP_REENTRY_* stay false): proves G-RP-LAW/-DEFER/-SWEEP (mirror-based, always
## exercise the gated branches) + G-RP-OFF (real statics verbatim pass-through).
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_reentry_pace.gd
## RUN — ON arm (FACETED + both flags true): additionally proves the real statics MATCH the mirrors (the flag wiring
## itself, not just the law bodies).
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

## Script-local mirror of CubeSphere.reentry_admit_view (§3.1) with the `FP_REENTRY_BACKLOG_GATE` early-return
## removed, so the gated branches (gate-open growth / gate-closed hold / step-clamp) are exercisable even with the
## const compiled false. Same consts, same body otherwise — the ONLY difference from the real static is the missing
## flag check, which is exactly what the wrapper-consistency checks below re-add.
static func _mirror_admit(last_vd: int, want_vd: int, gen_backlog: int) -> int:
	if last_vd < 0 or want_vd <= last_vd:
		return want_vd
	if gen_backlog > CubeSphere.REENTRY_GEN_BACKLOG_MAX:
		return last_vd
	return mini(want_vd, last_vd + CubeSphere.REENTRY_GROW_STEP)

## Script-local mirror of CubeSphere.reentry_hold_view (§3.2), same treatment.
static func _mirror_hold(want_vd: float, alt: float, falling_fast: bool) -> float:
	if not falling_fast or alt <= CubeSphere.REENTRY_REGROW_DEFER_ALT:
		return want_vd
	return minf(want_vd, CubeSphere.REENTRY_HOLD_VIEW)

## Radial altitude (blocks above the sphere) of a lattice point in facet `fid`'s frame — the WorldManager metric
## (== _radial_altitude_lattice), mirrored from verify_approach_anchor.gd so the G-RP-OFF reference matches the
## driver's actual input to the tolerance the round() comparison needs (exact at the facet centre axis).
func _radial(fid: int, x: float, y: float, z: float) -> float:
	var w := FA.lattice_to_world64(fid, x, y, z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - FA.R_BLOCKS

func _initialize() -> void:
	print("=== verify_reentry_pace (FALL-MESH-STALL: G-RP-LAW/DEFER/SWEEP/OFF) ===")
	print("  flags: FP_REENTRY_BACKLOG_GATE=%s FP_REENTRY_REGROW_DEFER=%s FP_APPROACH_ANCHOR=%s FACETED=%s"
		% [str(CubeSphere.FP_REENTRY_BACKLOG_GATE), str(CubeSphere.FP_REENTRY_REGROW_DEFER),
		   str(CubeSphere.FP_APPROACH_ANCHOR), str(CubeSphere.FACETED)])
	print("  consts: GEN_BACKLOG_MAX=%d GROW_STEP=%d REGROW_DEFER_ALT=%.0f HOLD_VIEW=%.0f ENV_FALL_HOLD_VY=%.1f"
		% [CubeSphere.REENTRY_GEN_BACKLOG_MAX, CubeSphere.REENTRY_GROW_STEP, CubeSphere.REENTRY_REGROW_DEFER_ALT,
		   CubeSphere.REENTRY_HOLD_VIEW, CubeSphere.ENV_FALL_HOLD_VY])
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-LAW — reentry_admit_view (§3.1), via the flag-independent mirror. INLINE loops only.
	# ---------------------------------------------------------------------------------------------------------------
	var shrink_verbatim := true
	for i in range(0, 50):
		var last_vd := 50 + i
		var want_vd := last_vd - 1 - i               # always <= last_vd (a shrink or hold)
		var r := _mirror_admit(last_vd, want_vd, 999999)   # even with a huge backlog, shrink must pass
		if r != want_vd:
			shrink_verbatim = false
	_ok(shrink_verbatim, "G-RP-LAW: shrink (want_vd <= last_vd) passes verbatim regardless of backlog")

	var first_write_passthrough := true
	for want in [0, 8, 64, 128, 5000]:
		if _mirror_admit(-1, want, 999999) != want:
			first_write_passthrough = false
	_ok(first_write_passthrough, "G-RP-LAW: last_vd == -1 (first write) passes want_vd through regardless of backlog")

	var gate_closed_holds := true
	for i in range(0, 30):
		var last_vd2 := 40 + i
		var r2 := _mirror_admit(last_vd2, last_vd2 + 20, CubeSphere.REENTRY_GEN_BACKLOG_MAX + 1 + i)
		if r2 != last_vd2:
			gate_closed_holds = false
	_ok(gate_closed_holds, "G-RP-LAW: backlog > REENTRY_GEN_BACKLOG_MAX(%d) holds last_vd (no growth admitted)" % CubeSphere.REENTRY_GEN_BACKLOG_MAX)

	var gate_open_step_clamped := true
	var one_shell_bound := true
	for i in range(0, 30):
		var last_vd3 := 10 + i
		var want3 := last_vd3 + 500                  # a huge want — must still clamp to one step
		var r3 := _mirror_admit(last_vd3, want3, 0)   # drained backlog ⇒ gate open
		var grown := r3 - last_vd3
		if grown != CubeSphere.REENTRY_GROW_STEP:
			gate_open_step_clamped = false
		if grown > CubeSphere.REENTRY_GROW_STEP:
			one_shell_bound = false
	_ok(gate_open_step_clamped and one_shell_bound, "G-RP-LAW: gate-open growth is clamped to exactly REENTRY_GROW_STEP(%d) per admitted write, even for a huge want_vd" % CubeSphere.REENTRY_GROW_STEP)

	var admit_monotone := true
	var prev_r := -1
	for want4 in range(0, 300, 5):
		var r4 := _mirror_admit(20, want4, 0)
		if r4 < prev_r:
			admit_monotone = false
		prev_r = r4
	_ok(admit_monotone, "G-RP-LAW: monotone non-decreasing in want_vd (gate-open, fixed last_vd/backlog)")

	# Wrapper consistency: the REAL static must equal the mirror when the flag is compiled ON, and must equal
	# want_vd verbatim (ignoring last_vd/backlog entirely) when compiled OFF — this is what ties the const flag to
	# the mirrored law body, on top of the branch coverage above.
	if CubeSphere.FP_REENTRY_BACKLOG_GATE:
		var wrapper_matches_mirror := true
		for i in range(0, 40):
			var lv := 5 + i * 3
			var wv := lv + 40
			var bl := (i * 37) % (CubeSphere.REENTRY_GEN_BACKLOG_MAX * 2)
			if CubeSphere.reentry_admit_view(lv, wv, bl) != _mirror_admit(lv, wv, bl):
				wrapper_matches_mirror = false
		_ok(wrapper_matches_mirror, "G-RP-LAW(wrapper, flag ON): CubeSphere.reentry_admit_view matches the mirror exactly across a swept table")
	else:
		var wrapper_passthrough := true
		for i in range(0, 40):
			var lv2 := 5 + i * 3
			var wv2 := lv2 + 40
			if CubeSphere.reentry_admit_view(lv2, wv2, CubeSphere.REENTRY_GEN_BACKLOG_MAX * 5) != wv2:
				wrapper_passthrough = false
		_ok(wrapper_passthrough, "G-RP-LAW(wrapper, flag OFF): CubeSphere.reentry_admit_view returns want_vd verbatim regardless of backlog (byte-identical)")

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-DEFER — reentry_hold_view (§3.2), via the flag-independent mirror.
	# ---------------------------------------------------------------------------------------------------------------
	var defer_alt := CubeSphere.REENTRY_REGROW_DEFER_ALT
	var hold_view := CubeSphere.REENTRY_HOLD_VIEW

	var clamps_when_fast_and_high := true
	for i in range(0, 40):
		var alt := defer_alt + 1.0 + float(i) * 20.0     # strictly above the defer altitude
		var want5 := hold_view + 10.0 + float(i)         # always wants more than the held disc
		if not is_equal_approx(_mirror_hold(want5, alt, true), hold_view):
			clamps_when_fast_and_high = false
	_ok(clamps_when_fast_and_high, "G-RP-DEFER: falling_fast AND alt > REGROW_DEFER_ALT(%.0f) ⇒ clamped to HOLD_VIEW(%.0f)" % [defer_alt, hold_view])

	var passthrough_when_slow := true
	for i in range(0, 40):
		var alt2 := defer_alt + 1.0 + float(i) * 20.0
		var want6 := hold_view + 10.0 + float(i)
		if not is_equal_approx(_mirror_hold(want6, alt2, false), want6):
			passthrough_when_slow = false
	_ok(passthrough_when_slow, "G-RP-DEFER: slow descent (falling_fast == false) ⇒ pass-through even high above REGROW_DEFER_ALT")

	var passthrough_when_low := true
	for i in range(0, 40):
		var alt3 := defer_alt - float(i)                 # at/below the defer altitude
		var want7 := hold_view + 10.0 + float(i)
		if not is_equal_approx(_mirror_hold(want7, alt3, true), want7):
			passthrough_when_low = false
	_ok(passthrough_when_low, "G-RP-DEFER: at/below REGROW_DEFER_ALT ⇒ pass-through even while falling fast (release ramp takes over)")

	var never_grows := true       # the clamp can only ever REDUCE want_vd, never increase it
	for i in range(0, 60):
		var alt4 := defer_alt - 100.0 + float(i) * 5.0
		for want8 in [0.0, 20.0, hold_view, hold_view + 50.0, 200.0]:
			for ff in [true, false]:
				if _mirror_hold(want8, alt4, ff) > want8 + 1.0e-6:
					never_grows = false
	_ok(never_grows, "G-RP-DEFER: the law only ever reduces want_vd, never grows it, across alt/falling_fast combinations")

	if CubeSphere.FP_REENTRY_REGROW_DEFER:
		var wrapper_matches_mirror2 := true
		for i in range(0, 30):
			var altw := 100.0 + float(i) * 30.0
			for ffw in [true, false]:
				var w9 := 20.0 + float(i)
				if not is_equal_approx(CubeSphere.reentry_hold_view(w9, altw, ffw), _mirror_hold(w9, altw, ffw)):
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
	# G-RP-SWEEP — §3.3 composition, both laws forced on via the mirrors: a simulated 38 b/s descent 2500→0 with a
	# synthetic generation-backlog model (issued − 490·t, floored 0). TASKS_PER_VD ≈ 6800/128 (§0 peak/full ratio) is
	# the synthetic tasks-issued-per-view-unit-grown scale; the drain rate (490 blocks/s) is §1's measured throughput.
	# INLINE loop only.
	# ---------------------------------------------------------------------------------------------------------------
	var full := 128.0
	var re_lo := CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST     # the descent re-grow knee (~609)
	var descent_speed := 38.0          # b/s, the doc's fast-end drag-limited descent
	var drain_rate := 490.0            # blocks/s measured engine throughput (§1)
	const TASKS_PER_VD := 6800.0 / 128.0
	var dt := 0.1
	var t := 0.0
	var alt := 2500.0
	var admitted_vd := -1
	var backlog := 0.0
	var max_backlog := 0.0
	var step_annulus_tasks := float(CubeSphere.REENTRY_GROW_STEP) * TASKS_PER_VD
	while alt > 0.0:
		var want_raw := CubeSphere.approach_view_distance(alt, full, re_lo)
		var want_held := _mirror_hold(want_raw, alt, true)     # falling_fast == true throughout (38 b/s >> ENV_FALL_HOLD_VY)
		var want_vd11 := int(round(want_held))
		var admitted_next := _mirror_admit(admitted_vd, want_vd11, int(backlog))
		var issued := maxf(0.0, float(admitted_next - maxi(admitted_vd, 0))) * TASKS_PER_VD
		admitted_vd = admitted_next
		backlog = maxf(0.0, backlog + issued - drain_rate * dt)
		max_backlog = maxf(max_backlog, backlog)
		alt -= descent_speed * dt
		t += dt
	# final settle: let the (now stationary) admitted view catch up to the full landing want, same closed loop.
	for _settle in range(0, 4000):
		if admitted_vd >= 128:
			break
		var admitted_next2 := _mirror_admit(admitted_vd, 128, int(backlog))
		var issued2 := maxf(0.0, float(admitted_next2 - maxi(admitted_vd, 0))) * TASKS_PER_VD
		admitted_vd = admitted_next2
		backlog = maxf(0.0, backlog + issued2 - drain_rate * dt)
		max_backlog = maxf(max_backlog, backlog)
	var bound := float(CubeSphere.REENTRY_GEN_BACKLOG_MAX) + 2.0 * step_annulus_tasks
	_ok(max_backlog <= bound, "G-RP-SWEEP: simulated 38 b/s descent 2500→0 keeps modeled backlog (max %.0f) ≤ GEN_BACKLOG_MAX + 2 step-annuli (%.0f)" % [max_backlog, bound])
	_ok(admitted_vd >= 128, "G-RP-SWEEP: the admitted view still reaches full 128 by touchdown (settled at %d)" % admitted_vd)
	print("  G-RP-SWEEP: max_backlog=%.0f bound=%.0f admitted_at_alt0=%d fall_time=%.1fs" % [max_backlog, bound, admitted_vd, t])

	# ---------------------------------------------------------------------------------------------------------------
	# G-RP-OFF — driver (needs the godot_voxel module + FP_APPROACH_ANCHOR compiled true): the two new flags being
	# OFF must not change the set_approach_anchor write sequence WorldManager._apply_approach_anchor produces —
	# i.e. the recorded (offset_y, near_vd) sequence across an altitude sweep matches the raw approach_view_distance
	# law with no gating applied. Gracefully SKIPs (not a failure) when FP_APPROACH_ANCHOR is off or the module is
	# absent — the pure-math + mirror layers above already fully pin both laws.
	# ---------------------------------------------------------------------------------------------------------------
	if CubeSphere.FP_REENTRY_BACKLOG_GATE or CubeSphere.FP_REENTRY_REGROW_DEFER:
		print("  SKIP(driver, G-RP-OFF): this check is specifically the OFF arm (both FP_REENTRY_* compiled false) — the ON-arm wrapper-vs-mirror checks above already cover the gated behaviour.")
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
				var h := 1200.0 - float(i) * 10.0        # descend 1200 → 0, matching the doc's descent direction
				var pos := Vector3(px, h, pz)
				w.approach_anchor_step_now(pos)
				var applied_view := int(w._module_world.call("viewer_view_distance"))
				var full2 := float(TC.near_render_radius())
				# reference: the raw S1 law, no FP_REENTRY_* gating applied (both flags are compiled off here).
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
