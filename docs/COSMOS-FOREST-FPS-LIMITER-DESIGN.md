# COSMOS — Forest-FPS Limiter: rest-frame decomposition, the observer term, the controller floor-trap, and the motion plan (task #129)

Status: **DESIGN ONLY** — no code changed. Companion to
`docs/COSMOS-FOREST-FPS-DESIGN.md` (#119) and `docs/COSMOS-APPLIED-PROBE-CALM-DESIGN.md` (#123).
Evidence: 1,544 live telemetry windows (`tools/remote-bridge/results/telemetry.jsonl`,
2026-08-14, standing warm forest, spd 0, ~6 min) + a served-pck constant dump
(`build/web/index.pck` of this deploy worktree, `load_resource_pack` +
`get_script_constant_map`).

---

## 0. Executive verdict (honest version)

1. **Rest fps is NOT limited by any engine subsystem we instrument.** Every
   instrumented consumer is flat-zero at rest (vt_total 0.02 ms, vox_gen/mesh/main 0,
   main_commit 0, snow 0.26, env 0.02, tex 0, smooth_* 0, sh_reemit frozen at 121,
   `sh_pending_src` bit-identical across the whole capture — CALM holds). Yet
   **99.5 % of 0.25 s windows contain a ≥33 ms frame** (worst_ms p50 = 37.4,
   hitch rate 5.04/s, hitch-per-window mode 1–2, only 6.9 % zero-hitch windows).
2. That per-window slow frame is **quasi-periodic (~5 Hz), not stochastic**
   (under a random 9 %-per-frame model P(window has ≥1) ≈ 75 %, P(0) ≈ 25 %;
   measured 93 %/7 % — under-dispersed ⇒ a clocked source). The only ~4–5 Hz
   clocked main-thread work left standing after the subsystem exoneration is the
   **telemetry observer itself** (the 4 Hz `_send_telemetry` snapshot,
   `remote_bridge.gd:544-716`, + the 0.5 Hz ambient viewport-readback capture that
   the code itself annotates as "the ~35 ms readback lands this frame",
   `remote_bridge.gd:895`) — plus whatever genuine residual hides under it.
   **This cannot be fully proven from the current fields** (the snapshot cannot
   observe its own cost) → §5 designs the byte-off decomposition patch that settles
   it in one deploy.
3. **The controller is provably in a self-made trap regardless of which of those
   it is** — and this is the part that hurts the *played* game. The adaptive
   setpoint is `clamp(floor_p10 × 2.0, 18, 45)` (`stream_load_controller.gd:136-139`,
   margin/max `cube_sphere.gd:2273-2274`, served `FP_CTRL_ADAPTIVE=true` — pck dump).
   The floor window samples **frame periods** (`LiveSource.poll` inter-poll wall
   delta, `stream_load_controller.gd:274-278`). After every slow frame the browser's
   rAF fires a **catch-up frame with a ~12 ms period**; those catch-up periods are
   what p10 reads (`floor_p10 = 12.2` — physically impossible as a *sustained*
   period on a 60 Hz display). So: more hitches → more catch-up samples → **lower**
   floor → setpoint 24.4 — just under the very p90 (25.5) the hitches produce →
   overload latched → **credit pinned 0/oscillating 0–0.3 at rest with zero
   streaming demand** (vox_gen 0). The measurement loop *is* the feedback trap
   (obs-2 class, one layer further out than #119: this time the estimator, not a
   consumer, closes the loop).
4. **Rest is fine; motion is the deliverable.** Best-window fps reaches 60.0+
   (p90 fps = 60.0 in this capture) whenever the ~5 Hz spike happens to miss;
   the unobserved played rest state is likely at/near vsync. The user-visible
   problem is **walking fps 20–30**, which today starts from credit 0 (starved
   streaming, see-through, mesh lag) *because of* the trap in (3). Fix F1 unpins
   it — but has a hard **interlock**: with credit flowing, walking re-arms the
   far-tree full rebuild (`FT_DELTA_MIN_MOVE = 2.0` blk, walk 5.5 blk/s ⇒ 1.4 blk
   per 250 ms step ⇒ rebuild every ~2nd step ≈ 2 Hz; run 9.5 blk/s ⇒ every step
   = 4 Hz) at the #119-measured ~50–60 ms each ⇒ 10–23 % duty — the #119 attacker
   returns through the door F1 opens. F2 (below) must ship with F1.

---

## 1. What we measured (live, served build)

### 1.1 Served flag set (pck dump, this worktree's `build/web/index.pck`)

```
FP_CTRL_ADAPTIVE=true   CTRL_ADAPTIVE_MARGIN=2.0  CTRL_ADAPTIVE_MAX_MS=45.0
CTRL_FRAME_BUDGET_MS=18 CTRL_WINDOW_FRAMES=30     CTRL_WINDOW_PCTL=0.9
CTRL_FLOOR_PCTL=0.1     CTRL_FLOOR_WINDOW_FRAMES=1800
FP_INFLIGHT_GATE=true   FP_M2_LOD=true
FP_FAR_TREES_DELTA=true FP_FAR_TREES_NEARCULL=true FP_FT_STALE_REBUILD=true
FP_FT_NEAR_GUARD=true   FT_DELTA_MIN_MOVE=2.0      FAR_TREES_STEP_MS=250
FP_APPLIED_PROBE_CALM=true  FP_SHELL_SURF_CAP=true  FP_FARRING_FULL_COVER=true
FP_LOAD_DEFER=true      FP_JOB_LANE=true           FP_WEATHER_THREAD=false
FP_STREAM_IDLE_DIET=<ABSENT — not in served build>
```

### 1.2 Rest distributions (1,544 valid windows, warm forest, spd 0)

| field | p10 | p50 | p90 | max | reading |
|---|---|---|---|---|---|
| fps | 50.8 | 55.8 | 60.0 | 62.8 | near-vsync between spikes |
| worst_ms (true window max, `remote_bridge.gd:373-383`) | 33.7 | **37.4** | 55.6 | 378 | ≥33 ms frame in 99.5 % of windows |
| phys_ms | 4.8 | 5.6 | 7.3 | 19.1 | constant idle cost (see §4.3) |
| ctrl_ms | 0.20 | 0.24 | 0.32 | 4.9 | controller tick exonerated |
| vt_total_ms | 0.02 | 0.02 | 0.02 | 0.30 | hitch is NOT VoxelTerrain::_process |
| vox_gen / vox_mesh / vox_main | 0 | 0 | 0 | 0 | zero streaming demand at rest |
| main_commit / snow / env / tex_spent / smooth_* | ~0 | ~0 | ~0 | ≤1.2 | all exonerated |
| draws / prims | 118 / 515k | 119 / 516k | 119 / 516k | — | constant; diet A/B already showed −110k prims moves nothing |
| stream_credit | 0.0 | 0.10 | 0.30 | 1.0 | pinned-oscillating at rest |
| frame_worst_ema vs setpoint | — | 25.5 vs 24.4 | — | — | marginal permanent overload |
| floor_p10 | 11.9 | 12.2 | 12.7 | — | **below vsync — catch-up artifact** |

Frame accounting: 55.8 fps over a 0.25 s window ≈ 14 frames ≈ **13 × ~16.5 ms
(vsync) + 1 × ~37 ms**. Eliminate the one spike → 60 fps. There is no "18 ms
median frame" — the median window is a vsync train with one clocked stall in it.

`hitches` increments (HITCH_MS = 33, `remote_bridge.gd:118`): per-window histogram
{0: 7 %, 1: 56 %, 2: 36 %, ≥3: 1.4 %} ⇒ mean 1.30/window = 5.2/s. The 4 Hz
snapshot + 0.5 Hz capture account for 4.5/s of clocked candidates; ~0.5–0.7/s
is either a second source or snapshot cost split across two frames (eval + send).
cap=1 windows are NOT worse than cap=0 (worst p50 37.1 vs 37.4) — consistent with
an every-window stall that the capture merely coincides with (max() doesn't stack).

### 1.3 Why the EMA reads 25.5

The controller p90 is the 4th-largest of a 30-frame sliding window
(`stream_load_controller.gd:122-131`), ≈ 0.53 s ≈ 2 snapshot frames + capture +
residual. With 2–3 clocked ~37 ms frames + 1–2 ~25 ms shoulder frames per ctrl
window, the p90 sits 24–27 — precisely the observed marginal-overload hover and
the 0↔0.3 credit oscillation. Nothing about the *terrain* is in this loop.

---

## 2. Question 1 answered — the ~25 ms "worst-frame at rest"

**It is not smooth_v2, not phys, not shell verts, not far-ring re-emits, not the
far-tree step** (DELTA holds at rest: `facet_far_trees.gd:811` skips the rebuild
when `_rebuild_inputs_changed` is false; camera still + epoch/edit/nearcull-fp
frozen — and the guard path `facet_far_trees.gd:775-779` is ≤0.5 ms by
construction). It is a **~4–5 Hz clocked main-thread stall of ~20–40 ms whose
prime suspect is the measurement pipeline itself**:

- `_send_telemetry` (4 Hz, `remote_bridge.gd:544`): builds the full ~130-field
  message — `VoxelEngine.get_stats()` dict (`:598`), five `world.call()` telemetry
  dicts (`:846-878`), a **synchronous `JavaScriptBridge.eval`** for the WASM heap
  size (`:536`, one per window), `JSON.stringify` + `send_text` (`:715`).
- `_maybe_capture_frame` (every ~2 s, frames-dir timestamps): viewport
  `get_image()` GPU→CPU readback (`remote_bridge.gd:908-913`) — self-documented
  "~35 ms readback" (`:895`). The #119 exoneration ("cap=0 windows still bimodal")
  covered only THIS capture path, **never the 4 Hz snapshot** — the snapshot runs
  in every session the bridge is connected, i.e. in every measurement we have
  ever taken. It is the one 4 Hz main-thread consumer with no timer on itself.

**What we cannot claim yet:** that the snapshot alone costs ≥33 ms. GDScript dict
building + stringify of ~2 KB "should" be single-digit ms; the eval and the WS
send are the plausible heavy tails on web. There may be a genuine engine-side
~1–2 Hz residual underneath. **This is exactly what §5's patch discriminates in
one deploy** — and the discrimination is cheap because the hypothesis is
falsifiable with a query knob alone (`?telem=1hz`: if hitch rate drops 5 → ~1.5/s
and worst_ms p50 → ~17, the observer is the attacker; if it stays ~4/s, a real
source remains and the new sub-timers name it).

---

## 3. The controller floor-trap (proven from current data) — fix F1

### 3.1 Root cause chain (all live, all cited)

1. `LiveSource.poll()` samples **frame periods** (`stream_load_controller.gd:277`).
2. Browser rAF compensates a slow frame with a fast next callback ⇒ every ~37 ms
   frame mints a ~12 ms *period* sample.
3. The floor window's p10 therefore reads ≈ the catch-up period, **not** the
   achievable steady period (`_floor_p_low`, `stream_load_controller.gd:175-184`):
   live floor_p10 = 12.2 on a display whose steady floor is 16.7.
4. Adaptive setpoint = `clamp(12.2 × 2.0, 18, 45)` = **24.4**
   (`stream_load_controller.gd:136-139`).
5. The clocked ~5 Hz stall holds the window p90-EMA at ~25.5 > 24.4 ⇒ overload ⇒
   AIMD ×0.5 ⇒ **credit 0** (`:141-145`), releasing to 0.1–0.3 only in clean
   half-seconds, then re-cut. `credit_ok = credit > 0.0` feeds every gated tier
   (`world_manager.gd:1343-1344` → `facet_far_ring.gd:1431`).
6. Perverse invariant: **the more the observer (or any spike source) hitches, the
   lower the floor estimate falls** — the setpoint chases its own attacker
   downward. The design intent ("a steady 33 ms client is NOT overloaded,
   setpoint ≈ 43", `cube_sphere.gd:2250-2257`) assumed floor_p10 ≈ steady period;
   catch-up sampling breaks that assumption on every vsynced browser.

### 3.2 F1 — `FP_CTRL_FLOOR_VSYNC` (byte-off, 1 const + 1 clamp)

- `cube_sphere.gd`: `const FP_CTRL_FLOOR_VSYNC := false` (flip at export A/B, the
  sed-at-export pattern used for FP_CTRL_ADAPTIVE, `cube_sphere.gd:2321`) +
  `const CTRL_FLOOR_MIN_MS := 16.0` (just under 60 Hz vsync; deliberately NOT
  display-queried — deterministic for gates, and 120 Hz clients only get a
  *more* conservative floor).
- `stream_load_controller.gd:_floor_p_low()` — one line under the flag:
  `return maxf(samp[idx], CubeSphere.CTRL_FLOOR_MIN_MS)`.
  Flag off ⇒ byte-identical return path.
- Effect on the live numbers: setpoint = clamp(16.0 × 2.0, 18, 45) = **32**.
  Rest EMA 25.5 < 32 ⇒ overload clears ⇒ credit → 1.0 at rest and stays ≥0.5 in
  moderate motion. Genuine overload (sustained ~30 fps ⇒ p90 ≈ 33 > 32) still
  trips — the protective envelope survives; the max clamp 45 is untouched.
- Determinism/gates: adaptive-mode square-wave gates (G-M2-CTRL family) feed
  synthetic periods ≥ 18 ms ⇒ p10 ≥ 18 ⇒ the clamp is inert there —
  bit-identical traces. New gate **G-CTRL-VSYNC**: synthetic source alternating
  {37, 12} ms periods; assert setpoint ≥ 32 flag-on and == 24.4 flag-off.
- NEVER-OOM: no allocation; pure arithmetic.

**Do not ship F1 without F2** — see the interlock (§0.4): F1 re-admits the
far-tree rebuild PWM in motion.

---

## 4. Question 2 — motion forest fps 20–30: model + plan

The current capture is rest-only (spd 0 throughout); motion needs Run C of §6.
The motion frame model from code + #119 measurements, in expected size order:

1. **Streaming starvation → burst duty (today's regime, credit 0).** At credit 0
   the mesher apply budget floors at 0.25 × 2 ms = 0.5 ms/frame and 1 grant/tick
   (`stream_load_controller.gd:195-202`, `CTRL_RELIEF_FLOOR cube_sphere.gd:2244`);
   pool pace = 0 while gated (`:211-212`). The player outruns coverage; when
   credit blips, deferred volume lands in bursts (the #123 candidates arm only
   under this trickle: `_noblack_near_meshed` probes `facet_far_ring.gd:1728+`,
   applied-ladder shrink/regrow excursions). F1 removes the false pin so
   admission is continuous instead of PWM — the single biggest expected motion
   win, *and* it un-freezes the visible mesh-lag/see-through symptom.
2. **Far-tree rebuild duty once credit flows (the F1 interlock).**
   `step()` (`facet_far_trees.gd:763-827`) re-arms per `FT_DELTA_MIN_MOVE = 2.0`
   (`cube_sphere.gd:930`, check `facet_far_trees.gd:996`): walk ⇒ ~2 Hz, run ⇒
   4 Hz full `_rebuild_meshes` (`:1169`) + `_rebuild_cards` (`:1047`) at the
   #119-measured ~50–60 ms ⇒ **10–23 % of frame time**. Fix **F2**, two stages:
   - **F2a (const A/B, zero code):** `FT_DELTA_MIN_MOVE` 2.0 → 12.0. Cards/meshes
     live at ≥128 blk; a 12-blk re-arm hysteresis moves the *sort/fade reference*,
     not tree world positions (records are absolute per-facet; fades are
     dist-only — `COSMOS-FOREST-FPS-DESIGN.md §4` skip-is-pixel-identical
     argument applies between re-arms). Duty falls 6×: walk re-arms every ~2.2 s.
     Visual risk: band-edge trees hand off up to 12 blk late — at 448 blk that is
     sub-pixel; the NEARCULL guard (`facet_far_trees.gd:775-779`) still heals
     far-over-near every 250 ms independently.
   - **F2b (the real fix, flag `FP_FT_REBUILD_ASYNC`):** move the two rebuild
     loops onto JobLane (`FP_JOB_LANE=true` live; lane pattern
     `world_manager.gd:851-855`): worker builds the PackedFloat32Array instance
     buffers from the (already worker-built, `_reap_enum`) record cache;
     main thread only `set_buffer` + counts (~few ms upload). Records are
     appended by `_reap_enum` on main and read by the rebuild — hand the worker
     an immutable snapshot reference (the per-facet arrays are replaced, never
     mutated in place, same discipline as the enum worker). Chop query
     (`_is_chopped`, `facet_far_trees.gd:741-744`) is a main-thread Callable —
     snapshot the edit-overlay keys for the wanted facets pre-dispatch (bounded:
     edits near the player only). Est: motion far-tree main cost ≤3 ms/step.
3. **Physics/streaming idle+motion floor.** phys_ms 5.6 at *rest* (p90 7.3,
   max 19) = full-fat `update_streaming` every tick (`world_manager.gd:1185`) +
   ground collider + analytic floor queries; it grows with motion. The designed
   `FP_STREAM_IDLE_DIET` (`COSMOS-STREAM-IDLE-DIET-DESIGN.md`) is **absent from
   the served build** (pck dump) — ship order stays CALM(live) → F1/F2 → diet;
   re-baseline the floor after F1 (the spikes contaminate today's floor_p10).
4. **The same ~5 Hz stall source, if it is not the observer**, rides on top of
   motion frames identically (+20–40 ms at 5 Hz ⇒ −8–12 fps at 30 fps) — §5
   settles it.

---

## 5. The byte-off instrumentation patch — `FP_TELEM_FRAME_DECOMP`

Pure GDScript (bridge + world_manager), no engine rebuild, flag default **false**
(and additionally inert when the bridge is not connected). All state is
fixed-size ints/floats — never-OOM. Adds ~10 fields to the 4 Hz message only.

### 5.1 New per-window fields + exact measurement sites

| field | site | what |
|---|---|---|
| `fh` (6 ints) | `remote_bridge.gd:_process` next to the existing `real_delta` accumulation (`:379-384`) | frame-period histogram bins `[<14, 14–20, 20–25, 25–33, 33–50, ≥50]` ms — makes worst_ms/EMA reconstruction exact instead of max-censored |
| `telem_ms` | bracket the whole `_send_telemetry` body with `Time.get_ticks_usec()`; **latch and emit in the NEXT window's message** (self-measurement lag) | the snapshot's own cost — the missing timer |
| `eval_ms` | around `JavaScriptBridge.eval` in `_wasm_heap_mb` (`:536`) | the sync JS bridge round-trip |
| `cap_ms` | around `tex.get_image()` (`:913`) | the readback, per capture window |
| `sub_ms` | connect `RenderingServer.frame_pre_draw`/`frame_post_draw` once in the bridge; window-max of the bracket | main-thread render submit + GL flush proxy (the only script-visible render bracket on gl_compat) |
| `phys_worst_ms` | usec bracket around the body of `WorldManager._physics_process`, window-max (same `_snow_us_max` pattern, `world_manager.gd:828-830`) | per-tick physics spikes the 4 Hz-sampled Performance monitor hides (max 19 seen) |
| `ft_ms` | bracket `_far_trees.step(...)` call site `facet_far_ring.gd:1431`, window-max | far-tree step incl. guard + any rebuild |
| `ring_ms` | bracket the far-ring per-frame step block that contains `:1431` (one bracket, whole tier pump), window-max | far-ring main-thread frame cost |
| `wm_proc_ms` | bracket the body of `WorldManager._process` (`world_manager.gd:816`), window-max | everything §world runs per frame in one number |
| `unattr` | in bridge `_process`: count frames with `real_delta > 25 ms` where that same frame's max(bracketed segments) < 10 ms — requires the brackets above to latch per-frame maxima before the bridge reads them (bridge `_process` runs after WorldManager in tree order; verify with `process_priority`) | **the verdict field**: clocked stall frames that none of our timers own |

### 5.2 Observer-diet knobs (measurement hygiene, same patch)

- `?telem=1hz` (relay/query param, like `?frames=0`, parsed at
  `remote_bridge.gd:328`): snapshot period 0.25 s → 1 s. **The primary A/B
  discriminator** — zero new code paths in-engine beyond the period.
- Heap eval decimation: run `_wasm_heap_mb` every 4th window (heap moves slowly;
  field repeats in between).
- These change *observed* sessions only; the played game never runs the bridge.

### 5.3 A/B protocol (one deploy, three runs, same forest spot)

- **Run A (discriminator):** rest, `?frames=0&telem=1hz`. Read `fh` (now the
  histogram survives the lower snapshot rate). Verdict table:
  - hitch rate ~5/s → ~1.2/s AND `fh[≥33]` ≈ snapshot count ⇒ **observer is the
    attacker**; true rest ≈ 60 fps; close #129-rest as measurement artifact;
    keep F1 (the trap is real regardless — it acted on observer spikes, and will
    act on any future genuine ones) and proceed to motion.
  - hitch rate stays ≥4/s ⇒ genuine 4–5 Hz engine source ⇒ Run B fields
    (`unattr`, `sub_ms`, `phys_worst_ms`, `wm_proc_ms`) name or exclude it; if
    `unattr` stays high with all brackets low ⇒ browser/compositor side (GC,
    WebGL flush) ⇒ attack via alloc diet / submit batching, not tier logic.
- **Run B:** rest, `?frames=0`, 4 Hz, decomp on — direct read of `telem_ms`,
  `eval_ms`, `unattr`.
- **Run C (motion):** 60 s walk + 30 s run loop through the forest, `?frames=0`,
  decomp on, once WITH F1+F2a export-flipped and once without (4 sessions total).
  Success metric: walking fps p50 ≥ 45, `fh[≥33]` rate ≤ 1/s, no see-through
  (NEARCULL guard events steady), `stream_credit` p50 ≥ 0.5 while walking.

### 5.4 Gates

- **G-DECOMP-OFF:** flag off ⇒ telemetry message keys byte-identical (snapshot a
  reference message in the headless harness; compare key sets).
- **G-DECOMP-COST:** flag on, synthetic 300-frame run ⇒ sum of bracket overhead
  < 0.1 ms/frame (usec-bracket the brackets in the gate itself).
- **G-CTRL-VSYNC** (§3.2) for F1; far-tree gates G-FT-* re-run for F2a (const
  change is inside existing DELTA gate coverage — `verify_far_trees` asserts
  rebuild-on-move which still holds at the 12-blk threshold with a longer drive).

---

## 6. Ship order & risk

1. **P0 — instrumentation + knobs** (`FP_TELEM_FRAME_DECOMP`, `?telem=1hz`):
   no behavior change, unblocks every later verdict. Deploy, Run A/B.
2. **P1 — F1 (`FP_CTRL_FLOOR_VSYNC`) + F2a (`FT_DELTA_MIN_MOVE` 12.0) together**,
   export-flipped as one A/B: rest must stay ≥ current (nothing at rest consumes
   credit except the far-tree step, which DELTA already skips), motion Run C is
   the acceptance test. Rollback = flip the two consts back (content redeploy).
3. **P2 — F2b (`FP_FT_REBUILD_ASYNC`)** once Run C confirms the far-tree duty is
   the next motion term; then **FP_STREAM_IDLE_DIET** (already designed) with the
   floor re-baselined post-F1.

Failure modes considered: (a) F1 unpins credit on a genuinely weak client —
bounded: setpoint 32 still trips at sustained <31 fps, AIMD unchanged, and the
inflight gate (`FP_INFLIGHT_GATE=true`, hysteresis latch
`stream_load_controller.gd:86-91`) still holds surfaces 3–4 through real backlog;
(b) F2a visual pop — bounded to ≤12 blk of hand-off hysteresis at ≥128 blk
distance, NEARCULL cull-only guard unaffected; (c) decomp observer cost — gated
by G-DECOMP-COST and bridge-connected-only.

## 7. Lessons (for the memory index)

- **The observer had no timer on itself.** Every "worst frame" number we have
  ever taken contained the 4 Hz snapshot whose cost was never measured; the #119
  cap=0 exoneration covered the capture path only. Rule: any periodic
  measurement emitter must emit its own previous-cycle duration.
- **Never feed a floor estimator raw frame *periods* on a vsynced browser** —
  rAF catch-up frames make p10 read below the physical floor, and the adaptive
  setpoint then tracks its own attacker downward (measurement-in-the-loop
  feedback trap, obs-2 class).
- **Window-max fields cannot distinguish clocked from stochastic sources** —
  the under/over-dispersion of *count* fields (hitch increments per window) can,
  for free.
