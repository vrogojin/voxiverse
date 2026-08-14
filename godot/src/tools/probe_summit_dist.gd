extends SceneTree
## THROWAWAY PROBE (#109 summit-stream investigation, deleted after run) — for the live repro position
## (NAV lattice -28370, 70, 7117 on fid 748) print each edge slot's own-side ridge distance (own_dist),
## the seam neighbour fids, and where the point sits vs POOL_D_WARM / POOL_D_COMMIT. Read-only.

func _init() -> void:
	FacetAtlas.warm_up()
	# Live BCI position from the lead's telemetry: |p| ~ 6410 = R + 39 (blocks) — planet-fixed frame.
	var bci := CubeSphere.DVec3.new(-5429.0, 1694.0, -2957.0)
	var n := sqrt(bci.x * bci.x + bci.y * bci.y + bci.z * bci.z)
	var dir := CubeSphere.DVec3.new(bci.x / n, bci.y / n, bci.z / n)
	var fid := FacetAtlas.facet_of_dir(dir)
	print("|bci|=", snappedf(n, 0.1), "  fid=", fid)
	var lat: Array = FacetAtlas.world_to_lattice64(fid, bci.x, bci.y, bci.z)
	print("lattice=", snappedf(lat[0], 0.1), ",", snappedf(lat[1], 0.1), ",", snappedf(lat[2], 0.1),
		"  dom=", FacetAtlas._dom.slice(fid * 4, fid * 4 + 4))
	var best := 1.0e30
	for slot in 4:
		var nb := FacetAtlas.seam_neighbour(fid, slot)
		var d := FacetAtlas.own_dist(fid, slot, float(lat[0]), float(lat[1]), float(lat[2]))
		best = minf(best, d)
		print("slot=", slot, " nb=", nb, " own_dist=", snappedf(d, 0.01))
	print("min_ridge_dist=", snappedf(best, 0.01),
		"  D_WARM=", CubeSphere.POOL_D_WARM, "  D_COMMIT=", CubeSphere.POOL_D_COMMIT,
		"  imminent_selected=", best < CubeSphere.POOL_D_WARM,
		"  committed=", best < CubeSphere.POOL_D_COMMIT)
	quit(0)
