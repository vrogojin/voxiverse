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

# block id -> tile file stem under DIR. AIR (0) has no texture. Keep in lock-step
# with BlockCatalog ids; the catalog-parity workstream extends both together.
const TILES := {
	BlockCatalog.GRASS: "grass",
	BlockCatalog.DIRT: "dirt",
	BlockCatalog.STONE: "stone",
	BlockCatalog.WOOD: "wood",
	BlockCatalog.LEAF: "leaf",
}

## Absolute res:// path to the tile for `block_id`, or "" if none is mapped.
static func path_for(block_id: int) -> String:
	var stem: String = TILES.get(block_id, "")
	return "" if stem == "" else "%s/%s.png" % [DIR, stem]

## Loaded Texture2D for `block_id`, or null if unmapped / not on disk.
static func texture_for(block_id: int) -> Texture2D:
	var p := path_for(block_id)
	return null if p == "" else load(p) as Texture2D
