class_name VoxiLight
extends RefCounted
## COSMOS TEXTURED-LOD §2V.3 (docs/COSMOS-TEXTURED-LOD-DESIGN.md — V1 FP_SHADE_UNIFIED): the ONE lighting law shared
## by the near blocks and the far skin, so the orbit→surface transition is stitchless (the user's #1 requirement).
##
## §2V.3 verified three mismatches between the two live shaders that made "near vs far totally different light":
##   1. NORMAL   — near used normalize(v_wp) (position from the SCENE ORIGIN, a pseudo-normal that is NOT the planet
##                 radial in the facet-local frame); the far shell used normalize(wp − centre), the TRUE sphere radial.
##   2. TERMINATOR— near had none (plain day(μ)); the far shell added a scatter band + warm _scatter_tint(μ).
##   3. NIGHT FLOOR— near had a moonshine floor (max(shade, moonshine)); the far lacked it.
## Any one alone breaks the seam; together they are the "totally different light".
##
## THE LAW — ONE tiny GLSL snippet, STRING-INCLUDED (pure concatenation, NO new shader_type/compiled program) into
## the near atlas shader (block_atlas.gd), the shell LIGHT sub-strings (facet_far_ring.gd), and TierPlace._TIER_SHADER.
## voxi_shade(n, sd) → shade·tint carries the far shell's FULL model (day smoothstep + scatter band tint + night
## floor) PLUS the moonshine floor. It takes the surface normal `n` as a PARAMETER: each shader derives the TRUE
## planet-radial normal in its own frame (near: normalize(wp − planet_centre) via a new uniform; far/tier: normalize(
## wp − MODEL·0)). At the same world point with the same planet centre the two normals are identical ⇒ a near block
## top and the far texel covering it shade IDENTICALLY at every sun angle, INCLUDING the terminator (G-VL-EQ).
##
## ONE uniform set (sun_dir, night_floor, term_mu, moonshine) — identical values on every material — plus the near-only
## planet_centre, pushed from ONE WorldManager site (world_manager.set_near_daylight_sun_dir, next to the existing
## sun_dir sync) so planet_centre can never go STALE across facet crossings/re-anchors (§2V.6 risk F1).
##
## The GLSL constants (helper bodies, exp coefficients, smoothstep edges) MIRROR CosmosSky.day_factor / scatter_tint /
## scatter_band EXACTLY — the same bytes the far shell already ships (facet_far_ring _SHELL_ABS_TEX_LIGHT). shade_tint()
## below is the GDScript twin the gate sweeps (verify_shade_unified G-VL-EQ). NO engine dependency — pure math + a const
## string; loads on any path. FP_SHADE_UNIFIED off ⇒ nothing includes this ⇒ shaders byte-identical (FLAT 6042/0).

# The canonical unified uniform VALUES — the ONE parameter set every material is seeded with (so near == far by
# construction). Sourced from CosmosSky so the far shell's shipped look is preserved (night_floor 0.06, term_mu 0.12)
# and the near field adopts it (was NEAR_NIGHT_FLOOR 0.10 — the deliberate unification, only under the flag). moonshine
# defaults 0.0 (a static floor; the near shader already defaulted it 0.0 and never fed it, so numerically unchanged).
const NIGHT_FLOOR := CosmosSky.SHELL_NIGHT_FLOOR   # 0.06
const TERM_MU := CosmosSky.TERMINATOR_MU           # 0.12
const MOONSHINE := 0.0

# The shared GLSL snippet. Declares the ONE uniform set + the shade·tint law. String-included verbatim into every
# material shader under FP_SHADE_UNIFIED. Helper names (_air_mass/_scatter_tint/_scatter_band/_day) match the shell's
# inline copies BYTE-FOR-BYTE (the inline copies are removed by the include so there is never a duplicate declaration).
# NO shader_type / render_mode / varying / sampler here — those belong to each including shader (this is a pure body).
const SHADE_GLSL := "uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.06;
uniform float term_mu = 0.12;
uniform float moonshine = 0.0;
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
vec3 voxi_shade(vec3 n, vec3 sd) {
	float mu = dot(n, normalize(sd));
	float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);
	vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
	return vec3(shade) * tint;
}
"

## COSMOS TWILIGHT — the shade snippet the shaders actually splice. FP_TWILIGHT_AMBIENT OFF ⇒ the shipped SHADE_GLSL
## verbatim (byte-identical; every splice site + verify_shade_unified see the unchanged string). ON ⇒ voxi_shade adds a
## cool ADDITIVE skylight term over a twilight band so the ground never goes near-black while the sun is up: `_twi`
## peaks at the horizon (μ≈0) and tapers to 0 below ~−14° (into the night floor) and above ~+11° (clean daylight), and
## TWI_RGB (= a dim cool dusk sky) is the diffuse fill the direct-sun-only law lacked. Kept as a localized string edit on
## the ONE base so there is a single source of the law.
const _TWI_RETURN := "	vec3 _direct = vec3(shade) * tint;
	float _twi = smoothstep(-0.25, -0.02, mu) * (1.0 - smoothstep(-0.02, 0.20, mu));
	return _direct + vec3(0.150, 0.180, 0.240) * _twi;
}"
static func shade_glsl() -> String:
	if not CubeSphere.FP_TWILIGHT_AMBIENT:
		return SHADE_GLSL
	return SHADE_GLSL.replace("	return vec3(shade) * tint;\n}", _TWI_RETURN)

# --- GDScript twin of the GLSL law (byte-for-byte equivalent) — the reference the G-VL-EQ numeric sweep drives ------

static func _air_mass(mu: float) -> float:
	var m := clampf(mu, 0.0, 1.0)
	var h := rad_to_deg(asin(m))
	return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364))

static func _scatter_tint(mu: float) -> Vector3:
	var m := _air_mass(mu)
	return Vector3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m))

static func _scatter_band(mu: float) -> float:
	var up := smoothstep(-0.10, 0.0, mu)
	var dn := 1.0 - smoothstep(0.15, 0.25, mu)
	return up * dn

static func _day(mu: float, term_mu: float) -> float:
	return smoothstep(-term_mu, term_mu, mu)

## The shade·tint the GLSL voxi_shade(n, sd) computes, in GDScript. `n` is the surface normal (any frame), `sd` the
## sun direction. Returns Vector3 = shade × scatter_tint (component-wise). The gate compares this between the "near way"
## (n = normalize(wp − planet_centre)) and the "far way" (n = normalize(wp − MODEL·0)) — equal when the two centres
## agree (the unified normal), diverging when perturbed (falsification).
static func shade_tint(n: Vector3, sun_dir: Vector3,
		night_floor := NIGHT_FLOOR, term_mu := TERM_MU, moonshine := MOONSHINE) -> Vector3:
	var mu := n.dot(sun_dir.normalized())
	var shade := maxf(night_floor + (1.0 - night_floor) * _day(mu, term_mu), moonshine)
	var tint := Vector3(1.0, 1.0, 1.0).lerp(_scatter_tint(mu), _scatter_band(mu))
	return Vector3(shade, shade, shade) * tint
