# COSMOS — Tasks #72 (far terrain below near blocks) + #73 (orbit/de-orbit facet misalignment): Root Cause, Served-PCK Audit, Residual Fix

Status: DESIGN (no code). Author: Fable (architecture), 2026-08-15.
Worktree: `/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats` (the DEPLOY worktree — its
`build/web/index.pck` is the served artifact; all live-flag claims below are dumped from THAT pck,
per the #131 lesson that the main checkout's pck is stale).

Scope: the two oldest open far-render tasks, both filed ~2026-07-2x at the de-orbit milestone,
**before** the datum/coverage/frame fix families shipped. This doc (1) maps each to its true
mechanism with current file:line, (2) proves from the served pck which parts are already fixed
live, (3) designs a byte-off fix for the one real residual, (4) gives the gate + live A/B plan.

**Executive verdict (details in §1/§2):**

| task | historical mechanism | status live | residual |
|---|---|---|---|
| #72 far-too-low | far-ring covered-branch envelope-min − ~11.7 sink visible where near mesh never reached (12–40 blk trench) | **FIXED** by the shipped coverage chain (§1.2, pck-verified) | **REAL, bounded, deliberate**: the FP_SMOOTH_V2_NEARFILL 6-block uniform sink is the visible skin on relief beyond the applied radius (§1.3) → fix FP_V2_NEARFILL_UNSINK (§3) |
| #73 facet misalign | per-facet PLANE datum vs sphere (∝R inter-facet step) + 4 frame-desync sub-bugs | **structural classes FIXED** — every known sub-mechanism has a shipped flag, all ON in the served pck (§2) | no *structural* residual possible (§2.1); the un-excluded class is a RUNTIME pose-desync transient (C1–C5 triage, §2.2) — needs one reproducing frame before closing |

Shared cause? **Historically yes, currently no.** Both descend from the one original sin — each
facet rendering on its own PLANE while the true surface is the sphere (the ∝R datum step) — which
FS1/FS2′ closed. #72's *current* residual is not datum at all: it is the deliberate no-protrusion
sink. #73 has no current residual. They are NOT one bug today.

---

## 0. Served-pck evidence (the live flag set)

Dumped from this worktree's `build/web/index.pck` via `ProjectSettings.load_resource_pack` +
`get_script_constant_map` (custom editor headless; `pck_loaded=true`, `const_count=542` — the
non-stale count). Source defaults are all `false` (byte-off; e.g. `FP_DATUM_BAKE := false`
`cube_sphere.gd:393`); the deploy cheat bakes them on at export. Live values that matter here:

```
FP_DATUM_BAKE=true          FP_RADIAL_DATUM=false        FP_SHELL_WELD=true
FP_FARRING_FULL_COVER=true  FP_FARRING_UNCOVERED_TRUE=true
FP_FARRING_APPLIED_COVER=true  FP_APPLIED_PROBE_SLAB=true
FP_APPLIED_VIEW_BAND=true   FP_APPLIED_PROBE_CALM=true   APPLIED_PROBE_MAX=112
FP_SMOOTH_V2=true           FP_SMOOTH_V2_NEARFILL=true   V2_NEARFILL_SINK=6.0
FP_BLOCKY_FARRING=true      FP_ENV_ALL=true              BACKSTOP_SINK=6.0  BACKSTOP_CELLS=16
FP_FIXED_FRAME=true         FP_DESCENT_FACET_RESYNC=true FP_UPVECTOR_FACET_HEAL=true
FP_QUERY_FRAME_GUARD=true   FP_TWIST_FRAME_AWARE=true    FACET_TWIST=false
FP_NB_FULLRES=true  FP_NB_WELD=true  FP_FT_FRAME_WELD=true  FP_ORBIT_RELIEF=true
FP_SMOOTH_RIM=false  FP_FAR_SMOOTH=false  FP_BLOCK_LOD=false  FP_BLOCK_LOD_ORBIT=false
FACETED=true (terrain_config — the deploy-cheat flip, confirmed served)
```

## 1. Task #72 — "far terrain rendered too LOW, below the near blocks"

### 1.1 The one height contract (why the DATUM class is closed for ground tiers)

Under live `FP_DATUM_BAKE` the near mesh is lifted onto the sphere: per-vertex `y += s(fid,x,z)`
in the C++ mesher (patch 0010 `VoxelMesherBlocky.set_facet_datum_bake`, wired at
`module_world.gd:1873-1875` and `:1910-1911` from `FacetAtlas.datum_bake_params`,
`facet_atlas.gd:492-504`; the continuous solve is `datum_lift`, `facet_atlas.gd:471-486`).
`FP_RADIAL_DATUM=false` live, so there is no integer re-index on top (no double-lift).

Every far GROUND tier emits **radially onto the same sphere** — not on the facet plane:

- far-ring welded chords: `_weld_place(d, g)` — absolute, radial, from SHARED corner dirs
  (`facet_far_ring.gd:3870`, `:3947`; FS1 weld path `:3716-3721` via
  `FacetAtlas.facet_corner_dirs`, `facet_atlas.gd:425-436`);
- FacetSmoothV2 tiles: the native bake's own canon-dir **radial** placement
  (`facet_smooth_v2.gd:51-52`, consumed at `:82-94`);
- FacetOrbitRelief: `pos[k2] = d * (r_datum + relief)` (`facet_orbit_relief.gd:250`);
- skin tier: explicitly adds `datum_lift` before the placement map (`facet_skin_tier.gd:557-561`).

A radial point `d̂·(R+g)` and the lifted near vertex `p0+(g+s)·n̂` differ by ≤ ~0.03 blocks
vertically at g=64 (n̂-vs-d̂ half-facet angle ≤ 1.9°): the tiers agree on ONE surface. The
datum-omission class that bit far TREES (#131 — anchored via `lattice_to_world64` *without* the
lift, ±5.5 blk) does **not** apply to any ground tier, and the tree instance is itself fixed live
(`FP_FT_FRAME_WELD=true` in the pck). #72 is NOT a datum bug in the current code.

### 1.2 The historical mechanism — and the shipped chain that closed it

As filed (July, pre-`FP_FARRING_UNCOVERED_TRUE`), the far ring drew its dense backstop in the
covered regime — min-envelope heights minus `TierPlace.backstop_sink()` =
`max(ENV_EPS_G, ENV_ALL_EPS_FRAC·cell) ≈ 11.7` blocks at R=6371 (`tier_place.gd:108-114`, `:56`,
cell = 417/16 per `BACKSTOP_CELLS`, `cube_sphere.gd:334`) — across an annulus the near mesh never
actually reached. That is exactly "far terrain below the near blocks, near blocks floating above."
It was re-root-caused and fixed in stages, all live in the served pck:

1. `FP_FARRING_UNCOVERED_TRUE` — TRUE chord outside the streamed ellipsoid + 24
   (`_uncovered`, `facet_far_ring.gd:3611-3625`);
2. `FP_FARRING_APPLIED_COVER` (#89) — the three-zone law: sunk-covered territory shrinks to the
   PROBED applied radius; the gap annulus renders at TRUE − `ENV_EPS_G` (1.5)
   (`_blend_uncovered`, `facet_far_ring.gd:3672-3693`, zone-B emit `:3690`;
   `_applied_covered` `:3639-3652`; ladder `:1834-1916`, max 112 `cube_sphere.gd:1932`);
3. `FP_APPLIED_PROBE_SLAB` (#113) — un-killed the dead ladder (probe clamped to the loadable
   slab); `FP_APPLIED_VIEW_BAND` (#117) — height-banded zone C (`:3643-3644`, band snapshot
   `:1871`); `FP_APPLIED_PROBE_CALM` (#123) — churn calm. Live telemetry `sh_applied_r`
   (`facet_far_ring.gd:3323`) confirmed 0→96 on the live site after #117.

**Verdict: the filed #72 is fixed live by this chain.**

### 1.3 The real remaining residual (what a user can still see)

In the annulus between the applied radius (≤112) and the streamed+24 boundary, the visible far
skin is `max(` backstop zone-B, V2 near-fill `)` per point:

- backstop zone-B = TRUE − 1.5, but 26-block cells drawn flat at the corner-MIN under
  `FP_BLOCKY_FARRING` (`cube_sphere.gd:610`; mixed-cell MIN law documented at
  `facet_far_ring.gd:3658-3660`) — on relief a cell top dips well below TRUE at its up-slope
  corners;
- the V2 near-fill tile (hop ≤ 1) = TRUE − **6.0** uniformly: `V2_NEARFILL_SINK`
  (`cube_sphere.gd:1722`), applied per-tile at `facet_smooth_v2.gd:537` and subtracted radially
  at `:92-93` (slot sink resolved at `:586`).

On flat ground the backstop's −1.5 wins → sub-2-block step, invisible. **On relief the corner-MIN
backstop falls away and the smooth V2 tile at TRUE − 6 becomes the visible surface: a ~6-block
sunk skirt around the near bubble, near blocks standing proud above it.** That is #72's phrasing,
alive today as a *deliberate* no-protrusion sink (the tile must ride under near blocks wherever
near mesh exists — never-see-through outranks). Deliberate, but 6 blocks is over-conservative in
the zone where the near mesh provably is NOT: the same argument that produced the backstop's
three-zone law applies verbatim to V2's near-fill and was never ported there.

## 2. Task #73 — "orbit/de-orbit facet misalignment (tilted/offset facets)"

Filed before any of the frame/datum family existed. The symptom decomposes into five mechanisms,
each root-caused later under its own task, each with a shipped flag — **all ON in the served pck**:

| sub-mechanism | fix (live) | where |
|---|---|---|
| inter-facet ∝R plane-datum step in the far shell (facets meet at cliffs/offsets from orbit) | FS1 `FP_SHELL_WELD` — radial emit from SHARED corner dirs; adjacent facets weld bit-identically | `facet_far_ring.gd:3716-3721`, `facet_atlas.gd:425-436`, const `cube_sphere.gd:362` |
| near-mesh datum steps at seams | FS2′ `FP_DATUM_BAKE` (near lift onto the sphere) | §1.1 citations; const `cube_sphere.gd:393` |
| crossing re-place transform churn (PlanetRoot re-placing mesh mid-descent) | `FP_FIXED_FRAME` — set_active's re-place is identity; the ring pins at (identity − anchor) | `facet_far_ring.gd:52-53`, `:668-670`, const `cube_sphere.gd:2328` |
| descent facet/pose desync (stale fid vs pose during de-orbit) | `FP_DESCENT_FACET_RESYNC` + `FP_QUERY_FRAME_GUARD` | consts `cube_sphere.gd:3462`, `:3478` |
| post-de-orbit up-vector hysteresis-strip tilt (canted horizon read as "tilted facets") | `FP_UPVECTOR_FACET_HEAL` (#91) | const `cube_sphere.gd:3555` |

Neighbour-facet placement (#104, `FP_NB_FULLRES`/`FP_NB_WELD`) and the far-tree world-axis basis
(#131, `FP_FT_FRAME_WELD`) closed the same *visual* class for near-neighbour terrain and trees —
both live.

### 2.1 Why no per-facet relative tilt is possible in the current far stack

All far tiers are children of the ONE ring node and share its placement transform
(`facet_smooth_v2.gd:407-409`, `facet_orbit_relief.gd:495`); the merged meshes are in ABSOLUTE
planet coords (`facet_far_ring.gd:5-14`, `:665-667`). A single rigid transform cannot express a
*relative* tilt between facets; per-facet offsets would have to come from emitted coords — which
are welded radially from shared corner dirs (FS1). `FACET_TWIST=false` live (`cube_sphere.gd:49`)
with `FP_TWIST_FRAME_AWARE=true` (`:3328`), so no twist term exists either.

### 2.2 Verdict — structural classes closed; the runtime class needs a repro before closing

Every *structural* mechanism (emitted coords, per-facet planes, placement transforms, twist) is
excluded by §2.1 + the shipped-flag table. What this audit **cannot** exclude headlessly is the
**runtime pose-desync transient** class — the C1–C5 triage already circulated for this task
(frozen-relief vs live-shell registration skew; V2 hop-annulus lag on descent; a stale
active-fid far-tier consumer; a frame-basis/datum twin at cube-face folds — this one IS excluded
for ground tiers by §1.1, it was the tree/structure bug; f32 jitter at altitude). Every
historical orbit misalignment turned out to be runtime desync, and `verify_facet_seams.gd`-style
static weld gates never caught one. **Therefore: build nothing for #73 until one reproducing
frame + telemetry window exists; the discriminating gate is a `verify_spacefly.gd`-style
scripted de-orbit flight asserting cross-tier registration per frame, not a static weld check.**
If no repro appears in the §3.4(2) confirmation run, close as fixed-by the table above.

Sharpening C1 against §2.1: FacetOrbitRelief cannot desync from the shell *statically* — its one
frozen mesh (`facet_orbit_relief.gd:437`) and the shell's emit are both absolute coords under the
ONE ring transform. The only C1-shaped window left is *re-anchor timing*: if PlanetRoot applies a
fixed-frame re-anchor on frame N and the ring's `(identity − _anchor_offset)` pin
(`facet_far_ring.gd:52-53`) updates on N+1, the WHOLE far stack skews against the NEAR field for
exactly one frame at re-anchor events — a far-vs-near one-frame offset, never facet-vs-facet
within the far stack. That is the discriminator the scripted flight should log (re-anchor event
timestamps vs the frame the misalignment is captured on). Note re-anchors CLUSTER during
descent (anchor events track altitude bands), so a per-frame skew at each event is exactly
what a player reports as "facets misaligned falling from orbit" — capture the frame PAIR
N/N+1 around every re-anchor. If the misalignment only ever lives in single frames adjacent
to re-anchors, the fix is ORDERING (apply the ring's pin in the same frame/callback as the
PlanetRoot re-anchor, before render) — a ~5-line fix, no geometry change.

### 2.3 Honest bound on what is known to remain

A crossing's deferred re-emit leaves the just-left/just-entered facet quads + a thin terminator
band stale for ≤1–2 frames (`facet_far_ring.gd:663-693`) — under `FP_FIXED_FRAME` there is no
transform jump at all, so this is a colour/role staleness, not a tilt. Cosmetic, bounded,
accepted.

---

## 3. RESIDUAL FIX (#72) — `FP_V2_NEARFILL_UNSINK`: vertex-shader zone un-sink for the V2 near-fill

New `const FP_V2_NEARFILL_UNSINK := false` in `godot/src/cosmos/cube_sphere.gd`. Effective only
with `FP_SMOOTH_V2_NEARFILL` and `TierPlace.applied_cover_on()` (it refines both, replaces
neither). Default off ⇒ byte-identical (no mesh, material, or emit change).

### 3.1 Design: move the zone decision into the material, not the mesh

Rebuilding V2 tiles per ladder step would re-tile up to the whole hop≤1 set on every 16-block
walk — the exact churn class CALM exists to kill. Instead: the near-fill tiles' geometry stays
EXACTLY as shipped (uniformly sunk 6.0, byte-identical arrays), and a flag-gated variant of V2's
existing spatial material (`facet_smooth_v2.gd:306-311` region) un-sinks per-vertex in the VERTEX
shader:

```
p_true   = p + normalize(p) * u_sink            // recover the TRUE radial position (u_sink = 6.0)
zoneC    = applied_covered(p_true)              // same ellipsoid test as facet_far_ring.gd:3639-3652,
                                                // uniforms: u_col, u_applied_r, u_params(r,O,H), u_band_top
true_h   = length(p_true) - u_R                 // lattice-height proxy for the view-band gate (:3643)
VERTEX   = zoneC ? p : (p_true - normalize(p_true) * u_eps)   // u_eps = TierPlace.ENV_EPS_G (1.5)
```

- Zone C (inside the applied ellipsoid, below band top): keep the shipped sunk position — hidden
  under real near mesh, no-protrusion preserved verbatim.
- Otherwise: TRUE − 1.5 — the same equal-altitude-with-z-guard law the backstop's zone B already
  uses (`facet_far_ring.gd:3690`). The visible skirt collapses 6.0 → 1.5 blocks.
- Uniforms are set on MAIN each cadence tick from the SAME live sources the ring already
  maintains: `_applied_r` + band top (`facet_far_ring.gd:132-140`, `:1871`) and the player column
  — no new probes, no rebuilds, hysteresis inherited from the ladder (grow 1 step/tick, shrink
  instant). `applied_r = 0` (degraded/no-module) ⇒ whole tile un-sinks to TRUE − 1.5 — equal-
  altitude far, strictly better than a 6-block trench, never see-through *under* terrain.
- gl_compat-safe: a few vertex ALU ops + 4 uniforms; no textures, no derivatives, no discard.
  Web/GLES3 vertex stage handles this trivially.
- Physics untouched (V2 is render-only); near-fill tiles only (hop ≤ 1 slots, `:537`) — hop ≥ 2
  tiles have sink 0.0 and keep the shipped material.

Protrusion honesty: in zone B the tile can transiently coexist with a near block landing during
the probe window — at TRUE − 1.5 it stays a block *under* the block top, same accepted transient
as backstop zone B (COSMOS-NEAR-FAR-HEIGHT-DESIGN.md §2.3 tolerance, unchanged). The z-guard is
load-bearing: zone B emits TRUE − `ENV_EPS_G`, never TRUE − 0.

Composition caveat (uniform vs frozen snapshot — from architecture review): the shader's
uniforms update per FRAME while the backstop geometry updates per REBUILD (`_async_applied_r`
frozen at dispatch, `facet_far_ring.gd:2104`). At a ladder step the V2 tile therefore flips
zones one-to-many frames BEFORE the backstop re-emit lands. Both states are valid ground under
the §2.3 tolerance, but the mismatch must be *proven* bounded, not assumed synchronized —
G-FH-UNSINK below asserts it closes within one rebuild.

### 3.2 Never-OOM ledger

4 uniforms + one extra ShaderMaterial instance (shared by all near-fill slots): ≤ ~2 KB resident,
zero per-frame allocation, zero new arrays, zero rebuild churn.

### 3.3 Gates (headless; flags forced via function/material params, no sed)

Extend `godot/src/tools/verify_near_far_height.gd` (existing G-NFH suite, `:13-26`):

- **G-FH-DATUM** (pins §1.1 for all ground tiers): at sample cells on two adjacent facets AND
  across a cube-face fold, assert |far-tier emitted node height − (near `cell_y +
  FacetAtlas.datum_lift`)| ≤ 0.15 blk for: far-ring `_btrue_cache` nodes, V2 `build_tile` pos
  (sink forced 0), `FacetOrbitRelief` nodes, skin `_lattice_world`. (CPU-side mirror of the
  shader's `p_true` recovery proves the un-sink target is the near surface.)
- **G-FH-UNSINK**: drive the shader law's CPU mirror (a static helper shared with the gate) over
  a relief fixture with forced (col, applied_r=96, params, band): every zone-B vertex lands in
  [TRUE−1.6, TRUE−1.4]; every zone-C vertex byte-equal to the shipped sunk position; applied_r=0
  ⇒ all-B. Snapshot-desync bound: step the ladder one notch with the backstop re-emit
  artificially held — assert the V2-vs-backstop zone disagreement set is exactly the stepped
  annulus and empties after ONE `_dispatch_async_rebuild` completes (never persists).
- **G-FH-OFF**: flag off ⇒ material + arrays byte-identical to shipped; full FLAT
  `verify_feature` all-pass.
- **#73 pin (no new code)**: existing `verify_facet_seams.gd` FS0 weld gates + a new assert in
  the same file: after `set_active(A→B)` the ring `transform` equals `_placement_xform()` in the
  same call under `FP_FIXED_FRAME` (identity), and shared-edge `facet_corner_dirs` node positions
  of A and B are bit-equal (the FS1 law, now pinned against regression).

### 3.4 Live A/B

1. Handoff skirt: stand on a mountainside, screenshot the near↔far frontier (annulus 112–152)
   flag-off vs flag-on — the ~6-block sunk skirt under the near block edge collapses to ≤2;
   `sh_applied_r` stays ≥ 64 (no ladder regression).
2. Orbit/de-orbit (#73 confirmation): full de-orbit run, screenshots at shell distance and at
   the descent handoff — no inter-facet step/tilt expected TODAY (pre-fix), since #73 is already
   closed; this A/B is the evidence to retire the task.

---

## 4. Task disposition

- **#72**: historical mechanism fixed live (chain in §1.2); reopen scope = the §1.3 residual
  only → implement `FP_V2_NEARFILL_UNSINK` (§3). Cosmetic-but-visible class (relief frontiers),
  not structural.
- **#73**: structural classes closed (FS1 `FP_SHELL_WELD` + FS2′ `FP_DATUM_BAKE` +
  `FP_FIXED_FRAME` + `FP_DESCENT_FACET_RESYNC` + `FP_UPVECTOR_FACET_HEAL`), evidence =
  served-pck dump (§0). Hold for one reproducing frame per §2.2; if the §3.4(2) de-orbit
  confirmation run shows nothing, close as fixed-by. No new flag pre-repro.
