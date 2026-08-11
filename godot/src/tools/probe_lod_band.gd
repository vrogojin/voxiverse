extends SceneTree
## PROBE (task #107, read-only): pin the repro geometry for the blocky-mountain LOD band.
## Player world BCI ~[-5606,1395,-2795] on facet 772 (NAV lattice -30970,50,7161, alt 47).
## Prints: active fid check, player lattice, facet edge/far-ring cell pitch, seam distances,
## peaks within 1200 blocks (owner fid + hop + distance), SmoothV2 annulus membership,
## M2 SSE desired tier for each hop-1 facet at the live camera geometry.

const PX := -5606.0
const PY := 1395.0
const PZ := -2795.0

func _init() -> void:
	FacetAtlas.warm_up()
	var d := CubeSphere.DVec3.new(PX, PY, PZ)
	var l := d.length()
	var nd := CubeSphere.DVec3.new(PX / l, PY / l, PZ / l)
	var fid := FacetAtlas.facet_of_dir(nd)
	print("player |p|=", l, " facet_of_dir=", fid)
	var lat := FacetAtlas.world_to_lattice64(fid, PX, PY, PZ)
	print("player lattice in fid ", fid, ": ", lat)
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var ew := dmax.x - dmin.x + 1
	var eh := dmax.y - dmin.y + 1
	print("dom ", dmin, "..", dmax, "  edge cells ", ew, "x", eh,
		"  far-ring cell pitch = edge/CELLS(4) = ", float(ew) / 4.0, " blocks")
	for slot in range(4):
		var od := FacetAtlas.own_dist(fid, slot, lat[0], lat[1], lat[2])
		print("  seam slot ", slot, " -> nb ", FacetAtlas.seam_neighbour(fid, slot),
			"  own_dist ", "%.1f" % od)
	# hop map (BFS depth 2)
	var hop := {fid: 0}
	var frontier := [fid]
	for h in range(1, 3):
		var nxt := []
		for f in frontier:
			for s in range(4):
				var nb := FacetAtlas.seam_neighbour(int(f), s)
				if nb >= 0 and not hop.has(nb):
					hop[nb] = h
					nxt.append(nb)
		frontier = nxt
	# peak scan over hop<=2 facets
	var peaks := []   # [g, dist, f, x, z, biome]
	for f in hop.keys():
		var a := FacetAtlas.dom_min(int(f))
		var b := FacetAtlas.dom_max(int(f))
		for z in range(a.y, b.y + 1, 3):
			for x in range(a.x, b.x + 1, 3):
				var prof := TerrainConfig.facet_profile(int(f), x, z)
				var g := prof.x
				if g < 60.0:
					continue
				var w := FacetAtlas.lattice_to_world64(int(f), float(x), g, float(z))
				var dx: float = w[0] - PX
				var dy: float = w[1] - PY
				var dz: float = w[2] - PZ
				var dist := sqrt(dx * dx + dy * dy + dz * dz)
				if dist <= 1200.0:
					peaks.append([g, dist, int(f), x, z, int(prof.y)])
	peaks.sort_custom(func(p, q): return p[0] > q[0])
	print("peaks g>=60 within 1200 blocks (top 12): [g, dist, fid(hop), x, z, biome]")
	for i in range(mini(12, peaks.size())):
		var p: Array = peaks[i]
		print("  g=", "%.0f" % p[0], " dist=", "%.0f" % p[1], " fid=", p[2],
			"(hop ", hop.get(p[2], -1), ") cell(", p[3], ",", p[4], ") biome=", p[5])
	# SmoothV2 annulus membership for the live config (hop_b=2, hop_h=4 with REACH)
	var ann := FacetSmoothV2.hop_annulus(fid, CubeSphere.V2_HOP_B, CubeSphere.V2_HOP_H_REACH)
	var near_facets := [fid]
	for s in range(4):
		near_facets.append(FacetAtlas.seam_neighbour(fid, s))
	for f in near_facets:
		print("SmoothV2 annulus (hop 2..4) contains fid ", f, "? ", ann.has(f))
	print("annulus size=", ann.size())
	# M2 SSE desired tier at the hop-1 facet centres (fov 75 deg, viewport 540 px — live capture geometry)
	var fov := deg_to_rad(75.0)
	var vh := 540.0
	for s in range(4):
		var nb2 := FacetAtlas.seam_neighbour(fid, s)
		var cc := FacetAtlas.centre_cell(nb2)
		var w2 := FacetAtlas.lattice_to_world64(nb2, float(cc.x), 0.0, float(cc.y))
		var dx2: float = w2[0] - PX
		var dy2: float = w2[1] - PY
		var dz2: float = w2[2] - PZ
		var dist2 := sqrt(dx2 * dx2 + dy2 * dy2 + dz2 * dz2)
		var lc := log(CubeSphere.LOD_TAU_PX * 2.0 * dist2 * tan(fov * 0.5) / vh) / log(2.0)
		var des := clampi(int(floor(lc)), 1, 3)
		print("hop-1 fid ", nb2, " centre dist ", "%.0f" % dist2,
			"  sse lc=", "%.2f" % lc, " desired tier ", des, " (pinned l1 by A2)")
	quit(0)
