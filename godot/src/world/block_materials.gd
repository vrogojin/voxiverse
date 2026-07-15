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
static var _snow_cache: Dictionary = {}   # int base block_id -> StandardMaterial3D (snow-capped variant, M1)

## Render material for `block_id`; null for AIR. Cached across calls. Opaque blocks
## get a textured (or flat-swatch) unshaded material; translucent blocks (glass/water/
## ice, cull_group > 0) get an alpha-blended material (WGC §5.1); emissive blocks
## (lava) get a glow. The look is driven by BlockCatalog.render_def_of — a data change,
## not a code change.
## Returns a Material (StandardMaterial3D in the default FLAT_WORLD; a bend ShaderMaterial when
## the COSMOS planet is on — see _bend_material). Both share the same per-id cache.
static func get_for(block_id: int) -> Material:
	if block_id == BlockCatalog.AIR:
		return null
	var cached: Material = _cache.get(block_id, null)
	if cached != null:
		return cached
	# COSMOS M1 (§3.4): when the planet is on, every material carries the shared camera-centred bend
	# shader so ALL geometry (terrain, water, trees, placed blocks, VoxelBody debris — everything
	# flows through here) curves onto the sphere with one code path, keeping each block's own albedo/
	# texture/emission. FLAT_WORLD (default) returns today's StandardMaterial3D — byte-identical.
	# COSMOS R2.2 (M5_REAL): the near field is now REAL baked geometry (the C++ mesher places every vertex
	# at its true sphere position), so it must carry NO bend shader — bending baked verts again would
	# double-transform them. Return the plain StandardMaterial3D, same as flat (docs/…-REAL-GEOMETRY §1).
	var mat: Material
	if CubeSphere.FLAT_WORLD or CubeSphere.M5_REAL:
		mat = _standard(block_id)
	else:
		mat = _bend_material(block_id)
	_cache[block_id] = mat
	return mat

## Today's per-id StandardMaterial3D look (unchanged from pre-M1) — the FLAT_WORLD material.
static func _standard(block_id: int) -> StandardMaterial3D:
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
	return mat

## The COSMOS M1 bend material (§3.4): a ShaderMaterial mirroring _standard's look (unshaded,
## textured / flat-swatch / translucent, optional emission) with the shared camera-centred sphere
## vertex bend. Only built when CubeSphere.FLAT_WORLD is false.
static func _bend_material(block_id: int) -> ShaderMaterial:
	CosmosBend.ensure_globals()
	var tex := BlockTextures.texture_for(block_id)
	var rd := BlockCatalog.render_def_of(block_id)
	var color := BlockCatalog.color_of(block_id)
	var translucent: bool = rd.get("translucent", false)
	var m := ShaderMaterial.new()
	# COSMOS M5a (§2): when M5_RENDER is on, carry the TRUE-POSITION placement shader (per-vertex sphere
	# position + interaction bubble) instead of the camera-centred bend — same uniform surface, so the
	# param-setting below is unchanged. Default M5_RENDER=false → the CosmosBend shader (byte-identical).
	if CubeSphere.M5_RENDER:
		CosmosTruePlace.ensure_globals_m5()
		m.shader = CosmosTruePlace.translucent_shader_m5() if translucent else CosmosTruePlace.opaque_shader_m5()
	else:
		m.shader = CosmosBend.translucent_shader() if translucent else CosmosBend.opaque_shader()
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
		m.set_shader_parameter("use_texture", true)
	else:
		m.set_shader_parameter("use_texture", false)
	if translucent:
		m.set_shader_parameter("albedo_color", color)          # tint + alpha; no per-voxel vertex color
	else:
		m.set_shader_parameter("albedo_color", Color(1, 1, 1, 1) if tex != null else color)
		m.set_shader_parameter("use_vertex_color", true)
		if rd.get("emissive", false):
			m.set_shader_parameter("emission_color", Color(color.r, color.g, color.b))
			m.set_shader_parameter("emission_energy", float(rd.get("emissive_glow", 1.0)))
	# COSMOS M5a: register with the single-writer so the current chart table is applied now (snapshot) and
	# on every future flip/reanchor in the SAME pass as the far material (kills near/far table divergence).
	if CubeSphere.M5_RENDER:
		CosmosTruePlace.register_material(m)
	return m

## The SNOW-CAPPED variant render material for `base_id` (M1 ADR §5.3): the snow_block texture
## through the standard textured recipe, tinted `lerp(WHITE, color_of(base_id), 0.18)` — a
## whole-cell reskin toward snow that keeps a subtle base hue. Cached per base id. Used by BOTH
## render paths for a `snow_capped` grass/podzol/sand cell (the module bakes it into snow-variant
## models; the fallback commits the surface with it). Zero new texture assets (reuses snow_block's
## tile); a base id with no snow_block tile falls back to a flat snow-tinted swatch. v2 (top/side
## split) stays deferred (MAX_SURFACES contention).
static func snow_capped_for(base_id: int) -> StandardMaterial3D:
	var cached: StandardMaterial3D = _snow_cache.get(base_id, null)
	if cached != null:
		return cached
	var snow_id := BlockCatalog.id_of(&"snow_block")
	var tex := BlockTextures.texture_for(snow_id)
	var tint: Color = lerp(Color.WHITE, BlockCatalog.color_of(base_id), 0.18)
	var mat: StandardMaterial3D
	if tex != null:
		mat = _textured(tex)
		mat.albedo_color = tint            # tint the (white) snow texture toward the base hue
	else:
		mat = _solid(tint)
	_snow_cache[base_id] = mat
	return mat

## Drop the entire per-id render-material cache (RUNTIME-MATERIAL-STREAMING §2.6 session
## boundary): a fresh session (world-load / peer session) may bind a given dense LRID to a
## DIFFERENT material, so its cached StandardMaterial3D must not persist across a
## `BlockCatalog.reset_session()`. Gameplay never calls this mid-session (LRIDs are stable,
## §7.4) — it pairs with the catalog session reset. The next `get_for` rebuilds fresh looks.
static func reset_cache() -> void:
	_cache.clear()
	_snow_cache.clear()             # snow-cap variants (M1) rebind per session too
	if CubeSphere.M5_RENDER:
		CosmosTruePlace.reset_materials()   # the M5 single-writer fan-out holds the cached materials — clear it too

## Update the EXISTING cached Material for `block_id` in place from the catalog look
## (RUNTIME-MATERIAL-STREAMING §5.3): when an UNRESOLVED placeholder LRID late-resolves
## to a real material, the swatch/emission are swapped into the same StandardMaterial3D
## instance every holder already references (library model override, fallback surface,
## VoxelBody surface) — so the look updates everywhere with no rebake/remesh. A no-op if
## nothing has cached this id yet (the next `get_for` builds it fresh from the real look).
static func refresh(block_id: int) -> void:
	var cached: Material = _cache.get(block_id, null)
	# Bend ShaderMaterials (COSMOS curved mode) have no albedo_color/emission properties; in-place
	# streaming refresh is a StandardMaterial3D-only path (unchanged in the default flat world).
	if cached == null or not (cached is StandardMaterial3D):
		return
	var mat := cached as StandardMaterial3D
	var color := BlockCatalog.color_of(block_id)
	# Flat-swatch materials (no tile, the placeholder + streamed-material case) carry the
	# colour in albedo_color; textured materials tint white and keep the texture.
	if mat.albedo_texture == null:
		mat.albedo_color = color
	var rd := BlockCatalog.render_def_of(block_id)
	if rd.get("emissive", false):
		mat.emission_enabled = true
		mat.emission = Color(color.r, color.g, color.b)
		mat.emission_energy_multiplier = float(rd.get("emissive_glow", 1.0))

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
