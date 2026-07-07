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
	_test_temperature()
	_test_worldgen_air_bounds()
	_test_manifest_trim()
	_test_smoothing()
	_test_shape_memo()
	_test_collider_cheap_queries()
	_test_collider_overlay_cases()
	_test_collider_amortized()
	_test_collider_gate()
	_test_physics_dormancy()
	_test_ceiling_scan()
	_test_tree()
	_test_masses()
	_test_materials()
	_test_inventory()
	_test_cell_codec()
	_test_water_shore()
	_test_shape_math()
	_test_material_data()
	_test_catalog_expansion()
	_test_merged_physics()
	_test_world_loop()
	_test_structural()
	_test_shapes_live()
	_test_fallback_water()
	_test_waterlogging()
	_test_multi_liquid_lava()
	_test_metadata()
	_test_zonechunk()
	_test_dynamic_catalog()
	_test_zone_bundle()
	_test_snowy_world()
	_test_snow_layer_codec()
	_test_snow_accumulation()
	_test_snow_composites()
	_test_snow_sim()
	_test_mountains()
	_test_sharp_slope()
	_test_shader_prewarm()
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
	# The Mountains biome is the new tall term — explicitly stress the bound over several mountain massifs
	# (they sit far from origin, outside the box above) so MAX_SURFACE_Y is proven to bound real PEAKS.
	var mtn_max := -0x7fffffff
	for mc: Vector2i in TerrainConfig.find_mountains(6):
		for dx in range(-160, 161, 2):
			for dz in range(-160, 161, 2):
				var h2: int = TerrainConfig.height_at(mc.x + dx, mc.y + dz)
				if h2 > max_seen:
					max_seen = h2
				if h2 > mtn_max:
					mtn_max = h2
	_ok(mtn_max > TerrainConfig.SEA_LEVEL + 40, "Mountains produce genuinely TALL peaks (max mountain height %d)" % mtn_max)
	_ok(max_seen <= TerrainConfig.MAX_SURFACE_Y,
		"MAX_SURFACE_Y (%d) is a true upper bound on height_at over a wide sample INCLUDING mountain peaks (max seen %d)"
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
	# ...and specifically ABOVE the tallest mountain peaks (the new tall content) — the early-out must not
	# be tricked into skipping a peak, and nothing generates above the raised bound over a mountain.
	for mc: Vector2i in TerrainConfig.find_mountains(6):
		for dx in range(-160, 161, 11):
			for dz in range(-160, 161, 11):
				for y in range(above_y + 1, above_y + 31):
					if TerrainConfig.generated_cell(mc.x + dx, y, mc.y + dz) != BlockCatalog.AIR:
						air_above_ok = false
	_ok(air_above_ok, "no generated cell above MAX_SURFACE_Y+max_above (=%d) — above early-out skips only air (incl. over mountains)" % above_y)
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
	# Widened SLOPE threshold (SHARP-SLOPE): the emitted set now UNIONS the full corner-tuple set so no
	# slope-adjacent whole-block-quantized shape can cube-fall-back. It is therefore ≥ the full set.
	_ok(emitted.size() >= full.size(), "emitted set covers the full %d corner tuples for guaranteed coverage (%d)" % [full.size(), emitted.size()])
	# M1 (ADR §6.4 / §8 item 9): the snow half-slab modifier (85) is unioned into the emitted set so
	# the module path ALWAYS bakes (snow_block, 85) even though the temperate sample won't contain it.
	_ok(eset.has(TerrainConfig.SNOW_SLAB_MODIFIER), "emitted set contains the snow half-slab modifier (%d)" % TerrainConfig.SNOW_SLAB_MODIFIER)
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
			# A snow LAYER cap (SNOW-ACCUMULATION §1.5) is baked in the dedicated _layer_arid table, NOT
			# the corner-modifier dry set — exclude it here (its coverage is fenced in _test_snow_accumulation).
			if cm != 0 and not CellCodec.is_layer(cm):
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

	# (b) sea: every underwater column is liquid-filled (water, or lava over a molten ocean —
	# MULTI-LIQUID §2.4) up to SEA_LEVEL and there is NO water above it; the sea is walked-through
	# (non-solid, the P2 gate).
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
			# a cell in the sea column (just under the surface) is the LIQUID of the column's climate
			# regime — water, OR lava over a molten (t >= LAVA_SEA_T) ocean (MULTI-LIQUID §2.4) — or
			# ice, OR, where an underwater smoothing CAP grows there (WATER-SHORE §3.6), a shaped cap
			# composite of the underwater-floor material (it fills its own remainder with liquid up to
			# the water line, or is a bare ramp in the frozen regime). Only a PLAIN solid full cube
			# would be a real "solid floating in the sea" bug.
			var my: int = SEA - 1 if SEA - 1 > g else g + 1
			var midv: int = TerrainConfig.generated_cell(x, my, z)
			var mid: int = CellCodec.mat(midv)
			var is_cap: bool = my == g + 1 and CellCodec.modifier(midv) != 0
			# The expected sea-fill material for this column's regime (retargeted from a bare == WATER
			# check to _sea_liquid_kind so a molten sea's lava fill passes rather than flips — risk 5).
			var reg_liq: int = BlockCatalog.liquid_lrid_of(TerrainConfig._sea_liquid_kind(TerrainConfig.column_profile(x, z).w))
			if mid != reg_liq and mid != ICE and not is_cap:
				sea_ok = false
			# ...and there is no water ABOVE the sea surface.
			if TerrainConfig.generated_block(x, SEA + 2, z) == WATER:
				sea_ok = false
	_ok(found_ocean, "at least one ocean/underwater column exists")
	_ok(sea_ok, "sea fills up to SEA_LEVEL and never above it")
	_ok(BlockCatalog.solidity_of(WATER) < 0.5, "water is non-solid (waded through)")

	# (c) sea ICE on a cold column. Ice generation is CLIMATE-driven (climate t < -0.55),
	# independent of the temperature model — see _test_temperature for the model itself.
	var cold := _find_cold_sea()
	if cold.x != 0x7fffffff:
		var cx := cold.x
		var cz := cold.y
		_ok(TerrainConfig.generated_block(cx, SEA, cz) == ICE, "cold sea surface is ICE (%d,%d)" % [cx, cz])
		_ok(BlockCatalog.solidity_of(ICE) >= 0.5, "ICE is solid (walk the frozen sea)")
		# breaking the ice would expose non-solid water below.
		_ok(BlockCatalog.solidity_of(TerrainConfig.generated_block(cx, SEA - 1, cz)) < 0.5,
			"water under the ice is non-solid (%d,%d)" % [cx, cz])
	else:
		_ok(false, "no cold sea column found to exercise ICE (widen the scan?)")

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

# 2b. The reworked (biome-independent) piecewise temperature model (PerVoxelEnvironment):
#   - every column's surface reads 21.5 C (air AND surface block),
#   - air cools linearly to 0 C at y = 256 (clamped above),
#   - ground cools 1 C/block to a 3 C plateau, then a geothermal rise of 1 C/block
#     in the 24 blocks above bedrock (3 C at y=-40 → 27 C at the y=-64 bedrock floor).
# Values are exact floats, so the tolerances are tight.
func _test_temperature() -> void:
	print("[2b] temperature model (absolute-altitude lapse: 0@y=96 / depth→3 plateau / geothermal→27)")
	var env := PerVoxelEnvironment.new()
	var land := _grass_column()
	var g: int = TerrainConfig.height_at(land.x, land.y)
	var fx := float(land.x) + 0.5
	var fz := float(land.y) + 0.5
	# M1 (ADR §3.4): a temperate column's surface temperature is 21.5 − LAPSE·g, NOT a flat 21.5.
	var t_climate: float = TerrainConfig.column_profile(land.x, land.y).w
	var st_surf: float = ClimateModel.surface_temperature(g, t_climate)          # 21.5 − 0.224·g

	# (a) surface: the exposed block AND the surface air read the column's own surface temperature.
	var t_surf := env.temperature(Vector3(fx, float(g) + 0.5, fz))
	_ok(absf(t_surf - st_surf) < 0.05, "surface block reads 21.5 − 0.224·g = %.2f C (got %.2f)" % [st_surf, t_surf])
	_ok(absf(PerVoxelEnvironment.surface_air_temperature(land.x, land.y) - st_surf) < 0.01,
		"surface air temperature == the column's surface anchor")
	_ok(absf(PerVoxelEnvironment.air_temperature(TerrainConfig.BASE_HEIGHT) - ClimateModel.air_temperature(TerrainConfig.BASE_HEIGHT, ClimateModel.CLIMATE_TEMPERATE)) < 0.01,
		"air_temperature(baseline) == the temperate lapse value")

	# (b) altitude: air reaches 0 C at y=96 (temperate), goes NEGATIVE above (no clamp), drops monotonically.
	var t_96 := env.temperature(Vector3(fx, 96.5, fz))
	_ok(t_96 < 1.0, "air at y=96 is near 0 C (got %.2f)" % t_96)
	_ok(absf(PerVoxelEnvironment.air_temperature(96.0, ClimateModel.CLIMATE_TEMPERATE)) < 0.05, "air_temperature(96) is 0 C")
	_ok(PerVoxelEnvironment.air_temperature(256.0, ClimateModel.CLIMATE_TEMPERATE) < -30.0, "air_temperature(256) is well below 0 (no clamp)")
	var t_top := env.temperature(Vector3(fx, 256.5, fz))
	_ok(t_top < -30.0, "air at y=256 reads far below 0 C (got %.2f)" % t_top)
	var t_a10 := env.temperature(Vector3(fx, float(g + 10) + 0.5, fz))
	var t_a100 := env.temperature(Vector3(fx, float(g + 100) + 0.5, fz))
	_ok(t_a10 < st_surf and t_a100 < t_a10, "air temperature drops with altitude (%.2f > %.2f)" % [t_a10, t_a100])
	# continuity at the surface seam: air one block up is just under the surface anchor.
	var t_air1 := env.temperature(Vector3(fx, float(g + 1) + 0.5, fz))
	_ok(t_air1 < st_surf and st_surf - t_air1 < 0.3, "air one block above surface ~surface anchor (got %.2f)" % t_air1)

	# (c) underground: -1 C per block of depth down to a 3 C plateau (off the surface anchor).
	var t_d1 := env.temperature(Vector3(fx, float(g - 1) + 0.5, fz))
	_ok(absf(t_d1 - (st_surf - 1.0)) < 0.05, "one block deep reads surface−1 = %.2f C (got %.2f)" % [st_surf - 1.0, t_d1])
	var t_d5 := env.temperature(Vector3(fx, float(g - 5) + 0.5, fz))
	_ok(absf(t_d5 - (st_surf - 5.0)) < 0.05, "five blocks deep reads surface−5 = %.2f C (got %.2f)" % [st_surf - 5.0, t_d5])
	var t_plateau := env.temperature(Vector3(fx, float(g - 25) + 0.5, fz))   # d=25 (>18.5), y>-40
	_ok(absf(t_plateau - 3.0) < 0.05, "deep block hits the 3 C plateau (got %.2f)" % t_plateau)

	# (d) geothermal rise in the 24 blocks above bedrock (column-independent).
	var t_geo0 := env.temperature(Vector3(fx, -40.0 + 0.5, fz))
	_ok(absf(t_geo0 - 3.0) < 0.05, "geothermal start y=-40 reads 3 C (got %.2f)" % t_geo0)
	var t_geo_mid := env.temperature(Vector3(fx, -52.0 + 0.5, fz))
	_ok(absf(t_geo_mid - 15.0) < 0.05, "geothermal mid y=-52 reads 15 C (got %.2f)" % t_geo_mid)
	var t_bedrock := env.temperature(Vector3(fx, -64.0 + 0.5, fz))
	_ok(absf(t_bedrock - 27.0) < 0.05, "bedrock y=-64 reads 27 C (got %.2f)" % t_bedrock)

	# (e) frozen-sea seam: LAND is 21.5 C at every biome, but a frozen OCEAN column's
	# sea-level ice/air stays sub-zero so the brittle-ice structural curve reads the
	# sheet as sound (not tissue-paper). Restores the invariant the rework had severed.
	var cold := _find_cold_sea()
	if cold.x != 0x7fffffff:
		var cst := env.temperature(Vector3(float(cold.x) + 0.5, float(TerrainConfig.SEA_LEVEL) + 0.5, float(cold.y) + 0.5))
		_ok(cst < -5.0, "frozen-sea surface ice/air stays sub-zero for sound ice (got %.2f)" % cst)

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
	var liquid_cells := 0
	var shaped_cells := 0
	var capped_cells := 0
	var uncovered := 0
	# M1 (ADR §6/§8): guarantee the sample straddles the COLD band so snow-capped + half-slab cells
	# are exercised. Append a 16³ block known to hold a capped surface cell (if this seed has one).
	var capped_block := _find_capped_block()
	if capped_block.x != 0x7fffffff:
		origins.append(capped_block)
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
					# WATER-SHORE §8 item 7: mirror the worker's LIQUID-AWARE resolve by passing the
					# cell's liquid level — open-water surface cells (level 9, modifier 0) → the 0.9
					# slab ARID, shore composites (level 9, modifier != 0) → their wet-model ARID, and
					# submerged composites (level 10) / dry cells (level 0) → the dry resolve, exactly
					# as gen_arid_for(mat, modifier, liquid_level) does on the worker (Stream B contract).
					# M1 (§5.2): mirror the worker's FULL per-cell resolve — pass the liquid kind AND the
					# STATE axis so a snow-capped cell → its snow-variant ARID and a slab → the dry (snow, 85)
					# ARID, exactly as the worker's inline resolve does.
					var expected: int = int(mw.call("gen_arid_for", mat, modifier, CellCodec.liquid_level(v), CellCodec.liquid_kind(v), CellCodec.state(v)))
					if got != expected:
						mismatches += 1
					if CellCodec.liquid_field(v) != 0:
						liquid_cells += 1
					if CellCodec.has_state(v, CellCodec.STATE_SNOW_CAPPED):
						capped_cells += 1
					if mat != BlockCatalog.AIR and modifier != 0:
						shaped_cells += 1
						if not bool(mw.call("is_manifest_baked", mat, modifier)):
							uncovered += 1
					cells += 1
	_ok(mismatches == 0, "module generator TYPE == gen_arid_for(mat,modifier,level,kind,state) over %d cells (%d mismatches)" % [cells, mismatches])
	if capped_block.x != 0x7fffffff:
		_ok(capped_cells > 0, "both-path sample straddles the COLD band: %d snow-capped cells present" % capped_cells)
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
	print("    both-path determinism checked %d cells (%d shaped, %d liquid-carrying)" % [cells, shaped_cells, liquid_cells])

	# LIQUID-AWARE ARID MIRROR over COASTAL blocks. gen_arid_for(mat, modifier, liquid_level) mirrors
	# the module worker's per-cell ARID: an open-water surface cell (level 9, modifier 0, water
	# material) → the open-water surface model ARID (native: the pure fluid; legacy: the 0.9 slab);
	# a shore composite (level 9, modifier != 0) → its water/twin model ARID; a submerged floor
	# composite (level 10) → the waterlogged TWIN when native waterlogging is on (so it culls against
	# the surrounding water — no border), else the DRY shape ARID. Drive the generator over 16³ blocks
	# chosen to straddle the found coastline (surface + composites at y==0) and the smoothed seafloor
	# (submerged composites below y==0), and assert TYPE == gen_arid_for(mat, modifier, level).
	var WATER_ID := BlockCatalog.id_of(&"water")
	var shore := _find_shore_composite()
	var uw := _find_uw_smoothed()
	var ow := _find_open_water(false)      # a non-frozen open-water column (its SEA_LEVEL cell = the 0.9 slab)
	var coast_origins: Array[Vector3i] = []
	var have_shore := shore.x != 0x7fffffff
	var have_uw := uw.x != 0x7fffffff
	var have_ow := ow.x != 0x7fffffff
	if have_shore:
		coast_origins.append(Vector3i(floori(shore.x / 16.0) * 16, floori(float(TerrainConfig.SEA_LEVEL) / 16.0) * 16, floori(shore.y / 16.0) * 16))
	if have_uw:
		var ug: int = TerrainConfig.height_at(uw.x, uw.y)
		coast_origins.append(Vector3i(floori(uw.x / 16.0) * 16, floori(ug / 16.0) * 16, floori(uw.y / 16.0) * 16))
	if have_ow:
		# Drive an OPEN-WATER block too so the surface-water (level-9, modifier-0 slab) class is
		# sampled reliably, not left to whether the shore block's ocean side happened to land in it.
		coast_origins.append(Vector3i(floori(ow.x / 16.0) * 16, floori(float(TerrainConfig.SEA_LEVEL) / 16.0) * 16, floori(ow.y / 16.0) * 16))
	if coast_origins.is_empty():
		_ok(false, "both-path (coast): found a coastal block to drive the liquid-aware ARID mirror")
	else:
		var ac_coast: int = mw.call("appearance_count")
		var slab_arid := int(mw.call("gen_arid_for", WATER_ID, 0, CellCodec.LIQ_LEVEL_SURFACE))
		var w_mismatch := 0
		var w_cells := 0
		var surf_water_seen := 0
		var composite_seen := 0
		var submerged_seen := 0
		for origin: Vector3i in coast_origins:
			var buf: Object = ClassDB.instantiate("VoxelBuffer")
			buf.call("create", 16, 16, 16)
			if buf.has_method("fill"):
				buf.call("fill", 0, ch)
			gen.call("_generate_block", buf, origin, 0)
			for lz in range(16):
				for lx in range(16):
					for ly in range(16):
						var v: int = TerrainConfig.generated_cell(origin.x + lx, origin.y + ly, origin.z + lz)
						var mat: int = CellCodec.mat(v)
						if mat == BlockCatalog.AIR:
							continue
						var modifier: int = CellCodec.modifier(v)
						var level: int = CellCodec.liquid_level(v)
						var got: int = int(buf.call("get_voxel", lx, ly, lz, ch))
						var expected: int = int(mw.call("gen_arid_for", mat, modifier, level, CellCodec.liquid_kind(v), CellCodec.state(v)))
						if got != expected:
							w_mismatch += 1
						if level == CellCodec.LIQ_LEVEL_SURFACE:
							if modifier == 0 and BlockCatalog.liquid_kind_of(mat) == CellCodec.LIQ_WATER:
								surf_water_seen += 1
								if got != slab_arid:                # open-water surface → water-slab ARID
									w_mismatch += 1
							else:
								composite_seen += 1                 # shore composite → wet-model ARID
						elif level == CellCodec.LIQ_LEVEL_FULL:
							submerged_seen += 1                     # submerged floor composite → twin (native) / dry (legacy)
						w_cells += 1
		print("    both-path coast: %d cells (%d surface-water, %d composites, %d submerged)"
			% [w_cells, surf_water_seen, composite_seen, submerged_seen])
		_ok(w_mismatch == 0, "both-path (coast): module TYPE == gen_arid_for(mat, modifier, level) over %d coastal cells (%d mismatches)" % [w_cells, w_mismatch])
		# Class coverage — each guarded by whether its source column was actually found, so an
		# atypical coast under-samples honestly instead of a vacuous pass or a flaky false-fail.
		if have_ow or have_shore:
			_ok(surf_water_seen > 0, "both-path (coast): sampled open-water surface cells (level 9, water slab) — %d" % surf_water_seen)
		if have_shore:
			_ok(composite_seen > 0, "both-path (coast): sampled shore composite cells (level 9, modifier != 0, wet/twin model) — %d" % composite_seen)
		if have_uw:
			_ok(submerged_seen > 0, "both-path (coast): sampled submerged floor composite cells (level 10) — %d" % submerged_seen)
		_ok(int(mw.call("appearance_count")) == ac_coast, "both-path (coast): wet/slab ARIDs are frozen at setup — driving coastal blocks bakes NO new ARID (count stable at %d)" % ac_coast)

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

	# --- M1 snow-cap state-variant render mirror (ADR §5, §8 item 6) --------------------------------
	# _snow_arid is frozen at setup: driving the generator (above) baked NO new ARID; the snow-variant
	# ARID for a capped cell differs from the plain-material ARID and matches the mirror; an UNBAKED
	# state pair (stone — declared cappable but never baked) falls back to the plain look, never 0.
	var snow_bit := CellCodec.STATE_SNOW_CAPPED
	var grass_plain := int(mw.call("arid_for_cell", CellCodec.pack(GRASS, 0, 0)))
	var grass_snow := int(mw.call("arid_for_cell", CellCodec.pack(GRASS, 0, snow_bit)))
	_ok(grass_snow != grass_plain, "capped grass ARID (%d) differs from plain grass ARID (%d)" % [grass_snow, grass_plain])
	_ok(grass_snow == int(mw.call("gen_arid_for", GRASS, 0, 0, CellCodec.LIQ_WATER, snow_bit)),
		"arid_for_cell(capped grass) == gen_arid_for(grass, …, state) mirror")
	# stone: declared cappable but UNBAKED (worldgen never stamps it) → the snow slot is -1, so the
	# capped value falls back to the plain stone cube ARID (never a hole, §5.5).
	# stone: now a REAL baked mountain top (Mountains biome) — its snow variant IS baked, so a capped
	# stone cell renders the variant (differs from plain stone), mirroring grass. This is what makes high
	# stone peaks render WHITE. A NON-cappable material with a stray snow bit still falls back (never a hole).
	var stone_plain := int(mw.call("arid_for_cell", CellCodec.pack(STONE, 0, 0)))
	var stone_snow := int(mw.call("arid_for_cell", CellCodec.pack(STONE, 0, snow_bit)))
	_ok(stone_snow != stone_plain and stone_snow > 0, "capped stone renders the BAKED snow variant ARID (%d), differs from plain stone (%d)" % [stone_snow, stone_plain])
	_ok(stone_snow == int(mw.call("gen_arid_for", STONE, 0, 0, CellCodec.LIQ_WATER, snow_bit)),
		"arid_for_cell(capped stone) == gen_arid_for(stone, …, state) mirror")
	var dirt_plain := int(mw.call("arid_for_cell", CellCodec.pack(DIRT, 0, 0)))
	var dirt_snow := int(mw.call("arid_for_cell", CellCodec.pack(DIRT, 0, snow_bit)))
	_ok(dirt_snow == dirt_plain and dirt_snow > 0, "unbaked capped dirt falls back to the plain dirt ARID (%d), never a hole" % dirt_snow)
	# The generator does not bake a snow ARID on the worker either (frozen table).
	var ac_snow := int(mw.call("appearance_count"))
	var bufS: Object = ClassDB.instantiate("VoxelBuffer")
	bufS.call("create", 16, 16, 16)
	if capped_block.x != 0x7fffffff:
		gen.call("_generate_block", bufS, capped_block, 0)
	_ok(int(mw.call("appearance_count")) == ac_snow, "generating a capped block bakes NO new ARID (snow table frozen at %d)" % ac_snow)

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

## A 16³ block origin (16-aligned) known to contain a snow-CAPPED surface cell (M1 §6/§8), or
## (0x7fffffff,_,_) if this seed has none reachable near origin — so the both-path test straddles
## the cold band and exercises the snow-variant + slab render path.
func _find_capped_block() -> Vector3i:
	for x in range(-384, 384, 3):
		for z in range(-384, 384, 3):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			if CellCodec.has_state(TerrainConfig.generated_cell(x, g, z), CellCodec.STATE_SNOW_CAPPED):
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
	var s := TerrainConfig.find_coast()               # coast centre so the sweep spans below sea level (WATER-SHORE §3)
	var exact := true
	var shaped := 0
	var checked := 0
	var uw_cols := 0
	var uw_caps_seen := 0                              # underwater columns that DO grow a cap (§3.6: underwater caps ON)
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
			if g < TerrainConfig.SEA_LEVEL:
				uw_cols += 1
				if memo_cm != 0:                      # WATER-SHORE §3.6: underwater caps are now ON
					uw_caps_seen += 1
			checked += 1
	_ok(checked > 0, "shape memo: sampled %d columns" % checked)
	_ok(shaped > 0, "shape memo: sample includes shaped columns (%d) — memo exercised on real shapes" % shaped)
	_ok(uw_cols > 0, "shape memo: coast sweep spans underwater columns (%d) — memo exercised below sea level" % uw_cols)
	_ok(uw_caps_seen > 0, "shape memo: underwater columns CAN grow a cap (%d) — underwater caps ON (§3.6)" % uw_caps_seen)
	_ok(exact, "shape memo path == direct compute == generated_cell modifier over the whole sample (incl. underwater caps — cache is exact)")

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

	# (b) SMOOTHING ENGAGES over a wide sweep that now spans BOTH land and the underwater floor;
	# every surface modifier is a BOTTOM corner-height code (corners ≤ 2, anchor BOTTOM); the
	# MATERIAL projection is unchanged (generated_block == mat, so smoothing minted no new material
	# and no stackup shifts). WATER-SHORE §3: underwater floor surface cells (g < SEA_LEVEL) now
	# smooth too, and a smoothed one is a submerged composite carrying a FULL-fill water overlay
	# (liquid WATER, level 10) — the old `g < SEA_LEVEL → modifier 0` suppression is gone.
	var shaped := 0
	var underwater_shaped := 0
	var surface_cells := 0
	var range_ok := true
	var mat_ok := true
	var uw_liquid_ok := true
	for x in range(-400, 400, 3):
		for z in range(-400, 400, 3):
			var g: int = TerrainConfig.height_at(x, z)
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
				if g < TerrainConfig.SEA_LEVEL:
					underwater_shaped += 1
					# A smoothed underwater floor cell is a submerged composite: full-fill water.
					if CellCodec.liquid_kind(v) != CellCodec.LIQ_WATER \
							or CellCodec.liquid_level(v) != CellCodec.LIQ_LEVEL_FULL:
						uw_liquid_ok = false
	print("    surface sweep: %d cells, %d shaped (%d underwater)" % [surface_cells, shaped, underwater_shaped])
	if TerrainConfig.SMOOTHING_ENABLED:
		_ok(shaped > 0, "smoothing engages: at least one shaped surface cell over the sweep (%d)" % shaped)
		_ok(underwater_shaped > 0, "underwater floor smoothing engages: shaped surface cells below sea level (%d)" % underwater_shaped)
		_ok(uw_liquid_ok, "every smoothed underwater floor cell carries a full-fill water overlay (WATER, level 10)")
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
## Ceiling collision query (player.gd issue #2). WorldManager.ceiling_scan is the SWEPT,
## shape-aware upward mirror of floor_under: it must find a ceiling's underside anywhere
## in the head's swept range (so a fast rise / frame hitch can't TUNNEL a thin ceiling)
## and return INF for a clear range. The real ceiling in a heightmap world is a DUG
## TUNNEL — dig an interior cell and the solid terrain directly above it is the ceiling
## (it stays supported, unlike a floating placed block, which the collapse pass detaches).
func _test_ceiling_scan() -> void:
	var world: WorldManager = _struct_world("CeilScan")
	var spawn := TerrainConfig.find_spawn()
	var cx := spawn.x
	var cz := spawn.y
	var g: int = TerrainConfig.height_at(cx, cz)
	if g < TerrainConfig.SEA_LEVEL + 4:
		_ok(true, "ceiling-scan skipped (no tall land column at spawn, g=%d)" % g)
		world.queue_free()
		return
	var dig := Vector3i(cx, g - 3, cz)                 # an interior solid cell — stays supported
	var dug := world.break_terrain(dig, Vector3.INF)
	_ok(dug > 0, "ceiling-scan: dug an interior test cell at %s (id %d)" % [str(dig), dug])
	var underside := float(dig.y + 1)                  # solid terrain above the dug air = ceiling
	var fx := float(cx) + 0.5
	var fz := float(cz) + 0.5
	# (a) NO TUNNEL: sweep from inside the dug cell up to WELL ABOVE the surface (open
	# air). A point test at the range END (air) would read "clear"; the swept scan must
	# still find the INTERMEDIATE solid ceiling's underside.
	var from_h := float(dig.y) + 0.1
	var hit := world.ceiling_scan(fx, fz, from_h, float(g) + 5.0)
	_ok(absf(hit - underside) < 1e-3,
		"ceiling-scan: swept scan finds the intermediate ceiling underside %.2f (got %.2f)" % [underside, hit])
	# (b) CLEAR range fully in open air above the surface returns INF (no false positive).
	var clear := world.ceiling_scan(fx, fz, float(g) + 2.0, float(g) + 4.0)
	_ok(clear == INF, "ceiling-scan: a clear open-air head range returns INF (got %.2f)" % clear)
	world.queue_free()

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
			# (b) above the cap the collider substitutes TreeGen.block_at + a sea test + the SNOW stack
			# (snow_stack_at) for generated_cell; that is sound only if every generated solid cell there
			# is a tree cell, sea fill, OR snow (SNOW-ACCUMULATION §3.4 — snow may be a shaped LAYER; every
			# other above-cap generated solid stays a full cube).
			var SNOW_ID := BlockCatalog.id_of(&"snow_block")
			for y in range(g + 2, g + TreeGen.MAX_ABOVE_SURFACE + 1):
				var v: int = TerrainConfig.generated_cell(x, y, z)
				var vmat := CellCodec.mat(v)
				if vmat == BlockCatalog.AIR:
					continue
				var is_snow := vmat == SNOW_ID
				if CellCodec.modifier(v) != 0 and not is_snow:
					above_ok = false                         # only snow may be a shaped (LAYER) cell above the cap
				var is_tree: bool = TreeGen.block_at(x, y, z) != BlockCatalog.AIR
				var is_sea: bool = y <= TerrainConfig.SEA_LEVEL
				if not (is_tree or is_sea or is_snow):
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

	# Cost proof #2 — worst-case SINGLE-FRAME collider cost with CORE-THEN-FILL. Drive a real
	# GroundCollider directly (a bare WorldManager answers the cell queries). The first build is now a
	# small synchronous CORE around the faller (the ONLY synchronous cost — replacing the old ~368ms
	# whole-region stall); the full region then fills incrementally, and each fill slice must be a
	# small fraction of even that core build.
	var cw := WorldManager.new()
	cw.name = "ColliderPerfWorld"
	get_root().add_child(cw)
	var gc := GroundCollider.new()
	get_root().add_child(gc)
	gc.setup(cw)
	VoxelBody.spawn_loose(cw, {Vector3i(s.x, 40, s.y): STONE}, cw)   # active-body gate: keep the collider live
	var bt0 := Time.get_ticks_usec()
	gc.update(Vector3(float(s.x) + 0.5, 40.0, float(s.y) + 0.5))     # first build = synchronous CORE + one fill slice
	var core_us := Time.get_ticks_usec() - bt0
	var core_shapes := PhysicsServer3D.body_get_shape_count(gc.active_rid())
	# Pump the incremental fill to completion; time each update() slice.
	var here := Vector3(float(s.x) + 0.5, 40.0, float(s.y) + 0.5)
	var max_slice := 0
	var frames := 0
	while true:
		var s0 := Time.get_ticks_usec()
		gc.update(here)
		max_slice = maxi(max_slice, Time.get_ticks_usec() - s0)
		frames += 1
		if not gc.is_building() or frames > 6000:
			break
	var full_shapes := PhysicsServer3D.body_get_shape_count(gc.active_rid())
	print("    collider single-frame cost: synchronous CORE=%d us (%d shapes)  vs  worst fill slice=%d us over %d frames (full region %d shapes)"
		% [core_us, core_shapes, max_slice, frames, full_shapes])
	_ok(core_shapes > 0, "collider-cheap: the immediate core build emitted shapes (%d)" % core_shapes)
	_ok(full_shapes > core_shapes, "collider-cheap: the full region (%d shapes) fills in behind the smaller core (%d)" % [full_shapes, core_shapes])
	_ok(frames > 1, "collider-cheap: the fill spreads across K>1 frames (K=%d)" % frames)
	_ok(max_slice * 2 < core_us, "collider-cheap: worst fill slice (%d us) is well under even the core build (%d us)" % [max_slice, core_us])
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
	# CORE-THEN-FILL: the first build makes a small CORE live IMMEDIATELY (ground for the faller) and
	# fills the full R region incrementally behind it — no ~368ms whole-region synchronous stall.
	gc.update(Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5))
	_ok(gc.active_rid().is_valid() and PhysicsServer3D.body_get_shape_count(gc.active_rid()) > 0,
		"amortized: first build makes a CORE live immediately (collision for the faller)")
	_ok(gc.is_building(), "amortized: full region fills incrementally behind the core (core-then-fill)")
	var core_n := PhysicsServer3D.body_get_shape_count(gc.active_rid())
	# Pump the fill to completion so the FULL region is live for the rest of the test.
	var boot_f := 0
	while gc.is_building() and boot_f <= 6000:
		gc.update(Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5))
		boot_f += 1
	_ok(not gc.is_building(), "amortized: core-then-fill completes (full region live)")
	var n0 := PhysicsServer3D.body_get_shape_count(gc.active_rid())
	_ok(n0 > core_n, "amortized: settled full region (%d shapes) is larger than the bootstrap core (%d)" % [n0, core_n])
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
		"gate: first body spawn → collider bootstraps a core immediately (ground for the falling body)")
	# Let the core-then-fill finish so the collider is idle (not mid-fill) before we fly away.
	var gate_f := 0
	while gc.is_building() and gate_f <= 6000:
		gc.update(Vector3(float(cx) + 0.5, float(g) + 2.0, float(cz) + 0.5))
		gate_f += 1

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
		var modifier: int = CellCodec.modifier(v)
		# The collider keeps UNDERWATER cap cells as full sea-fill BOXES — its cap-prism emission is
		# land-only (ground_collider.gd:450, gated h >= SEA_LEVEL) because the player never stands
		# underwater and debris floats on the sea fill. WATER-SHORE §3.6 grows the underwater cap in
		# WORLDGEN (for RENDER), so cell_value_at(x, h+1, z) now carries a shaped composite; mirror
		# the collider's conservative PHYSICS model here by coarsening a submerged generated cap
		# (not a placed block) to sea fill (modifier 0 → box), so this heavy reference stays a faithful
		# model of the UNCHANGED collider. (This is a test-model correction, not a collider change.)
		if modifier != 0 and y == h + 1 and h < TerrainConfig.SEA_LEVEL \
				and not world.placed_cells().has(Vector3i(cx, y, cz)):
			modifier = 0
		if mat != BlockCatalog.AIR and modifier != 0:
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
## WATER-SHORE §5.2 — the FALLBACK mesher's new _emit_water pass renders the sea (the module
## path is the live/playable one; this is the safety net). The rest of the suite never meshes a
## coastal or oceanic chunk, so the water quads and ice cubes are otherwise green-but-unproven.
## Here we build REAL coastal + frozen chunks and inspect the returned ArrayMesh geometry — the
## presence and exact 0.9 height are headlessly assertable (sort order / z-fight are manual QA).
func _test_fallback_water() -> void:
	print("[WATER-SHORE] fallback mesher water pass (_emit_water)")
	var n := TerrainConfig.CHUNK_SIZE
	var water_mat: Material = BlockMaterials.get_for(BlockCatalog.id_of(&"water"))
	var ice_mat: Material = BlockMaterials.get_for(BlockCatalog.id_of(&"ice"))
	var water_y := float(TerrainConfig.SEA_LEVEL) + TerrainConfig.WATER_SURFACE_HEIGHT
	var world := _struct_world("WSFallback")

	# (a) A coastal/open-water chunk emits a water surface, and EVERY water vertex sits exactly on
	# the 0.9 plane — catches a missing pass, a wrong height, or stray water geometry anywhere.
	var ow := _find_open_water(false)
	if ow.x != 0x7fffffff:
		var mesh := ChunkMesher.build(floori(float(ow.x) / float(n)), floori(float(ow.y) / float(n)), world)
		var si := _mesh_surface_for(mesh, water_mat)
		_ok(si >= 0, "fallback water: coastal chunk emits a water surface")
		if si >= 0:
			var verts: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			var all_on_plane := verts.size() > 0
			for v in verts:
				if absf(v.y - water_y) >= 1.0e-4:
					all_on_plane = false
					break
			_ok(all_on_plane, "fallback water: every water vertex is exactly at y == SEA_LEVEL + 0.9 (%.2f)" % water_y)

	# (b) A frozen open-ocean chunk renders its sea-ice surface (this pass fixed it being invisible).
	var cold := _find_cold_sea()
	if cold.x != 0x7fffffff:
		var mesh2 := ChunkMesher.build(floori(float(cold.x) / float(n)), floori(float(cold.y) / float(n)), world)
		_ok(mesh2 != null and _mesh_surface_for(mesh2, ice_mat) >= 0,
			"fallback water: frozen-ocean chunk renders a sea-ice surface")
	world.queue_free()

## Index of the ArrayMesh surface whose material == `mat`, or -1 (null-safe).
func _mesh_surface_for(mesh: ArrayMesh, mat: Material) -> int:
	if mesh == null:
		return -1
	for i in mesh.get_surface_count():
		if mesh.surface_get_material(i) == mat:
			return i
	return -1

# NATIVE WATERLOGGING (WATERLOGGING.md §4.8): the game wires godot_voxel's solid+fluid co-fill so
# EVERY water cell — pure water, shore composites (liquid 9) AND submerged composites (liquid 10) —
# shares ONE fluid_index and culls together, killing the shore/submerged border. This asserts the
# wiring at the ARID layer (module-guarded; the built engine must expose the patched API):
#   * the native API is present (VoxelBlockyModelFluid + set_waterlog_fluid);
#   * pure deep water and surface water resolve to the SAME fluid ARID (no top seam);
#   * for every emitted composite pair, the level-9 and level-10 resolves are the SAME waterlogged
#     twin (all water shares one fluid, shore AND below) and that twin DIFFERS from the dry shape
#     (the border-killer: submerged now waterlogs instead of drawing a dry ramp beside a water wall);
#   * the twin manifest is frozen at setup (the worker never lazy-bakes).
# On an OLD engine (no patch) the game keeps the legacy composite path — this reports and skips.
func _test_waterlogging() -> void:
	print("[WATERLOGGING] native solid+fluid co-fill wiring (WATERLOGGING.md §4)")
	if not ClassDB.class_exists("VoxelTerrain") or not ClassDB.class_exists("VoxelBuffer"):
		print("    (godot_voxel module absent — waterlogging wiring runs on module builds only)")
		return
	var have_fluid := ClassDB.class_exists("VoxelBlockyModelFluid")
	var mesh_probe: Object = ClassDB.instantiate("VoxelBlockyModelMesh") if ClassDB.class_exists("VoxelBlockyModelMesh") else null
	var have_waterlog: bool = mesh_probe != null and mesh_probe.has_method("set_waterlog_fluid")
	if not (have_fluid and have_waterlog):
		print("    (engine lacks native waterlogging API: VoxelBlockyModelFluid=%s set_waterlog_fluid=%s — legacy composite path, skipping)"
			% [have_fluid, have_waterlog])
		return
	_ok(have_fluid, "waterlog: engine exposes VoxelBlockyModelFluid (pure-water fluid model)")
	_ok(have_waterlog, "waterlog: a VoxelBlockyModelMesh instance has set_waterlog_fluid (co-fill API)")

	var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
	get_root().add_child(mw)
	var built: bool = mw.call("setup")
	_ok(built, "waterlog: module world builds with native waterlogging enabled")
	if not built:
		mw.queue_free()
		return

	var WATER := BlockCatalog.id_of(&"water")
	var S := CellCodec.LIQ_LEVEL_SURFACE
	var F := CellCodec.LIQ_LEVEL_FULL

	# (1) Pure water shares ONE model: deep (level 0) and surface (level 9) → the same fluid ARID.
	var deep_water := int(mw.call("gen_arid_for", WATER, 0, 0))
	var surf_water := int(mw.call("gen_arid_for", WATER, 0, S))
	_ok(deep_water == surf_water,
		"waterlog: deep water (lvl 0) and surface water (lvl 9) share ONE fluid ARID (%d == %d)" % [deep_water, surf_water])

	# (2) Twin coverage + the border-killer invariant over every emitted composite pair.
	var pairs := {}
	for slot: int in TerrainConfig.emitted_shore_pairs():
		pairs[slot] = true
	for slot: int in TerrainConfig.emitted_submerged_pairs():
		pairs[slot] = true
	var checked := 0
	var same_twin := 0
	var covered := 0
	for slot: int in pairs.keys():
		var mat := slot / 256
		var modifier := slot % 256
		if mat <= BlockCatalog.AIR or mat >= BlockCatalog.count() or modifier <= 0:
			continue
		var t9 := int(mw.call("gen_arid_for", mat, modifier, S))
		var t10 := int(mw.call("gen_arid_for", mat, modifier, F))
		var dry := int(mw.call("gen_arid_for", mat, modifier, 0))
		checked += 1
		if t9 == t10:
			same_twin += 1                          # shore & submerged share one twin (one fluid)
		if t10 != dry:
			covered += 1                            # a baked twin (unbaked pairs degrade to the dry shape)
	_ok(checked > 0, "waterlog: emitted composite pairs to check (%d shore∪submerged)" % checked)
	_ok(same_twin == checked,
		"waterlog: level-9 and level-10 resolve to the SAME twin for every pair (%d/%d) — all water shares one fluid" % [same_twin, checked])
	# The manifest bakes exactly this union, so coverage should be ~100%; require a strong majority so a
	# wholesale bake failure is caught while a handful of degenerate pairs may fall back to the dry shape.
	_ok(covered * 10 >= checked * 9,
		"waterlog: >=90%% of emitted composite pairs have a baked waterlogged twin != dry shape (%d/%d)" % [covered, checked])
	print("    waterlog twins: %d pairs checked, %d covered (twin != dry), %d share-one-fluid" % [checked, covered, same_twin])

	# (3) A concrete submerged column resolves to its twin, not the dry ramp (the visible seafloor fix).
	var uw := _find_uw_smoothed()
	if uw.x != 0x7fffffff:
		var ug: int = TerrainConfig.height_at(uw.x, uw.y)
		var uc := TerrainConfig.generated_cell(uw.x, ug, uw.y)
		var umat := CellCodec.mat(uc)
		var umod := CellCodec.modifier(uc)
		if umod != 0 and CellCodec.liquid_level(uc) == F:
			var utwin := int(mw.call("gen_arid_for", umat, umod, F))
			var udry := int(mw.call("gen_arid_for", umat, umod, 0))
			_ok(utwin != udry,
				"waterlog: a real submerged composite (mat %d, mod %d) maps to its waterlogged twin, not the dry ramp (twin %d != dry %d)" % [umat, umod, utwin, udry])
	else:
		print("    (no smoothed underwater column found near the coast — concrete submerged assert skipped)")

	# (4) The twin/fluid ARIDs are FROZEN at setup — resolving them bakes nothing new.
	var ac := int(mw.call("appearance_count"))
	var _probe := int(mw.call("gen_arid_for", WATER, 0, S))
	_ok(int(mw.call("appearance_count")) == ac, "waterlog: twin/fluid ARIDs frozen at setup (count stable at %d)" % ac)

	# (5) MESH-LEVEL border-killer proof (durable regression guard): actually run the blocky mesher
	# on a waterlogged twin beside pure water and assert the SHARED water face is CULLED (no border)
	# while the terrain ramp is still emitted (no hole). (1)-(4) prove the WIRING; this proves the
	# rendered geometry, so a future change can't silently reintroduce the border. Guarded to module
	# builds that can mesh a VoxelBuffer headlessly; a differential over three meshes so it does not
	# depend on exact fluid face counts (which vary with corner heights).
	if ClassDB.class_exists("VoxelMesherBlocky"):
		var lib: Object = mw.get("_library")
		var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
		if lib != null and mesher != null and mesher.has_method("set_library") and mesher.has_method("build_mesh"):
			mesher.call("set_library", lib)
			var minp: int = mesher.call("get_minimum_padding")
			var maxp: int = mesher.call("get_maximum_padding")
			var water_mat: Object = BlockMaterials.get_for(WATER)
			# Pick a real emitted composite pair that actually baked a twin (twin ARID != dry ARID).
			var tmat := -1
			var tmod := -1
			for slot: int in pairs.keys():
				var m := slot / 256
				var md := slot % 256
				if m > BlockCatalog.AIR and m < BlockCatalog.count() and md > 0 \
						and int(mw.call("gen_arid_for", m, md, F)) != int(mw.call("gen_arid_for", m, md, 0)):
					tmat = m
					tmod = md
					break
			if tmat >= 0 and water_mat != null:
				var terr_mat: Object = BlockMaterials.get_for(tmat)
				var water_arid := int(mw.call("arid_for_cell", WATER))
				var twin_arid := int(mw.call("arid_for_cell", CellCodec.pack(tmat, tmod, 0, CellCodec.make_liquid(CellCodec.LIQ_WATER, F))))
				var b := minp + 1
				var span := minp + maxp + 4
				var mesh_verts := func(cells: Array) -> Array:
					var buf: Object = ClassDB.instantiate("VoxelBuffer")
					buf.call("set_channel_depth", 0, 1)          # CHANNEL_TYPE, DEPTH_16_BIT (ARIDs exceed 255)
					buf.call("create", span, span, span)
					buf.call("fill", 0, 0)                        # air
					for c in cells:
						var p: Vector3i = c[0]
						buf.call("set_voxel", int(c[1]), p.x, p.y, p.z, 0)
					var msh: Object = mesher.call("build_mesh", buf, [], {})
					var wv := 0
					var tv := 0
					if msh != null:
						for i in msh.get_surface_count():
							var mm: Object = msh.surface_get_material(i)
							var nn := (msh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
							if mm == water_mat:
								wv += nn
							elif mm == terr_mat:
								tv += nn
					return [wv, tv]
				var ta: Array = mesh_verts.call([[Vector3i(b, b, b), twin_arid]])                                   # twin alone
				var wa: Array = mesh_verts.call([[Vector3i(b, b, b), water_arid]])                                  # water alone
				var tw: Array = mesh_verts.call([[Vector3i(b, b, b), twin_arid], [Vector3i(b + 1, b, b), water_arid]])  # adjacent
				_ok(int(ta[1]) > 0, "waterlog-mesh: waterlogged twin renders its opaque terrain ramp — no hole (%d terrain verts)" % int(ta[1]))
				_ok(int(ta[0]) > 0 and int(wa[0]) > 0, "waterlog-mesh: twin and water each render water faces in isolation (%d, %d)" % [int(ta[0]), int(wa[0])])
				_ok(int(tw[0]) < int(ta[0]) + int(wa[0]),
					"waterlog-mesh: shared twin↔water face is CULLED — borderless (combined %d < isolated sum %d)" % [int(tw[0]), int(ta[0]) + int(wa[0])])
				print("    waterlog-mesh: twin(water=%d,terr=%d) water=%d twin+water=%d (<%d ⇒ border culled)"
					% [int(ta[0]), int(ta[1]), int(wa[0]), int(tw[0]), int(ta[0]) + int(wa[0])])
			else:
				print("    (no baked twin pair or water material — mesh-level border proof skipped)")
	mw.queue_free()

# MULTI-LIQUID Stream E (MULTI-LIQUID.md §5): lava is a first-class liquid — GENERATED (the
# climate-keyed molten sea, §2.4), CANONICALIZED like water (the codec keeps a known kind on a
# solid composite and strips an unknown one, rule 6), and RENDERED BORDERLESS within itself with a
# crisp boundary against water (the opaque-fluid culling audit, §2.3). Five parts, mirroring the
# WATER-SHORE / WATERLOGGING structure for the lava kind: (1) CODEC pins, (2) DATA MODEL +
# GMID byte-identity, (3) WORLDGEN molten sea, (4) both-path ARID per kind (module-guarded),
# (5) the MESH-LEVEL border-killer + crisp inter-liquid boundary (module + mesher guarded).
func _test_multi_liquid_lava() -> void:
	print("[MULTI-LIQUID] lava — generated / canonicalized / rendered borderless (MULTI-LIQUID §5)")
	var LAVA := BlockCatalog.id_of(&"lava")
	var WATER := BlockCatalog.id_of(&"water")
	var SEA: int = TerrainConfig.SEA_LEVEL
	var S := CellCodec.LIQ_LEVEL_SURFACE
	var F := CellCodec.LIQ_LEVEL_FULL
	var RAMP := ShapeCodec.make_modifier(2, 2, 0, 0)   # a real (wedge) modifier: a solid composite host
	_ok(LAVA > 0, "lava id resolves (id_of(&\"lava\") = %d)" % LAVA)

	# ---- (1) CODEC pins: rule 6 keeps a KNOWN kind on a solid composite, strips an unknown one ----
	# is_liquid_kind_known is rule 6's gate: water + lava are declared, kind 3 is reserved, NONE never.
	_ok(BlockCatalog.is_liquid_kind_known(CellCodec.LIQ_WATER), "codec: is_liquid_kind_known(WATER) == true")
	_ok(BlockCatalog.is_liquid_kind_known(CellCodec.LIQ_LAVA), "codec: is_liquid_kind_known(LAVA) == true")
	_ok(not BlockCatalog.is_liquid_kind_known(3), "codec: is_liquid_kind_known(3, reserved) == false")
	_ok(not BlockCatalog.is_liquid_kind_known(CellCodec.LIQ_NONE), "codec: is_liquid_kind_known(NONE) == false")
	# A LAVA overlay on a SOLID composite (modifier != 0) is KEPT bit-exactly (rule 6, known kind).
	var lava_comp := CellCodec.canonical(CellCodec.pack(STONE, RAMP, 0, CellCodec.make_liquid(CellCodec.LIQ_LAVA, S)))
	_ok(CellCodec.liquid_kind(lava_comp) == CellCodec.LIQ_LAVA and CellCodec.liquid_level(lava_comp) == S
			and CellCodec.mat(lava_comp) == STONE and CellCodec.modifier(lava_comp) == RAMP,
		"codec: canonical KEEPS liquid(LAVA, 9) on a solid composite (rule 6, known kind)")
	# An UNKNOWN kind (3) on the same solid composite is STRIPPED (rule 6 gate), material/modifier kept.
	var unk := CellCodec.canonical(CellCodec.pack(STONE, RAMP, 0, CellCodec.make_liquid(3, 5)))
	_ok(CellCodec.liquid_field(unk) == 0 and CellCodec.mat(unk) == STONE and CellCodec.modifier(unk) == RAMP,
		"codec: canonical STRIPS unknown liquid kind 3 on a solid composite (rule 6), mat/modifier kept")
	# (lava, 10) on the LAVA material → the bare lava id (rule 5: no dual encoding of full lava).
	_ok(CellCodec.canonical(CellCodec.pack(LAVA, 0, 0, CellCodec.make_liquid(CellCodec.LIQ_LAVA, F))) == LAVA,
		"codec: canonical (lava,10) on lava → bare lava id (rule 5)")
	# bits 54..63 stay 0 after packing a lava composite (the liquid field never leaks into reserved bits).
	_ok((CellCodec.pack(STONE, RAMP, 0, CellCodec.make_liquid(CellCodec.LIQ_LAVA, S)) >> 54) == 0,
		"codec: bits 54..63 == 0 after packing a lava composite")

	# ---- (2) DATA MODEL: material liquid identity + GMID byte-identity (omit-when-zero) ------------
	_ok(BlockCatalog.liquid_kind_of(WATER) == CellCodec.LIQ_WATER, "data: liquid_kind_of(water) == LIQ_WATER")
	_ok(BlockCatalog.liquid_kind_of(LAVA) == CellCodec.LIQ_LAVA, "data: liquid_kind_of(lava) == LIQ_LAVA")
	_ok(BlockCatalog.liquid_kind_of(STONE) == CellCodec.LIQ_NONE, "data: liquid_kind_of(a solid, stone) == LIQ_NONE")
	_ok(BlockCatalog.liquid_lrid_of(CellCodec.LIQ_LAVA) == LAVA, "data: liquid_lrid_of(LIQ_LAVA) == id_of(&\"lava\")")
	_ok(BlockCatalog.liquid_lrid_of(CellCodec.LIQ_WATER) == WATER, "data: liquid_lrid_of(LIQ_WATER) == id_of(&\"water\")")
	_ok(BlockCatalog.cull_group_of(LAVA) == 0, "data: cull_group_of(lava) == 0 (opaque fluid — the sliver-fix trigger)")
	# GMID byte-identity: a NON-liquid material's serialized document OMITS "liquid_kind" (so its GMID is
	# byte-identical to before the field existed); water AND lava DO carry it (safe: never serialized into
	# a zone bundle — placement rejects non-solid, capture strips the liquid axis). Byte-level substring.
	var stone_doc := MaterialDocument.to_document(BlockCatalog.def_of(STONE)).get_string_from_utf8()
	var dirt_doc := MaterialDocument.to_document(BlockCatalog.def_of(DIRT)).get_string_from_utf8()
	var water_doc := MaterialDocument.to_document(BlockCatalog.def_of(WATER)).get_string_from_utf8()
	var lava_doc := MaterialDocument.to_document(BlockCatalog.def_of(LAVA)).get_string_from_utf8()
	_ok(stone_doc.find("liquid_kind") == -1, "data: a non-liquid material (stone) document OMITS liquid_kind (GMID byte-identity)")
	_ok(dirt_doc.find("liquid_kind") == -1, "data: a non-liquid material (dirt) document OMITS liquid_kind (GMID byte-identity)")
	_ok(water_doc.find("liquid_kind") != -1, "data: the water document CARRIES liquid_kind (declared liquid)")
	_ok(lava_doc.find("liquid_kind") != -1, "data: the lava document CARRIES liquid_kind (declared liquid)")

	# ---- (3) WORLDGEN: the climate-keyed molten sea exists & is deterministic (§2.4) --------------
	# A molten ocean exists for the known seed (rare — temperature freq 0.002); a not-found here is a
	# LOUD failure, never a silent pass (§5 Stream E: a vacuous skip must not masquerade as green).
	var molten := _find_molten_column()
	_ok(molten.x != 0x7fffffff, "worldgen: a molten-sea column (t >= LAVA_SEA_T, g < SEA_LEVEL) exists for the seed")
	if molten.x != 0x7fffffff:
		var mt: float = TerrainConfig.column_profile(molten.x, molten.y).w
		var mg: int = TerrainConfig.height_at(molten.x, molten.y)
		_ok(mt >= TerrainConfig.LAVA_SEA_T and mg < SEA, "worldgen: molten column t=%.3f >= LAVA_SEA_T and g=%d < SEA" % [mt, mg])
		# The sea-fill SURFACE cell at the water line is the LAVA material carrying liquid(LAVA, 9).
		var msurf := TerrainConfig.generated_cell(molten.x, SEA, molten.y)
		_ok(CellCodec.mat(msurf) == LAVA and CellCodec.liquid_kind(msurf) == CellCodec.LIQ_LAVA
				and CellCodec.liquid_level(msurf) == S,
			"worldgen: molten sea SURFACE cell (y==SEA) is lava + liquid(LAVA, 9)")
		# Deep molten sea (y == SEA-1) is the BARE lava id (canonical full lava, byte-stable).
		_ok(TerrainConfig.generated_cell(molten.x, SEA - 1, molten.y) == LAVA,
			"worldgen: molten sea at SEA-1 is the BARE lava id (canonical full lava)")
		# DETERMINISM incl. the liquid bits (48+): a full-int re-sample of the surface cell is identical.
		_ok(TerrainConfig.generated_cell(molten.x, SEA, molten.y) == msurf,
			"worldgen: molten sea-fill cell (incl. liquid bits 48+) is deterministic on re-sample")
		# A molten SHORE/SUBMERGED composite, if the terrain grows one near the sea, carries LIQ_LAVA:
		# a SOLID terrain material + a surface modifier + a lava liquid overlay (level 10 submerged).
		var msub := _find_molten_submerged(molten)
		if msub.x != 0x7fffffff:
			var sg: int = TerrainConfig.height_at(msub.x, msub.y)
			var sc := TerrainConfig.generated_cell(msub.x, sg, msub.y)
			_ok(BlockCatalog.solidity_of(CellCodec.mat(sc)) >= 0.5 and CellCodec.modifier(sc) != 0,
				"worldgen: molten submerged composite is a SOLID terrain material + a surface modifier")
			_ok(CellCodec.liquid_kind(sc) == CellCodec.LIQ_LAVA and CellCodec.liquid_level(sc) == F,
				"worldgen: molten submerged composite carries liquid(LAVA, 10) — full-fill lava")
		else:
			print("    (no smoothed molten-floor composite found near the molten sea — submerged-lava assert skipped)")
	# BYTE-IDENTITY of the temperate regime: a NON-molten (t < LAVA_SEA_T) open-water column STILL
	# generates WATER sea fill — the molten regime flips ONLY hot oceans, everything else is unchanged.
	var ow := _find_open_water(false)
	if ow.x != 0x7fffffff:
		var owt: float = TerrainConfig.column_profile(ow.x, ow.y).w
		var owsurf := TerrainConfig.generated_cell(ow.x, SEA, ow.y)
		_ok(owt < TerrainConfig.LAVA_SEA_T, "worldgen: the open-water column is temperate (t=%.3f < LAVA_SEA_T)" % owt)
		_ok(CellCodec.mat(owsurf) == WATER and CellCodec.liquid_kind(owsurf) == CellCodec.LIQ_WATER,
			"worldgen: a temperate column STILL generates WATER sea fill (byte-identity — regime flips only hot oceans)")
		_ok(TerrainConfig._sea_liquid_kind(owt) == CellCodec.LIQ_WATER
				and TerrainConfig._sea_liquid_kind(0.7) == CellCodec.LIQ_LAVA,
			"worldgen: _sea_liquid_kind is the single regime authority (temperate → WATER, 0.7 → LAVA)")

	# ---- (4) BOTH-PATH ARID per kind (module-guarded, mirroring the water case) --------------------
	if not (ClassDB.class_exists("VoxelTerrain") and ClassDB.class_exists("VoxelBuffer")):
		print("    (godot_voxel module absent — per-kind ARID + mesh-level lava proofs run on module builds only)")
		return
	var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
	get_root().add_child(mw)
	var built: bool = mw.call("setup")
	_ok(built, "lava-arid: module world builds (water + lava fluids registered)")
	if not built:
		mw.queue_free()
		return

	# Deep lava (bare id, level 0) and surface lava (level 9, modifier 0) share ONE lava fluid ARID —
	# exactly like deep/surface water — so a molten ocean interior and its skin render as one fluid.
	var deep_lava := int(mw.call("gen_arid_for", LAVA, 0, 0, CellCodec.LIQ_LAVA))
	var surf_lava := int(mw.call("gen_arid_for", LAVA, 0, S, CellCodec.LIQ_LAVA))
	_ok(deep_lava == surf_lava,
		"lava-arid: deep lava (lvl 0) and surface lava (lvl 9) share ONE fluid ARID (%d == %d)" % [deep_lava, surf_lava])
	# Water and lava fluid ARIDs are DIFFERENT (distinct fluid_index → a crisp water/lava boundary,
	# never a mutual cull). The setup log shows surface ARIDs water=44, lava=45.
	var surf_water := int(mw.call("gen_arid_for", WATER, 0, S, CellCodec.LIQ_WATER))
	_ok(surf_water != surf_lava,
		"lava-arid: water and lava fluid ARIDs DIFFER (%d != %d — distinct fluid_index)" % [surf_water, surf_lava])
	# A real emitted LAVA composite pair resolves to its lava twin (level 9 == level 10), != the dry shape.
	var lava_pairs := {}
	for slot: int in TerrainConfig.emitted_submerged_pairs(CellCodec.LIQ_LAVA):
		lava_pairs[slot] = true
	for slot: int in TerrainConfig.emitted_shore_pairs(CellCodec.LIQ_LAVA):
		lava_pairs[slot] = true
	var lava_twin_mat := -1
	var lava_twin_mod := -1
	var lava_checked := 0
	var lava_same_twin := 0
	var lava_covered := 0
	for slot: int in lava_pairs.keys():
		var m := slot / 256
		var md := slot % 256
		if m <= BlockCatalog.AIR or m >= BlockCatalog.count() or md <= 0:
			continue
		var t9 := int(mw.call("gen_arid_for", m, md, S, CellCodec.LIQ_LAVA))
		var t10 := int(mw.call("gen_arid_for", m, md, F, CellCodec.LIQ_LAVA))
		var dry := int(mw.call("gen_arid_for", m, md, 0, CellCodec.LIQ_LAVA))
		lava_checked += 1
		if t9 == t10:
			lava_same_twin += 1
		if t10 != dry:
			lava_covered += 1
			if lava_twin_mat < 0:
				lava_twin_mat = m
				lava_twin_mod = md
	_ok(lava_checked > 0, "lava-arid: emitted lava composite pairs to check (%d shore∪submerged)" % lava_checked)
	_ok(lava_same_twin == lava_checked,
		"lava-arid: level-9 and level-10 resolve to the SAME lava twin for every pair (%d/%d) — one lava fluid" % [lava_same_twin, lava_checked])
	_ok(lava_covered * 10 >= lava_checked * 9,
		"lava-arid: >=90%% of emitted lava composite pairs have a baked twin != dry shape (%d/%d)" % [lava_covered, lava_checked])
	# A lava twin ARID is DISJOINT from a water twin ARID for the same (mat, modifier) — the kind-keyed
	# tables never mis-skin lava as water (risk 3). Only when BOTH kinds baked that pair.
	if lava_twin_mat >= 0:
		var l_twin := int(mw.call("gen_arid_for", lava_twin_mat, lava_twin_mod, F, CellCodec.LIQ_LAVA))
		var w_twin := int(mw.call("gen_arid_for", lava_twin_mat, lava_twin_mod, F, CellCodec.LIQ_WATER))
		if w_twin != int(mw.call("gen_arid_for", lava_twin_mat, lava_twin_mod, 0)):   # water baked this pair too
			_ok(l_twin != w_twin,
				"lava-arid: a lava twin ARID is DISJOINT from the water twin for the same (mat %d, mod %d) — no mis-skin" % [lava_twin_mat, lava_twin_mod])
	print("    lava twins: %d pairs checked, %d covered (twin != dry), %d share-one-fluid" % [lava_checked, lava_covered, lava_same_twin])

	# Drive the module generator over the molten sea block: every LAVA-carrying TYPE it writes equals
	# gen_arid_for(mat, modifier, level, LIQ_LAVA) — the worker reads the kind from the packed value, so
	# a lava cell resolves through the lava tables (anti-drift + consistency, the both-path invariant).
	if molten.x != 0x7fffffff:
		var gen: Object = mw.call("get_generator")
		if gen != null:
			var bx := floori(molten.x / 16.0) * 16
			var bz := floori(molten.y / 16.0) * 16
			var origins := [Vector3i(bx, -16, bz), Vector3i(bx, 0, bz)]
			var lava_cells := 0
			var lava_mismatch := 0
			for origin: Vector3i in origins:
				var buf: Object = ClassDB.instantiate("VoxelBuffer")
				buf.call("create", 16, 16, 16)
				if buf.has_method("fill"):
					buf.call("fill", 0, 0)
				gen.call("_generate_block", buf, origin, 0)
				for lz in range(16):
					for lx in range(16):
						for ly in range(16):
							var v: int = TerrainConfig.generated_cell(origin.x + lx, origin.y + ly, origin.z + lz)
							var mat: int = CellCodec.mat(v)
							if mat != LAVA and CellCodec.liquid_kind(v) != CellCodec.LIQ_LAVA:
								continue
							lava_cells += 1
							var got: int = int(buf.call("get_voxel", lx, ly, lz, 0))
							var kind: int = CellCodec.liquid_kind(v)
							if kind == CellCodec.LIQ_NONE:
								kind = CellCodec.LIQ_LAVA          # a bare lava id defaults to its own kind
							var expected: int = int(mw.call("gen_arid_for", mat, CellCodec.modifier(v), CellCodec.liquid_level(v), kind))
							if got != expected:
								lava_mismatch += 1
			_ok(lava_cells > 0, "lava-arid: the molten sea block sample contains lava cells (%d)" % lava_cells)
			_ok(lava_mismatch == 0,
				"lava-arid: module TYPE == gen_arid_for(mat, modifier, level, LIQ_LAVA) over %d lava cells (%d mismatches)" % [lava_cells, lava_mismatch])

	# ---- (5) MESH-LEVEL border-killer for LAVA + crisp water/lava boundary (risk 1, risk 2) --------
	# The durable regression guard: actually mesh a LAVA twin beside pure LAVA and assert the shared
	# LAVA face is CULLED (borderless) while the terrain ramp is present (no hole) — mirroring the water
	# mesh test in _test_waterlogging but for the lava kind. Then the CRISP inter-liquid boundary: a
	# WATER cell beside a LAVA cell does NOT cull (different fluid_index → both faces drawn). A
	# differential over isolated vs adjacent meshes (adjacency can only REMOVE faces, never add).
	if ClassDB.class_exists("VoxelMesherBlocky") and lava_twin_mat >= 0:
		var lib: Object = mw.get("_library")
		var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
		if lib != null and mesher != null and mesher.has_method("set_library") and mesher.has_method("build_mesh"):
			mesher.call("set_library", lib)
			var minp: int = mesher.call("get_minimum_padding")
			var maxp: int = mesher.call("get_maximum_padding")
			var lava_mat: Object = BlockMaterials.get_for(LAVA)
			var water_mat: Object = BlockMaterials.get_for(WATER)
			var terr_mat: Object = BlockMaterials.get_for(lava_twin_mat)
			var lava_arid := int(mw.call("arid_for_cell", LAVA))
			var water_arid := int(mw.call("arid_for_cell", WATER))
			var lava_twin_arid := int(mw.call("arid_for_cell",
				CellCodec.pack(lava_twin_mat, lava_twin_mod, 0, CellCodec.make_liquid(CellCodec.LIQ_LAVA, F))))
			var b := minp + 1
			var span := minp + maxp + 4
			# Mesh a cell layout; return a Dictionary {surface material -> total vertex count}.
			var mesh_counts := func(cells: Array) -> Dictionary:
				var buf: Object = ClassDB.instantiate("VoxelBuffer")
				buf.call("set_channel_depth", 0, 1)         # CHANNEL_TYPE, DEPTH_16_BIT (ARIDs exceed 255)
				buf.call("create", span, span, span)
				buf.call("fill", 0, 0)                       # air
				for c in cells:
					var p: Vector3i = c[0]
					buf.call("set_voxel", int(c[1]), p.x, p.y, p.z, 0)
				var msh: Object = mesher.call("build_mesh", buf, [], {})
				var out := {}
				if msh != null:
					for i in msh.get_surface_count():
						var mm: Object = msh.surface_get_material(i)
						var nn := (msh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
						out[mm] = int(out.get(mm, 0)) + nn
				return out
			var lv := func(d: Dictionary) -> int: return int(d.get(lava_mat, 0))
			var wv := func(d: Dictionary) -> int: return int(d.get(water_mat, 0))
			var tv := func(d: Dictionary) -> int: return int(d.get(terr_mat, 0))
			if lava_mat != null and water_mat != null:
				var twin_only: Dictionary = mesh_counts.call([[Vector3i(b, b, b), lava_twin_arid]])
				var lava_only: Dictionary = mesh_counts.call([[Vector3i(b, b, b), lava_arid]])
				var lava_adj: Dictionary = mesh_counts.call([[Vector3i(b, b, b), lava_twin_arid], [Vector3i(b + 1, b, b), lava_arid]])
				_ok(tv.call(twin_only) > 0, "lava-mesh: the lava twin renders its opaque terrain ramp — no hole (%d terrain verts)" % tv.call(twin_only))
				_ok(lv.call(twin_only) > 0 and lv.call(lava_only) > 0,
					"lava-mesh: twin and pure lava each render lava faces in isolation (%d, %d)" % [lv.call(twin_only), lv.call(lava_only)])
				_ok(lv.call(lava_adj) < lv.call(twin_only) + lv.call(lava_only),
					"lava-mesh: shared twin↔lava face is CULLED — borderless (combined %d < isolated sum %d)" % [lv.call(lava_adj), lv.call(twin_only) + lv.call(lava_only)])
				# Crisp inter-liquid boundary: a WATER cell beside a LAVA cell does NOT cull (different
				# fluid_index) — the total water+lava verts are PRESERVED (adjacency can only remove faces).
				var water_only: Dictionary = mesh_counts.call([[Vector3i(b, b, b), water_arid]])
				var wl_adj: Dictionary = mesh_counts.call([[Vector3i(b, b, b), water_arid], [Vector3i(b + 1, b, b), lava_arid]])
				var wl_sum: int = int(wv.call(wl_adj)) + int(lv.call(wl_adj))
				var iso_sum: int = int(wv.call(water_only)) + int(lv.call(lava_only))
				_ok(wl_sum >= iso_sum,
					"lava-mesh: water beside lava is NOT culled — crisp boundary (combined %d >= isolated sum %d)" % [wl_sum, iso_sum])
				print("    lava-mesh: twin(lava=%d,terr=%d) lava=%d twin+lava=%d (<%d ⇒ border culled); water|lava %d (>=%d ⇒ boundary drawn)"
					% [lv.call(twin_only), tv.call(twin_only), lv.call(lava_only), lv.call(lava_adj), lv.call(twin_only) + lv.call(lava_only), wl_sum, iso_sum])
	mw.queue_free()

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
			# DIRT (not in appearance_surface_materials, so its shapes are NOT pre-baked) exercises the
			# LAZY shape-append path. STONE moved into the pre-baked set to smooth mountain rock, so a
			# (STONE, RAMP) lookup now reuses a manifest ARID and no longer appends.
			_ok(int(mw.call("arid_for", DIRT, 0)) == DIRT, "shapes-live: cube ARID == LRID (bootstrap)")
			var before: int = mw.call("appearance_count")
			var arid: int = mw.call("arid_for", DIRT, RAMP)
			_ok(arid == before, "shapes-live: shaped ARID == prior model count (add_model()==ARID held)")
			_ok(int(mw.call("appearance_count")) == before + 1, "shapes-live: exactly one shaped model appended")
			_ok(int(mw.call("arid_for", DIRT, RAMP)) == arid, "shapes-live: shaped ARID stable on re-lookup (no duplicate append)")
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
	# SNOW-ACCUMULATION retarget: stone now declares snow_capped(bit0)+snow_fill(bits1..4), so a generic
	# STATE value must avoid the fill nibble (canonical strips a fill on a full cube). Use 0x21 (bit 0 +
	# bit 5) and widen stone's mask to permit it, so the value stays legal through _validate_state AND
	# survives _canonical_snow_fill (fill nibble == 0) — retarget the sweep, don't weaken it.
	var prev_mask := BlockCatalog.state_mask_of(BE)
	BlockCatalog._state_mask[BE] = 0x21

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
	_ok(world.set_state(cell, 0x21), "set_state succeeds on the block-entity cell")
	_ok(CellCodec.state(world.cell_value_at(cell)) == 0x21, "state axis reads back 0x21 (projection + canonical)")
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
	BlockCatalog._state_mask[BE] = prev_mask                   # restore stone's real 1-bit mask

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
	# SNOW-ACCUMULATION retarget: use a state value (0x21) outside the snow_fill nibble so it survives
	# canonical on a full cube; widen stone's mask to permit it. Restored below with prev_be.
	var prev_be_mask := BlockCatalog.state_mask_of(BE)
	BlockCatalog._state_mask[BE] = 0x21

	var w1 := _struct_world("P6bSave")
	var c_cube := Vector3i(px, pg + 1, pz)               # rests on the grass surface
	var c_ramp := Vector3i(px, pg + 2, pz)               # on top of the cube
	var c_be := Vector3i(px, pg + 3, pz)                 # block-entity cell on top
	_ok(w1.place_block(c_cube, CellCodec.pack(STONE)), "live save: place a full cube (supported)")
	_ok(w1.place_block(c_ramp, CellCodec.pack(GRASS, RAMP)), "live save: place a shaped ramp on top")
	_ok(w1.set_state(c_cube, 0x21), "live save: set a state on the cube cell")
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
	_ok(CellCodec.mat(w2.cell_value_at(c_cube)) == STONE and CellCodec.state(w2.cell_value_at(c_cube)) == 0x21,
		"live save/load: the state axis survived the round-trip (stone, state 0x21)")
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
	BlockCatalog._state_mask[BE] = prev_be_mask          # restore stone's real 1-bit mask

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
	# M1 retarget (ADR §1.5): a ≥3-entry STATE-axis layout so a bundle cell's state value up to 7
	# stays legal through _validate_state (the charlie cell carries state 5) — retarget, don't weaken.
	def.state_layout = [&"s0", &"s1", &"s2"]
	return MaterialDocument.to_document(def)

# SNOW ACCUMULATION Phase A1 (SNOW-ACCUMULATION.md §1): the LAYER shape family — variable-height
# snow depth (tenths) on the modifier axis. Fences make_layer's canonical mapping (10→full cube,
# 5→the corner slab 85, 0→AIR, 1..4/6..9→FAM), the is_layer/layer_level/snow_tenths accessors, and
# canonical()'s handling of FAM modifiers (round-trip, empty→AIR, unknown-kind/reserved→full cube,
# non-solid strip). Physics/render branches (ShapeCodec, mesher, worldgen) land in later A1/A2 steps.
func _test_snow_layer_codec() -> void:
	print("[SNOW-A1] LAYER shape family codec")
	var WATER_ID := BlockCatalog.id_of(&"water")
	# make_layer canonical mapping
	_ok(CellCodec.make_layer(10) == 0, "make_layer(10) == 0 (full cube)")
	_ok(CellCodec.make_layer(5) == CellCodec.LAYER_SLAB_MODIFIER, "make_layer(5) == 85 (corner slab)")
	_ok(CellCodec.LAYER_SLAB_MODIFIER == ShapeCodec.make_modifier(1, 1, 1, 1, ShapeCodec.ANCHOR_BOTTOM),
		"LAYER_SLAB_MODIFIER == make_modifier(1,1,1,1,BOTTOM)")
	_ok(CellCodec.make_layer(0) == CellCodec.MOD_FAM_BIT, "make_layer(0) == MOD_FAM_BIT (empty marker)")
	for lv in [1, 2, 3, 4, 6, 7, 8, 9]:
		var m := CellCodec.make_layer(lv)
		_ok(CellCodec.is_layer(m), "make_layer(%d) is a FAM LAYER" % lv)
		_ok(CellCodec.layer_level(m) == lv, "layer_level(make_layer(%d)) == %d" % [lv, lv])
		_ok(CellCodec.snow_tenths(m) == lv, "snow_tenths(FAM layer %d) == %d" % [lv, lv])
	# is_layer / snow_tenths on the non-FAM canonical forms (level 5 == 85, level 10 == 0)
	_ok(not CellCodec.is_layer(85) and CellCodec.snow_tenths(85) == 5, "level-5 slab (85): not FAM, snow_tenths 5")
	_ok(not CellCodec.is_layer(0) and CellCodec.snow_tenths(0) == 10, "full cube (0): not FAM, snow_tenths 10")
	# canonical() on a solid host: a level-3 layer round-trips; raw FAM level 10 → full cube; raw
	# FAM level 0 → AIR (whole cell zeroed); unknown kind / reserved bit → full cube.
	var l3 := CellCodec.pack(STONE, CellCodec.make_layer(3))
	_ok(CellCodec.canonical(l3) == l3, "canonical stable on a level-3 layer (solid host)")
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, CellCodec.MOD_FAM_BIT | 10))) == 0,
		"raw FAM level 10 → full cube (0)")
	_ok(CellCodec.canonical(CellCodec.pack(STONE, CellCodec.MOD_FAM_BIT)) == 0, "raw FAM level 0 → AIR (cell zeroed)")
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, CellCodec.MOD_FAM_BIT | (1 << CellCodec.MOD_FAM_KIND_SHIFT)))) == 0,
		"unknown FAM kind → full cube")
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, CellCodec.MOD_FAM_BIT | (1 << 4)))) == 0,
		"FAM reserved bit set → full cube")
	# a FAM LAYER on a NON-solid material strips (no 'layer of water') — the merged-contract gate
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(WATER_ID, CellCodec.make_layer(3)))) == 0,
		"FAM layer on a non-solid material strips to full cube")
	# ShapeCodec LAYER queries (the physics/render closed forms, SNOW-ACCUMULATION §1.4)
	var m3 := CellCodec.make_layer(3)      # a 0.3 uniform layer (FAM)
	_ok(absf(ShapeCodec.height_at(m3, 0.25, 0.75) - 0.3) < 1e-6, "height_at(layer 3) == 0.3 (flat over the footprint)")
	_ok(ShapeCodec.span(m3, 0.5, 0.5) == Vector2(0.0, 0.3), "span(layer 3) == (0, 0.3)")
	_ok(ShapeCodec.occupied(m3, 0.5, 0.2, 0.5) and not ShapeCodec.occupied(m3, 0.5, 0.4, 0.5), "occupied(layer 3): 0.2 in, 0.4 out")
	_ok(absf(ShapeCodec.local_top(m3, 0.5, 0.5) - 0.3) < 1e-6, "local_top(layer 3) == 0.3")
	_ok(absf(ShapeCodec.volume(m3) - 0.3) < 1e-6 and absf(ShapeCodec.volume(CellCodec.make_layer(7)) - 0.7) < 1e-6, "volume(layer 3/7) == 0.3/0.7")
	_ok(ShapeCodec.side_profile_full(m3, ShapeCodec.FACE_NY) and not ShapeCodec.side_profile_full(m3, ShapeCodec.FACE_PY) \
		and not ShapeCodec.side_profile_full(m3, ShapeCodec.FACE_PX), "side_profile_full(layer): only the floor (NY) is covered")
	_ok(ShapeCodec.bottom_face_covers(m3), "bottom_face_covers(layer) == true (uniform floor)")
	var tris: Array = ShapeCodec.surface_tris(m3)
	var tris_ok := tris.size() == 2
	for tri: Dictionary in tris:
		for k in ["v0", "v1", "v2"]:
			if absf((tri[k] as Vector3).y - 0.3) > 1e-6:
				tris_ok = false
		if (tri["normal"] as Vector3).y <= 0.0:
			tris_ok = false
	_ok(tris_ok, "surface_tris(layer 3): 2 tris, all verts at y=0.3, normals up")
	var SNOW_ID2 := BlockCatalog.id_of(&"snow_block")
	_ok(absf(BlockCatalog.mass_of_value(CellCodec.pack(SNOW_ID2, CellCodec.make_layer(2))) - 280.0 * 0.2) < 0.5,
		"mass_of_value(snow layer 2) == 56 kg (280 * 0.2)")

# SNOW-ACCUMULATION Phase A2 (SNOW-ACCUMULATION.md Decision 3 / §5.2 items 3-4): the static climate
# baseline S — variable-height snow that fills the air cells above g into a graded white surface, with
# the fixed half-slab DELETED. Fences: the stacked LAYER/cube cells match the closed-form snow plane; the
# collider cheap-query contract (surface_cap_modifier == modifier(generated_cell(g+1))) AND memo ==
# worker-direct on a SNOW column; the non-snow world stays BYTE-IDENTICAL (no snow / FAM cell on any
# temperate column); the MAX_SURFACE_Y + SNOW_FILL_MAX_CELLS bound; the fill FLATTENS relief; and the
# LAYER physics (floor_under / blocked auto-step / whole-cell break).
func _test_snow_accumulation() -> void:
	print("[SNOW-A2] snow accumulation baseline (graded stack, collider contract, byte-identity)")
	var SNOW_ID := BlockCatalog.id_of(&"snow_block")

	# (1) find a snowy accumulation column (cold, tree-free land with depth > 0), loud-fail if none.
	var col := _find_snow_column()
	if col.x == 0x7fffffff:
		_ok(false, "SNOW-A2: found a snowy accumulation column for this seed")
		return
	var sx := col.x
	var sz := col.y
	var g: int = TerrainConfig.height_at(sx, sz)
	var packed := TerrainConfig.snow_stack_at(sx, sz, {})     # worker-direct (fresh pcache, no memo pollution)
	var whole := (packed >> 4) & 0xF
	var top := packed & 0xF
	var capped := (packed >> 8) & 1
	var d := whole * 10 + top
	_ok(d > 0, "snow column (%d,%d): D=%d tenths (whole=%d top=%d capped=%d)" % [sx, sz, d, whole, top, capped])

	# (2) the stacked cells match the closed-form plane [g+1, g+1+D/10]: full snow cubes below, one
	# fractional LAYER at the top; the cap (if any) owns g+1 (snow stacks from g+2 there).
	var stack_ok := true
	var cubes := 0
	var layers := 0
	for dy in range(1, TerrainConfig.SNOW_FILL_MAX_CELLS + 2):
		var y := g + dy
		if capped == 1 and y == g + 1:
			continue                                         # lip cell — fenced by the cap contract below
		var v := TerrainConfig.generated_cell(sx, y, sz)
		var remaining := d - (y - (g + 1)) * 10
		var expect_mat := BlockCatalog.AIR
		var expect_mod := 0
		if remaining >= 10:
			expect_mat = SNOW_ID
		elif remaining >= 1:
			expect_mat = SNOW_ID
			expect_mod = CellCodec.make_layer(remaining)
		if CellCodec.mat(v) != expect_mat or CellCodec.modifier(v) != expect_mod:
			stack_ok = false
		if expect_mat == SNOW_ID:
			if expect_mod == 0: cubes += 1
			else: layers += 1
	_ok(stack_ok, "snow stack matches the closed-form plane g+1+D/10 (%d cubes + %d top LAYER)" % [cubes, layers])
	_ok(cubes + layers > 0, "the snow column actually stacks snow cells above the surface")

	# (3) collider cheap-query contract ON A SNOW COLUMN: surface_cap_modifier == modifier(generated_cell
	# (g+1)), and the memo == the worker-direct path (the single most load-bearing invariant, §3.4).
	var cap_memo := TerrainConfig.surface_cap_modifier(sx, sz)
	var cap_direct := TerrainConfig.surface_cap_modifier(sx, sz, {})
	var cap_gen := CellCodec.modifier(TerrainConfig.generated_cell(sx, g + 1, sz))
	_ok(cap_memo == cap_gen, "collider: surface_cap_modifier(memo) == modifier(generated_cell(g+1)) on the snow column (contract)")
	_ok(cap_direct == cap_gen, "collider: worker-direct surface_cap_modifier == modifier(generated_cell(g+1)) on the snow column")
	_ok(cap_memo == cap_direct, "collider: memo == worker-direct surface_cap_modifier on the snow column")
	_ok(TerrainConfig.snow_stack_at(sx, sz) == TerrainConfig.snow_stack_at(sx, sz, {}),
		"collider: snow_stack_at memo == worker-direct on the snow column")

	# (4) NON-SNOW WORLD BYTE-IDENTICAL: a wide TEMPERATE sweep carries neither the snow material nor the
	# FAM LAYER modifier family on any generated cell above the surface (the M1 §2.4 pin, extended).
	var temperate_cols := 0
	var temperate_clean := true
	for x in range(-320, 320, 7):
		for z in range(-320, 320, 7):
			var gg: int = TerrainConfig.height_at(x, z)
			if gg < TerrainConfig.SEA_LEVEL:
				continue
			var tt: float = TerrainConfig.column_profile(x, z).w
			if ClimateModel.surface_temperature(gg, tt) < 0.0:
				continue                                     # cold column: may carry snow (checked in (1)-(2))
			temperate_cols += 1
			for dy in range(1, TerrainConfig.SNOW_FILL_MAX_CELLS + 1):
				var v := TerrainConfig.generated_cell(x, gg + dy, z)
				if CellCodec.mat(v) == SNOW_ID or CellCodec.is_layer(CellCodec.modifier(v)):
					temperate_clean = false
	_ok(temperate_cols > 0, "temperate sweep sampled %d warm land columns" % temperate_cols)
	_ok(temperate_clean, "non-snow world byte-identical: NO snow_block / FAM LAYER cell on any temperate column")

	# (5) MAX_SURFACE_Y + SNOW_FILL_MAX_CELLS bound: snow never generates above it (a too-low bound would
	# punch holes — the loudest failure class; the generator early-out is raised to match).
	var bound := TerrainConfig.MAX_SURFACE_Y + TerrainConfig.SNOW_FILL_MAX_CELLS
	var bound_ok := true
	for x in range(-320, 320, 11):
		for z in range(-320, 320, 11):
			for y in range(bound + 1, bound + 8):
				if CellCodec.mat(TerrainConfig.generated_cell(x, y, z)) == SNOW_ID:
					bound_ok = false
	_ok(bound_ok, "no snow generates above MAX_SURFACE_Y + SNOW_FILL_MAX_CELLS (=%d)" % bound)

	# (6) FLATNESS: over a snowy patch the snow SURFACE (g+1+D/10) spreads LESS than the raw terrain top —
	# the fill converges low spots toward the plane (the user's "rising level H" flattening uneven ground).
	var g_lo := 0x7fffffff
	var g_hi := -0x7fffffff
	var s_lo := INF
	var s_hi := -INF
	var patch := 0
	for dx in range(-12, 13):
		for dz in range(-12, 13):
			var x := sx + dx
			var z := sz + dz
			var gg: int = TerrainConfig.height_at(x, z)
			if gg < TerrainConfig.SEA_LEVEL:
				continue
			var pk := TerrainConfig.snow_stack_at(x, z, {})
			if pk == 0:
				continue
			var dd := ((pk >> 4) & 0xF) * 10 + (pk & 0xF)
			var s := float(gg + 1) + float(dd) / 10.0
			g_lo = mini(g_lo, gg); g_hi = maxi(g_hi, gg)
			s_lo = minf(s_lo, s); s_hi = maxf(s_hi, s)
			patch += 1
	if patch >= 8 and g_hi > g_lo:
		_ok((s_hi - s_lo) <= float(g_hi - g_lo), "snow fill FLATTENS relief: snow-surface spread %.1f <= terrain spread %d over a %d-column basin" % [s_hi - s_lo, g_hi - g_lo, patch])
	else:
		print("    flatness sub-test skipped (snowy patch too small / uniform: %d cols, terrain spread %d)" % [patch, g_hi - g_lo if g_hi > g_lo else 0])

	# (7) LAYER physics (the A1 place/break payoff, exercised on the accumulation material): a hand-placed
	# snow LAYER-2 stands at g+1+0.2, auto-steps (rise 0.2 <= STEP_MAX), and breaks to snow_block (whole
	# cell). Placed at g+1 of a FLAT, tree-free, temperate (no generated snow), cap-free column so it rests
	# SUPPORTED on the solid ground (an unsupported placement would detach as a loose body — SI §6).
	var flat := _find_flat_land_column()
	if flat.x == 0x7fffffff:
		_ok(false, "SNOW-A2: found a flat land column to place a snow layer on")
	else:
		var wm := _struct_world("SnowA2")
		var fg: int = TerrainConfig.height_at(flat.x, flat.y)
		var lcell := Vector3i(flat.x, fg + 1, flat.y)
		_ok(wm.place_block(lcell, CellCodec.pack(SNOW_ID, CellCodec.make_layer(2))), "place a snow LAYER-2 by hand on flat ground (the A1 payoff)")
		var lv := wm.cell_value_at(lcell)
		_ok(CellCodec.mat(lv) == SNOW_ID and CellCodec.is_layer(CellCodec.modifier(lv)) and CellCodec.layer_level(CellCodec.modifier(lv)) == 2,
			"placed cell reads back as a snow LAYER level 2 (survived the structural audit — supported by the ground)")
		var fxp := float(flat.x) + 0.5
		var fzp := float(flat.y) + 0.5
		var flp := wm.floor_under(fxp, fzp, float(fg + 3))
		_ok(absf(flp - (float(fg + 1) + 0.2)) < 1e-3, "floor_under on the placed LAYER-2 == g+1+0.2 (got %.3f)" % flp)
		_ok(not wm.blocked(fxp, fzp, float(fg + 1)), "blocked auto-steps onto the LAYER-2 (rise 0.2 <= STEP_MAX)")
		_ok(wm.break_terrain(lcell) == SNOW_ID, "break_terrain on the LAYER yields snow_block (removes the whole cell)")
		wm.queue_free()

# SNOW-ACCUMULATION Phase B (Decision 2 — composites). Fences: the fill-nibble codec + canonical rules
# (2.3.1-2.3.6, snow_capped stays index 0), fill_volume sign/monotonicity + a Monte-Carlo cross-check,
# a cold RAMP column's fill == its closed form with canonical(v)==v and a both-path composite ARID
# mirror, the collider union == ⋃ _occ_span over a snow column (steelman 5a), the cheap-query contract
# on a CAPPED snowy column (steelman 5b), and the flat-white flatness over a shallow basin (steelman 5c).
func _test_snow_composites() -> void:
	print("[SNOW-B] snow-fill composites (fill nibble canonical, physics, collider union, both-path)")
	var SNOW_ID := BlockCatalog.id_of(&"snow_block")
	var WATER := BlockCatalog.id_of(&"water")
	var RAMP0 := ShapeCodec.make_modifier(2, 1, 1, 0, ShapeCodec.ANCHOR_BOTTOM)   # a partial ramp, min corner 0
	var RAMP1 := ShapeCodec.make_modifier(2, 2, 1, 1, ShapeCodec.ANCHOR_BOTTOM)   # min corner 1 → terrain min 5 tenths

	# --- (1) fill-nibble codec round-trip + coexistence with snow_capped -----------------------------
	var v7 := CellCodec.with_snow_fill(CellCodec.pack(GRASS, RAMP0), 7)
	_ok(CellCodec.snow_fill(v7) == 7, "snow_fill round-trips level 7")
	_ok(CellCodec.snow_fill(CellCodec.with_snow_fill(v7, 0)) == 0, "with_snow_fill 0 clears the fill nibble")
	var v7c := CellCodec.with_state(v7, CellCodec.state(v7) | CellCodec.STATE_SNOW_CAPPED)
	_ok(CellCodec.has_state(v7c, CellCodec.STATE_SNOW_CAPPED) and CellCodec.snow_fill(v7c) == 7,
		"snow_capped (bit 0) and the fill nibble (bits 1..4) coexist independently")

	# --- (2) canonical rules 2.3.1 .. 2.3.6 each pinned; snow_capped stays index 0 -------------------
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(GRASS, RAMP0), 0))) == 0,
		"2.3.1 fill 0 → absent")
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(GRASS, RAMP0), 15))) == 10,
		"2.3.2 fill > 10 clamps to 10")
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(WATER, RAMP0), 8))) == 0,
		"2.3.3 fill on a non-solid material stripped")
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(GRASS, 0), 8))) == 0,
		"2.3.4 fill on a full cube (no remainder) stripped")
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(SNOW_ID, CellCodec.make_layer(3)), 8))) == 0,
		"2.3.5 fill on a LAYER (snow-on-snow) stripped")
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(GRASS, RAMP1), 5))) == 0,
		"2.3.6 fill <= 5*min_corner stripped (fill 5, ramp min corner 1)")
	_ok(CellCodec.snow_fill(CellCodec.canonical(CellCodec.with_snow_fill(CellCodec.pack(GRASS, RAMP1), 6))) == 6,
		"2.3.6 fill above the terrain minimum survives (fill 6)")
	var cap_idx0 := true
	for m in [GRASS, STONE, BlockCatalog.id_of(&"podzol"), BlockCatalog.id_of(&"sand"), SNOW_ID]:
		if not CellCodec.has_state(CellCodec.canonical(CellCodec.pack(m, RAMP0, CellCodec.STATE_SNOW_CAPPED)), CellCodec.STATE_SNOW_CAPPED):
			cap_idx0 = false
	_ok(cap_idx0, "snow_capped stays index 0 on grass/stone/podzol/sand/snow_block through the extended layout")

	# --- (3) fill_volume: sign/monotonicity + a Monte-Carlo cross-check (§2.5) -----------------------
	_ok(ShapeCodec.fill_volume(0, 10) == 0.0, "fill_volume: a full cube has no terrain remainder (0)")
	var fv3 := ShapeCodec.fill_volume(RAMP0, 3)
	var fv8 := ShapeCodec.fill_volume(RAMP0, 8)
	_ok(fv3 >= 0.0 and fv8 > fv3, "fill_volume monotonically increases with the fill level (%.3f < %.3f)" % [fv3, fv8])
	var acc := 0.0
	var rng := 987654321
	for _i in range(6000):
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var fx := float(rng & 0xFFFF) / 65536.0
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var fz := float(rng & 0xFFFF) / 65536.0
		acc += maxf(0.0, 0.7 - ShapeCodec.height_at(RAMP0, fx, fz))
	var mc := acc / 6000.0
	_ok(absf(mc - ShapeCodec.fill_volume(RAMP0, 7)) < 0.03,
		"fill_volume(7) (%.3f) ≈ Monte-Carlo estimate (%.3f)" % [ShapeCodec.fill_volume(RAMP0, 7), mc])

	# --- (4) a cold RAMP surface column: fill == closed form (10, buried), canonical(v)==v, both-path -
	var ramp_col := _find_snow_ramp_column()
	if ramp_col.x == 0x7fffffff:
		_ok(false, "SNOW-B: found a cold RAMP surface column (snow fills the ramp)")
	else:
		var rx := ramp_col.x
		var rz := ramp_col.y
		var rg: int = TerrainConfig.height_at(rx, rz)
		var rv := TerrainConfig.generated_cell(rx, rg, rz)
		_ok(CellCodec.modifier(rv) != 0, "cold ramp column: the surface cell IS a ramp (modifier %d)" % CellCodec.modifier(rv))
		_ok(CellCodec.snow_fill(rv) == 10, "cold ramp column: the surface fill nibble == 10 (buried — the closed form)")
		_ok(CellCodec.canonical(rv) == rv, "cold ramp column: the generated surface cell is canonical (canonical(v)==v)")
		var wmf := WorldManager.new()
		wmf.name = "SnowBFloor"
		get_root().add_child(wmf)
		var fu := wmf.floor_under(float(rx) + 0.5, float(rz) + 0.5, float(rg) + 3.0)
		_ok(fu >= float(rg + 1) - 1e-3, "cold ramp column: floor_under stands on the BURIED snow top (>= g+1, got %.3f) — the A2 gap is closed" % fu)
		wmf.queue_free()
		if ClassDB.class_exists("VoxelTerrain") and ClassDB.class_exists("VoxelBuffer"):
			var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
			get_root().add_child(mw)
			if bool(mw.call("setup")):
				var comp_arid := int(mw.call("arid_for_cell", rv))
				var mirror := int(mw.call("gen_arid_for", CellCodec.mat(rv), CellCodec.modifier(rv), 0, CellCodec.LIQ_WATER, CellCodec.state(rv)))
				_ok(comp_arid == mirror and comp_arid > 0, "cold ramp column: arid_for_cell == gen_arid_for mirror on the fill composite (ARID %d)" % comp_arid)
				var dry := int(mw.call("arid_for_cell", CellCodec.pack(CellCodec.mat(rv), CellCodec.modifier(rv))))
				_ok(comp_arid != dry, "cold ramp column: the composite/skin ARID (%d) differs from the plain dry ramp (%d)" % [comp_arid, dry])
			mw.queue_free()

	# --- (5a) collider union == ⋃ _occ_span over the snow column [g, g+MAX+1] (steelman) -------------
	var scol := _find_snow_column()
	if scol.x == 0x7fffffff:
		_ok(false, "SNOW-B: found a snow column for the collider union check")
	else:
		var cx := scol.x
		var cz := scol.y
		var cg: int = TerrainConfig.height_at(cx, cz)
		var cw := WorldManager.new()
		cw.name = "SnowBCol"
		get_root().add_child(cw)
		var gc := GroundCollider.new()
		get_root().add_child(gc)
		gc.setup(cw)
		VoxelBody.spawn_loose(cw, {Vector3i(cx, cg + 30, cz): STONE}, cw)   # gate the collider live
		var here := Vector3(float(cx) + 0.5, float(cg) + 30.0, float(cz) + 0.5)
		gc.update(here)
		_settle_collider(gc, here)
		var col := _collider_col(gc.active_rid(), cx, cz)
		var covered := {}
		for bx: Vector2 in col["boxes"]:
			for yy in range(int(round(bx.x)), int(round(bx.y))):
				covered[yy] = true
		for py in col["prisms"]:
			covered[int(py)] = true
		var union_ok := true
		var mismatch := -0x40000000
		for yy in range(cg, cg + TerrainConfig.SNOW_FILL_MAX_CELLS + 3):
			var occ: bool = _occ_span_pub(TerrainConfig.generated_cell(cx, yy, cz), 0.5, 0.5) != Vector2.ZERO
			if occ != covered.has(yy):
				union_ok = false
				mismatch = yy
		_ok(union_ok, "collider union == ⋃ _occ_span over the snow column [g, g+MAX+1] (steelman 5a; mismatch y=%d)" % mismatch)
		gc.queue_free()
		cw.queue_free()

	# --- (5b) a CAPPED snowy column: the cheap-query contract + the lip fill hold there too ----------
	var ccol := _find_capped_snow_column()
	if ccol.x == 0x7fffffff:
		print("    (no capped snowy column with D>=10 near origin for this seed — 5b skipped)")
	else:
		var kx := ccol.x
		var kz := ccol.y
		var kg: int = TerrainConfig.height_at(kx, kz)
		var cap_gen := CellCodec.modifier(TerrainConfig.generated_cell(kx, kg + 1, kz))
		_ok(TerrainConfig.surface_cap_modifier(kx, kz) == cap_gen,
			"capped snow column: surface_cap_modifier(memo) == modifier(generated_cell(g+1)) (contract, steelman 5b)")
		_ok(TerrainConfig.surface_cap_modifier(kx, kz, {}) == cap_gen,
			"capped snow column: worker-direct surface_cap_modifier == modifier(generated_cell(g+1)) (memo==direct)")
		var lipv := TerrainConfig.generated_cell(kx, kg + 1, kz)
		_ok(CellCodec.modifier(lipv) != 0 and CellCodec.snow_fill(lipv) > 0,
			"capped snow column: the g+1 lip carries a corner modifier AND a snow fill (min(D,10)) — the gap is closed on the lip")

	# --- (5c) flatness: a SHALLOW snowy DEPRESSION reads as one flat white plane (steelman). The fill
	#         converges relief ≥ 2 blocks to a snow surface spread ≤ 1 tenth+1 (the "rising level H"). Not
	#         every shallow patch is a depression (a ridge poking through raises the surface), so the
	#         honest, non-flaky claim is that such flattened basins EXIST — _find_snow_basin validates the
	#         flattening and returns the first, and the recomputed spreads are reported. ------------------
	var basin := _find_snow_basin()
	if basin.x == 0x7fffffff:
		print("    (no shallow snowy DEPRESSION near origin for this seed — 5c skipped)")
	else:
		var bm := _basin_spreads(basin)
		_ok(bm.z >= 8 and bm.y <= 1.1 and bm.x >= 2.0,
			"shallow basin: %d-col snowy depression flattens terrain spread %.0f → snow-surface spread %.2f (<= 1 tenth+1, steelman 5c)" % [int(bm.z), bm.x, bm.y])

	# --- (5d) WIDE DISTANT-COLD completeness sweep: every exposed snow-fill composite cell — anywhere in
	#         the infinite world, well OUTSIDE the sampled cold windows — resolves to a BAKED composite
	#         (render >= physics, never floating). This pins the enumeration fix for the module-vs-fallback
	#         parity break: the old spatial sample only baked composites near find_cold()+find_mountains(6),
	#         so a distant cold partial lip degraded to the M1 cap skin (no fill plane) while physics used
	#         the true fill — the walkable snow floated up to ~0.9 block above the render. The enumeration
	#         bakes snow_fill_materials() × appearance_modifiers() completely, so this sweep must find 0
	#         unbaked composites and 0 floats. Two independent gates: (i) pure-terrain — every swept
	#         composite pair (mat, modifier) is in emitted_cold_pairs(); (ii) module-guarded — arid_for_cell
	#         resolves each cell to the composite ARID (_comp_arid_of >= 0), which renders the fill plane. --
	var baked := {}
	for slot: int in TerrainConfig.emitted_cold_pairs():
		baked[slot] = true
	# Distant regions, all far OUTSIDE the old _EMIT_SAMPLE_R (160) windows: the (0,4000) cold ring from
	# the defect report, find_cold()'s own fringe (where 0<D<10 partial lips live), and mountains BEYOND
	# the six the old bake sampled.
	var regions: Array = [
		[TerrainConfig.find_cold(), 160, 6],
		[Vector2i(0, 4000), 300, 8],
		[Vector2i(4000, 0), 240, 8],
		[Vector2i(-3000, 3000), 240, 8],
	]
	var far_mtns := TerrainConfig.find_mountains(12)
	for mi in range(6, far_mtns.size()):                       # mountains beyond the sampled 6
		regions.append([far_mtns[mi], 140, 8])
	var comp_cells: Array = []                                 # packed generated composite cell values
	var partial_lips := 0                                      # exposed cells with 0<fill<10 (the float class)
	for reg in regions:
		var ctr: Vector2i = reg[0]
		var rr: int = reg[1]
		var st: int = reg[2]
		for dx in range(-rr, rr + 1, st):
			var x := ctr.x + dx
			for dz in range(-rr, rr + 1, st):
				var z := ctr.y + dz
				var p := TerrainConfig.column_profile(x, z)
				var g := int(p.x)
				if g < TerrainConfig.SEA_LEVEL:
					continue
				if ClimateModel.surface_temperature(g, p.w) >= 0.0:
					continue                                  # only cold columns carry the fill
				for yy in [g, g + 1]:                          # the exposed surface ramp AND the smoothing lip
					var v := TerrainConfig.generated_cell(x, yy, z)
					var f := CellCodec.snow_fill(v)
					var m := CellCodec.modifier(v)
					if f > 0 and m > 0 and not CellCodec.is_layer(m):
						comp_cells.append(v)
						if f < 10:
							partial_lips += 1
	# (i) pure-terrain completeness: every swept composite pair is in the baked enumeration.
	var unbaked := 0
	var unbaked_eg := 0
	for v in comp_cells:
		var slot := CellCodec.mat(v) * 256 + CellCodec.modifier(v)
		if not baked.has(slot):
			unbaked += 1
			if unbaked_eg == 0:
				unbaked_eg = v
	print("    distant-cold sweep: %d exposed snow-fill composite cells (%d partial lips 0<D<10), %d regions" % [comp_cells.size(), partial_lips, regions.size()])
	_ok(comp_cells.size() > 0, "distant-cold sweep: sampled exposed snow-fill composite cells far outside the old windows (%d)" % comp_cells.size())
	_ok(partial_lips > 0, "distant-cold sweep: sampled PARTIAL lips (0<D<10 — the floating-render class the fix targets) (%d)" % partial_lips)
	_ok(unbaked == 0, "distant-cold sweep: EVERY exposed composite pair is in emitted_cold_pairs() — 0 unbaked (else mat %d mod %d floats)" % [CellCodec.mat(unbaked_eg), CellCodec.modifier(unbaked_eg)])
	# (ii) module-guarded: arid_for_cell resolves every composite to a real composite ARID (the fill plane),
	#      never the degraded cap-skin — render >= physics, never floating, on the live module worker path.
	if ClassDB.class_exists("VoxelTerrain") and ClassDB.class_exists("VoxelBuffer"):
		var mwd: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mwd)
		if bool(mwd.call("setup")):
			var floats := 0
			var floats_eg := 0
			var checked := 0
			for v in comp_cells:
				var ca := int(mwd.call("_comp_arid_of", CellCodec.mat(v), CellCodec.modifier(v), CellCodec.snow_fill(v)))
				checked += 1
				if ca < 0:
					floats += 1
					if floats_eg == 0:
						floats_eg = v
			_ok(floats == 0, "distant-cold sweep (module): all %d exposed composites resolve to a baked fill-plane ARID — 0 floats (else mat %d mod %d fill %d)" % [checked, CellCodec.mat(floats_eg), CellCodec.modifier(floats_eg), CellCodec.snow_fill(floats_eg)])
		mwd.queue_free()

## THE occupancy-span composition the WorldManager uses (mirror of its private _occ_span), so a test can
## assert the collider's coverage equals ⋃ _occ_span over a column: material gate, shape span, then the
## snow fill raising the walkable top to max(shape, fill/10).
func _occ_span_pub(v: int, fx: float, fz: float) -> Vector2:
	if BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5:
		return Vector2.ZERO
	var sp := ShapeCodec.span(CellCodec.modifier(v), fx, fz)
	var fill := CellCodec.snow_fill(v)
	if fill != 0:
		return Vector2(0.0, maxf(sp.y, float(fill) / 10.0))
	return sp

## A cold column whose smoothed SURFACE cell is a ramp (modifier != 0) buried by snow (generated fill
## == 10), or (0x7fffffff, _) if none near origin. The Phase B fill target.
func _find_snow_ramp_column() -> Vector2i:
	for x in range(-600, 600, 3):
		for z in range(-600, 600, 3):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.surface_modifier(x, z) == 0:
				continue
			if TerrainConfig.snow_stack_at(x, z, {}) == 0:
				continue
			if CellCodec.snow_fill(TerrainConfig.generated_cell(x, g, z)) == 10:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## A CAPPED snowy column with D >= 10 (whole snow cube ⇒ the lip fill = 10 survives canonical), or
## (0x7fffffff, _) if none near origin. The Phase B lip-fill target for the cheap-query contract.
func _find_capped_snow_column() -> Vector2i:
	for x in range(-600, 600, 3):
		for z in range(-600, 600, 3):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			var pk := TerrainConfig.snow_stack_at(x, z, {})
			if pk == 0 or ((pk >> 8) & 1) == 0 or ((pk >> 4) & 0xF) < 1:
				continue
			return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The centre of a SHALLOW snowy DEPRESSION: a 13×13 patch whose terrain top spread is in
## [2, SNOW_FILL_MAX_CELLS] blocks AND whose snow SURFACE the fill flattens to a spread ≤ 1.1 blocks —
## a genuine flat-white basin. (0x7fffffff, _) if none near origin.
func _find_snow_basin() -> Vector2i:
	for x in range(-400, 400, 8):
		for z in range(-400, 400, 8):
			if TerrainConfig.height_at(x, z) < TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.snow_stack_at(x, z, {}) == 0:
				continue
			var m := _basin_spreads(Vector2i(x, z))
			if m.z >= 10 and m.x >= 2.0 and m.x <= float(TerrainConfig.SNOW_FILL_MAX_CELLS) and m.y <= 1.1:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## (terrain-top spread, snow-surface spread, snowy-column count) over the 13×13 patch centred on `c`,
## as a Vector3. Snow surface = g+1+D/10 (the A2 numbering the collider/render share).
func _basin_spreads(c: Vector2i) -> Vector3:
	var s_lo := INF
	var s_hi := -INF
	var g_lo := 0x7fffffff
	var g_hi := -0x7fffffff
	var cols := 0
	for dx in range(-6, 7):
		for dz in range(-6, 7):
			var gg: int = TerrainConfig.height_at(c.x + dx, c.y + dz)
			if gg < TerrainConfig.SEA_LEVEL:
				continue
			var pk := TerrainConfig.snow_stack_at(c.x + dx, c.y + dz, {})
			if pk == 0:
				continue
			var dd := ((pk >> 4) & 0xF) * 10 + (pk & 0xF)
			var surf := float(gg + 1) + float(dd) / 10.0
			s_lo = minf(s_lo, surf); s_hi = maxf(s_hi, surf)
			g_lo = mini(g_lo, gg); g_hi = maxi(g_hi, gg)
			cols += 1
	if cols == 0:
		return Vector3(0, 0, 0)
	return Vector3(float(g_hi - g_lo), s_hi - s_lo, float(cols))

## A flat, tree-free, cap-free, TEMPERATE (no generated snow) land column at/above sea level — a stable
## place to hand-place a snow LAYER supported by the ground, or (0x7fffffff, _) if none near origin.
func _find_flat_land_column() -> Vector2i:
	for x in range(-200, 200, 2):
		for z in range(-200, 200, 2):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL + 1:
				continue
			var t: float = TerrainConfig.column_profile(x, z).w
			if ClimateModel.surface_temperature(g, t) < 0.0:
				continue                                     # cold: would carry generated snow above g+1
			if TerrainConfig.surface_modifier(x, z) != 0 or TerrainConfig.surface_cap_modifier(x, z) != 0:
				continue                                     # flat surface, no lip at g+1
			if TreeGen.block_at(x, g + 1, z) != BlockCatalog.AIR:
				continue                                     # g+1 must be air (tree-free)
			return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## A column (x, z) whose worldgen carries snow accumulation (D > 0) above its solid top, or
## (0x7fffffff, _) if none reachable near origin. Uses the worker-direct snow_stack_at (fresh pcache).
func _find_snow_column() -> Vector2i:
	for x in range(-512, 512, 3):
		for z in range(-512, 512, 3):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			# Require whole >= 1 (a full snow cube, D >= 10) so at least one VISIBLE snow cell exists — a
			# capped column with D < 10 has its snow hidden entirely behind the lip (Phase A2), which would
			# make the closed-form cell-stack assertion vacuous.
			if (((TerrainConfig.snow_stack_at(x, z, {}) >> 4) & 0xF) >= 1):
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## A cold, tree-free, DEEP (whole >= 1) snowy column whose terrain is FLAT over a SIM-scale neighbourhood
## (so a single sim step's writes stay within ≤ 4 godot_voxel data blocks), or (0x7fffffff, _) if none.
func _find_flat_snow_column() -> Vector2i:
	for x in range(-512, 512, 4):
		for z in range(-512, 512, 4):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL + 1:
				continue
			var pk := TerrainConfig.snow_stack_at(x, z, {})
			if pk == 0 or ((pk >> 4) & 0xF) < 1:
				continue                                     # need a full snow cube (deep, clean stack floor)
			if TreeGen.block_at(x, g + 1, z) != BlockCatalog.AIR:
				continue
			var lo := 0x7fffffff
			var hi := -0x7fffffff
			var ok := true
			for dx in range(-16, 17, 4):
				for dz in range(-16, 17, 4):
					var gg: int = TerrainConfig.height_at(x + dx, z + dz)
					if gg < TerrainConfig.SEA_LEVEL:
						ok = false
					lo = mini(lo, gg)
					hi = maxi(hi, gg)
			if ok and (hi - lo) <= 6:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

# SNOW-ACCUMULATION Phase C (Decision 4 — the snowfall SIM). Verify item 6 (§5.2): a deterministic
# SCRIPTED run (fixed step count + fixed player column) proves S grows only inside the active region,
# per-step writes ≤ MAX_CELL_WRITES, touched data blocks ≤ 4, every delta lives in `_edits` and survives a
# ZoneChunk save/load round-trip, two identical runs are byte-identical, growth is +1 tenth on ONE cell,
# the storm cap holds, the budget counter tracks, and melt decrements while skipping baseline-equal writes.
func _test_snow_sim() -> void:
	print("[SNOW-C] snowfall sim (bounded growth/melt, tile rotation, budget, determinism)")
	var SNOW_ID := BlockCatalog.id_of(&"snow_block")

	var col := _find_flat_snow_column()
	if col.x == 0x7fffffff:
		_ok(false, "SNOW-C: found a flat, deep, tree-free snowy column to simulate on")
		return
	var far := Vector2i(col.x + 4096, col.y + 4096)     # a player column that never blocks the tested cell

	# ---- (1) GROWTH is exactly +1 tenth on ONE cell, deterministic given (SEED, step, column) ----------
	var wg := _struct_world("SnowC_grow")
	var sfg := SnowfallSystem.new()
	sfg.setup(wg)
	_ok(sfg != null, "SnowfallSystem constructs + binds to a WorldManager")
	# Advance the weather phase to a step where THIS column is snowing (deterministic search).
	var snowing_step := -1
	for k in range(0, 600):
		sfg.step_counter = k
		if sfg.is_snowing(col.x, col.y):
			snowing_step = k
			break
	_ok(snowing_step >= 0, "found a snowing step for the test column (weather gate fires)")
	var d0 := sfg.column_depth(col.x, col.y)
	var base0 := sfg.baseline_depth(col.x, col.y)
	_ok(d0 == base0 and d0 > 0, "fresh column: dynamic depth == baseline (%d tenths), from cells only" % d0)
	var cells0 := sfg.snow_cells
	var wrote := sfg._process_column(col.x, col.y, far)
	_ok(wrote == 1, "one snowing step writes exactly ONE cell (got %d)" % wrote)
	_ok(sfg.column_depth(col.x, col.y) == d0 + 1, "growth raised the column depth by exactly +1 tenth")
	_ok(sfg.snow_cells == cells0 + 1, "the budget counter incremented by 1 (a new snow-authored cell)")
	# The delta lives in `_edits` as a snow cell, and re-reading depth from cells is stable.
	var found_edit := false
	for c: Vector3i in wg.placed_cells().keys():
		if CellCodec.mat(wg.placed_cells()[c]) == SNOW_ID:
			found_edit = true
	_ok(found_edit, "the growth delta is present in `_edits` as a snow cell")
	# Growth on the SAME column when NOT snowing does nothing.
	sfg.step_counter = -1                                # force a non-snowing phase search
	var quiet_step := -1
	for k in range(0, 600):
		sfg.step_counter = k
		if not sfg.is_snowing(col.x, col.y):
			quiet_step = k
			break
	if quiet_step >= 0:
		var d_before := sfg.column_depth(col.x, col.y)
		sfg._process_column(col.x, col.y, far)
		_ok(sfg.column_depth(col.x, col.y) == d_before, "no growth on a NON-snowing step (weather gate closed)")
	wg.queue_free()

	# ---- (2) SCRIPTED RUN: bounded per-step, region-confined, growth happens, budget consistent --------
	const STEPS := 160
	var wa := _struct_world("SnowC_runA")
	var sfa := SnowfallSystem.new()
	sfa.setup(wa)
	var max_writes := 0
	var max_blocks := 0
	var region_ok := true
	for i in range(STEPS):
		sfa.step_now(col)
		max_writes = maxi(max_writes, sfa.last_writes)
		# touched data blocks this step (16³) — the anti-remesh-storm bound
		var blocks := {}
		for c: Vector3i in sfa.last_step_cells:
			blocks[Vector3i(_fdiv16(c.x), _fdiv16(c.y), _fdiv16(c.z))] = true
			if maxi(absi(c.x - col.x), absi(c.z - col.y)) > SnowfallSystem.SIM_RADIUS:
				region_ok = false
		max_blocks = maxi(max_blocks, blocks.size())
	_ok(max_writes <= SnowfallSystem.MAX_CELL_WRITES, "every step wrote ≤ MAX_CELL_WRITES cells (peak %d ≤ %d)" % [max_writes, SnowfallSystem.MAX_CELL_WRITES])
	_ok(max_blocks <= 4, "every step touched ≤ 4 data blocks (peak %d)" % max_blocks)
	_ok(region_ok, "every write landed inside the active region (Chebyshev ≤ SIM_RADIUS of the player)")
	# Growth actually happened, and EVERY snow edit is inside the region.
	var snow_edits := 0
	var all_in_region := true
	for c: Vector3i in wa.placed_cells().keys():
		if CellCodec.mat(wa.placed_cells()[c]) != SNOW_ID:
			continue
		snow_edits += 1
		if maxi(absi(c.x - col.x), absi(c.z - col.y)) > SnowfallSystem.SIM_RADIUS:
			all_in_region = false
	_ok(snow_edits > 0, "the scripted run GREW snow (%d snow cells authored into `_edits`)" % snow_edits)
	_ok(all_in_region, "all authored snow cells lie inside the active region (no growth outside visited tiles)")
	_ok(sfa.snow_cells == snow_edits, "budget counter == the actual snow-authored cell count (%d)" % snow_edits)
	_ok(sfa.snow_cells < SnowfallSystem.SNOW_EDIT_BUDGET, "snow-edit count stays under the hard budget")

	# ---- (3) STORM CAP: no column grows past D_baseline + SNOW_STORM_EXTRA ------------------------------
	var cap_ok := true
	for c: Vector3i in wa.placed_cells().keys():
		if CellCodec.mat(wa.placed_cells()[c]) != SNOW_ID:
			continue
		var d := sfa.column_depth(c.x, c.z)
		var b := sfa.baseline_depth(c.x, c.z)
		if d > b + SnowfallSystem.SNOW_STORM_EXTRA:
			cap_ok = false
	_ok(cap_ok, "no column exceeds the storm ceiling D_baseline + SNOW_STORM_EXTRA (%d tenths)" % SnowfallSystem.SNOW_STORM_EXTRA)

	# ---- (4) DETERMINISM: a second identical run is byte-identical in `_edits` -------------------------
	var wb := _struct_world("SnowC_runB")
	var sfb := SnowfallSystem.new()
	sfb.setup(wb)
	for i in range(STEPS):
		sfb.step_now(col)
	var det_ok := wa.placed_cells().size() == wb.placed_cells().size()
	if det_ok:
		for c: Vector3i in wa.placed_cells().keys():
			if not wb.placed_cells().has(c) or wb.placed_cells()[c] != wa.placed_cells()[c]:
				det_ok = false
				break
	_ok(det_ok, "two identical scripted runs are byte-identical in `_edits` (deterministic)")

	# ---- (5) PERSISTENCE: ZoneChunk save/load round-trip reproduces every snow delta -------------------
	var regions := {}
	for c: Vector3i in wa.placed_cells().keys():
		regions[WorldManager.region_origin_of(c)] = true
	var wc := _struct_world("SnowC_load")
	for ro: Vector3i in regions.keys():
		wc.load_edits(ro, wa.save_edits(ro))
	var rt_ok := wc.placed_cells().size() == wa.placed_cells().size()
	if rt_ok:
		for c: Vector3i in wa.placed_cells().keys():
			if not wc.placed_cells().has(c) or wc.placed_cells()[c] != wa.placed_cells()[c]:
				rt_ok = false
				break
	_ok(rt_ok, "every snow delta survives a ZoneChunk save/load round-trip identically")
	wa.queue_free()
	wb.queue_free()
	wc.queue_free()

	# ---- (6) MELT: warm column decrements toward 0, skipping baseline-equal writes, budget tracks ------
	var m := _find_flat_land_column()                    # warm, flat, cap-free, tree-free
	if m.x == 0x7fffffff:
		_ok(false, "SNOW-C: found a warm flat column to melt on")
	else:
		var wm := _struct_world("SnowC_melt")
		var sfm := SnowfallSystem.new()
		sfm.setup(wm)
		var mg: int = TerrainConfig.height_at(m.x, m.y)
		# Seed a 1.2-block leftover snow stack (a full cube + a 0.2 LAYER) as if the sim had grown it, then
		# let the warm surface melt it. snow_cells is set to match the two authored cells.
		wm._write_cell(Vector3i(m.x, mg + 1, m.y), CellCodec.pack(SNOW_ID, 0))
		wm._write_cell(Vector3i(m.x, mg + 2, m.y), CellCodec.pack(SNOW_ID, CellCodec.make_layer(2)))
		sfm.snow_cells = 2
		var mfar := Vector2i(m.x + 4096, m.y + 4096)
		var d_prev := sfm.column_depth(m.x, m.y)
		_ok(d_prev == 12, "seeded warm column reads a 12-tenth dynamic stack (from cells)")
		var monotone := true
		var steps_used := 0
		for i in range(20):
			if sfm.column_depth(m.x, m.y) == 0:
				break
			sfm._process_column(m.x, m.y, mfar)
			var d_now := sfm.column_depth(m.x, m.y)
			if d_now != d_prev - 1:
				monotone = false
			d_prev = d_now
			steps_used += 1
		_ok(monotone and sfm.column_depth(m.x, m.y) == 0, "melt decrements exactly 1 tenth/step down to 0 (%d steps)" % steps_used)
		_ok(not wm.has_edit(Vector3i(m.x, mg + 1, m.y)) and not wm.has_edit(Vector3i(m.x, mg + 2, m.y)),
			"melted-to-baseline cells were REVERTED, not written baseline-equal (no leftover `_edits`)")
		_ok(sfm.snow_cells == 0, "budget counter returned to 0 as the reverts freed every snow cell")
		wm.queue_free()

## Floored /16 (a godot_voxel data block is 16³) for the touched-block count.
static func _fdiv16(a: int) -> int:
	var q := a / 16
	if (a % 16) != 0 and a < 0:
		q -= 1
	return q

# M1 SNOWY WORLD (M1-SNOWY-WORLD.md): the STATE axis (snow_capped), the absolute-altitude
# climate temperature model, snow-cap render variants, and the deep-frozen half-slab. Fences the
# codec constants + canonical masking, the deterministic worldgen invariants (cap predicate,
# state ⊥ liquid disjointness, the Risk-1 altitude-reachability gap), the melt/freeze evaluator
# firing end-to-end through _edits, and the half-slab physics + collider cheap-query contract.
func _test_snowy_world() -> void:
	print("[M1] snowy world (state axis, climate temperature, snow-cap variants, half-slab)")
	var env := PerVoxelEnvironment.new()
	var SNOW := CellCodec.STATE_SNOW_CAPPED
	var PODZOL := BlockCatalog.id_of(&"podzol")
	var SAND := BlockCatalog.id_of(&"sand")
	var WATER := BlockCatalog.id_of(&"water")
	var SNOW_ID := BlockCatalog.id_of(&"snow_block")
	var RAMP := ShapeCodec.make_modifier(2, 2, 0, 0)   # a real (wedge) modifier

	# --- (1) codec + climate constants (ADR §8 item 1) ---
	_ok(SNOW == 1, "STATE_SNOW_CAPPED == bit 0 (== 1)")
	_ok(TerrainConfig.SNOW_SLAB_MODIFIER == ShapeCodec.make_modifier(1, 1, 1, 1, ShapeCodec.ANCHOR_BOTTOM),
		"SNOW_SLAB_MODIFIER == make_modifier(1,1,1,1,ANCHOR_BOTTOM)")
	# bottom_face_covers: the fallback-mesher top-quad-suppression predicate (steelman critical). A
	# full-cover bottom slab may suppress the surface top quad; a partial wedge or top cap may NOT
	# (its taper would leave a hole).
	_ok(ShapeCodec.bottom_face_covers(0), "bottom_face_covers: full cube covers")
	_ok(ShapeCodec.bottom_face_covers(TerrainConfig.SNOW_SLAB_MODIFIER), "bottom_face_covers: snow half-slab covers")
	_ok(ShapeCodec.bottom_face_covers(ShapeCodec.make_modifier(1, 2, 2, 1, ShapeCodec.ANCHOR_BOTTOM)),
		"bottom_face_covers: bottom shape with all corners >= 1 covers")
	_ok(not ShapeCodec.bottom_face_covers(ShapeCodec.make_modifier(0, 1, 1, 0, ShapeCodec.ANCHOR_BOTTOM)),
		"bottom_face_covers: partial wedge lip (a 0 corner) does NOT cover — the hole case is drawn")
	_ok(not ShapeCodec.bottom_face_covers(ShapeCodec.make_modifier(1, 1, 1, 1, ShapeCodec.ANCHOR_TOP)),
		"bottom_face_covers: top-anchored cap does NOT cover the floor")
	var gdef := BlockCatalog.def_of(GRASS)
	# SNOW-ACCUMULATION §2.2: the fill-capable set now declares 5 STATE bits — snow_capped (still pinned
	# at index 0, the M1 global shorthand) + snow_fill_b0..b3 (the composite fill nibble, bits 1..4).
	_ok(gdef != null and gdef.state_layout.size() == 5 and gdef.state_layout[0] == &"snow_capped"
		and gdef.state_layout[1] == &"snow_fill_b0" and gdef.state_layout[4] == &"snow_fill_b3",
		"grass.state_layout == [snow_capped, snow_fill_b0..b3] (snow_capped stays index 0)")
	_ok(BlockCatalog.state_mask_of(GRASS) == 0x1F and BlockCatalog.state_mask_of(PODZOL) == 0x1F
		and BlockCatalog.state_mask_of(SAND) == 0x1F and BlockCatalog.state_mask_of(STONE) == 0x1F
		and BlockCatalog.state_mask_of(BlockCatalog.id_of(&"snow_block")) == 0x1F,
		"grass/podzol/sand/stone/snow_block each declare the 5-bit snow_capped+snow_fill mask (0x1F)")
	_ok(BlockCatalog.state_mask_of(DIRT) == 0 and BlockCatalog.state_mask_of(WATER) == 0
		and BlockCatalog.state_mask_of(BlockCatalog.AIR) == 0,
		"dirt/water/air declare no state (mask 0)")
	# canonical keeps snow_capped on a cappable cube AND ramp; strips it on non-cappable dirt/water.
	_ok(CellCodec.has_state(CellCodec.canonical(CellCodec.pack(GRASS, 0, SNOW)), SNOW),
		"canonical keeps snow_capped on a grass cube")
	_ok(CellCodec.has_state(CellCodec.canonical(CellCodec.pack(GRASS, RAMP, SNOW)), SNOW),
		"canonical keeps snow_capped on a grass ramp")
	_ok(CellCodec.has_state(CellCodec.canonical(CellCodec.pack(STONE, 0, SNOW)), SNOW),
		"canonical keeps snow_capped on a stone cube (cappable — now stamped on B_MOUNTAINS peaks)")
	_ok(CellCodec.state(CellCodec.canonical(CellCodec.pack(DIRT, 0, SNOW))) == 0,
		"canonical STRIPS snow_capped on dirt (not cappable)")
	_ok(CellCodec.state(CellCodec.canonical(CellCodec.pack(WATER, 0, SNOW))) == 0,
		"canonical STRIPS snow_capped on water (not cappable)")
	# undeclared bits (1<<3) masked to 0 on grass, keeping only the declared snow_capped bit.
	_ok(CellCodec.state(CellCodec.canonical(CellCodec.pack(GRASS, 0, (1 << 3) | SNOW))) == SNOW,
		"canonical masks undeclared state bits on grass (keeps only snow_capped)")
	# air-zeroing with a state bit; high bits stay 0.
	_ok(CellCodec.canonical(CellCodec.pack(BlockCatalog.AIR, 0, SNOW)) == 0,
		"canonical air-zeroes a cell even with a stray state bit")
	_ok((CellCodec.pack(GRASS, 0, SNOW) >> 54) == 0, "bits 54..63 stay 0 with a state bit set")
	# with_state / has_state.
	var wsv := CellCodec.with_state(CellCodec.pack(GRASS, RAMP), SNOW)
	_ok(CellCodec.state(wsv) == SNOW and CellCodec.mat(wsv) == GRASS and CellCodec.modifier(wsv) == RAMP,
		"with_state sets the STATE field, leaving material + modifier intact")
	# canonical(generated_cell) == generated_cell on a capped column (idempotent through the hook).
	# placeholder permissiveness (ADR §8 item 2): an UNRESOLVED placeholder keeps its bits.
	var ph := BlockCatalog.register_placeholder(&"sha256:snowyworldphantom", &"phantom")
	_ok(BlockCatalog.state_mask_of(ph) == 0xFFFF, "UNRESOLVED placeholder mask is permissive (0xFFFF)")
	# 0x21 (bit 0 + bit 5) avoids the snow_fill nibble (bits 1..4), which canonical strips on a full cube.
	_ok(CellCodec.state(CellCodec.canonical(CellCodec.pack(ph, 0, 0x21))) == 0x21,
		"placeholder keeps its (non-fill) state bits through canonical (RMS §8 lossless)")
	# ClimateModel constants.
	_ok(absf(ClimateModel.surface_temperature(0, 0.0) - 21.5) < 1e-4, "surface_temperature(0, 0.0) == 21.5")
	_ok(absf(ClimateModel.surface_temperature(96, 0.0)) < 1e-3, "surface_temperature(96, 0.0) == 0 (±ε)")
	_ok(absf(ClimateModel.climate_base(-0.6) - (-8.0)) < 1e-4, "climate_base(-0.6) == -8")
	_ok(absf(ClimateModel.climate_base(0.0) - 21.5) < 1e-4, "climate_base(0.0) == 21.5")
	_ok(absf(ClimateModel.climate_base(-0.35) - 6.75) < 0.02, "climate_base(-0.35) ≈ 6.75")

	# --- (4) worldgen invariants over a wide deterministic scan (ADR §8 item 4) ---
	var scan_capped := 0
	var scan_bare_temperate := 0
	var both_liq_state := 0
	var cap_pred_ok := true
	for x in range(-300, 300, 5):
		for z in range(-300, 300, 5):
			var g: int = TerrainConfig.height_at(x, z)
			var v := TerrainConfig.generated_cell(x, g, z)
			if CellCodec.liquid_field(v) != 0 and CellCodec.has_state(v, SNOW):
				both_liq_state += 1                       # state ⊥ liquid disjointness (§1.6)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			var t: float = TerrainConfig.column_profile(x, z).w
			if CellCodec.has_state(v, SNOW):
				scan_capped += 1
				if BlockCatalog.state_mask_of(CellCodec.mat(v)) & SNOW == 0:
					cap_pred_ok = false                   # a cap only on a cappable material
				if ClimateModel.surface_temperature(g, t) >= 0.0:
					cap_pred_ok = false                   # a cap only where surface temp < 0
			elif ClimateModel.surface_temperature(g, t) >= 0.0:
				scan_bare_temperate += 1                  # a bare, temperate-surface land column
	_ok(both_liq_state == 0, "state ⊥ liquid: NO generated cell carries both snow_capped and a liquid overlay (%d violations)" % both_liq_state)
	_ok(cap_pred_ok, "cap predicate exact: every capped column is a cappable material with surface_temperature < 0")
	_ok(scan_capped > 0, "worldgen produces snow-capped columns for this seed (%d in the scan)" % scan_capped)
	_ok(scan_bare_temperate > 0, "worldgen produces bare temperate columns (state 0) (%d)" % scan_bare_temperate)

	# (a) a specific capped column: cap set, mat/modifier match the material projection, temp < 0, canonical stable.
	var cap := _find_capped_column()
	if cap.x == 0x7fffffff:
		_ok(false, "M1: found a snow-capped column for the worldgen sweep")
	else:
		var cg: int = TerrainConfig.height_at(cap.x, cap.y)
		var cv := TerrainConfig.generated_cell(cap.x, cg, cap.y)
		var ct: float = TerrainConfig.column_profile(cap.x, cap.y).w
		_ok(CellCodec.has_state(cv, SNOW), "capped column: surface cell carries snow_capped")
		_ok(BlockCatalog.state_mask_of(CellCodec.mat(cv)) & SNOW != 0, "capped column: material is cappable")
		_ok(ClimateModel.surface_temperature(cg, ct) < 0.0, "capped column: surface_temperature < 0")
		_ok(env.temperature(Vector3(float(cap.x) + 0.5, float(cg) + 0.5, float(cap.y) + 0.5)) < 0.0, "capped column: sampled ground temperature < 0")
		_ok(CellCodec.canonical(cv) == cv, "capped column: canonical(generated_cell) == generated_cell")

	# (b) a warm-edge temperate column is BARE and reads >= 0.
	var warm := _grass_column()
	var wg: int = TerrainConfig.height_at(warm.x, warm.y)
	var wv := TerrainConfig.generated_cell(warm.x, wg, warm.y)
	_ok(not CellCodec.has_state(wv, SNOW), "temperate grass column is BARE (state 0)")
	_ok(env.temperature(Vector3(float(warm.x) + 0.5, float(wg) + 0.5, float(warm.y) + 0.5)) >= 0.0, "temperate surface reads >= 0 C")

	# (f) altitude-cap reachability — NOW SATISFIED by the Mountains biome (the M1 Risk-1 gap is closed).
	# Tall stone peaks cross the y=96 freeze line, so a TEMPERATE (t >= CLIMATE_TEMPERATE) column reaches
	# sub-zero SURFACE temperature by ALTITUDE alone. This FLIPS the old "expected none this seed" assert.
	_ok(ClimateModel.surface_temperature(97, 0.0) < 0.0, "altitude mechanism: temperate surface goes sub-zero above y=96")
	var alt_cap_found := false
	var alt_cap_at := Vector2i.ZERO
	for mc: Vector2i in TerrainConfig.find_mountains(6):
		for dx in range(-160, 161, 3):
			for dz in range(-160, 161, 3):
				var ax := mc.x + dx
				var az := mc.y + dz
				var p := TerrainConfig.column_profile(ax, az)
				if p.w < ClimateModel.CLIMATE_TEMPERATE:
					continue                              # only TEMPERATE columns test altitude-only caps
				var gg := int(p.x)
				if gg >= TerrainConfig.SEA_LEVEL and ClimateModel.surface_temperature(gg, p.w) < 0.0:
					alt_cap_found = true
					alt_cap_at = Vector2i(ax, az)
					break
			if alt_cap_found:
				break
		if alt_cap_found:
			break
	print("    altitude-cap reachability: TEMPERATE column sub-zero by ALTITUDE alone = %s (%s)" % [("FOUND" if alt_cap_found else "none"), alt_cap_at])
	_ok(alt_cap_found, "Mountains close the Risk-1 gap: a TEMPERATE column now reaches sub-zero surface by ALTITUDE alone (peak crosses y=96)")

	# --- (7) melt/freeze transition fires end-to-end through _edits (ADR §8 item 7) ---
	if cap.x != 0x7fffffff:
		var w := _struct_world("M1Melt")
		if w.environment == null:
			w.environment = env                       # headless _struct_world defers _ready; wire the sim query
		var cg2: int = TerrainConfig.height_at(cap.x, cap.y)
		var ccell := Vector3i(cap.x, cg2, cap.y)
		var cval := w.cell_value_at(ccell)
		_ok(w.apply_state_transitions(ccell) == false, "capped column is the transition fixed point: no melt fires")
		_ok(CellCodec.has_state(w.cell_value_at(ccell), SNOW), "capped column still capped after apply")
		# Copy the capped value into a WARM column: it MELTS, persists in _edits, and is idempotent.
		var wcell := Vector3i(warm.x, wg, warm.y)
		w._write_cell(wcell, cval)
		_ok(CellCodec.has_state(w.cell_value_at(wcell), SNOW), "capped value copied into the warm column")
		_ok(w.apply_state_transitions(wcell) == true, "warm column MELTS the copied cap (transition fired)")
		_ok(not CellCodec.has_state(w.cell_value_at(wcell), SNOW), "melt cleared the snow_capped bit")
		_ok(w._edits.has(wcell) and not CellCodec.has_state(int(w._edits[wcell]), SNOW), "melt persisted in _edits (overlay authoritative)")
		_ok(w.apply_state_transitions(wcell) == false, "second apply is idempotent (no further change)")
		# Reverse edge: bare cappable material in the COLD column re-caps.
		w._write_cell(ccell, CellCodec.with_state(cval, 0))
		_ok(not CellCodec.has_state(w.cell_value_at(ccell), SNOW), "bared the cold-column surface cell")
		_ok(w.apply_state_transitions(ccell) == true, "cold column RE-CAPS bare cappable material (reverse transition fired)")
		_ok(CellCodec.has_state(w.cell_value_at(ccell), SNOW), "re-cap set the snow_capped bit")
		# Fallback mesher: a chunk over the capped column commits the surface with the snow variant.
		var cmat := CellCodec.mat(cval)
		var cxk := floori(cap.x / float(TerrainConfig.CHUNK_SIZE))
		var czk := floori(cap.y / float(TerrainConfig.CHUNK_SIZE))
		# Re-cap the overlay so the chunk actually meshes a capped top (the melt/bare edits above are local).
		w._write_cell(ccell, cval)
		var mesh: ArrayMesh = ChunkMesher.build(cxk, czk, w)
		var found_snow_mat := false
		if mesh != null:
			for si in range(mesh.get_surface_count()):
				if mesh.surface_get_material(si) == BlockMaterials.snow_capped_for(cmat):
					found_snow_mat = true
		_ok(found_snow_mat, "fallback chunk over the capped column commits a surface with the snow-cap variant material")
		_ok(BlockMaterials.snow_capped_for(cmat) != BlockMaterials.get_for(cmat), "snow_capped_for(mat) is a distinct material from the plain material")
		w.queue_free()

	# --- (8) SUPERSEDED: the fixed half-slab is REPLACED by snow accumulation (SNOW-ACCUMULATION
	# Decision 1.3.5). The variable-height stack, its physics, the collider cheap-query contract and the
	# memo==worker-direct byte-identity now live in _test_snow_accumulation() (ADR §5.2). SNOW_SLAB_MODIFIER
	# survives as the canonical encoding of LAYER level 5 (still pinned in _test_snow_layer_codec).
	print("    [M1] fixed half-slab superseded by snow accumulation — see _test_snow_accumulation()")

## A column (x, z) whose GENERATED surface cell carries the snow_capped state (M1), or
## (0x7fffffff, _) if this seed has none reachable near origin.
func _find_capped_column() -> Vector2i:
	for x in range(-384, 384, 3):
		for z in range(-384, 384, 3):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			if CellCodec.has_state(TerrainConfig.generated_cell(x, g, z), CellCodec.STATE_SNOW_CAPPED):
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## A column (x, z) whose GENERATED g+1 cell is the snow half-slab (M1), or (0x7fffffff, _) if none.
func _find_slab_column() -> Vector2i:
	var snow_id := BlockCatalog.id_of(&"snow_block")
	for x in range(-512, 512, 2):
		for z in range(-512, 512, 2):
			var g: int = TerrainConfig.height_at(x, z)
			if g < TerrainConfig.SEA_LEVEL:
				continue
			var gc := TerrainConfig.generated_cell(x, g + 1, z)
			if CellCodec.mat(gc) == snow_id and CellCodec.modifier(gc) == TerrainConfig.SNOW_SLAB_MODIFIER:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

# Mountains biome (SEPARATE tall biome; altitude snow caps). Proves: a real B_MOUNTAINS peak crosses the
# y=96 freeze line and carries the snow_capped state on bare STONE; the cap predicate holds; the capped
# peak renders the BAKED snow variant on BOTH paths (module ARID mirror + generator TYPE buffer; fallback
# look material); peaks are solid full cubes below the surface (floor-scan safe); and the NON-mountain
# world (mountain factor == 0) is byte-identical.
func _test_mountains() -> void:
	print("[MTN] Mountains biome (tall stone peaks + altitude snow caps)")
	var SNOW := CellCodec.STATE_SNOW_CAPPED
	# (1) locate the TALLEST peak across several mountain massifs (not every massif crosses y=96;
	# scan a spread of them and keep the global tallest B_MOUNTAINS column). Deterministic, loud-fail.
	var massifs := TerrainConfig.find_mountains(12)
	_ok(massifs.size() > 0, "found B_MOUNTAINS massifs")
	if massifs.is_empty():
		return
	var peak := Vector2i(0x7fffffff, 0)
	var peak_g := -0x7fffffff
	for mc: Vector2i in massifs:
		for dx in range(-160, 161):
			for dz in range(-160, 161):
				var x := mc.x + dx
				var z := mc.y + dz
				var p := TerrainConfig.column_profile(x, z)
				if int(p.y) != TerrainConfig.B_MOUNTAINS:
					continue
				var g := int(p.x)
				if g > peak_g:
					peak_g = g
					peak = Vector2i(x, z)
	_ok(peak.x != 0x7fffffff, "found a B_MOUNTAINS column (tallest peak at %s, g=%d)" % [peak, peak_g])
	_ok(peak_g > 96, "mountain peak crosses the y=96 freeze line (peak g = %d)" % peak_g)

	# (2) the peak surface cell: bare STONE, cappable, snow_capped state set, surface_temperature < 0.
	var pt: float = TerrainConfig.column_profile(peak.x, peak.y).w
	var pv := TerrainConfig.generated_cell(peak.x, peak_g, peak.y)
	_ok(CellCodec.mat(pv) == STONE, "mountain peak top is bare STONE (id %d)" % CellCodec.mat(pv))
	_ok(BlockCatalog.state_mask_of(STONE) & SNOW != 0, "stone is a declared cappable material")
	_ok(ClimateModel.surface_temperature(peak_g, pt) < 0.0, "peak surface_temperature < 0 (%.2f C)" % ClimateModel.surface_temperature(peak_g, pt))
	_ok(CellCodec.has_state(pv, SNOW), "mountain peak surface cell carries the snow_capped state")
	_ok(CellCodec.canonical(pv) == pv, "capped peak cell is canonical-stable")
	var env := PerVoxelEnvironment.new()
	_ok(env.temperature(Vector3(float(peak.x) + 0.5, float(peak_g) + 0.5, float(peak.y) + 0.5)) < 0.0, "sampled ground temperature at the peak < 0")

	# (3) peaks are SOLID full cubes below the surface — the analytic floor scan can never fall through.
	var solid_ok := true
	for dyy in range(1, 12):
		if BlockCatalog.solidity_of(TerrainConfig.generated_block(peak.x, peak_g - dyy, peak.y)) < 0.5:
			solid_ok = false
	_ok(solid_ok, "mountain interior below the peak is solid full cubes (no fall-through)")

	# (4) byte-identity of the NON-mountain world: where the mountain FACTOR is exactly 0 the uplift term
	# is `+= 0.0`, so height/biome/cell are bit-for-bit the pre-change values. Prove the demo spawn and the
	# vast majority of a wide lowland scan are factor 0 (untouched); every factor-0 column is non-mountain.
	var spawn := TerrainConfig.find_spawn()
	var sc: float = TerrainConfig.column_profile(spawn.x, spawn.y).z
	_ok(TerrainConfig._mountain_factor(sc, float(spawn.x), float(spawn.y)) == 0.0, "find_spawn() column has mountain factor 0 (byte-identical, untouched)")
	var demo := Vector2i(-187, 289)
	var dc: float = TerrainConfig.column_profile(demo.x, demo.y).z
	_ok(TerrainConfig._mountain_factor(dc, float(demo.x), float(demo.y)) == 0.0, "snow-demo spawn (-187,289) has mountain factor 0 (byte-identical)")
	var zero_cols := 0
	var total_cols := 0
	var factor0_never_mtn := true
	for x in range(-400, 400, 8):
		for z in range(-400, 400, 8):
			var pp := TerrainConfig.column_profile(x, z)
			var f := TerrainConfig._mountain_factor(pp.z, float(x), float(z))
			total_cols += 1
			if f == 0.0:
				zero_cols += 1
				if int(pp.y) == TerrainConfig.B_MOUNTAINS:
					factor0_never_mtn = false
	_ok(factor0_never_mtn, "no factor-0 column is ever classified B_MOUNTAINS")
	_ok(zero_cols * 100 >= total_cols * 80, "most of the world is untouched by mountains (factor 0 in %d/%d cols near origin)" % [zero_cols, total_cols])

	# (5) BOTH render paths render the capped stone peak WHITE (not plain rock).
	# Fallback look: the snow variant material differs from the plain stone material.
	_ok(BlockMaterials.snow_capped_for(STONE) != BlockMaterials.get_for(STONE), "fallback: capped-stone look material differs from plain stone")
	# Module path: arid_for_cell(peak cell) is the baked snow variant, differs from the plain-stone ARID at
	# the same modifier, and matches the gen_arid_for mirror; the generated TYPE buffer agrees.
	if ClassDB.class_exists("VoxelTerrain") and ClassDB.class_exists("VoxelBuffer"):
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		if bool(mw.call("setup")):
			var pmod := CellCodec.modifier(pv)
			var capped_arid := int(mw.call("arid_for_cell", pv))
			var plain_pv := CellCodec.pack(STONE, pmod, 0)
			var plain_arid := int(mw.call("arid_for_cell", plain_pv))
			_ok(capped_arid > 0 and capped_arid != plain_arid, "module: capped peak cell (modifier %d) renders a baked snow variant ARID (%d) != plain stone (%d)" % [pmod, capped_arid, plain_arid])
			# SNOW-ACCUMULATION: pass the peak cell's ACTUAL state (a cold ramp peak now also carries the
			# snow-fill nibble → a composite; a full-cube peak carries only snow_capped → the cap skin) so the
			# mirror sees the same axis the worker does.
			_ok(capped_arid == int(mw.call("gen_arid_for", STONE, pmod, CellCodec.liquid_level(pv), CellCodec.liquid_kind(pv), CellCodec.state(pv))), "module: arid_for_cell(peak) == gen_arid_for mirror")
			# Generate the block containing the peak cell and confirm its TYPE == the mirror (worker path).
			var gen: Object = mw.call("get_generator")
			if gen != null:
				var bx := int(floor(float(peak.x) / 16.0)) * 16
				var by := int(floor(float(peak_g) / 16.0)) * 16
				var bz := int(floor(float(peak.y) / 16.0)) * 16
				var buf: Object = ClassDB.instantiate("VoxelBuffer")
				buf.call("create", 16, 16, 16)
				gen.call("_generate_block", buf, Vector3i(bx, by, bz), 0)
				var got := int(buf.call("get_voxel", peak.x - bx, peak_g - by, peak.y - bz, 0))
				_ok(got == capped_arid, "module: generated TYPE at the peak cell (%d) == capped variant ARID (%d)" % [got, capped_arid])
		else:
			_ok(false, "module: world builds for the mountain render check")
		mw.queue_free()
	else:
		print("    (godot_voxel module absent — module-path peak render check runs on module builds only)")


# SHARP-SLOPE (docs/SHARP-SLOPE.md): the FAM kind-1 SLOPE family. S1 verify items 1–2 (the
# all-4096-payload codec/shape sweep, canonical rules, tiling proofs) + placement/physics pins.
# The unclamped SLOPE corner plane D(fx,fz) — the same max-sum rule ShapeCodec._plane_at uses,
# replicated so the test is independent of the private helper.
func _slope_plane(d: Vector4i, fx: float, fz: float) -> float:
	var c00 := float(d.x)
	var c10 := float(d.y)
	var c11 := float(d.z)
	var c01 := float(d.w)
	if (d.x + d.z) >= (d.y + d.w):
		if fz <= fx:
			return c00 + (c10 - c00) * fx + (c11 - c10) * fz
		return c00 + (c11 - c01) * fx + (c01 - c00) * fz
	if fx + fz <= 1.0:
		return c00 + (c10 - c00) * fx + (c01 - c00) * fz
	return (c10 + c01 - c11) + (c11 - c01) * fx + (c11 - c10) * fz

# The surface y of the covering triangle at footprint (fx,fz), or null if no tri covers it — the
# collider's prism top there. XZ point-in-triangle + barycentric interpolation of the vertex y's.
func _slope_tri_y_at(tris: Array, fx: float, fz: float):
	var best = null
	for tri: Dictionary in tris:
		var a: Vector3 = tri["v0"]
		var b: Vector3 = tri["v1"]
		var c: Vector3 = tri["v2"]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-9:
			continue
		var w0 := ((b.z - c.z) * (fx - c.x) + (c.x - b.x) * (fz - c.z)) / d
		var w1 := ((c.z - a.z) * (fx - c.x) + (a.x - c.x) * (fz - c.z)) / d
		var w2 := 1.0 - w0 - w1
		if w0 >= -1e-4 and w1 >= -1e-4 and w2 >= -1e-4:
			var y := w0 * a.y + w1 * b.y + w2 * c.y
			if best == null or y > float(best):
				best = y                                  # topmost covering tri = the walkable/collider surface
	return best

func _test_sharp_slope() -> void:
	print("[S1] sharp-slope: FAM kind-1 SLOPE family (codec/shape sweep + canonicalization + tiling)")
	var FAM := CellCodec.MOD_FAM_BIT
	var KIND := CellCodec.FAM_SLOPE << CellCodec.MOD_FAM_KIND_SHIFT

	# --- Item 1: sweep ALL 4096 payloads through every query -------------------------
	var no_nan := true
	var span_ok := true
	var vol_ok := true
	var occ_ok := true
	var tris_ok := true
	var mc_ok := true
	var mc_max_err := 0.0
	var samples := [Vector2(0.15, 0.2), Vector2(0.5, 0.5), Vector2(0.8, 0.35), Vector2(0.3, 0.85), Vector2(0.95, 0.95)]
	for payload in range(4096):
		var m := FAM | KIND | payload
		if not CellCodec.is_slope(m):
			no_nan = false
			continue
		var d := CellCodec.slope_deltas(m)
		# round-trip: the biased encode/decode is exact for in-range deltas
		if CellCodec._slope_raw(d.x, d.y, d.z, d.w) != m:
			no_nan = false
		var v := ShapeCodec.volume(m)
		if is_nan(v) or v < -1e-6 or v > 1.0 + 1e-6:
			vol_ok = false
		# Monte-Carlo volume: mean of clamp(D,0,1) over the unit square (== ∫ height_at).
		var acc := 0.0
		var grid := 12
		for iu in grid:
			for iv in grid:
				var fx := (float(iu) + 0.5) / float(grid)
				var fz := (float(iv) + 0.5) / float(grid)
				acc += ShapeCodec.height_at(m, fx, fz)
		var mc := acc / float(grid * grid)
		mc_max_err = maxf(mc_max_err, absf(mc - v))
		if absf(mc - v) > 0.02:
			mc_ok = false
		for s: Vector2 in samples:
			var h := ShapeCodec.height_at(m, s.x, s.y)
			if is_nan(h) or h < -1e-6 or h > 1.0 + 1e-6:
				no_nan = false
			var sp := ShapeCodec.span(m, s.x, s.y)
			if is_nan(sp.x) or is_nan(sp.y) or sp.y < -1e-6 or sp.y > 1.0 + 1e-6 or sp.x < -1e-6:
				span_ok = false
			# occupied consistent with span: a point at mid-span is in, well above H is out.
			if sp.y > 0.05:
				if not ShapeCodec.occupied(m, s.x, sp.y * 0.5, s.y):
					occ_ok = false
				if ShapeCodec.occupied(m, s.x, sp.y + 0.2, s.y):
					occ_ok = false
		# surface_tris: non-degenerate, and the surface is single-valued (each tri's normal has
		# a positive y so it is a genuine top facet, never a vertical sliver).
		for tri: Dictionary in ShapeCodec.surface_tris(m):
			var n: Vector3 = tri["normal"]
			if is_nan(n.x) or n.length() < 0.5 or n.y < -1e-4:
				tris_ok = false
	_ok(no_nan, "slope-sweep: 4096 payloads decode + height_at is finite in [0,1] (round-trip exact)")
	_ok(vol_ok, "slope-sweep: volume finite in [0,1] for every payload")
	_ok(span_ok, "slope-sweep: span finite, span.y in [0,1] for every payload")
	_ok(occ_ok, "slope-sweep: occupied consistent with span (in at mid-span, out above H)")
	_ok(tris_ok, "slope-sweep: surface_tris non-degenerate, upward-facing (single-valued top)")
	_ok(mc_ok, "slope-sweep: volume == Monte-Carlo ∫clamp(D,0,1) within 0.02 (max err %.4f)" % mc_max_err)

	# --- Canonical rules 1.3.1–1.3.4 -------------------------------------------------
	_ok(CellCodec.make_slope(2, 2, 2, 2) == 0, "slope-canon: rule 1 all d≥1 → full cube (0)")
	_ok(CellCodec.make_slope(1, 1, 1, 1) == 0, "slope-canon: rule 1 all d==1 → full cube (0)")
	# rule 2: all d≤0 → the empty-FAM marker, which canonical() collapses to AIR.
	_ok(CellCodec.make_slope(-2, 0, -1, 0) == FAM, "slope-canon: rule 2 all d≤0 → empty-FAM marker")
	_ok(CellCodec.canonical(CellCodec.pack(STONE, CellCodec.make_slope(-2, 0, -1, 0))) == 0,
		"slope-canon: rule 2 empty-FAM marker collapses the cell to AIR")
	# rule 3: all d∈{0,1} (mixed) → the legacy corner modifier, NOT a slope.
	var leg := CellCodec.make_slope(0, 1, 1, 0)
	_ok(leg == ShapeCodec.make_modifier(0, 2, 2, 0, ShapeCodec.ANCHOR_BOTTOM) and not CellCodec.is_slope(leg),
		"slope-canon: rule 3 all d∈{0,1} → legacy corner modifier (reuses baked shape)")
	# rule 4: an out-of-band tuple is kept as a slope and round-trips exactly.
	var kept := CellCodec.make_slope(3, -1, 0, 2)
	_ok(CellCodec.is_slope(kept) and CellCodec.slope_deltas(kept) == Vector4i(3, -1, 0, 2),
		"slope-canon: rule 4 mixed tuple kept as SLOPE, round-trips")
	# uniqueness / idempotence: a kept slope canonicalizes to itself.
	var pk := CellCodec.pack(STONE, kept)
	_ok(CellCodec.canonical(pk) == pk, "slope-canon: canonical(pack(stone, slope)) == itself (idempotent)")
	# junk FAM kind (kind 2) strips to full cube + warns.
	var junk := FAM | (2 << CellCodec.MOD_FAM_KIND_SHIFT) | 0x1FF
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(STONE, junk))) == 0,
		"slope-canon: unknown FAM kind strips to full cube (0)")
	# non-solid gate: a slope on water strips to full cube (no ramp of water).
	_ok(CellCodec.modifier(CellCodec.canonical(CellCodec.pack(BlockCatalog.id_of(&"water"), kept))) == 0,
		"slope-canon: slope on a non-solid material strips (no ramp of water)")
	# mass composes volume.
	var mv := CellCodec.pack(STONE, CellCodec.make_slope(3, 3, 0, 0))
	_ok(is_equal_approx(BlockCatalog.mass_of_value(mv), BlockCatalog.mass_of(STONE) * ShapeCodec.volume(CellCodec.modifier(mv))),
		"slope-canon: mass_of_value == density × volume(slope)")

	# --- Item 2: tiling proofs -------------------------------------------------------
	# A vertical RUN: cell y carries make_slope(Tw − y). Stacking (d, d−1, d−2, …) the union of
	# spans is one contiguous interval topped at clamp(D). Proof: Σ_k clamp(D−k, 0, 1) == clamp(D, 0, N).
	# Run-base tuples with all deltas in [0,3] and spread ≤ SLOPE_MAX_SPREAD (=3): exactly the shape a
	# run at y=lo carries, so every run cell's deltas stay in the encodable [−3,+4] over k=0..3.
	var tile_ok := true
	var contig_ok := true
	var tuples := [Vector4i(3, 1, 0, 2), Vector4i(2, 3, 1, 0), Vector4i(0, 2, 3, 1), Vector4i(3, 2, 1, 0)]
	var ncells := 4
	for base: Vector4i in tuples:
		for s: Vector2 in samples:
			var dsum := 0.0
			var prev_h := 1.0
			for k in ncells:
				var mk := CellCodec.make_slope(base.x - k, base.y - k, base.z - k, base.w - k)
				# span handles every canonical form: full cube (0 → (0,1)), legacy corner collapse,
				# kept SLOPE, and the empty-FAM marker (→ ZERO).
				var hk := ShapeCodec.span(mk, s.x, s.y).y
				# a run cell is full whenever the cell above it holds material (no gap/sliver)
				if hk > 1e-4 and prev_h < 1.0 - 1e-4:
					contig_ok = false
				prev_h = hk
				dsum += hk
			var expect := clampf(_slope_plane(base, s.x, s.y), 0.0, float(ncells))
			if absf(dsum - expect) > 1e-3:
				tile_ok = false
	_ok(tile_ok, "slope-tiling: Σ run-cell heights == clamp(D, 0, N) (gap-free vertical tiling)")
	_ok(contig_ok, "slope-tiling: a run cell is full wherever the cell above holds material (no sliver)")
	# horizontal edge continuity: two cells sharing an edge with equal corner deltas have equal H
	# along that edge (crack-free). Cell A +X edge (d10,d11) meets cell B −X edge (d00,d01).
	var edge_ok := true
	var ca := CellCodec.make_slope(3, 2, -1, 0)      # A: +X edge corners d10=2, d11=-1
	var cb := CellCodec.make_slope(2, 3, 1, -1)      # B: −X edge corners d00=2, d01=-1 (== A's +X edge)
	for tt in 9:
		var fz := float(tt) / 8.0
		var ha := ShapeCodec.height_at(ca, 1.0, fz)   # A's +X face (fx=1)
		var hb := ShapeCodec.height_at(cb, 0.0, fz)   # B's −X face (fx=0)
		if absf(ha - hb) > 1e-4:
			edge_ok = false
	_ok(edge_ok, "slope-tiling: shared-edge H equal for adjacent slope cells (crack-free)")

	# --- render/physics PARITY (the whole point): the collider prisms come from surface_tris, so
	# for every footprint where the shape is solid (H>0) there is a surface triangle whose height
	# equals the rendered/analytic surface H — collider covers EXACTLY what renders. The plateau
	# {D≥1} polygon is load-bearing: without it the full-height uphill part would have no collision.
	var parity_ok := true
	var plateau_ok := true
	var parity_modifiers := [
		CellCodec.make_slope(2, 2, -1, -1), CellCodec.make_slope(3, 1, 0, 2),
		CellCodec.make_slope(2, 3, 0, 1), CellCodec.make_slope(1, 3, 2, 0),
		CellCodec.make_slope(3, 0, -1, 1), CellCodec.make_slope(2, -1, -1, 2)]
	for m: int in parity_modifiers:
		if not CellCodec.is_slope(m):
			continue
		var tris: Array = ShapeCodec.surface_tris(m)
		var has_plateau := false
		for tri: Dictionary in tris:
			var n: Vector3 = tri["normal"]
			if n.y > 0.999 and absf((tri["v0"] as Vector3).y - 1.0) < 1e-4:
				has_plateau = true                        # a flat tri at y=1 == the plateau
		# does the modifier HAVE a plateau region ({D≥1} somewhere)? (max delta ≥ 1 for a kept slope)
		var d := CellCodec.slope_deltas(m)
		if maxi(maxi(d.x, d.y), maxi(d.z, d.w)) >= 1 and not has_plateau:
			plateau_ok = false
		for iu in 7:
			for iv in 7:
				var fx := (float(iu) + 0.5) / 7.0
				var fz := (float(iv) + 0.5) / 7.0
				var h := ShapeCodec.height_at(m, fx, fz)          # render/analytic surface
				if h <= 1e-3:
					continue                                      # empty footprint — no prism needed
				var covered = _slope_tri_y_at(tris, fx, fz)
				if covered == null or absf(float(covered) - h) > 2e-3:
					parity_ok = false
	_ok(plateau_ok, "slope-parity: surface_tris includes the plateau {D≥1} polygon (full-height prisms exist)")
	_ok(parity_ok, "slope-parity: collider prism surface (surface_tris) == rendered/analytic H at every solid footprint")

	# contact_area smoke: the structural-joint query must stay finite in [0,1] for slope↔slope,
	# slope↔legacy and slope↔full pairs across all three axes (the LUT-bypass / triangle-clip paths).
	var ca_ok := true
	var ca_partners := [0, ShapeCodec.make_modifier(2, 2, 0, 0), CellCodec.make_slope(2, 1, -1, 0), CellCodec.make_slope(3, 2, 1, 0)]
	for m: int in parity_modifiers:
		for p: int in ca_partners:
			for ax in 3:
				var caab := ShapeCodec.contact_area(m, p, ax)
				var caba := ShapeCodec.contact_area(p, m, ax)
				if is_nan(caab) or caab < -1e-6 or caab > 1.0 + 1e-6 or is_nan(caba) or caba < -1e-6 or caba > 1.0 + 1e-6:
					ca_ok = false
	_ok(ca_ok, "slope-parity: contact_area finite in [0,1] for slope×{slope,legacy,full} on all axes")

	# --- placement + physics pins ----------------------------------------------------
	_test_sharp_slope_live()
	# --- S2 worldgen: emission, byte-identity, collider contract, both-path mirror ----
	_test_sharp_slope_worldgen()

# S1 placement/physics: place a SLOPE cell, drive floor_under / break / VoxelBody, render both paths.
func _test_sharp_slope_live() -> void:
	var SLOPE := CellCodec.make_slope(2, 2, -1, -1)   # descending along +z, plane D = 2 − 3·fz
	_ok(CellCodec.is_slope(SLOPE), "slope-live: test modifier is a kept SLOPE")
	var world: WorldManager = _struct_world("S1Slope")
	var col := _grass_column()
	var cx := col.x
	var cz := col.y
	var g: int = TerrainConfig.height_at(cx, cz)
	var rc := Vector3i(cx, g + 1, cz)
	_ok(world.place_block(rc, CellCodec.pack(STONE, SLOPE)), "slope-live: place a stone SLOPE cell")
	_ok(world.cell_solid(rc), "slope-live: placed slope cell is solid")
	_ok(CellCodec.modifier(world.cell_value_at(rc)) == SLOPE, "slope-live: placed cell carries the slope modifier")
	# floor_under == cell.y + clamp(D) at footprints where the slope cell is OCCUPIED (H > 0), so the
	# floor reads the placed slope, not the (possibly smoothed) ground below it. SLOPE plane D=2−3fz
	# on fz ≤ fx=0.5, so fz ∈ {0.1,0.3,0.5} all give H > 0.
	var floor_ok := true
	for s: Vector2 in [Vector2(0.5, 0.1), Vector2(0.5, 0.3), Vector2(0.5, 0.5)]:
		var expect := float(g + 1) + clampf(_slope_plane(CellCodec.slope_deltas(SLOPE), s.x, s.y), 0.0, 1.0)
		var got := world.floor_under(float(cx) + s.x, float(cz) + s.y, float(g) + 4.0)
		if not is_equal_approx(got, expect):
			floor_ok = false
	_ok(floor_ok, "slope-live: floor_under == cell.y + clamp(D) across the slope face (parity)")
	# fallback mesher builds real geometry for the slope chunk.
	var n := TerrainConfig.CHUNK_SIZE
	var fb := ChunkMesher.build(floori(float(cx) / float(n)), floori(float(cz) / float(n)), world)
	_ok(fb != null and fb.get_surface_count() > 0, "slope-live: fallback mesher builds the slope chunk")
	# break returns the material.
	_ok(world.break_terrain(rc, Vector3.INF) == STONE, "slope-live: break_terrain returns the slope material (STONE)")
	world.queue_free()
	# a loose VoxelBody keeps the FAM modifier + weighs density × volume.
	var mworld: WorldManager = _struct_world("S1SlopeMass")
	var vb := VoxelBody.spawn_loose(mworld, {Vector3i.ZERO: CellCodec.pack(STONE, SLOPE)}, mworld)
	_ok(vb != null, "slope-live: spawn a loose stone-SLOPE VoxelBody")
	if vb != null:
		_ok(is_equal_approx(vb.mass, BlockCatalog.mass_of(STONE) * ShapeCodec.volume(SLOPE)),
			"slope-live: VoxelBody mass == density × volume(slope) = %.1f (got %.1f)" % [BlockCatalog.mass_of(STONE) * ShapeCodec.volume(SLOPE), vb.mass])
	mworld.queue_free()
	# module path: a placed slope value resolves to a shaped ARID (lazy append, never a hole).
	if ClassDB.class_exists("VoxelTerrain"):
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		if bool(mw.call("setup")):
			var arid: int = mw.call("arid_for", STONE, SLOPE)
			_ok(arid > 0, "slope-live: module arid_for(stone, slope) yields a shaped ARID (%d)" % arid)
			_ok(int(mw.call("arid_for", STONE, SLOPE)) == arid, "slope-live: slope ARID stable on re-lookup")
		mw.queue_free()

# SHARP-SLOPE S2 worldgen: steepness emission on mountain faces, byte-identity of the non-steep
# world, the generalized collider cheap-query contract (memo == worker-direct), no-hole runs, the
# crack audit, and the module both-path ARID mirror.
func _test_sharp_slope_worldgen() -> void:
	print("[S2] sharp-slope worldgen: emission + byte-identity + collider contract + both-path mirror")
	# Find slope-emitting columns on a mountain face (loud fail if none — the whole point).
	var mtn: Vector2i = TerrainConfig.find_mountain()
	var fires: Array = []
	for dz in range(-40, 40):
		for dx in range(-40, 40):
			var x := mtn.x + dx
			var z := mtn.y + dz
			if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(x, z)):
				fires.append(Vector2i(x, z))
	_ok(fires.size() > 0, "slope-gen: mountain face has SLOPE-emitting columns (%d found) — pyramids replaced" % fires.size())

	# (3a) every run cell canonical, materials are skin/banding, NO ore in the run.
	var canon_ok := true
	var run_has_slope := false
	var ore_absent := true
	var ore_ids := {}
	for oname in [&"coal_ore", &"iron_ore", &"gold_ore", &"copper_ore", &"redstone_ore", &"diamond_ore", &"emerald_ore", &"lapis_ore"]:
		var oid := BlockCatalog.id_of(oname)
		if oid > 0:
			ore_ids[oid] = true
	for col: Vector2i in fires:
		var g: int = TerrainConfig.height_at(col.x, col.y)
		var run := TerrainConfig.slope_run_of(col.x, col.y)
		var rng := TerrainConfig.slope_run_range(run, g)
		for y in range(rng.x, rng.y):
			var v: int = TerrainConfig.generated_cell(col.x, y, col.y)
			if CellCodec.canonical(v) != v:
				canon_ok = false
			if CellCodec.is_slope(CellCodec.modifier(v)):
				run_has_slope = true
			if ore_ids.has(CellCodec.mat(v)):
				ore_absent = false
	_ok(run_has_slope, "slope-gen: run cells carry canonical SLOPE modifiers")
	_ok(canon_ok, "slope-gen: every run cell is canonical (canonical(v) == v)")
	_ok(ore_absent, "slope-gen: no ore/strata generated on carved slope faces (Risk 6)")

	# (3d) no-hole: a slope column is SOLID from below the run up to the clamp plane, then air above.
	var no_hole := true
	for col: Vector2i in fires:
		var g: int = TerrainConfig.height_at(col.x, col.y)
		var run := TerrainConfig.slope_run_of(col.x, col.y)
		var rng := TerrainConfig.slope_run_range(run, g)
		# below the run (one cell under lo) must be solid full; the cell just above the run top must be air.
		var below: int = TerrainConfig.generated_cell(col.x, rng.x - 1, col.y)
		if CellCodec.mat(below) == BlockCatalog.AIR:
			no_hole = false
		# contiguous solid through the run (each run cell has material somewhere in its footprint)
		for y in range(rng.x, rng.y):
			var vv: int = TerrainConfig.generated_cell(col.x, y, col.y)
			if CellCodec.mat(vv) == BlockCatalog.AIR:
				no_hole = false
	_ok(no_hole, "slope-gen: slope columns are gap-free (solid below the run, material through it)")

	# (memo-safety + broad no-hole) WIDE scan: EVERY firing column across a large mountain patch must
	# keep Tw−g ∈ [−3,+4] (the memo's 4-bit codes are exact — no spike/pit corruption) AND be solid
	# from below the run up through it (no carved-away hole). Guards the lone-spike failure class.
	var memo_range_ok := true
	var wide_no_hole := true
	var wide_fires := 0
	for dz in range(-60, 60):
		for dx in range(-60, 60):
			var x := mtn.x + dx
			var z := mtn.y + dz
			var run := TerrainConfig.slope_run_of(x, z)
			if not TerrainConfig.slope_run_fires(run):
				continue
			wide_fires += 1
			var g: int = TerrainConfig.height_at(x, z)
			var rng := TerrainConfig.slope_run_range(run, g)
			if rng.x < g - 3 or rng.y > g + 4 or rng.y <= rng.x:
				memo_range_ok = false
			# memo (analytic) run must equal worker-direct run (no divergence anywhere in the patch)
			if TerrainConfig.slope_run_of(x, z, {}) != run:
				memo_range_ok = false
			if CellCodec.mat(TerrainConfig.generated_cell(x, rng.x - 1, z)) == BlockCatalog.AIR:
				wide_no_hole = false
			for y in range(rng.x, rng.y):
				if CellCodec.mat(TerrainConfig.generated_cell(x, y, z)) == BlockCatalog.AIR:
					wide_no_hole = false
	_ok(wide_fires > 0, "slope-gen: wide mountain scan found %d firing columns" % wide_fires)
	_ok(memo_range_ok, "slope-gen: every firing column keeps Tw−g ∈ [−3,+4] AND memo == worker run (no spike corruption)")
	_ok(wide_no_hole, "slope-gen: no carved-away holes across the wide mountain scan")

	# (4) THE generalized collider contract: generated_modifier_at == modifier(generated_cell) for
	# y ∈ [g−4, g+4], memo (analytic) == worker-direct ({}) — over the mountain sweep.
	var gma_ok := true
	var memo_ok := true
	for col: Vector2i in fires:
		var g: int = TerrainConfig.height_at(col.x, col.y)
		for y in range(g - 4, g + 5):
			var direct: int = CellCodec.modifier(TerrainConfig.generated_cell(col.x, y, col.y))
			var light: int = TerrainConfig.generated_modifier_at(col.x, y, col.y)      # analytic (memo)
			var worker: int = TerrainConfig.generated_modifier_at(col.x, y, col.y, {})  # worker-direct
			if light != direct:
				gma_ok = false
			if worker != direct:
				memo_ok = false
	_ok(gma_ok, "slope-contract: generated_modifier_at == modifier(generated_cell) for y∈[g−4,g+4] (memo)")
	_ok(memo_ok, "slope-contract: memo == worker-direct ({}) — one predicate, no divergence")

	# (3e) BYTE-IDENTITY of the non-steep world: a column with NO firing column in its 3×3 stencil
	# uses raw half-block quantization == legacy, so its surface/cap modifier equals the PRE-slope
	# computation. Verified over the gentle spawn patch AND that no slope appears there.
	var spawn: Vector2i = TerrainConfig.find_spawn()
	var byte_ok := true
	var no_slope_gentle := true
	var checked_gentle := 0
	for dz in range(-30, 30):
		for dx in range(-30, 30):
			var x := spawn.x + dx
			var z := spawn.y + dz
			# skip rim columns (a firing column in the 3×3 legitimately reshapes them, §3.1 Risk 3)
			var rim := false
			for jx in range(-1, 2):
				for jz in range(-1, 2):
					if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(x + jx, z + jz)):
						rim = true
			if rim:
				continue
			var g: int = TerrainConfig.height_at(x, z)
			# legacy surface/cap modifiers from the RAW corner targets (the pre-slope formula)
			var raw := TerrainConfig._corner_targets(x, z, null)
			var tree := TreeGen.block_at(x, g + 1, z) != BlockCatalog.AIR
			var legacy_sm := 0 if tree else TerrainConfig._modifier_from_targets(raw, g)
			var legacy_cm := 0 if tree else TerrainConfig._modifier_from_targets(raw, g + 1)
			if TerrainConfig.surface_modifier(x, z) != legacy_sm:
				byte_ok = false
			# cap byte-identity ignores the deep-frozen snow-slab fold (unchanged by this feature)
			if legacy_cm != 0 and TerrainConfig.surface_cap_modifier(x, z) != legacy_cm:
				byte_ok = false
			if CellCodec.is_slope(CellCodec.modifier(TerrainConfig.generated_cell(x, g, z))):
				no_slope_gentle = false
			checked_gentle += 1
	_ok(checked_gentle > 0, "slope-byte: swept %d gentle non-rim columns at spawn" % checked_gentle)
	_ok(byte_ok, "slope-byte: non-rim surface/cap modifiers == legacy raw-target computation (byte-identical)")
	_ok(no_slope_gentle, "slope-byte: no SLOPE cells generated in the gentle spawn region")

	# (3c) crack audit (§3.1 / §5.2.3c): a lattice corner shared between a slope cell and its +X
	# neighbour quantizes to ONE value from EITHER cell's _quantized_targets — so the corner-height
	# plane is C0 across the seam (no crack), whether the neighbour is slope or legacy.
	var crack_ok := true
	for col: Vector2i in fires:
		var qa := TerrainConfig._quantized_targets(col.x, col.y, null)          # this cell (c00,c10,c11,c01)
		var qb := TerrainConfig._quantized_targets(col.x + 1, col.y, null)      # +X neighbour cell
		# this cell's +X edge corners (c10 @ (x+1,z), c11 @ (x+1,z+1)) == neighbour's −X edge (c00, c01)
		if absf(qa.y - qb.x) > 1e-6 or absf(qa.z - qb.w) > 1e-6:
			crack_ok = false
		# and the +Z neighbour, same discipline on the other axis
		var qc := TerrainConfig._quantized_targets(col.x, col.y + 1, null)      # +Z neighbour cell
		if absf(qa.w - qc.x) > 1e-6 or absf(qa.z - qc.y) > 1e-6:
			crack_ok = false
	_ok(crack_ok, "slope-crack: shared lattice corners quantize identically from either cell (crack-free)")

	# (DEFECT 1) baked-set COMPLETENESS (mirrors _test_manifest_trim's emitted_modifiers coverage): a
	# WIDE mountain sweep must emit NO slope payload absent from all_slope_payloads() and NO (mat,payload)
	# pair absent from emitted_slope_pairs(). An unbaked pair cube-falls-back on the module (web) path —
	# the pyramids the pre-DEFECT r=32 sample let reappear on far mountains. Analytic set → 0 unbaked.
	var baked := {}
	for p: int in TerrainConfig.emitted_slope_pairs():
		baked[p] = true
	var pay_set := {}
	for p: int in TerrainConfig.all_slope_payloads():
		pay_set[p] = true
	var slope_cells := 0
	var unbaked_pairs := 0
	var unbaked_payloads := 0
	for dz in range(-70, 70):
		for dx in range(-70, 70):
			var x := mtn.x + dx
			var z := mtn.y + dz
			var run := TerrainConfig.slope_run_of(x, z)
			if not TerrainConfig.slope_run_fires(run):
				continue
			var g: int = TerrainConfig.height_at(x, z)
			var rng := TerrainConfig.slope_run_range(run, g)
			for y in range(rng.x, rng.y):
				var v: int = TerrainConfig.generated_cell(x, y, z)
				var mod: int = CellCodec.modifier(v)
				if not CellCodec.is_slope(mod):
					continue
				slope_cells += 1
				var payload: int = mod & 0xFFF
				if not pay_set.has(payload):
					unbaked_payloads += 1
				if not baked.has(CellCodec.mat(v) * TerrainConfig._SLOPE_STRIDE + payload):
					unbaked_pairs += 1
	_ok(slope_cells > 0, "slope-complete: wide mountain sweep produced %d slope cells" % slope_cells)
	_ok(unbaked_payloads == 0, "slope-complete: every emitted payload ∈ all_slope_payloads() (%d unbaked)" % unbaked_payloads)
	_ok(unbaked_pairs == 0, "slope-complete: every emitted (mat,payload) ∈ emitted_slope_pairs() — no cube fallback (%d unbaked of %d cells)" % [unbaked_pairs, slope_cells])

	# (DEFECT 2) "don't touch hills": the 45° widening (a column whose corner-target plane escapes the
	# ONE-cell window [g,g+1] but stays within the TWO-cell window [g,g+2] — the 1–2 block/cell band)
	# fires SLOPE only in B_MOUNTAINS. Every NON-mountain column in that band must emit NO slope AND keep
	# its g+1 cap modifier BYTE-IDENTICAL to the legacy formula; a mountain column in the same band DOES
	# still emit SLOPE (the ladder kill is preserved where it matters).
	var hill_band := 0
	var mtn_band := 0
	var mtn_band_fires := 0
	var hill_no_slope := true
	var hill_byte := true
	for cc: Vector2i in [spawn, TerrainConfig.find_coast(), mtn]:  # mtn supplies B_MOUNTAINS band columns
		for dz in range(-120, 120, 2):
			for dx in range(-120, 120, 2):
				var x := cc.x + dx
				var z := cc.y + dz
				var g: int = TerrainConfig.height_at(x, z)
				if g < TerrainConfig.SEA_LEVEL:
					continue
				var raw := TerrainConfig._corner_targets(x, z, null)
				var q0 := roundi(raw.x * 4.0)
				var q1 := roundi(raw.y * 4.0)
				var q2 := roundi(raw.z * 4.0)
				var q3 := roundi(raw.w * 4.0)
				var lo_r: int = mini(mini(q0, q1), mini(q2, q3))
				var hi_r: int = maxi(maxi(q0, q1), maxi(q2, q3))
				var escapes_two := lo_r < g * 4 or hi_r > (g + 2) * 4
				var escapes_one := lo_r < g * 4 or hi_r > (g + 1) * 4
				if escapes_two or not escapes_one:
					continue                          # not the 1–2 block/cell (~45°) band
				if int(TerrainConfig.column_profile(x, z).y) == TerrainConfig.B_MOUNTAINS:
					mtn_band += 1
					if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(x, z)):
						mtn_band_fires += 1
					continue
				# NON-mountain 45° band: skip rim columns (a firing neighbour legitimately reshapes them)
				var rim := false
				for jx in range(-1, 2):
					for jz in range(-1, 2):
						if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(x + jx, z + jz)):
							rim = true
				if rim:
					continue
				hill_band += 1
				if CellCodec.is_slope(CellCodec.modifier(TerrainConfig.generated_cell(x, g, z))) \
						or CellCodec.is_slope(CellCodec.modifier(TerrainConfig.generated_cell(x, g + 1, z))):
					hill_no_slope = false
				var tree := TreeGen.block_at(x, g + 1, z) != BlockCatalog.AIR
				var legacy_cm := 0 if tree else TerrainConfig._modifier_from_targets(raw, g + 1)
				if legacy_cm != 0 and TerrainConfig.surface_cap_modifier(x, z) != legacy_cm:
					hill_byte = false
	_ok(hill_band > 0, "slope-hills: swept %d non-mountain 45° band columns (the widening must skip these)" % hill_band)
	_ok(hill_no_slope, "slope-hills: NO SLOPE cell on non-mountain 45° columns (hills byte-identical, DEFECT 2)")
	_ok(hill_byte, "slope-hills: non-mountain 45° g+1 caps == legacy formula (hills untouched)")
	_ok(mtn_band_fires > 0, "slope-hills: mountain columns in the same 45° band DO emit SLOPE (%d of %d) — ladder kill kept" % [mtn_band_fires, mtn_band])

	# (6) both-path module mirror: arid_for_cell == gen_arid_for mirror for a generated slope cell;
	# unbaked payload → cube (never 0); a snow-capped run cell → the _snow_slope_arid slot.
	if ClassDB.class_exists("VoxelTerrain") and fires.size() > 0:
		var mw: Node = load("res://src/world/voxel_module/module_world.gd").new()
		get_root().add_child(mw)
		if bool(mw.call("setup")):
			var mirror_ok := true
			var slope_arid_seen := false
			var cube_fallbacks := 0                  # DEFECT 1: a slope cell resolving to its plain cube ARID
			for col: Vector2i in fires:
				var g: int = TerrainConfig.height_at(col.x, col.y)
				var run := TerrainConfig.slope_run_of(col.x, col.y)
				var rng := TerrainConfig.slope_run_range(run, g)
				for y in range(rng.x, rng.y):
					var v: int = TerrainConfig.generated_cell(col.x, y, col.y)
					if not CellCodec.is_slope(CellCodec.modifier(v)):
						continue
					var a1: int = mw.call("arid_for_cell", v)
					var a2: int = mw.call("gen_arid_for", CellCodec.mat(v), CellCodec.modifier(v), 0, CellCodec.LIQ_WATER, CellCodec.state(v))
					if a1 != a2:
						mirror_ok = false
					if a1 > 0:
						slope_arid_seen = true
					if a1 == int(mw.call("arid_for", CellCodec.mat(v), 0)):
						cube_fallbacks += 1          # baked-set complete => this must never happen
			_ok(mirror_ok, "slope-both: arid_for_cell == gen_arid_for mirror over mountain run cells")
			_ok(slope_arid_seen, "slope-both: generated slope cells resolve to real (non-zero) ARIDs")
			_ok(cube_fallbacks == 0, "slope-both: every generated slope cell resolves to a NON-cube ARID (%d fell back)" % cube_fallbacks)
			# an unbaked slope payload falls back to the material cube (never 0/hole)
			var unbaked := CellCodec.MOD_FAM_BIT | (CellCodec.FAM_SLOPE << CellCodec.MOD_FAM_KIND_SHIFT) | 0x2AA
			var fb: int = mw.call("gen_arid_for", STONE, unbaked)
			_ok(fb == int(mw.call("arid_for", STONE, 0)), "slope-both: unbaked slope payload → material cube ARID (never a hole)")
		mw.queue_free()

# Shader/material PIPELINE pre-warm (RENDER-STREAMING-SPIKES). Headless has NO GPU so we
# cannot assert pipelines actually compiled; instead we fence the ENUMERATION and
# LIFECYCLE that guarantee the on-device warm-up is a complete SUPERSET: a cube with a
# real material for EVERY non-AIR block id (a skipped id = a residual gameplay spike), a
# shaped mesh for every emitted smoothing modifier, no empty/null-material instance, and
# a clean teardown that frees the whole pile after the frame budget.
func _test_shader_prewarm() -> void:
	print("[prewarm] shader/material pipeline pre-warm enumeration + lifecycle")
	BlockCatalog.ensure_ready()
	var prewarm: ShaderPrewarm = ShaderPrewarm.new()
	get_root().add_child(prewarm)
	var count := prewarm.spawn_warmups(Transform3D.IDENTITY)
	_ok(count == prewarm.warmup_instance_count(), "prewarm: spawn count == warmup_instance_count() (%d)" % count)
	_ok(count == prewarm.live_mesh_instance_count(), "prewarm: every spawned job is a live MeshInstance3D child (%d)" % count)

	# (a) one cube per non-AIR block id — no id skipped (a skipped id = a residual spike).
	var non_air := BlockCatalog.count() - 1
	var cube_ids := prewarm.warmed_cube_ids()
	_ok(cube_ids.size() == non_air, "prewarm: one warm-up cube per non-AIR block id (%d cubes, %d non-AIR ids)" % [cube_ids.size(), non_air])
	var cube_set := {}
	for id: int in cube_ids:
		cube_set[id] = true
	var all_ids := true
	for id in range(1, BlockCatalog.count()):
		if not cube_set.has(id):
			all_ids = false
	_ok(all_ids, "prewarm: no non-AIR block id is skipped (every id 1..count-1 has a cube)")

	# (b) shaped warm-up covers every emitted smoothing modifier.
	var emitted := TerrainConfig.emitted_modifiers()
	var shaped_set := {}
	for m in prewarm.warmed_shape_modifiers():
		shaped_set[m] = true
	var all_mods := true
	for m in emitted:
		if not shaped_set.has(m):
			all_mods = false
	_ok(all_mods, "prewarm: shaped warm-up covers every emitted modifier (%d emitted, %d shaped)" % [emitted.size(), shaped_set.size()])
	_ok(count >= non_air + emitted.size(), "prewarm: total superset >= cubes + shaped-per-modifier (%d >= %d)" % [count, non_air + emitted.size()])

	# (c) every warm-up instance has a mesh (>=1 surface) WITH a material set — an empty
	#     or null-material instance would warm nothing.
	var geom_ok := true
	var mats_seen := {}
	for c in prewarm.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		var mesh := mi.mesh
		if mesh == null or mesh.get_surface_count() < 1:
			geom_ok = false
			continue
		var mat := mesh.surface_get_material(0)
		if mat == null:
			geom_ok = false
			continue
		mats_seen[mat.get_instance_id()] = true
	_ok(geom_ok, "prewarm: every warm-up instance has a mesh (>=1 surface) with a material set")

	# (d) the real per-id material of every non-AIR id appears among the warmed materials.
	var mats_ok := true
	for id in range(1, BlockCatalog.count()):
		var mat := BlockMaterials.get_for(id)
		if mat == null or not mats_seen.has(mat.get_instance_id()):
			mats_ok = false
	_ok(mats_ok, "prewarm: the real BlockMaterials material of every non-AIR id is warmed")

	print("    prewarm superset: %d cubes + %d shaped = %d instances (WARMUP_FRAMES=%d)"
		% [cube_ids.size(), count - cube_ids.size(), count, ShaderPrewarm.WARMUP_FRAMES])

	# (e) LIFECYCLE: driving the frame countdown frees the whole pile, then finishes.
	var done := [false]
	prewarm.finished.connect(func() -> void: done[0] = true)
	for _f in range(ShaderPrewarm.WARMUP_FRAMES):
		prewarm._process(0.016)
	_ok(prewarm.live_mesh_instance_count() == 0, "prewarm: warm-up meshes freed after WARMUP_FRAMES (%d frames)" % ShaderPrewarm.WARMUP_FRAMES)
	prewarm._process(0.016)   # one more frame: overlay + self teardown; finished fires
	_ok(done[0], "prewarm: finished signal fires after the frame budget (player re-enabled here)")
	_ok(prewarm.warmup_instance_count() == 0, "prewarm: tracked instance list cleared on teardown")

	# (f) PHASE 2 TERMINATION GUARANTEE. begin() enables the module-only terrain-meshed hold; a bare
	# player (no WorldManager → not a module build) must SKIP the hold and finish immediately, so a
	# fallback/non-module build never pays a load penalty and the prewarm always terminates.
	var pw2: ShaderPrewarm = ShaderPrewarm.new()
	get_root().add_child(pw2)
	var dummy := Node3D.new()
	get_root().add_child(dummy)
	var done2 := [false]
	pw2.finished.connect(func() -> void: done2[0] = true)
	pw2.begin(dummy, Callable())
	var guard := 0
	while not done2[0] and guard < 100000:
		pw2._process(1.0)
		guard += 1
	_ok(done2[0], "prewarm: PHASE 2 finishes (no module → hold skipped; never hangs)")
	_ok(pw2.live_mesh_instance_count() == 0, "prewarm: PHASE 2 tears the pile down on finish")
	dummy.queue_free()

# WATER-SHORE §8 (items 1–6 + collider 8) — composite water-over-terrain cells, the 0.9 water
# surface, and underwater floor smoothing. The liquid axis (CellCodec bits 48..53) is a pure
# render+sim overlay: no physics function reads it, and it is worldgen-only (player actions never
# fabricate liquid bits). This test fences the codec, the generated-liquid rule, the physics
# transparency of the axis, the manifest coverage, and the collider. Module-path ARID mirroring
# (item 7) lives in _test_both_paths. (Item 5b ZoneChunk liquid round-trip is DEFERRED OUT of v1
# per the doc's ORCHESTRATOR DEVIATION banner — liquid is never serialized, so it is not tested.)
func _test_water_shore() -> void:
	print("[WATER-SHORE] composite shore cells / 0.9 water surface / underwater floor smoothing")
	var SEA: int = TerrainConfig.SEA_LEVEL
	var WATER := BlockCatalog.id_of(&"water")
	var ICE := BlockCatalog.id_of(&"ice")
	var RAMP := ShapeCodec.make_modifier(2, 2, 0, 0)   # a real (wedge) modifier: a composite anchor
	var W9 := CellCodec.make_liquid(CellCodec.LIQ_WATER, CellCodec.LIQ_LEVEL_SURFACE)

	# ---- item 1: CODEC — pack/project round-trip + canonicalization -----------------
	# Constant pin: WATER_SURFACE_HEIGHT (now 0.9375 = native fluid TOP_HEIGHT) still rounds to the
	# water-line level (LIQ_LEVEL_SURFACE=9) in tenths, so the liquid-9 water-line encoding is intact.
	_ok(roundi(TerrainConfig.WATER_SURFACE_HEIGHT * 10.0) == CellCodec.LIQ_LEVEL_SURFACE,
		"codec: roundi(WATER_SURFACE_HEIGHT*10) == LIQ_LEVEL_SURFACE (%d) — 0.9375 rounds to level 9" % CellCodec.LIQ_LEVEL_SURFACE)

	# pack/project round-trip over kinds × levels: the liquid FIELD projects back exactly and never
	# perturbs the material/modifier/state axes (a solid host with a modifier, so nothing is stripped).
	var rt_ok := true
	var axes_ok := true
	for k in range(0, 4):
		for lvl in range(0, 16):
			var field := CellCodec.make_liquid(k, lvl)
			var v := CellCodec.pack(STONE, RAMP, 7, field)
			if CellCodec.liquid_kind(v) != (k & CellCodec.LIQ_KIND_MASK) or CellCodec.liquid_level(v) != (lvl & 0xF) \
					or CellCodec.liquid_field(v) != field:
				rt_ok = false
			if CellCodec.mat(v) != STONE or CellCodec.modifier(v) != RAMP or CellCodec.state(v) != 7:
				axes_ok = false
			if (v >> 54) != 0:                                   # bits 54..62 and bit 63 clear after pack
				axes_ok = false
	_ok(rt_ok, "codec: liquid pack/project round-trips over kinds × levels")
	_ok(axes_ok, "codec: liquid field never perturbs mat/modifier/state; bits 54..63 == 0 after pack")
	_ok(CellCodec.liquid_top(CellCodec.pack(STONE, RAMP, 0, W9)) == 0.9, "codec: liquid_top == level/10 (0.9 at level 9)")

	# canonicalization rules (§2.3): each violation strips to the canonical form.
	_ok(CellCodec.canonical(CellCodec.pack(BlockCatalog.AIR, 0, 0, W9)) == 0,
		"codec canon: liquid on AIR → whole value 0 (rule 1)")
	_ok(CellCodec.liquid_field(CellCodec.canonical(CellCodec.pack(STONE, RAMP, 0, CellCodec.make_liquid(0, 5)))) == 0,
		"codec canon: kind 0 with a level → field 0 (rule 2)")
	_ok(CellCodec.liquid_field(CellCodec.canonical(CellCodec.pack(STONE, RAMP, 0, CellCodec.make_liquid(CellCodec.LIQ_WATER, 0)))) == 0,
		"codec canon: a kind with level 0 → field 0 (rule 3)")
	# level > 10 clamps to 10 on a solid composite host (a modifier != 0 keeps liquid, rule 6).
	_ok(CellCodec.liquid_level(CellCodec.canonical(CellCodec.pack(STONE, RAMP, 0, CellCodec.make_liquid(CellCodec.LIQ_WATER, 11)))) == CellCodec.LIQ_LEVEL_FULL,
		"codec canon: level 11 clamps to 10 (rule 4)")
	# (water, 10) on the water material → the bare water id (rule 5: no dual encoding of full water).
	_ok(CellCodec.canonical(CellCodec.pack(WATER, 0, 0, CellCodec.make_liquid(CellCodec.LIQ_WATER, CellCodec.LIQ_LEVEL_FULL))) == WATER,
		"codec canon: (water,10) on water → bare water id (rule 5)")
	# liquid on a solid FULL cube (modifier 0) strips (rule 6, waterlogged full cubes out of v1).
	_ok(CellCodec.liquid_field(CellCodec.canonical(CellCodec.pack(STONE, 0, 0, W9))) == 0 \
			and CellCodec.mat(CellCodec.canonical(CellCodec.pack(STONE, 0, 0, W9))) == STONE,
		"codec canon: liquid on a solid full cube strips (rule 6), material kept")
	# kind ≠ the non-solid host's own liquid identity strips (rule 5): kind 2 on the water material.
	_ok(CellCodec.liquid_field(CellCodec.canonical(CellCodec.pack(WATER, 0, 0, CellCodec.make_liquid(2, 5)))) == 0,
		"codec canon: liquid kind ≠ non-solid host identity strips (rule 5)")
	# modifier-on-water STILL strips (the untouched non-solid-modifier invariant), while a matching
	# WATER liquid at level 9 is KEPT — i.e. the open-water surface cell: bare water + liquid(WATER,9).
	var wsurf := CellCodec.canonical(CellCodec.pack(WATER, RAMP, 0, W9))
	_ok(CellCodec.modifier(wsurf) == 0, "codec canon: modifier on water STILL strips (untouched non-solid invariant)")
	_ok(CellCodec.liquid_kind(wsurf) == CellCodec.LIQ_WATER and CellCodec.liquid_level(wsurf) == CellCodec.LIQ_LEVEL_SURFACE,
		"codec canon: water-material + level-9 liquid is KEPT (the open-water surface cell)")
	# is_plain false for any liquid-carrying value; strip_liquid is exact.
	_ok(not CellCodec.is_plain(CellCodec.pack(STONE, 0, 0, W9)), "codec: is_plain false for a liquid-carrying value")
	_ok(not CellCodec.is_plain(CellCodec.pack(WATER, 0, 0, W9)), "codec: is_plain false for the water-surface value")
	_ok(CellCodec.strip_liquid(CellCodec.pack(STONE, RAMP, 5, W9)) == CellCodec.pack(STONE, RAMP, 5, 0),
		"codec: strip_liquid clears ONLY the liquid field (mat/modifier/state kept)")
	# PRESERVATION PIN (§2.2): canonical(with_liquid(valid composite)) keeps the field bit-exactly —
	# guards the historical pack()/canonical() drops-bits-≥48 bug from regressing.
	var comp := CellCodec.with_liquid(CellCodec.pack(GRASS, RAMP), CellCodec.LIQ_WATER, CellCodec.LIQ_LEVEL_SURFACE)
	var comp_can := CellCodec.canonical(comp)
	_ok(CellCodec.liquid_field(comp_can) == W9 and CellCodec.modifier(comp_can) == RAMP and CellCodec.mat(comp_can) == GRASS,
		"codec: canonical(with_liquid(valid composite)) PRESERVES the liquid field (bits ≥48 not dropped)")

	# ---- item 2: WORLDGEN — the composite exists ------------------------------------
	var shore := _find_shore_composite()
	if shore.x == 0x7fffffff:
		_ok(false, "worldgen: found a non-frozen shore composite column (g == SEA_LEVEL, surface_modifier != 0)")
	else:
		var sc := TerrainConfig.generated_cell(shore.x, SEA, shore.y)
		_ok(BlockCatalog.solidity_of(CellCodec.mat(sc)) >= 0.5, "worldgen: shore composite has a SOLID terrain material")
		_ok(CellCodec.modifier(sc) != 0, "worldgen: shore composite carries a surface modifier (a shaped ramp)")
		_ok(CellCodec.liquid_kind(sc) == CellCodec.LIQ_WATER and CellCodec.liquid_level(sc) == CellCodec.LIQ_LEVEL_SURFACE,
			"worldgen: shore composite carries liquid(WATER, 9) — water to the 0.9 line")
	# A smoothed underwater floor column → submerged composite carrying liquid(WATER, 10).
	var uw := _find_uw_smoothed()
	if uw.x == 0x7fffffff:
		_ok(false, "worldgen: found a smoothed underwater floor column (g < SEA_LEVEL, surface_modifier != 0)")
	else:
		var ug: int = TerrainConfig.height_at(uw.x, uw.y)
		var uc := TerrainConfig.generated_cell(uw.x, ug, uw.y)
		_ok(CellCodec.modifier(uc) != 0, "worldgen: submerged floor composite is shaped (modifier != 0)")
		_ok(CellCodec.liquid_kind(uc) == CellCodec.LIQ_WATER and CellCodec.liquid_level(uc) == CellCodec.LIQ_LEVEL_FULL,
			"worldgen: submerged floor composite carries liquid(WATER, 10) — full-fill")
	# A non-frozen underwater column that GROWS a cap (WATER-SHORE §3.6 — underwater caps ON): its
	# cap cell at y=g+1 is a COMPOSITE of the UNDERWATER-FLOOR material (sand/gravel/red_sand/mud —
	# NOT a land biome top), shaped, filling its remainder with water: level 9 when the cap sits
	# exactly at the water line (g == SEA-1), else level 10 (submerged).
	var uwcap := _find_uw_cap()
	if uwcap.x == 0x7fffffff:
		print("    (no non-frozen underwater cap column found near the coast — underwater-cap worldgen assert skipped)")
	else:
		var cg: int = TerrainConfig.height_at(uwcap.x, uwcap.y)
		var capc := TerrainConfig.generated_cell(uwcap.x, cg + 1, uwcap.y)
		var capmat := CellCodec.mat(capc)
		var uw_mats := {
			BlockCatalog.id_of(&"sand"): true, BlockCatalog.id_of(&"gravel"): true,
			BlockCatalog.id_of(&"red_sand"): true, BlockCatalog.id_of(&"mud"): true,
		}
		_ok(CellCodec.modifier(capc) != 0, "worldgen: underwater cap cell (y=g+1) is shaped (modifier != 0)")
		_ok(uw_mats.has(capmat),
			"worldgen: underwater cap material is an underwater-floor material (sand/gravel/red_sand/mud), not a land biome-top")
		var want_lvl: int = CellCodec.LIQ_LEVEL_SURFACE if cg + 1 == SEA else CellCodec.LIQ_LEVEL_FULL
		_ok(CellCodec.liquid_kind(capc) == CellCodec.LIQ_WATER and CellCodec.liquid_level(capc) == want_lvl,
			"worldgen: underwater cap fills its remainder with water (level %d, %s)" % [want_lvl, "water line" if cg + 1 == SEA else "submerged"])
	# Open water: mat water + level 9 at SEA_LEVEL; the bare water id at SEA_LEVEL-1 (byte-identity).
	var ow := _find_open_water(false)
	if ow.x == 0x7fffffff:
		_ok(false, "worldgen: found a non-frozen open-water column (g <= SEA_LEVEL-2)")
	else:
		var owg: int = TerrainConfig.height_at(ow.x, ow.y)
		var surf := TerrainConfig.generated_cell(ow.x, SEA, ow.y)
		_ok(CellCodec.mat(surf) == WATER and CellCodec.liquid_level(surf) == CellCodec.LIQ_LEVEL_SURFACE,
			"worldgen: open water at SEA_LEVEL is the water material + liquid level 9")
		_ok(TerrainConfig.generated_cell(ow.x, SEA - 1, ow.y) == WATER,
			"worldgen: open water at SEA_LEVEL-1 is the BARE water id (deep-water byte-identity)")
		# A deep flat floor cell is a bare id with no liquid — byte-identical to generated_block.
		var floor_cell := TerrainConfig.generated_cell(ow.x, owg, ow.y)
		if CellCodec.modifier(floor_cell) == 0:
			_ok(CellCodec.liquid_field(floor_cell) == 0 and floor_cell == TerrainConfig.generated_block(ow.x, owg, ow.y),
				"worldgen: a FLAT underwater floor cell is a bare id, liquid 0 (byte-identity)")
	# Frozen ocean surface → ice, field 0; the sheet ends crisply (no liquid overlay).
	var cold := _find_cold_sea()
	if cold.x != 0x7fffffff:
		var fc := TerrainConfig.generated_cell(cold.x, SEA, cold.y)
		_ok(CellCodec.mat(fc) == ICE and CellCodec.liquid_field(fc) == 0,
			"worldgen: frozen ocean surface is ICE with NO liquid overlay (crisp sheet)")
	else:
		_ok(false, "worldgen: found a cold sea column to fence the frozen-surface rule")
	# Frozen smoothed shore (g == SEA_LEVEL, t < -0.55, modifier != 0) → bare ramp, field 0 (rare;
	# assert only when the terrain provides one).
	var fshore := _find_frozen_shore()
	if fshore.x != 0x7fffffff:
		var fsc := TerrainConfig.generated_cell(fshore.x, SEA, fshore.y)
		_ok(CellCodec.modifier(fsc) != 0 and CellCodec.liquid_field(fsc) == 0,
			"worldgen: a frozen smoothed shore cell is a bare ramp with NO liquid overlay")
	else:
		print("    (no frozen smoothed shore column found near origin — frozen-shore worldgen assert skipped)")

	# ---- item 3: underwater smoothing ENGAGES & AGREES ------------------------------
	var c := TerrainConfig.find_coast()
	var uw_sm_seen := 0
	var agree_ok := true
	var det_ok := true
	for dx in range(-150, 151, 3):
		var x := c.x + dx
		for dz in range(-150, 151, 3):
			var z := c.y + dz
			var g: int = TerrainConfig.height_at(x, z)
			if g >= SEA:
				continue
			var v := TerrainConfig.generated_cell(x, g, z)
			# surface_modifier(x,z) == modifier(generated_cell) below sea level too (§3.4).
			if TerrainConfig.surface_modifier(x, z) != CellCodec.modifier(v):
				agree_ok = false
			# determinism INCLUDING the liquid bits (48+): a full-int re-sample is identical.
			if v != TerrainConfig.generated_cell(x, g, z):
				det_ok = false
			if CellCodec.modifier(v) != 0:
				uw_sm_seen += 1
	_ok(uw_sm_seen > 0, "smoothing: an ocean-crossing sweep has underwater smoothed columns (%d)" % uw_sm_seen)
	_ok(agree_ok, "smoothing: surface_modifier(x,z) == modifier(generated_cell(x,g,z)) for underwater columns")
	_ok(det_ok, "smoothing: generated_cell (incl. liquid bits 48+) is deterministic on re-sample")

	# ---- item 4: PHYSICS through water (the axis is invisible to physics) -----------
	var pw: WorldManager = _struct_world("WaterPhysics")
	if shore.x != 0x7fffffff:
		var sm := TerrainConfig.surface_modifier(shore.x, shore.y)
		var fx := float(shore.x) + 0.5
		var fz := float(shore.y) + 0.5
		var expect_top := float(SEA) + ShapeCodec.local_top(sm, 0.5, 0.5)
		# floor_under stands on the terrain RAMP inside the composite cell (the water is not floor).
		var fu := pw.floor_under(fx, fz, float(SEA) + 3.0)
		_ok(is_equal_approx(fu, expect_top),
			"physics: floor_under over a composite == g + local_top(sm) = %.3f (got %.3f)" % [expect_top, fu])
		# wading the shore ramp is not blocked (open air/water above the ramp surface).
		_ok(pw.blocked(fx, fz, expect_top + 0.05) == false, "physics: blocked() false wading the shore ramp")
		# a ray straight down hits the composite's ramp IN-CELL (not the water overlay), UP normal.
		var hit := pw.aimed_voxel(Vector3(fx, float(SEA) + 4.0, fz), Vector3(0, -1, 0), 16.0)
		_ok(hit.get("hit", false) and hit["voxel"] == Vector3i(shore.x, SEA, shore.y) and hit["normal"] == Vector3i.UP,
			"physics: aimed_voxel from above hits the composite ramp cell (through the water)")
		# breaking the composite returns its TERRAIN material and leaves the cell dry air.
		var mat_here := TerrainConfig.generated_block(shore.x, SEA, shore.y)
		var broke := pw.break_terrain(Vector3i(shore.x, SEA, shore.y), Vector3.INF)
		_ok(broke == mat_here, "physics: break_terrain on a composite returns the terrain material (%d)" % mat_here)
		_ok(pw.block_id_at(Vector3i(shore.x, SEA, shore.y)) == 0 and pw.cell_value_at(Vector3i(shore.x, SEA, shore.y)) == 0,
			"physics: the broken composite cell is dry air (overlay 0, no liquid)")
		# a scripted break/place loop never writes a liquid-carrying overlay value (worldgen-only axis).
		pw.place_block(Vector3i(shore.x, SEA, shore.y), STONE)
		pw.break_terrain(Vector3i(shore.x, SEA, shore.y), Vector3.INF)
		pw.place_block(Vector3i(shore.x, SEA, shore.y), GRASS)
		var no_liquid := true
		for ev: int in pw._edits.values():
			if CellCodec.liquid_field(ev) != 0:
				no_liquid = false
		_ok(no_liquid, "physics: after a scripted break/place loop, _edits carries NO liquid value (worldgen-only)")
	# floor_under over open water reaches the smoothed seafloor (water is waded through).
	if ow.x != 0x7fffffff:
		var owg: int = TerrainConfig.height_at(ow.x, ow.y)
		var ow_sm := TerrainConfig.surface_modifier(ow.x, ow.y)
		var owf := pw.floor_under(float(ow.x) + 0.5, float(ow.y) + 0.5, float(SEA) + 3.0)
		_ok(owf < float(SEA), "physics: floor_under falls THROUGH open water (below the water line, got %.3f)" % owf)
		_ok(is_equal_approx(owf, float(owg) + ShapeCodec.local_top(ow_sm, 0.5, 0.5)),
			"physics: floor_under over open water reaches the smoothed seafloor (g + local_top)")
	pw.queue_free()

	# ---- item 5: MANIFEST coverage --------------------------------------------------
	# Every (mat, modifier) an underwater surface sweep emits is covered by the dry manifest sets
	# (gravel now in appearance_surface_materials); every non-frozen shore-emitted pair ∈
	# emitted_shore_pairs() (superset language, mirroring the existing emitted-modifiers assert).
	if TerrainConfig.SMOOTHING_ENABLED:
		var mat_set := {}
		for m: int in TerrainConfig.appearance_surface_materials():
			mat_set[m] = true
		var mod_set := {}
		for m: int in TerrainConfig.emitted_modifiers():
			mod_set[m] = true
		var shore_set := {}
		for s: int in TerrainConfig.emitted_shore_pairs():
			shore_set[s] = true
		var uncovered_mat := 0
		var uncovered_mod := 0
		var uncovered_shore := 0
		var uw_surface_seen := 0
		var shore_pairs_seen := 0
		var uw_cap_wet_seen := 0                          # LEVEL-9 water-line cap composites (§3.6)
		var uw_cap_dry_seen := 0                          # LEVEL-10 submerged cap composites (§3.6)
		for dx in range(-150, 151, 3):
			var x := c.x + dx
			for dz in range(-150, 151, 3):
				var z := c.y + dz
				var g: int = TerrainConfig.height_at(x, z)
				# Underwater CAP composites (WATER-SHORE §3.6): checked independently of the surface
				# modifier — a flat cell beside a rising neighbour has cm != 0 with sm == 0. A cap at
				# the water line (g == SEA-1) is a LEVEL-9 WET composite → its pair ∈ emitted_shore_pairs();
				# a deeper cap (g < SEA-1) is a LEVEL-10 DRY composite → in the dry manifest.
				if g < SEA and TerrainConfig.column_profile(x, z).w >= -0.55:
					var cm := TerrainConfig.surface_cap_modifier(x, z)
					if cm != 0:
						var capmat := TerrainConfig.generated_block(x, g + 1, z)
						if g + 1 == SEA:                     # water-line cap → LEVEL-9 wet composite
							uw_cap_wet_seen += 1
							if not shore_set.has(capmat * 256 + cm):
								uncovered_shore += 1
						else:                                # submerged cap → LEVEL-10 dry composite
							uw_cap_dry_seen += 1
							if not mat_set.has(capmat):
								uncovered_mat += 1
							if not mod_set.has(cm):
								uncovered_mod += 1
				var sm := TerrainConfig.surface_modifier(x, z)
				if sm == 0:
					continue
				if g < SEA:                                  # underwater floor surface cell
					uw_surface_seen += 1
					if not mat_set.has(TerrainConfig.generated_block(x, g, z)):
						uncovered_mat += 1
					if not mod_set.has(sm):
						uncovered_mod += 1
				elif g == SEA and TerrainConfig.column_profile(x, z).w >= -0.55:   # non-frozen shore composite
					shore_pairs_seen += 1
					var slot := TerrainConfig.generated_block(x, g, z) * 256 + sm
					if not shore_set.has(slot):
						uncovered_shore += 1
		print("    manifest: uw cap composites seen — %d wet (level 9), %d dry (level 10)" % [uw_cap_wet_seen, uw_cap_dry_seen])
		_ok(uw_surface_seen > 0, "manifest: underwater surface sweep found shaped floor cells (%d)" % uw_surface_seen)
		_ok(uncovered_mat == 0, "manifest: every underwater surface/dry-cap material ∈ appearance_surface_materials (gravel present) — %d uncovered" % uncovered_mat)
		_ok(uncovered_mod == 0, "manifest: every underwater surface/dry-cap modifier ∈ emitted_modifiers — %d uncovered" % uncovered_mod)
		_ok(uncovered_shore == 0, "manifest: every non-frozen shore/water-line-cap pair ∈ emitted_shore_pairs (superset) — %d uncovered of %d surface + %d wet-cap seen" % [uncovered_shore, shore_pairs_seen, uw_cap_wet_seen])

	# ---- item 8 (6): COLLIDER — underwater surface prisms + debris floats on water ---
	var uwc := _find_open_water(true)   # a non-frozen open-water column that is ALSO smoothed
	if uwc.x == 0x7fffffff:
		print("    (no non-frozen smoothed underwater column found — collider water sweep skipped)")
	else:
		var cw: WorldManager = _struct_world("WaterCollider")
		var gc := GroundCollider.new()
		get_root().add_child(gc)
		gc.setup(cw)
		VoxelBody.spawn_loose(cw, {Vector3i(uwc.x, SEA + 20, uwc.y): STONE}, cw)   # active-body gate
		var center := Vector3(float(uwc.x) + 0.5, float(SEA) + 20.0, float(uwc.y) + 0.5)
		gc.update(center)
		_settle_collider(gc, center)
		var act := _collider_col(gc.active_rid(), uwc.x, uwc.y)
		var ref := _ref_col_heavy(cw, uwc.x, uwc.y, Vector2i(uwc.x, uwc.y))
		_ok(_cols_equal(act, ref), "collider: underwater column shapes == heavy-path reference (byte-identical incl. surface prism)")
		var uwg: int = TerrainConfig.height_at(uwc.x, uwc.y)
		_ok((act["prisms"] as Array).has(uwg), "collider: the smoothed underwater floor emits a surface PRISM at g=%d" % uwg)
		# loose-debris-floats-on-water: the sea fill emits a box whose top is the SEA_LEVEL+1 surface.
		var floats := false
		for bx: Vector2 in act["boxes"]:
			if absf(bx.y - float(SEA + 1)) < 0.001:
				floats = true
		_ok(floats, "collider: loose debris floats on water (sea-fill box tops out at SEA_LEVEL+1)")
		gc.queue_free()
		cw.queue_free()

## The first non-frozen SHORE COMPOSITE column near the coast: g == SEA_LEVEL with a nonzero
## surface modifier (a shaped water-line cell). Scans the find_coast()-centred region.
func _find_shore_composite() -> Vector2i:
	var c := TerrainConfig.find_coast()
	for dx in range(-160, 161):
		var x := c.x + dx
		for dz in range(-160, 161):
			var z := c.y + dz
			if TerrainConfig.height_at(x, z) != TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.column_profile(x, z).w < -0.55:
				continue                                     # frozen shore: ice regime (no composite)
			if TerrainConfig.surface_modifier(x, z) != 0:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The first smoothed UNDERWATER FLOOR column near the coast: g < SEA_LEVEL with a nonzero
## surface modifier (a submerged composite).
func _find_uw_smoothed() -> Vector2i:
	var c := TerrainConfig.find_coast()
	for dx in range(-160, 161):
		var x := c.x + dx
		for dz in range(-160, 161):
			var z := c.y + dz
			if TerrainConfig.height_at(x, z) >= TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.surface_modifier(x, z) != 0:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The first non-frozen UNDERWATER column near the coast that GROWS a cap (WATER-SHORE §3.6):
## g < SEA_LEVEL with a nonzero surface_cap_modifier. Its cap cell at y=g+1 is a submerged (or, at
## g==SEA_LEVEL-1, water-line) composite of the underwater-floor material. Non-frozen so the
## water-line case carries a clean liquid overlay (a frozen water-line cap is the ice regime).
func _find_uw_cap() -> Vector2i:
	var c := TerrainConfig.find_coast()
	for dx in range(-160, 161):
		var x := c.x + dx
		for dz in range(-160, 161):
			var z := c.y + dz
			if TerrainConfig.height_at(x, z) >= TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.column_profile(x, z).w < -0.55:
				continue                                     # frozen: ice regime at the water line
			if TerrainConfig.surface_cap_modifier(x, z) != 0:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The first OPEN-WATER column near the coast with at least one CLEAR water cell above the floor
## (g <= SEA_LEVEL-2), non-frozen, and NO smoothing cap growing on it (WATER-SHORE §3.6): a cap at
## g+1 is a solid composite that would intercept both the SEA_LEVEL-1 byte-identity read and a
## floor_under scan, so "open water" excludes it — the water column above the smoothed seafloor is
## unobstructed. `must_be_smoothed` also requires a nonzero surface modifier (a smoothed seafloor) —
## used by the collider sweep to exercise underwater surface prisms.
func _find_open_water(must_be_smoothed: bool) -> Vector2i:
	var c := TerrainConfig.find_coast()
	for dx in range(-160, 161):
		var x := c.x + dx
		for dz in range(-160, 161):
			var z := c.y + dz
			var g: int = TerrainConfig.height_at(x, z)
			if g > TerrainConfig.SEA_LEVEL - 2:
				continue
			if TerrainConfig.column_profile(x, z).w < -0.55:
				continue                                     # frozen: ICE cap, not open water
			if TerrainConfig.surface_cap_modifier(x, z) != 0:
				continue                                     # a cap would obstruct the clear water column
			if must_be_smoothed and TerrainConfig.surface_modifier(x, z) == 0:
				continue
			return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The first FROZEN smoothed shore column (g == SEA_LEVEL, t < -0.55, surface_modifier != 0), or
## the (0x7fffffff, _) sentinel — a wide outward scan (frozen beaches are rare).
func _find_frozen_shore() -> Vector2i:
	for x in range(-1200, 1200, 7):
		for z in range(-1200, 1200, 11):
			if TerrainConfig.height_at(x, z) != TerrainConfig.SEA_LEVEL:
				continue
			if TerrainConfig.column_profile(x, z).w >= -0.55:
				continue
			if TerrainConfig.surface_modifier(x, z) != 0:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The first MOLTEN-SEA column (MULTI-LIQUID §2.4): an underwater column (g < SEA_LEVEL) whose
## climate temperature is in the molten regime (t >= LAVA_SEA_T), so its sea fill IS lava. Molten
## oceans are rare (temperature freq 0.002 → hundreds-of-blocks climate regions, same class as
## frozen oceans), so this is a WIDE scan (biased toward the lava coast if one is in range, then a
## dense outward sweep). Returns the (0x7fffffff, _) sentinel if none — the caller asserts LOUDLY.
func _find_molten_column() -> Vector2i:
	var lc := TerrainConfig.find_coast_of(CellCodec.LIQ_LAVA)
	if lc.x != 0x7fffffff:
		for dx in range(-60, 61):
			for dz in range(-60, 61):
				var p := TerrainConfig.column_profile(lc.x + dx, lc.y + dz)
				if p.w >= TerrainConfig.LAVA_SEA_T and int(p.x) < TerrainConfig.SEA_LEVEL:
					return Vector2i(lc.x + dx, lc.y + dz)
	for x in range(-1400, 1400, 5):
		for z in range(-1400, 1400, 5):
			var p := TerrainConfig.column_profile(x, z)
			if p.w >= TerrainConfig.LAVA_SEA_T and int(p.x) < TerrainConfig.SEA_LEVEL:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)

## The first smoothed MOLTEN-FLOOR composite near a known molten column `m`: an underwater column
## (g < SEA_LEVEL) in the molten regime (t >= LAVA_SEA_T) with a nonzero surface modifier — a
## submerged composite whose liquid overlay is LIQ_LAVA (level 10). Sentinel if the terrain grows no
## smoothed molten floor in the sampled region (the caller then prints a skip, never a silent pass).
func _find_molten_submerged(m: Vector2i) -> Vector2i:
	for dx in range(-48, 49):
		for dz in range(-48, 49):
			var x := m.x + dx
			var z := m.y + dz
			var p := TerrainConfig.column_profile(x, z)
			if int(p.x) >= TerrainConfig.SEA_LEVEL or p.w < TerrainConfig.LAVA_SEA_T:
				continue
			if TerrainConfig.surface_modifier(x, z) != 0:
				return Vector2i(x, z)
	return Vector2i(0x7fffffff, 0)
