extends SceneTree
## probe_nearfill_protrude — MEASURE the #110 far-over-near protrusion on the repro facet.
## The C3 FP_SMOOTH_V2_NEARFILL tile linearly interpolates POINT-SAMPLED node heights at V2_CELLS=52
## (~8.02-block pitch) and sinks the whole tile a constant V2_NEARFILL_SINK=6 blocks. Wherever the fine
## surface between nodes dips more than 6 blocks below the interpolating chord, the smooth tile ends up
## ABOVE the near blocks and wins the depth test. This probe quantifies that: it rebuilds the node grid
## exactly as FarDensity.node_at / bake_smooth_tile do (byte-equal law), then samples the fine analytic
## surface at sub-cell pitch and reports chord-over-fine statistics for the whole facet and for the
## player window around lattice (13034, 8153) on facet 578 (the live screenshots fpro-0/fpro-1).
## READ-ONLY measurement tool — no engine/game code touched.

const FID := 578
const SINK := 6.0          # CubeSphere.V2_NEARFILL_SINK
const WIN_X := 13034       # player lattice x (NAV pos)
const WIN_Z := 8153        # player lattice z
const WIN_R := 72          # window half-extent (blocks)

func _initialize() -> void:
	print("=== probe_nearfill_protrude fid=%d cells=%d sink=%.1f ===" % [FID, CubeSphere.V2_CELLS, SINK])
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	var r_datum := FacetAtlas.r_of(FID)
	var cd := FacetAtlas.facet_corner_dirs(FID)
	var cells := int(CubeSphere.V2_CELLS)
	var stride := cells + 1
	print("  r_datum=%.2f sea=%d" % [r_datum, TerrainConfig.SEA_LEVEL])

	# --- 1. the node grid, exactly the tile's law (FarDensity.node_at == bake_smooth_tile byte-equal) ---
	var node_r := PackedFloat64Array()
	node_r.resize(stride * stride)
	var g_min := 1 << 30
	var g_max := -(1 << 30)
	for gj in range(stride):
		for gi in range(stride):
			var nd: Dictionary = FarDensity.node_at(cd, r_datum, float(gi) / float(cells), float(gj) / float(cells))
			node_r[gj * stride + gi] = r_datum + float(nd["relief"])
			g_min = mini(g_min, int(nd["g"]))
			g_max = maxi(g_max, int(nd["g"]))
	print("  node grid done: g range [%d..%d]" % [g_min, g_max])

	# --- 2. fine sampling at sub-cell pitch: chord-over-fine per sample ---
	var m := 4                       # sub-samples per cell edge (facet-wide pass, ~2-block pitch)
	var n_side := cells * m
	var worst := -1e9
	var worst_st := Vector2.ZERO
	var over0 := 0                   # samples where chord > fine (sink 0 would protrude)
	var over6 := 0                   # samples where chord - 6 > fine (LIVE protrusion)
	var over12 := 0                  # samples where chord - 12 > fine
	var total := 0
	var sum_pos := 0.0
	var w_worst := -1e9
	var w_over6 := 0
	var w_total := 0
	var w_worst_xz := Vector2i.ZERO
	for j in range(n_side + 1):
		var t := float(j) / float(n_side)
		for i in range(n_side + 1):
			var s := float(i) / float(n_side)
			var fine := _fine_r(cd, r_datum, s, t)
			var chord := _interp_r(node_r, stride, cells, s, t)
			var d := chord - fine          # chord-over-fine (blocks, radial)
			total += 1
			if d > 0.0:
				over0 += 1
				sum_pos += d
			if d > SINK:
				over6 += 1
			if d > 12.0:
				over12 += 1
			if d > worst:
				worst = d
				worst_st = Vector2(s, t)
			# player window bookkeeping (lattice coords of this sample)
			var nd := FarDensity.node_dir(cd, s, t)
			var wp := nd * float(r_datum)
			var lat: Array = FacetAtlas.world_to_lattice64(FID, wp.x, wp.y, wp.z)
			var lx := int(round(float(lat[0])))
			var lz := int(round(float(lat[2])))
			if absi(lx - WIN_X) <= WIN_R and absi(lz - WIN_Z) <= WIN_R:
				w_total += 1
				if d > SINK:
					w_over6 += 1
				if d > w_worst:
					w_worst = d
					w_worst_xz = Vector2i(lx, lz)
	print("  FACET-WIDE (pitch %.2f blk, %d samples):" % [417.0 / float(n_side), total])
	print("    chord-over-fine worst = %+.2f blk at st=%s" % [worst, str(worst_st)])
	print("    chord > fine        : %d (%.1f%%)  mean-over=%.2f" % [over0, 100.0 * over0 / total, (sum_pos / maxi(over0, 1))])
	print("    PROTRUDES (>%.0f)    : %d (%.1f%%)" % [SINK, over6, 100.0 * over6 / total])
	print("    would beat sink 12  : %d (%.1f%%)" % [over12, 100.0 * over12 / total])
	print("  PLAYER WINDOW (±%d @ %d,%d): %d samples, worst %+.2f blk at %s, protruding %d (%.1f%%)" % [
		WIN_R, WIN_X, WIN_Z, w_total, w_worst, str(w_worst_xz), w_over6, 100.0 * w_over6 / maxi(w_total, 1)])

	# --- 3. dense window pass at ~1-block pitch for the exact live view ---
	# find the (s,t) of the window centre by inverting via a coarse scan (cheap: reuse node_dir)
	var best_d := 1e18
	var c_s := 0.5
	var c_t := 0.5
	for j in range(0, n_side + 1):
		for i in range(0, n_side + 1):
			var s2 := float(i) / float(n_side)
			var t2 := float(j) / float(n_side)
			var nd2 := FarDensity.node_dir(cd, s2, t2)
			var wp2 := nd2 * float(r_datum)
			var lat2: Array = FacetAtlas.world_to_lattice64(FID, wp2.x, wp2.y, wp2.z)
			var dd := absf(float(lat2[0]) - float(WIN_X)) + absf(float(lat2[2]) - float(WIN_Z))
			if dd < best_d:
				best_d = dd
				c_s = s2
				c_t = t2
	var span := float(WIN_R) / 417.0
	var nn := WIN_R * 2               # ~1-block pitch
	var d_worst := -1e9
	var d_hist := [0, 0, 0, 0, 0, 0]  # >0, >2, >4, >6, >10, >15
	var d_total := 0
	for j in range(nn + 1):
		var t3 := clampf(c_t - span + 2.0 * span * float(j) / float(nn), 0.0, 1.0)
		for i in range(nn + 1):
			var s3 := clampf(c_s - span + 2.0 * span * float(i) / float(nn), 0.0, 1.0)
			var fine3 := _fine_r(cd, r_datum, s3, t3)
			var chord3 := _interp_r(node_r, stride, cells, s3, t3)
			var d3 := chord3 - fine3
			d_total += 1
			if d3 > 0.0: d_hist[0] += 1
			if d3 > 2.0: d_hist[1] += 1
			if d3 > 4.0: d_hist[2] += 1
			if d3 > SINK: d_hist[3] += 1
			if d3 > 10.0: d_hist[4] += 1
			if d3 > 15.0: d_hist[5] += 1
			d_worst = maxf(d_worst, d3)
	print("  DENSE WINDOW (~1-blk pitch, %d samples): worst %+.2f blk" % [d_total, d_worst])
	print("    over: >0 %.1f%%  >2 %.1f%%  >4 %.1f%%  >6(SINK) %.1f%%  >10 %.1f%%  >15 %.1f%%" % [
		100.0 * d_hist[0] / d_total, 100.0 * d_hist[1] / d_total, 100.0 * d_hist[2] / d_total,
		100.0 * d_hist[3] / d_total, 100.0 * d_hist[4] / d_total, 100.0 * d_hist[5] / d_total])
	print("=== probe_nearfill_protrude done ===")
	quit(0)

## Fine analytic surface radius along the (s,t) direction — the SAME profile law node_at samples, at full res.
func _fine_r(cd: PackedFloat64Array, r_datum: float, s: float, t: float) -> float:
	var nd := FarDensity.node_dir(cd, s, t)
	var prof := TerrainConfig.profile_at_dir(nd.x, nd.y, nd.z, r_datum)
	return r_datum + maxf(0.0, float(int(prof.x) - TerrainConfig.SEA_LEVEL))

## Radial height of the smooth tile surface at (s,t): the tile's OWN two-triangle split per cell
## (idx (v00,v10,v11)+(v01,v00,v11), facet_smooth_v2.gd:117-118), interpolated in node radii.
func _interp_r(node_r: PackedFloat64Array, stride: int, cells: int, s: float, t: float) -> float:
	var fs_all := s * float(cells)
	var ft_all := t * float(cells)
	var gi := clampi(int(floor(fs_all)), 0, cells - 1)
	var gj := clampi(int(floor(ft_all)), 0, cells - 1)
	var fs := fs_all - float(gi)
	var ft := ft_all - float(gj)
	var r00 := node_r[gj * stride + gi]
	var r10 := node_r[gj * stride + gi + 1]
	var r01 := node_r[(gj + 1) * stride + gi]
	var r11 := node_r[(gj + 1) * stride + gi + 1]
	if fs >= ft:
		return r00 + (r10 - r00) * fs + (r11 - r10) * ft   # tri A (v00,v10,v11)
	return r00 + (r01 - r00) * ft + (r11 - r01) * fs       # tri B (v01,v00,v11)
