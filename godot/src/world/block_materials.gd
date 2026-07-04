class_name BlockMaterials
extends RefCounted
## Per-id RENDER materials, cached (DESIGN §1.2). Used by the module library, the
## fallback mesher, AND VoxelBody meshing — the one place a block id maps to a
## StandardMaterial3D so the world, placed blocks, and detached bodies all render
## a given block identically.
##
## GRASS/WOOD reuse the existing textured builders; DIRT/STONE/LEAF are flat
## solid-colour swatches (unshaded, colour from BlockCatalog). No separate
## dirt/stone/leaf material files — the three solid builders live here (fewer
## files, one owner). Texture bakers can replace _solid() later with no contract
## change.

# Cache keyed by block id so repeat lookups reuse one material (GrassMaterial /
# WoodMaterial cache internally; the solid builders are cached here).
static var _cache: Dictionary = {}    # int block_id -> StandardMaterial3D

## Render material for `block_id`; null for AIR. Cached across calls.
static func get_for(block_id: int) -> StandardMaterial3D:
	if block_id == BlockCatalog.AIR:
		return null
	var cached: StandardMaterial3D = _cache.get(block_id, null)
	if cached != null:
		return cached
	var mat: StandardMaterial3D
	match block_id:
		BlockCatalog.GRASS:
			mat = GrassMaterial.build()
		BlockCatalog.WOOD:
			mat = WoodMaterial.build()
		_:
			mat = _solid(BlockCatalog.color_of(block_id))
	_cache[block_id] = mat
	return mat

## Flat solid-colour material (unshaded, double-sided) matching the grass/wood
## conventions — vertex_color_use_as_albedo on so per-voxel tints still apply.
static func _solid(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	return mat
