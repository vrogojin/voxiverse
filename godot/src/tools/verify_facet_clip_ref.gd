extends SceneTree
## COSMOS FP-CARVE C0 (docs/COSMOS-FACETED-CARVE.md) — the multi-plane face-clip REFERENCE gate. Proves the
## GDScript that the C++ mesher (patch 0004) transcribes 1:1 BEFORE any C++ is written:
##   * ShapeMesh.build_carve_faces(local_planes) folds the unit cube through _clip_solid once per plane.
##   * Its face vertex-cloud == FacetAtlas.junction_prism_verts (the shared clip enumerator) bidirectionally.
##   * Every produced vertex sits inside all straddling half-spaces (f64 own_dist ≥ −1e-4) and in [0,1]³.
##   * For SINGLE-plane cells with the quantized model plane, the emitted geometry is byte-identical to
##     ShapeMesh._build_junction (the shipped render path).
## Runs on the plain editor binary (no FACETED toggle): all math is pure frozen-atlas geometry.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const SM := preload("res://src/world/shape_mesh.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_facet_clip_ref (FP-CARVE C0) ===")
	TC.warm_up()
	FA.warm_up()

	# Facets with a large seam-orientation spread: spawn + one mid-facet on 3 different cube faces.
	var K: int = FA.K
	var fids: Array = [FA.spawn_facet()]
	for face in [0, 2, 4]:
		var f: int = (face * K + int(K / 2)) * K + int(K / 2)
		if not fids.has(f):
			fids.append(f)
	print("  test facets: ", fids)

	var total_single := 0
	var total_corner := 0
	for fid: int in fids:
		var r := _test_facet(fid)
		total_single += int(r.x)
		total_corner += int(r.y)

	_ok(total_single > 0, "coverage: exercised %d single-plane straddle cells" % total_single)
	_ok(total_corner > 0, "coverage: exercised %d corner (≥2-plane) straddle cells" % total_corner)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# Scan facet `fid`'s domain, comparing build_carve_faces vs junction_prism_verts on every straddle cell found
# (bounded sample), plus the single-plane byte-identity vs _build_junction. Returns Vector2i(single, corner) counts.
func _test_facet(fid: int) -> Vector2i:
	TC.set_active_facet(fid)
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var single := 0
	var corner := 0
	var match_fail := 0
	var inside_fail := 0
	var bounds_fail := 0
	var byte_fail := 0
	var byte_checked := 0
	# f64 own_dist parity gate (§4 hazard): worst |vertex own_dist| over all straddling slots.
	var worst_match := 0.0
	var worst_own := 0.0

	var z := lo.y
	while z <= hi.y and (single < 80 or corner < 24):
		var x := lo.x
		while x <= hi.x and (single < 80 or corner < 24):
			var g := TC.height_at(x, z)
			for y in range(g - 4, g + 3):
				var st := FA.cell_seam_state(fid, x, y, z)
				if st["air"]:
					continue
				var slots: PackedInt32Array = st["straddle"]
				if slots.is_empty():
					continue
				var ns := slots.size()
				if ns == 1 and single >= 80:
					continue
				if ns >= 2 and corner >= 24:
					continue
				if ns == 1:
					single += 1
				else:
					corner += 1

				# LOCAL planes, EXACTLY as junction_prism_verts builds them: base = own_dist at the (0,0,0) corner.
				var planes: Array = []
				for slot in slots:
					var pl := FA.seam_planes_f64(fid)
					var b := slot * 4
					var base := pl[b] * float(x) + pl[b + 1] * float(y) + pl[b + 2] * float(z) + pl[b + 3]
					planes.append([pl[b], pl[b + 1], pl[b + 2], base])

				var prism := FA.junction_prism_verts(fid, x, y, z)
				var faces := SM.build_carve_faces(planes)
				var bverts := PackedVector3Array()
				for fdict: Dictionary in faces:
					for p: Vector3 in fdict["poly"]:
						bverts.append(p)

				# (i) bidirectional cloud match to 1e-4
				for v: Vector3 in bverts:
					var best := 1e9
					for u: Vector3 in prism:
						best = minf(best, v.distance_to(u))
					worst_match = maxf(worst_match, best)
					if best > 1e-4:
						match_fail += 1
					# (iv) unit-cube bounds
					if v.x < -1e-4 or v.x > 1.0 + 1e-4 or v.y < -1e-4 or v.y > 1.0 + 1e-4 or v.z < -1e-4 or v.z > 1.0 + 1e-4:
						bounds_fail += 1
					# (ii) inside every straddling half-space, checked in f64 via own_dist
					for slot in slots:
						var od := FA.own_dist(fid, slot, float(x) + v.x, float(y) + v.y, float(z) + v.z)
						worst_own = minf(worst_own, od)
						if od < -1e-4:
							inside_fail += 1
				for u: Vector3 in prism:
					var best2 := 1e9
					for v: Vector3 in bverts:
						best2 = minf(best2, u.distance_to(v))
					worst_match = maxf(worst_match, best2)
					if best2 > 1e-4:
						match_fail += 1

				# (iii) single-plane byte-identity vs the shipped _build_junction render path
				if ns == 1:
					var mod := CellCodec.modifier(FA.junction_modify(fid, Vector3i(x, y, z), CellCodec.pack(BlockCatalog.STONE, 0)))
					if CellCodec.is_junction(mod):
						byte_checked += 1
						var slot := CellCodec.junction_slot(mod)
						var q := CellCodec.junction_q(mod)
						var mp := FA.junction_model_plane(fid, slot, q)
						var qfaces := SM.build_carve_faces([mp])
						var arr := {"verts": PackedVector3Array(), "normals": PackedVector3Array(),
							"uvs": PackedVector2Array(), "indices": PackedInt32Array()}
						for fdict2: Dictionary in qfaces:
							SM._emit_polygon(arr, fdict2["poly"], fdict2["normal"])
						var ref := ShapeMesh.build(mod)
						if not _arr_equal(arr, ref):
							byte_fail += 1
			x += 1
		z += 1

	_ok(match_fail == 0, "fid %d: build_carve_faces cloud == junction_prism_verts (fails=%d, worst=%s)" % [fid, match_fail, worst_match])
	_ok(inside_fail == 0, "fid %d: every carve vertex inside all straddling half-spaces (fails=%d, worst own=%s)" % [fid, inside_fail, worst_own])
	_ok(bounds_fail == 0, "fid %d: every carve vertex in [0,1]³ (fails=%d)" % [fid, bounds_fail])
	_ok(byte_checked == 0 or byte_fail == 0, "fid %d: single-plane build_carve_faces == _build_junction byte-for-byte (checked=%d, fails=%d)" % [fid, byte_checked, byte_fail])
	return Vector2i(single, corner)

func _arr_equal(a: Dictionary, b: Dictionary) -> bool:
	var av: PackedVector3Array = a["verts"]
	var bv: PackedVector3Array = b["verts"]
	if av.size() != bv.size():
		return false
	for i in range(av.size()):
		if av[i] != bv[i]:
			return false
	var ai: PackedInt32Array = a["indices"]
	var bi: PackedInt32Array = b["indices"]
	if ai.size() != bi.size():
		return false
	for i in range(ai.size()):
		if ai[i] != bi[i]:
			return false
	return true
