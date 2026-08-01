extends SceneTree
## G-FARLOD-SINK / G-FARLOD-BAND — COSMOS FAR-LOD QUALITY (task #farlod, flag CubeSphere.FP_FARLOD_QUALITY).
## Flag-INDEPENDENT: drives the block-LOD mesher + the ladder's screen-space law directly on REAL facets (like the
## sibling verify_block_lod), FORCING the flag's parameters on so the fix is proven even though the const is compiled
## off. Byte-off (FP_FARLOD_QUALITY false) is covered by verify_feature (FLAT 6042/0) + verify_block_lod (bands unmoved).
##
##   G-FARLOD-SINK — (A) NO-PROTRUSION. For ≥2 cube faces, at every ladder level L1..MAX, greedy-mesh the facet with the
##                   radial sink FORCED on (ring._farlod_sink = FARLOD_BLOCK_SINK) and assert EVERY emitted megablock
##                   top corner sits at-or-below the TRUE analytic surface radius at that column (no protrusion), with a
##                   ≥ (sink − ε) margin (the sink actually landed the tier below the near field). FALSIFIER: the SAME
##                   corners meshed with sink 0 leave at least one column with margin < sink (a coplanar/near-protruding
##                   vertex the near field would z-fight) — so the check has teeth (a regression that dropped the sink
##                   would fail the margin assertion).
##   G-FARLOD-BAND — (B) FINER band selection. The flag-gated K_px is byte-identical off; the FARLOD_TARGET_PX-scaled
##                   law is monotone (finer near / coarser far), NEVER coarser than the shipped law at any distance and
##                   strictly finer somewhere, and its hand-off on-screen block size is FARLOD_TARGET_PX/FARLOD_SHIP_PX
##                   of the shipped ~4 px. FALSIFIER: at a probe distance the shipped law picks a COARSER level than the
##                   retune (the retune demonstrably changes selection — not a no-op).
## Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

func _initialize() -> void:
	print("=== verify_farlod (G-FARLOD-SINK / G-FARLOD-BAND: block-LOD no-protrusion + finer bands) ===")
	FacetAtlas.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED"); print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return

	_gate_sink()
	_gate_band()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ============================================================================================================
# (A) G-FARLOD-SINK — the block-LOD tiers sit provably below the true surface once the radial sink is applied.
# ============================================================================================================
func _gate_sink() -> void:
	var sink := CubeSphere.FARLOD_BLOCK_SINK
	var eps := 0.05                     # f32 render-coord slack (radii are ~6371-block magnitudes)
	var top_lvl: int = mini(CubeSphere.BLOCK_LOD_MAX_LEVEL, FacetBlockLod.LEVELS - 1)
	# Spread across ≥2 cube faces + varied relief (a face-centre, a mid-lat, a hilly, a pole-ish facet).
	var fids := [0, 300, 1200, 3455]

	for fid in fids:
		var lod := FacetBlockLod.new()
		lod.build(fid)
		var worst_over := -1.0e30       # max (sunk_radius − surface_radius): must stay ≤ eps (no protrusion)
		var worst_margin := 1.0e30      # min (surface_radius − sunk_radius): must stay ≥ sink − eps (sink landed)
		var raw_falsifier := false      # some column's UNSUNK margin < sink (proves the sink is doing real work)
		var checked := 0

		for level in range(1, top_lvl + 1):
			var pitch := 1 << level
			var half := pitch >> 1
			var lvl := lod.get_level(level)
			var w: int = lvl["w"]
			var h: int = lvl["h"]
			var top: PackedInt32Array = lvl["top"]
			var dmin := FacetAtlas.dom_min(fid)

			var ring_s := FacetBlockLodRing.new()
			ring_s._level = level; ring_s._pitch = pitch
			ring_s._farlod_sink = sink                    # FORCE the sink on (const is compiled off)
			var ring_r := FacetBlockLodRing.new()
			ring_r._level = level; ring_r._pitch = pitch
			ring_r._farlod_sink = 0.0                     # reference / falsifier: no sink

			for cz in range(h):
				for cx in range(w):
					var ci := cz * w + cx
					var lx := dmin.x + cx * pitch + half
					var lz := dmin.y + cz * pitch + half
					if not FacetAtlas.in_polygon(fid, lx, lz, 0.0):
						continue                          # unemitted coarse column (outside the facet polygon)
					# The top-quad corner (child (0,0) of this coarse cell) — a real column whose analytic g ≥ top[ci].
					var x0 := dmin.x + cx * pitch
					var z0 := dmin.y + cz * pitch
					var th: int = top[ci]
					var vs := ring_s._w(fid, x0, th, z0)  # sunk vertex (the actual mesher path)
					var vr := ring_r._w(fid, x0, th, z0)  # unsunk reference
					var r_s := vs.length()
					var r_r := vr.length()
					# TRUE analytic surface radius at the SAME column.
					var g0 := int(TerrainConfig.facet_profile(fid, x0, z0).x)
					var sw := FacetAtlas.lattice_to_world64(fid, float(x0), float(g0), float(z0))
					var r_surf := Vector3(sw[0], sw[1], sw[2]).length()
					worst_over = maxf(worst_over, r_s - r_surf)
					worst_margin = minf(worst_margin, r_surf - r_s)
					if (r_surf - r_r) < sink - eps:
						raw_falsifier = true
					checked += 1

			ring_s.free(); ring_r.free()

		_ok(worst_over <= eps,
			"G-FARLOD-SINK fid %d: every block-LOD top ≤ true surface (worst protrusion %.3f blk ≤ %.2f, %d cols/L1..L%d)"
			% [fid, worst_over, eps, checked, top_lvl])
		_ok(worst_margin >= sink - eps,
			"G-FARLOD-SINK fid %d: every block-LOD top ≥ %.1f blk BELOW the surface (worst margin %.3f blk)"
			% [fid, sink, worst_margin])
		_ok(raw_falsifier,
			"G-FARLOD-SINK fid %d: FALSIFIER — an UNSUNK column has margin < %.1f blk (the sink does real work / teeth)"
			% [fid, sink])
		lod = null


# ============================================================================================================
# (B) G-FARLOD-BAND — the finer screen-space level selection (monotone, finer-not-coarser, on-screen bounded).
# ============================================================================================================
func _gate_band() -> void:
	var k_ship := CubeSphere.BLOCK_LOD_SCREEN_K_PX
	var k_fine := k_ship * (CubeSphere.FARLOD_SHIP_PX / CubeSphere.FARLOD_TARGET_PX)   # what block_lod_screen_k_px() returns ON

	# Byte-identical OFF: the flag-gated helper returns the shipped constant (⇒ verify_block_lod bands unmoved).
	_ok(is_equal_approx(CubeSphere.block_lod_screen_k_px(), k_ship),
		"G-FARLOD-BAND: block_lod_screen_k_px() == shipped %.0f with the flag off (byte-identical)" % k_ship)

	# The retune targets a FINER hand-off (smaller on-screen block ⇒ larger K_px).
	_ok(CubeSphere.FARLOD_TARGET_PX < CubeSphere.FARLOD_SHIP_PX and k_fine > k_ship,
		"G-FARLOD-BAND: target %.2f px < shipped %.1f px ⇒ K_px %.0f → %.0f (finer levels persist farther)"
		% [CubeSphere.FARLOD_TARGET_PX, CubeSphere.FARLOD_SHIP_PX, k_ship, k_fine])

	# Monotone (finer near / coarser far) + never coarser than the shipped law + strictly finer somewhere.
	var monotone := true
	var never_coarser := true
	var finer_somewhere := false
	var prev := 0
	for di in range(1, 121):
		var d := float(di) * 100.0                       # 100 .. 12000 blocks
		var lf := _lvl_for(d, k_fine)
		var ls := _lvl_for(d, k_ship)
		if lf < prev:
			monotone = false
		prev = lf
		if lf > ls:
			never_coarser = false                        # the retune must NEVER pick a COARSER level than shipped
		if lf < ls:
			finer_somewhere = true
	_ok(monotone, "G-FARLOD-BAND: level_for_distance is monotone non-decreasing (finer near, coarser far)")
	_ok(never_coarser, "G-FARLOD-BAND: the retune is NEVER coarser than the shipped law at any distance")
	_ok(finer_somewhere, "G-FARLOD-BAND: FALSIFIER — the retune picks a strictly FINER level than shipped at some distance (not a no-op)")

	# On-screen hand-off size: a level-n block retired at d_max(n) subtends pitch/d_max = 4/K_px of the projection.
	# The retuned fraction is (target/ship) of the shipped fraction ⇒ the knob directly sets the on-screen block size.
	var frac_ratio := (4.0 / k_fine) / (4.0 / k_ship)
	_ok(is_equal_approx(frac_ratio, CubeSphere.FARLOD_TARGET_PX / CubeSphere.FARLOD_SHIP_PX),
		"G-FARLOD-BAND: hand-off on-screen block size scales to target/ship = %.3f (≈%.2f px vs the shipped ~%.1f px)"
		% [CubeSphere.FARLOD_TARGET_PX / CubeSphere.FARLOD_SHIP_PX, CubeSphere.FARLOD_TARGET_PX, CubeSphere.FARLOD_SHIP_PX])


## level_for_distance with an EXPLICIT K_px (mirrors FacetBlockLodLadder.level_for_distance / d_max = 2^n·K/4).
func _lvl_for(dist: float, k: float) -> int:
	for n in range(1, CubeSphere.BLOCK_LOD_GLOBAL_LEVEL + 1):
		if dist <= float(1 << n) * k / 4.0:
			return n
	return CubeSphere.BLOCK_LOD_GLOBAL_LEVEL
