# COSMOS-LOD-LADDER-MIDBAND — mid-distance mountain renders as giant low-res blocks

Task #107 root-cause + fix design (Fable, 2026-08-11). Repro: facet 772, NAV `-30970,50,7161`, alt 47, surface;
shots `lod-0.jpg`/`lod-1.jpg`. Companion: COSMOS-FAR-SMOOTH-V2-DESIGN.md, COSMOS-NEAR-FAR-HEIGHT-DESIGN.md,
COSMOS-BLOCK-LOD-DESIGN.md, COSMOS-NB-FULLRES-DESIGN.md; twin investigation (summit attribution, C1/C2):
COSMOS-LOD-LADDER-SMOOTH-DESIGN.md (deploy-cheats worktree).

## 0. Premise correction (measured, not assumed)

The task named the FP_BLOCK_LOD ladder's coarse level as the suspect. The LIVE pck (downloaded 2026-08-11 10:08 UTC,
`get_script_constant_map` dump) says the block-LOD pyramid is **not live at all**:
`FP_BLOCK_LOD=false, FP_BLOCK_LOD_RINGS=false, FP_BLOCK_LOD_GLOBAL=false, FP_BLOCK_LOD_ORBIT=false`.
What IS live and relevant: `FP_BLOCKY_FARRING=true, FP_BLOCKY_TEX=true, FP_NB_FULLRES=true, FP_SMOOTH_V2=true
(V2_CELLS=52, V2_HOP_B=2, V2_HOP_H=3, V2_HOP_H_REACH=4, FP_SMOOTH_V2_REACH=true), FP_M2_LOD=true, FP_M1_POOL=true,
BACKSTOP_CELLS=16, FP_ENV_ALL=true, FP_FARRING_UNCOVERED_TRUE=true, FP_FARRING_APPLIED_COVER=true,
FP_SMOOTH_V2_EXCL_BLKLOD=false, FP_SKIN_TIER=false, FP_MID_DENSE=false`.

## 1. Measured repro geometry

Headless probe (`src/tools/probe_lod_ladder.gd`, this branch) from the exact repro pose — player world
`(-5606.9, 1395.7, -2794.4)` matches the user's BCI `[-5606.58, 1395.19, -2794.76]`:

- Nearest mountain (the crosshair hill): **d ≈ 430–457 blocks**, biome 9 (B_MOUNTAINS → grey stone palette),
  and it **straddles fid 748 and fid 797** — two DIFFERENT rungs in the same view:
  - the **shoulder** (g 55–62, d≈430) sits on fid **748** = an EDGE neighbour of active 772 (`seam_neighbour`
    slots → 796, 748, 773, 771) ⇒ a **live pool facet** under FP_NB_FULLRES;
  - the **summit** (g 66–72, d≈457, the probe's g≥66 cut) sits entirely on fid **797** = hop-2, NON-pool,
    inside the FacetSmoothV2 annulus (hop ∈ [2..4]) — the backstop NEVER emits there (797 is not
    active/excluded/sticky) and the 104-blk horizon quad is min-contained below the smooth tile.

Cross-checked by the parallel investigation (COSMOS-LOD-LADDER-SMOOTH-DESIGN.md, deploy-cheats worktree,
`probe_lod_band.gd`): the measured summit silhouette (grey-mask column-top scan of `lod-0.jpg`, risers 2–8 px /
benches 6–15 px at the 960×540 capture ≈ 4–11-blk risers / 8–20-blk benches at d≈474) is **too fine to be
26-blk backstop cells (~19–21 px benches at that capture scale) and matches M2 ℓ2/ℓ3 (4/8-blk) megablocks**.

On-screen block size: `px = P·vh/(2·d·tan(fov/2))`; at fov 75°/vh 1080, a **26-block cell at d=430 ≈ 42 px**;
an 8-block cell ≈ 13 px (≈6 px at the 960 capture); full-res 1-block ≈1.6 px.

## 2. Root cause — the ladder has a NON-MONOTONE rung on live-pool facets

What covers a live-pool facet's area BEYOND the streamed near meshes (applied ellipsoid ≈112–160 blocks,
`APPLIED_PROBE_MAX=112`, `facet_far_ring.gd:1584-1612`):

1. **FacetSmoothV2 excludes it** — the annulus starts at `V2_HOP_B=2` (`facet_smooth_v2.gd:178`,
   `hop_annulus(active, 2, 3|4)`), so hop-0/1 facets have no smooth tile. When the player approaches and the
   mountain's facet drops hop-2 → hop-1, its smooth tile is UNLOADED.
2. **FacetLodMesher (FP_M2_LOD) excludes it** — the SSE want-loop skips live pool facets
   (`facet_lod_mesher.gd:294-296` `live.has(fid) → continue`), and the A2 seam pin that used to guarantee
   ℓ1 = 2-block megablocks on the 4 edge neighbours **explicitly excludes live-pool facets**
   (`facet_lod_mesher.gd:752-761`). Under FP_NB_FULLRES all 4 edge neighbours ARE live pool ⇒ the A2 pin set is
   empty. **This is the regression vector: FP_NB_FULLRES (PR #41) silently traded the whole-facet 2-block ℓ1 LOD
   cover for a ~112-block-radius full-res patch, leaving the facet's remainder to the coarsest tier.**
3. What remains is the **far-ring dense BACKSTOP**: live-pool facets are `_is_backstop` (`_excluded` ∪ active ∪
   sticky), rendered from the dense grid at `BACKSTOP_CELLS=16` ⇒ **417/16 ≈ 26-block cells**, and under
   **FP_BLOCKY_FARRING those cells are emitted as literal flat-topped blocks with wall quads**
   (`facet_far_ring.gd:3959-3965 → _emit_blocky:3789`). Outside the applied ellipsoid the vertices take TRUE
   chord heights (zone A/B, `_blend_uncovered` `facet_far_ring.gd:3303-3318`) — full-height, un-flattened.

So the approach ladder is: **1-block voxels (0..~112) → 26-block blocky columns (~112..~830) → 8-block smooth
relief (hop 2..4) → coarser far tiers.** The middle rung is 3× COARSER than the tier BEHIND it — the same
mountain looks smooth at hop-2 and explodes into 26-block grey ziggurat steps exactly when the player gets
CLOSER. That inversion is the user's report, and B_MOUNTAINS' stone palette + terraced TRUE-height quantization
makes it maximally visible.

**2b. Second mechanism — M2 megablocks protrude OVER resident smooth tiles (the SUMMIT).** FacetLodMesher is
smooth-blind: `_recompute_wants` stamps a want on every front-facing in-frustum non-live facet with no check of
SmoothV2 residency (zero references to smooth anywhere in `facet_lod_mesher.gd`), so hop-2..N facets carry BOTH
a smooth tile and an M2 megablock mesh. The M2 mesh is true-height 2^ℓ-quantized blocks; the smooth TIN
underestimates peaks between its 8-blk nodes ⇒ at relief maxima the M2 blocks stick out ABOVE the smooth
surface. Worse, the budgeter's progressive first-cover admits a meshless facet at **max(target, ℓ3)** and
refines finer **only while the build queue is idle** (`facet_lod_mesher.gd:333-338`), and the SSE distance is
the facet CENTRE (`:297-313`) — so mid-field facets sit at ℓ2/ℓ3 (4/8-blk) far longer and coarser than the
τ=3 px law intends. That is the measured 4–11-blk summit stepping on fid 797.

## 3. The fix — FP_SMOOTH_V2_NEARCOVER (extend the smooth annulus down to hop 0)

Chosen over the alternatives (§5) because the live art direction is smooth-far (tasks #85/#99/#101), the tier
already exists at the right pitch, and it makes the ladder monotone with ZERO new meshers:

**Rule: with `FP_SMOOTH_V2_NEARCOVER` on, the residency annulus becomes hop ∈ [0..H] (active + ring-1 included);
every V2 tile (all hops — weld-uniform) is emitted with a small uniform radial sink `V2_NEAR_SINK ≈ 1.5` blocks;
`FP_SMOOTH_V2_EXCL_BLKLOD` (already implemented, `facet_far_ring.gd:1846/2803`, currently false) is enabled so
the far ring suppresses its 26-block blocky emission under every COMMITTED resident V2 tile.**

- **Composition with the near field — no holes, no dynamic re-mesh.** The near full-res voxels sit at true
  height; the V2 tile is ε-sunk ⇒ near overdraws it wherever meshes are applied (the shipped skin-tier SINK=1.5
  overlap law, `facet_skin_tier.gd`). Where near is NOT applied (the 112..417+ remainder) the ε-sunk 8-block
  smooth relief shows. Tiles stay STATIC — residency still changes only on crossings, preserving V2's core
  invariant (`facet_smooth_v2.gd:21-27`); the applied ellipsoid's growth needs no tile updates.
- **Weld preserved**: the sink is `pos − normalize(pos)·ε` — a pure function of the welded vertex ⇒ two facets'
  shared vertices sink bit-identically; applying it to ALL tiles (not just hop-0/1) avoids a sunk↔unsunk edge
  crack. ε at ≥112 blocks is ≤ ~9 px at the frontier and shrinks with distance — the same visual class as the
  shipped skin sink.
- **Protrusion**: 8-block chord error ≈ 8²·|h″|/8 ≈ 0.15–1 block ≤ ε ⇒ the tile never rises above near blocks
  where they coexist (G-NPT class argument; gate pins it).
- **Crossing pop dies too**: hop-2→1 no longer unloads the tile, so the smooth cover PERSISTS while near meshes
  stream in and overdraw progressively — the approach is seamless smooth → full-res.
- **NEVER-OOM**: +5 tiles (active + 4 edge neighbours) ≈ 5 × 53²·(12+12+16 B) + indices ≈ **+0.75 MB** in the
  existing V2 ledger; bounded by the annulus cap as today.
- **Perf**: tiles bake off-thread (`bake_smooth_tile`, FP_CPP_SMOOTH_BAKE) under the live pace/merge machinery
  (FP_SMOOTH_V2_PACE + _ASYNC_MERGE); +5 tiles per crossing is ~12% of the ~40-tile annulus. The blocky-emit
  suppression REDUCES far-ring tris/upload.

## 3b. Companion fixes for the SUMMIT mechanism (merged from COSMOS-LOD-LADDER-SMOOTH-DESIGN.md C1/C2)

NEARCOVER + EXCL_BLKLOD fix the shoulder/hop-0/1 band only — EXCL_BLKLOD suppresses the far-ring blocky emit,
not M2. Two more flags close the summit:

- **`FP_M2_SMOOTH_DEFER` (C1, LOCKED v1 = skip-ALL)**: FacetLodMesher defers to a resident smooth tile. Wire a
  `set_smooth_query` Callable → `FacetFarRing.is_smooth_resident` (accessor exists, `facet_far_ring.gd:1047`;
  Callable pattern precedent `facet_block_lod_ladder.gd:40-46`; unset ⇒ shipped verbatim). In
  `_recompute_wants`, a smooth-resident facet gets **no M2 want at all** — both investigators converged here:
  the SMOOTH doc's original "ℓ1 still allowed" is unsound because any want on a MESHLESS facet materializes
  through the budgeter's `max(target, ℓ3)` first-cover (`facet_lod_mesher.gd:333-338`) with idle-only
  refinement (the ℓ3 summit steps return under load), AND there is no band where ℓ1-over-smooth is both
  visible and not already covered finer (smooth-resident today ⇒ hop≥2 ⇒ nearest point ≳290 blk ⇒ 2-blk cells
  ≈1 px; under NEARCOVER the hop-0/1 close portion is the near/pool full-res band). Skip-ALL also retires the
  ℓ1 ledger exposure for the whole annulus (no ~4.6 MB ℓ1 meshes grantable over smooth) ⇒ the gate's M2-ledger
  assertion is strict monotone non-increase, no carve-outs. The ℓ3-floor-bypass variant stays a documented
  fallback ONLY if a live A/B shows the 8-blk flat-colour smooth band reads too soft just before a crossing.
- **C1 eviction clause (REQUIRED)**: the want-skip alone leaves an already-granted ℓ≥2 mesh protruding through
  the smooth tile until the idle sweep demotes it — and `LOD_IDLE_DEMOTE_S = 30.0` (`facet_lod_mesher.gd:35`)
  is far past the ~10 s acceptability line. So the resident-set transition (facet becomes smooth-resident,
  flag on) must **immediately evict (or demote-to-quad) the facet's existing M2 mesh**; `_idle_sweep` remains
  the backstop for races.
- **`FP_M2_EDGE_DIST` (C2)**: feed `sse_lc` the distance to the NEAREST point of the facet's planar quad
  (reuse `_facet_render_corners`) instead of the centre (`facet_lod_mesher.gd:313`) — removes the ~300-blk
  coarse bias on edge-on facets (e.g. 771: centre 608 vs nearest edge ~380 ⇒ tier 2 vs 1). Composes with the
  existing hysteresis; A2's pin becomes a special case it mostly subsumes.

## 4. Flags + gates + phases

| Flag | Gates | OFF ⇒ |
|---|---|---|
| `FP_SMOOTH_V2_NEARCOVER` | hop_b 2→0 residency + uniform `V2_NEAR_SINK` + enabling the existing EXCL_BLKLOD suppression path for resident tiles | annulus/emission byte-identical (hop_b=2 verbatim, sink term absent, EXCL_BLKLOD stays dead) |
| `FP_M2_SMOOTH_DEFER` | smooth-residency query + want-skip in `_recompute_wants` + idle-sweep reclaim | Callable never wired ⇒ want loop byte-identical |
| `FP_M2_EDGE_DIST` | nearest-quad-point distance into `sse_lc` | centre distance verbatim |

- **N0 (gate-first)**: `verify_lod_ladder.gd` — G-LAD-MONO: reconstruct the as-rendered cover pitch along the
  player→peak ray at the repro pose, **with the M2 tier included in the frontmost-cover computation** (so the
  baseline pin fails on BOTH the 748 shoulder [backstop-26] and the 797 summit [M2 ℓ2/ℓ3]); assert pitch is
  monotone non-increasing toward the camera. Pins TODAY's inversion as the failing baseline.
- **N1**: NEARCOVER residency + sink + suppression. Exit: shoulder rows of G-LAD-MONO green; G-V2-WELD/
  G-V2-PURE unchanged; sink ≤ true − chord-residual assertion (G-V2-NEAR-SINK); byte-off FLAT 6042/0.
- **N1b**: `FP_M2_SMOOTH_DEFER` + `FP_M2_EDGE_DIST`. Exit: summit rows green; **G-LAD-DEFER-EVICT** —
  simulate resident-set arrival on a facet already holding an ℓ3 mesh: assert the mesh is freed and its bytes
  return on the transition itself (NOT after `LOD_IDLE_DEMOTE_S`); M2 ledger strict monotone non-increase under
  DEFER (no ℓ1 carve-out — skip-ALL); G-M2-SEL sweep unchanged off; byte-off FLAT 6042/0.
- **Acceptance evidence (live)**: the protrusion claim is not headless-gateable end-to-end — the accepted
  protocol is an approach-capture A/B toward the fid-797 summit at **800 / 470 / 250 / 130 blocks**, flags
  off vs on, compared against `lod-0.jpg`/`lod-1.jpg`.
- **N2 (optional polish)**: distance-graded V2 commit priority so hop-0/1 tiles build FIRST after a crossing
  (they are the visually nearest); reuse the pace queue's nearest-first order.

## 5. Alternatives considered

- **Densify the pool-facet backstop** (BACKSTOP_CELLS 16→52 on backstop facets): kills "giant" (26→8 blk) with
  ~zero bytes, but keeps blocky-vs-smooth style mismatch mid-band, pays ~9× env/bake cost on ~13 facets, and
  8-blk BLOCKS at the 112-block rim still subtend ~37 px. Fallback if the V2 A/B fails.
- **Re-admit M2 ℓ1 megablocks on live-pool facets** (clip tiles outside the applied ellipsoid): restores the
  pre-NB_FULLRES look (2-blk cubes), but re-introduces the live-facet z-fight the exclusion exists for
  (`facet_lod_mesher.gd:594`), costs ~4.6 MB/facet, and the crossing re-clip is dynamic churn V2 avoids.
- **Retune thresholds only**: no threshold moves the 26-blk backstop out of the 112..830 band — coverage, not
  tuning, is what's missing.

## 6. Also noted (separate, pre-existing)

- The SSE-by-facet-CENTRE-distance law (`facet_lod_mesher.gd:266-316`) under-resolves the near portion of a
  far-centred facet — now addressed directly by `FP_M2_EDGE_DIST` (§3b C2).
- Task #72 ("far terrain too low") is the twin symptom of the same rung: env-flattened/sunk backstop where a
  finer tier should be. FP_SMOOTH_V2_NEARCOVER shrinks its visible surface too (true-height ε-sunk relief
  replaces env terraces in the mid band).
