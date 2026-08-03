class_name FacetBlockLodLadder
extends Node3D
## COSMOS BLOCK-LOD P2 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4/§5/§9) — the STREAMED LADDER: the L2..L4 megablock tiers
## (FP_BLOCK_LOD_RINGS) that extend blocky relief past the P1 L1 rim out toward the horizon with a power-of-2 fidelity
## fall-off. GATED CONSTRUCTION sibling of the far ring / P1 ring: it only exists when FP_BLOCK_LOD_RINGS is on ⇒
## byte-identical off (WorldManager never news it up).
##
## GENERALIZES P1: this node owns ONE FacetBlockLodRing per level n in 2..BLOCK_LOD_MAX_LEVEL — the exact same
## generalized greedy mesher / async worker bake / arrival dither / weld law the P1 rim ring uses, just at coarser
## pitch (setup(fid, n)). The ladder's job on top of the ring is (a) LEVEL SELECTION — assign each nearby facet a
## level by the on-screen block-size law (level_for_distance, d_max(Ln)≈2^n·K_px/4), so a facet ~2–4 px/block gets the
## matching tier; (b) a SHARED cross-level NEVER-OOM ledger — the P1 L1 ring + these L2..L4 rings + the L5 global mesh
## all draw from ONE ceiling (block_lod_ceiling(): 16 MB default / 28 MB expanded), coarsened FINEST-FIRST on breach
## (drop L1, then L2, …) so under 16 MB the ladder self-trims to L2.. and re-adds L1 only at the A/B-gated 28 MB.
##
## CONTAINMENT + SKIRTS (§3/§4): every level is MIN-decimated ⇒ coarser sits at-or-below finer and is overdrawn; the
## per-facet skirt (dropped one coarse pitch) closes the ≤1-coarse-pitch boundary step. No stitching geometry. The
## sunk far ring is the ultimate backstop under everything ⇒ a streaming gap or an eviction NEVER leaves a hole.
##
## DRAWS: one merged ArrayMesh per resident (facet × level) ⇒ draws ≈ live tiles across levels (bounded by
## BLOCK_LOD_LADDER_MAX_FACETS), NOT block count. ASYNC: every bake rides the P1 JobLane worker path at
## PRIORITY_BLOCK_LOD ⇒ a crossing/descent through multiple levels pays commit-only on main (no bake stall).

const _SCREEN_K_PX := CubeSphere.BLOCK_LOD_SCREEN_K_PX   # px·distance per block (the design's on-screen block-size const)

var _active_fid := -1
var _rings: Dictionary = {}            # level(int) -> FacetBlockLodRing (one per tier 2..cap)
var _lane: JobLane = null
var _l1: FacetBlockLodRing = null      # the P1 rim ring (registered for shared finest-first coarsening); may be null
var _global = null                     # the L5 global tier (FacetBlockLodGlobal) — reserved-byte floor; may be null
var _centre_cache: Dictionary = {}     # fid -> Vector3 world facet centre (datum), for the distance law
var _dispatch_rounds := 0
var _wholesale_clears := 0             # cross-level coarsening sweeps that emptied a whole ladder ring (breach guard)

# COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 2 LAW R-E (one-look arbitration in code): see the identical field on
# FacetBlockLodRing. Wired up by WorldManager ONLY when FP_FAR_SMOOTH is on; unset ⇒ byte-identical to shipped.
var _smooth_query: Callable = Callable()

## REVISION 2 LAW R-E: wire the smooth-residency arbitration query into this ladder AND every ring it owns.
func set_smooth_query(cb: Callable) -> void:
	_smooth_query = cb
	for n in _rings:
		(_rings[n] as FacetBlockLodRing).set_smooth_query(cb)

func _smooth_owns(fid: int) -> bool:
	return _smooth_query.is_valid() and bool(_smooth_query.call(fid))


# ---- the on-screen block-size LAW (§4) -------------------------------------------------------------------------

## d_max(Ln): the distance (blocks) at which a level-n megablock (pitch 2^n) drops under the ~4 px LOD threshold —
## d_max ≈ 2^n · K_px / 4. Pure; the gate checks the band boundaries against this.
static func d_max(level: int) -> float:
	# COSMOS FAR-LOD QUALITY (B): K_px comes from the flag-gated helper — the shipped 1407 with FP_FARLOD_QUALITY off
	# (byte-identical: verify_block_lod's 500→L1..8000→L5 bands unmoved), or the finer FARLOD_TARGET_PX-scaled value on.
	return float(1 << level) * CubeSphere.block_lod_screen_k_px() / 4.0

## The tier a facet at distance `dist` blocks should render at: the smallest level whose d_max still covers it,
## clamped to [1, GLOBAL_LEVEL]. dist≤703→L1, ≤1407→L2, ≤2814→L3, ≤5628→L4, else→L5. This is the screen-space law
## the ladder assigns facets by (level 1 = the P1/near domain; the ladder itself only streams 2..cap).
static func level_for_distance(dist: float) -> int:
	for n in range(1, CubeSphere.BLOCK_LOD_GLOBAL_LEVEL + 1):
		if dist <= d_max(n):
			return n
	return CubeSphere.BLOCK_LOD_GLOBAL_LEVEL


# ---- lifecycle -------------------------------------------------------------------------------------------------

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	var top := mini(CubeSphere.BLOCK_LOD_MAX_LEVEL, FacetBlockLod.LEVELS - 1)
	for n in range(2, top + 1):
		var ring := FacetBlockLodRing.new()
		ring.name = "BlockLodL%d" % n
		add_child(ring)
		# The ladder governs the shared ceiling ⇒ lift each ring's own byte cap (huge) and keep only its LRU-facet cap.
		ring.set_caps(1 << 30, CubeSphere.BLOCK_LOD_LADDER_LRU)
		if _lane != null:
			ring.set_job_lane(_lane)
		ring.setup(active_fid, n, false)   # no ridge-1 initial stream — the ladder drives the per-level assigned band
		_rings[n] = ring
	rebuild(active_fid)


## Hand the shared TH0 job lane to every tier ring BEFORE setup so all bakes run off-main (commit-only on main).
func set_job_lane(lane: JobLane) -> void:
	_lane = lane
	for n in _rings:
		(_rings[n] as FacetBlockLodRing).set_job_lane(lane)


## Register the P1 L1 rim ring so the shared coordinator can coarsen it FIRST (finest level) under the 16 MB ceiling
## (design §5 "start ladder at L2, drop L1"). Null ⇒ the ladder governs only its own L2.. rings.
func register_l1(l1: FacetBlockLodRing) -> void:
	_l1 = l1

## Register the L5 global tier so its always-resident DATA floor + visible mesh count against the shared ceiling
## (the global data is a protected reserve; the ladder coarsens its own tiers before touching the global mesh).
func set_global(global) -> void:
	_global = global


func place(xform: Transform3D) -> void:
	transform = xform
	for n in _rings:
		(_rings[n] as FacetBlockLodRing).place(xform)


func set_sun_dir(sun_dir: Vector3) -> void:
	for n in _rings:
		(_rings[n] as FacetBlockLodRing).set_sun_dir(sun_dir)


# ---- level assignment + streaming ------------------------------------------------------------------------------

## World facet centre on the datum (absolute coords), cached. Distances between centres are block-metric (1 unit = 1
## block), so level_for_distance reads directly off them.
func _facet_centre(fid: int) -> Vector3:
	if _centre_cache.has(fid):
		return _centre_cache[fid]
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var cx := float(dmin.x + dmax.x) * 0.5
	var cz := float(dmin.y + dmax.y) * 0.5
	var a := FacetAtlas.lattice_to_world64(fid, cx, 0.0, cz)
	var v := Vector3(a[0], a[1], a[2])
	_centre_cache[fid] = v
	return v


## Assign each facet in a bounded neighbourhood of `active_fid` to a ladder level by the screen-space law. BFS over
## seam neighbours (bounded by BLOCK_LOD_LADDER_MAX_FACETS and by d_max(cap)); classify each by its centre distance;
## per level keep the NEAREST BLOCK_LOD_LADDER_LRU facets (so each per-level band is residency-bounded ⇒ NEVER-OOM).
## Returns {level -> Array[fid]} for levels 2..cap. Pure w.r.t. the scene (gate-callable).
func assign_levels(active_fid: int) -> Dictionary:
	var top := mini(CubeSphere.BLOCK_LOD_MAX_LEVEL, FacetBlockLod.LEVELS - 1)
	var reach := d_max(top)
	var centre0 := _facet_centre(active_fid)
	# Bounded BFS enumeration (nearest-first-ish via ring expansion; hard-capped).
	var visited := {active_fid: true}
	var frontier: Array = [active_fid]
	var candidates: Array = []          # [fid, dist] within reach
	while not frontier.is_empty() and visited.size() < CubeSphere.BLOCK_LOD_LADDER_MAX_FACETS:
		var next: Array = []
		for fid in frontier:
			for slot in range(4):
				var nb := FacetAtlas.seam_neighbour(fid, slot)
				if nb < 0 or visited.has(nb):
					continue
				visited[nb] = true
				var dist := (_facet_centre(nb) - centre0).length()
				if dist <= reach:
					# REVISION 2 LAW R-E: a facet the smooth tier already draws is NEVER classified into a ladder
					# level — code-level mutual exclusion (still traversed for BFS connectivity, just not banded).
					if not _smooth_owns(nb):
						candidates.append([nb, dist])
					next.append(nb)
				if visited.size() >= CubeSphere.BLOCK_LOD_LADDER_MAX_FACETS:
					break
			if visited.size() >= CubeSphere.BLOCK_LOD_LADDER_MAX_FACETS:
				break
		frontier = next
	# Classify by the law, then per level keep nearest-N.
	var by_level: Dictionary = {}
	for n in range(2, top + 1):
		by_level[n] = []
	for c in candidates:
		var lvl := level_for_distance(float(c[1]))
		if lvl < 2:
			continue                    # near domain — the P1 L1 ring / near voxels own it
		lvl = clampi(lvl, 2, top)
		(by_level[lvl] as Array).append(c)
	for n in by_level:
		var arr: Array = by_level[n]
		arr.sort_custom(func(a, b): return a[1] < b[1])
		var band: Array = []
		for i in range(mini(arr.size(), CubeSphere.BLOCK_LOD_LADDER_LRU)):
			band.append(int(arr[i][0]))
		by_level[n] = band
	return by_level


## Re-assign + re-stream every tier for a (possibly new) active facet, then enforce the shared ceiling. Called on
## setup and every crossing. Each ring streams its assigned band up-front on the worker (commit-only on main).
func rebuild(active_fid: int) -> void:
	_active_fid = active_fid
	var assign := assign_levels(active_fid)
	for n in _rings:
		var band: Array = assign.get(n, [])
		(_rings[n] as FacetBlockLodRing).rebuild_band(band)
	_dispatch_rounds += 1
	enforce_shared_budget()


# ---- shared NEVER-OOM ledger (§5) ------------------------------------------------------------------------------

## Total block-LOD mesh bytes under the shared ceiling: the P1 L1 ring (if registered) + every ladder tier + the L5
## global tier (data floor + visible mesh). The gate asserts this ≤ block_lod_ceiling().
func total_bytes() -> int:
	var t := 0
	if _l1 != null:
		t += _l1.ledger_bytes()
	for n in _rings:
		t += (_rings[n] as FacetBlockLodRing).ledger_bytes()
	if _global != null:
		t += int(_global.call("total_bytes"))
	return t

## The block-LOD mesh bytes the coordinator may coarsen (everything EXCEPT the global data floor, which is protected).
func _reclaimable_bytes() -> int:
	var t := 0
	if _l1 != null:
		t += _l1.ledger_bytes()
	for n in _rings:
		t += (_rings[n] as FacetBlockLodRing).ledger_bytes()
	if _global != null:
		t += int(_global.call("mesh_bytes"))
	return t

## The finest-first ring order the coordinator coarsens through: the P1 L1 ring first (finest), then L2, L3, …
func _coarsen_order() -> Array:
	var order: Array = []
	if _l1 != null:
		order.append(_l1)
	var levels := _rings.keys()
	levels.sort()
	for n in levels:
		order.append(_rings[n])
	return order

## Enforce the shared ceiling: while the total (mesh + global data floor) exceeds it, evict ONE LRU non-band facet
## from the FINEST ring that still has one (design §5 "drop the finest streamed level first"). The band of each ring
## (its assigned/ridge-1 set) is protected; the L5 global DATA floor is never touched. If every ring is down to its
## band and it is STILL over, the visible global mesh is shed next; if even that bottoms out, record a wholesale-clear
## (the irreducible band floor is the NEVER-OOM guarantee — bounded, and the far ring backstops any thinned tier).
func enforce_shared_budget() -> void:
	var ceiling := CubeSphere.block_lod_ceiling()
	var order := _coarsen_order()
	var guard := 0
	while total_bytes() > ceiling and guard < 8192:
		guard += 1
		# Phase 1 — evict ONE LRU non-band tile from the finest ring that has one (cheap coarsening).
		var freed := 0
		for ring in order:
			var r: FacetBlockLodRing = ring
			freed = r.evict_one_lru(r.current_band())
			if freed > 0:
				break
		if freed > 0:
			continue
		# Phase 2 — shed the L5 global VISIBLE mesh (the data floor stays); the far ring backstops it.
		if _global != null and int(_global.call("mesh_bytes")) > 0:
			_global.call("shed_mesh_once")
			continue
		# Phase 3 — hard breach: even the protected bands overrun. Drop the FINEST streamed ring ENTIRELY (§5
		# "drop the finest streamed level first"); the coarser tiers + the sunk far ring still cover it (no hole).
		var dropped := false
		for ring in order:
			var r: FacetBlockLodRing = ring
			if r.clear_all() > 0:
				_wholesale_clears += 1
				dropped = true
				break
		if not dropped:
			break                                  # only the global DATA floor remains — the irreducible NEVER-OOM floor


# ---- telemetry -------------------------------------------------------------------------------------------------

func active_levels() -> Array:
	var ls := _rings.keys()
	ls.sort()
	return ls

func level_tile_count(level: int) -> int:
	if not _rings.has(level):
		return 0
	return (_rings[level] as FacetBlockLodRing).draw_count()

func level_bytes(level: int) -> int:
	if not _rings.has(level):
		return 0
	return (_rings[level] as FacetBlockLodRing).ledger_bytes()

func draw_count() -> int:
	var n := 0
	for lvl in _rings:
		n += (_rings[lvl] as FacetBlockLodRing).draw_count()
	return n

func ring_for(level: int) -> FacetBlockLodRing:
	return _rings.get(level, null)

func async_idle() -> bool:
	for n in _rings:
		if not (_rings[n] as FacetBlockLodRing).async_idle():
			return false
	return true

func dispatch_rounds() -> int:
	return _dispatch_rounds

func wholesale_clears() -> int:
	return _wholesale_clears
