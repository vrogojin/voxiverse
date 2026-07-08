extends SceneTree
## COSMOS-FRAME-ORIENTATION §8 ARBITER (Fable's NON-NEGOTIABLE step-5 gate; steelman-hardened).
## For every single-out STRIP (all 4 D4s) + the corner WEDGE, in BOTH epochs (home 4 with M_win=I, and a
## flipped home-3 chart with M_win≠I), assert the window exits agree BYTE-for-byte:
##   worker-generated packed == WorldManager.cell_value_at == the collider wrapper's modifier.
## Steelman fix: it SEARCHES each strip for a cell with a nonzero SURFACE MODIFIER (smoothing ramp) AND a
## FIRING SLOPE (found on the neighbour face, then the edge fold is INVERTED to the exact window cell so any
## D4 strip at any depth is reachable) and FAILS LOUDLY if either is not found — so the byte-equality is
## validated on genuinely SHAPED cells (slopes AND ramps), not silently on full cubes.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TC := preload("res://src/world/terrain_config.gd")
const NONE := 0x7fffffff

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# The worker's WINDOW-frame packed value at window (x,z,y): fold → canonical resolve_cell → rotate by the
# column's J⁻¹ at the buffer-write exit (exactly what module_world does).
func _worker_value(chart, x: int, z: int, y: int) -> int:
	var ctx := TC.GenCtx.new(chart.face)
	var raw: Vector2i = chart.raw_of(x, z)
	var tc: Vector3i = TC.worker_fold_column(chart.face, raw.x, raw.y, ctx, CS.d4_of(chart.m_win()))
	var p: Vector4 = TC.column_profile(tc.y, tc.z, ctx)
	var srun := TC.slope_run_of(tc.y, tc.z, ctx)
	var v := TC.resolve_cell(tc.y, y, tc.z, int(p.x), int(p.y), p.z, p.w, ctx, srun)   # CANONICAL
	var m := CellCodec.modifier(v)
	if ctx.jinv_d4 != 0 and m != 0:
		v = CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(m, ctx.jinv_d4))       # window exit
	return v

func _surface_g_true(f: int, i: int, j: int) -> int:
	return int(TC.column_profile(i, j, TC.GenCtx.new(f)).x)

# Coarse full-face scan of face F for a FIRING SLOPE (want_slope) or a nonzero SURFACE MODIFIER (ramp).
# Faces reliably carry both (mountains + gentle gradients), so this finds one; returns (i,j) or NONE.
func _find_on_face(f: int, want_slope: bool) -> Vector2i:
	var n := CS.n_for(CS.HOME_BODY)
	var stride := maxi(n / 140, 1)
	for i in range(6, n - 6, stride):
		for j in range(6, n - 6, stride):
			var ctx := TC.GenCtx.new(f)
			if want_slope:
				if TC.slope_run_fires(TC.slope_run_of(i, j, ctx)):
					return Vector2i(i, j)
			else:
				if TC.surface_modifier(i, j, ctx) != 0 or TC.surface_cap_modifier(i, j, ctx) != 0:
					return Vector2i(i, j)
	return Vector2i(NONE, 0)

# Invert a single-edge fold: the RAW home-face index (past edge `side`) that folds to (F, ti, tj).
# edge_remap gives (M, t) with p_true = M·p_raw + t (det +1), so p_raw = M⁻¹·(p_true − t).
func _raw_for_neighbour(home: int, side: int, ti: int, tj: int) -> Vector2i:
	var n := CS.n_for(CS.HOME_BODY)
	var e := CS.edge_remap(home, side, n)
	var m: Array = e["m"]
	var t: Array = e["t"]
	var a := int(m[0]); var b := int(m[1]); var c := int(m[2]); var d := int(m[3])
	var px := ti - int(t[0]); var py := tj - int(t[1])
	return Vector2i(d * px - b * py, -c * px + a * py)   # [[d,-b],[-c,a]] · (px,py), det +1

# worker==cell_value_at over a y-band; collider==render at g + slope-run cells (skipped in the wedge).
func _assert_cell(w: WorldManager, chart, x: int, z: int, label: String, is_wedge: bool) -> void:
	var raw: Vector2i = chart.raw_of(x, z)
	var gc := CS.fold_cell_canonical(chart.face, raw.x, raw.y, CS.n_for(CS.HOME_BODY))
	var g := _surface_g_true(int(gc["face"]), int(gc["i"]), int(gc["j"]))
	var shaped_seen := false
	for dy: int in [-2, -1, 0, 1, 2, 3]:
		var y := g + dy
		var wv := _worker_value(chart, x, z, y)
		if CellCodec.mat(wv) == 0:
			continue
		if CellCodec.modifier(wv) != 0:
			shaped_seen = true
		var cva: int = w.cell_value_at(Vector3i(x, y, z))
		_ok(wv == cva, "%s (%d,%d) y=%d: worker packed == cell_value_at (%d vs %d)" % [label, x, z, y, wv, cva])
	_ok(shaped_seen, "%s (%d,%d): the probe cell is genuinely SHAPED (nonzero modifier in the y-band)" % [label, x, z])
	if is_wedge:
		return
	var col_sm: int = w.col_surface_modifier(x, z)
	_ok(col_sm == CellCodec.modifier(w.cell_value_at(Vector3i(x, g, z))),
		"%s (%d,%d): collider surface_modifier == cell_value_at modifier @g" % [label, x, z])
	var srun: int = w.col_slope_run_of(x, z)
	if TC.slope_run_fires(srun):
		var rng := TC.slope_run_range(srun, g)
		for yy: int in [int(rng.x), int((rng.x + rng.y) / 2), int(rng.y) - 1]:
			if yy < int(rng.x) or yy > int(rng.y) - 1:
				continue
			_ok(TC.slope_run_modifier_at(srun, g, yy) == CellCodec.modifier(w.cell_value_at(Vector3i(x, yy, z))),
				"%s (%d,%d): collider slope-run modifier == cell_value_at @%d" % [label, x, z, yy])

# Test one strip: find a ramp AND a firing slope on the neighbour face, invert the fold to the window cell,
# assert the three exits agree. FAILS if either shape class is not found.
func _check_strip(w: WorldManager, chart, side: int, epoch: String) -> void:
	var n := CS.n_for(CS.HOME_BODY)
	var side_name: String = {0: "EAST", 1: "WEST", 2: "NORTH", 3: "SOUTH"}[side]
	var nf := int(CS.edge_remap(chart.face, side, n)["b"])
	var d4 := CS.d4_of(CS.edge_remap(chart.face, side, n)["m"])
	for want_slope: bool in [false, true]:
		var kind := "slope" if want_slope else "ramp"
		var cell := _find_on_face(nf, want_slope)
		if cell.x == NONE:
			_ok(false, "%s %s(d4=%d)→F%d: FOUND a %s on the neighbour face" % [epoch, side_name, d4, nf, kind])
			continue
		var raw: Vector2i = _raw_for_neighbour(chart.face, side, cell.x, cell.y)
		# Sanity: raw is genuinely a SINGLE-OUT strip cell of this side, folding back to (nf, cell).
		var back := CS.fold_cell(chart.face, raw.x, raw.y, n)
		if int(back["face"]) != nf or int(back["i"]) != cell.x or int(back["j"]) != cell.y:
			_ok(false, "%s %s %s: fold-inversion consistency (raw %s → %s, want F%d %s)" % [epoch, side_name, kind, str(raw), str(back), nf, str(cell)])
			continue
		var win: Vector2i = chart.window_of(raw.x, raw.y)
		print("  [cover] %s %s(d4=%d) %s @win(%d,%d) → F%d(%d,%d)" % [epoch, side_name, d4, kind, win.x, win.y, nf, cell.x, cell.y])
		_assert_cell(w, chart, win.x, win.y, "%s %s %s" % [epoch, side_name, kind], false)

func _check_wedge(w: WorldManager, chart, epoch: String) -> void:
	var n := CS.n_for(CS.HOME_BODY)
	# Scan double-out raw cells near the corner for a shaped/slope column; assert worker==cell_value_at (the
	# render is self-consistent). The collider light-query in the wedge is the §6.6/§4.6 M5 residual (skipped).
	var found := false
	for depth: int in [2, 3, 4, 6, 8, 12, 20, 32]:
		for t2: int in [2, 3, 4, 6, 8, 12, 20, 32]:
			var ri := -depth
			var rj := -t2
			var g := CS.fold_cell_canonical(chart.face, ri, rj, n)
			if int(g["face"]) < 0:
				continue
			var ctx := TC.GenCtx.new(int(g["face"]))
			if TC.surface_modifier(int(g["i"]), int(g["j"]), ctx) == 0 and not TC.slope_run_fires(TC.slope_run_of(int(g["i"]), int(g["j"]), ctx)):
				continue
			var win: Vector2i = chart.window_of(ri, rj)
			_ok(true, "%s wedge: shaped double-out column @win(%d,%d)" % [epoch, win.x, win.y])
			_assert_cell(w, chart, win.x, win.y, "%s wedge" % epoch, true)
			found = true
			break
		if found:
			break
	_ok(found, "%s wedge: found a shaped double-out column" % epoch)

func _init() -> void:
	print("=== verify_cosmos_arbiter (§8 — worker == cell_value_at == collider, steelman-hardened) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — needs FLAT_WORLD=false to exercise the curved worker/collider paths. NOT A PASS.")
		print("==== VERIFY: SKIPPED (curved-only gate) ====")
		quit(2)                                     # sentinel: distinct from a real pass (0) or fail (1)
		return
	var n := CS.n_for(CS.HOME_BODY)
	# Epoch A: home 4, M_win = I. All 4 strips reachable (the fold inversion picks the window cell).
	var wa := WorldManager.new()
	wa.install_chart(CHART.new(CS.HOME_BODY, 4, 0, 0))
	for side in [CS.SIDE_WEST, CS.SIDE_EAST, CS.SIDE_NORTH, CS.SIDE_SOUTH]:
		_check_strip(wa, wa.chart(), side, "A:home4/M_win=I")
	_check_wedge(wa, wa.chart(), "A:home4/M_win=I")

	# Epoch B: home 3 after a WEST flip → M_win = WEST edge D4 (≠ I). Exercises the M_win≠I collider rotation
	# across all four of face-3's strips (different D4s).
	var chart_b: CHART = CHART.new(CS.HOME_BODY, 4, 20, n / 2)
	chart_b.flip(Vector3(-20.0 - CHART.FLIP_HYST - 5.0, 0.0, 0.0))
	var wb := WorldManager.new()
	wb.install_chart(chart_b)
	print("  epoch B: face=", chart_b.face, " M_win=", chart_b.m_win())
	for side in [CS.SIDE_WEST, CS.SIDE_EAST, CS.SIDE_NORTH, CS.SIDE_SOUTH]:
		_check_strip(wb, chart_b, side, "B:home3/M_win≠I")
	_check_wedge(wb, chart_b, "B:home3/M_win≠I")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
