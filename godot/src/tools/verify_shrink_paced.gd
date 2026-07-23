extends SceneTree
## COSMOS-PERF UNATTENDED R4 gate — G-SHRINK-PACED (flag CubeSphere.FP_SHRINK_PACED).
##
## On a crossing, `redesignate` drops the FROM slot's max_view_distance 128 → 96 in ONE frame, and `_ramp_pool_step`
## SNAPS every shrinking slot the same frame. That one-frame block-unload BURST trips the wasm dlmalloc allocator
## convoy (memory voxiverse-walk-perf-root-cause) — a crossing/descent worst-frame spike. FP_SHRINK_PACED routes the
## unload through the existing per-slot ramp: the FROM slot's view_target drops to 96 but view_f is LEFT at its current
## radius, and `_ramp_pool_step` sheds ≤ SHRINK_STEP_BLOCKS (one 16-block mesh-block shell) per frame until it reaches
## the target. Same END STATE (view_f → 96, same blocks unloaded); only the per-frame unload count is bounded.
##
## Asserts (FP_SHRINK_PACED on): (A) a 128→96 shrink in `_ramp_pool_step` is spread over ≥2 frames with every per-frame
## delta ≤16 and the same end state (96); (B) the REAL `redesignate` FROM-slot rebalance does NOT snap (view_f stays at
## its current radius, view_target set to 96) and then paces down ≤16/frame to 96. With the flag OFF it asserts the
## shipped ONE-frame snap (byte-identical baseline).
##
## RUN (needs FACETED + FP_M1_POOL = true; sed-toggle FP_SHRINK_PACED = true for the pacing asserts):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_M1_POOL := false/const FP_M1_POOL := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_SHRINK_PACED := false/const FP_SHRINK_PACED := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_shrink_paced.gd
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const MW := preload("res://src/world/voxel_module/module_world.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_shrink_paced (COSMOS-PERF UNATTENDED R4: G-SHRINK-PACED) ===")
	if not (CubeSphere.FACETED and CubeSphere.FP_M1_POOL):
		print("  FAIL: needs FACETED = true AND FP_M1_POOL = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	var on: bool = CubeSphere.FP_SHRINK_PACED
	var step := CubeSphere.SHRINK_STEP_BLOCKS
	print("  FP_SHRINK_PACED=%s  SHRINK_STEP_BLOCKS=%d  FIXED_FRAME=%s" % [str(on), step, str(CubeSphere.FP_FIXED_FRAME)])

	var stub := Node3D.new()          # stub terrain: _set_if no-ops (no max_view_distance) — the ramp math reads the dict
	get_root().add_child(stub)
	var stub2 := Node3D.new()
	get_root().add_child(stub2)
	var root_stub := Node3D.new()     # stub PlanetRoot so redesignate's non-null guard passes
	get_root().add_child(root_stub)

	# ---- Part A: _ramp_pool_step pacing of a 128→96 shrink (the machinery both shrink paths route through). ----
	var mwA = MW.new()
	get_root().add_child(mwA)
	var fidX := FA.spawn_facet()
	mwA.test_seed_pool_slot(fidX, 128.0, 96.0, false, stub)   # a NON-active slot shrinking 128 → 96 (_pool_active = -1)
	var series: Array = [128.0]
	var frames := 0
	while mwA.test_pool_view_f(fidX) > 96.0 + 0.01 and frames < 32:
		mwA.pool_ramp_tick(0.05)
		series.append(mwA.test_pool_view_f(fidX))
		frames += 1
	var end_a := mwA.test_pool_view_f(fidX)
	var max_delta := 0.0
	var monotone := true
	for i in range(1, series.size()):
		var d: float = series[i - 1] - series[i]
		max_delta = maxf(max_delta, d)
		if series[i] > series[i - 1] + 0.01:
			monotone = false
	print("  Part A series=%s frames=%d max_delta=%.1f end=%.1f" % [str(series), frames, max_delta, end_a])

	if on:
		_ok(absf(end_a - 96.0) < 0.01, "A: paced shrink reaches the SAME end state (96, got %.1f)" % end_a)
		_ok(frames >= 2, "A: 128→96 shrink is SPREAD over ≥2 frames (no one-frame snap) — %d frames" % frames)
		_ok(max_delta <= float(step) + 0.01, "A: every per-frame unload delta ≤ SHRINK_STEP_BLOCKS (%d) — max %.1f" % [step, max_delta])
		_ok(monotone, "A: the shrink is monotone non-increasing")
	else:
		_ok(absf(end_a - 96.0) < 0.01, "A(OFF): shrink reaches 96 (got %.1f)" % end_a)
		_ok(frames == 1, "A(OFF): shrink SNAPS in ONE frame (byte-identical baseline) — %d frames" % frames)
		_ok(max_delta >= 31.0, "A(OFF): the one-frame delta is the full 32-block snap (%.1f)" % max_delta)

	# ---- Part B: the REAL redesignate FROM-slot rebalance (crossing path) — paced, not snapped. ----
	var mwB = MW.new()
	get_root().add_child(mwB)
	mwB.test_set_planet_root(root_stub)
	var A := FA.spawn_facet()
	var B := FA.seam_neighbour(A, 0)
	_ok(B != A and B >= 0, "B setup: A=%d has a distinct seam neighbour B=%d" % [A, B])
	mwB.test_seed_pool_slot(A, 128.0, 128.0, true, stub)     # FROM = the active slot at full near radius (128)
	mwB.test_seed_pool_slot(B, 96.0, 96.0, false, stub2)     # TO   = a warm neighbour at 96
	var redesignated: bool = mwB.redesignate(B)
	_ok(redesignated, "B: redesignate(A→B) committed (pool hit)")
	var from_vf_after := mwB.test_pool_view_f(A)
	var from_tgt_after := mwB.pool_view_target(A)
	print("  Part B after redesignate: FROM(A) view_f=%.1f target=%d  (active now=%s)" % [from_vf_after, from_tgt_after, str(B)])

	if on:
		_ok(absf(from_vf_after - 128.0) < 0.01, "B: FROM slot is NOT snapped — view_f held at 128 (got %.1f)" % from_vf_after)
		_ok(from_tgt_after == 96, "B: FROM slot view_target set to 96 (paced goal) — got %d" % from_tgt_after)
		# Pace it down and check ≤16/frame all the way to 96.
		var bseries: Array = [from_vf_after]
		var bframes := 0
		while mwB.test_pool_view_f(A) > 96.0 + 0.01 and bframes < 32:
			mwB.pool_ramp_tick(0.05)
			bseries.append(mwB.test_pool_view_f(A))
			bframes += 1
		var bmax := 0.0
		for i in range(1, bseries.size()):
			bmax = maxf(bmax, bseries[i - 1] - bseries[i])
		print("  Part B pacing series=%s frames=%d max_delta=%.1f" % [str(bseries), bframes, bmax])
		_ok(bframes >= 2, "B: FROM 128→96 paced over ≥2 frames — %d" % bframes)
		_ok(bmax <= float(step) + 0.01, "B: FROM per-frame delta ≤ %d (max %.1f)" % [step, bmax])
		_ok(absf(mwB.test_pool_view_f(A) - 96.0) < 0.01, "B: FROM reaches the same end state (96)")
	else:
		_ok(absf(from_vf_after - 96.0) < 0.01, "B(OFF): FROM slot SNAPS to 96 immediately (byte-identical) — got %.1f" % from_vf_after)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
