---
name: voxiverse-lod-ladder-smooth
description: 2026-08-11 blocky-mountain mid-band ROOT = M2 FacetLodMesher l2/l3 megablocks protrude OVER resident SmoothV2 (no arbitration) + hop-0/1 covered by NOTHING but 27-block far-ring backstop; NOT block-LOD (not deployed); fix FP_M2_SMOOTH_DEFER/_EDGE_DIST/FP_SMOOTH_V2_NEARFILL
metadata: 
  node_type: memory
  type: project
---

2026-08-11, task #107 (blocky mountain on approach, facet 772 / peak on 797 @474 blocks).
SIBLING: [[voxiverse-lod-ladder-midband]] (parallel investigator, same task) — agrees on the
non-monotone ladder + hop-0/1 hole + NEARCOVER-style fix, but attributes the repro slabs to the
26-blk backstop on hop-1 pool facets. DISCRIMINATOR measured here: the grey-peak silhouette
risers are 4-11 blocks and the g=72 summit is wholly on 797 (hop-2, NON-pool, non-backstop ⇒
only 109-blk quad + smooth + M2 exist there) ⇒ the summit slabs are M2, so their
FP_SMOOTH_V2_NEARCOVER + FP_SMOOTH_V2_EXCL_BLKLOD fixes the 748-shoulder rung but leaves the
summit blocky without C1/C2 below. RESOLVED same day: sibling re-probed with g>=66 cut and CONFIRMED the summit attribution
(g 66-72 @ d~457 wholly on 797, hop-2, non-pool, smooth-resident); designs MERGED into
COSMOS-LOD-LADDER-MIDBAND-DESIGN.md on branch fix/voxiverse-lod-ladder. C1 final form =
skip ALL M2 wants for smooth-resident facets (my "allow l1" clause was WRONG: progressive
first-cover admits meshless at max(target,3), facet_lod_mesher.gd:363-365, idle-only refine
=> l1 want re-materializes l3 steps; no band where l1-over-smooth is visible AND uncovered).
Gate must also assert DEFER EVICTS (stale l3 protrudes for LOD_IDLE_DEMOTE_S after residency
arrives — immediate-evict if that constant is long). Sibling carries N0 (G-LAD-MONO gate,
now includes the M2 tier in the frontmost-cover scan). Acceptance = live approach-capture
A/B at 800/470/250/130 blk toward the 797 summit.

N0 SHIPPED (sibling, fix/voxiverse-lod-ladder): verify_lod_ladder.gd 8/8 pin-green (dual-vh
540/1080 summit rows: lc 1.95/0.95 @ d=453, both floor to granted l3 — the first-cover floor
is canvas-independent; sampled-column up-quantize documented); rung
table player→summit: 60-100 near 1-blk | 130-300 backstop 26.1-blk on hop-1 pool fid 773
(the RAY shoulder is 773, not 748 — 748/797 straddle was the peak MASS; capture headings
should say 773) | 430-800 M2 l3 8-blk over smooth on 797/821. Summit protrusion MEASURED:
M2 quantized top 72.0 vs smooth TIN 58.66 = +13.3 blk (TIN 8-blk under-samples the peak).
GATE TRAP for pin gates: model the LIVE flag fingerprint with gate-local consts
(e.g. LIVE_NB_FULLRES) — reading CubeSphere.FP_* (repo default-false) silently voids the pin.

- The FP_BLOCK_LOD/_RINGS/_GLOBAL pyramid is **NOT in the live deploy** — deploy_cheats.sh
  CS_FLAGS (scratchpad) has no FP_BLOCK_LOD*. The live mid-band blocky tiers are
  FP_M2_LOD (FacetLodMesher, 2/4/8-block l1..3) + FP_BLOCKY_FARRING far ring
  (CELLS=4 ≈109-blk; backstop facets BACKSTOP_CELLS=16 ≈27-blk).
- ROOT (3 laws): (1) M2 true-height megablocks protrude over the resident SmoothV2 tile —
  no M2↔smooth arbitration exists anywhere (smooth "draws OVER the shell" contract only holds
  for MIN-decimated far-ring cells); (2) M2 SSE tier uses FACET-CENTRE distance (~300-blk
  coarse bias) + refinement < l3 is idle-only with native-second estimates (x10-25 on web) so
  l3=8-blk lingers; (3) hop-0/1 facets (active + FP_NB_FULLRES pool) are excluded from BOTH
  smooth (hop_b=2, facet_smooth_v2.gd:194) and M2 (facet_lod_mesher.gd:295) ⇒ beyond near-128
  the frontmost tier is the 27-blk blocky backstop — the ladder is NON-MONOTONE on approach
  (8-blk → 27-blk → full-res).
- Screenshot-silhouette scan (grey-mask column tops) measured 4-11-blk risers at 474 ⇒ M2
  l2/l3, not backstop(27)/far(109)/smooth(continuous). Probe: src/tools/probe_lod_band.gd.
- Fix design (docs/COSMOS-LOD-LADDER-SMOOTH-DESIGN.md, all byte-off): C1 FP_M2_SMOOTH_DEFER
  (skip M2 wants >=l2 where FacetFarRing.is_smooth_resident(fid) — far_ring:1047 already
  exists; idle_sweep returns bytes), C2 FP_M2_EDGE_DIST (nearest-point-of-facet distance for
  sse_lc), C3 FP_SMOOTH_V2_NEARFILL (hop_b=0 + uniform 6-blk radial tile sink = BACKSTOP_SINK;
  residency superset ⇒ no crossing gap; +5 tiles ≈ +0.95MB, +14% paced commit).
- LESSON: with many overlapping flag-gated tiers, "which tier is frontmost" is a DEPTH fact,
  not a draw-order fact — min-decimated tiers underdraw, sampled/decimated voxel meshes
  protrude; any new smooth tier needs an explicit exclusion law per blocky tier
  ([[voxiverse-block-lod-design]] R-E, [[voxiverse-tier-depth-priority]]).
