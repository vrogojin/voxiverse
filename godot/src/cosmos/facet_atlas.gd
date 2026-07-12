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

# COSMOS FACETED FP2 (§2.5) — per-facet seam table. Every facet has EXACTLY 4 grid-edge neighbours (the K×K×6
# facet grid is closed via CubeSphere.fold_cell at n=K), one per slot E/W/N/S. Each slot stores THIS facet's
# OWN-side ridge plane in its LATTICE frame — own(x,y,z)=A·x+B·y+C·z+D ≥ 0 is the interior half-space — plus the
# welded ring (world) and the world ridge normal m̂. The plane, the FP2 domain mask, the junction clip, and the
# exact physics all read the SAME (A,B,C,D), so render == collision == mask by construction (§3.5).
const S_EAST := 0    # +a
const S_WEST := 1    # −a
const S_NORTH := 2   # +b
const S_SOUTH := 3   # −b
static var _seam_plane := PackedFloat64Array()   # 16/fid: 4 slots × (A,B,C,D) — own-side plane in lattice coords
static var _seam_neigh := PackedInt32Array()     # 4/fid: neighbour fid per slot
static var _seam_ring := PackedFloat64Array()    # 24/fid: 4 slots × (r0.xyz, r1.xyz) welded ring (world)
static var _seam_mhat := PackedFloat64Array()    # 12/fid: 4 slots × m̂.xyz (world ridge normal, toward this facet)

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
	# seams need every facet's frame built first (each seam reads BOTH facets' planes)
	_seam_plane.resize(_nf * 16)
	_seam_neigh.resize(_nf * 4)
	_seam_ring.resize(_nf * 24)
	_seam_mhat.resize(_nf * 12)
	for face in range(6):
		for a in range(K):
			for b in range(K):
				var fid := (face * K + a) * K + b
				for slot in range(4):
					_build_seam(fid, face, a, b, slot)
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

# ------- seams (§2.5, f64) -------

# The raw neighbour facet grid index (a±1 / b±1; may be out of [0,K) → fold_cell resolves it cross-face).
static func _neigh_ab(a: int, b: int, slot: int) -> Vector2i:
	match slot:
		S_EAST: return Vector2i(a + 1, b)
		S_WEST: return Vector2i(a - 1, b)
		S_NORTH: return Vector2i(a, b + 1)
		_: return Vector2i(a, b - 1)

# The two shared true-corner VERTEX (i,j) indices of this slot's grid edge, in THIS facet's face indexing.
static func _seam_edge_ij(a: int, b: int, slot: int) -> Array:
	match slot:
		S_EAST: return [a + 1, b, a + 1, b + 1]
		S_WEST: return [a, b, a, b + 1]
		S_NORTH: return [a, b + 1, a + 1, b + 1]
		_: return [a, b, a + 1, b]     # S_SOUTH

static func _proj_plane(p: Array, c0: Array, n: Array) -> Array:
	var s: float = (p[0] - c0[0]) * n[0] + (p[1] - c0[1]) * n[1] + (p[2] - c0[2]) * n[2]
	return [p[0] - s * n[0], p[1] - s * n[1], p[2] - s * n[2]]

static func _facet_world_centroid(fid: int) -> Array:
	var f := fid * 12
	var p := fid * 8
	var qcx: float = (_poly[p + 0] + _poly[p + 2] + _poly[p + 4] + _poly[p + 6]) / 4.0
	var qcy: float = (_poly[p + 1] + _poly[p + 3] + _poly[p + 5] + _poly[p + 7]) / 4.0
	return [_frame[f + 0] + qcx * _frame[f + 3] + qcy * _frame[f + 9],
		_frame[f + 1] + qcx * _frame[f + 4] + qcy * _frame[f + 10],
		_frame[f + 2] + qcx * _frame[f + 5] + qcy * _frame[f + 11]]

static func _build_seam(fid: int, face: int, a: int, b: int, slot: int) -> void:
	var fA := fid * 12
	var c0A: Array = [_frame[fA + 0], _frame[fA + 1], _frame[fA + 2]]
	var euA: Array = [_frame[fA + 3], _frame[fA + 4], _frame[fA + 5]]
	var nA: Array = [_frame[fA + 6], _frame[fA + 7], _frame[fA + 8]]
	var ewA: Array = [_frame[fA + 9], _frame[fA + 10], _frame[fA + 11]]
	# neighbour facet via fold_cell at grid resolution K (single-edge fold — a facet is never double-out)
	var nb := _neigh_ab(a, b, slot)
	var fold: Dictionary = CubeSphere.fold_cell(face, nb.x, nb.y, K)
	var fidB := (int(fold["face"]) * K + int(fold["i"])) * K + int(fold["j"])
	var fB := fidB * 12
	var c0B: Array = [_frame[fB + 0], _frame[fB + 1], _frame[fB + 2]]
	var nB: Array = [_frame[fB + 6], _frame[fB + 7], _frame[fB + 8]]
	# shared true edge endpoints (·R, un-planarized), projected onto BOTH facet planes and averaged = welded ring
	var ev := _seam_edge_ij(a, b, slot)
	var e0 := _corner(face, ev[0], ev[1])
	var e1 := _corner(face, ev[2], ev[3])
	var pA0 := _proj_plane(e0, c0A, nA); var pB0 := _proj_plane(e0, c0B, nB)
	var pA1 := _proj_plane(e1, c0A, nA); var pB1 := _proj_plane(e1, c0B, nB)
	var r0: Array = [(pA0[0] + pB0[0]) / 2.0, (pA0[1] + pB0[1]) / 2.0, (pA0[2] + pB0[2]) / 2.0]
	var r1: Array = [(pA1[0] + pB1[0]) / 2.0, (pA1[1] + pB1[1]) / 2.0, (pA1[2] + pB1[2]) / 2.0]
	# ridge (bisector) plane: normal m̂ = normalize(t̂ × ĥ), oriented toward THIS facet's centroid
	var that := _norm([r1[0] - r0[0], r1[1] - r0[1], r1[2] - r0[2]])
	var hhat := _norm([nA[0] + nB[0], nA[1] + nB[1], nA[2] + nB[2]])
	var mhat := _norm(_cross(that, hhat))
	var mc := _facet_world_centroid(fid)
	if mhat[0] * (mc[0] - r0[0]) + mhat[1] * (mc[1] - r0[1]) + mhat[2] * (mc[2] - r0[2]) < 0.0:
		mhat = [-mhat[0], -mhat[1], -mhat[2]]
	# express own-side half-space in THIS facet's lattice frame: own(x,y,z) = A·x + B·y + C·z + D ≥ 0
	var A: float = mhat[0] * euA[0] + mhat[1] * euA[1] + mhat[2] * euA[2]
	var Bc: float = mhat[0] * nA[0] + mhat[1] * nA[1] + mhat[2] * nA[2]
	var C: float = mhat[0] * ewA[0] + mhat[1] * ewA[1] + mhat[2] * ewA[2]
	var ox := float(_off[fid * 2]); var oz := float(_off[fid * 2 + 1])
	var D: float = (mhat[0] * (c0A[0] - r0[0]) + mhat[1] * (c0A[1] - r0[1]) + mhat[2] * (c0A[2] - r0[2])) - A * ox - C * oz
	var sp := fid * 16 + slot * 4
	_seam_plane[sp + 0] = A; _seam_plane[sp + 1] = Bc; _seam_plane[sp + 2] = C; _seam_plane[sp + 3] = D
	_seam_neigh[fid * 4 + slot] = fidB
	var sr := fid * 24 + slot * 6
	_seam_ring[sr + 0] = r0[0]; _seam_ring[sr + 1] = r0[1]; _seam_ring[sr + 2] = r0[2]
	_seam_ring[sr + 3] = r1[0]; _seam_ring[sr + 4] = r1[1]; _seam_ring[sr + 5] = r1[2]
	var sm := fid * 12 + slot * 3
	_seam_mhat[sm + 0] = mhat[0]; _seam_mhat[sm + 1] = mhat[1]; _seam_mhat[sm + 2] = mhat[2]

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

## f64 lattice→world: world point of lattice coords (x,y,z) via W_fid (§2.2). Returns [wx,wy,wz] (f64 scalars —
## never routed through f32 Vector3). The exact placement map; its inverse is world_to_lattice64.
static func lattice_to_world64(fid: int, x: float, y: float, z: float) -> Array:
	var f := fid * 12
	var fx := x - float(_off[fid * 2])
	var fz := z - float(_off[fid * 2 + 1])
	return [_frame[f + 0] + fx * _frame[f + 3] + y * _frame[f + 6] + fz * _frame[f + 9],
		_frame[f + 1] + fx * _frame[f + 4] + y * _frame[f + 7] + fz * _frame[f + 10],
		_frame[f + 2] + fx * _frame[f + 5] + y * _frame[f + 8] + fz * _frame[f + 11]]

## f64 world→lattice: inverse of W_fid (orthonormal basis ⇒ transpose). Returns [x,y,z].
static func world_to_lattice64(fid: int, wx: float, wy: float, wz: float) -> Array:
	var f := fid * 12
	var dx := wx - _frame[f + 0]; var dy := wy - _frame[f + 1]; var dz := wz - _frame[f + 2]
	return [dx * _frame[f + 3] + dy * _frame[f + 4] + dz * _frame[f + 5] + float(_off[fid * 2]),
		dx * _frame[f + 6] + dy * _frame[f + 7] + dz * _frame[f + 8],
		dx * _frame[f + 9] + dy * _frame[f + 10] + dz * _frame[f + 11] + float(_off[fid * 2 + 1])]

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

# ------- seams & junction clip (§2.5, §3.5 — runtime, all f64) -------

const SEAM_EPS := 1.0e-6

## The neighbour facet across `slot` (E/W/N/S) — the fid that shares this ridge.
static func seam_neighbour(fid: int, slot: int) -> int:
	return _seam_neigh[fid * 4 + slot]
## This facet's own-side ridge plane in its LATTICE frame: own(x,y,z)=A·x+B·y+C·z+D ≥ 0 is interior.
static func seam_plane(fid: int, slot: int) -> Vector4:
	var b := fid * 16 + slot * 4
	return Vector4(_seam_plane[b], _seam_plane[b + 1], _seam_plane[b + 2], _seam_plane[b + 3])
## The welded ring endpoints (world coords) — r0, r1.
static func seam_ring(fid: int, slot: int) -> Array:
	var b := fid * 24 + slot * 6
	return [Vector3(_seam_ring[b + 0], _seam_ring[b + 1], _seam_ring[b + 2]),
		Vector3(_seam_ring[b + 3], _seam_ring[b + 4], _seam_ring[b + 5])]
## The world ridge normal m̂ (points toward THIS facet's interior).
static func seam_mhat(fid: int, slot: int) -> Vector3:
	var b := fid * 12 + slot * 3
	return Vector3(_seam_mhat[b + 0], _seam_mhat[b + 1], _seam_mhat[b + 2])

## Signed own-side distance of the LATTICE POINT (x,y,z) to this facet's ridge plane `slot` (≥0 interior).
static func own_dist(fid: int, slot: int, x: float, y: float, z: float) -> float:
	var b := fid * 16 + slot * 4
	return _seam_plane[b] * x + _seam_plane[b + 1] * y + _seam_plane[b + 2] * z + _seam_plane[b + 3]

## Classify the unit CELL (integer x,y,z) against this facet's 4 ridge planes (§3.5.1). Returns
## {"air": bool, "straddle": PackedInt32Array of slots}. air ⇒ the cube lies wholly beyond some ridge (the FP2
## domain mask); empty straddle & not air ⇒ interior full cell; non-empty straddle ⇒ a junction cell clipped by
## those seams. Exact min/max over the 8 cube corners (the plane is affine, extrema are at corners).
static func cell_seam_state(fid: int, x: int, y: int, z: int) -> Dictionary:
	var straddle := PackedInt32Array()
	for slot in range(4):
		var b := fid * 16 + slot * 4
		var A := _seam_plane[b]; var B := _seam_plane[b + 1]; var C := _seam_plane[b + 2]
		var base := A * float(x) + B * float(y) + C * float(z) + _seam_plane[b + 3]
		var lo := base + minf(0.0, A) + minf(0.0, B) + minf(0.0, C)
		var hi := base + maxf(0.0, A) + maxf(0.0, B) + maxf(0.0, C)
		if hi <= SEAM_EPS:
			return {"air": true, "straddle": PackedInt32Array()}   # wholly beyond this ridge → masked
		if lo < -SEAM_EPS:
			straddle.append(slot)
	return {"air": false, "straddle": straddle}

## The clipped unit-cube vertex cloud (LOCAL cell coords u∈[0,1]³) for a junction cell = cube ∩ (own-side of
## every straddling ridge). A convex point set (ConvexPolygonShape3D hulls it; the mesher builds faces from the
## same clip). Empty if masked; the 8 corners if interior. Shared by render AND collision → identical geometry.
static func junction_prism_verts(fid: int, x: int, y: int, z: int) -> PackedVector3Array:
	var st := cell_seam_state(fid, x, y, z)
	if st["air"]:
		return PackedVector3Array()
	var slots: PackedInt32Array = st["straddle"]
	if slots.is_empty():
		var full := PackedVector3Array()
		for i in range(8):
			full.append(_cube_corner(i))
		return full
	# local planes: own_local(u) = A·ux + B·uy + C·uz + base ≥ 0, base = own_dist at the cell-origin corner
	var planes: Array = []
	for slot in slots:
		var b := fid * 16 + slot * 4
		var base := _seam_plane[b] * float(x) + _seam_plane[b + 1] * float(y) + _seam_plane[b + 2] * float(z) + _seam_plane[b + 3]
		planes.append([_seam_plane[b], _seam_plane[b + 1], _seam_plane[b + 2], base])
	return _clip_cube_points(planes)

static func _cube_corner(i: int) -> Vector3:
	return Vector3(float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1))

static func _own_local(pl: Array, u: Vector3) -> float:
	return pl[0] * u.x + pl[1] * u.y + pl[2] * u.z + pl[3]

static func _inside_all(planes: Array, u: Vector3, eps: float) -> bool:
	for pl in planes:
		if _own_local(pl, u) < -eps:
			return false
	return true

# The 12 edges of the unit cube as corner-index pairs (indices differ in exactly one bit).
const _CUBE_EDGES := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3], [2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]

# Vertices of the cube clipped to the intersection of the given half-spaces (own_local ≥ 0). Generous point
# collection — kept corners, edge∩plane crossings, and (for corner cells) face∩plane∩plane triple points — then
# filtered to the region; a convex hull downstream tidies duplicates. Exact for 1 plane, correct for ≤3.
static func _clip_cube_points(planes: Array) -> PackedVector3Array:
	var eps := 1.0e-6
	var pts := PackedVector3Array()
	for i in range(8):
		var u := _cube_corner(i)
		if _inside_all(planes, u, eps):
			pts.append(u)
	for e in _CUBE_EDGES:
		var u0 := _cube_corner(e[0]); var u1 := _cube_corner(e[1])
		for pl in planes:
			var f0 := _own_local(pl, u0); var f1 := _own_local(pl, u1)
			if (f0 < -eps and f1 > eps) or (f0 > eps and f1 < -eps):
				var t := f0 / (f0 - f1)
				var u := u0.lerp(u1, t)
				if _inside_all(planes, u, eps * 100.0):
					pts.append(u)
	# corner cells: triple points face∩plane_i∩plane_j (a cube face fixes one axis; solve the 2×2 in the rest)
	if planes.size() >= 2:
		for i in range(planes.size()):
			for j in range(i + 1, planes.size()):
				_face_plane_plane_points(planes[i], planes[j], planes, pts, eps)
	return pts

# For each of the 6 axis-aligned cube faces, solve the point satisfying both planes on that face; keep it if it
# lies in the unit square and inside every half-space. Covers the vertex where two ridge planes meet (corner cells).
static func _face_plane_plane_points(p: Array, q: Array, planes: Array, pts: PackedVector3Array, eps: float) -> void:
	for axis in range(3):
		for fixed in [0.0, 1.0]:
			# axis coord = fixed; the two free axes (a1,a2) solve [p,q] linear system
			var a1 := (axis + 1) % 3
			var a2 := (axis + 2) % 3
			var pa: float = p[a1]; var pb: float = p[a2]; var pc: float = p[axis] * fixed + p[3]
			var qa: float = q[a1]; var qb: float = q[a2]; var qc: float = q[axis] * fixed + q[3]
			var det: float = pa * qb - pb * qa
			if absf(det) < 1e-12:
				continue
			var s1: float = (-pc * qb + qc * pb) / det
			var s2: float = (-pa * qc + qa * pc) / det
			if s1 < -eps or s1 > 1.0 + eps or s2 < -eps or s2 > 1.0 + eps:
				continue
			var u := Vector3.ZERO
			u[axis] = fixed; u[a1] = clampf(s1, 0.0, 1.0); u[a2] = clampf(s2, 0.0, 1.0)
			if _inside_all(planes, u, eps * 100.0):
				pts.append(u)

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
