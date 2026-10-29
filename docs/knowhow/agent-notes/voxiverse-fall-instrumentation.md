---
name: voxiverse-fall-instrumentation
description: 2026-08-22 de-orbit fall perf instrumented — STREAMING (t_stream_us) is the dominant main-thread cost the whole descent; hot bands alt~700 (regime/phys 48ms) + alt~70 (surface entry 83ms); NOT scaled-body
metadata: 
  node_type: memory
  type: project
---

2026-08-22 (after P7 prebake merged). Instrumented the de-orbit fall (user: "instrument the perf during the fall").

METHOD gotchas:
- The actual freefall from alt 2500→7 is FASTER than 1Hz telemetry can resolve — captured in <1 telemetry sample
  (2530 → 7 in consecutive rows). At 1Hz the "fall" window is really POST-LANDING at alt 7. To resolve the dynamic
  descent frame-by-frame needs ?telem=10hz (FP_TELEM_10HZ, live in the deploy set; interval→0.1 at remote_bridge.gd
  :400-402, correctly overrides the FP_TELEM_LITE 1Hz default at :409). The URL param must be present:
  https://voxiverse.game-host.org/?remote=<token>&telem=10hz — a plain reload comes back at 1Hz.
- WORKAROUND that works at 1Hz = a STEPPED descent: freeze_player on + set_alt through bands (2500/1800/1200/700/
  350/150/70/30) with ~6s settle each, sample the steady cost per band. Maps cost-vs-altitude cleanly. Fall trigger
  for a real fall = nav detach + set_fly off (drops fast).

FINDINGS (stepped per-band median, 1Hz, relay-observer overhead ~13-23ms included so absolute ms inflated):
| alt | frame ms | phys ms | t_stream ms | offsurf | fps |
| 2500 | 128 | 17 | 14.1 | 100% | 25 |  (128 = teleport-in transient)
| 1800 | 37  | 19 | 15.8 | 100% | 23 |
| 1200 | 32  | 18 | 15.1 | 100% | 27 |
| 700  | 51  | **48.6** | **37.9** | 100% | 20 |   <-- ATMO regime transition
| 350  | 31  | 18 | 15.8 | 100% | 32 |
| 150  | 29  | 19 | 15.1 | 14%  | 34 |   <-- offsurf flips 100→0 between 150 and 70
| 70   | **83** | 19 | 15.7 | 0%   | 25 |   <-- surface-entry near-field burst
| 30   | 30  | 15 | 12.9 | 0%   | 35 |

ROOT: **t_stream_us (streaming) dominates the ENTIRE descent — steady ~14-16 ms/frame, spiking to 38 ms.** The
descending position never lets the streamer settle: it re-evaluates/loads every frame. `t_stream_us` is a combined
bucket — at high alt (offsurf) it is the FAR-RING/skin churn (the P7 subsystem), at low alt (surface) the near-field
chunk streamer. TWO hot bands: (1) alt~700 = the ATMO_TOP regime handoff, phys 18→48.6 ms + stream 15→38 ms as
near-field physics+streaming re-engage (class of prior #56 FP_ALT_REGIME / #70 phys_ms de-orbit); (2) alt~70 =
surface-entry, frame 83 ms full near-field streaming burst (prior #71).

REFUTED: t_scaledbody_us ≈ 0 the whole way ⇒ the pending "altitude-driven scaled-body reprocessing" hypothesis
(task #58) is NOT the fall cost. It's STREAMING.

NEXT (fix directions, not yet built): pace/bound the streaming re-evaluation during high-velocity descent (cf.
FP_ENV_FALL_HOLD / FP_FREEFALL_RAILS which already pause env-warm on fast fall — extend to the far-ring/near
streamer); and smooth the alt~700 regime handoff so the near-field re-engagement doesn't spike phys 48 ms in one
frame. Confirm with a 10Hz dynamic fall before committing. [[voxiverse-orbit-perf-farring-churn]]
[[voxiverse-motion-phys-root]] [[voxiverse-prebake-pacing-p7]]
