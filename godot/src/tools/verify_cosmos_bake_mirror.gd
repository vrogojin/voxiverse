extends SceneTree
## COSMOS R2.1 gate — the PACKED-TABLE bake mirror (docs/COSMOS-REAL-GEOMETRY-STUDY §2). The near voxel
## field bakes inside the godot_voxel C++ mesher; to keep cube topology out of the C++ (the fold-table
## sign/index class that scrambled the shader twice), CosmosTruePlace.pack_bake_params + bake_place_packed
## are the EXACT arithmetic the C++ will run — pure numbers, no chart access. This gate proves that mirror
## equals the gate-proven place_true(node_origin + v) across HOME cells, all four EDGE strips, and the
## double-out CORNER (both must return wedge), so the C++ becomes a mechanical transcription validated
## BEFORE any 24-minute engine rebuild. Curved-only (loud-skip + exit 2 under FLAT — the toggle discipline).

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

func _init() -> void:
	print("=== verify_cosmos_bake_mirror (R2.1 packed-table C++ mirror) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — near bake mirror is curved-only; needs FLAT_WORLD=false. NOT A PASS.")
		print("==== VERIFY: SKIPPED (curved-only gate) ====")
		quit(2)
		return
	# Corner-origin chart (face 4, org 0) so a window sweep crosses BOTH face edges and the double-out
	# corner — every branch of the fold. node_origin = ZERO at org 0, so w == v here (the identity is
	# still exercised at a non-zero anchor via the y term + mt).
	var chart: CHART = CHART.new(CS.HOME_BODY, 4, 0, 0)
	var node_origin: Vector3 = chart.node_origin()
	var anchor := Vector3(40.0, 4.0, 40.0)
	var frame := TP.bake_frame(chart, anchor)
	var params := TP.pack_bake_params(chart, frame)
	var n := chart.n

	# ---- T1: mirror == place_true across HOME + EDGE strips (a band straddling each face edge) ----
	var worst_home := 0.0
	var worst_edge := 0.0
	var n_home := 0
	var n_edge := 0
	# Sweep window x from just inside WEST (−12) to just past EAST (n+12), z fixed mid-face, plus a
	# vertical band across NORTH/SOUTH — covering home interior and all four single-edge strips.
	for vy in [0.0, 4.0, 60.0]:
		for step in range(-12, 13):
			# EAST/WEST strip: vary x near the i-edges, z safely mid-face.
			for base_x in [0, n]:
				var vx := float(base_x + step)
				var vz := float(n / 2)
				_cmp(chart, node_origin, frame, params, vx, vy, vz, true)
			# NORTH/SOUTH strip: vary z near the j-edges, x safely mid-face.
			for base_z in [0, n]:
				var vx2 := float(n / 2)
				var vz2 := float(base_z + step)
				_cmp(chart, node_origin, frame, params, vx2, vy, vz2, true)
	worst_home = _worst_in
	n_home = _n_in
	worst_edge = _worst_out
	n_edge = _n_out
	_ok(n_home > 20 and worst_home < 1e-3, "T1 home-cell parity: mirror == place_true (worst %.8f blk, %d pts)" % [worst_home, n_home])
	_ok(n_edge > 20 and worst_edge < 1e-3, "T2 edge-strip parity: mirror == place_true across all 4 folds (worst %.8f blk, %d pts)" % [worst_edge, n_edge])

	# ---- T3: the double-out CORNER quadrant — both must classify as wedge (mirror sentinel == place_true) ----
	var corner_agree := 0
	var corner_total := 0
	for dx in range(1, 10):
		for dz in range(1, 10):
			# Past EAST *and* NORTH → corner quadrant (double-out) → wedge.
			var vx := float(n + dx)
			var vz := float(n + dz)
			var mp := TP.bake_place_packed(params, vx, 4.0, vz)
			var tp := TP.place_true(chart, Vector3(node_origin.x + vx, 4.0, node_origin.z + vz), frame)
			corner_total += 1
			if mp == TP._WEDGE and tp == TP._WEDGE:
				corner_agree += 1
	_ok(corner_total > 50 and corner_agree == corner_total, "T3 corner-wedge parity: mirror wedge == place_true wedge (%d/%d)" % [corner_agree, corner_total])

	# ---- T4: radial normal parity (mirror radial == place_and_radial radial) on a home + edge sample ----
	var worst_rad := 0.0
	var n_rad := 0
	for step in range(-8, 9):
		for base_x in [0, n]:
			var vx := float(base_x + step)
			var vz := float(n / 2)
			var pr := TP.place_and_radial(chart, Vector3(node_origin.x + vx, 4.0, node_origin.z + vz), frame)
			if pr["pos"] == TP._WEDGE:
				continue
			var mr := TP.bake_radial_packed(params, vx, 4.0, vz)
			worst_rad = maxf(worst_rad, (mr - (pr["radial"] as Vector3)).length())
			n_rad += 1
	_ok(n_rad > 10 and worst_rad < 1e-4, "T4 radial-normal parity: mirror radial == place_and_radial (worst %.8f, %d pts)" % [worst_rad, n_rad])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# accumulators for _cmp (home vs edge split)
var _worst_in := 0.0
var _n_in := 0
var _worst_out := 0.0
var _n_out := 0
func _cmp(chart, node_origin: Vector3, frame: Dictionary, params: Dictionary, vx: float, vy: float, vz: float, _split: bool) -> void:
	var mp := TP.bake_place_packed(params, vx, vy, vz)
	var w := Vector3(node_origin.x + vx, vy, node_origin.z + vz)
	var tp := TP.place_true(chart, w, frame)
	# Classify by whether place_true says home (in-range) vs folded/edge, via the raw index.
	var px := float(chart.mw_a) * vx + float(chart.mw_b) * vz
	var pz := float(chart.mw_c) * vx + float(chart.mw_d) * vz
	var in_home := px >= 0.0 and px < float(chart.n) and pz >= 0.0 and pz < float(chart.n)
	if mp == TP._WEDGE or tp == TP._WEDGE:
		return                                          # corner handled in T3
	var e := (mp - tp).length()
	if in_home:
		_worst_in = maxf(_worst_in, e); _n_in += 1
	else:
		_worst_out = maxf(_worst_out, e); _n_out += 1
