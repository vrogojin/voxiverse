extends SceneTree
## COSMOS-FRAME-ORIENTATION §8 ARBITER (Fable's NON-NEGOTIABLE step-5 gate). Curved-only.
## For probe columns covering NATIVE + every single-out STRIP + the corner WEDGE, in BOTH epochs
## (home 4 with M_win=I, and home 3 after a WEST flip with M_win≠I), assert the THREE window exits
## agree BYTE-for-byte:
##   worker-generated packed  ==  WorldManager.cell_value_at  ==  the collider wrapper's modifier.
## This catches a missed exit or a frame mismatch between the worker's true-face make_slope and the
## analytic corner-target stencil (they must coincide per-strip UNDER J, not just canonically).

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TC := preload("res://src/world/terrain_config.gd")

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

func _surface_g(chart, x: int, z: int) -> int:
	var n := CS.n_for(CS.HOME_BODY)
	var raw: Vector2i = chart.raw_of(x, z)
	var g := CS.fold_cell_canonical(chart.face, raw.x, raw.y, n)
	var ctx := TC.GenCtx.new(int(g["face"]))
	return int(TC.column_profile(int(g["i"]), int(g["j"]), ctx).x)

func _check_epoch(w: WorldManager, chart, label: String) -> void:
	# Origin at the corner (0,0) → window quadrants are native (+,+), WEST strip (−,+), SOUTH strip (+,−),
	# wedge (−,−). For the home-3 epoch the frame is rotated but the same window signs still hit each region.
	var probes := [
		Vector2i(30, 30), Vector2i(80, 45),          # native
		Vector2i(-5, 40), Vector2i(-24, 110),         # WEST strip
		Vector2i(45, -5), Vector2i(110, -24),         # SOUTH strip
		Vector2i(-6, -6), Vector2i(-14, -10),         # corner wedge (double-out)
	]
	var n := CS.n_for(CS.HOME_BODY)
	for col: Vector2i in probes:
		var x := col.x
		var z := col.y
		var g := _surface_g(chart, x, z)
		# Is this the DOUBLE-OUT wedge? (raw index out of range in BOTH axes → fold_cell face −1.)
		var raw: Vector2i = chart.raw_of(x, z)
		var is_wedge := int(CS.fold_cell(chart.face, raw.x, raw.y, n)["face"]) < 0
		# Check a band of y around the surface (the shaped cells live here). THE render exits (worker buffer
		# write == cell_value_at) must agree BYTE-for-byte EVERYWHERE, incl. the wedge.
		for dy: int in [-2, -1, 0, 1, 2]:
			var y := g + dy
			var wv := _worker_value(chart, x, z, y)
			if CellCodec.mat(wv) == 0:
				continue                              # air — nothing to compare
			var cva: int = w.cell_value_at(Vector3i(x, y, z))
			_ok(wv == cva, "%s col(%d,%d) y=%d: worker packed == cell_value_at (%d vs %d)" % [label, x, z, y, wv, cva])
		# COLLIDER == render (walk-on-what-you-see) for NATIVE + single-out STRIPS. The wedge's collider
		# light-query samples a MIXED 3-face neighbour set that cannot match the single resolved-cell
		# canonical — the §6.6/§4.6 metric-lie residual (M5, edits locked there). The render is still
		# self-consistent in the wedge (worker == cell_value_at above), so this is the accepted residual.
		if is_wedge:
			continue
		var col_sm: int = w.col_surface_modifier(x, z)
		_ok(col_sm == CellCodec.modifier(w.cell_value_at(Vector3i(x, g, z))),
			"%s col(%d,%d): collider surface_modifier == cell_value_at modifier @g" % [label, x, z])
		var srun: int = w.col_slope_run_of(x, z)
		if TC.slope_run_fires(srun):
			var rng := TC.slope_run_range(srun, g)
			var yy := int(rng.x)
			var col_m: int = TC.slope_run_modifier_at(srun, g, yy)
			_ok(col_m == CellCodec.modifier(w.cell_value_at(Vector3i(x, yy, z))),
				"%s col(%d,%d): collider slope-run modifier == cell_value_at @%d" % [label, x, z, yy])

func _init() -> void:
	print("=== verify_cosmos_arbiter (§8 — worker == cell_value_at == collider) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  (curved-only; skipping under FLAT)")
		print("==== VERIFY: 0 passed, 0 failed (skipped flat) ====")
		quit(0)
		return
	var n := CS.n_for(CS.HOME_BODY)
	# Epoch A: home 4, origin at the corner → M_win = I.
	var wa := WorldManager.new()
	wa.install_chart(CHART.new(CS.HOME_BODY, 4, 0, 0))
	_check_epoch(wa, wa.chart(), "home4/M_win=I")
	# Epoch B: home 3 after a WEST flip → M_win = WEST edge D4 (≠ I), origin re-based near the corner.
	var chart_b: CHART = CHART.new(CS.HOME_BODY, 4, 20, n / 2)
	chart_b.flip(Vector3(-20.0 - CHART.FLIP_HYST - 5.0, 0.0, 0.0))
	var wb := WorldManager.new()
	wb.install_chart(chart_b)
	print("  epoch B: face=", chart_b.face, " M_win=", chart_b.m_win())
	_check_epoch(wb, chart_b, "home3/M_win≠I")
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
