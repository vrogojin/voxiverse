# COSMOS LOD-DROPOUT — commit-before-hide / last-good-resident residency design

**Bug (user-reported):** trees AND buildings VANISH for moments — up to ~30 s — when the LOD
ladder switches steps. Random/intermittent, worst during/after de-orbit or fast movement.

**This is the "gap/residency" fix.** It is deliberately composable with two sibling designs in
flight: `docs/COSMOS-SURFACE-ENTRY-SPIKE-DESIGN.md` (the shell RE-EMIT **spike** at the
surface↔offsurf crossing — a *prewarm/pacing* fix at a different altitude band) and
`docs/COSMOS-FAR-EDIT-DEBOUNCE-DESIGN.md` (debounced far re-bake on **edit**). §7 maps the
overlaps. All new behaviour is behind new byte-off `FP_*` flags (§5).

---

## 1. Root cause — verified against source (all cites are this worktree)

The common root: **a tier is hidden/blanked on a transition, and the replacement tier's commit
is gated behind stream credit** — which collapses to 0 during de-orbit / fast movement
(AIMD ×0.5 per tick on overload with a zero-snap below 0.1, `stream_load_controller.gd:6,19,143-147`;
forwarded as the boolean `_stream_credit_ok` into every far-tier step,
`facet_far_ring.gd:493-494,1526,1530,1659-1660`) — with **no "keep the old tier resident until
the new one is proven committed" guarantee anywhere in the ladder**. Recovery is +0.1/tick under
sustained headroom, so a stressed client sits at credit 0 for tens of seconds — exactly the
observed tail. Three concrete mechanisms, all live in the served build (arm flags confirmed ON:
FP_FT_SHELL_BAND, FP_FT_STALE_REBUILD, FP_STRUCT_SHELL_BAND, FP_STRUCT_CARDS,
FP_STRUCT_CARD_ALT_BAND, FP_STRUCT_LOD, FP_TEX_BAKE_WORKER, FP_BG_PREBAKE, FP_FT_NEAR_GUARD,
FP_STRUCT_NEAR_GUARD, FP_STRUCT_REG_EPOCH):

### M1 — tree `_stale` hide-latch held hostage by starved credit
- Zone O (orbit) latches `_stale = true` (`facet_far_trees.gd:786-792`); the plain
  offsurf path latches it too (`:794-795`).
- `_apply_visibility` shows the tier only when NOT `_stale` (`:772`, `:780`, `:796`) —
  "correct-or-nothing" (COLORFIX §4.2).
- `_stale` clears ONLY at the end of a **completed** rebuild (`:887-888`), and that rebuild is
  credit-gated (`:842-843`).
- The one credit-0 escape, `_stale_override` (`:894-897`), requires **camera moved >
  `FT_STALE_MOVE` = 32 blk AND ≥ `FT_STALE_MS` = 2000 ms** (`:58-59`). A **parked** descent
  (user stops to look around) never satisfies the move conjunct ⇒ the tier stays hidden until
  credit returns — unbounded, up to the full credit-recovery tail (~30 s).

### M2 — un-baked-skin handoff (trees + buildings)
- Above the hide line the fine-map SKIN owns trees (canopy speckle) and, under FP_STRUCT_LOD,
  house roofs (`cube_sphere.gd:1280,1301`). The tree card tier dissolves over
  [`FT_SHELL_FADE_ALT`=520, `FT_SHELL_HIDE_ALT`=600] (`cube_sphere.gd:1254-1255`;
  driven per step at `facet_far_trees.gd:820-824`); structure cards over
  [`STRUCT_CARD_FADE_ALT`=2000, `STRUCT_CARD_HIDE_ALT`=2400] (`cube_sphere.gd:1464-1465`;
  `facet_far_structures.gd:472-492`). **Neither hide consults whether the target facet's skin
  is actually baked.**
- The skin bakes lazily under a 5 ms/frame budget (`FACET_TEX_BAKE_BUDGET_MS`,
  `cube_sphere.gd:2667`) with a **single** web worker (`WEB_BAKE_WORKERS := 1`,
  `facet_tex_baker.gd:37`) and a single-in-flight gate (`_job_inflight`,
  `facet_tex_baker.gd:201,628-654`) — ~1 facet/s on web. An un-baked facet's texels stay
  alpha 0 ⇒ the shader falls back to the flat vertex-colour ring — **no canopy, no roof**
  (coverage sentinel, `facet_tex_baker.gd:234-244`). Residency is `_baked[fid]`
  (`facet_tex_baker.gd:45`); prewarm covers only the setup-time emitted set
  (`facet_tex_baker.gd:321-324`).
- Aggravator: FP_BLOCK_LOD_ORBIT **freezes the baker entirely at orbit** (`set_frozen`,
  `facet_tex_baker.gd:528-531,537-538`), so a de-orbit into fresh terrain arrives with a stone-
  cold queue exactly when the handoff needs it.
- The visible disc inside the card band at h≈600 spans ~π·2400²/417² ≈ **100+ facets**; at
  1 facet/s a cold queue is minutes deep ⇒ up to (and beyond) the observed 30 s of speckle-less
  biome-flat terrain where trees/roofs should be.

### M3 — near-handoff restore streak frozen at credit 0
- A far tree is culled when NearPresence reports COVERED (`facet_far_trees.gd:565-567`);
  RESTORE requires `FT_CULL_DWELL` = 2 (`cube_sphere.gd:1212`) **consecutive NOT_COVERED probes
  advanced only inside a real rebuild** (`:568-576`; the #130 state-fold `:606-631` re-arms the
  DELTA gate but cannot conjure a rebuild the credit gate refuses). Structures mirror it with
  `STRUCT_HIDE_STREAK`/`STRUCT_SHOW_STREAK` = 2 (`cube_sphere.gd:1349-1350`;
  `facet_far_structures.gd:952-966`), advanced only in `_cull_emit` (rebuild-owned).
- So a parked camera at credit 0 cannot advance the streak ⇒ the far twin stays hidden after
  the near tier unloaded. FP_FT_NEAR_GUARD is **cull-only, never un-hides**
  (`facet_far_trees.gd:660-667`); trees have **no** `_cull_pending` latch (structures do:
  `facet_far_structures.gd:868,911-915`), so trees stall hardest.

### Structures — what is ALREADY plugged (correction to the shared brief)
With **FP_STRUCT_NEAR_GUARD ON** (served), `_credit_gate_open` returns `settled` alone
(`facet_far_structures.gd:833-834`) — the structures **step is already credit-independent**.
And under FP_STRUCT_CARD_STAGE the staged snapshot keeps the **old resident set rendering**
through a fill (`:653-662` "the resident old snapshot renders", swap at `:729-743`) with a
0.7 s wake fade (`:496-504`; `STRUCT_WAKE_FADE_S`, `cube_sphere.gd:1481`) — i.e. Stage-3 card
residency across the version-drift rebuild **is** last-good-resident. The residual structure
gaps are: (a) the node re-shows on a zone cross with `visible_instance_count` still 0 /
buffer stale until the first commit (`:453-461,477-490` set visibility regardless of buffer
content); (b) the un-baked-skin handoff at 2400 (M2); (c) the settle gate; and (d)
**FP_STRUCT_NEAR_HOLD is NOT in the served arm** — inside r0 the shipped path drops the far
model on distance alone while the near build lags a descent (`:930-937`), the classic
"house vanishes as I approach it". §5 ships it in the same arm.

---

## 2. THE INVARIANT — commit-before-hide / last-good-resident

> **A tier transition may remove tier A from the view only when tier B's replacement content
> is PROVEN COMMITTED (buffer uploaded / skin texels baked) for the view being handed over.
> Until then tier A's last-good geometry stays resident and visible — stale-but-plausible
> always beats absent.**

This is the far-tier analogue of the close-up tier's own law ("a promoted facet shows the
coarser base map until its layer is ready → no hitch, no hole", `facet_tex_baker.gd:82-84`)
and of REG_EPOCH staging (§1 correction). The ladder violates it in exactly the three places
above. Applied per handoff:

| Handoff | Today | Under the invariant |
|---|---|---|
| Trees offsurf→onsurf / O→B (`_stale`) | hide until a credit-permitted rebuild | show the **frozen last-good CARD rung** (cards are valid at any band; the band-sensitive mesh rung stays hidden) + the §3 floor bounds staleness to ≤ ~2 s |
| Trees near→far restore (M3) | streak frozen at credit 0 | pending-restore latch + §3 floor advances it |
| Cards→skin, trees @600 & struct-cards @2400 (M2) | altitude-only hide | **readiness-gated** hide: cards hold until the target facets' skin is baked (§4), prewarm makes the hold short |
| Struct zone re-show | node visible, buffer possibly empty | first-commit gate: keep `visible_instance_count`'s last-good buffer; never zero it on a zone flip (verify only — staging already provides this under S4) |
| Struct near approach (r0 floor) | distance-only drop | ship FP_STRUCT_NEAR_HOLD (exists, off) — hold until COVERED probe (`:930-949`) |

Concretely for trees (new flag `FP_FT_LASTGOOD`, byte-off):
- `_apply_visibility` zone S / zone B / binary paths (`facet_far_trees.gd:772,780,796`): when
  `_stale` is latched AND a last-good card buffer exists (`_last_buf` non-empty, the same
  CPU snapshot the guard already edits, `:703-742`), show `_mmi` (cards) anyway; keep the mesh
  rung hidden until the first completed rebuild (its band membership is what COLORFIX §4.2
  protects against). The FT_NEAR_GUARD keeps running (`:826-835`), so a stale card standing
  over an arrived near mesh is still healed credit-independently — the one visual hazard of
  showing stale cards is already covered by an existing, served, cull-only mechanism.
- Zone O is exempt: above `FT_SHELL_HIDE_ALT` the skin owns the view by design; the fix there
  is §4's readiness gate, not stale display.

Bounded cost: zero new draws (the card MMI was already allocated/visible in the shipped happy
path); no new allocation (reuses `_last_buf`); one extra branch per `_apply_visibility`.

---

## 3. THE CREDIT-INDEPENDENT REBUILD FLOOR (fixes M1 + M3)

New flag `FP_FT_STALE_PARKED` (requires FP_FT_STALE_REBUILD, already served-ON).

**3.1 Wall-clock-only override.** `_stale_override` (`facet_far_trees.gd:894-897`) drops the
`FT_STALE_MOVE` conjunct: fire on `now − _last_rebuild_wall_ms ≥ FT_STALE_MS` **alone** (keep
`FT_STALE_MS` = 2000 ⇒ the same ≤0.5 Hz floor, now guaranteed for a *parked* camera too).
Under the flag:

```
override := settled ∧ ¬credit_ok ∧ (elapsed ≥ FT_STALE_MS)
            ∧ (moved > FT_STALE_MOVE  ∨  _stale  ∨  _ft_cull_pending)
```

The third conjunct-group is the cost bound: a parked camera with nothing latched and no
restore pending does **not** re-admit rebuilds (and even when the override opens, the DELTA
gate `_rebuild_inputs_changed` (`:871-872,1051-1056`) still short-circuits a bit-identical
rebuild — the floor admits at most one *real* rebuild per 2 s, and only when an input actually
drifted). This is the same "rare, throttled" envelope FP_FT_STALE_REBUILD already ships; we
only remove the parked-camera blind spot.

**3.2 Trees pending-restore latch** (`_ft_cull_pending`, the converse of the cull-only guard —
the structures' `_cull_pending` idiom, `facet_far_structures.gd:911-915`, ported): in
`_compute_nearcull_fp` (`facet_far_trees.gd:584-632`), which already probes every annulus tree
per step under DELTA, set `_ft_cull_pending = true` whenever a probe disagrees with committed
visibility — NOT_COVERED on a dwell-held key (restore wants to advance) or COVERED on a shown
tree (hide wants to advance). Pure read, no streak mutation (the streak still advances only in
`_nearcull_emit`, preserving "consecutive rebuilds" semantics, `:568-576`). The latch feeds
§3.1's override and OR-folds into `_rebuild_inputs_changed`, so a frozen streak now drains at
the floor rate: worst-case restore latency = `FT_CULL_DWELL` × max(`FAR_TREES_STEP_MS`,
`FT_STALE_MS`) ≈ **4 s** instead of unbounded.

**3.3 Structures**: no change needed for the step gate (already open under
FP_STRUCT_NEAR_GUARD, `:833-834`) — §3 for structures is *verification only* (G-LG-RES below
asserts the property holds end-to-end, including through BAKE_STAGE/CARD_STAGE drains).

---

## 4. THE SKIN PREWARM / READINESS GATE (fixes M2)

New flags `FP_SKIN_READY_GATE` and `FP_SKIN_HANDOFF_PREWARM` (independent; best together).

**4.1 Readiness predicate** on FacetTexBaker (cheap dict lookups):

```
handoff_ready(fid) := _shot_baked.has(fid) if _shot_on else _baked.has(fid)
ready_frac(fids)   := |ready| / |fids|      # over a supplied facet set
```

`_shot_baked` (`facet_tex_baker.gd:67`) is the right surface when FP_PAGES_SHOT serves —
canopy/roof pixels exist only in the g1 shot bake (`:362-368,434-441`); `_baked` (`:45`) is
the g0 floor otherwise.

**4.2 Gate the hide on readiness.** The tier_fade drivers become readiness-aware:
- Trees (`facet_far_trees.gd:820-824`): compute the **handoff set** = facets whose surface
  centre is inside the card band footprint of the current camera (reuse the `_last_wanted`
  set — it is exactly this, `:1013-1049`). If `ready_frac < SKIN_READY_MIN`, clamp
  `tier_fade ≥ SKIN_HOLD_FADE` and treat zone O as zone B up to a hard ceiling
  `FT_SHELL_HOLD_MAX_ALT` (default 900): the cards keep rendering above 600 while the skin
  bakes underneath. Above the ceiling the hold releases unconditionally (orbit economics +
  NEVER-OOM: the card instance cap and `FAR_TREES_BYTES_MAX` ledger already bound the held
  tier; the ceiling bounds its *duty*). Symmetrically on descent the zone-O→B boundary is
  crossed `SKIN_HANDOFF_MARGIN_ALT` (80) early so enumeration+rebuild start before the skin
  hands over — the frozen-set/enum cold-start (`:818-819` early return) stops costing the
  first visible seconds.
- Structure cards (`facet_far_structures.gd:472-492`): same clamp on the czone-1 fade with
  `STRUCT_CARD_HOLD_MAX_ALT` (default 2800) — only when FP_STRUCT_LOD serves (otherwise there
  is no roof skin to wait for and the hold would be pointless).

The gate degrades safely: if the baker reference is unwired, `ready_frac` returns 1.0 ⇒
shipped behaviour verbatim.

**4.3 Prewarm the projected set — view-facets-first queue priority.** 1 facet/s cannot fill a
100-facet disc reactively (§1 M2 math), so reprioritize rather than add throughput:
- New unit class **"handoff"** in `_select_worker_unit` (`facet_tex_baker.gd:659-688`),
  slotted **after** close-up and band (the tiers the player is looking at up close must not
  starve — the task's explicit budget constraint) but **before** the g1 shot cursor and g0
  global coverage: when the camera altitude is inside
  [`FT_SHELL_FADE_ALT` − `SKIN_HANDOFF_MARGIN_ALT`, `FT_SHELL_HOLD_MAX_ALT`] (or the struct
  band analogue), serve un-ready facets from the handoff set nearest-emit-axis-first.
- Un-freeze early: FP_BLOCK_LOD_ORBIT's `set_frozen(false)` should flip at de-orbit
  **commitment** (falling below orbit hold), not at skin handover — giving the baker the whole
  descent (~tens of seconds) of lead time. This composes with (does not duplicate) the
  surface-entry design's shell prewarm: that one warms the *near shell* at OFFSURFACE_Y;
  this warms the *skin pages* at 600-900/2400-2800 (§7).
- Budget unchanged (5 ms/frame, single worker, check-before-unit). Is 1 facet/s enough *with*
  prewarm? For the common case yes: a descent from orbit to h=600 takes long enough to bake
  the ~30-40 facets actually inside the **frustum-weighted** handoff set (nearest-axis
  ordering front-loads what the player sees); the readiness gate (§4.2) is the correctness
  backstop for the tail — the view is *never* handed to an un-baked facet, it just holds
  cards a little longer. The two halves are belt and braces; neither alone suffices.

---

## 5. Flags, consts, byte-off contract

All new flags default **false** in `cube_sphere.gd` (the served arm turns them ON via the
deploy_cheats CS_FLAGS sed / CLITE_FLAGS env, per the established pipeline):

```gdscript
const FP_FT_LASTGOOD := false          # §2: show frozen last-good CARDS while _stale (mesh rung stays hidden)
const FP_FT_STALE_PARKED := false      # §3: wall-clock-only credit-0 floor + pending-restore latch (needs FP_FT_STALE_REBUILD)
const FP_SKIN_READY_GATE := false      # §4.2: card→skin hide gated on baked-skin readiness (trees + struct cards)
const FP_SKIN_HANDOFF_PREWARM := false # §4.3: baker "handoff" unit class + early un-freeze
const SKIN_READY_MIN := 0.9            # §4.2 ready_frac threshold before the hide may complete
const SKIN_HOLD_FADE := 0.35           # §4.2 tier_fade floor while holding (cards stay clearly present)
const SKIN_HANDOFF_MARGIN_ALT := 80.0  # §4.2/4.3 early-arm band below the hide line (blocks)
const FT_SHELL_HOLD_MAX_ALT := 900.0   # §4.2 hard ceiling for the tree-card hold (duty bound)
const STRUCT_CARD_HOLD_MAX_ALT := 2800.0
```

Plus: flip the **existing** `FP_STRUCT_NEAR_HOLD` into the served arm (§1 correction (d)) —
it is precisely this design's invariant at the r0 floor and already implemented+gated.

**Byte-off contract**: every new read is behind its flag const (the codebase's uniform idiom —
e.g. `facet_far_trees.gd:178-183`); unconditional writes limited to leaf ints/bools that are
only READ under a flag (the `_note_rebuilt` pattern, `:899-904`). Off ⇒ the FLAT gate stays
**6042/0** and all existing G-FT*/G-ST* gates hold bit-exact. New-flag families ship ON via
`CLITE_FLAGS` env per arm (no source byte drift in the A/B).

---

## 6. Verify-gate extensions + telemetry

Extend `verify_far_trees.gd` / `verify_far_structures.gd` (headless, scripted `step()` drives
with `settled=true, credit_ok=false` — the credit starve is a *parameter*, no controller
mocking needed):

- **G-LG-RES** (invariant): drive an offsurf→onsurf flip at credit 0 with a warm cache;
  assert every post-flip step satisfies `card tier visible ∨ rebuild completed this step` —
  no hidden-with-no-replacement window longer than one step. Mirror for structures across a
  staged snapshot fill (assert `visible_instance_count > 0` throughout).
- **G-LG-FLOOR** (§3.1): parked camera (constant `cam_abs`), credit 0, `_stale` latched ⇒
  assert a real rebuild (`_dbg_rebuild_count` drift, `facet_far_trees.gd:145`) within
  `FT_STALE_MS` + `FAR_TREES_STEP_MS`; and the negative: nothing latched/pending ⇒ zero
  rebuilds over 10 s (the cost bound).
- **G-LG-RESTORE** (§3.2): stub `_near_query` COVERED→hide, flip to NOT_COVERED, hold credit
  0 + camera parked ⇒ tree restored within `FT_CULL_DWELL × FT_STALE_MS` + one step.
- **G-SKIN-GATE** (§4.2): un-baked handoff set, camera scripted up through 600 ⇒ assert
  `tier_fade ≥ SKIN_HOLD_FADE` and `_mmi.visible` until `bake_facet` commits the set, then the
  fade releases within one step; and the ceiling: at `FT_SHELL_HOLD_MAX_ALT` the hold releases
  regardless.
- **G-SKIN-PRI** (§4.3): with camera in the handoff band and a dirty global cursor, assert the
  next N completed bake units are handoff-set fids (queue order), and close-up/band units
  still pre-empt them (the budget-protection property).

**Telemetry for the live A/B** (rides the existing shell/tex telemetry channels): per tier a
`gap_ms` accumulator — wall time in the state (tier hidden ∧ replacement not ready) — plus
`gap_worst_ms` and a `hold_ms` (time the readiness gate held cards). The bug is *directly* the
`gap_ms` trace: the A arm should show the 2-30 s spikes, the B arm ≤ ~2 s worst. Watch via the
`?remote` bridge counters (bare-URL feel + counters, not frame-time — the observer-effect
lesson).

---

## 7. Composability with the sibling designs

| Touch point | This design | Surface-entry-spike | Edit-debounce | Conflict? |
|---|---|---|---|---|
| Credit rail (`facet_far_ring.gd:1526,1530`) | read-only (`credit_ok` param semantics unchanged; override is tier-local) | may pace/pre-warm around the crossing | — | No — neither mutates `_stream_credit_ok` |
| `facet_far_trees.gd` step/gate | `_stale_override` + `_apply_visibility` + fp pass | none expected (its band is OFFSURFACE_Y) | — | keep §3 edits inside the existing STALE_REBUILD block to minimize merge surface |
| `facet_tex_baker.gd` queue | new "handoff" class after cu/band, before shot/coverage | may prewarm the *shell*, not the baker | inserts debounced re-bake units | Order law to agree on: **cu > band > handoff > edit-rebake > shot > coverage** (edit re-bakes are cosmetic-latency-tolerant; handoff gaps are the user-visible bug) |
| `set_frozen` (orbit) | un-freeze earlier on descent | — | — | No |
| Flags | 4 new + FP_STRUCT_NEAR_HOLD | its own | its own | separate byte-off families; any subset composes in an arm |

---

## 8. Staged build order (cheapest-first) + effort

| Stage | What | Fixes | Effort | Risk |
|---|---|---|---|---|
| **S1** | `FP_FT_STALE_PARKED`: wall-clock floor + `_ft_cull_pending` latch (§3.1-3.2) | M1 (parked case) + M3 | ~0.5 d (a conjunct drop + a ported latch + G-LG-FLOOR/RESTORE) | Low — reuses served STALE_REBUILD envelope |
| **S2** | Ship `FP_STRUCT_NEAR_HOLD` in the arm + G-LG-RES structures verification (§1(d), §3.3) | houses-vanish-on-approach + proves Stage-3 residency | ~0.5 d (arm change + gates only) | Low |
| **S3** | `FP_SKIN_READY_GATE` (§4.1-4.2) | M2 correctness (no un-baked handover) | ~1 d | Med — new baker↔tier query plumbing; degrade-to-shipped when unwired |
| **S4** | `FP_SKIN_HANDOFF_PREWARM` (§4.3) + early un-freeze | M2 latency (hold becomes short) | ~1 d | Med — queue-order law shared with edit-debounce (§7) |
| **S5** | `FP_FT_LASTGOOD` frozen-card stale display (§2) | M1 residual (stale-visible instead of ≤2 s hidden) | ~1 d | Highest visual risk (stale fades/positions ≤2 s) — last, needs live A/B |

S1+S2 alone convert the unbounded 30 s dropout into a ≤ ~2-4 s heal and are nearly free;
S3+S4 close the skin handoff; S5 closes the last visible beat. Each stage is a separate flag —
live A/B can bisect any regression to one stage.
