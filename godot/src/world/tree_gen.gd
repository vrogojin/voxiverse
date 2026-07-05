class_name TreeGen
extends RefCounted
## Deterministic tree overlay (DESIGN §3). A tree is anchored to one cell of a
## G x G column grid; jitter keeps the whole tree (canopy radius 1) inside its
## grid cell, so any world cell is affected by AT MOST the one tree of its own
## grid cell → O(1) lookup, no neighbour search.
##
## Everything is hash-of-position (no randi()/randf(), no per-run state), so both
## render paths, reloads, the analytic queries, the ground collider and the
## collapse pass agree by construction. Trees are TERRAIN (generated cells), not
## spawned bodies — chopping a trunk runs the collapse pass which detaches the
## floating canopy as a wood+leaf VoxelBody.

const G := 10                      # tree grid cell size (columns)
const P := 5                       # patch size, in tree-grid cells (=> 50x50 columns)
const PATCH_CHANCE := 0.30         # fraction of patches containing trees
const TREE_CHANCE := 0.45          # per grid cell inside an active patch
const TRUNK_MIN := 4
const TRUNK_MAX := 6
const MAX_ABOVE_SURFACE := 7       # trunk max 6 + 1 canopy cap layer

## Sentinel "no tree" base (y is a deep negative so no world cell ever matches).
const _NO_TREE := Vector3i(0, -0x40000000, 0)

## Deterministic hash in [0,1) for an integer lattice + salt (same integer-mix
## family as TexturePackBaker._hash; no floats until the final divide).
static func _hash01(ix: int, iz: int, salt: int) -> float:
	var n := (ix * 374761393 + iz * 668265263 + salt * 362437) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65536.0

## True iff grid cell (gx, gz) hosts a tree (patch gate AND per-cell gate).
static func has_tree(gx: int, gz: int) -> bool:
	var px := floori(float(gx) / float(P))
	var pz := floori(float(gz) / float(P))
	if _hash01(px, pz, 11) >= PATCH_CHANCE:
		return false
	return _hash01(gx, gz, 22) < TREE_CHANCE

## Base of the grid cell's tree: (bx, gy, bz) where gy = ground height of the
## tree's OWN base column. Returns _NO_TREE when the grid cell has no tree.
static func tree_base(gx: int, gz: int) -> Vector3i:
	if not has_tree(gx, gz):
		return _NO_TREE
	# Jitter clamped so the canopy (±1) stays inside the grid cell: offset ∈ [2, 7].
	var bx := gx * G + 2 + int(_hash01(gx, gz, 33) * float(G - 4))
	var bz := gz * G + 2 + int(_hash01(gx, gz, 44) * float(G - 4))
	var gy := TerrainConfig.height_at(bx, bz)
	return Vector3i(bx, gy, bz)

## Trunk height (in blocks) for the grid cell's tree ∈ {TRUNK_MIN..TRUNK_MAX}.
static func _trunk_height(gx: int, gz: int) -> int:
	return TRUNK_MIN + int(_hash01(gx, gz, 55) * 3.0)

## WOOD / LEAF / AIR the tree overlay places at world cell (x, y, z). Consults
## ONLY the tree of (x, z)'s own grid cell, and only that tree's base column —
## costs a handful of integer hashes (+1 height_at for the base when a tree
## exists). Cheap enough for the ground collider's per-cell scan.
static func block_at(x: int, y: int, z: int) -> int:
	var gx := floori(float(x) / float(G))
	var gz := floori(float(z) / float(G))
	if not has_tree(gx, gz):
		return BlockCatalog.AIR
	var base := tree_base(gx, gz)
	var bx := base.x
	var bz := base.z
	var gy := base.y
	var t := _trunk_height(gx, gz)
	var dx := x - bx
	var dz := z - bz

	# Trunk: a single WOOD column from gy+1 up to gy+t.
	if dx == 0 and dz == 0:
		if y >= gy + 1 and y <= gy + t:
			return BlockCatalog.WOOD
		# fall through: above the trunk the centre column may still be a cap leaf.

	# Canopy ring layers (LEAF): the top two trunk layers, 3x3 minus the trunk centre.
	if y == gy + t - 1 or y == gy + t:
		if absi(dx) <= 1 and absi(dz) <= 1 and not (dx == 0 and dz == 0):
			return BlockCatalog.LEAF

	# Cap (LEAF): a plus shape one layer above the trunk top.
	if y == gy + t + 1 and absi(dx) + absi(dz) <= 1:
		return BlockCatalog.LEAF

	return BlockCatalog.AIR
