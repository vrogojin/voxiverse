# COSMOS — floor_under ↔ surface_y fall-through: root cause + fix design

Status: DESIGN (no code). Author: Fable (architecture). Date: 2026-08-06.
Defect: the player falls under the visible ground and gets buried (live: radial alt −17,
~24 blocks below the true surface; measured pair `floor_under = −12.1` vs `surface_y = +11.9`
at the same nominal facet/column — player.gd:1750). Band-aids deployed: `FP_TP_FLOOR_WELD`
(dev-teleport-only), `FP_DESCENT_FACET_RESYNC` (non-adjacent drift only). Root unaddressed.

---

## 1. Root cause

**The two funnels are pure-identical; the lie is a cross-frame read.** `floor_under` and
`surface_y` disagree live because they are evaluated against the mutable pair
**(active facet, lattice position)** while that pair is *transiently inconsistent* — the raw
`(x, z)` numbers of the player's pose, interpreted in a *different facet's* lattice frame,
denote a **different physical column** (facet frame offsets are decorrelated by up to ±32768
blocks). The deep value (−12.1) is simply the *other* column's real surface (e.g. an ocean
floor, g ≈ −15, plus lift); the +11.9 is the player's true column. Both funnels are right —
about different places.

### 1.1 Why the pure functions can never disagree (verified, not assumed)

Both funnels resolve through one law at a *fixed* state:

- `surface_y` (world_manager.gd:3674) = `effective_height(xi,zi) + 1 + _datum_lift(xi,zi)`;
  `effective_height` (:1549) → `col_height` (:1566) → `TerrainConfig.height_at` (:667) →
  `analytic_column_profile` (:1203) → `column_profile` → `facet_profile` (:1027) — pure f64
  over the frozen atlas + noise.
- `floor_under` (world_manager.gd:3699) scans `cell_value_at` (:1249) →
  `TerrainConfig.generated_cell` (:1269) → the **same** `column_profile` (same facet-scoped
  memo key `Vector3i(facet,x,z)`, terrain_config.gd:784) → `resolve_cell`; then
  `FacetAtlas.junction_modify` (facet_atlas.gd:749); both add the **same**
  `_datum_lift(xi,zi)` (:3677 vs :3706/:3737). Same facet + same column ⇒ same answer.

Measured falsifications of the local-term suspects (probe:
`godot/src/tools/probe_seam_tilt.gd`, run headless against the real atlas):

1. **Datum (`_datum_lift`/`FP_DATUM_BAKE`) — exonerated.** It is stateless f64 arithmetic on
   the frozen frame (facet_atlas.gd:471), not a lazy bake; both funnels call it with identical
   `(fid, x+0.5, z+0.5)`. No stale/absent path exists. (`datum_shift`/`FP_RADIAL_DATUM` is
   retired-off and returns 0, facet_atlas.gd:448.)
2. **Junction domain mask — exonerated for the deep-floor signature.** All 6·24²·4 = 13,824
   seam planes have own-side y-coefficient **B > 0** (probe: 13824 vs 0): every facet domain
   *narrows* with depth (tilt |B|/|∇h| = 0.024–0.033), so a past-ridge column is masked at
   **all** depths — `floor_under` then exhausts to its fallback
   `effective_height+1+s` (:3776), which *equals* `surface_y`. Safe by accident. A brute-force
   hunt over 6,336 near-ridge columns (own_dist ∈ [−3, +1], 8 facets incl. the observed 348)
   found **zero** columns where the content scan tops below the profile.
3. **`FP_VIEWER_RELIEF_REACH` / `FP_FARRING_APPLIED_COVER` / far-render milestone — ruled
   out.** Collision is analytic; those flags touch mesh emission/cover extents only. Nothing
   feeds `_datum_lift` or the funnels. (They *do* explain why the neighbour's ground is
   *visible* at the fatal column — see §1.3.)

This is exactly why headless never reproduces: at any *consistent* (facet, pose) the functions
agree by construction.

### 1.2 The stateful mechanism (the actual killer)

The crossing protocol is **two-phase and only eventually consistent** (player.gd:135-144):
`WorldManager.maybe_cross_facet` (world_manager.gd:2394) commits
`TerrainConfig.set_active_facet(B)` inside `_commit_facet_change` (:2522-2536 — followed by a
long fallible pipeline: redesignate/pool/far-ring/restream), and only *afterwards* does the
player re-express the pose via `apply_reframe` (player.gd:779-781). Pose/frame consistency is
healed **at the start of the next physics frame** (`_heal_frame_desync`, player.gd:429 — the
G-REENTRY fix; the live 11,081-block teleport was this same class). Between the commit and the
heal, every `floor_under`/`surface_y`/`blocked` call interprets stale lattice numbers in the
new frame ⇒ reads the wrong physical column.

What turns a one-frame window into a *persistent* landing lie is the **re-fire band**: any
position where the boundary law that *placed/kept* the player on facet A disagrees with the
crossing law (`own_dist < −FACET_CROSS_HYST`, world_manager.gd:2427) makes the crossing
re-fire **every physics frame** (documented + measured in player.gd:2515-2526: the grow=0.5
polygon resolver accepts columns with own_dist ∈ (−0.6, −0.1) — 288 such columns in this
atlas; the player "RE-crosses to the neighbour every physics frame, and the post-teleport
fall/settle re-reads surface_y on the crossed (deep, un-reframed) neighbour column → sinks
into the seafloor and stays"). Other entrances to the same band, still open in general play:

- **corner containment-deferral / corner-commit slack** — a committed corner landing may sit
  up to `FACET_CORNER_SLACK = 2.0` past another ridge (world_manager.gd:96, :2385), and the
  cooldown-void path re-commits when `own_dist < −1` (:2423) — oscillation-prone states;
- **crossing-pipeline aborts** — facet flipped, dict never applied (the class
  `_heal_frame_desync` exists for; the *current* frame's `_move` already consumed the lie);
- **any external `set_active_facet`** (dev ops, re-entry restore, resync) not atomically
  paired with the pose re-expression.

During a descent through such a state, `_move`'s landing query
(`terrain_floor = world.floor_under(...)`, player.gd:1748) on wrong-phase frames returns the
neighbour column's real-but-irrelevant surface (deep fill/seafloor). The player tunnels the
true surface and settles buried. **Column-specific** because it needs (a) a re-fire band
column (sub-block boundary disagreement — data-dependent) and (b) a *deep* aliased column in
the other lattice (ocean/valley — data-dependent). **Live-only** because it needs the mutable
state to interleave across frames — no pure gate samples that.

### 1.3 Why the ground is visible where physics says air

The near mesh renders only the active facet's domain (`junction_modify` masks foreign cells at
both window exits), but the far/LOD/skin tiers (`FP_FARRING_FULL_COVER`,
`FP_FARRING_APPLIED_COVER`, block-LOD rings) draw the *whole planet* — the neighbour's true
surface is on screen at the fatal column. The player visibly falls "through the ground" that
no active-facet physics owns at that instant.

---

## 2. Fix design (ranked; ROOT + GUARD recommended together)

### 2.1 ROOT — `FP_QUERY_FRAME_GUARD` (reconcile the *frame*, the real fix)

The datum needs no reconciling (§1.1) — the **frame** does. Make cross-frame interpretation
impossible for the physics funnels:

- Player passes its pose stamp `_pos_fid` (player.gd:144) into the analytic queries it makes
  with `position`-derived coordinates: `floor_under`, `surface_y`, `blocked`, `ceiling_scan`
  (new optional trailing arg `pos_fid := -1`; −1 ⇒ shipped behaviour, byte-identical).
- Inside `WorldManager`, under `const FP_QUERY_FRAME_GUARD := false` (cube_sphere.gd): if
  `pos_fid >= 0 and pos_fid != TerrainConfig.active_facet()`, re-express the query point
  **once** via `FacetAtlas.reframe_position64(pos_fid, active, x, y, z)` (f64-exact,
  facet_atlas.gd:522) before scanning. A wrong-phase call then reads the **same physical
  column** by construction — the whole class (teleport band, ping-pong, pipeline aborts,
  rogue facet flips) is dead, not per-entrance patched.
- Cost: one int compare per call; one 18-flop reframe only in the (rare) desync case.
- **Placement (FablePhys hardening #2):** stamp-check ONCE at each funnel entry, never per
  cell — the reframe must live strictly on the mismatch path so the steady state adds one
  int compare and stays out of the phys budget reclaimed in #70. And declare an owner
  against `_heal_frame_desync` (player.gd:429): the guard reframes the *query*, the heal
  reframes the *pose next frame* — the guard must never mutate `position`/`_pos_fid`
  (read-only re-expression), so the two can't ping-pong a pose across frames.

This composes with — does not replace — `_heal_frame_desync` (which still fixes the *pose*
for motion) and keeps `maybe_cross_facet`'s hysteresis/containment untouched.

### 2.2 GUARD — `FP_FLOOR_SURFACE_WELD` (generalized surface weld, belt-and-suspenders)

Generalize `FP_TP_FLOOR_WELD` from "dev-teleport column, 3-block proximity" to **every**
landing, inside `floor_under` (world_manager.gd:3699), just before returning a found floor:

```
const FLOOR_WELD_EPS := 2.0   # > max legitimate in-cell deficit: shaped-span (≤1) + smoothing/snow headroom — derived, not tuned
if found_play_y < surface_play_y - FLOOR_WELD_EPS and not _edit_columns.has(Vector2i(xi, zi)):
    return surface_play_y        # un-edited column: topmost solid == surface, per the no-caves law
```

- **The epsilon is load-bearing (FablePhys hardening #1).** On un-edited columns
  `floor_under` sits *legitimately fractionally below* `surface_y`: a shaped/slope surface
  cell returns its in-cell span top (< 1.0 at some footprints), snow fill composes a partial
  span, and an open-water column wades to the smoothed seafloor (`g + local_top` — the
  verify_feature water contract) while `surface_y` is `effective_height + 1`. A bare `<`
  would fire on every smoothed slope and every swim, popping players onto phantom floors.
  `FLOOR_WELD_EPS = 2.0` (one full-cell span + smoothing/snow headroom) keeps those
  contracts intact while still catching every real incident (the class produces 10-70-block
  gaps, never < 2). Each legitimate-deficit case gets its own no-fire gate assert (§3).
- **Correctness argument (no false clamp).** The world is heightmap-only — in an *un-edited*
  column the topmost solid is exactly `effective_height` (or higher via trees/placements,
  which the clamp never touches: it fires only when floor < surface − EPS). A legitimate
  below-surface stand exists **only** inside dug shafts/tunnels — which make the column
  edited, and `_edit_columns` (the existing O(1) per-column edit index,
  world_manager.gd:3200-3233) then skips the clamp, preserving shipped behaviour exactly.
  Water: `height_at` returns the topmost *solid* (seafloor), so `surface_y` tracks the scan's
  own answer within the smoothing span — inside the epsilon, swimming/sinking unchanged.
- **Perf.** `floor_under` is hot, but the clamp adds one memoized column-profile read
  (`analytic_column_profile` — O(1) hit on the shared per-column memo the scan already warms)
  plus one Dictionary lookup. Negligible against the existing per-cell scan.
- **Limit (why it is the belt, not the fix).** If floor *and* surface are consistently wrong
  (both read the same stale facet — the non-adjacent drift case), the clamp is a no-op; that
  class stays owned by `FP_DESCENT_FACET_RESYNC`. If the *surface* read is the wrong-phase one
  and the floor right, the clamp direction (`< surface` → raise) can lift onto a wrong-column
  surface for one frame — bounded, self-corrects on the healed next frame, and cannot bury
  (it only ever raises toward *a* surface). ROOT removes these residues entirely.

**Recommendation: ship both.** ROOT kills the mechanism; GUARD converts any future unknown
entrance into a safe landing instead of a burial (the failure mode becomes "stand on the
surface", never "tunnel"). Both are `const FP_* := false`, byte-identical off — every guard
is either a new default-off arg or gated inline.

## 3. Flags, touch points, gate

- `cube_sphere.gd`: `const FP_QUERY_FRAME_GUARD := false`, `const FP_FLOOR_SURFACE_WELD := false`.
- `world_manager.gd`: `floor_under` / `surface_y` / `blocked` / `ceiling_scan` optional
  `pos_fid` + reframe preamble (§2.1); the weld clause in `floor_under`'s two return paths
  (probe loop :3737 and tail :3772) — NOT the no-floor fallback :3776 (already = surface_y).
- `player.gd`: pass `_pos_fid` at the `position`-based call sites (:592, :1748, :2612, the
  `blocked` per-axis calls, `_dev_land_clamp` :2421).
- Gate (falsifiable, headless — the mechanism is now reproducible without a browser):
  `verify_floor_weld.gd` —
  1. FLAT byte-off: full `verify_feature` 6042/0 with both flags false.
  2. **Repro assert (must FAIL pre-fix):** on facet A near a ridge, capture
     `surface_y(x,z)`; flip `set_active_facet(B)` *without* reframing (the desync harness
     pattern from G-REENTRY-CONTINUOUS); assert raw-`(x,z)` `floor_under` now diverges
     (reproduces the live −12/+12 pair headlessly for the first time); then assert the
     `pos_fid=A` guarded call returns the physical-column floor (agreement restored).
  3. Weld: over the 288-column teleport band (own_dist ∈ (−0.6, −0.1)) drive a scripted
     descent per column; assert landing y == surface_y ± ε, and assert a dug-shaft column
     still lands on the shaft floor (no false clamp).
  4. Weld no-fire cases (the epsilon contracts): a smoothed-slope footprint, a snow-filled
     cell, and an open-water column each assert the weld does NOT fire (flag ON bit-identical
     to OFF at those columns) — pinning FLOOR_WELD_EPS against the legitimate-deficit set.

## 4. Live verification (deploy-pipeline constraint)

`deploy_cheats.sh` git-checkout-reverts **uncommitted** edits to `cube_sphere.gd` and
`remote_bridge.gd` on every deploy (memory: the 2026-07-31 diag silently never shipped).
Therefore: the flag flips AND any live diagnostic **must be committed** on the deploy branch
before running the pipeline — or live in a file outside those two. Suggested live drill via
the remote bridge: (a) geo-teleport to the known band column (lat 8 / lon 2) with
`FP_DEV_TP_REFRAME` temporarily OFF to re-open the teleport entrance, assert telemetry alt
never < −1; (b) a fast-flight ridge/corner soak (the general entrance) with a committed
telemetry line `floor−surface` per tick, asserting |Δ| ≤ 1 except inside edited columns.

Incident probe (`FP_FALLTHRU_PROBE`, FablePhys design, adopted): in `_move` after the floor
query, when `terrain_floor < surface_y − 3`, push a rate-limited (1/s) telemetry record:
{column, active_fid, the player's `_pos_fid` stamp, facet_of_dir owner, own_dist for all 4
slots under BOTH active_fid and _pos_fid, floor, surface_y, feet_y, vy, crossing-cooldown
counter, teleport/flight markers}. Each record is self-diagnosing: this design predicts
active_fid ≠ _pos_fid (or oscillation across records) with the column interior under the
pose-consistent fid and garbage/far under the stale one — one live fall names the entry
machine (race vs cooldown vs corner vs teleport) or falsifies the theory.

## 5. Composition with existing flags

- `FP_TP_FLOOR_WELD`: subsumed for un-edited columns by the weld; both are max-toward-surface
  holds — compose idempotently, no double-apply (keep it until the weld soaks, then retire).
- `FP_DESCENT_FACET_RESYNC`: orthogonal class (non-adjacent stale facet, funnels agree-and-
  wrong); unaffected — the weld is a no-op there by design (§2.2), the resync still fires.
- `FP_DEV_TP_REFRAME`: remains the correct resolver for the teleport *entrance*; ROOT makes
  the game safe even where a resolver/crossing disagreement survives.
- `maybe_cross_facet` hysteresis/cooldown/corner-commit: untouched — ROOT makes their
  deferral states *safe* rather than trying to make them *impossible*.
- Perf follow-up (separate ticket, from the adjudicated FP_FLOOR_DOMAIN_WELD proposal): a
  fully-masked column makes `floor_under` grind ~1000 cells to reach the fallback that
  equals `surface_y` anyway (§1.1 item 2 is the correctness proof). A masked-surface-cell
  early-out (`cell_value_at` air at `effective_height` while unmasked `generated_cell` is
  solid ⇒ return `effective_height+1+s` immediately) is provably behaviour-identical and
  saves the scan — same cost family as the #70 phys-budget work.
