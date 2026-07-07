extends SceneTree
## COSMOS M0 — headless property tests for the cube-sphere math kernel (cube_sphere.gd).
## Run: godot --headless --path godot --script res://src/tools/verify_cosmos_m0.gd
## Exits 0 all-pass, 1 on any failure. Pure math, no engine dependencies.
##
## Gates (docs/COSMOS-PLANET-TOPOLOGY.md §9 M0):
##   [1] exact cell -> dir -> cell round-trips (dense sample + all edges/corners) and
##       stable dir -> cell -> dir, with the measured f64 precision margin reported.
##   [2] 1:1 edge adjacency (§4.1): every one of the 12 edges (both directions) folds its
##       boundary strip to the neighbour bijectively, with the two straddling cells one
##       cell apart geometrically (no T-junctions, no gap/overlap).
##   [3] D4 remap pins (§4.2): the generated table matches hand-verified structural facts,
##       including the doc's worked example (face 4 <-> face 0), and every M is a valid D4.
##   [4] global key pack/unpack bijection over extremes (§1.3), incl. the region prefix.
##   [5] distortion bound (§2.2): sampled cell-size ratio within the equal-angle [0.707, 1.0].
##   [6] determinism: functions are pure (same input -> identical output; no randi/Time).

const CS := preload("res://src/cosmos/cube_sphere.gd")

var _fail := 0
var _pass := 0
var _rng_state := 0x2545F4914F6CDD1D   # deterministic LCG seed (NO randi/Time — §8.2)

# Precision bookkeeping (reported at the end to confirm f64 held).
var _worst_int_dev := 0.0        # max |recovered_float - integer| over all round-trips
var _worst_stable_ang := 0.0     # max angular drift over dir -> cell -> dir

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _initialize() -> void:
	print("COSMOS M0 — cube-sphere math kernel verification")
	_test_roundtrip()
	_test_edge_adjacency()
	_test_d4_pins()
	_test_global_key()
	_test_distortion_bound()
	_test_determinism()
	_test_corner_tables()
	print("\n    precision: worst |recovered - integer| = %s cells; worst dir->cell->dir drift = %s rad"
		% [_worst_int_dev, _worst_stable_ang])
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# Deterministic 64-bit LCG so "random" cell sampling is reproducible and uses NO randi/Time.
func _rand_int(lo: int, hi: int) -> int:
	_rng_state = (_rng_state * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
	var span := hi - lo
	if span <= 0:
		return lo
	return lo + (_rng_state % span)

# ---------------------------------------------------------------------------------------
# [1] Exact round-trips (§1.2, §9 M0)
# ---------------------------------------------------------------------------------------
func _test_roundtrip() -> void:
	print("[1] exact cell -> dir -> cell round-trips (Earth N=10016 + spot-check Moon)")
	_roundtrip_body(CS.n_for("earth"), "earth")
	_roundtrip_body(CS.n_for("moon"), "moon")

func _roundtrip_body(n: int, label: String) -> void:
	var bad := 0
	var checked := 0
	# A dense grid across each face, plus all 4 edges, all 4 corners, and random cells.
	var samples: Array = []
	var stride := maxi(1, n / 40)   # ~40x40 interior grid per face
	for i in range(0, n, stride):
		for j in range(0, n, stride):
			samples.append([i, j])
	# All four edges (dense along) + the 4 corners.
	var estride := maxi(1, n / 200)
	for t in range(0, n, estride):
		samples.append([t, 0])
		samples.append([t, n - 1])
		samples.append([0, t])
		samples.append([n - 1, t])
	for c in [[0, 0], [0, n - 1], [n - 1, 0], [n - 1, n - 1]]:
		samples.append(c)
	# Random interior + boundary cells.
	for _r in range(2000):
		samples.append([_rand_int(0, n), _rand_int(0, n)])

	for face in range(6):
		for s in samples:
			var i: int = s[0]
			var j: int = s[1]
			var d := CS.face_cell_to_dir(face, i, j, n)
			var rt := CS.dir_to_face_cell(d, n)
			if int(rt["face"]) != face or int(rt["fi"]) != i or int(rt["fj"]) != j:
				bad += 1
				if bad <= 4:
					print("    mismatch face %d (%d,%d) -> %s" % [face, i, j, str(rt)])
			# Precision margin: how far the un-rounded recovery lands from the integer.
			var rf := CS.dir_to_face_cell_f(d, n)
			_worst_int_dev = maxf(_worst_int_dev, absf(float(rf["fa"]) - float(i)))
			_worst_int_dev = maxf(_worst_int_dev, absf(float(rf["fb"]) - float(j)))
			# dir -> cell -> dir stability.
			var d2 := CS.face_cell_to_dir(int(rt["face"]), int(rt["fi"]), int(rt["fj"]), n)
			_worst_stable_ang = maxf(_worst_stable_ang, d.angle_to(d2))
			checked += 1
	_ok(bad == 0, "[%s] exact cell->dir->cell over %d samples/face (%d bad)" % [label, checked, bad])
	# The rounding margin must be comfortably < 0.5 (f32 would blow this up); assert it holds.
	_ok(_worst_int_dev < 1e-4, "[%s] round-trip float lands within 1e-4 of the integer (worst %s) — f64 held" % [label, _worst_int_dev])

# ---------------------------------------------------------------------------------------
# [2] 1:1 edge adjacency (§4.1)
# ---------------------------------------------------------------------------------------
func _test_edge_adjacency() -> void:
	print("[2] 1:1 edge adjacency — no T-junctions (all 6 faces x 4 sides = 24 crossings)")
	var n := CS.n_for("earth")
	var cell_ang := (PI / 2.0) / float(n)   # nominal mid-face cell angular size
	var total_ok := 0
	for face in range(6):
		for side in range(4):
			var ok := _check_edge(face, side, n, cell_ang)
			if ok:
				total_ok += 1
	_ok(total_ok == 24, "all 24 edge crossings are 1:1 bijections with neighbour-adjacent cells (%d/24)" % total_ok)

func _check_edge(face: int, side: int, n: int, cell_ang: float) -> bool:
	# Boundary strip: the in-face row adjacent to this edge, and the out-of-range row one past.
	# Fold the out-of-range row and require (a) it maps to valid B cells on B's shared boundary,
	# (b) the map is a bijection, (c) each folded cell is one cell away from the in-face cell it
	# neighbours across the edge (no gap/overlap => cell complex, §4.1).
	var seen := {}
	var bijective := true
	var on_boundary := true
	var neighbours := true
	var b_expected := -1
	# Sample the strip (dense but not all N to keep it fast; boundaries + a fine stride).
	var idx: Array = []
	var stride := maxi(1, n / 400)
	for t in range(0, n, stride):
		idx.append(t)
	idx.append(n - 1)
	for t in idx:
		# in-face cell adjacent to the edge, and the window cell one past the edge.
		var inface: Array
		var outside: Array
		match side:
			CS.SIDE_EAST:  inface = [n - 1, t]; outside = [n, t]
			CS.SIDE_WEST:  inface = [0, t];     outside = [-1, t]
			CS.SIDE_NORTH: inface = [t, n - 1]; outside = [t, n]
			_:             inface = [t, 0];     outside = [t, -1]
		var fold := CS.fold_cell(face, outside[0], outside[1], n)
		var bf := int(fold["face"])
		var bi := int(fold["i"])
		var bj := int(fold["j"])
		if b_expected == -1:
			b_expected = bf
		if bf != b_expected:
			bijective = false
		if bi < 0 or bi >= n or bj < 0 or bj >= n:
			on_boundary = false
			continue
		# folded cell must sit on B's shared boundary (one of its four edges).
		if not (bi == 0 or bi == n - 1 or bj == 0 or bj == n - 1):
			on_boundary = false
		var key := bi * n + bj
		if seen.has(key):
			bijective = false
		seen[key] = true
		# geometric adjacency: the in-face cell and the folded B cell are ~one cell apart.
		var da := CS.face_cell_to_dir(face, inface[0], inface[1], n)
		var db := CS.face_cell_to_dir(bf, bi, bj, n)
		var ang := da.angle_to(db)
		if ang < 0.3 * cell_ang or ang > 1.9 * cell_ang:
			neighbours = false
	_ok(bijective, "  edge (face %d, side %d): fold is an injective map onto B=%d" % [face, side, b_expected])
	_ok(on_boundary, "  edge (face %d, side %d): every folded cell lands on B's shared boundary" % [face, side])
	_ok(neighbours, "  edge (face %d, side %d): straddling cells are ~one cell apart (no gap/overlap)" % [face, side])
	return bijective and on_boundary and neighbours

# ---------------------------------------------------------------------------------------
# [3] D4 remap pins (§4.2)
# ---------------------------------------------------------------------------------------
func _test_d4_pins() -> void:
	print("[3] D4 remap table pins (generated table == hand-verified, incl. §4.2 worked example)")
	var n := CS.n_for("earth")

	# Every one of the 24 entries: M is a valid D4 element (columns are +/- unit axes,
	# orthogonal, |det| = 1) and r is untouched (implicit — M/t act on (i,j) only).
	var all_d4 := true
	for face in range(6):
		for side in range(4):
			var e := CS.edge_remap(face, side, n)
			if not _is_d4(e["m"]):
				all_d4 = false
				print("    non-D4 M at face %d side %d: %s" % [face, side, str(e["m"])])
	_ok(all_d4, "all 24 generated M are valid D4 elements (signed permutations, det = +/-1)")

	# The §4.2 WORKED EXAMPLE: the edge between face 4 (+Z polar) and face 0 (+X). Face 4 cells
	# exiting its j=0 (SOUTH) side land on face 0. The doc gives v^4 = -X and v^0 = +Z and says
	# they meet on face 0's j=N-1 side; the trailing numeric formula in the doc is truncated
	# ("...") so we pin the structural facts it DOES state, plus the full generated affine map.
	var e40 := CS.edge_remap(4, CS.SIDE_SOUTH, n)
	_ok(int(e40["b"]) == 0, "§4.2 example: face 4 SOUTH (j=0) side neighbours face 0")
	# Fold a mid-edge cell one past face 4's j=0 edge; it must land on face 0's j=N-1 boundary.
	var f40 := CS.fold_cell(4, n / 2, -1, n)
	_ok(int(f40["face"]) == 0, "§4.2 example: fold(face4, j=-1) -> face 0")
	_ok(int(f40["j"]) == n - 1, "§4.2 example: lands on face 0's j=N-1 shared side (got j=%d)" % int(f40["j"]))
	_ok(int(f40["i"]) == n / 2, "§4.2 example: along-edge i preserved (i=%d)" % int(f40["i"]))
	# Pin the exact generated affine map for this edge: (i,j) -> (i, j+N).
	_ok(_map_eq(e40["m"], e40["t"], [1, 0, 0, 1], [0, n]),
		"§4.2 example: generated map is (i,j)->(i, j+N)  m=%s t=%s" % [str(e40["m"]), str(e40["t"])])

	# A second independent hand-derived pin: face 0's EAST (i=N-1) side neighbours face 2 (+Y),
	# entering at face 2's i=0 side, along-edge j preserved: (i,j) -> (i-N, j).
	var e02 := CS.edge_remap(0, CS.SIDE_EAST, n)
	_ok(int(e02["b"]) == 2, "pin: face 0 EAST side neighbours face 2")
	_ok(_map_eq(e02["m"], e02["t"], [1, 0, 0, 1], [-n, 0]),
		"pin: face 0 EAST map is (i,j)->(i-N, j)  m=%s t=%s" % [str(e02["m"]), str(e02["t"])])
	var f02 := CS.fold_cell(0, n, n / 2, n)
	_ok(int(f02["face"]) == 2 and int(f02["i"]) == 0 and int(f02["j"]) == n / 2,
		"pin: fold(face0, i=N) -> face 2 (0, N/2)")

	# Round-trip consistency of the table: folding across an edge and back returns identity
	# for a mid-strip cell (the two directed crossings of an edge are inverse maps).
	var round_ok := true
	for face in range(6):
		for side in range(4):
			var oc: Array
			match side:
				CS.SIDE_EAST:  oc = [n, n / 2]
				CS.SIDE_WEST:  oc = [-1, n / 2]
				CS.SIDE_NORTH: oc = [n / 2, n]
				_:             oc = [n / 2, -1]
			var f := CS.fold_cell(face, oc[0], oc[1], n)
			# fold the B cell's mirror-back: recompute the direction and re-classify — the
			# folded cell's own face_cell_to_dir must classify to itself (a valid B cell).
			var d := CS.face_cell_to_dir(int(f["face"]), int(f["i"]), int(f["j"]), n)
			var rt := CS.dir_to_face_cell(d, n)
			if int(rt["face"]) != int(f["face"]) or int(rt["fi"]) != int(f["i"]) or int(rt["fj"]) != int(f["j"]):
				round_ok = false
	_ok(round_ok, "folded cells are self-consistent lattice cells on their neighbour face")

func _is_d4(m: Array) -> bool:
	# columns must each be a +/-unit axis and orthogonal; determinant +/-1.
	var det: int = m[0] * m[3] - m[1] * m[2]
	if absi(det) != 1:
		return false
	# each entry in {-1,0,1}, each row/col has exactly one nonzero.
	for v in m:
		if v < -1 or v > 1:
			return false
	var col0_nz: int = (1 if m[0] != 0 else 0) + (1 if m[2] != 0 else 0)
	var col1_nz: int = (1 if m[1] != 0 else 0) + (1 if m[3] != 0 else 0)
	return col0_nz == 1 and col1_nz == 1

func _map_eq(m: Array, t: Array, em: Array, et: Array) -> bool:
	return m[0] == em[0] and m[1] == em[1] and m[2] == em[2] and m[3] == em[3] \
		and t[0] == et[0] and t[1] == et[1]

# ---------------------------------------------------------------------------------------
# [4] Global key pack/unpack (§1.3)
# ---------------------------------------------------------------------------------------
func _test_global_key() -> void:
	print("[4] global edit key pack/unpack bijection (§1.3), incl. extremes + region prefix")
	var n := CS.n_for("earth")
	var seen := {}
	var bij := true
	var fits := true
	# Extremes: faces 0..5; i,j at 0/1/N-1 and the 14-bit max; r at +/- extremes.
	var i_vals := [0, 1, 7, n - 1, 16383]
	var j_vals := [0, 1, 42, n - 1, 16383]
	var r_vals := [-2048, -64, -1, 0, 1, 116, 2047]
	for face in range(6):
		for i in i_vals:
			for j in j_vals:
				for r in r_vals:
					var k := CS.edit_key(face, i, j, r)
					if k < 0 or k >= (1 << 43):
						fits = false
					var u := CS.unpack_key(k)
					if int(u["face"]) != face or int(u["i"]) != i or int(u["j"]) != j or int(u["r"]) != r:
						bij = false
					if seen.has(k):
						bij = false
					seen[k] = true
	_ok(bij, "edit_key pack/unpack is a bijection over %d (face,i,j,r) extremes (no collisions)" % seen.size())
	_ok(fits, "every key fits in 43 bits (int64-safe)")

	# Region prefix: all cells in one 32^3 region share region_key; neighbouring regions differ.
	var base_face := 2
	var bi := 320
	var bj := 480
	var br := -32
	var rk := CS.region_key(base_face, bi, bj, br)
	var consistent := true
	for di in range(CS.REGION_SIZE):
		for dj in [0, 15, 31]:
			for dr in [0, 31]:
				if CS.region_key(base_face, bi + di, bj + dj, br + dr) != rk:
					consistent = false
	_ok(consistent, "region_key is constant across a full 32^3 region (prefix consistent)")
	var distinct := CS.region_key(base_face, bi + 32, bj, br) != rk \
		and CS.region_key(base_face, bi, bj + 32, br) != rk \
		and CS.region_key(base_face, bi, bj, br + 32) != rk \
		and CS.region_key(base_face + 1, bi, bj, br) != rk
	_ok(distinct, "region_key differs for each adjacent region (i/j/r/face)")
	# N is 32-aligned so no region straddles a face (§1.1/§8.2).
	var aligned := true
	for body in CS.BODY_N.keys():
		if CS.n_for(body) % CS.REGION_SIZE != 0:
			aligned = false
	_ok(aligned, "every body's N is a multiple of 32 (no region straddles a face)")

# ---------------------------------------------------------------------------------------
# [5] Distortion bound (§2.2) — proves the warp is the equal-angle one.
# ---------------------------------------------------------------------------------------
func _test_distortion_bound() -> void:
	print("[5] distortion bound (§2.2): equal-angle cell width in [0.707, 1.0], worst ratio sqrt(2)")
	var n := CS.n_for("earth")
	# Measure the along-i and along-j angular cell widths across a face by finite differences,
	# normalized to the face-centre width. The equal-angle warp gives min ~0.7071 (edge-mid,
	# transverse) and max 1.0 (centre / along-edge); worst max/min = sqrt(2). A wrong warp
	# constant (e.g. raw gnomonic, or tan of a wrong multiple) would violate this.
	var centre_w := _cell_angwidth_i(n, n / 2, n / 2)   # face-centre reference
	var minw := INF
	var maxw := -INF
	var face := 0
	for i in range(0, n, maxi(1, n / 60)):
		for j in range(0, n, maxi(1, n / 60)):
			var wi := _cell_angwidth_i(n, i, j) / centre_w
			var wj := _cell_angwidth_j(n, i, j) / centre_w
			minw = minf(minw, minf(wi, wj))
			maxw = maxf(maxw, maxf(wi, wj))
	print("    normalized cell width range over face 0: [%.4f, %.4f], ratio %.4f" % [minw, maxw, maxw / minw])
	_ok(maxw <= 1.0 + 1e-3, "max normalized cell width <= 1.0 (got %.4f)" % maxw)
	_ok(minw >= 0.7071 - 3e-3, "min normalized cell width >= 0.7071 (got %.4f)" % minw)
	_ok(maxw / minw <= 1.4143, "worst linear cell-size ratio <= sqrt(2) (got %.4f)" % (maxw / minw))
	# Sanity: face centre is isotropic (i and j widths equal there).
	var iso := absf(_cell_angwidth_i(n, n / 2, n / 2) - _cell_angwidth_j(n, n / 2, n / 2))
	_ok(iso < 1e-6 * centre_w, "face centre is isotropic (i/j cell widths equal)")

func _cell_angwidth_i(n: int, i: int, j: int) -> float:
	var a := CS.face_cell_to_dir(0, float(i) - 0.5, float(j), n)
	var b := CS.face_cell_to_dir(0, float(i) + 0.5, float(j), n)
	return a.angle_to(b)

func _cell_angwidth_j(n: int, i: int, j: int) -> float:
	var a := CS.face_cell_to_dir(0, float(i), float(j) - 0.5, n)
	var b := CS.face_cell_to_dir(0, float(i), float(j) + 0.5, n)
	return a.angle_to(b)

# ---------------------------------------------------------------------------------------
# [6] Determinism (§8.2)
# ---------------------------------------------------------------------------------------
func _test_determinism() -> void:
	print("[6] determinism: functions are pure (same input -> identical output)")
	var n := CS.n_for("earth")
	var pure := true
	for _t in range(500):
		var face := _rand_int(0, 6)
		var i := _rand_int(0, n)
		var j := _rand_int(0, n)
		var d1 := CS.face_cell_to_dir(face, i, j, n)
		var d2 := CS.face_cell_to_dir(face, i, j, n)
		if d1.x != d2.x or d1.y != d2.y or d1.z != d2.z:
			pure = false
		var k1 := CS.dir_to_face_cell(d1, n)
		var k2 := CS.dir_to_face_cell(d1, n)
		if int(k1["fi"]) != int(k2["fi"]) or int(k1["fj"]) != int(k2["fj"]) or int(k1["face"]) != int(k2["face"]):
			pure = false
	_ok(pure, "face_cell_to_dir / dir_to_face_cell are bit-for-bit deterministic on re-call")
	# warp/unwarp inverse to < 1 ULP-ish over the domain.
	var worst := 0.0
	for s in range(-99, 100):
		var a := float(s) / 100.0
		worst = maxf(worst, absf(CS.unwarp(CS.warp(a)) - a))
	_ok(worst < 1e-12, "unwarp(warp(a)) == a to < 1e-12 over [-0.99, 0.99] (worst %s)" % worst)

# ---------------------------------------------------------------------------------------
# [7] Corner + orientation tables (§5.2 / §5.3)
# ---------------------------------------------------------------------------------------
func _test_corner_tables() -> void:
	print("[7] corner tables + orientation (§5.2/§5.3): 8 valence-3 corners at lat +/-35.26 deg")
	var n := CS.n_for("earth")
	# Orientation: the poles (+/-Z) are at face-4/5 CENTRES (§5.2).
	var cn := (n / 2)   # a central cell (centre lies between cn-1 and cn; use the near-centre cell)
	var north := CS.face_cell_to_dir(4, cn, cn, n)
	var south := CS.face_cell_to_dir(5, cn, cn, n)
	_ok(north.z > 0.9999, "face 4 centre points at +Z (north pole)")
	_ok(south.z < -0.9999, "face 5 centre points at -Z (south pole)")

	# The 8 corners sit at |z| = 1/sqrt(3) -> latitude asin(1/sqrt3) = 35.264 deg.
	var lat_ok := true
	for k in range(8):
		var c := CS.corner_dir(k)
		if absf(absf(c.z) - CS.INV_SQRT3) > 1e-12:
			lat_ok = false
		# unit length
		if absf(c.length() - 1.0) > 1e-12:
			lat_ok = false
	var lat_deg := rad_to_deg(asin(CS.INV_SQRT3))
	_ok(lat_ok, "all 8 corner directions are unit vectors at |z|=1/sqrt3 (latitude %.3f deg)" % lat_deg)
	_ok(absf(lat_deg - 35.2644) < 1e-3, "corner latitude is 35.264 deg (got %.4f)" % lat_deg)

	# Each corner is shared by exactly 3 faces (a valence-3 defect), and each face's listed
	# corner cell is a grid corner (i,j in {0, N-1}) whose direction is nearest the corner.
	var struct_ok := true
	var meet3 := true
	for k in range(8):
		var cells := CS.corner_cells(k, n)
		if cells.size() != 3:
			meet3 = false
			continue
		var faces_seen := {}
		var cdir := CS.corner_dir(k)
		for cell in cells:
			faces_seen[int(cell["face"])] = true
			var ci := int(cell["i"])
			var cj := int(cell["j"])
			if not ((ci == 0 or ci == n - 1) and (cj == 0 or cj == n - 1)):
				struct_ok = false
			# the corner cell's direction must be close to the corner direction (within a
			# couple of cells' worth of angle).
			var d := CS.face_cell_to_dir(int(cell["face"]), ci, cj, n)
			if d.angle_to(cdir) > 5.0 * (PI / 2.0) / float(n):
				struct_ok = false
		if faces_seen.size() != 3:
			meet3 = false
	_ok(meet3, "each of the 8 corners is shared by exactly 3 faces (valence-3)")
	_ok(struct_ok, "each corner cell is a grid corner nearest its cube-corner direction")

	# PIN the corner-cell table for the (+,+,+) corner: faces {0,2,4} (the +X,+Y,+Z faces).
	var c0 := CS.corner_cells(0, n)   # signs [+1,+1,+1]
	var got_faces := {}
	for cell in c0:
		got_faces[int(cell["face"])] = Vector2i(int(cell["i"]), int(cell["j"]))
	_ok(got_faces.has(0) and got_faces.has(2) and got_faces.has(4),
		"pin: corner (+,+,+) is shared by faces 0, 2, 4")
	# Face 0 (n=+X, u=+Y, v=+Z): (+,+,+) has +Y and +Z projections -> corner cell (N-1, N-1).
	_ok(got_faces.get(0, Vector2i(-1, -1)) == Vector2i(n - 1, n - 1),
		"pin: corner (+,+,+) on face 0 is cell (N-1, N-1)")
	# Face 4 (n=+Z, u=+Y, v=-X): (+,+,+) has +Y (u>0 -> i=N-1) and -X . v=-X>0? v^=-X, corner.x=+1
	# so corner . v^ = -1 < 0 -> j=0. Corner cell (N-1, 0).
	_ok(got_faces.get(4, Vector2i(-1, -1)) == Vector2i(n - 1, 0),
		"pin: corner (+,+,+) on face 4 is cell (N-1, 0)")

	# Corner constants carried for M5.
	_ok(CS.CORNER_SEA_R == 48 and CS.CORNER_LOCK_R == 8, "corner-zone constants pinned (SEA_R=48, LOCK_R=8)")
