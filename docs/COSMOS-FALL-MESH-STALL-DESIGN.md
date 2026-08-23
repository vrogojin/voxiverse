# COSMOS FALL MESH STALL — the de-orbit alt 200-800 collapse (fps ~3)

**Status: DESIGN (instrumented + attributed; no gameplay code in this pass).**
**Flags: `FP_REENTRY_BACKLOG_GATE` + `FP_REENTRY_REGROW_DEFER` (both default `false`, byte-identical off).**
Branch `perf/fall-mesh-stall`. Predecessor: `docs/COSMOS-FALL-STREAM-PACING-DESIGN.md`
(branch `perf/fall-stream-pace`, commit cc2ee78 — measured NEUTRAL live; §4 explains why, and why
this design is not a repeat of that miss).

---

## 0. The symptom (measured live, twice)

De-orbit fall from a settled ~2500-block orbit, drag-limited ~25-38 b/s radial descent.
In the altitude band **~870 → ~450** the frame collapses to **frame_ms 325-1125 (median ~390),
fps ~2.5** for ~20-25 s, then recovers instantly. Above the band the descent runs 60-140 ms
frames (fps 10-15, the separate orbital-descent baseline); below it, 120-180 ms to touchdown.

Two independent live falls show the identical signature
(`tools/remote-bridge/results/telemetry.jsonl.1`):

| run | seq (t₀ unix) | flood starts | peak `vox_gen` | deep-stall band | recovery |
|---|---|---|---|---|---|
| fix-OFF | off-full-1787480091 | alt 870.6 (t+88.7) | **5874** (alt 597) | alt 592→450: frame 347-1125 ms | t+110.7, alt 448, `vox_gen`=0 → next sample frame **21.9 ms** |
| fix-ON (cc2ee78) | fp-full-1787475560 | alt 846.9 (t+37.1) | **6807** (alt 597) | alt 597→312: frame 325-719 ms | t+66.5, alt 297, `vox_gen`=0 → frame 238→146 ms |

The prior-fix run floods and collapses **identically** — the pacing attempt changed nothing here.

---

## 1. (a) Step-1 attribution — what the ~380 ms IS (and is not)

All fix-OFF samples in the stall band (alt 150-900, proc_ms > 140, n=23):

| field | median | max | verdict |
|---|---:|---:|---|
| `frame_ms` | 202 (deep band 347-503) | 1125 | the symptom |
| **`vox_gen`** (VoxelEngine `tasks.generation`) | **2513** | **5874** | **the correlate — see below** |
| `pool_tasks` | `GenerateBlock,GenerateBlock,…` | — | engine pool saturated with GenerateBlock the entire stall |
| `vt_total_ms` (VoxelTerrain::_process main-thread, summed over pool) | 0.78 | 5.66 | NOT VoxelTerrain's own process |
| `vt_req_upd_ms` / `vt_req_load_ms` / `vt_load_resp_ms` / `vt_detect_ms` | ≤0.30 | ≤4.86 | not it |
| `vt_updated_max` / `vt_dropped_meshs` | 0 | 0 | no mesh-update burst on main |
| `vox_mesh` / `vox_main` | 3 / 0 | 106 / 149 | mesh+apply queues near-empty until the drain tail |
| `t_stream_us` (whole update_streaming tail) | 17.2 ms | 28.3 ms | the prior fix's target — 5% of the stall |
| `phys_ms` / `telem_ms` / `tex_ms` / `main_commit_ms` | 20 / 19 / 16 / 3.2 | 32 / 26 / 27 / 11 | normal background |
| `smooth_v2_commit_ms` | 15.76 (frozen value all run) | — | stale latch, not per-frame cost |
| `t_move_us` / `t_floor_us` / `t_aim_us` | 0.28 / 2.2 / 1.5 ms | **27.6 / 27.4 / 10 ms** | *uniform inflation* of every tiny bucket — the convoy signature |
| `bm_res`/`bm_bake`, `cu_want`, `g2_baked`, `sh_build`, `heap_mb` | 0 / −1 / 0 / 0 / 0 / flat 494.8 | — | block-LOD, cull, DEM, shell-build, heap growth all inert |

**Sum of every attributed bucket ≈ 90-110 ms worst-case; frame_ms is 350-500+.**
The remaining ~250-400 ms is main-thread time spent NOWHERE that GDScript or
VoxelTerrain::_process can see — and it tracks one variable exactly:

- collapse begins 1-3 samples after `vox_gen` exceeds ~1.5 k, is sustained while the backlog
  is 1.5-6.8 k, and **frame time recovers to 22-238 ms in the very sample where `vox_gen`
  reaches 0** — in both runs.
- the smaller post-416 restore surge (`vox_gen` 504→1087→0, ~3 s) does **not** collapse the
  frame (37-162 ms) — small backlog, brief.
- this is the documented engine-side class: `module_world.gd:2424` ("worst_ms 117-136 ms
  whenever vox_gen > 0 (even STANDING STILL) while the mesh/apply queues read 0") and the
  walk-perf root cause (WASM allocator/task-queue convoy: 6 pool workers grinding
  GenerateBlock contend the shared dlmalloc + ThreadedTaskRunner queue lock; every
  main-thread malloc/lock waits). At walking backlogs (~1.5-2.8 k of mostly-cheap blocks)
  it is a 117-136 ms hitch; at a 6-7 k flood of all-surface-class blocks it is a sustained
  350-500 ms/frame collapse.

**Attribution: the ~380 ms is main-thread starvation by godot_voxel's GenerateBlock backlog
(engine-side WASM worker contention), NOT any GDScript subsystem and NOT
VoxelTerrain::_process.** No new telemetry field is needed — `vox_gen` + `pool_tasks`
pin it, and `vox_gen` is the closed-loop input the fix uses.

(`proc_ms` is unreliable on threaded web — TIME_PROCESS reads whole-frame there; all
conclusions above use `frame_ms` + queue counters.)

## 2. (b) Root cause in code — what issues the 6-7 k-block flood

The flood is the **approach-anchor descent re-growth law** meeting a **ground-anchored viewer**
with **full-radius pool terrains**:

1. **`WorldManager._apply_approach_anchor`** (`godot/src/world/world_manager.gd:773-802`,
   driver `:759-768`, 100 ms debounce) computes
   `near_vd = CubeSphere.approach_view_distance(d, full=128, lo)`
   (`godot/src/cosmos/cube_sphere.gd:2774-2777`): 0 at d ≥ `ANCHOR_REL_HI` **900**, growing
   linearly to full **128** at the descent knee `lo = ANCHOR_REL_LO/ANCHOR_HYST ≈ 609`
   (`cube_sphere.gd:2736-2739`). On descent, d shrinks at the fall rate → the whole 0→128
   re-growth is emitted across alt 900→609 (~11 s at 25-38 b/s). **Both live floods begin at
   alt 870/847 — first debounced write after the 900 knee.**
2. The write lands on the single player VoxelViewer
   (`module_world.set_approach_anchor`, `godot/src/world/voxel_module/module_world.gd:492-497`)
   which is **pinned to the sub-player ground** by the anchor offset law — so each growth step
   demands a full disc of *terrain-intersecting* data around the future touchdown point (no
   air-cheap sphere half).
3. godot_voxel loads per paired terrain at
   **min(viewer.view_distance, terrain.max_view_distance)**
   (`docker/engine/cache/godot/modules/voxel/terrain/fixed_lod/voxel_terrain.cpp:1256-1258`).
   The pool slots sat frozen at **full max_view 128** through the orbit (the FP_ALT_REGIME
   freeze stops the per-tick machinery, not the terrain property), so the **viewer is the sole
   binding lever**, and every live slot (active + warm neighbour, `facet_neighbours`=1) loads
   its full box: ≈ (2·9+1)² × 9 ≈ 3.2 k data blocks/slot × ~2 slots ≈ **6-7 k GenerateBlock
   tasks** — matching the observed 5874/6807 peaks.
4. Web generation throughput is ~490 blocks/s (5874 drained in ~12 s) → the backlog holds
   thousands for ~20 s → §1's convoy → 2.5 fps until drained.
5. Independent confirmation: the **regime restore** at ATMO_TOP+PREP = 416
   (`world_manager.gd:733-746`, restore ~`:3155`) re-issues only ~0.5-1.6 k tasks post-416 —
   and does not collapse the frame. The stall is entirely the *pre-416* anchor flood; much of
   that flood is also **wasted** (generated against the stale pre-restore facet designation,
   re-issued after the 416 redesignation).

## 3. (c) The fix — two flags in `godot/src/cosmos/cube_sphere.gd`

Both default `false`; every new const lives beside the ANCHOR consts (`cube_sphere.gd`
~`:2736`). Recommended live config: **both ON**.

### 3.1 `FP_REENTRY_BACKLOG_GATE` — closed-loop, consumption-paced viewer growth (primary)

The attributed cost is the **backlog magnitude**, so govern growth by the backlog itself —
never open-loop by time/rate (the cc2ee78 mistake):

```gdscript
const FP_REENTRY_BACKLOG_GATE := false
const REENTRY_GEN_BACKLOG_MAX := 256   # max VoxelEngine tasks.generation admitting further view growth
const REENTRY_GROW_STEP := 8           # max viewer view_distance growth (blocks) per debounced anchor write

## Pure law (gate-testable): the next viewer view_distance given the last written one, the
## anchor law's want, and the live generation backlog. Shrink always passes (ascent release
## unchanged). Growth admitted only while the engine pool has drained below the cap, and then
## by at most REENTRY_GROW_STEP per write — so one gate-open write can never emit a giant annulus.
static func reentry_admit_view(last_vd: int, want_vd: int, gen_backlog: int) -> int:
    if not FP_REENTRY_BACKLOG_GATE or last_vd < 0 or want_vd <= last_vd:
        return want_vd
    if gen_backlog > REENTRY_GEN_BACKLOG_MAX:
        return last_vd
    return mini(want_vd, last_vd + REENTRY_GROW_STEP)
```

Code sites:
- `world_manager.gd` — new `var _anchor_last_vd := -1` beside the anchor state; in
  `_apply_approach_anchor` (`:801`, just before the `set_approach_anchor` call):
  read `var backlog := _voxel_gen_backlog()` and
  `near_vd = CubeSphere.reentry_admit_view(_anchor_last_vd, near_vd, backlog)`;
  `_anchor_last_vd = near_vd` after the write. The **offset_y write stays live every tick**
  — only the view component is gated (the viewer stays ground-pinned; streaming priority
  ordering, `FP_SUMMIT_STREAM` h_eff, and the `_anchor_released` latch are untouched).
- `_voxel_gen_backlog()` — new small helper: `VoxelEngine.get_stats().tasks.generation` via
  `Engine.get_singleton`/ClassDB string access (the `module_world.gd` no-hard-reference
  pattern); returns 0 when the module is absent (fallback path never reaches this code anyway
  — `_apply_approach_anchor` early-outs at `:762`). Cost: one dictionary read per debounced
  write (≤10 Hz) — `remote_bridge.gd:728` already calls it at 1-10 Hz.
- `_block_lod.set_effective_rim` coupling (`:809-810`) consumes the **gated** near_vd —
  correct by construction (the L1 rim tracks what the viewer actually loads).

Why the step clamp is right *here* and was neutral in cc2ee78: alone, an 80 b/s rate clamp
never binds (the natural law grows ~11 b/s at a 25-38 b/s fall — proven by the fix-ON flood
being byte-identical in shape). Under the backlog gate, growth happens in **gate-open bursts**,
and the step clamp bounds each burst's annulus (~one data-block shell ≈ 100-150 blocks) so the
backlog can overshoot `MAX` by at most one shell per live slot.

### 3.2 `FP_REENTRY_REGROW_DEFER` — don't re-grow high, land on the proven small disc

Everything generated at alt 900→460 against the pre-restore facet designation is barely
visible (the release ramp's own sub-τ premise) and partially re-issued by the 416 restore.
Defer the re-growth to where it is actually needed:

```gdscript
const FP_REENTRY_REGROW_DEFER := false
const REENTRY_REGROW_DEFER_ALT := 460.0  # radial alt above which a FAST descent holds the landing disc
                                         # (just above the ATMO_TOP+PREP=416 restore: release precedes it)
const REENTRY_HOLD_VIEW := 64.0          # the held near view — LAND_RAMP_HOLD_BLOCKS' proven landing disc
                                         # (far-ring chords cover 64-128, hole=0 proven)

## Pure law: clamp the anchor's wanted view to the landing disc while plunging fast above the
## defer altitude. `falling_fast` = _fall_vy_ema < -ENV_FALL_HOLD_VY (the FP_ENV_FALL_HOLD /
## FP_LAND_RAMP_HOLD shared position-based signal, world_manager.gd:1283-1296). Slow descents
## (vy < 20 b/s) never trigger it — they don't flood either.
static func reentry_hold_view(want_vd: float, alt: float, falling_fast: bool) -> float:
    if not FP_REENTRY_REGROW_DEFER or not falling_fast or alt <= REENTRY_REGROW_DEFER_ALT:
        return want_vd
    return minf(want_vd, REENTRY_HOLD_VIEW)
```

Code sites:
- `world_manager.gd _apply_approach_anchor`: `view_f = CubeSphere.reentry_hold_view(view_f, h,
  _fall_vy_ema < -CubeSphere.ENV_FALL_HOLD_VY)` between the law (`:800`) and rounding (`:801`).
  Uses `h` (radial `_radial_altitude_lattice`, the same ladder the 416 regime reads) — NOT
  `h_eff` (SUMMIT_STREAM makes h_eff ground-relative; the defer threshold must align with the
  416 restore altitude).
- `world_manager.gd:1283`: extend the vy-EMA compute gate to
  `FP_ENV_FALL_HOLD or FP_LAND_RAMP_HOLD or FP_REENTRY_REGROW_DEFER` (the signal must exist
  when only the new flag is on). Off ⇒ condition is the shipped expression (byte-identical).
- Note `min(64, law)` only binds below d ≈ 755 (the law reaches 64 there) — which is exactly
  why 3.1 must also run above it: the 0→64 leg alone is ~0.8-1 k blocks, still ≥ 3× the gate cap.

### 3.3 Composition (both ON — the recommended config)

alt > 900: viewer 0 (unchanged) → 900-460: growth capped at 64 AND backlog-gated/step-paced
(≤ ~1 k total, in ≤256-task slices) → 416: regime restore + redesignation exactly as shipped
(slot-driven, ungated, proven non-collapsing at ~1-1.6 k) → below 460 with the restore drained:
gate-paced growth 64→128 (~2.4 k blocks in ≤256 slices, ~5-6 s at the measured ~490 blocks/s)
→ touchdown with the landing-kick finishing on the ground (today's shipped behaviour).
Worst-case backlog by construction ≈ `REENTRY_GEN_BACKLOG_MAX` + one step-annulus/slot +
the untouched restore surge ≈ **≤ ~1.6 k, briefly** — the regime live data shows is
non-collapsing — vs today's sustained 5.9-6.8 k.

## 4. (d) Why this targets the attributed cost (and cc2ee78 could not)

| | cc2ee78 (`FP_STREAM_FALL_PACE` / `FP_REENTRY_VIEW_RAMP`) | this design |
|---|---|---|
| target | `t_stream` tail drivers (17 ms of a 390 ms frame) / open-loop 80 b/s growth-rate clamp | the `vox_gen` backlog itself (the variable frame_ms tracks 1:1) |
| feedback | none (time-based) | closed-loop on `tasks.generation` — cannot flood regardless of descent speed, teleports (`set_alt`), or future throughput changes |
| proof of miss | fix-ON fall floods to **6807** and collapses identically (§0 table) | gate cap 256 makes the 5.9-6.8 k state unreachable; A/B asserts `vox_gen` max in-band directly |

## 5. (e) Fall-through-terrain safety

- **Collision never reads the voxel mesh.** Floor/`blocked()`/`surface_y` are analytic
  (TerrainConfig + edit overlay — CLAUDE.md "Physics is analytic"; the
  FP_FLOOR_SURFACE_WELD / FP_FALLTHRU_PROBE class fixes guard the *query frame*, not mesh
  residency). Holding the *render/stream* view small during the plunge cannot delay any
  collision-relevant state. Precedent: `FP_LAND_RAMP_HOLD` already holds a 64 disc during
  fast falls by design (`cube_sphere.gd` LAND_RAMP_HOLD comment; hole=0 proven).
- The **416-regime restore path is untouched**: `_update_alt_regime`, `_alt_reentry_pending`,
  the one-shot redesignation and the landing-kick run exactly as shipped;
  `REENTRY_REGROW_DEFER_ALT` (460) sits above 416, so the near field lands on the true
  sub-camera facet before surface physics, per the R3 re-entry fix.
- The anchor **offset law is untouched** (viewer stays ground-pinned; no pose/facet coupling).
- The `_anchor_released` hysteresis latch is untouched (both laws clamp the *written* value).
- Ascent is untouched (shrink always passes both laws).
- NEVER-OOM: both laws only *reduce* requested residency; no new allocation.

## 6. (f) Gate plan — `godot/src/tools/verify_reentry_pace.gd` (headless, self-describing)

Follows the `verify_approach_anchor.gd` pattern (pure-law asserts + a stubbed module recording
`set_approach_anchor` writes via `approach_anchor_step_now`).

- **G-RP-LAW**: `reentry_admit_view` — shrink passes verbatim; gate-closed (backlog > MAX)
  holds `last_vd`; gate-open grows by ≤ `REENTRY_GROW_STEP`; monotone in `want_vd`; `last_vd`
  = −1 (first write) passes through.
- **G-RP-DEFER**: `reentry_hold_view` — clamps to `REENTRY_HOLD_VIEW` iff falling_fast AND
  alt > `REENTRY_REGROW_DEFER_ALT`; pass-through on slow descent / low alt; continuous at the
  release edge when composed with G-RP-LAW (no single write may grow > `REENTRY_GROW_STEP`).
- **G-RP-SWEEP**: flags forced on (script-local mirror of the laws, the verify pattern for
  const flags): a simulated 38 b/s descent 2500→0 with a synthetic backlog model
  (issued − 490·t, floored 0) must keep modeled backlog ≤ `REENTRY_GEN_BACKLOG_MAX` +
  2 step-annuli and still reach full 128 by alt 0.
- **G-RP-OFF**: flags off ⇒ the recorded `set_approach_anchor` (offset_y, vd) write sequence
  across an altitude sweep is byte-identical to shipped (the §3 laws return their inputs).
- **FLAT gate**: `verify_feature.gd` must stay **6042/0** (flags off ⇒ byte-identical).

## 7. (g) Live A/B protocol (the correct fall methodology)

Baseline is already captured: **off-full-1787480091** (`telemetry.jsonl.1`).

1. Deploy fix build (flags ON). `set_alt 2500` → `freeze_player on` → settle ≥30 s (confirm
   `att=space`, stable orbit_r) → `freeze_player off` → release into the real ~25-38 b/s
   drag-limited descent → touchdown, then 60 s walk.
2. Sample the **alt 200-800 band** from telemetry. PASS requires ALL of:
   - `frame_ms` median in-band **≤ 150 ms** (baseline ~390 deep / 202 whole-band) and no
     sustained (>3 consecutive samples) stretch above 350 ms;
   - `vox_gen` max in-band **≤ 2000** (baseline 5874/6807) — the mechanism check, not just
     the symptom;
   - lands with `player_y − surface_y ∈ [0, 4]` (no fall-through), `att` reaches `surface`;
   - post-landing walk fps within noise of the pre-flight surface baseline (~25-33) and a
     re-ascent to orbit re-releases the viewer (anchor ascent leg unchanged);
   - screenshot at alt ~600: far-ring/skin ground cover present under the held 64-disc (no
     black hole under the player — the FP_LAND_RAMP_HOLD hole=0 criterion).
3. Neutral/regression rule: if frame_ms median improves but `vox_gen` still peaks > 2 k, the
   gate is not binding (check the backlog read path) — do NOT ship on the symptom number alone.

## 8. Out of scope (recorded, not addressed here)

- The **10-15 fps orbital-descent baseline** above the flood band (frame 60-140 ms with
  `vox_gen` = 0) is a different cost (far-field/sky/telemetry mix) — not this stall.
- Engine-side convoy hardening (mimalloc / task-queue sharding) would shrink the per-unit
  backlog cost for ALL streaming, not just re-entry — tracked separately (walk-perf L2/#141).
- Slot-side `max_view_distance` during orbit stays 128 (the freeze keeps properties); gating
  it too would double-bound the flood but adds redesignation coupling risk for no additional
  benefit once the viewer lever is gated (engine takes the min).
