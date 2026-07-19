class_name FacetSkinTier
extends Node3D
## COSMOS SEAMLESS-SCALES §4/§10 C3 — the heightfield SKIN tier (flag CubeSphere.FP_SKIN_TIER).
##
## THE GAP IT FILLS. Between the near voxel field (0..~128 blocks — FacetLodMesher / FacetSlots) and the
## whole-planet far-ring backstop (~12.5-block cells, FP_FARRING_FULL_COVER) there is a resolution gap:
## post-L5 the voxel meshes still ARRIVE over ~1 s and until they do the ground shape is only the coarse
## backstop (the obs-2/3 "the ground changes as blocks arrive" pop). The skin is a cheap per-column
## heightfield that covers that annulus IMMEDIATELY from `sample_columns` (§7.2 item 2: one C++ call per
## tile, ~1-3 ms) so the surroundings are visually complete in ~1 s instead of ~45 s.
##
## COMPOSITION (SEAMLESS-SCALES §0.5 / §5.1 — overlap + shared sampling + sink, NOT a cross-fade). The
## skin is built in ABSOLUTE planet coords (like the far ring) and SUNK `SINK` blocks radially inward, so
## the opaque near voxels strictly OVERDRAW it (a voxel block arriving changes the surface by <= the sink
## bias, sub-pixel — never a gap) and it OVERDRAWS the far-ring backstop (finer wins where present; the
## backstop is already correct where the skin has not reached). No alpha, no z-fight.
##
## ONE-SAMPLER LAW (§7.1). Every height/biome/water/colour comes from `_sampler` — a Callable that routes
## to the ONE worldgen core: the compiled VoxelGeneratorCosmos.sample_columns when present, else the
## GDScript oracle (TerrainConfig.column_profile + FarPalette, byte-equal to the C++ path by G-CG-COLUMNS).
## There is NO independent height function here; a second one would crack at a facet ridge.
##
## DRAW-CALL DISCIPLINE (§10 C3 ledger "≤50 draws / merge-per-facet fallback"). Tiles do NOT each get a
## MeshInstance3D — that was ~114 draws at the shipped tile count (measured live: standing fps 60→30,
## draws 90→204, the exact vsync-ladder ceiling the atlas rescued us from). Instead a facet's tiles are
## MERGED into ONE ArrayMesh surface on ONE MeshInstance3D per LIVE FACET (§ "Part A"): draws drop to
## ≈ the live-facet count (active + a few neighbours, ≤~6). The merge is INCREMENTAL — only a facet whose
## tile set changed this update() is re-merged (a pure PackedArray concat + one upload, main-thread-cheap;
## the per-tile _sampler.call count is UNCHANGED, so no new apply-bound cost). Per-tile geometry is kept
## CPU-side (the merge source of truth) so a re-merge never re-samples — it is memcpy-cheap.
##
## OWNERSHIP DEDUP (§ "Part B"). Facet DOMAIN BOXES overlap at K=24 seams (MARGIN_CELLS apron + the quad's
## AABB corners), so the un-deduped skin covered every seam region from TWO facets (~2× tiles for a given
## reach). Each tile is now owned by exactly ONE facet: the one whose EXACT polygon contains the tile
## centre (`FacetAtlas.in_polygon(fid, cx, cz, 0)`). Adjacent facet polygons TILE the sphere (partition,
## share edges), so a tile centre lies in exactly one — deterministic, and the SAME partition the near
## voxel field already uses (junction_modify masks foreign cells to AIR). Because a TILE (32 blocks) is far
## wider than the ownership granularity, tiles straddling a polygon edge extend ~half a tile past it, so the
## two owners' tiles meet with a natural sub-tile overlap band across the ridge — no crack, exactly as the
## overlap contract requires (and the far-ring backstop still underlies any residual sliver). WITHIN a facet
## adjacent tiles share their boundary column bit-for-bit (G-SKIN-EDGE) — dedup does not touch that.
##
## NEVER-OOM (§10 C3 ledger). A HARD `MAX_BYTES` ceiling (8 MB) on the TRUE footprint. The merge keeps the
## per-tile vertex data CPU-side (the merge source) AND the RenderingServer keeps the uploaded copy, so the
## true peak is ~2× the vertex bytes — `total_bytes()` reports that 2× footprint and the ceiling binds on
## IT (source is therefore capped at ~4 MB). Tiles are added nearest-first and the farthest evicted when the
## budget would be exceeded — memory safety outranks coverage. Dedup removes the ~2× seam redundancy, which
## recovers the reach the 2× footprint accounting costs: the skin stays memory-neutral vs the shipped
## per-tile version at the SAME reach while cutting draws ~20×. CDLOD morph, pitch-2/4/8 extension rings and
## tree impostors are LATER stages (§4.2/§4.3), deliberately NOT built here.
##
## Flag OFF (default) == byte-identical: WorldManager never creates this node, so nothing changes. FACETED
## only (like FacetFarRing) — the flat world has no facets/atlas; under FLAT the node is never created.

const TILE := 32                     # columns per tile edge (pitch 1). Adjacent tiles SHARE their boundary
                                     # column (tile tx spans [tx·TILE .. tx·TILE+TILE] inclusive), so a
                                     # shared vertex is sampled from the SAME integer (fid,x,z) on both —
                                     # bit-identical by construction (the shared-edge rule, §7 / G-SKIN-EDGE).
const SINK := 1.5                    # the v1 depth-composition knob (blocks). See _compose_position — this is
                                     # HOW the skin defers to the exact voxels, kept separate from WHAT the tile
                                     # is (the geometry below never reads SINK except through _compose_position).
const R_INNER := 64.0                # skip tiles wholly inside this radius: the near voxel disc (0..~128)
                                     # already covers there, so spending the budget on the 96..256 annulus
                                     # (where the arriving-mesh frontier leaves the coarse backstop showing)
                                     # reaches much further out. A one-tile overlap is kept so the skin still
                                     # underlies the near disc's edge (no ring gap while meshes stream in).
const R_OUTER := 256.0               # target coverage radius (blocks). Actual reach is capped by MAX_BYTES.
const MAX_BYTES := 8 * 1024 * 1024   # §10 C3 hard ceiling on the TRUE footprint (source + render copy).
const RENDER_COPY_FACTOR := 2        # true peak = CPU merge-source arrays + the RenderingServer upload of the
                                     # merged mesh ≈ 2× the vertex bytes. The ceiling binds on this footprint,
                                     # so `_src_bytes` (the counted vertex data) is effectively capped at 4 MB.

# --- COVERED-TILE SKIP (the overdraw fix, §10 C3 "underlay contract") -----------------------------
# The measured cost of the skin was NOT draws (the merge fixed those — 189 both ways) but FILL: a skin
# tile in the 64..128 band renders BEHIND the opaque near voxels, and on the gl_compatibility web path a
# shaded opaque fragment is not reliably early-z-rejected (no depth prepass; hardware early-z of a lit
# fragment is best-effort and weak on a throttled integrated GPU), so those occluded fragments shade for
# nothing — close to the camera, at high pixel density. A tile whose whole footprint is inside CONFIRMED-
# MESHED near coverage is therefore pure overdraw: we DON'T emit it (the underlay contract the far ring
# already uses). Tiles over UNMESHED near regions (streaming holes) or beyond the near radius still render
# — that is the skin's actual job (immediate gap-fill + the annulus). Coverage is queried via a Callable
# (fid, fid-lattice AABB) -> bool routed to module_world.skin_near_meshed (godot_voxel is_area_meshed);
# an INVALID callable (no module / fallback path) means "never covered" → byte-identical to pre-skip.
const NEAR_COVER_R := 144.0          # only PROBE tiles within this radius for coverage — the near field can
                                     # only cover ~128; beyond it the annulus always renders (no probe cost).
const COVER_Y_MARGIN := 40.0         # the coverage AABB's radial half-band around the tile's sampled surface
                                     # (mirrors pool_seam_meshed's 40): tall enough to span the meshed surface
                                     # shell, short enough to stay inside the loaded vertical extent (a band
                                     # past the view distance would read un-meshed air blocks → false → render).
const REAP_INTERVAL_MS := 100        # while STANDING, re-probe the built tiles' coverage at most this often
                                     # (10 Hz) — enough to catch the ~1 s post-stop mesh settle, cheap enough
                                     # that the transient probe cost is nil, and it self-terminates once the
                                     # covered tiles are evicted (nothing left within NEAR_COVER_R to probe).
const COVER_CONFIRM := 2             # anti-churn hysteresis: a tile must read covered on COVER_CONFIRM
                                     # CONSECUTIVE re-evals (each a ≥TILE·0.5 move, since update() early-returns
                                     # while stationary) before it is dropped from the merge; ANY exposed read
                                     # resets it and it renders immediately (gap-fill promptness outranks a rare
                                     # pace-across-boundary churn). So a streaming boundary that flickers each
                                     # beat never reaches the skip and never thrashes the re-merge.

var _sampler: Callable               # (fid:int, packed:PackedInt64Array) -> {heights,biomes,water,colors}
var _sampler_obj: Object = null      # STRONG ref to the sampler's object (the compiled generator is a
                                     # RefCounted a Callable does NOT keep alive) — held so it is not freed
                                     # out from under _sampler mid-session (else every sample returns null).
var _active_fid := -1
var _anchor_offset: Vector3 = Vector3.ZERO   # fixed-frame floating-origin shift, mirrored from the far ring
var _mat: Material                   # StandardMaterial3D normally; the biased tier ShaderMaterial under FP_TIER_DEPTH_BIAS (P3)
# Per-tile geometry (the merge source of truth). key "fid:tx:tz" ->
#   {fid:int, bytes:int, dist:float, pos:PackedVector3Array, nrm:PackedVector3Array, col:PackedColorArray, idx:PackedInt32Array}
var _tiles: Dictionary = {}
# Per LIVE FACET: the ONE merged draw call. fid -> {mi:MeshInstance3D, keys:Dictionary(tileKey->true)}.
var _facets: Dictionary = {}
var _src_bytes := 0                  # sum of the per-tile vertex bytes (the CPU merge source). Footprint = 2×.
var _last_center := Vector3(1e18, 1e18, 1e18)   # last player world pos an update scheduled from
# Covered-tile skip hysteresis: tileKey -> count of CONSECUTIVE covered re-evals (see COVER_CONFIRM). Pruned
# to the current candidate set each update() so it stays bounded by the annulus tile count (a few KB of ints).
var _cover_hold: Dictionary = {}
var _last_reap_ms := 0               # throttle clock for the standing-still coverage reap (REAP_INTERVAL_MS)

# --- lifecycle -----------------------------------------------------------------------------------

## Build this epoch's sampler and stand the skin up. The compiled generator (a RefCounted a Callable does
## NOT keep alive) is held in the `_sampler_obj` MEMBER from the moment it is created, so it is never freed
## out from under `_sampler` — the bug of returning only a Callable and letting the gen die. Falls back to
## the GDScript oracle (byte-equal by G-CG-COLUMNS) when the compiled class is absent.
func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_sampler_obj = _build_cpp_gen(active_fid)
	if _sampler_obj != null:
		_sampler = Callable(_sampler_obj, "sample_columns")
	else:
		push_warning("FacetSkinTier: VoxelGeneratorCosmos absent — using the GDScript oracle sampler (slow).")
		_sampler = Callable(FacetSkinTier, "gd_sample")
	_mat = _make_material()
	transform = _placement_xform()

## Crossing: the active facet changed. Tiles are keyed by fid so they PERSIST across a crossing (a
## neighbour facet's tiles stay valid); only the placement (identity under the fixed frame) is re-set.
func set_active(new_fid: int) -> void:
	_active_fid = new_fid
	transform = _placement_xform()

## Fixed-frame re-anchor: slide the absolute skin mesh by −A in lockstep with PlanetRoot + the far ring.
func shift_anchor(a: Vector3) -> void:
	if not _fixed_frame_on():
		return
	_anchor_offset += a
	transform = _placement_xform()

func _fixed_frame_on() -> bool:
	return CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL

## Same placement law as FacetFarRing: identity (minus the re-anchor offset) under the fixed frame, so the
## ABSOLUTE-coord mesh renders in the scene frame; else T_active⁻¹ (re-place absolute into active-lattice).
## One node transform covers EVERY facet's merged mesh — they are all absolute-coord children of this node.
func _placement_xform() -> Transform3D:
	if _fixed_frame_on():
		return Transform3D(Basis.IDENTITY, -_anchor_offset)
	return FacetAtlas.facet_transform(_active_fid).affine_inverse()

# --- scheduling ----------------------------------------------------------------------------------

## Per-frame (from WorldManager.update_streaming): schedule the tiles whose facet columns fall within
## R_OUTER of the player, nearest-first, under the byte ceiling; evict tiles that fell out of range or
## past the budget. `player_lattice` is the player's (x,y,z) in the ACTIVE facet lattice (the frame
## WorldManager already works in); `fids` are the candidate facets to skin (active + front neighbours).
##
## Only facets whose tile set CHANGED this call are re-merged at the end (the incremental merge, main-thread
## cheap — no re-sample). The TILE·0.5 hysteresis keeps this (and the re-merge) from firing every frame.
func update(active_fid: int, player_lattice: Vector3, fids: PackedInt32Array,
		cover_query: Callable = Callable()) -> void:
	_active_fid = active_fid
	var pw := _lattice_world(active_fid, player_lattice.x, player_lattice.y, player_lattice.z)
	# Small hysteresis: only RESCHEDULE (the expensive rank/build over all candidate facets) when the player
	# moved enough to matter — never per frame. But the near field finishes MESHING ~1 s AFTER the player
	# stops (streaming lag), and that is exactly when the covered-tile skip must drop the now-hidden tiles —
	# the standing-still overdraw the fix targets. So while stationary we still run a CHEAP, self-terminating
	# coverage REAP of the tiles already built (throttled; no rank, no new builds): it evicts each tile as the
	# near voxels below it confirm meshed, then goes quiet (nothing left to evict → no re-merge). No-op without
	# a cover_query (the fallback / no-module path) → byte-identical to the movement-only schedule.
	if pw.distance_to(_last_center) < float(TILE) * 0.5 and _tiles.size() > 0:
		if cover_query.is_valid() and _reap_due():
			_reap_covered(pw, cover_query)
		return
	_last_center = pw

	var dirty := {}                                # fids whose tile set changed → re-merge at the end
	# Rank every in-range, OWNED tile by distance (nearest-first, dist-sorted ascending).
	var wanted := _rank_tiles(pw, fids)            # Array of [dist, fid, tx, tz]

	# PHASE 1 — decide the KEEP set (rank + covered-tile skip), WITHOUT building. The covered-tile skip
	# advances the hysteresis streak for EVERY candidate (not just built ones), so a whole band confirms
	# together and, once confirmed, stays skipped — no per-beat flip. An invalid cover_query (no module /
	# fallback) never skips → keep == every in-range tile → byte-identical to the pre-skip schedule.
	var keep := {}                                 # key -> true for tiles that SHOULD render this beat
	var seen := {}                                 # every candidate key (for _cover_hold pruning)
	for entry in wanted:
		var key: String = _key(int(entry[1]), int(entry[2]), int(entry[3]))
		seen[key] = true
		if not _tile_covered(int(entry[1]), int(entry[2]), int(entry[3]), float(entry[0]), cover_query):
			keep[key] = true
	# PHASE 2 — evict tiles no longer kept (out of range / now covered) FIRST, so the byte budget below
	# reflects only the surviving set. (Evicting before building is what stops a band flipping covered from
	# transiently pinning the budget with about-to-die tiles and starving the frontier — the churn trap.)
	for key in _tiles.keys():
		if not keep.has(key):
			dirty[int(_tiles[key]["fid"])] = true
			_evict(key)
	# PHASE 3 — build the kept tiles that aren't present yet, nearest-first, under the 8 MB ceiling.
	for entry in wanted:
		var fid := int(entry[1])
		var key2: String = _key(fid, int(entry[2]), int(entry[3]))
		if not keep.has(key2) or _tiles.has(key2):
			continue
		var m := _build_tile(fid, int(entry[2]), int(entry[3]))
		if m.is_empty():
			continue
		var b: int = m["bytes"]
		if (_src_bytes + b) * RENDER_COPY_FACTOR > MAX_BYTES:
			# Budget bound: stop adding (the rest of the annulus is the far ring's job). NEVER-OOM.
			break
		m["dist"] = float(entry[0])
		_tiles[key2] = m
		_src_bytes += b
		_register_key(fid, key2)
		dirty[fid] = true
	# Prune the hysteresis map to this beat's candidate set so it stays bounded (a tile that left the
	# annulus entirely drops its streak; a re-entrant tile re-confirms from scratch).
	for key in _cover_hold.keys():
		if not seen.has(key):
			_cover_hold.erase(key)
	# Incremental merge: rebuild ONLY the facets whose tile set changed (§ Part A).
	for fid in dirty.keys():
		_remerge_facet(int(fid))

## COVERED-TILE SKIP decision (the overdraw fix). Returns true only when tile (fid,tx,tz) is CONFIRMED to
## sit wholly inside meshed near coverage — so it renders behind the opaque near voxels for nothing. Two
## guards keep the skin's real job intact: (1) tiles past NEAR_COVER_R (the annulus / beyond the near field)
## are never skipped — the near voxels cannot cover them; (2) COVER_CONFIRM consecutive covered re-evals are
## required before a skip, and ANY exposed read resets the streak and renders immediately, so a streaming
## hole (the gap-fill case) is filled promptly and a flickering boundary never thrashes the merge. An invalid
## `cover_query` (no module / fallback path) always returns false → the skip is inert (byte-identical).
func _tile_covered(fid: int, tx: int, tz: int, dist: float, cover_query: Callable) -> bool:
	var key := _key(fid, tx, tz)
	if not cover_query.is_valid() or dist > NEAR_COVER_R:
		_cover_hold.erase(key)                     # out of the near field / no query → render, reset streak
		return false
	if not _probe_covered(fid, tx, tz, cover_query):
		_cover_hold.erase(key)                     # exposed (a hole, or the near field hasn't meshed here yet)
		return false
	var streak := int(_cover_hold.get(key, 0)) + 1
	_cover_hold[key] = streak
	return streak >= COVER_CONFIRM                 # skip only once confirmed-covered for COVER_CONFIRM beats

## Is tile (fid,tx,tz)'s whole footprint meshed in the near field? Sample the 5 extreme columns (4 corners +
## centre — cheap vs the 1089-column full build) to bound the tile's surface height, then ask `cover_query`
## whether the fid-lattice AABB spanning that footprint ± COVER_Y_MARGIN is fully meshed (godot_voxel
## is_area_meshed, which is true only when EVERY mesh block in the box is applied — exactly "fully behind
## confirmed near voxels"). A partly-streamed tile reads false → renders (gap-fill preserved).
func _probe_covered(fid: int, tx: int, tz: int, cover_query: Callable) -> bool:
	var ox := tx * TILE
	var oz := tz * TILE
	var probe := PackedInt64Array([
		_pack_xz(ox, oz), _pack_xz(ox + TILE, oz), _pack_xz(ox, oz + TILE),
		_pack_xz(ox + TILE, oz + TILE), _pack_xz(ox + TILE / 2, oz + TILE / 2)])
	var res: Dictionary = _sampler.call(fid, probe)
	var h: PackedFloat32Array = res["heights"]
	if h.size() < 5:
		return false                               # bad sample → treat as exposed (render, never over-skip)
	var gmin := h[0]
	var gmax := h[0]
	for i in range(1, h.size()):
		gmin = minf(gmin, h[i])
		gmax = maxf(gmax, h[i])
	var aabb := AABB(Vector3(float(ox), gmin - COVER_Y_MARGIN, float(oz)),
		Vector3(float(TILE), (gmax - gmin) + 2.0 * COVER_Y_MARGIN, float(TILE)))
	return bool(cover_query.call(fid, aabb))

## Is the standing-still coverage reap due (≥ REAP_INTERVAL_MS since the last one)? Throttles the reap to
## ~10 Hz so the per-tile probe cost stays negligible during the ~1 s the near field takes to settle.
func _reap_due() -> bool:
	return Time.get_ticks_msec() - _last_reap_ms >= REAP_INTERVAL_MS

## Standing-still reap: re-probe ONLY the tiles already built (no rank, no new builds) and evict any that
## have since become CONFIRMED-covered by the near field meshing in below them. Self-terminating — once the
## covered tiles are gone the survivors are the annulus (dist > NEAR_COVER_R → the probe short-circuits, no
## sample) and any genuine holes (still exposed → kept), so subsequent reaps find nothing to evict and issue
## no re-merge. This is what removes the overdraw the player sees while STANDING (the measured 20 fps hit),
## which the movement-gated schedule alone cannot, because it never re-evaluates while the player is still.
func _reap_covered(pw: Vector3, cover_query: Callable) -> void:
	_last_reap_ms = Time.get_ticks_msec()
	var dirty := {}
	for key in _tiles.keys():
		var t: Dictionary = _tiles[key]
		var fid := int(t["fid"])
		var parts: PackedStringArray = key.split(":")
		var tx := int(parts[1])
		var tz := int(parts[2])
		var c := _lattice_world(fid, float(tx * TILE + TILE / 2), 0.0, float(tz * TILE + TILE / 2))
		if _tile_covered(fid, tx, tz, pw.distance_to(c), cover_query):
			dirty[fid] = true
			_evict(key)
	for fid in dirty.keys():
		_remerge_facet(int(fid))

## Test seam (verify_skin G-SKIN-COVER standing case): run one reap immediately, bypassing the throttle, so
## the gate can drive the standing-still eviction deterministically without wall-clock delays.
func gate_reap(active_fid: int, player_lattice: Vector3, cover_query: Callable) -> void:
	_active_fid = active_fid
	var pw := _lattice_world(active_fid, player_lattice.x, player_lattice.y, player_lattice.z)
	_reap_covered(pw, cover_query)

## The candidate tiles within R_OUTER of the player AND owned by their facet, as [dist, fid, tx, tz],
## sorted nearest-first. Ownership (Part B): a tile belongs to `fid` iff its CENTRE column is inside fid's
## exact polygon — `in_polygon(grow=0)`. Adjacent facet polygons partition the sphere, so each world region
## is skinned once (no seam-box double coverage), the same partition the near voxel field uses.
func _rank_tiles(pw: Vector3, fids: PackedInt32Array) -> Array:
	var out: Array = []
	for fid in fids:
		var lo := FacetAtlas.dom_min(fid)
		var hi := FacetAtlas.dom_max(fid)
		var tx0 := int(floor(float(lo.x) / float(TILE)))
		var tx1 := int(floor(float(hi.x) / float(TILE)))
		var tz0 := int(floor(float(lo.y) / float(TILE)))
		var tz1 := int(floor(float(hi.y) / float(TILE)))
		for tx in range(tx0, tx1 + 1):
			for tz in range(tz0, tz1 + 1):
				var cx := tx * TILE + TILE / 2
				var cz := tz * TILE + TILE / 2
				if not FacetAtlas.in_polygon(fid, cx, cz, 0.0):
					continue                          # owned by a neighbour facet (Part B dedup)
				var w := _lattice_world(fid, float(cx), 0.0, float(cz))
				var d := pw.distance_to(w)
				if d >= R_INNER - float(TILE) and d <= R_OUTER + float(TILE):
					out.append([d, fid, tx, tz])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out

## Drop a tile from the source dict + its facet's key set + the byte counter. Marks nothing dirty itself
## (the caller batches the re-merge); a facet left with zero tiles is torn down by _remerge_facet.
func _evict(key: String) -> void:
	var t: Dictionary = _tiles[key]
	var fid := int(t["fid"])
	_src_bytes -= int(t["bytes"])
	if _facets.has(fid):
		(_facets[fid]["keys"] as Dictionary).erase(key)
	_tiles.erase(key)

func _register_key(fid: int, key: String) -> void:
	if not _facets.has(fid):
		_facets[fid] = {"mi": null, "keys": {}}
	(_facets[fid]["keys"] as Dictionary)[key] = true

# --- per-facet merge (§ Part A — the ONE draw call per live facet) --------------------------------

## Rebuild facet `fid`'s single merged surface from its current tiles' CPU-side geometry and (re)assign it
## to the facet's one MeshInstance3D. Pure PackedArray concat + one upload — no _sampler call, so it is
## main-thread cheap and adds NO apply-bound cost (the sampling already happened in _build_tile). A facet
## with no tiles is torn down (its draw call removed). Called once per dirty facet per update().
func _remerge_facet(fid: int) -> void:
	if not _facets.has(fid):
		return
	var rec: Dictionary = _facets[fid]
	var keys: Dictionary = rec["keys"]
	if keys.is_empty():
		# No tiles left → remove the draw call entirely.
		var mi_gone: MeshInstance3D = rec["mi"]
		if mi_gone != null:
			mi_gone.queue_free()
		_facets.erase(fid)
		return

	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	# Pre-size so the concat is a memcpy fill, not a growth cascade (all tiles share stride² verts).
	var stride := TILE + 1
	var vper := stride * stride
	var iper := TILE * TILE * 6
	var ntiles := keys.size()
	pos.resize(vper * ntiles)
	nrm.resize(vper * ntiles)
	col.resize(vper * ntiles)
	idx.resize(iper * ntiles)
	var voff := 0
	var ioff := 0
	for key in keys.keys():
		var t: Dictionary = _tiles[key]
		var tp: PackedVector3Array = t["pos"]
		var tn: PackedVector3Array = t["nrm"]
		var tc: PackedColorArray = t["col"]
		var ti: PackedInt32Array = t["idx"]
		var nv := tp.size()
		for i in range(nv):
			pos[voff + i] = tp[i]
			nrm[voff + i] = tn[i]
			col[voff + i] = tc[i]
		var ni := ti.size()
		for j in range(ni):
			idx[ioff + j] = ti[j] + voff        # re-base this tile's indices into the merged vertex buffer
		voff += nv
		ioff += ni

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var mi: MeshInstance3D = rec["mi"]
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _mat
		mi.name = "skin_facet_%d" % fid
		rec["mi"] = mi
		add_child(mi)
	mi.mesh = mesh

# --- tile construction (the ONE place tile geometry is made; used by update AND the gate) ----------

## Build facet `fid`'s tile (tx,tz): sample its (TILE+1)² columns in ONE _sampler call, place each column
## vertex at its ABSOLUTE world height SUNK by SINK, colour it from the palette. Returns the CPU-side
## geometry {fid,bytes,pos,nrm,col,idx} (the merge source of truth) or {} on a bad sample. NOT added to any
## mesh here — the facet's tiles are merged together by _remerge_facet.
func _build_tile(fid: int, tx: int, tz: int) -> Dictionary:
	var ox := tx * TILE
	var oz := tz * TILE
	var stride := TILE + 1
	var packed := PackedInt64Array()
	packed.resize(stride * stride)
	var k := 0
	for gj in range(stride):
		for gi in range(stride):
			packed[k] = _pack_xz(ox + gi, oz + gj)
			k += 1
	var res: Dictionary = _sampler.call(fid, packed)
	var heights: PackedFloat32Array = res["heights"]
	var colors: PackedColorArray = res["colors"]
	if heights.size() != stride * stride:
		return {}

	var pos := _positions_from(fid, ox, oz, heights)
	var col := PackedColorArray()
	var nrm := PackedVector3Array()
	col.resize(stride * stride)
	nrm.resize(stride * stride)
	for i in range(stride * stride):
		col[i] = colors[i]
		nrm[i] = Vector3.ZERO

	# Indexed quad grid — two tris/cell, memory-optimal (verts shared) so the 8 MB ceiling reaches further.
	var idx := PackedInt32Array()
	idx.resize(TILE * TILE * 6)
	var q := 0
	for cj in range(TILE):
		for ci in range(TILE):
			var i0 := cj * stride + ci
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			idx[q + 0] = i0; idx[q + 1] = i2; idx[q + 2] = i1
			idx[q + 3] = i1; idx[q + 4] = i2; idx[q + 5] = i3
			q += 6
			_accum_normal(nrm, pos, i0, i2, i1)
			_accum_normal(nrm, pos, i1, i2, i3)
	for i in range(nrm.size()):
		var n := nrm[i]
		nrm[i] = n.normalized() if n.length_squared() > 0.0 else Vector3.UP

	var bytes := pos.size() * 12 + nrm.size() * 12 + col.size() * 16 + idx.size() * 4
	return {"fid": fid, "bytes": bytes, "dist": 0.0, "pos": pos, "nrm": nrm, "col": col, "idx": idx}

## THE per-vertex placement (the ONE geometry rule, shared by _build_tile and the shared-edge gate):
## each column's ABSOLUTE world surface point at its sampled height, SUNK SINK blocks radially inward.
## `heights` is the (stride×stride) g array from a _sampler call. Because a column's placement depends
## ONLY on its integer (fid, ox+gi, oz+gj) — never on the tile it belongs to — two adjacent tiles put
## their shared boundary column at bit-identical positions (the shared-edge invariant, G-SKIN-EDGE).
func _positions_from(fid: int, ox: int, oz: int, heights: PackedFloat32Array) -> PackedVector3Array:
	var stride := TILE + 1
	var pos := PackedVector3Array()
	pos.resize(stride * stride)
	for i in range(stride * stride):
		var gi := i % stride
		var gj := i / stride
		var g := int(heights[i])
		var w := _lattice_world(fid, float(ox + gi), float(g), float(oz + gj))
		pos[i] = _compose_position(w)             # geometry hands the TRUE surface point to the ONE
		                                          # composition site; it never applies depth resolution itself
	return pos

## THE composition-mechanism site (the ONLY one). Maps a TRUE world surface point to the position the skin
## renders at so the exact voxels strictly OVERDRAW it and it OVERDRAWS the far-ring backstop — the
## "overlap + shared sampling + sink" contract (SEAMLESS-SCALES §0.5/§5.1). This is a resolution trick, kept
## deliberately SEPARATE from tile geometry (heights/colours/water/shared-edge/ridge exactness are identical
## no matter how depth is resolved): swapping the mechanism must touch ONLY this function.
##
## v1 = a constant radial SINK (push the surface `SINK` blocks toward the planet centre). At the skin's
## operating range (96-256 blocks) binocular depth acuity is ~14-42 blocks, so a 1.5-block sink is ~10-28×
## below the stereo/VR threshold — imperceptible; it stays as v1. It is a pure function of the surface point,
## so two adjacent tiles' shared column (same `w`) still land bit-identically (G-SKIN-EDGE holds).
##
## Future alternatives (NOT built — this is the seam that keeps them a drop-in):
##   (a) distance-scaled polygon offset — return `w` unchanged and bias the DEPTH in the material just enough
##       to break z-fight, scaled with distance to stay under the per-distance stereo threshold (true depth,
##       VR-exact); needs the offset wired on the material, geometry unchanged.
##   (b) true-depth layered composite — return `w` unchanged and render each tier to its own target,
##       compositing by nested coverage; needs Forward+/WebGPU or a depth-texture engine patch (unschedulable
##       in gl_compatibility through Godot 4.7).
func _compose_position(w: Vector3) -> Vector3:
	return w - w.normalized() * SINK

## Gate surface (G-SKIN-EDGE): the raw sunk (stride×stride) positions a tile at lattice origin (ox,oz)
## would build. Takes the origin directly (not tx/tz) so the gate can FALSIFY by perturbing it.
func gate_tile_positions(fid: int, ox: int, oz: int) -> PackedVector3Array:
	var stride := TILE + 1
	var packed := PackedInt64Array()
	packed.resize(stride * stride)
	var k := 0
	for gj in range(stride):
		for gi in range(stride):
			packed[k] = _pack_xz(ox + gi, oz + gj)
			k += 1
	var res: Dictionary = _sampler.call(fid, packed)
	return _positions_from(fid, ox, oz, res["heights"])

static func _accum_normal(nrm: PackedVector3Array, pos: PackedVector3Array, a: int, b: int, c: int) -> void:
	var fn := (pos[b] - pos[a]).cross(pos[c] - pos[a])
	nrm[a] += fn; nrm[b] += fn; nrm[c] += fn

# --- coordinate helpers --------------------------------------------------------------------------

## Absolute planet-coord world point of lattice (fid,x,y,z) as a Vector3 (f32 render coord). The f64
## lattice_to_world64 is the exact placement map the near voxels and far ring use, so the skin lands on
## the same surface they do.
static func _lattice_world(fid: int, x: float, y: float, z: float) -> Vector3:
	var w := FacetAtlas.lattice_to_world64(fid, x, y, z)
	return Vector3(w[0], w[1], w[2])

## Pack a lattice column (x,z) into the int64 sample_columns expects: x low 32 bits, z high 32.
static func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)

func _key(fid: int, tx: int, tz: int) -> String:
	return "%d:%d:%d" % [fid, tx, tz]

## Build the compiled generator frozen for `active_fid`, exactly as module_world/verify_cppgen do (noise
## stack + material tables + frozen atlas + the §7.2 far_colors). Null if the class is not in the binary.
static func _build_cpp_gen(active_fid: int) -> Object:
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		return null
	var gen: Object = ClassDB.instantiate("VoxelGeneratorCosmos")
	if gen == null:
		return null
	var ns := TerrainConfig.noise_stack()
	var cfg := {
		"hills": ns["hills"], "detail": ns["detail"], "continent": ns["continent"],
		"temperature": ns["temperature"], "humidity": ns["humidity"], "mountain": ns["mountain"],
		"seed": ns["seed"], "gen_face": 0, "gen_n": 0, "gen_facet": active_fid,
		"flat_world": true, "faceted": CubeSphere.FACETED, "m5c_corner": CubeSphere.M5C_CORNER,
		"radial_datum": CubeSphere.FP_RADIAL_DATUM,   # COSMOS FS2 §3.2: the skin sample_columns adds S in C++ too
		"cube_arid": PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7]),
		"block_ids": TerrainConfig.appearance_surface_materials(), "model_count": 8, "waterlog": false,
		"id_wood": BlockCatalog.WOOD, "id_leaf": BlockCatalog.LEAF,
		"id_spruce_log": BlockCatalog.id_of(&"spruce_log"), "id_spruce_leaf": BlockCatalog.id_of(&"spruce_leaves"),
		"id_birch_log": BlockCatalog.id_of(&"birch_log"), "id_birch_leaf": BlockCatalog.id_of(&"birch_leaves"),
		"far_colors": FarPalette.frozen_colors(),
	}
	for k in TerrainConfig.material_tables():
		cfg[k] = TerrainConfig.material_tables()[k]
	if CubeSphere.FACETED:
		var atlas := FacetAtlas.frozen_atlas()
		cfg["facet_frame"] = atlas["facet_frame"]
		cfg["facet_off"] = atlas["facet_off"]
		cfg["facet_r_blocks"] = atlas["facet_r_blocks"]
	if not gen.call("setup", cfg):
		return null
	return gen

## The GDScript oracle sampler: the SAME core the C++ path mirrors (byte-equal by G-CG-COLUMNS), used only
## when the compiled class is absent. Returns the §7.2 key set for the packed (x,z) columns of facet `fid`.
static func gd_sample(fid: int, packed: PackedInt64Array) -> Dictionary:
	var n := packed.size()
	var heights := PackedFloat32Array(); heights.resize(n)
	var biomes := PackedInt32Array(); biomes.resize(n)
	var water := PackedByteArray(); water.resize(n)
	var colors := PackedColorArray(); colors.resize(n)
	var ctx = TerrainConfig.GenCtx.new(0, fid) if CubeSphere.FACETED else {}
	for i in range(n):
		var pk: int = packed[i]
		var vx := pk & 0xffffffff
		var x := (vx - 0x100000000) if vx >= 0x80000000 else vx
		var vz := (pk >> 32) & 0xffffffff
		var z := (vz - 0x100000000) if vz >= 0x80000000 else vz
		var pr: Vector4 = TerrainConfig.column_profile(x, z, ctx)
		var g := int(pr.x)
		var biome := int(pr.y)
		var w := g < TerrainConfig.SEA_LEVEL          # water is a TRUE-space property (uses unshifted g)
		# COSMOS FS2 (§3.2): the skin lands on the datum-shifted surface (g + S) so it agrees with the near
		# voxels and the radial far shell (One-Surface Law). S ≡ 0 with FP_RADIAL_DATUM off ⇒ byte-identical.
		heights[i] = float(g + (FacetAtlas.datum_shift(fid, x, z) if CubeSphere.FACETED else 0))
		biomes[i] = biome
		water[i] = 1 if w else 0
		colors[i] = FarPalette.color_for(g, biome, pr.w, w)
	return {"heights": heights, "biomes": biomes, "water": water, "colors": colors}

func _make_material() -> Material:
	# TIER-DEPTH P3 (§5.2): the skin is the middle tier → a 4-quantum window-space depth bias so it loses to the near
	# blocks but beats the far ring at every distance. The biased material is a LIT vertex-colour spatial shader
	# equivalent to the StandardMaterial3D below. Flag off → the shipped StandardMaterial3D verbatim (byte-identical).
	if TierPlace.depth_bias_on():
		return TierPlace.make_biased_material(TierPlace.skin_bias())
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # winding-agnostic (facet transforms may flip)
	m.roughness = 1.0
	return m

# --- gate surface --------------------------------------------------------------------------------

## The ABSOLUTE-coord SUNK vertex the skin renders for column (fid,x,z). The gate asserts adjacent tiles
## agree here bit-for-bit (shared-edge) and that it sits SINK below the true surface (sink gate).
func skin_vertex(fid: int, x: int, z: int) -> Vector3:
	var res: Dictionary = _sampler.call(fid, PackedInt64Array([_pack_xz(x, z)]))
	var g := int((res["heights"] as PackedFloat32Array)[0])
	var w := _lattice_world(fid, float(x), float(g), float(z))
	return _compose_position(w)

## The TRUE (unsunk) absolute surface point for column (fid,x,z) — the sink gate's reference.
func true_vertex(fid: int, x: int, z: int) -> Vector3:
	var res: Dictionary = _sampler.call(fid, PackedInt64Array([_pack_xz(x, z)]))
	var g := int((res["heights"] as PackedFloat32Array)[0])
	return _lattice_world(fid, float(x), float(g), float(z))

## Build a tile and register + merge it exactly as update() would (used by the memory gate's scripted pan).
## No budget enforcement here — the gate asserts the ceiling holds under update()'s enforcement separately.
func gate_add_tile(fid: int, tx: int, tz: int) -> bool:
	var key := _key(fid, tx, tz)
	if _tiles.has(key):
		return true
	var m := _build_tile(fid, tx, tz)
	if m.is_empty():
		return false
	_tiles[key] = m
	_src_bytes += int(m["bytes"])
	_register_key(fid, key)
	_remerge_facet(fid)
	return true

## TRUE footprint (§ NEVER-OOM): the CPU merge-source arrays PLUS the RenderingServer's merged upload
## ≈ 2× the vertex bytes. The 8 MB ceiling binds on this, not on the raw vertex bytes.
func total_bytes() -> int: return _src_bytes * RENDER_COPY_FACTOR
func tile_count() -> int: return _tiles.size()
func has_tile(fid: int, tx: int, tz: int) -> bool: return _tiles.has(_key(fid, tx, tz))

## Draw-count gate surface (G-SKIN-DRAW): the number of live MeshInstance3Ds the skin renders — ONE per
## live facet after the merge, NOT one per tile. This is the whole point of Part A; the gate asserts it is
## ≤ the live-facet count and « tile_count().
func mesh_instance_count() -> int:
	# Count what ACTUALLY renders — MeshInstance3D children of this node — not the _facets bookkeeping, so
	# the gate measures true draw calls and would catch any regression that re-introduced per-tile nodes.
	var n := 0
	for c in get_children():
		if c is MeshInstance3D:
			n += 1
	return n

## The number of distinct facets that currently own at least one tile — the theoretical minimum draw count
## (mesh_instance_count must equal this after every merge).
func distinct_facet_count() -> int:
	var seen := {}
	for key in _tiles.keys():
		seen[int(_tiles[key]["fid"])] = true
	return seen.size()

## Gate/telemetry: the farthest built tile centre from world point `pw`, over ALL facets the skin covers
## (not just the active one) — the honest reach of the current skin under the byte ceiling.
func coverage_radius(pw: Vector3) -> float:
	var best := 0.0
	for key in _tiles.keys():
		var parts: PackedStringArray = key.split(":")
		var f := int(parts[0]); var tx := int(parts[1]); var tz := int(parts[2])
		var c := FacetAtlas.lattice_to_world64(f, float(tx * TILE + TILE / 2), 0.0, float(tz * TILE + TILE / 2))
		best = maxf(best, pw.distance_to(Vector3(c[0], c[1], c[2])))
	return best
