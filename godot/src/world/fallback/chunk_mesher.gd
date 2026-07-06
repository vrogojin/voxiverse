class_name ChunkMesher
extends RefCounted
## Pure-GDScript mesher for one heightmap chunk, now MULTI-MATERIAL (DESIGN §4.5).
##
## The world is a layered heightmap (grass surface, dirt band, stone below) plus a
## deterministic tree overlay and a sparse player-edit overlay. This is the SAFETY
## NET path (the godot_voxel module is the live path); it shows the layers and the
## trees, but arbitrary mid-column carves render exactly only on the module path —
## the fallback models top-of-column digs via `effective_height`.
##
##   * TOP faces are greedy-merged by (effective_height, top block id) — adjacent
##     columns of equal height AND equal top material collapse into one quad, and a
##     dug column whose new top cell is dirt renders a dirt top.
##   * SIDE faces per downward step are split into contiguous same-id vertical
##     segments (via world.block_id_at), so hillsides show grass/dirt/stone banding.
##   * TREES: tree cells overlapping the chunk emit cubes (faces where the neighbour
##     is air), for the genuine, unchopped, non-buried tree cells only.
##   * PLACED blocks: player-placed cells (edit id > 0) emit cubes the same way.
##
## Emits one ArrayMesh with up to 5 surfaces (one per block id present), each with
## its BlockMaterials material. Cell (x,y,z) spans [x,x+1]³. UVs are 1 tile / face.

## Build an ArrayMesh for chunk (cx, cz). `world` supplies composed heights + ids;
## when null (safety), renders a grass-only heightmap.
static func build(cx: int, cz: int, world: WorldManager = null) -> ArrayMesh:
	var n := TerrainConfig.CHUNK_SIZE
	var x0 := cx * n
	var z0 := cz * n
	var stride := n + 2

	# Effective column heights incl. a 1-cell border (for edge side faces).
	var hmap := PackedInt32Array()
	hmap.resize(stride * stride)
	for lz in stride:
		for lx in stride:
			var wx := x0 + lx - 1
			var wz := z0 + lz - 1
			hmap[lz * stride + lx] = world.effective_height(wx, wz) if world != null \
				else TerrainConfig.height_at(wx, wz)

	# Top block id per interior column (for the greedy top merge key).
	var topids := PackedInt32Array()
	topids.resize(n * n)
	# Surface cell MODIFIER per interior column (0 = FULL). P5b-2 worldgen smoothing
	# reshapes the top cell of a land column: a non-zero modifier column renders as
	# ShapeMesh geometry (surface + any cap), NOT a flat quad, so it is excluded from the
	# greedy top merge and its side wall is capped at the cell floor so the slope shows.
	var topmods := PackedInt32Array()
	topmods.resize(n * n)
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			topids[lz * n + lx] = _cell_id(world, x0 + lx, h, z0 + lz)
			topmods[lz * n + lx] = CellCodec.modifier(world.cell_value_at(Vector3i(x0 + lx, h, z0 + lz))) \
				if world != null else 0

	# One SurfaceTool per block id present (lazily begun on first face).
	var tools: Dictionary = {}   # int block_id -> SurfaceTool
	_emit_tops(tools, hmap, topids, topmods, stride, n, x0, z0)
	_emit_sides(tools, world, hmap, topmods, stride, n, x0, z0)
	if world != null:
		_emit_terrain_shapes(tools, world, hmap, stride, n, x0, z0)
		_emit_trees(tools, world, n, x0, z0)
		_emit_placed(tools, world, n, x0, z0)

	if tools.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for id: int in tools.keys():
		var st: SurfaceTool = tools[id]
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, BlockMaterials.get_for(id))
	if mesh.get_surface_count() == 0:
		return null
	return mesh

# --- top faces: greedy 2D merge over equal (height, top id) ---------------------
static func _emit_tops(tools: Dictionary, hmap: PackedInt32Array, topids: PackedInt32Array,
		topmods: PackedInt32Array, stride: int, n: int, x0: int, z0: int) -> void:
	var used := PackedByteArray()
	used.resize(n * n)
	# A smoothing-shaped surface cell renders via _emit_terrain_shapes (ShapeMesh), not a
	# flat quad — mark it used so the greedy merge skips it and never floats a flat top
	# over a ramp (nor lets it break a flat run).
	for i in n * n:
		if topmods[i] != 0:
			used[i] = 1
	for lz in n:
		for lx in n:
			if used[lz * n + lx]:
				continue
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			var id := topids[lz * n + lx]

			var w := 1
			while lx + w < n and not used[lz * n + lx + w] \
					and hmap[(lz + 1) * stride + (lx + 1 + w)] == h \
					and topids[lz * n + lx + w] == id:
				w += 1

			var d := 1
			var can_grow := true
			while lz + d < n and can_grow:
				for k in w:
					if used[(lz + d) * n + lx + k] \
							or hmap[(lz + 1 + d) * stride + (lx + 1 + k)] != h \
							or topids[(lz + d) * n + lx + k] != id:
						can_grow = false
						break
				if can_grow:
					d += 1

			for dz in d:
				for dx in w:
					used[(lz + dz) * n + lx + dx] = 1

			if id == BlockCatalog.AIR:
				continue
			var y := float(h + 1)
			var wx0 := float(x0 + lx)
			var wz0 := float(z0 + lz)
			var wx1 := wx0 + w
			var wz1 := wz0 + d
			_quad(_tool_for(tools, id), Vector3.UP,
				Vector3(wx0, y, wz0), Vector3(wx0, y, wz1),
				Vector3(wx1, y, wz1), Vector3(wx1, y, wz0),
				Vector2(wx0, wz0), Vector2(wx0, wz1),
				Vector2(wx1, wz1), Vector2(wx1, wz0))

# --- side faces: one wall per downward step, split by block id ------------------
static func _emit_sides(tools: Dictionary, world: WorldManager, hmap: PackedInt32Array,
		topmods: PackedInt32Array, stride: int, n: int, x0: int, z0: int) -> void:
	var dirs := [
		{"dx": 1, "dz": 0, "nrm": Vector3(1, 0, 0)},
		{"dx": -1, "dz": 0, "nrm": Vector3(-1, 0, 0)},
		{"dx": 0, "dz": 1, "nrm": Vector3(0, 0, 1)},
		{"dx": 0, "dz": -1, "nrm": Vector3(0, 0, -1)},
	]
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			var wx := x0 + lx
			var wz := z0 + lz
			# A shaped (smoothed) surface cell draws its own side trapezoids via
			# _emit_terrain_shapes, so cap the flat wall at the cell FLOOR (h) instead of
			# its top (h+1) — otherwise a full vertical face would hide the slope. FULL
			# columns keep the wall to h+1 (byte-identical to the pre-smoothing mesh).
			var wall_top := h if topmods[lz * n + lx] != 0 else h + 1
			for dir in dirs:
				var nh: int = hmap[(lz + 1 + dir.dz) * stride + (lx + 1 + dir.dx)]
				if nh >= h:
					continue
				# Wall covers cells y in [nh+1 .. h] on this (taller) column's face.
				# Split into contiguous same-id vertical segments so the wall bands.
				var seg_start := nh + 1
				var seg_id := _cell_id(world, wx, seg_start, wz)
				var y := nh + 2
				while y <= h:
					var cid := _cell_id(world, wx, y, wz)
					if cid != seg_id:
						if seg_id != BlockCatalog.AIR and seg_start < wall_top:
							_wall(_tool_for(tools, seg_id), dir.nrm, lx, lz, x0, z0, seg_start, mini(y, wall_top))
						seg_start = y
						seg_id = cid
					y += 1
				if seg_id != BlockCatalog.AIR and seg_start < wall_top:
					_wall(_tool_for(tools, seg_id), dir.nrm, lx, lz, x0, z0, seg_start, wall_top)

# --- smoothed terrain: ShapeMesh geometry for shaped surface + cap cells ----------
# P5b-2 worldgen smoothing (SVS §8.1) reshapes the surface cell of a land column and, on
# a rising neighbour, grows a one-cell grass cap above it. Both are GENERATED shaped
# cells (not player-placed), so they emit through the same shared ShapeMesh seam the
# placed ramps use — "two render paths, one behaviour". The surface cell is at the column
# top (effective_height); the cap sits one above. Full-cube columns emit nothing here.
static func _emit_terrain_shapes(tools: Dictionary, world: WorldManager,
		hmap: PackedInt32Array, stride: int, n: int, x0: int, z0: int) -> void:
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			var wx := x0 + lx
			var wz := z0 + lz
			# Surface cell (y = h): a smoothing-shaped top emits ShapeMesh geometry.
			var vs: int = world.cell_value_at(Vector3i(wx, h, wz))
			var ms: int = CellCodec.modifier(vs)
			if ms != 0 and BlockCatalog.solidity_of(CellCodec.mat(vs)) >= 0.5:
				_emit_shaped(tools, Vector3i(wx, h, wz), CellCodec.mat(vs), ms)
			# Cap cell (y = h+1): a partial grass lip above the surface on a rising
			# neighbour (generated, not placed — placed cells are handled by _emit_placed).
			var vc: int = world.cell_value_at(Vector3i(wx, h + 1, wz))
			var mc: int = CellCodec.modifier(vc)
			if mc != 0 and BlockCatalog.solidity_of(CellCodec.mat(vc)) >= 0.5:
				_emit_shaped(tools, Vector3i(wx, h + 1, wz), CellCodec.mat(vc), mc)

# --- trees: cubes for genuine tree cells overlapping the chunk ------------------
static func _emit_trees(tools: Dictionary, world: WorldManager,
		n: int, x0: int, z0: int) -> void:
	var g := TreeGen.G
	var gx0 := floori(float(x0) / float(g)) - 1
	var gx1 := floori(float(x0 + n - 1) / float(g)) + 1
	var gz0 := floori(float(z0) / float(g)) - 1
	var gz1 := floori(float(z0 + n - 1) / float(g)) + 1
	var gzc := gz0
	while gzc <= gz1:
		var gxc := gx0
		while gxc <= gx1:
			if TreeGen.has_tree(gxc, gzc):
				_emit_one_tree(tools, world, gxc, gzc, n, x0, z0)
			gxc += 1
		gzc += 1

static func _emit_one_tree(tools: Dictionary, world: WorldManager,
		gx: int, gz: int, n: int, x0: int, z0: int) -> void:
	var base := TreeGen.tree_base(gx, gz)
	var bx := base.x
	var bz := base.z
	var gy := base.y
	# The tree occupies a 3x3 column footprint, y in [gy+1 .. gy+MAX_ABOVE_SURFACE].
	var dz := -1
	while dz <= 1:
		var dx := -1
		while dx <= 1:
			var cx := bx + dx
			var cz := bz + dz
			if cx >= x0 and cx < x0 + n and cz >= z0 and cz < z0 + n:
				var y := gy + 1
				var y_top := gy + TreeGen.MAX_ABOVE_SURFACE
				while y <= y_top:
					var tid := TreeGen.block_at(cx, y, cz)
					# Genuine cell: raw tree id present AND the composed world query
					# agrees (not buried under a hill, not chopped away by an edit).
					if tid != BlockCatalog.AIR and world.block_id_at(Vector3i(cx, y, cz)) == tid:
						_emit_cube(tools, world, Vector3i(cx, y, cz), tid)
					y += 1
			dx += 1
		dz += 1

# --- placed blocks: cubes for player-placed edit cells inside the chunk ---------
static func _emit_placed(tools: Dictionary, world: WorldManager,
		n: int, x0: int, z0: int) -> void:
	for cell: Vector3i in world.placed_cells().keys():
		# placed_cells() values are PACKED cell values. A full cube (modifier 0) emits
		# the culled cube faces as before; a shaped placed cell (ramp/slab, SVS §4.2)
		# emits its partial geometry from the shared ShapeMesh instead.
		var packed: int = world.placed_cells()[cell]
		var id: int = CellCodec.mat(packed)
		if id <= BlockCatalog.AIR:
			continue
		if cell.x < x0 or cell.x >= x0 + n or cell.z < z0 or cell.z >= z0 + n:
			continue
		var modifier: int = CellCodec.modifier(packed)
		if modifier == 0:
			_emit_cube(tools, world, cell, id)
		else:
			_emit_shaped(tools, cell, id, modifier)

# --- cube emission: faces of `cell` (id) not occluded by the 6-neighbour ---------
# A face is culled iff the neighbour OCCLUDES it per the transparency-index rule
# (WGC §5.2, WorldManager.occludes_face) — the single owner mirrored from the module
# path. For the current all-opaque world this reduces to `cell_solid(neighbour)`
# (byte-identical), and it also does the right thing for a placed glass/water block:
# the shared face between a solid and a MORE-transparent neighbour is NOT culled, so
# you see the solid through the pane and translucent-behind-translucent culls once.
static func _emit_cube(tools: Dictionary, world: WorldManager, cell: Vector3i, id: int) -> void:
	var my_group: int = BlockCatalog.transparency_index_of(id)
	for f in _CUBE_FACES:
		var nrm: Vector3i = f["n"]
		if WorldManager.occludes_face(world.cell_value_at(cell + nrm), my_group):
			continue
		var b := Vector3(cell)
		_quad(_tool_for(tools, id), Vector3(nrm),
			b + (f["a"] as Vector3), b + (f["b"] as Vector3),
			b + (f["c"] as Vector3), b + (f["d"] as Vector3),
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))

# --- shaped (partial) placed cell: emit the shared ShapeMesh geometry -------------
# The ONE render seam (SVS §4): both paths consume ShapeMesh.build, so a placed ramp/
# slab looks identical on the module and fallback paths. We emit the full unit-cell
# shape geometry (surface tris + anchor face + side trapezoids) translated to the cell,
# without inter-cell face culling — the hidden interior overdraw is cosmetically
# invisible and gameplay never reads geometry (rule 2). Only PLACED cells can be shaped
# in P5b-1 (worldgen still emits full cubes), so this touches the placed pass only.
static func _emit_shaped(tools: Dictionary, cell: Vector3i, id: int, modifier: int) -> void:
	var geom := ShapeMesh.build(modifier)
	var verts: PackedVector3Array = geom["verts"]
	var normals: PackedVector3Array = geom["normals"]
	var uvs: PackedVector2Array = geom["uvs"]
	var indices: PackedInt32Array = geom["indices"]
	var st := _tool_for(tools, id)
	var base := Vector3(cell)
	for i in indices:
		st.set_normal(normals[i])
		st.set_uv(uvs[i])
		st.add_vertex(base + verts[i])

# The 6 cube faces: outward normal + 4 corner offsets (winding is irrelevant —
# the materials are double-sided/unshaded).
const _CUBE_FACES := [
	{"n": Vector3i(1, 0, 0), "a": Vector3(1, 0, 0), "b": Vector3(1, 1, 0), "c": Vector3(1, 1, 1), "d": Vector3(1, 0, 1)},
	{"n": Vector3i(-1, 0, 0), "a": Vector3(0, 0, 1), "b": Vector3(0, 1, 1), "c": Vector3(0, 1, 0), "d": Vector3(0, 0, 0)},
	{"n": Vector3i(0, 1, 0), "a": Vector3(0, 1, 0), "b": Vector3(1, 1, 0), "c": Vector3(1, 1, 1), "d": Vector3(0, 1, 1)},
	{"n": Vector3i(0, -1, 0), "a": Vector3(0, 0, 0), "b": Vector3(0, 0, 1), "c": Vector3(1, 0, 1), "d": Vector3(1, 0, 0)},
	{"n": Vector3i(0, 0, 1), "a": Vector3(0, 0, 1), "b": Vector3(1, 0, 1), "c": Vector3(1, 1, 1), "d": Vector3(0, 1, 1)},
	{"n": Vector3i(0, 0, -1), "a": Vector3(0, 0, 0), "b": Vector3(0, 1, 0), "c": Vector3(1, 1, 0), "d": Vector3(1, 0, 0)},
]

# --- helpers -------------------------------------------------------------------

## Composed block id at (x, y, z); grass fallback when there is no world.
static func _cell_id(world: WorldManager, x: int, y: int, z: int) -> int:
	if world == null:
		return BlockCatalog.GRASS
	return world.block_id_at(Vector3i(x, y, z))

## Lazily begin (once) and return the SurfaceTool for block id `id`.
static func _tool_for(tools: Dictionary, id: int) -> SurfaceTool:
	var st: SurfaceTool = tools.get(id, null)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools[id] = st
	return st

static func _wall(st: SurfaceTool, nrm: Vector3,
		lx: int, lz: int, x0: int, z0: int, y_bottom: int, y_top: int) -> void:
	var yb := float(y_bottom)
	var yt := float(y_top)
	var cx := float(x0 + lx)
	var cz := float(z0 + lz)
	var a: Vector3
	var b: Vector3
	if nrm.x > 0:
		a = Vector3(cx + 1, 0, cz); b = Vector3(cx + 1, 0, cz + 1)
	elif nrm.x < 0:
		a = Vector3(cx, 0, cz + 1); b = Vector3(cx, 0, cz)
	elif nrm.z > 0:
		a = Vector3(cx + 1, 0, cz + 1); b = Vector3(cx, 0, cz + 1)
	else:
		a = Vector3(cx, 0, cz); b = Vector3(cx + 1, 0, cz)
	_quad(st, nrm,
		Vector3(a.x, yb, a.z), Vector3(b.x, yb, b.z),
		Vector3(b.x, yt, b.z), Vector3(a.x, yt, a.z),
		Vector2(0, yb), Vector2(1, yb), Vector2(1, yt), Vector2(0, yt))

## Emit a quad (two tris) into the SurfaceTool.
static func _quad(st: SurfaceTool, nrm: Vector3,
		v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		u0: Vector2, u1: Vector2, u2: Vector2, u3: Vector2) -> void:
	st.set_normal(nrm); st.set_uv(u0); st.add_vertex(v0)
	st.set_normal(nrm); st.set_uv(u1); st.add_vertex(v1)
	st.set_normal(nrm); st.set_uv(u2); st.add_vertex(v2)
	st.set_normal(nrm); st.set_uv(u0); st.add_vertex(v0)
	st.set_normal(nrm); st.set_uv(u2); st.add_vertex(v2)
	st.set_normal(nrm); st.set_uv(u3); st.add_vertex(v3)
