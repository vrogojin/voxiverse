# COSMOS-FOREST-SNOW-PROC — warm-forest main-thread snow burn: root cause + FP_SNOW_PRECIP_GATE design

Status: DESIGN v2 (root-caused, measured; fix not yet implemented).
v2 change: per user direction the gate is the strict WHITELIST — *the snow sim runs only when
active precipitation is falling AND the local temperature is below 0 °C* — not v1's
warm-column blacklist. §3 is redesigned around that rule; §3.4 records the one deliberate
exception (the melt question) for user confirmation.
Author: Fable architect session 2026-08-12
Telemetry: live warm forest, facet 1754 (~8665,10,14212), air 18.8 °C, no snow, fully
prebaked (fm_baked 3456/3456, tex_baked 3456), up_ms 433 s+.

---

## 0. TL;DR

The SnowfallSystem fixed step runs **unconditionally every 0.5 s in every biome**. In a warm,
snow-free forest each of its 32 columns still pays 2 **unmemoized faceted column-profile
computes** (full f64 `cell_dir` + 4–5 3D-noise samples each), 2–3 **`cell_value_at` →
`generated_cell` full per-cell resolves** (strata/tree canopy — expensive in a *forest*), the
**M1 melt/freeze evaluator** and a full **environment sample** — and then writes **nothing**.
Measured headless (native, flat path): a zero-write warm-forest step costs **6.4 ms**; on the
live web (WASM ×~10 GDScript, faceted profile ×2–3) that is the observed **18–44 ms
`snow_ms`** main-thread burst. The R2 de-burst path (`FP_SNOW_SLICED`, task #55) is
**default-off and the live burst signature says it is not flipped in the deploy sed** — and
even sliced, the work itself is wasted where snow cannot fall.

Fix: **FP_SNOW_PRECIP_GATE** — the physical whitelist at the top of
`SnowfallSystem._process_column`: a column is processed **only when it is actively
precipitating there AND the surface temperature is < 0 °C** (`SNOW_T0 := 0.0`,
`terrain_config.gd:82` — already the one freeze authority). The only exception is a
column that *currently holds snow or an overlay edit*, which keeps the shipped path so
existing snow still melts when warm and stale states still clear (§3.4 — the melt
decision, flagged for user confirmation). Predicate cost ≈ 4–5 µs/column; every skip is a
*proven no-op elision*, so world evolution stays **byte-equal**. Warm-forest `snow_ms`
→ ~0.2 ms; snowy-biome *dry spells* now also skip (a strict improvement over v1).

---

## 1. The measured problem (re-derived from the live telemetry, not the summary)

`tools/remote-bridge/results/telemetry.jsonl`, filtered to facet 1754 / on_ground /
fm_baked = 3456 (n = 4878 samples):

| key | p10 | p50 | p90 | max | nature |
|---|---|---|---|---|---|
| proc_ms | 17.9 | 26.5 | 76.5 | 934 | **whole-frame** (see §1.1) |
| snow_ms | 0.02 | 4.48 | 7.00 | 38.6 | real delta, window max |
| phys_ms | 5.2 | 6.1 | 11.5 | 92 | real delta |
| env_converge_ms | 0.00 | 0.02 | 0.02 | 21.5 | real delta |
| smooth_v2_commit_ms | 22.38 | 22.38 | 22.38 | 22.40 | **latched** (§1.2) |
| ctrl_ms | — | 0.22 | 0.28 | 4.3 | real delta |
| main_commit_ms | — | 0.00 | 0.02 | 0.08 | real delta |
| worst_ms | 33.5 | 36.3 | 79.8 | 965 | worst frame in window |
| fps | 32.6 | 39.2 | 47.6 | 61.3 | |

Correlation (the discriminating cut): windows with `snow_ms > 10` have **proc_ms p50 = 54.9**
(n = 159); windows with `snow_ms < 1` have **proc_ms p50 = 27.7** (n = 1539). The snow step
is the single largest *attributed* main-thread spike, ~+27 ms on the frames it bursts.

### 1.1 `proc_ms` is NOT a process-cost meter here

`proc_ms` is `Performance.TIME_PROCESS` (`src/net/remote_bridge.gd:624`). Per
COSMOS-PERF-POSTPORT (and the recorded lesson): on the threaded web export TIME_PROCESS reads
**whole-frame time** — it contains render submit and pacing, so its ~33 ms "floor" at ~30 fps
is the frame period itself, not a hidden 33 ms of simulation. The budget below therefore uses
only the real-delta keys.

### 1.2 `smooth_v2_commit_ms` 22.4 is stale, not recurring

It reports `FacetSmoothV2._last_commit_ms` — the **duration of the last whole-surface
ArrayMesh rebuild** (`src/world/facet_smooth_v2.gd:388`, set at :509/:599, read at :634).
Standing still, fully baked, nothing re-dirties → no commits → the value is latched from the
last rebuild. Being pinned at exactly 22.38 across 4878 samples confirms it. **It is not a
per-frame cost** and must not be summed into the frame budget.

### 1.3 The steady-state main-thread frame budget (attributed)

- `snow_ms`: 0 most frames; **one step every 0.5 s ≈ 4.5 ms p50, bursting 18–44 ms** (§2).
- `phys_ms`: 6 ms p50, spikes 27–92 ms (physics step + ground-collider work; separate issue).
- `env_converge_ms`: ~0 normally, occasional 9–35 ms slices (env convergence; bounded, rare).
- `ctrl_ms`/`main_commit_ms`/`vt_total_ms`/`tex_spent_ms`: ≈ 0 at steady state.
- **Unattributed residual**: `worst_ms` p50 is 36 ms even in windows where every attributed
  key is ≈ 0. On gl_compatibility web the render submit runs on the main thread
  (draws ≈ 171, prims ≈ 516k) and the vsync ladder quantizes 33→50 ms; the WASM allocator
  convoy is also known. This residual is REAL but it is *not* snow, *not* smooth_v2, *not*
  env — it is the next hunt after this fix (a per-frame attribution key for "render submit +
  rest" would pin it; out of scope here).

Verdict on the task's "other ~40 ms": it is (a) the TIME_PROCESS whole-frame artifact plus
(b) the ~36 ms unattributed worst-frame floor above — there is **no second hidden 40 ms
simulation system**. Snow is the one big attributed, removable cost.

---

## 2. Root cause (file:line)

### 2.1 Where snow_ms is measured and what runs

`WorldManager._process` (`src/world/world_manager.gd:790-800`) times exactly
`_snowfall.process(delta, _last_player_pos)` into `_snow_us_max` (window max; emitted as
`snow_ms` at :3599, reset :3606). Suppressors exist for airborne (`FP_SNOW_SKIP_AIRBORNE`),
orbital freeze, and fresh-load (`FP_LOAD_DEFER`) — **there is no precipitation/temperature
suppressor**: on the ground, storm or clear, warm or cold, the sim steps forever.

`SnowfallSystem.process` (`src/sim/snowfall_system.gd:84-99`): a wall-clock accumulator runs
`step_now` every `STEP_SECONDS = 0.5`, with **catch-up up to `MAX_STEPS_PER_FRAME = 4` steps
in one frame** after a hitch (:93). One step = one rotating 16×16 tile, ≤ 32 columns
(`MAX_COLUMN_UPDATES`), each through `_process_column` (:232).

### 2.2 What a WARM column pays (per column, per step)

`_process_column(x, z, …)` (`src/sim/snowfall_system.gd:232-293`), warm branch
(`ts ≥ SNOW_T0` → MELT, :277):

1. `TerrainConfig.height_at(x, z)` (:234) — memoized (`analytic_column_profile`,
   `terrain_config.gd:1234`); cheap after first touch. ✔
2. `TerrainConfig.column_profile(x, z).w` (:235) — **pcache = null ⇒ NOT memoized**. On the
   live FACETED build this is `facet_profile(facet, x, z)` recomputed **every call**
   (`terrain_config.gd:821-822` → :1058: f64 `FacetAtlas.cell_dir` + 4–5 3D-noise samples +
   mountain factor + height; **no internal memo** — confirmed :1058-1064).
3. `world.apply_state_transitions(surface)` (:250) — the M1 evaluator
   (`world_manager.gd:2059-2100`): `cell_value_at(surface)` (full
   `generated_cell` per-cell resolve — strata/ores/**tree canopy**, heavy in a forest) +
   `environment.sample(...)` (:2081) → `PerVoxelEnvironment.temperature`
   (`per_voxel_environment.gd:157-185`) whose `_climate_w` (:121-125) calls
   **`TerrainConfig.column_profile(x, z).w` pcache-less AGAIN** — a second full faceted
   profile compute — plus light/pressure/gravity fields.
4. `column_depth(x, z)` (:281 → :368-397) — `snow_stack_at` (shape-memo, cheap ✔) + 1–2
   `world.cell_value_at` = 1–2 more `generated_cell` resolves (tree cells in a forest).
5. Result: `d_cur = 0` → **return with zero writes**. `is_snowing` is never even consulted
   (warm branch); all of the above is pure waste, repeated every 0.5 s forever.

A COLD-but-DRY column wastes almost as much: it pays 1–4 and then `is_snowing` returns
false at :255-256 — zero writes again. Only cold + precipitating columns do real work.

### 2.3 Measured (headless probe, `src/tools/probe_snow_cost.gd`, native, flat path)

```
WARM forest step_now: 60 steps, writes=0 — per-step ms p50 6.71  p90 7.85  max 8.42
COLD        step_now: 60 steps, writes=223 — per-step ms p50 6.13  p90 8.63  max 13.8
WARM micro-split (per column, caches warm):
  apply_state_transitions 32.1 µs   column_depth 22.2 µs   cell_value(g+1) 19.6 µs
  env_sample 7.8 µs   column_profile 2.1 µs(*)   height_at 1.2 µs   snow_stack 0.8 µs
  surface_temp 0.3 µs   is_snowing 0.5 µs
```
(*) the FLAT profile is 3× 2D-noise ≈ 2 µs; the live FACETED profile (§2.2 item 2) is the
f64+3D-noise `facet_profile` with no memo — strictly heavier, and paid **twice** per column.

So a zero-write warm step costs ~6.4 ms **native**. The live build is (a) WASM GDScript
(×~10, recorded ×25 worst-case) and (b) faceted-profile-burdened; the observed live
**p50 4.5 ms / burst 18–44 ms** `snow_ms` is exactly this step, with the 38–44 ms ceiling
matching either a cool-tile faceted step (~32 cols × ~1.2 ms) or the `MAX_STEPS_PER_FRAME=4`
hitch catch-up (4 × ~10 ms) — both the same underlying per-column waste.

### 2.4 Why task #55 (R2, "snow off the main-thread hot path") does not cover this

R2 did **not** move the sim off-thread. It built `FP_SNOW_SLICED`
(`snowfall_system.gd:88-89, 101-162`): *no catch-up + drain 8 columns/frame*. That flag is
`const FP_SNOW_SLICED := false` (`cube_sphere.gd`, also false on the deployed
`deploy/cheats-eyeball` branch); the deploy flips flags via sed before export
(`remote_bridge.gd:691-693`), and the live burst signature (single-frame 38–44 ms spikes —
impossible for an 8-column drain at any plausible per-column cost) says **the sed does not
flip it**. Either way, slicing only spreads the waste; where snow cannot fall the work
itself is the bug. Note: the airborne fix in [[voxiverse-unattended-perf-2026-07-21]] was
`FP_SNOW_SKIP_AIRBORNE` — an *altitude* suppressor; there has never been a
precipitation/thermal one.

---

## 3. The fix — FP_SNOW_PRECIP_GATE (the physical whitelist)

**The rule (user-specified):** the snow sim processes a column ONLY when *active
precipitation is falling there* AND *the local surface temperature is below 0 °C*. In all
other cases the column's processing is disabled. The one designed exception — columns that
currently HOLD snow or an overlay edit keep the shipped path so melt/state-clear still work
— is §3.4, called out for user confirmation.

### 3.1 The two predicate inputs, and why they are ~µs

**Temperature.** `ts = ClimateModel.surface_temperature(g, t) [+ season_offset]` — exactly
what `_process_column` already computes at `snowfall_system.gd:234-242` and what the
generator's own snow stamp uses (`terrain_config.gd:1535: if ts >= SNOW_T0: no snow`, with
`SNOW_T0 := 0.0` at :82 — the user's "below 0 °C" is literally the existing one authority;
the HUD/env kind boundary uses the same zero crossing, `per_voxel_environment.gd:245`).
Under the flag the `t` read is rerouted from the unmemoized `column_profile(x, z).w` (:235)
to **`TerrainConfig.analytic_column_profile(x, z).w`** — identical value by construction
(`terrain_config.gd:1241-1247` shifts only `.x`), but served from the persistent analytic
memo (:1204-1226). Cost: height memo ~1.2 µs + profile memo ~1 µs + arithmetic ~0.3 µs.

**Active precipitation.** The sim's own storm gate `is_snowing(x, z)`
(`snowfall_system.gd:414-424`) *is* the precipitation state that drives accumulation —
there is no other:
- Live today (FP_PRECIP / FP_CLIMATE_GRID off): the SEED+105 spatially-coherent storm noise
  (:415-419), **measured 0.47 µs/call** (§2.3). Pure in (SEED, step_counter, position).
- With FP_PRECIP on: :420-423 ANDs the weather grid — `environment.precipitation()`
  (`per_voxel_environment.gd:232-245`): one `cloud_water_at_dir` grid lookup + threshold,
  kind resolved by the same ts<0 zero-crossing. The predicate composes unchanged. (Caveat
  noted: `precipitation()`'s :242 `_climate_w` is itself a pcache-less profile call — a
  pre-existing FP_PRECIP-only cost; an optional third injection under this same flag can
  reroute `per_voxel_environment.gd:123/125` to the analytic memo. Live builds have
  FP_PRECIP off, so it does not affect this fix's numbers.)

So the whole predicate is a memo read + a compare + one noise/grid sample — **no
re-derivation**, ~4–5 µs/column total.

### 3.2 The injection (SnowfallSystem._process_column, after :242 — ts final, before :250)

```gdscript
# COSMOS-FOREST-SNOW-PROC (FP_SNOW_PRECIP_GATE): the snow sim runs ONLY under freezing
# precipitation. A bare generated column outside (precip AND ts < 0) is a PROVEN no-op for
# this whole method (§3.3) — skip it before the evaluator/depth machinery. Columns that
# HOLD snow or carry an overlay edit keep the shipped path (§3.4: melt + state-clear).
if _gate_enabled:
    if not world.has_edit(Vector3i(x, g, z)) and not world.has_edit(Vector3i(x, g + 1, z)):
        if ts >= TerrainConfig.SNOW_T0:
            if TerrainConfig.snow_stack_at(x, z) == 0:
                return 0          # warm, no snow anywhere → disabled (rain or clear alike)
            # warm WITH baseline snow (seasonal thaw fringe) → fall through: MELT must run
        elif not is_snowing(x, z):
            return 0              # sub-zero but DRY → disabled (melt unreachable at ts < 0)
        # sub-zero AND precipitating → fall through: the whitelist case, ACCUMULATE runs
```

`var _gate_enabled := CubeSphere.FP_SNOW_PRECIP_GATE` as an instance var so the gate suite
drives both states directly (the `process_sliced` direct-drive pattern, :112). New flag
`CubeSphere.FP_SNOW_PRECIP_GATE := false` (byte-off). Second injection under the same flag:
the :235 `t` read → `analytic_column_profile(x, z).w` (§3.1).

Decision-table view of the predicate (bare, unedited columns):

| ts < 0 | precip | shipped outcome | gated outcome |
|---|---|---|---|
| yes | yes | ACCUMULATE runs | **full path (whitelist)** |
| yes | no | AST no-op + `is_snowing` false → 0 writes | **skip** |
| no | yes (rain) | MELT branch, depth 0 → 0 writes | **skip** |
| no | no | MELT branch, depth 0 → 0 writes | **skip** |

### 3.3 Proof every skip is a no-op (byte-equal world evolution)

For a column with no edit at `(x,g,z)` or `(x,g+1,z)`:

1. **M1 evaluator** (:250): the surface cell is unedited ⇒ generated value ⇒ "worldgen is
   the fixed point of the transition" (`world_manager.gd:2049-2051`) ⇒
   `apply_state_transitions` changes nothing, at ANY temperature. Any *stale* state bit
   necessarily lives in `_edits` (`set_state → _write_cell → _edits`,
   `world_manager.gd:2043`) ⇒ `has_edit(surface)` true ⇒ **not skipped**.
2. **Warm + `snow_stack_at == 0`**: dynamic snow is contiguous from `g+1` and the warm
   baseline is bare (:278-279, `terrain_config.gd:1535`), so ANY dynamic snow implies an
   edit at `(x,g+1,z)` ⇒ caught. With none, the shipped MELT branch computes
   `column_depth == 0` and returns 0 writes. Skip = same outcome.
3. **Cold + dry**: MELT is unreachable (`ts < SNOW_T0` takes the ACCUMULATE branch, :253),
   and ACCUMULATE returns at :255-256 because `is_snowing` is false — **regardless of how
   much snow the column holds**. 0 writes. Skip = same outcome. (This is why cold snowy
   biomes' dry spells skip too — a strict improvement over the v1 blacklist, which still
   paid the full path on every cold column.)
4. **Cold + precip / warm-with-baseline-snow / any edited column**: NOT skipped — shipped
   path verbatim.
5. `step_counter`, tile rotation, write caps, ground-rebuild debounce: untouched — the skip
   removes only per-column reads, never a write or a counter.

Hence flag-on the `_edits` overlay, `snow_cells`, `last_writes` and every rendered cell are
**byte-identical** to flag-off for all time; only CPU time changes. Flag-off the new lines
are `if false` + the shipped :235 read — byte-identical code path. One ordering note:
`is_snowing` advances no state (pure in step_counter), so consulting it earlier than the
shipped :254 call site changes nothing.

### 3.4 The melt decision (FLAGGED FOR USER CONFIRMATION)

Taken **literally**, "disabled in ALL other cases" would also freeze the melt path: snow
already on the ground would persist as static edits when it warms or the storm passes —
never melting, never freeing the `snow_cells` budget, and stale `snow_capped` bits would
never clear. That both looks wrong (permanent snow patches in a thaw) and breaks the
byte-equivalence guarantee this project's flags are held to.

**Chosen: option (a)** — columns that currently hold snow (baseline `snow_stack_at != 0`)
or carry an overlay edit (dynamic snow, dug/placed cells, stale state bits — all live in
`_edits`) keep the shipped path. This *is* the "separate ultra-cheap melt-only pass" in the
minimal form: no second scheduler, just the whitelist's exception set. It is self-
extinguishing — a warm snow column melts one tenth per visit until bare, the edit reverts
(`_melt_cell`, :320-328), and from then on the column skips like any other. The exception
set is exactly the columns physics says still need attention, it is empty in the warm
forest (the measured problem), and it preserves byte-equal world evolution. Option (b)
(literal disable) is rejected but trivially available by deleting the `snow_stack_at`/
`has_edit` escapes — at the cost of permanent-snow artifacts and a behavior (not just perf)
diff. **Please confirm (a) is the intended reading.**

### 3.5 Perf estimate

- Warm forest (facet 1754): every column skips at ~4 µs (warm needs no `is_snowing` call)
  ⇒ step ≈ 32 × 4 µs + tile enumeration ≈ **0.3 ms native / ~1–2 ms web worst** (vs
  18–44 ms) ⇒ `snow_ms` p50 4.5 → **≤ 0.3**, max 38–44 → **≤ 3** (even a 4-step catch-up
  burst ≤ ~2 ms). The snow-correlated proc_ms delta (+27 ms p50 on burst windows)
  disappears; fps p10 32.6 → ~40, p50 into the low-to-mid 40s. Remaining limiter: the §1.3
  unattributed ~36 ms worst-frame floor + phys spikes (explicitly NOT snow).
- Cold snowy biome, dry spell: columns skip at ~5 µs (one extra `is_snowing`) — the same
  ~20× step reduction v1 could not deliver there.
- Cold + storm: unchanged cost by design (~5–14 ms/step measured native — the sim working).
  Optional zero-code knob: sed-flip the gate-proven `FP_SNOW_SLICED` to de-burst those
  steps to ≤ 8 columns/frame (G-SLICE-EQUIV already proves byte-equal outcomes).
- Never-OOM: work removal only; the predicate allocates nothing. gl_compat-safe: no render
  change.

---

## 4. Gates (headless, `verify_snow_precip_gate.gd`, drives `_gate_enabled` both ways)

The four-quadrant matrix plus the exception set:

- **G-PGATE-EQUIV** — warm-forest, cold-dry, and cold-storm regions, K = 80 steps each,
  same (step_counter, player_col): ordered write-cell fingerprint + `snow_cells` +
  `step_counter` identical between `_gate_enabled = false` and `true`. (§3.3, asserted.)
- **G-PGATE-COLD-PRECIP** — cold region during storm phases (`is_snowing` true windows):
  `writes_total > 0` and equal to the reference — snow still falls and deepens.
- **G-PGATE-COLD-DRY** — cold region, storm-free step_counter phases: gated run performs
  0 writes AND its per-step cost ≤ 25 % of reference (the new skip actually engages).
- **G-PGATE-WARM** — warm forest: 0 writes both arms; gated per-step cost ≤ 25 % of
  reference (subsumes warm+rain — `is_snowing` is not even consulted when warm).
- **G-PGATE-MELT** — warm column with dynamic snow injected (`_write_cell` a snow layer at
  `g+1`): melts step-by-step to baseline exactly as the reference (edit reverted), THEN the
  column starts skipping. Warm column with a stale `snow_capped` bit via `set_state`: the
  evaluator clears it (skip defeated by `has_edit(surface)`).
- **G-PGATE-OFF** — `_gate_enabled = false` behaves as shipped (the reference arm of
  G-PGATE-EQUIV); the flag const defaults false ⇒ live build byte-off.

## 5. Live A/B

1. Deploy with `FP_SNOW_PRECIP_GATE` sed-flipped on (everything else unchanged).
2. **Warm arm** — same spot (facet 1754, ~8665,10,14212), warmed to fm_baked 3456, ≥ 120 s
   standing + walking: assert `snow_ms` p50 < 0.5 and max < 5 (was 4.5 / 44); proc_ms
   windows with snow > 10 count → 0; fps p10 ≥ 38 (was 32.6). Screenshot: no visual change.
3. **Cold + precip control** — a snowy/taiga or high-mountain spot (HUD ground temp < 0 °C):
   wait/teleport into a storm window and assert `snow_ms` returns non-trivial (~2–8 window
   p50 — the sim working) and snow visibly deepens (frame captures ≥ 60 s apart). During the
   SAME session's storm-free minutes, `snow_ms` should drop to ~0 — the dry-spell skip,
   observable live.
4. **Melt spot-check** — carry accumulated snow into a warm fringe (or use the seasonal
   thaw edge if FP_SEASONS is flipped): existing snow visibly recedes over minutes.
5. Regression watch: `hitches` rate not up; `heap_mb` flat (no new allocation).

## 6. Honest verdict

The out-of-storm snow burn is fully removable with a µs-scale whitelist — no refactor, and
every skipped column is provably a shipped no-op, so the world stays byte-equal. It buys
back the single largest attributed main-thread spike (~27 ms p50 on the frames it hits, up
to 44 ms) in ANY biome that isn't under active snowfall — warm forest and cold dry spells
alike. It does NOT buy the other half: the ~36 ms p50 unattributed worst-frame floor (§1.3
— main-thread render submit / vsync ladder / allocator, plus phys_ms spikes to 92 ms)
persists and caps steady-state fps in the low 40s; that is the next hunt. During an actual
cold storm the step keeps its real cost by design; flipping the existing FP_SNOW_SLICED at
deploy bounds it to 8 columns/frame with gate-proven identical outcomes.

Open item for the user: confirm the §3.4 melt reading — snow-holding columns stay live so
thaw works (recommended, and what this design specifies); a literal all-disabled reading
would leave permanent snow and is a behavior change, not just a perf one.

## 7. Artifacts

- Measurement probe: `godot/src/tools/probe_snow_cost.gd` (headless; not a gate).
- Telemetry basis: `tools/remote-bridge/results/telemetry.jsonl` (facet-1754 filter, §1).
