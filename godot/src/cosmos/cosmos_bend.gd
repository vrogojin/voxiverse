class_name CosmosBend
extends RefCounted
## COSMOS M1 — the camera-centred exact-sphere render bend (docs/COSMOS-PLANET-TOPOLOGY.md §3.4).
##
## Physics, streaming and edits stay on the FLAT lattice (§3.3, the y ↦ r theorem); ONLY the
## rendered vertices are wrapped onto the exact sphere around the camera, so the sea-level horizon
## appears at its true ~147 blocks (§1.2) and ships go hull-down from a beach, while every query
## the player, DDA, collider and collapse pass run stays flat-space exact.
##
## The bend is a shared VERTEX transform applied in WORLD space, so it composes across EVERY
## render path (module VoxelTerrain, the GDScript fallback mesher, water, VoxelBody debris) without
## per-path code — a material built by BlockMaterials carries the bend shader when
## CubeSphere.FLAT_WORLD is false, and reads the camera position + datum radius from two GLOBAL
## shader uniforms (`cosmos_bend_origin`, `cosmos_radius`) that main.gd refreshes each frame.
##
## THE EXACT SAGITTA (§3.4): for a vertex at world (x, y, z), with the bend origin (camera) at
## horizontal (ox, oz) and datum radius R,
##     d   = (x, z) − (ox, oz);         len = |d|;   phi = len / R      (arc angle)
##     rv  = R + y                       (vertex radius — the prism taper falls out for free)
##     y'  = rv·cos(phi) − R             (exact drop, NOT the d²/2R truncation)
##     (x',z') = (ox,oz) + d·(rv·sin(phi)/max(len,ε))
## At the camera column (len → 0) the bend is identically zero, so the player/aim ray/collider are
## unaffected. This module is the SINGLE SOURCE of that formula: the GLSL vertex() below and the
## GDScript `bend_point()` mirror it bit-for-formula so verify can pin the horizon against geometry.

## Names of the two runtime-registered global shader uniforms the bend shaders read.
const U_ORIGIN := "cosmos_bend_origin"
const U_RADIUS := "cosmos_radius"

const _EPS := 1e-6

static var _opaque_shader: Shader = null
static var _translucent_shader: Shader = null
static var _far_shader: Shader = null
static var _globals_ready := false

## Register the two global shader uniforms (idempotent). A `global uniform` referenced by a shader
## must exist as a global shader parameter or the shader fails to compile, so this MUST run before
## any bend material is built. Called from BlockMaterials (material build) and main.gd (per-frame
## update); both no-op after the first registration.
static func ensure_globals() -> void:
	if _globals_ready:
		return
	# Register the two globals exactly ONCE per process (the `_globals_ready` latch below gates it).
	# We must NOT probe with `global_shader_parameter_get` first: that RenderingServer call is
	# EDITOR-ONLY and, in a GLES3/Compatibility export (the browser build), spams
	# "This function should never be used outside the editor" every frame and tanks perf (it is a
	# synchronous server round-trip). `_add` is idempotent-safe here because the latch guarantees a
	# single call; the SET side (set_camera) never reads back. `global_shader_parameter_list()` would
	# be another non-editor existence check, but the latch makes any check unnecessary.
	RenderingServer.global_shader_parameter_add(U_ORIGIN, RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	RenderingServer.global_shader_parameter_add(
		U_RADIUS, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, float(CubeSphere.radius_for(CubeSphere.HOME_BODY)))
	_globals_ready = true

## Push the current camera position (window/scene space) into the bend origin global uniform. The
## bend is camera-centred (§3.4) so this runs each frame; the radius is constant per body.
static func set_camera(origin: Vector3) -> void:
	ensure_globals()
	RenderingServer.global_shader_parameter_set(U_ORIGIN, origin)
	RenderingServer.global_shader_parameter_set(U_RADIUS, float(CubeSphere.radius_for(CubeSphere.HOME_BODY)))

## The shared GLSL vertex-bend snippet (world-space in, world-space out), mirrored exactly by
## `bend_point()`. Written into both shader variants so the formula lives in one string.
const _VERTEX_BEND := """
	vec3 _cw = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 _d = _cw.xz - cosmos_bend_origin.xz;
	float _len = length(_d);
	float _phi = _len / cosmos_radius;
	float _rv = cosmos_radius + _cw.y;
	float _by = _rv * cos(_phi) - cosmos_radius;
	vec2 _bxz = cosmos_bend_origin.xz + _d * (_rv * sin(_phi) / max(_len, 1e-6));
	vec3 _bent = vec3(_bxz.x, _by, _bxz.y);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(_bent, 1.0)).xyz;
"""

## The opaque bend shader (unshaded, double-sided) — mirrors BlockMaterials._textured/_solid plus
## optional emission (lava). Textured or flat-swatch via `use_texture`; per-voxel tint via COLOR.
static func opaque_shader() -> Shader:
	if _opaque_shader != null:
		return _opaque_shader
	var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
global uniform vec3 cosmos_bend_origin;
global uniform float cosmos_radius;
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_texture = false;
uniform bool use_vertex_color = true;
uniform vec3 emission_color = vec3(0.0);
uniform float emission_energy = 0.0;
void vertex() {
%s}
void fragment() {
	vec4 col = albedo_color;
	if (use_texture) { col *= texture(albedo_tex, UV); }
	if (use_vertex_color) { col.rgb *= COLOR.rgb; }
	ALBEDO = col.rgb;
	EMISSION = emission_color * emission_energy;
}
""" % _VERTEX_BEND
	_opaque_shader = s
	return s

## The translucent bend shader (unshaded, double-sided, depth-prepass alpha) — mirrors
## BlockMaterials._translucent (glass/water/ice). Alpha comes from albedo_color.a (× optional tile).
static func translucent_shader() -> Shader:
	if _translucent_shader != null:
		return _translucent_shader
	var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;
global uniform vec3 cosmos_bend_origin;
global uniform float cosmos_radius;
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_texture = false;
void vertex() {
%s}
void fragment() {
	vec4 col = albedo_color;
	if (use_texture) { col *= texture(albedo_tex, UV); }
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
""" % _VERTEX_BEND
	_translucent_shader = s
	return s

## The FAR-FIELD bend shader (COSMOS Stage 3): the SAME sphere bend applied to the LOD heightmap tiles,
## so the distant silhouette curves with the planet by the identical sagitta formula as the near voxel
## field — instead of floating flat above the true horizon (the near-bent / far-flat seam). The
## ShaderMaterial mirror of FarTerrain.make_material()'s StandardMaterial3D: unshaded, CULL_BACK (the far
## top is single-sided, wound up; skirts are double-sided in geometry), vertex-colour albedo, no texture.
## The bend reads MODEL_MATRIX, so it is correct with the far node offset into the global-index frame.
## Only built when CubeSphere.FLAT_WORLD is false; FLAT keeps the StandardMaterial3D byte-identical.
static func far_shader() -> Shader:
	if _far_shader != null:
		return _far_shader
	var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode unshaded, cull_back;
global uniform vec3 cosmos_bend_origin;
global uniform float cosmos_radius;
void vertex() {
%s}
void fragment() {
	ALBEDO = COLOR.rgb;
}
""" % _VERTEX_BEND
	_far_shader = s
	return s

## The exact-sphere horizon distance (blocks) for an eye `eye_height` above the datum on a body of
## datum radius `radius` — the geometric tangent-line distance √(2·R·h + h²) (§1.2/§3.4). At R=6371,
## h=1.7 this is ~147.2 blocks, the locked COSMOS sea-horizon target. verify pins the bend against it.
static func sea_horizon_distance(radius: float, eye_height: float) -> float:
	return sqrt(2.0 * radius * eye_height + eye_height * eye_height)

## GDScript mirror of the GLSL `_VERTEX_BEND` (identity coordinate frame — MODEL_MATRIX = I), used
## by verify to check the shader formula against the geometric horizon. `world` is a window/scene
## point, `origin` the camera (bend centre), `radius` the datum R. Returns the bent point.
static func bend_point(world: Vector3, origin: Vector3, radius: float) -> Vector3:
	var d := Vector2(world.x - origin.x, world.z - origin.z)
	var l := d.length()
	var phi := l / radius
	var rv := radius + world.y
	var by := rv * cos(phi) - radius
	var bxz: Vector2 = Vector2(origin.x, origin.z) + d * (rv * sin(phi) / max(l, _EPS))
	return Vector3(bxz.x, by, bxz.y)
