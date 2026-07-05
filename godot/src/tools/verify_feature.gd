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
	_test_worldgen_air_bounds()
	_test_manifest_trim()
	_test_smoothing()
	_test_shape_memo()
	_test_collider_cheap_queries()
	_test_collider_overlay_cases()
	_test_collider_amortized()
	_test_collider_gate()
	_test_physics_dormancy()
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
	_test_metadata()
	_test_zonechunk()
	_test_dynamic_catalog()
	_test_zone_bundle()
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

# 1b. Air-skip bounds (PERF, generator all-air early-outs). MAX_SURFACE_Y must be a TRUE upper
# bound on the surface so the module generator can skip blocks above the terrain WITHOUT ever
# skipping real content (a too-low bound would punch holes). Prove it over a wide sample, and
# prove nothing generates above MAX_SURFACE_Y+max_above or below the bedrock floor (exactly the
# volumes the early-outs skip).
func _test_worldgen_air_bounds() -> void:
	print("[1b] air-skip bounds (MAX_SURFACE_Y upper bound / all-air above+below)")
	var max_seen := -0x7fffffff
	# Wide, dense sample of the surface (cheap height_at) — the bound must hold everywhere.
	for x in range(-420, 420, 5):
		for z in range(-420, 420, 5):
			var h: int = TerrainConfig.height_at(x, z)
			if h > max_seen:
				max_seen = h
	_ok(max_seen <= TerrainConfig.MAX_SURFACE_Y,
		"MAX_SURFACE_Y (%d) is a true upper bound on height_at over a wide sample (max seen %d)"
		% [TerrainConfig.MAX_SURFACE_Y, max_seen])
	# Nothing (solid, cap, tree or sea) generates above MAX_SURFACE_Y+max_above, nor below the
	# bedrock floor — exactly the two volumes the generator early-outs drop.
	var above_y := TerrainConfig.MAX_SURFACE_Y + TreeGen.MAX_ABOVE_SURFACE
	var air_above_ok := true
	var air_below_ok := true
	for x in range(-240, 240, 17):
		for z in range(-240, 240, 17):
			for y in range(above_y + 1, above_y + 31):
				if TerrainConfig.generated_cell(x, y, z) != BlockCatalog.AIR:
					air_above_ok = false
			for y in range(TerrainConfig.BEDROCK_FLOOR - 16, TerrainConfig.BEDROCK_FLOOR):
				if TerrainConfig.generated_cell(x, y, z) != BlockCatalog.AIR:
					air_below_ok = false
	_ok(air_above_ok, "no generated cell above MAX_SURFACE_Y+max_above (=%d) — above early-out skips only air" % above_y)
	_ok(air_below_ok, "no generated cell below the bedrock floor (y < %d) — below early-out skips only air" % TerrainConfig.BEDROCK_FLOOR)

# 1c. Appearance-manifest trim (PERF, fewer GPU readbacks at load). The module bakes materials ×
# emitted_modifiers() (a wide-area sample), not × all 79 corner tuples. Assert the set is actually
# trimmed and that it COVERS every smoothed shape the generator emits over the spawn play-area
# (so no cube-fallback where the player is); any far-region straggler cube-falls-back gracefully.
func _test_manifest_trim() -> void:
	print("[1c] appearance manifest trim (bake only emitted shapes)")
	if not TerrainConfig.SMOOTHING_ENABLED:
		_ok(TerrainConfig.emitted_modifiers().size() == 0, "smoothing OFF: manifest bakes 0 shaped models")
		return
	var emitted := TerrainConfig.emitted_modifiers()
	var full := TerrainConfig.appearance_modifiers()
	var mats := TerrainConfig.appearance_surface_materials().size()
	var eset := {}
	for m: int in emitted:
		eset[m] = true
	_ok(emitted.size() > 0, "emitted modifier set is non-empty (%d)" % emitted.size())
	_ok(emitted.size() < full.size(), "emitted set is TRIMMED vs the full %d corner tuples (%d)" % [full.size(), emitted.size()])
	# Coverage over the spawn play-area, using the REAL tree-aware surface/cap queries: every
	# smoothed shape the generator emits there must be in the baked set (no cube-fallback there).
	var s := TerrainConfig.find_spawn()
	var uncovered := 0
	var emitted_seen := 0
	for dx in range(-150, 150, 3):
		for dz in range(-150, 150, 3):
			var x := s.x + dx
			var z := s.y + dz
			var sm := TerrainConfig.surface_modifier(x, z)
			if sm != 0:
				emitted_seen += 1
				if not eset.has(sm):
					uncovered += 1
			var cm := TerrainConfig.surface_cap_modifier(x, z)
			if cm != 0:
				emitted_seen += 1
				if not eset.has(cm):
					uncovered += 1
	_ok(uncovered == 0, "baked set covers every smoothed shape over the spawn play-area (%d seen, %d uncovered)" % [emitted_seen, uncovered])
	print("    manifest trim: %d emitted modifiers (full %d) → %d materials x %d = %d baked (was %d)"
		% [emitted.size(), full.size(), mats, emitted.size(), mats * emitted.size(), mats * full.size()])

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
	if TerrainConfig.SMOOTHING_ENABLED:
		_ok(shaped_cells > 0, "both-path sample includes shaped surface cells (%d) — smoothing active" % shaped_cells)
		_ok(uncovered == 0, "every shaped generated cell is PRE-BAKED in the frozen manifest (%d uncovered) — worker never lazy-bakes" % uncovered)
	else:
		_ok(shaped_cells == 0, "smoothing OFF: both-path sample has no shaped cells (%d)" % shaped_cells)
	# The generator only READS the frozen arrays — generating must not grow the ARID table.
	var ac := int(mw.call("appearance_count"))
	var buf2: Object = ClassDB.instantiate("VoxelBuffer")
	buf2.call("create", 16, 16, 16)
	gen.call("_generate_block", buf2, origins[0], 0)
	_ok(int(mw.call("appearance_count")) == ac, "generator allocates/bakes NO ARID on the worker (count stable at %d)" % ac)
	print("    both-path determinism checked %d cells (%d shaped)" % [cells, shaped_cells])

	# All-air early-outs (PERF): a block entirely ABOVE content and one entirely BELOW bedrock
	# must generate ALL AIR via the cheap early-out (no column-profile pass) — verify the output
	# is all-air, and that it costs a tiny fraction of a content block.
	var air_above := Vector3i(0, TerrainConfig.MAX_SURFACE_Y + TreeGen.MAX_ABOVE_SURFACE + 14, 0)   # oy=48
	var air_below := Vector3i(0, TerrainConfig.BEDROCK_FLOOR - 16, 0)                                # oy+16 <= floor
	var content_origin := Vector3i(48, 0, 48)
	_ok(_module_block_all_air(mw, air_above), "block entirely above MAX_SURFACE_Y+max_above generates ALL AIR (early-out)")
	_ok(_module_block_all_air(mw, air_below), "block entirely below the bedrock floor generates ALL AIR (early-out)")
	var reps := 8
	var bA: Object = ClassDB.instantiate("VoxelBuffer")
	bA.call("create", 16, 16, 16)
	var ta0 := Time.get_ticks_usec()
	for _r in range(reps):
		gen.call("_generate_block", bA, air_above, 0)
	var air_us := float(Time.get_ticks_usec() - ta0) / float(reps)
	var tc0 := Time.get_ticks_usec()
	for _r in range(reps):
		gen.call("_generate_block", bA, content_origin, 0)
	var content_us := float(Time.get_ticks_usec() - tc0) / float(reps)
	print("    air-block gen cost: all-air=%.1f us/block  vs  content=%.1f us/block (%.0fx cheaper)"
		% [air_us, content_us, content_us / maxf(0.1, air_us)])
	_ok(air_us < content_us, "all-air block generation is far cheaper than a content block (early-out hit)")
	mw.queue_free()

## True iff the module generator writes ALL AIR (TYPE channel 0) for the 16³ block at `origin`.
func _module_block_all_air(mw: Node, origin: Vector3i) -> bool:
	var gen: Object = mw.call("get_generator")
	if gen == null:
		return false
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 16, 16, 16)
	if buf.has_method("fill"):
		buf.call("fill", 0, 0)
	gen.call("_generate_block", buf, origin, 0)
	for lz in range(16):
		for lx in range(16):
			for ly in range(16):
				if int(buf.call("get_voxel", lx, ly, lz, 0)) != 0:
					return false
	return true

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

# P5b-3. Per-column SHAPE MEMO exactness (the analytic-path smoothing-jerkiness fix). The main-
# thread analytic queries consult TerrainConfig._shape_memo; a non-null pcache bypasses it and
# computes directly. Assert the MEMO path returns EXACTLY the direct compute for surface_modifier,
# surface_cap_modifier AND the fully-generated cell's modifier over a wide sample — proving the
# cache is byte-identical (no cheap-vs-correct divergence), so gameplay/rendering are unchanged.
func _test_shape_memo() -> void:
	print("[P5b-3] per-column shape memo == direct compute (analytic path)")
	if not TerrainConfig.SMOOTHING_ENABLED:
		_ok(true, "smoothing OFF: shape memo returns 0 (no shapes) — skipped")
		return
	var s := TerrainConfig.find_spawn()
	var exact := true
	var shaped := 0
	var checked := 0
	for dx in range(-160, 160, 3):
		for dz in range(-160, 160, 3):
			var x := s.x + dx
			var z := s.y + dz
			var g: int = TerrainConfig.height_at(x, z)
			# Memo path (pcache == null, main thread) vs direct compute (non-null pcache bypasses memo).
			var memo_sm := TerrainConfig.surface_modifier(x, z)
			var memo_cm := TerrainConfig.surface_cap_modifier(x, z)
			var direct_sm := TerrainConfig.surface_modifier(x, z, {})
			var direct_cm := TerrainConfig.surface_cap_modifier(x, z, {})
			if memo_sm != direct_sm or memo_cm != direct_cm:
				exact = false
			# The memoized modifier must also equal what the FULL generated_cell carries at g / g+1.
			if memo_sm != CellCodec.modifier(TerrainConfig.generated_cell(x, g, z)):
				exact = false
			if memo_cm != CellCodec.modifier(TerrainConfig.generated_cell(x, g + 1, z)):
				exact = false
			if memo_sm != 0 or memo_cm != 0:
				shaped += 1
			checked += 1
	_ok(checked > 0, "shape memo: sampled %d columns" % checked)
	_ok(shaped > 0, "shape memo: sample includes shaped columns (%d) — memo exercised on real shapes" % shaped)
	_ok(exact, "shape memo path == direct compute == generated_cell modifier over the whole sample (cache is exact)")

	# Cost: the actual analytic surface query (generated_cell at y==g), memo-WARM, vs the direct
	# 9-height_at corner-stencil recompute the memo removes from every moving-player probe.
	var reps := 5
	var cols := 3600
	for dx in range(0, 60):
		for dz in range(0, 60):
			TerrainConfig.surface_modifier(s.x + dx, s.y + dz)     # warm the memo
	var tw0 := Time.get_ticks_usec()
	for _r in range(reps):
		for dx in range(0, 60):
			for dz in range(0, 60):
				var g2: int = TerrainConfig.height_at(s.x + dx, s.y + dz)
				var _v := TerrainConfig.generated_cell(s.x + dx, g2, s.y + dz)   # memo HIT
	var memo_us := float(Time.get_ticks_usec() - tw0) / float(reps * cols)
	var td0 := Time.get_ticks_usec()
	for _r in range(reps):
		for dx in range(0, 60):
			for dz in range(0, 60):
				var _m := TerrainConfig.surface_modifier(s.x + dx, s.y + dz, {})  # direct 9-height_at compute
	var direct_us := float(Time.get_ticks_usec() - td0) / float(reps * cols)
	print("    shape-memo cost: analytic surface query (generated_cell, memo-warm) = %.2f us/query; direct corner-stencil recompute = %.2f us/query" % [memo_us, direct_us])
	_ok(memo_us < direct_us, "memo-warm analytic query (%.2f us) cheaper than the direct corner-stencil recompute (%.2f us)" % [memo_us, direct_us])

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
	if TerrainConfig.SMOOTHING_ENABLED:
		_ok(shaped > 0, "smoothing engages: at least one shaped surface cell over the sweep (%d)" % shaped)
	else:
		_ok(shaped == 0, "smoothing OFF: no shaped surface cells over the sweep (%d)" % shaped)
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
	if not TerrainConfig.SMOOTHING_ENABLED:
		print("    smoothing-walkable — SKIPPED (smoothing OFF)")
		return
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

# 2b. GroundCollider cheap queries (PERF freeze fix): the collider now reads the surface
# SHAPE from the LIGHT TerrainConfig.surface_modifier / surface_cap_modifier queries and
# TreeGen.block_at instead of the ~12x-heavier generated_cell. Prove that (a) the light
# modifier queries are byte-identical to the full generation at the surface + cap cell, and
# (b) above the cap, generated cells are only tree/sea/air (full cubes, modifier 0) — so
# TreeGen.block_at + the sea test are sound substitutes and collision geometry is unchanged.
# Also demonstrate the query is dramatically cheaper (the actual freeze fix).
func _test_collider_cheap_queries() -> void:
	print("[2b] collider cheap queries (light surface/cap modifier == full generation)")
	var s: Vector2i = TerrainConfig.find_spawn()
	var checked := 0
	var surf_ok := true
	var cap_ok := true
	var above_ok := true
	# Sweep a wide patch so it spans varied terrain (ramps, caps, trees, and — outward —
	# possibly water), exercising every branch of the light queries.
	for dz in range(-40, 40):
		for dx in range(-40, 40):
			var x := s.x + dx
			var z := s.y + dz
			var g: int = TerrainConfig.height_at(x, z)
			# (a) surface modifier: light query == modifier of the fully generated top cell.
			if TerrainConfig.surface_modifier(x, z) != CellCodec.modifier(TerrainConfig.generated_cell(x, g, z)):
				surf_ok = false
			# (a') cap modifier: light query == modifier of the fully generated cell one above.
			if TerrainConfig.surface_cap_modifier(x, z) != CellCodec.modifier(TerrainConfig.generated_cell(x, g + 1, z)):
				cap_ok = false
			# (b) above the cap the collider substitutes TreeGen.block_at + a sea test for
			# generated_cell; that is sound only if every generated cell there is a full cube
			# (modifier 0) AND, when solid, is a tree cell or sea fill.
			for y in range(g + 2, g + TreeGen.MAX_ABOVE_SURFACE + 1):
				var v: int = TerrainConfig.generated_cell(x, y, z)
				if CellCodec.mat(v) == BlockCatalog.AIR:
					continue
				if CellCodec.modifier(v) != 0:
					above_ok = false                         # no shaped generated cell above the cap
				var is_tree: bool = TreeGen.block_at(x, y, z) != BlockCatalog.AIR
				var is_sea: bool = y <= TerrainConfig.SEA_LEVEL
				if not (is_tree or is_sea):
					above_ok = false
			checked += 1
	_ok(checked > 0, "collider-cheap: swept %d columns around spawn" % checked)
	_ok(surf_ok, "collider-cheap: surface_modifier(x,z) == modifier(generated_cell(x, h, z)) over the whole sweep")
	_ok(cap_ok, "collider-cheap: surface_cap_modifier(x,z) == modifier(generated_cell(x, h+1, z)) over the whole sweep")
	_ok(above_ok, "collider-cheap: above the cap, generated cells are only tree/sea (modifier 0) — cheap substitutes are sound")

	# Cost proof: over the same region, time the OLD strategy (full generated_cell at the
	# top + through the above-surface column) vs the NEW light strategy the collider now
	# uses. The light path must be dramatically cheaper (this IS the freeze fix). Correctness
	# above is the gate; this timing is a soft assert (light does strictly less work).
	var reps := 3
	var t0 := Time.get_ticks_usec()
	for _r in range(reps):
		for dz in range(-14, 15):
			for dx in range(-14, 15):
				var x := s.x + dx
				var z := s.y + dz
				var g: int = TerrainConfig.height_at(x, z)
				var acc := 0
				acc += CellCodec.modifier(TerrainConfig.generated_cell(x, g, z))   # old: top read
				for y in range(g + 1, g + TreeGen.MAX_ABOVE_SURFACE + 1):
					acc += CellCodec.mat(TerrainConfig.generated_cell(x, y, z))    # old: above-surface reads
	var old_us := Time.get_ticks_usec() - t0
	var t1 := Time.get_ticks_usec()
	for _r in range(reps):
		var hc := {}
		for dz in range(-14, 15):
			for dx in range(-14, 15):
				var x := s.x + dx
				var z := s.y + dz
				var g: int = TerrainConfig.height_at(x, z)
				var acc := 0
				acc += TerrainConfig.surface_modifier(x, z, hc)                    # new: light top
				for y in range(g + 1, g + TreeGen.MAX_ABOVE_SURFACE + 1):
					if y == g + 1:
						acc += TerrainConfig.surface_cap_modifier(x, z, hc)        # new: light cap
					elif y <= TerrainConfig.SEA_LEVEL:
						acc += 1
					else:
						acc += CellCodec.mat(TreeGen.block_at(x, y, z))            # new: cheap hash
	var new_us := Time.get_ticks_usec() - t1
	print("    per-cell region query cost (29x29, x%d): full-generated_cell=%d us  light=%d us  (%.1fx cheaper)"
		% [reps, old_us, new_us, (float(old_us) / maxf(1.0, float(new_us)))])
	_ok(new_us < old_us, "collider-cheap: light query strategy is cheaper than full generated_cell (%d us < %d us)" % [new_us, old_us])

	# Cost proof #2 — worst-case SINGLE-FRAME collider cost, old vs new scheduling. Drive a real
	# GroundCollider directly (a bare WorldManager answers the cell queries). The FIRST build is
	# synchronous (= the old whole-region single-frame cost — the walking stutter); a drift then
	# triggers the AMORTIZED rebuild, whose worst single update() slice must be a small fraction.
	var cw := WorldManager.new()
	cw.name = "ColliderPerfWorld"
	get_root().add_child(cw)
	var gc := GroundCollider.new()
	get_root().add_child(gc)
	gc.setup(cw)
	VoxelBody.spawn_loose(cw, {Vector3i(s.x, 40, s.y): STONE}, cw)   # active-body gate: keep the collider live
	var bt0 := Time.get_ticks_usec()
	gc.update(Vector3(float(s.x) + 0.5, 40.0, float(s.y) + 0.5))     # first build = synchronous
	var full_us := Time.get_ticks_usec() - bt0
	var nshapes := PhysicsServer3D.body_get_shape_count(gc.active_rid())
	# Drift REBUILD_DIST blocks → an incremental rebuild; time each update() slice to completion.
	var np := Vector3(float(s.x) + 0.5 + float(GroundCollider.REBUILD_DIST), 40.0, float(s.y) + 0.5 + float(GroundCollider.REBUILD_DIST))
	var max_slice := 0
	var frames := 0
	while true:
		var s0 := Time.get_ticks_usec()
		gc.update(np)
		max_slice = maxi(max_slice, Time.get_ticks_usec() - s0)
		frames += 1
		if not gc.is_building() or frames > 4000:
			break
	print("    collider single-frame cost: OLD whole-region=%d us  vs  NEW worst incremental slice=%d us over %d frames (%d shapes)"
		% [full_us, max_slice, frames, nshapes])
	_ok(nshapes > 0, "collider-cheap: first (synchronous) build emitted shapes (%d)" % nshapes)
	_ok(frames > 1, "collider-cheap: incremental rebuild spreads across K>1 frames (K=%d)" % frames)
	_ok(max_slice * 2 < full_us, "collider-cheap: worst single-frame slice (%d us) is well under the whole-region cost (%d us)" % [max_slice, full_us])
	gc.queue_free()
	cw.queue_free()

# 2c. GroundCollider OVERLAY correctness (dug tunnels + placed structures). The freeze fix
# replaces ONLY the heavy generated_cell surface/tree read; the overlay/solidity logic that
# makes carved air and built geometry correct is UNTOUCHED. Proven three ways per the review:
#  (a) dig a vertical shaft → NO collision box in the carved-air cells, a floor box at the
#      true tunnel bottom, AND floor_under still falls into the hole (player never teleports
#      to the surface — the analytic physics in WorldManager is untouched);
#  (b) place a small structure (full cube + a shaped slab) → boxes/prisms match the placed
#      cells;
#  (c) the cheap surface_modifier/TreeGen substitution yields BYTE-IDENTICAL collider shapes
#      vs the OLD heavy generated_cell path (cell_value_at) over a plain, a dug, and a placed
#      column — read back straight from PhysicsServer.
func _test_collider_overlay_cases() -> void:
	print("[2c] collider overlay cases (dug tunnels + placed structures)")

	# --- (a) DUG SHAFT ---------------------------------------------------------
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var wd: WorldManager = _struct_world("ColDug")
	var gd := GroundCollider.new()
	get_root().add_child(gd)
	gd.setup(wd)
	VoxelBody.spawn_loose(wd, {Vector3i(cx, g + 20, cz): STONE}, wd)       # active-body gate: keep the collider live
	var dcenter := Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5)
	gd.update(dcenter)                                                     # first build → centre (cx,cz)
	var dug_ys := [g, g - 1, g - 2]                                        # dig the top 3 solid cells
	var dug_ok := true
	for dy: int in dug_ys:
		if wd.break_terrain(Vector3i(cx, dy, cz)) <= 0:
			dug_ok = false
	gd.rebuild_now()                                                       # rebuild over the dug overlay
	_settle_collider(gd, dcenter)                                          # drive the incremental build to completion
	_ok(dug_ok, "dug shaft: broke 3 surface cells (overlay = air)")
	var act_d := _collider_col(gd.active_rid(), cx, cz)
	var ref_d := _ref_col_heavy(wd, cx, cz, Vector2i(cx, cz))
	_ok(_cols_equal(act_d, ref_d), "dug shaft: collider shapes == OLD heavy-path shapes (byte-identical)")
	# No box may span any carved-air cell [dy, dy+1].
	var no_phantom := true
	for dy: int in dug_ys:
		for bx: Vector2 in act_d["boxes"]:
			if bx.x <= float(dy) + 0.001 and bx.y >= float(dy) + 1.0 - 0.001:
				no_phantom = false
	_ok(no_phantom, "dug shaft: NO collision box in the carved-air cells (no phantom shelf)")
	# A floor box exists whose TOP is the true tunnel bottom (top face at the lowest dug y).
	var tunnel_floor_top := float(g - 2)
	var has_floor := false
	for bx: Vector2 in act_d["boxes"]:
		if absf(bx.y - tunnel_floor_top) < 0.001:
			has_floor = true
	_ok(has_floor, "dug shaft: floor box top at the true tunnel bottom (y=%d)" % (g - 2))
	# Analytic player physics is UNTOUCHED: floor_under scans down into the shaft (never clamps
	# to the noise top), so a player over the hole falls to the tunnel floor, not the surface.
	var fu := wd.floor_under(float(cx) + 0.5, float(cz) + 0.5, float(g) + 0.5)
	_ok(fu < float(g) - 0.5 and absf(fu - float(g - 2)) < 0.001,
		"dug shaft: floor_under=%.2f is the tunnel floor (y-2), NOT the surface (no teleport)" % fu)
	gd.queue_free()
	wd.queue_free()

	# --- (b) PLACED STRUCTURE (full cube + shaped slab) ------------------------
	var wp: WorldManager = _struct_world("ColPlace")
	var gp := GroundCollider.new()
	get_root().add_child(gp)
	gp.setup(wp)
	VoxelBody.spawn_loose(wp, {Vector3i(cx, g + 20, cz): STONE}, wp)       # active-body gate: keep the collider live
	var pcenter := Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5)
	gp.update(pcenter)
	var slab_mod := ShapeCodec.make_modifier(1, 1, 1, 1, ShapeCodec.ANCHOR_BOTTOM)   # a half-slab
	var placed_cube := wp.place_block(Vector3i(cx, g + 1, cz), STONE)                # full cube on the surface
	var placed_slab := wp.place_block(Vector3i(cx, g + 2, cz), CellCodec.pack(STONE, slab_mod))
	gp.rebuild_now()
	_settle_collider(gp, pcenter)
	_ok(placed_cube and placed_slab, "placed structure: full cube (g+1) + slab (g+2) accepted")
	var act_p := _collider_col(gp.active_rid(), cx, cz)
	var ref_p := _ref_col_heavy(wp, cx, cz, Vector2i(cx, cz))
	_ok(_cols_equal(act_p, ref_p), "placed structure: collider shapes == OLD heavy-path shapes (byte-identical)")
	# The full cube at g+1 is covered by a solid box.
	var cube_covered := false
	for bx: Vector2 in act_p["boxes"]:
		if bx.x <= float(g + 1) + 0.001 and bx.y >= float(g + 2) - 0.001:
			cube_covered = true
	_ok(cube_covered, "placed structure: full cube at g+1 is covered by a collision box")
	# The shaped slab at g+2 is a convex prism (matches the placed geometry, not a full box).
	_ok(act_p["prisms"].has(g + 2), "placed structure: shaped slab at g+2 emits a convex prism")
	gp.queue_free()
	wp.queue_free()

# 2d. GroundCollider AMORTIZED rebuild (frame-budgeted + double-buffered). Proves the walking
# stutter is gone: no single update() pays the whole-region cost, the live collider keeps
# colliding mid-transition, and the SETTLED shapes are byte-identical to a full rebuild.
func _test_collider_amortized() -> void:
	print("[2d] collider amortized rebuild (frame-budgeted, double-buffered)")
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var cw: WorldManager = _struct_world("ColAmort")
	var gc := GroundCollider.new()
	get_root().add_child(gc)
	gc.setup(cw)
	VoxelBody.spawn_loose(cw, {Vector3i(cx, g + 20, cz): STONE}, cw)       # active-body gate: keep the collider live
	# First build is synchronous → the world has collision immediately at spawn/load.
	gc.update(Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5))
	_ok(not gc.is_building(), "amortized: first build completes synchronously (immediate collision)")
	var n0 := PhysicsServer3D.body_get_shape_count(gc.active_rid())
	_ok(n0 > 0, "amortized: first build emitted shapes (%d)" % n0)
	var rid0 := gc.active_rid()
	# Drift REBUILD_DIST blocks → an incremental rebuild. ONE update() must NOT finish it.
	var ncx := cx + GroundCollider.REBUILD_DIST
	var ncz := cz + GroundCollider.REBUILD_DIST
	var np := Vector3(float(ncx) + 0.5, float(g) + 2.0, float(ncz) + 0.5)
	var region_total := (2 * GroundCollider.R + 1) * (2 * GroundCollider.R + 1)
	gc.update(np)
	_ok(gc.is_building(), "amortized: one update() after an 8-block drift advances only a slice (region NOT built in one call)")
	# The live set is untouched during the transition — bodies keep colliding with the old set.
	_ok(gc.active_rid() == rid0 and PhysicsServer3D.body_get_shape_count(rid0) == n0,
		"amortized: live collider unchanged mid-transition (double-buffered; no partial set)")
	# Pump to completion; count frames and track the worst per-frame shape churn.
	var frames := 1
	var max_ops := gc.last_slice_ops()
	while gc.is_building() and frames <= 4000:
		gc.update(np)
		max_ops = maxi(max_ops, gc.last_slice_ops())
		frames += 1
	_ok(frames > 1, "amortized: incremental build spreads across K>1 frames (K=%d)" % frames)
	_ok(not gc.is_building(), "amortized: incremental build settles")
	# Settled shapes at the NEW centre == a full synchronous rebuild's output (byte-identical),
	# and the buffer actually swapped (live RID changed).
	_ok(gc.active_rid() != rid0, "amortized: buffer swapped to the freshly-built body")
	var act := _collider_col(gc.active_rid(), ncx, ncz)
	var ref := _ref_col_heavy(cw, ncx, ncz, Vector2i(ncx, ncz))
	_ok(_cols_equal(act, ref), "amortized: settled shapes == full-rebuild output at the new centre (byte-identical)")
	# A SECOND drift builds into the body that already holds a full set → exercises the SHAPE
	# REUSE path (body_set_shape in place, not clear-all+add-all) + any trim. Churn must stay
	# bounded here too — this is the periodic clear-spike the fix removes.
	var ncx2 := ncx + GroundCollider.REBUILD_DIST
	var ncz2 := ncz + GroundCollider.REBUILD_DIST
	var np2 := Vector3(float(ncx2) + 0.5, float(g) + 2.0, float(ncz2) + 0.5)
	var f2 := 0
	while f2 <= 4000:
		gc.update(np2)
		max_ops = maxi(max_ops, gc.last_slice_ops())
		f2 += 1
		if not gc.is_building():
			break
	print("    amortized: worst per-frame shape churn = %d ops (region ~%d shapes / %d columns) over 2 rebuilds"
		% [max_ops, n0, region_total])
	_ok(max_ops > 0, "amortized: (re)build does bounded work each frame (>0 ops)")
	_ok(max_ops < region_total, "amortized: NO single update() churns the whole region (%d ops << %d columns / ~%d shapes)" % [max_ops, region_total, n0])
	var act2 := _collider_col(gc.active_rid(), ncx2, ncz2)
	var ref2 := _ref_col_heavy(cw, ncx2, ncz2, Vector2i(ncx2, ncz2))
	_ok(_cols_equal(act2, ref2), "amortized: reuse-path rebuild settles byte-identical to a full rebuild")
	gc.queue_free()
	cw.queue_free()

# 2e. GroundCollider ACTIVE-BODY GATE (the exploration-jerkiness fix). The collider only serves
# loose VoxelBodies; the player is analytic. So with NO body near, update() must do ZERO work
# (the per-distance stutter while flying was this rebuild-on-drift cycle). Prove: (a) zero bodies
# → a long moving path drives NO build / zero shape churn; (b) spawning a body activates it and
# forces an immediate build (ground for the faller); (c) flying far from the debris idles it again;
# (d) the body count increments on spawn and decrements on free.
func _test_collider_gate() -> void:
	print("[2e] collider active-body gate (no rebuild while nothing is loose)")
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var cw := WorldManager.new()
	cw.name = "ColGate"
	get_root().add_child(cw)
	var gc := GroundCollider.new()
	get_root().add_child(gc)
	gc.setup(cw)
	# (a) ZERO loose bodies: a 40-step moving path must produce NO build and NO shape churn.
	_ok(cw.active_body_count() == 0, "gate: no loose bodies initially (count %d)" % cw.active_body_count())
	var churn := 0
	var ever_built := false
	for step in range(40):
		gc.update(Vector3(float(cx + step * 2) + 0.5, float(g) + 2.0, float(cz) + 0.5))
		churn += gc.last_slice_ops()
		if gc.is_building() or gc.active_rid().is_valid():
			ever_built = true
	_ok(churn == 0 and not ever_built,
		"gate: zero loose bodies → ZERO collider work over a 40-step moving path (churn=%d, built=%s)" % [churn, str(ever_built)])

	# (b) Spawn a loose body near the player → gate activates → collider builds IMMEDIATELY.
	var body := VoxelBody.spawn_loose(cw, {Vector3i(cx, g + 20, cz): STONE}, cw)
	_ok(cw.active_body_count() == 1 and cw.has_active_bodies(), "gate: body-count increments on spawn (%d)" % cw.active_body_count())
	_ok(cw.has_active_bodies_near(Vector2i(cx, cz), GroundCollider.R), "gate: has_active_bodies_near true for the nearby body")
	gc.update(Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5))
	_ok(gc.active_rid().is_valid() and PhysicsServer3D.body_get_shape_count(gc.active_rid()) > 0,
		"gate: first body spawn → collider builds immediately (ground for the falling body)")

	# (c) Fly 200 blocks from the debris → gate turns OFF (exploration after a break leaves debris
	# behind, and the collider must NOT keep churning around the departing player). P2: the gate now
	# RETAINS its shape set while off (so reactivation pays no synchronous rebuild), so active_rid()
	# stays valid — the invariant is that it does ZERO further rebuild work while gated.
	gc.update(Vector3(float(cx + 200) + 0.5, float(g) + 2.0, float(cz) + 0.5))
	_ok(gc.is_gated() and not gc.is_building(),
		"gate: flying 200 blocks from the debris → collider gated OFF (idle, shapes retained)")
	var churn_far := 0
	for step in range(20):
		gc.update(Vector3(float(cx + 200 + step) + 0.5, float(g) + 2.0, float(cz) + 0.5))
		churn_far += gc.last_slice_ops()
	_ok(churn_far == 0, "gate: ZERO rebuild churn while gated + exploring away (churn=%d)" % churn_far)

	# (d) Free the body → count decrements.
	body.free()
	_ok(cw.active_body_count() == 0 and not cw.has_active_bodies(), "gate: body-count decrements when the body is freed (%d)" % cw.active_body_count())
	gc.queue_free()
	cw.queue_free()

# 2f. DORMANT-BY-DEFAULT PHYSICS. The world holds many persistent bodies, so physics must be
# dormant unless disturbed: a settled body freezes (→ zero per-frame cost), the collider counts
# ONLY awake bodies (a pile of frozen debris near the player costs nothing), and a break/contact
# wakes dormant bodies. Proven end-to-end here.
func _test_physics_dormancy() -> void:
	print("[2f] dormant-by-default physics (freeze settled / gate on awake / wake on disturbance)")
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var w := WorldManager.new()
	w.name = "Dormancy"
	get_root().add_child(w)
	var gc := GroundCollider.new()
	get_root().add_child(gc)
	gc.setup(w)
	var center := Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5)
	# A ground body resting on the surface (grounded via the analytic check, no physics stepping).
	var body := VoxelBody.spawn_loose(w, {Vector3i(cx, g + 1, cz): STONE}, w)
	_ok(body != null and body.is_awake(), "dormancy: freshly-spawned body is AWAKE")
	_ok(w.awake_body_count() == 1, "dormancy: awake count 1 after spawn")
	gc.update(center)
	_ok(gc.active_rid().is_valid() and PhysicsServer3D.body_get_shape_count(gc.active_rid()) > 0,
		"dormancy: collider active while a body is awake")

	# (1) DWELL BEFORE FREEZE (P0). A grounded, at-rest body must NOT freeze on a single calm frame
	# (that caught bodies mid-bounce, freezing them in mid-air) — it freezes only after
	# SETTLE_DWELL_SEC of CONTINUOUS calm. At 0.016 s/tick, 0.5 s ≈ 32 ticks.
	var dwell_ticks := int(ceil(VoxelBody.SETTLE_DWELL_SEC / 0.016))
	for _tick in range(dwell_ticks - 3):
		body._physics_process(0.016)
	_ok(not body.freeze, "dormancy: body does NOT freeze before the settle dwell elapses (~%d ticks)" % dwell_ticks)
	# A hot frame mid-dwell RESETS the timer — a body cannot freeze at a bounce apex / zero-crossing.
	body.linear_velocity = Vector3(1.0, 0.0, 0.0)
	body._physics_process(0.016)
	body.linear_velocity = Vector3.ZERO
	_ok(not body.freeze, "dormancy: a hot frame mid-dwell resets the timer (no premature mid-motion freeze)")
	# Now let the full dwell elapse with sustained calm → it freezes → dormant.
	var froze := false
	for _tick in range(dwell_ticks + 4):
		body._physics_process(0.016)
		if body.freeze:
			froze = true
			break
	_ok(froze, "dormancy: after SETTLE_DWELL_SEC of sustained calm, a grounded body freezes")
	_ok(not body.is_awake() and not body.is_physics_processing(),
		"dormancy: a frozen body is DORMANT — not awake, _physics_process OFF (zero per-frame cost)")
	_ok(w.awake_body_count() == 0, "dormancy: awake count drops to 0 once settled (body still present)")

	# (1b) A calm but UNSUPPORTED body must NEVER freeze — it has to keep falling, not freeze in
	# mid-air. (Support is confirmed analytically at dwell expiry; no ground below → no freeze.)
	var airborne := VoxelBody.spawn_loose(w, {Vector3i(cx, g + 30, cz): STONE}, w)
	for _tick in range(dwell_ticks + 10):
		airborne._physics_process(0.016)
	_ok(not airborne.freeze, "dormancy: a calm but unsupported body never freezes mid-air (keeps falling)")
	airborne.free()

	# (2) collider stays GATED with only a FROZEN body near — zero rebuild churn. P2: the gate now
	# RETAINS shapes while off (active_rid stays valid), so the invariant is ZERO further work, not a
	# discarded shape set.
	var churn := 0
	for step in range(20):
		gc.update(Vector3(float(cx + step) + 0.5, float(g) + 2.0, float(cz) + 0.5))
		churn += gc.last_slice_ops()
	_ok(churn == 0 and gc.is_gated(),
		"dormancy: only a FROZEN body near → collider gated (shapes retained), ZERO rebuild churn (churn=%d)" % churn)

	# (3) wake-on-break: digging the surface under the frozen body wakes it → collider reactivates.
	w.break_terrain(Vector3i(cx, g, cz))
	_ok(body.is_awake() and body.is_physics_processing(), "dormancy: a break near a frozen body WAKES it (dynamic again)")
	_ok(w.awake_body_count() == 1, "dormancy: awake count back to 1 after wake-on-break")
	gc.update(center)
	_ok(gc.active_rid().is_valid() and PhysicsServer3D.body_get_shape_count(gc.active_rid()) > 0,
		"dormancy: the woken body reactivates the collider (ground for the faller)")
	gc.queue_free()
	w.queue_free()

	# (4) wake-on-contact for WOOD (sandbox-dynamic): a sleeping wood body is dormant; Godot wakes it
	# on contact/push (impulse) — modelled here by wake() clearing the sleep.
	var w2 := WorldManager.new()
	w2.name = "DormancyWood"
	get_root().add_child(w2)
	var wood := VoxelBody.spawn_loose(w2, {Vector3i(cx, g + 1, cz): WOOD}, w2)
	_ok(wood != null and wood._is_wood, "dormancy: wood body is sandbox-dynamic (never auto-freezes)")
	wood.sleeping = true                          # Godot auto-sleeps a wood body at rest
	_ok(not wood.is_awake() and w2.awake_body_count() == 0, "dormancy: a SLEEPING wood body is dormant (not counted)")
	wood.wake()                                   # contact/push wakes it (Godot-native; modelled by wake())
	_ok(wood.is_awake() and w2.awake_body_count() == 1, "dormancy: contact/push wakes the sleeping wood body")
	w2.queue_free()

## Drive an incremental GroundCollider (re)build to completion by pumping update() (simulating
## physics frames), so a test can read the settled shape set. Pumps through the P2 edit DEBOUNCE
## (a pending rebuild has not started building yet) AND the incremental build. Bounded so a bug
## can't hang verify.
func _settle_collider(gc: GroundCollider, center: Vector3) -> void:
	for _i in range(6000):
		gc.update(center)
		if not gc.is_building() and not gc.is_pending():
			return

## Read the collider's emitted shapes at column (cx,cz) straight from PhysicsServer, grouped
## as box vertical-spans (Vector2(bottom,top)) and prism cell-ys — so a test can compare the
## ACTUAL collider output against a reference.
func _collider_col(rid: RID, cx: int, cz: int) -> Dictionary:
	var boxes: Array = []
	# A shaped cell emits >1 convex triangle-prism; collect the SET of prism cell-ys (the
	# modifier that fixes the triangle count is computed identically on both paths, so the
	# cell set is the byte-identity signal — see _ref_col_heavy, which marks one per cell).
	var prism_set := {}
	var n := PhysicsServer3D.body_get_shape_count(rid)
	for i in n:
		var sh: RID = PhysicsServer3D.body_get_shape(rid, i)
		var stype := PhysicsServer3D.shape_get_type(sh)
		if stype == PhysicsServer3D.SHAPE_BOX:
			var o: Vector3 = PhysicsServer3D.body_get_shape_transform(rid, i).origin
			if int(floor(o.x)) == cx and int(floor(o.z)) == cz:
				var half: Vector3 = PhysicsServer3D.shape_get_data(sh)
				boxes.append(Vector2(o.y - half.y, o.y + half.y))
		elif stype == PhysicsServer3D.SHAPE_CONVEX_POLYGON:
			var pts: PackedVector3Array = PhysicsServer3D.shape_get_data(sh)   # world-space (identity xform)
			if pts.size() > 0:
				var mn := pts[0]
				for p: Vector3 in pts:
					mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
				if int(floor(mn.x + 0.001)) == cx and int(floor(mn.z + 0.001)) == cz:
					prism_set[int(floor(mn.y + 0.001))] = true
	boxes.sort_custom(func(a, b): return a.x < b.x)
	var prisms: Array = prism_set.keys()
	prisms.sort()
	return {"boxes": boxes, "prisms": prisms}

## Reference: the OLD (pre-fix) collider column algorithm, using the HEAVY generated_cell path
## (world.cell_value_at) for every cell. Byte-for-byte the code the fix replaced, so a match
## against the live collider proves the cheap surface_modifier/TreeGen substitution changed
## nothing observable. y_lo is derived exactly as the collider does (region-min surface).
func _ref_col_heavy(world: WorldManager, cx: int, cz: int, center: Vector2i) -> Dictionary:
	var R: int = GroundCollider.R
	var min_h := 0x7fffffff
	for i in (2 * R + 1):
		for j in (2 * R + 1):
			var hh: int = TerrainConfig.height_at(center.x - R + i, center.y - R + j)
			if hh < min_h:
				min_h = hh
	var y_lo := min_h - GroundCollider.DEPTH
	var h: int = TerrainConfig.height_at(cx, cz)
	var boxes: Array = []
	var prisms: Array = []
	var run_start := 0x7fffffff
	var y := y_lo
	while world.is_removed(Vector3i(cx, y, cz)):
		y -= 1
	while y <= h:
		var ov: int = world.placed_cells().get(Vector3i(cx, y, cz), -1)
		var modifier := 0
		if ov > 0:
			modifier = CellCodec.modifier(ov)
		elif ov < 0 and y == h:
			modifier = CellCodec.modifier(world.cell_value_at(Vector3i(cx, y, cz)))
		if ov == 0:
			if run_start != 0x7fffffff:
				boxes.append(Vector2(float(run_start), float(y)))
				run_start = 0x7fffffff
		elif modifier != 0:
			if run_start != 0x7fffffff:
				boxes.append(Vector2(float(run_start), float(y)))
				run_start = 0x7fffffff
			prisms.append(y)
		elif run_start == 0x7fffffff:
			run_start = y
		y += 1
	var y_top := maxi(h + TreeGen.MAX_ABOVE_SURFACE, world.placed_top(cx, cz))
	while y <= y_top:
		var v: int = world.cell_value_at(Vector3i(cx, y, cz))
		var mat: int = CellCodec.mat(v)
		if mat != BlockCatalog.AIR and CellCodec.modifier(v) != 0:
			if run_start != 0x7fffffff:
				boxes.append(Vector2(float(run_start), float(y)))
				run_start = 0x7fffffff
			prisms.append(y)
		elif mat != BlockCatalog.AIR:
			if run_start == 0x7fffffff:
				run_start = y
		elif run_start != 0x7fffffff:
			boxes.append(Vector2(float(run_start), float(y)))
			run_start = 0x7fffffff
		y += 1
	if run_start != 0x7fffffff:
		boxes.append(Vector2(float(run_start), float(y_top + 1)))
	boxes.sort_custom(func(a, b): return a.x < b.x)
	prisms.sort()
	return {"boxes": boxes, "prisms": prisms}

func _cols_equal(a: Dictionary, b: Dictionary) -> bool:
	var ab: Array = a["boxes"]
	var bb: Array = b["boxes"]
	if ab.size() != bb.size():
		return false
	for i in ab.size():
		if absf(ab[i].x - bb[i].x) > 0.001 or absf(ab[i].y - bb[i].y) > 0.001:
			return false
	var ap: Array = a["prisms"]
	var bp: Array = b["prisms"]
	if ap.size() != bp.size():
		return false
	for i in ap.size():
		if ap[i] != bp[i]:
			return false
	return true

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
	var after := -1
	var placed := world.place_block(c, STONE)
	_ok(placed, "place_block STONE succeeds")
	_ok(world.block_id_at(c) == STONE, "cell is stone after place")
	_ok(world.place_block(c, STONE) == false, "place into occupied cell fails")
	_ok(world.place_block(Vector3i(cx, g + 1, cz), 0) == false, "place invalid id fails")
	if ground != null and ground.active_rid().is_valid():
		after = PhysicsServer3D.body_get_shape_count(ground.active_rid())
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

# P6a. Per-cell METADATA store + STATE-axis lifecycle (VDS §14 P1 / §15.3 leak tests).
# No shipped material declares has_block_entity yet (like state layouts), so the test
# flips the flag on a live VoxelState to exercise the machinery, then restores it —
# gameplay data stays byte-identical. Asserts: (a) zero-cost default (empty _meta on a
# metadata-free world), (b) round-trip through get_metadata, (c) break + collapse FREE
# metadata and fire the orphan signal, (d) non-block-entity materials reject metadata,
# (e) the JSON-subset validator rejects Object/NaN/INF/oversize, (f) set_state round-trips
# through the state projection and PRESERVES metadata with no orphan.
func _test_metadata() -> void:
	print("[P6a] per-cell metadata store + state-axis lifecycle")
	var world: WorldManager = _struct_world("P6aMeta")
	var orphans: Array = []
	world.block_entity_orphaned.connect(func(c: Vector3i, m: Dictionary) -> void: orphans.append([c, m]))

	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var cell := Vector3i(cx, g + 1, cz)

	# (a) ZERO-COST DEFAULT: a pristine world has an EMPTY _meta, and plain cube
	# place/break edits never allocate a metadata entry.
	_ok(world._meta.size() == 0, "zero-cost default: _meta empty on a pristine world")
	world.place_block(cell, STONE)
	world.break_terrain(cell, Vector3.INF)
	world.place_block(cell, STONE)
	_ok(world._meta.size() == 0, "plain place/break creates NO metadata entries (zero-cost default holds)")
	_ok(orphans.is_empty(), "no orphan signal from plain edits")
	world.break_terrain(cell, Vector3.INF)

	# has_block_entity is false for every shipped material until we flip one.
	var BE := STONE
	var st: VoxelState = BlockCatalog.state_of(BE)
	var prev_flag := st.has_block_entity
	_ok(not BlockCatalog.has_block_entity(BE), "has_block_entity is false for shipped materials (default)")
	st.has_block_entity = true
	_ok(BlockCatalog.has_block_entity(BE), "has_block_entity true after the flag is set")

	# (d) metadata on a NON-block-entity material is rejected, writes nothing.
	_ok(world.place_block(cell, GRASS), "place a grass cell (non block-entity)")
	_ok(world.set_metadata(cell, {"k": 1}) == false, "set_metadata REJECTED on a non-block-entity material")
	_ok(world._meta.size() == 0, "rejected metadata wrote nothing")
	world.break_terrain(cell, Vector3.INF)

	# (b) ROUND-TRIP on a block-entity cell (nested doc: bool/int/float/String/Array/Dict).
	_ok(world.place_block(cell, BE), "place a block-entity cell")
	var doc := {"label": "chest", "count": 7, "open": false, "items": [1, 2, 3], "sub": {"x": 1.5}}
	_ok(world.set_metadata(cell, doc), "set_metadata on the block-entity cell succeeds")
	_ok(world.has_metadata(cell), "has_metadata true after set")
	_ok(world._meta.size() == 1, "exactly one metadata entry stored")
	_ok(world.get_metadata(cell) == doc, "get_metadata round-trips the document (deep equal)")
	# returned document is a COPY — mutating it must not change the stored state.
	var got := world.get_metadata(cell)
	got["count"] = 999
	_ok(world.get_metadata(cell)["count"] == 7, "get_metadata returns a copy (no aliasing into the store)")

	# (e) JSON-subset validator rejects an Object, NaN, INF, a non-String key, and an
	# oversize document; every rejection leaves the good document intact (validate-first).
	_ok(world.set_metadata(cell, {"bad": world}) == false, "validator rejects an Object value")
	_ok(world.set_metadata(cell, {"nan": NAN}) == false, "validator rejects a NaN float")
	_ok(world.set_metadata(cell, {"inf": INF}) == false, "validator rejects an INF float")
	_ok(world.set_metadata(cell, {1: "int-key"}) == false, "validator rejects a non-String key")
	var big := ""
	for _i in range(WorldManager.META_MAX_BYTES + 100):
		big += "x"
	_ok(world.set_metadata(cell, {"blob": big}) == false, "validator rejects an oversize document (> cap)")
	_ok(world.get_metadata(cell) == doc, "all rejected writes left the good document intact")

	# (f) set_state round-trips through the state projection + canonical, and PRESERVES
	# metadata (the one write that does) with no orphan.
	orphans.clear()
	_ok(world.set_state(cell, 5), "set_state succeeds on the block-entity cell")
	_ok(CellCodec.state(world.cell_value_at(cell)) == 5, "state axis reads back 5 (projection + canonical)")
	_ok(world.block_id_at(cell) == BE, "set_state left the material projection unchanged")
	_ok(world.get_metadata(cell) == doc, "set_state KEPT the metadata (preserving write)")
	_ok(orphans.is_empty(), "set_state fired NO orphan signal")
	_ok(world.set_state(Vector3i(cx, g + 40, cz), 3) == false, "set_state on an air cell fails")

	# (c) BREAK frees the metadata (_meta shrinks back) + fires the orphan once with the doc.
	orphans.clear()
	_ok(world.break_terrain(cell, Vector3.INF) == BE, "break returns the material id (hotbar contract intact)")
	_ok(world._meta.size() == 0, "break FREED the metadata entry (_meta shrank back to 0)")
	_ok(not world.has_metadata(cell), "has_metadata false after break")
	_ok(orphans.size() == 1, "break fired the orphan signal exactly once")
	if orphans.size() == 1:
		_ok(orphans[0][0] == cell and orphans[0][1] == doc, "orphan carried the cell + the old document")
	world.queue_free()

	# (c') COLLAPSE-undercut also frees metadata (the historically-forgotten path, §16):
	# a block-entity cell riding a cluster that detaches is carved through _write_cell(c,0),
	# so its metadata is freed + orphaned. Build a stone pillar with a 1-shelf block-entity
	# cell on top, set metadata, then break the pillar top so the shelf loses support.
	var patch := _flat_patch5()
	if patch.x != 0x7fffffff:
		var px := patch.x
		var pz := patch.y
		var pg: int = TerrainConfig.height_at(px, pz)
		var w2 := _struct_world("P6aCollapse")
		var orphans2: Array = []
		w2.block_entity_orphaned.connect(func(c: Vector3i, m: Dictionary) -> void: orphans2.append([c, m]))
		for k in range(1, 4):
			w2.place_block(Vector3i(px, pg + k, pz), BE)       # pillar of 3
		var shelf := Vector3i(px + 1, pg + 3, pz)              # 1-shelf off the pillar top (air below)
		_ok(w2.place_block(shelf, BE) and w2.block_id_at(shelf) == BE, "collapse: 1-shelf block-entity cell HOLDS")
		var sdoc := {"note": "spawner", "runs": 42}
		_ok(w2.set_metadata(shelf, sdoc) and w2.has_metadata(shelf), "collapse: metadata set on the shelf cell")
		orphans2.clear()
		w2.break_terrain(Vector3i(px, pg + 3, pz), Vector3.INF)   # remove the shelf's support
		_ok(not w2.has_metadata(shelf) and w2.block_id_at(shelf) != BE,
			"collapse: undercut shelf detached and its metadata was FREED")
		var found_orphan := false
		for o: Array in orphans2:
			if o[0] == shelf and o[1] == sdoc:
				found_orphan = true
		_ok(found_orphan, "collapse: orphan signal fired for the carved block-entity cell with its doc")
		w2.queue_free()
	else:
		_ok(false, "collapse: found a flat patch for the collapse-frees-metadata test")

	st.has_block_entity = prev_flag                            # restore (gameplay data untouched)

# JSON-canonical normalization of a metadata document: the exact form it takes after one
# round-trip through the §5 UTF-8-JSON metadata layer. JSON has no int/float distinction,
# so bare ints normalize to float; everything else (strings, bools, finite floats, arrays,
# nested dicts, key set) is preserved. This IS the metadata fidelity guarantee for a
# JSON-based layer, and lets the round-trip assert exact deep-equality against it.
func _json_norm(d: Dictionary) -> Variant:
	return JSON.parse_string(JSON.stringify(d))

# P6b. ZoneChunk container + edit-overlay save/load (VOXEL-DATA-STRUCTURE §5/§15). Asserts:
# (a) round-trip fidelity — a region mixing full cubes, shaped cells (non-zero modifier), a
# state-bearing cell, a dug-to-air cell and a metadata-bearing block-entity cell serializes
# → deserializes with every cell's (material, modifier, state) exact and metadata canonical;
# unset cells stay absent (fall back to the generator). Both the raw container round-trip
# AND the live save_edits/load_edits path (through _write_cell) are exercised. (b) zero-cost —
# an all-cube chunk carries NO modifier/state/metadata layers (layer_flags bits clear) and
# lands near the §5.5 ~8.2 KiB budget; uniform air / empty-overlay chunks are a handful of
# bytes. (c) id-map stability — a chunk deserialized under a DIFFERENT dense-id assignment
# (a remap resolver) resolves materials by NAME, not by the saving session's ids. (d) an
# unknown material name resolves to a logged placeholder, never a crash.
func _test_zonechunk() -> void:
	print("[P6b] ZoneChunk container + edit-overlay save/load")
	var RAMP := ShapeCodec.make_modifier(2, 2, 0, 0)   # non-zero modifier (a wedge)
	var SLAB := ShapeCodec.make_modifier(1, 1, 1, 1)    # non-zero modifier (a half-slab)

	# ---- (a1) RAW CONTAINER round-trip fidelity ------------------------------------
	# Build a chunk directly (the container is a dumb byte store — canonicalization is the
	# world's job, so we feed already-canonical packed values and expect an exact echo).
	var i_cube := ZoneChunk.local_index(1, 1, 1)
	var i_ramp := ZoneChunk.local_index(2, 1, 1)
	var i_state := ZoneChunk.local_index(3, 1, 1)
	var i_both := ZoneChunk.local_index(4, 1, 1)        # shaped AND state-bearing
	var i_air := ZoneChunk.local_index(5, 1, 1)         # a dug-to-air edit (present, value 0)
	var i_meta := ZoneChunk.local_index(6, 1, 1)        # metadata-bearing
	var i_unset := ZoneChunk.local_index(7, 1, 1)       # never set → must stay absent

	var v_cube := CellCodec.pack(STONE)
	var v_ramp := CellCodec.pack(GRASS, RAMP)
	var v_state := CellCodec.pack(WOOD, 0, 5)
	var v_both := CellCodec.pack(STONE, SLAB, 3)
	# A JSON-round-trip-STABLE document (only strings/bools/finite floats/nested) so the
	# reloaded document deep-equals the original EXACTLY, and a second doc with a bare int
	# to fence the canonical-JSON (int→float) normalization.
	var doc := {"label": "chest", "fill": 0.5, "open": false, "tags": ["a", "b"], "sub": {"ratio": 1.25}}
	var doc_int := {"count": 7, "name": "spawner"}

	var zc := ZoneChunk.new()
	zc.set_cell(i_cube, v_cube)
	zc.set_cell(i_ramp, v_ramp)
	zc.set_cell(i_state, v_state)
	zc.set_cell(i_both, v_both)
	zc.set_cell(i_air, 0)                                # air is a REAL present material
	zc.set_cell(i_meta, v_cube, doc)

	var bytes := zc.to_bytes()
	var zc2 := ZoneChunk.from_bytes(bytes)

	_ok(zc2.present_count() == 6, "raw round-trip: present cell count preserved (6, got %d)" % zc2.present_count())
	_ok(zc2.material_name_at(i_cube) == "stone" and zc2.modifier_at(i_cube) == 0 and zc2.state_at(i_cube) == 0,
		"raw round-trip: full cube (stone, mod 0, state 0) exact")
	_ok(zc2.material_name_at(i_ramp) == "grass" and zc2.modifier_at(i_ramp) == RAMP and zc2.state_at(i_ramp) == 0,
		"raw round-trip: shaped cell (grass ramp modifier) exact")
	_ok(zc2.material_name_at(i_state) == "wood" and zc2.modifier_at(i_state) == 0 and zc2.state_at(i_state) == 5,
		"raw round-trip: state-bearing cell (wood, state 5) exact")
	_ok(zc2.material_name_at(i_both) == "stone" and zc2.modifier_at(i_both) == SLAB and zc2.state_at(i_both) == 3,
		"raw round-trip: shaped+stated cell (stone, slab, state 3) exact")
	_ok(zc2.material_name_at(i_air) == "air" and zc2.modifier_at(i_air) == 0,
		"raw round-trip: dug-to-air cell present as 'air' (distinct from unset)")
	_ok(zc2.meta_at(i_meta) != null and zc2.meta_at(i_meta) == doc,
		"raw round-trip: metadata document deep-equals the original (JSON-stable doc)")
	_ok(zc2.material_name_at(i_unset) == "" and not zc2.present_indices().has(i_unset),
		"raw round-trip: an unset cell stays ABSENT (falls back to the generator on load)")

	# metadata with a bare int normalizes to its canonical-JSON form (int → float) and is
	# otherwise exact — the honest fidelity guarantee of a UTF-8-JSON metadata layer.
	var zc3 := ZoneChunk.new()
	zc3.set_cell(i_meta, v_cube, doc_int)
	var zc3b := ZoneChunk.from_bytes(zc3.to_bytes())
	_ok(zc3b.meta_at(i_meta) == _json_norm(doc_int),
		"raw round-trip: int-bearing metadata equals its canonical-JSON form (7 → 7.0)")

	# ---- (b) ZERO-COST DEFAULT ------------------------------------------------------
	# An all-cube chunk: every one of the 32768 cells present as a full cube over a 4-material
	# palette (2-bit indices). NO modifier/state/metadata layers, size near the §5.5 budget.
	var mats := [BlockCatalog.AIR, GRASS, DIRT, STONE]
	var allcube := ZoneChunk.new()
	for idx in range(ZoneChunk.CELLS):
		allcube.set_cell(idx, CellCodec.pack(mats[idx & 3]))
	_ok(allcube.layer_flags() == 0, "zero-cost: all-cube chunk has NO modifier/state/meta layers (flags == 0)")
	var allcube_size := allcube.to_bytes().size()
	print("    all-cube 32^3 chunk serializes to %d bytes (§5.5 target ~8.2 KiB)" % allcube_size)
	_ok(allcube_size >= 8192 and allcube_size <= 8400,
		"zero-cost: all-cube chunk size ~8.2 KiB (2-bit dense material layer only, got %d)" % allcube_size)
	# a round-trip of the all-cube chunk still resolves every cell to its material.
	var allcube2 := ZoneChunk.from_bytes(allcube.to_bytes())
	var dense_ok := allcube2.present_count() == ZoneChunk.CELLS
	for idx in [0, 1, 2, 3, 100, 32767]:                 # cell idx carries material mats[idx & 3]
		if allcube2.material_name_at(idx) != BlockCatalog.name_of(mats[idx & 3]):
			dense_ok = false
	_ok(dense_ok, "zero-cost: all-cube chunk round-trips (dense material layer intact)")
	# uniform all-air (all present, one palette entry) and an empty overlay (all unset) are tiny.
	var alluniform := ZoneChunk.new()
	for idx in range(ZoneChunk.CELLS):
		alluniform.set_cell(idx, 0)                      # every cell present as air
	var uniform_size := alluniform.to_bytes().size()
	_ok(uniform_size <= 16, "zero-cost: uniform all-air chunk is a handful of bytes (%d, no index array)" % uniform_size)
	var empty_size := ZoneChunk.new().to_bytes().size()
	_ok(empty_size <= 16, "zero-cost: empty (all-unset) overlay chunk is a handful of bytes (%d)" % empty_size)

	# ---- (a2) LIVE save_edits / load_edits through the write choke point -------------
	# Build a supported pillar of edits (full cube + shaped + state + block-entity metadata)
	# on a flat patch, save the overlay to bytes, and load into a FRESH world; assert every
	# edited cell round-trips exactly and an UNEDITED cell falls back to the generator.
	var patch := _flat_patch5()
	if patch.x == 0x7fffffff:
		_ok(false, "P6b: found a flat patch for the live save/load round-trip")
		return
	var px := patch.x
	var pz := patch.y
	var pg: int = TerrainConfig.height_at(px, pz)
	# Flip a block-entity capability on so the metadata cell keeps its document (as _test_metadata does).
	var BE := STONE
	var be_state: VoxelState = BlockCatalog.state_of(BE)
	var prev_be := be_state.has_block_entity
	be_state.has_block_entity = true

	var w1 := _struct_world("P6bSave")
	var c_cube := Vector3i(px, pg + 1, pz)               # rests on the grass surface
	var c_ramp := Vector3i(px, pg + 2, pz)               # on top of the cube
	var c_be := Vector3i(px, pg + 3, pz)                 # block-entity cell on top
	_ok(w1.place_block(c_cube, CellCodec.pack(STONE)), "live save: place a full cube (supported)")
	_ok(w1.place_block(c_ramp, CellCodec.pack(GRASS, RAMP)), "live save: place a shaped ramp on top")
	_ok(w1.set_state(c_cube, 5), "live save: set a state on the cube cell")
	_ok(w1.place_block(c_be, CellCodec.pack(BE)), "live save: place the block-entity cell")
	var live_doc := {"label": "furnace", "lit": true, "progress": 0.75}
	_ok(w1.set_metadata(c_be, live_doc), "live save: attach metadata to the block-entity cell")

	var edited := [c_cube, c_ramp, c_be]
	# a deep-ground cell we NEVER edit — must fall back to the generator after load.
	var c_unedited := Vector3i(px, pg - 5, pz)
	var unedited_gen := TerrainConfig.generated_cell(c_unedited.x, c_unedited.y, c_unedited.z)

	# Round-trip every touched 32^3 region through bytes into a fresh world.
	var regions := {}
	for c: Vector3i in edited:
		regions[WorldManager.region_origin_of(c)] = true
	var w2 := _struct_world("P6bLoad")
	for ro: Vector3i in regions.keys():
		var region_bytes := w1.save_edits(ro).to_bytes()
		w2.load_edits(ro, ZoneChunk.from_bytes(region_bytes))

	var fidelity_ok := true
	for c: Vector3i in edited:
		if w2.cell_value_at(c) != w1.cell_value_at(c):
			fidelity_ok = false
	_ok(fidelity_ok, "live save/load: every edited cell's packed value (mat|modifier|state) restored exactly")
	_ok(CellCodec.mat(w2.cell_value_at(c_cube)) == STONE and CellCodec.state(w2.cell_value_at(c_cube)) == 5,
		"live save/load: the state axis survived the round-trip (stone, state 5)")
	_ok(CellCodec.modifier(w2.cell_value_at(c_ramp)) == RAMP,
		"live save/load: the shaped ramp modifier survived the round-trip")
	_ok(w2.has_metadata(c_be) and w2.get_metadata(c_be) == _json_norm(live_doc),
		"live save/load: block-entity metadata restored (canonical-JSON, through _write_cell)")
	_ok(w2.cell_value_at(c_unedited) == unedited_gen,
		"live save/load: an UNEDITED cell falls back to the generated function (not clobbered)")
	w1.queue_free()
	w2.queue_free()

	# ---- (c) ID-MAP STABILITY (materials travel by NAME, not by dense id) ------------
	# Serialize a stone cell, then load it under a resolver that maps names to DIFFERENT
	# dense ids than the saving session used. The loaded material must follow the NAME.
	var zc_stone := ZoneChunk.new()
	var i_s := ZoneChunk.local_index(0, 0, 0)
	zc_stone.set_cell(i_s, CellCodec.pack(STONE))
	var loaded_stone := ZoneChunk.from_bytes(zc_stone.to_bytes())
	var remap := func(nm: StringName) -> int:
		if nm == &"stone":
			return DIRT                                  # deliberately a DIFFERENT id than STONE
		return BlockCatalog.id_of(nm)
	var w3 := _struct_world("P6bRemap")
	var s_cell := Vector3i(0, 40, 0)                     # air far above ground — placing an edit is unconstrained
	w3.load_edits(WorldManager.region_origin_of(s_cell), loaded_stone, remap)
	# region_origin_of(s_cell) + local(0,0,0) lands at the region origin; assert THAT cell.
	var s_target := WorldManager.region_origin_of(s_cell) + ZoneChunk.from_local_index(i_s)
	_ok(w3.block_id_at(s_target) == DIRT,
		"id-map stability: 'stone' resolved by NAME to the remapped id (DIRT), not the saved id")
	w3.queue_free()

	# ---- (d) UNKNOWN NAME → PLACEHOLDER (no crash) -----------------------------------
	# A resolver that fails to resolve every name; a wood cell must load as the placeholder
	# material (stone), loudly, without crashing or losing the edit.
	var zc_wood := ZoneChunk.new()
	zc_wood.set_cell(i_s, CellCodec.pack(WOOD))
	var loaded_wood := ZoneChunk.from_bytes(zc_wood.to_bytes())
	var unknown := func(_nm: StringName) -> int: return -1
	var w4 := _struct_world("P6bUnknown")
	w4.load_edits(WorldManager.region_origin_of(s_cell), loaded_wood, unknown)
	var placeholder_id := BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
	_ok(w4.block_id_at(s_target) == placeholder_id and placeholder_id > 0,
		"unknown name: unresolved material loaded as the placeholder (stone), no crash, edit kept")
	_ok(w4.block_id_at(s_target) != WOOD, "unknown name: placeholder is distinct from the saved material")
	w4.queue_free()

	be_state.has_block_entity = prev_be                  # restore (gameplay data untouched)

# P6c-1. Dynamic material catalog (RUNTIME-MATERIAL-STREAMING §2/§5/§6/§7/§8, §11 subset):
# the GMID⇄LRID identity model + material-document serialization + placeholder/late
# resolution — the core of runtime material streaming. Asserts: (a) the STATIC FACADE is
# unchanged — every existing catalog query returns today's values and the pre-P6c golden
# asserts stay green (the bootstrap catalog behaves exactly as today; streaming is inert
# until used); (c) GMID = sha256 of the exact document bytes (same bytes → same GMID, a
# changed field → a different GMID); (b) register_material of a SYNTHETIC material returns
# a fresh LRID, to_document→from_document round-trips it byte-stably, and it RENDERS on
# both paths (ARID lazily allocated via P5's table on the module path); (d) an unknown GMID
# → an UNRESOLVED magenta placeholder registered under the TRUE GMID (data round-trips
# losslessly); (e) late-resolution fills the SAME LRID in place (id unchanged, physics/look
# now real, the Material instance swapped in place with no rebake). Runs LAST so the
# synthetic materials it appends never perturb the count()==77 bootstrap assertions above.
func _test_dynamic_catalog() -> void:
	print("[P6c-1] dynamic material catalog (GMID ⇄ LRID + streaming)")

	# (a) STATIC FACADE UNCHANGED: the bootstrap catalog behaves exactly as today.
	_ok(BlockCatalog.count() == 77, "static facade: count() still 77 (bootstrap = core+world)")
	_ok(BlockCatalog.key_of(0) == &"air", "static facade: LRID 0 is the reserved 'air' key")
	for id in [GRASS, DIRT, STONE, WOOD, LEAF]:
		var nm := BlockCatalog.name_of(id)
		_ok(BlockCatalog.id_of(StringName(nm)) == id, "static facade: id_of(name_of(%d)) == %d" % [id, id])
		_ok(BlockCatalog.is_resolved(id), "static facade: bootstrap material %s is RESOLVED" % nm)
	# aliases still resolve to the frozen core ids (unchanged behaviour).
	_ok(BlockCatalog.id_of(&"oak_log") == WOOD and BlockCatalog.id_of(&"oak_leaves") == LEAF,
		"static facade: core aliases (oak_log/oak_leaves) still resolve to WOOD/LEAF")
	# every bootstrap LRID now carries a stable "<sha256 gmid>#<state>" key that round-trips.
	var key_stone := BlockCatalog.key_of(STONE)
	_ok(String(key_stone).begins_with("sha256:") and String(key_stone).ends_with("#stone"),
		"static facade: stone key is '<sha256 gmid>#stone' (got %s)" % key_stone)
	_ok(BlockCatalog.lrid_of(key_stone) == STONE, "static facade: lrid_of(key_of(STONE)) round-trips")
	_ok(String(BlockCatalog.gmid_of(STONE)).begins_with("sha256:"), "static facade: stone has a sha256 GMID")
	# the pre-P6c golden asserts still hold (redundant tripwire over unchanged data).
	_ok(BlockCatalog.check_against_data().is_empty(), "static facade: golden blocks.json↔catalog check still green")
	_ok(is_equal_approx(BlockCatalog.mass_of(STONE), 1500.0) and BlockCatalog.anchors_of(WOOD) == Vector3i(36, 24, 16),
		"static facade: core masses/anchors unchanged")

	# (c) GMID = sha256 over the document bytes (RMS §2.2): same bytes → same GMID; a
	# changed field → a different GMID (content-addressed, no canonicalization trap).
	var doc_a := _synthetic_document("voxiverse:testium", "solid", 1234.0, Color(0.5, 0.25, 0.75, 1.0))
	var gmid_a := MaterialDocument.gmid_of(doc_a)
	_ok(String(gmid_a).begins_with("sha256:") and String(gmid_a).length() == 71,
		"GMID is 'sha256:' + 64 hex chars (got %s)" % gmid_a)
	var doc_a2 := _synthetic_document("voxiverse:testium", "solid", 1234.0, Color(0.5, 0.25, 0.75, 1.0))
	_ok(doc_a2 == doc_a, "GMID: an identical def serializes to identical bytes (deterministic)")
	_ok(MaterialDocument.gmid_of(doc_a2) == gmid_a, "GMID stable: same bytes → same GMID")
	var doc_b := _synthetic_document("voxiverse:testium", "solid", 1235.0, Color(0.5, 0.25, 0.75, 1.0))  # mass 1234→1235
	_ok(MaterialDocument.gmid_of(doc_b) != gmid_a, "GMID: a changed field (mass) → a different GMID")

	# (b) REGISTER a synthetic material at runtime → a fresh LRID; the document round-trips
	# byte-stably (from→to reproduces the GMID); it renders.
	var before := BlockCatalog.count()
	var def_a := MaterialDocument.from_document(doc_a)
	_ok(def_a != null, "from_document parses the synthetic material")
	_ok(MaterialDocument.gmid_of(MaterialDocument.to_document(def_a)) == gmid_a,
		"document round-trip: to_document(from_document(bytes)) reproduces the GMID (byte-stable)")
	var lrid_a := BlockCatalog.register_material(gmid_a, def_a)
	_ok(lrid_a >= before, "register_material returns a FRESH LRID (>= old count %d, got %d)" % [before, lrid_a])
	_ok(BlockCatalog.count() == before + 1, "register_material appended exactly one LRID (single-state material)")
	_ok(is_equal_approx(BlockCatalog.mass_of(lrid_a), 1234.0), "streamed material mass reads through the facade (1234)")
	_ok(BlockCatalog.name_of(lrid_a) == "solid", "streamed material name reads through the facade")
	_ok(BlockCatalog.is_solid_id(lrid_a) and BlockCatalog.is_resolved(lrid_a), "streamed material is a valid RESOLVED id")
	_ok(BlockCatalog.gmid_of(lrid_a) == gmid_a, "streamed material's LRID maps back to its GMID")
	_ok(BlockCatalog.lrid_of(BlockCatalog.key_of(lrid_a)) == lrid_a, "streamed material key round-trips to its LRID")
	# idempotent: re-registering the same (gmid, state) returns the SAME LRID, appends nothing.
	_ok(BlockCatalog.register_material(gmid_a, MaterialDocument.from_document(doc_a)) == lrid_a,
		"register_material idempotent: same (gmid,state) → same LRID")
	_ok(BlockCatalog.count() == before + 1, "idempotent re-registration appended nothing")
	# it RENDERS on the fallback path: a live LRID always yields a non-null material.
	_ok(BlockMaterials.get_for(lrid_a) != null, "streamed material renders (fallback: non-null material)")
	# MaterialRegistry.register_document is the ingestion funnel (validate → GMID → register → store bytes).
	var doc_reg := _synthetic_document("voxiverse:regium", "solid", 555.0, Color(0.25, 0.5, 0.25, 1.0))
	var gmid_reg := MaterialRegistry.register_document(doc_reg)
	_ok(gmid_reg == MaterialDocument.gmid_of(doc_reg), "register_document returns the content GMID")
	_ok(MaterialRegistry.has_document(gmid_reg) and MaterialRegistry.document_bytes(gmid_reg) == doc_reg,
		"register_document keeps the exact bytes in the content store")
	_ok(BlockCatalog.lrid_of(StringName(String(gmid_reg) + "#solid")) >= 0, "register_document registered the material")
	# a malformed document is rejected WHOLE (count unchanged, GMID unresolved).
	var cnt_pre_bad := BlockCatalog.count()
	_ok(MaterialRegistry.register_document("{\"voxiverse_material\":1}".to_utf8_buffer()) == &"",
		"register_document rejects a malformed document (no states) → empty GMID")
	_ok(BlockCatalog.count() == cnt_pre_bad, "rejected document appended nothing (count unchanged)")

	# module path: a material registered AFTER setup has no cube ARID yet; arid_for lazily
	# bakes one so the ARID is renderable (never a hole, F5), growing the appearance table.
	if ClassDB.class_exists("VoxelTerrain"):
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		var built: bool = mw.call("setup")
		_ok(built, "streaming render: module world builds")
		if built:
			var ac0: int = mw.call("appearance_count")
			var doc_r := _synthetic_document("voxiverse:renderium", "solid", 900.0, Color(0.5, 0.75, 0.25, 1.0))
			var lrid_r := BlockCatalog.register_material(MaterialDocument.gmid_of(doc_r), MaterialDocument.from_document(doc_r))
			_ok(lrid_r >= 0, "streaming render: material registered after setup")
			var arid_r: int = mw.call("arid_for", lrid_r, 0)
			_ok(arid_r >= 0 and bool(mw.call("can_render", arid_r)),
				"streaming render: lazy cube ARID is baked + renderable (never a hole)")
			_ok(int(mw.call("appearance_count")) == ac0 + 1,
				"streaming render: exactly one cube model appended + baked for the streamed LRID")
			_ok(int(mw.call("arid_for", lrid_r, 0)) == arid_r,
				"streaming render: cube ARID stable on re-lookup (no duplicate append)")
			_ok(int(mw.call("appearance_count")) == ac0 + 1, "streaming render: no duplicate model for the same LRID")
		mw.queue_free()
	else:
		print("    (godot_voxel module absent — streamed-material ARID checked on module builds only)")

	# (d) UNKNOWN GMID → an UNRESOLVED magenta placeholder under the TRUE GMID (RMS §8):
	# world data round-trips losslessly (the cell keeps its true identity), only the
	# behaviour/look are provisional.
	var doc_p := _synthetic_document("voxiverse:latium", "solid", 4321.0, Color(0.25, 0.5, 0.75, 1.0))
	var gmid_p := MaterialDocument.gmid_of(doc_p)
	var cnt_before_p := BlockCatalog.count()
	var lrid_p := BlockCatalog.register_placeholder(gmid_p, &"solid")
	_ok(lrid_p >= cnt_before_p, "placeholder: an unknown GMID registers a fresh LRID")
	_ok(BlockCatalog.count() == cnt_before_p + 1, "placeholder: appended exactly one LRID")
	_ok(not BlockCatalog.is_resolved(lrid_p), "placeholder: the LRID is UNRESOLVED")
	_ok(BlockCatalog.gmid_of(lrid_p) == gmid_p, "placeholder: registered under the TRUE GMID (identity preserved)")
	_ok(BlockCatalog.color_of(lrid_p) == Color(1, 0, 1, 1), "placeholder: magenta look")
	_ok(is_equal_approx(BlockCatalog.mass_of(lrid_p), 1000.0), "placeholder: default physics (mass 1000)")
	_ok(BlockCatalog.solidity_of(lrid_p) >= 0.5 and BlockCatalog.is_solid_id(lrid_p),
		"placeholder: solid + valid placeable id (data loads losslessly)")
	# establish the placeholder's magenta render material so late-resolution must swap it.
	var mat_p: StandardMaterial3D = BlockMaterials.get_for(lrid_p)
	_ok(mat_p != null and mat_p.albedo_color == Color(1, 0, 1, 1), "placeholder: renders the magenta swatch")
	# idempotent: re-requesting the same placeholder returns the SAME LRID.
	_ok(BlockCatalog.register_placeholder(gmid_p, &"solid") == lrid_p, "placeholder: idempotent (same LRID)")

	# (e) LATE RESOLUTION: supplying the real document resolves the SAME LRID in place —
	# id unchanged, physics/look now real, the Material instance swapped in place.
	var def_p := MaterialDocument.from_document(doc_p)
	var lrid_resolved := BlockCatalog.register_material(gmid_p, def_p)
	_ok(lrid_resolved == lrid_p, "late resolution: the SAME LRID resolved in place (id unchanged)")
	_ok(BlockCatalog.count() == cnt_before_p + 1, "late resolution: NO new LRID appended")
	_ok(BlockCatalog.is_resolved(lrid_p), "late resolution: the LRID is now RESOLVED")
	_ok(is_equal_approx(BlockCatalog.mass_of(lrid_p), 4321.0), "late resolution: physics now real (mass 4321)")
	_ok(BlockCatalog.name_of(lrid_p) == "solid", "late resolution: the name resolves")
	_ok(BlockCatalog.color_of(lrid_p) == Color(0.25, 0.5, 0.75, 1.0), "late resolution: look now real (catalog swatch)")
	# the SAME cached Material instance was swapped in place — no new instance, no rebake.
	_ok(BlockMaterials.get_for(lrid_p) == mat_p, "late resolution: same Material instance (in-place swap)")
	_ok(mat_p.albedo_color == Color(0.25, 0.5, 0.75, 1.0), "late resolution: the material look swapped to the real colour")

# Serialize a synthetic single-state material to its document bytes (a test fixture for
# the streaming path). Uses float32-exact swatch/mass values so the JSON round-trip is
# byte-stable (GMID assertions above rely on it).
func _synthetic_document(mat_name: String, state_name: String, mass: float, swatch: Color) -> PackedByteArray:
	var st := VoxelState.new()
	st.state_name = StringName(state_name)
	st.mass = mass
	st.density = mass
	st.break_force = 800.0
	st.solidity = 1.0
	st.tint = swatch
	st.structural_class = &"rock"
	st.strength_anchors = Vector3i(8, 4, 2)
	var def := VoxelMaterialDef.new()
	def.id = StringName(mat_name)
	def.states = [st]
	def.default_state_index = 0
	return MaterialDocument.to_document(def)

# P6c-2. Zone bundles (RUNTIME-MATERIAL-STREAMING §2.6/§3.4/§5, §11 remainder): the final piece
# of runtime material streaming — a self-contained payload (manifest + id-map + ZoneChunk(s)) that
# carries the block MATERIALS a receiver has never seen alongside the voxel data, keyed by
# cross-session GMID. Asserts: (1) ZONE-BUNDLE ROUND-TRIP — a region of synthetic streamed
# materials (+ shapes + state + a metadata cell + a dug-to-air cell) saves → bundle bytes → loads
# into a FRESH bootstrap-only catalog with every cell's (material-by-GMID, modifier, state) +
# metadata identical (the manifest made it self-contained); (2) SHUFFLED-LOAD-ORDER GMID ROUND-TRIP
# (the crux) — a session that pre-registers the SAME materials in the REVERSE order (so dense LRIDs
# differ) loads the bundle correctly by GMID, proving dense ids never cross the boundary; (3) DEDUP
# — loading a bundle whose GMIDs are already registered reuses their LRIDs (no duplicates); (4)
# SCALE SANITY — 1000 register_material calls allocate monotonic bounded LRIDs, the facade still
# answers, and (module path) the batched ARID bake handles a large library without error. Runs
# LAST and resets the catalog around each phase, so the count()==77 bootstrap asserts above stand.
func _test_zone_bundle() -> void:
	print("[P6c-2] zone bundles (manifest + id-map + bulk inject) + shuffled-load-order round-trip")
	var RAMP := ShapeCodec.make_modifier(2, 2, 0, 0)   # a non-zero (wedge) modifier

	# ---- SESSION A: fresh catalog; register 3 synthetic materials in order X, Y, Z ----------
	BlockCatalog.reset_session()
	var base := BlockCatalog.count()                   # bootstrap-only baseline (77)
	var doc_x := _bundle_doc("voxiverse:alfa", "solid", 800.0, Color(0.9, 0.1, 0.1, 1.0), false)
	var doc_y := _bundle_doc("voxiverse:bravo", "solid", 900.0, Color(0.1, 0.9, 0.1, 1.0), false)
	var doc_z := _bundle_doc("voxiverse:charlie", "chest", 1000.0, Color(0.1, 0.1, 0.9, 1.0), true)
	var gx := MaterialDocument.gmid_of(doc_x)
	var gy := MaterialDocument.gmid_of(doc_y)
	var gz := MaterialDocument.gmid_of(doc_z)
	_ok(gx != gy and gy != gz and gx != gz, "bundle: three synthetic materials have distinct GMIDs")
	var kx := String(gx) + "#solid"
	var ky := String(gy) + "#solid"
	var kz := String(gz) + "#chest"
	MaterialRegistry.register_document(doc_x)
	MaterialRegistry.register_document(doc_y)
	MaterialRegistry.register_document(doc_z)
	var lA_x := BlockCatalog.lrid_of(StringName(kx))
	var lA_y := BlockCatalog.lrid_of(StringName(ky))
	var lA_z := BlockCatalog.lrid_of(StringName(kz))
	_ok(lA_x == base and lA_y == base + 1 and lA_z == base + 2,
		"bundle: session A assigns dense LRIDs in registration order X,Y,Z (%d,%d,%d)" % [lA_x, lA_y, lA_z])

	# Build a supported region of edits using them (mirrors the P6b live-save pattern).
	var patch := _flat_patch5()
	if patch.x == 0x7fffffff:
		_ok(false, "P6c-2: found a flat patch for the zone-bundle round-trip")
		BlockCatalog.reset_session()
		return
	var px := patch.x
	var pz := patch.y
	var pg: int = TerrainConfig.height_at(px, pz)
	var wA := _struct_world("P6c2Save")
	var c_x := Vector3i(px, pg + 1, pz)                # alfa cube (rests on the grass surface)
	var c_y := Vector3i(px, pg + 2, pz)                # bravo ramp on top
	var c_z := Vector3i(px, pg + 3, pz)                # charlie (block-entity): state + metadata
	var c_air := Vector3i(px + 1, pg, pz)              # a dug-to-air cell (present, value 0)
	_ok(wA.place_block(c_x, CellCodec.pack(lA_x)), "bundle: place alfa cube")
	_ok(wA.place_block(c_y, CellCodec.pack(lA_y, RAMP)), "bundle: place bravo ramp")
	_ok(wA.place_block(c_z, CellCodec.pack(lA_z)), "bundle: place charlie block-entity cube")
	_ok(wA.set_state(c_z, 5), "bundle: set a state on the charlie cell")
	var live_doc := {"label": "vault", "locked": true, "fill": 0.5}
	_ok(wA.set_metadata(c_z, live_doc), "bundle: attach metadata to the charlie cell")
	_ok(wA.break_terrain(c_air, Vector3.INF) > 0, "bundle: dig a surface cell to air")

	# Record the cross-session expectation (GMID + axes) for every cell.
	var cells := [c_x, c_y, c_z, c_air]
	var expect := {}
	for c: Vector3i in cells:
		var v := wA.cell_value_at(c)
		expect[c] = {"gmid": BlockCatalog.gmid_of(CellCodec.mat(v)),
			"mod": CellCodec.modifier(v), "state": CellCodec.state(v)}

	var region_set := {}
	for c: Vector3i in cells:
		region_set[WorldManager.region_origin_of(c)] = true
	var bundle := wA.save_bundle(region_set.keys())
	_ok(bundle.material_count() == 3, "bundle: manifest holds 3 materials (got %d)" % bundle.material_count())
	var idmap := bundle.id_map()
	_ok(idmap.has(ZoneBundle.AIR_KEY), "bundle: id-map includes the reserved 'air' key (no document needed)")
	_ok(idmap.has(kx) and idmap.has(kz),
		"bundle: id-map binds container ids to cross-session '<gmid>#<state>' keys")
	var bytes := bundle.to_bytes()
	_ok(bytes.size() > 0, "bundle: serializes to bytes (%d)" % bytes.size())
	_ok(ZoneBundle.from_bytes(bytes).to_bytes() == bytes, "bundle: to_bytes→from_bytes→to_bytes is byte-stable")
	wA.queue_free()

	# ---- (1) ZONE-BUNDLE ROUND-TRIP into a FRESH catalog state ------------------------------
	BlockCatalog.reset_session()
	_ok(BlockCatalog.count() == base, "round-trip: fresh session is bootstrap-only again (%d)" % BlockCatalog.count())
	_ok(BlockCatalog.lrid_of(StringName(kx)) < 0, "round-trip: alfa is UNKNOWN to the fresh catalog before load")
	var wB := _struct_world("P6c2Load")
	wB.load_bundle(ZoneBundle.from_bytes(bytes))
	var rt_ok := true
	for c: Vector3i in cells:
		var v := wB.cell_value_at(c)
		var e: Dictionary = expect[c]
		if BlockCatalog.gmid_of(CellCodec.mat(v)) != e["gmid"] \
				or CellCodec.modifier(v) != e["mod"] or CellCodec.state(v) != e["state"]:
			rt_ok = false
	_ok(rt_ok, "round-trip: every cell's (material-by-GMID, modifier, state) restored exactly")
	_ok(wB.has_metadata(c_z) and wB.get_metadata(c_z) == _json_norm(live_doc),
		"round-trip: block-entity metadata restored (material learned from the bundle manifest)")
	_ok(wB.block_id_at(c_air) == BlockCatalog.AIR, "round-trip: the dug-to-air cell restored as air")
	_ok(BlockCatalog.is_resolved(BlockCatalog.lrid_of(StringName(kx))),
		"round-trip: manifest materials registered + RESOLVED (self-contained bundle)")
	wB.queue_free()

	# ---- (2) SHUFFLED-LOAD-ORDER GMID ROUND-TRIP (the crux) ---------------------------------
	# A fresh session pre-registers the SAME materials in the REVERSE order, so their dense LRIDs
	# differ from session A. Loading the bundle must resolve every cell by GMID regardless.
	BlockCatalog.reset_session()
	MaterialRegistry.register_document(doc_z)          # reverse order: Z, Y, X
	MaterialRegistry.register_document(doc_y)
	MaterialRegistry.register_document(doc_x)
	var lC_z := BlockCatalog.lrid_of(StringName(kz))
	var lC_x := BlockCatalog.lrid_of(StringName(kx))
	_ok(lC_z == base and lC_x == base + 2,
		"shuffled: session C assigns LRIDs in reverse order (Z=%d, X=%d)" % [lC_z, lC_x])
	_ok(lC_x != lA_x and lC_z != lA_z,
		"shuffled: dense LRIDs DIFFER between sessions (alfa %d→%d, charlie %d→%d)" % [lA_x, lC_x, lA_z, lC_z])
	var cnt_before := BlockCatalog.count()
	var wC := _struct_world("P6c2Shuffle")
	wC.load_bundle(ZoneBundle.from_bytes(bytes))
	var sh_ok := true
	for c: Vector3i in cells:
		var v := wC.cell_value_at(c)
		var e: Dictionary = expect[c]
		if BlockCatalog.gmid_of(CellCodec.mat(v)) != e["gmid"] \
				or CellCodec.modifier(v) != e["mod"] or CellCodec.state(v) != e["state"]:
			sh_ok = false
	_ok(sh_ok, "shuffled: cells resolve by GMID to the right materials despite different dense ids")
	_ok(CellCodec.mat(wC.cell_value_at(c_x)) == lC_x and lC_x != lA_x,
		"shuffled: alfa cell resolved to session C's dense id (%d), not the saved id (%d) — dense ids never travel" % [lC_x, lA_x])

	# ---- (3) DEDUP: an already-registered GMID reuses its LRID (no duplicate) ----------------
	_ok(BlockCatalog.count() == cnt_before,
		"dedup: load_bundle allocated NO new LRIDs (all 3 GMIDs already registered) — count stable at %d" % cnt_before)
	_ok(BlockCatalog.lrid_of(StringName(kx)) == lC_x, "dedup: alfa reused its pre-registered LRID (no duplicate)")
	wC.queue_free()

	# ---- (4) SCALE SANITY (headless proxy for §7.2; the true 4k/8k wasm bake is deferred) ----
	BlockCatalog.reset_session()
	var scale_base := BlockCatalog.count()
	var N := 1000
	var mono_ok := true
	var last_lrid := scale_base - 1
	for i in range(N):
		var d := _bundle_doc("voxiverse:scale_%d" % i, "solid", 100.0 + float(i), Color(0.5, 0.5, 0.5, 1.0), false)
		var lr := BlockCatalog.register_material(MaterialDocument.gmid_of(d), MaterialDocument.from_document(d))
		if lr != last_lrid + 1 or lr >= BlockCatalog.CAPACITY:
			mono_ok = false
		last_lrid = lr
	_ok(mono_ok, "scale: %d register_material calls allocate MONOTONIC, bounded LRIDs (< CAPACITY)" % N)
	_ok(BlockCatalog.count() == scale_base + N, "scale: catalog grew by exactly %d (count %d)" % [N, BlockCatalog.count()])
	var facade_ok := true
	for i: int in [0, N / 2, N - 1]:
		var lr: int = scale_base + i
		if not is_equal_approx(BlockCatalog.mass_of(lr), 100.0 + float(i)) \
				or BlockCatalog.name_of(lr) != "solid" or not BlockCatalog.is_resolved(lr):
			facade_ok = false
	_ok(facade_ok, "scale: the catalog facade answers mass/name/resolved correctly at scale")
	if ClassDB.class_exists("VoxelTerrain"):
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		var built: bool = mw.call("setup")
		_ok(built, "scale: module world builds its library at %d materials (batched bake OK)" % BlockCatalog.count())
		if built:
			var ac0: int = mw.call("appearance_count")
			var arid: int = mw.call("arid_for", scale_base + N - 1, 0)
			_ok(arid >= 0 and bool(mw.call("can_render", arid)),
				"scale: a streamed material's cube ARID bakes + renders (never a hole)")
			_ok(int(mw.call("appearance_count")) >= ac0, "scale: appearance table grew without drift/error")
		mw.queue_free()
		print("    NOTE: true 4k/8k wasm bake benchmark needs a browser (SharedArrayBuffer/COOP-COEP) — deferred (RMS §3.2 / §10 Phase 4).")
	else:
		print("    (godot_voxel module absent — scale-sanity ARID bake path checked on module builds only)")

	# Leave the catalog reset to bootstrap so the run ends in a clean, documented state.
	BlockCatalog.reset_session()

# Serialize a synthetic single-state material for the zone-bundle tests, with an optional
# block-entity capability (so a bundle can carry a metadata-bearing cell). float32-exact
# swatch/mass so the document byte-round-trips stably (GMID stability, RMS §2.2).
func _bundle_doc(mat_name: String, state_name: String, mass: float, swatch: Color, block_entity: bool) -> PackedByteArray:
	var st := VoxelState.new()
	st.state_name = StringName(state_name)
	st.mass = mass
	st.density = mass
	st.break_force = 800.0
	st.solidity = 1.0
	st.tint = swatch
	st.structural_class = &"rock"
	st.strength_anchors = Vector3i(64, 32, 16)
	st.has_block_entity = block_entity
	var def := VoxelMaterialDef.new()
	def.id = StringName(mat_name)
	def.states = [st]
	def.default_state_index = 0
	return MaterialDocument.to_document(def)
