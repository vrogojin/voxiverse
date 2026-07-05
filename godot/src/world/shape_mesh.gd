class_name ShapeMesh
extends RefCounted
## The single geometry builder for a corner-height shape (SUB-VOXEL-SMOOTHING §4) —
## the render seam both paths + `VoxelBody` consume, so "two render paths, one
## behaviour" holds by construction (there is no second copy of the shape geometry).
## Given a modifier it returns the UNIT-cell mesh: the 1–2 surface triangles (top for
## BOTTOM, bottom for TOP), the ≤ 4 boundary side polygons (trapezoids, degenerate
## edges skipped), and the flat anchor face. Pure/deterministic; keyed only by the
## modifier so the mesher can cache one baked mesh per shape (P5b).
##
## Faces carry flat per-triangle normals and simple planar UVs (top/bottom → (x, z);
## sides → (tangent, y)); shapes reuse the material's texture planar-mapped (§1). P5a
## builds the geometry; P5b wires it into the meshers, the module `VoxelBlockyModelMesh`
## library, and `VoxelBody`.

const _EPS := 1e-6

## Build the unit-cell mesh for `modifier`: a dictionary of parallel arrays
## {verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
## indices: PackedInt32Array}. FULL (modifier 0) → a unit cube.
static func build(modifier: int) -> Dictionary:
	var c := ShapeCodec.corners(modifier)
	var anc := ShapeCodec.anchor(modifier)
	# Corner surface heights in blocks.
	var h00 := float(c.x) * 0.5
	var h10 := float(c.y) * 0.5
	var h11 := float(c.z) * 0.5
	var h01 := float(c.w) * 0.5
	var main := (c.x + c.z) >= (c.y + c.w)

	var arr := {
		"verts": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}

	# Surface (top) corner points, base (anchor) at y = 0 — BOTTOM frame. TOP mirrors
	# y → 1 − y at the end.
	var s00 := Vector3(0, h00, 0)
	var s10 := Vector3(1, h10, 0)
	var s11 := Vector3(1, h11, 1)
	var s01 := Vector3(0, h01, 1)
	var b00 := Vector3(0, 0, 0)
	var b10 := Vector3(1, 0, 0)
	var b11 := Vector3(1, 0, 1)
	var b01 := Vector3(0, 0, 1)

	# 1) Surface triangles (diagonal rule), outward normal up.
	if main:
		_tri(arr, s00, s10, s11, Vector3.UP, _uvxz(s00), _uvxz(s10), _uvxz(s11))
		_tri(arr, s00, s11, s01, Vector3.UP, _uvxz(s00), _uvxz(s11), _uvxz(s01))
	else:
		_tri(arr, s00, s10, s01, Vector3.UP, _uvxz(s00), _uvxz(s10), _uvxz(s01))
		_tri(arr, s10, s11, s01, Vector3.UP, _uvxz(s10), _uvxz(s11), _uvxz(s01))

	# 2) Anchor face — full square at y = 0, normal down.
	_quad(arr, b00, b10, b11, b01, Vector3.DOWN,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))

	# 3) Side faces (base → surface). Skip a face whose both edge heights are 0.
	_side(arr, b00, b10, s10, s00, Vector3(0, 0, -1), h00, h10)   # −Z: c00,c10
	_side(arr, b10, b11, s11, s10, Vector3(1, 0, 0), h10, h11)    # +X: c10,c11
	_side(arr, b11, b01, s01, s11, Vector3(0, 0, 1), h11, h01)    # +Z: c11,c01
	_side(arr, b01, b00, s00, s01, Vector3(-1, 0, 0), h01, h00)   # −X: c01,c00

	if anc == ShapeCodec.ANCHOR_TOP:
		_flip_top(arr)
	return arr

## Emit one side quad (base_a, base_b at y=0; surf_b, surf_a at the corner heights),
## skipping it when the face collapses to a line (both heights ~0).
static func _side(arr: Dictionary, base_a: Vector3, base_b: Vector3, surf_b: Vector3,
		surf_a: Vector3, nrm: Vector3, h_a: float, h_b: float) -> void:
	if h_a <= _EPS and h_b <= _EPS:
		return
	# UVs: tangent (0→1 across the face) × height.
	_quad(arr, base_a, base_b, surf_b, surf_a, nrm,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, h_b), Vector2(0, h_a))

## Mirror a BOTTOM-frame mesh to TOP: y → 1 − y, reverse winding, negate y-normals.
static func _flip_top(arr: Dictionary) -> void:
	var verts: PackedVector3Array = arr["verts"]
	var normals: PackedVector3Array = arr["normals"]
	var indices: PackedInt32Array = arr["indices"]
	for i in range(verts.size()):
		var v := verts[i]
		verts[i] = Vector3(v.x, 1.0 - v.y, v.z)
		var n := normals[i]
		normals[i] = Vector3(n.x, -n.y, n.z)
	for t in range(0, indices.size(), 3):
		var tmp := indices[t + 1]
		indices[t + 1] = indices[t + 2]
		indices[t + 2] = tmp
	arr["verts"] = verts
	arr["normals"] = normals
	arr["indices"] = indices

## Emit a triangle with a flat normal oriented to agree with `hint` (winding fixed so
## the geometric normal points the intended way); degenerate triangles are dropped.
static func _tri(arr: Dictionary, a: Vector3, b: Vector3, c: Vector3, hint: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var n := (b - a).cross(c - a)
	if n.length() <= _EPS:
		return
	n = n.normalized()
	if n.dot(hint) < 0.0:
		var tb := b
		b = c
		c = tb
		var tub := ub
		ub = uc
		uc = tub
		n = -n
	var base: int = arr["verts"].size()
	arr["verts"].append(a); arr["verts"].append(b); arr["verts"].append(c)
	arr["normals"].append(n); arr["normals"].append(n); arr["normals"].append(n)
	arr["uvs"].append(ua); arr["uvs"].append(ub); arr["uvs"].append(uc)
	arr["indices"].append(base); arr["indices"].append(base + 1); arr["indices"].append(base + 2)

## Emit a quad as two triangles (a,b,c,d in order).
static func _quad(arr: Dictionary, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		hint: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
	_tri(arr, a, b, c, hint, ua, ub, uc)
	_tri(arr, a, c, d, hint, ua, uc, ud)

static func _uvxz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
