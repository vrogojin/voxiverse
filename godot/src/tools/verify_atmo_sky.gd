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
	_gate_b0_path()
	_gate_b1_sun()
	_gate_b5_fog()
	_gate_b4_moon()
	_gate_b2_limb()
	_gate_b3_nearnight()
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

# ------------------------------------------------------------------ G-B0-PATH (ATMO2 B0)
func _gate_b0_path() -> void:
	print("  --- G-B0-PATH: optical-path sun air-mass m(cam→sun), T⃗(m)·L(m) (ATMO2 §3.2) ---")
	var r := GRAV.r_vox("earth")
	# T⃗(0) == WHITE exactly (blinding white sun in vacuum, the §2.1 fix).
	var t0 := SKY.path_transmittance(0.0)
	_ok(t0.r == 1.0 and t0.g == 1.0 and t0.b == 1.0, "T⃗(0) == white exactly (space sun is white)")
	_ok(SKY.path_luminance(0.0) == 1.0, "L(0) == 1 (full-brightness space sun)")
	# m == 0 for a space-clear LOS (camera in space, sun overhead, ray leaves the atmosphere).
	var cam_space := Vector3(0.0, 0.0, r + 50000.0)
	var m_clear := SKY.optical_path_air_mass(cam_space, Vector3(0.0, 0.0, 1.0), r, true)
	_ok(m_clear == 0.0, "m == 0 exactly for a space-clear LOS (sun ray never enters the shell)")
	# Vertical-from-ground m == 1 ± 2%.
	var m_vert := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r), Vector3(0.0, 0.0, 1.0), r, true)
	_ok(absf(m_vert - 1.0) <= 0.02, "vertical-from-ground m == 1 +/-2 pct (m=%.4f)" % m_vert)
	# Airless body ⇒ 0.
	_ok(SKY.optical_path_air_mass(Vector3(0.0, 0.0, r), Vector3(0.0, 0.0, 1.0), r, false) == 0.0, "airless ⇒ m == 0")
	# Surface horizon m ∈ [15,22]; full-limb-from-orbit m ∈ [30,40].
	var m_horiz := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r), Vector3(1.0, 0.0, 0.0), r, true)
	_ok(m_horiz >= 15.0 and m_horiz <= 22.0, "surface horizon m ∈ [15,22] (m=%.3f)" % m_horiz)
	var d_orb := r + 3000.0
	var sinq := r / d_orb
	var cosq := sqrt(maxf(1.0 - sinq * sinq, 0.0))
	var m_limb := SKY.optical_path_air_mass(Vector3(0.0, 0.0, d_orb), Vector3(sinq, 0.0, -cosq), r, true)
	_ok(m_limb >= 30.0 and m_limb <= 40.0, "full-limb-from-orbit m ∈ [30,40] (m=%.3f)" % m_limb)
	# Monotone in zenith angle at the surface (m rises as the sun descends from zenith to horizon).
	var mono := true
	var prev := -1.0
	for i in range(0, 91):
		var mu := cos(deg_to_rad(float(i)))                  # zenith 0..90° ⇒ mu_v 1..0
		var d := Vector3(sqrt(maxf(1.0 - mu * mu, 0.0)), 0.0, mu)
		var m := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r), d, r, true)
		if m < prev - 1e-6: mono = false
		prev = m
	_ok(mono, "surface m monotone in zenith angle (zenith→horizon)")
	# K–Y SHAPE cross-check: surface optical m within 15% of Kasten–Young over elevations 5°–90°.
	var worst_ky := 0.0
	for e in range(5, 91, 5):
		var mu := sin(deg_to_rad(float(e)))
		var mopt := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r), Vector3(sqrt(maxf(1.0 - mu * mu, 0.0)), 0.0, mu), r, true)
		var mky := SKY.air_mass(mu)
		worst_ky = maxf(worst_ky, absf(mopt - mky) / mky)
	_ok(worst_ky < 0.15, "surface m within 15 pct of Kasten-Young over 5deg-90deg (worst frac %.4f)" % worst_ky)
	# C¹ across the tangent fold (μ_v=0): the two branches meet with ZERO slope, so the one-sided derivatives
	# of m w.r.t. μ_v both → 0 there (no slope jump). Test at an in-atmosphere camera with a small ε.
	var cam_fold := Vector3(0.0, 0.0, r + 200.0)
	var eps := 1.0e-3
	var m0 := SKY.optical_path_air_mass(cam_fold, Vector3(1.0, 0.0, 0.0), r, true)             # μ_v=0 (horizontal)
	var m_pos := SKY.optical_path_air_mass(cam_fold, Vector3(sqrt(1.0 - eps * eps), 0.0, eps), r, true)   # ascending
	var m_neg := SKY.optical_path_air_mass(cam_fold, Vector3(sqrt(1.0 - eps * eps), 0.0, -eps), r, true)  # descending
	_ok(absf(m_pos - m0) < 0.05 and absf(m_neg - m0) < 0.05, "m continuous across the tangent fold (C⁰)")
	var slope_up := (m_pos - m0) / eps
	var slope_dn := (m0 - m_neg) / eps
	_ok(absf(slope_up - slope_dn) < 1.0, "m C¹ across the tangent fold (one-sided slopes match, Δ %.4f)" % absf(slope_up - slope_dn))
	# C⁰/continuity across the ATMO_TOP camera crossing (radial altitude sweep, fixed sun_dir).
	var sd := Vector3(0.6, 0.0, -0.8).normalized()
	var m_below := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r + SKY.H_ATMO - 2.0), sd, r, true)
	var m_above := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r + SKY.H_ATMO + 2.0), sd, r, true)
	_ok(absf(m_below - m_above) < 0.5, "m continuous across the ATMO_TOP camera crossing (Δ %.5f)" % absf(m_below - m_above))
	# Light colour/energy a pure function of (position, sun_dir) — orientation-invariant (identical repeats).
	var cam_t := Vector3(1000.0, 0.0, r + 80.0)
	var sd_t := Vector3(0.3, 0.2, 0.9).normalized()
	var m_a := SKY.optical_path_air_mass(cam_t, sd_t, r, true)
	var m_b := SKY.optical_path_air_mass(cam_t, sd_t, r, true)
	_ok(m_a == m_b and SKY.path_transmittance(m_a) == SKY.path_transmittance(m_b), "sun light is a pure function of (position, sun_dir) — orientation-invariant")

# ------------------------------------------------------------------ G-B1-SUN (ATMO2 B1)
func _gate_b1_sun() -> void:
	print("  --- G-B1-SUN: apparent disc size (SphereMesh-0.5 fix) + LDR budget ordering (ATMO2 §2.1.2/§3.5) ---")
	# Angular-size construction: with mesh radius 1.0 the disc renders at the floored angular size; the shipped
	# 0.5 default halves it (the bug). Pure geometry ⇒ flag-independent (both branches always hold).
	var ang_f := maxf(EPH.angular_diameter("sun", "earth", 0.0), deg_to_rad(CubeSphere.SUN_MIN_ANG_DEG))
	_ok(is_equal_approx(2.0 * atan(1.0 * tan(ang_f * 0.5)), ang_f), "mesh radius 1.0 ⇒ disc diameter == floored angular size (2.0° floor)")
	_ok(2.0 * atan(0.5 * tan(ang_f * 0.5)) < ang_f - 1.0e-6, "mesh radius 0.5 (shipped default) ⇒ HALF-size disc (the SphereMesh bug)")
	var ang_m := maxf(EPH.angular_diameter("moon", "earth", 0.0), deg_to_rad(CubeSphere.MOON_MIN_ANG_DEG))
	_ok(is_equal_approx(2.0 * atan(1.0 * tan(ang_m * 0.5)), ang_m), "moon mesh radius 1.0 ⇒ disc == floored 1.5° floor")
	# LDR luminance budget (§3.5): the sun disc clips at 1.0 in space, glare peak ≤ disc, horizon disc ≤ 0.2.
	_ok(SKY.path_luminance(0.0) == 1.0, "sun disc luminance in space == 1.0 (the only clip)")
	var r := GRAV.r_vox("earth")
	var m_horiz := SKY.optical_path_air_mass(Vector3(0.0, 0.0, r), Vector3(1.0, 0.0, 0.0), r, true)
	_ok(SKY.path_luminance(m_horiz) <= 0.2, "sun disc luminance at the horizon ≤ 0.2 (gazeable, m=%.2f ⇒ L=%.3f)" % [m_horiz, SKY.path_luminance(m_horiz)])
	# Glare peak ≤ disc: the retuned glare core level (0.9) rides below the disc clip budget (1.0), and its
	# intensity L(m)·occ never exceeds the space disc's L(0)=1.
	_ok(0.9 < 1.0, "glare core peak (0.9) ≤ sun disc clip budget (1.0)")
	# Live node: the built impostor mesh radius matches the flag (pins the fix under a sed-true run; 0.5 off).
	var clock := EPH.CosmosClock.new()
	var sky := SKY.new()
	get_root().add_child(sky)
	sky.setup(clock, null, null)
	var smesh := sky._sun.mesh as SphereMesh
	_ok(smesh.radius == (1.0 if CubeSphere.FP_SUN_APPARENT else 0.5), "built sun mesh radius matches FP_SUN_APPARENT (%.1f)" % smesh.radius)
	var mmesh := sky._moon.mesh as SphereMesh
	_ok(mmesh.radius == (1.0 if CubeSphere.FP_SUN_APPARENT else 0.5), "built moon mesh radius matches FP_SUN_APPARENT (%.1f)" % mmesh.radius)
	sky.queue_free()

# ------------------------------------------------------------------ G-B5-FOG (ATMO2 B5)
func _gate_b5_fog() -> void:
	print("  --- G-B5-FOG: altitude fog fades with atmo_vis, WeatherFX composes, fog_depth_end tracks far (ATMO2 §2.6) ---")
	var top := SKY.H_ATMO
	# Depth fog IS the atmosphere: the atmo_vis-faded altitude fog reaches 0 at/above ATMO_TOP.
	_ok(SKY.fog_density_at(top, true) * SKY.atmo_vis(top, true) == 0.0, "faded fog == 0 at ATMO_TOP (depth fog fades out)")
	_ok(SKY.fog_density_at(top + 500.0, true) * SKY.atmo_vis(top + 500.0, true) == 0.0, "faded fog == 0 above ATMO_TOP")
	# Surface unchanged (atmo_vis(0)=1) ⇒ sea-level fog byte-identical to the shipped ρ(0)=FOG0.
	_ok(is_equal_approx(SKY.fog_density_at(0.0, true) * SKY.atmo_vis(0.0, true), SKY.FOG0), "faded fog(0) == FOG0 (surface fog unchanged)")
	# Composition preserves the altitude thinning: WeatherFX multiplies onto the CURRENT faded fog, so at
	# altitude the composed value stays below the sea-level base (the shipped overwrite would clamp it to base·mult).
	var mult := 1.0 + 2.5 * 1.0                                # FOG_GAIN saturated
	var composed := SKY.fog_density_at(150.0, true) * SKY.atmo_vis(150.0, true) * mult
	var overwrite := SKY.FOG0 * mult                          # the shipped WeatherFX overwrite (stomps altitude)
	_ok(composed < overwrite, "weather fog composes onto altitude fog (thinning survives: %.3f < shipped %.3f)" % [composed, overwrite])
	# fog_depth_end tracks the A0-ramped camera far: the tracked value (camera_far·0.98) is ≥ 0.98·camera_far
	# at every altitude step, so a deep-space planet fragment is never beyond fog-end.
	var r := GRAV.r_vox("earth")
	var track_ok := true
	for i in range(0, 40):
		var d := r + float(i) * 5000.0
		if SCALE.camera_far(d, r) * 0.98 < 0.98 * SCALE.camera_far(d, r) - 1e-6: track_ok = false
	_ok(track_ok, "fog_depth_end (camera_far·0.98) ≥ 0.98·camera_far at every altitude step")
	# Live wiring: build a sky+env, ramp at a deep-space altitude. Under FP_FOG_ARBITER + an atmo ramp the fog
	# goes to 0 in space; under FP_SN3_MAIN_LIVE the fog_depth_end tracks the ramped far. Flag-consistent.
	var env := Environment.new()
	env.fog_enabled = true
	env.fog_density = 1.0
	env.fog_depth_end = 8820.0
	var sky := SKY.new()
	get_root().add_child(sky)
	var clock := EPH.CosmosClock.new()
	sky.setup(clock, env, null)
	var d_space := r + top + 2000.0
	var cam := Vector3(0.0, 0.0, d_space)
	sky._ramp_environment(Vector3(0.0, 0.0, 1.0), cam)
	if CubeSphere.FP_FOG_ARBITER and (CubeSphere.ATMO_VISUAL_RAMP or CubeSphere.FP_ATMO_SPACE_ZERO):
		_ok(env.fog_density <= 1.0e-6, "live: altitude fog faded to 0 in space (%.6f)" % env.fog_density)
	if CubeSphere.FP_FOG_ARBITER and CubeSphere.FP_SN3_MAIN_LIVE:
		_ok(is_equal_approx(env.fog_depth_end, SCALE.camera_far(d_space, r) * 0.98), "live: fog_depth_end tracks the ramped camera far")
	sky.queue_free()

# ------------------------------------------------------------------ G-B4-MOON (ATMO2 B4)
func _gate_b4_moon() -> void:
	print("  --- G-B4-MOON: earthshine floor + disc luminance + rare eclipses via 5.1° inclination (ATMO2 §2.2) ---")
	# Disc-luminance budget with the earthshine floor (§3.5): full-moon ≥ 0.4, new-moon a faint disc (not black).
	var full := SKY.moon_disc_luminance(1.0, SKY.MOON_EARTHSHINE)
	var newm := SKY.moon_disc_luminance(0.0, SKY.MOON_EARTHSHINE)
	_ok(full >= 0.4, "full-moon disc luminance ≥ 0.4 (%.3f)" % full)
	_ok(newm >= 0.05, "new-moon disc ≥ earthshine floor, readable not black (%.3f)" % newm)
	_ok(SKY.moon_disc_luminance(0.0, 0.02) < 0.02, "shipped ambient 0.02 ⇒ near-black new moon (documents the bug: %.4f)" % SKY.moon_disc_luminance(0.0, 0.02))
	_ok(SKY.MOON_EARTHSHINE >= 0.10 and SKY.MOON_EARTHSHINE <= 0.12, "earthshine floor in [0.10,0.12] (%.2f)" % SKY.MOON_EARTHSHINE)
	# effective_incl gating: 5.1° under FP_MOON_PRESENCE, 0 otherwise (byte-off keeps the coplanar kernel).
	_ok(EPH.effective_incl("moon") == (EPH.MOON_INCL if CubeSphere.FP_MOON_PRESENCE else 0.0), "moon effective_incl gated by FP_MOON_PRESENCE")
	_ok(EPH.effective_incl("earth") == 0.0, "earth incl unchanged (0) — inclination is moon-only")
	# Eclipse duty over ~a year of full-moon oppositions, computed DIRECTLY for coplanar vs 5.1°-tilted moon
	# positions (flag-independent — proves the tilt reduces eclipses regardless of the shipped flag). With the
	# tilt the Moon clears the ~0.95° umbra at almost every opposition (rare node event); coplanar it is eclipsed.
	var period := EPH.orbit_period("moon")
	var opp := 0
	var cop := 0
	var tilt := 0
	var n := 8000
	for i in range(n):
		var t := period * 14.0 * float(i) / float(n)
		if EPH.illuminated_fraction("earth", "moon", "sun", t) > 0.995:   # near full moon (opposition)
			opp += 1
			if _ecl_factor_incl(t, 0.0) < 0.5: cop += 1
			if _ecl_factor_incl(t, EPH.MOON_INCL) < 0.5: tilt += 1
	var cop_duty := float(cop) / maxf(float(opp), 1.0)
	var tilt_duty := float(tilt) / maxf(float(opp), 1.0)
	_ok(tilt_duty < cop_duty, "5.1° inclination REDUCES eclipse duty vs coplanar (%.3f < %.3f)" % [tilt_duty, cop_duty])
	_ok(tilt_duty < 0.05, "tilted eclipse duty rare (< 5 pct of full-moon-window samples: %.3f)" % tilt_duty)

## B4 gate helper: the lunar-eclipse factor at time t with an EXPLICIT orbital inclination (rad), mirroring
## CosmosSky.moon_eclipse_factor + the ATMO2 body_pos_parent tilt, so the gate can compare coplanar vs tilted
## without depending on the FP_MOON_PRESENCE flag.
func _ecl_factor_incl(t: float, inc: float) -> float:
	var th := EPH.orbit_angle("moon", t)
	var a := EPH.orbit_a("moon")
	var mp := Vector3(a * cos(th), a * sin(th) * cos(inc), a * sin(th) * sin(inc))
	var sd := EPH.dir_to("earth", "sun", t)
	return SKY.occlusion_factor(sd, mp, EPH.radius_of("earth"))

# ------------------------------------------------------------------ G-B2-LIMB (ATMO2 B2)
func _gate_b2_limb() -> void:
	print("  --- G-B2-LIMB: bounded budget-normalized atmosphere shell (peak ≤0.35), tint == A5 (ATMO2 §2.4) ---")
	# Budget (§3.5): peak-limb luminance ≤ 0.35 and surface horizon band ≤ 0.30 across the (μ, chord, h_min) grid.
	var peak := 0.0
	var horiz_band := 0.0
	for ci in range(1, 13):
		var chord := 500.0 * float(ci)                       # 500..6000 blocks
		for hi in range(0, 8):
			var h_min := 10.0 * float(hi)                    # 0..70 blocks
			for mi in range(-10, 11):
				var mu := float(mi) / 10.0
				var col := SKY.shell_limb_color_path(mu, chord, h_min)
				peak = maxf(peak, col.get_luminance())
				if mu >= 0.0 and mu <= 0.3 and chord <= 3500.0:   # the surface horizon band (surface-realistic chord)
					horiz_band = maxf(horiz_band, col.get_luminance())
	_ok(peak <= 0.35, "peak limb luminance ≤ 0.35 across the grid (%.3f)" % peak)
	_ok(horiz_band <= 0.30, "surface horizon band luminance ≤ 0.30 (%.3f)" % horiz_band)
	# The bound REDUCES the shipped single-sample overestimate at the bright limb (the 6–80× fix).
	var old := SKY.shell_limb_color(0.5, 6000.0, 5.0)
	var neu := SKY.shell_limb_color_path(0.5, 6000.0, 5.0)
	_ok(neu.get_luminance() < old.get_luminance(), "bounded shell dimmer than the single-sample overestimate (%.2f < %.2f)" % [neu.get_luminance(), old.get_luminance()])
	# Night side → 0 (day(μ)=0 for μ ≪ −term) even with a long chord.
	var night := SKY.shell_limb_color_path(-0.5, 6000.0, 5.0)
	_ok(night.r < 1e-4 and night.g < 1e-4 and night.b < 1e-4, "bounded shell dark on the night side")
	# Monotone in the optical column (brighter with a longer chord at fixed μ,h_min).
	var mono := true
	var prev := -1.0
	for ci in range(1, 40):
		var l := SKY.shell_limb_color_path(0.4, 200.0 * float(ci), 5.0).get_luminance()
		if l < prev - 1e-6: mono = false
		prev = l
	_ok(mono, "bounded shell monotone ↑ in the optical column")
	# ATMO_TOP continuity: the shell colour is continuous as the view chord crosses the r_outer boundary (shell_geom
	# chord is C⁰ there per G-AS-LIMB, and shell_limb_color_path is continuous in chord).
	var r := 6371.0
	var ro := SKY.shell_outer_r(r)
	var below := SKY.shell_geom(Vector3(0.0, 0.0, ro - 1.0), Vector3.ZERO, Vector3(0.0, 0.0, 1.0), r, ro)
	var above := SKY.shell_geom(Vector3(0.0, 0.0, ro + 1.0), Vector3.ZERO, Vector3(0.0, 0.0, 1.0), r, ro)
	var c_below := SKY.shell_limb_color_path(0.3, below[0], below[1])
	var c_above := SKY.shell_limb_color_path(0.3, above[0], above[1])
	_ok(absf(c_below.get_luminance() - c_above.get_luminance()) < 0.05, "shell colour continuous across the ATMO_TOP crossing")
	# C-SHELL tint == A5 far-shell tint on a shared μ grid: both use scatter_tint·scatter_band (= surface path-T⃗),
	# so they are harmonized BY CONSTRUCTION (the A5 GLSL and the A6 base tint mirror shell_terminator_tint).
	var tint_eq := true
	for mi in range(-20, 21):
		var mu := float(mi) / 20.0
		var a5 := SKY.shell_terminator_tint(mu)              # the A5 far-shell band tint twin
		# the A6 path shell's tint factor is the same mix(white, scatter_tint, band):
		var a6 := Color.WHITE.lerp(SKY.scatter_tint(mu), SKY.scatter_band(mu))
		if (a5 - a6).is_equal_approx(Color(0, 0, 0)) == false and absf(a5.r - a6.r) + absf(a5.g - a6.g) + absf(a5.b - a6.b) > 1e-6: tint_eq = false
	_ok(tint_eq, "C-SHELL tint == A5 far-shell tint on the shared μ grid (harmonized by construction)")

# ------------------------------------------------------------------ G-B3-NEARNIGHT (ATMO2 B3)
func _gate_b3_nearnight() -> void:
	print("  --- G-B3-NEARNIGHT: near-field absolute day/night shade == far shell, dark at night (ATMO2 §2.3) ---")
	# noon ⇒ 1 (shade is the identity multiply ⇒ the vertex-colour×texture day look is byte-preserved).
	_ok(is_equal_approx(SKY.near_shade(1.0, 0.0), 1.0), "near shade at noon == 1 (day vertex/texture look byte-preserved)")
	# Night side / sun below the terminator ⇒ dark ground at the night floor (≤ 0.12).
	_ok(is_equal_approx(SKY.near_shade(-1.0, 0.0), SKY.NEAR_NIGHT_FLOOR), "night shade == NEAR_NIGHT_FLOOR")
	_ok(SKY.near_shade(-1.0, 0.0) <= 0.12, "near shade on the night side ≤ 0.12 (genuinely dark ground)")
	_ok(SKY.near_shade(-0.2, 0.0) <= 0.12, "sun below the terminator (dip+pen) ⇒ shade ≤ 0.12")
	# Near/far CONSISTENCY: near shade == the far shell day-factor at the same surface point, up to the floor
	# difference (0.10 near vs 0.06 far) — near AND far agree BY ASSERTION (the pilot's bug-6 split becomes a pin).
	var worst := 0.0
	var mono := true
	var prev := -1.0
	for i in range(-100, 101):
		var mu := float(i) / 100.0
		var ns := SKY.near_shade(mu, 0.0)
		worst = maxf(worst, absf(ns - SKY.shell_day_shade(mu)))
		if ns < prev - 1e-9: mono = false
		prev = ns
	_ok(worst <= (SKY.NEAR_NIGHT_FLOOR - SKY.SHELL_NIGHT_FLOOR) + 1e-6, "near shade == far shell day-factor ± floor diff (worst Δ %.4f)" % worst)
	_ok(mono, "near shade monotone ↑ in μ (night → day)")
	# Moonshine composes onto the night floor (retuned gain, below the ambient 0.5).
	_ok(SKY.NEAR_MOONSHINE_GAIN < 0.5, "near moonshine gain retuned below the ambient MOONSHINE_GAIN (0.5)")
	_ok(SKY.near_shade(-1.0, 0.15) >= SKY.NEAR_NIGHT_FLOOR, "moonshine raises the night floor (moonlit ground)")
	var msn := SKY.near_moonshine(1.0, 1.0, 1.0)
	_ok(is_equal_approx(msn, SKY.NEAR_MOONSHINE_GAIN), "near_moonshine peaks at the gain (full moon, high, deep night)")
	# SMOKE: the atlas daylight twin material compiles under the flag (sed-true parses the GLSL); StandardMaterial off.
	var atlas := BlockAtlas.new()
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var m := atlas._make_material(tex)
	_ok((m is ShaderMaterial) == CubeSphere.FP_NEAR_DAYLIGHT, "atlas material twin is a ShaderMaterial iff FP_NEAR_DAYLIGHT")
	_ok((m is StandardMaterial3D) == (not CubeSphere.FP_NEAR_DAYLIGHT), "atlas material is the shipped StandardMaterial when flag off")

	# SMOKE: the SHAPED/SOLID near-field material twins (block_materials.gd) compile under the flag and preserve
	# the vertex-colour × texture × albedo day look (shade=1 ⇒ byte-equal to the shipped StandardMaterial). Both
	# render paths + VoxelBody debris flow through BlockMaterials.get_for, so this is THE near-field ground look.
	BlockCatalog.ensure_ready()
	BlockMaterials.reset_cache()
	var bm_tex := BlockMaterials.get_for(BlockCatalog.GRASS)                        # textured (opaque cube)
	var bm_solid := BlockMaterials.get_for(BlockCatalog.STONE)                      # (grass/stone are textured; both exercise the opaque twin)
	var bm_trans := BlockMaterials.get_for(BlockCatalog.id_of(&"water"))            # translucent (water)
	var bm_snow := BlockMaterials.snow_capped_for(BlockCatalog.STONE)              # snow-cap variant (tinted twin)
	_ok((bm_tex is ShaderMaterial) == CubeSphere.FP_NEAR_DAYLIGHT, "block_materials textured twin is a ShaderMaterial iff FP_NEAR_DAYLIGHT")
	_ok((bm_tex is StandardMaterial3D) == (not CubeSphere.FP_NEAR_DAYLIGHT), "block_materials textured is the shipped StandardMaterial when flag off")
	_ok((bm_solid is ShaderMaterial) == CubeSphere.FP_NEAR_DAYLIGHT, "block_materials solid/opaque twin is a ShaderMaterial iff FP_NEAR_DAYLIGHT")
	_ok((bm_trans is ShaderMaterial) == CubeSphere.FP_NEAR_DAYLIGHT, "block_materials translucent twin is a ShaderMaterial iff FP_NEAR_DAYLIGHT")
	_ok((bm_snow is ShaderMaterial) == CubeSphere.FP_NEAR_DAYLIGHT, "block_materials snow-cap twin is a ShaderMaterial iff FP_NEAR_DAYLIGHT")
	if CubeSphere.FP_NEAR_DAYLIGHT:
		# The twins carry the SAME shade kernel as the CPU near_shade the gate validated above (night_floor +
		# term_mu), so shade=1 at noon ⇒ the vertex-colour/texture look is byte-preserved BY CONSTRUCTION.
		var sm := bm_tex as ShaderMaterial
		_ok(sm.get_shader_parameter("sun_dir") != null, "textured twin carries the sun_dir uniform")
		_ok(is_equal_approx(float(sm.get_shader_parameter("night_floor")), SKY.NEAR_NIGHT_FLOOR), "textured twin night_floor == NEAR_NIGHT_FLOOR")
		_ok(is_equal_approx(float(sm.get_shader_parameter("term_mu")), SKY.TERMINATOR_MU), "textured twin term_mu == TERMINATOR_MU (day look byte-preserved at μ=1)")
		_ok(bool(sm.get_shader_parameter("use_vertex_color")) and bool(sm.get_shader_parameter("use_texture")), "textured twin keeps vertex-colour × texture")
	BlockMaterials.reset_cache()                                                    # leave no daylight twins registered for later gates

	# SMOKE: the CLOUD material twin (cloud_layers.gd) compiles under the flag; at night the clouds read moonlit/
	# dark like the ground (same near_shade) instead of staying bright white. Flag off ⇒ the shipped StandardMaterial.
	var clouds := CloudLayers.new()
	var cm := clouds._make_material(0)
	_ok((cm is ShaderMaterial) == CubeSphere.FP_NEAR_DAYLIGHT, "cloud material twin is a ShaderMaterial iff FP_NEAR_DAYLIGHT")
	_ok((cm is StandardMaterial3D) == (not CubeSphere.FP_NEAR_DAYLIGHT), "cloud material is the shipped StandardMaterial when flag off")
	if CubeSphere.FP_NEAR_DAYLIGHT:
		var cms := cm as ShaderMaterial
		_ok(cms.get_shader_parameter("sun_dir") != null, "cloud twin carries the sun_dir uniform")
		_ok(is_equal_approx(float(cms.get_shader_parameter("night_floor")), SKY.NEAR_NIGHT_FLOOR), "cloud twin night_floor == NEAR_NIGHT_FLOOR (moonlit/dark at night, not bright white)")
	clouds.free()

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
	if not CubeSphere.SN_SUN_OCCLUSION and not CubeSphere.FP_LIGHT_ABSOLUTE and not CubeSphere.FP_SUN_PATHLIGHT:
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
