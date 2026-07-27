extends SceneTree
## G-BT-* — FP_BLOCKY_TEX (COSMOS TEXTURED-LOD T1): the blocky far ring carries the FP_FACET_TEX satellite-page node-param
## UVs so the mega-blocks are painted with the downscaled real-block-surface image instead of one flat corner colour.
## Flag-INDEPENDENT — drives _emit_blocky directly on real facet caches (like verify_blocky_farring.gd), forcing tex on/off
## via the function's own `tex` argument so no flag flip is needed. Asserts:
##   G-BT-OFF    — _emit_blocky(...,tex=false) is bit-identical to today's blocky (NO ARRAY_TEX_UV / ARRAY_TEX_UV2).
##   G-BT-UV     — _emit_blocky(...,tex=true): every vertex carries a UV equal to a smooth-path node-param UV of the facet
##                 ((a+ni/cells)/K,(b+nj/cells)/K) (so walls INHERIT top-edge UVs — walls use only corner nodes); UVs in
##                 [0,1]; UV2 == (face, slot) for every vert; UV/UV2 counts == vertex count.
##   G-BT-NOPROT — tex on ⇒ vertex POSITIONS bit-identical to tex off (UVs never move a vertex — no-protrusion unchanged).
##   G-BT-BYTES  — the added arrays are bounded (UV+UV2 counts == vert count, 2+2 floats/vert) and ZERO textures are
##                 allocated by the emit (it reuses the FP_FACET_TEX pages — nothing here creates a Texture).
## Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

func _initialize() -> void:
	print("=== verify_blocky_tex (G-BT: FP_BLOCKY_TEX) ===")
	FacetAtlas.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED"); print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return
	var ring := FacetFarRing.new()
	var cells: int = ring.CELLS
	var stride := cells + 1
	var fids := [0, 37, 300, 1200, 2500, 3455]
	var kf := float(FacetAtlas.K)

	for fid in fids:
		ring._ensure_cached(fid)
		var pos: PackedVector3Array = ring._pos_cache[fid]
		var col: PackedColorArray = ring._col_cache[fid]

		# --- tex OFF emit (the shipped blocky) ---
		var st_off := SurfaceTool.new()
		st_off.begin(Mesh.PRIMITIVE_TRIANGLES)
		var n_off: int = ring._emit_blocky(st_off, pos, col, cells, stride)          # tex defaults false
		var arr_off := st_off.commit_to_arrays()
		var v_off: PackedVector3Array = arr_off[Mesh.ARRAY_VERTEX]

		# --- tex ON emit (forced, flag-independent) ---
		var st_on := SurfaceTool.new()
		st_on.begin(Mesh.PRIMITIVE_TRIANGLES)
		var n_on: int = ring._emit_blocky(st_on, pos, col, cells, stride, fid, true)
		var arr_on := st_on.commit_to_arrays()
		var v_on: PackedVector3Array = arr_on[Mesh.ARRAY_VERTEX]
		var uv_on = arr_on[Mesh.ARRAY_TEX_UV]
		var uv2_on = arr_on[Mesh.ARRAY_TEX_UV2]

		# G-BT-OFF: no UV channels off; identical tri count & vertex positions on/off (geometry unchanged by the flag).
		var off_no_uv: bool = (arr_off[Mesh.ARRAY_TEX_UV] == null) and (arr_off[Mesh.ARRAY_TEX_UV2] == null)
		_ok(off_no_uv, "G-BT-OFF fid %d: tex-off emit has NO UV / UV2 arrays" % fid)
		_ok(n_off == n_on, "G-BT-OFF fid %d: tri count identical on/off (%d)" % [fid, n_off])

		# G-BT-NOPROT: vertex positions bit-identical on/off (UVs move nothing).
		var same_pos := v_off.size() == v_on.size()
		var worst_dr := 0.0
		if same_pos:
			for i in range(v_off.size()):
				worst_dr = maxf(worst_dr, (v_off[i] - v_on[i]).length())
		same_pos = same_pos and worst_dr == 0.0
		_ok(same_pos, "G-BT-NOPROT fid %d: vertex positions bit-identical on/off (worst Δ %.6f)" % [fid, worst_dr])

		# G-BT-BYTES / count: UV & UV2 arrays present, one per vertex (bounded ~+4 floats/vert, ZERO textures).
		var uv_ok: bool = uv_on != null and uv2_on != null and uv_on.size() == v_on.size() and uv2_on.size() == v_on.size()
		_ok(uv_ok, "G-BT-BYTES fid %d: UV(%d)+UV2(%d) counts == verts(%d)" % [fid,
			(uv_on.size() if uv_on != null else -1), (uv2_on.size() if uv2_on != null else -1), v_on.size()])

		# G-BT-UV: every UV equals a facet node-param UV (⇒ walls inherit top-edge node UVs); UVs in [0,1]; UV2 == (face,slot).
		var d := ring._tex_decode(fid)
		var face := float(d[0])
		var ta := int(d[1]); var tb := int(d[2]); var kb := int(d[3])
		var slot: float = ring._slot_of(fid)
		# valid node-param UV set: ((ta + ni/cells)/kb, (tb + nj/cells)/kb) for ni,nj in 0..cells.
		var valid := {}
		for nj in range(cells + 1):
			for ni in range(cells + 1):
				var u := (float(ta) + float(ni) / float(cells)) / float(kb)
				var v := (float(tb) + float(nj) / float(cells)) / float(kb)
				valid[_key(u, v)] = true
		var bad_uv := 0
		var out_range := 0
		if uv_ok:
			for uu in uv_on:
				if uu.x < -1e-5 or uu.x > 1.0 + 1e-5 or uu.y < -1e-5 or uu.y > 1.0 + 1e-5:
					out_range += 1
				if not valid.has(_key(uu.x, uu.y)):
					bad_uv += 1
		_ok(bad_uv == 0, "G-BT-UV fid %d: every UV == a smooth node-param UV (%d off-grid)" % [fid, bad_uv])
		_ok(out_range == 0, "G-BT-UV fid %d: every UV in [0,1] (%d out of range)" % [fid, out_range])
		var uv2_bad := 0
		if uv_ok:
			for w in uv2_on:
				if absf(w.x - face) > 1e-5 or absf(w.y - slot) > 1e-5:
					uv2_bad += 1
		_ok(uv2_bad == 0, "G-BT-UV fid %d: every UV2 == (face %d, slot %d) (%d wrong)" % [fid, int(face), int(slot), uv2_bad])

	ring.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Quantize a UV to a stable key (facet grid params are exact ratios; 1e-4 tolerance absorbs f32 rounding).
func _key(u: float, v: float) -> String:
	return "%d:%d" % [int(round(u * 1e4)), int(round(v * 1e4))]
