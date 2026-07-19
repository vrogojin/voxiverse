extends SceneTree
## FP_WEATHER_THREAD gate — the weather sweep on a DEDICATED worker thread (EnvSimWorker + WeatherSystem's
## worker_sweep/commit_swap). Headless-provable claims:
##   * G-WTHREAD-SAFE    — no data race: the worker writes the BACK buffer, the main reads the FRONT, the
##                          swap is the only sync point ⇒ the front buffer is NEVER seen mid-write. Proven
##                          under REAL threads by a uniform-sentinel tear detector (no racy control reads).
##   * G-WTHREAD-EVOLVE  — the grid evolved OFF-THREAD is byte-identical to the shipped main-thread full
##                          sweep (step_slice) driven with the same game_time sequence ⇒ threading changed
##                          the cadence, not the physics.
##   * G-WTHREAD-MAINCOST— the main-thread per-frame weather cost collapses to a swap check: poll() is a
##                          tiny fraction of the shipped per-frame step_slice ⇒ no sweep runs on main.
##   * TEARDOWN          — start()/stop() joins cleanly with no dangling thread; stop() is safe unstarted.
## The actual walking smoothness with weather ON is LIVE-ONLY (real GPU, real frames).
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_weather_thread.gd 2>/dev/null | grep -E "VERIFY|---|detail"
## Exits 0 all-pass / 1 on any failure.

const WS := preload("res://src/sim/weather_system.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_weather_thread (FP_WEATHER_THREAD: weather sweep on a worker thread) ===")
	print("  CubeSphere.FP_WEATHER_THREAD = %s (the gate exercises the threaded path regardless of the flag default)" % str(CubeSphere.FP_WEATHER_THREAD))
	_gate_teardown()
	_gate_safe()
	_gate_evolve()
	_gate_maincost()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _fresh_grid() -> WeatherSystem:
	var ws: WeatherSystem = WS.new()
	ws.setup()
	ws.build_init(WS.N_CELLS)          # full basis in one call (the live path slices it over startup frames)
	return ws

## Busy-wait (bounded) until the worker has published a completed sweep. Deterministic-outcome: the worker
## always finishes; the timeout only guards a hung thread so the gate fails loud instead of blocking forever.
func _wait_ready(w: EnvSimWorker, timeout_ms: int = 5000) -> bool:
	var t0 := Time.get_ticks_msec()
	while not w.has_ready():
		if Time.get_ticks_msec() - t0 > timeout_ms:
			return false
		OS.delay_usec(100)
	return true

# ---------- TEARDOWN: clean start/stop, no dangling thread, safe when unstarted ----------
func _gate_teardown() -> void:
	print("  --- TEARDOWN: start()/stop() joins cleanly; stop() safe unstarted / twice ---")
	var ws := _fresh_grid()
	var w := EnvSimWorker.new(ws)
	# stop() before start() must be a harmless no-op (no thread exists yet).
	w.stop()
	_ok(not w.is_running(), "TEARDOWN: stop() before start() is a safe no-op")
	w.start()
	_ok(w.is_running(), "TEARDOWN: start() spins the worker thread (running)")
	w.poll(0.0)                                    # kick one sweep
	_ok(_wait_ready(w), "TEARDOWN: worker produced a sweep after the first poll")
	w.stop()
	_ok(not w.is_running(), "TEARDOWN: stop() joined the thread (no dangling thread on exit)")
	w.stop()
	_ok(not w.is_running(), "TEARDOWN: stop() is idempotent (safe to call twice)")

# ---------- G-WTHREAD-SAFE: the front buffer is NEVER seen mid-write, under real threads ----------
func _gate_safe() -> void:
	print("  --- G-WTHREAD-SAFE: worker writes BACK / main reads FRONT / swap is the only sync — no torn front ---")
	var ws := _fresh_grid()
	ws.debug_set_safety_fill(true)                 # worker fills the WHOLE back buffer with a rising sentinel
	var w := EnvSimWorker.new(ws)
	w.start()
	w.poll(0.0)                                    # kick sweep 1
	var torn := 0                                  # any read of a NON-uniform front = a front/back leak
	var reads := 0
	var non_decreasing := true
	var last_val := -1.0
	var max_val := -1.0
	# Free-run the worker while the main thread commits + reads the front MANY times. The reads deliberately
	# overlap the worker's back-buffer fill (right after each poll launches a sweep), so a leak would be caught.
	for it in range(2500):
		w.poll(float(it))
		for _r in range(5):
			var v := ws.debug_front_uniform_value()
			reads += 1
			if v < 0.0:
				torn += 1
			else:
				if v < last_val:
					non_decreasing = false
				last_val = v
				max_val = maxf(max_val, v)
	w.stop()
	_ok(torn == 0, "SAFE: %d front reads over the run, %d torn (front is always a consistent published sweep)" % [reads, torn])
	_ok(non_decreasing, "SAFE: published sentinel never went backwards (the swap always publishes the fresh sweep)")
	_ok(max_val >= 3.0, "SAFE: the worker actually ran and swaps happened (max published sentinel %.0f ≥ 3)" % max_val)

# ---------- G-WTHREAD-EVOLVE: off-thread evolution == the shipped main-thread full sweep ----------
func _gate_evolve() -> void:
	print("  --- G-WTHREAD-EVOLVE: worker sweep byte-identical to the shipped step_slice over the same drive ---")
	# a non-trivial game_time sequence (the sun sweeps longitude + a slow declination drift via the ephemeris).
	var seq: Array[float] = []
	for i in range(30):
		seq.append(50.0 + float(i) * 1234.5)       # game-seconds; each step advances the ephemeris sun + dt
	# REFERENCE: the shipped main-thread path. step_slice(gt, N_CELLS) is exactly one full sweep with the
	# publish flip — i.e. worker_sweep(gt) + commit_swap() — so it is the ground truth for the threaded split.
	var ref := _fresh_grid()
	for gt in seq:
		ref.step_slice(gt, WS.N_CELLS)
	var ref_hash := ref.state_hash()
	# THREADED: the SAME drive on the real worker thread, paced in lockstep (one sweep per step). poll(seq[i])
	# commits sweep i-1 and launches sweep i; a final poll commits the last sweep (then stop() drains the
	# throwaway sweep it launched — that writes only the back buffer, so the published front is unaffected).
	var thr := _fresh_grid()
	var w := EnvSimWorker.new(thr)
	w.start()
	var ok_pace := true
	w.poll(seq[0])                                  # kick sweep 0
	ok_pace = ok_pace and _wait_ready(w)
	for i in range(1, seq.size()):
		w.poll(seq[i])                              # commit sweep i-1, launch sweep i
		ok_pace = ok_pace and _wait_ready(w)
	w.poll(seq[seq.size() - 1])                     # commit the final sweep (launches a throwaway)
	w.stop()                                         # join (drains the throwaway; front = the last committed sweep)
	var thr_hash := thr.state_hash()
	_ok(ok_pace, "EVOLVE: the worker completed every lockstep sweep (no hang)")
	_ok(thr_hash == ref_hash, "EVOLVE: threaded state hash == shipped main-thread hash after %d sweeps (%d == %d)" % [seq.size(), thr_hash, ref_hash])
	_ok(thr.sweep_index() == ref.sweep_index(), "EVOLVE: same completed-sweep count (%d == %d)" % [thr.sweep_index(), ref.sweep_index()])
	# sanity: the drive actually moved the grid (a non-trivial evolution, not two frozen zero states).
	var moved := _fresh_grid()
	var start_hash := moved.state_hash()
	_ok(ref_hash != start_hash, "EVOLVE: the drive genuinely evolved the grid (final hash != seed hash)")

# ---------- G-WTHREAD-MAINCOST: main-thread per-frame weather cost ≈ 0 (no step_slice on main) ----------
func _gate_maincost() -> void:
	print("  --- G-WTHREAD-MAINCOST: poll() is a tiny fraction of the shipped per-frame step_slice ---")
	# Shipped main path cost: the per-frame sliced sweep (CELLS_PER_FRAME cells) that caused the walking hitch.
	var ref := _fresh_grid()
	for i in range(30):                             # warm so the fields are representative
		ref.step_slice(float(i), WS.CELLS_PER_FRAME)
	var frames := 1000
	var t0 := Time.get_ticks_usec()
	for f in range(frames):
		ref.step_slice(float(f), WS.CELLS_PER_FRAME)
	var slice_us := float(Time.get_ticks_usec() - t0) / float(frames)
	# Threaded main path cost: poll() only. The worker runs REAL physics off-thread; poll does a swap check
	# and, when a sweep is ready, a pointer flip + release — no sweep math on the main thread.
	var thr := _fresh_grid()
	var w := EnvSimWorker.new(thr)
	w.start()
	w.poll(0.0)
	var poll_us_total := 0.0
	var commits_seen := 0
	var prev_sweep := thr.sweep_index()
	for f in range(frames):
		var tp := Time.get_ticks_usec()
		w.poll(float(f) * 1000.0)
		poll_us_total += float(Time.get_ticks_usec() - tp)
		if thr.sweep_index() != prev_sweep:         # a commit happened on this poll (the expensive path)
			commits_seen += 1
			prev_sweep = thr.sweep_index()
		OS.delay_usec(50)                           # let wall-time pass so the worker completes real sweeps
	w.stop()
	var poll_us := poll_us_total / float(frames)
	print("    MAINCOST detail: main-thread poll() = %.3f µs/frame vs shipped step_slice = %.1f µs/frame (×%.0f slice=%d cells); %d commits observed" %
		[poll_us, slice_us, WS.CELLS_PER_FRAME, WS.CELLS_PER_FRAME, commits_seen])
	_ok(poll_us < slice_us * 0.1, "MAINCOST: poll() %.3f µs/frame < 10%% of step_slice %.1f µs/frame (no sweep on main)" % [poll_us, slice_us])
	_ok(poll_us < 20.0, "MAINCOST: poll() %.3f µs/frame is ~0 in absolute terms (< 20 µs)" % poll_us)
	_ok(commits_seen > 0, "MAINCOST: the worker completed & committed real sweeps off-thread (%d commits) — work truly moved off main" % commits_seen)
