---
name: voxiverse-perf-next-architecture
description: Post-atlas perf roadmap 2026-07-17 — far-ring exclusion gap root cause + underlay/static-ring design; architecture verdict = keep faceted stack; unexplained 8-15ms frame gap needs scale3d/hidden-near split
metadata: 
  node_type: memory
  type: project
---

Fable analysis 2026-07-17 (`docs/COSMOS-PERF-NEXT-ARCHITECTURE.md`), after PR #19 (draws 204→74-87, fps 30-42, crossing ~140ms):

- **Obs-1 root cause (code-verified):** far ring excludes active+pool facets *binarily* (`world_manager.gd _facet_ring_sync_exclusion` → `facet_far_ring.gd _front_visible`) but near coverage is a 128/96-block disc on ~201-block facets → tracking annular hole shows planet interior (ring is CULL_DISABLED). Fix designed: **underlay** — draw ALL facets with min-filtered conservatively-sunken quads (+~1.5-2 block sink) + player-bubble shader discard (r≈32, edit safety); optional whole-planet static ring (3456 facets, ~110k tris, +7MB, zero rebuilds ever).
- **Architecture verdict: keep** faceted + fixed_lod pool + far layer. VoxelLodTerrain is Transvoxel/smooth-only through voxel 1.6 (no blocky LOD upstream) — cannot subsume the far ring without abandoning blockiness.
- **Unexplained 8-15 ms**: at 74-87 draws the draw slope explains ~4-6ms, base modeled 10-12ms, yet frame is 24-33ms. Must split via `?scale3d=` A/B (canvas follows devicePixelRatio — possible fill wall) + DEV_HIDE_NEAR floor before picking the next big lever.
- **L4 64³ nuance:** far ring commits ~4.6MB in one frame WITHOUT hanging; the 64³ hang may be pacing/many-buffer-creations, not size — ½-day attribution spike could unlock a GDScript settled-terrain baker with paced ≤512KB sub-uploads (last gl-compat draw cut).
- Obs-3: predictive viewer offset (velocity lookahead, clamp ~48 blocks) safe-tonight; soft speed clamp needs user (feel). Fall-through should be impossible (analytic physics) → instrument before fixing.
- WebGPU unchanged per [[voxiverse-godot-migration]]: unavailable through 4.7; migration stays post-FP-M2 positioning.
