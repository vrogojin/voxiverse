# COSMOS — Per-Frame Work Audit: "What is NOT contributing to the picture?" + the Unattended Fix Plan

**Status:** read-only performance-architecture audit + ranked, flag-gated plan. No code changed in this pass.
**Author:** Fable, 2026-07-21 (evening), commissioned for the unattended overnight fix effort.
**Branch audited:** `deploy/perf-plus-sky` @ `34a5c29` (includes the just-landed `FP_SHELL_ORBIT_IDLE` +
`FP_COAST_FULL_DT` fall fixes — this doc does NOT re-design those; it covers what they did *not* fix).
**Predecessors:** `COSMOS-PERF-POSTPORT-DESIGN.md` (apply-bound model, C1 crossing spike),
`COSMOS-CROSSING-FASTGEN-DESIGN.md` (crossing_ms 1.7–19 ms proven, controller pin),
`COSMOS-FIXED-FRAME-DESIGN.md` (O(1) crossing — realized, see §4), `COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md`.

**Evidence base.**
1. Live remote-bridge telemetry (this session): walk 54 fps but worst 1361 ms at crossings, snow_ms→145;
   fly 55 fps OK; **fall-from-orbit ~5 fps, worst 560–770 ms**, `sh_wfail` +5.7/frame,
   `vox_gen=vox_mesh=vox_main=0`, draws ≈30; one 38 s idle-ground stall.
2. **Controlled single-facet ground walk (remote-driven, ZERO crossings): fps p50 = 21 (min 5),
   worst 200 ms — snow_ms ≤126, phys_ms ≤96, proc_ms ≤83, prims ≈300 k, and `sh_wfail` climbing
   ~3.5/frame for the WHOLE walk.** This run is the keystone: two of the biggest drains are
   **always-on and mode-independent**, not crossing/fall specials.
3. Deployed flag truth dumped from `build/web/index.pck` via `get_script_constant_map` (§1.1) — repo
   consts are all `false`; **never** reason from source defaults.

---

## 0. Executive answer to the user's question

> "Are we doing any extra work that is NOT contributing to immediate rendering and immersion?"

**Yes — and the two biggest offenders run in EVERY mode, every frame:**

| # | Wasted work (always-on) | Cost | Contributes to the picture? |
|---|---|---|---|
| W1 | **Far-ring warm gate that can never converge on web** — `_warm_front()`'s per-frame 6·K²=3456-facet scan charges its *scan* time against the 3 ms warm budget, so on wasm (×25) it returns `false` even when **every facet is already cached**. `_pending` is never consumed → the scan+fail repeats every frame forever (`sh_wfail` +3.5/frame on a plain ground walk). | ~3 ms/frame burned **every frame, every mode** + the ring **never re-emits** (stale far terrain = the weld/tier symptoms) + downstream systems (`stream_pace` gate, shell) see a permanently "churning" ring. | **No.** It produces zero pixels — it fails before emitting, forever. |
| W2 | **SnowfallSystem stepping on the main thread** — a 0.5 s fixed-step burst of 32 columns × (column_profile noise + `apply_state_transitions` env queries + stack scans + weather noise) + up to 32 `set_voxel` remesh triggers + a ground rebuild, all in one `_process` call; after any hitch the accumulator runs **up to 4 steps in one frame** (catch-up amplification: a hitch *causes* the next hitch). | snow_ms 30–145 ms spikes, ~every 0.5 s, in **every** mode — including **falling from orbit**, where it simulates snow on a surface 100 k+ blocks below the camera. | Only near the player on the ground, at 2 Hz. In orbit/fall: **zero**. The per-frame *burst* shape is never necessary. |
| W3 | **The whole active-facet machinery running at altitude** — in orbit/fall the ground-track sweeps facets, so `maybe_cross_facet` commits redesignations (cooldown = 6 ticks ⇒ up to ~10/s), each doing: `_rebuild_window_indices` (a full scan of **ALL** edits — up to 200 k snow cells), pool spawn/retire + view-target churn, a one-frame 128→96 view **shrink snap** (block-unload burst → wasm allocator convoy), far-ring exclusion resync, gravity-area rebuilds, collider crossing note. | The fall's phys_ms 160–228 ms; pool/edit churn; allocator pressure. | **No.** From orbit the near voxel field isn't even on screen (draws ≈30 = the shell + sky). The player is not editing, walking, or colliding with anything the pool serves. |
| W4 | **`_rebuild_window_indices` is O(total edits) per crossing** — snow authors up to 200 k `_edits` cells; every crossing rescans the whole dict in GDScript (`world_manager.gd:2413-2443`), and `_translate_active` (`:832-840`) does it again for fallback consumers. | Crossings get **progressively slower over a session** as snow accumulates (the measured crossing_ms 1.7–19 ms was on a young session). | No — it recomputes an index that could be maintained incrementally per write. |
| W5 | Small always-on redundancies: `_push_bodies` allocates a `PhysicsShapeQueryParameters3D` + shape-query **every physics tick while moving** even with zero debris in the world (`player.gd:1679-1697`); ThermometerHUD does 3 `PerVoxelEnvironment.temperature()` noise queries + label writes per frame (`thermometer.gd:45-66`); NavHUD label writes per frame; CosmosSky recomputes the full ephemeris/uniform set per frame even when nothing perceptibly moved (`cosmos_sky.gd:664-799`). | Each ≤1–2 ms wasm, but they stack on a 21 fps baseline. | Marginally / at far lower rates than they run. |

Also audited and **found NOT running live** (flags OFF in the pck): weather grid / clouds / precip /
storms (`FP_CLIMATE_GRID/FP_CLOUDS/FP_PRECIP/FP_STORMS/FP_WEATHER_THREAD` all false), skin tier,
Moon ring/body-LOD, `MULTI_BODY/SOI_SWAP`. They cost nothing today; §7 sets the rule for turning
them on. `FarTerrain` is not instantiated under FACETED (`world_manager.gd:297`).

And one **measurement trap** that has already burned a fix cycle: `proc_ms`/`phys_ms` come from
`Performance.TIME_PROCESS/TIME_PHYSICS_PROCESS` (`remote_bridge.gd:602-603`), which are **known-invalid
on the threaded web export** (they fold in rAF wait — see memory `voxiverse-web-time-process-invalid`).
Only `worst_ms` (true wall delta) and the µs attribution counters (`snow_ms`, `ctrl_ms`, crossing/farring
events) are trustworthy. The fall's "~470 ms unaccounted" is partly an artifact of trusting proc+phys (§3).

---

## 1. Ground truth: what actually runs, per frame, per mode

### 1.1 Deployed flag reality (dumped from `index.pck`, 2026-07-21)

ON: `FACETED, FP_M1_POOL, FP_M2_LOD+FP_NO_NEAR_LOD` (LOD mesher bypassed), `FP_CPPGEN,
FP_FARRING_FAST_REBUILD, FP_FARRING_ASYNC_REBUILD, FP_FARRING_FULL_COVER, FP_SHELL_WELD,
FP_TIER_STICKY_BACKSTOP, FP_TIER_ENVELOPE, FP_TIER_WARM_CONVERGE, FP_FIXED_FRAME,
POOL_CROSSING_PREGEN, FP_PREFILL_112, FP_VEL_PREDICT, FP_INFLIGHT_GATE, FP_CTRL_ADAPTIVE,
FP_LANDING_STREAM_KICK, FP_SHELL_CAMERA_SET, FP_SHELL_PREWARM, FP_SHELL_ORBIT_IDLE,
FP_COAST_FULL_DT, ORBIT_COAST/ATTITUDE, SN_NAV_MODES, SN_DEVNAV, SN_ATMO_BRAKING,
SN_FOFF_RADIAL_FALL, ORBITAL_SKY + full atmo/sky set (FP_ATMO_SHELL, FP_SUN_PRESENCE,
FP_LIGHT_ABSOLUTE, FP_SHELL_ABSOLUTE, FP_SN3_MAIN_LIVE, FP_SCALED_BODY, SKY_MOONSHINE(+LIGHT)),
FP_SEASONS, FP_ATLAS_MATERIAL, FP_BULK_UNDERGROUND, FP_NEAR_DAYLIGHT`.
OFF: `FP_CLIMATE_GRID, FP_CLOUDS, FP_PRECIP, FP_STORMS, FP_WEATHER_THREAD, FP_SKIN_TIER,
FP_TIER_DEPTH_BIAS, FP_BODY_LOD, FP_MOON_RING, MULTI_BODY, SOI_SWAP, FP_COLBULK, FP_STAMP,
SHELL_TERMINATOR_TINT`.

### 1.2 The frame graph (what runs where)

`_process` (main thread, every frame):
- `WorldManager._process` (`world_manager.gd:333-394`): snowfall step (§2), weather (null — flag off),
  gravity-area resync @0.5 s, `StreamLoadController.tick`, stream-pace forward, LOD-exclusion resync @0.5 s.
- `ModuleWorld._process` (`module_world.gd:391-419`): ≤1 pool-slot view-ramp step/frame (`:433-499`),
  cover ageing; self-disables when idle.
- `FacetFarRing._process` (`facet_far_ring.gd:312-350`): `_poll_async_rebuild` (swap upload when a build
  lands), `_prewarm_step` (one-shot, budgeted), then the **warm/emit state machine** — §2 W1.
- `CosmosSky._process` (`cosmos_sky.gd:664-799`): ~6 ephemeris evaluations, sun/moon/glare/star/shell
  transforms + ~20 shader-uniform writes, environment ramp. Runs unconditionally every frame.
- `main.gd:180-230`: clock advance, shell camera-set driver (`apply_camera_set` — cheap; sets `_pending`
  on drift), sun-dir forwards, SN3 scaled-body camera planes.
- `RemoteBridge._process` (`remote_bridge.gd:335-430`): telemetry fold (cheap), event drains, and — when
  frames are enabled — the **viewport readback capture** (GPU sync stall; `?frames=0` for measurements).
- HUDs: PerfHud (cheap), ThermometerHUD (3 env noise queries/frame), NavHUD (label writes/frame).

`_physics_process` (`player.gd:579-653`, every tick):
- `_heal_frame_desync`, `_move` (analytic floor/wall queries → `cell_value_at` → **GDScript**
  `TerrainConfig.generated_cell` + `FacetAtlas.junction_modify` per cell probed — `FP_CPPGEN` accelerates
  only the module's C++ generator, NOT this query path), `update_streaming`
  (`world_manager.gd:672-728`: collider gate scan, skin (off), **pool manage** + imminent logic,
  far update (off)), `maybe_reanchor`, `maybe_cross_facet` (4 × `own_dist`/tick; the commit path is §4),
  `_push_bodies` (shape query + allocation while moving), `_update_aim` (DDA), `_nav_tick` (f64 maps —
  cheap), `_attitude_tick`. In coast: `_orbit_coast_move` (Kepler step — cheap math).
- `GroundCollider.update` (`ground_collider.gd:169-200`): fully gated off unless awake debris is near —
  **correctly dormant**; the gate scan itself is a children iteration per tick (`world_manager.gd:967-983`).

### 1.3 Per-mode verdict table

| Runs every frame | walk | fly | orbit | fall | on-screen contribution |
|---|---|---|---|---|---|
| Shell warm scan+fail (W1) | ✔ | ✔ | ✔ (idle only when converged; never converges while drifting) | ✔ worst | **zero** (never emits) |
| Snowfall step (W2) | ✔ | ✔ | ✔ | ✔ | walk only, 2 Hz would suffice |
| Pool manage + crossing detect | ✔ | ✔ | ✔ churning | ✔ churning | walk/fly/landing only |
| Crossing commit work (W3/W4) | on real crossings | rare | ~continuous | ~continuous | **zero above the atmosphere** |
| View-ramp step + streaming | ✔ | ✔ | ✔ (LANDING_STREAM_KICK floors active grow even at altitude) | ✔ | near field visible only ≲ a few k blocks |
| Analytic phys queries (GDScript worldgen) | ✔ | ✔ | ─ (coast) | ─ | yes (movement) but 25× the native cost |
| CosmosSky full update | ✔ | ✔ | ✔ | ✔ | yes (sky always visible) |
| Thermometer/Nav HUD queries | ✔ | ✔ | ✔ | ✔ | yes at ≤5 Hz, not 60 |
| GroundCollider | gated ✔ | gated | gated | gated | correct as-is |
| Weather/clouds/skin/moon-ring | — (flags off) | — | — | — | n/a today |

---

## 2. The two always-on drains, mechanically

### 2.1 W1 — the warm gate that cannot converge (THE top fix)

`facet_far_ring.gd:458-478`:

```gdscript
for face in range(6):
  for a in range(k):
    for b in range(k):          # 6·K² = 3456 iterations, EVERY call
      ...
      if not _front_visible(fid, nrm, thresh):  # dot test — but still a call + dict lookups ×3456
        continue
      ... _ensure_cached(fid) only if uncached ...
      if Time.get_ticks_usec() - t0 > budget_us:   # ← charged for SCANNING, not just warming
        return false
```

The 3 ms budget (`WARM_BUDGET_MS`, `:24`) is compared against **elapsed time including the pure scan**.
On wasm the 3456-iteration GDScript scan alone exceeds 3 ms, so the loop exits `false` **even when zero
facets need warming**. Consequences, all confirmed by telemetry:
- `sh_wfail` climbs every frame in every regime (+3.5/frame on a flat ground walk with nothing pending
  but a stale `_pending`; +5.7/frame falling).
- `_pending` is never consumed → the surface re-emit never fires → far-ring/tier staleness (this is
  plausibly the live residue behind several "weld/see-through" symptom reports, independent of the
  geometry fixes).
- ~3 ms/frame is burned producing nothing — ≈7 % of a 21 fps frame, forever.
- The orbit branch (`:321-340`) runs `_warm_front` **unconditionally** every frame while unconverged;
  during a descent the drift/θ_h triggers (`:214-242`) keep re-snapshotting, so it *stays* unconverged —
  `FP_SHELL_ORBIT_IDLE` only helps after convergence, which the budget bug prevents.

**Fix shape (R1, GDScript-only):** count only *warm work* against the budget and return `true` when the
scan finds nothing uncached, regardless of elapsed time; plus make the scan itself O(visible) instead of
O(6·K²) (precomputed `PackedVector3Array` of facet centre-dirs iterated inline, or an incremental
front-set maintained across frames — the axis moves degrees per second, not per frame). Target:
`sh_wfail` stops climbing within 2 s of any drift, in **all** regimes.

### 2.2 W2 — snowfall main-thread bursts + hitch coupling

`snowfall_system.gd:67-78`: wall-clock accumulator, `MAX_STEPS_PER_FRAME=4`. After any ≥2 s frame
(crossing spike, shell swap, capture), the next `_process` runs 4 full steps back-to-back — 4× the
column scans, 4× the `set_voxel` remesh triggers, 4 ground rebuilds → snow_ms 126–145. The hitch
*reschedules itself*. Per-step cost is dominated by per-column GDScript worldgen noise
(`column_profile`, `generated_cell`, `apply_state_transitions` → `PerVoxelEnvironment` temperature)
— pure math with **no scene access until the write**, i.e. thread-safe by construction except the
final `_write_cell`.

**Fix shape (R2):** (a) drop catch-up: after a hitch, run **one** step and discard backlog
(`steps < 1`); (b) slice: 8 columns/frame continuously instead of 32/0.5 s bursts (same throughput,
flat cost); (c) regime-gate: no stepping when `radial_altitude() > ATMO_TOP` (nobody can see snow
accumulate from orbit); (d) optional, bigger: move the evaluate phase to a worker (the
`EnvSimWorker` pattern already written for the weather grid, `world_manager.gd:344-354`), main thread
only applies the ≤32 writes. (a)+(b)+(c) are trivial and remove the spikes; (d) removes the cost.

---

## 3. The fall collapse — full mechanism + what's still unexplained

Chain during a de-orbit descent (worst mode, ~5 fps):

1. **Shell thrash (biggest, half-fixed):** θ_h shrinks continuously → `shell_set_camera_abs`
   (`facet_far_ring.gd:227-232`) re-snapshots on every 5° θ_h / 13° drift change → `_pending` → the
   orbit branch warms+re-emits progressively (`SHELL_REEMIT_GROWTH=64`) → repeated **async builds** of a
   ~2000-facet mesh, each landing as a main-thread `add_surface_from_arrays` upload in `_swap_in_arrays`
   (`:438-453`). `FP_SHELL_ORBIT_IDLE` idles the scan only once converged — the budget bug (§2.1)
   plus continuous drift means it effectively never idles during the descent.
2. **Crossing churn (the phys_ms):** the ground track sweeps facets; every 6+ ticks a crossing commits
   inside `_physics_process` → `_rebuild_window_indices` (O(all edits), W4) + `redesignate` + the
   from-slot **view shrink snap** (`module_world.gd:1922` — a one-frame unload of the 128-view annulus:
   thousands of block frees → the known wasm dlmalloc convoy, memory `voxiverse-walk-perf-root-cause`)
   + far-ring exclusion resync + `_sync_gravity_areas` + collider note. None of it renders anything at
   150 km altitude.
3. **Snow steps** (W2) continue against the surface far below: snow_ms ≤71 mid-fall.
4. **`FP_LANDING_STREAM_KICK`** floors the active slot's grow pace even while the "active" facet is
   churning at altitude → speculative near-field streaming for facets that will not be the landing site.

**The ~470 ms unaccounted share of a 631 ms frame — ranked hypotheses + how to confirm:**

| Rank | Hypothesis | Why | Confirm with |
|---|---|---|---|
| 1 | **Far-ring swap upload + build snapshot** — `_swap_in_arrays` ArrayMesh upload (gl_compat = main-thread GL buffer upload) + `visible_fids` full scans around dispatch | fires exactly on descent re-emits; T2e already instruments it | read the `{"type":"farring"}` events (`remote_bridge.gd:420`) — `swap_ms`/`build_ms` per event, correlate with worst frames. **Zero new code.** |
| 2 | **Allocator convoy from the shrink-snap unload** (2) | matches the "all queues zero yet stalled" postport signature | correlate crossing events (`ev:"crossing"` records carry per-phase ms) with same-window worst_ms; A/B with R4 (shrink pacing) |
| 3 | **Instrument artifact** — proc/phys are TIME_PROCESS-family, invalid on threaded web; "unaccounted" may be GL driver/compositor time invisible to script timers | known-invalid metric | stop summing proc+phys; add a §6 main-thread ledger (µs accumulators around each `_process` leg — the `take_perf_attrib` pattern, already half-built) |
| 4 | First-use pipeline compiles (gl_compat) for materials that first appear during descent (atmo shell, backstop, glare) | classic one-off 100 ms+ | one-descent trace with Chrome about:tracing on the T4 rig; or pre-warm those materials in ShaderPrewarm |
| 5 | GDScript dict/array churn GC-like free storms from pool/edit churn | secondary of #2 | falls out of R3/R4 A/B |

The 38 s idle-ground stall is almost certainly **not engine work**: prime suspects are tab
backgrounding (rAF stops; telemetry `up_ms` keeps counting) or the capture readback path. Add
`document.hidden` + a "rAF gap" flag to telemetry (3 lines, `remote_bridge.gd`) before spending any
optimization effort on it.

---

## 4. Crossing cost — status of the fixed-frame design + the minimal-work crossing

`COSMOS-FIXED-FRAME-DESIGN.md` **is realized and live** (`FP_FIXED_FRAME=true`):
`redesignate()` skips the PlanetRoot write (`module_world.gd:1906-1911` — no
`NOTIFICATION_TRANSFORM_CHANGED`, no per-mesh-block re-place), the far ring is absolute
(`facet_far_ring.gd:140-150`), and the measured crossing frame itself was 1.7–19 ms across 13
crossings (CROSSING-FASTGEN). The 200–772 ms transform re-place is **gone**. What remains on/around a
crossing, in cost order:

1. **Post-crossing apply/upload burst (C1 p50 343 ms)** — the 96→128 annulus meshing lands as
   main-thread apply bursts (postport §1; `FP_INFLIGHT_GATE` feeds admission back but cannot shape
   *uploads*). This — not the crossing frame — is the walk-mode 1.3 s worst.
2. **From-slot shrink snap** (one-frame unload burst, `module_world.gd:1922` + `_ramp_pool_step:454-458`).
3. **`_rebuild_window_indices`** O(all edits) (W4) — grows with session snow.
4. Far-ring exclusion resync → `_pending` → (today) the W1 dead warm loop instead of a re-emit.
5. Gravity-area resync, collider core rebuild — bounded, fine.

**Minimal-work crossing** = the fixed-frame bookkeeping (already O(1)) + an **incremental per-fid edit
index** (R5) + **paced shrink** (R4) + a working deferred re-emit (R1). Nothing else on the crossing
frame is structural.

---

## 5. Ranked plan (impact ÷ risk, all flag-gated, NEVER-OOM, GDScript unless noted)

Ordering rule applied: always-on waste first (helps every mode), then fall, then crossing polish.
**Every gate below must run under the RIGHT condition** — a drifting/descending/edit-loaded state, not
a settled one (the prior fall fix passed a settled-state gate and did nothing live).

| # | Change | Flag | Expected win | Proof gate (headless unless noted) | Rebuild? |
|---|---|---|---|---|---|
| **R1** | **Warm-gate convergence + O(visible) scan** (§2.1): budget counts only `_ensure_cached` work; `return true` when nothing uncached; precomputed packed centre-dir array or incremental front set | `FP_WARM_TRUE_BUDGET` | kills the ~3 ms/frame all-modes burn; un-sticks every deferred re-emit (staleness class); descent stops thrashing | extend `verify_shell`: drive `shell_set_camera_abs` through a **continuous drift sweep** with an artificially tiny budget (simulating wasm) → assert `sh_wfail` stops climbing ≤N frames after each drift stops AND `sh_reemit>0`; plus surface-walk variant asserting `_pending` consumed | no |
| **R2** | **Snow de-burst** (§2.2 a–c): no catch-up, 8 cols/frame slicing, altitude gate | `FP_SNOW_SLICED` | removes the 30–145 ms periodic spike in all modes; zero snow cost in orbit/fall | `verify_feature` snow invariants must stay green (drive `step_now` directly — determinism preserved by keeping the step math untouched); new gate: scripted 3 s of 20 ms frames + one 2 s hitch → assert max snow work/frame ≤ slice bound, backlog discarded | no |
| **R3** | **Altitude regime gate** (the §0-W3 killer): one `regime()` source on WorldManager (`SURFACE / ASCENT / ORBITAL`, from `radial_altitude()` vs `ATMO_TOP`+hysteresis). In ORBITAL: `maybe_cross_facet` returns early (facet frozen), pool manage suspended (targets held), snow suspended (R2c), LANDING_STREAM_KICK inert; on descent through the gate: ONE redesignate to the sub-camera facet + stream kick | `FP_ALT_REGIME` | fall phys_ms 160–228 → ~0; no pool/edit/gravity churn above the atmosphere; allocator quiet during descent | **descent altitude-sweep gate**: scripted fall 400 k→0 (the `verify_spacefly` harness pattern, inline loops not closures) asserting redesignate count == 1 (at the gate), snow steps == 0 above gate, pool ops == 0 above gate, and pose/landing invariants unchanged vs flag-off (landing facet identical) | no |
| **R4** | **Paced shrink**: route the from-slot 128→96 and retire unloads through the existing ramp machinery (shrink in 16-block steps, 1 slot/frame) instead of the snap (`module_world.gd:454-458,1922`) | `FP_SHRINK_PACED` | removes the crossing/descent one-frame unload burst (allocator-convoy class) | crossing gate with slots pre-filled to 128: assert per-frame `max_view_distance` delta ≤16 and total unloaded blocks equal to snap path (same end state); live A/B on crossing worst_ms | no |
| **R5** | **Incremental per-fid edit index**: maintain `_edits_by_fid` (+ per-fid column/top maps) in `_write_cell`/revert; `_rebuild_window_indices` + `_translate_active` become O(active-fid) | `FP_EDIT_FID_INDEX` | crossing cost stops scaling with session snow (protects R1–R4 wins long-term) | gate seeded with **200 k synthetic snow edits** (the right condition): crossing `rebuild_ms` pinned < 2 ms; byte-equal index vs full rebuild | no |
| **R6** | **Shell swap staging**: split the async far-ring build into ~4 sector surface arrays; upload ≤1 sector/frame into the staging mesh, flip `_mi.mesh` when complete (old mesh stays visible meanwhile — the existing implicit double-buffer) | `FP_SHELL_STAGED_SWAP` | caps the descent's repeated upload spike (hypothesis-1 of §3); bounded worst-frame from re-emits | T2e farring events: swap_ms p95 pin under a scripted orbit→descent re-emit sweep; visual parity gate on emitted-set equality | no |
| **R7** | **Main-thread ledger + hygiene**: µs accumulators per `_process` leg (extend `take_perf_attrib`), `document.hidden`/rAF-gap telemetry, thermometer+nav HUD at 5 Hz, reuse the `_push_bodies` query object + gate it on `has_active_bodies_near` | (telemetry+micro) | closes the "unaccounted ms" question **with data**; ~1–3 ms/frame back; kills the idle-stall ambiguity | attribution sums ≥80 % of worst_ms on a scripted worst-case run; HUD text updates ≤5 Hz asserted | no |
| **R8** | Apply/upload reorder (postport P3): gaze/priority-ordered mesh-apply queue in godot_voxel | (engine) | walk C1 343 ms → spread | needs the ~24 min engine rebuild + patch; only after R1–R7 land (they may shrink C1 enough) | **yes** |

Explicitly NOT re-planned here: `FP_SHELL_ORBIT_IDLE`/`FP_COAST_FULL_DT` (landed), controller un-pin +
prefill-112 (landed), far-ring async (landed — R1/R6 complete it), the tier-depth geometry work
(owned by its own doc).

## 6. Cross-cutting: one frame budget, one scheduler

Today each amortized system carries a private budget (warm 3 ms, prewarm 3 ms, collider 24 ops, ramp
1 slot, snow 32 writes, LOD tick…) — worst frames are the **sum**. After R1–R5, fold them behind one
`FrameBudget` object (WorldManager-owned, ~2–3 ms/frame wasm): each system draws and yields; priority
= (visible now) > (imminent) > (background warm). This is a small GDScript refactor with an existing
pattern (`StreamLoadController` credit) and makes "no multi-hundred-ms freezes" a structural property
instead of N tuned constants. Rule for future sims (weather/clouds when re-enabled): **a sim may not
ship main-thread stepping** — it must use the `EnvSimWorker` pattern (the thread exists and is proven)
or draw from `FrameBudget`.

## 7. Verdict

The engine is not "too heavy" — walk/fly hold 54 fps when nothing misfires, draws are ~30–200, and the
sim layer is structurally dormant-by-default. The 5–21 fps regimes are caused by a small set of
**always-on loops that do no visible work**: a warm gate that mathematically cannot pass on wasm (W1),
a bursty main-thread snow step with hitch-coupling (W2), and a facet/pool state machine that keeps
servicing the ground while the player is in space (W3/W4). R1–R5 are all GDScript-only, individually
flag-gated, individually provable under drifting/descending/edit-loaded gates, and together they
target: fall ~5 fps → 30+, walk worst 1361 ms → the C1 residual (~300 ms, then R6/R8), and a flat
~5–8 ms/frame given back in every mode.
