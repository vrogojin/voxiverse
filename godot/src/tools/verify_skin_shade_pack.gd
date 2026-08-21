extends SceneTree
## G-SSP — FP_SKIN_SHADE_PACK gate (docs/COSMOS-SKIN-SHADE-PACK, Defect 3 near↔far brightness step).
##
## Proves the C++ bake_far_tile packed byte (patch 0014) DECODED reproduces the GDScript truth —
## SurfaceShot._shade quantised by SurfaceShot.shade_q — and that the flag off is byte-identical:
##   G-SSP-OFF     flag-off generator ⇒ every byte == idx + 1 (≤ 14), byte-equal to the GDScript idx-only
##                 reference; _apply_shade_pack(code, false) / shader_code(false) return VERBATIM strings.
##   G-SSP-PACK    flag-on generator over N ≥ 256 columns × {band-like, fine-like} tile shapes: packed byte
##                 == 1 + idx + 14·shade_q(SurfaceShot._shade), idx preserved ((b−1) % 14 == flag-off idx),
##                 b ≤ 252 always. This IS the C++↔GDScript byte-equality for the packed byte (the reference
##                 bytes are computed in pure GDScript).
##   G-SSP-EDIT    the EDIT branch packs too (edit idx preserved + shade carried).
##   G-SSP-SPREAD  non-vacuous: ≥ 3 distinct shade_q values and ≥ 1 tree column in the sample.
##   G-SSP-SHADER  flag-on shader strings carry the packed decode; flag-off strings are untouched.
## Requires the rebuilt engine (patch 0014). Exits 0 all-pass, 1 on any failure.

func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)

func _corners(fid: int) -> PackedVector2Array:
	var lc := PackedVector2Array(); lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	return lc

## THE reference packed byte for column (lx,lz) carrying far idx `fi` — the pure-GDScript law the C++ bake
## must reproduce (mirrors FacetTexBaker._sp_pack / the 0014 pack: centre g via facet_profile, is_tree via
## TreeGen.top_decoration, shade via SurfaceShot._shade, quantised by SurfaceShot.shade_q).
func _pack_ref(fi: int, fid: int, lx: int, lz: int, ctx) -> int:
	if fi < 0 or fi >= CubeSphere.SHADE_PACK_LANES:
		return fi + 1
	var g := int(TerrainConfig.facet_profile(fid, lx, lz).x)
	var is_tree := TreeGen.top_decoration(lx, lz, ctx) != BlockCatalog.AIR
	var s := SurfaceShot._shade(fid, lx, lz, g, is_tree, g < TerrainConfig.SEA_LEVEL, ctx)
	return 1 + fi + CubeSphere.SHADE_PACK_LANES * SurfaceShot.shade_q(s)

func _init() -> void:
	var fails := 0
	var checks := 0
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("G-SSP: SKIP — needs FACETED + FLAT_WORLD."); quit(0); return
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	FarPalette.ensure_far_index_ready()
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()

	# ---- G-SSP-SHADER: string-level A/B (runs even without the module) --------------------------------------------
	var pg := CubeSphere.PLANET_MAP_QUAD * CubeSphere.PLANET_MAP_TEXELS
	var probes := [
		FacetFarRing._FLAT_ALBEDO % CubeSphere.BAND_LAYERS,
		FacetFarRing._FLAT_ALBEDO_META,
		FacetFarRing._FLAT_ALBEDO_META_FINE % [pg, pg - 1],
	]
	var decode_mark := "% " + str(CubeSphere.SHADE_PACK_LANES) + "]"   # the packed decode's `far_lut[_xp % 14]` indexing
	var shader_ok := true
	for pc in probes:
		checks += 1
		if FacetFarRing._apply_shade_pack(pc, false) != pc:
			shader_ok = false
			fails += 1
			print("  G-SSP-SHADER FAIL — _apply_shade_pack(code, false) is NOT verbatim (byte-off broken)")
		checks += 1
		var on: String = FacetFarRing._apply_shade_pack(pc, true)
		if on == pc or on.find(decode_mark) == -1:
			shader_ok = false
			fails += 1
			print("  G-SSP-SHADER FAIL — _apply_shade_pack(code, true) lacks the packed decode:\n%s" % on)
	checks += 1
	if FacetOrbitRelief.shader_code(false).find("far_lut[_f8 - 1]") == -1 or FacetOrbitRelief.shader_code(false).find(decode_mark) != -1:
		shader_ok = false
		fails += 1
		print("  G-SSP-SHADER FAIL — orbit-relief shader_code(false) is NOT the legacy decode (byte-off broken)")
	checks += 1
	if FacetOrbitRelief.shader_code(true).find(decode_mark) == -1:
		shader_ok = false
		fails += 1
		print("  G-SSP-SHADER FAIL — orbit-relief shader_code(true) lacks the packed decode")
	if shader_ok:
		print("  G-SSP-SHADER PASS — decode spliced on, verbatim off (band + meta + fine + orbit-relief)")

	# ---- generators: flag-off (default material_tables) and flag-on (gate override) --------------------------------
	var gen_off: Object = FacetSkinTier._build_cpp_gen(0)
	if gen_off == null:
		print("G-SSP: %s — VoxelGeneratorCosmos absent (module not compiled in); C++ checks skipped." %
			("FAIL" if fails > 0 else "SKIP"))
		quit(1 if fails > 0 else 0); return
	if not gen_off.has_method("bake_far_tile"):
		print("G-SSP: FAIL — engine has the module but NOT bake_far_tile(). Rebuild with patches 0011+.")
		quit(1); return
	var gen_on: Object = FacetSkinTier._build_cpp_gen(0, {"skin_shade_pack": true})
	if gen_on == null:
		print("G-SSP: FAIL — flag-on generator refused setup."); quit(1); return

	# Probe: a pre-0014 binary accepts the unknown "skin_shade_pack" key but never packs (all bytes ≤ 14).
	# Fail FAST with the actionable message instead of churning through 40k per-texel mismatches.
	var probe: PackedByteArray = gen_on.call("bake_far_tile", 0, _corners(0), 24, 24, 24, PackedInt64Array(), PackedInt32Array())
	var probe_max := 0
	for pb in probe:
		probe_max = maxi(probe_max, int(pb))
	if probe_max <= CubeSphere.SHADE_PACK_LANES:
		print("G-SSP: FAIL — flag-on bake never packs (max byte %d ≤ 14): the engine predates patch 0014. Rebuild." % probe_max)
		quit(1); return

	var n_facets: int = 6 * FacetAtlas.K * FacetAtlas.K
	var sample := PackedInt32Array()
	var stepf := maxi(1, n_facets / 6)   # ~6-7 facets spread over the sphere; × (48² + 64²) ≈ 40k columns ≫ the 256 minimum
	var f := 0
	while f < n_facets:
		sample.append(f); f += stepf

	# ---- G-SSP-OFF: flag-off bytes are idx-only (≤ 14) and idx-equal to the flag-on decode -------------------------
	# ---- G-SSP-PACK: flag-on packed byte == the GDScript reference law, over band-like + fine-like shapes ----------
	var cases := [Vector2i(48, 48), Vector2i(64, 64)]   # tex == nx == ny; band (1 blk/texel) vs fine (subsampled) SHAPES share the code path — both exercised
	var mism_pack := 0
	var mism_idx := 0
	var over_255 := 0
	var off_bad := 0
	var first := ""
	var ncols := 0
	var q_hist := {}
	var tree_seen := false
	for fid in sample:
		var lc := _corners(fid)
		var ctx = TerrainConfig.GenCtx.new(0, fid)
		for c in cases:
			var tex: int = c.x
			var cpp_off: PackedByteArray = gen_off.call("bake_far_tile", fid, lc, tex, tex, tex, PackedInt64Array(), PackedInt32Array())
			var cpp_on: PackedByteArray = gen_on.call("bake_far_tile", fid, lc, tex, tex, tex, PackedInt64Array(), PackedInt32Array())
			if cpp_off.size() != tex * tex or cpp_on.size() != tex * tex:
				fails += 1
				print("  FAIL size fid=%d tex=%d off=%d on=%d" % [fid, tex, cpp_off.size(), cpp_on.size()])
				continue
			for by in range(tex):
				var t := (float(by) + 0.5) / float(tex)
				var row_off := by * tex
				for bx in range(tex):
					var s := (float(bx) + 0.5) / float(tex)
					var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
					var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
					var b_off: int = cpp_off[row_off + bx]
					var b_on: int = cpp_on[row_off + bx]
					ncols += 1
					if b_off <= 0 or b_off > CubeSphere.SHADE_PACK_LANES:
						off_bad += 1
						if first == "": first = "OFF fid=%d texel(%d,%d) byte=%d not in [1,14]" % [fid, bx, by, b_off]
						continue
					var fi := b_off - 1
					if b_on <= 0 or ((b_on - 1) % CubeSphere.SHADE_PACK_LANES) != fi:
						mism_idx += 1
						if first == "": first = "IDX fid=%d texel(%d,%d) on=%d off-idx=%d" % [fid, bx, by, b_on, fi]
					if b_on > 255 or b_on > 1 + 13 + CubeSphere.SHADE_PACK_LANES * (CubeSphere.SHADE_PACK_STEPS - 1):
						over_255 += 1
					var want := _pack_ref(fi, fid, lx, lz, ctx)
					if b_on != want:
						mism_pack += 1
						if first == "": first = "PACK fid=%d texel(%d,%d) lx=%d lz=%d on=%d want=%d (idx=%d)" % [fid, bx, by, lx, lz, b_on, want, fi]
					else:
						q_hist[(b_on - 1) / CubeSphere.SHADE_PACK_LANES] = true
					if not tree_seen and TreeGen.top_decoration(lx, lz, ctx) != BlockCatalog.AIR:
						tree_seen = true
	checks += 3
	if off_bad == 0:
		print("  G-SSP-OFF PASS — %d flag-off bytes all idx-only in [1,14] (packed == idx law holds off)" % ncols)
	else:
		fails += 1
		print("  G-SSP-OFF FAIL — %d flag-off bytes outside [1,14]; first: %s" % [off_bad, first])
	if mism_pack == 0 and mism_idx == 0 and ncols >= 256:
		print("  G-SSP-PACK PASS — %d columns: packed == 1 + idx + 14·shade_q(SurfaceShot._shade), idx preserved" % ncols)
	else:
		fails += 1
		print("  G-SSP-PACK FAIL — pack-mismatch=%d idx-mismatch=%d ncols=%d; first: %s" % [mism_pack, mism_idx, ncols, first])
	if over_255 == 0:
		print("  G-SSP-CAP  PASS — every packed byte ≤ 252 ≤ 255")
	else:
		fails += 1
		print("  G-SSP-CAP  FAIL — %d packed bytes exceed the cap" % over_255)

	# ---- G-SSP-EDIT: the EDIT branch packs (idx preserved + shade carried) ----------------------------------------
	var efid := sample[sample.size() / 2]
	var elc := _corners(efid)
	var ectx = TerrainConfig.GenCtx.new(0, efid)
	var etex := 32
	var ecells := PackedInt64Array()
	var efar := PackedInt32Array()
	var eset := {}
	for by in range(etex):
		var t := (float(by) + 0.5) / float(etex)
		for bx in range(etex):
			var s := (float(bx) + 0.5) / float(etex)
			var lx := int(round(_bilerp(elc[0].x, elc[1].x, elc[2].x, elc[3].x, s, t)))
			var lz := int(round(_bilerp(elc[0].y, elc[1].y, elc[2].y, elc[3].y, s, t)))
			var key := _pack_xz(lx, lz)
			if not eset.has(key):
				var eidx := (absi(lx) + absi(lz)) % CubeSphere.SHADE_PACK_LANES
				eset[key] = eidx
				ecells.append(key)
				efar.append(eidx)
	var cpp_e: PackedByteArray = gen_on.call("bake_far_tile", efid, elc, etex, etex, etex, ecells, efar)
	var emism := 0
	var efirst := ""
	for by in range(etex):
		var t := (float(by) + 0.5) / float(etex)
		var row_off := by * etex
		for bx in range(etex):
			var s := (float(bx) + 0.5) / float(etex)
			var lx := int(round(_bilerp(elc[0].x, elc[1].x, elc[2].x, elc[3].x, s, t)))
			var lz := int(round(_bilerp(elc[0].y, elc[1].y, elc[2].y, elc[3].y, s, t)))
			var want := _pack_ref(int(eset[_pack_xz(lx, lz)]), efid, lx, lz, ectx)
			if cpp_e[row_off + bx] != want:
				emism += 1
				if efirst == "": efirst = "texel(%d,%d) got=%d want=%d" % [bx, by, cpp_e[row_off + bx], want]
	checks += 1
	if cpp_e.size() == etex * etex and emism == 0:
		print("  G-SSP-EDIT PASS — %d edited cells pack (edit idx preserved + shade carried)" % eset.size())
	else:
		fails += 1
		print("  G-SSP-EDIT FAIL — size=%d mismatches=%d; first: %s" % [cpp_e.size(), emism, efirst])

	# ---- G-SSP-SPREAD: the sample must exercise real relief + trees (else PACK could pass on a flat constant) ------
	checks += 1
	if q_hist.size() >= 3 and tree_seen:
		print("  G-SSP-SPREAD PASS — %d distinct shade_q steps; tree column present" % q_hist.size())
	else:
		fails += 1
		print("  G-SSP-SPREAD FAIL — distinct shade_q=%d (need ≥3), tree_seen=%s" % [q_hist.size(), str(tree_seen)])

	print("G-SSP: %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
