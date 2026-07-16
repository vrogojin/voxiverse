# COSMOS — Mesh-Upload Pacing: Root-Cause & Ceiling Analysis

**Branch:** `fix/voxiverse-crossing-jerkiness`
**Question:** After the generation fixes (bulk-underground), the residual jerkiness is on the
main-thread mesh-apply + GPU-upload + render path, not generation. What actually causes the
300–1188 ms post-crossing worst-frame spikes, what can we pace WITHOUT touching the render
radius (user-vetoed at 128 near / 256 flat), and what is inherent?

**Verdict (up front):** The mesh **apply is already fully paced** — the godot_voxel main-thread
apply queue is empty essentially always (mean depth **0.01**, gpu-apply queue **always 0**). The
dominant deep-spike class (**79%** of all frames ≥250 ms) is the **GL-compatibility draw-call +
web-rAF render ceiling at the fully-streamed 204-draw-call load**, evenly spread across the whole
soak — it is **not** an apply/upload backlog and **no mesh-pacing knob removes it**. The genuine
post-crossing spike is a **modest 157–381 ms transient over ~11–23 frames**, driven by
generation-worker CPU contention during the restream burst, which the existing request-pacing
(view-ramp + `StreamLoadController` + committed-imminent pre-gen) already spreads. The only
mesh-side knob (`time_budget_ms`) is **export-baked and not runtime-adjustable from GDScript**, and
with an empty apply queue lowering it trades slower fill / more pop-in for a benefit that mostly
does not exist. **The remaining real lever is structural draw-call reduction (greedy meshing /
coarser far-LOD) or a radius cut (vetoed) — not pacing.**

---

## 1. Evidence — what the telemetry actually says

Source: `tools/remote-bridge/results/telemetry.jsonl` — a **149-minute** live real-GPU remote-bridge
soak, **31,085** per-second telemetry rows + **11** crossing events + **11** post-crossing
attribution windows.

### 1.1 How the metrics are measured (this changes the interpretation)

From `godot/src/net/remote_bridge.gd`:

| field | source | trustworthy? |
|---|---|---|
| `worst_ms` | **true wall-clock max frame delta** over the ~1 s window (`Time.get_ticks_usec()` deltas, NOT the engine-clamped `_process(delta)`) | **YES — the only reliable timing.** Captures GDScript + physics + render + GPU + browser rAF. |
| `proc_ms` | `Performance.TIME_PROCESS` | **NO.** On the threaded web export `TIME_PROCESS` includes rAF/compositor wait (memory `voxiverse-web-time-process-invalid`: reads 77–136 ms at a healthy 60 fps). It **tracks** `worst_ms` because both inflate together; it does **not** attribute cost to GDScript. |
| `phys_ms` | `TIME_PHYSICS_PROCESS` | Mostly reliable; physics is fixed-step. |
| `vox_gen/mesh/main/gpu` | `VoxelEngine.get_stats()` task counts | **Queue DEPTHS (pending tasks), not times.** `vox_main` = pending main-thread mesh-apply tasks; `vox_gpu` = pending gpu tasks; `vox_gen` = pending generation tasks. Sampled once per window (misses sub-second transients). |
| `draws` / `prims` | `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` / `..._PRIMITIVES...` | Reliable render-load counters. |

Because `proc_ms` is `TIME_PROCESS`, **any decomposition that treats `worst_ms − proc_ms` as
"render time" is wrong** — `proc_ms` is itself mostly render/rAF wait. The correct read is:
`worst_ms` is the whole frame; the `vox_*` **queue depths** tell us *where the backlog is*; `draws`
tells us the **render load**.

### 1.2 Frame-rate bands (where time is actually spent)

| fps band | % of soak | draws | prims | worst_ms | vgen (pending) | vmain (pending) |
|---|---|---|---|---|---|---|
| 0–3 | 0.9% | **204** | 136,578 | ~514 | **0** | 0 |
| 3–8 | 0.6% | 164 | 124,457 | ~255 | 280 | 0 |
| 8–15 | 2.3% | 117 | 101,425 | ~152 | 398 | 0 |
| 15–25 | 5.3% | 175 | 129,997 | ~103 | 0 | 0 |
| **25–40** | **86.4%** | **204** | 136,578 | ~57 | 0 | 0 |
| 40–55 | 3.4% | 44 | 82,287 | ~52 | 0 | 0 |
| 55–61 | 1.6% | 44 | 82,287 | ~26 | 0 | 0 |

Read this carefully:

- **The steady state is 25–40 fps (86% of the time) at 204 draw calls, ~57 ms worst frame, with
  every voxel queue empty.** That ~30 fps / 57 ms floor is the **draw-call render cost** of 204
  GL-compatibility draws (ANGLE→D3D11) — exactly the per-draw-call ceiling the `mesh_block_size=32`
  comment in `module_world.gd` already describes. This is the floor, not a spike.
- The 40–61 fps band exists only at **44 draws** (partially-streamed / far-from-full) — halving the
  draw calls roughly doubles the frame rate. **The frame rate is draw-call-bound, cleanly.**

### 1.3 Deep-spike attribution (frames ≥ 250 ms, n = 411)

| classification | count | share |
|---|---|---|
| **vgen = 0 AND vmain = 0 AND phys < 100 ms → pure render / browser-rAF** | **326** | **79.3%** |
| at max draw-call load (draws ≥ 200) | 316 | 76.9% |
| during a generation burst (vgen > 0) | 85 | 20.7% |
| **mesh-APPLY queue backed up (vmain > 0)** | **6** | **1.5%** |
| **gpu-apply queue backed up (vgpu > 0)** | **0** | **0.0%** |
| physics catch-up > 100 ms | 8 | 1.9% |

`vox_main` (pending apply tasks): **mean 0.01** across all 31k rows, max 36. `vox_gpu`: **max 0 —
the gpu-apply queue never once backed up.** The apply path is not the bottleneck in any measurable
sense.

The 326 pure-render/rAF spikes are **evenly spread across 150 of 299 30-second bins** over the
2.5-hour soak (max 11 per bin) — i.e. a **persistent render/scheduling ceiling at the 204-draw
load**, not a handful of tab-background events. (The single 7,862 ms outlier IS a
background/GC/tab-hidden gap — inherent to an unattended browser soak, discard it.)

### 1.4 The actual post-crossing spike (the attribution windows)

The 11 `post_worst_ms` windows the emitter logs (the true "worst frame in the 11–23 frames
following a crossing"):

```
185, 267, 273, 292, 308, 272, 279, 381, 183, 158, 197  (ms) — mean ≈ 254 ms, over 11–23 frames each
```

So the **honest post-crossing worst frame is 157–381 ms**, not the 1188 ms figure — the ≥500 ms
spikes in a naive `sort -worst` are the *evenly-spread render-ceiling* class (§1.3), which happen
whether or not a crossing just occurred. During these windows `vgen` is 280–400 (generation burst)
and `vmain` stays ~0: the cost is **generation-worker CPU stealing cycles from the browser main
thread / rAF**, not mesh apply.

---

## 2. Root cause (a / b / c / d from the brief)

| candidate | verdict | evidence |
|---|---|---|
| **(a) mesh apply exceeding the 6 ms budget on a single 32³ block** | **Not the driver.** The `TimeSpreadTaskRunner` is a `do { run(); } while (elapsed < budget)` (`util/tasks/time_spread_task_runner.cpp:39–68`) — it runs ≥1 apply even over budget, but the apply queue empties every frame (`vmain` mean 0.01). At most a few ms/frame, never 100s. | `vmain` mean 0.01, max 36; only 1.5% of spikes have `vmain>0`. |
| **(b) GPU vertex upload on first draw of a new mesh RID** | **Minor / transient only.** The gpu-apply queue (`vox_gpu`) never backs up (max 0). A post-crossing batch-apply can cause a sub-second upload transient the ~1 s queue sampling misses — this is the plausible core of the modest 157–381 ms post-crossing windows — but it is bounded and small, not the ≥500 ms class. | `vgpu` max 0; post-crossing windows 157–381 ms. |
| **(c) render thread drawing many more instances (draw-call step)** | **YES — this is the floor AND the dominant spike class.** 204 GL-compat draws = ~30 fps / 57 ms steady; halving to 44 draws → 45–60 fps. 79% of deep spikes sit at draws ≥ 200 with all queues empty. | §1.2 band table; §1.3. |
| **(d) browser rAF scheduling gaps** | **YES — compounds (c).** Once the frame rate collapses under draw load + worker contention, the browser throttles rAF and worst-frame balloons (the 514 ms fps-0–3 rows, the 7.8 s outlier). Inherent to the threaded web export on a low-core client. | §1.3 even spread; the multi-second outlier. |

**Bottom line: the spike is (c) the GL-compatibility draw-call render ceiling + (d) web-rAF
scheduling, not (a) apply backlog or (b) an upload queue we can drain faster.** The apply is
already paced to an empty queue.

---

## 3. Controllable levers WITHOUT changing render radius

### 3.1 `voxel/threads/main/time_budget_ms` — the only mesh-apply knob

- **What it is:** read ONCE at startup into `config.inner.main_thread_budget_usec`
  (`voxel_engine_gd.cpp:60`); caps µs/frame the `TimeSpreadTaskRunner` spends applying finished
  meshes. Currently **6** (`godot/project.godot:83`).
- **Runtime-adjustable from GDScript? NO.** `VoxelEngine::set_main_thread_time_budget_usec()`
  exists in C++ (`voxel_engine.h:189`) but is **not bound to GDScript** — `voxel_engine_gd.cpp`
  `_bind_methods()` binds `get_stats`/version/tests only, not the budget setter. So there is **no
  adaptive per-crossing throttle** without an engine patch (+~24 min rebuild). It is **export-baked**
  (a re-export, not an engine rebuild, picks up a project-setting change).
- **Effect of lowering (6 → 4 → 3):** fewer applies/frame ⇒ a *transient* post-crossing batch of
  finished meshes applies (and uploads, next frame) over more frames ⇒ shallower-but-longer fill,
  more pop-in. **With the apply queue already empty, the benefit is limited to the sub-second
  post-crossing batch transient (the 157–381 ms windows); it does NOTHING for the 79% render/rAF
  ceiling class.** Raising it does nothing useful (queue is already drained).
- **A/B-worthy?** Marginally, for the post-crossing window only. See §4.

### 3.2 A godot_voxel property that caps new mesh instances made visible per frame?

**None exists.** In `VoxelTerrain` the `TimeSpreadTaskRunner` **is** the throttle — there is no
separate "N mesh blocks visible per frame" knob. `max_view_distance` gates which blocks are
*requested* (the view-ramp already staggers this); once a mesh is applied, godot_voxel owns its RID
and it is drawn the next frame. There is no per-block visibility gate to stagger from GDScript.

### 3.3 A module-level (GDScript) stagger?

**Not feasible for meshes.** godot_voxel owns the mesh lifecycle as `RenderingServer` RIDs (not
scene `MeshInstance` nodes we can toggle `.visible` on — the wrapper `.visible=false` leaves the RID
blocks drawn; `module_world.gd:32`). The **only** GDScript-side control over what renders is
`max_view_distance`, which is what the view-ramp / `StreamLoadController` /
`CTRL_IMMINENT_COMMIT_PACE` already modulate to spread block **requests** (upstream of apply). That
request-pacing is the right and already-present lever for the 21% generation-burst spikes; there is
no apply-side backlog left to pace.

### 3.4 Draw-call reduction (the real remaining lever — out of scope here)

The frame rate is cleanly draw-call-bound (§1.2: 204 draws → 30 fps, 44 draws → 55 fps). The floor
and 79% of spikes only move with **fewer draw calls**:

- `mesh_block_size` is already at **32** (the max; godot_voxel accepts only 16 or 32), already
  cutting draws ~4–8× vs the 16³ default.
- Further reduction needs a **structural** change: **greedy meshing** (merge coplanar faces — fewer
  primitives *and* fewer surfaces), or a **coarser / merged far-LOD** so distant facets contribute
  fewer draws. That is the domain of the render-simplification design, not mesh-upload pacing.
- Or a **radius cut** — explicitly **vetoed** by the user.

**This design does not implement a structural draw-call change; it documents that this — not
pacing — is where the remaining real win is.**

---

## 4. What is implemented, and the A/B recipe

### 4.1 Implemented: documented, reversible knob (no baked default change)

The prior `4 → 6` bump was an **explicit user choice** recorded in the project.godot comment
("faster fill > marginal extra smoothness here — the user explicitly opted into"). The telemetry
does not justify silently reverting that trade: the benefit of lowering is confined to the modest
post-crossing transient and cannot be measured on this GPU-less host (per memory
`voxiverse-gpu-headless-testing`, real-web worst-frame needs a real GPU). So the shipped
**default stays `time_budget_ms = 6`**, and this design annotates it as the documented A/B knob
pointing here. No generation code path changes ⇒ **FLAT byte-identity (6035/0) and the faceted gate
are untouched by construction** (a project setting affects apply *pacing*, never generated blocks;
the headless verify gates do not render).

### 4.2 How to A/B it live (real-GPU browser only)

`time_budget_ms` is **export-baked** — flip it at deploy via a sed on `godot/project.godot` before
`scripts/export-web.sh`, then `scripts/deploy.sh`:

```bash
# A/B a lower apply budget (spread the post-crossing batch transient; slower fill / more pop-in):
sed -i 's/^threads\/main\/time_budget_ms=6/threads\/main\/time_budget_ms=4/' godot/project.godot
scripts/export-web.sh && scripts/deploy.sh
# then drive a few crossings via the remote bridge and compare post_worst_ms windows in
# tools/remote-bridge/results/telemetry.jsonl against the 6-ms baseline (mean ≈254 ms).
# Try 3 as the low end. Revert with the reverse sed (back to 6).
```

**Compare on `post_worst_ms` (the crossing windows), NOT raw `sort -worst_ms`** — the latter is
dominated by the render/rAF ceiling class that this knob does not touch. **Expected effect: modest
(tens of ms on the post-crossing window), possibly within web-rAF noise.** If 4/3 does not measurably
beat 6 on `post_worst_ms`, keep 6 (the user's fill-speed choice stands).

---

## 5. Honest ceiling statement

- The mesh **apply/upload path is already paced** — the queue is empty (mean 0.01), the gpu queue
  never backs up, and there is no GDScript hook to pace it further even if it did.
- **~79% of the deep spikes and the entire ~30 fps steady floor are the GL-compatibility draw-call
  render ceiling (204 draws) plus web-rAF scheduling** on a low-core client — **inherent to this
  render path; only a structural draw-call cut (greedy meshing / coarser far-LOD) or a radius cut
  (vetoed) removes them. `time_budget_ms` does not.**
- The genuine post-crossing spike is a **modest 157–381 ms / ~20-frame transient** from generation
  contention, already spread by the existing request-pacing controller; the one knob left
  (`time_budget_ms`, A/B-able down to 4/3) can only shave the sub-second apply-batch portion of it,
  by a modest and possibly-noise-level amount.

The single most impactful next step for frame stability is **reducing the 204 draw-call load**, not
mesh-upload pacing.
