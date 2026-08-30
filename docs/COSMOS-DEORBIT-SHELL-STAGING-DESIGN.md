# COSMOS DE-ORBIT SHELL STAGING — `FP_SHELL_STAGE_REEMIT`

**Problem**: at the S1 approach-anchor release knee (alt ≈ 560–600; `ANCHOR_REL_LO/ANCHOR_HYST ≈ 609`,
`cube_sphere.gd:2736/2738`, driver `world_manager.gd:862–864`), the FacetFarRing shell re-emits the whole
visible cap — measured live `sh_emit = sh_visN = 930` facets ≈ **1.07 M primitives in ONE build** — and the
resulting WorkerThreadPool alloc-storm rides the WASM dlmalloc single-lock convoy into a **2440 ms**
main-thread frame (`worst_ms=2440 @ alt=595.9`, `vox_gen=0`, `t_farring_us=40`). Reproduces on natural
gradual de-orbit and on freeze-release alike. This is THE dominant de-orbit stall.

**Fix**: a per-frame emit **budget** that stages a large pending re-emit across multiple worker cycles
(≤ `SHELL_STAGE_FACETS` facets per dispatch, nearest-to-camera sectors first), converging to the identical
final shell in ≈ 0.3–0.4 s with no hole and no stale-sector wedge. Flag `FP_SHELL_STAGE_REEMIT := false`,
byte-identical off. Design only — no code edited by this document.

---

## 1. Root cause, grounded in the code

### 1.1 The transition avalanche

All shell rebuilds funnel through `_begin_rebuild()` (`facet_far_ring.gd:2307`) →
`_dispatch_async_rebuild()` (`:2317`) → worker `_async_build_worker()` (`:2494`) → main-thread swap
`_poll_async_rebuild()` (`:2577`) → `_swap_in_sectors()` (`:2278`, FP_FARRING_SECTORS on).

At alt ≈ 595 the regime is still `_shell_orbit()` (`:1973–1974` — `_cam_set and not _emit_floored_last`;
the floored flip is at `OFFSURFACE_Y = 256`, `cube_sphere.gd:2432`), so the dispatch driver is the orbit
branch of `_process` (`:1509–1551`) / `_orbit_warm_async` (`:2011–2030`): any `_pending` fires
`_begin_rebuild()` on the next idle frame.

The anchor-release knee re-grows the near field, which arms `_pending` from **five sources at once** —
the live `sh_pending_src` at the stall showed slots **4, 10, 11, 12, 15**:

| slot | source (`facet_far_ring.gd:340–357`) | what changed at the knee |
|---|---|---|
| 4 | `SRC_CAM` — `_shell_snapshot` (`:1302–1309`) | θ_h/axis snapshot as FALL_HOLD triggers fire (`shell_fall_should_reemit`, `:1290–1298`) |
| 10 | `SRC_UNSINK` — `_unsink_drift_check` (`:1774–1791`) | player column drifted ≥ `UNSINK_DRIFT_BLOCKS` during the fall |
| 11/12 | `SRC_LADDER_SHRINK/GROW` — applied-cover ladder (`:1918–1952`) | `_applied_r`/band react to the near re-grow |
| 15 | `SRC_SLOTS` — band/close-up slot pushes (`:4371`) | FacetTexBaker re-slots as near tiles stream back |

### 1.2 Why FP_FARRING_SECTORS does not help here

`_sectors_compute_dirty()` (`:2201–2233`) marks a sector dirty when (a) any member's emit **signature**
(`_sector_fid_sig`, `:2165–2187`) changed — and the slot id rides the signature at bit 16
(`s |= (int(_uv2_y(fid)) + 2) << 16`, `:2186`), so an SRC_SLOTS wave dirties every re-slotted facet's
sector — or (b) `sunk_changed` is true and the member is sunkish (`:2231–2233`), where
`sunk_changed := _sector_unsink_sig != _sectors_sunk_state()` (`:2208`) and `_sectors_sunk_state()`
(`:2195–2196`) compares `[_async_unsink_col, _async_unsink_have_col, _async_applied_r, _async_applied_band,
_cull_reemit_count]` **verbatim**. At the knee the unsink column AND `_applied_r`/band AND the slot map all
changed since the last orbit build ⇒ **all 24 sectors dirty in one dispatch** ⇒ the worker emits all 930
facets (`_worker_emit_one`, `:2558–2571` — a dirty sector's facet always emits) into 24 P3 bulk collectors,
`_bulk_assemble`s 24 surface arrays (`:2545–2546`), and `_swap_in_sectors` (`:2278–2304`) creates 24
ArrayMeshes + `add_surface_from_arrays` on main in one frame. `FP_UNSINK_DRIFT_CALM` (`cube_sphere.gd:2118`)
and `SHELL_FALL_REEMIT_MS = 1000` (`:2983`) throttle the **periodic** re-arms; they cannot split this
**one-time** avalanche — once `_pending` is set, dispatch emits everything dirty in a single build.

The main-thread 2440 ms is not `t_farring` driver time (40 µs): it is the dlmalloc single-lock convoy —
the worker's burst of Packed*Array growth/assembly allocations serializes against every main-thread
allocation for the duration of the build ([[voxiverse-walk-perf-root-cause]]), plus the 24-mesh swap.
Cost scales with **burst size**, superlinearly (small builds don't convoy — see §3.1).

---

## 2. Design overview

New flag `FP_SHELL_STAGE_REEMIT` (default `false`). When a sectored async dispatch finds a dirty set whose
facet count exceeds a trigger threshold, it:

1. **Selects** a priority-ordered subset of dirty sectors whose combined facet count fits the per-dispatch
   budget `SHELL_STAGE_FACETS`; the rest are **deferred** (simply removed from `_async_sector_dirty` for
   this build — see §4.1 for why nothing is lost).
2. **Holds** the continuous frozen inputs (unsink column, applied radius/band, slot snapshots) at their
   stage-start values for every dispatch of the staging run, so all staged sectors emit from ONE coherent
   snapshot and already-emitted sectors cannot be re-dirtied by mid-stage drift (§4.2).
3. **Re-arms** `_pending` (new `SRC_STAGE`) after each staged swap while deferred sectors remain, driving
   the next worker cycle through the existing `_process` dispatch paths.
4. **Converges**: the run ends when a dispatch's dirty set fits the budget entirely (nothing deferred), or
   the `SHELL_STAGE_MAX_MS` failsafe force-completes (one final unbudgeted dispatch = today's behaviour,
   bounded to the remainder).

Scope: staging applies only when `_async_sectored` (FP_FARRING_SECTORS on **and** the async path); the
single-core synchronous `_rebuild_full()` (`:3273`) and warm-only dispatches (`_dispatch_warm_only`,
`:2394` — `_async_sectored = false`, `:2412`) are untouched.

### 2.1 New constants (`godot/src/cosmos/cube_sphere.gd`, insert after line 351)

```gdscript
## COSMOS DE-ORBIT SHELL STAGING (docs/COSMOS-DEORBIT-SHELL-STAGING-DESIGN.md) — stage the release-knee
## re-emit avalanche. At the S1 anchor-release knee the near re-grow dirties ALL 24 far-ring sectors in one
## dispatch (unsink + applied ladder + slot waves), so FP_FARRING_SECTORS re-emits the whole ~930-facet /
## ~1.07M-prim cap in ONE worker build — the dlmalloc convoy busy-waits the browser main thread ~2.4 s (the
## dominant de-orbit stall). When true, a dirty burst > SHELL_STAGE_TRIGGER facets is released over multiple
## worker cycles at ≤ SHELL_STAGE_FACETS facets per dispatch, nearest-to-camera sectors first, from ONE held
## input snapshot (no cross-sector sunk/slot mismatch), converging to the IDENTICAL final shell in ≈ 0.3 s.
## Deferred sectors keep drawing their resident meshes (never a hole); never-built sectors are never deferred.
## Requires FP_FARRING_SECTORS + FP_FARRING_ASYNC_REBUILD. Default OFF → every dirty sector emits in the same
## dispatch exactly as today (byte-identical, FLAT 6042/0). Gate: src/tools/verify_shell_staging.gd.
const FP_SHELL_STAGE_REEMIT := false
const SHELL_STAGE_FACETS := 112     # per-dispatch dirty-facet budget (~2 typical knee sectors; §3.1)
const SHELL_STAGE_TRIGGER := 168    # stage only when dirty facets exceed this (1.5× budget — small dirt stays 1-frame)
const SHELL_STAGE_MAX_MS := 2500    # stage-run failsafe: past this wall-clock, emit the remainder unbudgeted
```

---

## 3. The trigger predicate and the budget

### 3.1 Numbers, from the measured burst

Measured: 930 facets ≈ 1.07 M prims (≈ 1150 prims/facet) in one build ⇒ 2440 ms main-thread stall
⇒ **2.62 ms/facet all-in** (worker build + convoy + 24-mesh swap) as a *linear upper bound*.

- **Budget `SHELL_STAGE_FACETS := 112`**: a sector at the knee holds ~930/24 ≈ 39 visible facets on
  average (populated sectors ~40–80; a full 12×12 sector front-on can reach ~144). 112 admits 2 typical
  sectors (or 1 large) per dispatch ⇒ ~9–14 dispatches for the 930-facet burst.
  - Pessimistic linear bound per staged frame: 112 × 2.62 ≈ **294 ms** — already inside the ≤ 300 ms
    success criterion. Empirically it will be far lower: the convoy is superlinear in burst size — the
    shipped fall regime already absorbs throttled re-emits of comparable ≤ 1–2-sector size at 53 fps
    post-FP_UNSINK_DRIFT_CALM (worst frames ≪ 100 ms), so a ≤ 112-facet build sits in the
    empirically-absorbed regime (expected ≤ ~60–120 ms worst).
  - Hard per-frame bound: `max(SHELL_STAGE_FACETS, largest single selected sector)` — a sector is the
    swap unit and is never split, and ≥ 1 sector must be taken for progress; worst case ≈ 144 facets
    (linear bound ≈ 380 ms, still 6.4× better than 2440 and a one-sector oddity).
- **Staging latency**: each stage is one worker round-trip = dispatch frame + poll/swap frame ≈ 2 frames.
  ~12 stages × 2 frames ≈ 24 frames ≈ **0.4 s @ 60 fps** (0.35 s at the ~10–14 dispatch range) — inside
  the ≤ 0.5 s target; at descent speed (~40–80 blk/s through the 560–600 band) the shell converges well
  within the band.
- **Trigger `SHELL_STAGE_TRIGGER := 168` (= 1.5 × budget)**: ordinary dirties (axis drift, one slot push,
  a single-sector unsink arm — ≤ ~2 sectors ≈ ≤ ~160 facets) stay single-dispatch with **zero** added
  latency; the knee's 930 ≫ 168 always stages. Anything between 112 and 168 emits unstaged in one
  dispatch — by the linear bound ≤ 440 ms once, but such mid-size bursts are not observed live (dirt is
  either sector-local or the full-cap avalanche); the trigger is deliberately conservative so staging
  cannot add latency to the common case.

### 3.2 The predicate (evaluated in `_dispatch_async_rebuild`, after `_sectors_compute_dirty()` at `:2382`)

```
stage_this_dispatch :=
    FP_SHELL_STAGE_REEMIT
    and _async_sectored                                   # sectored async build only
    and ( _stage_active                                   # a run in progress keeps budgeting to the end
          or deferrable_dirty_facets > SHELL_STAGE_TRIGGER )
    and not stage_failsafe                                # §4.4
```

where `deferrable_dirty_facets` counts fids in `_async_fids` whose sector is dirty **and deferrable**:

```
deferrable(s) := _sector_built_epoch[s] == _sector_epoch    # has a RESIDENT current-epoch mesh (:2218)
```

Sectors that are **not** deferrable (never built, or epoch-invalidated by a sync `_sectors_reset()`,
`:2261–2271` — their resident mesh is empty) are **always emitted in the current dispatch** and never
deferred: deferring them would be a real hole. At the knee every sector is epoch-current (built during
orbit), so the whole burst is deferrable. A boot / post-`force_rebuild` full build (all sectors
epoch-stale) therefore never stages — correct, since there is no resident coverage to lean on there
(that path is the boot-warm's problem, already paced by FP_BOOT_ASYNC).

Why count **facets**, not sectors: build cost ∝ facets/prims, and sector populations vary 0–144; a
sector count would over/under-shoot the budget by ~4×.

The `sh_applied_r` 0→R transition and Δ(wanted set) were considered as triggers and rejected: they are
*causes* of the dirty burst, not the burst itself — the dirty-facet count is the single measurable that
directly bounds the build cost, and it catches every avalanche regardless of which SRC mix armed it.

---

## 4. The staging queue

### 4.1 Selection, priority, and why deferred sectors are never lost

New main-thread helper `_stage_filter_dirty(axis: Vector3, on := CubeSphere.FP_SHELL_STAGE_REEMIT)`,
called from `_dispatch_async_rebuild` immediately after `_sectors_compute_dirty()`:

1. One pass over `_async_fids` (≤ ~930) accumulating per dirty sector: `facets[s]`,
   `prio[s] = max(prio[s], _centre_pack[fid].dot(axis))` (the packed centre-dir array from FIX D,
   `_ensure_centre_pack()`, `:2668–2675` — main thread, idempotent), and `newmem[s] |= fid not in
   _sector_sig[s]` (a member its resident mesh does not contain).
2. Partition dirty sectors into **class 0** — not deferrable, or `newmem[s]` true (gaining a facet its
   resident mesh lacks) — and **class 1** — deferrable, replacement-only.
3. Order: all of class 0 first (unconditionally included, budget-exempt for correctness — at the knee this
   class is empty or tiny: the cap *shrinks* on descent and FALL_HOLD's `SHELL_FALL_MARGIN_DEG` keeps
   growth behind the limb, see `shell_set_camera_abs` `:1242–1245`), then class 1 by **descending
   `prio[s]`** — the sub-camera/screen-centre sector fills first and coverage advances outward to the
   horizon, exactly the visual order the player scans.
4. Take class-1 sectors in order while `taken + facets[s] ≤ SHELL_STAGE_FACETS`; always take at least one
   (progress guarantee). Remove the rest from `_async_sector_dirty`; record `_stage_deferred_n` (count)
   and `_stage_last_emit_facets` (telemetry).
5. If anything was deferred and `_stage_active` is false: **start the run** — `_stage_active = true`,
   `_stage_start_ms = now`, capture the hold snapshot (§4.2).

**No sector can be dropped.** `_sectors_record_frozen()` (`:2238–2257`) updates a sector's signature
record `_sector_sig[s]` / `_sector_built_epoch[s]` **only for sectors in `_async_sector_dirty`**
(`:2239–2243`). A deferred sector is removed from that set before the worker runs, so its record stays
stale, so the next dispatch's `_sectors_compute_dirty()` re-derives it dirty by the *same comparison that
marked it this time*. The "queue" is therefore not persisted state that can desynchronize — it is
re-derived from ground truth every dispatch. Corollary: **a new dirty arriving mid-stage merges for free**
(it simply changes the ground truth the next recomputation reads) and can never restart anything — each
dispatch emits at most the budget regardless of how the dirty set grew.

### 4.2 The stage-snapshot hold (kills the re-dirty treadmill and the cross-sector seam)

Left alone, the run would never drain: each dispatch freezes the **live** continuous inputs
(`_async_unsink_col = _player_col_abs` `:2330`, `_async_applied_r = _applied_r` `:2335`, band `:2339`,
`_refresh_slot_snapshot()` `:2319`), and during a descent the player column moves every frame — so
dispatch *N+1*'s `_sectors_sunk_state()` differs from what dispatch *N*'s sectors were recorded against,
re-dirtying every sunkish sector forever (the storm re-created in slow motion). Two measures:

**(a) Hold the snapshot for the run.** While `_stage_active`, `_dispatch_async_rebuild` reuses the
stage-start copies for the five continuous inputs (`_async_unsink_col`, `_async_unsink_have_col`,
`_async_applied_r`, `_async_applied_band`) and **skips** `_refresh_slot_snapshot()` (the held
`_slot_snapshot`/`_band_slot_snapshot` persist — they are only ever written there and in `_rebuild_full`).
Every staged sector thus emits from ONE coherent snapshot: no sunk-depth or texture-slot mismatch between
a sector emitted at stage 1 and its neighbour emitted at stage 12 — **no seam artifact**. Drift that
accumulates during the ≈ 0.4 s run is reconciled by the first normal dispatch after the run (the existing
SRC_UNSINK/SRC_SLOTS arms fire as shipped; if that reconciliation is itself a > trigger burst, it stages
again — correct and bounded).

**(b) Per-sector sunk record.** The global `_sector_unsink_sig` (`:299`, written at `:2257`) is
insufficient under partial swaps: after the first staged swap it would claim the *new* state for sectors
still built against the *old* one — deferred sunk-only-dirty sectors would compare clean and be dropped
(the permanent stale-wedge failure mode). Under the flag, add `_sector_sunk_built: Array`
(sector → the `_sectors_sunk_state()` Array it was last built against), written per dirty sector in
`_sectors_record_frozen()`; `_sectors_compute_dirty()` then tests sunkish members against
`_sector_sunk_built[s]` instead of the global fingerprint. With the hold (a), the current state is
constant during a run ⇒ emitted sectors compare clean, deferred sectors compare dirty ⇒ the dirty set
**strictly shrinks** by ≥ 1 sector per dispatch from sources (a)+(b). Flag off ⇒ the global compare runs
verbatim (byte-identical).

Residual mid-stage dirt sources and why they terminate: cache-presence bits in `_sector_fid_sig`
(`_bpos_cache`/`_env_done`/`_benv_done`, `:2169–2176`) only ever *set* (monotone — worker env-warm,
`:2526–2536`); membership changes are cap-law-bounded (FALL_HOLD holds the cap); `_async_v2_resident`
(`:2370–2374`) can oscillate but is bounded by the failsafe (§4.4).

### 4.3 Driving the run: `SRC_STAGE`

After a staged `_swap_in_sectors()` completes in `_poll_async_rebuild()` (`:2586`), if
`_stage_deferred_n > 0`: `_arm_pending(SRC_STAGE)`. `_arm_pending` (`:1396–1406`) sets `_pending = true`
(with FP_APPLIED_PROBE_CALM on it also bumps the sensor slot — SRC_STAGE is a SAFETY arm, never luxury).
The existing `_process` regimes then dispatch on the next idle frame:
in `_shell_orbit()` via `_orbit_warm_async`'s `want := _pending …` (`:2021–2027`) or the S1b branch's
`if _pending or grew_ok or …: _begin_rebuild()` (`:1543–1546`) — note `_pending` **bypasses** the
`SHELL_FALL_REEMIT_MS` throttle there (the throttle only gates `grew_ok`), so staged cycles chain at
worker speed, ~2 frames each; on the floored surface via `_surface_converge_emit`'s `want := _pending …`
(`:1613`). No new dispatch site is introduced; the `_async_building` guard (`:1481–1482`) serializes
cycles exactly as today.

Enum change: `const SRC_STAGE := 18`, `SRC_COUNT := 19` (`:357–358`; SRC_FORCE = 17 stays reserved).
This appends one column to the `sh_pending_src` sensor (`:3645–3649`) — additive, position-stable for all
existing columns. `verify_probe_calm.gd:65` pins `SRC_COUNT == 18` and must be extended to 19 with
SRC_STAGE appended to its order assertion (a deliberate one-line gate update, same as every prior enum
extension).

### 4.4 Run termination and the failsafe

- **Normal end**: a dispatch defers nothing (`_stage_deferred_n == 0` after selection). After its swap,
  `_stage_active = false` and the holds release. The run is over when, additionally, the *next*
  `_sectors_compute_dirty` against live inputs produces ordinary (≤ trigger) dirt — the shipped calm
  machinery owns it again.
- **Failsafe**: if `now − _stage_start_ms > SHELL_STAGE_MAX_MS` (2500 ms ≈ 24 worst-case one-sector
  cycles + slow-frame slack) at dispatch time, staging is bypassed for that dispatch — the full remaining
  dirty set emits unbudgeted (exactly today's behaviour, bounded to ≤ the original burst) and the run
  closes. This caps the hold duration (stale sunk/slot inputs can never persist beyond ~2.5 s) and makes
  livelock impossible even if some signature source oscillated adversarially.
- **Pre-emption**: any synchronous whole-mesh rebuild (`force_rebuild` `:3461` / `_rebuild_full` `:3273`)
  calls `_sectors_reset()` (`:3300`) — which under the flag also clears `_stage_active/_stage_deferred_n/`
  `_sector_sunk_built` — cancelling the run; the sync build emits everything anyway.

---

## 5. Coverage during staging — the no-hole argument

1. **Deferred sectors keep drawing.** `_swap_in_sectors()` touches only sectors in `_async_sector_dirty`
   (`:2284–2291`); every other sector's `MeshInstance3D` child keeps its resident mesh. A deferred sector
   is by construction deferrable = has a resident current-epoch mesh (§3.2). The player sees the
   *pre-transition* shell geometry there — stale by ≤ 0.4 s of sunk/slot drift, but opaque and present.
   The whole-cap `_mi` mesh was already emptied at the first sectored swap ever (`:2281–2282`), so there
   is no double-draw.
2. **Never-built sectors are never deferred** (class 0, §4.1) — the only sectors whose "resident mesh" is
   empty always emit in the current dispatch.
3. **Membership growth** (a facet newly visible in a deferred sector) is the one way staleness could be a
   *gap* rather than stale geometry. Class 0 also captures it (`newmem[s]`: a dirty sector gaining a
   member absent from its record is emitted first). Independently, at the knee the cap **shrinks**
   (descent: θ_h falls; `shell_fall_should_reemit` `:1290–1298` suppresses shrink re-emits and FALL_HOLD's
   +12° margin keeps any growth behind the limb per the G-SHELL-NOPOP containment law), so growth-driven
   dirt is not the knee case at all.
4. **Membership shrink** in a deferred sector means it keeps drawing a facet that left the wanted set —
   overdraw behind the limb (the S1 slack law guarantees departures are limb-hidden), not a hole; healed
   when its turn comes.
5. **Belt-and-braces under-layers** (why the REGROW work measured hole=0 through this band): the
   FP_FARRING_FULL_COVER backstop roles, the FacetOrbitRelief tier, the smooth-V2 annulus and the chord
   fallbacks (`_emit_cached`'s chord path, dispatched chord-only under FP_ENV_FALL_HOLD `:2325/:2510`)
   all cover independently of which sector mesh is fresh. Staging never touches them.
6. **Telemetry confirmation is built in**: `_swap_in_sectors` rebuilds `_emitted` as the union of *every*
   sector's drawn shard (`:2293–2299`), deferred sectors' shards included — so `sh_emit` stays ≈ 930
   throughout a staged run. A hole would read as `sh_emit < sh_visN`; the A/B (§9) asserts it does not.

---

## 6. Exact edit sites

All in `godot/src/world/facet_far_ring.gd` unless noted. Every edit is inert with the flag off.

**E1 — `cube_sphere.gd:351`** (after the `FP_FARRING_SECTORS` const): insert the §2.1 block.

**E2 — state (`facet_far_ring.gd:304`,** after `_async_sector_arrays`):
```gdscript
# COSMOS DE-ORBIT SHELL STAGING (FP_SHELL_STAGE_REEMIT, doc in cube_sphere.gd): stage-run state. ALL of it
# is zero/never touched with the flag off (byte-identical).
var _stage_active := false                 # a staged run is in progress (holds the frozen-input snapshot)
var _stage_start_ms := 0                   # wall-clock at run start (SHELL_STAGE_MAX_MS failsafe)
var _stage_hold: Array = []                # held [unsink_col, have_col, applied_r, applied_band] for the run
var _stage_deferred_n := 0                 # sectors deferred by the LAST staged dispatch (0 ⇒ run drains)
var _stage_last_emit_facets := 0           # facets actually selected for the LAST staged dispatch (telemetry)
var _sector_sunk_built: Array = []         # sector -> _sectors_sunk_state() it was last built against (flag-on only)
```

**E3 — `:357–358`**:
```gdscript
# before
const SRC_FORCE := 17          # force_rebuild() synchronous path (reserved; no _pending arm)
const SRC_COUNT := 18
# after
const SRC_FORCE := 17          # force_rebuild() synchronous path (reserved; no _pending arm)
const SRC_STAGE := 18          # staged re-emit continuation (FP_SHELL_STAGE_REEMIT — SAFETY, drains the run)
const SRC_COUNT := 19
```

**E4 — `_sectors_ensure_arrays` (`:2133–2145`)**: under the flag, also
`if CubeSphere.FP_SHELL_STAGE_REEMIT: _sector_sunk_built.resize(ns)` (nulls = never recorded ⇒ treated as
mismatch ⇒ dirty, the safe default).

**E5 — `_sectors_compute_dirty` (`:2201–2233`)**: replace the global sunk compare for the dirty test when
the flag is on. Before (`:2208` and `:2231–2233`):
```gdscript
var sunk_changed: bool = _sector_unsink_sig != _sectors_sunk_state()
...
			if sunk_changed and _sector_sig_sunkish(sg):
				_async_sector_dirty[s] = true
				break
```
After: with `FP_SHELL_STAGE_REEMIT` off, verbatim. On: `sunk_changed_for(s) :=
_sector_sunk_built[s] == null or _sector_sunk_built[s] != _sectors_sunk_state()` (per-sector, §4.2b),
used in place of the global `sunk_changed` inside the member loop. (The function gains the codebase's
gate-forcing param `stage_on := CubeSphere.FP_SHELL_STAGE_REEMIT`.)

**E6 — new `_stage_filter_dirty(axis: Vector3, stage_on := CubeSphere.FP_SHELL_STAGE_REEMIT) -> void`**
(place after `_sectors_compute_dirty`): the §3.2 predicate + §4.1 selection. Early-return when
`not stage_on or not _async_sectored`. Uses `_ensure_centre_pack()` + one pass over `_async_fids`;
mutates only `_async_sector_dirty`, `_stage_*`.

**E7 — `_dispatch_async_rebuild` (`:2317–2386`)**, two touches:
- `:2319` slot-snapshot freeze — before: `_refresh_slot_snapshot()`. After:
  `if not (CubeSphere.FP_SHELL_STAGE_REEMIT and _stage_active): _refresh_slot_snapshot()` (hold, §4.2a).
- `:2330–2339` continuous-input freeze — after the shipped assignments, add:
  ```gdscript
  if CubeSphere.FP_SHELL_STAGE_REEMIT and _stage_active:
      _async_unsink_col = _stage_hold[0]; _async_unsink_have_col = _stage_hold[1]
      _async_applied_r = _stage_hold[2];  _async_applied_band = _stage_hold[3]
  ```
- after `:2382` (`if _async_sectored: _sectors_compute_dirty()`), add
  `_stage_filter_dirty(_async_demand_axis-style axis from _cull_params()[0])` — and inside E6, on run
  start, capture `_stage_hold = [_async_unsink_col, _async_unsink_have_col, _async_applied_r,
  _async_applied_band]` (the values just frozen, i.e. the stage-start live state).

**E8 — `_sectors_record_frozen` (`:2238–2257`)**: in the per-dirty-sector reset loop (`:2239–2243`), add
`if CubeSphere.FP_SHELL_STAGE_REEMIT: _sector_sunk_built[s] = _sectors_sunk_state()`. The global
`_sector_unsink_sig` write at `:2257` stays (it is the flag-off law's record and harmless flag-on).

**E9 — `_poll_async_rebuild` (`:2577–2594`)** — after `_swap_in_sectors()` (`:2586`):
```gdscript
		if CubeSphere.FP_SHELL_STAGE_REEMIT and _stage_active:
			if _stage_deferred_n > 0:
				_arm_pending(SRC_STAGE)      # drain the run: next idle frame dispatches the next slice
			else:
				_stage_active = false        # run drained — release the input hold
				_stage_hold = []
```

**E10 — `_sectors_reset` (`:2261–2271`)**: under the flag, clear `_sector_sunk_built` entries, and
`_stage_active = false; _stage_deferred_n = 0; _stage_hold = []` (sync rebuild pre-empts the run, §4.4).

**E11 — telemetry (`:3614`,** beside `sh_reemit`): flag-gated keys (off ⇒ keys absent ⇒ byte-identical
consumers, same pattern as `:3640–3649`):
```gdscript
	if CubeSphere.FP_SHELL_STAGE_REEMIT:
		out["sh_stage_on"] = 1 if _stage_active else 0
		out["sh_stage_q"] = _stage_deferred_n          # sectors still queued
		out["sh_stage_emit"] = _stage_last_emit_facets # facets in the last staged slice (≤ budget bound)
```

**E12 — `verify_probe_calm.gd:59–66`**: extend the pinned enum assertion to `SRC_COUNT == 19` +
`SRC_STAGE == 18`.

Nothing else changes: `_async_build_worker`/`_worker_emit_one` (`:2494–2571`) already emit exactly the
sectors in `_async_sector_dirty`; shrinking that set *is* the whole mechanism.

---

## 7. Byte-off proof

- Every new statement is behind `CubeSphere.FP_SHELL_STAGE_REEMIT` (E4–E11) — with the flag off, all new
  state stays at its zero initializer and no branch is entered; `_sectors_compute_dirty`'s sunk test and
  `_dispatch_async_rebuild`'s freezes run verbatim.
- `_stage_filter_dirty` early-returns off ⇒ `_async_sector_dirty` untouched ⇒ every dirty sector emits in
  the same dispatch exactly as today.
- The only flag-off-visible deltas are the two enum consts (E3) — `sh_pending_src` gains a trailing `,0`
  column *only when FP_APPLIED_PROBE_CALM is on* (positional parsing of existing columns unaffected) —
  and the E12 gate pin update. No gameplay/mesh byte changes.
- FLAT: `verify_feature.gd` never enters FACETED far-ring paths — stays **6042/0**.
- Composition: FP_FARRING_SECTORS/BULK_EMIT are upstream mechanisms staging rides unchanged;
  FP_UNSINK_DRIFT_CALM's arm-throttles still gate *when* dirt arrives — staging only bounds *how much of
  it is built per cycle*; FP_SHELL_FALL_HOLD's `_pending`-bypass of the 1000 ms throttle is what lets the
  run drain at worker speed (§4.3) — no throttle interplay to tune.

---

## 8. Gate plan — `godot/src/tools/verify_shell_staging.gd`

New headless SceneTree gate modeled on `verify_shell.gd` (preload `FFR`, `TerrainConfig.warm_up()` +
`FA.warm_up()`, FACETED sed to run). Per the C-lite lesson (a fix can be runtime-dead), the driver
exercises the **real dispatch→worker→swap path**, not mirrors: it instantiates FacetFarRing, calls
`setup(spawn_facet)`, engages the S1 law via `shell_set_camera_abs` at an orbit-band altitude, prewarns
the front caches directly (`_ensure_cached`/`_ensure_backstop_cached` over `visible_fids()` — bounded
≤ 6·K²), then drives real cycles: `_dispatch_async_rebuild()` → spin `while _async_building:
_poll_async_rebuild(); OS.delay_msec(1)`. Calling `_dispatch_async_rebuild` directly sidesteps the
compile-const `_async_enabled()` check (`:2109–2110`) so the REAL WorkerThreadPool build + sectored swap
runs headless regardless of FP_FARRING_ASYNC_REBUILD's baked value; all staging functions take the
codebase-convention forcing params (`stage_on := …`, E5/E6) so no sed of the new flag is needed either.

Sub-gates:

- **G-STG-TRIG** — trigger fires only on big bursts: dirty a single sector (slot flip on one facet) ⇒
  with `stage_on = true`, `_stage_filter_dirty` defers nothing and `_stage_active` stays false; then
  force a full-cap burst (mutate the unsink column + applied_r so every sunkish sector dirties, the real
  knee mechanism) ⇒ staging engages, `_stage_deferred_n > 0`.
- **G-STG-BUDGET** — per-cycle bound on the REAL path: across the whole staged drain of the burst, every
  dispatch's selected facet count (`_stage_last_emit_facets`, cross-checked by summing
  `_async_sector_dirty` member counts at dispatch) ≤ `max(SHELL_STAGE_FACETS, largest selected sector)`
  and ≥ 1; the per-cycle swapped vertex delta (the `_push_event` "async-sect" verts, `:2304`) is
  proportionally bounded vs the unstaged reference build.
- **G-STG-CONVERGE** — drive cycles until `_sectors_compute_dirty` yields empty (cap the loop at
  `2·ceil(N/budget)+4` cycles); assert the final state is IDENTICAL to a reference unstaged run
  (`stage_on = false` from the same start state): same `_emitted` key set, same per-sector `_sector_sig`
  records, same `_sector_drawn` unions.
- **G-STG-MERGE** — mid-run, inject new dirt on an *already-emitted* sector (flip its slot / a cache bit):
  assert it re-enters the dirty set, the run still drains, no sector of the original deferred set is ever
  lost (every deferred sector is eventually recorded at the current epoch with a matching sig).
- **G-STG-SUNKPIN** — the stale-wedge regression (§4.2b): burst caused ONLY by a sunk-state change; after
  the first staged cycle, assert the deferred sunkish sectors are STILL computed dirty (per-sector record
  law) — this test FAILS if the global `_sector_unsink_sig` compare were kept, proving the per-sector
  record is load-bearing.
- **G-STG-NOHOLE** — at every intermediate cycle: every sector NOT in that cycle's dirty set still has its
  resident mesh (non-null, epoch-current, surface count as before) and the union of all `_sector_drawn`
  shards ⊇ (reference emitted set ∩ pre-transition emitted set); never-built sectors never appear in the
  deferred remainder (class-0 law).
- **G-STG-HOLD** — during the run, mutate the live `_player_col_abs`/`_applied_r` between cycles; assert
  every staged dispatch froze the SAME `_async_unsink_col`/`_async_applied_r` (the stage-hold), and the
  first post-run dispatch picks up the live values.
- **G-STG-FAILSAFE** — inject `_stage_start_ms = now − SHELL_STAGE_MAX_MS − 1`; assert the next dispatch
  emits the full remainder (unbudgeted) and closes the run.
- **G-STG-BYTEOFF** — `stage_on = false`: the burst emits in ONE dispatch (selected facet count == full
  burst), `_stage_*` state never leaves zero, and `_sectors_compute_dirty`'s dirty set is element-equal
  to the flag-on *pre-filter* set.

Plus the E12 one-line update in `verify_probe_calm.gd`. Existing gates re-run unchanged:
`verify_shell.gd`, `verify_farring_emit` (G-FR-SECT/G-FR-BULK), FLAT `verify_feature.gd` (6042/0).

---

## 9. Live A/B plan

Build with the deployed flag set + `FP_SHELL_STAGE_REEMIT := true`; export; deploy.

1. **Warm**: load, let the prebake settle (FP_PREBAKE_* pacing; wait for `prebake done` / stable fps at
   rest) — the knee measurement must not alias prebake work.
2. **Descent**: from a ≥ 1500-alt orbit, natural gradual de-orbit through the 560–600 band (same profile
   as the measured baseline; repeat once with the freeze-release shortcut to confirm both reproduce).
3. **Success criteria** (telemetry via the remote bridge relay):
   - `worst_ms` in the 560–600 band: **2440 → ≤ 200–300 ms** (expected ≤ ~120 by §3.1).
   - `sh_stage_emit` ≤ 112 (occasionally ≤ ~144, the one-large-sector case) across several consecutive
     frames instead of one 930 spike; `sh_stage_q` counts down monotonically to 0 within ≤ ~0.5 s;
     `sh_reemit` advances by ~9–14 over the band instead of +1.
   - **No visible hole/wedge**: visually, and `sh_emit` never drops below `sh_visN` during the run
     (§5.6); no stale-sunk shelf persisting > ~1 s after landing sight-lines settle.
   - Regression watch: on-foot and steady-orbit `worst_ms` unchanged (trigger must not fire there —
     `sh_stage_on` stays 0 outside the knee).
4. **Telemetry gotchas** (from the fall-instrumentation sessions): the relay is 1 Hz (`telem=10hz` is
   finicky) — but `worst_ms` is the window-worst and rate-robust, and `sh_stage_q`'s monotone drain is
   readable even at 1 Hz (expect to catch 1–2 mid-run samples); consent lapses on `link_lost` — re-grant
   before the descent; `sh_pending_src` slot 18 (SRC_STAGE) attributes the drain arms definitively.

---

## 10. Executive summary

- **Trigger**: dirty-**facet** count of *deferrable* sectors (resident current-epoch mesh) >
  `SHELL_STAGE_TRIGGER = 168` at sectored async dispatch — the knee's 930 always stages; ordinary ≤ ~2-sector
  dirt never does (zero added latency).
- **Budget**: `SHELL_STAGE_FACETS = 112` facets/dispatch (~2 knee sectors; hard bound
  max(112, largest sector)); 930/112 ⇒ ~9–14 worker cycles ≈ 0.3–0.4 s; linear worst ≤ ~294 ms/frame,
  empirically ≪ (the convoy is superlinear — ≤ 2-sector builds are already absorbed at 53 fps).
- **Queue**: re-derived each dispatch from the sector signature records (deferral = don't record ⇒
  re-computes dirty ⇒ nothing lost, new dirt merges free); priority = never-built/new-member sectors
  first, then descending camera-axis dot (centre-out toward the horizon); stage-held input snapshot +
  per-sector sunk record guarantee monotone drain and no cross-sector seam; 2.5 s failsafe collapses to
  today's single build.
- **No hole**: deferred sectors keep drawing their resident meshes (swap touches dirty only,
  `:2284–2291`); never-built sectors are never deferred; growth is limb-hidden by FALL_HOLD; `sh_emit`
  stays ≈ `sh_visN` throughout.
- **Flag**: `FP_SHELL_STAGE_REEMIT := false` (+3 consts) — off ⇒ byte-identical single-dispatch emit;
  FLAT 6042/0.
- **Gate**: `verify_shell_staging.gd` drives the REAL dispatch→WorkerThreadPool→sectored-swap path
  headless (direct `_dispatch_async_rebuild` + poll loop, forcing params per codebase convention):
  trigger-selectivity, per-cycle budget, convergence-to-reference, merge, stale-wedge regression
  (G-STG-SUNKPIN), no-hole, hold, failsafe, byte-off.
