extends SceneTree
## probe_acacia — Bug-1 adjudicator (TREE-BUGS design probe; NOT a shipped gate).
## Question: does the C++ mesh generator (VoxelGeneratorCosmos.resolve_cell) place acacia
## trunk/canopy cells at columns where the LIVE ANALYTIC path (TerrainConfig.generated_cell with
## pcache = null, i.e. what WorldManager.block_id_at composes) says AIR?
## Run FACETED+FP_CLIMATE_BIOMES sed'd ON.

var _gen: Object

func _initialize() -> void:
	print("=== probe_acacia (Bug 1: acacia mesh-vs-analytic divergence) ===")
	print("  FACETED=%s FP_CLIMATE_BIOMES=%s FP_CPPGEN=%s" % [str(CubeSphere.FACETED), str(CubeSphere.FP_CLIMATE_BIOMES), str(CubeSphere.FP_CPPGEN)])
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
	print("  id_acacia_log=%d id_acacia_leaf=%d" % [id_acacia_log, id_acacia_leaf])

	# --- find savanna facets (GD oracle, worker-style GenCtx) + a forest control ---
	var nf := int(atlas["facet_count"])
	var stride := maxi(1, nf / 600)
	var savanna: Array = []
	var forest: Array = []
	var f := 0
	while f < nf and (savanna.size() < 6 or forest.size() < 2):
		var lo: Vector2i = FacetAtlas.dom_min(f)
		var hi: Vector2i = FacetAtlas.dom_max(f)
		var cx := (lo.x + hi.x) / 2
		var cz := (lo.y + hi.y) / 2
		var prof: Vector4 = TerrainConfig.column_profile(cx, cz, TerrainConfig.GenCtx.new(0, f))
		var b := int(prof.y)
		if b == TerrainConfig.B_SAVANNA and savanna.size() < 6:
			savanna.append(f)
		elif b == TerrainConfig.B_FOREST and forest.size() < 2:
			forest.append(f)
		f += stride
	print("  savanna facets: %s  forest control: %s" % [str(savanna), str(forest)])
	if savanna.is_empty():
		print("NO savanna facet found in stride sweep — widen stride")
		quit(1)
		return

	var total_trees := 0
	var mesh_only := 0        # C++ places acacia cell, analytic says AIR  (the live bug)
	var analytic_only := 0    # analytic places, C++ air
	var biome_mismatch := 0
	var species_detail := {}
	var first := ""
	for sf in savanna + forest:
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
				# pure-position patch/cell gates (identical in both ports)
				var px := floori(float(gx) / 5.0)
				var pz := floori(float(gz) / 5.0)
				if TreeGen._hash01(px, pz, 11) >= TreeGen.PATCH_CHANCE:
					continue
				if TreeGen._hash01(gx, gz, 22) >= TreeGen.TREE_CHANCE:
					continue
				var b2: Vector2i = TreeGen._base_pos(gx, gz)
				var bx := b2.x
				var bz := b2.y
				# stay inside the facet domain
				if bx - 2 < lo2.x or bx + 2 > hi2.x or bz - 2 < lo2.y or bz + 2 > hi2.y:
					continue
				# biome parity at the base column: live-analytic (null pcache) vs C++ (fid)
				var gd_prof: Vector4 = TerrainConfig.column_profile(bx, bz)
				var cpp_prof: Vector4 = _gen.call("column_profile", fac, bx, bz)
				if int(gd_prof.y) != int(cpp_prof.y) or int(gd_prof.x) != int(cpp_prof.x):
					biome_mismatch += 1
					if first == "":
						first = "PROFILE fid=%d base=(%d,%d) GD(g=%d,b=%d) CPP(g=%d,b=%d)" % [fac, bx, bz, int(gd_prof.x), int(gd_prof.y), int(cpp_prof.x), int(cpp_prof.y)]
				var gd_species := TreeGen._species_for(int(gd_prof.y), gx, gz)
				var gy := TerrainConfig.column_top(bx, bz)
				if gy <= TerrainConfig.SEA_LEVEL:
					continue
				total_trees += 1
				# compare the full tree bbox on both paths
				for dx in range(-2, 3):
					for dz in range(-2, 3):
						for y in range(gy + 1, gy + 9):
							var gd_id := CellCodec.mat(TerrainConfig.generated_cell(bx + dx, y, bz + dz))
							var cpp_id := CellCodec.mat(int(_gen.call("resolve_cell", fac, bx + dx, y, bz + dz)))
							if gd_id == cpp_id:
								continue
							var is_tree_cpp := cpp_id == id_acacia_log or cpp_id == id_acacia_leaf
							var is_tree_gd := gd_id == id_acacia_log or gd_id == id_acacia_leaf
							if is_tree_cpp and gd_id == BlockCatalog.AIR:
								mesh_only += 1
							elif is_tree_gd and cpp_id == BlockCatalog.AIR:
								analytic_only += 1
							var key := "%d->%d" % [gd_id, cpp_id]
							species_detail[key] = int(species_detail.get(key, 0)) + 1
							if first == "":
								first = "CELL fid=%d (%d,%d,%d) gd_sp=%d GD=%d CPP=%d (gy=%d)" % [fac, bx + dx, y, bz + dz, gd_species, gd_id, cpp_id, gy]
	print("  trees swept: %d" % total_trees)
	print("  mesh-only acacia cells (C++ solid / analytic AIR): %d" % mesh_only)
	print("  analytic-only acacia cells: %d" % analytic_only)
	print("  profile (g/biome) mismatches: %d" % biome_mismatch)
	print("  mismatch id-pairs gd->cpp: %s" % str(species_detail))
	if first != "":
		print("  FIRST: " + first)
	print("=== probe done ===")
	quit(0)
