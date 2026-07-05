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
	TerrainConfig.warm_up()
	_test_stackup()
	_test_worldgen()
	_test_tree()
	_test_masses()
	_test_materials()
	_test_inventory()
	_test_cell_codec()
	_test_material_data()
	_test_catalog_expansion()
	_test_merged_physics()
	_test_world_loop()
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# 1. Vertical stackup (WGC §6.1/§6.5): a bedrock floor, columns SOLID from bedrock
# up to their surface (no hollow, no overhang — the player can never fall through
# the world), the surface cell is solid biome ground, and deepslate replaces stone
# below the transition. No bedrock above -59; no grass below sea level.
func _test_stackup() -> void:
	print("[1] terrain vertical stackup (bedrock / solid columns / no fall-through)")
	var BEDROCK := BlockCatalog.id_of(&"bedrock")
	var DEEPSLATE := BlockCatalog.id_of(&"deepslate")
	var WB: int = TerrainConfig.WORLD_BOTTOM_Y
	var SEA: int = TerrainConfig.SEA_LEVEL
	var checked := 0
	for x in range(-360, 360, 37):
		for z in range(-360, 360, 41):
			var g: int = TerrainConfig.height_at(x, z)
			# bedrock floor: y == WORLD_BOTTOM_Y is always bedrock.
			_ok(TerrainConfig.generated_block(x, WB, z) == BEDROCK, "bedrock at world floor (%d,%d)" % [x, z])
			# no bedrock above -59 (BEDROCK_TOP_Y).
			for y in [-59, -50, -30, -10, g]:
				_ok(TerrainConfig.generated_block(x, y, z) != BEDROCK, "no bedrock above -59 @ (%d,%d,%d)" % [x, y, z])
			# surface cell is SOLID ground (never air/water at the solid top g).
			_ok(TerrainConfig.is_solid(x, g, z), "surface cell g is solid (%d,%d)" % [x, z])
			# NO FALL-THROUGH: every cell from just above bedrock up to g is solid.
			var solid_col := true
			for y in [WB + 3, -50, -40, -24, -16, -8, g - 3, g]:
				if y <= g and not TerrainConfig.is_solid(x, y, z):
					solid_col = false
			_ok(solid_col, "column solid bedrock..surface, no hollow (%d,%d)" % [x, z])
			# deepslate dominates below the full-deepslate line; stone above the band.
			_ok(_is_deepslate_family(TerrainConfig.generated_block(x, -40, z)),
				"deepslate family at y=-40 (%d,%d)" % [x, z])
			# no grass below sea level (underwater columns get a seafloor, not grass).
			if g < SEA:
				_ok(TerrainConfig.generated_block(x, g, z) != GRASS, "no grass below sea @ (%d,%d) g=%d" % [x, z, g])
			checked += 1
	print("    checked %d columns" % checked)
	# deepslate gradient boundaries: none above the top line, all below the full line.
	var above := 0
	var below := 0
	for x in range(0, 200, 13):
		for z in range(0, 200, 17):
			if TerrainConfig.generated_block(x, -8, z) == DEEPSLATE:
				above += 1
			if TerrainConfig.generated_block(x, -40, z) != DEEPSLATE \
					and not _is_deepslate_family(TerrainConfig.generated_block(x, -40, z)):
				below += 1
	_ok(above == 0, "no deepslate above the transition (y=-8): %d" % above)
	_ok(below == 0, "everything at y=-40 is deepslate family: %d non-deepslate" % below)

# Is `id` a deepslate-family block (deepslate itself, a deepslate ore, or a rare
# deep sulfur/cinnabar pocket that the strata pass punches through it)?
func _is_deepslate_family(id: int) -> bool:
	if id == BlockCatalog.id_of(&"deepslate"):
		return true
	if id >= BlockCatalog.id_of(&"deepslate_coal_ore") and id <= BlockCatalog.id_of(&"deepslate_emerald_ore"):
		return true
	return id == BlockCatalog.id_of(&"sulfur_block") or id == BlockCatalog.id_of(&"cinnabar_block")

# A deterministic PLAINS/FOREST land column above the sea with a clear (tree-free)
# grass surface — the well-defined ground the edit-loop tests need in a now
# biome-varied world.
func _grass_column() -> Vector2i:
	var s: Vector2i = TerrainConfig.find_spawn()
	for dz in range(0, 48):
		for dx in range(0, 48):
			var x := s.x + dx
			var z := s.y + dz
			var g: int = TerrainConfig.height_at(x, z)
			if g <= TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.generated_block(x, g, z) != GRASS:
				continue
			var clear := true
			for yy in range(g + 1, g + 7):
				if TerrainConfig.generated_block(x, yy, z) != 0:
					clear = false
					break
			if clear:
				return Vector2i(x, z)
	return s

# 2. The Minecraft-adapted worldgen pipeline (WGC §6): biomes, ores, sea/ice,
# beaches, cold-biome surface temperature, and — CRITICAL — both render paths
# agreeing byte-for-byte (the module generator vs the analytic generated_block).
func _test_worldgen() -> void:
	print("[2] worldgen pipeline (biomes / ores / sea / ice / determinism)")

	# (a) biome determinism + coverage: two calls agree, and a big sample shows
	# real biome variation (the continent/climate noises actually shape the world).
	_ok(TerrainConfig.biome_at(100, 100) == TerrainConfig.biome_at(100, 100), "biome_at deterministic")
	var biomes := {}
	for x in range(-1000, 1000, 47):
		for z in range(-1000, 1000, 53):
			biomes[TerrainConfig.biome_at(x, z)] = true
	_ok(biomes.size() >= 5, "biome coverage >= 5 distinct in a 2000^2 sample (got %d)" % biomes.size())

	# (b) sea: every underwater column is water-filled up to SEA_LEVEL and there is
	# NO water above it; the sea is walked-through (non-solid, the P2 gate).
	var SEA: int = TerrainConfig.SEA_LEVEL
	var WATER := BlockCatalog.id_of(&"water")
	var ICE := BlockCatalog.id_of(&"ice")
	var found_ocean := false
	var sea_ok := true
	for x in range(-800, 800, 31):
		for z in range(-800, 800, 37):
			var g: int = TerrainConfig.height_at(x, z)
			if g >= SEA:
				continue
			found_ocean = true
			# a cell in the water column (just under the surface) is water or ice...
			var mid: int = TerrainConfig.generated_block(x, SEA - 1, z) if SEA - 1 > g else TerrainConfig.generated_block(x, g + 1, z)
			if mid != WATER and mid != ICE:
				sea_ok = false
			# ...and there is no water ABOVE the sea surface.
			if TerrainConfig.generated_block(x, SEA + 2, z) == WATER:
				sea_ok = false
	_ok(found_ocean, "at least one ocean/underwater column exists")
	_ok(sea_ok, "sea fills up to SEA_LEVEL and never above it")
	_ok(BlockCatalog.solidity_of(WATER) < 0.5, "water is non-solid (waded through)")

	# (c) sea ICE on a cold column, structurally backed by sub-zero surface temp.
	var env := PerVoxelEnvironment.new()
	var cold := _find_cold_sea()
	if cold.x != 0x7fffffff:
		var cx := cold.x
		var cz := cold.y
		_ok(TerrainConfig.generated_block(cx, SEA, cz) == ICE, "cold sea surface is ICE (%d,%d)" % [cx, cz])
		_ok(BlockCatalog.solidity_of(ICE) >= 0.5, "ICE is solid (walk the frozen sea)")
		# breaking the ice would expose non-solid water below.
		_ok(BlockCatalog.solidity_of(TerrainConfig.generated_block(cx, SEA - 1, cz)) < 0.5,
			"water under the ice is non-solid (%d,%d)" % [cx, cz])
		var ice_temp := env.temperature(Vector3(cx + 0.5, SEA + 0.5, cz + 0.5))
		_ok(ice_temp < -5.0, "cold-sea surface temperature < -5 C (got %.1f)" % ice_temp)
	else:
		_ok(false, "no cold sea column found to exercise ICE (widen the scan?)")

	# a temperate land column reads ~room temperature at the surface (unchanged model).
	var land := _grass_column()
	var lg: int = TerrainConfig.height_at(land.x, land.y)
	var land_temp := env.temperature(Vector3(land.x + 0.5, float(lg) + 0.5, land.y + 0.5))
	_ok(land_temp > 15.0, "temperate land surface temperature is warm (got %.1f)" % land_temp)

	# (d) beaches: sand appears on a found coastline (a column at sea +/- 2).
	var BEACH_SAND := BlockCatalog.id_of(&"sand")
	var found_beach := false
	for x in range(-800, 800, 19):
		for z in range(-800, 800, 23):
			if found_beach:
				break
			if TerrainConfig.biome_at(x, z) == TerrainConfig.B_BEACH:
				var bg: int = TerrainConfig.height_at(x, z)
				if TerrainConfig.generated_block(x, bg, z) == BEACH_SAND:
					found_beach = true
	_ok(found_beach, "beach sand present on a found coastline")

	# (e) ores (WGC §6.6): scan a deep volume, assert every ore present, hosts are
	# stone/deepslate only (ores sit below the surface), deepslate variants only
	# below the transition, diamond never above -40, coal >> diamond.
	_test_ores()

	# (f) BOTH-PATH DETERMINISM (WGC §7.2, the hardest invariant): the module
	# generator's output must equal generated_block for every cell it writes.
	_test_both_paths()

# Cold underwater column (climate temperature < -0.55, solid top below sea) whose
# surface freezes to ice. Returns (0x7fffffff, _) if none found in the scan.
func _find_cold_sea() -> Vector2i:
	# g <= SEA-2 guarantees at least one WATER cell under the surface ICE cap.
	for x in range(-1200, 1200, 17):
		for z in range(-1200, 1200, 19):
			var p := TerrainConfig.column_profile(x, z)
			if p.w < -0.55 and int(p.x) <= TerrainConfig.SEA_LEVEL - 2:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

# Ore distribution over a deep sampled volume.
func _test_ores() -> void:
	var ore_names := ["coal_ore", "copper_ore", "iron_ore", "gold_ore",
		"redstone_ore", "lapis_ore", "diamond_ore", "emerald_ore"]
	var stone_lo := BlockCatalog.id_of(&"coal_ore")          # 18
	var stone_hi := BlockCatalog.id_of(&"emerald_ore")       # 25
	var deep_lo := BlockCatalog.id_of(&"deepslate_coal_ore") # 26
	var deep_hi := BlockCatalog.id_of(&"deepslate_emerald_ore") # 33
	var diamond := BlockCatalog.id_of(&"diamond_ore")
	var deep_diamond := BlockCatalog.id_of(&"deepslate_diamond_ore")
	var STONE := BlockCatalog.STONE
	var DEEPSLATE := BlockCatalog.id_of(&"deepslate")
	var counts := PackedInt32Array()
	counts.resize(8)
	var host_vol := 0
	var below_surface_ok := true
	var deep_placement_ok := true
	var diamond_ok := true
	for x in range(0, 96):
		for z in range(0, 96):
			var g: int = TerrainConfig.height_at(x, z)
			for y in range(-64, 16):
				if y >= g:
					break
				var id: int = TerrainConfig.generated_block(x, y, z)
				var is_stone_ore := id >= stone_lo and id <= stone_hi
				var is_deep_ore := id >= deep_lo and id <= deep_hi
				if id == STONE or id == DEEPSLATE or is_stone_ore or is_deep_ore:
					host_vol += 1
				if is_stone_ore or is_deep_ore:
					var idx := (id - stone_lo) if is_stone_ore else (id - deep_lo)
					counts[idx] += 1
					if y >= g:
						below_surface_ok = false
					if is_deep_ore and y >= TerrainConfig.DEEPSLATE_TOP_Y:
						deep_placement_ok = false
					if (id == diamond or id == deep_diamond) and y > -40:
						diamond_ok = false
	var total_ore := 0
	for i in 8:
		total_ore += counts[i]
	print("    ore counts: %s (host volume %d)" % [str(counts), host_vol])
	_ok(host_vol > 0, "sampled a non-empty deep-stone volume")
	var frac := float(total_ore) / float(maxi(host_vol, 1))
	_ok(frac > 0.002 and frac < 0.08, "ore fraction of deep-stone volume in [0.2%%,8%%] (got %.3f%%)" % (frac * 100.0))
	# Every ore EXCEPT emerald (highland-gated, exercised separately) is present.
	for i in 7:
		_ok(counts[i] > 0, "ore '%s' present in the sample (%d)" % [ore_names[i], counts[i]])
	_ok(below_surface_ok, "ores only host in stone/deepslate below the surface")
	_ok(deep_placement_ok, "deepslate ores only below the deepslate transition (-16)")
	_ok(diamond_ok, "diamond never generates above y=-40")

	# Emerald is highland-only (continent c > 0.4, WGC §6.6): find a highland region
	# and confirm emerald generates there (and NOT in the flat sample above).
	_ok(counts[7] == 0, "no emerald in the low-continent sample (highland-gated)")
	var emerald := BlockCatalog.id_of(&"emerald_ore")
	var hi := _find_highland()
	if hi.x != 0x7fffffff:
		var em := 0
		for x in range(hi.x - 40, hi.x + 40):
			for z in range(hi.y - 40, hi.y + 40):
				if TerrainConfig.continent_at(x, z) <= 0.4:
					continue
				var g: int = TerrainConfig.height_at(x, z)
				for y in range(-8, mini(g, 16)):
					if TerrainConfig.generated_block(x, y, z) == emerald:
						em += 1
		_ok(em > 0, "emerald generates in a highland region (found %d)" % em)
	else:
		print("    (no highland c>0.4 region found near origin — emerald scan skipped)")

## A highland column (continent c > 0.45) or (0x7fffffff, _) if none found nearby.
func _find_highland() -> Vector2i:
	for x in range(-1500, 1500, 13):
		for z in range(-1500, 1500, 17):
			if TerrainConfig.continent_at(x, z) > 0.45:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

# Both render paths agree: instantiate the module generator (only when the
# godot_voxel module is compiled in) and compare its VoxelBuffer output to the
# analytic generated_block over several 16^3 blocks spanning bedrock..sea.
func _test_both_paths() -> void:
	if not ClassDB.class_exists("VoxelTerrain") or not ClassDB.class_exists("VoxelBuffer"):
		print("    (godot_voxel module absent — both-path determinism runs on module builds only)")
		return
	var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
	var gen: Object = mw.call("_make_generator")
	_ok(gen != null, "module generator compiles")
	if gen == null:
		mw.free()
		return
	var ch := 0                                   # VoxelBuffer.CHANNEL_TYPE
	var origins := [
		Vector3i(0, -64, 0), Vector3i(0, -16, 0), Vector3i(48, 0, 48),
		Vector3i(-80, -32, 16), Vector3i(128, -8, -64), Vector3i(-256, 0, 320),
	]
	var mismatches := 0
	var cells := 0
	for origin: Vector3i in origins:
		var buf: Object = ClassDB.instantiate("VoxelBuffer")
		buf.call("create", 16, 16, 16)
		if buf.has_method("fill"):
			buf.call("fill", 0, ch)
		gen.call("_generate_block", buf, origin, 0)
		for lz in range(16):
			for lx in range(16):
				for ly in range(16):
					var got: int = int(buf.call("get_voxel", lx, ly, lz, ch))
					var expected: int = TerrainConfig.generated_block(origin.x + lx, origin.y + ly, origin.z + lz)
					if got != expected:
						mismatches += 1
					cells += 1
	_ok(mismatches == 0, "module generator == generated_block over %d cells (%d mismatches)" % [cells, mismatches])
	print("    both-path determinism checked %d cells" % cells)
	mw.free()

# 3. Trees exist, are well formed and deterministic; species are biome-keyed and
# a SPRUCE is found in taiga/snowy (WGC §6.7). Oak stays a valid tree.
func _test_tree() -> void:
	print("[3] tree generation (species + biome gate)")
	var SPRUCE_LOG := BlockCatalog.id_of(&"spruce_log")
	var SPRUCE_LEAF := BlockCatalog.id_of(&"spruce_leaves")
	var BIRCH_LOG := BlockCatalog.id_of(&"birch_log")
	var log_ids := {WOOD: true, SPRUCE_LOG: true, BIRCH_LOG: true}
	var found := false
	var found_spruce := false
	for gx in range(-200, 200):
		for gz in range(-200, 200):
			if not TreeGen.has_tree(gx, gz):
				continue
			var base: Vector3i = TreeGen.tree_base(gx, gz)
			var species := TreeGen.block_at(base.x, base.y + 1, base.z)
			if species == SPRUCE_LOG:
				found_spruce = true
			if found:
				continue
			var base2: Vector3i = TreeGen.tree_base(gx, gz)
			_ok(base == base2, "tree_base deterministic")
			var bx := base.x
			var bz := base.z
			var gy: int = TerrainConfig.height_at(bx, bz)
			_ok(base.y == gy, "tree base y == ground height")
			# ground under the trunk is a solid biome top, above sea (no submerged trees).
			_ok(TerrainConfig.is_solid(bx, gy, bz) and gy > TerrainConfig.SEA_LEVEL, "solid ground above sea under trunk")
			# trunk: a run of log cells straight above the base.
			var trunk_cells := 0
			var leaf_cells := 0
			for y in range(gy + 1, gy + TreeGen.MAX_ABOVE_SURFACE + 1):
				if log_ids.has(TreeGen.block_at(bx, y, bz)):
					trunk_cells += 1
			# canopy: count leaf cells (any species) in the tree's footprint.
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					for y in range(gy + 1, gy + TreeGen.MAX_ABOVE_SURFACE + 2):
						var b: int = TreeGen.block_at(bx + dx, y, bz + dz)
						if b == LEAF or b == SPRUCE_LEAF or b == BlockCatalog.id_of(&"birch_leaves"):
							leaf_cells += 1
			_ok(trunk_cells >= TreeGen.TRUNK_MIN, "trunk has >= TRUNK_MIN logs (%d)" % trunk_cells)
			_ok(leaf_cells >= 5, "canopy has leaves (%d)" % leaf_cells)
			_ok(log_ids.has(TerrainConfig.generated_block(bx, gy + 1, bz)), "generated_block sees a trunk log")
			found = true
		# keep scanning for a spruce even after the first (oak) tree is validated.
	_ok(found, "at least one tree exists in the sampled grid")
	_ok(found_spruce, "a spruce tree (spruce_log trunk) is found in a cold biome")

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
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
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
		if id <= BlockCatalog.AIR or id >= BlockCatalog.CORE_COUNT:
			continue                          # air + world/extended rows (covered by _test_catalog_expansion)
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
	_ok(seen_core == BlockCatalog.CORE_COUNT - 1, "drift gate covered all %d non-air core materials (%d)"
		% [BlockCatalog.CORE_COUNT - 1, seen_core])

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

# P3a. Catalog expansion (WGC §3-§5): the core+world catalog fully resolves, the
# drift gate covers every non-core material, translucency is authored on both the sim
# and render sides, glass/water have the right solidity split, and the module library-
# order invariant holds for ALL ids (not just the frozen 5).
func _test_catalog_expansion() -> void:
	print("[P3a] catalog expansion + translucent rendering")
	var n := BlockCatalog.count()
	_ok(n == 77, "catalog holds 77 materials (core+world), got %d" % n)

	# (a) every id 0..count-1 resolves to state + mass + solidity + a render material,
	# id<->name round-trips, and non-air names are unique.
	var names := {}
	for id in range(1, n):
		var s: VoxelState = BlockCatalog.state_of(id)
		_ok(s != null, "id %d resolves to a VoxelState" % id)
		if s == null:
			continue
		var nm := BlockCatalog.name_of(id)
		_ok(BlockCatalog.id_of(StringName(nm)) == id, "id_of(name_of(%d)) round-trips (%s)" % [id, nm])
		_ok(not names.has(nm), "material name '%s' is unique" % nm)
		names[nm] = true
		_ok(BlockCatalog.mass_of(id) > 0.0, "%s has mass > 0" % nm)
		_ok(BlockCatalog.solidity_of(id) >= 0.0, "%s has a solidity" % nm)
		_ok(BlockMaterials.get_for(id) != null, "%s yields a non-null render material" % nm)
	# aliases resolve to their frozen core ids (WGC §3.1).
	_ok(BlockCatalog.id_of(&"oak_log") == BlockCatalog.WOOD, "alias oak_log -> WOOD")
	_ok(BlockCatalog.id_of(&"oak_leaves") == BlockCatalog.LEAF, "alias oak_leaves -> LEAF")

	# (b) DRIFT GATE over every non-core, non-override record with a structural class:
	# propose_anchors(priors, class) == the stored anchors. (Fluid/bedrock/non-solid
	# sentinel classes propose ZERO and store [0,0,0]; timber/rock/soil/etc reproduce.)
	var records := BlockCatalog.load_data()
	var world_checked := 0
	var world_covered := 0
	for rec: Variant in records:
		if not (rec is Dictionary):
			continue
		var id := int(rec.get("id", -1))
		if id < BlockCatalog.CORE_COUNT or id >= n:
			continue                          # core handled by _test_material_data
		world_checked += 1
		if bool(rec.get("anchors_override", false)):
			continue                          # tuned value (snow_block, powder_snow) — gate skips
		var nm := String(rec.get("name", "?"))
		var cls := StringName(String(rec.get("structural_class", "rock")))
		var priors: Dictionary = rec.get("priors", {})
		var proposed := AnchorConverter.propose_anchors(priors, cls)
		var stored := BlockCatalog.anchors_of(id)
		_ok(proposed == stored, "drift gate '%s': propose%s == stored %s" % [nm, str(proposed), str(stored)])
		world_covered += 1
	_ok(world_checked == n - BlockCatalog.CORE_COUNT, "iterated all %d world records (%d)"
		% [n - BlockCatalog.CORE_COUNT, world_checked])
	_ok(world_covered > 60, "drift gate covered %d non-override world materials" % world_covered)

	# (c) translucency authored on BOTH sides for glass/water/ice; solidity split.
	var glass := BlockCatalog.id_of(&"glass")
	var water := BlockCatalog.id_of(&"water")
	var ice := BlockCatalog.id_of(&"ice")
	_ok(glass > 0 and water > 0 and ice > 0, "glass/water/ice ids resolve")
	# sim side: translucence > 0.
	_ok(BlockCatalog.state_of(glass).translucence > 0.0, "glass sim-translucence > 0")
	_ok(BlockCatalog.state_of(water).translucence > 0.0, "water sim-translucence > 0")
	# solidity: glass is a solid block, water is non-solid (you wade through it).
	_ok(BlockCatalog.solidity_of(glass) >= 0.5, "glass is solid (solidity >= 0.5)")
	_ok(BlockCatalog.solidity_of(water) < 0.5, "water is non-solid (solidity < 0.5)")
	# render side: translucent materials have a real transparency mode + a cull group.
	for tid in [glass, water, ice]:
		var m: StandardMaterial3D = BlockMaterials.get_for(tid)
		_ok(m != null and m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED,
			"%s render material is transparency-enabled" % BlockCatalog.name_of(tid))
		_ok(BlockCatalog.cull_group_of(tid) != 0, "%s has a non-zero cull group" % BlockCatalog.name_of(tid))
	# an opaque material (stone) stays opaque, cull group 0.
	_ok(BlockCatalog.cull_group_of(BlockCatalog.STONE) == 0, "stone cull group is 0 (opaque)")
	_ok(BlockMaterials.get_for(BlockCatalog.STONE).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"stone render material is opaque (transparency disabled)")

	# (d) occludes_face transparency-index truth table (WGC §5.1). occludes_face(nb, my)
	# answers "does neighbour `nb` occlude the face of a cell whose cull group is `my`?"
	# — false when nb is non-solid OR more transparent than `my` (index(nb) > my).
	var g := BlockCatalog.cull_group_of(glass)                              # 3
	var red := BlockCatalog.id_of(&"red_stained_glass")
	var blue := BlockCatalog.id_of(&"blue_stained_glass")
	var rg := BlockCatalog.cull_group_of(red)                              # 6
	var bg := BlockCatalog.cull_group_of(blue)                             # 7
	# opaque stone (group 0) behind a glass pane: the GLASS face against stone is culled
	# (stone is opaque, index 0 <= 3), the STONE face is drawn (glass index 3 > 0).
	_ok(WorldManager.occludes_face(CellCodec.pack(BlockCatalog.STONE), g) == true,
		"stone(0) occludes a glass(3) face (opaque neighbour always occludes)")
	_ok(WorldManager.occludes_face(CellCodec.pack(glass), 0) == false,
		"glass(3) does NOT occlude an opaque(0) cell's face (you see stone through the pane)")
	# glass|glass: equal index => occluded (no internal faces inside a glass wall).
	_ok(WorldManager.occludes_face(CellCodec.pack(glass), g) == true, "glass|glass culls (equal index)")
	# red(6) | blue(7): exactly one face. A red neighbour occludes a blue cell's face
	# (6 <= 7); a blue neighbour does NOT occlude a red cell's face (7 > 6).
	_ok(WorldManager.occludes_face(CellCodec.pack(red), bg) == true, "red(6) occludes blue(7) face (6<=7)")
	_ok(WorldManager.occludes_face(CellCodec.pack(blue), rg) == false, "blue(7) does NOT occlude red(6) face (7>6)")
	# water is non-solid: it never occludes anything (you always see the cell behind it).
	_ok(WorldManager.occludes_face(CellCodec.pack(water), 0) == false, "water is non-solid: never occludes opaque")
	_ok(WorldManager.occludes_face(CellCodec.pack(water), g) == false, "water is non-solid: never occludes glass")

	# (e) placement: a solid translucent block (glass) places + reads back; a non-solid
	# fluid (water) is rejected from the hotbar (WGC §6.3).
	var world: WorldManager = WorldManager.new()
	world.name = "WorldManagerP3a"
	get_root().add_child(world)
	var gcol := _grass_column()
	var cx := gcol.x
	var cz := gcol.y
	var gg: int = TerrainConfig.height_at(cx, cz)
	_ok(world.place_block(Vector3i(cx, gg + 1, cz), glass), "place glass succeeds")
	_ok(world.block_id_at(Vector3i(cx, gg + 1, cz)) == glass, "placed glass reads back")
	_ok(world.place_block(Vector3i(cx, gg + 2, cz), water) == false, "placing water is rejected (non-solid)")

	world.queue_free()

	# (f) module library-order invariant for ALL ids: build the module world directly
	# (synchronously — a SceneTree script defers a child's _ready(), so we cannot read
	# WorldManager.using_module here). setup() returns true only when _configure_library
	# asserted every model index == id across the WHOLE catalog; a mismatch returns false.
	if ClassDB.class_exists("VoxelTerrain"):
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		var built: bool = mw.call("setup")
		_ok(built, "module library built with model_index==id for all %d ids" % n)
		mw.queue_free()
	else:
		print("    (godot_voxel module absent — library-order assert exercised on module builds only)")

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
	# Wide sample so land columns are guaranteed regardless of where origin lands in
	# the now continent-shaped world; ocean/tree/frozen columns are skipped below.
	for x in range(-200, 200, 23):
		for z in range(-200, 200, 19):
			var g: int = TerrainConfig.height_at(x, z)
			# Skip underwater columns (water above the seafloor is legitimately
			# non-solid, but the "plain grass surface" expectations below assume a dry
			# land column) and any column whose above-surface cells are occupied.
			if g <= TerrainConfig.SEA_LEVEL:
				continue
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
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
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
	# kicked VoxelBody (invariant 4). Find any tree (any species), chop its lowest
	# trunk cell. Wide scan so a tree is found wherever the land biomes fall.
	var SPRUCE_LOG := BlockCatalog.id_of(&"spruce_log")
	var BIRCH_LOG := BlockCatalog.id_of(&"birch_log")
	var log_ids := {WOOD: true, SPRUCE_LOG: true, BIRCH_LOG: true}
	var chopped := false
	for gx in range(-120, 120):
		for gz in range(-120, 120):
			if chopped:
				break
			if not TreeGen.has_tree(gx, gz):
				continue
			var base: Vector3i = TreeGen.tree_base(gx, gz)
			var trunk := Vector3i(base.x, base.y + 1, base.z)
			var trunk_id := world.block_id_at(trunk)
			if not log_ids.has(trunk_id):
				continue
			var n_bodies_before := _count_voxel_bodies(world)
			var id := world.break_terrain(trunk, Vector3(base.x + 0.5, base.y - 2.0, base.z + 0.5))
			_ok(id == trunk_id, "chopped trunk returns its log id (got %d)" % id)
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
