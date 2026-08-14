extends SceneTree
## COSMOS-FOREST-FPS-LIMITER F1 gate (docs/COSMOS-FOREST-FPS-LIMITER-DESIGN.md §3, task #129) — the adaptive
## controller floor-trap fix FP_CTRL_FLOOR_VSYNC. Two-state, self-describing.
##
## The trap: the floor window samples frame PERIODS; after a slow frame the browser rAF fires a ~12 ms catch-up
## period, so the floor p10 reads ~12 ms — below the 60 Hz vsync period, impossible as a SUSTAINED cadence. The
## adaptive setpoint = clamp(floor_p10 × MARGIN, BUDGET, ADAPTIVE_MAX) then lands ~24 ms, JUST UNDER the p90 the
## spikes produce, so overload latches and credit pins at 0 — the controller chases its own attacker down.
## FP_CTRL_FLOOR_VSYNC clamps the floor estimate to ≥ CTRL_FLOOR_MIN_MS (16 ms) so the setpoint floors at ~32 ms.
##
## Driven directly: a scripted frame-period source feeds tick() (no live game). A "trap" pattern [16,16,29,12] has
## floor_p10 = 12 but p90 = 29 → off ⇒ overloaded (24 < 29), on ⇒ NOT (32 > 29) = the fix. A "genuine" pattern
## [16,16,50,16] (real 50 ms spikes above a 16 ms floor) stays overloaded in BOTH states — F1 never masks a real one.
##
## RUN (adaptive is forced true in-gate; toggle FP_CTRL_FLOOR_VSYNC to see both states):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_ctrl_floor.gd

const SLC := preload("res://src/world/stream_load_controller.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## A scripted frame-period source: poll() cycles `pattern` (ms), backlog/inflight 0 (streaming idle).
class ScriptSrc extends RefCounted:
	var pattern: Array = []
	var i := 0
	func _init(p: Array) -> void:
		pattern = p
	func poll() -> Dictionary:
		var ms: float = pattern[i % pattern.size()]
		i += 1
		return {"frame_ms": ms, "backlog": 0, "inflight": 0}

## Feed `n` ticks of `pattern` into a fresh adaptive controller; return its settled stats().
func _run(pattern: Array, n: int) -> Dictionary:
	var c = SLC.new()
	c.set_adaptive(true)                       # F1 only acts in adaptive mode (absolute mode ignores the floor)
	c.set_input_source(ScriptSrc.new(pattern))
	var t := 0.0
	for _k in range(n):
		t += CubeSphere.CTRL_TICK_S + 0.01     # > CTRL_TICK_S so the setpoint updates every tick
		c.tick(t)
	return c.stats()

func _initialize() -> void:
	print("=== verify_ctrl_floor (F1: FP_CTRL_FLOOR_VSYNC — adaptive floor-trap fix) ===")
	var on := CubeSphere.FP_CTRL_FLOOR_VSYNC
	# Fill the 1800-frame floor window + settle the EMA.
	var trap := _run([16.0, 16.0, 29.0, 12.0], 2100)
	var genuine := _run([16.0, 16.0, 50.0, 16.0], 2100)
	var fp_trap := float(trap.get("floor_p10_ms", 0.0))
	var sp_trap := float(trap.get("setpoint_ms", 0.0))
	print("  trap:    floor_p10=%.1f setpoint=%.1f overload=%s   genuine: floor_p10=%.1f setpoint=%.1f overload=%s" % [
		fp_trap, sp_trap, str(trap.get("overload")),
		float(genuine.get("floor_p10_ms", 0.0)), float(genuine.get("setpoint_ms", 0.0)), str(genuine.get("overload"))])

	# G-CTRL-VSYNC-FLOOR: the floor estimate is clamped to ≥ vsync under the flag; raw (~12) off.
	if on:
		_ok(fp_trap >= CubeSphere.CTRL_FLOOR_MIN_MS - 0.01,
			"G-CTRL-VSYNC(on): trap floor_p10 clamped to ≥ %.0f ms (%.1f)" % [CubeSphere.CTRL_FLOOR_MIN_MS, fp_trap])
		_ok(sp_trap >= 30.0,
			"G-CTRL-VSYNC(on): trap setpoint floored to ~32 ms (%.1f) — the rAF catch-up can't drag it under the spikes" % sp_trap)
	else:
		_ok(fp_trap < CubeSphere.CTRL_FLOOR_MIN_MS,
			"G-CTRL-VSYNC(off): trap floor_p10 is the raw rAF-catch-up period < %.0f ms (%.1f)" % [CubeSphere.CTRL_FLOOR_MIN_MS, fp_trap])

	# G-CTRL-VSYNC-TRAP: the rAF trap pattern overloads OFF (the pin) and does NOT overload ON (the fix).
	if on:
		_ok(not bool(trap.get("overload")),
			"G-CTRL-VSYNC(on): the rAF trap pattern does NOT overload (credit un-pinned) — the F1 fix")
	else:
		_ok(bool(trap.get("overload")),
			"G-CTRL-VSYNC(off): the rAF trap pattern overloads (credit pinned) — the reproduced floor-trap")

	# G-CTRL-VSYNC-GENUINE: a real 50 ms spike above a 16 ms floor overloads in BOTH states (F1 never masks a real one).
	_ok(bool(genuine.get("overload")),
		"G-CTRL-VSYNC: a genuine 50 ms-spike overload still trips (%s) — F1 does not mask real overload" % ("on" if on else "off"))

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
