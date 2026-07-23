extends SceneTree
## COSMOS-LOD-SKY task 2 gate (docs/COSMOS-LOD-SKY-DESIGN.md §6/§7, §9 L0–L3). Proves the celestial-lighting
## MATH end-to-end WITHOUT a live browser: phases/terminator on the SHIPPED geometry (L0), moonshine + lunar
## eclipse (L1), the Rayleigh sunrise/sunset ramp (L2), and the space-side terminator tint (L3). Every asserted
## object is a PURE static (CosmosEphemeris phase helpers / CosmosSky scatter+moonshine statics), so this gate is
## FLAG-INDEPENDENT — it passes identically with the SKY_* / SHELL_TERMINATOR_TINT flags true or false; the flags
## only decide whether _ramp_environment / _make_material COMPOSE the math in-game. Only the LOOK is live-only.
##
## Gates:
##   G-MOON-PHASE   illuminated fraction f=(1+cos ψ)/2 over a synodic month (0→1→0), full-moon spacing == synodic
##                  period, quarter ⇒ elongation ≈90°, bright limb ⊥ line-of-sight & sunward (§7.2).
##   G-TERMINATOR   the day/night boundary from the single Sun direction is the great circle ⊥ sun_dir to ≤1°;
##                  the surface ramp (sun·up) and the orbit-view shading (sun·n) are the SAME sign ⇒ one Sun,
##                  two vantages agree (§7.1).
##   G-SKY-MOONSHINE  ambient energy = gain·f·moon_up·night_authority (0 at new moon / day / moon-down, monotone,
##                  C¹); the lunar-eclipse factor is 0 in the umbra, 1 clear, monotone, and dims the term (§7.3).
##   G-SKY-SCATTER  T(μ)=exp(−τ·m(μ)) matches the real optical-depth table at sampled elevations; each channel is
##                  monotone in μ and blue is extinguished fastest (red-ward hue as μ↓); C¹; flag-off leaves the
##                  shipped two-colour ramp byte-identical (§6a).
##   G-SHELL-TINT   the per-vertex shell tint == mix(white, scatter_tint(μ), band(μ)) at sampled μ; the far-ring
##                  material is a plain StandardMaterial3D when the flag is off and the tint ShaderMaterial (with a
##                  sun_dir uniform) when on — byte-identical shell off (§6b).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_lod_sky.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const SKY := preload("res://src/cosmos/cosmos_sky.gd")
const RING := preload("res://src/world/facet_far_ring.gd")

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
	print("=== verify_lod_sky (COSMOS-LOD-SKY task 2: phases/terminator/moonshine/scatter/tint) ===")
	print("  flags: SKY_MOONSHINE=%s SKY_SCATTER_RAMP=%s SHELL_TERMINATOR_TINT=%s (gate is flag-independent)"
		% [str(CubeSphere.SKY_MOONSHINE), str(CubeSphere.SKY_SCATTER_RAMP), str(CubeSphere.SHELL_TERMINATOR_TINT)])
	_gate_moon_phase()
	_gate_terminator()
	_gate_moonshine()
	_gate_scatter()
	_gate_shell_tint()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ G-MOON-PHASE
func _gate_moon_phase() -> void:
	print("  --- G-MOON-PHASE: f=(1+cos ψ)/2 over a synodic month, quarter⇒elongation 90°, bright limb ---")
	# f == (1+cos ψ)/2 exactly (the two helpers agree) across several t.
	var agree := true
	for i in range(13):
		var t := 6000.0 * float(i)
		var psi := EPH.phase_angle("earth", "moon", "sun", t)
		var f := EPH.illuminated_fraction("earth", "moon", "sun", t)
		if _rel(f, 0.5 * (1.0 + cos(psi))) > 1.0e-9:
			agree = false
	_ok(agree, "illuminated_fraction == (1+cos ψ)/2 (definitional agreement)")

	# Synodic month from the sidereal month + year: T_syn = 1/(1/T_moon − 1/T_year).
	var t_moon := EPH.orbit_period("moon")
	var t_year := EPH.orbit_period("earth")
	var t_syn := 1.0 / (1.0 / t_moon - 1.0 / t_year)
	_ok(absf(t_syn / EPH.DAY_GAME - 29.5) < 0.6, "synodic month = %.2f game-days ≈ 29.5" % (t_syn / EPH.DAY_GAME))

	# Sweep two synodic months: full moon (f→1) at t≈0 and t≈T_syn; new moon (f→0) at t≈T_syn/2.
	var steps := 4000
	var f_min := 2.0
	var f_max := -1.0
	var t_min := 0.0
	var next_full_t := 0.0
	var next_full_f := -1.0
	for i in range(steps + 1):
		var t := 2.0 * t_syn * float(i) / float(steps)
		var f := EPH.illuminated_fraction("earth", "moon", "sun", t)
		if f < f_min:
			f_min = f; t_min = t
		if f > f_max:
			f_max = f
		# track the largest f inside a window centred on the expected second full moon
		if t > 0.5 * t_syn and t < 1.5 * t_syn and f > next_full_f:
			next_full_f = f; next_full_t = t
	_ok(f_max > 0.98, "full moon reached (max f = %.4f > 0.98)" % f_max)
	_ok(f_min < 0.02, "new moon reached (min f = %.4f < 0.02)" % f_min)
	_ok(absf(t_min - 0.5 * t_syn) / t_syn < 0.05, "new moon at ~half a synodic month (t_min/T_syn = %.3f)" % (t_min / t_syn))
	_ok(_rel(next_full_t, t_syn) < 0.03, "successive full moons spaced one synodic period (%.0f vs %.0f s)" % [next_full_t, t_syn])

	# Quarter phase (f≈0.5) ⇒ solar elongation ≈ 90°.
	var t_quarter := 0.0
	var best := 1.0
	for i in range(steps + 1):
		var t := t_syn * float(i) / float(steps)
		var f := EPH.illuminated_fraction("earth", "moon", "sun", t)
		if absf(f - 0.5) < best:
			best = absf(f - 0.5); t_quarter = t
	var elong_deg := rad_to_deg(EPH.elongation("earth", "moon", "sun", t_quarter))
	_ok(absf(elong_deg - 90.0) < 2.0, "quarter phase -> elongation %.2f deg ~ 90" % elong_deg)

	# Bright limb at the quarter: unit vector, ⊥ the Earth→Moon line of sight, pointing sunward.
	var blimb := EPH.bright_limb_dir("earth", "moon", "sun", t_quarter)
	var m_hat := EPH.dir_to("earth", "moon", t_quarter)
	var s_hat := EPH.dir_to("earth", "sun", t_quarter)
	_ok(absf(blimb.length() - 1.0) < 1.0e-5, "bright-limb direction is a unit vector")
	_ok(absf(blimb.dot(m_hat)) < 1.0e-5, "bright limb perpendicular to line of sight (dot = %s)" % blimb.dot(m_hat))
	_ok(blimb.dot(s_hat) > 0.0, "bright limb points sunward (dot = %.3f > 0)" % blimb.dot(s_hat))

# ------------------------------------------------------------------ G-TERMINATOR
func _gate_terminator() -> void:
	print("  --- G-TERMINATOR: day/night boundary is the great circle ⊥ sun_dir (surface==orbit) ---")
	# Use a real ephemeris Sun direction (body-fixed, the one CosmosSky lights + ramps with).
	var sun := EPH.dir_to_bodyfixed("earth", "sun", 12345.0)
	if sun == Vector3.ZERO:
		sun = Vector3(1, 0, 0)
	sun = sun.normalized()

	# Day side (surface normal along +sun) is lit, night side (−sun) dark: sun·n sign == surface ramp sign.
	_ok(sun.dot(sun) > 0.0, "sub-solar point lit (sun·n = 1 > 0)")
	_ok(sun.dot(-sun) < 0.0, "anti-solar point dark (sun·n = −1 < 0)")

	# The lit/dark boundary is where sun·n = 0. Sweep several great circles through the sphere and find the
	# zero crossing; assert the crossing normal is ⊥ sun (== 90° ± 1°) — the terminator great circle, identical
	# for the surface ramp (n = local up) and the orbit-view shell shading (n = vertex normal): one Sun, two views.
	var axes := [Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0.3, 0.7, 0.64), Vector3(-0.5, 0.2, 0.84)]
	var worst_deg := 0.0
	for ax_raw in axes:
		var ax: Vector3 = (ax_raw as Vector3).normalized()
		# build an orthonormal basis (u, w) spanning a great circle; n(θ) = cosθ·u + sinθ·w.
		var u := sun.cross(ax)
		if u.length() < 1.0e-4:
			continue
		u = u.normalized()
		var w := sun.cross(u).normalized()
		var prev := sun.dot(u)          # θ=0
		var steps := 720
		for i in range(1, steps + 1):
			var th := TAU * float(i) / float(steps)
			var n := (u * cos(th) + w * sin(th)).normalized()
			var d := sun.dot(n)
			if (prev <= 0.0 and d > 0.0) or (prev >= 0.0 and d < 0.0):
				# linear-interpolate the crossing normal and measure its angle to the Sun
				var frac := prev / (prev - d)
				var th_c := TAU * (float(i - 1) + frac) / float(steps)
				var n_c := (u * cos(th_c) + w * sin(th_c)).normalized()
				worst_deg = maxf(worst_deg, absf(rad_to_deg(sun.angle_to(n_c)) - 90.0))
			prev = d
	_ok(worst_deg <= 1.0, "terminator crossing ⊥ sun_dir within %.4f° ≤ 1°" % worst_deg)

# ------------------------------------------------------------------ G-SKY-MOONSHINE
func _gate_moonshine() -> void:
	print("  --- G-SKY-MOONSHINE: ambient = gain·f·moon_up·night; eclipse dims/reddens ---")
	# Zeros: new moon (f=0), day (night=0), moon down (moon_up=0).
	_ok(SKY.moonshine_energy(0.0, 1.0, 1.0) == 0.0, "0 at new moon (f=0)")
	_ok(SKY.moonshine_energy(1.0, 1.0, 0.0) == 0.0, "0 by day (night_authority=0)")
	_ok(SKY.moonshine_energy(1.0, 0.0, 1.0) == 0.0, "0 with the Moon below the horizon (moon_up=0)")
	# Full moon, high, deep night == the gain.
	_ok(_rel(SKY.moonshine_energy(1.0, 1.0, 1.0), SKY.MOONSHINE_GAIN) < 1.0e-9, "full moon high at night == MOONSHINE_GAIN")
	# Monotone + continuous in f (C¹ — the term is linear in each argument).
	var mono := true
	var cont := true
	var prev := -1.0
	for i in range(0, 101):
		var f := float(i) / 100.0
		var e := SKY.moonshine_energy(f, 0.8, 0.7)
		if e < prev - 1.0e-12: mono = false
		if prev >= 0.0 and absf(e - prev) > 0.02: cont = false
		prev = e
	_ok(mono, "monotone ↑ in illuminated fraction")
	_ok(cont, "continuous (C¹) in f")

	# Lunar eclipse: at t=0 the Moon is full AND (incl=0 model) squarely in Earth's umbra ⇒ factor 0; at the
	# new-moon time it is on the sunlit side ⇒ factor 1. In between the factor stays within [0,1].
	var ecl0 := SKY.moon_eclipse_factor(0.0)
	var t_new := 0.5 * (1.0 / (1.0 / EPH.orbit_period("moon") - 1.0 / EPH.orbit_period("earth")))
	var ecl_new := SKY.moon_eclipse_factor(t_new)
	_ok(ecl0 == 0.0, "eclipse factor == 0 at full-moon alignment (Moon in the umbra)")
	_ok(ecl_new == 1.0, "eclipse factor == 1 at new moon (Moon sunlit)")
	var in_range := true
	for i in range(0, 201):
		var t := t_new * 2.0 * float(i) / 200.0
		var e := SKY.moon_eclipse_factor(t)
		if e < 0.0 or e > 1.0: in_range = false
	_ok(in_range, "eclipse factor stays within [0,1] across the month")
	# The eclipse dims moonshine: eclipsed effective fraction < clear.
	var clear := SKY.moonshine_energy(1.0 * 1.0, 1.0, 1.0)
	var eclipsed := SKY.moonshine_energy(1.0 * ecl0, 1.0, 1.0)
	_ok(eclipsed < clear, "eclipse dims the moonshine term (%.3f < %.3f)" % [eclipsed, clear])

# ------------------------------------------------------------------ G-SKY-SCATTER
func _gate_scatter() -> void:
	print("  --- G-SKY-SCATTER: T(μ)=exp(−τ·m(μ)) vs the real optical-depth table; red-ward monotone; off-identity ---")
	# Air mass endpoints (Kasten–Young): m(1)≈1 overhead, m(0)≈38 at the horizon.
	_ok(_rel(SKY.air_mass(1.0), 1.0) < 5.0e-3, "air_mass(μ=1) = %.4f ≈ 1 (overhead)" % SKY.air_mass(1.0))
	_ok(absf(SKY.air_mass(0.0) - 38.0) < 1.0, "air_mass(μ=0) = %.2f ≈ 38 (horizon)" % SKY.air_mass(0.0))

	# The design's sampled table (T as R,G,B): μ=sin(elev).
	var table := [
		[sin(deg_to_rad(30.0)), Color(0.92, 0.82, 0.61)],
		[sin(deg_to_rad(11.0)), Color(0.81, 0.61, 0.29)],
		[sin(deg_to_rad(5.0)),  Color(0.66, 0.37, 0.086)],
		[0.0,                   Color(0.20, 0.024, 0.0)],
	]
	for row in table:
		var mu: float = row[0]
		var want: Color = row[1]
		var got := SKY.scatter_tint(mu)
		var d := absf(got.r - want.r) + absf(got.g - want.g) + absf(got.b - want.b)
		_ok(d < 0.03, "scatter_tint(μ=%.3f) = (%.3f,%.3f,%.3f) ≈ (%.3f,%.3f,%.3f)" % [mu, got.r, got.g, got.b, want.r, want.g, want.b])

	# Monotone in μ (each channel down as μ down / air mass up) AND blue extinguished fastest (red-ward hue).
	# The hue metric is the CHANNEL RATIO B/R = exp(-(τ_B-τ_R)·m): it falls monotonically as μ falls (blue lost
	# first) — the absolute R-B can dip near the horizon because R itself darkens, so the ratio is the honest test.
	# Fine sweep (Δμ=0.002) so the C¹ continuity check is not fooled by the (steep but smooth) horizon air mass.
	var mono := true
	var cont := true
	var hue_redward := true
	var prev := SKY.scatter_tint(1.0)
	var prev_br := prev.b / maxf(prev.r, 1.0e-9)
	for i in range(499, -1, -1):       # μ from ~0.998 down to 0.0
		var mu := float(i) / 500.0
		var c := SKY.scatter_tint(mu)
		if c.r > prev.r + 1.0e-9 or c.g > prev.g + 1.0e-9 or c.b > prev.b + 1.0e-9:
			mono = false               # every channel decreases as μ falls
		if absf(c.r - prev.r) > 0.05 or absf(c.g - prev.g) > 0.05 or absf(c.b - prev.b) > 0.05:
			cont = false
		var br := c.b / maxf(c.r, 1.0e-9)
		if br > prev_br + 1.0e-9:       # B/R must not rise as μ falls (blue extinguished at least as fast)
			hue_redward = false
		prev = c
		prev_br = br
	_ok(mono, "every channel monotone down as mu falls (more air mass)")
	_ok(cont, "scatter_tint continuous (C1) across mu")
	_ok(hue_redward, "hue shifts red-ward as mu falls (B/R falls, blue extinguished first)")

	# sunset_weight: 0 with the Sun high (plain day), 0 in deep night, > 0 near the horizon band.
	_ok(SKY.sunset_weight(0.9) == 0.0, "sunset_weight high sun == 0 (plain day)")
	_ok(SKY.sunset_weight(-0.3) == 0.0, "sunset_weight deep night == 0")
	_ok(SKY.sunset_weight(0.1) > 0.0, "sunset_weight in the horizon band > 0")

	# Off-identity: with SKY_SCATTER_RAMP off, _ramp_environment leaves the shipped two-colour lerp byte-identical
	# at a low-sun (sunset) geometry.
	var env := Environment.new()
	var sky := SKY.new()
	get_root().add_child(sky)
	sky.setup(EPH.CosmosClock.new(), env, null)
	var cam := Vector3(0.0, 0.0, float(EPH.radius_of("earth")))    # on the +Z surface, up = +Z
	var sun_low := Vector3(0.02, 0.0, 0.06).normalized()           # a few degrees above the horizon
	sky._ramp_environment(sun_low, cam)
	var elev := clampf(sun_low.dot(Vector3(0, 0, 1)), -1.0, 1.0)
	var twilight := clampf((elev + 0.15) / 0.30, 0.0, 1.0)
	var want_sky := SKY._SKY_NIGHT.lerp(SKY._SKY_DAY, twilight)
	if CubeSphere.SKY_SCATTER_RAMP:
		_ok(true, "off-identity skipped (SKY_SCATTER_RAMP compiled ON)")
	else:
		_ok(env.background_color.is_equal_approx(want_sky), "flag-off: sunset background == shipped two-colour lerp")
	sky.queue_free()

# ------------------------------------------------------------------ G-SHELL-TINT
func _gate_shell_tint() -> void:
	print("  --- G-SHELL-TINT: per-vertex tint == mix(white, scatter_tint(μ), band(μ)); off ⇒ StandardMaterial ---")
	# The GDScript twin the shell shader mirrors. Full day (μ=0.5): band 0 ⇒ tint white (ALBEDO unchanged).
	var t_day := SKY.shell_terminator_tint(0.5)
	_ok(t_day.is_equal_approx(Color.WHITE), "full-day μ=0.5 ⇒ tint == white (shell unchanged)")
	# Terminator (μ=0): band 1 ⇒ tint == scatter_tint(0) (deep crimson).
	var t_term := SKY.shell_terminator_tint(0.0)
	_ok(t_term.is_equal_approx(SKY.scatter_tint(0.0)), "terminator μ=0 ⇒ tint == scatter_tint(0) (crimson)")
	# Deep night (μ=−0.3): band 0 ⇒ white (no tint applied to the dark side).
	_ok(SKY.shell_terminator_tint(-0.3).is_equal_approx(Color.WHITE), "deep night μ=−0.3 ⇒ tint == white")
	# Sampled equality tint == mix(white, scatter_tint, band).
	var eq := true
	for i in range(0, 41):
		var mu := -0.2 + 0.4 * float(i) / 40.0
		var want := Color.WHITE.lerp(SKY.scatter_tint(mu), SKY.scatter_band(mu))
		if not SKY.shell_terminator_tint(mu).is_equal_approx(want):
			eq = false
	_ok(eq, "shell_terminator_tint(μ) == mix(white, scatter_tint(μ), band(μ)) across the band")

	# Material identity: off ⇒ a plain StandardMaterial3D (byte-identical shell); on ⇒ the tint ShaderMaterial
	# with a sun_dir uniform. Matches the compiled flag either way (flag-independent).
	var ring := RING.new()
	get_root().add_child(ring)
	var mat := ring._make_material()
	if CubeSphere.SHELL_TERMINATOR_TINT:
		_ok(mat is ShaderMaterial, "flag ON: far-ring material is the tint ShaderMaterial")
		var has_uniform := (mat as ShaderMaterial).get_shader_parameter("sun_dir") != null
		_ok(has_uniform, "flag ON: material carries the sun_dir uniform")
	else:
		_ok(mat is StandardMaterial3D, "flag OFF: far-ring material is the shipped StandardMaterial3D (byte-identical)")
		_ok(not (mat is ShaderMaterial), "flag OFF: no shell shader present")
	ring.queue_free()
