# COSMOS-TRIANGULAR-TOPOLOGY-STUDY — more faces / triangular border blocks vs the cube corner

Status: RESEARCH (Fable, 2026-07-12). Trigger: the user's proposal to reduce the visible
voxel distortion near the cube CORNERS by (1) using a planet with MORE faces than the
6-face cube, and/or (2) allowing TRIANGULAR, non-buildable border blocks (right-isosceles
90°+45°+45°, i.e. a square voxel halved on its diagonal) at face borders while keeping
standard square/cube voxels in-face. The user's exact ask: *"do deep research if
geometrically this is feasible AND better AND simpler to implement in our setup."*

Companions: COSMOS-PROJECTION-STUDY (branch `docs/voxiverse-cosmos-projection-study`) —
proved the cube-sphere optimal for a **pure** square lattice via the quad-defect
quantization theorem; **this study evaluates exactly the degree of freedom that proof
excluded**: relaxing the pure-square assumption at borders. COSMOS-M5C-CORNER (the shipped
corner seal this would compete with), COSMOS-REAL-GEOMETRY-STUDY (R2 true-baked render —
under which the corner render is already geometrically honest), COSMOS-FRAME-ORIENTATION
(`M_win`, the D4 edge machinery any new topology must replace).

All numbers below are exact or shown with their arithmetic. Cell/stretch figures reuse the
projection study's measured baseline: equal-angle corner singular values
**S ∈ [0.666, 1.154]**, corner anisotropy **√3 ≈ 1.732** (the proven lower bound for a
90°-chart-corner → 120°-sphere-wedge map, achieved by the shipped warp).

---

## 0. Executive summary — the three-way verdict first

The user's question decomposes cleanly, and the honest answers differ per part:

1. **"More square faces": NO EFFECT — mathematically impossible to help** (§2).
   Any surface tiled by square cells has vertex defects quantized to multiples of 90°;
   Gauss–Bonnet fixes the total at 720°; subdividing cube faces adds only 0-defect
   vertices and the 8 corners stay at 90° each. There is no square-cell planet with
   milder corners than the cube. (This re-confirms the projection study's theorem — it is
   restated here because idea (1) is precisely an attempted counterexample.)
2. **Triangular border blocks at EDGES: solve a non-problem** (§3). The 12 cube edges are
   developable (zero curvature — every edge lattice vertex is 4-valent, defect 0), the two
   face grids already align by an exact integer D4 isometry, and under R2 true placement
   both sides bake to the same great-circle seam with sub-cell weld. There is no gap,
   no overlap, and no distortion at edges for miter triangles to fix. **All the genuine
   distortion is concentrated at the 8 corners.**
3. **Triangular border blocks at CORNERS: geometrically REAL — this is the truncated-cube
   family** (§4). The user's 90-45-45 half-voxel is exactly the boundary cell of a 45°
   diagonal lattice cut, and cutting the 8 corners turns the cube into a truncated cube:
   **8 vertices × 90° defect → 24 vertices × 30° defect**, corner anisotropy bound
   **1.732 → ≈ 1.267** (arithmetic in §4.2 — as gentle as an icosahedron corner, while
   keeping square in-face voxels). The user's geometric instinct is correct.
   **BUT** two hard caveats: (a) the improvement is *strictly local* — outside the cap
   the enclosed defect is still 90°, so the metric at radius r ≫ t (cap depth t) is
   *unchanged* by Gauss–Bonnet (§4.3): the cap must be as large as the region you want
   to look better (t ≈ 64–128 cells to cover the visible corner zone); (b) it is a
   substantial re-architecture (§5): a new non-separable projection, planet
   regeneration, square↔triangle seams at 24 new edges, physics/mesher special cases,
   and re-derivation of the entire corner pipeline — **4–6 milestones** in the
   subsystem that produced this project's recurring frame bugs.
4. **Verdict: (a) FEASIBLE — yes, with real engineering caveats. (b) BETTER — modestly
   and only locally: anisotropy 1.73 → 1.27 and wedge slack 90° → 30° within ~t cells of
   each corner; invisible beyond that. (c) SIMPLER — bluntly, NO: strictly more
   machinery than the shipped cube + M5c** (more vertices, more seam types, two lattice
   families, non-separable warp).
5. **The 80/20 exists and is cheap** (§6): a **cosmetic triangular corner monument** on
   the existing M5c pillar — a static, three-fold-symmetric cap mesh (true-space under
   R2) whose base trim uses exactly the user's 90-45-45 half-cell triangles to meet the
   three face grids on their diagonals. Zero topology change, zero regeneration, days of
   work. It does not change the metric — it changes what the eye reads at the pinch
   point: a deliberate landmark instead of a squished lattice. §7 ranks it first among
   the actionable options.

---

## 1. The hard wall: Gauss–Bonnet and what "reducing corner distortion" can even mean

For any closed polyhedral (piecewise-flat) surface of sphere topology, the sum of vertex
angular defects is exactly **4π = 720°** (discrete Gauss–Bonnet). This is invariant — no
choice of faces, face counts, or face shapes changes the total. The ONLY lever any
topology proposal has is **redistribution**: more defect vertices, each carrying less.

Per-vertex defect matters because the local lattice distortion near a cone point is a
function of its defect δ: the surrounding charts must stretch their combined (360° − δ)
of flat angle over the sphere's smooth 360°. Milder δ ⇒ milder minimum stretch (§4.2
quantifies). So the entire question "can corners be gentler?" is exactly the question
"can the 720° be split into more, smaller pieces *without giving up square in-face
voxels*?"

## 2. Idea (1), "more faces": killed by the quantization theorem

**Theorem (quad-defect quantization, restated from COSMOS-PROJECTION-STUDY §1).** On any
surface tiled edge-to-edge by unit squares, a vertex where k squares meet has defect
360° − k·90° — a multiple of 90°. With the total pinned at 720°, the possible
distributions are 8 × 90° (k = 3, the cube), 4 × 180° (k = 2 "beak" fold points —
geodesics reverse; unusable), or mixtures with defects ≥ 90°. **8 × 90° is the unique
minimum-severity distribution.**

**Corollary (face subdivision does nothing).** Subdividing each cube face into k × k
sub-faces (or any recombination of square-tiled patches into "more faces") adds only
vertices of defect 0: a face-interior lattice vertex has 4 squares (defect 0); an
edge-interior lattice vertex has 2 + 2 squares across the fold — 4 × 90° = 360°, defect 0
(this is the §3 developability); the 8 original corners keep exactly 3 squares — defect
90°, untouched. A "24-face planet" or "96-face planet" built of squares is the cube-sphere
wearing different bookkeeping: same 8 corners, same 90° each, same S ∈ [0.666, 1.154].

Non-square quads don't rescue it: rectangles re-derive the same 90° quanta, and rhombi /
sheared quads are not square voxels (the Minecraft-style building constraint is locked).
**Idea (1) is closed: no help, at any face count.**

## 3. Edges vs corners — where triangles could matter and where they cannot

The user's picture — *"overlapping real voxels from the bordering faces under non-0
angles … triangular block materials partially filling the border voxels, aligned with the
intersecting voxels'"* — is an edge-miter picture. The geometry says edges need none of
it:

- **Edges are developable.** Every edge-interior lattice vertex is 4-valent (2 squares
  per face) ⇒ defect 0 ⇒ zero Gaussian curvature along the whole edge. The two face
  grids meet across the fold by the **exact integer D4 isometry** the engine already
  implements (`edge_remap`, det +1, all 12 edges — cube_sphere.gd; the flip theorem of
  COSMOS-FRAME-ORIENTATION §2 is exact *because* of this).
- **Under R2 true placement the seam is already welded.** Both faces' vertices bake to
  true sphere positions; the shared boundary bakes to the same great-circle arc from
  both sides (seam-weld gate ≤ 1.05 cells, COSMOS-REAL-GEOMETRY-STUDY §8). There is no
  gap to fill, no overlap to resolve, and no angular mismatch: a cell on face A and its
  D4-image neighbour on face B are the *same physical cell*.
- The only edge-adjacent residual ever measured is the mid-edge transverse scale dip
  (σ₂ = 0.707 — cells are ~29% narrower across the seam direction). That is a smooth
  *metric* property of the projection, not a junction defect: a triangular border block
  cannot change it (it is not a shape problem; the cells on both sides are already
  correctly adjacent).

**Conclusion: triangular MITER blocks at the 12 edges are a solution to a problem the
engine does not have.** All non-developable distortion — 100% of the planet's 720° of
curvature — sits at the 8 corners. Triangles can only matter there. That is §4.

## 4. Idea (2) at corners: the truncation family — the real content of the proposal

### 4.1 The user's 90-45-45 triangle IS the truncated-cube boundary cell

Cut each cube corner with a plane perpendicular to the corner diagonal at lattice depth
t (cells along each edge). On each incident face the cut is a 45° diagonal line from
(t, 0) to (0, t) in corner-local cell coordinates. A square lattice cut at 45° has
exactly one lattice-aligned boundary element: **the square cell halved on its diagonal —
a right-isosceles 90°+45°+45° triangle**. (The user's "or something else" alternatives —
e.g. 30-60-90 — correspond to non-45° cuts, which do not align with any lattice
direction and would leave sub-cell slivers; 45° is the unique lattice-friendly cut.)
So the proposal, made precise, is the **truncated cube**: 6 octagonal faces (square
grids with 4 diagonal-cut corners) + 8 small triangular cap faces.

### 4.2 The defect and stretch arithmetic — how much gentler, exactly

**Defect.** Each truncation vertex (3 per original corner, 24 total) joins two octagon
faces and one cap triangle. The octagon's interior angle at a 45° cut is 135° (the 90°
face corner splits into two 135° angles — independent of the depth t, because the cut
direction is fixed at 45°); the equilateral cap contributes 60°. Flat angle sum
= 135° + 135° + 60° = 330° ⇒ **defect 30° per vertex; 24 × 30° = 720°** ✓.

**Anisotropy bound at a 30° vertex.** The three charts' corners (135°, 135°, 60°; total
330°) must cover the sphere's smooth 360° around the vertex direction. Apportion sphere
wedges β_o, β_o, β_t (2β_o + β_t = 360°); the minimal condition number of a chart-corner
map α → β is tan(β/2)/tan(α/2) (same lemma the projection study used for the cube's √3).
Equalizing the two chart types:

```
β_o = 143.8°, β_t = 72.4°:
  octagon: tan(71.9°)/tan(67.5°) = 3.0595 / 2.4142 = 1.2673
  cap:     tan(36.2°)/tan(30°)   = 0.7319 / 0.5774 = 1.2677
```

**Corner anisotropy bound ≈ 1.267, vs the cube's 1.732** — a 2.7× reduction of the
deviation from isotropy (0.732 → 0.267). Note β_t ≈ 72°: the cap chart behaves exactly
like an icosahedron corner — the truncated cube reaches icosahedral gentleness *while
keeping square in-face voxels*. Per-axis stretch: with anisotropy c, S = √(a·c) and
√(a/c) for corner area factor a. At the cube's measured a = 0.77 this gives
S ∈ [0.78, 0.99]; at a = 1.0, S ∈ [0.89, 1.13]. Either way the worst per-axis deviation
improves from **33% (S = 0.666) to ~12–22%**, warp-design-dependent.

**The comparison table** (anisotropy = achievable lower bound at the worst vertex):

| Topology | defect vertices | per-vertex defect | corner anisotropy | square in-face voxels |
|---|---|---|---|---|
| **Cube (shipped)** | 8 | 90° | **1.732** (achieved) | all |
| Cube, faces subdivided any k | 8 | 90° | 1.732 — **zero change** | all |
| Cuboctahedron | 12 | 60° | ≈ 1.32 | triangles are face-sized: ~37% of surface unbuildable — reject |
| **Truncated cube, depth t** | 24 | 30° | **≈ 1.267** | all but 8 caps of side t√2 |
| Chamfered cube | 24 (+8 flat) | 30° | ≈ 1.27 | 12 hexagonal edge-bands unbuildable — pays at the *edges*, which need no help (§3) — dominated by truncated cube |
| Icosahedron | 12 | 60° | 1.258 (tan 36°/tan 30°) | **none** — no square tiling |
| Truncated icosahedron | 60 | 12° | ≈ 1.09 | **none** |

Also gentler per sub-vertex: the flat window's excess ("wedge") at a truncation vertex is
360° − 330° = **30° instead of 90°**, and a small lap around one sub-vertex carries 30°
holonomy instead of 90°. The two octagons at each sub-vertex still meet across a
(shortened) original cube edge, so the **12 D4 edge remaps survive**; the third incident
chart is the triangle cap — see §5 for what that costs.

### 4.3 The decisive caveat: the improvement is strictly local (Gauss–Bonnet again)

Truncation does not remove curvature — it splits one 90° point into three 30° points a
distance ~t apart. **For any loop of radius r > t around the old corner, the enclosed
defect is still 3 × 30° = 90°, so the surface outside radius ~t is isometric to the
original 270° cone.** Every metric quantity at r ≫ t — cell stretch, the corner-zone
squish the player sees from 50–100 cells out, the 90° holonomy of a full corner
circumnavigation — is **provably unchanged**. Truncation blunts the tip; it cannot slim
the cone.

Consequences for cap sizing:

- A *small* cap (t ≈ 8, matching today's anomaly radius) improves the metric only in a
  ~8-cell neighbourhood **that M5c already makes unenterable** (pillar + edit lock +
  anomaly at R_b = 8). Net visible gain over shipped: ≈ zero.
- To visibly improve the corner zone a player actually sees (near view = 128 blocks;
  the cone's distortion pattern is scale-free, so the squish spans the whole visible
  neighbourhood whenever the player is within a few hundred cells of a corner), the cap
  must be **t ≈ 64–128 cells**, i.e. an unbuildable triangular plaza ~90–180 cells on a
  side at each of the 8 corners (area ≈ 0.87·t² ≈ 3.5k–14k cells each — globally
  negligible, locally the entire corner neighbourhood). At that size the "border block"
  framing has become "a differently-shaped M5c exclusion zone, 8×–250× larger".

This is the crux the proposal has to clear, and it can't be engineered around: **the
only way to make the whole planet's corners milder everywhere is to spread defect
globally (icosahedral-class), which square voxels forbid (§2).**

### 4.4 One more honesty check: what the corner "distortion" IS under the shipped path

Under R2/Design-Z the near+far render bakes true sphere positions — the corner is drawn
*geometrically honestly* today. The residual the user reacts to is **intrinsic cell
shape**: near the vertex, unit lattice cells render as bricks squeezed to 0.666× in one
diagonal direction and stretched 1.154× in the other, and a corner lap turns the world
90°. Truncation genuinely mildens the first (to ~[0.79, 1.13] within the cap zone) and
subdivides the second (3 × 30° cuts instead of 1 × 90° — but 90° total for any lap
enclosing the corner, invariant per §4.3). Nothing about truncation changes the *render
honesty* — both are honest; truncation's cells are just less non-cubic near the tip.

## 5. Feasibility in OUR engine — what the truncated cube actually costs

The pieces, against the shipped architecture:

1. **A new projection kernel — the big one.** `face_cell_to_dir`/`dir_to_face_cell`
   must chart an *inflated truncated cube*: the sphere region near each corner belongs
   to the cap chart, and the octagon charts' cells near the diagonal cut get directions
   pushed away from the corner. Merely masking cells of the existing cube projection
   changes NOTHING (the metric is a property of the projection; §4.3's numbers require
   the re-chart). The equal-angle warp is separable (tan per axis); the truncated warp
   near the cut is **non-separable** — a new 2-D warp with an exact inverse, f64-pure,
   worker-safe, plus re-derived round-trip gates. This also **regenerates the planet**
   (every cell within ~2t of every corner owns a new direction; content moves).
2. **Fold/chart topology rework.** 14 charts (6 octagon + 8 cap), 36 edges: the 12
   octagon–octagon edges keep today's exact D4 remaps (shortened by 2t), but the 24
   octagon–cap seams are **square-lattice ↔ triangle-lattice — no integer remap
   exists**. The flat-window paradigm (everything is square cells) fails within t of
   each corner: with an octagon home face, the window near a sub-vertex contains a 60°+
   sector of non-square-lattice content. Workable design: the caps are **not charts but
   plugs** — pre-authored static true-space meshes (R2 makes this natural), with the
   window lattice simply ending at the diagonal cut; but then `fold_cell`, the wedge
   handling (now 30° slack per sub-vertex, 3 per corner), `M_win` accumulation, edit
   keys, collapse flood-fill termination at cut cells, and the DDA across half-cells
   all need cut-boundary rules.
3. **Physics at the cut and on the cap.** The analytic physics (`block_id_at`,
   per-axis `blocked()`, `floor_under()`) is lattice-based. Half-cell boundary columns
   need a triangular-footprint collision rule in both render paths; the cap surface is
   either walkable (closed-form height function over a fixed monument design — doable
   but a new special case in the player controller) or barred (an M5c-style
   barrier/anomaly — in which case the cap's *gameplay* is exactly today's pillar,
   scaled up).
4. **Meshing.** The 90-45-45 half-cells need a mesh shape in the module path AND the
   GDScript fallback AND the far LOD builder. (Partially mitigated: the engine already
   has a directional sub-voxel shape family — slopes/smoothing via `shape_mesh` +
   modifier payloads with D4 rotation rules per COSMOS-FRAME-ORIENTATION §6 — a
   vertical diagonal half-block is plausibly one more entry, with the same fold-rotation
   discipline.)
5. **M5c re-derivation.** 24 vertices instead of 8; cone angle 330° instead of 270°
   (bisector 165° instead of 135°); the §7 unreachability lemma, constants, and all
   C-gates re-proven for the new adjacency; corner enumeration tables (`CORNER_SIGNS`,
   `corner_cells`) replaced by 24-vertex tables.
6. **Web/worker safety:** nothing *inherently* unsafe — generation stays a pure
   function of d̂, caps are static meshes, no new threading or per-frame allocation.
   The risk is not thread-safety; it is that this rewrites the exact subsystem
   (frames, folds, seams, corners) that produced bug cycles #68–#77, and every
   frozen-epoch/purity audit re-runs.

**Effort estimate: 4–6 milestones** (projection kernel ≈ 1, fold/window rework ≈ 1–2,
physics + mesher ≈ 1–2, M5c-analog + gates ≈ 1), plus planet regeneration and a full
gate re-derivation pass. Compare: the *entire* corner problem on the shipped cube was
sealed by M5c in "days-small" (COSMOS-REAL-GEOMETRY-STUDY §8) on top of machinery that
already existed.

## 6. The 80/20: a cosmetic triangular cap on the existing M5c corner

There is a cheap option that captures most of what the eye is asking for, because the
residual is a *presentation* problem (the corner looks pinched/alien) rather than a
correctness problem (M5c seals it; R2 renders it honestly):

**Option B — the corner monument cap.** Keep topology, projection, generation, physics,
and M5c exactly as shipped. Add a designed, three-fold-symmetric static monument mesh at
each vertex (true-space placement under R2 — same pattern as the §8 barrier cylinder
visual, but permanent and authored), sized to the pillar + anomaly footprint (~8-cell
radius):

- Its base trim uses **exactly the user's 90-45-45 half-cell triangles**, aligned to
  each of the three incident faces' grid diagonals — the truncated-cube *look* at the
  one place it matters, with zero truncated-cube machinery.
- Optionally relax M5c §2.2's "no modifiers on pillar columns" rule to give the pillar
  a 45° sub-voxel skirt from the *existing* slope shape family (data change + the
  standard fold-rotation payload rules; contained).
- Collision stays the shipped pillar + anomaly (render ⊆ locked columns — one
  containment assert added to gate C4's render==collision check).

Cost: **days**. Risk: presentation-only. What it does NOT do: change S anywhere — the
squished cells at r > 8 remain (they remain under small-t truncation too, §4.3; only
the 4–6-milestone large-t rewrite touches them). What it DOES do: replace the
worst-looking 16 cells of the planet with a deliberate landmark, which is how the corner
reads as *designed* rather than *broken* — the same psychology that made M5c's anomaly
"a consistent place, not a glitch" (M5C-CORNER §12.1).

## 7. Verdict and ranked recommendation

**(a) Feasible?** Yes — the truncated-cube family is geometrically sound, and a
plugs-not-charts cap design keeps it worker/web-safe. Feasible ≠ contained: it is a new
projection + fold topology + planet regeneration (§5).

**(b) Better?** Quantified: within ~t cells of each corner, anisotropy 1.732 → 1.267,
worst axis 0.666 → ~0.79–0.84, sub-vertex wedge 90° → 30°. Beyond ~t: **provably zero
change** (§4.3). New costs: 24 square↔triangle seams, 8 unbuildable cap plazas (t ≈
64–128 to cover the visible zone), two lattice families in every downstream system.
So: better *locally and modestly*, at a scope that only pays if t is large.

**(c) Simpler?** **No.** Strictly more machinery than shipped cube + M5c on every axis:
14 charts vs 6, 36 edges vs 12 (24 of them lattice-incompatible), 24 defect vertices vs
8, non-separable warp vs separable, mixed cell shapes vs one. The user's proposal is
*geometrically right* that triangles buy gentler corners; it is not a simplification.

**Ranked recommendation:**

1. **Keep cube + M5c** (shipped, sealed, gates green). Do nothing until R2 + M5c have
   been seen live at the corner — the honest true-baked corner with the pillar/anomaly
   may already read fine.
2. **If corner cosmetics still bother after the live A/B: Option B, the triangular
   corner monument** (§6) — the user's 90-45-45 triangles as authored true-space trim
   on the M5c pillar. Days of work, zero topology risk, captures the "designed corner"
   win. **This is the recommended actionable answer to the proposal.**
3. **Only if the corner-zone *metric* is later deemed unacceptable on its own terms:**
   the truncated cube at t ≈ 64–128 as a scheduled 4–6-milestone re-architecture with
   planet regeneration — after the demo gate, never before. File under "engine v2
   options" with this study as the spec seed.
4. **Rejected outright:** more square faces / subdivision (§2 — theorem, zero effect);
   triangular miters at the 12 edges (§3 — developable, already exact); icosahedral /
   truncated-icosahedral substrates (no square tiling — building constraint is locked);
   chamfered cube (pays its area at edges, which need nothing).

The one-line summary for the user: *Gauss–Bonnet fixes 720° of corner defect on any
planet; squares alone can only park it as 8 × 90° (the cube — more faces change
nothing); your triangular border blocks are exactly the truncated cube, which genuinely
mildens each corner 90° → 3 × 30° (stretch 1.73 → 1.27) but only within the cut-off cap
and at the price of a 4–6-milestone rewrite — so the shipped cube + M5c stays, and the
cheap real win from your idea is its cosmetic form: a 90-45-45-trimmed monument cap on
the M5c pillar.*
