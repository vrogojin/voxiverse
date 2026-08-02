class_name FacetSmoothTier
extends RefCounted
## COSMOS FAR-RENDER-OVERHAUL §2 (docs/COSMOS-FAR-RENDER-OVERHAUL-DESIGN.md) — SMOOTH far-terrain geometry
## (Item B, `FP_FAR_SMOOTH`). Naive Surface Nets (§2.2) over the `FarDensity` source: rounded mountains and
## (with B4) dug overhangs where the shipped far ring shows flat 26-104-block heightfield cells or blocky LOD
## megablocks. Painted by the SAME map skin as the heightfield (§2.6) — the smooth vertices carry the identical
## UV/UV2 attributes, so band → fine → base resolves with zero B-specific shader work beyond the normal swap.
##
## B1 SCOPE (this file today): the pure MESHER — `build_tile(fid, cells)` turns one (facet, tier) tile into an
## ArrayMesh-ready surface (pos/nrm/col/uv/uv2/idx), plus the tier consts and the byte ledger. NO render driver,
## NO LRU, NO worker dispatch, NO edit invalidation — those are B2/B3 (they clone the shipped `_pbm_*` slot +
## `_async_build_worker`/`_swap_in_arrays` patterns). Nothing in the running engine constructs a FacetSmoothTier
## yet ⇒ byte-identical, inert (FLAT 6042/0).
##
## HEIGHTFIELD DEGENERACY (§2.2): on the simple `FarDensity` path the density is a graph over the facet plane, so
## the surface net collapses to ONE vertex per column at the relief height — a smooth displaced grid. `build_tile`
## implements exactly that (the general edit-occupancy edge-scan plugs in at B4). This is why G-FS-DEGEN can assert
## `tris == 2·cells²` and radial normals on a flat facet: the net never hallucinates volume geometry.

# --- tier ladder (§2.4). cells-per-facet-edge per tier; MAX = residency cap (facets held resident at that tier) ---
# The pitch (blocks) is informational — the tile is tessellated at `cells` nodes/edge so a flat facet gives exactly
# 2·cells² tris. Real facet edges are ~417 blocks (K=24), so these match the design table's 4/8/16/32-block pitches.
enum { S2 = 0, S3 = 1, S4 = 2, S5 = 3 }

## cells-per-edge for a tier index (S2..S5). Reads the CubeSphere consts so the deploy sed / gate share one source.
static func cells_for_tier(tier: int) -> int:
	match tier:
		S2: return CubeSphere.SMOOTH_S2_CELLS
		S3: return CubeSphere.SMOOTH_S3_CELLS
		S4: return CubeSphere.SMOOTH_S4_CELLS
		_: return CubeSphere.SMOOTH_S5_CELLS

## residency cap (max facets held resident) for a tier index — NEVER-OOM: fixed at creation, enforced by the LRU (B3).
static func residency_for_tier(tier: int) -> int:
	match tier:
		S2: return CubeSphere.SMOOTH_S2_MAX
		S3: return CubeSphere.SMOOTH_S3_MAX
		S4: return CubeSphere.SMOOTH_S4_MAX
		_: return CubeSphere.SMOOTH_S5_MAX

## Build the smooth-tier surface for facet `fid` at `cells` cells-per-edge. Returns the packed arrays an ArrayMesh
## surface wants, all in ABSOLUTE planet-block coords (the far ring's frame — parented under its node so
## `shift_anchor`/`_placement_xform` apply unchanged). PURE + worker-safe (only FarDensity/FarPalette static reads).
##   pos : PackedVector3Array  (cells+1)²          nrm : PackedVector3Array density-gradient normals
##   col : PackedColorArray    skin fallback tint  uv  : PackedVector2Array ((a+s)/K,(b+t)/K) facet param
##   uv2 : PackedVector2Array  (face, slot)        idx : PackedInt32Array   2 tris/cell, front = outward
## `slot` is written −1 here (B2 overlay: UV2.y=-1 ⇒ the shell shader's fine/base branch paints it — no band).
## `lift` (blocks) nudges every vertex radially outward: the B2 overlay draws the smooth mesh a hair ABOVE the
## flat heightfield so it occludes it (sub-pixel at far distance) until the emit-exclusion path lands (increment 2).
## `curved` places vertices on the CURVED SPHERE `dir·(R + relief)` instead of on the flat inscribed facet quad — the
## piecewise-flat quads ARE the facet-boundary crease (adjacent flat tangent planes meet at a dihedral angle even at
## sea level), so curving the base is what removes the "straight lines stitching facets"; it also sits the tile above
## the inscribed heightfield (occlusion for free). Off (B1 gate) ⇒ the flat planar+relief placement node_at returns.
static func build_tile(fid: int, cells: int, lift: float = 0.0, curved: bool = false) -> Dictionary:
	FarPalette.ensure_ready()
	var r_datum := FacetAtlas.r_of(fid)
	var corners := [
		FacetAtlas.facet_planar_corner(fid, 0),
		FacetAtlas.facet_planar_corner(fid, 1),
		FacetAtlas.facet_planar_corner(fid, 2),
		FacetAtlas.facet_planar_corner(fid, 3),
	]
	var dec := _decode(fid)
	var face := int(dec[0])
	var a := int(dec[1])
	var b := int(dec[2])
	var kb := int(dec[3])
	var stride := cells + 1
	var n := stride * stride

	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	pos.resize(n)
	nrm.resize(n)
	col.resize(n)
	uv.resize(n)
	uv2.resize(n)
	# `dir` is kept only to orient the normals outward — not returned.
	var dirs := PackedVector3Array()
	dirs.resize(n)

	var inv := 1.0 / float(cells)
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var node := FarDensity.node_at(corners, s, t)
			var vi := gj * stride + gi
			var d: Vector3 = node["dir"]
			if curved:
				pos[vi] = d * (r_datum + float(node["relief"]) + lift)   # on the sphere → no dihedral crease across facets
			else:
				pos[vi] = (node["pos"] as Vector3) + d * lift            # flat planar+relief (B1 gate parity)
			dirs[vi] = d
			var g := int(node["g"])
			col[vi] = FarPalette.color_for(g, int(node["biome"]), float(node["temp"]), g < TerrainConfig.SEA_LEVEL)
			uv[vi] = Vector2((float(a) + s) / float(kb), (float(b) + t) / float(kb))
			uv2[vi] = Vector2(float(face), -1.0)

	# Per-vertex normal = normalized cross of the world-space tangents (central differences of the displaced grid
	# = the density gradient on a heightfield, §2.5), oriented outward (dot with the radial dir). On a flat facet
	# the tangents are the facet plane ⇒ the normal is radial (G-FS-DEGEN).
	for gj in range(stride):
		for gi in range(stride):
			var vi := gj * stride + gi
			var i0 := gi - 1 if gi > 0 else gi
			var i1 := gi + 1 if gi < cells else gi
			var j0 := gj - 1 if gj > 0 else gj
			var j1 := gj + 1 if gj < cells else gj
			var ts := pos[gj * stride + i1] - pos[gj * stride + i0]
			var tt := pos[j1 * stride + gi] - pos[j0 * stride + gi]
			var nv := ts.cross(tt)
			if nv.length_squared() <= 0.0:
				nv = dirs[vi]
			nv = nv.normalized()
			if nv.dot(dirs[vi]) < 0.0:
				nv = -nv
			nrm[vi] = nv

	var idx := PackedInt32Array()
	idx.resize(cells * cells * 6)
	var ii := 0
	for gj in range(cells):
		for gi in range(cells):
			var v00 := gj * stride + gi
			var v10 := v00 + 1
			var v01 := v00 + stride
			var v11 := v01 + 1
			# front (outward) winding: cross(v10−v00, v11−v10) aligns with the outward normal above.
			idx[ii] = v00; idx[ii + 1] = v10; idx[ii + 2] = v11
			idx[ii + 3] = v00; idx[ii + 4] = v11; idx[ii + 5] = v01
			ii += 6

	return {"pos": pos, "nrm": nrm, "col": col, "uv": uv, "uv2": uv2, "idx": idx}

## Resident byte cost of a built tile (§2.7 ledger, `SMOOTH_BYTES_MAX`). pos/nrm 12 B each, col 16 B, uv/uv2 8 B
## each, idx 4 B — the ArrayMesh vertex-buffer footprint the LRU accounts against the NEVER-OOM cap.
static func tile_bytes(tile: Dictionary) -> int:
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	return nv * (12 + 12 + 16 + 8 + 8) + ni * 4

## Decode `fid` → [face, a, b, k] in its body-local (face,a,b) indexing — mirrors FacetTexBaker._decode so UV =
## ((a+s)/k,(b+t)/k) agrees with the band/fine skin and the far ring.
static func _decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]

# =====================================================================================================================
# B2 INSTANCE — the worker-baked smooth-tile MeshInstance (docs/COSMOS-FAR-RENDER-OVERHAUL-DESIGN.md §2.7). A
# FacetFarRing owns ONE of these under FP_FAR_SMOOTH: it builds `build_tile` for a requested set of facets on
# WorkerThreadPool slots (cloned from the baker's _pbm pattern), merges the resident tiles into ONE ArrayMesh surface,
# and shares the ring's shell material so the map skin + every per-frame uniform bind come for free. Increment 1 draws
# it as an overlay (a small radial `lift`) — the emit-exclusion + normal-lit relief variant + skirts land in B2 inc-2.
# NEVER-OOM: resident tiles bounded by the requested set (≤ tier cap) + SMOOTH_BYTES_MAX ledger, fixed at creation.

var _mi: MeshInstance3D = null
var _material: Material = null
var _lift: float = 0.0
var _tiles: Dictionary = {}          # fid -> build_tile Dictionary (resident, committed on main)
var _want: Dictionary = {}           # fid -> cells (the requested resident set; the driver refreshes it)
var _bytes: int = 0                  # resident tile bytes (ledger)
var _dirty: bool = false             # a commit/evict happened → rebuild the merged mesh this step
# worker slots (single-writer of _s_* on main pre-dispatch; the worker writes only _s_result[i] under the mutex)
var _sn: int = 0
var _s_fid: PackedInt32Array
var _s_cells: PackedInt32Array
var _s_task: PackedInt32Array
var _s_result: Array = []
var _s_mutex: Mutex = null

## Create the MeshInstance under `parent` (inherits the ring's placement transform), share `material`, prewarm the
## worker-touched statics on MAIN (FarPalette / BlockCatalog / the noise via one profile_at_dir) so `build_tile` is
## worker-safe. `lift` (blocks) is the overlay nudge.
func setup_instance(parent: Node3D, material: Material, lift: float) -> void:
	FarPalette.ensure_ready()
	BlockCatalog.ensure_ready()
	TerrainConfig.profile_at_dir(0.0, 1.0, 0.0, FacetAtlas.R_BLOCKS)   # warm _ensure_noise on main
	_material = material
	_lift = lift
	_mi = MeshInstance3D.new()
	_mi.name = "FacetSmoothMesh"
	if material != null:
		_mi.material_override = material
	parent.add_child(_mi)
	_sn = clampi(OS.get_processor_count() - 1, 1, 4)
	_s_fid = PackedInt32Array(); _s_fid.resize(_sn); _s_fid.fill(-1)
	_s_cells = PackedInt32Array(); _s_cells.resize(_sn)
	_s_task = PackedInt32Array(); _s_task.resize(_sn); _s_task.fill(-1)
	_s_result.resize(_sn)
	_s_mutex = Mutex.new()

## The driver's requested resident set: facets → cells (tier pitch). Evicts tiles that fell out of the set.
func request(fids: Array, cells: int) -> void:
	var w := {}
	for f in fids:
		w[int(f)] = cells
	_want = w
	for fid in _tiles.keys():
		if not _want.has(int(fid)):
			_bytes -= FacetSmoothTier.tile_bytes(_tiles[int(fid)])
			_tiles.erase(int(fid))
			_dirty = true

## Per-frame: reap finished worker tiles (commit on main), dispatch idle slots to wanted-not-resident facets, and
## rebuild the merged mesh once if anything changed. Bounded per call.
func step() -> void:
	if _mi == null:
		return
	for i in range(_sn):
		if int(_s_task[i]) < 0 or not WorkerThreadPool.is_task_completed(int(_s_task[i])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(_s_task[i]))
		var fid := int(_s_fid[i])
		_s_mutex.lock()
		var tile = _s_result[i]
		_s_result[i] = null
		_s_mutex.unlock()
		if _want.has(fid) and tile != null and not _tiles.has(fid):
			var tb: int = FacetSmoothTier.tile_bytes(tile)
			if _bytes + tb <= CubeSphere.SMOOTH_BYTES_MAX:
				_tiles[fid] = tile
				_bytes += tb
				_dirty = true
		_s_fid[i] = -1
		_s_task[i] = -1
	for i in range(_sn):
		if int(_s_fid[i]) >= 0:
			continue
		var fid := _next_want()
		if fid < 0:
			break
		_s_fid[i] = fid
		_s_cells[i] = int(_want[fid])
		_s_task[i] = WorkerThreadPool.add_task(Callable(self, "_build_worker").bind(i), false, "smoothtile")
	if _dirty:
		_rebuild_mesh()
		_dirty = false

func _next_want() -> int:
	for fid in _want.keys():
		var f := int(fid)
		if _tiles.has(f) or _inflight(f):
			continue
		return f
	return -1

func _inflight(fid: int) -> bool:
	for i in range(_sn):
		if int(_s_fid[i]) == fid:
			return true
	return false

func _build_worker(i: int) -> void:
	var fid := int(_s_fid[i])
	var cells := int(_s_cells[i])
	var tile := FacetSmoothTier.build_tile(fid, cells, _lift, true)   # curved sphere placement (kills the facet crease)
	_s_mutex.lock()
	_s_result[i] = tile
	_s_mutex.unlock()

## Concatenate every resident tile into ONE ArrayMesh surface (index-offset) → ≤ 1 extra draw for the whole smooth set.
func _rebuild_mesh() -> void:
	var P := PackedVector3Array()
	var N := PackedVector3Array()
	var C := PackedColorArray()
	var U := PackedVector2Array()
	var U2 := PackedVector2Array()
	var I := PackedInt32Array()
	for fid in _tiles.keys():
		var t = _tiles[fid]
		var base := P.size()
		P.append_array(t["pos"])
		N.append_array(t["nrm"])
		C.append_array(t["col"])
		U.append_array(t["uv"])
		U2.append_array(t["uv2"])
		for idx in (t["idx"] as PackedInt32Array):
			I.append(base + idx)
	var mesh := ArrayMesh.new()
	if P.size() > 0:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = P
		arr[Mesh.ARRAY_NORMAL] = N
		arr[Mesh.ARRAY_COLOR] = C
		arr[Mesh.ARRAY_TEX_UV] = U
		arr[Mesh.ARRAY_TEX_UV2] = U2
		arr[Mesh.ARRAY_INDEX] = I
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		if _material != null:
			mesh.surface_set_material(0, _material)
	_mi.mesh = mesh

func resident_count() -> int:
	return _tiles.size()

func smooth_bytes() -> int:
	return _bytes

## The set of facets currently drawn smooth — the far-ring drops these from its heightfield emit (increment 2).
func resident_fids() -> Array:
	return _tiles.keys()
