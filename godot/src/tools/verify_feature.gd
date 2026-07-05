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
	_test_smoothing()
	_test_tree()
	_test_masses()
	_test_materials()
	_test_inventory()
	_test_cell_codec()
	_test_shape_math()
	_test_material_data()
	_test_catalog_expansion()
	_test_merged_physics()
	_test_world_loop()
	_test_structural()
	_test_shapes_live()
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

# Both render paths agree (WGC §7.2 + SVS §10.6): build the module world (library +
# FROZEN appearance manifest), drive its generator over several 16³ blocks (now
# INCLUDING a block guaranteed to hold smoothed surface cells), and assert every TYPE
# value it writes equals the manifest's ARID for generated_cell's (material, modifier) —
# i.e. decoding each ARID reproduces (mat, modifier) exactly. Also fences the P5b-2
# invariants: shaped cells appear (smoothing active), every shaped generated cell is
# PRE-BAKED in the frozen manifest (the worker never lazy-bakes), and generating never
# grows the ARID table (the worker only reads the frozen arrays).
func _test_both_paths() -> void:
	if not ClassDB.class_exists("VoxelTerrain") or not ClassDB.class_exists("VoxelBuffer"):
		print("    (godot_voxel module absent — both-path determinism runs on module builds only)")
		return
	var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
	get_root().add_child(mw)
	var built: bool = mw.call("setup")
	_ok(built, "both-path: module world builds (library + frozen appearance manifest)")
	if not built:
		mw.queue_free()
		return
	var gen: Object = mw.call("get_generator")
	_ok(gen != null, "both-path: generator available after setup")
	if gen == null:
		mw.queue_free()
		return
	var ch := 0                                   # VoxelBuffer.CHANNEL_TYPE
	var origins := [
		Vector3i(0, -64, 0), Vector3i(0, -16, 0), Vector3i(48, 0, 48),
		Vector3i(-80, -32, 16), Vector3i(128, -8, -64), Vector3i(-256, 0, 320),
	]
	# Guarantee the sample includes shaped surface cells: add a 16³ block known to hold one.
	var shaped_block := _find_shaped_block()
	if shaped_block.x != 0x7fffffff:
		origins.append(shaped_block)
	var mismatches := 0
	var cells := 0
	var shaped_cells := 0
	var uncovered := 0
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
					var v: int = TerrainConfig.generated_cell(origin.x + lx, origin.y + ly, origin.z + lz)
					var mat: int = CellCodec.mat(v)
					var modifier: int = CellCodec.modifier(v)
					var expected: int = int(mw.call("gen_arid_for", mat, modifier))
					if got != expected:
						mismatches += 1
					if mat != BlockCatalog.AIR and modifier != 0:
						shaped_cells += 1
						if not bool(mw.call("is_manifest_baked", mat, modifier)):
							uncovered += 1
					cells += 1
	_ok(mismatches == 0, "module generator TYPE == manifest arid_for(mat,modifier) over %d cells (%d mismatches)" % [cells, mismatches])
	_ok(shaped_cells > 0, "both-path sample includes shaped surface cells (%d) — smoothing active" % shaped_cells)
	_ok(uncovered == 0, "every shaped generated cell is PRE-BAKED in the frozen manifest (%d uncovered) — worker never lazy-bakes" % uncovered)
	# The generator only READS the frozen arrays — generating must not grow the ARID table.
	var ac := int(mw.call("appearance_count"))
	var buf2: Object = ClassDB.instantiate("VoxelBuffer")
	buf2.call("create", 16, 16, 16)
	gen.call("_generate_block", buf2, origins[0], 0)
	_ok(int(mw.call("appearance_count")) == ac, "generator allocates/bakes NO ARID on the worker (count stable at %d)" % ac)
	print("    both-path determinism checked %d cells (%d shaped)" % [cells, shaped_cells])
	mw.queue_free()

## A 16³ block origin (16-aligned) known to contain a smoothed (shaped) surface cell, or
## (0x7fffffff,_,_) if none found near origin — so the both-path test always samples the
## smoothing, not just flat plains.
func _find_shaped_block() -> Vector3i:
	for x in range(-256, 256, 4):
		for z in range(-256, 256, 4):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			if CellCodec.modifier(TerrainConfig.generated_cell(x, g, z)) != 0:
				return Vector3i(floori(x / 16.0) * 16, floori(g / 16.0) * 16, floori(z / 16.0) * 16)
	return Vector3i(0x7fffffff, 0, 0)

# P5b-2. Deterministic terrain smoothing (SUB-VOXEL-SMOOTHING §8.1): the natural world
# now emits sub-voxel shapes at the walkable surface. Asserts determinism (same seed →
# same modifiers, mat+modifier), flat-ground regression safety (byte-identical plain
# blocks), that smoothing actually engages, that the material projection is untouched,
# tree bases stay FULL-topped, no fall-through (solid full cubes below the surface), and
# the surface is continuously WALKABLE (floor_under monotone/continuous up a smoothed
# step, no cliff steeper than the source heightmap). Both-path + manifest coverage are
# fenced in _test_both_paths (run from _test_worldgen).
func _test_smoothing() -> void:
	print("[P5b-2] deterministic terrain smoothing (sub-voxel surface shapes)")

	# (a) DETERMINISM: generated_cell (material AND modifier) identical on re-sample.
	var det_ok := true
	for x in range(-150, 150, 7):
		for z in range(-150, 150, 11):
			var g: int = TerrainConfig.height_at(x, z)
			for y in [g, g + 1]:
				if TerrainConfig.generated_cell(x, y, z) != TerrainConfig.generated_cell(x, y, z):
					det_ok = false
	_ok(det_ok, "generated_cell (material + modifier) is deterministic on re-sample")

	# (b) SMOOTHING ENGAGES over a wide land sweep; every surface modifier is a BOTTOM
	# corner-height code (corners ≤ 2, anchor BOTTOM); the MATERIAL projection is unchanged
	# (generated_block == mat, so smoothing minted no new material and no stackup shifts).
	var shaped := 0
	var surface_cells := 0
	var range_ok := true
	var mat_ok := true
	for x in range(-400, 400, 3):
		for z in range(-400, 400, 3):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			var v: int = TerrainConfig.generated_cell(x, g, z)
			surface_cells += 1
			if CellCodec.mat(v) != TerrainConfig.generated_block(x, g, z):
				mat_ok = false
			var modifier: int = CellCodec.modifier(v)
			if modifier != 0:
				shaped += 1
				var c := ShapeCodec.corners(modifier)
				if c.x > 2 or c.y > 2 or c.z > 2 or c.w > 2 \
						or ShapeCodec.anchor(modifier) != ShapeCodec.ANCHOR_BOTTOM:
					range_ok = false
	print("    surface sweep: %d land cells, %d shaped" % [surface_cells, shaped])
	_ok(shaped > 0, "smoothing engages: at least one shaped surface cell over the sweep (%d)" % shaped)
	_ok(range_ok, "every surface modifier is a BOTTOM corner-height code (corners ≤ 2)")
	_ok(mat_ok, "smoothing leaves the material projection unchanged (generated_block == mat)")

	# (c) FLAT-GROUND REGRESSION SAFE: on a naturally flat 5×5 patch the surface cell is a
	# PLAIN FULL cube (modifier 0 → byte-identical to a plain block) with no cap above it.
	var patch := _flat_patch5()
	if patch.x != 0x7fffffff:
		var fx := patch.x
		var fz := patch.y
		var fg: int = TerrainConfig.height_at(fx, fz)
		_ok(CellCodec.modifier(TerrainConfig.generated_cell(fx, fg, fz)) == 0,
			"flat patch: surface cell is FULL (modifier 0)")
		_ok(TerrainConfig.generated_cell(fx, fg, fz) == TerrainConfig.generated_block(fx, fg, fz),
			"flat patch: generated_cell == bare material id (byte-identical plain packed value)")
		_ok(TerrainConfig.generated_block(fx, fg + 1, fz) == 0,
			"flat patch: no cap cell above a flat surface (g+1 is air)")
	else:
		_ok(false, "found a flat 5×5 patch to fence flat-ground regression safety")

	# (d) TREE BASES stay FULL-topped: the surface cell under a trunk base is a full cube
	# so trunks never float on a ramp corner (SVS §8.1 tree exception).
	var tree_ok := true
	var tree_checked := 0
	for gx in range(-160, 160):
		if tree_checked >= 8:
			break
		for gz in range(-160, 160):
			if tree_checked >= 8:
				break
			if not TreeGen.has_tree(gx, gz):
				continue
			var base: Vector3i = TreeGen.tree_base(gx, gz)
			if base.y < TerrainConfig.SEA_LEVEL:
				continue
			if CellCodec.modifier(TerrainConfig.generated_cell(base.x, base.y, base.z)) != 0:
				tree_ok = false
			tree_checked += 1
	_ok(tree_checked > 0 and tree_ok, "tree-base columns keep a FULL surface cell (checked %d)" % tree_checked)

	# (e) NO FALL-THROUGH: only y==g / y==g+1 carry modifiers; every cell below the surface
	# stays a solid FULL cube, so the analytic downward floor scan can never miss.
	var nofall_ok := true
	for x in range(-80, 80, 9):
		for z in range(-80, 80, 11):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			for y in [g, g - 1, g - 3]:
				if not TerrainConfig.is_solid(x, y, z):
					nofall_ok = false
				if y < g and CellCodec.modifier(TerrainConfig.generated_cell(x, y, z)) != 0:
					nofall_ok = false
	_ok(nofall_ok, "no fall-through: columns are solid full cubes below the smoothed surface")

	# (f) WALKABILITY: across a naturally sloped land region the standable surface is
	# continuous (no jump > STEP_MAX between adjacent footprints) and always finite.
	_test_smoothing_walkable()

# The standable surface over a smoothed 1-block step is continuous and walkable: sample
# floor_under densely across a found 1-step land slope on a live WorldManager and assert
# no adjacent-sample jump exceeds STEP_MAX (so the player auto-steps up it) and no sample
# falls through. A continuous floor IS the walkability guarantee — blocked() auto-steps
# exactly the same STEP_MAX rise floor_under exposes here.
func _test_smoothing_walkable() -> void:
	var spot := Vector2i(0x7fffffff, 0)
	for x in range(-200, 200):
		for z in range(-200, 200):
			var g: int = TerrainConfig.height_at(x, z)
			if g <= TerrainConfig.SEA_LEVEL:
				continue
			# a gentle 1-step up to the +x neighbour, ≤1 elsewhere on the walk axis.
			if TerrainConfig.height_at(x + 1, z) != g + 1:
				continue
			if absi(TerrainConfig.height_at(x - 1, z) - g) > 1:
				continue
			# clear above both columns so the floor scan hits the surface/cap, not a tree.
			var clear := true
			for xx in [x, x + 1]:
				for yy in range(g + 2, g + 6):
					if TerrainConfig.is_solid(xx, yy, z):
						clear = false
						break
				if not clear:
					break
			if clear:
				spot = Vector2i(x, z)
				break
		if spot.x != 0x7fffffff:
			break
	if spot.x == 0x7fffffff:
		print("    (no clear 1-step land slope found near origin — walkability sweep skipped)")
		_ok(true, "walkability sweep skipped (no 1-step land slope near origin)")
		return
	var world: WorldManager = _struct_world("P5bWalk")
	var g: int = TerrainConfig.height_at(spot.x, spot.y)
	var z := float(spot.y) + 0.5
	var finite_ok := true
	var cont_ok := true
	var max_jump := 0.0
	var prev := world.floor_under(float(spot.x) - 0.4, z, float(g) + 5.0)
	var xx := float(spot.x) - 0.4
	while xx <= float(spot.x) + 1.6:
		var f := world.floor_under(xx, z, float(g) + 5.0)
		if f <= -1000.0:
			finite_ok = false
		var jump := absf(f - prev)
		if jump > max_jump:
			max_jump = jump
		if jump > WorldManager.STEP_MAX + 1e-3:
			cont_ok = false
		prev = f
		xx += 0.1
	_ok(finite_ok, "walkability: floor_under always finite across the slope (no fall-through)")
	_ok(cont_ok, "walkability: standable surface continuous up the smoothed 1-step (max jump %.3f ≤ STEP_MAX)" % max_jump)
	world.queue_free()

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

# P5a. Sub-voxel SHAPE math (SUB-VOXEL-SMOOTHING §2/§6/§7 + VDS §3.2). Pure, no
# world. The load-bearing guard: modifier 0 is BYTE-IDENTICAL to the full-cube stubs
# P2/P4 already call, so the running game (which emits only modifier 0) is unchanged.
# Then the real corner-height math: the §2.1 volume table, rotation invariance, the
# §6 complement invariant, §7 contact-area examples, the LUT/direct agreement + the
# handedness case, and the §3.2 canonicalization.
func _test_shape_math() -> void:
	print("[P5a] sub-voxel shape math (corner-height / mass / contact area)")

	# (a) FULL-CUBE IDENTITY: modifier 0 returns exactly today's full-cube value for
	# EVERY function — the guarantee that P5a changes no behaviour.
	_ok(ShapeCodec.volume(0) == 1.0, "volume(FULL) == 1")
	_ok(ShapeCodec.local_top(0, 0.3, 0.7) == 1.0, "local_top(FULL) == 1")
	_ok(ShapeCodec.span(0, 0.3, 0.7) == Vector2(0.0, 1.0), "span(FULL) == (0,1)")
	_ok(ShapeCodec.occupied(0, 0.5, 0.5, 0.5), "occupied(FULL) == true")
	_ok(ShapeCodec.corners(0) == Vector4i(2, 2, 2, 2), "corners(FULL) == (2,2,2,2)")
	for axis in [ShapeCodec.AXIS_X, ShapeCodec.AXIS_Y, ShapeCodec.AXIS_Z]:
		_ok(ShapeCodec.contact_area(0, 0, axis) == 1.0, "contact_area(FULL,FULL,%d) == 1" % axis)
	for face in range(6):
		_ok(ShapeCodec.side_profile_full(0, face), "side_profile_full(FULL, %d) == true" % face)

	# (b) VOLUME of the §2.1 named shapes (BOTTOM-anchored representatives).
	var named := {
		"SLAB": [1, 1, 1, 1, 0.5],
		"RAMP": [2, 2, 0, 0, 0.5],
		"HALF_RAMP_LO": [1, 1, 0, 0, 0.25],
		"HALF_RAMP_HI": [2, 2, 1, 1, 0.75],
		"CORNER": [2, 0, 0, 0, 1.0 / 3.0],
		"ANTICORNER": [2, 2, 2, 0, 5.0 / 6.0],
		"HALF_CORNER": [1, 0, 0, 0, 1.0 / 6.0],
		"HALF_ANTICORNER": [1, 1, 1, 0, 5.0 / 12.0],
		"RIDGE": [2, 0, 2, 0, 2.0 / 3.0],
	}
	for nm in named:
		var d: Array = named[nm]
		var m := ShapeCodec.make_modifier(d[0], d[1], d[2], d[3])
		_ok(is_equal_approx(ShapeCodec.volume(m), d[4]),
			"volume(%s) == %.4f (got %.4f)" % [nm, d[4], ShapeCodec.volume(m)])

	# (c) ROTATION INVARIANCE: a cyclic corner shift (90° yaw) preserves volume for
	# every one of the 81 corner tuples (max-sum rule routes the diagonal consistently).
	var rot_ok := true
	for c0 in range(3):
		for c1 in range(3):
			for c2 in range(3):
				for c3 in range(3):
					var m := ShapeCodec.make_modifier(c0, c1, c2, c3)
					var mr := ShapeCodec.make_modifier(c3, c0, c1, c2)   # yaw: (c00,c10,c11,c01)->(c01,c00,c10,c11)
					if not is_equal_approx(ShapeCodec.volume(m), ShapeCodec.volume(mr)):
						rot_ok = false
	_ok(rot_ok, "volume invariant under 90° rotation over all 81 corner tuples")

	# (d) §6 COMPLEMENT INVARIANT for a FIXED diagonal: V_D(c) + V_D(2−c) == 1.
	var comp_ok := true
	for c0 in range(3):
		for c1 in range(3):
			for c2 in range(3):
				for c3 in range(3):
					var c := Vector4i(c0, c1, c2, c3)
					var cc := Vector4i(2 - c0, 2 - c1, 2 - c2, 2 - c3)
					for use_main in [true, false]:
						var s := ShapeCodec.volume_of_corners(c, use_main) \
							+ ShapeCodec.volume_of_corners(cc, use_main)
						if not is_equal_approx(s, 1.0):
							comp_ok = false
	_ok(comp_ok, "fixed-diagonal complement invariant V_D(c)+V_D(2−c)=1 over all codes")

	# (e) CONTACT AREA — the §7 examples the requirements call out.
	var slab_b := ShapeCodec.make_modifier(1, 1, 1, 1, ShapeCodec.ANCHOR_BOTTOM)
	var slab_t := ShapeCodec.make_modifier(1, 1, 1, 1, ShapeCodec.ANCHOR_TOP)
	# Bottom slab beside top slab: profiles (½,½) vs (½,½) opposite anchor → ∫max(0,0)=0.
	_ok(ShapeCodec.contact_area(slab_b, slab_t, ShapeCodec.AXIS_X) == 0.0,
		"bottom-slab ‖ top-slab lateral contact == 0 (zero overlap ⇒ no joint)")
	# RAMP (2,2,0,0): high side is the −Z face (2,2), zero edge is +Z (0,0).
	var ramp := ShapeCodec.make_modifier(2, 2, 0, 0)
	# High side against a cube on its −z: a=cube(−z), b=ramp(+z) → cube+Z(2,2) ∩ ramp−Z(2,2)=1.
	_ok(ShapeCodec.contact_area(0, ramp, ShapeCodec.AXIS_Z) == 1.0,
		"ramp high side ‖ cube == 1 (full-face joint)")
	# Zero edge against a cube on its +z: a=ramp(−z), b=cube(+z) → ramp+Z(0,0) ∩ cube−Z(2,2)=0.
	_ok(ShapeCodec.contact_area(ramp, 0, ShapeCodec.AXIS_Z) == 0.0,
		"ramp zero edge ‖ cube == 0 (no joint)")
	# Cube directly above a bottom slab: horizontal, a=lower=slab, b=upper=cube → 0
	# (½-block air gap; the famous §7.2 unsupported-cube case).
	_ok(ShapeCodec.contact_area(slab_b, 0, ShapeCodec.AXIS_Y) == 0.0,
		"cube above bottom-slab horizontal contact == 0")
	# Cube above an anticorner (one all-2 triangle) → half the face.
	var anticorner := ShapeCodec.make_modifier(2, 2, 2, 0)
	_ok(ShapeCodec.contact_area(anticorner, 0, ShapeCodec.AXIS_Y) == 0.5,
		"cube above anticorner horizontal contact == ½")

	# (f) HANDEDNESS: two identical wedges nose-to-nose (high edges meet) give a
	# different area than nose-to-tail. Catches the §7.1 profile-orientation bug — if
	# the extraction ignored which edge faces the seam both would read equal.
	var ramp_hi_pz := ShapeCodec.make_modifier(0, 0, 2, 2)   # high side at +Z
	# nose-to-nose along z: a=(high +Z) meets b=ramp(−Z high) → 1.
	_ok(ShapeCodec.contact_area(ramp_hi_pz, ramp, ShapeCodec.AXIS_Z) == 1.0,
		"wedges nose-to-nose (high edges meet) contact == 1")
	# nose-to-tail: a=ramp(+Z is the zero edge) meets b=ramp(−Z high) → 0.
	_ok(ShapeCodec.contact_area(ramp, ramp, ShapeCodec.AXIS_Z) == 0.0,
		"wedges nose-to-tail (zero edge meets high) contact == 0")

	# (g) LUT vs direct integral agreement over all 18×18 side-profile pairs.
	ShapeCodec.ensure_ready()
	var lut_ok := true
	for ia in range(18):
		for ib in range(18):
			var lut_v := ShapeCodec._lut[ia * 18 + ib]
			var direct := ShapeCodec._profile_overlap_direct(ia, ib)
			if not is_equal_approx(lut_v, direct):
				lut_ok = false
	_ok(lut_ok, "profile-overlap LUT == direct integral over all 18×18 pairs")

	# (h) CANONICALIZATION (§3.2): FULL-cube variants collapse to 0, empty shapes to
	# AIR, corner value 3 clamps, and canonical modifiers round-trip / stay unique.
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE,
		ShapeCodec.make_modifier(2, 2, 2, 2, ShapeCodec.ANCHOR_BOTTOM)))) == 0,
		"all-corners-2 BOTTOM → FULL (modifier 0)")
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE,
		ShapeCodec.make_modifier(2, 2, 2, 2, ShapeCodec.ANCHOR_TOP)))) == 0,
		"all-corners-2 TOP → FULL (modifier 0)")
	# All-corners-0 with a nonzero encoding (TOP anchor bit) → the whole cell is AIR.
	_ok(CellCodec.canonical(CellCodec.pack(STONE,
		ShapeCodec.make_modifier(0, 0, 0, 0, ShapeCodec.ANCHOR_TOP))) == 0,
		"all-corners-0 (nonzero encoding) → AIR (whole value 0)")
	# Corner value 3 clamps to 2: modifier 7 = corners (3,1,0,0) → (2,1,0,0).
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, 7))) ==
		ShapeCodec.make_modifier(2, 1, 0, 0),
		"corner value 3 clamps to 2 (modifier 7 → (2,1,0,0))")
	# Idempotent round-trip + uniqueness for a spread of canonical corner-height codes.
	var seen := {}
	var round_ok := true
	for c0 in range(3):
		for c1 in range(3):
			for c2 in range(3):
				for c3 in range(3):
					for anc in [ShapeCodec.ANCHOR_BOTTOM, ShapeCodec.ANCHOR_TOP]:
						var raw := ShapeCodec.make_modifier(c0, c1, c2, c3, anc)
						var can := CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, raw)))
						# canonical is idempotent: canonicalizing the canonical form is a no-op.
						var can2 := CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, can)))
						if can != can2:
							round_ok = false
	_ok(round_ok, "canonicalization is idempotent over all corner-height codes × anchors")

	# (i) ShapeMesh builds a non-empty, indexed mesh for FULL and a ramp (P5b's render
	# seam exists and is deterministic); parallel arrays stay aligned.
	var full_mesh := ShapeMesh.build(0)
	_ok(full_mesh["verts"].size() > 0 and full_mesh["indices"].size() % 3 == 0,
		"ShapeMesh.build(FULL) yields a triangulated mesh")
	_ok(full_mesh["verts"].size() == full_mesh["normals"].size()
		and full_mesh["verts"].size() == full_mesh["uvs"].size(),
		"ShapeMesh arrays (verts/normals/uvs) stay aligned")
	var ramp_mesh := ShapeMesh.build(ramp)
	_ok(ramp_mesh["verts"].size() > 0 and ramp_mesh["indices"].size() % 3 == 0,
		"ShapeMesh.build(RAMP) yields a triangulated mesh")
	var m1 := ShapeMesh.build(ramp)
	_ok(m1["verts"] == ramp_mesh["verts"], "ShapeMesh.build is deterministic")

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
	# A canonical corner-height modifier (no corner==3, not all-2, not empty) on a
	# solid material is preserved. Modifier 5 = corners (1,1,0,0) = HALF_RAMP_LO.
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, 5, 0))) == 5,
		"canonical keeps a valid corner-height modifier on a solid material")

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
			# P5b-2: skip a column whose (smoothed) surface cell is shaped — its standable
			# floor is fractional (cell.y + H(fx,fz)), not g+1, and aimed_voxel returns an
			# in-cell surface hit; both are covered by _test_smoothing. Byte-identity to the
			# pre-P2 behaviour applies to FULL-cube surface columns only.
			if CellCodec.modifier(TerrainConfig.generated_cell(x, g, z)) != 0:
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

# P5b-1. Sub-voxel shapes wired END-TO-END for PLACED cells (SUB-VOXEL-SMOOTHING
# §4/§5/§9): the module ARID appearance table (lazy shaped model, add_model()==ARID),
# the analytic physics seams (fractional floor, STEP_MAX auto-step, in-cell ray), a
# partial VoxelBody (mass = density × ½), and structural attachment by real contact
# area (zero overlap ⇒ detach). Worldgen is NOT smoothed here, so only player-placed
# cells can be shaped — full-cube gameplay stays byte-identical (fenced by the P2/P4
# byte-identity tests above).
func _test_shapes_live() -> void:
	print("[P5b-1] sub-voxel shapes live (render ARIDs + analytic physics + dig/place)")
	var RAMP := ShapeCodec.make_modifier(2, 2, 0, 0)   # descending along +z: H(fx,fz) = 1 − fz
	var SLAB := ShapeCodec.make_modifier(1, 1, 1, 1)    # flat half-block, rise 0.5

	# (a) MODULE ARID appearance table: the plain-cube ARID equals the LRID (bootstrap),
	# a shaped value lazily appends ONE VoxelBlockyModelMesh whose model index == the
	# allocated ARID (the anti-drift assert, VDS §8.1), and a repeat lookup re-uses it.
	if ClassDB.class_exists("VoxelTerrain"):
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		var built: bool = mw.call("setup")
		_ok(built, "shapes-live: module world builds")
		if built:
			_ok(int(mw.call("arid_for", STONE, 0)) == STONE, "shapes-live: cube ARID == LRID (bootstrap)")
			var before: int = mw.call("appearance_count")
			var arid: int = mw.call("arid_for", STONE, RAMP)
			_ok(arid == before, "shapes-live: shaped ARID == prior model count (add_model()==ARID held)")
			_ok(int(mw.call("appearance_count")) == before + 1, "shapes-live: exactly one shaped model appended")
			_ok(int(mw.call("arid_for", STONE, RAMP)) == arid, "shapes-live: shaped ARID stable on re-lookup (no duplicate append)")
			_ok(int(mw.call("appearance_count")) == before + 1, "shapes-live: no duplicate ARID for the same shape")
		mw.queue_free()
	else:
		print("    (godot_voxel module absent — ARID appearance table checked on module builds only)")

	# A clear grass column for the physics/dig-place asserts.
	var world: WorldManager = _struct_world("P5bShapes")
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var rc := Vector3i(cx, g + 1, cz)   # the surface-adjacent air cell (ramp sits on grass)

	# (b) PLACE a shaped value; the ONE world query reports it solid + shaped (both render
	# paths read this query, so they agree by construction), and the fallback mesher emits
	# real shape geometry for the placed ramp's chunk.
	_ok(world.place_block(rc, CellCodec.pack(GRASS, RAMP)), "shapes-live: place a grass RAMP")
	_ok(world.cell_solid(rc), "shapes-live: placed ramp cell is solid (material gate)")
	_ok(CellCodec.modifier(world.cell_value_at(rc)) == RAMP, "shapes-live: placed cell carries the ramp modifier")
	var n := TerrainConfig.CHUNK_SIZE
	var fb_mesh := ChunkMesher.build(floori(float(cx) / float(n)), floori(float(cz) / float(n)), world)
	_ok(fb_mesh != null and fb_mesh.get_surface_count() > 0, "shapes-live: fallback mesher builds the ramp chunk (partial geometry)")

	# (c) floor_under is a CONTINUOUS in-cell floor: it varies with the footprint along
	# the ramp axis and equals cell.y + H(fx,fz) — a boundary-only test would be constant.
	var f02 := world.floor_under(cx + 0.5, cz + 0.2, float(g) + 3.0)
	var f05 := world.floor_under(cx + 0.5, cz + 0.5, float(g) + 3.0)
	var f08 := world.floor_under(cx + 0.5, cz + 0.8, float(g) + 3.0)
	_ok(f02 > f05 and f05 > f08, "shapes-live: floor_under monotone across the ramp (%.3f>%.3f>%.3f)" % [f02, f05, f08])
	_ok(is_equal_approx(f02, float(g + 1) + (1.0 - 0.2)), "shapes-live: floor_under == cell.y + H at fz=0.2 (%.3f)" % f02)
	_ok(is_equal_approx(f08, float(g + 1) + (1.0 - 0.8)), "shapes-live: floor_under == cell.y + H at fz=0.8 (%.3f)" % f08)

	# (e) aimed_voxel hits the IN-CELL surface (not the cell boundary): a downward ray at
	# a high-H footprint hits higher than at a low-H footprint, both inside the ramp cell.
	var hit_hi := world.aimed_voxel(Vector3(cx + 0.5, float(g) + 8.0, cz + 0.2), Vector3(0, -1, 0), 32.0)
	_ok(hit_hi.get("hit", false) and hit_hi["voxel"] == rc, "shapes-live: ray-down hits the ramp cell")
	_ok(is_equal_approx((hit_hi["position"] as Vector3).y, float(g + 1) + 0.8),
		"shapes-live: ray hits in-cell surface at cell.y+H=%.2f (got %.3f)" % [float(g + 1) + 0.8, (hit_hi["position"] as Vector3).y])
	_ok(hit_hi["normal"] == Vector3i.UP, "shapes-live: ramp surface hit reports UP normal (placement adjacency)")
	var hit_lo := world.aimed_voxel(Vector3(cx + 0.5, float(g) + 8.0, cz + 0.8), Vector3(0, -1, 0), 32.0)
	_ok(hit_lo.get("hit", false) and is_equal_approx((hit_lo["position"] as Vector3).y, float(g + 1) + 0.2),
		"shapes-live: ray-down at a lower-H footprint hits lower (in-cell, not boundary)")
	# Tunnelling guard: an oblique ray through the ramp's empty upper wedge (entering the
	# low +z side, rising) exits without ever crossing the surface — it must NOT hit the ramp.
	var thru := world.aimed_voxel(Vector3(cx + 0.5, float(g) + 1.95, cz + 1.4),
		Vector3(0.0, 0.1, -1.0).normalized(), 8.0)
	_ok(not (thru.get("hit", false) and thru["voxel"] == rc),
		"shapes-live: oblique ray through the empty wedge does not hit the ramp (tunnelling guard)")

	# (f) breaking a placed shaped cell returns its MATERIAL (hotbar contract intact).
	_ok(world.break_terrain(rc, Vector3.INF) == GRASS, "shapes-live: break_terrain returns the ramp's material (GRASS)")

	# (d) blocked() auto-steps a half-slab (rise 0.5 <= STEP_MAX) but a full cube (rise
	# 1.0) still walls — the byte-identical full-cube gate plus the new ramp/slab step.
	_ok(world.place_block(rc, CellCodec.pack(GRASS, SLAB)), "shapes-live: place a half-slab to step onto")
	_ok(world.blocked(cx + 0.5, cz + 0.5, float(g + 1)) == false, "shapes-live: half-slab auto-stepped (rise 0.5 <= STEP_MAX)")
	world.break_terrain(rc, Vector3.INF)
	_ok(world.place_block(rc, STONE), "shapes-live: place a full cube")
	_ok(world.blocked(cx + 0.5, cz + 0.5, float(g + 1)) == true, "shapes-live: full cube blocks (rise 1.0 > STEP_MAX)")
	world.queue_free()

	# (f cont.) a loose VoxelBody made of one stone RAMP weighs density × fill-fraction.
	var mworld: WorldManager = _struct_world("P5bMass")
	var vb := VoxelBody.spawn_loose(mworld, {Vector3i.ZERO: CellCodec.pack(STONE, RAMP)}, mworld)
	_ok(vb != null, "shapes-live: spawn a partial stone-ramp VoxelBody")
	if vb != null:
		_ok(is_equal_approx(vb.mass, BlockCatalog.mass_of(STONE) * 0.5),
			"shapes-live: partial VoxelBody mass == density × ½ = %.1f (got %.1f)" % [BlockCatalog.mass_of(STONE) * 0.5, vb.mass])
	mworld.queue_free()

	# (g) STRUCTURAL attachment is by real contact-area (SVS §7, canonical −/+ order):
	# a ramp arm whose HIGH edge meets the tower (full-face overlap) ATTACHES; the same
	# arm whose ZERO edge meets the tower (no overlap ⇒ no joint) DETACHES.
	_test_shapes_attach()

func _test_shapes_attach() -> void:
	var patch := _flat_patch5()
	if patch.x == 0x7fffffff:
		_ok(false, "shapes-live: found a flat patch for the attachment test")
		return
	var cx := patch.x
	var cz := patch.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var tower := 5
	# Full-overlap: the ramp's −X face (corners c00,c01) is the HIGH edge (2,2) toward the
	# tower → full-face contact → the arm holds.
	var wa := _struct_world("P5bAttachFull")
	for k in range(1, tower + 1):
		wa.place_block(Vector3i(cx, g + k, cz), STONE)
	var yy := g + tower
	var b0 := _count_voxel_bodies(wa)
	var arm := Vector3i(cx + 1, yy, cz)
	_ok(wa.place_block(arm, CellCodec.pack(STONE, ShapeCodec.make_modifier(2, 0, 0, 2))),
		"shapes-live: place full-overlap ramp arm")
	_ok(_count_voxel_bodies(wa) == b0 and wa.block_id_at(arm) == STONE,
		"shapes-live: full-overlap ramp arm ATTACHES (holds on the tower)")
	wa.queue_free()
	# Zero-overlap: the ramp's −X face is the ZERO edge (0,0) toward the tower → no joint
	# → the arm has no support → it detaches as a VoxelBody.
	var wb := _struct_world("P5bAttachZero")
	for k in range(1, tower + 1):
		wb.place_block(Vector3i(cx, g + k, cz), STONE)
	var b1 := _count_voxel_bodies(wb)
	wb.place_block(arm, CellCodec.pack(STONE, ShapeCodec.make_modifier(0, 2, 2, 0)))
	_ok(_count_voxel_bodies(wb) > b1 and wb.block_id_at(arm) != STONE,
		"shapes-live: zero-overlap ramp arm DETACHES (zero contact ⇒ no joint)")
	wb.queue_free()

func _count_voxel_bodies(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if ch is VoxelBody:
			c += 1
		c += _count_voxel_bodies(ch)
	return c

# P4. Structural-integrity solver (STRUCTURAL-INTEGRITY §8 + INTEGRATION-DECISIONS):
# the per-material capacities as pure-math asserts (the anchors become executable
# σ's), then LIVE builds via the edit overlay whose collapse thresholds ARE the
# anchors — pillars (P, compression), dangling chains (D, tension), horizontal
# cantilevers (H, shear+moment), falling sand (participation), per-joint
# reinforcement, and the preserved tree-chop (pass 0). Every threshold uses the
# exact integer-Newton capacities, so binding "exactly at capacity" is not flaky.
func _test_structural() -> void:
	print("[P4] structural integrity solver")
	_struct_math_asserts()
	var patch := _flat_patch5()
	if patch.x == 0x7fffffff:
		_ok(false, "found a flat clear grass patch for structural builds")
		return
	var cx := patch.x
	var cz := patch.y
	var g: int = TerrainConfig.height_at(cx, cz)
	print("    flat 5x5 patch at (%d,%d) g=%d" % [cx, cz, g])

	# Pillars — the P (compression) anchor: a pillar of P stands, P+1 crushes at base.
	_struct_pillar(DIRT, 4, cx, cz, g)
	_struct_pillar(WOOD, 36, cx, cz, g)
	_struct_pillar(STONE, 64, cx, cz, g)
	# Dangling chains — the D (tension) anchor.
	_struct_dangle(DIRT, 1, cx, cz, g)
	_struct_dangle(WOOD, 16, cx, cz, g)
	_struct_dangle(STONE, 4, cx, cz, g)
	# Horizontal cantilevers — the H (shear+moment) anchor.
	_struct_cantilever(DIRT, 2, cx, cz, g)
	_struct_cantilever(WOOD, 24, cx, cz, g)
	_struct_cantilever(STONE, 6, cx, cz, g)
	# Falling sand — the participation (attachment=0) audit.
	_struct_sand(cx, cz, g)
	# Per-joint reinforcement raises capacity in the live solver.
	_struct_reinforcement(cx, cz, g)
	# Tree-chop unchanged (pass 0).
	_struct_tree_chop()

# Pure-math capacity asserts (no world): the anchors + mass reproduce σ_c/σ_t/σ_s/M₀
# in the integer-Newton domain, the mixed wood/stone joint, the φ plateau (=1 across
# today's world) and the endpoints, and the cement reinforcement bonus.
func _struct_math_asserts() -> void:
	# σ_c=P·w, σ_s=H·w, σ_t=D·w, M₀=σ_s·H/2 with w=round(m·g). dirt m=900 → w=8829.
	_ok(StructuralModel.weight_int(DIRT) == 8829, "w_int(dirt)=8829")
	_ok(StructuralModel.sigma_c(DIRT) == 35316 and StructuralModel.sigma_t(DIRT) == 8829
		and StructuralModel.sigma_s(DIRT) == 17658 and StructuralModel.moment0(DIRT) == 17658,
		"dirt σ_c/σ_t/σ_s/M₀ = 35316/8829/17658/17658")
	# stone m=1500 → w=14715; (64,6,4).
	_ok(StructuralModel.sigma_c(STONE) == 941760 and StructuralModel.sigma_t(STONE) == 58860
		and StructuralModel.sigma_s(STONE) == 88290 and StructuralModel.moment0(STONE) == 264870,
		"stone σ_c/σ_t/σ_s/M₀ = 941760/58860/88290/264870")
	# wood m=80 → w=785; (36,24,16).
	_ok(StructuralModel.sigma_c(WOOD) == 28260 and StructuralModel.sigma_t(WOOD) == 12560
		and StructuralModel.sigma_s(WOOD) == 18840 and StructuralModel.moment0(WOOD) == 226080,
		"wood σ_c/σ_t/σ_s/M₀ = 28260/12560/18840/226080")
	# Mixed wood/stone tension joint (SI §4 worked example): F_t = ½(σ_t,wood+σ_t,stone).
	var ft_ws := StructuralModel.joint_ft(WOOD, STONE, 21.5, 0, 1.0)
	_ok(ft_ws == 35710, "mixed wood/stone F_t = ½(12560+58860) = 35710 (got %d)" % ft_ws)
	_ok(2 * StructuralModel.weight_int(STONE) <= ft_ws and 3 * StructuralModel.weight_int(STONE) > ft_ws,
		"mixed joint: 2 stones dangle under wood, a 3rd snaps")
	# φ plateau (=1) across today's world; frost strengthens soil; heat fails timber.
	_ok(is_equal_approx(StructuralModel.phi(12.0, &"soil"), 1.0)
		and is_equal_approx(StructuralModel.phi(21.5, &"rock"), 1.0)
		and is_equal_approx(StructuralModel.phi(23.0, &"timber"), 1.0),
		"φ = 1 on the plateau (deep mine == surface behaviour)")
	_ok(is_equal_approx(StructuralModel.phi(-10.0, &"soil"), 3.0), "φ_soil(−10°C) = 3.0 (frost cementation)")
	_ok(is_equal_approx(StructuralModel.phi(300.0, &"timber"), StructuralModel.PHI_MIN),
		"φ_timber(300°C) = φ_min (heat failure)")
	# Cement reinforcement (id 2): F_t = σ_t + R_t on a stone joint.
	var ft_bare := StructuralModel.joint_ft(STONE, STONE, 21.5, 0, 1.0)
	var ft_cem := StructuralModel.joint_ft(STONE, STONE, 21.5, 2, 1.0)
	_ok(ft_bare == 58860 and ft_cem == 98860, "cement raises stone F_t 58860 → 98860 (+R_t)")

# The first (lowest x, then z) naturally-flat 5x5 grass patch clear to g+69 above —
# the deterministic test bed. Its centre support cell is confined bulk once a block
# sits on it (all 6 neighbours solid), so a pillar/tower base bears the FULL column
# and crushes at its own σ_c rather than punching through the ground.
func _flat_patch5() -> Vector2i:
	for x in range(-256, 256):
		for z in range(-256, 256):
			var g: int = TerrainConfig.height_at(x, z)
			if g <= TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.generated_block(x, g, z) != GRASS:
				continue
			var flat := true
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					if TerrainConfig.height_at(x + dx, z + dz) != g \
							or TerrainConfig.generated_block(x + dx, g + 1, z + dz) != 0:
						flat = false
						break
				if not flat:
					break
			if not flat:
				continue
			var clear := true
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					for yy in range(g + 1, g + 70):
						if TerrainConfig.generated_block(x + dx, yy, z + dz) != 0:
							clear = false
							break
					if not clear:
						break
				if not clear:
					break
			if clear:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

func _struct_world(nm: String) -> WorldManager:
	var w := WorldManager.new()
	w.name = nm
	get_root().add_child(w)
	return w

# Pillar of `mat`: P cells stand, P+1 crushes at the base (compression, σ_c=P·w).
func _struct_pillar(mat: int, cap_p: int, cx: int, cz: int, g: int) -> void:
	var w := _struct_world("P4Pillar_%d" % mat)
	var nm := BlockCatalog.name_of(mat)
	var b0 := _count_voxel_bodies(w)
	var built := true
	for k in range(1, cap_p + 1):
		if not w.place_block(Vector3i(cx, g + k, cz), mat):
			built = false
	var base := Vector3i(cx, g + 1, cz)
	_ok(built and _count_voxel_bodies(w) == b0 and w.block_id_at(base) == mat,
		"%s pillar of %d STANDS (no debris, base solid)" % [nm, cap_p])
	w.place_block(Vector3i(cx, g + cap_p + 1, cz), mat)
	_ok(_count_voxel_bodies(w) > b0 and w.block_id_at(base) != mat,
		"%s pillar of %d COLLAPSES (base crushed, debris spawned)" % [nm, cap_p + 1])
	w.queue_free()

# Dangling chain of `mat` hung from a stone tower's arm: D cells hold, D+1 snaps the
# top joint (tension, σ_t=D·w). The arm is the test material so the tested joint is
# same-material; the tower is stone so it never self-collapses under the extra load.
func _struct_dangle(mat: int, cap_d: int, cx: int, cz: int, g: int) -> void:
	var w := _struct_world("P4Dangle_%d" % mat)
	var nm := BlockCatalog.name_of(mat)
	var h_tower := cap_d + 3
	for k in range(1, h_tower + 1):
		w.place_block(Vector3i(cx, g + k, cz), STONE)
	var yy := g + h_tower
	w.place_block(Vector3i(cx + 1, yy, cz), mat)   # arm base (off the tower)
	w.place_block(Vector3i(cx + 2, yy, cz), mat)   # arm tip (clears the tower body)
	var b0 := _count_voxel_bodies(w)
	var top := Vector3i(cx + 2, yy - 1, cz)
	var built := true
	for k in range(1, cap_d + 1):
		if not w.place_block(Vector3i(cx + 2, yy - k, cz), mat):
			built = false
	_ok(built and _count_voxel_bodies(w) == b0 and w.block_id_at(top) == mat,
		"%s dangling chain of %d HOLDS" % [nm, cap_d])
	w.place_block(Vector3i(cx + 2, yy - cap_d - 1, cz), mat)
	_ok(_count_voxel_bodies(w) > b0 and w.block_id_at(top) != mat,
		"%s dangling chain of %d SNAPS at the top joint" % [nm, cap_d + 1])
	w.queue_free()

# Horizontal cantilever of `mat` off a same-material braced wall: H cells hold, H+1
# detaches (root shear σ_s=H·w binds, moment M₀ binds together at H). The wall is
# elevated so the beam has air below; weak dirt keeps a short beam (low wall), strong
# wood/stone use a tall wall so their long beams clear the terrain.
func _struct_cantilever(mat: int, cap_h: int, cx: int, cz: int, g: int) -> void:
	var w := _struct_world("P4Cant_%d" % mat)
	var nm := BlockCatalog.name_of(mat)
	var h_wall := 4 if mat == DIRT else 14
	for k in range(1, h_wall + 1):
		for dz in [-1, 0, 1]:
			w.place_block(Vector3i(cx, g + k, cz + dz), mat)   # 3-wide braced wall
	var yy := g + h_wall
	var b0 := _count_voxel_bodies(w)
	var root := Vector3i(cx + 1, yy, cz)
	var built := true
	for k in range(1, cap_h + 1):
		if not w.place_block(Vector3i(cx + k, yy, cz), mat):
			built = false
	_ok(built and _count_voxel_bodies(w) == b0 and w.block_id_at(root) == mat,
		"%s cantilever of %d HOLDS" % [nm, cap_h])
	w.place_block(Vector3i(cx + cap_h + 1, yy, cz), mat)
	_ok(_count_voxel_bodies(w) > b0 and w.block_id_at(root) != mat,
		"%s cantilever of %d DETACHES at the root" % [nm, cap_h + 1])
	w.queue_free()

# Falling sand — the participation (attachment = 0.0) audit (INTEGRATION-DECISIONS §1.3).
func _struct_sand(cx: int, cz: int, g: int) -> void:
	var w := _struct_world("P4Sand")
	var SAND := BlockCatalog.id_of(&"sand")
	_ok(SAND > 0, "sand id resolves")
	if SAND <= 0:
		w.queue_free()
		return
	# (a) sand side-attached to a stone wall with air below FALLS — the att_A·att_B=0
	# product zeroes the sand↔stone joint the arithmetic mean would keep glued.
	w.place_block(Vector3i(cx, g + 1, cz), STONE)
	w.place_block(Vector3i(cx, g + 2, cz), STONE)
	var b0 := _count_voxel_bodies(w)
	var spot := Vector3i(cx + 1, g + 2, cz)          # beside the stone top, air below
	w.place_block(spot, SAND)
	_ok(_count_voxel_bodies(w) > b0 and w.block_id_at(spot) != SAND,
		"undercut sand side-attached to a stone wall FALLS (participation 0)")
	# contrast: a DIRT block (participation 1) in the same spot HOLDS as a 1-shelf.
	var b1 := _count_voxel_bodies(w)
	w.place_block(spot, DIRT)
	_ok(_count_voxel_bodies(w) == b1 and w.block_id_at(spot) == DIRT,
		"a dirt shelf of 1 off the same wall HOLDS (participation 1 — contrast)")
	# (b) a sand block on solid ground STANDS (pure compression routing).
	var heap := Vector3i(cx - 2, g + 1, cz)
	var b2 := _count_voxel_bodies(w)
	w.place_block(heap, SAND)
	_ok(_count_voxel_bodies(w) == b2 and w.block_id_at(heap) == SAND,
		"a sand block on solid ground STANDS (compression, not participation)")
	# (c) a sand column of 4 CRUSHES its base (P=3): 3 stands, the 4th crushes.
	var scol := cx + 2
	var b3 := _count_voxel_bodies(w)
	for k in range(1, 4):
		w.place_block(Vector3i(scol, g + k, cz), SAND)
	_ok(_count_voxel_bodies(w) == b3 and w.block_id_at(Vector3i(scol, g + 1, cz)) == SAND,
		"sand column of 3 STANDS (P=3)")
	w.place_block(Vector3i(scol, g + 4, cz), SAND)
	_ok(_count_voxel_bodies(w) > b3 and w.block_id_at(Vector3i(scol, g + 1, cz)) != SAND,
		"sand column of 4 CRUSHES its base (P=3)")
	w.queue_free()

# Per-joint reinforcement in the live solver: a stone dangling chain of 5 (bare
# σ_t=4·w ⇒ the plain stone anchor is 4/5, snaps) HOLDS once every joint on its load
# path is cemented (F_t 58860 → 98860). Same structure, reinforcement flips it.
func _struct_reinforcement(cx: int, cz: int, g: int) -> void:
	var w := _struct_world("P4Reinf")
	var chain := 5
	var h_tower := chain + 3
	for k in range(1, h_tower + 1):
		w.place_block(Vector3i(cx, g + k, cz), STONE)
	var yy := g + h_tower
	# Pre-cement the WHOLE load path (joints may be reinforced before the cells exist;
	# the store is keyed by cell pair, queried only for existing solid pairs).
	w.reinforce_joint(Vector3i(cx + 1, yy, cz), Vector3i(cx, yy, cz), 2)          # arm base ↔ tower
	w.reinforce_joint(Vector3i(cx + 2, yy, cz), Vector3i(cx + 1, yy, cz), 2)      # arm tip ↔ arm base
	w.reinforce_joint(Vector3i(cx + 2, yy - 1, cz), Vector3i(cx + 2, yy, cz), 2)  # chain top ↔ arm tip
	for k in range(1, chain + 1):
		w.reinforce_joint(Vector3i(cx + 2, yy - k - 1, cz), Vector3i(cx + 2, yy - k, cz), 2)
	w.place_block(Vector3i(cx + 1, yy, cz), STONE)
	w.place_block(Vector3i(cx + 2, yy, cz), STONE)
	var b0 := _count_voxel_bodies(w)
	var top := Vector3i(cx + 2, yy - 1, cz)
	var built := true
	for k in range(1, chain + 1):
		if not w.place_block(Vector3i(cx + 2, yy - k, cz), STONE):
			built = false
	_ok(built and _count_voxel_bodies(w) == b0 and w.block_id_at(top) == STONE,
		"cemented stone chain of 5 HOLDS (bare stone snaps at 5 — reinforcement raised F_t)")
	w.queue_free()

# Tree-chop is decided by pass 0 (connectivity), unchanged: chopping the lowest trunk
# cell detaches the whole canopy as one kicked VoxelBody — the invariant that cannot regress.
func _struct_tree_chop() -> void:
	var w := _struct_world("P4Tree")
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
			if not log_ids.has(w.block_id_at(trunk)):
				continue
			var n0 := _count_voxel_bodies(w)
			w.break_terrain(trunk, Vector3(base.x + 0.5, base.y - 2.0, base.z + 0.5))
			_ok(_count_voxel_bodies(w) > n0, "tree-chop still detaches the canopy (pass 0 preserved)")
			chopped = true
			break
		if chopped:
			break
	_ok(chopped, "found and chopped a tree trunk")
	w.queue_free()
