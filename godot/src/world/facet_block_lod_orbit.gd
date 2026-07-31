class_name FacetBlockLodOrbit
extends Node3D
## COSMOS PLANET-LOD-CONFIG P0 (docs/COSMOS-PLANET-LOD-CONFIG-DESIGN.md §2 — "crisp BLOCKY megablocks from orbit") —
## THE orbit render phase (FP_BLOCK_LOD_ORBIT). Above the swap altitude it meshes the WHOLE visible disc as
## DISTANCE-LADDERED megablocks (L4 at the nadir → L5 toward the limb, a PER-FACET screen-distance selection — NOT one
## uniform level), riding the far ring's scaled-body clamp, so the planet reads as crisp voxel-edged geometry from
## orbit instead of the smooth §2V "satellite" skin the user rejected. GATED CONSTRUCTION sibling of the far ring /
## ladder / global ⇒ byte-identical off (WorldManager never news it up; nothing calls it).
##
## WHY A NEW TIER (not the L5 global): the L5 global tier meshes the NEAREST facets at ONE uniform pitch-32 level; from
## orbit the user wants the NADIR crisp (L4/16-blk) coarsening to L5 toward the limb — a per-facet distance ladder over
## the WHOLE front disc, with §2V RETIRED (not underlaid). This node is that: it enumerates the visible disc, assigns
## each facet a level by the on-screen block-size law (CubeSphere.orbit_level_for_dist), and merges the accepted facets
## into ≤ BLOCK_LOD_ORBIT_DRAWS ArrayMeshes under a HARD byte cap.
##
## REUSES the existing machinery (no re-implementation): the greedy mesher + shared shade material is FacetBlockLodRing
## (one pure mesher per level, mesh_arrays_from_level, NOT in the tree — the same pattern FacetBlockLodGlobal uses); the
## per-facet columns are baked with the SAME 2×2 MIN stencil the global tier bakes L5 with (containment: coarse top ≤
## the finer terrain, no protrusion), generalized to the assigned level. ONE shade law ⇒ lit identically to near ↔ L1
## ↔ ladder ↔ L5 ↔ far skin (radial-normal shell shade·tint).
##
## SCALED-BODY CLAMP (§2.5): the node is placed each frame from the FAR RING's own transform (WorldManager passes
## _facet_ring.transform), which ALREADY carries the SN3 scale_about_camera(cam, s=min(1,D_ENGAGE/d)) clamp — so the
## megablock mesh scales screen-invariantly with the disc in deep space exactly as the ring does (no detachment / clip).
##
## NEVER-OOM (§2.3): a hard ledger BLOCK_LOD_ORBIT_BYTES_MAX (12 MB). The merge loop is nearest-first; when adding a
## facet would breach, it first COARSENS that facet L4→L5 (fewer quads), and if even L5 breaches it STOPS meshing (the
## sunk far ring backstops the farthest limb — no hole). Because §2V is retired above the swap, the COMBINED budget
## (orbit mesh + far-ring mesh) stays far under the 40 MB web ceiling.
##
## WORKER-PACED (§5): re-assign + re-mesh fire only on a CROSSING or when the sub-camera direction / altitude drifts
## past BLOCK_LOD_ORBIT_REASSIGN_DEG / _DH (no per-frame re-tessellation churn). With a JobLane the per-facet column
## bakes run on the worker (commit-only on main); without one (headless gate) they bake inline (byte-identical result).

# NO-PROTRUSION (§2.4/§2.5): the megablock top is the EXACT MIN over ALL fine L0 columns in the coarse cell — computed
# via the shipped FacetBlockLod decimate chain (facet_block_lod.gd: top(coarse)=MIN(2×2 children), applied L0→level), the
# SAME MIN pyramid the ladder uses (gate-proven MIN-correct at G-BLD-LADDER). Because it is the true minimum over the
# whole cell (not a sparse stencil), the coarse top sits at-or-below the true terrain EVERYWHERE ⇒ it can NEVER protrude
# above the fine surface (containment, structurally improves #72). Cost: a full-L0 pyramid per facet — bounded by the
# byte cap (only ~200 nadir facets mesh under 12 MB) and CACHED per (fid,level) so a drift re-assign re-bakes only the
# newly-covered facets (the far ring backstops the fill). This is the design's "analytic + already decimated" pyramid.
const CACHE_MAX := 640                  # per-(fid,level) column-dict cache cap (cheap DATA, ~1–4 KB each); wholesale-clear on breach
const BYTES_PER_COL := 6               # int32 top(4) + id(1) + water(1) — the transient per-facet column arithmetic

var _active_fid := -1
var _material: ShaderMaterial = null
var _meshers: Dictionary = {}          # level(int) -> FacetBlockLodRing (pure mesher: _level/_pitch set; NOT in tree)
var _sun_dir := Vector3(1.0, 0.0, 0.0)

# Camera state (absolute planet frame; body centre at origin). Pushed by WorldManager each frame; re-assign throttled.
var _cam_dir := Vector3(0.0, 1.0, 0.0) # sub-camera ABSOLUTE unit direction (planet centre → camera)
var _cam_d := 0.0                      # camera distance from the body centre (blocks) = R + altitude
var _cam_h := 0.0                      # radial altitude (blocks) = _cam_d − R
var _engaged := false                  # swap-band latch (hysteresis) — true ⇒ orbit mesh live + §2V retired
var _have_assign := false              # a first assignment has been meshed (guards the drift-throttle baseline)
var _assign_dir := Vector3.ZERO        # sub-camera dir at the last re-assign (drift baseline)
var _assign_h := 0.0                   # altitude at the last re-assign (drift baseline)

# Visible-disc meshing state.
var _mesh_groups: Dictionary = {}      # face(int) -> MeshInstance3D (merged mesh; ≤ BLOCK_LOD_ORBIT_DRAWS)
var _group_bytes: Dictionary = {}      # face -> int
var _mesh_bytes := 0                   # Σ _group_bytes — the NEVER-OOM ledger (≤ BLOCK_LOD_ORBIT_BYTES_MAX)
var _level_by_fid: Dictionary = {}     # fid -> the level actually meshed (after any cap coarsening) — telemetry/gate
var _reassigns := 0                    # diagnostics: re-assignment sweeps
var _coarsen_events := 0               # diagnostics: facets bumped L4→L5 at the cap
var _dropped_limb := 0                 # diagnostics: farthest facets left to the far-ring backstop at the cap

var _lane: JobLane = null
var _statics_warm := false


# ---- the on-screen block-size LAW (§2.2) — thin instance wrappers over the PURE CubeSphere statics -----------------

## The megablock level a facet at camera distance `dist` (blocks) should render at (nadir L4 → limb L5). Monotone.
static func level_for_orbit_dist(dist: float) -> int:
	return CubeSphere.orbit_level_for_dist(dist, CubeSphere.BLOCK_LOD_ORBIT_PX, CubeSphere.BLOCK_LOD_ORBIT_K_PX,
		CubeSphere.BLOCK_LOD_ORBIT_MIN_LEVEL, CubeSphere.BLOCK_LOD_GLOBAL_LEVEL)


# ---- lifecycle -----------------------------------------------------------------------------------------------------

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_prewarm_statics(active_fid)
	# One pure mesher per orbit level (L4, L5). Each carries its own _level/_pitch so mesh_arrays_from_level welds on the
	# right lattice pitch; all share ONE material (identical shade law across the disc). Not added to the tree.
	for lvl in range(CubeSphere.BLOCK_LOD_ORBIT_MIN_LEVEL, CubeSphere.BLOCK_LOD_GLOBAL_LEVEL + 1):
		var m := FacetBlockLodRing.new()
		m._level = lvl
		m._pitch = 1 << lvl
		m._sun_dir = _sun_dir
		if _material == null:
			_material = m.shared_material()
		_meshers[lvl] = m
	_material.set_shader_parameter("sun_dir", _sun_dir)
	set_process(true)


func set_job_lane(lane: JobLane) -> void:
	_lane = lane


func _prewarm_statics(active_fid: int) -> void:
	if _statics_warm:
		return
	FacetAtlas.warm_up()
	FarPalette.ensure_ready()
	var p := TerrainConfig.facet_profile(active_fid, 0, 0)
	FarPalette.color_for(int(p.x), int(p.y), p.w, false)
	_statics_warm = true


func place(xform: Transform3D) -> void:
	transform = xform


func set_sun_dir(sun_dir: Vector3) -> void:
	_sun_dir = sun_dir
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)


func _process(_delta: float) -> void:
	if _material != null:
		_material.set_shader_parameter("u_now", float(Time.get_ticks_msec()) / 1000.0)


# ---- camera drive + swap engage (§2.5 / §5) -----------------------------------------------------------------------

## WorldManager pushes the sub-camera ABSOLUTE direction (planet centre → camera, unit) + distance-from-centre each
## frame. Updates the hysteresis engage latch and re-assigns the disc ONLY on a crossing or a drift past the thresholds
## (no per-frame churn). Returns true iff the orbit tier is currently ENGAGED (WorldManager retires §2V while it is).
func set_camera(cam_dir: Vector3, cam_d: float) -> bool:
	if cam_dir.length() > 1.0e-6:
		_cam_dir = cam_dir.normalized()
	_cam_d = cam_d
	_cam_h = cam_d - FacetAtlas.R_BLOCKS
	_engaged = CubeSphere.block_lod_orbit_engaged(_cam_h, _engaged)
	if not _engaged:
		if not _mesh_groups.is_empty():
			_clear_mesh()                          # dropped below the swap — free the orbit mesh, the skin path resumes
			_have_assign = false
		return false
	if _should_reassign():
		_reassign_and_mesh()
	return true


func _should_reassign() -> bool:
	if not _have_assign:
		return true
	if absf(_cam_h - _assign_h) > CubeSphere.BLOCK_LOD_ORBIT_REASSIGN_DH:
		return true
	var d := _assign_dir.dot(_cam_dir)             # cos of the drift angle (both unit)
	return d < cos(deg_to_rad(CubeSphere.BLOCK_LOD_ORBIT_REASSIGN_DEG))


## Crossing hook (WorldManager): the active facet changed. Force a re-assign next camera tick (the disc re-centres).
func rebuild(active_fid: int) -> void:
	_active_fid = active_fid
	_have_assign = false


func engaged() -> bool:
	return _engaged


# ---- visible-disc assignment + merged mesh (§2.2/§2.3) ------------------------------------------------------------

## The camera position in the ABSOLUTE mesh frame (body centre at origin, facet centres via lattice_to_world64): the
## sub-camera direction scaled to the distance-from-centre. Distances to facet centres are block-metric (1 unit=1 blk).
func _cam_abs() -> Vector3:
	return _cam_dir * _cam_d


func _facet_centre(fid: int) -> Vector3:
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var a := FacetAtlas.lattice_to_world64(fid, float(dmin.x + dmax.x) * 0.5, 0.0, float(dmin.y + dmax.y) * 0.5)
	return Vector3(a[0], a[1], a[2])


## Enumerate the VISIBLE DISC and assign each facet its megablock level. Front-hemisphere test (dot(facet_dir, cam_dir)
## > FRONT_COS), sorted nearest-first, capped at BLOCK_LOD_ORBIT_MAX_FACETS. Returns Array[[fid, dist, level]] sorted by
## dist. PURE w.r.t. the scene tree (the gate calls it directly to assert the per-facet level law + the distribution).
func assign_disc(cam_dir: Vector3, cam_d: float) -> Array:
	var u := cam_dir.normalized() if cam_dir.length() > 1.0e-6 else Vector3(0.0, 1.0, 0.0)
	var cam := u * cam_d
	var out: Array = []
	for fid in range(FacetAtlas.facet_count()):
		var c := _facet_centre(fid)
		var cn := c.length()
		if cn < 1.0e-6:
			continue
		if (c / cn).dot(u) <= CubeSphere.BLOCK_LOD_ORBIT_FRONT_COS:
			continue                               # back hemisphere — never visible from this camera
		var dist := (cam - c).length()
		out.append([fid, dist, level_for_orbit_dist(dist)])
	out.sort_custom(func(a, b): return a[1] < b[1])
	if out.size() > CubeSphere.BLOCK_LOD_ORBIT_MAX_FACETS:
		out.resize(CubeSphere.BLOCK_LOD_ORBIT_MAX_FACETS)
	return out


## One async build unit: the disc assignment + the staged per-face arrays (single-writer on the worker). RefCounted ⇒
## freed after the commit. Mirrors FacetBlockLodRing.BakeUnit / FacetTexBaker's worker/commit split.
class BuildUnit:
	extends RefCounted
	var disc: Array = []
	var groups: Dictionary = {}                    # face -> {v,c,u,i}
	var level_by_fid: Dictionary = {}
	var mesh_bytes := 0
	var coarsen := 0
	var dropped := 0

var _inflight := false                             # a build is on the worker (guard vs re-dispatch)


func _reassign_and_mesh() -> void:
	_reassigns += 1
	_assign_dir = _cam_dir
	_assign_h = _cam_h
	_have_assign = true
	var unit := BuildUnit.new()
	unit.disc = assign_disc(_cam_dir, _cam_d)
	# WORKER-PACED (§5): the whole-disc bake + greedy mesh (~1728 facets, PURE) runs on the TH0 lane; MAIN pays only the
	# ≤ DRAWS ArrayMesh upload. Without a lane (headless gate) it builds inline (byte-identical result). The far ring
	# backstops the disc until the commit lands, so there is never a hole during the (seconds-scale) worker fill.
	if _lane != null:
		if _inflight:
			return                                  # a build is already computing — the drift throttle will re-fire after it
		_inflight = true
		_lane.submit(JobLane.PRIORITY_BLOCK_LOD,
			Callable(self, "_worker_build").bind(unit), Callable(self, "_commit_build").bind(unit), "blocklod-orbit")
	else:
		_worker_build(unit)
		_commit_build(unit)


## WORKER THREAD: bake + greedy-mesh the assigned disc nearest-first into `unit.groups` under the hard byte cap. On a
## would-be breach: COARSEN the facet L4→L5 (fewer quads); if even L5 breaches, STOP (the sunk far ring backstops the
## rest — no hole). Touches NO RenderingServer / scene tree (only reads prewarmed statics + writes the unit) ⇒ race-free.
func _worker_build(unit: BuildUnit) -> void:
	var cap := CubeSphere.BLOCK_LOD_ORBIT_BYTES_MAX
	var kk := FacetAtlas.K * FacetAtlas.K
	var stopped := false
	for rec in unit.disc:
		if stopped:
			unit.dropped += 1
			continue
		var fid: int = rec[0]
		var lvl: int = rec[2]
		var arr := _mesh_facet(fid, lvl)
		var bytes: int = int(arr["bytes"])
		if unit.mesh_bytes + bytes > cap and lvl < CubeSphere.BLOCK_LOD_GLOBAL_LEVEL:
			lvl = CubeSphere.BLOCK_LOD_GLOBAL_LEVEL
			arr = _mesh_facet(fid, lvl)
			bytes = int(arr["bytes"])
			unit.coarsen += 1
		if unit.mesh_bytes + bytes > cap:
			stopped = true
			unit.dropped += 1
			continue
		var face: int = (fid - FacetAtlas.fid_base_of(fid)) / kk
		if not unit.groups.has(face):
			unit.groups[face] = {"v": PackedVector3Array(), "c": PackedColorArray(), "u": PackedVector2Array(), "i": PackedInt32Array()}
		_append(unit.groups[face], arr)
		unit.mesh_bytes += bytes
		unit.level_by_fid[fid] = lvl


## MAIN THREAD (lane commit): upload the staged per-face arrays into ≤ DRAWS ArrayMeshes — the ONLY GPU/tree touch (the
## cheap part). Fully replaces the previous meshes (double-free-safe via _clear_mesh). Records the ledger + diagnostics.
func _commit_build(unit: BuildUnit) -> void:
	_inflight = false
	_clear_mesh()
	_level_by_fid = unit.level_by_fid
	_coarsen_events = unit.coarsen
	_dropped_limb = unit.dropped
	var faces := unit.groups.keys()
	faces.sort()
	var committed := 0
	for face in faces:
		if committed >= CubeSphere.BLOCK_LOD_ORBIT_DRAWS:
			break
		var g: Dictionary = unit.groups[face]
		var verts: PackedVector3Array = g["v"]
		if verts.is_empty():
			continue
		var am := ArrayMesh.new()
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_COLOR] = g["c"]
		a[Mesh.ARRAY_TEX_UV] = g["u"]
		a[Mesh.ARRAY_INDEX] = g["i"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		var mi := MeshInstance3D.new()
		mi.name = "BlockLodOrbit_face%d" % face
		mi.mesh = am
		mi.material_override = _material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_mesh_groups[face] = mi
		var nidx: int = (g["i"] as PackedInt32Array).size()
		_group_bytes[face] = verts.size() * FacetBlockLodRing.BYTES_PER_VERT + nidx * FacetBlockLodRing.BYTES_PER_INDEX
		_mesh_bytes += _group_bytes[face]
		committed += 1


## Greedy-mesh one facet at `level` from a freshly-stencil-baked level dict, via the level's pure mesher. Returns the
## FacetBlockLodRing.mesh_arrays_from_level arrays ({verts,colors,uvs,indices,bytes,...}). PURE w.r.t. the scene tree.
func _mesh_facet(fid: int, level: int) -> Dictionary:
	var mesher: FacetBlockLodRing = _meshers.get(level, null)
	if mesher == null:
		return {"verts": PackedVector3Array(), "colors": PackedColorArray(), "uvs": PackedVector2Array(),
			"indices": PackedInt32Array(), "bytes": 0}
	return mesher.mesh_arrays_from_level(fid, _bake_cols(fid, level))


func _append(g: Dictionary, arr: Dictionary) -> void:
	# CoW: pull the packed arrays out of the dict, mutate, assign back (mutating through the subscript does not write).
	var v: PackedVector3Array = g["v"]
	var base := v.size()
	v.append_array(arr["verts"]); g["v"] = v
	var c: PackedColorArray = g["c"]
	c.append_array(arr["colors"]); g["c"] = c
	var uu: PackedVector2Array = g["u"]
	uu.append_array(arr["uvs"]); g["u"] = uu
	var dst: PackedInt32Array = g["i"]
	var src: PackedInt32Array = arr["indices"]
	for k in src:
		dst.push_back(k + base)
	g["i"] = dst


func _clear_mesh() -> void:
	for face in _mesh_groups:
		var mi: MeshInstance3D = _mesh_groups[face]
		if mi != null:
			remove_child(mi)
			mi.queue_free()
	_mesh_groups.clear()
	_group_bytes.clear()
	_mesh_bytes = 0


# ---- per-facet column bake (§2.4 — EXACT MIN decimate, no protrusion) ----------------------------------------------

var _col_cache: Dictionary = {}        # (fid*8 + level) -> level dict (exact MIN pyramid; cheap DATA, drift-cached)

## One facet's columns at `level`, as the EXACT MIN pyramid level (top = MIN over ALL fine L0 columns in each coarse
## cell), via the shipped FacetBlockLod decimate chain — so the megablock top is at-or-below the true terrain
## EVERYWHERE (no protrusion, G-BLD-ORBIT-MIN). Shaped exactly like FacetBlockLod.get_level(level) so the ring mesher
## consumes it unchanged. CACHED per (fid,level): a drift re-assign re-bakes only the newly-covered facets. PURE
## (reads only prewarmed statics + builds a transient RefCounted pyramid — the SAME build the ring's worker path uses)
## ⇒ worker-safe. NEVER-OOM: the cache is bounded (CACHE_MAX entries, wholesale-clear on breach).
func _bake_cols(fid: int, level: int) -> Dictionary:
	var key := fid * 8 + level
	if _col_cache.has(key):
		return _col_cache[key]
	var lod := FacetBlockLod.new()
	lod.build(fid)                                   # L0 analytic + L1..L5 exact MIN decimate (the ladder's chain)
	var lvl: Dictionary = lod.get_level(level)
	if _col_cache.size() >= CACHE_MAX:
		_col_cache.clear()                            # bounded transient DATA — wholesale-clear rather than grow
	_col_cache[key] = lvl
	return lvl


# ---- ledger / telemetry (NEVER-OOM §2.3 + gate) -------------------------------------------------------------------

func mesh_bytes() -> int:
	return _mesh_bytes

## Everything the orbit tier costs the memory budget (only the merged visible mesh — no always-resident data floor;
## the columns are transient per re-assign). The gate asserts this ≤ BLOCK_LOD_ORBIT_BYTES_MAX and combined < 40 MB.
func total_bytes() -> int:
	return _mesh_bytes

func draw_count() -> int:
	var n := 0
	for face in _mesh_groups:
		var mi: MeshInstance3D = _mesh_groups[face]
		if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			n += 1
	return n

## The facets the orbit mesh is CURRENTLY covering (with the level actually meshed) — the §2V-retire set: while the
## tier is engaged the far ring's smooth skin is suppressed, so these facets do NOT also draw §2V (swap, not overlay).
func covered_fids() -> Array:
	return _level_by_fid.keys()

func level_of(fid: int) -> int:
	return int(_level_by_fid.get(fid, -1))

func coarsen_events() -> int:
	return _coarsen_events

func dropped_limb() -> int:
	return _dropped_limb

func reassigns() -> int:
	return _reassigns

## True once the worker build has landed (nothing computing). The headless gate pumps the lane until this is true.
func async_idle() -> bool:
	return not _inflight


## Arithmetic peak-byte bound for a level→facet-count distribution (§2.3 gate): Σ level count·quads_est(level)·112 B/quad
## (28 B/vert × 4 verts). `quads_est` maps a level to an assumed greedy quads/facet (design §2.3: L5≈62, L4≈4×). PURE.
static func peak_bytes_for(level_counts: Dictionary, quads_est: Dictionary) -> int:
	var bytes_per_quad := 4 * FacetBlockLodRing.BYTES_PER_VERT + 6 * FacetBlockLodRing.BYTES_PER_INDEX  # 4 verts + 2 tris
	var t := 0
	for lvl in level_counts:
		var q: int = int(quads_est.get(lvl, 0))
		t += int(level_counts[lvl]) * q * bytes_per_quad
	return t
