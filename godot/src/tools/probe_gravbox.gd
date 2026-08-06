extends SceneTree
## probe_gravbox — quantify facet domain size vs the per-facet gravity box tangential cover.

func _initialize() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	var atlas: Dictionary = FacetAtlas.frozen_atlas()
	print("facet_count=%d" % int(atlas["facet_count"]))
	print("GRAV_BOX_TANGENTIAL=%.0f (half %.0f)" % [WorldManager.GRAV_BOX_TANGENTIAL, WorldManager.GRAV_BOX_TANGENTIAL * 0.5])
	for f in [0, 2, 20, 100]:
		var lo: Vector2i = FacetAtlas.dom_min(f)
		var hi: Vector2i = FacetAtlas.dom_max(f)
		var cc := FacetAtlas.centre_cell(f)
		print("fid=%d dom=[%s..%s] span=(%d,%d) centre=%s  max offset from centre=(%d,%d)" % [
			f, str(lo), str(hi), hi.x - lo.x, hi.y - lo.y, str(cc),
			maxi(hi.x - cc.x, cc.x - lo.x), maxi(hi.y - cc.y, cc.y - lo.y)])
	quit(0)
