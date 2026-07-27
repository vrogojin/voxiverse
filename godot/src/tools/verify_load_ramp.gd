extends SceneTree
## FP_LOAD_RAMP gate — G-LOAD-RAMP (flag CubeSphere.FP_LOAD_RAMP; perf/voxiverse-load-profile).
##
## The bug: the FIRST cold load slams the near VoxelTerrain's max_view_distance to the FULL near radius
## (near_render_radius(): 256 flat / 128 faceted) in ONE step at module_world.setup() — on the single-terrain path
## AND, under FP_M1_POOL, in _pool_init_active (active slot seeded view_f == view_target == full, "NO ramp"). godot_voxel
## then queues the whole view sphere in one pass, and the ShaderPrewarm overlay (≤4 s, 40³ box) lifts long before it
## meshes → the multi-minute post-splash fill. FP_LOAD_RAMP starts the first load at module_world.RAMP_START_BLOCKS (48)
## and grows to the full target over RAMP_SECONDS using the EXISTING ramp mechanism (single-terrain _ramp_active leg /
## the active pool slot via _ramp_pool_step). The FINAL view is unchanged — pure load-shaping.
##
## This gate stands up a REAL module_world (needs the godot_voxel module; skips cleanly if absent), calls setup(), and
## asserts the INITIAL near-view distance + that it GROWS toward — but never past — the full target:
##   • FP_LOAD_RAMP ON  → initial view == RAMP_START_BLOCKS (small), ramp is armed, target == full, and driving a few
##     _process ticks GROWS the view toward full (and never exceeds it).
##   • FP_LOAD_RAMP OFF → initial view == full radius from frame 0, no ramp, and it stays full (the byte-identical slam).
## Covers whichever path the compiled flags select: single-terrain (default/FLAT) or the FP_M1_POOL active slot.
##
## RUN — prove the ramp (FLAT single-terrain path is enough; sed FP_LOAD_RAMP on):
##   sed -i 's/const FP_LOAD_RAMP := false/const FP_LOAD_RAMP := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_load_ramp.gd
## RUN — prove the byte-identical baseline (defaults, flag off): same command without the sed.
## RUN — the live pool path (also sed FACETED + FP_M1_POOL on): same command; the gate auto-detects the pool slot.
## Exits 0 all-pass / 1 on any failure.

const MW := preload("res://src/world/voxel_module/module_world.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_load_ramp (FP_LOAD_RAMP: G-LOAD-RAMP) ===")
	print("  flags: FP_LOAD_RAMP=%s FACETED=%s FP_M1_POOL=%s FLAT_WORLD=%s" % [
		CubeSphere.FP_LOAD_RAMP, CubeSphere.FACETED, CubeSphere.FP_M1_POOL, CubeSphere.FLAT_WORLD])

	if not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP: godot_voxel module absent (no VoxelTerrain) — nothing to assert on the module path.")
		print("=== VERIFY: %d passed, %d failed (skipped) ===" % [_pass, _fail])
		quit(0)
		return

	# Mirror WorldManager._ready's faceted prerequisites so setup() picks the pool path when the deploy flags are on.
	if CubeSphere.FACETED:
		TC.warm_up()
		FA.warm_up()
		if TC.active_facet() < 0:
			TC.set_active_facet(FA.spawn_facet())

	var mw = MW.new()
	mw.name = "ModuleWorldGate"
	get_root().add_child(mw)
	var ok: bool = mw.setup()
	_ok(ok, "module_world.setup() returned true")
	if not ok:
		print("=== VERIFY: %d passed, %d failed ===" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	var full := TC.near_render_radius()
	var start := int(minf(MW.RAMP_START_BLOCKS, float(full)))
	var pooled: bool = int(mw._pool_active) >= 0 and not (mw._pool as Dictionary).is_empty()
	print("  path=%s  full_radius=%d  ramp_start=%d" % ["POOL" if pooled else "single-terrain", full, start])

	# --- initial view distance (the value godot_voxel streams to on frame 0) ---
	var v0 := _view_now(mw, pooled)
	if CubeSphere.FP_LOAD_RAMP:
		_ok(v0 == start, "ON: initial view starts SMALL (== RAMP_START %d), got %d" % [start, v0])
		_ok(_target_now(mw, pooled) == full, "ON: ramp target == full radius %d" % full)
		_ok(_ramp_armed(mw, pooled, full), "ON: ramp is armed (view < target, will grow)")
	else:
		_ok(v0 == full, "OFF: initial view is FULL radius %d from frame 0 (byte-identical slam), got %d" % [full, v0])
		_ok(not _ramp_armed(mw, pooled, full), "OFF: no ramp armed")

	# --- drive a few frames: it must GROW toward full (ON) / stay put (OFF), never exceed full ---
	for i in range(6):
		mw._process(0.5)
	var v1 := _view_now(mw, pooled)
	if CubeSphere.FP_LOAD_RAMP:
		_ok(v1 > v0, "ON: view GROWS after ticks (%d → %d)" % [v0, v1])
	else:
		_ok(v1 == v0, "OFF: view unchanged after ticks (%d)" % v0)
	_ok(v1 <= full, "final view never exceeds full radius %d (got %d) — NEVER-widen invariant" % [full, v1])
	_ok(_target_now(mw, pooled) == full, "target is exactly the full radius %d (no unbounding)" % full)

	mw.queue_free()
	print("=== VERIFY: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## The current initial/active near-view distance in blocks (pool active slot view, else the single terrain's).
func _view_now(mw, pooled: bool) -> int:
	if pooled:
		return int((mw._pool[mw._pool_active] as Dictionary)["view_f"])
	return int(mw._terrain.max_view_distance)

## The ramp TARGET (full radius the leg grows toward).
func _target_now(mw, pooled: bool) -> int:
	if pooled:
		return int((mw._pool[mw._pool_active] as Dictionary)["view_target"])
	return int(mw._ramp_target) if bool(mw._ramp_active) else int(mw._terrain.max_view_distance)

## Is a grow leg armed (current < target)?
func _ramp_armed(mw, pooled: bool, full: int) -> bool:
	if pooled:
		var s: Dictionary = mw._pool[mw._pool_active]
		return float(s["view_f"]) < float(s["view_target"]) - 0.5
	return bool(mw._ramp_active) and int(mw._ramp_target) == full
