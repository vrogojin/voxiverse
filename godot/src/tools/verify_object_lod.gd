extends SceneTree
## COSMOS-OBJECT-LOD P0 gate (FP_OBJ_LOD). Certifies the pure LOD SELECTION LAW (ObjectLod) — the angular
## primitives, size→ladder derivation, coarsest-rung selection, one-sided sticky-DOT hysteresis (no-pop),
## class cull/beacon policy, and the never-OOM boot-budget pick. Pure math, runs FLAT.
## Run: godot --headless --path godot --script res://src/tools/verify_object_lod.gd

var _fail := 0
var _pass := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else: _fail += 1; push_error("FAIL: " + m); print("  FAIL: ", m)
func _near(a: float, b: float, m: String, eps := 0.05) -> void:
	_ok(absf(a - b) <= eps, "%s (got %f, want %f)" % [m, a, b])

const K := 771.3            # k_px(1080, 70°) reference — asserted in _test_primitives

func _initialize() -> void:
	_test_primitives()
	_test_sizing()
	_test_selection()
	_test_hysteresis()
	_test_cull()
	_test_budget()
	print("==== VERIFY-OBJECT-LOD: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _test_primitives() -> void:
	var k := ObjectLod.k_px(1080.0, deg_to_rad(70.0))
	_near(k, 771.3, "k_px(1080,70deg)", 1.0)
	_near(ObjectLod.proj_px(5.0, 1000.0, k), 7.713, "proj_px r5 d1000")
	_near(ObjectLod.sse_px(2.5, 1000.0, k), 1.928, "sse_px e2.5 d1000")
	_ok(ObjectLod.proj_px(5.0, 0.0, k) == 0.0, "proj_px d<=0 → 0")
	_ok(ObjectLod.k_px(1080.0, deg_to_rad(35.0)) > k, "narrower fov (zoom) raises k_px → promotes objects")

func _test_sizing() -> void:
	_ok(ObjectLod.mesh_pitches(10.0).is_empty(), "extent 10 (<16): no mesh rung")
	_ok(ObjectLod.step_count(10.0) == 0, "extent 10: 0 mesh steps")
	_ok(ObjectLod.mesh_pitches(16.0) == [4, 2], "extent 16: pitches [4,2]")
	_ok(ObjectLod.mesh_pitches(30.0) == [4, 2], "extent 30: pitches [4,2] (2 steps)")
	_ok(ObjectLod.mesh_pitches(512.0) == [128, 64, 32, 16, 8, 4, 2], "extent 512: 7 mesh steps, coarse→fine")
	_ok(ObjectLod.step_count(1024.0) == ObjectLod.MESH_STEP_MAX, "extent 1024: capped at MESH_STEP_MAX")
	_near(ObjectLod.rep_error(ObjectLod.REP_FULL, 0, 10.0), 0.0, "rep_error FULL = 0")
	_near(ObjectLod.rep_error(ObjectLod.REP_CARD, 0, 10.0), 5.0, "rep_error CARD = r/2")
	_near(ObjectLod.rep_error(ObjectLod.REP_DOT, 0, 10.0), 10.0, "rep_error DOT = r")
	_near(ObjectLod.rep_error(ObjectLod.REP_MESH, 4, 10.0), 4.0, "rep_error MESH = pitch")

func _test_selection() -> void:
	var k := ObjectLod.k_px(1080.0, deg_to_rad(70.0))
	# small object extent 10, r 5: FULL near → CARD → DOT far
	_ok(ObjectLod.rung_raw(5.0, 10.0, 1000.0, k)["rep"] == ObjectLod.REP_FULL, "r5 d1000 → FULL (card err > 1px)")
	_ok(ObjectLod.rung_raw(5.0, 10.0, 2500.0, k)["rep"] == ObjectLod.REP_CARD, "r5 d2500 → CARD")
	_ok(ObjectLod.rung_raw(5.0, 10.0, 4000.0, k)["rep"] == ObjectLod.REP_DOT, "r5 d4000 → DOT (proj < 2px)")
	# big object extent 512, r 256: decimated-mesh rungs kick in
	var big5000 := ObjectLod.rung_raw(256.0, 512.0, 5000.0, k)
	_ok(big5000["rep"] == ObjectLod.REP_MESH and int(big5000["pitch"]) == 4, "r256 d5000 → MESH pitch 4")
	var big50000 := ObjectLod.rung_raw(256.0, 512.0, 50000.0, k)
	_ok(big50000["rep"] == ObjectLod.REP_MESH and int(big50000["pitch"]) == 64, "r256 d50000 → MESH pitch 64")
	# selection is monotone in distance: rep never gets FINER as d grows
	var prev := ObjectLod.REP_FULL
	var mono := true
	for d in [1000.0, 3000.0, 6000.0, 12000.0, 30000.0, 80000.0, 200000.0]:
		var rep: int = ObjectLod.rung_raw(256.0, 512.0, d, k)["rep"]
		if rep > prev: mono = false
		prev = rep
	_ok(mono, "rung_raw monotone coarsening with distance")

func _test_hysteresis() -> void:
	var k := ObjectLod.k_px(1080.0, deg_to_rad(70.0))
	# r5: proj crosses P_POINT(2) at d = 2*5*k/2 = 5k ≈ 3856; the (1-HYST) knee 1.5px at d ≈ 5141.
	var d_band := 2.0 * 5.0 * k / 1.7          # proj ≈ 1.7px — inside the sticky band [1.5,2.0]
	_ok(ObjectLod.rung_hyst(ObjectLod.REP_DOT, 5.0, 10.0, d_band, k)["rep"] == ObjectLod.REP_DOT,
		"hyst: DOT stays DOT inside band (proj 1.7)")
	_ok(ObjectLod.rung_hyst(ObjectLod.REP_CARD, 5.0, 10.0, d_band, k)["rep"] != ObjectLod.REP_DOT,
		"hyst: CARD stays non-DOT inside band (no premature dot)")
	var d_below := 2.0 * 5.0 * k / 1.4         # proj ≈ 1.4px — below the band
	_ok(ObjectLod.rung_hyst(ObjectLod.REP_CARD, 5.0, 10.0, d_below, k)["rep"] == ObjectLod.REP_DOT,
		"hyst: CARD demotes to DOT below band (proj 1.4)")
	var d_above := 2.0 * 5.0 * k / 2.1         # proj ≈ 2.1px — above the band
	_ok(ObjectLod.rung_hyst(ObjectLod.REP_DOT, 5.0, 10.0, d_above, k)["rep"] != ObjectLod.REP_DOT,
		"hyst: DOT promotes out above band (proj 2.1)")
	# no-pop: the DOT⇄disc swap delta equals proj, bounded by P_POINT at the promote knee
	_ok(ObjectLod.swap_delta_px(5.0, 2.0 * 5.0 * k / ObjectLod.P_POINT, k) <= ObjectLod.P_POINT + 0.01,
		"no-pop: DOT swap delta ≤ P_POINT at the knee")

func _test_cull() -> void:
	# debris fades over [0.5,2] px and culls below 0.5; space never culls (clamps to a 2px beacon)
	var d1 := ObjectLod.cull(ObjectLod.CLASS_DEBRIS, 1.5)
	_ok(bool(d1["draw"]) and absf(float(d1["fade"]) - 0.6667) < 0.01, "debris proj1.5 → fade ~0.667")
	_ok(not bool(ObjectLod.cull(ObjectLod.CLASS_DEBRIS, 0.4)["draw"]), "debris proj0.4 → culled")
	var s := ObjectLod.cull(ObjectLod.CLASS_SPACE, 0.1)
	_ok(bool(s["draw"]) and absf(float(s["dot_px"]) - ObjectLod.P_POINT) < 0.001, "space proj0.1 → beacon (2px, never culled)")
	_near(ObjectLod.beacon_brightness(1.0), 0.25, "beacon brightness ∝ p² (p=1 → 0.25)")
	_near(ObjectLod.beacon_brightness(2.0), 1.0, "beacon brightness saturates at P_POINT")

func _test_budget() -> void:
	var strong := ObjectLod.budget_bytes(2, 8.0, 8)
	var weak := ObjectLod.budget_bytes(0, 2.0, 2)
	var mid := ObjectLod.budget_bytes(2, 4.0, 4)
	var unknown := ObjectLod.budget_bytes(1, 0.0, 0)
	_ok(strong == 16 * 1024 * 1024, "budget strong GPU/8GB/8core → 16MB")
	_ok(weak == 2 * 1024 * 1024, "budget weak GPU/2GB/2core → 2MB")
	_ok(mid == 8 * 1024 * 1024, "budget mid 4GB → 8MB (mem-capped)")
	_ok(unknown == 8 * 1024 * 1024, "budget unknown proxies → mid GPU default 8MB")
	# never-OOM: no proxy combination ever exceeds the hard ceiling, and every proxy can only lower the pick
	var worst := 0
	for g in [0, 1, 2]:
		for m in [0.0, 2.0, 4.0, 8.0, 64.0]:
			for c in [0, 1, 2, 4, 16]:
				worst = maxi(worst, ObjectLod.budget_bytes(g, m, c))
	_ok(worst <= ObjectLod.OBJ_LOD_BYTES_MAX, "budget never exceeds OBJ_LOD_BYTES_MAX (never-OOM)")
	_ok(ObjectLod.budget_bytes(2, 8.0, 2) <= ObjectLod.budget_bytes(2, 8.0, 8), "budget: fewer cores never raises the pick")
