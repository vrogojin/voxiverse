extends SceneTree
## COSMOS-AGENT-AUTONOMY A3 gate (FP_AGENT_NAV). Pure planner over a synthetic grid (MockWorld) — flat run,
## wall routing, the ledge step-UP (the stall fix), the drop-cap pit, liquid avoidance, node cap, determinism.
## Runs FLAT (AgentNav is world-agnostic). Run: godot --headless --path godot --script res://src/tools/verify_agent_nav.gd

var _fail := 0
var _pass := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else: _fail += 1; push_error("FAIL: " + m); print("  FAIL: ", m)

# Minimal world: `solid` cells (Vector3i→true) + `liquid` cells (Vector3i→water id 44). Mirrors the two
# methods AgentNav reads (cell_solid / block_id_at).
class MockWorld extends RefCounted:
	var solid := {}
	var liquid := {}
	func cell_solid(c: Vector3i) -> bool: return solid.has(c)
	func block_id_at(c: Vector3i) -> int:
		if solid.has(c): return 3
		if liquid.has(c): return 44
		return 0
	func floor_row(x0: int, x1: int, z0: int, z1: int, y: int) -> void:
		for x in range(x0, x1 + 1):
			for z in range(z0, z1 + 1):
				solid[Vector3i(x, y, z)] = true

func _plan(w, from: Vector3i, goal: Vector3i, mode: String) -> Dictionary:
	var nav := AgentNav.new()
	var st := {}
	var guard := 0
	while not nav.plan_slice(w, from, goal, mode, st, 4096) and guard < 200:
		guard += 1
	return st

func _initialize() -> void:
	_test_flat()
	_test_wall()
	_test_ledge()
	_test_pit()
	_test_liquid()
	_test_cap_and_determinism()
	print("==== VERIFY-AGENT-NAV: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _test_flat() -> void:
	var w := MockWorld.new(); w.floor_row(-2, 10, -2, 2, 0)
	var st := _plan(w, Vector3i(0, 1, 0), Vector3i(5, 1, 0), "stand")
	_ok(str(st.get("result", "")) == "ok", "flat: path found")
	var path: Array = st.get("path", [])
	_ok(path.size() == 5, "flat: length == Manhattan 5 (got %d)" % path.size())
	var flat := true
	for c in path:
		if (c as Vector3i).y != 1: flat = false
	_ok(flat, "flat: every waypoint stays at y=1")

func _test_wall() -> void:
	var w := MockWorld.new(); w.floor_row(-2, 10, -3, 3, 0)
	for y in range(1, 3):                                   # a solid wall at x=3, z=-1..1 (gap at z=2 to route around)
		w.solid[Vector3i(3, y, -1)] = true
		w.solid[Vector3i(3, y, 0)] = true
		w.solid[Vector3i(3, y, 1)] = true
	var st := _plan(w, Vector3i(0, 1, 0), Vector3i(6, 1, 0), "stand")
	_ok(str(st.get("result", "")) == "ok", "wall: path found (routes around)")
	var blocked := false
	for c in st.get("path", []):
		if (c as Vector3i) == Vector3i(3, 1, 0) or (c as Vector3i) == Vector3i(3, 1, -1) or (c as Vector3i) == Vector3i(3, 1, 1):
			blocked = true
	_ok(not blocked, "wall: no waypoint inside the wall")

func _test_ledge() -> void:
	var w := MockWorld.new()
	w.floor_row(-2, 2, -2, 2, 0)                            # low floor y=0 for x≤2
	w.floor_row(3, 8, -2, 2, 1)                             # raised floor y=1 for x≥3 (a 1-block ledge)
	var st := _plan(w, Vector3i(0, 1, 0), Vector3i(5, 2, 0), "stand")
	_ok(str(st.get("result", "")) == "ok", "ledge: path found")
	var has_up := false
	for c in st.get("path", []):
		if (c as Vector3i).y == 2: has_up = true
	_ok(has_up, "ledge: path contains a step-UP (y=2) — the auto-jump the follower executes")

func _test_pit() -> void:
	var w := MockWorld.new()
	w.floor_row(-2, 1, -2, 2, 0)
	w.floor_row(2, 4, -2, 2, -5)                            # a 5-deep pit (> NAV_DROP_MAX 3)
	w.floor_row(5, 8, -2, 2, 0)
	var st := _plan(w, Vector3i(0, 1, 0), Vector3i(6, 1, 0), "stand")
	_ok(str(st.get("result", "")) == "no_path", "pit: no path across a >3-deep drop")

func _test_liquid() -> void:
	var w := MockWorld.new(); w.floor_row(-2, 8, -3, 3, 0)
	w.liquid[Vector3i(3, 1, 0)] = true                     # water blocks the direct line; detour in z is open
	var st := _plan(w, Vector3i(0, 1, 0), Vector3i(6, 1, 0), "stand")
	_ok(str(st.get("result", "")) == "ok", "liquid: path found (routes around)")
	var over_water := false
	for c in st.get("path", []):
		if (c as Vector3i) == Vector3i(3, 1, 0): over_water = true
	_ok(not over_water, "liquid: never a waypoint over water")

func _test_cap_and_determinism() -> void:
	var w := MockWorld.new(); w.floor_row(-2, 10, -2, 2, 0)
	# out-of-range goal ⇒ no_path (range cap), expansions bounded.
	var st := _plan(w, Vector3i(0, 1, 0), Vector3i(200, 1, 0), "stand")
	_ok(str(st.get("result", "")) == "no_path", "cap: out-of-range goal ⇒ no_path")
	_ok(int(st.get("exp", 0)) <= CubeSphere.NAV_NODE_CAP, "cap: expansions ≤ NAV_NODE_CAP")
	# determinism: identical grid ⇒ identical path.
	var a := _plan(w, Vector3i(0, 1, 0), Vector3i(6, 1, 1), "stand")
	var b := _plan(w, Vector3i(0, 1, 0), Vector3i(6, 1, 1), "stand")
	_ok(a.get("path", []) == b.get("path", []), "determinism: same grid ⇒ same path")
