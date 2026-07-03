class_name ChunkMesher
extends RefCounted
## Pure-GDScript greedy mesher for one heightmap chunk (grass surface).
##
## The world is a heightmap (no overhangs), so we build the visible surface
## directly instead of marching solid/air:
##   * TOP faces are greedy-merged by height — adjacent columns of equal height
##     collapse into one quad.
##   * SIDE faces are emitted per column where a neighbour is lower; exactly one
##     wall is emitted per step (only the taller column emits) → no doubles.
##
## The surface is uniformly grass (SurfaceModel ships one state), so there is a
## single material. `world` supplies EFFECTIVE column heights (noise heightmap
## minus blocks the player has broken from the top), so a dug column drops by one
## — the fallback renders vertical digging correctly. (Arbitrary mid-column
## removals only show in the godot_voxel path, which is the live one; the fallback
## is the safety net.) Cell (x,y,z) spans [x,x+1]³ and is solid when y <=
## height_at; the walkable surface plane is y = height_at + 1. UVs are world
## metres (1 tile / voxel).

## Build an ArrayMesh (grass surface) for chunk (cx, cz).
static func build(cx: int, cz: int, grass_mat: Material, world: WorldManager = null) -> ArrayMesh:
	var n := TerrainConfig.CHUNK_SIZE
	var x0 := cx * n
	var z0 := cz * n
	var stride := n + 2

	# Heights incl. a 1-cell border (for edge side faces).
	var hmap := PackedInt32Array()
	hmap.resize(stride * stride)
	for lz in stride:
		for lx in stride:
			var wx := x0 + lx - 1
			var wz := z0 + lz - 1
			hmap[lz * stride + lx] = world.effective_height(wx, wz) if world != null \
				else TerrainConfig.height_at(wx, wz)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := _emit_tops(st, hmap, stride, n, x0, z0)
	count += _emit_sides(st, hmap, stride, n, x0, z0)

	if count == 0:
		return null
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(mesh.get_surface_count() - 1, grass_mat)
	return mesh

# --- top faces: greedy 2D merge over equal height ------------------------------
static func _emit_tops(st: SurfaceTool, hmap: PackedInt32Array,
		stride: int, n: int, x0: int, z0: int) -> int:
	var count := 0
	var used := PackedByteArray()
	used.resize(n * n)
	for lz in n:
		for lx in n:
			if used[lz * n + lx]:
				continue
			var h := hmap[(lz + 1) * stride + (lx + 1)]

			var w := 1
			while lx + w < n and not used[lz * n + lx + w] \
					and hmap[(lz + 1) * stride + (lx + 1 + w)] == h:
				w += 1

			var d := 1
			var can_grow := true
			while lz + d < n and can_grow:
				for k in w:
					if used[(lz + d) * n + lx + k] \
							or hmap[(lz + 1 + d) * stride + (lx + 1 + k)] != h:
						can_grow = false
						break
				if can_grow:
					d += 1

			for dz in d:
				for dx in w:
					used[(lz + dz) * n + lx + dx] = 1

			var y := float(h + 1)
			var wx0 := float(x0 + lx)
			var wz0 := float(z0 + lz)
			var wx1 := wx0 + w
			var wz1 := wz0 + d
			_quad(st, Vector3.UP,
				Vector3(wx0, y, wz0), Vector3(wx0, y, wz1),
				Vector3(wx1, y, wz1), Vector3(wx1, y, wz0),
				Vector2(wx0, wz0), Vector2(wx0, wz1),
				Vector2(wx1, wz1), Vector2(wx1, wz0))
			count += 6
	return count

# --- side faces: one grass wall per downward step ------------------------------
static func _emit_sides(st: SurfaceTool, hmap: PackedInt32Array,
		stride: int, n: int, x0: int, z0: int) -> int:
	var count := 0
	var dirs := [
		{"dx": 1, "dz": 0, "nrm": Vector3(1, 0, 0)},
		{"dx": -1, "dz": 0, "nrm": Vector3(-1, 0, 0)},
		{"dx": 0, "dz": 1, "nrm": Vector3(0, 0, 1)},
		{"dx": 0, "dz": -1, "nrm": Vector3(0, 0, -1)},
	]
	for lz in n:
		for lx in n:
			var h := hmap[(lz + 1) * stride + (lx + 1)]
			for dir in dirs:
				var nh: int = hmap[(lz + 1 + dir.dz) * stride + (lx + 1 + dir.dx)]
				if nh >= h:
					continue
				count += _wall(st, dir.nrm, lx, lz, x0, z0, nh + 1, h + 1)
	return count

static func _wall(st: SurfaceTool, nrm: Vector3,
		lx: int, lz: int, x0: int, z0: int, y_bottom: int, y_top: int) -> int:
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
	return 6

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
