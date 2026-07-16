extends SceneTree
## COSMOS ORBITAL O0 gate (docs/COSMOS-ORBITAL-DESIGN.md §3.3/§3.4/§4.2/§4.4, §11 O0). Proves the
## LOCKED scale/time/mass math of the celestial kernel — the entire point of the phase — plus a
## CosmosSky instantiation smoke test. Almost every assert is PURE-KERNEL (CosmosEphemeris/DVecF64
## are engine-free statics), so this gate is FLAG-INDEPENDENT: it passes identically with
## CubeSphere.ORBITAL_SKY true or false (the sed-true in the run recipe is harmless, not required).
## The one scene-touching part (CosmosSky.setup building its reused nodes) also does not read the
## flag, so it runs either way. RENDER cannot be verified headless — the live sunset is a screenshot.
##
## Asserts:
##   SCALE   GM scaling law: GM_SCALE == (1e-3)³·72² (to f64 ulp; direct == is a 1-ulp miss), and
##           GM_game/GM_real == 5.184e-6 for every body; derived GM_game == the canonical §3.3 table.
##   CAL     Calendar: DAY_GAME=1200; Earth spin period 1200 s; Moon month ≈ 32796 s (9.11 h, 27.3
##           game-days); year ≈ 438300 s (121.75 h, 365 game-days) — each derived by Kepler
##           T=2π√(a³/GM_parent), proving the GM table is self-consistent with the locked periods.
##   TIDAL   sub-Earth longitude of the Moon is constant across a full month (same face Earthward).
##   ANG     Sun angular diameter ≈ 0.533°, Moon ≈ 0.518° (the near-equality eclipses need).
##   SPEED   circular datum ≈ 570, low orbit ≈ 548 m/s & period ≈ 78.7 s, escape ≈ 805 m/s.
##   PURE    determinism (same t → identical), monotone advance, clock advance sums exactly.
##   ECLIPSE some t exists where Moon-dir and Sun-dir from Earth fall within the summed angular radii.
##   SKY     CosmosSky builds its Sun/SunLight/Moon/StarDome nodes and ticks without error.
##
## RUN (flag optional):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbital_sky.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const SKY := preload("res://src/cosmos/cosmos_sky.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Relative-tolerance compare (both non-zero regime).
func _rel(a: float, b: float) -> float:
	var d := absf(b)
	if d < 1.0e-300:
		return absf(a - b)
	return absf(a - b) / d

func _initialize() -> void:
	print("=== verify_orbital_sky (COSMOS ORBITAL O0: CosmosEphemeris scale/time/mass + sky) ===")
	print("  CubeSphere.ORBITAL_SKY = %s (gate is flag-independent; kernel is pure statics)" % str(CubeSphere.ORBITAL_SKY))

	_gate_scale()
	_gate_calendar()
	_gate_tidal_lock()
	_gate_angular_sizes()
	_gate_speeds()
	_gate_purity()
	_gate_eclipse()
	_gate_sky_instantiation()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- SCALE: the GM scaling law (the heart of the phase) ----------
func _gate_scale() -> void:
	print("  --- SCALE: GM_game = GM_real × 5.184e-6 = (1e-3)³·72² ---")
	var prod := pow(1.0e-3, 3.0) * pow(72.0, 2.0)
	# The literal 5.184e-6 and the computed product differ by 1 ulp (rel ~1.6e-16) — so this is a
	# tolerance check, NOT ==, and the tolerance is far below any physical significance.
	_ok(prod != EPH.GM_SCALE, "SCALE: (1e-3)³·72² != the 5.184e-6 literal by 1 ulp (direct == would be brittle)")
	_ok(_rel(prod, EPH.GM_SCALE) < 1.0e-12, "SCALE: GM_SCALE == (1e-3)³·72² to f64 ulp (rel %s < 1e-12)" % _rel(prod, EPH.GM_SCALE))
	_ok(is_equal_approx(EPH.GM_SCALE, 5.184e-6), "SCALE: GM_SCALE == 5.184e-6")
	# per-body scaling law + canonical §3.3 table cross-check.
	var canon := {"sun": 6.880e14, "earth": 2.066e9, "moon": 2.543e7}
	for b in ["sun", "earth", "moon"]:
		var ratio := EPH.gm_game(b) / EPH.gm_real(b)
		_ok(_rel(ratio, 5.184e-6) < 1.0e-3, "SCALE[%s]: GM_game/GM_real = %s ≈ 5.184e-6 (rel %s)" % [b, ratio, _rel(ratio, 5.184e-6)])
		_ok(_rel(EPH.gm_game(b), canon[b]) < 1.0e-3, "SCALE[%s]: derived GM_game %s ≈ canonical %s (rel %s)" % [b, EPH.gm_game(b), canon[b], _rel(EPH.gm_game(b), canon[b])])

# ---------- CAL: the calendar (Kepler self-consistency with the locked periods) ----------
func _gate_calendar() -> void:
	print("  --- CAL: day 1200 s, month ≈ 32796 s, year ≈ 438300 s (Kepler-derived) ---")
	_ok(is_equal_approx(EPH.DAY_GAME, 1200.0), "CAL: DAY_GAME == 1200 s (20-min day)")
	_ok(is_equal_approx(EPH.TIME_COMPRESSION, 72.0), "CAL: TIME_COMPRESSION == 72×")
	# Earth spin period from the spin rate.
	var earth_spin_T := TAU / EPH.omega_spin("earth")
	_ok(_rel(earth_spin_T, 1200.0) < 1.0e-6, "CAL: Earth spin period = %.3f s == 1200 (rel %s)" % [earth_spin_T, _rel(earth_spin_T, 1200.0)])
	# Year — Earth around Sun, Kepler T=2π√(a³/GM_sun). Matches the locked 438300 s to <0.01%.
	var year := EPH.orbit_period("earth")
	_ok(_rel(year, 438300.0) < 1.0e-3, "CAL: year (Kepler) = %.1f s ≈ 438300 (%.3f h, rel %s)" % [year, year / 3600.0, _rel(year, 438300.0)])
	_ok(_rel(year / EPH.DAY_GAME, 365.25) < 5.0e-3, "CAL: year = %.2f game-days ≈ 365" % (year / EPH.DAY_GAME))
	# Month — Moon around Earth, Kepler T=2π√(a³/GM_earth). The locked table month (32796 s, from
	# real 27.32 d ÷ 72) and the (a=384400, GM_earth) Kepler period disagree by ~0.45% — an inherent
	# real-world inconsistency (the Moon's mean-distance/mass/period is NOT a clean one-body Kepler
	# set: Earth–Moon barycentre + osculating vs mean elements). The ÷1000/÷72 scaling preserves that
	# real ~0.45% ratio EXACTLY (§3.3), so the tolerance here is physical, not numerical slop.
	var month := EPH.orbit_period("moon")
	var month_rel := _rel(month, 32796.0)
	_ok(month_rel < 1.0e-2, "CAL: month (Kepler) = %.1f s ≈ 32796 (%.3f h, rel %.3f — inherent real two-body 0.45%%)" % [month, month / 3600.0, month_rel])
	_ok(_rel(month / EPH.DAY_GAME, 27.3) < 1.0e-2, "CAL: month = %.2f game-days ≈ 27.3" % (month / EPH.DAY_GAME))
	# Kepler-self-consistency (explicit): the derived period IS 2π√(a³/GM_parent) — recompute independently.
	for b in ["earth", "moon"]:
		var a := EPH.orbit_a(b)
		var gmp := EPH.gm_game(EPH.parent_of(b))
		var t_indep := TAU * sqrt((a * a * a) / gmp)
		_ok(_rel(t_indep, EPH.orbit_period(b)) < 1.0e-9, "CAL[%s]: orbit_period == 2π√(a³/GM_parent) (self-consistent)" % b)

# ---------- TIDAL: the Moon keeps one face Earthward all month ----------
func _gate_tidal_lock() -> void:
	print("  --- TIDAL: sub-Earth longitude of the Moon constant across a full month ---")
	var month := EPH.orbit_period("moon")
	var lon0 := EPH.sub_longitude("moon", "earth", 0.0)
	var worst := 0.0
	var steps := 400
	for i in range(steps + 1):
		var t := month * float(i) / float(steps)
		var lon := EPH.sub_longitude("moon", "earth", t)
		# smallest signed angular difference (wrap-safe)
		var d := lon - lon0
		while d > PI: d -= TAU
		while d < -PI: d += TAU
		worst = maxf(worst, absf(d))
	_ok(worst < 1.0e-9, "TIDAL: sub-Earth longitude drift over a month = %s rad < 1e-9 (tidally locked)" % worst)

# ---------- ANG: real angular diameters ----------
func _gate_angular_sizes() -> void:
	print("  --- ANG: Sun ≈ 0.533°, Moon ≈ 0.518° (from Earth) ---")
	var sun_deg := rad_to_deg(EPH.angular_diameter("sun", "earth", 0.0))
	var moon_deg := rad_to_deg(EPH.angular_diameter("moon", "earth", 0.0))
	_ok(absf(sun_deg - 0.533) < 0.02, "ANG: Sun angular diameter %.4f° ≈ 0.533°" % sun_deg)
	_ok(absf(moon_deg - 0.518) < 0.02, "ANG: Moon angular diameter %.4f° ≈ 0.518°" % moon_deg)
	_ok(absf(sun_deg - moon_deg) < 0.05, "ANG: Sun/Moon near-equal (Δ %.4f°) — the eclipse coincidence" % absf(sun_deg - moon_deg))

# ---------- SPEED: derived orbital speeds (Earth system) ----------
func _gate_speeds() -> void:
	print("  --- SPEED: circular 570, low-orbit 548/78.7 s, escape 805 m/s ---")
	var gm := EPH.gm_game("earth")
	var R := EPH.radius_of("earth")
	var v_circ := sqrt(gm / R)
	_ok(_rel(v_circ, 570.0) < 1.0e-2, "SPEED: circular at datum = %.1f m/s ≈ 570" % v_circ)
	var r_low := R + 500.0
	var v_low := sqrt(gm / r_low)
	var t_low := TAU * sqrt((r_low * r_low * r_low) / gm)
	_ok(_rel(v_low, 548.0) < 1.0e-2, "SPEED: low orbit (r=%.0f) = %.1f m/s ≈ 548" % [r_low, v_low])
	_ok(_rel(t_low, 78.7) < 1.0e-2, "SPEED: low orbit period = %.2f s ≈ 78.7" % t_low)
	var v_esc := sqrt(2.0 * gm / R)
	_ok(_rel(v_esc, 805.0) < 1.0e-2, "SPEED: escape at datum = %.1f m/s ≈ 805" % v_esc)

# ---------- PURE: determinism + clock exactness ----------
func _gate_purity() -> void:
	print("  --- PURE: determinism, monotone advance, exact clock sum ---")
	# same t → identical outputs (repeated calls).
	var p1 := EPH.body_pos_helio("moon", 12345.678)
	var p2 := EPH.body_pos_helio("moon", 12345.678)
	_ok(p1[0] == p2[0] and p1[1] == p2[1] and p1[2] == p2[2], "PURE: body_pos_helio is a pure function of t (identical repeats)")
	var d1 := EPH.dir_to("earth", "sun", 999.0)
	var d2 := EPH.dir_to("earth", "sun", 999.0)
	_ok(d1 == d2, "PURE: dir_to is a pure function of t")
	# clock advance sums exactly + is monotone.
	var c := EPH.CosmosClock.new()
	c.advance(1.5)
	c.advance(2.5)
	_ok(c.now() == 4.0, "PURE: clock advance(1.5)+advance(2.5) == 4.0 exactly (t=%.17g)" % c.now())
	var before := c.now()
	c.advance(0.25)
	_ok(c.now() > before and c.now() == 4.25, "PURE: clock is monotone and sums exactly (t=%.17g)" % c.now())
	# DVecF64 sanity: sub/length/dot behave.
	var a := DV.v(3.0, 4.0, 0.0)
	_ok(is_equal_approx(DV.length(a), 5.0), "PURE: DVecF64.length([3,4,0]) == 5")
	_ok(is_equal_approx(DV.dot(DV.v(1.0, 2.0, 3.0), DV.v(4.0, 5.0, 6.0)), 32.0), "PURE: DVecF64.dot == 32")

# ---------- ECLIPSE: Moon can occult the Sun (geometry sanity) ----------
func _gate_eclipse() -> void:
	print("  --- ECLIPSE: some t where Moon-dir and Sun-dir from Earth coincide within summed radii ---")
	var month := EPH.orbit_period("moon")
	var sum_radii := 0.5 * (EPH.angular_diameter("sun", "earth", 0.0) + EPH.angular_diameter("moon", "earth", 0.0))
	var min_sep := PI
	var t_min := 0.0
	# Sample two synodic months at a step fine enough not to skip the ±sum_radii window (§ gate note).
	var t := 0.0
	var dt := 8.0
	var t_end := 2.0 * month
	while t <= t_end:
		var ds := EPH.dir_to("earth", "sun", t)
		var dm := EPH.dir_to("earth", "moon", t)
		var sep := ds.angle_to(dm)
		if sep < min_sep:
			min_sep = sep
			t_min = t
		t += dt
	_ok(min_sep < sum_radii, "ECLIPSE: min Sun–Moon separation %.5f rad < summed radii %.5f rad (occultation possible at t=%.0f s)" % [min_sep, sum_radii, t_min])

# ---------- SKY: CosmosSky instantiation smoke test (exercises the scene-touching path) ----------
func _gate_sky_instantiation() -> void:
	print("  --- SKY: CosmosSky builds its reused nodes + ticks without error ---")
	var clock := EPH.CosmosClock.new()
	var sky := SKY.new()
	get_root().add_child(sky)
	sky.setup(clock, null, null)                # null env (no ramp), null cam provider (origin-centred)
	_ok(sky.get_node_or_null("Sun") != null, "SKY: Sun impostor mesh built")
	_ok(sky.get_node_or_null("SunLight") != null, "SKY: DirectionalLight built")
	_ok(sky.get_node_or_null("Moon") != null, "SKY: Moon impostor built")
	_ok(sky.get_node_or_null("StarDome") != null, "SKY: star dome built")
	# Tick a few frames of clock+sky update — must not crash and must move the sun over a day.
	var sun := sky.get_node_or_null("SunLight") as DirectionalLight3D
	var basis_a := sun.transform.basis
	clock.advance(600.0)                        # half a game-day
	sky._process(0.0)
	var basis_b := sun.transform.basis
	_ok(not basis_a.is_equal_approx(basis_b), "SKY: sun light rotated after half a day (sky moves with the clock)")
	sky.queue_free()
