class_name TreeGen
extends RefCounted
## Deterministic tree overlay (DESIGN §3, WORLDGEN-CATALOG §6.7). A tree is
## anchored to one cell of a G x G column grid; jitter keeps the whole tree
## (canopy radius <= 2) inside its grid cell, so any world cell is affected by AT
## MOST the one tree of its own grid cell -> O(1) lookup, no neighbour search.
##
## Everything is hash-of-position (no randi()/randf(), no per-run state), so both
## render paths, reloads, the analytic queries, the ground collider and the
## collapse pass agree by construction. Trees are TERRAIN (generated cells), not
## spawned bodies — chopping a trunk runs the collapse pass which detaches the
## floating canopy as a wood+leaf VoxelBody.
##
## SPECIES (WGC §6.7): the species is a pure function of the base column's biome
## plus one hash — forest = 70% oak / 30% birch, taiga/snowy = spruce, swamp/
## plains = oak; desert/badlands/ocean/beach get NO trees (biome gate). OAK is
## bit-identical to the pre-species generator (same salts 33/44/55, same shape,
## same WOOD/LEAF ids), so existing oak trees never move.

const G := 10                      # tree grid cell size (columns)
const P := 5                       # patch size, in tree-grid cells (=> 50x50 columns)
const PATCH_CHANCE := 0.30         # fraction of patches containing trees
const TREE_CHANCE := 0.45          # per grid cell inside an active patch
const TRUNK_MIN := 4               # oak/birch trunk min
const TRUNK_MAX := 6               # oak/birch trunk max
const SPRUCE_TRUNK_MIN := 5
const SPRUCE_TRUNK_MAX := 8
## Tallest a tree reaches above its base surface (spruce trunk 8 + 1 canopy cap +
## 1 headroom). Widens the collapse scan and collider vertical bounds that read it.
const MAX_ABOVE_SURFACE := 10

# Species enum.
const SP_NONE := 0
const SP_OAK := 1
const SP_BIRCH := 2
const SP_SPRUCE := 3

## Sentinel "no tree" base (y is a deep negative so no world cell ever matches).
const _NO_TREE := Vector3i(0, -0x40000000, 0)

# Cached species material ids (resolved once from the data-driven catalog).
static var _sp_ready := false
static var _SPRUCE_LOG := 0
static var _SPRUCE_LEAF := 0
static var _BIRCH_LOG := 0
static var _BIRCH_LEAF := 0

## Warm the species id cache on the main thread (called from TerrainConfig.warm_up
## so the voxel worker thread never races it into existence).
static func warm_up() -> void:
	if _sp_ready:
		return
	BlockCatalog.ensure_ready()
	_SPRUCE_LOG = BlockCatalog.id_of(&"spruce_log")
	_SPRUCE_LEAF = BlockCatalog.id_of(&"spruce_leaves")
	_BIRCH_LOG = BlockCatalog.id_of(&"birch_log")
	_BIRCH_LEAF = BlockCatalog.id_of(&"birch_leaves")
	_sp_ready = true

## Deterministic hash in [0,1) for an integer lattice + salt (same integer-mix
## family as TexturePackBaker._hash; no floats until the final divide).
static func _hash01(ix: int, iz: int, salt: int) -> float:
	var n := (ix * 374761393 + iz * 668265263 + salt * 362437) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65536.0

## Jittered base column (bx, bz) of the grid cell's tree — pure position, NO
## gating (so has_tree/species can consult the base biome without recursing).
## Offset in [2, 7] keeps a canopy of radius <= 2 inside the 10-wide grid cell.
static func _base_pos(gx: int, gz: int) -> Vector2i:
	var bx := gx * G + 2 + int(_hash01(gx, gz, 33) * float(G - 4))
	var bz := gz * G + 2 + int(_hash01(gx, gz, 44) * float(G - 4))
	return Vector2i(bx, bz)

## Species for the grid cell's tree given its base-column biome (WGC §6.7); the
## forest oak/birch split uses one extra hash. SP_NONE gates the biome out.
static func _species_for(biome: int, gx: int, gz: int) -> int:
	match biome:
		TerrainConfig.B_FOREST:
			return SP_OAK if _hash01(gx, gz, 88) < 0.70 else SP_BIRCH
		TerrainConfig.B_TAIGA, TerrainConfig.B_SNOWY:
			return SP_SPRUCE
		TerrainConfig.B_SWAMP, TerrainConfig.B_PLAINS:
			return SP_OAK
		_:
			return SP_NONE

## True iff grid cell (gx, gz) hosts a tree (patch gate AND per-cell gate AND the
## biome gate). The two cheap hash gates run first, so the biome lookup only fires
## for the ~13% of grid cells that pass them.
static func has_tree(gx: int, gz: int, pcache = null) -> bool:
	var px := floori(float(gx) / float(P))
	var pz := floori(float(gz) / float(P))
	if _hash01(px, pz, 11) >= PATCH_CHANCE:
		return false
	if _hash01(gx, gz, 22) >= TREE_CHANCE:
		return false
	var b := _base_pos(gx, gz)
	return _species_for(TerrainConfig.biome_at(b.x, b.y, pcache), gx, gz) != SP_NONE

## Base of the grid cell's tree: (bx, gy, bz) where gy = ground height of the
## tree's OWN base column. Returns _NO_TREE when the grid cell has no tree.
static func tree_base(gx: int, gz: int) -> Vector3i:
	if not has_tree(gx, gz):
		return _NO_TREE
	var b := _base_pos(gx, gz)
	return Vector3i(b.x, TerrainConfig.height_at(b.x, b.y), b.y)

## Oak/birch trunk height (in blocks) ∈ {TRUNK_MIN..TRUNK_MAX}. Salt 55 is the
## legacy oak salt — unchanged, so oak trunks are bit-identical.
static func _trunk_height(gx: int, gz: int) -> int:
	return TRUNK_MIN + int(_hash01(gx, gz, 55) * 3.0)

static func _spruce_trunk_height(gx: int, gz: int) -> int:
	return SPRUCE_TRUNK_MIN + int(_hash01(gx, gz, 66) * float(SPRUCE_TRUNK_MAX - SPRUCE_TRUNK_MIN + 1))

## WOOD / LEAF / AIR the tree overlay places at world cell (x, y, z). Consults
## ONLY the tree of (x, z)'s own grid cell, and only that tree's base column —
## costs a handful of integer hashes (+ biome lookup for the base when a tree
## exists). Trees whose base is at/below sea level are suppressed (the sea fills
## those cells), so no submerged half-trees poke through the water.
static func block_at(x: int, y: int, z: int, pcache = null) -> int:
	var gx := floori(float(x) / float(G))
	var gz := floori(float(z) / float(G))
	if not has_tree(gx, gz, pcache):
		return BlockCatalog.AIR
	var b := _base_pos(gx, gz)
	var bx := b.x
	var bz := b.y
	var gy := TerrainConfig.column_top(bx, bz, pcache)
	if gy <= TerrainConfig.SEA_LEVEL:
		return BlockCatalog.AIR
	var species := _species_for(TerrainConfig.biome_at(bx, bz, pcache), gx, gz)
	var dx := x - bx
	var dz := z - bz
	match species:
		SP_OAK:
			return _oak_block(gx, gz, dx, y, dz, gy, BlockCatalog.WOOD, BlockCatalog.LEAF)
		SP_BIRCH:
			if not _sp_ready:
				warm_up()
			return _oak_block(gx, gz, dx, y, dz, gy, _BIRCH_LOG, _BIRCH_LEAF)
		SP_SPRUCE:
			if not _sp_ready:
				warm_up()
			return _spruce_block(gx, gz, dx, y, dz, gy)
	return BlockCatalog.AIR

## Oak-shaped tree (also used, with birch ids, for birch): a WOOD trunk column,
## a 3x3-minus-centre canopy ring on the top two trunk layers, and a plus-shaped
## cap one layer above. Byte-identical to the pre-species oak when (log_id,
## leaf_id) == (WOOD, LEAF).
static func _oak_block(gx: int, gz: int, dx: int, y: int, dz: int, gy: int, log_id: int, leaf_id: int) -> int:
	var t := _trunk_height(gx, gz)

	# Trunk: a single log column from gy+1 up to gy+t.
	if dx == 0 and dz == 0:
		if y >= gy + 1 and y <= gy + t:
			return log_id
		# fall through: above the trunk the centre column may still be a cap leaf.

	# Canopy ring layers: the top two trunk layers, 3x3 minus the trunk centre.
	if y == gy + t - 1 or y == gy + t:
		if absi(dx) <= 1 and absi(dz) <= 1 and not (dx == 0 and dz == 0):
			return leaf_id

	# Cap: a plus shape one layer above the trunk top.
	if y == gy + t + 1 and absi(dx) + absi(dz) <= 1:
		return leaf_id

	return BlockCatalog.AIR

## Spruce: a taller trunk (5-8) under a conical, two-tier canopy — a wide radius-2
## skirt on the lower layers narrowing to a radius-1 crown and a single-cell cap.
static func _spruce_block(gx: int, gz: int, dx: int, y: int, dz: int, gy: int) -> int:
	var t := _spruce_trunk_height(gx, gz)
	var top := gy + t

	# Trunk.
	if dx == 0 and dz == 0 and y >= gy + 1 and y <= top:
		return _SPRUCE_LOG

	# Cap.
	if y == top + 1:
		if dx == 0 and dz == 0:
			return _SPRUCE_LEAF
		return BlockCatalog.AIR

	# Crown (narrow): top two trunk layers, radius 1 minus the trunk centre.
	if y == top or y == top - 1:
		if absi(dx) <= 1 and absi(dz) <= 1 and not (dx == 0 and dz == 0):
			return _SPRUCE_LEAF
		return BlockCatalog.AIR

	# Skirt (wide): two lower layers, a radius-2 diamond minus the trunk centre.
	if y == top - 2 or y == top - 3:
		if absi(dx) + absi(dz) <= 2 and not (dx == 0 and dz == 0):
			return _SPRUCE_LEAF

	return BlockCatalog.AIR
