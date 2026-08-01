class_name FacetBlockLodGlobal
extends Node3D
## COSMOS BLOCK-LOD P2 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4/§5/§9) — the L5 GLOBAL tier (FP_BLOCK_LOD_GLOBAL): the
## whole planet as 32-block megablocks, so it reads blocky from orbit. GATED CONSTRUCTION sibling of the far ring /
## ladder ⇒ byte-identical off.
##
## TWO PARTS, and the split is forced by MEASUREMENT (NEVER-OOM outranks visual depth, CLAUDE.md):
##   1. DATA FLOOR — the L5 column store {top,id,water} for ALL 3456 facets, ALWAYS RESIDENT, NEVER LRU-evicted. This
##      is the design §5 "≈2.3 MB always-resident floor" (measured ~3–4.5 MB with the streaming margin). Baked
##      progressively on the worker at boot (per cube face), never blocking main; the far ring backstops the fill gap.
##   2. VISIBLE MESH — a full-globe L5 greedy mesh is ~158 MB (measured 285 quads/facet × 3456), INFEASIBLE under the
##      16/28 MB ceiling, so the actual blocky geometry is only the NEAREST-camera facets (≤ BLOCK_LOD_GLOBAL_MESH_
##      FACETS), MERGED by cube face into ≤ BLOCK_LOD_GLOBAL_DRAWS ArrayMeshes (draw-ceiling safe), hard-capped at
##      BLOCK_LOD_GLOBAL_MESH_BYTES. Beyond the near cap the sunk far ring + FP_FACET_TEX smooth skin backstop — which
##      is design-correct: from orbit L5 blocks go sub-pixel, so the smooth satellite is the right tier out there.
##      The mesh is coarsen-shed under the shared ceiling (shed_mesh_once); the DATA floor is the irreducible reserve.
##
## CONTAINMENT: L5 columns are MIN-sampled over a 2×2 stencil (≈decimate of the L4-pitch base) so the coarse tops sit
## at-or-below the finer ladder tiles (overdrawn, no protrusion). The EXACT Ln+1==decimate(Ln) invariant is proven by
## the gate on sample facets via FacetBlockLod; the global store trades exactness for a bounded boot cost (documented).
## ONE shade law: the merged meshes use the generalized ring's shared material ⇒ lit identically to near↔L1↔ladder↔skin.

const LEVEL := 5
const PITCH := 1 << LEVEL              # 32-block megablocks
const STENCIL := 2                     # 2×2 MIN sub-sample per L5 column (containment vs the exact L0 decimate)
const BYTES_PER_COL := 6               # int32 top(4) + id(1) + water(1) — the always-resident DATA arithmetic

var _active_fid := -1
var _top: Dictionary = {}              # fid -> PackedInt32Array (L5 column top heights)
var _id: Dictionary = {}               # fid -> PackedByteArray
var _wat: Dictionary = {}              # fid -> PackedByteArray
var _dims: Dictionary = {}             # fid -> Vector2i (w5,h5)
var _data_bytes := 0                   # Σ cols·BYTES_PER_COL — the protected floor (never shrinks once built)
var _facets_baked := 0                 # progressive-bake progress (boot splash / telemetry)

var _mesh_groups: Dictionary = {}      # face(int) -> MeshInstance3D (merged L5 mesh; ≤ BLOCK_LOD_GLOBAL_DRAWS)
var _group_bytes: Dictionary = {}      # face -> int (merged mesh bytes)
var _mesh_bytes := 0                   # Σ _group_bytes (the shed-able visible mesh)
var _mesher: FacetBlockLodRing = null  # level-5 greedy mesher + shared shade material (NOT in the tree)
var _material: ShaderMaterial = null
var _sun_dir := Vector3(1.0, 0.0, 0.0)

var _lane: JobLane = null
var _worker_on := false
var _statics_warm := false
var _data_ready := false


func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_prewarm_statics(active_fid)
	_mesher = FacetBlockLodRing.new()
	_mesher._level = LEVEL
	_mesher._pitch = PITCH
	_mesher._sun_dir = _sun_dir
	_material = _mesher.shared_material()
	_material.set_shader_parameter("sun_dir", _sun_dir)
	set_process(true)
	# DATA floor: build all 3456 facets' L5 columns. Async (per-face units) when a lane is present; else inline (gate).
	if _worker_on:
		_dispatch_data_bake()
	else:
		_bake_all_data()
		_remesh_visible(active_fid)


func set_job_lane(lane: JobLane) -> void:
	_lane = lane
	_worker_on = lane != null


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


# ---- L5 DATA store (always-resident floor) ---------------------------------------------------------------------

## The L5 grid dims for `fid` — the SAME halving the pyramid uses (L0 dims → 5× ceil-halve), so the store's cells align
## bit-for-bit with FacetBlockLod.get_level(5) and the ladder's L4/L3 tiles (dmin + cx·PITCH corners weld cleanly).
static func _l5_dims(fid: int) -> Vector2i:
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var w := dmax.x - dmin.x + 1
	var h := dmax.y - dmin.y + 1
	for _i in range(LEVEL):
		w = (w + 1) >> 1
		h = (h + 1) >> 1
	return Vector2i(w, h)


## Bake one facet's L5 columns straight from facet_profile with a 2×2 MIN stencil (containment) — NOT a full L0
## decimate (3456×174k samples would be infeasible). top = MIN over the stencil (≤ the finer tiles); id/water from the
## MIN sub-cell. PURE (reads only prewarmed statics) ⇒ worker-safe.
func _bake_facet_data(fid: int) -> void:
	if _top.has(fid):
		return
	var dmin := FacetAtlas.dom_min(fid)
	var d := _l5_dims(fid)
	var w := d.x
	var h := d.y
	var top := PackedInt32Array(); top.resize(w * h)
	var idb := PackedByteArray(); idb.resize(w * h)
	var wat := PackedByteArray(); wat.resize(w * h)
	var sub := PITCH / STENCIL            # 16-block sub-step
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			var tmin := 0x7fffffff
			var mid := 0
			var mwat := 0
			var wor := 0
			for sz in range(STENCIL):
				for sx in range(STENCIL):
					var lx := dmin.x + cx * PITCH + sx * sub + (sub >> 1)
					var lz := dmin.y + cz * PITCH + sz * sub + (sub >> 1)
					var prof := TerrainConfig.facet_profile(fid, lx, lz)
					var g := int(prof.x)
					if g < TerrainConfig.SEA_LEVEL:
						wor = 1
					if g < tmin:
						tmin = g
						mid = clampi(int(prof.y), 0, 255)
						mwat = 1 if g < TerrainConfig.SEA_LEVEL else 0
			top[ci] = tmin
			idb[ci] = mid
			wat[ci] = 1 if (wor != 0 or mwat != 0) else 0
	_top[fid] = top
	_id[fid] = idb
	_wat[fid] = wat
	_dims[fid] = d
	_data_bytes += w * h * BYTES_PER_COL
	_facets_baked += 1


func _bake_all_data() -> void:
	for fid in range(FacetAtlas.facet_count()):
		_bake_facet_data(fid)
	_data_ready = true


## The stored L5 level dict for `fid`, shaped exactly like FacetBlockLod.get_level(5) so the ring mesher consumes it.
func _level_dict(fid: int) -> Dictionary:
	var d: Vector2i = _dims[fid]
	return {"n": LEVEL, "w": d.x, "h": d.y, "top": _top[fid], "id": _id[fid], "water": _wat[fid]}


# ---- progressive async DATA bake (boot) ------------------------------------------------------------------------

class FaceUnit:
	extends RefCounted
	var face := -1
	var tops: Dictionary = {}
	var ids: Dictionary = {}
	var wats: Dictionary = {}
	var dims: Dictionary = {}
	var bytes := 0

## Submit the 6 cube faces as worker units (each bakes its 576 facets' L5 columns into its own buffer — single-writer,
## race-free), committed on main (merge the buffer into the store). After the last face lands, mesh the near cap.
func _dispatch_data_bake() -> void:
	var nfaces := FacetAtlas.facet_count() / (FacetAtlas.K * FacetAtlas.K)   # 6 for Earth
	for face in range(nfaces):
		var unit := FaceUnit.new()
		unit.face = face
		_lane.submit(JobLane.PRIORITY_BLOCK_LOD,
			Callable(self, "_worker_bake_face").bind(unit), Callable(self, "_commit_face").bind(unit),
			"blocklod-global-face%d" % face)


func _worker_bake_face(unit: FaceUnit) -> void:
	var kk := FacetAtlas.K * FacetAtlas.K
	var lo := unit.face * kk
	for fid in range(lo, lo + kk):
		var dmin := FacetAtlas.dom_min(fid)
		var d := _l5_dims(fid)
		var w := d.x
		var h := d.y
		var top := PackedInt32Array(); top.resize(w * h)
		var idb := PackedByteArray(); idb.resize(w * h)
		var wat := PackedByteArray(); wat.resize(w * h)
		var sub := PITCH / STENCIL
		for cz in range(h):
			for cx in range(w):
				var ci := cz * w + cx
				var tmin := 0x7fffffff
				var mid := 0
				var wor := 0
				for sz in range(STENCIL):
					for sx in range(STENCIL):
						var lx := dmin.x + cx * PITCH + sx * sub + (sub >> 1)
						var lz := dmin.y + cz * PITCH + sz * sub + (sub >> 1)
						var prof := TerrainConfig.facet_profile(fid, lx, lz)
						var g := int(prof.x)
						if g < TerrainConfig.SEA_LEVEL:
							wor = 1
						if g < tmin:
							tmin = g
							mid = clampi(int(prof.y), 0, 255)
				top[ci] = tmin
				idb[ci] = mid
				wat[ci] = wor
		unit.tops[fid] = top
		unit.ids[fid] = idb
		unit.wats[fid] = wat
		unit.dims[fid] = d
		unit.bytes += w * h * BYTES_PER_COL


func _commit_face(unit: FaceUnit) -> void:
	for fid in unit.tops:
		if _top.has(fid):
			continue
		_top[fid] = unit.tops[fid]
		_id[fid] = unit.ids[fid]
		_wat[fid] = unit.wats[fid]
		_dims[fid] = unit.dims[fid]
		_data_bytes += int(unit.dims[fid].x) * int(unit.dims[fid].y) * BYTES_PER_COL
		_facets_baked += 1
	if _facets_baked >= FacetAtlas.facet_count():
		_data_ready = true
		_remesh_visible(_active_fid)


# ---- visible merged mesh (byte-capped, camera-facing) ----------------------------------------------------------

func rebuild(active_fid: int) -> void:
	_active_fid = active_fid
	if _data_ready:
		_remesh_visible(active_fid)


## The nearest-camera facets to mesh: the ≤ BLOCK_LOD_GLOBAL_MESH_FACETS facets closest to the active-facet centre
## (the sub-camera nadir from orbit), bounded so the merged mesh stays under the cap. Grouped by cube face for merge.
func _visible_facets(active_fid: int) -> Array:
	var c0 := _centre(active_fid)
	var all: Array = []
	for fid in range(FacetAtlas.facet_count()):
		all.append([fid, (_centre(fid) - c0).length_squared()])
	all.sort_custom(func(a, b): return a[1] < b[1])
	var out: Array = []
	for i in range(mini(all.size(), CubeSphere.BLOCK_LOD_GLOBAL_MESH_FACETS)):
		out.append(int(all[i][0]))
	return out


func _centre(fid: int) -> Vector3:
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var a := FacetAtlas.lattice_to_world64(fid, float(dmin.x + dmax.x) * 0.5, 0.0, float(dmin.y + dmax.y) * 0.5)
	return Vector3(a[0], a[1], a[2])


## Rebuild the merged visible mesh: greedy-mesh each near facet from the STORE, merge by cube face into ≤ DRAWS
## ArrayMeshes, hard-cap the total at BLOCK_LOD_GLOBAL_MESH_BYTES (stop adding faces once the cap is hit). Fully
## replaces the previous groups (a coarse whole-set refresh — cheap: the mesh reads the already-baked store).
func _remesh_visible(active_fid: int) -> void:
	if not _data_ready:
		return
	_clear_mesh()
	var vis := _visible_facets(active_fid)
	var kk := FacetAtlas.K * FacetAtlas.K
	# accumulate per face group
	var groups: Dictionary = {}      # face -> {verts,colors,uvs,indices}
	for fid in vis:
		if not _top.has(fid):
			continue
		var face: int = (fid - FacetAtlas.fid_base_of(fid)) / kk
		if not groups.has(face):
			groups[face] = {"v": PackedVector3Array(), "c": PackedColorArray(), "u": PackedVector2Array(), "i": PackedInt32Array()}
		var g: Dictionary = groups[face]
		var arr := _mesher.mesh_arrays_from_level(fid, _level_dict(fid))
		_append(g, arr)
	# commit ≤ DRAWS groups under the byte cap
	var faces := groups.keys()
	faces.sort()
	var committed := 0
	for face in faces:
		if committed >= CubeSphere.BLOCK_LOD_GLOBAL_DRAWS:
			break
		var g: Dictionary = groups[face]
		var verts: PackedVector3Array = g["v"]
		if verts.is_empty():
			continue
		var nidx: int = (g["i"] as PackedInt32Array).size()
		var bytes := verts.size() * FacetBlockLodRing.BYTES_PER_VERT + nidx * FacetBlockLodRing.BYTES_PER_INDEX
		if _mesh_bytes + bytes > CubeSphere.BLOCK_LOD_GLOBAL_MESH_BYTES:
			continue                 # cap reached — leave the rest to the far-ring backstop (no hole)
		var am := ArrayMesh.new()
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_COLOR] = g["c"]
		a[Mesh.ARRAY_TEX_UV] = g["u"]
		a[Mesh.ARRAY_INDEX] = g["i"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		var mi := MeshInstance3D.new()
		mi.name = "BlockLodL5_face%d" % face
		mi.mesh = am
		mi.material_override = _material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_mesh_groups[face] = mi
		_group_bytes[face] = bytes
		_mesh_bytes += bytes
		committed += 1


func _append(g: Dictionary, arr: Dictionary) -> void:
	# GDScript CoW gotcha: mutating a Packed array THROUGH the dict subscript does not write back — pull it out, mutate,
	# assign it back so the accumulation actually lands in `g`.
	var v: PackedVector3Array = g["v"]
	var base := v.size()
	v.append_array(arr["verts"]); g["v"] = v
	var c: PackedColorArray = g["c"]
	c.append_array(arr["colors"]); g["c"] = c
	var u: PackedVector2Array = g["u"]
	u.append_array(arr["uvs"]); g["u"] = u
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


## Coordinator hook: shed the largest visible mesh group (the ladder calls this after coarsening its own tiers when
## the shared ceiling is still breached). The DATA floor is untouched; the far ring backstops the shed region.
func shed_mesh_once() -> void:
	var victim := -1
	var vb := -1
	for face in _group_bytes:
		var b: int = _group_bytes[face]
		if b > vb:
			vb = b
			victim = face
	if victim < 0:
		return
	var mi: MeshInstance3D = _mesh_groups[victim]
	if mi != null:
		remove_child(mi)
		mi.queue_free()
	_mesh_groups.erase(victim)
	_mesh_bytes -= int(_group_bytes.get(victim, 0))
	_group_bytes.erase(victim)


# ---- telemetry / coordinator ledger ----------------------------------------------------------------------------

func data_bytes() -> int:
	return _data_bytes

func mesh_bytes() -> int:
	return _mesh_bytes

## Everything the global tier costs the shared ceiling: the always-resident DATA floor + the shed-able visible mesh.
func total_bytes() -> int:
	return _data_bytes + _mesh_bytes

func facets_total() -> int:
	return FacetAtlas.facet_count()

func facets_baked() -> int:
	return _facets_baked

func data_ready() -> bool:
	return _data_ready

func draw_count() -> int:
	return _mesh_groups.size()

## Arithmetic DATA floor (the gate asserts _data_bytes == this): Σ over all facets of w5·h5·BYTES_PER_COL.
func data_bytes_arithmetic() -> int:
	var t := 0
	for fid in range(FacetAtlas.facet_count()):
		var d := _l5_dims(fid)
		t += d.x * d.y * BYTES_PER_COL
	return t
