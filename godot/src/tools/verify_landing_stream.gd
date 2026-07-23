extends SceneTree
## NEAR-FIELD LANDING STREAM WEDGE gate (fix/voxiverse-landing-stream) — proves FP_LANDING_STREAM_KICK unfreezes the
## RESIDENT active pool slot's view-distance ramp after a de-orbit LAND, and that the fix is correctly SCOPED so it
## never perturbs the shipped crossing behaviour.
##
## Root cause reproduced here in isolation: module_world._ramp_pool_step advances a slot's grow leg at pace ==
## _stream_pace, and the StreamLoadController pins that at 0 whenever its backlog/apply gate is held closed (a
## far-ring/shell rebuild churning in-flight work). Only the committed-IMMINENT slot carries a pace floor; the
## resident active slot (which is what remains once the player has LANDED and no crossing is pending) has none, so its
## view ramp — and thus the near voxel stream — freezes at whatever radius the last orbital redesignation left it and
## ZERO further load requests are issued. FP_LANDING_STREAM_KICK floors the resident active slot's grow pace at
## CTRL_RELIEF_FLOOR (after the FP_INFLIGHT_GATE cut) and repairs a collapsed view_target back to the full near radius.
##
## The gate drives _ramp_pool_step directly with a synthetic _pool (a plain Node3D per slot → _set_if no-ops the
## engine-only max_view_distance write, so no godot_voxel binary is needed) under the wedge condition (_stream_pace=0,
## no imminent). Asserts:
##   G-LAND-REPAIR   a collapsed active view_target is snapped back up to near_render_radius.
##   G-LAND-GROW     the active view_f grows on the FIRST step despite _stream_pace==0 (the freeze is broken).
##   G-LAND-FULL     within ~RAMP_SECONDS/CTRL_RELIEF_FLOOR seconds the active slot reaches the full near radius,
##                   and its int view mirror (the engine max_view_distance) is non-zero (streaming re-enabled).
##   G-LAND-SCOPE-NB a non-active neighbour at pace 0 (not imminent) stays FROZEN — the floor is active-only.
##   G-LAND-SCOPE-XING with a real PENDING crossing (imminent != active) the active slot is NOT floored and its
##                   collapsed target is NOT repaired — the shipped crossing ramp is byte-preserved.
##
## RUN:
##   sed -i 's/const FP_LANDING_STREAM_KICK := false/const FP_LANDING_STREAM_KICK := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_landing_stream.gd
##   # then REVERT the sed. Exits 0 all-pass / 1 on any failure.
## OFF byte-identity (flag false) is covered by the FLAT verify_feature gate (6042/0), not re-proved here.

const MW := preload("res://src/world/voxel_module/module_world.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _slot(fid: int, view_f: float, view_target: float, spawn_ms: int) -> Dictionary:
	return {
		"terrain": Node3D.new(), "slot": null, "mesher": null, "generator": null,
		"spawn_ms": spawn_ms, "view": int(round(view_f)), "editable": false, "fid": fid,
		"view_f": view_f, "view_target": view_target, "ramp_from": view_f,
	}

func _initialize() -> void:
	print("=== verify_landing_stream (FP_LANDING_STREAM_KICK: near-field de-orbit-land stream wedge) ===")
	if not CubeSphere.FP_LANDING_STREAM_KICK:
		print("  FAIL: CubeSphere.FP_LANDING_STREAM_KICK is false — sed-toggle it true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return

	var full := float(TerrainConfig.near_render_radius())
	var start := 48.0
	var collapsed := minf(96.0, full - 1.0)   # a churned-crossing residue: below the full near radius

	# ---- LANDED wedge: active slot resident, no imminent, load gate pinning pace at 0 ----
	var mw = MW.new()
	mw._pool_active = 10
	mw._imminent_fid = -1
	mw._imminent_committed = false
	mw._stream_pace = 0.0                      # the StreamLoadController's held-closed gate
	mw._pool = {10: _slot(10, start, collapsed, 1000), 11: _slot(11, start, collapsed, 2000)}

	var before := float(mw._pool[10]["view_f"])
	var ramping: bool = mw._ramp_pool_step(0.1)
	_ok(float(mw._pool[10]["view_target"]) >= full - 0.5,
		"G-LAND-REPAIR active view_target snapped to full (%d), got %s" % [int(full), str(mw._pool[10]["view_target"])])
	_ok(ramping and float(mw._pool[10]["view_f"]) > before + 1e-4,
		"G-LAND-GROW active view_f grew on the first step at _stream_pace=0 (before=%s after=%s)"
			% [str(before), str(mw._pool[10]["view_f"])])

	# Drive ~7 s of frames (RAMP_SECONDS/CTRL_RELIEF_FLOOR = 1.5/0.25 = 6 s worst-case fill) and confirm completion.
	var t := 0.0
	while t < 7.0:
		mw._ramp_pool_step(0.05)
		t += 0.05
	var v10f := float(mw._pool[10]["view_f"])
	var v10i := int(mw._pool[10]["view"])
	_ok(absf(v10f - full) < 0.5,
		"G-LAND-FULL active view_f reached full near radius %d (got %s)" % [int(full), str(v10f)])
	_ok(v10i > 0 and v10i >= int(full),
		"G-LAND-FULL active int view (engine max_view_distance) non-zero & full (got %d)" % v10i)

	# Scope: the non-active neighbour (pace 0, not imminent) must NOT have been floored — still frozen at start.
	_ok(absf(float(mw._pool[11]["view_f"]) - start) < 0.5,
		"G-LAND-SCOPE-NB non-active neighbour stayed frozen at %d (got %s)" % [int(start), str(mw._pool[11]["view_f"])])
	for fid in mw._pool.keys():
		var t3: Node3D = mw._pool[fid]["terrain"]
		if t3 != null: t3.free()

	# ---- PENDING crossing: imminent != active → the landing kick must NOT engage (shipped ramp preserved) ----
	var mw2 = MW.new()
	mw2._pool_active = 10
	mw2._imminent_fid = 11                      # a genuine crossing is pending — NOT a landed/settled state
	mw2._imminent_committed = false
	mw2._stream_pace = 0.0
	mw2._pool = {10: _slot(10, start, collapsed, 1000), 11: _slot(11, start, collapsed, 2000)}
	var a_before := float(mw2._pool[10]["view_f"])
	var tgt_before := float(mw2._pool[10]["view_target"])
	for _i in range(40):
		mw2._ramp_pool_step(0.05)
	_ok(absf(float(mw2._pool[10]["view_f"]) - a_before) < 0.5,
		"G-LAND-SCOPE-XING active NOT floored while a crossing is pending (view_f %s→%s)"
			% [str(a_before), str(mw2._pool[10]["view_f"])])
	_ok(absf(float(mw2._pool[10]["view_target"]) - tgt_before) < 0.5,
		"G-LAND-SCOPE-XING active collapsed target NOT repaired while a crossing is pending (%s)"
			% str(mw2._pool[10]["view_target"]))
	for fid in mw2._pool.keys():
		var t4: Node3D = mw2._pool[fid]["terrain"]
		if t4 != null: t4.free()

	mw.free()
	mw2.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
