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

# REVISION 5 — rest quiescence COMPLETION: the residual re-emit train + the perpetual bake worker (2026-08-04, Fable)

Live post-REV4 rest signals (player frozen, alt ~105, skin baked, daylight): `sh_pend False`
(Stage B's noblack fix WORKS — the per-frame `_pending` re-arm is dead) but `sh_begin`/`sh_reemit`
still climb ~0.75/s, `sh_build True` persistently, `pbm_busy 1` continuously, `proc_ms 76-106`,
fps 30-44. Colour/lighting correct (REV4 Stage A verified) — this revision is pure work-shedding.

## R5.1 Residual 1 — the remaining `_begin_rebuild` caller at rest

**The caller is `facet_far_ring.gd:1187` — `_surface_converge_emit`'s FP_ENV_FLOORED_ASYNC
branch (`:1166-1189`), dispatching on `remaining > 0` (`:1179-1185`).** `sh_pend False` +
climbing `sh_begin` uniquely identifies it: it is the ONLY floored-regime dispatch that fires
with `_pending` false. The ENV_RESUME_MS(300)/`ENV_RESUME_PACED` throttle never binds — each
dispatch's worker task (`_async_build_worker`) takes ~1.3 s on web, and `_process` early-returns
while `_async_building` (`:1077`), so the cadence IS the build time: ~0.75/s. `sh_build True`
persistently is the same fact.

**Why the convergence predicate never latches (in a practical session).** At the floored
surface the emit cap is floored to θ_emit = 90° (`shell_set_camera_abs`, `:927-928`) →
`_front_visible` admits the FULL hemisphere: **~1728 facets** (minus ~200 smooth-covered ≈
1500). Under the live flag set (FP_ENV_FALLBACK_EMIT + FP_ENV_FLOORED_ASYNC),
`_count_uncached_visible` (`:1353-1378`) counts every one of them until it is **fully
min-enveloped** — `_env_done` (set only in `_ensure_cached`'s env_all branch, `:2565-2571`,
via `_env_weld_grid(fid, 4)` ≈ 289 fine samples + boundary canon ≈ 10-40 ms/facet on a web
worker) or `_benv_done` for dense targets (`:2655-2659`, `_env_weld_grid(fid,16)` ≈ 4k samples
— "can eat a whole frame's budget by itself", cube_sphere.gd:421). Supply is
`ENV_WARM_BATCH := 12` per dispatch (facet_far_ring.gd:33). So convergence needs
**~125 dispatch cycles**, and — the structural flaw — **warm and emit are FUSED**: the ONLY way
to warm 12 env caches is `_begin_rebuild` → a full ~1500-facet SurfaceTool re-emit +
`generate_normals` on the worker + a main-thread `_swap_in_arrays` upload (`:1560+`) per cycle.
Each cycle ALSO contends with the perpetual fine-map bake (R5.2) on the SAME 1-2-thread web
WorkerThreadPool (both `add_task(..., false)` = low priority, FIFO). Net: the latch is
mathematically reachable but its horizon is **many minutes per floored engage** (and every
descent/teleport/regime flip replays it), during which the ring re-emits ~0.75/s and the main
thread pays a whole-hemisphere mesh upload per cycle. That IS the live residual.

**Fix — two flags, independently shippable:**
- **R5.A `FP_ENV_DEMAND_DISC` — bound the convergence SET.** The min-envelope is a
  no-protrusion lower bound **against the NEAR field**; a facet with no near field over it has
  nothing to protrude through — its exact chord (already ε-sunk / skirted, the pre-env shipped
  surface) is its correct TERMINAL state. Near meshes exist only within
  `near_render_radius + RIM_STREAM_MARGIN` of the player (the §2.1 invariant), i.e. inside
  backstop ∪ mid-dense ∪ a couple of rings. So: in `_count_uncached_visible` /
  `_count_uncovered_visible` and the worker's warm loop, demand env ONLY for
  `_dense_warm(fid) or hop(fid, active) <= ENV_DEMAND_RINGS` (const := MID_DENSE_RINGS + 2);
  every other front facet counts DONE once `_pos_cache.has(fid)` (chord). Floored `remaining`
  drops ~1500 → ≤ ~40 ⇒ **≤ 4 dispatches to latch**. Strictly less work + smaller `_env_done`
  ⇒ NEVER-OOM by construction. (ORBIT keeps its existing law — off-surface there is no near
  field at the ground, envelopes there are only used AS the drawn surface; unchanged.)
- **R5.B `FP_WARM_EMIT_SPLIT` — decouple warm from emit.** When the only dispatch reason is
  env upgrade (`remaining > 0`, `_pending` false), dispatch a **warm-only** worker task: same
  `_async_building` single-writer gate, same task/poll machinery, but skip the SurfaceTool
  emit / `commit_to_arrays` / `_swap_in_arrays` entirely (an `_async_warm_only` mode in
  `_async_build_worker`). Re-emit the mesh only on `_pending` or when env progress crosses
  `ENV_REEMIT_GROWTH` (default: once, at `remaining == 0`) — env upgrades only adjust heights
  of already-drawn chords (sub-pixel at those distances; ε sink + skirts hold meanwhile).
  Kills the per-cycle whole-hemisphere rebuild + GPU upload even where demand is legitimately
  large (orbit env warm benefits too).

**Hygiene (found while tracing, fix in R5.B's commit):** `_cull_update()` runs at `:1062`,
BEFORE the `_async_building` early-return (`:1077`), while the floored worker **erases**
`_bpos_cache`/`_benv_done` mid-task (`:1521-1523`, `:1528-1530`) — a main/worker Dictionary
race (`_cull_cell_aabb` reads `_bpos_cache[fid]`, `:2033+`). Fix: the worker builds into
locals and REPLACES via single assignment (pass a `force` flag instead of the transient
erase), and/or move the cull probe behind the `_async_building` gate like every other
cache-touching driver already is (`_noblack_guarantee` at `:1090` is past it; the cull is not).

## R5.2 Residual 2 — the perpetually-busy bake worker (`pbm_busy 1`)

**The source is the FP_PLANET_MAP whole-planet FINE-tier dispatch loop,
`facet_tex_baker.gd:1832-1849`.** `tex_baked 3456/3456` is `_baked` (the g0 BASE pages,
`tex_telemetry`, `:2027`) — it says NOTHING about `_fine_baked`, which has **no telemetry
field at all** (the blind spot). On-surface, `:1846-1848` force `_pbm_cpp = 0` and
`_pbm_tile = 0` (both gated on `_offsurface`) → `_pbm_compute` falls to the per-texel
GDScript path (`:1953-1983`): PLANET_MAP_TEXELS=64 → 4096 `facet_profile` samples/facet ≈
1-2 s/facet on a web worker × up to 3456 facets ≈ **hours**. The on-surface slot cap
(`active = 1`, `:1773`) makes it exactly ONE continuously-busy slot = the observed
`pbm_busy 1`. It never drains at rest because the dispatch loop refills the slot the frame
the reap empties it. Beyond occupancy, the worker's per-texel GDScript allocation convoys
the WASM allocator with the main thread (the measured walk-perf mechanism, memory
`voxiverse-walk-perf-root-cause`) — a first-order suspect for the erratic 76-106 ms
`proc_ms` at rest — plus the `_fm_tex.update_layer` page upload every ≤15 frames (`:1855-1861`)
and the per-commit `blit_rect` land on main.

**Fix — R5.C `FP_FINE_BAKE_SURFACE_PAUSE`.** Gate the fine dispatch loop (`:1832`) on
`_offsurface` (or: `_offsurface or (near-streamer settled and _pbm_tile_ok)` if we later want
opportunistic native on-surface baking; ship the simple form first). Rationale: the fine tier
is 6.5 blocks/texel — an orbit/far feature; on-surface everything in sight is covered by
band/skin/smooth at higher fidelity, and the on-surface path is BOTH 10× slower (GDScript)
AND the allocator-convoy worst case. Coverage resumes on the next off-surface excursion at
the C++ tile path's ~10× rate on all 4 slots. Un-fine facets on-surface render exactly the
pre-Item-A shipped look (base-page colour) — the alpha-coverage law already handles un-baked
= shipped, never black. Add `fm_baked`/`fm_want`(=`_base_all`)/`fm_dirty` to
`tex_telemetry()` so this class of "invisible background sweep" can never hide again.

## R5.3 §7.1 wired — the S2 collar cost (warmup 405 ms spike + walk rebake expense)

`build_tile_rim` → `_env_weld_grid(fid, 104)` at ENV_FINE_MULT=4 = 417² ≈ **174k
`profile_at_dir`/facet** on the worker (facet_smooth_tier.gd:194). Wire the §7.1 ladder as
**R5.D `FP_RIM_CHEAP`**:
- **(i) `RIM_FINE_MULT := 2` (web: 1)** for the S2 call only: 174k → 43k (11k web) samples.
  The envelope stays a PROVEN lower bound by compensation: a coarser fine grid can only MISS
  low columns (env too HIGH = protrusion risk), so subtract `RIM_ENV_RESID` — the measured
  node-wise max of `env@mult4 − env@mult2` over a facet fan + 1 block — from the S2 heights.
  `dil = ceil(skew/fine_pitch)` (`:2875`) already rescales with the coarser pitch. Gate
  G-RIM-MULT asserts `env@mult_low − RIM_ENV_RESID ≤ env@mult4` node-wise (falsified by
  setting RIM_ENV_RESID = 0 on a mountain facet).
- **(ii) crescent-only rebake.** Cache each S2 tile's node-height array
  (`_rim_nodes[fid]`: 105² f32 ≈ 44 KB × ≤ SMOOTH_S2_MAX(9) ≈ 0.4 MB — fixed, NEVER-OOM).
  On a drift-triggered `request_refresh` (player moved > RIM_REBUILD_BLOCKS), recompute
  `_env_node_min` ONLY for nodes whose distance-to-column crossed the
  `[R_env − feather − drift, R_env + feather + drift]` annulus between the old and new baked
  columns (membership can't change outside it — the blend weight is a pure function of that
  distance); reuse cached heights elsewhere; ALWAYS recompute boundary nodes (cheap 1-D
  canon) so the cross-facet weld stays bit-equal. Worst case at drift 24 ≈ 10-15 % of nodes.
  Gate G-RIM-CRESCENT: crescent rebake ≡ full rebake at the same column, node-array
  byte-equal (run at cells=24 for speed — the law is resolution-independent).
- **(iii) escape hatch (unchanged §7.1 iv):** if the live A/B still can't hold walking pace,
  FP_SMOOTH_RIM off + `BACKSTOP_CELLS 16→32` — shipped machinery, one const, ~70 % of the
  visual win at 4k samples/facet.

## R5.4 Gates — why G-FS-QUIESCE-RING missed the live loop, and the replacement

REV4's gate (verify_far_smooth.gd `_gate_quiesce_ring`, `:2128`) missed for three reasons:
1. **Wrong regime:** it drove `_orbit_warm_async` with `_emit_floored_last = false`; the live
   rest loop is `_surface_converge_emit`'s FLOORED env branch (`:1166-1189`), which it never
   called.
2. **Wrong counting law:** it ran under the repo's default consts (FP_ENV_FALLBACK_EMIT /
   FP_ENV_FLOORED_ASYNC / FP_ENV_ALL false — the ENV flags have no gate-forcing params in the
   counters), so `_count_uncached_visible` degraded to `_pos_cache.has()` — pre-satisfied by
   `setup()`'s synchronous `_rebuild_full()`. The live `_env_done`/`_benv_done` demand never
   executed headless: `remaining == 0` held by construction.
3. **Fixpoint-existence only:** it asserted zero-delta AT the fixpoint, never the
   **reachability bound** from a cold floored engage (empty env dicts, chords only) — which
   is the state every live descent lands in.

**G-FS-QUIESCE-SURF (new; keep -RING for orbit):**
- Add gate-forcing params (`fallback_on`, `floored_async_on`) to the two counters +
  `_surface_converge_emit` + the worker's `have` test, mirroring the existing `quiesce_on`
  convention, so the LIVE counting law runs headless without a const sed.
- Cold floored engage on a real ring (`_cam_set`, `_emit_floored_last = true`, empty
  `_env_done`/`_benv_done`): pump `_surface_converge_emit` + a synchronous stand-in for the
  worker cycle; assert `remaining` latches to 0 within `ceil(demand/ENV_WARM_BATCH) + 2`
  dispatches, `_begin_rebuild_count` delta ≤ that bound, and `_reemit_count` delta ≤ 2
  (R5.B: one initial + one final emit).
- Then the 240-frame zero-delta window on the counters that actually climbed live:
  `_begin_rebuild_count`, `_reemit_count`, `_shell_gen`, `sh_pend` false every frame,
  `remaining == 0` stable.
- **Falsify both ways:** demand-disc forced off → the cold-engage dispatch count exceeds the
  bound (~`ceil(1500/12)`) — the live bug reproduces; split forced off → `_reemit_count`
  climbs with every warm batch.
- **G-TEX-SURF-PAUSE:** baker `update()` on-surface with `_fine_baked` incomplete dispatches
  ZERO fine tasks (slot drains after the in-flight reap; `_pbm_busy_count()` → 0) and
  resumes off-surface; falsified with the flag off. Assert `fm_baked` present in
  `tex_telemetry()`.
- **Standing live check (remote bridge):** over 60 s at rest — Δ`sh_begin` = Δ`sh_reemit` = 0,
  `pbm_busy` = 0, `sh_build` false ≥ 95 % of samples, `sh_envN`/`sh_benvN` static.

## R5.5 Staged plan + verdict

| Stage | Content | Flag | Gate |
|---|---|---|---|
| C (ship first — biggest instant win, trivial) | fine-bake surface pause + fm telemetry | FP_FINE_BAKE_SURFACE_PAUSE | G-TEX-SURF-PAUSE |
| A | env demand disc (floored convergence set ≤ ~40) | FP_ENV_DEMAND_DISC | G-FS-QUIESCE-SURF (+falsify) |
| B | warm-only dispatch, emit decoupled (+ cull/worker cache-race hygiene) | FP_WARM_EMIT_SPLIT | G-FS-QUIESCE-SURF reemit bound |
| D | S2 collar: RIM_FINE_MULT + crescent rebake (escape hatch: §7.1 iv) | FP_RIM_CHEAP | G-RIM-MULT + G-RIM-CRESCENT |

**Verdict: GREEN for C, A, B; YELLOW for D.** C is a dispatch gate on a background sweep whose
on-surface value is nil and whose cost is measured (the fine-bake perf wall + the WASM
allocator convoy are both memory-documented). A is a counting-law change justified by the
envelope's own purpose (a lower bound needs a near field to bound against) — strictly less
work, falsifiable, flag-gated. B reuses the existing task/poll/single-writer machinery minus
the emit — surgical. D(i) is YELLOW until G-RIM-MULT pins RIM_ENV_RESID on real terrain;
D(ii) is YELLOW on implementation care at the annulus boundary but its gate is byte-
equivalence (the strong form). Acceptance = the brief's invariant verbatim: at rest with skin
baked — ZERO shell re-emits, ZERO bake-worker tasks, `proc_ms` ≈ the pre-smooth baseline, and
the warmup S2 bake paced/coarsened so fps stays > ~30 throughout. Meta-lesson this round: a
convergence gate must run the **live flag configuration's** predicate (gate-forcing params on
every flag the predicate branches on) and must bound **time-to-latch from the cold state**,
not just verify the warm fixpoint; and every background sweep needs a telemetry field — a
worker that is busy with work no counter names is invisible until it costs 30 fps.

---

# REVISION 6 — C++ smooth-tile-height bake (`FP_CPP_SMOOTH_BAKE`) (2026-08-04, Fable)

The tier is **correct and quiescent at rest** (R2–R5), but the WARMUP is unplayable: every
smooth tile's per-node heights are computed in GDScript — `FacetSmoothTier.build_tile`'s
node loop calls `FarDensity.node_at` once per node (`(cells+1)²` = 2 809 at S3, 11 025 at
S2), each `node_at` = one interpreted `TerrainConfig.profile_at_dir` (5 noise samples + the
height/mountain math) **plus a per-node Dictionary alloc**, and the boundary-normal pass adds
`4 · (4·cells)` more `profile_at_dir` calls (832 at S3). On web that per-node allocation
traffic convoys the WASM dlmalloc against the main thread ([[voxiverse-walk-perf-root-cause]])
— the exact wall only the C++ port (`FP_CPPGEN`, patch 0007) ever solved for the voxel path,
and that `bake_far_tile` (patch 0011, `FP_CPP_TILE_BAKE`) solved for the far SKIN this
session. REVISION 6 applies the SAME proven pattern to the smooth tier's HEIGHTS: **one
marshalled native call per tile**, byte-equal to the GDScript, behind `FP_CPP_SMOOTH_BAKE`.
This is a perf port of an already-correct computation — no geometry law changes.

## R6.1 The native method (patch 0012, `VoxelGeneratorCosmos`)

ENTRY POINT 5, alongside `sample_columns`/`bake_far_tile` (const, one `RWLockRead` per call,
thread-safe from WorkerThreadPool exactly like both):

```cpp
// The whole FarDensity.node_at grid for one tile in ONE call. Pure function of its
// arguments + the frozen noise Parameters — no fid, no atlas lookup: the caller passes
// FacetAtlas.facet_corner_dirs(fid) (12 f64, canon corners 00,10,11,01) and r_of(fid)
// verbatim, so the P0 canon-dir weld law is inherited, not re-derived.
Dictionary bake_smooth_tile(PackedFloat64Array corner_dirs, double r_datum, int cells) const;
```

Returns (all sized `n = (cells+1)²`, row-major `vi = gj·stride + gi`, `stride = cells+1`,
node params `s = gi·inv`, `t = gj·inv` with `inv = 1.0/double(cells)` — the EXACT GDScript
grid law, never `gi/cells`):

| key | type | content (byte-equality construction vs `far_density.gd`) |
|---|---|---|
| `"dir"` | PackedVector3Array | `node_at`'s `dir`: f64 bilerp of the canon corner dirs (same term order `v00(1-s)(1-t)+v10·s(1-t)+v11·s·t+v01(1-s)t`, indices 0/3/6/9), `ln = sqrt(ex²+ey²+ez²)` f64, degenerate guard `ln <= 0 → (0,1,0)`, divisions f64, THEN `Vector3(dx,dy,dz)` f32-narrow at construction — identical to GDScript's narrow point |
| `"g"` | PackedInt32Array | `int(prof.x)` of `profile_at_dir(p, dx, dy, dz, r_datum)` called with the **f64 pre-narrow** dx/dy/dz (as GDScript does) — the C++ `profile_at_dir` is the already-gated 0007 port, byte-equal by construction |
| `"biome"` | PackedInt32Array | `int(prof.y)` |
| `"temp"` | PackedFloat32Array | `prof.w` (the f32 component verbatim; GDScript's f64 widen on read reproduces the same value) |
| `"bnrm"` | PackedVector3Array | `FarDensity.boundary_normal(dir[vi], r_datum)` for **perimeter** vi only (interior = Vector3()); see R6.2 |

**Refusal (0008 inert-but-well-formed pattern):** empty Dictionary when `!_params.ready`,
`corner_dirs.size() < 12`, `cells <= 0`, or `cells > 512` (S2=104 is the real max; the cap
blocks a bogus giant alloc). The generator stays fully functional for voxels either way.

**Fields native vs GDScript-finished.** Native = exactly the convoy: the bilerp+normalize,
the `profile_at_dir` sample, and the boundary-normal stencil (each a per-node interpreted
worldgen chain + Variant/Dictionary churn today). GDScript cheaply finishes everything that
is pure arithmetic over the returned arrays, **verbatim from today's code** so it cannot
diverge: `relief = maxf(0.0, float(g − SEA_LEVEL)) * RELIEF` (f64, exact — small-int inputs),
`planar = dir·r_datum`, both `pos` branches (`curved`/`node_at`-pos), `uv`/`uv2`, the
interior central-difference normals over the FINAL pos grid, and the colour
(`FarPalette.color_for(g, biome, temp, g < SEA_LEVEL)` — kept GDScript **deliberately**: the
native `far_color` now carries the `skin_block_exact` per-column branch, which needs integer
(x,z) columns that smooth (s,t) nodes don't have; routing colour through it would be a
divergence trap, and 2 809 branch-only `color_for` calls allocate nothing).

Private statics inside the module (mirroring 0011's structure): `smooth_node(p, cd, r_datum,
s, t, …)` (= `node_at` minus the Dictionary) and `smooth_boundary_normal(p, d, r_datum)`
(= `boundary_normal` + `_radial_at`, see R6.2). Mirrored constants: `SMOOTH_RELIEF = 1.0`
(`FarDensity.RELIEF`), `SMOOTH_BNORM_STEP = 1.0` (`BOUNDARY_NORMAL_STEP`).

## R6.2 Boundary normals — yes, native (they are a third of the cost)

`boundary_normal` is 4 extra `profile_at_dir` per perimeter node — at S3 that is 832 calls
vs the grid's 2 809 (~30 % of the tile's worldgen cost), at S2 1 664. It goes native inside
the SAME call (the `"bnrm"` array), not as a second entry point. Byte-equality construction —
the f32/f64 split is the load-bearing part and is mirrored op-for-op:

- ref pick: `absf` compares on the f32 components (f64-widened, identical predicate);
- `u = (ref − d·(ref.dot(d))).normalized()`, `v = d.cross(u).normalized()` — **all
  Vector3 real_t (f32) core ops** (GDScript Vector3 math IS these same core functions);
- `scale = 1.0 / r_datum` **f64**; `tangent * scale` → Godot narrows the scalar to real_t
  first (`tangent * real_t(scale)`), f32×f32;
- `_radial_at`: `sd = (d + tangent·scale).normalized()` f32; `profile_at_dir` at the
  **f32-widened** `sd.x/y/z` (unlike the grid nodes' f64 — mirror exactly); relief f64;
  `sd * real_t(r_datum + relief)`;
- cross/normalize/orient: f32 core ops, `length_squared() <= 0 → d`, `dot < 0 → −nv`.

## R6.3 Integration (`facet_smooth_tier.gd`), flag `FP_CPP_SMOOTH_BAKE`

New `const FP_CPP_SMOOTH_BAKE := false` in `cube_sphere.gd` (deploy sed flips it alongside
`FP_FAR_SMOOTH`). **No off-surface gate** — the native bake is cheap enough to run
on-surface, which is exactly where the warmup floods.

1. **Generator instance (design question 5):** the P1 `FacetSmoothTier` instance OWNS one,
   built in `setup_instance` via the existing frozen-config plumbing —
   `_cpp_gen = FacetSkinTier._build_cpp_gen(active_fid)` — when the flag is on and the class
   exists. NOT shared with the skin tier's live instance: `FP_SKIN_TIER` can be off/absent
   independently, and a second instance costs ~nothing (the Parameters struct holds Refs to
   the SAME noise Resources). Held as a strong member ref (the `_sampler_obj` lesson);
   written once at setup, read-only ever after ⇒ worker-safe without new locking
   (`bake_smooth_tile` is const + RWLockRead, the `_pbm` concurrency pattern).
   **Config rider (required for byte-equality):** `_build_cpp_gen`'s cfg gains
   `"climate_biomes": CubeSphere.FP_CLIMATE_BIOMES`. Today it omits the key ⇒ `p.climate_biomes`
   defaults false while GDScript `TerrainConfig._biome` reads the live flag — a latent
   biome/colour divergence for the SKIN too whenever `FP_CLIMATE_BIOMES` ships on. Fixing it
   is byte-identical with the flag off and gate-covered by G-CG-COLUMNS with it on.
2. **`build_tile(fid, cells, lift, curved, normal_lit, slot, gen: Object = null)`:** when
   `gen != null`, ONE `gen.call("bake_smooth_tile", corner_dirs, r_datum, cells)` replaces the
   node_at loop; validate the four grid arrays are size `n` (else fall through — loud
   refusal, never a wrong tile); the fill loop derives relief/pos/planar/uv/uv2/colour/alpha
   verbatim (R6.1 table); the normal pass reads `bnrm[vi]` at the perimeter instead of
   calling `FarDensity.boundary_normal`, interior central-diff unchanged. `gen == null`
   (flag off, module absent, malformed return) ⇒ the current loop, byte-identical.
3. **`build_tile_rim(…, gen)` — yes, the rim routes through the native bake too, but only on
   its FULL-bake path:** the `not have_cache` branch (initial S2 bake — at 11 025 nodes the
   single biggest tile in the system) consumes the same baked arrays for every node's
   dir/g/relief/biome/temp, then blends env/feather/sink in GDScript exactly as today. The
   FP_RIM_CHEAP **crescent** rebake path is left untouched: it resamples only a small fresh
   annulus (a batched full-grid bake would waste 11 025 native nodes to feed ~hundreds), and
   it is already measured-acceptable (R5.3). `_env_weld_grid` (the rim's OTHER warmup cost)
   stays GDScript at its Stage-D coarsened mult — separate, already-shipped mitigation; noted
   as the residual S2 cost, not this revision's scope.
4. **Worker glue:** `_build_worker` passes the frozen `_cpp_gen` into both builders (one
   added argument; single-writer discipline unchanged — the member never mutates after
   setup). `snap_edge_to_pitch`/`_pitch_node_pos` stay GDScript (≤ ~20 `node_at` per tile —
   noise, not signal).

Earth-only parity note: `FarDensity.node_at` calls `TerrainConfig.profile_at_dir` (never the
Moon dispatch) — the native bake mirrors that verbatim. Same scope, not a regression.

## R6.4 The gate (G-CSB-EQ, extend `tools/verify_far_smooth.gd`)

1. **Per-node bit-equality:** for a facet sample spanning all 6 faces, a cross-face-edge
   pair, and a cube-corner facet, at S5/S4/S3 (+S2 on one facet): native `bake_smooth_tile`
   vs the GDScript `node_at` loop — `g`/`biome` `==`, `dir`/`temp`/`bnrm` bit-equal
   per component. 0 mismatches over ~10⁴ nodes.
2. **Whole-tile:** `build_tile` (and rim full-bake) with `gen` vs without —
   pos/nrm/col/uv/uv2/idx byte-equal.
3. **Weld survives the port (law 2):** a shared cross-face edge node computed through the
   NATIVE path from BOTH facets' `corner_dirs` ⇒ bit-identical.
4. **Falsify:** re-run (1) against a native call with `cells+1` and with a rotated corner
   order — the comparison MUST fail (non-vacuous gate).
5. Regressions: `verify_far_smooth` 27/0 with the flag ON; FLAT 6042/0 flag OFF
   (byte-identical — default false); G-CG-COLUMNS both states of the climate_biomes rider.

## R6.5 Patch / rebuild plan

- **New patch `docker/engine/patches/godot_voxel/0012-cosmos-smooth-tile-bake.patch`** — do
  NOT extend 0011 (one feature per patch, and 0011 is shipped). Touches only
  `generators/cosmos/voxel_generator_cosmos.{h,cpp}` (+ the ClassDB bind). Generate from the
  prepared tree at `scratchpad/voxel-src` (base commit = 0001-0010, working diff = 0011):
  commit the 0011 state locally, implement, `git diff HEAD > 0012…patch` ⇒ applies cleanly
  after 0011 in `scripts/build.sh`'s patch ladder.
- **Rebuild:** `scripts/build.sh` — Linux editor first (`SKIP_WEB=1`, minutes warm) for the
  headless gates, then the web templates for deploy. GDScript lands in the same PR with the
  flag default-false (byte-identical until the sed).

## R6.6 Verdict — **GREEN**, with one named unknown

This is the third instance of an already-twice-proven pattern (0007 voxels, 0011 skin): port
a pure, gate-pinned computation behind a batched const entry point, keep the GDScript twin as
the byte-oracle and the fallback. Bounded memory: the per-call return is `36·n` bytes
(~397 KB at S2, ~101 KB at S3), ≤ `SMOOTH_BUILD_SLOTS`(8) in flight ≈ ≤ 3.2 MB transient,
freed at commit — no new resident state, NEVER-OOM ledger unchanged.

**Warmup speedup estimate:** a 289-facet cold engage is ~4–5·10⁵ interpreted
`profile_at_dir` chains + as many Dictionary allocs today. Native: the same sample count
compiled (the skin bake measured ~10–40× per tile on this exact chain) ⇒ worker-side bake
time from minutes to ~5–15 s — and, the part that actually restores playability, the
per-node allocation traffic vanishes (one marshalled call + packed arrays), so the WASM
allocator convoy stops stalling the MAIN thread during warmup. Composes with
FP_SMOOTH_GROW_PACE (fewer, cheaper builds) rather than replacing it.

**Single riskiest byte-equality unknown:** the compiler's floating-point contraction (FMA)
in the f64 bilerp/normalize chain vs GDScript's op-by-op VM — plus the enumerated f32-narrow
points in `boundary_normal` (R6.2). Precedent says the shipped flags don't contract (0007's
`height_c3` is the same `a*b+c` style and is bit-equal on BOTH Linux and web), and G-CSB-EQ
item 1 falsifies it per-node; if web codegen ever contracts, the fix is `-ffp-contract=off`
on the cosmos TU. Everything else is mirrored construction, not hope.
