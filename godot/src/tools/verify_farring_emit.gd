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

	# ==== P2 (FP_FARRING_SECTORS / G-FR-SECT) ====

	# --- E: the static partition is total and stable — every fid maps to exactly one sector in [0, ns).
	var ns: int = ring._sector_count()
	var bad := 0
	for fid in range(FacetAtlas.K * FacetAtlas.K * 6):
		var s: int = ring._sector_of(fid)
		if s < 0 or s >= ns:
			bad += 1
		if ring._sector_of(fid) != s:
			bad += 1   # pure function — identical on re-query
	_ok(bad == 0, "E partition: all %d fids map to exactly one sector in [0,%d)" % [FacetAtlas.K * FacetAtlas.K * 6, ns])

	# --- F: sectored worker + swap E2E — the UNION of the sector meshes is vertex/colour-multiset-identical to the
	# single whole-cap emit (coverage: no gap, no overlap, no double-emit; borders weld EXACTLY — same welded caches).
	ring._mi = MeshInstance3D.new()
	ring.add_child(ring._mi)
	ring._async_fids = PackedInt32Array(fids)
	ring._async_backstop = {}
	ring._async_mid = {}
	ring._async_v2_resident = {}
	ring._async_env_warm = false
	ring._async_chord_only = false
	ring._async_warm_only = false
	ring._async_sectored = true
	ring._async_sector_parts = {}
	ring._async_sector_arrays = {}
	ring._sectors_compute_dirty()
	var populated := {}
	for fid in fids:
		populated[ring._sector_of(fid)] = true
	_ok(ring._async_sector_dirty.size() == populated.size(), "F first sectored build: every populated sector dirty (%d)"
		% ring._async_sector_dirty.size())
	_ok(populated.size() >= 2, "F fid spread spans >= 2 sectors (%d)" % populated.size())
	ring._async_build_worker()
	ring._swap_in_sectors()
	var st_ref := SurfaceTool.new()
	st_ref.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in fids:
		ring._emit_cached(st_ref, fid, false)
	st_ref.generate_normals()
	# The committed single-cap surface ROUND-TRIPS through add_surface_from_arrays (colour/normal quantization) in
	# _swap_in_arrays — round-trip the reference identically so the comparison is render-path vs render-path.
	var ref := _mesh_roundtrip(st_ref.commit_to_arrays())
	var uni: Array = ring.mesh_arrays()
	_ok(not uni.is_empty(), "F union: sector meshes committed")
	if not uni.is_empty():
		var rv: PackedVector3Array = ref[Mesh.ARRAY_VERTEX]
		var uv: PackedVector3Array = uni[Mesh.ARRAY_VERTEX]
		_ok(uv.size() == rv.size(), "F union vert count == single-mesh count (%d)" % rv.size())
		_ok(_pc_multiset(uni) == _pc_multiset(ref), "F/G union (pos,colour) MULTISET == single mesh — no gap/overlap, borders weld exactly")
	var drawn_union := 0
	for fid in fids:
		if ring._emitted.has(fid):
			drawn_union += 1
	_ok(drawn_union == fids.size(), "F _emitted union covers the full frozen set (%d)" % drawn_union)

	# --- H: dirty selectivity — an unchanged pass re-emits NOTHING; a single-facet change re-emits EXACTLY one sector.
	ring._sectors_compute_dirty()
	_ok(ring._async_sector_dirty.is_empty(), "H unchanged pass: zero dirty sectors")
	ring._benv_done[1200] = true   # single-facet cache-upgrade class flip
	ring._sectors_compute_dirty()
	_ok(ring._async_sector_dirty.size() == 1 and ring._async_sector_dirty.has(ring._sector_of(1200)),
		"H single-facet change dirties EXACTLY its one sector (%d)" % ring._sector_of(1200))
	ring._benv_done.erase(1200)
	var fids2: Array = fids.duplicate()
	fids2.erase(300)
	ring._async_fids = PackedInt32Array(fids2)
	ring._sectors_compute_dirty()
	_ok(ring._async_sector_dirty.size() == 1 and ring._async_sector_dirty.has(ring._sector_of(300)),
		"H single-facet membership drop dirties EXACTLY its one sector (%d)" % ring._sector_of(300))
	# incremental swap: only that sector's mesh object changes; the dropped facet leaves the union and _emitted.
	var keep_meshes := {}
	for s in range(ns):
		if ring._sector_mi[s] != null:
			keep_meshes[s] = (ring._sector_mi[s] as MeshInstance3D).mesh
	ring._async_sector_parts = {}
	ring._async_sector_arrays = {}
	ring._async_build_worker()
	ring._swap_in_sectors()
	var untouched := true
	for s in range(ns):
		if s == ring._sector_of(300):
			continue
		if keep_meshes.has(s) and ring._sector_mi[s] != null \
				and (ring._sector_mi[s] as MeshInstance3D).mesh != keep_meshes[s]:
			untouched = false
	_ok(untouched, "H incremental swap: every clean sector keeps its RESIDENT mesh object")
	var s300: int = ring._sector_of(300)
	var m300: ArrayMesh = (ring._sector_mi[s300] as MeshInstance3D).mesh
	_ok(m300.get_surface_count() == 0, "H dropped facet's sector mesh cleared (no members left)")
	_ok(not ring._emitted.has(300) and ring._emitted.size() == fids2.size(), "H _emitted union tracks the drop (%d)"
		% ring._emitted.size())
	var uni2: Array = ring.mesh_arrays()
	var st_ref2 := SurfaceTool.new()
	st_ref2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in fids2:
		ring._emit_cached(st_ref2, fid, false)
	st_ref2.generate_normals()
	var ref2 := _mesh_roundtrip(st_ref2.commit_to_arrays())
	_ok(_pc_multiset(uni2) == _pc_multiset(ref2), "H post-incremental union multiset == single mesh of the reduced set")

	ring.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## The GPU-surface round trip the render path applies to every committed cap (colour/normal quantization).
func _mesh_roundtrip(arrays: Array) -> Array:
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m.surface_get_arrays(0)

## (pos, colour) occurrence-count multiset of a committed surface — order-independent geometric identity.
func _pc_multiset(arr: Array) -> Dictionary:
	var d := {}
	var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var cv: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	for i in range(pv.size()):
		var key := [pv[i], cv[i]]
		d[key] = d.get(key, 0) + 1
	return d
