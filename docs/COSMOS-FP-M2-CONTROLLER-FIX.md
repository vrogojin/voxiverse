# COSMOS-FP-M2-CONTROLLER-FIX — un-starving the StreamLoadController (credit pinned at 0, M2 inert in production)

Status: **implemented + headless-gate-validated** (2026-07-15, task #115, branch
`fix/voxiverse-crossing-hitches`). All three prongs (P1 sensor, P2 p90 statistic, P3
relief floor + geometric commit) shipped across the 6 files in §6.2/§6.3; the new
regression gate **G-M2-STARVE(a–f)** plus the amended G-M2-CTRL(a) / G-M2-POLICY(W1)
pass with FACETED+FP_M1_POOL+FP_M2_LOD on (127/0), and the flag-off FLAT `verify_feature`
byte-identity holds (6027/0). Live/web acceptance (§6.4) remains manual and pending —
headless cannot reproduce the web `TIME_PROCESS` pathology.
This document EXTENDS `docs/COSMOS-FP-M2-DESIGN.md`: it amends §6.5 (the admission
controller), overturns §14.10(a) (starvation as accepted risk), and supersedes ledger
row 7's implicit assumption that one AIMD credit may gate all four admission surfaces.
Evidence base: the live real-GPU border-walk session of 2026-07-15
(`tools/remote-bridge/results/telemetry.jsonl`, 482 samples / 437 s / 8 facet crossings).

---

## 1. Confirmed root cause

The tasking hypothesis ("perpetual near-field overload pins the AIMD credit at 0, which
closes every admission surface, including the W1 imminent exemption") is **confirmed in
its mechanics and corrected in its causality**. There are two independent causes, either
of which alone pins credit at 0; both are live.

### 1.1 Layer 1 — the sensor is invalid on the threaded web export (the dominant cause)

`StreamLoadController.LiveSource.poll()` reads
`Performance.TIME_PROCESS + TIME_PHYSICS_PROCESS`
(`godot/src/world/stream_load_controller.gd:180-181`) as "the main-thread frame cost".
On the threaded web export this reading is **physically impossible as a frame cost**:

- Across all 482 telemetry samples, `proc_ms + phys_ms` **never** went below **18.4 ms**
  (median 136, p25 103). The AIMD setpoint is `CTRL_FRAME_BUDGET_MS := 18.0`
  (`cube_sphere.gd:122`) — the headroom branch (`stream_load_controller.gd:90-91`) was
  therefore **unreachable for the entire session**, by ≥ 0.4 ms even at its best sample.
- In the 22 samples where the game was demonstrably idle-healthy (fps ≥ 59, `vox_gen` = 0,
  stationary), `proc_ms` **median was 77 ms**. A main thread cannot spend 77 ms per frame
  at 60 fps (16.7 ms frame period). On the web export, `TIME_PROCESS` evidently includes
  time that is not main-thread work (main-loop iteration time including the browser
  present/rAF wait under the emscripten threaded loop), i.e. it does not measure what
  §6.5.1 assumed.
- Consequence: `_overload` (`stream_load_controller.gd:85`) is true on **every** control
  tick from boot. Credit multiplicatively halves and zero-snaps within 4 ticks (≤ 1 s of
  boot, `:86-89`) and can never rise again — `stream_credit = 0` in **all** 482 samples,
  including long stationary stretches. The controller was dead before the player took a
  step. This is not "load pins the credit"; **the sensor pins the credit regardless of
  load.**

Note the implementation divergence: design §6.5.1 specified `frame_worst` as the "worst
**actual frame delta**" (the PerfHUD's `worst`, which the telemetry shows behaving sanely:
16.7 ms at healthy 60 fps). The implementation instead fed the window with `TIME_PROCESS`
samples. The telemetry's `worst_ms` (true frame deltas, from `min_fps`) is exactly the
signal the design asked for — and it is measurable correctly on web.

### 1.2 Layer 2 — even a correct sensor cannot recover credit in a browser while it matters

With the sensor corrected to true frame deltas, the statistic is still
max-over-30-frames vs an 18 ms setpoint, EMA'd, and recovery to a fireable promote needs
`credit ≥ 0.5` (five consecutive headroom ticks from 0, 1.25 s) **plus**
`CTRL_PROMOTE_SUSTAIN_S = 1.5 s` of sustain ≈ **2.75 s of continuously hitch-free
30-frame windows**. The telemetry says this never happens outside a lab:

- `worst_ms ≤ 18` occurs in only 22/482 samples and **never twice in a row** — even
  stationary, a browser drops a frame every few hundred ms (GC, compositor). One 33 ms
  frame per half-second holds a max-of-30-frames statistic above 18 forever.
- While walking, real frame worsts sit at 33–50 ms (fps ~30) — including in samples where
  `vox_gen` = 0. So during every ridge approach — precisely when the imminent promote must
  fire — credit is legitimately 0 even with a perfect sensor.

### 1.3 The starved code paths (exact, with the W1 reading verified)

One pinned scalar closes all four surfaces:

| Surface | Code | At credit 0 |
|---|---|---|
| 1 — LOD apply budget | `stream_load_controller.gd:122-123` → `facet_lod_mesher.gd:481-493` | `apply_ms = 0` — built meshes never apply |
| 2 — build grants | `:126-127` → `facet_lod_mesher.gd:324-328` (`grants <= 0 → return`) | budgeter never enqueues → **zero LOD facets ever built** (telemetry: `lod.facets`/`tris`/`bytes` peak 0, `builder_queued` peak 0) |
| 3 — pool ramp pace | `:131-132` → `world_manager.gd:232-234` → `module_world.gd:416` | pace 0 (also backlog-held) |
| 4 — promotes | `:137-146` → `world_manager.gd:1571,1644-1656` | never admitted |

The W1 "imminent" exemption reading is **confirmed**: `promote_imminent_admitted()`
(`stream_load_controller.gd:145-146`) is exempt from `backlog_gated()` but still requires
`_headroom_hold_s ≥ 1.5` — and `_headroom_hold_s` accrues **only while
`_credit ≥ CTRL_PROMOTE_CREDIT`** (`:100-103`). Credit pinned at 0 ⇒ the hold is reset
every tick ⇒ the exemption can never fire. The escape hatch was built downstream of the
very signal it needed to escape.

### 1.4 Causality correction (what starvation actually costs)

The tasking's loop — "no LOD promotion → no generation relief → near-field gen keeps
saturating the frame" — is **not** what the telemetry shows, and the distinction matters
for what this fix can honestly promise:

- The steady-state ~30 fps while walking is **not** gen-admission-driven: immediately
  before the 2→3 crossing, `vox_gen` was **0** and worst frames were still 33–45 ms.
  That main-thread cost lives elsewhere (task #114, GroundCollider broadphase, is the
  live suspect) and no amount of LOD promotion removes it.
- What the starvation *does* cost, visible in all 8 crossings: `facet_neighbours` was 0
  at every ridge approach (the occasional 1 is the *departed* facet after a crossing, not
  a pre-warm), so **every crossing rode the pool-miss spawn-at-cross ladder** —
  `vox_gen` jumps 0 → 700–1300 at the crossing sample and worst_ms pins at the 50 ms
  telemetry cap for the following ~10-20 s. Plus: zero LOD covers ever (neighbours render
  as flat far-ring quads), and the entire M2 investment inert.
- Therefore the honest success criteria for THIS fix are: **pre-warmed crossings
  (pool-miss = 0, `facet_neighbours = 1` before the cross), LOD residency > 0, credit > 0
  when stationary, crossing-window worst-frame improved.** Restoring 60 fps *while
  walking mid-facet* is explicitly NOT this fix's claim — that is #114.

### 1.5 §14.10(a) is overturned

The design accepted chronic-overload starvation as "honest: that machine could not have
afforded the live neighbour anyway". Both halves of that sentence are now falsified:
(i) the sensor makes *every* web machine read as chronically overloaded, including idle
ones; (ii) the economics are wrong — the imminent neighbour's generation cost is **not
optional**. It is paid either way; starving the promote only moves the payment to the
worst possible moment (synchronously, at the seam, player standing on it) and the
worst possible shape (a burst instead of a paced ramp). Deferral of unavoidable work is
a scheduling choice, not a saving — an admission controller may *pace* it, never *veto* it.

---

## 2. The chosen mechanism — three prongs

Three independent, individually-small changes. P1/P2 make the credit *able* to recover
when the machine is genuinely healthy; P3 makes the relief path *not need* the credit at
all. P3 is the structural fix; P1/P2 without P3 would still starve every approach
(§1.2), and P3 without P1/P2 would leave `demote_pressure()` permanently latched (a
broken sensor reads overload even at idle → continuous coarsening churn). All three ship
together.

### P1 — fix the sensor (implement §6.5.1 as designed)

`LiveSource.poll()` returns the **measured wall delta between successive polls** (it is
polled once per frame from `WorldManager._process`, `world_manager.gd:227-228`), via
`Time.get_ticks_usec()` kept inside `LiveSource`; the first poll returns 0.0 (neutral).
Each sample is clamped to a new const `CTRL_FRAME_SAMPLE_CLAMP_MS := 250.0` so a
backgrounded tab cannot poison the window with a multi-second sample (the giant-tick
discontinuity guard, W2, already resets the sustains; the clamp bounds the window
contribution). `TIME_PROCESS` is no longer read. Wall-clock use stays confined to
`LiveSource`, which no gate ever constructs — determinism (§6.5.7) intact.

### P2 — re-scale the statistic: window max → window p90

The binding statistic becomes the **90th-percentile** frame delta over the
`CTRL_WINDOW_FRAMES = 30` window (new const `CTRL_WINDOW_PCTL := 0.9`; deterministic:
sort the filled window, index `ceil(0.9·fill)−1`), then EMA as today. Rationale: with a
*max* statistic, one dropped frame per half-second — browser-normal even at idle — holds
overload forever (§1.2); p90 tolerates ≤ 3 stutter frames per window while still
reading sustained 30 fps (all deltas 33 ms → p90 = 33 > 18) as overload. The setpoint
stays `CTRL_FRAME_BUDGET_MS = 18.0`: healthy vsync'd 60 fps reads p90 ≈ 16.7 ≤ 18 ✓.
**Gate-compatibility for free:** every G-M2-CTRL gate drives a constant square-wave
source, and for a constant window p90 ≡ max — the existing credit traces are
bit-identical.

### P3 — the relief floor + geometric commit (decouple relief from the overload credit)

The four surfaces are re-classified by what they admit:

- **Feedback-gated (unchanged):** surface 3 (pool ramp pace, generic) and surface 4's
  corner/2nd promote — these admit *extra, optional* generation volume; gating them on
  overload + backlog is correct feedback.
- **Relief (floored / geometric):** LOD builds+applies and the *imminent* promote —
  these either relieve or merely reschedule unavoidable cost, and must flow even at
  credit 0, bounded.

Concretely, with one new credit floor `CTRL_RELIEF_FLOOR := 0.25` and one new policy
radius `POOL_D_COMMIT := 64.0`:

**P3a — floor surfaces 1–2.** In `stream_load_controller.gd`:
`apply_budget_ms(base) = base × max(_credit, CTRL_RELIEF_FLOOR)` (floor: 0.5 ms/frame)
and `grant_count(base) = ceil(base × max(_credit, CTRL_RELIEF_FLOOR))` (floor: 1 grant/
tick). New accessor `relief_only() -> bool := _credit < CTRL_RELIEF_FLOOR`. While
`relief_only()`, the mesher's budgeter (`facet_lod_mesher.gd:_run_budgeter`) restricts
its candidate set to **(i) facets with no mesh at all** (`cur < 1` — the ≥ ℓ3 instant
first cover; the far-ring-quad→LOD upgrade that never happened live) **and (ii) the
imminent-ridge facet** (any tier toward target). SSE refinement of already-covered
facets remains credit-gated — the floor buys *coverage*, not luxury.

**P3b — geometric commit for the imminent promote.** §3.2's Z1-hybrid contract says the
imminent neighbour (nearest ridge `< POOL_D_WARM = 96`) *is* a live terrain; the
controller was only ever meant to pace *when* it starts (§3.5), but as built it holds an
unbounded veto. Restore the contract with a bounded deferral window:

```gdscript
static func promote_admit_imminent(ctrl, ridge_dist: float) -> bool:
    if ctrl == null: return true                                   # flag-off / FP-M1c
    return bool(ctrl.promote_imminent_admitted()) \                # polite path (headroom)
        or ridge_dist < CubeSphere.POOL_D_COMMIT                   # committed path (geometric)
```

Between 96 and 64 blocks the controller may politely defer the spawn to a headroom
window (frequently available under P1/P2 when the player pauses); inside 64 blocks the
spawn is admitted unconditionally — the crossing is committed, the cost is no longer
optional, and pre-paying it now (≈ 6.7 s of lead even at run speed 9.5 b/s; 11.6 s at
walk 5.5) strictly dominates paying it at the seam. The 96→64 politeness window and the
64 commit radius are the two dials (`POOL_D_COMMIT → POOL_D_WARM` disables politeness;
`→ 0` restores today's behaviour minus the sensor fix).

**P3c — imminent ramp-pace floor.** A committed spawn must also *stream*: surface 3 held
at 0 would leave the promoted terrain at `RAMP_START_BLOCKS = 48` forever. WorldManager
tells the module the imminent fid each pool pass (`set_imminent_fid(fid)`, −1 when
none); `module_world._ramp_pool_step` (`module_world.gd:416`) paces **that slot only** at
`maxf(_stream_pace, CTRL_RELIEF_FLOOR)`. Worst case the ramp takes
`RAMP_SECONDS / 0.25 = 6 s` — inside the commit lead time. All other slots keep the
fully-gated pace (backlog gate intact for optional volume).

**P3d — demote disjointness.** `facet_lod_mesher.demote_pressure_relief()` additionally
skips the imminent fid (it already skips promote-held facets and facets at
`LOD_MAX_TIER`, `facet_lod_mesher.gd:202-206`).

### Why this beats the alternative levers

- **Lever 2 (throttle the near-field firehose so credit recovers)** — rejected on
  evidence: the walking-frame saturation persists at `vox_gen = 0` (§1.4), so throttling
  gen admission would not recover credit; it *would* slow ground-under-player stream-in,
  which outranks neighbour pre-warm. And it leaves relief hostage to a signal (credit)
  that a browser cannot keep high anyway (§1.2).
- **Lever 3 in its pure form (measure LOD-specific headroom as a second closed loop)** —
  rejected: it needs a second trustworthy sensor on a platform where the first one just
  failed silently, and a second feedback loop whose stability against the first must be
  proven. The floor achieves the same admission with a *constant* — trivially stable,
  trivially deterministic. (P2 *is* the defensible part of lever 3: measuring the right
  statistic of the right signal.)
- **Lever 4 in its pure form (force-admit at the crossing)** — subsumed and improved:
  admitting at `D_COMMIT = 64` is the same feed-forward decision taken ~7–12 s earlier,
  which is the entire difference between a paced ramp and a spawn-at-cross burst.
- **Floor-everything (drop `relief_only()`'s candidate restriction)** — rejected: under
  genuine sustained overload, unrestricted SSE refinement at floored grants would fight
  `demote_pressure()`'s coarsening (§3, hunting) and spend builder time sharpening
  scenery mid-struggle. The restriction is what makes the floor provably terminal.

---

## 3. No-re-deadlock / no-oscillation argument

**The floored path cannot deadlock, because it is open-loop.** Deadlock in the shipped
design is a feedback cycle: relief admission ← credit ← load ← (absence of) relief. The
floor and the geometric commit read **no load signal at all** — `max(credit, 0.25)` and
`dist < 64` are decidable regardless of any measurement, so no measurement state can
close them. There is no cycle to re-form.

**The floored path is bounded per frame and terminal in total.**
Per frame: apply ≤ 0.5 ms (hard time-boxed, `facet_lod_mesher.gd:489-493`); ≤ 1 grant
enqueue per tick, still under `LOD_QUEUE_MAX_JOBS = 16` and the 30 s est-seconds bound
(`:322, :345`); ≤ 1 promote per `POOL_SPAWN_INTERVAL_S = 1 s` under `FP2_LIVE_CAP = 2`;
one ramp slot per frame (the FP-M1c serializer, `module_world.gd:388-419`) at ≤ 0.25×
pace. Total: the relief candidate set is monotone-shrinking — a meshless facet that
receives its ℓ3 cover leaves the set and (in relief mode) is never refined further, the
imminent facet is one fid, and once every visible facet is covered the budgeter finds no
candidates and the floor costs zero. Worst-case main-thread add is ~1 ms/frame — which
also bounds sensor self-pollution: floored work cannot push a healthy 16.7 ms p90 over
the 18 ms setpoint, so the floor cannot hold credit down (§14.10(b)'s convergence
argument now applies to a constant instead of a shrinking fraction — stronger).

**Build↔demote hunting is excluded by set-disjointness, in both set and time.**
`demote_pressure_relief` victims must *have* a mesh, not be promote-held, not be the
imminent fid (P3d), and not already be at `LOD_MAX_TIER` — so a victim always retains a
mesh one tier coarser. Relief grants target only *meshless* facets + the imminent fid.
A demoted facet therefore never re-enters the relief set; the only path back to a finer
tier is normal SSE refinement, which requires `credit ≥ CTRL_RELIEF_FLOOR` — and
`demote_pressure()` requires sustained `credit = 0` (`stream_load_controller.gd:110-113,
157-158`). The states "demoting" and "re-refining" are mutually exclusive by credit
value. No facet can oscillate.

**Promote↔retire thrash is excluded by the existing hysteresis, now actually exercised.**
A granted promote is never yanked (§6.5.4, unchanged); retirement stays purely geometric
at `POOL_D_RETIRE = 128` with `POOL_MIN_LIVE_S = 10` — a 64-block-wide hysteresis band
around the commit radius. The imminent *selection* keeps `POOL_SWITCH_MARGIN = 16`
incumbent hysteresis (`world_manager.gd:1621-1631`), so `set_imminent_fid` churn at a
corner is already damped; a stale imminent exemption in P3c/P3d is one facet, harmless.

**Credit can now genuinely recover (P1+P2)** — stationary/healthy p90 ≈ 16.7 ≤ 18 →
+0.1/tick → full credit in 2.5 s, promotes via the polite path in ≈ 2.75 s of standing
still — and, decisively, the system **no longer needs it to**: at permanent credit 0 the
game still converges to full LOD coverage + a pre-warmed imminent neighbour, with credit
modulating only refinement luxury and optional pool volume. The failure mode of the
remaining feedback loop is bounded degradation, never inertness.

---

## 4. NEVER-OOM proof

No cap check moves, weakens, or gains a bypass. Every unblocked admission lands in the
same allocation funnels, and the caps are evaluated **after** the admission decision,
independently (§6.5.6 verbatim):

- **Floored LOD grants** enter via `request()` → `_admit()` (`facet_lod_mesher.gd:374-460`)
  — the identical caps/LRU path as full-credit grants: `LOD_MAX_FACETS = 64`,
  `LOD_MAX_TRIS = 3.0 M`, `LOD_MAX_BYTES = 96 MB` ledgers, eviction-funded, degrade-then-
  deny-to-quad. A floor grant denied by the ledger dies exactly as a credit-1 grant does.
  G-M2-CTRL(e) (caps bind at credit 1) already asserts the stronger case — the floor
  admits a strict subset of what credit 1 admits.
- **The geometric-commit promote** enters via the unchanged `pool_spawn` path behind the
  `FP2_LIVE_CAP` check (`world_manager.gd:1569`) and the `POOL_MAX_NEIGHBOURS = 4` hard
  backstop (G-M1-POOL). It can never add more live volume than the shipped FP-M1c policy
  admitted unconditionally.
- **The imminent ramp floor** only paces toward the slot's *existing* `view_target` — it
  changes when volume arrives, never how much.
- Relief mode introduces **no new allocation site**; `relief_only()` and
  `promote_admit_imminent` are pure predicates.

Memory ceilings and lifetime caps are bit-identical to shipped FP-M2. Memory safety
outranks smoothness, unchanged.

---

## 5. Determinism, flag-off byte-identity, far/near consistency

- **Determinism of the headless gates:** all new constants are fixed;
  `relief_only()` is a pure function of `_credit`; the commit test is a pure function of
  a caller-supplied distance; p90 is a deterministic order statistic of the injected
  window. Wall-clock stays confined to `LiveSource`, which gates never construct
  (`verify_fp_m2.gd` injects `_SquareWaveSource`). Constant synthetic signals make
  p90 ≡ max, so existing credit traces are bit-identical; the two gate assertions that
  intentionally change are listed in §6.3.
- **Flag-off byte-identity:** the controller is only created under `FP_M2_LOD`
  (`world_manager.gd:270-272`); with it OFF, `_load_ctrl == null` ⇒ mesher/module read
  shipped defaults, `promote_admit_imminent(null, d)` returns true unchanged,
  `set_imminent_fid` is never called, and the new consts are dead data. FLAT
  `verify_feature` stays structural 6027/0.
- **Far/near consistency:** nothing here changes *what* an LOD build generates — only
  *when* builds/promotes are admitted. Floored builds use the same generator/probe path
  and the same rebuild triggers, so the water-where-sand class of divergence cannot be
  reintroduced. The one visual delta: under sustained load neighbours now hold at ℓ3
  first-covers (instead of quads) until headroom refines them — strictly closer to the
  live terrain than the quad was.

---

## 6. Implementation plan (for Opus)

All changes live inside FP_M2_LOD-gated code or the controller class. No engine (C++)
changes. Order matters only for §6.3 (gates last).

### 6.1 Constants — `godot/src/cosmos/cube_sphere.gd`

Beside the CTRL_/POOL_ families:

```gdscript
const CTRL_RELIEF_FLOOR := 0.25          # §P3a: min credit-equivalent for relief surfaces 1-2 (+ imminent ramp)
const CTRL_FRAME_SAMPLE_CLAMP_MS := 250.0 # §P1: per-sample clamp on the measured frame delta
const CTRL_WINDOW_PCTL := 0.9            # §P2: order statistic over the frame window (was: max)
const POOL_D_COMMIT := 64.0              # §P3b: inside this ridge distance the imminent promote is geometric
```

### 6.2 Code changes

**`stream_load_controller.gd`**
1. `LiveSource`: add `_last_usec := -1`; `poll()` computes `frame_ms` as the clamped
   usec delta between calls (first call → 0.0), drops the `TIME_PROCESS`/
   `TIME_PHYSICS_PROCESS` reads. Keep the `VoxelEngine` backlog read.
2. `tick()`: replace the window-max loop (`:80-82`) with the p90 order statistic over
   the `_win_fill` filled samples (copy, sort, index `ceil(CTRL_WINDOW_PCTL·fill)−1`).
   Keep the variable/stats key `frame_worst_ema` (re-document as "EMA of the window p90").
3. `apply_budget_ms` / `grant_count`: scale by `maxf(_credit, CubeSphere.CTRL_RELIEF_FLOOR)`.
4. Add `relief_only() -> bool: return _credit < CubeSphere.CTRL_RELIEF_FLOOR`; add
   `"relief_only"` to `stats()`.
   Surfaces 3–4 accessors are **unchanged**.

**`world_manager.gd`**
5. `promote_admit_imminent(ctrl)` → `promote_admit_imminent(ctrl, ridge_dist: float)`
   per §P3b (stays static/pure for G-M2-POLICY).
6. `_manage_pool_z1hybrid`: at `:1571` pass `float(want[t])` for `idx == 0`; after
   computing `targets`, forward `set_imminent_fid(targets[0] if targets.size() > 0 else -1)`
   to `_module_world` (guard `has_method`).

**`module_world.gd`**
7. Add `var _imminent_fid := -1` + `set_imminent_fid(fid)` (forwards to `_lod_mesher`
   like `set_load_controller`, `:1517-1520`).
8. `_ramp_pool_step` `:416`: `var pace := _stream_pace; if up_fid == _imminent_fid:
   pace = maxf(pace, CubeSphere.CTRL_RELIEF_FLOOR)` — use `pace` in the grow expression.

**`facet_lod_mesher.gd`**
9. Add `var _imminent_fid := -1` + `set_imminent_fid(fid)`.
10. `_run_budgeter`: after computing `grants`, `var relief := _controller != null and
    bool(_controller.call("relief_only"))`; in the candidate loop, when `relief`, `continue`
    unless (`cur < 1` or `fid == _imminent_fid`).
11. `demote_pressure_relief`: also `continue` on `fid == _imminent_fid`.

### 6.3 Verify gates — `godot/src/tools/verify_fp_m2.gd`

**Amend (behaviour intentionally changed):**
- `:682` G-M2-CTRL(a) "at credit 0 all admissions stop" becomes: at credit 0,
  `grant_count(2) == 1`, `apply_budget_ms(2.0) == 0.5`, `stream_pace() == 0.0`,
  `relief_only() == true` — surfaces 1–2 floor, surface 3 still closes.
- `:809/:811` G-M2-POLICY(W1): pass an out-of-commit distance
  (`CubeSphere.POOL_D_COMMIT + 32.0`) so these keep asserting the *headroom* path.

**Add G-M2-STARVE — the regression gate that would have caught this bug** (fixed-step
injected clock + `_SquareWaveSource` throughout; no wall clock in any decision):

- (a) **Reproduce the starved state:** drive `frame_ms = 45, backlog = 900` for ≥ 12
  ticks → assert `credit() == 0.0`, `backlog_gated()`, `promote_admitted() == false`,
  `promote_imminent_admitted() == false` (the shipped deadlock, now pinned as the
  precondition).
- (b) **The relief floor is not pinned at 0:** under (a), assert `grant_count(2) == 1`,
  `apply_budget_ms(2.0) == 0.5`, `relief_only()` — i.e. *under sustained overload the
  build/apply admission surfaces are still open at the floor*. (This single assert fails
  on the shipped code — the minimal catcher.)
- (c) **The imminent ridge still promotes:** under (a),
  `WM.promote_admit_imminent(ctrl, CubeSphere.POOL_D_COMMIT - 1.0) == true` and
  `... + 32.0) == false` and `WM.promote_admit(ctrl) == false` — geometric commit fires
  at credit 0; the politeness window and the corner/2nd feed-forward throttle hold.
- (d) **End-to-end residency under starvation:** wire the starved controller into a real
  mesher (`set_load_controller`), seed a want for an uncovered facet (the direct-request
  pattern used by the build gates), tick N times → assert `stats()["facets"] ≥ 1` (an ℓ3
  first cover materialized). Live telemetry showed residency pinned at 0 for 437 s —
  this asserts it cannot happen again.
- (e) **Disjointness / no hunting:** in relief mode with a covered non-imminent facet
  wanting a finer tier, assert the budgeter does NOT grant it; after
  `demote_pressure_relief()` coarsens a victim, assert the victim still has a mesh and
  is not re-granted while `relief_only()` holds; assert the imminent fid is never chosen
  as the demote victim.
- (f) **P2 trace identity:** re-run the G-M2-CTRL(a/b) square-wave credit trace and
  assert the tick-by-tick credit values equal the pre-change constants (p90 ≡ max under
  a constant signal).

Run: `docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script
res://src/tools/verify_fp_m2.gd` (with FACETED/FP_M2_LOD sed-toggled ON, as today), plus
the FLAT `verify_feature` 6027/0 byte-identity run with both flags OFF.

### 6.4 Live acceptance (remote-bridge telemetry, same border-walk protocol as the baseline)

Against `tools/remote-bridge/results/telemetry.jsonl` (2026-07-15) as baseline:
1. `stream_credit` reaches ≥ 0.5 within 5 s of standing still (P1/P2 sensor proof —
   headless cannot test the web `TIME_PROCESS` pathology).
2. `lod.facets > 0` sustained during the walk; `builder_queued` > 0 observed at least once.
3. `facet_neighbours == 1` *before* each crossing sample; `pool_miss_count() == 0`
   across ≥ 5 crossings.
4. Crossing-window (±10 s) `worst_ms` p99 strictly improved vs the baseline's
   pinned-50 ms windows.
5. NEVER-OOM: `lod.bytes ≤ 96 MB`, `vmem` stable — unchanged ceilings.

### 6.5 Documentation

- This file (source of truth for the fix).
- `COSMOS-FP-M2-DESIGN.md`: pointer lines at §6.5 and §14.10 + ledger row (done in this
  commit); after implementation, update §6.5.3's surface table in place.

---

## 7. Decisions ledger (delta)

| # | Decision | Status |
|---|---|---|
| 1 | `LiveSource` reads `TIME_PROCESS + TIME_PHYSICS_PROCESS` as the frame cost (§6.5.1 impl) | **Overturned** — invalid on threaded web (never < 18.4 ms in 482 samples, 77 ms median at idle-60 fps); replaced by measured inter-poll frame delta, clamped |
| 2 | Overload statistic = max over 30-frame window | **Superseded** — window p90 (`CTRL_WINDOW_PCTL`); max makes browser-normal isolated stutter indistinguishable from sustained overload |
| 3 | One AIMD credit gates all four admission surfaces | **Amended** — surfaces 1–2 floored at `CTRL_RELIEF_FLOOR` with a relief-only candidate restriction; surfaces 3–4 stay feedback-gated except the imminent slot |
| 4 | The imminent promote requires sustained credit ≥ 0.5 (W1 exemption exempts backlog only) | **Amended** — geometric commit inside `POOL_D_COMMIT`: the controller defers the §3.2 imminent-live invariant within [D_COMMIT, D_WARM], never vetoes it |
| 5 | §14.10(a): chronic-overload starvation accepted as honest degradation | **Overturned** — §1.5: the deferred cost is unavoidable and lands at the seam instead; degraded-but-inert is not honest degradation |
