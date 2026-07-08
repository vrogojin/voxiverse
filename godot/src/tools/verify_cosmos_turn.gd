extends SceneTree
## COSMOS #71 — the home-face-flip TURN-COMPENSATION gate. A flip re-bases the window onto the neighbour
## face whose lattice is a D4 rotation of the old at the shared edge; chart.flip now returns that rotation
## as `yaw` and the player counter-rotates its heading + velocity by it, so a crossing does not snap the
## view. This gate exercises the REAL chart.flip across all 4 of face 4's edges and asserts that, with the
## returned yaw applied, the player's PHYSICAL forward + a velocity direction stay CONTINUOUS across the
## crossing (window-forward mapped through the home-face tangent frame at the shared edge). It is also the
## SIGN arbiter — a wrong-sign yaw shows as a ~2·angle error here. Runs on the FLAT binary (pure chart/CS
## math); FLAT byte-identity is covered by verify_feature (the player rotation only fires when a flip
## happens, which needs a chart → curved-only).
##   godot --headless --path godot --script res://src/tools/verify_cosmos_turn.gd

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func v(d) -> Vector3:
	return Vector3(d.x, d.y, d.z)

# Tangent basis (+i, +j) at face-cell (ci,cj) as raw central differences (direction is what matters).
func tangents(face: int, ci: int, cj: int, n: int) -> Array:
	var ei := v(CS.face_cell_to_dir(face, float(ci + 1), float(cj), n)) - v(CS.face_cell_to_dir(face, float(ci - 1), float(cj), n))
	var ej := v(CS.face_cell_to_dir(face, float(ci), float(cj + 1), n)) - v(CS.face_cell_to_dir(face, float(ci), float(cj - 1), n))
	return [ei.normalized(), ej.normalized()]

# A window-space heading (xz) mapped to a physical direction through a home-face tangent frame.
func phys_dir(win: Vector2, ei: Vector3, ej: Vector3) -> Vector3:
	return (ei * win.x + ej * win.y).normalized()

func _initialize() -> void:
	print("COSMOS #71 — home-face-flip turn compensation (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	var n := CS.n_for(CS.HOME_BODY)
	CS.warm_edge_tables(n)
	var mid := n / 2
	# One case per face-4 edge: a chart on face 4 + a local position ~70 cells past that edge (mid-edge, no
	# corner) so chart.flip fires and returns the edge's D4 yaw. {side_name, chart origin, local}.
	var cases := [
		{"name": "EAST",  "io": n - 10, "jo": mid, "lx": 80,  "lz": 0},
		{"name": "WEST",  "io": 10,     "jo": mid, "lx": -80, "lz": 0},
		{"name": "NORTH", "io": mid,    "jo": n - 10, "lx": 0, "lz": 80},
		{"name": "SOUTH", "io": mid,    "jo": 10,  "lx": 0,  "lz": -80},
	]
	# Test headings + one velocity direction, applied before vs after with the compensation yaw.
	var test_yaws := [0.0, 30.0, 90.0, 150.0, 210.0, 315.0]
	var worst := 0.0
	for c: Dictionary in cases:
		var chart := CHART.new(CS.HOME_BODY, 4, int(c["io"]), int(c["jo"]))
		var gi: int = int(c["io"]) + int(c["lx"])
		var gj: int = int(c["jo"]) + int(c["lz"])
		# The shared-edge cell on face 4 + the across-edge cell on the neighbour (exact D4 relation there).
		var edge4: Vector2i
		var edgeN: Dictionary
		match String(c["name"]):
			"EAST":  edge4 = Vector2i(n - 1, mid); edgeN = CS.fold_cell(4, n, mid, n)
			"WEST":  edge4 = Vector2i(0, mid);     edgeN = CS.fold_cell(4, -1, mid, n)
			"NORTH": edge4 = Vector2i(mid, n - 1); edgeN = CS.fold_cell(4, mid, n, n)
			_:       edge4 = Vector2i(mid, 0);     edgeN = CS.fold_cell(4, mid, -1, n)
		var res := chart.flip(Vector3(float(c["lx"]), 6.0, float(c["lz"])))   # THE real flip → yaw + new face
		_ok(bool(res["ok"]), "%s: flip executed (to face %d)" % [c["name"], int(res.get("to_face", -1))])
		var yaw := float(res["yaw"])
		var N := int(res["to_face"])
		_ok(N == int(edgeN["face"]), "%s: flip target matches the fold neighbour (face %d)" % [c["name"], N])
		var t4 := tangents(4, edge4.x, edge4.y, n)
		var tn := tangents(N, int(edgeN["i"]), int(edgeN["j"]), n)
		var worst_case := 0.0
		for deg: float in test_yaws:
			var y0 := deg_to_rad(deg)
			var y1 := y0 + yaw
			# Godot forward for yaw θ = (−sin θ, −cos θ) in (x,z); a velocity "east" test dir = (cos θ, −sin θ).
			var fwd0 := phys_dir(Vector2(-sin(y0), -cos(y0)), t4[0], t4[1])
			var fwd1 := phys_dir(Vector2(-sin(y1), -cos(y1)), tn[0], tn[1])
			var vel0 := phys_dir(Vector2(cos(y0), -sin(y0)), t4[0], t4[1])
			var vel1 := phys_dir(Vector2(cos(y1), -sin(y1)), tn[0], tn[1])
			var af := rad_to_deg(acos(clampf(fwd0.dot(fwd1), -1.0, 1.0)))
			var av := rad_to_deg(acos(clampf(vel0.dot(vel1), -1.0, 1.0)))
			worst_case = maxf(worst_case, maxf(af, av))
		worst = maxf(worst, worst_case)
		_ok(worst_case < 5.0, "%s (D4 yaw %.0f°): physical forward + velocity CONTINUOUS across the crossing (max err %.2f°)" % [c["name"], rad_to_deg(yaw), worst_case])
	print("  worst forward/velocity continuity error across all 4 edges: %.3f°  (≈0 correct; ~90/180 = wrong-sign)" % worst)
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
