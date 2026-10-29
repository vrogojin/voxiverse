---
name: voxiverse-fartree-shift-residual
description: 2026-08-13
metadata: 
  node_type: memory
  type: project
---

Task #120 residual (2026-08-13): far trees STILL read "a few blocks lower" after FP_FAR_TREES_ALIGN
shipped/live. Root-caused via served-pck const dump (headless `ProjectSettings.load_resource_pack` +
`get_script_constant_map` — works even when scripts are binary-tokenized; the strings-grep flag-dump
does NOT) + pixel-census of the live frames (flood-fill canopy blobs, count trunk px beneath;
FOV is 75° VERTICAL, player.gd:345 ⇒ f≈352px on 960×540 — an f=686 horizontal-FOV assumption
mis-bands every distance estimate by ~2×).

Measured: weld exact in the ramp-zero band [128,208] (full 2.3–3.7-blk trunks); deep band ≥288 =
0/~40 blobs with any trunk pixel. Residual = (a) FT_SINK_MAX=1.0 deliberate bury whose §4.3 premise
(visible far ground sunk) is FALSE post ground-welds — V2_NEARFILL_SINK=6 tier is deliberately
UNDER the visible surface; (b) REAL BUG: mesh+card fade shaders share the same `_ft_dither(FRAGCOORD)`
with same-sense compares ⇒ keep-sets NESTED not complementary ⇒ 448 handoff coverage = max(f) not 1
(50% at midpoint — trunks dissolve); (c) 1-blk-wide trunk < 1px past d≈350 (art legibility floor).

Fix design (docs/COSMOS-FARTREE-SHIFT-RESIDUAL-DESIGN.md): P0-a FT_SINK_MAX 1.0→0.15 (1 line, inside
ALIGN guard); P0-b FP_FT_XFADE_COMPL invert card dither (`1.0 - _ft_dither`) ⇒ union coverage 1;
P1 FP_FT_TRUNK_LEGIBLE optional (2-texel card trunk + distance-inflated mesh trunk verts);
P2 groundlock deferred (relief only; sample UNSUNK V2 node heights, clamp ±2). Gates G-FTR-1/G-XDC-1.

ALSO FOLDED IN (task #130, same doc §5): NEARCULL+DELTA restore-dwell stall — _compute_nearcull_fp
XORs only COVERED trees, so a COVERED→NOT_COVERED edge drifts the DELTA fingerprint ONCE, the restore
streak freezes at 1 of FT_CULL_DWELL=2 under a static camera → far tree culled forever (missing tree)
until camera moves 2blk. Zero gate coverage: all G-FTC-* drove debug_rebuild (bypasses DELTA). Fix =
state-fold: mid-restore trees contribute _mix(hash, streak) to the fp (+SALT_U while UNKNOWABLE so
frozen states are quiet but U→N drifts) — rebuilds fire exactly while the cull machine can progress,
bounded at DWELL+1, quiescent otherwise. Gate G-FTC-5 drives debug_step (the DELTA-gated hook).
LESSON: when a gated consumer's state machine advances only inside the gated action, the gate's
change-detector must encode the machine's mid-progress states or it starves them.

**LESSON**: a saturated "artistic" offset constant is indistinguishable from a placement bug to the
user; gates that assert the ramp SHAPE don't protect the percept. And screen-space dither cross-fades
between co-located LOD reps MUST be complementary (invert one sample) — same-sense dithers are
in-phase and halve coverage. Related: [[voxiverse-far-trees-design]] [[voxiverse-far-trees-colorfix]]
[[voxiverse-grassbase-backstop]]. Adjacent open defect: task #130 NEARCULL restore-dwell stall.
