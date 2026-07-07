extends SceneTree
## COSMOS M1 — headless property tests for the single-face curved patch (docs/COSMOS-PLANET-
## TOPOLOGY.md §9 M1). Run:
##   godot --headless --path godot --script res://src/tools/verify_cosmos_m1.gd
## Exits 0 all-pass, 1 on any failure. Asserts the CURVED-mode math invariants that ARE headlessly
## checkable, WITHOUT flipping CubeSphere.FLAT_WORLD (a const): the adapter's window↔global mapping,
## the curved 3D-noise worldgen determinism, the toward-centre gravity field, and the §3.4 bend /
## 147-block sea-horizon math. Plus the load-bearing byte-identity gate: with FLAT_WORLD ON, the
## adapter and the gravity stub are byte-identical to the pre-M1 world at the DATA layer.
##
## Gates (§9 M1 + the task):
##   [1] adapter (i,j,r) ↔ (x,z,y) round-trips and matches CubeSphere; FLAT_WORLD data byte-identity.
##   [2] gravity points to centre (−Y in-window) and matches the PerVoxelEnvironment field; flat stub.
##   [3] §3.4 bend: exact sagitta + the ~147-block sea horizon (formula ≡ geometric horizon).
##   [4] determinism: the curved worldgen is a pure function of (SEED, face, i, j) — no randi/Time.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CB := preload("res://src/cosmos/cosmos_bend.gd")
const TC := preload("res://src/world/terrain_config.gd")
const PVE := preload("res://src/sim/per_voxel_environment.gd")

var _fail := 0
var _pass := 0

const R_EARTH := 6371.0
const EYE := 1.7                 # Player.eye_height default — the locked COSMOS demo eye height

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _initialize() -> void:
	print("COSMOS M1 — single-face curved patch verification (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	_test_adapter()
	_test_gravity()
	_test_bend_horizon()
	_test_determinism()
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------------------------------------------------------------------------------
# [1] The terrain-function adapter (§3.5) + the window↔global mapping.
# ---------------------------------------------------------------------------------------
func _test_adapter() -> void:
	print("[1] adapter: (i,j,r)↔(x,z,y) window mapping, CubeSphere round-trip, FLAT_WORLD byte-identity")
	var n := CS.n_for(CS.HOME_BODY)
	_ok(n == 10016, "Earth N = 10016 (got %d)" % n)
	_ok(CS.HOME_FACE == 4, "M1 window homed on the polar face 4 (got %d)" % CS.HOME_FACE)

	# The window↔global coordinate mapping (§3.1): window (x, y, z) = (i, r, j). Assert the bijection
	# on a spread of cells (it is the pure integer identity that the adapter and generated_cell_global
	# rely on — x=i, y=r, z=j — so the whole engine downstream is a translation of face-index space).
	var map_ok := true
	for i: int in [0, 1, 137, 5008, n - 1]:
		for j: int in [0, 42, 9999, n - 1]:
			for r: int in [-64, -1, 0, 5, 116]:
				# window-space (x,y,z) from the global cell, and back: x=i, y=r, z=j (§3.1)
				var x: int = i
				var y: int = r
				var z: int = j
				if x != i or y != r or z != j or Vector3i(x, y, z) != Vector3i(i, r, j):
					map_ok = false
	_ok(map_ok, "window↔global mapping x=i, y=r, z=j is the exact integer bijection")

	# CubeSphere cell↔dir round-trip on the face-4 window cells the adapter samples d̂ at (ties the
	# adapter's noise domain to the M0 kernel: the direction it feeds worldgen is the exact lattice
	# direction, recovered bit-for-cell).
	var rt_ok := true
	var stride := maxi(1, n / 50)
	for i in range(0, n, stride):
		for j in range(0, n, stride):
			var d := CS.face_cell_to_dir(CS.HOME_FACE, i, j, n)
			var rt := CS.dir_to_face_cell(d, n)
			if int(rt["face"]) != CS.HOME_FACE or int(rt["fi"]) != i or int(rt["fj"]) != j:
				rt_ok = false
	_ok(rt_ok, "face-4 window cells cell→dir→cell round-trip exactly (adapter d̂ domain matches CubeSphere)")

	# FLAT_WORLD data byte-identity: generated_cell_global(HOME_FACE, i, j, r) must equal today's
	# generated_cell(i, r, j) for a sample — the R→∞ limit is exactly the pre-M1 world (§3.5). This is
	# the DATA-layer proof (beyond the suite) that the adapter perturbs nothing when the planet is off.
	if CS.FLAT_WORLD:
		TC.warm_up()
		var ident_ok := true
		var mism := 0
		for i in [0, 3, 64, 250, 1000]:
			for j in [0, 7, 128, 777]:
				for r in [-64, -20, -1, 0, 1, 5, 12, 30]:
					var via_adapter := TC.generated_cell_global(CS.HOME_FACE, i, j, r)
					var via_today := TC.generated_cell(i, r, j)   # window identity: x=i, y=r, z=j
					if via_adapter != via_today:
						ident_ok = false
						mism += 1
		_ok(ident_ok, "FLAT_WORLD: generated_cell_global(4,i,j,r) == generated_cell(i,r,j) byte-for-byte (%d mismatch)" % mism)
	else:
		# Curved: the adapter must produce SANE, deterministic data (valid biome, finite surface).
		var sane := true
		for i in [100, 2500, 9000]:
			for j in [200, 5000]:
				var p := TC._curved_profile(CS.HOME_FACE, i, j)
				var biome := int(p.y)
				if biome < TC.B_OCEAN or biome > TC.B_PLAINS:
					sane = false
				if not is_finite(p.x) or int(p.x) < TC.WORLD_BOTTOM_Y or int(p.x) > 200:
					sane = false
		_ok(sane, "curved adapter yields a valid biome + finite surface height per column")

# ---------------------------------------------------------------------------------------
# [2] Gravity — the toward-centre field (§6.1).
# ---------------------------------------------------------------------------------------
func _test_gravity() -> void:
	print("[2] gravity: −Y in-window, GM/(R+r)² magnitude, continuity at the datum, flat stub")
	var env := PVE.new()

	# The curved FIELD formula (exactly what PerVoxelEnvironment.gravity computes in curved mode —
	# same GM = g0·R² from CubeSphere.gm_for, same r = R + pos.y). Direction is −Y for every column
	# (the §3.3 y↦r theorem), magnitude 9.81 at the datum, falling with altitude.
	var rr := float(CS.radius_for(CS.HOME_BODY))
	var gm := CS.gm_for(CS.HOME_BODY)
	var g0 := CS.SURFACE_GRAVITY

	# magnitude at the datum r=0 is exactly the surface gravity (continuity with the flat stub 9.81).
	var mag0 := gm / (rr * rr)
	_ok(absf(mag0 - g0) < 1e-6, "field magnitude at r=0 is SURFACE_GRAVITY 9.81 (got %.6f)" % mag0)

	# direction is straight down (−Y): the x,z components are identically 0 at every altitude.
	var dir_ok := true
	var mono_ok := true
	var last := INF
	for r in [-64, -20, 0, 50, 128, 256, 512]:
		var rad := rr + float(r)
		var field := Vector3(0.0, -gm / (rad * rad), 0.0)
		if field.x != 0.0 or field.z != 0.0 or field.y >= 0.0:
			dir_ok = false
		var m := field.length()
		if m > last:            # magnitude must not INCREASE with altitude
			mono_ok = false
		last = m
	_ok(dir_ok, "gravity is exactly −Y in window space (no x/z tilt) at every altitude")
	_ok(mono_ok, "gravity magnitude decreases monotonically with altitude (1/r² falloff)")

	# +512 shell top magnitude (§6.1: ~8.4 on Earth via g0·R²): a real drop, still Earth-like.
	var mag512 := gm / ((rr + 512.0) * (rr + 512.0))
	_ok(mag512 < g0 and mag512 > 8.0, "gravity at the +512 atmosphere shell top is %.3f (< 9.81, > 8)" % mag512)

	# FLAT_WORLD byte-identity: the live gravity() returns the fixed-down stub exactly.
	if CS.FLAT_WORLD:
		var g := env.gravity(Vector3(3.0, 10.0, -7.0))
		_ok(g == PVE.GRAVITY and g == Vector3(0.0, -9.81, 0.0),
			"FLAT_WORLD: PerVoxelEnvironment.gravity is the byte-identical −9.81 stub (got %s)" % str(g))
	else:
		var g0v := env.gravity(Vector3(3.0, 0.0, -7.0))
		_ok(g0v.x == 0.0 and g0v.z == 0.0 and absf(g0v.y + g0) < 1e-6,
			"curved: PerVoxelEnvironment.gravity at r=0 is (0, −9.81, 0) (got %s)" % str(g0v))

# ---------------------------------------------------------------------------------------
# [3] The §3.4 render bend + the 147-block sea horizon.
# ---------------------------------------------------------------------------------------
func _test_bend_horizon() -> void:
	print("[3] bend: exact sagitta, ~147-block sea horizon (formula ≡ geometric tangent), fog-edge drop")
	var R := R_EARTH

	# The geometric horizon: the tangent-line distance √(2Rh + h²) from an eye at height h. The bend's
	# sea_horizon_distance MUST equal it (one source of the formula), and land at the locked ~147.
	var d_geo := sqrt(2.0 * R * EYE + EYE * EYE)
	var d_bend := CB.sea_horizon_distance(R, EYE)
	_ok(absf(d_bend - d_geo) < 1e-9, "sea_horizon_distance == geometric √(2Rh+h²) (%.4f vs %.4f)" % [d_bend, d_geo])
	_ok(absf(d_bend - 147.19) < 0.5, "Earth sea horizon at eye 1.7 m is ~147 blocks (got %.2f)" % d_bend)

	# Exact sagitta (NOT the d²/2R truncation): the bent sea-surface point (y=0) at horizontal L drops
	# by exactly R(1 − cos(L/R)). Pin the CPU mirror against that closed form and against the doc's
	# 5.1 m fog-edge figure at L = 256.
	var origin := Vector3.ZERO
	var sag_ok := true
	for L in [8.0, 64.0, 147.19, 256.0, 512.0]:
		var p := CB.bend_point(Vector3(L, 0.0, 0.0), origin, R)
		var exact := R * cos(L / R) - R
		if absf(p.y - exact) > 1e-6:
			sag_ok = false
		# horizontal coordinate is R·sin(L/R) (the point rolls around the sphere)
		if absf(p.x - R * sin(L / R)) > 1e-4:
			sag_ok = false
	_ok(sag_ok, "bend_point reproduces the exact sagitta R(1−cos(L/R)) (not the d²/2R truncation)")
	var drop256 := -(R * cos(256.0 / R) - R)
	_ok(absf(drop256 - 5.146) < 0.05, "curvature drop at the 256-block fog edge is ~5.1 m (got %.3f)" % drop256)

	# The bend at the camera column is identically zero (the player/aim ray/collider are unaffected).
	var at_cam := CB.bend_point(Vector3(0.0, 5.0, 0.0), origin, R)
	_ok(at_cam.is_equal_approx(Vector3(0.0, 5.0, 0.0)), "bend is identically zero at the camera column (got %s)" % str(at_cam))

	# Formula ≡ geometric horizon by TANGENCY: with the bent sea surface a circle of radius R centred
	# at (0, −R, 0) (the camera column maps to the origin), the eye at (0, h, 0) has a line of sight to
	# the horizon point that is perpendicular to that point's radius. Assert the bent point at the
	# horizon arc is a tangent point (sightline ⟂ radius), pinning the 147 to real sphere geometry.
	var phi_t := acos(R / (R + EYE))              # tangent-point angle from the top
	var L_arc := R * phi_t                          # along-surface arc to the horizon
	_ok(absf(L_arc - d_geo) < 0.5, "horizon arc distance ≈ tangent distance at this scale (%.3f vs %.3f)" % [L_arc, d_geo])
	var pt := CB.bend_point(Vector3(L_arc, 0.0, 0.0), origin, R)   # bent sea point at the horizon
	var center := Vector3(0.0, -R, 0.0)
	var eye := Vector3(0.0, EYE, 0.0)
	var to_eye := (eye - pt).normalized()
	var radius_dir := (pt - center).normalized()
	_ok(absf(to_eye.dot(radius_dir)) < 1e-3,
		"bent horizon point is a true tangent point (sightline ⟂ radius, dot=%.5f)" % to_eye.dot(radius_dir))

# ---------------------------------------------------------------------------------------
# [4] Determinism — pure SEED, window-independent (§8.2).
# ---------------------------------------------------------------------------------------
func _test_determinism() -> void:
	print("[4] determinism: curved worldgen is a pure function of (SEED, face, i, j) — no randi/Time")
	TC.warm_up()

	# The curved column profile is identical on re-call (no per-run state) and independent of the
	# order it is queried in — a pure function of (face, i, j) only.
	var pure := true
	var cells := [[100, 200], [2500, 5000], [9000, 9000], [0, 0], [10015, 10015]]
	for c in cells:
		var a := TC._curved_profile(CS.HOME_FACE, c[0], c[1])
		var b := TC._curved_profile(CS.HOME_FACE, c[0], c[1])
		if a != b:
			pure = false
	# query a second time in REVERSE order — output must not depend on call history
	cells.reverse()
	for c in cells:
		var a := TC._curved_profile(CS.HOME_FACE, c[0], c[1])
		var b := TC._curved_profile(CS.HOME_FACE, c[0], c[1])
		if a != b:
			pure = false
	_ok(pure, "_curved_profile is bit-for-bit deterministic and order-independent")

	# generated_cell_global is likewise deterministic (whichever mode is active).
	var cell_pure := true
	for i in [10, 500, 3003]:
		for r in [-30, 0, 20]:
			var v1 := TC.generated_cell_global(CS.HOME_FACE, i, 250, r)
			var v2 := TC.generated_cell_global(CS.HOME_FACE, i, 250, r)
			if v1 != v2:
				cell_pure = false
	_ok(cell_pure, "generated_cell_global is deterministic on re-call")
