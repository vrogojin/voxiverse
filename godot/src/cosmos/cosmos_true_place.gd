class_name CosmosTruePlace
extends RefCounted
## COSMOS M5a — the TRUE-POSITION placement math (docs/COSMOS-M5-ADR.md §2), replacing CosmosBend's
## camera-centred radial sagitta with per-vertex placement at the exact sphere position P = (R+y)·d̂.
##
## This file owns the CPU MIRROR (place_point / camera_frame) + the GLSL vertex snippet (built into
## opaque/translucent/far variants, the CosmosBend pattern). The shader and place_point share one formula
## so verify (verify_cosmos_m5) can pin the GPU path against CubeSphere.world_point (§2.3 T1). Gated behind
## CubeSphere.M5_RENDER (default false → CosmosBend is used, byte-identical); FLAT_WORLD never builds it.
##
## THE WELL-CONDITIONED FORM (§2.1): the camera-relative output avoids any R-magnitude f32 subtraction —
##   d̂    = normalize(n̂_s + tan(a·π/4)·û_s + tan(b·π/4)·v̂_s)     (strip s's TRUE face axes; warp == tan(a·π/4))
##   POS  = M_tangent · ( R·(d̂ − d̂_cam) + y·d̂ − y_cam·d̂_cam )    (every term ≤ ~reach, not R)
## with d̂_cam / y_cam / M_tangent per-frame globals computed on CPU in f64. M_tangent is the orthonormalized
## Jacobian of the window→sphere map at the camera (Gram-Schmidt from ∂P/∂x with d̂_cam pinned as the up/
## radial column), so the map is FIRST-ORDER IDENTITY at the camera (physics-render divergence ~0.002 blk
## at the 5-blk DDA reach). POS is the camera-RELATIVE placed offset; the shader adds it to the camera world
## position (reused CosmosBend camera uniform) to get the world vertex.

const _WEDGE := Vector3(1.0e18, 1.0e18, 1.0e18)   # sentinel: double-out corner wedge → discard (M5c keystone)

## The INTERACTION BUBBLE (Fable ruling, ADR §2.1 amended): render == flat-window IDENTITY inside r0 (so
## near interaction — DDA/aim/collision/walk-feel — is EXACT at every camera position, even AT the corner,
## regardless of the local stretch S), pure orthonormalized TRUE placement beyond r1, smoothstep between.
## r1 < INNER_HOLE_CURVED (112) so the blend COMPLETES inside the near volume and the pure-true far tiles
## join continuously. Fold-free over [r0,r1] (min radial derivative > 0 on both S>1 and S≈0.707 sides).
const BUBBLE_R0 := 16.0
const BUBBLE_R1 := 104.0

## Continuous raw home-face index of a window point (x, z): p = org + M_win·w (the #74 chart line, floats).
static func _raw_of_f(chart: CosmosChart, x: float, z: float) -> Vector2:
	return Vector2(
		float(chart.i_org) + float(chart.mw_a) * x + float(chart.mw_b) * z,
		float(chart.j_org) + float(chart.mw_c) * x + float(chart.mw_d) * z)

## Fold a CONTINUOUS raw coord (px, pz) on `home` to its true face + continuous face coord. Single-edge
## affine (edge_remap), matching CubeSphere.fold_cell for integers. Returns {face, x, z} or face −1 (wedge).
static func _fold_f(home: int, px: float, pz: float, n: int) -> Dictionary:
	var oi := px < 0.0 or px >= float(n)
	var oj := pz < 0.0 or pz >= float(n)
	if not oi and not oj:
		return {"face": home, "x": px, "z": pz}
	if oi and oj:
		return {"face": -1, "x": px, "z": pz}                  # corner wedge (M5c keystone)
	var side := CubeSphere.SIDE_EAST
	if px >= float(n): side = CubeSphere.SIDE_EAST
	elif px < 0.0: side = CubeSphere.SIDE_WEST
	elif pz >= float(n): side = CubeSphere.SIDE_NORTH
	else: side = CubeSphere.SIDE_SOUTH
	var e := CubeSphere.edge_remap(home, side, n)
	var m: Array = e["m"]
	var t: Array = e["t"]
	return {
		"face": int(e["b"]),
		"x": float(m[0]) * px + float(m[1]) * pz + float(t[0]),
		"z": float(m[2]) * px + float(m[3]) * pz + float(t[1]),
	}

## The unit sphere direction of a CONTINUOUS true face coord (fx, fz) — the gnomonic map with the equal-
## angle warp, matching CubeSphere.face_cell_to_dir (a = 2·fx/n − 1; note fx already carries the +0.5 for a
## cell centre, per §2.1). f64.
static func _dir_of(face: int, fx: float, fz: float, n: int) -> Vector3:
	var a := 2.0 * fx / float(n) - 1.0
	var b := 2.0 * fz / float(n) - 1.0
	var u := tan(a * (PI / 4.0))
	var v := tan(b * (PI / 4.0))
	var nn := CubeSphere._axis_n(face)
	var uu := CubeSphere._axis_u(face)
	var vv := CubeSphere._axis_v(face)
	var d := Vector3(
		float(nn.x) + u * float(uu.x) + v * float(vv.x),
		float(nn.y) + u * float(uu.y) + v * float(vv.y),
		float(nn.z) + u * float(uu.z) + v * float(vv.z))
	return d.normalized()

## The unit sphere direction of a WINDOW point (x, z) via the current chart (fold + gnomonic). _WEDGE
## sentinel dir is (0,0,0) → the caller emits a degenerate position.
static func dir_of_window(chart: CosmosChart, x: float, z: float) -> Vector3:
	var n := chart.n
	var p := _raw_of_f(chart, x, z)
	var g := _fold_f(chart.face, p.x, p.y, n)
	if int(g["face"]) < 0:
		return Vector3.ZERO
	return _dir_of(int(g["face"]), float(g["x"]), float(g["z"]), n)

## The per-frame camera frame globals (§2.1): d̂_cam, y_cam, and M_tangent (the orthonormalized Jacobian of
## the window→sphere map at the camera, Gram-Schmidt from ∂P/∂x with d̂_cam pinned up). Returned as
## {d_cam: Vector3, y_cam: float, mt: Basis} where `mt` maps a WORLD offset → the camera-local frame
## (POS = mt·(P − P_cam)); mt is orthonormal so the shader just multiplies. cam = camera WINDOW position.
static func camera_frame(chart: CosmosChart, cam: Vector3) -> Dictionary:
	var d_cam := dir_of_window(chart, cam.x, cam.z)
	# Tangent directions from finite differences of the window→dir map at the camera (central, ε window-cells).
	var eps := 0.5
	var dxp := dir_of_window(chart, cam.x + eps, cam.z)
	var dxn := dir_of_window(chart, cam.x - eps, cam.z)
	var dzp := dir_of_window(chart, cam.x, cam.z + eps)
	var dzn := dir_of_window(chart, cam.x, cam.z - eps)
	var tx := (dxp - dxn)                                       # ∝ ∂d̂/∂x  (direction of ∂P/∂x)
	var tz := (dzp - dzn)                                       # ∝ ∂d̂/∂z
	# Gram-Schmidt with d̂_cam pinned as the radial/up column (ex ⟂ d_cam since ∂d̂/∂x ⟂ d̂ for a unit d̂).
	var ex := (tx - d_cam * tx.dot(d_cam)).normalized()
	var ez := (tz - d_cam * tz.dot(d_cam) - ex * tz.dot(ex)).normalized()
	# Right-handed check: window (x, z) with +y radial should keep the mesh winding; if ez flipped, re-cross.
	if ex.cross(d_cam).dot(ez) < 0.0:
		ez = -ez
	# mt rows = (ex, d_cam, ez) so mt·V = (V·ex, V·d_cam, V·ez): world offset → camera-local (x, y=radial, z).
	var mt := Basis(Vector3(ex.x, d_cam.x, ez.x), Vector3(ex.y, d_cam.y, ez.y), Vector3(ex.z, d_cam.z, ez.z))
	return {"d_cam": d_cam, "y_cam": cam.y, "mt": mt, "w_cam": cam}

## The CPU MIRROR of the shader placement (§2.1 + the Fable bubble): the camera-RELATIVE render offset of a
## window point w=(x,y,z). frame is the camera_frame Dictionary.
##   ident   = w − w_cam                                        (flat-window offset — what physics uses)
##   true    = mt·(R·(d̂−d̂_cam) + y·d̂ − y_cam·d̂_cam)            (orthonormalized true position)
##   render  = lerp(ident, true, smoothstep(r0, r1, ρ)),  ρ = horizontal |w − w_cam|
## Inside r0 → render == ident == identity (near interaction EXACT even at the corner); beyond r1 → pure
## true (seam shear killed, strips wrap, corner closes). The WEDGE (double-out) has no true position: it is
## the FADING ECHO ident·(1−s) — full flat echo inside r0, collapsed to the camera by r1 — so it does not
## double-image against the true strips that fill its sector beyond r1 (M5c-lite seals it fully later).
static func place_point(chart: CosmosChart, w: Vector3, frame: Dictionary) -> Vector3:
	var w_cam: Vector3 = frame["w_cam"]
	var ident := w - w_cam
	var rho := Vector2(w.x - w_cam.x, w.z - w_cam.z).length()
	var s := smoothstep(BUBBLE_R0, BUBBLE_R1, rho)
	var d := dir_of_window(chart, w.x, w.z)
	if d == Vector3.ZERO:
		return ident * (1.0 - s)                                # wedge: fading flat echo
	var d_cam: Vector3 = frame["d_cam"]
	var y_cam: float = frame["y_cam"]
	var mt: Basis = frame["mt"]
	var rr := float(chart.radius)
	var rel := d * rr - d_cam * rr + d * w.y - d_cam * y_cam     # R·(d̂−d̂_cam) + y·d̂ − y_cam·d̂_cam
	var pos_true := mt * rel
	return ident.lerp(pos_true, s)

## The PURE true placement (no bubble) — for the FAR shader / gates that want the un-blended truth.
static func place_true(chart: CosmosChart, w: Vector3, frame: Dictionary) -> Vector3:
	var d := dir_of_window(chart, w.x, w.z)
	if d == Vector3.ZERO:
		return _WEDGE
	var rr := float(chart.radius)
	var rel := d * rr - (frame["d_cam"] as Vector3) * rr + d * w.y - (frame["d_cam"] as Vector3) * float(frame["y_cam"])
	return (frame["mt"] as Basis) * rel

# ============================================================================================
#  THE SHADER (GPU mirror of place_point / place_true) + the global-uniform chart table
# ============================================================================================
# The shader lives here so the ONE placement formula (§2.1 + the bubble) is authored once and shared
# with the CPU mirror above. Every uniform below is a runtime-registered GLOBAL shader parameter, so a
# single push updates ALL M5 materials (terrain, water, VoxelBody, far tiles) with no per-material state —
# exactly the CosmosBend pattern, extended with the per-frame camera frame + the flip-time chart table.
# Godot global params carry no arrays, so the 4-strip fold table is flattened to per-side scalars (s0=EAST,
# s1=WEST, s2=NORTH, s3=SOUTH — the _fold_f classify order). Registered/pushed only when M5_RENDER is on;
# under FLAT_WORLD / default M5_RENDER=false no M5 material is ever built (CosmosBend stays byte-identical).

const U_CAM := "cosmos_bend_origin"          # reuse the bend camera-origin global (camera WINDOW world pos = w_cam)
const U_RADIUS := "cosmos_radius"            # reuse the bend datum-radius global (R)

static var _opaque_m5: Shader = null
static var _translucent_m5: Shader = null
static var _far_m5: Shader = null
static var _globals_m5_ready := false

## Register every M5 global shader parameter exactly once (latched — see CosmosBend.ensure_globals for
## why we never probe first: the get/list calls are editor-only and tank the GLES3 export). MUST run
## before any M5 material is built (a `global uniform` a shader references must already exist).
static func ensure_globals_m5() -> void:
	if _globals_m5_ready:
		return
	var RS := RenderingServer
	RS.global_shader_parameter_add(U_CAM, RS.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	RS.global_shader_parameter_add(U_RADIUS, RS.GLOBAL_VAR_TYPE_FLOAT, float(CubeSphere.radius_for(CubeSphere.HOME_BODY)))
	RS.global_shader_parameter_add("m5_dcam", RS.GLOBAL_VAR_TYPE_VEC3, Vector3(0, 1, 0))
	RS.global_shader_parameter_add("m5_ycam", RS.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	RS.global_shader_parameter_add("m5_mt", RS.GLOBAL_VAR_TYPE_MAT3, Basis.IDENTITY)
	RS.global_shader_parameter_add("m5_org", RS.GLOBAL_VAR_TYPE_VEC2, Vector2.ZERO)
	RS.global_shader_parameter_add("m5_mwin", RS.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 0, 1))
	RS.global_shader_parameter_add("m5_n", RS.GLOBAL_VAR_TYPE_FLOAT, 1.0)
	for nm: String in ["m5_hn", "m5_hu", "m5_hv"]:
		RS.global_shader_parameter_add(nm, RS.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	for k: int in range(4):
		RS.global_shader_parameter_add("m5_s%dm" % k, RS.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 0, 1))
		RS.global_shader_parameter_add("m5_s%dt" % k, RS.GLOBAL_VAR_TYPE_VEC2, Vector2.ZERO)
		RS.global_shader_parameter_add("m5_s%dn" % k, RS.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
		RS.global_shader_parameter_add("m5_s%du" % k, RS.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
		RS.global_shader_parameter_add("m5_s%dv" % k, RS.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	_globals_m5_ready = true

## Per-FRAME push (main.gd → WorldManager): the camera frame globals for `cam` (camera WINDOW position).
## Mirrors camera_frame(): d̂_cam / y_cam / M_tangent + the camera origin (bubble centre) + R.
static func push_camera(chart: CosmosChart, cam: Vector3) -> void:
	ensure_globals_m5()
	var fr := camera_frame(chart, cam)
	var RS := RenderingServer
	RS.global_shader_parameter_set(U_CAM, cam)
	RS.global_shader_parameter_set(U_RADIUS, float(chart.radius))
	RS.global_shader_parameter_set("m5_dcam", fr["d_cam"])
	RS.global_shader_parameter_set("m5_ycam", float(fr["y_cam"]))
	RS.global_shader_parameter_set("m5_mt", fr["mt"])

## Frame-CHANGE push (WorldManager, at every set_active_frame / reanchor site): the chart-orientation +
## 5-chart fold table. org + M_win change on reanchor/flip; the axes on a face flip. Cheap enough to push
## the whole table at each (a handful of RenderingServer sets, only on those discrete events).
static func push_chart_table(chart: CosmosChart) -> void:
	ensure_globals_m5()
	var RS := RenderingServer
	var n := chart.n
	RS.global_shader_parameter_set("m5_org", Vector2(float(chart.i_org), float(chart.j_org)))
	RS.global_shader_parameter_set("m5_mwin", Vector4(float(chart.mw_a), float(chart.mw_b), float(chart.mw_c), float(chart.mw_d)))
	RS.global_shader_parameter_set("m5_n", float(n))
	RS.global_shader_parameter_set("m5_hn", _axisf(CubeSphere._axis_n(chart.face)))
	RS.global_shader_parameter_set("m5_hu", _axisf(CubeSphere._axis_u(chart.face)))
	RS.global_shader_parameter_set("m5_hv", _axisf(CubeSphere._axis_v(chart.face)))
	var sides := [CubeSphere.SIDE_EAST, CubeSphere.SIDE_WEST, CubeSphere.SIDE_NORTH, CubeSphere.SIDE_SOUTH]
	for k: int in range(4):
		var e := CubeSphere.edge_remap(chart.face, int(sides[k]), n)
		var m: Array = e["m"]
		var t: Array = e["t"]
		var fb := int(e["b"])
		RS.global_shader_parameter_set("m5_s%dm" % k, Vector4(float(m[0]), float(m[1]), float(m[2]), float(m[3])))
		RS.global_shader_parameter_set("m5_s%dt" % k, Vector2(float(t[0]), float(t[1])))
		RS.global_shader_parameter_set("m5_s%dn" % k, _axisf(CubeSphere._axis_n(fb)))
		RS.global_shader_parameter_set("m5_s%du" % k, _axisf(CubeSphere._axis_u(fb)))
		RS.global_shader_parameter_set("m5_s%dv" % k, _axisf(CubeSphere._axis_v(fb)))

static func _axisf(a: Vector3i) -> Vector3:
	return Vector3(float(a.x), float(a.y), float(a.z))

## The M5 global-uniform declaration block, prepended to each shader variant (one authored list).
const _M5_UNIFORMS := """global uniform vec3 cosmos_bend_origin;
global uniform float cosmos_radius;
global uniform vec3 m5_dcam;
global uniform float m5_ycam;
global uniform mat3 m5_mt;
global uniform vec2 m5_org;
global uniform vec4 m5_mwin;
global uniform float m5_n;
global uniform vec3 m5_hn; global uniform vec3 m5_hu; global uniform vec3 m5_hv;
global uniform vec4 m5_s0m; global uniform vec2 m5_s0t; global uniform vec3 m5_s0n; global uniform vec3 m5_s0u; global uniform vec3 m5_s0v;
global uniform vec4 m5_s1m; global uniform vec2 m5_s1t; global uniform vec3 m5_s1n; global uniform vec3 m5_s1u; global uniform vec3 m5_s1v;
global uniform vec4 m5_s2m; global uniform vec2 m5_s2t; global uniform vec3 m5_s2n; global uniform vec3 m5_s2u; global uniform vec3 m5_s2v;
global uniform vec4 m5_s3m; global uniform vec2 m5_s3t; global uniform vec3 m5_s3n; global uniform vec3 m5_s3u; global uniform vec3 m5_s3v;
"""

## Shared GLSL prefix: classify the window vertex through the chart (raw p → 5-chart fold → n̂/û/v̂ + face
## coord), emitting _wedge / _nn / _uu / _vv / _fc / _ident / _s. Mirrors _raw_of_f + _fold_f + dir setup.
const _M5_CLASSIFY := """
	vec3 _wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 _w = _wv.xz;
	vec3 _ident = _wv - cosmos_bend_origin;
	float _s = smoothstep(16.0, 104.0, length(_wv.xz - cosmos_bend_origin.xz));
	vec2 _p = m5_org + vec2(m5_mwin.x * _w.x + m5_mwin.y * _w.y, m5_mwin.z * _w.x + m5_mwin.w * _w.y);
	bool _oi = (_p.x < 0.0) || (_p.x >= m5_n);
	bool _oj = (_p.y < 0.0) || (_p.y >= m5_n);
	vec3 _nn = m5_hn; vec3 _uu = m5_hu; vec3 _vv = m5_hv; vec2 _fc = _p; bool _wedge = false;
	if (_oi && _oj) { _wedge = true; }
	else if (_oi || _oj) {
		vec4 _m; vec2 _t;
		if (_p.x >= m5_n) { _m = m5_s0m; _t = m5_s0t; _nn = m5_s0n; _uu = m5_s0u; _vv = m5_s0v; }
		else if (_p.x < 0.0) { _m = m5_s1m; _t = m5_s1t; _nn = m5_s1n; _uu = m5_s1u; _vv = m5_s1v; }
		else if (_p.y >= m5_n) { _m = m5_s2m; _t = m5_s2t; _nn = m5_s2n; _uu = m5_s2u; _vv = m5_s2v; }
		else { _m = m5_s3m; _t = m5_s3t; _nn = m5_s3n; _uu = m5_s3u; _vv = m5_s3v; }
		_fc = vec2(_m.x * _p.x + _m.y * _p.y + _t.x, _m.z * _p.x + _m.w * _p.y + _t.y);
	}
"""

## NEAR vertex body (opaque/translucent): the classify prefix + the INTERACTION BUBBLE
## (render = mix(ident, true, s); wedge = fading echo ident·(1−s)). Mirrors place_point.
const _M5_VERTEX_NEAR := _M5_CLASSIFY + """
	vec3 _out;
	if (_wedge) {
		_out = _ident * (1.0 - _s);
	} else {
		float _a = 2.0 * _fc.x / m5_n - 1.0;
		float _b = 2.0 * _fc.y / m5_n - 1.0;
		vec3 _d = normalize(_nn + tan(_a * 0.7853981633974483) * _uu + tan(_b * 0.7853981633974483) * _vv);
		vec3 _rel = _d * cosmos_radius - m5_dcam * cosmos_radius + _d * _wv.y - m5_dcam * m5_ycam;
		_out = mix(_ident, m5_mt * _rel, _s);
	}
	VERTEX = (inverse(MODEL_MATRIX) * vec4(cosmos_bend_origin + _out, 1.0)).xyz;
"""

## FAR vertex body: the classify prefix + PURE true placement (no bubble — Fable: far = truth); wedge far
## tiles collapse to the camera (degenerate). Mirrors place_true.
const _M5_VERTEX_FAR := _M5_CLASSIFY + """
	vec3 _world;
	if (_wedge) {
		_world = cosmos_bend_origin;
	} else {
		float _a = 2.0 * _fc.x / m5_n - 1.0;
		float _b = 2.0 * _fc.y / m5_n - 1.0;
		vec3 _d = normalize(_nn + tan(_a * 0.7853981633974483) * _uu + tan(_b * 0.7853981633974483) * _vv);
		vec3 _rel = _d * cosmos_radius - m5_dcam * cosmos_radius + _d * _wv.y - m5_dcam * m5_ycam;
		_world = cosmos_bend_origin + m5_mt * _rel;
	}
	VERTEX = (inverse(MODEL_MATRIX) * vec4(_world, 1.0)).xyz;
"""

## Opaque M5 shader — same fragment/uniform surface as CosmosBend.opaque_shader (so BlockMaterials sets
## the identical shader params); the vertex body is the true-position placement + bubble.
static func opaque_shader_m5() -> Shader:
	if _opaque_m5 != null:
		return _opaque_m5
	var s := Shader.new()
	s.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled;\n" + _M5_UNIFORMS + """
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_texture = false;
uniform bool use_vertex_color = true;
uniform vec3 emission_color = vec3(0.0);
uniform float emission_energy = 0.0;
void vertex() {
""" + _M5_VERTEX_NEAR + """}
void fragment() {
	vec4 col = albedo_color;
	if (use_texture) { col *= texture(albedo_tex, UV); }
	if (use_vertex_color) { col.rgb *= COLOR.rgb; }
	ALBEDO = col.rgb;
	EMISSION = emission_color * emission_energy;
}
"""
	_opaque_m5 = s
	return s

## Translucent M5 shader (glass/water/ice) — mirrors CosmosBend.translucent_shader's surface.
static func translucent_shader_m5() -> Shader:
	if _translucent_m5 != null:
		return _translucent_m5
	var s := Shader.new()
	s.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_prepass_alpha;\n" + _M5_UNIFORMS + """
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_texture = false;
void vertex() {
""" + _M5_VERTEX_NEAR + """}
void fragment() {
	vec4 col = albedo_color;
	if (use_texture) { col *= texture(albedo_tex, UV); }
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
"""
	_translucent_m5 = s
	return s

## Far-field M5 shader (LOD tiles) — mirrors CosmosBend.far_shader's surface; PURE true placement.
static func far_shader_m5() -> Shader:
	if _far_m5 != null:
		return _far_m5
	var s := Shader.new()
	s.code = "shader_type spatial;\nrender_mode unshaded, cull_back;\n" + _M5_UNIFORMS + """
void vertex() {
""" + _M5_VERTEX_FAR + """}
void fragment() {
	ALBEDO = COLOR.rgb;
}
"""
	_far_m5 = s
	return s
