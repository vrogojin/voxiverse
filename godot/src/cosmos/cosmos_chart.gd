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

func _init(p_body: String = CubeSphere.HOME_BODY, p_face: int = CubeSphere.HOME_FACE,
		p_i_org: int = 0, p_j_org: int = 0) -> void:
	body = p_body
	face = p_face
	i_org = p_i_org
	j_org = p_j_org
	n = CubeSphere.n_for(body)
	radius = CubeSphere.radius_for(body)

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
	return CubeSphere.fold_cell_canonical(face, i_org + x, j_org + z, n)

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
	return {"found": true, "x": int(w["i"]) - i_org, "z": int(w["j"]) - j_org}

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
	i_org += di
	j_org += dj
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
func flip_needed(local: Vector3) -> bool:
	var gi := i_org + int(floor(local.x))
	var gj := j_org + int(floor(local.z))
	return gi >= n + FLIP_HYST or gi < -FLIP_HYST or gj >= n + FLIP_HYST or gj < -FLIP_HYST

## Perform the home-face flip: fold the player's out-of-range global column to the true neighbour
## face and re-base the window onto it, KEEPING the player's window position unchanged so the world
## position is continuous (no teleport). Returns {ok, from_face, to_face}. The caller HARD-RESTREAMS
## the local region (the render nodes carried the old face's content) — edits are global-keyed so
## they re-materialise unchanged, and a subsequent maybe_reanchor brings the (now large) local band
## back to origin. A corner quadrant (fold face −1) is refused (M5) → {ok:false}.
func flip(local: Vector3) -> Dictionary:
	var wx := int(floor(local.x))
	var wz := int(floor(local.z))
	var g := CubeSphere.fold_cell(face, i_org + wx, j_org + wz, n)
	var b := int(g["face"])
	if b < 0:
		return {"ok": false, "from_face": face, "to_face": face}   # corner quadrant — M5
	var from_face := face
	# Re-base: window (wx, wz) must map to the same true global cell (b, gi, gj) on the new face, so
	# the player does not move. On the new home face b the fold is the identity in range, so choosing
	# i_org' = gi − wx, j_org' = gj − wz makes window (wx, wz) → (b, gi, gj) exactly.
	face = b
	i_org = int(g["i"]) - wx
	j_org = int(g["j"]) - wz
	return {"ok": true, "from_face": from_face, "to_face": b}
