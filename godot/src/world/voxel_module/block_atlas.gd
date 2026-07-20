class_name BlockAtlas
extends RefCounted
## COSMOS-ATLAS Stage 0/1 (docs/COSMOS-ATLAS-DESIGN.md §2) — the OPAQUE texture atlas + ONE shared opaque material.
##
## Every OPAQUE terrain block id today has its OWN StandardMaterial3D (block_materials.gd), and VoxelMesherBlocky
## emits one surface (= one draw call) per distinct material per 32³ mesh block, so materials MULTIPLY the draw
## count. This builder packs every distinct opaque block-face TILE (and every opaque swatch-only colour) into ONE
## padded grid texture behind ONE shared opaque `StandardMaterial3D`, and exposes a per-(block-id) → atlas-cell map.
## `module_world._add_cube` (under CubeSphere.FP_ATLAS_MATERIAL) then routes every opaque cube onto that shared
## material with per-face `set_tile(cell)` instead of a per-id `set_material_override`, so the mesher MERGES all
## opaque cubes in a block into ONE surface.
##
## Deterministic + baked ONCE at module_world.setup() on the MAIN thread (next to _configure_library); never per
## frame / per crossing. Pure GDScript (no godot_voxel dependency) — safe to load on the fallback path too.
##
## STAGE-2 SCOPE (docs/COSMOS-ATLAS-DESIGN.md §2.4/§2.6): the OPAQUE CUBE cells (Stage 1) PLUS the snow-CAP variant
## cells the shaped families need. The module routes the DOMINANT opaque shaped/composite families — dry corner-height
## shapes, snow-cap cubes+shapes, snow LAYER depth, snow-FILL composites — onto this ONE shared material by baking
## atlas-remapped UVs into per-(cell, modifier) ArrayMeshes (module_world._atlas_shape_mesh).
## DELIBERATELY per-material (residual surfaces): the SHARP-SLOPE family — atlassing it would bake ~5160 distinct
## per-(cell,payload) meshes (~5.9 MB) for a MINORITY steep-terrain surface, over the NEVER-OOM ≤-few-MB budget — so
## slopes keep the shipped shared-`_shape_mesh_cache` per-material path (a residual slope surface only where sharp
## slopes appear). Also per-material (later stages): translucent (glass/ice/stained/tinted, cull_group > 0), emissive
## (lava), fluid (water/lava) models — the Stage-3 translucent atlas; the seam carve SENTINELS (the C++ carve clip's
## cut-face UVs are unverifiable headless); and the fluid-bearing waterlog/wet twins. `has_cell(id)` stays false for
## every non-opaque-cube id.

# 16×16 grid of 64 px cells = 1024² (design §2.2, Stage-2 expansion). Stage 1 was 8×8×128 px (also 1024²): the OPAQUE
# CUBE set is EXACTLY 64 look-keys (28 distinct tiles + 36 swatch colours) which FILLED the 8×8 grid, so Stage 2 —
# which adds the shaped-family cells (§2.6: the 4 snow-CAP tinted variants, and headroom for any future per-face /
# composite tile) — must GROW the grid. 16×16 = 256 cells is the smallest POT square that fits 64 + the new cells; to
# keep the atlas ≤ 4 MB (NEVER-OOM: memory-neutral to Stage 1) the cell drops to 64 px. The TexturePackBaker output is
# a 16 px source upscaled ×8 to 128 px; a 64 px cell is that same 16 px art at a clean ×4 (128→64 is an exact 2:1
# NEAREST halve), so under NEAREST filtering the on-screen result is pixel-identical to Stage 1 at mip 0 (only one
# fewer mip level). 1024² RGBA8 = 4 MB (+~1.3 MB mips), POT (safe for GL-compatibility / WebGL2 / ANGLE mip
# generation). A cell beyond the 256th (only if the opaque look-key count ever exceeds 256) finds no cell and falls
# back to its own per-id material in the module (a residual surface, never a hole — design §5).
const GRID := 16
const CELL_PX := 64
const ATLAS_PX := GRID * CELL_PX     # 1024

# The snow-cap base-hue tint (M1 ADR §5.3 / BlockMaterials.snow_capped_for): the snow_block tile multiplied by
# lerp(WHITE, base_colour, SNOW_CAP_TINT). Baked here (per cappable base) so a shaped snow-VARIANT model can ride the
# ONE shared atlas material — the tint that lived in the per-variant material's albedo_color moves into the cell.
const SNOW_CAP_TINT := 0.18

var texture: Texture2D = null                 # the baked atlas (ImageTexture)
var image: Image = null                       # the source Image (kept so the verify gate can sample cells)
var material: Material = null                 # the ONE shared opaque atlas material (StandardMaterial3D, or the B3 ShaderMaterial twin under FP_NEAR_DAYLIGHT; identity-checked by G-ATLAS-MAT)

# COSMOS ATMO2 B3 (docs/COSMOS-ATMO2-DESIGN.md §2.3/§3.3): the near-field daylight TWIN of the shared atlas
# material. Keeps vertex-colour×texture EXACTLY (UNSHADED base, white albedo, double-sided, nearest-mipmap +
# CLAMP) and multiplies an absolute day/night shade(μ), μ = normalize(world_pos)·ŝ (planet centre = scene origin
# under the fixed frame, §1). shade=1 at noon ⇒ ALBEDO byte-equal to the shipped StandardMaterial output; the
# night side dims to night_floor so the near ground goes dark exactly as the far shell does. sun_dir fed each
# frame (set_near_daylight_sun_dir). gl_compat-safe (no loops/derivatives). StandardMaterial fallback = flag off.
const _NEAR_DAYLIGHT_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D atlas_tex : source_color, filter_nearest_mipmap, repeat_disable;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.10;
uniform float term_mu = 0.12;
uniform float moonshine = 0.0;
varying vec3 v_wp;
varying vec4 v_col;
void vertex() { v_col = COLOR; v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
void fragment() {
	vec3 n = normalize(v_wp);
	float mu = dot(n, normalize(sun_dir));
	float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);
	vec4 t = texture(atlas_tex, UV);
	ALBEDO = v_col.rgb * t.rgb * shade;
	ALPHA = t.a;
}
"
var grid := Vector2i(GRID, GRID)              # atlas_size_in_tiles the cube models are configured with
var _cell_of: Dictionary = {}                 # block_id -> Vector2i(col, row); only opaque cubes that got a cell
var _snow_cap_cell: Dictionary = {}           # base block_id -> Vector2i; the snow-CAP variant cell (Stage 2, §2.6)
var _built := false

## True iff `block_id` is an OPAQUE cube (the atlas Stage-1 set): a solid whose render mode is "opaque" — NOT
## translucent (cull_group > 0), NOT emissive (lava), NOT AIR. Water/lava render as fluid models, and both are
## translucent/emissive respectively, so they are excluded here too. Static so callers (module + gate) agree.
static func is_opaque_cube(block_id: int) -> bool:
	if block_id <= BlockCatalog.AIR:
		return false
	var rd := BlockCatalog.render_def_of(block_id)
	return String(rd.get("mode", "")) == "opaque"

## The atlas cell (col,row) for an opaque cube id, or Vector2i(-1,-1) if it has none (non-opaque, or the grid was
## full when it was reached). Consumed by module_world._add_cube (which passes it to set_tile) + the gate.
func cell_of(block_id: int) -> Vector2i:
	return _cell_of.get(block_id, Vector2i(-1, -1))

func has_cell(block_id: int) -> bool:
	return _cell_of.has(block_id)

## The snow-CAP variant atlas cell for a cappable base material (Stage 2, §2.6), or Vector2i(-1,-1) if none.
## Consumed by module_world's snow-variant + composite + slope-twin builders (which pass it to the shaped-UV remap).
func snow_cap_cell_of(base_id: int) -> Vector2i:
	return _snow_cap_cell.get(base_id, Vector2i(-1, -1))

func has_snow_cap_cell(base_id: int) -> bool:
	return _snow_cap_cell.has(base_id)

## Every cappable base id that received a snow-cap cell (for the gate's coverage sweep over the shaped set).
func snow_cap_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for id: int in _snow_cap_cell.keys():
		out.append(id)
	return out

## The [0,1]² UV rectangle a given atlas cell (col,row) spans (cell / grid) — the target rect the shaped-family UV
## remap folds a model's unit-cell UVs into. The gate cross-checks that every baked shaped UV lands inside it.
func rect_of_cell(cell: Vector2i) -> Rect2:
	if cell.x < 0 or cell.y < 0:
		return Rect2()
	return Rect2(float(cell.x) / GRID, float(cell.y) / GRID, 1.0 / GRID, 1.0 / GRID)

## The UV-space rectangle a face configured with this id's cell samples (cell / grid), in [0,1]². The cube model's
## bake() turns set_atlas_size_in_tiles(grid)+set_tile(cell) into exactly these UVs; the gate cross-checks it.
func cell_uv_rect(block_id: int) -> Rect2:
	var c: Vector2i = cell_of(block_id)
	if c.x < 0:
		return Rect2()
	return Rect2(float(c.x) / GRID, float(c.y) / GRID, 1.0 / GRID, 1.0 / GRID)

## Every opaque cube id that received an atlas cell (for the gate's coverage sweep).
func celled_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for id: int in _cell_of.keys():
		out.append(id)
	return out

## Build the atlas image + shared material + per-id cell map. Deterministic; idempotent. Returns true if at least
## one opaque cube was placed (so the module can route it); false leaves the module fully on the per-id path.
func build() -> bool:
	if _built:
		return not _cell_of.is_empty()
	BlockCatalog.ensure_ready()
	image = Image.create(ATLAS_PX, ATLAS_PX, true, Image.FORMAT_RGBA8)   # mipmaps=true (generated below)
	image.fill(Color(0, 0, 0, 0))
	# One cell PER distinct look-key: textured ids share a cell by tile stem (grass/dirt/…); swatch-only ids share
	# a cell by colour. So coarse_dirt+dirt collapse to one dirt cell, and two ids of the same swatch colour share.
	var key_cell := {}                              # look-key String -> Vector2i(col,row)
	var next := 0
	var total := BlockCatalog.count()
	for id in range(1, total):
		if not is_opaque_cube(id):
			continue
		var stem: String = BlockTextures.TILES.get(StringName(BlockCatalog.name_of(id)), "")
		var key: String
		if stem != "":
			key = "tile:" + stem
		else:
			key = "swatch:" + BlockCatalog.color_of(id).to_html(true)
		var cell: Vector2i
		if key_cell.has(key):
			cell = key_cell[key]
		else:
			if next >= GRID * GRID:
				# Grid full — leave this id with no cell (module keeps its per-id material: a residual surface,
				# never a hole). Only reachable if the opaque look-key count ever exceeds GRID² (currently 64).
				push_warning("[block_atlas] atlas full (%d cells) — id %d (%s) keeps its own material" % [GRID * GRID, id, key])
				continue
			cell = Vector2i(next % GRID, next / GRID)
			key_cell[key] = cell
			next += 1
			if stem != "":
				_paint_tile(cell, "%s/%s.png" % [BlockTextures.DIR, stem])
			else:
				_paint_swatch(cell, BlockCatalog.color_of(id))
		_cell_of[id] = cell

	# Stage 2 (§2.6): the snow-CAP variant cells. A base material's snow-capped look is the snow_block tile multiplied
	# by lerp(WHITE, base_colour, 0.18) — a per-material albedo tint the shared atlas material cannot carry, so it is
	# BAKED into its own cell (the snow texel × the base tint). Same-tint bases share a cell. The snow_block stem
	# (opaque cube) already has a plain-snow cell above; these are the TINTED siblings. The base set is the UNION of the
	# snow-CAP materials (snow-variant cubes/shapes/slope twins → snow_capped_for) AND the snow-FILL materials (the
	# composite surface-0 capped ramp is snow_capped_for over snow_fill_materials — which adds snow_block itself).
	var snow_stem: String = BlockTextures.TILES.get(&"snow_block", "")
	var cap_bases := {}
	for m in TerrainConfig.snow_cappable_materials():
		cap_bases[m] = true
	for m in TerrainConfig.snow_fill_materials():
		cap_bases[m] = true
	for base in cap_bases.keys():
		if base <= BlockCatalog.AIR or base >= total:
			continue
		var tint: Color = lerp(Color.WHITE, BlockCatalog.color_of(base), SNOW_CAP_TINT)
		var ckey := "snowcap:" + tint.to_html(true)
		var scell: Vector2i
		if key_cell.has(ckey):
			scell = key_cell[ckey]
		else:
			if next >= GRID * GRID:
				push_warning("[block_atlas] atlas full (%d cells) — snow-cap base %d keeps its own material" % [GRID * GRID, base])
				continue
			scell = Vector2i(next % GRID, next / GRID)
			key_cell[ckey] = scell
			next += 1
			if snow_stem != "":
				_paint_tinted_tile(scell, "%s/%s.png" % [BlockTextures.DIR, snow_stem], tint)
			else:
				_paint_swatch(scell, tint)
		_snow_cap_cell[base] = scell

	image.generate_mipmaps()
	texture = ImageTexture.create_from_image(image)
	material = _make_material(texture)
	_built = true
	print("[block_atlas] built %d×%d atlas: %d opaque cube ids + %d snow-cap variants → %d cells (%d free) at %d² px" % [
		GRID, GRID, _cell_of.size(), _snow_cap_cell.size(), next, GRID * GRID - next, ATLAS_PX])
	return not _cell_of.is_empty()

## Blit the source tile PNG (128² TexturePackBaker output) into `cell`, 1:1 (byte-identical at mip 0). Decompresses
## a VRAM-compressed import + resizes (NEAREST, pixel-art) if the tile is not exactly CELL_PX — defensive; the pack
## is 128². On any load failure the cell stays transparent and G-ATLAS-COVER catches it.
func _paint_tile(cell: Vector2i, path: String) -> void:
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		push_warning("[block_atlas] tile missing: %s" % path)
		return
	var src: Image = tex.get_image()
	if src == null:
		return
	if src.is_compressed():
		src.decompress()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	if src.get_width() != CELL_PX or src.get_height() != CELL_PX:
		src.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_NEAREST)
	image.blit_rect(src, Rect2i(0, 0, CELL_PX, CELL_PX), Vector2i(cell.x * CELL_PX, cell.y * CELL_PX))

## Blit the source tile PNG multiplied per-pixel by `tint` (the atlas equivalent of block_materials.snow_capped_for:
## a textured material with albedo_color = tint over the snow_block tile — final unshaded colour = texel × tint, with
## vertex colour white on the shaped models). Same decompress/convert/resize hygiene as _paint_tile.
func _paint_tinted_tile(cell: Vector2i, path: String, tint: Color) -> void:
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		push_warning("[block_atlas] snow-cap tile missing: %s" % path)
		return
	var src: Image = tex.get_image()
	if src == null:
		return
	if src.is_compressed():
		src.decompress()
	if src.get_format() != Image.FORMAT_RGBA8:
		src.convert(Image.FORMAT_RGBA8)
	if src.get_width() != CELL_PX or src.get_height() != CELL_PX:
		src.resize(CELL_PX, CELL_PX, Image.INTERPOLATE_NEAREST)
	for y in CELL_PX:
		for x in CELL_PX:
			var p: Color = src.get_pixel(x, y)
			src.set_pixel(x, y, Color(p.r * tint.r, p.g * tint.g, p.b * tint.b, p.a))
	image.blit_rect(src, Rect2i(0, 0, CELL_PX, CELL_PX), Vector2i(cell.x * CELL_PX, cell.y * CELL_PX))

## Fill `cell` with a solid swatch colour (the atlas equivalent of block_materials._solid): a no-tile opaque id
## renders its BlockCatalog colour, baked into a cell so the shared material needs no per-cell albedo_color.
func _paint_swatch(cell: Vector2i, color: Color) -> void:
	var c := Color(color.r, color.g, color.b, 1.0)
	image.fill_rect(Rect2i(cell.x * CELL_PX, cell.y * CELL_PX, CELL_PX, CELL_PX), c)

## The ONE shared opaque atlas material — mirrors block_materials._textured (UNSHADED, white albedo, double-sided,
## NEAREST_WITH_MIPMAPS, vertex_color_use_as_albedo) EXCEPT texture_repeat is CLAMP (design §4.3: repeat would wrap
## a cell's 0..1 UVs into its neighbour; the cube unit-cell UVs are 0..1 within one cell, so clamp is correct).
func _make_material(tex: Texture2D) -> Material:
	# COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): the near-field daylight ShaderMaterial twin (keeps vertex-colour×texture
	# EXACTLY, multiplies the absolute day/night shade). Off ⇒ the shipped StandardMaterial verbatim (byte-identical).
	if CubeSphere.FP_NEAR_DAYLIGHT:
		var sh := Shader.new()
		sh.code = _NEAR_DAYLIGHT_SHADER
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("atlas_tex", tex)
		sm.set_shader_parameter("night_floor", CosmosSky.NEAR_NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", CosmosSky.TERMINATOR_MU)
		sm.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		return sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.texture_repeat = false                      # CLAMP (§4.3)
	mat.vertex_color_use_as_albedo = true
	return mat

## COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): feed the current Sun direction into the near-field daylight twin each
## frame (forwarded from CosmosSky via module_world/WorldManager). No-op unless the flag is on and the material
## is the ShaderMaterial twin ⇒ flag-off is byte-identical (never wired; the StandardMaterial path is untouched).
func set_near_daylight_sun_dir(sun_dir: Vector3) -> void:
	if not CubeSphere.FP_NEAR_DAYLIGHT:
		return
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter("sun_dir", sun_dir)
