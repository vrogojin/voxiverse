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
# The window↔global bijection (§3.1). Identity fold within the home face (M2); M3 adds the
# edge unfold for cells that spill past a face edge.
# ---------------------------------------------------------------------------------------

## Window cell → global cell {face, i, j, r}. i = i_org + x, j = j_org + z, r = y.
func to_global(cell: Vector3i) -> Dictionary:
	return {"face": face, "i": i_org + cell.x, "j": j_org + cell.z, "r": cell.y}

## Window cell → the 43-bit global edit key (§1.3). O(1); THE key the `_edits` overlay stores in
## curved mode so an edit is found again by its global identity across any re-anchor / home face.
func to_global_key(cell: Vector3i) -> int:
	return CubeSphere.edit_key(face, i_org + cell.x, j_org + cell.z, cell.y)

## Window cell → the per-(face, region_i, region_j, region_r) region key (§1.3): every cell in one
## 32³ ZoneChunk region shares it. Extends `region_origin_of` / the ZoneChunk store to the sphere.
func to_region_key(cell: Vector3i) -> int:
	return CubeSphere.region_key(face, i_org + cell.x, j_org + cell.z, cell.y)

## The exact body-frame world point (f64 DVec3) of a window cell — P = (R + r)·d̂ (§1.2). Used by
## verify to prove the re-anchor is teleport-free (the world point is invariant across a shift).
func world_point_of(cell: Vector3i) -> CubeSphere.DVec3:
	return CubeSphere.world_point(face, float(i_org + cell.x), float(j_org + cell.z),
		float(cell.y), float(radius), n)

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
