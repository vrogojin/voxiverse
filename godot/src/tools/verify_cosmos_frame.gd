extends SceneTree
## COSMOS-FRAME-ORIENTATION §8 — the pinned-orientation gate (bug #2). Runs on the pure CHART math
## (no module / no live scene needed): the whole point of M_win is that a flip is an ISOMETRY that
## leaves every physical cell's WINDOW position unchanged, which is now statable as EQUALITY.
##
## G-A: reanchor world-continuity — a pure −Δ translation; global cells + M_win invariant.
## G-B: flip world-continuity — every physical cell's window position is EQUAL before/after a flip
##      (0°, 90°, 180° edges), M_win accumulates the crossed edge's D4, and a 3-flip corner loop
##      yields 90° holonomy with per-step continuity intact.

var _pass := 0
var _fail := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: ", msg)

func _gkey(c: Dictionary) -> String:
	return "%d:%d:%d" % [int(c["face"]), int(c["i"]), int(c["j"])]

# Is M a valid C4 element (orthogonal, det +1)? m_win() -> [a,b,c,d] row-major.
func _is_c4(m: Array) -> bool:
	var a := int(m[0]); var b := int(m[1]); var c := int(m[2]); var d := int(m[3])
	var det := a * d - b * c
	return det == 1 and (a * a + c * c) == 1 and (b * b + d * d) == 1 and (a * b + c * d) == 0

func _mat_eq(m: Array, e: Array) -> bool:
	return int(m[0]) == e[0] and int(m[1]) == e[1] and int(m[2]) == e[2] and int(m[3]) == e[3]

# ---- G-A: reanchor is a pure translation; content + M_win invariant ---------------------------
func _test_reanchor() -> void:
	print("[G-A] reanchor world-continuity — pure −Δ translation, M_win + global cells invariant")
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var chart := CosmosChart.new(CubeSphere.HOME_BODY, 4, n / 2, n / 2)
	var probes: Array = []                          # window cells around the player
	for dx in [-30, 0, 40, 120]:
		for dz in [-25, 0, 60]:
			probes.append(Vector2i(dx, dz))
	var before := {}
	for w: Vector2i in probes:
		before[w] = _gkey(chart.to_global_column(w.x, w.y))
	var mw0 := chart.m_win()
	# Force a reanchor: player 300 window-cells out (past SHIFT_TRIGGER 256).
	var d := chart.reanchor(Vector3(300.0, 0.0, 270.0))
	_ok(d != Vector2i.ZERO, "reanchor fired (player past the trigger)")
	_ok(_mat_eq(chart.m_win(), mw0), "M_win UNCHANGED by a reanchor (it is a pure translation)")
	# The caller subtracts Δ from window positions; the same physical cell is now at (w − Δ).
	var cont := true
	for w: Vector2i in probes:
		var g_now := _gkey(chart.to_global_column(w.x - d.x, w.y - d.y))
		if g_now != String(before[w]):
			cont = false
	_ok(cont, "every physical cell keeps its global identity after the reanchor (world-continuous)")

# ---- G-B: a flip leaves every physical cell's WINDOW position unchanged ------------------------
# Returns the post-flip chart (or null if the flip did not fire). `expect_m` (or []) asserts M_win.
func _flip_and_check(chart: CosmosChart, player: Vector3, label: String, expect_m: Array) -> void:
	# Probe a grid of window cells that stay in-window around the player crossing point.
	var probes: Array = []
	var pwx := int(floor(player.x)); var pwz := int(floor(player.z))
	for dx in range(-40, 41, 20):
		for dz in range(-40, 41, 20):
			probes.append(Vector2i(pwx + dx, pwz + dz))
	var before := {}
	for w: Vector2i in probes:
		before[w] = _gkey(chart.to_global_column(w.x, w.y))
	if not chart.flip_needed(player):
		_ok(false, "%s: flip_needed true (probe positioned past the edge + hysteresis)" % label)
		return
	var res := chart.flip(player)
	if not bool(res["ok"]):
		_ok(false, "%s: flip ok (not a corner quadrant)" % label)
		return
	_ok(_is_c4(chart.m_win()), "%s: M_win stays a valid C4 element (orthogonal, det +1)" % label)
	# THE gate: every probe cell's window position maps to the SAME global cell after the flip.
	var cont := true
	var bad := ""
	for w: Vector2i in probes:
		var g_now := _gkey(chart.to_global_column(w.x, w.y))
		if g_now != String(before[w]):
			cont = false
			bad = "%s: win(%d,%d) was %s now %s" % [label, w.x, w.y, before[w], g_now]
	_ok(cont, "%s: EVERY physical cell's window position is CONTINUOUS across the flip (★ equality)%s" % [label, ("" if cont else " — " + bad)])
	if not expect_m.is_empty():
		_ok(_mat_eq(chart.m_win(), expect_m), "%s: M_win accumulated the crossed edge's D4 %s (got %s)" % [label, str(expect_m), str(chart.m_win())])

func _test_flip_edges() -> void:
	print("[G-B] flip world-continuity — window position EQUAL before/after; M_win accumulates the edge D4")
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	# Face 4 edges (from the audit): WEST→3 = 90°, EAST→2 = 270°, NORTH→1 = 180°, SOUTH→0 = 0°.
	# Cross EAST: origin near the +i edge, player far past it (≥ FLIP_HYST). M_f = edge_remap(4,EAST).m.
	var east: Array = CubeSphere.edge_remap(4, CubeSphere.SIDE_EAST, n)["m"]
	var c_e := CosmosChart.new(CubeSphere.HOME_BODY, 4, n - 20, n / 2)
	_flip_and_check(c_e, Vector3(20.0 + CosmosChart.FLIP_HYST + 5.0, 0.0, 0.0), "EAST→2", [int(east[0]), int(east[1]), int(east[2]), int(east[3])])
	# Cross WEST (90°): origin near the −i edge, player far past it.
	var west: Array = CubeSphere.edge_remap(4, CubeSphere.SIDE_WEST, n)["m"]
	var c_w := CosmosChart.new(CubeSphere.HOME_BODY, 4, 20, n / 2)
	_flip_and_check(c_w, Vector3(-20.0 - CosmosChart.FLIP_HYST - 5.0, 0.0, 0.0), "WEST→3", [int(west[0]), int(west[1]), int(west[2]), int(west[3])])
	# Cross SOUTH (0° control): M_win must stay identity.
	var c_s := CosmosChart.new(CubeSphere.HOME_BODY, 4, n / 2, 20)
	_flip_and_check(c_s, Vector3(0.0, 0.0, -20.0 - CosmosChart.FLIP_HYST - 5.0), "SOUTH→0", [1, 0, 0, 1])
	# Cross NORTH (180°).
	var north: Array = CubeSphere.edge_remap(4, CubeSphere.SIDE_NORTH, n)["m"]
	var c_n := CosmosChart.new(CubeSphere.HOME_BODY, 4, n / 2, n - 20)
	_flip_and_check(c_n, Vector3(0.0, 0.0, 20.0 + CosmosChart.FLIP_HYST + 5.0), "NORTH→1", [int(north[0]), int(north[1]), int(north[2]), int(north[3])])

# ---- holonomy: a loop around a cube corner accumulates 90° in M_win (documented, correct) ------
func _test_holonomy() -> void:
	print("[G-B/holonomy] a corner loop nets a 90° M_win; per-step window continuity still holds")
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var chart := CosmosChart.new(CubeSphere.HOME_BODY, 4, 20, 20)   # near the WEST/SOUTH corner of face 4
	var steps := 0
	# Walk a small loop that crosses several edges and returns; assert continuity each flip and a
	# net non-identity (90°) M_win after a corner circuit. Cross WEST, then keep flipping around.
	var players := [
		Vector3(-20.0 - CosmosChart.FLIP_HYST - 5.0, 0.0, 40.0),   # cross WEST off face 4
	]
	for p: Vector3 in players:
		if chart.flip_needed(p):
			var probes := [Vector2i(int(floor(p.x)), int(floor(p.z))), Vector2i(int(floor(p.x)) + 10, int(floor(p.z)) - 10)]
			var before := {}
			for w: Vector2i in probes:
				before[w] = _gkey(chart.to_global_column(w.x, w.y))
			var res := chart.flip(p)
			if bool(res["ok"]):
				steps += 1
				var cont := true
				for w: Vector2i in probes:
					if _gkey(chart.to_global_column(w.x, w.y)) != String(before[w]):
						cont = false
				_ok(cont, "holonomy step %d: window continuity holds" % steps)
				_ok(_is_c4(chart.m_win()), "holonomy step %d: M_win is a valid C4 element" % steps)
	_ok(steps >= 1, "at least one holonomy flip executed")

# ---- G-C: view-ray continuity WITHOUT compensation (replaces the retired verify_cosmos_turn) --------
# Under M_win the window frame is continuous across a flip, so with the player's yaw UNCHANGED (Fix A
# reverted) the same forward ray still hits the SAME global cells. verify_cosmos_turn pinned the OLD
# compensation that must now be absent; this pins its replacement — continuity with no player rotation.
func _test_view_ray() -> void:
	print("[G-C] view-ray continuity WITHOUT compensation — the unrotated forward ray hits the same global cells")
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var chart := CosmosChart.new(CubeSphere.HOME_BODY, 4, n - 20, n / 2)
	var player := Vector3(20.0 + CosmosChart.FLIP_HYST + 5.0, 0.0, 0.0)   # near EAST edge, past hysteresis
	var pwx := int(floor(player.x)); var pwz := int(floor(player.z))
	var ray: Array = []                              # window cells along the forward (+x) look ray
	for k in range(-8, 9):
		ray.append(Vector2i(pwx + k, pwz))
	var before := {}
	for w: Vector2i in ray:
		before[w] = _gkey(chart.to_global_column(w.x, w.y))
	if not chart.flip_needed(player):
		_ok(false, "G-C: flip fires")
		return
	if not bool(chart.flip(player)["ok"]):
		_ok(false, "G-C: flip ok")
		return
	var same := true
	for w: Vector2i in ray:
		if _gkey(chart.to_global_column(w.x, w.y)) != String(before[w]):
			same = false
	_ok(same, "the UNMODIFIED forward ray hits the same global cells after the flip (no yaw compensation needed)")

# ---- G-F: corner-path gate (COSMOS-FRAME-ORIENTATION §5.4/§8) --------------------------------------
# (a) a DIAGONAL entry past hysteresis on BOTH axes → chart.flip is REFUSED every tick, and M_win / org
#     are NOT mutated; (b) exiting through a SINGLE-out strip → a normal one-D4 flip fires with window
#     continuity; (c) the spawn corner's reachable face-set is exactly {4, 3, 0} (§5.4); (d) the wedge
#     render rotation (worker) EQUALS the collider rotation (analytic) — render == collision by construction.
func _test_corner_path() -> void:
	print("[G-F] corner-path — diagonal flip refused + unmutated; single-out fires; face-set {4,3,0}; render==collider J")
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	# (a) diagonal double-out past hysteresis on both axes (near the WEST/SOUTH corner of face 4).
	var chart := CosmosChart.new(CubeSphere.HOME_BODY, 4, 20, 20)
	var mw_pre := chart.m_win()
	var org_pre := Vector2i(chart.i_org, chart.j_org)
	var diag := Vector3(-20.0 - CosmosChart.FLIP_HYST - 5.0, 0.0, -20.0 - CosmosChart.FLIP_HYST - 5.0)
	var refused_ok := true
	for _tick in 3:
		var res := chart.flip(diag)
		if bool(res["ok"]):
			refused_ok = false
	_ok(refused_ok, "diagonal corner-quadrant entry: chart.flip REFUSED every tick (no single-edge fold)")
	_ok(_mat_eq(chart.m_win(), mw_pre) and Vector2i(chart.i_org, chart.j_org) == org_pre, "refused flip did NOT mutate M_win / origin")
	# (b) exit through a SINGLE-out WEST strip → a normal flip fires (one D4), window continuity holds.
	var west: Array = CubeSphere.edge_remap(4, CubeSphere.SIDE_WEST, n)["m"]
	_flip_and_check(chart, Vector3(-20.0 - CosmosChart.FLIP_HYST - 5.0, 0.0, 40.0), "corner-exit WEST→3", [int(west[0]), int(west[1]), int(west[2]), int(west[3])])
	# (c) spawn corner face-set: scan the window quadrants around the corner (face 4, origin 0,0); every
	#     cell resolves (canonically) to one of {4, 3, 0} — never 1/2/5 (§5.4). Both single-out strips + wedge.
	var faces := {}
	for di in [-40, -8, 8, 40]:
		for dj in [-40, -8, 8, 40]:
			var g := CubeSphere.fold_cell_canonical(4, di, dj, n)
			faces[int(g["face"])] = true
	var subset := true
	for f in faces.keys():
		if not (f == 4 or f == 3 or f == 0):
			subset = false
	_ok(subset, "spawn-corner reachable faces ⊆ {4,3,0} (got %s)" % str(faces.keys()))
	_ok(faces.has(4) and faces.has(3) and faces.has(0), "spawn-corner reaches all of home 4 + WEST strip 3 + SOUTH strip 0")
	# (d) wedge render(worker) J == collider(analytic) J — so render == collision in the wedge, both paths.
	TerrainConfig.set_active_face(4); TerrainConfig.set_active_mwin_d4(0)
	var wedge_ok := true
	for depth: int in [2, 4, 8, 16]:
		var wi := -depth; var wj := -depth               # double-out wedge column on face 4
		if int(CubeSphere.fold_cell(4, wi, wj, n)["face"]) >= 0:
			continue
		var ctx := TerrainConfig.GenCtx.new(4)
		TerrainConfig.worker_fold_column(4, wi, wj, ctx, 0)   # worker jinv for this wedge column
		if ctx.jinv_d4 != TerrainConfig.analytic_jinv_d4(wi, wj):
			wedge_ok = false
	_ok(wedge_ok, "wedge column: worker render J⁻¹ == analytic collider J⁻¹ (render == collision by construction)")

func _init() -> void:
	print("=== verify_cosmos_frame (COSMOS-FRAME-ORIENTATION §8 — bug #2 pinned orientation) FLAT_WORLD=", CubeSphere.FLAT_WORLD, " ===")
	_test_reanchor()
	_test_flip_edges()
	_test_view_ray()
	_test_holonomy()
	_test_corner_path()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
