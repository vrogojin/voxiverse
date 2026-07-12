class_name FacetedSpike
extends Node3D
## COSMOS FP0 (docs/COSMOS-FACETED-PLANET-STUDY.md §11) — the faceted-planet VISUAL SPIKE. A static demo
## planet: 6·k² FLAT square facets (CosmosFacet) tilted to approximate a sphere, meeting at dihedral ridges,
## each carrying the REAL earth terrain (height + biome colour). Directional-lit so the flat facets read
## clearly. Free-fly camera. NO streaming, NO physics, NO wedge, NO fold machinery — the point is only to let
## the user judge the faceted LOOK (faces JOIN at seams; there is no fourth wedge surface). Built by main.gd
## when CubeSphere.FACETED_SPIKE is true, instead of the normal world.

const R_DEMO := 512.0        # demo planet radius (blocks) — small so the whole faceted sphere is visible
const K_DEMO := 8            # faceting resolution → 384 facets, ~10° ridges (clearly faceted for the taste test)
const CELLS := 10            # heightmap cells per facet edge
const RELIEF := 0.35         # metres of relief per (g − SEA_LEVEL) block — chunky but keeps facets the star

func _ready() -> void:
	_setup_env()
	add_child(_build_planet())
	add_child(_build_camera())
	add_child(_build_hud())

func _build_planet() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in range(6):
		for a in range(K_DEMO):
			for b in range(K_DEMO):
				_emit_facet(st, face, a, b)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "FacetedPlanet"
	mi.mesh = st.commit()
	var tc := 0
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		var arr := mi.mesh.surface_get_arrays(0)
		var iv: Variant = arr[Mesh.ARRAY_INDEX]
		var vv: Variant = arr[Mesh.ARRAY_VERTEX]
		tc = ((iv as PackedInt32Array).size() / 3) if iv != null else ((vv as PackedVector3Array).size() / 3)
	print("[FP0] faceted planet built: %d facets (k=%d), %d triangles, R=%d" % [6 * K_DEMO * K_DEMO, K_DEMO, tc, int(R_DEMO)])
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED     # spike: winding-agnostic
	mat.roughness = 1.0
	mi.material_override = mat
	return mi

func _emit_facet(st: SurfaceTool, face: int, a: int, b: int) -> void:
	var normal := CosmosFacet.facet_normal(face, a, b, K_DEMO)
	var stride := CELLS + 1
	var pos: Array = []
	var col: Array = []
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(CELLS)
			var t := float(gj) / float(CELLS)
			var d := CosmosFacet.facet_dir_at(face, a, b, K_DEMO, s, t)
			var ter := _terrain(d)
			var relief := maxf(0.0, float(int(ter["g"]) - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(CosmosFacet.facet_pos_at(face, a, b, K_DEMO, s, t, R_DEMO) + normal * relief)
			col.append(ter["color"])
	for gj in range(CELLS):
		for gi in range(CELLS):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			_tri(st, pos, col, i0, i2, i1)
			_tri(st, pos, col, i1, i2, i3)

func _tri(st: SurfaceTool, pos: Array, col: Array, i: int, j: int, k: int) -> void:
	st.set_color(col[i]); st.add_vertex(pos[i])
	st.set_color(col[j]); st.add_vertex(pos[j])
	st.set_color(col[k]); st.add_vertex(pos[k])

## Real earth terrain at sphere direction d: map to a cube-face cell, read the curved profile, colour via the
## far palette (same biome/snow/sea colours the far LOD uses). The faceted planet shows the SAME world.
func _terrain(d: CubeSphere.DVec3) -> Dictionary:
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var g := CubeSphere.dir_to_face_cell(d, n)
	var face := int(g["face"])
	var i := clampi(int(g["fi"]), 0, n - 1)
	var j := clampi(int(g["fj"]), 0, n - 1)
	var prof := TerrainConfig._curved_profile(face, i, j)   # Vector4(g, biome, c, t)
	var gg := int(prof.x)
	var biome := int(prof.y)
	var tt := prof.w
	var clamped_sea := gg <= TerrainConfig.SEA_LEVEL
	return {"g": gg, "color": FarPalette.color_for(gg, biome, tt, clamped_sea)}

func _setup_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.05)     # space-black so the planet reads
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.37, 0.42)
	env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()               # flat-shades the facets so they POP
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	sun.light_energy = 1.1
	add_child(sun)

func _build_camera() -> Camera3D:
	var cam := FreeCam.new()
	cam.name = "FreeCam"
	cam.position = Vector3(0.0, R_DEMO * 0.5, R_DEMO * 2.4)
	cam.far = 20000.0
	cam.fov = 70.0
	return cam

func _build_hud() -> CanvasLayer:
	var cl := CanvasLayer.new()
	var lbl := Label.new()
	lbl.text = "FP0 FACETED PLANET SPIKE\nWASD + Space/Shift fly · mouse look · Ctrl = fast · Esc = release mouse\n%d flat facets (k=%d) · faces JOIN at ridges · no wedge" % [6 * K_DEMO * K_DEMO, K_DEMO]
	lbl.position = Vector2(12, 10)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	cl.add_child(lbl)
	return cl

## Minimal free-fly camera (no physics) for the spike.
class FreeCam extends Camera3D:
	var _yaw := 0.0
	var _pitch := -0.2
	func _ready() -> void:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		rotation = Vector3(_pitch, _yaw, 0.0)
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var mm := event as InputEventMouseMotion
			_yaw -= mm.relative.x * 0.005
			_pitch = clampf(_pitch - mm.relative.y * 0.005, -1.55, 1.55)
			rotation = Vector3(_pitch, _yaw, 0.0)
		elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	func _process(delta: float) -> void:
		var v := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): v.z -= 1.0
		if Input.is_key_pressed(KEY_S): v.z += 1.0
		if Input.is_key_pressed(KEY_A): v.x -= 1.0
		if Input.is_key_pressed(KEY_D): v.x += 1.0
		if Input.is_key_pressed(KEY_SPACE): v.y += 1.0
		if Input.is_key_pressed(KEY_SHIFT): v.y -= 1.0
		if v != Vector3.ZERO:
			var sp := 180.0 * (5.0 if Input.is_key_pressed(KEY_CTRL) else 1.0)
			global_position += (global_transform.basis * v.normalized()) * sp * delta
