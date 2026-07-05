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

## Render material for `block_id`; null for AIR. Cached across calls. Opaque blocks
## get a textured (or flat-swatch) unshaded material; translucent blocks (glass/water/
## ice, cull_group > 0) get an alpha-blended material (WGC §5.1); emissive blocks
## (lava) get a glow. The look is driven by BlockCatalog.render_def_of — a data change,
## not a code change.
static func get_for(block_id: int) -> StandardMaterial3D:
	if block_id == BlockCatalog.AIR:
		return null
	var cached: StandardMaterial3D = _cache.get(block_id, null)
	if cached != null:
		return cached
	var tex := BlockTextures.texture_for(block_id)
	var rd := BlockCatalog.render_def_of(block_id)
	var color := BlockCatalog.color_of(block_id)
	var mat: StandardMaterial3D
	if rd.get("translucent", false):
		mat = _translucent(tex, color, block_id == BlockCatalog.id_of(&"water"))
	elif tex != null:
		mat = _textured(tex)
	else:
		mat = _solid(color)
	if rd.get("emissive", false):
		mat.emission_enabled = true
		mat.emission = Color(color.r, color.g, color.b)
		mat.emission_energy_multiplier = float(rd.get("emissive_glow", 1.0))
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

## Translucent material for glass/water/ice (WGC §5.1). `color` carries the swatch RGB
## tint AND the alpha; a tile (e.g. the glass pane) modulates it when present, else the
## flat tint is used. ALPHA_DEPTH_PRE_PASS kills most cube-scale sorting artifacts;
## `double_sided` (water) also disables back-face culling so the surface reads from
## below. Unshaded to match the flat-ambient look. vertex_color is OFF so a placed
## coloured pane keeps its authored tint (meshers don't set per-voxel colours).
static func _translucent(tex: Texture2D, color: Color, double_sided: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED if double_sided else BaseMaterial3D.CULL_BACK
	if tex != null:
		mat.albedo_texture = tex
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		mat.texture_repeat = true
	return mat
