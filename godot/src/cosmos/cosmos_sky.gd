extends Node3D
class_name CosmosSky
## COSMOS ORBITAL O0 — the sky layer (docs/COSMOS-ORBITAL-DESIGN.md §4.4, §8.2). Created ONLY when
## CubeSphere.ORBITAL_SKY is true (main.gd); with the flag off this node never exists and the shipped
## flat-ambient environment (main._setup_environment) is byte-identical. The planet is pinned at scene
## identity forever (the fixed-frame keystone), so spin + orbit are expressed by MOVING THE SKY: this
## node re-writes a handful of node transforms/uniforms per frame from the CosmosEphemeris kernel — no
## geometry is ever re-placed, nothing is allocated per frame (NEVER-OOM: O(few) nodes, reused).
##
## Contents (all reused, never grown):
##   • Sun     — an emissive smooth SphereMesh impostor at D_SKY + THE DirectionalLight3D (−sun_dir).
##   • Moon    — a shaded-sphere impostor at D_SKY, radius = (D_SKY/d_true)·R_moon so its angular size
##               is EXACT; lit by the same light ⇒ its phase (lit fraction) is automatic.
##   • Stars   — a static inverted-sphere dome rotated by −Earth-spin (one basis write/frame).
##   • Env ramp— background/ambient driven by Sun elevation; night = the shipped ambient floor.
##
## Impostors are placed at (camera_origin + dir·D_SKY) so they do NOT parallax as the player walks and
## are anchor-independent (§4.4 / risk #4). Shadows OFF by default on web (D11) — the DirectionalLight
## casts none until a measured worst-frame A/B (a future SUN_SHADOWS flag). RENDER cannot be verified
## headless (the gate exercises instantiation only); the pure math it reads is fully gated.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

## Clamped sky-impostor distance (blocks). Inside the faceted camera far (FacetFarRing.CAMERA_FAR =
## 9000) so impostors never clip the far plane; > R_BLOCKS = 3072 so they sit outside the planet (§4.4).
## O3 (R = 6371) revisits this; O0 targets the shipped R = 3072.
const D_SKY := 8000.0

## COSMOS-LOD-SKY M1 — the D_SKY O3 revisit (§1/§11). The star dome is a sphere of radius D·STAR_DOME_MULT
## (built in _build_nodes), so the binding constraint is that the DOME stay inside the camera far clip
## (FacetFarRing.CAMERA_FAR = 9000). SKY_FAR_MARGIN keeps the dome edge a stated fraction inside the clip;
## the impostor then sits as far OUTSIDE the planet as that allows. Both are used ONLY when FP_SKY_DSKY_R is
## on (via _dsky); with the flag off the shipped literal 8000 is used everywhere and 8000·1.05 = 8400 is the
## byte-identical shipped star-dome radius.
const STAR_DOME_MULT := 1.05      # star dome radius = D_SKY · this (matches the _build_nodes 1.05 / 2.1 literals)
const SKY_FAR_MARGIN := 0.95      # keep the star dome edge ≤ 95% of the camera far clip (headroom inside the plane)

## The R-rescale-safe sky placement radius (blocks): as far out as the far clip allows with the star dome
## fully inside it. Derived from FacetFarRing.CAMERA_FAR so it tracks the far plane and can never clip. At
## CAMERA_FAR=9000 this is 9000·0.95/1.05 ≈ 8143 (dome edge 8550 < 9000; 1.28·R, outside the planet). Pure math.
static func d_sky_derived() -> float:
	return FacetFarRing.CAMERA_FAR * SKY_FAR_MARGIN / STAR_DOME_MULT

## The observer body whose body-fixed frame is the scene frame (the dominant body). O0 = Earth.
const OBSERVER := "earth"

## COSMOS-LOD-SKY M1 (FP_BODY_LOD) — a placeholder camera vertical fov (deg) for the per-frame BodyLod K_px
## consult. M1 only SELECTS the tier (always IMPOSTOR for the real Sun/Moon), so the exact fov is immaterial;
## the real live fov (and its zoom) is M4 (FP_TELESCOPE). Used only inside the FP_BODY_LOD-gated consult.
const LOD_NOMINAL_FOV_DEG := 70.0

var _clock: EPH.CosmosClock = null
var _env: Environment = null
var _cam_provider: Node = null                 # anything with camera_global_transform() -> Transform3D (the Player)

# COSMOS-PERF FALL-ALTRATE (FP_FALL_ATMO_THROTTLE): throttle state for the per-frame _update_sky recompute. The
# sun/moon/shell uniforms + all the Environment fog/ambient/background writes are held during a fast descent and
# refreshed ≤ 1/FALL_THROTTLE_MS. −1 sentinels (no prior sample) ⇒ the first _process always updates. DEAD off the flag.
var _atmo_prev_d := -1.0
var _atmo_prev_usec := -1
var _atmo_apply_msec := -1

# COSMOS-PERF FALL-SCALE (FP_FALL_SHELL_OFF): radial-speed state for hiding the additive atmosphere shell during a
# fast fall. −1 sentinels ⇒ the first frame reads 0 speed (shell stays visible). DEAD off the flag (never sampled).
var _shelloff_prev_d := -1.0
var _shelloff_prev_usec := -1

var _sun: MeshInstance3D = null
var _sun_light: DirectionalLight3D = null
var _moon: MeshInstance3D = null
var _stars: MeshInstance3D = null
var _moon_mat: StandardMaterial3D = null
var _star_mat: ShaderMaterial = null
var _sun_mat: StandardMaterial3D = null           # A2: kept so the Sun disc can redden by T(μ_cam) each frame
var _glare: MeshInstance3D = null                 # A2 (FP_SUN_PRESENCE): the additive Sun glare quad; null unless built
var _glare_mat: ShaderMaterial = null
var _moon_phase_mat: ShaderMaterial = null        # A4 (FP_LIGHT_ABSOLUTE): the unshaded self-phase Moon material; null unless built
var _atmo_shell: MeshInstance3D = null            # A6 (FP_ATMO_SHELL): the additive atmosphere limb/sky shell; null unless built
var _atmo_shell_mat: ShaderMaterial = null
const _SUN_EMISSION_BASE := Color(1.0, 0.96, 0.85)   # A2: the shipped Sun emission/albedo; reddened by T(μ) at dusk

## L1 moonshine per-frame inputs, computed in _update_sky (which holds t + the Moon geometry) and read by
## _ramp_environment. Defaults ⇒ zero moonshine, so a direct _ramp_environment call (the SN4 gate) is
## unaffected regardless of the flag. base albedo cached once so the eclipse redden is non-cumulative.
var _moon_up := 0.0                 # clamp(moon_dir·up, 0, 1) — how high the Moon rides
var _moon_illum := 0.0              # ephemeris illuminated fraction (0 new … 1 full)
var _moon_eclipse := 1.0            # lunar-eclipse factor (1 clear … 0 deep umbra)
var _moon_light: DirectionalLight3D = null   # L1 v1 real second light (SKY_MOONSHINE_LIGHT); null unless built
var _moon_ring: MoonFarRing = null           # M2 (FP_MOON_RING): the Moon's coarse far ring, built on RING promotion
var _moon_ring_axis := Vector3.ZERO          # body-coords cull axis of the last ring build (drift-rebuild trigger)
var _cur_sun_dir := Vector3(1.0, 0.0, 0.0)   # L3: last body-fixed Sun direction, exposed via current_sun_dir()
const _MOON_ALBEDO_BASE := Color(0.72, 0.72, 0.70)   # shipped grey (see _build_nodes); umbra reddens toward crimson
## ATMO2 B4: the earthshine floor for the Moon self-phase shader (§3.3, 0.10–0.12) — a crescent/new moon is a
## faint disc, not black. Replaces the shipped flat 0.02 `ambient` ONLY under FP_MOON_PRESENCE.
const MOON_EARTHSHINE := 0.11
## ATMO2 B4 twin: the Moon impostor's disc-mean luminance under the self-phase shader ALBEDO =
## base·(earthshine + (1−earthshine)·lit). lit = disc-integrated illuminated fraction (full=1, new=0). Pins the
## §3.5 budget: full-moon ≥ 0.4, new-moon ≥ the earthshine floor (never the black-on-black bug at 0.02).
static func moon_disc_luminance(illum_frac: float, earthshine: float) -> float:
	return _MOON_ALBEDO_BASE.get_luminance() * (earthshine + (1.0 - earthshine) * clampf(illum_frac, 0.0, 1.0))
## ATMO2 (bug-3 fix): the Moon disc albedo reddened by the SAME optical-path transmittance T⃗(m) as the Sun — the
## Moon obeys the identical atmosphere law: NEUTRAL/white overhead (short path m≈1) → RED at the horizon (long path
## m≈18). The shipped path applied NO path colour to the Moon, so its only reddening was the eclipse dim — which,
## with a coplanar orbit, fired at every high full moon → the pilot's inverted "red when high, white at horizon".
## `base` already carries the (now rare, incl-gated) eclipse redden; this composes the horizon reddening on top.
## Pure/static so the gate (G-B4) drives it directly. `moon_dir` is unit, TOWARD the Moon; cam is planet-absolute.
static func moon_path_albedo(base: Color, cam: Vector3, moon_dir: Vector3, r_solid: float, has_atmo: bool) -> Color:
	var m := optical_path_air_mass(cam, moon_dir, r_solid, has_atmo)
	var tm := path_transmittance(m)
	return Color(base.r * tm.r, base.g * tm.g, base.b * tm.b)
## The active sky placement radius (blocks), resolved ONCE in _build_nodes: the derived R-safe value under
## FP_SKY_DSKY_R, else the shipped literal D_SKY (byte-identical). Everything downstream reads this, never D_SKY.
var _dsky := D_SKY
## COSMOS-LOD-SKY M1 (FP_BODY_LOD) — the per-body latched LOD tier (caller-owned state; the BodyLod kernel is
## stateless). Populated only while FP_BODY_LOD is on; empty otherwise (the consult never runs ⇒ byte-identical).
var _lod_tier := {}

## BLACK-SKY FIX: the additive procedural starfield for the dome (see _build_nodes). `blend_add` +
## `depth_draw_never` are what stop it occluding the ramped Environment background (the original
## opaque dome's bug); `cull_front` shows its inside; `unshaded` keeps it light-independent. Stars are
## a hashed cell field on the view direction — asset-free, deterministic, and cheap (one hash + a
## smoothstep per fragment). `star_fade` collapses the whole thing to black (⇒ adds nothing) by day.
const STAR_DOME_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, blend_add, depth_draw_never, shadows_disabled, fog_disabled;

uniform float star_fade : hint_range(0.0, 1.0) = 1.0;
// COSMOS ATMO-SKY A1 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C5): the analytic planet-disc mask. planet_dir is the
// LOCAL-frame (dome-basis) direction toward the planet centre; planet_cos_ang = cos(planet angular radius).
// Fragments whose view direction falls INSIDE the disc are discarded so stars never sprinkle over the planet
// once A0 renders it at d≫D_SKY. Default planet_cos_ang = 2.0 (> 1) ⇒ the test never fires ⇒ byte-identical.
uniform vec3 planet_dir = vec3(0.0, 0.0, 1.0);
uniform float planet_cos_ang = 2.0;

varying vec3 v_dir;

void vertex() {
	v_dir = normalize(VERTEX);
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	vec3 d = normalize(v_dir);
	// A1: discard fragments inside the planet's angular disc (planet_cos_ang=2.0 default ⇒ never — byte-identical).
	if (dot(d, normalize(planet_dir)) > planet_cos_ang) discard;
	vec3 g = d * 140.0;
	vec3 cell = floor(g);
	float h = hash13(cell);
	float star = 0.0;
	// Only the sparse top slice of cells host a star; brightness varies across the surviving range.
	if (h > 0.982) {
		vec3 fp = fract(g) - 0.5;
		float bright = (h - 0.982) / 0.018;
		star = smoothstep(0.42, 0.0, length(fp)) * (0.35 + 0.65 * bright);
	}
	// A faint milky band so the dome is not a pure void between stars (still ~black additively).
	float band = smoothstep(0.30, 0.0, abs(d.z)) * 0.020;
	// NOTE: write the starlight to ALBEDO, NOT EMISSION. Under `unshaded` Godot skips the light pass and
	// ALBEDO *is* the fragment output — EMISSION would be silently dropped and the dome would render
	// black, which is the very bug being fixed here. With blend_add this ALBEDO is added to the sky
	// behind it, so black = adds nothing (the by-day case) and stars = additive points at night.
	ALBEDO = (vec3(star) * 2.2 + vec3(0.7, 0.75, 1.0) * band) * star_fade;
}
"""

# COSMOS ATMO-SKY A4 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C5): the Moon SELF-PHASE shader. UNSHADED — its lit
# hemisphere is computed per-fragment from a `sun_dir` uniform (world normal · sun_dir), so it is IMMUNE to the
# global DirectionalLight being dimmed to 0 on the night side by C1 (the shipped shaded-Moon material would
# black out exactly when the Moon should shine). Phase (crescent→full) falls out of the Lambert term; the
# eclipse redden feeds `base_albedo`. Built ONLY under FP_LIGHT_ABSOLUTE; the StandardMaterial stays otherwise.
const _MOON_PHASE_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, shadows_disabled;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 base_albedo : source_color = vec3(0.72, 0.72, 0.70);
uniform float ambient = 0.02;
varying vec3 v_wn;
void vertex() { v_wn = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz; }
void fragment() {
	float lam = max(dot(normalize(v_wn), normalize(sun_dir)), 0.0);
	ALBEDO = base_albedo * (ambient + (1.0 - ambient) * lam);
}
"""

# COSMOS ATMO-SKY A2 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C5): the Sun GLARE quad. gl_compat has no bloom/HDR, so
# the exact 0.53° Sun disc is an invisible dot; this additive radial-falloff quad is the perceptual job real
# glare does. blend_add + depth_draw_never (never occludes; the planet's depth kills it behind the disc, the
# star-dome discipline). Its `intensity` is driven ×occ(cam) so it dies at sunset/eclipse/umbra. Built ONLY
# under FP_SUN_PRESENCE. `disable_fog` is intrinsic (fog_disabled) — celestial, beyond the atmosphere.
const _SUN_GLARE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
uniform vec3 glare_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float intensity = 1.0;
// B1 (FP_SUN_APPARENT): tight=0 ⇒ the shipped single-lobe falloff (byte-identical); tight=1 ⇒ a bright
// tight core (~1.5 disc radii @ ~0.9 over a 5-radii quad ⇒ r≈0.3) PLUS a soft wide skirt (to the 5-radii edge).
uniform float tight = 0.0;
void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;   // 0 at centre → 1 at the quad edge (5 disc radii)
	float a_ship = smoothstep(1.0, 0.0, r);
	a_ship *= a_ship;                           // sharpen the falloff toward a bright core
	float core = smoothstep(0.30, 0.0, r) * 0.9;    // 0.9 at centre → 0 at ~1.5 disc radii
	float skirt = smoothstep(1.0, 0.0, r) * 0.35;   // soft additive skirt out to the quad edge
	float a = mix(a_ship, max(core, skirt), tight);
	ALBEDO = glare_color * a * intensity;
}
"""

# COSMOS ATMO-SKY A6 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C4): the atmosphere shell — ONE object that is the blue
# limb HALO from outside AND the horizon-band sky from inside. A SphereMesh of radius R+SHELL_ATMO_MULT·ATMO_TOP,
# planet-centred; cull_front (one fragment per view direction, inside OR outside) + blend_add + depth_draw_never
# (never occludes; the planet's own depth kills it behind the disc — the star-dome discipline). The closed-form
# per-pixel fragment mirrors CosmosSky.shell_geom + shell_limb_color EXACTLY (gate G-AS-LIMB): chord through the
# shell (planet-occluded) × ρ(h_min) × the SAME day/T/band curves as C1/C2, so the limb reddens across the
# terminator and darkens on the night side by the ground-sunset curves — seamless by construction. No loops/
# textures/volumetrics (gl_compat-safe). StandardMaterial has no analytic twin, so the fallback is: flag off ⇒
# no shell node at all (the camera sky A3 is the base layer). Uniforms fed each frame in _update_sky.
const _ATMO_SHELL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, blend_add, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec3 cam = vec3(0.0);
uniform vec3 centre = vec3(0.0);
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float r_solid = 6371.0;
uniform float r_outer = 7139.0;
uniform float h_scale = 128.0;
uniform float term_mu = 0.12;
uniform float gain = 1.6;
// B2 (FP_ATMO_PATH_SHELL): path_norm=0 ⇒ the shipped single-sample strength·gain (byte-identical); path_norm=1
// ⇒ a bounded, budget-normalized limb intensity (peak ≈0.35) so the sky is never blown cyan-white.
uniform float path_norm = 0.0;
uniform float peak_l = 0.95;
uniform float sat = 15.0;
uniform vec3 rayleigh_blue : source_color = vec3(0.15, 0.38, 0.92);
float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float h = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(h + 6.07995, -1.6364)); }
vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }
float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 dir = normalize(wp - cam);
	vec3 oc = centre - cam;
	float dc2 = dot(oc, oc);
	float tca = dot(oc, dir);
	float b2 = max(dc2 - tca * tca, 0.0);
	float b = sqrt(b2);
	if (b >= r_outer) { ALBEDO = vec3(0.0); }
	else {
		float h_min = b - r_solid;
		float half_out = sqrt(max(r_outer * r_outer - b2, 0.0));
		float seg_start = max(tca - half_out, 0.0);
		float seg_end = tca + half_out;
		if (b < r_solid) { float t_hit = tca - sqrt(max(r_solid * r_solid - b2, 0.0)); if (t_hit > 0.0) seg_end = min(seg_end, t_hit); }
		float chord = max(seg_end - seg_start, 0.0);
		// Sun-angle datum for day/night gating + terminator tint. Shipped (path_norm=0): the infinite-line
		// closest-approach point (byte-identical). B2 (path_norm=1): the CHORD-MIDPOINT direction — the point in
		// the atmosphere segment actually being viewed. The closest-approach proxy lands on the HORIZON RING for
		// near-vertical surface rays (mu≈0 ⇒ the terminator band tint + a lit night zenith), which is exactly the
		// olive day sky + blue night halo the pilot reported; the midpoint is correct for surface AND orbit.
		vec3 xca = (cam + tca * dir) - centre;
		vec3 xmid = (cam + 0.5 * (seg_start + seg_end) * dir) - centre;
		vec3 xsel = (path_norm > 0.5) ? xmid : xca;
		vec3 xhat = (length(xsel) > 1e-4) ? normalize(xsel) : -normalize(sun_dir);   // degenerate ⇒ dark (night)
		float mu = dot(xhat, normalize(sun_dir));
		float strength = chord * exp(-max(h_min, 0.0) / h_scale) / h_scale;
		vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
		// B2: bound the single-sample overestimate to the §3.5 budget (peak ≈0.35) via a saturating transform.
		float l_ship = strength * gain;
		float l_path = peak_l * (1.0 - exp(-strength / sat));
		float l = mix(l_ship, l_path, path_norm) * _day(mu);
		ALBEDO = rayleigh_blue * tint * l;
	}
}
"""

# Shipped flat-ambient values (main._setup_environment) — reused verbatim as the NIGHT floor so a
# night sky matches today's look exactly, and DAY brightens above them.
const _NIGHT_AMBIENT := Color(1, 1, 1)
const _NIGHT_AMBIENT_ENERGY := 0.35        # dimmed floor at night; ramps to 1.0 (shipped) at high noon
const _SKY_DAY := Color(0.62, 0.74, 0.86)  # main.SKY_COLOR
const _SKY_NIGHT := Color(0.02, 0.02, 0.05)

# ---------------------------------------------------------------------------------------
# SN4 — the altitude atmosphere ramp (SN4a) + analytic sun-occlusion dimmer (SN4b). All the curve/geometry
# math below is PURE STATIC (engine-free): it is composed onto the shipped sun-elevation ramp inside
# _ramp_environment ONLY when the flags (CubeSphere.ATMO_VISUAL_RAMP / .SN_SUN_OCCLUSION) are on, and is
# driven DIRECTLY (flag-independent) by the G-SN-RAMP / G-SN-OCCLUDE gates. Every function is C¹ in its
# radial-altitude argument h (smoothstep is Hermite ⇒ zero-slope, C¹-continuous endpoints; exp is C∞), so
# the whole ramp is seamless (SEAMLESS-SCALES). ZERO bytes: these are property writes, no geometry/material.
# ---------------------------------------------------------------------------------------

## Fog scale height (blocks) — shared with the SN1 drag model (OrbitalState.DRAG_H_SCALE = 128).
const H_SCALE := 128.0
## Atmosphere ceiling (blocks) == CubeSphere.ATMO_TOP; the space_mix band spans 0.5·H_ATMO..2.5·H_ATMO.
const H_ATMO := 384.0
## Sea-level fog density — the shipped main._setup_environment value, so fog_density(h=0) is byte-identical.
const FOG0 := 1.0
## Ambient-energy multiplier floor reached in space (the sky no longer scatters skylight).
const AMBIENT_SPACE := 0.15
## space_mix smoothstep band (blocks): sky/star/ambient cross from atmosphere to space between these.
const SPACE_MIX_LO := 0.5 * H_ATMO      # 192
const SPACE_MIX_HI := 2.5 * H_ATMO      # 960
## Sun-occlusion soft penumbra half-width (rad), ~ the solar angular radius (SN4b, §6.3).
const OCC_PENUMBRA := 0.005
## Ambient floor multiplier applied by SN4b in the orbital umbra (the night side keeps a faint fill).
const AMBIENT_UMBRA := 0.25

## space_mix(h): 0 in the atmosphere → 1 in space, C¹ (smoothstep). On an airless body (has_atmo=false) the
## sky is black at the surface, so space_mix ≡ 1 everywhere.
static func space_mix(h: float, has_atmo: bool) -> float:
	if not has_atmo:
		return 1.0
	return smoothstep(SPACE_MIX_LO, SPACE_MIX_HI, h)

## Depth-fog density at altitude h: FOG0·exp(−h/H_SCALE), C∞. Airless body ⇒ 0 (no atmosphere to fog).
static func fog_density_at(h: float, has_atmo: bool) -> float:
	if not has_atmo:
		return 0.0
	return FOG0 * exp(-h / H_SCALE)

## Ambient-energy multiplier at space_mix sm: 1.0 (surface) → AMBIENT_SPACE (space).
static func ambient_scale(sm: float) -> float:
	return lerpf(1.0, AMBIENT_SPACE, sm)

## Raw occlusion factor in [0,1]: 1 fully sunlit, 0 in the umbra (the body's disc covers the sun), C¹ through
## the penumbra. sun_dir = unit direction TOWARD the sun; p = player position from the planet centre (blocks);
## r_vox = the occluding body's voxel radius. α = angle(sun_dir, −p̂); the body occludes when α < asin(R/|p|).
static func occlusion_factor(sun_dir: Vector3, p: Vector3, r_vox: float) -> float:
	var dist := p.length()
	if dist <= 0.0:
		return 1.0
	var ang_radius := asin(clampf(r_vox / dist, 0.0, 1.0))   # the body's angular radius from the player
	var to_center := -p / dist
	var alpha := acos(clampf(sun_dir.dot(to_center), -1.0, 1.0))
	# α small ⇒ sun behind the body's disc ⇒ umbra ⇒ 0; α large ⇒ clear of the disc ⇒ sunlit ⇒ 1.
	return smoothstep(ang_radius - OCC_PENUMBRA, ang_radius + OCC_PENUMBRA, alpha)

## The DirectionalLight energy under SN4b: the occlusion factor blended with the shipped light (1.0) by
## altitude authority = space_mix(h), so the elevation ramp owns the surface (→ 1.0, byte-identical hand-off)
## and the occlusion dimmer owns space (→ occlusion_factor). Continuous everywhere (both terms C¹ in h).
static func occlusion_light(sun_dir: Vector3, p: Vector3, h: float, r_vox: float, has_atmo: bool) -> float:
	var authority := space_mix(h, has_atmo)
	return lerpf(1.0, occlusion_factor(sun_dir, p, r_vox), authority)

## The ambient multiplier under SN4b: in the orbital umbra the ambient fill drops to AMBIENT_UMBRA, again
## blended in by altitude authority so the surface is untouched. Continuous; 1.0 when fully sunlit.
static func occlusion_ambient(sun_dir: Vector3, p: Vector3, h: float, r_vox: float, has_atmo: bool) -> float:
	var authority := space_mix(h, has_atmo)
	var occ := occlusion_factor(sun_dir, p, r_vox)
	return lerpf(1.0, lerpf(AMBIENT_UMBRA, 1.0, occ), authority)

# ---------------------------------------------------------------------------------------
# COSMOS ATMO-SKY (docs/COSMOS-ATMO-SKY-DESIGN.md §3) — the UNIFIED atmosphere/day-night statics. ALL pure
# (engine-free), so the gate (verify_atmo_sky.gd) drives them DIRECTLY and is FLAG-INDEPENDENT; the A0-A6
# flags only decide whether the sky/light/shell COMPOSE them in-game. Every function is C¹ in its altitude/
# angle argument (smoothstep is Hermite; exp is C∞). ZERO bytes: scalar math, no geometry, no allocation.
# ---------------------------------------------------------------------------------------

## A3 (§3 C3): the IN-ATMOSPHERE authority — 1 at the surface, exactly 0 at/above ATMO_TOP (star-black in
## space). Replaces space_mix's 192..960 band with a 0.5·ATMO_TOP..ATMO_TOP fade so the whole tint/star
## crossover happens INSIDE the atmosphere (ρ(ATMO_TOP)=e⁻³≈5%). Airless body ⇒ 0 everywhere (no sky).
const ATMO_VIS_LO := 0.5 * H_ATMO            # 192 — start of the vis→0 fade
## A4 (§3 C1): the twilight penumbra half-width (rad) as a function of altitude. Long at the ground
## (~1.5-min sunset over the 45.5-min day), sharp in vacuum (a hard terminator from orbit).
const PEN_GROUND := 0.10                      # penumbra half-width at h=0 (rad) — the long ground twilight
const PEN_SPACE := 0.005                      # penumbra half-width in vacuum (rad) — ~solar angular radius
## A5/A6 (§3 C2/C4): the ABSOLUTE terminator half-width (in μ = n̂·ŝ) for the day/night great-circle factor.
const TERMINATOR_MU := 0.12                   # day(x̂) crosses 0→1 over ±this about x̂·ŝ = 0
## A5 (§3 C2): the globe night-hemisphere floor so it stays faintly earthshine-readable, never pure black.
const SHELL_NIGHT_FLOOR := 0.06
## A6 (§3 C4): the atmosphere shell outer radius = R + SHELL_ATMO_MULT·ATMO_TOP, and the additive limb tint.
const SHELL_ATMO_MULT := 2.0
const RAYLEIGH_BLUE := Color(0.15, 0.38, 0.92)   # the τ⃗-weighted Rayleigh sky/limb hue (taste; live-only look)
const SHELL_LIMB_GAIN := 1.6                  # additive limb/sky intensity scale (tuned once vs the ground sky)

## A3 atmo_vis(h): 1 (surface) → 0 (space), C¹. On an airless body there is no atmosphere ⇒ 0 everywhere.
static func atmo_vis(h: float, has_atmo: bool) -> float:
	if not has_atmo:
		return 0.0
	return 1.0 - smoothstep(ATMO_VIS_LO, H_ATMO, h)

## A4 pen(h): the twilight penumbra half-width (rad) — PEN_GROUND at the surface, PEN_SPACE at/above ATMO_TOP.
static func pen(h: float) -> float:
	return lerpf(PEN_GROUND, PEN_SPACE, clampf(h / H_ATMO, 0.0, 1.0))

## A4 occlusion_factor with a CALLER-SUPPLIED penumbra half-width (the altitude-varying twilight). Identical
## to occlusion_factor when penum == OCC_PENUMBRA; kept separate so occlusion_factor stays byte-untouched.
static func occlusion_factor_pen(sun_dir: Vector3, p: Vector3, r_vox: float, penum: float) -> float:
	var dist := p.length()
	if dist <= 0.0:
		return 1.0
	var ang_radius := asin(clampf(r_vox / dist, 0.0, 1.0))
	var to_center := -p / dist
	var alpha := acos(clampf(sun_dir.dot(to_center), -1.0, 1.0))
	return smoothstep(ang_radius - penum, ang_radius + penum, alpha)

## A4 C1: the ABSOLUTE DirectionalLight energy — occ(cam) ALWAYS (no space_mix authority lerp), with the
## altitude-widened penumbra pen(h). Dark side dark from EVERY camera position (kills the through-planet
## lighting); at the surface occ degenerates into the sun-below-horizon test (§2.2), so this IS the sunset
## dimmer too. NOTE: unlike occlusion_light this does NOT reach 1.0 on the surface day side unless the sun is
## up — that is the point (absolute day/night), so it is a SEPARATE function, not a byte-hand-off to shipped.
static func light_energy_absolute(sun_dir: Vector3, p: Vector3, h: float, r_vox: float) -> float:
	return occlusion_factor_pen(sun_dir, p, r_vox, pen(h))

## A4 C1: the ABSOLUTE ambient multiplier — lerp(AMBIENT_UMBRA, 1, occ) continuous, no authority. Night =
## the umbra floor everywhere (restores the pre-ORBITAL_SKY ambient-only night), day = full fill.
static func ambient_absolute(sun_dir: Vector3, p: Vector3, h: float, r_vox: float) -> float:
	var occ := occlusion_factor_pen(sun_dir, p, r_vox, pen(h))
	return lerpf(AMBIENT_UMBRA, 1.0, occ)

## A5/A6 C2: the ABSOLUTE terminator day factor at surface direction x̂ — mu = x̂·ŝ. 0 on the night
## hemisphere, 1 on the day hemisphere, exactly 0.5 on the great circle x̂·ŝ = 0 (⊥ ŝ by construction).
static func day_factor(mu: float) -> float:
	return smoothstep(-TERMINATOR_MU, TERMINATOR_MU, mu)

## A5 C2: the globe per-vertex darkening at mu = n̂·ŝ — NIGHT_FLOOR + (1−NIGHT_FLOOR)·day(mu), in [FLOOR,1].
static func shell_day_shade(mu: float) -> float:
	return SHELL_NIGHT_FLOOR + (1.0 - SHELL_NIGHT_FLOOR) * day_factor(mu)

## ATMO2 B3 (§2.3/§3.3): the NEAR-FIELD night floor (0.10) and the near-field moonshine gain (retuned 0.5→0.15
## to compose with the floor, §3.3). Separate from SHELL_NIGHT_FLOOR (0.06) and MOONSHINE_GAIN (0.5, ambient) so
## those stay byte-identical; the near field is slightly brighter at night than the far shell (foreground readability).
const NEAR_NIGHT_FLOOR := 0.10
const NEAR_MOONSHINE_GAIN := 0.15

## ATMO2 B3 C-NEAR twin: the absolute day/night shade multiplied onto the unshaded near materials at surface
## direction cosine mu = normalize(MODEL·v)·ŝ. shade = max(night_floor + (1−night_floor)·day(mu), moonshine).
## EQUALS shell_day_shade at the same surface point up to the floor difference (near/far agree by construction),
## so the pilot's near/far night split is killed. noon (mu=1) ⇒ 1; sun below the terminator ⇒ the night floor.
static func near_shade(mu: float, moonshine_term: float) -> float:
	return maxf(NEAR_NIGHT_FLOOR + (1.0 - NEAR_NIGHT_FLOOR) * day_factor(mu), clampf(moonshine_term, 0.0, 1.0))

## ATMO2 B3: the near-field moonshine term (composes into near_shade): gain·illum·moon_up·night_authority, ≤1.
static func near_moonshine(illum_frac: float, moon_up: float, night_authority: float) -> float:
	return NEAR_MOONSHINE_GAIN * clampf(illum_frac, 0.0, 1.0) * clampf(moon_up, 0.0, 1.0) * clampf(night_authority, 0.0, 1.0)

## A4 Moon self-phase twin: the disc-integrated lit fraction of a Lambert sphere at phase-cosine cos_phase
## (cos of the sun–observer angle seen from the Moon) = (1+cos_phase)/2 — EXACTLY EPH.illuminated_fraction,
## so the unshaded per-fragment Lambert shader and the ephemeris agree by construction (gate G-AS-ABSLIGHT).
static func lambert_illum_fraction(cos_phase: float) -> float:
	return 0.5 * (1.0 + clampf(cos_phase, -1.0, 1.0))

## A6 C4: the atmosphere shell outer radius (blocks) = r_solid + SHELL_ATMO_MULT·ATMO_TOP.
static func shell_outer_r(r_solid: float) -> float:
	return r_solid + SHELL_ATMO_MULT * H_ATMO

## A6 C4: the CLOSED-FORM view-ray shell geometry (no volumetrics). Returns [chord, h_min]:
##   • chord = the FORWARD path length (blocks) inside the atmosphere shell but OUTSIDE the solid planet and
##     in FRONT of the planet's near surface (the solid disc occludes the far atmosphere — the limb integral);
##     handles camera INSIDE the shell (near entry clamped to 0 ⇒ the horizon-band sky) and OUTSIDE it.
##   • h_min = closest-approach altitude of the ray to the planet centre, minus r_solid (drives ρ(max(h_min,0))).
## `dir` must be unit. Pure geometry — the GLSL twin mirrors this exactly (gate G-AS-LIMB).
static func shell_geom(cam: Vector3, centre: Vector3, dir: Vector3, r_solid: float, r_outer: float) -> Array:
	var oc := centre - cam
	var dc2 := oc.dot(oc)
	var tca := oc.dot(dir)
	var b2 := maxf(dc2 - tca * tca, 0.0)
	var b := sqrt(b2)
	var h_min := b - r_solid
	if b >= r_outer:
		return [0.0, h_min]                       # the ray misses the atmosphere entirely
	var half_out := sqrt(maxf(r_outer * r_outer - b2, 0.0))
	var seg_start := maxf(tca - half_out, 0.0)    # forward entry into the shell (0 when the camera is inside)
	var seg_end := tca + half_out                  # forward exit from the shell
	if b < r_solid:                                # the infinite line pierces the solid planet…
		var t_hit := tca - sqrt(maxf(r_solid * r_solid - b2, 0.0))   # …near-surface intersection
		if t_hit > 0.0:                            # …but only occlude when that hit is IN FRONT (else the ray looks away)
			seg_end = minf(seg_end, t_hit)
	return [maxf(seg_end - seg_start, 0.0), h_min]

## A6 C4: the additive limb/sky colour twin. mu = x̂_ca·ŝ (surface dir at closest approach); cos_day drives
## day(mu) so the limb reddens across the terminator and goes dark on the night side — the SAME curves as the
## ground sunset (C1) and the globe (C2). Out = RAYLEIGH_BLUE·mix(1,T(mu),band(mu)) · day(mu) · L, additive.
static func shell_limb_color(mu: float, chord: float, h_min: float) -> Color:
	var strength := chord * exp(-maxf(h_min, 0.0) / H_SCALE) / H_SCALE   # single-sample optical path ∝ chord·ρ(h_min)
	var t := scatter_tint(mu)
	var recolour := Color.WHITE.lerp(t, scatter_band(mu))
	var base := Color(RAYLEIGH_BLUE.r * recolour.r, RAYLEIGH_BLUE.g * recolour.g, RAYLEIGH_BLUE.b * recolour.b)
	var l := strength * day_factor(mu) * SHELL_LIMB_GAIN
	return Color(base.r * l, base.g * l, base.b * l)

## ATMO2 B2 (§2.4/§3.3): the peak limb intensity cap (the `l`-factor ceiling; base RAYLEIGH_BLUE luminance ≈
## 0.37 ⇒ peak output luminance ≈ 0.34 ≤ the §3.5 budget of 0.35) and the saturation scale of the optical
## column (tuned so the surface horizon band lands ≈0.2–0.3). These BOUND the single-sample overestimate.
const SHELL_PEAK_L := 0.95
const SHELL_SAT := 15.0

## ATMO2 B2: the BOUNDED atmosphere-shell colour. Same base×tint as shell_limb_color, but the strength is a
## SATURATING transform of the single-sample optical column (chord·ρ(h_min)/H) so it can never blow past the
## §3.5 budget (peak-limb ≈0.35, surface horizon band ≈0.2–0.3), monotone in the optical path, →0 on the night
## side. The GLSL twin mixes to this via `path_norm=1`. Colour = the shared scatter_tint/band (= surface path-T⃗).
static func shell_limb_color_path(mu: float, chord: float, h_min: float) -> Color:
	var ss := chord * exp(-maxf(h_min, 0.0) / H_SCALE) / H_SCALE     # the shipped single-sample optical column
	var l := SHELL_PEAK_L * (1.0 - exp(-ss / SHELL_SAT)) * day_factor(mu)   # bounded, budget-normalized, day-gated
	var t := scatter_tint(mu)
	var recolour := Color.WHITE.lerp(t, scatter_band(mu))
	var base := Color(RAYLEIGH_BLUE.r * recolour.r, RAYLEIGH_BLUE.g * recolour.g, RAYLEIGH_BLUE.b * recolour.b)
	return Color(base.r * l, base.g * l, base.b * l)

## ATMO2 (night-halo / green-sky fix): the shell's sun-angle datum μ = x̂·ŝ, computed at the CHORD MIDPOINT of the
## view ray through the shell — the twin of the B2 shader's `xmid` branch (path_norm=1). Replaces the infinite-line
## closest-approach proxy, which for near-vertical SURFACE rays lands on the horizon ring (μ≈0) and so lit the night
## zenith blue and tinted the day zenith olive. The midpoint is the atmosphere segment actually viewed, correct for
## surface AND orbit. Feed the result into shell_limb_color_path so a NIGHT-side upward view resolves to μ<0 ⇒ 0.
## Mirrors shell_geom's segment math exactly (gate G-B2 night-zero pins the twin). `dir`, `sun_dir` must be unit.
static func shell_view_mu(cam: Vector3, centre: Vector3, dir: Vector3, r_solid: float, r_outer: float, sun_dir: Vector3) -> float:
	var oc := centre - cam
	var dc2 := oc.dot(oc)
	var tca := oc.dot(dir)
	var b2 := maxf(dc2 - tca * tca, 0.0)
	if sqrt(b2) >= r_outer:
		return -1.0                                    # misses the shell (no contribution) ⇒ night default
	var half_out := sqrt(maxf(r_outer * r_outer - b2, 0.0))
	var seg_start := maxf(tca - half_out, 0.0)
	var seg_end := tca + half_out
	if sqrt(b2) < r_solid:
		var t_hit := tca - sqrt(maxf(r_solid * r_solid - b2, 0.0))
		if t_hit > 0.0:
			seg_end = minf(seg_end, t_hit)
	var pt := cam + dir * (0.5 * (seg_start + seg_end)) - centre
	if pt.length() < 1.0e-4:
		return -1.0                                    # degenerate (ray through centre) ⇒ dark
	return pt.normalized().dot(sun_dir.normalized())

# ---------------------------------------------------------------------------------------
# COSMOS ATMO2 (docs/COSMOS-ATMO2-DESIGN.md §3.2) — the OPTICAL-PATH kernel. The single physical law that
# colours the Sun disc/glare, the DirectionalLight, and (B2) the atmosphere shell. All PURE STATIC (engine-
# free), so the gate (G-B0-PATH) drives it DIRECTLY and is flag-independent. Two scale heights are split on
# purpose: H_SCALE=128 is the amplitude/gameplay height (fog, drag, halo thickness — unchanged, shared with
# SN1); H_OPT is the EXTINCTION-COLOUR height, chosen so the 1:1000 world's air-mass range matches the real
# Earth m-range the shipped τ⃗ were measured against (m_horizon≈18, m_limb≈36). One declared const buys a
# physical white-in-space → warm-noon → red-horizon → crimson-graze sun with NO regime switch, C¹ everywhere.
# ---------------------------------------------------------------------------------------

## §3.2: the extinction-colour scale height (blocks). Deliberately << H_SCALE (see the section note).
const H_OPT := 30.0
## §3.2 L(m): the broadband luminance extinction coefficient (dimmer sun through more air).
const TAU_LUM := 0.10

## §3.2 ρ_opt(h) = exp(−h/H_OPT): the extinction-colour density profile (distinct from the H_SCALE fog ρ).
static func rho_opt(h: float) -> float:
	return exp(-h / H_OPT)

## §3.2 normalizer N = H_OPT·(1−e^(−ATMO_TOP/H_OPT)): the vertical-from-ground optical column, so m=1 there.
static func opt_norm() -> float:
	return H_OPT * (1.0 - exp(-H_ATMO / H_OPT))

## §3.2 X_horiz(h): the tangent (horizontal) half-path optical column at altitude h (blocks). r_solid = R.
static func x_horiz(h: float, r_solid: float) -> float:
	return rho_opt(maxf(h, 0.0)) * sqrt(PI * (r_solid + maxf(h, 0.0)) * H_OPT / 2.0)

## §3.2 X_up(h,μ_v): the ascending-ray optical column. μ_v = dir·up ≥ 0. C¹; μ_v=1 ⇒ ≈H_OPT·ρ (plane-
## parallel vertical), μ_v=0 ⇒ ≡ X_horiz (the tangent fold) — 4 ops, no erf.
static func x_up(h: float, mu_v: float, r_solid: float) -> float:
	var hc := maxf(h, 0.0)
	return H_OPT * rho_opt(hc) / sqrt(mu_v * mu_v + 2.0 * H_OPT / (PI * (r_solid + hc)))

## §3.2 m(cam→sun ray): the NORMALIZED optical air mass along the viewer→sun ray. 0 for a space-clear LOS,
## ≈1 vertical-from-ground, ≈18 at the surface horizon, ≈36 through the full limb from orbit. C¹ across the
## tangent fold (μ_v=0) and the ATMO_TOP camera crossing (ρ_opt(ATMO_TOP)≈0 makes both branches meet). A pure
## function of (camera position, sun_dir) — NOT camera orientation — so the light it drives is orientation-
## invariant (G-B0-PATH). `sun_dir` is unit, TOWARD the sun. Airless body ⇒ 0 (no extinction).
static func optical_path_air_mass(cam: Vector3, sun_dir: Vector3, r_solid: float, has_atmo: bool) -> float:
	if not has_atmo:
		return 0.0
	var dist := cam.length()
	var h := dist - r_solid
	var up := (cam / dist) if dist > 1.0e-6 else Vector3.UP
	var mu_v := sun_dir.dot(up)                       # dir·up: +1 sun at zenith, 0 at horizon, <0 below
	var tca := -dist * mu_v                            # signed distance to closest approach (sun_dir·(centre−cam))
	var b2 := maxf(dist * dist - tca * tca, 0.0)
	var b := sqrt(b2)
	var h_min := b - r_solid                           # closest-approach altitude of the (infinite) ray
	var x := 0.0
	if h >= H_ATMO:
		# Camera in space: the forward ray re-enters the atmosphere only if it heads toward the planet
		# (tca>0) and grazes the shell (h_min<ATMO_TOP). Else the LOS is clear ⇒ m=0 (blinding white sun).
		if tca > 0.0 and h_min < H_ATMO:
			x = 2.0 * x_horiz(maxf(h_min, 0.0), r_solid)   # full chord through the shell (X_space)
		else:
			x = 0.0
	else:
		# Camera inside the atmosphere.
		if mu_v >= 0.0:
			x = x_up(h, mu_v, r_solid)                 # ascending ray out to space
		else:
			# Descending ray that clears the planet (fold at the tangent): X_down = 2·X_horiz(h_min) − X_up.
			x = 2.0 * x_horiz(maxf(h_min, 0.0), r_solid) - x_up(h, absf(mu_v), r_solid)
	return maxf(x, 0.0) / opt_norm()

## §3.2 T⃗(m) = exp(−τ⃗·m): the per-channel path transmittance colour (the sun/light hue). m=0 ⇒ WHITE.
static func path_transmittance(m: float) -> Color:
	return Color(exp(-TAU_R * m), exp(-TAU_G * m), exp(-TAU_B * m))

## §3.2 L(m) = exp(−τ_lum·m): the broadband brightness factor (1 in space, dimming toward the horizon).
static func path_luminance(m: float) -> float:
	return exp(-TAU_LUM * m)

# ---------------------------------------------------------------------------------------
# COSMOS-LOD-SKY task 2 (docs/COSMOS-LOD-SKY-DESIGN.md §6, §7.3) — celestial lighting statics. ALL pure
# (engine-free) so the gates (G-SKY-MOONSHINE / G-SKY-SCATTER / G-SHELL-TINT) drive them DIRECTLY and are
# FLAG-INDEPENDENT; the flags only decide whether _ramp_environment / _make_material COMPOSE them in-game.
# ZERO bytes: property/uniform writes only, no geometry, no per-frame allocation.
# ---------------------------------------------------------------------------------------

# --- L2/L3 Rayleigh scattering (§6). ONE model, μ = sin(sun elevation) = cos(zenith), three consumers. ---
## Sea-level vertical Rayleigh optical depths (real, 680/550/440 nm). Named per channel: R the least extinct.
const TAU_R := 0.042
const TAU_G := 0.098
const TAU_B := 0.245

## Kasten–Young relative air mass at μ = sin(elevation). μ clamped to [0,1] (the direct-sun term is defined
## down to the horizon; μ<0 is handled by sunset_weight/scatter_band fading the tint into night). m(1)=1
## (overhead), m(0)≈38 (horizon). C¹ in μ over (0,1]. Real formula: 1/(sin h + 0.50572·(h°+6.07995)^−1.6364).
static func air_mass(mu: float) -> float:
	var m := clampf(mu, 0.0, 1.0)
	var h_deg := rad_to_deg(asin(m))
	return 1.0 / (m + 0.50572 * pow(h_deg + 6.07995, -1.6364))

## Direct-light transmittance colour T_c(μ) = exp(−τ_c·m(μ)) — the sunrise/sunset/terminator colour, straight
## from the physics (no scripted gradient): pale-warm near noon → gold → orange → deep crimson at the horizon.
static func scatter_tint(mu: float) -> Color:
	var m := air_mass(mu)
	return Color(exp(-TAU_R * m), exp(-TAU_G * m), exp(-TAU_B * m))

## L2 GROUND weight: how strongly the scatter tint colours the sky. 0 with the Sun high (ordinary blue day),
## rising as it nears the horizon, back to 0 well below (deep night owns the floor). C¹ (smoothstep product).
const SUNSET_MU_HI := 0.50        # above this μ (elev ≳ 30°): no sunset tint — plain day
const SUNSET_MU_LO := -0.10       # below this μ (elev ≲ −6°): deep night — no direct-Sun colour
static func sunset_weight(mu: float) -> float:
	var hi := 1.0 - smoothstep(0.25, SUNSET_MU_HI, mu)     # fade out as the Sun climbs past the band
	var lo := smoothstep(SUNSET_MU_LO, 0.02, mu)           # fade out below the horizon into night
	return hi * lo

## L3 SHELL band weight: localise the tint to the terminator arc on the globe (μ∈[−0.05,0.25] ≈ 17° of arc,
## §6). 0 in full day (no tint, ALBEDO unchanged) and in deep night; a smooth bump peaking at the terminator.
const BAND_MU_LO := -0.05
const BAND_MU_HI := 0.25
static func scatter_band(mu: float) -> float:
	var up := smoothstep(BAND_MU_LO - 0.05, BAND_MU_LO + 0.05, mu)   # night → band
	var down := 1.0 - smoothstep(BAND_MU_HI - 0.10, BAND_MU_HI, mu)  # band → full day
	return up * down

## L3 per-vertex shell ALBEDO multiplier at μ = normalize(v)·sun_dir: mix(white, scatter_tint(μ), band(μ)).
## The GDScript twin of the shell shader's tint (the gate pins the shader to THIS curve; render is live-only).
static func shell_terminator_tint(mu: float) -> Color:
	var w := scatter_band(mu)
	return Color.WHITE.lerp(scatter_tint(mu), w)

# --- L1 moonshine (§7.3). v0 ambient (default), + lunar-eclipse dim/redden; v1 real light shares the energy. ---
## Ambient-energy gain of a full Moon over the night floor (D-LS1, taste; 0.5 of the floor).
const MOONSHINE_GAIN := 0.5
## Cool moonlight tint applied to the ambient light colour on the night side.
const MOONSHINE_TINT := Color(0.75, 0.80, 1.00)

## Extra night ambient energy from moonshine: gain · illuminated_fraction · moon_up · night_authority. 0 at new
## moon (f=0), by day (night_authority=0) or when the Moon is down (moon_up=0); monotone & C¹ in every argument.
static func moonshine_energy(illum_frac: float, moon_up: float, night_authority: float) -> float:
	return MOONSHINE_GAIN * clampf(illum_frac, 0.0, 1.0) * clampf(moon_up, 0.0, 1.0) * clampf(night_authority, 0.0, 1.0)

## Lunar-eclipse factor ∈ [0,1] at time t: 1 = Moon in full sunlight, 0 = Moon deep in Earth's umbra. Reuses
## occlusion_factor with the MOON as the occluded point and EARTH as the occluding body (radius r_earth), in
## Earth's inertial frame. Multiplies the illuminated fraction (dims moonshine) and drives the impostor redden.
static func moon_eclipse_factor(t: float) -> float:
	var sun_dir := EPH.dir_to("earth", "sun", t)
	var moon_p := EPH.body_pos_parent_v3("moon", t)        # Moon relative to Earth's centre (blocks, inertial)
	return occlusion_factor(sun_dir, moon_p, EPH.radius_of("earth"))

## Wire the sky to a clock (read each frame), the scene Environment (ramped; may be null → no ramp),
## and a camera provider (the Player; may be null → impostors sit around the origin). Builds the
## reused nodes once. Idempotent-safe: call once from main.gd under the flag.
func setup(clock: EPH.CosmosClock, env: Environment = null, cam_provider: Node = null) -> void:
	_clock = clock
	_env = env
	_cam_provider = cam_provider
	# B1 sub-flag (FP_SUN_GLOW, §3.4): enable the Compatibility-renderer glow with a HIGH hdr threshold so ONLY
	# the sun disc/glare (the sole ≥0.9-luminance residents of the §3.5 budget) bloom — the LDR-honest "bloom"
	# on gl_compat. Off ⇒ the Environment glow is untouched ⇒ byte-identical. Requires FP_SUN_APPARENT + an env.
	if CubeSphere.FP_SUN_GLOW and CubeSphere.FP_SUN_APPARENT and _env != null:
		_env.glow_enabled = true
		_env.glow_hdr_threshold = 0.92
		_env.glow_intensity = 0.8
		_env.glow_bloom = 0.1
	_build_nodes()
	_update_sky(0.0 if _clock == null else _clock.now())

func _build_nodes() -> void:
	# Resolve the sky placement radius ONCE (the flag is a compile-time const, so this never changes at runtime).
	# FP_SKY_DSKY_R off ⇒ the shipped literal 8000 ⇒ every downstream value is byte-identical to shipped.
	_dsky = d_sky_derived() if CubeSphere.FP_SKY_DSKY_R else D_SKY

	# --- Sun impostor: emissive smooth sphere (explicitly NON-voxel, D8: environmental, never a place).
	_sun = MeshInstance3D.new()
	_sun.name = "Sun"
	var sun_mesh := SphereMesh.new()
	sun_mesh.radial_segments = 32
	sun_mesh.rings = 16
	# B1 (FP_SUN_APPARENT): Godot's SphereMesh default radius is 0.5, so _place_impostor (which scales by the
	# requested world radius) renders the disc at HALF its intended angular size. Set radius 1.0 so the disc hits
	# its true 2.0° floor. Off ⇒ the shipped 0.5 default ⇒ byte-identical (half-size, the shipped look).
	if CubeSphere.FP_SUN_APPARENT:
		sun_mesh.radius = 1.0
		sun_mesh.height = 2.0
	_sun.mesh = sun_mesh
	var sun_mat := StandardMaterial3D.new()
	sun_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sun_mat.emission_enabled = true
	sun_mat.emission = Color(1.0, 0.96, 0.85)
	sun_mat.emission_energy_multiplier = 8.0
	sun_mat.albedo_color = Color(1.0, 0.96, 0.85)
	# BLACK-SKY FIX: the faceted Environment drives DEPTH FOG fully opaque at CAMERA_FAR·0.98 = 8820
	# ("so the space-black rim is hidden", main._setup_environment) — but the impostors sit at D_SKY =
	# 8000, i.e. ~93% into that ramp, so the Sun was being almost entirely repainted in fog colour (and
	# fog colour is ramped to the NIGHT sky colour after dusk ⇒ the Sun vanished outright). Celestial
	# bodies are BEYOND the atmosphere by definition and must never be fogged.
	sun_mat.disable_fog = true
	_sun.material_override = sun_mat
	_sun_mat = sun_mat                                    # A2: reddened by T(μ_cam) each frame under FP_SUN_PRESENCE
	_sun.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sun)

	# --- A2 (FP_SUN_PRESENCE): the additive Sun glare quad. Built ONLY under the flag ⇒ no extra node/draw with it
	# off (byte-identical). Placed + intensity-driven each frame in _update_sky; billboarded toward the camera.
	if CubeSphere.FP_SUN_PRESENCE:
		_glare = MeshInstance3D.new()
		_glare.name = "SunGlare"
		_glare.mesh = QuadMesh.new()
		var gsh := Shader.new()
		gsh.code = _SUN_GLARE_SHADER
		_glare_mat = ShaderMaterial.new()
		_glare_mat.shader = gsh
		_glare_mat.set_shader_parameter("glare_color", Vector3(1.0, 0.95, 0.85))
		_glare_mat.set_shader_parameter("intensity", 1.0)
		# B1 (FP_SUN_APPARENT): retune the glare into a tight bright core + soft skirt (tight=1); off ⇒ tight=0 =
		# the shipped single-lobe falloff (the uniform defaults to 0.0 ⇒ byte-identical).
		if CubeSphere.FP_SUN_APPARENT:
			_glare_mat.set_shader_parameter("tight", 1.0)
		_glare.material_override = _glare_mat
		_glare.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_glare.sorting_offset = -0.5                      # sort with the additive dome, never against the opaque disc
		add_child(_glare)

	# --- THE DirectionalLight (day-night sun light). Shadows OFF by default (D11 / risk #6).
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "SunLight"
	_sun_light.shadow_enabled = false
	_sun_light.light_energy = 1.0
	add_child(_sun_light)

	# --- L1 v1 (SKY_MOONSHINE_LIGHT, §7.3): a real second DirectionalLight for moon-shadows-on-terrain. Built
	# ONLY under the flag (draw-count VISUAL-RISK on gl_compat — an extra additive lit pass), aimed/energised in
	# _update_sky. Flag off ⇒ never created ⇒ byte-identical (no extra light in the scene). Requires SKY_MOONSHINE.
	if CubeSphere.SKY_MOONSHINE and CubeSphere.SKY_MOONSHINE_LIGHT:
		_moon_light = DirectionalLight3D.new()
		_moon_light.name = "MoonLight"
		_moon_light.shadow_enabled = false
		_moon_light.light_color = MOONSHINE_TINT
		_moon_light.light_energy = 0.0
		add_child(_moon_light)

	# --- Moon impostor: a SHADED sphere lit by the sun light ⇒ its phase falls out for free (§4.4).
	_moon = MeshInstance3D.new()
	_moon.name = "Moon"
	var moon_mesh := SphereMesh.new()
	moon_mesh.radial_segments = 32
	moon_mesh.rings = 16
	# B1 (FP_SUN_APPARENT): same SphereMesh-0.5 fix as the Sun — restore the Moon's true 1.5° angular floor.
	if CubeSphere.FP_SUN_APPARENT:
		moon_mesh.radius = 1.0
		moon_mesh.height = 2.0
	_moon.mesh = moon_mesh
	_moon_mat = StandardMaterial3D.new()
	_moon_mat.albedo_color = Color(0.72, 0.72, 0.70)
	_moon_mat.roughness = 1.0
	_moon_mat.metallic = 0.0
	_moon_mat.disable_fog = true                          # BLACK-SKY FIX — see the Sun note above (fog opaque at 8820 > D_SKY)
	_moon.material_override = _moon_mat
	# --- A4 (FP_LIGHT_ABSOLUTE): the unshaded self-phase material replaces the shaded StandardMaterial so the Moon
	# does NOT black out when C1 dims the global light at night. Built + selected ONLY under the flag ⇒ off is
	# byte-identical (override stays the shipped _moon_mat). The eclipse redden then feeds `base_albedo` (see _update_sky).
	if CubeSphere.FP_LIGHT_ABSOLUTE:
		var msh := Shader.new()
		msh.code = _MOON_PHASE_SHADER
		_moon_phase_mat = ShaderMaterial.new()
		_moon_phase_mat.shader = msh
		_moon_phase_mat.set_shader_parameter("base_albedo", _MOON_ALBEDO_BASE)
		_moon_phase_mat.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		# B4 (FP_MOON_PRESENCE): raise the flat 0.02 ambient to an EARTHSHINE FLOOR so a crescent/new moon is a
		# faint readable disc, not black-on-black. Off ⇒ the shader default 0.02 stands ⇒ byte-identical look.
		if CubeSphere.FP_MOON_PRESENCE:
			_moon_phase_mat.set_shader_parameter("ambient", MOON_EARTHSHINE)
		_moon.material_override = _moon_phase_mat
	_moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_moon)

	# --- Star dome: one big inverted sphere, rotated by −Earth spin.
	# BLACK-SKY FIX (live screenshot pass, 2026-07-17): the O0 placeholder was an OPAQUE near-black
	# StandardMaterial dome. Being opaque, it OCCLUDED the Environment background entirely — so the
	# day-sky blue that _ramp_environment writes to background_color was never visible, and the sky
	# rendered black at ALL times of day (confirmed live: black in 4/4 quadrants). It also carried no
	# actual stars (a flat dark tint), so night was an empty void too. Fix = an ADDITIVE shader dome:
	#   • blend_add + depth_draw_never ⇒ it NEVER occludes; the ramped background shows through and the
	#     dome only ADDS light. Depth TEST stays on, so the opaque Sun/Moon impostors (at D_SKY, nearer
	#     than the dome at 1.05·D_SKY) still correctly occlude the stars behind them.
	#   • procedural hashed starfield (no texture assets — stays asset-free per O0) so night is starry.
	#   • star_fade uniform, driven from the same sun-elevation ramp ⇒ stars vanish by day (additive
	#     black adds nothing) and bloom in at dusk. NEVER-OOM: one mesh, one material, zero per-frame alloc.
	_stars = MeshInstance3D.new()
	_stars.name = "StarDome"
	var star_mesh := SphereMesh.new()
	star_mesh.radius = _dsky * STAR_DOME_MULT
	star_mesh.height = _dsky * STAR_DOME_MULT * 2.0
	star_mesh.radial_segments = 24
	star_mesh.rings = 12
	_stars.mesh = star_mesh
	var star_shader := Shader.new()
	star_shader.code = STAR_DOME_SHADER
	_star_mat = ShaderMaterial.new()
	_star_mat.shader = star_shader
	_star_mat.set_shader_parameter("star_fade", 1.0)
	_stars.material_override = _star_mat
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Draw the dome BEFORE geometry it must never hide; additive + no depth-write already guarantee it
	# cannot occlude, this just keeps it out of the transparent sort against the impostors.
	_stars.sorting_offset = -1.0
	add_child(_stars)

	# --- A6 (FP_ATMO_SHELL): the atmosphere limb/sky shell. Built ONLY under the flag ⇒ no node/draw with it off
	# (byte-identical). Radius = R + SHELL_ATMO_MULT·ATMO_TOP, planet-centred at the scene origin; the near-space
	# (h < D_ENGAGE) regime is unscaled so it aligns with the unscaled far ring exactly. Uniforms driven per frame.
	if CubeSphere.FP_ATMO_SHELL:
		var r_vox := CosmosGravity.r_vox(OBSERVER)
		var r_outer := shell_outer_r(r_vox)
		_atmo_shell = MeshInstance3D.new()
		_atmo_shell.name = "AtmosphereShell"
		var ash_mesh := SphereMesh.new()
		ash_mesh.radius = r_outer
		ash_mesh.height = r_outer * 2.0
		ash_mesh.radial_segments = 48
		ash_mesh.rings = 24
		_atmo_shell.mesh = ash_mesh
		var ash_sh := Shader.new()
		ash_sh.code = _ATMO_SHELL_SHADER
		_atmo_shell_mat = ShaderMaterial.new()
		_atmo_shell_mat.shader = ash_sh
		_atmo_shell_mat.set_shader_parameter("centre", Vector3.ZERO)
		_atmo_shell_mat.set_shader_parameter("r_solid", r_vox)
		_atmo_shell_mat.set_shader_parameter("r_outer", r_outer)
		_atmo_shell_mat.set_shader_parameter("h_scale", H_SCALE)
		_atmo_shell_mat.set_shader_parameter("term_mu", TERMINATOR_MU)
		_atmo_shell_mat.set_shader_parameter("gain", SHELL_LIMB_GAIN)
		_atmo_shell_mat.set_shader_parameter("rayleigh_blue", Vector3(RAYLEIGH_BLUE.r, RAYLEIGH_BLUE.g, RAYLEIGH_BLUE.b))
		# B2 (FP_ATMO_PATH_SHELL): switch the shell to the bounded budget-normalized limb intensity. Off ⇒
		# path_norm stays 0 ⇒ the shipped single-sample strength·gain ⇒ byte-identical.
		if CubeSphere.FP_ATMO_PATH_SHELL:
			_atmo_shell_mat.set_shader_parameter("path_norm", 1.0)
			_atmo_shell_mat.set_shader_parameter("peak_l", SHELL_PEAK_L)
			_atmo_shell_mat.set_shader_parameter("sat", SHELL_SAT)
		_atmo_shell.material_override = _atmo_shell_mat
		_atmo_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_atmo_shell.sorting_offset = -0.9                 # additive, with the dome; never sorts against the opaque discs
		add_child(_atmo_shell)

	# --- COSMOS-LOD-SKY M2 (FP_MOON_RING): the Moon's coarse far ring. Created ONLY when the flag + MULTI_BODY
	# are on (the Moon facets must exist in the atlas); built lazily on the IMPOSTOR→RING promotion and placed to
	# match the impostor exactly (see _update_moon_ring). The tier decision comes from FP_BODY_LOD's per-frame
	# consult. Flag off ⇒ this node never exists ⇒ byte-identical (the impostor path above is untouched).
	if CubeSphere.FP_MOON_RING and CubeSphere.MULTI_BODY:
		FacetAtlas.warm_up()                              # idempotent; ensures the Moon body rows exist
		var mbi := FacetAtlas.body_index("moon")
		if mbi >= 0:
			_moon_ring = MoonFarRing.new()
			_moon_ring.name = "MoonFarRing"
			add_child(_moon_ring)
			_moon_ring.setup(mbi)

func _process(_delta: float) -> void:
	if _clock == null:
		return
	# COSMOS-PERF FALL-ALTRATE (FP_FALL_ATMO_THROTTLE): off ⇒ the shipped every-frame recompute (byte-identical).
	if not CubeSphere.FP_FALL_ATMO_THROTTLE:
		_update_sky(_clock.now())
		return
	# Throttle the whole recompute during a fast descent: derive the radial (altitude) speed from the camera
	# origin distance, then hold the last uniforms unless motion is slow/steady (converge exactly) or
	# FALL_THROTTLE_MS has elapsed. The sun/stars freeze for ≤ FALL_THROTTLE_MS while plummeting (imperceptible).
	var now_usec := Time.get_ticks_usec()
	var d := _camera_origin().length()
	var vspeed := 0.0
	if _atmo_prev_usec >= 0:
		vspeed = FallThrottle.radial_speed(_atmo_prev_d, d, float(now_usec - _atmo_prev_usec) / 1.0e6)
	_atmo_prev_d = d
	_atmo_prev_usec = now_usec
	var now_msec := Time.get_ticks_msec()
	var ms_since := (now_msec - _atmo_apply_msec) if _atmo_apply_msec >= 0 else 0x7fffffff
	if FallThrottle.should_reapply(true, vspeed, ms_since):
		_atmo_apply_msec = now_msec
		_update_sky(_clock.now())

## Re-place the sky from the ephemeris at time t. ONLY transforms/uniforms are written (no allocation,
## no geometry rebuild) — the per-frame cost is a handful of node writes (§4.1). NOTE: CosmosSky is a
## direct child of an IDENTITY node (main / the pinned PlanetRoot frame), so child LOCAL transforms
## equal their globals; writing `.transform` (not `.global_transform`) is both correct AND avoids the
## headless `!is_inside_tree()` global-transform stall the gate would otherwise hit.
func _update_sky(t: float) -> void:
	var cam_origin := _camera_origin()

	# Sun direction in Earth's BODY-FIXED frame ⇒ day-night emerges from Earth's spin (§8.2).
	var sun_dir := EPH.dir_to_bodyfixed(OBSERVER, "sun", t)
	if sun_dir == Vector3.ZERO:
		sun_dir = Vector3(1.0, 0.0, 0.0)

	_cur_sun_dir = sun_dir                                   # L3: forwarded to the shell tint uniform (current_sun_dir)

	# The light comes FROM the sun: a DirectionalLight shines along its local −Z, so aim −Z at −sun_dir
	# (i.e. +Z = sun_dir). look_at points local −Z at the target, so look from cam toward (cam − sun_dir).
	_sun_light.transform = _looking_along(-sun_dir, cam_origin)

	# --- A1/A2 planet-occlusion + presence inputs (evaluated only when a flag is on ⇒ byte-identical off) ---
	var r_vox_sky := 0.0
	var occ_cam := 1.0                                       # sun visibility from the camera (0 = behind the planet disc)
	if CubeSphere.FP_SKY_PLANET_OCCLUDE or CubeSphere.FP_SUN_PRESENCE:
		r_vox_sky = CosmosGravity.r_vox(OBSERVER)
		occ_cam = occlusion_factor(sun_dir, cam_origin, r_vox_sky)
	# B0 (FP_SUN_PATHLIGHT, §2.6): unify the disc/glare penumbra on pen(h) — the same altitude-widened twilight
	# the absolute light uses — so the disc/glare and the DirectionalLight die together across the terminator.
	if CubeSphere.FP_SUN_PATHLIGHT and (CubeSphere.FP_SKY_PLANET_OCCLUDE or CubeSphere.FP_SUN_PRESENCE):
		occ_cam = occlusion_factor_pen(sun_dir, cam_origin, r_vox_sky, pen(cam_origin.length() - r_vox_sky))

	# Sun impostor: at cam + sun_dir·D_SKY, radius sized to its exact angular diameter. A2 floors the angular
	# size (the real 0.53° disc is an invisible ~8-px dot on gl_compat with no glare); off ⇒ the exact size.
	var sun_ang := EPH.angular_diameter("sun", OBSERVER, t)
	if CubeSphere.FP_SUN_PRESENCE:
		sun_ang = maxf(sun_ang, deg_to_rad(CubeSphere.SUN_MIN_ANG_DEG))
	var sun_pos := cam_origin + sun_dir * _dsky
	var sun_r := _dsky * tan(sun_ang * 0.5)
	_place_impostor(_sun, sun_pos, sun_r)

	# Moon impostor: body-fixed direction from Earth, exact angular size (A2-floored), lit by the shared light.
	var moon_dir := EPH.dir_to_bodyfixed(OBSERVER, "moon", t)
	if moon_dir == Vector3.ZERO:
		moon_dir = Vector3(-1.0, 0.0, 0.0)
	var moon_ang := EPH.angular_diameter("moon", OBSERVER, t)
	if CubeSphere.FP_SUN_PRESENCE:
		moon_ang = maxf(moon_ang, deg_to_rad(CubeSphere.MOON_MIN_ANG_DEG))
	_place_impostor(_moon, cam_origin + moon_dir * _dsky, _dsky * tan(moon_ang * 0.5))

	# A4 (FP_LIGHT_ABSOLUTE): drive the Moon self-phase shader's sun direction — its lit hemisphere faces the
	# Sun exactly as the shipped shaded material did under the DirectionalLight, but unshaded ⇒ never blacks out
	# when C1 dims the global light at night. No-op unless the phase material was built (byte-identical off).
	if _moon_phase_mat != null:
		_moon_phase_mat.set_shader_parameter("sun_dir", sun_dir)

	# A2 (FP_SUN_PRESENCE): redden the Sun disc by the direct-light transmittance T(μ_cam) so it agrees with the
	# sunset sky, and drive the additive glare quad (billboarded at the Sun, brightness ×occ so it dies at
	# sunset/eclipse/umbra). occ_cam is the same planet-occlusion the disc uses. Flag off ⇒ none of this runs.
	if CubeSphere.FP_SUN_PRESENCE:
		# B0 (FP_SUN_PATHLIGHT): the disc/glare colour is the optical-PATH transmittance T⃗(m) along the
		# camera→sun ray (WHITE in space, warm at noon, red at the horizon) and its brightness is L(m)·occ —
		# NOT the camera-ELEVATION K–Y curve, which reddened the sun in vacuum. Off ⇒ the shipped K–Y path.
		var st: Color
		var lum := 1.0
		if CubeSphere.FP_SUN_PATHLIGHT:
			var r_ps := r_vox_sky if r_vox_sky > 0.0 else CosmosGravity.r_vox(OBSERVER)
			var m_sun := optical_path_air_mass(cam_origin, sun_dir, r_ps, OrbitalState.has_atmo(OBSERVER))
			st = path_transmittance(m_sun)
			lum = path_luminance(m_sun)
		else:
			var up_s := cam_origin.normalized() if cam_origin.length() > 1.0 else Vector3.UP
			var mu_cam := sun_dir.dot(up_s)
			st = scatter_tint(mu_cam)                        # air_mass clamps μ∈[0,1]; horizon ⇒ deep crimson
		var reddened := Color(_SUN_EMISSION_BASE.r * st.r, _SUN_EMISSION_BASE.g * st.g, _SUN_EMISSION_BASE.b * st.b)
		if _sun_mat != null:
			_sun_mat.emission = reddened
			_sun_mat.albedo_color = reddened
			if CubeSphere.FP_SUN_PATHLIGHT:
				# Disc core stays white×T⃗; energy ∝ L(m)·occ so it is blinding in space, dim-red at sunset,
				# gone in the umbra (the impostor is a crisp disc, not the K–Y-dimmed blob).
				_sun_mat.emission_energy_multiplier = 8.0 * lum * maxf(occ_cam, 0.0)
		if _glare != null:
			_place_glare(sun_pos, sun_r * CubeSphere.SUN_GLARE_RADII, cam_origin)
			var glare_i := (lum * occ_cam) if CubeSphere.FP_SUN_PATHLIGHT else occ_cam
			_glare_mat.set_shader_parameter("intensity", glare_i)
			_glare_mat.set_shader_parameter("glare_color", Vector3(reddened.r, reddened.g, reddened.b))
			_glare.visible = glare_i > 0.001

	# A1 (FP_SKY_PLANET_OCCLUDE): hide the Sun/Moon impostors when the planet disc covers their direction (once A0
	# renders the planet at d≫D_SKY the opaque discs would otherwise draw IN FRONT of it). occlusion_factor==0
	# means the body is behind the disc. Flag off ⇒ both stay visible (byte-identical). Star-dome mask below.
	if CubeSphere.FP_SKY_PLANET_OCCLUDE:
		_sun.visible = occ_cam >= 0.5
		_moon.visible = occlusion_factor(moon_dir, cam_origin, r_vox_sky) >= 0.5

	# --- L1 MOONSHINE (SKY_MOONSHINE, §7.3). Compute the Moon geometry _ramp_environment reads, redden the
	# impostor through a lunar eclipse, and (v1) aim the optional real second light. Flag off ⇒ this whole block
	# is skipped: the moonshine inputs stay 0 (no ambient add) and the Moon albedo stays the shipped grey.
	if CubeSphere.SKY_MOONSHINE:
		var up := cam_origin.normalized() if cam_origin.length() > 1.0 else Vector3.UP
		_moon_up = clampf(moon_dir.dot(up), 0.0, 1.0)
		_moon_illum = EPH.illuminated_fraction(OBSERVER, "moon", "sun", t)
		_moon_eclipse = moon_eclipse_factor(t)
		# Eclipse redden: blend the shipped grey toward the §6 horizon crimson as the Moon enters the umbra.
		var umbra := scatter_tint(0.0)                       # deep crimson (m≈38 horizon transmittance)
		var moon_albedo := _MOON_ALBEDO_BASE.lerp(umbra, 1.0 - _moon_eclipse)
		# ATMO2 (bug-3 fix): compose the atmospheric path transmittance so the Moon obeys the SAME law as the Sun —
		# neutral overhead, red at the horizon. Off ⇒ the shipped eclipse-only grey (byte-identical). The eclipse
		# redden above is now rare (incl=5.1° under FP_MOON_PRESENCE) so this is the Moon's dominant colour law.
		if CubeSphere.FP_SUN_PATHLIGHT:
			moon_albedo = moon_path_albedo(moon_albedo, cam_origin, moon_dir, CosmosGravity.r_vox(OBSERVER), OrbitalState.has_atmo(OBSERVER))
		# A4: under the self-phase shader the eclipse redden feeds `base_albedo`; else the shipped StandardMaterial.
		if _moon_phase_mat != null:
			_moon_phase_mat.set_shader_parameter("base_albedo", moon_albedo)
		else:
			_moon_mat.albedo_color = moon_albedo
		if _moon_light != null:                              # v1 (SKY_MOONSHINE_LIGHT): a real −moon_dir light
			_moon_light.transform = _looking_along(-moon_dir, cam_origin)
			var night_authority := 1.0 - clampf((clampf(sun_dir.dot(up), -1.0, 1.0) + 0.15) / 0.30, 0.0, 1.0)
			_moon_light.light_energy = CubeSphere.MOON_LIGHT_MAX * _moon_illum * _moon_eclipse * night_authority

	# Star dome: centred on the camera, rotated by −Earth spin (the stars wheel as the planet turns).
	var spin := EPH.spin_angle(OBSERVER, t)
	var star_basis := Basis(Vector3(0, 0, 1), -spin)
	_stars.transform = Transform3D(star_basis, cam_origin)
	# A1 (FP_SKY_PLANET_OCCLUDE): feed the star-dome planet-disc mask (LOCAL dome frame, so it composes with the
	# −spin rotation). Above the surface the disc covers a real solid angle → stars inside it are discarded; at/
	# inside the surface nothing is masked. Flag off ⇒ never written (planet_cos_ang stays the 2.0 default = no mask).
	if CubeSphere.FP_SKY_PLANET_OCCLUDE and _star_mat != null:
		var dist_s := cam_origin.length()
		if dist_s > r_vox_sky and r_vox_sky > 0.0:
			_star_mat.set_shader_parameter("planet_dir", star_basis.inverse() * (-cam_origin / dist_s))
			_star_mat.set_shader_parameter("planet_cos_ang", cos(asin(clampf(r_vox_sky / dist_s, 0.0, 1.0))))
		else:
			_star_mat.set_shader_parameter("planet_cos_ang", 2.0)   # at/inside the surface: mask nothing

	# A6 (FP_ATMO_SHELL): feed the atmosphere shell its camera + Sun direction (centre/R/gain are static uniforms
	# set at build). The shell is planet-centred at the scene origin; the camera moves within/around it. No-op
	# unless the shell was built ⇒ byte-identical off.
	if _atmo_shell_mat != null:
		# COSMOS-PERF FALL-SCALE (FP_FALL_SHELL_OFF): the shell is a planet-centred additive sphere rendered
		# cull_front + depth_draw_never, so every covered fragment runs the per-fragment optical-path shader EVERY
		# frame with NO early-Z rejection — a screen-COVERAGE-bound cost that balloons as the camera descends into
		# the shell. Bisect: HIDE it (and skip its uniform writes) while |radial speed| > SHELL_OFF_VSPEED (a fall).
		# Off ⇒ always visible + written (byte-identical). Orbit/hover hold altitude ⇒ radial ≈ 0 ⇒ never hidden.
		var shell_hidden := false
		if CubeSphere.FP_FALL_SHELL_OFF and _atmo_shell != null:
			var soff_usec := Time.get_ticks_usec()
			var soff_d := cam_origin.length()
			var soff_v := 0.0
			if _shelloff_prev_usec >= 0:
				soff_v = FallThrottle.radial_speed(_shelloff_prev_d, soff_d, float(soff_usec - _shelloff_prev_usec) / 1.0e6)
			_shelloff_prev_d = soff_d
			_shelloff_prev_usec = soff_usec
			shell_hidden = soff_v > CubeSphere.SHELL_OFF_VSPEED
			_atmo_shell.visible = not shell_hidden
		if not shell_hidden:
			_atmo_shell_mat.set_shader_parameter("cam", cam_origin)
			_atmo_shell_mat.set_shader_parameter("sun_dir", sun_dir)

	# Day-night environment ramp from the Sun's elevation over the local horizon (radial up).
	_ramp_environment(sun_dir, cam_origin)

	# COSMOS-LOD-SKY M1 (FP_BODY_LOD): consult the multi-body LOD selection law + log any impostor↔ring
	# handover. SELECTION ONLY — no placement/mesh change (the real Sun/Moon stay IMPOSTOR by the law), so the
	# impostor writes above are unchanged. Fully inside the flag guard ⇒ byte-identical with the flag off.
	if CubeSphere.FP_BODY_LOD:
		_update_body_lod(t, cam_origin)

	# COSMOS-LOD-SKY M2 (FP_MOON_RING): once the law latches the Moon at RING, build/show its real-terrain far
	# ring and hide the impostor; on demote, evict the ring and restore the impostor. Placed to match the impostor
	# exactly (same centre + angular radius) so the handover is sub-pixel. No-op unless the ring node exists.
	if _moon_ring != null:
		_update_moon_ring(cam_origin, moon_dir, moon_ang)

## Drive the Environment background/ambient from the Sun's elevation. Elevation = sun_dir · up, where
## up is the radial direction at the camera (planet centre = origin under the fixed frame). Night (sun
## below the horizon) sits at the shipped ambient floor; day brightens/blues toward noon (§8.2).
func _ramp_environment(sun_dir: Vector3, cam_origin: Vector3) -> void:
	var up := cam_origin.normalized() if cam_origin.length() > 1.0 else Vector3.UP
	var elev := clampf(sun_dir.dot(up), -1.0, 1.0)          # −1 (midnight) .. +1 (noon)
	var day := clampf(elev, 0.0, 1.0)                        # 0 below horizon, ramps to 1 at zenith
	var twilight := clampf((elev + 0.15) / 0.30, 0.0, 1.0)   # soft dawn/dusk band around the horizon
	var night_fade := 1.0 - twilight                         # shipped star-fade: stars own the night sky

	# --- SN4 / ATMO-SKY altitude inputs (only evaluated when a flag is on; flag-off ⇒ byte-identical below) ---
	var atmo_on := CubeSphere.ATMO_VISUAL_RAMP
	var occ_on := CubeSphere.SN_SUN_OCCLUSION
	var atmo_zero := CubeSphere.FP_ATMO_SPACE_ZERO           # A3: atmo_vis replaces the space_mix band
	var light_abs := CubeSphere.FP_LIGHT_ABSOLUTE           # A4: absolute occ-always light + ambient
	var path_light := CubeSphere.FP_SUN_PATHLIGHT           # B0: optical-path T⃗(m)·L(m) light colour/energy
	var fog_arb := CubeSphere.FP_FOG_ARBITER                # B5: fog fades with atmo_vis + fog_depth_end tracks far
	var h := 0.0
	var r_vox := 0.0
	var has_atmo := true
	if atmo_on or occ_on or atmo_zero or light_abs or path_light or fog_arb:
		r_vox = CosmosGravity.r_vox(OBSERVER)
		h = cam_origin.length() - r_vox                      # radial altitude above the voxel surface
		has_atmo = OrbitalState.has_atmo(OBSERVER)
	# The "space fraction" driving the sky-blacken / star-emerge / ambient-thin. A3 replaces the 192..960
	# space_mix band with 1−atmo_vis (a 0.5·ATMO_TOP..ATMO_TOP fade, exactly 1 at/above ATMO_TOP ⇒ star-black
	# in space with NO twilight leak). atmo_eff gates the blacken/fog path (either the shipped ramp or A3).
	var atmo_eff := atmo_on or atmo_zero
	var sm := 0.0
	if atmo_zero:
		sm = 1.0 - atmo_vis(h, has_atmo)
	elif atmo_on:
		sm = space_mix(h, has_atmo)

	# BLACK-SKY FIX: fade the additive starfield out as twilight brightens, so stars own the night sky
	# and add nothing at noon (the ramped blue background then reads through the dome untouched). Driven
	# from the SAME elevation as the background ramp, so stars and sky can never disagree. Kept OUTSIDE
	# the `_env == null` early-out below — the starfield must still ramp when there is no Environment.
	# SN4a/A3: stars ALSO emerge as the sky blackens with altitude (star_fade = max(night_fade, space fraction)).
	if _star_mat != null:
		_star_mat.set_shader_parameter("star_fade", maxf(night_fade, sm) if atmo_eff else night_fade)

	# The DirectionalLight energy/colour. A4 (light_abs) is the ABSOLUTE occ-always dimmer with pen(h) twilight +
	# T(μ) sunset-reddened colour — the dark side stays dark from EVERY camera (supersedes the SN4b authority
	# lerp). Else SN4b's occlusion_light (authority-blended). Both OUTSIDE the `_env == null` guard — the light
	# must dim without an Environment. Flag-off ⇒ light_energy/colour never touched (shipped 1.0 / white).
	if path_light:
		# B0 (FP_SUN_PATHLIGHT): colour = T⃗(m) over the camera→sun optical path (WHITE in space, warm at noon,
		# red at the horizon); energy = occ(pen(h)) · L(m). Supersedes A4's K–Y colour on the live light — the
		# sunset reddening now comes from the physical path, matching the disc, the shell, and the near field.
		var m_l := optical_path_air_mass(cam_origin, sun_dir, r_vox, has_atmo)
		_sun_light.light_energy = light_energy_absolute(sun_dir, cam_origin, h, r_vox) * path_luminance(m_l)
		_sun_light.light_color = path_transmittance(m_l)
	elif light_abs:
		_sun_light.light_energy = light_energy_absolute(sun_dir, cam_origin, h, r_vox)
		_sun_light.light_color = scatter_tint(maxf(elev, 0.0))
	elif occ_on:
		_sun_light.light_energy = occlusion_light(sun_dir, cam_origin, h, r_vox, has_atmo)

	if _env == null:
		return
	var sky := _SKY_NIGHT.lerp(_SKY_DAY, twilight)
	var ambient := lerpf(_NIGHT_AMBIENT_ENERGY, 1.0, day)
	if atmo_eff:
		# SN4a/A3: sky → BLACK, ambient → AMBIENT_SPACE, fog thins with altitude (all composed onto the ramp).
		# A3: black is reached exactly at ATMO_TOP (sm=1), so the space sky is star-black with NO day/night leak.
		sky = sky.lerp(Color.BLACK, sm)
		ambient *= ambient_scale(sm)
		# B5 (FP_FOG_ARBITER): depth fog IS the atmosphere — fade it with atmo_vis(h) so it reaches 0 at ATMO_TOP
		# (else the shipped ρ(h) leaves ~5% haze at the ceiling that paints the deep-space planet). Off ⇒ shipped ρ(h).
		var fd := fog_density_at(h, has_atmo)
		if fog_arb:
			fd *= atmo_vis(h, has_atmo)
		_env.fog_density = fd
	# B5 (FP_FOG_ARBITER): track the A0-ramped camera far so a deep-space planet fragment is never beyond
	# fog-end (which the night ramp drives toward black). main.gd pins it at CAMERA_FAR·0.98; here it grows with
	# altitude exactly as CosmosScale.camera_far does. Off ⇒ never written (the static main.gd value stands).
	if fog_arb and CubeSphere.FP_SN3_MAIN_LIVE:
		_env.fog_depth_end = CosmosScale.camera_far(cam_origin.length(), r_vox) * 0.98
	# Ambient umbra factor: A4's absolute dimmer (continuous, no authority — the surface night side is dark
	# too, restoring the pre-ORBITAL ambient-only night), else SN4b's altitude-authority occlusion_ambient.
	if light_abs:
		ambient *= ambient_absolute(sun_dir, cam_origin, h, r_vox)
	elif occ_on:
		ambient *= occlusion_ambient(sun_dir, cam_origin, h, r_vox, has_atmo)

	# L2 SKY_SCATTER_RAMP (§6a): recolour the sky/fog toward the Rayleigh direct-light transmittance as the Sun
	# nears the horizon (deep-blue → gold → crimson), and warm the ambient tint in the gold band. `elev` is
	# μ = sin(sun elevation), the exact argument scatter_tint wants. sunset_weight is 0 with the Sun high and in
	# deep night, so away from sunrise/sunset the shipped ramp is untouched. Environment writes only (no shader).
	# L1 SKY_MOONSHINE (§7.3): add the cool ambient moonlight term on the night side (energy = gain·f·moon_up·night;
	# f dimmed by the eclipse factor), and cool the ambient tint by its strength. Both terms reset their colour to
	# white when inactive, so nothing lingers. Flag(s) off ⇒ ambient_light_color is NEVER written (byte-identical).
	var amb_col := Color.WHITE
	var amb_col_write := false
	if CubeSphere.SKY_SCATTER_RAMP:
		var w := sunset_weight(elev)
		if atmo_zero:
			w *= atmo_vis(h, has_atmo)                        # A3: the sunset recolour fades to 0 in space (no space tint)
		if w > 0.0:
			var st := scatter_tint(elev)
			sky = sky.lerp(Color(sky.r * st.r, sky.g * st.g, sky.b * st.b), w)
			amb_col = amb_col.lerp(st, w * 0.6)
		amb_col_write = true
	if CubeSphere.SKY_MOONSHINE:
		var add := moonshine_energy(_moon_illum * _moon_eclipse, _moon_up, night_fade)
		ambient += add
		amb_col = amb_col.lerp(MOONSHINE_TINT, clampf(add / MOONSHINE_GAIN, 0.0, 1.0))
		amb_col_write = true

	_env.background_color = sky
	_env.fog_light_color = _env.background_color
	_env.ambient_light_energy = ambient
	if amb_col_write:
		_env.ambient_light_color = amb_col

## L3 (SHELL_TERMINATOR_TINT): the current body-fixed Sun direction, for main.gd to forward into the far-ring
## shell tint uniform each frame (so the space-side terminator band tracks the same Sun as the ground ramp).
func current_sun_dir() -> Vector3:
	return _cur_sun_dir

## Camera origin (parallax-free sky centre). Falls back to this node's own origin if no provider yet
## (local origin — CosmosSky is at identity, so this is the scene origin / planet centre).
func _camera_origin() -> Vector3:
	if _cam_provider != null and _cam_provider.has_method("camera_global_transform"):
		return (_cam_provider.camera_global_transform() as Transform3D).origin
	return transform.origin

## A transform at `origin` whose local −Z points along `fwd` (matches DirectionalLight's shine axis).
func _looking_along(fwd: Vector3, origin: Vector3) -> Transform3D:
	var f := fwd.normalized()
	if f == Vector3.ZERO:
		f = Vector3(0, -1, 0)
	var up := Vector3(0, 0, 1)                               # spin axis; avoids degeneracy for horizon-plane f
	if absf(f.dot(up)) > 0.99:
		up = Vector3(0, 1, 0)
	var xf := Transform3D()
	xf = xf.looking_at(f, up)                                # basis only; −Z → f
	xf.origin = origin
	return xf

## Place a reused impostor at `pos` scaled to sphere `radius` (SphereMesh default radius = 1). Writes
## the LOCAL transform (CosmosSky is at identity ⇒ local == global; see _update_sky note).
func _place_impostor(mi: MeshInstance3D, pos: Vector3, radius: float) -> void:
	var r := maxf(radius, 0.001)
	mi.transform = Transform3D(Basis().scaled(Vector3(r, r, r)), pos)

## A2 (FP_SUN_PRESENCE): billboard the glare QuadMesh at `pos`, +Z facing the camera, half-extent `half`.
## QuadMesh spans ±0.5, so the basis is scaled by 2·half to reach the requested half-extent.
func _place_glare(pos: Vector3, half: float, cam: Vector3) -> void:
	var fz := cam - pos
	if fz.length() < 1.0e-4:
		fz = Vector3(0.0, 0.0, 1.0)
	fz = fz.normalized()
	var up := Vector3(0.0, 0.0, 1.0)
	if absf(fz.dot(up)) > 0.99:
		up = Vector3(0.0, 1.0, 0.0)
	var fx := up.cross(fz).normalized()
	var fy := fz.cross(fx).normalized()
	var s := 2.0 * maxf(half, 0.001)
	_glare.transform = Transform3D(Basis(fx, fy, fz).scaled(Vector3(s, s, s)), pos)

## COSMOS-LOD-SKY M1 (FP_BODY_LOD) — the per-frame LOD SELECTION consult (§2). For each celestial body,
## classify its presented tier from the angular-size law (relief_px vs TAU_POP, latched ±25% hysteresis) and
## print the G-SSE-INV handover line on a tier change. SELECTION ONLY: the real Sun (e_relief=0) and Moon
## (relief_px ≈ 0.23 px at its true distance) both resolve to IMPOSTOR, so nothing above changes — the actual
## per-body RING build + placement is M2. Called only under the flag (see _update_sky); zero cost off.
func _update_body_lod(t: float, _cam_origin: Vector3) -> void:
	var kpx := BodyLod.k_px(_viewport_h_px(), deg_to_rad(LOD_NOMINAL_FOV_DEG))
	for body in ["sun", "moon"]:
		var d := EPH.distance_between(OBSERVER, body, t)
		var r := EPH.radius_of(body)
		var e := BodyLod.e_relief_of(body)
		var prev := int(_lod_tier.get(body, BodyLod.POINT))
		var next := BodyLod.tier_hyst(prev, r, e, d, kpx)
		if next != prev:
			print(BodyLod.transition_log(body, prev, next, d, BodyLod.relief_px(e, d, kpx)))
			_lod_tier[body] = next

## COSMOS-LOD-SKY M2 (FP_MOON_RING) — the per-frame Moon far-ring driver. Reads the tier the FP_BODY_LOD law
## latched for the Moon (_lod_tier); at RING it builds (once, or on axis drift) + shows the real cratered ring
## and hides the impostor; below RING it evicts the whole ring and restores the impostor. The ring is placed to
## MATCH the impostor exactly — the same sky centre (cam + moon_dir·D_SKY) and angular radius (D_SKY·tan(ang/2)),
## via a uniform scale about the body centre — so its silhouette equals the impostor's sphere to sub-pixel and
## the handover is seamless (SEAMLESS-SCALES / G-SSE-INV). NEVER-OOM: built whole, freed whole on demote.
## Rebuild threshold: the visible Moon hemisphere turns as the Earth-relative direction drifts; rebuild the emit
## set past a few degrees (caches persist, bounded by the body's facet count — within the §3 CPU budget).
const MOON_RING_REBUILD_DEG := 4.0
func _update_moon_ring(cam_origin: Vector3, moon_dir: Vector3, moon_ang: float) -> void:
	var tier := int(_lod_tier.get("moon", BodyLod.POINT))
	if tier < BodyLod.RING:
		if _moon_ring.is_built():
			_moon_ring.evict()
		_moon.visible = true
		return
	# RING: the cull axis is the direction from the Moon centre toward the camera, in the Moon's ABSOLUTE body
	# frame. The ring mesh is placed unrotated (identity orientation ⇒ body axes == render axes) with the Moon
	# centred at cam + moon_dir·D_SKY, so the camera lies along −moon_dir from that centre.
	var axis := (-moon_dir).normalized()
	if not _moon_ring.is_built() or _moon_ring_axis.angle_to(axis) > deg_to_rad(MOON_RING_REBUILD_DEG):
		_moon_ring.build([axis.x, axis.y, axis.z])
		_moon_ring_axis = axis
	# Place to match the impostor: centre + uniform scale sizing the Moon datum (R_moon) to the impostor's
	# angular radius at D_SKY. Relief (craters) scales with it, so it is sub-pixel at the RING threshold and grows
	# on approach exactly as the impostor's disc does — the "detail grows as you get closer" payoff.
	var sky_radius := maxf(_dsky * tan(moon_ang * 0.5), 0.001)
	var scale := sky_radius / EPH.radius_of("moon")
	var center := cam_origin + moon_dir * _dsky
	_moon_ring.place(Transform3D(Basis.IDENTITY.scaled(Vector3(scale, scale, scale)), center))
	_moon.visible = false                            # make-before-break: the ring is committed above, now hide the disc

## Gate/telemetry access to the live Moon ring (null unless FP_MOON_RING + MULTI_BODY built it).
func moon_ring() -> MoonFarRing:
	return _moon_ring

## Device-px viewport height for the K_px consult, read defensively (this runs only under FP_BODY_LOD, never
## in the headless sky gate). Falls back to a 1080p nominal when no viewport is available.
func _viewport_h_px() -> float:
	var vp := get_viewport()
	if vp != null:
		var h := vp.get_visible_rect().size.y
		if h > 1.0:
			return h
	return 1080.0
