# COSMOS-FACET-TILING-RESEARCH — octagons, hexagons, and the strategic tiling question

**Status:** research + verdict (read-only pass — no code changed, no flags added by this doc).
**Author:** research agent, 2026-07-20. **Commissioned question (user):** *"how do we ensure the
sides of all facets are stitched together properly — maybe use octagons instead of squares for
the facets?"*

**Scope split — read this first.** The *tactical* seam program is already owned and decided
elsewhere and this doc treats it as settled context, not as its subject:

- The seam **height step** (≤5.30 blocks ∝R) is the plane-datum mismatch, root-caused in
  `docs/COSMOS-FACET-SEAMS-DESIGN.md` §1; the shell see-through is §2.
- The first integer fix (`FP_RADIAL_DATUM`, per-column S = round(s), shipped default-off in
  `facet_atlas.gd:447` + C++ mirror patch `0009-cosmos-radial-datum.patch`) was **pilot-falsified:
  integer quantization of s terraces** — S jumps by 1 along the contour lines s = k+½, and since
  s sweeps 0 → 6.81 (sagitta) from corner to centre, ~7 stair-step contour rings cross the facet
  *interior*, not just the seam band. The terracing is the rounding, **not the tiling**.
- The replacement is decided: **FS2′ `FP_DATUM_BAKE`** — the *same* datum s(fid, x, z) left
  **unrounded/continuous** (∇s ≤ ~0.034 blocks/block, imperceptible shear), applied at the
  render/physics/input boundary (`y_play = y_cell + s`), voxel *data* byte-identical, interior
  smoothness identical by construction. Both render paths and the analytic sampler consume the
  same closed-form s, so render/collision divergence is zero by construction.

**This doc answers the strategic question that remains:** is the *square* facet tiling itself
wrong? Would octagons, or the hex+pentagon (Goldberg) tiling, stitch better? The answer is
built from three theorems, one in-repo prior proof, and an external survey — and it is a
decisive **no, keep the cube** — with the reasons quantified below so the decision is durable.

Companions: `COSMOS-PLANET-TOPOLOGY.md` (the LOCKED equal-angle cube-sphere choice and why),
`COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` (the 2026-07-12 study that — as shown in §2.3 below —
already *is* the octagon study under another name), `COSMOS-FACET-SEAMS-DESIGN.md` (the
tactical fix program: FS1 `FP_SHELL_WELD` shipped default-off, FS2 retired → FS2′).

---

## 0. Executive summary

1. **Regular octagons cannot tile a sphere or a plane by themselves** (interior angle 135°
   fits neither 360° nor any positive spherical defect with ≥3 faces per vertex — §2.1).
   Every octagon-bearing tiling must import other polygons, and those other polygons are
   where the curvature goes.
2. **The user's octagon intuition, made rigorous, is the truncated cube** (6 octagons + 8
   triangles): the octagonal faces are literally today's cube faces with 45°-cut corners, so
   octagon↔octagon seams inherit the existing D4 lattice algebra unchanged. This exact family
   was already studied in `COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` §4 with the verdict:
   geometrically real, **modestly better only within ~64–128 cells of each corner**
   (defect 8×90° → 24×30°, corner anisotropy 1.73 → 1.27), and **strictly more machinery**
   (4–6 milestones). It fixes *corners*, and the user's pain is *seams* — which octagons do
   not improve at all (§2.3–2.4).
3. **The user's concrete hybrid — hexagonal facets, each filled with the same axis-aligned
   square voxel grid, voxels clipped at the hex boundary — is evaluated head-to-head in
   §3.2.** The interior genuinely works (clipping is the existing border-cube trick;
   building inside one hex is locally identical to today). The cost is entirely at seams,
   and it is a **frame-rotation theorem, not a "squares don't fit hexagons" objection**: a
   square-grid direction field on a sphere is defined modulo 90°, so its singularities are
   quantized to 90° (index ¼) — the cube realizes exactly 8 of them and *zero in-plane grid
   rotation at every seam*; a Goldberg tiling's 12 pentagons carry 60° ∉ 90°·ℤ, which a
   square field **cannot absorb at a point**, so the mismatch is forced onto **seam lines**.
   Best case (optimized per-hex frames): ≥6 pentagon-to-pentagon grain-boundary arcs,
   ~42,000 blocks of seam across which grid lines do not continue. Naive case: essentially
   every seam misaligned by 30°-class rotations. Either way, for a *building* game the hex
   hybrid trades "8 brutal but policy-hidden corner points, all other seams grid-aligned"
   for "misalignment smeared along lines through the playable world" — strictly worse.
   The only consistent hex planet is **hexagonal-prism voxels** (PlanetSmith's route —
   §4.3), i.e. changing the *voxel*, not the tiling: a different game.
4. **No shipped engine solves the problem VOXIVERSE set for itself** (surface-aligned *square*
   voxels on a sphere). External practice splits into exactly two camps (§4): (a) one global
   3D lattice + smooth polygonization (Space Engineers, Astroneer, No Man's Sky) — which
   *dissolves* facet seams by giving up surface-aligned flat building; (b) surface-aligned
   voxels with a **changed voxel shape** (PlanetSmith's hex prisms). Cube-sphere *renderers*
   (non-voxel) all fix face seams the way FS1/FS2′ do: shared-edge welding, skirts, and
   projecting render vertices onto the true sphere.
5. **Ranked verdict (§5): (A) keep square facets + FS2′ + corner policy ≫ (B) chamfered /
   truncated-cube corner caps ≫ (C) hex facets with clipped square voxels.** (B) collapses
   to corner-only truncation because our K×K equal-angle faceting *already* chamfers the 12
   cube edges into ordinary 3.75° seams (§2.5) — its benefit is real but strictly local to
   the 8 already-ocean-forced corners, at 4–6-milestone cost. (C) fails on the
   frame-rotation theorem (§3.2). The remaining reported artifacts (invisible wall,
   unsmoothed border terrain, crossing orientation glitch) are **crossing-layer bugs, not
   tiling properties** — a hex planet would have crossings too, with *worse* (non-lattice,
   30°/60°-class) basis turns (§5.2).

---

## 1. First principles — what a tiling can and cannot buy you

Three facts frame every alternative. They are short but they decide everything.

### 1.1 Curvature is conserved: the 720° budget (Descartes / Gauss–Bonnet)

For any convex polyhedral approximation of the sphere, the sum of angular defects over all
vertices is exactly **720°**. A tiling never removes curvature; it only chooses *where to
concentrate it*:

| tiling | curvature carriers | defect each |
|---|---|---|
| cube (ours) | 8 corners | 90° |
| truncated cube (6 octagons + 8 triangles) | 24 vertices (3 per triangle cap) | 30° |
| truncated cuboctahedron (4.6.8) | 48 vertices | 15° |
| Goldberg GP(m,0) (hexes + 12 pentagons) | 60 vertices (5 per pentagon) | 12° |
| icosahedron | 12 corners | 60° |

Two consequences: (a) "octagons instead of squares" cannot make the planet rounder — it can
only *redistribute* the same 720°; (b) any redistribution's benefit is **strictly local**:
`COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` §4.3 proved (via Gauss–Bonnet on the enclosing loop)
that outside a truncation cap of depth t, the metric is *unchanged* — a cap must be as large
as the region you want to look better.

### 1.2 Seam dihedral is set by cell size, not polygon shape

The bend at a facet↔facet seam is (to first order) the angular diameter of a facet:
δ ≈ facet_edge / R. Ours: 90°/K = **3.75°** at K=24 (facet edge ≈ 417 blocks at R=6371).
A Goldberg tiling with the *same cell count* (≈3456 cells → GP(19,0), 3612 cells) has cells
of the same angular diameter and therefore **the same ~3.5–4° dihedral per seam**. "Hexagons
stitch more smoothly" is false at equal cell size; the sphere demands 1/R of bending per
unit distance no matter how you cut it. What hexes actually change: bends are distributed
over 3 edge orientations instead of 2 (marginally rounder silhouette) and the honeycomb
theorem gives ~6% less total seam length per unit area ([the honeycomb problem on the
sphere](https://arxiv.org/pdf/math/0211234)). Both effects are cosmetic at our scale.

### 1.3 The quad-defect quantization theorem (already proven in-repo)

`COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` §2 (re-confirming the projection study): **any surface
tiled purely by square cells has vertex defects quantized to multiples of 90°**, and with the
total fixed at 720°, the minimum-corner-count square-cell planet is *exactly* the cube —
8 × 90°. There is no square-voxel planet with milder corners than the one we have. Every
"better tiling" therefore requires **non-square cells somewhere**, and §§2–3 below are the
audit of where that "somewhere" lands and what it costs.

A corollary that matters just as much: the cube is the unique closed tiling whose face
adjacency maps are **exact isometries of the square lattice** (the D4 group — 90° rotations
+ integer translations). This is what makes `FacetAtlas.reframe_position64` /
`crossing_basis` exact, cross-seam cell adjacency 1:1, and the extended-window seam strategy
of `COSMOS-PLANET-TOPOLOGY.md` §4 possible at all. Keep this corollary in view: it is the
single property every alternative below fails.

### 1.4 The frame-rotation theorem (hairy ball, quantized for square grids)

The question "where does the square building grid point?" defines a tangent **direction
field mod 90°** (a *cross field*) over the whole planet. Two theorems govern it:

- **Poincaré–Hopf / hairy ball:** any tangent field on a sphere must have singularities of
  total index +2. For a field defined mod 90°, singularity indices are quantized to
  **multiples of ¼**, and an index-¼ point is exactly a **90° rotation defect** — the grid
  turns by a quarter-turn around it, which *is* a square-lattice symmetry, so the lattice
  closes up seamlessly around it.
- **Holonomy matching:** walking a small loop around any point, the accumulated in-plane
  grid rotation across the seams crossed must equal the enclosed angular defect (mod 90°).
  A defect ∈ 90°·ℤ can therefore be absorbed at an isolated point with zero-rotation seams
  everywhere around it. A defect ∉ 90°·ℤ **cannot**: some seam crossed by *every* loop
  around it must carry a non-lattice rotation jump — i.e. the mismatch is forced to run
  along a **line** (a branch cut / grain boundary) emanating from the point, ending only at
  another such fractional point.

The cube saturates the theorem perfectly: 8 corners × index ¼ = 2, defect 90° each — all
singular structure sits at 8 *points* that are lattice symmetries, and **every seam on the
planet carries zero in-plane grid rotation** (within faces the facet lattices are parallel
projections of one face grid; across the 12 cube edges the map is an exact 90° D4 fold —
out-of-plane dihedral only). This is why the 1:1 cross-seam column correspondence exists,
and thus why the FS2′ datum can make both sides of a seam agree column-for-column at all.
Any tiling whose defects are not multiples of 90° (pentagons: 60°; icosahedral corners:
60°; hex-tiling holonomy generally 60°-class) forces grid mismatch **off the points and
onto seam lines** — the decisive fact for §3.2.

---

## 2. The octagon question, answered with the actual math

### 2.1 Octagons alone: impossible, everywhere

Regular octagon interior angle = 135°. At any tiling vertex, q ≥ 3 faces must meet:

- **Plane** (angles sum to exactly 360°): 2×135° = 270° (needs a 90° filler — not an octagon);
  3×135° = 405° > 360°. No pure-octagon vertex exists. ∎
- **Sphere** (angles sum to < 360°, positive defect): q = 3 already overshoots (405° > 360°),
  and *spherical* octagons have angles > 135°, making it worse. q = 2 is degenerate (a lens,
  not a tiling). No pure-octagon spherical tiling exists. ∎
- Octagons-only *does* tile the **hyperbolic** plane ({8,3} — three per vertex, angle sum
  > 360°): octagons are natively negative-curvature polygons. A planet is positive-curvature.
  This is the deep reason the octagon instinct points the wrong way: adding octagons moves
  the tiling *away* from closing into a sphere, so companion polygons must carry even more
  concentrated positive curvature to compensate.

### 2.2 What octagon-bearing tilings actually exist

- **4.8.8 truncated-square tiling** (2 octagons + 1 square per vertex, 270+90 = 360): tiles
  the **plane** — and is *flat everywhere* (zero defect at every vertex). Zero defect means
  it **cannot close into a sphere** at all. In the plane it has one genuinely interesting
  property: all octagons and squares share one lattice orientation, so axis-aligned square
  voxel grids inside every cell stay mutually aligned (translation-only seams). But a planet
  cannot use it, period.
- **Truncated cube, 3.8.8** (2 octagons + 1 triangle per vertex, 135+135+60 = 330°, defect
  30° × 24 vertices = 720° ✓): the *only* way to wrap mostly-octagons around a sphere. And
  here is the punchline — see §2.3.
- **Truncated cuboctahedron, 4.6.8** (90+120+135 = 345°, defect 15° × 48 = 720° ✓): squares
  + hexagons + octagons. Three face shapes ⇒ three lattice families and three seam types
  (square↔hex, hex↔oct, oct↔square), of which only the square faces can hold an aligned
  voxel grid. Strictly more seam machinery than today for zero seam-smoothness gain (§1.2).
  Rejected without further analysis.

### 2.3 The punchline: "octagons" = the truncated cube = the corner study we already ran

The truncated cube's 6 octagonal faces are **today's 6 cube faces with their corners cut at
45°**. Octagon↔octagon adjacency is exactly cube-face adjacency — the same 12 edges, the
same D4 lattice isometries, the same seam algebra we ship. Nothing about the *seams between
facets* changes. All that changes is the 8 corners: each is replaced by a triangular cap,
splitting 90° of defect into 3 × 30°.

This precise family — square voxels in-face, 45° staircase cut boundaries, triangular corner
caps — is what `COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` §4–§5 analyzed exhaustively
(2026-07-12, triggered by the user's earlier triangular-border-blocks proposal, which is the
same polyhedron approached from the other side). Its verdict, which this pass re-endorses:

- **Geometrically real**: corner anisotropy bound 1.732 → ≈1.267 (icosahedron-gentle),
  wedge slack 90° → 30°.
- **Strictly local**: invisible beyond the cap (Gauss–Bonnet, §1.1(b) above); the cap must
  be t ≈ 64–128 cells deep to cover the visible corner zone.
- **Not simpler — a 4–6-milestone re-architecture**: non-separable projection, planet regen,
  square↔triangle seams at 24 new edges, two lattice families through physics/mesher/streaming,
  re-derivation of the corner pipeline — in the subsystem that produced the project's
  recurring frame bugs.

### 2.4 Does ANY octagon-bearing tiling help the square-voxel-building constraint?

No — it *hurts* it, in two independent ways:

1. **Filling a regular octagon with an axis-aligned square grid** aligns cleanly with its 4
   axis-parallel edges but leaves the 4 diagonal edges as **45° staircases** — every second
   facet boundary becomes a jagged sawtooth of half-exposed blocks. Building "up to the
   border" (clean today: the border is a lattice line) becomes building against a staircase.
2. The companion polygons (triangles in 3.8.8, hexes in 4.6.8) cannot hold an aligned square
   grid at all ⇒ non-buildable or special-cased zones larger and more numerous than the 8
   corner exclusion zones we ship today (`COSMOS-PLANET-TOPOLOGY.md` §5 already forces deep
   ocean + edit refusal at corners — the corners are *policy-hidden* at zero geometry cost).

**Octagon verdict: rejected.** Octagons do not and cannot address seam stitching (octagon
seams *are* our seams); the corner improvement they encode is real but local, already
studied, and priced at 4–6 milestones; and they actively degrade the building grid at every
diagonal boundary.

### 2.5 The chamfered-cube middle path (truncate corners + chamfer edges), priced honestly

The natural "soften the cube without leaving it" candidate: chamfer the 12 edges and/or
truncate the 8 corners, keeping 6 big grid-aligned square faces (option B of §5.1). Two
observations settle it:

- **Edge chamfering buys nothing — our edges are already chamfered.** A chamfer strip along
  a cube edge *is* grid-compatible (its lattice lines parallel to the edge match both
  neighbouring faces; the fold is purely out-of-plane, in-plane rotation 0 — D4 preserved;
  this is visible in the rhombicuboctahedron, whose 24 vertices carry 30° each with all
  square faces mutually grid-aligned). But the shipped K×K equal-angle faceting already
  distributes the 12 edges' 90° folds into ordinary ~3.75° facet seams — the 12 cube edges
  are *not* concentrated folds in VOXIVERSE's geometry; every edge lattice vertex is
  4-valent with defect 0 (`COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` §3: "edges are developable
  — triangles at edges solve a non-problem"). Chamfering an already-smooth edge is a no-op.
- **So the middle path collapses to corner-only truncation** — exactly the truncated-cube
  family of §2.3, with its already-delivered verdict: defect 8×90° → 24×30°, anisotropy
  1.73 → 1.27, benefit strictly local to caps of depth t (Gauss–Bonnet), cost 4–6 milestones
  (two lattice families, 24 square↔triangle staircase seams, non-separable projection,
  planet regen). Its one virtue over the hex path: it **preserves the zero-rotation-seam
  property everywhere outside the caps** (30° cap defects are not lattice symmetries, so the
  caps themselves hold no coherent square grid — they must be non-buildable trim, like the
  user's original triangular-border-blocks idea). Since the 8 corners are already
  ocean-forced and edit-refused (`COSMOS-PLANET-TOPOLOGY.md` §5), the *gameplay* value of
  the caps is nil today; the *visual* value is capped and achievable at ~1% of the cost with
  render-side corner smoothing (§5.3-2). **B is the best tiling change if one is ever
  forced — and still not worth making now.**

---

## 3. The real alternative — Goldberg / geodesic (hex + 12 pentagons)

### 3.1 What it is, and the honest quantified wins

A Goldberg polyhedron GP(m,n): hexagonal cells + **exactly 12 pentagons** (Euler's formula —
V − E + F = 2 forces 12 pentagons no matter how many hexes; see
[Red Blob Games' spherical-hex study](https://www.redblobgames.com/x/1640-hexagon-tiling-of-sphere/)).
Matching our ~3456-facet resolution: GP(19,0) = 3612 cells, cell diameter ≈ our 417 blocks.

Wins, quantified against the cube at equal cell count:

| property | cube K=24 | Goldberg GP(19,0) | win? |
|---|---|---|---|
| defect concentration | 8 × 90° | 12 pentagons × 60° (as 5 × 12° vertices each) | modest: worst point −33%, but 50% more special points |
| seam dihedral (typ.) | ~3.75° | ~3.5–4° | **none** (§1.2 — set by cell size) |
| seam length / area | 1.0 | ≈0.94 (honeycomb theorem) | ~6%, cosmetic |
| cell shape uniformity | anisotropy →√3 at 8 corners (equal-angle warp; area spread ≈1.3:1) | naive geodesic area spread ≈1.2–1.9:1; equal-area (ISEA-class) variants exist | ties, roughly — uniformity is achievable in both families |
| neighbour topology | 4 edge + 4 diagonal (ambiguity) | 6 edge, no diagonals | genuinely nicer for streaming/LOD rings |
| special zones a player meets | 8 corners (policy: ocean-forced, edit-refused) | 12 pentagons (must be policy-hidden the same way) | wash |

So the *geometry* win is real but small: the planet is at best "a bit rounder at 12 points
instead of 8," with identical seam bending everywhere else. Now the disqualifier.

### 3.2 The user's hybrid, head-to-head: hex facets + clipped square voxel grid

The proposal, stated fairly: keep the square axis-aligned voxel micro-grid for building, but
make the *macro* facets hexagonal (Goldberg tiling, per-facet local frames), **clipping**
voxels at the hex boundary with the existing border-cube clipping machinery (the junction
clip-plane / facet-carve trick, patch `0004-facet-carve.patch`). Gentle hex seams outside,
Minecraft building inside. Evaluate each half on its merits:

**The interior half works — confirmed.** Inside one hex facet the proposal is locally
identical to today: an axis-aligned square lattice on the facet's mean plane, columns along
n̂, the analytic sampler unchanged, and the boundary handled by clip planes cutting partial
cubes — precisely the shipped border-cube technique, just against 6 planes instead of 4.
Building, collision, streaming *within* a hex: no new problems. If facets never met, this
would be free.

**The seam half fails on the frame-rotation theorem (§1.4) — and this is the load-bearing
argument, not "squares don't fit hexagons."** The question is not whether a hex can contain
squares (it can); it is **where the square grid's direction field puts its mandatory
singularities**:

1. **The cube concentrates; the hex tiling smears.** The cube's assignment — 6 faces of
   perfectly parallel grid, 12 edges of exact 90° D4 folds (in-plane rotation ≡ 0 mod 90°),
   8 corners absorbing index ¼ each — is the *optimal* solution of the §1.4 constraint: all
   rotation lives at 8 points which are lattice symmetries, and **every seam is
   grid-aligned with a 1:1 column correspondence** (this correspondence is what lets the
   FS2′ datum make the two sides agree column-for-column, and what makes
   `reframe_position64`/`crossing_basis` exact integers+quarter-turns). A Goldberg tiling
   destroys this: its 12 pentagons each carry a 60° defect, and **60° ∉ 90°·ℤ**, so by the
   holonomy-matching theorem a square field cannot absorb a pentagon at a point. The
   mismatch is *forced off the points and onto seams*.
2. **Best case, quantified (optimized per-hex frames).** Choose every hex's square frame as
   coherently as possible: all seams can be driven to ~0° in-plane rotation *except* along
   branch cuts that must emanate from each pentagon (carrying a 30°-class rotation jump)
   and can terminate only at another pentagon. Twelve pentagons ⇒ **≥ 6 grain-boundary
   arcs**. The pentagons sit at icosahedron vertices (nearest-neighbour arc 63.4°); a
   minimal perfect matching along icosahedral edges gives 6 arcs × 1.107·R ≈ 7,050 blocks
   ≈ **42,000 blocks of grain boundary** at R = 6371. Along every block of those arcs, the
   two sides' lattices meet at 30°/60° — an incommensurate moiré (crystallographically a
   high-angle grain boundary): **no cell-to-cell correspondence, grid lines do not
   continue, block faces are sliced arbitrarily against rotated neighbours.** Compare the
   cube: 8 *points*, total exclusion area ~8·π·48² ≈ 58k cells of policy ocean. The hybrid
   converts point defects into **line defects through the playable world** — and unlike
   the fixed corners, hiding 42,000 blocks of arcs under ocean requires worldgen to
   guarantee connected ocean channels linking all 12 pentagon zones on every seed.
3. **Naive case (each hex frames itself — e.g. from its geodesic parent triangle or local
   north).** Then essentially **every** hex↔hex seam carries a 30°-class in-plane rotation:
   grid lines break at every border, cross-seam terrain continuity becomes cross-lattice
   resampling everywhere, and the FS2′-style datum (which presumes matched columns) has
   nothing to match. This is the configuration people intuit when they say "hexes are
   smooth": smooth in *dihedral* (which §1.2 shows is a wash anyway), incoherent in *grid*.
4. **What concretely breaks at a grain seam** (each a load-bearing engine contract):
   `block_id_at` cross-seam queries and the extended one-rectilinear-lattice seam window
   (`COSMOS-PLANET-TOPOLOGY.md` §4); `reframe_position64`/`crossing_basis` exactness — a
   crossing would rotate the player's *building grid* by 30°/60°, so structures cannot
   continue across a seam (the #1 gameplay regression); the analytic sampler (`floor_under`,
   per-axis `blocked()`) — polygon clipping against rotated foreign cells instead of integer
   indexing; `godot_voxel` box streaming, the C++ generator's per-column loops, the D4 edge
   tables, `_collapse_unsupported`'s flood fill. The border-*clipping* trick itself only
   covers the geometry half: our matched junction-block pairs exist because the two lattices
   mirror each other across the seam (a D4 property) — under a 30° relative rotation the
   clip planes of the two sides no longer pair.
5. **And the 12 pentagons remain**, holding no square grid at all — 12 non-buildable
   special zones (vs the cube's 8), each additionally the anchor of a grain arc.

**Head-to-head answer to the commissioned question:** yes — the framing is correct and the
math confirms it. Hex-with-clipped-squares trades *"8 brutal corners, every seam perfect"*
for *"12 corners that are still special, plus mild-looking seams that are each broken for
building"* — either all of them (naive) or ≥42,000 blocks of them routed through the world
(optimal). For a renderer that would be a defensible trade; **for a building game it is
strictly the wrong direction**, because building quality is min-over-seams, not
average-over-seams: a seam where the grid continues is *invisible* to the builder (post-
FS2′), while a seam where it doesn't is a permanent wall — and the hybrid multiplies the
latter. Concentrated beats distributed. **Rejected.**

### 3.3 The consistent hex planet: change the voxel, not the tiling

The one coherent way to use Goldberg: **hexagonal-prism voxels** whose lattice *is* the hex
tiling (each facet a patch of hex columns; the 12 pentagons become pentagonal-prism columns,
special-cased forever). This is precisely what **PlanetSmith** ships (§4.3) — and it works
*because* the hex-prism lattice's symmetry group (60° rotations) matches hex adjacency, the
same alignment the cube gives squares. For VOXIVERSE it means: replace `godot_voxel` (cubic
buffers) and both meshers, rewrite the crossing algebra, collision, collapse, all worldgen
indexing — and abandon the Minecraft-square building feel that is the project's stated
identity. That is not a fix; it is a different game. **Cost: total re-architecture (multi-
month), for a benefit already shown in §3.1 to be small. Rejected.**

---

## 4. External survey — how real engines actually handle this

The field splits into two camps plus a renderer tradition; notably, **no shipped engine does
surface-aligned square voxels on a sphere** — every one either drops surface alignment or
drops squareness.

### 4.1 Camp A — one global 3D lattice + smooth polygonization (seams dissolved, flatness abandoned)

- **Astroneer**: marching cubes over chunked voxel data; deformation edits voxels and
  re-polygonizes the local chunk ([Game Developer interview](https://www.gamedeveloper.com/design/what-i-astroneer-i-s-devs-learned-while-leaving-early-access)).
- **Space Engineers**: sparse global voxel field, implicit-surface extraction
  ([community/engineering discussion](https://steamcommunity.com/app/244850/discussions/0/1489992080509613812/?ctp=2)).
- **No Man's Sky**: voxel-based generation → polygonization → population, continuous LOD
  ([GDC 2017, "Continuous World Generation in No Man's Sky"](https://www.gdcvault.com/play/1024265/Continuous-World-Generation-in-No)).

These engines have *no facet seams* because the voxel lattice is one global axis-aligned 3D
grid (or an implicit field): "up" is not a lattice axis, terrain is smooth (marching cubes /
dual contouring), and nobody promises Minecraft-flat gravity-aligned building on the natural
terrain. Their seam problem is the *LOD* seam, solved by transition cells
([Transvoxel](https://transvoxel.org/), [Lengyel's dissertation](https://transvoxel.org/Lengyel-VoxelTerrain.pdf)),
octree-aware dual contouring ([Gildea](http://ngildea.blogspot.com/2014/09/dual-contouring-chunked-terrain.html)),
or skirts. **Lesson for us:** adopting Camp A = giving up invariant #1 (the axis-aligned
in-facet voxel grid). Explicitly a major re-architecture; not recommended, but recorded as
the industry default for a reason — it is the only known way to make the seam problem
*vanish* rather than be managed.

### 4.2 Cube-sphere renderers (non-voxel): our FS1/FS2′ are the standard practice

Planet-scale terrain renderers overwhelmingly use the cube-sphere (spherified or equal-angle
cube, quadtree per face) and handle face/patch seams with exactly the toolkit the seams
program adopts: **project render vertices onto the true sphere** (the analogue of FS2′'s
continuous datum — the surface as a pure function of direction), **share edge vertices
bit-identically across patches** (the analogue of FS1's shared-corner-direction weld),
constrain fine edges to coarse polylines at LOD T-junctions (FS1's coarse-owns-edge rule),
plus skirts and geomorphing as backstops. Equal-area cube variants (COBE quadrilateralized
spherical cube; Nagata/tangent-adjusted cubes) trade separability for area uniformity —
`COSMOS-PLANET-TOPOLOGY.md` already weighed this and locked equal-angle *because*
separability is what proves the 12 cube edges stitch cell-for-cell 1:1. Nothing found in
this survey argues for reopening that decision. **Lesson:** the tactical program (weld +
continuous datum) is not a house hack; it is the field's convergent solution.

### 4.3 Camp B — the one shipped hex planet: PlanetSmith

[PlanetSmith](https://store.steampowered.com/app/2539340/PlanetSmith/) (open beta; EA 2027)
is the only found game with **surface-aligned voxels on a real sphere**: "the worlds are made
out of hexagonal blocks which … allows for the surface to be curved into a planet"
([press kit](https://planetsmith.world/press); dev retrospective:
["I Spent 5 Years Building a Voxel Survival Game Where the World Is a Planet"](https://www.youtube.com/watch?v=-QL42dGHsmY)).
The blocks are hexagonal prisms on a geodesic/Goldberg-class tiling (12 pentagons hidden in
the hex field, per the Euler constraint — the press kit does not document the tiling, but no
alternative exists mathematically). Note both the confirmation and the caution:
- Confirmation: hexagons *do* enable seamless spherical voxel worlds — by making the voxel
  lattice's symmetry match the tiling's (§3.3), and it took a dedicated engine ~5 years.
- Caution: they did **not** put square voxels in hex facets — no one has, because §3.2 says
  you can't. And "seamless" is bought at the price of hexagonal building, a deliberately
  different design identity from Minecraft-square.

Also consistent with [Red Blob's spherical-hex analysis](https://www.redblobgames.com/x/1640-hexagon-tiling-of-sphere/):
the world "looks flat near the player as long as you don't get near the pentagons" — the 12
pentagons are hex-world corners, policy-hidden exactly like our 8 ocean-forced cube corners.
Every tiling has its corners; every shipped design hides them with content policy.

### 4.4 Minecraft-like planet mods

Surveyed approaches (Galacticraft and kin) keep **flat separate dimensions per planet** and
fake the sphere at the skybox/space-transition level — i.e., they decline the problem
entirely. VOXIVERSE's faceted pivot (piecewise-flat facets + curvature at seams) is already
strictly beyond shipped Minecraft-planet practice; there is no external prior art to copy at
this layer, which is why the in-repo probe-and-theorem work (seams design §1–2, the
topology studies) is the correct methodology.

---

## 5. Verdict and ranked recommendation

### 5.1 The strategic answer, ranked: A ≫ B ≫ C

**(A) Keep square cube-sphere facets + FS2′ continuous datum + FS1 shell weld +
corner-commit/crossing polish — the answer, now and long-term.** §1.3/§1.4 are the whole
story: the cube is the unique sphere tiling whose adjacency/holonomy group is a symmetry of
the square lattice — all mandatory curvature sits at 8 lattice-symmetric points, and every
seam on the planet has a 1:1 grid-aligned column correspondence. That correspondence is
precisely what makes the FS2′ datum able to *close* the seams (both sides agree
column-for-column on a surface that is a pure function of d̂), reducing residual seam
texture to the same ±1-block quantization the terrain has everywhere. Cost: already built
(default-off flags), zero new persistent memory. The 8 corners stay policy-hidden ocean.

**(B) Chamfered/truncated-cube corner caps — the best tiling change if one is ever forced;
still not now.** §2.5: edge chamfering is a no-op (K×K equal-angle faceting already smears
the edge folds to 3.75° seams), so B collapses to corner-only truncation = the studied
truncated cube: 8×90° → 24×30°, anisotropy 1.73 → 1.27, benefit strictly local to the caps
(Gauss–Bonnet), caps themselves non-buildable trim, **zero-rotation seams preserved
everywhere else** (its decisive virtue over C). Price: 4–6 milestones, two lattice
families, planet regen — for corners that are ocean-forced and edit-refused anyway.
Reconsider only if corners ever become playable land; until then, render-side corner
smoothing (§5.3-2) captures the visible benefit at ~1% of the cost.

**(C) Hex facets with clipped square voxels — rejected on the frame-rotation theorem.**
§3.2: the interior works, but pentagons' 60° defects are not square-lattice symmetries, so
grid mismatch is forced onto seam *lines* — best case ≥6 grain arcs ≈ 42,000 blocks, naive
case every seam — through the playable world, breaking cross-seam building exactly where
the cube keeps it perfect. For a building game, concentrated point defects beat distributed
line defects, categorically. (Hex-*prism* voxels — PlanetSmith's consistent version — and
the global-3D-lattice smooth-terrain route are coherent but are different games: total
re-architecture, abandoning the Minecraft-square identity. Argue them only ever as a
product pivot, never as a seam fix.)

Bottom line for the user's question: **the seams are stitched by making the rendered/played
surface a pure function of the sphere direction (FS1 + FS2′), not by changing the polygon.**
Octagons and hexagons redistribute curvature; they cannot remove it (§1.1), they do not
soften seam bending at equal cell size (§1.2), and they sacrifice the one property that
makes VOXIVERSE's seams *closable* at all — the grid-aligned 1:1 seam correspondence.

### 5.2 What actually fixes the user's reported artifacts (all tiling-independent)

| artifact | root layer | fix (owner) |
|---|---|---|
| terracing (stairs into facet middle) | integer round(s) in FP_RADIAL_DATUM | **FS2′ `FP_DATUM_BAKE`** — continuous s at the render/physics boundary (decided; owned by the seams program) |
| seam cliffs / unsmoothed border terrain | plane-datum mismatch ∝R | same FS2′ (both sides land on R+g, a pure function of d̂) + existing junction bevels finally meeting at matched heights |
| see-through shell slits | per-facet planar chords | **FS1 `FP_SHELL_WELD`** (implemented, default-off — flip after live pass) |
| “invisible wall” at borders | collision seam: cross-facet floor/`blocked()` queries disagreeing with the neighbour's datum during/near crossing | apply the *same* continuous datum in every analytic-sampler exit on both sides (FS2′ touchpoint list), then re-test; if residue remains it is a crossing-window bug (extended-window fill rule), not geometry |
| orientation glitch when crossing | `crossing_basis` dihedral turn application to look/velocity | crossing-layer polish (velocity/look re-frame timing, hysteresis) — note a hex tiling would make this *worse*: 60°-class turns instead of 3.75° dihedral + exact D4 |

None of these five is a property of the square tiling; a tiling change would fix none of
them and would break the machinery that fixes them.

### 5.3 Ranked plan

1. **Now (ship):** FS0 gate + FS1 `FP_SHELL_WELD` (already implemented, default-off) +
   **FS2′ `FP_DATUM_BAKE`** (continuous datum; retires integer `FP_RADIAL_DATUM` — keep the
   flag returning S≡0/retired per the seams program) + the §5.2 collision/crossing passes.
   All default-off, byte-identical off, sed-flip at export — the established pattern.
   NEVER-OOM: zero new persistent bytes (closed-form s; same caches, new values).
2. **Medium term (optional, cosmetic):** corner-zone *render* softening — since corners are
   already ocean-forced and edit-refused, a render-only smoothing of the far-shell/skin in
   the 8 corner caps (no lattice change, no new tiling) captures most of what truncation
   would visibly buy at ~1% of its cost. Only if live pilots still flag corners after FS2′.
3. **Deferred, not scheduled (B):** truncated-cube corner caps (§2.5) — record the trigger
   condition explicitly: *only if the 8 corners ever become playable land*. Otherwise the
   render-side smoothing in (2) permanently substitutes.
4. **Explicitly rejected (recorded so it stays decided, C and kin):** pure-octagon and
   octagon-bearing tilings as seam fixes (§2), hex facets with clipped square voxels — the
   frame-rotation theorem, §3.2 — hex-prism voxels (§3.3), global-3D-lattice smooth terrain
   (§4.1). Reopen only as a product pivot, never as a seam fix.

---

## Sources

- In-repo: `docs/COSMOS-FACET-SEAMS-DESIGN.md` (root causes, FS1/FS2/FS2′, measured 5.30/2.77/6.81 ∝R table);
  `docs/COSMOS-TRIANGULAR-TOPOLOGY-STUDY.md` (quad-defect quantization; truncated-cube family verdict);
  `docs/COSMOS-PLANET-TOPOLOGY.md` (locked equal-angle cube, separability/edge-stitch proof, corner policy);
  `godot/src/cosmos/facet_atlas.gd` (`datum_shift`, `facet_corner_dirs`, D4 crossing algebra);
  `godot/src/cosmos/cube_sphere.gd` (`FP_SHELL_WELD`, `FP_RADIAL_DATUM` registry);
  `docker/engine/patches/godot_voxel/0009-cosmos-radial-datum.patch`.
- [PlanetSmith on Steam](https://store.steampowered.com/app/2539340/PlanetSmith/) · [press kit](https://planetsmith.world/press) · [dev retrospective (YouTube)](https://www.youtube.com/watch?v=-QL42dGHsmY)
- [Red Blob Games — Wraparound hexagon tile maps on a sphere](https://www.redblobgames.com/x/1640-hexagon-tiling-of-sphere/)
- [The Honeycomb Problem on the Sphere (Hales)](https://arxiv.org/pdf/math/0211234)
- [Transvoxel algorithm](https://transvoxel.org/) · [Lengyel, Voxel-Based Terrain for Real-Time Virtual Simulations](https://transvoxel.org/Lengyel-VoxelTerrain.pdf)
- [Gildea — Dual Contouring: Seams & LOD for Chunked Terrain](http://ngildea.blogspot.com/2014/09/dual-contouring-chunked-terrain.html)
- [GDC 2017 — Continuous World Generation in No Man's Sky](https://www.gdcvault.com/play/1024265/Continuous-World-Generation-in-No)
- [Game Developer — What Astroneer's devs learned](https://www.gamedeveloper.com/design/what-i-astroneer-i-s-devs-learned-while-leaving-early-access)
- [Space Engineers voxel discussion](https://steamcommunity.com/app/244850/discussions/0/1489992080509613812/?ctp=2)
