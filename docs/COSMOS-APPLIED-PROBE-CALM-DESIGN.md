# COSMOS APPLIED-PROBE-CALM — stop the far ring's perpetual full-shell re-emit

**Task #123 (`FP_APPLIED_PROBE_CALM`).**
Author: Fable. Companion to docs/COSMOS-STREAM-IDLE-DIET-DESIGN.md §9 (which named the
suspect) and docs/COSMOS-FOREST-FPS-DESIGN.md (task #119 — this is the spike source that
survived FP_FAR_TREES_DELTA).

> **REVISION 2 (2026-08-13) — READ §R2 FIRST.** §§1–6 below pinned the trigger on the
> FP_FARRING_CULL_COVERED cull APPLY. That analysis is **correct for the flag but the
> flag is NOT DEPLOYED** — the served FARRING set is ACTIVE_NOBLACK, APPLIED_COVER,
> ASYNC_REBUILD, FAST_REBUILD, FULL_COVER, UNCOVERED_TRUE (+ APPLIED_PROBE_SLAB,
> APPLIED_VIEW_BAND), and `_cull_on()` (`facet_far_ring.gd:2512`) gates the whole cull
> on FP_FARRING_CULL_COVERED ⇒ `:2701-02` never runs live. The cull-side impl (c02eb30)
> is HELD. §R2 re-pins the trigger against the deployed set and revises the fix to a
> **sink-side** coalescer that is robust to which source fires. LESSON (recorded): a
> root-cause verdict must be filtered through the SERVED flag set, never the tree's
> constants — the same discipline as dumping flags from the served pck.

## 0. The confirmed live evidence

Stationary warm forest (facet 1754, FP_FAR_TREES_DELTA live), one remote session:

- **182 `{"type":"farring"}` re-emit events**, `path=async`, `build_ms` 1,500–2,150
  (worker), **`swap_ms` 60–94 ms — a MAIN-THREAD stall each** (the 55–181 ms worst_ms
  spikes; `cap` null on the >90 ms windows ⇒ not the telemetry confound).
- `verts` **monotonically decrementing** 489,078 → 476,586 (Δ ≈ 12.5 k over the session,
  ≈ 68 verts ≈ ~11 backstop cells per event): the FULL_COVER shell is being rebuilt over
  and over to drop a handful more covered cells each time.
- `sh_applied_r` **steady at 96** the whole session — the §9 shrink-to-zero ladder theory
  is **corrected**: the trigger is NOT the applied ladder oscillating.
- `stream_credit` pinned at **0** the whole session.

## 1. ROOT CAUSE — the covered-cell cull's APPLY fires per trickle step, and it is credit-immune

### 1.1 The trigger (pinned)

The re-emit driver is the **FP_FARRING_CULL_COVERED covered-cell cull**, not
`_applied_probe_step` (which only sets `_pending` when `_applied_r` changes,
`facet_far_ring.gd:1733-1734` — and `sh_applied_r` was constant) and not
FP_APPLIED_VIEW_BAND (`:1740-1744` only records `_applied_band`; it never touches
`_pending`). The chain, every `CULL_REAP_MS = 100 ms` (`cube_sphere.gd:1665`):

1. `_cull_update` (`facet_far_ring.gd:2671-2702`) re-probes **every cell of every live
   backstop facet** — `BACKSTOP_CELLS² = 256` cells/facet (`cube_sphere.gd:334`), each an
   `is_area_meshed`-class engine call via `_cull_probe_cell` (`:2661-2664`) — and feeds
   the per-cell hysteresis (`cull_feed :2526-2549`, `CULL_CONFIRM = 2`).
2. The decoupled decider `_cull_decide_reemit` (`:2619-2631`) APPLIES the live mask when
   it has been stable for **`CULL_SETTLE_PROBES = 3` probes (≈ 300 ms)**, differs from
   committed, and **≥ `CULL_REBUILD_MS = 250 ms`** since the last APPLY
   (`cube_sphere.gd:1674-1675`) → sets `_pending = true` (`:2701-2702`).
3. `_pending` wakes the surface-converge path out of its idle short-circuit
   (`_surface_converge_emit`, `:1472`) → `_begin_rebuild()` (`:1488` et al. →
   `:1904-1909`) → async worker build (1.5–2.1 **s**) → main-thread
   `_swap_in_arrays` of the ~480 k-vert shell (`:2156`, the 60–94 ms stall) → the
   `farring` event (`:3032-3038`).

The decider *was* built to coalesce ("never per probe", `:2668-2670`) — but its
constants (300 ms settle / 250 ms rate-limit) were tuned for the round-2 era when the
rebuild was the thing being protected, not for a **minutes-long coverage trickle**: every
time ~11 more cells confirm covered, 300 ms of quiet elapses, and a fresh full-shell
rebuild fires. 182 times.

### 1.2 Why the mask trickles for minutes — the third feedback trap

The cull probes `is_area_meshed` over the near field. With credit pinned at 0, the
mesher's admission surfaces are floored to a crawl (`apply_budget_ms` / `grant_count` at
`CTRL_RELIEF_FLOOR` fractions, `stream_load_controller.gd:195-202`) — so the residual
near-field mesh blocks land over **minutes**, each landing flips a few more probe cells
covered, each flip earns another APPLY, each APPLY's 60–94 ms swap keeps
`frame_worst_ema` over the setpoint, which keeps credit at 0, which keeps the near field
slow. **The cull's own rebuilds sustain the coverage churn that triggers them.** Same
feedback-trap class as obs-2 and the far-trees PWM (forest-fps §2.3), one layer further
out — and this one is **credit-immune**: credit gates far-trees (`facet_far_trees.gd:481`),
smooth-v2's first commit (`:1325`), and pool promotes — never the shell re-emit.

Honest note: even if the trickle has an additional driver (probe boundary
nondeterminism, skin/collider interplay), the fix below bounds the re-emits regardless of
the trickle's exact source — it does not depend on this paragraph being the whole story.

### 1.3 The cost/benefit absurdity being fixed

Each APPLY spends ~2 s of a worker + a 60–94 ms main stall to remove **~11 cells ≈ 22
triangles of overdraw** that already sit *behind opaque near voxels* (the cull is an
overdraw diet, U2). Total harvested this session: ~2.5 % of the backstop's verts, paid
for with 182 stalls. Regression provenance: #113 `FP_APPLIED_PROBE_SLAB` (PR #50) and
#117 `FP_APPLIED_VIEW_BAND` (PR #56) made coverage *provable* — so the cull, dormant
while the ladder was dead, went from never-firing to perpetually-firing.

## 2. THE FIX — `FP_APPLIED_PROBE_CALM`

Four measures, all inside the existing decider/probe functions, all flag-guarded.
Design law: **FLUSH (safety) is never delayed; APPLY (luxury) is heavily coalesced.**
The asymmetry is inherited from the shipped state machine's own doctrine ("holes are
worse than overdraw", `:2524`) — deferring an APPLY only leaves cells DRAWN behind
opaque near voxels, i.e. exactly the pre-cull shipped visual. Zero correctness debt.

### 2.1 Credit-gate the APPLY (breaks the feedback loop)

In `_cull_decide_reemit` (`:2625`), the APPLY branch additionally requires
`_stream_credit_ok` — the bool the far ring **already holds** (`:415`, fed per tick by
WorldManager `world_manager.gd:1317-1318`, the same gate smooth-v2 and far-trees ride,
`:1325`, `:1335`). Under overload the shell simply stops rebuilding for overdraw
savings → the spikes stop → `frame_worst_ema` falls → credit recovers → near-field
grants recover → coverage converges *faster* → the trap unwinds. The FLUSH branch
(`:2621-2624`) is untouched — safety re-emits stay immediate and un-rate-limited.

### 2.2 Real settle + real rate-limit + delta deadband

APPLY admission under the flag becomes: quiet for `CALM_SETTLE_PROBES` (20 probes ≈ 2 s)
AND `now − _cull_last_reemit_ms ≥ CALM_APPLY_MIN_MS` (10 s) AND (live∖committed delta
≥ `CALM_MIN_CELLS` (24) OR quiet ≥ `CALM_HARVEST_PROBES` (300 ≈ 30 s — the final
harvest, so a small settled remainder is still eventually collected)). A minutes-long
trickle now coalesces into **~1 APPLY per settled plateau** instead of one per 11 cells.
The delta count is computed inside the existing `_cull_mask_differs` walk (`:2575-2582`
— return a count instead of a bool under the flag; off ⇒ early-return-true behaviour
identical).

### 2.3 Probe diet + flap pin

- **Slice probing**: `_cull_update`'s full 256-cells × N-facets probe sweep every 100 ms
  (`:2687-2689`) becomes `CALM_PROBE_SLICE` (64) cells per facet per reap, round-robin —
  full grid coverage every 4 reaps ≈ 0.4 s. Safety margin: un-cover detection is what
  FLUSH needs promptly, and the probe AABB is dilated +`CULL_DILATE = 32` blocks
  (`:2653`, `cube_sphere.gd:1663`) — near retreat at walk speed (~6 b/s) takes >5 s to
  cross the dilation band, so a ≤0.4 s detection lag keeps FLUSH firing well before an
  actual hole (the shipped race argument `:1665` comment, unweakened). Cuts the
  steady-state probe load ~4×.
- **Flap pin**: a cell whose covered/uncovered reads flip ≥ `CALM_FLAP_N` (4) times gets
  pinned DRAWN (streak forced 0, excluded from future culling until its facet's mask is
  pruned/reset `:2692-2694`). Drawing is always safe (INVARIANT G-CV-SAFE preserved —
  culled ⊆ covered can only get *more* true); this ends any FLUSH↔APPLY oscillation a
  boundary cell could sustain. One byte per cell in the existing streak array's spare
  range (values > CULL_CONFIRM are free).

### 2.4 Applied-ladder climb coalescing (the §9 residual, kept)

`_applied_probe_step` (`:1720-1744`): under the flag, a **grow** step (`:1730-1732`)
no longer sets `_pending` per +16 step; the climb runs to its fixpoint (next step fails
or `APPLIED_PROBE_MAX`) and sets `_pending` **once** on the terminal step. A **shrink**
(`:1728-1729`) still sets `_pending` immediately — shrink means the coverage claim broke
(sunk cells may now be wrongly hidden ⇒ safety, same asymmetry). This didn't fire in
this session (`sh_applied_r` constant) but converts the crossing/settle climb from up to
7 re-emits to 2 (shrink + fixpoint), closing the burst mechanism before it is ever
observed live.

### 2.5 Flags + constants (`cube_sphere.gd`, beside the CULL block `:1661-1675`)

```gdscript
const FP_APPLIED_PROBE_CALM := false  # coalesce far-ring cull/ladder re-emits: FLUSH stays instant, APPLY settles
const CALM_SETTLE_PROBES := 20        # live-mask quiet probes (~2 s) before an APPLY is considered (shipped 3)
const CALM_APPLY_MIN_MS := 10000      # min wall-ms between APPLY re-emits (shipped 250)
const CALM_MIN_CELLS := 24            # min live∖committed cell delta to justify a full-shell APPLY ...
const CALM_HARVEST_PROBES := 300      # ... unless quiet this long (~30 s) — final overdraw harvest
const CALM_PROBE_SLICE := 64          # cull cells probed per facet per reap (full grid ≤ 4 reaps ≈ 0.4 s)
const CALM_FLAP_N := 4                # covered↔uncovered flips that pin a cell DRAWN (safety direction)
```

New telemetry (unconditional, house-style cheap): expose the existing
`_cull_reemit_count` (`:365`) plus a live/committed delta cell count in the stats dict
beside `sh_applied_r` (`:3145`) as `sh_cull_reemits` / `sh_cull_delta` — the live A/B
discriminator, and the counter G-APC gates read back.

### 2.6 Byte-off / gl_compat / NEVER-OOM

Every changed decision is inside `if CubeSphere.FP_APPLIED_PROBE_CALM` (const false ⇒
shipped `CULL_SETTLE_PROBES/CULL_REBUILD_MS` comparisons and the per-step ladder
`_pending` writes run verbatim; the flap-pin byte range is never written; slice state
never allocated). No shader, no render-path change (gl_compat untouched — the fix
*removes* GPU re-uploads). Memory: one int cursor per facet for the slice round-robin +
the flap counts inside the existing streak arrays ⇒ ≤ a few hundred bytes, pruned with
the masks (`:2692-2698`). NEVER-OOM unaffected — the shell's vert ceiling is unchanged;
deferred APPLYs keep MORE verts resident transiently, bounded by the shipped FULL_COVER
mesh size (which is the flag-off steady state anyway).

## 3. Correctness — #113/#117 coverage guarantees preserved

- **No see-through / no hole**: holes are FLUSH's domain; FLUSH is untouched and still
  un-rate-limited (`:2621-2624`), still fed by the dilated probe with a ≥5 s
  motion-margin (§2.3). Culled ⊆ covered (G-CV-SAFE `:2525`) can only strengthen under
  the flag (we cull less, later).
- **No far-over-near / grey regression**: #113/#117's fix is the applied-cover *ladder
  zones + sink* at emit, driven by `_applied_r`/`_applied_band` — both computed exactly
  as shipped every frame. Only the ladder's *re-emit cadence on grow* changes (§2.4:
  once per climb instead of per step; shrink immediate), so zone transitions land within
  one climb (~7 frames) of today. The mesa/grass-base screenshots re-verify this in the
  A/B.
- **Convergence**: an APPLY still eventually fires for any settled non-empty delta
  (the 30 s harvest term) — committed == live at rest is reached, just not re-reached
  180 times on the way.

## 4. Gates (new `verify_probe_calm.gd`; `cull_feed`/`_cull_decide_reemit` are already
headlessly drivable with mocked reads + injectable `now_ms`, `:2521`, `:2612`)

- **G-APC-1 coalesce**: feed a scripted trickle (11 cells confirm per ~1 s, 3 min
  simulated) → flag on: APPLY count ≤ plateau count (assert ≤ 5 vs shipped ≈ 180);
  committed == live at the end.
- **G-APC-2 safety**: un-cover a committed cell mid-trickle → FLUSH fires the SAME
  decide pass, rate-limit ignored; G-CV-SAFE invariant suite stays green.
- **G-APC-3 credit gate**: `_stream_credit_ok=false` ⇒ zero APPLYs ever (FLUSH still
  fires); flip true ⇒ APPLY on the next eligible decide.
- **G-APC-4 flap pin**: oscillate one cell ≥ CALM_FLAP_N ⇒ it stays drawn, no further
  re-emits from it; facet prune resets it.
- **G-APC-5 ladder**: drive a 0→112 climb ⇒ exactly one `_pending` at fixpoint; a
  shrink ⇒ `_pending` same step. (Extends verify_applied_* fixtures.)
- **G-APC-6 slice coverage**: every cell index probed within 4 reaps; detection lag of a
  scripted un-cover ≤ 4 reaps.
- **G-APC-7 flag-off parity**: shipped decide/ladder behaviour verbatim (APPLY count ==
  shipped for the same trickle), standard flag-off export compare; existing cull gates
  (G-CV-*) green both ways.

## 5. Live A/B (stationary forest, the #119/#123 protocol)

Pass criteria: `farring` events **182 → < 10/session** (and none in any 5-min stationary
window after warm); `worst_ms` unimodal (mass > 75 ms < 10 % of windows, was ~50 %);
`stream_credit` p50 > 0 (the trap unwound); fps p50 recovers to the DELTA-era clean mode
(~38–42, from the observed 10–27); `sh_cull_reemits` flat at rest. Regression checks:
grass-base (#113) + mesa (#117) screenshot spots — no grey oval, no far-over-near; chop
a tree with the far band visible; then the walk loop — crossings still re-emit promptly
(FLUSH + `_pending` from role events are untouched), no hole flash at facet borders.

## 6. Interaction with FP_FAR_TREES_DELTA + FP_STREAM_IDLE_DIET — and priority

Three flags, three disjoint idle-gates: DELTA gates the far-trees tier step (render
frame), IDLE_DIET gates the physics-tick streaming tail, CALM gates the far-ring
re-emit decision (render frame, `_cull_decide_reemit`/`_applied_probe_step`). No shared
state beyond the credit bool they all *read*. The system-level composition matters:
**CALM is the one that actually releases the credit** — in the measured session credit
was pinned 0, which keeps DELTA's tier step gated (`facet_far_trees.gd:481`) and
floors near-field grants; without CALM, both other fixes run in a starved regime.
Ship/measure order: **CALM first (or together with DELTA), IDLE_DIET after** — and
re-run the IDLE_DIET baseline once CALM is live, since the floor it targets is currently
contaminated by the spike windows.

**Honest verdict:** highest-value forest fix currently known — it removes 182 × (60–94 ms
main stall + ~2 s worker occupancy) per session and unwinds the credit trap that starves
everything else. It does NOT change the ~14 ms render residual; after CALM + DELTA the
stationary forest should sit at the clean-mode ~38–42 fps, and the remaining climb to
50+ is the backstop vertex diet (forest-fps §6.4/§7), not another scheduler fix.

---

# §R2 — REVISION 2: the DEPLOYED trigger set, and the sink-side fix

## R2.1 Deployed-flag filter of every `_pending = true` site

All 13 arm sites, filtered against the served set (CULL_COVERED **off**; ACTIVE_NOBLACK,
APPLIED_COVER, ASYNC_REBUILD, FAST_REBUILD, FULL_COVER, UNCOVERED_TRUE, APPLIED_PROBE_SLAB,
APPLIED_VIEW_BAND **on**) for a *stationary* player:

| site | source | live? | can fire repeatedly at rest? |
|---|---|---|---|
| `:602` | boot-warm completion | one-shot | no |
| `:641` | facet crossing | needs crossing | no |
| `:739` / `:892` | `_smooth.consume_changed()` / `_mesh_inc_gate` | only if **FP_FAR_SMOOTH** (`_smooth` built `:527-529`) — presence in served set UNCONFIRMED | if live: yes (tile lands/leaves) |
| `:1226` (`_shell_snapshot`) | camera drift | camera static | no |
| `:1295` | pool exclusion change | pool stable at rest (≤ timer retires) | rare |
| **`:1591`** | **FP_FARRING_ACTIVE_NOBLACK** `_noblack_guarantee` | **YES** | **yes — see R2.2** |
| `:1626` | UNCOVERED_TRUE column drift (`UNSINK_DRIFT_BLOCKS=16`) | yes | no (stationary column) |
| **`:1734`** | **applied ladder `_applied_r` change** | **YES** | **yes — see R2.3** |
| `:2702` | cull APPLY | **NOT DEPLOYED** | — (the §1 mis-pin) |
| `:4371` | band/close-up **slot-map push** (`set_band_slots`/`set_closeup_slots`, Q2 `FP_SLOT_INDIRECT` off `:1165`) | yes (pushed from `world_manager.gd:1298-1307` on baker epoch bumps) | only while the band/close-up tier is still (re)baking |
| `:5215` | `_drain_relief_dirty` (FP_RELIEF_REEMIT) | flag presence unconfirmed; DEM fully baked ⇒ `_relief_dirty` empty | no at warm rest |

**The R4.2 "endless train" is ruled OUT for the deployed set** unless FP_FAR_SMOOTH is
served: the third disjunct of `:1590` (`not _emitted.has(fid)`) needs the active facet
absent from the emit set, but `_front_visible` **forces the active facet in** under
ACTIVE_NOBLACK+FULL_COVER (`:2283-84`) and FULL_COVER bypasses the shipped active-skip
(`:2295-2300`), so after any completed rebuild `_emitted.has(active)` is true
(`:2168-2184`). The documented train (`:1568-1574`) requires the `_smooth_covered`
exclusion (`visible_fids :2912`), i.e. `_smooth != null` (`:2880`) = FP_FAR_SMOOTH.
**Action for the A/B owner: confirm FP_FAR_SMOOTH / FP_SMOOTH_V2 / FP_BLOCKY_FARRING /
FP_RELIEF_REEMIT / FP_SLOT_INDIRECT in the served set** — they select between R2.2-R2.4.

## R2.2 Live candidate A — NOBLACK unsink flips (`:1584-1592`)

`_noblack_guarantee` runs EVERY render frame (`:1368`) and probes a tight
20×192×20-block column under the camera (`_noblack_near_meshed :1600-1613`,
`NOBLACK_PROBE_HALF=10`, `cube_sphere.gd:1710-11`) via the same `is_area_meshed`
callable. Any flip of that read toggles `new_unsink` between `fid` and `-1` and each
toggle arms `_pending` (`:1587-1591`). At credit-0 the near field under/around the
camera is still trickling mesh blocks (grants floored, §1.2 — unchanged), and a block
REMESH inside the probe box transiently reads not-meshed ⇒ covered→uncovered→covered
double-flips ⇒ 2 re-emits per transient. Sustained trickle ⇒ sustained flips.

## R2.3 Live candidate B — applied-ladder excursions, and why "steady 96" does NOT refute it

`sh_applied_r` is sampled **once per 0.25 s telemetry window** (`facet_far_ring.gd:3145`
read at stats time). A full shrink-regrow excursion (96→0 on one failed
`_applied_box_meshed` read `:1728-29`, then +16/frame ×6 back to 96) completes in
~0.1–0.2 s — **inside one window** — so per-window sampling aliases it to "steady 96".
The §9 mechanism therefore stands as a live candidate: the same remesh-transient false
reads that drive R2.2 (the ladder box is far larger — r=96 ⇒ ~192 blocks wide — so it
intersects MORE remeshing blocks) collapse and regrow the ladder; each excursion arms
`_pending` up to 7×, which the async pipeline coalesces into ~1–2 rebuilds. ~26+
excursions/session × spacing ≈ the observed cadence. The verts-monotone-down signature
is **passive** under both A and B: each rebuild picks up the newest per-facet geometry
suppression (`FP_SMOOTH_V2_EXCL_BLKLOD` assembler skip `:2940`, if V2+BLOCKY served, as
V2 residency grows at the credit-0 crawl) — the verts delta identifies what the rebuilds
*absorb*, not what *triggers* them.

## R2.4 Zero-deploy discriminators (existing jsonl), then one-deploy confirmation

1. **Inter-event gap histogram** of the 182 farring events (already captured): regular
   back-to-back ~2–3 s spacing from session start ⇒ an every-frame train (R4.2 ⇒
   FP_FAR_SMOOTH is served after all); clustered bursts separated by quiet ⇒ transient-
   driven A/B above; event rate decaying as the session warms ⇒ trickle-driven (A/B).
2. **Next deploy** (telemetry-only, unconditional): a per-source arm counter — a small
   `_pending_src: Dictionary` bumped with a source tag at each of the ~13 arm sites,
   dumped as `sh_pending_src` per window. One int per site; definitive attribution
   forever (this class of bug has now mis-attributed twice — buy the sensor).

## R2.5 THE BUILDABLE FIX (REVISION 3, build-ready) — sink-side classified pending

**Green-lit 2026-08-13 with served-flag data: FP_FAR_SMOOTH NOT deployed (train ruled
out); FP_SMOOTH_V2 + FP_BLOCKY_FARRING deployed; FP_RELIEF_REEMIT / FP_SLOT_INDIRECT /
FP_RING_QUIESCE / FP_SMOOTH_V2_EXCL_BLKLOD not deployed.** Live trigger = A and/or B
(both transient-driven). One deliberate change from the green-lit sketch, flagged for
the implementer in R2.5.4: **ladder GROW is SAFETY-at-fixpoint, not LUXURY** — grow is
what removes the #113/#117 far-over-near grey, so coalescing it 10 s behind a credit
gate would ship a visible grey regression at spawn/after crossings. The excursion churn
is instead killed at the root by the net-zero debounce (R2.5.3), which also catches
multi-frame remeshes that a 2-read confirm would miss.

### R2.5.1 The arm-site choke point + the sensor (`sh_pending_src`)

One helper replaces every literal `_pending = true` in `facet_far_ring.gd`:

```gdscript
## FP_APPLIED_PROBE_CALM choke point. Every _pending arm routes here with a source tag.
## Flag off ⇒ exactly the shipped write (byte-identical behaviour); no counter, no state.
func _arm_pending(src: int, luxury := false) -> void:
    if not CubeSphere.FP_APPLIED_PROBE_CALM:
        _pending = true
        return
    _pending_src[src] += 1                       # the sensor — bumps on EVERY arm, both classes
    if luxury:
        _pending_luxury = true
        _calm_last_lux_arm_ms = Time.get_ticks_msec()   # settle clock
    else:
        _pending = true
```

`_pending_src` is a `PackedInt32Array` sized `SRC_COUNT` (allocated in `setup`,
~60 bytes), dumped in the stats dict (beside `sh_applied_r`, `:3145`) as
`sh_pending_src` (comma-joined ints, fixed order below). This is the definitive
attribution/verification telemetry the A/B reads — **in the SAME flag**, per the
build request; it has mis-attributed twice, the sensor is the insurance.

Source tags (enum consts in FacetFarRing, index = position in `sh_pending_src`):
`SRC_BOOT=0, SRC_CROSS=1, SRC_SMOOTH_CHG=2, SRC_SMOOTH_INC=3, SRC_CAM=4, SRC_POOL=5,
SRC_NB_BUILT=6, SRC_NB_UNCOVER=7, SRC_NB_RESINK=8, SRC_NB_NOTEMIT=9, SRC_UNSINK=10,
SRC_LADDER_SHRINK=11, SRC_LADDER_GROW=12, SRC_CULL_FLUSH=13, SRC_CULL_APPLY=14,
SRC_SLOTS=15, SRC_RELIEF=16, SRC_FORCE=17`.

### R2.5.2 The complete partition — every arm site, classified (implementer's table)

| site (file:line) | source tag | class | why |
|---|---|---|---|
| `:602` boot-warm completion | SRC_BOOT | **SAFETY** | one-shot; boot correctness |
| `:641` facet-crossing deferred re-emit | SRC_CROSS | **SAFETY** | emitted set changed with the active facet |
| `:739` `_smooth.consume_changed()` | SRC_SMOOTH_CHG | LUXURY | tile takeover ⇒ facet double-drawn until re-emit (overdraw, not a hole). Dead live (FP_FAR_SMOOTH off) |
| `:892` `_mesh_inc_gate` re-inclusion | SRC_SMOOTH_INC | **SAFETY** | make-before-break hole prevention. Dead live |
| `:1226` (`_shell_snapshot`) camera drift commit | SRC_CAM | **SAFETY** | emit axis/cap changed; already drift-throttled upstream |
| `:1295` `set_pool_excluded` (+ the `force_rebuild()` path above it, `:1291-93`) | SRC_POOL / SRC_FORCE | **SAFETY** | a retired neighbour must re-enter the shell promptly (hole); a spawned one must leave it (double-draw with real voxels) |
| `:1591` disjunct `built_now` (`:1579-82`) | SRC_NB_BUILT | **SAFETY** | never-black: fresh chord must draw now |
| `:1591` disjunct unsink flip → `fid` (uncover, `:1586-87`) | SRC_NB_UNCOVER | **SAFETY, net-zero debounced** (R2.5.3) | un-sink is the never-black guarantee; debounce only filters remesh transients |
| `:1591` disjunct unsink flip → `-1` (re-sink) | SRC_NB_RESINK | **SAFETY, net-zero debounced** | an un-sunk TRUE-surface backstop under arrived near z-fights at the surface — visual correctness, not luxury; paired with UNCOVER in the debounce |
| `:1591` disjunct `not _emitted.has(fid)` | SRC_NB_NOTEMIT | **SAFETY** | active facet not drawn = black-hole risk; quiet under the deployed set (R2.1) |
| `:1626` `_unsink_drift_check` | SRC_UNSINK | **SAFETY** | already ≥16-block drift-gated; rare |
| `:1734` ladder SHRINK (`:1728-29`) | SRC_LADDER_SHRINK | **SAFETY, net-zero debounced** | coverage claim broke ⇒ sunk cells may hide a hole; debounce filters transients only |
| `:1734` ladder GROW | SRC_LADDER_GROW | **SAFETY at FIXPOINT** (no arm per +16 step; ONE immediate arm when the climb terminates — next probe fails or `APPLIED_PROBE_MAX`) | grow REMOVES the #113/#117 far-over-near grey — visual correctness; per-climb single-arm is the whole coalescing win (≤7 arms → 1) |
| `:2702` cull FLUSH | SRC_CULL_FLUSH | **SAFETY** | committed-cell hole (shipped semantics). Dead live |
| `:2702` cull APPLY | SRC_CULL_APPLY | LUXURY | overdraw diet — the held c02eb30 admission law is SUBSUMED by the luxury coalescer (its source-side settle/deadband may stay as a pre-filter; harmless). Dead live |
| `:4371` band/close-up slot pushes | SRC_SLOTS | **SAFETY** | stale slot map samples the wrong facet's texture (visibly wrong). Proper diet = ship Q2 `FP_SLOT_INDIRECT` (separate recommendation) |
| `:5215` `_drain_relief_dirty` | SRC_RELIEF | LUXURY | DEM shade-multiply catch-up, cosmetic. Dead live (FP_RELIEF_REEMIT off) |

Implementation guard for the implementer: **anything not in this table (a future arm
site) defaults SAFETY** — mis-classifying toward SAFETY is always behaviour-preserving.

### R2.5.3 Net-zero debounce (replaces the 2-read CALM_FLIP_CONFIRM)

The three debounced arms (NB_UNCOVER, NB_RESINK, LADDER_SHRINK) are exactly the ones a
1-to-N-frame `is_area_meshed` remesh transient can fire spuriously. Read-count
confirmation (2 frames) misses slow web remeshes; instead, debounce by TIME with
net-zero cancellation:

* On a debounced arm: record `(src, state_before)` in a one-slot hold latch with
  deadline `now + CALM_NETZERO_HOLD_MS` (250 ms) — do NOT set `_pending` yet. The
  underlying state change itself is ALSO held (the ladder keeps `_applied_r`, noblack
  keeps `_noblack_unsink_fid`) — only the probe's verdict is remembered.
* Each frame while held, re-evaluate the same probe: if it REVERTS (re-proves the
  held radius / re-reads covered) before the deadline ⇒ **cancel** — no state change,
  no arm, zero rebuilds (a net-zero excursion is pixel-identical by construction:
  nothing was ever committed in between).
* If the deadline expires with the verdict still standing ⇒ apply the state change and
  arm SAFETY immediately (shipped behaviour, 250 ms late).
* **Why 250 ms is safe:** the arm feeds an async pipeline whose own build latency is
  1.5–2.1 s (§0) — the debounce adds ≤ 12–17 % to a safety re-emit's existing latency.
  A TRUE near retreat at rest requires an edit (edits fire their own re-arms), and
  while moving the ladder/noblack re-prove every frame anyway. `CULL_DILATE`-class
  margins (§2.3 reasoning) are unaffected — the cull is not deployed.

The ladder's climb behaviour under the flag: shrink held per above; on a confirmed
shrink, `_applied_r = 0` and the regrow climbs silently (+16/frame, NO arm per step);
at fixpoint, if the fixpoint radius == the pre-shrink radius AND the shrink arm was
cancelled (never fired) ⇒ nothing arms at all; otherwise ONE SRC_LADDER_GROW safety
arm. Result at rest: a remesh transient produces **zero** rebuilds (was up to 7+1).

### R2.5.4 The luxury coalescer (forward rail — nothing live rides it today)

At the ONE place `_process` consumes pending (immediately after `_applied_probe_step`,
`:1375`, before the regime branches):

```gdscript
if CubeSphere.FP_APPLIED_PROBE_CALM and _pending_luxury:
    var now := Time.get_ticks_msec()
    if _stream_credit_ok \
            and now - _calm_last_lux_arm_ms >= CubeSphere.CALM_SETTLE_MS \
            and now - _calm_last_lux_promote_ms >= CubeSphere.CALM_APPLY_MIN_MS:
        _pending_luxury = false
        _calm_last_lux_promote_ms = now
        _pending = true
```

Credit-gate (`_stream_credit_ok`, `:415`, fed by `world_manager.gd:1317-18`) + 2 s
settle + 10 s rate — the c02eb30 admission law relocated verbatim to the sink. Under
the DEPLOYED set every live arm is SAFETY-classed, so this rail idles; it exists so
SMOOTH_CHG / CULL_APPLY / RELIEF (and any future cosmetic source) are calm on arrival,
and so the fix needs no re-design when those flags ship. Be honest in review: the
live win comes from R2.5.3 + the per-climb single-arm, not from this rail.

### R2.5.5 Constants, byte-off, gates

```gdscript
const FP_APPLIED_PROBE_CALM := false   # sink-side pending classification + net-zero debounce + sensor
const CALM_NETZERO_HOLD_MS := 250      # transient-cancellation hold on the 3 debounced safety arms
const CALM_SETTLE_MS := 2000           # luxury rail: quiet time since last luxury arm
const CALM_APPLY_MIN_MS := 10000       # luxury rail: min interval between luxury-promoted rebuilds
```

Byte-off: `_arm_pending`'s first line short-circuits to the shipped `_pending = true`
(no counter, no latch, no debounce — G-APC-7 parity asserts arm-for-arm identical
behaviour with the flag off); `_pending_src`/latches allocated only under the flag.
gl_compat untouched; NEVER-OOM: +~60 B counters + 1 hold latch.

Gates (verify_probe_calm.gd; the arm sites are drivable via the existing gate-forcing
`on :=` param convention):
- **G-APC-1 coalesce**: scripted luxury-arm trickle ⇒ ≤1 promotion per settle+rate
  window (was 1:1). **G-APC-2 safety-immediate**: EVERY SAFETY row of the R2.5.2 table
  arms `_pending` the same frame (drive each tag once, assert same-frame).
- **G-APC-3 credit gate**: `_stream_credit_ok=false` ⇒ luxury never promotes; safety
  unaffected. **G-APC-4 default-safety**: an unknown tag arms SAFETY.
- **G-APC-5 ladder**: climb 0→112 ⇒ exactly one SRC_LADDER_GROW arm at fixpoint,
  same-frame promoted (no grey window beyond climb+build).
- **G-APC-6 net-zero**: scripted 1-frame and 5-frame probe transients (shrink and
  noblack, both directions) ⇒ 0 arms, 0 state change; a persistent flip ⇒ state + arm
  at ≤ CALM_NETZERO_HOLD_MS. **G-APC-7 flag-off parity**: shipped arm behaviour verbatim
  + export compare. **G-APC-8 sensor**: each scripted arm bumps exactly its tag;
  `sh_pending_src` order matches the enum.

Live A/B: pass bar unchanged — farring events 182 → <10/session, worst_ms unimodal,
credit p50 > 0, fps toward ~38-42 — PLUS `sh_pending_src` names the dominant live
source (settles A-vs-B for the record) and confirms the debounce caught it
(SRC_LADDER_SHRINK/NB_UNCOVER counters low at rest). Regression eyeballs: #113
grass-base + #117 mesa spots (no grey), spawn + one crossing (grey clears at the
shipped cadence — grow is same-frame at fixpoint), chop a tree (edit re-arms).

**Honest status:** trigger narrowed to A/B (train ruled out by the served-flag data);
the fix is source-agnostic, kills the transient class at the root, and carries its own
attribution sensor so a third mis-pin is structurally impossible.
