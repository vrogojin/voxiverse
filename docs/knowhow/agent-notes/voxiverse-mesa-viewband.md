---
name: voxiverse-mesa-viewband
description: "2026-08-12 SHIPPED+MERGED PR #56 (main 5df69bb) FP_APPLIED_VIEW_BAND — mesa grey-oval far-over-near = #113 probe wants full slab but engine loads only mesh rows [c−4,c+3] ⇒ ladder alive only player-y∈[32,95]; valley floor c=0 pins sh_applied_r=0; fix clamps probe to loadable band + height-banded zone C; LIVE sh_applied_r 0→96"
metadata: 
  node_type: memory
  type: project
---

Task #117 (residual of [[voxiverse-grassbase-backstop]]): grey oval over hot badlands mesa base at facet 1754, sh_applied_r=0.

**Root cause (MEASURED in real engine, E2/E3 probes vs served pck):** `_applied_box_meshed_slab` (facet_far_ring.gd:1637, the #113 body) demands the FULL slab y[−64,130) = 32³-mesh-rows −2..4 at every r, but godot_voxel loads only rows **[c−4, c+3]** around viewer row c=floordiv(ly,32) (voxel_terrain.cpp:1288-1296 + box3i.h:26 `from_center_extents(c,e)=Box3i(c−e,2e)` — one block SHORT upward; mesh_block_size=32 module_world.gd:393; view 128 ⇒ e=4). Full slab fits ⟺ **c∈{1,2} ⟺ player lattice y∈[32,95]**. #113 grass base y=34 = c=1 → looked healed (COINCIDENCE — near the window optimum); mesa valley floor y≈10-17 (c=0): row4 (y128..159, tree/snow headroom voxels 128-129) NEVER loads → first step false forever → applied_r pinned 0 → zone-B chord treads over the concavity. Measured: rows −2..3=T, row4=F stable 1500+ frames at settled view 128; view 96 ⇒ row3=F too; y=100 (c=3) ⇒ row−2=F. Grass-base settle at 64 (not 96/112) = W1 second-ridge CORNER pin at r=80 (pool_seam_meshed_weld corner-safe false, module_world.gd:2092) — secondary residual.

**Why:** third instance of the dead-latch class (probe demands unloadable blocks = unsatisfiable forever). #113's gate modeled meshed⇔slab×domain only — the viewer row window was missing from the model.

**SHIPPED+MERGED PR #56 (main 5df69bb, 2026-08-12), bundled with [[voxiverse-forest-snow-warmskip]].** LIVE A/B: sh_applied_r 0→96, new sh_applied_band=128 telemetry live at c=0. Gates verify_applied_band 20/0, verify_applied_slab(#113) 11/0, facet_seams 43/0, nb_weld 15/0, FLAT 6042/0. Byte-off. Impl matches design below. Visual oval-gone eyeball deferred (mechanism proven; user to revisit exact badlands spot).

**How to apply:** fix design = FP_APPLIED_VIEW_BAND (docs/COSMOS-FAR-NEAR-MESA-DESIGN.md): (1) module_world.meshed_band_y(ly) single-derivation loadable band; (2) probe vertical band ∩= loadable band; (3) height-banded zone C (vertex true-height ≤ band_top−1 else zone B — soundness at any live view; needs _btrue_h_cache ~1.2KB/fid); (4) sh_applied_band telemetry. Byte-off. Gates verify_applied_band G-VB-LAW/SAT/ZONEC/OFF + heavy G-VB-ENGINE (E2/E3 harness). Phase-2 alt: FP_VIEWER_SLAB_ANCHOR (pin grounded viewer row to slab — fixes unmeshed summit crowns + climb churn, needs perf A/B). LESSONS: gate synthetics must model the ENGINE loadable set (bounds ∧ viewer row window ∧ from_center_extents asymmetry) or drive the real engine; telemetry pos = player.global_position in a spin-dependent scene frame — NOT invertible offline to facet lattice; headless WorldManager harness: cover queries wire only via player update path, airborne-first pose stalls streaming (ground the first pose).
