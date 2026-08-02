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
##     returns that vertex + its shading inputs, sampled through the EXACT chain the shipped far-ring emit uses
##     (`facet_far_ring.gd:1363`: bilerp planar corners → normalize → `profile_at_dir` at R_BLOCKS → relief), so
##     a smooth-tier vertex COINCIDES with the heightfield vertex at any shared node ⇒ welds to the shipped shell
##     and to same-pitch neighbours by construction (§2.4).
##   • COMPLEX (edit-cluster occupancy, Item B4 `FP_FAR_SMOOTH_OVERHANG`): `occ_at` — solid fraction of a cell's
##     underlying blocks (terrain + edit overlay, EXCLUDING TreeGen). STUB here (B1 ships the simple path only);
##     the mesher's vertical edge-scan plugs into it unchanged when B4 lands.
##
## B1 SCOPE: this module + the surface-net mesher (`facet_smooth_tier.gd`) are FOUNDATION only — nothing in the
## running engine calls them (byte-identical, inert). The render driver/LRU/swap arrive in B2 behind the flag.

## Blocks of radial relief per (g − SEA_LEVEL). MUST mirror `FacetFarRing.RELIEF` (:28) — the smooth tier places
## vertices on the SAME radial law as the heightfield emit, or the two would not weld at the tier hand-off.
const RELIEF := 1.0

## The simple-path node record for facet-param (s, t) ∈ [0,1]² over the tile whose 4 planar corners are `corners`
## (each an `[x,y,z]` Array from `FacetAtlas.facet_planar_corner`, ABSOLUTE planet-block coords — the far ring's
## own frame). Returns:
##   pos    : Vector3 world vertex = planar + dir·relief  (the radial surface point — identical to the emit)
##   dir    : Vector3 outward unit radial at this node    (for the ε-sink, normal orientation, skirt drop)
##   planar : Vector3 the un-relieved plane point         (skirt/weld reference)
##   g      : int  ground cell height (blocks)            (G-FS-BOUND range check, LOD chord-snap)
##   biome  : int  · temp : float                         (skin colour via FarPalette.color_for)
##   relief : float radial displacement (blocks)          (degeneracy check, chord-snap)
static func node_at(corners: Array, s: float, t: float) -> Dictionary:
	var c0: Array = corners[0]
	var c1: Array = corners[1]
	var c2: Array = corners[2]
	var c3: Array = corners[3]
	var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
	var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
	var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
	var ln := sqrt(bx * bx + by * by + bz * bz)
	# Degenerate guard (a corner exactly at the planet centre is impossible, but keep the mesher total): a zero-
	# length node has no radial ⇒ treat as up +Y so the tile still tessellates rather than emitting NaNs.
	var dx := 0.0
	var dy := 1.0
	var dz := 0.0
	if ln > 0.0:
		dx = bx / ln
		dy = by / ln
		dz = bz / ln
	var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
	var g := int(prof.x)
	var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
	return {
		"pos": Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief),
		"dir": Vector3(dx, dy, dz),
		"planar": Vector3(bx, by, bz),
		"g": g,
		"biome": int(prof.y),
		"temp": prof.w,
		"relief": relief,
	}

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
