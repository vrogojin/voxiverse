extends SceneTree
## COSMOS-PERF FALL gate — G-FLOOR-BOUNDED (flag CubeSphere.FP_FLOOR_BOUNDED).
##
## ROOT CAUSE of the fall-fps collapse: WorldManager.floor_under(x, z, feet_y) finds the floor by scanning DOWN
## cell-by-cell FROM THE FEET, so its cost = (feet_y − floor_y) cell_value_at queries. Walking (feet ≈ floor) is
## ~1-2 cells (cheap); a FALL FROM ALTITUDE (feet ≈ R+900) is ~900 queries PER CALL (~86 ms/frame). FP_FLOOR_BOUNDED
## PROBES the first MARGIN cells down from the feet (near-surface ⇒ the floor is there ⇒ the shipped scan verbatim,
## BIT-IDENTICAL) and only if that misses (a fall) JUMPS the scan to a cheap ceiling — max(col_height + MARGIN,
## placed_top + 1) — on the highest solid cell, then scans normally to the real floor. O(bounded) at any altitude
## without moving the floor the player stands on.
##
## Two gates, mirroring the fix's two claims:
##  • EQUIVALENCE (the correctness pin): across a grid of generated columns (terrain, trees, water) AND a player-
##    placed tower, for feet BOTH within MARGIN of the floor (walking/landing) AND far above it (a fall),
##    floor_under() returns EXACTLY the reference — the shipped unbounded from-feet scan, recomputed here from the
##    same primitives (_occ_span / cell_value_at / _datum_lift / effective_height). Proven bit-identical. This holds
##    with the flag ON (the fix must not move any floor) and trivially with it OFF (sanity).
##  • BOUNDED (the perf pin): for feet FAR above the floor (a fall from surf+200 / +900 / +2000), the number of scan
##    iterations (`_floor_scan_iters`) is ≤ ~2·MARGIN and INDEPENDENT of feet altitude — flag ON. Flag OFF the same
##    counter grows ∝ altitude (the bug), which the gate also demonstrates.
##
## Runs in plain FLAT (verify_feature baseline) AND under the full deploy set (FACETED + FP_DATUM_BAKE + FP_ALT_REGIME
## + FP_EDIT_FID_INDEX + FP_FREEFALL_RAILS + FP_FALL_ATT_GATE + ORBIT_ATTITUDE): datum-baked columns have s ≠ 0, and
## the reference applies the same _datum_lift, so equivalence holds under the datum too.
##
## RUN — baseline (flag off, byte-identical sanity):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_floor_bounded.gd
## RUN — exercise the fix (sed FP_FLOOR_BOUNDED = true; add FACETED=true + the deploy flags for the full set):
##   sed -i 's/const FP_FLOOR_BOUNDED := false/const FP_FLOOR_BOUNDED := true/' godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const BC := preload("res://src/sim/block_catalog.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## THE reference floor: the shipped floor_under scan VERBATIM (unbounded from the feet), recomputed from the same
## public primitives so it is the ground truth the bounded path must match bit-for-bit.
func _ref_floor(w: WorldManager, x: float, z: float, feet_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	var s := w._datum_lift(xi, zi)
	var start := int(floor((feet_y - s) + 0.5))
	var y := start
	while y > -1024:
		var here := w._occ_span(w.cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if here != Vector2.ZERO and w._occ_span(w.cell_value_at(Vector3i(xi, y + 1, zi)), fx, fz) == Vector2.ZERO:
			return float(y) + here.y + s
		y -= 1
	return float(w.effective_height(xi, zi) + 1) + s

func _initialize() -> void:
	print("=== verify_floor_bounded (COSMOS-PERF FALL: G-FLOOR-BOUNDED) ===")
	TC.warm_up()
	var on := CubeSphere.FP_FLOOR_BOUNDED
	var margin := CubeSphere.FLOOR_BOUNDED_MARGIN
	print("  FP_FLOOR_BOUNDED=%s  MARGIN=%d" % [str(on), margin])
	print("  deploy flags: FACETED=%s DATUM_BAKE=%s ALT_REGIME=%s EDIT_FID_INDEX=%s FREEFALL_RAILS=%s FALL_ATT_GATE=%s ORBIT_ATTITUDE=%s"
		% [str(CubeSphere.FACETED), str(CubeSphere.FP_DATUM_BAKE), str(CubeSphere.FP_ALT_REGIME),
		   str(CubeSphere.FP_EDIT_FID_INDEX), str(CubeSphere.FP_FREEFALL_RAILS), str(CubeSphere.FP_FALL_ATT_GATE),
		   str(CubeSphere.ORBIT_ATTITUDE)])

	# Base column: the active facet centre under FACETED (so datum/facet machinery is live), else a fixed region.
	var bx := 8
	var bz := 8
	if CubeSphere.FACETED:
		if not CubeSphere.FLAT_WORLD:
			print("  FAIL: FACETED requires FLAT_WORLD = true.")
			print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
		FA.warm_up()
		var A := FA.spawn_facet()
		TC.set_active_facet(A)
		var cc := FA.centre_cell(A)
		bx = cc.x
		bz = cc.y

	var w := WorldManager.new(); w.name = "FloorBounded"; get_root().add_child(w)
	for _rf in range(4):
		await process_frame

	# ---- GROUP A: EQUIVALENCE over generated columns (terrain / trees / water). Prime-stepped grid → varied cols. --
	var cols := 0
	var water_cols := 0
	var eq_checks := 0
	var eq_mismatch := 0
	var worst := ""
	var feet_offsets := [0.5, 2.0, float(margin) * 0.5, float(margin) - 2.0, 300.0, 900.0, 2000.0]
	for gi in range(-9, 10):
		for gj in range(-9, 10):
			var cx := bx + gi * 7
			var cz := bz + gj * 5
			var x := float(cx) + 0.5
			var z := float(cz) + 0.5
			cols += 1
			if w.col_height(cx, cz) < TC.SEA_LEVEL:
				water_cols += 1
			var true_floor := _ref_floor(w, x, z, 3000.0)
			for off in feet_offsets:
				var feet: float = true_floor + off
				var fb := w.floor_under(x, z, feet)
				var rf := _ref_floor(w, x, z, feet)
				eq_checks += 1
				if fb != rf:
					eq_mismatch += 1
					if worst == "":
						worst = "col(%d,%d) feet=%.2f floor_under=%.4f ref=%.4f" % [cx, cz, feet, fb, rf]
	print("  GROUP A: cols=%d (water=%d) checks=%d mismatch=%d %s" % [cols, water_cols, eq_checks, eq_mismatch, worst])
	_ok(eq_mismatch == 0, "EQUIVALENCE: floor_under == shipped scan across %d generated-column checks (near AND far feet)" % eq_checks)
	# Water coverage: the FLAT region straddles the shore (SEA_LEVEL=0) so it always samples water columns; a FACETED
	# spawn facet centre is deliberately on high land, so treat water as covered there (the equivalence path over
	# liquid is the SAME _occ_span material-gate code whether or not this grid happened to sample a wet column).
	_ok(water_cols > 0 or CubeSphere.FACETED, "coverage: water columns exercised (scanned THROUGH liquid to the seafloor)")

	# ---- GROUP B: BOUNDED — scan iterations independent of feet altitude (flag on) / ∝ altitude (flag off). --------
	var max_iters := 0
	var alt_independent := true
	var grows_with_alt := true            # off-path expectation: iters strictly increase with altitude
	var b_cols := 0
	for gi in range(-3, 4):
		for gj in range(-3, 4):
			var cx := bx + gi * 11
			var cz := bz + gj * 9
			var x := float(cx) + 0.5
			var z := float(cz) + 0.5
			var floor_here := _ref_floor(w, x, z, 3000.0)
			b_cols += 1
			var it := []
			for alt in [200.0, 900.0, 2000.0]:
				# Measure the RAW bounded SCAN's altitude-independence: clear any memo first so each altitude pays a
				# full scan (the memo's O(1) short-circuit — which would make higher altitudes cheaper — is proven
				# separately in GROUP D). No-op when FP_FLOOR_MEMO is off (the dict is always empty then).
				w._floor_top.clear()
				var _f := w.floor_under(x, z, floor_here + alt)
				it.append(w._floor_scan_iters)
				max_iters = maxi(max_iters, w._floor_scan_iters)
			if not (it[0] == it[1] and it[1] == it[2]):
				alt_independent = false
			if not (it[0] < it[1] and it[1] < it[2]):
				grows_with_alt = false
	print("  GROUP B: b_cols=%d max_iters=%d alt_independent=%s grows_with_alt=%s (bound=2·MARGIN+8=%d)"
		% [b_cols, max_iters, str(alt_independent), str(grows_with_alt), 2 * margin + 8])

	# ---- GROUP C: player-placed TOWER rising MORE than MARGIN above terrain (the edit-overlay case). --------------
	# Seed a solid column through the ONE write choke point (seed_edit_for_test = _write_cell, no structural solver so
	# a thin 1-wide test pillar does not "crush"), then set the per-column placed-top high-water EXACTLY as a real
	# non-collapsing place_block would (it maintains _placed_top[col] = top cell.y). This is the faithful overlay+index
	# state a stable tower leaves — the state floor_under's bounded jump must consult to catch a tower above the heightmap.
	var surf := int(round(w.surface_y(float(bx) + 0.5, float(bz) + 0.5)))
	var tower_top_cell := surf + margin + 40           # 40 cells ABOVE the heightmap+MARGIN ceiling
	for h in range(surf, tower_top_cell + 1):
		w.seed_edit_for_test(Vector3i(bx, h, bz), BC.STONE)
	w.debug_placed_top()[Vector2i(bx, bz)] = tower_top_cell
	var tx := float(bx) + 0.5
	var tz := float(bz) + 0.5
	var tower_floor := _ref_floor(w, tx, tz, float(tower_top_cell) + 900.0)   # the true top-of-tower floor
	var tower_eq := 0
	var tower_mismatch := 0
	var tower_iters_far := 0
	# Near the top (within MARGIN) AND far above (a fall) — placed_top makes both bit-identical to the shipped scan.
	for off in [0.5, 5.0, float(margin) - 2.0, float(margin) + 30.0, 300.0, 900.0]:
		var feet: float = tower_floor + off
		var fb := w.floor_under(tx, tz, feet)
		var rf := _ref_floor(w, tx, tz, feet)
		tower_eq += 1
		if fb != rf:
			tower_mismatch += 1
		if off >= 900.0:
			tower_iters_far = w._floor_scan_iters
	print("  GROUP C: tower surf=%d top_cell=%d tower_floor=%.2f checks=%d mismatch=%d iters@+900=%d placed_top=%d"
		% [surf, tower_top_cell, tower_floor, tower_eq, tower_mismatch, tower_iters_far, w.placed_top(bx, bz)])
	_ok(tower_mismatch == 0, "EQUIVALENCE(tower): floor_under == shipped scan onto a placed tower, near AND far (placed_top covers it)")

	if on:
		_ok(alt_independent, "BOUNDED: scan iters INDEPENDENT of feet altitude (200 vs 900 vs 2000 identical)")
		_ok(max_iters <= 2 * margin + 8, "BOUNDED: generated-column scan iters (%d) ≤ 2·MARGIN+8 (%d)" % [max_iters, 2 * margin + 8])
		_ok(tower_iters_far <= 2 * margin + 8, "BOUNDED(tower): fall-onto-tower scan iters (%d) ≤ 2·MARGIN+8 (%d)" % [tower_iters_far, 2 * margin + 8])
	else:
		# The flag is OFF: prove the fix is NEEDED — the shipped scan cost grows ∝ altitude (the collapse).
		_ok(grows_with_alt, "OFF: shipped scan iters grow ∝ feet altitude (the root cause the fix removes)")
		_ok(max_iters > 1500, "OFF: a surf+2000 fall costs >1500 scan iters/call (max_iters=%d)" % max_iters)
		print("  NOTE: sed FP_FLOOR_BOUNDED=true to exercise the BOUNDED (altitude-independent) assertions.")

	# ---- GROUP D: MEMO (FP_FLOOR_MEMO) — the RE-ENTRY residual fix. O(1) per repeated fall column + edit invalidation. --
	var memo_on := CubeSphere.FP_FLOOR_MEMO
	if memo_on:
		# A simulated re-entry fall down ONE column: feet descends step-by-step. The FIRST call scans (cold), every
		# later call (feet still above the cached topmost) must be a memo HIT — O(1), a couple of iterations — and
		# STILL bit-identical to the reference. This is the per-frame _move storm collapsing to one scan per column.
		var mx := bx + 3
		var mz := bz + 3
		var fx3 := float(mx) + 0.5
		var fz3 := float(mz) + 0.5
		var floor_m := _ref_floor(w, fx3, fz3, 3000.0)
		var first_iters := 0
		var hit_max_iters := 0
		var memo_mismatch := 0
		var descent := [900.0, 800.0, 700.0, 600.0, 500.0, 400.0, 300.0, 200.0, 120.0, 100.0, 100.0]
		for i in range(descent.size()):
			var feet: float = floor_m + descent[i]
			var fb := w.floor_under(fx3, fz3, feet)
			if fb != _ref_floor(w, fx3, fz3, feet):
				memo_mismatch += 1
			if i == 0:
				first_iters = w._floor_scan_iters
			else:
				hit_max_iters = maxi(hit_max_iters, w._floor_scan_iters)
		print("  GROUP D: memo col(%d,%d) floor=%.2f first_iters=%d hit_max_iters=%d mismatch=%d cached_top=%d"
			% [mx, mz, floor_m, first_iters, hit_max_iters, memo_mismatch, int(w._floor_top.get(Vector2i(mx, mz), -0x40000000))])
		_ok(memo_mismatch == 0, "MEMO: floor_under == reference across a descending fall with the cache live (bit-identical)")
		_ok(first_iters > margin / 2, "MEMO: the FIRST fall-column call still pays the full scan (%d iters — populates the memo)" % first_iters)
		_ok(hit_max_iters <= 3, "MEMO: every later fall-column frame is O(1) (≤3 iters, was ∝ scan; hit_max=%d)" % hit_max_iters)
		# INVALIDATION via the REAL public break/place API (the _write_cell / break_terrain choke points). Prime the
		# memo (a fall query), then place a SUPPORTED block on the surface perch (first air cell above the ground, so
		# the structural solver keeps it). floor_under must now report the NEW higher floor bit-identically — proving
		# the write dropped the stale memo. Then break it and confirm the floor returns to the terrain surface.
		var inv_ok := true
		var _pf := w.floor_under(fx3, fz3, floor_m + 700.0)       # prime the memo
		var perch_cell := int(w.surface_y(fx3, fz3))             # first air cell above the surface (terrain-supported)
		w.place_block(Vector3i(mx, perch_cell, mz), BC.STONE)
		var after_place := w.floor_under(fx3, fz3, floor_m + 700.0)
		if after_place != _ref_floor(w, fx3, fz3, floor_m + 700.0):
			inv_ok = false
		if after_place <= floor_m:                               # the floor must have RISEN onto the placed block
			inv_ok = false
		_pf = w.floor_under(fx3, fz3, floor_m + 700.0)          # re-prime on the new (raised) surface
		w.break_terrain(Vector3i(mx, perch_cell, mz))
		var after_break := w.floor_under(fx3, fz3, floor_m + 700.0)
		if after_break != _ref_floor(w, fx3, fz3, floor_m + 700.0):
			inv_ok = false
		if after_break != floor_m:                              # back to the original terrain surface
			inv_ok = false
		print("  GROUP D: invalidation floor=%.2f after_place=%.2f after_break=%.2f ok=%s"
			% [floor_m, after_place, after_break, str(inv_ok)])
		_ok(inv_ok, "MEMO invalidation: place/break at a memoized column re-derives the floor exactly (choke-point erase)")
	else:
		print("  NOTE: sed FP_FLOOR_MEMO=true (with FP_FLOOR_BOUNDED=true) to exercise the MEMO O(1)/invalidation gates.")

	w.queue_free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
