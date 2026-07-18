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

var _sun: MeshInstance3D = null
var _sun_light: DirectionalLight3D = null
var _moon: MeshInstance3D = null
var _stars: MeshInstance3D = null
var _moon_mat: StandardMaterial3D = null
var _star_mat: ShaderMaterial = null

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

## Wire the sky to a clock (read each frame), the scene Environment (ramped; may be null → no ramp),
## and a camera provider (the Player; may be null → impostors sit around the origin). Builds the
## reused nodes once. Idempotent-safe: call once from main.gd under the flag.
func setup(clock: EPH.CosmosClock, env: Environment = null, cam_provider: Node = null) -> void:
	_clock = clock
	_env = env
	_cam_provider = cam_provider
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
	_sun.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sun)

	# --- THE DirectionalLight (day-night sun light). Shadows OFF by default (D11 / risk #6).
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "SunLight"
	_sun_light.shadow_enabled = false
	_sun_light.light_energy = 1.0
	add_child(_sun_light)

	# --- Moon impostor: a SHADED sphere lit by the sun light ⇒ its phase falls out for free (§4.4).
	_moon = MeshInstance3D.new()
	_moon.name = "Moon"
	var moon_mesh := SphereMesh.new()
	moon_mesh.radial_segments = 32
	moon_mesh.rings = 16
	_moon.mesh = moon_mesh
	_moon_mat = StandardMaterial3D.new()
	_moon_mat.albedo_color = Color(0.72, 0.72, 0.70)
	_moon_mat.roughness = 1.0
	_moon_mat.metallic = 0.0
	_moon_mat.disable_fog = true                          # BLACK-SKY FIX — see the Sun note above (fog opaque at 8820 > D_SKY)
	_moon.material_override = _moon_mat
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

func _process(_delta: float) -> void:
	if _clock == null:
		return
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

	# The light comes FROM the sun: a DirectionalLight shines along its local −Z, so aim −Z at −sun_dir
	# (i.e. +Z = sun_dir). look_at points local −Z at the target, so look from cam toward (cam − sun_dir).
	_sun_light.transform = _looking_along(-sun_dir, cam_origin)

	# Sun impostor: at cam + sun_dir·D_SKY, radius sized to its exact angular diameter.
	var sun_ang := EPH.angular_diameter("sun", OBSERVER, t)
	_place_impostor(_sun, cam_origin + sun_dir * _dsky, _dsky * tan(sun_ang * 0.5))

	# Moon impostor: body-fixed direction from Earth, exact angular size, lit by the shared light.
	var moon_dir := EPH.dir_to_bodyfixed(OBSERVER, "moon", t)
	if moon_dir == Vector3.ZERO:
		moon_dir = Vector3(-1.0, 0.0, 0.0)
	var moon_ang := EPH.angular_diameter("moon", OBSERVER, t)
	_place_impostor(_moon, cam_origin + moon_dir * _dsky, _dsky * tan(moon_ang * 0.5))

	# Star dome: centred on the camera, rotated by −Earth spin (the stars wheel as the planet turns).
	var spin := EPH.spin_angle(OBSERVER, t)
	var star_xf := Transform3D(Basis(Vector3(0, 0, 1), -spin), cam_origin)
	_stars.transform = star_xf

	# Day-night environment ramp from the Sun's elevation over the local horizon (radial up).
	_ramp_environment(sun_dir, cam_origin)

	# COSMOS-LOD-SKY M1 (FP_BODY_LOD): consult the multi-body LOD selection law + log any impostor↔ring
	# handover. SELECTION ONLY — no placement/mesh change (the real Sun/Moon stay IMPOSTOR by the law), so the
	# impostor writes above are unchanged. Fully inside the flag guard ⇒ byte-identical with the flag off.
	if CubeSphere.FP_BODY_LOD:
		_update_body_lod(t, cam_origin)

## Drive the Environment background/ambient from the Sun's elevation. Elevation = sun_dir · up, where
## up is the radial direction at the camera (planet centre = origin under the fixed frame). Night (sun
## below the horizon) sits at the shipped ambient floor; day brightens/blues toward noon (§8.2).
func _ramp_environment(sun_dir: Vector3, cam_origin: Vector3) -> void:
	var up := cam_origin.normalized() if cam_origin.length() > 1.0 else Vector3.UP
	var elev := clampf(sun_dir.dot(up), -1.0, 1.0)          # −1 (midnight) .. +1 (noon)
	var day := clampf(elev, 0.0, 1.0)                        # 0 below horizon, ramps to 1 at zenith
	var twilight := clampf((elev + 0.15) / 0.30, 0.0, 1.0)   # soft dawn/dusk band around the horizon
	var night_fade := 1.0 - twilight                         # shipped star-fade: stars own the night sky

	# --- SN4 altitude inputs (only evaluated when a flag is on; flag-off ⇒ byte-identical below) ---
	var atmo_on := CubeSphere.ATMO_VISUAL_RAMP
	var occ_on := CubeSphere.SN_SUN_OCCLUSION
	var h := 0.0
	var r_vox := 0.0
	var has_atmo := true
	if atmo_on or occ_on:
		r_vox = CosmosGravity.r_vox(OBSERVER)
		h = cam_origin.length() - r_vox                      # radial altitude above the voxel surface
		has_atmo = OrbitalState.has_atmo(OBSERVER)
	var sm := space_mix(h, has_atmo) if atmo_on else 0.0

	# BLACK-SKY FIX: fade the additive starfield out as twilight brightens, so stars own the night sky
	# and add nothing at noon (the ramped blue background then reads through the dome untouched). Driven
	# from the SAME elevation as the background ramp, so stars and sky can never disagree. Kept OUTSIDE
	# the `_env == null` early-out below — the starfield must still ramp when there is no Environment.
	# SN4a: stars ALSO emerge as the sky blackens with altitude (star_fade = max(night_fade, space_mix)).
	if _star_mat != null:
		_star_mat.set_shader_parameter("star_fade", maxf(night_fade, sm) if atmo_on else night_fade)

	# SN4b: the sun-occlusion dimmer drives the DirectionalLight energy. Computed OUTSIDE the `_env == null`
	# guard — the light must dim even when there is no Environment. Flag-off ⇒ light_energy is never touched
	# (stays the shipped 1.0 set in _build_nodes).
	if occ_on:
		_sun_light.light_energy = occlusion_light(sun_dir, cam_origin, h, r_vox, has_atmo)

	if _env == null:
		return
	var sky := _SKY_NIGHT.lerp(_SKY_DAY, twilight)
	var ambient := lerpf(_NIGHT_AMBIENT_ENERGY, 1.0, day)
	if atmo_on:
		# SN4a: sky → BLACK, ambient → AMBIENT_SPACE, fog thins with altitude (all composed onto the ramp).
		sky = sky.lerp(Color.BLACK, sm)
		ambient *= ambient_scale(sm)
		_env.fog_density = fog_density_at(h, has_atmo)
	if occ_on:
		ambient *= occlusion_ambient(sun_dir, cam_origin, h, r_vox, has_atmo)
	_env.background_color = sky
	_env.fog_light_color = _env.background_color
	_env.ambient_light_energy = ambient

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

## Device-px viewport height for the K_px consult, read defensively (this runs only under FP_BODY_LOD, never
## in the headless sky gate). Falls back to a 1080p nominal when no viewport is available.
func _viewport_h_px() -> float:
	var vp := get_viewport()
	if vp != null:
		var h := vp.get_visible_rect().size.y
		if h > 1.0:
			return h
	return 1080.0
