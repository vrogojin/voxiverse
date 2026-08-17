extends SceneTree
## G-FTSC — FP_FT_SKIN_CHOP gate (docs/COSMOS-FARTREE-CHOP-DESIGN.md §5, task #137).
##
## Proves the chopped-tree far-skin fix end to end WITHOUT a compile-time sed of the flag itself (the mechanism is
## exercised through the gate-forcing `force` params, the `fine_pause_on` convention). Checks:
##   G-FTSC-OFF   flag off (in-tree default): with a REAL chop seeded, far_skin_edit_snap ⇒ {}, _snap_slot leaves the
##                per-slot arrays empty, invalidate_far_skin is a no-op — the byte-off inertness proof.
##   G-FTSC-SNAP  the forced snapshot is EXACTLY the chopped tree's grid cell columns where TreeGen.top_decoration is
##                non-air, each valued TerrainConfig.top_block_id(...); an un-chopped control tree contributes nothing.
##   G-FTSC-BAKE  a bake fed the snapshot arrays reads the EDIT-branch (terrain) index at every chopped-footprint
##                texel and the TREE index at the control tree's texels; ≥1 chopped texel actually changed vs the
##                un-edited bake (vacuity guard); C++ bake_far_tile ≡ the GDScript reference byte-for-byte.
##   G-FTSC-INVAL invalidate_far_skin drops fine residency + evicts the band layer; an in-flight bake latches
##                `_skin_stale` and the commit drain re-invalidates.
## RUN (needs FACETED + FLAT_WORLD sed-toggled like every faceted gate; FP_FT_SKIN_CHOP needs NO sed):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_ft_skin_chop.gd
## Exits 0 all-pass, 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const WM := preload("res://src/world/world_manager.gd")
const TB := preload("res://src/world/facet_tex_baker.gd")

var _pass := 0
var _fail := 0
var _w = null   # the WorldManager the forced-snap Callable closes over

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)

func _corners(fid: int) -> PackedVector2Array:
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var wp := FA.facet_planar_corner(fid, ci)
		var l := FA.world_to_lattice64(fid, wp[0], wp[1], wp[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	return lc

## Byte-equal replica of _pbm_compute's GDScript branch (EDIT → TREE → TERRAIN; verify_tile_bake's _gd_ref with the
## edit map keyed by Vector2i column like the shipped `esnap`). The reference the C++ bake must match under edits.
func _gd_ref(fid: int, lc: PackedVector2Array, tex: int, esnap: Dictionary) -> PackedByteArray:
	var ctx = TC.GenCtx.new(0, fid)
	var out := PackedByteArray()
	out.resize(tex * tex)
	out.fill(0)
	var has_edits: bool = not esnap.is_empty()
	for by in range(tex):
		var t := (float(by) + 0.5) / float(tex)
		var row_off := by * tex
		for bx in range(tex):
			var s := (float(bx) + 0.5) / float(tex)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var fi := -1
			if has_edits:
				var eb := int(esnap.get(Vector2i(lx, lz), -1))
				if eb >= 0:
					fi = FarPalette.far_color_index_of_block(eb)
			if fi < 0:
				var deco := TreeGen.top_decoration(lx, lz, ctx)
				if deco != BlockCatalog.AIR:
					fi = FarPalette.far_color_index_of_block(deco) if CubeSphere.FP_SKIN_BLOCK_EXACT else FarPalette.far_color_index(BlockCatalog.color_of(deco))
				else:
					var prof := TC.facet_profile(fid, lx, lz)
					var g := int(prof.x)
					if CubeSphere.FP_SKIN_BLOCK_EXACT:
						fi = FarPalette.far_color_index_of_block(TC.top_block_id(g, int(prof.y), prof.w, lx, lz))
					else:
						fi = FarPalette.far_color_index(FarPalette.color_for(g, int(prof.y), prof.w, g < TC.SEA_LEVEL))
			out[row_off + bx] = fi + 1
	return out

## The forced-snapshot Callable installed on the baker (the real wiring passes 1 arg, so `force` takes the flag
## default there; the gate's query forces so the baker-side plumbing is testable with the flag compiled off).
func _forced_snap(fid: int) -> Dictionary:
	return _w.far_skin_edit_snap(fid, true)

func _initialize() -> void:
	print("=== verify_ft_skin_chop (G-FTSC — FP_FT_SKIN_CHOP, task #137) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("G-FTSC: SKIP — needs FACETED + FLAT_WORLD (sed-toggled like the other faceted gates).")
		quit(0)
		return
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	FarPalette.ensure_far_index_ready()
	TC.warm_up()
	FA.warm_up()
	var flag_on: bool = CubeSphere.FP_FT_SKIN_CHOP
	print("  FP_FT_SKIN_CHOP=%s FP_SKIN_BLOCK_EXACT=%s" % [str(flag_on), str(CubeSphere.FP_SKIN_BLOCK_EXACT)])

	# --- Find a facet carrying TWO distinct trees with a real above-ground footprint (chop + control). ---------------
	var fid := -1
	var chop_g := Vector2i.ZERO
	var ctrl_g := Vector2i.ZERO
	var chop_base := Vector3i.ZERO
	var n_facets: int = 6 * FA.K * FA.K
	var step := maxi(1, n_facets / 48)
	var f := 0
	while f < n_facets and fid < 0:
		var ctx = TC.GenCtx.new(0, f)
		var dmn := FA.dom_min(f)
		var dmx := FA.dom_max(f)
		var trees: Array = []
		for gx in range(floori(float(dmn.x) / float(TreeGen.G)), floori(float(dmx.x) / float(TreeGen.G)) + 1):
			for gz in range(floori(float(dmn.y) / float(TreeGen.G)), floori(float(dmx.y) / float(TreeGen.G)) + 1):
				var info := TreeGen.tree_info(gx, gz, ctx)
				if info.is_empty():
					continue
				var b: Vector3i = info["base"]
				# a REAL painted footprint (submerged bases decorate nothing) inside the facet polygon
				if TreeGen.top_decoration(b.x, b.z, ctx) == BlockCatalog.AIR or not FA.in_polygon(f, b.x, b.z, 0.0):
					continue
				trees.append([Vector2i(gx, gz), b])
				if trees.size() >= 2:
					break
			if trees.size() >= 2:
				break
		if trees.size() >= 2:
			fid = f
			chop_g = trees[0][0]
			chop_base = trees[0][1]
			ctrl_g = trees[1][0]
		f += step
	_ok(fid >= 0, "setup: found a facet with ≥2 painted trees (scanned stride %d)" % step)
	if fid < 0:
		_done()
		return
	print("  fid=%d chop_gcell=%s base=%s ctrl_gcell=%s" % [fid, str(chop_g), str(chop_base), str(ctrl_g)])

	# --- Seed the chop: the trunk-base cell (base + (0,1,0)) dug to air — EXACTLY the rung-1/2 predicate cell. -------
	_w = WM.new()
	TC.set_active_facet(fid)
	var trunk_base := Vector3i(chop_base.x, chop_base.y + 1, chop_base.z)
	_w.seed_edit_for_test(trunk_base, 0)
	_ok(_w.far_tree_chopped(fid, trunk_base), "setup: far_tree_chopped sees the seeded trunk-base edit")

	# --- G-FTSC-OFF: byte-off inertness (only assertable when the flag is compiled off, the in-tree default) ---------
	if not flag_on:
		_ok(_w.far_skin_edit_snap(fid).is_empty(), "G-FTSC-OFF: unforced far_skin_edit_snap is {} despite the chop")
	else:
		print("  G-FTSC-OFF skipped (flag compiled ON — sed run)")

	# --- G-FTSC-SNAP: forced snapshot exactness -----------------------------------------------------------------------
	var snap: Dictionary = _w.far_skin_edit_snap(fid, true)
	var ctx2 = TC.GenCtx.new(0, fid)
	var expected := {}
	for lx in range(chop_g.x * TreeGen.G, (chop_g.x + 1) * TreeGen.G):
		for lz in range(chop_g.y * TreeGen.G, (chop_g.y + 1) * TreeGen.G):
			if TreeGen.top_decoration(lx, lz, ctx2) != BlockCatalog.AIR:
				var prof := TC.facet_profile(fid, lx, lz)
				expected[Vector2i(lx, lz)] = TC.top_block_id(int(prof.x), int(prof.y), prof.w, lx, lz)
	_ok(not snap.is_empty(), "G-FTSC-SNAP: forced snapshot non-empty (chopped tree found from the edit)")
	_ok(snap.size() == expected.size(), "G-FTSC-SNAP: footprint size %d == expected %d" % [snap.size(), expected.size()])
	var content_ok := true
	for k in expected:
		if int(snap.get(k, -999)) != int(expected[k]):
			content_ok = false
			break
	_ok(content_ok, "G-FTSC-SNAP: every footprint column carries its bare-terrain top_block_id")
	var ctrl_clean := true
	for k in snap:
		var kv: Vector2i = k
		if kv.x >= ctrl_g.x * TreeGen.G and kv.x < (ctrl_g.x + 1) * TreeGen.G \
				and kv.y >= ctrl_g.y * TreeGen.G and kv.y < (ctrl_g.y + 1) * TreeGen.G:
			ctrl_clean = false
			break
	_ok(ctrl_clean, "G-FTSC-SNAP: the un-chopped control tree contributes NO columns")
	# memo: same revision returns the identical snapshot; a new unrelated edit re-computes (rev keyed on edit_count)
	_ok(_w.far_skin_edit_snap(fid, true) == snap, "G-FTSC-SNAP: memo returns the identical snapshot at the same rev")
	_w.seed_edit_for_test(Vector3i(chop_base.x + 3, chop_base.y + 20, chop_base.z + 3), 3)   # unrelated placed block
	var snap2: Dictionary = _w.far_skin_edit_snap(fid, true)
	_ok(snap2.size() == snap.size(), "G-FTSC-SNAP: re-memo after an unrelated edit keeps the footprint (%d)" % snap2.size())

	# --- G-FTSC-BAKE: the baked bytes ---------------------------------------------------------------------------------
	var lc := _corners(fid)
	var tex := 256
	var ref_chop := _gd_ref(fid, lc, tex, snap2)
	var ref_clean := _gd_ref(fid, lc, tex, {})
	var ctx3 = TC.GenCtx.new(0, fid)
	var chopped_texels := 0
	var changed_texels := 0
	var chop_law_ok := true
	var ctrl_texels := 0
	var ctrl_law_ok := true
	for by in range(tex):
		var t := (float(by) + 0.5) / float(tex)
		for bx in range(tex):
			var s := (float(bx) + 0.5) / float(tex)
			var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var p := by * tex + bx
			var col := Vector2i(lx, lz)
			if snap2.has(col):
				chopped_texels += 1
				if int(ref_chop[p]) != FarPalette.far_color_index_of_block(int(snap2[col])) + 1:
					chop_law_ok = false
				if ref_chop[p] != ref_clean[p]:
					changed_texels += 1
			elif lx >= ctrl_g.x * TreeGen.G and lx < (ctrl_g.x + 1) * TreeGen.G \
					and lz >= ctrl_g.y * TreeGen.G and lz < (ctrl_g.y + 1) * TreeGen.G \
					and TreeGen.top_decoration(lx, lz, ctx3) != BlockCatalog.AIR:
				ctrl_texels += 1
				if ref_chop[p] != ref_clean[p]:
					ctrl_law_ok = false     # control tree must be untouched by the chop snapshot
	_ok(chopped_texels >= 1, "G-FTSC-BAKE: ≥1 texel lands on the chopped footprint (got %d)" % chopped_texels)
	_ok(chop_law_ok, "G-FTSC-BAKE: every chopped-footprint texel bakes the EDIT-branch (terrain) index")
	_ok(changed_texels >= 1, "G-FTSC-BAKE: ≥1 chopped texel actually CHANGED vs the un-edited bake (got %d/%d — non-vacuous)" % [changed_texels, chopped_texels])
	_ok(ctrl_texels >= 1 and ctrl_law_ok, "G-FTSC-BAKE: the control tree's %d texels are byte-identical to the un-edited bake" % ctrl_texels)

	# C++ bake_far_tile ≡ the GDScript reference, fed the same snapshot arrays the dispatch would build.
	var gen: Object = FacetSkinTier._build_cpp_gen(fid)
	if gen != null and gen.has_method("bake_far_tile"):
		var ec := PackedInt64Array()
		var ef := PackedInt32Array()
		for k in snap2:
			ec.append(_pack_xz(int(k.x), int(k.y)))
			ef.append(FarPalette.far_color_index_of_block(int(snap2[k])))
		var cpp: PackedByteArray = gen.call("bake_far_tile", fid, lc, tex, tex, tex, ec, ef)
		_ok(cpp.size() == tex * tex and cpp == ref_chop, "G-FTSC-BAKE: C++ bake_far_tile byte-equal to the GDScript reference with the chop snapshot")
	else:
		print("  G-FTSC-BAKE: C++ leg skipped (VoxelGeneratorCosmos/bake_far_tile absent — GDScript path proven above)")

	# --- G-FTSC-INVAL: cache coherence on a minimal baker harness -----------------------------------------------------
	var b = TB.new()
	b.set_edit_snap_query(Callable(self, "_forced_snap"))
	# minimal 1-slot pbm harness (the real sizing lives in _setup_parallel_band, gated behind the band flags)
	b._pbm_n = 1
	b._pbm_fid.resize(1); b._pbm_fid[0] = -1
	b._pbm_esnap.resize(1); b._pbm_esnap[0] = {}
	b._pbm_ecells.resize(1); b._pbm_ecells[0] = PackedInt64Array()
	b._pbm_efar.resize(1); b._pbm_efar[0] = PackedInt32Array()
	if not flag_on:
		b._snap_slot(0, fid)                     # unforced: the flag gate must leave the slot empty
		_ok((b._pbm_ecells[0] as PackedInt64Array).is_empty() and (b._pbm_esnap[0] as Dictionary).is_empty(),
			"G-FTSC-OFF: unforced _snap_slot leaves the per-slot arrays empty despite the chop")
	b._snap_slot(0, fid, true)
	_ok((b._pbm_esnap[0] as Dictionary).size() == snap2.size() and (b._pbm_ecells[0] as PackedInt64Array).size() == snap2.size()
		and (b._pbm_efar[0] as PackedInt32Array).size() == snap2.size(),
		"G-FTSC-INVAL: forced _snap_slot freezes the full snapshot into the per-slot arrays")
	b._fine_baked[fid] = true
	if not flag_on:
		b.invalidate_far_skin(fid)               # unforced: must be a no-op
		_ok(b._fine_baked.has(fid), "G-FTSC-OFF: unforced invalidate_far_skin is a no-op")
	b.invalidate_far_skin(fid, true)
	_ok(not b._fine_baked.has(fid) and not b._skin_stale.has(fid),
		"G-FTSC-INVAL: invalidate drops fine residency (no latch — nothing in flight)")
	b._bm_slots[fid] = 3
	b.invalidate_far_skin(fid, true)
	_ok(not b._bm_slots.has(fid) and b._bm_free.has(3), "G-FTSC-INVAL: invalidate evicts the resident band layer")
	# in-flight race: a chop mid-bake latches _skin_stale; the commit drain re-invalidates
	b._fine_baked[fid] = true
	b._pbm_fid[0] = fid                          # simulate an in-flight bake of this facet
	b.invalidate_far_skin(fid, true)
	_ok(b._skin_stale.has(fid), "G-FTSC-INVAL: chop while in flight latches _skin_stale")
	b._pbm_fid[0] = -1                           # simulate the reap finishing the bake…
	b._fine_baked[fid] = true                    # …whose commit re-marked the (stale) tile
	b._drain_skin_stale(fid)
	_ok(not b._fine_baked.has(fid) and not b._skin_stale.has(fid),
		"G-FTSC-INVAL: the commit drain re-invalidates the stale tile and clears the latch")

	_w.free()
	_w = null
	_done()

func _done() -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail != 0 else 0)
