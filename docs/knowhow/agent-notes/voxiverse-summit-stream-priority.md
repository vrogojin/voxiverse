---
name: voxiverse-summit-stream-priority
description: 2026-08-11 summit near-blocks arrive last ROOT = approach-anchor pins viewer to DATUM not sub-player ground (offset −62 at h=66 → priority inversion) + landing-kick pace floor dead in 96-block ridge warm band + chronic credit-0 (p90>2×p10 client);
metadata: 
  node_type: memory
  type: project
---

Task #109 root cause (design-only, doc COSMOS-SUMMIT-STREAM-PRIORITY-DESIGN.md in deploy-cheats worktree):

1. **#107 pre-existing verdict**: `is_smooth_resident` consumed ONLY by blocky-LOD tiers (facet_lod_mesher/block_lod_ring/ladder); NO near-field VoxelTerrain path reads it — #107 only changed the stall's cover (giant blocks → smooth).
2. **Anchor bug (summit-specific)**: `_update_approach_anchor` runs every tick grounded too; h = radial-above-DATUM (world_manager.gd:630), `approach_offset_y` (cube_sphere.gd:2231) pins viewer world alt to o_base=0 (FP_VIEWER_RELIEF_REACH makes clamped_viewer_offset_y()=0) → at 66-block summit viewer sits 62 BELOW feet → godot_voxel priority (strict 3D distance to viewer, priority_dependency.cpp band0=MAX−d>>4) serves invisible mountain interior FIRST, visible summit surface LAST.
3. **Dead pace floor**: FP_LANDING_STREAM_KICK floor + view_target repair (module_world.gd:522-528, 593-595) guarded by `_imminent_fid < 0 or == _pool_active`; imminent is selected whenever within POOL_D_WARM=96 of a ridge (~⅔ of a 417-450 facet) → active slot advances at pace 0 while ALSO burning the single grow channel ("active wins", l.553-560).
4. **Credit trap**: FP_CTRL_ADAPTIVE setpoint = clamp(p10×2, 18, 45); high-jitter 40fps client (p90 32 > setpoint 31) is pinned credit-0 forever → stream_pace 0.
5. Facet-748 summit probe: min ridge dist 141 > 96 ⇒ imminent −1 AT the peak (freeze binds on the approach). Live flags baked by scratchpad/deploy_cheats.sh sed (repo consts all false — always check CS_FLAGS there).
6. Fix flag FP_SUMMIT_STREAM: S1 h_eff = h − ground_h (analytic col memo) in _apply_approach_anchor; S2 drop the imminent guard on the active floor/repair; S3 optional pace-1.0 until near_column_meshed. Gates verify_summit_stream.gd (OFF-byte, anchor, floor, order-proxy, budget).
7. `dropped_block_loads` is LIFETIME-cumulative for fixed-lod VoxelTerrain (no reset, unlike lod terrain) — telemetry treats it as a windowed rate, wrong.

**IMPLEMENTED 2026-08-11** (SummitStream agent) — FP_SUMMIT_STREAM committed 379ad629 on deploy/cheats-eyeball (byte-off const:=false; NOT merged/deployed — awaiting live eyeball). S1 world_manager.gd `_apply_approach_anchor` ~:689: `h_eff = max(h - ground_h, 0)`, ground_h = `surface_y(x,z)` → `_radial_altitude_lattice` (memoized col, zero new cost), used for BOTH offset and release d. S2 module_world.gd `_ramp_pool_step` ~:523 (target-repair) + ~:598 (pace-floor): guard relaxed to `(CubeSphere.FP_SUMMIT_STREAM or _imminent_fid < 0 or ==_pool_active)` so the resident active slot is ALWAYS repaired+floored at CTRL_RELIEF_FLOOR (maxf composes with imminent floor; view_target capped at near_render_radius). **S3 SKIPPED** — pace-1.0 is a supply increase needing grounded-state plumbing into the module, contrary to the reorder-only/no-convoy mandate; S1+S2 suffice without touching the load rate. Gate verify_summit_stream.gd (G-SS-OFF/ANCHOR/FLOOR/ORDER/BUDGET): OFF 20/0, ON 22/0. Regressions green: FLAT verify_feature 6042/0, verify_faceted 137/0, verify_stream_parallel 57/0, verify_fast_load 41/0. Gate note: PART A pure-math + PART B bare-ModuleWorld pool hooks (test_seed_pool_slot/pool_ramp_tick) always run; PART C driver (real WorldManager, scanned summit column) skips cleanly if module/FP_APPROACH_ANCHOR absent.

Related: [[voxiverse-streaming-supply-demand]] [[voxiverse-fast-load]] [[voxiverse-walk-perf-root-cause]] [[voxiverse-nb-fullres]]
