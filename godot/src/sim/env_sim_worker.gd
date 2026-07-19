class_name EnvSimWorker
extends RefCounted
## Reusable WORKER-THREAD + DOUBLE-BUFFER harness for environmental simulations — the pilot's request to
## "use a separate dedicated thread for the weather simulation (and later for all other environmental
## simulations) to offload the main game cycle". FP_WEATHER_THREAD (WeatherSystem) is its first and, today,
## its only consumer; it is written as a small generic base so a future field sim reuses it verbatim.
##
## THE MODEL — one PRODUCER (the worker thread), one CONSUMER (the main thread), a shared DOUBLE buffer
## that the driven sim already owns:
##   * the worker WRITES only the BACK buffer, READING the FRONT buffer as its (read-only) source;
##   * the main thread READS only the FRONT buffer (its consumers query it throughout the frame);
##   * FRONT/BACK are flipped by exactly ONE `commit_swap()` on the MAIN thread — the single
##     synchronisation point — and ONLY while the worker is QUIESCED (blocked between sweeps).
##
## WHY IT IS RACE-FREE (the whole game; gate G-WTHREAD-SAFE proves it under real threads):
##   * concurrent READS of the front buffer by both threads are safe — there is no writer of the front;
##   * the worker's WRITES land in the back buffer, which the main thread never reads;
##   * the pointer flip mutates one bool and runs only when the worker has finished a sweep and is blocked
##     on the go semaphore, so at the instant of the flip the worker is provably not touching any buffer.
## Because the flip is the only shared mutation and it happens at a quiescent instant, NO mutex guards the
## read hot path — the main thread's per-frame weather cost collapses to the swap check (≈ one lock of a
## bool + an optional pointer flip), i.e. ~0 (gate G-WTHREAD-MAINCOST). With a strict double buffer the
## worker MUST block after each sweep until the swap (it has nowhere else to write); that block is a plain
## semaphore wait (no busy spin), and it caps the publish rate at one sweep per poll — exactly what the
## single consumer needs. NEVER-OOM: this adds only the Thread stack + a Mutex + a Semaphore; it allocates
## NO simulation buffers (the sim owns its pre-allocated double buffer) and nothing per sweep.
##
## DETERMINISM: threading unlinks the sweep cadence from the frame, so the exact sweep sequence is no
## longer frame-locked — acceptable for a field that evolves over minutes. The sim stays deterministic
## GIVEN its driven (SEED + game_time) sequence: `worker_sweep` must advance by SIM-TIME (elapsed
## game_time), never by a per-frame count, so the same driven time sequence reproduces the same state
## regardless of how sweeps interleave with frames (gate G-WTHREAD-EVOLVE asserts an EXACT match against a
## synchronous reference driven with the identical time sequence).
##
## THE CONTRACT — the driven `sim` (any RefCounted/Object) must expose exactly two methods:
##   * worker_sweep(game_time: float) -> void   # compute ONE complete sweep into the back buffer (worker)
##   * commit_swap() -> void                      # publish: flip the front/back pointer (main, quiesced)

var _sim: Object = null
var _thread: Thread = null
var _go: Semaphore = null              ## main → worker: "run one sweep" (also the teardown wakeup)
var _mutex: Mutex = null               ## guards _ready and _exit (tiny critical sections only)
var _ready := false                    ## worker → main: a completed sweep sits in the back buffer
var _exit := false                     ## teardown requested
var _running := false                  ## the thread is live
var _kicked := false                   ## the first sweep has been released
# _pending_gt is handed across the go handshake: the main thread writes it right BEFORE posting `go`, the
# worker reads it right AFTER `go.wait()` returns. Those two points can never overlap (the main thread does
# not post again until it has seen _ready, which the worker sets only after the sweep that consumed it), so
# the semaphore's happens-before is the whole synchronisation — no separate lock is needed for this scalar.
var _pending_gt := 0.0

func _init(sim: Object) -> void:
	_sim = sim

## Spin the worker thread. It immediately BLOCKS on the go semaphore; the first `poll()` releases sweep 1.
func start() -> void:
	if _running:
		return
	_go = Semaphore.new()
	_mutex = Mutex.new()
	_thread = Thread.new()
	_exit = false
	_ready = false
	_kicked = false
	_running = true
	_thread.start(_worker_loop)

## Call once per frame on the MAIN thread. Cheap by construction: it (a) commits a ready sweep — the single
## sync point, a pointer flip taken while the worker is quiesced — and (b) releases the next sweep. NO
## simulation math runs on the main thread here.
func poll(game_time: float) -> void:
	if not _running:
		return
	if not _kicked:
		_pending_gt = game_time            # published before the release (happens-before the worker read)
		_kicked = true
		_go.post()
		return
	_mutex.lock()
	var ready := _ready
	if ready:
		_ready = false
	_mutex.unlock()
	if ready:
		# The worker set _ready THEN blocked on `go`, so it is NOT touching any buffer right now: the flip
		# is race-free. This is THE synchronisation point of the whole design.
		_sim.call("commit_swap")
		_pending_gt = game_time            # handed to the next sweep; the worker reads it after the post
		_go.post()

## True when a completed sweep is waiting for commit (lets the gate observe the handshake / pace lockstep).
func has_ready() -> bool:
	if not _running:
		return false
	_mutex.lock()
	var r := _ready
	_mutex.unlock()
	return r

## Clean teardown: request exit, wake the worker, and JOIN it. Safe to call when never started or twice
## (no dangling thread on scene exit — the SnowfallSystem/pool lifecycle discipline).
func stop() -> void:
	if not _running:
		return
	_mutex.lock()
	_exit = true
	_mutex.unlock()
	_go.post()                             # wake the worker if it is blocked between sweeps
	_thread.wait_to_finish()               # JOIN — the sweep in flight (if any) drains first
	_running = false
	_thread = null
	_go = null
	_mutex = null

func is_running() -> bool:
	return _running

# --- the worker thread body -----------------------------------------------------------------------
# Loop: block for a release, bail on exit, else run ONE full sweep into the back buffer and publish it.
# Every path back to `go.wait()` leaves the buffers untouched, so the main thread's flip is always safe.
func _worker_loop() -> void:
	while true:
		_go.wait()                         # block (no spin) until main releases a sweep or requests exit
		_mutex.lock()
		var exit := _exit
		_mutex.unlock()
		if exit:
			return
		var gt := _pending_gt              # safe: read only here, after the go handshake (see poll)
		_sim.call("worker_sweep", gt)      # writes the BACK buffer only; reads the front as its source
		_mutex.lock()
		_ready = true                      # publish: a completed sweep awaits the main thread's commit
		_mutex.unlock()
