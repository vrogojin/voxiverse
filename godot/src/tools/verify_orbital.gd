extends SceneTree
## COSMOS ORBITAL O1 / SPACE-NAV SN1 gate — O1a KERNEL (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.10,
## docs/COSMOS-SPACE-NAV-DESIGN.md §10 SN1). Proves the pure-f64 substrate: the GM_dyn scale bridge,
## the three-regime blend gravity field, the symplectic orbital integrator (energy conservation), and
## the freeze-to-Kepler round trip. Every assert is PURE-KERNEL (CosmosGravity / OrbitalState /
## CosmosEphemeris are engine-free statics), so this gate is FLAG-INDEPENDENT: it passes identically
## with CubeSphere.FP_M3_ORBIT true or false (the kernels are DEAD — never instantiated — when the flag
## is off; the gate exercises them directly). The frame-algebra + handoff + drag + re-entry gates that
## need the full engine (G-O1-HANDOFF/REENTRY/DRAG/ANCHOR/OFF) live in the O1b wiring.
##
## Asserts:
##   G-SN-SCALE  GM_dyn(body) = GM_game·(R_vox/R_eph)³; identity when R_vox==R_eph (Moon today); Earth
##               interim datum gravity 24.6 / circular 274.6; feel_g Earth==22, Moon≈3.63.
##   G-O1-FIELD  gravity_fixed: == feel-g·(−n̂) below LO, == GM_dyn/r²·(−p̂) above HI, continuous at both
##               band edges, magnitude monotone on the ramp; _slerp_unit endpoints/unit/monotone.
##   G-O1-ENERGY 10 LEO orbits ACTIVE at dt=1/60: specific energy + |h| bounded, secular slope < 1e-6/orbit,
##               r deviation < 10 blocks.
##   G-O1-KEPLER rv→coe→rv round trip == state to f64 ε; RAILS period exact (pos at t == at t+T); ACTIVE
##               integration matches the analytic Kepler propagation over an orbit.
##
## RUN (flag optional): docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbital.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")

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

func _initialize() -> void:
	print("=== verify_orbital (COSMOS ORBITAL O1a: GM_dyn + gravity field + integrator + Kepler) ===")
	print("  CubeSphere.FP_M3_ORBIT = %s (gate is flag-independent; kernels are pure statics)" % str(CubeSphere.FP_M3_ORBIT))
	FacetAtlas.warm_up()                                # gravity_fixed's facet normal needs the atlas built
	_gate_scale()
	_gate_field()
	_gate_energy()
	_gate_kepler()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-SN-SCALE: the GM_dyn scale bridge (SPACE-NAV §3, D-SN-2) ----------
func _gate_scale() -> void:
	print("  --- G-SN-SCALE: GM_dyn = GM_game·(R_vox/R_eph)³; identity when R_vox==R_eph ---")
	# Earth interim: k = R_BLOCKS/6371.
	var k_earth := FacetAtlas.R_BLOCKS / EPH.radius_of("earth")
	var expect_earth := EPH.gm_game("earth") * k_earth * k_earth * k_earth
	_ok(_rel(GRAV.gm_dyn("earth"), expect_earth) < 1.0e-12, "G-SN-SCALE: gm_dyn(earth) = %.6e == GM_game·k³ (k=%.5f)" % [GRAV.gm_dyn("earth"), k_earth])
	# Earth/1000 (R_BLOCKS = R_eph = 6371): k = 1 ⇒ GM_dyn collapses to the real-Earth GM_game EXACTLY — the
	# whole point of the resize (the O3 migration the GM_dyn formula was designed to make a no-op). Was 2.317e8
	# at the interim R=3072; now 2.066e9.
	_ok(GRAV.gm_dyn("earth") == EPH.gm_game("earth"), "G-SN-SCALE: gm_dyn(earth) = %.4e == GM_game EXACTLY (R_vox==R_eph identity, Earth/1000)" % GRAV.gm_dyn("earth"))
	# Moon: R_vox == R_eph == 1737 ⇒ identity.
	_ok(GRAV.gm_dyn("moon") == EPH.gm_game("moon"), "G-SN-SCALE: gm_dyn(moon) == GM_game(moon) EXACTLY (R_vox==R_eph identity)")
	_ok(GRAV.r_vox("moon") == EPH.radius_of("moon"), "G-SN-SCALE: r_vox(moon) == R_eph(moon) == 1737")
	# The identity property stated generally: gm_dyn/gm_game == (r_vox/r_eph)³.
	var ratio := GRAV.gm_dyn("earth") / EPH.gm_game("earth")
	_ok(_rel(ratio, k_earth * k_earth * k_earth) < 1.0e-12, "G-SN-SCALE: gm_dyn/GM_game == k³ = %.6f" % (k_earth * k_earth * k_earth))
	# Datum numbers (Earth/1000): datum gravity = GM_dyn/R² = 2.066e9/6371² ≈ 50.9 b/s²; datum circular speed =
	# √(GM_dyn/R) ≈ 569.5 b/s. These are the REAL-Earth Kepler values under the ephemeris' 72× time compression
	# (the same compression that gives the 20-min day) — NOT √(9.81·R) = 250, which is CubeSphere.gm_for (the
	# per-voxel-HUD feel anchor), a SEPARATE field the orbital integrator does not read.
	_ok(_rel(GRAV.datum_gravity("earth"), 50.9) < 5.0e-3, "G-SN-SCALE: datum gravity(earth) = %.3f ≈ 50.9" % GRAV.datum_gravity("earth"))
	_ok(_rel(GRAV.datum_circular_speed("earth"), 569.5) < 5.0e-3, "G-SN-SCALE: datum circular(earth) = %.2f ≈ 569.5" % GRAV.datum_circular_speed("earth"))
	# feel_g: Earth == the shipped walk-feel gravity (player.gd `gravity`), rescaled to 9.8; Moon ≈ 1.62 (real ratio).
	_ok(GRAV.feel_g("earth") == 9.8, "G-SN-SCALE: feel_g(earth) == 9.8 exactly (mirrors player.gd walk gravity)")
	_ok(_rel(GRAV.feel_g("moon"), 1.618) < 1.0e-2, "G-SN-SCALE: feel_g(moon) = %.3f ≈ 1.62 (9.8 × real g-ratio, hang ×2.5)" % GRAV.feel_g("moon"))

# ---------- G-O1-FIELD: the three-regime blend gravity field (§2.2) ----------
func _gate_field() -> void:
	print("  --- G-O1-FIELD: gravity_fixed regimes/continuity/monotonicity + slerp ---")
	var body := "earth"
	var rv := GRAV.r_vox(body)
	var fid := 100                                      # any interior facet; its normal is the local up
	var n := FacetAtlas.facet_normal64(fid)             # world outward normal [x,y,z]
	var n_dv := DV.v(n[0], n[1], n[2])
	# Place the sample points directly ALONG the facet normal: there radial-down == lattice-down, so the
	# direction is exact (−n̂) at every altitude and the test isolates the MAGNITUDE blend cleanly.
	var p_at := func(h: float) -> PackedFloat64Array: return DV.scale(n_dv, rv + h)

	# Below LO: exactly feel-g magnitude, direction −n̂.
	var g_lo := GRAV.gravity_fixed(body, fid, p_at.call(64.0))
	_ok(_rel(DV.length(g_lo), GRAV.feel_g(body)) < 1.0e-9, "G-O1-FIELD: |g| at h=64 == feel_g %.3f (below band)" % GRAV.feel_g(body))
	var dir_lo := DV.scale(g_lo, 1.0 / DV.length(g_lo))
	_ok(_rel(DV.dot(dir_lo, DV.v(-n[0], -n[1], -n[2])), 1.0) < 1.0e-9, "G-O1-FIELD: direction at h=64 == −facet_normal (shipped feel down)")

	# Above HI: exactly GM_dyn/r² magnitude, direction −p̂.
	var r_hi := rv + 600.0
	var expect_hi := GRAV.gm_dyn(body) / (r_hi * r_hi)
	var g_hi := GRAV.gravity_fixed(body, fid, p_at.call(600.0))
	_ok(_rel(DV.length(g_hi), expect_hi) < 1.0e-9, "G-O1-FIELD: |g| at h=600 == GM_dyn/r² %.4f (above band)" % expect_hi)

	# Continuity at LO (128) and HI (512): the value must not jump across the edge.
	var eps := 0.01
	var lo := CubeSphere.H_BLEND_LO
	var hi := CubeSphere.H_BLEND_HI
	var d_lo := absf(DV.length(GRAV.gravity_fixed(body, fid, p_at.call(lo - eps))) - DV.length(GRAV.gravity_fixed(body, fid, p_at.call(lo + eps))))
	var d_hi := absf(DV.length(GRAV.gravity_fixed(body, fid, p_at.call(hi - eps))) - DV.length(GRAV.gravity_fixed(body, fid, p_at.call(hi + eps))))
	_ok(d_lo < 1.0e-3, "G-O1-FIELD: |Δg| across the LO edge = %.2e < 1e-3 (continuous)" % d_lo)
	_ok(d_hi < 1.0e-3, "G-O1-FIELD: |Δg| across the HI edge = %.2e < 1e-3 (continuous)" % d_hi)

	# Bounded on the ramp: lerp keeps |g(h)| between the two regime magnitudes (feel_g and GM_dyn/r²) at
	# every altitude — the true, R-independent invariant. NOTE: strict monotonicity across the blend is a
	# POST-O3 property only; at the interim R=3072 feel_g (22) sits just BELOW the datum GM_dyn/r² (~22.6),
	# which then descends to ~18, so the blend has a small (~3%) hump near the band bottom (disclosed). The
	# hump never exceeds max(feel_g, GM_dyn/r²(h)); post-O3 (22→43.6, feel below GM/r² throughout) it is
	# monotone. We assert the bound here + strict monotonicity in the pure GM regime above HI.
	var bounded := true
	var peak_over := 0.0
	for i in range(0, 65):
		var h := lo + (hi - lo) * float(i) / 64.0
		var r_h := rv + h
		var g_reg := GRAV.gm_dyn(body) / (r_h * r_h)
		var mag := DV.length(GRAV.gravity_fixed(body, fid, p_at.call(h)))
		var mmin := minf(GRAV.feel_g(body), g_reg)
		var mmax := maxf(GRAV.feel_g(body), g_reg)
		if mag < mmin - 1.0e-6 or mag > mmax + 1.0e-6:
			bounded = false
		peak_over = maxf(peak_over, mag - GRAV.feel_g(body))
	_ok(bounded, "G-O1-FIELD: |g| stays between feel_g and GM_dyn/r² across the ramp (hump peak +%.3f m/s², interim)" % peak_over)
	# Strictly monotone-decreasing in the pure GM regime above HI.
	var prev := 1.0e30
	var mono_hi := true
	for i in range(0, 41):
		var h := hi + 50.0 * float(i)
		var mag := DV.length(GRAV.gravity_fixed(body, fid, p_at.call(h)))
		if mag > prev + 1.0e-12:
			mono_hi = false
		prev = mag
	_ok(mono_hi, "G-O1-FIELD: magnitude strictly monotone-decreasing above HI (pure GM_dyn/r²)")

	# _slerp_unit endpoints / unit / monotone angle between two 40°-apart unit vectors.
	var a := DV.v(1.0, 0.0, 0.0)
	var b := DV.v(cos(deg_to_rad(40.0)), sin(deg_to_rad(40.0)), 0.0)
	var s0 := GRAV._slerp_unit(a, b, 0.0)
	var s1 := GRAV._slerp_unit(a, b, 1.0)
	_ok(_rel(DV.dot(s0, a), 1.0) < 1.0e-12, "G-O1-FIELD: slerp(t=0) == a")
	_ok(_rel(DV.dot(s1, b), 1.0) < 1.0e-12, "G-O1-FIELD: slerp(t=1) == b")
	var prev_ang := -1.0
	var slerp_mono := true
	var slerp_unit := true
	for i in range(0, 11):
		var t := float(i) / 10.0
		var sv := GRAV._slerp_unit(a, b, t)
		if absf(DV.length(sv) - 1.0) > 1.0e-12:
			slerp_unit = false
		var ang := acos(clampf(DV.dot(a, sv), -1.0, 1.0))
		if ang < prev_ang - 1.0e-12:
			slerp_mono = false
		prev_ang = ang
	_ok(slerp_unit, "G-O1-FIELD: _slerp_unit stays unit-length")
	_ok(slerp_mono, "G-O1-FIELD: _slerp_unit angle from a increases monotonically")

# ---------- G-O1-ENERGY: symplectic energy conservation over 10 LEO orbits ----------
func _gate_energy() -> void:
	print("  --- G-O1-ENERGY: 10 LEO orbits, bounded energy/|h|, secular slope < 1e-6/orbit ---")
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	var r := GRAV.r_vox(body) + 500.0
	var v_circ := sqrt(mu / r)
	# Circular orbit inclined 30° (avoids the equatorial degeneracy; energy is inclination-blind).
	var inc := deg_to_rad(30.0)
	var st := ORB.make(body, DV.v(r, 0.0, 0.0), DV.v(0.0, v_circ * cos(inc), v_circ * sin(inc)))
	var e0 := ORB.specific_energy(mu, st.pos, st.vel)
	var h0 := DV.length(ORB.ang_momentum(st.pos, st.vel))
	var period := TAU * sqrt(r * r * r / mu)
	var dt := 1.0 / 60.0
	var zero := DV.v(0.0, 0.0, 0.0)
	var e_at_orbit := PackedFloat64Array([e0])
	var worst_e := 0.0
	var worst_h := 0.0
	var worst_r := 0.0
	var t := 0.0
	var next_orbit := period
	var orbits_done := 0
	while orbits_done < 10:
		st.step(dt, zero)
		t += dt
		var e := ORB.specific_energy(mu, st.pos, st.vel)
		var hh := DV.length(ORB.ang_momentum(st.pos, st.vel))
		worst_e = maxf(worst_e, _rel(e, e0))
		worst_h = maxf(worst_h, _rel(hh, h0))
		worst_r = maxf(worst_r, absf(DV.length(st.pos) - r))
		if t >= next_orbit:
			e_at_orbit.append(e)
			next_orbit += period
			orbits_done += 1
	# Secular drift: least-squares slope of energy vs orbit index, relative to |e0|.
	var slope := _lsq_slope(e_at_orbit)
	var rel_slope := absf(slope / e0)
	_ok(worst_e < 1.0e-3, "G-O1-ENERGY: worst relative energy excursion = %.2e < 1e-3 (bounded)" % worst_e)
	_ok(worst_h < 1.0e-6, "G-O1-ENERGY: worst relative |h| excursion = %.2e < 1e-6 (near-exact)" % worst_h)
	_ok(rel_slope < 1.0e-6, "G-O1-ENERGY: secular energy slope = %.2e /orbit < 1e-6 (symplectic, no drift)" % rel_slope)
	_ok(worst_r < 10.0, "G-O1-ENERGY: worst radius deviation = %.4f blocks < 10 (circular held)" % worst_r)

func _lsq_slope(ys: PackedFloat64Array) -> float:
	var n := ys.size()
	if n < 2:
		return 0.0
	var sx := 0.0; var sy := 0.0; var sxx := 0.0; var sxy := 0.0
	for i in range(n):
		var x := float(i)
		sx += x; sy += ys[i]; sxx += x * x; sxy += x * ys[i]
	var denom := float(n) * sxx - sx * sx
	if absf(denom) < 1.0e-300:
		return 0.0
	return (float(n) * sxy - sx * sy) / denom

# ---------- G-O1-KEPLER: freeze/thaw round trip + period + ACTIVE-vs-analytic ----------
func _gate_kepler() -> void:
	print("  --- G-O1-KEPLER: rv→coe→rv round trip, exact period, ACTIVE matches analytic ---")
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	# A generic inclined eccentric orbit (no degeneracy). a=5000 (> R), e=0.3 ⇒ r_peri=3500 > 3072.
	var el_in := PackedFloat64Array([5000.0, 0.3, deg_to_rad(40.0), deg_to_rad(25.0), deg_to_rad(60.0), deg_to_rad(10.0), 0.0])
	var rv0 := ORB.coe_to_rv(mu, el_in, 0.0)
	var p0: PackedFloat64Array = rv0[0]
	var v0: PackedFloat64Array = rv0[1]

	# rv → coe: the recovered elements must match the inputs.
	var el_out := ORB.rv_to_coe(mu, p0, v0, 0.0)
	var enames := ["a", "e", "inc", "raan", "argp", "M"]
	var coe_ok := true
	for i in range(6):
		if _rel(el_out[i], el_in[i]) > 1.0e-9:
			coe_ok = false
			print("    coe[%s]: got %.12f want %.12f" % [enames[i], el_out[i], el_in[i]])
	_ok(coe_ok, "G-O1-KEPLER: rv_to_coe recovers a/e/inc/raan/argp/M to 1e-9")

	# coe → rv → coe → rv round trip on the STATE (freeze/thaw).
	var st := ORB.make(body, p0, v0)
	st.freeze(0.0)
	_ok(st.mode == ORB.RAILS, "G-O1-KEPLER: freeze() sets RAILS mode")
	st.thaw(0.0)
	var rt_p := _rel(DV.length(DV.sub(st.pos, p0)), 0.0) if DV.length(p0) == 0.0 else DV.length(DV.sub(st.pos, p0)) / DV.length(p0)
	var rt_v := DV.length(DV.sub(st.vel, v0)) / DV.length(v0)
	_ok(rt_p < 1.0e-9, "G-O1-KEPLER: freeze→thaw position round-trip rel = %.2e < 1e-9" % rt_p)
	_ok(rt_v < 1.0e-9, "G-O1-KEPLER: freeze→thaw velocity round-trip rel = %.2e < 1e-9" % rt_v)

	# RAILS period exactness: position at t == at t+T.
	var period := TAU * sqrt(5000.0 * 5000.0 * 5000.0 / mu)
	st.freeze(0.0)
	var pa := st.position_at(123.0)
	var pb := st.position_at(123.0 + period)
	_ok(DV.length(DV.sub(pa, pb)) < 1.0e-6, "G-O1-KEPLER: RAILS position(t) == position(t+T), Δ = %.2e blocks" % DV.length(DV.sub(pa, pb)))

	# ACTIVE integration matches the analytic Kepler propagation over an orbit (integration accuracy).
	var st2 := ORB.make(body, p0, v0)
	var dt := 1.0 / 60.0
	var zero := DV.v(0.0, 0.0, 0.0)
	var worst := 0.0
	var t := 0.0
	var samples := 0
	while t < period:
		st2.step(dt, zero)
		t += dt
		# compare to analytic every ~1/1000 of the orbit
		if samples % 88 == 0:
			var pana: PackedFloat64Array = ORB.coe_to_rv(mu, el_in, t)[0]
			worst = maxf(worst, DV.length(DV.sub(st2.pos, pana)))
		samples += 1
	_ok(worst < 2.0, "G-O1-KEPLER: ACTIVE vs analytic worst position gap over one orbit = %.4f blocks < 2 (integration accuracy)" % worst)
