extends SceneTree
## probe_acacia2 — vertical dump at a few savanna tree sites: GD analytic vs C++ resolve_cell,
## with datum shift, species gates, and hash values. Diagnosis refinement of probe_acacia.

var _gen: Object

func _initialize() -> void:
	print("=== probe_acacia2 ===")
	_gen = ClassDB.instantiate("VoxelGeneratorCosmos")
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	var ns := TerrainConfig.noise_stack()
	FacetAtlas.warm_up()
	var atlas: Dictionary = FacetAtlas.frozen_atlas()
	TerrainConfig.set_active_facet(20)
	var cfg := {
		"hills": ns["hills"], "detail": ns["detail"], "continent": ns["continent"],
		"temperature": ns["temperature"], "humidity": ns["humidity"], "mountain": ns["mountain"],
		"seed": ns["seed"], "gen_face": 0, "gen_n": 0, "gen_facet": 20,
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
		quit(1)
		return

	var fac := 20
	var lo: Vector2i = FacetAtlas.dom_min(fac)
	var hi: Vector2i = FacetAtlas.dom_max(fac)
	var dumped := 0
	for gx in range(floori(float(lo.x) / 10.0) + 1, floori(float(hi.x) / 10.0)):
		if dumped >= 3:
			break
		for gz in range(floori(float(lo.y) / 10.0) + 1, floori(float(hi.y) / 10.0)):
			if dumped >= 3:
				break
			var px := floori(float(gx) / 5.0)
			var pz := floori(float(gz) / 5.0)
			if TreeGen._hash01(px, pz, 11) >= TreeGen.PATCH_CHANCE:
				continue
			if TreeGen._hash01(gx, gz, 22) >= TreeGen.TREE_CHANCE:
				continue
			var b2: Vector2i = TreeGen._base_pos(gx, gz)
			var bx := b2.x
			var bz := b2.y
			if bx - 2 < lo.x or bx + 2 > hi.x or bz - 2 < lo.y or bz + 2 > hi.y:
				continue
			var prof: Vector4 = TerrainConfig.column_profile(bx, bz)
			var biome := int(prof.y)
			if biome != TerrainConfig.B_SAVANNA:
				continue
			var h124 := TreeGen._hash01(gx, gz, 124)
			if h124 >= TreeGen.ACACIA_DENSITY:
				continue          # C++ would thin this out too; want a real acacia site
			var gy := TerrainConfig.column_top(bx, bz)
			if gy <= TerrainConfig.SEA_LEVEL:
				continue
			dumped += 1
			var ds := FacetAtlas.datum_shift(fac, bx, bz)
			var cpp_prof: Vector4 = _gen.call("column_profile", fac, bx, bz)
			print("--- site fid=%d grid=(%d,%d) base=(%d,%d) gy(column_top)=%d datum_shift=%d" % [fac, gx, gz, bx, bz, gy, ds])
			print("    GD prof (g,b,c,t)=(%d,%d,%.4f,%.4f)  CPP prof=(%d,%d,%.4f,%.4f)" % [int(prof.x), biome, prof.z, prof.w, int(cpp_prof.x), int(cpp_prof.y), cpp_prof.z, cpp_prof.w])
			print("    GD species=%d h124=%.3f has_tree=%s trunk_h=%d" % [TreeGen._species_for(biome, gx, gz), h124, str(TreeGen.has_tree(gx, gz)), TreeGen._acacia_trunk_height(gx, gz)])
			print("    TreeGen.block_at(bx,gy+1..gy+7): %s" % str(range(gy + 1, gy + 8).map(func(y): return TreeGen.block_at(bx, y, bz))))
			print("    y: GDcell | CPPcell   (column bx,bz)")
			for y in range(gy - 3, gy + 9):
				var gd := TerrainConfig.generated_cell(bx, y, bz)
				var cp := int(_gen.call("resolve_cell", fac, bx, y, bz))
				print("    %4d: gd=0x%x(mat %d) | cpp=0x%x(mat %d)%s" % [y, gd, CellCodec.mat(gd), cp, CellCodec.mat(cp), ("   <<< MISMATCH" if gd != cp else "")])
	print("=== done (%d sites) ===" % dumped)
	quit(0)
