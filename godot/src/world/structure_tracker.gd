class_name StructureTracker
extends RefCounted
## COSMOS STRUCTURES P0 (docs/COSMOS-STRUCTURES-DESIGN.md §4) — incremental identification of PLAYER-built
## structures from the edit overlay. Owned by WorldManager, driven from the TWO overlay write choke points
## (`_write_cell` tail → `note_cell`, `sim_revert_cell` → `note_removed`) so no mutation is missed (CLAUDE.md
## rule 1: nothing else mutates `_edits`). Source-agnostic record shape so P1's generated villages reuse it.
##
## THE MODEL (§4.2):
##  - `_cell_mat` (edit_key:int → material-id:int) is THE source of truth for "which cells are tracked" — a PLACED
##    overlay cell whose material qualifies (mat > 0, NOT snow-family: the snowfall sim writes real overlay snow
##    through the same choke, so a blizzard would otherwise cluster). Keys are the existing `FacetAtlas.edit_key`
##    ints (a total bijection with (fid, cell)); NO new coordinate scheme.
##  - `_parent` / `_clusters` are a union-find + per-root {count, bbox, mats histogram, rev} maintained INCREMENTALLY
##    on placement (O(α(n)), path-halving, iterative — no web-stack recursion). A cluster registers when it crosses
##    the threshold (§4.1: count ≥ STRUCT_MIN_BLOCKS AND bbox extent ≥ STRUCT_MIN_EXTENT on ≥ 2 axes).
##  - REMOVAL can SPLIT a component; exact decremental connectivity is not worth it (§4.2). Law: erase the cell,
##    mark DIRTY, and a debounced (≥ STRUCT_RECLUSTER_MS) `tick()` re-floods ALL tracked cells (bounded by
##    STRUCT_TRACK_MAX) into fresh components + registrations. Until it runs the stale bbox only OVER-covers (the far
##    model lingers one beat too large — cosmetically safe, never a hole).
##
## NEVER-OOM (§4.3): `_cell_mat` is capped at STRUCT_TRACK_MAX (past it, placements are counted but not clustered —
## `_saturated`); the registry is capped at STRUCT_REG_MAX (largest-first). `total_bytes()` is dict-entry arithmetic,
## asserted ≤ the ledger by the gate.
##
## Off ⇒ never constructed (WorldManager guards on FP_STRUCT_DETECT) so this file is pure inert data (byte-identical).

const SOURCE_PLAYER := 0                      # §3 record `source` — P1 generated villages will use SOURCE_GEN
const _MATS_HISTO_MAX := 8                    # §4.2 bounded per-cluster material histogram (≤ 8 distinct ids kept)

# The six face-adjacent lattice offsets (6-connectivity, §4.1). Same-facet only (edit keys are fid-scoped, §4.4).
const _NEIGH := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

var _cell_mat: Dictionary = {}               # edit_key:int → material id (THE tracked-cell set + per-cell material)
var _parent: Dictionary = {}                 # union-find: edit_key → edit_key (root); derived, rebuilt on recluster
var _clusters: Dictionary = {}               # root edit_key → {count, bmin, bmax, mats, rev, fid} (derived)
var _reg: Dictionary = {}                     # root edit_key → registry record (the registered structures)

var _snow_ids: Dictionary = {}               # material ids the snowfall sim writes — EXCLUDED from clustering (§4.1)
var _rev_counter := 0                         # monotone rev source (bumped per cluster mutation — the far delta signal)
var _dirty := false                           # a removal happened; a recluster is pending
var _dirty_at_ms := 0                         # Time.get_ticks_msec() when _dirty was first set (debounce anchor)
var _saturated := false                       # hit STRUCT_TRACK_MAX (telemetry-degrade, log-once)
var _reg_saturated := false                   # hit STRUCT_REG_MAX (telemetry-degrade, log-once)
var _dbg_recluster_count := 0                 # gate read-back: number of reclusters run


func _init() -> void:
	BlockCatalog.ensure_ready()
	for nm in [&"snow_block", &"powder_snow"]:
		var id := BlockCatalog.id_of(nm)
		if id > BlockCatalog.AIR:
			_snow_ids[id] = true


## True iff `mat` is a placed BUILD material (non-air, not snow-family). The one qualify predicate.
func _qualifies_mat(mat: int) -> bool:
	return mat > BlockCatalog.AIR and not _snow_ids.has(mat)


# =====================================================================================================================
# The two choke-point hooks (§4.2). `ek` is the (fid, cell) FacetAtlas.edit_key int; `packed` the new overlay value.
# =====================================================================================================================

## `_write_cell` tail: the cell now carries `packed`. Place (qualifying, newly tracked), material-swap (qualifying,
## already tracked), or remove (non-qualifying — dug air / snow — over a tracked cell).
func note_cell(ek: int, packed: int) -> void:
	var mat := CellCodec.mat(packed)
	var qual := _qualifies_mat(mat)
	var tracked: bool = _cell_mat.has(ek)
	if qual and not tracked:
		if _cell_mat.size() >= CubeSphere.STRUCT_TRACK_MAX:
			if not _saturated:
				_saturated = true
				print("  StructureTracker: STRUCT_TRACK_MAX (", CubeSphere.STRUCT_TRACK_MAX, ") hit — new placements counted, not clustered")
			return                               # degrade, never grow
		_cell_mat[ek] = mat
		_add_cell(ek, mat)
	elif qual and tracked:
		if _cell_mat[ek] != mat:                 # material swap in place — connectivity unchanged, histogram + rev shift
			var old_mat: int = _cell_mat[ek]
			_cell_mat[ek] = mat
			var root := _find(ek)
			if _clusters.has(root):
				var cl: Dictionary = _clusters[root]
				_histo_dec(cl["mats"], old_mat)
				_histo_inc(cl["mats"], mat)
				cl["rev"] = _bump_rev()
				_sync_registration(root)
	elif tracked:                                # non-qualifying over a tracked cell ⇒ removal
		note_removed(ek)


## `sim_revert_cell` (the ONLY `_edits` erase) + the removal path of `note_cell`: the cell is no longer a placed
## structure cell. Erase it; mark DIRTY (a removal can split a component) for the debounced recluster (§4.2).
func note_removed(ek: int) -> void:
	if not _cell_mat.has(ek):
		return
	var root := _find(ek)
	var mat: int = _cell_mat[ek]
	_cell_mat.erase(ek)
	if _clusters.has(root):                       # keep the live record honest until the recluster (over-covers only)
		var cl: Dictionary = _clusters[root]
		cl["count"] = int(cl["count"]) - 1
		_histo_dec(cl["mats"], mat)
		cl["rev"] = _bump_rev()
		_sync_registration(root)
	if not _dirty:
		_dirty = true
		_dirty_at_ms = Time.get_ticks_msec()


## Debounced recluster tick — called each frame by WorldManager. Runs the bounded full re-flood once the removal
## burst has settled (≥ STRUCT_RECLUSTER_MS since the first dirtying removal). No-op when nothing is dirty.
func tick(now_ms: int) -> void:
	if not _dirty:
		return
	if now_ms - _dirty_at_ms < CubeSphere.STRUCT_RECLUSTER_MS:
		return
	_recluster_all()
	_dirty = false


# =====================================================================================================================
# Incremental placement (union-find, §4.2) — make-set then union with each present face-adjacent tracked cell.
# =====================================================================================================================

func _add_cell(ek: int, mat: int) -> void:
	_parent[ek] = ek
	var up: Array = FacetAtlas.edit_key_unpack(ek)
	var fid: int = up[0]
	var cell: Vector3i = up[1]
	_clusters[ek] = {"count": 1, "bmin": cell, "bmax": cell, "mats": {mat: 1}, "rev": _bump_rev(), "fid": fid}
	for d in _NEIGH:
		var nk := FacetAtlas.edit_key(fid, cell + d)
		if _cell_mat.has(nk):
			_union(ek, nk)
	_sync_registration(_find(ek))


## Iterative find with path-halving (no recursion — web stack). Returns the component root.
func _find(x: int) -> int:
	var r: int = x
	while int(_parent.get(r, r)) != r:
		var p := int(_parent[r])
		_parent[r] = int(_parent.get(p, p))       # path-halving
		r = int(_parent[r])
	return r


## Union by count (attach the smaller cluster under the larger); merge the child's record into the parent's.
func _union(a: int, b: int) -> void:
	var ra := _find(a)
	var rb := _find(b)
	if ra == rb:
		return
	var ca: Dictionary = _clusters[ra]
	var cb: Dictionary = _clusters[rb]
	if int(ca["count"]) < int(cb["count"]):       # keep the larger as root
		var t := ra; ra = rb; rb = t
		var tc := ca; ca = cb; cb = tc
	_parent[rb] = ra
	ca["count"] = int(ca["count"]) + int(cb["count"])
	var bmin: Vector3i = ca["bmin"]; var bmax: Vector3i = ca["bmax"]
	var obmin: Vector3i = cb["bmin"]; var obmax: Vector3i = cb["bmax"]
	ca["bmin"] = Vector3i(mini(bmin.x, obmin.x), mini(bmin.y, obmin.y), mini(bmin.z, obmin.z))
	ca["bmax"] = Vector3i(maxi(bmax.x, obmax.x), maxi(bmax.y, obmax.y), maxi(bmax.z, obmax.z))
	for k in (cb["mats"] as Dictionary):
		_histo_add(ca["mats"], int(k), int(cb["mats"][k]))
	ca["rev"] = _bump_rev()
	_clusters.erase(rb)
	if _reg.has(rb):                              # the child root was registered — its record moves under the new root
		_reg.erase(rb)
	_sync_registration(ra)


# =====================================================================================================================
# Removal recluster (§4.2) — bounded full re-flood of all tracked cells into fresh components + registrations.
# =====================================================================================================================

func _recluster_all() -> void:
	_dbg_recluster_count += 1
	_parent.clear()
	_clusters.clear()
	_reg.clear()
	var visited: Dictionary = {}
	var qualifying: Array = []                     # {root, count} candidates for largest-first registry retention
	for seed in _cell_mat.keys():
		if visited.has(seed):
			continue
		# BFS over 6-connectivity through the tracked-cell set (iterative — no recursion).
		var up: Array = FacetAtlas.edit_key_unpack(seed)
		var fid: int = up[0]
		var comp: Array = [seed]
		visited[seed] = true
		var qi := 0
		var count := 0
		var bmin: Vector3i = up[1]; var bmax: Vector3i = up[1]
		var mats: Dictionary = {}
		while qi < comp.size():
			var ek: int = comp[qi]; qi += 1
			var eu: Array = FacetAtlas.edit_key_unpack(ek)
			var cell: Vector3i = eu[1]
			var mat: int = _cell_mat[ek]
			_parent[ek] = seed
			count += 1
			bmin = Vector3i(mini(bmin.x, cell.x), mini(bmin.y, cell.y), mini(bmin.z, cell.z))
			bmax = Vector3i(maxi(bmax.x, cell.x), maxi(bmax.y, cell.y), maxi(bmax.z, cell.z))
			_histo_inc(mats, mat)
			for d in _NEIGH:
				var nk := FacetAtlas.edit_key(fid, cell + d)
				if _cell_mat.has(nk) and not visited.has(nk):
					visited[nk] = true
					comp.append(nk)
		_clusters[seed] = {"count": count, "bmin": bmin, "bmax": bmax, "mats": mats, "rev": _bump_rev(), "fid": fid}
		if _is_structure(count, bmin, bmax):
			qualifying.append({"root": seed, "count": count})
	# Registry retention: largest-first up to STRUCT_REG_MAX (§4.3).
	qualifying.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
	_reg_saturated = qualifying.size() > CubeSphere.STRUCT_REG_MAX
	for i in range(mini(qualifying.size(), CubeSphere.STRUCT_REG_MAX)):
		var root: int = qualifying[i]["root"]
		_reg[root] = _make_record(root)


# =====================================================================================================================
# Registration (§4.1/§4.3) — a cluster is a structure at ≥ STRUCT_MIN_BLOCKS AND extent ≥ STRUCT_MIN_EXTENT on ≥ 2 axes.
# =====================================================================================================================

func _is_structure(count: int, bmin: Vector3i, bmax: Vector3i) -> bool:
	if count < CubeSphere.STRUCT_MIN_BLOCKS:
		return false
	var axes := 0
	if bmax.x - bmin.x + 1 >= CubeSphere.STRUCT_MIN_EXTENT: axes += 1
	if bmax.y - bmin.y + 1 >= CubeSphere.STRUCT_MIN_EXTENT: axes += 1
	if bmax.z - bmin.z + 1 >= CubeSphere.STRUCT_MIN_EXTENT: axes += 1
	return axes >= 2


## Incremental registration sync for a live root (add/refresh/remove), honouring the largest-first REG_MAX cap.
func _sync_registration(root: int) -> void:
	if not _clusters.has(root):
		_reg.erase(root)
		return
	var cl: Dictionary = _clusters[root]
	var ok := _is_structure(int(cl["count"]), cl["bmin"], cl["bmax"])
	if ok:
		if _reg.has(root) or _reg.size() < CubeSphere.STRUCT_REG_MAX:
			_reg[root] = _make_record(root)
		else:
			# At cap — evict the smallest registered structure if this one is larger (largest-first, §4.3).
			var small_root := -1
			var small_ct := 0x7fffffff
			for r in _reg:
				var c: int = int(_reg[r]["count"])
				if c < small_ct:
					small_ct = c; small_root = r
			if int(cl["count"]) > small_ct and small_root != -1:
				_reg.erase(small_root)
				_reg[root] = _make_record(root)
			else:
				_reg_saturated = true
	else:
		_reg.erase(root)


## §3 record shape (source-agnostic — P1 GEN villages produce the same). Fresh dict each call (the far tier snapshots).
func _make_record(root: int) -> Dictionary:
	var cl: Dictionary = _clusters[root]
	return {
		"source": SOURCE_PLAYER,
		"root": root,
		"fid": int(cl["fid"]),
		"bmin": cl["bmin"],
		"bmax": cl["bmax"],
		"rev": int(cl["rev"]),
		"count": int(cl["count"]),
		"mats": (cl["mats"] as Dictionary).duplicate(),
		"max_extent": _max_extent(cl["bmin"], cl["bmax"]),
	}


static func _max_extent(bmin: Vector3i, bmax: Vector3i) -> int:
	return maxi(maxi(bmax.x - bmin.x + 1, bmax.y - bmin.y + 1), bmax.z - bmin.z + 1)


# --- bounded material histogram helpers (§4.2, ≤ 8 distinct ids) ------------------------------------------------------
func _histo_inc(h: Dictionary, mat: int) -> void:
	_histo_add(h, mat, 1)

func _histo_add(h: Dictionary, mat: int, n: int) -> void:
	if h.has(mat):
		h[mat] = int(h[mat]) + n
	elif h.size() < _MATS_HISTO_MAX:
		h[mat] = n
	# else: drop (bounded) — the dominant materials are already tracked; the tail never changes the majority colour

func _histo_dec(h: Dictionary, mat: int) -> void:
	if h.has(mat):
		var v := int(h[mat]) - 1
		if v <= 0:
			h.erase(mat)
		else:
			h[mat] = v

func _bump_rev() -> int:
	_rev_counter += 1
	return _rev_counter


# =====================================================================================================================
# Public read API (the far tier + the gate).
# =====================================================================================================================

## The registered structures, as fresh record dicts. The FacetFarStructures tier walks this (never the world).
func registry() -> Array:
	var out: Array = []
	for root in _reg:
		out.append(_reg[root])
	return out

## Sum of registered structures' revs — the far tier's rebuild-delta latch (a bump ⇒ some structure changed).
func rev_sum() -> int:
	var s := 0
	for root in _reg:
		s += int(_reg[root]["rev"])
	return s

func tracked_count() -> int: return _cell_mat.size()
func registry_count() -> int: return _reg.size()
func is_saturated() -> bool: return _saturated
func is_reg_saturated() -> bool: return _reg_saturated
func recluster_count() -> int: return _dbg_recluster_count
func is_dirty() -> bool: return _dirty

## NEVER-OOM ledger (§8): dict-entry arithmetic across the tracked-cell store + union-find + cluster records + registry.
func total_bytes() -> int:
	# ~48 B/dict-entry worst (GDScript Variant key+value + hash slot); registry records carry a small mats dict (~96 B).
	var cell_b := _cell_mat.size() * 48
	var parent_b := _parent.size() * 48
	var cluster_b := _clusters.size() * 160
	var reg_b := _reg.size() * 224
	return cell_b + parent_b + cluster_b + reg_b
