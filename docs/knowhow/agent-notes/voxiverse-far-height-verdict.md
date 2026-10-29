---
name: voxiverse-far-height-verdict
description: 2026-08-15
metadata: 
  node_type: memory
  type: project
---

Tasks #72 (far terrain below near blocks) + #73 (orbit/de-orbit facet misalign), root-caused
2026-08-15, doc COSMOS-FAR-HEIGHT-DESIGN.md. Served-pck audit (deploy-worktree build/web/index.pck,
542 consts, load_resource_pack + get_script_constant_map): FP_DATUM_BAKE=true, FP_RADIAL_DATUM=false,
full applied-cover chain + FS1 weld + FIXED_FRAME all live.

- **Ground tiers have NO datum omission** (unlike far trees #131): far-ring `_weld_place`
  (facet_far_ring.gd:3870/3947), V2 native canon-dir bake (facet_smooth_v2.gd:51-52),
  orbit-relief d*(r_datum+relief) (facet_orbit_relief.gd:250) all emit RADIALLY on the sphere;
  near lift p0+(g+s)n̂ agrees ≤0.03 blk. The datum class only bites tiers anchored via
  lattice_to_world64 without the lift.
- **#72 residual**: in the annulus beyond applied_r (≤112), visible skin = max(backstop zone-B
  TRUE−1.5 corner-MIN, V2 near-fill TRUE−6.0). On relief the corner-MIN backstop falls away ⇒
  the V2_NEARFILL_SINK 6.0 (cube_sphere.gd:1722, applied facet_smooth_v2.gd:537/:92-93) is the
  visible ~6-blk sunk skirt. Fix design: FP_V2_NEARFILL_UNSINK — geometry unchanged, flag-gated
  VERTEX SHADER recovers p_true and applies the backstop's three-zone law via 4 uniforms
  (col/applied_r/params/band) — zero rebuild churn (the reason NOT to re-tile per ladder step).
- **#73 structural classes CLOSED** (FP_SHELL_WELD + FP_DATUM_BAKE + FP_FIXED_FRAME +
  FP_DESCENT_FACET_RESYNC + FP_UPVECTOR_FACET_HEAL): no relative facet tilt possible — all far
  tiers are children of ONE ring node in absolute welded coords (facet_smooth_v2.gd:407-409,
  facet_orbit_relief.gd:495); FACET_TWIST=false; the C4 datum/basis twin is excluded for GROUND
  tiers (§1.1 radial emit). Un-excluded: runtime pose-desync transients ([[voxiverse-tasks-72-73-state]]
  C1-C5) — hold for a reproducing frame; gate = scripted flight, not static weld.

LESSON: when a "too low" report survives many shipped fixes, separate the WRONG-height class
(coverage/datum bugs) from the DELIBERATE-sink class (no-protrusion guards) — the residual lives
in whichever deliberate sink is the max() winner at the frontier, and the fix is porting the
zone law to that tier, not another coverage probe.

Related: [[voxiverse-fartree-frame]] [[voxiverse-grassbase-backstop]] [[voxiverse-mesa-viewband]]
[[voxiverse-lod-ladder-midband]] [[voxiverse-facet-seams]]
