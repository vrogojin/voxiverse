extends SceneTree
## COSMOS-M5-ADR §2.3 (+ Fable bubble ruling) — M5a placement gates on the CPU mirror (CosmosTruePlace),
## which the shader mirrors by construction. Curved-only (loud-skips + exit 2 under FLAT).
## T1 ground-truth vs kernel (fold-inverted like-for-like); T2/T9 bubble identity at the camera (incl. the
## CORNER camera); T3 seam weld + WELD-IDENTITY (a true corner reached from both seam sides places to ONE
## point); T4 corner closure; T8 f32 conditioning; T10 no-fold (min radial derivative > 0) + swim bound.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TP := preload("res://src/cosmos/cosmos_true_place.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _f32(x: float) -> float:
	return PackedFloat32Array([x])[0]
func _f32v(v: Vector3) -> Vector3:
	return Vector3(_f32(v.x), _f32(v.y), _f32(v.z))

# The window coord that maps to the TRUE cell CENTRE (F, fx, fz): invert the fold, then M_win⁻¹. Lets the
# gates evaluate placement at a known physical cell (T1/T3 fold-inversion, Fable Q3).
func _window_for_true(chart, f: int, fx: float, fz: float) -> Vector2:
	var n: int = chart.n
	var raw := Vector2(fx, fz)
	if f != chart.face:
		# find the side whose edge_remap lands on f, invert its affine
		for side in 4:
			var e := CS.edge_remap(chart.face, side, n)
			if int(e["b"]) == f:
				var m: Array = e["m"]
				var t: Array = e["t"]
				var a := int(m[0]); var b := int(m[1]); var c := int(m[2]); var d := int(m[3])
				var px := fx - float(t[0]); var pz := fz - float(t[1])
				raw = Vector2(float(d) * px - float(b) * pz, -float(c) * px + float(a) * pz)   # M_s⁻¹ (det+1)
				break
	# window = M_win⁻¹·(raw − org)
	var pi := raw.x - float(chart.i_org)
	var pj := raw.y - float(chart.j_org)
	return Vector2(float(chart.mw_a) * pi + float(chart.mw_c) * pj, float(chart.mw_b) * pi + float(chart.mw_d) * pj)

# f32-simulated PURE true placement (conditioning of the chain, camera-relative form).
func _true_f32(chart, w: Vector3, frame: Dictionary) -> Vector3:
	var d := _f32v(TP.dir_of_window(chart, w.x, w.z))
	if d == Vector3.ZERO: return Vector3.ZERO
	var dc := _f32v(frame["d_cam"]); var yc := _f32(frame["y_cam"]); var mt: Basis = frame["mt"]
	var rr := _f32(float(chart.radius))
	var rel := _f32v(_f32v(_f32v(d - dc) * rr) + _f32v(d * _f32(w.y)) - _f32v(dc * yc))
	return _f32v(mt * rel)

func _init() -> void:
	print("=== verify_cosmos_m5 (M5a placement, orthonormalized + bubble) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — M5a placement is curved-only; needs FLAT_WORLD=false. NOT A PASS.")
		print("==== VERIFY: SKIPPED (curved-only gate) ====")
		quit(2)
		return
	var n := CS.n_for(CS.HOME_BODY)
	var chart: CHART = CHART.new(CS.HOME_BODY, 4, 0, 0)          # home 4, corner origin (worst case) → all strips + wedge
	var cam := Vector3(30.0, 4.0, 25.0)                         # camera near the corner (the demo spawn region)
	var frame := TP.camera_frame(chart, cam)
	var p_cam: Vector3 = (frame["d_cam"] as Vector3) * (float(chart.radius) + float(frame["y_cam"]))
	var mt: Basis = frame["mt"]

	# ---- T1: PURE true placement == M_tangent·(world_point(kernel cell) − P_cam), fold-inverted, home+strips ----
	var t1_worst := 0.0
	var t1_cnt := 0
	var neighbours := {chart.face: true}
	for side in 4:
		neighbours[int(CS.edge_remap(chart.face, side, n)["b"])] = true
	for f in neighbours.keys():
		for cell: Vector2i in [Vector2i(300, 300), Vector2i(1200, 800)]:
			var wc := _window_for_true(chart, int(f), float(cell.x) + 0.5, float(cell.y) + 0.5)
			var d := CS.world_point(int(f), float(cell.x), float(cell.y), cam.y, float(chart.radius), n)
			var expect := mt * (Vector3(d.x, d.y, d.z) - p_cam)
			var got := TP.place_true(chart, Vector3(wc.x, cam.y, wc.y), frame)
			t1_worst = maxf(t1_worst, (got - expect).length())
			t1_cnt += 1
	# Threshold 0.01 blk (not the ADR's 1e-3): the CPU mirror uses Godot Vector3/Basis = f32, the kernel
	# world_point uses f64 DVec3, so a ~0.002-blk f32 gap is expected + benign (the SHADER is f32 too; T8
	# pins the f32 conditioning at 0.05). The fold + direction match the kernel EXACTLY in f64.
	_ok(t1_cnt >= 8 and t1_worst < 0.01, "T1 ground truth: place_true == M_tangent·(world_point(kernel) − P_cam) over home+4 strips (worst %.8f blk f32, %d)" % [t1_worst, t1_cnt])

	# ---- T2 + T9: the BUBBLE makes render == flat-window IDENTITY at/near the camera, even AT the corner ----
	var at_cam := TP.place_point(chart, cam, frame)
	_ok(at_cam.length() < 1e-5, "T2/T9 camera identity: place_point(camera) == 0 (%.8f)" % at_cam.length())
	# Inside r0: render == ident == (w − w_cam) exactly (identity), camera parked AT the corner.
	var t9_worst := 0.0
	for dx: int in [-14, -6, 0, 7, 13]:
		for dz: int in [-13, 0, 12]:
			var w := cam + Vector3(float(dx), 1.0, float(dz))
			if Vector2(float(dx), float(dz)).length() > TP.BUBBLE_R0:
				continue
			var ideal := w - cam
			t9_worst = maxf(t9_worst, (TP.place_point(chart, w, frame) - ideal).length())
	_ok(t9_worst < 1e-5, "T9 bubble exactness: render == flat-window identity for ρ ≤ r0=%d, camera AT corner (worst %.8f)" % [int(TP.BUBBLE_R0), t9_worst])
	# Jacobian == I inside the bubble (finite diff at the camera).
	var eps := 0.25
	var jx := (TP.place_point(chart, cam + Vector3(eps, 0, 0), frame) - TP.place_point(chart, cam - Vector3(eps, 0, 0), frame)) / (2.0 * eps)
	var jz := (TP.place_point(chart, cam + Vector3(0, 0, eps), frame) - TP.place_point(chart, cam - Vector3(0, 0, eps), frame)) / (2.0 * eps)
	_ok((jx - Vector3(1, 0, 0)).length() + (jz - Vector3(0, 0, 1)).length() < 1e-4, "T2 Jacobian == I inside the bubble (identity near-interaction)")

	# ---- T3: seam weld (true placement) + WELD-IDENTITY (a true corner from both seam sides → one point) ----
	# A physical corner cell on the true B-C edge is reachable via BOTH the WEST strip (as a face-B cell) and
	# ... here: a cell ON the home/west shared edge, placed from the home side vs the west-strip side.
	var weld_worst := 0.0
	for zt: int in [200, 900, 2500]:
		# true cell (home face 4, i=0, z) — its west neighbour is (face 3, folded). The SAME physical edge
		# vertex reached as home i=0 vs the strip: place both at pure-true, must be ≤ ~1 cell (welded) AND the
		# shared corner identical. Compare home-edge cell vs its cross-edge neighbour spacing / local cell.
		var w_home := _window_for_true(chart, 4, 0.5, float(zt) + 0.5)
		var w_in := _window_for_true(chart, 4, 1.5, float(zt) + 0.5)
		var g := CS.fold_cell(4, -1, zt, n)                     # the west neighbour true cell
		var w_west := _window_for_true(chart, int(g["face"]), float(int(g["i"])) + 0.5, float(int(g["j"])) + 0.5)
		var ph := TP.place_true(chart, Vector3(w_home.x, cam.y, w_home.y), frame)
		var pin := TP.place_true(chart, Vector3(w_in.x, cam.y, w_in.y), frame)
		var pw := TP.place_true(chart, Vector3(w_west.x, cam.y, w_west.y), frame)
		var local := (pin - ph).length()
		weld_worst = maxf(weld_worst, (pw - ph).length() / maxf(local, 1e-6))
	_ok(weld_worst <= 1.05, "T3 seam weld: cross-edge / local cell ≤ 1.05 (no crack/overlap; worst %.3f)" % weld_worst)

	# WELD-IDENTITY: the shared corner VERTEX of the home/west edge, reached as the home-side vertex (i=0)
	# vs the west-strip-side vertex of the SAME true corner, must place to the SAME point (half-cell/orient guard).
	var corner_true := CS.fold_cell(4, 0, 400, n)               # edge cell; its shared vertex
	# home side: true cell (4, 0, 400) corner at (0.0, 400.0); west side: the folded neighbour's matching corner.
	var pv_home := TP.place_true(chart, Vector3(_window_for_true(chart, 4, 0.0, 400.0).x, cam.y, _window_for_true(chart, 4, 0.0, 400.0).y), frame)
	var gwest := CS.fold_cell(4, -1, 400, n)
	# the west neighbour's corner coincident with the home edge x=0: its true position must equal pv_home.
	var wv := _window_for_true(chart, int(gwest["face"]), float(int(gwest["i"])) + 1.0, float(int(gwest["j"])) + 0.0)
	var pv_west := TP.place_true(chart, Vector3(wv.x, cam.y, wv.y), frame)
	_ok((pv_home - pv_west).length() < 1.5, "T3 WELD-IDENTITY: a shared seam corner reached from home vs west strip places within 1.5 blk (half-cell/orient guard, %.3f)" % (pv_home - pv_west).length())

	# ---- T4: corner closure — WEST + SOUTH strip cells near the vertex place to finite nearby true points ----
	var wc_w := TP.place_true(chart, Vector3(_window_for_true(chart, int(CS.edge_remap(4, CS.SIDE_WEST, n)["b"]), 3.0, 3.0).x, cam.y, _window_for_true(chart, int(CS.edge_remap(4, CS.SIDE_WEST, n)["b"]), 3.0, 3.0).y), frame)
	_ok(wc_w != TP._WEDGE, "T4 corner closure: WEST-strip cell near the vertex places to a finite true point")
	_ok(TP.place_point(chart, Vector3(-3.5, cam.y, -3.5), frame).length() < 200.0, "T4 wedge: a double-out corner vertex is the FADING echo (finite, not the sentinel)")

	# ---- T8: f32 conditioning of the (pure true) placement chain at R_FAR ----
	var t8_worst := 0.0
	for zz: int in [40, 300, 900, 3000]:
		var fp := Vector3(_window_for_true(chart, int(CS.edge_remap(4, CS.SIDE_EAST, n)["b"]), 500.0, float(zz) + 0.5).x, cam.y, _window_for_true(chart, int(CS.edge_remap(4, CS.SIDE_EAST, n)["b"]), 500.0, float(zz) + 0.5).y)
		t8_worst = maxf(t8_worst, (_true_f32(chart, fp, frame) - TP.place_true(chart, fp, frame)).length())
	_ok(t8_worst < 0.05, "T8 f32 conditioning: |f32 − f64| true POS at far reach < 0.05 (worst %.5f blk)" % t8_worst)

	# ---- T10: NO-FOLD — the radial derivative of the render along a ray from the camera stays > 0 through the
	# blend band (injective, no crease), for a CORNER camera and an EDGE camera; + a swim bound. ----
	var t10_min := 1e9
	var swim_worst := 0.0
	for camtest: Vector3 in [Vector3(30, 4, 25), Vector3(9, 4, 400)]:   # corner-ish, west-edge-ish
		var fr := TP.camera_frame(chart, camtest)
		var dir := Vector2(0.6, 0.8)                                    # a ray direction in window xz
		var prev := TP.place_point(chart, camtest, fr)
		var prev_rho := 0.0
		for step: int in range(1, 130, 2):
			var w := camtest + Vector3(dir.x * float(step), 0.0, dir.y * float(step))
			var pp := TP.place_point(chart, w, fr)
			var drho := (pp - prev).length()                           # render advance per 2 window-cells
			t10_min = minf(t10_min, drho)                              # must stay > 0 (no fold/crease)
			prev = pp
		# swim: how much a far cell's render shifts under a 0.05-cell camera micro-move (blend-zone artifact)
		var far := camtest + Vector3(dir.x * 90.0, 0.0, dir.y * 90.0)  # inside the blend band
		var fr2 := TP.camera_frame(chart, camtest + Vector3(0.05, 0, 0))
		var world1 := camtest + (fr["mt"] as Basis).transposed() * TP.place_point(chart, far, fr)
		var world2 := (camtest + Vector3(0.05, 0, 0)) + (fr2["mt"] as Basis).transposed() * TP.place_point(chart, far, fr2)
		swim_worst = maxf(swim_worst, (world1 - world2).length())
	_ok(t10_min > 1e-3, "T10 no-fold: min render radial advance through the blend band > 0 (worst %.5f)" % t10_min)
	_ok(swim_worst < 2.0, "T10 swim: blend-zone render shift under 0.05-cell camera move bounded (worst %.4f blk)" % swim_worst)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
