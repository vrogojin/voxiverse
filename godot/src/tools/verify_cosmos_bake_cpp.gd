extends SceneTree
## COSMOS R2.1 gate — the COMPILED C++ near bake (docs/COSMOS-REAL-GEOMETRY-STUDY §2). The mirror gate
## (verify_cosmos_bake_mirror) proved the ARITHMETIC == place_true; this proves the C++ TRANSCRIPTION of it
## (cosmos_bake.h) is faithful — catching type/typo/packing slips that only exist in the compiled module.
## It pushes CosmosTruePlace.pack_bake_params_flat into a VoxelMesherBlocky via set_cosmos_bake and asserts
## the bound cosmos_debug_place() equals place_true across home cells, all four edge folds, and the corner
## wedge. Requires the module built WITH patch 0003 (cosmos_debug_place bound); loud-skip otherwise. Curved
## sweep math is topology-only, so it does not need FLAT_WORLD=false — but stays curved-gated for hygiene.

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
	print("=== verify_cosmos_bake_cpp (R2.1 COMPILED C++ bake) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — near bake is curved-only. NOT A PASS."); print("==== VERIFY: SKIPPED ===="); quit(2); return
	if not ClassDB.class_exists("VoxelMesherBlocky"):
		print("  SKIPPED — godot_voxel module absent (no VoxelMesherBlocky). NOT A PASS."); print("==== VERIFY: SKIPPED ===="); quit(2); return
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if mesher == null or not mesher.has_method("cosmos_debug_place") or not mesher.has_method("set_cosmos_bake"):
		print("  SKIPPED — engine built WITHOUT patch 0003 (cosmos_debug_place unbound). Rebuild required. NOT A PASS.")
		print("==== VERIFY: SKIPPED ===="); quit(2); return

	var chart: CHART = CHART.new(CS.HOME_BODY, 4, 0, 0)
	var node_origin: Vector3 = chart.node_origin()
	var anchor := Vector3(40.0, 4.0, 40.0)
	var frame := TP.bake_frame(chart, anchor)
	mesher.call("set_cosmos_bake", TP.pack_bake_params_flat(chart, frame))
	var n := chart.n
	var wedge := Vector3(1.0e18, 1.0e18, 1.0e18)

	var worst_home := 0.0; var n_home := 0
	var worst_edge := 0.0; var n_edge := 0
	for vy in [0.0, 4.0, 60.0]:
		for step in range(-12, 13):
			for base_x in [0, n]:
				var vx := float(base_x + step)
				var vz := float(n / 2)
				_cmp(chart, node_origin, frame, mesher, vx, vy, vz)
			for base_z in [0, n]:
				var vx2 := float(n / 2)
				var vz2 := float(base_z + step)
				_cmp(chart, node_origin, frame, mesher, vx2, vy, vz2)
	worst_home = _worst_in; n_home = _n_in; worst_edge = _worst_out; n_edge = _n_out
	_ok(n_home > 20 and worst_home < 2e-3, "T1 home-cell: compiled C++ == place_true (worst %.7f blk, %d pts)" % [worst_home, n_home])
	_ok(n_edge > 20 and worst_edge < 2e-3, "T2 edge-strip: compiled C++ == place_true across 4 folds (worst %.7f blk, %d pts)" % [worst_edge, n_edge])

	var corner_agree := 0; var corner_total := 0
	for dx in range(1, 10):
		for dz in range(1, 10):
			var vx := float(n + dx); var vz := float(n + dz)
			var cp: Vector3 = mesher.call("cosmos_debug_place", vx, 4.0, vz)
			var tp := TP.place_true(chart, Vector3(node_origin.x + vx, 4.0, node_origin.z + vz), frame)
			corner_total += 1
			if cp == wedge and tp == TP._WEDGE:
				corner_agree += 1
	_ok(corner_total > 50 and corner_agree == corner_total, "T3 corner-wedge: compiled C++ wedge == place_true wedge (%d/%d)" % [corner_agree, corner_total])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

var _worst_in := 0.0
var _n_in := 0
var _worst_out := 0.0
var _n_out := 0
func _cmp(chart, node_origin: Vector3, frame: Dictionary, mesher: Object, vx: float, vy: float, vz: float) -> void:
	var cp: Vector3 = mesher.call("cosmos_debug_place", vx, vy, vz)
	var tp := TP.place_true(chart, Vector3(node_origin.x + vx, vy, node_origin.z + vz), frame)
	if cp == Vector3(1.0e18, 1.0e18, 1.0e18) or tp == TP._WEDGE:
		return
	var px := float(chart.mw_a) * vx + float(chart.mw_b) * vz
	var pz := float(chart.mw_c) * vx + float(chart.mw_d) * vz
	var in_home := px >= 0.0 and px < float(chart.n) and pz >= 0.0 and pz < float(chart.n)
	var e := (cp - tp).length()
	if in_home:
		_worst_in = maxf(_worst_in, e)
		_n_in += 1
	else:
		_worst_out = maxf(_worst_out, e)
		_n_out += 1
