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
	if CubeSphere.M5C_CORNER:
		_c4_pillar()
	else:
		_c9_byte_identity()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

const TC := preload("res://src/world/terrain_config.gd")
const CS2 := preload("res://src/cosmos/cube_sphere.gd")

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
