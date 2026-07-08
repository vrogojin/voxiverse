# COSMOS-M5-MULTICHART — scoping the true-position render milestone

Status: SCOPING (Fable, 2026-07-08). No implementation. Companion to
COSMOS-PLANET-TOPOLOGY (§3.4 bend, §4.6 metric lie, §5.3 corner zone, §7.2 B2),
COSMOS-FRAME-ORIENTATION (#74 `M_win`, the corner wedge §5.4/§10).
Context: the user chose M5 over the bounded wedge-fill blend (FRAME-ORIENTATION §10 —
dropped); this note defines M5, what it subsumes, size/shape/risks, and the staging.
Hard constraint: spawn stays on the polar face-4 corner; the live web demo stays loadable
and playable.

---

## 0. Executive summary

- **M5 = true-position rendering.** Replace the camera-centred sagitta bend (one flat
  window wrapped radially around the camera) with placement of every rendered vertex at
  its **exact sphere position** `P = (R + y)·d̂(face, i, j)`, expressed camera-relative in
  the player's tangent frame. Physics, streaming, edits, and the floating-origin window
  stay exactly as they are — M5 is a **render + corner-policy milestone, not a physics or
  engine rewrite**, and it does not require rebuilding godot_voxel.
- **It kills the whole §4.6 class, not just the corner:** the wedge, the corner metric
  lie, and the seam kink (rigid-unfold placement error growing away from every edge) all
  vanish, because nothing is ever rendered at an unfolded flat position again.
- **#74 (`M_win`) is a prerequisite, not wasted work** (§3.1): M5's tangent frame is
  derived from the window frame; without the orientation pin the entire true-position
  render would rotate on every flip — bug #2 at planet scale. Everything #74 ships
  (frame pin, gates, Fix-A revert, canonical modifiers) survives M5 unchanged.
- **Discovery that reshapes the corner scope (§4): the R1-LOCKED corner-zone design
  (TOPOLOGY §5.3) was never implemented.** `CORNER_SEA_R = 48` / `CORNER_LOCK_R = 8`
  exist in `cube_sphere.gd:30-31` and are pinned by `verify_cosmos_m0:447` — but have
  **zero consumers**: no ocean mask in the height path, no edit lock in `world_manager`.
  The locked design makes every corner deep sea ("no walkable terrain, no trees, nothing
  shaped within 48 cells — the ~30° shear deforms only water"). The entire corner saga
  happened on land that the locked design forbids. The corner decision must be re-made
  explicitly (§4): implement §5.3 (small; M5's corner scope then collapses) vs land
  corners (M5c, the only genuinely open-ended part of M5).
- **Staged and shippable (§5): M5a** exact-placement shader for the existing single
  window (~the size of one prior milestone; removes the metric lie everywhere but the
  wedge), **M5b** neighbour-face render charts (true across-corner horizon), **M5c**
  corner policy (trivial if §5.3 ships; medium-large if corners stay land). Each stage is
  independently web-verifiable behind a toggle, the same `FLAT_WORLD`/`SMOOTHING_ENABLED`
  discipline as every prior milestone.

## 1. What M5 is (and is not) in this codebase

Today (M1–M4): one flat lattice window = home face + rigid-unfold strips + synthetic
wedge; all geometry is meshed and *placed* at flat window coordinates; `CosmosBend`
(§3.4) wraps the flat picture radially around the camera per frame. Exact at the camera,
metrically wrong with distance (§4.6), singular at corners.

M5: geometry is still *meshed* on flat per-face lattices (godot_voxel and the far
builder unchanged), but *placed* at true sphere positions:

```
vertex (window x, y, z)
  → strip classification (home / W / E / N / S — 5 exact integer affines, §4.3 tables)
  → true face cell (face, i, j)         [the fold, now applied per-vertex in the shader]
  → d̂ = normalize(n̂ + tan(a·π/4)·û + tan(b·π/4)·v̂)          [face_cell_to_dir, in GLSL]
  → P = (R + y)·d̂                                            [world_point, §1.2]
  → camera-relative tangent-frame output: M_tangent · (P − P_camera)
```

`M_tangent` and `P_camera` are per-frame f64 CPU uniforms (the same discipline as the
bend's `cosmos_bend_origin`), so f32 shader residuals stay near-camera-small. The home
cell under the camera maps to itself: like the bend, M5 is identity at the player, so
physics (flat window, y↦r) and render agree where the player stands and diverge only
where it cannot matter — but now the divergence is *zero in ground truth* instead of
growing with distance.

**What M5 is NOT:** not multiple physics worlds, not a spherical-gravity player rewrite,
not per-face `VoxelTerrain` instances for the interactive near field (the near field
stays the single home-window volume; "multichart" refers to *placement charts* — the
per-face affine+gnomonic maps — plus render-only neighbour-face volumes in M5b), and not
the §7.2 B2 orbital planet mesh (a later, separate consumer of the same `world_point`).

## 2. Components

1. **M5 placement shader** (replaces the three `CosmosBend` shaders — opaque,
   translucent, far). Inputs per frame: `M_tangent`, `P_camera`, `(i_org, j_org)`,
   `M_win`; per body: face axis table + the home face's 4 edge affines (small uniform
   block, changes only at a flip). Cost per vertex: one branch over 5 strip cases, 2
   `tan`, 1 `normalize`, 1 mat3 — comparable to the current bend (2 trig + normalize);
   no new per-frame CPU work beyond two uniforms. Wedge-quadrant vertices have no true
   preimage: **discarded** (degenerate output) — what is really there is drawn by M5b's
   neighbour charts, or is flat sea under §5.3 (see §4).
2. **Neighbour-face render charts (M5b).** Render-only, collision-free volumes (the far
   layer's discipline: analytic heightmap tiles + caps + budget, one per face within
   sight range — at most 4 faces relevant near a corner, 2 near an edge, 1 mid-face)
   carrying the *neighbour faces'* content at true positions via the same shader with
   that face's uniforms. This is what replaces the deep strips and the wedge visually:
   the across-seam horizon becomes the actual planet. Near-interactive terrain remains
   home-window-only — by the time a neighbour face is within interaction range, the §4.5
   flip has made it home.
3. **Corner policy (M5c or §5.3)** — see §4. Includes the corner *edit* policy
   (`CORNER_LOCK_R`, already specified and locked).
4. **Precision engineering.** Camera-relative f64→f32 uniform pipeline, jitter test at
   R = 6371 (f32 ULP at planet radius ≈ 1 mm — acceptable, but the tan/normalize chain
   near strip boundaries needs a numeric gate), seam weld tolerance between home volume
   and neighbour charts (both compute `P` of the same physical cells → agree to f32 by
   construction; the gate pins it).
5. **Gates.** Ground-truth placement (rendered vertex == `world_point` to tolerance,
   home + all 4 strips + across-seam), seam continuity home-volume↔neighbour-chart,
   corner closure (the 270° renders with no gap/overlap), FRAME-ORIENTATION G-A/G-B
   equality gates re-run under M5 (the tangent frame must stay flip/reanchor-continuous),
   horizon distance (the §3.4 ~147-block sea horizon now emerges from true geometry —
   keep the pin), and the standing web gate: loadable, playable, no perf regression.

## 3. What M5 subsumes, retains, and simplifies

### 3.1 #74 `M_win` — RETAINED, and a prerequisite. Not wasted.

The physics/streaming window survives M5 unchanged, and with it the window's orientation
question. M5's `M_tangent` is built from the window frame: if that frame rotated per
flip (pre-#74), the whole true-position render would visibly rotate around the player at
every flip — bug #2 re-created at planet scale. #74 is also what makes M5's per-flip
uniform update a pure *translation* of `(i_org, j_org)` + edge-table swap with no
orientation discontinuity. Everything in #74 ships value now (the live rotation bug) and
remains load-bearing under M5: the frame pin, the G-A/G-B gates (re-used as M5 gates),
the Fix-A revert, canonical directional modifiers, and `ShapeCodec.rotate_modifier`.
Verdict: ship #74 now; zero of it is thrown away.

### 3.2 Replaced / eliminated by M5

- `CosmosBend`'s camera-centred sagitta (all three shaders) → the M5 placement shader.
  (`bend_point`/`sea_horizon_distance` survive in verify as ground-truth references.)
- The **rendered** wedge: #69's canonical fill stops being drawn (M5a discards; M5b/§5.3
  shows the real terrain/sea). The #75 red marker retires.
- The §4.6 metric lie as a *visible* phenomenon: seam kink, corner shear, the 0.707
  transverse dip — all placement artifacts of rendering unfolded flat positions; none
  survive true placement. (§4.6 remains true of *index bookkeeping*, which is invisible.)

### 3.3 Retained (content/identity layer — untouched by M5)

- The flat window, floating origin, re-anchor, flip, extended-window fold for
  **physics/collision/DDA/streaming** — the y↦r theorem is per-face exact and M5 keeps
  gameplay on it.
- #69 `fold_cell_canonical` for **content identity**: worldgen stencils crossing edges,
  global edit keys, region keys. (Its wedge branch stops feeding the *render* but still
  answers physics-window queries until/unless §5.3 makes the zone sea.)
- `LatticeNav`, the frozen-epoch generator discipline, all of #74.

### 3.4 Simplified

- **Bug-#1 J machinery:** M5b neighbour charts mesh each face's content in its own face
  frame → render `J = I` there by construction. The home window's strips still need the
  window-frame modifier for the **collider** (physics stays folded), so the #74 J path
  survives on that side — smaller, not gone.
- The M4 flip handoff: with M5b, the across-seam horizon no longer changes identity at a
  flip (the neighbour chart was already rendering true positions), so the far
  cover/handoff machinery can shrink to the near-field ramp only.

## 4. The corner decision (must be made explicitly — the locked design is unimplemented)

TOPOLOGY §5.3 (LOCKED at R1) specifies: deterministic deep-ocean mask within
`CORNER_SEA_R = 48` cells of each of the 8 corner directions (a pure function of d̂,
~free to evaluate), edit lock within `CORNER_LOCK_R = 8`, a deterministic window-fill
rule, and the proof that the residual ~30° shear then "deforms only water" —
pixel-equivalent, invisible. **None of it is implemented**: the constants sit unconsumed
in `cube_sphere.gd:30-31` (pinned only as constants by `verify_cosmos_m0:447`), there is
no ocean blend in the height path and no edit lock in `world_manager`. Separately, the
shipped #69 nearest-cell fill differs from §5.3's lower-numbered-edge fill rule — a
divergence that is invisible over water and visible over land, i.e. exactly the terrain
the user has been standing on. Three options:

- **(i) Implement §5.3 as locked** (small: one blend in the height path — it is already
  a pure function of d̂, worker-safe by the same argument as the latitude term — plus the
  edit-lock check; days, not weeks). Corners become open sea; M5a's discarded wedge is
  flat water behind the near field; **M5c disappears from the critical path**. Spawn
  stays on face 4's corner *region* (find_spawn scans outward and lands on the first
  coast beyond ~48 cells — the spawn constraint is honoured; the vertex itself becomes a
  sea the player can swim across, §5.3 item 4). This is the R1-locked answer and my
  recommendation.
- **(ii) Land corners (full M5c):** keep shaped terrain at the vertex and give the
  corner true physics: a geodesic motion remap around the vertex (the flat window cannot
  represent it — the player's diagonal crossing must re-home mid-step), a corner edit
  policy beyond the lock, and near-interactive rendering of three faces at once. This is
  the only genuinely research-grade piece of M5 — medium-large, and the web-perf risk
  concentrates here (three near volumes). Only buy it if the user explicitly wants
  walkable cube-corner summits.
- **(iii) Interim:** M5a+M5b with the #69 fill retained (unrendered by M5a, sea-or-echo
  visible only in the physics window's collider) — workable but leaves the corner as
  today's compromise; strictly dominated by (i).

The user's standing constraint ("do not move spawn to hide bugs") is honoured by (i):
nothing about the spawn *scan* changes, and the corner stops being a bug to hide —
it becomes the locked design, observable and gated.

## 5. Staging, size, risks

| Stage | Contents | Size (this project's milestone scale) | Ships behind |
|---|---|---|---|
| **§5.3 corner zone** (recommended first, independent) | ocean mask + edit lock + fill-rule alignment + gates | small — comparable to a fix-batch PR (#10) | worldgen constant flip |
| **M5a** | placement shader (home + 4 strips, wedge discard), precision pipeline, ground-truth + seam gates, far shader swap | ≈ one milestone — comparable to far-LOD (#36) or M4 (#65) | `M5_RENDER` toggle (bend restores byte-identically) |
| **M5b** | neighbour-face render charts (far-layer discipline, per-face uniforms), corner closure gate, handoff shrink | ≈ one milestone — comparable to M4 | same toggle + chart cap flags |
| **M5c** | only if land corners (option ii): geodesic corner motion, tri-chart near render, corner edit policy | medium-large, research-grade | — |

**Biggest risks, in order:**
1. **Web perf/memory of M5b charts** — bounded by construction if they reuse the far
   layer's tile/tri/draw caps (they are far-style meshes, not voxel volumes; the near
   field stays single). The gate is the existing never-OOM discipline + the live-demo
   non-negotiable. Mitigation: per-face chart budget and distance culling from day one.
2. **Shader precision at planet radius** — mitigated by camera-relative f64 uniforms
   (the bend already established the pattern); needs an explicit jitter gate.
3. **Per-vertex strip branching in GLES3/WebGL2** — 5-way branch on uniforms is
   coherent (whole chunks take one path except at strip boundaries); measure in M5a
   before committing M5b.
4. **Scope creep toward M5c** — pinned by making the §4 corner decision *before* M5a
   starts.

## 6. Where M5 was (and wasn't) previously sketched

M5 is *referenced* as the deferred corner refinement in `cosmos_chart.gd` (§4.3/§5.3
comments), COSMOS-CORNER-CANONICAL, and COSMOS-SEAM-METRIC's levers list ("M5 multichart
true-position render — large, web-risk"); the adjacent locked designs are TOPOLOGY §5.3
(corner zone) and §7.2 (B2 planet mesh, a future consumer of the same `world_point`).
No prior document designed M5 itself — this note is its first scoping; a full design ADR
precedes M5a implementation.
