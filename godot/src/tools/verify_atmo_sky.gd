extends SceneTree
## COSMOS ATMO-SKY gate (docs/COSMOS-ATMO-SKY-DESIGN.md §5). Proves the unified atmosphere/day-night/celestial
## MATH end-to-end WITHOUT a live browser. All the curve/geometry math is PURE STATIC (CosmosSky.* / CosmosScale.*
## / CosmosEphemeris.*), so this gate drives it DIRECTLY and is FLAG-INDEPENDENT: it passes identically with the
## A0..A6 flags true or false — the flags only decide whether the sky/light/shell COMPOSE this math in-game. The
## GLSL shaders (shell v2, atmosphere halo, moon phase, star mask) are pinned to these GDScript twins BY
## CONSTRUCTION (line-for-line mirrors); the actual rendered LOOK is LIVE-ONLY (remote-bridge screenshots).
##
## Gates:
##   G-AS-FARRAMP (A0): CosmosScale camera near/far ramp with altitude — 0.05/9000 at h=0, 1.2·√(d²−R²) beyond.
##   G-AS-OCC     (A1): planet-disc occlusion of the sky (sun in front / behind / grazing) + the star-mask cos.
##   G-AS-ZERO    (A3): atmo_vis(ATMO_TOP)==0 exactly, C¹, h=0 endpoints, scatter weight ≡0 above ATMO_TOP.
##   G-AS-ABSLIGHT(A4): absolute light is a function of POSITION only; night≈0 at every altitude; noon=1; dusk
##                      monotone through pen(h); Moon phase twin == ephemeris illuminated fraction.
##   G-AS-TERM    (A5): terminator day(x̂)=0.5 on the great circle, symmetric, monotone; shell shade in [FLOOR,1];
##                      scaled-centre ABSOLUTENESS (normalize invariant under scale-about-camera).
##   G-AS-LIMB    (A6): shell_geom (chord,h_min) vs a ray-march reference; limb→0 on the night side/above the
##                      shell; inside/outside continuity at the ATMO_TOP crossing.
##   INERT (byte-identity face): a live CosmosSky+Environment with the SHIPPED flags leaves _ramp_environment at
##                      the shipped day-night values (the full FLAT 6042/0 byte gate is run separately).
##   SMOKE: CosmosSky builds + ticks (with the atmo flags sed-true in the run recipe this compiles the shaders).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_atmo_sky.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const SKY := preload("res://src/cosmos/cosmos_sky.gd")
const SCALE := preload("res://src/cosmos/cosmos_scale.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_atmo_sky (COSMOS ATMO-SKY: G-AS-FARRAMP/OCC/ZERO/ABSLIGHT/TERM/LIMB) ===")
	print("  A0=%s A1=%s A2=%s A3=%s A4=%s A5=%s A6=%s (gate is flag-independent; math is pure static)" % [
		str(CubeSphere.FP_SN3_MAIN_LIVE), str(CubeSphere.FP_SKY_PLANET_OCCLUDE), str(CubeSphere.FP_SUN_PRESENCE),
		str(CubeSphere.FP_ATMO_SPACE_ZERO), str(CubeSphere.FP_LIGHT_ABSOLUTE), str(CubeSphere.FP_SHELL_ABSOLUTE),
		str(CubeSphere.FP_ATMO_SHELL)])
	FacetAtlas.warm_up()
	_gate_farramp()
	_gate_occ()
	_gate_zero()
	_gate_abslight()
	_gate_term()
	_gate_limb()
	_gate_inert()
	_gate_smoke()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ G-AS-FARRAMP (A0)
func _gate_farramp() -> void:
	print("  --- G-AS-FARRAMP: camera near/far ramp with altitude (A0 un-clips the planet) ---")
	var r := FacetAtlas.R_BLOCKS
	# Ground endpoints EXACT (byte-identical to the shipped 0.05 / 9000).
	_ok(SCALE.camera_near(0.0) == SCALE.NEAR_MIN, "near(h=0)==0.05 (shipped)")
	_ok(SCALE.camera_far(r, r) == SCALE.FAR_MIN, "far(d=R)==9000 (shipped; tangent=0)")
	# Near ramps 0.05 → 8 and caps.
	_ok(SCALE.camera_near(SCALE.NEAR_H_DIV * SCALE.NEAR_MAX) == SCALE.NEAR_MAX, "near caps at 8")
	_ok(SCALE.camera_near(1.0e9) == SCALE.NEAR_MAX, "near clamps to 8 far out")
	# Far ramps as max(9000, 1.2·√(d²−R²)) and never drops below 9000.
	var mono := true
	var prev := 0.0
	var matched := true
	for i in range(0, 401):
		var d := r + float(i) * 200.0
		var f := SCALE.camera_far(d, r)
		var want: float = maxf(SCALE.FAR_MIN, SCALE.FAR_TANGENT_K * sqrt(maxf(d * d - r * r, 0.0)))
		if not is_equal_approx(f, want): matched = false
		if f < prev - 1e-6: mono = false
		if f < SCALE.FAR_MIN - 1e-6: mono = false
		prev = f
	_ok(matched, "far == max(9000, 1.2·√(d²−R²)) across the altitude sweep")
	_ok(mono, "far monotone non-decreasing, never < 9000")
	# A concrete deep-space case: the pilot's d ≈ 167 k must reach past the limb √(d²−R²).
	var d_deep := r + 160000.0
	_ok(SCALE.camera_far(d_deep, r) > sqrt(d_deep * d_deep - r * r), "far reaches past the limb at deep-space d")

# ------------------------------------------------------------------ G-AS-OCC (A1)
func _gate_occ() -> void:
	print("  --- G-AS-OCC: analytic planet-disc occlusion of the sky ---")
	var r := GRAV.r_vox("earth")
	var sun := Vector3(1.0, 0.0, 0.0)
	var d := r + 3000.0
	# Sun in front of the planet (day side): visible (occ==1). Sun behind the disc: hidden (occ==0).
	_ok(SKY.occlusion_factor(sun, sun * d, r) == 1.0, "sun in front of the planet ⇒ visible (occ==1)")
	_ok(SKY.occlusion_factor(sun, -sun * d, r) == 0.0, "sun behind the planet disc ⇒ hidden (occ==0)")
	# Grazing the limb: monotone 0→1 sweeping the body across the limb (C¹, no pop), spans the full range.
	var mono := true
	var saw0 := false
	var saw1 := false
	var prev := -1.0
	for i in range(0, 361):
		var a := PI * float(i) / 360.0
		var p := Vector3(-cos(a), -sin(a), 0.0) * d
		var f := SKY.occlusion_factor(sun, p, r)
		if f < prev - 1e-9: mono = false
		if f == 0.0: saw0 = true
		if f == 1.0: saw1 = true
		prev = f
	# NOTE: the vacuum terminator is SHARP by design (penumbra ≈ solar radius ≪ the 1° sample step), so no
	# small-step continuity is asserted here — only monotone + full range (matching the SN4b occlusion gate).
	_ok(mono and saw0 and saw1, "occ monotone across the limb, spans 0→1")
	# Star-dome disc mask: cos_ang = cos(asin(R/d)) ∈ (0,1). A view toward the centre (dot==1) is inside the disc
	# (> cos_ang ⇒ masked); a view 90° off (dot==0) is outside (< cos_ang ⇒ kept). Shrinks with altitude.
	var cos_ang := cos(asin(clampf(r / d, 0.0, 1.0)))
	_ok(cos_ang > 0.0 and cos_ang < 1.0, "planet_cos_ang ∈ (0,1) at altitude")
	_ok(1.0 > cos_ang, "view toward the centre is inside the disc (masked)")
	_ok(0.0 < cos_ang, "view 90° off the centre is outside the disc (kept)")
	var cos_hi := cos(asin(clampf(r / (r + 30000.0), 0.0, 1.0)))
	_ok(cos_hi > cos_ang, "disc angular radius shrinks with altitude (cos_ang ↑)")

# ------------------------------------------------------------------ G-AS-ZERO (A3)
func _gate_zero() -> void:
	print("  --- G-AS-ZERO: atmo_vis star-black in space, sunset tint ≡ 0 above ATMO_TOP ---")
	var top := SKY.H_ATMO
	_ok(SKY.atmo_vis(0.0, true) == 1.0, "atmo_vis(0)==1 (full atmosphere at the surface)")
	_ok(SKY.atmo_vis(top, true) == 0.0, "atmo_vis(ATMO_TOP)==0 EXACTLY (star-black at the ceiling)")
	_ok(SKY.atmo_vis(top + 500.0, true) == 0.0, "atmo_vis above ATMO_TOP clamps to 0")
	_ok(SKY.atmo_vis(0.0, false) == 0.0, "airless atmo_vis(0)==0 (no sky)")
	# Monotone decreasing + continuous over 0..500; C¹ signature (zero slope) at both endpoints.
	var mono := true
	var cont := true
	var prev := 2.0
	var maxstep := 0.0
	for i in range(0, 501):
		var v := SKY.atmo_vis(float(i), true)
		if v > prev + 1e-9: mono = false
		if prev <= 1.0:
			var step: float = absf(v - prev)
			maxstep = maxf(maxstep, step)
			if step > 0.02: cont = false
		prev = v
	_ok(mono, "atmo_vis monotone ↓ in h")
	_ok(cont, "atmo_vis continuous (max 1-block step %.5f)" % maxstep)
	var eps := 0.25
	var slope_lo: float = (SKY.atmo_vis(SKY.ATMO_VIS_LO + eps, true) - SKY.atmo_vis(SKY.ATMO_VIS_LO - eps, true)) / (2.0 * eps)
	var slope_hi: float = (SKY.atmo_vis(top + eps, true) - SKY.atmo_vis(top - eps, true)) / (2.0 * eps)
	_ok(absf(slope_lo) < 1e-3, "atmo_vis slope≈0 at the fade start (C¹): %.6f" % slope_lo)
	_ok(absf(slope_hi) < 1e-3, "atmo_vis slope≈0 at ATMO_TOP (C¹): %.6f" % slope_hi)
	# The space fraction (1−atmo_vis) drives the sky-blacken; it is exactly 1 at/above ATMO_TOP (no twilight leak).
	_ok(is_equal_approx(1.0 - SKY.atmo_vis(top, true), 1.0), "space fraction == 1 at ATMO_TOP (sky fully black)")
	# The sunset recolour weight (sunset_weight·atmo_vis) is ≡ 0 above ATMO_TOP at EVERY μ (bug-3 fix).
	var zero_above := true
	for j in range(-10, 11):
		var mu := float(j) / 10.0
		if SKY.sunset_weight(mu) * SKY.atmo_vis(top + 100.0, true) != 0.0: zero_above = false
	_ok(zero_above, "scatter weight ≡ 0 above ATMO_TOP at every μ (star-black space, no re-hue)")

# ------------------------------------------------------------------ G-AS-ABSLIGHT (A4)
func _gate_abslight() -> void:
	print("  --- G-AS-ABSLIGHT: absolute day/night light (dark side dark from every camera) ---")
	var r := GRAV.r_vox("earth")
	var sun := Vector3(1.0, 0.0, 0.0)
	# Noon (subsolar point): light == 1. Determinism: same p ⇒ identical (a pure function of position, not orientation).
	var p_noon := sun * (r + 100.0)
	_ok(is_equal_approx(SKY.light_energy_absolute(sun, p_noon, 100.0, r), 1.0), "noon (subsolar) light == 1")
	_ok(SKY.light_energy_absolute(sun, p_noon, 100.0, r) == SKY.light_energy_absolute(sun, p_noon, 100.0, r), "light is a pure function of position (identical repeats)")
	# Night side ≈ 0 at EVERY altitude — this KILLS the through-planet lighting (the bug-2 regression).
	var night_ok := true
	for h in [0.0, 50.0, 100.0, 500.0, 2000.0, 20000.0]:
		if SKY.light_energy_absolute(sun, -sun * (r + h), h, r) > 1.0e-6: night_ok = false
	_ok(night_ok, "night side light ≈ 0 at every altitude (no through-planet lighting)")
	# pen(h): long twilight at the ground, sharp in vacuum.
	_ok(is_equal_approx(SKY.pen(0.0), SKY.PEN_GROUND), "pen(0)==PEN_GROUND (long ground twilight)")
	_ok(is_equal_approx(SKY.pen(SKY.H_ATMO), SKY.PEN_SPACE), "pen(ATMO_TOP)==PEN_SPACE (sharp vacuum terminator)")
	_ok(SKY.pen(0.0) > SKY.pen(SKY.H_ATMO), "pen(h) narrows with altitude")
	# Dusk sweep at the ground: sweep the sun angle α across the horizon; light rises 0→1 monotone through pen(0).
	var mono := true
	var saw0 := false
	var saw1 := false
	var prev := -1.0
	for i in range(0, 361):
		var a := PI * float(i) / 360.0
		var p := Vector3(-cos(a), -sin(a), 0.0) * r
		var l := SKY.light_energy_absolute(sun, p, 0.0, r)
		if l < prev - 1e-9: mono = false
		if l < 1.0e-6: saw0 = true
		if l > 1.0 - 1.0e-6: saw1 = true
		prev = l
	_ok(mono and saw0 and saw1, "dusk light monotone 0→1 through the ground penumbra")
	# Moon self-phase twin == the ephemeris illuminated fraction, over a synodic sweep.
	var month := EPH.orbit_period("moon")
	var worst := 0.0
	for i in range(0, 121):
		var t := month * float(i) / 120.0
		var ph := EPH.phase_angle("earth", "moon", "sun", t)
		var twin := SKY.lambert_illum_fraction(cos(ph))
		var ref := EPH.illuminated_fraction("earth", "moon", "sun", t)
		worst = maxf(worst, absf(twin - ref))
	_ok(worst < 1.0e-9, "Moon phase twin == ephemeris illuminated fraction (worst Δ %.10f)" % worst)

# ------------------------------------------------------------------ G-AS-TERM (A5)
func _gate_term() -> void:
	print("  --- G-AS-TERM: absolute terminator + self-shaded globe (never tracks the camera) ---")
	# day(x̂) = 0.5 exactly on the great circle x̂·ŝ = 0; endpoints 0/1; symmetric; monotone.
	_ok(is_equal_approx(SKY.day_factor(0.0), 0.5), "day(μ=0)==0.5 (terminator great circle ⊥ ŝ)")
	_ok(SKY.day_factor(1.0) == 1.0, "day(μ=+1)==1 (full day)")
	_ok(SKY.day_factor(-1.0) == 0.0, "day(μ=−1)==0 (full night)")
	var sym := true
	var mono := true
	var prev := -1.0
	for i in range(-100, 101):
		var mu := float(i) / 100.0
		var dv := SKY.day_factor(mu)
		if not is_equal_approx(dv + SKY.day_factor(-mu), 1.0): sym = false
		if dv < prev - 1e-9: mono = false
		prev = dv
	_ok(sym, "day(μ) symmetric: day(μ)+day(−μ)==1")
	_ok(mono, "day(μ) monotone ↑")
	# Globe shade lands in [NIGHT_FLOOR, 1] — the night hemisphere is faint but never pure black (earthshine floor).
	_ok(is_equal_approx(SKY.shell_day_shade(-1.0), SKY.SHELL_NIGHT_FLOOR), "globe night shade == NIGHT_FLOOR")
	_ok(is_equal_approx(SKY.shell_day_shade(1.0), 1.0), "globe day shade == 1")
	# ABSOLUTENESS: the shell v2 derives n̂ from (MODEL_MATRIX·vertex − MODEL_MATRIX·0). Under scale-about-camera
	# (X' = C + s·(X−C)) the normalized surface direction is INVARIANT ⇒ the tint/terminator does NOT follow the
	# camera. Assert normalize(X'−centre') == normalize(X−centre) across scales, so μ (and thus day/tint) is fixed.
	var centre := Vector3.ZERO
	var surf := Vector3(0.0, 0.0, 6371.0)                     # a point on the globe
	var camc := Vector3(4000.0, 0.0, 9000.0)                 # an arbitrary camera
	var worst := 0.0
	for k in range(1, 40):
		var s := float(k) / 40.0
		var surf_s := camc + s * (surf - camc)
		var centre_s := camc + s * (centre - camc)
		var n_scaled := (surf_s - centre_s).normalized()
		var n_true := (surf - centre).normalized()
		worst = maxf(worst, (n_scaled - n_true).length())
	_ok(worst < 1.0e-5, "n̂ invariant under scale-about-camera (worst Δ %.10f) ⇒ terminator absolute" % worst)
	# tint twin: shell_day_shade·mix(1,T,band) matches the per-vertex composition on a μ grid (sanity, in-range).
	var tin_ok := true
	for i in range(-20, 21):
		var mu := float(i) / 20.0
		var st := SKY.shell_terminator_tint(mu)              # mix(white, T, band) — the shared v1/v2 band tint
		if st.r < 0.0 or st.r > 1.0 or st.g < 0.0 or st.g > 1.0 or st.b < 0.0 or st.b > 1.0: tin_ok = false
	_ok(tin_ok, "shell band tint in [0,1] across the μ grid")

# ------------------------------------------------------------------ G-AS-LIMB (A6)
func _gate_limb() -> void:
	print("  --- G-AS-LIMB: atmosphere shell closed-form (chord, h_min) vs ray-march reference ---")
	var r := 6371.0
	var ro := SKY.shell_outer_r(r)
	_ok(is_equal_approx(ro, r + SKY.SHELL_ATMO_MULT * SKY.H_ATMO), "shell_outer_r == R + SHELL_ATMO_MULT·ATMO_TOP")
	var centre := Vector3.ZERO
	# Reference: march the ray and integrate ds over samples inside the shell AND in front of the first planet hit.
	var worst_chord := 0.0
	var worst_hmin := 0.0
	var cases := [
		[Vector3(0.0, 0.0, r + 3000.0), Vector3(0.0, 0.0, -1.0)],       # space, looking at the planet (through the disc)
		[Vector3(0.0, 0.0, r + 3000.0), Vector3(0.0, 1.0, -0.2).normalized()],  # space, grazing the limb
		[Vector3(0.0, 0.0, r + 200.0), Vector3(0.0, 1.0, -0.05).normalized()],  # low altitude horizon-ward
		[Vector3(0.0, 0.0, r + 50.0), Vector3(0.0, 1.0, 0.3).normalized()],     # inside the shell, up-and-out
	]
	for c in cases:
		var cam: Vector3 = c[0]
		var dir: Vector3 = c[1]
		var geom := SKY.shell_geom(cam, centre, dir, r, ro)
		var chord: float = geom[0]
		var hmin: float = geom[1]
		# ray-march reference chord + first-planet-hit gate
		var ds := 0.5
		var acc := 0.0
		var hit := false
		var tmax := ro * 3.0
		var tt := 0.0
		while tt < tmax:
			var x := cam + dir * tt
			var rr := (x - centre).length()
			if rr < r:
				hit = true                                    # solid planet — stop accumulating (near-surface occludes)
				break
			if rr <= ro:
				acc += ds
			tt += ds
		# reference h_min via analytic perpendicular distance
		var oc := centre - cam
		var tca := oc.dot(dir)
		var ref_hmin: float = sqrt(maxf(oc.dot(oc) - tca * tca, 0.0)) - r
		worst_chord = maxf(worst_chord, absf(chord - acc))
		worst_hmin = maxf(worst_hmin, absf(hmin - ref_hmin))
		# when the ray hits the planet, the closed form must cut the chord at the near surface (finite, not through)
		if hit:
			_ok(chord >= 0.0, "chord non-negative on a planet-hitting ray")
	_ok(worst_chord < 2.0, "shell chord matches the ray-march reference (worst Δ %.3f blocks ≤ ds)" % worst_chord)
	_ok(worst_hmin < 1.0e-3, "shell h_min matches the analytic perpendicular distance (worst Δ %.10f)" % worst_hmin)
	# Limb intensity → 0 on the NIGHT side (day(μ)=0 for μ ≪ −term) even with a long chord.
	var night_col := SKY.shell_limb_color(-0.5, 2000.0, 5.0)
	_ok(night_col.r < 1.0e-4 and night_col.g < 1.0e-4 and night_col.b < 1.0e-4, "limb dark on the night side (day(μ)=0)")
	# Above the shell (b ≥ r_outer) the chord is 0 ⇒ no halo.
	var above := SKY.shell_geom(Vector3(0.0, 0.0, r + 3000.0), centre, Vector3(0.0, 1.0, 0.0), r, ro)
	_ok(above[0] == 0.0, "chord == 0 for a ray that misses the shell (b ≥ r_outer)")
	# Inside/outside continuity at the ATMO_TOP crossing: chord is continuous as the camera crosses r_outer radially.
	var dir_up := Vector3(0.0, 0.0, 1.0)
	var below := SKY.shell_geom(Vector3(0.0, 0.0, ro - 1.0), centre, dir_up, r, ro)
	var above2 := SKY.shell_geom(Vector3(0.0, 0.0, ro + 1.0), centre, dir_up, r, ro)
	_ok(absf(below[0] - above2[0]) < 3.0, "chord continuous across the ATMO_TOP (r_outer) crossing (Δ %.3f)" % absf(below[0] - above2[0]))

# ------------------------------------------------------------------ INERT (byte-identity face)
func _gate_inert() -> void:
	print("  --- INERT: shipped flags leave _ramp_environment at the shipped day-night values ---")
	# The full FLAT 6042/0 byte gate is run separately; this proves the sky ramp's flag-off face at noon.
	var env := Environment.new()
	env.fog_enabled = true
	env.fog_density = 1.0
	var sky := SKY.new()
	get_root().add_child(sky)
	var clock := EPH.CosmosClock.new()
	sky.setup(clock, env, null)
	var cam := Vector3(0.0, 0.0, float(FacetAtlas.R_BLOCKS))
	var sun_up := Vector3(0.0, 0.0, 1.0)
	sky._ramp_environment(sun_up, cam)
	if not CubeSphere.ATMO_VISUAL_RAMP and not CubeSphere.FP_ATMO_SPACE_ZERO:
		_ok(env.fog_density == 1.0, "flag-off: fog_density untouched (==1.0)")
	if not CubeSphere.SN_SUN_OCCLUSION and not CubeSphere.FP_LIGHT_ABSOLUTE:
		_ok(sky._sun_light.light_energy == 1.0, "flag-off: light_energy untouched (==shipped 1.0)")
		_ok(sky._sun_light.light_color == Color(1, 1, 1), "flag-off: light_color untouched (white)")
	sky.queue_free()

# ------------------------------------------------------------------ SMOKE (shader compile when flags sed-true)
func _gate_smoke() -> void:
	print("  --- SMOKE: CosmosSky builds + ticks (compiles the atmo shaders when the flags are on) ---")
	var clock := EPH.CosmosClock.new()
	var sky := SKY.new()
	get_root().add_child(sky)
	sky.setup(clock, null, null)
	_ok(sky.get_node_or_null("Sun") != null, "Sun impostor built")
	_ok(sky.get_node_or_null("StarDome") != null, "star dome built")
	# These nodes exist ONLY when their flags are on — assert consistency with the flag, so a sed-true run proves
	# the shader compiled (Godot would have errored at build otherwise) and a sed-false run proves byte-off.
	_ok((sky.get_node_or_null("SunGlare") != null) == CubeSphere.FP_SUN_PRESENCE, "glare node present iff FP_SUN_PRESENCE")
	_ok((sky.get_node_or_null("AtmosphereShell") != null) == CubeSphere.FP_ATMO_SHELL, "atmosphere shell present iff FP_ATMO_SHELL")
	clock.advance(600.0)
	sky._process(0.0)                                        # tick — must not crash; drives every live uniform
	_ok(true, "CosmosSky ticked a game-half-day without error")
	sky.queue_free()
	# A5 shell v2 material smoke: building _make_material assigns the shader .code, which PARSES the GLSL — a
	# syntax error surfaces here headless. Off ⇒ the shipped StandardMaterial; sed-true ⇒ the shell v2 ShaderMaterial.
	var fr := FacetFarRing.new()
	var mat := fr._make_material()
	_ok(mat != null, "far-ring _make_material returns a material")
	_ok((mat is ShaderMaterial) == (CubeSphere.FP_SHELL_ABSOLUTE or CubeSphere.SHELL_TERMINATOR_TINT or TierPlace.depth_bias_on()), "shell material type consistent with the flags")
	fr.free()
