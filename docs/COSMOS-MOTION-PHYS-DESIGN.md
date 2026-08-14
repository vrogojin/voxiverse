# COSMOS — Motion phys_ms root cause: monitor semantics, the in-bracket streaming tail, and the tick-once fix (FP_STREAM_TICK_ONCE)

Status: **DESIGN ONLY** — no code changed. Companion to
`docs/COSMOS-FOREST-FPS-LIMITER-DESIGN.md` (#129) and
`docs/COSMOS-THREAD-OFFLOAD-DESIGN.md`.
Evidence: live walk telemetry (phys_ms median 24.6 / max 44.5 walking vs 5.6 at
rest, forest facet ~1754), a served-pck constant dump of THIS deploy worktree's
`build/web/index.pck` (`load_resource_pack` + `get_script_constant_map`), and the
engine source of the custom build (`docker/engine/cache/godot/main/main.cpp`).

---

## 0. Executive verdict (honest version)

1. **`phys_ms` does not mean what the motion decomposition assumed.**
   `phys_ms` is `Performance.TIME_PHYSICS_PROCESS`
   (`godot/src/net/remote_bridge.gd:683`). In the engine that monitor publishes,
   **once per second**, the **maximum duration of a single physics step**
   observed during that second, then resets: per-step
   `physics_process_max = MAX(step_wall_us, …)` at
   `docker/engine/cache/godot/main/main.cpp:4517-4518`, published only inside the
   1-second block at `main.cpp:4588` (`set_physics_process_time(physics_process_max)`,
   reset 4 lines later). It is **not** a per-frame physics time and is **not
   additive** with observer/render terms. "Motion frame ≈ phys 24.6 + observer 8
   + render 38" is arithmetically invalid. The correct reading of the live data:
   **while walking, at least one physics tick per second costs ~24.6 ms (median
   of the per-second maxima), up to 44.5 ms; at rest the worst tick per second is
   5.6 ms.** (`telem_ms` ~8 ms runs in the bridge's `_process` — outside the
   physics bracket — and is additionally observer-only.)
2. **The GroundCollider is exonerated** — the prime suspect is innocent (§2).
   It is hard-gated on nearby awake debris and does literally zero work while
   walking with nothing broken; when active it is drift-debounced and op-budgeted
   to single-digit ms per tick by construction.
3. **The real structure of the cost:** the *entire* gameplay+streaming
   orchestration pipeline runs inside the physics bracket —
   `Player._physics_process` (`godot/src/player/player.gd:786`) calls
   `world.update_streaming(position)` (`player.gd:822`) **every physics tick**,
   and a slow render frame runs **2 ticks** (`physics/common/max_physics_steps_per_frame=2`,
   `godot/project.godot:46`), so the whole ~200-line streaming tail
   (`godot/src/world/world_manager.gd:1185-1390`) executes **twice on exactly the
   frames that are already slow**. The engine's physics bracket additionally
   contains `PhysicsServer3D` sync/flush, `NavigationServer3D.process`, and **two
   `MessageQueue::flush()` calls per step** (`main.cpp:4462-4520`) — deferred
   work queued by worker threads (tex-bake worker, JobLane) can execute inside
   the bracket and be attributed to phys_ms.
4. **Motion-scaling terms** (§3): at rest the analytic movement funnel collapses
   to one memoized O(1) floor query and the tail's pacers are demand-idle; while
   walking, 6 `blocked()` wall probes + un-memoizable forest floor scans run per
   tick, and the tail's bakers/governors have both demand and a corrupted
   headroom signal (the 2nd tick of a catch-up frame measures a ~0 ms
   "inter-call frame delta" ⇒ reads as headroom precisely when overloaded,
   `world_manager.gd:1316-1320`, `:1354-1358`).
5. **What cannot be proven offline:** which single tail item owns the 24.6 ms
   worst tick. The decomposition instrument already exists —
   `FP_FALL_TIMING` (t_move/t_stream/t_floor/t_aim/t_pushbodies window-max µs,
   `player.gd:798-823`, `:896-901`, `:1841-1845`, shipped via `fall_timing()` →
   `remote_bridge.gd:894-898`) — but it is **false in the served pck** (dump,
   §1). P0 is a flag flip + redeploy, zero new code.
6. **Fix:** `FP_STREAM_TICK_ONCE` (§4) — run the *safety head* of
   `update_streaming` every tick, the *orchestration tail* at most once per
   render frame. Byte-off, gl_compat-safe, never-OOM, and **zero fall-through
   risk** (no collision-path state is touched; the collider update stays
   per-tick). Expected: walking phys_ms median 24.6 → ~14-17 (§4.4), with
   second-order frame-time gains from breaking the catch-up feedback.

---

## 1. Served build verification (the FACETED-flip trap check)

Dumped from this worktree's `build/web/index.pck` (the exact serving artifact):

```
FACETED=true                 FP_ANALYTIC_COL_MEMO=true   FP_FLOOR_MEMO=true
FP_FLOOR_BOUNDED=true        FLOOR_BOUNDED_MARGIN=96     FLOOR_MEMO_CAP=4096
FP_FALL_TIMING=false   <-- the decomposition instrument is OFF live
FP_TELEM_FRAME_DECOMP=true   FP_CTRL_FLOOR_VSYNC=true    FP_CTRL_ADAPTIVE=true
FP_STREAM_IDLE_DIET=<ABSENT> FT_DELTA_MIN_MOVE=2.0       FP_VEL_PREDICT=true
FP_SEAM_SLOPE_WELD=true      FP_DATUM_BAKE=true          FP_QUERY_FRAME_GUARD=true
FP_FLOOR_SURFACE_WELD=true   FP_CHOP_DEBRIS_CALM=true    FP_CHOP_COLLIDER_CARVE=true
FACET_TEX_BAKE_BUDGET_MS=5.0 FP_TEX_BAKE_WORKER=true     FP_FACET_TEX=true
FP_PLANET_MAP=true           FP_BG_PREBAKE=true          FP_GLOBAL_RELIEF_DATA=true
FP_DEM_DEFER=true            FP_M1_POOL=true             FP_M2_LOD=true
FP_JOB_LANE=true             FP_CPPGEN=true              FP_FIXED_FRAME=true
FP_SKIN_TIER=false           FP_DESCENT_FACET_RESYNC=true
```

Relevant engine facts (custom 4.4.1 build source, byte-served):
- `TIME_PHYSICS_PROCESS` = 1 Hz max-of-per-step-wall-time
  (`docker/engine/cache/godot/main/main.cpp:4517`, `:4588`).
- Physics step bracket contents: `PhysicsServer3D::sync/flush_queries` →
  `main_loop->physics_process` (ALL `_physics_process` callbacks) →
  `NavigationServer3D::process` → `MessageQueue::flush` →
  `PhysicsServer3D::step` → `MessageQueue::flush` → `iteration_end`
  (`main.cpp:4462-4516`).
- Catch-up cap: `max_physics_steps_per_frame=2` (`godot/project.godot:46`);
  at walking fps (~20-30 on a 60 Hz physics clock) most frames run 2 steps.
- `Engine._process_frames` increments **after** the physics loop
  (`main.cpp:4570` region), so both catch-up steps of one frame read the same
  `Engine.get_process_frames()` — the discriminator §4 uses.

---

## 2. The GroundCollider is exonerated (cited)

The teammate hypothesis — "the collider rebuilds/re-centres every frame while
moving" — is false on three independent grounds:

1. **Hard gate.** `GroundCollider.update()` early-returns (retaining shapes,
   doing zero PhysicsServer ops) unless a loose **awake** `VoxelBody` is within
   `_GATE_RADIUS = R + REBUILD_DIST = 22` columns of the player:
   `godot/src/physics/ground_collider.gd:195-201` → `_gate_off()` (`:348-350`,
   `_slice_ops = 0`). The gate query `has_active_bodies_near`
   (`godot/src/world/world_manager.gd:1686-1701`) iterates only frame-host
   children that are `VoxelBody` and skips empty/dormant ones. Walking through
   the forest without breaking anything ⇒ **no debris ⇒ the collider does
   nothing at all**, every tick. (The player never touches it anyway — movement
   is analytic; the collider exists solely for debris,
   `ground_collider.gd:3-8`.)
2. **No per-frame rebuild even when active.** A rebuild is triggered only on
   drift ≥ `REBUILD_DIST = 8` columns from the live centre
   (`ground_collider.gd:37`, `:229-232`), edits are debounced 15/60 frames
   (`:90-91`), and the sim channel 180 frames (`:103`). The rebuild itself is
   amortized: heights pass ≤ 32 columns/update (`COLS_PER_FRAME`, `:54`),
   shapes/trim pass ≤ 24 PhysicsServer ops/update (`OPS_PER_FRAME`, `:72`),
   double-buffered with an O(1) layer-toggle swap (`:19-30`, `:514-520`). Worst
   per-tick slice is low-single-digit ms **by construction** (that was the
   strip-mine fix).
3. **VoxelBody ticks.** Dormant bodies disable their per-frame script entirely
   (`godot/src/physics/voxel_body.gd:340`, `set_physics_process(false)`); with
   no debris there are zero VoxelBody `_physics_process` callbacks.

So the rest→walk jump cannot come from collider churn or debris solve. Any fix
aimed there would move nothing.

## 3. What actually scales with motion inside the bracket

### 3.1 The analytic movement funnel (`_move`, per tick)

At **rest**, `wish == 0` ⇒ `delta_move == 0` ⇒ the six `blocked()` wall probes
are never executed (`player.gd:1773-1784` both branches skip), `move_and_collide`
is skipped (`player.gd:1796-1797`), and the single landing `floor_under`
(`player.gd:1844`) is an O(1) `FP_FLOOR_MEMO` hit (cached-top jump,
`world_manager.gd:4326-4328`). Per-tick cost: sub-ms.

**Walking**, per tick: 6 × `blocked()` (each = FACETED ridge-plane test
`world_manager.gd:4549-4554` + an internal `floor_under` `:4558` + a 2-3-cell
`_headroom_clear` `:4570-4582`) + the landing `floor_under` + a swept ceiling
scan when rising + one `intersect_ray` (`player.gd:1870-1876`) + one
`move_and_collide` (wood-mask only). Two forest-specific aggravators:

- **Forest columns are memo-excluded.** `FP_FLOOR_MEMO` caches a column only
  when its topmost floor is a plain full cube with *plain air above*
  (`_span_indep_full/_span_indep_empty`, `world_manager.gd:4512-4515`); any
  tree wood/leaf cell above the walking floor flips `memo_safe` false
  (`:4386-4387`) and the populate-condition (`populate`, `:4360`) never fires
  during a surface walk anyway. So under canopy every `floor_under` re-scans
  its cells through `cell_value_at` → `TerrainConfig.generated_cell`
  (main-thread GDScript; `FP_ANALYTIC_COL_MEMO=true` reduces the per-column
  profile to once, `terrain_config.gd:1300-1310`, but the per-cell resolve and
  tree-overlay composition still run per query).
- **Every `floor_under` return passes `_ssw_weld`**
  (`FP_SEAM_SLOPE_WELD=true`, `world_manager.gd:4399-4418`): 4 seam-plane
  distances incl. `sqrt` per call — small but ×~7 calls ×2 ticks.

Estimated 1-3 ms/tick on wasm — a real motion term, but not 24 ms by itself.

### 3.2 The streaming orchestration tail (`update_streaming`, per tick)

`player.gd:822` calls `world.update_streaming(position)` inside the physics
tick. The head is safety/telemetry latching (`_streamer.update_center` — null on
the module path — and `_ground.update`, `world_manager.gd:1186-1189`, plus the
`_last_player_pos` latch `:1226-1227` and speed EMAs `:1195-1223`). Everything
after is **render-facing orchestration** re-executed per tick:

- alt-regime + approach anchor (`:1231-1236`);
- per-tick Callable construction + skin/cover/seam/band query plumbing
  (`:1244-1271`), far-ring player-column push incl. `lattice_to_world64`
  (`:1279-1283`), 4 × block-LOD `place` (`:1286-1295`);
- **the texture baker**: `_facet_tex.update(…, FACET_TEX_BAKE_BUDGET_MS=5.0, …)`
  (`:1321`) — a 5 ms budget **per call = per tick** (worker-mode
  `FP_TEX_BAKE_WORKER=true` moves the heavy bake off-main, but dispatch,
  reap and texture-commit remain main-thread);
- **the DEM pacer**: `_relief_data.step(…)` (`:1364`) — ≤1 facet bake/call;
- the neighbour-pool manager (`:1371-1372`), flip-settle polling (`:1380-1390`).

Two structural defects follow directly from the per-tick call site:

- **D1 — tick duplication on slow frames.** With 2 catch-up steps, the whole
  tail runs twice per render frame — its cost doubles on exactly the frames
  that are already over budget (mild positive feedback, bounded by the cap 2).
- **D2 — governor corruption.** The BG-prebake and G2 pacers admit work only
  when the *last frame had headroom*, measured as the wall delta between
  successive `update_streaming` calls (`_bg_frame_ms`,
  `world_manager.gd:1316-1320`; `_g2_frame_ms`, `:1354-1358`). On a 2-step
  catch-up frame the second step measures ~0.1 ms ⇒ *maximum headroom* ⇒ the
  governed bakers are invited to spend budget **during the overloaded frame**.
  The budget itself is also per-call: 2 ticks ⇒ up to 2 × 5 ms of tex-baker
  main-thread time per render frame while moving.

### 3.3 In-bracket engine work we do not own

Each physics step flushes the MessageQueue twice (`main.cpp:4503`, `:4513`).
`call_deferred` work queued by the tex-bake worker / JobLane completions since
the last flush executes there — attributed to phys_ms. This is the leading
candidate for the *residual* if P0's segment timers don't sum to the worst tick.

### 3.4 Why rest reads 5.6 and walk 24.6 (the model)

Rest worst-tick ≈ head + memoized `_move` + demand-idle tail ≈ 5-6 ms — matches
the #129 capture (phys_ms p50 5.6, p90 7.3). Walking worst-tick ≈ head +
motion `_move` (1-3 ms) + a tail call that hits demand (bake dispatch/commit,
DEM facet, pool op, or a deferred-commit flush) — a single such tick reaching
~20-45 ms at least once a second is exactly what a 1 Hz-max monitor reports as
24.6/44.5. The per-second recurrence follows from motion generating continuous
demand (SSE/band promotions, DEM want-list, far feeds) plus D2 inviting it in.

---

## 4. The fix — `FP_STREAM_TICK_ONCE` (byte-off) + P0 measurement

### 4.0 P0 — flip the existing instrument (zero code, one redeploy)

Export-flip `FP_FALL_TIMING := true` (`godot/src/cosmos/cube_sphere.gd:3851`).
This ships per-window **max µs** for `t_move_us` / `t_stream_us` / `t_floor_us`
/ `t_aim_us` / `t_pushbodies_us` (+ nav/att) through `fall_timing()`
(`player.gd:798-823`, `:896-901`, `:1841-1845` → `remote_bridge.gd:894-898`).
Read against phys_ms: `t_stream_us` names the tail, `t_move_us` the funnel, and
`phys_ms − max(t_*)` bounds the residual (server step + MessageQueue flush +
anything unowned). One walk session settles §3.4's attribution *before or
alongside* P1 — P1 does not depend on the answer, but P2 does.

### 4.1 P1 — the flag

`cube_sphere.gd`: `const FP_STREAM_TICK_ONCE := false` (export-flip A/B, the
`FP_CTRL_ADAPTIVE` sed-at-export pattern).

`world_manager.gd`: add `var _stream_tail_frame := -1`. In `update_streaming`,
immediately after the `_ground.update` + `_last_player_pos` latch block
(i.e. after `world_manager.gd:1227` — keeping the speed EMAs `:1195-1223`
per-tick is optional; they are wall-clock-based and cheap, keep them in the head
to minimize the diff):

```gdscript
# FP_STREAM_TICK_ONCE: the orchestration tail below is render-facing — running it on the
# SECOND catch-up physics step of one render frame does the identical work twice (same
# player_pos regime, same demand) and corrupts the _bg/_g2 headroom governors with a ~0 ms
# inter-call delta. Both catch-up steps share one Engine.get_process_frames() value
# (_process_frames increments after the physics loop), so this gate runs the tail exactly
# once per RENDER frame. The safety head above (streamer, GroundCollider, pos latch) stays
# per-tick. Off ⇒ no early return ⇒ byte-identical.
if CubeSphere.FP_STREAM_TICK_ONCE:
    var pf := Engine.get_process_frames()
    if pf == _stream_tail_frame:
        return
    _stream_tail_frame = pf
```

Everything from `_update_alt_regime` (`:1231`) down (anchor, plumbing, tex
baker, DEM, pool, `_far`, flip-settle) then runs once per render frame.

### 4.2 Safety analysis (the non-negotiables)

- **Fall-through: zero risk.** The tail writes no collision state. The floor /
  blocked / ceiling funnels (`world_manager.gd:4282+`, `:4534+`) and the
  GroundCollider (`_ground.update`, kept per-tick in the head) are untouched;
  the collider's own contract (debris-gated, drift-debounced, analytic settling
  confirmation) is unchanged. The player's movement reads world queries, never
  tail state.
- **Byte-off:** flag false ⇒ the guard block is skipped ⇒ every call proceeds
  exactly as shipped.
- **gl_compat / web:** no rendering change; fewer main-thread GL uploads per
  slow frame (bake commits once), never more.
- **Never-OOM:** one int of new state.
- **Semantic deltas with flag on (all benign):** (a) the flip-settle poll
  (`:1380-1390`) advances once per render frame instead of per tick — it is a
  poll of an async ramp, latency change ≤ one frame; (b) `_load_defer_tick`
  likewise; (c) governors now measure true render-frame deltas — that is the
  *point* (D2 fixed); (d) headless verify scripts that call `update_streaming`
  in a loop without advancing frames must either leave the flag off (default)
  or tick the SceneTree — noted in the gate.

### 4.3 Why not the alternatives

- **Rebuild-on-cell-cross / collider pooling:** aimed at an exonerated
  subsystem (§2) — no win available.
- **`max_physics_steps_per_frame` 2 → 1:** dilates game time whenever fps < 60
  (physics falls behind wall clock) — a gameplay change, not byte-off in
  spirit; rejected.
- **Move `update_streaming` to `_process`:** larger, riskier resequencing (the
  collider + streamer *want* the physics-tick pos), and loses the per-tick
  safety head. The tick-once gate gets the same win with a 6-line diff.
- **`FP_STREAM_IDLE_DIET`** (designed, absent from the served build): fixes the
  *rest* floor (demand-idle tail still costs orchestration); it composes with —
  and does not replace — TICK_ONCE, which fixes the *motion/catch-up* term.
  Ship TICK_ONCE first: motion is the deliverable.

### 4.4 Expected effect (quantified, with the honest bound)

On every 2-step frame the tail executes once instead of twice. Using the only
tail measurement on record (~8.4 ms/frame at ~1.4 ticks/frame ⇒ ~6 ms/call at
rest demand, `docs/COSMOS-THREAD-OFFLOAD-DESIGN.md` row 2) plus the 5 ms
per-call bake budget in motion, the tail is plausibly 8-12 ms/tick under walk
demand ⇒ the worst *frame's* physics portion drops ~8-12 ms, and the worst
*tick* loses the D2-invited bake spend ⇒ **phys_ms walking median 24.6 →
~14-17; worst_ms median 71 → low 60s**, plus second-order gains (shorter frames
⇒ fewer 2-step frames ⇒ fewer tail duplications — the feedback unwinds).
**Honest bound:** if P0 shows the 24.6 ms tick is one *un-sliced unit* (a
single bake commit, pool op, or deferred-flush batch), TICK_ONCE halves its
per-frame exposure but not its size; the unit then gets its own P2 fix (below)
with the P0 data naming it. And if P0 shows `t_move_us` dominating (§3.1's
estimate wrong), the lever is the funnel, not the tail — P2b.

### 4.5 P2 — data-gated follow-ups (pick ONE after P0's verdict)

- **P2a (`t_stream` residual / deferred-flush verdict):** replace worker
  `call_deferred` commits with an explicit drain in `WorldManager._process`
  (the JobLane `pump()` pattern, `world_manager.gd:854-855`) so commit cost is
  attributed and paced outside the physics bracket.
- **P2b (`t_move` verdict):** a per-tick transient column cache for the 6
  `blocked()` probes (keyed (xi, zi, feet-cell, fx/fz-quantized), cleared each
  tick — bounded ≤ 9 entries, never-OOM) — only worth designing if P0 proves
  the funnel ≥ ~5 ms/tick; footprint-dependence (`_occ_span`) makes this
  subtle, so it is NOT part of P1. **P0's verdict picked P2b — designed in §6
  (the sketch above is superseded there: the quantized-key `blocked()` cache is
  rejected as unsound; the shipped-shape design is a generated-value cell
  cache with the edit overlay always live).**

---

## 5. Gates

- **G-MTP-OFF (byte-off):** flag false ⇒ drive `update_streaming` twice in one
  headless "frame"; assert the tail ran twice (e.g. `_facet_tex` update-call
  counter / `_bg_last_frame_usec` advanced twice) — the shipped behavior.
- **G-MTP-ONCE:** flag true ⇒ same double call within one
  `Engine.get_process_frames()` value: tail counters advance ONCE; the head's
  `_ground.update` observed BOTH times (spy: `last_slice_ops()` reset, or a
  call-count shim on a GroundCollider test double). Then advance the SceneTree
  one frame, call again ⇒ tail advances.
- **G-MTP-FLOOR (fall-through safety):** scripted headless walk across forest
  columns (tree canopy overhead, the memo-excluded case): assert
  `floor_under`/`blocked` return byte-identical values flag-on vs flag-off at
  every step (they read no tail state — this is the invariant, cheap to pin),
  and the existing `verify_feature.gd` break/place/collapse loop passes with
  the flag on (collider coverage after an edit+move: break a block, pump
  `update()` until `!is_building() && !is_pending()`, assert a probe body rests
  on the live set — the established pattern).
- **G-MTP-GOV:** flag true ⇒ `_bg_frame_ms` never sampled twice per process
  frame (assert `_bg_last_frame_usec` monotone one-per-frame under a simulated
  2-tick drive).
- **Live A/B (one deploy, same forest spot, `?frames=0`):** P0 flags on in both
  arms; 60 s walk + 30 s run, TICK_ONCE off vs on. Accept: walking phys_ms
  median ≤ 16 (from 24.6), `t_stream_us` window-max halved on 2-step frames,
  worst_ms median down ≥ 8 ms, fps p50 up, **zero `FP_FALLTHRU_PROBE` events**,
  see-through/NEARCULL telemetry unchanged.

## 6. P2b — `FP_MOVE_PROBE_CACHE`: the `t_move` residual (design)

### 6.0 Verdict up front (honest version)

With `FP_STREAM_TICK_ONCE` live, the FP_FALL_TIMING decomposition names the new
walking #1: **`t_move_us` median 8.8 ms / max 20.5** (rest ≈ 0), vs `t_floor_us`
1.2 and `t_stream_us` 4.2. The motion-only cost inside `_move` is the six
`blocked()` wall probes — each a full un-memoized worldgen resolve chain per
cell — and their per-tick query set is **60-75 % redundant** (§6.1). The fix is
NOT the §4.5 sketch (a quantized-key `blocked()` boolean cache — provably
unsound on slopes/seams, §6.2). It is a **generated-value cell cache** under
`cell_value_at` with the edit overlay consulted live on every query, so the
edit-invalidation trap (clip-through) is impossible *by construction* (§6.3).
Honest bound: if the P0 sub-timer (§6.4) shows the probe funnel < ~3 ms of the
8.8, the cost is `move_and_collide`/engine and this cache cannot reach the bar
— ship nothing and redirect (§6.4 decision rule).

### 6.1 Where `t_move`'s 8.8 ms goes (root cause, cited)

`t_move_us` brackets exactly the `_move(delta)` call (`player.gd:814-816`);
`update_streaming` at `player.gd:822` is *outside* it, and the landing floor
query is split out inside as `t_floor_us` (`player.gd:1841-1845`). At rest
`wish == 0` ⇒ `delta_move == 0` ⇒ both probe branches skip
(`player.gd:1773-1784`) and `move_and_collide` is skipped
(`player.gd:1796-1797`) — matching the observed `t_move ≈ 0` at rest. Walking,
per tick:

- **Six `blocked()` probes** — x-axis at `player.gd:1775-1777`, z-axis at
  `player.gd:1781-1783` (three per axis: lead + both ± `PLAYER_RADIUS` corners).
- **Each `blocked()`** (`world_manager.gd:4551-4580`): the FACETED ridge-plane
  loop (≤4 × `FacetAtlas.own_dist`, `:4566-4571`), an internal `floor_under`
  (`:4575`) whose near-surface probe loop does **2 `cell_value_at` per
  iteration** (`world_manager.gd:4348-4352`, typically 1-2 iterations on a
  walkable column), and a `_headroom_clear` scan of 2-3 body cells
  (`:4587-4599`, one `cell_value_at` each).
- **`cell_value_at` is un-memoized** (`world_manager.gd:1475-1501`): after the
  overlay dict get (`:1476-1478`) every generated cell runs
  `TerrainConfig.generated_cell` (`terrain_config.gd:1300`) →
  `resolve_cell` (`:1329`) — the full per-cell pipeline (slope-run, cap, snow
  stack, sea, and for every above-surface forest cell the
  `TreeGen.block_at` canopy composition) — plus
  `FacetAtlas.junction_modify` (`world_manager.gd:1485-1486`).
  `FP_ANALYTIC_COL_MEMO` (`terrain_config.gd:1309-1313`) memoizes only the
  **column profile**; the per-cell resolve + tree overlay run per query.
- **The only cell-path cache, `FP_FLOOR_MEMO`, is doubly dead here.** It
  memoizes the column-top for `floor_under` only (`world_manager.gd:291-296`,
  read at `:4343-4345`) — `blocked()`'s headroom cells and the probe-loop pairs
  never see it. And while *walking under canopy* it never even populates:
  `populate` fires only on the fall-path ceiling jump (`:4377`), and a tree
  wood/leaf cell above the floor flips `memo_safe` false
  (`:4404`, `_span_indep_full/_span_indep_empty` `:4529-4531`) — the exact
  forest-column exclusion §3.1 documented. So under canopy every probe re-pays
  the full resolve. **This is why `t_move` is a forest walking cost.**

**The redundancy (what a cache can recover):** `PLAYER_RADIUS = 0.4`
(`player.gd:58`), so the two ± corner probes of an axis floor to the **same
integer column** as the lead probe except within 0.4 of a cell boundary —
typically 1-2 *unique* columns per axis, yet all three `blocked()` calls
re-resolve them from scratch (the `or` chain at `:1775-1777` only
short-circuits when blocked — in open walking all three run). Within one
`blocked()`, `floor_under`'s (y, y+1) pair and `_headroom_clear`'s body cells
overlap the same cells again. Net: **~36-48 `cell_value_at` calls/tick
collapsing to ~8-16 unique cells** — a 60-75 % intra-tick redundancy, ×2 on
catch-up frames (the probes are per-tick by design; only the §4 tail was
deduped). At wasm speeds (~0.1-0.2 ms per cold forest-cell resolve chain) that
is the observed 4-7 ms of recoverable work.

### 6.2 Why NOT the §4.5 sketch (cache `blocked()` itself)

§4.5 sketched caching the `blocked()` *boolean* keyed
`(xi, zi, feet-cell, fx/fz-quantized)`. Unsound: `blocked()` depends
**continuously** on its inputs — the ridge-plane `own_dist(fid, slot, x,
feet_y − s, z)` test (`world_manager.gd:4566-4571`) and the footprint
`(fx, fz)` through `_occ_span` (`:1603-1619`, real sub-cell spans on
slope/ramp/snow cells since SHARP-SLOPE/SNOW) — so two poses in the same
quantization bucket can legitimately differ. Any quantization coarse enough to
hit is coarse enough to lie, and a false "not blocked" is a clip-through. The
correct altitude is **one level down**: cache the *integer-cell pure value*
(`cell_value_at`'s generated branch — exact key, no quantization) and recompute
every footprint-/pose-dependent composition on top of it. Cached and uncached
paths are then identical by construction, not by tolerance.

### 6.3 The design — `FP_MOVE_PROBE_CACHE` (generated-value cache, overlay always live)

**The safety-decisive choice.** Two candidates were weighed:

- **(A) cache the full `cell_value_at` result** (overlay-composed): must
  invalidate on every overlay write — `_write_cell` (`:1944`),
  `sim_revert_cell` (`:2017`), collapse carves, sim snow writes — and a single
  missed site = the player clips through a just-placed block. Collision-
  safety-critical surface, for the marginal saving of one dict get.
- **(B) cache only the GENERATED value** — the branch *after* the overlay
  check misses. The overlay get (`world_manager.gd:1476-1478`) stays live on
  **every** query. Both edit kinds live in `_edits` — dug-to-air is stored as
  `0` and returns via `e >= 0` (`:1477`), placed blocks likewise — so **an
  edited cell can never be served from the cache, by construction**: the cache
  is consulted only on overlay miss, and worldgen output does not change when
  the overlay changes. Zero edit-invalidation surface. **Chosen: (B)** — the
  same shape `FP_FLOOR_MEMO`'s write-invalidation exists to protect, obtained
  for free.

**Mechanics** (all inside `WorldManager`, pure GDScript, no rebuild):

- **Store:** `_gen_cache: Dictionary` (`Vector3i cell → int packed value`) +
  `_gen_cache_tick: int`. Read/write wraps the generated tail of
  `cell_value_at` (`:1479-1501`): on entry to the generated branch, if
  `Engine.get_physics_frames() != _gen_cache_tick` ⇒ `clear()` + restamp (the
  **per-tick transient epoch** — self-clearing, no call-site wiring); then
  `get(cell, -1)` (packed values are ≥ 0, so −1 is a safe sentinel); on miss,
  compute the shipped branch verbatim and insert. Both generated sub-branches
  (no-chart `:1479-1487` and chart `:1491-1501`) cache their *final composed
  return* (after `junction_modify` / modifier rotation — those are pure
  functions of the cell within the epoch too).
- **Main-thread only:** gate reads *and* writes on the main thread (mirror
  `TerrainConfig._on_main_thread()`, `terrain_config.gd:1926`) —
  `cell_value_at` is also called by the fallback mesher
  (`chunk_mesher.gd:77-278`) and `SnowfallSystem` (`snowfall_system.gd:386,
  412, 425`); off-main queries bypass the cache entirely (no locks, no races).
- **Epoch-invalidating choke points** — cleared wholesale at exactly the two
  remap sites `FP_FLOOR_MEMO` already patrols: `_rebuild_window_indices`
  (`world_manager.gd:3778`, clear at `:3781-3783` — fires on crossing /
  home-face flip, which is also the only event that changes
  `active_facet`/datum mid-session) and `_shift_window_bookkeeping`
  (`:3865`, clear at `:3874-3876` — origin shift re-keys columns). A wholesale
  `.clear()` beside each existing `_floor_top` clear (no re-keying — a clear
  just recomputes). This inherits `FP_FLOOR_MEMO`'s *proven* invalidation
  discipline with a strictly weaker obligation (no write-site invalidation
  needed at all, per (B)).
- **Bounds (never-OOM):** the per-tick clear bounds the population to the
  per-tick query footprint (~10-40 cells walking; ~100s only during a
  collapse flood-fill tick). Belt-and-braces cap
  `MOVE_PROBE_CACHE_CAP := 512`: at cap, stop inserting for the rest of the
  epoch (hits keep working; misses just compute — degrades to the shipped
  path, never grows). Compare `FLOOR_MEMO_CAP` (`cube_sphere.gd:3913`).
- **Flag:** `const FP_MOVE_PROBE_CACHE := false` beside the FP_FLOOR_MEMO
  block (`cube_sphere.gd:3912`), flipped at deploy like every FP flag. Off ⇒
  one const test in `cell_value_at`'s generated branch, dict never touched —
  **byte-identical** (the overlay branch is not even touched by the diff).

**Identity proof (the clip-through invariant).** Within one epoch (one physics
tick, no choke event): the generated value is a pure function of the cell —
its only implicit parameters (`active_facet`, datum shift, chart anchor,
window indices) change *only* at the choke points, each of which clears. So a
hit returns a value computed by the same pure function in the same epoch ⇒
bit-equal to recomputation. A mid-tick overlay write (place/break/collapse/sim
— all route through `_write_cell`/`sim_revert_cell`) changes only the overlay
branch, which is evaluated live before the cache on every query ⇒ the very
next probe sees it, cached or not. Across epochs the cache is empty. There is
no third path. ∎ (Contrast: sub-tick *time*-dependence, e.g. evolving snow,
reaches cells only through sim writes to the overlay — `resolve_cell`'s snow
is the static baseline — so it is covered by the same argument; and even a
hypothetical time-dependent generator term would be frozen for at most one
physics tick.)

**What it deliberately does NOT do:** persist across ticks. A persistent
generated-value memo would also be sound under the same choke clears (it is
`FP_ANALYTIC_COL_MEMO`'s safety class) and would capture the ~14-tick
cross-tick reuse at walking speed — but the transient epoch is *provable in
one paragraph* and already removes the dominant intra-tick redundancy. If the
P2 hit-rate readback (§6.5) shows cross-tick misses still dominate, promoting
`_gen_cache_tick` to a choke-cleared persistent stamp is a 3-line follow-up
with its own gate — staged, not bundled.

### 6.4 P0 first — decompose `t_move` (the ship/no-ship gate)

Before any cache lands, extend the FP_FALL_TIMING instrument with one key:
**`t_probe_us`** — bracket the two probe blocks (`player.gd:1773-1784`) the
same way `t_floor_us` brackets the landing query (`:1841-1845`), plus two
counters surfaced through `fall_timing()` (`player.gd:2816`):
`n_probe_cva` / `n_probe_hit` (incremented in `cell_value_at`'s generated
branch under the flag — cost: one add). One redeploy, walk the forest spot:

- **`t_probe_us` median ≥ ~5 ms** ⇒ the funnel is the block-resolve — ship P1,
  expected recovery ≈ redundancy × t_probe (60-75 % ⇒ ~3-5 ms off `t_move`).
- **`t_probe_us` median < ~3 ms** ⇒ the 8.8 ms lives in
  `move_and_collide`/engine depenetration (`player.gd:1796-1797`,
  `_move_horizontal`) or the coast/attitude tail — **the cache cannot help;
  do not ship it.** Redirect: the loose-body gate already suppresses idle
  bodies; the next lever would be skipping `move_and_collide` when no loose
  body is within reach (a separate design with its own push-trap analysis —
  see the `:1794-1800` rubber-band comment before touching it).

### 6.5 Gates

- **G-MPC-OFF (byte-off):** flag false ⇒ drive a forest walk span headless;
  assert `_gen_cache` empty and every `blocked()`/`floor_under()`/
  `ceiling_scan()` return equals the pre-diff pin (trivial — the diff is
  flag-gated).
- **G-MPC-ID (the clip-through invariant, the gate that matters):** headless,
  over a forest column span *including* slope-carve, seam-band, and snow-fill
  columns: for a lattice of probe poses (sub-cell x/z offsets included),
  assert `blocked()` / `floor_under()` / `ceiling_scan()` **byte-identical
  flag-on vs flag-off**. Then, *within one stamp epoch* (no physics-frame
  advance — the SceneTree-script regime where `get_physics_frames()` is
  frozen, so the cache is maximally warm): warm the cache with a `blocked()`
  at pose P; `_write_cell` a solid block into that exact probe cell; re-query
  `blocked()` at P ⇒ **true**, and `floor_under` reflects the new top;
  `sim_revert_cell` it ⇒ both revert. Repeat with a dug-to-air edit over a
  solid column (probe must open). This pins the overlay-is-live-through-cache
  property that makes clip-through impossible.
- **G-MPC-EPOCH:** simulate a stamp change ⇒ assert wholesale clear; call
  `_rebuild_window_indices` / `_shift_window_bookkeeping` ⇒ assert clear
  (piggyback the existing `_floor_top` clear assertions).
- **G-MPC-CAP (never-OOM):** force > `MOVE_PROBE_CACHE_CAP` distinct cells in
  one epoch (one collapse-scale loop) ⇒ `_gen_cache.size() ≤ CAP`, queries
  beyond cap still byte-identical.
- **Existing suites:** `verify_feature.gd` break/place/collapse loop +
  `verify_floor_bounded.gd`/`verify_floor_weld.gd` flag-on (they exercise the
  exact composed queries).
- **Live A/B (one deploy, same forest spot, `?frames=0` + telem):** verify the
  **served pck's** flag block first (the FACETED flip trap — dump constants
  from the deploy worktree's pck, not main's). 60 s walk + 30 s run, cache off
  vs on. Accept: `t_probe_us` down ≥ 50 %, `t_move_us` median 8.8 → ≤ ~5,
  `n_probe_hit/n_probe_cva` ≥ 0.5, phys_ms median down, fps p50 up, **zero
  `FP_FALLTHRU_PROBE` events**, and a manual break/place spam pass at a wall
  with no clip-through.

### 6.6 Cost/risk

Pure main-thread GDScript CPU change: no render surface (gl_compat-trivially
safe), no engine rebuild, no threading. Never-OOM by double bound (per-tick
clear + cap). Flag off ⇒ one const test per generated-branch query. Worst
case with the flag on is perf-neutral (a dict get/insert around an already
expensive resolve); the failure mode a wrong cache *could* have had —
clip-through — is excluded structurally by (B), not by invalidation
book-keeping.

## 7. Lessons (for the memory index)

- **Know your monitor's aggregation before decomposing.**
  `TIME_PHYSICS_PROCESS` is a 1 Hz max-of-single-step, not a per-frame sum —
  treating it as an additive frame term over-attributed physics by ~2-4×.
- **Per-physics-tick call sites double their cost on exactly the slow frames**
  (catch-up steps), and any *inter-call* frame-time governor at such a site
  reads ~0 ms on the second step — inviting budgeted work into overloaded
  frames. Budgeted pacers must be per-render-frame.
- **The physics bracket contains MessageQueue flushes** — worker
  `call_deferred` commits bill to phys_ms.
