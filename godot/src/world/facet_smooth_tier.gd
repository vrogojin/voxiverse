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
## `slot` is written −1 here (B2 overlay: UV2.y=-1 ⇒ the shell shader's fine/base branch paints it — no band).
## `lift` (blocks) nudges every vertex radially outward: the B2 overlay draws the smooth mesh a hair ABOVE the
## flat heightfield so it occludes it (sub-pixel at far distance) until the emit-exclusion path lands (increment 2).
## `curved` places vertices on the CURVED SPHERE `dir·(R + relief)`. Historically (pre-P0) this differed from the
## `curved=false` branch, which placed vertices on the flat inscribed facet quad instead — the piecewise-flat
## quads ARE the facet-boundary crease (adjacent flat tangent planes meet at a dihedral angle even at sea level).
## Post-P0 (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 2) `FarDensity.node_at`'s own `pos`/`planar` are ALREADY
## the canon-dir radial placement (`dir·r_datum` + relief), so both branches now agree to float-associativity
## rounding only — the parameter/branch stay (call-site compatibility; the B2 worker always passes `true`).
## `normal_lit` (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P2, FP_SMOOTH_NORMAL_LIT): stamp alpha=0 on every
## vertex colour as the "this is a SMOOTH-TILE vertex" marker the shared shell shader's normal-lit branch
## keys off (`FacetFarRing._apply_smooth_normal_lit`). Defaults to the live flag (mirrors `_apply_shade_unified`'s
## `unified := CubeSphere.FP_SHADE_UNIFIED` pattern) so callers/gates can force it without toggling the const.
static func build_tile(fid: int, cells: int, lift: float = 0.0, curved: bool = false, normal_lit := CubeSphere.FP_SMOOTH_NORMAL_LIT) -> Dictionary:
	FarPalette.ensure_ready()
	var r_datum := FacetAtlas.r_of(fid)
	# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 2 (P0): the SHARED canon corner DIRECTIONS, not the facet's own
	# planarized corner points — `FarDensity.node_at` bilerps these so a boundary node welds bit-identically to
	# whichever facet is on the other side of the shared edge (`FacetAtlas.facet_corner_dirs`, `facet_atlas.gd:425`).
	var corner_dirs := FacetAtlas.facet_corner_dirs(fid)
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
			var node := FarDensity.node_at(corner_dirs, r_datum, s, t)
			var vi := gj * stride + gi
			var d: Vector3 = node["dir"]
			if curved:
				pos[vi] = d * (r_datum + float(node["relief"]) + lift)   # on the sphere → no dihedral crease across facets
			else:
				pos[vi] = (node["pos"] as Vector3) + d * lift            # node_at's own radial pos (B1 gate parity)
			dirs[vi] = d
			var g := int(node["g"])
			var vc := FarPalette.color_for(g, int(node["biome"]), float(node["temp"]), g < TerrainConfig.SEA_LEVEL)
			# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P2 (FP_SMOOTH_NORMAL_LIT): stamp alpha=0 as the per-vertex
			# "this is a SMOOTH-TILE vertex" marker the shared shell shader's normal-lit branch keys off
			# (`FacetFarRing._apply_smooth_normal_lit`, COLOR.a is unread by every existing shader consumer of
			# COLOR — only `.rgb` is ever taken). Off ⇒ alpha stays the FarPalette default (1.0), byte-identical
			# to the pre-P2 tiles.
			if normal_lit:
				vc.a = 0.0
			col[vi] = vc
			uv[vi] = Vector2((float(a) + s) / float(kb), (float(b) + t) / float(kb))
			uv2[vi] = Vector2(float(face), -1.0)

	# Per-vertex normal. INTERIOR (§2.5): normalized cross of the world-space tangents (central differences of the
	# displaced grid = the density gradient on a heightfield), oriented outward (dot with the radial dir). On a
	# flat facet the tangents are the facet plane ⇒ the normal is radial (G-FS-DEGEN). BOUNDARY (s or t ∈ {0,1},
	# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 3, P0): the OLD clamped-stencil here (`i0=gi` at gi==0, etc.)
	# is a one-sided in-tile difference — two facets sharing an edge would each clamp toward THEIR OWN interior
	# and generally compute DIFFERENT normals there (a shading seam once P2 lights by normal). Route boundary
	# nodes through `FarDensity.boundary_normal` instead — a pure function of the (already-welded, canon) `d`, so
	# both sides get the bit-identical value.
	for gj in range(stride):
		for gi in range(stride):
			var vi := gj * stride + gi
			var nv: Vector3
			if gi == 0 or gi == cells or gj == 0 or gj == cells:
				nv = FarDensity.boundary_normal(dirs[vi], r_datum)
			else:
				var ts := pos[gj * stride + gi + 1] - pos[gj * stride + gi - 1]
				var tt := pos[(gj + 1) * stride + gi] - pos[(gj - 1) * stride + gi]
				nv = ts.cross(tt)
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

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 / §2.1 (FP_SMOOTH_RIM) — the S2 NEAR-COLLAR builder. Same (cells+1)²
## grid / index winding / UV-UV2 skin law as `build_tile` above, but every vertex HEIGHT is envelope-inside-disc +
## feather + ε-sink instead of the plain true relief:
##   w    = clamp((|vertex − player_col| − r_env) / feather, 0, 1)     -- 0 strictly inside the disc, 1 past the feather
##   h(v) = lerp(env_pos(v), true_pos(v), w) − dir(v)·(sink · (1 − w))  -- the sink fades out exactly where w → 1
## `env_pos` is the SAME min-envelope lower bound the shipped backstop/coarse-horizon caches use
## (`FacetFarRing._env_weld_grid(fid, cells)`, reused verbatim — "don't reinvent it"): env_pos(v) ≤ true_pos(v)
## radially, by the SAME dilated-footprint-minimum construction proof the backstop already carries. A convex blend
## of two quantities that are both ≤ true, minus a non-negative sink, is still ≤ true — so the no-protrusion
## invariant holds BY CONSTRUCTION inside the disc (never by a tuned constant), which is what G-RIM-ENV proves.
## `player_col`/`r_env`/`feather`/`sink` are FROZEN inputs — the caller (`FacetSmoothTier`'s P1-instance worker glue)
## snapshots them ONCE per build batch (the same single-writer discipline `_snap_plan` already uses), so this is a
## PURE function of world position + these frozen scalars: two S2 tiles built in the SAME batch compute BIT-IDENTICAL
## values at any shared boundary vertex (already bit-identical there by the P0 canon weld) ⇒ the weld canon survives
## the blend (G-RIM-WELD). Past the feather (w=1, sink=0) this is EXACTLY `build_tile`'s plain true-height placement —
## an S2 tile's facet-edge boundary (almost always beyond R_env+feather in practice — the disc is ≤ ~160 blocks,
## the facet edge ~417) therefore already agrees with a neighbouring S3 tile's plain boundary before the frontier
## snap even runs (belt-and-suspenders on top of `snap_edge_to_pitch`).
static func build_tile_rim(fid: int, cells: int, player_col: Vector3, r_env: float, feather: float, sink: float, normal_lit := CubeSphere.FP_SMOOTH_NORMAL_LIT) -> Dictionary:
	FarPalette.ensure_ready()
	var r_datum := FacetAtlas.r_of(fid)
	var corner_dirs := FacetAtlas.facet_corner_dirs(fid)
	var dec := _decode(fid)
	var face := int(dec[0])
	var a := int(dec[1])
	var b := int(dec[2])
	var kb := int(dec[3])
	var stride := cells + 1
	var n := stride * stride

	# Reuse the shipped no-protrusion envelope law verbatim (§3 P3: "don't reinvent it") — the SAME cells-parametrized
	# min-envelope grid the coarse-horizon/dense-backstop caches build, made static so it is callable with no ring
	# instance (facet_far_ring.gd `_env_weld_grid`).
	var env := FacetFarRing._env_weld_grid(fid, cells)
	var env_pos: PackedVector3Array = env[0]

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
	var dirs := PackedVector3Array()
	dirs.resize(n)

	var feather_safe := maxf(feather, 0.001)
	var inv := 1.0 / float(cells)
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var node := FarDensity.node_at(corner_dirs, r_datum, s, t)
			var vi := gj * stride + gi
			var d: Vector3 = node["dir"]
			var true_pos: Vector3 = d * (r_datum + float(node["relief"]))
			var env_p: Vector3 = env_pos[vi]
			var dist := true_pos.distance_to(player_col)
			var w := clampf((dist - r_env) / feather_safe, 0.0, 1.0)
			var blended: Vector3 = env_p.lerp(true_pos, w)
			pos[vi] = blended - d * (sink * (1.0 - w))
			dirs[vi] = d
			var g := int(node["g"])
			var vc := FarPalette.color_for(g, int(node["biome"]), float(node["temp"]), g < TerrainConfig.SEA_LEVEL)
			if normal_lit:
				vc.a = 0.0
			col[vi] = vc
			uv[vi] = Vector2((float(a) + s) / float(kb), (float(b) + t) / float(kb))
			uv2[vi] = Vector2(float(face), -1.0)

	# Normals: identical law to `build_tile` — boundary via the canon `FarDensity.boundary_normal` (a pure function of
	# `d` alone), interior via the central-difference cross of the FINAL (blended) grid tangents, so a normal-lit
	# shade reads the ACTUAL collar surface (including the blend), not the unblended true relief.
	for gj in range(stride):
		for gi in range(stride):
			var vi := gj * stride + gi
			var nv: Vector3
			if gi == 0 or gi == cells or gj == 0 or gj == cells:
				nv = FarDensity.boundary_normal(dirs[vi], r_datum)
			else:
				var ts := pos[gj * stride + gi + 1] - pos[gj * stride + gi - 1]
				var tt := pos[(gj + 1) * stride + gi] - pos[(gj - 1) * stride + gi]
				nv = ts.cross(tt)
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
			idx[ii] = v00; idx[ii + 1] = v10; idx[ii + 2] = v11
			idx[ii + 3] = v00; idx[ii + 4] = v11; idx[ii + 5] = v01
			ii += 6

	return {"pos": pos, "nrm": nrm, "col": col, "uv": uv, "uv2": uv2, "idx": idx}

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 4 (P0, mixed pitch) — the COARSE-OWNS-EDGE chord-snap, generalized
## from the shipped `FacetFarRing._weld_snap_edges` (`facet_far_ring.gd:2939`, CELLS=4-only) to any tier pair on
## the ladder (S2/S3/S4/S5, and the S5→shipped-CELLS=4-shell frontier): a fine tile at `cells` sitting next to a
## coarser tile at `coarse_cells` (`cells` a whole multiple of `coarse_cells` — the ladder's node-superset property,
## 104=2·52=4·26=8·13) snaps every boundary vertex NOT already on the coarse lattice onto a straight-line lerp of
## its OWN coarse-index neighbours along that edge. Those coarse-index vertices already bit-match the coarse
## neighbour's own vertices there (law 2's canon-dir weld — same (canon dirs, r_datum, s, t) ⇒ same `node_at`), so
## the lerp reproduces the coarse tile's OWN straight polygon edge exactly ⇒ no crack at the mixed-pitch frontier.
## Mutates `pos` in place (mirrors the shipped in-place `_weld_snap_edges`). No-op if `coarse_cells` doesn't evenly
## divide `cells` or isn't strictly coarser (caller error guard — the ladder never calls it otherwise).
static func snap_edges_to_coarse(pos: PackedVector3Array, cells: int, coarse_cells: int) -> void:
	if coarse_cells <= 0 or coarse_cells >= cells or cells % coarse_cells != 0:
		return
	var cstride := cells / coarse_cells
	var stride := cells + 1
	for i in range(1, cells):
		if i % cstride == 0:
			continue                                     # already a coarse-index vertex — leave it exact
		var c0 := (i / cstride) * cstride                # lower coarse index on the edge
		var c1 := mini(c0 + cstride, cells)              # upper coarse index
		var lo := float(i - c0) / float(cstride)
		pos[i * stride + 0] = pos[c0 * stride + 0].lerp(pos[c1 * stride + 0], lo)             # West (gi=0)
		pos[i * stride + cells] = pos[c0 * stride + cells].lerp(pos[c1 * stride + cells], lo)  # East (gi=cells)
		pos[0 * stride + i] = pos[0 * stride + c0].lerp(pos[0 * stride + c1], lo)              # South (gj=0)
		pos[cells * stride + i] = pos[cells * stride + c0].lerp(pos[cells * stride + c1], lo)  # North (gj=cells)

# Tile-local edge selector (gi/gj grid sense — matches verify_far_smooth.gd's `_edge_indices` FA.slot convention:
# WEST=gi=0 ↔ FacetAtlas.S_WEST, EAST=gi=cells ↔ S_EAST, SOUTH=gj=0 ↔ S_SOUTH, NORTH=gj=cells ↔ S_NORTH).
enum { EDGE_WEST = 0, EDGE_EAST = 1, EDGE_SOUTH = 2, EDGE_NORTH = 3 }

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 4 (P1 generalization of the P0 `snap_edges_to_coarse` above) — snap
## ONE edge of a `cells`-resolution tile onto an ARBITRARY coarser reference pitch `pitch_cells` that need NOT
## evenly divide `cells`. This is the S5(13)→shipped-CELLS(4)-shell frontier case (13 isn't a multiple of 4, so the
## integer-ratio helper above no-ops there) — and, defensively, ANY tier tile whose neighbour is momentarily absent
## from the smooth-resident set (still shell) during ladder convergence (make-before-break window). Re-evaluates
## `FarDensity.node_at` at the reference pitch's OWN breakpoints — bit-consistent with what a tile actually built at
## that pitch (or the shipped shell, `_weld_place`/`_weld_unit`, same bilerp + same add-then-multiply order, P0
## canon) would place there — then piecewise-linearly interpolates this tile's non-breakpoint boundary nodes within
## their enclosing reference segment (same COARSE-OWNS-EDGE law, generalized off the integer-ratio assumption).
## No-op if `pitch_cells` isn't strictly coarser (the caller may call this unconditionally for all 4 edges; a
## same-or-finer neighbour is a no-op here — coarse-owns-edge means THAT side snaps toward `cells`, not vice versa).
static func snap_edge_to_pitch(pos: PackedVector3Array, cells: int, corner_dirs: PackedFloat64Array, r_datum: float, pitch_cells: int, edge: int) -> void:
	if pitch_cells <= 0 or pitch_cells >= cells:
		return
	var stride := cells + 1
	for i in range(1, cells):
		var u := float(i) / float(cells)
		var seg := clampi(int(floor(u * float(pitch_cells))), 0, pitch_cells - 1)
		var u0 := float(seg) / float(pitch_cells)
		var u1 := float(seg + 1) / float(pitch_cells)
		var lo := (u - u0) / (u1 - u0)
		var p0: Vector3
		var p1: Vector3
		var vi: int
		match edge:
			EDGE_WEST:
				p0 = _pitch_node_pos(corner_dirs, r_datum, 0.0, u0)
				p1 = _pitch_node_pos(corner_dirs, r_datum, 0.0, u1)
				vi = i * stride + 0
			EDGE_EAST:
				p0 = _pitch_node_pos(corner_dirs, r_datum, 1.0, u0)
				p1 = _pitch_node_pos(corner_dirs, r_datum, 1.0, u1)
				vi = i * stride + cells
			EDGE_SOUTH:
				p0 = _pitch_node_pos(corner_dirs, r_datum, u0, 0.0)
				p1 = _pitch_node_pos(corner_dirs, r_datum, u1, 0.0)
				vi = 0 * stride + i
			_:
				p0 = _pitch_node_pos(corner_dirs, r_datum, u0, 1.0)
				p1 = _pitch_node_pos(corner_dirs, r_datum, u1, 1.0)
				vi = cells * stride + i
		pos[vi] = p0.lerp(p1, lo)

## The CURVED radial placement at facet-param (s,t) — matches `build_tile`'s curved branch (`d·(r_datum+relief)`,
## lift=0, P1 retires the overlay lift) exactly, so a reference breakpoint here is bit-consistent with what a tile
## actually built AT that pitch would place there.
static func _pitch_node_pos(corner_dirs: PackedFloat64Array, r_datum: float, s: float, t: float) -> Vector3:
	var node := FarDensity.node_at(corner_dirs, r_datum, s, t)
	var d: Vector3 = node["dir"]
	return d * (r_datum + float(node["relief"]))

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §2 law 5 — the always-on crack backstop. Appends a thin radially-INWARD
## "curtain" of degenerate geometry along all 4 edges of an already-built tile, dropped `drop` blocks below the true
## surface (planet-centred coords ⇒ `pos.normalized()` IS the outward radial, no separate dir array needed). Any
## residual sub-pixel gap at a tile boundary (weld rounding, a neighbour mid-convergence) reveals this skirt, never
## a see-through hole. Mutates `tile`'s packed arrays IN PLACE (worker-safe: only touches this tile's own arrays,
## called AFTER any edge snap so the skirt hangs from the FINAL boundary position).
static func append_skirt(tile: Dictionary, cells: int, drop: float) -> void:
	var pos: PackedVector3Array = tile["pos"]
	var nrm: PackedVector3Array = tile["nrm"]
	var col: PackedColorArray = tile["col"]
	var uv: PackedVector2Array = tile["uv"]
	var uv2: PackedVector2Array = tile["uv2"]
	var idx: PackedInt32Array = tile["idx"]
	var stride := cells + 1
	for edge in range(4):
		var e := _edge_indices_list(edge, cells, stride)
		var base := pos.size()
		for vi in e:
			var p: Vector3 = pos[vi]
			var d := p.normalized()
			pos.append(p - d * drop)
			nrm.append(nrm[vi])
			col.append(col[vi])
			uv.append(uv[vi])
			uv2.append(uv2[vi])
		for k in range(e.size() - 1):
			var a0: int = e[k]
			var a1: int = e[k + 1]
			var b0 := base + k
			var b1 := base + k + 1
			idx.append(a0); idx.append(a1); idx.append(b1)
			idx.append(a0); idx.append(b1); idx.append(b0)
	tile["pos"] = pos
	tile["nrm"] = nrm
	tile["col"] = col
	tile["uv"] = uv
	tile["uv2"] = uv2
	tile["idx"] = idx

static func _edge_indices_list(edge: int, cells: int, stride: int) -> Array:
	var out := []
	match edge:
		EDGE_WEST:
			for gj in range(stride): out.append(gj * stride + 0)
		EDGE_EAST:
			for gj in range(stride): out.append(gj * stride + cells)
		EDGE_SOUTH:
			for gi in range(stride): out.append(0 * stride + gi)
		_:
			for gi in range(stride): out.append(cells * stride + gi)
	return out

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

# =====================================================================================================================
# P1 INSTANCE (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P1) — the worker-baked smooth-tile MeshInstance set. A
# FacetFarRing owns ONE of these under FP_FAR_SMOOTH: it builds `build_tile` for a requested {facet → tier}
# assignment on WorkerThreadPool slots (cloned from the baker's _pbm pattern), snaps mixed-pitch/frontier edges
# (law 4) + appends the always-on skirt (law 5), and rebuilds ONE PER-TIER ArrayMesh surface (S3/S4/S5 — never a
# single O(everything) merge) so a commit only touches the ONE tier that changed. `lift` is RETIRED to 0 — P1 is a
# REPLACEMENT tier (law 6: a facet is drawn by exactly one of {shell, smooth}), not a B2-style overlay. Shares the
# ring's shell material so the map skin + every per-frame uniform bind come for free. NEVER-OOM: resident tiles
# bounded by the per-tier residency cap + SMOOTH_BYTES_MAX ledger, fixed at creation.

var _material: Material = null
var _mi: Array = [null, null, null, null]     # per-tier MeshInstance3D, indexed by the S2..S5 enum
var _tiles: Dictionary = {}          # fid -> build_tile Dictionary (resident, committed on main)
var _tier_of: Dictionary = {}        # fid -> tier (S2..S5) of each resident tile
var _want: Dictionary = {}           # fid -> tier (the driver's requested resident set)
var _snap_plan: Dictionary = {}      # fid -> PackedInt32Array[4] (EDGE_WEST..NORTH → neighbour's pitch, or
                                      # FacetFarRing.CELLS if that neighbour isn't in `_want` this batch) — frozen at
                                      # request() time so the worker never reads live `_want` (single-writer discipline).
var _bytes: int = 0                  # resident tile bytes (ledger, summed across all tiers)
var _dirty_tier: Array = [false, false, false, false]   # per-tier: a commit/evict touched this tier since its last rebuild
var _changed := false                # residency changed since the last consume_changed() — drives the ring's `_pending`
# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM): the driver's LIVE player-column snapshot (absolute
# world coords), written by `set_rim_params` on the main thread each frame BEFORE `step()` dispatches. `step()`
# copies this into the per-slot frozen `_s_rim_col` at dispatch time (single-writer discipline, mirrors
# `_snap_plan`/`_s_snap`) so an in-flight S2 worker never races a later frame's write. Vector3.ZERO / never read
# with the flag off (S2 is never assigned ⇒ `_build_worker` never takes the rim branch).
var _rim_col: Vector3 = Vector3.ZERO
# worker slots (single-writer of _s_* on main pre-dispatch; the worker writes only _s_result[i] under the mutex)
var _sn: int = 0
var _s_fid: PackedInt32Array
var _s_tier: PackedInt32Array
var _s_task: PackedInt32Array
var _s_result: Array = []
var _s_snap: Array = []              # per-slot frozen snap plan (PackedInt32Array[4] or empty), single-writer pre-dispatch
var _s_rim_col: Array = []           # per-slot frozen player-column Vector3 (S2 builds only), single-writer pre-dispatch
var _s_mutex: Mutex = null

## Create one MeshInstance3D per ladder tier (S2/S3/S4/S5) under `parent` (inherits the ring's placement transform),
## sharing `material`; prewarm the worker-touched statics on MAIN (FarPalette / BlockCatalog / the noise via one
## profile_at_dir) so `build_tile`/`build_tile_rim` are worker-safe. An empty tier's MeshInstance3D carries a
## 0-surface mesh (0 draws) — S2 stays empty (and its MeshInstance3D a harmless no-op node) unless FP_SMOOTH_RIM
## actually assigns it (§3 P3).
func setup_instance(parent: Node3D, material: Material) -> void:
	FarPalette.ensure_ready()
	BlockCatalog.ensure_ready()
	TerrainConfig.profile_at_dir(0.0, 1.0, 0.0, FacetAtlas.R_BLOCKS)   # warm _ensure_noise on main
	_material = material
	for t in [S2, S3, S4, S5]:
		var mi := MeshInstance3D.new()
		mi.name = "FacetSmoothMesh_T%d" % t
		if material != null:
			mi.material_override = material
		parent.add_child(mi)
		_mi[t] = mi
	_sn = clampi(OS.get_processor_count() - 1, 1, CubeSphere.SMOOTH_BUILD_SLOTS)
	_s_fid = PackedInt32Array(); _s_fid.resize(_sn); _s_fid.fill(-1)
	_s_tier = PackedInt32Array(); _s_tier.resize(_sn)
	_s_task = PackedInt32Array(); _s_task.resize(_sn); _s_task.fill(-1)
	_s_result.resize(_sn)
	_s_snap.resize(_sn)
	_s_rim_col.resize(_sn)
	_s_mutex = Mutex.new()

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM): set the frozen player-column snapshot (ABSOLUTE world
## coords) the NEXT `step()` dispatch batch will bake S2 collar tiles against. Called once per frame by the ring's
## `_smooth_drive` BEFORE `step()` — main-thread-only write (matches the `_snap_plan`/`request()` single-writer
## contract). A no-op call with the flag off (nothing ever reads `_rim_col` then).
func set_rim_params(col: Vector3) -> void:
	_rim_col = col

# gi/gj tile-edge index → the FacetAtlas seam slot that borders it (EDGE_WEST..NORTH order, facet_atlas.gd:57-60).
const _EDGE_SEAM_SLOT := [1, 0, 3, 2]   # [S_WEST, S_EAST, S_SOUTH, S_NORTH]

## The driver's requested resident set: fid → tier (S3/S4/S5 only in P1). Freezes each wanted facet's per-edge snap
## plan from THIS batch's assignment (law 4: an edge whose neighbour is in `assignments` snaps to that neighbour's
## pitch if coarser; an edge whose neighbour is ABSENT this batch — still shell, or a transient convergence gap —
## snaps to the shipped CELLS=4 shell pitch; a same-or-finer neighbour is a no-op via `snap_edge_to_pitch`'s own
## guard). Evicts residents no longer wanted OR whose tier changed (frees the byte ledger, marks the OLD tier dirty).
func request(assignments: Dictionary) -> void:
	var w := {}
	for fid in assignments.keys():
		w[int(fid)] = int(assignments[fid])
	_want = w
	_snap_plan = {}
	for fid in w.keys():
		var f := int(fid)
		var plan := PackedInt32Array()
		plan.resize(4)
		for e in range(4):
			var nb := FacetAtlas.seam_neighbour(f, _EDGE_SEAM_SLOT[e])
			if w.has(nb):
				plan[e] = FacetSmoothTier.cells_for_tier(int(w[nb]))
			else:
				plan[e] = FacetFarRing.CELLS   # the shipped shell's pitch (always the coarsest — every ladder tier snaps toward it)
		_snap_plan[f] = plan
	for fid in _tiles.keys():
		var f := int(fid)
		if not _want.has(f) or int(_want[f]) != int(_tier_of[f]):
			_evict(f)

func _evict(fid: int) -> void:
	var t: int = int(_tier_of[fid])
	_bytes -= FacetSmoothTier.tile_bytes(_tiles[fid])
	_tiles.erase(fid)
	_tier_of.erase(fid)
	_dirty_tier[t] = true
	_changed = true

## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3 (FP_SMOOTH_RIM, §2.1 rebuild cadence): force a currently-resident tile
## to be dropped so the NEXT `request()`/`step()` re-bakes it fresh (reuses `_evict`'s ledger/dirty-tier/changed
## bookkeeping verbatim). The facet's role falls straight back to whatever its emit-exclusion law resolves to while
## no smooth tile is resident for it (for an S2/backstop-role facet: the still-warm sunk backstop quad) until the
## fresh tile re-commits — never a frame with neither. No-op if `fid` isn't currently resident.
func force_rebake(fid: int) -> void:
	if _tiles.has(int(fid)):
		_evict(int(fid))

## Per-frame: reap finished worker tiles (commit on main, ≤1 tile/slot), dispatch idle slots to wanted-not-resident
## facets, then rebuild AT MOST ONE dirty tier's ArrayMesh this call (the P1 perf fix — replaces the shipped B2
## O(everything) merged rebuild with an O(that tier's resident set) rebuild, ≤ 3 tier meshes total ⇒ ≤ +3 draws).
func step() -> void:
	if _sn == 0:
		return
	for i in range(_sn):
		if int(_s_task[i]) < 0 or not WorkerThreadPool.is_task_completed(int(_s_task[i])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(_s_task[i]))
		var fid := int(_s_fid[i])
		var tier := int(_s_tier[i])
		_s_mutex.lock()
		var tile = _s_result[i]
		_s_result[i] = null
		_s_mutex.unlock()
		if _want.has(fid) and int(_want[fid]) == tier and tile != null and not _tiles.has(fid):
			var tb: int = FacetSmoothTier.tile_bytes(tile)
			if _bytes + tb <= CubeSphere.SMOOTH_BYTES_MAX:
				_tiles[fid] = tile
				_tier_of[fid] = tier
				_bytes += tb
				_dirty_tier[tier] = true
				_changed = true
		_s_fid[i] = -1
		_s_task[i] = -1
	for i in range(_sn):
		if int(_s_fid[i]) >= 0:
			continue
		var fid := _next_want()
		if fid < 0:
			break
		var tier: int = int(_want[fid])
		_s_fid[i] = fid
		_s_tier[i] = tier
		_s_snap[i] = _snap_plan.get(fid, PackedInt32Array())
		_s_rim_col[i] = _rim_col   # §3 P3: freeze THIS batch's player column for the S2 branch (single-writer, mirrors _s_snap)
		# HIGH priority: the near smooth ring is a small, user-visible bounded set — it must preempt the background
		# whole-planet fine bake (low-priority _pbm tasks) or it starves behind it on a single-worker browser.
		_s_task[i] = WorkerThreadPool.add_task(Callable(self, "_build_worker").bind(i), true, "smoothtile")
	for t in [S2, S3, S4, S5]:
		if _dirty_tier[t]:
			_rebuild_tier_mesh(t)
			_dirty_tier[t] = false
			break   # ≤ 1 tier rebuild/frame (P1 mesh-management requirement)

func _next_want() -> int:
	for fid in _want.keys():
		var f := int(fid)
		if _tiles.has(f) or _inflight(f):
			continue
		return f
	return -1

func _inflight(fid: int) -> bool:
	for i in range(_sn):
		if int(_s_fid[i]) == fid:
			return true
	return false

func _build_worker(i: int) -> void:
	var fid := int(_s_fid[i])
	var tier := int(_s_tier[i])
	var cells := FacetSmoothTier.cells_for_tier(tier)
	var tile: Dictionary
	if tier == S2 and CubeSphere.FP_SMOOTH_RIM:
		# §3 P3: the S2 near-collar — envelope-inside-disc + feather + ε sink, against THIS batch's frozen player
		# column (never `_rim_col` live — the worker only reads its own slot's snapshot, taken pre-dispatch).
		var col: Vector3 = _s_rim_col[i]
		var r_env := FacetFarRing.rim_r_env()
		tile = FacetSmoothTier.build_tile_rim(fid, cells, col, r_env, CubeSphere.RIM_FEATHER_BLOCKS, TierPlace.backstop_sink())
	else:
		tile = FacetSmoothTier.build_tile(fid, cells, 0.0, true)   # curved sphere placement, lift retired to 0 (replacement law)
	var plan: PackedInt32Array = _s_snap[i]
	if plan.size() == 4:
		var corner_dirs := FacetAtlas.facet_corner_dirs(fid)
		var r_datum := FacetAtlas.r_of(fid)
		var pos: PackedVector3Array = tile["pos"]
		for e in range(4):
			FacetSmoothTier.snap_edge_to_pitch(pos, cells, corner_dirs, r_datum, int(plan[e]), e)
		tile["pos"] = pos
	FacetSmoothTier.append_skirt(tile, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)   # law 5: always-on crack backstop
	_s_mutex.lock()
	_s_result[i] = tile
	_s_mutex.unlock()

## Concatenate this tier's resident tiles into ONE ArrayMesh surface (index-offset) — the ONLY tier touched this call.
func _rebuild_tier_mesh(tier: int) -> void:
	var mi: MeshInstance3D = _mi[tier]
	if mi == null:
		return
	var P := PackedVector3Array()
	var N := PackedVector3Array()
	var C := PackedColorArray()
	var U := PackedVector2Array()
	var U2 := PackedVector2Array()
	var I := PackedInt32Array()
	for fid in _tiles.keys():
		if int(_tier_of[fid]) != tier:
			continue
		var t = _tiles[fid]
		var base := P.size()
		P.append_array(t["pos"])
		N.append_array(t["nrm"])
		C.append_array(t["col"])
		U.append_array(t["uv"])
		U2.append_array(t["uv2"])
		for idx in (t["idx"] as PackedInt32Array):
			I.append(base + idx)
	var mesh := ArrayMesh.new()
	if P.size() > 0:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = P
		arr[Mesh.ARRAY_NORMAL] = N
		arr[Mesh.ARRAY_COLOR] = C
		arr[Mesh.ARRAY_TEX_UV] = U
		arr[Mesh.ARRAY_TEX_UV2] = U2
		arr[Mesh.ARRAY_INDEX] = I
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		if _material != null:
			mesh.surface_set_material(0, _material)
	mi.mesh = mesh

func resident_count() -> int:
	return _tiles.size()

func smooth_bytes() -> int:
	return _bytes

## The set of facets currently drawn smooth (any tier) — the far-ring drops these from its heightfield/shell emit
## (law 6, `visible_fids()`).
func resident_fids() -> Array:
	return _tiles.keys()

## O(1) membership test for the exclusion law — is `fid` currently drawn by the smooth tier (any tier)?
func is_resident(fid: int) -> bool:
	return _tiles.has(int(fid))

## The tier (S2..S5) `fid` is resident at, or -1 if not resident.
func tier_of(fid: int) -> int:
	return int(_tier_of.get(int(fid), -1))

## Consume the "residency changed since last call" latch (single read-and-clear) — the driver uses this to know
## when the shell must re-emit to honour the exclusion law (a facet just left/joined the smooth-resident set).
func consume_changed() -> bool:
	var c := _changed
	_changed = false
	return c
