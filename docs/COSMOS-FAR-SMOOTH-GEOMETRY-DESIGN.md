# COSMOS FAR SMOOTH GEOMETRY — real far relief, welded facet borders, seamless NEAR hand-off

**Status: DESIGN (unattended milestone contract). Author: Fable. Grounded against worktree
`.claude/worktrees/deploy-cheats` @ aa47992.**

User directive: *(A)* FAR terrain must have real smooth GEOMETRY (visible relief from mid-altitude and
orbit) transitioning **seamlessly** into the NEAR blocky voxel terrain — no pop, no gap, no cliff at the
LOD boundary. *(B)* facet borders must be **geometrically smooth and invisible** at any altitude.

Reading confirmed (design question 2/near): the NEAR stays **blocky** — the Minecraft identity is the
product (docs/DESIGN.md); the FAR transitions *into* blocky, never the reverse. The transition surface
is therefore FAR-side machinery only.

---

## 0. Verdict up front

**One mesh system answers both asks** — a per-facet smooth spherical heightfield tier ladder (the
already-built `FacetSmoothTier`/`FarDensity`, Item B of COSMOS-FAR-RENDER-OVERHAUL) — but the shipped
B1/B2 substrate has **one load-bearing defect** (boundary dirs derived from *unshared* planar corners
⇒ it cannot weld across facets under curved placement) and **four missing pieces** (facet-agnostic
border normals, full-hemisphere residency + emit-exclusion, mixed-pitch snap, and the S2 near-collar
that replaces the sunk backstop). Each is bounded, flag-gated, and headless-gateable.

Feasibility: **GREEN overall** — P0-P2 are hardening + driver work on proven machinery; **P3 (the
near-collar) is the YELLOW stage** (WASM envelope-build cost, see §7). Riskiest unknown: the S2
envelope fine-grid cost on a 2-core browser (§7.1).

---

## 1. Current state (verified, file:line)

### 1.1 The far render today
- The far ring is a **radial heightfield**: per-facet vertex grids at `CELLS := 4`
  (`facet_far_ring.gd:19`) — a 417-block facet meshed as 4×4 ≈ 104-block cells — limb ring at 8
  (`:21`), backstop at `BACKSTOP_CELLS := 16` (`cube_sphere.gd:300`). Colour comes from the map skin
  (band/fine/base pages, `facet_tex_baker.gd`), which is now block-exact (FP_SKIN_BLOCK_EXACT,
  065d5ba). **Geometry** is what's coarse: 104-block flat cells carry no mountain shape.
- Seam law shipped and proven: `FP_SHELL_WELD` (`cube_sphere.gd:328`) places shell vertices radially
  from the **shared** corner dirs (`FacetAtlas.facet_corner_dirs`, `facet_atlas.gd:425-438`);
  `FP_ENV_ALL` (`cube_sphere.gd:461` region) rides the same EDGE-CANON rule via `_env_weld_grid`
  (`facet_far_ring.gd:2380+`, **cells-parametrized** — reusable at any pitch); mixed tessellation uses
  COARSE-OWNS-EDGE chord-snap (`_weld_snap_edges`, `facet_far_ring.gd:2358` region). FS2′
  `FP_DATUM_BAKE`/`FP_DATUM_EDGE_WELD` (`cube_sphere.gd:345-377`) put the near voxel surface on the
  same radial datum R+g.
- The near field: active facet VoxelTerrain + ≤ `POOL_MAX_NEIGHBOURS := 4` pooled neighbours
  (`cube_sphere.gd:74`); the far ring draws those facets as a **sunk** dense backstop
  (`_is_backstop` = active ∪ `_excluded` ∪ sticky ≤ `STICKY_RING1_MAX := 12`, `cube_sphere.gd:379-393`),
  min-envelope + ε sink under env_all (`facet_far_ring.gd:2700-2730` emit branch).

### 1.2 The smooth substrate already built (Item B1/B2, gated off)
- `world/far/far_density.gd` — **heightfield node source, NOT a flat shell**: `node_at`
  (`far_density.gd:35-64`) returns per-(s,t) the radial vertex `planar + dir·relief`,
  `relief = (g − SEA_LEVEL)·RELIEF` through the exact shipped chain
  (`TerrainConfig.profile_at_dir` at `:53`). Real relief exists; the mesher is a **displaced grid**
  (surface net degenerated on a heightfield — `facet_smooth_tier.gd:15-18`), gate-proven
  (`verify_far_smooth.gd` G-FS-DEGEN/BOUND/BYTES, 27/0).
- `world/facet_smooth_tier.gd` — pure mesher `build_tile(fid, cells, lift, curved)` (`:54-137`) +
  a B2 inc-1 render instance (`:157-313`): worker-baked tiles, merged into one ArrayMesh, shares the
  shell material (skin UV/UV2 carried at `:100-101` ⇒ zero skin work).
- Tier ladder consts exist: `SMOOTH_S2..S5_CELLS = 104/52/26/13`, caps `9/25/64/200`,
  `SMOOTH_BYTES_MAX = 96 MB` (`cube_sphere.gd:678-689`).

### 1.3 Why B2 was gated off (`FP_FAR_SMOOTH := false`, `cube_sphere.gd:673`)
Inc-1 (d7ea70d, priority fix 52e864f) was deliberately minimal, and four structural gaps make it
un-shippable as the answer to this directive:
1. **Ring too small**: `_smooth_ring` covers only the active facet's in-face 3×3
   (`facet_far_ring.gd:658-676`), cross-face neighbours explicitly skipped (`:658` comment) — a 9-facet
   smooth patch inside a piecewise-flat world, with gaps at cube-face edges.
2. **Fixed single tier**: always `SMOOTH_S4_CELLS` (`facet_far_ring.gd:413`) — no SSE ladder, no S2.
3. **Overlay, not replacement**: tiles draw `lift = 0.5` *above* the heightfield
   (`SMOOTH_LIFT_BLOCKS`, `facet_far_ring.gd:57`) — double-draw, z-arbitration by a magic lift, and the
   flat shell still shows at every non-resident facet. Emit-exclusion (`resident_fids`,
   `facet_smooth_tier.gd:311-313`) was stubbed but never wired.
4. **Worker starvation** vs the whole-planet fine bake was patched by HIGH priority (52e864f) but the
   driver still rebuilds the **entire merged mesh** on any commit (`_rebuild_mesh`,
   `facet_smooth_tier.gd:273-303`) — O(all resident bytes) on the main thread per commit; fine at 9
   facets, a hitch bomb at 300.

### 1.4 THE DEFECT: B1 cannot weld across facets under curved placement
`FarDensity.node_at` bilerps `facet_planar_corner` corners (`far_density.gd:36-42`) and normalizes to
get `dir`. But planarized corners are **per-facet** — *"each facet's OWN planarized projection —
adjacent facets disagree at a shared edge by the ∝R datum step"* (`facet_atlas.gd:420`). The
weld-by-construction claim in `far_density.gd:12-14` holds only against the shipped **planar** emit
(`curved=false`). The shipped B2 worker builds with `curved=true` (`facet_smooth_tier.gd:267`), where
`pos = dir·(r + relief)` — and adjacent facets derive **different boundary dirs** from their unshared
corners ⇒ cracks/steps at every smooth-tile border. This is the exact per-facet-chords failure FS1
already root-caused and solved with `facet_corner_dirs` (`facet_atlas.gd:418-438`). **P0 re-routes the
density boundary through the shared-corner canon.**

### 1.5 Why the user still sees facet borders (design question 3, root-caused)
Ranked residuals, given FP_SHELL_WELD + FP_ENV_ALL live:
- **(d) dominant — piecewise-flat cells.** With planar-corner placement a whole facet is one flat
  chord plane (sagitta ≈ 3.4 blocks mid-edge, ~6.9 at corners; adjacent facets tilt by 90°/K = 3.75°).
  Even radially-welded CELLS=4 leaves 104-block chords: relief between nodes is a straight line, so a
  mountain flank crossing a border kinks visibly. The border is where the **geometry class changes**,
  and 104-block sampling makes every facet boundary a visible break in relief.
- **(a) tier frontiers coincide with facet borders.** Backstop (16 cells, ε/6-block sunk) meets
  coarse (4 cells) exactly at facet edges (`facet_far_ring.gd:2700-2730`) — a resolution + sink step
  drawn along the border.
- **(c) normals**: the shell shades with the *radial* normal (continuous — not a seam source today),
  but any lit-relief upgrade with per-tile one-sided gradient stencils
  (`facet_smooth_tier.gd:106-121` clamps the stencil at tile edges) would *create* a shading seam.
  Must be fixed before P2's lit normals ship.
- **(b) colour skin — ruled out**: block-exact palette pages, UV facet-param continuous
  (`facet_far_ring.gd:2719-2732` law, carried identically by smooth tiles).

### 1.6 Why NEAR↔FAR pops today (design question 2, root-caused)
The visible transition at the near-field rim (~112-block view distance, inside the 417-block active
facet) is blocky voxels → **min-envelope backstop sunk at 26-block cells** — a coarse, sunk,
flat-celled band (the "dip band 38-94" of memory `voxiverse-deorbit-phys-fix`; FP_FARRING_FULL_COVER
filled the see-through, not the look). The pop is not a bug but a **resolution + sink discontinuity**:
the far surface under/around the near field is deliberately ≤ truth − ε (no-protrusion law, correct)
but sampled so coarsely that "≤ truth" means "up to a full cell's relief below truth". At S2 pitch
(4 blocks) the same envelope law collapses to within a few blocks of truth ⇒ the dip becomes
sub-block-scale. **The fix is resolution, not a new transition mechanism.**

Geomorph note (memory `voxiverse-seamless-transition-design`): vertex morphing stays rejected — the
fly-up pop was an unload-policy bug, and our tier ladder has **exact node supersets**
(104 = 2·52 = 4·26 = 8·13): a promote/demote swap is positionally exact at every shared node, so
there is nothing to morph. Transitions are make-before-break swaps + SSE hysteresis
(`SSE_HYST = 1.25` precedent), optional dither (`BLOCK_LOD_DITHER_S` precedent).

---

## 2. The unified scheme (design question 4 — yes, A and B are ONE system)

**One smooth spherical-heightfield tier ladder, envelope-lawed where it can meet voxels, welded by the
FS1 canon everywhere, replacing (not overlaying) the flat shell facet-by-facet as tiles commit.**

```
 blocky NEAR (voxels, truth)                      ← untouched, stays blocky
   └─ S2 collar  (4-block pitch, active ∪ pool):  envelope-inside-R_env + feather → true, ε-sunk
       └─ S3/S4/S5 ladder (8/16/32): true-height smooth tiles, SSE-driven, whole visible hemisphere
           └─ frontier: S5 boundary chord-snapped onto the shipped FP_SHELL_WELD CELLS=4 shell
               └─ shipped shell (radial weld) — orbit fallback + back hemisphere, unchanged
```

Laws (each cited to its existing precedent):
1. **Placement**: every vertex at `d̂·(r_of + relief(g(d̂)))` — curved (`facet_smooth_tier.gd:51-53`
   rationale), on the FS2′ radial datum the near mesh already sits on (`cube_sphere.gd:345-360`).
   Cell-chord sagitta at S5's 32-block pitch is 32²/8R ≈ 0.02 blocks — curvature ceases to be visible
   at ANY tier; the 3.75° facet dihedral is gone by construction.
2. **Boundary canon (fixes §1.4)**: boundary and interior node dirs derive from
   `facet_corner_dirs` bilerp (`_weld_unit` chain, `facet_far_ring.gd:2321` precedent), NOT
   `facet_planar_corner`. Two facets sharing an edge then compute bit-identical boundary nodes
   (in-face exactly; across the 12 cube edges to f64 rounding — `facet_atlas.gd:421-424`). Cross-face
   adjacency comes from `seam_neighbour` (`facet_atlas.gd:581`).
3. **Border normals (pre-empts §1.5c)**: at tile-boundary nodes the normal is computed
   **facet-agnostically** — central differences of `profile_at_dir` in the canonical tangent frame of
   d̂ (a pure function of d̂, both sides get the identical value). Interior nodes keep the cheap grid
   cross-tangent stencil (`facet_smooth_tier.gd:106-121`); both approximate the same ∇h so the
   interior/boundary blend is invisible. Cost: 4 extra `profile_at_dir` per boundary node only
   (≤ 4·(cells+1)·4 per tile).
4. **Mixed pitch**: fine-side boundary nodes snap onto the coarse-side chord — the shipped
   `_weld_snap_edges` discipline; tier order is coarse-owns-edge, and the S5→shipped-shell frontier
   snaps onto the CELLS=4 weld chord so the smooth region has a closed, crack-free rim at any
   residency state.
5. **Skirts (backstop against implementation bugs)**: `SMOOTH_SKIRT_BLOCKS := 4` radial drop along
   every tile border (`cube_sphere.gd:688`, already declared) — sub-pixel at engage distances,
   guarantees no see-through crack ships on night one.
6. **Replacement, not overlay**: a facet leaves the heightfield emit set the frame its smooth tile
   commits (smooth-until-ready; the `_excluded` mechanism at `facet_far_ring.gd:587-596` +
   `resident_fids` at `facet_smooth_tier.gd:311` are the two halves, currently unwired). `lift` → 0.
7. **ε sink + depth bias**: smooth tiers apply the emit-time ε sink exactly like the env shell
   (`_sunk_positions`, `facet_far_ring.gd:2728`) and inherit `FP_TIER_DEPTH_BIAS` arbitration — near
   blocks stay unbiased/authoritative.
8. **Skin**: unchanged — smooth vertices carry the same UV/UV2 the heightfield emits
   (`facet_smooth_tier.gd:100-101`); band → fine → base resolves identically. Zero shader work except
   P2's normal swap.

### 2.1 The NEAR↔FAR contract (design question 2)
- **Where voxels can exist** (disc of radius `R_env = near view distance + STREAM_MARGIN(32)` around
  the player column): S2 vertex height = **min-envelope** over the dilated footprint − ε — the proven
  no-protrusion law (`_env_weld_grid`, cells-parametrized, called with `cells = 104`;
  `ENV_FINE_MULT`/`ENV_DILATE_BLOCKS` in `tier_place.gd:23-25`). At 4-block pitch the envelope sits
  within the *local 4-block relief variation* of truth — the dip collapses from ~cell-scale to
  ~block-scale. The blocky rim then reads as block sides standing ≤ a few blocks proud of the smooth
  surface immediately beyond — the Distant-Horizons-style hand-off, no gap (smooth is strictly below),
  no cliff (sub-block dip), no pop (make-before-break, §3 P3).
- **Feather band** (`R_env … R_env + 16`): per-vertex `height = lerp(env, true, w)` — inside one
  facet's S2 tile, position-keyed (a pure function of world position + player column snapshot), so two
  adjacent S2 tiles spanning the disc compute identical boundary values ⇒ the weld canon survives.
- **Beyond the feather**: true heights (nothing to poke through; aliasing between nodes is invisible
  without voxels).
- **Rebuild cadence**: the disc moves with the player — re-request the affected S2 tile(s) when the
  player column moves > `RIM_REBUILD_BLOCKS := 24` (worker-paced, replace-in-place, old tile draws
  until the new one commits). STREAM_MARGIN(32) > 24 guarantees voxels never stream in outside the
  envelope zone between rebuilds.

---

## 3. Stages (each: implement → gate → FLAT → deploy; independently shippable)

### P0 — weld-true substrate (no new flag; hardens inert B1)
Re-route `FarDensity.node_at` dirs through the `facet_corner_dirs` canon (§2 law 2); add the
facet-agnostic boundary-normal law (§2 law 3); mixed-pitch chord-snap helper.
- Byte-off: nothing constructs the mesher (`FP_FAR_SMOOTH` still false) — FLAT 6042/0 untouched.
- Gates (extend `verify_far_smooth.gd`):
  - **G-FS-CANON**: demonstrate `facet_planar_corner` disagreement at a shared edge (the defect), then
    assert canon boundary dirs of an adjacent pair (E/W/N/S via `seam_neighbour`, incl. a cross-face
    pair) are bit-equal.
  - **G-FS-WELD-EDGE**: two adjacent same-pitch tiles → boundary vertex sets equal (≤ 1e-9·R).
  - **G-FS-NRM-CONT**: boundary normals across the pair equal (≤ 1e-4).
  - **G-FS-WELD-MIXED**: S3 tile vs S4 neighbour → fine boundary nodes on the coarse chord.
- Bytes: zero resident (pure functions).

### P1 — `FP_FAR_SMOOTH` re-arm: full ladder, replacement rendering
Driver rewrite in `facet_far_ring.gd` `_smooth_drive`: SSE-driven tier ladder S3/S4/S5 over the visible
hemisphere (nearest-first from the emit axis, per-tier caps 25/64/200, hysteresis 1.25), cross-face
ring via `seam_neighbour`, **emit-exclusion** smooth-until-ready (law 6), skirts, frontier snap
(law 4), `lift = 0` retired. Mesh management: **per-tier ArrayMesh surfaces, rebuild only the dirty
tier, ≤ 1 tier rebuild/frame** (replaces the O(everything) `_rebuild_mesh`) ⇒ ≤ +4 draws.
- Gates: **G-FS-EXCL** (a facet is in exactly one of {heightfield set, smooth-resident} every step;
  never neither), **G-FS-FRONTIER** (S5 rim nodes on the shipped weld chord), G-FS-BYTES re-run,
  G-FS-OFF.
- Bytes (tile = verts·56 B + idx·4 B): S3 ≤ 25×222 KB = 5.6 MB; S4 ≤ 64×57 KB = 3.7 MB;
  S5 ≤ 200×15 KB = 3.0 MB ⇒ **12.3 MB resident** (+ same again transiently at merge; GPU copy ≈
  resident) — ledgered under `SMOOTH_BYTES_MAX` 96 MB, asserted.
- Tri budget: ≤ 135k + 90k + 68k ≈ 293k merged into ≤ 4 draws (draw count, not tris, is our proven
  ceiling — memory `voxiverse-web-perf-architecture`).
- Deploy config: sed block-LOD visual rings OFF with smooth ON (rollback look preserved), per
  COSMOS-FAR-RENDER-OVERHAUL §4.3.

### P2 — `FP_SMOOTH_NORMAL_LIT`: relief lighting
Shader splice (string-splice discipline, `facet_far_ring.gd:3209` precedent): smooth-tile fragments
shade with the interpolated vertex NORMAL under the `FP_SHADE_UNIFIED` law (`cube_sphere.gd:641`,
`VoxiLight.SHADE_GLSL`); the shipped shell keeps the radial normal. Without this, S-tier relief is
geometry-only and barely reads; with it, sunlit slopes/lee shading make mountains visible from orbit.
- Gates: golden shader-string pin (flag-off splice byte-identical — the F7 lesson), FLAT 6042/0.
- Bytes: zero.

### P3 — `FP_SMOOTH_RIM`: the S2 near-collar (THE near↔far seam kill) — YELLOW
S2 tiles for active ∪ pool (≤ 5, cap `SMOOTH_S2_MAX` effectively 5-9), envelope-inside-disc + feather
+ ε sink (§2.1), replacing the visible backstop role: a backstop facet leaves the 16-cell sunk emit the
frame its S2 tile commits (make-before-break; sticky ring-1 facets stay S3). Rim rebuild cadence
`RIM_REBUILD_BLOCKS = 24`.
- Gates: **G-RIM-ENV** (inside `R_env`+margin every vertex ≤ true−ε, envelope-footprint proof — the
  `verify_no_protrusion.gd` pattern), **G-RIM-WELD** (two S2 tiles spanning the disc: shared boundary
  nodes equal; feather is position-keyed), **G-RIM-MBB** (never a frame with neither backstop nor S2
  resident for a pool facet), G-FS-BYTES.
- Bytes: ≤ 9×876 KB = **7.9 MB** resident + transient env fine grid ≤ 417²×4 B ≈ 0.7 MB/worker slot
  (≤ 4 slots) — under ledger.
- Perf risk + fallback ladder: see §7.1.

### P4 — `FP_SMOOTH_SHELL_BASE`: kill the last frontier (orbit polish)
Replace the shipped CELLS=4 shell emit with an always-resident S6 (7-cell, ~60-block pitch) smooth
base for the whole planet: 3456 × ~4.8 KB ≈ **16.6 MB**, ~98 tris/facet (front-hemisphere draw ≈
170k tris vs today's 110k). Radial nodes ⇒ per-cell dihedral < 0.6°; the S5 frontier then snaps onto
S6 instead of the CELLS=4 chord. Optional — ship only if the P1 frontier is still visible from orbit
in the live eyeball; gated behind a measured `heap_mb` A/B (instrument live: `self.__voxHeapSize`).
- Gates: G-FS-FRONTIER re-pointed at S6; ledger assert; FLAT.

### P5 (designated cut, out of directive scope) — `FP_FAR_SMOOTH_OVERHANG` (B4) edit-cluster
occupancy patches, unchanged from COSMOS-FAR-RENDER-OVERHAUL §2.3.

---

## 4. NEVER-OOM ledger (all fixed-at-creation or LRU'd under `SMOOTH_BYTES_MAX = 96 MB`)

| Stage | Resident bytes | Transient | Notes |
|---|---|---|---|
| P0 | 0 | per-tile build only | pure functions |
| P1 | 12.3 MB (S3+S4+S5 caps) | ≤ 1 tier merge/frame | + GPU ≈ resident |
| P2 | 0 | — | shader string |
| P3 | +7.9 MB (S2 ≤9) | 0.7 MB × ≤4 slots | env fine grids freed at commit |
| P4 | +16.6 MB (S6 all-planet) | — | replaces shell emit arrays (~2.4 MB back) |
| **Worst total** | **≈ 37 MB + GPU ≈ 74 MB** | | **≤ 96 MB cap, gate-asserted; live heap_mb A/B per stage** |

---

## 5. Reusable vs new

**Reused verbatim**: `FarDensity`/`FacetSmoothTier` mesher core + tier consts + byte ledger + worker
slots (B1/B2); `facet_corner_dirs`/`seam_neighbour`/`_weld_unit`/`_weld_snap_edges` (FS1);
`_env_weld_grid` cells-parametrized envelope + ε sink + EDGE-CANON (FP_ENV_ALL); `_excluded`
emit-exclusion mechanism; skin UV/UV2 law + shell material; SSE law `K_px`/hysteresis; make-before-break
+ sticky discipline (TIER-DEPTH P1); `verify_far_smooth.gd`/`verify_no_protrusion.gd` gate patterns.

**New**: canon-dir routing in `node_at` (P0); facet-agnostic boundary normals (P0); full-hemisphere
SSE driver + per-tier incremental mesh management + exclusion wiring (P1); smooth-normal shader splice
(P2); envelope-inside-disc + feather + rim rebuild cadence (P3); S6 base (P4). No new render paths, no
new textures, no C++ changes required (P0-P4 are pure GDScript + shader strings).

---

## 6. Flag summary (all `const … := false` in `cube_sphere.gd`, committed — the deploy script
`git checkout`-reverts that file, memory `voxiverse-fallthrough-loc-bug`)

`FP_FAR_SMOOTH` (P1, exists), `FP_SMOOTH_NORMAL_LIT` (P2), `FP_SMOOTH_RIM` (P3),
`FP_SMOOTH_SHELL_BASE` (P4), `FP_FAR_SMOOTH_OVERHANG` (P5, exists). New consts:
`RIM_REBUILD_BLOCKS := 24`, `RIM_STREAM_MARGIN := 32`, `RIM_FEATHER_BLOCKS := 16`.

---

## 7. Risks

### 7.1 THE riskiest unknown — S2 envelope build cost on 2-core WASM (P3)
`_env_weld_grid(fid, 104)` at `ENV_FINE_MULT=4` samples a 417²-node fine grid ≈ **174k
`profile_at_dir` calls per facet** — the same order as a band-facet bake, which measured ~1 facet/s
on a 2-core browser (memory `voxiverse-far-render-overhaul` perf wall). With ≤ 5 collar facets +
rebuild-on-move this may lag the walking player. Mitigation ladder (in order):
(i) `ENV_FINE_MULT 4→2` for the S2 call (43k calls) + `ENV_DILATE_BLOCKS` bump to keep the proof;
(ii) incremental rim rebuild — re-envelope only the moved crescent of the disc;
(iii) the C++ fine-bake work item (COSMOS-FAR-RENDER-OVERHAUL next-fix; `sample_columns` serializes —
would need the parallel-safe variant) lifts this ~10×;
(iv) fallback const: keep the shipped backstop but `BACKSTOP_CELLS 16→32` (6.5-block cells — shipped
machinery, one const, gets ~70 % of the visual win).
P3 ships only if (i)/(ii) hold a full walk-rebuild under ~1.5 s worker time on the live A/B.

### 7.2 Other risks
| Risk | Mitigation |
|---|---|
| Seam cracks despite the canon (classic isosurface failure) | Three independent layers: canon-shared boundary nodes (gate-proven bit-equal), chord-snap, always-on 4-block skirts. |
| Merged-mesh commit hitches at scale | Per-tier surfaces + ≤ 1 tier rebuild/frame + dirty-tier-only (P1 driver requirement, replaces `_rebuild_mesh`). |
| Smooth pokes near voxels at the rim | Envelope law inside R_env + STREAM_MARGIN > rebuild cadence + ε sink + depth bias; G-RIM-ENV is a proof, not an eyeball. |
| Tier-swap pop | Node-superset ladder ⇒ positionally exact swaps; SSE hysteresis 1.25; optional dither. Geomorph stays rejected. |
| Worker starvation vs fine bake | HIGH priority (52e864f) kept; collar > ladder > fine-map ordering; bounded nearest-first requests. |
| f64→f32 boundary rounding across cube edges | Canon agrees to f64 rounding (`facet_atlas.gd:423`); PackedVector3Array is f32 — both sides quantize the SAME f64 value to the SAME f32 ⇒ still bit-equal. Gate asserts on the built arrays, not the f64 math. |
| Shader splice regression | Golden-string pins (the Item-A F7 lesson) in every stage gate. |

---

## 8. Audit hooks (what Fable will check)
1. G-FS-CANON demonstrates the planar-corner disagreement AND the canon fix — the defect must be
   falsifiably shown, not just patched.
2. Byte-off identity per flag (FLAT 6042/0 + golden shader strings) after every stage.
3. G-RIM-ENV proof logs (no-protrusion at the rim is proven, never eyeballed).
4. Ledger reproduced by runtime accounting + live `heap_mb` before/after each deploy.
5. Live eyeball (deferred to the user): mountains readable from mid-altitude/orbit; no straight-line
   facet stitching anywhere; walking toward the rim shows blocky→smooth with no dip/cliff/pop.
