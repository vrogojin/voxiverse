# COSMOS-FRAME-ORIENTATION — root cause of "every regeneration rotates the faces" and the pinned-orientation fix

Status: DESIGN (Fable, 2026-07-08). Companion to COSMOS-PLANET-TOPOLOGY (§3/§4),
COSMOS-SEAM-METRIC, COSMOS-CORNER-CANONICAL. Supersedes the Fix-A rationale in #71.

Scope: the frame-by-frame diagnosis of the "misaligned / rotating faces" symptom family
(tasks #68/#70/#71/#72), the verdict on Fix A (player yaw compensation, commit f798a38),
and the implementation plan for the unified orientation fix + headless gates.
Hard constraint honoured throughout: spawn stays on the polar face-4 cube corner.

---

## 0. Executive summary

**One root cause.** Scene space is *identified with* the current home face's lattice frame
(window `x,z` ≡ face `i,j` minus the floating origin). That frame's **orientation is
epoch-dependent**: every home-face flip re-bases the window onto the neighbour face, whose
index axes are a D4 rotation (0/90/180/270°) of the old face's axes at the shared edge.
Nothing in the engine ever compensates that rotation *structurally* — instead, every
consumer of scene space silently assumes the frame orientation is world-fixed. Each
consumer that holds that false assumption is one observed bug:

| Consumer assuming a world-fixed frame | Observed symptom |
|---|---|
| The player transform (pre-#71) | the literal 90° view snap on first crossing |
| Directional sub-voxel shapes (`shape_mesh` corner mapping, no fold rotation) — **bug #1, numerically confirmed** | "the whole face is generated in the wrong orientation; slopes are the tell"; heals when a strip becomes native |
| Retained scene elements at a flip: the **far `FarStaleCover`** (translation-only pin, `far_terrain.gd:202`), the M4 near cover (`module_world.gd:1142`, flag-off in prod), loose `VoxelBody` debris | **bug #2**: post-Fix-A, the entire on-screen world (which at the flip instant *is* the cover) snap-rotates by the edge D4 around the player — "EVERY regeneration rotates the faces and misaligns them" |
| The §5.3 corner quadrant (canonical *content*, smeared *placement*) | the rotated/smeared quadrant visible from the corner spawn (known, M5) |

**The flip is an isometry; the engine rebases with a translation.** §2 proves (integer-exact)
that the flip's window-frame change is `w_new = M·(w_old − w_p) + w_p` — the crossed edge's
D4 rotation `M` about the player's window cell `w_p`. Restreamed content is recomputed in the
new frame and lands correctly; every *retained* element is repositioned translation-only
(`cover.position = old_pos − new_pos`, `old_terrain.position += old_wrapper_pos − position`,
`_far.position/_module_world.position = −(i_org,0,j_org)`), i.e. correct **only when M = I**
(equatorial↔equatorial edges). Every edge of the polar spawn face 4 except SOUTH has M ≠ I.

**Fix A verdict: REVERT (subsumed).** Its math is correct and its gate passed, but it is a
per-consumer patch of a frame that keeps rotating. It fixed the player and thereby *unmasked*
the covers: before Fix A the stale cover stayed aligned with the un-rotated player while the
*incoming* content looked rotated ("regeneration rotates it"); after Fix A the incoming
content is aligned and the *cover* — everything on screen at the flip instant — visibly
spins by 90/180° ("MUCH WORSE: every regen rotates the faces"). Chasing the remaining
consumers one by one (option 1, §5.2) is whack-a-mole; the correct fix removes the rotation.

**The fix: pin the window orientation for the life of the session (§5).** This implements
the user's MASTER-FACE model (§5.0): the master is the **North-pole face 4** (normal +Z on
the +Z spin axis — also the spawn/home face), and the scene renders in the master's
orientation always; the home face becomes a streaming-origin device only. Concretely the
chart gains a persistent D4 orientation `M_win` (= the composed junction remaps from the
master along the travelled path; I at spawn) that accumulates the fold rotation at each
flip, applied at the (already centralised) window↔face-index conversion sites. Scene
orientation then never changes — flips and re-anchors are both pure translations of every
node, the existing translation-only cover/debris/node handling becomes *correct by
construction*, and Fix A is unnecessary. One adjustment is forced by topology (§5.0): a
*constant* per-face orientation is impossible (the junction graph has 90° holonomy around
every cube corner), so the master orientation is parallel-transported along the travelled
path rather than baked per face. Bounded: ~8–10 integer conversion sites, zero per-frame
cost, web-safe.

**Bug #1 shares the root and gets the same treatment (§6):** a directional shape's modifier
is *computed* in the true-face frame but *rendered* in the window frame; the fold's D4
Jacobian (which `worker_fold_column` already knows) must rotate the direction payload at the
fold boundary. Canonical (§8.2, true-face) direction is what gates and the edit overlay
store; the window render orientation is derived. The current seam/corner gates' raw-modifier
byte-equality is over-constrained and *pinned the bug*; they change to world-direction
equality (§8).

---

## 1. Frame inventory — who lives in which frame, and what happens on reanchor / flip

Notation: home face `A`, origin `org = (i_org, j_org)`, window coords `w = (x, z)`,
face ("raw") index `p = (i, j) = org + w` (today's convention), fold `g = fold(p)` to the
true global cell. The crossed edge's remap is the exact integer affine `p' = M·p + t`
(`cube_sphere.gd edge_remap/fold_cell`), `M ∈ C4` (pure rotation, det +1 on all 24 edges).

| Layer | Node/state | Frame today | On reanchor (Δ) | On flip (A→B, remap M,t) |
|---|---|---|---|---|
| Near voxel field (module) | `VoxelTerrain` under wrapper at `−(org)`; **voxel index = raw index p** | home-face raw-index frame | wrapper `−= Δ` (exact) | wrapper set to `−org_B`; **full restream** with new frozen `gen_face` → recomputed, correct |
| Near cover (M4 Stage 2, default OFF) | frozen old `VoxelTerrain` | **old** raw-index frame | rides wrapper | pinned by `+= old_wrapper_pos − position` — **translation only → off by M about player** |
| Far LOD | `FarTerrain` at `−(org)`; tile local coords = raw index | home-face raw-index frame | node `−= Δ` (exact) | `rebase_to(−org_B)`: live set cleared + rebuilt (correct); **cover** kept at `old_pos − new_pos` — **translation only → off by M about player** |
| Fallback streamer / ground collider | window-space geometry | window | `−= Δ` (exact) | hard restream / `_rebuild_window_indices` (correct) |
| Player | `CharacterBody3D` | window | subtracts Δ (exact) | position untouched (fixed point of the flip, sub-cell residue ≤ ~1.4 blocks); yaw+velocity rotated by Fix A (`player.gd:188-198`) |
| VoxelBody debris, any other retained Node3D (portal nodes, particles) | window transforms | window | not shifted?/shifted per owner | **untouched → off by M about player** |
| CosmosBend | camera-centred radial sagitta, global uniforms | rotation-invariant in XZ | unaffected | unaffected (bend is isotropic about the camera column — it can neither cause nor mask a rotation) |
| Edits/meta | global keys via `chart.to_global_key` | face-index (global) | invariant | invariant (unfolded into the window on read) |
| Worldgen content | `fold_cell_canonical` per column, frozen `gen_face` per epoch | true global (face,i,j) | invariant | invariant — **proven byte-identical across epochs** (#70 dump) |

Reading of the table: **content and keys are frame-independent (good); placement is
consistently correct for translations and consistently wrong for the rotation part of a
flip wherever anything is retained.** The re-anchor is a pure translation everywhere and
provably cannot rotate anything — the user's "reanchor changes it" observation is
attributable to bug #1 strips and cover churn coinciding with the walk (gate G-A pins this
with evidence, §8).

## 2. The flip isometry theorem (root cause of bug #2, exact)

Let the player stand at window cell `w_p`, `p_p = org_A + w_p`, crossing the edge with
remap `(M, t)`. `chart.flip` (cosmos_chart.gd:155-191) sets
`org_B = g_p − w_p` where `g_p = M·p_p + t`, keeping the player's window cell fixed.

For any physical cell `g` in the crossed strip / on face B, its old window position is
`w_old = p − org_A` with `g = M·p + t`; its new window position is

```
w_new = g − org_B = M·(org_A + w_old) + t − (M·(org_A + w_p) + t − w_p)
      = M·(w_old − w_p) + w_p                                            (★)
```

— an **exact integer rotation by M about the player's window cell**. (★) is what the
restream implements implicitly by recomputing indices. Therefore any retained element kept
at `w_old` (or repositioned by any pure translation) sits wrong by exactly the rotation
part of (★): displaced by `(I − M)·(w_old − w_p)` — zero at the player, growing linearly
with distance, 90/180/270° of angular error. That is:

- `far_terrain.gd:202` `cover.position = old_pos − new_pos` — preserves `w_old`; the
  comment "its original world spot" is only true when M = I. The bug-B fix (#54) that
  restricted the cover to old-home-face-interior tiles removed the *translation*
  inconsistency of edge-straddling tiles but kept the rotation error of the whole cover.
- `module_world.gd:1142` near-cover pin — same defect (flag-off in prod, so today the near
  field blanks-and-ramps instead; the far cover is the always-on retained element).
- Pre-Fix-A player yaw — the same M, observed as the 90° turn.

**Why "0 at the camera, grows with distance" fooled two investigations:** a rotation about
the camera and a metric shear are indistinguishable in a position-magnitude probe. (★)
makes the two separable: the rotation is *exactly* D4 and *exactly* about `w_p`.

**Why the user sees it on *every* regen, both directions:** at the flip instant everything
on screen is retained content (the far cover; pre-restream near). Pre-Fix-A: the camera
kept the old frame → retained content looked continuous, *fresh* content streamed in
rotated → "the face regenerates misaligned/aligned". Post-Fix-A: the camera is
counter-rotated into the new frame at the instant of the flip → the *retained* majority of
the screen snap-rotates by M around the player, then heals as aligned tiles replace it over
~2–12 s (`COVER_MAX_SECONDS`), re-triggering on every crossing → "EVERY regeneration
rotates the faces and misaligns them", exactly as reported. The two reports are the same
defect viewed from the two sides of Fix A.

## 3. Reconciling every observed symptom

1. *"Spawn face misaligned with neighbours; crossing regenerates it aligned"* — at the
   corner spawn 3 of 4 window quadrants are folded: every directional shape in them is
   rotated by the strip's D4 (bug #1, confirmed: error ≡ edge angle, control edge 0°→0),
   and the corner quadrant is the canonical smear (M5). Flipping onto a neighbour face
   makes the terrain under/ahead native → its shapes snap correct → read as "regenerated
   aligned". Heightfield *placement* was never wrong — the terrain *skin* (ubiquitous
   smoothing ramps + sharp slopes) was, which is why it read as "the whole face is rotated"
   while the raw content dump stayed byte-identical.
2. *The 90° turn on first crossing* — (★) applied to the one retained element nobody
   rotated: the player. Fixed by #71 for the player only.
3. *"Near AND far wrong on first generation"* — near: bug #1 skins; far: the corner-quadrant
   smear occupies a quarter of the horizon from the corner spawn, and beyond-edge far tiles
   carry no shape skins (heightmap-only) so far *placement* is correct — the perceived
   far-vs-near disagreement is the near skin rotating against the far silhouette.
4. *"Reanchor changes it too"* — no rotation mechanism exists on reanchor (pure −Δ
   everywhere, §1; it does not even restream). The likely reality: "walking far" from the
   corner-adjacent spawn crosses an edge within a few hundred cells, so the observed
   rotation event was a *flip in disguise*; the remainder is far-set re-evaluation churn +
   bug #1 strips entering view. G-A (§8) pins reanchor invariance headlessly so this stops
   being folklore.
5. *"MUCH WORSE after Fix A: every regen rotates near+far"* — §2, the unmasked covers +
   the per-flip re-rotation of which strips carry wrong skins.

## 4. Fix A: keep, modify, or revert?

**Revert, as part of this fix (not before).** Fix A is *correct in isolation* (right angle,
right sign, gate-verified) but it compensates exactly one consumer of a frame that still
rotates, and its presence converts the covers' latent placement error into the dominant
on-screen symptom. Under the pinned-orientation design (§5) the window axes never rotate,
so there is nothing to compensate: `chart.flip` returns yaw for no one; `player.gd:188-198`
and the `last_flip_yaw` plumbing revert to pre-f798a38. The D4 yaw computation itself moves
into the chart as the `M_win` accumulation step — the math survives, the patch does not.
(Do not revert Fix A alone ahead of the fix: that restores the 90° view snap.)

## 5. The fix for bug #2 — pin the window orientation (`M_win`)

### 5.0 The user's master-face model: adopted — with the one adjustment topology forces

The user's design steer: *faces connect at junctions with exactly one correct fit; a MASTER
face that never rotates defines the orientation of all other faces.* Restated: render in a
single canonical orientation anchored to a fixed master face; the home face becomes a
streaming/floating-origin device only. **This is the correct principle, and it is what this
design implements.** Two concretizations exist and only one is mathematically possible:

- **Master = the North-pole face = face 4.** The spin axis is +Z (`terrain_config.gd`
  latitude climate, φ = asin(d.z)); face 4's outward normal is `(0,0,+1)`
  (`cube_sphere.gd` axis table), so face 4's centre *is* the North pole — and face 4 is
  also `HOME_FACE`/spawn. Master, spawn face, and the user's observation point coincide:
  at spawn the scene is in the master orientation by definition, and under this fix it
  never leaves it.
- **A *constant* per-face orientation `O(f)` composed from the master via the junction
  remaps is impossible — the junction graph is not cycle-consistent.** Proof: the composed
  D4 along `4 →(WEST, 90°)→ 3 →(0°)→ 0` is 90°, but along the direct edge
  `4 →(SOUTH, 0°)→ 0` it is 0° — two paths to the same face disagree. In general the
  composition around any cube corner is that corner's 90° angular defect (8 corners × 90°
  = 720°, the discrete Gauss–Bonnet total curvature of the sphere); the D4 "connection"
  defined by the 24 edge remaps has non-zero holonomy, so *no* orientation assignment
  makes every junction rotation-free. Picking a canonical spanning tree from the master
  (5 tree edges) leaves the 7 non-tree edges carrying the mismatch: flipping across them
  snaps the newly native face by the holonomy D4 — **bug #2 reintroduced at 7 of 12
  edges** (today it is clean at only the 4 equatorial-belt edges; a tree buys 5).
  Rejected.
- **The unique continuous realization of "the master never rotates and no junction ever
  rotates" is parallel transport:** carry the master's orientation along the path the
  player actually travels, composing the junction D4 at each crossing. That is exactly
  the `M_win` of §5.1 — `M_win` *is* "the composed junction remaps from the master along
  the travelled path", with `M_win = I` at spawn on the master face. Every crossing of
  every edge is rotation-free; no regen event of any kind re-orients the scene; the price
  is the §5.1 holonomy note (a face revisited after a closed loop *around a cube corner*
  renders D4-rotated vs the previous visit — locally unobservable, the honest curvature
  of a sphere; the per-face-constant alternative would instead pay it as a visible snap
  at a seam, which is precisely the bug being fixed).

**Why the chart index-mapping (`M_win`), not a basis on the render nodes:** rotating the
near wrapper + far node by the master D4 would re-orient the *render* but break the
`scene == window` identity that the player controller, GroundCollider, DDA, snowfall, and
every analytic gameplay query assume (they convert positions to cells directly) — each
would need the inverse basis applied, with a per-flip rotation pivot, and any missed one
is a render/physics divergence (walk-on-what-you-see broken). Carrying the D4 in the
chart's window↔index mapping keeps `scene == window` true for everything, confines the
change to the ~10 already-centralised index-conversion sites (§5.3), and leaves gravity
(−Y), axis-aligned collider boxes, and the (isotropic, rotation-free) CosmosBend
untouched by construction. Same rendered result as the node-basis idea, strictly smaller
blast radius.

**Does the master frame subsume bug #1?** No — and it wouldn't under the node-basis
variant either. Bug #1 is a *within-window* frame mismatch (shape computed in the
TRUE-face frame, corner-mapped in window axes with no fold rotation); it exists for
folded strips whatever the window's absolute orientation is. It does share the machinery:
the §6 fold Jacobian is `J = M_strip · M_win`, so one D4-rotation helper and one GenCtx
field serve both, and they land in the same change.

**Rotation-vs-shear, settled.** The A→B transform of the same physical region across a
flip is the (★) map of §2: an exact integer *isometry* — a D4 rotation about the player's
window cell composed with nothing else. Inter-point distances and angles are preserved
exactly (D4 matrices are orthogonal; the fold tables are affine with det +1), so the
cross-epoch re-orientation is RIGID, not a shear — confirming the user's rotation model.
The §4.6 corner metric lie is a *separate, additive* residual: a non-isometric placement
error of the corner quadrant *within* one window, position-dependent, unchanged by this
fix (M5). The within-epoch determinism findings (face-explicit generation, deterministic
far meshes, rotation-free bend, no node basis anywhere) are all consistent with this: the
rotation is *implicit* in which face's lattice the window is identified with, so no
within-epoch probe or grep for explicit rotations could ever see it.

### 5.1 Design

Add to `CosmosChart` a persistent orientation `M_win ∈ C4` (2×2 integer D4 matrix, det +1;
spawn = I), redefining the window↔face-index bijection:

```
p = org + M_win · w          (window → raw home-face index; today M_win ≡ I)
w = M_win⁻¹ · (p − org)
```

- **Reanchor** (unchanged semantics): `org += M_win·Δ`; caller still subtracts Δ from
  window positions; node shifts stay pure translations. `M_win` untouched.
- **Flip**: crossing an edge with remap `(M_f, t_f)`:
  `M_win ← M_f · M_win`, `org ← g_p − M_win·w_p`, face ← b. By (★)-algebra the window
  coordinates of every physical cell are then **continuous across the flip** — the frame
  never rotates, so covers, debris, the player, and every retained node are correct with
  today's translation-only handling. Fix A deletes.
- **Node frames**: module wrapper and far node local coords become the *rotated* raw index
  `v = M_win⁻¹·p` (still exact integers), node position `−M_win⁻¹·org` — so within an epoch
  the reanchor remains a pure node translation (no restream), and a flip still restreams
  (as today) into the new epoch's `v`-frame.
- **Generator epoch**: freeze `gen_mwin` next to `gen_face` on each generator instance
  (COSMOS-AUDIT frozen-epoch discipline); the worker computes `p = gen_mwin·v` before
  `worker_fold_column(gen_face, p…)`. One 4-int multiply per column, in already-hot integer
  code — no measurable cost, no new shared mutable state.
- **Holonomy (accepted, documented)**: walking a closed loop around a cube corner
  accumulates a net 90° in `M_win` (the corner's angular defect). The scene stays locally
  continuous at every step — a face revisited after such a loop renders D4-rotated relative
  to the previous visit, which is unobservable without an absolute compass and is the
  correct parallel transport on a curved surface. Do not "fix" it later.

### 5.2 Why not per-element compensation (option 1)?

The alternative — keep the rotating frame, apply the (★) isometry `T` to every retained
element at each flip (cover basis+origin, near-cover pin, each VoxelBody, portal nodes,
particles, plus keep Fix A) — is smaller today but leaves the invariant false: every future
retained window-space object must remember to apply `T` or silently reintroduce this bug
(this class has now produced #70, #71, #72 across five cycles). It also keeps the scene's
absolute orientation churning, which multiplayer ghosts, a sun/skybox, or a compass would
each re-expose. The pinned orientation makes the false assumption true once, for everything,
forever, and turns the strongest possible gate (positional *equality* across a flip) from
unstatable into trivial. Chosen: **M_win**.

### 5.3 Conversion-site inventory (the entire blast radius of §5)

All places that convert window ↔ raw index today (each gets the one matrix application, most
via a single new chart helper `raw_of(x, z) -> Vector2i` / its inverse):

1. `cosmos_chart.gd` — `to_global_column`, `window_of_global`, `flip_needed`, `flip`,
   `reanchor` (org update), `world_point_of` (inherits), + new `M_win` state & accessor.
2. `world_manager.gd:447-496` — the analytic wrapper block (`height_at`, `column_profile`,
   `surface_modifier`, `surface_cap_modifier`, `snow_stack_at`, `slope_run_of`,
   `TreeGen.block_at`): replace raw `_chart.i_org + x` with `chart.raw_of(x, z)`.
   (These bypass the chart today — that bypass is precisely the kind of scatter §5.2 warns
   about; route them through the helper.)
3. `world_manager.gd:592` (fold gate) and `home_face_edge_lines` (:819-829) — edge lines
   become `M_win⁻¹`-mapped, still axis-aligned; `cosmos_border_overlay` consumes unchanged.
4. `world_manager.gd:902/916` + `maybe_reanchor` — node positions become `−M_win⁻¹·org`
   (helper on the chart: `node_origin() -> Vector3`).
5. `module_world.gd` generator (~:1656-1664, :1864) — freeze `gen_mwin`, apply at the fold
   entry; `arid_for_cell`/main-thread mirrors take the same conversion where they fold.
6. `far_mesh_builder.gd:25` — sample at `M_win·local` (the far node's frozen epoch matrix,
   passed into `begin_tile`); `far_terrain.gd` key-space is per-epoch (cleared at flip) so
   keys need no change; `_tile_fully_in_face` tests the *raw* footprint → convert.
7. `lattice_nav.gd` — audit its window/index conversions the same way (M3 utility).
7b. `per_voxel_environment.gd` (`_surface_h`/`_climate_w`) — did its own `i_org + x`
   conversion, found at #74 step-3 implementation (credit Opus; the original inventory
   wrongly listed environment as chart-routed): route through `chart.raw_of()` like the
   WM wrappers. Proof again that any conversion outside the chart is a latent 90° bug —
   keep it in the risk-grep set.
8. `player.gd:188-198` + `last_flip_yaw` plumbing — **delete** (Fix A revert).
9. Player continuous position at flip (optional exactness, recommended): with `M_win` the
   window position is continuous by construction — the current "keep `(wx,wz)`" rebase is
   already the identity on cells; keep the sub-cell fraction as-is (residue vanishes since
   the frame no longer rotates: `org` is chosen from the *same* fixed player cell).
10. `verify_cosmos_*` — §8.

Explicitly **untouched**: CosmosBend (isotropic), edits/meta (global keys route through the
chart), `fold_cell`/`fold_cell_canonical`/`edge_remap`/`unfold_to_window` (raw-index domain,
unchanged), collapse/DDA/ground collider (consume WM wrappers), climate/environment (chart
methods), spawn (`HOME_FACE = 4`, corner scan — stays, per the standing user constraint).

### 5.4 The spawn corner under `M_win` — "aren't there 4 faces at the corner?" (user question)

**The vertex is a 3-face vertex; the "4th face" the eye sees is the synthesized corner
wedge, not a face.** Verified from the axis tables (`cube_sphere.gd` `_axis_n/_axis_u/
_axis_v`): the spawn cell face-4 `(0,0)` has direction `d ∝ (+1, −1, +1)` — the cube vertex
shared by exactly the three faces whose normals are those components: face 0 (+X, the SOUTH
neighbour), face 3 (−Y, the WEST neighbour), face 4 (+Z, home/master). Three 90° face
corners meet there: 270° of physical surface angle vs 360° of flat window angle — a 90°
angular *deficit*, which is precisely the corner holonomy of §5.0/§5.1 (four faces would
give 360° = flat = no corner and no seam problem at all). The window around the spawn
therefore shows **four quadrants but only three faces**: `(+,+)` home 4, `(−,+)` WEST strip
→ face 3 (exact D4 fold), `(+,−)` SOUTH strip → face 0 (exact D4 fold), and the diagonal
`(−,−)` quadrant — out of range in BOTH axes, `fold_cell` face −1 — which is **not a fourth
face** but the stretch slack of flattening 270° into 360°: `fold_cell_canonical` (#69)
fills it with the nearest real cell of each column's physical direction, so it renders as a
smeared echo of the two neighbours near their shared edge. Not a flaw in `M_win` — it is
the already-known §4.6/§5.3 corner-zone residual (M5), and under this fix it becomes
*stable* (identical on every regen) instead of re-orienting.

**Circumnavigating the vertex needs only single-edge flips — the corner-quadrant refusal is
never in the way.** `chart.flip` refuses only when the *player's own column* is diagonal
(fold −1 → `{ok:false}`); `flip_needed`'s hysteresis is `FLIP_HYST = 64` cells. Walking
around the vertex at radius > 64 cells crosses three single edges in sequence (4→3, 3→0,
0→4); each flip composes its edge D4 into `M_win`, and the loop composes to the 90°
holonomy — exactly the G-B(c) gate. Walking around at radius ≤ 64 crosses no flip at all
(the whole loop stays inside the hysteresis band): `M_win` never changes, nothing rotates,
and the player simply traverses the two exact strips + the wedge smear. Entering the
diagonal quadrant *deeply* (past 64 on both axes) leaves `flip_needed` true with `flip`
refused each tick — play continues on the canonical-fold wedge content (render, collider,
and DDA all read the same columns, so walk-on-what-you-see holds); the moment the player
exits into a single-out strip, a normal edge flip fires. So there is **no path that
requires a diagonal flip**, `M_win` only ever accumulates well-defined single-edge D4s, and
the refusal is a benign hysteresis guard, not a trap. One gate is added to pin this
(G-F, §8).

**The wedge × `M_win` interaction (the one genuine implementation detail):** wedge columns
resolve content as `window w → p = org + M_win·w → fold_cell_canonical(face, p)` — `M_win`
applies *before* the fold, so content/keys inherit the fix with no special case. For
*directional shapes* in the wedge no single-edge `J` exists; the rule (refining §6.6) is:
**derive the strip part of `J` from the face the canonical fold actually resolved to** —
the WEST edge's D4 if it resolved to the west neighbour, the SOUTH edge's D4 for the south
neighbour, identity if clamped onto the home face (within the extended window `|a| ≤ 1.62 <
2`, the resolved face is always one of the vertex's three faces, so this is total and
deterministic per cell). The residual *placement* smear of the wedge remains the M5 metric
lie, unchanged and now stable.

**Standing exactly ON the vertex / window straddling 3 faces + wedge simultaneously:** that
is literally the spawn state and steady-state play today — every column folds independently
(strips exact, wedge canonical), `M_win` is a uniform pre-multiply, the flip guard needs
only the player's own column. No interaction, no unhandled case.

**"I still see face 2 and can go through it" (user report) — face 2 is NEVER rendered at
spawn; verified by exhaustive enumeration.** A faithful replication of the
`cube_sphere.gd` math (warp = tan(a·π/4), `face_of_dir` argmax, face-4 edge folds) swept
every raw column within ±4608 cells of the vertex (the true reach ≈ spawn-scan 512 +
R_FAR 3072 + tile snap, all ≪ n = 10016): the single-out strips resolve to **{0, 3}
only**, the canonical corner wedge resolves to **{0, 3} only** — zero face-2 hits,
including the exact diagonal and every vertex-adjacent cell; max overshoot |a| = 1.92,
under the 2.0 gnomonic fence. Analytically airtight: face 2 is +Y and needs d.y > 0
dominant, but every wedge direction has d.y = warp(a) < −1 < 0; the EAST strip (the only
route to face 2 from home 4) needs raw i ≥ 10016. What the user is seeing is the **wedge
quadrant itself**: a rendered *duplicate echo* of faces 0/3 border terrain filling the
diagonal quadrant — "an extra face-shaped region that should not exist" is a *correct
description* of it (the sphere has 270° of surface at the vertex; the flat window paints
360°, and the canonical fold fills the 90° of slack with stretched copies of the
neighbours). Since faces 4/3/0 visibly occupy the other three quadrants, deducing the
fourth "must be face 2" was reasonable — but it is not face 2; it is not any face.
"Can go through it": (a) beyond the near radius (128 blocks curved) everything visible is
far tiles — render-only, collision-free by LOD design (within 128 the wedge streams solid
near content, render == collision, canonical fold on both paths); (b) if observed just
after a border crossing, the misrotated stale cover (bug #2, §2) is precisely
walkable-through misplaced terrain — fixed by this design. Verdict: **no extra-face
render bug exists; nothing to fix beyond #74** — the wedge echo is the known §4.6/§5.3
M5 placement residual, and it becomes stable (not re-orienting per regen) once `M_win`
lands. Optional cosmetic lever if the echo bothers play before M5: suppress or extra-fog
far tiles whose footprint lies wholly inside the corner quadrant (render-only, bounded) —
at the cost of a fogged hole over ¼ of the spawn horizon; not recommended by default.

## 6. The fix for bug #1 — canonical direction vs render orientation

**Principle (the §8.2 separation):** a directional cell's *canonical* direction lives in its
TRUE face's frame (home-independent — this is what worldgen computes and what the overlay
stores); its *render/collision* orientation in the window is `J⁻¹·(canonical)`, where
`J = M_strip · M_win` is the cell's net window→true-face D4 Jacobian — `M_strip` the fold
matrix `worker_fold_column` already applies (I for native cells), `M_win` from §5.

Mechanically:

1. `worker_fold_column` (terrain_config.gd:1664) additionally records the net D4 `J` in the
   `GenCtx`/pcache (2×2 int, already computed as part of the fold — zero extra math for
   native cells).
2. A pure table-driven helper `ShapeCodec.rotate_modifier(modifier: int, d4: int) -> int`
   rotates a direction-carrying modifier payload by a D4 element: sharp-slope direction
   bits, smoothing corner-height quadruples (s00/s10/s11/s01 cyclic permutation),
   waterlogged twins via their dry shape; snow LAYER and all isotropic shapes are fixed
   points. Unit-tested exhaustively (all payloads × 4 rotations; rotate⁴ = id,
   rotate(a)∘rotate(b) = rotate(ab)).
3. Apply `rotate_modifier(mod, J⁻¹)` at every **window exit** — one *logical* rule, two
   physical apply-sites (CORRECTED at #74 step-5 review, credit Opus: the analytic path
   cannot carry `J` to a single TerrainConfig choke). TerrainConfig speaks **canonical**
   (true-face frame) everywhere; rotation happens where values leave for window-space
   consumers: (i) the **worker** buffer write, via the `J` in the GenCtx (frozen
   `gen_mwin` + the `M_strip` of the fold it just performed); (ii) the **analytic/WM
   boundary** — `cell_value_at`'s generated branch (`world_manager.gd:231` receives the
   *already-folded* true cell, so no raw index exists inside `generated_cell_global` to
   derive `M_strip` from; its rotation must live at WM, where the window cell — hence
   `J` via the chart — is in hand, pairing with the §6.4 overlay canonicalise at the
   same choke), plus the col_*/modifier wrapper exits (raw-p derivation inside
   TerrainConfig or WM-side — implementer's choice; every exit must be covered).
   `_active_mwin` mirrors `_active_face`: main-thread analytic only (workers read the
   frozen `gen_mwin` — the module_world.gd:1575 audit rule extends verbatim); set both
   in ONE setter with a (face, mwin) pair no-op guard; memos store canonical values and
   rotate after read (never cache a rotated value across epochs). C4 is abelian (all 24
   remaps det +1): represent `d4` as k∈{0..3}, compose = (k1+k2)%4, inverse = (4−k)%4.
   **Acceptance arbiter (non-negotiable):** the cross-path equality gate — probe cells
   in every strip + the wedge, both epochs: worker packed value == `cell_value_at`
   generated value == collider wrapper modifier, byte-equal. Walk-on-what-you-see holds
   because the gate, not an assumption, pins that every consumer reads the same window
   value.
4. Edit overlay: canonicalise on write (rotate placed directional modifiers by `J` into the
   true-face frame before storing under the global key), de-canonicalise on read (`J⁻¹` for
   the *current* window). Cheap: only direction-carrying materials pay the lookup. This is
   what makes a player-placed slope keep its physical direction across a future flip.
5. FAR LOD: no change (heightmap-only, no directional payload).
6. Corner quadrant (no single-edge `J` exists): derive the strip part of `J` from the face
   `fold_cell_canonical` actually resolved the cell to — that neighbour's edge D4, or
   identity if it clamped onto the home face (total and deterministic: within the extended
   window the resolved face is always one of the vertex's three faces — §5.4). Matches the
   canonical-fold placement convention; the residual *placement* smear is the §4.6/M5
   metric lie, out of scope here.

Note bugs #1 and #2 are the *same* root (uncompensated D4 between frames) at two different
boundaries: #2 at window↔window across epochs (fixed by making `M_win` explicit), #1 at
true-face↔window within an epoch (fixed by making `J` explicit). After both, every frame
change in the engine is carried by an explicit matrix, never by an assumption.

## 7. Numbered implementation plan (for Opus)

Order matters — each step lands with its gate green before the next.

1. **`ShapeCodec.rotate_modifier` + exhaustive unit gate** (pure, no consumers yet).
   Extend `verify_feature`/new `verify_shape_rot` with the group-law asserts (§6.2).
2. **Chart `M_win`** (§5.1/§5.3 items 1, 9): state, `raw_of/window_of` helpers,
   reanchor/flip accumulation, `node_origin()`. Keep `M_win = I` behaviour byte-identical
   (it is, by construction — I is the identity in every formula). Extend `verify_cosmos_m2`
   with M-algebra property tests (flip-loop holonomy = corner defect; flip continuity (★)
   becomes window-coordinate *equality*).
3. **Consumers of the chart frame** (§5.3 items 2-7): WM wrappers, node origins, generator
   `gen_mwin`, far sampling, border overlay lines, lattice_nav. After this step a flip is a
   pure translation of every node.
4. **Revert Fix A** (§5.3 item 8): `player.gd:188-198`, `last_flip_yaw` plumbing,
   `chart.flip`'s yaw return (keep the D4 extraction — it feeds the M accumulation).
   Retire/rewrite `verify_cosmos_turn` per §8 G-C.
5. **Bug #1**: `J` in GenCtx, the single rotate point in TerrainConfig, overlay
   canonicalise/de-canonicalise (§6.3/6.4). Include the corner-wedge `J` rule (§6.6/§5.4:
   strip D4 of the face `fold_cell_canonical` resolved to; identity when clamped home).
6. **Gates** (§8): new `verify_cosmos_frame` (G-A/G-B/G-C **and the G-F corner-quadrant
   traversal**); rewrite the raw-byte-equality asserts in `verify_cosmos_seam`/
   `verify_cosmos_corner` to canonical + world-direction equality.
7. **Covers**: no code change needed (their translation pinning is now correct); *add* the
   G-B cover-placement assert so a regression is loud. Delete the now-misleading
   "original world spot" comments and re-comment with the §5 invariant.
8. Docs: update COSMOS-PLANET-TOPOLOGY §4.5 (flip = translation under `M_win`),
   COSMOS-SEAM-METRIC (rotation-vs-shear indistinguishability note → resolved),
   COSMOS-CORNER-CANONICAL (gate change), memory note.

Estimated blast radius: ~10 files, all integer index math at existing conversion points;
no per-frame additions; no shader/render-pipeline changes; web export unaffected
(no threading/memory behaviour changes; the frozen-epoch race discipline is preserved by
freezing `gen_mwin` exactly like `gen_face`).

## 8. Headless gates (what would have caught this)

All curved-mode, headless, spawn kept on the face-4 corner; run against the module path
(and the fallback where applicable).

- **G-A: reanchor world-continuity.** Build near+far around the player; record scene
  positions (node-resolved) of a probe set of *physical* cells (near voxels incl. a firing
  slope, far tile origins) + `world_point_of`. Force a reanchor. Assert every scene
  position shifted by exactly −Δ, `M_win` unchanged, all cell values (incl. modifiers)
  byte-unchanged. Pins symptom 4 forever.
- **G-B: flip world-continuity (the big one).** Same probe set; force a WEST flip off face
  4 (90°, the sign-sensitive edge), also NORTH (180°) and SOUTH (0° control). Assert:
  (a) every probe physical cell's window position after the flip **equals** its position
  before (frame equality — impossible to state before `M_win`, trivial after);
  (b) the far cover tiles' world transforms equal both their pre-flip transforms *and* the
  new frame's placement of the same tiles (they now coincide);
  (c) `M_win` accumulated the crossed edge's matrix; a 3-flip corner loop yields the 90°
  holonomy and per-step continuity still holds;
  (d) a probe `VoxelBody`'s world transform is unchanged across the flip.
- **G-C: view-ray continuity without compensation.** Cast the player's forward ray to a
  global cell; flip; assert the *unmodified* yaw's ray hits the same global cell
  (replaces `verify_cosmos_turn`, which pinned the compensation that must now be absent).
- **G-D: directional-shape world direction.** For a firing slope on each face-4 neighbour
  reached through the fold: rendered downhill direction in scene space == the true-face
  downhill mapped through `J⁻¹` (all four edges; the 0° edge as control). Assert equality
  across epochs (home 4 vs home 3) of the *world* direction — and assert the raw modifier
  *differs* by exactly `J` between epochs where `J` differs, the inversion of the old
  byte-equality gate that masked bug #1.
- **G-E (regression): seam/corner content gates** keep their content asserts but compare
  *canonical* (true-face) values; window-frame comparisons go through `rotate_modifier`.
- **G-F: corner-quadrant traversal (§5.4).** Drive the player window position diagonally
  past the vertex into the `(−,−)` quadrant beyond `FLIP_HYST` on both axes: assert
  `flip_needed` is true, `chart.flip` returns `{ok:false}` every tick, `M_win`/`org`/node
  positions are NOT mutated, and the wedge columns' render value == collider value ==
  `cell_value_at` (walk-on-what-you-see inside the wedge). Then exit through a single-out
  strip: assert a normal edge flip fires, `M_win` composes that single edge's D4 only, and
  G-B's position-equality holds across it. Also assert a directional shape resolved *into*
  the wedge uses the `J` of its canonically-resolved face (§6.6) on both render paths.
  Finally, the **face-set assert** (pins the user's "extra face" worry forever): enumerate
  the resolved face of every column the near window + far tiles reach from spawn — the set
  must be exactly `{home, its two vertex neighbours}` = {4, 3, 0}; face 2/1/5 appearing is
  a fail (§5.4 enumeration, zero face-2 hits over ±4608 cells).

Confirming measurement for §2 (cheap, run first if desired): build one far ring-0 tile,
force a 90° flip, compare the cover tile's world transform with the new-frame placement of
the same global tile — expected today: differs by exactly the edge D4 about the player's
window cell; after step 3: identical.

## 9. Risks, and what this does NOT fix

- **Biggest risk: a missed conversion site.** Any window↔raw conversion not routed through
  the chart helper renders 90°-rotated content after the first flip — the same *symptom*
  class this fixes. Mitigations: the §5.3 inventory is the grep-list (`i_org +`,
  `j_org +` outside the chart must be zero after step 3); G-B's equality asserts make a
  miss loud on the first gated flip, not five user cycles later.
- **Overlay modifier canonicalisation** touches the packed-cell hot path; keep it gated on
  direction-carrying materials and covered by G-D/G-E plus `verify_feature`'s break/place
  loop.
- **Holonomy** (§5.1) is correct-by-design, not a bug; documented so nobody "fixes" it.
- **Not fixed here (M5, known, accepted for now):** the §4.6 corner metric lie — the
  ~30° angular shear / smeared placement of the corner quadrant visible from the corner
  spawn, and its far-LOD counterpart. After this fix that residue is *stable* (it no longer
  changes per regen) and is the honest remaining imperfection at the deliberately-worst
  spawn point. Spawn stays on the corner per the standing constraint. A *bounded* upgrade
  of the wedge FILL (short of M5) exists — see §10.

## 10. Future option: the wedge fill — "natural continuation" short of M5

User goal (post-#74, separate task): *the terrain generator should be aware of the wedge
and naturally continue the terrain across it*, instead of the current #69 nearest-cell
echo. Analysis of the bounded options.

**Reframing what the wedge shows (sharpens §5.4).** The wedge's directions are not
fabricated: as `(a, b)` sweep from the vertex diagonal toward the ±2 fence, `d̂` sweeps a
*real lune of the sphere* — from the vertex out across the zone straddling the far 0↔3
edge. Near the vertex that terrain is also visible at the tips of the two strips
(the local *duplication* the user sees); farther out it is terrain not otherwise shown.
The sin of today's fill is therefore not *what* it shows but *how*: `fold_cell_canonical`
**integer-rounds** each wedge column to its nearest real cell (`dir_to_face_cell` →
`roundi`), so many window columns collapse onto one real cell — producing the plateau/
striping aliasing ("the geometry got crazy"), on top of the unavoidable §4.6 angular
compression. The truly-continuous fix (render the real 270° corner, no excess window)
remains M5 multichart. But a bounded de-aliasing exists:

**(a) Continuous-direction fill — RECOMMENDED.** For double-out columns only, evaluate
the *continuous* fields at the raw gnomonic direction `d̂ = face_cell_to_dir(home, i, j)`
directly (the function already accepts float indices), instead of the canonical cell's
rounded direction. `_curved_profile` (terrain_config.gd:582) is already a **pure function
of d̂** — heights, continent, mountain factor, humidity, latitude temperature, and the
biome all derive from noise at `d̂·R` and `d.z` — so this is a mechanical split into a
`_profile_of_dir(d̂)` core + the existing per-cell wrapper. Integer-keyed *features*
(strata/ore/tree/emitted-shape hashing) **keep** the #69 canonical cell — they need an
integer identity, and the nearest real cell is the only home-independent one.
  - **§8.2-clean:** content becomes a pure function of position (`d̂`) — the *same*
    home-independence #69 restored, achieved continuously instead of by rounding. Two
    epochs' wedges at the same vertex sample identical `d̂` → identical content.
  - **Bounded + web-safe:** worldgen-only (~terrain_config split + the double-out branch
    of the fold path; far tiles inherit via the same profile), same noise cost as today
    (the canonical path also computes a direction), zero per-frame cost, pure f64 +
    frozen tables → worker-safe.
  - **No interaction** with #74 `M_win` (directions are orientation-free), and
    render == collision == far by construction (all read the same profile).
  - **What it looks like:** the striping/cloned-plateau interior becomes a smooth
    heightfield that reads as terrain wrapping the corner, angularly compressed —
    "naturally continued" in exactly the user's sense. The wedge↔strip *boundary* keeps
    today's §4.6 kink (rigid strip fold vs gnomonic extension diverge with distance from
    the vertex) — not a new seam, the existing one.
  - **Optional boundary blend** (the useful part of option (c)): over a band of ~20% of
    the wedge angle at each boundary, lerp the height/climate scalars toward the
    adjacent strip's rigid-fold extension so the kink seam fades. Scalars blend cleanly;
    features stay on the canonical cell. Cheap; do it only if the seam is visible in play.
- **(b) Blend the two neighbour faces barycentrically across the wedge — REJECTED:**
  averaging the *content* of two different faces manufactures terrain that exists nowhere
  (ghost blending, mushy ridges) and is strictly worse than sampling real terrain along
  real directions, at the same cost.
- **(c) Keep nearest-cell, smooth only the boundary — INSUFFICIENT ALONE:** leaves the
  interior striping/echo, which is the complaint.

**Honest limits (say this to the user):** (a) is a *fill* upgrade, not geometry. The
angular compression (~25% of the window angle carries re-projected terrain), the metric
placement lie, and the wedge's synthetic edit/physics identity (edits key to the nearest
real cell; #69's deferred edit policy) all remain until M5. What (a) buys is that the
wedge stops looking broken (no duplication banding, no plateaus) and reads as a smooth,
slightly-stretched continuation — likely enough for play at the deliberately-worst spawn.
**Interaction with the §6.6 wedge-J rule:** smoothing ramps computed from *window-local*
height differences become self-consistent automatically under (a); features lifted from
the true-face frame still use the resolved-face `J`. **Rough size:** one focused task
(~150–300 LOC + gates: wedge interior height-delta continuity between adjacent columns,
cross-epoch wedge determinism at equal `d̂`, blend-band monotonicity, and the existing
corner gates staying green). Recommendation: offer the user *accept-echo-until-M5* vs
*bounded (a) now* — (a) is genuinely worth it if M5 is more than a milestone away.
