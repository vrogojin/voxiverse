---
name: voxiverse-orbit-relief-g3
description: "2026-08-10 G3 far-terrain 3D relief from orbit SHIPPED+MERGED (PR #39 447d038) — FacetOrbitRelief tier: DEM-displaced mesh + fine-map texture + terminator-only light (no slope shade) + edge-sink-at-commit + slot-arena/on-surface-suspend; user-confirmed. OPEN: slow reload load (DEM bake convoy)"
metadata:
  node_type: memory
  type: project
---

User wanted real 3D far terrain from orbit (mountains/valleys), combining high-res colour + brightness-aware lighting + 3D + performant. SHIPPED + MERGED to main PR #39 (447d038), user-confirmed live "looks great" @ ~40fps orbit steady.

**Tier**: FacetOrbitRelief (godot/src/world/facet_orbit_relief.gd), owned by FacetFarRing, behind FP_ORBIT_RELIEF (byte-off). Data source FP_GLOBAL_RELIEF_DATA = GlobalReliefData whole-planet i16 DEM (32 cells/facet, 13-block pitch, ~7.5MB, baked bg via bake_smooth_tile patch 0012). View-dependent: want_set ranks by min(nadir-dist, horizon-ring-dist), ORBIT_RELIEF_MAX_TILES cap; on-surface SUSPEND (shell_offsurface gate — G3 useless on ground, near+V2 cover it).

**The 4 things it took to make it usable (each a live A/B round after the first coarse+bright+seamy+laggy deploy):**
- COLOUR (was coarse ~104-block squares = shell _col_cache 5×5/facet): UV-map the FP_PLANET_MAP fine map (768²/64² texels, 16× finer, ~14MB already resident) onto the mesh — per-node UV from facet (s,t) via _tex_decode, G3-owned shader with sampler2DArray fine_map + far_lut[14] + _FINE_ELSE texelFetch decode, ALBEDO=fine×v_st, texel==0→coarse fallback.
- LIGHTING (was always-bright + per-facet day/night steps): ROOT = sun_dir FROZEN at material build, live-sun push never forwarded to _orbit_relief (per-facet step is cross-tier: G3-committed frozen vs neighbours live). Fix: set_sun_dir forwarded from set_shell_absolute_sun_dir hub. USER REJECTED SLOPE SHADING ("ugly") → v_st = voxi_shade(RADIAL normal, sun) ONLY (flat-skin terminator, day/night); NO real-normal relief/lambert term → dropped ARRAY_NORMAL + _fill_analytic_normals entirely (−12B/vert).
- SEAMS (black facet-edge lines): ROOT = no-protrusion edge-sink baked at BUILD from aspirational want-set + a corner node double-sunk (sunk_positions read-modify-write once per flagged edge; a corner on 2 edges sunk twice). Fix: sink each node once (union) + edge-sink computed at COMMIT from actual committed set.
- PERF (was "extremely laggy" 8fps/250ms stalls, then 40fps): ROOT1 _commit re-merged ENTIRE resident set via merge_tiles idx-remap loop (384×6144≈2.36M interp iters ≈100-300ms/commit) + SurfaceTool.generate_normals on 418K verts on MAIN thread. Fix: normals computed off-thread (then dropped entirely, see lighting) + FIXED-SLOT ARENA (persistent slot/fid, worker builds remapped idx, commit range-copies ≤ORBIT_RELIEF_COMMIT_TILES=24 changed tiles, add_surface_from_arrays, NO SurfaceTool/generate_normals) → commit ~8ms. ROOT2 near-full residency on ground → on-surface suspend.

**Perf reality**: orbit steady ~40fps (was 8fps disaster; G3 relief mesh ~1.08M prims costs ~15-20fps vs colour-only 60fps — acceptable tradeoff for real 3D). draws 34 (merged). Arena ~26.5MB, DEM 7.5MB — NEVER-OOM fine.

**Gates**: verify_orbit_relief 75/0 (OFF/TEXTURE/SUN/SEAM/COMMIT-COST/SUSPEND/BYTES/LIGHT/DATA-EQ/WELD), far_geometry 20/0, relief_reemit 17/0, far_smooth 515/0, FLAT 6042/0.

**OPEN follow-up**: fresh-reload LOAD is SLOW (~2-3min, fps 4→28 climbing) — the whole-planet DEM bake (FP_GLOBAL_RELIEF_DATA) competes with the near-field/colour-skin load convoy on the main thread; on-surface suspend gated G3's MESH but NOT the DEM bake. Fix idea: throttle/gate the DEM bake off the load path (only bake off-surface/idle, or lower budget). Also: shading flags FP_SKIN_RELIEF_SHADE/FP_RELIEF_REEMIT shipped DORMANT (byte-off, user rejected shading).

**Process lessons this arc**: (1) team of 3 Fable investigators (colour/lighting/perf) in parallel → synthesis → impl worked well for the multi-symptom fix. (2) impl agent (skin-block-arch) repeatedly resumed with wrong cwd / stale context / thought done-when-not — grep-PROOF corrections (grep returns 0/18) snapped it out each time; verify agent claims against real code before trusting "done". (3) a gate can pass on rate/count but miss per-commit DURATION (the 250ms stall slipped G-OR-PACE) — assert cost/duration, not just structure. (4) deploy_cheats.sh sed-flips CONTROL_ENABLED true→deploy→git-revert; a concurrent agent caught the transient true — sequence deploys after agents idle. (5) remote-bridge flight schema: set_time.local_hours (not hours), freeze_*/dev_nav need on:bool, wait.seconds≤60, look can't force nadir in orbit (camera holds horizon), reload op works under unattended grant. Related: [[voxiverse-far-geometry-prebake]] [[voxiverse-far-skin-block-color]] [[voxiverse-remote-bridge]] [[voxiverse-never-oom-web]].
