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

---

# REVISION 2 — live-failure root-cause + fix (2026-08-03, Fable)

P0-P3 shipped (4aae152 → ef68dba), passed 86/0 headless + FLAT 6042/0, deployed live — and looked
broken: patchwork of smooth/flat/megablock facets, a grey relief lump, facets flicking skin↔smooth,
sunk facets, fps 19-33 (proc 186 ms, hitches 4238, vox gen backlog 191), plus **the user's #1: the FAR
terrain visibly BELOW the adjacent NEAR terrain during streaming**. Rolled back. Every failure is
root-caused below to file:line. **The geometry substrate (P0 weld/mesher) is sound and stays; the
residency DRIVER model and three unwired couplings are the failure.**

## R.1 Root causes (confirmed in code)

### R.1.a Flicker — break-before-make everywhere + camera-coupled residency (THE big one)
1. **Evict-on-request**: `FacetSmoothTier.request()` evicts any resident whose wanted tier changed
   (`facet_smooth_tier.gd:510-513`) — a promote/demote **destroys the tile first**, rebuilds later.
   During the gap the facet has neither tile nor (see 3) shell coverage.
2. **Camera-coupled ranking**: `_smooth_ranked_fids` runs a fresh BFS **every frame**
   (`facet_far_ring.gd:431-432, 498-522`) and drops any facet failing `_front_visible(nb, nrm, thresh)`
   (`:516`), where the cull axis is the **camera emit axis** when `_cam_set`
   (`_cull_params`, `facet_far_ring.gd:1015-1018`). Turning the head removes facets from `ranked` →
   they leave `_want` → `request()` evicts them **instantly**; turning back re-requests them.
   Look-around = mass evict + rebuild = skin↔smooth flicker. The rank-BAND hysteresis
   (`:537-557`, d1/d2/d3 = caps×1.25) only damps in-band drift; it cannot survive a rank shuffle
   from a heading change or a facet crossing (rank is recomputed from a new BFS root).
3. **Stale-shell hole window**: emit-exclusion is a filter on `visible_fids()`
   (`facet_far_ring.gd:1959-1960`), but the shell mesh only honours it at its next **full async
   re-emit** (`consume_changed()` → `_pending`, `:438-439` — the known 300-700 ms re-emit bomb).
   On evict, `is_resident` flips false immediately and the tier mesh drops the tile within a frame
   (`step()`/`_rebuild_tier_mesh`), but the drawn shell mesh was built with that facet **excluded**
   → a HOLE (see-through to the sunk backstop / nothing) until the shell rebuild lands — seconds
   under load. G-FS-EXCL asserted the *sets*, not the *committed meshes*, so this was invisible headless.
4. **Discarded builds amplify churn**: a finished worker tile is thrown away if `_want` moved while
   it built (`facet_smooth_tier.gd:548`) — under per-frame re-ranking the driver builds → discards →
   rebuilds, which is why `smooth_res` hovered at 209 (< the 289 cap) while workers ran flat out.
5. **Rim rebake is an evict**: every `RIM_REBUILD_BLOCKS=24` of walk, ALL resident S2 collar tiles
   are `force_rebake`d **simultaneously** (`facet_far_ring.gd:468-474` → `facet_smooth_tier.gd:528-530`,
   a plain `_evict`) — the collar drops to the ε-sunk backstop for the multi-second S2 rebuild
   (R.1.e), then pops back. Periodic whole-collar flicker + sunk band by design.

### R.1.b Patchwork (smooth / flat / HUGE BLOCKS side-by-side)
- The ladder's resident set is capped at 25+64+200 = 289 facets (`cube_sphere.gd:700-703`) of a
  ~1700-facet visible hemisphere — everything past rank 289 stays flat far-map skin **by
  construction**, and during (slow, churning) convergence the boundary between the classes is
  arbitrary and moving.
- **The megablocks are the FP_BLOCK_LOD family / FP_BLOCKY_FARRING blocky emits still live in the
  deployed build.** §3 P1's "deploy config: sed block-LOD rings OFF with smooth ON" made mutual
  exclusion a *deploy-script* responsibility; nothing in code arbitrates
  (no `is_smooth_resident` check anywhere in `facet_block_lod_*.gd` — verified by grep). Wherever the
  smooth tile wasn't committed yet, the megablock tier showed = "some mountains are huge blocks".
  S5 itself (13 cells = 32-block pitch, `cube_sphere.gd:697`) is per-VERTEX-interpolated
  (`facet_smooth_tier.gd:98`, smooth-shaded quads, not per-cell-flat) — low-poly but not "blocks";
  the literal huge blocks are the megablock tiers.
- Mutual-exclusion-by-deploy-sed is an architecture smell: **arbitration must live in code** (one
  authority says which system draws a facet), or every deploy is one sed away from this patchwork.

### R.1.c Grey mis-colour — smooth tiles hard-code the coarsest skin tier
`build_tile`/`build_tile_rim` write `uv2[vi] = Vector2(float(face), -1.0)`
(`facet_smooth_tier.gd:113, 227`) — slot **hard-coded −1**. The shell emit feeds UV2.y through
`_slot_of` (`facet_far_ring.gd:3037`): band facets carry 64+layer (block-exact id-map skin,
FP_BAND_BLOCK_MAP), close-up facets a closeup slot. Slot −1 ⇒ the fragment falls to the **6-layer
whole-face base map** (`facet_far_ring.gd:3262` `texture(base_map, vec3(v_uv, v_face))`) — tens of
blocks per texel, a washed-out average (mountain ≈ stone grey), or **black when the page isn't bound
yet** (`:3166` "null until then → black texels"). So a smooth tile paints grey-average while its flat
neighbours paint crisp block-exact sand — the grey lump. The design's §2 law 8 claim ("skin:
unchanged — resolves identically") was simply not implemented: the tiles never consult the band/fine
slot snapshot. No colour gate existed to catch it.

### R.1.d Sunk facets + the NEAR/FAR height misalignment (user's #1)
Every fallback the smooth system exposes during a transient is **constructed ≤ truth**:
- backstop = min-envelope − ε sink at 26-block cells (`_env_weld_grid` + `_sunk_positions`,
  `facet_far_ring.gd:2700-2730`) — up to a full cell's relief below the near surface;
- coarse shell CELLS=4 = relief sampled at 5×5 nodes/facet — a mountain between nodes **does not
  exist** in the far mesh (the far skin sits at valley height under a near mountain);
- block-LOD megablock top = MIN over its footprint (containment law) — below truth by the relief
  variation over the footprint.
The no-protrusion law makes all of these correct **only while hidden behind committed near voxels**.
During streaming the near field hasn't filled its rim, so the ≤-truth fallback is *exposed* — "FAR
renders below NEAR". Add R.1.a's evict windows (facet falls from true-height smooth back to the sunk
fallback) and R.1.a.5's periodic whole-collar rebake, and sunk facets/steps were guaranteed visible.
**Design gap named: no-protrusion needs a complement — an EQUAL-HEIGHT law at every exposed
near↔far boundary.** ≤-truth is only licensed where committed voxels cover it; the exposed band must
carry the same per-column `g` the near VoxelTerrain builds from (one `TerrainConfig` chain — same
number, by construction), at all times including mid-stream.

### R.1.e Perf collapse
1. **Per-frame driver churn**: BFS + `_smooth_next_assignment` + `request()` rebuild `_snap_plan`
   (a Dictionary + 4-slot PackedInt32Array per wanted facet, ~289 of them) **every frame**
   (`facet_far_ring.gd:431-437`, `facet_smooth_tier.gd:493-513`).
2. **Tier-mesh rebuild is O(tier) in GDScript per commit**: `_rebuild_tier_mesh` concatenates every
   resident tile of the tier with a **per-element index loop** (`facet_smooth_tier.gd:639-640`,
   `for idx in …: I.append(base+idx)`) — S3 = 25×~19k idx ≈ 480k, S5 = 200×~1.2k ≈ 240k GDScript
   iterations, re-run near-every frame during convergence (each commit re-dirties the tier). This is
   the proc 186 ms.
3. **Shell re-emit bomb per residency change**: `consume_changed()` → `_pending` full-hemisphere
   re-emit (`:438-439`) fired continuously while 289 tiles converged/churned — hitches 4238.
4. **S2 collar cost, §7.1 fallbacks unwired**: `build_tile_rim` calls `_env_weld_grid(fid, 104)`
   (`facet_smooth_tier.gd:189`) = ~174k `profile_at_dir`/facet at ENV_FINE_MULT=4 — the known
   ~1 facet/s wall — ×5 facets, re-baked every 24 blocks of walk. None of §7.1's mitigations
   (FINE_MULT 2, crescent-incremental) were implemented.
5. **Worker starvation of the game**: smooth builds dispatch HIGH priority
   (`facet_smooth_tier.gd:571`) with up to `SMOOTH_BUILD_SLOTS=8` slots on detected true cores —
   on a 2-4 core browser the churning smooth/rim builds crowd out voxel generation → vox gen
   backlog 191 → the near field streams even slower → the exposed ≤-truth fallback (R.1.d) shows
   *longer*. The perf failure and the height failure compound each other.

## R.2 Verdict on the model
The **mesher/weld substrate (P0) is right and gate-proven** — keep it. The **tier-LADDER as a
rank-banded, camera-coupled, re-ranked-per-frame residency model is the wrong stability model** —
it optimizes byte budgets, not the user-visible invariant ("one or the other, never switching").
Replace the driver's laws, not the rendering machinery:

- **LAW R-A (sticky-monotonic residency).** Assignment is a pure function of `(active_fid)` via
  **hop-ring bands** (ring 1-2 → S3, ring ≤5 → S4, ring ≤10 → S5): geometric, camera-independent,
  changes only at a facet **crossing** — never while walking within a facet, never on look-around.
  Drop `_front_visible` from ranking (hop radius already bounds the set; back-hemisphere facets cost
  resident bytes but buy total stability — the ledger holds: same 289-facet worst case). Eviction
  only when hop distance exceeds band + 2 **and** has for ≥ 5 s (dwell), LRU under the byte cap.
- **LAW R-B (make-before-break, both directions, at the MESH level).** Tier change = build the new
  tile, swap on commit; `request()` never evicts a resident for a tier change (kill
  `facet_smooth_tier.gd:512` tier-mismatch evict). Rim rebake = build-then-swap (retire
  `force_rebake`-as-evict); stagger S2 rebakes one facet at a time. Exclusion decouples from
  correctness: **smooth-over-shell double-draw is safe** (smooth ≥ shell by no-protrusion + ε sink),
  so a facet joins the shell-exclusion list lazily/batched (≥ N changes or 2 s debounce), and
  LEAVING smooth requires the shell re-emit to **commit first** (facet re-included) before the tile
  is dropped. Gate on committed meshes, not sets.
- **LAW R-C (skin parity).** Smooth tiles carry the SAME UV2 slot law as the shell emit (route the
  frozen `_slot_of` snapshot into the build; refresh via the tier-mesh rebuild when slots move).
  Kill the hard-coded `(face, -1)`.
- **LAW R-D (equal-height at the exposed rim — the user's #1).** The surface drawn immediately
  outside the committed near field carries the per-column true `g` (the shared
  `TerrainConfig` chain) at ≤ 4-block pitch AT ALL TIMES: S2 collar facets are **permanently
  sticky** while backstop-role (never evicted, only swap-rebuilt); until the FIRST S2 commit the
  fallback must not read sunk — cut the ε sink to sub-block at the exposed rim band and raise
  `BACKSTOP_CELLS` 16→32 (§7.1 iv) as the interim floor. ≤-truth is licensed only under committed
  voxels.
- **LAW R-E (one-look arbitration in code).** `FP_FAR_SMOOTH` at runtime suppresses the block-LOD
  ring/blocky-farring emission for any facet in the smooth-eligible disc — mutual exclusion is a
  code invariant, never a deploy-sed convention.
- Coarse floor: S5 stays (it is vertex-interpolated, not the "huge blocks") but P2 normal-lit is
  **required with** P1 (geometry-only relief barely reads); if the live eyeball still reads faceted,
  floor S5 13→26 cells (bytes ×4 on the S5 set ≈ +9 MB, still under ledger).

## R.3 The missing gates (name the invariants the 86/0 never tested)
1. **G-FS-STABLE (temporal stability)** — drive the real driver along a scripted path (walk 200
   blocks, two facet crossings, four 90° camera turns, 600 steps): assert **no facet transitions
   smooth→shell more than once**, and never within N=100 steps of becoming smooth; assert zero
   evictions caused by camera turns.
2. **G-FS-COVER (rendered coverage, committed-mesh level)** — every step: each front facet is drawn
   by ≥ 1 committed mesh (shell surface actually containing its verts, OR resident tile in the
   actually-rebuilt tier mesh) — the set-level G-FS-EXCL missed the stale-shell hole window.
3. **G-FS-TIER-ADJ (consistency)** — adjacent smooth facets differ by ≤ 1 tier; no shell facet
   strictly inside the smooth disc radius (no patchwork holes at steady state AND at every step of
   the driven path).
4. **G-FS-COLOUR (skin parity)** — for sampled columns: the smooth tile's UV2 slot == the slot the
   shell emit would carry for that facet (`_slot_of` snapshot), and vertex colour == FarPalette of
   that column (catches R.1.c exactly).
5. **G-NF-HEIGHT (equal-height rim, THE acceptance gate)** — for every column of the near-field
   boundary ring, in converged AND every unconverged driver state of the driven path: the topmost
   drawn far-tier vertex height == near `g` (≤ 1 block ε). A flat-at-datum/env-sunk surface exposed
   at the rim FAILS this gate.
6. **G-FS-CHURN (work budget)** — over the driven path: builds-per-facet ≤ 2, discarded builds = 0,
   main-thread driver+rebuild time ≤ budget/frame (catches R.1.e.1-3).

## R.4 Staged fix plan (each flag-gated + headless-gateable, new gates included)
- **R1 `FP_SMOOTH_STICKY`** — driver rewrite: hop-ring assignment (crossing-triggered), dwell+LRU
  eviction, no camera coupling, build-then-swap tier changes, commit-even-if-want-moved (no
  discards). Gates: G-FS-STABLE, G-FS-TIER-ADJ, G-FS-CHURN, byte ledger re-assert.
- **R2 `FP_SMOOTH_MESH_INC`** — perf: per-tile index arrays pre-offset in the worker (main-thread
  rebuild = `append_array` only), tier rebuild debounced (≥ 250 ms), shell exclusion re-emit batched
  (≥ 16 changes or 2 s), driver re-rank only on crossing. Gate: G-FS-CHURN main-thread budget.
- **R3 `FP_SMOOTH_SKIN_SLOT`** — UV2 slot parity (LAW R-C). Gate: G-FS-COLOUR.
- **R4 `FP_SMOOTH_RIM` rev 2** — sticky S2 collar, staggered swap-rebakes, ENV_FINE_MULT 4→2 +
  crescent-incremental envelope (§7.1 i-ii wired), web build slots ≤ 2, normal priority for ladder
  tiles (HIGH only for the ≤ 5 collar tiles), interim `BACKSTOP_CELLS` 32 + rim ε-sink cut.
  Gates: **G-NF-HEIGHT**, G-RIM-ENV, G-RIM-MBB re-pointed at committed meshes.
- **R5 `FP_FAR_SMOOTH` re-arm** — code-level block-LOD/blocky-farring arbitration (LAW R-E), P2
  normal-lit required-on, live A/B. Gate: G-FS-COVER + full suite + FLAT.
Ship order: R1+R2 together (stability is meaningless at 19 fps), then R3, then R4 (the user's #1
gate), then R5 live.

## R.5 Verdict
**YELLOW — fixable forward, no new rendering model needed.** The weld/mesher substrate and byte
ledger survived contact intact; what failed is the residency policy (camera-coupled, break-before-
make), two unwired design claims (skin parity §2 law 8, §7.1 perf fallbacks), and a deploy-sed
arbitration that belonged in code. All are bounded driver/wiring work gateable by R.3. The one
architectural addition this revision makes permanent: **the equal-height law at the exposed near↔far
rim (LAW R-D / G-NF-HEIGHT) outranks the tier-ladder mechanics — it is the acceptance criterion the
whole feature exists to satisfy.** If R4's S2 cost still can't hold walking pace after §7.1 i-ii,
the fallback is not a model change but a baseline change: raise the always-resident far baseline to
true-height 8-block pitch for the rim band only (bytes ≈ +1.5 MB), so the resting state is
height-true without any bake-on-move at all.

---

# REVISION 3 — quiescence + no-hole commit model (2026-08-03, Fable)

REV2 (2c5b31c) shipped and held its own laws: `smooth_res` is CONSTANT at 209 at rest — the sticky
residency SET is stable. Two live failures remain: (1) the far terrain **keeps changing while the
player is stationary** (identical frozen pose, 12 s apart, different relief/grey patches, changed
extent; `hitches` +~10/s), and (2) **facet misalignment + render-through**. Both are root-caused
below. The finding in one line: **REV2 stabilized WHO is resident but gave neither the drivers an
idle state nor the commits a single-frame transaction — the far stack has no terminal state, and its
transient windows draw wrong or draw nothing.**

## R3.1 Root cause A — churn-at-rest: five engines run with zero player input

### R3.1.a The skin-convergence sweeps repaint the disc for the whole session
The whole-planet fine bake runs until ALL `6·K² = 3456` facets are baked
(`facet_tex_baker.gd:1755` `fine_pending = _fine_baked.size() < _base_all`, dispatch :1782-1804);
each commit blits a tile into an L8 sub-page and a throttled **full-layer `update_layer` of the
768² page fires every ≤ 15 frames** (:1806-1809 — the "2.36 MB" comment is stale; at
`PLANET_MAP_TEXELS=64` it is ~0.6 MB, still a recurring main-thread upload). In parallel the g0
base-coverage + g1 shot-upgrade sweeps (`_select_worker_unit` :653-661) rewrite base pages across
the whole planet. At measured web rates this is **minutes-to-an-hour of continuous repainting**.
The geometry under it is stable — but at orbit ALL relief cues are baked shading in the skin, so
this alone IS "relief/grey patches in different places" between two screenshots 12 s apart. It is
monotone convergence, not a loop — but with no disc-done terminal signal and no bound the user can
perceive, it is indistinguishable from churn.

### R3.1.b Every close-up/band commit forces a FULL shell re-emit (the hitch engine)
`_cu_commit_slice` bumps `_slots_epoch` (`facet_tex_baker.gd:1039`; evict :1055); WorldManager
pushes it (`world_manager.gd:1169-1178`) → `set_closeup_slots` → **`_pending = true`**
(`facet_far_ring.gd:3924`; band :3962) → a full-front shell re-emit (`_rebuild_full` /
`_dispatch_async_rebuild`), *because the skin slot is baked into mesh vertices* (UV2.y via
`_slot_of`, :3228-3231). At alt 427, `CLOSEUP_FAR = 4000` (`cube_sphere.gd:1075`) admits ~285
candidates capped to `CLOSEUP_MAX = 64` (:1071) → **up to 64 close-up commits after arrival, each
one full re-emit + `_shell_gen++`**. On top: the orbit warm-front progressive reveal re-emits every
`SHELL_REEMIT_GROWTH = 64` newly-cached facets (`facet_far_ring.gd:1007-1017`) while the ~1700-facet
front warms — the shell's emitted set literally grows = **"terrain extent changed"**. Each re-emit
is the known full tri-soup rebuild → the ~10/s hitch cadence at rest.

### R3.1.c The smooth driver has no idle state
`_smooth_drive()` runs every frame (`facet_far_ring.gd:949`) and unconditionally executes: the
dwell scan (O(res), :532-548), `_mesh_inc_gate` (O(res), :558-573), the R-C slot loop (O(res),
:474-479), and `_smooth.request()` — which **rebuilds `_want` + the full `_snap_plan` (209 × 4
`seam_neighbour` + fresh dicts) every frame** (`facet_smooth_tier.gd:520-545`) even when the
assignment is bit-identical to the previous frame. In the baker, `_recompute_want_sse`
(`facet_tex_baker.gd:863-899`) scans + sorts all 3456 facets **every update with no hold gate** —
the non-SSE `_recompute_want` HAS the axis-hold gate (:835); the SSE path omitted it. None of this
commits anything at fixpoint, but it is unconditional per-frame main-thread work — and it means
there is **no "settled" signal anywhere** to gate on or to assert in a test.

### R3.1.d Smooth tiles go skin-stale, then skin-WRONG (the moving grey/misplaced patches)
LAW R-C froze `_slot_of(fid)` into tile vertices at build time — but **nothing ever refreshes a
committed tile when the slot map moves** (`request_refresh` exists; its only caller is the rim
drift check, `facet_far_ring.gd:612`). The shell re-emits on every epoch bump; the 209 smooth
meshes never do. So smooth-resident facets carry **launch-time slots forever**: −1/base (grey
wash) at first, and — worse — when a close-up/band LAYER is evicted and REUSED for another facet,
the stale UV2.y now points at **another facet's texture** (`_evict_closeup`'s comment,
`facet_tex_baker.gd:1043-1055`, explicitly assumes a "≤ 1-frame window before the re-emit" — true
for the shell, FALSE for smooth meshes, which never re-emit). Terrain patches that are grey or
belong elsewhere, moving whenever the layer carousel reassigns — **with `smooth_res` constant and
zero mesh rebuilds**. This is the exact "residency stable, content churns" signature.

### R3.1.e (plausible, unconfirmed live) S2↔S3 role oscillation
`_sticky_target` snapshots `_is_backstop` at crossing time (`facet_far_ring.gd:509`) but
`_rim_assign` reads `_excluded` LIVE every frame (:594). A pool-membership flap without a crossing
flips a facet S3↔S2 indefinitely: tier-swap builds, both tier meshes dirtied, resident count
unchanged. Not required to explain the capture; the Q1 idle gate + role hysteresis below covers it.

## R3.2 Root cause B — render-through / misalignment: two commit windows + one stale weld

### R3.2.a The tier-mesh transaction is split across frames (hole OR double-draw)
A commit that moves a facet between tiers dirties BOTH tier meshes
(`facet_smooth_tier.gd:601-612`) but `step()` rebuilds **at most ONE tier per frame**
(:632-636 `break`), in fixed order [S2,S3,S4,S5]. Demote S4→S5: S4 rebuilds first — the tile is
REMOVED from the drawn S4 mesh ≥ 1 frame before it appears in S5. The facet is still
`is_resident`, so the shell keeps excluding it (`facet_far_ring.gd:2113`) → **a hole straight
through to the sunk backstop** for ≥ 1 frame (more when several tiers are dirty). Promote S5→S4:
add lands first → ≥ 1 frame of **double-draw of two different-pitch surfaces** → z-fight /
interpenetration = "facets misaligned, rendering through". REV2's make-before-break held at the
residency level and leaked at the committed-mesh level — inside `step()`'s own commit path.

### R3.2.b The `_shell_gen` handshake race — a commit can "prove" a re-inclusion it never drew
`_mesh_inc_gate` marks a leaving facet with the CURRENT `_shell_gen` (`facet_far_ring.gd:566`) and
drops it once the gen advances (:569-572). But `_shell_gen` bumps at **every** commit (:1423 async,
:2069 sync) — including a commit of an async build whose `visible_fids` snapshot (:1302) was taken
BEFORE the marking, i.e. a mesh that **excludes** the facet. Sequence: build dispatched (facet
excluded) → facet marked leaving at gen G (`_pending` set, :567) → in-flight build commits →
gen G+1 > G → facet evicted → the drawn shell does not contain it → **hole until the next re-emit
lands** (the `_pending` from the marking is only served after the current build finishes —
`_async_building` gate). Window = up to a full async build round; and because re-emits are constant
during convergence (R3.1.b), leavings routinely coincide with in-flight builds.

### R3.2.c Frozen snap plans go stale → mixed-pitch cracks at tier boundaries
A tile's edge weld is frozen at request() and applied once at build
(`facet_smooth_tier.gd:525-537`, worker :673-680). When a NEIGHBOUR's committed tier later
changes, nothing refreshes this tile — its edge stays snapped to the old pitch → a T-junction
crack at the shared border. The only seal is the 4-block skirt (`SMOOTH_SKIRT_BLOCKS`,
`cube_sphere.gd:704`); relief steps across a 32-block-pitch S5 cell routinely exceed 4 blocks →
**see-through slivers** at tier frontiers. Combined with R3.2.a/b's double-draw of non-coincident
surfaces (CELLS=4 shell heightfield vs curved smooth tile), this is the full "misaligned +
rendering through" picture.

## R3.3 REVISION 3 laws (these are the acceptance criteria)

- **LAW Q (fixpoint-at-rest).** Every far subsystem exposes a terminal state and reaches it in
  bounded time with zero input. When terminal: O(1) per-frame checks, zero allocations, zero
  dispatches, zero commits, zero uploads, zero re-emits. Convergence work (skin bakes) must be
  monotone, disc-first, and **decoupled from geometry** — a skin commit may never force a mesh
  re-emit.
- **LAW T (transactional visual commits).** Any change to who-draws-a-facet lands atomically in
  ONE frame across every committed mesh involved (both tier meshes; tier mesh + shell). If it
  cannot be afforded this frame, the **swap is deferred whole** — never half-applied. Old surface
  stays until the new one commits, for refreshes and tier changes alike.
- **LAW S (stable mesh, live skin).** Geometry carries only STABLE keys (facet identity); volatile
  skin residency (slots) resolves per-fragment through a baker-updated indirection texture. A slot
  change costs one tiny texture update — never a re-emit — and can never go stale on ANY mesh.

## R3.4 Fixes (staged, flag-gated)

- **Q1 `FP_SMOOTH_IDLE` — driver idle-gating.** Assignment signature = (active_fid, excluded-set
  hash, leaving/dwell/refresh state). `_smooth_drive` skips dwell/gate/slot/request work when the
  signature is unchanged; `request()` early-outs (no `_snap_plan` rebuild) on an unchanged `_want`;
  `step()` keeps a `_settled` latch (set when reap + dispatch + dirty are all empty; cleared by any
  request-change/refresh/evict) and returns immediately when settled; the rim scan gates on
  `_player_col_abs` having moved ≥ 1 block; `_recompute_want_sse`/`_recompute_band_want_sse` get
  the same hold gate the angular path has (:835): axis ≥ hold_cos AND |Δcam_dist| < half a facet.
  Adds S2-role hysteresis (a facet's rim role changes only after N frames of stable pool
  membership) closing R3.1.e.
- **Q2 `FP_SLOT_INDIRECT` — kill mesh-baked slots (LAW S).** UV2.y carries the stable facet key; a
  6·K² (3456-texel) fid→(closeup slot, band slot) RG8 lookup texture is the ONLY thing epoch bumps
  update. `set_closeup_slots`/`set_band_slots` stop setting `_pending` (:3924/:3962). One additive
  texelFetch in the shell shader (ANGLE-safe, shared by smooth tiles via the shared material).
  This kills the biggest at-rest re-emit engine (R3.1.b) AND the stale/wrong smooth skin (R3.1.d)
  in one move — R-C's frozen-slot plumbing retires.
- **T1 `FP_SMOOTH_TXN` — transactional tier commits (LAW T).** (a) Tier-mesh concatenation moves
  OFF-THREAD: committed tiles are immutable, so a worker builds the merged tier arrays (with
  per-tile indices pre-offset — the R2 promise that never shipped; kills the per-element append
  loop `facet_smooth_tier.gd:707-708`), main pays only `add_surface_from_arrays` + assign — the
  proven `_async_build_worker`/`_swap_in_arrays` pattern. (b) A tier-change commit is HELD until
  both affected tier meshes' new arrays are ready, then both `mi.mesh` assignments land the same
  frame. Removes both the R3.2.a hole/double-draw and the O(tier)-on-main hitch (an S2 collar
  rebake today re-concatenates ~335k indices on main — the §7.1 cost's mesh half).
- **T2 `FP_SHELL_SNAP_GEN` — fix the handshake race.** Bump a `_snap_gen` where `visible_fids` is
  snapshotted (:1302 dispatch, :2049 sync); every commit records its build's snap gen.
  `_mesh_inc_gate` marks leaving with `mark = _snap_gen + 1` (the earliest snapshot that CAN
  include the facet) and drops only when `last_committed_snap_gen >= mark`. Tightening (with T1):
  perform the smooth evict + tier-mesh swap on the SAME frame as the shell commit that re-includes
  the facet — both commit points are main-thread in the same `_process`.
- **T3 neighbour-aware weld refresh.** When a facet's COMMITTED tier changes, any committed
  neighbour whose frozen snap pitch for the shared edge now differs gets a staggered
  `request_refresh` (≤ 4 per commit, bounded). The skirt returns to being the sub-pixel backstop,
  not the primary seal (closes R3.2.c).
- **Q3 skin-convergence bounding (honest scope).** Q2 stops skin commits forcing mesh work, but
  texture CONTENT still changes at rest until the sweeps converge — that is inherent. Bound it:
  disc-first ordering already exists (`_next_fine_fid` axis-nearest); add a `fine_disc_done` /
  `shot_disc_done` latch + telemetry, pause the fine `update_layer` cadence when no baked-visible
  content changed, and ride the planned C++ `sample_columns` fine bake (~10×) for wall-clock. Live
  criterion: **geometry bit-static immediately; skin monotone, visible-disc converged ≤ ~2 min,
  then bit-static.**

Ship order: **Q1 + T2** (cheap, immediate: idle driver + race fix) → **T1** (the hitch killer +
no-hole transaction) → **Q2** (re-emit killer + stale-skin fix; touches the shader, biggest test
surface) → **T3**; Q3 rides the existing C++-bake roadmap. Each stage independently gateable and
FLAT-verified.

## R3.5 The two new gates (non-vacuous, headless)

- **G-FS-QUIESCE (fixpoint-at-rest).** Small-K harness body (convergence reachable headless).
  Script: teleport to a LOW_ORBIT pose, freeze; pump frames until settle or a frame cap; then run
  N = 600 frames asserting **zero delta** on ALL of: smooth `dispatch_count` sum, a new tier-mesh
  rebuild counter, `_begin_rebuild_count`, `_shell_gen`, `_slots_epoch`, `band_epoch`, a new
  fine-upload counter, and a new `request()`-rebuilt-snap-plan counter. **Non-vacuity:** (a) assert
  every counter was > 0 during warm-up (the machinery demonstrably runs); (b) perturb — cross one
  facet — assert the counters move, re-settle, re-assert all-zero. Any future regression that
  re-introduces per-frame work fails the delta, not a heuristic.
- **G-FS-NOHOLE (strengthens G-FS-COVER to committed meshes + boundaries).** Scripted churn path
  designed to provoke every window: tier promotes AND demotes, dwell-expiry leavings, rim
  refreshes, and a slot-epoch bump injected mid-async-build (the T2 race). Every frame assert:
  (1) **coverage** — every front facet ∈ (the shell's last COMMITTED emit set) ∪ (fids present in
  the CURRENT committed tier ArrayMeshes, via a new `gate_meshed_fids()` maintained exactly at
  `_rebuild_tier_mesh` commit) — residency dicts are explicitly NOT evidence; (2) **exclusivity** —
  the intersection is empty except facets inside a `_smooth_leaving` window bounded by T2;
  (3) **boundary** — sampled committed-tile edge verts vs the committed neighbour (tile or shell
  chord) differ ≤ ε radially. **Non-vacuity:** run the same script with T1/T2 forced OFF and assert
  the gate FAILS — the hole and the race are deterministic under the script, proving the gate sees
  them.

## R3.6 Verdict

**YELLOW, converging GREEN — the REV2 per-tier incremental model CAN reach quiescence; no new
rendering model is needed.** The residency law works (constant 209 proves it). What fails is
(1) slot-in-vertex coupling that welds the skin pipeline to mesh re-emits, (2) drivers with no idle
state, and (3) a commit model whose transactions span frames plus a gen-counter race — all fixable
inside the model. **One structural change is non-negotiable: tier-mesh assembly must leave the main
thread (T1).** Without it LAW T is unaffordable and the model degenerates to choosing between holes
and hitches; the per-facet-MeshInstance alternative is rejected (≈ +289 draws against the ~204-draw
GL-compat ceiling). Separately and bluntly: even fully quiesced, the S2 collar's §7.1 BAKE cost
(~174k `profile_at_dir` at 104 cells per facet, re-baked per 24 blocks of walk) is untouched by
this revision — T1 removes its mesh-concat half only; the bake half stays on §7.1's own plan
(ENV_FINE_MULT 4→2, crescent-incremental, C++ port). And the whole-planet skin sweeps mean the
planet repaints for minutes regardless — Q2 makes that cheap and Q3 makes it bounded and visible in
telemetry, but only the C++ fine bake makes it short.

---

# REVISION 4 — live triage: white far (Q2 shader parse-kill), no rest fixpoint, night lighting (2026-08-04, Fable)

Three live failures against the REV3 ship, all root-caused to exact lines. All file refs are
`godot/src/world/…` in worktree `deploy-cheats` unless stated.

## R4.1 Problem 0 (TOP): far terrain renders solid WHITE — Q2's splice KILLS the whole far shader

**Root cause — the Q2 fragment splice is ILLEGAL Godot shader language; the entire assembled
far-ring shader fails to PARSE on any real renderer, and the far ring falls back to the engine's
default (white, unshaded-by-our-law) material.**

- `_apply_slot_indirect` (facet_far_ring.gd:3959-3978) inserts, at the top of `void fragment()`,
  `v_slot = _slot_indirect(v_slot);` / `v_bslot = _slot_indirect(v_bslot);` (lines 3972-3976).
- `v_slot` and `v_bslot` are **varyings assigned in `vertex()`**: `v_slot = UV2.y;`
  (facet_far_ring.gd:3636) and `v_bslot = UV2.y;` (3755, 3868, 3874).
- Godot forbids exactly this. Engine source (the custom 4.4.1 tree we ship,
  `docker/engine/cache/godot/servers/rendering/shader_language.cpp:5365-5369`,
  `_validate_varying_assign`): a varying with `STAGE_VERTEX` assigned in `fragment` is a hard
  parse error — *"Varyings which assigned in 'vertex' function may not be reassigned in
  'fragment' or 'light'."*
- Consequence live (GL compatibility/ANGLE): `shader_set_code` parse fails → the ShaderMaterial is
  invalid → the MeshInstance renders with the renderer's default fallback material — **white
  albedo, vertex COLOR ignored, and every in-shader law dead**: the `v_st` day/night/terminator
  shade, FP_SHADE_UNIFIED/voxi_shade, FP_SMOOTH_NORMAL_LIT, the band/fine/flat-colour skin
  sampling. That is the observed picture in one stroke: far = uniform light-grey/white on
  non-snow terrain, in daylight AND at night, while the near (its own separate materials) stays
  correct. The smooth tiles share this ONE material (`setup_instance` passes
  `_mi.material_override` through), so they are equally white.
- **Why every gate was green:** headless runs the DUMMY RenderingServer — `shader_set_code`
  stores the string and never parses. The Q2 gate (`verify_far_smooth.gd`
  `_gate_slot_indirect_shader`) is a golden-STRING pin; string equality can never see a
  stage-rule violation. On a live browser the error IS printed to the JS console — nobody was
  looking for it.

Secondary latent defects in the same splice (fix while in there):
- **Truncation decode:** `_SLOT_INDIRECT_UNIFORMS` (3950-3957) computes
  `int(mod(fid, w))`/`int(floor(fid / w))` with NO rounding. A varying, even one constant across
  a triangle, is reconstructed per-fragment by barycentric interpolation — at fid≈3455 a
  few-ulp undershoot (3454.9997) flips both the `mod` and the row → wrong texel. Every shipped
  decoder in this family already rounds (`int(v_bslot + 0.5)`, 3698/3722); Q2's doesn't.
- The comment's fear of vertex-stage texture fetch (3942-3944) is unfounded on our target:
  WebGL2/GLES3.0 mandates `MAX_VERTEX_TEXTURE_IMAGE_UNITS ≥ 16`. There is no reason to resolve
  in fragment at all.

**Fix (Q2', flag-gated same FP_SLOT_INDIRECT — replaces the broken splice):** resolve in the
**vertex stage**, where assigning the varying is legal and the fid is exact:
- Splice targets the VERTEX assignments instead of `fragment()`:
  `v_slot = UV2.y;` → `v_slot = _slot_indirect(UV2.y);` (and the `v_bslot` twins; when both
  exist they share one fetch). Fragment code is untouched — the varying now carries the
  *resolved slot* (small magnitude, and downstream already decodes with `int(x + 0.5)`).
- Integer-exact decode with rounding:
  `int f = int(fid + 0.5); int w = int(slot_map_w + 0.5); texelFetch(slot_map, ivec2(f % w, f / w), 0).r;`
  plus a defensive `if (fid < 0.0) return -1.0;`.
- LAW S is preserved: a slot-map change still touches only the lookup texture
  (`_push_slot_indirect`), and the vertex stage re-reads it every frame — no re-emit, ever.
- Rollback lever (if anything still looks off live): export with FP_SLOT_INDIRECT **off** —
  UV2.y carries the REV2 baked slot again (correct colours at the cost of slot-change re-emits).

## R4.2 Problem 1: the far ring never quiesces at rest (sh_reemit climbs, sh_build true, ~30 fps)

**Root cause — two convergence predicates disagree with the ONE emit predicate, so the "settled"
fixpoint does not EXIST; the ring re-emits forever.** The emit law excludes smooth-resident
facets (`visible_fids()`, facet_far_ring.gd:2236: skip when
`_smooth.is_resident(fid) and not _smooth_leaving.has(fid)`). Two drivers never adopted that law:

1. **`_noblack_guarantee` — a `_pending = true` EVERY frame.** facet_far_ring.gd:1241:
   `if built_now or new_unsink != _noblack_unsink_fid or not _emitted.has(fid): _pending = true`.
   Under FP_SMOOTH_RIM the ACTIVE facet is S2 smooth-resident → permanently excluded from every
   emit → `_emitted.has(fid)` is false after every commit → `_pending` re-arms each frame → a
   continuous `_begin_rebuild` train (`sh_reemit` climbing, `sh_build` true, one whole-front
   worker build + main-thread `_swap_in_arrays` mesh upload per cycle = the 60-100 ms frames and
   the ~10/s hitch counter). Two subsystems each enforce a private invariant — never-black says
   "active must be in the emitted set", the exclusion law says "a smooth-resident facet never
   is" — and the composition has no fixpoint.
2. **`_surface_converge_emit`'s env loop — a dispatch every ENV_RESUME_MS (300 ms) forever.**
   facet_far_ring.gd:1179-1189: `remaining = _count_uncached_visible(p)`; converged only at
   `remaining == 0`. But `_count_uncached_visible` (1332-1352) has NO smooth exclusion, while
   the worker only warms fids in `_async_fids = visible_fids(...)` (1416) — which excludes them
   (2236). Worse, the smooth hop-ring (S3 = hops 1-2) coincides with the FP_MID_DENSE ring-2
   disc (`_recompute_mid_dense`, 2083-2108), so those facets are DENSE targets
   (`_dense_warm`, 1696-1699) counted by `_benv_done` — which can never be set for them.
   `remaining > 0` forever → `_srf_converged` never latches → the idle short-circuit (1167,
   1191) never engages.

**`setpoint_ms: 31.5` is a misread, not a cost.** stream_load_controller.gd:136-139: the
telemetry field is the ADAPTIVE overload *threshold* = `floor_p10 × CTRL_ADAPTIVE_MARGIN (2.0)`.
31.5 means the churn degraded the client's own p10 frame floor to ~15.7 ms and the adaptive law
then legitimized ~31 ms frames (never flags overload, never sheds). The controller's per-tick
cost is a bounded window sort — trivial. It is a *symptom amplifier* (it chases the degraded
floor), and it recovers by itself once the ring quiesces. No controller change.

**Fix (FP_RING_QUIESCE, default off = byte-identical): ONE emit-role predicate, used by
everything that reasons about the emitted set.**
- Factor `_smooth_covered(fid) := _smooth != null and _smooth.is_resident(fid)
  and not _smooth_leaving.has(fid)` out of visible_fids:2236 (single definition).
- `_noblack_guarantee`: a smooth-covered active facet counts as DRAWN — the committed S2 tile IS
  the opaque cover, strictly better than the sunk backstop. Condition becomes
  `… or (not _emitted.has(fid) and not _smooth_covered(fid))`; also skip the chord build and
  the unsink probe while covered. (The never-black invariant is *"active facet is covered by
  shell OR smooth"*, not "by shell".)
- `_count_uncached_visible` / `_count_uncovered_visible`: `continue` on `_smooth_covered(fid)` —
  the counter counts exactly what the emit can serve, nothing else.
- Result at rest: `remaining` reaches 0, `_srf_converged`/`_orbit_converged` latch, `_pending`
  stays false, per-frame far-ring cost = the Q1 idle-signature check + two dict probes ≈ 0.
  The REAL invariant of the brief holds: zero `_rebuild_full`/`_dispatch_async_rebuild`/
  `set_pending(true)` calls after settle.

## R4.3 Problem 2: far bright at night while near goes dark

Layered — fix in this order:
- **C-1 (dominant, live): identical root cause to R4.1.** With the shader parse-dead, the far
  ring ignores `sun_dir`/`night_floor` entirely (the default fallback material knows nothing of
  our sun) → white AND full-bright at night. Fixing R4.1 restores `voxi_shade` (voxi_light.gd:
  50-55) whose near/far parity at the same world point is already proven by construction
  (G-VL-EQ) — the far snow goes dark exactly as the near does, and the orbit view keeps the lit
  hemisphere + terminator (same radial law at every altitude; the regime needs NO altitude
  switch — FP_SHELL_ABSOLUTE's in-shader law is correct at the surface too, that was V1's
  whole point).
- **C-2 (residual, only if FP_SMOOTH_NORMAL_LIT is in the live export):**
  `_apply_smooth_normal_lit` (facet_far_ring.gd:3927-3932) substitutes the RELIEF normal into
  the ONE `mu = dot(n, sun_dir)` that voxi_shade uses for BOTH the day/night/terminator gate AND
  slope shading. At night the sun is below the *radial* horizon (near blocks: dark, they key off
  the planet-radial normal via `planet_centre`), but a smooth-tile slope tilted toward the sun's
  azimuth still gets `mu > 0` → day-lit patches at night, and a shifted terminator on relief.
  **Fix: a two-normal law** `voxi_shade_rel(up, n_rel, sd)`: shade/tint/night-floor from
  `mu_up = dot(up, sd)` (byte-identical to the near law), relief only as a bounded, DAY-GATED
  modulation `rel = mix(1.0, clamp(dot(n_rel,sd)/max(mu_up,ε), REL_MIN, REL_MAX), _day(mu_up))`
  multiplied into the result. At night `rel → 1` ⇒ far ≡ near exactly; from orbit the
  terminator is untouched (radial gate unchanged) — the altitude-dependence the brief asks for
  falls out with zero regime switch. Splice change: keep `n` radial always; pass the relief
  normal as the SECOND argument in the COLOR.a branch instead of replacing `n`.

## R4.4 Gates — what would have caught each of these headless

- **G-FS-VARY-STAGE (new, headless, catches R4.1's whole class).** For EVERY shader string the
  material factory can assemble (all flag combinations of `_make_material`'s splice chain),
  brace-scan the `vertex()` and `fragment()` bodies and assert **no declared varying is assigned
  in both**. Pure GDScript string analysis — runs on the dummy renderer. Golden-string equality
  pins content; this pins LEGALITY.
- **G-FS-SHADER-COMPILE (Tier A, native).** Instantiate every assembled material under the real
  GL renderer (the Xvfb+llvmpipe harness, memory `voxiverse-gpu-headless-testing`) and assert
  zero shader errors in the engine log. `--headless` can NEVER do this (dummy RS does not
  parse) — that is exactly how Q2 shipped gate-green. Until Tier A is wired, the cheap live
  check is: open the browser console; the parse error is printed verbatim.
- **G-SLOT-DECODE (headless).** GDScript twin of the GLSL decode: for fid 0..3455 AND fid±0.49
  perturbations, assert `round-then-%/÷` returns (fid % 64, fid ∕ 64) exactly, and the texel
  round-trips `_live_slot_of(fid)` through `_slot_img`.
- **G-FS-QUIESCE-RING (new, replaces G-FS-QUIESCE's blind spot).** REV3's gate counted the
  SMOOTH DRIVER's counters (request()/_snap_plan, baker wants) — the shell emit path and the
  noblack/env counters were out of scope, which is precisely where the loop lived. New gate, on
  a real FacetFarRing at a fixed active facet with forced S2+S3 smooth residency and env caches
  driven to the fixpoint: settle, then over N=240 frames assert **zero delta** on
  `_begin_rebuild_count`, `_reemit_count`, `_shell_gen`, `sh_pend == false` every frame, AND
  `_count_uncached_visible(p) == 0` (the fixpoint EXISTS — this single assert was the missing
  one). Falsification: force FP_RING_QUIESCE off and assert `_begin_rebuild_count` CLIMBS under
  the identical scenario (the shipped bug reproduces — non-vacuous). Headless measures CALL
  COUNTS, never fps — per the brief. Standing live check: `sh_reemit` delta/minute ≈ 0 at rest
  in the remote-bridge telemetry.
- **G-FS-NIGHT-PARITY (headless, for C-2).** Numeric sweep on the GDScript twins: for all
  `mu_up ≤ −term_mu` and a fan of relief normals (incl. steep sun-azimuth-facing),
  `shade_tint_rel(up, n_rel, sd) == shade_tint(up, sd)` exactly; plus a shader-string assert
  that the `_day(`/night gate consumes the RADIAL-derived mu (the `normalize(wp - centre)` term
  must remain voxi_shade's first argument in the spliced smooth branch).

## R4.5 Staged plan + verdict

| Stage | Content | Flag | Gate |
|---|---|---|---|
| A (ship first) | Q2' vertex-stage slot resolve + rounded decode | FP_SLOT_INDIRECT (fixed impl) | G-FS-VARY-STAGE + G-SLOT-DECODE (+ live console check) |
| B | ring quiescence: `_smooth_covered` predicate into noblack + the two counters | FP_RING_QUIESCE | G-FS-QUIESCE-RING (falsified both ways) |
| C (only if night-glow persists after A is live-verified and FP_SMOOTH_NORMAL_LIT is on) | two-normal `voxi_shade_rel` | FP_SMOOTH_NORMAL_LIT (fixed impl) | G-FS-NIGHT-PARITY |

**Verdict: GREEN for A and B, YELLOW for C.** A is proven from engine source (a parse-rule
violation, deterministic); B is a structural predicate mismatch whose fix re-uses the already-
shipped idle machinery (`_srf_converged`/Q1) — both are surgical, no redesign. C is conditional:
C-1 is expected to vanish with A (verify live at night BEFORE writing C's code); C-2's fix is
designed and orbit-safe by construction but should not ship blind. Meta-lesson, stated once: a
quiescence gate must assert that the **fixpoint exists** (the convergence counter reaches zero
under the same predicate the emitter uses) and a shader gate must assert **legality on a real
parser**, not string identity — both failures were gate-shaped, not code-shaped.
