# COSMOS LOD-HANDOFF FLICKER (trees + houses, while MOVING) — design

**Status: DESIGN ONLY — no code changed.** Scope: visual correctness of the near↔far handoff for
trees (`FacetFarTrees`) and structures (`FacetFarStructures`) while the player is **walking**
(horizontal motion across `near_render_radius()`), as distinct from the descent/fall case
`FP_STRUCT_NEAR_HOLD` (just merged) targets. No gameplay code touched; this proposes byte-off
`FP_*` render-layer flags only.

Caveat on flag state: `cube_sphere.gd`'s source constants (`FP_FAR_TREES*`, `FP_STRUCT_*`, …) all
read `false` in this worktree — per the FARTREE-POLISH design doc's own methodology note, the
**served** web build's flags must be confirmed by dumping the live `.pck`
(`ProjectSettings.load_resource_pack` + `get_script_constant_map`), never assumed from the
worktree source. This doc reasons from the code's *logic*, which holds regardless of which flags
are flipped on for deploy; where a specific flag's ON/OFF state changes the diagnosis I say so
explicitly.

---

## 1. Root cause

Both tiers already have a hide/show dwell (streak) machine keyed off the shared
`NearPresence.covered()` fact probe (`godot/src/world/near_presence.gd`) — this is **not** the
classic "hysteresis-free boundary thrashing every frame" bug (category a). The dwell/streak
machinery already exists and already suppresses razor's-edge per-frame toggling. The flicker is a
**different** failure mode from the same list: a **hard, un-crossfaded swap** whose transition
window is stretched to human-visible duration by throttling that gets *worse*, not better, exactly
while the player is moving (categories c/d/e combined).

### 1.1 Trees: the NEARCULL handoff is explicitly a HARD swap, not a fade

`FacetFarTrees` has real dither cross-fade machinery (`FP_FAR_TREES_FADE`) for two of its three
handoffs — near→mesh-rung dither-IN over `[R0, R0+FADE_NEAR_W]` and mesh↔card cross-dither over
`[448±FADE_BAND_W]` (`mesh_fade()`/`card_fade()`, `facet_far_trees.gd:396-425`). But the
NEARCULL boundary (the one this bug lives at — near voxel mesh present/absent) is **not** one of
the faded terms. The code says so directly:

```
facet_far_trees.gd:1291-1292
# FP_FAR_TREES_NEARCULL §5.2: the near-frontier dither-IN is REPLACED by the probe (a hard swap the §4 weld
# makes invisible) — keep only the 448 cross-dither (fout) so gap-fill trees (d<R0) aren't faded to nothing.
```

i.e. once `FP_FAR_TREES_NEARCULL` is on, the near-frontier `smoothstep(r0, r0+FADE_NEAR_W, d)`
dither-in term is dropped and replaced by `_nearcull_emit()`'s **boolean** cull decision
(`facet_far_trees.gd:550-578`). The tree either draws at full alpha or is not emitted at all —
there is no partial-alpha state at this boundary, ever.

The boolean itself already has asymmetric hysteresis:
- **Hide** (near arrived): `COVERED ⇒ return false` immediately — `HIDE_STREAK` is effectively 1
  (`facet_far_trees.gd:565-567`, "a positive `is_area_meshed` is a fact").
- **Show** (near receded): `NOT_COVERED` must repeat `FT_CULL_DWELL=2` **consecutive rebuild
  passes** before `_cull_dwell` erases and the tree returns (`facet_far_trees.gd:568-576`).

Both directions are gated by how often a *real rebuild pass* runs, not by wall-clock time or by a
frame counter: `_rebuild_inputs_changed` requires `_stream_credit_ok` (or the `FP_FT_STALE_REBUILD`
≤0.5 Hz override) AND (a delta condition — camera move, edit rev, or the NEARCULL change
fingerprint) (`facet_far_trees.gd:1057-1071`). `FP_FT_NEAR_GUARD` narrows this gap for the **hide**
direction only — a bounded, credit-independent, cull-only pass that zeroes stray live impostors —
but by its own comment budget (`CULL_PROBE_CAP`/`FT_GUARD_PROBE_CAP=64`, "annulus worst 144 → full
sweep ≤3 steps ≈0.75s via the round-robin cursor", `facet_far_trees.gd:56-57`) it can take **up to
~0.75 s** to notice and hide a newly-covered impostor under a dense annulus or fast motion. There is
**no** equivalent guard for the **show** direction — a receding tree's far impostor only comes back
once a real (credit-gated) rebuild completes 2 consecutive NOT_COVERED probes.

**Why this is worse while moving, not better:** `_stream_credit_ok` throttles exactly the frames
where the near voxel field is busiest generating/meshing chunks — which is precisely what's
happening *because* the player is walking into new territory. So the rebuild cadence that the
dwell counters depend on is most starved exactly when the boundary is being crossed. The probe
fact (`NearPresence.covered`) itself is accurate and cheap (a pure `is_area_meshed` read, no
latency of its own — `near_presence.gd:35-57`), but the *consumption* of that fact (streak advance
+ hard on/off swap) is rate-limited by the same budget the motion itself is consuming. Net effect
while walking: a tree crossing the boundary either (a) double-renders — near tree present, far
impostor still latched shown — for up to ~0.75 s (bounded by `FP_FT_NEAR_GUARD` when on, unbounded
by the ordinary rebuild cadence when off), or (b) vanishes from both renderers for however long 2
consecutive credit-gated rebuild passes take to land (unbounded — no guard on this side at all),
then **pops back in hard** (no fade) once the dwell is satisfied. Both read as "flicker."

### 1.2 Structures: same mechanism, no fade infrastructure at all, plus a structurally slower streak

`FacetFarStructures` renders ONE merged opaque `ArrayMesh` (`_commit_mesh`,
`facet_far_structures.gd:444-453`) with a `COLOR.rgb`-only unshaded shader (`_TAIL`,
`facet_far_structures.gd:83-96`) — there is no alpha/dither channel at all, so there is **no way
to fade a structure in or out today**; every hide/show is a full merged-mesh rebuild with that
structure's triangles present or absent.

The cull/streak law (`_cull_emit`, `facet_far_structures.gd:325-367`) mirrors the trees' but is
**symmetric and slower**: `STRUCT_HIDE_STREAK=2` **and** `STRUCT_SHOW_STREAK=2`
(`cube_sphere.gd:1251-1252`) — both directions need 2 consecutive probe agreements, not just the
show direction. Unlike the trees' `_cull_dwell`, the streak-advance step (`_cull_emit`, called from
inside `_rebuild`) is *not* independent of the expensive path — a streak only advances when
`_rebuild()` actually runs, which needs `_inputs_changed()` true. `_inputs_changed` does have a
`_cull_pending` escape (`facet_far_structures.gd:271-287`) that keeps re-arming while a transition
is outstanding, so once a rebuild *does* run it doesn't need to wait on the 2-block camera-move
delta gate for the second probe — but the **outer** gate,
`_credit_gate_open = settled and (credit_ok or FP_STRUCT_NEAR_GUARD)`
(`facet_far_structures.gd:265-266`), still blocks the entire probe+streak+rebuild pass at credit 0
unless `FP_STRUCT_NEAR_GUARD` is on — and per its own comment that flag currently only "admits the
… structures step at credit 0" for the **whole** step, i.e. it still pays the full merged-mesh
rebuild cost every time it runs, so it cannot run every frame the way the trees' lightweight guard
does. So structures get the *same* motion-correlated stream-credit starvation as trees, with:

- a **guaranteed minimum** double-render window on hide (streak must reach 2 even when the pass
  isn't starved — a whole house-silhouette double-image, far more visually jarring than a tree)
  and a **guaranteed minimum** gap window on show, plus
- no bounded credit-independent guard on *either* direction (trees at least have one for hide), so
  the worst case is unbounded stall, not ~0.75 s, and
- no fade to mask whatever window remains — every transition is a hard pop of an entire building.

### 1.3 Answering the task's classic-cause checklist
- (a) Hysteresis-free thrash at the boundary: **not the primary cause** — both tiers already
  Schmitt-gate on streak count. A secondary contributor: `_probe_pass`'s `below_floor` branch
  selection (`dist < r0`, `facet_far_structures.gd:309`) and the trees' `dist < FT_CULL_MIN` /
  `dist > probe_hi` branch edges (`facet_far_trees.gd:553,556`) are themselves un-hysteresis'd
  distance comparisons — a player oscillating exactly on `r0` can flip which *branch* of the state
  machine runs frame to frame, though the streak counters inside still damp the visible effect.
- (b) Gap where far hides before near is built (or the reverse): **yes, and this is exactly what
  `FP_STRUCT_NEAR_HOLD` targets** — see §2.
- (c) Double-render both-visible flash: **yes — primary cause**, from the credit-starved hide-side
  latency (§1.1) and the guaranteed 2-streak minimum for structures (§1.2).
- (d) Stale rebuild window where a prop briefly vanishes during a rebuild: **yes — primary cause**,
  from the credit-starved show-side latency (unbounded for both tiers absent a guard on that side).
- (e) COVERED/NOT_COVERED streak mistiming under continuous motion: **yes — this *is* (c)+(d)
  restated**: the streak is correct in *logic*, its real-world *duration* balloons under motion
  because the thing that advances it competes for the same frame-budget that motion itself spends.

---

## 2. Does FP_STRUCT_NEAR_HOLD help, hurt, or not touch the moving case?

**Helps, but only partially — it doesn't touch the dominant moving-flicker mechanism.**

`FP_STRUCT_NEAR_HOLD` changes only the `dist < r0` branch of `_cull_emit`
(`facet_far_structures.gd:331-350`). Shipped (flag off): `dist < r0 ⇒ return false` unconditionally
— the far model disappears the instant the player crosses inside `r0`, whether or not the near
mesh has actually finished streaming there. That is a real, general GAP source (category b) that
applies to **any** crossing of `r0`, not just descent — a player walking briskly toward a house
while near-chunk generation lags (e.g. under stream-credit pressure from the same motion) will hit
this exact hole. With the flag on, the inside-`r0` branch requires an actual `COVERED` probe before
hiding (immediate on that fact, matching the trees' law) and requires `STRUCT_SHOW_STREAK`
consecutive `NOT_COVERED` probes before un-hiding — same "safe direction" as the outer annulus.

So for **horizontal** motion: FP_STRUCT_NEAR_HOLD closes one specific unconditional-distance gap
(good, keep it on), but:
- It does **not** touch the `[r0, r0+CULL_ANNULUS]` outer-annulus branch, which is where most of
  the walking-flicker plays out (a player approaching from outside `r0` crosses that whole 64-block
  band before ever reaching the inside-`r0` branch) — that branch's `STRUCT_HIDE_STREAK=2` /
  `STRUCT_SHOW_STREAK=2` dwell-via-credit-gated-rebuild latency (§1.2) is unaffected.
  it Introduces the *same* probe-based streak machinery inside `r0` that already causes the
  guaranteed-double-render / guaranteed-gap windows outside it — so the inside-`r0` band now has
  the *same* moving-flicker exposure the outer band already had, in exchange for fixing the
  worse unconditional-hide gap. Net: strictly better (a bounded, probe-gated transient replaces an
  unconditional hole), but the moving-flicker symptom itself is not resolved, only slightly
  relocated/reduced in the inner band.
- It is still behind the same `_credit_gate_open` throttle, so under motion-correlated credit
  starvation its own probe can go stale too — but its *failure direction* is the safe one (keeps
  showing until proven covered ⇒ a stale double-render, never a stale gap), which is strictly
  better than the shipped behaviour but still a visible artifact, not a fix for the flicker itself.

**Verdict for the exec summary: NEAR_HOLD is a real but partial win — it removes one gap source and
converts it to the same (still-visible) double-render/streak-latency class the rest of this doc
fixes; it doesn't reach the outer-annulus streak-latency root cause, which is the majority of the
moving flicker.**

---

## 3. Fix design

One flag family per tier, composing with everything shipped above (NEARCULL, NEAR_GUARD,
STALE_REBUILD, STRUCT_NEAR_HOLD, STRUCT_NEAR_GUARD). Two independent levers, both needed per the
task's brief ("hysteresis... AND a cross-fade or hold"):

**Lever A — decouple the streak/decision cadence from the expensive-rebuild credit gate.**
Generalize `FP_FT_NEAR_GUARD` (currently hide-only for trees, whole-step-admission for structures)
into a genuinely bidirectional, bounded, credit-independent **decision** pass: probe + advance
streak every frame (capped, like the existing `CULL_PROBE_CAP`/`FT_GUARD_PROBE_CAP`/
`STRUCT_HOLD_PROBE_CAP` budgets already in the code), for BOTH hide and show, for BOTH tiers. This
bounds transition *duration* to a fixed frame/ms budget regardless of stream-credit pressure. The
expensive part (MultiMesh buffer rewrite / merged-mesh rebuild) stays credit-gated as today — only
the lightweight streak bookkeeping + a per-instance/per-vertex alpha value need to run every frame.

**Lever B — replace every hard on/off swap this bug lives at with a real cross-fade, driven by
streak progress (0 at transition start → 1 at transition complete), not distance.** This is the
direct fix for §1.1/§1.2: turn `cs["cover"]/HIDE_STREAK` and `cs["uncover"]/SHOW_STREAK` (and the
trees' `_cull_dwell` streak) into a continuous `[0,1]` alpha instead of a step function, and feed
it into the existing dither-discard machinery (trees) or a newly-added one (structures, which has
none today).

Also add distance dead-band (the task's requested Schmitt hysteresis) as belt-and-suspenders against
§1.3(a)'s branch-selection flicker, independent of the probe:

### 3.1 Trees — `FP_FT_NEARCULL_XFADE`

New flag, composes with `FP_FAR_TREES_NEARCULL` (no-op without it). Edit sites:

- `facet_far_trees.gd:550-578` (`_nearcull_emit`): return the existing bool for the emit/no-emit
  gate (geometry inclusion — unchanged, still needed to bound `FAR_TREES_MESH_TOTAL_MAX`/
  `FAR_TREES_CARD_INST_MAX` instance counts), **plus** expose the streak progress as a float via a
  companion read `_nearcull_alpha(fid, bx, gy, bz) -> float`: `cs["cover"]/1.0` while hiding (streak
  is already 1 = instant, so this stays a fast ramp — see below for widening it) and
  `cs["uncover"]/FT_CULL_DWELL` while showing, clamped `[0,1]`, 1.0 in every other (steady) state.
  Under `FP_FT_NEARCULL_XFADE`, also widen the immediate `HIDE_STREAK=1` to a small fixed frame
  count (e.g. 6, ~0.1 s at 60 fps) — an instant fact-based hide is *correct* logically but gives
  the dither nothing to fade over; a few-frame hide streak plus the fade below makes the hide look
  intentional instead of a snap, at negligible cost to the "hole" concern the instant-hide law was
  protecting against (a covered spot behind a fully-opaque near wall is never visible mid-fade
  anyway).
- `facet_far_trees.gd:1291-1298` (near-frontier dither term): replace the comment-documented "hard
  swap" with `fin *= _nearcull_alpha(...)` — i.e. the near-frontier dither-in term is the *product*
  of the existing distance ramp (kept for the non-NEARCULL degrade path, byte-identical there) and
  the new streak-progress alpha, instead of being unconditionally dropped. Same treatment for the
  mesh-band emit path around `facet_far_trees.gd:1282-1298`.
- `facet_far_trees.gd:56-59` / `cube_sphere.gd:1152-1153`: add `FT_CULL_XFADE_HIDE := 6` (frames)
  and reuse `FT_CULL_DWELL` for the show ramp length (already 2 rebuild-passes; under Lever A this
  becomes 2 *frames* of the new bounded pass, i.e. effectively instant-but-faded rather than
  multi-second).
- Distance dead-band: widen the `dist < FT_CULL_MIN` / `dist > probe_hi` edges
  (`facet_far_trees.gd:553,556`) into `FT_CULL_MIN - FT_HYST_W` / `probe_hi + FT_HYST_W` on entry
  vs. exit (i.e. which branch you're already in wins ties) — new const `FT_HYST_W := 8.0`.

### 3.2 Structures — `FP_STRUCT_XFADE` (+ `FP_STRUCT_HANDOFF_HYST` for the dead-band)

Structures need real shader work since there is no alpha channel today:

- `facet_far_structures.gd:83-96` (`_TAIL`): add a dither-discard fragment test against a new
  `COLOR.a` (currently only `COLOR.rgb` is read) — the same `_ft_dither(FRAGCOORD.xy) > v_fade`
  trick trees already use (`facet_far_trees.gd:221,234`), gl_compat-safe (no blend-state change,
  same reasoning as the far-trees GLES3 MM colour-slot lesson
  [[voxiverse-far-trees-colorfix]] — screen-door alpha avoids the alpha-blend-order problem
  entirely on a merged opaque mesh).
- `_ensure_bake`/`_commit_mesh` (`facet_far_structures.gd:397-453`): thread a per-structure alpha
  (from the widened streak progress, Lever A) into the baked `colors: PackedColorArray`'s `.a`
  component instead of the implicit 1.0, so a structure mid-transition renders at partial (dithered)
  opacity within the SAME merged-mesh commit — no extra draw call, no blend-order issue.
- `_cull_emit` (`facet_far_structures.gd:325-367`) and `_probe_pass`
  (`facet_far_structures.gd:295-323`): under Lever A, run every frame (bounded by
  `STRUCT_HOLD_PROBE_CAP`-style caps already present) so `cs["cover"]`/`cs["uncover"]` advance in
  wall-clock-bounded steps instead of rebuild-pass-bounded steps; expose the fraction
  `min(cs["cover"], STRUCT_HIDE_STREAK)/STRUCT_HIDE_STREAK` (and the `uncover` analogue) as the
  per-structure alpha for the bake step above. Streak counts (`STRUCT_HIDE_STREAK=2`,
  `STRUCT_SHOW_STREAK=2`) stay as-is — the fade masks the transition, so there's no need to shrink
  it to 1.
- Distance dead-band: `_probe_pass`'s `below_floor`/annulus edges (`facet_far_structures.gd:309-311`)
  and `_cull_emit`'s `dist < r0`/`dist > r0 + CULL_ANNULUS` edges (`facet_far_structures.gd:331,351`)
  get the same enter-vs-exit dead-band as trees: new const `STRUCT_HYST_W := 8.0`.
- Note: because it's one merged mesh, a structure fading in/out still needs its vertices *present*
  in the merged array throughout the fade (alpha 0→1, not append/remove), so `_rebuild()`'s
  nearest-first triangle-cap loop (`facet_far_structures.gd:417-434`) must not drop a
  mid-transition structure purely because its OLD `_cull_emit()` bool was false — it should include
  any structure with alpha > 0 (i.e. call the float form, gate on `> 0.0` not the old bool).

### 3.3 Gate (`verify_feature.gd`-style, headless SceneTree)

New gate functions (`G-LODX-*` naming, alongside the existing `G-FTC-*`/`G-FTG-*`/`G-FTSB-*`
read-backs already in `facet_far_trees.gd:1656-1720` and the structures telemetry fields):

1. **No per-frame toggle (Schmitt).** Drive a synthetic camera sweep across `[r0-3·HYST_W,
   r0+3·HYST_W]` at multiple step sizes (0.1, 1, 8, 32 blocks/step, matching walk/run/teleport
   speeds) for a fixed tree and a fixed structure with a scripted COVERED/NOT_COVERED probe stub.
   Assert: the emitted geometry-inclusion boolean changes state at most once per `HYST_W`-wide
   window of monotone motion — i.e. no state flips on a single-block back-and-forth wobble at the
   boundary.
2. **No gap.** At every simulated frame across the same sweep, assert
   `near_covered_bool OR far_alpha > 0.0` — never both false. (Near-covered comes from the scripted
   `NearPresence` stub, standing in for the real near renderer, which is out of scope here but is
   the trusted ground truth per §1's analysis — see §4 for confirming this against the *actual*
   near renderer too.)
3. **No sustained double.** Assert `far_alpha` reaches `1.0` or `0.0` (settles) within a bounded
   frame count (`FT_CULL_XFADE_HIDE` / `STRUCT_HIDE_STREAK` etc. under Lever A's per-frame
   advance) after the probe stub stops flip-flopping — i.e. the only window where
   `near_covered_bool AND far_alpha > 0` is the deliberate fade, bounded in duration, never
   indefinite (which is what credit-starvation causes today).
4. **Byte-off identity.** Both flags off ⇒ every existing NEARCULL/STRUCT_NEAR_HOLD gate
   (`G-FTC-*`, structures' own asserts) passes unchanged — confirms Lever A/B are additive, not a
   rewrite of the underlying probe law.
5. **Perf.** Rebuild count / step cost over a scripted walk-across-boundary trace, flag on vs off —
   assert no regression outside noise (Lever A adds bounded per-frame probe cost, already the same
   order as the existing `FP_FT_NEAR_GUARD` budget; Lever B adds one `.a` write per baked vertex,
   no new draw calls).

---

## 4. A/B plan (live, on the served build)

1. Pick a tree cluster and a placed house straddling `near_render_radius()` (128 shipped-faceted,
   confirm via pck dump per §0 caveat — don't trust the worktree's 256).
2. Walk directly at it, then directly away, at three speeds (slow walk, sprint/fly-adjacent, and a
   near-instant teleport across the boundary) — repeat 3× each direction/speed.
3. Strafe/oscillate along the boundary itself (perpendicular to the approach vector) for ~5 s.
4. Success criteria, each pass/fail independently recorded:
   - No visible pop/blink/double-image on any straight-line crossing at any speed.
   - No visible flicker during the boundary-oscillation strafe (this is the case most exposed to
     §1.3(a)'s un-hysteresis'd branch edges — the dead-band is the fix under test here
     specifically).
   - Exactly-one-renderer invariant confirmed via telemetry hook (reuse the remote-bridge frame +
     telemetry capture already used for the FARTREE-POLISH investigation
     [[voxiverse-fartree-polish132]] — log `far_alpha` + a near-mesh-presence sample per frame,
     assert never both 0 for > 1 frame and never both 1 for longer than the fade window).
   - No FPS regression (compare worst-frame-ms and p90 across the walk trace, flag on vs off,
     within noise — same methodology as the credit/stream perf memory entries).
5. Regress the existing FARTREE-POLISH / STRUCTURES A/B scenarios (co-location double-render at
   rest, descent hole) to confirm Lever A/B don't reopen those — they were already verified fixed
   by `FP_FT_NEAR_GUARD`/`FP_STRUCT_NEAR_HOLD` and this doc's flags are strictly additive on top.
