extends SceneTree
## Proves FP_ENV_WARM_ASYNC relocates the heavy env-cache build off the main thread:
##  A) MAIN-warm baseline — _ensure_cached on the main thread attributes builds to env_build_main.
##  B) WORKER-warm      — a real WorkerThreadPool dispatch of _async_build_worker with _async_env_warm=true
##                        builds the env caches on the WORKER thread (env_build_worker) while env_build_main is FROZEN,
##                        and honours the ENV_WARM_BATCH bound.
## Requires the env_all flags on (measure with the deploy flag set). Exits 0 all-pass, 1 on any failure.

func _init() -> void:
	var ok := true
	print("env_all_on=", TierPlace.env_all_on(),
		" FP_ENV_WARM_ASYNC=", CubeSphere.FP_ENV_WARM_ASYNC,
		" cores=", OS.get_processor_count())
	if not TierPlace.env_all_on():
		print("SKIP: env_all not on (need FP_ENV_ALL+FP_FARRING_FULL_COVER+FP_SHELL_WELD)"); quit(0); return
	FacetAtlas.warm_up()

	# A) main-thread warm attribution
	var ring := FacetFarRing.new()
	FacetFarRing.env_build_main = 0
	FacetFarRing.env_build_worker = 0
	var main_fids := [3, 7, 11, 15, 19]
	for fid in main_fids:
		ring._ensure_cached(fid)
	var a_main: int = FacetFarRing.env_build_main
	var a_wrk: int = FacetFarRing.env_build_worker
	print("A) main warm %d facets → env_build_main=%d  env_build_worker=%d" % [main_fids.size(), a_main, a_wrk])
	ok = _expect(a_main == main_fids.size(), "A main count == %d" % main_fids.size()) and ok
	ok = _expect(a_wrk == 0, "A worker count == 0") and ok

	# B) worker-thread warm attribution (real dispatch). Full front set of UNCACHED fids; the worker builds a bounded
	# batch off-thread. Use a fresh ring so no cache is pre-warmed.
	if OS.get_processor_count() <= 1:
		print("SKIP B: single-core host (async path falls back to sync by design)")
		_finish(ok); return
	var ring2 := FacetFarRing.new()
	FacetFarRing.env_build_main = 0
	FacetFarRing.env_build_worker = 0
	var fids := PackedInt32Array()
	for fid in range(100, 100 + FacetFarRing.ENV_WARM_BATCH + 8):   # more than one batch → proves the bound
		fids.append(fid)
	ring2._async_fids = fids
	ring2._async_backstop = {}          # orbit: no backstop facets
	ring2._async_env_warm = true        # the frozen "worker warms its own env caches" decision
	ring2._async_building = true
	var task: int = WorkerThreadPool.add_task(Callable(ring2, "_async_build_worker"), false, "env-warm proof")
	WorkerThreadPool.wait_for_task_completion(task)
	var b_main: int = FacetFarRing.env_build_main
	var b_wrk: int = FacetFarRing.env_build_worker
	print("B) worker dispatch of %d uncached fids (batch=%d) → env_build_main=%d  env_build_worker=%d" % [
		fids.size(), FacetFarRing.ENV_WARM_BATCH, b_main, b_wrk])
	ok = _expect(b_main == 0, "B main count == 0 (nothing built on main thread)") and ok
	ok = _expect(b_wrk == FacetFarRing.ENV_WARM_BATCH, "B worker count == ENV_WARM_BATCH bound (%d)" % FacetFarRing.ENV_WARM_BATCH) and ok
	ok = _expect(ring2._pos_cache.size() == FacetFarRing.ENV_WARM_BATCH, "B exactly ENV_WARM_BATCH facets cached this cycle") and ok
	_finish(ok)

func _expect(cond: bool, label: String) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	return cond

func _finish(ok: bool) -> void:
	print("RESULT: ", "ALL PASS" if ok else "FAILURES")
	quit(0 if ok else 1)
