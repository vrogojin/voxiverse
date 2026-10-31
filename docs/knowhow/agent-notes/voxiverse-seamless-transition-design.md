---
name: voxiverse-seamless-transition-design
description: "2026-07-28 Fable design — fly-up near→far pop root cause = VoxelViewer child-of-player ellipsoid (up-reach 64 blk) unloads entire near field at h≈64 (22 px/block, ~10× the τ≈2px invisibility bar); fix is streaming POLICY not renderer"
metadata: 
  node_type: memory
  type: project
---

Design doc `docs/COSMOS-SEAMLESS-TRANSITION-DESIGN.md` (branch docs/voxiverse-seamless-transition, 79728b4, based on deploy/cheats-eyeball).

**Root cause of the fly-up pop**: `module_world.attach_viewer` (module_world.gd:2852-2877) parents the single VoxelViewer to the PLAYER — view_distance 128, vertical up-reach 64 (VIEWER_VERTICAL_RATIO 0.5 + A2 downward clamp) — so climbing ~64 blocks empties the whole near field while blocks still subtend ~22 px. The OFFSURFACE_Y=256 / FP_ALT_REGIME=384 freezes are NOT the visible cause (CPU-only). §2V closed the color gap; the residual is relief/trees/parallax + this one unload EVENT.

**Plan**: S1 `FP_APPROACH_ANCHOR` (FIRST SHIP, zero bytes) — pin the viewer to the sub-player surface point via the existing offset lever (DEV_HIDE_NEAR proves both levers safe), release rim-first via view_distance ramp only past D_REL=K_px/τ≈700, hysteresis; also improves descent (stream starts ~700 vs ~416). + S1b flip FP_FARRING_LEVEL (kills the 13-blk sink at reveal). S2 = FP_BLOCK_LOD rings (#76 in flight) under a 4-point transition contract (L1 engages at rim 128, one τ law, arrival dither only, containment+SHADE_UNIFIED). S3 band POM/height byte = likely cut. S4: continuous geomorph REJECTED for blocks (melting; DH precedent) — north star is the τ-continuum law: every seam screen-error-timed ≤τ px + albedo-shared + shade-shared + level-aligned + arrival-dithered.

Related: [[voxiverse-textured-lod-design]] [[voxiverse-block-lod-design]]
