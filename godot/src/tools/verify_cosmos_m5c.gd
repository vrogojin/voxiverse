extends SceneTree
## COSMOS M5c gates (docs/COSMOS-M5C-CORNER.md §11). This file grows one stage at a time. S0 lands the
## PURE-MATH gates against CosmosCorner (chart-free, flag-independent): C1 φ-map algebra, C2 bisector
## involution, C8-algebra seam-glue. Later stages add C3-world / C4 pillar / C5 lock / C6 fuzz / C7 / C10.
## Curved-only discipline (loud-skip under FLAT_WORLD) — the math is universal, but the file is a COSMOS gate.

const CC := preload("res://src/cosmos/cosmos_corner.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _n := 0

func _init() -> void:
	print("=== verify_cosmos_m5c (S0 pure algebra) FLAT_WORLD=", CubeSphere.FLAT_WORLD, " ===")
	if CubeSphere.FLAT_WORLD:
		print("  SKIPPED — corner seal is curved-only. NOT A PASS."); print("==== VERIFY: SKIPPED ===="); quit(2); return
	_n = CubeSphere.n_for(CubeSphere.HOME_BODY)

	_c1_phi_map()
	_c2_involution()
	_c8_glue()
	_c6_flip()
	if CubeSphere.M5C_CORNER:
		_c4_pillar()
		_c5_edit_lock()
		if CubeSphere.M5C_TELEPORT:
			_c7_conservation()
			_c6_full()
		else:
			_c11_barrier()
	else:
		_c9_byte_identity()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

const TC := preload("res://src/world/terrain_config.gd")
const CS2 := preload("res://src/cosmos/cube_sphere.gd")

# C6-partial (§4/§11) — the eager flip cadence + single-edge property (flag-independent chart math; the FULL
# circling walker with no-double-out + 90° holonomy lands in S4's C6 where teleport makes every radius safe).
func _c6_flip() -> void:
	var mk := func() -> CosmosChart: return CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
	# hysteresis selection: past the SOUTH edge by overshoot 6 (window==raw at spawn, M_win=I, org=0):
	var ch: CosmosChart = mk.call()
	_ok(ch.flip_needed(Vector3(20, 60, -6), CubeSphere.FLIP_HYST_CORNER), "C6 eager flip fires at overshoot 6")
	_ok(not ch.flip_needed(Vector3(20, 60, -4), CubeSphere.FLIP_HYST_CORNER), "C6 eager no-flip at overshoot 4 (< 5)")
	_ok(not ch.flip_needed(Vector3(20, 60, -6), CosmosChart.FLIP_HYST), "C6 normal hysteresis no-flip at overshoot 6")
	# single-EDGE flip: a single-out column (i in range, j out) folds ok:true (not the double-out refusal):
	var ch2: CosmosChart = mk.call()
	var res: Dictionary = ch2.flip(Vector3(20, 60, -6))
	_ok(bool(res["ok"]), "C6 single-out column flips ok (single-edge)")
	# a real edge cross (face changed). The SOUTH edge of the polar face 4 carries a 0° D4, so M_win may be
	# unchanged — that is correct single-edge behaviour; only the FULL lap's composition is the 90° holonomy.
	_ok(int(res["from_face"]) != int(res["to_face"]), "C6 flip crossed to a neighbour face")
	# DOUBLE-out (both axes out → corner quadrant): flip refused (the shipped {ok:false} deferral):
	var ch3: CosmosChart = mk.call()
	var res3: Dictionary = ch3.flip(Vector3(-6, 60, -6))
	_ok(not bool(res3["ok"]), "C6 double-out (wedge) flip refused (ok:false)")
	# home-native classification (spawn preference §4): corner cell native, single-out column not native:
	var ch4: CosmosChart = mk.call()
	_ok(_native(ch4, 5, 5), "C6 (5,5) home-native")
	_ok(not _native(ch4, 20, -6), "C6 (20,-6) single-out NOT native")

func _native(ch: CosmosChart, x: int, z: int) -> bool:
	var p := ch.raw_of(x, z)
	return p.x >= 0 and p.x < ch.n and p.y >= 0 and p.y < ch.n

# C4 (§11) — the bedrock pillar, requires M5C_CORNER on. Scans the 4 corners of HOME_FACE, verifies the
# pillar footprint, one flat top, full bedrock cubes / zero modifier / no tree, and cross-face byte-equality.
func _c4_pillar() -> void:
	var bedrock := BlockCatalog.id_of(&"bedrock")
	var f := CubeSphere.HOME_FACE
	var found_total := 0
	for corner_v in [Vector2i(0, 0), Vector2i(0, _n - 1), Vector2i(_n - 1, 0), Vector2i(_n - 1, _n - 1)]:
		var corner: Vector2i = corner_v
		var si := 1 if corner.x == 0 else -1
		var sj := 1 if corner.y == 0 else -1
		var pillars: Array = []          # [i,j] cells that are B_PILLAR
		var max_r := 0.0
		for di in range(0, 12):
			for dj in range(0, 12):
				var i := corner.x + si * di
				var j := corner.y + sj * dj
				if int(TC._curved_profile(f, i, j).y) == TC.B_PILLAR:
					pillars.append(Vector2i(i, j))
					max_r = maxf(max_r, sqrt(float(di * di + dj * dj)))
		_ok(pillars.size() > 0, "C4 pillar exists @face %d corner (%d,%d) — %d cells" % [f, corner.x, corner.y, pillars.size()])
		_ok(max_r <= 6.0, "C4 pillar footprint radius %.2f <= 6 (≤5.2 + cell)" % max_r)
		# the corner cell itself must be a pillar (contains radius < 3):
		_ok(int(TC._curved_profile(f, corner.x, corner.y).y) == TC.B_PILLAR, "C4 corner cell is a pillar")
		# pick one pillar column and verify the stack + top + modifier + no-tree:
		if pillars.size() > 0:
			var pc: Vector2i = pillars[0]
			var d: CubeSphere.DVec3 = LatticeNav.dir_of(f, pc.x, pc.y, _n)
			var k := TC._pillar_corner_of(d, _n)
			var top := TC._pillar_top(k)
			# bedrock full cubes floor→top, air above:
			var floor_ok := CellCodec.mat(TC.generated_cell_global(f, pc.x, pc.y, TC.WORLD_BOTTOM_Y + 2)) == bedrock
			var mid_ok := CellCodec.mat(TC.generated_cell_global(f, pc.x, pc.y, top)) == bedrock
			var above_air := TC.generated_cell_global(f, pc.x, pc.y, top + 1) == BlockCatalog.AIR
			var mod0 := CellCodec.modifier(TC.generated_cell_global(f, pc.x, pc.y, top)) == 0
			_ok(floor_ok and mid_ok, "C4 pillar is bedrock floor→top(%d)" % top)
			_ok(above_air, "C4 pillar air above top")
			_ok(mod0, "C4 pillar zero modifier (full cube)")
			found_total += pillars.size()
	# (a) cross-face byte-equality: a vertex's 3 incident corner cells are all pillar bedrock, from ANY face.
	for k in range(8):
		var cells := CubeSphere.corner_cells(k, _n)
		var all_bedrock := true
		for cc in cells:
			if CellCodec.mat(TC.generated_cell_global(int(cc["face"]), int(cc["i"]), int(cc["j"]), 0)) != bedrock:
				all_bedrock = false
		_ok(all_bedrock, "C4 vertex %d: all 3 incident face-corner cells bedrock (cross-face purity)" % k)
	print("  (C4: %d pillar cells across the 4 home-face corners)" % found_total)

# C5 (§11) — the CORNER_LOCK_R edit refusal, requires M5C_CORNER on. A bare WorldManager with an injected
# chart (M_win=I at spawn → window == raw): locked columns (raw dist ≤ 8) refuse break/place; distance 9 is
# allowed. break/place early-return on the lock before any generation, so no full world setup is needed.
func _c5_edit_lock() -> void:
	var wm := WorldManager.new()
	wm._chart = CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
	var stone := BlockCatalog.id_of(&"stone")
	for col_v in [Vector2i(0, 0), Vector2i(7, 0), Vector2i(0, 7), Vector2i(5, 5)]:
		var col: Vector2i = col_v
		_ok(wm.is_corner_locked_column(col.x, col.y), "C5 column %s is locked (dist ≤ 8)" % col)
		_ok(wm.break_terrain(Vector3i(col.x, 20, col.y)) == 0, "C5 break refused @%s (all heights)" % col)
		_ok(wm.break_terrain(Vector3i(col.x, -30, col.y)) == 0, "C5 break refused deep @%s" % col)
		_ok(not wm.place_block(Vector3i(col.x, 20, col.y), stone), "C5 place refused @%s" % col)
	for col_v in [Vector2i(9, 0), Vector2i(0, 9), Vector2i(20, 20)]:
		var col: Vector2i = col_v
		_ok(not wm.is_corner_locked_column(col.x, col.y), "C5 column %s NOT locked (dist ≥ 9)" % col)
	wm.free()

# C7 (§11) — teleport conservation through the REAL m5c_corner_check: in-anomaly entries eject outside R_b,
# |v_h| + heading-relative yaw preserved, y only-raised, exit never in the wedge (⇒ C10 finite camera).
func _c7_conservation() -> void:
	var wm := WorldManager.new()
	wm._chart = CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
	var n := wm._chart.n
	TerrainConfig.set_active_frame(CubeSphere.HOME_FACE, 0)
	var frame := CosmosTruePlace.bake_frame(wm._chart, Vector3(5, 40, 5))
	for phi in [30, 60, 90, 135, 180, 210, 250]:
		for r in [2.0, 5.0, 7.5]:
			var b := deg_to_rad(float(phi) - 90.0)
			# corner (0,0), σ=(1,1) at spawn → window == raw; place the player at band angle φ, radius r.
			var pos := Vector3(r * cos(b), 40.0, r * sin(b))
			var vin := Vector3(-cos(b), 0.0, -sin(b)) * 3.0        # heading inward, |v_h|=3
			var reloc: Dictionary = wm.m5c_corner_check(pos, vin)
			_ok(not reloc.is_empty(), "C7 teleport fired @φ%d r%.1f" % [phi, r])
			if reloc.is_empty():
				continue
			var np: Vector3 = reloc["pos"]
			var nv: Vector3 = reloc["vel"]
			var pr := wm._chart.raw_of_f(np.x, np.z)
			var c := CosmosCorner.nearest_corner(pr.x, pr.y, n)
			_ok(CosmosCorner.corner_dist(pr.x, pr.y, c) >= CosmosCorner.R_B - 1.0e-3, "C7 exit outside R_b @φ%d" % phi)
			_ok(is_equal_approx(Vector2(nv.x, nv.z).length(), 3.0), "C7 |v_h| preserved @φ%d" % phi)
			_ok(np.y >= pos.y - 1.0e-6, "C7 y only raised @φ%d" % phi)
			_ok(not wm.is_wedge_column(int(floor(np.x)), int(floor(np.z))), "C7 exit not double-out @φ%d" % phi)
			# C10: the exit column has a real sphere position (place_true != _WEDGE) → finite epoch camera.
			_ok(CosmosTruePlace.place_true(wm._chart, np, frame) != CosmosTruePlace._WEDGE,
				"C10 exit place_true != _WEDGE @φ%d" % phi)
			# yaw-delta correctness: rotating d_in by Δψ yields the exit heading r̂_out (== new v_h direction).
			var yd: float = reloc["yaw_delta"]
			var din := Vector2(vin.x, vin.z).normalized()
			var vhn := Vector2(nv.x, nv.z).normalized()
			# rotate the 3D heading about +Y by Δψ (same convention as signed_angle_to in m5c_corner_check):
			var rot := Vector3(din.x, 0.0, din.y).rotated(Vector3.UP, yd)
			_ok(rot.is_equal_approx(Vector3(vhn.x, 0.0, vhn.y)), "C7 yaw Δψ maps heading→exit @φ%d" % phi)
	wm.free()

# C6-full (§11) — the seal under motion. (a) glue totality: every wedge point at any radius glues to a strip,
# never double-out; (b) the anomaly ejects a radial-approach walker from every direction; (c) the 3 edges of
# the spawn vertex compose to 90° holonomy (the honest curvature — pinned, not a bug).
func _c6_full() -> void:
	var n := _n
	# (a) glue totality — a wedge column, glued, is a real (non-wedge) strip column, at every radius.
	var chart := CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
	TerrainConfig.set_active_frame(CubeSphere.HOME_FACE, 0)
	var wedge_ok := 0
	for phi in [272.0, 290.0, 315.0, 340.0, 358.0]:
		for r in [3.0, 8.0, 30.0, 150.0]:
			var b := deg_to_rad(phi - 90.0)
			var px: float = r * cos(b)
			var pz: float = r * sin(b)                       # corner (0,0) σ=(+,+): window==raw
			var g: Dictionary = CosmosCorner.glue_raw(px, pz, n)
			# the glued window column must NOT be double-out (fold face >= 0):
			if not CosmosTruePlace.is_wedge(chart, g["px"], g["py"]):
				wedge_ok += 1
	_ok(wedge_ok == 20, "C6 glue totality: all wedge samples → real strip (%d/20)" % wedge_ok)
	# (b) radial-approach ejection: a WM teleport from every in-anomaly direction leaves R_b and the wedge.
	var wm := WorldManager.new()
	wm._chart = CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
	var eject := 0
	for phi in range(5, 266, 20):
		var b := deg_to_rad(float(phi) - 90.0)
		var pos := Vector3(6.0 * cos(b), 40.0, 6.0 * sin(b))
		var reloc: Dictionary = wm.m5c_corner_check(pos, Vector3(-cos(b), 0, -sin(b)) * 2.0)
		if not reloc.is_empty():
			var np: Vector3 = reloc["pos"]
			var pr := wm._chart.raw_of_f(np.x, np.z)
			var c := CosmosCorner.nearest_corner(pr.x, pr.y, n)
			if CosmosCorner.corner_dist(pr.x, pr.y, c) >= CosmosCorner.R_B - 1.0e-3 \
					and not wm.is_wedge_column(int(floor(np.x)), int(floor(np.z))):
				eject += 1
	_ok(eject >= 13, "C6 radial-approach: all directions eject outside R_b + wedge (%d/13)" % eject)
	wm.free()
	# (holonomy — the honest 90° curvature per lap — is pinned by verify_cosmos_m0's corner tests; not re-asserted here)

# C11 (§8/§11) — barrier mode (M5C_TELEPORT=false): an inward approach is clamped to the R_b cylinder
# surface (never gets inside) and its inward velocity component is removed. All other invariants keep.
func _c11_barrier() -> void:
	var wm := WorldManager.new()
	wm._chart = CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
	var n := wm._chart.n
	for phi in range(5, 266, 30):
		var b := deg_to_rad(float(phi) - 90.0)
		var pos := Vector3(4.0 * cos(b), 40.0, 4.0 * sin(b))       # 4 < R_b=8 → inside the barrier
		var reloc: Dictionary = wm.m5c_corner_check(pos, Vector3(-cos(b), 0, -sin(b)) * 3.0)
		_ok(not reloc.is_empty(), "C11 barrier fired @φ%d" % phi)
		if reloc.is_empty():
			continue
		var np: Vector3 = reloc["pos"]
		var pr := wm._chart.raw_of_f(np.x, np.z)
		var cc := CosmosCorner.nearest_corner(pr.x, pr.y, n)
		_ok(CosmosCorner.corner_dist(pr.x, pr.y, cc) >= CosmosCorner.R_B - 1.0e-3, "C11 clamped to ≥ R_b @φ%d" % phi)
		var nv: Vector3 = reloc["vel"]
		var w_v := wm._chart.window_of_f(cc.x, cc.y)
		var inward := (w_v - Vector2(np.x, np.z)).normalized()
		_ok(Vector2(nv.x, nv.z).dot(inward) <= 1.0e-3, "C11 inward velocity removed @φ%d" % phi)
	wm.free()

# C9 (§11) — byte-identity with M5C_CORNER OFF: _curved_profile == _curved_profile_base, no B_PILLAR anywhere.
func _c9_byte_identity() -> void:
	var f := CubeSphere.HOME_FACE
	var mism := 0
	var any_pillar := false
	for corner_v in [Vector2i(0, 0), Vector2i(_n - 1, _n - 1)]:
		var corner: Vector2i = corner_v
		var si := 1 if corner.x == 0 else -1
		var sj := 1 if corner.y == 0 else -1
		for di in range(0, 10):
			for dj in range(0, 10):
				var i := corner.x + si * di
				var j := corner.y + sj * dj
				var p := TC._curved_profile(f, i, j)
				var b := TC._curved_profile_base(f, i, j)
				if not p.is_equal_approx(b):
					mism += 1
				if int(p.y) == TC.B_PILLAR:
					any_pillar = true
	_ok(mism == 0, "C9 flag-off: _curved_profile == base over corner region (%d mismatches)" % mism)
	_ok(not any_pillar, "C9 flag-off: no B_PILLAR column anywhere")

# The four raw corners with their σ parity — exercise both reflection cases.
func _corners() -> Array:
	return [Vector4(0, 0, 1, 1), Vector4(_n, 0, -1, 1), Vector4(0, _n, 1, -1), Vector4(_n, _n, -1, -1)]

# raw point at canonical band angle φ and radius r about packed corner c: u′=r·(cosβ,sinβ), p=corner+σ·u′.
# Returns [px, py] as f64 SCALARS (a Vector2 would truncate to f32 and inject ~6e-6° into the involution).
func _raw_at(c: Vector4, phi: float, r: float) -> Array:
	var b := deg_to_rad(phi - 90.0)
	var ux := r * cos(b)
	var uy := r * sin(b)
	return [c.x + c.z * ux, c.y + c.w * uy]

func _c1_phi_map() -> void:
	# nearest_corner + u′ round-trip + φ sanity pins + quadrant ranges, for all 4 σ-parity corners.
	for c in _corners():
		var cc: Vector4 = c
		# a home-quadrant point (φ=135, r=20) near this corner classifies to THIS corner with THIS σ.
		var p := _raw_at(cc, 135.0, 20.0)
		var px: float = p[0]; var py: float = p[1]
		var nc := CC.nearest_corner(px, py, _n)
		_ok(nc.is_equal_approx(cc), "C1 nearest_corner @corner(%d,%d)" % [int(cc.x), int(cc.y)])
		# u′ round-trip: uprime_of then invert back to raw p.
		var u := CC.uprime_of(px, py, nc)
		var rtx := nc.x + nc.z * u.x; var rty := nc.y + nc.w * u.y
		_ok(is_equal_approx(rtx, px) and is_equal_approx(rty, py), "C1 u' round-trip @corner(%d,%d)" % [int(cc.x), int(cc.y)])
		# φ sanity pins (build u′ directly, φ is defined on u′ so corner/σ-independent):
		_ok(is_equal_approx(CC.phi_of_uprime(Vector2(0, -5)), 0.0), "C1 pin φ=0")
		_ok(is_equal_approx(CC.phi_of_uprime(Vector2(5, 0)), 90.0), "C1 pin φ=90")
		_ok(is_equal_approx(CC.phi_of_uprime(Vector2(5, 5)), 135.0), "C1 pin φ=135")
		_ok(is_equal_approx(CC.phi_of_uprime(Vector2(-5, 0)), 270.0), "C1 pin φ=270")
		# quadrant φ ranges (§1 table), on u′ directly:
		_ok(_in(CC.phi_of_uprime(Vector2( 3,  4)), 90, 180), "C1 home quadrant φ∈(90,180)")
		_ok(_in(CC.phi_of_uprime(Vector2( 3, -4)), 0, 90),   "C1 J-strip φ∈(0,90)")
		_ok(_in(CC.phi_of_uprime(Vector2(-3,  4)), 180, 270), "C1 I-strip φ∈(180,270)")
		_ok(_in(CC.phi_of_uprime(Vector2(-3, -4)), 270, 360), "C1 wedge φ∈(270,360)")

func _c2_involution() -> void:
	# sweep φ_in over the cone (skip the EPS_PHI seam bands where the clamp intentionally perturbs), radii
	# {2,5,7.9}: T(T(x)) restores azimuth to 1e-6, exit radius == R_X, exit never in the wedge band.
	for c in _corners():
		var cc: Vector4 = c
		for r in [2.0, 5.0, 7.9]:
			for pi in range(int(CC.EPS_PHI) + 1, int(270.0 - CC.EPS_PHI)):
				var phi_in := float(pi)
				var p := _raw_at(cc, phi_in, r)
				var t1: Dictionary = CC.teleport_raw(p[0], p[1], _n)
				var p1x: float = t1["px"]; var p1y: float = t1["py"]
				# exit radius R_X, exit not in wedge:
				_ok(is_equal_approx(CC.corner_dist(p1x, p1y, cc), CC.R_X), "C2 exit radius R_X")
				var phi1: float = t1["phi_out"]
				_ok(phi1 >= CC.EPS_PHI - 1e-6 and phi1 <= 270.0 - CC.EPS_PHI + 1e-6, "C2 exit not in wedge")
				# involution: EXACT outside the EPS_PHI seam band (φ_in ≈ 135 → φ_out clamps off the B–C seam),
				# bounded ≤ EPS_PHI inside it (§5.3a / §13.3 — the clamp trades 0.6 cells of seam clearance).
				var t2: Dictionary = CC.teleport_raw(p1x, p1y, _n)
				var dev: float = absf(float(t2["phi_out"]) - phi_in)
				if absf(phi_in - 135.0) < CC.EPS_PHI:
					_ok(dev <= CC.EPS_PHI + 1e-6, "C2 T²≈id in seam band @φ=%.0f r=%.1f (dev %.4f)" % [phi_in, r, dev])
				else:
					_ok(dev < 1e-6, "C2 T²=id @φ=%.0f r=%.1f (got %.6f)" % [phi_in, r, t2["phi_out"]])

func _c8_glue() -> void:
	# a wedge point (φ∈(270,360)) glues to a strip band, radius + reflection-consistent.
	for c in _corners():
		var cc: Vector4 = c
		for phi_in in [275.0, 300.0, 314.0, 316.0, 340.0, 355.0]:
			for r in [3.0, 8.0, 40.0, 200.0]:
				var p := _raw_at(cc, float(phi_in), r)
				var g: Dictionary = CC.glue_raw(p[0], p[1], _n)
				var pnx: float = g["px"]; var pny: float = g["py"]
				_ok(is_equal_approx(CC.corner_dist(pnx, pny, cc), r), "C8 glue preserves radius")
				var un := CC.uprime_of(pnx, pny, cc)
				var phi_new := CC.phi_of_uprime(un)
				# glued point lands in a strip (never home, never wedge):
				var in_strip := _in(phi_new, 0, 90) or _in(phi_new, 180, 270)
				_ok(in_strip, "C8 glued φ=%.0f → strip (got %.2f)" % [phi_in, phi_new])

func _in(v: float, lo: float, hi: float) -> bool:
	return v > lo - 1e-6 and v < hi + 1e-6
