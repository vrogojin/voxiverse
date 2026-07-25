extends SceneTree
## G-BLK-RING — FP_BLOCKY_FARRING (Block-LOD phase 1): the far ring emits flat-topped BLOCKS instead of the smooth
## welded surface. Asserts (flag-INDEPENDENT — drives _emit_blocky directly on real facet caches, like the other
## far-ring gates): (A) NO-PROTRUSION — every blocky vertex radius <= the max smooth-grid radius (the block top is the
## corner MIN, so it never pokes above the already-gated smooth surface); (B) WATERTIGHT/BOUNDED — the emit produces
## real triangles (walls close steps), vert count within a sane multiple of the smooth baseline; (C) NO NaN.
## Byte-off (flag false) is covered by verify_feature (FLAT 6042/0). Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

func _initialize() -> void:
	print("=== verify_blocky_farring (G-BLK-RING: FP_BLOCKY_FARRING) ===")
	FacetAtlas.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED"); print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return
	var ring := FacetFarRing.new()
	var cells: int = ring.CELLS
	var stride := cells + 1
	# A spread of facets incl. varied relief (equator, mid-lat, pole) so a mountain/valley cell is covered (the DH
	# "cave x-ray" concave-terrain check FableLOD-2 flagged).
	var fids := [0, 37, 300, 1200, 2500, 3455]
	var worst_above := 0.0
	var min_tri := 1 << 30
	var nan := false
	for fid in fids:
		ring._ensure_cached(fid)
		var pos: PackedVector3Array = ring._pos_cache[fid]
		var col: PackedColorArray = ring._col_cache[fid]
		# smooth surface bound = the max radius of the cached grid (the blocky top MINs the corners ⇒ ≤ this).
		var smooth_max := 0.0
		for p in pos:
			smooth_max = maxf(smooth_max, p.length())
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var ntri: int = ring._emit_blocky(st, pos, col, cells, stride)
		st.generate_normals()
		var arr := st.commit_to_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		min_tri = mini(min_tri, ntri)
		for v in verts:
			var r := v.length()
			if is_nan(r): nan = true
			# A: blocky vertex never ABOVE the smooth surface (tiny f32 slack).
			worst_above = maxf(worst_above, r - smooth_max)
		# B: real geometry — tri count ≥ the flat-top baseline (2/cell) and ≤ a sane bound (tops + ≤4 walls/cell).
		_ok(ntri >= 2 * cells * cells, "B fid %d: >= flat-top baseline (%d tris)" % [fid, ntri])
		_ok(ntri <= 10 * cells * cells, "B fid %d: <= tops+walls bound (%d tris ≤ %d)" % [fid, ntri, 10 * cells * cells])
	_ok(worst_above <= 0.05, "A no blocky vertex above the smooth surface (worst +%.4f blk) — no-protrusion a fortiori" % worst_above)
	_ok(not nan, "C no NaN vertex")
	ring.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
