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
#  THE SHADER (GPU mirror of place_point / place_true) + the chart table
# ============================================================================================
# The shader lives here so the ONE placement formula (§2.1 + the bubble) is authored once and shared with
# the CPU mirror above. AFTER the first WebGL2 deploy scrambled the strips while the CPU mirror passed 11/0,
# Fable diagnosed a uniform-TRANSPORT bug (COSMOS-PROJECTION-STUDY §3): the 5-chart fold table had been
# minted as ~30 scalar GLOBAL params (Godot globals cannot be arrays), and one wrong index/sign there
# scrambles a whole strip — invisible to the math-only mirror. The fix (this file):
#   * the chart table is now PER-MATERIAL uniform ARRAYS (indexed 0=home, 1=EAST, 2=WEST, 3=NORTH,
#     4=SOUTH; a wedge vertex is idx 5, handled before any array read). Home carries an IDENTITY fold
#     affine so home + strips share ONE code path (no special-case branch to get wrong).
#   * ONE writer — set_chart_table() — packs the table once and applies it to EVERY registered M5 material
#     (near opaque/translucent + far) in the SAME call, so near and far can never drift apart (the
#     LOD/chunk-divergence class). A snapshot is kept so a lazily-built material gets the current table on
#     register(). The per-FRAME camera frame stays scalar GLOBALS (allowed, already proven by the bend).
#   * verify_cosmos_m5_parity transcribes this GLSL against the SAME packed arrays and diffs vs place_point
#     — the headless catch for exactly the packing class that slipped past 11/0.
# Registered/built only when M5_RENDER is on; default false → no M5 material exists (CosmosBend byte-identical).

const U_CAM := "cosmos_bend_origin"          # reuse the bend camera-origin global (camera WINDOW world pos = w_cam)
const U_RADIUS := "cosmos_radius"            # reuse the bend datum-radius global (R)
const U_DEBUG := "m5_debug_chart"           # global bool: paint each vertex by its classified chart (debug)

static var _opaque_m5: Shader = null
static var _translucent_m5: Shader = null
static var _far_m5: Shader = null
static var _globals_m5_ready := false
static var _materials: Array = []            # every live M5 ShaderMaterial (near ids + far) — the writer's fan-out
static var _snapshot: Dictionary = {}        # last packed chart table (uniform name → value); applied to late registrants

## Register the M5 SCALAR global shader params exactly once (latched — see CosmosBend.ensure_globals for why
## we never probe first). The chart TABLE is no longer global (it is per-material arrays); only the per-frame
## camera frame + the debug toggle live here. MUST run before any M5 material is built.
static func ensure_globals_m5() -> void:
	if _globals_m5_ready:
		return
	var RS := RenderingServer
	RS.global_shader_parameter_add(U_CAM, RS.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	RS.global_shader_parameter_add(U_RADIUS, RS.GLOBAL_VAR_TYPE_FLOAT, float(CubeSphere.radius_for(CubeSphere.HOME_BODY)))
	RS.global_shader_parameter_add("m5_dcam", RS.GLOBAL_VAR_TYPE_VEC3, Vector3(0, 1, 0))
	RS.global_shader_parameter_add("m5_ycam", RS.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	RS.global_shader_parameter_add("m5_mt", RS.GLOBAL_VAR_TYPE_MAT3, Basis.IDENTITY)
	RS.global_shader_parameter_add(U_DEBUG, RS.GLOBAL_VAR_TYPE_BOOL, false)
	_globals_m5_ready = true

## Register an M5 material with the single-writer fan-out. Called at material build (BlockMaterials /
## FarTerrain). Idempotent; a material built after a chart change gets the current table immediately.
static func register_material(m: ShaderMaterial) -> void:
	if m == null or _materials.has(m):
		return
	_materials.append(m)
	if not _snapshot.is_empty():
		_apply_snapshot(m)

## Drop the material registry (BlockMaterials.reset_cache session boundary — the cached materials are
## rebuilt fresh, so the old instances must not linger in the fan-out list).
static func reset_materials() -> void:
	_materials.clear()

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

## Frame-CHANGE writer (WorldManager, at every set_active_frame / reanchor site): pack the chart-orientation
## + 5-chart fold table ONCE and apply it to EVERY registered M5 material in this single call (the single-
## writer rule — near + far can never drift). Also snapshots it for materials built later. Index convention:
## 0 = home (IDENTITY fold affine), 1 = EAST, 2 = WEST, 3 = NORTH, 4 = SOUTH; wedge (idx 5) reads no array.
static func set_chart_table(chart: CosmosChart) -> void:
	_snapshot = pack_chart_table(chart)
	for m in _materials:
		_apply_snapshot(m)

## Pack the chart table into the per-material uniform dictionary (also the input the parity harness diffs).
## Kept pure (no RenderingServer / material side effects) so verify can call it directly.
static func pack_chart_table(chart: CosmosChart) -> Dictionary:
	var n := chart.n
	var cm: Array = []          # vec4[5]  edge affine (m0,m1,m2,m3) per chart
	var ct: Array = []          # vec2[5]  edge translation (t0,t1)
	var an: Array = []          # vec3[5]  true face n̂
	var au: Array = []          # vec3[5]  true face û
	var av: Array = []          # vec3[5]  true face v̂
	cm.resize(5); ct.resize(5); an.resize(5); au.resize(5); av.resize(5)
	# idx 0 = home: identity fold (fc = p) + home face axes
	cm[0] = Vector4(1, 0, 0, 1); ct[0] = Vector2(0, 0)
	an[0] = _axisf(CubeSphere._axis_n(chart.face))
	au[0] = _axisf(CubeSphere._axis_u(chart.face))
	av[0] = _axisf(CubeSphere._axis_v(chart.face))
	# idx 1..4 = EAST/WEST/NORTH/SOUTH strips (the _fold_f classify order): edge affine + neighbour axes
	var sides := [CubeSphere.SIDE_EAST, CubeSphere.SIDE_WEST, CubeSphere.SIDE_NORTH, CubeSphere.SIDE_SOUTH]
	for k: int in range(4):
		var e := CubeSphere.edge_remap(chart.face, int(sides[k]), n)
		var m: Array = e["m"]
		var t: Array = e["t"]
		var fb := int(e["b"])
		cm[k + 1] = Vector4(float(m[0]), float(m[1]), float(m[2]), float(m[3]))
		ct[k + 1] = Vector2(float(t[0]), float(t[1]))
		an[k + 1] = _axisf(CubeSphere._axis_n(fb))
		au[k + 1] = _axisf(CubeSphere._axis_u(fb))
		av[k + 1] = _axisf(CubeSphere._axis_v(fb))
	return {
		"chart_org": Vector2(float(chart.i_org), float(chart.j_org)),
		"chart_mwin": Vector4(float(chart.mw_a), float(chart.mw_b), float(chart.mw_c), float(chart.mw_d)),
		"chart_ncells": float(n),
		"chart_m": cm, "chart_t": ct, "chart_axn": an, "chart_axu": au, "chart_axv": av,
	}

## The last packed chart table (uniform name → value) — read by the parity harness.
static func chart_snapshot() -> Dictionary:
	return _snapshot

static func _apply_snapshot(m: ShaderMaterial) -> void:
	for key: String in _snapshot:
		m.set_shader_parameter(key, _snapshot[key])

static func _axisf(a: Vector3i) -> Vector3:
	return Vector3(float(a.x), float(a.y), float(a.z))

## Toggle the chart-ID debug albedo (Fable §3.2): paint each vertex by its classified chart so one live
## screenshot shows exactly which vertices misclassify. Global bool → flips all M5 materials at once.
static func set_debug_chart(on: bool) -> void:
	ensure_globals_m5()
	RenderingServer.global_shader_parameter_set(U_DEBUG, on)

## The per-material chart-table uniform declarations, prepended to each shader. ARRAYS (per-material — the
## fix): Godot's shader language allows uniform arrays on materials (only GLOBAL params can't be arrays).
const _M5_UNIFORMS := """global uniform vec3 cosmos_bend_origin;
global uniform float cosmos_radius;
global uniform vec3 m5_dcam;
global uniform float m5_ycam;
global uniform mat3 m5_mt;
global uniform bool m5_debug_chart;
uniform vec2 chart_org;
uniform vec4 chart_mwin;
uniform float chart_ncells;
uniform vec4 chart_m[5];
uniform vec2 chart_t[5];
uniform vec3 chart_axn[5];
uniform vec3 chart_axu[5];
uniform vec3 chart_axv[5];
varying flat float v_chart;
"""

## The chart-ID debug palette (home grey / EAST red / WEST blue / NORTH green / SOUTH yellow / wedge magenta).
const _M5_DEBUG_FN := """
vec3 _m5_chart_color(float c) {
	if (c < 0.5) return vec3(0.60, 0.60, 0.60);
	if (c < 1.5) return vec3(0.90, 0.20, 0.20);
	if (c < 2.5) return vec3(0.20, 0.50, 0.90);
	if (c < 3.5) return vec3(0.20, 0.80, 0.20);
	if (c < 4.5) return vec3(0.90, 0.80, 0.20);
	return vec3(1.00, 0.00, 1.00);
}
"""

## Shared GLSL classify prefix: window vertex → raw p → 5-chart index (0 home / 1-4 strips / 5 wedge) →
## fold coord _fc + true face axes _nn/_uu/_vv, plus _ident and the bubble weight _s. Mirrors _raw_of_f +
## _fold_f. Home (idx 0) carries an identity affine so it shares the strip fold expression. v_chart set for
## the debug view. WebGL2 (GLSL ES 3.00) permits dynamic indexing of uniform arrays.
const _M5_CLASSIFY := """
	vec3 _wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 _w = _wv.xz;
	vec3 _ident = _wv - cosmos_bend_origin;
	float _s = smoothstep(16.0, 104.0, length(_wv.xz - cosmos_bend_origin.xz));
	vec2 _p = chart_org + vec2(chart_mwin.x * _w.x + chart_mwin.y * _w.y, chart_mwin.z * _w.x + chart_mwin.w * _w.y);
	bool _oi = (_p.x < 0.0) || (_p.x >= chart_ncells);
	bool _oj = (_p.y < 0.0) || (_p.y >= chart_ncells);
	int _idx;
	if (_oi && _oj) { _idx = 5; }
	else if (!_oi && !_oj) { _idx = 0; }
	else if (_p.x >= chart_ncells) { _idx = 1; }
	else if (_p.x < 0.0) { _idx = 2; }
	else if (_p.y >= chart_ncells) { _idx = 3; }
	else { _idx = 4; }
	v_chart = float(_idx);
	int _ai = (_idx == 5) ? 0 : _idx;
	vec4 _m = chart_m[_ai]; vec2 _t = chart_t[_ai];
	vec2 _fc = vec2(_m.x * _p.x + _m.y * _p.y + _t.x, _m.z * _p.x + _m.w * _p.y + _t.y);
	vec3 _nn = chart_axn[_ai]; vec3 _uu = chart_axu[_ai]; vec3 _vv = chart_axv[_ai];
"""

## NEAR vertex body: classify + the INTERACTION BUBBLE (render = mix(ident, true, s); wedge = fading echo).
const _M5_VERTEX_NEAR := _M5_CLASSIFY + """
	vec3 _out;
	if (_idx == 5) {
		_out = _ident * (1.0 - _s);
	} else {
		float _a = 2.0 * _fc.x / chart_ncells - 1.0;
		float _b = 2.0 * _fc.y / chart_ncells - 1.0;
		vec3 _d = normalize(_nn + tan(_a * 0.7853981633974483) * _uu + tan(_b * 0.7853981633974483) * _vv);
		vec3 _rel = _d * cosmos_radius - m5_dcam * cosmos_radius + _d * _wv.y - m5_dcam * m5_ycam;
		_out = mix(_ident, m5_mt * _rel, _s);
	}
	VERTEX = (inverse(MODEL_MATRIX) * vec4(cosmos_bend_origin + _out, 1.0)).xyz;
"""

## FAR vertex body: classify + PURE true placement (no bubble — Fable: far = truth); wedge collapses to cam.
const _M5_VERTEX_FAR := _M5_CLASSIFY + """
	vec3 _world;
	if (_idx == 5) {
		_world = cosmos_bend_origin;
	} else {
		float _a = 2.0 * _fc.x / chart_ncells - 1.0;
		float _b = 2.0 * _fc.y / chart_ncells - 1.0;
		vec3 _d = normalize(_nn + tan(_a * 0.7853981633974483) * _uu + tan(_b * 0.7853981633974483) * _vv);
		vec3 _rel = _d * cosmos_radius - m5_dcam * cosmos_radius + _d * _wv.y - m5_dcam * m5_ycam;
		_world = cosmos_bend_origin + m5_mt * _rel;
	}
	VERTEX = (inverse(MODEL_MATRIX) * vec4(_world, 1.0)).xyz;
"""

## Opaque M5 shader — same fragment/param surface as CosmosBend.opaque_shader; vertex = true placement + bubble.
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
""" + _M5_DEBUG_FN + """
void vertex() {
""" + _M5_VERTEX_NEAR + """}
void fragment() {
	if (m5_debug_chart) { ALBEDO = _m5_chart_color(v_chart); EMISSION = vec3(0.0); }
	else {
		vec4 col = albedo_color;
		if (use_texture) { col *= texture(albedo_tex, UV); }
		if (use_vertex_color) { col.rgb *= COLOR.rgb; }
		ALBEDO = col.rgb;
		EMISSION = emission_color * emission_energy;
	}
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
""" + _M5_DEBUG_FN + """
void vertex() {
""" + _M5_VERTEX_NEAR + """}
void fragment() {
	if (m5_debug_chart) { ALBEDO = _m5_chart_color(v_chart); ALPHA = 1.0; }
	else {
		vec4 col = albedo_color;
		if (use_texture) { col *= texture(albedo_tex, UV); }
		ALBEDO = col.rgb;
		ALPHA = col.a;
	}
}
"""
	_translucent_m5 = s
	return s

## Far-field M5 shader (LOD tiles) — mirrors CosmosBend.far_shader's surface; PURE true placement.
static func far_shader_m5() -> Shader:
	if _far_m5 != null:
		return _far_m5
	var s := Shader.new()
	s.code = "shader_type spatial;\nrender_mode unshaded, cull_back;\n" + _M5_UNIFORMS + _M5_DEBUG_FN + """
void vertex() {
""" + _M5_VERTEX_FAR + """}
void fragment() {
	ALBEDO = m5_debug_chart ? _m5_chart_color(v_chart) : COLOR.rgb;
}
"""
	_far_m5 = s
	return s
