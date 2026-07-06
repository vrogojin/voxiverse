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
## Both builders emit the water surface at y = WATER_SURFACE_HEIGHT with NO vertical side faces
## (WATER-SHORE seam fix — see surface_slab's doc): a coincident translucent side pane between a
## slab and a wet composite drew as a visible "border" inside the water. Now:
##   * `surface_slab()` — the OPEN-WATER surface cell's own model (translucent water material,
##     transparency_index 1): a top quad at 0.9 (the visible plane) + a bottom lid at y=0. No
##     sides, so adjacent water cells share one seamless plane; the lid closes the volume.
##   * `shore_fill()` — surface 1 of the WET COMPOSITE model (WATER-SHORE §4.3): ONLY the top
##     0.9 quad, above the opaque terrain ramp on surface 0 (which shows through). No sides/
##     bottom. Modifier-INDEPENDENT, so one mesh is shared across every modifier & material
##     (the wet model's per-material difference is only the surface-0 override).

const _EPS := 1e-6

## The open-water surface cell model: the flat water plane at y = WATER_SURFACE_HEIGHT plus a
## bottom lid at y = 0 — NO vertical side faces. WATER-SHORE follow-up (seam fix): the wet
## composite's water box side and this slab's side are COINCIDENT translucent quads at a
## water↔composite boundary; the opaque wet model's side can't be culled by the translucent
## slab, so a visible vertical pane was drawn INSIDE the water body (the "border" the user saw).
## Dropping the side faces means adjacent surface-water cells and shore composites share ONE
## continuous 0.9 plane with no vertical pane between them. The bottom lid closes the volume
## against the water cube below (so a slab exposed by a drained-hole edit still reads as water).
## Trade-off: a true water↔AIR vertical edge (rare in a terrain-bounded lake/sea) loses its top
## 0.9 lip; the deep water cube below still walls the rest.
static func surface_slab() -> Dictionary:
	return _lid(TerrainConfig.WATER_SURFACE_HEIGHT)

## The shore-composite water overlay (surface 1 of the wet model): ONLY the top water plane at
## y = WATER_SURFACE_HEIGHT — no sides, no bottom. The opaque terrain ramp (surface 0) fills
## below and shows through; a side pane here is exactly what drew as a seam against neighbouring
## water, so it is gone. A bare top quad = the visible water surface above the ramp, continuous
## with the open-water slab plane. Modifier-independent, so one mesh is shared across all.
static func shore_fill() -> Dictionary:
	return _top(TerrainConfig.WATER_SURFACE_HEIGHT)

## A fresh empty geometry dict in the shared {verts,normals,uvs,indices} format.
static func _new() -> Dictionary:
	return {
		"verts": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}

## A single horizontal water quad (+Y, the visible surface) at height `top`; planar UVs (x, z).
static func _top(top: float) -> Dictionary:
	var arr := _new()
	_quad(arr, Vector3(0, top, 0), Vector3(1, top, 0), Vector3(1, top, 1), Vector3(0, top, 1),
		Vector3.UP, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	return arr

## The top water quad at `top` plus a bottom lid at y=0 (−Y) — no side faces.
static func _lid(top: float) -> Dictionary:
	var arr := _top(top)
	_quad(arr, Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3.DOWN, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
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
