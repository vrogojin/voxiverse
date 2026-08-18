class_name DevSpaceObject
extends Node3D
## COSMOS-OBJECT-LOD P3 (docs/COSMOS-OBJECT-LOD-DESIGN.md, FP_OBJ_LOD_SPACE) — a DEV CLASS_SPACE test object: a
## ~40-block "asteroid / station" stand-in used to live-verify the P3 beacon ladder (never-cull dot, planet
## occlusion, clamped-distance placement). It implements EXACTLY the duck-typed registry interface the far tier
## reads (ObjectRegistry / FacetFarObjects) — the SAME interface a real VoxelBody exposes — which is the point:
## it proves "ships / stations / asteroids plug into the same API" (locked decision 1) with no tier change.
##
## Spawned by WorldManager ONLY under CubeSphere.FP_OBJ_LOD_SPACE (radially +2500 blocks above the player spawn),
## registered as ObjectLod.CLASS_SPACE, and never spawned with the flag off ⇒ byte-identical off.
##
## L0 is a plain solid ~40³ grey/stone BoxMesh so up close it reads as a real object; when the tier stands a far
## card/dot in for it (set_far_hidden(true)) the box is hidden — the same L0-hide contract as a VoxelBody.

## The object's full extent (blocks) — largest AABB dimension. r = extent/2 = 20 (ObjectLod bounding radius).
const EXTENT := 40.0

var _mesh: MeshInstance3D = null
var _far_hidden := false

func _ready() -> void:
	if _mesh == null:
		_build_mesh()

func _build_mesh() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(EXTENT, EXTENT, EXTENT)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.46, 0.46, 0.49)     # stone grey
	mat.roughness = 0.95
	mat.metallic = 0.0
	box.material = mat
	_mesh = MeshInstance3D.new()
	_mesh.name = "DevSpaceObjectL0"
	_mesh.mesh = box
	_mesh.visible = not _far_hidden
	add_child(_mesh)

# --- COSMOS-OBJECT-LOD duck interface (identical shape to VoxelBody's) -------------------------------------------

## The object's centre in planet-absolute (global) space — the tier maps this through the far-ring parent inverse.
func obj_world_center() -> Vector3:
	return global_transform.origin

## Bounding extent (blocks); ObjectLod uses r = extent/2. Static (a rigid station stand-in).
func obj_extent() -> float:
	return EXTENT

## CLASS_SPACE ⇒ never hard-culled; the tier clamps it to a P_POINT beacon dot (brightness ∝ p²) at extreme range.
func obj_class() -> int:
	return ObjectLod.CLASS_SPACE

## No mesh rebuilds (static) ⇒ a constant rev; the tier's must-fix #1 re-hide never needs to re-fire.
func obj_rev() -> int:
	return 0

## Dormant / static — the tier treats it as a snapshot object (no per-frame awake rewrite).
func is_awake() -> bool:
	return false

## Hide / show the L0 box while a far card/dot stands in for it (the L0-hide contract the tier drives).
func set_far_hidden(hidden: bool) -> void:
	_far_hidden = hidden
	if _mesh != null:
		_mesh.visible = not hidden
