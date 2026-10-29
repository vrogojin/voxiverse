---
name: voxiverse-sn1-orbital-substrate
description: SN1 orbital substrate (FP_M3_ORBIT) — f64 kernel landed+gated; interactive player/world loop deferred to live session
metadata: 
  node_type: memory
  type: project
---

SN1 = the ORBITAL substrate, branch `feat/voxiverse-sn1` (off feat/voxiverse-spacenav). Implements O1O4 Part A MINUS H_FARSWAP (R1 rejected) PLUS GM_dyn (SPACE-NAV §3). Flag `FP_M3_ORBIT` default false, flag-off byte-identical (FLAT 6035/0).

**Landed + gated (2 commits):**
- O1a (kernel): `cosmos_gravity.gd` (GM_dyn = GM_game·(R_vox/R_eph)³, 3-regime blend field, point-mass gravity_bci), `orbital_state.gd` (f64 BCI [pos,vel], velocity-Verlet + 1/60 substep clamp, freeze-to-Kepler rv↔coe, §2.4/§5.1 frame algebra, §2.6 drag, anchor_snap/place_rel), `cosmos_ephemeris.gd` (+body_vel_helio). Gate `verify_orbital.gd`: G-SN-SCALE/O1-FIELD/ENERGY/KEPLER = 30/0.
- O1b (wiring MATH): gate `verify_orbital_wiring.gd`: G-O1-HANDOFF/DRAG/REENTRY/ANCHOR = 21/0.
- Every gate falsified (sabotage→red→restore).

**Two deliberate deviations from the literal design (both disclosed, more conservative/self-consistent):**
1. G-O1-FIELD "monotone on ramp" is POST-O3 only — at interim R=3072 feel_g(22)<datum GM_dyn/r²(24.6) makes a ~3% hump; gate asserts the true invariant (|g| bounded between the two regimes) + strict monotone above HI.
2. Drag K0 = datum_gravity/DRAG_TERMINAL² (not design's FEEL_G/…) so terminal=55 balances the integrator's actual point-mass gravity; integrator uses point-mass (§2.3) not the blend, so this is self-consistent.

**DEFERRED to the live/morning session (NOT built):** the interactive player.gd PMode ORBITAL loop (input→gear-2 thrust→integrate→node placement), mode transitions/hysteresis, world_manager anchor-follow node re-placement + prepare_landing, orbit HUD. Reason: live-only-validated per design + byte-identity-critical; conservative choice not to ship unvalidated FPS-controller surgery overnight. The MATH those need is all built + gated.

GM_dyn: earth interim R_vox=FacetAtlas.R_BLOCKS=3072 (→identity post-O3 resize); moon R_vox==R_eph==1737 (identity today). See [[voxiverse-orbital-o1o4-staging]] [[voxiverse-seamless-scales]] [[voxiverse-never-oom-web]].
