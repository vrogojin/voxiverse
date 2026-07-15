extends SceneTree
## COSMOS FP-CARVE C1/C2/C3 gate — the COMPILED C++ facet carve (docs/COSMOS-FACETED-CARVE.md, patch 0004).
## Proves the compiled transcription of the C0-gated GDScript reference:
##   C1  facet_carve_debug_cell == ShapeMesh.build_carve_faces reference (class, verts <= 1e-4, uvs/indices)
##       over real spawn-facet planes (air/interior/straddle/corner) AND a synthetic 2-plane corner cell.
##   C2  get_facet_carve() round-trips the pushed dict (f64 exact).
##   C3  build_mesh end-to-end (16-bit buffer, origin via additional_data) exercises generate_mesh<uint16_t>:
##       straddle-vs-air == reference clip, straddle-vs-cube culls the shared face, tangents==4*verts &
##       colors==verts, enabled=false is plain-cube byte-equal, interior/air sentinel falls to a plain cube.
## Requires the module built WITH patch 0004 (set_facet_carve bound); loud-skip otherwise. NOT A PASS on skip.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const SM := preload("res://src/world/shape_mesh.gd")

const CH_TYPE := 0        # VoxelBuffer.CHANNEL_TYPE
const DEPTH_16 := 1       # VoxelBuffer.DEPTH_16_BIT
const A_VERTEX := 0       # Mesh.ARRAY_VERTEX
const A_NORMAL := 1       # Mesh.ARRAY_NORMAL
const A_TANGENT := 2      # Mesh.ARRAY_TANGENT
const A_COLOR := 3        # Mesh.ARRAY_COLOR
const A_TEX_UV := 4       # Mesh.ARRAY_TEX_UV
const A_INDEX := 12       # Mesh.ARRAY_INDEX

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_facet_carve_cpp (FP-CARVE C1/C2/C3 COMPILED) ===")
	if not ClassDB.class_exists("VoxelMesherBlocky"):
		print("  SKIPPED — godot_voxel module absent. NOT A PASS."); print("==== VERIFY: SKIPPED ===="); quit(2); return
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if mesher == null or not mesher.has_method("set_facet_carve") or not mesher.has_method("facet_carve_debug_cell"):
		print("  SKIPPED — engine built WITHOUT patch 0004 (set_facet_carve unbound). Rebuild required. NOT A PASS.")
		print("==== VERIFY: SKIPPED ===="); quit(2); return

	TC.warm_up()
	FA.warm_up()

	_gate_c1_debug_cell(mesher)
	_gate_c2_roundtrip(mesher)
	_gate_c3_build_mesh()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---- C1: compiled clip == GDScript reference ----------------------------------------------------
func _gate_c1_debug_cell(mesher: Object) -> void:
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var planes := FA.seam_planes_f64(fid)
	mesher.call("set_facet_carve", {"enabled": true, "planes": planes, "arid_base": 2, "arid_count": 1})

	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var straddle := 0
	var corner := 0
	var air := 0
	var interior := 0
	var class_fail := 0
	var vert_fail := 0
	var uv_fail := 0
	var idx_fail := 0
	var worst := 0.0
	var z := lo.y
	while z <= hi.y and (straddle < 120 or corner < 16 or air < 4 or interior < 4):
		var x := lo.x
		while x <= hi.x and (straddle < 120 or corner < 16 or air < 4 or interior < 4):
			var g := TC.height_at(x, z)
			for y in range(g - 4, g + 3):
				var ref := _ref_debug(planes, x, y, z)
				var cls: int = ref["class"]
				if cls == 0:
					if air >= 4: continue
					air += 1
				elif cls == 1:
					if interior >= 4: continue
					interior += 1
				else:
					var ns: int = ref["nstraddle"]
					if ns >= 2:
						if corner >= 16: continue
						corner += 1
					else:
						if straddle >= 120: continue
						straddle += 1
				var dbg: Dictionary = mesher.call("facet_carve_debug_cell", x, y, z)
				var r := _cmp_debug(ref, dbg)
				class_fail += int(r["class"])
				vert_fail += int(r["vert"])
				uv_fail += int(r["uv"])
				idx_fail += int(r["idx"])
				worst = maxf(worst, r["worst"])
			x += 1
		z += 1
	_ok(straddle > 0 and corner > 0 and air > 0 and interior > 0,
		"C1 coverage: straddle=%d corner=%d air=%d interior=%d" % [straddle, corner, air, interior])
	_ok(class_fail == 0, "C1: class matches reference (fails=%d)" % class_fail)
	_ok(vert_fail == 0, "C1: verts match reference <=1e-4 (fails=%d, worst=%s)" % [vert_fail, worst])
	_ok(uv_fail == 0, "C1: uvs match reference (fails=%d)" % uv_fail)
	_ok(idx_fail == 0, "C1: indices match reference exactly (fails=%d)" % idx_fail)

	# Synthetic 2-plane corner cell (independent of FacetAtlas classification).
	var synth := PackedFloat64Array([
		1.0, 0.0, 0.0, -10.5,   # own = x - 10.5 -> straddle at lattice (10,10,10)
		0.0, 0.0, 1.0, -10.5,   # own = z - 10.5 -> straddle
		0.0, 0.0, 0.0, 100.0,   # interior filler (never straddle/air)
		0.0, 0.0, 0.0, 100.0])
	mesher.call("set_facet_carve", {"enabled": true, "planes": synth, "arid_base": 2, "arid_count": 1})
	var sref := _ref_debug(synth, 10, 10, 10)
	var sdbg: Dictionary = mesher.call("facet_carve_debug_cell", 10, 10, 10)
	var sr := _cmp_debug(sref, sdbg)
	_ok(sref["class"] == 2 and int(sref["nstraddle"]) == 2, "C1 synthetic: cell (10,10,10) is a 2-plane corner")
	_ok(sr["class"] == 0 and sr["vert"] == 0 and sr["uv"] == 0 and sr["idx"] == 0,
		"C1 synthetic corner: compiled clip == reference (worst=%s)" % sr["worst"])

# GDScript re-implementation of facet_cell_state + the plain-fan emit (mirror of facet_carve_debug_cell).
func _ref_debug(planes: PackedFloat64Array, x: int, y: int, z: int) -> Dictionary:
	var SEAM_EPS := 1.0e-6
	var locals: Array = []
	var air := false
	for slot in range(4):
		var A: float = planes[slot * 4]
		var B: float = planes[slot * 4 + 1]
		var C: float = planes[slot * 4 + 2]
		var D: float = planes[slot * 4 + 3]
		var base := A * float(x) + B * float(y) + C * float(z) + D
		var lo := base + minf(0.0, A) + minf(0.0, B) + minf(0.0, C)
		var hi := base + maxf(0.0, A) + maxf(0.0, B) + maxf(0.0, C)
		if hi <= SEAM_EPS:
			air = true
			break
		if lo < -SEAM_EPS:
			locals.append([A, B, C, base])
	var cls := 0 if air else (2 if locals.size() > 0 else 1)
	var d := {"class": cls, "nstraddle": locals.size(),
		"verts": PackedVector3Array(), "uvs": PackedVector2Array(), "indices": PackedInt32Array()}
	if cls == 2:
		for f: Dictionary in SM.build_carve_faces(locals):
			var poly: Array = f["poly"]
			if poly.size() < 3:
				continue
			var base_i: int = d["verts"].size()
			var nrm: Vector3 = f["normal"]
			for p: Vector3 in poly:
				d["verts"].append(p)
				d["uvs"].append(SM._face_uv(p, nrm))
			for i in range(1, poly.size() - 1):
				d["indices"].append(base_i + 0)
				d["indices"].append(base_i + i)
				d["indices"].append(base_i + i + 1)
	return d

func _cmp_debug(ref: Dictionary, dbg: Dictionary) -> Dictionary:
	var out := {"class": 0, "vert": 0, "uv": 0, "idx": 0, "worst": 0.0}
	if int(ref["class"]) != int(dbg.get("class", -99)):
		out["class"] = 1
	var rv: PackedVector3Array = ref["verts"]
	var dv: PackedVector3Array = dbg.get("verts", PackedVector3Array())
	var ru: PackedVector2Array = ref["uvs"]
	var du: PackedVector2Array = dbg.get("uvs", PackedVector2Array())
	var ri: PackedInt32Array = ref["indices"]
	var di: PackedInt32Array = dbg.get("indices", PackedInt32Array())
	if rv.size() != dv.size():
		out["vert"] = 1
	else:
		for i in range(rv.size()):
			var e := rv[i].distance_to(dv[i])
			out["worst"] = maxf(out["worst"], e)
			if e > 1e-4:
				out["vert"] = int(out["vert"]) + 1
	if ru.size() != du.size():
		out["uv"] = 1
	else:
		for i in range(ru.size()):
			if (ru[i] - du[i]).length() > 1e-4:
				out["uv"] = int(out["uv"]) + 1
	if ri.size() != di.size():
		out["idx"] = 1
	else:
		for i in range(ri.size()):
			if ri[i] != di[i]:
				out["idx"] = int(out["idx"]) + 1
	return out

# ---- C2: get_facet_carve round-trip -------------------------------------------------------------
func _gate_c2_roundtrip(mesher: Object) -> void:
	var planes := FA.seam_planes_f64(FA.spawn_facet())
	mesher.call("set_facet_carve", {"enabled": true, "planes": planes, "arid_base": 7, "arid_count": 3})
	var got: Dictionary = mesher.call("get_facet_carve")
	var ok := bool(got.get("enabled", false)) and int(got.get("arid_base", -1)) == 7 and int(got.get("arid_count", -1)) == 3
	var gp: PackedFloat64Array = got.get("planes", PackedFloat64Array())
	var pmatch := gp.size() == 16
	if pmatch:
		for i in range(16):
			if gp[i] != planes[i]:
				pmatch = false
				break
	_ok(ok and pmatch, "C2: get_facet_carve() round-trips the pushed dict (f64 exact)")

# ---- C3: build_mesh end-to-end ------------------------------------------------------------------
func _gate_c3_build_mesh() -> void:
	# A single-plane straddle at lattice (1,1,1): own = x - 1.5 (keep u.x in [0.5,1]).
	var planes := PackedFloat64Array([
		1.0, 0.0, 0.0, -1.5,
		0.0, 0.0, 0.0, 100.0,
		0.0, 0.0, 0.0, 100.0,
		0.0, 0.0, 0.0, 100.0])
	var origin := Vector3i(0, 0, 0)
	# sentinel at buffer index (2,2,2) -> lattice (1,1,1); pos offset = (1,1,1).
	var scell := Vector3i(2, 2, 2)

	# (a) straddle sentinel next to air == reference clip (offset by pos).
	var lm := _new_lib_mesher()
	var mesher: Object = lm[1]
	mesher.call("set_facet_carve", {"enabled": true, "planes": planes, "arid_base": 2, "arid_count": 1})
	var buf_a := _buffer([[scell, 2]])
	var arr_a := _mesh_arrays(mesher, buf_a, origin)
	var ref := _ref_debug(planes, 1, 1, 1)
	var refv: PackedVector3Array = ref["verts"]
	if arr_a.is_empty():
		_ok(false, "C3(a): build_mesh produced a surface for the straddle sentinel")
	else:
		var av: PackedVector3Array = arr_a[A_VERTEX]
		var bidi := av.size() == refv.size()
		if bidi:
			for v: Vector3 in av:
				var best := 1e9
				for u: Vector3 in refv:
					best = minf(best, (v - Vector3(1, 1, 1)).distance_to(u))
				if best > 1e-4:
					bidi = false
					break
		_ok(bidi, "C3(a): straddle-vs-air surface verts == reference clip (n=%d vs %d)" % [av.size(), refv.size()])
		# (c) tangents == 4*verts, colors == verts
		var at: PackedFloat32Array = arr_a[A_TANGENT]
		var ac: PackedColorArray = arr_a[A_COLOR]
		_ok(at.size() == 4 * av.size(), "C3(c): tangents.size()==4*verts (%d vs %d)" % [at.size(), 4 * av.size()])
		_ok(ac.size() == av.size(), "C3(c): colors.size()==verts (%d vs %d)" % [ac.size(), av.size()])

	# (b) sentinel next to a full cube on +x -> the shared +X face is culled. The neighbour cube (id 3)
	# carries a DISTINCT material, so surface 0 (the sentinel's material) is the sentinel's geometry ALONE
	# -> its triangle count drops by the culled +X face vs the all-air case (a).
	var buf_b := _buffer([[scell, 2], [Vector3i(3, 2, 2), 3]])
	var arr_b := _mesh_arrays(mesher, buf_b, origin)   # surface 0 = the sentinel's material
	var tris_a := (arr_a[A_INDEX] as PackedInt32Array).size() / 3 if not arr_a.is_empty() else 0
	var tris_b := 0
	if not arr_b.is_empty():
		tris_b = (arr_b[A_INDEX] as PackedInt32Array).size() / 3
	_ok(tris_b > 0 and tris_b < tris_a, "C3(b): straddle-vs-cube culls the shared face (tris %d < %d)" % [tris_b, tris_a])

	# (d) enabled=false -> the sentinel meshes as a plain cube, byte-equal to the cube-ARID buffer.
	mesher.call("set_facet_carve", {"enabled": false})
	var arr_d := _mesh_arrays(mesher, _buffer([[scell, 2]]), origin)
	var arr_cube := _mesh_arrays(mesher, _buffer([[scell, 1]]), origin)
	var deq := (not arr_d.is_empty()) and (not arr_cube.is_empty())
	if deq:
		var dv: PackedVector3Array = arr_d[A_VERTEX]
		var cv: PackedVector3Array = arr_cube[A_VERTEX]
		deq = dv.size() == cv.size() and _same_pointset(dv, cv)
	_ok(deq, "C3(d): enabled=false -> sentinel is a plain cube, byte-equal to the cube ARID")

	# (e) sentinel classified interior (plane far away) -> plain-cube fallback, no crash, no hole.
	var far := PackedFloat64Array([
		0.0, 0.0, 0.0, 500.0, 0.0, 0.0, 0.0, 500.0,
		0.0, 0.0, 0.0, 500.0, 0.0, 0.0, 0.0, 500.0])
	mesher.call("set_facet_carve", {"enabled": true, "planes": far, "arid_base": 2, "arid_count": 1})
	var arr_e := _mesh_arrays(mesher, _buffer([[scell, 2]]), origin)
	var ev := 0
	if not arr_e.is_empty():
		ev = (arr_e[A_VERTEX] as PackedVector3Array).size()
	_ok(ev == 24, "C3(e): interior sentinel falls to a plain cube (24 verts, no hole; got %d)" % ev)

func _new_lib_mesher() -> Array:
	var library: Object = ClassDB.instantiate("VoxelBlockyLibrary")
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	var mat := StandardMaterial3D.new()
	var mat2 := StandardMaterial3D.new()
	mat2.albedo_color = Color(0.2, 0.4, 0.8)   # distinct material -> distinct surface for the neighbour
	# id 0 = air/empty
	if ClassDB.class_exists("VoxelBlockyModelEmpty"):
		library.call("add_model", ClassDB.instantiate("VoxelBlockyModelEmpty"))
	# id 1 = plain cube, id 2 = carve sentinel cube (same material -> same material_id 0),
	# id 3 = a neighbour cube with a DISTINCT material (material_id 1) so it lands on its own surface.
	_add_cube(library, mat)
	_add_cube(library, mat)
	_add_cube(library, mat2)
	if library.has_method("bake"):
		library.call("bake")
	if mesher.has_method("set_library"):
		mesher.call("set_library", library)
	return [library, mesher]

func _add_cube(library: Object, mat: Material) -> void:
	var cube: Object = ClassDB.instantiate("VoxelBlockyModelCube")
	if cube.has_method("set_atlas_size_in_tiles"):
		cube.call("set_atlas_size_in_tiles", Vector2i(1, 1))
	if cube.has_method("set_tile"):
		for side in 6:
			cube.call("set_tile", side, Vector2i(0, 0))
	if cube.has_method("set_material_override"):
		cube.call("set_material_override", 0, mat)
	library.call("add_model", cube)

func _buffer(cells: Array) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 6, 6, 6)
	buf.call("set_channel_depth", CH_TYPE, DEPTH_16)
	for c: Array in cells:
		var p: Vector3i = c[0]
		buf.call("set_voxel", int(c[1]), p.x, p.y, p.z, CH_TYPE)
	return buf

func _mesh_arrays(mesher: Object, buf: Object, origin: Vector3i) -> Array:
	var mesh: Object = mesher.call("build_mesh", buf, [], {"origin_in_voxels": origin})
	if mesh == null or not mesh.has_method("get_surface_count") or int(mesh.call("get_surface_count")) == 0:
		return []
	return mesh.call("surface_get_arrays", 0)

func _same_pointset(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	for v: Vector3 in a:
		var found := false
		for u: Vector3 in b:
			if v.distance_to(u) < 1e-5:
				found = true
				break
		if not found:
			return false
	return true
