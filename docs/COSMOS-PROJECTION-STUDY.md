# COSMOS-PROJECTION-STUDY — sphere-into-squares: substrate, warp, and the M5a verdict

Status: RESEARCH (Fable, 2026-07-09), task #76. Trigger: the first live WebGL2 deploy of
M5a broke (wedge unchanged, faces scrambled, LOD/chunk mismatch) while its CPU mirror
passed 11/0 — prompting the user's question: *"are there better ways of wrapping a
sphere into a mesh made of squares/cubes?"* This study answers it with numbers, then
ranks the paths. Companion: COSMOS-PLANET-TOPOLOGY §2 (the original variant choice),
COSMOS-M5-ADR (the placement design this adjudicates around).

All distortion figures below are computed exactly from the engine's own map
(`P = R·d̂(a,b)`, `d̂ = (n̂ + warp(a)û + warp(b)v̂)/L`, cells of face size n = 10016,
R = 6371): Jacobian singular values (σ₁, σ₂) of window-cells → sphere-blocks.
σ = 1 means one window cell spans one true block; σ₁/σ₂ is the local anisotropy
(shear); σ₁·σ₂ the area factor.

---

## 0. Executive summary

1. **The substrate is settled — cube-sphere is optimal for a square voxel lattice**
   (§1). On a quad lattice the angular defect at any lattice vertex is quantized to
   multiples of 90°; Gauss–Bonnet fixes the total at 720°; hence **exactly 8 corners of
   90° is the minimum-severity distribution** — the cube. Fewer points means 180°+
   cone points (far worse); icosphere/HEALPix don't tile with square cells. The lead's
   claim is confirmed and strengthened: the corners are not merely unavoidable, the
   cube's distribution of them is the best a square lattice can do.
2. **The projection lever is nearly spent — equal-angle is provably corner-optimal**
   (§2). Measured exactly: equal-angle's corner singular values are (1.154, 0.666),
   anisotropy 1.733 = √3 — which is the *mathematical lower bound* for any
   bounded-area map taking the chart's 90° corner onto the sphere's 120° wedge
   (minimal condition number of a 90°→120° cone map = tan 60°/tan 45° = √3).
   No warp swap can improve the corner. Conformal evades the bound only by letting
   cell size vanish: corner cells 0.046 blocks, still half-size 1,250 cells out —
   **disqualified for a voxel world**. Remaining warp gains are ~10% mid-edge, at the
   cost of regenerating the entire world's content. The earlier "corner Jacobian ≈
   diag(2,1,2)" reading was the pre-normalization warp derivative (warp′ ≈ 1.57·2),
   not the metric; the true stretch range is **S ∈ [0.666, 1.154]** — milder than
   feared, and it *widens* the M5a interaction-bubble's fold-free margin.
3. **Neither the wedge nor the corner misalignment is a projection problem** (§2.3):
   the wedge is topological (the flat window double-covers near the vertex under
   *any* warp) and the corner angular stretch (120° rendered in 90° of window) is
   chart-forced. The user-visible artifacts are killed only by true-position
   placement (M5) + the corner anomaly (M5c-lite) — exactly the committed plan.
4. **Recommendation: fix the M5a shader (path B), keep equal-angle, land M5c-lite
   before the A/B** (§3–§4). The live failure is a WebGL2 *porting* bug, not math —
   prime suspect the ~75-scalar unpacking of the 5-chart table into global uniforms
   (Godot globals can't hold arrays; per-material uniform **arrays** can) plus a
   near/far uniform-update split explaining the LOD mismatch. Bounded fix, days,
   with two cheap debug levers that make it deterministic.

## 1. Substrate head-to-head (given: square voxel lattice + threaded WebGL2 demo)

**The quantization theorem.** On a lattice of square cells, an interior vertex where
k quads meet has angular defect 2π − k·(π/2): the defect is *quantized to multiples
of 90°*. Gauss–Bonnet requires the defects to sum to 720° over the sphere. The
options: 8 × 90° (cube, k=3 points), 4 × 180° (k=2 "beak" points — a half-plane
fold, geodesics reverse, unusable), or mixtures with larger defects. More, smaller
defects are *impossible* with square cells. So the 8 cube corners are not just
necessary — they are the gentlest possible arrangement. Any "better wrapping" made
of squares is the cube-sphere wearing a different warp.

| Substrate | Defects | Square-lattice fit | Indexing/seams | Verdict |
|---|---|---|---|---|
| **Cube-sphere** (ours) | 8 × 90° (minimum severity) | native | 12 edges, exact D4 affines (built: fold/M_win/keys/gates) | **keep** |
| Icosphere / geodesic | 12 × 60° (gentler points) | **none** — triangle/hex charts; cube voxels don't tile them; D4 machinery → D6 rework | 30 edges, awkward remaps | reject |
| HEALPix | 720° over 8 polar-ish valence-3 points | quad *faces* but curvilinear, area-first; ring/nested indexing | 12 base quads, non-uniform neighbour rules | reject (buys area uniformity we don't need at the cost of everything built) |
| 2-chart polar / lat-long | 2 × 360° pole singularities | square-ish away from poles | catastrophic pole cells | reject |
| Single flat torus-wrap | metric lie everywhere, no sphere | perfect | trivial | that is FLAT_WORLD; not a planet |

Web/GPU cost is substrate-independent at our scale except icosphere/HEALPix, which
would force a full engine rework (godot_voxel is a cubic-lattice mesher).

## 2. The projection (warp) lever — quantified

### 2.1 Measured distortion (exact, from the engine's map, n = 10016)

| Warp | face centre σ | edge midpoint σ | corner σ | corner anisotropy | corner area |
|---|---|---|---|---|---|
| **equal-angle** (current, tan) | 0.999, 0.999 | 0.999, 0.707 | **1.154, 0.666** | **1.733 = √3** | 0.77 |
| gnomonic (no warp) | 1.272, 1.272 | 0.900, 0.636 | 0.735, 0.424 | 1.73 | 0.31 |
| conformal (Rančić-type) | ~1, ~1 | ~1, ~1 (zero shear) | **→ 0 scale** | 1 (by construction) | → 0 |
| equal-area (COBE-type) | ~1, ~1 | shear moved here | bounded area | unbounded shear at corner | 1 |

**The corner lower bound.** Any chart maps its square's 90° corner onto the
sphere's 120° vertex wedge (three faces × 120° = 360°, the sphere is smooth there).
A linear map taking a 90° cone onto a 120° cone has minimal condition number
tan 60°/tan 45° = √3 ≈ 1.732. Equal-angle *achieves* 1.733 — the corner shear is
already optimal among all bounded-area warps; the only escape is conformal's
vanishing area.

**Conformal, disqualified with numbers.** Near the corner a conformal chart behaves
as z^(4/3) (90°→120°), so |f′| ~ r^(1/3) and the physical cell size at ρ cells from
the corner is ~ (ρ/N)^(1/3) of mid-face: ρ=1 → **0.046 blocks**; ρ=8 (the anomaly
disc) → 0.09; ρ=100 → 0.22; cells reach half-size only at **ρ ≈ 1,250**. A fifth
of a face-quadrant near every corner becomes a miniature world — walk speed, reach,
and structure scale all visibly wrong on *walkable terrain* (the user's dry-planet
requirement makes this land, not hidden ocean). It would also make the M5a
interaction bubble *harder* (S down to ~0.05, not our 0.67). Conformal is the right
tool for PDE grids and the wrong tool for unit-cube gameplay.

**Optimized polynomials (COBE / 5th-order / "Outerra-style" tweaks):** these trade
along the same one-parameter family between equal-angle and equal-area. Best case
they shave the mid-edge transverse dip 0.707 → ~0.8 and overall anisotropy ~1.41 →
~1.3. They cannot touch the corner (bound above) and cannot touch the wedge (§2.3).

### 2.2 Is warp() really a localized swap?

Code-wise, **yes** — verified against the architecture: `warp()/unwarp()`
(cube_sphere.gd §1.2) sit below `face_cell_to_dir`/`dir_to_face_cell`; the D4 edge
remaps, `fold_cell(_canonical)`, `M_win`, edit/region keys, §8.2 canonicalisation,
and gravity (radial) are all *index-space or direction-space* constructs that never
see the warp. The gates that pin metric numbers (horizon 147, corner enumerations)
re-run unchanged; T-series tolerances would need re-derivation. **But content-wise,
no**: the warp defines which direction each cell owns, so swapping it *regenerates
the planet* — every mountain moves, every existing edit's surroundings change. A
real cost, acceptable only if the payoff were large. Per §2.1 it is ~10% mid-edge.

### 2.3 What no warp can fix (the user-visible artifacts)

- **The wedge** is topology: the flat window has 360° of *lattice* angle at the
  vertex while home+strips consume 270° of it (mapping onto the full 360° physical);
  the excess quadrant double-covers regardless of warp. Only true-position
  placement (discard) + the M5c anomaly/pillar remove it.
- **The corner sector stretch** (each face's 120° of reality drawn in 90° of window
  under the bend) is the chart-corner angle ratio — warp-independent. Only true
  placement renders the 120° as 120°.
- The **seam kink** mid-edge would shrink ~30% under an optimized warp — but it was
  already §4.6-invisible in play, and true placement eliminates it exactly.

**Conclusion: the projection lever cannot deliver the demanded wins.** Equal-angle
stays. Keep the warp isolation as a future numeric-comfort lever only.

## 3. Path B — finish M5a: diagnosis of the WebGL2 break

The CPU mirror passed 11/0, so the math and conventions are right; the live failure
is porting. Mapping symptoms to causes:

| Symptom | Likely cause |
|---|---|
| "legitimate faces messed up / directions mixed" | the 5-chart table unpack: Godot **global** shader params can't be arrays, so ~75 per-side scalars were minted — one wrong index/order/sign anywhere scrambles a whole strip. Also int→float packing of (M_s, t_s). |
| "wedge rendered as before" | the double-out classification branch never fires in GLSL (comparison against un-updated org/table, or float compare off-by-half) — consistent with the table being wrong wholesale. |
| "LOD terrain not coinciding with chunks" | near and far materials updated by *different* code paths / frames — one got a stale or differently-packed table; or one applied the bubble and the other didn't. |

**Fix design (bounded, days):**
1. Replace scalar globals with **per-material uniform arrays** (`uniform vec4
   chart_m[5]; uniform vec4 chart_axes_n[5]; …`) — supported in Godot's shader
   language (only *globals* can't be arrays). The table changes only at a flip;
   update it through ONE function that touches every registered M5 material (near
   opaque/translucent, far, water, debris) in the same frame — this single-writer
   rule kills the LOD/chunk divergence class outright. Keep the three per-frame
   camera globals as scalars (allowed, already working for the bend).
2. **Chart-ID debug mode**: a shader flag that outputs the classification branch as
   flat albedo (home/W/E/N/S/wedge = 6 colours). One screenshot shows exactly which
   vertices misclassify — turns the scramble from a mystery into a lookup.
3. **Uniform-parity harness**: transcribe the GLSL logic into a GDScript function
   fed with the *same packed arrays* the materials receive, and diff it against
   `CosmosTruePlace.place_point` over the T1 probe set. This catches packing/order
   bugs headlessly — the exact class that slipped past the 11/0 mirror (which
   tested the math, not the packing).
4. Force `precision highp float` semantics (Godot spatial default is highp on
   desktop GL but verify for the web export; mediump on some mobile drivers would
   shred 10016-scale coordinates); keep integer-valued floats < 2²⁴ (they are:
   max ~10016).
5. Corrected constants from §2.1: the bubble's S range is [0.666, 1.154] (not
   [0.5, 2]) — fold-free margin of the [16, 104] smoothstep grows to ≈ 0.65; no
   parameter change needed, T8/T10 unchanged.

Risk after fix: low — the remaining unknown is only WebGL2 driver variance, which
the chart-ID debug mode exposes in one frame on the live site.

## 4. Recommendation (ranked by effort × risk × payoff, web-first)

1. **Fix M5a's shader as diagnosed (§3), keep equal-angle** — days, low risk,
   delivers the exact-kill of every visible artifact class. The math is proven;
   only plumbing failed.
2. **Land M5c-lite (pillar + anomaly + eager corner flips) before the user A/B**
   (already adjudicated) — the wedge is invisible-by-unreachable at the mandated
   corner spawn, independent of shader work.
3. **Do not swap the warp now.** Equal-angle is provably corner-optimal (√3 bound
   achieved); candidate gains are ~10% mid-edge; cost is a regenerated planet and
   re-derived gate tolerances; and it fixes neither the wedge nor the corner
   sectors. Revisit only if, post-M5, some numeric margin (bubble swim, T-series
   tolerance) is genuinely uncomfortable — the isolation makes that a contained
   future pass.
4. **Reject conformal** (vanishing corner cells — worse gameplay AND worse M5a
   margins) and **reject substrate changes** (quad-defect quantization theorem;
   icosphere/HEALPix don't fit the voxel lattice or the built machinery).

The honest bottom line for the user's question: *there is no better way to wrap a
sphere in squares* — the cube-sphere with an equal-angle-class warp is the optimum
the mathematics allows, and the two artifacts they can see are exactly the two
things no projection can fix. The cure for those is the already-designed
true-position render + corner anomaly; what failed on the web was a uniform-packing
port, not the idea.
