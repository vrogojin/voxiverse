---
name: voxiverse-nb-fullres-design
description: 2026-08-10 FP_NB_FULLRES concrete spec (task
metadata: 
  node_type: memory
  type: project
---

2026-08-10, task #102 Phase C: wrote the implementation-ready spec `docs/COSMOS-NB-FULLRES-DESIGN.md`
(deploy/cheats-eyeball), superseding the [[voxiverse-perf-next-architecture]] parent doc's §3.2/§3.3 skeleton
in COSMOS-STREAM-PARALLEL-DESIGN.md where they differ.

Non-obvious findings baked into the spec:
- `VoxelTerrain.get_statistics()` has NO resident-memory/block counters (voxel_terrain.cpp:599-613 — only
  time_* + dropped/updated event counters). `module_world.gd:2188 _pool_block_sum` therefore sums EVENT
  counters, mislabeled as blocks_replaced. Real measured bytes = `VoxelEngine.get_stats().memory_pools.voxel_used`
  (VoxelMemoryPool, engine-wide data bytes) + `OS.get_static_memory_usage()`.
- Whole-facet binary far-ring exclusion (world_manager.gd:3051-3066) would turn a live-but-EMPTY neighbour
  (player mid-facet, localized viewer out of view reach → zero blocks stream) into a backstop-only hole at the
  visible ridge — exclusion must be band-conditional (`pool_seam_meshed` latch + geometric release at 96).
- The one-player-viewer construction means a live neighbour's resident bytes ∝ ridge proximity automatically;
  mid-facet a live neighbour costs ~0 bytes. Retire law: `targets.has(nb)` skip already self-disables
  distance-retire once the selector returns all 4 edges; crossing rebalance is the existing recompute path.
  New needs: farthest-first retire + same-tick imminent-priority eviction when the cap blocks the crossing target.

**Why:** these three facts are easy to re-miss (the parent design itself got the memory counters wrong) and any
implementer of Phase C will hit them.
**How to apply:** implement from COSMOS-NB-FULLRES-DESIGN.md, not the parent §3.2/§3.3; never cite
get_statistics for memory; keep exclusion band-conditional.
