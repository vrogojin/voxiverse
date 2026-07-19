class_name RemoteControl
extends Node
## REMOTE-CONTROL EXECUTOR — Phase 2 (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4). The step-sequence
## runner that pairs with the relay's forward gate. Created by RemoteBridge ONLY after a human has
## consented to control (§6.1); freed on revoke / override / link-loss. It NEVER exists in normal
## play, in an observe-only session, or when RemoteBridge.CONTROL_ENABLED is false — the same
## "dead in normal play" discipline as RemoteBridge itself. verify_feature never runs main.gd, so
## this node never exists under the headless gate (the 6027/0 tally is structural).
##
## P3 SCOPE (control stays INERT until P4 flips CONTROL_ENABLED): the FULL §4 closed-loop executor is
## live. `move`/`turn`/`look`/`jump`/`set_fly` drive the player through the INTENT SEAM (player.gd §4.2)
## — real locomotion through the identical analytic pipeline a human uses, verified by per-tick
## displacement integration (never a teleport). `break`/`place`/`select_slot` (resolved D5) route through
## the SAME WorldManager break/place/collapse + inventory pipeline (reach + rules enforced). `wait`/
## `screenshot`/`stop`/`reload` are unchanged from P2. An op outside the whitelist is `bad_op`.
##
## SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md): `dev_nav`/`nav`/`thrust`/`roll` add the dev/test space-nav verbs
## so the orchestrator can fly scripted orbital/interplanetary missions. `dev_nav`(F) and `nav`(O/G/R) resolve
## synchronously via the player's gated remote_set_dev_nav/remote_nav_verb; `thrust`(WASD+Space/Ctrl) and
## `roll`(Q/E) are TIMED held-input steps that arm the player's own intent seam for `seconds` then release it —
## the SAME analytic fly / dev-flight / coast paths a human's keystrokes drive. All inert unless the space-nav
## flags are enabled AND dev-nav is engaged (they report `blocked`/no-op otherwise).
##
## SECURITY: the executor's actuator surface is EXACTLY the five player intent fields (remote_drive/
## input/run/jump/yaw_rate) + the reused player break/place/select_slot/set_fly/pitch methods + the
## screenshot/reload requests. It synthesises no raw key/mouse input and reaches nothing outside game
## actions; every mutation is the human WorldManager pipeline. The human OVERRIDE (§6.4) is observed
## here — ANY local key/mouse (except Esc / the
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

# ── §4 locomotion tunables ─────────────────────────────────────────────────────────────────────────
const MOVE_TOL := 0.15                     # blocks — |moved_blocks − blocks| within this ⇒ `ok` (§4.4)
const MOVE_STALL_BLOCKS := 0.05            # < this progress over the stall window while driving ⇒ `blocked`
const MOVE_STALL_MS := 1500                # §4.4 sliding obstruction window
const MOVE_WATCHDOG_CAP_S := 60.0          # §4.4 hard cap on blocks/speed×3 + 2 s
const TURN_RATE_DEG := 120.0               # §4.5 easing rate for turn / look-yaw / look-pitch
const TURN_TOL_DEG := 0.5                  # §4.5 completion tolerance (degrees)
const TURN_WATCHDOG_S := 10.0              # §4.5 belt-and-braces (can't realistically fire)
const JUMP_WATCHDOG_S := 5.0               # §4.6 never-grounded ⇒ `timeout`
const LOOK_WATCHDOG_S := 10.0              # look easing bound
const ROLL_RATE_DEG := 60.0               # SPACE-FLY: the roll step's held rate (deg/s) → rad/s seam (docs/COSMOS-SPACEFLY-DESIGN.md)
const PITCH_MIN_DEG := -85.0               # §1.1 look.pitch_deg clamp
const PITCH_MAX_DEG := 85.0

# Injected by the bridge (the intent seam + the pos/yaw/facet snapshot in step events).
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
var _hold_deadline := 0                    # msec — SPACE-FLY `thrust`/`roll` timed HELD-input step (docs/COSMOS-SPACEFLY-DESIGN.md)
var _shot_deadline := 0                    # msec — `screenshot` watchdog
var _shot_id := -1
var _shot_done := false
var _shot_ok := false

# ── §4.4 move state (closed-loop displacement, robust to reanchor/reframe) ──────────────────────────
var _move_target := 0.0                    # commanded blocks
var _move_acc := 0.0                        # integrated along-heading displacement (the frame-free scalar)
var _move_h := Vector3.ZERO                 # along-heading unit vector (lattice); rotated by each reframe
var _move_speed := 0.0                       # gait speed (blocks/s) for stop-anticipation + watchdog
var _move_reframes := 0                      # facet crossings during this step (explains pos discontinuities)
var _move_deadline := 0                      # msec watchdog
var _stall_ref_acc := 0.0                    # acc at the last significant-progress mark (obstruction detect)
var _stall_ref_ms := 0

# ── §4.5 turn / look state (remaining-degrees easing; seam-immune across crossings) ─────────────────
var _turn_total := 0.0                       # signed radians commanded (+ = left)
var _turn_remaining := 0.0                   # signed radians left to apply
var _turn_deadline := 0
var _pitch_active := false                   # this look step also eases pitch
var _pitch_target := 0.0                     # absolute radians

# ── §4.6 jump state ─────────────────────────────────────────────────────────────────────────────────
var _jump_deadline := 0

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
		"thrust", "roll":
			# SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md): a TIMED held-input step. The seam (remote_input/run or
			# remote_roll_rate) was armed in _start_step and is consumed by the player's own _move / _attitude_tick
			# every tick; here we only watch the clock and release it (via _zero_intent in _finish_step) at the deadline.
			if Time.get_ticks_msec() >= _hold_deadline:
				_finish_step("ok")
		# move / turn / look / jump advance from physics_tick (below); stop / reload / set_fly / break /
		# place / select_slot / dev_nav / nav resolve synchronously in _start_step; nothing else to poll here.


# ══════════════════════════════════════════════════════════════════════════════════════════════════
# LOCOMOTION EXECUTION (§4.3) — driven from Player._physics_process, AFTER _move() and the origin/frame
# corrections, so measurement sees pure locomotion displacement (pre-reanchor) and the crossing yaw is
# known. `tick_move_delta` is this tick's _move() horizontal LATTICE displacement; `reframe_yaw` is any
# facet crossing's dihedral twist this tick (0 otherwise). No-op unless a move/turn/look/jump step runs.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
func physics_tick(delta: float, tick_move_delta: Vector3, reframe_yaw: float) -> void:
	if _overridden or not _running or _cur.is_empty():
		return
	match str(_cur.get("op", "")):
		"move":
			_tick_move(delta, tick_move_delta, reframe_yaw)
		"turn", "look":
			_tick_turn_look(delta)
		"jump":
			# The one-shot latch clears the first grounded tick (lift-off) — done when the player consumed it.
			if not bool(_player_get("remote_jump", false)):
				_finish_step("ok")
			elif Time.get_ticks_msec() >= _jump_deadline:
				_finish_step("timeout")


# ── move (§4.4) ─────────────────────────────────────────────────────────────────────────────────────
func _start_move() -> void:
	if not is_instance_valid(player):
		_finish_step("bad_op")
		return
	var blocks := float(_cur.get("blocks", 0.0))
	if blocks <= 0.0:
		_finish_step("bad_op")
		return
	var input := _heading_input(str(_cur.get("heading", "forward")))
	# The along-heading unit vector in the LATTICE frame (same frame tick_move_delta is measured in).
	var basis: Basis = player.transform.basis
	var h: Vector3 = basis * input
	h.y = 0.0
	if h.length() < 1e-6:
		_finish_step("blocked")
		return
	_move_h = h.normalized()
	_move_target = blocks
	_move_acc = 0.0
	_move_reframes = 0
	var run := str(_cur.get("gait", "walk")) == "run"
	var flying := bool(_player_get("flying", false))
	if flying:
		_move_speed = float(_player_get("fly_speed", 16.0)) * (2.0 if run else 1.0)
	else:
		_move_speed = float(_player_get("run_speed", 9.5)) if run else float(_player_get("walk_speed", 5.5))
	var wd := minf(blocks / maxf(_move_speed, 0.001) * 3.0 + 2.0, MOVE_WATCHDOG_CAP_S)
	_move_deadline = Time.get_ticks_msec() + int(wd * 1000.0)
	_stall_ref_acc = 0.0
	_stall_ref_ms = Time.get_ticks_msec()
	# Arm the intent seam — consumed by the NEXT Player._move().
	player.set("remote_input", input)
	player.set("remote_run", run)
	player.set("remote_drive", true)


func _tick_move(delta: float, tick_move_delta: Vector3, reframe_yaw: float) -> void:
	# Accumulate BEFORE rotating h — this tick's delta is expressed in the PRE-crossing frame.
	var proj := tick_move_delta.dot(_move_h)
	if proj > 0.0:                                 # negative projections (slide-back / rubber-band) don't add
		_move_acc += proj
	if reframe_yaw != 0.0:
		_move_h = _move_h.rotated(Vector3.UP, reframe_yaw).normalized()
		_move_reframes += 1
	# Obstruction: mark the last significant-progress point; stall past the window ⇒ blocked.
	if _move_acc - _stall_ref_acc >= MOVE_STALL_BLOCKS:
		_stall_ref_acc = _move_acc
		_stall_ref_ms = Time.get_ticks_msec()
	# Stop condition: half-tick anticipation so we land within MOVE_TOL of the target.
	if _move_acc >= _move_target - _move_speed * delta * 0.5:
		_finish_move("ok")
		return
	if Time.get_ticks_msec() >= _move_deadline:
		_finish_move("timeout")
		return
	if Time.get_ticks_msec() - _stall_ref_ms > MOVE_STALL_MS:
		_finish_move("blocked")


func _finish_move(status: String) -> void:
	_finish_step(status, {"moved_blocks": snappedf(_move_acc, 0.001), "reframes": _move_reframes})


# ── turn / look (§4.5) — remaining-degrees easing; a reframe's yaw twists BOTH current + target, so the
# remaining counter is untouched by crossings (seam-correctness is free). ──────────────────────────────
func _start_turn() -> void:
	var degrees := float(_cur.get("degrees", 0.0))
	if degrees <= 0.0:
		_finish_step("bad_op")
		return
	var yaw_sign := 1.0 if str(_cur.get("dir", "left")) == "left" else -1.0   # left = +yaw (matches mouse-look)
	_turn_total = deg_to_rad(degrees) * yaw_sign
	_turn_remaining = _turn_total
	_pitch_active = false
	_turn_deadline = Time.get_ticks_msec() + int(TURN_WATCHDOG_S * 1000.0)
	if is_instance_valid(player):
		player.set("remote_yaw_rate", deg_to_rad(TURN_RATE_DEG) * yaw_sign)


func _start_look() -> void:
	_turn_total = 0.0
	_turn_remaining = 0.0
	_pitch_active = false
	if _cur.has("yaw_deg"):
		_turn_total = deg_to_rad(float(_cur.get("yaw_deg", 0.0)))   # signed, + = left (sugar for turn)
		_turn_remaining = _turn_total
	if _cur.has("pitch_deg"):
		_pitch_active = true
		_pitch_target = deg_to_rad(clampf(float(_cur.get("pitch_deg", 0.0)), PITCH_MIN_DEG, PITCH_MAX_DEG))
	_turn_deadline = Time.get_ticks_msec() + int(LOOK_WATCHDOG_S * 1000.0)
	if is_instance_valid(player) and _turn_remaining != 0.0:
		player.set("remote_yaw_rate", signf(_turn_remaining) * deg_to_rad(TURN_RATE_DEG))
	if not _cur.has("yaw_deg") and not _cur.has("pitch_deg"):
		_finish_step("ok")                         # empty look — nothing to do


func _tick_turn_look(delta: float) -> void:
	var rate := deg_to_rad(TURN_RATE_DEG)
	var tol := deg_to_rad(TURN_TOL_DEG)
	var done := true
	# Yaw easing — the executor OWNS the exact rotate (seam-immune remaining-degrees counter).
	if absf(_turn_remaining) > tol:
		done = false
		var step := signf(_turn_remaining) * minf(rate * delta, absf(_turn_remaining))
		if is_instance_valid(player):
			player.rotate_y(step)
		_turn_remaining -= step
	# Pitch easing toward the absolute target.
	if _pitch_active:
		var cur := _player_pitch()
		if absf(_pitch_target - cur) > tol:
			done = false
			var pstep := clampf(_pitch_target - cur, -rate * delta, rate * delta)
			if is_instance_valid(player) and player.has_method("remote_set_pitch"):
				player.call("remote_set_pitch", cur + pstep)
	if done:
		_finish_step("ok", {"turned_deg": snappedf(rad_to_deg(absf(_turn_total - _turn_remaining)), 0.1)})
		return
	if Time.get_ticks_msec() >= _turn_deadline:
		_finish_step("timeout", {"turned_deg": snappedf(rad_to_deg(absf(_turn_total - _turn_remaining)), 0.1)})


# ── jump (§4.6) ─────────────────────────────────────────────────────────────────────────────────────
func _start_jump() -> void:
	if bool(_player_get("flying", false)):
		_finish_step("ok", {"note": "flying"})     # no-op + ok while airborne (§1.1)
		return
	if is_instance_valid(player):
		player.set("remote_jump", true)            # latched; consumed at the next grounded tick (lift-off)
	_jump_deadline = Time.get_ticks_msec() + int(JUMP_WATCHDOG_S * 1000.0)


# ── SPACE-FLY held-input steps (docs/COSMOS-SPACEFLY-DESIGN.md) ──────────────────────────────────────
## thrust: arm the body-local wish (dx=strafe, dy=vertical, dz=forward; +Z back to match the WASD `input`
## shape) + run for `seconds`. The seam feeds the player's own fly / dev-flight / coast-exit path each tick;
## the deadline poll (in _process) releases it. Vertical thrust (dy) is how a scripted flight climbs to orbit
## and de-orbits; forward (dz<0) is prograde. No motion happens unless dev-nav/fly is engaged.
func _start_thrust() -> void:
	var seconds := float(_cur.get("seconds", 0.0))
	if seconds <= 0.0:
		_finish_step("bad_op")
		return
	var wish := Vector3(float(_cur.get("dx", 0.0)), float(_cur.get("dy", 0.0)), float(_cur.get("dz", 0.0)))
	var run := str(_cur.get("gait", "walk")) == "run"
	if is_instance_valid(player) and player.has_method("remote_set_thrust"):
		player.call("remote_set_thrust", wish, run)
	_hold_deadline = Time.get_ticks_msec() + int(round(seconds * 1000.0))

## roll: hold a Q/E roll rate (dir left=+ / right=−) for `seconds`. Only bites under ORBIT_ATTITUDE in SPACE.
func _start_roll() -> void:
	var seconds := float(_cur.get("seconds", 0.0))
	if seconds <= 0.0:
		_finish_step("bad_op")
		return
	var roll_sign := 1.0 if str(_cur.get("dir", "left")) == "left" else -1.0
	if is_instance_valid(player) and player.has_method("remote_set_roll"):
		player.call("remote_set_roll", roll_sign * deg_to_rad(ROLL_RATE_DEG))
	_hold_deadline = Time.get_ticks_msec() + int(round(seconds * 1000.0))


# ── seam helpers ─────────────────────────────────────────────────────────────────────────────────────
## Zero every intent field so the rover halts within one physics tick (called FIRST on any terminal event).
func _zero_intent() -> void:
	if not is_instance_valid(player):
		return
	player.set("remote_drive", false)
	player.set("remote_input", Vector3.ZERO)
	player.set("remote_run", false)
	player.set("remote_jump", false)
	player.set("remote_yaw_rate", 0.0)
	player.set("remote_roll_rate", 0.0)        # SPACE-FLY: release a held roll on any terminal event (override/abort/step end)


## The body-local wish vector for a heading — the SAME shape as the WASD `input` (forward = −Z).
func _heading_input(heading: String) -> Vector3:
	match heading:
		"back": return Vector3(0, 0, 1)
		"left": return Vector3(-1, 0, 0)
		"right": return Vector3(1, 0, 0)
		_: return Vector3(0, 0, -1)                # forward (default)


func _player_get(prop: String, deflt: Variant) -> Variant:
	if is_instance_valid(player):
		var v: Variant = player.get(prop)
		if v != null:
			return v
	return deflt


func _player_pitch() -> float:
	if is_instance_valid(player) and player.has_method("remote_pitch"):
		return float(player.call("remote_pitch"))
	return 0.0


## Resolve a `target` param: a {dx,dy,dz} dict → a player-relative Vector3i offset; else the String "aim".
func _target_arg(t: Variant) -> Variant:
	if t is Dictionary:
		var d: Dictionary = t
		return Vector3i(int(d.get("dx", 0)), int(d.get("dy", 0)), int(d.get("dz", 0)))
	return "aim"


## Resolve a `block` param (id int or block name String) to a block id (0 = use the selected hotbar slot).
func _block_arg(b: Variant) -> int:
	if b is int or b is float:
		return int(b)
	if b is String:
		return BlockCatalog.id_of(StringName(b))
	return 0


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
		"move":
			_start_move()
		"turn":
			_start_turn()
		"look":
			_start_look()
		"jump":
			_start_jump()
		"set_fly":
			var on := bool(_cur.get("on", false))
			if is_instance_valid(player) and player.has_method("remote_set_fly"):
				player.call("remote_set_fly", on)
			_finish_step("ok")                     # §4.6: capsule disable + velocity zero replicated in the player
		"select_slot":
			var okk := false
			if is_instance_valid(player) and player.has_method("remote_select_slot"):
				okk = bool(player.call("remote_select_slot", int(_cur.get("n", 0))))
			_finish_step("ok" if okk else "blocked")
		"break":
			var bid := 0
			if is_instance_valid(player) and player.has_method("remote_break"):
				bid = int(player.call("remote_break", _target_arg(_cur.get("target", "aim"))))
			_finish_step("ok" if bid > 0 else "blocked")
		"place":
			var okk := false
			if is_instance_valid(player) and player.has_method("remote_place"):
				okk = bool(player.call("remote_place", _block_arg(_cur.get("block", 0)), _target_arg(_cur.get("target", "aim"))))
			_finish_step("ok" if okk else "blocked")
		"dev_nav":
			# SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md): F — drive dev-nav to a definite state. `blocked` when the
			# space-nav build is not running (SN_DEVNAV off), so a scripted flight fails loudly rather than flying blind.
			var on := bool(_cur.get("on", false))
			var okk := false
			if is_instance_valid(player) and player.has_method("remote_set_dev_nav"):
				okk = bool(player.call("remote_set_dev_nav", on))
			_finish_step("ok" if okk else "blocked")
		"nav":
			# SPACE-FLY: O/G/R — orbit-coast / geostationary / detach. `blocked` when the verb is inert (not dev-nav,
			# no BCI state, wrong mode) — the SAME condition a human keypress would be a no-op under.
			var okk := false
			if is_instance_valid(player) and player.has_method("remote_nav_verb"):
				okk = bool(player.call("remote_nav_verb", str(_cur.get("verb", ""))))
			_finish_step("ok" if okk else "blocked")
		"thrust":
			_start_thrust()
		"roll":
			_start_roll()
		"stop":
			_finish_step("ok")                     # a labelled fence — the queue continues (§4.6)
		"reload":
			_finish_step("ok")                     # terminal: _finish_step fires reload_requested + ends seq
		_:
			_finish_step("bad_op")                 # defence-in-depth: never reached (bridge cap-checks the ack)


func _finish_step(status: String, extra: Dictionary = {}) -> void:
	if _cur.is_empty():
		return
	_zero_intent()                                 # §4.3: intent zeroed FIRST — the rover stops within one tick
	var op := str(_cur.get("op", ""))
	var rec := {
		"type": "step_done", "seq": _seq, "id": _cur.get("id"), "op": op, "status": status,
		"moved_blocks": 0.0, "turned_deg": 0.0, "reframes": 0,
		"dur_s": snappedf(float(Time.get_ticks_msec() - _step_t0) / 1000.0, 0.01), "t": _now_s(),
	}
	rec.merge(_snapshot())
	rec.merge(extra, true)                          # overwrite the zero defaults with moved_blocks/turned_deg/reframes/note
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
	_zero_intent()                                 # belt-and-braces: no lingering intent after the sequence ends
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
	# F5: never hand the controls back mid-air. If the agent had toggled fly on, drop it so the human's
	# takeover starts from normal grounded locomotion rather than a lingering remote-set fly state.
	if is_instance_valid(player) and bool(_player_get("flying", false)) and player.has_method("remote_set_fly"):
		player.call("remote_set_fly", false)


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
