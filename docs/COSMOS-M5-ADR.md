# COSMOS-M5-ADR — true-position render with walkable land corners: the design

Status: ADR (Fable, 2026-07-08), task #76. Supersedes the *sizing* of M5b/M5c in
COSMOS-M5-MULTICHART.md (the scoping note feared per-face render volumes and a
geodesic integrator; §1 below proves neither is needed at the current R_FAR — the
scope collapses). Prerequisite: #74 `M_win` (COSMOS-FRAME-ORIENTATION), shipped.
Locked user decisions: true-position render; **walkable LAND corners** (a general
technique valid for dry planets — the §5.3 sea-corner shortcut is rejected as the
corner *solution*, though its edit-lock and keystone-fallback clauses are reused);
staged M5a→M5b→M5c with the user in the loop; spawn stays on the polar face-4
corner; the loadable/playable web demo outranks everything.

---

## 0. Executive summary

- **One shader, five exact charts, zero new render volumes.** M5 replaces the
  camera-centred sagitta bend with per-vertex placement at the exact sphere position
  `P = (R + y)·d̂(face, i, j)`. The window already contains, at single-edge-fold
  positions, every real cell within reach — home + 4 strips. The shader classifies
  each vertex into one of the 5 charts (exact integer affines, uniforms), maps it to
  its true face coordinate, and places it at `P` in the camera's tangent frame.
- **The corner-closure theorem (§1)** kills the feared "tri-chart near render":
  near a vertex the two strips contain *all* neighbour-face cells within reach, and
  their true-position images wrap around the vertex and meet exactly at the
  neighbours' shared edge — 90°(home) + 90° + 90° of window covers exactly the 270°
  of reality; the 90° wedge is discarded, nothing overlaps, nothing gaps. The corner
  renders geometrically true **from the existing single near volume**, and the far
  field likewise (3072 ≪ n/2 = 5008, so at most one vertex and no second wedge is
  ever in range).
- **Walkable corners (M5c) reduce to motion + a keystone (§4):** eager home-face
  flips inside a small corner zone keep the player's column out of the wedge, and
  the vertex cell itself carries the §5.3-anticipated unbreakable keystone monument
  (~3-cell disc, 8 per planet). This is not a dodge: in the gameplay (per-face flat
  lattice) metric the vertex is a genuine cone point with a 90° angle deficit — a
  geodesic *through* it is mathematically ambiguous by ±45°, so **any** general
  technique must special-case the apex; a 3-cell monument is the minimal honest one,
  and it works identically on dry planets.
- **Web-safety by construction:** no new voxel volumes, no new draw calls, no new
  per-frame CPU work beyond three uniform updates (the bend does two today); vertex
  cost comparable to the bend (adds one 5-way uniform branch + 2 `tan`).
- Staging: **M5a** placement shader + gates (the milestone-sized piece), **M5b**
  far-layer verification + wedge-tile drop (small), **M5c** corner zone (small).

## 1. The corner-closure theorem (why the scope collapses)

Setup: home face A, vertex V shared with faces B (WEST) and C (SOUTH); window reach
ρ (near 128, far 3072), face size n = 10016.

1. *Strip coverage:* a face-B cell at distance `d₁` from the A-B edge lies in the
   WEST strip iff `d₁ ≤ ρ`. Any face-B cell within ρ of V has `d₁ ≤ ρ` (its distance
   to the A-B edge is bounded by its distance to V — the A-B and B-C edges are
   perpendicular sides of face B's corner). Likewise face-C cells and the SOUTH
   strip. Hence **every real cell of A, B, C within ρ of V is present in the window
   exactly once** (home, WEST strip, SOUTH strip respectively — disjoint bands of
   different faces).
2. *Exact closure:* under true placement, strip cells land at their real positions;
   the WEST strip's face-B image is bounded by the true B-C edge, the SOUTH strip's
   face-C image by the same edge from the other side; both are placed by the same
   `world_point`, so they meet exactly (to f32) with no third volume. Window angle
   bookkeeping at V: 90° + 90° + 90° → the full 270° of reality; the wedge's 90° is
   the flat window's excess and is **discarded** — no overlap, no gap.
3. *Reach bounds:* R_FAR = 3072 < n/2 = 5008 ⇒ at most one vertex in range and
   never a second wedge; strips at far reach cover the whole 270° cap to the
   horizon. Consequence: **per-face "neighbour charts" (the scoping note's M5b) are
   unnecessary at this R_FAR** — they return only if R_FAR ever exceeds ~n/2 or for
   the §7.2 orbital view (B2), for which this ADR keeps the door open (the shader's
   chart table generalizes; nothing here hard-codes 5).

## 2. M5a — the placement shader (implementation design, ready for Opus)

### 2.1 Conventions (normative)

- Continuous raw coordinate: `a = 2·x/n − 1` for continuous window-derived lattice
  coordinate x (so cell centre `k + 0.5` reproduces `face_cell_to_dir(face, k)`'s
  `a = 2(k+0.5)/n − 1` exactly). The CPU mirror and the GLSL must share this line.
- Chart classification of a vertex's raw `p = org + M_win·w.xz` (f32; `|p| ≤ ~3300`
  and `org` components ≤ n = 10016 — f32-exact for integers up to 2²⁴):
  in-range → home; one axis out → that side's strip affine `(M_s, t_s)`; both out →
  **wedge: discard** (emit a degenerate position; M5c's keystone makes the region
  unreachable anyway).
- Well-conditioned camera-relative output (avoids any R-magnitude f32 subtraction):

```
d̂    = normalize(n̂_s + tan(a·π/4)·û_s + tan(b·π/4)·v̂_s)      // strip s's true face axes
POS  = M_tangent · ( R·(d̂ − d̂_cam) + w.y·d̂ − y_cam·d̂_cam )   // every term small near camera
```

  `d̂_cam` (f32 vec3), `y_cam` (f32), `M_tangent` (mat3) are per-frame global
  uniforms computed on CPU in f64: `d̂_cam` from the camera's continuous raw coords;
  `M_tangent` = orthonormalized Jacobian of the window→sphere map at the camera
  (columns: normalized ∂P/∂x, d̂_cam, ∂P/∂z), so the map is **first-order identity
  at the camera** — physics-render divergence is quadratic, ≈ 0.002 blocks at the
  5-block DDA reach (D²/2R), the same class as the bend today.
- Uniform update cadence: the 5-chart table (per chart: 2×2+2 int affine + 3 vec3
  axes) **only at a flip**; `org` **only at a reanchor**; `M_tangent`/`d̂_cam`/
  `y_cam` **per frame** (three globals; the bend pushes two today).

### 2.2 Integration points

1. New `cosmos_true_place.gd` (peer of `cosmos_bend.gd`; CosmosBend is retained
   untouched for the toggle): builds opaque/translucent/far shader variants around
   one shared `_VERTEX_PLACE` snippet (the CosmosBend pattern — single string,
   mirrored by a GDScript `place_point()` for verify).
2. `BlockMaterials` / `FarTerrain.make_material` / water / VoxelBody debris: where
   they select the bend shader in curved mode, select the M5 shader when
   `CubeSphere.M5_RENDER` (new const, default **false**) — one branch per site;
   `M5_RENDER = false` restores the bend byte-identically (the FLAT_WORLD /
   SMOOTHING_ENABLED discipline).
3. `main.gd` per-frame: compute + push the three globals (replacing the bend's
   `set_camera` when M5 is on — exactly one shader family's globals are pushed,
   keyed on the flag). `WorldManager.maybe_reanchor` / `maybe_flip_home_face`: push
   `org` / the chart table (the node-repositioning hooks already sit there).
4. **No change** to meshers, godot_voxel, physics, streaming, edits, #74, #69.

### 2.3 M5a gates (headless, `verify_cosmos_m5.gd`)

- **T1 ground truth:** `place_point(w)` == `M_tangent·(world_point(fold(raw(w))) −
  P_cam)` to 1e-3 blocks over home + all 4 strips, near and far radii.
- **T2 camera identity:** `place_point(camera) == camera` to 1e-4; Jacobian ≈ I at
  the camera by finite differences (1e-3).
- **T3 seam weld:** across each of the home face's 4 edges, adjacent cells place to
  points ≤ 1.05 cells apart (no crack, no overlap) — the assert that replaces the
  old §4.6 kink acceptance.
- **T4 corner closure:** a ring of strip cells around the vertex — the B-side and
  C-side images meet along the true B-C edge with gap < 1 block; swept angle
  270° ± ε; no two placed cells coincide (no double cover).
- **T5 flip/reanchor continuity:** FRAME-ORIENTATION G-A/G-B re-run under M5 —
  every probe cell's *placed* position equal across a reanchor and 90°/180°/0°
  flips.
- **T6 horizon:** the ~147-block sea horizon (eye 1.7) — now emergent from true
  geometry; keep the numeric pin. **T7:** FLAT_WORLD and `M5_RENDER=false`
  byte-identical. **T8 jitter:** placed-position noise at 3072 blocks < 0.05 under
  simulated camera micro-motion (the f32 conditioning gate).

## 3. M5b — far field under M5 (reduced scope)

No new charts (§1.3): with the M5 far shader the existing far tiles place true.
Work: (i) drop far tiles whose footprint is wholly wedge (discarded geometry — save
the budget); (ii) desired-set audit — tile AABBs and eviction distances stay
window-metric while placement is curved (conservative; document); (iii) gates:
T3/T4 at far reach + a horizon-silhouette closure sweep around the vertex.
Days, not a milestone.

## 4. M5c — walkable land corners (reduced scope)

The gameplay metric (per-face flat lattice) concentrates a 90° angle deficit at each
vertex: it is a cone point, and a geodesic through the apex is ambiguous by ±45° —
*no* technique can make "walking straight across the exact vertex" well-defined
without inventing an answer. The general dry-planet design:

1. **Corner-zone eager flip:** within `CORNER_ZONE_R` (proposed 32) of a vertex,
   `flip_needed` uses `FLIP_HYST_CORNER` (proposed 8, vs 64) — the player re-homes
   onto whichever face they walk onto almost immediately, so circling the vertex at
   any radius beyond the keystone is a sequence of exact single-edge isometries
   (`M_win` keeps each rotation-free; a full loop accumulates the honest 90°
   holonomy). Flip-storm control: 8 cells still exceeds any zigzag amplitude, and a
   circling player pays the same 3 flips per lap as with hysteresis 64.
2. **The keystone:** the ~`KEYSTONE_R = 3`-cell disc at each vertex renders and
   collides as an unbreakable decorative monument (exactly the fallback TOPOLOGY
   §5.3 item 2 anticipated; it sits inside the locked `CORNER_LOCK_R = 8`
   edit-refusal disc, which ships with it). It blocks the only path into the wedge
   (the diagonal through the vertex cell), making the wedge **unreachable** — its
   synthetic collision content becomes moot and the M5a render discard is never
   visible from a reachable position.
3. **Edit policy:** the locked `CORNER_LOCK_R` refusal in `break_terrain` /
   `place_block` (§5.3 item 2), unchanged by land corners.
4. **Gates:** wedge unreachability (a driven walker circling at radii
   `KEYSTONE_R+1 .. CORNER_ZONE_R` never acquires a double-out column; every flip
   in the loop is single-edge; loop holonomy = 90°); keystone render == collision;
   the edit lock; T4 re-checked with the keystone present.

Deliberately **not** built: an apex-crossing cone-chart integrator (ill-posed at the
apex, per above); revisit only if playtesting demands stepping over a 3-cell
monument.

## 5. Staging, size, risks

| Stage | Contents | Size | Gate set |
|---|---|---|---|
| M5a | placement shader + integration + toggle | ≈ one milestone (far-LOD/M4 scale) | T1–T8 |
| M5b | far wedge-tile drop + audits | days | T3/T4-far, horizon closure |
| M5c | eager corner flip + keystone + edit lock | days–small | unreachability, holonomy, lock |

Risks, ranked: (1) **f32 conditioning** of the placement chain — mitigated by the
§2.1 well-conditioned form + T8; fallback: per-chunk f64-precomputed `d̂`-anchor
uniforms. (2) **WebGL2 vertex branching** — coherent (whole chunks share a chart
except at strip boundaries); measure in M5a before starting M5b/M5c. (3)
**Perceptual:** true placement makes distant across-seam terrain *converge*
(curvature) where the flat window spread it — the world will read slightly
"smaller" across seams; not a bug, brief the user. (4) **Toggle hygiene:** bend and
M5 shaders must not both push globals — `main.gd` keys one set on `M5_RENDER`.

Sequencing: M5a on a fresh branch off `main` (post-#16; #74 is merged beneath it —
prerequisite); M5a review + live web deploy + user pass before M5b; the M5c corner
constants land behind their own flag so the user can compare corner feels live.
