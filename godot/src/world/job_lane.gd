class_name JobLane
extends RefCounted
## COSMOS MAIN-THREAD ORCHESTRATION TH0 (docs/COSMOS-MAINTHREAD-ORCHESTRATION-DESIGN.md §2) — the thin
## priority JOB LANE that lets the main thread "do nothing but orchestrate other threads". It is the single
## multiplexer through which every future offload (TH1 tex bake, TH2 far-ring warm, TH3 manifest build,
## TH4 skin/snow) hands its COMPUTE to a worker and gets a bounded MAIN-THREAD commit back.
##
## THE CONTRACT — a job is two Callables:
##   * `dispatch`  — runs on a WorkerThreadPool worker. PURE CPU: worldgen/mesh/SurfaceTool/Image/sampling.
##                   It writes ONLY into buffers the SUBMITTER owns single-writer while the job is in flight;
##                   it must NEVER touch RenderingServer or the scene tree (the far-ring worker contract,
##                   facet_far_ring.gd:864-935). For a CHUNKED job it advances one bounded slice per call.
##   * `commit`    — runs on the MAIN thread during the per-frame drain, under a ms + N-per-frame budget.
##                   The ONLY place a job may touch the GPU / scene tree (mesh swap, update_layer, add_model).
##
## WHY NO NEW THREADS (design law §1): the Emscripten pool is FIXED at 16 (PTHREAD_POOL_SIZE, engine patch
## 0001) and already ledgered at 15 worst-case. This lane spawns ZERO threads — it dispatches EXCLUSIVELY via
## `WorkerThreadPool.add_task` (the shared pool, ≤2 slots budgeted) and gates itself to `max_inflight` tasks
## at a time, so it can never exhaust the pool (the known blank-world failure). There is NO `Thread.new()` in
## this file — G-JL-NOTHREADS asserts that structurally.
##
## WHY IT DOESN'T STARVE LATENCY-CRITICAL WORK (§5.3): the pending set is drained HIGHEST-PRIORITY-FIRST, so a
## crossing-critical far-ring rebuild (PRIORITY_CRITICAL) submitted AFTER a bulk manifest slice
## (PRIORITY_OPPORTUNISTIC) that is still queued dispatches BEFORE it. A big job is submitted CHUNKED — each
## chunk re-queues after its commit, so a higher-priority job inserted mid-run preempts the remaining chunks.
##
## NEVER-OOM / dlmalloc (§4, §5.1): the lane holds ONLY Callables + gate bools + small ints — it allocates NO
## marshalling buffers (those are the submitter's preallocated ledgers). Even its own Job bookkeeping is
## POOLED (a free-list, `_free`) so a steady stream of submits does not churn the shared WASM allocator.

# Priority bands (higher dispatches first) — the design's ordering: crossing > tex bake > manifest > opportunistic.
const PRIORITY_CRITICAL := 100      # crossing-critical far-ring rebuild (TH2 force paths)
const PRIORITY_TEXTURE := 70        # facet-tex base / close-up bake (TH1)
const PRIORITY_MANIFEST := 40       # manifest model construction (TH3)
const PRIORITY_OPPORTUNISTIC := 10  # skin tiles / block-LOD / bulk warm (TH4)

# Default main-thread drain budget — the commit phase never spends more than this per frame (design §3: the
# main thread pays ONLY the bounded commit). Callers may override per-pump for a specific subsystem cadence.
const COMMIT_BUDGET_MS := 2.0
const COMMIT_MAX_PER_FRAME := 6     # hard N-cap so a flood of ready results can't blow the frame (G-JL-BOUNDED)

## One unit of work. Pooled + reused (never freed per-job) to keep the lane allocation-flat under load.
class Job:
	extends RefCounted
	var priority := 0
	var dispatch: Callable
	var commit: Callable
	var tag := ""
	var chunked := false
	var _more := false          # worker sets this (chunked dispatch returns true ⇒ another slice remains)
	var _task_id := -1
	func reset() -> void:
		priority = 0
		dispatch = Callable()
		commit = Callable()
		tag = ""
		chunked = false
		_more = false
		_task_id = -1

var _pending: Array[Job] = []   # queued, not yet dispatched (drained highest-priority-first)
var _running: Array[Job] = []   # dispatched onto WorkerThreadPool, not yet completed
var _ready: Array[Job] = []     # worker done, awaiting the bounded main-thread commit
var _free: Array[Job] = []      # POOL: reusable Job instances (never allocate per-submit once warm)

var _max_inflight := 2          # ≤2 WorkerThreadPool slots (the ledgered budget); configurable for gates
var _main_commit_us := 0        # accumulated main-thread commit time since the last take (telemetry)
var commits_last_frame := 0     # commits run in the most recent drain (gate observable)

func _init(max_inflight := 2) -> void:
	_max_inflight = maxi(1, max_inflight)

## Acquire a pooled Job (or make one only when the pool is empty — a bounded one-time warm cost).
func _acquire() -> Job:
	var j: Job = _free.pop_back() if not _free.is_empty() else Job.new()
	j.reset()
	return j

## SUBMIT a one-shot job: `dispatch` computes on a worker, `commit` (optional) commits on main. Higher
## `priority` dispatches first. Returns immediately — the work runs on a later pump.
func submit(priority: int, dispatch: Callable, commit := Callable(), tag := "") -> void:
	var j := _acquire()
	j.priority = priority
	j.dispatch = dispatch
	j.commit = commit
	j.tag = tag
	j.chunked = false
	_enqueue(j)

## SUBMIT a CHUNKED job: `chunk` runs one bounded slice per dispatch and RETURNS true while more slices
## remain; `commit` runs after each slice. The lane re-queues the job (competing again by priority) until a
## slice returns false — so a big build interleaves with, and yields to, higher-priority work between chunks.
func submit_chunked(priority: int, chunk: Callable, commit := Callable(), tag := "") -> void:
	var j := _acquire()
	j.priority = priority
	j.dispatch = chunk
	j.commit = commit
	j.tag = tag
	j.chunked = true
	_enqueue(j)

## Priority-insert into the pending queue (highest priority at the FRONT so dispatch is a cheap pop_front).
func _enqueue(j: Job) -> void:
	var i := 0
	while i < _pending.size() and _pending[i].priority >= j.priority:
		i += 1
	_pending.insert(i, j)

## MAIN THREAD, once per frame: (1) reap finished workers, (2) drain ready commits under the budget, (3) fill
## free worker slots highest-priority-first. `commit_budget_ms` / `max_commits` bound the main-thread cost.
func pump(commit_budget_ms := COMMIT_BUDGET_MS, max_commits := COMMIT_MAX_PER_FRAME) -> void:
	_reap()
	_drain(commit_budget_ms, max_commits)
	_fill_slots()

## Move every COMPLETED running task to the ready queue (its commit is paid on the main thread in _drain).
## wait_for_task_completion on an already-finished task only reclaims the handle — it never blocks here (the
## far-ring poll contract, facet_far_ring.gd:940-949).
func _reap() -> void:
	var i := _running.size() - 1
	while i >= 0:
		var j := _running[i]
		if WorkerThreadPool.is_task_completed(j._task_id):
			WorkerThreadPool.wait_for_task_completion(j._task_id)
			j._task_id = -1
			_running.remove_at(i)
			_ready.append(j)
		i -= 1

## MAIN THREAD: run ready commits under BOTH a ms budget and an N-per-frame cap. Whatever doesn't fit stays in
## `_ready` for the next frame — a flood of results can never blow the frame (G-JL-BOUNDED). A chunked job with
## another slice remaining is re-queued (by priority) after its commit, so its next chunk competes fairly.
func _drain(budget_ms: float, max_commits: int) -> void:
	var t0 := Time.get_ticks_usec()
	commits_last_frame = 0
	while not _ready.is_empty():
		if commits_last_frame >= max_commits:
			break
		if commits_last_frame > 0 and float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			break   # never abandon the FIRST commit for the budget — always make forward progress
		var j: Job = _ready.pop_front()
		if j.commit.is_valid():
			j.commit.call()
		commits_last_frame += 1
		if j.chunked and j._more:
			j._more = false
			_enqueue(j)          # more slices remain — re-compete (reuses the SAME pooled Job, no alloc)
		else:
			_recycle(j)
	_main_commit_us += Time.get_ticks_usec() - t0

## Dispatch pending jobs onto the shared WorkerThreadPool until the in-flight budget is full — NEVER spawning a
## thread (add_task multiplexes onto the fixed pool). Highest priority goes first (pending is priority-sorted).
func _fill_slots() -> void:
	while _running.size() < _max_inflight and not _pending.is_empty():
		var j: Job = _pending.pop_front()
		# _worker_entry wraps the submitter's dispatch so a chunked return value is captured into j._more
		# (WorkerThreadPool discards a task's return, so the wrapper records it on the job instead).
		j._task_id = WorkerThreadPool.add_task(_worker_entry.bind(j), false, "job-lane:" + j.tag)
		_running.append(j)

## WORKER THREAD: run the submitter's compute. For a chunked job the dispatch returns true while more slices
## remain; a one-shot job's return is ignored. NOTHING here touches the RenderingServer or the tree.
func _worker_entry(j: Job) -> void:
	var r: Variant = j.dispatch.call()
	j._more = j.chunked and (r == true)

## Return a finished Job to the pool for reuse (allocation-flat under a steady submit stream).
func _recycle(j: Job) -> void:
	j.reset()
	if _free.size() < 32:        # bounded pool — never a growing leak
		_free.append(j)

## TELEMETRY (design TH0): the accumulated MAIN-THREAD commit/drain time in ms since the last read, then reset.
## This is the number that must DROP as TH1+ move compute off main (proving cost left the frame, not just the
## timer). Reported via WorldManager.take_perf_attrib → RemoteBridge telemetry as `main_commit_ms`.
func take_main_commit_ms() -> float:
	var ms := float(_main_commit_us) / 1000.0
	_main_commit_us = 0
	return ms

# --- Gate observables (headless, flag-independent) -----------------------------------------------------
func pending_count() -> int: return _pending.size()
func inflight_count() -> int: return _running.size()
func ready_count() -> int: return _ready.size()
func is_idle() -> bool: return _pending.is_empty() and _running.is_empty() and _ready.is_empty()
