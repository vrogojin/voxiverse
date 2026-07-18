extends SceneTree
## COSMOS SPACE-NAV SN5 gate — G-SN-DEVFLIGHT (docs/COSMOS-SPACE-NAV-DESIGN.md §7.2, §5.3, §10 SN5).
## Proves the DEV-FLIGHT velocity-command controller (CosmosDevFlight) end-to-end WITHOUT a live browser:
## a scripted sequence of camera-frame input + mode context is stepped through the FULL in-game flight path
## (input → controller → CosmosNav classify → position update), asserting the trajectory matches the per-mode
## spec. This is the phase's VALUE — the controller MATH is gateable; only the FEEL/LOOK is live-only.
##
## The controller kernel is an engine-free pure static (CosmosDevFlight / CosmosNav / OrbitalState /
## CosmosGravity), so this gate is FLAG-INDEPENDENT: it passes identically with SN_DEVNAV true or false (the
## controller is DEAD — never driven in-game — when the flag is off; the gate drives it directly). Byte-identity
## (flag-off == shipped) is the FLAT verify_feature (6035/0), run separately.
##
## Asserts (§10 SN5 (a)-(d)):
##   (a) FORWARD in LOW_ORBIT moves TANGENTIALLY at 0.25·v_circ(r): |v_bci| == 0.25·v_circ, v_bci ⊥ r̂.
##   (b) A SUSTAINED ASCENT triggers the mode transitions PLANETARY→LOW→HIGH→DEEP at the correct altitude bands
##       with the 2-s dwell/hysteresis honoured (committed sequence + transition radii in-band).
##   (c) SN-R1: velocity is CONTINUOUS (no jump) at EVERY tick including mode-flip ticks during powered flight —
##       |Δv_bci| ≤ DEV_ACCEL·dt at every tick, and the flip ticks are NOT special.
##   (d) PLANETARY zero-input hover tracks the surface rotation (v_bci == ω⃗×p, |v_fix| == 0); ORBITAL zero-input
##       hover station-keeps to the planet centre (v_bci == 0, position fixed).
##   (e) speed caps match the §7.2 table + the camera-frame → BCI wish composition.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_dev_flight.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const DEVF := preload("res://src/cosmos/cosmos_dev_flight.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _rel(a: float, b: float) -> float:
	var d := absf(b)
	if d < 1.0e-300:
		return absf(a - b)
	return absf(a - b) / d

func _name(m: int) -> String:
	return NAV.NAV_NAMES[m] if m >= 0 and m < NAV.NAV_NAMES.size() else "NONE"

func _initialize() -> void:
	print("=== verify_dev_flight (COSMOS SPACE-NAV SN5: G-SN-DEVFLIGHT — velocity-command controller) ===")
	print("  CubeSphere.SN_DEVNAV = %s (gate is flag-independent; controller is a pure static)" % str(CubeSphere.SN_DEVNAV))
	FacetAtlas.warm_up()                                    # r_vox(earth) reads FacetAtlas.R_BLOCKS
	_gate_forward_low()
	_gate_ascent_and_continuity()
	_gate_hover()
	_gate_caps_and_wish()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# The east-tangential unit direction at BCI position p (⊥ r̂, in the equatorial sense): normalize(ẑ × p̂).
func _tangential(p: PackedFloat64Array) -> PackedFloat64Array:
	var z := DV.v(0.0, 0.0, 1.0)
	var c := DV.v(z[1] * p[2] - z[2] * p[1], z[2] * p[0] - z[0] * p[2], z[0] * p[1] - z[1] * p[0])
	var l := DV.length(c)
	return DV.scale(c, 1.0 / l) if l > 0.0 else DV.v(0.0, 1.0, 0.0)

# The outward radial unit direction at p.
func _radial(p: PackedFloat64Array) -> PackedFloat64Array:
	var l := DV.length(p)
	return DV.scale(p, 1.0 / l) if l > 0.0 else DV.v(1.0, 0.0, 0.0)

# ---------- (a) FORWARD in LOW_ORBIT → tangential at 0.25·v_circ(r) ----------
func _gate_forward_low() -> void:
	print("  --- (a) forward in LOW_ORBIT: tangential flight at 0.25·v_circ ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	# Start at rest at r = 5R (outside the 4R vicinity, in the well below r_geo ⇒ LOW_ORBIT). Command FORWARD
	# (camera looking east ⇒ wish = tangential) and let the command ramp to the cap. Mode held LOW_ORBIT (the
	# scenario is "flying forward in low orbit"): drive the controller with a fixed mode, wish re-aimed each tick.
	var p := DV.v(5.0 * R, 0.0, 0.0)
	var v := DV.v(0.0, 0.0, 0.0)
	var dt := 1.0 / 60.0
	var t := 0.0
	for _i in range(400):
		var wish := _tangential(p)
		var cap := DEVF.speed_cap(NAV.LOW_ORBIT, body, p, t)
		var out := DEVF.step(NAV.LOW_ORBIT, body, p, v, t, dt, wish, cap)
		p = out[0]; v = out[1]; t += dt
	var v_circ := sqrt(GRAV.gm_dyn(body) / DV.length(p))
	var cap_final := DEVF.LOW_FRAC * v_circ
	_ok(_rel(DV.length(v), cap_final) < 1.0e-6, "(a): |v_bci| = %.4f == 0.25·v_circ = %.4f (converged to the cap)" % [DV.length(v), cap_final])
	# Tangential: v ⊥ r̂. The residual radial fraction is one tick of kinematic lag (v is aimed tangent to the
	# PREVIOUS position; the craft then moved tangentially, rotating r̂ by ~|v|·dt/r ≈ 3e-5), not an impulse.
	var radial_comp := absf(DV.dot(v, _radial(p)))
	_ok(radial_comp / DV.length(v) < 1.0e-3, "(a): v_bci ⊥ r̂ (radial fraction %s — tangential flight)" % [radial_comp / DV.length(v)])
	# It is genuinely classified LOW_ORBIT there (the scenario's premise is real, not forced).
	_ok(NAV.classify(body, p, v, t) == NAV.LOW_ORBIT, "(a): the state is genuinely LOW_ORBIT (classifier agrees)")

# ---------- (b) sustained ascent → mode transitions + (c) SN-R1 continuity ----------
# One powered radial climb from the surface drives BOTH: the committed mode sequence P→LOW→HIGH→DEEP with the
# transition altitude bands, AND the per-tick / flip-tick Δv bound (SN-R1 no-jerk during powered flight).
func _gate_ascent_and_continuity() -> void:
	print("  --- (b) ascent: P→LOW→HIGH→DEEP transitions + (c) SN-R1 velocity continuity ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var w := EPH.omega_spin(body)
	var dt := 1.0 / 60.0
	# Start resting on the surface (h≈50, inside the atmosphere band ⇒ PLANETARY) with v = ω⃗×p (surface rest).
	var p := DV.v(R + 50.0, 0.0, 0.0)
	var v := ORB.omega_cross(body, p)
	var ns := NAV.NavState.new()
	ns.mode = NAV.PLANETARY
	var t := 0.0

	var step_bound := DEVF.DEV_ACCEL * dt
	var worst_dv := 0.0             # max |Δv_bci| over ALL ticks (must be ≤ step_bound)
	var worst_flip_dv := 0.0        # max |Δv_bci| specifically at mode-flip ticks (must also be ≤ step_bound)
	var flips := 0
	var seq: Array = [ns.mode]
	var trans_r := {}               # mode → radius at which it was first committed (for the band check)

	var tick := 0
	while tick < 300000:
		var wish := _radial(p)                              # camera aimed radially outward, holding "forward"
		var mode := ns.mode                                 # the CURRENT committed mode drives the controller
		var cap := DEVF.speed_cap(mode, body, p, t, true)   # run = true (only matters for PLANETARY)
		var v_prev := PackedFloat64Array([v[0], v[1], v[2]])
		var out := DEVF.step(mode, body, p, v, t, dt, wish, cap)
		p = out[0]; v = out[1]
		var dv := DV.length(DV.sub(v, v_prev))
		worst_dv = maxf(worst_dv, dv)
		# Advance the machine AFTER the physical step (it only READS state; §5.4 theorem).
		var prev := ns.mode
		ns.tick(body, p, v, t, dt)
		if ns.mode != prev:
			flips += 1
			worst_flip_dv = maxf(worst_flip_dv, dv)         # the flip tick's own Δv — must not exceed the bound
			seq.append(ns.mode)
			if not trans_r.has(ns.mode):
				trans_r[ns.mode] = DV.length(p)
		if ns.mode == NAV.DEEP_SPACE:
			break
		t += dt
		tick += 1

	var names: Array = []
	for m in seq:
		names.append(_name(m))
	print("    committed mode sequence: %s   (flips=%d, ticks=%d)" % [str(names), flips, tick])
	# (b) the committed sequence is exactly the ascent ladder.
	var expected := [NAV.PLANETARY, NAV.LOW_ORBIT, NAV.HIGH_ORBIT, NAV.DEEP_SPACE]
	var seq_ok: bool = seq.size() == expected.size()
	if seq_ok:
		for i in range(expected.size()):
			if int(seq[i]) != expected[i]:
				seq_ok = false
	_ok(seq_ok, "(b): committed ascent sequence PLANETARY→LOW→HIGH→DEEP (dwell + hysteresis honoured)")
	# (b) the transition altitude bands (interim radii; ±hysteresis tolerance). LOW near the atmosphere top,
	# HIGH near r_geo (the low/high divide), DEEP near the 10R gravity-well edge.
	var r_geo := NAV.r_geo_dyn(body)
	var r_well := R / sqrt(NAV.GRAV_FRAC_MIN)               # γ = 0.01 ⟺ r = 10R
	if trans_r.has(NAV.LOW_ORBIT):
		# A leisurely dev-climb is SUB-ORBITAL in the vicinity, so it stays PLANETARY past the atmosphere top and
		# only becomes LOW when it turns super-suborbital (u ≥ 0.25) — anywhere ABOVE the atmosphere, within the
		# 4R vicinity (+hysteresis). That is the correct classifier semantics, not the atmosphere ceiling.
		var rl: float = trans_r[NAV.LOW_ORBIT]
		_ok(rl > R + NAV.h_atmo(body) and rl < NAV.VICINITY_R * R * 1.10,
			"(b): LOW commit at r=%.0f (h≈%.0f) above the atmosphere, within the 4R vicinity" % [rl, rl - R])
	if trans_r.has(NAV.HIGH_ORBIT):
		var rh: float = trans_r[NAV.HIGH_ORBIT]
		_ok(_rel(rh, r_geo) < 0.10, "(b): HIGH commit at r=%.0f near the geostationary divide r_geo=%.0f (±10%%)" % [rh, r_geo])
	if trans_r.has(NAV.DEEP_SPACE):
		var rd: float = trans_r[NAV.DEEP_SPACE]
		_ok(_rel(rd, r_well) < 0.10, "(b): DEEP commit at r=%.0f near the 10R gravity-well edge %.0f (±10%%)" % [rd, r_well])
	# (c) SN-R1: no impulse at ANY tick, and flip ticks are not special.
	_ok(flips >= 3, "(c): the ascent crossed ≥3 mode boundaries (P→LOW→HIGH→DEEP); flips=%d" % flips)
	_ok(worst_dv <= step_bound + 1.0e-9, "(c): |Δv_bci| ≤ DEV_ACCEL·dt at EVERY tick (worst=%.6f, bound=%.6f)" % [worst_dv, step_bound])
	_ok(worst_flip_dv <= step_bound + 1.0e-9, "(c): flip-tick |Δv_bci| ≤ bound too (worst flip=%.6f, bound=%.6f) — no jerk at a mode flip" % [worst_flip_dv, step_bound])

# ---------- (d) zero-input hover: planetary tracks ω⃗×p, orbital station-keeps ----------
func _gate_hover() -> void:
	print("  --- (d) zero-input hover: planetary tracks surface, orbital station-keeps ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var dt := 1.0 / 60.0

	# PLANETARY hover: start resting on the surface (v = ω⃗×p). Zero input ⇒ the command decays to 0 ⇒ the
	# physical velocity is the carrier ω⃗×p every tick ⇒ the body-fixed velocity is 0 (co-rotates with the surface).
	var r0 := R + 100.0
	var pp := DV.v(r0, 0.0, 0.0)
	var pv := ORB.omega_cross(body, pp)
	var t := 0.0
	var worst_fix := 0.0
	var worst_carrier := 0.0
	for _i in range(240):
		var out := DEVF.step(NAV.PLANETARY, body, pp, pv, t, dt, DV.v(0.0, 0.0, 0.0), 0.0)
		pp = out[0]; pv = out[1]; t += dt
		var carrier := ORB.omega_cross(body, pp)
		worst_carrier = maxf(worst_carrier, DV.length(DV.sub(pv, carrier)))
		var v_fix: PackedFloat64Array = ORB.bci_to_fixed(body, t, pp, pv)[1]
		worst_fix = maxf(worst_fix, DV.length(v_fix))
	# The residual is EXACTLY the forward-Euler co-rotation lag: v is set from carrier(p_prev), read against
	# carrier(p_new); the surface turned by ω·dt in between ⇒ dev ≈ ω²·r·dt (~1.4 mm/s here). Not an impulse —
	# it does not accumulate (a steady, tiny slip). Assert it is bounded by that physical lag, not 1e-9.
	var w := EPH.omega_spin(body)
	var euler_lag := w * w * r0 * dt
	_ok(worst_carrier < 1.5 * euler_lag, "(d): PLANETARY hover v_bci == ω⃗×p to the Euler lag ω²·r·dt (dev %s < %s — tracks the spinning surface)" % [worst_carrier, 1.5 * euler_lag])
	_ok(worst_fix < 1.5 * euler_lag, "(d): PLANETARY hover |v_fix| ≈ 0 (%s < %s — stationary ON the surface to integration precision)" % [worst_fix, 1.5 * euler_lag])

	# ORBITAL hover: start at rest at r = 5R (LOW_ORBIT). Zero input ⇒ carrier = 0 ⇒ v_bci = 0 ⇒ the position is
	# FIXED in the planet-centred inertial frame (station-keeps to the planet centre, not the rotating surface).
	var op := DV.v(5.0 * R, 0.0, 0.0)
	var op0 := PackedFloat64Array([op[0], op[1], op[2]])
	var ov := DV.v(0.0, 0.0, 0.0)
	t = 0.0
	var worst_speed := 0.0
	var worst_drift := 0.0
	for _i in range(240):
		var out := DEVF.step(NAV.LOW_ORBIT, body, op, ov, t, dt, DV.v(0.0, 0.0, 0.0), 0.0)
		op = out[0]; ov = out[1]; t += dt
		worst_speed = maxf(worst_speed, DV.length(ov))
		worst_drift = maxf(worst_drift, DV.length(DV.sub(op, op0)))
	_ok(worst_speed < 1.0e-12, "(d): ORBITAL hover |v_bci| == 0 (max %s — station-keeps to the planet centre)" % worst_speed)
	_ok(worst_drift < 1.0e-12, "(d): ORBITAL hover position fixed in BCI (max drift %s)" % worst_drift)

# ---------- (e) speed caps (§7.2 table) + the camera-frame → BCI wish composition ----------
func _gate_caps_and_wish() -> void:
	print("  --- (e) §7.2 speed caps + camera→BCI wish composition ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var t := 0.0
	# PLANETARY: shipped fly 16 / 32 (run).
	var ps := DV.v(R, 0.0, 0.0)
	_ok(DEVF.speed_cap(NAV.PLANETARY, body, ps, t, false) == 16.0, "(e): PLANETARY cap = 16 (shipped fly)")
	_ok(DEVF.speed_cap(NAV.PLANETARY, body, ps, t, true) == 32.0, "(e): PLANETARY cap = 32 (running)")
	# LOW_ORBIT: 0.25·v_circ(r).
	var r_low := 5.0 * R
	var pl := DV.v(r_low, 0.0, 0.0)
	_ok(_rel(DEVF.speed_cap(NAV.LOW_ORBIT, body, pl, t), 0.25 * sqrt(GRAV.gm_dyn(body) / r_low)) < 1.0e-12,
		"(e): LOW_ORBIT cap = 0.25·v_circ(r)")
	# HIGH_ORBIT: 0.25·v_circ(r), floored at 50. Far out (r large) the floor binds; near r_geo it does not.
	var r_far := 100.0 * R
	var pf := DV.v(r_far, 0.0, 0.0)
	_ok(DEVF.speed_cap(NAV.HIGH_ORBIT, body, pf, t) == DEVF.HIGH_ORBIT_FLOOR, "(e): HIGH_ORBIT cap floored at 50 far out")
	# At the interim scale HIGH_ORBIT lives at r ≥ r_geo where 0.25·v_circ ≈ 27 < 50, so the floor binds across
	# the whole HIGH regime — assert the general max(floor, 0.25·v_circ) formula (here == floor at r_geo).
	var r_geo := NAV.r_geo_dyn(body)
	var pg := DV.v(r_geo, 0.0, 0.0)
	_ok(_rel(DEVF.speed_cap(NAV.HIGH_ORBIT, body, pg, t), maxf(DEVF.HIGH_ORBIT_FLOOR, 0.25 * sqrt(GRAV.gm_dyn(body) / r_geo))) < 1.0e-12,
		"(e): HIGH_ORBIT cap = max(50, 0.25·v_circ(r_geo)) = %.1f (floor binds at interim scale)" % DEVF.speed_cap(NAV.HIGH_ORBIT, body, pg, t))
	# DEEP_SPACE: 0.25·v_sol at the heliocentric radius (~536 b/s near Earth). Build a BCI point near Earth.
	var pd := DV.v(6.0 * R, 0.0, 0.0)
	var p_hel := DV.add(pd, EPH.body_pos_helio(body, t))
	var v_sol := sqrt(EPH.gm_game("sun") / DV.length(p_hel))
	_ok(_rel(DEVF.speed_cap(NAV.DEEP_SPACE, body, pd, t), 0.25 * v_sol) < 1.0e-12, "(e): DEEP_SPACE cap = 0.25·v_sol(r_helio) = %.1f" % (0.25 * v_sol))
	# INTERSTELLAR: the const authority.
	_ok(DEVF.speed_cap(NAV.INTERSTELLAR, body, ps, t) == DEVF.SN_DEV_V_MAX, "(e): INTERSTELLAR cap = SN_DEV_V_MAX (10000)")

	# Camera→BCI wish composition: with a standard camera basis (x=right, y=up, z=back), FORWARD (wish_local
	# z=−1) yields −cam_z = the look direction. Aim the camera along +X (cam_z = −X) ⇒ forward wish = +X.
	var cam_x := DV.v(0.0, 0.0, 1.0)     # right
	var cam_y := DV.v(0.0, 1.0, 0.0)     # up
	var cam_z := DV.v(-1.0, 0.0, 0.0)    # back (look is −cam_z = +X)
	var fwd := DEVF.wish_dir(cam_x, cam_y, cam_z, Vector3(0, 0, -1))
	_ok(_rel(fwd[0], 1.0) < 1.0e-12 and absf(fwd[1]) < 1.0e-12 and absf(fwd[2]) < 1.0e-12, "(e): camera FORWARD → +X BCI (−cam_z)")
	# Up (Space) → +Y; zero input → zero vector.
	var up := DEVF.wish_dir(cam_x, cam_y, cam_z, Vector3(0, 1, 0))
	_ok(_rel(up[1], 1.0) < 1.0e-12, "(e): camera UP → +Y BCI (cam_y)")
	var none := DEVF.wish_dir(cam_x, cam_y, cam_z, Vector3.ZERO)
	_ok(DV.length(none) == 0.0, "(e): zero input → zero wish (hover)")
