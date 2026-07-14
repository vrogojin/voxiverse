extends SceneTree
## STANDALONE far-vs-near worldgen-consistency DIAGNOSTIC (task: "far renders water where near
## generates sand"). NOT a game-src file — no production code imports it; it only READS the frozen
## FacetAtlas + TerrainConfig pure statics, so it needs neither the godot_voxel module nor FACETED=true
## (facet_profile / profile_at_dir are flag-independent pure functions of (SEED, fid, x, z)). Run:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_far_near.gd
##
## It compares, over a facet's interior surface columns, the NEAR generator's water/land classification
## (the ground truth both render paths share) against each FAR layer's derived classification, and reports
## the count + magnitude of disagreements. Two independent effects are isolated:
##
##   METRIC 1  CLASSIFIER OFF-BY-ONE (resolution-independent RULE bug). NEAR opens water at a column iff
##             g < SEA_LEVEL (the sea fill runs g < y <= SEA_LEVEL; at g == SEA_LEVEL the top is a dry/
##             beach-sand solid cell). Every FAR layer instead tests `g <= SEA_LEVEL` (facet_far_ring.gd:177,
##             facet_lod_builder.gd:246-247 apron, via FarPalette.color_for's clamped_sea arg). At the SAME
##             height g the two verdicts differ exactly on the g == SEA_LEVEL contour — the far layer paints
##             WATER where near renders LAND. This is a genuine, byte-safe-to-fix bug.
##
##   METRIC 2  COARSE FAR-RING ALIASING (the "whole water body" amplifier). FacetFarRing samples g on only a
##             CELLS+1 (=5) grid across a ~200-block facet — one height sample per ~50 blocks — then classifies
##             + colours per vertex. Modelled faithfully here in lattice space: a coarse (CELLS+1)² grid of g
##             over the facet domain, bilinearly interpolated, classified `coarse_g <= SEA_LEVEL`. Compared
##             against the per-column near verdict this shows how a single sub-sea-level coarse sample floods a
##             whole ~50×50-block quad blue over near sand. The largest contiguous far=water / near=sand region
##             is reported as the "water body" size. Re-run with the proposed fix (strict `< SEA_LEVEL`) shows
##             the reduction attributable to the rule bug alone.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

const CELLS := 4                     # == FacetFarRing.CELLS (far-ring heightmap cells per facet edge)

func _initialize() -> void:
	print("=== verify_far_near (far-vs-near water/sand consistency) ===")
	TC.warm_up()
	FA.warm_up()
	FarPalette.ensure_ready()
	var sea := TC.SEA_LEVEL
	var spawn: int = FA.spawn_facet()
	print("  atlas: %d facets (k=%d, R=%d, edge~%d blocks), SEA_LEVEL=%d, far-ring CELLS=%d"
		% [FA.facet_count(), FA.K, int(FA.R_BLOCKS), int((PI / 2.0 * FA.R_BLOCKS) / FA.K), sea, CELLS])

	# Sample a spread of facets: the spawn facet + a coastal-ish mix across faces so the numbers are not one
	# lucky patch. (A pole facet is near-frozen, an equatorial one temperate — both have shorelines.)
	# g-range census across the whole planet: find where the shoreline (g crossing SEA_LEVEL) actually lives.
	var gmin := 0x7fffffff
	var gmax := -0x7fffffff
	var under := 0
	var at_sea := 0
	var census := 0
	var shoreline_facets: Array = []
	for fid in range(0, FA.facet_count(), 37):     # a strided census (~93 facets) — cheap planet-wide sample
		var cc: Vector2i = FA.centre_cell(fid)
		var uc := 0
		var lc := 0
		for dz in range(-40, 41, 8):
			for dx in range(-40, 41, 8):
				var g := int(TC.facet_profile(fid, cc.x + dx, cc.y + dz).x)
				census += 1
				gmin = mini(gmin, g); gmax = maxi(gmax, g)
				if g < sea: under += 1; uc += 1
				elif g == sea: at_sea += 1
				else: lc += 1
		if uc > 0 and lc > 0 and shoreline_facets.size() < 8:
			shoreline_facets.append(fid)        # a facet that straddles the shore
	print("  g census (%d samples): min=%d max=%d  under-sea=%d (%.1f%%)  at-sea=%d  shoreline-straddling facets=%s"
		% [census, gmin, gmax, under, 100.0 * float(under) / maxf(1.0, float(census)), at_sea, str(shoreline_facets)])

	var facets := [spawn, 0, 100, 800, 1728, 2000, 3000, 3455]
	for sf in shoreline_facets:
		facets.append(sf)
	var seen := {}
	var tot_cols := 0
	var tot_obo := 0            # METRIC 1: near land (g==sea) but far <= says water
	var tot_alias := 0         # METRIC 2: coarse far verdict != near per-column verdict
	var tot_alias_water_over_land := 0   # far=water, near=land (the reported symptom)
	var tot_alias_water_over_sand := 0   # ...and near land is specifically beach/desert SAND
	var tot_alias_fixed := 0   # METRIC 2 with the proposed strict-`<` fix
	var worst_body := 0
	var worst_body_fid := -1

	for fid in facets:
		if seen.has(fid):
			continue
		seen[fid] = true
		var r := _scan_facet(fid, sea)
		tot_cols += int(r["cols"])
		tot_obo += int(r["obo"])
		tot_alias += int(r["alias"])
		tot_alias_water_over_land += int(r["wol"])
		tot_alias_water_over_sand += int(r["wos"])
		tot_alias_fixed += int(r["alias_fixed"])
		if int(r["body"]) > worst_body:
			worst_body = int(r["body"]); worst_body_fid = fid
		print("  facet %4d: cols=%d  offbyone(g==sea)=%d (%.2f%%)  coarse-alias=%d (%.2f%%)  water-over-sand=%d  largest-body=%d cells"
			% [fid, int(r["cols"]), int(r["obo"]), 100.0 * float(r["obo"]) / maxf(1.0, float(r["cols"])),
			   int(r["alias"]), 100.0 * float(r["alias"]) / maxf(1.0, float(r["cols"])),
			   int(r["wos"]), int(r["body"])])

	print("")
	print("  ==== SUMMARY over %d facets, %d surface columns ====" % [seen.size(), tot_cols])
	print("  METRIC 1  classifier off-by-one (g == SEA_LEVEL, near LAND vs far WATER): %d cols (%.3f%% of surface)"
		% [tot_obo, 100.0 * float(tot_obo) / maxf(1.0, float(tot_cols))])
	print("  METRIC 2  coarse far-ring mismatch vs near per-column:                    %d cols (%.3f%%)"
		% [tot_alias, 100.0 * float(tot_alias) / maxf(1.0, float(tot_cols))])
	print("            of which far=WATER over near=LAND: %d   (near land is SAND: %d)"
		% [tot_alias_water_over_land, tot_alias_water_over_sand])
	print("            same coarse metric with proposed strict `< SEA_LEVEL` fix:      %d cols (%.3f%%)  [rule-bug share removed]"
		% [tot_alias_fixed, 100.0 * float(tot_alias_fixed) / maxf(1.0, float(tot_cols))])
	print("  largest contiguous far=WATER / near=LAND region: %d cells on facet %d (the visible 'water body')"
		% [worst_body, worst_body_fid])
	print("==== done ====")
	quit(0)

## Scan one facet's interior surface columns. Returns the per-facet tallies used by the summary.
func _scan_facet(fid: int, sea: int) -> Dictionary:
	var dmn: Vector2i = FA.dom_min(fid)
	var dmx: Vector2i = FA.dom_max(fid)
	var nx := dmx.x - dmn.x
	var nz := dmx.y - dmn.y
	if nx <= 0 or nz <= 0:
		return {"cols": 0, "obo": 0, "alias": 0, "wol": 0, "wos": 0, "alias_fixed": 0, "body": 0}

	# Coarse far-ring height grid: (CELLS+1)² samples of near g across the facet's lattice domain, exactly the
	# ~50-block sampling FacetFarRing._ensure_cached does (near g == the ring's profile_at_dir g to f32; the ring
	# samples a bilerp-of-planar-corners direction, this samples the true cell_dir — same surface, ≤0.1% arc/chord).
	var grid := []                   # (CELLS+1)² of g (float)
	grid.resize((CELLS + 1) * (CELLS + 1))
	for gj in range(CELLS + 1):
		for gi in range(CELLS + 1):
			var cx := dmn.x + int(round(float(gi) / float(CELLS) * float(nx)))
			var cz := dmn.y + int(round(float(gj) / float(CELLS) * float(nz)))
			grid[gj * (CELLS + 1) + gi] = float(TC.facet_profile(fid, cx, cz).x)

	var cols := 0
	var obo := 0
	var alias := 0
	var wol := 0
	var wos := 0
	var alias_fixed := 0
	# Mismatch grid for the contiguous-body flood fill (1 = far=water over near=land, else 0), lattice-indexed.
	var mm := PackedByteArray()
	mm.resize((nx + 1) * (nz + 1))

	for z in range(dmn.y, dmx.y + 1):
		for x in range(dmn.x, dmx.x + 1):
			if not FA.in_polygon(fid, x, z, -1.0):
				continue                      # interior only (skip the seam fringe)
			cols += 1
			var prof := TC.facet_profile(fid, x, z)
			var g := int(prof.x)
			var biome := int(prof.y)
			var near_water := g < sea         # NEAR ground truth: open water at this column's surface
			var far_full := g <= sea          # FAR classifier at full res (the `<=` rule) — isolates the off-by-one
			if far_full != near_water:
				obo += 1                       # exactly the g == sea contour

			# METRIC 2: the coarse far-ring verdict. The far ring makes a PER-VERTEX water decision with the
			# integer rule `g_vertex <= sea` and interpolates the resulting vertex COLOURS across the ~50-block
			# quad, so a fine column reads as the water/land class of the nearest coarse grid vertex. Modelled
			# by snapping to that vertex (integer g) rather than float-interpolating height.
			var fx := float(x - dmn.x) / float(nx) * float(CELLS)
			var fz := float(z - dmn.y) / float(nz) * float(CELLS)
			var gi_n := clampi(int(round(fx)), 0, CELLS)
			var gj_n := clampi(int(round(fz)), 0, CELLS)
			var vg := int(round(grid[gj_n * (CELLS + 1) + gi_n]))   # integer g at the nearest far-ring vertex
			var far_coarse_water := vg <= sea                       # far ring's `g <= sea` per-vertex rule
			var far_coarse_fixed := vg < sea                        # proposed strict-`<` fix, same coarse vertex
			if far_coarse_water != near_water:
				alias += 1
				if far_coarse_water and not near_water:
					wol += 1
					mm[(z - dmn.y) * (nx + 1) + (x - dmn.x)] = 1
					if _near_surface_is_sandy(x, z, g, biome, prof.z, prof.w):
						wos += 1
			if far_coarse_fixed != near_water:
				alias_fixed += 1

	var body := _largest_region(mm, nx + 1, nz + 1)
	return {"cols": cols, "obo": obo, "alias": alias, "wol": wol, "wos": wos, "alias_fixed": alias_fixed, "body": body}

## Is the NEAR surface cell at this column a sand-family block (sand/red_sand/gravel — what the user sees as
## "sand")? Resolves the ACTUAL top cell through the shared resolve_cell so it is exactly what the near voxel
## world renders — no biome guessing. Pure analytic path (pcache=null); no _active_facet dependence.
func _near_surface_is_sandy(x: int, z: int, g: int, biome: int, c: float, t: float) -> bool:
	var v := TC.resolve_cell(x, g, z, g, biome, c, t)
	var mat := CellCodec.mat(v)
	return mat == BlockCatalog.id_of(&"sand") or mat == BlockCatalog.id_of(&"red_sand") \
		or mat == BlockCatalog.id_of(&"gravel")

## Largest 4-connected region of set cells in a w×h bitmap (iterative flood fill) — the "water body" size.
func _largest_region(mm: PackedByteArray, w: int, h: int) -> int:
	var best := 0
	var visited := PackedByteArray()
	visited.resize(w * h)
	var stack: Array = []
	for start in range(w * h):
		if mm[start] == 0 or visited[start] == 1:
			continue
		var size := 0
		stack.clear()
		stack.append(start)
		visited[start] = 1
		while not stack.is_empty():
			var idx: int = stack.pop_back()
			size += 1
			var cx := idx % w
			var cy := idx / w
			for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var ax: int = cx + d[0]
				var ay: int = cy + d[1]
				if ax < 0 or ay < 0 or ax >= w or ay >= h:
					continue
				var ni := ay * w + ax
				if mm[ni] == 1 and visited[ni] == 0:
					visited[ni] = 1
					stack.append(ni)
		if size > best:
			best = size
	return best
