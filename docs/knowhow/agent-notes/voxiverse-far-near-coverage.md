---
name: voxiverse-far-near-coverage
description: 2026-08-11
metadata: 
  node_type: memory
  type: project
---

2026-08-11 task #110 (facet 578, NAV 13034,110,8153, snowy mountain): the smooth grey surface
protruding over near blocks is **FacetOrbitRelief (G3, FP_ORBIT_RELIEF)** — on-surface it stays a
*frozen, visible, un-sunk* draw (facet_orbit_relief.gd:613-645, OFFSURFACE_Y=256) of exact
profile_at_dir chords at 13-block DEM pitch, interior "accepted at face value" (:276-290 admits the
FP_ENV_ALL bug class). Measured: G3 chords >fine surface over 35.4% of the repro window (worst
+2.03), and the realized near tops are a further 0.6 (top-face datum) to 3.6 (sharp-slope carve,
Tw−g ∈ [−3,4]) blocks below profile ⇒ G3 rides ~0.5-5.6 blk above real blocks over ~half the window
(dendritic blob). Flat-grey look = G3 coarse_color fallback (fine map unbaked post-teleport).

**#107 FP_SMOOTH_V2_NEARFILL EXONERATED by measurement** (hypothesis "sink-6 insufficient"
FALSIFIED): tile chord-over-fine worst +1.25 facet-wide; with sink 6 ⇒ worst −4.76, 0.0% above.
Pre-existing (G3 PR #39 predates #107); #109 summit streaming just exposed it. User's
"disable far at full near coverage" gate = wrong target + wrong granularity (facet 417 blk vs near
disc 128; near_column_meshed is a player-column probe). Right fix: **FP_ORBIT_RELIEF_SURFACE_HIDE**
— `_mi.visible = ring.shell_offsurface()` in FacetOrbitRelief.step(); backstop+V2+near-fill keep
coverage, frozen tiles stay warm. Doc: docs/COSMOS-FAR-NEAR-COVERAGE-DESIGN.md; probes
src/tools/probe_{nearfill_protrude,nearfill_vs_near,nearfill_dirmap,orelief_protrude}.gd.
LESSON (again, cf [[voxiverse-seam-mask-fallthru-law]]): measure the sign before blaming the newest
change — the "obvious" #107 regression was innocent. Also: this worktree has FACETED:=false
(deploy_cheats flips flags at export; live CS_FLAGS list is in COSMOS-LOD-LADDER-SMOOTH-DESIGN.md §1)
— headless column_profile falls to the FLAT branch; use facet_profile/profile_at_dir+cell_dir for
live-law probes. Related: [[voxiverse-orbit-relief-g3]] [[voxiverse-lod-ladder-smooth]]
[[voxiverse-tier-depth-priority]].
