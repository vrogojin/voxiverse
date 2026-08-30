# COSMOS-PERF-ENGINE-DEEP-DESIGN — the WASM gen/alloc convoy, and how to actually kill it

Date: 2026-08-23. Author: Fable deep-perf investigation (branch deploy/perf-plus-sky worktree).
Scope: INVESTIGATION + ROADMAP only — no gameplay code. Companion evidence:
`docs/COSMOS-WALK-PERF-DESIGN.md`, `docker/engine/patches/godot/0002-web-malloc-option.patch`,
`docs/COSMOS-FP-M2-HEAP-AB.md` (§1.1 heap ceiling), memory files
`voxiverse-walk-perf-root-cause`, `voxiverse-mimalloc-reab-rejected`, `voxiverse-fall-mesh-stall`,
`voxiverse-orbit-perf-farring-churn`, `voxiverse-prebake-pacing-p7`.

---

## ⛔ MEASURED OUTCOME 2026-08-23 — mimalloc-FIT REJECTED (§0 below is SUPERSEDED)

The §0 recommendation was **built and measured live, and it FAILED.** The arena-reserve cap (128→16 MiB) was
compiled into the live web template (all build plumbing verified — served `index.wasm` byte-match, fresh relink)
and A/B'd with a consent-gated de-orbit fall:

- **mimalloc-FIT peak heap = 842 MB** (@ alt 94, near-field descent flood) vs **dlmalloc 412 MB** → **+430 MB =
  3.6× the +120 MB NEVER-OOM ceiling**, and **~identical to the UNCAPPED mimalloc peak (~834)**.
- The cap trimmed only the **rest/idle** heap (834→706), **not the peak.** WHY the §2.2 analysis was wrong:
  `arena_reserve` is the per-step *size*, not the total. At peak flood demand the allocator needs its full
  per-thread working set across the 24-worker pool (~+420 MB) regardless of step granularity. The +422 MB is
  **real mimalloc segment/thread-heap working set**, not arena-stepping slack.

**Decision: dlmalloc stays; mimalloc (FIT or not) cannot fit NEVER-OOM. The −23 % walk-frame win is unbuyable
within the memory ceiling.** Live was reverted to dlmalloc + redeployed. `versions.env WEB_MALLOC=dlmalloc`; the
guarded FIT block in `build-engine.sh` is dormant + kept as a record ([[voxiverse-mimalloc-fit-build]],
[[voxiverse-mimalloc-arena-root]]).

**Re-prioritized roadmap** (allocator swap is OFF the table): **C-lite** — re-gate the de-orbit near-field
view-regrow flood on a *freeze-independent* airborne-descent signal (`offsurf && alt-decreasing`, not the
ATMO-frozen `_fall_vy_ema` that broke attempt #2, §4.c) → **B** godot_voxel gen **admission control** (engine
patch 0015: cap concurrent GenerateBlock so the flood can't saturate the pool → bounds the convoy at the source,
which is the ONLY lever that helps now that the allocator is fixed) → **D** gen-path alloc diet (fewer heap ops
per block = less lock pressure, profiling-gated). These attack the convoy's *rate/volume* instead of its
*allocator*, and none touch heap ceiling.

---

## 0. Executive verdict — lead recommendation  ⚠️ SUPERSEDED — see MEASURED OUTCOME above

**Ship mimalloc with the wasm32 arena-reserve default capped.** The P6 mimalloc rejection
(+398–422 MB heap) was **misattributed**: the heap blow-up is NOT "per-thread segments ×
WEB_PTHREAD_POOL=24". Measured inside the pinned emsdk 3.1.64 toolchain image, the vendored
mimalloc (v2.1.2) uses **4 MiB segments on wasm32** — per-thread cost is small — and the real
driver is the 32-bit **`arena_reserve` default of 128 MiB per arena growth step**, allocated
via `emmalloc_memalign` on sbrk where *reserve == committed real linear memory that never
shrinks*. +422 MB ≈ 3 × 128 MiB arena steps + alignment + live-thread segments. Capping
`arena_reserve` to 16 MiB is a **one-line toolchain sed + ~4 min warm template rebuild**, with
a predicted steady baseline of ≈ +60–100 MB — inside the +120 MB NEVER-OOM ceiling, tight
enough that the measured heap A/B gate decides, not this prediction.

The frame win is already causally proven on the walking workload (worst_ms p50 **−23%**, L2
A/B), and the de-orbit 2–3 fps stall is the same mechanism at 10× amplitude (frame_ms tracks
vox_gen 1:1; recovery is instant at vox_gen→0). This is the only candidate that attacks the
shared root cause of every streaming stall at once, at config-level cost.

Ranked roadmap: **A** mimalloc-FIT (this) → **C-lite** fall-flood re-gate on a
freeze-independent signal (GDScript, parallel, days) → **B** godot_voxel gen admission control
(engine patch, only if A+C-lite leave a residual) → **D** gen-path alloc diet (profiling-gated).
WebGPU fork: **rejected** (RED, §4.d). WEB_PTHREAD_POOL reduction: **rejected as a heap lever**
(§2.3 — it was never the driver).

---

## 1. Synthesis — one root cause, three stalls (thesis test)

### 1.1 The mechanism, stated crisply

> On the threaded web export, **frame time is not a function of main-thread work — it is a
> function of concurrent worker allocation activity.** Every `malloc`/`free` in the process
> serializes through emscripten dlmalloc's ONE global lock. The browser main thread is
> forbidden from `Atomics.wait`, so a contended lock on main **busy-waits inside the rAF
> callback**. Any burst of `GenerateBlock` tasks turns N workers into N lock contenders and
> the main thread into a spinner: all main-thread buckets inflate *uniformly* (they all
> allocate), and the frame recovers the instant the burst drains.

The voxel gen path performs ~500–2000 heap ops per generated block (patch 0002 preamble), so
`vox_gen` backlog is a direct proxy for lock pressure.

### 1.2 Evidence per stall

| Stall | Convoy signature | Key numbers | Allocator-dominant? |
|---|---|---|---|
| **Walk streaming** (2026-07-17, L1/L2) | 6/6 workers ACTIVE on GenerateBlock yet ~40 blocks/s out (≈1–1.5 workers' effective throughput — the pool runs full-width and every thread crawls); unchanged physics code phys_ms 4.3→44.5 while workers busy; drain↔worst_ms r=−0.47 (bidirectional = shared serializer); movement itself FREE (moving gen-idle p50 23.4 ≈ standing 23.2) | mimalloc A/B: worst_ms p50 **−23%** — causal confirmation | **YES** (proven) |
| **De-orbit atmosphere entry** (2026-08-23) | Approach-anchor viewer re-grows view 0→128 → **6–7k GenerateBlock flood**; frame_ms tracks vox_gen **1:1**; EVERY main-thread bucket uniformly inflates; instant recovery at vox_gen→0; vt_total <1 ms (not mesh/apply), t_stream 17 ms (not the GDScript tail) | 2–3 fps for ~20 s at alt ~870→450; two GDScript view-gating fixes FAILED (stale `falling_fast` at the ATMO-freeze crossing, §4.c) | **YES** (mechanism-matched; mimalloc never A/B'd on this workload — the ship gate includes it) |
| **Prebake fine-map grind** (P7) | Same *shape* (4 C++ bakers at 100% duty, all main buckets 2–3×, proc_ms 91 vs 25) but mimalloc A/B at orbit = **WASH** while the grind ran; fixed by PACING+SCOPING (worst frame 147→43 ms, PR #79) | Residual hitches ~2.3/s → ~0 post-P7 | **NO — bandwidth convoy**, same family, already mitigated |

### 1.3 Thesis verdict

**CONFIRMED for walk + de-orbit, with one honest refinement.** The walk stall and the de-orbit
flood share the allocator convoy as dominant cost — same signature (uniform main-bucket
inflation, frame ∝ worker activity, instant recovery on drain), and the allocator's causal role
is proven by the −23% mimalloc delta on walk. The prebake grind is *convoy-adjacent* (worker
activity starving main) but its serializer is memory bandwidth + large-buffer traffic, not the
malloc lock — mimalloc did nothing for it, pacing killed it. It is listed here so nobody
re-spends the allocator lever on it.

The remaining unacceptable stalls therefore reduce to ONE root cause:
**unbounded GenerateBlock concurrency × single-lock allocator × main-thread busy-wait.**
Two attack axes follow: replace the allocator (A), and bound the flood (B/C).

---

## 2. The decisive new finding — the P6 heap veto was misattributed

### 2.1 What P6 concluded vs what the toolchain actually contains

P6 (`voxiverse-mimalloc-reab-rejected`) measured heap_mb 412.3 (dlmalloc) → 810–834 (mimalloc),
Δ +398–422 MB vs the +120 MB ceiling, and attributed it to *"mimalloc reserves per-thread
segments × WEB_PTHREAD_POOL=24 preallocated Web Workers"*. Inspected 2026-08-23 inside the
pinned toolchain image (`voxiverse/godot-build:4.4`, emsdk 3.1.64 — mimalloc is **vendored** in
`system/lib/mimalloc`, not a port, `MI_MALLOC_VERSION 212` = v2.1.2, built by
`tools/system_libs.py::libmimalloc` with `-DMI_MALLOC_OVERRIDE -DMI_DEBUG=0`):

1. **Per-thread segments are 4 MiB on wasm32, not 32 MiB.**
   `include/mimalloc/types.h:162-166`: `MI_SEGMENT_SHIFT = 7 + MI_SEGMENT_SLICE_SHIFT` when
   `MI_INTPTR_SIZE ≤ 4` → 4 MiB (the 32 MiB figure is the 64-bit branch). A thread's first heap
   touch costs ~4 MiB, and *preallocated-but-never-started* pool workers have no heap at all.
   24 workers, even all live, explain ≲ ~100 MB — nowhere near +422.

2. **The real driver: `arena_reserve` = 128 MiB per growth step on 32-bit.**
   `src/options.c:86-90`: `#if MI_INTPTR_SIZE>4 → 1 GiB … #else → { 128L * 1024L KiB }` =
   **128 MiB** reserved *at a time* whenever mimalloc grows an OS arena.

3. **On wasm, "reserve" is real, permanent memory.**
   `src/prim/emscripten/prim.c`: mimalloc sits on **emmalloc on sbrk**; `_mi_prim_alloc` calls
   `emmalloc_memalign` (`config->has_overcommit = false` — commit flag meaningless, the full
   reservation is materialized in `wasmMemory`), `_mi_prim_decommit` is a **no-op**
   (`*needs_recommit = false`), and sbrk never shrinks. Additionally each 128 MiB arena is
   4 MiB-*aligned* via memalign, adding slack per step.

So: 810 − 412 ≈ 398 MB ≈ **3 × 128 MiB arena steps + alignment + (live threads ≈ 14) × 4 MiB
segments**. The observed later drift 810→834 (+24 MB = 6 × 4 MiB) is consistent with additional
segment allocations, not arena steps. The mechanism is *arena granularity*, not thread count.

### 2.2 Why this changes the verdict

The P6 frame conclusion stands (walk win real, orbit wash). The P6 *heap* veto also stands —
against the **default-tuned** build. But the default is tunable at three levels, cheapest first:

- **Build-time default sed** (recommended): change the 32-bit `arena_reserve` literal in the
  toolchain image's `options.c` and rebuild `libmimalloc-mt.a`. Deterministic, pinned,
  version-controlled via our Docker layer + `versions.env`. This is the ship vehicle.
- **Runtime env**: `_mi_prim_getenv` exists (`prim/emscripten/prim.c:180`, backed by emscripten
  `getenv`/JS `ENV`), so `MIMALLOC_ARENA_RESERVE=16384` (KiB) is honoured — `arena_reserve` is
  first read at the first arena growth, well after runtime init, so latching order is safe.
  Useful for fast A/B iteration (sed the exported `index.js` ENV block, no rebuild), NOT the
  ship vehicle (brittle against export regeneration).
- **Secondary knobs** if the gate is missed by a little: `eager_commit_delay` 1→4 (first N
  segments per thread committed per-page on demand — trims the per-thread 4 MiB upfront),
  `max_segment_reclaim` (cross-thread segment reuse), arena 16→8 MiB.

### 2.3 WEB_PTHREAD_POOL: answered and closed

The task asked whether lowering the pool 24→N shrinks mimalloc's baseline proportionally.
**No.** Per-thread cost is ~4 MiB (wasm32 segments), so even 24→8 saves ≲ 64 MB *worst case*,
and idle preallocated workers cost mimalloc nothing. Meanwhile the pool ledger
(`versions.env`: voxel ≤ 10 [patch 0005 clamps web hw-concurrency to 14, `threads/count/ratio
0.7` → N=6 live on the hw=8 reference client] + WTP 5 [`worker_pool/max_threads.web=5`, the 4
C++ tile bakers] + audio/IO/spare ≤ 3 ⇒ ~18 worst case) leaves real exhaustion risk below ~18
— and pool exhaustion on web is a **blank-world deadlock** (project.godot:56 history). Verdict:
**keep WEB_PTHREAD_POOL=24**; do not spend risk budget on ≤ 64 MB that the arena fix dwarfs.
(Optional, only if the heap gate misses by < 40 MB: trim 24→18 with the ledger as floor.)

### 2.4 Predicted heap (to be replaced by measurement)

steady ≈ dlmalloc-equivalent working set (412) + live threads (~14) × 4–8 MiB segments +
arena slack (≤ 2 × 16 MiB) + metadata ≈ **470–510 MB ⇒ Δ ≈ +60–100 MB** vs the 412.3 dlmalloc
baseline. PASS is plausible but **tight** — and the fall-flood transient may pin extra arenas
permanently (sbrk high-water). Hence the gate below measures **peak, on the flood workload,
not just steady-state**. If the flood pins > +120 MB, that is a genuine reject (again) and the
roadmap falls through to B/C.

---

## 3. Candidate deep fixes — evaluation

### a. mimalloc-FIT — tuned-arena mimalloc inside the +120 MB ceiling  ⟵ **#1 pick**

| Axis | Assessment |
|---|---|
| Feasibility | **HIGH.** Toolchain-level: Docker layer sed of the vendored `options.c` 32-bit `arena_reserve` literal (guarded — fail the build if the pattern is absent) + clear the emscripten cache so `libmimalloc-mt.a` rebuilds + `WEB_MALLOC=mimalloc`. Engine patch 0002 (scons `malloc=` option) is already merged and inert; the flip is one `versions.env` line. |
| Expected gain | Walk worst_ms p50 **−23% (proven, L2)**. De-orbit flood: mechanism-matched, expected large, **unproven** — the ship gate A/Bs it. Orbit: wash (proven, P6) — no regression expected. Helps every future streaming feature for free. |
| NEVER-OOM | Predicted Δ +60–100 MB (§2.4) vs ceiling +120 MB — **measured peak gate decides** (§5). Deterministic signal (`heap_mb` = wasmMemory.byteLength, reproduced byte-exact in P6). Revert = `WEB_MALLOC=dlmalloc` + rebuild. |
| Risk | LOW-MED: (1) gate is tight — mitigation ladder §2.2; (2) small arenas → more emmalloc-level growth events → sbrk fragmentation (bounded: 16 MiB granularity ≈ 26 steps to +422's footprint, each reusable after free); (3) cross-thread free traffic (gen workers allocate → main frees) exercises mimalloc's deferred-free path — covered by the frame A/B. |
| Build cost | ~3.5–4 min warm web-template rebuild (P6 measured); no native rebuild (FLAT gate untouched — WEB_* affects web templates only). |

### b. godot_voxel generation admission control (engine patch 0015)

Cap the *flood*, not the lock: a per-tick admission budget on GenerateBlock dispatch inside
`VoxelEngine`/the streaming dependency (e.g. max N tasks handed to the pool per frame, or
paced view-box growth inside `VoxelTerrain` itself so a 0→128 view change becomes an internal
staged sequence). Feasibility MED — moderate C++, cumulative-patch convention
(`docker/engine/patches/godot_voxel/`, next slot 0015), byte-off behind an FP_ flag routed
through a project setting. Gain: bounds the *worst case* structurally — no GDScript caller can
ever flood again; still valuable **after** mimalloc (6–7k tasks of real gen work churn cache
and workers even with a scalable allocator). Risk MED: under-admission starves legitimate
streaming (the FP_REENTRY tuning showed 128/4 made things *worse*); needs a backlog-aware
controller, and the engine has the true queue state (`get_stats().tasks.generation`) with no
staleness problem — exactly what the GDScript attempts lacked. Cost: ~24 min cold / minutes
warm rebuild + gate work. **Rank #3 — hold until A + C-lite measure out.**

### c. Reduce the generated block VOLUME during fast motion

Why the two GDScript attempts failed (must not repeat): both gated on
`falling_fast = _fall_vy_ema < -ENV_FALL_HOLD_VY`, but **`_fall_vy_ema` is FROZEN above
ATMO_TOP (FP_ALT_REGIME)** — at the exact atmosphere-entry crossing where the view re-grows,
the signal is stale/false, both the DEFER hold and the backlog gate bypass, and the full flood
fires before the EMA catches up (4-run live A/B: 3/4 runs flooded 5727–7531 ≥ baseline).

- **C-lite (do this, rank #2): GDScript re-gate v2 on a freeze-independent airborne-descent
  signal** — `offsurf && altitude-decreasing` (both live in every regime) — so the gate engages
  AT the crossing and releases when grounded (preserving the reviewer's walk-wedge fix). Days
  of work, no rebuild, reuses the shelved FP_REENTRY_BACKLOG_GATE machinery (branch
  perf/fall-mesh-stall, 2d391fb) with only the gating predicate swapped. Independent of A and
  worth having even if A ships (less work is less work).
- **C-full (engine-side)**: subsumed by (b) — the engine-internal version has no
  signal-staleness class of bug because it reads its own queue.

### d. Everything else the evidence touches

- **WebGPU fork migration: REJECTED.** Definitive RED (`voxiverse-webgpu-fork-spike`): on
  emscripten the fork's wgpu is permanently WebGL2 (no `navigator.gpu` backend), real WebGPU
  needs a multi-month Dawn re-architecture duplicating Godot's official proposal. Not a perf
  lever for this engine generation.
- **emmalloc** (`-sMALLOC=emmalloc`): also one global lock, no per-thread heaps — does not
  address the convoy. Skip.
- **Gen-path alloc diet (rank #4)**: the convoy input is ~500–2000 heap ops/block. The C++
  generator port (patch 0007, FP_CPPGEN) already cut GDScript-side churn; nobody has *counted*
  its remaining per-block allocations. A profiling pass (count allocs in `generate_block` via
  a debug counter build) then thread-local buffer reuse where hot. Helps under ANY allocator;
  strictly after A ships, only if residual walk jank persists.
- **SharedArrayBuffer / memory growth**: already configured (`-sWASM_MEM_MAX=2048MB`); growth
  with SAB works and is not the bottleneck. No action.
- **More/fewer workers**: settled — more workers add convoy contenders (FP-M1b bought nothing);
  the worker ratio is already smoothness-tuned (project.godot `threads/count`). No action.

---

## 4. Roadmap (ranked) and the #1 first step

| # | Item | Vehicle | Cost | Gate |
|---|---|---|---|---|
| 1 | **A. mimalloc-FIT** | toolchain sed + versions.env flip | ~4 min warm rebuild + A/B session | §5 heap peak ≤ +120 MB AND walk win AND fall no-worse |
| 2 | **C-lite. fall-flood re-gate v2** | GDScript, reuse 2d391fb, swap predicate to `offsurf && alt-decreasing` | days, no rebuild | verify_reentry_pace + live 4-run flood A/B (vox_gen bound < 2000, fps floor ≥ 15) |
| 3 | **B. gen admission control** | godot_voxel patch 0015, FP_ flag | C++ + ~24 min cold rebuild | only if 1+2 leave fall/new floods; byte-off + FLAT 6042/0 |
| 4 | **D. gen alloc diet** | profile-then-patch | profiling first | only if residual walk jank post-A |

### 4.1 The #1 first concrete step (exact)

1. `docker/engine/` toolchain layer (Dockerfile or a `build-engine.sh` pre-step, matching the
   existing pin discipline): before any web scons run,
   - sed `/emsdk/upstream/emscripten/system/lib/mimalloc/src/options.c`
     32-bit branch `{  128L * 1024L, UNINIT, MI_OPTION(arena_reserve) }` →
     `{  ${WEB_MIMALLOC_ARENA_RESERVE_KIB}L, UNINIT, MI_OPTION(arena_reserve) }`,
     **guarded**: `grep -c` the exact original pattern first, hard-fail if ≠ 1 (emsdk bump
     canary);
   - purge the emscripten cache copies of `libmimalloc-mt.a` (and `libmimalloc*.a`) under
     `/emsdk/upstream/emscripten/cache/sysroot/lib/wasm32-emscripten/` so embuilder recompiles
     from the seded source.
2. `docker/engine/versions.env`: add
   `WEB_MIMALLOC_ARENA_RESERVE_KIB=16384` (with a WHY comment citing this doc §2) and flip
   `WEB_MALLOC=mimalloc`.
3. `scripts/build.sh` (SKIP_LINUX=1) → warm web-template rebuild (~4 min) →
   `scripts/export-web.sh` → deploy via the deploy_cheats flow.
4. Run the §5 A/B. Decision rule:
   - heap PASS + walk win + fall no-worse ⇒ **ship** (mimalloc stays; update
     `voxiverse-mimalloc-reab-rejected` memory to superseded);
   - heap FAIL by < 40 MB ⇒ retry with arena 8192 KiB + `eager_commit_delay` 1→4 (same sed
     mechanism, `options.c:76`), optionally pool 24→18 (ledger floor §2.3);
   - still FAIL ⇒ revert `WEB_MALLOC=dlmalloc`, record the peak decomposition, promote B+C-lite
     to the whole plan.

### 4.2 Discipline

- FLAT `verify_feature` 6042/0 is structurally unaffected (allocator/pool are web-template
  knobs; the linux editor build is untouched) — still run it as the standing gate.
- All behavioural changes byte-off behind FP_ flags (C-lite, B). The allocator itself has no
  FP_ flag — its "flag" is the `versions.env` pin with the documented revert knob, per the
  patch-0002 convention.
- **NEVER-OOM outranks frame time.** The heap gate is the ship gate; a frame win cannot
  override a heap FAIL. Ceiling: steady AND peak Δ ≤ +120 MB over the 412.3 dlmalloc baseline
  (`docs/COSMOS-FP-M2-HEAP-AB.md` §1.1 ⇒ absolute ≤ ~532 MB).

---

## 5. A/B measurement protocol (heap AND frame)

Hard-won methodology (from `voxiverse-fall-mesh-stall`, `voxiverse-mimalloc-reab-rejected`,
`voxiverse-prebake-pacing-p7`) — deviations produced garbage twice, follow it exactly:

- **Fresh browser** each arm (accumulated state poisoned P6's first run). Capture the dlmalloc
  baseline arm FIRST on the current live build before overwriting.
- **Warm before measuring**: park frozen at orbit until `fm_baked` plateaus AND
  `bg_inflight → 0` (~1–2 min) — `vox_gen` is a GLOBAL counter and the whole-planet prebake
  competes for the same workers.
- **Three workloads per arm** (all on the settled village scene, -39.506,-35.956):
  1. **Walk**: fixed walk route; metrics worst_ms p50/p90, fps, `heap_mb`.
  2. **Orbit**: `set_alt 2500` → freeze → 30 s settle → 40-frame window; warm-match `fm_baked`
     across arms; expect frame wash — this arm exists for heap + no-regression only.
  3. **Fall (the flood)**: establish orbit → freeze → warm → **release** (`freeze_player` off;
     a real ~38 b/s drag fall, ~60 1 Hz samples — `set_alt` unfrozen snaps to surface and
     measures nothing). Metrics: fps floor + stall duration inside the vox_gen>1000 window,
     frame_ms↔vox_gen coupling, and **peak `heap_mb` during the flood** (the NEVER-OOM
     number — sbrk high-water is permanent).
- **Signals**: `heap_mb` (wasmMemory.byteLength — deterministic, browser-leak-immune) and
  `frame_ms`/worst_ms + `vox_gen`. `proc_ms` is whole-frame on threaded web — ignore. Relay
  `telem_ms` inflates frame_ms — prefer the in-game PERF HUD for the headline worst-frame.
- **telemetry.jsonl accumulates across sessions** — filter to the contiguous tail after the
  last `fm_baked<5` reset.
- Repeat the fall arm ≥ 3× (run-to-run variance was the P6 trap; 1 of 4 runs fluked in the
  FP_REENTRY A/B).

**Pass criteria (ship gate for A):**
- NEVER-OOM: Δ`heap_mb` (steady AND flood-peak, all three workloads) ≤ **+120 MB** vs 412.3.
- Walk: worst_ms p50 improvement ≥ 15% (proven potential 23%).
- Fall: fps floor during the flood ≥ baseline (target: 2–3 → ≥ 10–15 fps; any regression
  rejects), stall duration not longer.
- Orbit: no regression beyond noise (warm-matched).

---

## 6. What this doc supersedes / corrects

- `voxiverse-mimalloc-reab-rejected` — heap *mechanism* corrected (§2.1): arena granularity,
  not per-thread × pool. Its veto remains valid **for the default-tuned build**; the reject
  becomes conditional pending the §5 re-A/B.
- The task-brief framing "lower WEB_PTHREAD_POOL to shrink mimalloc proportionally" —
  investigated and answered NO (§2.3); the pool stays 24.
- The prebake grind is NOT an allocator problem (§1.2) — do not re-spend the lever there;
  P7 pacing already holds it.
