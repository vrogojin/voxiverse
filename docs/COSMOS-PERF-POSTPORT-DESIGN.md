# COSMOS — Post-Port Performance: the New Cost Landscape, Apply-Bound Streaming, and the Re-Prioritization Law

**Status:** analysis + ranked design (no implementation in this pass). Branch `deploy/perf-plus-sky`, 2026-07-17 (evening).
**Author:** Fable (deep-analysis pass), commissioned after the C++ worldgen port (`FP_CPPGEN`, patch
`docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch`) landed and was live-verified.
**Predecessors:** `COSMOS-WALK-PERF-DESIGN.md` (the pre-port cost model — now partially obsolete),
`COSMOS-STREAM-SCHED-DESIGN.md` (R-plan; re-adjudicated in §5), `COSMOS-MESH-PACING-DESIGN.md`
(“apply queue is empty” — **no longer true**, §1.4), `COSMOS-SEAMLESS-SCALES-DESIGN.md` (the one-sampler
law the port implements). Scope fence: `fable-render-priority` owns the far-LOD-over-blocks DEPTH bug;
this doc owns throughput / scheduling / CPU only.

> **Headline.** The port worked: generation now drains at **322–964 blocks/s** (was 26–34) and the
> backlog is nonzero in only **21 %** of active windows (was ~most of every walk). The freeze did not
> disappear because it was never *only* generation: **the pipeline’s pacer moved from the workers to
> the main thread.** Pre-port, slow gen was an accidental rate-limiter that trickled meshes into the
> apply path; post-port, each quantized view-ramp shell (jump p50 **270 blocks**, max 638) generates in
> ~1 s and lands as a compressed **mesh-apply/upload burst** — `vox_main`, empty in every previous
> session ever measured, now spikes to **87** pending applies, exactly inside the worst frames
> (300–881 ms). Every one of the 11 measured crossings has a ≥290 ms frame in ±2 s (**C1 p50 = 343 ms**),
> and part of that stall happens with ALL voxel queues at zero — an unattributed main-thread commit
> (far-ring re-emit is the prime suspect, §2.2c) that generation speed cannot touch. The framerate
> “jumping back and forth” is real and largely *periodic*: a 2 s capture readback (~+35 ms, observed
> sessions only), a 0.5 s snowfall step (≤4 block remeshes/step), the shell-burst sawtooth, and the
> 60↔30 vsync ladder — **129 fps-bucket transitions/min** on the walking leg. The plan: instrument the
> apply/upload/receive stage first (T2, one small engine-patch batch + three no-rebuild edits), then
> gate streaming admission on **in-flight blocks (gen+mesh+apply) instead of gen backlog** (P1), spread
> the crossing’s work (P2), and re-order the apply queue by gaze/distance (P3) — that is what
> “continuous re-prioritization” means now: **re-prioritizing uploads, not generation.**

Reading map: §1 measured ground truth · §2 root causes per complaint · §3 instrumentation (do first)
· §4 ranked plan · §5 re-adjudication of the stream-sched R-plan · §6 metrics protocol · §7 verdicts
on prior framings · §8 risks + honest caveats.

---

## 0. Data provenance

All numbers re-derived from `tools/remote-bridge/results/telemetry.jsonl(.1)`, sessions of
2026-07-17 (rx 14:20–17:23 UTC, four sessions split on `up_ms` resets; the post-port verification
session S3 = rx 16:42+, n = 11 604 windows @250 ms, 11 committed crossings with `crossing` /
`crossing_after` event records). All from the user’s laptop (hw≈8, `pool_threads=6`), real GPU, live
site. Deployed flag provenance (from the first-record `flags` stamp, `remote_bridge.gd:652-658`):
FACETED, FP_M1_POOL, FP_M2_LOD, FP_CTRL_ADAPTIVE, FP_PREFILL_112, FP_VEL_PREDICT, FP_FIXED_FRAME,
FP_FARRING_FULL_COVER, FP_NO_NEAR_LOD, FP_ATLAS_MATERIAL, POOL_CROSSING_PREGEN — all true.
**Gap:** the stamp does not include `FP_CPPGEN` (lead-confirmed ON), nor `FP_FARRING_FAST_REBUILD` /
`FP_FARRING_ASYNC_REBUILD` / `ORBITAL_SKY` — their deployed state is **unknown from telemetry**
(repo consts are `false`, `cube_sphere.gd:253,270,458`; deploy flips via sed). Fix in T2d.

---

## 1. Measured ground truth, post-port

### 1.1 Generation is (mostly) exonerated

- Drain rate while draining >50/window: **p50 322, p90 502, max 964 blocks/s** (pre-port: 26–34).
- `vox_gen` whole-session p50 = 0, p90 = 0; backlog nonzero in **21 %** of active-phase windows.
- Burst arrivals are *quantized*: `vox_gen` jumps >50 land at **p50 270 / max 638 blocks in one
  250 ms window** — each 16-voxel step of a slot’s `max_view_distance` releases a whole shell
  (`_ramp_pool_step` advances `view_f` continuously, `module_world.gd:432-472`, but the engine’s
  data-box diff quantizes to 16-voxel mesh blocks; a shell at r≈7 blocks ≈ 4π·49 ≈ 600 blocks).
- The gen-side telemetry died with the port: `gen_ct_*`/`gen_ms_*` read 0 all session — the T1
  per-class timer lives in the GDScript generator source (`module_world.gd:2845-2866`), which
  `FP_CPPGEN` bypasses (`_make_cpp_generator`, `module_world.gd:3546`). Instrument gap → T2c.

### 1.2 The four-quadrant table, post-port (S3, background-gap-filtered)

| condition | n | worst p50 | worst p90 | M1 (>100 ms) | phys p50 | fps p10 |
|---|---|---|---|---|---|---|
| still, gen = 0 | 8 641 | 46.1 | 66.2 | **0.7 %** | 3.4 | 19.8 |
| moving, gen = 0 | 528 | 43.0 | 74.8 | 4.5 % | 12.6 | 25.9 |
| moving, gen 1–100 | 41 | 66.7 | 131.1 | **34.1 %** | 17.3 | 13.9 |
| moving, gen > 100 | 152 | 58.1 | 135.2 | **29.6 %** | 17.8 | 14.2 |

The shape of the old story survives at ~⅓ its magnitude: streaming-active windows are still the
freeze windows (M1 ~30 % vs 0.7 %), and `phys_ms` still inflates 3.4 → 17.8 for unchanged code
(the SMT-oversubscription coupling of WALK-PERF §2.9 — 6 workers grinding for ~1 s per burst still
collide with the main thread; they just finish 10× sooner now). The difference: those windows are
now a **small minority** of the route — the pain compressed into bursts.

### 1.3 The walking leg (16:46–16:50, the 11-crossing run)

M1 = **13.5 %** (route-integrated; the lead’s 11.9 % reproduces within protocol noise), worst p50 50 /
p90 122, fps p10 16, fps p50 39, **fps-bucket transitions 129/min**, fps stddev 15.8. Of the 108
worst>100 windows, only **47 are within ±2 s of a crossing** — 56 % of freezes happen *between*
crossings (shell bursts + periodic spikes, §2.3/§2.4).

### 1.4 `vox_main` queues for the first time in project history

`vox_main` (pending main-thread `ITimeSpreadTask`s — mesh applies + frees) was mean 0.002/max 20
across 10 830 pre-port samples (WALK-PERF §1.4) and mean-0 in `COSMOS-MESH-PACING-DESIGN.md`.
Post-port it is nonzero in 31 windows — **spiking 17–87, exclusively inside crossing/burst windows,
coincident with the worst frames**. `vox_mesh` peaks at 33. Windows where the scene changed
(|Δdraws| > 0, i.e. meshes actually added/removed) have **M1 = 12.4 % vs 1.0 %** for windows with no
scene delta. The apply stage is no longer idle machinery; it is the queue where the burst lands.
(The 6 ms budget, `project.godot` `threads/main/time_budget_ms=6`, spreads it — but a burst of 600
applies is 3.6 s of nominal budget, and single tasks overshoot the quantum since one task = one whole
block’s `build_mesh` + inline `glGenBuffers`/`glBufferData` upload, `mesh_storage.cpp:219-276`,
WALK-PERF §2.8.)

### 1.5 Two periodic main-thread spikes, one host confound

Autocorrelation of `worst_ms` in a quiet stationary phase (n = 2 267): peaks at lag 8 (**2.0 s,
+0.41**) and lag 2 (**0.5 s, +0.27**); hi-windows p50 50 ms vs lo-windows p50 30 ms.

- **2.0 s = the remote-bridge ambient capture.** `FRAME_INTERVAL_MS := 2000` with a synchronous
  `get_viewport().get_texture().get_image()` readback ~35 ms (`remote_bridge.gd:78-86`). The
  skip-gate (`CAPTURE_SKIP_WORST_MS := 45`) creates the observed alternation: a capture makes the
  window bad → next capture skipped → good window → capture fires again. **Observer effect: this
  exists only in remote-bridge sessions — including every session we measure.** §6 addresses it.
- **0.5 s = the snowfall fixed step.** `STEP_SECONDS := 0.5` on the main thread
  (`world_manager.gd:282-284` → `snowfall_system.gd:22-27`): ≤32 column scans + ≤32 cell writes
  ⇒ up to ~4 block remeshes (and their uploads) per step, plus GDScript-on-WASM scan cost.
- **Host confound:** across S1–S3 with a byte-identical static scene (draws 132–188, prims frozen,
  player stationary), session fps p50 swings 22↔59 and `floor_p10` (the *best*-decile frame) drifts
  15 → 31 ms over tens of minutes. That is thermal/power throttling (or browser energy-saver rAF
  demotion) on the laptop, not app load. Any A/B that ignores it will lie; §6’s protocol interleaves
  arms. It is also almost certainly a component of the user’s “uneven” percept on long sessions.

### 1.6 Crossing anatomy (all 11 events, `crossing`/`crossing_after` records)

The crossing *bookkeeping* is solved: `crossing_ms` 0.8–10.2, `redesignate_ms` 0.2–3.8,
`transform_ms` 0 (fixed frame skips the PlanetRoot write, `module_world.gd:1868-1869`),
`far_ms` ≤0.6, `rebuild_ms` ≤0.14. Yet **C1 (max `worst_ms` within ±2 s) = p50 343 ms**, range
290–881, on every crossing. The timeline signature, consistent across all 11:

```
t−4s…−1s   prefill burst: vox_gen 0→300–640 (imminent slot ramping 48→112 at commit pace),
           C++ gen drains it at 300–900/s; worst 45–130 ms windows while workers grind
t−0.5s…+0.3s  THE FREEZE: 2–4 consecutive 200–880 ms frames.
           vox_mesh spikes 18–33, vox_main spikes 17–87 (apply/free burst).
           On WARM crossings (no gen at all, e.g. 31→32: vox_gen=0 throughout) the freeze
           still happens: w=283/257/295 with gen=mesh=0 at sample time, vox_main=36 at t=0.
t+0.3s…+1.5s  recovery; post-cross annulus 112→128 trickles in (few hundred blocks, drains fast)
```

Verdict: the crossing freeze post-port = **(a)** the compressed apply/upload burst of the prefill +
redesignate view-rebalance (§2.2a-b) **plus (b)** a zero-queue main-thread stall that no current
instrument attributes (§2.2c). Generation is a minor term now.

---

## 2. Root causes, per complaint

### 2.1 Complaint 1 — “freezes while crossing facets border still not good enough”

Three mechanisms, in measured order of size:

**(a) Burst compression through the unpaced downstream.** The port made admission (view-ramp
growth) effectively free for the workers, so each released shell arrives at the mesher and then the
main-thread apply within ~1 s. Nothing pauses in that path: gen results are received **unbounded per
frame** (`voxel_engine.cpp:288-315`, WALK-PERF §2.2 — every completed task applied + deleted in one
frame), meshing is fast C++, and applies queue into the 6 ms time-spread budget whose tasks
individually overshoot (one 32³ apply = `build_mesh` + inline WebGL2 upload on the calling thread,
`voxel_terrain.cpp:1901-1920`, `mesh_storage.cpp:219-276`). The controller cannot help: its only
load-shedding signal for streaming admission is `vox_gen > CTRL_BACKLOG_MAX(300)`
(`stream_load_controller.gd:215-216`, fed by `LiveSource.poll` which reads **only**
`tasks.generation`, `:251-261`) — a queue that now empties in ~1 s. **The controller paces the stage
that is no longer the bottleneck and is blind to the stage that is.**

**(b) The redesignate view-rebalance.** At the crossing frame, `to` ramps 112→128 (a few hundred
blocks of gen+mesh+apply in the next ~2 s — small now) and `from` **snaps** 128→96
(`module_world.gd:1880-1884`): the shrink unloads a ~500-block annulus in one engine pass — data-map
erases + mesh frees (frees are time-spread tasks too → part of the t=0 `vox_main` spike).

**(c) The unattributed zero-queue stall (the biggest single unknown).** 250–350 ms frames straddling
t=0 with `vox_gen=vox_mesh=vox_main=0` at sample time, on crossings with **zero** streaming (warm
31→32). `vt_*` reads ~0.02 ms through them — but that acquits only `VoxelTerrain::_process` **of the
active terrain**: `terrain_main_thread_stats` reads `_terrain` only (`module_world.gd:1990-1994`),
so the imminent/neighbour terrains’ receive/update passes are invisible, and the time-spread runner
+ inline uploads live in `VoxelEngine::process`, outside `vt_*` entirely. Prime suspect: the
**far-ring re-emit** — every pool-exclusion change (spawn/retire/crossing) marks `_pending`
(`facet_far_ring.gd:121-127`) and the deferred rebuild ends in **one** `add_surface_from_arrays` of
the whole merged ring mesh (~MB-scale) on the main thread (`facet_far_ring.gd:190-208` async path;
worse if `FP_FARRING_FAST/ASYNC_REBUILD` are OFF in the deploy — unknown, §0). A multi-MB inline
`glBufferData` + browser-side validation is exactly a 100–300 ms frame. Secondary suspects: the
`from`-shrink bookkeeping pass, gravity-area resync + collider rebuild (`world_manager.gd:1803-1828`
— but instrumented cheap), a GC. **T2e settles this for zero rebuild cost** (GDScript timers around
the ring swap); do not ship a fix for (c) before T2e names it.

### 2.2 Complaint 2 — “framerate jumps back and forth quite noticeably”

The oscillation decomposes into four named, quantified components:

1. **The shell-burst sawtooth** (walking): admit 270–640 blocks → ~1 s of worker grind (fps 45→20,
   the §1.2 coupling) → apply burst (worst 100–200 ms) → quiet → next shell. Period ≈ the ramp’s
   shell cadence at walking speed; amplitude ≈ 25–40 fps. Fix = P1/P2 (admission pacing).
2. **The vsync ladder**: frame cost hovers near 16.7 ms → the browser quantizes to 60/30/20 buckets;
   fps p50 sits pinned at ~33 in whole segments whose best frames are 15 ms. A steady 45-cost frame
   reads as 30; one 5 ms improvement reads as 60. This *amplifies* every other component. No direct
   fix on WebGL2; shrinking the periodic spikes (below) moves whole segments up a bucket.
3. **The 0.5 s snowfall step and 2 s capture readback** (§1.5): +20–35 ms every cycle, i.e. a
   guaranteed 60→30 bucket drop at each firing. Fix = P4a/P4b.
4. **Host throttling** (§1.5): session-scale drift, not per-second oscillation — but it moves the
   baseline into the regime where components 1–3 straddle the 33 ms line, maximizing visible
   flapping. Protocol fix only (§6).

Evenness is therefore a *first-class metric* now: E1 (fps-bucket transitions/min, baseline **129**)
and E2 (windowed fps stddev, baseline **15.8**) enter the ship rule (§6).

### 2.3 Complaint 3 — “continuous re-prioritizing of block generation streaming” (standing /
moving+direction / gaze)

What already exists and still works post-port: the engine re-sorts every queued generation task by
live distance-to-viewer every 200 ms and workers re-check cancellation before running
(STREAM-SCHED §3.1, `threaded_task_runner.cpp:216-332`); `FP_VEL_PREDICT` leads the facet
promote/commit distances by speed (`cube_sphere.gd:423-434`). What changed: **generation order
barely matters at 300–900 blocks/s — a mis-ordered gen task costs ~3 ms of delay, not 173 ms.** The
stages whose ORDER the player now sees are (i) **admission** (which shell/slot is allowed to enter
the pipe — this is where standing/moving/direction belongs) and (ii) **apply** (which finished mesh
reaches the screen first — this is where gaze belongs, and it is a plain FIFO today: the time-spread
runner pops in arrival order). The concrete law is P1 (admission) + P3 (apply order + gaze/lead
viewers); the R4 cancellation patch is **demoted** (stale gen tasks now cost ~3 ms each;
`vt_dropped_loads` totalled 423 in 1.8 h of S0 ≈ nothing — the waste it reclaimed died with the
port). Full re-adjudication of the R-plan in §5.

### 2.4 Complaint 4 — “where are we still leaking CPU time” (the sweep)

Main-thread consumers, ranked by measured/estimated per-event cost on the user’s laptop:

| # | consumer | site | cadence | est. cost/event | verdict |
|---|---|---|---|---|---|
| 1 | mesh apply+upload bursts (incl. frees) | `voxel_terrain.cpp:1901-1920` + `mesh_storage.cpp:219-276`, budget `project.godot:time_budget_ms=6` | per shell/crossing | 100–880 ms/burst | **the** target (P1–P3) |
| 2 | far-ring re-emit single-mesh swap | `facet_far_ring.gd:190-208` | per spawn/retire/crossing | ~100–300 ms (suspected; T2e) | measure then chunk (P2c) |
| 3 | ambient capture readback | `remote_bridge.gd:78-86` | 2 s (bridge sessions only) | ~35 ms | exclude from metrics + mark (P4b) |
| 4 | snowfall fixed step | `snowfall_system.gd:22-27` via `world_manager.gd:283` | 0.5 s | est 5–25 ms (scan + ≤4 remeshes) | measure (T2f), smear (P4a) |
| 5 | unbounded gen-result receive | `voxel_engine.cpp:288-315` | per burst | O(burst) map inserts + task spawns | bounded by P1; engine cap optional (P5b) |
| 6 | controller tick (two window sorts) | `stream_load_controller.gd:106-123,159-168` | 0.25 s | sub-ms (30 + floor-window floats) | fine |
| 7 | telemetry tick (get_stats + 2 JS evals + JSON) | `remote_bridge.gd:530-690` | 0.25 s | ~1–3 ms | acceptable; bridge-only |
| 8 | `_ramp_pool_step`, lod tick, ring warm budget | `module_world.gd:390-418`, `facet_far_ring.gd:24` | per frame | sub-ms / budgeted 3 ms | fine |
| 9 | snow/water/carve per-material draws etc. | (atlas Stage 2 leftovers) | per frame | steady, in the 132–188 draws | already solved class |

And the honest negative result: the **standing-still 30 fps floor is not an app CPU leak.** With a
frozen scene (draws 132, prims constant, all queues 0) the *best-decile* frame drifts 15→31 ms
across a session while identical earlier segments ran 58 fps — that is the host, not the code
(§1.5). The in-app fill lever for weak/throttled clients remains the `?scale3d=` cap
(PERF-NEXT §1.2, unshipped, user-decision). If `ORBITAL_SKY` is ON in the deploy (unknown, §0), its
per-frame clock+sky pass must be measured once in T2f before it is assumed free.

---

## 3. Instrumentation first (T2 suite) — cheapest-decisive ordering

The pre-port instruments answered “is it gen?”; none of them can attribute a main-thread burst. In
cost order (first three need **no engine rebuild**):

- **T2d — flag provenance (5 lines, GDScript).** Extend the one-shot `flags` stamp
  (`remote_bridge.gd:652-658`) with `FP_CPPGEN`, `FP_FARRING_FAST_REBUILD`,
  `FP_FARRING_ASYNC_REBUILD`, `ORBITAL_SKY`, `FP_COLBULK`, `FP_STAMP`. Today we cannot prove what
  build produced a telemetry file. (This gap is live *right now*: §2.2c’s prime suspect hinges on
  whether the async ring path shipped.)
- **T2e — far-ring re-emit timer (10 lines, GDScript).** `Time.get_ticks_usec()` around the
  deferred re-emit’s mesh build + around the swap/`add_surface_from_arrays`
  (`facet_far_ring.gd:137-208`, both sync and async paths); emit an event record
  `{type:"farring", build_ms, swap_ms, verts}` through the existing event drain
  (`remote_bridge.gd:407` pattern). **Decision value: convicts or acquits the §2.2c stall in one
  crossing run.**
- **T2b — vt over ALL pool terrains (10 lines, GDScript).** `terrain_main_thread_stats` sums
  `get_statistics()` timings across `_pool` slots, not just `_terrain`
  (`module_world.gd:1990-1994`) — the imminent slot is where the prefill lands and it is currently
  invisible.
- **T2f — per-consumer frame attribution (15 lines, GDScript).** Accumulate `usec` around the
  snowfall step (`world_manager.gd:283-284`), the controller tick, and (if deployed) the CosmosSky
  process; add `snow_ms`, `cap=1` (window-contains-capture marker — lets analysis exclude
  capture-polluted windows honestly), and the max of each per telemetry window.
- **T2a — the engine-side apply/receive/upload meter (the one rebuild; batch with the pending
  heap line, task #5).** In the godot_voxel stats patch: per-frame accumulators exposed through
  `VoxelEngine.get_stats()` — `timespread_ms` (wall time inside
  `_time_spread_task_runner.process`), `applies` (tasks run), `apply_worst_ms` (longest single
  task), `received` (completed tasks dequeued in `process()`, `voxel_engine.cpp:288-315`), and
  `upload_bytes` (accumulated in `apply_mesh_update` from the mesh arrays’ sizes). Plus
  `mem["wasm_heap"] = emscripten_get_heap_size()` under `__EMSCRIPTEN__` (the NEVER-OOM gate
  instrument — still missing, still blocking every memory-costly bet). ~30 lines total; decision
  value: splits every worst frame into *timespread / receive / elsewhere*, and prices uploads in
  bytes for P2’s budget.
- **T2c — C++ generator counters (part of the same rebuild).** `VoxelGeneratorCosmos` gets atomic
  `blocks_generated` + `gen_us` (and, cheap, the 4-class histogram — the classifier ports in ~10
  lines), exposed via a bound method; `gen_class_stats` (`module_world.gd:2004`) merges it so the
  existing telemetry fields revive. Without this the port’s own regressions would be invisible.

---

## 4. Ranked plan

Flags: every item `const bool := false` in `cube_sphere.gd`, OFF == byte-identical, FLAT verify
6035/0 must hold. Judged on §6’s integrated SW-1C route, never on streaming-conditioned stats.

### P1 — `FP_INFLIGHT_GATE`: admission paced by total in-flight work, not gen backlog *(the main event)*

Mechanism: redefine the pipeline-pressure signal from `vox_gen` alone to **in-flight blocks
`F = tasks.generation + tasks.meshing + K·tasks.main_thread`** (K≈2 — an apply is main-thread-priced;
all three already in the polled `get_stats()` dict, `stream_load_controller.gd:258-260`). Two uses:

- `backlog_gated()` becomes `F > INFLIGHT_MAX` with hysteresis (open at `F < INFLIGHT_MIN`);
  proposed 192/64 (≈ 0.6/0.2 s of pipe at measured drain). Surfaces 3–4 inherit it unchanged
  (`stream_load_controller.gd:196,202`).
- Feed-forward on the ramp: `pace *= clampf(1.0 - float(main_q)/APPLY_CHOKE, 0.0, 1.0)`
  (APPLY_CHOKE ≈ 24) applied in `_ramp_pool_step` (`module_world.gd:463-468`) *including* the
  imminent floor — the committed-imminent slot keeps priority but must not outrun the apply stage
  (its exemption was designed when gen was the choke; applies choke everyone equally).

Expected effect (numbers to beat): shell bursts admitted in ≤~100-block tranches ⇒ `vox_main` peak
87 → <20; walking-leg M1 13.5 % → **≤6 %**; between-crossing freeze share (61 of 108 bad windows)
→ ~0; E1 129 → ≤80. Cost: S (GDScript, ~20 lines). NEVER-OOM: zero (strictly *delays* admission).
Risk: slower fill when genuinely idle — mitigated because the gate opens fully at F<64 and supply
is 300+/s, so time-to-cover barely moves (M4 guard, §6).

### P2 — crossing-specific spreading *(kills the C1 = 343 ms class)*

- **(a) `FP_PREFILL_FULL_FF` — prefill to the full near radius under the fixed frame.** The 112 cap
  existed because a 128-view imminent would have enlarged the *PlanetRoot re-place* — which the
  fixed frame deleted (`cube_sphere.gd:398-414`, `module_world.gd:1866-1869`). With P1 pacing the
  approach, raise `imminent_prefill_blocks()` to `near_render_radius()` (128) when
  `FP_FIXED_FRAME` — the post-cross 112→128 annulus (~a few hundred blocks of gen+mesh+apply at
  t+0…+1.5 s) disappears; redesignate’s only remaining work is the `from` shrink. NEVER-OOM: the
  imminent slot transiently holds active-radius volume — bounded by the existing per-slot bounds
  clamp + `POOL_NEIGHBOUR_MEM_BUDGET_MB` (`module_world.gd:83-84`); ledger entry: one slot ≤ +20 MB
  transient, freed on the post-cross shrink of `from`. Gate on the T2a heap instrument being live.
- **(b) `FP_SHRINK_RAMP` — ramp the `from` shrink instead of snapping.** Replace the 128→96 snap
  (`module_world.gd:1880-1884`; the generic snap at `:440-444`) with the same one-slot-per-frame
  ramp used for grows (~1 s), spreading the unload bookkeeping + mesh frees. Cost: S. NEVER-OOM:
  keeps ≤ the pre-crossing volume for ~1 s longer — no new peak (the peak IS the pre-crossing
  state). Expected: removes the free-burst component of the t=0 `vox_main` spike.
- **(c) far-ring chunked commit — design ready, ship AFTER T2e convicts it.** If the re-emit swap
  is the §2.2c stall: split the merged ring mesh into K per-facet-group surfaces committed ≤1 per
  frame (double-buffered per group exactly as the whole mesh is today,
  `facet_far_ring.gd:190-208`), or K sibling `MeshInstance3D`s swapped round-robin. Upload per
  frame drops K×; the transient double-buffer is *smaller* than today’s whole-mesh double buffer ⇒
  NEVER-OOM negative. Flag `FP_FARRING_CHUNK_SWAP`. If T2e instead shows the swap is cheap and the
  stall is elsewhere, re-aim at what T2a names (timespread vs receive vs “outside everything” = GC).

Expected effect of P2a+b (+c if convicted): **C1 p50 343 → ≤150 ms**, crossing `post_worst_ms`
(events) p50 ~150 → ≤100, with M4/M5 flat.

### P3 — the standing / moving-direction / gaze law *(complaint 3, concretely)*

State machine (all inputs already computed per frame: `_player_speed`, camera basis, `F` from P1):

```
STANDING  (speed < 0.5 for 2 s):   viewer at player; ramps open under the F-gate
                                   (idle prefetch IS the F-gate running open — supply 300+/s
                                   fills the full disc in ~5–8 s; no special mode needed)
MOVING    (speed ≥ 0.5):           R9 idle-lead viewer offset  lead = v̂ · min(K·|v|, 48) · idle,
                                   idle = clamp(1 − F/INFLIGHT_MAX, 0, 1), τ = 0.5 s smoothing
                                   (STREAM-SCHED §9.4 verbatim, with backlog term := F)
GAZE      (always, additive):      apply-queue ordering, not a viewer: see below
```

- **(a) `FP_IDLE_LEAD` (R9)** ships as specced in STREAM-SCHED §9.4 with the one substitution
  above. ~15 lines. Direction-of-motion priority for *admission*.
- **(b) P-APPLY-PRIO (engine patch, rides the T2a rebuild):** make the time-spread runner pop
  **mesh-apply tasks nearest-first with a gaze bonus**: priority = `dist²(block_center, viewer) −
  GAZE_W · max(0, dot(look, dir_to_block)) · dist` (viewer pos + look already sync per frame,
  `voxel_engine.cpp:313-351`). The queue is ≤~100 entries under P1 — an O(n) scan per pop inside
  the 6 ms budget is noise. This is “where we are looking” applied to the only stage whose order
  the eye can see. Also: before running an apply, drop it if its block left the loaded set (the
  late-arrival drop already exists at `voxel_terrain.cpp:1619-1637`; this just saves the build).
- **(c) R6 gaze *viewer* (a second VoxelViewer) stays SHELVED** — it adds demand volume to buy
  ordering that (b) buys for free, and its M4 risk was pre-registered (STREAM-SCHED §9.8).

Expected: first-mesh-ahead latency −30 % while walking (measure via M5 forward-probe); no M4 change
(reorders, adds nothing). NEVER-OOM: zero.

### P4 — the periodic-spike diet *(complaint 2’s deterministic half)*

- **(a) `FP_SNOW_SMEAR`:** snowfall `STEP_SECONDS` 0.5 → 0.125 with `MAX_COLUMN_UPDATES` 32 → 8 and
  `MAX_CELL_WRITES` 32 → 8 (`snowfall_system.gd:22-27`) — identical steady-state throughput,
  ¼ the per-event spike; the fixed-step determinism contract is preserved (same writes, finer
  slicing; `MAX_STEPS_PER_FRAME` guard unchanged). Ship only if T2f measures the step ≥ ~8 ms.
- **(b) capture hygiene, final form:** keep the 2 s cadence but (i) stamp `cap=1` into the window’s
  telemetry (T2f) so analysis and the §6 metrics *exclude* capture windows by construction, and
  (ii) run all A/B metric sessions with `?frames=0` (the switch exists,
  `remote_bridge.gd:268-292`). The skip-gate’s good-window bias (§1.5) currently *manufactures*
  alternation in every dataset we judge by — this is a measurement-integrity fix as much as a perf fix.

### P5 — conditional / engine-side follow-ups (only on T2a evidence)

- **(a) `mesh_block_size` 32→16 A/B** (WALK-PERF L6, unparked): 8× smaller apply quantum directly
  attacks `apply_worst_ms` overshoot; the atlas already collapsed the per-draw material cost, so
  the old 204-draw wall may not return — that is exactly what the A/B measures (draws vs worst).
  One-line sed + deploy. Judge on E1/M1 vs draws.
- **(b) engine receive cap:** bound `process_async_tasks`’ per-frame completed-task dequeue
  (`voxel_engine.cpp:288-315`) to N=64/frame. Only if T2a shows `received`-heavy worst frames
  surviving P1. ~5 lines in the existing patch set.
- **(c) apply byte budget:** if `upload_bytes` (T2a) shows single-frame multi-MB uploads surviving
  P1+P5a, add a per-frame byte budget beside the ms budget in the time-spread runner
  (Sodium-style, WALK-PERF §6). Park until priced.

### Explicitly NOT doing

- **R4 cancellation patch** — demoted (§2.3): the per-stale-task waste fell ~50× with the port;
  measured stale arrivals are negligible (423 drops / 1.8 h). Re-open only if T2a shows receive
  cost from dead blocks.
- **Worker-count changes, budget-knob-as-fix (6→2/12), more viewers, VoxelLodTerrain, WebGPU-now,
  64³ mesh blocks** — all previously adjudicated, verdicts unchanged (WALK-PERF §3/§4; the 64³
  NO-GO note now has a mechanism: it was an apply-quantum pathology, which P5a moves the *right*
  direction instead).
- **Gen-side micro-optimization of the C++ generator** — supply ≥ demand at every speed measured;
  further gen speed buys nothing the eye can see (Amdahl: the visible path is apply-bound).

---

## 5. The STREAM-SCHED R-plan, re-adjudicated post-port

| item | pre-port role | post-port verdict |
|---|---|---|
| T1 per-class gen timer | shipped, decisive | **dead under FP_CPPGEN** — revive in C++ (T2c) |
| R1 `FP_COLBULK` / R7 `FP_STAMP` | rejected by ship rule; kept OFF | stay OFF; the port removed their reason to exist (the VM multiplier). The unexplained 11.2 s R1-ON freeze is moot but its root cause (likely the same apply-burst class, amplified) is now *explained by this doc’s model* |
| R2 `FP_LAZY_NB` | demand shaper | **superseded by P1** — the F-gate is R2 generalized (it paces *all* non-imminent volume by pipeline pressure, not just neighbour ramps) |
| R9 `FP_IDLE_LEAD` | cheap, valid | **promoted** into P3a with backlog := F |
| R4 cancel patch (was “patch 0007”) | +10–30 % effective supply | **demoted** (§2.3; also its patch number was taken by the generator port) |
| R5 sprint shed | sprint overload valve | **shelved** — “moving fast >8” windows measure M1 = 0.3 % (§1.2: fast movement over warm/backstopped terrain is *fine*); revisit only if flying over cold terrain regresses post-skin |
| R6 gaze viewer | crosshair priority | **replaced** by P3b (apply-order gaze weighting, zero added demand) |
| R3 skin tier | THE post-L5 item | unchanged, in flight (task #8; `sample_columns` landed, patch 0008). Complementary: the skin shrinks what a hole costs; P1–P3 shrink how often holes and freezes happen |

---

## 6. Measurement protocol (SW-1C) and ship rule

Route: SW-1 (STREAM-SCHED §8) **plus a scripted 6-crossing leg at walking speed** (the crossing
complaint needs ≥10 crossings/arm for C1’s p50 to be stable; the 16:46 run is the template).
Integrated, unconditioned, capture-excluded (`cap=1` windows dropped; or `?frames=0` runs).
**Interleave A/B arms in one session** (A-B-A-B), never sequential sessions — §1.5’s host drift is
larger than most expected wins.

| metric | definition | baseline (S3 walk leg) | target |
|---|---|---|---|
| **M1** | % windows worst>100, whole route | **13.5 %** | ≤6 % |
| **M2** | fps p10, unconditional | **16** | ≥25 |
| **C1** | per-crossing max worst_ms in ±2 s, p50 (n≥10) | **343 ms** | ≤150 ms |
| **E1** | fps-bucket (60/45/30/20/10) transitions per minute | **129** | ≤70 |
| **E2** | fps stddev over route windows | **15.8** | ≤9 |
| **M4** | ∫vox_gen dt + time-to-drain after stops | (guard) | no regression >10 % |
| **M4b** | ∫(vox_mesh + vox_main) dt | new | monotonically ↓ with P1 |
| **M5** | forward-probe hole windows | (guard) | no regression |

Ship rule unchanged: an item lands only if its named kill metric improves and no other M regresses
>10 %. The L4b lesson stays load-bearing: E1/E2 exist precisely so a config cannot buy “smoothness
while streaming” by streaming forever.

---

## 7. Explicit verdicts on prior framings

| framing | verdict |
|---|---|
| “The apply queue is empty; the 6 ms budget is idle machinery” (WALK-PERF §1.4, MESH-PACING) | **Was true, now false.** Correct pre-port measurement; the port un-idled it. `vox_main` spikes to 87 inside the worst frames (§1.4). The *governor* claim (“budget throttles nothing”) flips accordingly: the budget now throttles the visible path, and its per-task overshoot is why bursts freeze. |
| “Crossing freeze = post-crossing GEN burst” (CROSSING-FASTGEN, obs-2) | **Half-dead.** The gen burst is now a ~1 s worker grind with modest frame impact; the freeze core is the apply/upload burst + the §2.2c zero-queue stall. |
| “Supply < demand, always — design for permanent scarcity” (STREAM-SCHED headline) | **Inverted.** Supply ≥ demand at every measured speed; the scheduler’s job is now *rate-shaping into the main thread*, not scarcity triage. |
| “phys_ms inflation = SMT oversubscription while workers grind” (WALK-PERF §2.9) | **Survives, attenuated** — same signature (3.4→17.8) confined to the ~1 s bursts. Not worth a worker-cap revisit (L4b verdict stands); P1 shortens the bursts instead. |
| “transform re-place is the crossing spike” (FIXED-FRAME docs) | **Confirmed fixed** — `transform_ms = 0` in all 22 event records. The remaining spike is a different mechanism (§2.1). |
| “worst_ms is the only trustworthy web load signal” | Stands; extended: `worst_ms` windows are polluted by our own capture in bridge sessions — `cap`-marking (T2f) is required for honest numbers. `vt_*` additionally has the single-terrain blind spot (§2.2c). |

---

## 8. Risks and honest caveats

| risk / caveat | exposure | mitigation |
|---|---|---|
| §2.2c mis-attributed (far-ring innocent; stall is GC or receive) | P2c aimed wrong | T2e/T2a run FIRST; P2c ships only on conviction |
| Host throttling contaminates every A/B | phantom wins/losses | interleaved arms, same-session, capture-excluded (§6); report floor_p10 alongside |
| n = 11 crossings, one route, one laptop | fragile baselines | C1 defined at p50 over ≥10 crossings/arm; re-baseline per session |
| P1 over-throttles fill (pop-in returns) | M4/M5 regression | hysteresis 192/64; imminent slot keeps its floor; M4 guard auto-rejects |
| P2a prefill-128 memory transient | NEVER-OOM | gated on the T2a heap instrument (task #5 finally lands); explicit ≤+20 MB one-slot ledger; bounds-clamp already binds |
| P3b priority scan cost in the runner | main-thread ms | queue ≤~100 under P1; O(n) scan ≈ µs; measured by T2a’s timespread_ms |
| Deployed-flag uncertainty (FARRING_FAST/ASYNC, ORBITAL_SKY, CPPGEN) | this doc’s §2.2c reasoning + any A/B provenance | T2d is 5 lines; do it in the next deploy regardless of everything else |
| The capture skip-gate has been biasing *all* recent worst-frame datasets toward alternation | past conclusions drawn on polluted evenness | none retroactively; `cap=1` + `?frames=0` going forward; re-derive evenness baselines after T2f |
| gen telemetry blind under FP_CPPGEN until T2c | port regressions invisible | T2c rides the T2a rebuild; until then keep one GDScript-gen canary session per deploy |

### The one-paragraph verdict

The port did exactly what was promised and the residual is a *different* system: a bursty producer
feeding an unpaced, FIFO, main-thread consumer over a synchronous-upload GL. Every remaining
complaint — crossing freezes, uneven walking, “where is the CPU going” — is a view of that one
mechanism plus two self-inflicted periodic spikes and a throttling laptop. The fix is not more
speed anywhere; it is **admission control keyed to the apply stage (P1), spreading the two
crossing-shaped bursts (P2), and ordering applies by where the player is looking (P3)** — with one
small instrument batch (T2) bought first so that, for the first time, the main thread’s worst
frame can name its owner.
