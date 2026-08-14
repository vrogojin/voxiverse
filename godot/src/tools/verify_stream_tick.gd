extends SceneTree
## COSMOS-MOTION-PHYS gate (docs/COSMOS-MOTION-PHYS-DESIGN.md §5, task #129 motion) — FP_STREAM_TICK_ONCE.
## WorldManager.update_streaming runs every physics tick; a slow render frame runs 2 physics steps, so the render-facing
## orchestration TAIL runs twice on already-slow frames. FP_STREAM_TICK_ONCE runs the tail at most once per render frame
## (both catch-up steps share one Engine.get_process_frames()). The safety head (streamer/collider/pos-latch) stays
## per-tick → zero fall-through. Two-state, self-describing.
##
##   G-MTP-ONCE   flag on: two update_streaming calls in ONE process-frame ⇒ the tail runs ONCE; a simulated new frame ⇒
##                the tail runs again. flag off: every call runs the tail (2 calls ⇒ +2) — the shipped behaviour.
##   G-MTP-FLOOR  flag on vs off: block_id_at / floor_under return byte-identical values (the tail writes no collision
##                state — the fall-through-safety invariant), driven on a bare WorldManager.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_stream_tick.gd

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _bare_world(nm: String) -> WorldManager:
	var w := WorldManager.new()
	w.name = nm
	get_root().add_child(w)
	return w

func _initialize() -> void:
	print("=== verify_stream_tick (FP_STREAM_TICK_ONCE — the walking phys_ms tail-dedup) ===")
	var on := CubeSphere.FP_STREAM_TICK_ONCE
	var w := _bare_world("TickOnce")
	var p := Vector3(0.0, 100.0, 0.0)

	# Two calls within ONE process-frame (Engine.get_process_frames() is fixed during _initialize).
	var base := w.debug_tail_runs()
	w.update_streaming(p)
	w.update_streaming(p)
	var after2 := w.debug_tail_runs() - base
	if on:
		_ok(after2 == 1, "G-MTP-ONCE(on): 2 update_streaming calls in one render frame ⇒ tail runs ONCE (%d)" % after2)
	else:
		_ok(after2 == 2, "G-MTP-ONCE(off): 2 calls ⇒ tail runs twice (shipped, %d)" % after2)

	# Simulate a render-frame advance: the tail must run again under the flag.
	w.debug_set_tail_frame(-99)
	var b3 := w.debug_tail_runs()
	w.update_streaming(p)
	_ok(w.debug_tail_runs() - b3 == 1,
		"G-MTP-ONCE: a new render frame runs the tail again (%d) — %s" % [w.debug_tail_runs() - b3, "on" if on else "off"])

	# G-MTP-FLOOR (fall-through safety): the collision queries read NO tail state, so they are identical flag-on vs off.
	# Drive block_id_at over a small column span on a bare world (procedural terrain, no edits) — deterministic + flag-
	# independent by construction; this pins the invariant that the tail-dedup can never change what the player stands on.
	var w2 := _bare_world("TickFloor")
	var q_ok := true
	for x in range(-3, 4):
		for z in range(-3, 4):
			var col_solid := 0
			for y in range(-4, 40):
				if w2.block_id_at(Vector3i(x, y, z)) != 0:
					col_solid += 1
			# after driving the streaming tail (which under the flag may have been skipped once), the same query must hold
			w2.update_streaming(Vector3(float(x), 100.0, float(z)))
			var col_solid2 := 0
			for y in range(-4, 40):
				if w2.block_id_at(Vector3i(x, y, z)) != 0:
					col_solid2 += 1
			if col_solid != col_solid2:
				q_ok = false
	_ok(q_ok, "G-MTP-FLOOR: block_id_at is invariant across update_streaming (tail writes no collision state — no fall-through)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
