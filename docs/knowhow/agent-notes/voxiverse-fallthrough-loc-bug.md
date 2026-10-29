---
name: voxiverse-fallthrough-loc-bug
description: 2026-07-31 SOLVED — dev geo-teleport lat8/lon2 buried alt-−17 = floor_under≠surface_y (NOT facet); fixed FP_TP_FLOOR_WELD (live alt 7 grass); + deploy-pipeline reverts CS/RB lesson
metadata:
  node_type: memory
  type: project
---

**Dev geo-teleport fall-through SOLVED 2026-07-31 (deploy/cheats-eyeball e981ba2, live-verified: teleport lat8/lon2 alt30 → settles alt 7 on GRASS, air/ground 18.6/19.0°C, not −17 deepslate).**

Symptom: `teleport {lat_deg:8, lon_deg:2, alt:30}` buried the player on deepslate at radial alt −17 (aim "deepslate (−10925,−18,−232)"), open sky above. Reproducible + location-specific, but a DEV-TELEPORT bug — that column is normal grass+trees from above, and normal walking there is fine (6450-col sweep).

ROOT CAUSE (measured LIVE via temporary tp_debug telemetry; headless NEVER reproduced it — the pure functions agree): at this facet column `floor_under` (the analytic column-scan the FALLING player lands on in `player.gd _move`, `world.floor_under(x,z,y)` ~line 1719) returns **−12.1** while `surface_y` (the shared-heightmap law the MESH follows) returns the correct **+11.9** — a ~24-block floor↔surface disagreement (datum/column-scan mismatch) on the **SAME, CORRECT facet 348** (own_dist **+55.8**, NO crossing fires). The falling player tunnels the true grass surface and settles on the deep fill. `_dev_land_clamp` (surface_y guard) clamps once then disarms → `_move` re-drops to floor_under.

WHY 2 PRIOR FIXES FAILED: both chased the FACET. `FP_DEV_TP_REFRAME` (owner via `facet_of_dir`) and the facet-weld (re-assert owner + suppress `maybe_cross_facet`) solved a non-problem — live telemetry proved facet was ALWAYS 348, own_dist +55.8, no crossing.

FIX (`FP_TP_FLOOR_WELD`, player.gd): on a dev geo-teleport arm `_tp_land_frames`/`_tp_land_x/z`; in `_move`, while within 3 blocks of the teleport column, `terrain_floor = maxf(terrain_floor, world.surface_y(x,z))` → land ON the analytic surface; release on walk-away (floor_under correct there). Dev-only (armed solely by `_dev_teleport_geo`); off-flag byte-identical (FLAT 6042/0). The deeper floor_under↔surface_y disagreement (datum-collision class, see [[voxiverse-deorbit-phys-fix]]) is left unaddressed — weld sidesteps it for the teleport landing only.

**DEPLOY-PIPELINE LESSON (cost hours 2026-07-31): `scratchpad/deploy_cheats.sh` runs `git checkout -- cube_sphere.gd remote_bridge.gd` (CS/RB) at the START and END of EVERY deploy** (to revert the flag / CONTROL_ENABLED seds). This ALSO reverts any UNCOMMITTED edits to those two files before export. My tp_debug telemetry merge was in remote_bridge.gd → reverted out of every build → diagnostics never reached telemetry → every fix looked byte-identical (−17). I first misdiagnosed as browser/Service-Worker cache — WRONG: there is NO service-worker file in build/web (index.html calls installServiceWorker but none is generated), reloads DO load fresh, the served .pck is current (no-cache). To ship a change in CS/RB you MUST commit it (deploy reverts to HEAD); player.gd + other files keep uncommitted edits through the deploy. Live diagnostics that must survive a deploy → commit them or put them in a non-CS/RB file. Also: the remote `reload` op = plain `location.reload()`; a heavy build's initial bake drops fps to ~2–6 for ~60–90s before recovering — always wait for fps≥20 before driving.

Related: [[voxiverse-block-lod-design]] (dev-instrument ops teleport/set_alt/freeze), [[voxiverse-deorbit-phys-fix]] (FP_ANALYTIC_COL_MEMO / floor memo class), [[voxiverse-orbit-real-space]].
