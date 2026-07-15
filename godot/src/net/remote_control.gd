class_name RemoteControl
extends Node
## REMOTE-CONTROL EXECUTOR — Phase 2 (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4). The step-sequence
## runner that pairs with the relay's forward gate. Created by RemoteBridge ONLY after a human has
## consented to control (§6.1); freed on revoke / override / link-loss. It NEVER exists in normal
## play, in an observe-only session, or when RemoteBridge.CONTROL_ENABLED is false — the same
## "dead in normal play" discipline as RemoteBridge itself. verify_feature never runs main.gd, so
## this node never exists under the headless gate (the 6027/0 tally is structural).
##
## P2 SCOPE (control stays INERT until P4 flips CONTROL_ENABLED): only `wait`, `screenshot`, `stop`
## and `reload` execute end-to-end. The locomotion + world-mutation ops (move/turn/look/jump/set_fly/
## break/place/select_slot) are RECOGNISED but return a clear `unimplemented` status — the §4 closed-
## loop executor + the player intent seam land in P3. An op outside the whole whitelist is `bad_op`.
##
## SECURITY: the executor's ONLY authored effect in P2 is (a) request a viewport screenshot from the
## bridge and (b) request a browser reload while a grant is active. It synthesises no input, calls no
## Player/World mutation method, and reflection/eval is confined to the reload op (bridge-side, web,
## grant-gated). The human OVERRIDE (§6.4) is observed here — ANY local key/mouse (except Esc / the
## revoke chord, which are REVOKE and belong to the activator) aborts the running queue in the SAME
## frame and ENDS the grant (resolved D2). Detection is both event-driven (_unhandled_input) AND a
## per-tick poll, so it never depends on event delivery order.

# ── Downlink to the bridge (it owns the socket; these become WS text/binary frames) ──────────────
signal step_started(rec: Dictionary)       # {type:"step_start", seq, id, op, pos, yaw_deg, facet, t}
signal step_finished(rec: Dictionary)      # {type:"step_done", seq, id, op, status, …, t}
signal sequence_finished(rec: Dictionary)  # {type:"seq_done", seq, status, completed, t}
signal shot_requested(seq: String, id: int, label: String)   # bridge does the tagged 0x02 capture
signal reload_requested()                  # bridge does JavaScriptBridge.eval("location.reload()")
signal progress(text: String)              # live badge readout ("" clears it)
signal override_triggered()                # any local human input while granted (§6.4) — bridge decides grant fate

# ── Tunables ─────────────────────────────────────────────────────────────────────────────────────
const SHOT_WATCHDOG_S := 10.0              # §4.6: screenshot fails `timeout` under sustained backpressure
const OVERRIDE_MOUSE_VEL := 40.0           # px/s poll threshold (get_last_mouse_velocity) — ignore idle jitter
const OVERRIDE_MOUSE_PX := 3.0             # per-event relative-motion threshold (_unhandled_input)

## Ops that are RECOGNISED but not yet live in P2 — they return `unimplemented` (P3 lands the real
## §4 semantics + the player.gd intent seam). This is a data list, not a dispatch path.
const STUB_OPS := ["move", "turn", "look", "jump", "set_fly", "break", "place", "select_slot"]

# Injected by the bridge (for the pos/yaw/facet snapshot in step events; P3 uses it as the intent seam).
var player: Node3D = null

# ── Sequence / step state ────────────────────────────────────────────────────────────────────────
var _seq := ""
var _on_fail := "abort"
var _steps: Array = []
var _idx := -1
var _finished_count := 0
var _running := false

var _cur: Dictionary = {}                  # the step in flight ({} between steps / when idle)
var _step_t0 := 0                          # msec at step start (dur_s)

var _wait_deadline := 0                    # msec — `wait`
var _shot_deadline := 0                    # msec — `screenshot` watchdog
var _shot_id := -1
var _shot_done := false
var _shot_ok := false

# Override arming: the consent CLICK that granted us may still be "pressed" for a frame — don't
# self-trigger. Arm only after one fully-idle frame; then any local input takes over.
var _override_armed := false
var _overridden := false


func is_running() -> bool:
	return _running


## Load + start a validated cmd_seq (the bridge has already ack'd + cap-checked it).
func begin_sequence(cmd: Dictionary) -> void:
	_seq = str(cmd.get("seq", ""))
	_on_fail = str(cmd.get("on_fail", "abort"))
	var steps_val = cmd.get("steps", [])
	_steps = (steps_val as Array).duplicate() if steps_val is Array else []
	_idx = -1
	_finished_count = 0
	_cur = {}
	_running = true
	_next_step()


## Halt NOW: zero any intent (P3 seam), emit the terminal record for the running step + the sequence.
## reason ∈ user_override | link_lost | aborted (revoke / preempt).
func abort(reason: String) -> void:
	if not _running:
		return
	if not _cur.is_empty():
		_finish_step(reason)                       # emits step_done + ends the sequence
	else:
		var seq_status := reason if reason == "user_override" or reason == "link_lost" else "aborted"
		_end_sequence(seq_status)


## Bridge → executor: the commanded screenshot for `id` was handed to the socket (ok) or failed.
func notify_shot(id: int, ok: bool) -> void:
	if id == _shot_id and not _shot_done:
		_shot_done = true
		_shot_ok = ok


func _process(_delta: float) -> void:
	# OVERRIDE is checked every tick regardless of run state — a granted-but-idle executor must still
	# hand control back the instant the human touches anything (the badge promises exactly this).
	_override_check()
	if _overridden or not _running or _cur.is_empty():
		return

	match str(_cur.get("op", "")):
		"wait":
			if Time.get_ticks_msec() >= _wait_deadline:
				_finish_step("ok")
		"screenshot":
			if _shot_done:
				_finish_step("ok" if _shot_ok else "timeout")
			elif Time.get_ticks_msec() >= _shot_deadline:
				_finish_step("timeout")
		# stop / reload / stubs resolve synchronously in _start_step; nothing to poll here.


func _next_step() -> void:
	_idx += 1
	if _idx >= _steps.size():
		_end_sequence("ok")
		return
	var st = _steps[_idx]
	if not (st is Dictionary):
		_cur = {"op": "", "id": null}
		_finish_step("bad_op")
		return
	_cur = st
	_step_t0 = Time.get_ticks_msec()
	_start_step()


func _start_step() -> void:
	var op := str(_cur.get("op", ""))
	var start_rec := {"type": "step_start", "seq": _seq, "id": _cur.get("id"), "op": op, "t": _now_s()}
	start_rec.merge(_snapshot())
	step_started.emit(start_rec)
	progress.emit(_progress_text())

	match op:
		"wait":
			var s := float(_cur.get("seconds", 0.0))
			_wait_deadline = Time.get_ticks_msec() + int(round(s * 1000.0))
		"screenshot":
			_shot_id = int(_cur.get("id", -1))
			_shot_done = false
			_shot_ok = false
			_shot_deadline = Time.get_ticks_msec() + int(SHOT_WATCHDOG_S * 1000.0)
			shot_requested.emit(_seq, _shot_id, str(_cur.get("label", "shot")))
		"stop":
			_finish_step("ok")                     # a labelled fence — the queue continues (§4.6)
		"reload":
			_finish_step("ok")                     # terminal: _finish_step fires reload_requested + ends seq
		_:
			if STUB_OPS.has(op):
				_finish_step("unimplemented", {"note": "P3 op not live in P2"})
			else:
				_finish_step("bad_op")             # defence-in-depth: never reached (bridge cap-checks the ack)


func _finish_step(status: String, extra: Dictionary = {}) -> void:
	if _cur.is_empty():
		return
	var op := str(_cur.get("op", ""))
	var rec := {
		"type": "step_done", "seq": _seq, "id": _cur.get("id"), "op": op, "status": status,
		"moved_blocks": 0.0, "turned_deg": 0.0, "reframes": 0,
		"dur_s": snappedf(float(Time.get_ticks_msec() - _step_t0) / 1000.0, 0.01), "t": _now_s(),
	}
	rec.merge(_snapshot())
	rec.merge(extra)
	_finished_count += 1
	_cur = {}
	step_finished.emit(rec)

	if status == "user_override":
		_end_sequence("user_override")
		return
	if status == "link_lost":
		_end_sequence("link_lost")
		return
	if op == "reload" and status == "ok":
		_end_sequence("ok")
		reload_requested.emit()                    # page navigates away — best-effort after the events flush
		return
	if status != "ok" and _on_fail == "abort":
		_end_sequence("failed")                    # remaining steps drained unrun (counted only in `completed`)
		return
	_next_step()


func _end_sequence(status: String) -> void:
	if not _running:
		return
	_running = false
	_cur = {}
	_steps = []
	sequence_finished.emit({
		"type": "seq_done", "seq": _seq, "status": status, "completed": _finished_count, "t": _now_s(),
	})
	progress.emit("")                              # clear the live step readout


# ── Human override (§6.4) — event-driven AND per-tick polled ──────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if _overridden or not _override_armed:
		return
	if event is InputEventKey:
		var kc := (event as InputEventKey).keycode
		if kc == KEY_ESCAPE or kc == KEY_F9:       # Esc / the revoke chord are REVOKE (activator), not override
			return
		if (event as InputEventKey).pressed and not (event as InputEventKey).echo:
			_trigger_override()
	elif event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed:
			_trigger_override()
	elif event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() > OVERRIDE_MOUSE_PX:
			_trigger_override()


func _override_check() -> void:
	if _overridden:
		return
	if not _override_armed:
		if not _any_local_input():                 # wait for one fully-idle frame before arming
			_override_armed = true
		return
	if _override_input():
		_trigger_override()


func _trigger_override() -> void:
	if _overridden:
		return
	_overridden = true
	override_triggered.emit()                      # bridge sends control_state:override + ends/suspends the grant
	if _running:
		abort("user_override")                     # zero intent + emit step_done/seq_done user_override


## Arming gate: ANY input (incl. Esc) keeps us un-armed, so we only arm once the console is idle.
func _any_local_input() -> bool:
	return Input.is_anything_pressed() or Input.get_last_mouse_velocity().length() > OVERRIDE_MOUSE_VEL


## Override trigger: any local input EXCEPT Esc / the revoke chord (those are handled as REVOKE).
func _override_input() -> bool:
	if Input.is_key_pressed(KEY_ESCAPE):
		return false
	if Input.is_key_pressed(KEY_F9) and Input.is_key_pressed(KEY_CTRL) and Input.is_key_pressed(KEY_SHIFT):
		return false
	if Input.is_anything_pressed():
		return true
	return Input.get_last_mouse_velocity().length() > OVERRIDE_MOUSE_VEL


func _snapshot() -> Dictionary:
	var d := {}
	if is_instance_valid(player):
		var p: Vector3 = player.global_position
		d["pos"] = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]
		d["yaw_deg"] = snappedf(rad_to_deg(player.rotation.y), 0.1)
	d["facet"] = TerrainConfig.active_facet()
	return d


func _progress_text() -> String:
	var op := str(_cur.get("op", ""))
	var extra := ""
	match op:
		"move": extra = " %s" % str(_cur.get("blocks", ""))
		"turn": extra = " %s°" % str(_cur.get("degrees", ""))
		"wait": extra = " %ss" % str(_cur.get("seconds", ""))
	return "step %d/%d: %s%s" % [_idx + 1, _steps.size(), op, extra]


func _now_s() -> float:
	return Time.get_unix_time_from_system()
