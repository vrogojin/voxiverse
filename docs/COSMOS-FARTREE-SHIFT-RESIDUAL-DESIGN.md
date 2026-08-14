# COSMOS FARTREE-SHIFT-RESIDUAL — why far trees STILL read "a few blocks lower" after FP_FAR_TREES_ALIGN

Status: DESIGN (task #120 residual + task #130 dwell-stall — ONE combined fix). Author: Fable
architect session 2026-08-13.
Parent doc: COSMOS-FARTREE-ALIGN-DESIGN.md (the shipped #120 weld+cull). Companions:
COSMOS-FAR-TREES-DESIGN.md (the tier), COSMOS-LOD-LADDER-SMOOTH-DESIGN.md (V2 near-fill sink).
Proposed flags: `FT_SINK_MAX` retune (behind the existing `FP_FAR_TREES_ALIGN`),
`FP_FT_XFADE_COMPL` + `FP_FT_TRUNK_LEGIBLE` (new, default false, byte-identical off), and the
§5 dwell-stall repair (inside the existing `FP_FAR_TREES_NEARCULL`+`FP_FAR_TREES_DELTA` guards —
no new flag).

---

## 1. What was verified about the LIVE build (do not re-litigate)

All of this was measured against the served artifact, not the repo:

- **The fix is live.** The served `build/web/index.pck` (this deploy worktree, Aug 13 02:02) was
  loaded headlessly and its constant map dumped: `FP_FAR_TREES_ALIGN = true`,
  `FP_FAR_TREES_NEARCULL = true` (and CARDS/MESH/FADE/SNOW/COLORFIX/DELTA all true), `FT_SINK_MAX
  = 1.0`, `FT_SINK_R0 = 208`, `FT_SINK_R1 = 288`. Hypothesis "fix inert live" is **dead**.
- **The card band IS covered by ALIGN.** The rebuild-time sink ramp is applied identically in the
  card path (facet_far_trees.gd:904-906) and the mesh path (facet_far_trees.gd:1014-1016), off the
  same shared enum anchor (facet_far_trees.gd:702-704). Hypothesis 1 (cards missed by the weld) is
  **dead by code inspection**.
- **The near trunk base convention is right.** tree_gen.gd:331-334: trunk occupies `[gy+1, gy+t]`;
  the oak/birch canopy ring wraps the top TWO trunk layers (tree_gen.gd:337-340), so the **clear
  visible trunk below the canopy is `t − 2` blocks** (t ∈ 4..6, tree_gen.gd:24-25 ⇒ 2..4 blocks).
  Hypothesis 3 is dead (and G-FTA-1 pins it against the live world).
- **The weld works where the ramp is zero — measured on the user's own frame.** The reported
  screenshots (grassy plain, pos −12007, 55, 5945, alt 51) were re-captured by the live session
  (frame-…-002, same viewpoint) and pixel-classified (trunk/canopy/grass ASCII maps + a
  flood-fill blob census). With the real camera FOV (75° vertical, player.gd:345 ⇒ f ≈ 352 px
  on the 960×540 frame; ground row y ≈ 272 + 352·51/d):

  | screen y | camera d | zone | measured |
  |---|---|---|---|
  | 412+ | < 128 | near voxel field | near trees, full trunks |
  | 358–412 | 128–208 | **ramp-zero** far band (sink 0) | far trees show **full 2.3–3.7-block trunks**, bases ON the grass — the E1–E4 weld holds live |
  | 334–358 | 208–288 | sink ramp | trunks partially visible (≈1–2 blocks shorter), mixed |
  | 311–334 | 288–460 | saturated sink + 448 handoff | **0 of ~40 real tree blobs show a single trunk pixel** — canopy balls sitting on/in the grass |

  (The only "trunk" hits past y 330 were shoreline sand misclassified — checked by hand.)

So: the shipped weld eliminated E1–E4 exactly as designed, **and the user is right anyway** — the
entire far population beyond ~290 blocks reads as trunkless canopies flush with the ground, while
everything nearer shows proud trunks. At alt 51 the ramp zone spans only ~24 screen pixels, so the
eye sees a *line* beyond which all trees drop. That is the residual.

---

## 2. Root cause of the residual — three stacked effects, quantified

### R-A (dominant, systematic): the §4.3 deep-band sink saturates to a FULL block — by design — against ground that is NOT sunk

`sink_ramp(d) = FT_SINK_MAX·smoothstep(208, 288, d)` (facet_far_trees.gd:378-379,
cube_sphere.gd:960-962) buries **every** far tree past 288 by 1.0 block. The §4.3 premise was
"deep in the band the visible ground is the sunk V2/far tier". Measured, that premise is **false
on the plain**: the visible mid/far ground welds to true block-top height (the ramp-zero band's
trees stand base-exact on it, §1 row 2; #83/#89/#113 welded the far tiers up). The sunk tier the
premise pointed at — `V2_NEARFILL_SINK = 6.0` on hop ≤ 1 tiles (cube_sphere.gd:1643,
facet_smooth_v2.gd:537) — sits 6 blocks *under* the visible surface precisely so it is **not**
what you see; burying trees "onto" it buries them into the ground you *do* see.

Arithmetic of the visible damage: oak/birch clear trunk = `t − 2` = 2–4 blocks (§1). Sink 1.0
leaves 1–3. At d ≥ 300 one block subtends ≤ 1.2 px (f/d = 352/300) and the trunk is 1 px wide —
after JPEG/scaling, a 1–3 px × 1 px brown stem on green is at the edge of visibility. The sink
eats the block that made the difference between "short trunk" and "no trunk". Net read: **canopy
sitting on the grass ⇒ "the far tree is a few blocks lower"** (the eye assigns the missing trunk
height to a vertical drop).

### R-B (handoff band): the 448 mesh↔card cross-dither is IN-PHASE — coverage collapses to 50%, trunks dissolve first

Both dither shaders use the **same** hash on the **same** `FRAGCOORD.xy`
(`_ft_dither`, card: facet_far_trees.gd:191/204; mesh: facet_far_trees.gd:282/297), and both keep
a pixel iff `dither ≤ v_fade`. At the 448 handoff the fades are complementary *in value*
(mesh `1 − smoothstep(416, 480, d)` — :996 under NEARCULL, `mesh_fade`'s `fout` :349 otherwise;
card `smoothstep(416, 480, d)` — `card_fade` :368-369), but because the keep-*sets* are nested
(`dither ≤ 0.5` for both at the midpoint), the union coverage is `max(f_mesh, f_card)`, **not 1**.
At mid-handoff half the tree's pixels show grass straight through; a 1-px-wide trunk loses half
its pixels and effectively vanishes. The intended cross-dissolve (one representation's discards
exactly filled by the other's keeps — trivially achievable since ALIGN co-locates them) was never
what the code did. Census correlate: the trunkless-big-blob cluster sits in [416, 480].

### R-C (floor, irreducible by placement): sub-pixel trunk legibility

Past d ≈ 350 (1 block < 1 px) a 1-block-wide trunk cannot survive rasterisation + nearest-sampled
32² card tiles (facet_far_trees.gd:42, :1016-1020) regardless of placement. Even a perfectly
placed tree reads as a canopy blob. This is not a bug in the weld — it is a *legibility* property
of the art — but it multiplies R-A: with the sink removed, 2–4 blocks of trunk (2–4 px at 300–450)
are back above the detectability floor; with it, 1–3 px straddle it.

**Not implicated:** the NEARCULL band (no double/ghost trees measured anywhere in the frame; the
restore-dwell stall — a *different* defect, a persistently MISSING tree, is task #130 and is root-caused + fixed in §5 of this doc).
The lateral E4 fix holds (no offset measurable). `NearPresence` wiring is live
(world_manager.gd:431, :3582).

---

## 3. Fix design

### P0-a — retune the deep-band sink: `FT_SINK_MAX 1.0 → 0.15` (one line, under the existing flag)

cube_sphere.gd:960. `sink_ramp` is only evaluated under `FP_FAR_TREES_ALIGN`
(facet_far_trees.gd:904, :1014), so byte-off parity is untouched; the ramp machinery, gates and
record format all stay. 0.15 keeps a hair of contact bias (anti-shimmer where the far ground
crosses the base at grazing angles) while returning the full trunk to view. Not 0.0 outright: a
strict zero risks visible base-gap sparkle on slope cells; 0.15 < any visual quantum at d > 208.

Why not keep 1.0 and "reshape" the ramp: there is no d beyond which the burial becomes correct —
the visible far ground tracks true height at every distance the tree tier draws on (that is the
whole point of the far-ground weld work). The ramp's *structure* survives only as the blend-in
lever for P2 (below) and as an emergency constant if a genuinely sunk visible tier ever returns.

Risk R1 (honest): during warmup/descent transients the visible mid-band ground CAN briefly be a
sunk tier (V2 near-fill at −6 before the dense band lands). Trees will float over it for that
transient, where today they float 5 instead of 6 — not a regression class, but the live A/B must
eyeball a descent. If it reads badly the escape is a *state*-conditional sink (off-surface/warmup
only), not a distance ramp.

### P0-b — `FP_FT_XFADE_COMPL`: make the 448 cross-dither complementary (one line per shader)

Under the flag, the CARD fade shader inverts its dither sample:
`if (1.0 - _ft_dither(FRAGCOORD.xy) > v_fade) discard;` (facet_far_trees.gd:204; mesh :297
unchanged). Then card-keep = `dither > 1 − f_card` = exactly the mesh-discard set when
`f_card = 1 − f_mesh` — union coverage 1.0 across the whole handoff, trunks and canopies stop
dissolving. The far-end hash-thinning statistics are unchanged (keep-fraction still `v_fade`;
which half of the pixels survive is irrelevant to thinning). Flag default false ⇒ shipped shader
string verbatim (the FADE splice is character-identical), byte-off holds.

### P1 — `FP_FT_TRUNK_LEGIBLE`: keep the trunk above the pixel floor (optional, cosmetic)

Two independent micro-changes, both under one flag, both zero-draw:

1. **Card raster**: paint the trunk column ≥ 2 texels wide in the 32² side tile
   (`_raster_tile`, facet_far_trees.gd:1184+) so nearest-sampling cannot skip it.
2. **Mesh shader**: inflate trunk-flagged verts (UV2.x < 0.5) radially in local XZ by
   `0.35 · clamp((dist_to_camera − 256)/192, 0, 1)` in the vertex shader (`CAMERA_POSITION_WORLD`
   is available; the trunk-stretch block :266 already branches on the flag vert class). Distant
   trunks render ~1.4 blocks wide — above the 1-px floor out to ~500.

This attacks R-C. Ship it only if the P0 A/B still reads "stemless" past 350 — it changes art, so
it goes to the user's eyeball explicitly.

### P2 — `FP_FT_GROUNDLOCK` (deferred; design pinned here so it isn't re-derived)

On *relief* (not this plain) the far ground is an interpolated surface (V2: 8-block cell pitch,
block-top-exact only at nodes — facet_smooth_v2.gd:51) and can locally sit above/below a tree's
column top, burying/floating a base-exact tree by the local interpolation error. If post-P0
mountain scenes still show buried/floating far trees: at rebuild time, deep-band base :=
`anchor + r̂·clamp(h_vis − h_anchor, −2, +2)` blended by the existing `smoothstep(FT_SINK_R0,
FT_SINK_R1, d)`, where `h_vis` is the **unsunk** baked V2 node height bilinearly sampled at the
record's `(bx, bz)` (tile pos grids are resident in `FacetSmoothV2._tiles`; add the per-slot
`V2_NEARFILL_SINK` back before sampling — locking to the *sunk* near-fill would re-create R-A at
−6). Tile absent ⇒ delta 0 (anchor, never worse than P0). Cost: one dict hit + bilinear per
emitted instance per rate-capped rebuild — µs-scale. NOT scheduled now: the measured plain shows
h_vis ≈ h_anchor, so P2's payoff is unproven until a relief A/B says otherwise.

### Flags / consts summary

```
cube_sphere.gd:
  const FT_SINK_MAX := 0.15            # was 1.0 — §3 P0-a (read only under FP_FAR_TREES_ALIGN)
  const FP_FT_XFADE_COMPL := false     # §3 P0-b complementary handoff dither
  const FP_FT_TRUNK_LEGIBLE := false   # §3 P1 trunk width floor (card raster + mesh vert inflate)
```

Byte-off: P0-a is inside the ALIGN guard; P0-b/P1 are new default-false flags whose off-paths are
the shipped strings/geometry verbatim. gl_compat-safe: no new uniforms except reading the built-in
camera position; no draw/instance count changes anywhere.

---

## 4. Gates (extend verify_far_trees.gd) + live A/B

Headless:

- **G-FTR-1**: `sink_ramp(FT_SINK_R0) == 0` (unchanged law) and `sink_ramp(FT_SINK_R1 + ε) ==
  FT_SINK_MAX == 0.15`; emitted card+mesh origins == anchor − r̂·sink_ramp(d) (existing G-FTA-3
  re-pinned to the new const).
- **G-XDC-1**: CPU-simulate both keep-predicates over a 64×64 FRAGCOORD grid at fades
  {0.25, 0.5, 0.75} with `f_card = 1 − f_mesh`: assert union coverage == 1.0 under
  FP_FT_XFADE_COMPL and == max(f) without it (pins both the fix and the shipped defect so the
  in-phase class can't silently return). Assert shader-string parity flag-off.
- **G-TRK-1** (P1 only): card side-tile trunk column ≥ 2 opaque texels at every row below the
  canopy; mesh shader string contains the inflate term iff flag on.
- **G-OFF**: both new flags off + FT_SINK_MAX reverted in a scratch branch ⇒ card/mesh
  `debug_buffer()` bit-identical to shipped (the standing byte-off suite).

Live A/B (redeploy, same cheat flag set; the viewpoint is pinned and reproducible — pos −12007,
55, 5945, alt 51, yaw toward the lake):

1. Re-run the blob census (tools: the session's blobscan script — flood-fill dark canopies,
   count trunk pixels beneath) on a fresh frame: **deep-band (screen y ∈ [311, 334]) blobs of
   width ≥ 6 px with ≥ 1 trunk pixel: 0% today → expect ≥ 50%** (spruce/jungle shapes legitimately
   hide trunks; 100% is not the bar).
2. Pan/descend across the band: no tree-base step at the y≈358 (d=208) line; trunk length visually
   continuous from the near field to the horizon fade.
3. 448-handoff strip (y ∈ [311, 315] at this alt — better: walk 300 blocks toward the lake so the
   handoff sits mid-screen): no half-dissolved "ghost lattice" trees under FP_FT_XFADE_COMPL.
4. Descent from orbit: watch for floating trees over transient sunk ground (risk R1) — if seen,
   file the state-conditional sink follow-up, do not re-raise FT_SINK_MAX.
5. fps/draws/vmem unchanged (no structural cost anywhere in this design).

---

## 5. Task #130 — the NEARCULL+DELTA restore-dwell stall (combined into this fix)

### 5.1 Root cause, verified against the code

The cull state machine can only advance **inside a real rebuild**, but the DELTA gate's
fingerprint cannot see a rebuild is still *needed*:

1. `_compute_nearcull_fp` (facet_far_trees.gd:524-548) XORs `_cull_hash` over trees probed
   **COVERED only** (:546-547). It is a pure read (dwell advances only in `_nearcull_emit`,
   by design — the doc comment at :520-523 even says so).
2. A near mesh unloads under a static camera: the tree flips COVERED→NOT_COVERED, its hash drops
   out of the fingerprint — **one** drift → `_rebuild_inputs_changed` (:796) arms **one** rebuild.
3. In that rebuild `_nearcull_emit` sees NOT_COVERED on a hidden tree and advances the restore
   streak to 1 (:511-515) — still `< FT_CULL_DWELL = 2` (cube_sphere.gd:964) → stays hidden.
4. The fingerprint is now stable again (the tree is not COVERED; mid-streak state contributes
   nothing), camera/epoch/edits unchanged → **no second rebuild ever fires** → the streak freezes
   at 1 → the far tree stays culled while the near tree is gone: a **persistent missing tree**,
   until the camera moves ≥ `FT_DELTA_MIN_MOVE` (2 blk). DELTA off ⇒ every step rebuilds ⇒ streak
   completes ⇒ the stall is strictly a NEARCULL×DELTA composition bug.
5. Why no gate caught it: every G-FTC-* drives `debug_rebuild` (:1300-1310), which **bypasses**
   the DELTA gate; the G-FTD suite never enables NEARCULL. The composed path had zero coverage.
   (`debug_step` :1316-1331 — the DELTA-gated driver — already exists and is the hook §5.3 uses.)

### 5.2 Fix — make the fingerprint see cull-machine progress (state-fold, no new flag)

Fold *pending-restore state* into the §5.4 fingerprint so the DELTA gate re-arms exactly while the
state machine can make progress, and goes quiet the moment it cannot. In `_compute_nearcull_fp`,
per probed annulus tree (h = `_cull_hash(fid, bx, bz)`, `st` = probe result, `dw` =
`_cull_dwell.get(key, -1)`):

```
COVERED                               → fp ^= h                       # shipped term, unchanged
NOT_COVERED and dw >= 0 (mid-restore) → fp ^= _mix(h, dw)             # drifts as the streak advances
UNKNOWABLE  and dw >= 1 (mid-restore) → fp ^= _mix(h, dw) ^ SALT_U    # constant while frozen
anything else                         → no term                       # shipped behaviour
```

`_mix(h, s)` = one more avalanche round over `h + (s+1)·0x9E3779B9` (same arithmetic family as
`_cull_hash` :383-386); `SALT_U` a fixed constant. Properties, each mapping to a failure mode:

- **Stall dead**: after the first rebuild the tree's term is `_mix(h, 1)` ≠ its pre-rebuild term
  (`_mix(h, 0)`) ⇒ drift ⇒ next step rebuilds ⇒ streak 2 ⇒ restore. Total rebuilds per restore
  event: `FT_CULL_DWELL` + 1 final (the erased entry's term vanishing) — **bounded**, then quiet.
- **No UNKNOWABLE churn**: a mid-streak tree gone UNKNOWABLE (view ramp-down, module gap)
  contributes a *constant* term ⇒ fingerprint stable ⇒ zero rebuilds while frozen (the DELTA
  promise kept); the U→NOT_COVERED flip changes the term (SALT_U drops) ⇒ drift ⇒ progress
  resumes. Without SALT_U this transition would be invisible and the stall would return through
  the UNKNOWABLE door.
- **Steady state byte-identical**: with no restore in progress every term is the shipped
  COVERED-only term — same fp values, same rebuild cadence, same perf. Flags off ⇒ the function is
  never called (step :627-628) — byte-off untouched.
- Probe-cap note: the fp pass's early return at the cap (:536-537) can drop a mid-restore tree's
  term and cause drift-churn only in >256-tree annuli — same pre-existing cap semantics as
  shipped (R1 in the parent doc); no new behaviour class.

Rejected alternative (for the record): re-arming `_rebuild_inputs_changed` whenever any
`_cull_dwell` value > 0. Simpler, but a permanently-UNKNOWABLE mid-streak tree would then rebuild
every STEP_MS forever — exactly the static-camera stall FP_FAR_TREES_DELTA exists to kill. The
state-fold is quiet under UNKNOWABLE by construction.

### 5.3 Gate — G-FTC-5, NEARCULL **through** DELTA (the missing composition coverage)

Drive `debug_step` (:1316 — NOT `debug_rebuild`), both flags on, stubbed near-query, static
camera + fixed cache/edits throughout:

1. Stub COVERED → step → tree culled (0 instances). Extra static steps → **no** rebuilds
   (fp stable — pins steady-state quiet).
2. Flip stub to NOT_COVERED → run static steps: assert the tree's instance is restored within
   `FT_CULL_DWELL` rebuild-steps, and `rebuild_count()` increments by ≤ `FT_CULL_DWELL + 1`
   total, then further static steps rebuild **zero** times (bounded + quiescent).
3. Mid-streak UNKNOWABLE freeze: COVERED → NOT_COVERED (one step, streak 1) → UNKNOWABLE for N
   steps: assert zero rebuilds and still hidden (frozen, no churn) → NOT_COVERED again: assert
   restore completes. Pins the SALT_U transition.
4. Byte-off: NEARCULL on / DELTA off ⇒ per-step rebuilds restore in `FT_CULL_DWELL` steps
   exactly as shipped; both off ⇒ existing G-OFF byte parity.

---

## 6. Honest verdict

- This is **not** a card-band structural gap and **not** a broken weld — E1–E4 are fixed and
  measurably exact live in the ramp-zero band. The residual is (a) a **1-line over-tuned
  constant** (`FT_SINK_MAX` — the deliberate deep-band burial whose premise stopped being true
  when the far-ground tiers got welded to true height), (b) a **real 1-line shader bug** (in-phase
  cross-dither halving coverage at the 448 handoff), and (c) a **sub-pixel art floor** that no
  placement change can beat (optional P1).
- The #120 gate suite could not have caught this: G-FTA-1/3 asserted the anchor and the ramp
  *shape*, which are both correct — nothing asserted that the saturated ramp is visually
  indistinguishable from a height bug, and nothing asserted handoff coverage. G-XDC-1 closes the
  second class permanently; the census-based live check closes the first.
- Task #130 is a genuine composition bug (NEARCULL's dwell can only advance inside a rebuild;
  DELTA's fingerprint could not express "a rebuild is still needed") with zero gate coverage on the
  composed path — the §5.2 state-fold makes the fingerprint a faithful progress signal and G-FTC-5
  pins the composition (bounded rebuilds, UNKNOWABLE-quiet, restore within FT_CULL_DWELL).
