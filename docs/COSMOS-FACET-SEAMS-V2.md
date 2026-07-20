# COSMOS-FACET-SEAMS-V2 — smooth-everywhere datum (pilot-driven revision of FS2)

**Status:** design delta, 2026-07-20. Amends `docs/COSMOS-FACET-SEAMS-DESIGN.md` (v1) after the
first live pilot of FS1+FS2. **v1's root cause, FS0 pin gate, FS1 shell weld, One-Height /
One-Surface Laws, tier table and queue all stand.** What changes: **FS2's integer content
re-index is retired** (pilot-falsified — it terraces the facet interior) and replaced by
**FS2′ `FP_DATUM_BAKE`** — the same datum, applied as a *continuous* displacement at the
render/physics/input boundary with the voxel content untouched. This doc also root-causes the
two border artifacts the pilot reported (invisible wall; crossing orientation glitch).

**Pilot verdict being answered:** borders fixed ("no more crazy 8-block altitude shifts" —
keep), but (i) "degraded ground smoothing in the MIDDLE of a facet" (new terracing), (ii)
invisible wall at some border spots, (iii) unsmoothed terrain right at the border, (iv)
orientation glitches when crossing.

---

## 1. Why FS2 terraced the interior (the v1 miss, owned)

FS2 shipped as v1 specified: integer `S = round(s) ∈ [0,7]` per column, applied as a content
re-index (`y − S`) at the window exits. Two consequences v1 under-weighed:

- **Terrace rings.** s is smooth with range ~7 across a facet, so S steps by 1 along ~7 contour
  rings (~every 30–60 blocks). v1 §3.3 claimed the resulting ≤1-block feature shear was "the
  same class as existing terrain steps" — **wrong on smooth ground**: plains/gentle slopes have
  long flat runs, and the S-contours cut brand-new 1-block ledges straight across them. The
  border cliff (rare, 5-block) was traded for interior ledges (everywhere, 1-block). The pilot
  is right that this is a net smoothness regression mid-facet.
- **It fights the smoother structurally.** The corner-height smoothing / SHARP-SLOPE modifiers
  are computed in true-height space against neighbour columns, *then* the re-index shifts
  adjacent columns by different S. A ramp computed to meet a neighbour at Δh=0 renders with the
  neighbour ±1 — broken ramps exactly on the contour rings. No tuning fixes this: any *post-
  resolve integer* shift breaks smoothing at its contours, and any *pre-resolve* integer shift
  still quantizes (and drags sea/snow/strata thresholds with it). The integer approach is a
  dead end for interiors; retire it.

**Decision: `FP_RADIAL_DATUM` (integer re-index) → OFF permanently; superseded by FS2′.**
(Keep the code until FS2′ lands if reverting live would re-open the 8-block cliffs — the pilot
prefers steps-at-border < terraces-everywhere is *not* established; if forced to choose interim,
flag guidance: FS1 stays on either way; FS2 on/off is the team-lead's interim call.)

## 2. FS2′ — `FP_DATUM_BAKE`: continuous datum at the boundary, content byte-identical

### 2.1 The idea

Keep the voxel **content** exactly as shipped (plane-anchored, byte-identical world, generator
untouched — no C++ *generator* change at all). Define two spaces related by a vertical,
per-column, **continuous** shear:

```
cell space  (content, physics grid):  the shipped lattice, y_cell
play space  (render + collision + aim): y_play = y_cell + s(fid, X, Z)

s(fid, X, Z) = −b + sqrt(b² + R² − |p0|²),  p0 = lattice_to_world64(fid, X, 0, Z), b = p0·n̂
```

s is the v1 §3.1 datum solve **without rounding**, evaluated at continuous (X,Z) — C∞, range
[0, ~6.9], gradient ≤ ~0.034 blocks/block. In play space the rendered/walked surface sits at
`R + g` (±0.15 cosine): **borders match with NO ±1 rounding residual** (better than FS2), and
the interior is the shipped shape lifted by a smooth field — **zero new steps, smoothing
untouched because content is untouched**. The sea surface (water cells at y_cell = 0) renders
at `R + s` — oceans continuous across seams too. Trees/bevels/carves ride the same lift.

This is the R2 "real-baked geometry" architecture in miniature: vertical-only, per-column,
CPU-side, with the input map that design already proved (J⁻¹ pattern) — none of the shader
transport that failed twice.

### 2.2 The application surfaces (the complete list)

1. **Near voxel mesh — the one engine touch.** Per-vertex `y += s(x,z)` at mesh time in the C++
   blocky mesher, via the patch-0003 precedent (`set_cosmos_bake` / `cosmos_bake.h` — the
   existing CPU per-vertex placement hook built for curved R2; ~50 ns/vert in the existing C++
   workers). New small mode or sibling patch (`facet_datum_bake`): params = the frozen facet
   frame row + R + the terrain's frozen fid (per pool terrain, frozen at spawn like
   `gen_facet`). GDScript twin + mirror gate (`verify_datum_bake_mirror`, the
   verify_cosmos_bake_mirror pattern). The GDScript fallback mesher applies the same helper
   directly. Requires one full build.sh cycle (`module_in_web=yes` check) — the same weight
   FS2's generator patch already paid; FS2′ *replaces* that patch class, not adds to it.
2. **Skin tier**: `+ s` in `_lattice_world` (facet_skin_tier.gd:539) — one line; shared-edge
   invariant preserved (s is a pure function of (fid, column)).
3. **Far ring**: nothing — FS1's radial emission already renders `R + relief` = the same
   surface by construction.
4. **Collision (analytic)**: the WM physics funnels convert at the boundary:
   `floor_under(x,z,y) = floor_under_cell(x, z, y − s) + s`; `blocked`/`_occ_span`/headroom the
   same pattern (evaluate in cell space, report in play space). The player already stands on
   fractional heights (slopes/smoothing), so a float floor is native. GroundCollider box y
   `+= s` per column; VoxelBody spawn/detach positions `+ s`.
5. **Input/DDA**: the aim ray converts play→cell per column step (`y −= s(column)` as the DDA
   walks columns — it already steps per column; exact). Aim highlight renders at `+ s`.
6. **HUD/env**: PerVoxelEnvironment keeps cell space (lapse-rate error ≤ 7 blocks ≈ negligible,
   as v1 already accepted).

Everything else — worldgen, resolve_cell, smoothing, junction planes/mask, crossing algebra,
edits keys, sea fill, snow — is **untouched**: they live entirely in cell space.

### 2.3 Gates (FS2′)

- **G-D2-SHAPE (the pilot gate):** flag-on near mesh == flag-off mesh + per-vertex `s·ŷ`
  exactly (assert per vertex over sample blocks, interior + border). Proves *zero shape change*
  — no terracing can exist if this holds, because the flag-off shape is the shipped smooth one.
- **G-D2-SEAM:** rendered surface at matched d̂ across every seam agrees ≤ 0.2 blocks (5-sample
  × all seams via the FS0 probe harness, now on play-space heights).
- **G-D2-WALK:** analytic floor == rendered top (±1e-3) at interior points AND 1 block each
  side of 3 ridges — collision-render agreement across the seam (also the pilot's "invisible
  wall" class regression guard for the *height* part).
- **G-D2-DDA:** hit-cell equality — aiming at the displaced render resolves the same cell as
  the un-displaced aim at the un-displaced render, over a ray fan including cross-seam rays.
- **G-D2-OFF:** flag-off byte identity (mesh, physics traces); FLAT suite; G-CG untouched
  (generator unchanged is the point).
- Live-only: interior smoothness reads as shipped (screenshot A/B vs a pre-FS2 build), border
  cliffs stay gone, ocean seam continuity.

NEVER-OOM: **0 bytes** (s is arithmetic; no caches — optionally memoized in the existing
per-pass column memo).

### 2.4 Rejected alternatives (this round)

- **Band-limited height blend** (datum only near ridges, → 0 inland, applied pre-smoothing):
  interior byte-identical, but it (a) still terraces *inside the band* (gradient ~0.1 ⇒ a step
  every ~10 blocks exactly where the pilot already sees "unsmoothed border"), (b) needs the C++
  *generator* touched anyway (heights come from `sample_columns`), (c) re-opens sea-level
  handling in the band, and (d) forfeits FS3 (far stays sagitta-mismatched inland, sink stays
  13). Strictly dominated by FS2′ — recorded here so it isn't re-proposed.
- **Render-only displacement without the collision/input maps**: up to 7 blocks of
  walk-on-what-you-see divergence — violates the render==collision invariant; never acceptable.

## 3. The invisible wall at the border — root cause + fix (collision-seam)

**Mechanism (file:line, confirmed):** `blocked()` keeps a permanent ridge wall — any query with
`own_dist < FACET_WALL_EPS = −3` is a wall (world_manager.gd:76, :2860-2865). It is supposed to
be unreachable because the crossing commits at `own_dist < −FACET_CROSS_HYST = −0.1`
(:1794-1796). But `maybe_cross_facet` **refuses to commit** in two cases, and then the analytic
floor carries the player on to −3 where they hit the wall:

- **Corner containment refusal** (:1807-1813): near a facet-grid corner the reframed landing
  fails the "interior to ALL FOUR of B's ridges" check → `continue` — the code comment
  explicitly accepts "the analytic floor still carries the player." That deferral IS the
  invisible wall, at every facet-grid corner approach ("at some places" ✓). This is the known
  FP-M1d diagonal-corner debt surfacing as gameplay.
- **Cooldown refusal** (:1791-1793): within `FACET_CROSS_COOLDOWN = 6` ticks of a commit, a
  corner zig-zag re-hits a ridge and is refused → same wall.

(FS2's datum shift is at most a ~0.2-block perturbation of `own_dist` via the plane's small y
coefficient — not the cause.)

**Fix — corner commit by direction (`FP_CROSS_CORNER_COMMIT`):** when a slot fires and
containment fails, resolve the destination by *direction*, not by the single crossed edge:

```
candidates = {the two edge neighbours whose ridges are crossed, their common diagonal facet}
commit to argmax over candidates of  min_slot own_dist(candidate, reframe(candidate, pos))
(tie / all < −(HYST+SLACK): defer one tick, as today)
```

The argmax facet is the one that actually contains the player's direction (equivalently:
`FacetAtlas.facet_of_dir(d̂(pos))` — the classifier already exists, facet_atlas.gd:786 — used
as a cross-check/gate oracle). The diagonal fid resolves by composing `seam_neighbour` across
the two crossed slots (both orders → same facet except at the 8 cube corners, where 3 facets
meet and one order is the answer — assert agreement, else take the facet_of_dir pick).
Cooldown amendment: the cooldown must **not** apply once `own_dist < −1` (genuinely past the
ridge — never park the player in masked space); it exists to stop jitter at −0.1, not to strand.
The −3 wall **stays** as the final backstop but becomes unreachable in normal traversal.

Pool note: the diagonal facet may not be pooled (edge-neighbours-only policy) — commit uses the
existing pool-miss path (:1839-1847, spawn-then-redesignate, milliseconds), and the pool policy
gains "warm the diagonal when TWO ridges are < D_WARM2" (the Z1-hybrid corner clause already
contemplates exactly this).

**Gates:** G-CORNER-WALK — headless traversal lines grazing several facet-grid corners
(including cross-cube-face ones): never `blocked()` by the ridge wall, lands on the
`facet_of_dir`-correct facet, ≤3 commits per pass (no storm); cooldown-strand probe (fast
zig-zag at a corner never reaches own_dist −3).

## 4. "Unsmoothed terrain right at the border"

Three contributors, ranked:

1. **FS2's own contour breakage** (§1) is *steepest at the border* (the correction ramps to its
   max there) — FS2′ removes it wholesale (content untouched ⇒ smoothing untouched).
2. **Bevel lip after crossing** — the junction manifest is cleared on crossing (lip fallback;
   the proven per-facet-bake constraint). Known debt; the real fix remains FP-CARVE (mesh-time
   clip). Unchanged by this doc; noted so the pilot's observation is attributed.
3. **Smoothing stencils at the mask boundary** — implementer must verify the smoothing/slope
   stencils read *generated* (unmasked) heights for beyond-ridge neighbour columns (the mask is
   an emission rule at the window exits; stencil reads should see the continuous field — under
   FS2′ + FS1 the extended-plane heights match the neighbour's rendered surface to ≤0.2, so
   ramps arriving at the ridge are correct by construction). If a stencil is found consuming
   masked AIR, route it through `column_profile` (unmasked) — a small, gate-able fix
   (G-D2-STENCIL: modifier fields continuous up to the ridge).

## 5. Crossing orientation glitch — root cause analysis (hand off to the crossing/nav owner)

Not a seams-geometry bug; characterized here with the algebra so the owner starts warm. The
twist chain: `maybe_cross_facet` computes `yaw_delta` = yaw of A's +X in B's lattice (:1814-1815)
→ `player.apply_reframe` (player.gd:291-316) applies `reframe_twist`:
shipped = rotate local yaw+velocity by `+yaw_delta`; `FP_CROSS_KEEP_HEADING` = leave them
unchanged (SN-FIX #2).

The world-heading algebra (world_yaw = frame_yaw + local_yaw; frame_yaw_B − frame_yaw_A =
−yaw_delta):

- **Fixed frame ON** (ActiveFrame flips T_from→T_to, world_manager.gd:1876-1880): preserving the
  player's *world* heading requires local += yaw_delta — i.e. **the shipped twist is the
  heading-preserving one, and KEEP_HEADING (local unchanged) rotates the world heading by the
  full inter-frame yaw** — a visible snap, largest at cross-cube-face seams. The flag's
  documented intent ("world heading preserved") is achieved by the *opposite* branch under the
  fixed frame. If the live build has FIXED_FRAME + KEEP_HEADING both sed-on, this is the glitch,
  and the fix is to make the twist frame-aware (KEEP_HEADING ⇒ apply +yaw_delta under the fixed
  frame; no-twist only in the legacy frame / orbital BCI regime it was designed for).
- **Fixed frame OFF** (legacy: scene ≡ active lattice): the rendered planet re-expresses into
  B's frame at the commit while the camera twists by yaw_delta — the two must cancel in one
  frame; any one-frame ordering gap (twist applied in `_physics_process` :562 vs the module/far
  re-place inside `maybe_cross_facet`) shows as a transient view snap. Also verify the FP3b
  "dihedral crest eased by the camera" path still runs — if the easing died, every crossing
  shows the raw 3.75° tilt step.

Both in-repo defaults are `false` (cube_sphere.gd:432, :789); the deploy sed-flips flags at
export, so the owner's first move is reading the live flag set, then the matching branch above.

## 6. Revised stage plan (delta to v1 §6)

- FS0, FS1 — **unchanged, keep live** (FS1 confirmed working: shell closed).
- FS2 — **retire** (flag off; remove after FS2′ soaks). Interim on/off = team-lead call (§1).
- **FS2′ `FP_DATUM_BAKE`** (§2) — the smooth-everywhere border fix. Gates G-D2-*.
- **FS-W `FP_CROSS_CORNER_COMMIT`** (§3) — kills the invisible wall. Gate G-CORNER-WALK.
  Independent of FS2′; can ship first (it is GDScript-only, small).
- FS3 (sink shrink) — unchanged, now gated on FS2′ (not FS2).
- FS4 (queue) — unchanged.
- Orientation glitch — **handed off** (§5) to the crossing/nav owner with the two-mode analysis.

Order of pilot relief: FS-W (GDScript, days) → FS2′ (one engine patch + rebuild) → FS3.
