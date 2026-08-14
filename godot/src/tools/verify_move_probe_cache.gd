extends SceneTree
## COSMOS-MOTION-PHYS §6.5 gate — FP_MOVE_PROBE_CACHE (the walking t_move fix: a per-physics-tick generated-value cache
## under WorldManager.cell_value_at). The cache wraps ONLY the generated branch, AFTER the live edit-overlay get, so an
## edited cell can never be served from cache → clip-through is impossible by construction (design §6.3 choice B). This
## gate pins that invariant and the never-OOM bounds. Two-state (reads CubeSphere.FP_MOVE_PROBE_CACHE); the identity and
## overlay-live checks hold in BOTH flag states, so it is all-pass at the default (byte-off) and when the flag is flipped.
##
##   G-MPC-ID      cell_value_at(c) == _cell_value_generated(c) over an unedited cell span (sub-surface..sky, i.e. across
##                 solid/air/slope/snow bands) — the cache NEVER returns a value different from raw generation.
##   G-MPC-OFF     flag off ⇒ _gen_cache stays empty (byte-off: the dict is never touched).  flag on ⇒ queries populate it.
##   G-MPC-OVERLAY the clip-through invariant: warm the cache at cell C (generates AIR), _write_cell STONE into C, re-query
##                 ⇒ block_id_at == STONE (the overlay is consulted live BEFORE the cache); sim_revert_cell ⇒ back to AIR.
##   G-MPC-EPOCH   flag on: a stale _gen_cache_tick ⇒ the next query clears + restamps to the current physics frame; and
##                 _rebuild_window_indices / _shift_window_bookkeeping clear the cache wholesale (the remap choke points).
##   G-MPC-CAP     flag on: > MOVE_PROBE_CACHE_CAP distinct cells in one epoch ⇒ _gen_cache.size() ≤ CAP, queries still exact.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_move_probe_cache.gd

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _bare(nm: String) -> WorldManager:
	var w := WorldManager.new()
	w.name = nm
	get_root().add_child(w)
	return w

func _initialize() -> void:
	print("=== verify_move_probe_cache (FP_MOVE_PROBE_CACHE — the walking t_move generated-value cache) ===")
	var on := CubeSphere.FP_MOVE_PROBE_CACHE
	var w := _bare("MPC")

	# G-MPC-ID: the cache path must equal raw generation on every unedited cell (a pure-function-within-epoch proof).
	# Span crosses sub-surface solid → surface → air so slope/snow/tree composition variants are exercised.
	var identical := true
	var first_bad := ""
	for x in range(-6, 7):
		for z in range(-6, 7):
			for y in range(-3, 34):
				var c := Vector3i(x, y, z)
				var via_cache := w.cell_value_at(c)          # cache path (flag on) or straight fall-through (off)
				var via_raw := w._cell_value_generated(c)    # always the raw generated branch, cache-bypassed
				if via_cache != via_raw:
					identical = false
					if first_bad == "":
						first_bad = "%s cache=%d raw=%d" % [str(c), via_cache, via_raw]
	_ok(identical, "G-MPC-ID: cell_value_at == _cell_value_generated over a %d-cell span (cache never lies) %s" % [13 * 13 * 37, first_bad])

	# G-MPC-OFF / populate: byte-off ⇒ the dict is untouched; flag-on ⇒ the span above populated it.
	if on:
		_ok(not w._gen_cache.is_empty(), "G-MPC-POP: flag on ⇒ the query span populated _gen_cache (%d)" % w._gen_cache.size())
	else:
		_ok(w._gen_cache.is_empty(), "G-MPC-OFF: flag off ⇒ _gen_cache never touched (byte-off, %d)" % w._gen_cache.size())

	# G-MPC-OVERLAY (the clip-through invariant): a high cell generates AIR. Warm the cache there, then place a solid;
	# the very next query must see the solid (the overlay short-circuits before the cache), and a revert must restore AIR.
	var cc := Vector3i(2, 60, 2)
	var gen_here := w._cell_value_generated(cc)
	_ok(CellCodec.mat(gen_here) == BlockCatalog.AIR, "G-MPC-OVERLAY setup: (2,60,2) generates AIR (mat=%d)" % CellCodec.mat(gen_here))
	var warm := w.cell_value_at(cc)                          # warms _gen_cache[cc] = AIR when the flag is on
	_ok(warm == gen_here, "G-MPC-OVERLAY: warm query equals generated")
	w._write_cell(cc, BlockCatalog.STONE)                    # place a solid over the just-cached AIR cell
	_ok(w.block_id_at(cc) == BlockCatalog.STONE, "G-MPC-OVERLAY: placed STONE is seen THROUGH the warm cache (no clip-through)")
	w.sim_revert_cell(cc)                                    # dig it back out
	_ok(w.block_id_at(cc) == BlockCatalog.AIR, "G-MPC-OVERLAY-REVERT: revert restores the generated AIR")

	# The mirror case: a solid sub-surface cell, dug to air, must OPEN through the cache.
	var sc := Vector3i(-3, -2, -3)
	var solid_gen := w._cell_value_generated(sc)
	if CellCodec.mat(solid_gen) != BlockCatalog.AIR:
		var _warm2 := w.cell_value_at(sc)                    # warm with the solid generated value
		w._write_cell(sc, 0)                                 # dug to air (dug cells are stored as 0 in _edits, design §6.3)
		_ok(w.block_id_at(sc) == BlockCatalog.AIR, "G-MPC-OVERLAY-DIG: dug-to-air opens a solid column THROUGH the cache")
		w.sim_revert_cell(sc)
		_ok(w.block_id_at(sc) == CellCodec.mat(solid_gen), "G-MPC-OVERLAY-DIG-REVERT: revert restores the generated solid")
	else:
		_ok(true, "G-MPC-OVERLAY-DIG: (skip) sub-surface probe cell generated AIR here — no solid to dig")
		_ok(true, "G-MPC-OVERLAY-DIG-REVERT: (skip)")

	# G-MPC-EPOCH: the per-tick transient epoch + the two remap choke clears (only meaningful with the flag on).
	if on:
		w._gen_cache.clear()
		w._gen_cache_tick = Engine.get_physics_frames()
		var _p1 := w.cell_value_at(Vector3i(7, 5, 7))
		w._gen_cache_tick = Engine.get_physics_frames() - 99   # simulate a physics-frame advance since last stamp
		var _p2 := w.cell_value_at(Vector3i(8, 5, 8))
		_ok(w._gen_cache_tick == Engine.get_physics_frames(), "G-MPC-EPOCH: a query on a new epoch restamps the tick")
		_ok(w._gen_cache.has(Vector3i(8, 5, 8)) and not w._gen_cache.has(Vector3i(7, 5, 7)),
			"G-MPC-EPOCH: the epoch advance CLEARED the old cell and repopulated only the new one")
		var _p3 := w.cell_value_at(Vector3i(9, 5, 9))
		w._rebuild_window_indices()
		_ok(w._gen_cache.is_empty(), "G-MPC-EPOCH: _rebuild_window_indices clears the cache wholesale (crossing/flip choke)")
		var _p4 := w.cell_value_at(Vector3i(10, 5, 10))
		w._shift_window_bookkeeping(Vector2i(4, 4))
		_ok(w._gen_cache.is_empty(), "G-MPC-EPOCH: _shift_window_bookkeeping clears the cache wholesale (origin-shift choke)")
	else:
		_ok(true, "G-MPC-EPOCH: (skip — flag off)")
		_ok(true, "G-MPC-EPOCH: (skip — flag off)")
		_ok(true, "G-MPC-EPOCH: (skip — flag off)")
		_ok(true, "G-MPC-EPOCH: (skip — flag off)")

	# G-MPC-CAP (never-OOM): more distinct cells than the cap in one epoch ⇒ bounded size, and queries past the cap are
	# still exact (they compute + return, just do not insert).
	if on:
		w._gen_cache.clear()
		w._gen_cache_tick = Engine.get_physics_frames()
		var over := CubeSphere.MOVE_PROBE_CACHE_CAP + 200
		var exact := true
		for i in range(over):
			var c2 := Vector3i(1000 + i, 7, 1000)
			if w.cell_value_at(c2) != w._cell_value_generated(c2):
				exact = false
		_ok(w._gen_cache.size() <= CubeSphere.MOVE_PROBE_CACHE_CAP,
			"G-MPC-CAP: %d distinct cells one epoch ⇒ size %d ≤ CAP %d" % [over, w._gen_cache.size(), CubeSphere.MOVE_PROBE_CACHE_CAP])
		_ok(exact, "G-MPC-CAP: every query past the cap is still byte-exact (compute-not-insert degrades to shipped path)")
	else:
		_ok(true, "G-MPC-CAP: (skip — flag off)")
		_ok(true, "G-MPC-CAP: (skip — flag off)")

	print("==== VERIFY: %d passed, %d failed (flag %s) ====" % [_pass, _fail, "ON" if on else "OFF"])
	quit(1 if _fail > 0 else 0)
