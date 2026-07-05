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
