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
## Tallest a tree reaches above its base surface. Widens the collapse scan and collider
## vertical bounds that read it. Raised 10→14 for the B1 jungle tree (trunk ≤ 11 + 2 canopy
## layers + 1 cap): a wider scan bound is safe for every shorter species (worldgen bytes are
## unaffected — this bounds the collapse/collider scan, not generated_cell), and jungle trees
## only exist under CubeSphere.FP_CLIMATE_BIOMES anyway.
const MAX_ABOVE_SURFACE := 14

# Species enum. SP_ACACIA/SP_JUNGLE/SP_CACTUS are the B1 climate-biome species (appended;
# only ever selected under CubeSphere.FP_CLIMATE_BIOMES — see _species_for).
const SP_NONE := 0
const SP_OAK := 1
const SP_BIRCH := 2
const SP_SPRUCE := 3
const SP_ACACIA := 4
const SP_JUNGLE := 5
const SP_CACTUS := 6

# --- B1 climate-biome tree tuning (design §6.4) -------------------------------
const JUNGLE_TRUNK_MIN := 8         # dense, tall rainforest tree
const JUNGLE_TRUNK_MAX := 11
const ACACIA_TRUNK_MIN := 4         # short, flat-topped savanna tree
const ACACIA_TRUNK_MAX := 6
const CACTUS_MIN := 1              # a 1×1 column, height 1..3 (very sparse)
const CACTUS_MAX := 3
const ACACIA_DENSITY := 0.5        # fraction of eligible savanna cells that actually host an acacia (sparse)
const CACTUS_DENSITY := 0.3        # ...and of desert cells that host a cactus (very sparse)

## Sentinel "no tree" base (y is a deep negative so no world cell ever matches).
const _NO_TREE := Vector3i(0, -0x40000000, 0)

# Cached species material ids (resolved once from the data-driven catalog).
static var _sp_ready := false
static var _SPRUCE_LOG := 0
static var _SPRUCE_LEAF := 0
static var _BIRCH_LOG := 0
static var _BIRCH_LEAF := 0
static var _JUNGLE_LOG := 0     # B1 climate-biome species ids
static var _JUNGLE_LEAF := 0
static var _ACACIA_LOG := 0
static var _ACACIA_LEAF := 0
static var _CACTUS := 0

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
	_JUNGLE_LOG = BlockCatalog.id_of(&"jungle_log")
	_JUNGLE_LEAF = BlockCatalog.id_of(&"jungle_leaves")
	_ACACIA_LOG = BlockCatalog.id_of(&"acacia_log")
	_ACACIA_LEAF = BlockCatalog.id_of(&"acacia_leaves")
	_CACTUS = BlockCatalog.id_of(&"cactus")
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
	# COSMOS CLIMATE-BIOMES B1 (design §6.4): the new species are FLAG-GATED. B_DESERT already exists in the
	# shipped world and must stay TREE-FREE when the flag is off (byte-identity), so the desert→cactus mapping
	# lives here rather than in the match above; jungle/savanna biomes only exist under the flag at all. Acacia
	# and cactus thin their patches with an extra hash so savanna/desert stay sparse (dry, open look).
	if CubeSphere.FP_CLIMATE_BIOMES:
		match biome:
			TerrainConfig.B_JUNGLE:
				return SP_JUNGLE
			TerrainConfig.B_SAVANNA:
				return SP_ACACIA if _hash01(gx, gz, 124) < ACACIA_DENSITY else SP_NONE
			TerrainConfig.B_DESERT:
				return SP_CACTUS if _hash01(gx, gz, 125) < CACTUS_DENSITY else SP_NONE
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
		SP_JUNGLE:
			if not _sp_ready:
				warm_up()
			return _jungle_block(gx, gz, dx, y, dz, gy)
		SP_ACACIA:
			if not _sp_ready:
				warm_up()
			return _acacia_block(gx, gz, dx, y, dz, gy)
		SP_CACTUS:
			if not _sp_ready:
				warm_up()
			return _cactus_block(gx, gz, dx, y, dz, gy)
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

## B1 climate-biome tree trunk heights (pure position hashes; TreeGen-owned salts 121/122).
static func _jungle_trunk_height(gx: int, gz: int) -> int:
	return JUNGLE_TRUNK_MIN + int(_hash01(gx, gz, 121) * float(JUNGLE_TRUNK_MAX - JUNGLE_TRUNK_MIN + 1))

static func _acacia_trunk_height(gx: int, gz: int) -> int:
	return ACACIA_TRUNK_MIN + int(_hash01(gx, gz, 122) * float(ACACIA_TRUNK_MAX - ACACIA_TRUNK_MIN + 1))

## Jungle: a tall (8-11) jungle_log column under a dense two-tier canopy — a wide radius-2 (5×5)
## block on the top two trunk layers narrowing to a radius-1 plus cap. Radius ≤ 2 keeps the whole
## tree inside its 10-wide grid cell (the O(1) one-tree-per-cell invariant), like spruce.
static func _jungle_block(gx: int, gz: int, dx: int, y: int, dz: int, gy: int) -> int:
	var t := _jungle_trunk_height(gx, gz)
	var top := gy + t

	# Trunk.
	if dx == 0 and dz == 0 and y >= gy + 1 and y <= top:
		return _JUNGLE_LOG

	# Wide canopy: top two trunk layers, a full radius-2 square minus the trunk centre.
	if y == top or y == top - 1:
		if absi(dx) <= 2 and absi(dz) <= 2 and not (dx == 0 and dz == 0):
			return _JUNGLE_LEAF
		return BlockCatalog.AIR

	# Cap: a plus one layer above the trunk top.
	if y == top + 1 and absi(dx) + absi(dz) <= 1:
		return _JUNGLE_LEAF

	return BlockCatalog.AIR

## Acacia: a short (4-6) acacia_log trunk under a FLAT radius-2 canopy disc (the savanna umbrella look)
## with a small plus cap. Deliberately thin foliage (one flat layer) so savanna reads open, not forested.
static func _acacia_block(gx: int, gz: int, dx: int, y: int, dz: int, gy: int) -> int:
	var t := _acacia_trunk_height(gx, gz)
	var top := gy + t

	# Trunk.
	if dx == 0 and dz == 0 and y >= gy + 1 and y <= top:
		return _ACACIA_LOG

	# Flat top: one radius-2 square layer at the trunk top minus the trunk centre.
	if y == top:
		if absi(dx) <= 2 and absi(dz) <= 2 and not (dx == 0 and dz == 0):
			return _ACACIA_LEAF
		return BlockCatalog.AIR

	# Cap: a plus one layer above (the umbrella's crown).
	if y == top + 1 and absi(dx) + absi(dz) <= 1:
		return _ACACIA_LEAF

	return BlockCatalog.AIR

## Cactus: a 1×1 cactus column, height 1..3 (salt 123). No canopy — the cheapest possible "tree".
static func _cactus_block(gx: int, gz: int, dx: int, y: int, dz: int, gy: int) -> int:
	if dx != 0 or dz != 0:
		return BlockCatalog.AIR
	var h := CACTUS_MIN + int(_hash01(gx, gz, 123) * float(CACTUS_MAX - CACTUS_MIN + 1))
	if y >= gy + 1 and y <= gy + h:
		return _CACTUS
	return BlockCatalog.AIR
