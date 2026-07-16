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

## The observer body whose body-fixed frame is the scene frame (the dominant body). O0 = Earth.
const OBSERVER := "earth"

var _clock: EPH.CosmosClock = null
var _env: Environment = null
var _cam_provider: Node = null                 # anything with camera_global_transform() -> Transform3D (the Player)

var _sun: MeshInstance3D = null
var _sun_light: DirectionalLight3D = null
var _moon: MeshInstance3D = null
var _stars: MeshInstance3D = null
var _moon_mat: StandardMaterial3D = null

# Shipped flat-ambient values (main._setup_environment) — reused verbatim as the NIGHT floor so a
# night sky matches today's look exactly, and DAY brightens above them.
const _NIGHT_AMBIENT := Color(1, 1, 1)
const _NIGHT_AMBIENT_ENERGY := 0.35        # dimmed floor at night; ramps to 1.0 (shipped) at high noon
const _SKY_DAY := Color(0.62, 0.74, 0.86)  # main.SKY_COLOR
const _SKY_NIGHT := Color(0.02, 0.02, 0.05)

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
	_moon.material_override = _moon_mat
	_moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_moon)

	# --- Star dome: one big inverted sphere, unshaded dark emissive, rotated by −Earth spin. A
	# placeholder starfield (no texture assets in O0); the live screenshot pass refines the look.
	_stars = MeshInstance3D.new()
	_stars.name = "StarDome"
	var star_mesh := SphereMesh.new()
	star_mesh.radius = D_SKY * 1.05
	star_mesh.height = D_SKY * 2.1
	star_mesh.radial_segments = 24
	star_mesh.rings = 12
	_stars.mesh = star_mesh
	var star_mat := StandardMaterial3D.new()
	star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	star_mat.cull_mode = BaseMaterial3D.CULL_FRONT        # see the inside of the dome
	star_mat.emission_enabled = true
	star_mat.emission = Color(0.03, 0.03, 0.06)
	star_mat.emission_energy_multiplier = 1.0
	star_mat.albedo_color = Color(0.01, 0.01, 0.02)
	_stars.material_override = star_mat
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	_place_impostor(_sun, cam_origin + sun_dir * D_SKY, D_SKY * tan(sun_ang * 0.5))

	# Moon impostor: body-fixed direction from Earth, exact angular size, lit by the shared light.
	var moon_dir := EPH.dir_to_bodyfixed(OBSERVER, "moon", t)
	if moon_dir == Vector3.ZERO:
		moon_dir = Vector3(-1.0, 0.0, 0.0)
	var moon_ang := EPH.angular_diameter("moon", OBSERVER, t)
	_place_impostor(_moon, cam_origin + moon_dir * D_SKY, D_SKY * tan(moon_ang * 0.5))

	# Star dome: centred on the camera, rotated by −Earth spin (the stars wheel as the planet turns).
	var spin := EPH.spin_angle(OBSERVER, t)
	var star_xf := Transform3D(Basis(Vector3(0, 0, 1), -spin), cam_origin)
	_stars.transform = star_xf

	# Day-night environment ramp from the Sun's elevation over the local horizon (radial up).
	_ramp_environment(sun_dir, cam_origin)

## Drive the Environment background/ambient from the Sun's elevation. Elevation = sun_dir · up, where
## up is the radial direction at the camera (planet centre = origin under the fixed frame). Night (sun
## below the horizon) sits at the shipped ambient floor; day brightens/blues toward noon (§8.2).
func _ramp_environment(sun_dir: Vector3, cam_origin: Vector3) -> void:
	if _env == null:
		return
	var up := cam_origin.normalized() if cam_origin.length() > 1.0 else Vector3.UP
	var elev := clampf(sun_dir.dot(up), -1.0, 1.0)          # −1 (midnight) .. +1 (noon)
	var day := clampf(elev, 0.0, 1.0)                        # 0 below horizon, ramps to 1 at zenith
	var twilight := clampf((elev + 0.15) / 0.30, 0.0, 1.0)   # soft dawn/dusk band around the horizon
	_env.background_color = _SKY_NIGHT.lerp(_SKY_DAY, twilight)
	_env.fog_light_color = _env.background_color
	_env.ambient_light_energy = lerpf(_NIGHT_AMBIENT_ENERGY, 1.0, day)

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
