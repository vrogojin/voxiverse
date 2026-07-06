class_name WaterMesh
extends RefCounted
## Geometry builders for the WATER-SHORE feature's water surfaces (WATER-SHORE §4.1).
## Same `{verts, normals, uvs, indices}` dictionary format as `ShapeMesh.build` so the
## module path (VoxelBlockyModelMesh) consumes them identically; pure/static/deterministic.
##
## The one water height (0.9 blocks) is read from `TerrainConfig.WATER_SURFACE_HEIGHT` —
## NOT hardcoded — because it is NOT a half-block corner height and therefore cannot live
## in the ShapeCodec/ShapeMesh corner-height family (which is HALF-BLOCK granular by
## design, corners ∈ {0,1,2}). That is exactly why water is a dedicated lightweight
## builder rather than a new shape family (WATER-SHORE §4.1, decision §10.8).
##
## Both builders return a box [0,1] × [0, WATER_SURFACE_HEIGHT] × [0,1]:
##   * `surface_slab()` — the OPEN-WATER surface cell's own model (its own translucent
##     water material + transparency_index 1): the top quad at y=0.9 is the visible water
##     plane; the bottom + side quads are flush with cell faces and get pattern-culled by
##     the blocky mesher against the seafloor / neighbour slabs, but exist so a slab
##     exposed by an edit (a drained hole beside it) still closes the volume.
##   * `shore_fill()` — surface 1 of the WET COMPOSITE model (WATER-SHORE §4.3): the water
##     that fills a smoothed shore cell up to the water line ABOVE its terrain ramp. Same
##     box; it deliberately does NOT match the ramp corners (the opaque ramp on surface 0
##     shows THROUGH it; box geometry below/inside the ramp is depth-hidden overdraw). The
##     box is modifier-INDEPENDENT, so one mesh is shared across every modifier & material
##     (the wet model's per-material difference is only the surface-0 override).

const _EPS := 1e-6

## The open-water surface cell model: a box whose top face sits at the water line
## (y = WATER_SURFACE_HEIGHT). See the file header for the face-culling role.
static func surface_slab() -> Dictionary:
	return _box(TerrainConfig.WATER_SURFACE_HEIGHT)

## The shore-composite water overlay: the same 0.9-high box, used as surface 1 of the wet
## composite model. Modifier-independent (never matches the ramp corners) so it is shared.
static func shore_fill() -> Dictionary:
	return _box(TerrainConfig.WATER_SURFACE_HEIGHT)

## Build a unit-footprint box from y=0 to y=`top`: top quad (+Y, the visible surface),
## bottom quad (−Y), and four side quads. Flat per-face normals; planar UVs (top/bottom →
## (x, z); sides → (tangent, y)) matching ShapeMesh's conventions.
static func _box(top: float) -> Dictionary:
	var arr := {
		"verts": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}
	var b00 := Vector3(0, 0, 0)
	var b10 := Vector3(1, 0, 0)
	var b11 := Vector3(1, 0, 1)
	var b01 := Vector3(0, 0, 1)
	var t00 := Vector3(0, top, 0)
	var t10 := Vector3(1, top, 0)
	var t11 := Vector3(1, top, 1)
	var t01 := Vector3(0, top, 1)

	# Top (+Y) — the water surface. Bottom (−Y) at y=0.
	_quad(arr, t00, t10, t11, t01, Vector3.UP,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	_quad(arr, b00, b10, b11, b01, Vector3.DOWN,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))

	# Four sides (base → water line). UVs: tangent × height.
	_quad(arr, b00, b10, t10, t00, Vector3(0, 0, -1),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, top), Vector2(0, top))   # −Z
	_quad(arr, b10, b11, t11, t10, Vector3(1, 0, 0),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, top), Vector2(0, top))   # +X
	_quad(arr, b11, b01, t01, t11, Vector3(0, 0, 1),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, top), Vector2(0, top))   # +Z
	_quad(arr, b01, b00, t00, t01, Vector3(-1, 0, 0),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, top), Vector2(0, top))   # −X
	return arr

## Emit a triangle with a flat normal oriented to agree with `hint` (winding fixed so the
## geometric normal points the intended way); degenerate triangles are dropped. Identical
## contract to ShapeMesh._tri so both builders' meshes read the same way in the mesher.
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
