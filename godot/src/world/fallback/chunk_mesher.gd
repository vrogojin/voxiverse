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
##   * WATER (WATER-SHORE §5.2): the sea/ice cells sit ABOVE the solid height and so
##     are invisible to the passes above. `_emit_water` draws the water LINE — one
##     horizontal 0.9-high quad per open-water OR shore-composite column — and the ice
##     cube for frozen sea. Underwater smoothed floor ramps need NO code here: they are
##     GENERATED shaped surface cells, so `_emit_terrain_shapes` (§5.1) already emits
##     them once worldgen carries the underwater surface modifier.
##
## WATER PARITY (WATER-SHORE §5.3): gameplay parity with the module path is exact by
## construction — both paths read the same `resolve_cell` output and the same physics
## queries (this pass reads block_id_at / cell_value_at only, never geometry). Visual
## parity for water is DELIBERATELY RELAXED on this safety-net path. Accepted gaps
## (documented fidelity class, not bugs): no vertical water SIDE faces where water meets
## air laterally (a dug channel wall shows no water pane); no underwater tint faces
## (level-10 submerged composites render terrain-only, as the module path also does).
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

	# Top LOOK KEY per interior column (greedy top merge key): the material id, or
	# `mat | _LOOK_SNOW_FLAG` for a snow-capped cell (M1 §5.4), so capped/bare tops never
	# merge and the commit binds the snow-variant material.
	var topids := PackedInt32Array()
	topids.resize(n * n)
	# Surface cell MODIFIER per interior column (0 = FULL). P5b-2 worldgen smoothing
	# reshapes the top cell of a land column: a non-zero modifier column renders as
	# ShapeMesh geometry (surface + any cap), NOT a flat quad, so it is excluded from the
	# greedy top merge and its side wall is capped at the cell floor so the slope shows.
	var topmods := PackedInt32Array()
	topmods.resize(n * n)
	# Columns whose h+1 cell is a solid SHAPED cell (e.g. a snow half-slab): its bottom face is
	# coincident with the flat surface top quad, so the top quad is skipped to kill z-fight (§6.4).
	var capshaped := PackedByteArray()
	capshaped.resize(n * n)
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			if world == null:
				topids[lz * n + lx] = BlockCatalog.GRASS
				topmods[lz * n + lx] = 0
				continue
			var vtop := world.cell_value_at(Vector3i(x0 + lx, h, z0 + lz))
			topids[lz * n + lx] = _look_of(vtop)
			topmods[lz * n + lx] = CellCodec.modifier(vtop)
			var vcap := world.cell_value_at(Vector3i(x0 + lx, h + 1, z0 + lz))
			# Only a cap whose BOTTOM face FULLY covers the footprint (a bottom-anchored slab, all
			# corners >= 1 — the snow half-slab, or a full-cover lip) may suppress the surface top
			# quad: its solid underside is coincident with that quad, so drawing both z-fights. A
			# PARTIAL/wedge lip (any 0 corner) or a top-anchored cap does NOT cover the whole floor,
			# so the surface top quad must stay or the exposed remainder becomes a hole (M1 §6.4).
			if BlockCatalog.solidity_of(CellCodec.mat(vcap)) >= 0.5 and ShapeCodec.bottom_face_covers(CellCodec.modifier(vcap)):
				capshaped[lz * n + lx] = 1

	# One SurfaceTool per LOOK KEY present (lazily begun on first face).
	var tools: Dictionary = {}   # int look key -> SurfaceTool
	_emit_tops(tools, hmap, topids, topmods, capshaped, stride, n, x0, z0)
	_emit_sides(tools, world, hmap, topmods, stride, n, x0, z0)
	if world != null:
		_emit_terrain_shapes(tools, world, hmap, stride, n, x0, z0)
		_emit_snow(tools, world, hmap, stride, n, x0, z0)
		_emit_trees(tools, world, n, x0, z0)
		_emit_placed(tools, world, n, x0, z0)
		_emit_water(tools, world, hmap, stride, n, x0, z0)

	if tools.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for id: int in tools.keys():
		var st: SurfaceTool = tools[id]
		st.commit(mesh)
		# A look key with the snow flag binds the snow-cap variant material (M1 §5.4).
		var surf_mat: Material = BlockMaterials.snow_capped_for(id & 0xFFFF) if (id & _LOOK_SNOW_FLAG) != 0 else BlockMaterials.get_for(id)
		mesh.surface_set_material(mesh.get_surface_count() - 1, surf_mat)
	if mesh.get_surface_count() == 0:
		return null
	return mesh

# --- top faces: greedy 2D merge over equal (height, top id) ---------------------
static func _emit_tops(tools: Dictionary, hmap: PackedInt32Array, topids: PackedInt32Array,
		topmods: PackedInt32Array, capshaped: PackedByteArray, stride: int, n: int, x0: int, z0: int) -> void:
	var used := PackedByteArray()
	used.resize(n * n)
	# A smoothing-shaped surface cell renders via _emit_terrain_shapes (ShapeMesh), not a
	# flat quad — mark it used so the greedy merge skips it and never floats a flat top
	# over a ramp (nor lets it break a flat run).
	# A shaped surface cell renders via _emit_terrain_shapes; a column with a solid shaped h+1
	# cell (snow slab) skips its top quad too (its coincident bottom face would z-fight, §6.4).
	for i in n * n:
		if topmods[i] != 0 or capshaped[i]:
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
				var seg_id := _look_id(world, wx, seg_start, wz)
				var y := nh + 2
				while y <= h:
					var cid := _look_id(world, wx, y, wz)
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
			# SHARP-SLOPE §4.3: a steep SLOPE column emits its whole vertical RUN [lo, hi−1] of shaped
			# cells (carve below h, caps above h+1), not just h/h+1. Rare buried full cells between the
			# heightmap top and the run start are emitted as cubes so the fallback stays hole-free.
			var run := TerrainConfig.slope_run_of(wx, wz)
			if TerrainConfig.slope_run_fires(run):
				var rng := TerrainConfig.slope_run_range(run, h)
				for yy in range(h + 1, rng.x):
					var vf: int = world.cell_value_at(Vector3i(wx, yy, wz))
					if CellCodec.modifier(vf) == 0 and BlockCatalog.solidity_of(CellCodec.mat(vf)) >= 0.5:
						_emit_shaped(tools, Vector3i(wx, yy, wz), _look_of(vf), 0)   # full cube
				for yy in range(rng.x, rng.y):
					var vv: int = world.cell_value_at(Vector3i(wx, yy, wz))
					var mm: int = CellCodec.modifier(vv)
					if mm != 0 and BlockCatalog.solidity_of(CellCodec.mat(vv)) >= 0.5:
						_emit_shaped(tools, Vector3i(wx, yy, wz), _look_of(vv), mm)
				continue
			# Surface cell (y = h): a smoothing-shaped top emits ShapeMesh geometry, and — SNOW-ACCUMULATION
			# §2.8 — a snow-FILLED ramp DUAL-EMITs the snow LAYER fill on top (the module's composite, sans
			# baking). Same (mat, state, modifier) projection on both paths. (A slope column has already
			# emitted its run and CONTINUEd, so snow-fill/cap never double up with the run.)
			var cs := Vector3i(wx, h, wz)
			var vs: int = world.cell_value_at(cs)
			var ms: int = CellCodec.modifier(vs)
			if ms != 0 and BlockCatalog.solidity_of(CellCodec.mat(vs)) >= 0.5:
				_emit_shaped(tools, cs, _look_of(vs), ms)
				_emit_snow_fill(tools, cs, CellCodec.snow_fill(vs))
			# Cap cell (y = h+1): a partial grass lip above the surface on a rising
			# neighbour (generated, not placed — placed cells are handled by _emit_placed).
			var cc := Vector3i(wx, h + 1, wz)
			var vc: int = world.cell_value_at(cc)
			var mc: int = CellCodec.modifier(vc)
			if mc != 0 and BlockCatalog.solidity_of(CellCodec.mat(vc)) >= 0.5:
				_emit_shaped(tools, cc, _look_of(vc), mc)
				_emit_snow_fill(tools, cc, CellCodec.snow_fill(vc))

# --- stacked snow: cubes + a top LAYER for the accumulated snow above the surface ---
# SNOW-ACCUMULATION §2.8. Like the sea/ice cells, the accumulated snow cells (SNOW-ACCUMULATION
# Decision 3) sit ABOVE the solid heightmap top, so they are invisible to _emit_tops/_emit_sides
# (which skin effective_height). This pass draws them: for each column it scans the bounded band
# above the surface top (h+1 .. h + SNOW_FILL_MAX_CELLS) and, for every generated snow_block cell,
# emits a culled CUBE (a full snow cell, modifier 0) or the shared ShapeMesh (a top LAYER / the level-5
# slab). It reads only the composed cell query (cell_value_at), so it derives from the same resolve_cell
# output as the module path (the §5.1 parity statement). The surface top quad's z-fight is already
# suppressed by the capshaped marking (bottom_face_covers(LAYER/cube) == true) in build().
static func _emit_snow(tools: Dictionary, world: WorldManager, hmap: PackedInt32Array,
		stride: int, n: int, x0: int, z0: int) -> void:
	var snow_id := BlockCatalog.id_of(&"snow_block")
	var max_up := TerrainConfig.SNOW_FILL_MAX_CELLS + 1
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			var wx := x0 + lx
			var wz := z0 + lz
			for dy in range(1, max_up + 1):
				var cell := Vector3i(wx, h + dy, wz)
				var v := world.cell_value_at(cell)
				if CellCodec.mat(v) != snow_id:
					continue                              # cap cell / air / handled elsewhere
				var modifier := CellCodec.modifier(v)
				if modifier == 0:
					_emit_cube(tools, world, cell, snow_id)   # a full snow cell (culled faces)
				else:
					_emit_shaped(tools, cell, _look_of(v), modifier)   # a top LAYER / slab

# --- snow FILL: the snow LAYER a filled ramp carries (SNOW-ACCUMULATION §2.8) ------
# A cold ramp surface/lip cell buries its remainder with a flat snow plane at `fill/10`. The fallback
# dual-emits it as a second ShapeMesh (snow_block LAYER) at the fill level — the fill plane rounds UP to
# the same curated {3,5,8,10} the module bakes, so BOTH paths show the snow at one height (parity). The
# snow's portion inside the opaque ramp is hidden interior overdraw (gameplay never reads geometry).
static func _emit_snow_fill(tools: Dictionary, cell: Vector3i, fill_level: int) -> void:
	if fill_level <= 0:
		return
	var rl := 3 if fill_level <= 3 else (5 if fill_level <= 5 else (8 if fill_level <= 8 else 10))
	# make_layer(10) == 0 → a full snow cube (the buried case); 5 → the half-slab; 3/8 → thin FAM slabs.
	_emit_shaped(tools, cell, BlockCatalog.id_of(&"snow_block"), CellCodec.make_layer(rl))

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
	# WINDOW-keyed overlay view (COSMOS M3 §4.3): in curved mode `placed_cells()` is GLOBAL-int-
	# keyed, so iterate the window projection instead (identical to `placed_cells()` in flat mode).
	var placed := world.placed_cells_window()
	for cell: Vector3i in placed.keys():
		# values are PACKED cell values. A full cube (modifier 0) emits the culled cube faces as
		# before; a shaped placed cell (ramp/slab, SVS §4.2) emits its partial geometry instead.
		var packed: int = placed[cell]
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

# --- water surface: one 0.9 quad per water/composite column; ice cube for frozen sea ---
# WATER-SHORE §5.2. The fallback is a heightmap skin over effective_height, so sea/ice
# cells (non-solid water sits ABOVE the solid height) are never touched by _emit_tops /
# _emit_sides. This pass draws the water LINE — one horizontal quad at SEA_LEVEL + 0.9
# per column that has water at the water line — plus the ice cap for frozen sea. It reads
# only the shared cell queries (block_id_at / cell_value_at), so it derives from exactly
# the same resolve_cell output as the module path (WATER-SHORE §5.3 parity statement).
static func _emit_water(tools: Dictionary, world: WorldManager, hmap: PackedInt32Array,
		stride: int, n: int, x0: int, z0: int) -> void:
	var sea := TerrainConfig.SEA_LEVEL
	var water_id := BlockCatalog.id_of(&"water")
	var ice_id := BlockCatalog.id_of(&"ice")
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			var wx := x0 + lx
			var wz := z0 + lz
			if h < sea:
				# Open water / submerged column: what sits at the water line?
				var id := world.block_id_at(Vector3i(wx, sea, wz))
				if BlockCatalog.liquid_kind_of(id) == CellCodec.LIQ_WATER:
					_water_top_quad(tools, water_id, wx, wz)      # the sunk 0.9 surface plane
				elif id == ice_id:
					_emit_cube(tools, world, Vector3i(wx, sea, wz), id)  # frozen sea cap
				# else: overlay projects a player-placed/dug cell (block_id_at wins) → emit
				# nothing, so a shaft dug below sea level stays dry.
			elif h == sea:
				# Potential shore composite: the surface cell (y == h == SEA_LEVEL) carries a
				# liquid(WATER, 9) overlay iff smoothed and non-frozen. Same plane as above.
				var v := world.cell_value_at(Vector3i(wx, h, wz))
				if CellCodec.liquid_level(v) == CellCodec.LIQ_LEVEL_SURFACE:
					_water_top_quad(tools, water_id, wx, wz)

## One horizontal water quad for column (wx, wz) at y = SEA_LEVEL + WATER_SURFACE_HEIGHT,
## world-planar UVs (matching _emit_tops). Continuous plane across cases 1 and 2 above.
static func _water_top_quad(tools: Dictionary, water_id: int, wx: int, wz: int) -> void:
	var y := float(TerrainConfig.SEA_LEVEL) + TerrainConfig.WATER_SURFACE_HEIGHT
	var wx0 := float(wx)
	var wz0 := float(wz)
	var wx1 := wx0 + 1.0
	var wz1 := wz0 + 1.0
	_quad(_tool_for(tools, water_id), Vector3.UP,
		Vector3(wx0, y, wz0), Vector3(wx0, y, wz1),
		Vector3(wx1, y, wz1), Vector3(wx1, y, wz0),
		Vector2(wx0, wz0), Vector2(wx0, wz1),
		Vector2(wx1, wz1), Vector2(wx1, wz0))

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

## Render LOOK-KEY flag (M1 ADR §5.4): bit 16 of a look key marks a SNOW-CAPPED variant. Distinct
## from the MATERIAL projection so capped/bare tops never greedy-merge and the commit binds the
## snow-variant material; AIR/solidity/physics keep reading the material — this key is render-local.
const _LOOK_SNOW_FLAG := 0x10000

## Render look key for a packed cell value: the material id, or `mat | _LOOK_SNOW_FLAG` when the
## cell carries the snow_capped state on a cappable material (state_mask_of != 0).
static func _look_of(v: int) -> int:
	var m := CellCodec.mat(v)
	if m != BlockCatalog.AIR and CellCodec.has_state(v, CellCodec.STATE_SNOW_CAPPED) \
			and BlockCatalog.state_mask_of(m) != 0:
		return m | _LOOK_SNOW_FLAG
	return m

## Composed LOOK KEY at (x, y, z); grass fallback when there is no world.
static func _look_id(world: WorldManager, x: int, y: int, z: int) -> int:
	if world == null:
		return BlockCatalog.GRASS
	return _look_of(world.cell_value_at(Vector3i(x, y, z)))

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
