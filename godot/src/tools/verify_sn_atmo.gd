extends SceneTree
## COSMOS SPACE-NAV SN4 gate — G-SN-RAMP + G-SN-OCCLUDE (docs/COSMOS-SPACE-NAV-DESIGN.md §6.2, §6.3, §10 SN4).
## Proves the SN4a ALTITUDE ATMOSPHERE RAMP and the SN4b ANALYTIC SUN-OCCLUSION DIMMER end-to-end WITHOUT a
## live browser: the ramp/occlusion MATH is pure static (CosmosSky.space_mix / fog_density_at / ambient_scale /
## occlusion_factor / occlusion_light / occlusion_ambient), so this gate drives it DIRECTLY and is
## FLAG-INDEPENDENT (it passes identically with ATMO_VISUAL_RAMP / SN_SUN_OCCLUSION true or false — the flags
## only decide whether _ramp_environment COMPOSES this math in-game). Only the LOOK is live-only.
##
## G-SN-RAMP asserts (§6.2):
##   • C¹: space_mix is continuous AND has ~zero slope at both band endpoints (the smoothstep signature); every
##     ramp curve is continuous (no jump) across 0..1200 blocks.
##   • Endpoints EXACT: h=0 (has_atmo) → space_mix=0, fog=FOG0, ambient_scale=1, sky==ramped sky, star_fade==night;
##     h≥2.5·H_ATMO → space_mix=1, background==BLACK, star_fade==1, ambient_scale==AMBIENT_SPACE.
##   • Monotone in h: space_mix ↑, fog ↓, ambient ↓, background → black.
##   • Airless body (has_atmo=false) ≡ space at the surface: space_mix(0)=1, fog(0)=0.
## G-SN-OCCLUDE asserts (§6.3):
##   • factor==0 in the umbra (player directly behind the body from the sun), ==1 fully sunlit.
##   • monotone through the penumbra (sweeping the sun across the body's limb).
##   • continuous in h at the blend-band boundary where it hands to the elevation ramp; light_energy(h=0)==1.0
##     EXACTLY (byte-identical hand-off to the shipped light on the surface).
##   • airless body: the occlusion dimmer owns from the surface (light in the umbra ==0 at h=0).
## Plus an INERT-RAMP check: with the shipped flags (both false), a live CosmosSky+Environment leaves the ramp
## at the shipped day-night values (fog_density and light_energy untouched) — the byte-identity face of G-SN-ATMO-OFF
## (the FLAT verify_feature 6035/0 is the full byte-identity gate, run separately).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_sn_atmo.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const SKY := preload("res://src/cosmos/cosmos_sky.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_sn_atmo (COSMOS SPACE-NAV SN4: G-SN-RAMP + G-SN-OCCLUDE) ===")
	print("  CubeSphere.ATMO_VISUAL_RAMP = %s  SN_SUN_OCCLUSION = %s (gate is flag-independent; math is pure static)"
		% [str(CubeSphere.ATMO_VISUAL_RAMP), str(CubeSphere.SN_SUN_OCCLUSION)])
	FacetAtlas.warm_up()                                    # r_vox(earth) reads FacetAtlas.R_BLOCKS
	_gate_ramp()
	_gate_occlude()
	_gate_inert()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ G-SN-RAMP
func _gate_ramp() -> void:
	print("  --- G-SN-RAMP: altitude ramp curves ---")
	var lo := SKY.SPACE_MIX_LO
	var hi := SKY.SPACE_MIX_HI

	# Endpoints EXACT (has_atmo=true).
	_ok(SKY.space_mix(0.0, true) == 0.0, "space_mix(0)==0")
	_ok(SKY.space_mix(hi, true) == 1.0, "space_mix(2.5H_ATMO)==1")
	_ok(SKY.space_mix(hi + 500.0, true) == 1.0, "space_mix above band clamps to 1")
	_ok(SKY.fog_density_at(0.0, true) == SKY.FOG0, "fog(0)==FOG0 (shipped 1.0)")
	_ok(SKY.ambient_scale(0.0) == 1.0, "ambient_scale(space_mix=0)==1 (surface unchanged)")
	_ok(is_equal_approx(SKY.ambient_scale(1.0), SKY.AMBIENT_SPACE), "ambient_scale(1)==AMBIENT_SPACE")
	# background at the endpoints (the composite the ramp writes): sky.lerp(BLACK, space_mix).
	var day_sky := SKY._SKY_NIGHT.lerp(SKY._SKY_DAY, 1.0)   # noon sky
	_ok(day_sky.lerp(Color.BLACK, SKY.space_mix(0.0, true)) == day_sky, "background(h=0)==ramped sky (unchanged)")
	_ok(day_sky.lerp(Color.BLACK, SKY.space_mix(hi, true)) == Color.BLACK, "background(space)==BLACK even with sun up")
	# star_fade = max(night_fade, space_mix): at the surface it is the shipped night_fade; in space it is 1.
	var night_fade := 0.4                                   # any daytime value; space_mix must dominate in space
	_ok(maxf(night_fade, SKY.space_mix(0.0, true)) == night_fade, "star_fade(h=0)==night_fade (shipped)")
	_ok(maxf(night_fade, SKY.space_mix(hi, true)) == 1.0, "star_fade(space)==1 (stars emerge)")

	# Monotone + continuous across 0..1200 (fine sweep). Also record the max step for the continuity claim.
	var prev_sm := -1.0
	var prev_fog := 1e30
	var prev_amb := 1e30
	var max_sm_step := 0.0
	var mono := true
	var cont := true
	var last_h := 0.0
	for i in range(0, 1201):
		var h := float(i)
		var sm := SKY.space_mix(h, true)
		var fog := SKY.fog_density_at(h, true)
		var amb := SKY.ambient_scale(sm)
		if sm < prev_sm - 1e-9: mono = false
		if fog > prev_fog + 1e-9: mono = false
		if amb > prev_amb + 1e-9: mono = false
		if prev_sm >= 0.0:
			var step: float = absf(sm - prev_sm)
			max_sm_step = maxf(max_sm_step, step)
			if step > 0.02: cont = false                    # 1-block steps can never jump this much (C⁰)
		prev_sm = sm; prev_fog = fog; prev_amb = amb; last_h = h
	_ok(mono, "space_mix ↑ / fog ↓ / ambient ↓ monotone in h")
	_ok(cont, "all ramp curves continuous (max 1-block space_mix step %.5f)" % max_sm_step)

	# C¹ signature of smoothstep: ~zero slope at both band endpoints (central finite difference).
	var eps := 0.25
	var slope_lo: float = (SKY.space_mix(lo + eps, true) - SKY.space_mix(lo - eps, true)) / (2.0 * eps)
	var slope_hi: float = (SKY.space_mix(hi + eps, true) - SKY.space_mix(hi - eps, true)) / (2.0 * eps)
	_ok(absf(slope_lo) < 1e-3, "space_mix slope≈0 at band start (C¹): %.6f" % slope_lo)
	_ok(absf(slope_hi) < 1e-3, "space_mix slope≈0 at band end (C¹): %.6f" % slope_hi)

	# Airless body (Moon): space at the surface — space_mix≡1, fog≡0.
	_ok(SKY.space_mix(0.0, false) == 1.0, "airless space_mix(0)==1 (black sky at surface)")
	_ok(SKY.fog_density_at(0.0, false) == 0.0, "airless fog(0)==0 (no atmosphere)")

# ------------------------------------------------------------------ G-SN-OCCLUDE
func _gate_occlude() -> void:
	print("  --- G-SN-OCCLUDE: sun-occlusion dimmer ---")
	var r_vox := GRAV.r_vox("earth")                        # 3072
	var sun := Vector3(1.0, 0.0, 0.0)
	var dist := r_vox + 1200.0                              # h=1200 > 2.5·H_ATMO ⇒ authority==1 (occlusion owns)
	var h_space := dist - r_vox

	# Umbra: player directly behind the planet from the sun (p along −sun). factor==0, light==0 in space.
	var p_umbra := -sun * dist
	_ok(SKY.occlusion_factor(sun, p_umbra, r_vox) == 0.0, "factor==0 in the umbra")
	_ok(SKY.occlusion_light(sun, p_umbra, h_space, r_vox, true) == 0.0, "light==0 in the umbra (space regime)")
	# Sunlit: player on the day side (p along +sun). factor==1, light==1.
	var p_sun := sun * dist
	_ok(SKY.occlusion_factor(sun, p_sun, r_vox) == 1.0, "factor==1 fully sunlit")
	_ok(SKY.occlusion_light(sun, p_sun, h_space, r_vox, true) == 1.0, "light==1 fully sunlit (space regime)")

	# Monotone through the penumbra: sweep α = angle(sun, −p̂) from 0 (umbra) to π (sunlit); factor ↑.
	var mono := true
	var saw_zero := false
	var saw_one := false
	var prev := -1.0
	for i in range(0, 361):
		var a := PI * float(i) / 360.0
		# −p̂ makes angle a with sun ⇒ p̂ = −(cos a, sin a, 0), p = dist·p̂.
		var p := Vector3(-cos(a), -sin(a), 0.0) * dist
		var f := SKY.occlusion_factor(sun, p, r_vox)
		if f < prev - 1e-9: mono = false
		if f == 0.0: saw_zero = true
		if f == 1.0: saw_one = true
		prev = f
	_ok(mono, "factor monotone ↑ sweeping the sun across the limb")
	_ok(saw_zero and saw_one, "penumbra spans the full 0→1 range across the sweep")

	# Continuity in h at the blend-band boundary: sweep h 0..1200 (umbra geometry). No jump; light(h=0)==1.0 EXACT.
	var cont := true
	var prev_l := -1.0
	var max_step := 0.0
	for i in range(0, 1201):
		var h := float(i)
		var pu := -sun * (r_vox + h)
		var l := SKY.occlusion_light(sun, pu, h, r_vox, true)
		if prev_l >= 0.0:
			var step: float = absf(l - prev_l)
			max_step = maxf(max_step, step)
			if step > 0.02: cont = false
		prev_l = l
	_ok(cont, "light_energy continuous in h at the blend boundary (max 1-block step %.5f)" % max_step)
	var p0 := -sun * r_vox                                  # surface, umbra geometry
	_ok(SKY.occlusion_light(sun, p0, 0.0, r_vox, true) == 1.0, "light_energy(h=0)==1.0 EXACT (hands to elevation ramp)")

	# Airless body: the occlusion dimmer owns from the surface (authority=space_mix(0,false)=1) ⇒ umbra dark at h=0.
	_ok(SKY.occlusion_light(sun, p0, 0.0, r_vox, false) == 0.0, "airless: umbra dark at the surface (occlusion owns)")

# ------------------------------------------------------------------ INERT-RAMP (byte-identity face)
func _gate_inert() -> void:
	print("  --- INERT-RAMP: shipped flags leave the ramp at day-night values ---")
	# A live CosmosSky + Environment with the SHIPPED flags (ATMO_VISUAL_RAMP / SN_SUN_OCCLUSION both false):
	# _ramp_environment must NOT write fog_density or light_energy, and must produce the shipped day-night ramp.
	var env := Environment.new()
	env.fog_enabled = true
	env.fog_density = 1.0                                   # the shipped sentinel
	var sky := SKY.new()
	get_root().add_child(sky)
	var clock := EPH.CosmosClock.new()
	sky.setup(clock, env, null)
	# Drive the ramp at high noon over the planet (sun straight up at the local zenith of cam_origin).
	var cam := Vector3(0.0, 0.0, float(FacetAtlas.R_BLOCKS))   # on the +Z surface (Earth/1000 R=6371; up = +Z)
	var sun_up := Vector3(0.0, 0.0, 1.0)                   # noon
	sky._ramp_environment(sun_up, cam)
	# With the flags off the shipped formula is: twilight=1 ⇒ background==_SKY_DAY, ambient==1.0, fog untouched.
	_ok(env.fog_density == 1.0, "flag-off: fog_density untouched (==1.0)")
	_ok(sky._sun_light.light_energy == 1.0, "flag-off: light_energy untouched (==shipped 1.0)")
	_ok(env.background_color.is_equal_approx(SKY._SKY_DAY), "flag-off: noon background == shipped _SKY_DAY")
	_ok(is_equal_approx(env.ambient_light_energy, 1.0), "flag-off: noon ambient == shipped 1.0")
	sky.queue_free()
