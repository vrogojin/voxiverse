class_name FacetFarRing
extends Node3D
## COSMOS FP2 §5.2 / FP3 §6.1 — the planet rendered AROUND the active facet. Every non-active facet is drawn as
## a flat, low-res, terrain-coloured quad built (ONCE, cached) from its PLANARIZED corners in ABSOLUTE planet
## coords with radial relief (FP0's seam-glue). This node's transform = T_active⁻¹ (facet_transform(active)
## inverse), so the whole planet is re-placed into the active facet's flat render frame by ONE rigid transform —
## the player on the flat facet sees the faceted planet curve away, faces JOINING at the seams (no wedge).
##
## FP-S1(d) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §4-R2 defect 4 / §8): a crossing's set_active USED to do a
## synchronous full 3456-facet rescan + re-emit + generate_normals + commit (plus first-time 25-noise-profile
## caching for every newly-front-hemisphere facet) in ONE main-thread frame — the same frame as the restream
## kickoff. That is a large part of the crossing stall. Now set_active is O(1): it updates ONLY the node transform
## (the mesh is in ABSOLUTE coords, so a rigid re-place keeps every cached facet correctly positioned) and marks a
## deferred rebuild. _process completes it OFF the crossing frame: it cache-warms newly-front-hemisphere facets
## under a per-frame ms budget (mirroring FarTerrain's discipline), then re-emits once. The headless gate drives it
## synchronously via force_rebuild(). Render-only, collision-free, voxel-worker-free (like FarTerrain).

const ENABLED := true
const CELLS := 4                     # heightmap cells per facet edge (far LOD) — k=24 facets are small
const RELIEF := 1.0                  # blocks of radial relief per (g − SEA_LEVEL)
const BACK_CULL := 0.0               # front hemisphere only — back-side facets sit below the surface horizon
const CAMERA_FAR := 9000.0           # the planet spans ~2R; the player camera far must reach it in faceted mode
const FOG_BEGIN := 2200.0            # fog only far out, so the whole planet reads
const WARM_BUDGET_MS := 3.0          # FP-S1(d): per-frame cache-warm budget for newly-front-hemisphere facets

var _active_fid := -1
# COSMOS FP-FIXED-FRAME re-anchor (§3): the accumulated floating-origin shift. Under the fixed frame the ring pins @
# (identity − _anchor_offset) so its ABSOLUTE mesh rides the same re-anchor as PlanetRoot. ZERO with the flag off.
var _anchor_offset: Vector3 = Vector3.ZERO
var _mi: MeshInstance3D
var _pos_cache: Dictionary = {}      # fid -> PackedVector3Array (ABSOLUTE planet coords; built once per facet)
var _col_cache: Dictionary = {}      # fid -> PackedColorArray
# COSMOS far-ring full coverage (docs/COSMOS-FARRING-COVERAGE-DESIGN.md §3): the SEPARATE dense caches for "backstop"
# facets (the active facet + the live-pool `_excluded` set) under FP_FARRING_FULL_COVER. Built lazily at BACKSTOP_CELLS
# (denser than the shipped CELLS=4) by _ensure_backstop_cached; the shipped _pos_cache/_col_cache stay at CELLS for the
# non-backstop horizon facets. Positions are ABSOLUTE + radial with NO sink baked in — the BACKSTOP_SINK radial push is
# applied PER EMITTED VERTEX in _emit_cached, so a facet that transitions backstop→distant across a crossing drops the
# sink automatically on the next rebuild (the cache is role-agnostic). NEVER populated with the flag off (zero cost).
var _bpos_cache: Dictionary = {}     # fid -> PackedVector3Array (dense, ABSOLUTE, un-sunk)
var _bcol_cache: Dictionary = {}     # fid -> PackedColorArray
# COSMOS-PERF L1 (§3.1): pre-TRIANGULATED per-facet caches for FP_FARRING_FAST_REBUILD. Built lazily from the grid
# caches above (only when the fast path or the equivalence gate runs → zero cost/memory with the flag off). Each holds
# the facet's 32 tris EXPANDED to 96 vertices in the EXACT order/winding _emit_cached emits — so the fast rebuild is a
# straight append_array memcpy per facet (~1728 C++ memcpys) instead of ~332k per-vertex GDScript→C++ round-trips.
# NORMALS are NOT cached: the mesh's GLOBAL smoothing (generate_normals merges vertices across facet SEAMS — proven by
# G-L1-FARRING) depends on the whole visible set, so the fast path assembles pos/col, then runs create_from +
# generate_normals (both C++, no GDScript per-vertex calls) → the normal array is BIT-IDENTICAL to the SurfaceTool path.
var _tri_pos_cache: Dictionary = {}  # fid -> PackedVector3Array (96 verts: the facet's tri soup, ABSOLUTE coords)
var _tri_col_cache: Dictionary = {}  # fid -> PackedColorArray   (96 colors, per _emit_cached order)
var _centre_cache: Dictionary = {}   # FP-S1(d): fid -> Array[3] cached centre dir (cheap; no planar-corner recompute per rebuild)
# FP-S1(d) deferred-rebuild state
var _pending := false                # a crossing requested a rebuild; _process (or force_rebuild) completes it off-frame
var _emitted: Dictionary = {}        # fid -> true: the facets in the CURRENTLY committed mesh (visible-set gate check)
var _reemit_count := 0               # diagnostics: full re-emits done (gate: set_active does NOT re-emit synchronously)
# COSMOS FP-R0 SPIKE: facets rendered as REAL rotated voxel terrains (WorldManager fills this behind
# CubeSphere.FP_R0). Their flat quad is suppressed here so the real voxels don't z-fight the ring. Empty
# on the shipped build (FP_R0 off) → the ring draws every non-active facet exactly as before, byte-identical.
var _excluded: Dictionary = {}       # fid -> true (skipped in the visible set, same as the active facet is skipped)
# COSMOS TIER-DEPTH-PRIORITY P1 (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.3): the STICKY backstop set under
# FP_TIER_STICKY_BACKSTOP. Grown EAGERLY to active ∪ ring-1 (make-before-break: a facet is drawn sunk BEFORE it
# enters the pool) and shrunk LAZILY (a departing facet holds its backstop role STICKY_HOLD role-events so it never
# reverts to an unsunk coarse quad while near meshes may still be applied). `_is_backstop` unions this. Empty with
# the flag off → `_is_backstop` is the shipped active∪`_excluded`, byte-identical. `_sticky_hold` is the per-fid
# remaining-hold countdown driving the lazy shrink; recomputed on every set_active/set_pool_excluded (a role-event).
var _sticky: Dictionary = {}         # fid -> true (currently a sticky backstop)
var _sticky_hold: Dictionary = {}    # fid -> int (role-events left before this ex-target may drop out of _sticky)
# COSMOS TIER-DEPTH-PRIORITY P1 gate visibility: which fids were emitted AS BACKSTOP (sunk) in the CURRENTLY committed
# mesh — the make-before-break invariant is "every pool facet is an emitted backstop at the moment near meshes apply",
# and that is a property of the LAST rebuild's roles, not the live `_is_backstop`. Recorded at each rebuild/swap.
var _emitted_backstop: Dictionary = {}   # fid -> true (drawn sunk in the committed mesh)
# COSMOS-PERF STEP 2 (FP_FARRING_ASYNC_REBUILD): off-main-thread rebuild state. The worker assembles the mesh DATA
# (per-vertex emit + generate_normals + commit_to_arrays — pure CPU, NO RenderingServer) on the WARMED, read-only
# per-facet caches; the main thread swaps the finished ArrayMesh in (the only RenderingServer touch). Single-flight
# (_async_building), double-buffered (the old _mi.mesh stays visible until the swap), happens-before via the worker
# pool's is_task_completed (main writes _async_fids before add_task; worker writes _async_arrays before returning).
var _async_task_id := -1
var _async_building := false
var _async_fids := PackedInt32Array()   # the visible set the in-flight worker is building (main → worker; read-only during)
var _async_arrays: Array = []           # worker → main: the committed surface arrays (built off-thread, swapped on main)
# COSMOS far-ring full coverage (§4): the FROZEN backstop set for the in-flight worker. `_is_backstop` reads `_excluded`,
# which set_pool_excluded MUTATES on the main thread mid-crossing — so the worker must NOT evaluate the role live (that
# would race the dict). The role is snapshotted here on the main thread at dispatch (fid -> true); the worker only reads
# this frozen dict, preserving the existing "worker reads read-only per-facet state" contract. Empty with the flag off.
var _async_backstop: Dictionary = {}
# T2e (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-rebuild build/swap timing records, drained by WorldManager →
# RemoteBridge (take_events) so the §2.2c "zero-queue crossing stall" (far-ring re-emit prime suspect) is convicted or
# acquitted in one run. Bounded FIFO (NEVER-OOM: a drain-less headless session can never grow it). `_async_build_us` is
# the off-thread worker build wall time, written by the worker before it returns and read by main after is_task_completed
# (same happens-before as _async_arrays), so the async event carries a real build_ms alongside its main-thread swap_ms.
const EVENTS_MAX := 16
var _events: Array = []
var _async_build_us := 0

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_recompute_sticky()              # TIER-DEPTH P1: seed the sticky backstop set so ring-1 is sunk from the first build (no-op with the flag off)
	_mi = MeshInstance3D.new()
	_mi.name = "FacetFarRingMesh"
	_mi.material_override = _make_material()
	add_child(_mi)
	_rebuild_full()                  # initial build — synchronous (spawn is masked by the ShaderPrewarm hold)
	set_process(true)

## FP3 §6.1 / FP-S1(d) crossing: re-place the planet into facet `new_fid`'s render frame (rigid, O(1)) and DEFER the
## exclusion/terminator re-emit + any new-facet noise caching to _process (off the crossing frame, under a budget).
## The existing merged mesh is in ABSOLUTE coords, so the transform update alone keeps every cached facet correctly
## placed; only B's quad (now the active facet → should be excluded) and the just-left A's quad (now visible) plus a
## thin terminator band are transiently stale for the ≤1-2 frames until the deferred re-emit lands.
func set_active(new_fid: int) -> void:
	_active_fid = new_fid
	transform = _placement_xform()   # rigid re-place (cheap); identity under FP-FIXED-FRAME (no re-place)
	_recompute_sticky()              # TIER-DEPTH P1: grow the sticky set to the NEW active's ring-1 (no-op with the flag off)
	_pending = true

## FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §1.4/§2.2 step 8): the ring mesh is built in ABSOLUTE planet
## coords. When the fixed frame pins the scene @ the absolute frame (PlanetRoot @ identity) this node stays @
## identity — a crossing does NO transform write here (only the deferred exclusion/terminator re-emit remains). Off
## ⇒ T_active⁻¹, re-placing the absolute mesh into the active facet's render frame exactly as today (byte-identical).
func _placement_xform() -> Transform3D:
	if CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL:
		return Transform3D(Basis.IDENTITY, -_anchor_offset)
	return FacetAtlas.facet_transform(_active_fid).affine_inverse()

## COSMOS FP-FIXED-FRAME re-anchor (§3): slide the absolute ring mesh by −A in lockstep with PlanetRoot + the
## ActiveFrame so the whole rendered planet stays continuous through a floating-origin shift. The offset survives a
## crossing (set_active re-applies _placement_xform, which now folds it in). No-op unless the fixed frame is on.
func shift_anchor(a: Vector3) -> void:
	if not (CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL):
		return
	_anchor_offset += a
	transform = _placement_xform()

## COSMOS FP-R0 SPIKE: hide these facets' flat quads (they are drawn as real rotated voxel terrains instead).
## Called only behind CubeSphere.FP_R0; on the shipped build nothing calls this so `_excluded` stays empty and the
## ring is byte-identical. Synchronous (a one-time spawn-setup call), unlike a crossing's deferred re-emit.
func set_excluded(fids: Array) -> void:
	_excluded.clear()
	for f in fids:
		_excluded[int(f)] = true
	force_rebuild()

## FP-M1c (docs/COSMOS-FP-M1-DESIGN.md §4.1): set the excluded flat-quad facets to the live neighbour pool and
## rebuild DEFERRED (budgeted _process) rather than synchronously — a pool spawn/retire/crossing must never pay a
## full ring regen on its own frame (§12.1c). No-op re-sets that leave the set unchanged skip the pending flag.
func set_pool_excluded(fids: Array) -> void:
	var next := {}
	for f in fids:
		next[int(f)] = true
	if next == _excluded:
		return
	_excluded = next
	_recompute_sticky()   # TIER-DEPTH P1: fold the new pool set into the sticky backstop (no-op with the flag off)
	_pending = true   # deferred rebuild (the crossing's set_active already re-placed the mesh rigidly)

## FP-S1(d): drive the deferred rebuild off the crossing frame. Cache-warm the newly-front-hemisphere facets under a
## per-frame ms budget; once they are all cached, do the single re-emit. Only active while a crossing is pending.
## COSMOS-PERF STEP 2: first drain any finished off-thread build (swap it in on the main thread). A new crossing that
## arrives while a build is in flight keeps _pending set but does NOT re-dispatch (_async_building gate) — it is served
## once the in-flight build lands, so the worker's read-only cache snapshot is never mutated under it.
func _process(_dt: float) -> void:
	_poll_async_rebuild()
	if not _pending or _async_building:
		return
	var nrm := FacetAtlas.facet_normal64(_active_fid)
	if _warm_front(nrm):             # all front-hemisphere facets cached → safe to re-emit this frame
		_begin_rebuild()

## COSMOS-PERF STEP 2: whether the off-main-thread rebuild path is live (flag on AND real background workers exist —
## a single-core build has no worker to flip is_task_completed, so it must fall back to the synchronous rebuild).
func _async_enabled() -> bool:
	return CubeSphere.FP_FARRING_ASYNC_REBUILD and OS.get_processor_count() > 1

## Complete a warmed pending rebuild: dispatch it to a worker (async path) or build it inline (synchronous fallback).
func _begin_rebuild() -> void:
	if _async_enabled():
		_dispatch_async_rebuild()
	else:
		_rebuild_full()

## MAIN THREAD: snapshot the (already-warmed) visible set and hand the whole mesh-DATA build to a worker. The caches the
## worker reads are frozen for its lifetime — _process will not warm/dispatch again while _async_building (the gate in
## _process), and force_rebuild/set_excluded join first — so the worker only ever READS _pos_cache/_col_cache.
func _dispatch_async_rebuild() -> void:
	transform = _placement_xform()   # rigid re-place is cheap + main-thread-only (same as _rebuild_full's first line)
	_async_fids = visible_fids()     # every fid here is warmed already (_warm_front gated the dispatch)
	# COSMOS far-ring full coverage (§4): freeze the backstop role on the MAIN thread so the worker never reads `_excluded`
	# live (set_pool_excluded may mutate it mid-run). Only populated under FULL_COVER; empty otherwise → worker sinks nothing.
	_async_backstop = {}
	if CubeSphere.FP_FARRING_FULL_COVER:
		for fid in _async_fids:
			if _is_backstop(fid):
				_async_backstop[fid] = true
	_async_arrays = []
	_pending = false                 # consumed — a fresh crossing sets it again and is served after this build lands
	_async_building = true
	_async_task_id = WorkerThreadPool.add_task(Callable(self, "_async_build_worker"), false, "far-ring mesh rebuild")

## WORKER THREAD: pure CPU. Emits the visible facets' cached pos/col into a SurfaceTool, computes the GLOBAL smooth
## normals, and extracts the raw surface arrays via commit_to_arrays — which, unlike commit(), creates NO mesh RID and
## touches NO RenderingServer. The arrays are BIT-IDENTICAL to what the synchronous commit() would store (proven by
## G-L1-FARRING-ASYNC). NOTHING here reads the scene tree or a rendering server.
func _async_build_worker() -> void:
	var t0 := Time.get_ticks_usec()   # T2e: off-thread build wall time (read on main after is_task_completed)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in _async_fids:
		# backstop role read from the FROZEN snapshot (never `_excluded` live) — the const read is thread-safe.
		_emit_cached(st, fid, CubeSphere.FP_FARRING_FULL_COVER and _async_backstop.has(fid))
	st.generate_normals()
	_async_arrays = st.commit_to_arrays()
	_async_build_us = Time.get_ticks_usec() - t0

## MAIN THREAD: swap a finished off-thread build onto the MeshInstance3D. The double-buffer is implicit — the previous
## _mi.mesh stayed assigned (and visible) for the whole worker run; here we replace it with the freshly built one. This
## is the ONLY RenderingServer touch of the async path (the add_surface_from_arrays / mesh RID create + assignment).
func _poll_async_rebuild() -> void:
	if not _async_building:
		return
	if not WorkerThreadPool.is_task_completed(_async_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_async_task_id)   # already done — reclaims the handle (never blocks here)
	_swap_in_arrays(_async_arrays, _async_fids)
	_async_task_id = -1
	_async_arrays = []
	_async_building = false

## MAIN THREAD: build the ArrayMesh from the worker's surface arrays and assign it, then update the committed-set gate
## state exactly as _rebuild_full does (so emitted_count/reemit_count/_emitted are identical to the synchronous path).
## An empty visible set (fully back-facing) yields an empty ArrayMesh — matching _build_fast's empty-mesh contract.
func _swap_in_arrays(arrays: Array, fids: PackedInt32Array) -> void:
	var t_swap := Time.get_ticks_usec()   # T2e: main-thread swap (add_surface_from_arrays / RID create + instance update)
	var mesh := ArrayMesh.new()
	var verts := 0
	if arrays.size() == Mesh.ARRAY_MAX and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		verts = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_mi.mesh = mesh
	_emitted.clear()
	_emitted_backstop.clear()   # TIER-DEPTH P1: the async build drew the FROZEN `_async_backstop` roles as sunk
	for fid in fids:
		_emitted[fid] = true
		if _async_backstop.has(fid):
			_emitted_backstop[fid] = true
	_reemit_count += 1
	_push_event("async", _async_build_us, Time.get_ticks_usec() - t_swap, verts)

## Warm (noise-cache) every uncached front-hemisphere facet under WARM_BUDGET_MS. Returns true once none remain
## uncached (rebuild may proceed), false when the frame budget is spent (resume next frame). The scan itself is a
## cheap cached-dot classification; only _ensure_cached (25 sphere-profile samples) is budgeted.
func _warm_front(nrm: Array) -> bool:
	var k := FacetAtlas.K
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm):
					continue
				# COSMOS far-ring full coverage (§4): backstop facets warm their DENSE cache; every other facet the
				# shipped grid cache. Warming on the MAIN thread here (before any async dispatch) keeps the worker's
				# read-only cache contract — the worker only ever reads _bpos_cache/_pos_cache, never builds them.
				if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
					if not _bpos_cache.has(fid):
						_ensure_backstop_cached(fid)
				elif not _pos_cache.has(fid):
					_ensure_cached(fid)
				if Time.get_ticks_usec() - t0 > budget_us:
					return false     # budget spent — finish warming next frame
	return true

func _front_visible(fid: int, nrm: Array) -> bool:
	# COSMOS far-ring full coverage (§2): with FP_FARRING_FULL_COVER on, the active facet + `_excluded` set are NO
	# LONGER skipped — they are drawn as sunk "backstop" facets (see _is_backstop / _emit_cached) so the near-disk
	# annular hole is filled. Only the back-hemisphere cull remains. With the flag off, the shipped exclusions apply
	# verbatim (byte-identical: active + `_excluded` absent from the visible set).
	if not CubeSphere.FP_FARRING_FULL_COVER:
		if fid == _active_fid:
			return false                 # the near voxel world already covers the active facet
		if _excluded.has(fid):
			return false                 # FP-R0 SPIKE: drawn as a real rotated voxel terrain, not a flat quad
	var cd := _centre_dir(fid)
	return cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] >= BACK_CULL

## COSMOS far-ring full coverage (§2): a "backstop" facet is one the near voxel world / live pool overlaps (the active
## facet or a live-pool-`_excluded` facet). Under FP_FARRING_FULL_COVER these are drawn from the dense `_bpos_cache` at
## BACKSTOP_CELLS and sunk radially by BACKSTOP_SINK at emit; every other front-hemisphere facet keeps its exact shipped
## CELLS geometry. Role is decided at emit time (keyed by the current active/excluded state), never baked into a cache.
func _is_backstop(fid: int) -> bool:
	return fid == _active_fid or _excluded.has(fid) or _sticky.has(fid)

## COSMOS TIER-DEPTH-PRIORITY P1 (§5.3): recompute the sticky backstop set on a role-event (set_active / set_pool_excluded
## / setup). Make-before-break: the TARGET = active ∪ ring-1 neighbours (the design's set; a facet the player can cross into
## is a seam neighbour = ring-1, so it is already drawn sunk BEFORE it enters the pool and near meshes arrive). Unsink-late
## ("recently-active"): a facet that WAS sticky but is no longer a target keeps its role for STICKY_HOLD more role-events (a
## hold countdown), so a just-departed facet never reverts to a coarse unsunk quad while its near meshes may still be
## applied. Pool facets OUTSIDE ring-1 are already backstop via `_excluded.has` (unioned in `_is_backstop`) and revert
## benignly (a dip) when they leave — so they are deliberately NOT unioned into the TARGET, keeping `_sticky` rigorously
## bounded by ring-1 (≤ STICKY_RING1_MAX, the +96 kB dense-cache ceiling). No-op (empty `_sticky`) unless the flag is on.
func _recompute_sticky() -> void:
	if not TierPlace.sticky_on():
		return
	var target := {}
	for f in TierPlace.ring1(_active_fid):
		target[int(f)] = true
	# Grow eagerly: every target is sticky now, hold refreshed to full.
	for f in target.keys():
		_sticky[int(f)] = true
		_sticky_hold[int(f)] = CubeSphere.STICKY_HOLD
	# Shrink lazily: a sticky facet no longer targeted decrements its hold; only at 0 does it drop.
	for f in _sticky.keys():
		if target.has(int(f)):
			continue
		var h := int(_sticky_hold.get(int(f), 0)) - 1
		if h <= 0:
			_sticky.erase(int(f))
			_sticky_hold.erase(int(f))
		else:
			_sticky_hold[int(f)] = h

## The full scan + re-emit + commit (the OLD _rebuild). Runs at setup, from _process once warming completes, and
## from force_rebuild (the gate). NOT called synchronously by a crossing — that is the whole point of FP-S1(d).
func _rebuild_full() -> void:
	transform = _placement_xform()   # absolute → active-lattice render frame (identity under FP-FIXED-FRAME)
	var fids := visible_fids()
	_emitted.clear()
	_emitted_backstop.clear()   # TIER-DEPTH P1: record which fids this build draws SUNK (the make-before-break gate reads it)
	for fid in fids:
		_ensure_emit_cached(fid)
		_emitted[fid] = true
		if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
			_emitted_backstop[fid] = true
	# COSMOS-PERF L1: pick the mesh assembler. FAST = packed-array memcpy + one add_surface_from_arrays; the shipped
	# SurfaceTool path stays the default (byte-identical mesh). Both consume the SAME visible fids in the SAME order.
	# T2e: time the mesh BUILD (assembler) and the SWAP (mesh assign / RID create + instance update) separately — two
	# ticks_usec reads either side of the split assignment, telemetry-only, no behavioural change.
	var t_build := Time.get_ticks_usec()
	var new_mesh: Mesh = _build_fast(fids) if CubeSphere.FP_FARRING_FAST_REBUILD else _build_surfacetool(fids)
	var build_us := Time.get_ticks_usec() - t_build
	var t_swap := Time.get_ticks_usec()
	_mi.mesh = new_mesh
	var swap_us := Time.get_ticks_usec() - t_swap
	_reemit_count += 1
	_pending = false
	# 32 tris/facet at CELLS=4; under FULL_COVER the backstop facets are denser (2·BACKSTOP_CELLS²) — count them exactly.
	var tris := fids.size() * CELLS * CELLS * 2
	if CubeSphere.FP_FARRING_FULL_COVER:
		var extra := (CubeSphere.BACKSTOP_CELLS * CubeSphere.BACKSTOP_CELLS - CELLS * CELLS) * 2
		for fid in fids:
			if _is_backstop(fid):
				tris += extra
	_push_event("sync", build_us, swap_us, tris * 3)   # T2e: verts = 3·tris (cheap; no surface read-back on the crossing frame)
	print("[FP2] facet far ring: %d triangles around facet %d (%d facets cached, %d backstop)" % [tris, _active_fid, _pos_cache.size(), _bpos_cache.size()])

## The front-hemisphere visible fid set (front-facing, non-active, non-excluded), in canonical face/a/b order. Both
## mesh assemblers + the equivalence gate consume this so their vertex/color/normal arrays are index-aligned.
func visible_fids() -> PackedInt32Array:
	var out := PackedInt32Array()
	var k := FacetAtlas.K
	var nrm := FacetAtlas.facet_normal64(_active_fid)
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if _front_visible(fid, nrm):
					out.append(fid)
	return out

## SHIPPED assembler: per-vertex SurfaceTool emission + generate_normals (the ~332k GDScript→C++ round-trip path).
func _build_surfacetool(fids: PackedInt32Array) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for fid in fids:
		_ensure_emit_cached(fid)
		_emit_cached(st, fid, CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid))   # main thread — live role is safe
	st.generate_normals()
	return st.commit()

## FAST assembler (L1): concat the pre-triangulated per-facet pos/col caches into two big packed arrays (C++ memcpy),
## build a normal-less mesh, then let SurfaceTool COMPUTE the normals via create_from + generate_normals — both C++,
## so NONE of the ~332k per-vertex GDScript→C++ round-trips of the shipped path remain, yet the normals are the SAME
## GLOBALLY-smoothed array (create_from replays the identical vertex list into the identical generate_normals, seams
## and all). A few ms of memcpy + one C++ normal pass, vs 300–700 ms of GDScript emission.
func _build_fast(fids: PackedInt32Array) -> Mesh:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for fid in fids:
		# COSMOS far-ring full coverage (§4): a sunk backstop facet cannot ride the pre-triangulated memcpy (its
		# vertices are pushed radially inward per-vertex at BACKSTOP_CELLS). Under FULL_COVER it falls back to the
		# per-vertex sunk expansion (a handful of facets — §5); non-backstop facets keep the memcpy fast path. The
		# vertex order/winding matches _emit_cached exactly, so the later global generate_normals is bit-identical.
		if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
			_append_backstop_tris(pos, col, fid)
		else:
			_ensure_tri_cached(fid)
			pos.append_array(_tri_pos_cache[fid])
			col.append_array(_tri_col_cache[fid])
	if pos.size() == 0:
		return ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_COLOR] = col
	var flat := ArrayMesh.new()
	flat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)   # normal-less; positions + colors only
	var st := SurfaceTool.new()
	st.create_from(flat, 0)                                       # C++ read-back of the vertex list (no GDScript per-vert)
	st.generate_normals()                                        # C++ GLOBAL smoothing — bit-identical to the shipped path
	return st.commit()

## FP-S1(d) gate helper: synchronously complete a pending deferred rebuild (what _process does over budgeted frames)
## so headless gates — which do not step frames — can assert the post-crossing visible set. COSMOS-PERF STEP 2: joins
## any in-flight off-thread build first (so the caches are quiescent), then rebuilds synchronously — force_rebuild is
## always immediate + main-thread, regardless of the async flag.
func force_rebuild() -> void:
	_join_async_rebuild()
	_rebuild_full()

## COSMOS-PERF STEP 2: block until any in-flight worker finishes and discard its result (a synchronous rebuild is about
## to overwrite it). Called before force_rebuild/set_excluded (which rebuild inline) and on _exit_tree (the worker reads
## this node's caches — it must not outlive the node). No-op when nothing is in flight.
func _join_async_rebuild() -> void:
	if not _async_building:
		return
	WorkerThreadPool.wait_for_task_completion(_async_task_id)
	_async_task_id = -1
	_async_arrays = []
	_async_building = false

## COSMOS-PERF STEP 2: never free while a worker is still reading our caches.
func _exit_tree() -> void:
	_join_async_rebuild()

# --- T2e far-ring build/swap timing events ---
## Push one rebuild's timing record. `path` = "sync"|"async"; build_ms = mesh assembly (off-thread for async), swap_ms =
## the main-thread RID create/instance update, verts = the committed vertex count. Main-thread only in both paths.
func _push_event(path: String, build_us: int, swap_us: int, verts: int) -> void:
	_events.append({
		"type": "farring", "path": path,
		"build_ms": snappedf(float(build_us) / 1000.0, 0.01),
		"swap_ms": snappedf(float(swap_us) / 1000.0, 0.01),
		"verts": verts,
	})
	while _events.size() > EVENTS_MAX:
		_events.pop_front()   # NEVER-OOM: drop the oldest if no bridge is draining

## Drain the pending far-ring timing records (FIFO), clearing the queue. WorldManager.take_farring_events() delegates here.
func take_events() -> Array:
	if _events.is_empty():
		return []
	var out := _events
	_events = []
	return out

# --- gate diagnostics ---
func is_rebuild_pending() -> bool: return _pending
func reemit_count() -> int: return _reemit_count
func is_emitted(fid: int) -> bool: return _emitted.has(fid)
func emitted_count() -> int: return _emitted.size()
func is_backstop(fid: int) -> bool: return _is_backstop(fid)     # COSMOS far-ring full coverage — gate visibility
func backstop_cache_size() -> int: return _bpos_cache.size()     # G-FRC-BOUND: dense caches ≤ 5-facet bound
func is_emitted_backstop(fid: int) -> bool: return _emitted_backstop.has(fid)   # TIER-DEPTH P1: fid drawn SUNK in the committed mesh
func is_sticky(fid: int) -> bool: return _sticky.has(fid)        # TIER-DEPTH P1 gate visibility
func sticky_count() -> int: return _sticky.size()               # TIER-DEPTH P1: sticky set ≤ STICKY_RING1_MAX bound

## TIER-DEPTH P2 gate: the SUNK (as-rendered) dense backstop vertex positions for facet `fid` — the cache (envelope or
## constant-relief) pushed in by the current emit sink (TierPlace.backstop_sink). The gate projects these onto the near
## height field (world_to_lattice64) to prove the rendered coarse surface never rises above the near block tops.
func backstop_rendered_positions(fid: int) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _sunk_positions(_bpos_cache[fid])

## TIER-DEPTH P2 gate: the RAW (un-sunk) dense backstop cache for facet `fid` — the ENVELOPE heights under FP_TIER_ENVELOPE,
## the plain profile_at_dir relief otherwise. The gate applies its OWN fixed ε sink to this so it can prove the ENVELOPE
## property in isolation (a lower bound at a small sink) vs the plain sample (which needs the full 6-block sink to hold).
func backstop_raw_positions(fid: int) -> PackedVector3Array:
	_ensure_backstop_cached(fid)
	return _bpos_cache[fid]

# Compute + cache facet `fid`'s ABSOLUTE-coord terrain quad once (built from its planarized corners + radial relief).
func _ensure_cached(fid: int) -> void:
	if _pos_cache.has(fid):
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var stride := CELLS + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(CELLS)
			var t := float(gj) / float(CELLS)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE (node placed by transform)
			# far water iff g < SEA_LEVEL — STRICT, matching near's sea fill (g < y <= SEA_LEVEL, so g==SEA_LEVEL is DRY
			# beach/shelf sand, not water). `<=` painted the flattened beach shelf (a wide band quantized to g==SEA_LEVEL)
			# as water over near's sand. Matches the already-correct far_mesh_builder.gd classifier.
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	_pos_cache[fid] = pos
	_col_cache[fid] = col

## COSMOS far-ring full coverage (§4): ensure the emit cache appropriate to facet `fid`'s CURRENT role — the dense
## backstop cache for a backstop facet under FULL_COVER, else the shipped CELLS grid. Called by every synchronous
## assembler path before it emits; the async path warms these on the main thread in _warm_front instead.
func _ensure_emit_cached(fid: int) -> void:
	if CubeSphere.FP_FARRING_FULL_COVER and _is_backstop(fid):
		_ensure_backstop_cached(fid)
	else:
		_ensure_cached(fid)

## COSMOS far-ring full coverage (§3): compute + cache facet `fid`'s DENSE (BACKSTOP_CELLS) ABSOLUTE-coord terrain quad
## once. Identical construction to _ensure_cached (planar corners + radial relief + FarPalette colour) but at the denser
## resolution so the between-sample chord error stays below the near mountain relief. The BACKSTOP_SINK radial push is
## NOT baked here — it is applied per emitted vertex (so the cache is role-agnostic and survives a crossing unchanged).
func _ensure_backstop_cached(fid: int) -> void:
	if _bpos_cache.has(fid):
		return
	# TIER-DEPTH P2 (§5.1): under the min-envelope rule each vertex height becomes a PROVABLE lower bound of the near
	# surface over its dilated footprint, replacing the constant sink. Separate builder so the flag-off path is textually
	# the shipped per-vertex profile sample (byte-identical).
	if TierPlace.envelope_on():
		_ensure_backstop_cached_env(fid)
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE, un-sunk
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g < TerrainConfig.SEA_LEVEL))
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## TIER-DEPTH P2 (§5.1): the MIN-ENVELOPE dense backstop cache. Each of the (BACKSTOP_CELLS+1)² coarse vertices keeps its
## own planar position b and radial direction d̂ (grid unchanged — NOT a re-mesh), but its HEIGHT becomes a provable lower
## bound of the near surface: the MINIMUM near g over the vertex's 2×2-coarse-cell footprint DILATED by the radial-vs-
## normal skew reach, sampled on a fine grid at ENV_FINE_MULT × the coarse resolution. A rendered backstop triangle is a
## convex combination of three such corner minima, so it stays ≤ the near surface everywhere in the overlap BY
## CONSTRUCTION (no tuned constant — the proof). The small radial ε sink at emit (TierPlace.backstop_sink) covers the
## sub-fine-sample residual + f32 rounding. Colour is the vertex's OWN direct biome/water sample (cosmetic). Costs
## ~(ENV_FINE_MULT·cells+1)² transient profile_at_dir samples at cache build; ZERO persistent bytes (same 17² grid). Uses
## the far ring's own profile_at_dir funnel (byte-equal to sample_columns by the one-sampler law), so no facet-param→
## lattice remap is introduced. NEVER-OOM: the fine grid is transient and bounded; no cache grows with walk distance.
func _ensure_backstop_cached_env(fid: int) -> void:
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	var mult := TierPlace.ENV_FINE_MULT
	var fine := cells * mult
	var fstride := fine + 1
	# Fine near-g grid over the facet (pitch = edge/fine ≈ 3 blocks): one profile_at_dir per fine node.
	var fg := PackedInt32Array()
	fg.resize(fstride * fstride)
	for fj in range(fstride):
		for fi in range(fstride):
			var s := float(fi) / float(fine)
			var t := float(fj) / float(fine)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var prof := TerrainConfig.profile_at_dir(bx / ln, by / ln, bz / ln, FacetAtlas.R_BLOCKS)
			fg[fj * fstride + fi] = int(prof.x)
	# Skew dilation, in fine-sample units: the far vertex lands displaced ≤ ENV_DILATE_BLOCKS from its footprint b.
	var edge_blocks := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var fine_pitch := edge_blocks / float(fine)
	var dil := int(ceil(TierPlace.ENV_DILATE_BLOCKS / maxf(fine_pitch, 0.001)))
	var half := mult + dil                       # footprint = ±1 coarse cell (±mult fine) + the skew dilation
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var fic := gi * mult
			var fjc := gj * mult
			var gmin := 1 << 30
			for wj in range(fjc - half, fjc + half + 1):
				if wj < 0 or wj >= fstride:
					continue
				var rowoff := wj * fstride
				for wi in range(fic - half, fic + half + 1):
					if wi < 0 or wi >= fstride:
						continue
					var gg: int = fg[rowoff + wi]
					if gg < gmin:
						gmin = gg
			var relief := maxf(0.0, float(gmin - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE, envelope height, un-sunk
			var vp := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var vg := int(vp.x)
			col.append(FarPalette.color_for(vg, int(vp.y), vp.w, vg < TerrainConfig.SEA_LEVEL))
	_bpos_cache[fid] = pos
	_bcol_cache[fid] = col

## COSMOS far-ring full coverage (§2): return a copy of grid positions `p` pushed radially inward by BACKSTOP_SINK
## blocks (p − p̂·BACKSTOP_SINK) so the coarse backstop sits strictly behind the opaque near voxels. Computed once per
## emit so a shared grid vertex is not re-normalized per triangle. Pure math — safe on the async worker thread.
func _sunk_positions(p: PackedVector3Array) -> PackedVector3Array:
	var sink := TierPlace.backstop_sink()   # TIER-DEPTH P2: ε guard under the envelope, else the shipped BACKSTOP_SINK
	var out := PackedVector3Array()
	out.resize(p.size())
	for i in range(p.size()):
		var v: Vector3 = p[i]
		out[i] = v - v.normalized() * sink
	return out

## COSMOS far-ring full coverage (§4): expand backstop facet `fid`'s dense sunk grid into the tri soup (same two tris
## per cell, same winding, same per-vertex colours as _emit_cached) and append it to the fast path's packed arrays. Used
## only by _build_fast under FULL_COVER for the handful of backstop facets that cannot ride the pre-triangulated memcpy.
func _append_backstop_tris(pos: PackedVector3Array, col: PackedColorArray, fid: int) -> void:
	_ensure_backstop_cached(fid)
	var gp := _sunk_positions(_bpos_cache[fid])
	var gc: PackedColorArray = _bcol_cache[fid]
	var cells := CubeSphere.BACKSTOP_CELLS
	var stride := cells + 1
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			pos.push_back(gp[i0]); pos.push_back(gp[i2]); pos.push_back(gp[i1])
			pos.push_back(gp[i1]); pos.push_back(gp[i2]); pos.push_back(gp[i3])
			col.push_back(gc[i0]); col.push_back(gc[i2]); col.push_back(gc[i1])
			col.push_back(gc[i1]); col.push_back(gc[i2]); col.push_back(gc[i3])

## COSMOS far-ring full coverage (§2/§4): emit facet `fid`'s tri soup into `st`. A backstop facet (under FULL_COVER)
## emits its DENSE cache with the BACKSTOP_SINK radial push applied per vertex (pre-computed once here via _sunk_positions
## so a shared grid vertex is not re-normalized per triangle); every other facet emits the shipped CELLS grid verbatim.
## Pure CPU + const reads only — safe on the async worker thread (no scene-tree / RenderingServer access). `sunk` is
## decided by the CALLER (live `_is_backstop` on the main-thread sync path; the frozen `_async_backstop` snapshot on the
## worker) so this function never reads the mutable `_excluded` off-thread.
func _emit_cached(st: SurfaceTool, fid: int, sunk: bool) -> int:
	var pos: PackedVector3Array
	var col: PackedColorArray
	var cells := CELLS
	if sunk:
		pos = _sunk_positions(_bpos_cache[fid])
		col = _bcol_cache[fid]
		cells = CubeSphere.BACKSTOP_CELLS
	else:
		pos = _pos_cache[fid]
		col = _col_cache[fid]
	var stride := cells + 1
	var n := 0
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			st.set_color(col[i0]); st.add_vertex(pos[i0])
			st.set_color(col[i2]); st.add_vertex(pos[i2])
			st.set_color(col[i1]); st.add_vertex(pos[i1])
			st.set_color(col[i1]); st.add_vertex(pos[i1])
			st.set_color(col[i2]); st.add_vertex(pos[i2])
			st.set_color(col[i3]); st.add_vertex(pos[i3])
			n += 2
	return n

## COSMOS-PERF L1: derive facet `fid`'s pre-triangulated pos/col soup from its grid caches, ONCE (cached forever). Expands
## the (CELLS+1)² vertex grid into the SAME 32-tri soup _emit_cached emits (same two tris per cell, same winding, same
## per-vertex colors) so a fast rebuild is a straight append_array of these arrays. Normals are computed later, globally,
## by _build_fast's create_from + generate_normals (they depend on the whole visible set via cross-facet seam smoothing).
func _ensure_tri_cached(fid: int) -> void:
	if _tri_pos_cache.has(fid):
		return
	_ensure_cached(fid)
	var pos: PackedVector3Array = _pos_cache[fid]
	var col: PackedColorArray = _col_cache[fid]
	var stride := CELLS + 1
	var tp := PackedVector3Array()
	var tc := PackedColorArray()
	for gj in range(CELLS):
		for gi in range(CELLS):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			tp.push_back(pos[i0]); tp.push_back(pos[i2]); tp.push_back(pos[i1])
			tp.push_back(pos[i1]); tp.push_back(pos[i2]); tp.push_back(pos[i3])
			tc.push_back(col[i0]); tc.push_back(col[i2]); tc.push_back(col[i1])
			tc.push_back(col[i1]); tc.push_back(col[i2]); tc.push_back(col[i3])
	_tri_pos_cache[fid] = tp
	_tri_col_cache[fid] = tc

func _centre_dir(fid: int) -> Array:
	if _centre_cache.has(fid):
		return _centre_cache[fid]
	var cd := _facet_centre_dir(fid)
	_centre_cache[fid] = cd
	return cd

func _facet_centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _make_material() -> Material:
	# TIER-DEPTH P3 (§5.2): the far ring is the coarsest overlapping tier → an 8-quantum window-space depth bias so it
	# loses every coincident-depth tie to the skin and near blocks at ANY distance. The biased material is a LIT
	# vertex-colour spatial shader equivalent to the StandardMaterial3D below (fog/tonemap applied by the environment).
	# Flag off → the shipped StandardMaterial3D verbatim (byte-identical).
	if TierPlace.depth_bias_on():
		return TierPlace.make_biased_material(TierPlace.far_bias())
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # far ring: winding-agnostic (transforms may flip facets)
	m.roughness = 1.0
	return m

## Triangle count of the built ring mesh (gate).
func triangle_count() -> int:
	if _mi == null or _mi.mesh == null:
		return 0
	var mesh: ArrayMesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return 0
	var arr := mesh.surface_get_arrays(0)
	var vv: Variant = arr[Mesh.ARRAY_VERTEX]
	return (vv as PackedVector3Array).size() / 3
