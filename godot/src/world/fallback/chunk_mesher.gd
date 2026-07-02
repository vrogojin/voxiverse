class_name ChunkMesher
extends RefCounted
## Pure-GDScript greedy mesher for one heightmap chunk.
##
## The world is a heightmap (no overhangs), so we do not volumetrically march
## solid/air. Instead we build the visible surface directly:
##   * TOP faces are greedy-merged: adjacent columns of equal height collapse
##     into a single quad (large plateaus become one rectangle), which is what
##     makes a 256-block radius affordable in GDScript.
##   * SIDE faces are emitted per column only where a neighbour column is lower,
##     forming the vertical "cliff" walls between height steps. Exactly one wall
##     is emitted per step (only the taller column emits), so no double faces.
##
## Cell (x,y,z) spans the unit cube [x,x+1]x[y,y+1]x[z,z+1] and is solid when
## y <= height_at(x,z). The topmost solid cell is y = height_at, so the walkable
## surface plane is y = height_at + 1. UVs are in world metres (1 tile / voxel).

## Build and return an ArrayMesh for the chunk at (cx, cz), or null if empty.
static func build(cx: int, cz: int, material: Material) -> ArrayMesh:
	var n := TerrainConfig.CHUNK_SIZE
	var x0 := cx * n
	var z0 := cz * n

	# Sample heights for the chunk plus a 1-cell border (for edge side faces).
	# hmap is (n+2) x (n+2); local (lx,lz) maps to world (x0+lx-1, z0+lz-1).
	var stride := n + 2
	var hmap := PackedInt32Array()
	hmap.resize(stride * stride)
	for lz in stride:
		for lx in stride:
			hmap[lz * stride + lx] = TerrainConfig.height_at(x0 + lx - 1, z0 + lz - 1)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	_emit_tops(st, hmap, stride, n, x0, z0)
	_emit_sides(st, hmap, stride, n, x0, z0)

	var mesh := st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	mesh.surface_set_material(0, material)
	return mesh

# --- top faces: greedy 2D rectangle merge over equal heights --------------------
static func _emit_tops(st: SurfaceTool, hmap: PackedInt32Array, stride: int,
		n: int, x0: int, z0: int) -> void:
	var used := PackedByteArray()
	used.resize(n * n)  # interior cells only (local 0..n-1 -> hmap index +1)

	for lz in n:
		for lx in n:
			if used[lz * n + lx]:
				continue
			var h := hmap[(lz + 1) * stride + (lx + 1)]

			# Grow width along +x while height matches and unused.
			var w := 1
			while lx + w < n \
					and not used[lz * n + lx + w] \
					and hmap[(lz + 1) * stride + (lx + 1 + w)] == h:
				w += 1

			# Grow depth along +z while the whole [lx, lx+w) row matches.
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

			# Quad corners in world space, top plane at y = h + 1.
			var y := float(h + 1)
			var wx0 := float(x0 + lx)
			var wz0 := float(z0 + lz)
			var wx1 := wx0 + w
			var wz1 := wz0 + d
			# CCW as seen from above (+Y). Double-sided material tolerates either.
			_quad(st, Vector3.UP,
				Vector3(wx0, y, wz0),
				Vector3(wx0, y, wz1),
				Vector3(wx1, y, wz1),
				Vector3(wx1, y, wz0),
				Vector2(wx0, wz0), Vector2(wx0, wz1),
				Vector2(wx1, wz1), Vector2(wx1, wz0))

# --- side faces: one vertical wall per exposed step -----------------------------
static func _emit_sides(st: SurfaceTool, hmap: PackedInt32Array, stride: int,
		n: int, x0: int, z0: int) -> void:
	# Neighbour offsets: +x, -x, +z, -z with their outward normals.
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
					continue  # neighbour is level or taller: no wall here
				_emit_wall(st, dir.nrm, lx, lz, x0, z0, nh + 1, h + 1)

## One vertical quad on the face of column (lx,lz) between world y=[y_bottom,y_top].
static func _emit_wall(st: SurfaceTool, nrm: Vector3, lx: int, lz: int,
		x0: int, z0: int, y_bottom: int, y_top: int) -> void:
	var yb := float(y_bottom)
	var yt := float(y_top)
	var cx := float(x0 + lx)
	var cz := float(z0 + lz)
	# The four corners of the cell's footprint edge that faces `nrm`.
	var a: Vector3
	var b: Vector3
	if nrm.x > 0:            # +x face, at x = cx+1
		a = Vector3(cx + 1, 0, cz)
		b = Vector3(cx + 1, 0, cz + 1)
	elif nrm.x < 0:         # -x face, at x = cx
		a = Vector3(cx, 0, cz + 1)
		b = Vector3(cx, 0, cz)
	elif nrm.z > 0:         # +z face, at z = cz+1
		a = Vector3(cx + 1, 0, cz + 1)
		b = Vector3(cx, 0, cz + 1)
	else:                    # -z face, at z = cz
		a = Vector3(cx, 0, cz)
		b = Vector3(cx + 1, 0, cz)
	# UVs in metres: horizontal run along the wall, vertical = world y.
	var run := 1.0
	_quad(st, nrm,
		Vector3(a.x, yb, a.z), Vector3(b.x, yb, b.z),
		Vector3(b.x, yt, b.z), Vector3(a.x, yt, a.z),
		Vector2(0, yb), Vector2(run, yb), Vector2(run, yt), Vector2(0, yt))

## Emit a quad as two triangles (v0,v1,v2)+(v0,v2,v3) with a shared normal.
static func _quad(st: SurfaceTool, nrm: Vector3,
		v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		u0: Vector2, u1: Vector2, u2: Vector2, u3: Vector2) -> void:
	st.set_normal(nrm); st.set_uv(u0); st.add_vertex(v0)
	st.set_normal(nrm); st.set_uv(u1); st.add_vertex(v1)
	st.set_normal(nrm); st.set_uv(u2); st.add_vertex(v2)
	st.set_normal(nrm); st.set_uv(u0); st.add_vertex(v0)
	st.set_normal(nrm); st.set_uv(u2); st.add_vertex(v2)
	st.set_normal(nrm); st.set_uv(u3); st.add_vertex(v3)
