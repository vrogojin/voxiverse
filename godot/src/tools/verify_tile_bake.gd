extends SceneTree
## G-CPB — FP_CPP_TILE_BAKE byte-equality gate.
##
## Proves VoxelGeneratorCosmos::bake_far_tile() (patch 0011, C++) produces the EXACT same far-skin index bytes as the
## shipping GDScript bake path in facet_tex_baker.gd::_pbm_compute (the `elif not tiled` branch). Requires the rebuilt
## engine (0011). Three checks:
##   G-CPB-TILE  byte-equal C++ vs GDScript reference over a facet sample × rectangular tile cases (no edits).
##   G-CPB-CONC  the same facets baked concurrently on the WorkerThreadPool match the serial result (thread-safe const).
##   G-CPB-FALS  a deliberately corner-swapped tile MUST differ from the correct one (the comparison isn't trivially equal).
## Exits 0 all-pass, 1 on any failure.

func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)

# Byte-equal replica of _pbm_compute's shipping GDScript branch (edit → tree → terrain). `edits` maps _pack_xz(lx,lz)
# → block_id (mirrors _edit_snap); empty for the no-edit cases.
func _gd_ref(fid: int, lc: PackedVector2Array, nx: int, ny: int, tex: int, edits: Dictionary = {}) -> PackedByteArray:
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var out := PackedByteArray(); out.resize(tex * tex); out.fill(0)
	var has_edits: bool = not edits.is_empty()
	for by in range(ny):
		var t := (float(by) + 0.5) / float(ny)
		var row_off := by * tex
		for bx in range(nx):
			var s := (float(bx) + 0.5) / float(nx)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var fi := -1
			if has_edits:
				var k := _pack_xz(lx, lz)
				if edits.has(k):
					fi = FarPalette.far_color_index_of_block(int(edits[k]))
			if fi < 0:
				var deco := TreeGen.top_decoration(lx, lz, ctx)
				if deco != BlockCatalog.AIR:
					fi = FarPalette.far_color_index_of_block(deco) if CubeSphere.FP_SKIN_BLOCK_EXACT else FarPalette.far_color_index(BlockCatalog.color_of(deco))
				else:
					var prof := TerrainConfig.facet_profile(fid, lx, lz)
					var g := int(prof.x)
					if CubeSphere.FP_SKIN_BLOCK_EXACT:
						fi = FarPalette.far_color_index_of_block(TerrainConfig.top_block_id(g, int(prof.y), prof.w, lx, lz))
					else:
						fi = FarPalette.far_color_index(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
			out[row_off + bx] = fi + 1
	return out

func _corners(fid: int) -> PackedVector2Array:
	var lc := PackedVector2Array(); lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	return lc

var _gen: Object = null
var _conc_lc: Array = []
var _conc_fids: PackedInt32Array = PackedInt32Array()
var _conc_out: Array = []
const _CONC_TEX := 48

func _conc_task(k: int) -> void:
	_conc_out[k] = _gen.call("bake_far_tile", _conc_fids[k], _conc_lc[k], _CONC_TEX, _CONC_TEX, _CONC_TEX, PackedInt64Array(), PackedInt32Array())

func _init() -> void:
	var fails := 0
	var checks := 0
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("G-CPB: SKIP — needs FACETED + FLAT_WORLD."); quit(0); return
	# Same init chain the world/baker setup runs, so FacetAtlas frames + palettes exist in this bare SceneTree.
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	FarPalette.ensure_far_index_ready()
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	_gen = FacetSkinTier._build_cpp_gen(0)
	if _gen == null:
		print("G-CPB: SKIP — VoxelGeneratorCosmos absent (module not compiled in). Gate is a no-op on the GDScript path.")
		quit(0); return
	if not _gen.has_method("bake_far_tile"):
		print("G-CPB: FAIL — engine has the module but NOT bake_far_tile(). Rebuild with patch 0011.")
		quit(1); return

	# ---- G-CPB-TILE: byte-equality over a facet sample × tile-shape cases -------------------------------------------
	var n_facets: int = 6 * FacetAtlas.K * FacetAtlas.K
	var sample := PackedInt32Array()
	var step := maxi(1, n_facets / 24)
	var f := 0
	while f < n_facets:
		sample.append(f); f += step
	# tile shapes: full square, non-square (stride test), and a partial fill (nx,ny < tex leaves a zero border)
	var cases := [Vector3i(64, 64, 64), Vector3i(40, 64, 64), Vector3i(51, 33, 64)]
	var mism_total := 0
	var first_mism := ""
	var hist := {}   # palette index (byte-1) → count, for coverage (G-CPB-COVER)
	for fid in sample:
		var lc := _corners(fid)
		for c in cases:
			var nx: int = c.x; var ny: int = c.y; var tex: int = c.z
			var cpp: PackedByteArray = _gen.call("bake_far_tile", fid, lc, nx, ny, tex, PackedInt64Array(), PackedInt32Array())
			var gd := _gd_ref(fid, lc, nx, ny, tex)
			checks += 1
			if cpp.size() != tex * tex:
				fails += 1
				print("  FAIL size fid=%d case=%s cpp.size=%d expect=%d" % [fid, str(c), cpp.size(), tex * tex])
				continue
			var mism := 0
			for p in range(tex * tex):
				var b: int = gd[p]
				if b > 0:
					hist[b - 1] = int(hist.get(b - 1, 0)) + 1
				if cpp[p] != b:
					mism += 1
					if first_mism == "":
						var px := p % tex; var py := p / tex
						first_mism = "fid=%d case=%s texel(%d,%d) cpp=%d gd=%d" % [fid, str(c), px, py, cpp[p], b]
			if mism != 0:
				fails += 1
				mism_total += mism
	if mism_total == 0:
		print("  G-CPB-TILE PASS — %d tiles byte-equal (facets=%d × cases=%d)" % [checks, sample.size(), cases.size()])
	else:
		print("  G-CPB-TILE FAIL — %d mismatching texels; first: %s" % [mism_total, first_mism])

	# ---- G-CPB-COVER: the sample must NON-VACUOUSLY exercise trees + varied terrain (else G-CPB-TILE could pass blind) --
	var leaf_idx := FarPalette.far_color_index_of_block(BlockCatalog.LEAF)
	var wood_idx := FarPalette.far_color_index_of_block(BlockCatalog.WOOD)
	var pillar_idx := FarPalette.far_color_index(Color(0.20, 0.20, 0.23))
	var distinct := hist.size()
	var tree_seen: bool = hist.has(leaf_idx) or hist.has(wood_idx)
	checks += 1
	if distinct >= 6 and tree_seen:
		print("  G-CPB-COVER PASS — %d distinct far indices; tree(leaf=%d/wood=%d) present; pillar[%d] %s" %
			[distinct, leaf_idx, wood_idx, pillar_idx, "present" if hist.has(pillar_idx) else "absent(ok)"])
	else:
		fails += 1
		print("  G-CPB-COVER FAIL — distinct=%d (need ≥6), tree_seen=%s. Sample doesn't exercise the tree/terrain paths." % [distinct, str(tree_seen)])

	# ---- G-CPB-EDIT: byte-equality WITH a full edit set (EditTable + pack_xz incl. negative coords + a dug-to-air 0) ----
	var efid := sample[3]
	var elc := _corners(efid)
	var etex := 56
	# Place a distinct edit at EVERY sampled lattice cell of the tile (varied block ids incl. AIR=0), so the EditTable,
	# pack_xz over whatever coord signs this facet carries, presence-wins, and the index-0 case all fire.
	var edits := {}
	var ecells := PackedInt64Array()
	var efar := PackedInt32Array()
	var pick := [BlockCatalog.AIR, BlockCatalog.WOOD, BlockCatalog.LEAF, BlockCatalog.id_of(&"stone"), BlockCatalog.id_of(&"sand")]
	for by in range(etex):
		var t := (float(by) + 0.5) / float(etex)
		for bx in range(etex):
			var s := (float(bx) + 0.5) / float(etex)
			var lx := int(round(_bilerp(elc[0].x, elc[1].x, elc[2].x, elc[3].x, s, t)))
			var lz := int(round(_bilerp(elc[0].y, elc[1].y, elc[2].y, elc[3].y, s, t)))
			var key := _pack_xz(lx, lz)
			if not edits.has(key):
				var blk: int = pick[(absi(lx) + absi(lz)) % pick.size()]
				edits[key] = blk
				ecells.append(key)
				efar.append(FarPalette.far_color_index_of_block(blk))
	var cpp_e: PackedByteArray = _gen.call("bake_far_tile", efid, elc, etex, etex, etex, ecells, efar)
	var gd_e := _gd_ref(efid, elc, etex, etex, etex, edits)
	checks += 1
	if cpp_e.size() == etex * etex and cpp_e == gd_e:
		print("  G-CPB-EDIT PASS — %d edited cells byte-equal C++ vs GDScript (incl. dug-to-air 0 + neg coords)" % edits.size())
	else:
		fails += 1
		var em := -1
		for p in range(mini(cpp_e.size(), gd_e.size())):
			if cpp_e[p] != gd_e[p]: em = p; break
		print("  G-CPB-EDIT FAIL — cpp.size=%d gd.size=%d first-mismatch texel=%d" % [cpp_e.size(), gd_e.size(), em])

	# ---- G-CPB-FALS: a corner-swapped tile MUST differ (guards against a trivially-equal comparator) ----------------
	var ff := sample[sample.size() / 2]
	var lc0 := _corners(ff)
	var lc_bad := PackedVector2Array([lc0[1], lc0[0], lc0[3], lc0[2]])  # swap v00<->v10, v11<->v01
	var a: PackedByteArray = _gen.call("bake_far_tile", ff, lc0, 64, 64, 64, PackedInt64Array(), PackedInt32Array())
	var b: PackedByteArray = _gen.call("bake_far_tile", ff, lc_bad, 64, 64, 64, PackedInt64Array(), PackedInt32Array())
	checks += 1
	if a == b:
		fails += 1
		print("  G-CPB-FALS FAIL — corner-swapped tile identical to correct (comparator would miss a real bug)")
	else:
		print("  G-CPB-FALS PASS — corner-swapped tile differs, as it must")

	# ---- G-CPB-CONC: concurrent bakes on the WorkerThreadPool == serial (const, thread-safe) ------------------------
	_conc_fids = PackedInt32Array()
	_conc_lc = []
	var m := mini(8, sample.size())
	for k in range(m):
		_conc_fids.append(sample[k]); _conc_lc.append(_corners(sample[k]))
	var serial := []
	for k in range(m):
		serial.append(_gen.call("bake_far_tile", _conc_fids[k], _conc_lc[k], _CONC_TEX, _CONC_TEX, _CONC_TEX, PackedInt64Array(), PackedInt32Array()))
	_conc_out = []; _conc_out.resize(m)
	var gid := WorkerThreadPool.add_group_task(Callable(self, "_conc_task"), m, -1, false, "gcpb")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	var conc_bad := 0
	for k in range(m):
		if _conc_out[k] != serial[k]:
			conc_bad += 1
	checks += 1
	if conc_bad == 0:
		print("  G-CPB-CONC PASS — %d facets baked concurrently == serial" % m)
	else:
		fails += 1
		print("  G-CPB-CONC FAIL — %d/%d concurrent bakes differ from serial" % [conc_bad, m])

	print("G-CPB %s — checks=%d fails=%d" % ["PASS" if fails == 0 else "FAIL", checks, fails])
	quit(1 if fails != 0 else 0)
