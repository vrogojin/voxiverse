# COSMOS-REAL-GEOMETRY-STUDY — baking the inflated cube: real geometry instead of a placement shader

Status: DESIGN STUDY (Fable, 2026-07-09), task #76. Trigger: two live WebGL2 failures
of the M5a placement vertex shader (scrambled strips, wedge unchanged, near/far
mismatch) with the CPU math at 11/0 — a GPU-transport fragility we cannot test
headlessly. The user's model: *"what we want is just an inflated rubber cube — can't
we generate REAL geometry?"* This study designs that architecture rigorously and
gives the verdict. Companions: COSMOS-M5-ADR (the shader design this supersedes in
part), COSMOS-PROJECTION-STUDY (metric numbers reused here).

---

## 0. Executive summary — verdict first

**The user is right, and the resulting architecture is *better* than the shader plan
— including better than my own interaction-bubble adjudication.** Bake the inflation
into real mesh vertices (the `place_true` math that passed 11/0, run on CPU at mesh
time), and the entire remaining per-frame correction turns out to be a **rigid
rotation about the camera** — expressible as plain node transforms. End state:

- **Zero custom shaders in curved mode** (the bend retires too). Everything that
  broke twice — chart tables, classification, per-vertex trig transported through
  GLSL/driver — moves to CPU where the 11/0 harness actually covers it.
- **The wedge is gone from render entirely** (double-cover triangles culled at bake;
  the corner-closure theorem guarantees no hole) — better than the shader plan,
  which kept an echo inside the bubble.
- **The interaction bubble is RETIRED**, replaced by something simpler and *exact*:
  a per-ray/per-tick CPU Jacobian correction at the camera (aim residual ≈ 0.005
  blocks at reach, vs the bubble's approximation and the naive 1.5–1.7-block skew).
- Zero memory delta; ~0.2 ms/chunk C++ bake cost; per-frame cost = a few node
  transforms.
- **The two structural costs, honestly:** (1) the near field must be baked inside
  the godot_voxel meshing path — a small **C++ module hook** (engine rebuild
  pipeline we already own, patch-0002 precedent); GDScript post-processing is
  main-thread jank (4–20 ms/block on web) and per-block mesh access isn't a stable
  module API. (2) **Two-space rendering**: physics stays in window space, render is
  true space, so every *visible window-space object* (VoxelBody debris, selection
  highlight, overlay pillars, particles) needs a small per-object render offset —
  a bounded, enumerable list.
- Staged: **R1** far-layer bake (GDScript we own, no engine touch, days — kills the
  far wedge echo + far misalignment, most of what the user sees) → **R2** near-field
  module bake + rigid alignment + input mapping, bend retired → **R3** M5c
  pillar/anomaly (design unchanged). Each behind a toggle.

My previous "fix the shader" recommendation is **superseded**: the failure mode is
transport, not math; a repaired shader stays permanently exposed to the class that
already burned two deploys, while the baked path is testable end-to-end headlessly.

## 1. The architecture

Four pieces, all CPU:

1. **Bake (per mesh chunk, once at mesh/edit time):** transform every vertex from
   window coords to its true sphere position `P = (R+y)·d̂(fold(raw(w)))` expressed
   in the **epoch tangent frame** (anchor = the chart origin at the last flip;
   orthonormal frame with the anchor's radial as +Y). Per-vertex cost: 2 `tan` +
   normalize + one mat3 — ~50 ns in C++. Rebaked automatically whenever godot_voxel
   re-meshes (edits) — consistency for free. Wedge (double-out) triangles are
   dropped here; strips wrap and close the corner as *real, weldable* geometry.
2. **Rigid per-frame alignment (node transforms, no shader):** as the player walks
   away from the epoch anchor, the camera's true radial tilts from +Y by
   dist/R (0.58° at 64 cells, 27.6° at a full window — exact rigid rotation at any
   angle). Each frame, set the render roots' (module wrapper, far node) transform to
   the rotation about the camera that re-levels the camera's radial to +Y, and place
   the camera/hand nodes at the aligned true position of the player's window
   position. A handful of `Transform3D` sets per frame — the most driver-proven
   operation that exists. No rebake cadence is ever needed (rigid = exact at any
   angle); a flip's restream rebakes into the new epoch frame with `M_win`
   continuity (#74 machinery unchanged, still load-bearing).
3. **Input/aim mapping (CPU, exact):** physics remains flat-window (locked). The
   camera sees true space, so map view→window at the origin: the DDA ray direction
   and the WASD movement direction are multiplied by `J(w_cam)⁻¹` (the same 3×3
   window→sphere Jacobian, inverted once per ray/tick). Residual = ray-curvature
   only: **≈ 0.005 blocks at reach 5** (measured `|dS/dw|·d²`), versus 1.5–1.7
   blocks naive skew at seams/corner without it — this correction is mandatory, and
   it *replaces the M5a interaction bubble* with an exact, simpler mechanism (the
   bubble was an approximate render-side blend; this is an exact input-side map).
4. **Per-object render offsets (the two-space consequence):** visible objects whose
   physics lives in window space get their *render* placed at aligned-true
   positions: VoxelBody debris (mesh child offset, updated when moving / once when
   sleeping), the block-selection highlight (place at true(cell)), border-overlay
   pillars, any particles. Terrain, water, and portal-frame blocks are baked with
   the terrain — no work. Bounded, enumerable list; each is one transform.

## 2. Q1 — feasibility on godot_voxel + costs

| Hook | Viability | Cost | Verdict |
|---|---|---|---|
| **C++ transform in the module's blocky mesher output** (before arrays upload) | precedent: we already patch the module (0002); the transform is one function over the vertex/normal arrays with the frozen epoch uniforms | ~50 ns/vert → **0.2 ms per 4k-vert block**, inside the existing C++ mesh workers; zero main-thread cost; AABBs recomputed automatically from transformed arrays | **the near-field path** |
| GDScript post-process of per-block meshes | per-block `ArrayMesh` access is not a stable module API; would run on the main thread | 1–5 µs/vert → **4–20 ms/block on web** = jank | fallback only if the API exists; verify first |
| Far layer / water / debris (our own GDScript builders) | full control | +2 trig per vertex inside existing build loops (~+10–20% of far tile build, amortized under the 3 ms/frame budget) | **R1, no engine touch** |

Memory: identical vertex/normal counts → **zero delta** (never-OOM ✓). Face culling
at mesh time happens on the flat lattice before the transform — still valid (smooth
deformation preserves adjacency/occlusion topology). Web build: the module is
already compiled in (`module_in_web=yes`); the hook ships inside it.

## 3. Q2 — precision

Per-chunk **local origins**: bake vertices relative to the chunk's true anchor
(chunk node origin = anchor, f64 on CPU); local offsets ≤ ~64 blocks → f32 ULP
7.6e-6 (exact for our purposes). Node origins stay ≤ window scale (epoch frame is
anchor-centred). Reanchor: unchanged — a pure translation of node origins
(`M_win`/org bookkeeping identical to today); the bake frame is per-*epoch* (flip),
not per-reanchor, and the rigid alignment absorbs any angle exactly, so **no rebake
between flips, ever**. Far LOD: same epoch frame, same alignment root — near/far
coincide by construction (they share `place_true`), killing the "LOD not coinciding
with chunks" class structurally.

## 4. Q3 — physics consistency (and the bubble's retirement)

- Flat local collider vs true surface sag: 0.0007 blocks at 3, 0.002 at 5, 0.02 at
  16 — irrelevant at interaction range.
- Aim/DDA and movement: **exact at the origin** via the `J⁻¹` input map (§1.3);
  residual 0.005 blocks at reach. The interaction bubble is **unnecessary** —
  retired, along with its blend-zone swim and T9/T10 gates (replaced by an
  input-map gate: window cell hit by the corrected DDA == cell under the true view
  ray, sampled at corner/edge/centre cameras).
- The one *honest* visible of true rendering (any variant — shader or baked):
  directional ground-speed truth near seams. Window physics moves you 1 cell/tick;
  the true world shows that as ×0.67–×1.15 depending on direction/place (the locked
  unit-cube metric, now rendered honestly). Mid-face imperceptible; near seams a
  mild "terrain feel" variation; disclose to the user, gate the range.

## 5. Q4 — wedge and corner in real geometry

- **Wedge: gone by construction.** Double-out triangles are culled at bake; the
  corner-closure theorem (M5-ADR §1) guarantees the strips' true images tile the
  vertex neighbourhood completely — culling leaves **no hole** (gate: closed ring
  of real vertices around the vertex, max weld gap < 1 block; this is now a plain
  CPU vertex assert, not a shader test). The M5a "fading echo inside the bubble"
  hack is unnecessary — there is no echo anywhere.
- Physics still has wedge collision until M5c seals it (invisible floor if entered)
  → keep the adjudicated order: **M5c-lite (pillar + anomaly + eager flips) lands
  with or before the first user A/B.** M5c's design is unchanged by baking; it gets
  *simpler* presentation-wise because there is no rendered echo to hide.
- The 3-face corner is meshed as three real, true-placed patches meeting along real
  shared edges — continuous geometry a headless gate can literally weld-check.

## 6. Q5 — reused vs replaced

| | |
|---|---|
| **Untouched** | worldgen, §8.2 canonical fold, edit keys, streaming, floating origin/reanchor, flips + `M_win` (#74 — still a prerequisite: the epoch bake frame derives from the window frame), gravity, analytic physics, M4 handoff, M5c design |
| **Reused** | `CosmosTruePlace` math (the 11/0 part) as the bake transform; T1–T7 gates (now asserting *baked vertices*, which is stronger — they test the shipped artifact, not a mirror); the closure theorem |
| **Replaced** | the M5a GLSL placement shader (dropped); the interaction bubble (→ exact `J⁻¹` input map); **the CosmosBend shaders retire in curved mode** (kept behind the toggle for rollback) |
| **New** | the C++ mesher bake hook; the rigid alignment updater; the input map; per-object render offsets; bake-parity gate (baked vertex == `place_true` == `world_point`, per chunk, headless) |

## 7. Verdict, risks, fallback

**Verdict: adopt real-baked geometry.** It is more robust (the failure class that
broke two deploys is structurally eliminated — nothing chart-shaped crosses the
GPU boundary), more testable (every stage is a CPU artifact a headless gate can
byte-check), *more* correct (exact input map beats the approximate bubble; wedge
fully gone), memory-neutral, and cheap at runtime. The shader path, even repaired,
would remain permanently exposed to driver variance we cannot test before deploy.

Biggest risks, ranked:
1. **The C++ mesher hook** — the one structural dependency. Verify the exact
   insertion point in the module's blocky mesher first (a spike task); precedent
   and the build pipeline exist. Fallback: if the module exposes per-block meshes
   to script, a threaded GDScript/C# post-process; last resort, R1-only shipping
   (far baked, near stays bend) — which already delivers most of the visible win.
2. **Two-space rendering leaks** — a visible window-space object someone forgets to
   offset renders misplaced near seams. Mitigation: one `RenderSpace.true_of(w)`
   helper + an inventory gate (enumerate visible non-terrain nodes; assert each is
   offset-registered).
3. **Normals/AABB correctness in the bake** — mechanical; covered by the
   bake-parity gate + a lighting sanity screenshot.
4. The honest speed-truth disclosure (§4) — user expectation, not a defect.

## 8. Staged plan

| Stage | Contents | Size | Ships behind |
|---|---|---|---|
| **R1** | far layer + water + debris baked true (GDScript builders we own), far wedge tiles culled, rigid alignment root for the far node, ring-0 window-blend baked at tile build (rebuilt on the existing 64 m recenter) so the near(bend)/far(true) join stays clean at seams | days; no engine touch; kills the far echo + far misalignment | `M5_REAL` toggle |
| **R2** | C++ mesher bake hook (near field), bend retired in curved mode, camera/hand true-placement, `J⁻¹` input map, per-object render offsets, reanchor cadence tightened if needed | ~1 milestone incl. the spike + engine rebuild cycle | same toggle |
| **R3** | M5c pillar + anomaly + eager corner flips (unchanged design) | days-small | corner flag |

Gates per stage: bake-parity (vertex == `place_true`, headless), seam weld ≤ 1.05
cells, corner closed-ring, input-map hit-cell equality, G-A/G-B re-run, horizon-147,
FLAT_WORLD/toggle byte-identity, never-OOM budget unchanged. Go/no-go between
stages: gates green + live web deploy at FPS parity + user pass.
