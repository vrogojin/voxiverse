# COSMOS-FACETED-PLANET-STUDY — the piecewise-flat planet: undistorted square facets, curvature at the seams

Status: RESEARCH + DESIGN (Fable, 2026-07-12). Trigger: the user's decision to abandon
the smooth cube→sphere warp: *"step back and implement true near-spherical geometry
with multiple flat faces (octagon or hexagon, whatever makes sense) that assemble to
approximate a spheric shape. Face junction border blocks should be triangular whenever
needed or normal squares where it is normal. No more transforming cube into sphere."*
The ask: feasibility, and a design that reuses as much of the existing code as makes
sense.

Companions — and why neither answered this: COSMOS-PROJECTION-STUDY (branch
`docs/voxiverse-cosmos-projection-study`) proved the cube-sphere optimal **for a smooth
warp over one continuous square lattice**; COSMOS-TRIANGULAR-TOPOLOGY-STUDY analysed
triangular border cells **under that same smooth warp**. Both operated inside the
assumption this proposal drops: that the voxel lattice is continuous across the whole
planet. The faceted planet is a genuinely new axis (§1), and several of the prior
no-go theorems legitimately do not apply to it.

All numbers computed exactly from the engine's own map (equal-angle cube-sphere grid,
`d̂ = normalize(n̂ + tan(aπ/4)û + tan(bπ/4)v̂)`, earth body R = 6371 blocks), by direct
construction of the faceted polyhedron at each k: facet planes, dihedrals, planarized
corner angles, vertex defects (checked to sum to exactly 720.00°), seam steps, and
grid-twist under two orientation assignments.

---

## 0. Executive summary — the three-way verdict first

1. **Feasible — yes, and web-safer than what we have.** The faceted planet is an
   assembly of ~1,500 *flat voxel worlds* (facets) glued by a seam layer. Every facet
   meshes with the **stock flat mesher** (no C++ bake hook, no bend/placement shaders,
   nothing chart-shaped near the GPU), renders as a static node with one rigid
   `Transform3D`, and runs the existing analytic physics unmodified. The whole planet
   fits f32 (R ≈ 6371 → position ULP ~0.001 blocks): true-space static geometry +
   moving camera — the R2/Design-Z idea in its purest form, with the per-vertex
   spherical bake replaced by a per-*facet* rigid transform.
2. **Better — for the stated goal, unambiguously.** Inside a facet, cell distortion is
   **exactly zero by construction** (vs the smooth warp's S ∈ [0.666, 1.154] and √3
   corner anisotropy). And the 8 × 90° corner problem genuinely dissolves: measured
   vertex defects at k = 16 are ≤ 0.55° everywhere, **0.47° at the old cube corners**
   — ordinary vertices; no wedge, no anomaly, no M5c (§3, §5). The prior studies'
   "more faces cannot help" theorem does not apply because faceting abandons lattice
   continuity across seams — which is precisely where the cost reappears (§5): a
   dihedral ridge network (5.2° mean turn at k = 16, every ~625 blocks), ~1.4% of the
   surface as non-buildable seam strip, seam datum steps up to ~11 blocks near the old
   corners, and 8 unavoidable grid-orientation singularities (Poincaré–Hopf) where
   bricks meet at 22–30° on a handful of seams.
3. **Simpler — yes, net, as a destination.** The pivot **deletes** the entire smooth-
   warp stack — CosmosBend, CosmosTruePlace + the C++ mesher bake hook, the J⁻¹ input
   map, `M_win`, `fold_cell` as runtime algebra, home-face flips + eager corner flips,
   the wedge, M5c (pillar/anomaly/edit-lock), the 43-bit fold keys — and **adds** a
   static one-shot FacetAtlas, a seam-strip generator, and a facet-crossing handoff
   (§7). The class of bug that consumed #68–#77 (sliding-window frame orientation)
   dies structurally: there is no sliding window and no D4 flip left to get wrong.
   The residual hard part is *conventional* streaming engineering (zone handoffs, LOD
   stitching), not differential geometry. **But it is a restart of the COSMOS
   topology/render layer** — planet regeneration, ~5 milestones + a cheap visual
   spike, all COSMOS gates re-derived. It is a simpler *destination*, not a shortcut.
4. **Recommendation:** the **k × k faceted quad-sphere, k = 16** for earth (1,536
   quad facets, ~625-block facets, 5.2° ridges, silhouette 0.12% out-of-round — reads
   round from orbit, reads "flat world with occasional gentle fold-lines" from the
   ground). "Hexagons/octagons" cannot carry square voxel grids (§2) — the correct
   reading of the user's instinct is *many small quad facets*. Run the **FP0 visual
   spike first** (days): assemble a 3-facet ridge + an old-corner cluster from
   far-builder meshes and let the user judge the ridge aesthetic before any engine
   work. That look — a faceted planet with visible fold-lines — is the one
   irreversible taste decision in this pivot.

## 1. What is genuinely new: dropping lattice continuity (why the old theorems don't bind)

The projection study's quantization theorem — vertex defects on a square-tiled surface
are multiples of 90°, hence 8 × 90° is the best any square planet can do — has a
hypothesis: **one square lattice, edge-to-edge, continuous across the whole surface**.
Both prior studies (and the shipped engine: one window lattice + exact integer D4
remaps) live inside that hypothesis.

The faceted planet abandons it. Each facet carries its **own private square lattice**;
at a seam, two lattices simply *end*, at a dihedral angle, with no integer (or any)
remap between them. Seam relationships become **data** (an f64 rigid transform per
adjacency, precomputed in an atlas), not **algebra** (integer D4 matrices). Once
lattice continuity is gone:

- Vertex defects are no longer quantized to 90° — they can be (and measured: are)
  spread nearly uniformly at ~720°/(6k²) each (§3). The 8 fat corners dissolve.
- In exchange, *every* seam is a lattice discontinuity: bricks across it need not
  align in phase, and cannot all align in orientation (§5.3).

That is the entire trade, stated up front: the smooth warp buys one global lattice by
concentrating 720° into 8 harsh points and smearing metric distortion over every cell;
faceting buys **perfect cells everywhere** by shattering the lattice into ~6k² islands
and paying at the seams. Everything below quantifies that price.

## 2. The polyhedron menu — and the blunt part about hexagons and octagons

A facet must carry a square voxel grid, i.e. be a planar region tileable by unit
squares — any planar *quad* region qualifies (the grid is ours; the boundary just
clips it). Regular hexagons/octagons as *lattice cells* do not exist in a square
world; as *face shapes* the only square-grid-compatible octagon is the truncated
cube's 45°-cut square (prior study §4.1). The honest enumeration:

| Polyhedron | facets | facet shape | ridge turn (180°−dihedral) | verdict |
|---|---|---|---|---|
| Cube (k = 1) | 6 | square | **90°** | the degenerate case: gravity flips 90° at edges — rejected at project start |
| Truncated cube | 6 + 8 | octagon (square grid, 45° corners) + triangle caps | **90°** oct–oct, 54.7° oct–tri | keeps the cube's 90° edge folds — fails "approximate a sphere"; reject |
| Rhombicuboctahedron | 18 + 8 | **congruent squares** + triangles | 45° □–□, 35.3° □–△ | the "exact assembly" pole: identical M×M facets, exact edge match, zero gaps, zero twist off the triangles — but 35–45° gravity steps; too harsh for a walkable earth. Noted as a charming option for **small stylized bodies** (moons/asteroids) |
| **k × k faceted quad-sphere** | **6k²** | near-square quads (rhombic near old corners) | **90°/k** (measured 4.2–5.8° at k = 16) | **the design** — tunable smoothness, derived from the engine's own grid |
| Geodesic / Goldberg quad meshes | ~6k² | non-congruent quads | ~90°/k | same defect total, same seam classes, none of our math — dominated by the cube-derived version |

**The k × k faceted quad-sphere** (the recommendation): subdivide each cube face
k × k on the **equal-angle grid the engine already uses**, project the lattice
vertices to the sphere, and make each resulting quad a *flat* facet (construction
details in §3.1 — the 4 projected corners are not exactly coplanar, and handling that
honestly is a real design point). 6k² facets, 12k² seams, 6k² + 2 vertices. The
equal-angle spacing is exactly what makes the dihedrals uniform (±15% — gnomonic
spacing would make edge-adjacent dihedrals ~1.6× the centre ones), so the shipped
warp survives as the *facet placement function*.

## 3. The faceted quad-sphere, measured

### 3.1 Construction: planarized facets + welded boundary rings

Three constructions were evaluated numerically; two fail:

- **Tangent-plane polyhedron** (facet = tangent plane at each cell centre,
  intersected with neighbours): exactly planar and watertight *mid-face*, but near
  the old cube corners the 4 planes around a lattice vertex are far from concurrent —
  the two triple-points separate by up to **425 blocks** at k = 16 (277 at the
  corner-adjacent vertex). The polyhedron's combinatorics reorganize (long diagonal
  edges, pentagonal faces) — the clean 6k² quad bookkeeping is destroyed. Reject.
- **Inscribed quads used raw**: the 4 sphere-projected corners of a quad are
  non-coplanar by up to **5.96 blocks** at k = 16 (20.6 at k = 8) — the "sag". A
  non-flat facet defeats the whole point. Reject.
- **Inscribed + planarized + welded (the design):** fit each facet's plane to its 4
  sphere corners (best-fit; sag ≤ 5.96 blocks means each corner moves ≤ ~3 blocks
  onto the plane). Adjacent facets then disagree along the shared edge by a **seam
  step** — measured max |d_A − d_B| along the true chord: **p50 2.6 / p99 11.1 /
  max 11.9 blocks at k = 16**, decaying linearly from the old corners (11.1 at the
  corner-adjacent seams → 0.7 blocks seven facets out; at k = 24: max 5.3). The fix
  is structural: each seam gets ONE **welded boundary ring** (average of the two
  facets' edge lines, stored in the atlas); both facets' meshes and the seam strip
  terminate on that shared ring, so the assembly is watertight *by construction* and
  the step becomes an internal grade of the seam strip (§6). Facet interiors stay
  perfectly planar; only the strip bends.

### 3.2 The numbers table (earth, R = 6371 blocks)

| k | facets | facet size (blocks, mid-face / smallest) | ridge turn mean/max | silhouette sag (blocks, % R) | max vertex defect | sag max | seam step p50/max | 4-blk strip, % of surface |
|---|---|---|---|---|---|---|---|---|
| 8 | 384 | 1249 / 890 | 10.4° / 11.8° | 30.7 (0.48%) | 2.20° | 20.6 | 9.7 / 35.4 | 0.70% |
| 12 | 864 | 833 / — | 7.0° / 7.7° | 13.6 (0.21%) | 0.98° | 10.1 | — | ~1.0% |
| **16** | **1536** | **625 / 443** | **5.2° / 5.8°** | **7.7 (0.12%)** | **0.55°** | **6.0** | **2.6 / 11.9** | **1.40%** |
| 24 | 3456 | 417 / — | 3.5° / 3.8° | 3.4 (0.05%) | 0.25° | 2.8 | 1.1 / 5.5 | 2.10% |
| 32 | 6144 | 313 / — | 2.6° / 2.8° | 1.9 (0.03%) | 0.14° | 1.6 | — | ~2.8% |

Gauss–Bonnet check: defects sum to **720.00°** exactly at every k. The old cube
corners are valence-3 vertices with defect **0.47°** at k = 16 — *milder than the
average interior vertex would be on a uniform split*. The corner problem, as a
metric concentration, is gone.

**k = 16 is the sweet spot** for earth: ridges gentle enough to walk without ceremony
(5.2° ≈ a mild ramp transition), facets big enough to be worlds (625 blocks ≈ 2–3
minutes' walk edge to edge), steps small enough for the strip to absorb as banks
(≤ 12 blocks, and only near the 8 old corners), facet count (1,536) trivial for a
static atlas. k = 8 reads distinctly low-poly (10.4° ridges, 20-block sags, 35-block
steps); k = 24 halves every seam artifact but doubles seam density and handoff
cadence. Per-body: hold facet size ~600 rather than k — mars k ≈ 8, moon k ≈ 4–5
(22° ridges: a visibly chunky stylized moon, which is honest and arguably charming).

Facet shapes: mid-face facets are near-rectangles (corner angles 90° ± a few
degrees); facets in the corner *quadrants* are progressively rhombic, ending at the
corner facet itself with angles **[113.6°, 63.3°, 119.8°, 63.3°]** at k = 16 (the
spherical cube's 120° corner, inherited as boundary shape). At k = 16, 27% of facets
have a corner angle ≥ 15° off square. **This costs nothing inside the facet** — the
voxel grid is ours and stays square; a rhombic facet is a flat world with a rhombic
*border* (staircase clipping at two edges, handled by the same boundary mask as every
other facet). It matters only as seam bookkeeping (§5.3, §6).

## 4. Does faceting deliver the win the user wants? (Q2)

**Yes — the core claim survives quantification.** Inside a facet, the render *is* a
flat voxel world: every cell a perfect unit cube, zero anisotropy, zero area error,
at every distance from every seam — not "S ∈ [0.666, 1.154], milder than feared" but
exactly 1.0, everywhere a player stands. The three residuals, honestly:

1. **Non-planarity of projected quads** — real (sag ≤ 6 blocks at k = 16) but fully
   absorbed at construction: planes are fitted, boundaries welded (§3.1); the residue
   is the seam-strip internal grade, never a distorted cell.
2. **The dihedral ridge** — the curvature the warp used to smear over every cell now
   stands as visible fold-lines every ~625 blocks: a 5.2° kink in the ground plane
   and in gravity (§7). From orbit the silhouette is a 64-gon (0.12% out-of-round —
   visually a circle). This is not a defect; it is the aesthetic the user is
   explicitly choosing. FP0 exists to confirm they like it in person.
3. **Border blocks** — at 5.2°, the "triangular blocks" the user pictured are barely
   needed as *shapes*: a 5.2° miter across a 4-block strip is a 0.36-block rise —
   **one half-slab step of the existing corner-height slope family** (`ShapeCodec`
   quantizes to half-blocks; the strip's bank uses the shipped shapes, D4 payload
   rules and all). Genuine triangular *prism* geometry appears only in the strip's
   generated bridge mesh (§6), not as a new lattice cell type. At small k (chunky
   bodies, 18–22° ridges) the same strip design holds with taller banks.

## 5. Gauss–Bonnet, honestly: where the 720° actually goes (Q3)

Faceting does not destroy curvature; it re-houses it. Three ledgers, all measured:

### 5.1 Vertex defects: genuinely dissolved

720.00° spread over 6k² + 2 vertices: max 0.55°, old corners 0.47° (k = 16). No
vertex needs *any* special gameplay handling — no pillar, no anomaly, no edit lock,
no eager flip. The prior studies' corner machinery is not "re-derived at 24 vertices"
(the truncated-cube outcome) — it is **deleted** (§7.2). This is the decisive
structural difference from every option analysed under the smooth warp.

### 5.2 Facet shape: concentrated at the old corners, cost = bookkeeping only

The 8 corner quadrants inherit rhombic facet *boundaries* (§3.2) and the largest seam
steps (11 blocks) and sags. All of it lands in the atlas and the strip generator —
none of it in cells, physics, or the player's hands.

### 5.3 Grid orientation: the one true conserved residue — 8 twist singularities

Bricks across a seam can differ in **phase** (sub-block offset — unavoidable and
cosmetically negligible, facet dimensions are irrational in blocks) and in
**orientation** (twist). Twist is governed by a mod-90° holonomy: around any facet
loop, seam twists sum to −(enclosed defect) mod 90°. Since every vertex defect is
≤ 0.55°, *locally* twist-free assignments exist around every single vertex — but
globally, a square-grid (cross) field on a sphere must carry total index 2
(Poincaré–Hopf), quantized in quarters: **at least 8 quarter-index vertices where
90° of twist concentrates, somewhere on the planet**. This is the last, irreducible
ghost of the corner problem, and it is a *point* phenomenon, not a region:

- **Naive assignment** (each facet's grid from its cube-face frame — zero precompute,
  D4-tidy): measured twist ~0.3° across in-face seams (max 3.9°), but the 12 old cube
  edges become twist *ramps* — 4° at mid-edge growing to ~43° near corners. Visible
  brick-rotation bands along every old edge. Not acceptable as the final look.
- **Optimized assignment** (standard trivial-connections least squares over the seam
  graph, one-shot in the atlas bake): twist ≈ 0 on essentially every seam, with 8
  chosen singular vertices whose 3–4 incident seams share the mandatory 90° —
  **22–30° on those few seams, ~11° one facet-ring out, < 1.5° ten facets out**
  (ring decay ≈ 90°/8r). The singularities are placeable — at the 8 old corners for
  symmetry, or under oceans; either way each is a natural "navel" landmark (the
  cosmetic-monument idea from the triangular study, §6 there, applies verbatim, now
  at zero metric cost).

So: the smooth warp's "8 corners squeeze every nearby cell and turn the world 90°"
becomes "8 points where brick orientation visibly mismatches across a couple of
seams." That is the honest full extent of what Gauss–Bonnet still costs.

## 6. Seam design — the junction layer the user asked for (Q6)

Anatomy of one seam (facets A, B; all data from the atlas):

1. **The welded ring** (§3.1): one shared polyline per seam; both facet meshes end on
   it exactly. Watertight by construction — the weld gate is a plain CPU assert.
2. **The strip**: the last ~2 cells of each facet's lattice flanking the ring are
   **non-buildable, generated seam terrain** ("ridge rock" + bank shapes from the
   existing slope family). The strip bridges: the dihedral kink (5.2°), the datum
   step (p50 2.6, ≤ 12 blocks near old corners — a designed bank/cliff there), grid
   phase/twist, and terrain-height reconciliation. Strip budget: **1.4% of the
   planet's surface at k = 16** (0.7% at k = 8, 2.1% at k = 24).
3. **Ownership rule**: each facet's lattice is authoritative up to the seam's ridge
   *plane* (stored per seam). Placement, DDA, collapse flood-fill, and the ground
   collider clamp there — one plane test against atlas data, replacing `fold_cell`'s
   whole remap algebra at boundaries. No block ever spans a seam; no two lattices
   ever claim the same space.
4. **Terrain continuity**: both facets' generators sample worldgen by **true sphere
   direction d̂** (the shipped sphere-domain worldgen, unchanged) — a mountain
   approaching a seam is the *same* mountain on both sides to within the boundary
   column pairing (< 1 block phase); the strip's fill interpolates the residue.
   Boundary columns of A and B at the ring differ in datum by the step — the strip's
   generated columns ramp between them.
5. **Water**: gravity is facet-normal (§7), so per-facet flat seas are
   self-consistent; at ocean seams the two sea planes meet at the ridge with the
   dihedral kink and up to a few blocks of datum mismatch — reconciled as banks/falls
   inside the strip. A disclosed toy-physics artifact (same class as R2's speed-truth
   disclosure), not a bug.
6. **Rendering**: two facet meshes + one strip mesh; AO/occlusion don't cross the
   seam (mild shading discontinuity along strips — accepted; the strip material
   masks it).

## 7. Gravity, crossing, and what replaces the frame machinery (Q4)

### 7.1 Per-facet gravity and the crossing

Gravity is **piecewise constant**: −facet-normal, everywhere on a facet (deviation
from true radial ≤ 4.0° at facet corners, k = 16 — imperceptible). Crossing a seam:

- Player reaches the ridge plane → handoff: position/velocity/orientation multiplied
  by the seam's rigid transform (a 5.2° rotation about the ridge axis + the frame
  change), camera slerped over ~0.3 s. Walking over a ridge feels like cresting a
  gentle fold — there is no 90° world-turn left anywhere in the design.
- Physics stays the flat analytic model in the *new* facet's frame; the GroundCollider
  re-centres; debris (`VoxelBody`) crossing a seam gets the same one-shot re-frame.
- Aim/DDA across a seam: transform the ray at the ridge plane, continue in the
  neighbour lattice — exact, no Jacobian, no bubble, no J⁻¹ (within a facet,
  render frame ≡ physics frame *rigidly*, so the entire R2 input-map apparatus is
  unnecessary).

### 7.2 The replacement map (the machinery ledger)

| Shipped (smooth warp) | Faceted replacement |
|---|---|
| Sliding window chart + floating origin + reanchor | **Static facet frame** (facet ≤ 1250 blocks — f32-safe; no reanchor at facet scale) |
| `M_win` orientation pin + home-face flips + flip hysteresis + eager corner flips | **Facet-crossing handoff** (one rigid transform per seam, from the atlas) |
| `fold_cell` / `edge_remap` D4 algebra at runtime | **Ridge-plane clamp + neighbour transform** (data, not algebra; `edge_remap` survives only inside the one-shot atlas builder) |
| 43-bit fold-based global edit keys | **(facet_id, local cell)** keys (11 + 29 bits) |
| CosmosBend / CosmosTruePlace + C++ `set_cosmos_bake` mesher hook + epoch frames | **Nothing** — stock flat meshing + per-facet node `Transform3D` |
| Interaction bubble → J⁻¹ input map | **Nothing** — rigid ⇒ exact |
| Corner wedge (double-cover) + `_WEDGE` sentinel | **Does not exist** — facets are finite, nothing double-covers |
| M5c: pillar, anomaly teleport, energy barrier, corner edit lock, corner-zone constants | **Deleted** — corners are 0.47° vertices; optional cosmetic navel monument at the 8 twist singularities |

Every row deletes runtime machinery in favour of static data. The one genuinely new
*dynamic* mechanism is the handoff — which is M4's restream pattern (already shipped
for face flips) triggered ~16× more often but ~17× milder (5.2° vs 90°, no D4
content re-orientation, neighbour meshes already on screen).

## 8. Code-reuse map (Q5 — the crux)

**REUSED, essentially untouched (the flat engine becomes the whole game again):**
worldgen (`TerrainConfig` incl. the sphere-domain `generated_cell_global` sampling by
d̂ — now fed by facet-frame → d̂), both meshers (module **stock**, GDScript fallback),
analytic physics (`block_id_at` / `blocked` / `floor_under`), GroundCollider, collapse
flood-fill, VoxelBody, the sim layer (BlockCatalog / PerVoxelEnvironment /
MaterialRegistry), inventory/HUD, portals, snow/liquids, slope shapes (`ShapeCodec` /
`shape_mesh` — the seam banks), StructuralSolver, the frozen-epoch purity discipline
(a facet generator is a pure function of (facet_id, x, z) — *less* shared state than
today), M4 handoff, the far builders (`far_terrain`/`far_mesh_builder` — simplified:
rigid placement replaces the spherical bake), zone/region persistence (per-facet).

**REUSED, repurposed:** `CubeSphere` (`face_cell_to_dir`, the equal-angle warp, DVec3
f64 discipline, `edge_remap`) — demoted from per-cell hot path to the **one-shot
FacetAtlas builder**; R2's "static true-space geometry + moving camera" architecture —
kept as the render model, minus the bake.

**DELETED:** everything in §7.2's left column, plus their gates (T-series, C-gates,
wedge/corner enumerations) — replaced by smaller facet gates.

**NEW (the honest bill):**
1. **FacetAtlas** (~a `cube_sphere.gd`-sized pure kernel + bake): facet frames,
   planarized planes, welded rings, ridge planes, adjacency transforms, twist field
   (trivial-connections least squares), spawn table. Gates: Σ defects = 720.00°,
   weld closure, transform round-trips, twist indices sum 2.
2. **Facet world container**: generator/physics masked to the facet polygon + strip;
   per-facet region files; facet-local `WorldManager` wiring.
3. **Seam-strip generator**: bridge mesh on the welded ring, bank shapes, ridge
   material, terrain/sea reconciliation, no-build + clamp rules.
4. **Crossing handoff**: ridge detection, rigid re-frame (player/camera/debris),
   neighbour prefetch, M4-driven near restream.
5. **Neighbour render ring**: adjacent facets as static mid-LOD meshes (far-builder
   product) + the planet-scale far ring.

Ratio judged over the shipped tree: the deleted smooth-warp/frame/corner stack is the
largest and historically most bug-productive subsystem in `src/cosmos` + the curved
paths of `world_manager`/`module_world`; the new code is smaller, static-data-driven,
and testable headlessly piece by piece.

## 9. Streaming, memory, and the web budget

- **Cadence**: at k = 16 a straight-line walk crosses a seam every ~625 blocks (~2–3
  min). Each crossing = M4-style restream of the near field into the new facet, with
  the neighbour already visible as its mid-LOD static mesh (prefetched when the
  player is within ~64 blocks of a ridge). This is the **#1 risk** (§10): the flip
  restream class returns at 16× the frequency — mitigated by it being 17× milder,
  and by facet meshes being plain flat chunks (no bake in the pipeline).
- **Memory (never-OOM):** atlas < 1 MB at k = 16 (1,536 facets × frames/planes/rings).
  Near volume unchanged (one facet's chunks ≈ today's window budget). Neighbour ring
  ≈ today's far budget. Zero new per-voxel data. Ceilings: neighbour-ring mesh count
  capped; strip meshes stream with their facets.
- **Draw calls**: from the ground, 1–4 facets + strips + far ring (horizon at eye
  height ≈ 160 blocks, from a 64-block peak ≈ 900 — within 1–2 facets); from
  altitude, the far ring merges facets per old-face groups exactly as it merges LOD
  tiles today.
- **Workers/web**: the facet generator is purer than the current frozen-epoch one (no
  window state at all); nothing chart-shaped crosses the GPU boundary; threading
  model unchanged.

## 10. Risks, ranked

1. **Handoff cadence × restream cost** — the old freeze class, 16× more frequent.
   Mitigations: M4 pattern (shipped), milder content delta, prefetch, facet-size
   tuning (k = 12 if needed). Gate: crossing a seam at walk/sprint on the live web
   build with no visible hitch.
2. **The aesthetic is a taste decision** — visible fold-lines every 625 blocks and a
   ridge-strip network (1.4% of the world unbuildable) are *the product*, not a bug.
   FP0's mockup exists to get the user's yes/no for days, not milestones.
3. **Seam-strip quality near the 8 old corners** — 11-block banks + rhombic
   staircase boundaries + the twist singularities all coincide there. Bounded scope
   (8 clusters), designable (navel monuments), but the fit-and-finish milestone lives
   or dies here.
4. **Terrain-feature continuity across seams** — d̂-sampling guarantees agreement to
   < 1 block phase, but tall features straddling a ridge will read "creased";
   worldgen may want ridge-aware feature damping (a data tweak, not architecture).
5. **Planet regeneration** — all COSMOS-era content/edit keys die (any topology
   change pays this; do it before persistent content matters).
6. **Enumerable two-frame leaks** — debris/portals/particles crossing seams need the
   one-shot re-frame; same bounded-inventory discipline R2 already established.

## 11. Staged plan

| Stage | Contents | Size | Gate |
|---|---|---|---|
| **FP0** | Visual spike: FacetAtlas math (frames/rings/dihedrals only) + a 3-facet ridge and an old-corner cluster assembled from far-builder meshes; fly-through + screenshots | days | **user taste verdict** on the faceted look; Σ defects = 720.00° |
| **FP1** | One playable facet: facet-frame → d̂ terrain adapter, stock meshing, gravity = facet normal, spawn at facet centre (≥ 300 blocks from any seam), FACETED toggle alongside FLAT_WORLD | ~1 milestone | flat-engine verify suite green on a facet; byte-identity with FLAT_WORLD off-toggle |
| **FP2** | Neighbour ring + far ring (rigid placement), welded rings rendered, strips as visual barrier terrain | ~1 milestone | weld closure ≤ 0.0 by construction; FPS parity on web |
| **FP3** | Crossing: handoff (player/camera/debris), (facet_id, cell) edit keys, DDA/clamp at ridge planes, M4 restream reuse | ~1 milestone | cross-and-return byte-identity; no-hitch live crossing |
| **FP4** | Seam gameplay: walkable banks (slope shapes), no-build + collapse/collider clamps, terrain/sea reconciliation in strips | ~1 milestone | seam walk/build/break invariants in verify |
| **FP5** | The 8 singular vertices: twist-field bake, corner-cluster fit-and-finish (monuments), gate re-derivation sweep, live web A/B vs shipped R2+M5c | ~1 milestone | user pass on live deploy |

**≈ 5 milestones + a days-scale spike**, comparable to the truncated-cube estimate
(4–6) — but unlike that option it *deletes* the warp/frame/corner stack rather than
tripling it, and every stage ships behind a toggle with the flat world byte-identical.

## 12. Verdict

**(a) Feasible?** Yes — with a construction that is *more* web-robust than the
shipped one (stock flat meshes + rigid transforms; nothing driver-sensitive), f32-safe
at planet scale, worker-pure, and headlessly testable at every stage.

**(b) Better?** For the user's actual complaint — per-cell distortion — categorically:
cells are exact unit cubes everywhere, the 8 × 90° corners dissolve to 0.47° vertices,
M5c and the wedge cease to exist. The quantified new costs: 5.2° fold-lines every
~625 blocks, 1.4% of the surface as non-buildable seam strip, ≤ 12-block seam banks
near the old corners, 8 point twist-singularities (22–30° brick mismatch on a few
seams), and a 64-gon silhouette (0.12% — reads round). Whether that trade is "better"
is exactly the FP0 taste question; the arithmetic says the artifacts are localized,
bounded, and designable, where the warp's were ambient.

**(c) Simpler?** Net, yes — this is the first proposal in the series where the
deletion column outweighs the addition column: the sliding-window/fold/flip/corner
apparatus (the source of bug cycles #68–#77) is replaced by static precomputed data
plus one conventional handoff mechanism, and the R2 bake collapses from per-vertex
spherical math in C++ to per-facet node transforms. It is still a ~5-milestone
restart with planet regeneration — the sunk-cost argument from the triangular study
cuts against it *if* the shipped R2+M5c corner is judged acceptable in the live A/B.
The user has judged it is not. Given that, this is the right architecture to pivot
to, and the cheap, reversible first step is FP0.

**Recommended parameters:** earth = k 16 (1,536 facets, ~625-block facets, 5.2°
ridges); twist singularities parked at the 8 old corners as designed landmarks;
strip = 2 cells per side on the welded ring; spawn = facet centres. Small bodies:
hold facet size (~600 blocks), let k fall (mars ≈ 8, moon ≈ 4–5) and the look go
proudly chunky.
