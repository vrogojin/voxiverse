# COSMOS-FP-M2-HEAP-AB — the FP-M2e browser-heap A/B methodology + the ≤4-core degradation harness

Status: **validation methodology** for milestone FP-M2e (docs/COSMOS-FP-M2-DESIGN.md §11 NEVER-OOM
ledger, §13 "FP-M2e", §6.5 the load-adaptive controller). This document is the *procedure of record*
for the two live-deploy measurements that gate flipping `CubeSphere.FP_M2_LOD` default-ON:

1. **The browser-heap A/B** — FP-M1c baseline (flag OFF) vs FP-M2 (flag ON), proving the ON−OFF memory
   delta fits inside the §11 ledger caps (NEVER-OOM).
2. **The ≤4-core degradation run** — proving the controller reduces *streaming pace*, not *frame rate*,
   on a constrained machine.

The companion headless proxy for both is the soak driver `godot/src/tools/verify_fp_m2_soak.gd`
(the walk-the-planet driver, §12 gates). This doc says exactly what to measure, where to read it, and
what the pass criterion is — so the M2e sign-off is a checklist, not a judgement call.

> **Why a document and not just an assert.** The binding memory + frame-pacing numbers are WASM-heap /
> WASM-worker-timing phenomena that a native headless run cannot fully reproduce (native drains the
> voxel worker pool faster and has no `SharedArrayBuffer` heap). The soak driver measures the
> headless-*meaningful* half (the `vox_gen` backlog, the LOD ledgers, the pool-miss correctness) and
> prints a memory proxy; the numbers that ONLY exist on live web are captured by this procedure, by
> hand, against the live deploy at https://voxiverse.game-host.org.

---

## 0. Prerequisites

- The FP-M2 stack (M2b/M2c/M2d) landed and green on `feat/voxiverse-cosmos-m5`: `verify_faceted`
  (all FP-M1 + FP-M2 headless gates) and `verify_fp_m2` pass with `FP_M2_LOD` both OFF and ON, and
  FLAT `verify_feature` is **6027/0**.
- Two web exports built and deployable, differing ONLY in the export-time sed flip (the established
  deploy pattern, docs/COSMOS-FP-M2-DESIGN.md §0.8, §13):
  - **A / baseline**: `FACETED=true, FP_M1_POOL=true, FP_M2_LOD=false` (FP-M1c behaviour).
  - **B / candidate**: `FACETED=true, FP_M1_POOL=true, FP_M2_LOD=true`.
  - Repo consts stay committed OFF; the flip is a sed line at export only.
- A desktop Chromium-family browser with DevTools (for `performance.memory` + the WASM heap) and the
  ability to launch with `--enable-precise-memory-info` for un-bucketed `performance.memory` readings.
- The in-game **PerfHUD** (`godot/src/ui/perf_hud.gd`) visible — it already prints a `[PERF]` line every
  0.25 s with `worst` frame ms, `vmem` (`RENDER_VIDEO_MEM_USED`), and `vox backlog: gen/mesh`. This is
  the primary live instrument; the browser DevTools heap is the secondary (JS/WASM-heap) instrument.

---

## 1. What we are proving (the two pass criteria, up front)

### 1.1 Heap A/B pass criterion (NEVER-OOM, §11)

Deploy A, run the standard protocol (§2), record the steady-state + peak heap. Deploy B, run the
**identical** protocol, record the same. Then:

- **Steady-state ON−OFF heap delta ≤ +120 MB** over a ≥ 15-min soak (the §11 rule-of-force: pool
  −40 MB, LOD cache +96 MB cap, builder thread +2 MB → ceiling shift ≈ +58 MB, common case ≈ +30 MB;
  the +120 MB is the hard ceiling that INCLUDES the scripted telescope burst).
- **Slope flat**: the heap trace over the last 10 min of the soak has no upward drift (no leak) —
  linear-fit slope ≤ a few MB/min, indistinguishable from GC noise.
- **LOD ledgers never exceeded** (the hard, controller-independent caps, §11): `LOD_MAX_FACETS = 64`,
  `LOD_MAX_TRIS = 3_000_000`, `LOD_MAX_BYTES_MB = 96`. Read from `FacetLodMesher.stats()` (surfaced
  through the PerfHUD / a debug print, see the M2e-WIRE note §5).
- The LOD-mesh cache steady-state sits ≈ **50 MB** (design estimate: 8×ℓ1 + 16×ℓ2 + ~40×ℓ3,
  §11 / §1.3), well under the 96 MB cap (2× headroom).

If the delta exceeds +120 MB or the slope is non-flat, the flip does NOT ship: apply the NEVER-OOM
degrade dial (`POOL_D_WARM2` 48→0 to strict-Z1, or lower `LOD_MAX_*` caps, §11 / §3.3) and re-measure.

### 1.2 ≤4-core degradation pass criterion (§6.5, §13, risk #10a)

On a machine constrained to ≤ 4 logical cores, run the walk-the-planet path (§3). The controller
(`StreamLoadController`, §6.5) must keep the **frame rate at setpoint** by dropping **streaming pace**:

- **worst-frame ≤ `CTRL_FRAME_BUDGET_MS` = 18 ms for ≥ 99% of frames** STILL holds (PerfHUD `worst`
  histogram) — the same headline metric as the full-core run.
- **Pace visibly degrades instead**: facets hold a coarser LOD tier longer / promote slower; the
  imminent neighbour may go live later (larger `own_dist` lead consumed); under chronic overload the
  admission **credit pins low** and a crossing may ride the pool-miss ladder behind an existing LOD
  mesh (§9.1) — degraded but hole-free and honest (risk #10a). No frame-rate collapse, no blank, no
  console error storm.
- The `vox_gen` backlog stays bounded (≤ `CTRL_BACKLOG_MAX = 300`, the feed-forward gate holds
  full-res admission at zero until the pool drains, §6.5.3).

The contrast that proves it: on full cores the same walk converges *faster* (credit high, promotes
early); on ≤ 4 cores it converges *slower* but never jerks. Same frame-time histogram, different pace.

---

## 2. The heap A/B protocol (live web, per deploy)

Run this identically on deploy A and deploy B. Budget ≈ 20 min per deploy.

1. **Cold boot.** Load the deploy, confirm `crossOriginIsolated === true` in the console (COOP/COEP;
   the engine will not start threaded otherwise — the #1 web gotcha). Wait for the world to finish its
   initial mesh (PerfHUD `vox backlog: gen` drains to ~0). Record **boot heap** (§2.1).
2. **Steady idle (2 min).** Stand still on the spawn facet. Record heap every 30 s. This is the
   floor.
3. **Border-approach walk (10 min).** Walk the planet crossing ≥ 6 facet seams, INCLUDING one
   cube-edge seam and one corner approach (where the Z1-hybrid second live slot fires, §3.2). At each
   approach, dwell ~10 s near the ridge (inside `POOL_D_WARM`) so the pool/LOD layer fully populates,
   then cross. This is the motion that produced the logged jerk (§1.2) and the LOD layer's busiest
   state. Watch the PerfHUD `[PERF]` line: on B, `vox_gen` must stay ≤ ~300; on A it will spike
   1500–2800 (the problem being fixed). Record heap every 30 s.
4. **Scripted telescope burst (3 min).** (B only exercises the LOD selector; on A the far ring is
   static.) Zoom / fly to an altitude where the far limb fills the frustum, then sweep the camera
   across the limb so the SSE selector requests fine tiers for dozens of facets in sequence (§6.2
   telescope regime, risk #4). This is the memory WORST case — the caps must bind here. Record the
   **peak heap** and `FacetLodMesher.stats()` at peak.
5. **Return to idle (2 min).** Stop, let the LRU + idle-demote (`LOD_IDLE_DEMOTE_S`) reclaim. Record
   heap every 30 s — it should return toward the step-3 steady level (proves reclaim, no leak).
6. **Leak check (long tail).** Optionally continue the walk for a further 10 min; linear-fit the heap
   trace. Slope ≈ 0 is the pass.

### 2.1 Where to read each number

| Signal | Where | Notes |
|---|---|---|
| **JS heap used** | DevTools console: `performance.memory.usedJSHeapSize / 1048576` MB | Launch with `--enable-precise-memory-info` for exact (un-bucketed) values. Small for this engine (logic is WASM), but tracks GDScript-side growth. |
| **WASM linear heap** | DevTools: `<wasm module>.HEAP8.length / 1048576` or, in the engine, the `Module.HEAPU8.buffer.byteLength` — the true engine heap (voxel buffers, meshes, generators) | The BINDING number for the §11 ledger — the LOD cache + pool terrains live here. Watch it grow across step 3–4 and reclaim in step 5. |
| **GPU / video mem** | PerfHUD `vmem` (= `Performance.RENDER_VIDEO_MEM_USED`) | Mesh + texture VRAM. LOD meshes add GPU bytes ≈ ×1 the CPU array bytes (§11); this is where the ×1 GPU estimate is confirmed/updated. |
| **`vox_gen` / `vox_mesh` backlog** | PerfHUD `vox backlog: gen N mesh M` | The throughput proof; the A-vs-B headline. |
| **LOD ledgers** | `FacetLodMesher.stats()` → facets / tris / bytes | Must be ≤ caps at the telescope peak. See §5 M2e-WIRE. |
| **`crossOriginIsolated`** | DevTools console | Must be `true` (threaded export gate). |

### 2.2 The A/B table to fill in (sign-off artefact)

| Metric | A (FP-M1c, flag OFF) | B (FP-M2, flag ON) | B − A | Pass? |
|---|---|---|---|---|
| Boot heap (WASM) MB | | | | |
| Steady idle heap MB | | | | ≤ +120 |
| Walk steady heap MB | | | | ≤ +120 |
| Telescope PEAK heap MB | | | | ≤ +120 |
| Post-idle reclaimed heap MB | | | | returns toward walk-steady |
| Long-tail slope MB/min | | | | ≈ 0 (flat) |
| `vmem` (GPU) MB, walk | | | | LOD adds ≈ ×1 CPU cache |
| `vox_gen` backlog, approach | 1500–2800 | ≤ 300 | | B ≤ 300 |
| worst-frame ≤ 18 ms, % frames | | | | B ≥ 99% |
| LOD facets / tris / bytes, peak | n/a | | | ≤ 64 / 3 M / 96 MB |

---

## 3. The ≤4-core degradation run

Goal: force the controller into its throttling regime and prove pace (not frame rate) degrades.

### 3.1 Constraining the machine

- **Live web (the real gate).** Throttle the browser tab's available parallelism. Options, most to
  least faithful:
  - Launch the browser on a machine / VM with ≤ 4 logical cores, OR pin the browser process to 4
    cores at the OS level (`taskset -c 0-3 <browser>` on Linux; `cpulimit`/affinity tools elsewhere).
    The WASM `PTHREAD_POOL_SIZE` is fixed at 16 (FP-M1b), but the OS scheduler only has 4 cores to run
    them on, so the voxel workers contend exactly as on a 4-core client.
  - Chrome DevTools "Performance → CPU: 4× slowdown" is a coarser proxy (it slows the main thread, not
    just worker parallelism) — use only as a smoke check, not the sign-off.
- **Headless proxy (the CI-runnable half).** Pin the verify binary to 4 cores and run the soak
  driver; the native voxel worker pool then has 4 cores, so its DRAIN RATE falls and a fixed arrival
  backs up more — the same pressure the controller must throttle:

  ```bash
  taskset -c 0-3 docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
      --script res://src/tools/verify_fp_m2_soak.gd 2> stderr.log
  ```

  The soak prints the `vox_gen` peak/sustained and the drain-rate proxy; compare the 4-core run to an
  unconstrained run — the 4-core `vox_gen` should be higher for the SAME walk (less drain), which is
  precisely the load the live controller converts into slower pace rather than dropped frames.

### 3.2 What to record (live)

- PerfHUD `worst`-frame histogram: **≥ 99% ≤ 18 ms** must STILL hold (the invariant).
- The controller **credit trace** (§6.5) alongside worst-frame — credit should spend more time low on
  4 cores (pace throttled) than on full cores. (Read via the M2e-WIRE hook, §5.)
- Observed pace degradation, described concretely: which facets held a coarser tier, how long the
  imminent neighbour stayed LOD before going live, whether any crossing rode the pool-miss ladder
  (still hole-free). A promote that is *deferred* under load but completes without a jerk is the pass;
  a dropped frame or a blank is the fail.

---

## 4. The headless memory proxy (what the soak driver prints)

`verify_fp_m2_soak.gd` cannot read the WASM heap (there is none headless), but it prints a GDScript-side
memory proxy at boot, post-walk, and per metric window, so the A/B has a headless companion trace:

- `Performance.MEMORY_STATIC` (MB) — GDScript/engine static allocation.
- `OS.get_static_memory_usage()` (MB) — process static memory.
- `Performance.RENDER_VIDEO_MEM_USED` (MB) — the SAME `vmem` monitor the live PerfHUD reports (mesh /
  texture VRAM), so the headless and live GPU-mem numbers are directly comparable for the LOD layer.

These are a leak/growth SANITY proxy only — the binding NEVER-OOM number is the live WASM heap from
§2.1. A flat headless `MEMORY_STATIC` across the walk is necessary-not-sufficient; the live heap A/B
is the gate.

---

## 5. M2e-WIRE hooks (to be added by M2c/M2d, not by the harness)

The harness and this procedure reference two read-only accessors that do not exist yet. They are the
ONLY hooks M2e needs from the earlier stages; they are pure reads (no behaviour change, flag-gated):

- **`# M2e-WIRE (M2c)`** — `WorldManager.stream_load_credit() -> float`: expose the
  `StreamLoadController` admission credit ∈ [0, 1] (§6.5.3) so both the live PerfHUD credit trace and
  the ≤4-core degradation proof can log credit alongside worst-frame/backlog and assert credit falls
  (pace throttled) under constrained cores while worst-frame holds.
- **`# M2e-WIRE (M2d)`** — `WorldManager.lod_stats() -> Dictionary`: forward `FacetLodMesher.stats()`
  (covered-facet count, tris, bytes, build backlog) once FacetLodMesher is owned by WorldManager, so
  the heap A/B (§2.1 / §2.2) can assert the LOD ledgers stay ≤ caps at the telescope peak, and the
  soak driver can sample them per window.

Until these land, the soak driver logs only what already exists (`vox_gen`/`vox_mesh` via
`VoxelEngine.get_stats()`, pool-miss via `WorldManager.pool_miss_count()`, the memory proxies of §4),
and the live A/B reads the LOD ledgers from a temporary debug print in `FacetLodMesher` if the
accessor is not yet wired.

---

## 6. Sign-off checklist (the flip gate)

The `FP_M2_LOD` default-ON flip ships only when ALL of:

- [ ] §2.2 heap A/B table filled: steady + peak ON−OFF delta ≤ +120 MB, long-tail slope flat.
- [ ] `vox_gen` backlog ≤ 300 sustained on B at a border approach (vs 1500–2800 on A).
- [ ] worst-frame ≤ 18 ms for ≥ 99% of frames on B (full cores).
- [ ] LOD ledgers ≤ caps throughout, including the telescope burst.
- [ ] §3 ≤4-core run: worst-frame invariant holds, pace degrades (credit throttles), no blank / no
      error storm / hole-free crossings.
- [ ] The accepted-artifact set is SAID in the sign-off notes before default-ON (risk #9): player
      edits are invisible / healed at LOD distance; transient promote/demote megablock overlap
      bounded by the 20 s lifetime caps (§9).
- [ ] Reverted the export sed after measuring; repo consts stay committed OFF; the flip is the
      export-time line only.
