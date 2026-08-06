extends SceneTree
## verify_tree_biomes — COSMOS-TREE-BUGS Bug 1 gate (docs/COSMOS-TREE-BUGS-DESIGN.md, Bug 1 "Gate spec").
## Proves FP_BIOME_SPACE_FIX (renumber the Moon biome ids 21/22/23, clear of every Earth id — B_SAVANNA=11
## and B_JUNGLE=12 no longer collide with B_MOON_MARIA=11/B_MOON_HIGHLANDS=12) fixes the live bug where
## savanna/jungle columns were hijacked into the airless `_moon_cell` branch on the ANALYTIC path
## (block_id_at / collision / break DDA) while the C++ mesh generator — which has no moon branch — kept
## drawing the correct savanna/jungle ground + trees: visible trees the player walks straight through.
##
## Gates:
##   G-TB-EQUAL   probe_acacia promoted to an assertion: >=5 savanna + >=2 jungle facets, every tree
##                site's full column y in [g-4, g+TreeGen.MAX_ABOVE_SURFACE] over the 5x5 canopy
##                footprint: TerrainConfig.generated_cell == C++ resolve_cell cell-for-cell, 0 mismatches
##                (was 11,740+ mesh/analytic-only cells before the fix).
##   G-TB-SOLID   at >=20 acacia + >=10 jungle sites: block_id_at(trunk cell) == acacia_log/jungle_log AND
##                cell_solid(trunk cell) == true — the actual collision/DDA truth the player feels.
## (G-TB-COVER lives in verify_cppgen.gd's saw_tree counter, extended to acacia/jungle/cactus so a
##  flag-ON byte-equality run can never be vacuous on B1 species; G-TB-MOON is a re-run of the EXISTING
##  verify_multibody.gd gate under the fix, not new code here; byte-off is FLAT verify_feature 6042/0.)
##
## RUN (sed FACETED + FP_CLIMATE_BIOMES + FP_BIOME_SPACE_FIX all ON):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_tree_biomes.gd 2>/dev/null | grep VERIFY
## Falsifier: re-run with ONLY FP_BIOME_SPACE_FIX sed'd back OFF (FACETED/FP_CLIMATE_BIOMES still ON) —
## must go RED on G-TB-EQUAL and G-TB-SOLID (probe_acacia/2/3 already proved it measurably does).
## Exits 0 all-pass / 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _gen: Object

func _initialize() -> void:
	print("=== verify_tree_biomes (COSMOS-TREE-BUGS Bug 1) — FACETED=%s FP_CLIMATE_BIOMES=%s FP_BIOME_SPACE_FIX=%s FP_CPPGEN=%s ===" % [
		str(CubeSphere.FACETED), str(CubeSphere.FP_CLIMATE_BIOMES), str(CubeSphere.FP_BIOME_SPACE_FIX), str(CubeSphere.FP_CPPGEN)])
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		print("ABORT: no VoxelGeneratorCosmos in binary")
		quit(1)
		return
	_gen = ClassDB.instantiate("VoxelGeneratorCosmos")
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	var ns := TerrainConfig.noise_stack()
	FacetAtlas.warm_up()
	var atlas: Dictionary = FacetAtlas.frozen_atlas()
	var fid0 := TerrainConfig.active_facet()
	if fid0 < 0:
		fid0 = 0
		TerrainConfig.set_active_facet(fid0)
	var cfg := {
		"hills": ns["hills"], "detail": ns["detail"], "continent": ns["continent"],
		"temperature": ns["temperature"], "humidity": ns["humidity"], "mountain": ns["mountain"],
		"seed": ns["seed"], "gen_face": 0, "gen_n": 0, "gen_facet": fid0,
		"flat_world": true, "faceted": true, "m5c_corner": CubeSphere.M5C_CORNER,
		"cube_arid": PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7]),
		"block_ids": TerrainConfig.appearance_surface_materials(),
		"model_count": 8, "waterlog": false,
		"id_wood": BlockCatalog.WOOD, "id_leaf": BlockCatalog.LEAF,
		"id_spruce_log": BlockCatalog.id_of(&"spruce_log"),
		"id_spruce_leaf": BlockCatalog.id_of(&"spruce_leaves"),
		"id_birch_log": BlockCatalog.id_of(&"birch_log"),
		"id_birch_leaf": BlockCatalog.id_of(&"birch_leaves"),
	}
	for k in TerrainConfig.material_tables():
		cfg[k] = TerrainConfig.material_tables()[k]
	cfg["far_colors"] = FarPalette.frozen_colors()
	cfg["facet_frame"] = atlas["facet_frame"]
	cfg["facet_off"] = atlas["facet_off"]
	cfg["facet_r_blocks"] = atlas["facet_r_blocks"]
	if not bool(_gen.call("setup", cfg)):
		print("ABORT: setup() rejected")
		quit(1)
		return
	print("  setup ok; facet_count=%d" % int(atlas["facet_count"]))

	var id_acacia_log := BlockCatalog.id_of(&"acacia_log")
	var id_acacia_leaf := BlockCatalog.id_of(&"acacia_leaves")
	var id_jungle_log := BlockCatalog.id_of(&"jungle_log")
	var id_jungle_leaf := BlockCatalog.id_of(&"jungle_leaves")

	# --- find savanna + jungle facets (GD oracle, worker-style GenCtx) ---
	var nf := int(atlas["facet_count"])
	var stride := maxi(1, nf / 600)
	var savanna: Array = []
	var jungle: Array = []
	var f := 0
	while f < nf and (savanna.size() < 6 or jungle.size() < 3):
		var lo: Vector2i = FacetAtlas.dom_min(f)
		var hi: Vector2i = FacetAtlas.dom_max(f)
		var cx := (lo.x + hi.x) / 2
		var cz := (lo.y + hi.y) / 2
		var prof: Vector4 = TerrainConfig.column_profile(cx, cz, TerrainConfig.GenCtx.new(0, f))
		var b := int(prof.y)
		if b == TerrainConfig.B_SAVANNA and savanna.size() < 6:
			savanna.append(f)
		elif b == TerrainConfig.B_JUNGLE and jungle.size() < 3:
			jungle.append(f)
		f += stride
	print("  savanna facets: %s  jungle facets: %s" % [str(savanna), str(jungle)])
	_ok(savanna.size() >= 5, "G-TB-EQUAL: found >=5 savanna facets (got %d)" % savanna.size())
	_ok(jungle.size() >= 2, "G-TB-EQUAL: found >=2 jungle facets (got %d)" % jungle.size())
	if savanna.is_empty() and jungle.is_empty():
		print("ABORT: no savanna/jungle facet found in stride sweep")
		quit(1)
		return

	# --- a real WorldManager for the live analytic composed query (block_id_at / cell_solid) ---
	var w := WorldManager.new()
	w.name = "TreeBiomesGateWM"
	get_root().add_child(w)
	await process_frame
	await process_frame

	var mismatches := 0
	var acacia_solid_sites := 0
	var jungle_solid_sites := 0
	var first := ""
	for sf in savanna + jungle:
		var fac := int(sf)
		TerrainConfig.set_active_facet(fac)   # live analytic path resolves on the ACTIVE facet
		var lo2: Vector2i = FacetAtlas.dom_min(fac)
		var hi2: Vector2i = FacetAtlas.dom_max(fac)
		var g_lo_x := floori(float(lo2.x) / 10.0) + 1
		var g_hi_x := floori(float(hi2.x) / 10.0) - 1
		var g_lo_z := floori(float(lo2.y) / 10.0) + 1
		var g_hi_z := floori(float(hi2.y) / 10.0) - 1
		for gx in range(g_lo_x, g_hi_x + 1):
			for gz in range(g_lo_z, g_hi_z + 1):
				if TreeGen._hash01(floori(float(gx) / 5.0), floori(float(gz) / 5.0), 11) >= TreeGen.PATCH_CHANCE:
					continue
				if TreeGen._hash01(gx, gz, 22) >= TreeGen.TREE_CHANCE:
					continue
				var b2: Vector2i = TreeGen._base_pos(gx, gz)
				var bx := b2.x
				var bz := b2.y
				if bx - 2 < lo2.x or bx + 2 > hi2.x or bz - 2 < lo2.y or bz + 2 > hi2.y:
					continue
				var gd_prof: Vector4 = TerrainConfig.column_profile(bx, bz)
				var cpp_prof: Vector4 = _gen.call("column_profile", fac, bx, bz)
				if int(gd_prof.y) != int(cpp_prof.y) or int(gd_prof.x) != int(cpp_prof.x):
					mismatches += 1
					if first == "":
						first = "PROFILE fid=%d base=(%d,%d) GD(g=%d,b=%d) CPP(g=%d,b=%d)" % [fac, bx, bz, int(gd_prof.x), int(gd_prof.y), int(cpp_prof.x), int(cpp_prof.y)]
					continue
				var gy := int(gd_prof.x)
				if gy <= TerrainConfig.SEA_LEVEL:
					continue
				var species := TreeGen._species_for(int(gd_prof.y), gx, gz)
				if species != TreeGen.SP_ACACIA and species != TreeGen.SP_JUNGLE:
					continue
				# G-TB-EQUAL: full column, [g-4, g+MAX_ABOVE_SURFACE], over the 5x5 canopy footprint.
				for dx in range(-2, 3):
					for dz in range(-2, 3):
						for y in range(gy - 4, gy + TreeGen.MAX_ABOVE_SURFACE + 1):
							var gd_id := CellCodec.mat(TerrainConfig.generated_cell(bx + dx, y, bz + dz))
							var cpp_id := CellCodec.mat(int(_gen.call("resolve_cell", fac, bx + dx, y, bz + dz)))
							if gd_id != cpp_id:
								mismatches += 1
								if first == "":
									first = "CELL fid=%d (%d,%d,%d) species=%d GD=%d CPP=%d (gy=%d)" % [fac, bx + dx, y, bz + dz, species, gd_id, cpp_id, gy]
				# G-TB-SOLID: the trunk cell (base, g+1) via the REAL composed query.
				var trunk := Vector3i(bx, gy + 1, bz)
				var trunk_id := w.block_id_at(trunk)
				var trunk_solid := w.cell_solid(trunk)
				if species == TreeGen.SP_ACACIA:
					if trunk_id == id_acacia_log and trunk_solid:
						acacia_solid_sites += 1
					elif acacia_solid_sites < 20:
						_ok(false, "G-TB-SOLID: acacia trunk %s block_id_at=%d (want %d) cell_solid=%s" % [str(trunk), trunk_id, id_acacia_log, str(trunk_solid)])
				else:
					if trunk_id == id_jungle_log and trunk_solid:
						jungle_solid_sites += 1
					elif jungle_solid_sites < 10:
						_ok(false, "G-TB-SOLID: jungle trunk %s block_id_at=%d (want %d) cell_solid=%s" % [str(trunk), trunk_id, id_jungle_log, str(trunk_solid)])

	print("  mismatches: %d  acacia-solid sites: %d  jungle-solid sites: %d" % [mismatches, acacia_solid_sites, jungle_solid_sites])
	if first != "":
		print("  FIRST: " + first)
	_ok(mismatches == 0, "G-TB-EQUAL: 0 mesh/analytic mismatches over the full tree-site column sweep (got %d)" % mismatches)
	_ok(acacia_solid_sites >= 20, "G-TB-SOLID: >=20 solid acacia trunk sites (got %d)" % acacia_solid_sites)
	_ok(jungle_solid_sites >= 10, "G-TB-SOLID: >=10 solid jungle trunk sites (got %d)" % jungle_solid_sites)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
