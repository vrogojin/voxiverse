# COSMOS-SEAM-METRIC — the corner-spawn seam misalignment, diagnosed and quantified

Status: **DIAGNOSIS + SCOPED FIX DESIGN (no code changed) — one gate pending.** The user
additionally reports that *block values themselves* differ when returning to the original
face; a full-BLOCK-ID path-independence gate (all 24 edges + a straddle band — the existing
72/0 gate covered only the height profile) is being run to confirm or refute a value
divergence. §7 records this document's prediction for that gate and the candidate mechanisms.
The §2–§4 geometry stands either way; the §5 "residual lie is the documented §4.6 budget"
conclusion is **HELD** until the gate lands.
**RESOLUTION (July 2026):** the block-value report was confirmed as §7 mechanism 2 (the
corner-quadrant home-face dependence), and the user chose the terrain-preserving fix over
§5's ocean mask + spawn move — see `docs/COSMOS-CORNER-CANONICAL.md` (the canonical position
fold), which supersedes §5 items 1–2; §2–§4 (the placement measurements and the no-frame-bug
finding) remain authoritative. Investigates the user-reported
cross-face seam misalignment at the initial curved spawn: is it an initial-frame **origin
bug** that the first home-face flip normalises (the user's hypothesis), or the **documented
ground-truth metric lie** (cube_sphere.gd §4.6)? Answer, with numbers: **it is the lie — but
evaluated at the one point on the planet where the lie is two orders of magnitude worse than
everywhere else (the cube corner), which is exactly where the game currently spawns the
player — compounded by a genuine, fixable content crack: the M5 corner mask that three code
comments claim exists is not implemented.** No origin/frame inconsistency exists; the fix is
spawn placement + the corner mask, not frame surgery.

Read together with: `docs/COSMOS-PLANET-TOPOLOGY.md` (§2.2 metric, §4.6 accepted lies, §5.3
corner design), `cube_sphere.gd` (§4.6 block, lines 312-328; `fold_cell` 348;
`CORNER_SEA_R` 30), `cosmos_bend.gd` (§3.4 bend), `terrain_config.gd`
(`_curved_profile` 582, `worker_fold_column` 700, `find_spawn` 1828),
`world_manager.gd` (`_ready` 87-135, `maybe_flip_home_face` 809),
`verify_cosmos_seam.gd` (Opus's 72/0 value-determinism gate — trusted input here).

All numbers below were computed with the repo's own math (a throwaway headless probe driving
`CubeSphere.face_cell_to_dir` / `fold_cell` / `world_point`, the exact `CosmosBend` sagitta
formula, and `TerrainConfig._curved_profile` heights on the custom editor binary; the probe
script was deleted after the run — §6 tells Opus how to regenerate it as a verify gate).

---

## 1. What was reported, what was already proven

- **User (live, curved build):** at initial spawn (chart `i_org = j_org = 0`, home face 4,
  player near the *worst corner*), neighbouring faces' terrain is misaligned across the face
  borders; near chunks and far LOD agree with each other. After any border crossing (a
  home-face flip) "everything aligns"; the user hypothesises per-face origins that the flip
  unifies.
- **Opus (headless, trusted):** worldgen **values** are path-independent — all 24 cube edges,
  extended-window generation byte-identical to the true-face generation
  (`verify_cosmos_seam.gd`, 72/0). So it is not a worldgen divergence; both render paths fold
  the value correctly but *place* the cell on the home face's flat extended lattice and bend
  it camera-centred.
- **The crux left open:** the player spawns *at the corner*, where a border is close to the
  camera — and the camera-centred lie was believed to be ~0 near the camera. If the seam is
  visibly off *near* the player, doesn't that exceed the lie and imply an initial-frame bug?

## 2. Crux answer 1 — the lie is NOT ~0 near the camera at a corner (numbers)

The rendered geometry is: flat window lattice (1 m per cell, orthogonal axes) → the exact
camera-centred sphere wrap (`cosmos_bend.gd` §3.4 — which is precisely the exponential map at
the camera: planar distance → arc, azimuth preserved). The true geometry is the equal-angle
chart embedding. The visible misalignment is the difference field, which is zero at the
camera *point* but grows at a rate set by the **local metric error of the flat window at the
camera's location** — and that local error is wildly position-dependent. Measured local
lattice metric (per-cell true step vectors, `n = 10016`, `R = 6371`):

| camera site | \|t_i\| | \|t_j\| | axis angle | σ_max(F−R), the linear lie coefficient |
|---|---|---|---|---|
| face centre | 1.0092 | 1.0092 | 90.00° | **0.0092** |
| edge midpoint | 1.0092 | 0.7137 | 90.00° | 0.2863 (pure along-edge scale; see §3) |
| **cube corner** | 0.9515 | 0.9515 | **120.02°** | **0.3274** |

(F = the true images of the window axes in the tangent plane; R = the best-fit rotation —
each rendered probe below is *granted its optimal rigid alignment*, so these are the
irreducible residuals.) At the corner the true lattice axes meet at **120°** (the valence-3
defect, TOPOLOGY §5.1) while the window renders them at 90° — a 30° shear *at the camera*.

Rendered-vs-true displacement of probe cells (blocks), camera at the corner cell (4,0,0):

| window offset (ρ) | across the WEST seam | in-face | corner wedge (raw M5 stub) |
|---|---|---|---|
| ρ = 8 | 5.6 (**0.69·ρ**) | 2.1 (0.26·ρ) | 3.8 (0.34·ρ) |
| ρ = 32 | 23.6 (**0.74·ρ**) | 8.4 (0.26·ρ) | 15.3 (0.34·ρ) |
| ρ = 128 | 95.6 (**0.75·ρ**) | 33.7 (0.26·ρ) | — |

**A cross-seam cell 32 blocks from the corner camera renders ~24 blocks from its true
position.** So: observed ≈ predicted — *when the lie is predicted at the corner*, where its
coefficient is 0.26–0.75, not ~0. The "lie ≈ 0 near the camera" intuition is a face-centre
result (coefficient 0.009 — 0.1 blocks at 128, invisible); at the corner it is wrong by two
orders of magnitude. **No origin-scale anomaly is needed to explain the observation.**

On top of the smooth shear, there is a genuine **content discontinuity**: the corner quadrant
(out-of-range in both axes) folds to face −1 and falls back to raw home-face extrapolation
(`fold_cell` cube_sphere.gd:352-354, `worker_fold_column` terrain_config.gd:700-707,
`cosmos_chart.gd:59-63`). Along the two quadrant boundary lines radiating from the corner,
adjacent 1-m window cells sample ground truth this far apart:

| d (cells from corner) | ground gap between adjacent cells (m, should be ~1) |
|---|---|
| 8 | 6.1 |
| 16 | 13.7 |
| 32 | 28.7 |
| 64 | 58.9 |

Terrain features visibly **tear** along those two lines (the gap grows ≈ 0.9·d), in both the
near field and the far LOD (both consistently render the same wrong thing — matching the
user's "near and far agree"). The §5.3 deep-ocean mask that is supposed to hide exactly this
(`CORNER_SEA_R := 48`, cube_sphere.gd:30) is **declared but referenced by no worldgen code**
— the comments at terrain_config.gd:703, cosmos_chart.gd:52 and lattice_nav.gd:19-20 assert
a mask that does not exist. The user is parked in front of an unmasked M5 stub.

## 3. Crux answer 2 — there is no initial-frame origin inconsistency

Spawn path (`world_manager.gd:87-135` + `main.gd:33-36`) vs flip path
(`maybe_flip_home_face` 809-839), frame by frame:

| frame element | at spawn | after a flip |
|---|---|---|
| chart | `CosmosChart(HOME_FACE, 0, 0)` (`:97`) | re-based `(face′, i_org′, j_org′)` |
| `TerrainConfig` active face | `set_active_face(chart.face)` (`:98`) | same (`:816`) |
| module wrapper position | default ZERO = −(i_org, j_org) = −(0,0) | `−(i_org′, j_org′)` (`:828`) |
| module generator face | `_gen_face` default = `HOME_FACE` = chart face | new frozen epoch (`:830`) |
| far node position | `−(i_org, j_org)` = ZERO (`:130-131`) | `rebase_to(−(i_org′, j_org′))` (`:835`) |
| bend origin | per-frame camera (main.gd), both cases | same |

Every convention the flip establishes, `setup()` establishes identically at the identity
origin. There is **no normalisation the flip performs that spawn omits.** The user's
"different origins before, same origin after" is a natural misreading of what actually
changes at the flip: *which face's flat lattice is extended* — i.e. **where the low-error
region of the irreducible lie is centred**, which is always "on the player's current home
face", never "unified".

## 4. Crux answer 3 — why "after crossing, ALL faces align" (and why it can't be literal)

Geometrically, multiple cube faces cannot be flattened around one point without distortion
growing with distance — literal global alignment from one flat lattice + one bend is
impossible. What the user experiences is the coefficient table above, evaluated where they
actually stand after crossing:

- **Crossing direction at an edge midpoint: coefficient 0.001** (measured: 0.03 blocks at
  ρ = 32, 0.12 at ρ = 128) — cross-seam terrain is *genuinely* pixel-aligned near the camera.
- The along-edge 0.29·ρ residual at an edge is a **uniform, seam-symmetric scale stretch**
  (axis angle stays 90.00°, zero shear, identical on both sides) — a smooth diffeomorphism
  with no reference to betray it: no crack, no kink (§4.6's "0° kink at edge midpoints").
  Humans see tears and kinks, not uniform stretch.
- Away from corners there is no corner quadrant in view, so no content tear exists at all.
- And from a face centre, **no corner is even within the far horizon**: face centre → corner
  is 54.7° of arc ≈ 6,087 blocks, vs `R_FAR = 3,072`.

So post-crossing the player is simply *not at a corner any more*: the lie coefficient in view
drops ~500× and the only true discontinuity (the wedge) leaves the horizon. That reads as
"everything aligned" — local truth, correctly observed, incorrectly extrapolated to "all
faces reference the same origin".

## 5. Verdict and the fix (localized — but not the one the origin hypothesis suggests)

**Verdict:** irreducible metric lie + unimplemented M5 corner mask, both maximised at the
cube corner — and the game **spawns the player at the cube corner**: `find_spawn()`
(terrain_config.gd:1828) scans outward from column (0,0), which under the spawn chart
`(HOME_FACE, 0, 0)` is *global face-4 cell (0,0)* — a corner of the cube. In FLAT_WORLD
(0,0) is an arbitrary point of an infinite plane (fine); in curved mode it is the single
worst point on the planet. That, not a frame bug, is the actionable defect.

**The fix (hand to Opus; small, curved-only, FLAT byte-identical):**

1. **Spawn at the face centre, not the corner.** In `find_spawn()` add a curved-mode branch
   that scans outward from `(n/2, n/2)` instead of `(0, 0)` (window == face indices under the
   identity chart, so the returned Vector2i stays window-correct for `main.gd:33-36`
   unchanged; the first `maybe_reanchor` recentres the origin on the next frame — |window| ≈
   5,008 is f32-safe, ULP ≈ 0.5 mm). From the face centre the lie coefficient in view is
   0.009 and no corner is within the far horizon (§4). One function, a few lines.
2. **Implement the §5.3 corner ocean mask** (the already-declared `CORNER_SEA_R = 48`): in
   the curved height path (`_height_c3` / `_curved_profile`), blend the surface to deep ocean
   within 48 cells of each of the 8 corner directions per the locked TOPOLOGY §5.3 formula
   (pure function of d̂ — 8 dot products gated on `max(|a|,|b|) > 0.98`, worker-safe by the
   frozen-epoch purity contract). This makes the three existing "deep-ocean-masked" comments
   true and puts the near-corner wedge tears under featureless water. Note honestly: the mask
   covers the *near*-corner zone; wedge tears beyond 48 cells remain (far LOD renders the
   quadrant out to R_FAR) — acceptable once nothing spawns there, and fully retired by M5
   proper (which may also drop far tiles whose footprint enters a corner quadrant, the
   `_tile_fully_in_face` precedent).
3. **Verify gates:** (a) spawn-corner-distance gate — the chosen spawn column's direction is
   ≥ some margin (e.g. 1,000 cells of arc) from all 8 corner directions; (b) a metric gate
   adapted from this investigation's probe: mid-edge crossing-direction displacement
   coefficient ≤ 0.01 at ρ ≤ 128 (regression-pins the §4.6 claim the design relies on);
   (c) corner-mask gate — `_curved_profile` within 8 cells of a corner direction is ocean.
4. **Do not** pursue frame/origin surgery, per-face far-tile placement, or a cross-face bend
   correction for this issue — §3 shows there is no frame defect, and after (1)+(2) the
   residual lie in every reachable view matches the documented, accepted §4.6 budget
   (invisible at face centres, kink-free at edge midpoints). The full multi-chart render
   redesign remains a deliberate M5+ decision, not a hotfix.

**Effort/risk:** (1) ≈ hours; (2) ≈ half a day + verify; (3) ≈ half a day. All curved-only
branches; FLAT_WORLD byte-identical; no render-path or frame changes; no perf impact beyond
8 gated dot products per column profile. The live-web-demo gate is untouched.

## 6. Reproducing the numbers (for the verify gate)

Probe recipe (SceneTree script on the custom editor, ~100 lines): camera cell `c₀`, true
per-cell step vectors by central difference of `CubeSphere.world_point`; tangent basis from
them; F = window-axes images; best rotation by 2-D Procrustes (`θ = atan2(F₁₀−F₀₁, F₀₀+F₁₁)`);
rendered probe = exponential map of the rotated window offset with the exact bend convention
(`φ = ρ/R`, radius `R+y` — `cosmos_bend.gd:16-24`); true probe = `fold_cell` →
`world_point` (raw fallback in the quadrant, matching the shipped chart/worker); report
|rendered − true| and the per-site σ_max(F−R). The §2 tables are the outputs at camera sites
(4,0,0), (4,0,n/2), (4,n/2,n/2).

## 7. Pending: the "blocks themselves change" report — prediction + candidate mechanisms

The user further reports genuinely *different blocks* on returning to the original face —
which, if it holds outside the zones below, would contradict §8.2 value path-independence and
supersede the §5 acceptance framing. This document's prediction for the full-block gate:

1. **The 24 single-edge strips will come back byte-identical.** The audit F2 fix threads the
   folded TRUE (face, i, j) through `GenCtx` into the entire feature stack (ores / strata /
   bedrock / trees / smoothing / snow-state hashes), on both the worker and analytic paths
   (`worker_fold_column` terrain_config.gd:700, `generated_cell_global` :636-646). If the
   gate fails on a plain edge, the bug is a residual F2-class miss — a feature layer still
   reading `_active_face` or a raw window coordinate instead of ctx — and the hunt should
   grep every feature hash for a coordinate that did not come out of the fold.
2. **The gate WILL find genuine home-face-dependence in two bounded places, if it probes
   them** — both are the M5 corner stub, not a new bug class:
   - **The corner quadrant itself:** `fold_cell` → face −1 → raw fallback in the HOME face's
     overshoot coordinates (`worker_fold_column` :704-706, `cosmos_chart.gd:59-63`). The same
     physical zone generates as raw-A when homed on face A and raw-B when homed on face B —
     *different blocks throughout the wedge, by construction*. A player who spawned at the
     corner, crossed, and walked back is looking at exactly this zone re-homed — "I really
     get different blocks when returning" is this stub's expected signature.
   - **A ~1–2-cell fringe along the quadrant boundaries:** an edge-strip cell whose
     smoothing/slope/tree stencil *neighbour* lands in the quadrant inherits the neighbour's
     home-face-dependent raw fallback → the strip cell's own modifier/material can flip with
     the home face even though its column profile does not.
   Both are erased by the §5 fix (corner ocean mask → the quadrant + fringe become uniform
   deep sea regardless of path; face-centre spawn → nobody is parked there watching).
3. **A non-worldgen mechanism matches the report's phrasing too:** the snowfall sim mutates
   the overlay over time (`SnowfallSystem`, stepped near the player each frame) — snow LAYER
   cells legitimately appear/deepen between visits, flip or no flip. Distinguisher: the
   changed blocks are snow-family and change with elapsed time *without* crossing any border.

Triage rule: classify the user's changed blocks (snow-family → mechanism 3; inside/adjacent
to the corner quadrant → mechanism 2; anywhere else on a plain edge → mechanism 1, a real
F2-residual worldgen bug that outranks everything in §5).
