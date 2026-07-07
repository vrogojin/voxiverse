class_name FarMeshBuilder
extends RefCounted
## Pure static builder for one far-field heightmap tile (LOD-DESIGN §1.3, §2).
##
## A tile is a world-anchored square grid of lattice points; each vertex height is
## the render surface r(x,z) of LOD-DESIGN §2.2 (the voxel walk surface biased down,
## clamped up over open water), sampled by ONE TerrainConfig.column_profile call per
## point — so the far silhouette equals the near voxel surface at every lattice point
## by construction (LOD-DESIGN §3.1). Vertices carry a FarPalette colour and Ulrich
## skirts (LOD-DESIGN §1.4) hide inter-ring cracks. An all-sea tile collapses to a
## single flat quad (LOD-DESIGN §2.5).
##
## No scene access, no randi/Time — fully headless-testable and byte-identical for a
## given (ring, tile_coord, SEED) (LOD-DESIGN §2.7). The expensive part (profiling) is
## `sample_step`, sliceable under a per-frame budget; `assemble` (normals + indices) is
## cheap and runs once when sampling completes.

## The one composite render height r(x,z) of LOD-DESIGN §2.2 plus its column scalars,
## returned as {r, g, biome, t, clamped}. `clamped` == the vertex was pulled up to the
## sea surface (an open-water vertex → the sea palette).
static func sample_point(wx: int, wz: int) -> Dictionary:
	# Route through the shared main-thread analytic memo (PERF): the far mesh samples many columns per
	# frame; in curved mode an uncached column_profile recomputes the full _curved_profile each one. In
	# flat mode analytic_column_profile is the plain column_profile (byte-identical to before).
	var p := TerrainConfig.analytic_column_profile(wx, wz)
	var g := int(p.x)
	var biome := int(p.y)
	var t := p.w
	var land := float(g) + 1.0 - FarTerrain.BIAS_LAND
	var clamped := false
	var r := land
	if g < TerrainConfig.SEA_LEVEL:
		var sea_y := _sea_y()
		if land < sea_y:
			r = sea_y
			clamped = true
	return {"r": r, "g": g, "biome": biome, "t": t, "clamped": clamped}

## The far sea surface height (LOD-DESIGN §2.2): SEA_LEVEL + WATER_SURFACE_HEIGHT − BIAS_SEA.
static func _sea_y() -> float:
	return float(TerrainConfig.SEA_LEVEL) + TerrainConfig.WATER_SURFACE_HEIGHT - FarTerrain.BIAS_SEA

# ------------------------------------------------------------------------------
# Sliceable sampling job (LOD-DESIGN §2.6).

## Start sampling tile `tc` of `ring`: allocate the padded height lattice + interior
## colour lattice and a column cursor. Does NO profiling yet — `sample_step` does the work.
static func begin_tile(ring: int, tc: Vector2i) -> Dictionary:
	var rd: Dictionary = FarTerrain.RING_TABLE[ring]
	var grid := int(rd["grid"])
	var cell := float(rd["cell_m"])
	var tile := float(rd["tile_m"])
	var side := grid + 1                       # interior lattice points per edge
	var ext := grid + 3                        # padded lattice (one ring per edge for normals)
	var origin := Vector2(float(tc.x) * tile, float(tc.y) * tile)
	var heights := PackedFloat32Array()
	heights.resize(ext * ext)
	var colors := PackedColorArray()
	colors.resize(side * side)
	return {
		"ring": ring, "tc": tc, "grid": grid, "cell": cell, "tile": tile,
		"side": side, "ext": ext, "origin": origin,
		"heights": heights, "colors": colors,
		"cursor": 0, "total": ext * ext,
		"all_sea": true, "sea_y": _sea_y(),
	}

## Sample up to `max_cols` padded-lattice columns of `job`. Returns true once the whole
## tile has been sampled (LOD-DESIGN §2.6: ≤ 1,024-column slices keep any tile inside the
## per-frame budget). Idempotent after completion.
static func sample_step(job: Dictionary, max_cols: int) -> bool:
	var cursor := int(job["cursor"])
	var total := int(job["total"])
	if cursor >= total:
		return true
	var ext := int(job["ext"])
	var grid := int(job["grid"])
	var side := int(job["side"])
	var cell := float(job["cell"])
	var origin: Vector2 = job["origin"]
	var heights: PackedFloat32Array = job["heights"]
	var colors: PackedColorArray = job["colors"]
	var all_sea := bool(job["all_sea"])
	var end := mini(cursor + max_cols, total)
	for k in range(cursor, end):
		var ei := k / ext                       # 0..ext-1  → lattice i = ei-1 (−1..grid+1)
		var ej := k % ext
		var i := ei - 1
		var j := ej - 1
		var wx := int(origin.x) + i * int(cell)
		var wz := int(origin.y) + j * int(cell)
		var s := sample_point(wx, wz)
		heights[k] = float(s["r"])
		if i >= 0 and i <= grid and j >= 0 and j <= grid:
			colors[i * side + j] = FarPalette.color_for(
				int(s["g"]), int(s["biome"]), float(s["t"]), bool(s["clamped"]))
			if not bool(s["clamped"]):
				all_sea = false
	job["cursor"] = end
	job["all_sea"] = all_sea
	return end >= total

## Assemble the sampled `job` into raw mesh arrays (LOD-DESIGN §1.3): interior grid +
## central-difference normals + FarPalette colours + straight-down skirts, OR — when
## every interior vertex is a clamped sea vertex — the single flat quad of the open-ocean
## collapse (LOD-DESIGN §2.5). Cheap: no profiling, only index/normal math.
static func assemble(job: Dictionary) -> Dictionary:
	var grid := int(job["grid"])
	var cell := float(job["cell"])
	var side := int(job["side"])
	var ext := int(job["ext"])
	var origin: Vector2 = job["origin"]
	var tile := float(job["tile"])
	var heights: PackedFloat32Array = job["heights"]
	var colors: PackedColorArray = job["colors"]
	var sea_y := float(job["sea_y"])

	# Open-ocean collapse: an all-sea tile is one coplanar quad (LOD-DESIGN §2.5).
	if bool(job["all_sea"]):
		return _collapsed_quad(origin, tile, sea_y, colors, side, grid)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var vcolors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(side * side)
	normals.resize(side * side)
	vcolors.resize(side * side)

	# Interior grid vertices + central-difference normals.
	for i in range(0, grid + 1):
		for j in range(0, grid + 1):
			var vi := i * side + j
			var h := heights[_ext_at(ext, i, j)]
			verts[vi] = Vector3(origin.x + float(i) * cell, h, origin.y + float(j) * cell)
			var dhx := heights[_ext_at(ext, i - 1, j)] - heights[_ext_at(ext, i + 1, j)]
			var dhz := heights[_ext_at(ext, i, j - 1)] - heights[_ext_at(ext, i, j + 1)]
			normals[vi] = Vector3(dhx, 2.0 * cell, dhz).normalized()
			vcolors[vi] = colors[vi]

	# Top-surface triangles wound so the front face points UP (+Y). The original order faced DOWN, so
	# the surface was back-face-culled and only the vertical skirts rendered ("grid of vertical bars");
	# with culling off it showed its underside ("terrain rendered from underground"). Reversed here so
	# it is viewed correctly from above, with CULL_BACK restored on the material.
	for i in range(0, grid):
		for j in range(0, grid):
			var v00 := i * side + j
			var v01 := i * side + (j + 1)
			var v11 := (i + 1) * side + (j + 1)
			var v10 := (i + 1) * side + j
			indices.append_array([v00, v11, v01, v00, v10, v11])

	# Skirts: extrude every tile edge straight down (LOD-DESIGN §1.4). Skirt vertices copy
	# their top vertex's normal + colour (no dark walls). Per-edge (non-deduplicated) so the
	# vertex count is exactly grid²+... ≤ the 16-bit / 4,485-vertex pin. Skirt quads are
	# DOUBLE-SIDED (both windings): the player sits at the ring centre, so at a boundary the
	# covering skirt must be seen whether distant terrain RISES away from the player or falls
	# toward it — no single winding covers both, so a one-sided skirt leaks sky on every rising
	# ridge (LOD-DESIGN §1.4). Only the thin skirt walls are doubled, keeping the top surface
	# single-sided CULL_BACK — no whole-surface overdraw, no extra draw call.
	var skirt_depth := float(FarTerrain.SKIRT_CELLS) * cell
	# min-x, max-x, min-z, max-z edges (each skirt quad is emitted double-sided — see _wall_quad).
	_add_skirt(verts, normals, vcolors, indices, side, skirt_depth,
		_border_indices(side, grid, 0))     # min-x (i=0, j varies)
	_add_skirt(verts, normals, vcolors, indices, side, skirt_depth,
		_border_indices(side, grid, 1))     # max-x (i=grid)
	_add_skirt(verts, normals, vcolors, indices, side, skirt_depth,
		_border_indices(side, grid, 2))     # min-z (j=0)
	_add_skirt(verts, normals, vcolors, indices, side, skirt_depth,
		_border_indices(side, grid, 3))     # max-z (j=grid)

	return {
		"verts": verts, "normals": normals, "colors": vcolors, "indices": indices,
		"tri_count": indices.size() / 3, "grid": grid, "cell": cell,
		"origin": origin, "collapsed": false,
	}

## Full build (sample everything + assemble) — used by verify and any non-budgeted caller.
static func build_arrays(ring: int, tc: Vector2i) -> Dictionary:
	var job := begin_tile(ring, tc)
	while not sample_step(job, 1 << 20):
		pass
	return assemble(job)

## Wrap raw arrays into an ArrayMesh with the shared far material on surface 0.
static func build_mesh(arrays: Dictionary, material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var surf := []
	surf.resize(Mesh.ARRAY_MAX)
	surf[Mesh.ARRAY_VERTEX] = arrays["verts"]
	surf[Mesh.ARRAY_NORMAL] = arrays["normals"]
	surf[Mesh.ARRAY_COLOR] = arrays["colors"]
	surf[Mesh.ARRAY_INDEX] = arrays["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)
	if material != null and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material)
	return mesh

# ------------------------------------------------------------------------------
# Internals.

static func _ext_at(ext: int, i: int, j: int) -> int:
	return (i + 1) * ext + (j + 1)

## The (grid+1) interior vertex indices along one border edge, ordered by the varying
## axis. `edge`: 0 min-x, 1 max-x, 2 min-z, 3 max-z.
static func _border_indices(side: int, grid: int, edge: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	match edge:
		0:                                       # i = 0, j = 0..grid
			for j in range(0, grid + 1):
				out.append(0 * side + j)
		1:                                       # i = grid
			for j in range(0, grid + 1):
				out.append(grid * side + j)
		2:                                       # j = 0, i = 0..grid
			for i in range(0, grid + 1):
				out.append(i * side + 0)
		3:                                       # j = grid
			for i in range(0, grid + 1):
				out.append(i * side + grid)
	return out

## Extrude one border edge downward and stitch the double-sided wall.
static func _add_skirt(verts: PackedVector3Array, normals: PackedVector3Array,
		vcolors: PackedColorArray, indices: PackedInt32Array, _side: int,
		depth: float, border: PackedInt32Array) -> void:
	var n := border.size()
	if n < 2:
		return
	var skirt := PackedInt32Array()
	skirt.resize(n)
	for k in range(n):
		var top := border[k]
		var si := verts.size()
		verts.append(verts[top] - Vector3(0, depth, 0))
		normals.append(normals[top])            # copy edge normal → lit like the surface
		vcolors.append(vcolors[top])
		skirt[k] = si
	for k in range(n - 1):
		_wall_quad(indices, border[k], border[k + 1], skirt[k + 1], skirt[k])

## The wall quad (top a→b, bottom under b→under a) emitted DOUBLE-SIDED — both triangle
## windings. Winding is intentionally NOT chosen: a centre viewer must see the covering skirt
## on both rising boundaries (the ring's own edge faces away) and falling ones (it faces
## toward), which no single winding achieves; emitting both is the robust crack seal
## (LOD-DESIGN §1.4). It costs 4 skirt tris/quad instead of 2, doubling only the thin skirt
## walls (~6% of a tile's tris) — far cheaper than a CULL_DISABLED material, which would either
## overdraw the whole top surface or split the tile into a second draw call.
static func _wall_quad(indices: PackedInt32Array,
		ta: int, tb: int, sb: int, sa: int) -> void:
	indices.append_array([
		ta, tb, sb, ta, sb, sa,                 # front winding
		ta, sb, tb, ta, sa, sb,                 # back winding
	])

## The open-ocean collapse quad (LOD-DESIGN §2.5): 4 verts, 2 tris, +Y normals, corner
## colours preserved so an ice/lava/water regime boundary across the tile still shows.
static func _collapsed_quad(origin: Vector2, tile: float, sea_y: float,
		colors: PackedColorArray, side: int, grid: int) -> Dictionary:
	var verts := PackedVector3Array([
		Vector3(origin.x, sea_y, origin.y),
		Vector3(origin.x, sea_y, origin.y + tile),
		Vector3(origin.x + tile, sea_y, origin.y + tile),
		Vector3(origin.x + tile, sea_y, origin.y),
	])
	var up := Vector3(0, 1, 0)
	var normals := PackedVector3Array([up, up, up, up])
	var vcolors := PackedColorArray([
		colors[0 * side + 0],
		colors[0 * side + grid],
		colors[grid * side + grid],
		colors[grid * side + 0],
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	return {
		"verts": verts, "normals": normals, "colors": vcolors, "indices": indices,
		"tri_count": 2, "grid": grid, "cell": 0.0, "origin": origin, "collapsed": true,
	}
