class_name FacetAtlas
extends RefCounted
## COSMOS FACETED (docs/COSMOS-FACETED-IMPL.md §2) — the FacetAtlas kernel. Built ONCE at warm_up: for each of
## the 6·K² facets of the piecewise-flat planet it computes a PLANARIZED square patch (§2.1), its rigid
## lattice→planet frame (§2.2, forced right-handed), a per-facet decorrelation offset O (§2.3), and the local
## polygon + lattice domain (§2.4). Faceted worldgen samples the real sphere terrain at each facet cell's true
## direction (cell_dir → TerrainConfig.profile_at_dir). ALL kernel math is f64 (scalars / CubeSphere.DVec3) —
## NEVER route a direction/anchor through Vector3 (f32) before the final placement (pitfall #1). Pure/immutable
## after warm_up (read-only-after-freeze, like the noise singletons), so voxel workers may read it. Generation
## is a pure function of (SEED, fid, x, z) — stronger than the curved frozen-epoch contract (no window state).

const K := 24                    # faceting resolution: 6·K² = 3456 facets — LOCKED at 24 (user taste-test, FP0 k=8/16/24)
const R_BLOCKS := 3072.0         # planet radius, blocks. Facet edge = (π/2·R)/K ≈ 200 blocks — R tracks K so a facet
                                 # stays a ~200-block playable patch (facet size is the only thing R×K couple; scale-invariant math)
const MARGIN_CELLS := 8          # lattice cells kept beyond the facet polygon (streaming slack)
const STRIP_CELLS := 2           # per-side seam strip width (FP2+)
const SPAWN_EDGE_MIN := 48       # spawn scan stays ≥ this many cells from the facet boundary

static var _ready := false
static var _nf := 0
static var _frame := PackedFloat64Array()   # 12/fid: c0'(3) ê_u(3) n̂(3) ê_w(3)
static var _off := PackedInt32Array()        # 2/fid: O.x O.z
static var _poly := PackedFloat64Array()     # 8/fid: local q0..q3 as (x,y)
static var _dom := PackedInt32Array()        # 4/fid: minx minz maxx maxz
static var _spawn_fid := -1

static func facet_count() -> int:
	return 6 * K * K

## Build the whole atlas once (main thread). Call AFTER TerrainConfig.warm_up (spawn pick reads worldgen).
static func warm_up() -> void:
	if _ready:
		return
	_nf = 6 * K * K
	_frame.resize(_nf * 12)
	_off.resize(_nf * 2)
	_poly.resize(_nf * 8)
	_dom.resize(_nf * 4)
	for face in range(6):
		for a in range(K):
			for b in range(K):
				_build_facet((face * K + a) * K + b, face, a, b)
	_spawn_fid = _pick_spawn_facet()
	_ready = true

static func is_ready() -> bool:
	return _ready

# ------- construction (f64) -------

static func _corner(face: int, i: int, j: int) -> Array:
	var d := CosmosFacet.vertex_dir(face, i, j, K)   # f64 DVec3 unit
	return [d.x * R_BLOCKS, d.y * R_BLOCKS, d.z * R_BLOCKS]

static func _cross(a: Array, b: Array) -> Array:
	return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]

static func _norm(a: Array) -> Array:
	var l: float = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
	if l == 0.0:
		return [0.0, 0.0, 0.0]
	return [a[0] / l, a[1] / l, a[2] / l]

static func _build_facet(fid: int, face: int, a: int, b: int) -> void:
	var c: Array = [_corner(face, a, b), _corner(face, a + 1, b), _corner(face, a + 1, b + 1), _corner(face, a, b + 1)]
	var mx: float = (c[0][0] + c[1][0] + c[2][0] + c[3][0]) / 4.0
	var my: float = (c[0][1] + c[1][1] + c[2][1] + c[3][1]) / 4.0
	var mz: float = (c[0][2] + c[1][2] + c[2][2] + c[3][2]) / 4.0
	# mean-plane normal = normalize((c2−c0) × (c3−c1)), oriented OUTWARD (radial side)
	var d1: Array = [c[2][0] - c[0][0], c[2][1] - c[0][1], c[2][2] - c[0][2]]
	var d2: Array = [c[3][0] - c[1][0], c[3][1] - c[1][1], c[3][2] - c[1][2]]
	var n: Array = _norm(_cross(d1, d2))
	if n[0] * mx + n[1] * my + n[2] * mz < 0.0:
		n = [-n[0], -n[1], -n[2]]
	# project corners onto the mean plane
	var cp: Array = []
	for i in range(4):
		var s: float = (c[i][0] - mx) * n[0] + (c[i][1] - my) * n[1] + (c[i][2] - mz) * n[2]
		cp.append([c[i][0] - s * n[0], c[i][1] - s * n[1], c[i][2] - s * n[2]])
	var eu: Array = _norm([cp[1][0] - cp[0][0], cp[1][1] - cp[0][1], cp[1][2] - cp[0][2]])
	var ew: Array = _cross(eu, n)          # ê_u × n̂ — FORCED right-handed (X×Y=Z), never from the c3 edge
	var ox := int(floor(TerrainConfig._hash01_3d(fid, 11, 0, 751) * 65536.0)) - 32768
	var oz := int(floor(TerrainConfig._hash01_3d(fid, 23, 0, 757) * 65536.0)) - 32768
	var f := fid * 12
	_frame[f + 0] = cp[0][0]; _frame[f + 1] = cp[0][1]; _frame[f + 2] = cp[0][2]
	_frame[f + 3] = eu[0]; _frame[f + 4] = eu[1]; _frame[f + 5] = eu[2]
	_frame[f + 6] = n[0]; _frame[f + 7] = n[1]; _frame[f + 8] = n[2]
	_frame[f + 9] = ew[0]; _frame[f + 10] = ew[1]; _frame[f + 11] = ew[2]
	_off[fid * 2] = ox; _off[fid * 2 + 1] = oz
	var minx := 1.0e18; var minz := 1.0e18; var maxx := -1.0e18; var maxz := -1.0e18
	for i in range(4):
		var dvx: float = cp[i][0] - cp[0][0]
		var dvy: float = cp[i][1] - cp[0][1]
		var dvz: float = cp[i][2] - cp[0][2]
		var qx: float = dvx * eu[0] + dvy * eu[1] + dvz * eu[2]
		var qy: float = dvx * ew[0] + dvy * ew[1] + dvz * ew[2]
		_poly[fid * 8 + i * 2] = qx; _poly[fid * 8 + i * 2 + 1] = qy
		minx = minf(minx, qx); minz = minf(minz, qy); maxx = maxf(maxx, qx); maxz = maxf(maxz, qy)
	_dom[fid * 4 + 0] = ox + int(floor(minx)) - MARGIN_CELLS
	_dom[fid * 4 + 1] = oz + int(floor(minz)) - MARGIN_CELLS
	_dom[fid * 4 + 2] = ox + int(ceil(maxx)) + MARGIN_CELLS
	_dom[fid * 4 + 3] = oz + int(ceil(maxz)) + MARGIN_CELLS

# ------- runtime (f64; the ONE map both sampling and placement use) -------

## Facet cell (x,z) → its true sphere direction (f64). Column d̂ at the plane point y=0 (§3.2): a facet column
## is straight along n̂ so all its cells share one d̂. Sampling shares this map with placement → they can't disagree.
static func cell_dir(fid: int, x: int, z: int) -> CubeSphere.DVec3:
	var f := fid * 12
	var fx := float(x) - float(_off[fid * 2]) + 0.5
	var fz := float(z) - float(_off[fid * 2 + 1]) + 0.5
	return CubeSphere.DVec3.new(
		_frame[f + 0] + fx * _frame[f + 3] + fz * _frame[f + 9],
		_frame[f + 1] + fx * _frame[f + 4] + fz * _frame[f + 10],
		_frame[f + 2] + fx * _frame[f + 5] + fz * _frame[f + 11]).normalized()

## The rigid placement Transform3D (FP2+ node placement; FP1 renders in the local frame and never needs it).
static func facet_transform(fid: int) -> Transform3D:
	var f := fid * 12
	var eu := Vector3(_frame[f + 3], _frame[f + 4], _frame[f + 5])
	var ny := Vector3(_frame[f + 6], _frame[f + 7], _frame[f + 8])
	var ew := Vector3(_frame[f + 9], _frame[f + 10], _frame[f + 11])
	var c0 := Vector3(_frame[f + 0], _frame[f + 1], _frame[f + 2])
	var ox := float(_off[fid * 2]); var oz := float(_off[fid * 2 + 1])
	return Transform3D(Basis(eu, ny, ew), c0 - ox * eu - oz * ew)

## True iff facet cell (x,z) is inside the facet polygon dilated by `grow` cells (convex quad, 4 half-planes).
## `grow` is OUTWARD dilation: grow=0 is the exact polygon, grow>0 admits points up to `grow` cells OUTSIDE an
## edge (FP2 ring overlap), grow<0 requires points at least |grow| cells INSIDE (spawn margin). Winding-robust:
## the polygon centroid fixes the interior sign, so it works regardless of the (eu, ew) handedness (which is
## CW because ê_w = ê_u × n̂ ⇒ ê_u × ê_w = −n̂ — a left-handed 2D frame viewed from outside).
static func in_polygon(fid: int, x: int, z: int, grow: float) -> bool:
	var px := float(x) - float(_off[fid * 2]) + 0.5
	var pz := float(z) - float(_off[fid * 2 + 1]) + 0.5
	var p := fid * 8
	var cx: float = (_poly[p + 0] + _poly[p + 2] + _poly[p + 4] + _poly[p + 6]) / 4.0
	var cz: float = (_poly[p + 1] + _poly[p + 3] + _poly[p + 5] + _poly[p + 7]) / 4.0
	for e in range(4):
		var ax := _poly[p + e * 2]; var ay := _poly[p + e * 2 + 1]
		var bx := _poly[p + ((e + 1) % 4) * 2]; var by := _poly[p + ((e + 1) % 4) * 2 + 1]
		var ex := bx - ax; var ey := by - ay
		var elen: float = sqrt(ex * ex + ey * ey)
		if elen == 0.0:
			continue
		var cp: float = ex * (pz - ay) - ey * (px - ax)     # 2× signed area of (a,b,p): sign = which side
		var cc: float = ex * (cz - ay) - ey * (cx - ax)     # centroid is interior → its sign IS the interior side
		var inward: float = (cp if cc >= 0.0 else -cp) / elen   # distance from the edge INTO the interior
		if inward < -grow:
			return false
	return true

# domain accessors (gates / FP2 streaming bounds)
static func dom_min(fid: int) -> Vector2i:
	return Vector2i(_dom[fid * 4 + 0], _dom[fid * 4 + 1])
static func dom_max(fid: int) -> Vector2i:
	return Vector2i(_dom[fid * 4 + 2], _dom[fid * 4 + 3])
static func frame_basis(fid: int) -> Basis:
	var f := fid * 12
	return Basis(Vector3(_frame[f + 3], _frame[f + 4], _frame[f + 5]),
		Vector3(_frame[f + 6], _frame[f + 7], _frame[f + 8]),
		Vector3(_frame[f + 9], _frame[f + 10], _frame[f + 11]))

# ------- spawn (§3.3 item 5) -------

static func _facet_centre_cell(fid: int) -> Vector2i:
	var p := fid * 8
	var qx: float = (_poly[p + 0] + _poly[p + 2] + _poly[p + 4] + _poly[p + 6]) / 4.0
	var qy: float = (_poly[p + 1] + _poly[p + 3] + _poly[p + 5] + _poly[p + 7]) / 4.0
	return Vector2i(_off[fid * 2] + int(round(qx)), _off[fid * 2 + 1] + int(round(qy)))

static func _pick_spawn_facet() -> int:
	for fid in range(_nf):
		var cc := _facet_centre_cell(fid)
		var d := cell_dir(fid, cc.x, cc.y)
		if absf(d.z) >= 0.5:                       # temperate latitude only (|sin φ| < 0.5)
			continue
		var prof := TerrainConfig.facet_profile(fid, cc.x, cc.y)
		var g := int(prof.x); var biome := int(prof.y)
		if g > TerrainConfig.SEA_LEVEL + 1 and (biome == TerrainConfig.B_PLAINS or biome == TerrainConfig.B_FOREST):
			return fid
	return 0

static func spawn_facet() -> int:
	return _spawn_fid

## The centre lattice cell of any facet (gates / FP2 window centring).
static func centre_cell(fid: int) -> Vector2i:
	return _facet_centre_cell(fid)

## The spawn column (facet-local lattice cell) for find_spawn — the spawn facet's window centre.
static func spawn_column() -> Vector2i:
	return _facet_centre_cell(_spawn_fid)

# ------- frame self-test (G-F1e, all f64 — never routes the frame through f32 Vector3) -------

## f64 frame-math metrics for facet `fid` (the FP1 gate G-F1e asserts thresholds on these). Recomputes the
## true (unprojected) corners, reads the stored frame, and returns: orthonormality residual, basis
## determinant, n̂·(centre radial), max original-corner plane deviation (blocks) + edge length, and the
## worst W_fid⁻¹∘W_fid round-trip error over a 3×3 cell sample. All arithmetic stays in f64.
static func verify_frame(fid: int) -> Dictionary:
	var f := fid * 12
	var c0: Array = [_frame[f + 0], _frame[f + 1], _frame[f + 2]]
	var eu: Array = [_frame[f + 3], _frame[f + 4], _frame[f + 5]]
	var n: Array = [_frame[f + 6], _frame[f + 7], _frame[f + 8]]
	var ew: Array = [_frame[f + 9], _frame[f + 10], _frame[f + 11]]
	# orthonormality residual: worst deviation of the Gram matrix from identity
	var ortho := 0.0
	for pair in [[eu, eu, 1.0], [n, n, 1.0], [ew, ew, 1.0], [eu, n, 0.0], [eu, ew, 0.0], [n, ew, 0.0]]:
		var a: Array = pair[0]; var b: Array = pair[1]
		ortho = maxf(ortho, absf(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] - pair[2]))
	# determinant of [eu | n | ew] = eu · (n × ew); +1 for a right-handed orthonormal basis
	var nxw: Array = _cross(n, ew)
	var det: float = eu[0] * nxw[0] + eu[1] * nxw[1] + eu[2] * nxw[2]
	# recompute the true (unprojected) corners + centroid → n̂ must point along the centre radial
	var face := int(fid / (K * K))
	var rem := fid - face * K * K
	var a := int(rem / K); var b := rem - a * K
	var tc: Array = [_corner(face, a, b), _corner(face, a + 1, b), _corner(face, a + 1, b + 1), _corner(face, a, b + 1)]
	var mx: float = (tc[0][0] + tc[1][0] + tc[2][0] + tc[3][0]) / 4.0
	var my: float = (tc[0][1] + tc[1][1] + tc[2][1] + tc[3][1]) / 4.0
	var mz: float = (tc[0][2] + tc[1][2] + tc[2][2] + tc[3][2]) / 4.0
	var ml: float = sqrt(mx * mx + my * my + mz * mz)
	var n_dot_centre: float = (n[0] * mx + n[1] * my + n[2] * mz) / ml
	# original corners' deviation from the stored mean plane (through c0 with normal n)
	var plane_dev := 0.0
	for i in range(4):
		var dev: float = (tc[i][0] - c0[0]) * n[0] + (tc[i][1] - c0[1]) * n[1] + (tc[i][2] - c0[2]) * n[2]
		# c0 is the PROJECTED corner 0; measure each true corner's signed distance to the plane, de-meaned
		plane_dev = maxf(plane_dev, absf(dev))
	var edge: float = sqrt(pow(tc[1][0] - tc[0][0], 2.0) + pow(tc[1][1] - tc[0][1], 2.0) + pow(tc[1][2] - tc[0][2], 2.0))
	# W_fid round-trip: place a sample cell, invert with the orthonormal basis, recover (x−O.x, y, z−O.z)
	var rt := 0.0
	for sx in [-1, 0, 1]:
		for sz in [-1, 0, 1]:
			var px: float = 100.0 + float(sx)
			var pz: float = 100.0 + float(sz)
			var yy: float = 7.0
			var wx: float = c0[0] + px * eu[0] + yy * n[0] + pz * ew[0]
			var wy: float = c0[1] + px * eu[1] + yy * n[1] + pz * ew[1]
			var wz: float = c0[2] + px * eu[2] + yy * n[2] + pz * ew[2]
			var rx: float = wx - c0[0]; var ry: float = wy - c0[1]; var rz: float = wz - c0[2]
			var iu: float = rx * eu[0] + ry * eu[1] + rz * eu[2]
			var iy: float = rx * n[0] + ry * n[1] + rz * n[2]
			var iw: float = rx * ew[0] + ry * ew[1] + rz * ew[2]
			rt = maxf(rt, maxf(absf(iu - px), maxf(absf(iy - yy), absf(iw - pz))))
	return {"ortho": ortho, "det": det, "n_dot_centre": n_dot_centre, "plane_dev": plane_dev, "edge": edge, "roundtrip": rt}
