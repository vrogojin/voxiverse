class_name FacetSmoothTier
extends RefCounted
## COSMOS FAR-RENDER-OVERHAUL §2 (docs/COSMOS-FAR-RENDER-OVERHAUL-DESIGN.md) — SMOOTH far-terrain geometry
## (Item B, `FP_FAR_SMOOTH`). Naive Surface Nets (§2.2) over the `FarDensity` source: rounded mountains and
## (with B4) dug overhangs where the shipped far ring shows flat 26-104-block heightfield cells or blocky LOD
## megablocks. Painted by the SAME map skin as the heightfield (§2.6) — the smooth vertices carry the identical
## UV/UV2 attributes, so band → fine → base resolves with zero B-specific shader work beyond the normal swap.
##
## B1 SCOPE (this file today): the pure MESHER — `build_tile(fid, cells)` turns one (facet, tier) tile into an
## ArrayMesh-ready surface (pos/nrm/col/uv/uv2/idx), plus the tier consts and the byte ledger. NO render driver,
## NO LRU, NO worker dispatch, NO edit invalidation — those are B2/B3 (they clone the shipped `_pbm_*` slot +
## `_async_build_worker`/`_swap_in_arrays` patterns). Nothing in the running engine constructs a FacetSmoothTier
## yet ⇒ byte-identical, inert (FLAT 6042/0).
##
## HEIGHTFIELD DEGENERACY (§2.2): on the simple `FarDensity` path the density is a graph over the facet plane, so
## the surface net collapses to ONE vertex per column at the relief height — a smooth displaced grid. `build_tile`
## implements exactly that (the general edit-occupancy edge-scan plugs in at B4). This is why G-FS-DEGEN can assert
## `tris == 2·cells²` and radial normals on a flat facet: the net never hallucinates volume geometry.

# --- tier ladder (§2.4). cells-per-facet-edge per tier; MAX = residency cap (facets held resident at that tier) ---
# The pitch (blocks) is informational — the tile is tessellated at `cells` nodes/edge so a flat facet gives exactly
# 2·cells² tris. Real facet edges are ~417 blocks (K=24), so these match the design table's 4/8/16/32-block pitches.
enum { S2 = 0, S3 = 1, S4 = 2, S5 = 3 }

## cells-per-edge for a tier index (S2..S5). Reads the CubeSphere consts so the deploy sed / gate share one source.
static func cells_for_tier(tier: int) -> int:
	match tier:
		S2: return CubeSphere.SMOOTH_S2_CELLS
		S3: return CubeSphere.SMOOTH_S3_CELLS
		S4: return CubeSphere.SMOOTH_S4_CELLS
		_: return CubeSphere.SMOOTH_S5_CELLS

## residency cap (max facets held resident) for a tier index — NEVER-OOM: fixed at creation, enforced by the LRU (B3).
static func residency_for_tier(tier: int) -> int:
	match tier:
		S2: return CubeSphere.SMOOTH_S2_MAX
		S3: return CubeSphere.SMOOTH_S3_MAX
		S4: return CubeSphere.SMOOTH_S4_MAX
		_: return CubeSphere.SMOOTH_S5_MAX

## Build the smooth-tier surface for facet `fid` at `cells` cells-per-edge. Returns the packed arrays an ArrayMesh
## surface wants, all in ABSOLUTE planet-block coords (the far ring's frame — parented under its node so
## `shift_anchor`/`_placement_xform` apply unchanged). PURE + worker-safe (only FarDensity/FarPalette static reads).
##   pos : PackedVector3Array  (cells+1)²          nrm : PackedVector3Array density-gradient normals
##   col : PackedColorArray    skin fallback tint  uv  : PackedVector2Array ((a+s)/K,(b+t)/K) facet param
##   uv2 : PackedVector2Array  (face, slot)        idx : PackedInt32Array   2 tris/cell, front = outward
## `slot` is written −1 here (B1: skin binding is B2's job — the driver stamps the real close-up/band/base slot then).
static func build_tile(fid: int, cells: int) -> Dictionary:
	FarPalette.ensure_ready()
	var corners := [
		FacetAtlas.facet_planar_corner(fid, 0),
		FacetAtlas.facet_planar_corner(fid, 1),
		FacetAtlas.facet_planar_corner(fid, 2),
		FacetAtlas.facet_planar_corner(fid, 3),
	]
	var dec := _decode(fid)
	var face := int(dec[0])
	var a := int(dec[1])
	var b := int(dec[2])
	var kb := int(dec[3])
	var stride := cells + 1
	var n := stride * stride

	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	pos.resize(n)
	nrm.resize(n)
	col.resize(n)
	uv.resize(n)
	uv2.resize(n)
	# `dir` is kept only to orient the normals outward — not returned.
	var dirs := PackedVector3Array()
	dirs.resize(n)

	var inv := 1.0 / float(cells)
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var node := FarDensity.node_at(corners, s, t)
			var vi := gj * stride + gi
			pos[vi] = node["pos"]
			dirs[vi] = node["dir"]
			var g := int(node["g"])
			col[vi] = FarPalette.color_for(g, int(node["biome"]), float(node["temp"]), g < TerrainConfig.SEA_LEVEL)
			uv[vi] = Vector2((float(a) + s) / float(kb), (float(b) + t) / float(kb))
			uv2[vi] = Vector2(float(face), -1.0)

	# Per-vertex normal = normalized cross of the world-space tangents (central differences of the displaced grid
	# = the density gradient on a heightfield, §2.5), oriented outward (dot with the radial dir). On a flat facet
	# the tangents are the facet plane ⇒ the normal is radial (G-FS-DEGEN).
	for gj in range(stride):
		for gi in range(stride):
			var vi := gj * stride + gi
			var i0 := gi - 1 if gi > 0 else gi
			var i1 := gi + 1 if gi < cells else gi
			var j0 := gj - 1 if gj > 0 else gj
			var j1 := gj + 1 if gj < cells else gj
			var ts := pos[gj * stride + i1] - pos[gj * stride + i0]
			var tt := pos[j1 * stride + gi] - pos[j0 * stride + gi]
			var nv := ts.cross(tt)
			if nv.length_squared() <= 0.0:
				nv = dirs[vi]
			nv = nv.normalized()
			if nv.dot(dirs[vi]) < 0.0:
				nv = -nv
			nrm[vi] = nv

	var idx := PackedInt32Array()
	idx.resize(cells * cells * 6)
	var ii := 0
	for gj in range(cells):
		for gi in range(cells):
			var v00 := gj * stride + gi
			var v10 := v00 + 1
			var v01 := v00 + stride
			var v11 := v01 + 1
			# front (outward) winding: cross(v10−v00, v11−v10) aligns with the outward normal above.
			idx[ii] = v00; idx[ii + 1] = v10; idx[ii + 2] = v11
			idx[ii + 3] = v00; idx[ii + 4] = v11; idx[ii + 5] = v01
			ii += 6

	return {"pos": pos, "nrm": nrm, "col": col, "uv": uv, "uv2": uv2, "idx": idx}

## Resident byte cost of a built tile (§2.7 ledger, `SMOOTH_BYTES_MAX`). pos/nrm 12 B each, col 16 B, uv/uv2 8 B
## each, idx 4 B — the ArrayMesh vertex-buffer footprint the LRU accounts against the NEVER-OOM cap.
static func tile_bytes(tile: Dictionary) -> int:
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	return nv * (12 + 12 + 16 + 8 + 8) + ni * 4

## Decode `fid` → [face, a, b, k] in its body-local (face,a,b) indexing — mirrors FacetTexBaker._decode so UV =
## ((a+s)/k,(b+t)/k) agrees with the band/fine skin and the far ring.
static func _decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]
