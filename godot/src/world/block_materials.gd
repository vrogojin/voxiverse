class_name BlockMaterials
extends RefCounted
## Per-id RENDER materials, cached (DESIGN §1.2). Used by the module library, the
## fallback mesher, AND VoxelBody meshing — the one place a block id maps to a
## StandardMaterial3D so the world, placed blocks, and detached bodies all render
## a given block identically.
##
## Every block with a tile in BlockTextures gets a real textured material (the
## enhanced CC0 pack, see docs/TEXTURES.md); a block with no tile falls back to a
## flat solid-colour swatch (colour from BlockCatalog). Adding a textured block is
## a data change in BlockTextures — no code here changes.

# Cache keyed by block id so repeat lookups reuse one material.
static var _cache: Dictionary = {}    # int block_id -> StandardMaterial3D

## Render material for `block_id`; null for AIR. Cached across calls.
static func get_for(block_id: int) -> StandardMaterial3D:
	if block_id == BlockCatalog.AIR:
		return null
	var cached: StandardMaterial3D = _cache.get(block_id, null)
	if cached != null:
		return cached
	var tex := BlockTextures.texture_for(block_id)
	var mat := _textured(tex) if tex != null else _solid(BlockCatalog.color_of(block_id))
	_cache[block_id] = mat
	return mat

## Textured material for a block face. Unshaded (DESIGN §1: flat ambient look, no
## sun/shadows) and double-sided so newly-exposed inner faces read correctly after
## a break regardless of winding. NEAREST filter keeps the pixel-art look crisp;
## mipmaps tame shimmer where the fallback mesher tiles one texture per world-metre;
## repeat lets those per-metre UVs tile seamlessly.
static func _textured(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.texture_repeat = true
	mat.vertex_color_use_as_albedo = true
	return mat

## Flat solid-colour material (unshaded, double-sided) — the fallback when a block
## has no tile. vertex_color_use_as_albedo on so per-voxel tints still apply.
static func _solid(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	return mat
