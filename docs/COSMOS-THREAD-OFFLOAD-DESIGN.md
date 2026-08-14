# COSMOS THREAD-OFFLOAD — can anything move off the primary game thread?

**Status: DESIGN (research only — nothing here is implemented).**
Author: Fable (thread-offload architect). Question from the project owner: *"Can we offload
anything to secondary threads from the primary game thread?"*

**Executive answer: offloading is genuinely viable on this hardware — and mostly it
already IS offloaded.** The reference host has **~8 logical cores** (telemetry `cores=8`
= `navigator.hardwareConcurrency`; the `os_cores=2` key is `OS.get_processor_count()`,
which is KNOWN to under-report on the web export — root-caused and fixed in commit
622a5c5, `facet_tex_baker.gd:202-207`). The main thread is the bottleneck and there ARE
free cores. Eight subsystems already run their compute on workers (§2). Of the ~19.4 ms
measured static main-thread floor (docs/COSMOS-FOREST-FPS-DESIGN.md §3), what remains on
main is (a) work that should not run at all when the player is stationary (the idle-diet
class — fix by not running it, not by moving it), (b) RenderingServer / physics-server
applies that are main-thread-only by engine API, (c) **one genuine, high-value offload
candidate**: the FacetFarTrees instance-set rebuild walk (~50–70 ms per fire) —
`FP_FAR_TREES_WORKER`, §6 — and (d) **a real sizing bug this audit found**: two shipped
worker pools size themselves off the under-reporting `OS.get_processor_count()` and run
with **1 worker slot on web** despite 8 true cores — `FP_TRUE_CORES`, §6bis.

---

## 1. Ground rules — what Godot 4.4 threaded-web permits

The export is threaded (SharedArrayBuffer + COOP/COEP); the Emscripten pthread pool is
FIXED and pre-allocated (engine patch 0001; over-requesting errors "thread pool is
exhausted" — `godot/project.godot:56-58`).

| Allowed off-main | Forbidden off-main (main-thread-only) |
|---|---|
| Pure GDScript/C++ compute over PackedArrays, math, Dictionaries the worker owns single-writer | `RenderingServer` in any form: `MultiMesh.set_buffer`, `ArrayMesh.add_surface_from_arrays`, material/uniform sets, `update_layer` |
| Read-only access to frozen statics (`FacetAtlas` tables, a frozen `VoxelGeneratorCosmos` under RWLockRead — patches 0011/0012) | SceneTree / Node property writes (`add_child`, `visible`, transforms) |
| `WorkerThreadPool.add_task` (web pool = 5, 4 low-prio — `project.godot:131-132`), `Thread.new()` (one live: EnvSimWorker) | PhysicsServer bodies/shapes (GroundCollider, VoxelBody) |
| | Live game state another thread mutates (`WorldManager._edits`, `_cache` dicts) unless snapshotted at dispatch |

**The pattern is fixed by two hard-won laws:**
1. **COMPUTE off-thread → bounded APPLY on main** — and *measure the apply*: the C++
   worldgen port inverted the bottleneck to the main-thread apply stage (memory
   `voxiverse-postport-applybound`; `threads/main/time_budget_ms=6`, `project.godot:121`).
2. **Allocation-flat workers** — the WASM dlmalloc is ONE shared lock; workers that churn
   allocations convoy against the voxel gen pool and the main thread (memory
   `voxiverse-walk-perf-root-cause`: 7 workers measured SLOWER than 1 on this host).
   Workers write into preallocated buffers the submitter owns.

The in-repo mechanism is **JobLane** (`godot/src/world/job_lane.gd`, FP_JOB_LANE): zero
new threads, ≤2 WTP slots, priority-drained, 2 ms/6-commit main-thread drain budget,
pooled Job bookkeeping. **Every new offload in this design rides it** — no parallel
mechanism is invented.

---

## 2. What is ALREADY off-main — the thread ledger (class C: done)

This is the part of the answer most worth stating plainly: the engine has been through
five threading campaigns and the compute-heavy tail is gone from main.

| Subsystem | Compute (worker) | Main-thread apply | Where |
|---|---|---|---|
| godot_voxel gen+mesh | own C++ pool, ≥3 workers (`project.godot:101-103`), telemetry `pool_threads=6` | mesh upload under 6 ms budget (`project.godot:121`) | engine |
| FacetSmoothV2 tile builds | `_build_worker` per-tile on WTP | tile lands in `_tiles` | `facet_smooth_v2.gd:584-589` |
| FacetSmoothV2 merge (FP_SMOOTH_V2_ASYNC_MERGE) | `_merge_worker` ~630k-index concat on snapshot | `_build_and_swap` GPU upload only (185→14.5 ms, PR #43) | `facet_smooth_v2.gd:625-629`, `:606-618` |
| FacetOrbitRelief (G3) | `_build_worker` DEM-displaced tiles | slot-arena commit ~8 ms paced | `facet_orbit_relief.gd:684,706` |
| FacetFarRing full rebuild / env warm | `_async_build_worker` | swap_ms on main (event-logged `build_ms`/`swap_ms`) | `facet_far_ring.gd:1975,2003,2082` |
| FacetTexBaker band/fine bakes | `_pbm_compute` WTP fan + JobLane units; `WEB_BAKE_WORKERS=1` convoy-tuned | budget-sliced `update_layer` (5 ms, overrunnable) | `facet_tex_baker.gd:1860,1916,639` |
| Block-LOD ladder/ring/orbit/global bakes | JobLane `PRIORITY_BLOCK_LOD` | ArrayMesh + add_child commit | `facet_block_lod_ring.gd:255`, `_ladder.gd:87`, `_orbit.gd:233`, `_global.gd:186` |
| WeatherSystem (FP_WEATHER_THREAD) | dedicated thread, double-buffer, quiesced swap | `poll()` = one bool + pointer flip | `env_sim_worker.gd`, `weather_system.gd:325` |
| FacetFarTrees **enumeration** | `_enum_worker` one facet/job on WTP | LRU insert | `facet_far_trees.gd:540-596` |

**A real sizing bug found during this audit:** `FacetSmoothV2.setup_instance` sizes its
worker slots from `OS.get_processor_count() - 1` (`facet_smooth_v2.gd:425`) — but Godot's
web build **under-reports** (returned 2 on this 8-core host; that is exactly why commit
622a5c5 made `facet_tex_baker.gd:202-207` read `navigator.hardwareConcurrency` via
JavaScriptBridge instead). So smooth-v2 runs with **_sn = 1 worker slot on web** despite
8 true cores, and `facet_orbit_relief.gd:511` sizes the same way — both serialize their
tile warm-ups onto a single worker for no reason. This is now a fix candidate:
**`FP_TRUE_CORES`, §6bis** — route every GDScript worker-pool sizing through the ONE
true-core reader, with explicit headroom reserved for the voxel mesher pool. A related
open verification: telemetry `pool_threads=6` is consistent with the *engine-side* voxel
pool seeing 8 cores (`clamp(round(0.7·8), 3, 7) = 6`, `project.godot:101-103`) while
GDScript's `OS.get_processor_count()` returns 2 in the same runtime — dump both live
(§6bis gate) rather than assuming which sites are mis-sized.

---

## 3. What REMAINS on the main thread — inventory, ranked, classified

Classes: **(A)** offloadable pure-compute with a cheap main apply · **(B)** main-thread-
bound (RenderingServer/SceneTree/physics — cannot move; defer/throttle/idle-guard instead)
· **(C)** already-threaded (§2). Costs from the task-#119 telemetry capture
(docs/COSMOS-FOREST-FPS-DESIGN.md) unless marked *est*.

| # | Item | Where | Cost | Class | Verdict |
|---|---|---|---|---|---|
| 1 | **FacetFarTrees rebuild walk** (cards + meshes: 40–75k records ×2, fades, `_is_chopped` Callable+Vector3i alloc per in-band record, ~0.76 MB buffer realloc) | `facet_far_trees.gd:697-754` (cards), `:786-850` (meshes), fired from `step()` `:506-509` | **~50–70 ms per fire** (the measured Δ≈57.6 ms). Post-`FP_FAR_TREES_DELTA` (`:502`, shipped in this tree): fires only on camera motion ≥2 blk / cache epoch / edit rev — i.e. the whole cost moves to *walking* | **A — THE candidate** | **P1 `FP_FAR_TREES_WORKER`** (§6). Apply = 7× `MultiMesh.set_buffer` + visible counts ≈ 1–2 ms |
| 2 | `update_streaming` full tail at 60 Hz with no stationary guard: `_skin_candidate_fids()` alloc (`world_manager.gd:3368`), per-tick Callable constructions (`:1218-1245`), 4× block-LOD `place` (`:1260-1269`), tex-baker slice (`:1295`), DEM admission (`:1338`), pool manage (`:1346`) | `player.gd:822` → `world_manager.gd:1159-1364` | ~8.4 ms/frame (phys_ms fast-window p50; ~1.4 ticks/frame) | **B — idle-guard, NOT offload** | **P0 `FP_STREAM_IDLE_DIET`** (forest-fps §4.7). The tail is orchestration + engine calls; offloading orchestration is a category error — *don't run it* when nothing changed |
| 3 | Render submit + GPU + browser compositor (709k prims incl. the 489k-vert FULL_COVER backstop) + uninstrumented scripts | residual | ~14 ms | **B** | Not a threading problem at all — gl_compat submits on main by design. The lever is the §6.3 forest-fps floor probes → backstop vertex diet. Out of scope here |
| 4 | FacetSmoothV2 commit apply `_build_and_swap` | `facet_smooth_v2.gd:606-618` | ~14.5 ms per commit, rate-capped ≥500 ms apart (`SMOOTH_V2_COMMIT_MS`, `cube_sphere.gd:976`) | **B** (RenderingServer upload) — compute already C | Done. The latched `smooth_v2_commit_ms 21.3` in telemetry is a stale last-commit value, not a per-frame cost (forest-fps §2.4) |
| 5 | Env convergence `_surface_converge_emit` | `facet_far_ring.gd:1466`, telemetry `env_converge_ms` `:3143` | measured **0.02 ms** in the forest capture (0–16 only during warm bursts, which already ride `_async_build_worker` warm-only, `:2003`) | **C** | Exonerated. No action |
| 6 | GlobalReliefData DEM step | `world_manager.gd:1338` → `global_relief_data.gd` (main by class design, `:39-41`) | 0 when idle post-`FP_DEM_DEFER` (shipped); 20–60 ms/admitted step only inside bake windows | **A, designed** | `FP_DEM_ASYNC` already fully specified in docs/COSMOS-STREAM-PARALLEL-DESIGN.md §4.2, never implemented. Keep as P2 backlog — DEFER removed its player-visible cost |
| 7 | StreamLoadController | `stream_load_controller.gd:132-141` | 0.02–0.4 ms | B | Leave. It's the governor — it must see the frame it governs |
| 8 | DDA raycast, `_collapse_unsupported` flood-fill, GroundCollider re-centre, VoxelBody | `world_manager.gd`, `physics/ground_collider.gd` | event-driven (break/place); chop-lag already fixed (task #96, per-fid edit index) | **B** (physics server + must read live `_edits` synchronously — a break must be authoritative *this tick*) | Not worth: correctness demands sync reads; costs are event spikes already bounded |
| 9 | Snow / ctrl / vt / weather-poll instrumented scripts | telemetry | ≈0.02–0.4 ms each | C/B | Leave (SnowfallSystem already off hot path, R2 task #55; weather already threaded) |

**The honest headline:** after `FP_FAR_TREES_DELTA` lands, the stationary-forest main
thread contains **zero offloadable compute of consequence**. The remaining stationary
budget is #2 (idle diet) + #3 (render). Offload only helps the *moving* camera (item #1)
and background bake windows (item #6).

---

## 4. The honest core model (~8 logical cores) — what offload buys, and the real caveats

Ground truth (corrected): the reference host has **~8 logical cores**. Telemetry
`cores=8` is `navigator.hardwareConcurrency` (the TRUE count, commit 622a5c5);
`os_cores=2` is `OS.get_processor_count()`, which **under-reports on the web export** —
it is a broken sensor, not a hardware fact. The typical desktop-browser user (the
non-negotiable demo audience) has 4–8 logical cores. **The main thread is the
bottleneck and there ARE free cores — offloading is genuinely viable here.** Four honest
caveats survive the correction:

1. **Logical ≠ physical: hyperthreads.** `hardwareConcurrency` counts HT siblings;
   CPU-bound WASM work scales ~1.2–1.4× per HT pair, not 2×. Budget an 8-logical-core
   host as ~4–5 cores of real CPU-bound throughput, a 4-core user as ~2.5–3.
2. **The voxel pool competes only while moving.** godot_voxel's mesher/gen workers
   (pool_threads=6) are busy exactly when the player moves; an offloaded task then
   timeslices against meshing. But **at rest meshing is idle → the cores are genuinely
   free**, which is ideal for the stationary-forest scenario, and the moving-case
   contention is already governed: the far-trees job rides the stream-credit gate
   (`step()` returns unless `credit_ok`, `facet_far_trees.gd:481`), so under overload the
   controller cuts credit and the background dispatch idles. No new admission machinery.
3. **The dlmalloc convoy is about ALLOCATION, not core count.** The measured
   walk-perf pathology (memory `voxiverse-walk-perf-root-cause`) is workers churning the
   ONE shared WASM allocator lock. More cores don't fix a serialized lock — so the
   allocation-flat law stands at full strength: offloaded tasks pre-allocate/reuse
   buffers, never churn per-task allocations. (Bonus: the P1 design's preallocated
   double buffers *remove* the shipped path's 0.76 MB/step churn.)
4. **Never offload per-frame small work.** A WTP dispatch+reap round trip costs
   ~0.1–0.3 ms of main-thread bookkeeping plus a frame of latency; anything under
   ~5 ms/event (items 5, 7, 9) is cheaper to run in place or not at all.

**Sizing law (new, §6bis):** every GDScript-side worker pool must size itself off the
TRUE core count (the `facet_tex_baker.gd:202-207` reader), reserving explicit headroom
for the voxel mesher pool — never off `OS.get_processor_count()`. This audit found two
shipped violations (smooth-v2 `_sn`, orbit-relief slots) running 1-wide on web.

*(One-line low-end note: a hypothetical true-2-core user degrades gracefully — the
single-slot lane + credit gate means offloaded work timeslices instead of stalling
frames; the design needs no separate low-end mode.)*

---

## 5. The prioritized plan

| Pri | Item | Flag | Type | Expected effect |
|---|---|---|---|---|
| **P0a** | Far-trees rebuild-on-change (already implemented in this tree, shipping via task #119) | `FP_FAR_TREES_DELTA` (`cube_sphere.gd:929`) | *don't run it* | stationary forest p50 30 → ~38-42 |
| **P0b** | Stationary streaming diet: run the `update_streaming` tail at 5 Hz when player within 0.25 blk + no dirty latch (edits/crossing/regime) | `FP_STREAM_IDLE_DIET` (new; design in forest-fps §4.7 — unchanged, endorsed) | *don't run it* | phys_ms p50 9.4 → ~5-6; +2-4 fps on the static floor |
| **P1** | **Far-trees rebuild → worker** (§6) | `FP_FAR_TREES_WORKER` (new) | **offload (A)** | walking-forest: the residual ~57 ms motion stall → ~1-2 ms apply; stationary: no change (DELTA already skips) |
| **P1b** | **True-core worker sizing** (§6bis): smooth-v2 `_sn` + orbit-relief slots off `hardwareConcurrency` with mesher headroom, instead of the under-reporting `OS.get_processor_count()` (1 slot on web today) | `FP_TRUE_CORES` (new) | sizing fix for existing C | crossing/warm-up annulus fill 2-3× faster on 8-logical-core hosts (tile builds parallelize instead of serializing on one worker); no stationary effect |
| **P2** | DEM bake → JobLane opportunistic | `FP_DEM_ASYNC` + `FP_BG_ONE_TOKEN` (already designed, COSMOS-STREAM-PARALLEL-DESIGN §4.2/§5) | offload (A) | bake-window frames only (fresh load / off-surface sweeps); clearly viable on 8 logical cores — schedule after P1/P1b land |
| — | smooth_v2 / orbit-relief / far-ring / tex / weather / env | (shipped flags) | already C | none — compute already off-main (P1b widens their slots) |
| — | update_streaming plumbing, controller, physics/raycast/collapse/GroundCollider, MultiMesh & mesh applies, render submit | — | B | **not offloadable** — engine API or correctness; the render residual needs a vertex diet, not a thread |

P0a/P0b are listed because the brief demands the distinction be explicit: **the two
biggest main-thread line items are not offload problems**, and shipping P1 without P0
would thread-ify work that mostly shouldn't run.

---

## 6. P1 design — `FP_FAR_TREES_WORKER`

### 6.1 The compute/apply split

Today `step()` (main) runs `_rebuild_meshes(cam_abs, wanted)` + `_rebuild_cards(cam_abs,
wanted)` synchronously (`facet_far_trees.gd:506-509`): a pure record walk that reads
`_cache` (fid → immutable-once-landed `PackedFloat32Array`), `cam_abs`, flag constants,
and the `_is_chopped` Callable into `WorldManager._edits` — then applies via
`_mm.set_buffer(buf)` / `mm.set_buffer(bufs[c])` + `visible_instance_count`
(`:748-749`, `:843-845`).

Under the flag, the walk becomes a **JobLane job** (WorldManager already owns the lane,
`world_manager.gd:219,381`; the tier gets `set_job_lane(lane)` exactly like
`facet_block_lod_ring.gd:165`):

* **Dispatch (worker):** run the SAME two build functions, refactored the
  `FP_SMOOTH_V2_ASYNC_MERGE` way — each split into a **pure build** (returns/fills
  buffers; no `set_buffer`, no `_dbg`/print, no node access) + a **main apply**. The
  sync path composes pure-build + apply back-to-back in the same order (flag off ⇒ same
  calls, same output — the `_commit`/`_build_and_swap` precedent,
  `facet_smooth_v2.gd:595-618`).
* **Apply (commit, main):** 1× card `set_buffer` + 6× species `set_buffer` +
  7× `visible_instance_count` + the `_last_buf`/`_live_instances`/`_capped` latches.
  ~0.76 MB of buffer upload ≈ **1–2 ms** — one JobLane commit (the drain never abandons
  its first commit, `job_lane.gd:143-144`, so exceeding the 2 ms budget by a little is
  bounded and legal).
* **Priority:** a new `JobLane.PRIORITY_FAR_TREES := 30` — below manifest (40), above
  opportunistic (10): cosmetic far band, must never outrank crossing/block-LOD/texture.

### 6.2 What crosses the boundary (snapshot semantics — the correctness model)

The job owns, captured on main at dispatch:

| Datum | Form | Why safe |
|---|---|---|
| `cam_abs` | Vector3 by value | trivial |
| `wanted` | the cached `_last_wanted` Array (DELTA already caches it, `:629-639`) — duplicated shallow (≤ ~64 ints) | worker-private copy |
| record arrays | an `Array` of the `PackedFloat32Array`s for the wanted fids, built at dispatch | each recs array is written ONCE by `_reap_enum` before it ever enters `_cache` and never mutated after (`:528-533`); eviction only drops the dict ref — the job's ref keeps it alive (COW refcount). Single-writer-then-immutable |
| chop set | `WorldManager._edits` **shallow-duplicated** at dispatch, with a pure static predicate replacing the `_is_chopped` Callable (same `FacetAtlas.edit_key` math) | `_edits` mutates on main during flight; the duplicate is O(edit-count) — tens of entries typically. NEVER call a Callable into WorldManager from the worker |
| epoch stamp | `(cache_epoch, edits_rev, cam_abs)` triple | the stale-discard key (§6.3) |
| output buffers | the tier's preallocated **back** buffers (1 card + 6 mesh `PackedFloat32Array`s, sized `cap × stride` once at setup) | worker single-writer while in flight; +≈0.76 MB resident (NEVER-OOM ledger §6.5) |

**Determinism:** the pure build is a deterministic function of exactly this snapshot, so
`worker(snapshot) == sync(snapshot)` **byte-equal** — gateable headless without threads
(call the pure build twice with the same snapshot) and with them (G-FTW-EQ, §6.4).

### 6.3 Double-buffer + stale-result policy (no tearing, no ghosts)

* **Front** = the buffers currently applied to the MultiMeshes; **back** = the worker
  target. Commit applies back → GPU, then swaps roles. The screen never sees a
  half-written buffer because `set_buffer` is the only publication point and it happens
  once, on main, from a completed back buffer.
* **In-flight = hold, not stack:** `step()` never dispatches while a job is in flight
  (mirror of the single `_merge_task` slot, `facet_smooth_v2.gd:548-549`); `_dirty`
  re-arms via the existing DELTA change detector on the next step.
* **Stale discard at commit:** if `cache_epoch` or `edits_rev` at commit ≠ the job's
  stamp → **discard** (do not apply; DELTA re-fires). A chopped tree can therefore never
  reappear from a stale result. **Camera motion alone does NOT discard** — the applied
  result is ≤250 ms + one build old; at the band floor of 128 blocks (mesh rung) that is
  sub-degree angular error, and fades lag by one step exactly as the shipped 250 ms
  cadence already does. Motion-discard would livelock the band while walking.
* **Visibility latch:** the COLORFIX `_stale` off-surface latch (`:462-469`) keeps its
  contract — the latch clears at *commit* (first applied rebuild), not at dispatch.

### 6.4 Flags, injection sites, gates

```gdscript
# cube_sphere.gd, beside the FAR_TREES block
const FP_FAR_TREES_WORKER := false   # far-trees rebuild walk on JobLane; main pays only set_buffer
```

Injection: `facet_far_trees.gd step()` `:506-509` — under the flag, replace the two sync
calls with the snapshot+submit (guarded by the in-flight slot); `world_manager.gd` wires
`set_job_lane` beside the tier's existing `set_chop_query` (`world_manager.gd:414`
plumbing pattern). Byte-off: with the const false the submit branch is dead, the sync
path runs the same pure-build+apply composition in the same order, and the preallocated
back buffers are never created (allocated lazily on first flag-on dispatch).

Gates (extend `verify_far_trees.gd`, 40/0 today):
* **G-FTW-EQ** — pure build on a worker (real WTP task) with a fixed snapshot ==
  synchronous pure build, byte-equal card + 6 mesh buffers.
* **G-FTW-STALE** — bump `edits_rev` (chop) while a job is in flight → commit discards;
  next step re-dispatches and the chopped tree is absent from the applied buffer.
* **G-FTW-HOLD** — no second dispatch while one is in flight; `_dirty` re-arms after.
* **G-FTW-OFF** — flag off: rebuild path identical (rebuild counter == DELTA behaviour;
  existing 40 gates green; standard flag-off export compare).
* **G-JL-BOUNDED** already covers the commit budget.

Live A/B (forest facet 1754, the #119 protocol): baseline = DELTA-on capture; flag-on,
**walk a 200-block loop through the forest**: worst_ms histogram while moving loses the
80–110 ms mode; fps p50 while moving ≥ baseline+5; eyeball: no tree ghosts after chopping
with the far band visible, fades track motion with no visible lag step.

### 6.5 Cost model + NEVER-OOM

* **8-logical-core host (the reference):** the walk runs on a genuinely free core when
  stationary-adjacent (meshing idle) and overlaps meshing while moving; wall time
  ~50–70 ms mostly hidden, main pays only the 1–2 ms apply. Moving-camera stall mode
  (80–110 ms worst frames) eliminated; expected walking-forest fps p50 +5–8 and min_fps
  up sharply.
* **4-core user:** ~2.5–3 cores of real throughput; the walk timeslices against the
  voxel pool while moving (credit-gated, ≤1 in flight, ≤4 fires/s), stretching wall time
  to maybe ~100 ms — still invisible to the frame; apply unchanged at 1–2 ms. Net win,
  slightly smaller margin.
* **Allocation-flat either way:** preallocated back buffers + O(edits) dict dup +
  O(64) Array of refs per dispatch ⇒ no new dlmalloc-convoy pressure (§4.3).
* **Memory:** +0.76 MB back buffers + transient snapshot refs ≈ **+0.8 MB**, ledgered;
  no per-step churn (the shipped path's 0.76 MB/step realloc actually *disappears* on
  the flag-on path — the buffers are reused).

---

## 6bis. P1b design — `FP_TRUE_CORES`: size GDScript worker pools off the real core count

**The bug (§2):** `facet_smooth_v2.gd:425` (`_sn = clampi(OS.get_processor_count() - 1,
1, CubeSphere.SMOOTH_BUILD_SLOTS)`) and `facet_orbit_relief.gd:511` size their worker
slot pools from `OS.get_processor_count()`, which returns 2 on this 8-core host ⇒ **one
worker slot each on web**. Their tile builds — the annulus/relief warm-up after every
facet crossing — serialize on a single WTP worker while 4–5 logical cores sit idle.

**The fix:** one shared true-core reader + one sizing law.

* Promote the proven reader out of the tex baker: `CubeSphere.true_cores()` — web:
  `navigator.hardwareConcurrency` via JavaScriptBridge, else `OS.get_processor_count()`
  (exactly `facet_tex_baker.gd:202-207`; the baker delegates to it, no behaviour change
  there). Read once, cached.
* Sizing law with mesher headroom: `slots = clampi(true_cores - VOXEL_RESERVE, 1, cap)`
  with `VOXEL_RESERVE := 4` (main + ~3 busy voxel workers) — on 8 logical cores → 4
  slots (was 1); on 4 → 1 (unchanged, graceful); caps stay `SMOOTH_BUILD_SLOTS`/the
  relief cap. Applied under the flag at the two sizing sites; off ⇒ the shipped
  `OS.get_processor_count()-1` expression verbatim.
* Any NEW worker sizing (P1's lane usage included) must call `true_cores()` — the lane
  itself stays `max_inflight=2` (its ledgered WTP budget; not a per-core knob).

**Gates:** G-TC-READ — headless, `true_cores()` == `OS.get_processor_count()` (no JS
bridge off-web); G-TC-SIZE — sizing formula table-checked for cores ∈ {2,4,8,16};
G-TC-OFF — flag off ⇒ `_sn` identical to shipped. **Live verification first** (the §2
open question): dump `cores`, `os_cores`, and the engine's `pool_threads` from the
served build in one telemetry window to confirm which sites are actually mis-sized
before flipping the flag.

**Honest expectation:** this buys crossing/warm-up latency (annulus fill 2-3× faster),
NOT stationary fps — the smooth-v2 main-thread cost is its apply, which P1b does not
touch. Worth doing because it is small, byte-off, and removes a silent serialization
that will otherwise distort every future offload measurement.

---

## 7. Honest verdict — what NOT to offload, and the ceiling

**Not worth offloading** (and why):
* `update_streaming` tail — orchestration + engine applies; the fix is the idle diet.
* SmoothV2/orbit-relief/far-ring/tex/weather/env — already threaded (P1b widens two of
  their pools); only their RenderingServer applies remain, which cannot move.
* Controller, snow, HUD reads — sub-ms; dispatch tax exceeds the work.
* Raycast / collapse flood-fill / GroundCollider — physics + must-be-synchronous
  gameplay authority; event-driven and already bounded.

**Ceiling after P0a + P0b + P1 + P1b** (stationary forest): the static floor decomposes
as ~14 ms render-submit/GPU residual + ~5-6 ms dieted physics tick + ~1 ms scripts ⇒
**~20-21 ms ≈ 45-50 fps p50 best case on the 8-logical-core reference host, realistically
p50 ~40-45**; on a 4-core user expect a few fps less at the same floor (the residual is
render-bound, not core-bound). min_fps and hitch-rate improve more than the median — the
stall modes are what die, and that is the felt experience. **The remaining ~14 ms
residual is not a threading problem**: gl_compatibility submits draws on the main thread
by engine design, so the next lever is the render residual itself (forest-fps §6.3 floor
probes → FULL_COVER backstop vertex diet). With that geometry diet landed, an 8-core
desktop user should sit at or near the vsync ladder's 60 fps rung; threading work beyond
this plan buys nothing further.
