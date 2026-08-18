class_name StructGenIndex
extends RefCounted
## COSMOS STRUCTURES P1a (docs/COSMOS-STRUCTURES-DESIGN.md §12.5) — the GEN half of the ONE structure registry.
## WorldManager-owned (beside _structure_tracker), constructed ONLY under FP_STRUCT_GEN (null off ⇒ byte-identical).
## A pure per-fid CACHE of StructureGen's hash function: enumerate a facet's live villages → their houses → §3-shape
## GEN records. Because the records are a deterministic function of position, the cache is EVICTABLE AT WILL — the
## GEN registry never holds blocks and can never grow the heap unboundedly (never-OOM by construction).
##
## THE SEAM (§12.5): `WorldManager.structure_registry()` returns `tracker.registry() + _gen_index.records()`, so the
## far tier consumes ONE registry from TWO producers with no downstream changes. GEN records carry
## `source = SOURCE_GEN`, a NEGATIVE `root` (disjoint from tracker roots), and a `rev` damage counter bumped when a
## player edit lands inside a GEN bbox (the far model then re-bakes and shows the hole, exactly like a player build).

const _FACET_CAP := 96              # LRU cap on cached facets (never-OOM; ≫ the ~a-few-facets wanted band)

var _cache: Dictionary = {}         # fid -> Array of GEN records (pure enumeration, rev overlaid from _rev)
var _lru: Array = []                # fids in recency order (front = most recent) for the eviction bound
var _rev: Dictionary = {}           # root -> damage rev (persists across enumeration eviction; 0-default is pristine)
var _wanted: PackedInt32Array = PackedInt32Array()

var _epoch := 0                     # bumped on crossing (re-selects the wanted band; records themselves are pure)
var _active_fid := -1
var _wanted_dirty := true

# telemetry / gate read-back
var _dbg_enum_count := 0


## Refresh the wanted-facet band from the active facet (WorldManager calls this each frame). The 3,456-facet scan +
## enumeration runs ONLY when the active facet changed (crossing) or the wanted set was never built — a still player
## costs one int compare. Enumerated facets are cached; facets that drop out of the band are LRU-evicted.
func refresh(active_fid: int) -> void:
	if active_fid == _active_fid and not _wanted_dirty and _wanted.size() > 0:
		return
	_active_fid = active_fid
	_wanted_dirty = false
	_wanted = _wanted_facets(active_fid)
	for fid in _wanted:
		enumerate_facet(int(fid))
	_evict_unwanted()

## Bump the crossing epoch (WorldManager calls this on a facet crossing). Re-selects the wanted band next refresh.
func set_active(new_fid: int) -> void:
	_epoch += 1
	_active_fid = new_fid
	_wanted_dirty = true

## THE registry query half (§12.5): fresh record dicts for every CACHED wanted facet's houses. The far tier walks
## this concatenated with the tracker's records; it never scans the world.
func records() -> Array:
	var out: Array = []
	for fid in _wanted:
		var recs: Variant = _cache.get(int(fid))
		if recs == null:
			recs = enumerate_facet(int(fid))
		for r in (recs as Array):
			out.append((r as Dictionary).duplicate())
	return out

## Enumerate facet `fid`'s GEN houses (cached). Walks the ≤ ~9 V-cells overlapping the facet domain → live villages'
## HPV×HPV house sub-cells → StructureGen.house_info; a house is emitted to the facet that OWNS its base column
## (FacetAtlas.in_polygon — the placement bijection, so a seam-straddling village splits cleanly, no double models).
func enumerate_facet(fid: int, pcache = null) -> Array:
	var hit: Variant = _cache.get(fid)
	if hit != null:
		_touch(fid)
		return hit
	_dbg_enum_count += 1
	var recs: Array = []
	# Body gate: Earth facets only (StructureGen.has_village gates too, but skip the whole scan for the Moon).
	if FacetAtlas.body_of_fid(fid) != 0:
		_store(fid, recs)
		return recs
	var ctx = pcache if pcache != null else TerrainConfig.GenCtx.new(0, fid)
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var vx0 := floori(float(dmin.x) / float(StructureGen.STRUCT_V))
	var vx1 := floori(float(dmax.x) / float(StructureGen.STRUCT_V))
	var vz0 := floori(float(dmin.y) / float(StructureGen.STRUCT_V))
	var vz1 := floori(float(dmax.y) / float(StructureGen.STRUCT_V))
	for vx in range(vx0, vx1 + 1):
		for vz in range(vz0, vz1 + 1):
			if not StructureGen.has_village(vx, vz, ctx):
				continue
			for ihx in range(StructureGen.STRUCT_HPV):
				for ihz in range(StructureGen.STRUCT_HPV):
					var hx := vx * StructureGen.STRUCT_HPV + ihx
					var hz := vz * StructureGen.STRUCT_HPV + ihz
					var hi := StructureGen.house_info(hx, hz, ctx)
					if hi.is_empty():
						continue
					var base: Vector3i = hi["base"]
					# Ownership: the base column belongs to EXACTLY one facet (the bijection — no seam double-models).
					if not FacetAtlas.in_polygon(fid, base.x, base.z, 0.0):
						continue
					var rec := StructureGen.make_record(fid, hi)
					var root := int(rec["root"])
					if _rev.has(root):
						rec["rev"] = int(_rev[root])   # overlay the damage counter onto the pristine record
					recs.append(rec)
	_store(fid, recs)
	return recs


## §12.5 damage rev: a player edit at (fid, cell) bumps the rev of every cached GEN record on that fid whose bbox
## contains the cell (O(records-on-fid) ≈ a handful). The rev-sum drift re-arms the far tier's delta gate → re-bake →
## the far model shows the hole within ~1-2 s (exactly the player-build path).
func note_edit(fid: int, cell: Vector3i) -> void:
	var recs: Variant = _cache.get(fid)
	if recs == null:
		return
	for r in (recs as Array):
		var rec: Dictionary = r
		if _bbox_has(rec["bmin"], rec["bmax"], cell):
			var root := int(rec["root"])
			var nrev := int(_rev.get(root, 0)) + 1
			_rev[root] = nrev
			rec["rev"] = nrev

static func _bbox_has(bmin: Vector3i, bmax: Vector3i, c: Vector3i) -> bool:
	return c.x >= bmin.x and c.x <= bmax.x and c.y >= bmin.y and c.y <= bmax.y and c.z >= bmin.z and c.z <= bmax.z


# --- wanted-facet band (§12.5) --------------------------------------------------------------------------------------
## Earth facets whose surface centre is within STRUCT_FAR_MAX + facet-radius of the ACTIVE facet's centre (the active
## facet ≈ the player), nearest-first, capped. Camera-independent + deterministic (a pure function of active_fid),
## and only recomputed on a crossing, so the 3,456-facet scan is rare.
func _wanted_facets(active_fid: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if active_fid < 0 or not CubeSphere.FACETED:
		return out
	var ac := _facet_centre(active_fid)
	var facet_radius := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)
	var reach := CubeSphere.STRUCT_FAR_MAX + facet_radius
	var reach2 := reach * reach
	var cand: Array = []
	var earth_n := 6 * FacetAtlas.K * FacetAtlas.K
	for fid in range(earth_n):
		var c := _facet_centre(fid)
		var dx := c.x - ac.x
		var dy := c.y - ac.y
		var dz := c.z - ac.z
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 <= reach2:
			cand.append([d2, fid])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	for i in range(mini(cand.size(), _FACET_CAP)):
		out.append(int(cand[i][1]))
	return out

func _facet_centre(fid: int) -> Vector3:
	var dmn := FacetAtlas.dom_min(fid)
	var dmx := FacetAtlas.dom_max(fid)
	var d := FacetAtlas.cell_dir(fid, (dmn.x + dmx.x) / 2, (dmn.y + dmx.y) / 2)
	return Vector3(float(d.x), float(d.y), float(d.z)) * FacetAtlas.R_BLOCKS


# --- LRU cache bookkeeping (never-OOM) ------------------------------------------------------------------------------
func _store(fid: int, recs: Array) -> void:
	_cache[fid] = recs
	_touch(fid)
	while _lru.size() > _FACET_CAP:
		var victim: int = _lru.pop_back()
		if not _in_wanted(victim):
			_cache.erase(victim)
		else:
			_lru.push_front(victim)                    # never evict a wanted facet; try the next-oldest
			break

func _touch(fid: int) -> void:
	_lru.erase(fid)
	_lru.push_front(fid)

func _evict_unwanted() -> void:
	# Keep the cache bounded to (wanted ∪ recent) — drop cached facets that left the band beyond the cap.
	if _cache.size() <= _FACET_CAP:
		return
	var drop: Array = []
	for fid in _cache.keys():
		if not _in_wanted(int(fid)):
			drop.append(int(fid))
	for fid in drop:
		if _cache.size() <= _FACET_CAP:
			break
		_cache.erase(fid)
		_lru.erase(fid)

func _in_wanted(fid: int) -> bool:
	for f in _wanted:
		if int(f) == fid:
			return true
	return false


# --- telemetry / ledger ---------------------------------------------------------------------------------------------
func enum_count() -> int: return _dbg_enum_count
func cached_facets() -> int: return _cache.size()
func wanted_count() -> int: return _wanted.size()

## NEVER-OOM ledger: cached records + the damage-rev map (dict-entry arithmetic). Bounded by _FACET_CAP facets.
func total_bytes() -> int:
	var recs := 0
	for fid in _cache:
		recs += (_cache[fid] as Array).size()
	return recs * 256 + _rev.size() * 48
