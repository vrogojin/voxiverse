extends SceneTree
## probe_nearfill_dirmap — is the near-gen's lattice->dir map (FacetAtlas.cell_dir, what the near blocks
## SAMPLE) the same direction as the render placement map (FacetAtlas.lattice_to_world64, where those
## blocks are DRAWN)? If not, the near mesh shows terrain of a different sphere point than its rendered
## location, and any profile-law far tile (SmoothV2 near-fill) diverges from it by slope x offset.

const FID := 578

func _initialize() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	TerrainConfig.set_active_facet(FID)
	var r := FacetAtlas.r_of(FID)
	var cc := FacetAtlas.centre_cell(FID)
	var probes := [
		Vector2i(cc.x, cc.y),
		Vector2i(13034, 8153),
		Vector2i(13074, 8139),
		Vector2i(cc.x + 150, cc.y),
		Vector2i(cc.x, cc.y + 150),
	]
	for pc: Vector2i in probes:
		var cdd = FacetAtlas.cell_dir(FID, pc.x, pc.y)
		var cd := Vector3(cdd.x, cdd.y, cdd.z)
		var w: Array = FacetAtlas.lattice_to_world64(FID, float(pc.x) + 0.5, 0.0, float(pc.y) + 0.5)
		var l := sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])
		var rd := Vector3(w[0] / l, w[1] / l, w[2] / l)
		var ang := cd.angle_to(rd)
		# where does cell_dir's point land in lattice space? (the horizontal offset in blocks)
		var cw := cd * r
		var lat: Array = FacetAtlas.world_to_lattice64(FID, cw.x, cw.y, cw.z)
		var off := Vector2(float(lat[0]) - (float(pc.x) + 0.5), float(lat[2]) - (float(pc.y) + 0.5))
		var g_cd := int(TerrainConfig.profile_at_dir(cd.x, cd.y, cd.z, r).x)
		var g_rd := int(TerrainConfig.profile_at_dir(rd.x, rd.y, rd.z, r).x)
		print("col %s: angle=%.5f deg (%.1f blk)  lattice-offset=(%.2f, %.2f)  g(cell_dir)=%d g(render-dir)=%d" % [
			str(pc), rad_to_deg(ang), ang * r, off.x, off.y, g_cd, g_rd])
	quit(0)
