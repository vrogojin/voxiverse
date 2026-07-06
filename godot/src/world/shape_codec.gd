class_name ShapeCodec
extends RefCounted
## Static, pure sub-voxel SHAPE math for the modifier axis (VOXEL-DATA-STRUCTURE
## §13.1.2 / SUB-VOXEL-SMOOTHING §2/§5/§6/§7). The modifier field of a packed cell
## value (CellCodec.modifier) selects an in-cell occupancy shape; this class turns a
## modifier into the geometric queries the merged analytic-physics contract
## (INTEGRATION-DECISIONS §3) composes against: vertical spans, surface heights,
## point occupancy, joint contact areas and side-face profiles. It is the SHAPE
## half of the contract — `BlockCatalog.solidity_of` is the material GATE that runs
## first (`WorldManager._occ_span`); a non-solid material's modifier is never
## reached, so these functions may assume a solid host.
##
## SHAPE MODEL (SVS §2): every partial shape is four quantized corner heights
## `c00,c10,c11,c01 ∈ {0,1,2}` (half-block units, at the columns (x0,z0), (x1,z0),
## (x1,z1), (x0,z1)) plus an anchor (BOTTOM: material fills from the floor up to the
## surface H; TOP: mirrored, hanging from the ceiling). H is piecewise planar: the
## unit square splits along the diagonal whose two corner heights sum LARGER
## (`sA = c00+c11` vs `sB = c10+c01`) — the max-sum rule that makes every rotation of
## a shape enclose identical volume. `modifier == 0` is the FULL CUBE — corners
## (2,2,2,2), the sole shape the world holds today — so every query below returns its
## full-cube value for modifier 0 (an explicit fast path guarantees byte-identity
## with the pre-P5 stubs; the general math also reduces to it).

## Modifier bit layout (VDS §3.2): bits 0..7 = corners (c00|c10<<2|c11<<4|c01<<6,
## 2 bits each), bit 8 = anchor (0 BOTTOM / 1 TOP), bit 15 = family (0 = corner
## heights, the only family implemented). Value 0 ⇔ FULL CUBE.
const ANCHOR_BOTTOM := 0
const ANCHOR_TOP := 1

## Face indices — the neighbour-direction convention shared with `chunk_mesher`'s
## `_CUBE_FACES` (0 +X, 1 −X, 2 +Y, 3 −Y, 4 +Z, 5 −Z) so P5b's occlusion wiring lines
## up. `side_profile` is meaningful for the four vertical faces (0,1,4,5).
const FACE_PX := 0
const FACE_NX := 1
const FACE_PY := 2
const FACE_NY := 3
const FACE_PZ := 4
const FACE_NZ := 5

## Axis indices for `contact_area` — match `StructuralSolver._axis` (0 x, 1 y, 2 z).
const AXIS_X := 0
const AXIS_Y := 1
const AXIS_Z := 2

const _EPS := 1e-6

# --- profile-overlap LUT (§7.1) -------------------------------------------------
# 18 quantized side profiles (anchor 0/1 × e0∈{0,1,2} × e1∈{0,1,2}); all 18×18 pair
# overlap areas precomputed once so the collapse flood + structural solver pay a
# table lookup, not an integral (§7.1 / §11 "collapse cost").
static var _lut: PackedFloat32Array
static var _ready := false

## Build the side-profile overlap LUT once. Cheap (324 closed-form integrals),
## idempotent, deterministic, web-safe. Called by `contact_area`.
static func ensure_ready() -> void:
	if _ready:
		return
	_lut = PackedFloat32Array()
	_lut.resize(18 * 18)
	for ia in range(18):
		for ib in range(18):
			_lut[ia * 18 + ib] = _profile_overlap_direct(ia, ib)
	_ready = true

# --- shape decode ---------------------------------------------------------------

## Corner heights (c00, c10, c11, c01) in half-block units {0,1,2}. FULL (modifier 0)
## → (2,2,2,2). Corner value 3 (the 2-bit slot permits it) is clamped to 2 defensively
## so the math is robust even on a non-canonical modifier.
static func corners(m: int) -> Vector4i:
	if m == 0:
		return Vector4i(2, 2, 2, 2)
	if CellCodec.is_layer(m):
		# A FAM LAYER has no corner heights; return a DEFENSIVE uniform half-block quantization
		# (clamped ≥1 so it is never the empty shape) for the corner-only consumers that are
		# approximate for snow anyway (side_profile / the structural LUT). The PRECISE queries
		# (height_at, volume, span, side_profile_full, surface_tris) branch on is_layer directly.
		var q := clampi(roundi(_layer_h(m) * 2.0), 1, 2)
		return Vector4i(q, q, q, q)
	return Vector4i(mini(m & 3, 2), mini((m >> 2) & 3, 2), mini((m >> 4) & 3, 2), mini((m >> 6) & 3, 2))

## Snow LAYER height in blocks ∈ (0, 1) — the FAM LAYER level in tenths. Only valid for is_layer(m).
static func _layer_h(m: int) -> float:
	return float(CellCodec.layer_level(m)) / 10.0

## Anchor (0 BOTTOM, 1 TOP). FULL → BOTTOM.
static func anchor(m: int) -> int:
	return (m >> 8) & 1

## True when the modifier is the FULL cube (field == 0).
static func is_full(m: int) -> bool:
	return m == 0

## True when this shape's BOTTOM face fully tiles the cell floor with NO taper — a
## bottom-anchored shape whose four corners are ALL >= 1, so every column of the cell
## has material resting on the floor (the underside is a solid, unbroken quad at y=0).
## The FULL cube (m==0, corners 2,2,2,2) qualifies. A partial WEDGE with any 0 corner
## does NOT (its floor is exposed along that edge), and a TOP-anchored shape hangs from
## the ceiling so its bottom is up at H, not on the floor. Used by the fallback mesher to
## decide when a cap cell's underside fully occludes the surface cell's top quad below it
## (M1 §6.4): only a full-cover slab may suppress that quad — a taper would leave a hole.
static func bottom_face_covers(m: int) -> bool:
	if m == 0:
		return true
	if anchor(m) != ANCHOR_BOTTOM:
		return false
	var c := corners(m)
	return c.x >= 1 and c.y >= 1 and c.z >= 1 and c.w >= 1

## Pack four corner heights + anchor into a modifier (does NOT canonicalize — a raw
## builder for worldgen/tests; run through `CellCodec.canonical` for the canonical
## form). All-2 BOTTOM here yields 0xAA, not 0.
static func make_modifier(c00: int, c10: int, c11: int, c01: int, anc: int = 0) -> int:
	return (c00 & 3) | ((c10 & 3) << 2) | ((c11 & 3) << 4) | ((c01 & 3) << 6) | ((anc & 1) << 8)

# --- mass / fill fraction (§6) --------------------------------------------------

## Fill fraction ∈ (0, 1] — the §6 closed form `(2·max(sA,sB) + min(sA,sB)) / 12`,
## invariant under rotation (the max-sum diagonal routes through the peak). FULL → 1.
static func volume(m: int) -> float:
	if m == 0:
		return 1.0
	if CellCodec.is_layer(m):
		return _layer_h(m)                       # a uniform layer of height h fills fraction h
	var c := corners(m)
	var sa := c.x + c.z          # c00 + c11
	var sb := c.y + c.w          # c10 + c01
	return float(2 * maxi(sa, sb) + mini(sa, sb)) / 12.0

## Fill fraction for a FIXED diagonal (main = the (0,0)-(1,1) split), NOT the max-sum
## rule — `V_main = (2·sA + sB)/12`. Exists so verify can fence the §6 complement
## invariant `V_D(c) + V_D(2−c) = 1` (which holds only per fixed diagonal).
static func volume_with_diagonal(m: int, use_main: bool) -> float:
	return volume_of_corners(corners(m), use_main)

## Fixed-diagonal fill fraction from an EXPLICIT corner tuple — no modifier decode, so
## the all-zero tuple (which the modifier space overloads as FULL) reads its true 0
## heights. Lets verify fence the §6 complement invariant across all 3⁴ tuples.
static func volume_of_corners(c: Vector4i, use_main: bool) -> float:
	var sa := c.x + c.z
	var sb := c.y + c.w
	if use_main:
		return float(2 * sa + sb) / 12.0
	return float(2 * sb + sa) / 12.0

# --- surface height (§2 diagonal rule) ------------------------------------------

## Interpolated corner-height surface at footprint (fx, fz), in HALF-block units.
## Piecewise planar under the max-sum diagonal rule (§2).
static func _height_half(c: Vector4i, fx: float, fz: float) -> float:
	var c00 := float(c.x)
	var c10 := float(c.y)
	var c11 := float(c.z)
	var c01 := float(c.w)
	if (c.x + c.z) >= (c.y + c.w):
		# main diagonal (0,0)-(1,1)
		if fz <= fx:
			# triangle (0,0),(1,0),(1,1) — c00,c10,c11
			return c00 + (c10 - c00) * fx + (c11 - c10) * fz
		# triangle (0,0),(1,1),(0,1) — c00,c11,c01
		return c00 + (c11 - c01) * fx + (c01 - c00) * fz
	# anti diagonal (1,0)-(0,1)
	if fx + fz <= 1.0:
		# triangle (0,0),(1,0),(0,1) — c00,c10,c01
		return c00 + (c10 - c00) * fx + (c01 - c00) * fz
	# triangle (1,0),(1,1),(0,1) — c10,c11,c01
	return (c10 + c01 - c11) + (c11 - c01) * fx + (c11 - c10) * fz

## Surface height H(fx, fz) in BLOCKS ∈ [0, 1] (the BOTTOM-anchor top / TOP-anchor
## depth-from-ceiling). Diagonal-independent along cell edges, so neighbouring cells
## are crack-free (§8.1).
static func height_at(m: int, fx: float, fz: float) -> float:
	if m == 0:
		return 1.0
	if CellCodec.is_layer(m):
		return _layer_h(m)                       # flat top at h everywhere (span/occupied/local_top follow)
	return _height_half(corners(m), fx, fz) * 0.5

# --- analytic physics (§5) ------------------------------------------------------

## Walkable top of the filled column at (fx, fz), in [0, 1]. BOTTOM → H; TOP → 1.0
## where any material exists (H > 0) else 0.0; FULL → 1.0 (SVS §5).
static func local_top(m: int, fx: float, fz: float) -> float:
	if m == 0:
		return 1.0
	var h := height_at(m, fx, fz)
	if anchor(m) == ANCHOR_TOP:
		return 1.0 if h > 0.0 else 0.0
	return h

## Filled vertical interval (lo, hi) within the unit cell at footprint (fx, fz).
## FULL → (0, 1). BOTTOM → (0, H); TOP → (1−H, 1); `Vector2.ZERO` where the shape is
## cut away (H == 0) at this footprint (SVS §5).
static func span(m: int, fx: float, fz: float) -> Vector2:
	if m == 0:
		return Vector2(0.0, 1.0)
	var h := height_at(m, fx, fz)
	if h <= 0.0:
		return Vector2.ZERO
	if anchor(m) == ANCHOR_TOP:
		return Vector2(1.0 - h, 1.0)
	return Vector2(0.0, h)

## True if the sub-cell point (fx, fy, fz) lies inside the shape's solid volume
## (point-in-interval, biased to "hit" on the filled boundary by _EPS per §11's DDA
## convention). FULL → always true.
static func occupied(m: int, fx: float, fy: float, fz: float) -> bool:
	if m == 0:
		return true
	var sp := span(m, fx, fz)
	if sp == Vector2.ZERO:
		return false
	return fy >= sp.x - _EPS and fy <= sp.y + _EPS

# --- side profiles (§7.1) -------------------------------------------------------

## The (anchor, e0, e1) side profile of `face` (0..5; the four vertical faces are
## meaningful). e0/e1 are the two corner heights (half-units) on that face's edge in
## world-tangential order (z for the ±X faces, x for the ±Z faces). y-faces return
## the anchor with (−1, −1) as "not a side profile".
static func side_profile(m: int, face: int) -> Vector3i:
	var c := corners(m)
	var anc := anchor(m)
	match face:
		FACE_PX:
			return Vector3i(anc, c.y, c.z)    # +X: c10 @ z0, c11 @ z1
		FACE_NX:
			return Vector3i(anc, c.x, c.w)    # −X: c00 @ z0, c01 @ z1
		FACE_PZ:
			return Vector3i(anc, c.w, c.z)    # +Z: c01 @ x0, c11 @ x1
		FACE_NZ:
			return Vector3i(anc, c.x, c.y)    # −Z: c00 @ x0, c10 @ x1
	return Vector3i(anc, -1, -1)

## True if the shape's `face` (0..5) side profile FULLY covers the unit face — so a
## neighbour on its far side is occluded (composed by `WorldManager.occludes_face`).
## FULL → every face is covered (true — today's fast path). Lateral faces are full
## iff both edge corners reach 2 (full height). y-faces use the anchor's coverage of
## the top/bottom plane (SVS §4.2).
static func side_profile_full(m: int, face: int) -> bool:
	if m == 0:
		return true
	if CellCodec.is_layer(m):
		return face == FACE_NY                   # a 0<h<1 uniform bottom layer covers ONLY the floor face
	var c := corners(m)
	var anc := anchor(m)
	match face:
		FACE_PX:
			return c.y == 2 and c.z == 2
		FACE_NX:
			return c.x == 2 and c.w == 2
		FACE_PZ:
			return c.w == 2 and c.z == 2
		FACE_NZ:
			return c.x == 2 and c.y == 2
		FACE_PY:
			# top plane covered: BOTTOM needs H≡1 (all-2 → FULL, never a nonzero
			# modifier); TOP hangs from the ceiling and covers it wherever H>0 (all
			# corners > 0).
			if anc == ANCHOR_TOP:
				return c.x > 0 and c.y > 0 and c.z > 0 and c.w > 0
			return c.x == 2 and c.y == 2 and c.z == 2 and c.w == 2
		FACE_NY:
			# bottom plane: BOTTOM fills from the floor and (max-sum rule) covers the
			# whole bottom for any nonempty shape; TOP touches y=0 only where H≡1.
			if anc == ANCHOR_TOP:
				return c.x == 2 and c.y == 2 and c.z == 2 and c.w == 2
			return c.x > 0 or c.y > 0 or c.z > 0 or c.w > 0
	return false

# --- contact area (§7) ----------------------------------------------------------

## Shared-face contact area (0..1) between two adjacent cells' shapes across `axis`
## (0 x, 1 y, 2 z) — the fraction of the unit face where BOTH cells' filled material
## meets, i.e. the structural joint capacity factor (VDS §13.3; zero ⇒ no joint).
## CONVENTION: `mod_a` is the cell on the −axis side, `mod_b` on the +axis side (for
## axis y: a is LOWER, b is UPPER — matches `StructuralSolver`'s tension-up call where
## the source cell is below its neighbour). Two FULL cubes → the whole face, 1.0.
static func contact_area(mod_a: int, mod_b: int, axis: int) -> float:
	if mod_a == 0 and mod_b == 0:
		return 1.0                                   # full-cube fast path (today's world)
	if axis == AXIS_Y:
		return _horizontal_contact(mod_a, mod_b)     # §7.2
	ensure_ready()
	var ia := _face_profile_index(mod_a, axis, true)   # a's +axis face
	var ib := _face_profile_index(mod_b, axis, false)  # b's −axis face
	return _lut[ia * 18 + ib]

## Profile index (0..17) of `m`'s face across `axis` (positive = the +axis face).
static func _face_profile_index(m: int, axis: int, positive: bool) -> int:
	var c := corners(m)
	var anc := anchor(m)
	var e0: int
	var e1: int
	if axis == AXIS_X:
		if positive:
			e0 = c.y; e1 = c.z                       # +X: c10, c11 (z order)
		else:
			e0 = c.x; e1 = c.w                       # −X: c00, c01
	else:                                            # AXIS_Z
		if positive:
			e0 = c.w; e1 = c.z                       # +Z: c01, c11 (x order)
		else:
			e0 = c.x; e1 = c.y                       # −Z: c00, c10
	return anc * 9 + e0 * 3 + e1

## Direct (non-LUT) overlap of two side profiles by index — §7.1 closed form. Same
## anchor: ∫min(hA,hB); opposite anchor (BOTTOM vs TOP): ∫max(0, hA+hB−1).
static func _profile_overlap_direct(ia: int, ib: int) -> float:
	var anc_a := ia / 9
	var ra := ia % 9
	var anc_b := ib / 9
	var rb := ib % 9
	var a0 := float(ra / 3) * 0.5
	var a1 := float(ra % 3) * 0.5
	var b0 := float(rb / 3) * 0.5
	var b1 := float(rb % 3) * 0.5
	if anc_a == anc_b:
		return _integral_min(a0, a1, b0, b1)
	return _integral_pos(a0 + b0 - 1.0, a1 + b1 - 1.0)

## ∫₀¹ min(lerp(a0,a1,t), lerp(b0,b1,t)) dt — both integrands linear, ≤1 crossing (§7.1).
static func _integral_min(a0: float, a1: float, b0: float, b1: float) -> float:
	var d0 := a0 - b0
	var d1 := a1 - b1
	if d0 * d1 >= 0.0:                               # no crossing: one line is min throughout
		return (minf(a0, b0) + minf(a1, b1)) * 0.5
	var ts := d0 / (d0 - d1)                         # crossing point
	var m0 := minf(a0, b0)
	var mc := lerpf(a0, a1, ts)
	var m1 := minf(a1, b1)
	return (m0 + mc) * 0.5 * ts + (mc + m1) * 0.5 * (1.0 - ts)

## ∫₀¹ max(0, lerp(g0,g1,t)) dt — the positive area of a line (BOTTOM-vs-TOP overlap).
static func _integral_pos(g0: float, g1: float) -> float:
	if g0 <= 0.0 and g1 <= 0.0:
		return 0.0
	if g0 >= 0.0 and g1 >= 0.0:
		return (g0 + g1) * 0.5
	var t := g0 / (g0 - g1)                          # zero crossing
	if g0 > 0.0:
		return g0 * t * 0.5                          # positive on [0, t]
	return g1 * (1.0 - t) * 0.5                      # positive on [t, 1]

# --- horizontal contact (§7.2) --------------------------------------------------
# Coverage regions on the shared horizontal plane, as {kind, tri}: kind 0 EMPTY,
# 1 FULL, 2 HALF (one triangle). tri ids: 0 main{c00,c10,c11}, 1 main{c00,c11,c01},
# 2 anti{c00,c10,c01}, 3 anti{c10,c11,c01}.
const _REG_EMPTY := 0
const _REG_FULL := 1
const _REG_HALF := 2

## Contact between a LOWER cell (mod_a, top face reaches y=1) and an UPPER cell
## (mod_b, bottom face reaches y=0) — area of the intersection of their coverage
## regions (§7.2).
static func _horizontal_contact(mod_a: int, mod_b: int) -> float:
	var ra := _top_region(mod_a)
	var rb := _bottom_region(mod_b)
	return _region_intersect_area(ra, rb)

## Where the lower cell's material reaches its TOP face (y=1). FULL → FULL; BOTTOM →
## the all-2 triangles ({H=1}); TOP → the whole face (hangs from the ceiling, H>0).
static func _top_region(m: int) -> Vector2i:
	if m == 0:
		return Vector2i(_REG_FULL, 0)
	if anchor(m) == ANCHOR_TOP:
		return Vector2i(_REG_FULL, 0)
	return _all2_region(m)

## Where the upper cell's material reaches its BOTTOM face (y=0). FULL → FULL; BOTTOM
## → the whole face (max-sum rule: no all-zero triangle on a nonempty shape); TOP →
## the all-2 triangles ({H=1}, material reaches down to y=0 only there).
static func _bottom_region(m: int) -> Vector2i:
	if m == 0:
		return Vector2i(_REG_FULL, 0)
	if anchor(m) == ANCHOR_TOP:
		return _all2_region(m)
	return Vector2i(_REG_FULL, 0)

## The union of the shape's max-sum triangles whose three corners are all 2, as a
## coverage region ({H=1} for a BOTTOM shape).
static func _all2_region(m: int) -> Vector2i:
	var c := corners(m)
	if (c.x + c.z) >= (c.y + c.w):
		var t0 := c.x == 2 and c.y == 2 and c.z == 2     # {c00,c10,c11}
		var t1 := c.x == 2 and c.z == 2 and c.w == 2     # {c00,c11,c01}
		if t0 and t1:
			return Vector2i(_REG_FULL, 0)
		if t0:
			return Vector2i(_REG_HALF, 0)
		if t1:
			return Vector2i(_REG_HALF, 1)
		return Vector2i(_REG_EMPTY, 0)
	var a2 := c.x == 2 and c.y == 2 and c.w == 2         # {c00,c10,c01}
	var a3 := c.y == 2 and c.z == 2 and c.w == 2         # {c10,c11,c01}
	if a2 and a3:
		return Vector2i(_REG_FULL, 0)
	if a2:
		return Vector2i(_REG_HALF, 2)
	if a3:
		return Vector2i(_REG_HALF, 3)
	return Vector2i(_REG_EMPTY, 0)

## Area of the intersection of two coverage regions. HALF∩HALF: same diagonal → ½ if
## the same triangle else 0; crossed diagonals → ¼ (§7.2).
static func _region_intersect_area(ra: Vector2i, rb: Vector2i) -> float:
	if ra.x == _REG_EMPTY or rb.x == _REG_EMPTY:
		return 0.0
	if ra.x == _REG_FULL and rb.x == _REG_FULL:
		return 1.0
	if ra.x == _REG_FULL:
		return 0.5                                   # FULL ∩ HALF
	if rb.x == _REG_FULL:
		return 0.5
	# both HALF
	var main_a := ra.y <= 1
	var main_b := rb.y <= 1
	if main_a == main_b:
		return 0.5 if ra.y == rb.y else 0.0
	return 0.25

# --- surface triangles for the in-cell ray test (§5.3) --------------------------

## The 1–2 surface triangles (top for BOTTOM, bottom for TOP) as dictionaries
## {v0, v1, v2, normal} in cell-local coordinates — the ray/plane targets for the
## `aimed_voxel` in-cell test (P5b). FULL → the flat top at y=1.
static func surface_tris(m: int) -> Array:
	if CellCodec.is_layer(m):
		# The walkable top of a uniform layer: one flat quad at y=h, normal UP (feeds the DDA aim
		# ray and the collider prisms). Diagonal is irrelevant for a flat surface.
		var h := _layer_h(m)
		var q00 := Vector3(0, h, 0)
		var q10 := Vector3(1, h, 0)
		var q11 := Vector3(1, h, 1)
		var q01 := Vector3(0, h, 1)
		return [_tri(q00, q10, q11, ANCHOR_BOTTOM), _tri(q00, q11, q01, ANCHOR_BOTTOM)]
	var c := corners(m)
	var anc := anchor(m)
	# Corner surface y in blocks: BOTTOM tops at H, TOP surface at 1−H.
	var y00 := float(c.x) * 0.5
	var y10 := float(c.y) * 0.5
	var y11 := float(c.z) * 0.5
	var y01 := float(c.w) * 0.5
	if anc == ANCHOR_TOP:
		y00 = 1.0 - y00; y10 = 1.0 - y10; y11 = 1.0 - y11; y01 = 1.0 - y01
	var p00 := Vector3(0, y00, 0)
	var p10 := Vector3(1, y10, 0)
	var p11 := Vector3(1, y11, 1)
	var p01 := Vector3(0, y01, 1)
	var tris: Array = []
	if (c.x + c.z) >= (c.y + c.w):
		tris.append(_tri(p00, p10, p11, anc))
		tris.append(_tri(p00, p11, p01, anc))
	else:
		tris.append(_tri(p00, p10, p01, anc))
		tris.append(_tri(p10, p11, p01, anc))
	return tris

## One surface triangle {v0,v1,v2,normal}; the normal is oriented outward (up for
## BOTTOM, down for TOP).
static func _tri(a: Vector3, b: Vector3, c: Vector3, anc: int) -> Dictionary:
	var n := (b - a).cross(c - a)
	if n.length() > 0.0:
		n = n.normalized()
	var want_up := anc == ANCHOR_BOTTOM
	if (n.y >= 0.0) != want_up:
		# reverse winding so the normal faces outward
		var t := b
		b = c
		c = t
		n = -n
	return {"v0": a, "v1": b, "v2": c, "normal": n}
