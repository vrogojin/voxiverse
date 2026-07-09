extends RefCounted
class_name CubeSphere
## COSMOS M0 — the cube-sphere math kernel (docs/COSMOS-PLANET-TOPOLOGY.md §1.2, §1.3,
## §4.2, §5.2/§5.3). Pure, deterministic f64 scalar math. NO engine dependencies, NO
## `randi()`/`Time` — every function is a pure function of its arguments.
##
## PRECISION NOTE (the load-bearing constraint): GDScript `float` is IEEE-754 f64 but
## `Vector3` is f32. Using `Vector3` for the direction math would FAIL the exact
## `cell -> dir -> cell` round-trip gate (§9 M0). All direction math therefore runs on the
## `DVec3` inner class below (three f64 fields) — NEVER `Vector3`. GDScript ints are 64-bit,
## so the 43-bit global edit key (§1.3) fits with room to spare.
##
## The two normative functions (§1.2) are `face_cell_to_dir` and `dir_to_face_cell`; the
## equal-angle warp is isolated behind `warp()`/`unwarp()` so a later distortion-tuning pass
## can swap it without touching topology, remap tables, or persistence (§1.2, §11.1).

# ---------------------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------------------

const QUARTER_PI := PI / 4.0

## The persistence region grid tiles each face 32^3 (ZoneChunk.SIZE); N is a multiple of 32
## so no region ever straddles a face (§1.1, §8.2).
const REGION_SIZE := 32

## Corner-zone constants (§5.3) — carried here so later milestones (M5) read them from the
## single kernel source. `CORNER_SEA_R`: worldgen forces deep ocean within this many cells of
## a cube corner; `CORNER_LOCK_R`: edits are refused within this many cells of a corner column.
const CORNER_SEA_R := 48
const CORNER_LOCK_R := 8

## 1/sqrt(3): the |z| of every cube corner direction; asin(1/sqrt3) = 35.264 deg is the
## latitude the 8 corners are parked at with the poles-on-face-centres orientation (§5.2).
const INV_SQRT3 := 0.5773502691896258

# Per-face local axes (§1.1). Faces are numbered by outward normal in the body-fixed frame:
# 0:+X 1:-X 2:+Y 3:-Y 4:+Z 5:-Z, with +Z = spin axis (north). Faces 4/5 are polar (face
# centres at the poles, §5.2); faces 0-3 tile the equatorial belt. Stored as integer axis
# triples (each is +/- a unit axis) so the reflection generator below stays exact-integer.
const FACE_N := [
	[ 1, 0, 0], [-1, 0, 0], [ 0, 1, 0], [ 0,-1, 0], [ 0, 0, 1], [ 0, 0,-1],
]  # n^  (outward normal)
const FACE_U := [
	[ 0, 1, 0], [ 0,-1, 0], [-1, 0, 0], [ 1, 0, 0], [ 0, 1, 0], [ 0, 1, 0],
]  # u^  (i axis)
const FACE_V := [
	[ 0, 0, 1], [ 0, 0, 1], [ 0, 0, 1], [ 0, 0, 1], [-1, 0, 0], [ 1, 0, 0],
]  # v^  (j axis)

# COSMOS frozen-epoch / F4 (docs/COSMOS-AUDIT.md §3.2 item 1): container-FREE axis accessors for the
# worker hot path. Indexing the nested `const` Arrays above (`FACE_N[face]` → an inner Array) increments
# that inner Array's copy-on-write refcount, and CONCURRENT `_ref` from the voxel worker pool + the main
# thread corrupts it (Godot array.cpp:61 "!success") → "Out of bounds get index" → the worker crash /
# vox_blocks=0. The flat path never hit this because its const-array reads return INTS (no inner
# refcount). These match-of-literals return a Vector3i VALUE (no container, no refcount), so every
# concurrent direction sample is lock-free by construction. The nested FACE_* consts stay for the
# main-thread-only setup (_gen_edge / corner tables), which never races the worker.
static func _axis_n(face: int) -> Vector3i:
	match face:
		0: return Vector3i(1, 0, 0)
		1: return Vector3i(-1, 0, 0)
		2: return Vector3i(0, 1, 0)
		3: return Vector3i(0, -1, 0)
		4: return Vector3i(0, 0, 1)
		_: return Vector3i(0, 0, -1)

static func _axis_u(face: int) -> Vector3i:
	match face:
		0: return Vector3i(0, 1, 0)
		1: return Vector3i(0, -1, 0)
		2: return Vector3i(-1, 0, 0)
		3: return Vector3i(1, 0, 0)
		_: return Vector3i(0, 1, 0)

static func _axis_v(face: int) -> Vector3i:
	match face:
		4: return Vector3i(-1, 0, 0)
		5: return Vector3i(1, 0, 0)
		_: return Vector3i(0, 0, 1)

# Side ids for the edge-remap tables (§4.2). A "side" is the face edge the window can spill
# across: EAST = past i=N-1 (a=+1), WEST = past i=0 (a=-1), NORTH = past j=N-1 (b=+1),
# SOUTH = past j=0 (b=-1).
const SIDE_EAST := 0   # +i
const SIDE_WEST := 1   # -i
const SIDE_NORTH := 2  # +j
const SIDE_SOUTH := 3  # -j

# Per-body N (cells per face edge) and datum radius R in blocks (§1.1 table). N is 32-aligned.
const BODY_N := {
	"earth": 10016,   # = 313 * 32
	"mars": 5312,
	"mercury": 3840,
	"moon": 2720,
}
const BODY_R := {
	"earth": 6371,
	"mars": 3390,
	"mercury": 2440,
	"moon": 1737,
}

# ---------------------------------------------------------------------------------------
# COSMOS M1 — the single, easily-flippable planet toggle (docs/COSMOS-PLANET-TOPOLOGY.md §9 M1,
# §3.5, §3.4, §6.1). THIS is the whole safety net: when FLAT_WORLD is true (the default) the
# engine is BYTE-IDENTICAL to the pre-M1 flat world — the terrain adapter is the identity, the
# §3.4 render bend is off, and gravity is the fixed-down stub. Flip it to false to enable the
# curved face-4 window: 3D-noise worldgen sampled along d̂, the camera-centred exact-sphere
# vertex bend (sea horizon at ~147 blocks), and the real toward-centre gravity field.
#
# TO BUILD A CURVED DEMO: change the one line below to `const FLAT_WORLD := false`.
const FLAT_WORLD := true

## COSMOS M5a (docs/COSMOS-M5-ADR.md §2): the TRUE-POSITION render toggle. DEFAULT false → the shipped
## camera-centred CosmosBend sagitta is used (byte-identical to M4). Flip to true to place every vertex at
## its exact sphere position P = (R+y)·d̂ via CosmosTruePlace (kills the §4.6 metric-lie shear everywhere —
## home + strips + corner, via the corner-closure theorem, from the SAME single near volume). A/B-able
## live; requires FLAT_WORLD = false (curved). FLAT_WORLD untouched by M5.
const M5_RENDER := false

## COSMOS R1 (docs/COSMOS-REAL-GEOMETRY-STUDY §8): the REAL-BAKED-GEOMETRY toggle — "the inflated rubber
## cube". DEFAULT false → the shipped CosmosBend shader path (byte-identical to M4). Flip to true to bake
## the FAR layer (+ later water/debris) at TRUE sphere positions on the CPU via CosmosTruePlace.place_true
## (per-tile local origin), cull the far wedge tiles, and level the render with a rigid alignment-root
## transform — NO custom shader crosses the GPU boundary (the class that broke M5a twice). Supersedes the
## M5a placement shader (M5_RENDER); the two are mutually exclusive (M5_REAL wins). Requires FLAT_WORLD =
## false (curved). Bake-parity is a headless gate (baked vertex == place_true == world_point).
const M5_REAL := false

## The cube face the M1 window is homed on (§3.5: "flat world reinterpreted as a face-4 window").
## Face 4 is +Z polar (a pole on the face centre, §5.2) so the window is defect-free lattice.
const HOME_FACE := 4

## The body the M1 window lives on (§1.1 table). Earth: N=10016, R=6371.
const HOME_BODY := "earth"

## Datum surface gravity in m/s² (§6.1). The standard-gravity anchor used to derive GM = g0·R²
## so the field is exactly g0 at the datum (r = 0) and falls off as 1/r² above it.
const SURFACE_GRAVITY := 9.81

## GM (gravitational parameter, in block·m²/s² bookkeeping units) for a body: g0·R² so that
## |gravity| = GM/(R+r)² equals SURFACE_GRAVITY exactly at the datum r = 0 (§6.1).
static func gm_for(body: String) -> float:
	var rr := float(radius_for(body))
	return SURFACE_GRAVITY * rr * rr

# Edge-remap table cache, keyed by N (the affine offsets scale with N). Built on first use.
# ONLY used for a FOREIGN n (a non-home body in a verify/test): the runtime home-body table lives in
# the FROZEN flat array below, which is the lock-free, allocation-free source the voxel worker reads.
static var _edge_cache: Dictionary = {}

# COSMOS frozen-epoch contract (docs/COSMOS-AUDIT.md §3.2 item 1): the home-body edge-remap table,
# built ONCE on the main thread in warm_edge_tables() BEFORE any voxel worker spawns and NEVER
# mutated again. A FLAT PackedInt32Array (24 entries × 7 ints: b, m00, m01, m10, m11, t0, t1) instead
# of the Dictionary-of-Array-of-Dictionary form, so every concurrent worker fold is a pure read of a
# frozen Packed array — lock-free and allocation-free by construction (Godot documents reads of a
# never-written Packed array as thread-safe). This subsumes the pass-1 prewarm AND removes the nested
# container as a memory-corruption candidate (COSMOS-AUDIT §2 #4 / F4). Empty until warm_edge_tables().
const _EDGE_STRIDE := 7                   # ints per (face, side) entry in the flat table
static var _edge_flat: PackedInt32Array = PackedInt32Array()
static var _edge_flat_n := 0             # the n `_edge_flat` was built for (0 = not built)
static var _edge_frozen := false         # true once warm_edge_tables() has published `_edge_flat`

# ---------------------------------------------------------------------------------------
# DVec3 — a minimal three-f64 vector. Deliberately NOT Vector3 (which is f32); the exact
# round-trip gate depends on f64 all the way through the direction math.
# ---------------------------------------------------------------------------------------
class DVec3:
	var x: float
	var y: float
	var z: float

	func _init(px := 0.0, py := 0.0, pz := 0.0) -> void:
		x = px
		y = py
		z = pz

	func length() -> float:
		return sqrt(x * x + y * y + z * z)

	func normalized() -> DVec3:
		var l := length()
		if l == 0.0:
			return DVec3.new()
		return DVec3.new(x / l, y / l, z / l)

	func dot(o: DVec3) -> float:
		return x * o.x + y * o.y + z * o.z

	## Angular distance (radians) to another (assumed unit) direction. Uses acos of the
	## clamped dot — good enough for the "are these two cells one apart?" adjacency check.
	func angle_to(o: DVec3) -> float:
		return acos(clampf(dot(o), -1.0, 1.0))

# ---------------------------------------------------------------------------------------
# The warp (§2). Isolated so it can be swapped later without touching topology/tables.
# ---------------------------------------------------------------------------------------

## The equal-angle (tangent) warp: face parameter a in [-1,1] -> plane coordinate u.
static func warp(a: float) -> float:
	return tan(a * QUARTER_PI)

## Exact inverse of warp() in f64 (tan/atan are inverses to < 1 ULP).
static func unwarp(u: float) -> float:
	return atan(u) / QUARTER_PI

# ---------------------------------------------------------------------------------------
# The two normative functions (§1.2)
# ---------------------------------------------------------------------------------------

## face/cell -> unit direction in the body-fixed frame (f64 scalar math, §1.2). `fi`/`fj`
## are floats so callers can request off-cell or off-face points, but for a lattice cell
## pass the integer indices.
static func face_cell_to_dir(face: int, fi: float, fj: float, n: int) -> DVec3:
	var a := 2.0 * (fi + 0.5) / float(n) - 1.0   # [-1, 1] across the face
	var b := 2.0 * (fj + 0.5) / float(n) - 1.0
	var u := warp(a)                             # THE warp (equal-angle, §2)
	var v := warp(b)
	var nn := _axis_n(face)   # container-free (F4): Vector3i value, no inner-Array refcount race
	var uu := _axis_u(face)
	var vv := _axis_v(face)
	var d := DVec3.new(
		float(nn.x) + u * float(uu.x) + v * float(vv.x),
		float(nn.y) + u * float(uu.y) + v * float(vv.y),
		float(nn.z) + u * float(uu.z) + v * float(vv.z),
	)
	# Normalize IN PLACE (F4): avoid the extra DVec3 `.normalized()` allocates — one fewer RefCounted per
	# column on the worker hot path. Value-identical (same f64 x/l arithmetic).
	var l := d.length()
	if l != 0.0:
		d.x /= l
		d.y /= l
		d.z /= l
	return d

## unit direction -> {face, fi, fj} (§1.2). face = argmax|component|; the warp is inverted
## per axis. Because it recovers u,v as ratios dot(d,u^)/dot(d,n^) and dot(d,v^)/dot(d,n^),
## the normalization factor cancels exactly — this is what makes the round-trip robust.
static func dir_to_face_cell(d: DVec3, n: int) -> Dictionary:
	var face := face_of_dir(d)
	var nn := _axis_n(face)   # container-free (F4)
	var uu := _axis_u(face)
	var vv := _axis_v(face)
	var nc := d.x * float(nn.x) + d.y * float(nn.y) + d.z * float(nn.z)  # dot(d, n^) = 1/L > 0
	var uc := d.x * float(uu.x) + d.y * float(uu.y) + d.z * float(uu.z)  # dot(d, u^) = u/L
	var vc := d.x * float(vv.x) + d.y * float(vv.y) + d.z * float(vv.z)  # dot(d, v^) = v/L
	var u := uc / nc
	var v := vc / nc
	var a := unwarp(u)
	var b := unwarp(v)
	var fi := roundi((a + 1.0) * float(n) * 0.5 - 0.5)
	var fj := roundi((b + 1.0) * float(n) * 0.5 - 0.5)
	return {"face": face, "fi": fi, "fj": fj}

## Continuous (un-rounded) inverse — used by the round-trip test to measure the precision
## margin (how far the recovered float lands from the integer, and thus from the rounding
## boundary). Returns {face, fa, fb} as floats.
static func dir_to_face_cell_f(d: DVec3, n: int) -> Dictionary:
	var face := face_of_dir(d)
	var nn := _axis_n(face)   # container-free (F4)
	var uu := _axis_u(face)
	var vv := _axis_v(face)
	var nc := d.x * float(nn.x) + d.y * float(nn.y) + d.z * float(nn.z)
	var uc := d.x * float(uu.x) + d.y * float(uu.y) + d.z * float(uu.z)
	var vc := d.x * float(vv.x) + d.y * float(vv.y) + d.z * float(vv.z)
	var a := unwarp(uc / nc)
	var b := unwarp(vc / nc)
	return {
		"face": face,
		"fa": (a + 1.0) * float(n) * 0.5 - 0.5,
		"fb": (b + 1.0) * float(n) * 0.5 - 0.5,
	}

## face = argmax|component|, with the sign of the dominant component selecting which of the
## two faces on that axis. Cell centres never lie exactly on an edge/corner (a = (2*fi+1)/N - 1
## is never +/-1 for integer fi), so this is unambiguous for every real cell.
static func face_of_dir(d: DVec3) -> int:
	var ax := absf(d.x)
	var ay := absf(d.y)
	var az := absf(d.z)
	if ax >= ay and ax >= az:
		return 0 if d.x > 0.0 else 1
	elif ay >= az:
		return 2 if d.y > 0.0 else 3
	else:
		return 4 if d.z > 0.0 else 5

## World-space point of a lattice cell (§1.2): P = (R + r) * face_cell_to_dir(...).
static func world_point(face: int, fi: float, fj: float, r: float, radius: float, n: int) -> DVec3:
	var d := face_cell_to_dir(face, fi, fj, n)
	var s := radius + r
	return DVec3.new(d.x * s, d.y * s, d.z * s)

# ---------------------------------------------------------------------------------------
# The global edit key (§1.3): key = face<<40 | i<<26 | j<<12 | (r+2048)
#   3 bits face | 14 bits i | 14 bits j | 12 bits (r+2048)   -> 43 bits, fits int64.
# 14 bits holds N <= 16384 (Earth's 10016 fits); 12 bits holds r in [-2048, +2047].
# ---------------------------------------------------------------------------------------

static func edit_key(face: int, i: int, j: int, r: int) -> int:
	return (face << 40) | (i << 26) | (j << 12) | (r + 2048)

static func key_face(key: int) -> int:
	return (key >> 40) & 0x7

static func key_i(key: int) -> int:
	return (key >> 26) & 0x3FFF

static func key_j(key: int) -> int:
	return (key >> 12) & 0x3FFF

static func key_r(key: int) -> int:
	return (key & 0xFFF) - 2048

static func unpack_key(key: int) -> Dictionary:
	return {"face": key_face(key), "i": key_i(key), "j": key_j(key), "r": key_r(key)}

## The region-key prefix (§1.3): the same layout over region indices (i>>5, j>>5, r/32).
## Every cell in one 32^3 region shares this key; adjacent regions differ. Used to extend
## `region_origin_of` and the ZoneChunk/ZoneBundle stores to (body, face, region_i/j/r).
static func region_key(face: int, i: int, j: int, r: int) -> int:
	var ri := i >> 5
	var rj := j >> 5
	var rr := _floordiv(r, REGION_SIZE)      # floor division, correct for negative r
	return (face << 40) | (ri << 26) | (rj << 12) | (rr + 2048)

# ---------------------------------------------------------------------------------------
# Edge-remap tables (§4.2) — GENERATED at first use from the §1.1 axis table, then cached.
#
# The remap is the RIGID unfold of the extended window (§4.3), NOT the gnomonic
# classification of off-edge cells. Off-edge, a "straight" index line kinks in ground truth
# (§4.6); the design keeps INDICES exact by using an exact D4 (dihedral) index map + integer
# offset, absorbing the kink as a ground-truth metric lie. Generation:
#
#   1. mirror map A->B: the cube reflection R that swaps the two face normals maps A's
#      equal-angle grid onto B's exactly (R is a cube symmetry, so it preserves the whole
#      construction). Sampling three interior cells and classifying R*dir recovers the exact
#      integer affine map {M_mirror, t_mirror} (A's cell <-> its across-edge mirror in B).
#   2. compose with the side's in-range reflection so an OUT-of-range window cell folds to the
#      correct B cell: unfold = mirror . reflect_side.
#
# Each entry: {b:int, m:[m00,m01,m10,m11], t:[t0,t1]} with (i',j') = M*(i,j) + t, r untouched.
# ---------------------------------------------------------------------------------------

## Returns the remap entry for crossing `side` of `face` (Dictionary {b, m, t}) for a given N. Reads
## the FROZEN flat table for the home body (lock-free); a foreign n falls back to the Dictionary cache
## (main-thread verify only — the voxel worker only ever folds at the home-body n).
static func edge_remap(face: int, side: int, n: int) -> Dictionary:
	if n == _edge_flat_n and _edge_flat.size() == 24 * _EDGE_STRIDE:
		var b := (face * 4 + side) * _EDGE_STRIDE
		return {
			"b": _edge_flat[b],
			"m": [_edge_flat[b + 1], _edge_flat[b + 2], _edge_flat[b + 3], _edge_flat[b + 4]],
			"t": [_edge_flat[b + 5], _edge_flat[b + 6]],
		}
	_ensure_edge_table(n)
	return _edge_cache[n][face * 4 + side]

# --- D4 orientation indices (COSMOS-FRAME-ORIENTATION §5.1/§6) -------------------------------------
## The quarter-turn index (0..3) of a C4 rotation matrix `m` = [a,b,c,d] (row-major, det +1): the
## angle atan2(m[2], m[0]) measured in +90° units. Used to express M_win / M_strip / the fold Jacobian
## J as small ints (C4 is abelian, so composing rotations is d4 addition mod 4). d4=1 is +90° — the
## same convention ShapeCodec.rotate_modifier uses.
static func d4_of(m: Array) -> int:
	var q := int(round(atan2(float(m[2]), float(m[0])) / (PI / 2.0)))
	return ((q % 4) + 4) % 4

## The strip fold's D4 quarter-turn taking `from_face`'s lattice → `to_face`'s across their shared edge
## (COSMOS-FRAME-ORIENTATION §6.6 / §5.4). 0 when to_face == from_face (native cell, or a corner wedge
## the canonical fold clamped back onto the home face). Otherwise it is the D4 of the (unique) edge of
## `from_face` whose remap lands on `to_face` — so a single-edge fold and a corner-wedge cell both get
## their strip D4 from the face the fold ACTUALLY RESOLVED to. Total + deterministic on the 24-edge graph.
static func strip_d4_to(from_face: int, to_face: int, n: int) -> int:
	if to_face == from_face or from_face < 0 or to_face < 0:
		return 0
	for side in 4:
		var e := edge_remap(from_face, side, n)
		if int(e["b"]) == to_face:
			return d4_of(e["m"])
	# Not edge-adjacent — must never happen within the extended window (the resolved face is always a
	# direct neighbour of the home face). Warn loudly instead of silently returning 0 (a wrong orientation).
	push_warning("CubeSphere.strip_d4_to: face %d is not edge-adjacent to home %d — returning identity (unexpected)" % [to_face, from_face])
	return 0

## Fold a window cell that has spilled across exactly ONE face edge back to its true global
## (face, i, j). Returns {face, i, j}. In-range cells are the identity. A cell out of range in
## BOTH i and j is a corner quadrant (§5.3) — undefined here (handled at M5); this returns
## {face:-1,...} for that case so callers can detect it.
static func fold_cell(face: int, i: int, j: int, n: int) -> Dictionary:
	var oi := i < 0 or i >= n
	var oj := j < 0 or j >= n
	if not oi and not oj:
		return {"face": face, "i": i, "j": j}
	if oi and oj:
		return {"face": -1, "i": i, "j": j}   # corner quadrant, §5.3 (M5)
	var side := -1
	if i >= n:
		side = SIDE_EAST
	elif i < 0:
		side = SIDE_WEST
	elif j >= n:
		side = SIDE_NORTH
	else:
		side = SIDE_SOUTH
	# Frozen-table fast path (the voxel-worker fold, COSMOS-AUDIT §3.2 item 1): read the affine map
	# straight out of the flat PackedInt32Array by index — no Dictionary/Array allocation, lock-free.
	if n == _edge_flat_n and _edge_flat.size() == 24 * _EDGE_STRIDE:
		var b := (face * 4 + side) * _EDGE_STRIDE
		return {
			"face": _edge_flat[b],
			"i": _edge_flat[b + 1] * i + _edge_flat[b + 2] * j + _edge_flat[b + 5],
			"j": _edge_flat[b + 3] * i + _edge_flat[b + 4] * j + _edge_flat[b + 6],
		}
	var e := edge_remap(face, side, n)
	var m: Array = e["m"]
	var t: Array = e["t"]
	return {
		"face": int(e["b"]),
		"i": m[0] * i + m[1] * j + t[0],
		"j": m[2] * i + m[3] * j + t[1],
	}

# COSMOS-CORNER-CANONICAL (task #69, docs/COSMOS-CORNER-CANONICAL.md): the F8 `oob_seen` fence. Counts ONLY
# a REAL out-of-range — the gnomonic-wrap branch |a| ≥ 2, which never occurs in practice (R_FAR → |a| ≤
# 1.62): a real out-of-range must NEVER pass silently, so verify asserts this stays zero. Because it never
# fires in practice it is never written on the worker path → no worker-written-static race (the audit
# discipline). NOTE (Opus deviation, flagged to team-lead): doc §2.3 also wanted the boundary CLAMP counted
# on this fence, but §7c1 expects the fence zero over the sweep — contradictory, since the a=±1 boundary
# clamp fires routinely on the exact wedge diagonal an integer lattice hits (and, being on the worker hot
# path, a counter for it would be a worker-written static). The clamp is the INTENDED nearest-edge
# projection (not an anomaly), so it is applied silently and NOT counted; the fence keeps its stated
# meaning. c1's fence-zero then holds; c1 separately asserts every fold lands in-range (the clamp working).
static var _corner_fence := 0
static func corner_fence_seen() -> int:
	return _corner_fence
static func reset_corner_fence() -> void:
	_corner_fence = 0

## COSMOS-CORNER-CANONICAL (#69): the CONTENT/key fold. Like `fold_cell`, but the corner quadrant (out of
## range in BOTH axes — which `fold_cell` refuses with face −1, having no single-edge D4 fold) resolves to
## the nearest TRUE global cell of its physical DIRECTION rather than the raw home-face overshoot. In-range
## → identity; single-out → the exact `fold_cell` D4 branch (delegated); double-out → canonicalise by
## POSITION: take the raw gnomonic overshoot direction d̂ = face_cell_to_dir(face, i, j) (UNCHANGED —
## placement/the §4.6 metric lie is out of scope) and project it to its nearest real cell via
## `dir_to_face_cell` (the M0 inverse), clamping i',j' to [0, n−1]. NEVER returns face −1 — every physical
## direction has a nearest real cell. This makes the wedge's COLUMN IDENTITY a pure function of position
## (no home-face argument), so the whole F2-folded feature stack downstream (trees/ore/strata/bedrock/
## smoothing/snow) is home-face-INDEPENDENT → §8.2 restored (docs/COSMOS-CORNER-CANONICAL §2). Pure f64 +
## frozen tables → worker-safe under the frozen-epoch contract; runs ONLY for double-out columns (corner-
## overlapping blocks; zero cost everywhere else). `fold_cell` itself is UNTOUCHED — the −1 sentinel still
## marks the topological "no D4 fold" where refusal is wanted (e.g. `chart.flip`'s corner guard).
static func fold_cell_canonical(face: int, i: int, j: int, n: int) -> Dictionary:
	var oi := i < 0 or i >= n
	var oj := j < 0 or j >= n
	if not oi and not oj:
		return {"face": face, "i": i, "j": j}            # in range → identity (the >99.9% fast path)
	if not (oi and oj):
		return fold_cell(face, i, j, n)                  # single-out → the exact D4 edge fold
	# Double-out (corner quadrant): canonicalise by physical position (§2.1).
	var a := 2.0 * (float(i) + 0.5) / float(n) - 1.0     # face overshoot params (mirror face_cell_to_dir)
	var b := 2.0 * (float(j) + 0.5) / float(n) - 1.0
	if absf(a) >= 2.0 or absf(b) >= 2.0:
		_corner_fence += 1                               # REAL out-of-range: gnomonic wrap — never in practice
	var d := face_cell_to_dir(face, float(i), float(j), n)   # the raw overshoot direction — UNCHANGED
	var c := dir_to_face_cell(d, n)                           # nearest TRUE global cell (M0 inverse)
	var ci := int(c["fi"])
	var cj := int(c["fj"])
	# Clamp the a=±1 boundary (roundi can give n on a neighbour's own edge) to the nearest in-range cell —
	# the intended nearest-cell projection, applied silently (see the fence note above; not counted).
	return {"face": int(c["face"]), "i": clampi(ci, 0, n - 1), "j": clampi(cj, 0, n - 1)}

## Inverse of the edge unfold: given the HOME face and a TRUE global column `(gface, gi, gj)`
## on a NEIGHBOUR face, recover the out-of-range home-face window column `(i, j)` that folds to
## it — the reverse of `fold_cell` for the single-edge strips (§4.3). Returns {found, i, j}. Used
## to place a neighbour-face edit back into the extended window (render/collider) and by the
## home-face flip. Only the 4 direct edges of `home_face` are checked (single-axis strips); a
## corner quadrant (double cover, §5.3 M5) returns found=false. The D4 map has det ±1, so its
## integer inverse is exact.
static func unfold_to_window(home_face: int, gface: int, gi: int, gj: int, n: int) -> Dictionary:
	if gface == home_face:
		return {"found": true, "i": gi, "j": gj}
	for side in range(4):
		var e := edge_remap(home_face, side, n)
		if int(e["b"]) != gface:
			continue
		var m: Array = e["m"]
		var t: Array = e["t"]
		var inv := invert_affine(m, t)
		var im: Array = inv["m"]
		var it: Array = inv["t"]
		var wi: int = im[0] * gi + im[1] * gj + it[0]
		var wj: int = im[2] * gi + im[3] * gj + it[1]
		# Only accept if the recovered window cell is genuinely in THIS side's out-of-range strip
		# (so an ambiguous corner cell reachable from two sides is not mis-claimed).
		var ok := false
		match side:
			SIDE_EAST:  ok = wi >= n and wj >= 0 and wj < n
			SIDE_WEST:  ok = wi < 0 and wj >= 0 and wj < n
			SIDE_NORTH: ok = wj >= n and wi >= 0 and wi < n
			_:          ok = wj < 0 and wi >= 0 and wi < n
		if ok:
			return {"found": true, "i": wi, "j": wj}
	return {"found": false, "i": 0, "j": 0}

## Inverse of a 2D integer affine map {m:[a,b,c,d], t:[t0,t1]} with det(m) = ±1 (a D4 element):
## if (gi,gj) = M·(i,j)+t then (i,j) = M⁻¹·((gi,gj)−t). Exact integers (M⁻¹ = det·adj(M)).
static func invert_affine(m: Array, t: Array) -> Dictionary:
	var a: int = m[0]; var b: int = m[1]; var c: int = m[2]; var d: int = m[3]
	var t0: int = t[0]; var t1: int = t[1]
	var det: int = a * d - b * c                 # ±1 for a D4 element
	# For det = ±1, 1/det == det, so M⁻¹ = det · [[d, −b], [−c, a]] is exact-integer.
	var im: Array = [det * d, -det * b, -det * c, det * a]
	var it: Array = [-(im[0] * t0 + im[1] * t1), -(im[2] * t0 + im[3] * t1)]
	return {"m": im, "t": it}

static func _ensure_edge_table(n: int) -> void:
	if _edge_cache.has(n):
		return
	var table: Array = []
	table.resize(24)
	for face in range(6):
		for side in range(4):
			table[face * 4 + side] = _gen_edge(face, side, n)
	_edge_cache[n] = table

## COSMOS frozen-epoch contract (docs/COSMOS-AUDIT.md §3.2 item 1): build the edge-remap table for
## `n` ONCE on the MAIN thread and FREEZE it into the flat `_edge_flat` PackedInt32Array, BEFORE any
## voxel worker exists. Every subsequent fold (worker or main) is then a pure lock-free READ of a
## never-mutated Packed array — no lazy build, no nested Dictionary/Array container to corrupt (the
## pass-1 crash class AND the F4 corruption candidate are both structurally removed). Called from
## TerrainConfig.warm_up() in module setup(), before the generator/viewer attaches. Idempotent (a
## no-op once frozen for this n). FLAT_WORLD never folds, so it need not (and does not) call this.
static func warm_edge_tables(n: int) -> void:
	if _edge_frozen and _edge_flat_n == n:
		return
	var flat := PackedInt32Array()
	flat.resize(24 * _EDGE_STRIDE)
	for face in range(6):
		for side in range(4):
			var e := _gen_edge(face, side, n)
			var m: Array = e["m"]
			var t: Array = e["t"]
			var b := (face * 4 + side) * _EDGE_STRIDE
			flat[b] = int(e["b"])
			flat[b + 1] = int(m[0]); flat[b + 2] = int(m[1])
			flat[b + 3] = int(m[2]); flat[b + 4] = int(m[3])
			flat[b + 5] = int(t[0]); flat[b + 6] = int(t[1])
	# Publish the fully-built table, then set the guards LAST so no reader ever sees a half-built
	# array (a reader checks `_edge_flat_n` / size before indexing). After this the array is const.
	_edge_flat = flat
	_edge_flat_n = n
	_edge_frozen = true

## Generate one {b, m, t} unfold entry for (face, side) at resolution n.
static func _gen_edge(face: int, side: int, n: int) -> Dictionary:
	# Exit axis (the neighbour's outward normal): the axis you head toward crossing this side.
	var uu: Array = FACE_U[face]
	var vv: Array = FACE_V[face]
	var exit_axis: Array
	match side:
		SIDE_EAST:  exit_axis = uu                     # +u^
		SIDE_WEST:  exit_axis = [-uu[0], -uu[1], -uu[2]]  # -u^
		SIDE_NORTH: exit_axis = vv                     # +v^
		_:          exit_axis = [-vv[0], -vv[1], -vv[2]]  # -v^ (SOUTH)
	var b := _face_of_axis(exit_axis)

	# The cube reflection R that swaps n^_A <-> n^_B: R = I - w w^T with w = n_A - n_B
	# (|w|^2 = 2 for orthogonal unit axes, so the factor 2/|w|^2 = 1 and R is exact-integer).
	var na: Array = FACE_N[face]
	var nb: Array = FACE_N[b]
	var w := [na[0] - nb[0], na[1] - nb[1], na[2] - nb[2]]
	var rmat := _reflection_matrix(w)

	# mirror map A->B: sample three interior cells, classify R*dir, read off the affine map.
	var half := n / 2
	var q0 := _classify_reflected(face, half, half, rmat, n)
	var qi := _classify_reflected(face, half + 1, half, rmat, n)
	var qj := _classify_reflected(face, half, half + 1, rmat, n)
	# columns of M_mirror are the images of the i- and j- unit steps.
	var mm := [
		int(qi["fi"]) - int(q0["fi"]), int(qj["fi"]) - int(q0["fi"]),
		int(qi["fj"]) - int(q0["fj"]), int(qj["fj"]) - int(q0["fj"]),
	]
	var tm := [
		int(q0["fi"]) - (mm[0] * half + mm[1] * half),
		int(q0["fj"]) - (mm[2] * half + mm[3] * half),
	]

	# side reflection (folds the out-of-range coordinate back in range before the mirror):
	#   EAST  (i>=N): i -> 2N-1-i        WEST  (i<0): i -> -1-i
	#   NORTH (j>=N): j -> 2N-1-j        SOUTH (j<0): j -> -1-j
	var mr: Array
	var tr: Array
	match side:
		SIDE_EAST:  mr = [-1, 0, 0, 1]; tr = [2 * n - 1, 0]
		SIDE_WEST:  mr = [-1, 0, 0, 1]; tr = [-1, 0]
		SIDE_NORTH: mr = [1, 0, 0, -1]; tr = [0, 2 * n - 1]
		_:          mr = [1, 0, 0, -1]; tr = [0, -1]

	# unfold = mirror . reflect_side  (apply the side reflection first, then the mirror).
	var comp := _compose(mm, tm, mr, tr)
	return {"b": b, "m": comp["m"], "t": comp["t"]}

## Classify R*face_cell_to_dir(face, i, j) -> {face, fi, fj} (exact integer, cells interior).
static func _classify_reflected(face: int, i: int, j: int, rmat: Array, n: int) -> Dictionary:
	var d := face_cell_to_dir(face, i, j, n)
	var rd := DVec3.new(
		rmat[0] * d.x + rmat[1] * d.y + rmat[2] * d.z,
		rmat[3] * d.x + rmat[4] * d.y + rmat[5] * d.z,
		rmat[6] * d.x + rmat[7] * d.y + rmat[8] * d.z,
	)
	return dir_to_face_cell(rd, n)

## R = I - w w^T for integer axis vector w with |w|^2 = 2. Row-major 3x3 flat array.
static func _reflection_matrix(w: Array) -> Array:
	var m := []
	m.resize(9)
	for p in range(3):
		for q in range(3):
			var iden := 1 if p == q else 0
			m[p * 3 + q] = iden - w[p] * w[q]
	return m

## Compose two 2D affine maps: result = A . B  (apply B first, then A).
static func _compose(am: Array, at: Array, bm: Array, bt: Array) -> Dictionary:
	var m := [
		am[0] * bm[0] + am[1] * bm[2], am[0] * bm[1] + am[1] * bm[3],
		am[2] * bm[0] + am[3] * bm[2], am[2] * bm[1] + am[3] * bm[3],
	]
	var t := [
		am[0] * bt[0] + am[1] * bt[1] + at[0],
		am[2] * bt[0] + am[3] * bt[1] + at[1],
	]
	return {"m": m, "t": t}

## Face index whose outward normal is the given axis vector (+/- unit axis).
static func _face_of_axis(axis: Array) -> int:
	for f in range(6):
		var nn: Array = FACE_N[f]
		if nn[0] == axis[0] and nn[1] == axis[1] and nn[2] == axis[2]:
			return f
	return -1

# ---------------------------------------------------------------------------------------
# Corner tables (§5.2 / §5.3): the 8 valence-3 cube corners.
# ---------------------------------------------------------------------------------------

## Signs of the 8 cube corner directions (sx, sy, sz), each direction = (sx,sy,sz)/sqrt(3).
const CORNER_SIGNS := [
	[ 1, 1, 1], [ 1, 1,-1], [ 1,-1, 1], [ 1,-1,-1],
	[-1, 1, 1], [-1, 1,-1], [-1,-1, 1], [-1,-1,-1],
]

## Unit direction to cube corner k (0..7).
static func corner_dir(k: int) -> DVec3:
	var s: Array = CORNER_SIGNS[k]
	return DVec3.new(float(s[0]) * INV_SQRT3, float(s[1]) * INV_SQRT3, float(s[2]) * INV_SQRT3)

## The 3 faces meeting at corner k, and each face's corner cell (i, j) at that corner, for a
## given N. Returns an Array of 3 dicts {face, i, j}. A corner cell's i is N-1 where the
## corner direction has a positive projection on that face's u^, else 0 (likewise j for v^).
static func corner_cells(k: int, n: int) -> Array:
	var s: Array = CORNER_SIGNS[k]
	var faces := [
		0 if s[0] > 0 else 1,   # the X face
		2 if s[1] > 0 else 3,   # the Y face
		4 if s[2] > 0 else 5,   # the Z face
	]
	var out: Array = []
	for f in faces:
		var uu: Array = FACE_U[f]
		var vv: Array = FACE_V[f]
		var du: int = s[0] * uu[0] + s[1] * uu[1] + s[2] * uu[2]   # sign of corner . u^
		var dv: int = s[0] * vv[0] + s[1] * vv[1] + s[2] * vv[2]   # sign of corner . v^
		out.append({
			"face": f,
			"i": (n - 1) if du > 0 else 0,
			"j": (n - 1) if dv > 0 else 0,
		})
	return out

# ---------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------

## Floor division of integers (GDScript `/` truncates toward zero; this floors for negatives).
static func _floordiv(a: int, b: int) -> int:
	var q := a / b
	if (a % b != 0) and ((a < 0) != (b < 0)):
		q -= 1
	return q

static func n_for(body: String) -> int:
	return int(BODY_N.get(body, 0))

static func radius_for(body: String) -> int:
	return int(BODY_R.get(body, 0))
