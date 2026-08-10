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
		var cd := centre_dir(f)
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

## §1.5/3 the no-protrusion EDGE MASK for `fid`, given the CURRENT resident want-set (`want`, a fid->true
## Dictionary — O(1) membership, built by the caller from `want_set`'s ordered result). For each of the 4
## cardinal `FacetAtlas` slots, if the neighbour across that edge is NOT in `want`, that edge is a frontier
## (bordering V2/near/unclaimed territory) and gets flagged for sinking; a neighbour that IS in `want` means
## both tiles will render that edge at the true DEM height, so it is left un-sunk (no crack). Bit layout matches
## `FacetSmoothV2.EDGE_WEST/EAST/SOUTH/NORTH` via the verified `S_WEST↔EDGE_WEST` etc correspondence documented
## on `_edge_indices` above. Pure — a gate can call this directly with a synthetic `want` Dictionary.
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

## THE per-tile build. `heights` is a `height_grid(fid)` snapshot (row-major, `NODES_PER_EDGE`² == 33²=1089
## ints); `coarse_col` is a `_col_cache[fid]` snapshot (§ above). `sink_edges` is a 4-bit mask
## (`FacetSmoothV2.EDGE_WEST/EAST/SOUTH/NORTH`) of which of THIS tile's edges border a facet NOT also resident
## in G3 this build (computed by the caller from the CURRENT want-set, main thread, §1.5/3) — those edges get
## the no-protrusion sink (§1.5); an edge shared with another resident G3 tile is left un-sunk so the two tiles'
## shared boundary stays at the true DEM height on both sides (preserving the weld — sinking one side and not
## the other would open a crack). `{}` (refusal) if `heights` is empty/wrong-size (facet not baked / malformed
## request) — the caller must never commit an empty tile as resident (mirrors V2's refusal contract exactly).
static func build_tile(fid: int, heights: PackedInt32Array, coarse_col: PackedColorArray, sink_edges: int) -> Dictionary:
	var cells := ORBIT_RELIEF_CELLS
	var stride := cells + 1
	var n := stride * stride
	if heights.size() != n:
		return {}
	var cd := FacetAtlas.facet_corner_dirs(fid)     # write-once atlas data — safe to call from a worker (mirrors V2)
	var r_datum := FacetAtlas.r_of(fid)
	var scale := cells / FacetFarRing.CELLS          # == 8, exact (ORBIT_RELIEF_CELLS(32) / shell CELLS(4))
	var pos := PackedVector3Array(); pos.resize(n)
	var nrm := PackedVector3Array(); nrm.resize(n)    # placeholder (== outward radial dir); merge_tiles expects the
	                                                    # key, and _commit() overwrites every normal via generate_normals
	                                                    # right after merging — see §1.6, no per-tile normal law needed
	var col := PackedColorArray(); col.resize(n)
	var g := PackedInt32Array(); g.resize(n)          # kept for G-OR-DATA-EQ / no-protrusion verification
	for j in range(stride):
		for i in range(stride):
			var k := j * stride + i
			var d := _weld_unit(cd, float(i) / float(cells), float(j) / float(cells))
			var h := heights[k]
			g[k] = h
			var relief := maxf(0.0, float(h - TerrainConfig.SEA_LEVEL)) * FacetFarRing.RELIEF
			pos[k] = d * (r_datum + relief)
			nrm[k] = d
			col[k] = coarse_color(coarse_col, i, j, scale, FacetFarRing.CELLS)
	var idx := _grid_indices(cells, stride)
	var tile := {"pos": pos, "nrm": nrm, "col": col, "g": g, "idx": idx}
	_append_edge_sink(tile, cells, stride, sink_edges)
	return tile

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

## §1.5 the NO-PROTRUSION guard at the V2/near boundary. G2's heights are exact `profile_at_dir` samples at the
## DEM's own coarse (13-block) pitch, not a min-envelope — between two samples on a steep slope the true near
## surface can rise above the mesh's straight-line interpolation (the SAME class of bug `FP_ENV_ALL` fixed for
## the shell's own coarser CELLS=4 grid). Sinking the WHOLE tile would hide relief that is otherwise correct, so
## only edges flagged in `sink_edges` (the caller-computed "this edge's neighbour is NOT also a resident G3
## tile" mask, §3) get sunk — reuses `FacetSmoothV2._edge_indices` to enumerate each flagged edge's node
## indices, then `FacetFarRing._sunk_positions_amt`'s exact law (`p - p̂·sink`, inlined here since that method is
## an INSTANCE method and this must stay static/worker-safe), amount `TierPlace.backstop_sink()`. An edge shared
## with another resident G3 tile is left UNTOUCHED — sinking one tile's copy of a shared edge and not the
## neighbour's would open a visible crack (both sides must agree on that edge's height). Interior nodes (and any
## edge bordering another G3 tile) are accepted at face value — the same fidelity tradeoff the shell's own
## un-enveloped tiers already accept elsewhere, disclosed in the design doc as bounded-not-eliminated.
static func _append_edge_sink(tile: Dictionary, cells: int, stride: int, sink_edges: int) -> void:
	var sink := TierPlace.backstop_sink()
	if sink <= 0.0 or sink_edges == 0:
		return
	var pos: PackedVector3Array = tile["pos"]
	for edge in [FacetSmoothV2.EDGE_WEST, FacetSmoothV2.EDGE_EAST, FacetSmoothV2.EDGE_SOUTH, FacetSmoothV2.EDGE_NORTH]:
		if (sink_edges & (1 << edge)) == 0:
			continue
		for k in _edge_indices(edge, cells, stride):
			var p: Vector3 = pos[k]
			var d := p.normalized()
			pos[k] = p - d * sink
	tile["pos"] = pos

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

## NEVER-OOM ledger (mirrors `FacetSmoothV2.tile_bytes`'s accounting: pos/nrm 12B each, col 16B, idx 4B — normals
## are NOT stored per tile, computed once at commit over the merged mesh, §1.6 of the design doc; charged here at
## the steady-state 12B/vert so the ledger reflects the RESIDENT cost once committed, not the transient pre-normal
## state).
static func tile_bytes(tile: Dictionary) -> int:
	if tile.is_empty():
		return 0
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	return nv * (12 + 12 + 16) + ni * 4

# =====================================================================================================================
# THE INSTANCE — owned by ONE FacetFarRing under FP_ORBIT_RELIEF. ONE MeshInstance3D, ONE material, ONE draw.
# Mirrors FacetSmoothV2's worker-slot-pool / dwell-eviction / rate-capped-whole-surface-commit shape exactly —
# the only structural differences are (a) no `_cpp_gen` at all (build_tile never touches the module, §0), (b) the
# want-set law is `want_set`/§2 (nearest-nadir-or-limb, not a fixed hop annulus), and (c) the commit is rate-
# capped to a LONGER interval (ORBIT_RELIEF_COMMIT_MS) because the resident vertex count is far larger than V2's.
# =====================================================================================================================

const EVICT_DWELL_STEPS := 20        ## mirrors FacetSmoothV2's own dwell — absorbs want-set boundary wobble

var _mi: MeshInstance3D = null
var _material: ShaderMaterial = null

var _active_fid := -1
var _relief_data: GlobalReliefData = null
var _ring: Node3D = null              ## owning FacetFarRing — read-only accessors only (shell_emit_axis/_col_cache), never mutated

var _want: Dictionary = {}            ## fid -> true (current residency target)
var _want_order: Array = []           ## the SAME fids, priority order (dispatch priority)
var _tiles: Dictionary = {}           ## fid -> tile dict (resident, committed on main)
var _leaving: Dictionary = {}         ## fid -> dwell steps remaining before eviction

var _last_axis_recompute_ms := 0

# worker slots (single-writer of _s_fid/_s_task on main pre-dispatch; the worker writes only _s_result[i] under the mutex)
var _sn := 0
var _s_fid: PackedInt32Array = PackedInt32Array()
var _s_task: PackedInt32Array = PackedInt32Array()
var _s_result: Array = []
var _s_mutex: Mutex = null

var _last_commit_ms := 0

## Construct the ONE MeshInstance3D (child of `ring`, sharing its placement transform), the worker slot pool,
## and seed `_want`/`_want_order`. `ring` is the owning FacetFarRing (needs `shell_emit_axis()`/`shell_emit_cos()`/
## `shell_emit_thetah()` and its `_col_cache` — see `_col_cache_for` below); `rd` is the SAME GlobalReliefData
## instance WorldManager already owns and pushes into the ring via `set_relief_data` (no new WorldManager-level
## plumbing — this instance is threaded through the ring, not constructed independently).
func setup_instance(ring: Node3D, active_fid: int, rd: GlobalReliefData) -> void:
	_ring = ring
	_relief_data = rd
	_active_fid = active_fid
	_material = FacetSmoothV2.make_material()   # reuse V2's lit-normal shader family (§1.6) — no new shader source
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
	_recompute_want(active_fid, true)

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
	var axis := Vector3(axis_a[0], axis_a[1], axis_a[2]) if axis_a.size() == 3 and (axis_a[0] != 0.0 or axis_a[1] != 0.0 or axis_a[2] != 0.0) else centre_dir(active)
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

## §2.1: the ONLY force-recompute trigger besides the axis-drift throttle — a facet crossing. No-op if the active
## facet didn't actually change (mirrors V2's `set_active` exactly).
func set_active(new_fid: int) -> void:
	if new_fid == _active_fid:
		return
	_active_fid = new_fid
	_recompute_want(new_fid, true)

## Snapshot the shell's `_col_cache[fid]` for a safe cross-thread hand-off (§0's thread-safety note), via
## `FacetFarRing.col_cache_for` (a real getter — `.duplicate()`, never a live reference). Empty if the shell
## hasn't cached `fid` yet (the boot-race `coarse_color` already degrades gracefully for).
func _col_cache_for(fid: int) -> PackedColorArray:
	return (_ring as FacetFarRing).col_cache_for(fid)

## Reap finished builds, advance dwell evictions, dispatch new builds into free slots (want-order = priority
## order), throttle-recompute the want-set on axis drift, then commit ONE whole-surface ArrayMesh rebuild if
## anything changed AND the commit rate-cap has elapsed. Cheap at rest (no dirty tiles, no in-flight slots ⇒ every
## loop below is a fast no-op scan) — called once per `FacetFarRing._process`, alongside `_smooth_v2.step()`.
func step() -> void:
	if _sn == 0 or _relief_data == null:
		return
	_recompute_want(_active_fid, false)   # throttled axis-drift recompute (no-op most calls)
	var dirty := false
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
			dirty = true
		# else: a refusal (G2 not baked yet) or `_want` moved while it built — discard silently; the fid stays in
		# `_want_order` so a later step() call simply re-dispatches it once its DEM lands.
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
				dirty = true
	for fid in _want_order:
		var f := int(fid)
		if _tiles.has(f) or _inflight(f):
			continue
		var slot := _free_slot()
		if slot < 0:
			break   # no free worker slot this call — the remainder waits for a later step()
		var heights := _relief_data.height_grid(f)      # main-thread snapshot — safe hand-off (§0)
		var coarse_col := _col_cache_for(f)              # main-thread snapshot — safe hand-off (§0)
		var sink_edges := edge_sink_mask(f, _want)       # pure, main-thread, cheap (4 seam_neighbour lookups)
		_s_fid[slot] = f
		_s_task[slot] = WorkerThreadPool.add_task(Callable(self, "_build_worker").bind(slot, f, heights, coarse_col, sink_edges), true, "orbitrelieftile")
	if dirty:
		var now_ms := Time.get_ticks_msec()
		if should_commit(dirty, now_ms, _last_commit_ms, CubeSphere.ORBIT_RELIEF_COMMIT_MS):
			_commit()
			_last_commit_ms = now_ms
		# else: stays dirty implicitly (the NEXT step() call re-checks _leaving/_tiles state and will still find
		# a reason to commit once the rate-cap window opens — no separate "pending" flag needed since `_tiles`
		# itself already reflects the latest state; the commit merely hasn't been pushed to the RenderingServer yet)

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
## the class doc's thread-safety note. Writes ONLY `_s_result[slot]` under the mutex; never touches `_want`/
## `_tiles`/any other instance field (single-writer discipline, mirrors `FacetSmoothV2._build_worker`).
func _build_worker(slot: int, fid: int, heights: PackedInt32Array, coarse_col: PackedColorArray, sink_edges: int) -> void:
	var tile := build_tile(fid, heights, coarse_col, sink_edges)
	_s_mutex.lock()
	_s_result[slot] = tile
	_s_mutex.unlock()

## Whole-surface commit (§3/§1.6): merge the resident tiles (race-free ascending-fid order, `FacetSmoothV2.
## merge_tiles` reused verbatim), build the raw ArrayMesh, then ONE `SurfaceTool.generate_normals()` pass over
## the WHOLE merged mesh — the SAME create_from+generate_normals+commit pattern `FacetFarRing._build_fast`
## already uses for the shell, so cross-facet-boundary normal smoothing applies here too (the shared-vertex
## positions are bit-equal by the weld argument in §0, so SurfaceTool's global smoothing merges them correctly).
func _commit() -> void:
	var merged := FacetSmoothV2.merge_tiles(_tiles)
	var pos: PackedVector3Array = merged["pos"]
	if pos.is_empty():
		_mi.mesh = ArrayMesh.new()
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_COLOR] = merged["col"]
	arr[Mesh.ARRAY_INDEX] = merged["idx"]
	var flat := ArrayMesh.new()
	flat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var st := SurfaceTool.new()
	st.create_from(flat, 0)
	st.generate_normals()
	_mi.mesh = st.commit()

## NEVER-OOM telemetry: actual resident bytes right now (sum of live tiles' `tile_bytes()`, not the theoretical
## cap) — mirrors `GlobalReliefData.resident_bytes()`'s ledger convention.
func resident_bytes() -> int:
	var b := 0
	for fid in _tiles.keys():
		b += tile_bytes(_tiles[fid])
	return b

func tile_count() -> int:
	return _tiles.size()
