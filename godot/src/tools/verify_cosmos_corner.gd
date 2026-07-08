extends SceneTree
## COSMOS-CORNER-CANONICAL (#69) verification — the terrain-preserving §8.2 corner-quadrant fix.
##   godot --headless --path godot --script res://src/tools/verify_cosmos_corner.gd
## Exits 0 all-pass, 1 on any failure. Gates c1/c3/c4/c5 are pure/analytic and run on ANY binary; the
## full-block gates c2/c6/c7 need the curved resolve_cell path (nested column_profile short-circuits to
## flat under FLAT_WORLD), so they SKIP on the flat binary and run on the curved one (temp-flip + restore).
## docs/COSMOS-CORNER-CANONICAL.md §7 defines every gate.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TC := preload("res://src/world/terrain_config.gd")

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

# The 4 diagonal corners of a face = the (±) overshoot sign pairs.
const SIGNS := [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

func _wedge_col(face: int, sign: Vector2i, depth: int, n: int) -> Vector2i:
	var vx: int = (n - 1) + depth if sign.x > 0 else -depth
	var vz: int = (n - 1) + depth if sign.y > 0 else -depth
	return Vector2i(vx, vz)

## Full block-id column via the real worker pipeline (worker_fold_column → column_profile → slope_run_of
## → resolve_cell) over [g−48, g+40]. Curved only. Returns {cf, ci, cj, g, ids}.
func _gen_col(gen_face: int, vx: int, vz: int) -> Dictionary:
	var ctx := TC.GenCtx.new(gen_face)
	var tc: Vector3i = TC.worker_fold_column(gen_face, vx, vz, ctx)
	ctx.jinv_d4 = 0   # COSMOS-FRAME-ORIENTATION §8 G-E: compare CANONICAL content (§8.2), not the per-home render rotation (G-D covers that)
	var p: Vector4 = TC.column_profile(tc.y, tc.z, ctx)
	var srun := TC.slope_run_of(tc.y, tc.z, ctx)
	var g := int(p.x)
	var ids := {}
	for y in range(g - 48, g + 41):
		ids[y] = TC.resolve_cell(tc.y, y, tc.z, g, int(p.y), p.z, p.w, ctx, srun)
	return {"cf": tc.x, "ci": tc.y, "cj": tc.z, "g": g, "ids": ids}

func _cols_equal(a: Dictionary, b: Dictionary) -> bool:
	if int(a["g"]) != int(b["g"]):
		return false
	for y in a["ids"].keys():
		if not b["ids"].has(y) or int(a["ids"][y]) != int(b["ids"][y]):
			return false
	return true

func _initialize() -> void:
	print("COSMOS-CORNER-CANONICAL — corner-quadrant §8.2 gates (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	BlockCatalog.ensure_ready()
	TC.warm_up()
	var n := CS.n_for(CS.HOME_BODY)
	CS.warm_edge_tables(n)
	CS.reset_corner_fence()

	_c1_well_defined(n)
	_c5_flat_sentinels(n)
	_c3_continuity(n)
	_c4_edits(n)
	if CS.FLAT_WORLD:
		print("[c2/c6/c7] SKIP full-block corner gates: need FLAT_WORLD=false (run on the curved binary).")
	else:
		_c2_path_independence(n)
		_c6_worker_parity(n)
		_c7_fringe(n)

	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------------------------------------------------------------------------------
# (c1) fold_cell_canonical well-defined: in-range on a real face, fence zero, deterministic.
# ---------------------------------------------------------------------------------------
func _c1_well_defined(n: int) -> void:
	print("[c1] fold_cell_canonical is well-defined over the corner wedge (in-range real cell, fence 0, deterministic)")
	CS.reset_corner_fence()
	var all_in_range := true
	var deterministic := true
	var count := 0
	for face in range(6):
		for sg: Vector2i in SIGNS:
			for depth: int in [1, 2, 3, 5, 8, 16, 32, 64, 96]:
				var w := _wedge_col(face, sg, depth, n)
				# Confirm it IS a double-out (corner quadrant) column, else the test isn't exercising the branch.
				if int(CS.fold_cell(face, w.x, w.y, n)["face"]) >= 0:
					continue
				var g := CS.fold_cell_canonical(face, w.x, w.y, n)
				var gf := int(g["face"])
				var gi := int(g["i"])
				var gj := int(g["j"])
				if gf < 0 or gf >= 6 or gi < 0 or gi >= n or gj < 0 or gj >= n:
					all_in_range = false
				var g2 := CS.fold_cell_canonical(face, w.x, w.y, n)
				if int(g2["face"]) != gf or int(g2["i"]) != gi or int(g2["j"]) != gj:
					deterministic = false
				count += 1
	_ok(count > 0, "the sweep exercised real double-out columns (%d)" % count)
	_ok(all_in_range, "every canonical fold returns an in-range cell on a real face (never −1)")
	_ok(deterministic, "fold_cell_canonical is deterministic (two calls byte-equal)")
	# The F8 fence = a REAL out-of-range (|a| ≥ 2) — must be zero. The benign a=±1 boundary clamp (nearest
	# edge cell, fires on the exact wedge diagonal) is applied silently and NOT fenced (see the
	# fold_cell_canonical note re: the §2.3/§7c1 doc contradiction); "all_in_range" above proves it works.
	_ok(CS.corner_fence_seen() == 0, "the F8 corner fence (real out-of-range, |a|≥2) stays zero over the sweep")

# ---------------------------------------------------------------------------------------
# (c5) FLAT byte-identity guards: fold_cell's −1 sentinel survives; in-range canonical == identity.
# ---------------------------------------------------------------------------------------
func _c5_flat_sentinels(n: int) -> void:
	print("[c5] sentinels: fold_cell still refuses the corner (−1); fold_cell_canonical is identity in-range")
	var sentinel_ok := int(CS.fold_cell(4, n + 20, n + 20, n)["face"]) < 0
	_ok(sentinel_ok, "fold_cell still returns face −1 for the corner quadrant (untouched — chart.flip refusal)")
	var idr := CS.fold_cell_canonical(4, 100, 200, n)
	_ok(int(idr["face"]) == 4 and int(idr["i"]) == 100 and int(idr["j"]) == 200,
		"fold_cell_canonical is the identity for an in-range cell (the flat-relevant path is unchanged)")
	var single := CS.fold_cell_canonical(4, n + 5, n / 2, n)     # single-out EAST → delegates to fold_cell
	var single_ref := CS.fold_cell(4, n + 5, n / 2, n)
	_ok(int(single["face"]) == int(single_ref["face"]) and int(single["i"]) == int(single_ref["i"]) and int(single["j"]) == int(single_ref["j"]),
		"single-out folds delegate to the exact fold_cell D4 result (edges unchanged)")
	print("      (full FLAT_WORLD byte-identity is covered by verify_feature 6027/0 — all fixed paths are curved-only.)")

# ---------------------------------------------------------------------------------------
# (c3) continuity: wedge-boundary height step ≤ 4 blocks (pins today's 0–2 envelope).
# ---------------------------------------------------------------------------------------
func _c3_continuity(n: int) -> void:
	print("[c3] continuity: |dh| ≤ 4 across the wedge boundary (last in-range cell vs first wedge cell)")
	var worst := 0
	var ok := true
	for face in range(6):
		for sg: Vector2i in SIGNS:
			# The boundary between the last in-range corner cell and the first double-out cell.
			var inside := _wedge_col(face, sg, 0, n)     # depth 0 → (n-1) or 0 corner cell (in range)
			# Clamp inside to a genuine in-range cell.
			inside.x = clampi(inside.x, 0, n - 1)
			inside.y = clampi(inside.y, 0, n - 1)
			var first := _wedge_col(face, sg, 1, n)       # depth 1 → 1 past the corner (double-out)
			if int(CS.fold_cell(face, first.x, first.y, n)["face"]) >= 0:
				continue
			var h_in := int(TC._curved_profile(face, inside.x, inside.y).x)
			# The wedge cell's height via the canonical fold (what dir_of / the render now sample).
			var cg := CS.fold_cell_canonical(face, first.x, first.y, n)
			var h_wedge := int(TC._curved_profile(int(cg["face"]), int(cg["i"]), int(cg["j"])).x)
			var dh := absi(h_in - h_wedge)
			if dh > worst:
				worst = dh
			if dh > 4:
				ok = false
	_ok(ok, "wedge-boundary height step ≤ 4 blocks everywhere (worst=%d)" % worst)

# ---------------------------------------------------------------------------------------
# (c4) edits: a wedge-window edit keys to the canonical cell + reads back; flip in the quadrant refuses.
# ---------------------------------------------------------------------------------------
func _c4_edits(n: int) -> void:
	print("[c4] edits: a wedge-window _write_cell stores under the canonical key + reads back; flip refuses the quadrant")
	var w := WorldManager.new()
	# Chart near face-4's +i,+j corner so a small +window column is double-out.
	w.install_chart(CHART.new(CS.HOME_BODY, 4, n - 5, n - 5))
	var wc := Vector3i(10, 6, 10)                          # global (n+5, n+5) → corner quadrant
	# Confirm it is genuinely a wedge column.
	_ok(int(CS.fold_cell(4, (n - 5) + wc.x, (n - 5) + wc.z, n)["face"]) < 0, "the test window cell is a corner-quadrant column")
	# The wedge cell's global key is now a REAL canonical face (never a raw −1-face key) — the keying
	# upgrade (§4.3 residual 3), which holds regardless of the edit-lock.
	var key := w.chart().to_global_key(wc)
	var uk := CS.unpack_key(key)
	_ok(int(uk["face"]) >= 0 and int(uk["face"]) < 6, "the wedge cell keys to a REAL canonical face (%d)" % int(uk["face"]))
	var packed := CellCodec.canonical(CellCodec.pack(BlockCatalog.STONE))
	var before := w.cell_value_at(wc)
	w._write_cell(wc, packed)
	if WorldManager.CORNER_EDIT_LOCK:
		_ok(w.cell_value_at(wc) == before and not w.has_edit(wc),
			"edit-lock ON: a wedge-window write is REFUSED (no overlay entry; §5.3 companion)")
	else:
		_ok(w.cell_value_at(wc) == packed,
			"edit-lock OFF: the wedge edit stores under the canonical key + reads back through the window")
	# A flip attempted inside the quadrant is still refused (fold_cell −1 guard, untouched).
	var res := w.chart().flip(Vector3(float(wc.x), 6.0, float(wc.z)))
	_ok(not bool(res["ok"]), "chart.flip inside the corner quadrant is still refused (ok:false)")
	w.free()

# ---------------------------------------------------------------------------------------
# (c2) THE gate — §8.2 in the wedge: two home-face windows reaching the same canonical cell generate
# byte-identical full block columns, and equal the true face's native generation (three-way).
# ---------------------------------------------------------------------------------------
func _c2_path_independence(n: int) -> void:
	print("[c2] §8.2 in the wedge — every home-face window reaching a canonical cell generates it identically (+ native)")
	# Sweep ALL faces' ALL corners over a dense band; group the generated block column by canonical
	# (face,i,j) key together with the HOME face it was reached from. Any canonical cell reached by ≥ 2
	# DISTINCT home faces must produce byte-identical columns (that IS §8.2), and each must equal the true
	# face's own in-range native generation (the three-way equality).
	var by_key := {}                                     # canonical_key -> {home_face -> column}
	for face in range(6):
		for sg: Vector2i in SIGNS:
			for depth: int in [1, 2, 3, 4, 6, 8, 12, 18, 26, 40]:
				var wc := _wedge_col(face, sg, depth, n)
				if int(CS.fold_cell(face, wc.x, wc.y, n)["face"]) >= 0:
					continue                             # single-out / in-range — not the wedge
				var g := CS.fold_cell_canonical(face, wc.x, wc.y, n)
				var k := CS.edit_key(int(g["face"]), int(g["i"]), int(g["j"]), 0)
				if not by_key.has(k):
					by_key[k] = {}
				if not by_key[k].has(face):
					by_key[k][face] = _gen_col(face, wc.x, wc.y)
	# Find canonical cells reached from ≥ 2 home faces; assert cross-home agreement + native equality.
	var multi := 0
	var cross_ok := true
	var native_ok := true
	var native_checked := 0
	for k in by_key.keys():
		var homes: Dictionary = by_key[k]
		# native generation of this canonical cell (from any entry — they share cf/ci/cj).
		var any: Dictionary = homes.values()[0]
		var native := _gen_col(int(any["cf"]), int(any["ci"]), int(any["cj"]))
		if not _cols_equal(any, native):
			native_ok = false
		native_checked += 1
		if homes.size() >= 2:
			multi += 1
			for hf in homes.keys():
				if not _cols_equal(homes[hf], native):
					cross_ok = false
	_ok(native_checked > 0 and native_ok, "each wedge canonical cell == its true face's native in-range generation (%d checked)" % native_checked)
	_ok(multi > 0, "canonical cells are reached from ≥ 2 distinct home faces (%d such cells joined)" % multi)
	_ok(cross_ok, "every home face reaching a canonical cell generates it BYTE-IDENTICALLY (§8.2 restored)")

# ---------------------------------------------------------------------------------------
# (c6) worker parity: worker_fold_column == chart.to_global_column canonical column for a window cell.
# ---------------------------------------------------------------------------------------
func _c6_worker_parity(n: int) -> void:
	print("[c6] worker parity: worker_fold_column == chart.to_global_column for the same wedge window column")
	var chart := CHART.new(CS.HOME_BODY, 4, n - 6, n - 6)
	var ok := true
	var count := 0
	for depth: int in [2, 6, 15, 40]:
		var wc := Vector3i(depth + 4, 0, depth + 4)       # window x,z past the corner in both axes
		var gcol := chart.to_global_column(wc.x, wc.z)
		if int(CS.fold_cell(4, (n - 6) + wc.x, (n - 6) + wc.z, n)["face"]) >= 0:
			continue
		var ctx := TC.GenCtx.new(4)
		var tc: Vector3i = TC.worker_fold_column(4, (n - 6) + wc.x, (n - 6) + wc.z, ctx)
		if int(gcol["face"]) != tc.x or int(gcol["i"]) != tc.y or int(gcol["j"]) != tc.z:
			ok = false
		count += 1
	_ok(count > 0 and ok, "render (chart) and physics (worker) fold the wedge to the SAME canonical column (%d)" % count)

# ---------------------------------------------------------------------------------------
# (c7) fringe path-independence: in-range cells within 2 cells of a corner, reached from a neighbour
# home face, generate byte-identically (post-fix; §1.1 says already-consistent, canonical must not break it).
# ---------------------------------------------------------------------------------------
func _c7_fringe(n: int) -> void:
	print("[c7] fringe: in-range near-corner cells are home-face-independent (reached from a neighbour home face)")
	var cols := 0
	var div := 0
	for off: int in [1, 2, 3]:
		var ci: int = (n - 1) - off
		var cj: int = (n - 1) - off
		var base := _gen_col(4, ci, cj)                    # homed on the true face 4
		for h: int in range(6):
			if h == 4:
				continue
			var uw: Dictionary = CS.unfold_to_window(h, 4, ci, cj, n)
			if not bool(uw["found"]):
				continue
			var alt := _gen_col(h, int(uw["i"]), int(uw["j"]))
			cols += 1
			if not _cols_equal(base, alt):
				div += 1
	_ok(cols > 0, "the fringe sweep reached near-corner cells from neighbour home faces (%d)" % cols)
	_ok(div == 0, "fringe strip cells are byte-identical across home-face epochs (%d divergences)" % div)
