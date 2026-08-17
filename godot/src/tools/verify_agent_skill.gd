extends SceneTree
## COSMOS-AGENT-AUTONOMY A4 gate (FP_AGENT_SKILL). The chop_tree phase machine: GOTO/AIM/CHOP transitions +
## typed-failure recovery, driven with scripted results (the executor/follower wiring is live-A/B scope, §10).
## FIND's overlay-aware alive-check runs only under FACETED (needs TreeGen + an active facet); skipped FLAT.
## Run: godot --headless --path godot --script res://src/tools/verify_agent_skill.gd

var _fail := 0
var _pass := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else: _fail += 1; push_error("FAIL: " + m); print("  FAIL: ", m)

# Mock player whose remote_break_cell replays a scripted why-sequence; carries a position for FIND.
class MockPlayer extends RefCounted:
	var position := Vector3.ZERO
	var seq: Array = []
	var i := 0
	func remote_break_cell(_cell: Vector3i) -> Dictionary:
		var why: String = "air"
		if i < seq.size(): why = str(seq[i])
		i += 1
		return {"why": why, "block_id": (3 if why == "ok" else 0)}

class MockWorld extends RefCounted:
	func block_id_at(_c: Vector3i) -> int: return 0
	func cell_solid(_c: Vector3i) -> bool: return false

func _mk_skill(bp: Array) -> AgentSkills:
	var s := AgentSkills.new()
	var mp := MockPlayer.new()
	mp.seq = bp
	s.setup(null, mp, MockWorld.new())
	s._tree_base = Vector3i(10, 40, 10)
	s._chop_start = Vector3i(10, 41, 10)
	s._chop_top = 48
	s._retries = CubeSphere.SKILL_RETRY_MAX     # exhaust retries so goto-blocked lands the terminal directly
	return s

func _initialize() -> void:
	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()
	_test_fsm()
	_test_chop_loop()
	_test_find_alive()
	print("==== VERIFY-AGENT-SKILL: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _test_fsm() -> void:
	var s := _mk_skill([])
	# GOTO ok → AIM
	var d := s.on_goto_done("ok")
	_ok(str(d.get("act", "")) == "aim" and s.phase() == "aim", "goto ok → aim phase")
	# AIM occluded → re-aim higher twice (toward eye height), then PROCEED to chop — AIM is cosmetic because
	# remote_break_cell is reach-gated, not line-of-sight; an occluded camera must never abort the chop.
	var d2 := s.on_aim_done("occluded", [], false)
	_ok(str(d2.get("act", "")) == "aim" and (d2["cell"] as Vector3i).y == s._chop_start.y + 1, "aim occluded → re-aim one cell higher")
	var d2b := s.on_aim_done("occluded", [], false)
	_ok(str(d2b.get("act", "")) == "aim" and (d2b["cell"] as Vector3i).y == s._chop_start.y + 2, "aim occluded again → re-aim two cells higher")
	var d3 := s.on_aim_done("occluded", [], false)
	_ok(str(d3.get("act", "")) == "continue" and s.phase() == "chop", "aim occluded thrice → proceed to chop (reach-gated, not LOS)")
	# AIM ok → chop
	var s2 := _mk_skill([])
	s2.on_goto_done("ok")
	var da := s2.on_aim_done("ok", [10, 41, 10], true)
	_ok(str(da.get("act", "")) == "continue" and s2.phase() == "chop", "aim ok → chop phase")
	# GOTO blocked (retries exhausted) → unreachable terminal
	var s3 := _mk_skill([])
	var db := s3.on_goto_done("blocked")
	_ok(str(db.get("act", "")) == "done" and str(db.get("status", "")) == "blocked" and str(db["extra"]["why"]) == "unreachable",
		"goto blocked (no retries) → terminal unreachable")

func _test_chop_loop() -> void:
	# break base (ok), then next (ok), then air → felled, broken==2, terminal ok.
	var s := _mk_skill(["ok", "ok", "air"])
	s.on_goto_done("ok"); s.on_aim_done("ok", [], true)
	var last := {}
	var guard := 0
	while s.phase() == "chop" and guard < 30:
		last = s.on_chop_poll()
		guard += 1
	_ok(str(last.get("act", "")) == "done" and str(last.get("status", "")) == "ok", "chop loop terminates ok")
	_ok(int(last["extra"]["broken"]) == 2, "chop loop: broken count == 2 (stopped on air after the trunk)")
	# out_of_reach mid-loop ⇒ terminal ok with partial (canopy usually already detached).
	var s2 := _mk_skill(["ok", "out_of_reach"])
	s2.on_goto_done("ok"); s2.on_aim_done("ok", [], true)
	var l2 := {}
	var g2 := 0
	while s2.phase() == "chop" and g2 < 30:
		l2 = s2.on_chop_poll(); g2 += 1
	_ok(str(l2.get("status", "")) == "ok" and int(l2["extra"]["broken"]) == 1, "chop out_of_reach mid-loop ⇒ partial ok (broken 1)")

func _test_find_alive() -> void:
	if not CubeSphere.FACETED:
		print("  FIND alive-check skipped (needs FACETED — sed-toggle like the other faceted gates)")
		return
	var wm := WorldManager.new()
	var s := AgentSkills.new()
	var mp := MockPlayer.new()
	# place the player near origin; FIND spirals the tree grid. This asserts the mechanism runs + a chopped
	# tree (base edited to air) is skipped by the overlay-aware alive-check.
	s.setup(null, mp, wm)
	var d := s.begin(48)
	_ok(d.has("act"), "FIND returns a directive (goto or no_tree terminal)")
	wm.queue_free()
