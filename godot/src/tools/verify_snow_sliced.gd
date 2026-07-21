extends SceneTree
## COSMOS-PERF UNATTENDED R2 gate — G-SNOW-SLICED (flag CubeSphere.FP_SNOW_SLICED).
## The shipped SnowfallSystem runs the whole 0.5 s fixed step in ONE main-thread _process call and its
## wall-clock accumulator runs up to MAX_STEPS_PER_FRAME=4 steps back-to-back after any hitch (the measured
## 126-145 ms snow_ms bursts, hitch-coupled). R2 de-bursts it: (a) drop catch-up — a hitch runs exactly ONE
## step and discards the backlog; (b) slice — the step's ≤32 columns are drained SLICE_COLUMNS/frame with the
## single ground rebuild + step_counter advance at the END; and it lowers the snow-`_edits` ceiling to
## SNOW_SLICED_EDIT_CAP (W4). This gate drives SnowfallSystem.process_sliced DIRECTLY (flag-agnostic — it runs
## in the default flag-off build) and proves:
##   G-SLICE-EQUIV     — over N fixed steps the sliced path writes byte-IDENTICAL cells (per-step write
##                       fingerprint) and reaches the SAME snow_cells / step_counter as the un-sliced
##                       `step_now` reference. Correctness (accumulation/melt outcome) is preserved.
##   G-SLICE-BOUND     — across a scripted 20 ms-frame run INCLUDING an injected hitch, the columns processed
##                       per process_sliced call NEVER exceed SLICE_COLUMNS (no per-frame burst, ever).
##   G-SLICE-NOCATCHUP — a single 2 s hitch frame advances step_counter by EXACTLY ONE (backlog dropped), not
##                       MAX_STEPS_PER_FRAME — the hitch cannot reschedule itself.
##   G-SLICE-CAP       — edit_budget(true) == SNOW_SLICED_EDIT_CAP < SNOW_EDIT_BUDGET == edit_budget(false):
##                       the trail is bounded under the flag, byte-identical (shipped budget) off.
##
## RUN (passes in the default flag-off build — drives the sliced method directly):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_snow_sliced.gd
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
	get_root().add_child(w)
	return w

## Order-sensitive fold of a step's written cells into a running fingerprint (the write ORDER is identical
## between the burst and sliced paths, so a sequential hash is an exact equality proof).
func _fold(h: int, cells: Array[Vector3i]) -> int:
	for c in cells:
		var ch := (c.x * 73856093) ^ (c.y * 19349663) ^ (c.z * 83492791)
		h = (h * 1000003 + ch) & 0x7FFFFFFFFFFFFFFF
	return h

## A comfortably-cold REGION (mean surface temperature over a coarse neighbourhood < −1.5 °C) so snow reliably
## accumulates across the ±SIM_RADIUS footprint — pure worldgen statics, no world needed.
func _find_cold_col() -> Vector2i:
	for i in range(1, 6000):
		var cx := i * 137
		var cz := i * 71
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
		if sum / float(n) < -1.5:
			return Vector2i(cx, cz)
	return Vector2i(0, 0)

func _initialize() -> void:
	print("=== verify_snow_sliced (COSMOS-PERF UNATTENDED R2: G-SNOW-SLICED) ===")
	BlockCatalog.ensure_ready()
	var col := _find_cold_col()
	var K := 80
	print("  cold test column = %s, steps K = %d, SLICE_COLUMNS = %d" % [str(col), K, SS.SLICE_COLUMNS])

	# --- reference: the shipped burst path, step_now K times -----------------------------------------
	var wr := _mk_world("SnowRef")
	var ref: SnowfallSystem = SS.new()
	ref.setup(wr)
	var ref_fp := 0
	for s in range(K):
		ref.step_now(col)
		ref_fp = _fold(ref_fp, ref.last_step_cells)

	# --- sliced: drive process_sliced with 20 ms frames until K steps complete -----------------------
	var ws := _mk_world("SnowSliced")
	var sl: SnowfallSystem = SS.new()
	sl.setup(ws)
	var sl_fp := 0
	var max_slice := 0
	var prev_sc := sl.step_counter
	var dt := 0.02
	var guard := K * 30 + 50            # ample frames to complete K steps (≤26 frames/step) + margin
	for f in range(guard):
		sl.process_sliced(dt, col)
		max_slice = maxi(max_slice, sl.last_slice_cols)
		if sl.step_counter != prev_sc:  # a step (empty or real) just finished this frame → fold its cells
			sl_fp = _fold(sl_fp, sl.last_step_cells)
			prev_sc = sl.step_counter
		if sl.step_counter >= K:
			break

	# G-SLICE-EQUIV
	_ok(sl.step_counter == K, "sliced completed exactly K=%d steps (got %d)" % [K, sl.step_counter])
	_ok(ref.snow_cells > 0, "reference actually accumulated snow (snow_cells=%d) — non-trivial run" % ref.snow_cells)
	_ok(sl.snow_cells == ref.snow_cells, "snow_cells match (sliced %d == ref %d)" % [sl.snow_cells, ref.snow_cells])
	_ok(sl_fp == ref_fp, "per-step write fingerprint IDENTICAL (sliced == ref) — outcome preserved")
	_ok(max_slice <= SS.SLICE_COLUMNS, "no burst: max cols/frame %d ≤ SLICE_COLUMNS %d" % [max_slice, SS.SLICE_COLUMNS])

	# G-SLICE-NOCATCHUP — a single 2 s hitch runs ONE step, not MAX_STEPS_PER_FRAME -------------------
	var wh := _mk_world("SnowHitch")
	var sh: SnowfallSystem = SS.new()
	sh.setup(wh)
	var sc0 := sh.step_counter
	var hitch_max := 0
	sh.process_sliced(2.0, col)                 # the hitch frame: 2 s elapsed at once
	hitch_max = maxi(hitch_max, sh.last_slice_cols)
	# drain the started step over a few normal frames
	for f in range(12):
		sh.process_sliced(0.02, col)
		hitch_max = maxi(hitch_max, sh.last_slice_cols)
	_ok(hitch_max <= SS.SLICE_COLUMNS, "hitch frame + drain never burst (max %d ≤ SLICE_COLUMNS %d)" % [hitch_max, SS.SLICE_COLUMNS])
	_ok(sh.step_counter - sc0 == 1, "2 s hitch advanced step_counter by EXACTLY 1 (not %d) — no catch-up" % SS.MAX_STEPS_PER_FRAME)

	# G-SLICE-CAP — the trail bound is lowered under the flag, byte-identical off ---------------------
	_ok(SS.edit_budget(true) == SS.SNOW_SLICED_EDIT_CAP, "edit_budget(sliced) == SNOW_SLICED_EDIT_CAP (%d)" % SS.SNOW_SLICED_EDIT_CAP)
	_ok(SS.edit_budget(false) == SS.SNOW_EDIT_BUDGET, "edit_budget(off) == SNOW_EDIT_BUDGET (%d) — byte-identical" % SS.SNOW_EDIT_BUDGET)
	_ok(SS.edit_budget(true) < SS.edit_budget(false), "sliced cap %d < shipped budget %d (bounds the crossing scan)" % [SS.SNOW_SLICED_EDIT_CAP, SS.SNOW_EDIT_BUDGET])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
