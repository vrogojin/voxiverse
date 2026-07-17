# COSMOS — Walking Performance: Root Cause, Ranked Plan, SOTA Survey

**Status:** analysis + ranked design (no implementation in this pass). Branch `deploy/perf-plus-sky`, 2026-07-17.
**Author:** Fable (deep-analysis pass), commissioned after the 2026-07-17 morning live measurements.
**Predecessors:** `COSMOS-PERF-ARCHITECTURE-ANALYSIS.md` (draw-call verdict → atlas, standing now 60 fps),
`COSMOS-PERF-NEXT-ARCHITECTURE.md`, `COSMOS-GEN-EFFICIENCY-DESIGN.md` (the measured gen cost model),
`COSMOS-CROSSING-FASTGEN-DESIGN.md`. This doc supersedes the **"2-worker web gen ceiling"** framing
and refutes part of the mesh-apply-budget framing written into `godot/project.godot:74-91`.

> **Headline (revised after E5, §2.9).** Walking is slow **only while the streaming pipeline is
> active** — movement with an empty generation queue is **free** (worst_ms p50 23.4 vs 23.2
> standing, §1) — and NOT because of mesh-apply budget, draw calls, physics, or movement itself.
> The original prime suspect (single-lock Emscripten allocator) was **tested and demoted**: the
> mimalloc A/B moved worst_ms p50 −23% and nothing else (§2.9). The leading explanation is now
> **genuine per-block GDScript-VM-on-WASM cost (~150–240 worker-ms) plus physical-core
> oversubscription on the user's SMT laptop** (6 workers + main on ~4 physical cores). The
> decisive next instrument is E9 (per-block wall time inside `_generate_block`, no rebuild) ×
> E2 (worker-count A/B); the likely levers are a device-aware worker cap for smoothness (L4b),
> the allocation diet (L3), and — if E9 confirms — the C++ generator port (L5a) as the main
> event. No architecture change is needed (§7).

---

## 0. What question this answers

The user asked: *fix walking performance; what else can be done; are there SOTA techniques or
similar projects that help?* The team lead asked specifically to settle **apply-bound vs gen-bound
vs upload-bound vs fill-bound**, reconcile a 19× throughput gap (44 blocks/s measured vs ~833
theoretical), and to check the hypothesis that the `voxel/threads/main/time_budget_ms=6` mesh-apply
budget is the drain governor (6 ms/frame ÷ ~8 ms/block × 60 fps ≈ 45/s ≈ the measured 44/s).

Short answers, argued below:

1. **The apply-budget arithmetic is a numerical coincidence.** The apply queue is *empty*
   (`vox_main` mean 0.002 over 10 830 live samples, §1.4), mesh-apply back-pressure **cannot**
   stall the generation queue (there is no bounded queue between them, §2.3), and finished
   generation results are applied **unbounded** per frame, outside the 6 ms budget
   (`voxel_engine.cpp:299-303`). Varying the budget 6→2/6→12 is predicted to change nothing
   measurable (§5 E3) — that experiment kills or confirms this cheaply.
2. **The drain IS worker-side** — but the workers collectively deliver only ~1–1.5 native-threads'
   worth of throughput despite 6 running (measured live: `pool_active = 6/6`, saturated on
   GenerateBlock through an entire drain — see §2.4a), and their throughput is *negatively
   correlated with main-thread frame time* (r = −0.47, §1.5): when the main thread stalls,
   generation stalls, and vice versa. That bidirectional coupling is the fingerprint of a **shared serializer in the
   WASM runtime**, not of a slow generator or a task-queue defect.
3. **Walking jank is the same phenomenon seen from the main thread's side.** Standing still with a
   draining backlog already produces worst_ms p50 43.8–60.9 (vs 23.2 idle); walking adds demand
   (backlog grows +67/s net at a 3.4 vox/s stroll) which keeps the pipeline hot, which keeps the
   main thread degraded. `phys_ms` for the *same* movement code is 7.4 ms with idle workers and
   31.0 ms with busy workers (§1.3) — the movement code did not get slower; the runtime did.

---

## 1. Measured ground truth (this morning's telemetry, re-analyzed)

Source: `tools/remote-bridge/results/telemetry.jsonl`, session 2026-07-17 10:13–11:00 (10 830
records @250 ms, real user GPU, all FP flags live). Analysis script rerunnable from the raw file.
Movement derived from `pos` deltas; "moving" = speed > 1 vox/s, "still" = < 0.05 vox/s.

### 1.1 The four-quadrant decomposition (the load-bearing table)

| condition | n | worst_ms p50 | worst_ms p90 | phys_ms p50 |
|---|---|---|---|---|
| **moving, vox_gen > 50** | 59 | **69.1** | 120.1 | **31.0** |
| **moving, vox_gen ≤ 5** | 15 | **23.4** | 24.8 | **7.4** |
| **still, vox_gen > 200** | 282 | **43.8** | 121.2 | 9.7 |
| **still, vox_gen ≤ 5** | 10 433 | **23.2** | 30.1 | 2.9 |

Three verdicts fall out immediately:

- **Movement is exonerated.** Walking through already-generated terrain (row 2) is
  indistinguishable from standing (row 4). GroundCollider, analytic sampling, the player
  controller, draw calls at walking view angles — all fine. (Caveat: n=15 ≈ 4 s; §5 E7 re-confirms
  with a deliberate circle-walk.)
- **Streaming activity alone degrades the main thread.** Row 3: the player is *stationary*, no new
  view volume is being requested beyond the initial fill, physics is quiet (9.7 ms) — yet worst_ms
  doubles and p90 hits 121 ms. Whatever hurts walking hurts *standing during a drain* almost as much.
- **`phys_ms` inflation tracks worker activity, not physics work.** The same movement+physics code
  path reads 7.4 ms (idle workers) vs 31.0 ms (busy workers). `TIME_PHYSICS_PROCESS` measures real
  step time (unlike `TIME_PROCESS`, which is rAF-polluted and remains invalid); the step itself is
  being *slowed from outside*.

### 1.2 Throughput: what the pipeline actually delivers

Stationary drain episodes (still, backlog > 100, contiguous):

- `vox_gen` 1342 → 112 over 48 s = **25.8 blocks/s** (worst_ms p50 38.0 during it)
- `vox_gen` 1362 → 103 over 37 s = **33.9 blocks/s** (worst_ms p50 47.6)
- Instantaneous (250 ms windows): p50 37/s, p90 72/s, **max 167/s**.

The team lead's "44 blocks/s" is confirmed in kind (same order; 26–34/s in the cleanest stationary
windows). These are *gross* rates — the player was still, view ramps settled, so adds ≈ 0.

### 1.3 Demand: what walking asks for

One clean 20 s walk at p50 **3.4 vox/s** (measured from `pos`; ~walking pace, not sprint) grew
`vox_gen` from 0 → 1364 = **net +67 blocks/s**; gross demand ≈ 90–100 blocks/s once concurrent
supply is added back. Geometric first-principles demand for the bare viewer ellipsoid (r=128,
vertical ≈ +64/−40 via the A2 clamp, `terrain_config.gd:166-198`) is only ~15–20 blocks/s at that
speed — so **~4–5× of the walking demand is not the near ellipsoid itself** but the surrounding
machinery (neighbour-pool view ramps, vel-predict lead, LOD probes). Unverified decomposition;
worth one instrumented walk (§5 E8) before optimizing demand.

**Deficit arithmetic:** demand ~90–100/s vs supply 26–34/s (which *falls* under load, §1.5) —
walking at 3.4 vox/s outruns the pipeline ~3×. That is the entire "mesh-lag see-through" class
(obs-2/3), and it is why the backlog peaked at 1416 while walking.

### 1.4 The apply queue is empty — the budget is not the governor

- `vox_main` (= pending `ITimeSpreadTask`s + progressive tasks, i.e. exactly the queue the 6 ms
  budget serves — `voxel_engine.cpp:389`): **mean 0.002, max 20, nonzero in ~0.0% of 10 830
  samples.** Finished meshes are applied essentially the frame they arrive.
- `vox_mesh` (meshing tasks in flight): p50 0, max 7. Meshing keeps up trivially (it is C++).
- This independently re-confirms the `COSMOS-MESH-PACING-DESIGN.md` finding (apply queue mean
  depth 0.01) — which was already quoted in `project.godot:85-87` *right next to* the comment
  calling the budget "the DOWNSTREAM choke". The queue-depth measurement was right; the "choke"
  framing was wrong.

### 1.5 The smoking gun: supply and main-thread health are coupled

Across 317 consecutive still-window pairs during drains: **correlation between instantaneous drain
rate and worst_ms = −0.47**. When drain is in its top quartile, worst_ms p50 = **29.9**; bottom
quartile, worst_ms p50 = **102.3**. Good frames ↔ fast generation; bad frames ↔ slow generation —
*in the same windows*. A one-way bottleneck (slow generator, slow uploads) does not produce this
signature; a **shared serializer** does. (Confound to keep in mind: block *mix* — expensive surface
blocks both generate slowly and produce heavier meshes. §5 E1/E2 discriminate.)

---

## 2. Pipeline anatomy (code-verified, with what CAN and CANNOT gate what)

The full path, from the patched module source in `docker/engine/cache/godot/modules/voxel/`:

```
VoxelTerrain._process (main)                                     [C++]
  └─ view-box diff → GenerateBlockTask enqueued (voxel pool)      — vox_gen += 1 at task ctor
GenerateBlockTask::run (worker N of 10)                          [generate_block_task.cpp:39-65]
  └─ run_cpu_generation → VoxelGeneratorScript::generate_block
       └─ GDVIRTUAL_CALL(_generate_block)  ← NO mutex, truly concurrent  [voxel_generator_script.cpp:23]
       └─ per call: wrapper VoxelBuffer create + copy_format + move_to   (heap + VoxelMemoryPool)
VoxelEngine::process (main, once per frame)                      [voxel_engine.cpp:288-315]
  ├─ dequeue_completed_tasks: apply_result + DELETE for EVERY completed task, UNBOUNDED
  │     — gen results land in the data map; vox_gen −= 1 at task dtor (so vox_gen = queued+running)
  ├─ _time_spread_task_runner.process(6 ms)  ← the ONLY thing the budget throttles
  └─ (ApplyMeshUpdateTask lives here: voxel_terrain.cpp:59-84)
VoxelTerrain (main): deps complete → MeshBlockTask (same pool)   [C++ mesher, fast, vox_mesh ≈ 0]
MeshBlockTask done → ApplyMeshUpdateTask pushed (time-spread)
apply_mesh_update (main): build_mesh() ON MAIN THREAD            [voxel_terrain.cpp:1901-1920]
  — GL compat: threaded graphics resource building = FALSE       [voxel_engine.cpp: auto_detect → GL_COMPATIBILITY → false]
  — ArrayMesh + surface upload + scene insert, one task = one whole 32³ block (budget can't split a task)
```

Consequences:

- **2.1** `vox_gen` counts tasks alive (constructor→destructor, `generate_block_task.cpp:29,35`);
  completed tasks are destroyed the same frame (`voxel_engine.cpp:299-303`), so a persistent
  backlog genuinely means *workers have not run those tasks yet*.
- **2.2** Gen-result application is **not** under the 6 ms budget; only mesh applies (and mesh-block
  frees) are. With `vox_main ≈ 0` the budget is idle machinery.
- **2.3** There is **no back-pressure path** from mesh-apply to the generation queue — no bounded
  queue anywhere between them. Apply cost can steal main-thread time (coupling §1.5) but cannot
  "hold" `vox_gen` at 44/s by queueing theory. The teammate's 45/s arithmetic was a coincidence.
- **2.4** Worker pool sizing: patch 0005 clamps web `hardware_concurrency` to 14
  (`patches/godot_voxel/0005`, verified applied), formula `clamp(round(0.7·hw), 3, max(hw−1,3))`
  (`voxel_engine.cpp:49-56`, `project.godot:71-73`). **Measured live (L1 shipped 2026-07-17 PM):
  `pool_threads = 6`** ⇒ the user's browser machine is a **laptop with hw ≈ 8** (NOT the 24-core
  dev host both analyses initially assumed; the analysis sessions in §1 were played from that
  laptop). `PTHREAD_POOL_SIZE=16` confirmed baked (`build/web/index.js`: `pthreadPoolSize=16`).
  Godot's own `get_processor_count()` = 2 on web (`library_godot_os.js:345-347`) — caps
  *WorkerThreadPool* at 2 but is irrelevant to the voxel pool, exactly as the team lead
  suspected. **The `module_world.gd:18-25` comment claiming a fixed 2-worker pin is STALE**
  (superseded by FP-M1b) and should be rewritten when next touched.
- **2.4a** L1 outcome (team-lead, instrumented live build): through an entire stationary drain,
  **`pool_active = 6 / pool_threads = 6`, every task name `GenerateBlock`, yielding ~40
  blocks/s** — the pool is fully *assigned* yet delivers ~1–1.5 workers' worth. Caveat (theirs,
  correct): `active_threads` means "has a task assigned"; a thread parked on a contended malloc
  lock inside its task also reports active — so this is *consistent with* the convoy but does not
  by itself distinguish burning-CPU from parked-on-futex. The same run reproduced the §1.1
  phys_ms signature from a different session: 4.3 → 44.5 ms for identical physics code purely
  because workers are busy. The mimalloc A/B (E5) is the discriminating fix-test.
- **2.5** The task runner itself is clean: per-iteration O(1) pop of the best task, priority resort
  every 200 ms, semaphore posted per enqueue (`threaded_task_runner.cpp:104-152, 169-330`). Not a
  suspect.

### 2.6 So why do 6 workers deliver ~1–1.5 workers' worth?

Native measured cost (GEN-EFFICIENCY §0, still valid): fully-underground block 13.7 ms *pre*-bulk;
with `FP_BULK_UNDERGROUND` ≈ 0.6 ms; surface-crossing blocks ~5–15 ms. WASM factor ~2–3× → mixed
per-block ~10–40 ms solo. **Six** truly-parallel workers (the measured pool, §2.4) ⇒ 150–600
blocks/s. Measured: 26–34/s sustained (40.8/s in the lead's clean drain), 167/s burst. The burst
proves ≥ some real concurrency exists; the sustained rate says that under load, per-block
*effective* cost inflates to ~150–240 worker-ms — a **~4–6× concurrency collapse**, not a slow
algorithm.

Two hypotheses survive contact with all the data; both are testable in one afternoon (§5):

- **H-A (primary): allocator convoy.** Emscripten's default dlmalloc has **one global lock**, and
  the official benchmark (web.dev "Scaling multithreaded WebAssembly applications") shows
  malloc-heavy workloads get *slower* as threads are added — threads convoy, and the main thread
  convoys with them. Our generator is exactly that workload: `column_profile` memoizes into a
  per-block `GenCtx.memo` **Dictionary** (`terrain_config.gd:558-582,659-670`) with ~256+ inserts
  per block, plus `slope_run_of`'s 9-neighbour `col_h` lookups, plus the per-call VoxelBuffer
  wrapper copy (`voxel_generator_script.cpp:14-29`) — call it 500–2000 heap ops per block, ×6
  workers, colliding with the main thread's thousands of GDScript Variant allocations per frame.
  One lock. This one mechanism explains *every* observation: the 10×-off throughput, the negative
  drain↔worst_ms correlation, the phys_ms inflation of unchanged code, and the fact that
  everything is fine when the pipeline is idle. Contended futex wakes on WASM cost ~ms-scale
  scheduling latency, which is how per-block cost inflates 10×.
- **H-B (secondary): effective parallelism is low for scheduling reasons** (workers starting late /
  parked / priority-inverted by the browser). Less likely — the pthread pool has 16 slots vs ~13
  demanded (10 voxel + 2 WTP + audio; the GPU task runner thread only starts on demand,
  `voxel_engine.cpp:125-126`, and never on GL) and Emscripten's non-strict pool queues rather than
  kills — but it is cheap to measure directly (§5 E1) and must be excluded before betting the
  engine rebuild.

A secondary suspect under H-A: **WASM shared-memory growth events** (`ALLOW_MEMORY_GROWTH` with
pthreads) stall all threads when the heap grows during heavy allocation phases — same signature,
mitigated by the same L2 fix (pre-sizing `INITIAL_MEMORY`).

### 2.7 And the walking hitch itself (worst_ms 65–120 while moving)?

Decomposition consistent with the data: (a) the shared-runtime convoy inflating *every* main-thread
millisecond (the dominant term — it inflates physics 4×, and by symmetry inflates process/render
work too); (b) unbounded gen-result receive bursts (`voxel_engine.cpp:299-303` applies *all*
completed tasks in one frame); (c) mesh applies — real but small at these rates (≈ 4–12 mesh
blocks/s ⇒ 1–3 per 250 ms window; a 32³ apply is a few ms of `build_mesh` + upload; note the far
ring commits a ~4.6 MB mesh in one frame without hanging, `COSMOS-PERF-NEXT-ARCHITECTURE.md` §0.4,
so per-apply upload size is *not* the 65 ms). The old "64³ hung the tab" result stays consistent:
that was 8× the quantum *plus* pathological many-buffer churn, and stays NO-GO.

### 2.8 Adjudication: the "render-step VBO upload stall" hypothesis (team-lead, 2026-07-17 PM)

After instrumenting `VoxelTerrain::_b_get_statistics` (vt_* ≈ 0.02–0.08 ms during 80–134 ms
frames) the team lead proposed: per-block GPU buffer creation/upload stalls the WebGL2/ANGLE
pipeline **during the render flush, outside the 6 ms budget and outside all stats**. Adjudication:

- **Mechanically half-right, one correction.** On gl_compatibility with single-threaded rendering
  (web), `ArrayMesh::add_surface_from_arrays` → `RS::mesh_add_surface` executes
  `glGenBuffers`/`glBufferData` **inline on the calling thread**
  (`drivers/gles3/storage/mesh_storage.cpp:219-276`) — i.e. **inside** `apply_mesh_update`,
  inside the ITimeSpreadTask, and therefore inside anything that times `apply_mesh_update`.
  It is *not* structurally invisible: a patch timing the apply captures the JS-side upload cost.
  (What *can* defer to the flush/swap is the browser-side cost — Chrome copies GL calls into the
  GPU-process command buffer and validation/translation can bite at flush — so a patch should
  time the apply AND count applies-per-window, and we should also look for worst-frames with
  ZERO applies in the window, which would acquit uploads entirely.)
- **Three observations weigh against uploads being the DOMINANT term:**
  1. The far ring commits a ~4.6 MB single-frame ArrayMesh without hanging
     (`COSMOS-PERF-NEXT-ARCHITECTURE.md` §0.4); a 32³ block surface is ~100–300 KB.
  2. The drain↔worst_ms correlation is **negative** (§1.5): the windows with the MOST applies
     have the BEST frames. Per-apply stalls predict the opposite sign (block-mix confound noted).
  3. ~~The load-average observation~~ **STRUCK (2026-07-17 PM):** the team lead's "host load
     1.96/24 during a drain" was measured on the *dev host* — the browser runs on the user's
     LAPTOP (hw ≈ 8, back-solved from the measured `pool_threads = 6`). That reading is void as
     evidence in either direction, and the per-thread census (old E0) is unrunnable from here.
     What replaces it: the L1 live measurement (§2.4a) — pool saturated at 6/6 on GenerateBlock
     while delivering ~40 blocks/s — which is consistent with the convoy but cannot alone
     distinguish burning-CPU from parked-on-futex. The mimalloc A/B carries that weight now.
- **And the upload hypothesis explains only one of the three joint facts.** It could explain
  127 ms frames; it cannot explain the 40.8 blocks/s worker-side ceiling (uploads don't gate
  `vox_gen` — §2.3's no-back-pressure argument cuts both ways), nor the phys_ms 4× inflation of
  unchanged code (§1.1). The serializer explains all three at once — which is exactly the "one
  joint puzzle, one explanation" test the team lead posed.
- **Verdict:** keep uploads as the *secondary* suspect inside the coupling story; spend the next
  measurement minutes on the serializer discriminators (E1/E2 + the free `ps -eLo pcpu` thread
  census below), and fold upload timing into the same single engine patch as the apply timer
  (§5 E5b) rather than betting a rebuild on uploads alone.
- **`proxy_to_pthread` note (researched, not recommended yet):** Godot 4.4's web platform has a
  `proxy_to_pthread` scons option (default off; off in our build — no `PROXY_TO_PTHREAD` in the
  shipped `index.js`). It would let the "main" thread `Atomics.wait` instead of busy-spinning,
  but proxies every GL call back to the browser thread — likely trading one pathology for
  another on a render-heavy app. Park unless E-census shows main-thread spin dominating.
- **Was `FP_BULK_UNDERGROUND` optimizing a non-bottleneck?** No — it removed real worker-side
  work (underground was ~76% of measured gen cost) and the ceiling today would be lower without
  it. But its end-to-end win was capped by the serializer, which is why its live effect
  undershot its microbench: right queue, right direction, wrong binding constraint.

### 2.9 E5 OUTCOME (2026-07-17 PM): mimalloc mostly did NOT move it — H-A demoted to a minor term

Provenance-verified A/B (BUILD-INFO `web_malloc: mimalloc`, 6 mimalloc symbol hits in the wasm),
identical metrics, team-lead run:

| metric (gen>200 unless noted) | dlmalloc | mimalloc | this doc's prediction | verdict |
|---|---|---|---|---|
| worst_ms p50 | 80.5 | 61.7 (−23%) | ~25 | MISS (partial move) |
| worst_ms p90 | 161.3 | 153.2 (−5%) | — | MISS |
| phys_ms p50 / p90 | 11.4 / 33.7 | 13.8 / 32.9 | → 8–12 | MISS (flat) |
| fps p50 | 34.6 | 33.9 | — | flat |
| stationary drain | 40.8/s | ~34.6/s (total-work/time; spawn conditions differed) | 3–10× | **MISS** |

**Honest verdict: the dlmalloc convoy is real but MINOR (−23% on worst p50 and nothing else).**
The primary-suspect framing of §2.6 H-A was wrong in magnitude. The hypothesis space is now:

- **(ii) genuine per-block web cost ~150–240 worker-ms — now LEADING.** Two multipliers this doc
  under-weighted: (a) the GDScript VM interpreter on WASM plausibly runs 5–10× slower than the
  native-editor GDScript the 2.9 µs/cell model was measured on (interpreter dispatch is WASM's
  worst case: indirect branches, bounds checks, no branch prediction), not the 2–3× compiled-C++
  factor I applied; (b) the laptop's hw≈8 is likely **4 physical cores + SMT** — 6 grinding
  workers + main + browser compositor oversubscribe physical cores, cutting per-worker speed
  ~1.5–2× AND explaining the phys_ms 3.2→11–34 inflation under BOTH allocators with no lock at
  all (main thread competing for physical cores is serialization-by-scheduler, allocator-independent).
- **(i-residual) a Godot-level serializer** (not libc malloc) — kept alive only by the fact that
  phys_ms inflation is exactly reproduced under mimalloc; but CPU oversubscription (above) is the
  simpler explanation and predicts the same signature.

**The decisive instrument (E9, no rebuild, ~4-min deploy):** time `_generate_block` ON the worker
in GDScript — `Time.get_ticks_usec()` at entry/exit, accumulate `gen_us_total` + `gen_blocks` on
the generator instance, surface via telemetry. Then read per-block wall-ms at N=6 vs N=3 (E2):

- per-block ≈ 150–240 ms at N=6 **and roughly unchanged at N=3** ⇒ **(ii) proven**, the cost is
  real VM work ⇒ L5(a) (C++ port of `resolve_cell`/`column_profile`/`slope_run_of`) becomes the
  MAIN event, with L3 as the cheap first bite;
- per-block **collapses at N=3** ⇒ contention proven ⇒ the lever is *worker-count-for-smoothness*
  (cap workers ≤ physical cores − 1 on small devices; see L4b) plus whatever E9's numbers point at.

Also predicted by the oversubscription model, checkable in the same E2 run: at N=3, **main-thread
worst_ms/phys_ms should IMPROVE** even if drain drops — on 4-physical-core devices, worker count
should be tuned for main-thread smoothness, not throughput (drain 34→25/s is invisible; worst_ms
80→40 is the whole user experience).

**L4b (new plan item): device-aware worker cap.** `ratio_over_max=0.7` on hw=8 yields 6 workers —
likely past the smoothness optimum on SMT laptops. If E2 shows worst_ms improving at N=3 with
tolerable drain, ship a lower web ratio (e.g. 0.4, floor 3) — one project-setting line, reversible,
memory-neutral, and it directly buys the walking-smoothness the user asked for.

**NEVER-OOM instrument gap (blocking L2 regardless of merit):** both heap probes failed on the
release web export (`heap_mb`: the Emscripten Module lives in a closure, invisible to
`JavaScriptBridge.eval`; `MEMORY_STATIC`: `#ifdef DEBUG_ENABLED`, reports 0 in release). Two fixes:
(1) **today, no rebuild**: `performance.measureUserAgentSpecificMemory()` — Chrome-only but
requires exactly the crossOriginIsolated we already guarantee (COOP/COEP); async, so eval a
snippet that stashes the result on a `window.__voxHeap` global and let the next telemetry tick
read it; (2) **next engine-patch batch**: one line in the godot_voxel stats patch adding
`mem["wasm_heap"] = emscripten_get_heap_size()` under `__EMSCRIPTEN__` to `get_stats()` — rides
the dict telemetry already polls. Until one of these lands, every memory-costly bet (mimalloc
included) is unshippable under the locked rule — so (1) should land with E9.

---

## 3. Explicit verdicts on the framings in circulation

| Framing | Verdict | Evidence |
|---|---|---|
| "6 ms mesh-apply budget is the downstream choke; ~45 blocks/s apply ceiling explains 44/s drain" (`project.godot:74-91`; team-lead hypothesis) | **Refuted as the governor.** The budgeted queue is empty (`vox_main` ≈ 0, §1.4); gen-result apply is unbounded and outside the budget; no back-pressure path exists (§2.3). The 45≈44 match is coincidence. The *direction* (main-thread apply path matters) survives as part of the coupling story. | §1.4, §2.2–2.3 |
| "2 web workers can't drain the queue" (`COSMOS-GEN-EFFICIENCY-DESIGN.md` §0, `COSMOS-CROSSING-FASTGEN-DESIGN.md`, `module_world.gd:18-25`) | **Stale/wrong on ≥8-core clients.** FP-M1b shipped scaled workers (6 on the user's laptop, up to 10 on big machines); throughput did not scale accordingly. Worker *count* was never the binding constraint on this hardware — the serializer was. (On 2–4-core devices count still matters.) | §2.4, §2.6 |
| "Generation is algorithmically too slow" | **Wrong as stated.** The algorithm is ~10–40 ms/block solo on web — fine. It is the *concurrent* execution environment that collapses. (A C++ port still helps — fewer allocations, fewer VM ops — but it is L5, not L1.) | §2.6 |
| "Walking cost = movement/physics/collider" | **Refuted.** Moving with an idle pipeline = standing (§1.1). | §1.1 |
| "Mesh-lag see-through is gen-bound" (obs-2/3 docs) | **Stands.** Demand 90–100/s vs supply 26–34/s (§1.2–1.3). | §1.2–1.3 |
| "Draw calls / vsync ladder is the walking ceiling" (pre-atlas analysis) | **Solved and stays solved** — standing is 58–60 fps at 62–195 draws. Not the walking delta. | ground truth |

---

## 4. Ranked plan

Ordering: cheapest-decisive-measurement first, then the fixes in expected-leverage order. Each item
tags its class — **[removes work]**, **[adds throughput]**, **[reshuffles]** — only the first two
raise a ceiling.

### L1 — Telemetry: expose pool health + heap counters *(measure; 10-line edit + 4-min deploy)*

Add to `remote_bridge.gd::_send_telemetry` (`src/net/remote_bridge.gd:437-467`) from the already-
fetched `get_stats()` dict: `thread_pools.general.thread_count`, `.active_threads` (and one sampled
`task_names` string), plus `memory_pools.std_current`. Zero cost (the dict is already built,
`voxel_engine_gd.cpp:110-131`). **Decision value:** during a stationary drain, `active_threads ≈ 10`
⇒ workers run-but-crawl ⇒ **H-A confirmed**; `active_threads ≤ 3` ⇒ **H-B**, investigate pool/
scheduling before any rebuild. NEVER-OOM: n/a (telemetry only). Flag: none needed (additive fields).

### L2 — Engine rebuild with `-sMALLOC=mimalloc` (+ sized `INITIAL_MEMORY`) *(adds throughput — the big bet)*

Mechanism: replace the single-lock dlmalloc with mimalloc's per-thread heaps. Emscripten ≥3.1.50
supports it; we pin 3.1.64 — available. The official benchmark shows dlmalloc *anti-scaling* with
threads and mimalloc restoring linear scaling plus ~1.8× single-thread. Implementation is the
patch-0001 pattern: a `docker/engine/patches/godot/0002-web-malloc-option.patch` adding a scons
option that appends `-sMALLOC=mimalloc` to web LINKFLAGS (`platform/web/detect.py`), wired from
`versions.env` (`WEB_MALLOC=mimalloc`, revert knob = `dlmalloc`). ~24-min rebuild + export + deploy.

- **Expected effect (numbers to beat):** sustained stationary drain 26–34/s → **3–10×** (if H-A);
  `still&gen>200` worst_ms p50 43.8 → **≈ 25–30**; walking worst_ms p50 65.8 → **≈ 25–40**; phys_ms
  while moving 31 → **≈ 8–12**. If it moves *none* of these, H-A is dead — revert (one env var).
- **Cost/risk:** LOW effort, MEDIUM risk. mimalloc reserves per-thread segments → higher baseline
  WASM heap. **NEVER-OOM ledger:** this is a memory-costly upgrade ⇒ ship as a *deploy-time A/B*
  (two builds), measure peak WASM heap with the `COSMOS-FP-M2-HEAP-AB.md` harness before making it
  the default; explicit ceiling: reject if baseline heap grows > +64 MB or peak exceeds the
  established cap. Same rebuild should set `INITIAL_MEMORY` ≈ measured peak (kills growth-event
  stalls; also a ledgered, measured choice).
- **Kill metric:** stationary-drain blocks/s and `still&gen>200` worst_ms p50, same spawn, same
  route, before/after.

### L3 — Allocation diet in the generator hot path *(removes work; helps regardless of L2)*

Mechanism: eliminate the per-block Dictionary memo traffic. `_generate_block` already builds a flat
`profs[]` per block (`module_world.gd:2812-2864`); the `GenCtx.memo` Dictionary
(`terrain_config.gd:659-670`) mainly serves `slope_run_of`'s 9-neighbour `col_h` re-lookups that
straddle block edges — replaceable by an 18×18 flat `PackedFloat64Array`/`PackedInt64Array` window
per block, byte-identical values, ~zero heap ops after warm-up. Optionally: an engine-patch
follow-up letting `VoxelGeneratorScript` reuse a per-thread wrapper buffer instead of
create+copy+move per call (`voxel_generator_script.cpp:14-29`).

- Flag: `FP_GEN_ALLOC_DIET` (const, default OFF, OFF = byte-identical; FLAT verify 6056/0 must hold).
- **Expected effect:** cuts worker heap-op rate ~10×. Under dlmalloc this attacks the convoy
  directly (maybe half the L2 win without a rebuild); under mimalloc it is still a straight CPU cut.
- Cost: S–M (GDScript only). NEVER-OOM: neutral (replaces a dict with a fixed array). Kill metric:
  stationary drain rate.

### L4 — Demand accounting, then trim *(removes work; measure first)*

§1.3 found gross walking demand ~90–100 blocks/s where the bare viewer ellipsoid explains only
15–20. Instrument one walk with per-terrain breakdown (which terrain/slot the queued tasks belong
to — cheap: log `view_f` targets + `vox_gen` against slot events), then trim the biggest
contributor (likely neighbour-pool ramp volume or vel-predict lead distance). Flag per trim, e.g.
`FP_DEMAND_TRIM`. **Expected effect:** demand −30–50% ⇒ backlog stops growing at walking speed even
pre-L2. Risk: pop-in at ridges if over-trimmed — judge on the see-through screenshots, not vibes.
NEVER-OOM: strictly reduces live volume.

### L5 — Port the worldgen inner loop to C++ (module patch) or VoxelGeneratorGraph *(adds throughput; big)*

Only if L2+L3 leave supply < demand. Two shapes: (a) port `resolve_cell` + `column_profile` +
`slope_run_of` into a C++ helper inside our existing godot_voxel patch set (patches 0001–0005 prove
the toolchain), keeping GDScript orchestration and the frozen-table contract; (b) rebuild worldgen
as a `VoxelGeneratorGraph` (upstream-sanctioned, "similar speed to C++", buffer-based with range
analysis — but expressing the faceted fold/junction/snow/liquid pipeline in graph nodes is a poor
fit). Recommendation if triggered: **(a)**. Expected 10–30× worker-side; L–XL effort; the verify
gates (`verify_feature`, G-M2-ID equality gates) are the safety net. NEVER-OOM: neutral.

### L6 — Apply-quantum work: `mesh_block_size` 32→16 A/B; paced sub-uploads *(reshuffles; conditional)*

Park unless post-L2 data shows mesh applies still spike frames. 16³ meshes = 8× smaller apply
quantum at up to 4–8× the draw calls (the atlas has since collapsed the per-draw material cost, so
the old 204-draw wall may not return — but that is exactly what the A/B measures). One-line sed
(`module_world.gd:363`) + deploy. Judge on walking worst_ms p50 vs draws. The Sodium prior art
(§6) says the *scheduling* pattern (upload-duration estimate + defer) is the porteable half; a
budget-aware apply-deferral patch in `apply_mesh_update` is the follow-up if 16³ regresses draws.

### L7 — `?scale3d=` resolution cap (N4, user decision) *(removes work — fill)*

Unchanged from `COSMOS-PERF-NEXT-ARCHITECTURE.md` §1.2: 3D renders at window×devicePixelRatio;
a cap buys headroom for everything at a look cost. Orthogonal to this doc's root cause; do the
A/B when the user wants the knob. Not the walking fix (standing is already 60 fps at full fill).

### Explicitly NOT doing (and why)

- **More workers / higher `ratio_over_max`** — adds contenders to the convoy; the data says count
  is not binding. [reshuffles, likely negative]
- **Budget tuning as a fix** (4↔6↔12 ms) — governor refuted (§1.4); keep 6 for fill rate.
- **64³ mesh blocks** — NO-GO stands (tab hang, `COSMOS-64MESH` history).
- **256-voxel near radius, mesh/collision caching, 2D-noise-for-speed** — all previously measured
  dead ends; nothing here changes those verdicts.
- **VoxelLodTerrain / Transvoxel / clipmaps** — no blocky LOD through godot_voxel 1.6; design-lock
  violation (`COSMOS-PERF-NEXT-ARCHITECTURE.md` §3).
- **WebGPU/Forward+** — renderer-gated through Godot 4.7, no committed timeline; unschedulable.
  What it would buy *when real*: threaded graphics resource building (the GL-compat `false` branch,
  §2) and a modern upload path — i.e. it dissolves L6 but does not by itself fix H-A.
- **Teardown-style raymarching, OffscreenCanvas worker-GL, persistent-mapped buffers** — see §6:
  respectively wrong hardware class, impossible while Godot owns the context, absent from WebGL2.

---

## 5. Experiments to run TODAY (decision table)

All doable with the live remote-drive loop + sed-and-redeploy (~4 min each) except E5 (24-min
rebuild). Run in this order; each is phrased as *signal ⇒ verdict*.

- **E0 — VOID (2026-07-17 PM).** The browser runs on the user's laptop (hw ≈ 8), not the dev
  host; no shell there, so the per-thread CPU census cannot be run from here. If the user is ever
  willing to run one command during a drain, `ps -eLo pid,tid,pcpu,comm --sort=-pcpu | head -40`
  on the browser PID still cleanly separates burning-CPU (per-block cost real → generator port)
  from parked-on-futex (convoy) — but the plan no longer depends on it.
- **E1 — DONE (2026-07-17 PM, team lead).** Result: `pool_threads = 6`, `pool_active = 6`
  saturated on GenerateBlock through the whole drain at ~40 blocks/s (§2.4a). H-B (few/parked
  threads at the *scheduler* level) is dead; what remains is burning-CPU vs futex-parked *inside*
  the tasks — which E5 (mimalloc) discriminates as a fix-test.
- **E2 (8 min): worker-count A/B.** Sed `project.godot` `threads/count/ratio_over_max` 0.7 → 0.15
  (⇒ 3 workers), re-export, redeploy; same spawn-drain measurement.
  Drain ~unchanged at 3 workers ⇒ serializer confirmed (count irrelevant) — and if worst_ms
  *improves* with fewer workers, the convoy is proven with extra colour. Drain ∝ workers ⇒ H-A
  weakened, per-block cost is real ⇒ prioritize L3/L5 over L2.
- **E3 (8 min): apply-budget falsification.** Sed `threads/main/time_budget_ms` 6→2, then 6→12.
  **Prediction under this doc's model: no material change** in either drain rate or walking
  worst_ms p50 (queue is empty; budget throttles nothing that matters). Any large change refutes
  §2.2 and revives the apply-bound framing — cheap insurance either way.
- **E4 (free): re-read this morning's data** for the `still&gen>200` worst-floor after any change —
  it is the cleanest "streaming activity janks the main thread" scalar; use it as the standard
  before/after metric alongside walking p50.
- **E5b (24 min, combine with E5 or run first if E0/E1 are ambiguous): one engine patch that
  times the apply.** In `apply_mesh_update` (`voxel_terrain.cpp:1873`) accumulate per-frame
  `apply_ms` + `applies_count`, expose via `_b_get_statistics`. Decision: worst-frames with
  `applies_count = 0` in their window acquit uploads; `apply_ms` ≈ worst_ms convicts them.
  This is the ONLY measurement that directly rules the §2.8 upload hypothesis in or out —
  rank it above E5 if E0's census shows many busy worker threads (i.e., convoy weakened).
- **E5 (24 min + deploy): the mimalloc build (L2).** Metrics: stationary drain blocks/s (expect
  ≥2× if H-A; hope 3–10×), `still&gen>200` worst p50 (expect → ~25), walking worst p50 (expect
  → 25–40), phys_ms while moving (expect → ~8), peak WASM heap (NEVER-OOM gate; reject > +64 MB).
- **E6 (10 min): circle-walk control (E7 in text).** Fly/walk a closed loop inside generated
  terrain for ≥60 s: confirms the n=15 "movement is free" cell with real sample size. If worst_ms
  rises with gen idle, something movement-linked survives (collider, far-ring) — would partially
  revive a lane this doc closed.
- **E7 (10 min): demand instrumentation walk (L4).** One straight-line walk with per-slot view
  targets logged; attribute the 90–100/s demand.

**Comparability rule:** every drain measurement = fresh reload → stand at spawn → measure
`d(vox_gen)/dt` over the first 60 s. Every walking measurement = same heading, same duration,
no user input (the morning walking sample was contaminated — n=74 windows only).

---

## 6. SOTA / prior-art survey (what ports, what doesn't)

Full-source survey run 2026-07-17 (WebSearch, primary sources). Condensed; verdicts are for
**Godot 4.4 + WebGL2/ANGLE + 16-slot pthread WASM** specifically.

| Source | What they do | Ports here? |
|---|---|---|
| **Minecraft Java + Sodium** | Meshing on workers since 1.8; upload on render thread is the acknowledged stutter source. Sodium: 8×4×8-section render regions sharing one buffer arena, multidraw batches, persistent-mapped staging buffers, and — key — **upload-duration estimators + per-frame upload budgets + distance-based deferral**. Sodium does *not* greedy-mesh. | Persistent mapping & multidraw **don't exist in WebGL2**. The **budgeted/estimated/deferred upload scheduler** pattern ports (L6 follow-up). Regions/arenas port in principle (big engine work). |
| **Distant Horizons** | LODs as persisted, aggregated, untextured colored-quad columns in a separate cheap render path (sqlite-backed). | Validates the FacetFarRing/underlay direction already shipped. Nothing new to take. |
| **Veloren** | Greedy meshing variants on a worker pool (wgpu); deferred atlas writes via continuations. No public chunks/s numbers. | Greedy-on-workers fine; **off-thread GPU buffer creation is wgpu-only** — that half cannot port to GL compat. |
| **No Man's Sky (GDC 2017)** | Generation decomposed into small resumable prioritized tasks under strict per-frame budgets; coarser LOD rings; deterministic-from-seed. | Architecture-level validation of what VOXIVERSE already does (controller, rings, determinism). |
| **Teardown** | Fully raymarched voxel volumes, no world triangles. | Doesn't port: needs volume raymarching horsepower + engine bypass; wrong hardware class for WebGL2. |
| **Binary greedy meshing** (cgerikj; 0fps) | 64³ meshed in 50–200 µs; quads at 8 bytes via vertex pulling. **Honest merge numbers: noise terrain only ~1.3×, sphere 2.3×, flat panels 10–30×.** The reliable win is **vertex format packing (4–8×)**, not merging, on natural terrain. | Partially: our faceted flats + bulk-stone underside are the *good* case for greedy, but it means a custom mesher + shader (Texture2DArray is core WebGL2). Park behind L5/L6 outcomes; sell as "packed vertices ≥ greedy". |
| **WebGL2 upload best practice (MDN, khronos)** | No persistent mapping, no real async upload. Chrome revalidates + double-copies every call through the GPU-process command buffer; ≥ms stalls documented, `bufferSubData` pauses up to 100 ms reported. Mitigations: pre-allocated pooled buffers, byte budgets sliced across frames, avoid RGB8. **OffscreenCanvas worker-GL: impossible while Godot owns the context.** | Sets the ceiling for L6: slice + pool + fewer bytes is all there is. |
| **Emscripten threading (web.dev, emscripten docs)** | **dlmalloc = one global lock; malloc-heavy code anti-scales with cores (measured); mimalloc restores scaling + ~1.8× single-thread; `-sMALLOC=mimalloc` since 3.1.50.** Main thread cannot `Atomics.wait` → contended locks *busy-wait* on the main thread, burning rAF budget — the exact §1.5 coupling signature. | **Directly — this is L2**, and it retroactively explains why FP-M1b (2→6/10 workers) bought so little. |
| **godot_voxel upstream** | Docs: GDScript generators "not scalable — prototyping only"; `VoxelGeneratorGraph` ≈ C++ speed (range analysis, 16×16-slice buffers); graphics resource building threadable on RD renderers only (never GL); `mesh_block_size` 32 = fewer-but-bigger uploads, 16 = smaller-but-more (worst-frame-bound targets arguably want 16 — L6). Web officially unsupported territory; greedy meshing declined upstream (#814). | The generator-language verdict feeds L5; the 16³ inversion feeds L6. |
| **Browser voxel engines (noa-engine → classic.minecraft.net; skishore/wave)** | wave: WASM, RLE columns + "equi-levels" (5–10× meshing speedup), WebGL2 texture arrays (1 draw call), shader-side quad decompression (~5× geometry bytes), heightmap far-LOD — smooth on an old MacBook. | Existence proof that the browser is not the ceiling — a lean pipeline hits 60 fps with headroom in WebGL2. Their tricks map to L3/L6/greedy lane. |
| **Godot 4.5/4.6 changelogs** | 4.5: general web perf from a compiler-flag change; export-time shader precompile. 4.6: Vulkan-side only. Nothing threads GL-compat mesh building. | Mild extra credit toward the already-planned post-FP-M2 4.6 migration; no reason to accelerate it for THIS problem. |

**Cross-cutting lesson:** every successful streamer (Sodium, NMS, wave) treats *upload and
generation as budgeted, prioritized, resumable work with hard per-frame byte/time budgets* — the
architecture VOXIVERSE already has — and none of them run 10 allocation-heavy script threads over
a single-lock allocator. The gap is the runtime, not the design.

---

## 7. Architecture verdict

**No architecture change.** The faceted planet + fixed-LOD pool + far-ring + analytic physics stack
is not implicated by any measurement in this doc — the same measurements *exonerate* movement,
draw calls, physics, meshing, and the apply queue. What is broken is (a) the WASM runtime's
allocator under our thread pattern — an engine *build* fix (L2), (b) allocation pressure in one
GDScript hot loop — a targeted code fix (L3), and (c) a demand budget nobody has itemized yet (L4).
The heavyweight options (generator port L5, mesher/upload work L6, greedy lane) stay on the shelf
until E1–E5 say they are needed. I recommend committing to: **E1→E2→E3 today, L2 build tomorrow,
L3 behind a flag this week; decide L4/L5 from the post-L2 numbers.** Estimated cost to the probable
end state (walking p50 ≤ ~30 ms, supply ≥ demand at walking speed): one engine rebuild + ~2 days of
flag-gated GDScript work + the measurement discipline above.

---

## 8. Risk register

| Risk | Exposure | Mitigation |
|---|---|---|
| mimalloc heap overhead violates NEVER-OOM | Baseline +MBs per thread heap; INITIAL_MEMORY pre-commit | Ship as build-level A/B; measure peak with the HEAP-AB harness; explicit reject ceiling (+64 MB baseline); revert = one env var (`WEB_MALLOC=dlmalloc`) |
| mimalloc-on-Emscripten maturity (3.1.64) | Allocator swap on a threaded WASM app | Headless native unaffected (patch is web-linkflags only); full verify + a 30-min web soak before making it default |
| H-B turns out true (low effective parallelism) | L2 buys little | E1/E2 run *first* and cost 12 minutes; if H-B, pivot to pool/scheduling forensics before any rebuild |
| Block-mix confound in drain metrics | Mis-attributed wins | Fixed spawn-drain protocol (§5 comparability rule); compare like windows only |
| E2's 3-worker A/B regresses low-core visitors if left deployed | Weak-device experience | It is an experiment, not a ship config; restore 0.7 after measurement |
| L3 memo removal breaks byte-identity | verify gate failure | `FP_GEN_ALLOC_DIET` const-flag OFF default; FLAT 6056/0 + G-M2-ID equality gates must stay green |
| Walking demand trim (L4) reintroduces ridge pop-in | Visual regression at crossings | Judge on commanded screenshots at ridge approach; committed-imminent slot keeps `CTRL_IMMINENT_COMMIT_PACE` |
| Stale docs keep steering work at ghosts | Repeated mis-framing | §3 table is the correction of record: fix `module_world.gd:18-25` and the `project.godot:74-91` "downstream choke" comment when those files are next touched |

### Known-wrong list (for the record, per the project's own tradition)

1. "2-worker web generation ceiling" — superseded (§3); months of framing, including in shipped
   comments and two design docs, attributed to worker count what belongs to runtime serialization.
2. `project.godot` budget comment ("the DOWNSTREAM choke") — the queue it throttles is empty.
3. The 833 blocks/s theoretical — assumed linear thread scaling on a runtime that measurably
   anti-scales; the correct theoretical under dlmalloc convoy is ~1–1.5 threads' worth, which is
   what we observe.
4. This doc's own weakest link, stated openly: H-A vs H-B is *inferred*, not yet directly observed
   — E1/E2 exist precisely to close that gap before the L2 bet, and the negative correlation of
   §1.5 has a residual block-mix confound that only the A/Bs fully remove.
