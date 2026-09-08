# COSMOS FAR-TIER WALK — unified move-churn diet + credit-independent cross-faded handoff

**Status: DESIGN ONLY — no code changed.** Branch `deploy/perf-plus-sky`, worktree `deploy-cheats`.

This doc unifies the three parallel investigations of this session:

- `docs/COSMOS-GROUND-RENDER-ARCH-DESIGN.md` §6-7 — the 150/238/378 ms walking frames are
  main-thread far-tier rebuild churn (direction **D**), not draw calls; far-trees full rebuild
  ~50-60 ms re-armed every 2 blocks walked, far-structures merged-mesh re-upload same cadence.
- `docs/COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md` — ~285 ms of the worst 378 ms frame is
  unattributed; `FP_WORST_FRAME_ATTR` (`cube_sphere.gd:4257`) is being built in parallel to
  split far-tier-rebuild vs near-VoxelEngine-apply. **Every perf claim in this doc is gated on
  that attribution** — the flicker lever stands on its own regardless.
- `docs/COSMOS-LOD-FLICKER-DESIGN.md` — the tree/house near↔far handoff is a HARD opaque swap
  whose streak machinery is starved by the same stream-credit budget that walking consumes
  (double-render up to ~0.75 s / hard pop on essentially every boundary crossing).

**One root, two composable levers**, separately flaggable so the live A/B attributes each:

| | Lever 1 — MOVE-CHURN DIET (perf) | Lever 2 — XFADE HANDOFF (flicker) |
|---|---|---|
| Flags | `FP_FT_WALK_CALM`, `FP_STRUCT_WALK_CALM` | `FP_FT_NEARCULL_XFADE`, `FP_STRUCT_XFADE`, `FP_STRUCT_HANDOFF_HYST` |
| Fixes | membership-delta vs camera-delta split — a pure walk stops re-committing the merged far meshes | credit-INDEPENDENT bounded probe+streak pass + dither cross-fade + Schmitt dead-band on both tiers |
| Claim gate | `FP_WORST_FRAME_ATTR` live attribution | none — needed regardless of the perf verdict |

Both default `false`, byte-off (off ⇒ current hard-swap / credit-gated / 2-block-rebuild
behaviour byte-identical; FLAT `verify_feature.gd` stays 6042/0).

---

## 1. Ground truth — the as-built rebuild/handoff machinery (file:line)

### 1.1 The step spine (both tiers)

`FacetFarRing._process` steps both tiers with the same three inputs
(`facet_far_ring.gd:1525-1530`):

```gdscript
_far_trees.step(_load_settled, _stream_credit_ok, _ft_cam)
_far_structures.step(_load_settled, _stream_credit_ok, _ft_cam)
```

`_stream_credit_ok` is the StreamLoadController AIMD credit (`facet_far_ring.gd:490-494`) —
the budget that chunk-gen consumes **exactly while walking**, which is why every credit-gated
consumer below starves at the worst moment (flicker doc §1.1).

### 1.2 Trees — the trigger chain

- Rate cap `FAR_TREES_STEP_MS := 250` (`cube_sphere.gd:1057`), then the DELTA gate
  `_rebuild_inputs_changed` (`facet_far_trees.gd:1056-1079`): re-arms on
  `cam_abs.distance_to(_last_rebuild_cam) >= move_thr` with
  `move_thr = FT_DELTA_MIN_MOVE := 2.0` (`cube_sphere.gd:1090`), or `FT_DELTA_MOVE_HYST := 12.0`
  under `FP_FT_MOVE_HYST` (`cube_sphere.gd:1099-1100`) — **already ON live and insufficient**:
  it merely widens the camera-delta threshold, accepting 12 blocks of visual staleness; it does
  not remove the camera term, so a walk still re-arms the FULL ~50-60 ms rebuild
  (`_rebuild_meshes` `facet_far_trees.gd:1247-1334` + `_rebuild_cards` `:1119-1208`, each ending
  in a whole-buffer `MultiMesh.set_buffer` upload `:1202,:1328`).
- The rebuild output is camera-dependent through exactly four terms, all functions of
  `dist(cam, tree)`: **band membership** (mesh `[R0, 448+32)` `:1249-1252,1280`, cards
  `[card_inner−32, 2400]` `:1127-1128,1152`), **fade alpha** (`mesh_fade`/`card_fade`/`thin_alpha`
  `:396-425`, baked per instance into `INSTANCE_CUSTOM.w` `:1195,:1319`), **sink ramp**
  (`sink_ramp` `:431-432`, applied to the instance origin `:1188-1190,:1312-1314`), and
  **nearest-first cap ordering** (only load-bearing when `_capped`/`_mesh_capped`).
- The near-handoff cull `_nearcull_emit` (`:550-578`) is a **boolean** (hide on COVERED
  immediately; restore after `FT_CULL_DWELL := 2` consecutive NOT_COVERED **rebuild passes**,
  `cube_sphere.gd:1153`) — no partial-alpha state exists at this boundary
  (the near-frontier dither term is explicitly dropped under NEARCULL, `:1291-1294`).
- `FP_FT_NEAR_GUARD` (`:668-742`) is the only credit-independent pass: **hide-only**, bounded
  (`FT_GUARD_PROBE_CAP := 64` probes/pass `:57`, 250 ms cadence `:832-835`), hides by **zeroing
  the 12 transform floats** in the CPU buffer snapshot (`_guard_hide_instance` `:708-731`) —
  destructive, so restore stays rebuild-owned (credit-gated, unbounded under starvation).
- Un-hysteresis'd branch edges: `dist < FT_CULL_MIN` (`:553`) and `dist > probe_hi`
  (`:555-557`) are raw comparisons — a player wobbling on the edge flips which branch of the
  state machine runs per pass.

### 1.3 Structures — the trigger chain

- Credit gate `_credit_gate_open = settled and (credit_ok or FP_STRUCT_NEAR_GUARD)`
  (`facet_far_structures.gd:265-266`) blocks the ENTIRE probe+streak+rebuild step at credit 0
  (the guard flag admits the whole step, but then pays the full merged-mesh rebuild — it cannot
  run per-frame like the trees' guard).
- Rate cap `STRUCT_STEP_MS := 250` (`cube_sphere.gd:1247`), then `_inputs_changed`
  (`facet_far_structures.gd:271-287`): re-arms on
  `cam_abs.distance_to(_last_cam) >= STRUCT_DELTA_MOVE` with `STRUCT_DELTA_MOVE := 2.0` (`:29`)
  — the structures twin of the trees' 2-block re-arm, with **no** MOVE_HYST analogue at all.
- A rebuild (`_rebuild` `:400-442`) re-appends every in-band cached bake nearest-first and
  re-uploads ONE merged surface (`_commit_mesh` → `clear_surfaces` + `add_surface_from_arrays`,
  `:444-453`). The bakes themselves are cached by `(root, rev)` (`_ensure_bake` `:457-495`) —
  **the per-rebuild cost is pure concatenation + re-upload of unchanged data** whenever nothing
  but the camera moved.
- The camera enters the merged mesh through exactly two terms: **band/branch membership**
  (`dist > STRUCT_FAR_MAX` `:419`, the `dist < r0` / annulus branches of `_cull_emit`
  `:331,351` and `_probe_pass` `:309-311`) and **nearest-first ordering** (load-bearing only
  under the `STRUCT_FAR_TRIS_MAX` cap `:428-430`). The vertices are ring-local absolute-planet
  coordinates baked once (`:456-489`) — *the geometry itself is camera-independent*.
- The cull is a **symmetric 2-streak** machine (`STRUCT_HIDE_STREAK`/`STRUCT_SHOW_STREAK := 2`,
  `cube_sphere.gd:1251-1252`) advanced **only inside `_rebuild`** (`_cull_emit` called from
  `:421`) — so hide AND show both wait on ≥2 credit-gated rebuilds; there is **no alpha channel
  at all** (`_TAIL` reads only `COLOR.rgb`, `:87-96`) — every transition is a hard pop of a
  whole building.
- `FP_STRUCT_NEAR_HOLD` (`:307-309,331-350`, just merged) fixes only the inside-r0 descent
  drop; the `[r0, r0+64]` walking annulus keeps the full streak-latency + hard-pop exposure
  (flicker doc §2).

### 1.4 Why this is the ONE root

Walking at 5.5 blk/s: the 2-block re-arm fires every ~0.36 s on BOTH tiers → the 250 ms rate
caps admit ~2.75 rebuilds/s each → far-trees ~50-60 ms + far-structures append+re-upload land
as main-thread bursts at ~2-4 Hz — the render-arch doc's predicted 150-ms-median profile —
**and** each starved/completed rebuild is also the only vehicle the handoff streaks ride, so
the same churn+starvation produces the flicker. One machinery, two symptoms, two levers.

---

## 2. Lever 1 — MOVE-CHURN DIET (`FP_FT_WALK_CALM` + `FP_STRUCT_WALK_CALM`)

### 2.0 The law

> **A far-tier re-commit is legal only on a MEMBERSHIP/CONTENT delta** — the emitted far SET
> changed (a facet's records landed/evicted, a structure's rev/registry changed, an edit landed,
> a cull state committed, a band edge was actually crossed) — **never on pure camera
> translation.** The far meshes are world-space; the camera moving does not change their
> geometry. (The [[voxiverse-orbit-perf-farring-churn]] SRC_UNSINK-drift lesson — camera-keyed
> re-derivation of camera-independent data — applied to walking.)

The two tiers need different mechanics because their camera coupling differs (§1.2 vs §1.3):
structures are already geometrically camera-independent (only membership + cap-ordering are
camera terms — replace the camera re-arm with a membership fingerprint); trees additionally
bake `dist`-driven alphas into the buffer (move that term to a per-frame shader uniform, then
the same fingerprint law applies).

### 2.1 Structures — `FP_STRUCT_WALK_CALM`

**Detection of "the far SET is unchanged" (deliverable 2):** `_probe_pass`
(`facet_far_structures.gd:295-323`) already iterates the whole registry (≤ `STRUCT_REG_MAX=256`
records) computing `_structure_dist(rec, cam_abs)` per record, every rate-capped step. Extend
that same loop — zero extra distance computes — to fold a **band fingerprint**: for every
record, classify its distance into a band code and XOR a code-mixed stable hash:

```gdscript
# inside the _probe_pass loop, per rec (new, under FP_STRUCT_WALK_CALM only):
#   code: 0 = FLOOR (dist < r0), 1 = ANNULUS [r0, r0+CULL_ANNULUS],
#         2 = BAND (annulus_top, STRUCT_FAR_MAX], 3 = OUT (> STRUCT_FAR_MAX)
#   band edges evaluated with the Schmitt dead-band (§3.4) keyed on the code latched last pass
#   (_band dict: root -> code) so a razor's-edge camera can't oscillate the fingerprint.
band_fp ^= _cull_mix(_root_hash(root), code)     # reuse the existing hash family (:390-393 + trees :443-446)
```

`band_fp` changes **iff at least one structure crossed a band/branch edge** — the exact
definition of a membership delta for this tier. Cost: one int-mix per record per step (≤256,
4 Hz) — noise.

**Edit sites:**

1. `cube_sphere.gd` (append after `:1281`, the `STRUCT_HOLD_PROBE_CAP` block):

```gdscript
const FP_STRUCT_WALK_CALM := false   # Lever 1: camera-delta re-arm → membership band-fingerprint (walk = zero re-commit)
```

2. `facet_far_structures.gd:271-287` (`_inputs_changed`) — replace the camera term:

```gdscript
# BEFORE (:273)
	or cam_abs.distance_to(_last_cam) >= STRUCT_DELTA_MOVE \
# AFTER
	or (cam_abs.distance_to(_last_cam) >= STRUCT_DELTA_MOVE \
		and (not CubeSphere.FP_STRUCT_WALK_CALM or _capped)) \
	or (CubeSphere.FP_STRUCT_WALK_CALM and band_fp != _last_band_fp) \
```

  (`band_fp` threaded from `_probe_pass` beside `cover_fp`; `_last_band_fp` latched in the same
  `if changed:` block `:280-287`. The `_capped` degrade keeps the shipped camera re-arm
  whenever the tri cap was hit last rebuild — nearest-first ORDERING then decides membership,
  which genuinely is camera-dependent; uncapped, order changes only vertex concatenation order,
  pixel-identical for one opaque unshaded surface.)

3. `facet_far_structures.gd:295-323` (`_probe_pass`) — add the band-code classification + fp
   accumulation per the snippet above (returns `{cover_fp, band_fp}` or writes a member; the
   shipped `cover_fp` computation is untouched, byte-identical off).

**Off-flag byte-identity:** the band dict / fp are computed and read only under the flag; the
shipped `_inputs_changed` disjunction short-circuits identically.

### 2.2 Trees — `FP_FT_WALK_CALM`

Requires `FP_FAR_TREES_DELTA` + `FP_FAR_TREES_FADE` (compile-time shader dependency on the
dither line); no-op without them.

**Step A — move the `dist`-driven alpha out of the buffer into the shader.** Add a
`uniform vec3 cam_pos` (pushed once per step beside `planet_centre`,
`facet_far_trees.gd:852-856` — one `set_shader_parameter`, no rebuild) and evaluate the SAME
fade laws (`mesh_fade`/`card_fade`/`thin_alpha`, `:396-425` — pure smoothstep/lerp, trivially
portable to GLSL with `FAR_TREES_MESH_MAX`/`FADE_*`/`THIN_*` as literals baked into the shader
string) in the vertex shader from `d = distance(MODEL_MATRIX[3].xyz, cam_pos)`. The per-instance
`INSTANCE_CUSTOM.w` then carries only the **cull/streak alpha** (1.0 steady-state; Lever 2's
animation target), and the dither test becomes `> v_fade_dist * v_fade_cull * tier_fade`.
Mechanically this is a `shader_code()`/`mesh_shader_code()` string-splice under the flag —
the exact pattern `FP_FT_SHELL_BAND` already uses (`:263-270`), off ⇒ shipped string verbatim.

  - Edit sites: `shader_code()` `:246-271`, `mesh_shader_code()` `:346-357` (splices);
    `step()` `:852-856` (push `cam_pos`); `_rebuild_cards` `:1169-1181` and `_rebuild_meshes`
    `:1289-1298` (under the flag: skip the CPU `card_fade`/`mesh_fade` evaluation, write
    `custom.w = 1.0` — or the Lever-2 streak alpha — instead of the distance alpha).
  - The **sink ramp stays CPU-side** (rebuild-time, from the rebuild camera): its total range
    is `FT_SINK_MAX := 0.15` blocks over an 80-block ramp (`cube_sphere.gd:1152-1155` region,
    consts `:1149-1151`), so a 16-block-stale camera mis-sinks by ≤ 0.15·16/80 = **0.03 blocks**
    — sub-visible; not worth vertex-position shader surgery.

**Step B — widen band membership by a margin, re-arm on half the margin.** New consts
(`cube_sphere.gd`, after `:1100`):

```gdscript
const FP_FT_WALK_CALM := false     # Lever 1: shader-side distance fades + margin membership (walk = 8× fewer rebuilds)
const FT_CALM_MARGIN := 32.0       # membership margin (blocks) on each camera-coupled band edge
                                   # camera re-arm threshold under the flag = FT_CALM_MARGIN * 0.5
```

At rebuild, every camera-coupled band edge admits `FT_CALM_MARGIN` of slack: the mesh band's
outer keep becomes `dist < d1_hi + FT_CALM_MARGIN` (`:1280`), the card band's inner becomes
`r0 − FT_CALM_MARGIN` (`:1127`) (outer 2400 edge unwidened — `thin_alpha` already holds exit
alpha at `THIN_MIN` sub-pixel cards; a resident-set pop there is invisible). Because the fade
alphas are now evaluated per-frame from the LIVE camera (Step A), every tree inside the widened
set renders at its **exact** current alpha — trees outside the true band but inside the margin
sit at dither-alpha ≈ 0 (fragment-discarded, near-zero fill at those distances). So within a
16-block camera excursion the buffer is a **pure function of membership + content** — skipping
the rebuild is pixel-identical *by construction*, not by tolerance (the difference from
`FP_FT_MOVE_HYST`, which accepted 12 blocks of alpha/band staleness).

  - Edit site `_rebuild_inputs_changed` (`:1056-1067`):

```gdscript
# BEFORE (:1059)
	var move_thr: float = CubeSphere.FT_DELTA_MOVE_HYST if CubeSphere.FP_FT_MOVE_HYST else CubeSphere.FT_DELTA_MIN_MOVE
# AFTER
	var move_thr: float = CubeSphere.FT_DELTA_MOVE_HYST if CubeSphere.FP_FT_MOVE_HYST else CubeSphere.FT_DELTA_MIN_MOVE
	if CubeSphere.FP_FT_WALK_CALM and not (_capped or _mesh_capped):
		move_thr = maxf(move_thr, CubeSphere.FT_CALM_MARGIN * 0.5)
```

  (same `_capped` degrade rationale as structures: under an instance cap, nearest-first
  ordering is membership — keep the shipped threshold. Instance-count headroom for the margin:
  cards +~2·32/2272 ≈ 3 % of band width, meshes +32/320 ≈ 10 % — inside
  `FAR_TREES_CARD_INST_MAX=8192` / `FAR_TREES_MESH_TOTAL_MAX=1024` headroom
  (`cube_sphere.gd:1054-1055`); when it isn't, `_capped` flips and the tier self-degrades to
  shipped cadence.)

**The near frontier (probe annulus) under a 16-block re-arm:** which trees are *in the probe
annulus* `[FT_CULL_MIN, r0+40]` also shifts with the camera. Lever 1 deliberately does NOT try
to fingerprint that — the `_pending_nearcull_fp` (`:584-632`) already re-arms the rebuild on
any probe-visible change (a mesh landing/leaving), and Lever 2's per-frame bounded pass (§3)
owns hide/show at that boundary *without* rebuilds. Deployed together (the recommended
configuration), frontier correctness is frame-bounded regardless of rebuild cadence; Lever 1
alone leaves the frontier at the guard's shipped 0.75-s worst case (same class as today).

### 2.3 Quantified expected rebuild-rate drop

At a 5.5 blk/s walk, 250 ms rate caps, no content events:

| tier | shipped (2-blk re-arm) | + MOVE_HYST 12 (live today) | + Lever 1 |
|---|---|---|---|
| trees full rebuild (~50-60 ms) | ~2.75 Hz (rate-cap-bound) | ~0.46 Hz | **~0.34 Hz** (16-blk) — and each *skipped* step now costs ~0 where today's DELTA check still ran the full rebuild |
| structures append+re-upload | ~2.75 Hz | ~2.75 Hz (no analogue) | **membership events only** — near a village, band-edge crossings per 100 blocks walked ≈ #structures whose r0/annulus/2400 shell you pierce ≈ 5-20 events vs ~275 shipped re-arms → **−90…97 %** |

Main-thread far-tier commit duty while walking: trees ~55 ms × 2.75/s ≈ **150 ms/s → ~19 ms/s**
(−87 %); structures re-upload duty −90 %+. Whether that converts to the measured
worst_ms 150/378 collapse is exactly what `FP_WORST_FRAME_ATTR`'s `wf_*` split decides (the
[[voxiverse-backstop-diet]] lesson: A/B the premise; if worst frames persist with far-tier
rebuilds at ~0 Hz, the residual is the near VoxelEngine apply burst → the `FP_INFLIGHT_GATE`
lane, not this one).

### 2.4 Lever-1 correctness guarantee (deliverable 3)

*Skipping a re-commit never drops a needed far mesh or leaves a stale one*, because every
input that can change the emitted SET is a latched fingerprint/epoch:

- trees: record cache (`_cache_epoch`, bumped on every land/evict `:924,1100,1112`), edits
  (`_current_edits_rev` `:535-536`), near-probe state (`_pending_nearcull_fp` `:584-632`),
  shell-zone flip (`:1066`), cap state (degrade), camera beyond margin/2 (the widened term) —
  any of these ⇒ `_rebuild_inputs_changed` true ⇒ full rebuild, exactly as shipped;
- structures: `reg_count`, `rev_sum`, `edits_rev`, `cover_fp`, `_cull_pending`, `_bake_pending`
  (all shipped, `:272-279`) **plus** `band_fp` (every band-edge crossing) — a genuine
  membership change always re-commits within one `STRUCT_STEP_MS` step;
- and between re-commits the buffers are pure functions of those latched inputs (trees: §2.2
  Step A/B makes the residual camera coupling either shader-live or ≤0.03-blk bounded;
  structures: world-space cached bakes, §1.3) — so the skip is pixel-identical, not "stale but
  tolerable".

---

## 3. Lever 2 — CREDIT-INDEPENDENT, CROSS-FADED HANDOFF

Flags: `FP_FT_NEARCULL_XFADE` (needs `FP_FAR_TREES_NEARCULL` + `FP_FAR_TREES_FADE` +
`FP_FT_NEAR_GUARD`), `FP_STRUCT_XFADE` (needs `FP_STRUCT_FAR`; composes `FP_STRUCT_NEAR_HOLD` /
`FP_STRUCT_NEAR_GUARD` / `FP_STRUCT_BAKE_STAGE`), `FP_STRUCT_HANDOFF_HYST` (dead-band,
independently flippable). New consts (`cube_sphere.gd`, in the respective flag blocks):

```gdscript
const FP_FT_NEARCULL_XFADE := false  # Lever 2a: bidirectional per-frame alpha animator at the near frontier (trees)
const FT_HYST_W := 8.0               # Schmitt dead-band width on the FT_CULL_MIN / probe_hi branch edges
const FT_XFADE_STEP := 0.17          # per-frame alpha step (≈6 frames 0→1; ~0.1 s at 60 fps)
const FP_STRUCT_XFADE := false       # Lever 2b: structures dither-alpha channel + credit-independent streak pass
const FP_STRUCT_HANDOFF_HYST := false# Lever 2c: Schmitt dead-band on the structures r0/annulus/2400 edges
const STRUCT_HYST_W := 8.0
const STRUCT_XFADE_STEPS := 4        # alpha quantisation steps per transition (4 commits max per event)
const STRUCT_XFADE_STEP_MS := 80     # commit cadence while a fade is in flight (bounded: ≤ STEPS commits/event)
```

### 3.1 The shared law

> The probe+streak **decision** advances on a bounded, credit-INDEPENDENT cadence (per render
> frame, probe-capped); only the expensive **commit** stays credit/delta-gated. Every hard
> on/off swap at the near↔far boundary becomes a dither cross-fade driven by **streak
> progress** (0→1 over a fixed frame count), not distance. Invariant: at every frame
> `near_covered OR far_alpha > 0` (never a gap), and `far_alpha` settles to {0,1} within
> `streak + ceil(1/step)` decision passes of the probe stabilising (never a sustained double).

### 3.2 Trees — `FP_FT_NEARCULL_XFADE`

The trees already have per-instance dither alpha (`INSTANCE_CUSTOM.w` + `_ft_dither` discard,
`:214-238`) and a bounded credit-independent buffer-poke pass (`_near_guard` + `_guard_flush`,
`:668-742`). The lever generalises the guard from *destructive hide-only* to a *bidirectional
alpha animator*:

1. **Stop zeroing transforms; animate alpha instead.** `_guard_hide_instance` (`:708-731`)
   currently zeroes the 12 transform floats — irreversible until the next full rebuild (why
   restore is rebuild-owned and starves). Under XFADE it instead steps the custom-`.w` float
   (card `base+15` `:1238`; mesh `co+3` `:1368`) in the existing `_last_buf`/`_last_mesh_bufs`
   snapshots toward a target, by `FT_XFADE_STEP` per pass:
   - target 0 ⇔ probe COVERED (fact ⇒ start immediately, the shipped streak-1 hide law kept —
     the fade itself supplies the visual dwell the flicker doc's "widen HIDE_STREAK" idea
     wanted, without touching the streak law);
   - target 1 ⇔ NOT_COVERED for `FT_CULL_DWELL` consecutive passes (the shipped show streak,
     now advanced per-pass instead of per-credit-gated-rebuild) — **this adds the missing
     show-side guard**: a receding tree's impostor fades back in a bounded ~8 passes instead
     of waiting on 2 starved rebuilds;
   - UNKNOWABLE ⇒ hold current alpha (never flips — the shared invariant).
2. **Pass cadence: every render frame** (drop the `FAR_TREES_STEP_MS` guard throttle `:832-835`
   under XFADE), budget unchanged (`FT_GUARD_PROBE_CAP := 64` probes round-robin `:57` — the
   pass is ≤0.5 ms by the guard's own construction; alpha stepping touches only rows
   mid-transition). `_guard_flush` (`:735-742`) uploads one `set_buffer` per *changed* buffer
   per frame — only while a transition is in flight (bounded duration), zero uploads at rest.
3. **Membership for fade-back:** a hidden (alpha-0) annulus tree must stay RESIDENT in the
   buffer to fade back without a rebuild. `_nearcull_emit` (`:550-578`) under XFADE returns
   `true` (emit) for annulus trees in EVERY cull state, writing `custom.w = 0.0` for
   currently-hidden ones (the guard metadata rows `:1200,:1323` already carry exactly the
   needed (fid, base, mm_sel, slot) tuple). Bounded: the annulus holds ~≤144 trees (guard-cap
   comment `:57`) — noise against the instance caps. Outside the annulus the shipped
   emit/no-emit booleans are untouched (instance-count bounding preserved).
4. **Schmitt dead-band:** the `dist < FT_CULL_MIN` (`:553`) and `dist > probe_hi` (`:556`)
   edges become state-keyed: a tree currently emitted-shown exits its branch only past
   `edge + FT_HYST_W`; one currently hidden/culled re-enters only past `edge − FT_HYST_W`
   (which side you're on wins ties) — no per-frame branch flapping for a player oscillating on
   the boundary (flicker doc §1.3(a)).
5. Composition with Lever 1: under `FP_FT_WALK_CALM` the shader dither is
   `dist_fade(shader) × custom.w` (§2.2 Step A) — the animator drives `custom.w` exactly as
   here; without WALK_CALM the animator multiplies into the baked distance alpha at write time
   (rebuild) and steps the product in the snapshot (visually identical, marginally coarser).

### 3.3 Structures — `FP_STRUCT_XFADE`

Structures need the alpha channel built first (nothing exists today):

1. **Shader** — `_TAIL` (`facet_far_structures.gd:87-96`): under the flag, splice the same
   screen-door discard the shell material already uses (`_SHELL_SHADER` `:123-133` — proven
   gl_compat-safe on this exact merged mesh; no blend-state change, no draw added):

```glsl
// v_col = vec4(COLOR.rgb * voxi_shade(...), 1.0);  →  v_col = vec4(..., COLOR.a);
// fragment(), first line under the flag:
if (_sd_dither(FRAGCOORD.xy) > v_col.a) discard;
```

   Built conditionally in `shader_code()` (`:98-99`) like the trees' splices — off ⇒ shipped
   string verbatim. **Zero memory delta**: `colors` is already a `PackedColorArray` (RGBA
   floats, `bytes` already counts 4×4 per vertex `:491`) — the `.a` lane exists, unused.
2. **Per-structure alpha state** — extend the `_cull` record (`:53-54,340,354`) with
   `alpha: float` (1.0 default). New bounded, credit-INDEPENDENT `_streak_pass(reg, cam_abs)`
   called in `step()` **before** the `_credit_gate_open` return (`:224-231` — the same
   placement law as the trees' guard `facet_far_trees.gd:826-835`): runs the existing
   `_probe_pass` probes (already capped by `STRUCT_HOLD_PROBE_CAP`-class budgets `:309`) plus
   the streak advance currently trapped inside `_cull_emit`-during-rebuild (`:327-367` — the
   streak MOVES here; `_cull_emit` becomes a pure read of `hidden`), then steps each `alpha`
   toward `0` (hidden) / `1` (shown) by `1/STRUCT_XFADE_STEPS` per `STRUCT_XFADE_STEP_MS`.
   Streak counts stay `2/2` — the fade masks the transition, no need to shrink them; the
   `FP_STRUCT_NEAR_HOLD` inside-r0 branch (`:337-350`) keeps its exact semantics (COVERED =
   fact ⇒ immediate hide-*target*; the fade is the only change) — off-HOLD, inside-r0 keeps the
   shipped `hidden=true` semantic, faded.
3. **Fade commits** — a merged mesh can't animate per-structure alpha via a uniform, so a fade
   step IS a re-commit — but a **bounded, event-driven** one: while any alpha is mid-flight
   (`_xfade_active`), `step()` bypasses the credit gate and the `STRUCT_STEP_MS` cadence down
   to `STRUCT_XFADE_STEP_MS`, for at most `STRUCT_XFADE_STEPS` commits per transition event.
   The commit itself is the shipped concatenation with one addition: after
   `colors.append_array(bake["colors"])` (`:432`), patch the appended range's `.a` to the
   structure's current alpha (O(range) float writes). With Lever 1 having removed the ~2.75 Hz
   walking re-commits, these ≤4-per-event commits are the *only* moving-camera commits left —
   net commit rate still falls by ~an order of magnitude.
4. **Residency** — `_rebuild`'s emit gate (`:421`) becomes `alpha > 0.0 or emitted` (the float
   form): a structure mid-fade-out stays in the merged array until it reaches 0 (then drops —
   membership change, one final commit); a structure fading IN enters at its current alpha.
5. **Schmitt dead-band** (`FP_STRUCT_HANDOFF_HYST`) — state-keyed enter/exit on the three
   distance edges: `_cull_emit`'s `dist < r0` (`:331`) / `dist > r0 + CULL_ANNULUS` (`:351`),
   `_probe_pass`'s `below_floor`/annulus mirror (`:309-311`), and (shared with Lever 1's
   `band_fp`) the `STRUCT_FAR_MAX` outer edge (`:419`). Width `STRUCT_HYST_W := 8.0`.

### 3.4 The exactly-one-renderer invariant (deliverable 3)

**No gap** (`near_covered OR far_alpha > 0` at every frame): `far_alpha` decreases only while
the probe reads COVERED — a *fact* (`NearPresence.covered` step 2, `near_presence.gd:46-49`:
positive `is_area_meshed` is trustworthy unconditionally) — so during every frame of a
fade-out the near mesh is present. An alpha-0 state persists only while COVERED holds or
UNKNOWABLE freezes it (the last known state had near present — the shipped safe law); the
instant NOT_COVERED is observed, the show streak advances **per decision pass, not per
credit-gated rebuild**, so `far_alpha` ramps back within `SHOW_STREAK + ceil(1/step)` passes.
The only true-gap window left is the pre-existing "near unloaded, probe not yet run" latency —
now bounded by the per-frame pass cadence instead of unbounded credit starvation.

**No sustained double**: `near_covered AND far_alpha > 0` occurs only (a) inside a deliberate
fade-out, duration ≤ `HIDE_STREAK + ceil(1/FT_XFADE_STEP)` passes (trees ≈ 7 frames;
structures ≤ 2·pass + 4·80 ms ≈ 0.5 s), or (b) while UNKNOWABLE freezes a shown impostor —
identical to the shipped safe-direction hold. The starved 0.75-s-to-unbounded double of §1 is
structurally gone because the decision pass no longer shares the stream-credit budget.

**Settle**: after the probe stabilises, every alpha monotonically reaches {0,1} within the
bound above — asserted by gate G-LODX-3.

---

## 4. Composition matrix (deployed FT_/STRUCT_ machinery)

| shipped flag | interaction |
|---|---|
| `FP_FAR_TREES_DELTA` (`:1089`) | Lever 1 trees rides its gate (prerequisite); the fingerprint/epoch terms are reused verbatim |
| `FP_FT_MOVE_HYST` (`:1099`) | superseded-by-max under `FP_FT_WALK_CALM` (`maxf`, §2.2); still the fallback when capped |
| `FP_FAR_TREES_NEARCULL` (`:1129`) | prerequisite of FT xfade; its emit booleans keep bounding instance counts outside the annulus |
| `FP_FT_NEAR_GUARD` (`:1165`) | generalised by FT xfade (same metadata, same flush law); with xfade OFF the shipped destructive hide-only guard runs verbatim |
| `FP_FT_STALE_REBUILD` (`:1182`) | unchanged — still the credit-0 full-rebuild floor for *content* staleness (new terrain); Lever 2 removes its handoff-latency role |
| `FP_STRUCT_NEAR_HOLD` (`:1277`) | kept; its inside-r0 streak law becomes the alpha-target law of that branch (§3.3.2) — the hold now *fades* instead of popping |
| `FP_STRUCT_NEAR_GUARD` (`:1237`) | subsumed for the handoff (the streak pass is credit-independent by construction); still useful to admit *content* rebuilds at credit 0 — orthogonal, keep |
| `FP_STRUCT_BAKE_STAGE` (`:1278`) | unchanged — fade-in of a never-baked house still waits on the staged drain (addition-only delay, never a removal), then fades in |
| `FP_FT_SHELL_BAND` / `FP_STRUCT_SHELL_BAND` | orthogonal (off-surface zones); xfade passes are skipped in shell mode exactly where the nearcull already is (`facet_far_trees.gd:829-831,869-884`) |

---

## 5. Gates (real-path drivers — the runtime-dead lesson)

Extend `verify_far_trees.gd` / `verify_structures.gd` (both exist, `godot/src/tools/`) plus a
new scripted walk driver; all headless-SceneTree, using the existing debug hooks
(`debug_step`/`debug_rebuild`/`debug_set_cache` `facet_far_trees.gd:1612-1651`, the structures
step with injected Callables) and a scripted `NearPresence` stub:

1. **G-WC-OFF (byte-off identity)** — all four flags false ⇒ the full existing G-FTD/G-FTC/
   G-FTG/G-FTS/G-ST-* suites pass unchanged AND FLAT `verify_feature.gd` 6042/0.
2. **G-WC-TREE (pure translation ⇒ zero re-commit)** — fixed cache/edits/probe-stub; drive
   `debug_step` along a 15-block camera translation in sub-margin steps ⇒
   `rebuild_count()` delta == 0; a 17-block move ⇒ exactly 1; a `debug_set_cache` epoch bump at
   a still camera ⇒ exactly 1 (membership change always re-commits).
3. **G-WC-STRUCT** — registry of ≥3 structures straddling r0/annulus/2400; camera translation
   that crosses NO edge ⇒ `_dbg_rebuild_count` unchanged; translation carrying one structure
   across `r0+CULL_ANNULUS` ⇒ ≥1 re-commit and the merged vert count changes by that bake's
   size; a rev bump ⇒ re-commit within one step.
4. **G-WC-FRESH (no-stale/no-drop)** — after any G-WC-2/3 sequence, compare the live buffers /
   merged arrays against a from-scratch `debug_rebuild` on a fresh tier instance with the same
   inputs: emitted sets must be equal (proves skipping never diverged the committed state).
5. **G-LODX-SCHMITT** — sweep the camera across `[edge − 3·HYST_W, edge + 3·HYST_W]` at step
   sizes 0.1/1/8/32 blocks with a wobble at the edge ⇒ the branch/emit state flips at most once
   per monotone HYST_W window; single-block back-and-forth at the edge ⇒ zero flips.
6. **G-LODX-GAP** — scripted COVERED→NOT_COVERED→COVERED probe sequences under continuous
   motion, `credit_ok = false` THROUGHOUT: assert per simulated frame
   `stub_covered OR far_alpha > 0` (trees: snapshot custom-.w read via `debug_buffer()`/
   `mesh_buffer()`; structures: the `_cull` alpha read-back), never both false.
7. **G-LODX-SETTLE** — after the stub stabilises, alpha reaches {0,1} within
   `streak + ceil(1/step)` passes (trees) / `2 + STRUCT_XFADE_STEPS` steps (structures) —
   still under `credit_ok = false` (the credit-independence proof).
8. **G-WC-PERF** — scripted 200-block walk trace: far-tree rebuild count ≤
   `ceil(200/16) + content_events`; structure re-commits ≤ `membership_events +
   STRUCT_XFADE_STEPS × transitions`; flag-off trace reproduces the shipped ~1-per-2-blocks
   counts (the control).

---

## 6. Live A/B plan

Deploy all four flags individually seddable (the deploy-flag discipline;
confirm served state by pck dump — the FARTREE-POLISH methodology, never worktree consts).
Instrument first: `FP_WORST_FRAME_ATTR` (parallel work) + add per-window rebuild-count deltas
(`ftr_rb`, `st_rb` from `rebuild_count()`/`_dbg_rebuild_count`) to the remote-bridge telemetry
so rebuild *rate* is a first-class A/B observable.

Scenario: a village straddling `near_render_radius()` with a tree line, walked at 3 speeds
(slow walk, sprint, teleport-across), straight in/out ×3 each + a 5-s boundary strafe:

- **Arm A (baseline)**: all four off — reproduce worst_ms median ~150 / flicker.
- **Arm B (Lever 2 only)**: xfade+hyst on, walk-calm off — success = no visible pop/blink/
  double on any crossing (telemetry: never `near∧alpha=0` >1 frame, never double past the fade
  window); worst_ms expected ~unchanged (this arm isolates the flicker claim from the perf
  claim).
- **Arm C (Lever 1 only)**: walk-calm on — success gated on `wf_*`: far-tier rebuild rate
  drops ~10×, and the walking worst_ms median falls from ~150 toward the at-rest ~26 ms IF the
  attribution assigned the gap to far-tier rebuilds; if worst_ms does NOT move, the `wf_*`
  snapshot names the residual (near apply burst ⇒ `FP_INFLIGHT_GATE` lane) — the lever is then
  still kept for the duty-cycle win, but the jerkiness verdict transfers.
- **Arm D (both)**: the ship candidate — no flicker AND the perf delta of C, plus regression of
  the shipped scenarios (co-located double-render at rest, descent hole — `FP_FT_NEAR_GUARD`/
  `FP_STRUCT_NEAR_HOLD` A/Bs) to confirm strict additivity.

---

## 7. Files referenced

- `godot/src/world/facet_far_trees.gd` — step/credit/guard `:802-889`, DELTA gate `:1056-1079`,
  nearcull `:550-578,584-632`, guard `:668-742`, card rebuild `:1119-1208`, mesh rebuild
  `:1247-1334`, fade laws `:396-432`, shaders `:188-357`, debug hooks `:1612-1651`.
- `godot/src/world/facet_far_structures.gd` — step/gates `:211-266`, `_inputs_changed`
  `:271-287`, probe/cull `:295-367`, rebuild/commit `:400-453`, bake cache `:457-495`, shaders
  `:83-141`.
- `godot/src/world/facet_far_ring.gd` — step spine `:1525-1530`, credit plumbing `:489-494`.
- `godot/src/world/near_presence.gd` — the shared tri-state probe (COVERED-first law `:35-57`).
- `godot/src/cosmos/cube_sphere.gd` — `FT_DELTA_MIN_MOVE:1090`, `FP_FT_MOVE_HYST:1099-1100`,
  `FAR_TREES_STEP_MS:1057`, band caps `:1051-1055`, `FT_CULL_MIN/DWELL:1152-1153`,
  `FP_FT_NEAR_GUARD:1165`, `FP_FT_STALE_REBUILD:1182`, `STRUCT_*:1237-1281`,
  `FP_WORST_FRAME_ATTR:4257`, `FP_INFLIGHT_GATE:2714`.
- Sibling docs: `COSMOS-GROUND-RENDER-ARCH-DESIGN.md`, `COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md`,
  `COSMOS-LOD-FLICKER-DESIGN.md` (this doc implements their §7-D / rank-1-adjacent / §3 items
  as one flag family).
