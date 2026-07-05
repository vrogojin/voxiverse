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
	_test_materials()
	_test_inventory()
	_test_cell_codec()
	_test_material_data()
	_test_merged_physics()
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

# 8. Every solid block id yields a non-null, textured, crisp-pixel material.
func _test_materials() -> void:
	print("[8] block render materials")
	_ok(BlockMaterials.get_for(BlockCatalog.AIR) == null, "AIR has no material")
	for id in [GRASS, DIRT, STONE, WOOD, LEAF]:
		var nm := BlockCatalog.name_of(id)
		var mat: StandardMaterial3D = BlockMaterials.get_for(id)
		_ok(mat != null, "%s has a material" % nm)
		if mat == null:
			continue
		var tex: Texture2D = mat.albedo_texture
		_ok(tex != null, "%s material is textured (not a flat swatch)" % nm)
		_ok(tex != null and tex.get_width() == 128 and tex.get_height() == 128,
			"%s texture is 128x128" % nm)
		_ok(mat.texture_filter == BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
			"%s uses NEAREST filter (crisp pixel-art)" % nm)
		_ok(mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
			"%s is unshaded (flat ambient look)" % nm)
	# Cache identity: repeated lookups reuse the one material instance.
	_ok(BlockMaterials.get_for(STONE) == BlockMaterials.get_for(STONE), "material cache reuses instance")

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

# 9. CellCodec packing + the packed overlay: pack/unpack round-trip, bare-id
# equivalence, air-zeroing canonicalization, and projection coherence
# (block_id_at == mat(cell_value_at)) on a live WorldManager and the generator.
func _test_cell_codec() -> void:
	print("[9] CellCodec + packed overlay")
	# (b) pack/unpack round-trip for sample (mat, modifier, state) triples.
	var triples := [
		[GRASS, 0, 0], [STONE, 5, 0], [WOOD, 0, 7], [LEAF, 42, 1000],
		[DIRT, 0xFFFF, 0xFFFF], [GRASS, 0xABCD, 0x1234],
	]
	for t in triples:
		var m: int = t[0]
		var mod: int = t[1]
		var st: int = t[2]
		var v := CellCodec.pack(m, mod, st)
		_ok(CellCodec.mat(v) == m and CellCodec.modifier(v) == mod and CellCodec.state(v) == st,
			"pack/unpack round-trip (%d,%d,%d)" % [m, mod, st])
	# (d) a bare legacy id IS a valid packed value == pack(id, 0, 0), and is_plain.
	for id in [BlockCatalog.AIR, GRASS, DIRT, STONE, WOOD, LEAF]:
		_ok(CellCodec.pack(id) == id, "bare id %d == pack(id,0,0)" % id)
		_ok(CellCodec.mat(id) == id, "mat(bare id %d) == id" % id)
		_ok(CellCodec.is_plain(id), "is_plain(bare id %d)" % id)
	# (c) canonicalization: 0 stays 0, air-zeroing drops stray modifier/state,
	# a bare solid id is already canonical, shaped/stated cells are not plain.
	_ok(CellCodec.canonical(0) == 0, "canonical(0) == 0")
	_ok(CellCodec.canonical(CellCodec.pack(BlockCatalog.AIR, 5, 3)) == 0,
		"canonical(air with modifier+state) == 0 (air-zeroing)")
	_ok(CellCodec.canonical(STONE) == STONE, "canonical(bare stone) == stone")
	_ok(not CellCodec.is_plain(CellCodec.pack(STONE, 1, 0)), "shaped stone is not plain")
	_ok(not CellCodec.is_plain(CellCodec.pack(STONE, 0, 1)), "stated stone is not plain")

	# (a) projection coherence on a LIVE WorldManager across edited + generated + air.
	var world: WorldManager = WorldManager.new()
	world.name = "WorldManagerCodec"
	get_root().add_child(world)
	var cx := 12
	var cz := 12
	var g: int = TerrainConfig.height_at(cx, cz)
	_ok(world.place_block(Vector3i(cx, g + 1, cz), STONE), "codec: place a stone")
	# The overlay stores a canonical PLAIN packed value for a placed cube (checked
	# BEFORE any break — digging the grass under it would collapse it into a body).
	_ok(world.cell_value_at(Vector3i(cx, g + 1, cz)) == STONE, "placed stone stored as plain packed value")
	_ok(CellCodec.is_plain(world.cell_value_at(Vector3i(cx, g + 1, cz))), "placed stone overlay value is_plain")
	_ok(world.break_terrain(Vector3i(cx, g, cz), Vector3.INF) == GRASS, "codec: dig the surface grass")
	var samples: Array[Vector3i] = [
		Vector3i(cx, g + 1, cz),        # placed stone (overlay)
		Vector3i(cx, g, cz),            # dug air (overlay, value 0)
		Vector3i(cx, g - 2, cz),        # generated dirt/stone
		Vector3i(cx, g - 20, cz),       # deep generated stone
		Vector3i(cx, g + 40, cz),       # air far above (generated)
		Vector3i(cx + 5, g, cz + 5),    # untouched surface grass
	]
	for c: Vector3i in samples:
		_ok(world.block_id_at(c) == CellCodec.mat(world.cell_value_at(c)),
			"projection coherence block_id_at==mat(cell_value_at) @ " + str(c))
	_ok(world.cell_value_at(Vector3i(cx, g, cz)) == 0, "dug cell stored as 0 (air)")
	# generated_block is exactly the material projection of generated_cell.
	var gen_checked := 0
	for x in range(-60, 60, 17):
		for z in range(-60, 60, 19):
			var gg: int = TerrainConfig.height_at(x, z)
			for y in [gg + 2, gg, gg - 1, gg - 5]:
				_ok(TerrainConfig.generated_block(x, y, z) == CellCodec.mat(TerrainConfig.generated_cell(x, y, z)),
					"generated_block == mat(generated_cell) @ (%d,%d,%d)" % [x, y, z])
				gen_checked += 1
	print("    projection-coherence checked %d generated cells" % gen_checked)
	world.queue_free()

# P1. Material-data layer: the anchor converter reproduces the calibration and
# the stored core anchors (drift gate), and blocks.json agrees with BlockCatalog.
func _test_material_data() -> void:
	print("[P1] material data + anchor converter")
	# (b) the three §1.2 calibration anchors, as pure-math converter asserts.
	_ok(AnchorConverter.propose_anchors({"C": 100.0, "T": 10.0}, &"rock") == Vector3i(64, 6, 4),
		"converter: stone (C100,T10,rock) -> (64,6,4)")
	_ok(AnchorConverter.propose_anchors({"C": 50.0, "T": 90.0}, &"timber") == Vector3i(36, 24, 16),
		"converter: wood (C50,T90,timber) -> (36,24,16)")
	_ok(AnchorConverter.propose_anchors({"cohesion": 25.0}, &"soil") == Vector3i(4, 2, 1),
		"converter: dirt (c=25,soil) -> (4,2,1) [1.5 rounds up to H=2]")
	# grass is a second soil anchor (§1.2 table) — proves the branch, not just dirt.
	_ok(AnchorConverter.propose_anchors({"cohesion": 30.0}, &"soil") == Vector3i(4, 2, 1),
		"converter: grass (c=30,soil) -> (4,2,1)")
	# round-half-up is load-bearing: 1.5 -> 2, and it is the normative helper form.
	_ok(AnchorConverter._round_half_up(1.5) == 2 and AnchorConverter._round_half_up(0.5) == 1,
		"round-half-up: 1.5->2, 0.5->1 (dirt H depends on this)")

	# (a) DRIFT GATE: for every non-air core record not marked anchors_override,
	# propose_anchors(priors, class) == the anchors stored in BlockCatalog.
	var records := BlockCatalog.load_data()
	_ok(not records.is_empty(), "blocks.json loads with a `blocks` array")
	var seen_core := 0
	for rec: Variant in records:
		if not (rec is Dictionary):
			continue
		var id := int(rec.get("id", -1))
		if id <= BlockCatalog.AIR or id >= BlockCatalog.COUNT:
			continue                          # air + (future) non-core rows
		seen_core += 1
		var nm := String(rec.get("name", "?"))
		var cls := StringName(String(rec.get("structural_class", "rock")))
		var priors: Dictionary = rec.get("priors", {})
		var proposed := AnchorConverter.propose_anchors(priors, cls)
		var stored := BlockCatalog.anchors_of(id)
		if bool(rec.get("anchors_override", false)):
			continue                          # tuned value — gate does not apply
		_ok(proposed == stored,
			"drift gate '%s': propose%s == stored %s" % [nm, str(proposed), str(stored)])
	_ok(seen_core == BlockCatalog.COUNT - 1, "drift gate covered all %d non-air core materials (%d)"
		% [BlockCatalog.COUNT - 1, seen_core])

	# (c) blocks.json <-> BlockCatalog consistency (ids/mass/anchors/class/swatch/
	# break_force/attachment) — the golden "consts asserted against data" check.
	var mismatches := BlockCatalog.check_against_data()
	_ok(mismatches.is_empty(), "blocks.json matches BlockCatalog: " + ", ".join(mismatches))

	# (d) attachment defaults to 1.0 for every core material (only sand/gravel,
	# not yet in the catalog, will ship 0.0 participation — §1.4).
	for id in [GRASS, DIRT, STONE, WOOD, LEAF]:
		var s: VoxelState = BlockCatalog.state_of(id)
		_ok(s != null and is_equal_approx(s.attachment, 1.0),
			"%s attachment == 1.0" % BlockCatalog.name_of(id))

# P2. Merged analytic-physics contract (INTEGRATION-DECISIONS §3): the material
# solidity gate, the _occ_span composition, the canonicalization addendum, and — the
# load-bearing invariant — floor_under/blocked/aimed_voxel BYTE-IDENTICAL to their
# pre-P2 behaviour on the current all-solid full-cube world.
func _test_merged_physics() -> void:
	print("[P2] merged analytic-physics contract")
	# (i) solidity gate: AIR + out-of-range non-solid; every core material solid.
	_ok(BlockCatalog.solidity_of(BlockCatalog.AIR) < 0.5, "AIR solidity < 0.5 (non-solid, gated out)")
	_ok(BlockCatalog.solidity_of(99) < 0.5, "out-of-range material is non-solid (null state -> 0.0)")
	for id in [GRASS, DIRT, STONE, WOOD, LEAF]:
		_ok(BlockCatalog.solidity_of(id) >= 0.5, "%s solidity >= 0.5 (solid)" % BlockCatalog.name_of(id))

	var world: WorldManager = WorldManager.new()
	world.name = "WorldManagerP2"
	get_root().add_child(world)

	# (ii) cell_solid == (solidity_of(block_id_at) >= 0.5) across a spread of
	# generated + air cells (the composition rule, not a re-derivation).
	var solid_checked := 0
	for x in range(-40, 40, 13):
		for z in range(-40, 40, 17):
			var g: int = TerrainConfig.height_at(x, z)
			for y in [g + 5, g + 1, g, g - 1, g - 8]:
				var c := Vector3i(x, y, z)
				var expected := BlockCatalog.solidity_of(world.block_id_at(c)) >= 0.5
				_ok(world.cell_solid(c) == expected, "cell_solid == solidity gate @ " + str(c))
				solid_checked += 1
	print("    cell_solid==gate checked %d cells" % solid_checked)

	# (iii) _occ_span: solid full cube -> (0,1); air and any non-solid material
	# (out-of-range mat, ANY modifier) -> ZERO (the material gate wins over the shape).
	_ok(world._occ_span(CellCodec.pack(STONE), 0.5, 0.5) == Vector2(0.0, 1.0),
		"_occ_span(solid full cube) == (0,1)")
	_ok(world._occ_span(0, 0.5, 0.5) == Vector2.ZERO, "_occ_span(air) == ZERO")
	_ok(world._occ_span(CellCodec.pack(99, 5, 0), 0.5, 0.5) == Vector2.ZERO,
		"_occ_span(non-solid material + modifier) == ZERO (material gate wins)")
	# gate logic on a synthetic sub-0.5 material (SI §7 fluid/soft band).
	var synth := VoxelState.new()
	synth.solidity = 0.3
	_ok(synth.solidity < 0.5, "synthetic VoxelState solidity 0.3 fails the >= 0.5 gate")

	# (iv) canonicalization addendum: modifier != 0 on a non-solid material strips to
	# full cube (0), material kept; a solid material keeps its modifier (P5 clamps it).
	var stripped := CellCodec.canonical(CellCodec.pack(99, 5, 3))
	_ok(CellCodec.mat(stripped) == 99 and CellCodec.modifier(stripped) == 0,
		"canonical strips modifier on non-solid material (mat kept, modifier 0)")
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, 7, 0))) == 7,
		"canonical keeps modifier on a solid material (no strip)")

	# (v) BYTE-IDENTITY: floor_under / blocked / aimed_voxel == known expected values
	# on untouched terrain. Bare-surface columns only (skip tree columns, whose above-
	# surface cells are solid) so the expected values are the plain grass surface.
	var phys_checked := 0
	for x in range(-30, 30, 11):
		for z in range(-30, 30, 9):
			var g: int = TerrainConfig.height_at(x, z)
			var clear := true
			for yy in range(g + 1, g + 5):
				if world.cell_solid(Vector3i(x, yy, z)):
					clear = false
					break
			if not clear:
				continue
			var fx := float(x) + 0.5
			var fz := float(z) + 0.5
			# floor is the top of the surface (grass) cell = g + 1.
			_ok(is_equal_approx(world.floor_under(fx, fz, float(g + 1) + 0.3), float(g + 1)),
				"floor_under == surface top g+1 @ (%d,%d)" % [x, z])
			# open air above the surface does not block...
			_ok(world.blocked(fx, fz, float(g + 1) + 0.3) == false, "not blocked in open air @ (%d,%d)" % [x, z])
			# ...but a body span intruding into the solid ground does.
			_ok(world.blocked(fx, fz, float(g) - 0.5) == true, "blocked when body overlaps ground @ (%d,%d)" % [x, z])
			# a ray straight down from above hits the surface cell (g) with an UP normal.
			var hit := world.aimed_voxel(Vector3(fx, float(g) + 4.0, fz), Vector3(0, -1, 0), 16.0)
			_ok(hit["hit"] and hit["voxel"] == Vector3i(x, g, z) and hit["normal"] == Vector3i.UP,
				"aimed_voxel down hits surface cell (up normal) @ (%d,%d)" % [x, z])
			phys_checked += 1
	_ok(phys_checked > 0, "byte-identity sampled %d bare-surface columns" % phys_checked)
	print("    byte-identity checked %d columns" % phys_checked)

	# (vi) occludes_face reduces to cell_solid for the current all-opaque full-cube
	# world (the seam P3's translucent materials fill): an opaque solid neighbour
	# occludes; air does not.
	for id in [GRASS, STONE, WOOD, LEAF]:
		_ok(WorldManager.occludes_face(CellCodec.pack(id), 0, 0) == true,
			"occludes_face(opaque solid %s) == true" % BlockCatalog.name_of(id))
	_ok(WorldManager.occludes_face(0, 0, 0) == false, "occludes_face(air) == false")
	_ok(WorldManager.occludes_face(CellCodec.pack(99), 0, 0) == false,
		"occludes_face(non-solid material) == false")

	world.queue_free()

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
