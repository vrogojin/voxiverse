---
name: voxiverse-fall-stream-pacing
description: 2026-08-22 de-orbit fall jerk ROOT = update_streaming tail (skin re-rank + tex SSE re-tier + DEM) unpaced by motion; alt-700 spike = ANCHOR_REL_LO knee NOT ATMO_TOP; design FP_STREAM_FALL_PACE + FP_REENTRY_VIEW_RAMP
metadata: 
  node_type: memory
  type: project
---

Task #144 (2026-08-22): de-orbit fall t_stream_us 14-16ms steady / 38ms spike. Design done in
docs/COSMOS-FALL-STREAM-PACING-DESIGN.md (deploy-cheats worktree), impl pending.

- t_stream_us times ONLY WorldManager.update_streaming (player.gd:920-922). FacetFarRing (own
  _process) and godot_voxel mesh work are NOT in the bucket. Steady cost = 3 tail drivers with no
  motion signal: skin tier full re-rank+coverage probes (wm:1333), facet-tex 5ms budget checked
  BEFORE each unit + SSE re-tier churn as cam_dist shrinks (wm:1388-1419), G2 DEM (wm:1431).
- alt~700 spike is NOT ATMO_TOP(384): it is ANCHOR_REL_LO=700 — _apply_approach_anchor jumps
  viewer view_distance 13-40+ blocks per 100ms write at descent speed → one-step near-stream demand
  (phys 48.6ms). Second burst at alt~70 full residency.
- GOTCHA: _fall_vy_ema is USELESS at plunge speeds — VEL_PREDICT_SPEED_CLAMP=40 b/s rejects orbital
  fall samples as "relocation". Fix uses a NEW radial-altitude-rate EMA (_radial_altitude_lattice is
  flip/crossing-continuous; only a 2000 b/s teleport clamp needed).
- Design: FP_STREAM_FALL_PACE (round-robin the 3 drivers 1-of-3/frame while alt-rate < −15 b/s;
  −15 chosen above walk 0-9, below SN-BRAKE terminal 20 so surface-entry stays paced) +
  FP_REENTRY_VIEW_RAMP (anchor_grow_clamp: growth ≤8 blocks/write on fast descent; shrink and
  teleport paths untouched). FP_ALT_REGIME's one-shot 416 redesignation deliberately untouched (it
  IS the fall-through fix). Stepped set_alt profiling bands are frozen ⇒ rate 0 ⇒ pacing dormant —
  they double as the A/B no-regression control; only a REAL fall shows the win.

Related: [[voxiverse-motion-phys-root]] (FP_STREAM_TICK_ONCE tail), [[voxiverse-deorbit-phys-fix]],
[[voxiverse-orbit-perf-farring-churn]].
