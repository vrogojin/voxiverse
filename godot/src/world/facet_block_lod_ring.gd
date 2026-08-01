class_name FacetBlockLodRing
extends Node3D
## COSMOS BLOCK-LOD P1 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4 + docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §4 override) —
## the FIRST visible decimated-block ring: ONE L1 (2-block pitch) megablock tier engaging at the near rim
## (~128 blocks) and covering the active facet + its 4 ridge neighbours (out to ~700), rendered as REAL greedy-
## meshed extruded blocky geometry OVER the far-ring skin. Closes the near→far RELIEF gap that S1 leaves: climbing
## out of the near voxel field steps 1-block → 2-block pitch (a ≤1-block containment step) instead of the current
## 3D-blocks → flat-paint cliff. This is the block-LOD design's P1, with Fable's §4 override — L1 at the rim, NOT
## L2 at 700 (the transition goal needs the rim ring). The full L2–L4 ladder is P2 (FP_BLOCK_LOD_RINGS), NOT here.
##
## SIBLING of FacetFarRing / FacetSkinTier under WorldManager — GATED CONSTRUCTION: the node/data only exist when
## FP_BLOCK_LOD is on ⇒ byte-identical off (WorldManager never news it up; nothing calls it). Mirrors the far ring's
## discipline: absolute planet coords, per-facet meshes, placed by the SAME node transform the far ring uses (so the
## L1 blocks and the far skin share ONE frame), rebuilt on facet crossings (band = active ∪ ridge-1).
##
## DATA: the P0 FacetBlockLod column pyramid (facet_block_lod.gd) — analytic L0 via TerrainConfig.facet_profile, then
## L1 = decimate(L0) with the §3 MIN-height / MAJORITY-id / OR-water 2× downscale (no-protrusion by containment:
## rendered coarse ≤ true fine terrain everywhere ⇒ never protrudes, structurally improves #72). Real-voxel / _edits
## bake is P4 (FP_BLOCK_LOD_REALBAKE) per design §9 — P1 is analytic, matching the far ring's one-sampler law.
##
## MESHING (§4): per facet, greedy-merged extruded L1 columns — top quads merged across equal-height/equal-id runs
## (ocean/plains → a few quads), interior side quads where a lattice neighbour is lower (corners from the shared
## integer (fid,x,z) lattice via FacetAtlas.lattice_to_world64 ⇒ adjacent columns weld BIT-IDENTICALLY), + a boundary
## SKIRT dropped one coarse pitch on the facet-polygon perimeter (closes the silhouette gap to the sunk backstop). ONE
## MeshInstance/ArrayMesh per facet ⇒ draws ≈ band facets (≤5) ≪ columns (~40k). Vertex-coloured from FarPalette (the
## SAME palette the far ring feeds), UNSHADED, composing with the shell `shade·tint` law (radial normal = normalize(
## wp − MODEL·0)); under FP_SHADE_UNIFIED it string-includes VoxiLight.SHADE_GLSL so L1 lights IDENTICALLY to the near
## blocks AND the far skin (one light law). Arrival DITHER only (§4 temporal): a 0.3 s screen-door discard fade on a
## facet mesh's arrival — NOT a standing spatial band; no transparency/sorting.
##
## COMPOSITION (§6): L1 emits OVER the far-ring skin (the far ring stays as the sunk always-there backstop
## underneath). With S1 (FP_APPROACH_ANCHOR) also on, the near plate recedes into L1 blocks instead of flat paint.
## S1↔L1 RIM COUPLING (SEAMLESS-SCALES §4, implemented): the ring's EFFECTIVE engagement rim (effective_rim) is driven
## by WorldManager from the SAME S1-ramped near view_distance it writes to the viewer — effective_rim =
## min(BLOCK_LOD_L1_RIM_BLOCKS, near_vd) (CubeSphere.block_lod_effective_rim). As S1 shrinks the near field below 128
## the L1 hand-off point tracks it inward so there is NEVER an uncovered annulus (near-edge..128) exposing far skin/L2.
## Because L1 already meshes WHOLE facets (0..facet-edge — the near voxels merely OVERDRAW ≤ rim), tracking the rim is a
## bookkeeping value only: it adds ZERO tiles / triggers NO re-mesh (the inward coverage was always there, revealed as
## the near field recedes). Set only when BOTH FP_APPROACH_ANCHOR and FP_BLOCK_LOD are on; else it stays the static 128.
##
## NEVER-OOM (§5): a hard ledger BLOCK_LOD_BYTES_MAX (16 MB), an LRU cap on resident L1 facet meshes, wholesale-clear
## on breach, and the L1 band bounded to the active facet + ridge-1 neighbours. The gate (verify_block_lod.gd) asserts
## the measured ledger == arithmetic, LRU never evicts the active band, draws ≈ facets, and the no-protrusion + weld
## laws (G-BLD-MIN / G-BLD-PYR / G-BLD-SEAM / G-BLD-BYTES / G-BLD-DRAWS).

# P2 GENERALIZATION (docs/COSMOS-BLOCK-LOD-DESIGN.md §4 ladder) — the level is now a PER-INSTANCE parameter, not a
# const. P1 (FP_BLOCK_LOD) constructs the ring at the default _level==1 (byte-identical to the shipped L1 rim ring);
# the P2 ladder (FacetBlockLodLadder, FP_BLOCK_LOD_RINGS) constructs one ring per level L2..cap via setup(fid, n).
# Everything downstream (pitch, greedy tile size, ledger) derives from _level, so ONE mesher serves the whole ladder.
var _level := 1                        # this ring's pyramid level (1=L1 rim / P1; 2..5 = the P2 ladder tiers)
var _pitch := 2                        # blocks per megablock at this level (1 << _level)
# COSMOS FAR-LOD QUALITY (A) — the radial sink (blocks) applied to EVERY emitted tier vertex (top + side + skirt) so the
# megablock tops sit provably BELOW the near voxel field (no coplanar z-fight / poke-through at the transition). Read
# from the flag-gated static at construction (0.0 when FP_FARLOD_QUALITY is off ⇒ _w is byte-identical). Uniform across
# all levels + a pure function of the world point ⇒ welds stay bit-identical and no inter-level crack is introduced.
# The gate (verify_farlod.gd) forces it on to prove the sink lands the tier ≤ the true analytic surface.
var _farlod_sink := CubeSphere.farlod_block_sink()

# Per-vertex ArrayMesh cost (no NORMAL array — the unshaded shader derives the radial normal): position(12) +
# color(16) + uv(8) = 36 B/vertex; indices are int32 (4 B). The ledger below sums exactly this.
const BYTES_PER_VERT := 36
const BYTES_PER_INDEX := 4

var _active_fid := -1
var _band: Array = []                  # the protected (never-evicted) facet set last streamed — ridge-1 (P1) or ladder-assigned
var _mesh_by_fid: Dictionary = {}      # fid -> MeshInstance3D (one draw per resident facet)
var _bytes_by_fid: Dictionary = {}     # fid -> int (arithmetic mesh bytes; summed into _ledger_bytes)
var _lru: Dictionary = {}              # fid -> last-touched ms (LRU eviction key; band fids never evicted)
var _ledger_bytes := 0                 # Σ _bytes_by_fid — the NEVER-OOM ledger (≤ BLOCK_LOD_BYTES_MAX)
var _byte_cap := CubeSphere.BLOCK_LOD_BYTES_MAX   # per-ring byte ceiling; the ladder lifts this to govern globally
var _lru_cap := CubeSphere.BLOCK_LOD_LRU_FACETS   # per-ring resident-facet cap (residency bound; band never evicted)
var _material: ShaderMaterial = null
var _sun_dir := Vector3(1.0, 0.0, 0.0)
# S1↔L1 rim coupling (SEAMLESS-SCALES §4): the EFFECTIVE inner engagement rim (blocks) where the near voxel field hands
# off to this tier. Static BLOCK_LOD_L1_RIM_BLOCKS (128) by default; driven DOWN to the S1-ramped near view_distance by
# WorldManager (via block_lod_effective_rim) only when FP_APPROACH_ANCHOR is also on. Bookkeeping only — the mesh already
# covers 0..facet-edge (whole facets), so this never re-clips geometry (zero tiles, no re-mesh). The gate reads it back.
var _effective_rim := CubeSphere.BLOCK_LOD_L1_RIM_BLOCKS
var _wholesale_clears := 0             # diagnostics: ledger-breach wholesale clears (gate reads to prove it fired)

# COSMOS MAIN-THREAD ORCHESTRATION TH4 (docs/COSMOS-MAINTHREAD-ORCHESTRATION-DESIGN.md §2 — same worker/commit split
# the §2V FacetTexBaker proved): the ~1 s analytic L0 bake + greedy mesh (_build_facet_arrays, PURE) runs on the TH0
# JobLane WORKER; MAIN pays ONLY the commit (ArrayMesh + add_child + ledger). CONVERGENCE: the whole band (≤5) is
# submitted UP FRONT on arrival/crossing at PRIORITY_BLOCK_LOD (above the far-skin g1 shot convergence), so the units
# COMPUTE in parallel on the lane's free worker slots (not serialized one-per-round-trip) and the active transition
# band fills within a couple of seconds. Each unit carries its OWN staging buffer (a BakeUnit RefCounted, single-
# writer per worker ⇒ no shared-Dictionary race); the MAIN commit stays paced by the lane's per-frame drain budget
# (each upload ≈ 2 ms), so main_commit stays ≈0. During the fill gap the sunk far ring backstops (no hole). The
# offload is live iff a lane was handed in (set_job_lane) — else the synchronous fallback (headless gate / no
# FP_JOB_LANE) drains inline, byte-identical to the P1 build. NEVER-OOM: transient staging is bounded by the lane's
# in-flight slots (≤2) + the ≤6/frame commit drain, freed on commit; the 16 MB committed-mesh ledger is unchanged.
var _lane: JobLane = null
var _worker_on := false                # _lane != null: the async offload is live (main never bakes)
var _inflight: Dictionary = {}         # fid -> BakeUnit: submitted (computing or awaiting commit), NOT yet resident
var _statics_warm := false             # the worker-touched statics (noise / palette) were prewarmed on MAIN
var _dispatch_rounds := 0              # diagnostics: rebuild() calls that submitted ≥1 unit (G-BLD-CONVERGE observable)

## One async bake unit: its own staging buffer so multiple units compute concurrently without sharing a mutable
## structure across threads (the worker writes ONLY its own `arrays`; MAIN reads it in the commit). RefCounted ⇒
## auto-freed once dropped from _inflight after the commit (transient staging, NEVER-OOM).
class BakeUnit:
	extends RefCounted
	var fid := -1
	var arrays: Dictionary = {}


## P2: `level` selects the pyramid tier (1=L1 rim / P1 default; 2..5 = ladder). Byte-identical to P1 at level==1.
## `do_rebuild` = false lets the ladder create a tier ring WITHOUT the P1 ridge-1 initial stream (the ladder drives its
## own per-level assigned band right after) — avoids leaving near ridge-1 facets stranded at a coarse level.
func setup(active_fid: int, level: int = 1, do_rebuild: bool = true) -> void:
	_level = clampi(level, 1, FacetBlockLod.LEVELS - 1)
	_pitch = 1 << _level
	_active_fid = active_fid
	_material = _make_material()
	_prewarm_statics(active_fid)
	set_process(true)
	if do_rebuild:
		rebuild(active_fid)


func level() -> int:
	return _level


## S1↔L1 rim coupling (SEAMLESS-SCALES §4): set this ring's EFFECTIVE inner engagement rim (blocks). WorldManager pushes
## min(BLOCK_LOD_L1_RIM_BLOCKS, near_view_distance) from the SAME value S1 (FP_APPROACH_ANCHOR) writes to the near
## VoxelViewer each debounced tick, so the L1 hand-off tracks the receding near field with no uncovered annulus. Idempotent
## + clamped ≥0. Bookkeeping only (whole-facet mesh already covers inward) ⇒ NO re-mesh, zero added tiles. Untouched ⇒ 128.
func set_effective_rim(rim: int) -> void:
	_effective_rim = maxi(rim, 0)


## The current effective inner engagement rim (blocks) — 128 static, or the S1-ramped near view_distance once it drops
## below 128. The gate asserts this == min(128, near_view_distance) across the S1 ramp (no gap), and == 128 when uncoupled.
func effective_rim() -> int:
	return _effective_rim


## P2 shared-budget hook: the ladder governs the CROSS-LEVEL byte ceiling, so it lifts each managed ring's own byte
## cap (leaving only the per-ring LRU-facet cap as a residency bound) and does the finest-first coarsening itself.
## Untouched ⇒ the P1 defaults (16 MB / 9 facets) — byte-identical.
func set_caps(byte_cap: int, lru_facets: int) -> void:
	_byte_cap = byte_cap
	_lru_cap = lru_facets


## TH4 (FP_TEX_BAKE_WORKER's set_job_lane twin): hand the block-LOD ring the ONE TH0 job lane. Once set, the L0
## bake + greedy mesh runs on a WorkerThreadPool worker and MAIN pays only the commit ⇒ no crossing stall. Null lane
## (or never called) ⇒ the synchronous fallback (byte-identical to the P1 inline build; used by the headless gate).
func set_job_lane(lane: JobLane) -> void:
	_lane = lane
	_worker_on = lane != null


## §2V "pre-warm statics on MAIN before the worker touches them": the worker path calls TerrainConfig.facet_profile
## (lazy noise init) + FarPalette.color_for (lazy palette / BlockCatalog init). Trigger both once on the main thread
## so the worker only ever READS the finished statics (no init race — the exact discipline FacetTexBaker.prewarm uses).
func _prewarm_statics(active_fid: int) -> void:
	if _statics_warm:
		return
	FacetAtlas.warm_up()
	FarPalette.ensure_ready()
	var p := TerrainConfig.facet_profile(active_fid, 0, 0)   # forces TerrainConfig._ensure_noise on MAIN
	FarPalette.color_for(int(p.x), int(p.y), p.w, false)     # forces FarPalette/BlockCatalog/ClimateModel ready on MAIN
	_statics_warm = true


## The L1 band for `active_fid`: the active facet ∪ its 4 ridge (seam) neighbours. Bounded (§5/§7) so the streamed
## set is O(1) per crossing. Deterministic order (active first) so the active facet is always the protected member.
func band_fids(active_fid: int) -> Array:
	var out: Array = [active_fid]
	for slot in range(4):
		var nb := FacetAtlas.seam_neighbour(active_fid, slot)
		if nb >= 0 and not out.has(nb):
			out.append(nb)
	return out


## Re-place + re-stream the band for a (possibly new) active facet. Called on setup and on every crossing. Submits
## EVERY not-yet-resident band facet UP FRONT to the lane at PRIORITY_BLOCK_LOD (so the ≤5 units compute in parallel
## on the free worker slots and beat the far-skin g1 refinement — no starvation), touches the LRU of the whole band,
## then evicts down to the cap / ledger (never the band). A facet already resident (or in flight) is a pure LRU touch.
## With NO lane (headless gate / FP_JOB_LANE off) it builds inline (byte-identical to P1).
func rebuild(active_fid: int) -> void:
	_active_fid = active_fid
	rebuild_band(band_fids(active_fid))


## P2: stream an EXPLICIT set of facets at this ring's level (the ladder assigns per-level bands by the distance law).
## `fids` becomes the protected band (never LRU-evicted). Submits every not-yet-resident facet UP FRONT to the lane
## (parallel worker slots), LRU-touches the whole set, then enforces the per-ring budget. rebuild() routes through
## here with the ridge-1 band ⇒ P1 is byte-identical (same submit/enforce path, same protected set).
func rebuild_band(fids: Array) -> void:
	_band = fids
	var now := Time.get_ticks_msec()
	var submitted := 0
	for fid in fids:
		_lru[fid] = now
		if _mesh_by_fid.has(fid):
			continue
		if not _worker_on:
			_commit_facet_arrays(fid, _build_facet_arrays(fid))   # sync fallback: inline build (P1 path, unchanged)
		elif not _inflight.has(fid):
			_submit_bake(fid)                                     # async: dispatch the whole band up front
			submitted += 1
	if submitted > 0:
		_dispatch_rounds += 1
	_enforce_budget(fids)


## The protected band this ring last streamed (ridge-1 for P1; the ladder's per-level assignment for L2..L5). The
## cross-level coordinator reads it to know which facets NOT to coarsen away.
func current_band() -> Array:
	return _band


## P2 GLOBAL reuse: greedy-mesh `fid` from an EXTERNALLY-sampled level dict (the L5 store), returning the same
## {verts,colors,uvs,indices,bytes,...} arrays the ladder commits. Lets FacetBlockLodGlobal share ONE mesher + shade
## law without re-baking L0. Pure w.r.t. the scene tree.
func mesh_arrays_from_level(fid: int, lvl: Dictionary) -> Dictionary:
	return _build_facet_arrays(fid, lvl)

## The shared unshaded vertex-colour material (shell shade·tint + arrival dither). Lazily built so a mesher-only ring
## (never setup()) can hand it to the global tier's merged MeshInstances ⇒ ONE shade law near↔L1↔ladder↔L5↔skin.
func shared_material() -> ShaderMaterial:
	if _material == null:
		_material = _make_material()
	return _material


## Submit one facet's bake to the lane: its own BakeUnit staging buffer (single-writer on the worker), high priority
## so the active transition band converges ahead of far-skin refinement. The lane runs ≤_max_inflight units at once.
func _submit_bake(fid: int) -> void:
	var unit := BakeUnit.new()
	unit.fid = fid
	_inflight[fid] = unit
	_lane.submit(JobLane.PRIORITY_BLOCK_LOD,
		Callable(self, "_worker_bake").bind(unit), Callable(self, "_worker_commit").bind(unit), "blocklod-%d" % fid)


## WORKER THREAD: the heavy pure compute (L0 bake + greedy mesh) into THIS unit's own buffer. Touches NO
## RenderingServer / scene tree (only reads the prewarmed statics + writes unit.arrays — single-writer, race-free).
func _worker_bake(unit: BakeUnit) -> void:
	unit.arrays = _build_facet_arrays(unit.fid)


## MAIN THREAD (lane commit, paced by the drain budget): upload this unit's staged arrays (ArrayMesh + add_child +
## ledger) — the ONLY GPU/tree touch, the cheap part (≈2 ms). Drop the unit from in-flight (RefCounted frees the
## staging), then re-enforce the budget (a unit baked while the band moved on commits then LRU-evicts). Commits are
## bounded ≤6/frame by the lane, so a whole-band burst spreads without a main hitch.
func _worker_commit(unit: BakeUnit) -> void:
	var fid := unit.fid
	_inflight.erase(fid)
	if not _mesh_by_fid.has(fid):
		_commit_facet_arrays(fid, unit.arrays)
	unit.arrays = {}
	_enforce_budget(_band)


## Set the render placement (absolute planet coords → current render frame). Mirrors the far ring's own node
## transform so the L1 blocks and the far skin sit in ONE frame (they overlap by construction — L1 overdraws the sunk
## backstop). WorldManager passes _facet_ring.transform each frame.
func place(xform: Transform3D) -> void:
	transform = xform


## Forward the Sun direction into the shared material (same value the far-ring shell gets), so the day/night
## shade·tint matches the far skin and the near blocks exactly.
func set_sun_dir(sun_dir: Vector3) -> void:
	_sun_dir = sun_dir
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)


func _process(_delta: float) -> void:
	# Feed the arrival-dither clock (§4 temporal): each facet mesh carries its build time in UV.x; the fragment
	# screen-door-discards until (now − arrival) exceeds BLOCK_LOD_DITHER_S. One uniform write/frame.
	if _material != null:
		_material.set_shader_parameter("u_now", float(Time.get_ticks_msec()) / 1000.0)
	# TH4: the whole band is submitted up front by rebuild(); the lane (pumped by WorldManager) runs + commits the
	# units. Nothing to dispatch per-frame here — main pays only the u_now uniform write.


# ---- ledger / LRU (NEVER-OOM §5) -------------------------------------------------------------------------------

func ledger_bytes() -> int:
	return _ledger_bytes

func facet_bytes(fid: int) -> int:
	return int(_bytes_by_fid.get(fid, 0))

func resident_fids() -> Array:
	return _mesh_by_fid.keys()

## Draw count == resident non-empty facet meshes (one draw each). The gate asserts this is ≈ band facets ≪ columns.
func draw_count() -> int:
	var n := 0
	for fid in _mesh_by_fid:
		var mi: MeshInstance3D = _mesh_by_fid[fid]
		if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			n += 1
	return n

func wholesale_clears() -> int:
	return _wholesale_clears

# --- async observables (headless gate: G-BLD-MAINCOST / G-BLD-CONVERGE) ------------------------------------------
func inflight_count() -> int:
	return _inflight.size()

func dispatch_rounds() -> int:
	return _dispatch_rounds

func is_baking() -> bool:
	return not _inflight.is_empty()

## True once the worker path has fully streamed the current band (nothing computing, nothing awaiting commit).
func async_idle() -> bool:
	return _inflight.is_empty()


## Evict resident facets outside `band`, LRU-first, until BOTH the LRU-facet cap AND the byte ledger are satisfied.
## The band is NEVER evicted (the active set is protected — G-BLD-BYTES). If the ledger is still breached after all
## non-band facets are gone, wholesale-clear everything non-band (already done) — the band alone is bounded (≤5 small
## facets) and is the irreducible floor.
func _enforce_budget(band: Array) -> void:
	# 1) LRU cap on resident facets.
	while _mesh_by_fid.size() > _lru_cap:
		var victim := _lru_victim(band)
		if victim < 0:
			break
		_evict(victim)
	# 2) Byte ledger.
	if _ledger_bytes <= _byte_cap:
		return
	while _ledger_bytes > _byte_cap:
		var victim := _lru_victim(band)
		if victim < 0:
			break                                  # only the band remains — the bounded floor
		_evict(victim)
	# 3) Wholesale-clear guard: if a single band build overran the ceiling, drop every non-band facet in one sweep
	#    (already achieved above); record the breach so the gate can see the safety fired.
	if _ledger_bytes > _byte_cap:
		_wholesale_clears += 1


## P2 cross-level coarsening hook (FacetBlockLodLadder): evict this ring's single LRU-oldest non-`band` facet and
## return the bytes freed (0 if nothing outside the band is resident). The ladder calls this finest-level-first on a
## shared-ceiling breach ("drop the finest streamed level first") — a facet dropped here still has the coarser tiers +
## the sunk far ring underneath, so no hole. Distinct from _enforce_budget (which bounds ONE ring against its own cap).
func evict_one_lru(band: Array) -> int:
	var victim := _lru_victim(band)
	if victim < 0:
		return 0
	var freed := int(_bytes_by_fid.get(victim, 0))
	_evict(victim)
	return freed


## P2 hard-breach coarsening: wholesale-clear this ENTIRE ring (band included) and return the bytes freed. The
## coordinator calls this on the FINEST streamed level when even the protected bands overrun the shared ceiling
## ("drop the finest streamed level first", design §5) — the coarser tiers + the sunk far ring still cover the band ⇒
## no hole. Idempotent (0 when already empty).
func clear_all() -> int:
	var freed := _ledger_bytes
	for fid in _mesh_by_fid.keys():
		_evict(fid)
	return freed


func _lru_victim(band: Array) -> int:
	var best := -1
	var best_ms := 0x7fffffffffffffff
	for fid in _mesh_by_fid:
		if band.has(fid):
			continue
		var ms := int(_lru.get(fid, 0))
		if ms < best_ms:
			best_ms = ms
			best = fid
	return best


func _evict(fid: int) -> void:
	var mi: MeshInstance3D = _mesh_by_fid.get(fid, null)
	if mi != null:
		remove_child(mi)
		mi.queue_free()
	_mesh_by_fid.erase(fid)
	_ledger_bytes -= int(_bytes_by_fid.get(fid, 0))
	_bytes_by_fid.erase(fid)
	_lru.erase(fid)


# ---- meshing (§4) ----------------------------------------------------------------------------------------------

## MAIN THREAD — the CHEAP commit: turn worker-built (or inline-built) arrays into an ArrayMesh + MeshInstance and
## charge the ledger. This is the ONLY RenderingServer / scene-tree touch; the ~1 s bake is NOT here (it produced
## `arr`). G-BLD-MAINCOST measures exactly this cost vs the whole synchronous build.
func _commit_facet_arrays(fid: int, arr: Dictionary) -> void:
	var verts: PackedVector3Array = arr["verts"]
	if verts.is_empty():
		return
	var am := ArrayMesh.new()
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_COLOR] = arr["colors"]
	a[Mesh.ARRAY_TEX_UV] = arr["uvs"]
	a[Mesh.ARRAY_INDEX] = arr["indices"]
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var mi := MeshInstance3D.new()
	mi.name = "BlockLodL1_%d" % fid
	mi.mesh = am
	mi.material_override = _material
	# The mesh is absolute planet coords; the far ring's fog/shading governs beyond — no cast shadow (unshaded tier).
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_mesh_by_fid[fid] = mi
	var bytes: int = int(arr["bytes"])
	_bytes_by_fid[fid] = bytes
	_ledger_bytes += bytes


## Greedy-mesh facet `fid`'s L1 tier into absolute-coord arrays. Pure w.r.t. the RenderingServer (a gate can call it
## directly). Returns {verts, colors, uvs, indices, bytes, n_top, n_side, n_skirt, edges}. `edges` is the set of
## emitted vertical-edge keys (side + skirt) — the seam bookkeeping G-BLD-SEAM audits against the required set.
func _build_facet_arrays(fid: int, lvl_override: Dictionary = {}) -> Dictionary:
	# P2: the L5 GLOBAL tier passes its already-sampled L5 level dict so the merged-mesh path reuses THIS exact greedy
	# mesher / weld law / palette / shade material without re-baking a full L0 pyramid per facet. Empty ⇒ the P1/ladder
	# path builds the pyramid analytically (unchanged).
	var lvl: Dictionary
	if lvl_override.is_empty():
		var lod := FacetBlockLod.new()
		lod.build(fid)
		lvl = lod.get_level(_level)
	else:
		lvl = lvl_override
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var top: PackedInt32Array = lvl["top"]
	var idb: PackedByteArray = lvl["id"]
	var wat: PackedByteArray = lvl["water"]
	var dmin := FacetAtlas.dom_min(fid)
	var half := _pitch >> 1

	# Emitted mask + per-column colour (RGBA8-packed for greedy equality) + the Color itself.
	var emit := PackedByteArray(); emit.resize(w * h)
	var col32 := PackedInt32Array(); col32.resize(w * h)
	var cols: Array = []; cols.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			var lx := dmin.x + cx * _pitch + half      # representative L0 cell (coarse-cell centre)
			var lz := dmin.y + cz * _pitch + half
			if not FacetAtlas.in_polygon(fid, lx, lz, 0.0):
				emit[ci] = 0
				continue
			emit[ci] = 1
			# Temperature for the palette (snow-cap / frozen-or-lava sea) — sampled once per emitted coarse column,
			# the SAME profile the far ring reads. id/water come from the decimated pyramid (majority / OR).
			var t: float = TerrainConfig.facet_profile(fid, lx, lz).w
			var c := FarPalette.color_for(top[ci], int(idb[ci]), t, wat[ci] != 0)
			cols[ci] = c
			col32[ci] = _rgba8(c)

	var verts := PackedVector3Array()
	var vcol := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var arrival := float(Time.get_ticks_msec()) / 1000.0
	var edges := {}                                   # emitted vertical-edge keys (side + skirt)
	var n_top := 0
	var n_side := 0
	var n_skirt := 0

	# --- TOP faces: greedy-merge rectangular runs of equal (top-height, colour) over the emitted grid. -----------
	var used := PackedByteArray(); used.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			if emit[ci] == 0 or used[ci] != 0:
				continue
			var th := top[ci]
			var c32 := col32[ci]
			# extend width
			var rw := 1
			while cx + rw < w:
				var ni := cz * w + cx + rw
				if emit[ni] == 0 or used[ni] != 0 or top[ni] != th or col32[ni] != c32:
					break
				rw += 1
			# extend height (whole rows only)
			var rh := 1
			var grow := true
			while grow and cz + rh < h:
				for k in range(rw):
					var ni := (cz + rh) * w + cx + k
					if emit[ni] == 0 or used[ni] != 0 or top[ni] != th or col32[ni] != c32:
						grow = false
						break
				if grow:
					rh += 1
			for zz in range(rh):
				for xx in range(rw):
					used[(cz + zz) * w + cx + xx] = 1
			# quad corners on the shared integer lattice (bit-identical welds — G-SKIN-EDGE)
			var x0 := dmin.x + cx * _pitch
			var x1 := dmin.x + (cx + rw) * _pitch
			var z0 := dmin.y + cz * _pitch
			var z1 := dmin.y + (cz + rh) * _pitch
			var c: Color = cols[ci]
			_add_quad(verts, vcol, uvs, idx,
				_w(fid, x0, th, z0), _w(fid, x1, th, z0), _w(fid, x1, th, z1), _w(fid, x0, th, z1),
				c, arrival)
			n_top += 1

	# --- SIDE faces (interior height steps) + SKIRT (facet-polygon perimeter, dropped one coarse pitch). ---------
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			if emit[ci] == 0:
				continue
			var th := top[ci]
			var c: Color = cols[ci]
			for d: Vector2i in dirs:
				var nx := cx + d.x
				var nz := cz + d.y
				var nb_emit := false
				var nb_top := 0
				if nx >= 0 and nx < w and nz >= 0 and nz < h and emit[nz * w + nx] != 0:
					nb_emit = true
					nb_top = top[nz * w + nx]
				var y_lo := th
				var is_skirt := false
				if nb_emit:
					if nb_top >= th:
						continue                       # neighbour at-or-above covers this edge
					y_lo = nb_top                       # interior wall down to the shorter neighbour
				else:
					y_lo = th - _pitch                   # boundary skirt: drop one coarse pitch to the backstop
					is_skirt = true
				# shared-edge endpoints (integer lattice) + the canonical edge key
				var xa: int; var za: int; var xb: int; var zb: int; var key: String
				if d == Vector2i(1, 0):
					xa = dmin.x + (cx + 1) * _pitch; za = dmin.y + cz * _pitch
					xb = xa; zb = dmin.y + (cz + 1) * _pitch
					key = "x:%d:%d" % [cx + 1, cz]
				elif d == Vector2i(-1, 0):
					xa = dmin.x + cx * _pitch; za = dmin.y + cz * _pitch
					xb = xa; zb = dmin.y + (cz + 1) * _pitch
					key = "x:%d:%d" % [cx, cz]
				elif d == Vector2i(0, 1):
					xa = dmin.x + cx * _pitch; za = dmin.y + (cz + 1) * _pitch
					xb = dmin.x + (cx + 1) * _pitch; zb = za
					key = "z:%d:%d" % [cx, cz + 1]
				else:
					xa = dmin.x + cx * _pitch; za = dmin.y + cz * _pitch
					xb = dmin.x + (cx + 1) * _pitch; zb = za
					key = "z:%d:%d" % [cx, cz]
				_add_quad(verts, vcol, uvs, idx,
					_w(fid, xa, y_lo, za), _w(fid, xb, y_lo, zb), _w(fid, xb, th, zb), _w(fid, xa, th, za),
					c, arrival)
				edges[key] = true
				if is_skirt:
					n_skirt += 1
				else:
					n_side += 1

	var nv := verts.size()
	var nidx := idx.size()
	var bytes := nv * BYTES_PER_VERT + nidx * BYTES_PER_INDEX
	return {
		"verts": verts, "colors": vcol, "uvs": uvs, "indices": idx, "bytes": bytes,
		"n_top": n_top, "n_side": n_side, "n_skirt": n_skirt, "edges": edges,
		"w": w, "h": h,
	}


## Independent seam audit for `fid` (G-BLD-SEAM teeth): re-derive the REQUIRED set of vertical-edge keys (every
## emitted column edge that is either a height step to a lower emitted neighbour OR a facet-polygon boundary) and
## confirm the mesher emitted a quad (side or skirt) for EVERY one — i.e. no silhouette hole. Returns the number of
## missing edges (0 = watertight boundary). Recomputed from the pyramid, NOT read back from the mesh, so a mesher
## that skipped a boundary/step edge would leave a required key unemitted ⇒ defects > 0 (the check has teeth).
func seam_defects(fid: int) -> int:
	var arr := _build_facet_arrays(fid)
	var edges: Dictionary = arr["edges"]
	var w: int = arr["w"]
	var h: int = arr["h"]
	# Re-derive emit + top exactly as the mesher does.
	var lod := FacetBlockLod.new()
	lod.build(fid)
	var lvl := lod.get_level(_level)
	var top: PackedInt32Array = lvl["top"]
	var dmin := FacetAtlas.dom_min(fid)
	var half := _pitch >> 1
	var emit := PackedByteArray(); emit.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var lx := dmin.x + cx * _pitch + half
			var lz := dmin.y + cz * _pitch + half
			emit[cz * w + cx] = 1 if FacetAtlas.in_polygon(fid, lx, lz, 0.0) else 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var missing := 0
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			if emit[ci] == 0:
				continue
			for d: Vector2i in dirs:
				var nx := cx + d.x
				var nz := cz + d.y
				var nb_emit := false
				var nb_top := 0
				if nx >= 0 and nx < w and nz >= 0 and nz < h and emit[nz * w + nx] != 0:
					nb_emit = true
					nb_top = top[nz * w + nx]
				var required := (not nb_emit) or (nb_top < top[ci])
				if not required:
					continue
				var key: String
				if d == Vector2i(1, 0):
					key = "x:%d:%d" % [cx + 1, cz]
				elif d == Vector2i(-1, 0):
					key = "x:%d:%d" % [cx, cz]
				elif d == Vector2i(0, 1):
					key = "z:%d:%d" % [cx, cz + 1]
				else:
					key = "z:%d:%d" % [cx, cz]
				if not edges.has(key):
					missing += 1
	return missing


# ---- helpers ---------------------------------------------------------------------------------------------------

## Absolute-coord world vertex of the integer lattice corner (fid, x, y, z). The shared (fid,x,z) lattice ⇒ any two
## columns meeting at an edge produce BIT-IDENTICAL corners (same f64 inputs → same Vector3) ⇒ no crack (the weld law).
func _w(fid: int, x: int, y: int, z: int) -> Vector3:
	var a := FacetAtlas.lattice_to_world64(fid, float(x), float(y), float(z))
	var v := Vector3(a[0], a[1], a[2])
	# COSMOS FAR-LOD QUALITY (A): push the vertex FARLOD_BLOCK_SINK blocks radially inward (planet centre = absolute
	# origin, so the radial is v.normalized(), the SAME law FacetSkinTier._compose_position uses). Pure in v ⇒ two
	# columns/facets sharing this corner still weld bit-identically. No-op (byte-identical) when _farlod_sink == 0.
	if _farlod_sink > 0.0:
		v -= v.normalized() * _farlod_sink
	return v


func _add_quad(verts: PackedVector3Array, vcol: PackedColorArray, uvs: PackedVector2Array, idx: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, c: Color, arrival: float) -> void:
	var base := verts.size()
	verts.push_back(p0); verts.push_back(p1); verts.push_back(p2); verts.push_back(p3)
	for _i in range(4):
		vcol.push_back(c)
		uvs.push_back(Vector2(arrival, 0.0))          # UV.x = arrival time (screen-door dither clock)
	idx.push_back(base); idx.push_back(base + 1); idx.push_back(base + 2)
	idx.push_back(base); idx.push_back(base + 2); idx.push_back(base + 3)


static func _rgba8(c: Color) -> int:
	return (int(round(c.r * 255.0)) << 24) | (int(round(c.g * 255.0)) << 16) \
		| (int(round(c.b * 255.0)) << 8) | int(round(c.a * 255.0))


## The unshaded, vertex-coloured material composing with the shell shade·tint law (radial normal = normalize(wp −
## MODEL·0), identical to _SHELL_ABS_SHADER). Under FP_SHADE_UNIFIED the ONE shared VoxiLight law is string-included
## so L1 shades identically to the near blocks AND the far skin (the user's #1 seamless requirement). Adds the §4
## arrival screen-door DITHER (a discard pattern in this one opaque material — no transparency, no sorting).
func _make_material() -> ShaderMaterial:
	var head := "shader_type spatial;\nrender_mode unshaded, cull_disabled;\n"
	var light: String
	var call: String
	if CubeSphere.FP_SHADE_UNIFIED:
		# The shared law declares sun_dir/night_floor/term_mu/moonshine + voxi_shade(n, sd).
		light = VoxiLight.SHADE_GLSL
		call = "voxi_shade(n, sun_dir)"
	else:
		# Inline shell law (byte-mirrors _SHELL_ABS_SHADER's day/night shade·tint — the shipped far-skin look).
		light = "uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);\n" \
			+ "uniform float night_floor = 0.06;\n" \
			+ "uniform float term_mu = 0.12;\n" \
			+ "float _air_mass(float mu) { float m = clamp(mu, 0.0, 1.0); float hh = degrees(asin(m)); return 1.0 / (m + 0.50572 * pow(hh + 6.07995, -1.6364)); }\n" \
			+ "vec3 _scatter_tint(float mu) { float m = _air_mass(mu); return vec3(exp(-0.042 * m), exp(-0.098 * m), exp(-0.245 * m)); }\n" \
			+ "float _scatter_band(float mu) { float up = smoothstep(-0.10, 0.0, mu); float dn = 1.0 - smoothstep(0.15, 0.25, mu); return up * dn; }\n" \
			+ "float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }\n" \
			+ "vec3 _sh(vec3 n, vec3 sd) { float mu = dot(n, normalize(sd)); float shade = night_floor + (1.0 - night_floor) * _day(mu); vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu)); return vec3(shade) * tint; }\n"
		call = "_sh(n, sun_dir)"
	# Bayer 4x4 threshold table (÷16) for the arrival screen-door.
	var body := "uniform float u_now = 0.0;\nuniform float u_dither = 0.3;\n" \
		+ "varying vec3 v_col;\nvarying float v_arr;\n" \
		+ "void vertex() {\n" \
		+ "\tvec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n" \
		+ "\tvec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;\n" \
		+ "\tvec3 n = normalize(wp - centre);\n" \
		+ "\tv_col = COLOR.rgb * " + call + ";\n" \
		+ "\tv_arr = UV.x;\n" \
		+ "}\n" \
		+ "const float _bayer[16] = float[](0.0,8.0,2.0,10.0, 12.0,4.0,14.0,6.0, 3.0,11.0,1.0,9.0, 15.0,7.0,13.0,5.0);\n" \
		+ "void fragment() {\n" \
		+ "\tfloat fade = clamp((u_now - v_arr) / max(u_dither, 0.0001), 0.0, 1.0);\n" \
		+ "\tif (fade < 1.0) {\n" \
		+ "\t\tint bx = int(mod(FRAGCOORD.x, 4.0));\n" \
		+ "\t\tint by = int(mod(FRAGCOORD.y, 4.0));\n" \
		+ "\t\tfloat thr = (_bayer[by * 4 + bx] + 0.5) / 16.0;\n" \
		+ "\t\tif (fade < thr) { discard; }\n" \
		+ "\t}\n" \
		+ "\tALBEDO = v_col;\n" \
		+ "}\n"
	var sh := Shader.new()
	sh.code = head + light + body
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("sun_dir", _sun_dir)
	m.set_shader_parameter("u_dither", CubeSphere.BLOCK_LOD_DITHER_S)
	if CubeSphere.FP_SHADE_UNIFIED:
		m.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		m.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		m.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return m
