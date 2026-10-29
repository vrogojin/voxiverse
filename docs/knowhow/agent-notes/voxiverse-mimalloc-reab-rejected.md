---
name: voxiverse-mimalloc-reab-rejected
description: 2026-08-22 P6 mimalloc re-A/B REJECTED on NEVER-OOM (+398MB heap) and no orbit frame win — dlmalloc stays
metadata: 
  node_type: memory
  type: project
---

2026-08-22 (P6, after perf batch PR #78 merged c489de6). Re-ran the mimalloc A/B now that the NEVER-OOM
gate is finally MEASURABLE: `heap_mb` telemetry (`_wasm_heap_mb()` = wasmMemory.buffer.byteLength, the TRUE
linear-memory OOM signal) landed in a087d48 and rides on the **FP_TELEM_LITE** just shipped. mimalloc had
been reverted to dlmalloc back in 5e986b9 as a PRECAUTION (heap unmeasurable then, probe returned -2), not a
measured rejection — L2 had shown worst_ms p50 −23% on the WALKING workload. So this was the honest re-test.

METHOD: WEB_MALLOC=mimalloc in docker/engine/versions.env (engine patch 0002 wires `-sMALLOC=` via scons
`malloc=`; libmimalloc-mt.a compiled in, module_in_web=yes, +22KB template). Rebuilt web templates (~3.5min
warm), deployed via deploy_cheats.sh. Two-phase live A/B at the IDENTICAL settled scene (village
-39.506,-35.956 → set_alt 2500 → freeze_player → 30s settle → 40-frame window). dlmalloc baseline captured
on the current live build FIRST (before overwriting), then mimalloc, then a 90s WARM re-capture so bake
states matched (fm_baked mimalloc 249-402 ≥ dlmalloc 95-300).

VERDICT — REJECT (dlmalloc stays; live reverted + rebuilt dlmalloc). CONFIRMED by a CLEAN-BROWSER re-run
(user restarted the browser suspecting mem/CPU leak poison — good instinct, partly right):
- **heap_mb: dlmalloc 412.3 (DEAD FLAT, byte-IDENTICAL across BOTH sessions) vs mimalloc 810→834 (flat at
  capture, plateaued). Δ = +398 to +422 MB.** NEVER-OOM ceiling is **+120 MB** (docs/COSMOS-FP-M2-HEAP-AB
  §1.1) → violated **~3.5×**. Root: mimalloc reserves per-thread segments × WEB_PTHREAD_POOL=24 preallocated
  Web Workers = huge fixed baseline. This is the SOLE, decisive veto — heap_mb = engine wasmMemory.byteLength
  is DETERMINISTIC (reproduced 412.3 exactly twice) and browser-leak-IMMUNE (not process RSS). Memory safety
  outranks frame time (locked rule) → veto stands regardless of workload.
- **Frame time at orbit = a WASH, NOT worse.** First (poisoned) run showed mimalloc slower (fps 35.6 vs 43.3);
  the CLEAN warm-matched re-run showed mimalloc EQUAL-or-marginally-better: fps 38.8 vs dlmalloc 37.3,
  hitches 4.17 vs 5.13/s, frame_ms 29.3 vs 33.5. LESSON: fps/hitches at orbit are NOISY — they track how hard
  the fine-map prebake is grinding at capture time (fm_baked rate) AND accumulated browser state; ALWAYS
  warm-match bake state (fm_baked) and use a FRESH browser. heap_mb is the only clean A/B signal here.
- The L2 −23% was a WALKING/streaming workload (dense per-block heap ops → dlmalloc single-global-lock convoy;
  main busy-waits). At FROZEN ORBIT there is no streaming convoy for mimalloc to relieve → no win, only +422 MB.
  mimalloc MIGHT still help WALKING (untested), but the +422 MB heap veto applies to any workload, so it can't
  ship without first shrinking the per-thread-segment cost (e.g. lower WEB_PTHREAD_POOL, or mimalloc seg tuning).

LESSON: the allocator win is workload-specific (walking-streaming, not orbit). But it doesn't matter here —
the +398 MB heap alone is a definitive NEVER-OOM reject, so even a walking win couldn't ship it without a way
to shrink the per-thread-segment baseline (e.g. drop WEB_PTHREAD_POOL, or mimalloc segment-size tuning —
untested). engine patch 0002 stays inert at dlmalloc; the flip is one line if that baseline problem is ever
solved. The REAL smoothness win remains the P0-P4 GDScript batch (PR #78): orbit freeze gone, fps 10→43,
max frame 1106→147ms. Residual ~2.3 hitches/s at orbit = the whole-planet fine-map prebake grind (3456 tiles
baked from scratch each load) — the next lever is PACING/SCOPING that prebake, NOT the allocator.
[[voxiverse-walk-perf-root-cause]] [[voxiverse-never-oom-web]] [[voxiverse-orbit-perf-farring-churn]]
