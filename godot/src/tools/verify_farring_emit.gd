extends SceneTree
## G-FR-BULK — FP_FARRING_BULK_EMIT (COSMOS FARRING-SWAP-DIET P3): the async worker's bulk (preallocated packed-array)
## emit must produce the BYTE-IDENTICAL committed surface as the shipped per-vertex SurfaceTool emit — same vertices,
## colors, uvs, uv2s in the same order AND the same globally-smoothed normals (generate_normals' cross-facet vertex-hash
## smoothing included, via the pure-CPU SurfaceTool.create_from_arrays round trip). Flag-INDEPENDENT (drives the twin
## emit functions directly on real facet caches, like verify_blocky_farring). Byte-off (flag false) is covered by
## verify_feature (FLAT 6042/0). Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

## Path A for a set of blocky facet emits: the shipped SurfaceTool pipeline.
func _blocky_surfacetool(ring: FacetFarRing, fids: Array, sunk: Dictionary, tex: bool) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in fids:
		var pos: PackedVector3Array = ring._bpos_cache[fid] if sunk.get(fid, false) else ring._pos_cache[fid]
		var col: PackedColorArray = ring._bcol_cache[fid] if sunk.get(fid, false) else ring._col_cache[fid]
		var cells: int = CubeSphere.BACKSTOP_CELLS if sunk.get(fid, false) else ring.CELLS
		ring._emit_blocky(st, pos, col, cells, cells + 1, fid, tex)
	st.generate_normals()
	return st.commit_to_arrays()

## Path B for the same set: the bulk twin + _bulk_assemble.
func _blocky_bulk(ring: FacetFarRing, fids: Array, sunk: Dictionary, tex: bool) -> Array:
	var parts: Array = []
	for fid in fids:
		var pos: PackedVector3Array = ring._bpos_cache[fid] if sunk.get(fid, false) else ring._pos_cache[fid]
		var col: PackedColorArray = ring._bcol_cache[fid] if sunk.get(fid, false) else ring._col_cache[fid]
		var cells: int = CubeSphere.BACKSTOP_CELLS if sunk.get(fid, false) else ring.CELLS
		ring._emit_blocky_bulk(parts, pos, col, cells, cells + 1, fid, tex)
	return ring._bulk_assemble(parts)

## Max per-component normal deviation between two committed arrays (both must have normals).
func _normal_dev(a: Array, b: Array) -> float:
	var na: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var nb: PackedVector3Array = b[Mesh.ARRAY_NORMAL]
	if na.size() != nb.size():
		return 1.0e9
	var worst := 0.0
	for i in range(na.size()):
		worst = maxf(worst, (na[i] - nb[i]).length())
	return worst

func _initialize() -> void:
	print("=== verify_farring_emit (G-FR-BULK: FP_FARRING_BULK_EMIT byte-equality) ===")
	FacetAtlas.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED"); print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return
	var ring := FacetFarRing.new()
	# The verify_blocky_farring facet spread (equator, mid-lat, pole, varied relief) + dense backstop caches for two.
	var fids := [0, 37, 300, 1200, 2500, 3455]
	var dense_fids := [37, 1200]
	for fid in fids:
		ring._ensure_cached(fid)
	var sunk := {}
	for fid in dense_fids:
		ring._ensure_backstop_cached(fid)
		sunk[fid] = true

	# --- A: blocky (the served FP_BLOCKY_FARRING config), tex off — whole-set compare incl. cross-facet normals.
	var t0 := Time.get_ticks_usec()
	var a1 := _blocky_surfacetool(ring, fids, sunk, false)
	var t_st := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var b1 := _blocky_bulk(ring, fids, sunk, false)
	var t_bk := Time.get_ticks_usec() - t0
	_ok(a1 == b1, "A blocky tex-off: committed arrays BYTE-IDENTICAL (%d verts; st %d us vs bulk %d us)"
		% [(a1[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), t_st, t_bk])
	_ok(_normal_dev(a1, b1) <= 1.0e-6, "A blocky tex-off: normals within eps (dev %.9f)" % _normal_dev(a1, b1))

	# --- B: blocky, tex on (FP_BLOCKY_TEX ∧ _tex_on() served config — uv/uv2 carried).
	var a2 := _blocky_surfacetool(ring, fids, sunk, true)
	var b2 := _blocky_bulk(ring, fids, sunk, true)
	_ok(a2 == b2, "B blocky tex-on: committed arrays BYTE-IDENTICAL (%d verts)"
		% (a2[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	_ok((a2[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() > 0, "B blocky tex-on: UVs present")
	_ok(_normal_dev(a2, b2) <= 1.0e-6, "B blocky tex-on: normals within eps (dev %.9f)" % _normal_dev(a2, b2))

	# --- C: the SMOOTH emit stage through _emit_cached itself (repo consts: FP_BLOCKY_FARRING off ⇒ smooth path),
	# mixed coarse + sunk-dense facets in one build — proves the shared selection + _emit_smooth_bulk + global normals.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris_a := 0
	for fid in fids:
		tris_a += ring._emit_cached(st, fid, sunk.get(fid, false), true)
	st.generate_normals()
	var a3 := st.commit_to_arrays()
	var parts: Array = []
	var tris_b := 0
	for fid in fids:
		tris_b += ring._emit_cached(null, fid, sunk.get(fid, false), true, CubeSphere.FP_FARRING_UNCOVERED_TRUE, parts)
	var b3 := ring._bulk_assemble(parts)
	_ok(tris_a == tris_b, "C smooth: triangle counts equal (%d)" % tris_a)
	_ok(a3 == b3, "C smooth via _emit_cached (mixed coarse+sunk): committed arrays BYTE-IDENTICAL (%d verts)"
		% (a3[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	_ok(_normal_dev(a3, b3) <= 1.0e-6, "C smooth: normals within eps (dev %.9f)" % _normal_dev(a3, b3))

	# --- D: empty build — _bulk_assemble([]) must fall through _swap_in_arrays' size guard exactly like the
	# SurfaceTool path (ARRAY_MAX-shaped, zero-size vertex array ⇒ same empty ArrayMesh).
	var e := ring._bulk_assemble([])
	var ev: PackedVector3Array = e[Mesh.ARRAY_VERTEX]
	_ok(e.size() == Mesh.ARRAY_MAX and ev.size() == 0, "D empty parts: ARRAY_MAX-shaped, 0 verts (guard-equivalent)")

	ring.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
