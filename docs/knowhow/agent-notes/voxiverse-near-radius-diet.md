---
name: voxiverse-near-radius-diet
description: "2026-08-31 ground/descent jerkiness — near voxel field is a MAJOR cost (DEV_HIDE_NEAR bisection); FP_NEAR_RADIUS_DIET lever; descent gen scales r² (128→3953, 96→2190, 64→900)"
metadata: 
  node_type: memory
  type: project
---

**Ground/descent jerkiness — near voxel field is a confirmed major cost.** User-driven live bisection
(2026-08-31, bare-URL, remote-control unattended): `DEV_HIDE_NEAR` (collapse near render to N blocks) made
the game "much less jerky" → the near voxel field (godot_voxel gen+mesh+main-thread apply) is a big
contributor; a RESIDUAL jerk remained = the FAR tier (far-ring/skin/structures render blocky terrain
independently, so render distance looks unchanged even with near collapsed). GOTCHA: `DEV_HIDE_NEAR`'s call
site (world_manager.gd:658) is guarded `if not FLAT_WORLD` and FACETED⇒FLAT_WORLD=true, so it's INERT live —
drop the guard for the diagnostic. DEV_HIDDEN_VIEW_BLOCKS=8 (tunable).

**Live faceted near radius = CURVED_RENDER_RADIUS_BLOCKS = 128** (256 is flat-only; terrain_config.gd
near_render_radius()). This is THE single knob every ramp/anchor/pool cap reads for near streamed+meshed area.

**Fix = `FP_NEAR_RADIUS_DIET` + `NEAR_RADIUS_DIET_BLOCKS`** (cube_sphere.gd, committed 46c11a7, byte-off, FLAT
6042/0): near_render_radius() returns the diet value when on. Analytic physics/collider read TerrainConfig
directly (never the mesh) ⇒ movement/collision UNCHANGED — pure render-cost trade. Deploy sed via `NRD=<n>` env
in deploy_cheats.sh.

**MEASURED descent-landing peak vox_gen scales with near AREA (r²), observer-robustly** (set_alt 600 fall,
wf_vox_gen peak is a real counter, not frame-time):
| near radius | descent peak vox_gen | grounded prims |
| 128 | 3953 | — |
| 96  | 2190 (−45%) | 518k |
| 64  | 900  (−77%) | 458k |
Matches (r/128)² exactly (96→0.56×, 64→0.25×). diet=64 = biggest smoothness win; tradeoff is VISUAL only
(full-res near detail ends at 64 blk, blocky far tier fills out). Value is the user's visual-quality call.

**MEASUREMENT NOTES (this session):** (1) ground walking shows vox_gen=0 — terrain is pre-warmed, so the
184-248ms walk spikes over ?remote are the OBSERVER EFFECT (relay hitch ~200ms), NOT gen; use bare-URL for feel,
counters (vox_gen/draws/prims) for observer-robust A/B. (2) DESCENT (set_alt 600) is the clean heavy-near-gen
event. (3) control caps: move.blocks ≤ 128; turn uses "degrees" not "deg"; one bad step rejects the whole seq.
(4) reload reconnect ~110s. NEXT: far-tier residual (near ON, far OFF flip); near-field mesh-apply pacing.
[[voxiverse-ground-walk-perf]] [[voxiverse-village-bake-memo]] [[voxiverse-deploy-cheats-pipeline]]
