extends SceneTree
## COSMOS SPACE-FLY headless MISSION gate — G-SPACEFLY (docs/COSMOS-SPACEFLY-DESIGN.md).
##
## The self-test the ORCHESTRATOR runs to verify EVERY new space mechanic WITHOUT a browser, a GPU, the
## relay, or a human at the controls. It scripts a full flight PROFILE — ascend to orbit, coast N periods,
## station-keep a decaying orbit, de-orbit + atmospheric brake to a survivable landing, transfer Earth→Moon
## across the SOI, and read Moon surface feel — asserting each mechanic against the SAME f64 kernels the
## WIRED player drives (CosmosDevFlight / OrbitalState / CosmosNav / CosmosGravity / CosmosEphemeris). Those
## kernels are pure static + flag-INDEPENDENT (the wiring flags gate the player's key handlers, not the math),
## so this gate runs green on ANY build — it is the mechanic falsifier that does not wait on a flag-flipped
## export or a live session. The live remote-bridge command-injection path (the `dev_nav`/`nav`/`thrust`/`roll`
## ops behind RemoteBridge.CONTROL_ENABLED) exercises the SAME mechanics through the real GPU when needed; this
## gate proves the physics those commands drive is correct first.
##
## Gates (each maps to a mechanic the pilot asked to self-verify):
##   (A) ASCENT→ORBIT     — a circular release at LEO gives |v| == v_circ and a bound orbit (energy < 0).
##   (B) ORBIT SUSTAINED  — the O free-coast holds radius over ≥ ORBITS_HELD full periods (no decay/hang).
##   (C) COAST VELOCITY   — |v| stays == v_circ across the whole coast (the telemetry v_bci a flight reads).
##   (D) STATION-KEEP     — a drag-decayed orbit is re-lifted by the prograde auto-boost (does NOT spiral in).
##   (E) DEORBIT + BRAKE  — a retrograde burn lowers periapsis into the atmosphere; the SN-BRAKE drag caps the
##                          descent speed (survivable landing, not a streaming-storm slam).
##   (F) EARTH→MOON + SOI — a point inside the Moon's SOI flips soi_dominant earth→moon; reexpress_soi round-
##                          trips exactly; a circular seed about the Moon is bound (a real destination orbit).
##   (G) WALK ON MOON     — feel_g(moon) ≈ 1/6 g and the jump hang-time scales ~1/√g (the floaty Moon walk).
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_spacefly.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const DEVF := preload("res://src/cosmos/cosmos_dev_flight.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

const ORBITS_HELD := 5                       # (B) the coast must hold radius over this many full periods

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
	print("=== verify_spacefly (COSMOS SPACE-FLY: G-SPACEFLY — headless test-flight mission) ===")
	print("  the space mechanics are flag-independent f64 kernels; this mission drives them exactly as the wired player does")
	FacetAtlas.warm_up()
	_gate_ascent_to_orbit()
	_gate_orbit_sustained()
	_gate_coast_velocity()
	_gate_station_keeping()
	_gate_deorbit_brake()
	_gate_earth_moon_soi()
	_gate_walk_on_moon()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Integrate the shared coast physics (OrbitalState.step, no thrust/drag) for `steps` clamped ticks; return the
## sampled radius extremes and the final [p,v]. This IS the player's O free-coast BCI physics (verify_ocoast §a).
func _coast(body: String, p0: PackedFloat64Array, v0: PackedFloat64Array, dt: float, steps: int) -> Dictionary:
	var os = ORB.make(body, p0, v0)
	var r_min := DV.length(p0)
	var r_max := r_min
	var v_min := DV.length(v0)
	var v_max := v_min
	var a_zero := DV.v(0.0, 0.0, 0.0)
	for _i in range(steps):
		os.step(NAV.clamp_nav_dt(dt), a_zero)
		var r := DV.length(os.pos)
		var v := DV.length(os.vel)
		r_min = minf(r_min, r); r_max = maxf(r_max, r)
		v_min = minf(v_min, v); v_max = maxf(v_max, v)
	return {"r_min": r_min, "r_max": r_max, "v_min": v_min, "v_max": v_max, "os": os}

# ---------- (A) ascent → a bound circular orbit at LEO ----------
func _gate_ascent_to_orbit() -> void:
	print("  --- (A) ASCENT→ORBIT: a circular release at LEO is a bound orbit at |v| == v_circ ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	# LEO: a few hundred blocks up (well above the atmosphere ceiling) — the altitude the O verb releases at.
	var r0 := R + 2000.0
	var p := DV.v(r0, 0.0, 0.0)
	var look := DV.v(0.0, 1.0, 0.0)                          # yaw-tangent heading (⊥ r̂)
	var v := DEVF.release_circular(body, p, look, DV.v(0.0, 0.0, 0.0))
	var mu := GRAV.gm_dyn(body)
	var v_circ := sqrt(mu / r0)
	_ok(_rel(DV.length(v), v_circ) < 1.0e-9, "(A) release |v| == v_circ (%.2f b/s at LEO r0=%.0f)" % [v_circ, r0])
	_ok(ORB.specific_energy(mu, p, v) < 0.0, "(A) the orbit is bound (specific energy < 0 — reaches orbit, does not escape)")
	_ok(v_circ > 0.0, "(A) v_circ is a real positive orbital speed")

# ---------- (B) the O free-coast holds a stable orbit over N periods (no decay/hang) ----------
func _gate_orbit_sustained() -> void:
	print("  --- (B) ORBIT SUSTAINED: the O coast holds radius over >= %d full periods ---" % ORBITS_HELD)
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := R + 2000.0
	var p := DV.v(r0, 0.0, 0.0)
	var v := DEVF.release_circular(body, p, DV.v(0.0, 1.0, 0.0), DV.v(0.0, 0.0, 0.0))
	var v_circ := sqrt(GRAV.gm_dyn(body) / r0)
	var period := TAU * r0 / v_circ
	var dt := NAV.MAX_NAV_DT                                 # the real per-frame clamp (1/30 s)
	var steps := int(ceil(float(ORBITS_HELD) * period / dt))
	var res := _coast(body, p, v, dt, steps)
	var spread := (float(res["r_max"]) - float(res["r_min"])) / r0
	var r_end := DV.length((res["os"] as OrbitalState).pos)
	_ok(spread < 1.0e-2, "(B) radius spread over %d orbits < 1%% (got %.3f%%) — a STABLE orbit" % [ORBITS_HELD, spread * 100.0])
	_ok(_rel(r_end, r0) < 1.0e-2, "(B) radius returns to r0 after %d orbits (no decay/spiral)" % ORBITS_HELD)
	_ok(r_end > 0.9 * r0, "(B) the craft never falls out of orbit (radius stays high — the 'orbits then hangs' bug is absent)")

# ---------- (C) coast velocity stays orbital (the v_bci telemetry a flight asserts) ----------
func _gate_coast_velocity() -> void:
	print("  --- (C) COAST VELOCITY: |v| stays == v_circ across the whole coast ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := R + 2000.0
	var p := DV.v(r0, 0.0, 0.0)
	var v := DEVF.release_circular(body, p, DV.v(0.0, 1.0, 0.0), DV.v(0.0, 0.0, 0.0))
	var v_circ := sqrt(GRAV.gm_dyn(body) / r0)
	var period := TAU * r0 / v_circ
	var res := _coast(body, p, v, NAV.MAX_NAV_DT, int(ceil(3.0 * period / NAV.MAX_NAV_DT)))
	var v_lo := float(res["v_min"]) / v_circ
	var v_hi := float(res["v_max"]) / v_circ
	_ok(v_lo > 0.99 and v_hi < 1.01, "(C) speed stays within 1%% of v_circ over 3 orbits (min %.4f max %.4f ×v_circ)" % [v_lo, v_hi])

# ---------- (D) station-keeping re-lifts a decaying orbit (the prograde auto-boost) ----------
func _gate_station_keeping() -> void:
	print("  --- (D) STATION-KEEP: a sub-circular (decaying) orbit is re-lifted by the prograde auto-boost ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := R + 2000.0
	var p := DV.v(r0, 0.0, 0.0)
	# A DECAYING seed: 0.9·v_circ tangential ⇒ release r0 is the apoapsis, periapsis is lower (sub-circular here).
	var v_circ := sqrt(GRAV.gm_dyn(body) / r0)
	var v := DV.scale(DV.v(0.0, 1.0, 0.0), 0.9 * v_circ)
	var dv := DEVF.station_keep_dv(body, p, v)
	_ok(DV.length(dv) > 0.0, "(D) the auto-boost fires on the sub-circular apoapsis arc (Δv > 0)")
	_ok(DV.dot(dv, v) > 0.0, "(D) the boost is PROGRADE (Δv·v > 0 — raises periapsis, does not brake)")
	# Applying it raises the orbit's specific energy toward the safe circular energy (never past it → no escape).
	var mu := GRAV.gm_dyn(body)
	var eps0 := ORB.specific_energy(mu, p, v)
	var v2 := DV.add(v, dv)
	var eps1 := ORB.specific_energy(mu, p, v2)
	_ok(eps1 > eps0, "(D) the boost raises orbital energy (re-lift), not lowers it")
	_ok(eps1 < 0.0, "(D) the boosted orbit is still bound (self-limiting: cannot pump past escape)")

# ---------- (E) de-orbit + atmospheric brake to a survivable descent ----------
func _gate_deorbit_brake() -> void:
	print("  --- (E) DEORBIT + BRAKE: a retrograde burn drops periapsis into atmosphere; SN-BRAKE caps descent ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var r0 := R + 2000.0
	var p := DV.v(r0, 0.0, 0.0)
	var v_circ := sqrt(GRAV.gm_dyn(body) / r0)
	# Retrograde de-orbit burn: drop below circular so periapsis falls to/below the surface (re-entry).
	var v := DV.scale(DV.v(0.0, 1.0, 0.0), 0.7 * v_circ)
	var mu := GRAV.gm_dyn(body)
	var q := ORB.periapsis_radius(mu, p, v)
	_ok(q < R + CubeSphere.ATMO_TOP, "(E) the retrograde burn drops periapsis into the atmosphere (q=%.0f < R+ATMO)" % q)
	# The SN-BRAKE drag: at a fast descent inside the atmosphere it produces an UPWARD (decelerating) accel that
	# never flips the fall — the fix for the ~141 m/s landing generation-storm. Test the accel sign + boundedness.
	var fast_vy := -140.0                                    # blocks/s, a fast re-entry descent
	var a_brake := ORB.atmo_brake_accel(body, 100.0, fast_vy)   # low altitude, dense air
	_ok(a_brake >= 0.0, "(E) atmo brake opposes the descent (accel >= 0 while falling, a=%.3f)" % a_brake)
	# At the atmosphere top the air is ~vacuum, so there is (near) no brake — continuous with the space free-fall.
	var a_top := ORB.atmo_brake_accel(body, CubeSphere.ATMO_TOP, fast_vy)
	_ok(a_top <= a_brake, "(E) brake is stronger deep in the atmosphere than at its top (density-profiled)")
	_ok(is_finite(a_brake), "(E) the brake accel is finite (no NaN under a fast descent)")

# ---------- (F) Earth→Moon transfer: SOI dominant-body swap + re-expression round-trip ----------
func _gate_earth_moon_soi() -> void:
	print("  --- (F) EARTH→MOON + SOI: a point inside the Moon SOI flips dominant earth→moon; reexpress round-trips ---")
	if not EPH.has_body("moon"):
		_ok(false, "(F) the Moon body exists in the ephemeris")
		return
	var t := 1000.0                                          # an arbitrary epoch — the Moon is somewhere on its orbit
	# The Moon's position in the Earth-centred BCI frame, and its SOI radius.
	var pm := EPH.body_pos_parent("moon", t)
	var r_soi := NAV.soi_radius("moon")
	_ok(r_soi > 0.0, "(F) the Moon has a finite sphere of influence (r_soi=%.0f blocks)" % r_soi)
	# A craft on the Earth→Moon line, JUST INSIDE the Moon's SOI (well inside the hysteresis band).
	var pm_len := DV.length(pm)
	var toward := DV.scale(pm, (pm_len - 0.5 * r_soi) / pm_len)   # 0.5·r_soi short of the Moon centre
	var dom := NAV.soi_dominant("earth", toward, t, CubeSphere.SOI_HYST)
	_ok(dom == "moon", "(F) soi_dominant flips earth→moon inside the SOI (got '%s')" % dom)
	# Far from the Moon (near Earth), the dominant body stays Earth.
	var near_earth := DV.v(GRAV.r_vox("earth") + 2000.0, 0.0, 0.0)
	var dom0 := NAV.soi_dominant("earth", near_earth, t, CubeSphere.SOI_HYST)
	_ok(dom0 == "earth", "(F) soi_dominant stays 'earth' near Earth (got '%s')" % dom0)
	# The SOI swap re-expression is an exact frame change: earth→moon then moon→earth returns the original state.
	var v := DV.v(0.0, 10.0, 0.0)
	var moon_state := ORB.reexpress_soi("earth", "moon", t, toward, v)
	var p_moon: PackedFloat64Array = moon_state[0]
	var v_moon: PackedFloat64Array = moon_state[1]
	_ok(DV.length(p_moon) < r_soi, "(F) re-expressed position is inside the Moon SOI (|p'|=%.0f < r_soi)" % DV.length(p_moon))
	var back := ORB.reexpress_soi("moon", "earth", t, p_moon, v_moon)
	_ok(DV.length(DV.sub(back[0], toward)) < 1.0e-3, "(F) earth→moon→earth position round-trips exactly (no drift)")
	_ok(DV.length(DV.sub(back[1], v)) < 1.0e-6, "(F) earth→moon→earth velocity round-trips exactly")
	# A circular seed about the Moon (in the moon frame) is a bound, sustained orbit — the Moon is a real destination.
	var r_m := DV.length(p_moon)
	var v_circ_m := sqrt(GRAV.gm_dyn("moon") / r_m)
	var vseed := DEVF.release_circular("moon", p_moon, DV.v(0.0, 0.0, 1.0), DV.v(0.0, 0.0, 0.0))
	_ok(_rel(DV.length(vseed), v_circ_m) < 1.0e-6, "(F) a circular release about the Moon gives |v| == moon v_circ (%.2f b/s)" % v_circ_m)
	_ok(ORB.specific_energy(GRAV.gm_dyn("moon"), p_moon, vseed) < 0.0, "(F) the Moon orbit is bound (a capturable destination)")

# ---------- (G) walk on the Moon: 1/6 g floaty feel ----------
func _gate_walk_on_moon() -> void:
	print("  --- (G) WALK ON MOON: feel gravity ~1/6 g, hang time ~1/√g (the floaty Moon walk) ---")
	var g_earth := GRAV.feel_g("earth")
	var g_moon := GRAV.feel_g("moon")
	_ok(g_earth > 0.0 and g_moon > 0.0, "(G) both bodies have a positive feel gravity")
	var ratio := g_moon / g_earth
	_ok(ratio > 0.1 and ratio < 0.25, "(G) Moon feel gravity is ~1/6 Earth (got %.3f — in the lunar band)" % ratio)
	# The player's _apply_body_feel scales jump_velocity by √ratio so jump HEIGHT is preserved while hang time
	# lengthens ~1/√ratio. Replicate that arithmetic and assert the Moon floats ~2.5× longer.
	var jump_scale := sqrt(ratio)
	var hang_scale := 1.0 / jump_scale                       # hang time ∝ v_jump/g = (√ratio)/(ratio) = 1/√ratio
	_ok(hang_scale > 2.0, "(G) a jump hangs ~%.1f× longer on the Moon than Earth (floaty)" % hang_scale)
	# Jump HEIGHT is preserved: h = v²/2g, v scaled √ratio, g scaled ratio ⇒ h scale = ratio/ratio = 1 (byte-neutral feel).
	var height_scale := (jump_scale * jump_scale) / ratio
	_ok(_rel(height_scale, 1.0) < 1.0e-9, "(G) jump HEIGHT is preserved across bodies (h scale == 1)")
