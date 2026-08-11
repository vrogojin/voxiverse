# COSMOS-LOD-LADDER-MIDBAND — mid-distance mountain renders as giant low-res blocks

Task #107 root-cause + fix design (Fable, 2026-08-11). Repro: facet 772, NAV `-30970,50,7161`, alt 47, surface;
shots `lod-0.jpg`/`lod-1.jpg`. Companion: COSMOS-FAR-SMOOTH-V2-DESIGN.md, COSMOS-NEAR-FAR-HEIGHT-DESIGN.md,
COSMOS-BLOCK-LOD-DESIGN.md, COSMOS-NB-FULLRES-DESIGN.md.

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

- Nearest mountain (the crosshair hill): **d ≈ 430–436 blocks**, g 55–62, biome 9 (B_MOUNTAINS → grey stone
  palette), and it **straddles fid 748 and fid 797**.
- fid **748** = an EDGE neighbour of active 772 (`seam_neighbour` slots → 796, 748, 773, 771) ⇒ a **live pool
  facet** under FP_NB_FULLRES.
- fid **797** = hop-2 ⇒ inside the FacetSmoothV2 annulus (hop ∈ [2..4]).

On-screen block size: `px = P·vh/(2·d·tan(fov/2))`; at fov 75°/vh 1080, a **26-block cell at d=430 ≈ 42 px** —
the "giant blocks" in the shots. An 8-block cell would be ≈13 px; full-res 1-block ≈1.6 px.

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

## 4. Flags + gates + phases

| Flag | Gates | OFF ⇒ |
|---|---|---|
| `FP_SMOOTH_V2_NEARCOVER` | hop_b 2→0 residency + uniform `V2_NEAR_SINK` + enabling the existing EXCL_BLKLOD suppression path for resident tiles | annulus/emission byte-identical (hop_b=2 verbatim, sink term absent, EXCL_BLKLOD stays dead) |

- **N0 (gate-first)**: `verify_lod_ladder.gd` — G-LAD-MONO: reconstruct the as-rendered cover pitch along the
  player→peak ray at the repro pose; assert pitch is monotone non-increasing toward the camera. Pins TODAY's
  26-blk inversion as the failing baseline.
- **N1**: residency + sink + suppression. Exit: G-LAD-MONO green; G-V2-WELD/G-V2-PURE unchanged; sink ≤ true −
  chord-residual assertion (G-V2-NEAR-SINK); byte-off FLAT 6042/0; live A/B at the repro pose (screenshot vs
  `lod-0.jpg`).
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

- The SSE-by-facet-CENTRE-distance law (`facet_lod_mesher.gd:266-316`) still under-resolves the near portion of
  a far-centred facet outside the pool; A2 covers only edge neighbours. Not the reported symptom's cause (M2
  never covers the offending facets here), but the same non-monotone class — worth folding into G-LAD-MONO.
- Task #72 ("far terrain too low") is the twin symptom of the same rung: env-flattened/sunk backstop where a
  finer tier should be. FP_SMOOTH_V2_NEARCOVER shrinks its visible surface too (true-height ε-sunk relief
  replaces env terraces in the mid band).
