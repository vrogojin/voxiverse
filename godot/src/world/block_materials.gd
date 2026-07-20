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

# COSMOS ATMO2 B3 (docs/COSMOS-ATMO2-DESIGN.md §2.3/§3.3 C-NEAR): every near-field daylight ShaderMaterial twin
# built under FP_NEAR_DAYLIGHT is registered here so set_near_daylight_sun_dir can feed the Sun into all of them
# each frame (both render paths + VoxelBody debris share this one static cache). Empty when the flag is off ⇒
# the setter is a no-op ⇒ byte-identical.
static var _daylight_twins: Array[ShaderMaterial] = []

# The near-field daylight shader twins (ATMO2 B3): they MIRROR the shipped unshaded StandardMaterial3D looks
# (_textured/_solid/_translucent) EXACTLY — same vertex-colour × texture × albedo output — and multiply the
# absolute day/night shade(μ), μ = normalize(world_pos)·ŝ (planet centre = scene origin under the fixed frame).
# shade=1 at noon ⇒ ALBEDO byte-equal to the StandardMaterial output; the night side dims to the night floor so
# the near ground darkens exactly as the far shell does. sun_dir fed each frame (set_near_daylight_sun_dir). The
# shade kernel is the CPU CosmosSky.near_shade twin (same NEAR_NIGHT_FLOOR/TERMINATOR_MU). gl_compat-safe (no
# loops/derivatives). The StandardMaterial path (flag off) is the permanent P3 fallback (any compile failure ⇒
# flag off ⇒ the shipped unshaded material verbatim).
#
# OPAQUE twin (_textured / _solid, + emissive lava): cull_disabled (both shipped looks are CULL_DISABLED), REPEAT
# (the fallback mesher tiles one texture per world-metre), vertex-colour × albedo × texture. Emission is added
# post-shade (unshaded EMISSION), so lava keeps its glow at night while its diffuse darkens.
const _NEAR_DAYLIGHT_OPAQUE_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.10;
uniform float term_mu = 0.12;
uniform float moonshine = 0.0;
varying vec3 v_wp;
varying vec4 v_col;
void vertex() { v_col = COLOR; v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
void fragment() {
	vec3 nrm = normalize(v_wp);
	float mu = dot(nrm, normalize(sun_dir));
	float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);
	vec4 base = albedo_color;
	if (use_vertex_color) { base *= v_col; }
	if (use_texture) { base *= texture(albedo_tex, UV); }
	ALBEDO = base.rgb * shade;
	EMISSION = emission_color * emission_energy;
}
"

# TRANSLUCENT twin (_translucent: glass/water/ice) — alpha-blended with a depth pre-pass (== TRANSPARENCY_ALPHA_
# DEPTH_PRE_PASS), vertex-colour OFF (placed panes keep their authored tint), REPEAT texture when present. Two
# cull variants mirror the shipped material: water is double-sided (cull_disabled), glass/ice cull_back.
const _NEAR_DAYLIGHT_TRANSLUCENT_DS_SHADER := "shader_type spatial;
render_mode unshaded, depth_prepass_alpha, cull_disabled;
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.10;
uniform float term_mu = 0.12;
uniform float moonshine = 0.0;
varying vec3 v_wp;
void vertex() { v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
void fragment() {
	vec3 nrm = normalize(v_wp);
	float mu = dot(nrm, normalize(sun_dir));
	float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);
	vec4 base = albedo_color;
	if (use_texture) { base *= texture(albedo_tex, UV); }
	ALBEDO = base.rgb * shade;
	ALPHA = base.a;
}
"
const _NEAR_DAYLIGHT_TRANSLUCENT_BACK_SHADER := "shader_type spatial;
render_mode unshaded, depth_prepass_alpha, cull_back;
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.10;
uniform float term_mu = 0.12;
uniform float moonshine = 0.0;
varying vec3 v_wp;
void vertex() { v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
void fragment() {
	vec3 nrm = normalize(v_wp);
	float mu = dot(nrm, normalize(sun_dir));
	float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);
	vec4 base = albedo_color;
	if (use_texture) { base *= texture(albedo_tex, UV); }
	ALBEDO = base.rgb * shade;
	ALPHA = base.a;
}
"

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
		# COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): the near-field unshaded material carries the absolute day/night
		# shade twin (keeps vertex-colour × texture EXACTLY, multiplies shade(μ)). Off ⇒ the shipped
		# StandardMaterial3D verbatim (byte-identical); on ⇒ the ShaderMaterial twin of the SAME look.
		if CubeSphere.FP_NEAR_DAYLIGHT:
			mat = _standard_daylight(block_id)
		else:
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

## COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): the near-field DAYLIGHT twin of _standard — the SAME per-id look
## (textured / flat-swatch / translucent, optional lava emission) rebuilt as a ShaderMaterial that multiplies
## the absolute day/night shade(μ) onto the diffuse. Keeps vertex-colour × texture × albedo EXACTLY at noon
## (shade=1) ⇒ the day look is byte-preserved; the night side darkens to the near night floor. Only built when
## FP_NEAR_DAYLIGHT is on (never on the flag-off path ⇒ byte-identical). Registered for the per-frame sun_dir feed.
static func _standard_daylight(block_id: int) -> ShaderMaterial:
	var tex := BlockTextures.texture_for(block_id)
	var rd := BlockCatalog.render_def_of(block_id)
	var color := BlockCatalog.color_of(block_id)
	var mat: ShaderMaterial
	if rd.get("translucent", false):
		mat = _daylight_translucent(tex, color, block_id == BlockCatalog.id_of(&"water"))
	elif tex != null:
		# textured: albedo white, vertex colour on, texture — matches _textured.
		mat = _daylight_opaque(tex, Color(1, 1, 1), true)
	else:
		# flat swatch: albedo = colour, vertex colour on — matches _solid.
		mat = _daylight_opaque(null, color, true)
	if rd.get("emissive", false) and not rd.get("translucent", false):
		mat.set_shader_parameter("emission_color", Color(color.r, color.g, color.b))
		mat.set_shader_parameter("emission_energy", float(rd.get("emissive_glow", 1.0)))
	return mat

## Build one OPAQUE near-daylight twin (_textured / _solid look). `tex` null ⇒ flat swatch (no texture).
## `albedo` is the base albedo_color (white for a textured block, the swatch colour for a no-tile block).
## Registered in _daylight_twins for the per-frame sun_dir feed.
static func _daylight_opaque(tex: Texture2D, albedo: Color, use_vertex_color: bool) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = _NEAR_DAYLIGHT_OPAQUE_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
		m.set_shader_parameter("use_texture", true)
	else:
		m.set_shader_parameter("use_texture", false)
	m.set_shader_parameter("albedo_color", albedo)
	m.set_shader_parameter("use_vertex_color", use_vertex_color)
	m.set_shader_parameter("night_floor", CosmosSky.NEAR_NIGHT_FLOOR)
	m.set_shader_parameter("term_mu", CosmosSky.TERMINATOR_MU)
	m.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
	_daylight_twins.append(m)
	return m

## Build one TRANSLUCENT near-daylight twin (_translucent look): alpha-blended + depth pre-pass, vertex colour
## OFF, `color` carries the RGBA tint+alpha, optional texture. `double_sided` (water) ⇒ cull_disabled, else
## (glass/ice) cull_back — mirroring the shipped material's culling exactly.
static func _daylight_translucent(tex: Texture2D, color: Color, double_sided: bool) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = _NEAR_DAYLIGHT_TRANSLUCENT_DS_SHADER if double_sided else _NEAR_DAYLIGHT_TRANSLUCENT_BACK_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
		m.set_shader_parameter("use_texture", true)
	else:
		m.set_shader_parameter("use_texture", false)
	m.set_shader_parameter("albedo_color", color)
	m.set_shader_parameter("night_floor", CosmosSky.NEAR_NIGHT_FLOOR)
	m.set_shader_parameter("term_mu", CosmosSky.TERMINATOR_MU)
	m.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
	_daylight_twins.append(m)
	return m

## COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): feed the current Sun direction into EVERY near-field daylight twin (both
## render paths + VoxelBody debris share this static cache). No-op unless the flag is on (nothing registered ⇒
## the twins never exist) ⇒ byte-identical. Forwarded from CosmosSky via WorldManager (world_manager.gd).
static func set_near_daylight_sun_dir(sun_dir: Vector3) -> void:
	if not CubeSphere.FP_NEAR_DAYLIGHT:
		return
	for m in _daylight_twins:
		if m != null:
			m.set_shader_parameter("sun_dir", sun_dir)

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
static func snow_capped_for(base_id: int) -> Material:
	var cached: Material = _snow_cache.get(base_id, null)
	if cached != null:
		return cached
	var snow_id := BlockCatalog.id_of(&"snow_block")
	var tex := BlockTextures.texture_for(snow_id)
	var tint: Color = lerp(Color.WHITE, BlockCatalog.color_of(base_id), 0.18)
	var mat: Material
	# COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): the snow-cap variant is a near-field unshaded material too, so it
	# carries the daylight shade twin. The tint (albedo_color) rides the twin's albedo_color uniform, keeping
	# texel × tint × vertex-colour EXACTLY at noon. Off ⇒ the shipped StandardMaterial3D verbatim (byte-identical).
	if CubeSphere.FP_NEAR_DAYLIGHT:
		mat = _daylight_opaque(tex, tint, true)   # tint the (white) snow texture toward the base hue
	elif tex != null:
		var sm := _textured(tex)
		sm.albedo_color = tint            # tint the (white) snow texture toward the base hue
		mat = sm
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
	_daylight_twins.clear()         # ATMO2 B3: the near-daylight twins are held by the cleared caches — drop them too
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
