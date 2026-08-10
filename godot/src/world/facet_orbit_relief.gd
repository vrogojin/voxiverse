class_name FacetOrbitRelief
extends RefCounted
## docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md (task #99 G3, `FP_ORBIT_RELIEF`) — real far-terrain 3D relief GEOMETRY
## from orbit: mountains rise, valleys/cliffs drop, visible in silhouette on the limb and on descent. Supersedes
## the rejected shading-only approach (`FP_SKIN_RELIEF_SHADE`/`FP_RELIEF_REEMIT` — user verdict: "still looks
## flat"). A NEW sibling subsystem to `FacetSmoothV2` (does NOT touch it — same "clean-slate, separate tier"
## discipline V2 itself already set relative to the old ladder), reusing its `hop_annulus`/`merge_tiles` statics
## verbatim (both are already generic, stateless).
##
## THE STRUCTURAL FIX vs the shelved S-ladder / V2's own `build_tile`: this tier's `build_tile` NEVER samples
## live worldgen. Every input is either already-baked `GlobalReliefData` DEM data (height) or write-once-then-
## read-only `FacetAtlas` geometry (corner dirs / r_datum) — the SAME class of data V2 already reads directly
## from a worker (safe: the atlas is built once at `warm_up()` and never mutated during gameplay). `GlobalReliefData`
## itself, by contrast, IS mutated live (the G2 pacer keeps baking facets during gameplay) — so its heights are
## NEVER read directly by a worker; the caller extracts a private per-facet snapshot (`height_grid`, main-thread
## only) BEFORE dispatch. The shell's `_col_cache` (also live-mutated) gets the same snapshot treatment for its
## colour contribution. `build_tile` therefore touches only: (a) write-once atlas statics, safe to call from a
## worker, and (b) plain value-type `PackedInt32Array`/`PackedColorArray` snapshots the main thread already
## copied out — no shared live object crosses the thread boundary at all.
##
## Tile pitch is literally G2's own grid — `ORBIT_RELIEF_CELLS == GlobalReliefData.CELLS` (32) — a 1:1 read, no
## rescale, no interpolation.
##
## PERF FIX #1 (live A/B regression #1 — SurfaceTool): the FIRST shipped cut ran `SurfaceTool.generate_normals()`
## over the whole merged mesh on every commit, stalling the main thread ≈250ms/commit. Fixed by dropping
## SurfaceTool entirely — `_commit` uploads via the SAFE high-level `add_surface_from_arrays` only.
##
## PERF FIX #2 (live A/B regression #2 — WS1/WS4, see `cube_sphere.gd`'s `FP_ORBIT_RELIEF` doc): (a) WS1a
## SUSPENDS the whole tier on-surface (`step()`, zero recompute/dispatch/commit past the reap — G3 has nothing to
## show there); (b) WS1b replaced the per-commit `FacetSmoothV2.merge_tiles` O(resident-set) re-merge with a
## FIXED-SLOT PERSISTENT ARENA (`_arena_pos`/`_arena_col`/`_arena_idx`, `ORBIT_RELIEF_MAX_TILES` slots, allocated
## once) — a commit only (re)writes the ≤`ORBIT_RELIEF_COMMIT_TILES` CHANGED tiles' slots, index-remap baked in at
## BUILD time (worker-side, `vert_base`), never re-processing the whole resident set; (c) `_centre_dir_cache`/
## `GlobalReliefData._height_grid_cache` memoize two per-facet computations that were being redone on every
## recompute/dispatch for an already-baked, therefore immutable, input.
##
## WS4 the no-protrusion EDGE SINK moved to COMMIT time (`edge_sink_mask` + `sunk_positions`), computed against the
## ACTUAL `_committed_tiles` set (not the aspirational want-set) — and, critically, a commit re-sinks not only the
## newly-admitted tile but every one of its ALREADY-committed neighbours too (their sink mask may have just
## changed now that this neighbour is real). Both sides of every committed edge therefore agree BY CONSTRUCTION
## after every commit — no rebuild, self-healing at the commit cadence (`verify_orbit_relief.gd`'s G-OR-SEAM).
##
## WS3 (user verdict: "no slope shades, it just looks ugly" — DROP real-normal relief shading entirely): the mesh
## carries NO normal attribute at all — `make_material` below hardcodes the SAME radial-normal law
## `FacetSmoothV2`'s own DEFAULT (non-LIT) tail already uses (`n = normalize(wp − centre)`, `voxi_shade(n, sun_dir)`
## — the flat skin's day/night/terminator law, nothing else), as its OWN independent material so G3's lighting can
## NEVER accidentally couple to `FP_SMOOTH_V2_LIT` (V2's own, unrelated, slope-shaded variant) if that flag's value
## ever changes. The 3-D read comes from GEOMETRY (silhouette/profile/parallax against the flat skin), not from
## per-slope brightness — dropping the per-vertex normal entirely also removes the analytic-normal compute
## (`_fill_analytic_normals`, now deleted) and 12 B/vertex of resident bytes (see `tile_bytes`/`arena_bytes`).
##
## WS2 (fixes the user's #1 complaint — coarse "large coloured squares"): the mesh ALSO carries a UV/UV2 pair
## landing on the SAME whole-planet `FP_PLANET_MAP` fine-map parametrisation the flat skin already samples
## (`facet_far_ring.gd`'s `_FLAT_ALBEDO_META_FINE`/`_tex_decode`) — `UV = ((a + i/cells)/k, (b + j/cells)/k)`,
## `UV2 = (face, 0.0)`, where `[face,a,b,k]` is `fid`'s decode (see `_tex_decode` below, a small pure duplicate of
## `FacetFarRing._tex_decode` — write-once `FacetAtlas` data, decoded MAIN-THREAD once per facet and passed as
## plain int args, matching every other worker-bound value here). `make_material`'s shader samples `fine_map`
## (`sampler2DArray`) at that UV; a `far_lut[14]` palette (seeded ONCE from `FarPalette.frozen_colors()`) resolves
## the fetched id to a colour. Texel id 0 (unbaked / `FP_PLANET_MAP` off) falls back to the SAME vertex colour
## (`coarse_color`, never-black) this tier already painted before WS2 — byte-visually identical whenever the fine
## map has nothing to say. `ALBEDO = fine_albedo × v_st` (v_st = the WS3 terminator, UNCHANGED — no slope term
## re-enters here).

const ORBIT_RELIEF_CELLS := 32   # == GlobalReliefData.CELLS; kept as its own const so this file has no hard
                                  # compile-time dependency on GlobalReliefData's internals beyond height_grid()'s shape

# =====================================================================================================================
# PURE / STATIC / WORKER-SAFE — no instance state, no RenderingServer access. Mirrors FacetSmoothV2's split.
# =====================================================================================================================

## The unit sphere direction at grid node (s,t), from the SHARED cube-sphere corner dirs `cd` (12 f64) — the
## IDENTICAL law `FacetFarRing._weld_unit`/`FacetSmoothV2._weld_unit` already use, so a shared facet edge welds
## bit-identically BY CONSTRUCTION (two facets sharing a grid edge read the SAME corner dirs at the SAME s,t).
static func _weld_unit(cd: PackedFloat64Array, s: float, t: float) -> Vector3:
	var ux := cd[0] * (1.0 - s) * (1.0 - t) + cd[3] * s * (1.0 - t) + cd[6] * s * t + cd[9] * (1.0 - s) * t
	var uy := cd[1] * (1.0 - s) * (1.0 - t) + cd[4] * s * (1.0 - t) + cd[7] * s * t + cd[10] * (1.0 - s) * t
	var uz := cd[2] * (1.0 - s) * (1.0 - t) + cd[5] * s * (1.0 - t) + cd[8] * s * t + cd[11] * (1.0 - s) * t
	var ln := sqrt(ux * ux + uy * uy + uz * uz)
	return Vector3(ux / ln, uy / ln, uz / ln)

## The facet centre direction — average of its 4 canon corner dirs. Mirrors `FacetFarRing._centre_dir`/
## `FacetSmoothV2._centre_dir` (both already independently duplicate this same tiny formula; this is the
## established convention in this codebase rather than a shared cross-file helper for a 4-line pure function).
static func centre_dir(fid: int) -> Vector3:
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var s := Vector3.ZERO
	for ci in range(4):
		s += Vector3(cd[ci * 3], cd[ci * 3 + 1], cd[ci * 3 + 2])
	return s.normalized()

## PERF FIX WS1c (live A/B follow-up): `_recompute_want` calls `centre_dir` for EVERY candidate facet (up to
## `FacetAtlas.facet_count()`, ~3456) on every throttled recompute — each call was allocating a fresh
## `PackedFloat64Array` + 4 `CosmosFacet.vertex_dir` calls. Precompute the WHOLE table ONCE (lazily, main thread
## only — `_recompute_want` never runs on a worker) and reuse it forever after; `FacetAtlas`'s corner-dir tables
## are write-once-then-read-only (built at `warm_up()`, never mutated during gameplay — §0), so this cache can
## never go stale. A class-level static cache (not per-instance) — shared across every `FacetOrbitRelief` and
## gate call, matching `FarPalette`'s `_block_idx`/`_fc_rgb` "built main-thread once" convention.
static var _centre_dir_cache: PackedVector3Array = PackedVector3Array()
static func _ensure_centre_dir_cache() -> void:
	if not _centre_dir_cache.is_empty():
		return
	var n := FacetAtlas.facet_count()
	var out := PackedVector3Array()
	out.resize(n)
	for fid in range(n):
		out[fid] = centre_dir(fid)
	_centre_dir_cache = out

static func centre_dir_cached(fid: int) -> Vector3:
	_ensure_centre_dir_cache()
	if fid < 0 or fid >= _centre_dir_cache.size():
		return centre_dir(fid)   # bounds-safe fallback (never garbage / never a crash)
	return _centre_dir_cache[fid]

## §2 the COVERAGE PRIORITY LAW: smaller = higher priority. `phi` = angle from the current emit axis (nadir-ish
## off-surface, the player's forward direction on the surface); `theta_h` = the true horizon-tangent angle
## (`FacetFarRing.shell_emit_thetah()`, -1.0 sentinel = no snapshot yet / on-surface). With no horizon snapshot,
## priority is pure nadir-distance (surface/descent regime — reduces to the original nearest-to-axis law).
## With a real horizon, priority is the SMALLER of "distance from nadir" and "distance from the horizon ring" —
## so both the near-nadir foreground AND the visible silhouette rank highest, and only the uninteresting MIDDLE
## band (neither underfoot nor silhouetted) gets truncated first when the candidate set exceeds the tile cap.
static func priority(phi: float, theta_h: float) -> float:
	if theta_h < 0.0:
		return phi
	return minf(phi, absf(phi - theta_h))

## §2 the RESIDENCY LAW. `active_fid`/`emit_axis`/`theta_h` describe the current view; `v2_hop_h` is V2's OWN
## outer hop bound (`CubeSphere.FP_SMOOTH_V2_REACH ? V2_HOP_H_REACH : V2_HOP_H` — the caller resolves this so
## this function stays a pure function of its inputs, no CubeSphere reads). Candidates = every facet whose
## angular distance from `emit_axis` is within `theta_h` (the whole visible cap; off-surface) or within
## `max_phi_fallback` (on-surface/no-horizon-yet — a fixed angular reach, since there's no cap to bound by),
## EXCLUDING `active_fid`'s own V2 footprint (hop 0..v2_hop_h — V2 already covers that ground at finer pitch).
## Ranked by `priority` ascending, truncated to `cap`. Pure — a gate can call this directly with a synthetic
## `all_fids` list and no live scene state.
static func want_set(active_fid: int, emit_axis: Vector3, theta_h: float, v2_hop_h: int, cap: int, all_fids: PackedInt32Array, max_phi_fallback: float) -> PackedInt32Array:
	var excluded := {active_fid: true}
	for fid in FacetSmoothV2.hop_annulus(active_fid, 0, v2_hop_h):
		excluded[int(fid)] = true
	var reach := theta_h if theta_h >= 0.0 else max_phi_fallback
	var picked: Array = []
	for fid in all_fids:
		var f := int(fid)
		if excluded.has(f):
			continue
		var cd := centre_dir_cached(f)
		var dot := clampf(cd.dot(emit_axis), -1.0, 1.0)
		var phi := acos(dot)
		if phi > reach:
			continue
		picked.append([priority(phi, theta_h), f])
	picked.sort()
	if picked.size() > cap:
		picked.resize(cap)
	var out := PackedInt32Array()
	out.resize(picked.size())
	for i in range(picked.size()):
		out[i] = int((picked[i] as Array)[1])
	return out

## §1.5/WS4 the no-protrusion EDGE MASK for `fid`, given the ACTUAL committed/uploaded set (`want`, a fid->true
## Dictionary — O(1) membership). **WS4 REVISED**: the caller now passes `_committed_tiles` (what is ACTUALLY
## drawn right now), not the aspirational `_want` — a neighbour that is merely QUEUED (in `_want`/`_tiles` but
## not yet uploaded) must still be treated as "not there" for sink purposes, or a tile could assume an
## about-to-be-built neighbour already covers its edge and render a temporary crack. For each of the 4 cardinal
## `FacetAtlas` slots, if the neighbour across that edge is NOT in `want`, that edge is a frontier (bordering
## V2/near/unclaimed territory or a not-yet-committed G3 tile) and gets flagged for sinking; a neighbour that IS
## in `want` means both tiles render that edge at the true DEM height, so it is left un-sunk (no crack). Bit
## layout matches `FacetSmoothV2.EDGE_WEST/EAST/SOUTH/NORTH` via the verified `S_WEST↔EDGE_WEST` etc
## correspondence documented on `_edge_indices` above. Pure — a gate can call this directly with a synthetic
## `want` Dictionary.
static func edge_sink_mask(fid: int, want: Dictionary) -> int:
	var mask := 0
	if not want.has(FacetAtlas.seam_neighbour(fid, FacetAtlas.S_WEST)):
		mask |= 1 << FacetSmoothV2.EDGE_WEST
	if not want.has(FacetAtlas.seam_neighbour(fid, FacetAtlas.S_EAST)):
		mask |= 1 << FacetSmoothV2.EDGE_EAST
	if not want.has(FacetAtlas.seam_neighbour(fid, FacetAtlas.S_SOUTH)):
		mask |= 1 << FacetSmoothV2.EDGE_SOUTH
	if not want.has(FacetAtlas.seam_neighbour(fid, FacetAtlas.S_NORTH)):
		mask |= 1 << FacetSmoothV2.EDGE_NORTH
	return mask

## The nearest coarse (shell CELLS=4) node colour to G3 node (i,j) — a PURE array lookup, zero worldgen, zero
## `FarPalette` call. `coarse_col` is the shell's own `_col_cache[fid]` (a (CELLS+1)²=25-entry row-major grid,
## `FacetFarRing.CELLS`=4), snapshotted by the caller BEFORE dispatch (see the class doc's thread-safety note).
## `scale` = `ORBIT_RELIEF_CELLS / FacetFarRing.CELLS` (== 8, exact — the SAME ratio `FP_SKIN_RELIEF_SHADE`'s
## `g2_scale` already established). Degrades to a neutral grey if the snapshot is empty (a boot-race — the
## shell's own base-grid residency is strictly larger than G3's, so this should not happen in steady state, but
## "never a black hole" is the established convention every other far-tier accessor here already follows).
static func coarse_color(coarse_col: PackedColorArray, i: int, j: int, scale: int, shell_cells: int) -> Color:
	if coarse_col.is_empty():
		return Color(0.5, 0.5, 0.5)
	var stride := shell_cells + 1
	var ci := clampi(int(round(float(i) / float(scale))), 0, shell_cells)
	var cj := clampi(int(round(float(j) / float(scale))), 0, shell_cells)
	return coarse_col[cj * stride + ci]

## WS2 `fid`'s [face, a, b, k] decode — a small pure duplicate of `FacetFarRing._tex_decode` (write-once
## `FacetAtlas` data, so it's safe to call from a worker too, but the caller decodes it MAIN-THREAD once per
## facet and passes plain ints — matching every other worker-bound value in this file's convention). `face` is
## the cube face (0..5), `(a,b)` this facet's cell within that face's k×k grid, `k` the grid edge count — the
## SAME parametrisation `FacetFarRing`'s fine-map sampling already uses, so G3's UV lands on identical texels.
static func _tex_decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]

## THE per-tile build. `heights` is a `height_grid(fid)` snapshot (row-major, `NODES_PER_EDGE`² == 33²=1089
## ints); `coarse_col` is a `_col_cache[fid]` snapshot (§ above). `vert_base` is this tile's PERSISTENT arena
## vertex offset (WS1b, its own `PERSISTENT SLOT ARENA` section below) — baked directly into the returned `idx`
## array here (worker-side, zero main-thread index-remap work at commit time). Tiles are built UN-SUNK — the
## no-protrusion edge sink (§1.5) moved to COMMIT time (WS4, see `sunk_positions` + `_write_arena_slot` below):
## baking the sink in at BUILD time froze it against the ASPIRATIONAL want-set, so a tile could keep an edge
## sunk for a neighbour that never actually got drawn (or vice versa) — a one-sided radial cliff at the true
## seam. `{}` (refusal) if `heights` is empty/wrong-size (facet not baked / malformed request) — the caller must
## never commit an empty tile as resident (mirrors V2's refusal contract exactly). WS3 (user verdict: "no slope
## shades"): NO normal is computed here at all — `make_material`'s shader recomputes its own radial normal from
## VERTEX/MODEL_MATRIX in-shader (the SAME law `FacetSmoothV2`'s default tail already uses), so a per-vertex
## ARRAY_NORMAL would be dead weight the active shader never reads. WS2 `face`/`a`/`b`/`k` are `fid`'s `_tex_decode`
## (the caller resolves it once, main-thread, and passes it here so `build_tile` stays a plain worker-safe
## function of value-type args): every node's UV lands on the SAME whole-planet fine-map parametrisation the flat
## skin already samples (`UV = ((a+i/cells)/k, (b+j/cells)/k)`, `UV2 = (face, 0.0)`, constant across the tile).
static func build_tile(fid: int, heights: PackedInt32Array, coarse_col: PackedColorArray, vert_base: int, face: int, a: int, b: int, k: int) -> Dictionary:
	var cells := ORBIT_RELIEF_CELLS
	var stride := cells + 1
	var n := stride * stride
	if heights.size() != n:
		return {}
	var cd := FacetAtlas.facet_corner_dirs(fid)     # write-once atlas data — safe to call from a worker (mirrors V2)
	var r_datum := FacetAtlas.r_of(fid)
	var scale := cells / FacetFarRing.CELLS          # == 8, exact (ORBIT_RELIEF_CELLS(32) / shell CELLS(4))
	var pos := PackedVector3Array(); pos.resize(n)
	var col := PackedColorArray(); col.resize(n)
	var uv := PackedVector2Array(); uv.resize(n)
	var uv2 := PackedVector2Array(); uv2.resize(n)
	var g := PackedInt32Array(); g.resize(n)          # kept for G-OR-DATA-EQ / no-protrusion verification
	var kf := float(maxi(k, 1))
	var uv2_face := Vector2(float(face), 0.0)
	for j in range(stride):
		for i in range(stride):
			var k2 := j * stride + i
			var d := _weld_unit(cd, float(i) / float(cells), float(j) / float(cells))
			var h := heights[k2]
			g[k2] = h
			var relief := maxf(0.0, float(h - TerrainConfig.SEA_LEVEL)) * FacetFarRing.RELIEF
			pos[k2] = d * (r_datum + relief)
			col[k2] = coarse_color(coarse_col, i, j, scale, FacetFarRing.CELLS)
			uv[k2] = Vector2((float(a) + float(i) / float(cells)) / kf, (float(b) + float(j) / float(cells)) / kf)
			uv2[k2] = uv2_face
	var idx := _grid_indices(cells, stride)
	for k2 in range(idx.size()):
		idx[k2] += vert_base   # WS1b: bake the arena offset in HERE (worker-side) — commit never remaps an index
	return {"pos": pos, "col": col, "uv": uv, "uv2": uv2, "g": g, "idx": idx}

## Plain 2-tri/cell quad grid — smooth (per-vertex, not `flat`) colour, so no provoking-vertex convention is
## needed (unlike V2's per-CELL flat paint): G3's colour already varies smoothly node-to-node (§ coarse_color).
static func _grid_indices(cells: int, stride: int) -> PackedInt32Array:
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
	return idx

## §1.5/WS4 the NO-PROTRUSION guard at the V2/near (or not-yet-committed-G3) boundary — REVISED to run at
## COMMIT time, not build time (see `build_tile`'s doc). G2's heights are exact `profile_at_dir` samples at the
## DEM's own coarse (13-block) pitch, not a min-envelope — between two samples on a steep slope the true near
## surface can rise above the mesh's straight-line interpolation (the SAME class of bug `FP_ENV_ALL` fixed for
## the shell's own coarser CELLS=4 grid). Sinking the WHOLE tile would hide relief that is otherwise correct, so
## only edges flagged in `sink_edges` (`edge_sink_mask`, computed by the caller from the CURRENT `_committed_
## tiles` set) get sunk. Returns a NEW copy of `pos` — never mutates its input — because `_tiles[fid]["pos"]`
## must stay canonical/un-sunk (a later commit may need to re-derive a DIFFERENT sink mask for the same tile as
## its neighbours' committed status changes, WS4's "self-heals at the commit cadence" property). Reuses
## `TierPlace.backstop_sink()`'s exact law (`p - p̂·sink`, inlined here since that method is an INSTANCE method
## and this must stay static/pure). An edge shared with another COMMITTED G3 tile is left UNTOUCHED — sinking
## one tile's copy of a shared edge and not the neighbour's would open a visible crack (both sides must agree on
## that edge's height). Interior nodes (and any edge bordering another committed G3 tile) are accepted at face
## value — the same fidelity tradeoff the shell's own un-enveloped tiers already accept elsewhere, disclosed in
## the design doc as bounded-not-eliminated.
## BUG FIX (live A/B follow-up, G-OR-SEAM root-cause): a CORNER node sits on TWO cardinal edges at once (e.g.
## (i=cells,j=0) is on both EAST and SOUTH). The original loop read/wrote `out[k]` per edge, so a corner shared by
## two FLAGGED edges got sunk TWICE (2×`backstop_sink()`) — the amount every OTHER touched node gets is exactly
## `backstop_sink()` once. Fixed by first collecting the UNION of touched indices across all flagged edges, then
## applying the sink exactly ONCE per index, always measured from the PRISTINE input `pos` (never the partially-
## mutated `out`) — a node on N flagged edges now sinks by the same single `sink` as a node on 1.
static func sunk_positions(pos: PackedVector3Array, cells: int, stride: int, sink_edges: int) -> PackedVector3Array:
	var out := pos.duplicate()
	var sink := TierPlace.backstop_sink()
	if sink <= 0.0 or sink_edges == 0:
		return out
	var touched := {}
	for edge in [FacetSmoothV2.EDGE_WEST, FacetSmoothV2.EDGE_EAST, FacetSmoothV2.EDGE_SOUTH, FacetSmoothV2.EDGE_NORTH]:
		if (sink_edges & (1 << edge)) == 0:
			continue
		for k in _edge_indices(edge, cells, stride):
			touched[k] = true
	for k in touched.keys():
		var p: Vector3 = pos[k]   # ALWAYS the pristine input — a corner on 2 flagged edges sinks exactly once
		var d := p.normalized()
		out[k] = p - d * sink
	return out

## Node indices along one cardinal edge of a `stride`×`stride` grid — mirrors `FacetSmoothV2._edge_indices`
## (a small pure helper each tier file keeps its own copy of, same convention `centre_dir` above follows,
## rather than reaching into another file's underscore-prefixed internals). `edge` is one of
## `FacetSmoothV2.EDGE_WEST/EAST/SOUTH/NORTH` (i=0 / i=cells / j=0 / j=cells — verified against
## `FacetAtlas.S_WEST/S_EAST/S_SOUTH/S_NORTH`'s own `(a,b)` convention: corner0=(a,b), corner1=(a+1,b) [+a =
## EAST, s=1], corner3=(a,b+1) [+b = NORTH, t=1] — so i/s tracks the a-axis, j/t tracks the b-axis, matching
## `want_set`'s edge-mask computation which reads `FacetAtlas` slots directly).
static func _edge_indices(edge: int, cells: int, stride: int) -> Array:
	var out := []
	match edge:
		FacetSmoothV2.EDGE_WEST:
			for gj in range(stride): out.append(gj * stride + 0)
		FacetSmoothV2.EDGE_EAST:
			for gj in range(stride): out.append(gj * stride + cells)
		FacetSmoothV2.EDGE_SOUTH:
			for gi in range(stride): out.append(0 * stride + gi)
		_:
			for gi in range(stride): out.append(cells * stride + gi)
	return out

## §3 the COMMIT RATE-CAP decision, split out PURE + static (mirrors `FacetFarRing.shell_fall_should_reemit`'s
## established pattern for wall-clock-dependent logic — an instance method embedding `Time.get_ticks_msec()`
## directly is hard to gate deterministically; pulling the decision into a pure function taking `now_ms`/
## `last_commit_ms` as explicit params makes the REV7 apply-bound rate-cap trivially testable with synthetic
## timestamps, no real threading/wall-clock waiting needed).
static func should_commit(dirty: bool, now_ms: int, last_commit_ms: int, commit_interval_ms: int) -> bool:
	return dirty and now_ms - last_commit_ms >= commit_interval_ms

## Per-tile byte cost (WS3: pos 12B + col 16B — NO nrm; WS2: + uv 8B + uv2 8B; idx 4B). Used by `G-OR-BYTES` to
## check the per-component arithmetic; the LIVE resident ledger is `arena_bytes()` below (the arena, WS1b, is
## allocated ONCE at full capacity, so its cost is a FIXED constant, not a per-tile sum).
static func tile_bytes(tile: Dictionary) -> int:
	if tile.is_empty():
		return 0
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	return nv * (12 + 16 + 8 + 8) + ni * 4

## WS1b PERSISTENT SLOT ARENA sizing — every tile has an IDENTICAL vertex/index count (no skirt, fixed
## `ORBIT_RELIEF_CELLS` grid), so a fixed-slot arena is exact, not approximate.
const VERTS_PER_TILE := (ORBIT_RELIEF_CELLS + 1) * (ORBIT_RELIEF_CELLS + 1)   # 33² = 1089
const IDX_PER_TILE := ORBIT_RELIEF_CELLS * ORBIT_RELIEF_CELLS * 6              # 32²·6 = 6144

## The FULL arena's fixed resident byte cost — `ORBIT_RELIEF_MAX_TILES` slots' worth, always, regardless of how
## many are actually occupied (matches `GlobalReliefData.resident_bytes()`'s "allocated upfront" convention).
static func arena_bytes() -> int:
	return CubeSphere.ORBIT_RELIEF_MAX_TILES * (VERTS_PER_TILE * (12 + 16 + 8 + 8) + IDX_PER_TILE * 4)

# =====================================================================================================================
# WS3 THE SHADER — G3's OWN material (deliberately NOT `FacetSmoothV2.make_material()`): hardcodes the SAME
# radial-normal-only law V2's DEFAULT (non-LIT) tail already uses (`n = normalize(wp − centre)`,
# `voxi_shade(n, sun_dir)` — the flat skin's day/night/terminator law, nothing else) as an INDEPENDENT material, so
# G3's lighting can never accidentally inherit V2's `FP_SMOOTH_V2_LIT` slope-shaded variant if that flag's value
# ever changes — G3 must NEVER show per-slope shading (user verdict: "no slope shades, it just looks ugly"). The
# 3-D read comes from GEOMETRY (silhouette/profile/parallax), not from brightness. Uses the SAME shared
# `VoxiLight.shade_glsl()` snippet every other far/near material already includes (one lighting law, no drift).
#
# WS2 the FINE-MAP texture: samples the SAME whole-planet `fine_map` (`FP_PLANET_MAP`) Texture2DArray the flat
# skin's own `_FLAT_ALBEDO_META_FINE` decodes (facet_far_ring.gd) — quadrant = floor(v_uv·2) picks the 768×768
# sub-page (`face·4 + qy·2 + qx`), `texelFetch` at `fract(v_uv·2)·768` resolves the palette id, `far_lut[id-1]`
# gives the colour. `far_lut`/the texel-resolution constant are BAKED into the source string at compose time
# (`shader_code()`) from `FarPalette.frozen_colors().size()`/`CubeSphere.PLANET_MAP_QUAD·PLANET_MAP_TEXELS` — never
# hardcoded — so a change to either constant can't silently desync G3 from the fine-map's real layout/palette
# size. id==0 (unbaked node, or `FP_PLANET_MAP` off ⇒ the uniform is never bound ⇒ Godot's default sampler reads
# 0) falls back to `v_col_raw` — the SAME vertex `coarse_color` this tier painted before WS2 (never black).
# =====================================================================================================================

const _OR_SHADER_HEAD := "shader_type spatial;
render_mode unshaded, cull_disabled;
"
const _OR_SHADER_TAIL := "uniform sampler2DArray fine_map : source_color, filter_nearest;
uniform vec3 far_lut[%d];
varying vec3 v_col_raw;
varying vec3 v_st;
varying vec2 v_uv;
varying float v_face;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 nr = normalize(wp - centre);
	v_col_raw = COLOR.rgb;
	v_st = voxi_shade(nr, sun_dir);
	v_uv = UV;
	v_face = UV2.x;
}
void fragment() {
	vec2 _q = clamp(floor(v_uv * 2.0), 0.0, 1.0);
	int _fl = int(v_face + 0.5) * 4 + int(_q.y) * 2 + int(_q.x);
	ivec2 _fi = clamp(ivec2(fract(v_uv * 2.0) * %d.0), ivec2(0), ivec2(%d));
	int _f8 = int(texelFetch(fine_map, ivec3(_fi, _fl), 0).r * 255.0 + 0.5);
	vec3 fine_albedo = (_f8 > 0) ? far_lut[_f8 - 1] : v_col_raw;
	ALBEDO = fine_albedo * v_st;
}
"

## The full shader source: HEAD + the shared `VoxiLight.shade_glsl()` snippet (declares sun_dir/night_floor/
## term_mu/moonshine + voxi_shade — picks up e.g. `FP_TWILIGHT_AMBIENT`'s splice for free, zero duplicated
## lighting law) + TAIL (WS2: `%d` filled with the far_lut size + the fine-map sub-page edge/clamp, from the SAME
## `PLANET_MAP_QUAD·PLANET_MAP_TEXELS` the flat skin's own fine decode derives its `pg`/`pg-1` from). A function
## (not a top-level const) so it always reads VoxiLight's CURRENT snippet.
static func shader_code() -> String:
	var nlut := FarPalette.frozen_colors().size()
	var pg := CubeSphere.PLANET_MAP_QUAD * CubeSphere.PLANET_MAP_TEXELS
	return _OR_SHADER_HEAD + VoxiLight.shade_glsl() + (_OR_SHADER_TAIL % [nlut, pg, pg - 1])

## FP_FAR_TERMINATOR_WELD (mirrors `FacetSmoothV2.make_material`): seed sun_dir from the last live Sun G3 itself
## was told (`set_sun_dir`, WS3 wiring), not the hardcoded default — kills a "frozen fake-noon" gap on rebuild.
static var _last_sun_dir := Vector3(1.0, 0.0, 0.0)

## WS2: `far_lut` is seeded ONCE here, at material creation, from `FarPalette.frozen_colors()` — the SAME 14-entry
## palette `_FLAT_ALBEDO_META_FINE`'s fine decode indexes (`far_lut[id-1]`), so a fine-map texel id resolves to
## the identical colour on G3 and on the flat skin.
static func make_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = shader_code()
	sm.shader = sh
	var seed := _last_sun_dir if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
	sm.set_shader_parameter("sun_dir", seed)
	sm.set_shader_parameter("far_lut", FarPalette.frozen_colors())
	return sm

# =====================================================================================================================
# THE INSTANCE — owned by ONE FacetFarRing under FP_ORBIT_RELIEF. ONE MeshInstance3D, ONE material, ONE draw.
# Mirrors FacetSmoothV2's worker-slot-pool / dwell-eviction shape; the commit itself is a FIXED-SLOT ARENA
# (WS1b, live A/B perf follow-up #2 — see the class doc) rather than a per-commit re-merge of the whole resident
# set. Structural differences from V2: (a) no `_cpp_gen` at all (build_tile never touches the module, §0), (b)
# the want-set law is `want_set`/§2 (nearest-nadir-or-limb, not a fixed hop annulus), (c) the whole tier is
# SUSPENDED on-surface (WS1a — see `step()`), and (d) the commit writes a persistent arena instead of
# re-concatenating every resident tile every call.
# =====================================================================================================================

const EVICT_DWELL_STEPS := 20        ## mirrors FacetSmoothV2's own dwell — absorbs want-set boundary wobble

var _mi: MeshInstance3D = null
var _material: ShaderMaterial = null

var _active_fid := -1
var _relief_data: GlobalReliefData = null
var _ring: Node3D = null              ## owning FacetFarRing — read-only accessors only (shell_offsurface/shell_emit_axis/_col_cache), never mutated

var _want: Dictionary = {}            ## fid -> true (current residency target)
var _want_order: Array = []           ## the SAME fids, priority order (dispatch priority)
var _tiles: Dictionary = {}           ## fid -> tile dict (BUILT, off-thread, UN-SUNK — not necessarily uploaded yet, see _committed_tiles)
var _leaving: Dictionary = {}         ## fid -> dwell steps remaining before eviction

var _last_axis_recompute_ms := 0

# worker slots (single-writer of _s_fid/_s_task on main pre-dispatch; the worker writes only _s_result[i] under the mutex)
var _sn := 0
var _s_fid: PackedInt32Array = PackedInt32Array()
var _s_task: PackedInt32Array = PackedInt32Array()
var _s_result: Array = []
var _s_mutex: Mutex = null

# WS1b PERSISTENT SLOT ARENA (live A/B perf follow-up #2): fixed-size pos/col/uv/uv2/idx arrays (WS3: NO nrm — the
# mesh carries no normal attribute; WS2: + uv/uv2 for the fine-map sample, see the class doc), allocated ONCE at
# ORBIT_RELIEF_MAX_TILES slots' worth — a commit never re-processes an already-resident tile's data, only writes
# the ≤ORBIT_RELIEF_COMMIT_TILES NEW ones into their reserved slot range, then uploads the WHOLE (fixed-size,
# unchanged-elsewhere) arena in ONE add_surface_from_arrays call. This replaces the prior design's per-commit
# `FacetSmoothV2.merge_tiles` over the WHOLE committed subset — THAT re-did the O(committed-tiles × 6144) index
# remap loop every single commit (measured ≈100-300ms at 384 tiles, the root cause the arena eliminates: index
# remapping now happens ONCE per tile, at BUILD time, worker-side — see build_tile's `vert_base` param).
var _arena_ready := false
var _arena_pos: PackedVector3Array = PackedVector3Array()
var _arena_col: PackedColorArray = PackedColorArray()
var _arena_uv: PackedVector2Array = PackedVector2Array()
var _arena_uv2: PackedVector2Array = PackedVector2Array()
var _arena_idx: PackedInt32Array = PackedInt32Array()
var _fid_slot: Dictionary = {}          ## fid -> arena slot (reserved from DISPATCH time through eviction)
var _slot_fid: PackedInt32Array = PackedInt32Array()   ## arena slot -> fid, -1 if free
var _free_arena_slots: Array = []       ## stack of free arena slot indices

# `_committed_tiles` is the SUBSET of `_tiles` currently WRITTEN into the arena (and therefore actually drawn).
# `_commit_dirty` is a PERSISTENT (not per-step-call) flag: true whenever `_tiles` has diverged from
# `_committed_tiles` and NOT yet fully caught up — so a rate-cap-blocked commit is never silently dropped, it
# just waits for the next eligible `step()` call.
var _committed_tiles: Dictionary = {}   ## fid -> true (already written into the arena)
var _commit_dirty := false
var _last_commit_ms := 0

## Construct the ONE MeshInstance3D (child of `ring`, sharing its placement transform), the worker slot pool,
## the persistent arena, and seed `_want`/`_want_order`. `ring` is the owning FacetFarRing (needs
## `shell_offsurface()`/`shell_emit_axis()`/`shell_emit_thetah()` and its `_col_cache` — see `_col_cache_for`
## below); `rd` is the SAME GlobalReliefData instance WorldManager already owns and pushes into the ring via
## `set_relief_data` (no new WorldManager-level plumbing — this instance is threaded through the ring, not
## constructed independently).
func setup_instance(ring: Node3D, active_fid: int, rd: GlobalReliefData) -> void:
	_ring = ring
	_relief_data = rd
	_active_fid = active_fid
	_material = make_material()   # WS3: G3's OWN radial-terminator-only material — never shares V2's material/flag
	_mi = MeshInstance3D.new()
	_mi.name = "FacetOrbitReliefMesh"
	_mi.mesh = ArrayMesh.new()
	_mi.material_override = _material
	ring.add_child(_mi)
	_sn = clampi(OS.get_processor_count() - 1, 1, CubeSphere.SMOOTH_BUILD_SLOTS)
	_s_fid = PackedInt32Array(); _s_fid.resize(_sn); _s_fid.fill(-1)
	_s_task = PackedInt32Array(); _s_task.resize(_sn); _s_task.fill(-1)
	_s_result.resize(_sn)
	_s_mutex = Mutex.new()
	_ensure_arena()
	_recompute_want(active_fid, true)

## WS1b: allocate the fixed-size arena (once). Every triangle starts DEGENERATE (all 3 indices point at vertex
## 0) so an un-written slot never renders garbage.
func _ensure_arena() -> void:
	if _arena_ready:
		return
	var cap := CubeSphere.ORBIT_RELIEF_MAX_TILES
	_arena_pos = PackedVector3Array(); _arena_pos.resize(cap * VERTS_PER_TILE)
	_arena_col = PackedColorArray(); _arena_col.resize(cap * VERTS_PER_TILE)
	_arena_uv = PackedVector2Array(); _arena_uv.resize(cap * VERTS_PER_TILE)
	_arena_uv2 = PackedVector2Array(); _arena_uv2.resize(cap * VERTS_PER_TILE)
	_arena_idx = PackedInt32Array(); _arena_idx.resize(cap * IDX_PER_TILE)
	_arena_idx.fill(0)
	_slot_fid = PackedInt32Array(); _slot_fid.resize(cap); _slot_fid.fill(-1)
	_free_arena_slots = range(cap)
	_arena_ready = true

## Reserve (or return the already-reserved) arena slot for `fid`. -1 if the arena is momentarily full (a
## transient dwell-eviction overlap, not a hard error — the caller's dispatch loop simply waits for a later
## `step()` once a slot frees; `want_set` already truncates to `ORBIT_RELIEF_MAX_TILES`, so steady-state demand
## never exceeds capacity).
func _alloc_arena_slot(fid: int) -> int:
	if _fid_slot.has(fid):
		return _fid_slot[fid]
	if _free_arena_slots.is_empty():
		return -1
	var slot: int = _free_arena_slots.pop_back()
	_fid_slot[fid] = slot
	_slot_fid[slot] = fid
	return slot

## Release `fid`'s arena slot (eviction, or a build refusal that never needed one — a no-op if `fid` never held
## a slot). Degenerates the slot's indices FIRST so nothing stale keeps rendering after release.
func _free_arena_slot(fid: int) -> void:
	if not _fid_slot.has(fid):
		return
	var slot: int = _fid_slot[fid]
	_fid_slot.erase(fid)
	_slot_fid[slot] = -1
	_degenerate_slot(slot)
	_free_arena_slots.append(slot)

func _degenerate_slot(slot: int) -> void:
	var vbase := slot * VERTS_PER_TILE
	var ibase := slot * IDX_PER_TILE
	for k in range(IDX_PER_TILE):
		_arena_idx[ibase + k] = vbase   # every triangle collapses to one point — zero area, invisible

## §2.1 recompute the want-set from the CURRENT emit axis/horizon. `force` bypasses the axis-drift throttle
## (always called on a genuine facet crossing, mirrors V2's crossing-only `set_active`); the throttled path is
## driven from `step()` below while the axis drifts without a crossing.
func _recompute_want(active: int, force: bool) -> void:
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_axis_recompute_ms < CubeSphere.ORBIT_RELIEF_AXIS_MS:
		return
	_last_axis_recompute_ms = now_ms
	var ring := _ring as FacetFarRing
	var axis_a: Array = ring.shell_emit_axis()
	var axis := Vector3(axis_a[0], axis_a[1], axis_a[2]) if axis_a.size() == 3 and (axis_a[0] != 0.0 or axis_a[1] != 0.0 or axis_a[2] != 0.0) else centre_dir_cached(active)
	var theta_h: float = ring.shell_emit_thetah()
	var v2_hop_h := CubeSphere.V2_HOP_H_REACH if CubeSphere.FP_SMOOTH_V2_REACH else CubeSphere.V2_HOP_H
	var n := FacetAtlas.facet_count()
	var all_fids := PackedInt32Array()
	all_fids.resize(n)
	for i in range(n):
		all_fids[i] = i
	var order := want_set(active, axis, theta_h, v2_hop_h, CubeSphere.ORBIT_RELIEF_MAX_TILES, all_fids, CubeSphere.ORBIT_RELIEF_FALLBACK_REACH_RAD)
	var new_want := {}
	for fid in order:
		new_want[int(fid)] = true
	for fid in new_want.keys():
		_leaving.erase(fid)
	for fid in _tiles.keys():
		if not new_want.has(fid) and not _leaving.has(fid):
			_leaving[fid] = EVICT_DWELL_STEPS
	_want = new_want
	_want_order = order

## §2.1/WS1a: the ONLY force-recompute trigger besides the axis-drift throttle — a facet crossing. On-surface,
## this ONLY records the new active fid — no recompute, no eviction, no dispatch: the resident mesh stays frozen
## exactly as it was (§ `step()`'s WS1a note), warm and ready for the next ascent. Off-surface, behaves exactly
## as before (force-recompute, mirrors V2's `set_active`).
func set_active(new_fid: int) -> void:
	if new_fid == _active_fid:
		return
	_active_fid = new_fid
	if (_ring as FacetFarRing).shell_offsurface():
		_recompute_want(new_fid, true)

## Snapshot the shell's `_col_cache[fid]` for a safe cross-thread hand-off (§0's thread-safety note), via
## `FacetFarRing.col_cache_for` (a real getter — `.duplicate()`, never a live reference). Empty if the shell
## hasn't cached `fid` yet (the boot-race `coarse_color` already degrades gracefully for).
func _col_cache_for(fid: int) -> PackedColorArray:
	return (_ring as FacetFarRing).col_cache_for(fid)

## WS1a (live A/B perf follow-up #1) — SUSPEND ON-SURFACE. G3 is an orbit/high-altitude feature; on the surface
## it has nothing useful to show (the near field + V2 own that view) but its full recompute+dispatch+commit
## cycle was running every frame regardless, at real cost (this alone was the dominant ground-level stall,
## proc_ms ≈240 live). Reaping ALWAYS runs first (cheap; frees any in-flight worker slot so nothing dangles
## across a freeze — a tile that finishes building while on-surface still lands in `_tiles`/marks
## `_commit_dirty`, it simply isn't committed until the ring goes back off-surface: "warm for next ascent").
## Everything past the reap — recompute, dwell-eviction, dispatch, commit — is skipped while `shell_offsurface()`
## is false: the resident mesh is a frozen, static draw, exactly as `set_active` above already promises.
## Called once per `FacetFarRing._process`, alongside `_smooth_v2.step()`.
func step() -> void:
	if _sn == 0 or _relief_data == null:
		return
	for i in range(_sn):
		if int(_s_fid[i]) < 0 or not WorkerThreadPool.is_task_completed(int(_s_task[i])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(_s_task[i]))
		var fid := int(_s_fid[i])
		_s_mutex.lock()
		var tile = _s_result[i]
		_s_result[i] = null
		_s_mutex.unlock()
		_s_fid[i] = -1
		_s_task[i] = -1
		if tile != null and not (tile as Dictionary).is_empty() and _want.has(fid):
			_tiles[fid] = tile
			_leaving.erase(fid)
			_commit_dirty = true
		else:
			_free_arena_slot(fid)   # refusal / no longer wanted — release its reserved slot immediately
		# a genuine completion with `_want.has(fid)` KEEPS its slot (still reserved, about to be committed).
	var ring := _ring as FacetFarRing
	if not ring.shell_offsurface():
		return   # WS1a: on-surface — no recompute, no dwell-eviction, no dispatch, no commit. Frozen.
	_recompute_want(_active_fid, false)   # throttled axis-drift recompute (no-op most calls)
	if not _leaving.is_empty():
		var to_evict := []
		for fid in _leaving.keys():
			var left := int(_leaving[fid]) - 1
			if left <= 0:
				to_evict.append(fid)
			else:
				_leaving[fid] = left
		for fid in to_evict:
			_leaving.erase(fid)
			if _tiles.has(fid):
				_tiles.erase(fid)
				_commit_dirty = true
			_free_arena_slot(fid)
	for fid in _want_order:
		var f := int(fid)
		if _tiles.has(f) or _inflight(f):
			continue
		var slot := _free_slot()
		if slot < 0:
			break   # no free worker slot this call — the remainder waits for a later step()
		var arena_slot := _alloc_arena_slot(f)
		if arena_slot < 0:
			break   # arena momentarily full (transient dwell overlap) — the remainder waits too
		var heights := _relief_data.height_grid(f)      # main-thread snapshot — safe hand-off (§0, WS1d-cached)
		var coarse_col := _col_cache_for(f)              # main-thread snapshot — safe hand-off (§0)
		var vert_base := arena_slot * VERTS_PER_TILE     # WS1b: baked into the worker's own idx output
		var tex := _tex_decode(f)                        # WS2: [face,a,b,k] — main-thread decode, plain ints to the worker
		_s_fid[slot] = f
		_s_task[slot] = WorkerThreadPool.add_task(Callable(self, "_build_worker").bind(
			slot, f, heights, coarse_col, vert_base, int(tex[0]), int(tex[1]), int(tex[2]), int(tex[3])), true, "orbitrelieftile")
	if _commit_dirty:
		var now_ms := Time.get_ticks_msec()
		if should_commit(_commit_dirty, now_ms, _last_commit_ms, CubeSphere.ORBIT_RELIEF_COMMIT_MS):
			_commit()
			_last_commit_ms = now_ms
		# else: _commit_dirty stays true (rate-cap window not yet open) — the NEXT eligible step() call retries;
		# nothing is silently dropped.

func _free_slot() -> int:
	for i in range(_sn):
		if int(_s_fid[i]) < 0:
			return i
	return -1

func _inflight(fid: int) -> bool:
	for i in range(_sn):
		if int(_s_fid[i]) == fid:
			return true
	return false

## WorkerThreadPool-dispatched (off MAIN): build one tile. Reads only its own bound args (`heights`/`coarse_col`
## are private snapshots, never the live `GlobalReliefData`/`_col_cache`) + write-once `FacetAtlas` statics — see
## the class doc's thread-safety note. `vert_base` (WS1b) is baked into the tile's own `idx` array here, off-
## thread — the main thread NEVER remaps an index. Writes ONLY `_s_result[slot]` under the mutex; never touches
## `_want`/`_tiles`/any other instance field (single-writer discipline, mirrors `FacetSmoothV2._build_worker`).
func _build_worker(slot: int, fid: int, heights: PackedInt32Array, coarse_col: PackedColorArray, vert_base: int, face: int, a: int, b: int, k: int) -> void:
	var tile := build_tile(fid, heights, coarse_col, vert_base, face, a, b, k)
	_s_mutex.lock()
	_s_result[slot] = tile
	_s_mutex.unlock()

## WS1b/WS4 (live A/B perf follow-up) — the ARENA commit. NO whole-set re-merge: (1) sync evictions (a freed
## arena slot was ALREADY degenerated by `_free_arena_slot` when the fid left `_tiles` — this just drops the
## bookkeeping entry); (2) admit up to `ORBIT_RELIEF_COMMIT_TILES` newly-built tiles into `_committed_tiles`
## (their arena slot was already reserved at DISPATCH time, §`_alloc_arena_slot`); (3) WS4 — recompute
## `edge_sink_mask` against the ACTUAL `_committed_tiles` set (not the aspirational `_want`) for every newly-
## admitted tile AND any of its ALREADY-committed neighbours (whose own mask may have just changed now that this
## neighbour is real) — write each affected tile's SUNK position copy (`sunk_positions`, canonical `_tiles[fid]`
## stays un-sunk) into its arena slot; (4) upload the WHOLE persistent (fixed-size) arena in ONE
## `add_surface_from_arrays` call. Steps (2)+(3) together cost O(≤ORBIT_RELIEF_COMMIT_TILES × 5) tile writes,
## NEVER O(resident-set) — the perf bug this replaces re-merged the ENTIRE committed subset (up to 384 tiles'
## index remap) every single commit.
func _commit() -> void:
	_ensure_arena()
	for fid in _committed_tiles.keys():
		if not _tiles.has(fid):
			_committed_tiles.erase(fid)
	var newly_added: Array = []
	var added := 0
	for fid in _tiles.keys():
		if added >= CubeSphere.ORBIT_RELIEF_COMMIT_TILES:
			break
		var f := int(fid)
		if _committed_tiles.has(f):
			continue
		_committed_tiles[f] = true
		newly_added.append(f)
		added += 1
	var to_write := {}
	for f in newly_added:
		to_write[f] = true
		for slot_dir in [FacetAtlas.S_WEST, FacetAtlas.S_EAST, FacetAtlas.S_SOUTH, FacetAtlas.S_NORTH]:
			var nb := FacetAtlas.seam_neighbour(f, slot_dir)
			if _committed_tiles.has(nb):
				to_write[nb] = true   # an already-committed neighbour's sink mask may have just changed
	for fid in to_write.keys():
		var f := int(fid)
		var slot: int = _fid_slot.get(f, -1)
		if slot < 0 or not _tiles.has(f):
			continue
		var mask := edge_sink_mask(f, _committed_tiles)
		_write_arena_slot(slot, _tiles[f], mask)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = _arena_pos
	arr[Mesh.ARRAY_COLOR] = _arena_col
	arr[Mesh.ARRAY_TEX_UV] = _arena_uv
	arr[Mesh.ARRAY_TEX_UV2] = _arena_uv2
	arr[Mesh.ARRAY_INDEX] = _arena_idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mi.mesh = m
	_commit_dirty = _committed_tiles.size() != _tiles.size()

## Write ONE tile's (sink-masked) data into its reserved arena slot. `tile["idx"]` is already offset by this
## slot's `vert_base` (baked in at `build_tile`, worker-side) — this is a plain per-index COPY, no arithmetic. WS3:
## no `nrm` slot — the mesh carries no normal attribute (`make_material`'s shader derives its own in-shader). WS2:
## `uv`/`uv2` are copied unchanged (the no-protrusion sink only moves POSITION radially — the fine-map texel a
## node samples never changes when its edge sinks).
func _write_arena_slot(slot: int, tile: Dictionary, sink_edges: int) -> void:
	var vbase := slot * VERTS_PER_TILE
	var ibase := slot * IDX_PER_TILE
	var spos := sunk_positions(tile["pos"], ORBIT_RELIEF_CELLS, ORBIT_RELIEF_CELLS + 1, sink_edges)
	var tcol: PackedColorArray = tile["col"]
	var tuv: PackedVector2Array = tile["uv"]
	var tuv2: PackedVector2Array = tile["uv2"]
	var tidx: PackedInt32Array = tile["idx"]
	for k in range(VERTS_PER_TILE):
		_arena_pos[vbase + k] = spos[k]
		_arena_col[vbase + k] = tcol[k]
		_arena_uv[vbase + k] = tuv[k]
		_arena_uv2[vbase + k] = tuv2[k]
	for k in range(IDX_PER_TILE):
		_arena_idx[ibase + k] = tidx[k]

## NEVER-OOM telemetry: the arena's FIXED resident byte cost (allocated once at full capacity, §`arena_bytes`)
## — 0 until `setup_instance` has run.
func resident_bytes() -> int:
	return arena_bytes() if _arena_ready else 0

## How many facets are ACTUALLY drawn right now (not merely built/queued — `_tiles.size()` for that).
func tile_count() -> int:
	return _committed_tiles.size()

## WS3 live sun wiring (mirrors `FacetSmoothV2.set_sun_dir`): feed the current Sun direction into THIS instance's
## OWN material (a separate ShaderMaterial from V2's/the shell's) so its terminator tracks live time. No-op if the
## material isn't built yet (mirrors V2's guard).
func set_sun_dir(sun_dir: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)
	# FP_FAR_TERMINATOR_WELD: record the live value so the NEXT rebuilt instance (a facet crossing frees and
	# reconstructs this whole object) seeds from it in `make_material` instead of the hardcoded fake-noon default.
	# Off ⇒ a no-op write to a var `make_material` never reads ⇒ byte-identical.
	if CubeSphere.FP_FAR_TERMINATOR_WELD:
		_last_sun_dir = sun_dir

## WS2: feed the whole-planet fine_map texture into THIS instance's OWN material (`FacetFarRing.set_fine_map`
## forwards here — see its doc). No-op if the material isn't built yet; a null `tex` is a no-op too (mirrors the
## caller's own guard, so this stays safe to call directly from a gate as well).
func set_fine_map(tex) -> void:
	if _material != null and tex != null:
		_material.set_shader_parameter("fine_map", tex)
