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
## STAGE-1 SCOPE: OPAQUE cubes only. Translucent (glass/ice/stained/tinted, cull_group > 0), emissive (lava) and
## fluid (water/lava fluid models) ids are NOT registered here — `has_cell(id)` returns false for them, so the
## module keeps them on their own per-id material (a SECOND translucent atlas + shaped-family atlas UVs are
## Stage 2+/§2.4-§2.5). Shaped/snow/slope/carve models likewise stay per-material this stage.

# 8×8 grid of 128 px cells = 1024² (design §2.2). 128 px is the TexturePackBaker output tile size, so each opaque
# tile lands in its cell at 1:1 (byte-identical at mip 0 under NEAREST). 1024² RGBA8 = 4 MB (+~1.3 MB mips), POT
# (safe for GL-compatibility / WebGL2 / ANGLE mip generation). The current bootstrap set is 28 distinct opaque
# tiles + 36 opaque swatch-only colours = EXACTLY 64 cells → fills the 8×8 grid. A 65th distinct opaque cell (a
# runtime-streamed material, RMS) finds no cell and gracefully falls back to its own per-id material in the module
# (a residual surface, never a hole — design §5).
const GRID := 8
const CELL_PX := 128
const ATLAS_PX := GRID * CELL_PX     # 1024

var texture: Texture2D = null                 # the baked atlas (ImageTexture)
var image: Image = null                       # the source Image (kept so the verify gate can sample cells)
var material: StandardMaterial3D = null       # the ONE shared opaque atlas material (identity-checked by G-ATLAS-MAT)
var grid := Vector2i(GRID, GRID)              # atlas_size_in_tiles the cube models are configured with
var _cell_of: Dictionary = {}                 # block_id -> Vector2i(col, row); only opaque cubes that got a cell
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
	image.generate_mipmaps()
	texture = ImageTexture.create_from_image(image)
	material = _make_material(texture)
	_built = true
	print("[block_atlas] built %d×%d atlas: %d opaque cube ids → %d cells (%d free) at %d² px" % [
		GRID, GRID, _cell_of.size(), next, GRID * GRID - next, ATLAS_PX])
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

## Fill `cell` with a solid swatch colour (the atlas equivalent of block_materials._solid): a no-tile opaque id
## renders its BlockCatalog colour, baked into a cell so the shared material needs no per-cell albedo_color.
func _paint_swatch(cell: Vector2i, color: Color) -> void:
	var c := Color(color.r, color.g, color.b, 1.0)
	image.fill_rect(Rect2i(cell.x * CELL_PX, cell.y * CELL_PX, CELL_PX, CELL_PX), c)

## The ONE shared opaque atlas material — mirrors block_materials._textured (UNSHADED, white albedo, double-sided,
## NEAREST_WITH_MIPMAPS, vertex_color_use_as_albedo) EXCEPT texture_repeat is CLAMP (design §4.3: repeat would wrap
## a cell's 0..1 UVs into its neighbour; the cube unit-cell UVs are 0..1 within one cell, so clamp is correct).
func _make_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.texture_repeat = false                      # CLAMP (§4.3)
	mat.vertex_color_use_as_albedo = true
	return mat
