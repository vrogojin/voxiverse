---
name: voxiverse-nb-fullres
description: "2026-08-11 FP_NB_FULLRES SHIPPED+MERGED (PR #41 de2d35e) — full-res near blocks on ALL 4 edge neighbours (was active+1 imminent = seam see-through); post-settle want-4-edges, ≤1 spawn/interval, measured-bytes 32MB growth ledger, band-conditional far-ring exclusion; live A/B +2.7MB/neighbour, fps recovers ~40, no OOM"
metadata:
  node_type: memory
  type: project
---

Perf directive (task #102): fast reload + neighbour-facet blocks + parallel threads. BOTH main pieces SHIPPED+MERGED overnight (user authorized full-auto PR+merge if A/B passes, full coverage accept fps cost, NEVER-OOM hard):
- Phase A FP_DEM_DEFER (PR #40, main 9647db6): reload fix — GlobalReliefData.step was frame-budget GATED-not-BOUNDED (O(3456) alloc scan + bake + hillshade 20-60ms/admitted frame = duty-cycle sawtooth, the 2-3min 4-28fps window). Defer DEM until near-view settled (initial_view_meshed latch) + demand-driven (far-ring request(fid)) + alloc-free _centre_dirs + first-call frame_ms<=0 fix. Live: g2_baked=0 through whole reload, user-confirmed good. FINDING: near-field convoy (chunk gen/mesh + colour-skin bake) is the RESIDUAL reload cost, NOT the DEM — but user OK ("looks good"), so left as optional follow-up.
- Phase C FP_NB_FULLRES (PR #41, de2d35e): near blocks on all 4 edge neighbours.

FP_NB_FULLRES design/impl (docs/COSMOS-NB-FULLRES-DESIGN.md, Fable fable-nb-arch + impl impl-nb-fullres):
- Near-field pool = module_world.gd Z1-hybrid (spawns real neighbour VoxelTerrains, own gen+facet-carve mesher). Baseline steady = 1 active + 1 imminent (z1_live_targets narrows to FP2_LIVE_CAP=2); other 3 edges showed far tier = seam see-through.
- Residency: want{} already has all 4 edges (world_manager.gd:2821); under flag+settled selector appends remaining edges nearest-first, cap→POOL_MAX_NEIGHBOURS=4, ≤1 spawn/interval, distance-retire self-disables for edges (targets.has(nb):continue), +farthest-first retire +same-tick imminent eviction. Crossing rebalances want-set to new active's 4 edges.
- Nearest-first PRESERVED BY CONSTRUCTION: one shared player viewer → godot_voxel distance priority global across pool; mid-facet neighbours stream ~0 blocks (bytes ∝ ridge proximity, automatic). NB_BAND_BLOCKS=64 render band. Colbulk stone-fill gens.
- TWO CRITICAL CORRECTIONS Fable self-caught: (1) VoxelTerrain.get_statistics() has NO memory counters — measure REAL bytes = VoxelEngine.get_stats().memory_pools.voxel_used + OS.get_static_memory_usage() (_pool_block_sum:2188 was mislabeled event counters). (2) whole-facet binary far-ring exclusion would make a live-but-EMPTY neighbour a see-through HOLE (worse than today) → must be BAND-CONDITIONAL (latch pool_seam_meshed, geometric release ridge-dist>NB_EXCL_RELEASE=96).
- NEVER-OOM: post-settle GROWTH budget over B0=(voxel_used+static) at settle; every non-imminent grow needs growth+NB_SPAWN_EST(4MB) ≤ NB_POOL_BYTES_CAP(32MB); breach ladder refuse→freeze-grows→farthest/LRU-retire, re-admit below cap−NB_BYTES_REHYST(8MB), 1600MB abs-heap backstop. Drift debits NB budget (conservative). G-SP-NB-CAP falsifier proves enforcement.
- Gates verify_stream_parallel Phase C 44/0 (G-SP-NB-OFF/COVER/CAP-falsifier/PRIO/REBALANCE, drives REAL WorldManager ledger/retire/exclusion helpers + static selector), FLAT 6042/0, verify_faceted 84/0.

LIVE A/B (walk to facet edge via move op, blocks≤128): facet_neighbours 0→1 + pool_active spiked to 6 (neighbour spawn+stream), vmem 189.8→192.5 (+2.7MB/neighbour, << 32MB cap; corner-4 ≈ +11MB), fps transient dip during streaming then recovers ~40, blocks render across seam NO see-through (frame confirmed). No crash/OOM.

REMAINING (optional, low-pri): near-field load convoy (real residual reload cost, user OK), Phase B FP_DEM_ASYNC (moot now DEM deferred), Phase D crossing/corner residue, Fable-flagged project.godot ratio_over_max=0.7 vs its own 0.4 comment re-check. UNATTENDED PROCESS: teleport op exists but move caps at 128 blocks; telemetry has pool_active/facet_neighbours/vmem_mb for pool A/B; fresh-load still ~2-3min (near-field). Related: [[voxiverse-stream-parallel-design]] [[voxiverse-neighbour-underground-direction]] [[voxiverse-orbit-relief-g3]] [[voxiverse-walk-perf-root-cause]] [[voxiverse-never-oom-web]].
