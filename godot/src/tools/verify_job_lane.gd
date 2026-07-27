extends SceneTree
## COSMOS MAIN-THREAD ORCHESTRATION TH0 — the FP_JOB_LANE truth gate (docs/COSMOS-MAINTHREAD-ORCHESTRATION-
## DESIGN.md §6). Drives the JobLane DIRECTLY (flag-independent — the lane is a plain class), so the gate is
## valid in whatever CubeSphere flag state it launches in. Gates:
##   G-JL-OFF        FP_JOB_LANE defaults false — the byte-identity keystone (off ⇒ the lane is never
##                   constructed by WorldManager ⇒ nothing routes / pumps ⇒ shipped main-thread path).
##   G-JL-PRIORITY   a high-priority job submitted AFTER a queued low-priority bulk job DISPATCHES + commits
##                   FIRST (max_inflight=1 makes the order observable) — bulk can't jump latency-critical work.
##   G-JL-BOUNDED    the main-thread drain honours BOTH its N-per-frame cap and its ms budget — a flood of
##                   ready results commits at most N/frame, the rest wait (a flood can never blow the frame).
##   G-JL-CHUNK      a chunked job yields between slices (re-competes by priority) and commits once per slice —
##                   the "big job as bounded sub-jobs that interleave" support.
##   G-JL-NOTHREADS  the lane dispatches via WorkerThreadPool.add_task ONLY and creates NO Thread (structural
##                   source assertion + a live dispatch/complete round-trip through the shared pool).
const JobLaneC := preload("res://src/world/job_lane.gd")

var _pass := 0
var _fail := 0
var _order: Array[String] = []      # main-thread commit order (PRIORITY gate)
var _committed := 0                 # main-thread commit count (BOUNDED gate)
var _slices := 0                   # chunked-slice counter (CHUNK gate, worker-mutated single-writer)

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# --- job callables ------------------------------------------------------------------------------------
func _noop_worker() -> void:
	pass

func _commit_order(tag: String) -> void:
	_order.append(tag)

func _commit_count() -> void:
	_committed += 1

func _chunk_worker() -> bool:
	_slices += 1
	return _slices < 4              # true ⇒ another slice remains; false on the 4th (last) slice

# Pump the lane until every queue drains OR a bounded iteration budget is spent (never an infinite loop even
# if the pool stalls). Gives the shared WorkerThreadPool real time between pumps.
func _run_to_idle(lane) -> void:
	for _i in range(2000):
		lane.pump()
		if lane.is_idle():
			return
		OS.delay_msec(1)

func _initialize() -> void:
	print("=== verify_job_lane (TH0 FP_JOB_LANE) — flag=%s ===" % CubeSphere.FP_JOB_LANE)

	# G-JL-OFF — byte-identity keystone.
	_ok(CubeSphere.FP_JOB_LANE == false, "G-JL-OFF: FP_JOB_LANE defaults false (byte-identical; lane not constructed)")

	# G-JL-PRIORITY — high-after-low dispatches first (max_inflight=1 serialises so order is observable).
	_order.clear()
	var lp = JobLaneC.new(1)
	lp.submit(JobLaneC.PRIORITY_OPPORTUNISTIC, Callable(self, "_noop_worker"), Callable(self, "_commit_order").bind("low"), "low")
	lp.submit(JobLaneC.PRIORITY_CRITICAL, Callable(self, "_noop_worker"), Callable(self, "_commit_order").bind("high"), "high")
	_run_to_idle(lp)
	_ok(_order == ["high", "low"], "G-JL-PRIORITY: high-priority job dispatched/committed before the earlier low-priority bulk (got %s)" % [_order])

	# G-JL-BOUNDED — flood 8 jobs into READY (drain disabled via max_commits=0), then prove the N-cap bounds
	# the per-frame commit count. A flood of ready results commits at most N/frame; the rest wait.
	_committed = 0
	var lb = JobLaneC.new(2)
	for k in range(8):
		lb.submit(JobLaneC.PRIORITY_MANIFEST, Callable(self, "_noop_worker"), Callable(self, "_commit_count"), "bulk%d" % k)
	# Accumulate all 8 into _ready WITHOUT committing (max_commits=0 ⇒ drain is inert; forward-progress override
	# only applies to the ms-budget branch, never the N-cap).
	var flooded := false
	for _i in range(2000):
		lb.pump(0.0, 0)
		if lb.ready_count() == 8 and lb.pending_count() == 0 and lb.inflight_count() == 0:
			flooded = true
			break
		OS.delay_msec(1)
	_ok(flooded and _committed == 0, "G-JL-BOUNDED: 8 results flooded into READY with 0 committed under a 0-cap (ready=%d committed=%d)" % [lb.ready_count(), _committed])
	# One bounded drain frame: N-cap = 3 ⇒ exactly 3 commit, 5 remain, frame stays bounded.
	lb.pump(100.0, 3)
	_ok(lb.commits_last_frame == 3 and _committed == 3 and lb.ready_count() == 5, "G-JL-BOUNDED: one drain frame committed exactly the 3-cap, 5 deferred (this=%d total=%d ready=%d)" % [lb.commits_last_frame, _committed, lb.ready_count()])
	# The remainder drains over subsequent bounded frames (nothing lost).
	_run_to_idle(lb)
	_ok(_committed == 8 and lb.is_idle(), "G-JL-BOUNDED: all 8 eventually committed across bounded frames, lane idle (committed=%d)" % _committed)

	# G-JL-CHUNK — a chunked job yields between slices; commit runs once per slice (4 slices ⇒ 4 commits).
	_slices = 0
	_committed = 0
	var lc = JobLaneC.new(2)
	lc.submit_chunked(JobLaneC.PRIORITY_TEXTURE, Callable(self, "_chunk_worker"), Callable(self, "_commit_count"), "chunky")
	_run_to_idle(lc)
	_ok(_slices == 4 and _committed == 4, "G-JL-CHUNK: chunked job ran 4 interleaving slices, each with a main-thread commit (slices=%d commits=%d)" % [_slices, _committed])

	# G-JL-NOTHREADS — (a) structural: the source dispatches via WorkerThreadPool.add_task and creates NO Thread;
	# (b) live: a real dispatch/complete round-trip through the shared pool (proven by the runs above landing).
	var src := ""
	var f := FileAccess.open("res://src/world/job_lane.gd", FileAccess.READ)
	if f != null:
		src = f.get_as_text()
		f.close()
	var uses_pool := src.find("WorkerThreadPool.add_task") != -1
	# Scan CODE lines only (a comment may mention `Thread.new()` prose — see the class docstring): no non-comment
	# line may construct a dedicated Thread.
	var no_thread := true
	for line in src.split("\n"):
		var s := (line as String).strip_edges()
		if s.begins_with("#"):
			continue
		if s.find("Thread.new(") != -1:
			no_thread = false
			break
	_ok(src != "" and uses_pool and no_thread, "G-JL-NOTHREADS: lane dispatches via WorkerThreadPool.add_task and constructs no Thread (pool=%s no_thread=%s)" % [uses_pool, no_thread])
	# Live round-trip: a fresh one-shot job actually completes through the pool.
	_committed = 0
	var ln = JobLaneC.new(2)
	ln.submit(JobLaneC.PRIORITY_CRITICAL, Callable(self, "_noop_worker"), Callable(self, "_commit_count"), "rt")
	_run_to_idle(ln)
	_ok(_committed == 1, "G-JL-NOTHREADS: a job dispatched onto the shared WorkerThreadPool completed + committed (committed=%d)" % _committed)

	# main_commit_ms telemetry surface: the lane accumulates drain time and resets on read.
	var lt = JobLaneC.new(2)
	lt.submit(JobLaneC.PRIORITY_MANIFEST, Callable(self, "_noop_worker"), Callable(self, "_commit_count"), "tm")
	_run_to_idle(lt)
	var first := lt.take_main_commit_ms()
	var second := lt.take_main_commit_ms()
	_ok(first >= 0.0 and second == 0.0, "G-JL-TELEMETRY: take_main_commit_ms returns accumulated drain time then resets (first=%.3f second=%.3f)" % [first, second])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
