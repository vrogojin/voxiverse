extends SceneTree
## FP_WORST_FRAME_ATTR gate — G-WORST-FRAME-ATTR (docs/COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md §3). FP_WORST_FRAME_ATTR
## is a DIAGNOSTIC instrument: at the exact frame RemoteBridge._process recognises a NEW window-worst, it snapshots the
## attribution stats RIGHT THEN (co-occurring with the worst frame instead of the 250 ms-later emit-tick sample) and
## emits them once/window as wf_*-prefixed telemetry. This gate proves the contracts headless:
##
##   • BYTE-OFF: the shipped default is FP_WORST_FRAME_ATTR == false; the snapshot is never built ⇒ _win_worst_snapshot
##     stays {} ⇒ the emit merge (guarded on `not _wf.is_empty()`) stamps NO wf_* key ⇒ byte-identical telemetry.
##   • NON-RESET PEEKS: the co-sample accessors (JobLane.peek_main_commit_ms, Player.fall_timing_peek) READ without
##     resetting, so the worst-frame snapshot never steals the value the window's take_* drains at the emit tick.
##   • CAPTURE SHAPE: _capture_worst_frame_snapshot() returns a dict whose every key is wf_-prefixed and which — even
##     with null world/player/voxel-engine (the flat gate's scene) — carries the always-available render/phys monitors.
##
## RUN (no flag toggling — the plumbing is exercised through the accessors directly; the flag default stays false):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_worst_frame_attr.gd
## Exits 0 all-pass / 1 on any failure.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const PlayerCls := preload("res://src/player/player.gd")
const JobLaneCls := preload("res://src/world/job_lane.gd")
const RemoteBridgeCls := preload("res://src/net/remote_bridge.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_worst_frame_attr (G-WORST-FRAME-ATTR) ===")
	print("  FP_WORST_FRAME_ATTR default = %s" % str(CS.FP_WORST_FRAME_ATTR))

	# --- BYTE-OFF: the shipped build must ship the flag OFF ---
	_ok(CS.FP_WORST_FRAME_ATTR == false, "DEFAULT: FP_WORST_FRAME_ATTR is false (byte-off)")

	# --- NON-RESET PEEK: JobLane.peek_main_commit_ms reads WITHOUT the reset that take_main_commit_ms performs ---
	var jl: JobLane = JobLaneCls.new()
	_ok(jl.peek_main_commit_ms() == 0.0, "JOBLANE: a fresh lane peeks 0.0 main-commit ms")
	jl._main_commit_us = 500                             # simulate a window's accumulated commit (what run() would add)
	_ok(jl.peek_main_commit_ms() == 0.5, "JOBLANE: peek reflects the live accumulator (500 us ⇒ 0.5 ms)")
	_ok(jl.peek_main_commit_ms() == 0.5, "JOBLANE: peek is NON-RESETTING (second peek still 0.5 ms)")
	_ok(jl.take_main_commit_ms() == 0.5, "JOBLANE: take returns the same value")
	_ok(jl.peek_main_commit_ms() == 0.0, "JOBLANE: take RESET the accumulator ⇒ peek now 0.0")

	# --- NON-RESET PEEK: Player.fall_timing_peek mirrors _ft WITHOUT clearing (fall_timing() still drains at emit) ---
	var p: Player = PlayerCls.new()
	_ok(p.fall_timing_peek().is_empty(), "PLAYER: a fresh player's fall_timing_peek() is {} (no keys)")
	p._ft_max("t_move_us", 120)
	p._ft_max("t_stream_us", 42)
	var pk1: Dictionary = p.fall_timing_peek()
	_ok(int(pk1.get("t_move_us", -1)) == 120, "PLAYER: peek reflects _ft (t_move_us=120)")
	_ok(int(pk1.get("t_stream_us", -1)) == 42, "PLAYER: peek reflects _ft (t_stream_us=42)")
	_ok(int(p.fall_timing_peek().get("t_move_us", -1)) == 120, "PLAYER: peek is NON-RESETTING (still 120 on re-peek)")
	# fall_timing() (the emit-tick drain) still returns + clears exactly as before ⇒ peek never stole the window value
	_ok(not p.fall_timing().is_empty(), "PLAYER: fall_timing() still drains the window after a peek")
	_ok(p.fall_timing_peek().is_empty(), "PLAYER: after fall_timing() drained, peek is {} again")
	p.free()

	# --- CAPTURE SHAPE: _capture_worst_frame_snapshot() on a bare bridge (null world/player/engine, the flat scene) ---
	var rb: RemoteBridge = RemoteBridgeCls.new()
	_ok(rb._win_worst_snapshot.is_empty(), "BRIDGE: a fresh bridge's _win_worst_snapshot is {} (byte-off default state)")
	var snap: Dictionary = rb._capture_worst_frame_snapshot()
	_ok(not snap.is_empty(), "BRIDGE: capture returns a populated dict (render/phys monitors are always available)")
	var non_wf := PackedStringArray()
	for k in snap:
		if not String(k).begins_with("wf_"):
			non_wf.append(String(k))
	_ok(non_wf.is_empty(), "BRIDGE: EVERY captured key is wf_-prefixed (no collision with window-aggregate fields): %s" % ",".join(non_wf))
	for k in ["wf_phys_ms", "wf_draws", "wf_prims", "wf_objects"]:
		_ok(snap.has(k), "BRIDGE: always-available monitor key present: %s" % k)
	# null world/player/engine ⇒ the guarded voxel/marker/fall-timing branches add nothing (no crash, no partial keys)
	_ok(not snap.has("wf_vox_gen"), "BRIDGE: null voxel engine ⇒ no wf_vox_* keys (guarded)")
	_ok(not snap.has("wf_main_commit_ms"), "BRIDGE: null world ⇒ no wf_*_commit_ms markers (guarded)")
	rb.free()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
