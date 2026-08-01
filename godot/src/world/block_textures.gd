class_name BlockTextures
extends RefCounted
## Data-driven block-id -> texture-file map (the only place a block id is tied to a
## surface texture). BlockMaterials builds the render material from here; the sim
## layer (SurfaceModel) reads the same path for the grass swatch — one owner, so
## the world, placed blocks, detached bodies and the sim never disagree on a look.
##
## Textures live in res://assets/textures/pack/<name>.png — the enhanced CC0 tiles
## produced by TexturePackBaker (see docs/TEXTURES.md). Adding a block is a one-line
## entry here (plus a spec row in TexturePackBaker); nothing else changes. The file
## name IS the stable material key the runtime-material-streaming workstream can
## content-address on, so keep names material-descriptive, not id-numeric.

const DIR := "res://assets/textures/pack"

# Material NAME -> tile file stem under DIR (the stable, id-independent key the doc
# calls for: the file name IS the material key). AIR has no texture. Multiple materials
# may share a stem (coarse_dirt reuses dirt; the stained/tinted glass variants reuse the
# glass pane and get their colour from the material tint; powder_snow reuses snow_block;
# dark_oak_leaves reuse the oak leaf). A material with NO entry falls back to its flat
# BlockCatalog swatch (WGC §5, docs/TEXTURES.md). Extend by baking a tile + a row here.
const TILES := {
	# core
	&"grass": "grass", &"dirt": "dirt", &"stone": "stone", &"wood": "wood", &"leaf": "leaf",
	# stones
	&"bedrock": "bedrock", &"deepslate": "deepslate", &"granite": "granite",
	&"diorite": "diorite", &"andesite": "andesite", &"tuff": "tuff", &"calcite": "calcite",
	&"dripstone_block": "dripstone_block", &"sandstone": "sandstone",
	&"obsidian": "obsidian", &"amethyst_block": "amethyst_block",
	# soils / surface
	&"coarse_dirt": "dirt", &"mud": "mud", &"sand": "sand", &"gravel": "gravel",
	&"snow_block": "snow_block", &"powder_snow": "snow_block",
	# cryo
	&"ice": "ice",
	# tree species (oak = core wood/leaf; dark_oak/cherry have no CC0 tile -> swatch)
	&"spruce_log": "spruce_log", &"spruce_leaves": "spruce_leaves",
	&"birch_log": "birch_log", &"birch_leaves": "birch_leaves",
	&"jungle_log": "jungle_log", &"jungle_leaves": "jungle_leaves",
	&"acacia_log": "acacia_log", &"acacia_leaves": "acacia_leaves",
	&"dark_oak_leaves": "leaf",
	# glass family (one baked pane; the material tint colours the stained/tinted variants)
	&"glass": "glass", &"tinted_glass": "glass",
	&"white_stained_glass": "glass", &"red_stained_glass": "glass",
	&"blue_stained_glass": "glass", &"green_stained_glass": "glass",
}

## Absolute res:// path to the tile for `block_id`, or "" if none is mapped.
static func path_for(block_id: int) -> String:
	var stem: String = TILES.get(StringName(BlockCatalog.name_of(block_id)), "")
	return "" if stem == "" else "%s/%s.png" % [DIR, stem]

## Loaded Texture2D for `block_id`, or null if unmapped / not on disk.
static func texture_for(block_id: int) -> Texture2D:
	var p := path_for(block_id)
	return null if p == "" else load(p) as Texture2D

# FP_SKIN_TEXTURE_MEAN palette cache: tile stem -> average tile colour (computed once per stem).
static var _mean_cache := {}

## The MEAN colour of a block's texture tile (the colour the near TEXTURED block averages to on screen), so the
## far §2V skin — which otherwise paints the flat BlockCatalog swatch — can present the SAME colour as the near
## field. Fully-transparent texels (leaf/glass cutouts) are skipped. Falls back to the flat swatch when the block
## has no tile or the image can't be read. Cached per stem (≤ ~24 tiles). Used only under FP_SKIN_TEXTURE_MEAN.
static func mean_color_of(block_id: int) -> Color:
	var swatch := BlockCatalog.color_of(block_id)
	var stem: String = TILES.get(StringName(BlockCatalog.name_of(block_id)), "")
	if stem == "":
		return swatch                                   # no tile → the flat swatch (unchanged)
	if _mean_cache.has(stem):
		return _mean_cache[stem]
	var col := swatch
	var tex := load("%s/%s.png" % [DIR, stem]) as Texture2D
	if tex != null:
		var img := tex.get_image()
		if img != null:
			if img.is_compressed():
				img = img.duplicate()
				img.decompress()
			var w := img.get_width()
			var h := img.get_height()
			var sx := maxi(1, w / 32)
			var sy := maxi(1, h / 32)                   # subsample ≤ ~32×32 per tile (cheap, one-shot)
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var n := 0.0
			for y in range(0, h, sy):
				for x in range(0, w, sx):
					var c := img.get_pixel(x, y)
					if c.a < 0.5:
						continue                        # skip cutout texels (leaves/glass)
					r += c.r
					g += c.g
					b += c.b
					n += 1.0
			if n >= 1.0:
				col = Color(r / n, g / n, b / n, 1.0)
	_mean_cache[stem] = col
	return col
