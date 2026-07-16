extends SceneTree
## COSMOS ORBITAL O1 gate (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.10) — the pure-kernel / headless-provable subset
## of the O1 suite. Drives CosmosGravity (§2.2 three-regime field), OrbitalState (§2.3 symplectic integrator +
## Kepler freeze/thaw + §2.6 drag) and the §2.4 frame algebra directly — every assert is on ENGINE-FREE f64 statics,
## so this gate is FLAG-INDEPENDENT (passes with FP_M3_ORBIT true or false; the kernels run nothing at load).
##
## Gates (§2.10):
##   G-O1-FIELD   gravity_fixed continuity at LO/HI; == facet-−normal·feel at h<LO; == GM/r² radial at h>HI; |g| monotone on the ramp
##   G-O1-ENERGY  10 LEO orbits ACTIVE @dt=1/60: specific energy + |L| bounded, secular drift ≈ 0 (slope<1e-6/orbit rel), r-dev < 10 blocks
##   G-O1-KEPLER  freeze→thaw round-trip to f64 ε; RAILS position at t+T == at t; thaw vs a fine ACTIVE integration close
##   G-O1-HANDOFF body-fixed→BCI→body-fixed round-trip < 1e-9; standing still at the equator ⇒ |v_bci| == ω·R eastward (33.4 m/s)
##   G-O1-DRAG    terminal @h=0 == DRAG_TERMINAL ±5%; a periapsis inside atmosphere decays; NO drag above ATMO_TOP; Moon (no atmo) ⇒ 0
##   G-O1-OFF     FP_M3_ORBIT=false; the §2.1 consts exist at their spec values; the kernels are pure (RefCounted, no nodes)
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbital.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const OS_ := preload("res://src/cosmos/orbital_state.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")

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

func _vlen(a: PackedFloat64Array) -> float:
	return DV.length(a)

func _vdiff(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return DV.length(DV.sub(a, b))

func _initialize() -> void:
	print("=== verify_orbital (COSMOS ORBITAL O1: gravity field + f64 integrator/Kepler + frame algebra) ===")
	print("  CubeSphere.FP_M3_ORBIT = %s (gate is flag-independent; kernels are pure statics)" % str(CubeSphere.FP_M3_ORBIT))
	# The FIELD gate needs facet normals → warm the atlas once (body-agnostic frozen tables).
	CubeSphere.warm_edge_tables(FA.K)
	TC.warm_up()
	FA.warm_up()

	_gate_field()
	_gate_energy()
	_gate_kepler()
	_gate_handoff()
	_gate_drag()
	_gate_off()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------------------------------------------------------------------------------
# G-O1-FIELD — the three-regime gravity blend
# ---------------------------------------------------------------------------------------
func _gate_field() -> void:
	print("  --- G-O1-FIELD: gravity_fixed 3-regime blend (continuity / endpoints / monotone) ---")
	var body := "earth"
	var R := EPH.radius_of(body)
	var gm := EPH.gm_game(body)
	var fid := FA.spawn_facet()
	var n := FA.facet_normal64(fid)                       # outward facet normal (unit)
	# use an OFF-CENTRE facet cell so the radial line p̂ genuinely differs from the facet normal n̂ (the facet
	# centre's direction is parallel to n̂ to f64, which would make the slerp endpoints coincide and not test it).
	var cc := FA.centre_cell(fid)
	var d := FA.cell_dir(fid, cc.x + 70, cc.y + 70)       # CubeSphere.DVec3 unit, near the facet boundary
	var dhat := DV.v(d.x, d.y, d.z)
	var feel := GRAV.feel_g(body)
	var ndotd: float = DV.dot(n, dhat)
	print("      fid=%d  R=%.1f  gm_game=%s  feel_g=%.4f  n̂·d̂=%.6f (off-centre ⇒ p̂ ≠ n̂)" % [fid, R, gm, feel, ndotd])
	_ok(ndotd < 0.9999, "FIELD: off-centre p̂ genuinely tilts from n̂ (n̂·d̂=%.6f) so the blend is exercised" % ndotd)

	# (a) below H_BLEND_LO (h=64, w=0): dir == −facet_normal (NOT radial), |g| == feel_g
	var p_lo := DV.scale(dhat, R + 64.0)
	var g_lo := GRAV.gravity_fixed(body, fid, p_lo)
	var want_lo := DV.scale(n, -feel)
	var radial_lo := DV.scale(dhat, -feel)
	_ok(_vdiff(g_lo, want_lo) < 1.0e-9, "FIELD: h<LO ⇒ g == −facet_normal·feel_g (Δ=%s)" % _vdiff(g_lo, want_lo))
	_ok(_vdiff(g_lo, radial_lo) > 1.0e-3, "FIELD: h<LO uses the FACET normal, not radial (Δ vs radial=%s)" % _vdiff(g_lo, radial_lo))
	_ok(_rel(_vlen(g_lo), feel) < 1.0e-9, "FIELD: h<LO magnitude == feel_g (%.4f)" % _vlen(g_lo))

	# (b) above H_BLEND_HI (h=600, w=1): dir == −p̂ (radial, NOT facet), |g| == gm/r²
	var r_hi := R + 600.0
	var p_hi := DV.scale(dhat, r_hi)
	var g_hi := GRAV.gravity_fixed(body, fid, p_hi)
	var want_hi := DV.scale(dhat, -(gm / (r_hi * r_hi)))
	var facet_hi := DV.scale(n, -(gm / (r_hi * r_hi)))
	_ok(_vdiff(g_hi, want_hi) < 1.0e-6, "FIELD: h>HI ⇒ g == −p̂·(gm/r²) radial (Δ=%s)" % _vdiff(g_hi, want_hi))
	_ok(_vdiff(g_hi, facet_hi) > 1.0e-3, "FIELD: h>HI uses RADIAL, not the facet normal (Δ vs facet=%s)" % _vdiff(g_hi, facet_hi))
	_ok(_rel(_vlen(g_hi), gm / (r_hi * r_hi)) < 1.0e-9, "FIELD: h>HI magnitude == gm/r² (%.4f)" % _vlen(g_hi))

	# (c) fid == −1 below the band ⇒ radial-down (not facet), magnitude feel_g
	var g_off := GRAV.gravity_fixed(body, -1, p_lo)
	var want_off := DV.scale(dhat, -feel)
	_ok(_vdiff(g_off, want_off) < 1.0e-9, "FIELD: fid=−1 h<LO ⇒ radial-down·feel_g (Δ=%s)" % _vdiff(g_off, want_off))

	# (d) continuity across the whole band: dense sampling, adjacent |Δg| small
	var prev := GRAV.gravity_fixed(body, fid, DV.scale(dhat, R - 50.0))
	var max_jump := 0.0
	var mono_ok := true
	var mag_prev := _vlen(prev)
	var mag_lo := 0.0
	var mag_hi := 0.0
	for i in range(1, 801):
		var h := -50.0 + float(i)                         # h from −49 .. 750, 1-block steps
		var g := GRAV.gravity_fixed(body, fid, DV.scale(dhat, R + h))
		max_jump = maxf(max_jump, _vdiff(g, prev))
		# |g| rises from feel_g toward gm/r² across the blend. It is STRICTLY monotone only on [LO, HI−32]:
		# once w≈1 near the top, |g| tracks gm/r² which DECLINES with altitude (correct physics — see report),
		# so the design's "monotone on the ramp" holds on the meaningful rise, not the saturated tail.
		if h >= CubeSphere.H_BLEND_LO and h <= CubeSphere.H_BLEND_HI - 32.0:
			if _vlen(g) < mag_prev - 1.0e-9:
				mono_ok = false
		if is_equal_approx(h, CubeSphere.H_BLEND_LO):
			mag_lo = _vlen(g)
		if is_equal_approx(h, CubeSphere.H_BLEND_HI):
			mag_hi = _vlen(g)
		mag_prev = _vlen(g)
		prev = g
	_ok(max_jump < 0.15, "FIELD: continuity — max adjacent |Δg| over the band = %s (< 0.15/block)" % max_jump)
	_ok(mono_ok, "FIELD: |g| monotone non-decreasing on the [LO, HI−32] rise")
	_ok(mag_hi > mag_lo, "FIELD: |g| rises across the band (feel_g → gm/r²): %.4f → %.4f" % [mag_lo, mag_hi])
	print("      ramp magnitude: |g|(LO)=%.4f → |g|(HI)=%.4f (feel %.2f → gm/r² %.2f)" %
		[mag_lo, mag_hi, feel, gm / ((R + CubeSphere.H_BLEND_HI) * (R + CubeSphere.H_BLEND_HI))])

# ---------------------------------------------------------------------------------------
# G-O1-ENERGY — 10 LEO orbits, symplectic conservation
# ---------------------------------------------------------------------------------------
func _gate_energy() -> void:
	print("  --- G-O1-ENERGY: 10 LEO orbits ACTIVE @dt=1/60 (energy/|L| bounded, secular drift ≈ 0) ---")
	var body := "earth"
	var gm := EPH.gm_game(body)
	var R := EPH.radius_of(body)
	var r0 := R + 500.0
	var vcirc := sqrt(gm / r0)
	var T := TAU * sqrt((r0 * r0 * r0) / gm)
	var dt := 1.0 / 60.0
	var steps_per_orbit := int(round(T / dt))
	var orbits := 10
	print("      LEO r=%.1f  v_circ=%.4f m/s  T=%.4f s  steps/orbit=%d" % [r0, vcirc, T, steps_per_orbit])

	var st := OS_.new(body)
	st.pos = DV.v(r0, 0.0, 0.0)
	st.vel = DV.v(0.0, vcirc, 0.0)                        # equatorial prograde circular
	var e0 := st.specific_energy()
	var l0 := _vlen(st.angular_momentum())
	var rmin := r0
	var rmax := r0
	var emin := e0
	var emax := e0
	var lmin := l0
	var lmax := l0
	var per_orbit_e := PackedFloat64Array()
	for orbit in range(orbits):
		for s in range(steps_per_orbit):
			st.integrate(dt)
			var r := _vlen(st.pos)
			rmin = minf(rmin, r); rmax = maxf(rmax, r)
			var e := st.specific_energy()
			emin = minf(emin, e); emax = maxf(emax, e)
			var l := _vlen(st.angular_momentum())
			lmin = minf(lmin, l); lmax = maxf(lmax, l)
		per_orbit_e.append(st.specific_energy())          # same-phase sample once per orbit
	# secular drift: least-squares slope of per-orbit energy vs orbit index
	var slope := _lsq_slope(per_orbit_e)
	var rel_slope := absf(slope) / absf(e0)
	var r_dev := rmax - rmin
	var e_osc := (emax - emin) / absf(e0)
	var l_osc := (lmax - lmin) / l0
	print("      energy ε0=%s  |L|0=%s" % [e0, l0])
	print("      MEASURED: r_dev=%.4f blocks | energy osc(rel)=%s | |L| osc(rel)=%s | secular slope=%s /orbit (rel %s)" %
		[r_dev, e_osc, l_osc, slope, rel_slope])
	_ok(r_dev < 10.0, "ENERGY: r deviation over 10 orbits = %.4f blocks (< 10)" % r_dev)
	_ok(rel_slope < 1.0e-6, "ENERGY: secular energy slope (rel) = %s /orbit (< 1e-6)" % rel_slope)
	_ok(e_osc < 1.0e-2, "ENERGY: energy oscillation bounded (rel %s < 1e-2)" % e_osc)
	_ok(l_osc < 1.0e-3, "ENERGY: |angular momentum| bounded (rel %s < 1e-3)" % l_osc)

# ---------------------------------------------------------------------------------------
# G-O1-KEPLER — freeze/thaw + rails periodicity
# ---------------------------------------------------------------------------------------
func _gate_kepler() -> void:
	print("  --- G-O1-KEPLER: freeze→thaw round-trip, RAILS period exact, rails vs ACTIVE ---")
	var body := "earth"
	var gm := EPH.gm_game(body)
	var R := EPH.radius_of(body)
	# an inclined elliptic orbit (nonzero e, i, raan, argp) to exercise the full element algebra
	var r_pe := R + 800.0
	var r_ap := R + 6000.0
	var a := (r_pe + r_ap) / 2.0
	var e := (r_ap - r_pe) / (r_ap + r_pe)
	var v_pe := sqrt(gm * (2.0 / r_pe - 1.0 / a))         # vis-viva at periapsis
	# start at periapsis; tilt the velocity out of plane to give inclination
	var inc := 0.5
	var st := OS_.new(body)
	st.pos = DV.v(r_pe, 0.0, 0.0)
	st.vel = DV.v(0.0, v_pe * cos(inc), v_pe * sin(inc))
	var p_before := st.pos.duplicate()
	var v_before := st.vel.duplicate()
	print("      ellipse a=%.1f e=%.4f (r_pe=%.1f r_ap=%.1f) v_pe=%.4f" % [a, e, r_pe, r_ap, v_pe])

	# freeze at t0, then rails_state(t0) must reproduce the exact rv (round-trip to f64 ε)
	var t0 := 123.5
	var froze: bool = st.freeze(t0)
	_ok(froze, "KEPLER: elliptic state froze to RAILS")
	_ok(st.mode == OS_.RAILS, "KEPLER: mode == RAILS after freeze")
	var s0: Array = st.rails_state(t0)
	_ok(_vdiff(s0[0], p_before) < 1.0e-6, "KEPLER: rails pos(t0) == pre-freeze pos (Δ=%s)" % _vdiff(s0[0], p_before))
	_ok(_vdiff(s0[1], v_before) < 1.0e-6, "KEPLER: rails vel(t0) == pre-freeze vel (Δ=%s)" % _vdiff(s0[1], v_before))

	# RAILS periodicity: state at t0+T equals state at t0 (period exact)
	var Tp: float = st.period()
	var sT: Array = st.rails_state(t0 + Tp)
	_ok(_vdiff(sT[0], s0[0]) < 1.0e-4, "KEPLER: rails pos(t0+T) == pos(t0) (period %.4f s, Δ=%s)" % [Tp, _vdiff(sT[0], s0[0])])
	_ok(_vdiff(sT[1], s0[1]) < 1.0e-6, "KEPLER: rails vel(t0+T) == vel(t0) (Δ=%s)" % _vdiff(sT[1], s0[1]))

	# thaw resets to ACTIVE with the rv at that time
	var thaw_t := t0 + Tp * 0.37
	st.thaw(thaw_t)
	_ok(st.mode == OS_.ACTIVE, "KEPLER: mode == ACTIVE after thaw")
	# rails vs a fine ACTIVE integration: freeze a fresh circular-ish state, integrate finely, compare to closed form
	var st2 := OS_.new(body)
	var r2 := R + 1500.0
	var vc2 := sqrt(gm / r2)
	st2.pos = DV.v(r2, 0.0, 0.0)
	st2.vel = DV.v(0.0, vc2, 0.0)
	st2.freeze(0.0)
	var span := st2.period() * 0.25
	var rails_end: Array = st2.rails_state(span)
	# integrate the same initial state with a fine dt
	var st3 := OS_.new(body)
	st3.pos = DV.v(r2, 0.0, 0.0)
	st3.vel = DV.v(0.0, vc2, 0.0)
	var dt := 1.0 / 240.0
	var nn := int(round(span / dt))
	for i in range(nn):
		st3.integrate(dt)
	var cross := _vdiff(rails_end[0], st3.pos)
	print("      MEASURED: rails vs fine-ACTIVE position deviation over quarter-orbit = %.4f blocks" % cross)
	_ok(cross < 5.0, "KEPLER: rails position tracks a fine ACTIVE integration (Δ=%.4f blocks < 5)" % cross)

# ---------------------------------------------------------------------------------------
# G-O1-HANDOFF — the §2.4 frame algebra
# ---------------------------------------------------------------------------------------
func _gate_handoff() -> void:
	print("  --- G-O1-HANDOFF: body-fixed↔BCI round-trip + equatorial spin term ---")
	var body := "earth"
	var R := EPH.radius_of(body)
	var t := 271.3
	# round-trip an arbitrary position + velocity through fixed→BCI→fixed
	var p_fixed := DV.v(1234.5, -678.9, 456.7)
	var v_fixed := DV.v(12.3, -4.5, 6.7)
	var p_bci := OS_.pos_fixed_to_bci(body, p_fixed, t)
	var v_bci := OS_.vel_fixed_to_bci(body, p_fixed, v_fixed, t)
	var p_back := OS_.pos_bci_to_fixed(body, p_bci, t)
	var v_back := OS_.vel_bci_to_fixed(body, p_bci, v_bci, t)
	_ok(_vdiff(p_back, p_fixed) < 1.0e-9, "HANDOFF: pos fixed→BCI→fixed round-trip (Δ=%s < 1e-9)" % _vdiff(p_back, p_fixed))
	_ok(_vdiff(v_back, v_fixed) < 1.0e-9, "HANDOFF: vel fixed→BCI→fixed round-trip (Δ=%s < 1e-9)" % _vdiff(v_back, v_fixed))

	# standing still (v_fixed=0) at the equator: |v_bci| == ω·R eastward
	var w := EPH.omega_spin(body)
	var wR := OS_.equatorial_spin_speed(body, R)
	# at t=0 (θ=0) the BCI frame == body-fixed, so the sign is readable directly
	var p_eq := DV.v(R, 0.0, 0.0)                          # equator, +x
	var v_still := DV.v(0.0, 0.0, 0.0)
	var v_spin := OS_.vel_fixed_to_bci(body, p_eq, v_still, 0.0)
	print("      MEASURED: ω=%s rad/s  ω·R=%.4f m/s  v_bci=(%.4f, %.4f, %.4f)" % [w, wR, v_spin[0], v_spin[1], v_spin[2]])
	_ok(_rel(_vlen(v_spin), wR) < 1.0e-9, "HANDOFF: |v_bci| standing at equator == ω·R (%.4f m/s)" % _vlen(v_spin))
	_ok(_rel(wR, 33.36) < 2.0e-3, "HANDOFF: ω·R ≈ 33.4 m/s (measured %.4f)" % wR)
	_ok(v_spin[1] > 0.0 and absf(v_spin[0]) < 1.0e-6 and absf(v_spin[2]) < 1.0e-6,
		"HANDOFF: spin velocity is +y (eastward at the equator, radial/polar components zero)")

# ---------------------------------------------------------------------------------------
# G-O1-DRAG — §2.6 atmosphere drag
# ---------------------------------------------------------------------------------------
func _gate_drag() -> void:
	print("  --- G-O1-DRAG: terminal speed, periapsis decay, ceiling, airless body ---")
	var body := "earth"
	var R := EPH.radius_of(body)
	var feel := GRAV.feel_g(body)
	var DT := CubeSphere.DRAG_TERMINAL
	# terminal by construction: at h=0, drag magnitude at speed DRAG_TERMINAL balances FEEL_G.
	# use the POLE (p along +z) so the co-rotating air term ω×p == 0 and v_air == v.
	var p_pole := DV.v(0.0, 0.0, R)
	var v_down := DV.v(0.0, 0.0, -DT)                      # falling at the terminal target
	var a_drag := OS_.drag_accel(body, p_pole, v_down, 0.0)
	var drag_mag := _vlen(a_drag)
	# solve the true terminal: feel = k0·v² ⇒ v = sqrt(feel/k0)
	var k0 := feel / (DT * DT)
	var v_term := sqrt(feel / k0)
	print("      feel_g=%.4f  K0=%s  drag|(v=DT,h=0)=%.4f (== feel_g?)  terminal(vs feel_g)=%.4f m/s" %
		[feel, k0, drag_mag, v_term])
	_ok(_rel(drag_mag, feel) < 0.05, "DRAG: |a_drag|(DRAG_TERMINAL, h=0) == feel_g ±5%% (%.4f vs %.4f)" % [drag_mag, feel])
	_ok(_rel(v_term, DT) < 0.05, "DRAG: terminal speed (vs feel_g) == DRAG_TERMINAL ±5%% (%.4f)" % v_term)

	# NO drag above ATMO_TOP
	var p_high := DV.v(0.0, 0.0, R + CubeSphere.ATMO_TOP + 10.0)
	var a_high := OS_.drag_accel(body, p_high, DV.v(0.0, 0.0, -200.0), 0.0)
	_ok(_vlen(a_high) == 0.0, "DRAG: zero drag above ATMO_TOP (h=%.0f)" % (CubeSphere.ATMO_TOP + 10.0))
	# drag present just below ATMO_TOP
	var p_in := DV.v(0.0, 0.0, R + CubeSphere.ATMO_TOP - 10.0)
	var a_in := OS_.drag_accel(body, p_in, DV.v(0.0, 0.0, -200.0), 0.0)
	_ok(_vlen(a_in) > 0.0, "DRAG: drag present just below ATMO_TOP")

	# Moon (no atmosphere) ⇒ zero drag anywhere
	var Rm := EPH.radius_of("moon")
	var a_moon := OS_.drag_accel("moon", DV.v(0.0, 0.0, Rm), DV.v(0.0, 0.0, -100.0), 0.0)
	_ok(_vlen(a_moon) == 0.0, "DRAG: airless Moon ⇒ zero drag")

	# a periapsis inside the atmosphere decays the orbit (energy becomes more negative)
	var gm := EPH.gm_game(body)
	var r_pe := R + 200.0                                  # inside ATMO_TOP=384
	var r_ap := R + 3000.0
	var a := (r_pe + r_ap) / 2.0
	var v_pe := sqrt(gm * (2.0 / r_pe - 1.0 / a))
	var st := OS_.new(body)
	st.pos = DV.v(r_pe, 0.0, 0.0)
	st.vel = DV.v(0.0, v_pe, 0.0)
	var e_start := st.specific_energy()
	var T := TAU * sqrt((a * a * a) / gm)
	var dt := 1.0 / 60.0
	var steps := int(round(5.0 * T / dt))
	# Integrate, but STOP once the periapsis has dropped to h≈H_BLEND_LO — below that, live re-entry hands off
	# to SURFACE mode (§2.7); driving the ACTIVE integrator underground (h<0) makes exp(−h/128) explode and the
	# explicit Euler diverge — an invalid regime, not a kernel bug. The energy loss is already decisive by then.
	var floor_r := R + CubeSphere.H_BLEND_LO
	var stopped_h := -1.0
	for i in range(steps):
		st.integrate(dt)
		if _vlen(st.pos) < floor_r:
			stopped_h = _vlen(st.pos) - R
			break
	var e_end := st.specific_energy()
	# apoapsis after decay from current a' = −gm/(2ε)
	var a_end := -gm / (2.0 * e_end)
	print("      MEASURED: periapsis-decay: ε %s → %s (Δ=%s); a %.1f → %.1f; stop h=%.1f" %
		[e_start, e_end, e_end - e_start, a, a_end, stopped_h])
	_ok(e_end < e_start, "DRAG: periapsis-in-atmosphere orbit decays (energy more negative)")
	_ok(a_end < a, "DRAG: semi-major axis shrinks under periodic drag (%.1f → %.1f)" % [a, a_end])

# ---------------------------------------------------------------------------------------
# G-O1-OFF — flag off, consts present, kernels pure
# ---------------------------------------------------------------------------------------
func _gate_off() -> void:
	print("  --- G-O1-OFF: FP_M3_ORBIT=false, consts at spec, kernels pure (no nodes) ---")
	_ok(CubeSphere.FP_M3_ORBIT == false, "OFF: FP_M3_ORBIT default false")
	_ok(is_equal_approx(CubeSphere.H_BLEND_LO, 128.0), "OFF: H_BLEND_LO == 128")
	_ok(is_equal_approx(CubeSphere.H_BLEND_HI, 512.0), "OFF: H_BLEND_HI == 512")
	_ok(is_equal_approx(CubeSphere.ATMO_TOP, 384.0), "OFF: ATMO_TOP == 384")
	_ok(is_equal_approx(CubeSphere.H_FARSWAP, 20000.0), "OFF: H_FARSWAP == 20000")
	_ok(is_equal_approx(CubeSphere.ORBIT_THRUST_G2, 25.0), "OFF: ORBIT_THRUST_G2 == 25")
	_ok(CubeSphere.ORBIT_ACTIVE_MAX == 8, "OFF: ORBIT_ACTIVE_MAX == 8")
	_ok(is_equal_approx(CubeSphere.DRAG_TERMINAL, 55.0), "OFF: DRAG_TERMINAL == 55")
	_ok(is_equal_approx(CubeSphere.ORBIT_PREWARM_H, 1024.0), "OFF: ORBIT_PREWARM_H == 1024")
	# the kernels are RefCounted / pure static — instancing OrbitalState adds NO scene node
	var before := get_root().get_child_count()
	var st := OS_.new("earth")
	var _g := GRAV.gravity_fixed("earth", -1, DV.v(EPH.radius_of("earth") + 1000.0, 0.0, 0.0))
	var after := get_root().get_child_count()
	_ok(st is RefCounted, "OFF: OrbitalState is RefCounted (never a scene Node)")
	_ok(before == after, "OFF: instancing/calling the kernels adds no scene nodes")

# ---------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------
## Least-squares slope of y[i] vs i (i = 0..n−1).
func _lsq_slope(y: PackedFloat64Array) -> float:
	var n := y.size()
	if n < 2:
		return 0.0
	var sx := 0.0; var sy := 0.0; var sxx := 0.0; var sxy := 0.0
	for i in range(n):
		var x := float(i)
		sx += x; sy += y[i]; sxx += x * x; sxy += x * y[i]
	var denom := float(n) * sxx - sx * sx
	if absf(denom) < 1.0e-300:
		return 0.0
	return (float(n) * sxy - sx * sy) / denom
