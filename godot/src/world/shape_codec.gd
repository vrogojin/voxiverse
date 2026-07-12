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
	if CellCodec.is_slope(m):
		# Defensive quantization (SHARP-SLOPE §2.2): per corner clampi(2·d_i, 0, 2), so any consumer
		# missed by the is_slope sweep degrades to the nearest legacy shape, never nonsense.
		var d := CellCodec.slope_deltas(m)
		return Vector4i(clampi(2 * d.x, 0, 2), clampi(2 * d.y, 0, 2), clampi(2 * d.z, 0, 2), clampi(2 * d.w, 0, 2))
	return Vector4i(mini(m & 3, 2), mini((m >> 2) & 3, 2), mini((m >> 4) & 3, 2), mini((m >> 6) & 3, 2))

## Snow LAYER height in blocks ∈ (0, 1) — the FAM LAYER level in tenths. Only valid for is_layer(m).
static func _layer_h(m: int) -> float:
	return float(CellCodec.layer_level(m)) / 10.0

## Anchor (0 BOTTOM, 1 TOP). FULL → BOTTOM. SLOPE → BOTTOM (always; SHARP-SLOPE §2.2).
static func anchor(m: int) -> int:
	if CellCodec.is_slope(m):
		return ANCHOR_BOTTOM
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
	if CellCodec.is_slope(m):
		return false                          # SHARP-SLOPE §2.2: min d ≤ 0 → floor exposed somewhere
	if anchor(m) != ANCHOR_BOTTOM:
		return false
	var c := corners(m)
	return c.x >= 1 and c.y >= 1 and c.z >= 1 and c.w >= 1

## Pack four corner heights + anchor into a modifier (does NOT canonicalize — a raw
## builder for worldgen/tests; run through `CellCodec.canonical` for the canonical
## form). All-2 BOTTOM here yields 0xAA, not 0.
static func make_modifier(c00: int, c10: int, c11: int, c01: int, anc: int = 0) -> int:
	return (c00 & 3) | ((c10 & 3) << 2) | ((c11 & 3) << 4) | ((c01 & 3) << 6) | ((anc & 1) << 8)

# --- D4 orientation rotation (COSMOS-FRAME-ORIENTATION §6) -----------------------
## Cyclically permute a corner tuple (c00, c10, c11, c01 at cell-local footprint corners
## (0,0),(1,0),(1,1),(0,1)) by `d4` quarter-turns (0..3). d4 == 1 is a +90° rotation of the
## index axes (the matrix [[0,-1],[1,0]], atan2(m2,m0) = +90°): the footprint corner at position q
## moves to R·q, so the NEW corner value at index k is the OLD value at R⁻¹(k). Worked out for the
## corner ring 0→1→2→3 (c00→c10→c11→c01, counter-clockwise in (x,z)): d4=1 → (c01,c00,c10,c11).
## The SAME permutation serves BOTH the corner-height family and the FAM SLOPE deltas (identical
## corner order). rotate⁴ = identity and rot(a)∘rot(b) = rot(a+b) hold by construction (a cyclic
## shift group), pinned by verify_shape_rot.
## Public D4 permutation of a corner/delta tuple (c00,c10,c11,c01) by `d4` quarter-turns — the SLOPE-run
## corner-target rotation the collider path uses (TerrainConfig.rotate_slope_run) so a rotated slope run
## decodes to the same rotated shape resolve_cell renders. Same permutation as rotate_modifier.
static func rotate_corners(c: Vector4i, d4: int) -> Vector4i:
	return _rot_corners(c, d4)

static func _rot_corners(c: Vector4i, d4: int) -> Vector4i:
	match ((d4 % 4) + 4) % 4:
		1:
			return Vector4i(c.w, c.x, c.y, c.z)   # +90°  (c01,c00,c10,c11)
		2:
			return Vector4i(c.z, c.w, c.x, c.y)   # 180°  (c11,c01,c00,c10)
		3:
			return Vector4i(c.y, c.z, c.w, c.x)   # 270°  (c10,c11,c01,c00)
	return c                                       # 0° — identity

## Rotate a direction-carrying MODIFIER (16-bit shape field only, NOT the liquid/state axes) by a
## D4 quarter-turn `d4` (0..3, +90° convention as `_rot_corners`) in the cell's XZ plane. Isotropic
## shapes are fixed points: modifier 0 (full cube), FAM LAYER (uniform snow). Directional shapes —
## FAM SLOPE (four signed deltas) and the corner-height family (ramps/wedges/caps) — permute their
## four corners. Waterlogged composites rotate via their dry shape (this modifier); the liquid FIELD
## rides the packed value's separate axis and is orientation-free. Pure, table-driven, deterministic
## (COSMOS-FRAME-ORIENTATION §6.2): rotate(mod, 0) == mod, rotate⁴ == id, rotate(a)∘rotate(b) ==
## rotate(a+b). Used at the ONE TerrainConfig resolve boundary (§6.3) with d4 = the fold Jacobian J⁻¹.
static func rotate_modifier(modifier: int, d4: int) -> int:
	var q := ((d4 % 4) + 4) % 4
	if q == 0 or modifier == 0:
		return modifier                            # identity turn, or the isotropic full cube
	if CellCodec.is_layer(modifier):
		return modifier                            # uniform LAYER — rotation-invariant
	if CellCodec.is_junction(modifier):
		return modifier                            # COSMOS FACETED: facet-frame-local, no D4 in faceted mode
	if CellCodec.is_slope(modifier):
		var d := _rot_corners(CellCodec.slope_deltas(modifier), q)
		return CellCodec.make_slope(d.x, d.y, d.z, d.w)   # canonical (rot of a canonical slope is canonical)
	# Corner-height family (BOTTOM/TOP anchor is a vertical axis → rotation-invariant).
	var c := _rot_corners(corners(modifier), q)
	return make_modifier(c.x, c.y, c.z, c.w, anchor(modifier))

# --- mass / fill fraction (§6) --------------------------------------------------

## Fill fraction ∈ (0, 1] — the §6 closed form `(2·max(sA,sB) + min(sA,sB)) / 12`,
## invariant under rotation (the max-sum diagonal routes through the peak). FULL → 1.
static func volume(m: int) -> float:
	if m == 0:
		return 1.0
	if CellCodec.is_layer(m):
		return _layer_h(m)                       # a uniform layer of height h fills fraction h
	if CellCodec.is_junction(m):
		return 0.5                               # COSMOS FACETED: partial fill (generation-only; mass unused)
	if CellCodec.is_slope(m):
		return _slope_volume(CellCodec.slope_deltas(m))
	var c := corners(m)
	var sa := c.x + c.z          # c00 + c11
	var sb := c.y + c.w          # c10 + c01
	return float(2 * maxi(sa, sb) + mini(sa, sb)) / 12.0

## Snow-fill volume (SNOW-ACCUMULATION §2.5): the fraction of the cell filled by a flat snow plane at
## height `level/10` sitting ABOVE the terrain shape `m` — i.e. ∫∫ max(0, s − H(fx,fz)) over the unit
## footprint, the positive part of the plane-minus-ramp integral. `break_terrain` yields `280·this`
## kg of snow. Deterministic numeric quadrature (a fixed grid); precision is cosmetic, but the sign and
## monotonicity in `level` are exact (verify pins it against a Monte-Carlo sample). FULL cube / LAYER →
## 0 (no terrain remainder to fill; snow-on-snow is Decision 4's business).
static func fill_volume(m: int, level: int) -> float:
	var s := float(clampi(level, 0, 10)) / 10.0
	if m == 0 or CellCodec.is_layer(m):
		return 0.0
	const N := 16
	var cell := 1.0 / float(N)
	var vol := 0.0
	for i in N:
		var fx := (float(i) + 0.5) * cell
		for j in N:
			var fz := (float(j) + 0.5) * cell
			vol += maxf(0.0, s - height_at(m, fx, fz))
	return vol * cell * cell

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
	if CellCodec.is_junction(m):
		return _junction_span(m, fx, fz).y       # COSMOS FACETED: use the seam-clip top (callers should use span)
	if CellCodec.is_slope(m):
		return clampf(_plane_at(CellCodec.slope_deltas(m), fx, fz), 0.0, 1.0)
	return _height_half(corners(m), fx, fz) * 0.5

## The SLOPE corner-plane value D(fx, fz) in BLOCKS (signed, UNCLAMPED) — the same max-sum diagonal
## rule as _height_half but over signed whole-block deltas (SHARP-SLOPE §2.1). The comparison
## d00+d11 ≥ d10+d01 is invariant under the uniform −1 shift between run cells, so every cell of a
## run splits on the SAME diagonal (exact vertical tiling). The occupied top surface is clamp(D,0,1).
static func _plane_at(d: Vector4i, fx: float, fz: float) -> float:
	var c00 := float(d.x)
	var c10 := float(d.y)
	var c11 := float(d.z)
	var c01 := float(d.w)
	if (d.x + d.z) >= (d.y + d.w):
		if fz <= fx:
			return c00 + (c10 - c00) * fx + (c11 - c10) * fz
		return c00 + (c11 - c01) * fx + (c01 - c00) * fz
	if fx + fz <= 1.0:
		return c00 + (c10 - c00) * fx + (c01 - c00) * fz
	return (c10 + c01 - c11) + (c11 - c01) * fx + (c11 - c10) * fz

## Fill fraction of a clipped-plane SLOPE shape (SHARP-SLOPE §2.2 `volume`): ∫ clamp(D, 0, 1) over
## the unit square = Σ over the two max-sum triangles of [I⁺(a,b,c) − I⁺(a−1,b−1,c−1)], the
## positive-part triangle integral identity ∫clamp(f,0,1) = ∫max(0,f) − ∫max(0,f−1).
static func _slope_volume(d: Vector4i) -> float:
	var a := float(d.x)
	var b := float(d.y)
	var cc := float(d.z)
	var dd := float(d.w)
	if (d.x + d.z) >= (d.y + d.w):
		return _clip_tri_vol(a, b, cc) + _clip_tri_vol(a, cc, dd)   # (d00,d10,d11)+(d00,d11,d01)
	return _clip_tri_vol(a, b, dd) + _clip_tri_vol(b, cc, dd)       # (d00,d10,d01)+(d10,d11,d01)

## ∫ clamp(linear, 0, 1) over one half-unit-square triangle (area ½), vertex values a,b,c.
static func _clip_tri_vol(a: float, b: float, c: float) -> float:
	return _int_pos_tri(a, b, c) - _int_pos_tri(a - 1.0, b - 1.0, c - 1.0)

## ∫ max(0, linear) over one half-unit-square triangle (area ½) whose vertex values are a,b,c
## (SHARP-SLOPE §2.2). Closed forms: all ≥ 0 → (a+b+c)/6; all ≤ 0 → 0; one positive p (others q,r)
## → p³/(6·(p−q)·(p−r)); one negative n (others p,q) → (a+b+c)/6 − n³/(6·(n−p)·(n−q)).
static func _int_pos_tri(a: float, b: float, c: float) -> float:
	var lo := minf(a, minf(b, c))
	if lo >= 0.0:
		return (a + b + c) / 6.0
	var hi := maxf(a, maxf(b, c))
	if hi <= 0.0:
		return 0.0
	var npos := int(a > 0.0) + int(b > 0.0) + int(c > 0.0)
	if npos == 1:
		var p := a if a > 0.0 else (b if b > 0.0 else c)
		var q: float
		var r: float
		if a > 0.0:
			q = b; r = c
		elif b > 0.0:
			q = a; r = c
		else:
			q = a; r = b
		return p * p * p / (6.0 * (p - q) * (p - r))
	# npos == 2: exactly one negative n, others p, q (both ≥ 0)
	var nn := a if a < 0.0 else (b if b < 0.0 else c)
	var pp: float
	var qq: float
	if a < 0.0:
		pp = b; qq = c
	elif b < 0.0:
		pp = a; qq = c
	else:
		pp = a; qq = b
	return (a + b + c) / 6.0 - nn * nn * nn / (6.0 * (nn - pp) * (nn - qq))

# --- analytic physics (§5) ------------------------------------------------------

## Walkable top of the filled column at (fx, fz), in [0, 1]. BOTTOM → H; TOP → 1.0
## where any material exists (H > 0) else 0.0; FULL → 1.0 (SVS §5).
static func local_top(m: int, fx: float, fz: float) -> float:
	if m == 0:
		return 1.0
	if CellCodec.is_junction(m):
		return _junction_span(m, fx, fz).y
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
	if CellCodec.is_junction(m):
		return _junction_span(m, fx, fz)
	var h := height_at(m, fx, fz)
	if h <= 0.0:
		return Vector2.ZERO
	if anchor(m) == ANCHOR_TOP:
		return Vector2(1.0 - h, 1.0)
	return Vector2(0.0, h)

## COSMOS FACETED §3.5.6 — the vertical solid interval of a JUNCTION cell at footprint (fx, fz): the cube
## column intersected with the seam half-space own_local(fx,fy,fz) = A·fx + B·fy + C·fz + base ≥ 0, using the
## active facet's q-model plane (matching the baked render mesh; exact per-cell physics is done in
## WorldManager._occ_span). own_local = B·fy + k, so the cut is at fy = −k/B (or a full/empty column if B≈0).
static func _junction_span(m: int, fx: float, fz: float) -> Vector2:
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return Vector2(0.0, 1.0)
	var pl: Array = FacetAtlas.junction_model_plane(fid, CellCodec.junction_slot(m), CellCodec.junction_q(m))
	var A: float = pl[0]; var B: float = pl[1]; var C: float = pl[2]; var base: float = pl[3]
	var k := A * fx + C * fz + base
	if absf(B) < 1e-9:
		return Vector2(0.0, 1.0) if k >= 0.0 else Vector2.ZERO   # vertical cut: full or empty column
	var thr := -k / B
	if B > 0.0:                                                  # solid where fy ≥ thr
		if thr >= 1.0:
			return Vector2.ZERO
		return Vector2(maxf(0.0, thr), 1.0)
	if thr <= 0.0:                                               # B < 0: solid where fy ≤ thr
		return Vector2.ZERO
	return Vector2(0.0, minf(1.0, thr))

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
	if CellCodec.is_junction(m):
		return false                             # COSMOS FACETED: never occlude a neighbour (the cut faces air)
	if CellCodec.is_layer(m):
		return face == FACE_NY                   # a 0<h<1 uniform bottom layer covers ONLY the floor face
	if CellCodec.is_slope(m):
		# SHARP-SLOPE §2.2: lateral face covered iff both edge deltas ≥ 1 (H ≡ 1 along the edge).
		# FACE_PY never (a full-height plane everywhere is canonically full). FACE_NY covered iff
		# min(d) ≥ 0 (floor touched everywhere except measure-zero corners; a min ≤ −1 exposes a
		# positive-area region → must NOT occlude the cell below).
		var d := CellCodec.slope_deltas(m)
		match face:
			FACE_PX:
				return d.y >= 1 and d.z >= 1
			FACE_NX:
				return d.x >= 1 and d.w >= 1
			FACE_PZ:
				return d.w >= 1 and d.z >= 1
			FACE_NZ:
				return d.x >= 1 and d.y >= 1
			FACE_PY:
				return false
			FACE_NY:
				return mini(mini(d.x, d.y), mini(d.z, d.w)) >= 0
		return false
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
	# SLOPE partner (SHARP-SLOPE §2.2): bypass the half-quantized LUT / region machinery — a SLOPE
	# edge profile is clamp(lerp(e0,e1),0,1), continuous, not a {0,1,2} half-step.
	if CellCodec.is_slope(mod_a) or CellCodec.is_slope(mod_b):
		if axis == AXIS_Y:
			return _slope_horizontal_contact(mod_a, mod_b)
		return _slope_lateral_contact(mod_a, mod_b, axis)
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
	if CellCodec.is_slope(m):
		return _slope_surface_tris(CellCodec.slope_deltas(m))
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

# --- SLOPE geometry (SHARP-SLOPE §2.2/§2.3) -------------------------------------

## The two max-sum footprint triangles (as XZ Vector2 corner triples) of a SLOPE tuple.
static func _slope_foot_tris(d: Vector4i) -> Array:
	if (d.x + d.z) >= (d.y + d.w):
		return [
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)],   # d00,d10,d11
			[Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]]   # d00,d11,d01
	return [
		[Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)],       # d00,d10,d01
		[Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]]       # d10,d11,d01

## Clip a convex XZ polygon by the half-plane {_plane_at(d) − thr ≥ 0} (keep_above) or ≤ 0.
static func _clip_plane_2d(poly: Array, d: Vector4i, thr: float, keep_above: bool) -> Array:
	if poly.size() < 3:
		return []
	var out: Array = []
	var n := poly.size()
	for i in n:
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[(i + 1) % n]
		var sc := _plane_at(d, cur.x, cur.y) - thr
		var sn := _plane_at(d, nxt.x, nxt.y) - thr
		if not keep_above:
			sc = -sc
			sn = -sn
		if sc >= 0.0:
			out.append(cur)
		if (sc >= 0.0) != (sn >= 0.0):
			var t := sc / (sc - sn)
			out.append(cur + (nxt - cur) * t)
	return out

## SLOPE surface triangles (SHARP-SLOPE §2.2, LOAD-BEARING for collider prisms): per max-sum
## footprint triangle, the PLATEAU {D ≥ 1} region emits flat tris at y = 1 (normal UP → full-height
## prisms), the BAND {0 < D < 1} region emits tris on the plane y = D (true sloped normal); the
## empty region {D ≤ 0} emits nothing. Each clipped polygon fan-triangulates.
static func _slope_surface_tris(d: Vector4i) -> Array:
	var tris: Array = []
	for ft: Array in _slope_foot_tris(d):
		# plateau {D ≥ 1} → flat at y = 1
		var plat := _clip_plane_2d(ft, d, 1.0, true)
		_fan_flat(plat, 1.0, ANCHOR_BOTTOM, tris)
		# band {0 ≤ D ≤ 1} → on the plane y = D
		var band := _clip_plane_2d(ft, d, 0.0, true)
		band = _clip_plane_2d(band, d, 1.0, false)
		if band.size() >= 3:
			for i in range(1, band.size() - 1):
				_append_tri(_slope_lift(d, band[0]), _slope_lift(d, band[i]), _slope_lift(d, band[i + 1]), ANCHOR_BOTTOM, tris)
	return tris

## Append a non-degenerate triangle (skips slivers from polygon clipping — a zero-area tri has no
## surface and would extrude to a zero-volume prism anyway).
static func _append_tri(a: Vector3, b: Vector3, c: Vector3, anc: int, out: Array) -> void:
	if (b - a).cross(c - a).length() < _EPS:
		return
	out.append(_tri(a, b, c, anc))

## The BOTTOM face polygons of a SLOPE cell: the {D > 0} footprint at y = 0, normal DOWN (the empty
## region has no underside). For the ShapeMesh builder.
static func slope_bottom_tris(m: int) -> Array:
	var d := CellCodec.slope_deltas(m)
	var tris: Array = []
	for ft: Array in _slope_foot_tris(d):
		var region := _clip_plane_2d(ft, d, 0.0, true)   # D ≥ 0
		_fan_flat(region, 0.0, ANCHOR_TOP, tris)         # normal DOWN
	return tris

## Fan-triangulate an XZ polygon into flat tris at height `y` with outward normal per `anc`.
static func _fan_flat(poly: Array, y: float, anc: int, out: Array) -> void:
	if poly.size() < 3:
		return
	for i in range(1, poly.size() - 1):
		_append_tri(
			Vector3(poly[0].x, y, poly[0].y),
			Vector3(poly[i].x, y, poly[i].y),
			Vector3(poly[i + 1].x, y, poly[i + 1].y), anc, out)

## Lift an XZ point to the clamped SLOPE surface (fx, clamp(D,0,1), fz).
static func _slope_lift(d: Vector4i, v: Vector2) -> Vector3:
	return Vector3(v.x, clampf(_plane_at(d, v.x, v.y), 0.0, 1.0), v.y)

# --- SLOPE contact area (SHARP-SLOPE §2.2) --------------------------------------

## A lateral-face profile as [anchor, h0, h1] in BLOCKS: the profile is clamp(lerp(h0,h1,t), 0, 1)
## across the face's tangent t ∈ [0,1]. Uniform for SLOPE (BOTTOM, raw block deltas), legacy
## (its anchor, half-block corner heights) and FULL (BOTTOM, 1, 1).
static func _profile_hab(m: int, axis: int, positive: bool) -> Array:
	if m == 0:
		return [ANCHOR_BOTTOM, 1.0, 1.0]
	if CellCodec.is_slope(m):
		var d := CellCodec.slope_deltas(m)
		var e0: int
		var e1: int
		if axis == AXIS_X:
			if positive:
				e0 = d.y; e1 = d.z            # +X: c10,c11
			else:
				e0 = d.x; e1 = d.w            # −X: c00,c01
		else:
			if positive:
				e0 = d.w; e1 = d.z            # +Z: c01,c11
			else:
				e0 = d.x; e1 = d.y            # −Z: c00,c10
		return [ANCHOR_BOTTOM, float(e0), float(e1)]
	var c := corners(m)
	var le0: int
	var le1: int
	if axis == AXIS_X:
		if positive:
			le0 = c.y; le1 = c.z
		else:
			le0 = c.x; le1 = c.w
	else:
		if positive:
			le0 = c.w; le1 = c.z
		else:
			le0 = c.x; le1 = c.y
	return [anchor(m), float(le0) * 0.5, float(le1) * 0.5]

## Add the t ∈ (0,1) where lerp(h0,h1,t) crosses 0 or 1 (the clamp knots of a profile).
static func _add_clip_knots(knots: Array, h0: float, h1: float) -> void:
	if absf(h1 - h0) < _EPS:
		return
	for target: float in [0.0, 1.0]:
		var t := (target - h0) / (h1 - h0)
		if t > _EPS and t < 1.0 - _EPS:
			knots.append(t)

## Lateral (X/Z) shared-face contact when at least one cell is a SLOPE: integrate the overlap of
## two clamped-linear edge profiles, subdividing [0,1] at both profiles' clamp knots so each segment
## is linear-in-both — then _integral_min (same anchor) / _integral_pos (opposite) per segment.
static func _slope_lateral_contact(mod_a: int, mod_b: int, axis: int) -> float:
	var pa := _profile_hab(mod_a, axis, true)     # a's +axis face
	var pb := _profile_hab(mod_b, axis, false)    # b's −axis face
	var same: bool = pa[0] == pb[0]
	var knots: Array = [0.0, 1.0]
	_add_clip_knots(knots, pa[1], pa[2])
	_add_clip_knots(knots, pb[1], pb[2])
	knots.sort()
	var total := 0.0
	for i in range(knots.size() - 1):
		var t0: float = knots[i]
		var t1: float = knots[i + 1]
		if t1 - t0 <= _EPS:
			continue
		var a0 := clampf(lerpf(pa[1], pa[2], t0), 0.0, 1.0)
		var a1 := clampf(lerpf(pa[1], pa[2], t1), 0.0, 1.0)
		var b0 := clampf(lerpf(pb[1], pb[2], t0), 0.0, 1.0)
		var b1 := clampf(lerpf(pb[1], pb[2], t1), 0.0, 1.0)
		var seg := _integral_min(a0, a1, b0, b1) if same else _integral_pos(a0 + b0 - 1.0, a1 + b1 - 1.0)
		total += seg * (t1 - t0)
	return total

## Horizontal (AXIS_Y) shared-face contact when at least one cell is a SLOPE: the area of
## intersection of the LOWER cell's top-reaching region and the UPPER cell's bottom-reaching region.
## The unit square is split into 4 quarter-triangles (compatible with BOTH cells' max-sum diagonals,
## so each region membership is LINEAR per quarter); clip each quarter by both memberships, shoelace.
static func _slope_horizontal_contact(mod_a: int, mod_b: int) -> float:
	var sq := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var ctr := Vector2(0.5, 0.5)
	var total := 0.0
	for i in 4:
		var quad: Array = [sq[i], sq[(i + 1) % 4], ctr]
		quad = _clip_membership(quad, mod_a, true)    # lower top-reaching
		quad = _clip_membership(quad, mod_b, false)   # upper bottom-reaching
		total += _poly_area(quad)
	return total

## Signed membership of (fx,fz) in a cell's shared-face-reaching region (≥ 0 inside). is_lower →
## top-reaching (reaches y=1); else bottom-reaching (reaches y=0). Linear within a quarter-triangle.
static func _membership(m: int, is_lower: bool, fx: float, fz: float) -> float:
	if m == 0:
		return 1.0                                    # full cube reaches both faces everywhere
	if CellCodec.is_slope(m):
		var val := _plane_at(CellCodec.slope_deltas(m), fx, fz)
		return (val - 1.0) if is_lower else (val - _EPS)   # D ≥ 1 (top) / D > 0 (bottom)
	var anc := anchor(m)
	var h := _height_half(corners(m), fx, fz) * 0.5   # blocks
	if is_lower:
		return 1.0 if anc == ANCHOR_TOP else (h - 1.0)     # TOP hangs (reaches top); BOTTOM: H ≥ 1
	return (h - 1.0) if anc == ANCHOR_TOP else 1.0         # TOP bottom region {H=1}; BOTTOM: whole face

## Sutherland–Hodgman clip of a convex polygon by {membership ≥ 0} (linear within a quarter).
static func _clip_membership(poly: Array, m: int, is_lower: bool) -> Array:
	if poly.size() < 3:
		return []
	var out: Array = []
	var n := poly.size()
	for i in n:
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[(i + 1) % n]
		var sc := _membership(m, is_lower, cur.x, cur.y)
		var sn := _membership(m, is_lower, nxt.x, nxt.y)
		if sc >= 0.0:
			out.append(cur)
		if (sc >= 0.0) != (sn >= 0.0):
			var t := sc / (sc - sn)
			out.append(cur + (nxt - cur) * t)
	return out

## Shoelace area of a simple XZ polygon.
static func _poly_area(poly: Array) -> float:
	if poly.size() < 3:
		return 0.0
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5
