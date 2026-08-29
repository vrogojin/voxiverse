extends SceneTree
## G-FR-BULK — FP_FARRING_BULK_EMIT (COSMOS FARRING-SWAP-DIET P3): the async worker's bulk (preallocated packed-array)
## emit must produce the BYTE-IDENTICAL committed surface as the shipped per-vertex SurfaceTool emit — same vertices,
## colors, uvs, uv2s in the same order AND the same globally-smoothed normals (generate_normals' cross-facet vertex-hash
## smoothing included, via the pure-CPU SurfaceTool.create_from_arrays round trip). Flag-INDEPENDENT (drives the twin
## emit functions directly on real facet caches, like verify_blocky_farring). Byte-off (flag false) is covered by
## verify_feature (FLAT 6042/0). Exits 0 all-pass, 1 on any failure.
##
## COSMOS DE-ORBIT SLICE SMOOTHING (docs/COSMOS-DEORBIT-SLICE-SMOOTHING-DESIGN.md): also proves G-FR-ACCUM
## (FP_FARRING_EMIT_ACCUM — the in-place accumulator emits BYTE-IDENTICAL committed surfaces to the parts path; forced
## via the `accum` emit param, flag-independent) and G-FR-FINE (FP_SHELL_SECTOR_FINE — the partition scales with the
## compiled `_sector_split()`: exhaustive fid→one-sector, (K/split)² membership bound, cross-sector seam weld).
## RUN needs FACETED; ALSO run once with FP_SHELL_SECTOR_FINE sedded on to exercise the 96-sector (split-4) partition:
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_SHELL_SECTOR_FINE := false/const FP_SHELL_SECTOR_FINE := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import   # then run the script; REVERT + re-import after.

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

## Path C for the same set: the ACCUMULATOR twin (in-place base-offset fill) + _accum_finalize.
func _blocky_accum(ring: FacetFarRing, fids: Array, sunk: Dictionary, tex: bool) -> Array:
	var acc: Array = [PackedVector3Array(), PackedColorArray(), PackedVector2Array(), PackedVector2Array()]
	for fid in fids:
		var pos: PackedVector3Array = ring._bpos_cache[fid] if sunk.get(fid, false) else ring._pos_cache[fid]
		var col: PackedColorArray = ring._bcol_cache[fid] if sunk.get(fid, false) else ring._col_cache[fid]
		var cells: int = CubeSphere.BACKSTOP_CELLS if sunk.get(fid, false) else ring.CELLS
		ring._emit_blocky_bulk(acc, pos, col, cells, cells + 1, fid, tex, true)
	return ring._accum_finalize(acc)

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

	# ==== G-FR-ACCUM (FP_FARRING_EMIT_ACCUM): the per-sector accumulator (base-offset in-place fill + _accum_finalize)
	# produces the BYTE-IDENTICAL committed surface as the parts path (_emit_*_bulk + _bulk_assemble). Flag-INDEPENDENT
	# — the emit twins take `accum` as a forced param, so both paths run in ONE process (the G-FR-BULK equality, one flag
	# deeper). This is one of the two correctness lynchpins of the slice-smoothing PR. ====

	# GA: blocky tex-off — parts vs accumulator, whole-set (incl. cross-facet normals via the identical finalize tail).
	var ga_parts := _blocky_bulk(ring, fids, sunk, false)
	var ga_accum := _blocky_accum(ring, fids, sunk, false)
	_ok(ga_parts == ga_accum, "GA accum blocky tex-off: committed arrays BYTE-IDENTICAL to parts (%d verts)"
		% (ga_parts[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	_ok(_normal_dev(ga_parts, ga_accum) <= 1.0e-9, "GA accum blocky tex-off: normals bit-equal (dev %.12f)" % _normal_dev(ga_parts, ga_accum))

	# GB: blocky tex-on — the uv/uv2 accumulator slots.
	var gb_parts := _blocky_bulk(ring, fids, sunk, true)
	var gb_accum := _blocky_accum(ring, fids, sunk, true)
	_ok(gb_parts == gb_accum, "GB accum blocky tex-on: committed arrays BYTE-IDENTICAL to parts (%d verts)"
		% (gb_parts[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	_ok((gb_accum[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() > 0, "GB accum blocky tex-on: UVs present")

	# GC: the SMOOTH path through _emit_cached itself — parts (bulk arg) vs accumulator (bulk arg + accum=true), mixed
	# coarse+sunk. Proves the `accum` param threads through _emit_cached → _emit_smooth_bulk unchanged for the served config.
	var gc_parts: Array = []
	for fid in fids:
		ring._emit_cached(null, fid, sunk.get(fid, false), true, CubeSphere.FP_FARRING_UNCOVERED_TRUE, gc_parts)
	var gc_a := ring._bulk_assemble(gc_parts)
	var gc_acc: Array = [PackedVector3Array(), PackedColorArray(), PackedVector2Array(), PackedVector2Array()]
	for fid in fids:
		ring._emit_cached(null, fid, sunk.get(fid, false), true, CubeSphere.FP_FARRING_UNCOVERED_TRUE, gc_acc, true)
	var gc_b := ring._accum_finalize(gc_acc)
	_ok(gc_a == gc_b, "GC accum smooth via _emit_cached (mixed coarse+sunk): committed arrays BYTE-IDENTICAL (%d verts)"
		% (gc_a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	_ok(_normal_dev(gc_a, gc_b) <= 1.0e-9, "GC accum smooth: normals bit-equal (dev %.12f)" % _normal_dev(gc_a, gc_b))

	# GD: empty accumulator finalize — null AND an all-empty quad must both yield the same ARRAY_MAX-shaped, 0-vert block
	# as _bulk_assemble([]) (the _swap_in_arrays size-guard equivalence, one path deeper).
	var gd_null := ring._accum_finalize(null)
	var gd_empty := ring._accum_finalize([PackedVector3Array(), PackedColorArray(), PackedVector2Array(), PackedVector2Array()])
	var gdnv: PackedVector3Array = gd_null[Mesh.ARRAY_VERTEX]
	var gdev: PackedVector3Array = gd_empty[Mesh.ARRAY_VERTEX]
	_ok(gd_null.size() == Mesh.ARRAY_MAX and gdnv.size() == 0 and gd_empty.size() == Mesh.ARRAY_MAX and gdev.size() == 0,
		"GD accum finalize null/empty: both ARRAY_MAX-shaped, 0 verts (guard-equivalent to _bulk_assemble([]))")

	# ==== G-FR-FINE (FP_SHELL_SECTOR_FINE): the partition scales to the compiled split (2 → 24 sectors ≤144 fids each;
	# 4 → 96 sectors ≤36 each). Run this gate ALSO with FP_SHELL_SECTOR_FINE sedded on to exercise the 96 partition. ====
	var sp: int = ring._sector_split()
	var nsF: int = ring._sector_count()
	var per_face_max := (FacetAtlas.K / sp) * (FacetAtlas.K / sp)   # (K/sp)² — the max sector membership by arithmetic
	_ok(nsF == 6 * sp * sp, "G-FR-FINE: _sector_count == 6·split² (split=%d ⇒ %d sectors)" % [sp, nsF])
	# exhaustive partition: every fid → exactly one sector in [0, ns); per-sector membership; max == (K/sp)² (no ragged/fat edge).
	var member := {}
	var bad_fine := 0
	for fid in range(FacetAtlas.K * FacetAtlas.K * 6):
		var s: int = ring._sector_of(fid)
		if s < 0 or s >= nsF or ring._sector_of(fid) != s:
			bad_fine += 1
		member[s] = int(member.get(s, 0)) + 1
	var max_member := 0
	var min_member := 1 << 30
	for s in member.keys():
		max_member = maxi(max_member, int(member[s]))
		min_member = mini(min_member, int(member[s]))
	_ok(bad_fine == 0, "G-FR-FINE: exhaustive fid→exactly-one-sector in [0,%d), pure (bad=%d)" % [nsF, bad_fine])
	_ok(max_member == per_face_max and max_member <= per_face_max,
		"G-FR-FINE: max sector membership == (K/%d)² == %d (≤ the per-slice bound; no clamp-induced fat edge)" % [sp, per_face_max])
	_ok(member.size() == nsF and min_member == per_face_max,
		"G-FR-FINE: the partition is EXACT — all %d sectors populated with %d fids each (K divides split)" % [nsF, per_face_max])

	# G-FR-FINE seam continuity (the OTHER correctness lynchpin, mechanises §5.2 the way the far ring actually welds):
	# the far-ring facets ABUT (they do not share bitwise vertices — a per-facet grid), so the seam guarantee is that the
	# sector partition is GEOMETRY-INVARIANT — a facet emits the identical vertices no matter which sector collects it, so
	# more sectors introduce NO new gap/overlap/duplicate. An adjacent facet pair straddling the FIRST sector boundary of
	# the compiled split lands in DIFFERENT sectors; driving the REAL sectored worker+swap on JUST that pair and comparing
	# the 2-sector union to the single-cap emit proves the sector boundary between two touching facets welds exactly.
	var k := FacetAtlas.K
	var half := int(k / sp)
	var bb := 3
	var f1 := (0 * k + (half - 1)) * k + bb
	var f2 := (0 * k + half) * k + bb
	var sf1: int = ring._sector_of(f1)
	var sf2: int = ring._sector_of(f2)
	_ok(sf1 != sf2, "G-FR-FINE seam: adjacent facets %d/%d straddle a sector border at split %d (sectors %d≠%d)" % [f1, f2, sp, sf1, sf2])
	var sring := FacetFarRing.new()
	sring._mi = MeshInstance3D.new()
	sring.add_child(sring._mi)
	sring._ensure_cached(f1)
	sring._ensure_cached(f2)
	sring._async_fids = PackedInt32Array([f1, f2])
	sring._async_backstop = {}
	sring._async_mid = {}
	sring._async_v2_resident = {}
	sring._async_env_warm = false
	sring._async_chord_only = false
	sring._async_warm_only = false
	sring._async_sectored = true
	sring._async_sector_parts = {}
	sring._async_sector_arrays = {}
	sring._sectors_compute_dirty()
	var seam_dirty: int = (sring._async_sector_dirty as Dictionary).size()
	sring._async_build_worker()
	sring._swap_in_sectors()
	var seam_uni: Array = sring.mesh_arrays()
	var seam_ref_st := SurfaceTool.new()
	seam_ref_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in [f1, f2]:
		sring._emit_cached(seam_ref_st, f, false)
	seam_ref_st.generate_normals()
	var seam_ref := _mesh_roundtrip(seam_ref_st.commit_to_arrays())
	_ok(seam_dirty == 2 and not seam_uni.is_empty() and _pc_multiset(seam_uni) == _pc_multiset(seam_ref),
		"G-FR-FINE seam: the cross-sector pair splits into %d sectors and its union == the single-cap emit — no gap/overlap/dup at the border (weld holds at split %d)" % [seam_dirty, sp])
	sring.free()

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
