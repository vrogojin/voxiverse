class_name FacetBlockLodRing
extends Node3D
## COSMOS BLOCK-LOD P1 (docs/COSMOS-BLOCK-LOD-DESIGN.md §4/§5/§9) — the ONE visible L2 (pitch-4) block ring, meshed
## from the P0 `FacetBlockLod` column pyramid and drawn OVER the sunk far ring (FacetFarRing, kept as the always-there
## backstop). Sibling of FacetFarRing/FacetSkinTier: absolute planet coords, per-facet MERGED surfaces (one ArrayMesh
## + one MeshInstance per band facet ⇒ draws ≈ live facet tiles), the same placement/weld/skirt discipline as
## FacetFarRing._emit_blocky. Created ONLY behind CubeSphere.FP_BLOCK_LOD (gate-constructed by WorldManager like _skin
## / _facet_tex); absent with the flag off ⇒ zero cost, byte-identical.
##
## RENDER FRAME: this node is added as a CHILD of the FacetFarRing node, so it inherits the far ring's placement
## transform verbatim (T_active⁻¹ / the fixed-frame anchor / the SN3 scaled placement) every frame — the L2 tile
## meshes are in ABSOLUTE planet coords (like the far ring's), so as a child at local identity they render coherently
## with the near blocks + the far ring at any facet/altitude with ZERO transform book-keeping of our own.
##
## MESHING (§4), mirroring FacetFarRing._emit_blocky onto the L2 lattice column grid:
##   - Per L2 column (a 4×4-block megacell): a FLAT top quad at radius R_BLOCKS + max(0, top_h)*RELIEF — the SAME
##     top→radius law the far ring uses (_weld_place), so the L2 ring sits coherently with the near field + far ring.
##   - A vertical side WALL on each internal edge where a same-level neighbour column is lower (closes the step,
##     watertight), coloured by the higher block.
##   - A boundary SKIRT dropped one coarse pitch (4 blocks radial) on the tile's outer edges (first/last row/col),
##     closing the silhouette gap against the tier beneath.
##   Corner directions come from the shared integer (fid,x,z) lattice via node_dir() ⇒ adjacent columns of a facet
##   weld bit-identically (same lattice node → same direction). Cross-facet edges are closed by the boundary skirt
##   exactly as FacetFarRing._emit_blocky does (the sibling's own blocky path skirts facet boundaries; it does not
##   attempt a bit-exact cross-facet vertex weld). MIN-rule tops (P0 §3) ⇒ every L2 vertex sits at-or-below the true
##   fine surface (no-protrusion by containment, G-BLD-NOPROTRUDE) ⇒ overdrawn by near voxels, overdraws the far ring.
##
## NEVER-OOM (§5): an explicit per-facet tile LRU + a BLOCK_LOD_BYTES_MAX mesh-byte ledger. Tiles that leave the band
## are freed (bytes reclaimed); a new tile is built only if it fits under the ceiling (else the far ring covers that
## facet); a hard-ceiling breach wholesale-clears. The transient FacetBlockLod pyramid is dropped after the L2 level is
## read (RefCounted), so only the finished L2 meshes are resident.

const RELIEF := 1.0                          # blocks of radial relief per (top_h − SEA_LEVEL) — MIRRORS FacetFarRing.RELIEF

var _mat: Material = null                     # shared far-ring material (mirror exactly ⇒ shade·tint + sun_dir sync for free)
var _active_fid := -1
# fid -> MeshInstance3D (one merged L2 tile per band facet). The LRU order + byte ledger below bound residency.
var _tiles: Dictionary = {}
var _tile_bytes: Dictionary = {}             # fid -> int (this tile's mesh bytes, the ledger's per-entry arithmetic)
var _lru: Array = []                          # fids, oldest-first (front = evict candidate)
var _bytes := 0                               # running sum of _tile_bytes (== the resident-tile arithmetic; G-BLD-BYTES)


## Gate-constructed by WorldManager behind FP_BLOCK_LOD. `material` is the far ring's shared material (mirror exactly);
## null is tolerated (the gate drives the mesher without a material — geometry is material-independent).
func setup(active_fid: int, material: Material = null) -> void:
	_active_fid = active_fid
	_mat = material


## Per streaming-update driver (WorldManager). `candidate_fids` = the far ring's front-hemisphere visible set. Selects
## the L2 band (an angular annulus around the active sub-point), builds ≤ BLOCK_LOD_TILES_PER_UPDATE missing band tiles
## (nearest-first, under the byte ceiling), and frees tiles whose facet left the band. Bounded per-frame work.
func update(active_fid: int, candidate_fids: PackedInt32Array) -> void:
	_active_fid = active_fid
	var band := _band_fids(active_fid, candidate_fids)   # Array of [fid, dot] (dot = cos angle to sub-point), band only
	var band_set := {}
	for e in band:
		band_set[int(e[0])] = true
	# Free tiles that left the band (reclaim bytes) — keeps residency bounded to the live annulus.
	for fid in _tiles.keys():
		if not band_set.has(fid):
			_free_tile(fid)
	# Build the nearest missing band tiles first (largest dot = smallest angle = nearest), bounded per update.
	band.sort_custom(func(a, b): return a[1] > b[1])
	var built := 0
	for e in band:
		if built >= CubeSphere.BLOCK_LOD_TILES_PER_UPDATE:
			break
		var fid := int(e[0])
		if _tiles.has(fid):
			continue
		if _bytes >= CubeSphere.BLOCK_LOD_BYTES_MAX:
			break                                # ceiling reached — far ring covers the rest (no unbounded growth)
		_add_tile(fid)
		built += 1


## The L2 band membership: facets whose CENTRE sub-point sits in the [BAND_MIN, BAND_MAX]-block angular annulus around
## the active facet's sub-point. Surface arc = R·θ ⇒ θ_min = BAND_MIN/R, θ_max = BAND_MAX/R; a facet is in-band iff
## dot(centre, active_centre) ∈ [cos θ_max, cos θ_min]. The inner cut (cos θ_min) excludes the active facet + ring-1
## (covered by the near voxel field / far-ring backstop). Returns Array of [fid, dot].
func _band_fids(active_fid: int, candidate_fids: PackedInt32Array) -> Array:
	var r := FacetAtlas.R_BLOCKS
	var cos_near := cos(CubeSphere.BLOCK_LOD_BAND_MIN / r)   # nearest allowed (largest dot)
	var cos_far := cos(CubeSphere.BLOCK_LOD_BAND_MAX / r)    # farthest allowed (smallest dot)
	var ac := _facet_centre_dir(active_fid)
	var out: Array = []
	for i in range(candidate_fids.size()):
		var fid := candidate_fids[i]
		if fid == active_fid:
			continue
		var d := _facet_centre_dir(fid)
		var dot := d.dot(ac)
		if dot <= cos_near and dot >= cos_far:
			out.append([fid, dot])
	return out


## Facet centre direction = node_dir at the facet's lattice-domain centre (dom is the polygon bbox + symmetric margin,
## so its centre is the polygon centre). Unit vector in ABSOLUTE planet space.
func _facet_centre_dir(fid: int) -> Vector3:
	var lo := FacetAtlas.dom_min(fid)
	var hi := FacetAtlas.dom_max(fid)
	return _node_dir(fid, 0.5 * float(lo.x + hi.x), 0.5 * float(lo.y + hi.y))


## The unit ABSOLUTE direction of lattice NODE (x,z) on facet `fid` (fractional allowed). Uses the PUBLIC f64
## lattice→world map at radial coord y=0 (the planar base point) then normalizes — identical to FacetAtlas.cell_dir's
## construction except sampled at the integer NODE (no +0.5 cell-centre offset), so a column corner shared by two
## adjacent columns of the SAME facet casts to the SAME direction ⇒ they weld bit-identically.
func _node_dir(fid: int, x: float, z: float) -> Vector3:
	var w := FacetAtlas.lattice_to_world64(fid, x, 0.0, z)
	return Vector3(w[0], w[1], w[2]).normalized()


## Build facet `fid`'s L2 tile as one merged MeshInstance3D, register it (LRU + ledger), and add it as a child.
func _add_tile(fid: int) -> void:
	var res := _mesh_l2(fid)
	var mesh: ArrayMesh = res["mesh"]
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.name = "BlockLodL2_%d" % fid
	mi.mesh = mesh
	if _mat != null:
		mi.material_override = _mat
	add_child(mi)
	_tiles[fid] = mi
	_tile_bytes[fid] = int(res["bytes"])
	_bytes += int(res["bytes"])
	_lru.erase(fid)
	_lru.append(fid)                              # newest at the back
	# NEVER-OOM: a hard-ceiling breach wholesale-clears (defensive — the build gate above already stops under budget).
	if _bytes > CubeSphere.BLOCK_LOD_BYTES_MAX:
		_wholesale_clear()


func _free_tile(fid: int) -> void:
	if not _tiles.has(fid):
		return
	var mi: MeshInstance3D = _tiles[fid]
	remove_child(mi)
	mi.queue_free()
	_tiles.erase(fid)
	_bytes -= int(_tile_bytes.get(fid, 0))
	_tile_bytes.erase(fid)
	_lru.erase(fid)


## NEVER-OOM breach handler (§5): drop ALL resident tiles (the far ring backstop covers the band meanwhile). Bounded,
## never leaves a stale ledger. Rebuild resumes next update under the ceiling.
func _wholesale_clear() -> void:
	for fid in _tiles.keys():
		var mi: MeshInstance3D = _tiles[fid]
		remove_child(mi)
		mi.queue_free()
	_tiles.clear()
	_tile_bytes.clear()
	_lru.clear()
	_bytes = 0


## Mesh facet `fid`'s L2 level into ONE ArrayMesh (per-facet merge). Returns a Dictionary the gates read directly:
##   mesh    : ArrayMesh (0 or 1 surface — G-BLD-DRAWS)
##   bytes   : int (this tile's mesh byte arithmetic — the ledger entry)
##   verts   : PackedVector3Array (ABSOLUTE, every emitted vertex — G-BLD-NOPROTRUDE / G-BLD-SEAM)
##   w, h    : int (L2 column grid dims)
##   top_r   : PackedFloat32Array (w*h; per-column top RADIUS — the weld/seam check reads shared-edge equality here)
##   top_h   : PackedInt32Array (w*h; the pyramid's MIN-rule top height — no-protrusion re-derivation)
##   dom_min : Vector2i (lattice origin, for the footprint→lattice mapping)
##   skirt_edge : PackedByteArray (w*h; bit0..3 = a boundary skirt was emitted on -x/+x/-z/+z edge)
## Flag-independent: the gate calls this on real facets directly. The transient pyramid is dropped on return.
func _mesh_l2(fid: int) -> Dictionary:
	var pitch := 1 << CubeSphere.BLOCK_LOD_LEVEL          # 4 blocks
	var lod := FacetBlockLod.new()
	lod.build(fid)                                        # L0..L5 (P0). We read L2; the RefCounted drops on return.
	var lvl := lod.get_level(CubeSphere.BLOCK_LOD_LEVEL)
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var top: PackedInt32Array = lvl["top"]
	var idb: PackedByteArray = lvl["id"]
	var wat: PackedByteArray = lvl["water"]
	var dmin := FacetAtlas.dom_min(fid)
	var skirt_r := float(pitch) * RELIEF                 # one coarse pitch radial drop

	# Per-column top radius + colour + corner directions (shared corners between adjacent columns are the SAME node).
	var top_r := PackedFloat32Array(); top_r.resize(w * h)
	var cols := PackedColorArray(); cols.resize(w * h)
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			var g: int = top[ci]
			top_r[ci] = FacetAtlas.R_BLOCKS + maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			# Colour: pyramid top_h(g) + decimated id(biome) + water(sea), latitude-t re-sampled at the column centre
			# (the pyramid does not carry t) — the SAME FarPalette.color_for mapping the far ring uses.
			var xc := dmin.x + cx * pitch + (pitch >> 1)
			var zc := dmin.y + cz * pitch + (pitch >> 1)
			var t := TerrainConfig.facet_profile(fid, xc, zc).w
			cols[ci] = FarPalette.color_for(g, int(idb[ci]), t, wat[ci] != 0)

	# Node directions on the (w+1)×(h+1) corner lattice: N(cx,cz) at lattice node (dmin + cx*pitch, dmin + cz*pitch).
	var nd := PackedVector3Array(); nd.resize((w + 1) * (h + 1))
	for nz in range(h + 1):
		for nx in range(w + 1):
			nd[nz * (w + 1) + nx] = _node_dir(fid, float(dmin.x + nx * pitch), float(dmin.y + nz * pitch))

	var skirt_edge := PackedByteArray(); skirt_edge.resize(w * h)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var verts := PackedVector3Array()
	for cz in range(h):
		for cx in range(w):
			var ci := cz * w + cx
			var r: float = top_r[ci]
			var c: Color = cols[ci]
			var d00: Vector3 = nd[cz * (w + 1) + cx]
			var d10: Vector3 = nd[cz * (w + 1) + cx + 1]
			var d01: Vector3 = nd[(cz + 1) * (w + 1) + cx]
			var d11: Vector3 = nd[(cz + 1) * (w + 1) + cx + 1]
			# FLAT top (2 tris) — all four corners at the column's own (MIN-rule) top radius.
			var t00 := d00 * r; var t10 := d10 * r; var t01 := d01 * r; var t11 := d11 * r
			_tri(st, c, t00, t01, t10, verts)
			_tri(st, c, t10, t01, t11, verts)
			var e := 0
			# +x internal edge (shared corners N10,N11): ONE wall to a lower same-level neighbour; boundary → skirt.
			if cx + 1 < w:
				var rn: float = top_r[ci + 1]
				if absf(r - rn) > 0.001:
					_wall(st, d10, d11, r, rn, c if r >= rn else cols[ci + 1], verts)
			else:
				_wall(st, d10, d11, r, r - skirt_r, c, verts); e |= 2
			# +z internal edge (shared corners N01,N11).
			if cz + 1 < h:
				var rd: float = top_r[ci + w]
				if absf(r - rd) > 0.001:
					_wall(st, d01, d11, r, rd, c if r >= rd else cols[ci + w], verts)
			else:
				_wall(st, d01, d11, r, r - skirt_r, c, verts); e |= 8
			# -x / -z outer boundary skirts (first row/col) — close the silhouette against the tier beneath.
			if cx == 0:
				_wall(st, d00, d01, r, r - skirt_r, c, verts); e |= 1
			if cz == 0:
				_wall(st, d00, d10, r, r - skirt_r, c, verts); e |= 4
			skirt_edge[ci] = e
	st.generate_normals()                                # correct for the lit StandardMaterial path; harmless unshaded
	var mesh: ArrayMesh = st.commit()                    # SurfaceTool.commit() → a single-surface ArrayMesh (1 draw)
	var bytes := verts.size() * (12 + 16 + 12)           # pos + color + normal, non-indexed
	return {"mesh": mesh, "bytes": bytes, "verts": verts, "w": w, "h": h, "top_r": top_r,
			"top_h": top, "dom_min": dmin, "skirt_edge": skirt_edge}


## One triangle (a,b,c) with a flat colour; also record the verts for the gate.
func _tri(st: SurfaceTool, c: Color, a: Vector3, b: Vector3, cc: Vector3, verts: PackedVector3Array) -> void:
	st.set_color(c); st.add_vertex(a)
	st.set_color(c); st.add_vertex(b)
	st.set_color(c); st.add_vertex(cc)
	verts.push_back(a); verts.push_back(b); verts.push_back(cc)


## A vertical wall quad between two corner directions from radius r0 to r1 (2 tris). CULL_DISABLED material ⇒ winding
## is free; coloured by the caller (the higher block). Mirrors FacetFarRing._emit_wall.
func _wall(st: SurfaceTool, da: Vector3, db: Vector3, r0: float, r1: float, c: Color, verts: PackedVector3Array) -> void:
	var hi := maxf(r0, r1); var lo := minf(r0, r1)
	var a_hi := da * hi; var b_hi := db * hi; var a_lo := da * lo; var b_lo := db * lo
	_tri(st, c, a_hi, a_lo, b_hi, verts)
	_tri(st, c, b_hi, a_lo, b_lo, verts)


# ---- gate accessors (read-only) --------------------------------------------------------------------------------
func tile_count() -> int:
	return _tiles.size()

func bytes_total() -> int:
	return _bytes

func tile_bytes(fid: int) -> int:
	return int(_tile_bytes.get(fid, 0))

func lru_order() -> Array:
	return _lru.duplicate()

func surface_count(fid: int) -> int:
	if not _tiles.has(fid):
		return 0
	var mi: MeshInstance3D = _tiles[fid]
	return 0 if mi.mesh == null else (mi.mesh as ArrayMesh).get_surface_count()
