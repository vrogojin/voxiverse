---
name: voxiverse-sharp-slope-manifest-stale
description: "2026-08-11 mountain ladder + fall-under ROOT = FP_MANIFEST_SLICE defers slope-manifest bake past generator freeze (empty slope_arid + stale model_count in GDScript gen AND C++ VoxelGeneratorCosmos Parameters, COW reassignment never propagates) → render cube-fallback vs analytic carved plane, gap ≤3 blocks; fix FP_SLOPE_MANIFEST_HEAL generator swap at cold-bake stage 3"
metadata: 
  node_type: memory
  type: project
---

2026-08-11, task #111 (facet 578 snowy mountain, NAV 13038,69,8156): "ladder-style slope" + "falls under
the slope" are ONE bug and it is NOT worldgen. `slope_run=-1` on the analytic path RECOMPUTES the carve
(byte-identical), the C++ FP_CPPGEN port carves faithfully, and the carve FIRES (955/1125 columns probed
against the served pck). The regression: `FP_MANIFEST_SLICE` (ON live) defers `_build_slope_manifest`
until after `_make_generator()` freezes `slope_arid`/`snow_slope_arid`/`model_count` into the GDScript
gen (module_world.gd:3984-4017) and the C++ `VoxelGeneratorCosmos` immutable Parameters (:4069). The
cold bake REASSIGNS `_slope_arid` (:1428, PackedInt32Array COW) so no live generator ever heals; the
stage-3 re-ramp regenerates with the SAME stale generators → every SLOPE cell renders the cube fallback
(patch 0007 cell_to_arid → cube_arid[id]) while `floor_under`/`GroundCollider` walk the carved plane —
render up to SLOPE_MAX_SPREAD=3 blocks ABOVE physics. Same staleness hits wet + snow-fill comp tables.

**Why:** verify_cppgen compares values with test-baked tables and verify_manifest_slice checks only the
module MEMBER tables — no gate reads a generator's FROZEN copy, which is what workers use.

**How to apply:** fix = `FP_SLOPE_MANIFEST_HEAL` — at `_manifest_cold_step` stage 3, rebuild + swap
generators (active + all pool slots) via `_make_generator`, THEN `_manifest_remesh_near`; never push
tables into live generators (worker race + immutable C++ Parameters + stale model_count OOB fence).
Doc: docs/COSMOS-SHARP-SLOPE-FACET-PARITY-DESIGN.md. Technique: dump served flags/probes by running the
custom editor `--main-pack build/web/index.pck -s <external .gd>` (in-tree consts are stock-false; the
deploy bakes flags). Related: [[voxiverse-floor-surface-root-cause]] [[voxiverse-l5a-cppgen]]
[[voxiverse-faceted-planet]]
