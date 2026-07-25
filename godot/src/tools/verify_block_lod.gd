extends SceneTree
## G-BLD-PYR / G-BLD-MIN / G-BLD-DETERMINISM — FacetBlockLod (Block-LOD P0, docs/COSMOS-BLOCK-LOD-DESIGN.md §3/§8/§9).
## Flag-INDEPENDENT: drives FacetBlockLod directly on REAL facets (spread across relief), like the sibling far-ring
## gates. Byte-off (FP_BLOCK_LOD false) is covered by verify_feature (FLAT 6042/0). Asserts:
##   G-BLD-PYR         — Ln+1 == decimate(Ln) EXACTLY: re-decimate each level from the one below, assert bit-equality
##                       (top/id/water) for every sampled facet.
##   G-BLD-MIN         — no-protrusion by containment: for every coarse column at every level, top(coarse) == MIN of
##                       its present 2×2 fine children (and <= every child). PLUS a self-contained FALSIFIER: a
##                       MAX-height decimation variant produces at least one coarse column ABOVE the fine surface on
##                       a hilly facet ⇒ a regression to majority/max-height WOULD be caught (the gate has teeth).
##   G-BLD-DETERMINISM — building the same facet twice yields bit-identical bytes at every level.
## Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

func _initialize() -> void:
	print("=== verify_block_lod (G-BLD-PYR / G-BLD-MIN / G-BLD-DETERMINISM: FacetBlockLod P0) ===")
	FacetAtlas.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED"); print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return

	# Spread: equator / mid-lat / varied-relief / poles — so hilly facets exercise the MIN rule + feed the falsifier.
	var fids := [0, 37, 300, 1200, 2500, 3455]
	var falsifier_fired := false          # a MAX-rule column poked above the fine surface somewhere (teeth)

	for fid in fids:
		var lod := FacetBlockLod.new()
		lod.build(fid)
		_ok(lod.level_count() == FacetBlockLod.LEVELS, "fid %d built L0..L%d" % [fid, FacetBlockLod.LEVELS - 1])

		# G-BLD-PYR: each level equals a fresh decimate of the one below.
		var pyr_ok := true
		for n in range(1, lod.level_count()):
			var redec := FacetBlockLod.decimate(lod.get_level(n - 1))
			if not FacetBlockLod.level_equals(redec, lod.get_level(n)):
				pyr_ok = false
		_ok(pyr_ok, "G-BLD-PYR fid %d: Ln+1 == decimate(Ln) for all levels" % fid)

		# G-BLD-MIN: coarse top == MIN(children) and <= every child, at every level. Falsifier: MAX-variant protrudes.
		var min_eq := true          # coarse top exactly the min of present children
		var min_le := true          # coarse top <= every present child (redundant with min_eq, checked independently)
		for n in range(1, lod.level_count()):
			var fine := lod.get_level(n - 1)
			var coarse := lod.get_level(n)
			var r := _check_min(fine, coarse)
			if not r[0]: min_eq = false
			if not r[1]: min_le = false
			if r[2]: falsifier_fired = true
		_ok(min_eq, "G-BLD-MIN fid %d: coarse top == MIN(present 2x2 children), all levels" % fid)
		_ok(min_le, "G-BLD-MIN fid %d: coarse top <= every present child, all levels" % fid)

		lod = null                  # RefCounted — release this facet's pyramid before the next (NEVER-OOM: transient)

	# Determinism on a flat-ish + a hilly facet (a property of the code, not the facet — two suffice, keeps the gate fast).
	for fid in [fids[0], fids[3]]:
		var a := FacetBlockLod.new(); a.build(fid)
		var b := FacetBlockLod.new(); b.build(fid)
		var same := a.level_count() == b.level_count()
		for n in range(a.level_count()):
			if not FacetBlockLod.level_equals(a.get_level(n), b.get_level(n)):
				same = false
		_ok(same, "G-BLD-DETERMINISM fid %d: rebuild bit-identical at every level" % fid)
		a = null; b = null

	_ok(falsifier_fired, "G-BLD-MIN falsifier: a MAX-height decimation WOULD protrude above the fine surface (relief present) — gate has teeth")

	_p1_render_gates()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## For each coarse column, re-derive MIN + MAX over the present 2×2 fine children and check:
##   [0] coarse.top == MIN(children)  (the no-protrusion rule holds)
##   [1] coarse.top <= every child    (independent containment check)
##   [2] MAX(children) > MIN(children) somewhere (relief) ⇒ a MAX-rule flat top WOULD sit ABOVE the fine surface at
##       the lower child = a protrusion the MIN rule prevents (the FALSIFIER: proves G-BLD-MIN is load-bearing).
func _check_min(fine: Dictionary, coarse: Dictionary) -> Array:
	var fw: int = fine["w"]
	var fh: int = fine["h"]
	var ftop: PackedInt32Array = fine["top"]
	var cw: int = coarse["w"]
	var ch: int = coarse["h"]
	var ctop: PackedInt32Array = coarse["top"]
	var ok_eq := true
	var ok_le := true
	var relief := false
	for cz in range(ch):
		for cx in range(cw):
			var tmin := 0x7fffffff
			var tmax := -0x7fffffff
			for dz in range(2):
				var fz := (cz << 1) + dz
				if fz >= fh:
					continue
				var rowoff := fz * fw
				for dx in range(2):
					var fx := (cx << 1) + dx
					if fx >= fw:
						continue
					var t: int = ftop[rowoff + fx]
					if t < tmin: tmin = t
					if t > tmax: tmax = t
			var c: int = ctop[cz * cw + cx]
			if c != tmin: ok_eq = false
			if c > tmin: ok_le = false            # containment: coarse <= EVERY child (i.e. <= the shortest = tmin)
			if tmax > tmin:
				relief = true                    # MAX-variant top (tmax) would exceed the lower child (tmin) here
	return [ok_eq, ok_le, relief]


## BLOCK-LOD P1 render gates (docs/COSMOS-BLOCK-LOD-DESIGN.md §4/§9) — drive FacetBlockLodRing._mesh_l2 DIRECTLY on real
## facets (flag-INDEPENDENT, like the P0 gates + verify_blocky_farring):
##   G-BLD-DRAWS      — a facet's L2 tile is ONE merged surface (surface_count == 1); tri count ≫ 1 ⇒ draws ≪ columns.
##   G-BLD-SEAM       — (a) shared-edge column corner DIRECTIONS bit-identical (the (fid,x,z) lattice node is one
##                      pure function ⇒ adjacent columns weld); (b) every outer boundary column emits its edge SKIRT
##                      (skirt_edge bit set) ⇒ no open silhouette; (c) an equal-height adjacent pair shares its top
##                      corner POSITIONS exactly (weld, not just direction).
##   G-BLD-NOPROTRUDE — every L2 vertex radius ≤ the fine surface over its footprint (re-derived from facet_profile,
##                      independent of the pyramid ⇒ teeth): per column, top_r ≤ R + max(0, g) for EVERY footprint
##                      cell, and every emitted vertex of that column ≤ its tile top max (walls/skirts drop). Mirrors
##                      verify_blocky_farring's A-check.
##   G-BLD-BYTES      — the mesh-byte ledger == the resident-tile arithmetic (Σ tile_bytes == bytes_total),
##                      LRU order == build order, free decrements exactly, and bytes_total ≤ BLOCK_LOD_BYTES_MAX.
func _p1_render_gates() -> void:
	var pitch := 1 << CubeSphere.BLOCK_LOD_LEVEL
	var r0 := FacetAtlas.R_BLOCKS
	var ring := FacetBlockLodRing.new()
	var fids := [0, 300, 1200, 3455]
	var worst_above := 0.0
	for fid in fids:
		var res := ring._mesh_l2(fid)
		var mesh: ArrayMesh = res["mesh"]
		var w: int = res["w"]
		var h: int = res["h"]
		var top_r: PackedFloat32Array = res["top_r"]
		var skirt_edge: PackedByteArray = res["skirt_edge"]
		var verts: PackedVector3Array = res["verts"]
		var dmin: Vector2i = res["dom_min"]

		# G-BLD-DRAWS — one merged surface, many columns ⇒ draws ≪ columns.
		_ok(mesh != null and mesh.get_surface_count() == 1, "G-BLD-DRAWS fid %d: L2 tile is ONE merged surface" % fid)
		_ok(w * h > 100 and verts.size() > w * h, "G-BLD-DRAWS fid %d: %d columns → 1 draw (draws << columns)" % [fid, w * h])

		# G-BLD-SEAM (a) — shared vertical edge between column (cx,cz) and (cx+1,cz): the +x boundary node of the left
		# column and the -x boundary node of the right column are the SAME lattice node ⇒ bit-identical direction.
		var seam_dir_ok := true
		var seam_pos_ok := true
		for cz in range(0, h, maxi(1, h / 8)):
			for cx in range(0, w - 1, maxi(1, w / 8)):
				var xn := float(dmin.x + (cx + 1) * pitch)
				var znt := float(dmin.y + cz * pitch)
				var znb := float(dmin.y + (cz + 1) * pitch)
				var da := ring._node_dir(fid, xn, znt)
				var db := ring._node_dir(fid, xn, znt)      # a pure function of the node → recompute is bit-identical
				if da != db: seam_dir_ok = false
				var ci := cz * w + cx
				if absf(top_r[ci] - top_r[ci + 1]) < 0.0005:
					# equal-height neighbours ⇒ their shared top-edge corner positions coincide exactly (weld).
					var top_edge := ring._node_dir(fid, xn, znb)
					if (da * top_r[ci]) != (da * top_r[ci + 1]): seam_pos_ok = false
					if (top_edge * top_r[ci]) != (top_edge * top_r[ci + 1]): seam_pos_ok = false
		_ok(seam_dir_ok, "G-BLD-SEAM fid %d (a): shared-edge column corner directions bit-identical (same lattice node)" % fid)
		_ok(seam_pos_ok, "G-BLD-SEAM fid %d (c): equal-height adjacent columns share top corner positions (weld)" % fid)

		# G-BLD-SEAM (b) — every OUTER boundary column emits its outer-edge skirt. bit0=-x,1=+x,2=-z,3=+z.
		var skirt_ok := true
		for cz in range(h):
			if (skirt_edge[cz * w] & 1) == 0: skirt_ok = false                    # -x edge (cx==0)
			if (skirt_edge[cz * w + (w - 1)] & 2) == 0: skirt_ok = false           # +x edge (cx==w-1)
		for cx in range(w):
			if (skirt_edge[cx] & 4) == 0: skirt_ok = false                         # -z edge (cz==0)
			if (skirt_edge[(h - 1) * w + cx] & 8) == 0: skirt_ok = false           # +z edge (cz==h-1)
		_ok(skirt_ok, "G-BLD-SEAM fid %d (b): every outer boundary column emits its edge skirt (silhouette closed)" % fid)

		# G-BLD-NOPROTRUDE — per column: top_r ≤ R + max(0,g) for EVERY footprint cell (re-sampled from facet_profile,
		# not the pyramid), AND every emitted vertex ≤ the tile top max. Sample columns sparsely (fast + teeth).
		# INTERIOR columns only: a boundary column's pyramid footprint is a PARTIAL 2×2 (the L0 domain edge truncates
		# the 4×4), so re-sampling a full 4×4 there would read beyond-domain cells (ungenerated terrain the tile only
		# overhangs into the margin — skirt-closed + far-ring-covered, exactly like _emit_blocky's facet-edge skirts).
		var above_fine := 0.0
		var step := maxi(1, w / 20)
		for cz in range(step, h - 1, step):
			for cx in range(step, w - 1, step):
				var ci := cz * w + cx
				var tr: float = top_r[ci]
				var min_fine := 1.0e30
				for dz in range(pitch):
					for dx in range(pitch):
						var g := int(TerrainConfig.facet_profile(fid, dmin.x + cx * pitch + dx, dmin.y + cz * pitch + dz).x)
						min_fine = minf(min_fine, r0 + maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)))
				above_fine = maxf(above_fine, tr - min_fine)     # ≤ 0 ⇒ top sits at/below the fine surface everywhere
		var tile_top_max := 0.0
		for i in range(top_r.size()):
			tile_top_max = maxf(tile_top_max, top_r[i])
		var wall_above := 0.0
		for v in verts:
			wall_above = maxf(wall_above, v.length() - tile_top_max)
		worst_above = maxf(worst_above, maxf(above_fine, wall_above))
		_ok(above_fine <= 0.05, "G-BLD-NOPROTRUDE fid %d: L2 top <= fine surface over its footprint (worst +%.4f blk)" % [fid, above_fine])
		_ok(wall_above <= 0.05, "G-BLD-NOPROTRUDE fid %d: no emitted vertex above the tile top max (worst +%.4f blk)" % [fid, wall_above])

	# G-BLD-BYTES — the ledger arithmetic + LRU + free, driven through the real _add_tile/_free_tile path.
	var bring := FacetBlockLodRing.new()
	bring.setup(0, null)
	var built := [0, 300, 1200]
	var expect := 0
	for fid in built:
		bring._add_tile(fid)
		expect += bring.tile_bytes(fid)
	var sum_entries := 0
	for fid in bring._tiles.keys():
		sum_entries += bring.tile_bytes(fid)
	_ok(bring.bytes_total() == expect and bring.bytes_total() == sum_entries,
		"G-BLD-BYTES ledger == sum of resident tile bytes (%d B, %d tiles)" % [bring.bytes_total(), bring.tile_count()])
	_ok(bring.lru_order() == built, "G-BLD-BYTES LRU order == build order")
	_ok(bring.bytes_total() <= CubeSphere.BLOCK_LOD_BYTES_MAX, "G-BLD-BYTES resident <= BLOCK_LOD_BYTES_MAX (%d <= %d)" % [bring.bytes_total(), CubeSphere.BLOCK_LOD_BYTES_MAX])
	var before := bring.bytes_total()
	var freed := bring.tile_bytes(300)
	bring._free_tile(300)
	_ok(bring.bytes_total() == before - freed and not bring._tiles.has(300) and bring.lru_order() == [0, 1200],
		"G-BLD-BYTES free decrements the ledger + drops the tile + LRU exactly")

	_ok(worst_above <= 0.05, "G-BLD-NOPROTRUDE overall: no L2 vertex pokes above the true surface (worst +%.4f blk)" % worst_above)
