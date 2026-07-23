extends SceneTree
## FP_INFLIGHT_GATE (P1) headless probe — asserts the in-flight signal F, its hysteresis latch, and backlog_gated()'s
## flag-branch. Runs against a synthetic injected source (deterministic; no VoxelEngine needed). NOT part of FLAT.

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("PROBE FAIL: " + msg)

class SynthSource extends RefCounted:
	var inflight := 0
	var backlog := 0
	func poll() -> Dictionary:
		return {"frame_ms": 5.0, "backlog": backlog, "inflight": inflight}

func _drive(c, src, steps: int) -> void:
	# advance the injected clock past CTRL_TICK_S each step so credit ticks; the latch updates every poll regardless
	for i in range(steps):
		c.tick(float(i + 1) * (CubeSphere.CTRL_TICK_S + 0.001))

func _initialize() -> void:
	print("== FP_INFLIGHT_GATE probe (flag = %s) ==" % str(CubeSphere.FP_INFLIGHT_GATE))
	var StreamLoadController = load("res://src/world/stream_load_controller.gd")
	var c = StreamLoadController.new()
	var src = SynthSource.new()
	c.set_input_source(src)

	# 1) F is stored from the source's "inflight"
	src.inflight = 100
	src.backlog = 10
	_drive(c, src, 2)
	_ok(int(c.stats()["inflight"]) == 100, "F(inflight) stored = 100, got %s" % str(c.stats()["inflight"]))

	# 2) latch CLOSES only above INFLIGHT_MAX(192); 100 and 150 keep it open
	_ok(bool(c.stats()["inflight_gated"]) == false, "latch open at F=100")
	src.inflight = 150
	_drive(c, src, 1)
	_ok(bool(c.stats()["inflight_gated"]) == false, "latch open at F=150 (< MAX 192)")
	src.inflight = 200
	_drive(c, src, 1)
	_ok(bool(c.stats()["inflight_gated"]) == true, "latch CLOSED at F=200 (> MAX 192)")

	# 3) hysteresis: stays closed in the band [MIN..MAX] (F=100 does NOT re-open)
	src.inflight = 100
	_drive(c, src, 1)
	_ok(bool(c.stats()["inflight_gated"]) == true, "latch stays closed at F=100 (hysteresis band, MIN 64)")

	# 4) re-opens only below INFLIGHT_MIN(64)
	src.inflight = 50
	_drive(c, src, 1)
	_ok(bool(c.stats()["inflight_gated"]) == false, "latch RE-OPENS at F=50 (< MIN 64)")

	# 5) backlog_gated() branch depends on the flag:
	#    ON  -> follows the F latch;  OFF -> shipped vox_gen > CTRL_BACKLOG_MAX(300)
	src.inflight = 300     # > MAX -> latch closes
	src.backlog = 10       # < 300 -> shipped gate OPEN
	_drive(c, src, 1)
	if CubeSphere.FP_INFLIGHT_GATE:
		_ok(c.backlog_gated() == true, "flag ON: backlog_gated follows F latch (closed)")
	else:
		_ok(c.backlog_gated() == false, "flag OFF: backlog_gated == (backlog 10 > 300) == false")

	src.inflight = 10      # < MIN -> latch open
	src.backlog = 400      # > 300 -> shipped gate CLOSED
	_drive(c, src, 1)
	if CubeSphere.FP_INFLIGHT_GATE:
		_ok(c.backlog_gated() == false, "flag ON: backlog_gated follows F latch (open); backlog=400 ignored")
	else:
		_ok(c.backlog_gated() == true, "flag OFF: backlog_gated == (backlog 400 > 300) == true")

	# 6) fallback: a source WITHOUT "inflight" makes F fall back to backlog (headless square-wave determinism)
	var c2 = StreamLoadController.new()
	var src2 = RefCounted.new()   # no poll() -> neutral zero-load; F stays 0
	# use a minimal source that only provides backlog
	c2.set_input_source(_BacklogOnly.new(120))
	c2.tick(0.5)
	_ok(int(c2.stats()["inflight"]) == 120, "F falls back to backlog(120) when source omits 'inflight', got %s" % str(c2.stats()["inflight"]))

	print("== PROBE: %d passed, %d failed ==" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

class _BacklogOnly extends RefCounted:
	var b := 0
	func _init(v: int) -> void:
		b = v
	func poll() -> Dictionary:
		return {"frame_ms": 5.0, "backlog": b}
