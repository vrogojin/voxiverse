---
name: voxiverse-floor-surface-root-cause
description: "2026-08-06 ROOT of falls-under-ground — floor_under/surface_y disagree only via cross-frame reads (facet/pose transient desync + every-frame re-fire band), NOT datum/junction; fix = FP_QUERY_FRAME_GUARD + FP_FLOOR_SURFACE_WELD"
metadata: 
  node_type: memory
  type: project
---

Fall-under-ground ROOT (task #90, doc docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md):
floor_under and surface_y are PURE-IDENTICAL (same column_profile memo, same _datum_lift) —
the live −12.1/+11.9 pair is a CROSS-FRAME read: the (active_facet, position) pair is only
eventually consistent (two-phase crossing: set_active_facet commits, apply_reframe later,
_heal_frame_desync only next frame), and in the "re-fire band" (resolver vs seam own_dist
disagreement, e.g. 288 grow=0.5 columns, corner-slack 2.0 states) a crossing re-fires EVERY
frame — wrong-phase queries interpret raw (x,z) in the other facet's decorrelated lattice
(offsets ±32768) = a DIFFERENT physical column (ocean g=−15 → the deep floor).

Measured falsifications (probe godot/src/tools/probe_seam_tilt.gd, real atlas):
- ALL 13,824 seam planes have B>0 (domains NARROW with depth, tilt 0.024–0.033) ⇒ a
  past-ridge column is masked at ALL depths ⇒ floor_under falls back to
  effective_height+1+s == surface_y (safe by accident). Junction mask exonerated.
- 6,336 near-ridge columns, 8 facets incl. 348: ZERO pure disagreements. Datum exonerated
  (datum_lift stateless, same args both funnels; FP_RADIAL_DATUM retired ⇒ datum_shift 0).
- Headless CAN now repro: flip set_active_facet without reframe between the two calls.

ADJUDICATED vs FablePhys's competing "domain-mask + 30.6x lever" theory (2026-08-06): their
lever MAGNITUDE matches my measured tilt but the SIGN is backwards (B>0 everywhere ⇒ no
re-admission at depth — probed at their exact d values, zero solids in 200 blocks), and the
fully-masked fallback (wm:3776) is textually identical to surface_y (wm:3677) ⇒ the mask
CANNOT return floor<surface. Their FP_FLOOR_DOMAIN_WELD guards an already-safe state (keep
only as a perf short-circuit for the ~1000-cell masked scan); their entrance-window inventory
(move-before-cross ordering, 6-tick cooldown, corner containment) + FP_FALLTHRU_PROBE
telemetry (log active_fid vs _pos_fid at incidents) are worth adopting.

Fix (both const := false, byte-off): FP_QUERY_FRAME_GUARD — pass player _pos_fid into
floor_under/surface_y/blocked/ceiling; reframe_position64 the query point when it differs
from active (kills the class); FP_FLOOR_SURFACE_WELD — in floor_under, found < surface_y − FLOOR_WELD_EPS(2.0) at a
column NOT in _edit_columns ⇒ return surface_y (no-caves law; dug columns skip ⇒ no false
clamp). EPS is LOAD-BEARING (FablePhys, conceded-round hardening): shaped/slope span tops,
snow fill, and smoothed seafloors legitimately put floor fractionally below surface_y — a
bare < fires on every slope footprint and every swim. Composition: subsumes [[voxiverse-fallthrough-loc-bug]]
FP_TP_FLOOR_WELD for un-edited columns; orthogonal to FP_DESCENT_FACET_RESYNC (that class =
both funnels agree-and-wrong). Deploy note: flags/diag MUST be committed (deploy_cheats.sh
reverts cube_sphere.gd + remote_bridge.gd).

SHIPPED 2026-08-06 (commit 7e6c53b on deploy/cheats-eyeball, DEPLOYED live w/ 128 flags incl.
all three): FP_QUERY_FRAME_GUARD + FP_FLOOR_SURFACE_WELD(+FLOOR_WELD_EPS:=2.0) + FP_FALLTHRU_PROBE
(diag: records active_fid vs _pos_fid + own_dist under both on any sub-surface landing, merged
into player.gd nav_telemetry). Guard = one stamp-check per funnel entry, reframe only on
pos_fid!=active, READ-ONLY (never mutates position/_pos_fid; _heal_frame_desync stays sole pose
owner). Gate verify_floor_weld.gd = 24/0 (G-REPRO 12-block divergence headless + G-GUARD restore
+ G-WELD-FIRES/SHAFT + G-WELD-NOFIRE slope/snow/water within EPS); FLAT verify_feature 6042/0
byte-off. LESSON: impl agent's git-checkout to strip a sed flag-toggle WIPED uncommitted edits
(reverts whole file to HEAD) — use sed/Edit not git checkout; ALWAYS grep the real code before
deploy (an agent reported "24/0 done" on the pre-correction bare-< weld). LIVE: extensive play
(teleport-ins, ground runs, orbit climb, full de-orbit fall+land) — alt floor never <7.8, no
burial, probe silent, near blocks stream after reload. Could NOT script a ground facet-CROSSING
(thrust legs fly up / stay on one facet) → user walk-test is the real live crossing check.
SIBLING BUG (same desync family, 2026-08-06, [[voxiverse-player-upvector-tilt]] doc
COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md): after de-orbit the player UP-VECTOR is bound to
the wrong facet's normal ⇒ stands tilted ~≤3.75° (facet-step angle); Fable root-causing — the
orientation-domain analogue of this floor-domain cross-frame read.
