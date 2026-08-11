# COSMOS — Fast Fresh-Load: defer far-tier commits + background sims until the near view settles

**Status: DESIGN (research only — nothing here is implemented).** Task #103.
Author: Fable (perf architect). Tree: `deploy/cheats-eyeball`.
Prior art this extends: `docs/COSMOS-STREAM-PARALLEL-DESIGN.md` (Phase A `FP_DEM_DEFER`, shipped —
`g2_baked=0` through load confirms it works and is NOT the residual cause).

---

## 1. The measured profile, re-attributed

Live fresh-load window, 8-core browser: `proc_ms` 156-804, `worst_ms` 626, while the near field is
**cheap** (`vox_main ≈ 0`, `vt_total_ms ≈ 0.1`) and workers idle (`pbm_busy` 1/4, `pool_threads` 6,
`stream_credit = 0`). Per-target truth after reading the sources:

| Telemetry | Measured | What it actually is | Verdict |
|---|---|---|---|
| `smooth_v2_commit_ms` | **185.66** | `FacetSmoothV2._commit()` — ONE whole-annulus ArrayMesh rebuild (`facet_smooth_v2.gd:472-487`). NB: this gauge is the **last** commit's cost (`facet_far_ring.gd:2971`), and during the fill there is a commit on essentially **every reap** — see §2.1. | **Dominant, deferrable + fixable** |
| `env_converge_ms` | 29.58 | `FacetFarRing._surface_converge_emit` (`facet_far_ring.gd:1369-1371`) — the surface warm-converge driver: env-cache warm + progressive shell re-emit. Budget `WARM_BUDGET_MS = 3` (`facet_far_ring.gd:32`) is checked **before** each unit; a unit is a per-facet env build documented at 16-40 ms on web (`facet_far_ring.gd:1402-1404`). | **Deferrable to hold-mode** |
| `snow_ms` | 20-25 | `SnowfallSystem.process` on main from `WorldManager._process` (`world_manager.gd:760-766`). | **Deferrable** |
| `phys_ms` | 27.22 | `Performance.TIME_PHYSICS_PROCESS` (`remote_bridge.gd:625`) — the whole physics tick, **including** `update_streaming` (called from `player.gd`'s physics tick). Partially overlaps the other counters. | Leave (player/collider needed; overlap) |
| `tex_worst_ms` | 15.78 | FacetTexBaker worst frame. Base-tier coverage is needed at boot (the shell's colours); band/fine are already view-first-paced under `FP_BG_PREBAKE` (`fm_baked=0` confirms). | Mostly leave; small optional trim |
| `setpoint_ms` | 38.5 | **NOT A COST.** It is `StreamLoadController._setpoint_ms` — the *adaptive overload threshold*, `clamp(floor_p10 × CTRL_ADAPTIVE_MARGIN, 18, max)` (`stream_load_controller.gd:132-141`). 38.5 means the client's own frame floor during load was ~30+ ms, so the controller relaxed its threshold. Zero ms to reclaim; it is a *symptom* of the pile-up. | Re-attribute |
| `main_commit_ms` | 2.6-4.2 | JobLane bounded drain (`job_lane.gd:180-184`) — already rate-capped. | Leave |

Sum of the real deferrable main-thread items ≈ **230-250 ms on the worst frames** — matching the
observed `worst_ms 626` once GC/alloc churn and the engine's 6 ms apply budget stack on top.

### 1.1 The architectural inversion (why `stream_credit = 0` matters)

`StreamLoadController` cuts credit whenever `EMA(frame p90) > setpoint` (`stream_load_controller.gd:141-149`)
— and credit gates **only the near field** (pool spawns, view ramp). The far tiers and background sims
run **unconditionally** in `_process`/`update_streaming` and bypass the governor entirely. So during a
fresh load: far-tier commits stall main → controller sees overload → throttles *the near field* — the
one thing the player is waiting for — while the work causing the stall is never throttled. Classic
priority inversion. Deferral doesn't just remove stall ms; it lets credit recover, which **un-throttles
the near ramp** — a second-order win on time-to-usable.

---

## 2. Per-target root cause + fix (ranked by ms removed)

### 2.1 FacetSmoothV2 — the 185 ms (and why it's really O(N²) during fill)

Mechanics (`facet_smooth_v2.gd`):

* Tiles build **off-thread already** (WTP, `SMOOTH_BUILD_SLOTS` = cores−1 ≤ 8, `step():433-441` →
  `_build_worker:461-466`). The main-thread cost is entirely the **commit**.
* `step()` (`facet_smooth_v2.gd:400-444`) sets `_dirty` on every reaped tile and calls `_commit()` in
  the **same call** (line 442-444). With 6+ worker slots landing tiles during boot, the fill performs
  ~one commit per step-with-a-landing — up to ~36 commits.
* `_commit()` (`:472-487`) re-merges **every resident tile from scratch**: `merge_tiles`
  (`:205-227`) concatenates pos/nrm/col via native `append_array` (cheap memcpy) but shifts indices
  with a **per-index GDScript loop** (`for k in range(n): idx.append(tidx[k] + base)`, `:224-226`).
* Sizes: `V2_CELLS = 52` (`cube_sphere.gd:1388`) ⇒ per tile 53² + 4·53 skirt = **3021 verts**,
  52²·6 + 4·52·6 = **17 472 indices**. Annulus hop 2..4 under `FP_SMOOTH_V2_REACH`
  (`cube_sphere.gd:1389-1406`) = 8+12+16 = **36 tiles** ⇒ ~109 k verts, **~630 k indices**. 630 k
  GDScript iterations on web ≈ the measured 185 ms. Over the whole fill the merge work is
  quadratic-ish: Σ commits × (tiles so far) ≈ 18 full-annulus merges' worth.
* It runs from the very first boot frames: `_smooth_v2.step()` sits at `facet_far_ring.gd:1276-1277`,
  **above** the `FP_BOOT_ASYNC` boot-warm early-return (`:1292-1300`).

Three-part fix, each independently shippable:

1. **Settle-freeze (`FP_LOAD_DEFER`, Phase 1)** — the exact WS1a pattern `FacetOrbitRelief.step()`
   already proved (`facet_orbit_relief.gd:614-646`: reap ALWAYS — free the worker slot, land the tile,
   mark dirty — but skip recompute/dispatch/**commit** while suspended). Pre-settle, `FacetSmoothV2.step()`
   reaps and returns. No build dispatch pre-settle either — the worker seats belong to the near field's
   window. Removes the full 185 ms (and its alloc churn) from the load window.
2. **Commit pacing (`FP_SMOOTH_V2_PACE`, Phase 2)** — adopt the G3 rate-cap verbatim:
   `SMOOTH_V2_COMMIT_MS` (init 500, mirrors `ORBIT_RELIEF_COMMIT_MS`, `cube_sphere.gd:844`) between
   commits; dirty tiles simply accumulate. Converts the post-settle fill from ~36 commits into ~5-8.
   (No `COMMIT_TILES` cap needed — unlike G3's arena, every commit here is whole-surface anyway.)
3. **Off-thread merge (`FP_SMOOTH_V2_ASYNC_MERGE`, Phase 2)** — `merge_tiles` is a pure static
   (no Node/RenderingServer access, `:199-227`): dispatch it as one WTP task on a shallow
   `_tiles.duplicate()` snapshot (tiles are immutable once landed — the skirt mutation happens in
   `build_tile` before landing), reap the merged arrays next `step()`, and pay only
   `add_surface_from_arrays` + `mi.mesh =` on main — the SAFE high-level API, unchanged (the REV-7
   ANGLE/WebGL2 law at `facet_smooth_v2.gd:21-27` stays intact; **no** RenderingServer region calls).
   Canonical ascending-fid merge order is preserved ⇒ `G-V2-PURE` byte-equality is preserved.
   Expected residual main cost: **~10-30 ms per paced commit** (native surface build of ~630 k idx),
   ≤ 1 per 500 ms, only while the annulus changes (fill/crossing).

> Rejected alternative: per-tile arena slots with build-time index pre-shift (the G3 arena). It would
> cut the commit to pure memcpys, but slot order = arrival order breaks the canonical ascending-fid
> merge that `G-V2-PURE` asserts as byte-equality. Not worth re-proving the race-freedom theorem for
> ~15 ms when pacing + async merge already bound the cost.

### 2.2 env-converge — hold-mode pre-settle (~25 ms removed)

`_surface_converge_emit` already contains the needed mode: the `FP_ENV_FALL_HOLD` branch
(`facet_far_ring.gd:1410-1419`) runs **chord-only coverage** — dispatch only when a visible facet has
no cache at all, no env upgrade, no continuous re-emit, one 6·K² scan per held frame. That is exactly
the right pre-settle behaviour: the shell keeps first-cover (no horizon holes) but stops converging.
`FP_LOAD_DEFER` reuses it: `WorldManager` plumbs the load-hold alongside the existing
`set_fall_hold` plumb (`world_manager.gd:1156-1157`); the ring ORs `_fall_hold || _load_hold` at the
one test site. Post-settle the ordinary convergence resumes untouched (hold is documented as
"NOT converged — env resumes when the hold lifts", `:1414-1416`).

### 2.3 SnowfallSystem — settle gate (~20-25 ms removed)

Callsite `world_manager.gd:760-766` already composes two suppressors (`_snow_skip_airborne()`,
`_alt_frozen()`). Add a third: `and (_load_settled or not CubeSphere.FP_LOAD_DEFER)`. Snow growth is
invisible to a player staring at a loading near field; the sim is dormant-by-default and persists via
`_edits` (`snowfall_system.gd:3-19`), so a delayed start is semantically free (the weather phase
already restarts cross-session, `:18-19`). `FP_SNOW_SLICED` keeps bounding it post-settle.

### 2.4 What is deliberately NOT gated

* **FacetTexBaker base tier** — the shell needs base colours at boot or the planet boots grey; band +
  fine are already deferred by the `FP_BG_PREBAKE` view-first governor (measured `fm_baked=0`). Leave.
* **`phys_ms`** — player controller + GroundCollider + the streaming driver itself; needed, and it
  overlaps the other counters (double-counted ms).
* **JobLane commits** (`main_commit_ms` 2.6-4.2) — already bounded by `COMMIT_BUDGET_MS`. Leave.
* **DEM** — already `FP_DEM_DEFER` (shipped; `g2_baked=0` through load).

---

## 3. The settle gate — one latch, one owner, everything reads it

Reuse the proven `FP_DEM_DEFER` shape (`world_manager.gd:1263-1265` + `global_relief_data.gd:76,264-268`)
and **generalize** it instead of inventing per-subsystem latches:

* **Owner:** `WorldManager`. One new `_load_settled := false`, flipped ONCE in `update_streaming`
  when `initial_view_meshed(player_pos)` (the existing 64³ probe under `FP_LOAD_RAMP`,
  `world_manager.gd:1309-1318`) — same short-circuit discipline as `_relief_settled` so the probe is
  never queried after settle. `_relief_settled` becomes a reader of the same event (both latches flip
  together; `FP_DEM_DEFER` keeps its own flag for byte-off independence).
* **Broadcast on flip (one-shot):**
  * `_facet_ring.set_load_settled(true)` → FacetFarRing releases the env load-hold and unfreezes
    `FacetSmoothV2` (the ring passes the settle bool into `_smooth_v2.step(settled)` — or a setter —
    matching how `_orbit_relief` reads `shell_offsurface()`).
  * Snow gate reads `_load_settled` directly at its callsite.
  * `GlobalReliefData.mark_settled()` (existing, unchanged).
* **Failsafe:** a wall-clock cap, `LOAD_DEFER_FAILSAFE_MS` (init 45 000) — the
  `BOOT_GATE_FAILSAFE_MS` pattern (`facet_far_ring.gd:1296-1297`) — so a view that never meshes (or a
  fallback-path quirk) cannot defer the far field forever. Fallback/no-module path returns `true`
  from `initial_view_meshed` immediately (`:1318`), so the gate only ever bites on the module path.
* **Boot-once, no re-arm:** crossings/teleports do NOT re-enter deferral (same law as
  `FP_DEM_DEFER`'s once-only latch). Post-boot far-tier cost is bounded by the Phase-2 pacing, not by
  re-freezing.
* **Paced resume (anti "the stall just moved to second 30"):** at settle, the deferred targets do not
  all fire on one frame — smooth-v2 resumes dispatch immediately (workers are free by then) but its
  commits are paced (§2.1.2); env-hold release re-enters the normal budgeted converge; snow's next
  fixed step is ≤ 32 columns by its own caps. Optionally (cheap, worth it): smooth-v2's FIRST commit
  waits until `stream_credit > 0` — the controller signal that the near field is no longer starving.

---

## 4. Idle-worker leverage — honest quantification

The 8-core profile shows main-bound, workers idle. But the movable compute is mostly *already* moved:

| Work | Today | Movable? |
|---|---|---|
| smooth-v2 tile bake | WTP workers (`facet_smooth_v2.gd:441`) | already off-thread |
| smooth-v2 **merge** | main, 185 ms GDScript | **YES → §2.1.3** (the whole realistic win) |
| smooth-v2 `add_surface_from_arrays` | main | must stay main (Node/mesh commit law) |
| env facet warm | main on the floored path; async exists behind `FP_ENV_FLOORED_ASYNC`/`FP_ENV_WARM_ASYNC` (`facet_far_ring.gd:1401-1419,1330-1336`) | pre-settle it's *held*, not moved — no worker needed |
| snow | main, cell writes through `_edits` → remesh | NO (single-writer world state; and it's gated instead) |
| DEM | deferred (`FP_DEM_DEFER`); async design exists (`FP_DEM_ASYNC`, STREAM-PARALLEL §4.2) | already designed, unchanged |

So the honest statement: **the load-window fix is deferral, not parallelism** — pre-settle there is
nothing left worth parallelising once the gates land (near-field gen is already `vt_total_ms ≈ 0.1`).
The one real off-thread win is the merge (185 → ~10-30 ms main residue), and it matters
**post-settle**, for fill/crossing smoothness, not for time-to-usable. The 8-core idle seats get used
post-settle by the resumed smooth-v2/DEM/tex pipelines exactly as today. The shared-generator lesson
holds: `build_tile` already uses the frozen per-ring `_cpp_gen` under `RWLockRead`
(`facet_smooth_v2.gd:44-50`) — no new C++ lock surface is introduced.

---

## 5. Flags, gates, NEVER-OOM

All `const … := false` in `cube_sphere.gd` (byte-off; live enable via the deploy sed, as established).

| Flag | Effect |
|---|---|
| `FP_LOAD_DEFER` | the settle latch + broadcast: smooth-v2 freeze (reap-only, no dispatch/commit), env load-hold (fall-hold branch reuse), snow gate, failsafe timer |
| `FP_SMOOTH_V2_PACE` | ≥ `SMOOTH_V2_COMMIT_MS` (500) between `FacetSmoothV2` commits, always (not just during load) |
| `FP_SMOOTH_V2_ASYNC_MERGE` | `merge_tiles` on a WTP task over a snapshot; main pays only `add_surface_from_arrays` |

Gates (new `verify_fast_load.gd`, pattern of `verify_stream_parallel.gd` / `verify_alt_regime.gd`):

* **G-FL-OFF** — all three flags off ⇒ byte-identical; FLAT `verify_feature.gd` **6042/0**.
* **G-FL-GATE** — the load-settle assertion the task demands: with `FP_LOAD_DEFER` forced on and the
  settle latch held false, drive N frames: `FacetSmoothV2` commit count == 0 AND dispatch count == 0
  (reaps allowed), env driver emits no growth re-emits (hold-branch counters), `SnowfallSystem.last_writes == 0`,
  `GlobalReliefData` bakes nothing. Flip the latch: all four resume within their own budgets.
* **G-FL-FAILSAFE** — latch flips via the wall-clock cap when `initial_view_meshed` never turns true.
* **G-FL-PACE** — post-settle synthetic fill: consecutive commit timestamps ≥ `SMOOTH_V2_COMMIT_MS` apart.
* **G-FL-MERGE-EQ** — async merge produces **byte-equal** pos/nrm/col/idx vs a direct `merge_tiles`
  call on the same resident set (extends `G-V2-PURE`'s equality law across the thread hop).

NEVER-OOM: unaffected — pure deferral/pacing, no new resident bytes. The async-merge snapshot is a
shallow Dictionary duplicate (36 refs) + one transient merged-array set (~13 MB peak for one in-flight
merge, same arrays `_commit` already materialises today — a timing shift, not a new ceiling; the
in-flight merge is single-slot, never stacked).

---

## 6. Phased rollout

* **Phase 1 — `FP_LOAD_DEFER`** (the load-window win; smallest diff: one latch + three read sites +
  one plumb). Gates G-FL-OFF/GATE/FAILSAFE. Live A/B on the boot telemetry (`world_settled` timer,
  fps p10 first 120 s, `stream_credit` recovery time, `smooth_v2_commit_ms` == 0 pre-settle).
* **Phase 2 — `FP_SMOOTH_V2_PACE` + `FP_SMOOTH_V2_ASYNC_MERGE`** (the post-settle fill + crossing
  smoothness). Gates G-FL-PACE/MERGE-EQ. Watch `smooth_v2_commit_ms` post-settle: expect ≤ ~30 ms
  paced, from 185.
* **Phase 3 — residue:** re-measure the load window; expected leaders afterwards are tex base slices
  (~5-16 ms, budgeted) and the engine's own 6 ms apply. If `env_converge_ms` still spikes post-settle,
  the existing `FP_ENV_FLOORED_ASYNC` path (already in-tree) is the next lever — enable, don't build.

## 7. The three hardest risks — and the kills

1. **The stall just moves to the settle moment** (deferred backlog fires at once). Kill: pacing is
   part of the design (Phase 2 flag, but the Phase-1 resume already staggers: dispatch-first,
   commit-later + the `stream_credit > 0` first-commit condition); G-FL-PACE asserts cadence; live A/B
   watches p10 fps in the 30 s *after* settle, not just before.
2. **Async-merge COW/threading subtlety on WASM** (a tile array mutated while the merge worker reads
   it). Kill: tiles are immutable post-landing by construction (skirt appended in `build_tile` before
   the mutex hand-off, `facet_smooth_v2.gd:126-128,461-466`); the merge input is a snapshot dict; the
   commit stays on main via the SAFE API; **G-FL-MERGE-EQ byte-equality** would surface any race as
   inequality. If ANGLE/WASM still misbehaves live: drop the flag — Phase 1+pacing already removed
   the load-window damage (the fallback is losing ~20 ms/500 ms post-settle, not the feature).
3. **Deferring something the boot actually needs** (a hidden pre-settle consumer of smooth-v2/env
   convergence — e.g. the shell showing flat far cells at the horizon for longer). Kill: hold-mode
   keeps first-cover chords (no holes, only no *upgrades*); the far shell + base skin still paint;
   `FP_DEM_DEFER` already proved the shade-multiply degrades to 1.0 gracefully. Gate on the FLAT
   suite + a live eyeball of the first 60 s horizon; the failsafe bounds any pathological hold at 45 s.

## 8. Expected outcome (honest numbers)

* Worst load-window frames: measured deferrable ≈ 185 (smooth-v2, on its commit frames) + ~25 (env) +
  ~22 (snow) ≈ **~230 ms removed**; `worst_ms` 626 → expected ~150-250 (tex slices + apply + GC
  residue). Smooth-v2 deferral alone roughly halves the worst frames — it is Phase 1's headline.
* Second-order: `frame_worst_ema` falls under the (adaptive) setpoint → `stream_credit` recovers from
  0 → the near ramp runs supply-limited instead of governor-choked, on workers that are already idle.
* **Time-to-usable target: ≤ 30 s** to `initial_view_meshed` 64³ on the measured 8-core client
  (from 2-3 min), i.e. the apply-bound ramp STREAM-PARALLEL §6 predicted once nothing else contends
  for main. On the 2-core floor the same gates apply; the absolute time is larger (supply-bound) but
  the pile-up removal is identical.
