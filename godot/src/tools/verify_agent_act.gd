extends SceneTree
## COSMOS-AGENT-AUTONOMY A1/A2 gate (FP_AGENT_ACT). Runs FLAT (no facet needed): break_cell fells the exact
## absolute cell + typed why; the aim solution's sign conventions + the 1-wide-pillar DDA (trunk-threading)
## regression; byte-off (flag off ⇒ _validate_cmd nacks caps). Run: godot --headless --path godot --script res://src/tools/verify_agent_act.gd

var _fail := 0
var _pass := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else: _fail += 1; push_error("FAIL: " + m); print("  FAIL: ", m)

func _initialize() -> void:
	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()
	_test_break_cell()
	_test_aim_solution()
	_test_aim_dda_pillar()
	_test_byte_off()
	print("==== VERIFY-AGENT-ACT: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _mk_player(wm: WorldManager) -> Player:
	var p := Player.new()
	p.world = wm
	p.inventory = Inventory.new()
	return p

## Top SOLID cell of column (x,z), scanned high→low (place_block needs a supported target).
func _surface_top(wm: WorldManager, x: int, z: int) -> int:
	for y in range(400, -64, -1):
		if wm.cell_solid(Vector3i(x, y, z)): return y
	return -64

func _test_break_cell() -> void:
	var wm := WorldManager.new()
	# place a STONE on the generated surface (supported), then fell exactly that cell.
	var top := _surface_top(wm, 30, 30)
	var cell := Vector3i(30, top + 1, 30)
	_ok(wm.place_block(cell, 3), "place STONE(3) on the surface (supported)")
	var p := _mk_player(wm)
	p.position = Vector3(30, top + 1, 31)                  # ~1.5 blocks away → within break_reach
	var r: Dictionary = p.remote_break_cell(cell)
	_ok(str(r.get("why", "")) == "ok" and int(r.get("block_id", 0)) == 3, "break_cell fells the exact cell (why ok, id 3)")
	_ok(not wm.cell_solid(cell), "cell reads air after break_cell")
	var r2: Dictionary = p.remote_break_cell(cell)
	_ok(str(r2.get("why", "")) == "air", "re-break of an empty cell ⇒ why:air")
	# out of reach: a solid generated surface cell 40 blocks away — untouched.
	var far := Vector3i(70, _surface_top(wm, 70, 30), 30)
	_ok(wm.cell_solid(far), "far surface cell is solid (precondition)")
	var r3: Dictionary = p.remote_break_cell(far)
	_ok(str(r3.get("why", "")) == "out_of_reach" and wm.cell_solid(far), "far cell ⇒ out_of_reach, world untouched")
	p.queue_free(); wm.queue_free()

func _test_aim_solution() -> void:
	var wm := WorldManager.new()
	var p := _mk_player(wm)
	p.position = Vector3(0, 100, 0)
	p.rotation.y = 0.0
	# cell straight ahead (-Z from eye): yaw ≈ 0, pitch ≈ 0.
	var ahead := p.remote_aim_solution(Vector3i(0, 101, -6))     # eye y=101.7; d≈(0.5,-0.2,-5.5)
	_ok(absf(float(ahead["yaw"])) < 0.15, "aim: cell ahead ⇒ yaw≈0 (got %.3f)" % float(ahead["yaw"]))
	_ok(absf(float(ahead["pitch"])) < 0.2, "aim: level cell ⇒ pitch≈0")
	# cell below ⇒ pitch < 0 (looks down).
	var below := p.remote_aim_solution(Vector3i(0, 90, -4))
	_ok(float(below["pitch"]) < -0.2, "aim: cell below ⇒ pitch<0 (looks down)")
	# cell behind (+Z) ⇒ |yaw| ≈ π.
	var behind := p.remote_aim_solution(Vector3i(0, 101, 6))
	_ok(absf(absf(float(behind["yaw"])) - PI) < 0.15, "aim: cell behind ⇒ |yaw|≈π")
	# cell to the +X (player-right; -Z fwd means +X is to the... yaw = atan2(-dx,-dz)) ⇒ yaw negative.
	var right := p.remote_aim_solution(Vector3i(6, 101, 0))
	_ok(float(right["yaw"]) < -1.0, "aim: cell to +X ⇒ yaw≈-π/2")
	p.queue_free(); wm.queue_free()

func _test_aim_dda_pillar() -> void:
	# THE 1-wide-trunk regression: a centre-aimed ray must HIT a 1-wide pillar (the DDA no longer threads past).
	# Build a supported 2-high pillar rising ABOVE the surface, then aim horizontally at its top cell so the
	# ray travels through air (neighbours at that height are empty) and can only strike the pillar.
	var wm := WorldManager.new()
	var top := _surface_top(wm, 20, 20)
	wm.place_block(Vector3i(20, top + 1, 20), 3)               # supported by the surface
	var pillar := Vector3i(20, top + 2, 20)                    # 1-wide, stands proud of the surrounding ground
	wm.place_block(pillar, 3)                                  # supported by top+1
	var p := _mk_player(wm)
	p.position = Vector3(15, float(top + 2) + 0.5 - p.eye_height, 20)   # eye at the pillar-top cell centre, 5 W of it
	p.rotation.y = 0.0
	var sol: Dictionary = p.remote_aim_solution(pillar)
	var yaw := float(sol["yaw"]); var pit := float(sol["pitch"])
	var dir := Vector3(-sin(yaw) * cos(pit), sin(pit), -cos(yaw) * cos(pit))
	var eye := p.position + Vector3(0, p.eye_height, 0)
	var info: Dictionary = wm.aimed_voxel(eye, dir, 8.0)
	_ok(bool(info.get("hit", false)) and info.get("voxel", Vector3i.ZERO) == pillar,
		"aim solution → DDA hits the 1-wide pillar (no ray-threading)")
	p.queue_free(); wm.queue_free()

func _test_byte_off() -> void:
	# flag off (in-tree default) ⇒ _validate_cmd nacks caps for every autonomy op.
	var rb := RemoteBridge.new()
	for op in ["break_cell", "place_cell", "aim_cell", "goto", "chop_tree"]:
		var cmd := {"type": "cmd_seq", "seq": "g", "issued": Time.get_unix_time_from_system(),
			"steps": [{"op": op, "cell": [1, 2, 3], "block": 3, "max_range": 20}]}
		_ok(rb._validate_cmd(cmd) == "caps", "byte-off: %s nacks caps with FP_AGENT_ACT/NAV/SKILL false" % op)
	rb.free()
