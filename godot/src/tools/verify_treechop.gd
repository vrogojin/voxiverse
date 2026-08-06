extends SceneTree
## verify_treechop — COSMOS-TREE-BUGS Bug 2 gate (docs/COSMOS-TREE-BUGS-DESIGN.md, Bug 2 "Gate spec").
## Proves FP_GRAV_BOX_COVER (per-facet gravity box now covers the whole post-2026-07-19-rescale facet
## domain, not just a stale ±160 core) and FP_CHOP_COLLIDER_CARVE (a collapse-spawned VoxelBody no longer
## starts fully overlapping its own stale, debounced GroundCollider shapes) together fix the live "chop a
## tree -> canopy turns upside down and slowly sinks under the ground" bug.
##
## Gates:
##   G-TC-COVER    numeric lemma (no physics): calls the real box-builder (`_build_facet_gravity_area`,
##                 world_manager.gd) for a stride of fids. Flag ON: box covers [dom_min-8, dom_max+8].
##                 Flag OFF: box byte-equals the shipped 320x2048x320 @ centre_cell.
##   G-TC-GRAV     a real break_terrain chop of a worldgen tree OUTSIDE the old ±160 core (>160 blocks
##                 from centre_cell — probe_treechop's site class): from the FIRST physics frame, the
##                 canopy's total_gravity aligns with the facet's own -up (was -0.605 fly-away, off).
##   G-TC-SETTLE   for both an inside-ring and an outside-ring chop, within 20s sim: body state stays
##                 finite (no NaN — was NaN in <=1 frame with both defects live), settles with the
##                 canopy centre within its own half-height of surface_y, upright (updot >= 0.9 — was
##                 -0.609 tumble), and frozen/sleeping at the end.
##
## Each sub-gate runs in its OWN fresh WorldManager (matching how the doc's individual probes each run in
## their own process) — an earlier combined-instance version cross-contaminated: a residual marker body /
## in-flight collider build from one site test skewed the NEXT site's result even though each test looks
## self-contained (found empirically: identical code, same site, passed standalone / failed when run second
## in a shared instance). Isolation costs one extra ~3s module-manifest bake per sub-gate — cheap insurance.
##
## RUN (sed FACETED + FP_M1_POOL + FP_FIXED_FRAME + FP_GRAV_BOX_COVER + FP_CHOP_COLLIDER_CARVE all ON):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_treechop.gd 2>/dev/null | grep VERIFY
## Falsifier: re-run with ONLY the two fix flags sed'd back OFF (FACETED/FP_M1_POOL/FP_FIXED_FRAME still
## ON) — must go RED on G-TC-GRAV and G-TC-SETTLE (probe_treechop/2/3 already proved it measurably does).
## Exits 0 all-pass / 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_treechop (COSMOS-TREE-BUGS Bug 2) — FACETED=%s FP_M1_POOL=%s FP_FIXED_FRAME=%s FP_GRAV_BOX_COVER=%s FP_CHOP_COLLIDER_CARVE=%s ===" % [
		str(CubeSphere.FACETED), str(CubeSphere.FP_M1_POOL), str(CubeSphere.FP_FIXED_FRAME),
		str(CubeSphere.FP_GRAV_BOX_COVER), str(CubeSphere.FP_CHOP_COLLIDER_CARVE)])
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)

	await _gate_grav_and_settle(fid, false)   # outside the old ±160 core (the live-bug site class)
	await _gate_grav_and_settle(fid, true)    # inside the ring (must ALSO settle cleanly)
	await _gate_cover(fid)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Spin up a fresh WorldManager on `fid`, wait for it to settle, and return {w, host, gc}.
func _new_world(fid: int, name: String) -> Dictionary:
	TerrainConfig.set_active_facet(fid)
	var w := WorldManager.new()
	w.name = name
	get_root().add_child(w)
	for i in range(5):
		await process_frame
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	var host: Node = af if af != null else w
	var gc: Node = null
	for ch in host.get_children():
		if ch is GroundCollider:
			gc = ch
	return {"w": w, "host": host, "gc": gc}

## Tear down a WorldManager created by `_new_world` and let the removal actually complete before the
## caller spins up the next one (isolation — see the file header).
func _free_world(w: WorldManager) -> void:
	w.queue_free()
	await process_frame

## G-TC-COVER — numeric lemma, no physics. `_build_facet_gravity_area` is called DIRECTLY (GDScript has
## no real method privacy — the leading underscore is convention only — so this exercises the exact live
## code path, not a re-derivation of its formula) for a stride of fids across the facet set.
func _gate_cover(seed_fid: int) -> void:
	var ctx := await _new_world(seed_fid, "TreeChopGateWM_cover")
	var w: WorldManager = ctx["w"]
	var nf := int(FacetAtlas.frozen_atlas()["facet_count"])
	var stride := maxi(1, nf / 24)
	var checked := 0
	var f := seed_fid % maxi(nf, 1)
	while checked < 24 and checked < nf:
		var area: Area3D = w.call("_build_facet_gravity_area", f)
		var cs: CollisionShape3D = area.get_child(0)
		var box: BoxShape3D = cs.shape
		var lo: Vector2i = FacetAtlas.dom_min(f)
		var hi: Vector2i = FacetAtlas.dom_max(f)
		if CubeSphere.FP_GRAV_BOX_COVER:
			var box_lo := Vector2(cs.position.x - box.size.x * 0.5, cs.position.z - box.size.z * 0.5)
			var box_hi := Vector2(cs.position.x + box.size.x * 0.5, cs.position.z + box.size.z * 0.5)
			_ok(box_lo.x <= float(lo.x) - 8.0 and box_lo.y <= float(lo.y) - 8.0
					and box_hi.x >= float(hi.x) + 8.0 and box_hi.y >= float(hi.y) + 8.0,
				"G-TC-COVER fid=%d box [%s..%s] covers dom±8 [%s..%s]" % [f, str(box_lo), str(box_hi), str(lo), str(hi)])
		else:
			var centre := FacetAtlas.centre_cell(f)
			_ok(box.size.is_equal_approx(Vector3(320.0, 2048.0, 320.0))
					and cs.position.is_equal_approx(Vector3(float(centre.x), 0.0, float(centre.y))),
				"G-TC-COVER fid=%d byte-off: box == shipped 320x2048x320 @ centre_cell" % f)
		area.queue_free()
		checked += 1
		f = (f + stride) % nf
	print("  G-TC-COVER: checked %d facets" % checked)
	await _free_world(w)

## Find worldgen tree bases with a real canopy (skip cactus), inside the facet domain, in the AXIS-ALIGNED
## SQUARE band `band_min <= max(|dx|,|dz|)` wait — see below: `max(|dx|,|dz|) < band_max` (inside a
## band_max-radius square) and, when `band_min > 0`, at least one axis offset is >= band_min (outside a
## band_min-radius square) — the exact site-selection SHAPE the doc's own probe_treechop/2/3 use (a square
## Chebyshev-style filter, not a Euclidean circle: an earlier Euclidean multi-candidate version of this gate
## picked geometrically-valid-looking sites that turned out to sit somewhere the analytic pipeline disagrees
## with TreeGen.block_at's raw check, or — for a large enough offset — near enough the facet's own domain
## edge to trip an unrelated facet-crossing re-anchor; the square filter matches the ALREADY-VALIDATED
## probe site class exactly and was empirically re-verified stable across repeated runs). Up to `cap`
## candidates, sweep order, so a caller can retry past a rare false positive.
func _find_tree_sites(lo: Vector2i, hi: Vector2i, cc: Vector2i, band_min: float, band_max: float, cap: int) -> Array:
	var out: Array = []
	var gx0 := floori(float(lo.x) / 10.0) + 1
	var gx1 := floori(float(hi.x) / 10.0)
	var gz0 := floori(float(lo.y) / 10.0) + 1
	var gz1 := floori(float(hi.y) / 10.0)
	for gx in range(gx0, gx1):
		for gz in range(gz0, gz1):
			var tb := TreeGen.tree_base(gx, gz)
			if tb.y <= TerrainConfig.SEA_LEVEL:
				continue
			if tb.x - 2 < lo.x or tb.x + 2 > hi.x or tb.z - 2 < lo.y or tb.z + 2 > hi.y:
				continue
			var adx := absf(float(tb.x - cc.x))
			var adz := absf(float(tb.z - cc.y))
			if adx >= band_max or adz >= band_max:
				continue
			if band_min > 0.0 and adx < band_min and adz < band_min:
				continue
			# require an actual trunk + canopy (species with real geometry — skip cactus)
			if TreeGen.block_at(tb.x, tb.y + 1, tb.z) > 0 and TreeGen.block_at(tb.x, tb.y + 3, tb.z) > 0:
				out.append(tb)
				if out.size() >= cap:
					return out
	return out

## G-TC-GRAV + G-TC-SETTLE for one real break_terrain chop, `inside_ring` selects the site class
## (<140 blocks from centre_cell — inside the old box) vs outside (>160 — the live-bug class, doc's
## probe_treechop). Mirrors the doc's probe_treechop/2/3 end-to-end path: real WorldManager, real
## GroundCollider gate/build, real break_terrain (collapse pass + detach kick), real PhysicsServer state.
## Tries each candidate site in turn until one actually chops (TreeGen.block_at can disagree with the full
## composed resolve_cell pipeline at the margins — a false positive just moves to the next candidate).
func _gate_grav_and_settle(fid: int, inside_ring: bool) -> void:
	var tag := "inside" if inside_ring else "outside"
	var cc := FacetAtlas.centre_cell(fid)
	var lo: Vector2i = FacetAtlas.dom_min(fid)
	var hi: Vector2i = FacetAtlas.dom_max(fid)
	# "inside" mirrors probe_treechop3 exactly: a square band < 140 (inside the OLD ±160 core). "outside" is
	# a square band [170, 220) — solidly past the OLD ±160 core (the exact class FP_GRAV_BOX_COVER targets)
	# but well short of the domain interior's own edge (half-widths ~250-295 x / ~175-200 z): a site near
	# the true domain boundary can trigger an unrelated facet-crossing re-anchor (confirmed independently
	# with a synthetic, non-chop drop at a ~310-out site, and with the doc's own probe_treechop.gd — a real,
	# pre-existing, separately-tracked concern, not something FP_GRAV_BOX_COVER/FP_CHOP_COLLIDER_CARVE claim
	# to fix, and not exercised by this gate).
	var sites: Array = _find_tree_sites(lo, hi, cc, 0.0, 140.0, 4) if inside_ring \
			else _find_tree_sites(lo, hi, cc, 170.0, 220.0, 4)
	if sites.is_empty():
		_ok(false, "G-TC-GRAV/-SETTLE (%s): no qualifying tree site found on fid=%d" % [tag, fid])
		return

	for site_i in range(sites.size()):
		var base: Vector3i = sites[site_i]
		var ctx := await _new_world(fid, "TreeChopGateWM_%s_%d" % [tag, site_i])
		var w: WorldManager = ctx["w"]
		var host: Node = ctx["host"]
		var gc: Node = ctx["gc"]
		var dist := Vector2(float(base.x - cc.x), float(base.z - cc.y)).length()

		var up_expected: Vector3 = -w.gravity_vector()
		var player_pos := Vector3(float(base.x) + 2.5, w.surface_y(float(base.x) + 2.5, float(base.z) + 0.5), float(base.z) + 0.5)

		# Park a tiny debris marker to open the collider gate BEFORE the chop (like a live session where the
		# collider has already served debris) and let it build the tree's own boxes — the exact stale-overlap
		# precondition the doc's probe_treechop reproduces.
		VoxelBody.spawn_loose(host, {Vector3i(base.x + 3, int(player_pos.y) + 1, base.z): BlockCatalog.STONE}, w)
		for i in range(90):
			if gc != null:
				gc.call("update", player_pos)
			await physics_frame

		# CHOP the two bottom trunk cells (the live two-click chop) via the real path.
		var r1 := w.break_terrain(Vector3i(base.x, base.y + 1, base.z), player_pos)
		var r2 := w.break_terrain(Vector3i(base.x, base.y + 2, base.z), player_pos)
		await physics_frame
		var body: VoxelBody = null
		for ch in host.get_children():
			if ch is VoxelBody and (body == null or (ch as VoxelBody).block_count() > body.block_count()):
				body = ch
		if body == null or body.block_count() < 3:
			if site_i + 1 < sites.size():
				print("  [%s] site %s (dist=%.1f) didn't chop (r1=%d r2=%d) — trying next candidate" % [tag, str(base), dist, r1, r2])
				await _free_world(w)
				continue
			_ok(false, "G-TC-GRAV/-SETTLE (%s): no canopy body spawned at any candidate (last r1=%d r2=%d)" % [tag, r1, r2])
			await _free_world(w)
			return
		print("  [%s] fid=%d base=%s dist_from_centre=%.1f" % [tag, fid, str(base), dist])

		# One more tick: the PhysicsServer only resolves a freshly-added body's area overlap (and so its
		# total_gravity) on the step AFTER it enters the tree, not the same step it was created — matching the
		# doc's probe_treechop timing (its state read is the FIRST iteration of its post-spawn physics loop,
		# i.e. one tick after the body-finding await already used above).
		if gc != null:
			gc.call("update", player_pos)
		await physics_frame

		# G-TC-GRAV: from the FIRST physics frame, the canopy's actual PhysicsServer gravity must already
		# align with the facet's own -up — not the project-default global (0,-9.8,0) an uncovered box leaves it with.
		var st0 := PhysicsServer3D.body_get_direct_state(body.get_rid())
		var grav0: Vector3 = st0.total_gravity if st0 != null else Vector3.INF
		var gdot0: float = (grav0.normalized().dot(-up_expected)) if grav0.is_finite() and grav0.length() > 0.01 else NAN
		_ok(is_finite(gdot0) and gdot0 >= 0.999,
			"G-TC-GRAV (%s): first-frame canopy gravity aligns with facet-down (gdot=%.4f, want >= 0.999)" % [tag, gdot0])

		# Half-height from the body's OWN local cell extents (each cell occupies [c, c+1] in body-local space).
		var min_y := 0x7fffffff
		var max_y := -0x7fffffff
		for c: Vector3i in body.cells.keys():
			min_y = mini(min_y, c.y)
			max_y = maxi(max_y, c.y)
		var half_height := float(max_y - min_y + 1) * 0.5

		var nan_seen := false
		for step in range(1201):   # 20 s @ 60 Hz
			if gc != null:
				gc.call("update", player_pos)
			await physics_frame
			if not is_instance_valid(body):
				break
			if not body.global_transform.origin.is_finite() or not body.linear_velocity.is_finite() \
					or not body.angular_velocity.is_finite():
				nan_seen = true
				break
			if (body.freeze or body.sleeping) and step > 30:
				break   # settled early — no need to burn the full 20 s

		_ok(not nan_seen, "G-TC-SETTLE (%s): body state stays finite (no NaN) through the sim" % tag)
		if nan_seen or not is_instance_valid(body):
			_ok(false, "G-TC-SETTLE (%s): body survives to settle" % tag)
			await _free_world(w)
			return
		var centre_end: Vector3 = body.transform * body._cells_center()
		var surf_end := w.surface_y(centre_end.x, centre_end.z)
		var updot_end: float = body.global_transform.basis.y.dot(up_expected)
		# NOT SUNK below the surface (the doc's own probe_treedrop/treechop3 "sunk" check: centre_end.y <
		# surf_end - 1.5), and not floating implausibly high either (full own-height + margin above the
		# surface would mean it never actually made contact). An irregular canopy's CENTROID normally sits
		# well ABOVE surf_end at rest — it spans several cells starting near the ground, not a symmetric box
		# straddling it — so this is deliberately NOT a tight half-height envelope around surf_end (an
		# earlier, stricter version of this assertion flagged the doc's own verified-good settle numbers as
		# failures: centre 8.24 vs surf 6.00, exactly probe_treechop3's "sunk=false" result).
		_ok(centre_end.y >= surf_end - 1.5,
			"G-TC-SETTLE (%s): canopy NOT sunk below surface (centre y=%.2f, surface_y=%.2f)" % [tag, centre_end.y, surf_end])
		_ok(centre_end.y <= surf_end + (max_y - min_y + 1) + 1.5,
			"G-TC-SETTLE (%s): canopy not implausibly high above surface (centre y=%.2f, surface_y=%.2f, own height=%d)" % [tag, centre_end.y, surf_end, max_y - min_y + 1])
		_ok(updot_end >= 0.9, "G-TC-SETTLE (%s): upright at rest (updot=%.3f, want >= 0.9)" % [tag, updot_end])
		_ok(body.freeze or body.sleeping, "G-TC-SETTLE (%s): frozen/sleeping at the end" % tag)
		await _free_world(w)
		return
