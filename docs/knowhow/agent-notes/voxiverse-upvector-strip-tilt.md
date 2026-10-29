---
name: voxiverse-upvector-strip-tilt
description: "2026-08-06 post-de-orbit horizon tilt ROOT = hysteresis-strip facet desync (active facet ≠ soil owner), NOT a stale basis; measured 3.744° = facet step; fix design FP_UPVECTOR_FACET_HEAL; doc COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md"
metadata: 
  node_type: memory
  type: project
---

Post-de-orbit "player stands tilted a few degrees" (live, active facet 1356): the player up IS the
active facet (ActiveFrame = facet_transform(active), world_manager.gd:2584-2585; player basis is
yaw-only — player.gd apply_reframe). The tilt = a stationary equilibrium where the crossing law
(own_dist < −0.1 at lifted play-y) never fires while the junction mask (cell_seam_state at cell y)
already hands the soil cell to the neighbour, which renders it (FP_M1_POOL). Strip ≤ ~0.33 blocks
live (hysteresis 0.1 + seam-plane y-lean |B| ≤ 0.0332 × datum lift ≤ 6.9). Headlessly measured
(probe_upvector_tilt.gd, real atlas): 244/11,808 near-ridge stations are TILT_H equilibria (34 on
fid 1356), up divergence exactly 3.744°; corner-deferral tilt (TILT_C) = 0. Attitude machine
(ORBIT_ATTITUDE/LAND_RECOVER) exonerated analytically — handback drops roll, ≤ ~3 s residue max.
A frame-vs-pose mismatch is impossible given "standing fine": decorrelated facet offsets (±32768)
would displace km, not degrees. The fall-through welds ([[voxiverse-seam-mask-fallthru-law]],
[[voxiverse-floor-surface-root-cause]]) made the strip survivable — burial became the visible tilt.

Fix design (doc COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md, deploy-cheats worktree):
FP_UPVECTOR_FACET_HEAL — in maybe_cross_facet, before the final return {}: grounded + h_speed<0.5
+ own_min<0.3 + soil cell masked ⇒ commit crossing to facet_of_dir owner via _commit_facet_change
(corner-wall bound reused). Fixed point by mask complementarity (P3: owner masked=false) ⇒ no
ping-pong. Gate spec verify_upvector_heal.gd in the doc. Invariant worth keeping: any
set_active_facet MUST pair with a _commit_facet_change-style frame commit.

FOLLOW-UP (same day, live signal "tilt changes at borders, frequently a bit off"): adjudicated as a
SECOND, geometric class — player up is piecewise-constant (facet normal) while the perceived
horizon (far-ring limb/sky/ocean) is CONTINUOUS radial. Measured (probe_radial_vs_facet_up.gd):
cant 0.01° at facet centre → 1.81° edge-mid → 2.60° corner (~0.0045°/block); at every crossing the
up snaps the full 3.744° step while the radial horizon doesn't ⇒ apparent cant sign-flips ±1.9°.
NOT a phase/ordering bug (the up is written from the commit's own `to` inside _commit_facet_change
— nothing captures a fid). Options: accept / FP_CAMERA_RADIAL_LEVEL visual-only roll ease (kills
the crossing snap, but tilts the near floor instead — eyeball A/B) / radial-up player (continuum
refactor). Telemetry discriminates per incident: strip class active≠owner+masked+3.7°; geometric
class active==owner + cant matches position prediction.

USER DECISION: Class C = option (b). Spec written as doc §5 (FP_CAMERA_RADIAL_LEVEL): visual-only
roll about VIEW-FORWARD (aim −basis.z invariant by construction), phi_raw = atan2(u_r·r̂0, u_r·û0)
from the REBUILT body×pitch basis (never read _camera — feedback guard), applied
phi = smoothstep(16,96, alt-above-floor) · cos²(pitch) · phi_raw, per-frame flag-gated write at
the tail of Player._move AFTER the crossing/heal block + floor query (post-heal facet ordering).
Erases the roll component of the border snap exactly (screen-up tracks continuous radial);
forward-pitch component remains (honest residue → option (c)). Ground w=0 keeps the flat floor
true, so the heal's domain sees zero roll. Gate verify_camera_radial_level.gd: byte-off, analytic
roll vs projection form, blend law, crossing roll-continuity <0.05°, aim invariance, heal
composition; mid-altitude floor-vs-horizon balance is eyeball-only.
