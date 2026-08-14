# COSMOS STREAM-IDLE-DIET — stop re-running the streaming tail 60×/s while nothing changes

**Task #119 P0b (`FP_STREAM_IDLE_DIET`). Status: DESIGN ONLY — nothing implemented.**
Author: Fable (stream-idle-diet architect). Companion to docs/COSMOS-FOREST-FPS-DESIGN.md
(§4.7 sketched this; endorsed by docs/COSMOS-THREAD-OFFLOAD-DESIGN.md §3 item 2 / §5 P0b,
which explicitly classifies this as *"idle-guard, NOT offload"* and defers the design here).

## 0. The problem in one paragraph

`Player._physics_process` calls `WorldManager.update_streaming(position)` every 60 Hz
physics tick (`player.gd:822`). The function (`world_manager.gd:1159-1364`) is the
orchestration spine of the whole streaming stack — skin tier, texture baker, DEM, block-LOD
placement, neighbour pool, far-ring query plumbing — and it runs **full-fat with no
stationary guard**. With the player standing still in the warm forest (facet 1754, the #119
telemetry capture: 1 unique pos, 1 unique camera, draws/prims constant), every input to the
tail is identical tick after tick, yet the tail runs ~120×/s (~2 ticks per 30 fps frame),
contributing the bulk of the ~8.4 ms/frame physics-tick tax in the ~19.4 ms static floor
(forest-fps §3 row 1). `FP_FAR_TREES_DELTA` (`facet_far_trees.gd:502`) already fixed the
same disease in the far-trees tier — rebuild on change, not on timer. This is the analogous
fix for the streaming tick.

---

## 1. AUDIT — every step of `update_streaming`, classified

Classes: **(a)** MUST run every tick (gameplay/physics authority) · **(b)** MOTION-GATED
(output is a deterministic function of player pos / camera / facet / edits / regime — all
constant when stationary) · **(c)** TIME-PACED / self-guarded (already carries its own
early-out or debounce; the diet removes only its residual per-tick prologue cost).

Costs are **structural estimates for the stationary warm-forest tick on web/WASM GDScript**
(no per-step live capture exists yet; the aggregate envelope is measured: `phys_ms`
fast-window p50 8.4 ms/frame, forest-fps §3, and `t_stream_us` is already instrumentable
via `FP_FALL_TIMING`, `player.gd:821-823` — the A/B in §7 captures the real split).

| # | Step | Where | Class | Est ms/tick (stationary) | Notes |
|---|---|---|---|---|---|
| 1 | `_streamer.update_center` (GDScript fallback streamer) | `world_manager.gd:1160-1161` | a | ~0 (null on module path) | module_in_web=yes in production ⇒ null check only |
| 2 | `_ground.update` — GroundCollider re-centre | `:1162-1163` → `ground_collider.gd:195` | **a — NEVER diet** | 0.01–0.05 | already self-gated (`has_active_bodies_near` gate-off, drift/edit debounce). Must poll every tick: a loose VoxelBody can roll toward a stationary player ([[voxiverse-floor-surface-root-cause]] — collision authority is per-tick) |
| 3 | FP_VEL_PREDICT speed EMA | `:1169-1177` | a | ~0.005 | this IS the motion sensor; feeds pool velocity-lead |
| 4 | FP_ENV_FALL_HOLD / LAND_RAMP_HOLD vy EMA | `:1184-1197` | a | ~0.005 | plunge detector; must not lag a fall |
| 5 | `_last_player_pos` latch (+ snowfall gate) | `:1200-1201` | a | ~0 | `_process` snow sim reads it |
| 6 | `_update_alt_regime` | `:1205` → `:657-670` | a | ~0.01 | one `lattice_to_world64`+sqrt; regime latch is a **wake edge source** (§3), keep it hot |
| 7 | `_update_approach_anchor` | `:1210` → `:683-692` | c (already debounced `ANCHOR_WRITE_DEBOUNCE_MS`, `:689`) | ~0.005 avg | input = altitude ⇒ constant when stationary; left in the must-run prologue (it is the injection boundary, §2) |
| 8 | `cover_query` Callable construction + `_skin.update(active, pos, _skin_candidate_fids(), cover)` | `:1218-1223`; `_skin_candidate_fids` `:3368-3378`; skin stationary path `facet_skin_tier.gd:198-201` | **b** | 0.1–0.3 | per tick: 1 Callable alloc + `has_method` string lookups + a fresh `PackedInt32Array` + a module `pool_neighbour_fids` Array + skin's `_lattice_world` + `_reap_due` check. The skin body already has its own TILE/2 stationary hysteresis — what remains is pure per-tick prologue + allocation churn (the dlmalloc-convoy class, [[voxiverse-walk-perf-root-cause]]) |
| 9 | `set_cover_query` / `set_seam_cover_query` / `set_band_query` on the far ring | `:1226-1245` | **b** | 0.05–0.15 | three Callable allocs + setter calls per tick pushing values that are **constant after setup** (they only ever change if the module appears/disappears — i.e. never at runtime) |
| 10 | `set_player_column` (FP_SMOOTH_RIM / FP_FARRING_UNCOVERED_TRUE) | `:1253-1257` | **b** | ~0.02 | `lattice_to_world64` of a constant pos |
| 11 | 4× block-LOD `place(_facet_ring.transform)` (ring, ladder, global, orbit) | `:1260-1269` → e.g. `facet_block_lod_ring.gd:281-282` | **b** | 0.02–0.1 | re-assigns the same Transform3D to 4 Node3Ds per tick (each set dirties the xform tree even when equal). Input = far-ring transform, which only changes on re-anchor/crossing — both require motion |
| 12 | `_facet_tex.update(…)` — texture baker drive | `:1276-1307` → `facet_tex_baker.gd:526-539`, `_update_main :542-608` | **b — the dominant item** | **1.5–3.5 (FP_SMOOTH_IDLE off) / 0.1–0.3 (on)** | per tick: `shell_emit_axis/offsurface/cam_dist` reads, wall-clock delta, then `_recompute_band_want_sse` (`:1148-1180`) + `_recompute_want_sse` (`:879`) — each a **full 3,456-facet dot+sqrt scan + sort** unless the `FP_SMOOTH_IDLE` axis-hold gate (`:1155-1162`, `cube_sphere.gd:1109` — **const false**) holds it. Warm-baked forest ⇒ the bake loops themselves exit immediately; the scans are the cost |
| 13 | `_load_defer_tick` + `set_stream_credit_ok` | `:1316-1318` | a | ~0.01 | boot-once latch (early-outs after settle, `:1393`); credit forward is one bool — far-trees' credit gate (`facet_far_trees.gd:481`) wants it fresh |
| 14 | `_relief_data.step` + `relief_baked` (DEM) | `:1319-1339` → `global_relief_data.gd:343-380` | c (post-FP_DEM_DEFER: fully-baked early-out `:346-347`, settle+budget guards `:361-367`) | ~0.01 warm | 20–60 ms/step only inside bake windows — those are exactly the "not settled" states the diet never arms in (§3) |
| 15 | `_manage_facet_pool` | `:1345-1346` → `:2956-3011`, z1hybrid `:3018+`, excl-latch probe `:3182` | **b** | 0.2–0.6 | per tick: 4× `seam_neighbour`+`own_dist`, a `pool_neighbour_fids` Array alloc, `_pool_off_surface`, `z1_live_targets` sort, and ≤1 `is_area_meshed` engine probe (`_nb_update_excl_latch`). Spawn/promote need distance change ⇒ motion; the only idle-reachable op is a timer-aged retire (heartbeat covers it, §2) |
| 16 | `m5c_glue_bodies` | `:1347-1348` | — | 0 | `M5C_CORNER` const false (`cube_sphere.gd:3754`) — dead |
| 17 | `_far.update_center` (non-faceted FarTerrain) | `:1349-1350` | b | ~0 (null in faceted prod) | |
| 18 | `_flip_settling` poll (ramp_done → re-mirror edits → release cover) | `:1354-1364` | a while true / dead while false | ~0.005 | crossing settle handshake — the diet never arms while it is true (§3) |

**Sum of the (b) rows: ≈ 2–4.5 ms/tick** with `FP_SMOOTH_IDLE` off (≈ 0.5–1.3 with it on),
× ~1.4–2 ticks/frame at the 30 fps floor ⇒ **≈ 3–8 ms/frame** — consistent with the
measured ~8.4 ms `phys_ms` envelope once `_move` + GroundCollider + engine physics
(~2–3 ms/frame, the (a) rows) are subtracted. The (a) rows total **≈ 0.05–0.15 ms/tick** —
that is the dieted tick's whole cost.

Two audit findings worth stating plainly:

1. **Half the tail already self-idles** (skin body, approach anchor, DEM, GroundCollider,
   baker bake-loops). What the 60 Hz spine still pays every tick is *orchestration*:
   Callable/array allocations, string `has_method` lookups, transform re-sets, and — the
   single biggest line — the baker's two unguarded 3,456-facet want-scans. The diet
   removes the whole spine, uniformly, instead of chasing each residual.
2. **Item 12 has an existing, narrower fix that never shipped**: `FP_SMOOTH_IDLE`
   (`cube_sphere.gd:1096-1109`, "LAW Q — fixpoint at rest") holds exactly those scans and
   is **const false**. The diet subsumes it for the stationary case but composes with it
   (§8): SMOOTH_IDLE also helps the *moving* camera, which the diet deliberately does not.

Steps that live OUTSIDE `update_streaming` and are untouched by this design:
`maybe_reanchor` (`player.gd:828`), `maybe_flip_home_face` (`:837`), the crossing scan,
DDA raycast/collapse (event-driven), the player's own `_move`/analytic floor sample, the
far-ring `_process` (far-trees step, smooth drive, controller tick), the JobLane pump.
All gameplay-authority or already governed elsewhere.

---

## 2. THE FIX — `FP_STREAM_IDLE_DIET`: heartbeat the tail, never skip it forever

### 2.1 Principle — downshift, don't stop

Forest-fps §4.7's endorsed shape: when the player is settled AND stationary, run the
motion-gated tail at a **5 Hz heartbeat** instead of 60 Hz. A heartbeat (vs a hard skip) is
the load-bearing safety choice:

- every (b) step is already **re-entrant and cadence-tolerant** (each has internal
  debounces/throttles built for variable call rates), so changing only the *cadence* — never
  the sequence, never to zero — keeps every liveness property: a timer-aged pool retire, a
  skin coverage reap, a straggler DEM want, a far-ring transform drift all still land, at
  worst `1/STREAM_IDLE_HZ` = 200 ms late, which is under the far ring's own 250 ms tier
  cadence (`FAR_TREES_STEP_MS`, `cube_sphere.gd:897`) and invisible;
- the no-op proof (§4) then only has to cover a **bounded 200 ms window**, not "forever";
- the failure direction is safe: if the predicate mis-fires, behaviour degrades to
  "streaming reacts within 200 ms", never "streaming wedged" ([[voxiverse-fast-load]]).

### 2.2 Injection site — ONE guarded early-return

`world_manager.gd`, immediately after `_update_approach_anchor(player_pos)` (`:1210`),
i.e. exactly at the (a)/(b) boundary the shipped statement order already has:

```gdscript
# FP_STREAM_IDLE_DIET (docs/COSMOS-STREAM-IDLE-DIET-DESIGN.md): when the player is settled
# AND stationary, the rest of this function (the motion-gated streaming tail) recomputes
# byte-identical results from unchanged inputs 60×/s. Downshift it to a STREAM_IDLE_HZ
# heartbeat; ANY wake edge (motion, camera turn, edit, crossing, regime flip, un-settle,
# observed tail work) restores full rate the SAME tick. Everything above this line — the
# collider, motion/fall sensors, regime latch, pos latch — stays 60 Hz unconditionally.
if CubeSphere.FP_STREAM_IDLE_DIET and _sid_tail_skip(player_pos):
    return
var _sid_t0 := Time.get_ticks_usec() if CubeSphere.FP_STREAM_IDLE_DIET else 0
```

and at the very end of the function (after the `_flip_settling` block, `:1364`):

```gdscript
if CubeSphere.FP_STREAM_IDLE_DIET:
    _sid_note_tail(Time.get_ticks_usec() - _sid_t0)
```

No shipped line moves; the tail body is byte-untouched. (Steps 13/18 — `_load_defer_tick`,
credit forward, `_flip_settling` — technically land below the cut, but §3 makes the diet
structurally unreachable whenever any of them has work to do, so their placement is safe:
`_load_defer_tick` is a post-settle no-op early-out (`:1393`), the credit forward only
matters under load, and `_flip_settling==true` blocks the diet outright.)

### 2.3 The idle predicate — `_sid_tail_skip(player_pos) -> bool`

Returns true (skip this tick's tail) iff ALL of:

**STATIONARY** (the far-trees-delta pattern, `facet_far_trees.gd:641-655`, tightened):
- `player_pos.distance_squared_to(_sid_pass_pos) < STREAM_IDLE_MOVE_EPS²` (0.25 blocks —
  forest-fps §4.7's number; 8× finer than `FT_DELTA_MIN_MOVE` 2.0, so the streaming tail
  always wakes before the far-trees tier does), and
- camera stable: the far ring's emit axis — the exact camera proxy the dietable consumers
  (baker want-scans) read — has not rotated:
  `dot(shell_emit_axis(), _sid_pass_axis) ≥ cos(STREAM_IDLE_CAM_DEG)` (2°), and
  `|shell_cam_dist() − _sid_pass_dist| < STREAM_IDLE_MOVE_EPS`
  (`facet_far_ring.gd:3067,:3074`; returns a stored ref/float — no alloc). `_facet_ring ==
  null` (fallback path) ⇒ camera term passes — no camera-driven consumer exists there.

**UNCHANGED WORLD** (each an int/bool compare against the last-full-pass latch):
- `TerrainConfig.active_facet() == _sid_pass_fid` (no crossing),
- `edit_count() == _sid_pass_edits` (`world_manager.gd:611` — breaks, places, AND snow
  writes all bump it; the same signal FP_FAR_TREES_DELTA plumbs, `facet_far_trees.gd:438`),
- `_alt_orbital == _sid_pass_orbital and not _alt_reentry_pending` (no regime flip).

**SETTLED** (streaming is NOT converging — the [[voxiverse-fast-load]] wedge guard):
- `not _flip_settling`,
- `_load_settled or not CubeSphere.FP_LOAD_DEFER` (never diet the fresh-load window),
- controller drained: `_load_ctrl == null or (not _load_ctrl.backlog_gated() and
  _load_ctrl.inflight() == 0)` (new one-line accessor beside `credit()`,
  `stream_load_controller.gd:189`; `backlog_gated` `:234-237` — reads existing fields,
  allocates nothing; do NOT call `stats()`, it builds a Dictionary),
- **work-sensed quiet** (§2.4): the last `STREAM_IDLE_ARM_TICKS` (30 ≈ 0.5 s) tail passes
  each completed in `< STREAM_IDLE_QUIET_US` (300 µs).

**HEARTBEAT**: even when idle, return false every `1000/STREAM_IDLE_HZ` ms
(`Time.get_ticks_msec() - _sid_last_tail_ms ≥ 200`), so the tail runs at 5 Hz.

Any failed condition ⇒ return false **this same tick** (the wake edge is ≤ one tick by
construction — the predicate runs before the tail every tick), reset the quiet streak, and
re-latch `_sid_pass_*` when the tail actually runs. Predicate cost: ~6 compares + one dot —
**≈ 2–5 µs/tick**, three orders of magnitude under what it saves.

### 2.4 Work-sensing — the "converging tiers" guard without per-subsystem plumbing

The one idle-reachable way inputs stay constant while *state* still converges: background
tiers finishing after the player stops (baker band/base stragglers, DEM wants, skin
coverage reaps, pool retire aging). Rather than adding a `quiescent()` accessor to five
subsystems, the diet **senses work**: `_sid_note_tail(us)` records each pass's wall time; a
pass ≥ `STREAM_IDLE_QUIET_US` (300 µs) means some step did real work (one band-bake slice
alone is ms-scale, `FACET_TEX_BAKE_BUDGET_MS`-bounded) ⇒ quiet streak resets ⇒ full 60 Hz
resumes until the tail measures quiet for 0.5 s again. Converging tiers therefore run
full-rate; only a **measured fixpoint** gets dieted. Mis-calibration fails safe: a host
whose no-op tail jitters above 300 µs simply never arms — shipped behaviour.

### 2.5 Flags + constants (`cube_sphere.gd`, new block beside the FAR_TREES/DELTA block `:929-931`)

```gdscript
const FP_STREAM_IDLE_DIET := false     # 60Hz streaming tail → 5Hz heartbeat when settled+stationary
const STREAM_IDLE_MOVE_EPS := 0.25     # blocks of player/cam-dist drift that wakes the full-rate tail
const STREAM_IDLE_CAM_DEG := 2.0       # degrees of emit-axis rotation that wakes it
const STREAM_IDLE_HZ := 5.0            # dieted tail cadence (200 ms worst-case staleness)
const STREAM_IDLE_ARM_TICKS := 30      # consecutive quiet tail passes (~0.5 s) required to arm
const STREAM_IDLE_QUIET_US := 300      # a tail pass at/over this "did work" → hold/return to 60 Hz
```

New state in `world_manager.gd` (all `_sid_*`, written only under the flag): pass latches
(pos, axis Array copy [3 floats], cam-dist, fid, edits, orbital), `_sid_last_tail_ms`,
`_sid_quiet_streak`, `_sid_tail_us` + `_sid_dieted_ticks`/`_sid_full_ticks` debug counters
(gate + telemetry read-back, the `_dbg_rebuild_count` pattern `facet_far_trees.gd:698`).

---

## 3. Wake-edge matrix (every re-arm is same-tick, checked in the predicate)

| Event | Signal in predicate | Latency to full-rate |
|---|---|---|
| player moves ≥ 0.25 blk | pos delta | same tick |
| camera turns ≥ 2° / altitude changes | emit-axis dot / cam-dist | same tick |
| break / place / chop / snow write | `edit_count()` | same tick |
| facet crossing | `active_facet()` + (during ramp) `_flip_settling` | same tick, held full-rate until ramp_done |
| view-distance ramp / approach-anchor release | altitude moved ⇒ pos/cam-dist term | same tick |
| regime flip (orbit↔surface) | `_alt_orbital` / `_alt_reentry_pending` | same tick |
| fresh load / teleport settle | `_load_settled` false; teleports also move pos | never armed |
| streaming backlog / in-flight loads | `backlog_gated() or inflight()>0` | same tick |
| background tier still converging | work-sense ≥ 300 µs | ≤ one heartbeat (200 ms) to detect, then full-rate |

Honest corner: **falling snow** bumps `edit_count` on every accumulation write, so in
active snowfall over the player's facet the diet effectively disarms — correct (the skin/
collider/edit consumers genuinely have new input) and, post-`FP_SNOW_PRECIP_GATE` (task
#118), warm/dry biomes like the #119 forest are unaffected.

---

## 4. Correctness — why the skipped ticks are no-ops

For each (b) step, output is a pure function of (player pos, camera axis+dist, active
facet, edit rev, regime, pool/streamed state) plus own internal state:

- **Steps 8–11, 17** (skin drive, query pushes, player column, block-LOD placement): the
  pushed values are recomputed from predicate-latched inputs only — unchanged inputs ⇒
  bit-identical values ⇒ re-pushing is identity. The Callables in step 9 are constant after
  `setup()` by construction (they wrap module methods resolved once).
- **Step 12** (baker): `_update_main` is deterministic in (emit_axis, offsurface, cam_dist,
  active_fid) + resident state; the want-scans produce the same want-set from the same
  camera; the bake loops act only on want∖resident. Resident state changes only via the
  baker's own passes (sensed, §2.4) or evictions it itself performs — no third party
  mutates it between ticks.
- **Steps 14–15** (DEM, pool): distance-driven decisions from a constant pos are constant;
  the two time-driven residuals (pool retire aging, DEM demand-serve) execute at the 5 Hz
  heartbeat, ≤ 200 ms late — both are already ≤1-op-per-second rate-limited paths
  (`POOL_SPAWN_INTERVAL_S`, `world_manager.gd:2990`), so a 200 ms phase shift is within
  their designed jitter.
- **No fall-through possible**: the analytic collision floor (`surface_y`/`floor_under`/
  `blocked` — the [[voxiverse-floor-surface-root-cause]] authority) is queried by
  `Player._move`, NOT produced by the tail; GroundCollider (step 2) and the frame-guard
  healing run every tick unconditionally. The diet touches zero physics inputs.
- **Never-OOM** ([[voxiverse-never-oom-web]]): the diet only *reduces* work; every ledger/
  cap (skin 8 MB, baker layers, pool cap, DEM bytes) is enforced inside the (b) steps
  themselves, which still run ≥ 5 Hz. New resident state: ~10 scalars + one 3-float Array.

**Byte-off:** every added statement is inside `if CubeSphere.FP_STREAM_IDLE_DIET` (const
false ⇒ the `and` short-circuits, `_sid_*` is never written, no timer calls execute) — the
shipped statement sequence runs verbatim every tick, gl_compat-untouched (no shader, no
render-path change). Standard flag-off export/behaviour parity in the gate (G-SID-6).

---

## 5. Perf estimate — honest

Dieted tick: (a) rows ≈ 0.05–0.15 ms + predicate ≈ 0.005 ms, vs ≈ 2–4.5 ms full-fat.

- **`phys_ms` p50 9.4 → ~5–6** (the remainder is `_move`, collider, engine physics — the
  forest-fps §4.7 / offload-doc §5 P0b projection, unchanged by this audit).
- **Stationary forest frame:** ~3–6 ms/frame off the clean-mode ~24 ms frame ⇒ with
  `FP_FAR_TREES_DELTA` already landed (p50 ~38–42), expect **p50 +2–5 fps (~41–46)**;
  against the shipped 30 fps PWM baseline the two P0s together account for the whole
  38–46 band. min_fps improves more than the median (physics-tick backlog is the §2.4
  forest-fps *amplifier*: fewer ms/tick ⇒ fewer compounding ticks on slow frames).
- **Ceiling honesty:** `update_streaming` is only ~5–6 of the ~19.4 ms floor
  (offload doc §3), and ~2–3 ms of it is must-run. This fix **cannot** buy 60 fps; the
  ~14 ms render-submit/GPU residual (forest-fps §3) stands and needs the §6.3 floor
  probes → vertex diet. If the live build ships `FP_SMOOTH_IDLE=on` (const is false in
  tree, but deploys bake flags — **dump the served pck's flags first**, the
  [[voxiverse-border-shade-weld]] lesson), item 12 is already partly held and the delta
  shrinks toward +1–3 fps; the A/B verdict must condition on that dump.

---

## 6. Gates (new `verify_stream_idle_diet.gd`, headless; drives `update_streaming` directly)

- **G-SID-1 arm**: flag on, scripted settled controller source, constant pos/axis → after
  `STREAM_IDLE_ARM_TICKS` quiet passes, `_sid_dieted_ticks` advances and tail passes run at
  ≈ `STREAM_IDLE_HZ` (count tails over N simulated ticks).
- **G-SID-2 no-op proof**: stationary player; snapshot observables after a full-rate pass
  (skin tile keyset + bytes, baker `slots_epoch`/`band_epoch`/want counts, pool fid set,
  4 block-LOD transforms, DEM `resident_bytes`) → run 60 dieted ticks → snapshots
  bit-equal; then force one heartbeat pass → still bit-equal (fixpoint).
- **G-SID-3 wake edges**: each row of §3's matrix (move 0.3 blk; rotate axis 3°; bump
  `edit_count` via `seed_edit_for_test`, `world_manager.gd:632`; flip `active_facet`; set
  `_flip_settling`; scripted backlog>0) → the NEXT `update_streaming` call runs the tail
  (full-tick counter increments; quiet streak reset).
- **G-SID-4 physics untouched**: with the diet armed, `_ground.update` tick counter ==
  tick count; the existing `verify_feature.gd` break/place/collapse loop green with the
  flag on; `floor_under`/`surface_y` results identical armed vs disarmed.
- **G-SID-5 converging never diets**: leave one band facet unbaked → tail passes measure
  ≥ QUIET_US → never arms until the bake completes; then arms.
- **G-SID-6 flag-off parity**: flag off ⇒ tail runs every tick (`_sid_full_ticks` == tick
  count, `_sid_dieted_ticks` == 0, no `_sid_*` writes), full existing suite green, standard
  flag-off export compare.

## 7. Live A/B (forest facet 1754, the #119 protocol — after FP_FAR_TREES_DELTA is live)

1. **Pre-step**: dump served-pck flags (esp. `FP_SMOOTH_IDLE`) — fixes the baseline claim.
2. Baseline = DELTA-on stationary capture; deploy DIET-on; ≥ 5 min stationary. **Pass:**
   fps p50 ≥ baseline +2 (stretch +5), `phys_ms` p50 ≤ ~6, hitches/s not worse. Telemetry
   adds `sid_dieted`/`sid_full` per window (read the debug counters) — expect duty
   cycle ≈ 1/12 while still.
3. **Then WALK** — the wedge test ([[voxiverse-fast-load]]): a 200-block loop with two
   facet crossings. Streaming must keep up exactly as baseline: no far-over-near flash, no
   pool-miss (`pool_miss_count`), no fall-through, skin/band fill latency unchanged
   (`sid_dieted` ≈ 0 while moving — the predicate must be observed disarmed).
4. Chop one tree while stationary → skin/collider/far-trees all react same-tick (edit wake).

## 8. Interaction with FP_FAR_TREES_DELTA (and FP_SMOOTH_IDLE) — composition verdict

Independent by construction: FAR_TREES_DELTA gates the far-trees tier inside
`FacetFarRing._process` (render frame, `facet_far_ring.gd:1334-1335`) — a path this design
never touches; the DIET gates the physics-tick tail. Their motion thresholds nest safely
(0.25 blk wakes streaming before 2.0 blk wakes trees; a tree rebuild needs no streaming-tail
service to land — its credit input is forwarded in the (a) prologue `:1316-1318`). Both
idle at rest ⇒ the controller sees a clean frame ⇒ credit stays high ⇒ no PWM re-entry —
they *reinforce*, not fight. `FP_SMOOTH_IDLE` remains worth flipping separately later (it
also holds the scans while *moving*); with the DIET on, its stationary benefit is subsumed —
measure it as a follow-up A/B, not bundled.

**Honest verdict:** this is the cheapest remaining win on the static floor — one guarded
early-return + a ~30-line predicate, byte-off, fails toward shipped behaviour — worth
roughly +2–5 fps p50 stationary and a larger min_fps/hitch improvement, and it is
explicitly NOT the path to 60 fps (the render residual is).

---

## 9. ADDENDUM (live A/B follow-up) — floor source vs SPIKE source at credit=0

A fresh stationary capture (facet 1754, FP_FAR_TREES_DELTA live) shows `stream_credit=0`
constantly with worst_ms spikes 55–181 ms, fps 10–27, draws steady 171. Attribution:

**The `update_streaming` tail CANNOT be the spike source.** Its stationary cost is a flat
~2–4.5 ms/tick (§1) — it raises the *median/floor*, never a single 100–181 ms frame. The
idle diet lowers the floor; it will NOT remove these spikes. Distinct fix, distinct owner.

**Prime spike suspect — the applied-cover ladder's re-emit churn (`FacetFarRing`).**
`_applied_probe_step` runs EVERY render frame (`facet_far_ring.gd:1375` → `:1720-1744`)
and **any change of `_applied_r` sets `_pending = true`** (`:1733-1734`), which the
surface-converge branch answers with a full-shell re-emit (`_begin_rebuild` → async build
+ main-thread `_swap_in_arrays` of the ~489 k-vert FULL_COVER mesh, or the synchronous
`_rebuild_full` fallback, `:1904-1909`). The ladder **shrinks to 0 instantly on ONE failed
coverage probe** (`:1728-1729`) and regrows one `APPLIED_PROBE_STEP=16` step per frame to
`APPLIED_PROBE_MAX=112` (`cube_sphere.gd:1757,:1760`) — so a single probe flicker fires
**1 + 7 consecutive re-emits**, a burst of heavy frames matching the observed bursty
55–181 ms shape. Critically, this path is **credit-immune** (the credit gates far-trees /
smooth-v2 / promotes — never the shell re-emit), so it sustains overload and pins credit
at 0 — exactly the observed constant. It is also **new since PR #50** (FP_APPLIED_PROBE_SLAB
brought the ladder to life: `sh_applied_r` 0→live); the original #119 capture predates it
and logged zero farring events. Same churn class, second suspect: the covered-cell cull
mask (`_cull_update`, `:2671`) — a mask hysteresis flip also sets `_pending`.

**Discriminators (already in telemetry, no new code):** (1) `sh_applied_r` per window
(`facet_far_ring.gd:3145`) — oscillation (112→0→regrow) at spike times is the smoking
gun; (2) `{"type":"farring", path, build_ms, swap_ms, verts}` events (`:3032-3038`,
published by `remote_bridge.gd:750`) — present at spike times ⇒ confirmed, absent ⇒ this
suspect is dead and the next candidate is the allocator convoy.

**Telemetry confound, bounded:** the ambient 2 s frame capture (~35 ms readback +
threaded encode) is SELF-SKIPPED whenever the last window's worst > 45 ms
(`CAPTURE_SKIP_WORST_MS`, `remote_bridge.gd:97`) — at worst 55–181 it is mostly off, so
it cannot explain the bulk of the spikes; residual captures are stamped `cap=1`
(`:148`) for exclusion. Commanded screenshots BYPASS the throttle (`:95`) — if the
session requested screenshots, exclude those windows too.

If confirmed, the fix is NOT this flag: it is a `FP_APPLIED_PROBE_CALM` follow-up in the
far ring (probe on a cadence not per-frame; hysteresis/decay instead of shrink-to-zero;
re-emit at most once per settle, not per ladder step) — separate design, same
byte-off/gate discipline.
