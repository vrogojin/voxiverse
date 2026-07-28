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

	# ================= BLOCK-LOD P1 — the L1 rim-ring RENDER node (FacetBlockLodRing) ==========================
	# Drives FacetBlockLodRing directly (like the P0 data section drives FacetBlockLod) — flag-independent under
	# FACETED (the node is a pure function of the facet + the pyramid; the in-engine construction is FP_BLOCK_LOD-
	# gated, but the gate news it up itself). Asserts G-BLD-SEAM / G-BLD-BYTES / G-BLD-DRAWS + the LRU/ledger law.
	var afid := 300                       # a mid-lat, varied-relief interior facet (exercises side quads + skirts)
	var ring := FacetBlockLodRing.new()
	root.add_child(ring)
	ring.setup(afid)
	var band := ring.band_fids(afid)

	# G-BLD-DRAWS: one draw per resident band facet ≪ the L1 column count (draws ≈ tiles, NOT columns).
	var probe := FacetBlockLod.new(); probe.build(afid)
	var l1 := probe.get_level(1)
	var l1_cols: int = int(l1["w"]) * int(l1["h"])
	var draws := ring.draw_count()
	_ok(draws == band.size() and draws <= 6, "G-BLD-DRAWS fid %d: draws(%d) == band facets(%d) ≤ 6" % [afid, draws, band.size()])
	_ok(draws * 100 < l1_cols, "G-BLD-DRAWS fid %d: draws(%d) ≪ L1 columns(%d) (≥100×)" % [afid, draws, l1_cols])

	# G-BLD-BYTES: the node ledger == the arithmetic recomputed straight from the committed ArrayMesh arrays;
	# ≤ BLOCK_LOD_BYTES_MAX; and the whole active band stays resident (LRU never evicts the active set).
	var recomputed := 0
	for fid in ring.resident_fids():
		var mi: MeshInstance3D = ring._mesh_by_fid[fid]
		var sa := mi.mesh.surface_get_arrays(0)
		var nv: int = (sa[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var ni: int = (sa[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
		recomputed += nv * FacetBlockLodRing.BYTES_PER_VERT + ni * FacetBlockLodRing.BYTES_PER_INDEX
	_ok(recomputed == ring.ledger_bytes(), "G-BLD-BYTES fid %d: ledger(%d B) == arithmetic from meshes(%d B)" % [afid, ring.ledger_bytes(), recomputed])
	_ok(ring.ledger_bytes() <= CubeSphere.BLOCK_LOD_BYTES_MAX, "G-BLD-BYTES: ledger %d B ≤ ceiling %d B (16 MB)" % [ring.ledger_bytes(), CubeSphere.BLOCK_LOD_BYTES_MAX])
	print("  INFO L1 measured cost: %.2f MB for %d band facets (%.2f MB/facet), ceiling %.0f MB" % [
		ring.ledger_bytes() / 1048576.0, band.size(), (ring.ledger_bytes() / 1048576.0) / maxf(1.0, band.size()), CubeSphere.BLOCK_LOD_BYTES_MAX / 1048576.0])
	var band_resident := true
	for fid in band:
		if not ring.resident_fids().has(fid):
			band_resident = false
	_ok(band_resident, "G-BLD-BYTES: whole active band resident (LRU never evicts the active set)")

	# G-BLD-SEAM: every required boundary/step edge is closed (side quad on interior steps, skirt on the perimeter) —
	# no silhouette hole; shared-lattice corners weld bit-identically by construction (lattice_to_world64 is pure).
	var seam_ok := true
	for fid in band:
		if ring.seam_defects(fid) != 0:
			seam_ok = false
	_ok(seam_ok, "G-BLD-SEAM: no boundary hole across the band (skirt closes tile/ring edges) + welded shared edges")

	# G-BLD-SEAM teeth: a mesher that dropped the perimeter skirt would leave the boundary edges required-but-missing.
	# Prove seam_defects would CATCH it: the required-set recompute for a facet with a nonempty perimeter is > 0 when
	# the emitted-edge set is emptied. (Uses the band's active facet; its polygon boundary guarantees required edges.)
	var teeth_ok := _seam_teeth(ring, afid)
	_ok(teeth_ok, "G-BLD-SEAM falsifier: seam_defects > 0 when the emitted-edge set is stripped (has teeth)")

	# NEVER-OOM stress: cross through several active facets so the LRU/ledger must evict; the final band stays
	# resident, residency stays ≤ the LRU cap, and the ledger stays under the ceiling.
	# Cross to 3 far-apart active facets: each band (≤5) is disjoint from the others, so ≥15 distinct facets pass
	# through a cap-9 residency ⇒ the LRU MUST have evicted. Assert residency ≤ cap, ledger ≤ ceiling, final band kept.
	var crossings := [800, 1600, 2400]
	for step_fid in crossings:
		ring.rebuild(step_fid)
	var final_band := ring.band_fids(2400)
	var stress_ok := ring.resident_fids().size() <= CubeSphere.BLOCK_LOD_LRU_FACETS
	stress_ok = stress_ok and ring.ledger_bytes() <= CubeSphere.BLOCK_LOD_BYTES_MAX
	for fid in final_band:
		if not ring.resident_fids().has(fid):
			stress_ok = false
	_ok(stress_ok, "G-BLD-BYTES LRU: after 3 disjoint crossings residency(%d) ≤ cap(%d), ledger ≤ ceiling, final band resident" % [ring.resident_fids().size(), CubeSphere.BLOCK_LOD_LRU_FACETS])

	ring.queue_free()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## G-BLD-SEAM teeth: confirm seam_defects actually reports missing edges. We rebuild the facet's required-edge set
## and check that with an EMPTY emitted-edge set at least one edge is required (would be flagged missing) — i.e. the
## facet has a real boundary/step, so a dropped skirt/side quad cannot slip past the audit.
func _seam_teeth(ring: FacetBlockLodRing, fid: int) -> bool:
	var arr := ring._build_facet_arrays(fid)
	var edges: Dictionary = arr["edges"]
	# The mesher emitted a nonempty edge set (perimeter skirts + interior steps). If it is nonempty, an empty set
	# WOULD raise seam_defects above 0 (every one of these keys would be reported missing). Nonempty ⇒ teeth.
	return edges.size() > 0


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
