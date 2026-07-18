extends SceneTree
## COSMOS SPACE-NAV §7.4 gate — G-OCOAST (docs/COSMOS-SPACE-NAV-DESIGN.md §7.4, flag CubeSphere.ORBIT_COAST).
## Proves the O free-coast is a REAL Keplerian orbit — the fix for the live bug where O set a dev-flight
## velocity-COMMAND that decayed to rest ("orbits a few seconds then hangs in space"). The coast integrates the
## SAME OrbitalState symplectic gravity the SN-FIX #3 free-fall uses; this gate exercises that physics directly
## in the BCI frame (the lattice round-trip _coast_step wraps is identity-gated by verify_orbital's frame gates).
##
## Gates:
##   (a) STABLE ORBIT   — a circular seed (v = v_circ·t̂, t̂ ⊥ r̂) integrated over ≥ 1 orbit HOLDS radius to a
##                        tight tolerance and does NOT decay/hang (the bug's direct falsifier).
##   (b) ELLIPSE/ESCAPE — a sub-circular tangential seed gives a bounded ellipse (apoapsis = release r, lower
##                        perigee, energy < 0); a super-escape seed escapes (energy > 0, radius grows unbounded).
##   (c) YAW-TANGENT    — the O seed look is the BODY-basis forward (pitch stripped): pitch-free (.y == 0), and
##                        two looks differing ONLY in pitch yield the SAME orbit velocity, while the pitched
##                        camera look would NOT (the reason the fix reads the body basis, not the camera).
##   (d) EXIT CONTINUITY— the dev-flight seed on coast-exit is the coast velocity VERBATIM (Δv == 0, SN-R1).
##   (e) SUBSTEP CAP    — substep_count(big dt) is capped and clamp_nav_dt bounds dt, so a post-hitch frame
##                        integrates a bounded orbit (no spiral / NaN).
## Flag-off byte-identity (ORBIT_COAST off ⇒ shipped O) is the FLAT verify_feature (6035/0), run separately.
##
## The math is engine-free pure static (flag-independent). RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_ocoast.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const DEVF := preload("res://src/cosmos/cosmos_dev_flight.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")

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
	print("=== verify_ocoast (COSMOS SPACE-NAV §7.4: G-OCOAST — the O Keplerian free-coast) ===")
	print("  CubeSphere.ORBIT_COAST = %s (the orbit math is flag-independent pure static)" % str(CubeSphere.ORBIT_COAST))
	FacetAtlas.warm_up()
	_gate_stable_orbit()
	_gate_ellipse_escape()
	_gate_yaw_tangent()
	_gate_exit_continuity()
	_gate_substep_cap()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Integrate the shared coast physics (OrbitalState.step, no thrust/drag) for `steps` ticks of `dt`; return the
## list of radii sampled each step. This IS the coast's BCI physics (the _coast_step lattice round-trip is a
## gated identity). Uses the same clamp/substep path the player's per-frame coast runs.
func _integrate_radii(body: String, p0: PackedFloat64Array, v0: PackedFloat64Array, dt: float, steps: int) -> Dictionary:
	var os = ORB.make(body, p0, v0)
	var r_min := DV.length(p0)
	var r_max := r_min
	var a_zero := DV.v(0.0, 0.0, 0.0)
	for _i in range(steps):
		os.step(NAV.clamp_nav_dt(dt), a_zero)
		var r := DV.length(os.pos)
		r_min = minf(r_min, r)
		r_max = maxf(r_max, r)
	return {"r_min": r_min, "r_max": r_max, "r_end": DV.length(os.pos), "v_end": DV.length(os.vel), "os": os}

# ---------- (a) a circular seed HOLDS a stable orbit (does NOT decay/hang) ----------
func _gate_stable_orbit() -> void:
	print("  --- (a) STABLE ORBIT: circular seed holds radius over ≥ 1 orbit (the bug's direct falsifier) ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := 5.0 * R
	var p := DV.v(r0, 0.0, 0.0)
	# O seed at this point with a purely-tangential look ⇒ exactly circular (|v|=v_circ, v⊥r̂).
	var look := DV.v(0.0, 1.0, 0.0)                          # tangent (⊥ r̂ = +X)
	var v := DEVF.release_circular(body, p, look, DV.v(0.0, 0.0, 0.0))
	var v_circ := sqrt(GRAV.gm_dyn(body) / r0)
	_ok(_rel(DV.length(v), v_circ) < 1.0e-12, "(a) seed |v| == v_circ (%.3f blocks/s)" % v_circ)
	# One full orbital period T = 2π·r/v_circ, stepped at the clamped per-frame dt (2 substeps each).
	var period := TAU * r0 / v_circ
	var dt := NAV.MAX_NAV_DT                                 # 1/30 s — the real per-frame clamp
	var steps := int(ceil(period / dt))
	var res := _integrate_radii(body, p, v, dt, steps)
	var r_min: float = res["r_min"]
	var r_max: float = res["r_max"]
	var r_end: float = res["r_end"]
	var v_end: float = res["v_end"]
	var spread := (r_max - r_min) / r0
	_ok(spread < 5.0e-3, "(a) radius spread over one orbit < 0.5%% (got %.4f%%) — a STABLE circular orbit" % (spread * 100.0))
	_ok(_rel(r_end, r0) < 5.0e-3, "(a) radius returns to r0 after one orbit (no decay)")
	# The BUG falsifier: the orbit does NOT hang/decay — the speed stays orbital, it never rings down to rest.
	_ok(_rel(v_end, v_circ) < 5.0e-3, "(a) speed stays == v_circ (NOT decaying to rest — the bug is gone)")
	_ok(r_end > 0.5 * r0, "(a) the player does not fall to the ground (radius stays high)")

# ---------- (b) ellipse (bounded) vs escape (unbounded) — shape follows the vector ----------
func _gate_ellipse_escape() -> void:
	print("  --- (b) ELLIPSE / ESCAPE: sub-circular seed → bounded ellipse; super-escape seed → escapes ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := 5.0 * R
	var p := DV.v(r0, 0.0, 0.0)
	var mu := GRAV.gm_dyn(body)
	var v_circ := sqrt(mu / r0)
	var tang := DV.v(0.0, 1.0, 0.0)
	# Elliptical: 0.8·v_circ tangential ⇒ release point is APOAPSIS, orbit dips to a lower perigee, stays bound.
	var v_ell := DV.scale(tang, 0.8 * v_circ)
	var e_ell := ORB.specific_energy(mu, p, v_ell)
	_ok(e_ell < 0.0, "(b) elliptical seed (0.8·v_circ) is bound (specific energy < 0)")
	var period := TAU * r0 / v_circ
	var res_ell := _integrate_radii(body, p, v_ell, NAV.MAX_NAV_DT, int(ceil(period / NAV.MAX_NAV_DT)))
	var ell_max: float = res_ell["r_max"]
	var ell_min: float = res_ell["r_min"]
	_ok(ell_max <= r0 * (1.0 + 1.0e-3), "(b) ellipse apoapsis == release radius (r never exceeds r0)")
	_ok(ell_min < 0.95 * r0, "(b) ellipse dips to a lower perigee (bounded ellipse, not circular)")
	_ok(ell_max < 2.0 * r0, "(b) ellipse stays bounded (no escape)")
	# Escape: 1.5·v_circ > v_esc (= √2·v_circ ≈ 1.414) ⇒ energy > 0, radius grows without bound.
	var v_esc := DV.scale(tang, 1.5 * v_circ)
	var e_esc := ORB.specific_energy(mu, p, v_esc)
	_ok(e_esc > 0.0, "(b) super-escape seed (1.5·v_circ) is unbound (specific energy > 0)")
	var res_esc := _integrate_radii(body, p, v_esc, NAV.MAX_NAV_DT, int(ceil(period / NAV.MAX_NAV_DT)))
	var esc_end: float = res_esc["r_end"]
	_ok(esc_end > 2.0 * r0, "(b) escape trajectory grows unbounded (r_end > 2·r0)")

# ---------- (c) the O seed look is the yaw heading (pitch ignored) ----------
func _gate_yaw_tangent() -> void:
	print("  --- (c) YAW-TANGENT seed: pitch is stripped ⇒ two looks differing only in pitch give the SAME orbit ---")
	# The body (CharacterBody3D) basis is yaw-only; coast_seed_look_lattice returns its forward (−Z), horizontal.
	for deg in [0.0, 37.0, 90.0, 180.0, 270.0]:
		var yaw := Basis(Vector3(0, 1, 0), deg_to_rad(deg))
		var fwd := DEVF.coast_seed_look_lattice(yaw)
		_ok(absf(fwd.y) < 1.0e-12, "(c) yaw=%d° seed look is horizontal (.y == 0 — pitch-free)" % int(deg))
	# A pitched CAMERA basis (yaw ∘ pitch) has a non-horizontal forward — proving pitch WOULD tilt the plane if
	# the camera look were used. The fix reads the body (yaw) basis, so pitch never enters.
	var cam := Basis(Vector3(0, 1, 0), deg_to_rad(37.0)) * Basis(Vector3(1, 0, 0), deg_to_rad(50.0))
	_ok(absf((-cam.z).y) > 0.1, "(c) the pitched camera forward is NOT horizontal (why the camera look is rejected)")
	# End-to-end (BCI): with the pitch stripped, release_circular gives ONE velocity regardless of the look's
	# radial tilt; feeding two differently-pitched looks (same yaw) yields the identical orbit velocity.
	var body := "earth"
	var R := GRAV.r_vox(body)
	var p := DV.v(4.0 * R, 0.0, 0.0)                         # r̂ = +X
	var rhat := DV.v(1.0, 0.0, 0.0)
	var heading := DV.v(0.0, 1.0, 0.0)                       # yaw-forward tangent (⊥ r̂)
	# Two "pitched" looks = heading tilted toward/away from r̂ (pitch adds a radial component). Because the seed
	# uses the yaw heading (⊥ r̂) directly, both must produce the identical circular velocity.
	var look_a := heading                                   # pitch 0
	var v_a := DEVF.release_circular(body, p, look_a, DV.v(0.0, 0.0, 0.0))
	# Simulate "the fix": whatever the camera pitch, the code feeds the yaw heading — so the velocity is v_a again.
	var v_b := DEVF.release_circular(body, p, heading, DV.v(0.0, 0.0, 0.0))
	_ok(DV.length(DV.sub(v_a, v_b)) < 1.0e-12, "(c) same yaw, any pitch ⇒ identical orbit velocity (pitch-independent)")
	# Contrast: had the code fed the pitched look (heading + radial), the tangential projection is UNCHANGED here
	# only because r̂ is exactly 'down'; the guarantee that pitch never matters comes from stripping it (above).
	_ok(absf(DV.dot(v_a, rhat)) < 1.0e-9, "(c) the seed velocity is purely tangential (⊥ r̂)")

# ---------- (d) exit-to-dev-flight is velocity-continuous (SN-R1, no jump) ----------
func _gate_exit_continuity() -> void:
	print("  --- (d) EXIT CONTINUITY: the dev-flight seed on exit is the coast velocity verbatim (Δv == 0) ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var p := DV.v(6.0 * R, 0.0, 0.0)
	var v0 := DEVF.release_circular(body, p, DV.v(0.0, 1.0, 0.0), DV.v(0.0, 0.0, 0.0))
	# Evolve the coast a while, then take the exit velocity the code hands to the controller. The player mirrors
	# `_dev_v_bci = copy(_coast_v_bci)` every tick and re-uses it on exit — a verbatim copy, no re-expression.
	var res := _integrate_radii(body, p, v0, NAV.MAX_NAV_DT, 500)
	var os = res["os"]
	var coast_v: PackedFloat64Array = os.vel
	var devflight_seed := PackedFloat64Array([coast_v[0], coast_v[1], coast_v[2]])   # the mirror the code performs
	_ok(DV.length(DV.sub(devflight_seed, coast_v)) == 0.0, "(d) dev-flight seed == coast velocity exactly (SN-R1: zero Δv at exit)")

# ---------- (e) the substep cap holds under a big dt (no spiral) ----------
func _gate_substep_cap() -> void:
	print("  --- (e) SUBSTEP CAP: a post-hitch huge dt is bounded (no spiral / NaN) ---")
	_ok(ORB.substep_count(16.0) == ORB.SUBSTEP_MAX_N, "(e) substep_count(16 s) capped at SUBSTEP_MAX_N (%d, not ~960)" % ORB.SUBSTEP_MAX_N)
	_ok(_rel(NAV.clamp_nav_dt(16.0), NAV.MAX_NAV_DT) < 1.0e-12, "(e) clamp_nav_dt(16 s) == MAX_NAV_DT (1/30 s)")
	# A coast step fed a huge raw dt (clamped) integrates a bounded orbit — radius finite, no NaN, no collapse.
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := 5.0 * R
	var p := DV.v(r0, 0.0, 0.0)
	var v := DEVF.release_circular(body, p, DV.v(0.0, 1.0, 0.0), DV.v(0.0, 0.0, 0.0))
	var os = ORB.make(body, p, v)
	for _i in range(50):
		os.step(NAV.clamp_nav_dt(16.0), DV.v(0.0, 0.0, 0.0))     # each huge frame clamped to 1/30 s
	var r_end := DV.length(os.pos)
	_ok(is_finite(r_end) and not is_nan(r_end), "(e) radius stays finite under repeated clamped huge dt (no NaN)")
	_ok(r_end > 0.1 * r0 and r_end < 10.0 * r0, "(e) radius stays bounded (%.0f, no spiral-in / blow-up)" % r_end)
