class_name FarDensity
extends RefCounted
## COSMOS FAR-RENDER-OVERHAUL §2.3 (docs/COSMOS-FAR-RENDER-OVERHAUL-DESIGN.md) — the density / radial-height
## SOURCE for the smooth far-terrain tiers (Item B, `FP_FAR_SMOOTH`). Pure + deterministic + worker-safe
## (only static TerrainConfig / FacetAtlas reads, no randi/Time, no mutable-global writes), so a given
## (facet, param) always yields the same node on every thread and every render path.
##
## TWO paths, one surface class (Naive Surface Nets, §2.2):
##   • SIMPLE (heightfield, the 99.99 % case): the far surface is the GRAPH of the column height over the facet
##     plane, so the "isosurface" is one vertex per column placed radially at the relief height. `node_at`
##     returns that vertex + its shading inputs, sampled through the EXACT chain FS1 welds with
##     (`facet_far_ring.gd:2914` `_weld_unit` precedent): bilerp the SHARED canon corner DIRECTIONS
##     (`FacetAtlas.facet_corner_dirs`) → normalize → `profile_at_dir` at the datum radius → relief. Unlike the
##     pre-P0 defect (bilerp the facet's OWN `facet_planar_corner` points then normalize — adjacent facets
##     disagree at a shared edge by the ∝R datum step, `facet_atlas.gd:420`), a boundary node's direction is now
##     a bilerp of the TWO shared canon corners only ⇒ two facets meeting at that edge compute the bit-identical
##     direction, hence the identical `g`/relief/pos there (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 2).
##   • COMPLEX (edit-cluster occupancy, Item B4 `FP_FAR_SMOOTH_OVERHANG`): `occ_at` — solid fraction of a cell's
##     underlying blocks (terrain + edit overlay, EXCLUDING TreeGen). STUB here (B1 ships the simple path only);
##     the mesher's vertical edge-scan plugs into it unchanged when B4 lands.
##
## B1 SCOPE: this module + the surface-net mesher (`facet_smooth_tier.gd`) are FOUNDATION only — nothing in the
## running engine calls them (byte-identical, inert). The render driver/LRU/swap arrive in B2 behind the flag.

## Blocks of radial relief per (g − SEA_LEVEL). MUST mirror `FacetFarRing.RELIEF` (:28) — the smooth tier places
## vertices on the SAME radial law as the heightfield emit, or the two would not weld at the tier hand-off.
const RELIEF := 1.0

## The simple-path node record for facet-param (s, t) ∈ [0,1]² over a tile whose 4 corners' SHARED canon
## directions are `corner_dirs` (`FacetAtlas.facet_corner_dirs(fid)` verbatim — 12 f64, CCW 00,10,11,01) at
## datum radius `r_datum` (`FacetAtlas.r_of(fid)`). COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 2 (P0): the node
## DIRECTION is the bilerp of these CANON corner dirs — NOT a normalize of bilerp'd `facet_planar_corner` points
## (the defect) — so a boundary node (s or t ∈ {0,1}) is a pure function of the two SHARED corner dirs on that
## edge, bit-identical regardless of which facet computed it. Returns:
##   pos    : Vector3 world vertex = planar + dir·relief = dir·(r_datum + relief)  (the radial surface point)
##   dir    : Vector3 outward unit radial at this node    (for the ε-sink, normal orientation, skirt drop)
##   planar : Vector3 the un-relieved base ALONG the canon dir (dir·r_datum)       (skirt/weld reference)
##   g      : int  ground cell height (blocks)            (G-FS-BOUND range check, LOD chord-snap)
##   biome  : int  · temp : float                         (skin colour via FarPalette.color_for)
##   relief : float radial displacement (blocks)          (degeneracy check, chord-snap)
static func node_at(corner_dirs: PackedFloat64Array, r_datum: float, s: float, t: float) -> Dictionary:
	var ex := _bilerp(corner_dirs[0], corner_dirs[3], corner_dirs[6], corner_dirs[9], s, t)
	var ey := _bilerp(corner_dirs[1], corner_dirs[4], corner_dirs[7], corner_dirs[10], s, t)
	var ez := _bilerp(corner_dirs[2], corner_dirs[5], corner_dirs[8], corner_dirs[11], s, t)
	var ln := sqrt(ex * ex + ey * ey + ez * ez)
	# Degenerate guard (a corner exactly at the planet centre is impossible, but keep the mesher total): a zero-
	# length node has no radial ⇒ treat as up +Y so the tile still tessellates rather than emitting NaNs.
	var dx := 0.0
	var dy := 1.0
	var dz := 0.0
	if ln > 0.0:
		dx = ex / ln
		dy = ey / ln
		dz = ez / ln
	var prof := TerrainConfig.profile_at_dir(dx, dy, dz, r_datum)
	var g := int(prof.x)
	var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
	var dir := Vector3(dx, dy, dz)
	var planar := dir * r_datum
	return {
		"pos": planar + dir * relief,
		"dir": dir,
		"planar": planar,
		"g": g,
		"biome": int(prof.y),
		"temp": prof.w,
		"relief": relief,
	}

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 3 (P0) — the facet-agnostic BOUNDARY normal: central differences
## of `profile_at_dir` in the CANONICAL tangent frame of `d` (a pure function of `d` alone — mirrors
## `FacetFarRing._env_corner_min`'s u/v construction, `facet_far_ring.gd:2456-2461`: pick the world axis LEAST
## aligned with `d`, Gram-Schmidt it off `d`, cross for the second tangent). Two facets sharing a boundary node
## have the identical canon `d` there (law 2) ⇒ this computes the IDENTICAL normal on both sides — no grid-index
## / facet-frame dependency, so the interior (grid cross-tangent stencil) / boundary (this) blend is invisible.
## Cost: 4 extra `profile_at_dir` calls (±tangent1, ±tangent2) — matches the design's stated budget.
const BOUNDARY_NORMAL_STEP := 1.0   # blocks — arc-length step for the central-difference tangent stencil
static func boundary_normal(d: Vector3, r_datum: float) -> Vector3:
	var ref := Vector3(0.0, 1.0, 0.0)
	if absf(d.y) >= absf(d.x) and absf(d.y) >= absf(d.z):
		ref = Vector3(1.0, 0.0, 0.0)                    # d ~ ±Y → use X so the cross stays well-conditioned
	var u := (ref - d * ref.dot(d)).normalized()
	var v := d.cross(u).normalized()
	var scale := BOUNDARY_NORMAL_STEP / r_datum          # angular offset ≈ tan θ for the small arc-length step
	var pu := _radial_at(d, u, scale, r_datum)
	var mu := _radial_at(d, u, -scale, r_datum)
	var pv := _radial_at(d, v, scale, r_datum)
	var mv := _radial_at(d, v, -scale, r_datum)
	var ts := pu - mu
	var tt := pv - mv
	var nv := ts.cross(tt)
	if nv.length_squared() <= 0.0:
		return d
	nv = nv.normalized()
	if nv.dot(d) < 0.0:
		nv = -nv
	return nv

## The radial surface point at direction `d` nudged toward `tangent` by `scale` (radians-ish, small-angle),
## renormalized onto the unit sphere then placed at its own true relief — one sample of the central-difference
## stencil `boundary_normal` uses.
static func _radial_at(d: Vector3, tangent: Vector3, scale: float, r_datum: float) -> Vector3:
	var sd := (d + tangent * scale).normalized()
	var prof := TerrainConfig.profile_at_dir(sd.x, sd.y, sd.z, r_datum)
	var g := int(prof.x)
	var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
	return sd * (r_datum + relief)

## COMPLEX path (Item B4) — solid fraction of the 2^level³ blocks under lattice cell `cell` on facet `fid`,
## from terrain + edit overlay, EXCLUDING TreeGen (trees are Item C). `d = 0.5 − occ` is the occupancy density
## the surface net contours to wrap dug arches / tunnel mouths. STUB: B1 ships the heightfield path only, so this
## asserts-off; the caller (`FacetSmoothTier`) never invokes it until `FP_FAR_SMOOTH_OVERHANG`. Documented here so
## the density contract is complete and B4 is a drop-in.
static func occ_at(_fid: int, _cell: Vector3i, _level: int, _edit_snap: Dictionary) -> float:
	assert(false, "FarDensity.occ_at is the B4 (FP_FAR_SMOOTH_OVERHANG) path — not wired in B1")
	return 1.0

## Bilinear over facet-param corners (v00,v10,v11,v01) at (s,t) — the SAME kernel FacetFarRing/_emit_cached and
## FacetTexBaker use, so a smooth-tier param maps identically to how the heightfield mesh maps a grid node.
static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t
