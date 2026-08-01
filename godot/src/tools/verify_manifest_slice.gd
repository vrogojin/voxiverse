extends SceneTree
## FP_MANIFEST_SLICE gate — G-MANIFEST-SLICE (flag CubeSphere.FP_MANIFEST_SLICE; perf/voxiverse-load-profile).
##
## The bug: module_world._build_gen_manifest bakes ~8000 appearance models SYNCHRONOUSLY at setup (~22s, each a GPU
## read-back). Most are cold-biome variants (snow-fill composites + sharp slopes + waterlog twins) a temperate spawn does
## not touch in its first seconds. FP_MANIFEST_SLICE bakes only the CORE synchronously and defers the cold bulk to after
## essential-ready, then re-ramps the near view so nothing renders a PERMANENT plain-cube fallback.
##
## This gate stands up a real module_world (needs the godot_voxel module; skips otherwise), calls setup(), and asserts:
##   • FP_MANIFEST_SLICE ON  → after setup the CORE tables are baked (gen>0, snow>0) but the COLD tables are NOT
##     (comp==0, slope==0) and a deferred bake is pending; driving begin_deferred_manifest_bake()+_process bakes the cold
##     tables (comp>0, slope>0), clears pending, and SCHEDULES a near-view remesh (the ramp is armed) — no permanent
##     wrong-shape.
##   • FP_MANIFEST_SLICE OFF → after setup EVERYTHING is baked (comp>0, slope>0), nothing pending (byte-identical).
##
## RUN — prove the slice (FLAT single-terrain is enough; sed FP_MANIFEST_SLICE on):
##   sed -i 's/const FP_MANIFEST_SLICE := false/const FP_MANIFEST_SLICE := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_manifest_slice.gd
## RUN — the byte-identical baseline (flag off): same command without the sed.
## Exits 0 all-pass / 1 on any failure. SKIPS (pass) when the module is absent.

const MW := preload("res://src/world/voxel_module/module_world.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_manifest_slice (FP_MANIFEST_SLICE: G-MANIFEST-SLICE) ===")
	print("  flags: FP_MANIFEST_SLICE=%s FACETED=%s FP_M1_POOL=%s" % [
		CubeSphere.FP_MANIFEST_SLICE, CubeSphere.FACETED, CubeSphere.FP_M1_POOL])
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP: godot_voxel module absent (no VoxelTerrain).")
		print("=== VERIFY: %d passed, %d failed (skipped) ===" % [_pass, _fail])
		quit(0)
		return

	var mw = MW.new()
	mw.name = "ManifestSliceGate"
	get_root().add_child(mw)
	var ok: bool = mw.setup()
	_ok(ok, "module_world.setup() returned true")
	if not ok:
		print("=== VERIFY: %d passed, %d failed ===" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	var gen0: int = mw.manifest_baked_count("gen")
	var snow0: int = mw.manifest_baked_count("snow")
	var comp0: int = mw.manifest_baked_count("comp")
	var slope0: int = mw.manifest_baked_count("slope")
	var pending0: bool = mw.manifest_cold_pending()
	print("  after setup: gen=%d snow=%d comp=%d slope=%d pending=%s" % [gen0, snow0, comp0, slope0, pending0])
	_ok(gen0 > 0, "CORE dry appearance baked synchronously (gen>0)")
	_ok(snow0 > 0, "CORE snow-cap baked synchronously (snow>0)")

	if CubeSphere.FP_MANIFEST_SLICE:
		# ON: cold tables NOT baked at setup, pending armed.
		_ok(comp0 == 0, "ON: snow-fill composites DEFERRED (comp==0 at setup)")
		_ok(slope0 == 0, "ON: sharp slopes DEFERRED (slope==0 at setup)")
		_ok(pending0, "ON: a deferred cold bake is pending after setup")
		# Fire the deferred bake and drive frames to completion.
		mw.begin_deferred_manifest_bake()
		var iters := 0
		while mw.manifest_cold_pending() and iters < 50:
			mw._process(0.1)
			iters += 1
		var comp1: int = mw.manifest_baked_count("comp")
		var slope1: int = mw.manifest_baked_count("slope")
		print("  after deferred bake (%d frames): comp=%d slope=%d pending=%s ramp_active=%s" % [
			iters, comp1, slope1, mw.manifest_cold_pending(), mw._ramp_active])
		_ok(comp1 > 0, "ON: snow-fill composites baked after the deferred pass (comp>0)")
		_ok(slope1 > 0, "ON: sharp slopes baked after the deferred pass (slope>0)")
		_ok(not mw.manifest_cold_pending(), "ON: cold bake completed (pending cleared)")
		# A near-view remesh was scheduled (single-terrain ramp armed, or the pool active slot re-ramping).
		var remesh_scheduled: bool = bool(mw._ramp_active)
		if CubeSphere.FACETED and CubeSphere.FP_M1_POOL and (mw._pool as Dictionary).has(mw._pool_active):
			var a: Dictionary = mw._pool[mw._pool_active]
			remesh_scheduled = float(a["view_f"]) < float(a["view_target"]) - 0.5
		_ok(remesh_scheduled, "ON: a bounded near-view remesh (re-ramp) was scheduled on completion — no permanent cube fallback")
	else:
		# OFF: everything baked at setup, nothing pending (byte-identical).
		_ok(comp0 > 0, "OFF: snow-fill composites baked synchronously at setup (comp>0)")
		_ok(slope0 > 0, "OFF: sharp slopes baked synchronously at setup (slope>0)")
		_ok(not pending0, "OFF: no deferred bake pending (byte-identical shipped path)")

	mw.queue_free()
	print("=== VERIFY: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
