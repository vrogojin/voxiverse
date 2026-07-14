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
	# FAM LAYER (SNOW-ACCUMULATION §1.4): a thin flat slab, BOTTOM-anchored, with all four
	# corner heights = level/10 — the uniform-height reuse of the corner builder (§3c "a thin-slab
	# builder — trivial next to the ramp builder"). is_layer FIRST so its FAM modifier never decodes
	# as corner heights.
	if CellCodec.is_junction(modifier):
		return _build_junction(modifier)
	if CellCodec.is_layer(modifier):
		var lh := float(CellCodec.layer_level(modifier)) / 10.0
		return _build_heights(lh, lh, lh, lh, ShapeCodec.ANCHOR_BOTTOM)
	if CellCodec.is_slope(modifier):
		return _build_slope(modifier)
	var c := ShapeCodec.corners(modifier)
	var anc := ShapeCodec.anchor(modifier)
	return _build_heights(float(c.x) * 0.5, float(c.y) * 0.5, float(c.z) * 0.5, float(c.w) * 0.5, anc)

## Build the unit-cell mesh from four BLOCK-height corner surfaces (h00,h10,h11,h01) + anchor —
## the shared geometry body for both the corner-height family and the uniform FAM LAYER.
static func _build_heights(h00: float, h10: float, h11: float, h01: float, anc: int) -> Dictionary:
	var main := (h00 + h11) >= (h10 + h01)

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

## Build the unit-cell mesh for a SLOPE modifier (SHARP-SLOPE §2.3): the top surface is exactly
## ShapeCodec.surface_tris (plateau at y=1 + band on the clipped plane); the bottom face is the
## {D > 0} clipped polygon at y = 0 (the empty region has no underside); side faces per lateral
## edge follow the clamped edge profile. Same {verts, normals, uvs, indices} dict.
static func _build_slope(modifier: int) -> Dictionary:
	var arr := {
		"verts": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}
	# 1) Top surface (plateau + band), top → (x, z) UVs, from the shared ShapeCodec query.
	for tri: Dictionary in ShapeCodec.surface_tris(modifier):
		var a: Vector3 = tri["v0"]
		var b: Vector3 = tri["v1"]
		var cc: Vector3 = tri["v2"]
		_tri(arr, a, b, cc, tri["normal"], _uvxz(a), _uvxz(b), _uvxz(cc))
	# 2) Bottom face — the {D > 0} clipped polygon at y = 0, normal down.
	for tri: Dictionary in ShapeCodec.slope_bottom_tris(modifier):
		var a: Vector3 = tri["v0"]
		var b: Vector3 = tri["v1"]
		var cc: Vector3 = tri["v2"]
		_tri(arr, a, b, cc, Vector3.DOWN, _uvxz(a), _uvxz(b), _uvxz(cc))
	# 3) Side faces — clamped edge profiles (SHARP-SLOPE §2.3). Heights in blocks, clamped to [0,1].
	var d := CellCodec.slope_deltas(modifier)
	var b00 := Vector3(0, 0, 0)
	var b10 := Vector3(1, 0, 0)
	var b11 := Vector3(1, 0, 1)
	var b01 := Vector3(0, 0, 1)
	_slope_side(arr, b00, b10, float(d.x), float(d.y), Vector3(0, 0, -1))   # −Z: d00,d10
	_slope_side(arr, b10, b11, float(d.y), float(d.z), Vector3(1, 0, 0))    # +X: d10,d11
	_slope_side(arr, b11, b01, float(d.z), float(d.w), Vector3(0, 0, 1))    # +Z: d11,d01
	_slope_side(arr, b01, b00, float(d.w), float(d.x), Vector3(-1, 0, 0))   # −X: d01,d00
	return arr

## Emit one SLOPE side face: the region under the clamped profile clamp(lerp(ha,hb,t),0,1) along the
## edge base_a→base_b (y=0). Fans the ≤ 5-vertex polygon (base corners + profile 0/1 knots).
static func _slope_side(arr: Dictionary, base_a: Vector3, base_b: Vector3, ha: float, hb: float, nrm: Vector3) -> void:
	var ts: Array = [0.0, 1.0]
	if absf(hb - ha) > _EPS:
		for target: float in [0.0, 1.0]:
			var t := (target - ha) / (hb - ha)
			if t > _EPS and t < 1.0 - _EPS:
				ts.append(t)
	ts.sort()
	# Ordered boundary loop as [pos, uv=(tangent, y)]: bottom edge a→b, then top profile b→a.
	var pts: Array = [[base_a, Vector2(0.0, 0.0)], [base_b, Vector2(1.0, 0.0)]]
	for i in range(ts.size() - 1, -1, -1):
		var t: float = ts[i]
		var py := clampf(lerpf(ha, hb, t), 0.0, 1.0)
		if py <= _EPS:
			continue
		pts.append([base_a.lerp(base_b, t) + Vector3(0, 1, 0) * py, Vector2(t, py)])
	if pts.size() < 3:
		return
	for i in range(1, pts.size() - 1):
		_tri(arr, pts[0][0], pts[i][0], pts[i + 1][0], nrm, pts[0][1], pts[i][1], pts[i + 1][1])

## COSMOS FACETED §3.5.4 — build the unit-cell mesh for a JUNCTION modifier: the unit cube clipped by the
## seam ridge plane (the QUANTIZED q-model plane from the atlas, matching the render). Clips the 6 cube faces
## against the plane (keep own_local ≥ 0) and adds the tilted cut face; the cut face's outward neighbour is AIR
## (the mask), so godot_voxel never culls it. The active facet supplies the exact per-seam orientation (A,B,C).
static func _build_junction(modifier: int) -> Dictionary:
	var arr := {
		"verts": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		_emit_cube(arr)                              # defensive: no active facet → full cube
		return arr
	var pl: Array = FacetAtlas.junction_model_plane(fid, CellCodec.junction_slot(modifier), CellCodec.junction_q(modifier))
	var faces := _clip_solid(_unit_cube_faces(), pl)
	for f: Dictionary in faces:
		_emit_polygon(arr, f["poly"], f["normal"])
	return arr

## COSMOS FP-CARVE (docs/COSMOS-FACETED-CARVE.md) — the multi-plane cube-clip REFERENCE the C++ mesher
## transcribes 1:1 (patch 0004). Given the LOCAL cell planes (each [A, B, C, base]; own_local(u) =
## A·ux + B·uy + C·uz + base ≥ 0 is the interior half-space — the exact form junction_prism_verts builds),
## fold the unit cube through _clip_solid once per plane. A single plane reproduces _build_junction's
## single-plane clip exactly (identical body); ≥ 2 planes clip CORNER cells correctly because _clip_solid
## re-clips every face it is handed, INCLUDING previously-added caps (cap-of-cap). Returns the surviving
## face list [{poly: [Vector3…] CCW, normal: Vector3}]; degenerate faces are dropped by _clip_solid.
static func build_carve_faces(local_planes: Array) -> Array:
	var faces := _unit_cube_faces()
	for pl: Array in local_planes:
		faces = _clip_solid(faces, pl)
	return faces

# The 6 faces of the unit cube as {poly: [Vector3 ×4 CCW], normal: Vector3 outward}.
static func _unit_cube_faces() -> Array:
	var v := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]
	return [
		{"poly": [v[0], v[3], v[2], v[1]], "normal": Vector3.DOWN},   # y=0
		{"poly": [v[4], v[5], v[6], v[7]], "normal": Vector3.UP},     # y=1
		{"poly": [v[0], v[1], v[5], v[4]], "normal": Vector3(0, 0, -1)},  # z=0
		{"poly": [v[3], v[7], v[6], v[2]], "normal": Vector3(0, 0, 1)},   # z=1
		{"poly": [v[0], v[4], v[7], v[3]], "normal": Vector3(-1, 0, 0)},  # x=0
		{"poly": [v[1], v[2], v[6], v[5]], "normal": Vector3(1, 0, 0)},   # x=1
	]

static func _plane_val(pl: Array, p: Vector3) -> float:
	return pl[0] * p.x + pl[1] * p.y + pl[2] * p.z + pl[3]

# Clip a convex solid (list of {poly, normal}) by one half-space (keep own_local ≥ 0), adding the cut cap.
static func _clip_solid(faces: Array, pl: Array) -> Array:
	var out: Array = []
	var cut_pts: Array = []
	for f: Dictionary in faces:
		var r := _clip_poly(f["poly"], pl)
		var poly: Array = r["poly"]
		if poly.size() >= 3:
			out.append({"poly": poly, "normal": f["normal"]})
		for cp: Vector3 in r["cut"]:
			cut_pts.append(cp)
	if cut_pts.size() >= 3:
		var cn := Vector3(-pl[0], -pl[1], -pl[2]).normalized()   # cut face points OUT of the solid (−grad)
		var ring := _order_ring(cut_pts, cn)
		if ring.size() >= 3:
			out.append({"poly": ring, "normal": cn})
	return out

# Sutherland–Hodgman: keep the own_local ≥ 0 side of `poly`; report the ≤2 crossing points for the cap.
static func _clip_poly(poly: Array, pl: Array) -> Dictionary:
	var out: Array = []
	var cut: Array = []
	var n := poly.size()
	for i in range(n):
		var cur: Vector3 = poly[i]
		var nxt: Vector3 = poly[(i + 1) % n]
		var fc := _plane_val(pl, cur)
		var fn := _plane_val(pl, nxt)
		var ic := fc >= -_EPS
		var inx := fn >= -_EPS
		if ic:
			out.append(cur)
		if ic != inx:
			var t := fc / (fc - fn)
			var ip := cur.lerp(nxt, t)
			out.append(ip)
			cut.append(ip)
	return {"poly": out, "cut": cut}

# Order a set of coplanar points into a convex ring (dedup + angular sort about the centroid).
static func _order_ring(pts: Array, normal: Vector3) -> Array:
	var uniq: Array = []
	for p: Vector3 in pts:
		var dup := false
		for u: Vector3 in uniq:
			if p.distance_to(u) < 1e-5:
				dup = true; break
		if not dup:
			uniq.append(p)
	if uniq.size() < 3:
		return []
	var c := Vector3.ZERO
	for u: Vector3 in uniq:
		c += u
	c /= float(uniq.size())
	var t := normal.cross(Vector3.UP)
	if t.length() < 1e-4:
		t = normal.cross(Vector3.RIGHT)
	t = t.normalized()
	var bt := normal.cross(t).normalized()
	uniq.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return atan2((a - c).dot(bt), (a - c).dot(t)) < atan2((b - c).dot(bt), (b - c).dot(t)))
	return uniq

# Emit a convex polygon (fan) with a flat normal + planar UV (top/bottom → x,z; laterals/cut → tangent,y).
static func _emit_polygon(arr: Dictionary, poly: Array, normal: Vector3) -> void:
	for i in range(1, poly.size() - 1):
		_tri(arr, poly[0], poly[i], poly[i + 1], normal,
			_face_uv(poly[0], normal), _face_uv(poly[i], normal), _face_uv(poly[i + 1], normal))

static func _face_uv(v: Vector3, normal: Vector3) -> Vector2:
	if absf(normal.y) > 0.5:
		return Vector2(v.x, v.z)
	var tang := normal.cross(Vector3.UP)
	if tang.length() < 1e-4:
		tang = Vector3(1, 0, 0)
	tang = tang.normalized()
	return Vector2(v.dot(tang), v.y)

static func _emit_cube(arr: Dictionary) -> void:
	for f: Dictionary in _unit_cube_faces():
		_emit_polygon(arr, f["poly"], f["normal"])

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
