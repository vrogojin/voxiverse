# COSMOS-PLANET-TOPOLOGY — R1: the blocky-voxel-on-a-sphere grid topology

Status: **LOCKED DESIGN (the L3 deep pass named in COSMOS-ARCHITECTURE §7.1).** This document
refines — and deliberately does not reshape — the layer interfaces locked in
`docs/COSMOS-ARCHITECTURE.md` (L1 frames/floating origin, L3 "global cube-sphere prism lattice
+ local chart the existing engine runs inside via y ↦ r", L5 LOD bands, and the R1/R2 risk
gates). It is the authoritative topology spec Phase 1 ("One spherical planet") implements.
Every deviation from a COSMOS *number* (not interface) is flagged loudly in §10.

Read together with: `docs/COSMOS-ARCHITECTURE.md` (§2 ground truth, §4.3 L3, §6 Phase 1, §7
follow-ups), `docs/LOD-DESIGN.md` + `godot/src/world/far/` (branch `feat/voxiverse-lod` — the
far-field seed this extends), `docs/DESIGN.md`, `docs/SIM-MODEL.md`.

Code citations are against the current working tree (descendant of `main` @ b168eea; far-field
citations against branch `feat/voxiverse-lod` @ 0983f34, marked "(branch)").

---

## 0. Executive summary

**Variant chosen: the equal-angle (tangent-warped) gnomonic cubed sphere** — the standard
"cubed-sphere" grid of atmospheric modelling and planet rendering, with per-axis warp
`u = tan(a·π/4)`. It is the only candidate that is simultaneously (a) closed-form and cheap in
both directions (one `tan`/`atan` per axis — f64-exact in WASM), (b) **separable per axis**,
which *proves* the 12 face edges stitch cell-for-cell 1:1 with no T-junctions (§4.1), and
(c) bounded to a worst-case linear cell-size ratio of exactly **√2 ≈ 1.414** (vs 3× for the raw
gnomonic cube) with zero anisotropy at face centres (§2).

**The load-bearing architectural result of this pass** (it dissolves most of R1 and re-scopes
R2): the play space *is the face lattice*. Because the lattice's third axis is radial by
construction, running today's entire engine in integer face-lattice coordinates `(i, r, j)` as
`(x, y, z)` makes gravity **exactly** `−Y` in every column with **zero** code change to the
player, `floor_under`, the DDA, the collider, or the collapse pass. The "local gnomonic chart"
of COSMOS §4.3.3 becomes a *render-only* embedding: a **camera-centred exact-sphere wrap in a
shared vertex shader** (§3.4) curves the world visually (the sea horizon appears at its true
147 blocks — COSMOS §1.2), while physics stays flat-lattice. A chart "re-anchor" is thereby
reduced to an **exact integer floating-origin translation: zero pop, zero restream** while the
player stays on one cube face. The entire R2 restream cost concentrates at the 12 face-edge
crossings, which get a dual-window prestream handoff (§4.5).

- **Seam strategy (§4):** an *extended window* — the neighbour face's boundary strip unfolded
  into the home face's index space by an exact 90°-rotation remap. One rectilinear lattice
  locally ⇒ meshing, collision, water, floods and the DDA cross the seam with no special cases
  and no cracks. Home-face flips are hysteretic; the module path pre-streams a second
  `VoxelTerrain` and swaps it in pixel-identically.
- **Corner strategy (§5):** the 8 cube corners are combinatorial valence-3 defects (three cells
  around a vertical edge; the sphere metric itself is smooth). They are hidden: the cube is
  oriented with **face centres at the poles** (so pole play is ordinary lattice) putting all 8
  corners at latitude ±35.26°, where worldgen deterministically forces **deep ocean** within
  48 cells and edits are refused within 8 cells. The window's fill rule and proofs (§5.4) show
  no algorithm loops, duplicates an edit, or loses a cell.
- **Re-anchor cost (§7):** intra-face **0 chunks re-meshed** (down from COSMOS's provisional
  "≈ a 256 m teleport every ~50 s"); a face crossing re-streams ≈ 1,600 mesh blocks (one
  initial-load's worth) amortized over a ≥ 13–28 s hysteresis band, with the analytic far field
  as graceful cover if the worker falls behind.
- **Biggest remaining risk:** the module-path face-crossing handoff on the single web voxel
  worker (two `VoxelTerrain` nodes transiently sharing one thread and one WASM heap) — R2's
  residue, gated by build-order milestone M4 (§9).

---

## 1. The lattice: definitions and notation (normative)

### 1.1 Bodies, faces, indices

Each walkable body owns one lattice. Cube faces are numbered by outward normal in the
**body-fixed frame** (COSMOS §4.1's `EF` frame): `0:+X, 1:−X, 2:+Y, 3:−Y, 4:+Z, 5:−Z`, with
**+Z = the spin axis** (north). So faces 4/5 are the polar faces (face centres at the poles —
the §5.5 orientation decision) and faces 0–3 tile the equatorial belt.

Per-face local axes follow the fixed right-handed table (the OpenGL-cubemap style convention;
the exact table is data in the math kernel, §9 M0):

| face | normal n̂ | û (i axis) | v̂ (j axis) |
|---|---|---|---|
| 0 | +X | +Y | +Z |
| 1 | −X | −Y | +Z |
| 2 | +Y | −X | +Z |
| 3 | −Y | +X | +Z |
| 4 | +Z | +Y | −X |
| 5 | −Z | +Y | +X |

A **global cell** is `(body, face, i, j, r)` with `i, j ∈ [0, N)` integers and `r` the radial
layer (1 m thick): `r = 0` is the datum (sea-level radius `R`), crust `r ∈ [−64, +116]` exactly
as `y` today (`terrain_config.gd:42-46,140`), atmosphere shell `r ∈ (surface, surface+512]`
(COSMOS V6). **Every lattice cell belongs to exactly one face** — face boundaries are cell
*faces*, not cells, so ownership is total and unambiguous (this matters for worldgen
determinism, §8.2).

`N` (cells per face edge) is per body: `N = 32 · round((π/2)·R / 32)` — a multiple of 32 so the
`ZoneChunk` 32³ region grid (`world_manager.gd:624`, `ZoneChunk.SIZE`) tiles each face exactly
and **no persistence region ever straddles a face**. (`r = −64` is 32-aligned too.)

| Body | R (blocks) | N | face-centre cell width | mean scale error |
|---|---|---|---|---|
| Earth | 6,371 | **10,016** (= 313·32) | 0.99915 m | 0.085 % |
| Mars | 3,390 | 5,312 | 1.00237 m | 0.24 % |
| Mercury | 2,440 | 3,840 | 0.99811 m | 0.19 % |
| Moon | 1,737 | 2,720 | 1.00313 m | 0.31 % |

Equator length: `4N = 40,064` cells vs true `2πR = 40,030` m — the "block = 1 m" bookkeeping
lie is ≤ 0.09 % on Earth (locked toy approximation, same class as prisms-as-cubes,
COSMOS §4.3.1).

### 1.2 The two normative functions (single source of truth)

All of L3/L5 — the voxel generator, the analytic queries, the far field, the B2 planet mesh,
and L1's chart bookkeeping — reads the sphere through exactly two pure functions in the math
kernel (`src/cosmos/cube_sphere.gd`, new; the only new "math engine" beyond COSMOS §4.1's
`frames.gd`):

```
# face/cell -> unit direction in the body-fixed frame (f64 scalar math)
func face_cell_to_dir(face: int, fi: float, fj: float) -> DVec3:
    a := 2.0*(fi + 0.5)/N - 1.0          # [-1, 1] across the face
    b := 2.0*(fj + 0.5)/N - 1.0
    u := tan(a * PI/4.0)                 # THE warp (equal-angle, §2)
    v := tan(b * PI/4.0)
    return normalize(n̂ + u*û + v*v̂)     # per-face axes from the §1.1 table

# unit direction -> (face, fi, fj); face = argmax |component|; exact inverse via atan
func dir_to_face_cell(d: DVec3) -> {face, fi, fj}
```

`tan`/`atan` are exact inverses in f64 to < 1 ULP; round-trip `cell → dir → cell` is exact for
every integer cell (verify-pinned, §9 M0). A world-space point is
`P = (R + r) · face_cell_to_dir(face, i, j)` — the prism lattice of COSMOS §4.3.1.

The warp is deliberately isolated behind `warp(a)`/`unwarp(u)` so a later distortion-tuning
pass can swap constants (e.g. a rational warp) without touching topology, remap tables, or
persistence — the *indices* are the identity, the warp only moves ground truth (§2.4).

### 1.3 The global edit key

`_edits` today is `Vector3i → packed value` (`world_manager.gd:47`). Per body it becomes one
sparse dictionary keyed by a 43-bit packed int64 (GDScript ints are 64-bit):

```
key = face << 40 | i << 26 | j << 12 | (r + 2048)      # 3 + 14 + 14 + 12 bits
```

(14 bits holds N ≤ 16,384 — Earth's 10,016 fits; 12 bits holds r ∈ [−2048, +2047].) The same
key prefix `(body, face, region_i, region_j, region_r)` extends `region_origin_of`
(`world_manager.gd:624`) and the `ZoneChunk`/`ZoneBundle` stores (`world_manager.gd:641,702`)
exactly as COSMOS L0 (§4.6) prescribes — a zone on the Moon is just a zone.

---

## 2. Problem 1 — cube-sphere variant choice

### 2.1 The measuring stick

For a *voxel* world the figure of merit differs from geodesy's. Blocks are rendered as perfect
unit cubes in the window regardless of variant (COSMOS §4.3.3, locked), so what the variant
controls is: **(a)** how much the *ground truth* under a "1 m" block varies (walk speed, area,
geodesic honesty), **(b)** cell *squareness* (anisotropy/shear is the perceptible lie —
a uniform scale error is locally invisible), **(c)** the cost and exactness of the
index ↔ direction math that runs per streamed column on the single web worker, and **(d)**
whether a regular integer grid lays on each face with exact edge alignment.

One fact first, because it disciplines the whole comparison: **the 120° corner is a
topological invariant, not a variant property.** Each cube-sphere face is a spherical square
of area 4πR²/6; its spherical excess forces corner angles of exactly
`(2π + 2π/3)/4 = 120°`. Three faces × 120° = 360°: the sphere is smooth at the corner, but
*every* variant's corner cell is a 120°/60° rhombus that the index grid calls a square —
~30° of shear. Variants can only redistribute *scale*; the corner shear is fixed and must be
handled topologically (§5), not projectionally.

### 2.2 Exact distortion of the candidates

Let θ be the angular distance from the face centre. The raw gnomonic map (face plane tangent
at the face centre, plane radius ρ = tan θ) has principal linear scale factors, normalized to
1 at the face centre:

- radial (toward the corner): `cos²θ`
- transverse: `cos θ`

| Variant | face centre | edge midpoint (θ=45°) | corner (θ=54.74°) | worst linear max/min | worst area max/min | axes at corner | inverse math |
|---|---|---|---|---|---|---|---|
| **Raw gnomonic** | 1.00 / 1.00 | 0.500 / 0.707 | 0.333 / 0.577 | **3.00×** | **5.20×** (cos³θ) | 120° | none (linear) — cheapest |
| **Equal-angle (tan-warp)** | 1.00 / 1.00 | 1.000 / 0.707 | 0.943 / 0.943 | **√2 = 1.414×** | **1.414×** | 120° | `atan` per axis — closed form |
| **QLSC / COBE** | ≈1 / ≈1 | equal-area by design | equal-area | shape pushed to ~1.4× anisotropy | **≈ 1.01×** | 120° | non-separable polynomial series fit; published inverse is approximate (closure error), no closed form |
| **Analytic equal-area (Snyder-class)** | 1 / 1 | exact area | exact area | worst angular distortion of the four | **1.00×** | 120° | trig-heavy; Newton iteration for the inverse |

Equal-angle numbers, derived (unit sphere, `u = tan(aπ/4)`; per-axis scale
`|∂P/∂a| = (π/4)sec²(aπ/4)·|∂P/∂u|`):

- face centre `(0,0)`: both axes `π/4` (≡ 1.0 normalized), orthogonal;
- edge midpoint `(±1, 0)`: along-edge `π/4` (1.0), transverse `π/(4√2)` (0.7071), orthogonal;
- corner `(1,1)`: both axes `0.9428`, meeting at 120° (e_u = (2,−1,−1)/√6, e_v = (−1,2,−1)/√6,
  cos = −½).

So the equal-angle grid's ground-truth cell widths lie in **[0.707, 1.0] m** (max/min = √2),
its cell areas in **[0.707, 1.0] m²**, and it is *perfectly isotropic where players spend
their time* (face centres) and *nearly isotropic at the corners* (0.943, though sheared 30° —
the invariant). The minimum is at edge midpoints, transverse to the edge — exactly the strip
the seam machinery (§4) already owns.

> **Numeric correction to COSMOS §4.3.1** (flagged; no interface change): the sentence "the
> warp keeps surface cell width within ~±7 % of 1 m across a face" is optimistic. The exact
> bound is [0.707, 1.0] — −29 % at edge-midpoint transverse. The ±7 % figure is true only of
> the corner cells (0.943) and of the along-edge direction. Nothing downstream in COSMOS
> depended on the ±7 % number; the locked bookkeeping rule ("every cell is 1 m³") absorbs
> either value identically.

### 2.3 Why not the equal-area families

Equal-area (COBE/QLSC or Snyder-class) buys area uniformity we don't need — block *volume*
bookkeeping is already a locked toy constant ("1 m³ per cell", COSMOS §4.3.1) — and pays for
it three times: (i) shape: equal-area shifts all distortion into shear, which *is* the
perceptible artifact for square blocks; (ii) math: no closed forms — the COBE fit is a
non-separable polynomial series whose standard inverse does not close exactly (documented
closure error in the FITS "CSC" convention), and Snyder-class needs Newton iteration per
query, on the hot generator path of a single web worker; (iii) exactness: the edit key and
determinism story (§8.2) want a bit-exact, iteration-free `cell ↔ dir` round trip. Raw
gnomonic is disqualified outright: a 3× linear / 5.2× area lie means a player walking a
constant 4.5 blocks/s covers 3× less ground at a corner than mid-face and block "masses"
misrepresent volume by 5× — far past toy tolerance.

**Locked: equal-angle.** One residual honesty note: near an edge the transverse ground-truth
scale *gradient* is ~1.1×10⁻⁴ per cell (`d(cos φ)/dφ ≈ 0.707` at φ=45°, Δφ ≈ 1/R per cell), so
across the visible 256-block disc the true cell width varies by up to ~3 % near edges (vs
0.16 % mid-face). Rendered geometry is uniform cubes, so this is locally invisible; it shows
only in global measurements (documented, same class as the equator length error §1.1).

---

## 3. Problem 2 — local chart ↔ global lattice

### 3.1 The window (the chart, made precise)

The **window** is the runtime instantiation of the lattice around the player — COSMOS §4.3.3's
chart, sharpened:

- **Window space = home-face index space.** Scene/gameplay coordinates are
  `(x, y, z) = (i − i_org, r, j − j_org)` where `(i_org, 0, j_org)` is the current
  floating-origin cell (an *integer* offset, L1-owned). No rotation, no projection: window
  space is a pure integer translation of the home face's `(i, r, j)`.
- **Extent:** everything the engine streams or queries lives within `W = 512` cells of the
  player (2× `RENDER_RADIUS_BLOCKS = 256`, `terrain_config.gd:114`): the voxel view distance
  (`module_world.gd:201`), the ±128 vertical viewer slab (`terrain_config.gd:117-128`), the
  DDA (reach 8, `player.gd:24`), the collider (`ground_collider.gd:45,134`), the collapse
  solver (RADIUS 5, cap 4096 cells, `structural_solver.gd:22-24`), the snowfall sim, and the
  B1 far field's *sampling* (which reads `height_on` through the window projection, §7.1).
  When the window overlaps a face edge, it is *extended* across it by the §4 unfold.
- **The bijection** `chart_cell ↔ global_cell` demanded by COSMOS §4.1/§4.3.3 is
  `to_global(c) = fold(face_home, c + (i_org, 0, j_org))` where `fold` is the identity inside
  the home face and the precomputed edge remap (§4.2) in the extension strips. It is applied
  at exactly the choke points COSMOS named: the composed read `cell_value_at`
  (`world_manager.gd:159`) and the single write `_write_cell` (`world_manager.gd:423`) — plus
  the generator callback (`module_world.gd:186` and `terrain_config.gd:469` via the adapter
  below). *Nothing else in the engine learns the planet exists.*

`WorldManager.block_id_at(cell)` (`world_manager.gd:169`) keeps its exact signature and
semantics — `cell` is a window-space `Vector3i`; the fold happens inside `cell_value_at`:

```
func cell_value_at(cell: Vector3i) -> int:
    var g := _chart.to_global_key(cell)          # int64 key, §1.3; O(1), fold only in strips
    var e: int = _edits.get(g, -1)
    if e >= 0: return e
    return TerrainConfig.generated_cell_global(_chart.to_global(cell))   # §3.5
```

Floor (`world_manager.gd:871`), walls (`:910`), ceiling (`:952`), the DDA (`:981`), the
collapse grouping (`:775,791`), `GroundCollider` (`ground_collider.gd:134,161,214`), the
snowfall sim, TreeGen and both meshers all consume `cell_value_at`/`block_id_at` on
window-space cells and are **byte-identical** — the CLAUDE.md rule-1 promise ("one cell
query") is precisely what makes this a two-choke-point change.

### 3.2 Re-anchoring: an integer origin shift, nothing else

Because window space is a *translation* of face-index space (not a re-projection), the L1
"chart re-anchor every 256 m" (COSMOS §4.1) degenerates to a floating-origin step:

- **Trigger:** horizontal window distance from the origin cell > 256 (hysteretic — the new
  origin is the cell under the player, so it cannot re-trigger within another 256 cells).
- **Action:** `(i_org, j_org) += Δ` (integers); translate the scene children by `−Δ` (an exact
  f32 operation for |Δ| ≤ 512-scale integers); the `VoxelTerrain`/fallback-streamer *nodes*
  move with the shift, their internal (face-index) content untouched. The player's position is
  subtracted exactly. **No cell changes its window identity relative to the player, no mesh is
  rebuilt, no edit is touched (keys are global), no content re-streams.** Pop: exactly 0.
- **Basis re-tilt:** none in the scene. The window frame's orientation to the body-fixed
  frame (the `basis` in `Frames.active_chart() → ChartInfo{body, anchor_dir, basis}`,
  COSMOS §4.1) is recomputed in f64 by L1 — it feeds the sun direction, the far/B2/B3
  placement and `gravity` *magnitude* bookkeeping, all continuous per-frame consumers. The
  discrete scene event carries no rotation because the *render* curvature lives in the §3.4
  bend, which is camera-centred and continuous.

Even without shifts, face-index coordinates are bounded by N ≈ 10,016, i.e. scene magnitudes
≤ ~10 km where f32 ULP ≤ 1 mm — inside COSMOS §4.1's "≤ 32 km scene" invariant with 3× margin.
The 256 m shift cadence is kept anyway (belt-and-braces, and it keeps the L1 contract uniform
between surface and space modes).

> **Refinement flag (satisfies, does not amend, the locked bound):** COSMOS §4.3.4 budgeted a
> re-anchor pop "≤ ~0.4 blocks at the fog edge" and §0/R2 a restream "≈ a 256 m teleport …
> every ~50 s at sprint". This pass delivers pop = 0 and restream = 0 for intra-face travel;
> §7.2's engineering question ("can module VoxelTerrain be re-origined without a full drop?")
> is answered *yes — by never rotating the lattice*. R2 re-scopes entirely to face crossings
> (§4.5, §8.1). `ChartInfo` and `Planet.chart()` keep their locked shapes.

### 3.3 Why lattice-space physics is exact (the y ↦ r theorem)

In face-index space the third axis *is* the radial direction of each column — that is the
definition of the prism lattice. Therefore:

- "down the column" (decreasing r) points at the planet centre **for every column, exactly**;
  a uniform `−Y` gravity in window space is *exact radial gravity*, not an approximation. The
  ≤ 2.3° "gravity-vs-grid tilt" of COSMOS §4.3.3 was the cost of physics in a *tangent-plane*
  chart; in lattice space it is zero by construction.
- walking at constant r follows the curved surface automatically; jumps are parabolae over the
  local surface; `velocity.y -= gravity * delta` (`player.gd:234`) is the correct radial
  integrator.
- the Godot physics server keeps its global `−Y` gravity for `VoxelBody` debris — correct
  per-column for the same reason. (The horizontal metric shrink with depth — the prism taper,
  ≤ 2 % at r = −100 — is the already-locked toy approximation, COSMOS §4.3.1.)

What lattice-space physics gets *wrong* is only the ground-truth horizontal metric (§2.2's
[0.707, 1.0] scale and the ~3 % gradient near edges) — invisible locally because the render is
the same lattice.

### 3.4 The render embedding: a camera-centred exact-sphere wrap (vertex shader)

COSMOS holds two claims in tension: §4.3.4 "the near field need not curve" versus §1.2's
*locked feature* "sea-level horizon ≈ 147 blocks — *inside* today's 256-block render radius;
watch ships hull-down from a beach". At eye height 1.7 m the horizon *must* appear at 147 m,
and the curvature drop at the 256 m fog edge is 5.1 m (`d²/2R`) — a flat near field cannot
show either. **This pass resolves the tension in favour of §1.2** (render-only; no layer
interface is touched):

- Physics, streaming, edits: flat lattice (§3.3). Rendering: a **shared vertex-shader
  include** bends every near-field vertex onto the exact sphere around the camera:

```
// uniform: bend_origin (camera position, window space), R (datum radius)
vec2  d   = v.xz - bend_origin.xz;          // lattice horizontal offset
float len = length(d);
float phi = len / R;                        // arc angle
float rv  = R + v.y;                        // vertex radius (prism taper for free)
v.y  = rv * cos(phi) - R;                   // exact sagitta (not the d²/2R truncation)
v.xz = bend_origin.xz + d * (rv * sin(phi) / max(len, 1e-6));
```

  Cost: one `sincos` + one `normalize` per vertex, WebGL2/GL-Compatibility trivial (the same
  "curved-world" vertex transform many shipped games use, here with physical constants). At
  the camera the bend is identically zero, so the player, the aim ray (reach 8 m → bend
  5 mm), and the `GroundCollider` boxes (≤ ~10 m) are unaffected; the `aimed_voxel` DDA
  (`world_manager.gd:981`) stays flat-space exact.
- **Who gets the shader:** the near voxel terrain materials (module path: the per-model
  materials in `module_world._configure_library` become ShaderMaterial equivalents of their
  StandardMaterial3D — a one-time conversion warmed by the existing ShaderPrewarm), the
  fallback mesher material, the water mesh, and (branch) the B1 far tiles (§7.1). Loose
  `VoxelBody` nodes and NPC visuals get the same formula CPU-side on their *visual* transform
  when > ~64 m from the camera (drop > 0.3 m); nearer ones skip it (< 0.3 m ≪ perception).
  Normals are left unbent (≤ 2.3° error at the fog edge — below diffuse-lighting perception;
  revisit in the L5 sky-quality pass if specular water ever cares).
- Because the bend centre is the *camera* (continuous), there is **no discrete visual event
  at all** — walking simply rolls the world under you; the horizon self-consistently sits at
  `√(2Rh)`; fog (`main.gd:75-84`) is camera-radial and composes unchanged.

### 3.5 The terrain-function adapter

`TerrainConfig` keeps its role and its internals (COSMOS §4.3.2 — that migration is Phase 1
work, not this pass), with the domain adapter this pass fixes the shape of:

```
static func generated_cell_global(g: GlobalCell) -> int:
    # dir̂ is THE noise domain: quantized f32 components of face_cell_to_dir (§8.2)
    var d := CubeSphere.face_cell_to_dir(g.face, g.i, g.j)
    return resolve_cell_sphere(g, _height_on(d), _biome_on(d), ...)   # same pipeline, y ↦ r
```

- `height_at(x, z)` (`terrain_config.gd:393`) → `height_on(body, dir̂) → r_surface`; every
  `get_noise_2d(x, z)` becomes `get_noise_3d(d * S)` (seam-free 3D noise on the sphere,
  COSMOS §3.2/L5); `column_profile` (`terrain_config.gd:444`) keeps its Vector4 contract with
  the latitude climate term (`asin(d.z)`, feeding `climate_model.gd:34` unchanged);
  `resolve_cell` (`terrain_config.gd:476`) is verbatim with `y ↦ r` (bedrock r = −64, sea
  r = 0, `SEA_LEVEL` at `terrain_config.gd:46`).
- **Flat-compatibility mode** (COSMOS §4.3.2): `FLAT_WORLD = true` makes `to_global` the
  identity and `face_cell_to_dir` return a constant-up tangent-plane fiction — today's world
  is the R → ∞ limit of one window; the byte-identical regression strategy is the
  `SMOOTHING_ENABLED` toggle pattern (`terrain_config.gd:39`).
- Column-keyed worldgen (TreeGen's 10-cell grid, `tree_gen.gd:70,123`; smoothing's 3×3 column
  stencils; the snowfall weather gate) keys on **global column identity** `(face, i, j)` —
  never on window coordinates — and takes neighbourhoods via intrinsic lattice adjacency
  (§4.4), so two windows always generate the same tree, lip, and drift (verify-pinned, §8.2).

### 3.6 L1 reconciliation

The frame chain (COSMOS §4.1 diagram) is unchanged: `EF (body-fixed) → CH (chart/window) →
SC (scene)`. This pass pins CH's definition: origin = the window origin cell's surface point,
basis = `(û', r̂, v̂')` at that cell (f64), plus the integer `(face, i_org, j_org)` that makes
`to_scene`/`to_global` exact. Ascent past the chart ceiling (the streamed slab top,
`terrain_config.gd:117-128`) hands off to L4's body-inertial ACTIVE state exactly as
COSMOS §4.4 locks — the window↔inertial conversion is `P = (R + r)·face_cell_to_dir(...)`
plus the ω×r surface velocity, all f64 in `frames.gd`. Descending, L4 converts back through
`dir_to_face_cell`. Nothing in that locked handoff changes.

---

## 4. Problem 3 — the 12 face-edge seams

### 4.1 The 1:1 edge theorem (why there are no T-junctions)

**Claim.** For any per-axis warp (in particular equal-angle), the cell-boundary subdivision
that two adjacent faces induce on their shared cube edge is *identical*, so boundary cells
correspond 1:1 with full shared quadrilateral faces — the lattice is a true cell complex on
the sphere shell: **no T-junctions, no slivers, no resolution mismatch, ever.**

**Proof.** The shared edge of faces A and B lies in a mirror plane of the cube (e.g. the +Z/+X
edge lies in the plane x = z). The cube-sphere construction — per-axis warp, same N, same
per-face recipe — is equivariant under the cube's symmetry group; the reflection through that
plane maps A's grid to B's grid while fixing the edge pointwise. Hence A's boundary lattice
points on the edge map to B's boundary lattice points: the two subdivisions coincide point
for point. ∎

Consequently every boundary cell of A has exactly one neighbour across the edge in B, sharing
its entire outer face (same two edge points, same r interval). Grid *lines* even continue
across the edge (each is a great-circle arc meeting its continuation with a kink that is 0°
at the edge midpoint and grows toward the corners — a ground-truth kink only; §4.6).

### 4.2 The remap algebra

For each of the 12 edges × 2 crossing directions, the index map A → B is an element of the
dihedral group D4 acting on `(i, j)` plus an offset — i.e. an **exact rigid map of index
space** composed of 90° rotations/reflections and integer translations, with `r` untouched.
Rather than hand-writing 24 error-prone entries, the math kernel **generates** the table at
boot from the §1.1 axis table: for face A's exit side, express two adjacent boundary cells'
edge coordinates in 3D, find B and the D4 element that reproduces them, cache
`{B, M ∈ D4, t ∈ ℤ²}`. `verify_feature.gd` pins the generated table with round-trip and
adjacency property tests (§9 M0). One worked example (edge between face 4 (+Z, polar) and
face 0 (+X), with §1.1 axes): face 4 cells exiting across its `j = 0` side (v̂₄ = −X) land on
face 0's `j = N−1` side (v̂₀ = +Z), with `(i', j') = (i, N−1 − (−1)) …` — generated, then
pinned; the doc deliberately trusts the generator + tests over a hand table.

### 4.3 The extended window (the unfold)

When the window overlaps an edge, the neighbour face's strip is **unfolded** into home-face
index coordinates: window cell `(x, y, z)` with `i = i_org + x ≥ N` (or `< 0`, and likewise
for j) maps through the edge's `{B, M, t}` to a face-B cell. The unfold is a bijection on the
strip (the 1:1 theorem) up to `W = 512` cells deep — far more than any algorithm reaches —
except in corner quadrants (§5.3).

**The decisive property:** the extended window is still *one rectilinear integer lattice*.
Cell adjacency in window space (`cell ± d`, the `_NEIGHBORS_6` arithmetic at
`world_manager.gd:775` and everywhere else) **is** intrinsic lattice adjacency across the
seam, because the fold is applied once at the identity layer (`to_global`), not per step.
Therefore, with zero per-algorithm changes:

- **Meshing:** both meshers see one contiguous lattice; adjacent cells across the seam share
  exact faces → no cracks, no gaps, no fall-through. Face-cull tests
  (`occludes_face`, `world_manager.gd:1095`; the module's blocky mesher culling) compare
  neighbouring window cells as always.
- **Collision/movement:** `floor_under`/`blocked`/`ceiling_scan` scan window columns; a player
  walks over the seam as over any two adjacent columns. A wall built across the seam is a run
  of ordinary adjacent cells; a tunnel dug under it is ordinary adjacent air.
- **Water:** the liquid axis and shore machinery evaluate per-column/neighbour on the same
  lattice; sea level is `r = 0` globally, so the ocean is level across every seam by
  construction.
- **Collapse/floods:** `StructuralSolver.solve` (bounded box RADIUS 5 + 4096-cell caps,
  `structural_solver.gd:22-24`) runs entirely inside the window; a canopy or bridge spanning
  the seam detaches as one component like any other.
- **Lighting/normals:** mesher normals are axis-aligned in window space, continuous across
  the seam; the sun direction is a per-frame L1/L2 quantity, smooth everywhere.
- **Edits:** `_write_cell` folds to the *true* face's global key — an edit made from a window
  homed on A re-materializes identically in a window homed on B (THE Phase-1 R1 invariant,
  COSMOS §6, verify-pinned).

```
            face A (home)              │ extension (face B, unfolded)
   j ↑   ┌───┬───┬───┬───┬───┬───┐▒▒▒▒│▒▒┌───┬───┬───┐
         ├───┼───┼───┼───┼───┼───┤ 1:1│  ├───┼───┼───┤     window space:
         ├───┼───┼───┼───┼───┼───┤ ⇄  │  ├───┼───┼───┤     ONE rectilinear grid;
         ├───┼───┼───┼───┼───┼───┤    │  ├───┼───┼───┤     the fold lives only in
         └───┴───┴───┴───┴───┴───┘▒▒▒▒│▒▒└───┴───┴───┘     to_global()/to_global_key()
              → i                cube edge (cell FACES, not cells)
```

### 4.4 Worldgen across the seam

The generator must be a pure function of the *global* cell (§8.2), so neighbourhood-consuming
worldgen (smoothing's 9-column `height_at` stencil, `terrain_config.gd:780` region; TreeGen
trunk scans, `tree_gen.gd:123`; snow drift checks) takes neighbours via a `LatticeNav.neighbor
(global_cell, dir)` helper that applies the edge fold — with the fast path (`≥ stencil radius
from any edge` → raw index arithmetic) covering > 99.9 % of columns. This is the *one* place
worldgen code changes shape for the sphere beyond the domain adapter (§3.5), and it guarantees
a tree whose trunk stands on face A grows the same canopy cells into face B from every window.

### 4.5 The home-face flip (where R2 now lives)

While the player is within the extension's validity, play continues on A's extended window —
crossing the seam *on foot involves no event at all*. The **home-face flip** (re-basing the
window on B) is deferred and hysteretic:

- **Trigger:** player ≥ 64 cells past the edge into B (hysteresis: flip back only ≥ 64 cells
  back into A — oscillating along the seam never flips).
- **Fallback path:** trivial. The flip is a rigid map of index space (§4.2); the streamer's
  chunk dictionary re-keys and each `MeshInstance3D` gets the corresponding rigid transform
  (its meshes carry world-space vertices, `chunk_streamer.gd:7-8`, so the instance transform
  absorbs the rotation exactly); re-meshing proceeds lazily at the normal budget
  (`chunk_streamer.gd:11`).
- **Module path (the R2 residue):** `VoxelTerrain`'s internal grid cannot be rotated. Locked
  two-stage design:
  1. **Dual-window prestream (target, milestone M4):** at ≥ 32 cells before the edge, spawn a
     second `VoxelTerrain` homed on B (own generator closure homed on B's index space),
     viewer-attached at the player's B-coordinates, streaming at *low* priority on the one
     worker. When `area_meshed` over the near box reports ready (the existing
     `initial_view_meshed` machinery, `world_manager.gd:148`), swap visibility and free the A
     node. Because both nodes render the *same global cells* as unit cubes and the inter-node
     scene transform is the exact rigid remap, the swap is **pixel-identical — zero pop**.
     Transient cost: bounded by shrinking A's `view_distance` as B's grows (union ≤ ~1.3× one
     near field; §8.1).
  2. **Hard restream (Phase-1 fallback, milestone M3):** flip = drop + restream around the
     player (one initial-load's worth, §8.1), with the B1 analytic far field (main-thread,
     always available — `far_terrain.gd:41-42` (branch) budgets) temporarily covering the
     near hole (its inner radius drops from 192 toward ~32 during the gap) and the fog wall
     masking detail. Play far from edges is unaffected; Phase 1 may ship this.

### 4.6 What remains visibly imperfect (documented, accepted)

A "straight" index-space line crossing a seam kinks in *ground truth* (0° at edge midpoints,
growing toward corners); a long wall over a seam is straight in-window and gently kinked from
orbit (B2 shows truth). Transverse ground scale dips to 0.707 at edge midpoints (§2.2). Both
are metric lies of the locked "cells are unit cubes" bookkeeping — invisible in play,
honest in the doc.

---

## 5. Problem 4 — the 8 cube-corner singularities

### 5.1 What the defect actually is

At a cube corner three faces meet. On the sphere the metric is **smooth** (3 × 120° face-corner
angles = 360° — no cone point); the defect is **combinatorial**: the vertical lattice edge
under the corner has *three* cells around it instead of four (a valence-3 vertex), and each of
those three corner cells is a 120°/60° rhombus in ground truth that its index grid calls a
square (the ~30° shear invariant, §2.1).

Crucially, **6-connectivity survives**: each corner cell has its 2 in-face side neighbours
plus the *other two corner cells* across its two boundary faces = 4 side neighbours + up/down
= a full 6-neighbourhood. No cell anywhere on the lattice has a deficient 6-neighbourhood; the
defect is only that around the corner *vertex* a loop closes after 3 cells, and that a 2-step
"diagonal" across the corner is ambiguous (i-then-j lands elsewhere than j-then-i).

### 5.2 Placement: hide the corners, keep the poles playable

The free parameter is the cube's orientation in the body-fixed frame. Options: (a) spin axis
through two opposite corners → 2 corners at the poles, 6 at latitude ±19.47°; (b) spin axis
through face centres → 0 corners at poles, all 8 at latitude ±35.26°, poles on face
interiors. **Locked: (b), face centres at the poles** (§1.1's face table). Rationale: poles
are *destinations* (polar caps, V4 landmarks — and with (b) pole play is ordinary defect-free
lattice), while ±35.26° mid-ocean points are anonymous; and (b) keeps all 8 corners in one
symmetry class for one uniform handling.

### 5.3 The corner-zone design (locked)

1. **Deterministic ocean mask.** `height_on` (§3.5) blends the surface to deep ocean floor
   (r ≤ −20) within `CORNER_SEA_R = 48` cells of each of the 8 corner directions:
   `h' = lerp(h_ocean, h, smoothstep(0.6, 1.0, ang_dist(d̂, ĉ_k)/(48/R)))` — a pure function
   of d̂ (8 dot products, evaluated only when `max(|a|,|b|) > 0.98`, i.e. essentially free).
   The corner neighbourhood is therefore always: water surface at r = 0 (or its climate ice,
   which the frozen-sea pin keeps sound, `per_voxel_environment.gd:38-44`) over generated
   seabed — no walkable terrain, no trees, no snow lips, nothing shaped within 48 cells.
2. **Edit lock.** `break_terrain`/`place_block` (`world_manager.gd:347,382`) refuse (return
   0/false) within `CORNER_LOCK_R = 8` cells of a corner column — 8 discs of ~16 cells on a
   ~6×10⁸-cell surface. This is the *only* gameplay-visible rule, and it exists to make the
   proofs below unconditional. (COSMOS §7.1's "8 sealed keystone columns" candidate remains
   the fallback if playtesting ever wants a visible marker — a decorative unbreakable pillar
   *inside* the lock zone is compatible with everything here.)
3. **Window fill rule.** A window whose extension would cover the corner has one quadrant
   (past *both* edges) where the unfold is undefined: unfolding the three 90° index squares
   flat leaves a 90° index-space gap. Fill it by continuing the unfold **around the lower-
   numbered edge** (deterministic): the third face's cells populate the gap quadrant,
   *double-covering* part of that face near the corner. Reads there are consistent (same
   global cells → same pure function + same global edit keys); writes cannot diverge because
   the double-covered region lies inside the edit lock. Visually the whole zone is open water
   rendered flat at r = 0 from any projection — two slightly-different index placements of
   the same flat sea are pixel-equivalent; the ~30° shear at the three corner cells deforms
   only water.
4. **Movement.** Swimming/boating across a corner works in whatever window the player is
   homed on; home-face flips near a corner use the ordinary §4.5 machinery (the hysteresis
   band never requires an unfold deeper than the fill rule provides).

```
      face A │ face B                 unfolded (window index space):
        ╲    │    ╱                  ┌────────┬────────┐
         ╲   │   ╱                   │ face A │ face B │
          ╲  │  ╱      corner        ├────────┼────────┤
    ───────╲ │ ╱───────  vertex      │ face C │ (gap)  │ ← fill: C continued
      face C ╲│╱  (3 cells meet)     └────────┴────────┘   around the A–C edge
                                      writes forbidden within CORNER_LOCK_R
```

### 5.4 Proofs that nothing breaks

- **No infinite loops.** Every iterative algorithm (collapse flood `structural_solver.gd:23-24`
  caps; DDA `world_manager.gd:998` t ≤ max_dist; column scans `world_manager.gd:887` bounded)
  iterates over *window index space*, which is a finite rectilinear array regardless of the
  fold — termination arguments are untouched. The fold itself is a table lookup, not a search.
- **No degenerate cell.** Every global cell is a genuine spherical prism with positive volume
  (min area 0.707 m², §2.2 — the corner cells are 120° rhombi of area 0.77 m², sheared but
  not degenerate) and a full 6-neighbourhood (§5.1).
- **No duplicated block.** The window→global map is injective everywhere except the corner
  fill quadrant; there, double coverage affects reads only (consistent by purity) — writes
  are refused inside `CORNER_LOCK_R`, and the fill quadrant at distance > LOCK_R from the
  corner is single-covered (the double cover shrinks to the corner). Hence `_edits` can never
  hold two keys for one physical cell, and no cell's edit can be visible in one window and
  absent in another (keys are global, §1.3).
- **No unreachable block.** Every global cell appears in some window homed on its own face
  (identity mapping), and the edit lock only refuses *writes* in 8×~16-cell ocean discs — a
  documented rule, not an accessibility hole.
- **Collapse near corners.** Floods start at edits (`world_manager.gd:791` is called only
  from break/place) which are ≥ 8 cells from the corner; with solver box RADIUS 5
  (`structural_solver.gd:22`) a flood can never reach the double-covered wedge at all.

---

## 6. Problem 5 — gravity and orientation

### 6.1 The gravity field (filling the stub)

`PerVoxelEnvironment.gravity(pos)` (`per_voxel_environment.gd:126`, today the uniform
`Vector3(0, −9.81, 0)` stub at `:72`) becomes, in window space:

```
func gravity(pos: Vector3) -> Vector3:
    var r := Cosmos.body(_body).radius + pos.y            # radial distance (y ↦ r)
    return Vector3(0.0, -Cosmos.body(_body).GM / (r * r), 0.0)
```

- Direction is exactly `−Y` in window space (the §3.3 theorem) — no per-position tilt, ever,
  on the surface; the full vector field (`−GM r̂/r²` in the body frame) is what L1/L4 read
  when converting to inertial coordinates (COSMOS §4.2 `Cosmos.gravity_at` — unchanged).
- Magnitude varies with altitude (9.81 at r = 0, 8.36 at the +512 shell top on Earth) and
  per body (Moon 1.62) as pure data (COSMOS §1.2 table). `sample()`
  (`per_voxel_environment.gd:130`) exposes `gravity`/`gravity_magnitude` to material state
  machines unchanged.

### 6.2 The player controller and the analytic queries

- `player.gd:21` (`gravity := 22.0`) is a *tuned feel constant*, not 9.81 — per-body scaling
  is `22.0 × g_body/9.81` (jump height and fall cadence scale with real surface gravity while
  preserving today's Earth feel; `jump_velocity` likewise ×√(g_body/9.81)). Applied at
  `player.gd:234` verbatim; no vector code path changes. The player's scene basis never
  reorients: window space *is* upright space (the "player's local up varies over the sphere"
  problem is absorbed entirely by L1's f64 window→body basis, which only the sky, far field
  and space-mode handoff consume).
- `floor_under` (`world_manager.gd:871`), `blocked` (`:910`), `ceiling_scan` (`:952`),
  `surface_y` (`:860`), the swept head test (`player.gd:249-254`) — all are column scans in
  window space and run **verbatim**; "the analytic floor on a curved chart" is a non-problem
  because the chart is only curved in the render (§3.4), never in the query space.
- `GroundCollider` (`ground_collider.gd:134,161`) and `VoxelBody` debris live in flat window
  space with server gravity `−Y` — exact (§3.3). Distant awake debris (> ~64 m) gets the
  CPU-side visual bend (§3.4); its physics is unchanged (flat-space is the *correct* space).
- Crossing a seam, "down" remains the column direction with no event (§4.3); over a full
  circumnavigation the window basis rotates 2π in the body frame purely inside L1's f64
  bookkeeping.

### 6.3 Orbit handoff (pointer, not redesign)

The chart-ceiling ↔ ACTIVE handoff, velocity rebasing, and ω×r are locked in COSMOS §4.4 and
untouched; this pass only pins the conversion formulas both directions
(`P = (R+r)·face_cell_to_dir`, `dir_to_face_cell` on descent) and notes that the *window*
(not the tangent chart) is what the descending object re-enters — landing contact uses
`floor_under` as today.

---

## 7. Problem 6 — LOD tie-in

### 7.1 B1 (far field): flat tiles + the same bend

The branch `FarTerrain` design (rings to 3,072 m, main-thread amortized, hard caps —
`far_terrain.gd:24-46,41-42` (branch)) is kept structurally intact with two changes that
*simplify* it relative to COSMOS §4.5.2:

1. Tiles sample `height_on(body, face_cell_to_dir(...))` through the window projection —
   same one-call-per-lattice-point contract (LOD-DESIGN §2.1), window indices as tile
   coordinates. Beyond the home face the tile grid uses the same §4.3 unfold (B1's 3,072 m
   reach can overlap up to ~2 faces' strips; the unfold's ground-truth error at that depth is
   rendered truthfully because of (2)).
2. Tiles are built **flat in window space** (no baked curvature drop — *simpler than the
   branch design*, which baked `d²/2R` per vertex) and bent by **the same §3.4 vertex-shader
   include as B0**. One bend function ⇒ B0 and B1 agree at the 192–256 m overlap **exactly**,
   by construction, every frame — no drop-reference drift as the camera moves, no re-bake on
   recenter. The exact sagitta matters at B1 range: the truncated `d²/2R` errs by `d⁴/24R³ ≈
   14 m` at 3 km; the `sin/cos` wrap errs only by the warp/unfold metric residuals (≤ ~3 %
   scale near edges, hidden under `FOG_END = 2750` (branch `far_terrain.gd:49`) and B2
   takeover). Skirts (`SKIRT_CELLS = 4`, branch `far_terrain.gd:39`) keep masking inter-ring
   cracks as today.

### 7.2 B2 (planet mesh) and the orbital view: one lattice, downsampled

B2 (3 km → ~5R) is built in **true body-frame geometry** (it *is* the sphere; no bend): per
visible face a quadtree of patches, each patch a `(i, j)` index-aligned grid at stride 2^k
whose vertices are `(R + height_on(d̂))·d̂` with `d̂ = face_cell_to_dir(face, i, j)` — i.e. the
**same global lattice downsampled by powers of two**, sampled through the *same* two §1.2
functions and the same `height_on` as the near generator. Therefore:

- surface and orbit agree at true positions by construction (a mountain's summit column is the
  same `(face, i, j)` at every LOD; V3's "true positions" needs no reconciliation step);
- patch borders align across face edges by the 1:1 edge theorem (§4.1) — the classic
  cube-sphere quadtree with Ulrich skirts (the pattern LOD-DESIGN §1.4 already locked) closes
  crack-free over edges and corners (a corner joins 3 patches; skirts + the shared edge
  subdivision cover it);
- the B1→B2 handoff at ~3 km: B1's bent-flat geometry *is* the sphere to within the unfold
  residuals, so the seam is a fog-covered overlap band (LOD-RESEARCH's bias-down rule) with
  B2 biased slightly below B1 — same discipline as today's near/far bias
  (`BIAS_LAND`, branch `far_terrain.gd:38`).
- Edits stay invisible in B1/B2 (COSMOS §5 ladder, locked). B3+ (celestial band) is untouched
  by this pass.

---

## 8. Problem 7 — cost and determinism (the R2 tie-in)

### 8.1 The restream budget, re-quantified

| Event | Old (COSMOS provisional) | This design | Worker cost |
|---|---|---|---|
| Walk within a face | re-anchor ≈ 256 m teleport every ~50 s sprint | **origin shift: 0 blocks** | zero (pointer translation of scene nodes) |
| Ordinary streaming | streaming while walking | identical to today | today's envelope (view 256, `module_world.gd:201`; 1 worker, `project.godot:63-64`) |
| Face crossing (per ~10,000-block face traverse) | (deferred) | dual-window prestream, or hard restream | ≈ one initial load: disc π·256² ≈ 2.06×10⁵ columns → **≈ 1,600 mesh blocks (32³)** / ≈ 12,900 data blocks (16³) over the ±128 slab |
| Corner sail-by | (deferred) | nothing special (ocean; window machinery only) | zero extra |

Face-crossing arithmetic: prestream begins 32 cells before the edge and the flip completes
64 cells after — a ≥ 96-cell band = **≥ 21 s at walk (4.5 m/s), ≥ 10 s at sprint (9.5,
`player.gd:17-18`)** for the worker to mesh ~1,600 blocks nearest-first (the module's normal
priority). If the worker falls behind (low-end browser), the swap simply waits — the player
keeps playing on A's extension (valid ~512 cells deep) — and in the hard-restream fallback the
B1 far field (main-thread analytic tiles, ~3 ms/frame budget, branch `far_terrain.gd:41`)
covers the gap with no hole. Memory transient: the dual-window union is capped ≤ ~1.3× one
near field by shrinking the outgoing node's `view_distance` as the incoming one grows (R3
discipline; exact MB numbers are a Phase-1 measurement, gate below).

**Phase-1 exit gate (restates COSMOS §6 with the new shape):** (a) intra-face: zero
re-mesh on origin shift, measured; (b) a walking face crossing completes the dual-window swap
with no visible hole and no frame > budget on a mid-range browser; (c) the transient heap
stays within the R3 ladder.

### 8.2 Determinism (pure SEED, window-independent)

- **The invariant:** every generated value is a pure function of `(SEED, body, face, i, j, r)`
  — the window (home face, origin, extension shape) **never** enters generation. Enforced
  structurally: the generator callback folds to the global cell *first* (§3.1), all
  neighbourhood worldgen uses intrinsic adjacency keyed globally (§4.4), and trees/climate/
  snow key on global column ids (§3.5).
- **Trig hygiene:** `face_cell_to_dir` runs in f64 (`tan`/`atan` — GDScript floats are f64,
  COSMOS §4.1), then the direction components are **quantized to f32** (they feed
  `FastNoiseLite.get_noise_3d`, which is f32 internally) — a deliberate, documented rounding
  point that makes intra-platform determinism exact (same binary, same bits — the existing
  WGC §7 discipline, `terrain_config.gd:25-30`) and shrinks the cross-platform libm exposure
  to values within ½ ULP-of-f32 of a rounding boundary (measure-~zero; residual risk filed
  under R4 with the ephemeris trig, COSMOS §7.4 — same mitigation would cover both).
- **Verify pins (extends `verify_feature.gd`):** cell↔dir round-trip exactness on a lattice
  sample incl. all 24 edge remaps and 8 corners; *same global cell resolved through two
  different windows/home faces is byte-identical*; an edit written via window A reads back via
  window B; a seam-spanning collapse detaches the same component from both windows; corner
  flood termination; `N mod 32 = 0` and region/face alignment.

---

## 9. Build order (each milestone independently testable)

| # | Milestone | Contents | Key risk | Test/demo |
|---|---|---|---|---|
| **M0** | Math kernel | `cube_sphere.gd` (§1.2 functions, warp, generated edge-remap tables, corner tables, global keys); headless property tests only — no engine change | none (pure f64 math) | verify: round-trips, 1:1 edge adjacency, D4 table pins |
| **M1** | Single-face curved patch | Flat world reinterpreted as a face-4 window: `generated_cell_global` adapter (3D noise via d̂), `PerVoxelEnvironment.gravity` filled (§6.1), the §3.4 bend shader on B0 + water; `FLAT_WORLD` compatibility toggle proves byte-identical regression | bend shader vs material conversion (module per-model materials → ShaderMaterial), fog/DoF interactions | the locked COSMOS demo seed: stand on a beach, sea horizon at 147 blocks, hull-down works; dig/build unchanged |
| **M2** | Full-face play | Global edit keys (§1.3), per-(body,face) `ZoneChunk` keys, 256 m origin shifts, latitude climate; walk 10,000 blocks across a face | f32 hygiene at ~5–10 km face coords; streaming determinism far from spawn | circumnavigate one face; edits found again; polar cap on face 4 |
| **M3** | Seam crossing (fallback-grade) | Extended window + fold at the two choke points; `LatticeNav` for worldgen stencils; home-face flip via **hard restream** (fallback path fully; module path with the far-field cover) | remap bugs; restream stall UX | walk/build a wall/dig a tunnel/watch water across an edge; verify cross-window edit identity |
| **M4** | Dual-window handoff (module) | Second `VoxelTerrain` prestream + pixel-identical swap (§4.5); view-distance seesaw; measure R2 gate | **the single riskiest step**: 2 nodes on 1 web worker + WASM heap transient | sprint across a seam on a mid-range browser within budget |
| **M5** | Corners | Ocean mask + edit lock + fill rule (§5.3); orientation locked (§5.2) | double-cover leak subtleties | sail around a corner; verify no dup/lost edits, floods terminate |
| **M6** | LOD tie-in | B1 flat-build + shared bend (§7.1); B2 quadtree off the same lattice (§7.2); orbit-view agreement | B1/B2 seam at 3 km; edge-crossing far tiles | climb to the ceiling: continuous surface→far→planet, features at true positions |

M0–M2 need no seam code at all (Phase 1 can demo after M2 with play zones off edges — exactly
COSMOS §6's allowance); M3/M4 retire R2; M5 closes the last topological hole; M6 hands off to
the L5 passes.

---

## 10. Locked-interface conformance and loud flags

**Conforms (unchanged shape):** `WorldManager.block_id_at`/`cell_value_at`/`_write_cell` as
the two choke points (COSMOS §2 row 2, §4.3.3); `TerrainConfig` as THE pure function with
`resolve_cell(face,u,v,r,…)` (§4.3.2); `Frames.active_chart() → ChartInfo{body, anchor_dir,
basis}` and `Planet.chart() → {body, anchor, basis, cell_map}` (§4.1/§4.3 interfaces —
`cell_map` = origin offset + fold tables); the L0 per-body/face region keys (§4.6); the L4
handoff (§4.4); the L5 band table (§4.5); analytic collider-less physics (the engine's law);
one voxel worker, GL-Compatibility, no compute (§4.1/§2).

**Flags (numbers/emphasis refined within scope — no COSMOS amendment required, but record
these deltas when COSMOS is next touched):**

1. **±7 % warp-uniformity claim corrected** to the exact [0.707, 1.0] linear bound (§2.2).
2. **Re-anchor semantics beaten, not changed:** pop 0 (vs "≤ 0.4 blocks"), intra-face restream
   0 (vs "≈ 256 m teleport") — the §7.2 engineering question answered by construction (§3.2).
   R2 re-scopes to face crossings (§8.1); its Phase-1 gate text should be updated accordingly.
3. **The near field curves (render-only):** resolves the internal COSMOS tension between
   §4.3.4 ("near field need not curve") and §1.2 (147-block horizon as a locked feature) in
   favour of §1.2, via the §3.4 shader. No layer interface involved.
4. **Corner strategy:** "8 sealed keystone columns" (COSMOS §7.1 candidate) refined to
   ocean-mask + 8-cell edit lock (§5.3); keystones remain compatible as decoration.
5. **Cube orientation locked** (face centres at poles, §5.2) — a new decision COSMOS left
   open; it constrains only worldgen data, no interface.

**Nothing in this pass requires changing a locked layer interface.**

---

## 11. Open questions (for later passes, none blocking Phase 1)

1. **Warp fine-tuning:** a rational per-axis warp could trade the √2 edge-mid dip for a
   flatter profile; isolated behind `warp()`/`unwarp()` (§1.2) — decide only if the ~3 %
   near-edge gradient (§2.3) ever shows up in play. Changing it after ship changes ground
   truth (not indices), so decide before persistent worlds matter.
2. **Bend shader vs future shadows/specular:** unbent normals are fine for today's unlit-ish
   look; the L5 sky-quality pass (COSMOS §7.5) should revisit if DirectionalLight shadows
   land.
3. **Dual-window memory ceiling on 2 GB heaps** (R3 × §4.5): if measurement busts the 1.3×
   cap, the fallback is asymmetric handoff (hard-drop A at swap) — decided by the M4 gate.
4. **TreeGen/snow stencils near corners:** the canonical 2-step diagonal rule (§5.1) can
   produce a mildly odd smoothing lip on corner-zone seabed cells — invisible under the ocean
   mask; revisit only if corners ever become land.
5. **`VoxelTerrain` generator re-homing** (M4): whether godot_voxel v1.4.1 tolerates two live
   terrains + generators under the capped pool (`project.godot:63-66`) or needs a small module
   patch (we build the engine ourselves — `docker/engine/`) is an M4 spike question.
6. **Antipodal/void semantics** below r = −64 stay as COSMOS §7.7 (bedrock shell, void
   beneath) — untouched here.

---

## 12. Sources

- Cubed-sphere fundamentals & equal-angle coordinates: Ronchi, Iacono, Paolucci, *The "Cubed
  Sphere": a new method for the solution of PDEs in spherical geometry* (J. Comput. Phys.
  124, 1996) — the equal-angle grid and its metric factors;
  [Wikipedia: Quadrilateralized spherical cube](https://en.wikipedia.org/wiki/Quadrilateralized_spherical_cube)
  and [COBE sky cube](https://lambda.gsfc.nasa.gov/product/cobe/skymap_info_new.html) (QLSC
  properties, approximate-fit caveats).
- Tan-warp for game planets: [acko.net — Making Worlds 1: Of Spheres and Cubes](https://acko.net/blog/making-worlds-1-of-spheres-and-cubes/).
- Gnomonic projection scale factors (cos²θ radial / cos θ transverse):
  [Wolfram MathWorld — Gnomonic Projection](https://mathworld.wolfram.com/GnomonicProjection.html);
  [Wikipedia — Gnomonic projection](https://en.wikipedia.org/wiki/Gnomonic_projection).
- Equal-area polyhedral maps: Snyder, *An equal-area map projection for polyhedral globes*
  (Cartographica 29, 1992) — the iteration-for-inverse cost cited in §2.3.
- Chunked planet LOD + skirts: T. Ulrich, *Rendering Massive Terrains using Chunked LOD*
  (SIGGRAPH 2002 course; cited via `docs/LOD-RESEARCH.md` §3);
  [cuberact Godot planet chunked LOD](https://github.com/cuberact/godot-cuberact-planet-chunked-lod).
- Curved-world vertex displacement precedent (render-only planet curvature):
  [Distant Horizons](https://gitlab.com/distant-horizons-team/distant-horizons) far-field
  practice per LOD-RESEARCH §4, and the widely-used "curved world" vertex-shader family (e.g.
  [Godot shaders — curved world](https://godotshaders.com/shader/curved-world/)); exact
  sagitta form derived in §3.4.
- Floating origin / velocity rebasing / scaled space: the COSMOS §8 source set (Thorne; KSP
  Krakensbane; Zylann solar_system_demo) — inherited, not re-argued here.
- In-repo ground truth (verified 2026-07-07): `godot/src/world/world_manager.gd`,
  `terrain_config.gd`, `voxel_module/module_world.gd`, `fallback/chunk_streamer.gd`,
  `player/player.gd`, `sim/per_voxel_environment.gd`, `sim/climate_model.gd`,
  `physics/ground_collider.gd`, `world/structural_solver.gd`, `world/tree_gen.gd`,
  `godot/project.godot`; branch `feat/voxiverse-lod`: `world/far/far_terrain.gd`,
  `far_mesh_builder.gd`; `docs/COSMOS-ARCHITECTURE.md`, `docs/LOD-DESIGN.md`.
