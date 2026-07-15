extends SceneTree
## Headless verification of the REMOTE-CONTROL P3 locomotion + mutation executor
## (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4). Drives a RemoteControl executor DIRECTLY against a live
## WorldManager + Player — no relay, no consent, no bridge — exercising the §4.2 intent seam end-to-end.
##
## Run: godot --headless --path godot --script res://src/tools/verify_remote_control.gd
##   exit 0 = all pass, 1 = any failure.
##
## Asserts:
##  (1) a `move` reaches its target within MOVE_TOL, driven through the REAL analytic locomotion pipeline;
##  (2) `break` / `place` route through the SAME WorldManager pipeline a human uses and mutate block_id_at;
##  (3) a `blocked` (no-progress) move reports status `blocked`;
##  (4) the watchdog fires `timeout` on a move that makes progress but never reaches its target;
##  (5) a FACETED ridge-crossing (reframe yaw) mid-move keeps the displacement accumulator CONTINUOUS.
##
## Tests (1)-(2) drive the REAL Player._physics_process loop (seam → real locomotion / mutation).
## Tests (3)-(5) direct-drive the executor's physics_tick with canned per-tick deltas + a synthetic
## reframe, so the §4 accumulator/stall/watchdog logic is deterministic and fast.

const RC := preload("res://src/net/remote_control.gd")

var _fail := 0
var _pass := 0
var _last_done: Dictionary = {}
var _last_seq: Dictionary = {}

var _world: WorldManager = null
var _player: Player = null
var _exec = null
var _phase := 0


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)


func _on_step_done(rec: Dictionary) -> void:
	_last_done = rec

func _on_seq_done(rec: Dictionary) -> void:
	_last_seq = rec


func _initialize() -> void:
	# Build the graph here, but run the tests from the first _process frame: in a `--script` SceneTree
	# tool the nodes added during _initialize don't get _ready (nor real tree membership) until AFTER
	# _initialize returns, so WorldManager/Player must be _ready before we drive them.
	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()

	_world = WorldManager.new()
	_world.name = "WM_RC"
	get_root().add_child(_world)

	_player = Player.new()
	_player.name = "Player_RC"
	_player.world = _world
	_player.inventory = Inventory.new()
	get_root().add_child(_player)                # _ready (built next frame) makes the camera rig + frame adapter

	_exec = RC.new()
	_exec.name = "Exec_RC"
	_exec.player = _player
	get_root().add_child(_exec)
	_exec.step_finished.connect(_on_step_done)
	_exec.sequence_finished.connect(_on_seq_done)
	_player.remote_exec = _exec


func _process(_delta: float) -> bool:
	if _phase != 0:
		return true                              # already done — keep quitting
	_phase = 1                                    # nodes are _ready now; the tree is live (global transforms valid)

	# Spawn on the surface and let gravity settle onto the analytic floor.
	var sx := 8
	var sz := 8
	var gy: int = TerrainConfig.height_at(sx, sz)
	_player.global_position = Vector3(sx + 0.5, gy + 2.0, sz + 0.5)
	_player.set_initial_look(0.0, 0.0)
	for _i in 90:
		_player._move(0.033)

	_test_move_reaches(_world, _player, _exec)
	_test_break_place(_world, _player, _exec)
	_test_blocked(_player, _exec)
	_test_timeout(_player, _exec)
	_test_crossing_continuity(_player, _exec)

	print("\n==== VERIFY-RC: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
	return true


# (1) A commanded walk of 2 blocks along a locally-flat heading, driven through the REAL locomotion core
# (the seam → _move → analytic walls/floor → per-tick displacement integration). moved_blocks lands
# within MOVE_TOL. We drive `_move` + the executor's physics_tick directly (the exact pair
# Player._physics_process runs) — no streaming/reanchor noise from a bare harness.
func _test_move_reaches(world: WorldManager, player: Player, exec: RC) -> void:
	print("[1] move reaches target through the real locomotion pipeline")
	var sx := int(floor(player.position.x))
	var sz := int(floor(player.position.z))
	var heading := _pick_flat_heading(sx, sz, int(floor(player.position.y)))
	var start := player.position
	_last_seq = {}
	exec.begin_sequence(_seq("rc-move", [{"id": 1, "op": "move", "blocks": 2.0, "heading": heading, "gait": "walk"}]))
	_pump_move(player, exec, 6000, 0.033)
	_ok(exec.has_method("physics_tick"), "executor exposes physics_tick (the §4.3 seam entry)")
	_ok(str(_last_done.get("status", "")) == "ok", "move step status ok (heading %s, got %s)" % [heading, str(_last_done.get("status", ""))])
	var moved := float(_last_done.get("moved_blocks", -1.0))
	_ok(absf(moved - 2.0) <= exec.MOVE_TOL, "moved_blocks %.3f within MOVE_TOL of 2.0" % moved)
	# The rover actually translated horizontally (real locomotion, not a no-op) and stopped moving.
	var flat := player.position - start
	flat.y = 0.0
	_ok(flat.length() >= 1.7, "player horizontally displaced %.2f blocks (real locomotion)" % flat.length())
	_ok(not player.remote_drive and player.remote_input == Vector3.ZERO, "intent zeroed after the step (rover stopped)")
	_ok(str(_last_seq.get("status", "")) == "ok", "seq_done status ok")
	# Settle a few plain (non-remote) locomotion ticks so the player rests on the floor for the break test.
	for _i in 20:
		player._move(0.033)


# (2) break + place route through the SAME WorldManager break/place pipeline a human uses and mutate
# block_id_at. Targets are player-relative cell offsets (the {dx,dy,dz} target mode).
func _test_break_place(world: WorldManager, player: Player, exec: RC) -> void:
	print("[2] break/place route through WorldManager + mutate block_id_at")
	var p := player.position
	var feet := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var cell := feet + Vector3i(0, -1, 0)        # the block directly under the feet (always solid ground)
	_ok(world.block_id_at(cell) > 0, "precondition: cell under feet is solid (%d)" % world.block_id_at(cell))

	# BREAK it via the offset target.
	_last_done = {}
	exec.begin_sequence(_seq("rc-break", [{"id": 1, "op": "break", "target": {"dx": 0, "dy": -1, "dz": 0}}]))
	_ok(str(_last_done.get("status", "")) == "ok", "break step status ok")
	_ok(world.block_id_at(cell) == 0, "break mutated block_id_at → air (was solid)")

	# PLACE a stone back into that now-air, still-supported cell.
	var STONE := BlockCatalog.id_of(&"stone")
	inv_grant(player, STONE)
	_last_done = {}
	exec.begin_sequence(_seq("rc-place", [{"id": 1, "op": "place", "block": STONE, "target": {"dx": 0, "dy": -1, "dz": 0}}]))
	_ok(str(_last_done.get("status", "")) == "ok", "place step status ok")
	_ok(world.block_id_at(cell) == STONE, "place mutated block_id_at → stone (id %d, got %d)" % [STONE, world.block_id_at(cell)])


# (3) A move that makes NO progress must report `blocked` (the analytic wall zeroed the axis / wood pin).
# Direct-drive with zero per-tick displacement while real time passes the stall window.
func _test_blocked(player: Player, exec: RC) -> void:
	print("[3] blocked move reports `blocked`")
	_last_done = {}
	exec.begin_sequence(_seq("rc-blocked", [{"id": 1, "op": "move", "blocks": 5.0, "heading": "forward", "gait": "walk"}]))
	var t0 := Time.get_ticks_msec()
	while exec.is_running() and Time.get_ticks_msec() - t0 < 4000:
		exec.physics_tick(0.016, Vector3.ZERO, 0.0)   # commanded, but NO displacement (obstructed)
		OS.delay_msec(150)
	_ok(str(_last_done.get("status", "")) == "blocked", "status blocked (got %s)" % str(_last_done.get("status", "")))


# (4) A move that keeps progressing (so it never trips the stall detector) but is too slow to reach the
# target inside the watchdog must report `timeout`.
func _test_timeout(player: Player, exec: RC) -> void:
	print("[4] watchdog fires `timeout`")
	_last_done = {}
	exec.begin_sequence(_seq("rc-timeout", [{"id": 1, "op": "move", "blocks": 1.0, "heading": "forward", "gait": "walk"}]))
	var t0 := Time.get_ticks_msec()
	while exec.is_running() and Time.get_ticks_msec() - t0 < 6000:
		var h: Vector3 = exec.get("_move_h")
		exec.physics_tick(0.016, h * 0.06, 0.0)        # steady 0.06 blocks/tick (> stall floor, < target)
		OS.delay_msec(300)
	_ok(str(_last_done.get("status", "")) == "timeout", "status timeout (got %s)" % str(_last_done.get("status", "")))


# (5) A facet reframe (dihedral yaw) mid-move must NOT discontinuity the accumulator: the tick's
# projection is added in the pre-crossing frame, then the heading rotates for subsequent ticks. Distance
# walked stays continuous across the seam and the step still lands within tolerance with reframes >= 1.
func _test_crossing_continuity(player: Player, exec: RC) -> void:
	print("[5] faceted ridge-crossing keeps the displacement accumulator continuous")
	_last_done = {}
	exec.begin_sequence(_seq("rc-cross", [{"id": 1, "op": "move", "blocks": 4.0, "heading": "forward", "gait": "walk"}]))
	# Feed the pre-crossing heading; rotate our feed vector by the same yaw the crossing applies, so it
	# stays aligned with the executor's rotated accumulator heading (exactly what a real reframe does).
	var feed_h := player.transform.basis * Vector3(0, 0, -1)
	feed_h.y = 0.0
	feed_h = feed_h.normalized()
	var injected := false
	var acc_before := -1.0
	var acc_after := -1.0
	var guard := 0
	while exec.is_running() and guard < 2000:
		guard += 1
		var acc: float = exec.get("_move_acc")
		if not injected and acc >= 2.0:
			acc_before = acc
			exec.physics_tick(0.016, feed_h * 0.1, deg_to_rad(30.0))
			acc_after = exec.get("_move_acc")
			feed_h = feed_h.rotated(Vector3.UP, deg_to_rad(30.0))
			injected = true
		else:
			exec.physics_tick(0.016, feed_h * 0.1, 0.0)
	_ok(injected, "reframe was injected mid-move (acc reached the trigger)")
	# Continuity: the reframe tick added exactly its projection (0.1) — no jump, no reset.
	_ok(acc_before >= 0.0 and absf((acc_after - acc_before) - 0.1) < 1e-3,
		"accumulator continuous across the reframe (Δacc %.4f == fed 0.1)" % (acc_after - acc_before))
	_ok(int(_last_done.get("reframes", 0)) >= 1, "reframes >= 1 recorded (got %d)" % int(_last_done.get("reframes", 0)))
	_ok(str(_last_done.get("status", "")) == "ok", "crossing move completes ok (got %s)" % str(_last_done.get("status", "")))
	var moved := float(_last_done.get("moved_blocks", -1.0))
	_ok(absf(moved - 4.0) <= exec.MOVE_TOL, "moved_blocks %.3f within MOVE_TOL of 4.0 despite the crossing" % moved)


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────────
func _seq(id: String, steps: Array) -> Dictionary:
	return {"type": "cmd_seq", "seq": id, "issued": Time.get_unix_time_from_system(), "on_fail": "abort", "steps": steps}


# Drive the exact locomotion pair Player._physics_process runs (minus the streaming/reanchor corrections
# a bare harness can't fully stand up): capture the pre-move LATTICE position, run _move, forward the
# horizontal displacement to the executor's physics_tick. This is the REAL analytic locomotion pipeline.
func _pump_move(player: Player, exec: RC, max_ms: int, dt: float) -> void:
	var t0 := Time.get_ticks_msec()
	while exec.is_running() and Time.get_ticks_msec() - t0 < max_ms:
		var pre := player.position
		player._move(dt)
		var d := player.position - pre
		d.y = 0.0
		exec.physics_tick(dt, d, 0.0)


# The first of forward(−Z)/back(+Z)/left(−X)/right(+X) whose next 3 cells never step UP from base_h (an
# upward step is what the analytic wall blocks); flat or downhill keeps locomotion free.
func _pick_flat_heading(sx: int, sz: int, base_h: int) -> String:
	var dirs := [["forward", Vector2i(0, -1)], ["back", Vector2i(0, 1)], ["left", Vector2i(-1, 0)], ["right", Vector2i(1, 0)]]
	for entry in dirs:
		var d: Vector2i = entry[1]
		var flat := true
		for k in range(1, 4):
			if TerrainConfig.height_at(sx + d.x * k, sz + d.y * k) > base_h:
				flat = false
				break
		if flat:
			return str(entry[0])
	return "forward"


func inv_grant(player: Player, block_id: int) -> void:
	player.inventory.add(block_id, 5)
	# Select whichever slot now holds it, so remote_place's inventory bookkeeping matches.
	for i in 9:
		if player.inventory.slot(i).get("id", 0) == block_id:
			player.inventory.select_slot(i)
			return
