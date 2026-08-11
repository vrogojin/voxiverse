extends SceneTree
## Task #107 probe — locate the mountain ahead of the repro pos (fid 772, lattice -30970,7161) and classify
## which live tier covers it: distance, owning fid, hop from active, M2 SSE tier, smooth-V2 annulus membership.
## Read-only; prints a report and exits 0.

const PFID := 772
const PX := -30970.0
const PZ := 7161.0

func _init() -> void:
	FacetAtlas.warm_up()
	var pw := FacetAtlas.lattice_to_world64(PFID, PX, 50.0, PZ)
	var ppos := Vector3(pw[0], pw[1], pw[2])
	print("player world=%.1f,%.1f,%.1f |r|=%.1f" % [pw[0], pw[1], pw[2], ppos.length()])
	# --- scan the lattice plane around the player for high ground -------------------------------------------------
	var best: Array = []      # entries [dist, g, biome, wx, wy, wz]
	var step := 24.0
	var reach := 2600.0
	var n := int(reach / step)
	for iz in range(-n, n + 1):
		for ix in range(-n, n + 1):
			var dx := float(ix) * step
			var dz := float(iz) * step
			var r2 := dx * dx + dz * dz
			if r2 < 150.0 * 150.0 or r2 > reach * reach:
				continue
			var w := FacetAtlas.lattice_to_world64(PFID, PX + dx, 0.0, PZ + dz)
			var ln := sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])
			var prof := TerrainConfig.profile_at_dir(w[0] / ln, w[1] / ln, w[2] / ln, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			if g >= 55:
				var sp := Vector3(w[0] / ln, w[1] / ln, w[2] / ln) * (FacetAtlas.R_BLOCKS + float(g))
				best.append([ppos.distance_to(sp), g, int(prof.y), w[0], w[1], w[2]])
	best.sort_custom(func(a, b): return a[0] < b[0])
	print("high-ground samples (g>=55): %d" % best.size())
	# --- hop map (seam BFS from the active facet) -----------------------------------------------------------------
	var hop := {PFID: 0}
	var frontier: Array = [PFID]
	for h in range(1, 7):
		var next: Array = []
		for f in frontier:
			for slot in range(4):
				var nb := FacetAtlas.seam_neighbour(int(f), slot)
				if nb >= 0 and not hop.has(nb):
					hop[nb] = h
					next.append(nb)
		frontier = next
	var edge_nbs: Array = []
	for slot in range(4):
		edge_nbs.append(FacetAtlas.seam_neighbour(PFID, slot))
	print("active=%d edge-neighbours=%s" % [PFID, str(edge_nbs)])
	# --- classify the nearest distinct peaks ----------------------------------------------------------------------
	var reported: Array = []
	for e in best:
		var d: float = e[0]
		var close := false
		for r in reported:
			var dx: float = e[3] - r[0]
			var dy: float = e[4] - r[1]
			var dz2: float = e[5] - r[2]
			if dx * dx + dy * dy + dz2 * dz2 < 350.0 * 350.0:
				close = true
				break
		if close:
			continue
		reported.append([e[3], e[4], e[5]])
		var ofid := _owning_fid(e[3], e[4], e[5], hop)
		var oh: int = hop.get(ofid, -1)
		var lc := _sse_lc(d, deg_to_rad(75.0), 1080.0)
		var tier := clampi(int(floor(lc)), 1, 3)
		var v2 := oh >= 2 and oh <= 4
		print("peak d=%.0f g=%d biome=%d fid=%d hop=%d sse_lc=%.2f tier=l%d(pitch %d) smoothV2=%s nbfull=%s" % [
			d, e[1], e[2], ofid, oh, lc, tier, 1 << tier, str(v2), str(edge_nbs.has(ofid))])
		if reported.size() >= 12:
			break
	quit(0)

func _owning_fid(wx: float, wy: float, wz: float, hop: Dictionary) -> int:
	for fid in hop.keys():
		var l := FacetAtlas.world_to_lattice64(int(fid), wx, wy, wz)
		if FacetAtlas.in_polygon(int(fid), int(round(l[0])), int(round(l[2])), 0.0):
			return int(fid)
	return -1

func _sse_lc(d: float, fov_v_rad: float, viewport_h: float) -> float:
	var coeff := 2.0 * maxf(d, 1.0) * tan(fov_v_rad * 0.5) / maxf(viewport_h, 1.0)
	return log(CubeSphere.LOD_TAU_PX * coeff) / log(2.0)
