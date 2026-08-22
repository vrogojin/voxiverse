# COSMOS FALL STREAM-PACING — de-orbit descent jerkiness (task #144)

**Status: DESIGN (no code in this doc's branch scope). Two byte-off flags: `FP_STREAM_FALL_PACE` +
`FP_REENTRY_VIEW_RAMP`.**

The measured problem (relay stepped-descent profile, task #143): `t_stream_us` — the timer around
`WorldManager.update_streaming` — burns a steady **14-16 ms every frame for the whole de-orbit fall**
(alt 2500 → 0), spiking to **38 ms at the alt≈700 handoff** (with `phys_ms` 18 → 48.6 there) and an
**83 ms worst frame at alt≈70 surface entry**. `t_scaledbody_us ≈ 0` throughout (scaled-body theory
REFUTED). The descending position never lets the streaming orchestration settle.

---

## 1. Root cause in code

### 1.1 Where `t_stream_us` is measured

`godot/src/player/player.gd:920-922` (inside `_physics_process`):

```gdscript
if _ft_on: _ft_t = Time.get_ticks_usec()
world.update_streaming(position)
if _ft_on: _ft_max("t_stream_us", Time.get_ticks_usec() - _ft_t)
```

It times **exactly one function**: `WorldManager.update_streaming`
(`godot/src/world/world_manager.gd:1258-1476`). Nothing else contributes to the bucket.

### 1.2 What is (and is NOT) inside that function

`update_streaming` is split (by the shipped `FP_STREAM_TICK_ONCE` fix, #129) into:

- **SAFETY HEAD** (`world_manager.gd:1259-1300`, runs every physics tick): fallback
  `_streamer.update_center` (null on the module path), `_ground.update` (GroundCollider — has an
  active-body gate at `ground_collider.gd:199` → **zero work during a fall with no loose debris**),
  the velocity/fall-vy EMA blocks (`:1268-1296`), position latch. Cheap on the live module build.
- **ORCHESTRATION TAIL** (`world_manager.gd:1313-1476`, once per render frame under
  `FP_STREAM_TICK_ONCE`): regime latch, approach anchor, and **three heavy render-side drivers**:

| block | site | per-frame work during descent |
|---|---|---|
| **skin tier** | `_skin.call("update", …)` `world_manager.gd:1333-1335` → `facet_skin_tier.gd:187-251` | Re-ranks EVERY candidate tile across active+pool facets **each call** (`_skin_tiles_wanted` builds + `sort_custom`s the full list, `facet_skin_tier.gd:331-353`), advances per-candidate coverage-hysteresis probes (`is_area_meshed` C++ calls within `NEAR_COVER_R` 144), evicts/builds tiles. Cost ∝ candidates, re-paid every frame because the centre moves every frame. |
| **facet-tex baker** | `_facet_tex.update(…)` block `world_manager.gd:1388-1419` → `facet_tex_baker.gd:536+` | Budget `FACET_TEX_BAKE_BUDGET_MS = 5.0` (`cube_sphere.gd:2372`) is checked **before** each bake unit — a band/fine unit is several ms, so the real spend is ~5-10 ms whenever there is pending work. During a descent `cam_dist` shrinks monotonically every frame, so the V4 SSE promotion law **continuously re-tiers facets** → there is always pending work → the budget is fully burned every frame, the whole way down. |
| **G2 DEM** | `_relief_data.step(…)` block `world_manager.gd:1431-1451` | Governed pacer (bakes only with headroom), but its want-list scan + the `initial_view_meshed` FP_DEM_DEFER probe (`:1437`) run per frame; off-surface it sweeps the planet. |

**NOT in the bucket** (important for scoping): `FacetFarRing` steps in its **own `_process`**
(`facet_far_ring.gd:615`), godot_voxel's near mesh/stream work runs in **its own** node processing +
threads. The alt≈700 `phys_ms` spike is therefore not tail code — it is the near-field
**streaming demand** that the tail's `set_approach_anchor` write creates in one step (§1.3).

Why the cost doesn't drop while moving fast: none of these three drivers has a motion/fall signal.
The skin re-rank and the SSE re-tier are *re-triggered by* motion — the faster the position changes,
the more churn — the exact inverse of what a plunging camera needs (nothing mid-distance is
legible at 100+ blocks/s).

### 1.3 The alt≈700 spike — the approach-anchor re-grow knee, not ATMO_TOP

`ATMO_TOP` is 384 and the `FP_ALT_REGIME` release is at 384+32 = 416 (`cube_sphere.gd:2997`,
`world_manager.gd:741`) — neither is at 700. What IS at 700: **`ANCHOR_REL_LO = 700`**
(`cube_sphere.gd:2736-2739`). `_apply_approach_anchor` (`world_manager.gd:773-810`) recomputes the
near viewer's `view_distance` from altitude on every debounced write (`ANCHOR_WRITE_DEBOUNCE_MS =
100`):

```
view_f = full · clamp((900 − d) / (900 − lo), 0, 1)      # cube_sphere.gd:2774-2777
```

Descending fast, `d` drops by 10-50+ blocks between 100 ms writes, so `view_distance` **jumps by
`full·Δd/291 ≈ 13-40+ blocks per write** (`_module_world.set_approach_anchor`,
`world_manager.gd:802` → `module_world.gd:492-497`). Each jump orders godot_voxel to stream/mesh a
whole new ellipsoid annulus at once → the stream 15→38 ms + phys 18→48.6 ms band at ~700, and again
the compounding near-field burst at ~70 (offsurf 0%, full near residency + trees/snow resume). The
one-shot `FP_ALT_REGIME` re-entry redesignation at 416 (`_alt_reentry_pending`,
`world_manager.gd:743`) is a *single* crossing-class frame and is **deliberately left untouched**
(it is the fall-through RE-ENTRY FIX; see §5).

---

## 2. The fix — two flags, both additive, both byte-off

### 2.1 Flag A — `FP_STREAM_FALL_PACE`: round-robin the heavy tail during a fast descent

**Signal.** A **radial altitude-rate EMA** — not the existing `_fall_vy_ema`
(`world_manager.gd:1283-1291`), because that one (a) samples lattice-y, and (b) rejects any
per-update speed above `VEL_PREDICT_SPEED_CLAMP = 40` b/s as a relocation — an orbital plunge is
routinely far faster than 40 b/s, so `_fall_vy_ema` goes stale exactly when we need it. Instead
reuse the estimator *pattern* on `_radial_altitude_lattice(player_pos)`
(`world_manager.gd:715-722`), which is **continuous across facet flips/crossings** (it converts to
world radius), so it needs no relocation clamp beyond a generous teleport guard:

```gdscript
# world_manager.gd — new state next to _fall_vy_ema (~:257)
var _alt_rate_ema := 0.0
var _alt_rate_last_usec := -1
var _alt_rate_last_alt := 0.0

# world_manager.gd — new helper next to _update_alt_regime
func _stream_pace_update_rate(player_pos: Vector3) -> void:
    var alt := _radial_altitude_lattice(player_pos)
    var nowu := Time.get_ticks_usec()
    if _alt_rate_last_usec >= 0:
        var dt := float(nowu - _alt_rate_last_usec) / 1.0e6
        if dt > 0.0:
            var r := (alt - _alt_rate_last_alt) / dt
            if absf(r) < CubeSphere.STREAM_PACE_RATE_CLAMP:   # a set_alt/teleport, not motion
                _alt_rate_ema = lerpf(_alt_rate_ema, r, 0.3)
    _alt_rate_last_usec = nowu
    _alt_rate_last_alt = alt
```

**Mechanism.** In the tail, immediately after the `FP_STREAM_TICK_ONCE` dedup +
`_dbg_tail_runs` (`world_manager.gd:1313`) and **after** `_update_alt_regime` /
`_update_approach_anchor` (`:1317`, `:1322` — those MUST keep running every tail frame, §5),
compute a pacing **phase**:

```gdscript
var _pace_phase := -1                       # -1 = unpaced: everything runs (shipped behaviour)
if CubeSphere.FP_STREAM_FALL_PACE:
    _stream_pace_update_rate(player_pos)
    if _alt_rate_ema < -CubeSphere.STREAM_FALL_PACE_VY:
        _pace_counter = (_pace_counter + 1) % 3
        _pace_phase = _pace_counter
```

Then gate exactly three call sites (each with a `_dbg_pace` run counter for the gate/telemetry):

| phase | site gated | skipped region |
|---|---|---|
| 0 | skin | only the `_skin.call("update", …)` call, `world_manager.gd:1333-1335` (the `set_cover_query`/`set_band_query`/rim/block-LOD-place plumbing at `:1336-1381` stays every frame — cheap, and the far ring depends on fresh callables) |
| 1 | facet-tex | the whole `if _facet_tex != null …` block `world_manager.gd:1388-1419` (epoch pushes only change inside `update`, so skipping the block whole keeps slot/band state consistent) |
| 2 | DEM | the whole `if _relief_data != null …` block `world_manager.gd:1431-1451` (the FP_DEM_DEFER settle latch just re-checks 2 frames later) |

A block runs when `_pace_phase < 0 or _pace_phase == <its phase>`. Effect: during a plunge each
heavy driver runs at **1/3 cadence (~20 Hz)** and at most ONE of them pays its cost on any given
frame → the steady tail drops from ~14-16 ms to ≈ max(single driver) ≈ 5-6 ms, and each subsystem
still advances continuously (no freeze, no starvation). When the rate calms (touchdown, orbit,
walking) `_pace_phase` is −1 and the tail is **byte-identical to today**.

**Threshold** `STREAM_FALL_PACE_VY := 15.0` — above walk/jump vertical (~0-9 b/s, per the
`ENV_FALL_HOLD_VY` comment `cube_sphere.gd:4214`) but **below** the SN-BRAKE atmosphere terminal
speed (20 b/s), so pacing stays engaged through the alt≈70 surface-entry band and releases only as
the drag/landing actually arrests the fall (the EMA adds a few frames of natural linger — the same
resume-smearing idea as `FP_ENV_RESUME_PACED`).

**Side benefit:** while phase-1 skips, `_bg_last_frame_usec` (`:1402-1406`) measures a ~3-frame
delta → the `FP_BG_PREBAKE` governor reads "no headroom" → background fine bakes self-suppress
during the plunge, compounding with the freshly-shipped P7 prebake pacing (which this design does
not touch).

### 2.2 Flag B — `FP_REENTRY_VIEW_RAMP`: bounded-step near-view re-growth on descent

Add a pure-static clamp in `cube_sphere.gd` (testable headless, the `approach_view_distance`
precedent):

```gdscript
## FP_REENTRY_VIEW_RAMP: on a FAST DESCENT, the anchor's view re-growth is bounded to
## ANCHOR_GROW_STEP blocks per debounced write, staging the near-field streaming demand over
## many frames instead of one Δd-sized jump. Shrinking (ascent/release) is never clamped.
static func anchor_grow_clamp(want_vd: int, last_vd: int, descending_fast: bool) -> int:
    if not FP_REENTRY_VIEW_RAMP or not descending_fast or last_vd < 0 or want_vd <= last_vd:
        return want_vd
    return mini(want_vd, last_vd + ANCHOR_GROW_STEP)
```

Wire it at exactly one site — `_apply_approach_anchor`, `world_manager.gd:801-802`:

```gdscript
var near_vd := int(round(view_f))
near_vd = CubeSphere.anchor_grow_clamp(near_vd, _anchor_last_vd, _pace_descending())  # NEW
_anchor_last_vd = near_vd                                                             # NEW state var
_module_world.call("set_approach_anchor", offset_y, near_vd)
```

where `_pace_descending()` = `_alt_rate_ema < -STREAM_FALL_PACE_VY` (reuses Flag A's estimator; if
only Flag B is on, `_stream_pace_update_rate` still runs under `FP_STREAM_FALL_PACE or
FP_REENTRY_VIEW_RAMP`, mirroring the `FP_ENV_FALL_HOLD or FP_LAND_RAMP_HOLD` shared-signal
pattern at `:1283`). The `FP_BLOCK_LOD` rim coupling (`:809-810`) reads the same clamped `near_vd`,
so the L1 hand-off stays consistent by construction. The **direct** anchor paths —
`approach_anchor_step_now` / `dev_reanchor_near` (`world_manager.gd:815-849`, the teleport/settle
path) — bypass the clamp: they route to `_apply_approach_anchor` too, so pass an explicit
`bypass_ramp := true` arg down (teleports must restore the view immediately; STREAM-SETTLE holds
the player anyway).

**Sizing** `ANCHOR_GROW_STEP := 8` (blocks per 100 ms write ⇒ ~80 blocks/s of view growth ⇒ the
full 128-radius near view restores from zero in ≤ 1.6 s of writes). Descent from the 416 regime
release to the ground takes ≥ 8 s even at pre-drag speeds and ~20+ s at terminal 20 b/s, so the
near field is always fully resident well before touchdown — the ramp changes *when the demand is
issued*, never *whether*.

### 2.3 New consts (all in `cube_sphere.gd`, after the `FP_ENV_RESUME_PACED` block ~`:4236`)

```gdscript
const FP_STREAM_FALL_PACE := false   # §2.1 round-robin the 3 heavy update_streaming tail drivers on fast descent
const STREAM_FALL_PACE_VY := 15.0    # blocks/s radial descent rate that engages pacing (walk/jump ≈ 0-9; terminal 20)
const STREAM_PACE_RATE_CLAMP := 2000.0  # reject |alt-rate| samples above this (a set_alt/teleport, not motion)
const FP_REENTRY_VIEW_RAMP := false  # §2.2 bounded-step near-view re-growth while descending fast
const ANCHOR_GROW_STEP := 8          # max view_distance growth (blocks) per debounced anchor write on fast descent
```

### 2.4 Sub-attribution telemetry (makes the live A/B decisive)

Mirror the `_snow_us_max` pattern (`world_manager.gd:251-252`, `:3979-3990`): wrap the three tail
drivers in passive `ticks_usec` max-timers `_skin_us_max` / `_tex_us_max` / `_relief_us_max` and add
`skin_ms` / `tex_ms` / `relief_ms` to `take_perf_attrib()` (RemoteBridge already forwards the dict,
`remote_bridge.gd:833-834`). Unconditional like `snow_ms` (two `ticks_usec` reads per block —
noise), so the A/B can prove which driver dominated and that pacing removed it.

---

## 3. Gate plan

**New gate: `godot/src/tools/verify_stream_fall_pace.gd`** — modeled line-for-line on
`verify_stream_tick.gd` (bare `WorldManager`, self-describing on the compiled flag, headless).
Needs three tiny test hooks on WorldManager (the `debug_set_tail_frame` precedent, `:231`):
`debug_set_alt_rate(v: float, freeze: bool)` (write `_alt_rate_ema` + suppress the estimator so
sub-ms headless wall-clock can't overwrite it), `debug_pace_runs() -> Dictionary` (the three
counters), `debug_alt_rate() -> float`.

- **G-SFP-PACE** (on): force rate −30 (frozen), drive 6 tail frames (`debug_set_tail_frame` to
  force each); assert each of the three pace counters advanced **exactly 2** (round-robin, full
  coverage, one per frame). Off: each advanced 6 (shipped).
- **G-SFP-CALM** (on): rate 0 ⇒ all three counters advance every frame — pacing is provably
  dormant when not plunging (the orbit-settled / walking protection).
- **G-SFP-EST**: estimator plumbing — a teleport-sized altitude jump between two calls leaves
  `debug_alt_rate()` unmoved (STREAM_PACE_RATE_CLAMP rejection); a plausible descent moves it
  negative.
- **G-SFP-FLOOR**: copy of G-MTP-FLOOR (`verify_stream_tick.gd:52-71`) driven with pacing engaged —
  `block_id_at` over a column span is invariant across paced `update_streaming` calls (the paced
  blocks write **no collision state**; the no-fall-through invariant, pinned).
- **G-AVR-CLAMP**: pure-static arm on `CubeSphere.anchor_grow_clamp`: growth bounded to
  `ANCHOR_GROW_STEP` per write and monotone; reaches `full` in `ceil((full-lo)/STEP)` writes;
  shrink never clamped; `descending_fast=false` or flag off ⇒ identity (self-describing both arms).

**Existing gates:** `verify_feature.gd` FLAT must stay **6042/0** — all new code is behind the two
default-false flags (and the estimator behind `FP_STREAM_FALL_PACE or FP_REENTRY_VIEW_RAMP`), so
OFF is byte-identical; the counters/timers follow the already-shipped unconditional
`_dbg_tail_runs`/`_snow_us_max` precedent. `verify_stream_tick.gd`, `verify_alt_regime.gd`,
`verify_approach_anchor.gd` are untouched and must stay green (we add code *after* their asserted
sites; the anchor gate drives `approach_anchor_step_now`, which bypasses the ramp).

---

## 4. Risks and how the design avoids them

| risk | avoidance |
|---|---|
| **Fall-through terrain** (the FP_FLOOR_SURFACE_WELD / FP_TP_FLOOR_WELD history) | Player collision is **analytic** (`surface_y`/`block_id_at`/`floor_under`) and never reads the paced blocks (skin/tex/DEM are render-only; pinned by G-SFP-FLOOR). The safety head (streamer/GroundCollider/pos-latch) and the fall-through-critical tail steps — `_update_alt_regime` (the 416 re-entry release), `_update_approach_anchor`, `_manage_facet_pool`, `_load_defer_tick`, flip-settle — run **every tail frame, unpaced**. The one-shot re-entry redesignation (`_alt_reentry_pending`) is deliberately not staged. |
| **View ramp delays near meshes past touchdown** | Visual-only by the same analytic-physics argument; sizing bound §2.2 (full view restored in ≤1.6 s vs ≥8 s of sub-416 descent). Teleport/settle paths bypass the clamp and STREAM-SETTLE already holds the player until `near_column_meshed`. |
| **Regressing orbit-settled smoothness (P7)** | Pacing engages only on `alt_rate < −15 b/s` *radial*; a settled orbit has ~0 radial rate (post orbit-decay fix) and its horizontal 569 b/s never enters the signal. An eccentric orbit's descending arc may briefly pace the three cosmetic drivers — the far ring (the orbit-smoothness-critical node) steps in its own `_process` and is untouched, as are FP_PREBAKE_VIEW_SCOPE/COAST_CAP. G-SFP-CALM pins the dormant case. |
| **Skin/tex visual staleness during the plunge** | 20 Hz effective cadence per driver at 100+ blocks/s of camera motion — below perceptual relevance; each driver still converges continuously (round-robin, not a hold). |
| **Estimator poisoned by teleports/crossings** | Radial altitude is continuous across flips/crossings (world-radius based); set_alt-class jumps are rejected by `STREAM_PACE_RATE_CLAMP` (G-SFP-EST). |

---

## 5. Live A/B protocol

Same relay methodology as the #143 profile (freeze_player + set_alt stepped bands + telemetry
sampling), plus a **real fall** arm — pacing is rate-gated, so the stepped bands double as the
no-regression control (frozen ⇒ rate 0 ⇒ pacing dormant ⇒ bands must match baseline):

1. **Stepped bands (control):** alt 2500/1800/1200/700/350/150/70/30, ≥10 s each, record median
   `frame_ms`/`phys_ms`/`t_stream_us` + new `skin_ms`/`tex_ms`/`relief_ms`. PASS: within noise of
   the baseline table (proves OFF-equivalence at rest and attributes the 14-16 ms split).
2. **Real fall (the fix's arm):** dev-fly to alt 2500, kill thrust, free-fall to touchdown; sample
   at telemetry cadence the whole way. PASS criteria:
   - descent-window `t_stream_us` median ≤ **7 ms** (from 14-16) and p90 ≤ **12 ms**;
   - alt 600-800 crossing: no `phys_ms` sample > **30 ms** (from 48.6) and no `frame_ms` > **60**;
   - alt 40-100 surface entry: worst `frame_ms` ≤ **50** (from 83);
   - **lands on the surface** — final altitude within [0, 4] of `surface_y` under the player, no
     tunnel/teleport in the pose telemetry (the fall-through check);
   - `skin_ms`/`tex_ms`/`relief_ms` confirm the round-robin (≤ one driver hot per window).
3. **Orbit control:** hold a settled circular orbit 60 s — fps/frame_ms unchanged vs baseline
   (pacing dormant; protects P7).

Run each arm flags-OFF then flags-ON on the same build (deploy-cheats export), diff the tables.
