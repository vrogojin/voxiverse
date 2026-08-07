extends SceneTree
## probe_acacia3 — decompose generated_cell at one savanna site to find where −1/AIR comes from.

func _initialize() -> void:
	print("=== probe_acacia3 ===")
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	TerrainConfig.set_active_facet(20)
	var bx := -12143
	var bz := -10557
	var p: Vector4 = TerrainConfig.column_profile(bx, bz)
	var g := int(p.x)
	var biome := int(p.y)
	print("prof g=%d biome=%d c=%.4f t=%.4f  active_facet=%d" % [g, biome, p.z, p.w, TerrainConfig.active_facet()])
	print("FP_ANALYTIC_COL_MEMO=%s FACETED=%s" % [str(CubeSphere.FP_ANALYTIC_COL_MEMO), str(CubeSphere.FACETED)])
	print("datum_shift=%d" % FacetAtlas.datum_shift(20, bx, bz))
	for y in range(0, 8):
		var rc_null := TerrainConfig.resolve_cell(bx, y, bz, g, biome, p.z, p.w, null)
		var rc_ctx := TerrainConfig.resolve_cell(bx, y, bz, g, biome, p.z, p.w, TerrainConfig.GenCtx.new(0, 20))
		var gc := TerrainConfig.generated_cell(bx, y, bz)
		var tb := TreeGen.block_at(bx, y, bz)
		print("y=%d resolve(null)=0x%x resolve(ctx)=0x%x generated_cell=0x%x tree=%d" % [y, rc_null, rc_ctx, gc, tb])
	# surface rule pieces
	print("_surface_rule(y=g)=%d" % TerrainConfig._surface_rule(bx, g, bz, g, biome, p.z, p.w))
	print("_biome_top=%d _biome_filler(d=1)=%d" % [TerrainConfig._biome_top(biome, bx, bz), TerrainConfig._biome_filler(biome, bx, g - 1, bz, 1, p.w)])
	print("slope fires=%s" % str(TerrainConfig._slope_fires_only(bx, bz, g, null)))
	quit(0)
