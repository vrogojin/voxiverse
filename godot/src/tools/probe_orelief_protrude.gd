extends SceneTree
## probe_orelief_protrude — #110: quantify the FacetOrbitRelief (G3) interior chord-over-fine excess on
## facet 578's player window. G3 tiles are UN-SUNK exact profile_at_dir chords at GlobalReliefData.CELLS=32
## (~13-block pitch) (facet_orbit_relief.gd:276-290), frozen-visible on-surface (:613-645). Anywhere the
## chord exceeds the fine analytic surface, the mesh sits ABOVE the near blocks (whose realized top face is
## already ~0.6 blk BELOW profile g, and up to ~3.6 blk below on sharp-slope carve columns) and wins depth.
## Reports chord-over-fine at 32 cells (G3, sink 0) side-by-side with 52 cells - 6 (SmoothV2 near-fill).

const FID := 578
const WIN_X := 13034
const WIN_Z := 8153
const WIN_R := 72

func _initialize() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	var r_datum := FacetAtlas.r_of(FID)
	var cd := FacetAtlas.facet_corner_dirs(FID)
	print("=== probe_orelief_protrude fid=%d (G3 cells=32 sink=0 vs V2 cells=52 sink=6) ===" % FID)
	var g3 := _node_grid(cd, r_datum, 32)
	var v2 := _node_grid(cd, r_datum, 52)
	# centre (s,t) of the window via corner-lattice affine inversion
	var l00 := _corner_lat(cd, r_datum, 0)
	var l10 := _corner_lat(cd, r_datum, 1)
	var l01 := _corner_lat(cd, r_datum, 3)
	var sx := l10 - l00
	var tz := l01 - l00
	var det := sx.x * tz.y - sx.y * tz.x
	var p := Vector2(float(WIN_X) + 0.5, float(WIN_Z) + 0.5) - l00
	var c_s := clampf((p.x * tz.y - p.y * tz.x) / det, 0.0, 1.0)
	var c_t := clampf((sx.x * p.y - sx.y * p.x) / det, 0.0, 1.0)
	print("  window centre st=(%.4f, %.4f)" % [c_s, c_t])
	var span := float(WIN_R) / 417.0
	var nn := WIN_R * 2
	var g3_worst := -1e9
	var v2_worst := -1e9
	var g3_hist := [0, 0, 0, 0]   # >0, >2, >4, >6
	var v2_hist := [0, 0, 0, 0]
	var total := 0
	var g3_sum := 0.0
	for j in range(nn + 1):
		var t := clampf(c_t - span + 2.0 * span * float(j) / float(nn), 0.0, 1.0)
		for i in range(nn + 1):
			var s := clampf(c_s - span + 2.0 * span * float(i) / float(nn), 0.0, 1.0)
			var nd := FarDensity.node_dir(cd, s, t)
			var prof := TerrainConfig.profile_at_dir(nd.x, nd.y, nd.z, r_datum)
			var fine := r_datum + maxf(0.0, float(int(prof.x) - TerrainConfig.SEA_LEVEL))
			var d3 := _interp_r(g3, 32, s, t) - fine            # G3: UN-SUNK
			var d2 := (_interp_r(v2, 52, s, t) - 6.0) - fine    # V2 near-fill: sunk 6
			total += 1
			if d3 > 0.0: g3_hist[0] += 1
			if d3 > 2.0: g3_hist[1] += 1
			if d3 > 4.0: g3_hist[2] += 1
			if d3 > 6.0: g3_hist[3] += 1
			if d2 > 0.0: v2_hist[0] += 1
			if d2 > 2.0: v2_hist[1] += 1
			if d3 > 0.0: g3_sum += d3
			g3_worst = maxf(g3_worst, d3)
			v2_worst = maxf(v2_worst, d2)
	print("  G3 orbit-relief chord-over-fine (%d samples): worst %+.2f  over: >0 %.1f%%  >2 %.1f%%  >4 %.1f%%  >6 %.1f%%  mean-over %.2f" % [
		total, g3_worst, 100.0 * g3_hist[0] / total, 100.0 * g3_hist[1] / total, 100.0 * g3_hist[2] / total,
		100.0 * g3_hist[3] / total, g3_sum / maxi(g3_hist[0], 1)])
	print("  V2 near-fill (sunk 6) same samples: worst %+.2f  over: >0 %.1f%%  >2 %.1f%%" % [
		v2_worst, 100.0 * v2_hist[0] / total, 100.0 * v2_hist[1] / total])
	print("  (near realized top face is ~0.6 blk BELOW fine profile; sharp-slope carve columns up to ~3.6 below")
	print("   => G3 protrusion over the near mesh ~= the >0 numbers above SHIFTED +0.6..+3.6 further above)")
	print("=== probe_orelief_protrude done ===")
	quit(0)

func _node_grid(cd: PackedFloat64Array, r_datum: float, cells: int) -> PackedFloat64Array:
	var stride := cells + 1
	var out := PackedFloat64Array()
	out.resize(stride * stride)
	for gj in range(stride):
		for gi in range(stride):
			var nd: Dictionary = FarDensity.node_at(cd, r_datum, float(gi) / float(cells), float(gj) / float(cells))
			out[gj * stride + gi] = r_datum + float(nd["relief"])
	return out

func _corner_lat(cd: PackedFloat64Array, r: float, k: int) -> Vector2:
	var d := Vector3(cd[k * 3], cd[k * 3 + 1], cd[k * 3 + 2]).normalized()
	var wp := d * r
	var lat: Array = FacetAtlas.world_to_lattice64(FID, wp.x, wp.y, wp.z)
	return Vector2(float(lat[0]), float(lat[2]))

func _interp_r(node_r: PackedFloat64Array, cells: int, s: float, t: float) -> float:
	var stride := cells + 1
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
	# G3 grid splits (v00,v10,v11)+(v00,v11,v01) (facet_orbit_relief.gd:271-272) — same diagonal as V2
	if fs >= ft:
		return r00 + (r10 - r00) * fs + (r11 - r10) * ft
	return r00 + (r01 - r00) * ft + (r11 - r01) * fs
