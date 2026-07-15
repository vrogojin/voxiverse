class_name CosmosFacet
extends RefCounted
## COSMOS FP0 (docs/COSMOS-FACETED-PLANET-STUDY.md) — the FacetAtlas math for the piecewise-flat planet.
## The planet is a k×k faceting of each of the 6 cube faces: 6k² FLAT quad facets, each an UNDISTORTED
## square-voxel patch, tilted to approximate the sphere. Curvature lives at the facet EDGES (dihedral ridges)
## and VERTICES; inside a facet, zero cell distortion. This kernel gives per-facet flat frames + corner
## positions; the FP0 spike (faceted_spike.gd) assembles a demo planet from them for the user's taste verdict.
##
## Vertex direction convention: a grid vertex (i,j) ∈ [0,k]² on cube face `face` maps to the sphere via the
## SAME equal-angle warp the engine uses — d = normalize(N + warp(2i/k−1)·U + warp(2j/k−1)·V). A facet is the
## cell (a,b) ∈ [0,k)²; its 4 corners are the grid vertices (a,b)(a+1,b)(a+1,b+1)(a,b+1). The facet is FLAT:
## its interior is the bilinear quad of those 4 true-sphere corners (NOT re-projected), so it is a plane patch.

## Sphere direction of grid vertex (i,j) at faceting resolution k, on cube face `face` (f64 exact).
static func vertex_dir(face: int, i: int, j: int, k: int) -> CubeSphere.DVec3:
	var a := 2.0 * float(i) / float(k) - 1.0
	var b := 2.0 * float(j) / float(k) - 1.0
	var nn := CubeSphere._axis_n(face)
	var uu := CubeSphere._axis_u(face)
	var vv := CubeSphere._axis_v(face)
	var wu := CubeSphere.warp(a)
	var wv := CubeSphere.warp(b)
	var d := CubeSphere.DVec3.new(
		float(nn.x) + wu * float(uu.x) + wv * float(vv.x),
		float(nn.y) + wu * float(uu.y) + wv * float(vv.y),
		float(nn.z) + wu * float(uu.z) + wv * float(vv.z))
	return d.normalized()

## A grid vertex direction as a Vector3 (f32 — for demo-scale mesh building; the demo R is small).
static func vertex_v3(face: int, i: int, j: int, k: int) -> Vector3:
	var d := vertex_dir(face, i, j, k)
	return Vector3(d.x, d.y, d.z)

## The 4 true-sphere CORNER positions of facet (face,a,b) at radius R, CCW: [00,10,11,01].
static func facet_corners(face: int, a: int, b: int, k: int, r: float) -> PackedVector3Array:
	return PackedVector3Array([
		vertex_v3(face, a, b, k) * r,
		vertex_v3(face, a + 1, b, k) * r,
		vertex_v3(face, a + 1, b + 1, k) * r,
		vertex_v3(face, a, b + 1, k) * r])

## The facet's outward normal — the radial at its centre (its flat plane's normal, ≈ the mean of the corner
## radials; the centre radial is the stable choice used for terrain displacement).
static func facet_normal(face: int, a: int, b: int, k: int) -> Vector3:
	var c := vertex_v3(face, a, b, k) + vertex_v3(face, a + 1, b, k) \
		+ vertex_v3(face, a + 1, b + 1, k) + vertex_v3(face, a, b + 1, k)
	return c.normalized()

## Bilinear interior sphere DIRECTION of a facet at (s,t) ∈ [0,1]² — for sampling terrain per facet cell.
## Uses the true corner directions, re-normalized (a point on the sphere, for the height/biome lookup).
static func facet_dir_at(face: int, a: int, b: int, k: int, s: float, t: float) -> CubeSphere.DVec3:
	var d00 := vertex_dir(face, a, b, k)
	var d10 := vertex_dir(face, a + 1, b, k)
	var d11 := vertex_dir(face, a + 1, b + 1, k)
	var d01 := vertex_dir(face, a, b + 1, k)
	var x := d00.x * (1 - s) * (1 - t) + d10.x * s * (1 - t) + d11.x * s * t + d01.x * (1 - s) * t
	var y := d00.y * (1 - s) * (1 - t) + d10.y * s * (1 - t) + d11.y * s * t + d01.y * (1 - s) * t
	var z := d00.z * (1 - s) * (1 - t) + d10.z * s * (1 - t) + d11.z * s * t + d01.z * (1 - s) * t
	return CubeSphere.DVec3.new(x, y, z).normalized()

## FLAT interior 3D position of a facet at (s,t) at radius R — the bilinear quad of the 4 true corners (a
## PLANE patch, no re-projection → undistorted flat facet).
static func facet_pos_at(face: int, a: int, b: int, k: int, s: float, t: float, r: float) -> Vector3:
	var c := facet_corners(face, a, b, k, r)
	return c[0].lerp(c[1], s).lerp(c[3].lerp(c[2], s), t)

# ---------------------------------------------------------------------------------------
# Gate helpers — validate the study's headline claim: the 8×90° cube corners DISSOLVE.
# ---------------------------------------------------------------------------------------

## Angular defect (degrees) at cube VERTEX `corner_idx` (0..7): 360° − Σ of the incident facets' corner
## angles there. The study predicts this is tiny (≈2.2° at k=8, 0.47° at k=16) — the corners cease to be
## metric concentrations. Finds the (3) faces whose grid corner maps to the cube direction.
static func corner_defect_deg(k: int, corner_idx: int) -> float:
	var cd := CubeSphere.corner_dir(corner_idx)
	var sum_ang := 0.0
	var found := 0
	for face in range(6):
		for ci in [0, k]:
			for cj in [0, k]:
				var vd := vertex_dir(face, ci, cj, k)
				if absf(vd.x - cd.x) < 1e-6 and absf(vd.y - cd.y) < 1e-6 and absf(vd.z - cd.z) < 1e-6:
					sum_ang += _corner_angle(face, ci, cj, k)
					found += 1
	if found == 0:
		return -1.0
	return 360.0 - rad_to_deg(sum_ang)

## Interior angle (radians) at grid corner (ci,cj) of the facet inward from it (the cube-corner facet).
static func _corner_angle(face: int, ci: int, cj: int, k: int) -> float:
	var a := ci if ci < k else k - 1        # the cell inward from an outer grid vertex
	var b := cj if cj < k else k - 1
	# the facet's 4 corner grid vertices in order:
	var vs := [Vector2i(a, b), Vector2i(a + 1, b), Vector2i(a + 1, b + 1), Vector2i(a, b + 1)]
	var idx := -1
	for m in range(4):
		if vs[m].x == ci and vs[m].y == cj:
			idx = m
			break
	if idx < 0:
		return 0.0
	var vp := vertex_v3(face, ci, cj, k)
	var vprev: Vector2i = vs[(idx + 3) % 4]
	var vnext: Vector2i = vs[(idx + 1) % 4]
	var e1 := (vertex_v3(face, vprev.x, vprev.y, k) - vp).normalized()
	var e2 := (vertex_v3(face, vnext.x, vnext.y, k) - vp).normalized()
	return acos(clampf(e1.dot(e2), -1.0, 1.0))

## Dihedral angle (degrees) across a sample interior edge between facet (face,a,b) and (face,a+1,b) — the
## fold-line "ridge turn". Study: ~5.2° mid-face at k=16, ~10° at k=8.
static func sample_dihedral_deg(face: int, a: int, b: int, k: int) -> float:
	var n1 := facet_normal(face, a, b, k)
	var n2 := facet_normal(face, a + 1, b, k)
	return rad_to_deg(acos(clampf(n1.dot(n2), -1.0, 1.0)))
