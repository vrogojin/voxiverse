class_name FacetFarRing
extends Node3D
## COSMOS FP2 §5.2 — the planet rendered AROUND the active facet. Every non-active facet is drawn as a flat,
## low-res, terrain-coloured quad built from its PLANARIZED corners (the same f64 frames the near voxel world
## uses, so faces meet cleanly at the ridges — no wedge), given radial relief (FP0's seam-glue), then transformed
## into the ACTIVE facet's lattice frame via FacetAtlas.world_to_lattice64. The player, standing on the flat
## active facet, sees the faceted planet curve away at the seams. Render-only, collision-free, voxel-worker-free
## (like FarTerrain); STATIC — rebuilt only on an FP3 crossing. Replaces FarTerrain in faceted mode (WM._ready).

const ENABLED := true
const CELLS := 4                     # heightmap cells per facet edge (far LOD) — k=24 facets are small, so this
                                     # already reads smooth; keeps the whole-planet mesh within the web tri budget
const RELIEF := 1.0                  # blocks of radial relief per (g − SEA_LEVEL)
const BACK_CULL := 0.0               # front hemisphere only — back-side facets sit below the surface horizon
const CAMERA_FAR := 9000.0           # the planet spans ~2R; the player camera far must reach it in faceted mode
const FOG_BEGIN := 2200.0            # fog only far out, so the whole planet reads

var _active_fid := -1

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	add_child(_build())

func _build() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var k := FacetAtlas.K
	var nrm := FacetAtlas.facet_normal64(_active_fid)
	var tris := 0
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if fid == _active_fid:
					continue                          # the near voxel world already covers the active facet
				var cd := _facet_centre_dir(fid)
				if cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] < BACK_CULL:
					continue                          # back hemisphere → not visible from the active facet
				tris += _emit_facet(st, fid)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "FacetFarRingMesh"
	mi.mesh = st.commit()
	mi.material_override = _make_material()
	print("[FP2] facet far ring: %d triangles around facet %d" % [tris, _active_fid])
	return mi

func _emit_facet(st: SurfaceTool, fid: int) -> int:
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var stride := CELLS + 1
	var pos: Array = []
	var col: Array = []
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(CELLS)
			var t := float(gj) / float(CELLS)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			# radial relief (shared-seam vertices displace to the same point → peaks stay glued, FP0)
			var l := FacetAtlas.world_to_lattice64(_active_fid, bx + dx * relief, by + dy * relief, bz + dz * relief)
			pos.append(Vector3(l[0], l[1], l[2]))
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g <= TerrainConfig.SEA_LEVEL))
	var n := 0
	for gj in range(CELLS):
		for gi in range(CELLS):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			_tri(st, pos, col, i0, i2, i1)
			_tri(st, pos, col, i1, i2, i3)
			n += 2
	return n

func _facet_centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _tri(st: SurfaceTool, pos: Array, col: Array, i: int, j: int, k: int) -> void:
	st.set_color(col[i]); st.add_vertex(pos[i])
	st.set_color(col[j]); st.add_vertex(pos[j])
	st.set_color(col[k]); st.add_vertex(pos[k])

func _make_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # far ring: winding-agnostic (transforms may flip facets)
	m.roughness = 1.0
	return m

## Triangle count of the built ring mesh (gate).
func triangle_count() -> int:
	for c in get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			var mesh: ArrayMesh = (c as MeshInstance3D).mesh
			if mesh.get_surface_count() > 0:
				var arr := mesh.surface_get_arrays(0)
				var vv: Variant = arr[Mesh.ARRAY_VERTEX]
				return (vv as PackedVector3Array).size() / 3
	return 0
