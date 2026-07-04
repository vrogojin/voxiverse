class_name AimHighlight
extends MeshInstance3D
## Brightens the FACE of the block the player is currently aiming at (and would
## break with a left-click, or build against with a right-click). Instead of a
## wireframe cage, it is a single unit quad laid flat on the aimed face, floated a
## hair proud of it (LIFT) to avoid z-fighting, drawn UNSHADED with ADDITIVE
## blending so it literally brightens whatever texture is underneath — a grass
## voxel, a wooden face — regardless of lighting.
##
## Depth testing stays ON (no_depth_test = false), so an intervening block hides
## the face highlight exactly like normal in-world geometry — the same occlusion
## guarantee the old wireframe established (walk behind a rise and the highlight
## on a block beyond it disappears).
##
## Positioning is entirely through the node transform. The caller supplies the
## full block transform (`cell_xform`, the WORLD transform of the unit cube on the
## target block — for a tumbling VoxelBody it carries the body's rotation) plus the
## struck face's unit normal in the block's LOCAL frame; a static 6-entry LUT maps
## that normal to the transform that carries the flat local quad onto the matching
## face of the unit cube [0,1]^3. Because `cell_xform` is the same transform the
## wireframe used, the face quad tracks moving bodies as faithfully as static
## terrain.

## Metres the quad floats off the face, along the face normal, so the additive
## quad sits just proud of the coplanar block face and never z-fights with it.
const LIFT := 0.004

## Face lookup table: block-local unit normal (Vector3i) -> the Transform3D that
## maps the flat local quad [0,1]x[0,1] (in the XZ plane at y=0, normal +Y) onto
## that face of the unit cube [0,1]^3, lifted LIFT outward along the normal. Built
## once, lazily, and shared by every highlight instance (static).
static var _FACE: Dictionary = {}

func _ready() -> void:
	# Live in world space: the player parents us but its own translation/rotation
	# must not drag the highlight around — show_face() supplies an absolute
	# transform composed from the target block's transform and the face LUT.
	top_level = true
	_ensure_lut()
	mesh = _build_quad()
	visible = false

## Snap the highlight onto the aimed face. `cell_xform` is the WORLD transform of
## the target block's unit cube (pure translation for terrain; body transform
## composed with the cell offset for a wooden block). `normal` is the struck
## face's unit axis in the block's LOCAL frame — the LUT places the quad on that
## face, lifted proud of it.
func show_face(cell_xform: Transform3D, normal: Vector3i) -> void:
	var face: Transform3D = _FACE.get(normal, Transform3D())
	global_transform = cell_xform * face
	visible = true

## Nothing is targeted (out of reach / pointing at sky) — stop drawing.
func hide_it() -> void:
	visible = false

# --- internals -----------------------------------------------------------------

## Build the static face LUT once. Each entry carries the flat quad (u along local
## X, v along local Z, at y=0) onto one face of the unit cube so it fully covers
## that face's [0,1]x[0,1] square, offset LIFT outward along the face normal.
static func _ensure_lut() -> void:
	if not _FACE.is_empty():
		return
	# Top / bottom: the quad already lies in the XZ plane, just lift it in Y.
	_FACE[Vector3i.UP] = Transform3D(Basis(), Vector3(0.0, 1.0 + LIFT, 0.0))
	_FACE[Vector3i.DOWN] = Transform3D(Basis(), Vector3(0.0, -LIFT, 0.0))
	# Sides: rotate the quad upright so local X->Y (or Z) spans the vertical face.
	# Basis columns are the images of local X, Y, Z; local Y becomes the outward
	# normal. Origins place x/z at the face and lift it LIFT outward.
	_FACE[Vector3i.RIGHT] = Transform3D(
		Basis(Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0)),
		Vector3(1.0 + LIFT, 0.0, 0.0))
	_FACE[Vector3i.LEFT] = Transform3D(
		Basis(Vector3(0.0, 1.0, 0.0), Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0)),
		Vector3(-LIFT, 0.0, 0.0))
	_FACE[Vector3i.BACK] = Transform3D(
		Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.0, 0.0)),
		Vector3(0.0, 0.0, 1.0 + LIFT))
	_FACE[Vector3i.FORWARD] = Transform3D(
		Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0)),
		Vector3(0.0, 0.0, -LIFT))

## One unit quad [0,1]x[0,1] in the local XZ plane at y=0 (two triangles), built
## once, with the additive unshaded material.
func _build_quad() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(1.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.0, 1.0), Vector3(0.0, 0.0, 1.0),
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	var mesh_out := ArrayMesh.new()
	mesh_out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_out.surface_set_material(0, _build_material())
	return mesh_out

## Unshaded additive white-ish quad: ADD blending brightens whatever is under it,
## so the aimed face reads as "lit up" over any texture. Depth test stays ON so a
## closer block occludes it (preserving the wireframe's occlusion behaviour), and
## culling is disabled so the single quad shows from either side.
func _build_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(0.55, 0.55, 0.55)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false   # respect depth buffer: occluded by closer geometry
	return mat
