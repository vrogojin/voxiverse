class_name CosmosChart
extends RefCounted
## COSMOS M2 — the floating-origin chart (docs/COSMOS-PLANET-TOPOLOGY.md §3.1/§3.2/§3.3).
##
## Window (scene/gameplay) space is a PURE INTEGER TRANSLATION of one cube face's index space:
##   (x, y, z) = (i − i_org, r, j − j_org)                                        (§3.1)
## where `(i_org, j_org)` is the floating-origin cell (L1-owned integers) and `r` is the radial
## layer (window y IS the global r directly — r ∈ [−64, +512] is always f32-safe, so the radial
## axis never re-anchors). Within the home face the window↔global fold is the IDENTITY (M2 plays a
## single face); the edge unfold arrives in M3 (§4.3). This class owns only that integer bijection
## and the re-anchor, so it is pure, deterministic, and testable WITHOUT flipping FLAT_WORLD.
##
## Re-anchoring (§3.2) is the whole floating-origin mechanism: an EXACT INTEGER origin shift —
## `(i_org, j_org) += Δ`, and the caller subtracts Δ from every window-space position (player,
## render nodes, column bookkeeping). Because the global identity `i = i_org + x` is invariant
## (Δ is added to i_org and subtracted from x in the same step), the WORLD position is continuous
## (no teleport, exact in f64) and every existing edit stays addressable by its UNCHANGED global
## key (§1.3). Pop = 0, restream = 0 — intra-face travel never re-projects the lattice (§3.2).
##
## Precision (§3.2): after a shift the local origin sits under the player, so |local| stays inside
## a few hundred metres even 5–10 km along the face (where an un-anchored window coordinate of
## ~10 km would carry an f32 ULP of ~1.2 mm); the reanchored band keeps the scene ULP sub-0.1 mm.

## The horizontal window distance (blocks) past which we re-anchor. Hysteretic: after a shift the
## new origin is the cell under the player, so |local| resets to [0, 1) and cannot re-trigger for
## another SHIFT_TRIGGER blocks of travel (§3.2). 256 = RENDER_RADIUS_BLOCKS keeps the L1 contract
## uniform between surface and space modes even though f32 would tolerate the full ~10 km face.
const SHIFT_TRIGGER := 256

var body: String        # which walkable body's lattice (§1.1 table): earth/mars/mercury/moon
var face: int           # the home cube face the window lives on (§3.5: face 4 for the M1/M2 demo)
var i_org: int          # floating-origin cell i (integer, L1-owned)
var j_org: int          # floating-origin cell j
var n: int              # cells per face edge for `body` (cached)
var radius: int         # datum radius R in blocks for `body` (cached)

## COSMOS-FRAME-ORIENTATION §5.1 — the PERSISTENT WINDOW ORIENTATION `M_win ∈ C4` (a 2×2 integer
## D4 rotation, det +1), row-major [[a,b],[c,d]]. It redefines the window↔raw-index bijection
## `p = org + M_win·w` so the SCENE renders in the master face's orientation for the whole session:
## a flip accumulates the crossed edge's fold matrix (`M_win ← M_f·M_win`) instead of letting the
## window silently re-base onto a rotated neighbour lattice. Result: flips AND reanchors are BOTH
## pure translations of every node → retained covers/debris/player stay aligned by construction
## (bug #2 fix). `M_win = I` at spawn on the master face 4, and every formula reduces to today's
## identity mapping when `M_win = I` → the flat world and the pre-fix curved spawn are byte-identical.
var mw_a: int = 1       # M_win = [[mw_a, mw_b], [mw_c, mw_d]]; identity at spawn
var mw_b: int = 0
var mw_c: int = 0
var mw_d: int = 1

func _init(p_body: String = CubeSphere.HOME_BODY, p_face: int = CubeSphere.HOME_FACE,
		p_i_org: int = 0, p_j_org: int = 0) -> void:
	body = p_body
	face = p_face
	i_org = p_i_org
	j_org = p_j_org
	n = CubeSphere.n_for(body)
	radius = CubeSphere.radius_for(body)

# ---------------------------------------------------------------------------------------
# M_win — the window orientation bijection (COSMOS-FRAME-ORIENTATION §5.1). p = org + M_win·w.
# M_win ∈ C4 is orthogonal with det +1, so M_win⁻¹ = M_winᵀ = [[a,c],[b,d]] (exact integers).
# ---------------------------------------------------------------------------------------

## The window cell (x, z) → its RAW home-face index (i, j) = org + M_win·w. THE single conversion
## every window→face-index consumer routes through (§5.3), so the orientation lives in ONE place.
## M_win = I → (i_org + x, j_org + z), byte-identical to the pre-fix convention.
func raw_of(x: int, z: int) -> Vector2i:
	return Vector2i(i_org + mw_a * x + mw_b * z, j_org + mw_c * x + mw_d * z)

## Inverse: a RAW home-face index (i, j) → the window cell (x, z) = M_win⁻¹·(p − org). Uses the
## transpose (M_win is an orthogonal det+1 integer matrix). M_win = I → (i − i_org, j − j_org).
func window_of(gi: int, gj: int) -> Vector2i:
	var pi := gi - i_org
	var pj := gj - j_org
	return Vector2i(mw_a * pi + mw_c * pj, mw_b * pi + mw_d * pj)

## COSMOS M5c (docs/COSMOS-M5C-CORNER.md §1) — CONTINUOUS float twins of raw_of / window_of. The corner
## math works in the continuous raw home-face frame (p = org + M_win·w), never on window (x,z) directly
## (M_win rotates the window). M_win is orthonormal integer so both are exact under f64.
func raw_of_f(x: float, z: float) -> Vector2:
	return Vector2(float(i_org) + float(mw_a) * x + float(mw_b) * z,
		float(j_org) + float(mw_c) * x + float(mw_d) * z)

## Inverse float twin: continuous raw (px, pz) → window (x, z) = M_win⁻¹·(p − org) (transpose form).
func window_of_f(px: float, pz: float) -> Vector2:
	var pi := px - float(i_org)
	var pj := pz - float(j_org)
	return Vector2(float(mw_a) * pi + float(mw_c) * pj, float(mw_b) * pi + float(mw_d) * pj)

## The render node's world-space origin: a node whose local coords are the ROTATED raw index
## `v = M_win⁻¹·p` must sit at position `−M_win⁻¹·org` so that scene(window) x,z == world x,z
## (scene == window preserved). M_win = I → (−i_org, 0, −j_org), today's node position exactly.
func node_origin() -> Vector3:
	return Vector3(-(mw_a * i_org + mw_c * j_org), 0.0, -(mw_b * i_org + mw_d * j_org))

## The 4 ints of M_win (row-major [a,b,c,d]) — for the generator epoch freeze (`gen_mwin`, §5.1)
## and the M-algebra gates. det is always +1.
func m_win() -> Array:
	return [mw_a, mw_b, mw_c, mw_d]

# ---------------------------------------------------------------------------------------
# The window↔global bijection (§3.1/§4.3). Identity fold within the home face; the EDGE UNFOLD
# (M3, §4.2/§4.3) folds a window cell that spilled past a face edge onto the true neighbour face
# via CubeSphere.fold_cell, so an edit made just across an edge is found again by its global
# (neighbour-face) key from a window homed on either side. Corner quadrants (out of range in BOTH
# axes) fold CANONICALLY (COSMOS-CORNER-CANONICAL #69): fold_cell returns face −1 there, but
# to_global_column routes through fold_cell_canonical → the nearest REAL cell of the physical
# direction (position-only, home-face-independent, real terrain — §8.2). flip() still refuses the
# quadrant; M5 later refines the corner's render placement + edit policy.
# ---------------------------------------------------------------------------------------

## Window column (x, z) → the TRUE global column {face, i, j}, folded across an edge if it spilled
## past one (§4.3). THE column projection the analytic curved-render callers use to resolve a
## window position to its global cell. In-range is the identity (home face).
func to_global_column(x: int, z: int) -> Dictionary:
	# COSMOS-CORNER-CANONICAL (#69): fold to the CANONICAL true global column — single-edge strips use the
	# exact D4 fold, the corner quadrant resolves to the nearest REAL cell of its physical direction
	# (position-only, home-face-INDEPENDENT). Never returns face −1. to_global / to_global_key /
	# to_region_key / world_point_of inherit this, so a wedge cell resolves + keys identically from any
	# window/epoch (§8.2). chart.flip below keeps plain fold_cell, so a flip INSIDE the quadrant is still
	# refused (the M5 hysteresis guard — that is a topology decision, not a content one).
	# COSMOS-FRAME-ORIENTATION §5.3: window→raw index routes through M_win (raw_of); identity when M_win=I.
	var p := raw_of(x, z)
	return CubeSphere.fold_cell_canonical(face, p.x, p.y, n)

## Window cell → global cell {face, i, j, r}. Folds the (i, j) across a face edge (§4.3); r = y is
## the radial layer (unfolded — the third axis is radial, §3.3).
func to_global(cell: Vector3i) -> Dictionary:
	var c := to_global_column(cell.x, cell.z)
	return {"face": int(c["face"]), "i": int(c["i"]), "j": int(c["j"]), "r": cell.y}

## Window cell → the 43-bit global edit key (§1.3). O(1) on the home face, one table lookup in an
## edge strip. THE key the `_edits` overlay stores in curved mode so an edit is found again by its
## global identity across any re-anchor, edge crossing, or home-face flip.
func to_global_key(cell: Vector3i) -> int:
	var c := to_global_column(cell.x, cell.z)
	return CubeSphere.edit_key(int(c["face"]), int(c["i"]), int(c["j"]), cell.y)

## Window cell → the per-(face, region_i, region_j, region_r) region key (§1.3): every cell in one
## 32³ ZoneChunk region shares it. Folds across an edge so a region key names the TRUE face.
func to_region_key(cell: Vector3i) -> int:
	var c := to_global_column(cell.x, cell.z)
	return CubeSphere.region_key(int(c["face"]), int(c["i"]), int(c["j"]), cell.y)

## The exact body-frame world point (f64 DVec3) of a window cell — P = (R + r)·d̂ (§1.2), folded to
## the true global cell across an edge. Used by verify to prove the re-anchor / home-face flip is
## teleport-free (the same physical cell has one world point from any window that reaches it).
func world_point_of(cell: Vector3i) -> CubeSphere.DVec3:
	var c := to_global_column(cell.x, cell.z)
	return CubeSphere.world_point(int(c["face"]), float(int(c["i"])), float(int(c["j"])),
		float(cell.y), float(radius), n)

## Inverse of `to_global_column` for the current window: a TRUE global column {face, i, j} → the
## window cell (x, z) that reaches it, folding a neighbour-face column back into the extended
## window (§4.3). Returns {found, x, z}. Used to place a neighbour-face edit into the window-space
## render/collider views. found=false for a column outside the extended window / a corner quadrant.
func window_of_global(gface: int, gi: int, gj: int) -> Dictionary:
	var w := CubeSphere.unfold_to_window(face, gface, gi, gj, n)
	if not bool(w["found"]):
		return {"found": false, "x": 0, "z": 0}
	# COSMOS-FRAME-ORIENTATION §5.3: raw index → window via M_win⁻¹ (window_of); identity when M_win=I.
	var win := window_of(int(w["i"]), int(w["j"]))
	return {"found": true, "x": win.x, "z": win.y}

# ---------------------------------------------------------------------------------------
# Re-anchoring — the integer origin shift (§3.2).
# ---------------------------------------------------------------------------------------

## True if the local (window) horizontal position warrants a re-anchor (|x| or |z| past the
## hysteretic trigger). Radial y never enters — r is bounded and always f32-safe.
func needs_reanchor(local: Vector3) -> bool:
	return absf(local.x) > float(SHIFT_TRIGGER) or absf(local.z) > float(SHIFT_TRIGGER)

## Re-anchor so the local origin sits under `local`. Returns the INTEGER shift Δ = (Δi, Δj) applied
## to (i_org, j_org); the CALLER must subtract Vector3(Δi, 0, Δj) from every window-space position
## it owns (player, render nodes, column-keyed bookkeeping) so the world stays continuous. Δ is
## exactly floor(local horizontal), so the post-shift local lands in [0, 1) — maximally f32-safe.
##
## TELEPORT-FREE (the invariant verify pins): global i = i_org + x. After the shift i_org' =
## i_org + Δi and the caller sets x' = x − Δi, so i' = i_org' + x' = i_org + x is unchanged; the
## world point P = (R + r)·d̂(face, i, j) is therefore identical in f64. Edits (global-keyed) are
## untouched — their keys don't move when the origin does.
func reanchor(local: Vector3) -> Vector2i:
	var di := int(floor(local.x))
	var dj := int(floor(local.z))
	# COSMOS-FRAME-ORIENTATION §5.1: the origin moves by M_win·Δ (raw-index space) while the caller
	# still subtracts the WINDOW Δ from window positions — so every node stays a pure −Δ translation
	# (node_origin shifts by exactly −Δ) and M_win is untouched. M_win = I → i_org+=di, j_org+=dj.
	i_org += mw_a * di + mw_b * dj
	j_org += mw_c * di + mw_d * dj
	return Vector2i(di, dj)

# ---------------------------------------------------------------------------------------
# The home-face flip (§4.5) — re-basing the window onto the neighbour face after the player
# crosses an edge. Hysteretic: the flip fires only once the player is FLIP_HYST cells PAST the
# edge (so oscillating along a seam never flips); flipping back is symmetric because the new home
# face contains the whole region in range, so the return crossing must again reach FLIP_HYST past.
# ---------------------------------------------------------------------------------------

## Cells past a face edge the player must travel before the home face flips (§4.5 hysteresis band).
const FLIP_HYST := 64

## True if the player at window `local` is ≥ FLIP_HYST cells PAST a face edge — i.e. the global
## column on the current home face has run out of [0, N) by more than the hysteresis (§4.5). The
## flip is deferred this far so play continues on the extended window across the seam with no event.
## `hyst` defaults to FLIP_HYST; COSMOS M5c (§4) passes FLIP_HYST_CORNER inside the corner zone so the
## player re-homes almost immediately after an edge crossing near a vertex (flipping early is an exact
## isometry, never wrong). Body otherwise unchanged.
func flip_needed(local: Vector3, hyst: int = FLIP_HYST) -> bool:
	# COSMOS-FRAME-ORIENTATION §5.3: the out-of-range test is on the RAW index (org + M_win·w), so
	# route through raw_of. M_win = I → (i_org + floor x, j_org + floor z), today's test exactly.
	var p := raw_of(int(floor(local.x)), int(floor(local.z)))
	return p.x >= n + hyst or p.x < -hyst or p.y >= n + hyst or p.y < -hyst

## Perform the home-face flip: fold the player's out-of-range global column to the true neighbour
## face and re-base the window onto it, KEEPING the player's window position unchanged so the world
## position is continuous (no teleport). Returns {ok, from_face, to_face}. The caller HARD-RESTREAMS
## the local region (the render nodes carried the old face's content) — edits are global-keyed so
## they re-materialise unchanged, and a subsequent maybe_reanchor brings the (now large) local band
## back to origin. A corner quadrant (fold face −1) is refused (M5) → {ok:false}.
func flip(local: Vector3) -> Dictionary:
	var wx := int(floor(local.x))
	var wz := int(floor(local.z))
	# The player's RAW home-face index p_p = org + M_win·w_p (raw_of), then folded to the neighbour.
	var p := raw_of(wx, wz)
	var gi := p.x
	var gj := p.y
	var g := CubeSphere.fold_cell(face, gi, gj, n)
	var b := int(g["face"])
	if b < 0:
		return {"ok": false, "from_face": face, "to_face": face}   # corner quadrant — M5
	var from_face := face
	# COSMOS-FRAME-ORIENTATION §5.1: ACCUMULATE the crossed edge's D4 fold matrix M_f into M_win
	# (M_win ← M_f·M_win) instead of letting the window silently re-base onto the rotated neighbour
	# lattice. The (★)-algebra (§2) then makes the window coordinate of EVERY physical cell continuous
	# across the flip — the scene frame does not rotate — so covers/debris/player need no compensation
	# (Fix A #71 deletes; its D4 extraction survives HERE as the accumulation step). M_f = edge_remap's
	# affine linear part [[m0,m1],[m2,m3]] (the exact matrix fold_cell applies), det +1 on every edge.
	var side := CubeSphere.SIDE_EAST
	if gi >= n:
		side = CubeSphere.SIDE_EAST
	elif gi < 0:
		side = CubeSphere.SIDE_WEST
	elif gj >= n:
		side = CubeSphere.SIDE_NORTH
	else:
		side = CubeSphere.SIDE_SOUTH
	var m: Array = CubeSphere.edge_remap(face, side, n)["m"]
	# M_win_new = M_f · M_win_old (row-major 2×2 integer product).
	var na := int(m[0]) * mw_a + int(m[1]) * mw_c
	var nb := int(m[0]) * mw_b + int(m[1]) * mw_d
	var nc := int(m[2]) * mw_a + int(m[3]) * mw_c
	var nd := int(m[2]) * mw_b + int(m[3]) * mw_d
	mw_a = na; mw_b = nb; mw_c = nc; mw_d = nd
	# Re-base the origin so the player's window cell (wx, wz) still maps to the SAME true global cell
	# (b, g.i, g.j): org ← g_p − M_win_new·w_p. Then raw_of(wx,wz) = g_p on face b → identity fold →
	# the player does not move, and by (★)-algebra every other window cell is continuous too.
	face = b
	i_org = int(g["i"]) - (mw_a * wx + mw_b * wz)
	j_org = int(g["j"]) - (mw_c * wx + mw_d * wz)
	return {"ok": true, "from_face": from_face, "to_face": b}
