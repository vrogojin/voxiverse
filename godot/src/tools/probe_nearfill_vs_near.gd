extends SceneTree
## probe_nearfill_vs_near — #110 discriminator #2. Probe 1 (probe_nearfill_protrude) proved the smooth
## tile's chord sits within +1.25 blk of the ANALYTIC profile_at_dir surface (sink 6 covers it). So if
## the tile still protrudes over the NEAR blocks, the gap must be between profile_at_dir(dir) and what
## the near voxel gen (TerrainConfig.generated_block, lattice space) actually realizes at the same
## columns. This measures, per lattice column in the player window on facet 578:
##   near_r  = |lattice_to_world64(x+.5, y_top+1, z+.5)|   (top face of the topmost generated solid)
##   tile_r  = triangle-interp of the FarDensity.node_at node radii at that column's (s,t)  −  SINK
##   prof_r  = r_datum + max(0, profile_at_dir(dir)−SEA)   (the analytic far law, for decomposition)
## and reports tile-over-near (the LIVE protrusion) split into interp error (tile+SINK − prof) and the
## near-law gap (prof − near). READ-ONLY measurement tool.

const FID := 578
const SINK := 6.0
const WIN_X := 13034
const WIN_Z := 8153
const WIN_R := 72

var _cd: PackedFloat64Array
var _r_datum: float
var _cells: int
var _stride: int
var _node_r: PackedFloat64Array
# lattice corners of the facet (v00, v10, v11, v01) for the (x,z) -> (s,t) inversion
var _l00 := Vector2.ZERO
var _l10 := Vector2.ZERO
var _l11 := Vector2.ZERO
var _l01 := Vector2.ZERO

func _initialize() -> void:
	print("=== probe_nearfill_vs_near fid=%d sink=%.1f ===" % [FID, SINK])
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	TerrainConfig.set_active_facet(FID)
	_r_datum = FacetAtlas.r_of(FID)
	_cd = FacetAtlas.facet_corner_dirs(FID)
	_cells = int(CubeSphere.V2_CELLS)
	_stride = _cells + 1
	_node_r = PackedFloat64Array()
	_node_r.resize(_stride * _stride)
	for gj in range(_stride):
		for gi in range(_stride):
			var nd: Dictionary = FarDensity.node_at(_cd, _r_datum, float(gi) / float(_cells), float(gj) / float(_cells))
			_node_r[gj * _stride + gi] = _r_datum + float(nd["relief"])
	# facet corner lattice coords (invert (x,z) -> (s,t) via bilinear on these)
	_l00 = _corner_lat(0)
	_l10 = _corner_lat(1)
	_l11 = _corner_lat(2)
	_l01 = _corner_lat(3)
	print("  corners lattice: v00=%s v10=%s v11=%s v01=%s" % [str(_l00), str(_l10), str(_l11), str(_l01)])
	# sanity: (s,t) inversion round-trip at window centre
	var st0 := _st_of(float(WIN_X) + 0.5, float(WIN_Z) + 0.5)
	var d0 := FarDensity.node_dir(_cd, st0.x, st0.y)
	var wp0 := d0 * _r_datum
	var lat0: Array = FacetAtlas.world_to_lattice64(FID, wp0.x, wp0.y, wp0.z)
	print("  st(%d,%d)=%s roundtrip lattice=(%.2f, %.2f)" % [WIN_X, WIN_Z, str(st0), float(lat0[0]), float(lat0[2])])

	var worst := -1e9
	var worst_col := Vector2i.ZERO
	var worst_parts := Vector3.ZERO
	var n_over := 0
	var n_tot := 0
	var sum_gap := 0.0
	var hist := [0, 0, 0, 0, 0]   # tile-over-near: >0, >2, >6, >10, >15
	var examples := 0
	for z in range(WIN_Z - WIN_R, WIN_Z + WIN_R + 1, 2):
		for x in range(WIN_X - WIN_R, WIN_X + WIN_R + 1, 2):
			var y_top := _top_solid(x, z)
			if y_top < 0:
				continue
			var wtop: Array = FacetAtlas.lattice_to_world64(FID, float(x) + 0.5, float(y_top + 1), float(z) + 0.5)
			var near_r := sqrt(float(wtop[0]) * float(wtop[0]) + float(wtop[1]) * float(wtop[1]) + float(wtop[2]) * float(wtop[2]))
			var st := _st_of(float(x) + 0.5, float(z) + 0.5)
			var tile_r := _interp_r(st.x, st.y) - SINK
			var d := FarDensity.node_dir(_cd, st.x, st.y)
			var prof := TerrainConfig.profile_at_dir(d.x, d.y, d.z, _r_datum)
			var prof_r := _r_datum + maxf(0.0, float(int(prof.x) - TerrainConfig.SEA_LEVEL))
			var over := tile_r - near_r          # LIVE protrusion (blocks radial; >0 = tile above near surface)
			var interp_err := (tile_r + SINK) - prof_r
			var law_gap := prof_r - near_r       # analytic far law vs realized near surface
			n_tot += 1
			sum_gap += law_gap
			if over > 0.0:
				n_over += 1
				hist[0] += 1
				if over > 2.0: hist[1] += 1
				if over > 6.0: hist[2] += 1
				if over > 10.0: hist[3] += 1
				if over > 15.0: hist[4] += 1
			if over > worst:
				worst = over
				worst_col = Vector2i(x, z)
				worst_parts = Vector3(interp_err, law_gap, float(y_top))
			if examples < 6 and (x % 24 == 0 and z % 24 == 0):
				examples += 1
				print("    col(%d,%d): y_top=%d near_r=%.2f prof_g=%d prof_r=%.2f tile_r(sunk)=%.2f over=%+.2f law_gap=%+.2f" % [
					x, z, y_top, near_r, int(prof.x), prof_r, tile_r, over, law_gap])
	print("  WINDOW ±%d @ (%d,%d), %d cols:" % [WIN_R, WIN_X, WIN_Z, n_tot])
	print("    tile-over-near worst = %+.2f blk at %s (interp_err=%+.2f, law_gap=%+.2f, y_top=%d)" % [
		worst, str(worst_col), worst_parts.x, worst_parts.y, int(worst_parts.z)])
	print("    protruding cols: %d/%d (%.1f%%)  [>2: %d  >6: %d  >10: %d  >15: %d]" % [
		n_over, n_tot, 100.0 * n_over / maxi(n_tot, 1), hist[1], hist[2], hist[3], hist[4]])
	print("    mean law_gap (prof_r - near_r) = %+.2f blk" % (sum_gap / maxi(n_tot, 1)))
	print("=== probe_nearfill_vs_near done ===")
	quit(0)

func _corner_lat(k: int) -> Vector2:
	var d := Vector3(_cd[k * 3], _cd[k * 3 + 1], _cd[k * 3 + 2]).normalized()
	var wp := d * _r_datum
	var lat: Array = FacetAtlas.world_to_lattice64(FID, wp.x, wp.y, wp.z)
	return Vector2(float(lat[0]), float(lat[2]))

## (x,z) lattice -> (s,t) in the corner quad. The corner lattice quad is (near-)axis-aligned; use the
## general bilinear inverse via two 1D solves along each axis pair (adequate for an affine/rect quad).
func _st_of(x: float, z: float) -> Vector2:
	# assume rectangle: v00..v10 spans s along lattice x (or z); detect axis from corners
	var sx := _l10 - _l00
	var tz := _l01 - _l00
	var p := Vector2(x, z) - _l00
	# solve p = s*sx + t*tz  (2x2 linear system — exact for an affine quad)
	var det := sx.x * tz.y - sx.y * tz.x
	if absf(det) < 1e-9:
		return Vector2(0.5, 0.5)
	var s := (p.x * tz.y - p.y * tz.x) / det
	var t := (sx.x * p.y - sx.y * p.x) / det
	return Vector2(clampf(s, 0.0, 1.0), clampf(t, 0.0, 1.0))

func _top_solid(x: int, z: int) -> int:
	for y in range(140, -1, -1):
		if TerrainConfig.generated_block(x, y, z) != 0:
			return y
	return -1

func _interp_r(s: float, t: float) -> float:
	var fs_all := s * float(_cells)
	var ft_all := t * float(_cells)
	var gi := clampi(int(floor(fs_all)), 0, _cells - 1)
	var gj := clampi(int(floor(ft_all)), 0, _cells - 1)
	var fs := fs_all - float(gi)
	var ft := ft_all - float(gj)
	var r00 := _node_r[gj * _stride + gi]
	var r10 := _node_r[gj * _stride + gi + 1]
	var r01 := _node_r[(gj + 1) * _stride + gi]
	var r11 := _node_r[(gj + 1) * _stride + gi + 1]
	if fs >= ft:
		return r00 + (r10 - r00) * fs + (r11 - r10) * ft
	return r00 + (r01 - r00) * ft + (r11 - r01) * fs
