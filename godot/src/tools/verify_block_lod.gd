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

	# ================= G-BLD-MAINCOST — the ~1 s L0 bake must LEAVE the main thread (TH4 async) ================
	# Mirrors §2V's G-TW-MAINCOST (61.7 ms → 0.9 ms). Build the SAME facet two ways and compare the MAIN-thread cost:
	#   (a) SYNC  — the P1 path: _build_facet_arrays + _commit on main = the whole ~1 s stall (what a crossing paid).
	#   (b) ASYNC — a JobLane: the worker runs _build_facet_arrays; MAIN pays only the ArrayMesh commit (lane drain).
	# A crossing that once froze main for ~1 s now pays only the bounded commit ⇒ FP_BLOCK_LOD is live-safe.
	var mc_fid := 305

	# (a) synchronous full main build (statics prewarmed on main first — a fair comparison; the async path prewarms too).
	var sync_ring := FacetBlockLodRing.new()
	root.add_child(sync_ring)
	sync_ring._prewarm_statics(mc_fid)
	var ts := Time.get_ticks_usec()
	sync_ring._commit_facet_arrays(mc_fid, sync_ring._build_facet_arrays(mc_fid))
	var sync_ms := float(Time.get_ticks_usec() - ts) / 1000.0

	# (b) async: worker bakes, main only commits (measured via the lane's accumulated main-commit clock).
	var lane := JobLane.new(2)
	var async_ring := FacetBlockLodRing.new()
	root.add_child(async_ring)
	async_ring._prewarm_statics(mc_fid)
	async_ring.set_job_lane(lane)
	lane.take_main_commit_ms()                       # reset the accumulator
	async_ring._submit_bake(mc_fid)                  # submit the single bake unit to the worker (own staging buffer)
	var guard := 0
	while not async_ring.async_idle() and guard < 30000:
		lane.pump()
		OS.delay_msec(1)
		guard += 1
	var async_ms := lane.take_main_commit_ms()       # ONLY the commit ran on main; the ~1 s bake was on the worker

	var committed := async_ring.resident_fids().has(mc_fid)
	_ok(committed, "G-BLD-MAINCOST: async worker path committed facet %d (baked off-main, uploaded on main)" % mc_fid)
	_ok(sync_ms > 50.0, "G-BLD-MAINCOST: SYNC main build is a real stall (%.1f ms > 50) — the cost to eliminate" % sync_ms)
	_ok(async_ms * 4.0 < sync_ms, "G-BLD-MAINCOST: ASYNC main cost %.2f ms ≪ SYNC %.1f ms (bake left the frame, ≥4×)" % [async_ms, sync_ms])
	print("  INFO G-BLD-MAINCOST: crossing main-thread cost per facet  BEFORE(sync)=%.1f ms  →  AFTER(async commit)=%.2f ms" % [sync_ms, async_ms])
	sync_ring.queue_free()
	async_ring.queue_free()

	# ================= G-BLD-CONVERGE — the whole band bakes in a couple of seconds, not starved ================
	# The live report: draws stuck at far-only, +2 facets in 50 s — the band was dispatched one-per-round-trip at
	# OPPORTUNISTIC priority, starved behind §2V's g1 shot convergence. Fix: submit the WHOLE band up front at
	# PRIORITY_BLOCK_LOD (> texture), computing in parallel on the free worker slots. Assert: (1) one rebuild submits
	# the whole band (1 dispatch round, not band_size); (2) it converges fully resident; (3) MAIN commit stays ≈0;
	# (4) ledger ≤ 16 MB; (5) block-LOD outranks the texture lane.
	_ok(JobLane.PRIORITY_BLOCK_LOD > JobLane.PRIORITY_TEXTURE,
		"G-BLD-CONVERGE: block-LOD priority (%d) > texture (%d) — the transition band beats far-skin g1 refinement" % [JobLane.PRIORITY_BLOCK_LOD, JobLane.PRIORITY_TEXTURE])
	var cfid := 1500
	var clane := JobLane.new(2)
	var cring := FacetBlockLodRing.new()
	root.add_child(cring)
	cring._prewarm_statics(cfid)
	cring.set_job_lane(clane)
	clane.take_main_commit_ms()
	cring.rebuild(cfid)                               # ONE rebuild → whole band submitted up front
	var cband := cring.band_fids(cfid)
	var missing := 0
	for fid in cband:
		if not cring.resident_fids().has(fid):
			missing += 1
	_ok(cring.inflight_count() == missing and cring.dispatch_rounds() == 1,
		"G-BLD-CONVERGE: whole band (%d, %d missing) submitted UP FRONT in 1 dispatch round (in-flight=%d, not serialized)" % [cband.size(), missing, cring.inflight_count()])
	var cguard := 0
	while not cring.async_idle() and cguard < 40000:
		clane.pump()
		OS.delay_msec(1)
		cguard += 1
	var conv_ms := clane.take_main_commit_ms()
	var all_res := true
	for fid in cband:
		if not cring.resident_fids().has(fid):
			all_res = false
	_ok(all_res, "G-BLD-CONVERGE: full band resident after convergence (not starved)")
	_ok(cring.dispatch_rounds() <= 2, "G-BLD-CONVERGE: converged in %d dispatch round(s) ≤ band+slack (was ~%d serialized)" % [cring.dispatch_rounds(), cband.size()])
	_ok(conv_ms < 100.0, "G-BLD-CONVERGE: whole-band MAIN commit %.2f ms ≈ 0 (the ~%d s of bakes stayed on the worker)" % [conv_ms, cband.size()])
	_ok(cring.ledger_bytes() <= CubeSphere.BLOCK_LOD_BYTES_MAX, "G-BLD-CONVERGE: ledger %d B ≤ 16 MB after the whole-band burst" % cring.ledger_bytes())
	print("  INFO G-BLD-CONVERGE: band=%d  dispatch_rounds=%d (was ~%d one-per-round serialized)  whole-band main_commit=%.2f ms" % [cband.size(), cring.dispatch_rounds(), cband.size(), conv_ms])
	cring.queue_free()

	# ================= BLOCK-LOD P2 — the L2..L4 LADDER + the L5 GLOBAL tier ====================================
	# Drives FacetBlockLodLadder / FacetBlockLodGlobal directly (flag-independent under FACETED, like the P0/P1
	# sections). Asserts G-BLD-LADDER (full pyramid + screen-space level law), G-BLD-RINGS (stream/LRU/dither/cap),
	# G-BLD-GLOBAL (all 3456 resident data floor, never evicted, arithmetic bytes), G-BLD-BYTES (shared ceiling +
	# finest-first coarsen + expanded knob), G-BLD-MAINCOST (multi-level crossing commit-only).

	# ---- G-BLD-LADDER: the on-screen block-size law + the full L1..L5 pyramid + containment every level ----------
	var law_ok := FacetBlockLodLadder.level_for_distance(500.0) == 1
	law_ok = law_ok and FacetBlockLodLadder.level_for_distance(1000.0) == 2
	law_ok = law_ok and FacetBlockLodLadder.level_for_distance(2000.0) == 3
	law_ok = law_ok and FacetBlockLodLadder.level_for_distance(4000.0) == 4
	law_ok = law_ok and FacetBlockLodLadder.level_for_distance(8000.0) == 5
	_ok(law_ok, "G-BLD-LADDER: level_for_distance picks the tier per distance (500→L1 1000→L2 2000→L3 4000→L4 8000→L5)")
	var dmax_ok := true
	for n in range(3, 6):
		if not is_equal_approx(FacetBlockLodLadder.d_max(n), 2.0 * FacetBlockLodLadder.d_max(n - 1)):
			dmax_ok = false
	_ok(dmax_ok, "G-BLD-LADDER: d_max(Ln) == 2·d_max(Ln−1) (power-of-2 band doubling to the horizon)")
	var plod := FacetBlockLod.new(); plod.build(300)
	var chain_ok := true
	var contain_ok := true
	for n in range(1, 6):
		var redec := FacetBlockLod.decimate(plod.get_level(n - 1))
		if not FacetBlockLod.level_equals(redec, plod.get_level(n)):
			chain_ok = false
		var rr := _check_min(plod.get_level(n - 1), plod.get_level(n))
		if not rr[1]:
			contain_ok = false
	_ok(chain_ok, "G-BLD-LADDER fid 300: L1..L5 == decimate chain EXACTLY (pyramid invariant across the whole ladder)")
	_ok(contain_ok, "G-BLD-LADDER fid 300: coarse ≤ finer at EVERY level L1..L5 (no protrusion up the ladder)")
	plod = null

	# ---- G-BLD-RINGS: L2..L4 stream + level cap + draws bounded + dither + LRU-across-crossings no-hole ----------
	var cap: int = CubeSphere.BLOCK_LOD_MAX_LEVEL
	var lad := FacetBlockLodLadder.new()
	root.add_child(lad)
	lad.setup(300)
	var lvls := lad.active_levels()
	var cap_ok := lvls.size() > 0 and int(lvls[0]) == 2
	for lv in lvls:
		if int(lv) > cap:
			cap_ok = false
	_ok(cap_ok, "G-BLD-RINGS: ladder streams L2..L%d, max level ≤ BLOCK_LOD_MAX_LEVEL(%d) — active=%s" % [cap, cap, str(lvls)])
	var lad_draws := lad.draw_count()
	var sum_tiles := 0
	for lv in lvls:
		sum_tiles += lad.level_tile_count(int(lv))
	_ok(lad_draws == sum_tiles and lad_draws <= (cap - 1) * CubeSphere.BLOCK_LOD_LADDER_LRU,
		"G-BLD-RINGS: draws(%d) == Σ per-level tiles ≤ (levels)·(LRU) — bounded by TILES not blocks" % lad_draws)
	# arrival-dither clock carried on a ladder tile (UV.x = arrival > 0): the per-level temporal fade.
	var dith_ok := false
	var l2ring := lad.ring_for(2)
	var l2band: Array = lad.assign_levels(300).get(2, [])
	if l2ring != null and not l2band.is_empty():
		var a2 := l2ring._build_facet_arrays(int(l2band[0]))
		var uvs2: PackedVector2Array = a2["uvs"]
		dith_ok = uvs2.size() > 0 and uvs2[0].x > 0.0
	_ok(dith_ok, "G-BLD-RINGS: arrival-dither clock (UV.x) carried on every ladder tile (per-level temporal fade)")
	# LRU across crossings: residency ≤ cap per ring, the freshly-assigned band always resident (no hole under the ring).
	for step in [900, 1700, 2500, 300]:
		lad.rebuild(step)
	var cross_ok := true
	for lv in lad.active_levels():
		var lr := lad.ring_for(int(lv))
		if lr.resident_fids().size() > CubeSphere.BLOCK_LOD_LADDER_LRU:
			cross_ok = false
		for fid in lr.current_band():
			if not lr.resident_fids().has(fid):
				cross_ok = false
	_ok(cross_ok, "G-BLD-RINGS: after 4 crossings each ring residency ≤ LRU(%d) AND its assigned band stays resident (no hole)" % CubeSphere.BLOCK_LOD_LADDER_LRU)
	print("  INFO ladder: levels=%s draws=%d total=%.2f MB  L2=%.2f L3=%.2f L4=%.2f MB" % [
		str(lad.active_levels()), lad.draw_count(), lad.total_bytes() / 1048576.0,
		lad.level_bytes(2) / 1048576.0, lad.level_bytes(3) / 1048576.0, lad.level_bytes(4) / 1048576.0])
	lad.queue_free()

	# ---- G-BLD-GLOBAL: L5 DATA for ALL 3456 facets, always resident + never evicted; bytes == arithmetic ---------
	var glane := JobLane.new(2)
	var glob := FacetBlockLodGlobal.new()
	root.add_child(glob)
	glob.set_job_lane(glane)
	glob.setup(300)                                  # dispatches the 6 cube-face DATA units on the worker
	var gg := 0
	while not glob.data_ready() and gg < 200000:
		glane.pump()
		OS.delay_msec(1)
		gg += 1
	_ok(glob.facets_baked() == glob.facets_total() and glob.facets_total() == 3456,
		"G-BLD-GLOBAL: L5 DATA baked for ALL %d facets (progressive worker bake, main never blocked)" % glob.facets_total())
	_ok(glob.data_bytes() == glob.data_bytes_arithmetic(),
		"G-BLD-GLOBAL: data floor %.2f MB == arithmetic Σ(w5·h5)·%d B" % [glob.data_bytes() / 1048576.0, FacetBlockLodGlobal.BYTES_PER_COL])
	_ok(glob.draw_count() <= CubeSphere.BLOCK_LOD_GLOBAL_DRAWS and glob.mesh_bytes() <= CubeSphere.BLOCK_LOD_GLOBAL_MESH_BYTES,
		"G-BLD-GLOBAL: visible mesh draws(%d) ≤ %d and bytes(%.2f MB) ≤ cap — NEVER-OOM (full-globe L5 mesh = ~158 MB, avoided)" % [
			glob.draw_count(), CubeSphere.BLOCK_LOD_GLOBAL_DRAWS, glob.mesh_bytes() / 1048576.0])
	var floor0 := glob.data_bytes()
	for step in [1000, 2000, 3000]:
		glob.rebuild(step)
	_ok(glob.data_bytes() == floor0 and glob.facets_baked() == 3456,
		"G-BLD-GLOBAL: DATA floor never LRU-evicted across crossings (%.2f MB stable, all 3456 resident)" % [floor0 / 1048576.0])
	print("  INFO L5 global: data floor %.2f MB (all 3456) + visible mesh %.2f MB in %d draws (cap %d MB)" % [
		glob.data_bytes() / 1048576.0, glob.mesh_bytes() / 1048576.0, glob.draw_count(), CubeSphere.BLOCK_LOD_GLOBAL_MESH_BYTES / 1048576])

	# ---- G-BLD-BYTES: the SHARED ceiling — L1 + ladder + global under ONE budget, finest-first coarsen, floor kept -
	_ok(CubeSphere.block_lod_ceiling() == CubeSphere.BLOCK_LOD_BYTES_MAX and not CubeSphere.BLOCK_LOD_EXPANDED_ENABLED,
		"G-BLD-BYTES: default shared ceiling == 16 MB (expanded path disabled by default)")
	_ok(CubeSphere.BLOCK_LOD_BYTES_EXPANDED == (28 << 20),
		"G-BLD-BYTES: expanded ceiling const == 28 MB (flip BLOCK_LOD_EXPANDED_ENABLED after a live heap A/B to re-add L1)")
	var l1r := FacetBlockLodRing.new(); root.add_child(l1r); l1r.setup(300, 1)   # the P1 L1 rim ring (~11 MB)
	var lad2 := FacetBlockLodLadder.new(); root.add_child(lad2); lad2.setup(300)  # the L2..L4 ladder (~11 MB)
	lad2.register_l1(l1r)
	lad2.set_global(glob)
	var pre := lad2.total_bytes()
	lad2.enforce_shared_budget()
	var post := lad2.total_bytes()
	_ok(pre > CubeSphere.block_lod_ceiling(),
		"G-BLD-BYTES: pre-enforce total %.2f MB breaches the 16 MB ceiling (L1+ladder+global together)" % [pre / 1048576.0])
	_ok(post <= CubeSphere.block_lod_ceiling(),
		"G-BLD-BYTES: post-enforce total %.2f MB ≤ ceiling — coarsened under ONE shared budget" % [post / 1048576.0])
	_ok(l1r.ledger_bytes() < lad2.level_bytes(2) or l1r.ledger_bytes() == 0,
		"G-BLD-BYTES: FINEST-FIRST — L1(%.2f MB) dropped before the coarser L2(%.2f MB) survived" % [l1r.ledger_bytes() / 1048576.0, lad2.level_bytes(2) / 1048576.0])
	_ok(glob.data_bytes() == floor0,
		"G-BLD-BYTES: L5 global DATA floor PROTECTED through the breach (%.2f MB intact, never coarsened)" % [floor0 / 1048576.0])
	_ok(lad2.wholesale_clears() >= 1,
		"G-BLD-BYTES: wholesale-clear fired on the hard breach (%d finest-level drops recorded)" % lad2.wholesale_clears())
	print("  INFO G-BLD-BYTES: shared ledger  BEFORE=%.2f MB  →  AFTER=%.2f MB (ceiling %.0f MB); global floor %.2f MB kept" % [
		pre / 1048576.0, post / 1048576.0, CubeSphere.block_lod_ceiling() / 1048576.0, floor0 / 1048576.0])
	l1r.queue_free()
	lad2.queue_free()
	glob.queue_free()

	# ---- G-BLD-MAINCOST (multi-level): a crossing through L2..L4 pays commit-only on main (no sync bake stall) ----
	var mlane := JobLane.new(2)
	var mlad := FacetBlockLodLadder.new()
	root.add_child(mlad)
	mlad.set_job_lane(mlane)
	mlad.setup(1500)                                 # first band on the worker
	var mw := 0
	while not mlad.async_idle() and mw < 60000:
		mlane.pump()
		OS.delay_msec(1)
		mw += 1
	mlane.take_main_commit_ms()                       # reset — measure ONLY the crossing below
	mlad.rebuild(700)                                 # crossing to a new active facet → new multi-level band
	var mw2 := 0
	while not mlad.async_idle() and mw2 < 60000:
		mlane.pump()
		OS.delay_msec(1)
		mw2 += 1
	var lad_commit := mlane.take_main_commit_ms()
	_ok(mlad.async_idle(), "G-BLD-MAINCOST(ladder): the whole L2..L4 crossing band converged on the worker")
	_ok(lad_commit < 150.0, "G-BLD-MAINCOST(ladder): multi-level crossing MAIN commit %.2f ms ≈ 0 (every tier baked off-main)" % lad_commit)
	print("  INFO G-BLD-MAINCOST(ladder): multi-level crossing main-commit = %.2f ms (bakes stayed on the worker)" % lad_commit)
	mlad.queue_free()

	# ================= PLANET-LOD-CONFIG P0 — the ORBIT megablock disc (FacetBlockLodOrbit) =====================
	_gate_orbit()

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


## G-BLD-ORBIT-LEVEL / -BYTES / -MIN / -RETIRE / -EMPTY (docs/COSMOS-PLANET-LOD-CONFIG-DESIGN.md §2). Drives
## FacetBlockLodOrbit directly (flag-independent under FACETED, like the P0/P1/P2 sections): the node is a pure function
## of the facet + camera; the in-engine construction is FP_BLOCK_LOD_ORBIT-gated, but the gate news it up itself.
func _gate_orbit() -> void:
	print("  -- PLANET-LOD-CONFIG P0: orbit megablock disc --")
	var MIN_L := CubeSphere.BLOCK_LOD_ORBIT_MIN_LEVEL          # 4
	var MAX_L := CubeSphere.BLOCK_LOD_GLOBAL_LEVEL             # 5

	# ---- G-BLD-ORBIT-LEVEL: the PURE per-facet screen-distance law (nadir L4 -> limb L5), monotone non-decreasing -----
	var nadir_lvl := FacetBlockLodOrbit.level_for_orbit_dist(8000.0)
	_ok(nadir_lvl == 4, "G-BLD-ORBIT-LEVEL: nadir facet at alt 8000 (d=8000) selects L4 (16-blk) - got L%d" % nadir_lvl)
	var far_lvl := FacetBlockLodOrbit.level_for_orbit_dist(13000.0)
	_ok(far_lvl == 5, "G-BLD-ORBIT-LEVEL: limb facet (d=13000) coarsens to L5 (32-blk) - got L%d" % far_lvl)
	_ok(FacetBlockLodOrbit.level_for_orbit_dist(10.0) == MIN_L, "G-BLD-ORBIT-LEVEL: clamped to L%d floor (never finer than the orbit min tier)" % MIN_L)
	_ok(FacetBlockLodOrbit.level_for_orbit_dist(1.0e6) == MAX_L, "G-BLD-ORBIT-LEVEL: clamped to L%d ceiling (never coarser than L5)" % MAX_L)
	var mono := true
	var prev := 0
	for step in range(0, 40):
		var dist := 4000.0 + float(step) * 500.0
		var lv := FacetBlockLodOrbit.level_for_orbit_dist(dist)
		if lv < prev:
			mono = false
		prev = lv
	_ok(mono, "G-BLD-ORBIT-LEVEL: level_for_orbit_dist MONOTONE non-decreasing in distance (no L5->L4 inversion)")
	var finer := CubeSphere.orbit_level_for_dist(8000.0, CubeSphere.BLOCK_LOD_ORBIT_PX, CubeSphere.BLOCK_LOD_ORBIT_K_PX, 3, MAX_L)
	_ok(finer == 4 and CubeSphere.orbit_level_for_dist(3000.0, CubeSphere.BLOCK_LOD_ORBIT_PX, CubeSphere.BLOCK_LOD_ORBIT_K_PX, 3, MAX_L) == 3,
		"G-BLD-ORBIT-LEVEL falsifier: a real B*=px*d/K function (min_level=3 lets d=3000 fall to L3) - not a constant")

	# ---- G-BLD-ORBIT-ENGAGE: the swap-altitude hysteresis band ------------------------------------------------------
	var e_hi := CubeSphere.BLOCK_LOD_ORBIT_ENGAGE_H * (1.0 + CubeSphere.BLOCK_LOD_ORBIT_HYST)
	var e_lo := CubeSphere.BLOCK_LOD_ORBIT_ENGAGE_H * (1.0 - CubeSphere.BLOCK_LOD_ORBIT_HYST)
	var eng_ok := CubeSphere.block_lod_orbit_engaged(e_hi + 1.0, false)
	eng_ok = eng_ok and not CubeSphere.block_lod_orbit_engaged(e_hi - 1.0, false)
	eng_ok = eng_ok and CubeSphere.block_lod_orbit_engaged(e_lo + 1.0, true)
	eng_ok = eng_ok and not CubeSphere.block_lod_orbit_engaged(e_lo - 1.0, true)
	eng_ok = eng_ok and not CubeSphere.block_lod_orbit_engaged(0.0, false)
	_ok(eng_ok, "G-BLD-ORBIT-ENGAGE: hysteresis swap band [%.0f..%.0f] (engage up-high, disengage down-low, off on surface)" % [e_lo, e_hi])

	# ---- Build a REAL bounded disc at alt 8000 (nadir camera) -------------------------------------------------------
	var afid := 300
	var node := FacetBlockLodOrbit.new()
	root.add_child(node)
	node.setup(afid)
	var u := node._facet_centre(afid).normalized()
	var cam_d := FacetAtlas.R_BLOCKS + 8000.0
	var disc := node.assign_disc(u, cam_d)
	_ok(disc.size() > 100, "G-BLD-ORBIT-DISC: the visible disc enumerates the front hemisphere (%d facets)" % disc.size())
	_ok(int(disc[0][2]) == 4, "G-BLD-ORBIT-LEVEL: nearest (nadir) disc facet is L4; farthest is L%d" % int(disc[disc.size() - 1][2]))

	var unit := FacetBlockLodOrbit.BuildUnit.new()
	unit.disc = disc.slice(0, mini(disc.size(), 180))   # a nearest slice that breaches the 12 MB cap ⇒ exercises coarsen/drop
	node._worker_build(unit)
	node._commit_build(unit)

	# ---- G-BLD-ORBIT-BYTES: enforced ledger <= cap; draws bounded; combined (skin retired) < 40 MB ------------------
	_ok(node.total_bytes() <= CubeSphere.BLOCK_LOD_ORBIT_BYTES_MAX,
		"G-BLD-ORBIT-BYTES: enforced ledger %.2f MB <= cap %.0f MB (nearest-first stop-at-cap)" % [node.total_bytes() / 1048576.0, CubeSphere.BLOCK_LOD_ORBIT_BYTES_MAX / 1048576.0])
	_ok(node.draw_count() <= CubeSphere.BLOCK_LOD_ORBIT_DRAWS,
		"G-BLD-ORBIT-BYTES: merged into %d draws <= %d (gl_compat draw-ceiling safe - merged by cube face)" % [node.draw_count(), CubeSphere.BLOCK_LOD_ORBIT_DRAWS])
	var combined := node.total_bytes() + 0
	_ok(combined < (40 << 20), "G-BLD-ORBIT-BYTES: combined budget %.2f MB < 40 MB (V2 skin retired frees ~8.2 MB)" % (combined / 1048576.0))
	var recomputed := 0
	for face in node._mesh_groups:
		var mi: MeshInstance3D = node._mesh_groups[face]
		var sa := mi.mesh.surface_get_arrays(0)
		var nv: int = (sa[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var ni: int = (sa[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
		recomputed += nv * FacetBlockLodRing.BYTES_PER_VERT + ni * FacetBlockLodRing.BYTES_PER_INDEX
	_ok(recomputed == node.total_bytes(), "G-BLD-ORBIT-BYTES: ledger(%d B) == arithmetic from the committed meshes(%d B)" % [node.total_bytes(), recomputed])

	# ---- G-BLD-ORBIT-BYTES (arithmetic, WHOLE disc): the LADDER is load-bearing - uniform L4 busts the budget --------
	var n_total := disc.size()
	var quads_est := {4: 248, 5: 62}
	var uni_l4 := FacetBlockLodOrbit.peak_bytes_for({4: n_total}, quads_est)
	var uni_l5 := FacetBlockLodOrbit.peak_bytes_for({5: n_total}, quads_est)
	_ok(uni_l4 > (40 << 20), "G-BLD-ORBIT-BYTES: uniform-L4 disc estimate %.1f MB > 40 MB - crisp hemisphere infeasible (WHY the ladder)" % (uni_l4 / 1048576.0))
	_ok(uni_l5 > CubeSphere.BLOCK_LOD_ORBIT_BYTES_MAX and uni_l5 < uni_l4,
		"G-BLD-ORBIT-BYTES: uniform-L5 disc estimate %.1f MB BUSTS the %.0f MB orbit cap (< L4's %.1f MB) - the per-facet ladder + cap-drop are load-bearing" % [uni_l5 / 1048576.0, CubeSphere.BLOCK_LOD_ORBIT_BYTES_MAX / 1048576.0, uni_l4 / 1048576.0])

	# ---- G-BLD-ORBIT-MIN: no-protrusion — the megablock top <= the TRUE terrain EVERYWHERE in the coarse cell ---------
	# The orbit columns come from the EXACT FacetBlockLod MIN decimate chain (top = MIN over ALL fine L0 cells), so the
	# coarse top sits at-or-below the true fine surface at EVERY point, not just at sparse samples. Test it against a
	# dense true-terrain grid (every 4 blocks inside a few coarse cells): assert top <= each true height AND top == MIN
	# over those samples (the decimation is a MIN). Teeth: relief present (MAX>MIN) ⇒ a MAX-rule top WOULD protrude.
	var contain_ok := true          # coarse top <= the TRUE terrain at every dense sample (real no-protrusion)
	var mineq_ok := true            # coarse top == MIN of the dense true samples (exact-MIN decimation, not max/mean)
	var relief_seen := false        # MAX(samples) > MIN(samples) somewhere ⇒ the MIN rule is load-bearing
	var checked := 0
	for fid in node.covered_fids():
		if checked >= 12:
			break
		checked += 1
		var lvl := node.level_of(fid)
		var cols := node._bake_cols(fid, lvl)
		var w: int = cols["w"]
		var h: int = cols["h"]
		var top: PackedInt32Array = cols["top"]
		var pitch := 1 << lvl
		var dmin := FacetAtlas.dom_min(fid)
		var dmax := FacetAtlas.dom_max(fid)
		var w0 := dmax.x - dmin.x + 1               # the L0 domain the pyramid decimated (boundary coarse cells are partial)
		var h0 := dmax.y - dmin.y + 1
		for cz in range(0, h, maxi(h / 2, 1)):
			for cx in range(0, w, maxi(w / 2, 1)):
				var ct: int = top[cz * w + cx]
				var tmin := 0x7fffffff
				var tmax := -0x7fffffff
				var span_x := mini(pitch, w0 - cx * pitch)   # clamp the sweep to the PRESENT L0 children only
				var span_z := mini(pitch, h0 - cz * pitch)
				for sz in range(0, span_z, 4):          # dense TRUE-terrain sweep over the present L0 cells (every 4 blocks)
					for sx in range(0, span_x, 4):
						var lx := dmin.x + cx * pitch + sx
						var lz := dmin.y + cz * pitch + sz
						var g := int(TerrainConfig.facet_profile(fid, lx, lz).x)
						if ct > g:
							contain_ok = false          # coarse top poked above the TRUE terrain — a protrusion
						if g < tmin: tmin = g
						if g > tmax: tmax = g
				if ct > tmin:                            # top must be <= the true minimum over the cell
					mineq_ok = false
				if tmax > tmin:
					relief_seen = true
	_ok(contain_ok and mineq_ok, "G-BLD-ORBIT-MIN: megablock top <= the TRUE terrain everywhere in the coarse cell (exact-MIN, no protrusion) - %d facets" % checked)
	_ok(relief_seen, "G-BLD-ORBIT-MIN falsifier: relief present (MAX>MIN in a coarse cell) — a MAX-height decimation WOULD protrude (MIN rule load-bearing)")

	# ---- G-BLD-ORBIT-RETIRE: the V2-retire predicate - orbit-covered facets are the retire set ---------------------
	var levels_ok := true
	for fid in node.covered_fids():
		var lv2 := node.level_of(fid)
		if lv2 < MIN_L or lv2 > MAX_L:
			levels_ok = false
	_ok(levels_ok and node.covered_fids().size() > 0,
		"G-BLD-ORBIT-RETIRE: orbit tier covers %d facets ALL at L4..L5 - the V2-retire set (block owns them, no double-draw)" % node.covered_fids().size())
	var eng_at_orbit := CubeSphere.block_lod_orbit_engaged(8000.0, false)
	_ok(eng_at_orbit, "G-BLD-ORBIT-RETIRE: at alt 8000 the tier ENGAGES => far-ring V2 skin suppressed (retire, not overlay)")

	# ---- G-BLD-ORBIT-EMPTY: on the surface the tier is inert -------------------------------------------------------
	var surf := FacetBlockLodOrbit.new()
	root.add_child(surf)
	surf.setup(afid)
	var eng_surf := surf.set_camera(u, FacetAtlas.R_BLOCKS + 0.0)
	_ok(not eng_surf and surf.total_bytes() == 0 and surf.covered_fids().is_empty(),
		"G-BLD-ORBIT-EMPTY: on the surface the orbit tier is DISENGAGED - no mesh, 0 bytes, nothing covered")

	print("  INFO orbit: disc=%d facets  bounded-build=%d facets  ledger=%.2f MB (cap %.0f MB)  draws=%d  coarsen=%d  dropped=%d" % [
		disc.size(), unit.disc.size(), node.total_bytes() / 1048576.0, CubeSphere.BLOCK_LOD_ORBIT_BYTES_MAX / 1048576.0,
		node.draw_count(), node.coarsen_events(), node.dropped_limb()])
	node.queue_free()
	surf.queue_free()
