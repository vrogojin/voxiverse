---
name: voxiverse-night-terrain-centre
description: 2026-07-31 SOLVED "red lava/terrain lit at night, per-facet offset, reversed sweep" = near-field terrain/sea shader normal used normalize(v_wp) assuming planet centre=origin; faceted render centre is offset per-facet → wrong normal. Fixed FP_NIGHT_TERRAIN_CENTRE + set_time floating-origin fix
metadata:
  node_type: memory
  type: project
---

**"Terrain/water lit at night" (bright orange/red facets, per-facet-offset day/night, reversed E→W sweep, red water seas) SOLVED + live-verified 2026-07-31 (deploy/cheats-eyeball; flags FP_NIGHT_TERRAIN_CENTRE + the set_time fix; verify_tier_shade 157/0, FLAT 6042/0).**

USER-VISIBLE SYMPTOMS (all ONE bug, surfaced by the user's frame-by-frame observations): a terrain/sea region renders fully DAY-lit at local night (bright orange, "looks like lava"), fades on re-bake, sweeps the sun WEST→EAST (reversed), different facets have DIFFERENT brightness-time offsets (patchwork of correct-blue vs mis-lit-red water side by side at the same instant). NOT lava (temperate ~20°C, blue water; lava seas only where worldgen temp ≥ LAVA_SEA_T 0.60). NOT the dev red/magenta CosmosBorderOverlay markers (those are thin emissive pillars; DEV_BORDERS=true SHIPS LIVE — a separate cleanup candidate).

ROOT CAUSE: the NEAR-FIELD DAYLIGHT TWINS (terrain + translucent SEA shaders — NOT block-LOD/far-ring, which are correct) compute the day/night radial normal as `n = normalize(v_wp)`, assuming the planet centre is the SCENE ORIGIN. But in the live FACETED build the render frame = T_active⁻¹ so `planet_render_centre() ≠ 0`, and the error vs the true radial DEPENDS ON THE FACET'S POSITION → each facet gets a different wrong normal → different `μ=n·ŝ` offset (patchwork), and a mirrored normal field inverts the E–W gradient (`dot(mirror_n,s)≡dot(n,mirror_s)`) → reversed sweep. Files: `voxel_module/block_atlas.gd:69` (module path) + `block_materials.gd:52/79/101` (fallback/water/debris incl. the flat sea). SAME bug CLASS as set_time. The sun_dir uniform WAS pushed per-frame (not stale); the frozen wrong quantity was the CENTRE (hardcoded 0).

FIX: `FP_NIGHT_TERRAIN_CENTRE` — near twins use `n = normalize(v_wp − planet_centre)`; `WorldManager.set_near_daylight_sun_dir` feeds the true render centre (`_facet_ring.render_centre()` = far shell's MODEL·0) into the module atlas twin + BlockMaterials twins every frame. (FP_SHADE_UNIFIED had done this for the atlas path only; this adds the BlockMaterials twins + the isolated normal fix.) Gate `verify_tier_shade.gd` (G-TS-MATCH/NEARNIGHT/WATER/FALSIFY/SHADER) 157/0.

ALSO FIXED same session (same floating-origin class): `remote_set_time` used raw `global_position` as up_bf → wrong local time far from spawn (day/night ~12h off) → my OWN earlier day/night TEST screenshots were misleading artifacts. Fixed: `up_bf = global_position - planet_render_centre()` (commit 4aa9d56).

LIVE VERIFY (pos ~−24766/−31297, far from spawn where worst): set_time 0 → uniformly DARK terrain; set_time 12 → uniform daylit forest. No patchwork, no bright-at-night.

STILL OPEN (separate, flagged not fixed): the SUN DISC looks dim/unrealistic at horizon RISE — a sky-shader low-elevation sun-brightness issue (cosmos_sky.gd), NOT the tier shade. Related: [[voxiverse-orbit-real-space]] (FP_SKY_PLANET_CENTRE — the sky's cam_rel = the same centre correction), [[voxiverse-fallthrough-loc-bug]] (deploy reverts CS/RB), [[voxiverse-atmo2-design]].
