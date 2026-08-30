# COSMOS FALL C-lite — the freeze-independent de-orbit descent gate

Status: DESIGN (no code changed by this doc). Supersedes the *arming* of
docs/COSMOS-FALL-MESH-STALL-DESIGN.md §3.1/§3.2 (PR #80, merged default-OFF).
Target branch: a sub-branch of `feat/voxiverse-bootstrap`; flags default OFF,
byte-identical off, FLAT `verify_feature.gd` MUST stay 6042/0.

---

## 0. Executive summary

The de-orbit atmosphere-entry stall (2–3 fps for ~20 s; a measured 959 ms single
frame at alt ~256) is the S1 approach-anchor view re-growth flooding godot_voxel
with a 6–7k GenerateBlock disc. PR #80 built the right law (backlog-gated,
step-clamped view growth) but armed it on `falling_fast = _fall_vy_ema <
-ENV_FALL_HOLD_VY`, and **that signal is provably frozen across the whole flood
band** (§1). C-lite:

1. Replaces the arming with a **freeze-independent descent latch** computed from
   the *analytic radial altitude* `h` that `_apply_approach_anchor` already
   computes every debounced write — no velocity EMA, no speed clamp, no regime
   dependence (§2).
2. Restructures `reentry_admit_view` so that (a) growth is **always**
   step-clamped under the flag (kills the landing-cliff flood), and (b) the
   backlog-block applies **only while descent-armed AND above alt 128** — above
   the 112-block max terrain height, so a grounded player can *structurally*
   never be backlog-wedged (§3).
3. **Reuses** `FP_REENTRY_BACKLOG_GATE` / `FP_REENTRY_REGROW_DEFER` (both
   default-OFF, never shipped ON) rather than adding a third flag; adds
   `REENTRY_GATE_REV := 2` for pck-dump self-description (§4).

Expected bound: vox_gen peak ≈ 256 (cap) + ~790 (largest admitted annulus)
≈ **~1050 concurrent**, vs ~5900 baseline (§6).

---

## 1. Why attempt #2 was non-functional — the verified freeze mechanism

Both PR #80 gate sites key on `falling_fast`:

- `godot/src/world/world_manager.gd:834` —
  `view_f = CubeSphere.reentry_hold_view(view_f, h, _fall_vy_ema < -CubeSphere.ENV_FALL_HOLD_VY)`
- `godot/src/world/world_manager.gd:847` —
  `if CubeSphere.FP_REENTRY_BACKLOG_GATE and _fall_vy_ema < -CubeSphere.ENV_FALL_HOLD_VY:`

`_fall_vy_ema` is updated in ONE place, `world_manager.gd:1337-1345`
(`update_streaming`, per physics tick):

```gdscript
var spd := player_pos.distance_to(_last_player_pos) / dtf
if spd < CubeSphere.VEL_PREDICT_SPEED_CLAMP:      # 40.0 b/s (cube_sphere.gd:2583)
    _fall_vy_ema = lerpf(_fall_vy_ema, (player_pos.y - _last_player_pos.y) / dtf, 0.3)
```

The sample is **rejected whenever the per-tick total 3-D speed ≥ 40 b/s** (the
clamp exists to reject crossing/flip discontinuities). A de-orbit trajectory is
*never* below 40 b/s between orbit-establish and the drag-braked terminal phase:
v_circ ≈ 569 b/s tangential, radial descent 100–500 b/s through the whole
alt ~900→ATMO_TOP band. So from the burn to deep inside the atmosphere **every
EMA sample is rejected and `_fall_vy_ema` holds its last sub-40 b/s value** —
the pre-burn hover/coast ≈ 0 — and `falling_fast` is false exactly where the
view re-grows and the flood fires. It catches up only once drag (SN-BRAKE
terminal ≈ 20 b/s) slows the fall below 40 b/s — after the flood. (Note this is
the code-verified mechanism; it is *correlated* with the FP_ALT_REGIME orbital
regime because orbital speeds ≫ 40, but the freeze is the speed clamp itself,
so no regime-aware fix of the EMA can work — even below ATMO_TOP, a >40 b/s
plunge freezes it. Second latent flaw: at exactly terminal speed the EMA
converges to −20 asymptotically and `< -20.0` may never trip.)

This exactly explains the live A/B: 1 of 4 fix-ON runs bound the flood (a run
whose descent happened to dip under 40 b/s early enough to latch the EMA
negative — a timing fluke), the other 3 flooded 5727–7531 ≥ baseline.

**Conclusion: any correct arming must not touch `_fall_vy_ema` or any
speed-clamped velocity estimate.**

### 1.1 Rejected candidate signals (verified in code)

- `_facet_ring.shell_offsurface()` (`facet_far_ring.gd:3523`) =
  `_cam_set and not _emit_floored_last` — depends on the far-ring camera-set
  driver and the *last emit's* floored state; emits are event-driven, so it is
  stale between emits, false in headless/no-cam contexts, and flips off near
  OFFSURFACE_Y (256) — i.e. it would disarm right where the 959 ms stall was
  measured. Not a descent signal.
- `_offsurface` (`facet_far_ring.gd:1217`, `h > OFFSURFACE_Y=256`) — same
  disarm-at-256 problem, and it is true while *hovering/ascending* too (no
  descent direction), so alone it re-introduces growth-blocking on ascent hover.
- `_alt_orbital` / regime latch — false below the ATMO_TOP+PREP=416 restore,
  i.e. disarms for the lower half of the flood band.

The only signal that is live in every regime, at every altitude, in every
locomotion mode, is the analytic radial altitude itself: `h =
_radial_altitude_lattice(player_pos)` (`world_manager.gd:723-730`) — a pure
function of the position that `player.gd:921` feeds to `update_streaming` every
physics tick in ALL regimes (orbital coast included; `_update_approach_anchor`
at `world_manager.gd:1376` is NOT gated on `_alt_frozen()`), continuous across
facet crossings because radial altitude is frame-independent
(`lattice_to_world64 → |w| − R_BLOCKS`). C-lite derives descent from **the sign
of Δh between successive debounced anchor writes**.

---

## 2. The descent predicate (deliverable 1)

### 2.1 Definition

Two pieces of state, updated once per *debounced anchor write* (≥
`ANCHOR_WRITE_DEBOUNCE_MS` = 100 ms apart, `cube_sphere.gd:2739`) inside
`_apply_approach_anchor`, right after `h` is computed:

```
dt      = (now_ms − prev_ms) / 1000                  # ≥ 0.1 s by debounce; larger on slow frames
vy_w    = (h − prev_h) / dt                          # radial rate, blocks/s, per-write
descending latch:
    if |vy_w| > REENTRY_DESCENT_VY_CLAMP (2000):     # teleport/pause discontinuity → ignore sample
        (keep latch, resample baseline)
    elif vy_w ≤ −REENTRY_DESCENT_VY_ON (10):         # engage on a single write
        _reentry_descending = true;  _reentry_calm_writes = 0
    elif vy_w ≥ −REENTRY_DESCENT_VY_OFF (5):         # calm write
        _reentry_calm_writes += 1
        if _reentry_calm_writes ≥ REENTRY_DESCENT_CALM_N (3):
            _reentry_descending = false              # release after ~0.3 s sustained calm
    # writes in the dead zone (−10, −5) keep the latch as-is (hysteresis band)

armed  = _reentry_descending and h > REENTRY_DESCENT_MIN_ALT (128.0)
```

`armed` drives the backlog-block; `_reentry_descending` (without the altitude
floor — the hold has its own 460 floor) drives `reentry_hold_view`.

### 2.2 Proof: LIVE at and above the atmosphere-entry crossing

- The tracker consumes only `h`, which is analytic and computed fresh on every
  anchor write in every regime (§1.1). Nothing in its dataflow is
  regime-gated, EMA'd, or speed-clamped. There is no path on which it can go
  stale while `_apply_approach_anchor` runs — and if `_apply_approach_anchor`
  did not run, the gate site would not run either (they are the same function).
- Engagement precedes the flood *by construction*: the first growth want
  appears only once d < ANCHOR_REL_HI = 900 (`approach_view_distance`,
  `cube_sphere.gd:2774-2777`), and re-grow toward full begins below the
  released knee ANCHOR_REL_LO/ANCHOR_HYST ≈ 609. Any descent fast enough to
  flood (≥ tens of b/s — §0 of the #80 design: slow descents don't flood,
  their annuli are small per write) produces per-write Δh of −1 to −90 blocks
  ≫ the 1-block deadband (10 b/s × 0.1 s), so the latch is true within one or
  two writes of the descent starting — hundreds of blocks above the 900 knee.
- A slow spiral decay (< 10 b/s) never engages — correctly: at ≤10 b/s the
  900→609 re-grow band takes ≥ 29 s, the same 6.5k tasks spread across ≥290
  debounced writes, each annulus tiny; and growth is still step-clamped (§3).

### 2.3 Proof: FALSE when grounded (no walk-wedge)

Three independent layers:

1. **Structural (the hard one):** the backlog-block requires `h > 128.0`. The
   analytic max surface height is **112** (`terrain_config.gd:275-276`:
   BASE 5 + continent 11 + hills 3 + detail 1 + MOUNTAIN_AMPLITUDE 92; Moon
   base 40). A player standing on ANY terrain has h ≤ ~114 < 128, so the
   backlog-block is *impossible* while grounded, regardless of latch state,
   backlog value, or FP_SUMMIT_STREAM. This single inequality retires the #80
   reviewer's walk-wedge scenario (global backlog is routinely 1.5–2.8k during
   ordinary walking — it can no longer block anything on the ground).
2. **Latch semantics:** grounded/walking radial rate is ~0 (downhill sprint
   ≈ −7 b/s < the 10 b/s engage threshold); a jump-fall may spike a write or
   two, but the latch releases after 3 calm writes (~0.3 s). At touchdown of a
   real de-orbit, Δh → 0 → latch drops in ~0.3 s.
3. **Law shape (§3):** even when armed *or* wedged-adjacent, growth is never
   frozen below full indefinitely — un-armed growth is unconditional at
   +STEP/write (reaches full 128 from 0 in ≤ 1.6 s of writes), so there is no
   state in which the near view can be held below full while grounded.

### 2.4 Threshold rationale

| Const | Value | Why |
|---|---|---|
| `REENTRY_DESCENT_VY_ON` | 10.0 b/s | Above any grounded locomotion vertical rate (~7 b/s downhill sprint); far below any descent that can flood (≥ tens of b/s). With the 100 ms debounce this is a 1-block deadband per write — enormous SNR vs the −30..−90 blocks/write of a real fall. |
| `REENTRY_DESCENT_VY_OFF` | 5.0 b/s | Release threshold < engage threshold → Schmitt hysteresis; no flap at apoapsis/near-hover where vy oscillates around 0. |
| `REENTRY_DESCENT_CALM_N` | 3 | ~0.3 s of sustained calm to release — outlives one bouncy write, short enough that touchdown un-arms almost immediately. |
| `REENTRY_DESCENT_MIN_ALT` | 128.0 | > 112 max terrain (structural grounded-safety, §2.3.1); < 256 (the measured 959 ms stall altitude stays covered); below 128 the step-clamp (§3) still paces the final landing growth. |
| `REENTRY_DESCENT_VY_CLAMP` | 2000.0 b/s | Rejects dev-teleport/fast-travel Δh discontinuities as non-motion (real de-orbit radial rates peak ~500–700 b/s). Unlike the 40 b/s EMA clamp this is far above every genuine rate, so it can never freeze the tracker mid-fall. |

---

## 3. Law changes

### 3.1 `reentry_admit_view` v2 — always step-clamp; backlog-block only while armed

```gdscript
static func reentry_admit_view(last_vd: int, want_vd: int, gen_backlog: int, descending: bool) -> int:
    if not FP_REENTRY_BACKLOG_GATE or last_vd < 0 or want_vd <= last_vd:
        return want_vd                                   # off / first write / shrink: verbatim
    if descending and gen_backlog > REENTRY_GEN_BACKLOG_MAX:
        return last_vd                                   # descent-armed + engine saturated: hold
    return mini(want_vd, last_vd + REENTRY_GROW_STEP)    # ALWAYS paced growth under the flag
```

Two deliberate deltas vs #80:

- **The call is unconditional under the flag** (the `and falling_fast` arming
  at the call site is deleted). The freeze-sensitivity is gone: the *predicate*
  only modulates the backlog condition, so a false-negative (missed descent)
  degrades to step-clamped growth (annuli ≤ ~790 tasks vs 6–7k — still a large
  win), and a false-positive (spurious "descending" on the ground) can block
  nothing because of the `h > 128` structural floor folded into `descending`
  (the site passes `armed`, §2.1).
- **Growth is step-clamped even when not armed.** This closes the
  landing-cliff hole: if the backlog stays saturated through the descent and
  the player lands with a small view, the old shape would jump to full in one
  write — a ~5.9k-task flood *at touchdown*. Now the post-landing catch-up is
  16 × ~100 ms writes, each annulus ≤ ~790 tasks. Cost of the new pacing in
  normal play: none at boot/spawn (`last_vd == −1` → verbatim first write),
  none grounded-stable (`want == last`), none on ascent (shrink verbatim);
  a dev-teleport re-anchor grows 0→128 over ~1.6 s (acceptable — teleports
  already settle-hold).

### 3.2 `reentry_hold_view` — same law, corrected arming input

Body unchanged (`cube_sphere.gd:2830-2833`); the `falling_fast` parameter is
renamed `descending` and the call site passes `_reentry_descending` instead of
the EMA test. Its internal `alt <= REENTRY_REGROW_DEFER_ALT (460)` floor is
untouched; ascent never holds because ascent → latch false.

### 3.3 New pure static for the latch (gate-testable)

Mirror of the #80 pattern (pure statics on CubeSphere so verify scripts drive
them headless with inline loops — the GDScript-closure-trap rule):

```gdscript
## C-lite (§2): one descent-latch step. Returns [descending: bool, calm_writes: int].
static func reentry_descent_step(vy_w: float, descending: bool, calm_writes: int) -> Array:
    if absf(vy_w) > REENTRY_DESCENT_VY_CLAMP:
        return [descending, calm_writes]                 # relocation, not motion
    if vy_w <= -REENTRY_DESCENT_VY_ON:
        return [true, 0]
    if vy_w >= -REENTRY_DESCENT_VY_OFF:
        calm_writes += 1
        if calm_writes >= REENTRY_DESCENT_CALM_N:
            return [false, calm_writes]
        return [descending, calm_writes]
    return [descending, calm_writes]                     # hysteresis dead zone
```

WorldManager's `_reentry_descent_tick` (§5.2) is a thin wrapper: compute
`vy_w` from `(h, now_ms)` vs the stashed previous sample, call this, stash.

---

## 4. Flag decision (deliverable 2): REUSE, with a revision marker

**Recommendation: reuse `FP_REENTRY_BACKLOG_GATE` + `FP_REENTRY_REGROW_DEFER`
with the corrected arming. Do not add `FP_REENTRY_DESCENT_GATE`.**

- Both flags are merged default-OFF and have never been in a green served
  build ON — there is no compat surface, and their *behavioral contract*
  ("bound the re-entry view-growth flood") is unchanged; only the broken
  arming input is replaced. One behavior = one flag pair.
- A third flag creates 8 combinations to reason about in
  `verify_reentry_pace.gd` and leaves attempt #2's provably-dead
  `falling_fast` keying in the tree.
- The sed-flip A/B tooling (the deploy-cheats pattern:
  `sed -i 's/const FP_REENTRY_BACKLOG_GATE := false/… := true/'` — already
  documented in `verify_reentry_pace.gd:26`) keeps working verbatim.
- A/B distinguishability (which semantics a served pck actually has — the
  established pck flag-dump technique) is preserved by adding
  **`const REENTRY_GATE_REV := 2`** next to the flag; the verify gate prints
  and asserts it, and a `load_resource_pack` const dump on the served pck
  disambiguates attempt-#2 (no such const / rev 1) from C-lite builds.

Byte-off discipline: every new const defaults inert (`FP_*` stay `false`); the
tracker tick runs only under `FP_REENTRY_BACKLOG_GATE or
FP_REENTRY_REGROW_DEFER`; both laws early-return `want_vd` verbatim with flags
off; FLAT (`FACETED=false`) never reaches `_apply_approach_anchor` at all
(`world_manager.gd:768`) ⇒ FLAT `verify_feature.gd` stays **6042/0**.

---

## 5. Exact edit sites (deliverable 3)

Line numbers per this worktree @ `ea1162a` (deploy/perf-plus-sky).

### 5.1 `godot/src/cosmos/cube_sphere.gd`

**(a) :2788-2795 — doc-comment paragraph** ("Review fix …") : rewrite to
describe the C-lite arming (descent latch + h>128 structural floor + un-armed
step-clamp), citing this doc. Comment-only.

**(b) after :2799 (below `REENTRY_GROW_STEP`) — new consts:**

```gdscript
## C-lite (docs/COSMOS-FALL-CLITE-DESIGN.md §2): the freeze-independent descent latch. Arming rev 2 —
## rev 1 (falling_fast/_fall_vy_ema) was measured-dead: the EMA sample is rejected whenever per-tick
## speed ≥ VEL_PREDICT_SPEED_CLAMP (40 b/s), i.e. across the ENTIRE de-orbit flood band (§1).
const REENTRY_GATE_REV := 2
const REENTRY_DESCENT_VY_ON := 10.0     # engage: per-write radial rate ≤ −this (b/s); > any grounded rate
const REENTRY_DESCENT_VY_OFF := 5.0     # release threshold (Schmitt band with VY_ON; no apoapsis flap)
const REENTRY_DESCENT_CALM_N := 3       # consecutive calm writes (~0.3 s) to release the latch
const REENTRY_DESCENT_MIN_ALT := 128.0  # backlog-block only above this radial alt (> 112 max terrain
                                        # ⇒ grounded backlog-wedge is STRUCTURALLY impossible)
const REENTRY_DESCENT_VY_CLAMP := 2000.0 # reject a per-write rate above this as teleport, not motion
```

**(c) :2805-2810 — `reentry_admit_view`:** replace with the §3.1 body
(adds the `descending: bool` 4th parameter; always-step-clamp shape).

**(d) after (c) — add `reentry_descent_step`** (§3.3 body).

**(e) :2826-2833 — `reentry_hold_view`:** rename param `falling_fast` →
`descending`; update the :2827-2829 comment to point at §2 of this doc
(body/floor unchanged).

### 5.2 `godot/src/world/world_manager.gd`

**(a) after :172 (`var _anchor_last_vd := -1`) — tracker state:**

```gdscript
# C-lite (COSMOS-FALL-CLITE §2): the freeze-independent descent latch, advanced once per debounced
# anchor write from the analytic radial altitude (never _fall_vy_ema — §1: the EMA is speed-clamp
# frozen across the whole de-orbit band). All inert (never written) unless FP_REENTRY_BACKLOG_GATE
# or FP_REENTRY_REGROW_DEFER ⇒ byte-identical off.
var _reentry_prev_alt := 0.0
var _reentry_prev_alt_ms := -1          # −1 = no baseline yet (first write only samples)
var _reentry_descending := false
var _reentry_calm_writes := 0
```

**(b) :834 — the hold site.** Before:

```gdscript
view_f = CubeSphere.reentry_hold_view(view_f, h, _fall_vy_ema < -CubeSphere.ENV_FALL_HOLD_VY)
```

After (tracker tick immediately above it, so both consumers see this write's
fresh latch; `h` is computed at :803):

```gdscript
if CubeSphere.FP_REENTRY_BACKLOG_GATE or CubeSphere.FP_REENTRY_REGROW_DEFER:
    _reentry_descent_tick(h)            # §2.1: advance the latch from Δh between debounced writes
view_f = CubeSphere.reentry_hold_view(view_f, h, _reentry_descending)
```

**(c) :840-849 — the backlog-gate site.** Before (comment block + code):

```gdscript
if CubeSphere.FP_REENTRY_BACKLOG_GATE and _fall_vy_ema < -CubeSphere.ENV_FALL_HOLD_VY:
    var backlog := _voxel_gen_backlog()
    near_vd = CubeSphere.reentry_admit_view(_anchor_last_vd, near_vd, backlog)
```

After (rewrite the :840-846 rationale comment per §2.3/§3.1):

```gdscript
if CubeSphere.FP_REENTRY_BACKLOG_GATE:
    var armed := _reentry_descending and h > CubeSphere.REENTRY_DESCENT_MIN_ALT
    var backlog := _voxel_gen_backlog() if armed else 0   # skip the stats call when un-armed
    near_vd = CubeSphere.reentry_admit_view(_anchor_last_vd, near_vd, backlog, armed)
```

**(d) new private method** (next to `_voxel_gen_backlog`, after :797):

```gdscript
## C-lite (§2.1): advance the descent latch from the analytic radial altitude. Called only from
## _apply_approach_anchor (≤ ~10 Hz by the anchor debounce) and only under the reentry flags.
func _reentry_descent_tick(h: float) -> void:
    var now_ms := Time.get_ticks_msec()
    if _reentry_prev_alt_ms < 0:
        _reentry_prev_alt = h
        _reentry_prev_alt_ms = now_ms
        return
    var dt := float(now_ms - _reentry_prev_alt_ms) / 1000.0
    if dt <= 0.0:
        return
    var vy_w := (h - _reentry_prev_alt) / dt
    _reentry_prev_alt = h
    _reentry_prev_alt_ms = now_ms
    var r := CubeSphere.reentry_descent_step(vy_w, _reentry_descending, _reentry_calm_writes)
    _reentry_descending = r[0]
    _reentry_calm_writes = r[1]
```

**(e) :783-787 — `_voxel_gen_backlog` doc comment:** drop the stale "AND while
falling_fast" clause; now "under FP_REENTRY_BACKLOG_GATE while descent-armed".

**(f) optional (recommended for the A/B): telemetry read-back** next to
`gen_cache_stats()` (:245), same `{}`-when-off pattern so telemetry is
byte-identical off:

```gdscript
func reentry_gate_stats() -> Dictionary:
    if not (CubeSphere.FP_REENTRY_BACKLOG_GATE or CubeSphere.FP_REENTRY_REGROW_DEFER):
        return {}
    return {"rg_rev": CubeSphere.REENTRY_GATE_REV, "rg_desc": _reentry_descending,
            "rg_last_vd": _anchor_last_vd}
```

(RemoteBridge folds it into the telemetry record exactly like `gen_cache_stats`.)

### 5.3 `godot/src/tools/verify_reentry_pace.gd`

- Update the two script-local mirrors (`_mirror_admit` :44-49 gains the
  `descending` arg + the §3.1 shape; `_mirror_wired_near_vd` :63-64 loses the
  `falling_fast` conjunct and passes `armed`).
- New asserts (inline loops, both arms): (1) not-descending growth is admitted
  at exactly +STEP regardless of backlog (the no-wedge law); (2) descending +
  backlog > MAX holds; (3) descending + backlog ≤ MAX grows +STEP; (4) shrink
  verbatim; (5) `reentry_descent_step` truth table: engage at −10, hold in
  (−10,−5), release only after 3 calm writes, teleport-clamp keeps state;
  (6) grounded-structural: for every h ≤ 114 the wired arm is false whatever
  the latch says; (7) the gate arm prints and asserts
  `REENTRY_GATE_REV == 2` and the compiled flag values (self-describing arm —
  the sed-ON run refuses to "pass" against a rev-1/flag-off pck).
- OFF arm continues to prove the statics return verbatim (byte-identity), and
  FLAT `verify_feature.gd` must print 6042/0 untouched.

Nothing else changes. `FP_ENV_FALL_HOLD`/`FP_LAND_RAMP_HOLD` keep their
existing `hold` wiring (out of C-lite's scope; note for later: their signal has
the same clamp-freeze and could adopt this latch in a follow-up).

---

## 6. Constants: backlog max + grow step (deliverable 4)

Flood geometry: full disc at vd=128 ≈ 6.5k tasks ⇒ K ≈ 6500/128² ≈ 0.40
tasks/block². One +8 annulus = K·(16v+64): ~44 tasks at v=0, ~380 at v=56,
~790 at v=120.

- **`REENTRY_GEN_BACKLOG_MAX := 256` — keep.** Peak concurrent under the gate
  ≈ cap (256) + the largest single admitted annulus (~790) ≈ **~1050**, ≤ the
  1500 target with ~400 of headroom for global (prebake/far-ring) gen noise.
  Attempt #2's 128 starved because the *global* backlog rarely drains below
  128 mid-descent even when nothing floods — with 256 the fluke-ON run did
  bind the flood at ~5× fewer tasks while still growing. Do NOT retune 256
  based on attempt #2's runs: those runs' arming was dead, so their dynamics
  say nothing about the gated regime.
- **`REENTRY_GROW_STEP := 8` — keep.** 16 admitted writes × ≥100 ms = 1.6 s
  minimum full growth; a drag-braked fall spends ≥10 s below the 609 knee, so
  8 does not starve. 4 (attempt #2) doubles the writes and, combined with the
  dead arming + 128 cap, produced the 2.9 fps crawl; there is no reason it
  helps now — the per-annulus bound at 8 (~790) is already under the target.
- **Descent-gating changes what the constants must survive, not their values:**
  the gate is now armed for the *whole* descent instead of a late fluke
  window, so the worst case is "backlog saturated throughout" — handled by the
  law shape (§3.1: un-armed/landing growth still paces at +8/write), not by
  tightening constants. **Tuning order if the A/B peak exceeds ~1500:** first
  MAX 256→192 (lowers the floor under the peak), only then STEP 8→6 (raises
  growth latency); never both at once (attempt #2's lesson).

---

## 7. Live A/B plan (deliverable 5)

Build two exports off the same commit: BASE (flags off) and CLITE
(`sed -i 's/const FP_REENTRY_BACKLOG_GATE := false/const FP_REENTRY_BACKLOG_GATE := true/;
s/const FP_REENTRY_REGROW_DEFER := false/const FP_REENTRY_REGROW_DEFER := true/'
godot/src/cosmos/cube_sphere.gd`), deploy via the deploy-cheats worktree,
confirm the served pck via const dump (`REENTRY_GATE_REV == 2` present ⇔ CLITE
semantics — never trust the branch name).

Protocol per run (remote-bridge scripted flight, `?remote=<token>`):

1. **Warm first:** idle grounded until telemetry `vox_gen` settles ≈ 0 and the
   prebake is quiet — `vox_gen` is a GLOBAL counter; an unwarmed prebake
   pollutes the peak. Compare warm-vs-warm only.
2. **Establish orbit** (space-nav verbs; confirm stable alt > 900) BEFORE
   releasing the fall — the measured baseline is a *released de-orbit*, not a
   powered dive.
3. **Released fall** to touchdown; log telemetry.jsonl at 10 Hz: `alt`,
   `vox_gen`, frame_ms (real deltas, p90 + max — never TIME_PROCESS on
   threaded web), `rg_desc`/`rg_last_vd` (§5.2f).
4. **Walk-wedge check (mandatory):** after landing, walk/sprint 60 s; assert
   `rg_last_vd` reaches full 128 within ~10 s of touchdown and stays there;
   separately, a fresh ground spawn must reach 128 normally.
5. ≥3 runs per arm (attempt #2's 1-of-4 fluke is the cautionary tale).
   Consent lapses on `link_lost` — re-grant the bridge before each run or the
   telemetry silently stops.

**Success criteria:** (a) `vox_gen` peak during the fall ≤ ~1500 (baseline
~5900) on every CLITE run; (b) fall fps floor ≥ 10–15, no single frame >
~400 ms in the entry band (baseline: 959 ms observed); (c) `rg_desc` true from
the burn until ~touchdown+0.3 s and false while walking (the predicate
liveness check, directly observable); (d) no walk-wedge per step 4; (e) landing
visual completeness comparable to BASE (the REGROW_DEFER 64-disc + far-ring
chords cover, hole=0 — already proven in #80's REGROW work).

**Rollback:** flags back to false = byte-identical shipped behavior; the
tracker vars are never written with both flags off.
