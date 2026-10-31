---
name: voxiverse-gen-convoy-alloc-census
description: Ground-walk dlmalloc convoy per-block allocation census + C++-vs-GDScript generator runtime probe
metadata: 
  node_type: memory
  type: project
---

2026-08-30. Ground-walk jerkiness layer B (villages off) = WASM dlmalloc convoy on the GENERATION path
(tasks.generation mean 157/max 2003, tasks.meshing ≈2, 6 workers busy, ~430ms/frame unmetered = main
busy-waiting on the one global dlmalloc mutex). Census: `docs/COSMOS-GEN-CONVOY-ALLOC-CENSUS.md`; design:
`docs/COSMOS-GEN-CONVOY-DESIGN.md` (Fable); feasibility: `docs/COSMOS-GEN-CONVOY-ALLOCATOR-FEASIBILITY.md`.

Durable facts (not obvious from code):
- **C++ VoxelGeneratorCosmos IS live on the deployed walk path** (FP_CPPGEN baked ON via deploy-cheat sed;
  repo default is false + FACETED false, so source defaults DON'T reflect the deploy). setup() accepts the
  faceted-flat cfg (all 4 refusal gates pass: 6 noises, cube_arid/block_ids non-empty post-cold-bake,
  flat_world=true so CURVED-refusal skips, frozen_atlas well-formed + facet_r_blocks=6371>0).
- **Zero-cost runtime probe for which generator is live:** the C++ gen has NO `gen_stats` binding, so
  `gen_class_stats()` skips it → telemetry `gen_ct_0..3`/`gen_ms_0..3` (remote_bridge.gd:846-872) are
  ABSENT when C++ is live, PRESENT+nonzero on GDScript fallback. Read the existing relay, no rebuild.
- **Per-block convoy ranking (C++ live):** #1 mesher CoW surface materialization ~7×M allocs (M=materials
  with geometry ~3-6), voxel_mesher_blocky.cpp:1176-1207, materialized on worker/freed on main (collapse
  TODO at :1173); #2 VoxelBuffer wrapper+ctrl 2/block (generate_block_task.cpp:48); #3 task objects 3;
  #4 gen `profs` std::vector 1 (voxel_generator_cosmos.cpp:2243, NOT thread_local). ~6+7M allocs/block,
  ~50-100k dlmalloc-lock acquisitions/sec at burst.
- **Channel data is ALREADY POOLED** via VoxelMemoryPool (per-pow2 freelist, self-warms — recycle pushes
  back, only clear_unused_blocks frees). Only CHANNEL_TYPE (1 channel/block, 8KiB). LESSON: don't count a
  new allocator front-end's "channel win" — it's redundant; net-new = CoW backings + wrapper/task objects
  + module std::vector. See [[voxiverse-walk-perf-root-cause]], [[voxiverse-mimalloc-arena-root]]
  (mimalloc rejected twice on heap; dlmalloc stays), [[voxiverse-ground-walk-perf]].
- Cheap arm-1 = module transient diet (thread_local profs + recycle buffer/task + collapse 7×M CoW),
  heap goes DOWN, no OOM risk; the Memory::alloc_static bucketed recycler front-end is the escalation.
