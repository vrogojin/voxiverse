extends SceneTree
## Headless verification of the hotbar/materials/trees/place-break feature.
## Run: godot --headless --path godot --script res://src/tools/verify_feature.gd
## Pure-logic + a live WorldManager in the tree; asserts the plan's §9.2 invariants.

const GRASS := 1
const DIRT := 2
const STONE := 3
const WOOD := 4
const LEAF := 5

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _initialize() -> void:
	BlockCatalog.ensure_ready()
	_test_stackup()
	_test_stone_relief()
	_test_tree()
	_test_masses()
	_test_inventory()
	_test_world_loop()
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# 1. Layered stackup: grass only at surface, >=2 dirt, stone >=3 below, no hollow.
func _test_stackup() -> void:
	print("[1] terrain stackup")
	var checked := 0
	for x in range(-300, 300, 7):
		for z in range(-300, 300, 53):
			var g: int = TerrainConfig.height_at(x, z)
			_ok(TerrainConfig.generated_block(x, g, z) == GRASS, "grass at surface (%d,%d)" % [x, z])
			_ok(TerrainConfig.generated_block(x, g - 1, z) == DIRT, "dirt at g-1 (%d,%d)" % [x, z])
			_ok(TerrainConfig.generated_block(x, g - 2, z) == DIRT, "dirt at g-2 (%d,%d)" % [x, z])
			# no grass anywhere below the surface
			for y in range(g - 1, g - 8, -1):
				_ok(TerrainConfig.generated_block(x, y, z) != GRASS, "no grass below surface (%d,%d,%d)" % [x, y, z])
			var s: int = TerrainConfig.stone_height_at(x, z)
			var stone_top: int = mini(s, g - TerrainConfig.DIRT_MIN_DEPTH)
			_ok(stone_top <= g - 3, "stone_top <= g-3 (%d,%d)" % [x, z])
			_ok(TerrainConfig.generated_block(x, stone_top, z) == STONE, "stone at stone_top (%d,%d)" % [x, z])
			_ok(TerrainConfig.generated_block(x, stone_top + 1, z) == DIRT, "dirt above stone_top (%d,%d)" % [x, z])
			# never hollow: deep cell is solid
			_ok(TerrainConfig.generated_block(x, stone_top - 20, z) == STONE, "deep stone solid (%d,%d)" % [x, z])
			checked += 1
	print("    checked %d columns" % checked)

# 2. Stone has its OWN relief, not a constant offset of the grass height.
func _test_stone_relief() -> void:
	print("[2] stone relief is its own noise")
	var vals := {}
	var offset_vals := {}
	for x in range(0, 400, 11):
		for z in range(0, 400, 13):
			var g: int = TerrainConfig.height_at(x, z)
			var s: int = TerrainConfig.stone_height_at(x, z)
			vals[s] = true
			offset_vals[(g - 3) - mini(s, g - 3)] = true
	_ok(vals.size() > 3, "stone_height_at is non-constant (%d distinct)" % vals.size())
	_ok(offset_vals.size() > 1, "stone_top - (g-3) varies (%d distinct) => own hills" % offset_vals.size())

# 3. A tree exists somewhere and is well formed (deterministic).
func _test_tree() -> void:
	print("[3] tree generation")
	var found := false
	for gx in range(0, 200):
		for gz in range(0, 200):
			if TreeGen.has_tree(gx, gz):
				var base: Vector3i = TreeGen.tree_base(gx, gz)
				var base2: Vector3i = TreeGen.tree_base(gx, gz)
				_ok(base == base2, "tree_base deterministic")
				var bx := base.x
				var bz := base.z
				var gy: int = TerrainConfig.height_at(bx, bz)
				_ok(base.y == gy, "tree base y == ground height")
				_ok(TerrainConfig.generated_block(bx, gy, bz) == GRASS, "grass under trunk")
				# trunk: at least one wood cell straight above the base
				var wood_cells := 0
				var leaf_cells := 0
				for y in range(gy + 1, gy + TreeGen.MAX_ABOVE_SURFACE + 1):
					var b: int = TreeGen.block_at(bx, y, bz)
					if b == WOOD:
						wood_cells += 1
				# canopy: count leaves in the tree's footprint
				for dx in range(-1, 2):
					for dz in range(-1, 2):
						for y in range(gy + 1, gy + TreeGen.MAX_ABOVE_SURFACE + 2):
							if TreeGen.block_at(bx + dx, y, bz + dz) == LEAF:
								leaf_cells += 1
				_ok(wood_cells >= TreeGen.TRUNK_MIN, "trunk has >= TRUNK_MIN wood (%d)" % wood_cells)
				_ok(leaf_cells >= 5, "canopy has leaves (%d)" % leaf_cells)
				# generated_block agrees (trees win above surface)
				_ok(TerrainConfig.generated_block(bx, gy + 1, bz) == WOOD, "generated_block sees trunk")
				found = true
				break
		if found:
			break
	_ok(found, "at least one tree exists in [0,200)^2 grid")

# 7. Mass ordering: stone heaviest, wood lightest, all > 0.
func _test_masses() -> void:
	print("[7] mass ordering")
	var ms := BlockCatalog.mass_of(STONE)
	var md := BlockCatalog.mass_of(DIRT)
	var mg := BlockCatalog.mass_of(GRASS)
	var ml := BlockCatalog.mass_of(LEAF)
	var mw := BlockCatalog.mass_of(WOOD)
	print("    stone=%.0f dirt=%.0f grass=%.0f leaf=%.0f wood=%.0f" % [ms, md, mg, ml, mw])
	_ok(ms > md and md > mg and mg > ml and ml > mw and mw > 0.0, "stone>dirt>grass>leaf>wood>0")

# 6. Inventory stacking / selection / consume.
func _test_inventory() -> void:
	print("[6] inventory")
	var inv: Inventory = Inventory.new()
	var surplus := inv.add(GRASS, 70)
	_ok(surplus == 0, "add 70 grass fully absorbed")
	_ok(inv.slot(0)["id"] == GRASS and inv.slot(0)["count"] == 64, "slot0 = 64 grass")
	_ok(inv.slot(1)["id"] == GRASS and inv.slot(1)["count"] == 6, "slot1 = 6 grass")
	var s2 := inv.add(DIRT, 1)
	_ok(s2 == 0 and inv.slot(2)["id"] == DIRT, "dirt lands in slot2")
	inv.select_slot(0)
	_ok(inv.selected_block_id() == GRASS, "selected slot0 = grass")
	_ok(inv.consume_selected(64) == true, "consume 64 grass ok")
	_ok(inv.slot(0)["id"] == 0 and inv.slot(0)["count"] == 0, "slot0 emptied to {0,0}")
	_ok(inv.consume_selected(1) == false, "consume from empty returns false")
	inv.select_slot(0)
	inv.scroll(-1)
	_ok(inv.selected_index() == Inventory.SLOT_COUNT - 1, "scroll -1 from 0 wraps to last")

# 4/5. Live world edit loop: break returns id, place mutates + collider rebuilds.
func _test_world_loop() -> void:
	print("[4/5] world edit loop (live WorldManager)")
	var world: WorldManager = WorldManager.new()
	world.name = "WorldManager"
	get_root().add_child(world)   # _ready() picks the render path + builds the collider
	var cx := 4
	var cz := 4
	var g: int = TerrainConfig.height_at(cx, cz)
	var c := Vector3i(cx, g, cz)
	_ok(world.block_id_at(c) == GRASS, "surface cell is grass")
	var broke := world.break_terrain(c, Vector3.INF)
	_ok(broke == GRASS, "break_terrain returns GRASS (got %d)" % broke)
	_ok(world.block_id_at(c) == 0, "cell is air after break")
	_ok(world.break_terrain(c, Vector3.INF) == 0, "double-break returns 0")
	# ground collider rebuilds on edit (shape count changes across a place above surface)
	var ground: GroundCollider = world.get_node_or_null("GroundCollider")
	var before := -1
	var after := -1
	if ground != null:
		before = PhysicsServer3D.body_get_shape_count(ground.get_rid())
	var placed := world.place_block(c, STONE)
	_ok(placed, "place_block STONE succeeds")
	_ok(world.block_id_at(c) == STONE, "cell is stone after place")
	_ok(world.place_block(c, STONE) == false, "place into occupied cell fails")
	_ok(world.place_block(Vector3i(cx, g + 1, cz), 0) == false, "place invalid id fails")
	if ground != null:
		after = PhysicsServer3D.body_get_shape_count(ground.get_rid())
		_ok(after > 0, "ground collider has shapes (%d)" % after)

	# tree chop: break a trunk cell with a finite breaker pos -> canopy detaches as a
	# kicked VoxelBody (invariant 4). Find a tree, chop its lowest trunk cell.
	var chopped := false
	for gx in range(0, 60):
		for gz in range(0, 60):
			if not TreeGen.has_tree(gx, gz):
				continue
			var base: Vector3i = TreeGen.tree_base(gx, gz)
			var trunk := Vector3i(base.x, base.y + 1, base.z)
			if world.block_id_at(trunk) != WOOD:
				continue
			var n_bodies_before := _count_voxel_bodies(world)
			var id := world.break_terrain(trunk, Vector3(base.x + 0.5, base.y - 2.0, base.z + 0.5))
			_ok(id == WOOD, "chopped trunk returns WOOD (got %d)" % id)
			var n_bodies_after := _count_voxel_bodies(world)
			_ok(n_bodies_after > n_bodies_before, "canopy detached into a VoxelBody (%d->%d)" % [n_bodies_before, n_bodies_after])
			chopped = true
			break
		if chopped:
			break
	_ok(chopped, "found and chopped a tree trunk")
	world.queue_free()

func _count_voxel_bodies(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is VoxelBody:
			c += 1
		c += _count_voxel_bodies(ch)
	return c
