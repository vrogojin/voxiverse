class_name AimHighlight
extends MeshInstance3D
## A wireframe cube outline drawn around the block the player is currently aiming
## at (and would break with a left-click). It reads clearly over any texture — a
## grass voxel, a wooden face — because it is an UNSHADED line mesh. It respects
## the depth buffer like normal in-world geometry: edges on the exposed near faces
## of the target block draw, while edges behind the block (or occluded by an
## intervening block/pillar) are correctly hidden. The INFLATE bump lifts the 12
## edges just proud of the block faces so they read crisply without z-fighting.
##
## The mesh is a unit cube spanning body-LOCAL [0, 1] on every axis, matching the
## convention that voxel cell `c` occupies the unit cube [c, c+1]. It is inflated
## a hair (INFLATE) around its centre so the outline sits just proud of the block
## faces instead of coplanar with them. Positioning is done entirely through the
## node transform: `show_at(xform)` drops the [0,1] cube exactly onto the target
## block, and because the caller passes a full Transform3D the outline tracks a
## tumbling/rotating VoxelBody as faithfully as a static terrain voxel.

## How far past the unit cube the outline is pushed, per axis, around the cube
## centre. 1.06 ≈ 3 cm of clearance on a 1 m block — enough to lift the lines off
## the coplanar block faces so depth-tested rendering shows them without z-fighting
## shimmer, while still hugging the block closely enough to read as its outline.
const INFLATE := 1.06

func _ready() -> void:
	# Live in world space: the player parents us but its own translation/rotation
	# must not drag the outline around — show_at() supplies an absolute transform.
	top_level = true
	mesh = _build_wire_cube()
	visible = false

## Snap the outline onto a target block. `xform` is the WORLD transform that maps
## the local [0,1] unit cube onto the block: for terrain it is a pure translation
## to the cell corner; for a wooden block it also carries the body's rotation so
## the cage tumbles with the piece.
func show_at(xform: Transform3D) -> void:
	global_transform = xform
	visible = true

## Nothing is targeted (out of reach / pointing at sky) — stop drawing the cage.
func hide_it() -> void:
	visible = false

# --- internals -----------------------------------------------------------------

## Build the 12-edge outline of the unit cube [0,1]^3 as a PRIMITIVE_LINES mesh,
## inflated by INFLATE about the cube centre, with a bright unshaded material that
## respects the depth buffer so closer opaque geometry occludes it.
func _build_wire_cube() -> ArrayMesh:
	# Inflate each of the two corner coordinates (0 and 1) about the centre 0.5.
	const CENTER := 0.5
	var lo := CENTER + (0.0 - CENTER) * INFLATE   # slightly below 0
	var hi := CENTER + (1.0 - CENTER) * INFLATE   # slightly above 1

	# The 8 corners of the inflated cube.
	var c: Array[Vector3] = [
		Vector3(lo, lo, lo), Vector3(hi, lo, lo),
		Vector3(hi, lo, hi), Vector3(lo, lo, hi),
		Vector3(lo, hi, lo), Vector3(hi, hi, lo),
		Vector3(hi, hi, hi), Vector3(lo, hi, hi),
	]
	# 12 edges as corner-index pairs: 4 bottom, 4 top, 4 verticals.
	var edges: Array[int] = [
		0, 1, 1, 2, 2, 3, 3, 0,   # bottom rectangle
		4, 5, 5, 6, 6, 7, 7, 4,   # top rectangle
		0, 4, 1, 5, 2, 6, 3, 7,   # vertical struts
	]

	var verts := PackedVector3Array()
	for idx: int in edges:
		verts.append(c[idx])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	var mesh_out := ArrayMesh.new()
	mesh_out.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh_out.surface_set_material(0, _build_material())
	return mesh_out

## Unshaded bright cyan so the outline reads over any texture regardless of
## lighting. Depth testing stays ON so the wireframe is occluded by closer opaque
## geometry — an intervening block hides the edges behind it, exactly like normal
## in-world geometry — while the INFLATE clearance keeps the near edges crisp.
func _build_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.1, 1.0, 1.0)   # bright cyan
	mat.vertex_color_use_as_albedo = false
	mat.no_depth_test = false                 # respect depth buffer: occluded by closer geometry
	# Lines have no back/front; disable culling so orientation never hides an edge.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
