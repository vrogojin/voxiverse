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
	if CubeSphere.FP_ENV_FALLBACK_EMIT:
		# Fallback fills a cheap chord for every past-batch facet, so ALL are cached; only ENV_WARM_BATCH are ENVELOPED.
		ok = _expect(ring2._env_done.size() == FacetFarRing.ENV_WARM_BATCH, "B exactly ENV_WARM_BATCH facets ENVELOPED this cycle") and ok
		ok = _expect(ring2._pos_cache.size() == fids.size(), "B every visible facet has a coarse cache (chord fills past the batch)") and ok
	else:
		ok = _expect(ring2._pos_cache.size() == FacetFarRing.ENV_WARM_BATCH, "B exactly ENV_WARM_BATCH facets cached this cycle") and ok

	# C) COVERAGE MID-CONVERGENCE (G-COVER, FP_ENV_FALLBACK_EMIT). The regression: with the warm mid-flight the worker
	# skipped every past-batch uncached facet, so the orbit near-hemisphere rendered BLACK (live sh_emit 766 < visN 947).
	# THE assertion: after ONE dispatch of a >batch front, EVERY visible facet has a cache to DRAW (env OR chord fallback)
	# — no holes. With FP_ENV_FALLBACK_EMIT on this holds structurally; off, it fails at ENV_WARM_BATCH (the hole, in
	# miniature) — exactly what B's bound-only check missed.
	var ring3 := FacetFarRing.new()
	FacetFarRing.env_build_main = 0
	FacetFarRing.env_build_worker = 0
	var fids3 := PackedInt32Array()
	for fid in range(300, 300 + FacetFarRing.ENV_WARM_BATCH + 40):   # ~40 facets beyond one warm batch
		fids3.append(fid)
	ring3._async_fids = fids3
	ring3._async_backstop = {}
	ring3._async_env_warm = true
	ring3._async_building = true
	var task3: int = WorkerThreadPool.add_task(Callable(ring3, "_async_build_worker"), false, "coverage proof")
	WorkerThreadPool.wait_for_task_completion(task3)
	var covered := 0
	for fid in fids3:
		if ring3._pos_cache.has(fid) or ring3._bpos_cache.has(fid):
			covered += 1
	var env_n: int = ring3._env_done.size()
	print("C) coverage: %d/%d visible facets have a draw cache; env-enveloped this cycle=%d (batch=%d); fallback=%s" % [
		covered, fids3.size(), env_n, FacetFarRing.ENV_WARM_BATCH, str(CubeSphere.FP_ENV_FALLBACK_EMIT)])
	if CubeSphere.FP_ENV_FALLBACK_EMIT:
		ok = _expect(covered == fids3.size(), "C coverage == visible set (NO black holes) — THE fix") and ok
		ok = _expect(env_n == FacetFarRing.ENV_WARM_BATCH, "C env bound honoured (only the batch is enveloped; the rest chord)") and ok
	else:
		ok = _expect(covered == FacetFarRing.ENV_WARM_BATCH, "C (fallback OFF) shipped hole: only the batch is covered (would black-hole in orbit)") and ok
	_finish(ok)

func _expect(cond: bool, label: String) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	return cond

func _finish(ok: bool) -> void:
	print("RESULT: ", "ALL PASS" if ok else "FAILURES")
	quit(0 if ok else 1)
