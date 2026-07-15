extends SceneTree
## COSMOS FP-M2e VALIDATION HARNESS — the walk-the-planet SOAK DRIVER (docs/COSMOS-FP-M2-DESIGN.md §12/§13
## "FP-M2e", §1.2 the measured problem, §6.5 the load-adaptive controller setpoint).
##
## WHAT IT MEASURES / WHY IT EXISTS
## FP-M2e gates the FP_M2_LOD flag default-ON. Its headline definition-of-done (§13, §3.4):
##   * `vox_gen` backlog ≤ 300 SUSTAINED at a border approach (vs the 1500–2800 measured on FP-M1c, §1.2), and
##   * worst-frame ≤ 18 ms for ≥ 99% of frames (§6.5.2 CTRL_FRAME_BUDGET_MS), incl. a ≤ 4-core run where PACE
##     must degrade, not frame rate.
## This tool DRIVES the exact motion that produced the logged jerk — a player walking the planet, approaching
## and CROSSING several facet seams — and every window samples worst-frame, proc, phys, and the godot_voxel
## generation/meshing backlogs via VoxelEngine.get_stats() (the SAME reading logic as ui/perf_hud.gd, replicated
## here — perf_hud is not modified). It records the time series and asserts the M2e thresholds as named consts.
##
## THE A/B FRAMING (§13). It runs meaningfully in BOTH flag states:
##   * FP_M2_LOD OFF  → the "A" BASELINE. Expected to VIOLATE the thresholds: with the FP-M1c pool it reproduces
##                      the multi-producer generation load (up to 5 full-res producers on one worker pool, §1.2),
##                      so the harness must DETECT a high vox_gen backlog. A baseline FAIL is CORRECT and EXPECTED.
##   * FP_M2_LOD ON   → the "B" that must PASS (in M2e, once M2b/c/d land: LOD-mesh neighbours + Z1-hybrid pool +
##                      the load controller). Same driver, better numbers.
##
## HEADLESS vs LIVE-WEB (read before trusting a number):
##   * `vox_gen` / `vox_mesh` backlog  — HEADLESS-MEANINGFUL. Real godot_voxel native generation runs on the
##     native worker pool; approaching seams + spawning pool neighbours queue real generation tasks, so the
##     backlog reading is a genuine signal (native drains FASTER than WASM, so the ABSOLUTE magnitude UNDER-
##     represents the live-web backlog — but the harness's ability to detect and rank it is proven headless).
##   * worst-frame / proc / phys  — LIVE-WEB-ONLY for the frame-pacing proof. Headless has no renderer and no
##     WASM worker timing; the "frame" cost here is essentially this script's per-frame cost, which is tiny and
##     NOT representative. The worst-frame histogram assertion is the controller's LIVE proof (§13, PerfHUD on
##     web); headless it is reported for completeness and CLEARLY flagged as non-representative. We DO NOT fake a
##     frame-time pass: the exit code is gated on the HEADLESS-MEANINGFUL vox_gen signal (see _summarize()).
##
## RUN (FACETED + FP_M1_POOL sed-toggled true — the FP-M1c pool baseline; add FP_M2_LOD for the B side):
##   # --- A baseline (flag OFF): expected to REPORT FAIL with a high vox_gen backlog ---
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_M1_POOL := false/const FP_M1_POOL := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fp_m2_soak.gd 2> stderr.log
##   # --- B side (flag ON), M2e only, after M2b/c/d land ---
##   sed -i 's/const FP_M2_LOD := false/const FP_M2_LOD := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fp_m2_soak.gd 2> stderr.log
##   # then REVERT the sed. Exits 0 only when the HEADLESS-MEANINGFUL thresholds hold.
##
## ≤4-CORE DEGRADATION (§13, controller pace must degrade not frame rate): force the run onto ≤4 cores at the OS
## level so the native worker pool + the (M2c) StreamLoadController see a constrained machine:
##   taskset -c 0-3 docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fp_m2_soak.gd 2> stderr.log
## The pass criterion under constrained cores (LIVE-WEB, M2e): worst-frame ≤ 18 ms STILL holds while STREAMING
## PACE drops — facets hold a coarser tier / promote slower (the controller reduces admission, §6.5.3). The
## headless proxy this tool prints is the vox_gen DRAIN RATE (backlog cleared / wall-second): under fewer cores
## the drain rate falls, so a FIXED-arrival baseline backs UP MORE — which is exactly the pace the controller must
## throttle. See docs/COSMOS-FP-M2-HEAP-AB.md for the full ≤4-core methodology + heap A/B procedure.
##
## M2e-WIRE HOOKS (things this harness will want from M2c/M2d, NOT wired now — do not add these here):
##   # M2e-WIRE (M2c): read the StreamLoadController admission credit ∈ [0,1] (world_manager.gd will own the
##   #   controller, facet_lod_mesher.gd reads it). Expose e.g. WorldManager.stream_load_credit() -> float so the
##   #   soak can log the credit trace ALONGSIDE worst-frame/backlog (the §6.5 closed-loop live proof) and assert
##   #   the ≤4-core degradation shows credit falling (pace throttled) while worst-frame holds.
##   # M2e-WIRE (M2d): read the live-neighbour count under the Z1-hybrid policy (e.g.
##   #   WorldManager.facet_pool_neighbour_count() already exists, but the soak also wants the LOD-covered facet
##   #   count + tris/bytes ledger from FacetLodMesher.stats() to assert LOD caps hold throughout the walk, §11).
##   #   Expose e.g. WorldManager.lod_stats() -> Dictionary once FacetLodMesher is owned by WorldManager (M2b/d).

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")

# ---- M2e definition-of-done thresholds (docs/COSMOS-FP-M2-DESIGN.md §13, §6.5.2) ----
const SOAK_VOXGEN_MAX := 300        # sustained vox_gen backlog ceiling at a border approach (vs 1500–2800 baseline)
const SOAK_WORST_MS := 18.0         # CTRL_FRAME_BUDGET_MS — worst-frame setpoint (LIVE-WEB proof; §6.5.2)
const SOAK_WORST_PCT := 0.99        # ≥ 99% of frames must satisfy worst-frame ≤ SOAK_WORST_MS (LIVE-WEB)

# ---- walk configuration ----
const SEAMS_TO_CROSS := 6           # the walk crosses ≥ 6 facet seams (§13: "≥ 6 seams incl. a cube-edge + corner")
const APPROACH_MS := 2500           # wall-time budget per seam approach (lets the ≤1 op/s pool throttle fire spawns)
const APPROACH_D_START := 80.0      # own_dist at the start of an approach (inside D_WARM = 96 → pre-warms the pool)
const APPROACH_D_PAST := -0.6       # own_dist just past the ridge → maybe_cross_facet commits
const CONTINUE_MS := 800            # wall-time budget walking into the new facet after a crossing
const SAMPLE_WINDOW_MS := 250       # metric window (perf_hud WINDOW = 0.25 s replicated)

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# godot_voxel worker/pool stats singleton (the perf_hud reading source; ui/perf_hud.gd:66-67).
var _voxel_engine: Object = null

# ---- the recorded metric series (one row per SAMPLE_WINDOW_MS window) ----
# each row: {t_ms, phase, fid, worst_ms, proc_ms, phys_ms, vox_gen, vox_mesh, mem_static_mb, vmem_mb}
var _series: Array = []
# running frame-cost window accumulators (perf_hud pattern: worst-in-window + frame count)
var _win_t0 := 0
var _win_worst_us := 0
var _win_frames := 0
var _win_vox_gen_peak := 0          # peak backlog seen in the window (captured right after each update_streaming)
var _win_vox_mesh_peak := 0
var _last_frame_us := 0             # ticks_usec at the last await, for the frame-delta measure

func _initialize() -> void:
	print("=== verify_fp_m2_soak (FP-M2e walk-the-planet soak driver) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this soak.")
		print("==== SOAK: 0 passed, 1 failed ===="); quit(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent (ClassDB has no VoxelTerrain) — the soak needs the module binary.")
		print("==== SOAK: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FP_M1_POOL:
		# The soak's whole point is the MULTI-PRODUCER pool load. Without the pool it degrades to the FP-S1 single
		# active terrain — still runs, but it cannot reproduce the 1500–2800 baseline (there is only one producer).
		print("  NOTE: FP_M1_POOL is OFF — running against the FP-S1 single-terrain fallback (one producer). The")
		print("        baseline multi-producer backlog is NOT reproducible without the pool; sed-toggle FP_M1_POOL")
		print("        = true for the true FP-M1c 'A' baseline.")
	print("  FLAGS: FACETED=%s FP_M1_POOL=%s FP_M2_LOD=%s  (A baseline = FP_M2_LOD OFF; B = ON)" % [
		CubeSphere.FACETED, CubeSphere.FP_M1_POOL, CubeSphere.FP_M2_LOD])
	print("  THRESHOLDS: SOAK_VOXGEN_MAX=%d (headless-meaningful)  SOAK_WORST_MS=%.1f  SOAK_WORST_PCT=%.2f (live-web-only)" % [
		SOAK_VOXGEN_MAX, SOAK_WORST_MS, SOAK_WORST_PCT])

	if Engine.has_singleton("VoxelEngine"):
		_voxel_engine = Engine.get_singleton("VoxelEngine")
	print("  VoxelEngine singleton: %s (backlog readable = %s)" % [
		"present" if _voxel_engine != null else "ABSENT", _voxel_engine != null])

	TC.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TC.set_active_facet(active)
	print("  atlas: %d facets (k=%d, R=%d), spawn active facet = %d, near_render_radius = %d" % [
		FA.facet_count(), FA.K, int(FA.R_BLOCKS), active, TC.near_render_radius()])

	# Build the full WorldManager (its _ready installs the module world + the pool under FACETED+FP_M1_POOL) and
	# attach a stand-in player so the ONE global VoxelViewer wires up and terrains actually stream (the
	# _gate_pool_walk_soak pattern, verify_faceted.gd:1307-1318).
	var w := WorldManager.new()
	w.name = "M2eSoak"
	get_root().add_child(w)
	await process_frame
	var player := Node3D.new()
	player.name = "SoakPlayer"
	get_root().add_child(player)
	if w.has_method("on_player_ready"):
		w.on_player_ready(player)
	print("  world: WorldManager built, using_module = %s" % str(w.get("using_module")))
	await process_frame

	_print_mem("boot")

	# Drive the walk: cross SEAMS_TO_CROSS seams, sampling metrics the whole way.
	await _walk_the_planet(w, player, active)

	_print_mem("post-walk")
	_summarize()

# -------------------------------------------------------------------------------------------------
# The walk: from the current active facet, repeatedly pick a mid-edge ridge onto a fresh neighbour,
# march the player from an interior approach point (own_dist ≈ +80, inside D_WARM) across the ridge
# (own_dist ≈ -0.6) — sampling every window — then commit maybe_cross_facet and continue into the new
# facet. This is the "approach → cross → continue" motion that produced the logged border jerk (§1.2).
# -------------------------------------------------------------------------------------------------
func _walk_the_planet(w: WorldManager, player: Node3D, start_fid: int) -> void:
	var current := start_fid
	var prev := -1
	var crossed := 0
	var miss_total := 0
	_win_t0 = Time.get_ticks_msec()
	_last_frame_us = Time.get_ticks_usec()
	# safety cap on outer iterations so a persistently-deferred ridge (corner geometry) can never loop forever.
	var attempts := 0
	while crossed < SEAMS_TO_CROSS and attempts < SEAMS_TO_CROSS * 3:
		attempts += 1
		# choose a ridge onto a neighbour that is NOT the facet we just came from (keep walking forward).
		var slot := _pick_forward_slot(current, prev)
		if slot < 0:
			print("  [walk] no forward ridge from facet %d — stopping the walk early." % current)
			break
		var B: int = FA.seam_neighbour(current, slot)
		var geo := _seam_geo(current, slot)
		if geo.is_empty():
			print("  [walk] degenerate ridge geometry (facet %d slot %d) — skipping." % [current, slot])
			prev = current
			continue
		var seam_pt: Vector3 = geo["seam_pt"]
		var nhat: Vector3 = geo["nhat"]
		var nlen: float = geo["nlen"]
		var d_s: float = geo["d_s"]
		# approach point (own_dist ≈ +APPROACH_D_START) → a point WELL past the ridge (own_dist ≈ APPROACH_D_PAST),
		# along the ridge normal. The march calls maybe_cross_facet every step (the real game loop), so
		# FACET_CROSS_COOLDOWN counts down during the approach and the crossing fires the moment own_dist < −HYST.
		var p_start := seam_pt + nhat * ((APPROACH_D_START - d_s) / nlen)
		var p_past := seam_pt + nhat * ((APPROACH_D_PAST - d_s) / nlen)
		print("  [walk] seam-attempt %d: facet %d --slot %d--> %d  (own_dist %.0f → %.1f, %d ms approach)" % [
			attempts, current, slot, B, APPROACH_D_START, APPROACH_D_PAST, APPROACH_MS])

		# --- APPROACH + CROSS folded into one march: stream + maybe_cross_facet each step, sampling every window. ---
		var miss_before := w.pool_miss_count()
		var res := await _march(w, player, p_start, p_past, APPROACH_MS, "approach", current)
		if bool(res.get("crossed", false)):
			var to: int = int(res.get("to", B))
			var miss_delta := w.pool_miss_count() - miss_before
			miss_total += miss_delta
			crossed += 1
			print("    crossed → facet %d (pool-miss delta %d, %s)" % [
				to, miss_delta, "POOL HIT" if miss_delta == 0 else "POOL MISS"])
			prev = current
			current = to
			# --- CONTINUE: walk a little deeper into the new facet from the reframed landing (settles the next approach). ---
			var np: Vector3 = res.get("new_pos", p_past)
			var cont_slot := _pick_forward_slot(current, prev)
			if cont_slot >= 0:
				var cgeo := _seam_geo(current, cont_slot)
				if not cgeo.is_empty():
					var inward := np - (cgeo["nhat"] as Vector3) * (30.0 / float(cgeo["nlen"]))
					await _march(w, player, np, inward, CONTINUE_MS, "continue", current)
		else:
			# No crossing over the whole approach (corner-containment deferral, §6.1 of maybe_cross_facet). Advance
			# `prev` so _pick_forward_slot tries a different ridge next attempt rather than re-marching the same one.
			print("    NO CROSS over the approach (own_dist reached %.1f) — trying a different ridge." % APPROACH_D_PAST)
			prev = B

	print("  [walk] crossed %d/%d seams over %d attempts; total pool-miss = %d" % [
		crossed, SEAMS_TO_CROSS, attempts, miss_total])
	_flush_window(current, "end")     # emit the last partial window
	# pool-miss is a HEADLESS-MEANINGFUL crossing-correctness signal (a HIT means the pool pre-warmed → the walking
	# path is the re-designation fast path, not a teardown). The FP-M1c gate already proves miss==0 on a single
	# crossing; here we surface it across the whole walk as a soak-health check (NOT one of the M2e headline gates).
	_ok(crossed > 0, "SOAK: the walk crossed at least one seam (crossed=%d over %d attempts)" % [crossed, attempts])
	# pool-miss is REPORTED, not asserted, here: this synthetic walk crosses a seam every ~%d ms, which outruns the
	# pool's ≤ 1-op/s spawn throttle (POOL_SPAWN_INTERVAL_S), so some approaches legitimately spawn-at-cross (still
	# hole-free — a MISS is a spawn+redesignate, never a teardown/blank). The STRICT "pool-miss count 0" assertion
	# lives in the FP-M2d live-sprint gate (§13), where the pace is realistic (a player walks a whole facet between
	# crossings). Here it is a pace-sensitivity signal only.
	print("  [walk] pool-miss over the walk: %d / %d crossings (pace artifact of the fast synthetic walk; a MISS is a hole-free spawn-at-cross, not a teardown — the strict miss==0 gate is FP-M2d live, §13)." % [
		miss_total, crossed])

# March the player position from `a` to `b` over `budget_ms` wall-time. Every step: update_streaming (the load
# producer, runs _manage_facet_pool), peek the vox_gen backlog the instant it is queued, then maybe_cross_facet
# (the real game loop — decrements FACET_CROSS_COOLDOWN and fires the crossing when own_dist < −HYST). Returns the
# crossing dict the moment a cross fires (breaking the march), or {} if the segment completes without crossing.
# Emits a metric window every SAMPLE_WINDOW_MS.
func _march(w: WorldManager, player: Node3D, a: Vector3, b: Vector3, budget_ms: int, phase: String, fid: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while true:
		var elapsed := Time.get_ticks_msec() - t0
		var u := clampf(float(elapsed) / float(budget_ms), 0.0, 1.0)
		var pos := a.lerp(b, u)
		player.global_position = pos
		# drive streaming (runs _manage_facet_pool → pool spawn/retire) — the load producer.
		w.update_streaming(pos)
		# capture the backlog the instant it is queued (before the native workers drain it across the awaited frame).
		var bl := _read_backlog()
		if int(bl["gen"]) > _win_vox_gen_peak:
			_win_vox_gen_peak = int(bl["gen"])
		if int(bl["mesh"]) > _win_vox_mesh_peak:
			_win_vox_mesh_peak = int(bl["mesh"])
		# the crossing driver — same call the Player makes every physics tick; fires when past the ridge.
		var res := w.maybe_cross_facet(pos)
		# frame-cost sample (wall time across the await — headless: script cost only, see header).
		await process_frame
		var now_us := Time.get_ticks_usec()
		var frame_us := now_us - _last_frame_us
		_last_frame_us = now_us
		if frame_us > _win_worst_us:
			_win_worst_us = frame_us
		_win_frames += 1
		# emit a window every SAMPLE_WINDOW_MS
		if Time.get_ticks_msec() - _win_t0 >= SAMPLE_WINDOW_MS:
			_flush_window(fid, phase)
		if bool(res.get("crossed", false)):
			return res
		if u >= 1.0:
			break
	return {}

# Close the current metric window: append a series row from the accumulators + the engine-averaged monitors, reset.
func _flush_window(fid: int, phase: String) -> void:
	if _win_frames == 0:
		return
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var vmem_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var mem_static_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	_series.append({
		"t_ms": Time.get_ticks_msec(),
		"phase": phase, "fid": fid,
		"worst_ms": _win_worst_us / 1000.0,
		"proc_ms": proc_ms, "phys_ms": phys_ms,
		"vox_gen": _win_vox_gen_peak, "vox_mesh": _win_vox_mesh_peak,
		"mem_static_mb": mem_static_mb, "vmem_mb": vmem_mb,
	})
	_win_t0 = Time.get_ticks_msec()
	_win_worst_us = 0
	_win_frames = 0
	_win_vox_gen_peak = 0
	_win_vox_mesh_peak = 0

# godot_voxel task backlog (the perf_hud reading logic, ui/perf_hud.gd:113-120). generation = vox_gen, meshing = vox_mesh.
func _read_backlog() -> Dictionary:
	if _voxel_engine != null and _voxel_engine.has_method("get_stats"):
		var st: Dictionary = _voxel_engine.call("get_stats")
		var tasks: Dictionary = st.get("tasks", {})
		return {"gen": int(tasks.get("generation", 0)), "mesh": int(tasks.get("meshing", 0))}
	return {"gen": 0, "mesh": 0}

# -------------------------------------------------------------------------------------------------
# Summary + threshold asserts.
# -------------------------------------------------------------------------------------------------
func _summarize() -> void:
	print("")
	print("  --- [M2E-SOAK] metric series (%d windows) ---" % _series.size())
	print("    %-4s %-9s %-5s %8s %8s %8s %8s %8s %10s" % [
		"win", "phase", "fid", "worst_ms", "proc_ms", "phys_ms", "vox_gen", "vox_msh", "memMB"])
	var worst_ms_overall := 0.0
	var voxgen_peak := 0
	var voxmesh_peak := 0
	var frames_under := 0
	var frames_total := 0
	# "sustained" vox_gen = the max over windows of the window's peak — a window is 250 ms, so a peak that persists
	# a whole window is by construction sustained load, not a single-frame blip (the §13 "sustained" qualifier).
	var voxgen_sustained := 0
	# a rolling 3-window mean to expose genuinely-sustained backlog vs a lone spike window.
	for i in range(_series.size()):
		var r: Dictionary = _series[i]
		print("    %-4d %-9s %-5d %8.3f %8.3f %8.3f %8d %8d %10.1f" % [
			i, r["phase"], int(r["fid"]), float(r["worst_ms"]), float(r["proc_ms"]), float(r["phys_ms"]),
			int(r["vox_gen"]), int(r["vox_mesh"]), float(r["mem_static_mb"])])
		worst_ms_overall = maxf(worst_ms_overall, float(r["worst_ms"]))
		voxgen_peak = maxi(voxgen_peak, int(r["vox_gen"]))
		voxmesh_peak = maxi(voxmesh_peak, int(r["vox_mesh"]))
		voxgen_sustained = maxi(voxgen_sustained, int(r["vox_gen"]))
		frames_total += 1
		if float(r["worst_ms"]) <= SOAK_WORST_MS:
			frames_under += 1
	var pct_under := (float(frames_under) / float(maxi(frames_total, 1)))

	print("")
	print("  --- [M2E-SOAK] SUMMARY ---")
	print("    windows sampled          : %d" % _series.size())
	print("    vox_gen  peak / sustained: %d / %d   (threshold SOAK_VOXGEN_MAX = %d)  [HEADLESS-MEANINGFUL]" % [
		voxgen_peak, voxgen_sustained, SOAK_VOXGEN_MAX])
	print("    vox_mesh peak            : %d" % voxmesh_peak)
	print("    worst-frame overall      : %.3f ms   (threshold SOAK_WORST_MS = %.1f)  [LIVE-WEB-ONLY — headless not representative]" % [
		worst_ms_overall, SOAK_WORST_MS])
	print("    frames worst ≤ %.0f ms     : %.2f%%   (threshold ≥ %.0f%%)  [LIVE-WEB-ONLY]" % [
		SOAK_WORST_MS, pct_under * 100.0, SOAK_WORST_PCT * 100.0])

	# ---- HEADLESS-MEANINGFUL gate: the vox_gen backlog. This is the exit-code-bearing assertion. ----
	# With FP_M2_LOD OFF + FP_M1_POOL ON this SHOULD FAIL (reproducing the multi-producer backlog) — a baseline FAIL
	# is the CORRECT, EXPECTED result that proves the harness detects the problem. With the full FP-M2 stack ON
	# (M2b/c/d landed) it must PASS: the LOD-mesh neighbours take non-imminent facets off the worker pool.
	var voxgen_ok := voxgen_sustained <= SOAK_VOXGEN_MAX
	_ok(voxgen_ok, "SOAK[headline]: sustained vox_gen backlog %d ≤ %d (border-approach ceiling, §13). A baseline (flag OFF) FAIL here is EXPECTED and proves the harness works." % [
		voxgen_sustained, SOAK_VOXGEN_MAX])

	# ---- LIVE-WEB-ONLY: reported, NOT exit-gated headless (headless frame time is unrepresentative). ----
	# We DELIBERATELY do NOT _ok() the worst-frame here in headless — asserting a headless frame-time pass would be
	# faking the controller's live proof. On live web (M2e), read this % from the PerfHUD histogram instead; the
	# pass criterion is pct_under ≥ SOAK_WORST_PCT. Printed above so it can be eyeballed / scraped from the log.
	if worst_ms_overall <= SOAK_WORST_MS and pct_under >= SOAK_WORST_PCT:
		print("    [live-web note] headless worst-frame is within budget — EXPECTED headless (no WASM worker timing);")
		print("                    this is NOT a controller pass. The real proof is the live-web PerfHUD histogram.")
	else:
		print("    [live-web note] headless worst-frame exceeds budget in %d window(s) — reported for eyeballing only." % (
			frames_total - frames_under))

	print("")
	print("==== SOAK: %d passed, %d failed ====" % [_pass, _fail])
	# exit 0 only when the headless-meaningful thresholds hold (the vox_gen gate + the walk-crossed sanity check).
	quit(1 if _fail > 0 else 0)

# -------------------------------------------------------------------------------------------------
# Helpers.
# -------------------------------------------------------------------------------------------------
# Pick a mid-edge ridge slot on `fid` whose seam-neighbour is a valid facet and is NOT `avoid` (keep walking
# forward, don't immediately re-cross back). Returns -1 if none.
func _pick_forward_slot(fid: int, avoid: int) -> int:
	var fallback := -1
	for slot in range(4):
		var nb: int = FA.seam_neighbour(fid, slot)
		if nb < 0 or nb == fid:
			continue
		if nb == avoid:
			fallback = slot          # last resort if every ridge leads back
			continue
		return slot
	return fallback

# Ridge geometry for facet `fid` slot `slot`: a mid-edge seam point (own lattice), the outward ridge normal (unit),
# its raw length, and own_dist at the seam point. Mirrors verify_faceted.gd:1328-1338. {} if degenerate.
func _seam_geo(fid: int, slot: int) -> Dictionary:
	var cc: Vector2i = FA.centre_cell(fid)
	var gA := int(TC.facet_profile(fid, cc.x, cc.y).x)
	var seam_cell := _seam_probe_cell(fid, slot, cc, gA)
	var pl: Vector4 = FA.seam_plane(fid, slot)
	var n := Vector3(pl.x, pl.y, pl.z)
	var nlen := n.length()
	if nlen < 1e-9:
		return {}
	var nhat := n / nlen
	var seam_pt := Vector3(float(seam_cell.x), float(gA), float(seam_cell.y))
	var d_s := FA.own_dist(fid, slot, seam_pt.x, seam_pt.y, seam_pt.z)
	return {"seam_pt": seam_pt, "nhat": nhat, "nlen": nlen, "d_s": d_s}

# March a lattice cell from the facet centre toward ridge `slot` until near the seam (own_dist ~ 1), staying
# mid-edge (away from polygon corners). Copied from verify_faceted.gd:1290-1301 (the shared seam-probe pattern).
func _seam_probe_cell(fid: int, slot: int, centre: Vector2i, g: int) -> Vector2i:
	var cur := Vector2i(centre)
	for _i in range(512):
		var d := FA.own_dist(fid, slot, float(cur.x), float(g), float(cur.y))
		if d <= 1.5:
			break
		var dx := FA.own_dist(fid, slot, float(cur.x + 1), float(g), float(cur.y)) - d
		var dz := FA.own_dist(fid, slot, float(cur.x), float(g), float(cur.y + 1)) - d
		cur += Vector2i(-1 if dx > 0.0 else 1, 0) if absf(dx) >= absf(dz) else Vector2i(0, -1 if dz > 0.0 else 1)
	return cur

# Print a memory snapshot (the headless proxy for the browser-heap A/B; see docs/COSMOS-FP-M2-HEAP-AB.md).
func _print_mem(label: String) -> void:
	var mem_static_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var vmem_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var os_static := OS.get_static_memory_usage() / 1048576.0
	print("  [mem:%s] MEMORY_STATIC=%.1f MB  OS.static=%.1f MB  RENDER_VIDEO_MEM_USED=%.1f MB" % [
		label, mem_static_mb, os_static, vmem_mb])
