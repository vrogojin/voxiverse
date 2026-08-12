extends SceneTree
## COSMOS-FOREST-SNOW-PROC gate — G-PGATE-* (flag CubeSphere.FP_SNOW_PRECIP_GATE).
## The shipped SnowfallSystem runs its FULL per-column body (2× column_profile computes + generated_cell
## resolves + the M1 evaluator + an env sample) in EVERY biome, then in a warm snow-free forest writes NOTHING
## (measured 18-44 ms live snow_ms of pure waste). FP_SNOW_PRECIP_GATE turns _process_column into a physical
## whitelist: a BARE (unedited) column is processed ONLY under active snowfall AND ts < SNOW_T0; every other bare
## column is a PROVEN shipped no-op (design §3.3) so it early-returns 0. Columns that HOLD snow or an overlay edit
## keep the shipped path (melt + state-clear, §3.4). This gate drives _process_column / step_now DIRECTLY on a
## SnowfallSystem with `_gate_enabled` set both ways (flag-agnostic — it runs in the default flag-off build) and
## proves the fix is BYTE-EQUAL in world evolution while the skip actually removes the work:
##   G-PGATE-OFF         — a fresh system reads _gate_enabled = CubeSphere.FP_SNOW_PRECIP_GATE (false in the ship
##                         build), and the off arm elides NOTHING (cols_full_total == every column).
##   G-PGATE-EQUIV       — over K steps in warm & cold regions the write-fingerprint + snow_cells + step_counter are
##                         IDENTICAL between _gate_enabled false and true (world evolution byte-equal, §3.3).
##   G-PGATE-COLD-PRECIP — a cold column in a SNOWING phase: gated processes it and writes exactly the reference.
##   G-PGATE-COLD-DRY    — a cold column in a DRY phase: gated 0 writes AND runs the full body on 0 columns vs the
##                         reference's 1 (skip engaged; cost ≤ 25 %).
##   G-PGATE-WARM        — warm forest: 0 writes both arms; gated runs the full body on 0 of ~R columns (≤ 25 %).
##   G-PGATE-MELT        — a warm column with injected dynamic snow melts step-for-step exactly as the reference
##                         (edit reverts), the has_edit(g+1) escape keeps it live throughout, and once bare it
##                         JOINS the skip set; a stale surface state edit is never skipped (has_edit(surface)).
##   G-PGATE-TS-EQUIV    — the memo-rerouted ts source (analytic_column_profile.w) equals the shipped
##                         column_profile.w for every probed column (the §3.1 value-equivalence claim).
##
## RUN (passes in the default flag-off build — drives _gate_enabled directly):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_snow_precip_gate.gd
## Exits 0 all-pass / 1 on any failure.

const SS := preload("res://src/sim/snowfall_system.gd")
const WM := preload("res://src/world/world_manager.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _mk_world(nm: String) -> WorldManager:
	var w := WorldManager.new()
	w.name = nm
	get_root().add_child(w)                      # _ready wires environment (apply_state_transitions does real work)
	return w

func _mk_sys(w: WorldManager, gated: bool) -> SnowfallSystem:
	var s: SnowfallSystem = SS.new()
	s.setup(w)
	s._gate_enabled = gated
	return s

## Order-sensitive fold of a step's written cells into a running fingerprint (the write ORDER is identical
## between the arms for a given step_counter+column, so a sequential hash is an exact equality proof).
func _fold(h: int, cells: Array[Vector3i]) -> int:
	for c in cells:
		var ch := (c.x * 73856093) ^ (c.y * 19349663) ^ (c.z * 83492791)
		h = (h * 1000003 + ch) & 0x7FFFFFFFFFFFFFFF
	return h

## Mean surface temperature over a coarse neighbourhood of column (cx, cz) — pure worldgen statics.
func _mean_ts(cx: int, cz: int) -> float:
	var sum := 0.0
	var n := 0
	var offs: Array[int] = [-32, 0, 32]
	for dz in offs:
		for dx in offs:
			var x: int = cx + dx
			var z: int = cz + dz
			var g := TerrainConfig.height_at(x, z)
			var t: float = TerrainConfig.column_profile(x, z).w
			sum += ClimateModel.surface_temperature(g, t)
			n += 1
	return sum / float(n)

func _find_cold_col() -> Vector2i:
	for i in range(1, 6000):
		if _mean_ts(i * 137, i * 71) < -1.5:
			return Vector2i(i * 137, i * 71)
	return Vector2i(0, 0)

func _find_warm_col() -> Vector2i:
	for i in range(1, 6000):
		if _mean_ts(i * 149, i * 83) > 4.0:
			return Vector2i(i * 149, i * 83)
	return Vector2i(0, 0)

## Run K step_now on both arms at `col`, folding fingerprints; returns [fp_ref, fp_gat, ref_cols, gat_cols].
func _run_region(col: Vector2i, K: int, ref: SnowfallSystem, gat: SnowfallSystem) -> Array:
	var fp_ref := 0
	var fp_gat := 0
	for s in range(K):
		ref.step_now(col)
		fp_ref = _fold(fp_ref, ref.last_step_cells)
		gat.step_now(col)
		fp_gat = _fold(fp_gat, gat.last_step_cells)
	return [fp_ref, fp_gat, ref.cols_full_total, gat.cols_full_total]

func _initialize() -> void:
	print("=== verify_snow_precip_gate (COSMOS-FOREST-SNOW-PROC: G-PGATE-*) ===")
	BlockCatalog.ensure_ready()
	var cold := _find_cold_col()
	var warm := _find_warm_col()
	var K := 60
	print("  cold col = %s (mean ts %.2f), warm col = %s (mean ts %.2f), K = %d" %
		[str(cold), _mean_ts(cold.x, cold.y), str(warm), _mean_ts(warm.x, warm.y), K])

	# --- G-PGATE-OFF: default flag = false; off arm elides nothing ------------------------------------
	var w_probe := _mk_world("SnowProbe")
	var s_default: SnowfallSystem = SS.new()
	s_default.setup(w_probe)
	_ok(s_default._gate_enabled == CubeSphere.FP_SNOW_PRECIP_GATE, "fresh system _gate_enabled tracks the flag")
	_ok(CubeSphere.FP_SNOW_PRECIP_GATE == false, "FP_SNOW_PRECIP_GATE default is false (ship build byte-off)")

	# --- G-PGATE-TS-EQUIV: the memo reroute is value-identical (§3.1) ---------------------------------
	var ts_equal := true
	for probe in [cold, warm, Vector2i(1234, -567), Vector2i(-4001, 2222), Vector2i(88, 88)]:
		var a: float = TerrainConfig.analytic_column_profile(probe.x, probe.y).w
		var b: float = TerrainConfig.column_profile(probe.x, probe.y).w
		if a != b:
			ts_equal = false
			print("    ts mismatch at %s: analytic.w %f != column.w %f" % [str(probe), a, b])
	_ok(ts_equal, "analytic_column_profile.w == column_profile.w (memo reroute value-equivalent)")

	# --- G-PGATE-EQUIV (warm) + G-PGATE-WARM ----------------------------------------------------------
	var wrw := _mk_world("WarmRef"); var wgw := _mk_world("WarmGat")
	var rw := _mk_sys(wrw, false);   var gw := _mk_sys(wgw, true)
	var resw := _run_region(warm, K, rw, gw)
	_ok(resw[0] == resw[1], "WARM: write fingerprint identical (gated == ref) — byte-equal")
	_ok(rw.snow_cells == gw.snow_cells, "WARM: snow_cells match (%d == %d)" % [rw.snow_cells, gw.snow_cells])
	_ok(rw.snow_cells == 0, "WARM: reference wrote no snow (snow_cells 0) — the measured warm case")
	_ok(rw.step_counter == gw.step_counter, "WARM: step_counter match (%d == %d)" % [rw.step_counter, gw.step_counter])
	_ok(int(resw[2]) > 0, "WARM: reference ran the full body on %d columns" % int(resw[2]))
	_ok(int(resw[3]) == 0, "WARM: gated ran the full body on 0 columns (all skipped)")
	_ok(int(resw[3]) <= int(resw[2]) / 4, "G-PGATE-WARM: gated full-body cols %d ≤ 25%% of ref %d" % [int(resw[3]), int(resw[2])])
	# informational wall-clock speedup (not a gate — headless timing is noisy)
	_time_region(warm, wrw, wgw)

	# --- G-PGATE-EQUIV (cold) + G-PGATE-COLD-PRECIP ---------------------------------------------------
	var wrc := _mk_world("ColdRef"); var wgc := _mk_world("ColdGat")
	var rc := _mk_sys(wrc, false);   var gc := _mk_sys(wgc, true)
	var resc := _run_region(cold, K, rc, gc)
	_ok(resc[0] == resc[1], "COLD: write fingerprint identical (gated == ref) — byte-equal")
	_ok(rc.snow_cells == gc.snow_cells, "COLD: snow_cells match (%d == %d)" % [rc.snow_cells, gc.snow_cells])
	_ok(rc.snow_cells > 0, "G-PGATE-COLD-PRECIP: reference accumulated snow (snow_cells %d) — snow still falls" % rc.snow_cells)
	_ok(rc.step_counter == gc.step_counter, "COLD: step_counter match (%d == %d)" % [rc.step_counter, gc.step_counter])
	_ok(int(resc[3]) < int(resc[2]), "COLD: gated skipped dry columns (full-body %d < ref %d)" % [int(resc[3]), int(resc[2])])

	# --- G-PGATE-COLD-DRY / COLD-PRECIP direct-drive at known weather phases --------------------------
	_dry_wet_direct(cold)

	# --- G-PGATE-MELT ---------------------------------------------------------------------------------
	_melt(warm)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Informational only: wall-clock cost of one step_now, gated vs reference (best of 5).
func _time_region(col: Vector2i, wr: WorldManager, wg: WorldManager) -> void:
	var r := _mk_sys(wr, false)
	var g := _mk_sys(wg, true)
	for i in range(3):
		r.step_now(col); g.step_now(col)               # warm caches
	var best_r := 1 << 62
	var best_g := 1 << 62
	for i in range(5):
		var t0 := Time.get_ticks_usec(); r.step_now(col); best_r = mini(best_r, Time.get_ticks_usec() - t0)
		var t1 := Time.get_ticks_usec(); g.step_now(col); best_g = mini(best_g, Time.get_ticks_usec() - t1)
	print("  [info] warm step_now best-of-5: ref %d us, gated %d us (%.0f%%)" %
		[best_r, best_g, 100.0 * float(best_g) / maxf(1.0, float(best_r))])

## G-PGATE-COLD-DRY + a direct COLD-PRECIP equality: find a DRY and a SNOWING step phase for `col` and drive
## _process_column once in each, asserting outcome + skip engagement per phase.
func _dry_wet_direct(col: Vector2i) -> void:
	var wr := _mk_world("DryWetRef"); var wg := _mk_world("DryWetGat")
	var r := _mk_sys(wr, false);      var g := _mk_sys(wg, true)
	var s_dry := -1
	var s_wet := -1
	for s in range(4000):
		r.step_counter = s
		if r.is_snowing(col.x, col.y):
			if s_wet < 0: s_wet = s
		else:
			if s_dry < 0: s_dry = s
		if s_dry >= 0 and s_wet >= 0: break
	_ok(s_dry >= 0, "found a DRY step phase for the cold column")
	_ok(s_wet >= 0, "found a SNOWING step phase for the cold column")
	if s_dry < 0 or s_wet < 0:
		return

	# COLD-DRY: 0 writes both arms; gated runs the full body on 0 columns, reference on 1 (≤25%).
	r.step_counter = s_dry; g.step_counter = s_dry
	var rc0 := r.cols_full_total; var gc0 := g.cols_full_total
	var wr_dry := r._process_column(col.x, col.y, col)
	var wg_dry := g._process_column(col.x, col.y, col)
	_ok(wr_dry == 0 and wg_dry == 0, "G-PGATE-COLD-DRY: 0 writes both arms (ref %d, gated %d)" % [wr_dry, wg_dry])
	_ok(r.cols_full_total - rc0 == 1, "COLD-DRY: reference ran the full body (1 column)")
	_ok(g.cols_full_total - gc0 == 0, "G-PGATE-COLD-DRY: gated skipped the column (0 full-body ⇒ ≤25%)")

	# COLD-PRECIP: gated processes and writes EXACTLY the reference (same cell/value).
	r.step_counter = s_wet; g.step_counter = s_wet
	r.last_step_cells.clear(); g.last_step_cells.clear()
	var rc1 := r.cols_full_total; var gc1 := g.cols_full_total
	var wr_wet := r._process_column(col.x, col.y, col)
	var wg_wet := g._process_column(col.x, col.y, col)
	_ok(wr_wet == wg_wet, "G-PGATE-COLD-PRECIP: writes match (ref %d == gated %d)" % [wr_wet, wg_wet])
	_ok(_fold(0, r.last_step_cells) == _fold(0, g.last_step_cells), "COLD-PRECIP: written cells identical")
	_ok(g.cols_full_total - gc1 == 1 and r.cols_full_total - rc1 == 1, "COLD-PRECIP: both ran the full body (not skipped)")

## G-PGATE-MELT: a warm column with injected dynamic snow melts identically in both arms, stays live via the
## has_edit(g+1) escape, joins the skip set once bare; a stale surface state edit is never skipped.
func _melt(warm: Vector2i) -> void:
	var wr := _mk_world("MeltRef"); var wg := _mk_world("MeltGat")
	var r := _mk_sys(wr, false);    var g := _mk_sys(wg, true)
	var x := warm.x; var z := warm.y
	var gh := TerrainConfig.height_at(x, z)
	var cell := Vector3i(x, gh + 1, z)
	var snowv := CellCodec.canonical(CellCodec.pack(r._snow_id, 0))   # a full (10-tenths) dynamic snow block
	for pair in [[wr, r], [wg, g]]:
		var w: WorldManager = pair[0]
		var sys: SnowfallSystem = pair[1]
		w._write_cell(cell, snowv)
		sys.snow_cells += 1
	_ok(wr.has_edit(cell) and wg.has_edit(cell), "MELT: injected dynamic snow at g+1 (edit present both arms)")

	var fp_r := 0; var fp_g := 0
	var melted_at := -1
	var stayed_live := true
	for step in range(30):
		var rc0 := r.cols_full_total; var gc0 := g.cols_full_total
		r._process_column(x, z, warm)
		g._process_column(x, z, warm)
		fp_r = _fold(fp_r, r.last_step_cells); r.last_step_cells.clear()
		fp_g = _fold(fp_g, g.last_step_cells); g.last_step_cells.clear()
		# while the edit is still present the gated arm must NOT skip (has_edit escape keeps it live)
		if wg.has_edit(cell) and (g.cols_full_total - gc0) == 0:
			stayed_live = false
		if not wr.has_edit(cell) and not wg.has_edit(cell) and melted_at < 0:
			melted_at = step
			break
	_ok(fp_r == fp_g, "G-PGATE-MELT: melt trajectory identical (gated == ref fingerprint)")
	_ok(melted_at >= 0, "MELT: snow fully melted to baseline (edit reverted both arms) by step %d" % melted_at)
	_ok(stayed_live, "MELT: gated arm stayed live while snow present (has_edit(g+1) escape)")

	# Now bare: the warm column JOINS the skip set — gated runs 0 full-body, reference 1.
	var rc := r.cols_full_total; var gc := g.cols_full_total
	var wr_bare := r._process_column(x, z, warm)
	var wg_bare := g._process_column(x, z, warm)
	_ok(wr_bare == 0 and wg_bare == 0, "MELT: bare warm column now 0 writes both arms")
	_ok(r.cols_full_total - rc == 1, "MELT: reference still runs the full body on the bare column")
	_ok(g.cols_full_total - gc == 0, "G-PGATE-MELT: gated now SKIPS the melted column (joined the skip set)")

	# A stale surface STATE edit (snow_capped-like) must defeat the skip via has_edit(surface).
	var surf := Vector3i(x, gh, z)
	var mat := CellCodec.mat(wg.cell_value_at(surf))
	var mask := BlockCatalog.state_mask_of(mat)
	if mask != 0 and wg.set_state(surf, mask):        # material carries a state axis → inject a stray bit
		var gc2 := g.cols_full_total
		g._process_column(x, z, warm)
		_ok(g.cols_full_total - gc2 == 1, "MELT: gated does NOT skip a column with a surface state edit (has_edit)")
	else:
		print("  [info] surface material at warm col carries no state axis — state-edit sub-check skipped")
