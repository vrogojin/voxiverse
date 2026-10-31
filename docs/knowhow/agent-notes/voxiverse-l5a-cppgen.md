---
name: voxiverse-l5a-cppgen
description: "L5(a) C++ worldgen port SHIPPED (flag FP_CPPGEN, patch 0007) — byte-equal, 8-20x native, A/B pending"
metadata: 
  node_type: memory
  type: project
---

VOXIVERSE L5(a) — the C++ worldgen port (the measured fix for the streaming/walking freezes) is
IMPLEMENTED and byte-equal, flags default-OFF. Branch deploy/perf-plus-sky.

WHY: 97% of block-gen time was in two per-cell INTERPRETER-bound classes (underground 337.7ms,
surface-crossing 559.8ms/block web) — a ~x25 GDScript/WASM tax, not an algorithm problem. Only
compilation removes a multiplier. See [[voxiverse-web-perf-architecture]], [[voxiverse-perf-next-architecture]].

WHAT: `VoxelGeneratorCosmos` C++ class in engine patch `docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch`
(sha b69c530d). Ports the WHOLE `_generate_block` inner path — column_profile/profile_at_dir,
slope_run, resolve_cell + every helper (bedrock/strata/ore/snow/cap/smoothing/sea/trees), the
CellCodec pack+canonical chain, the emit loop's ARID dispatch, junction_modify. Files:
generators/cosmos/{voxel_generator_cosmos.{h,cpp},cosmos_terrain.h}.
Flag `CubeSphere.FP_CPPGEN` (cube_sphere.gd, default false). module_world._make_generator returns the
C++ gen under the flag (else GDScript), via _make_cpp_generator, frozen from the same baked tables;
falls back to GDScript on any setup failure.

KEY DESIGN (one-sampler law, SEAMLESS-SCALES §7): it is THE worldgen implementation, not a
render-only path — GDScript twin kept ONLY as the byte-equality oracle. ONE core, THREE entry points
(generate_block / sample_columns batch / scalar column_profile+resolve_cell for physics parity). Noise
is NOT reimplemented — setup() takes the actual FastNoiseLite instances TerrainConfig built, so C++
calls the same const virtual (bit-match by construction). All f64 (`double`), int64 hashes.

GATES (verify_cppgen.gd cell gate + verify_cppgen_buffer.gd end-to-end ARID gate): FLAT G-CG-CELL
0/138960, buffer 0/2.2M; FACETED cell 0/592896, buffer 0/12.8M. verify_feature FLAT 6035/0 with
FP_CPPGEN OFF **and ON** (ON = live C++ on workers). Every gate falsified (rebuilt engine, caught the
diff). NATIVE speedup: surface block 8.15x, deep block 19.9x → projects to ~6-9ms web surface / ~2-3ms
deep, inside the §2.6 target.

STILL PENDING: the live web SW-1 A/B (team-lead owns — deploy + browser measure). To A/B: sed
FP_CPPGEN true at export, verify BUILD-INFO module_in_web=yes + `strings` shows VoxelGeneratorCosmos
before trusting numbers (a stock-web fallback silently reverts FP_CPPGEN ON to GDScript). Commits:
S1 67b97d3, S2 a1b8f9a, S3 b56b71d, S3b/S4 20a90e3.
