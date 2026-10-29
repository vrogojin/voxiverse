---
name: voxiverse-fall-mesh-stall
description: 2026-08-23 de-orbit atmosphere-entry ~2-3fps stall = near-field view-regrow GenerateBlock flood (vox_gen 6-7k WASM convoy); FP_REENTRY_BACKLOG_GATE fix SHELVED (non-functional — falling_fast stale at the ATMO-freeze crossing)
metadata: 
  node_type: memory
  type: project
---

2026-08-23. The de-orbit fall's real jerkiness = a **~2-3 fps stall for ~20s at alt ~870→450 (atmosphere entry)**.
Two fix attempts, BOTH shelved (unmerged). Live stays P7-baseline (both attempts' flags removed from deploy).

ROOT CAUSE (well-established, both by telemetry attribution + live A/B): as the ground-pinned approach-anchor viewer
re-grows its view_distance 0→128 across that band, godot_voxel loads a full terrain-intersecting disc per growth
step → **~6-7k GenerateBlock tasks flood the WASM worker pool** → main-thread starvation (the walk-perf convoy:
frame_ms tracks vox_gen 1:1; every tiny main-thread bucket uniformly inflates; frame recovers the instant
vox_gen→0). NOT the update_streaming GDScript tail (t_stream 17ms), NOT VoxelTerrain mesh/apply (vt_total <1ms),
NOT the whole-planet prebake (that's a SEPARATE confound — see below). Attribution done from the vt_*/vox_gen
telemetry fields on a warm continuous fall.

ATTEMPT 1 — stream-pace (voxiverse-fall-stream-pace, branch perf/fall-stream-pace, cc2ee78): NEUTRAL. Targeted the
update_streaming tail (t_stream 14-16ms) — the wrong cost (#143 mismeasured via FROZEN stepped bands). Safe, gated,
reviewed, but a live A/B showed identical stall on/off. Shelved.

ATTEMPT 2 — FP_REENTRY_BACKLOG_GATE + FP_REENTRY_REGROW_DEFER (branch perf/fall-mesh-stall, 2d391fb): SHELVED,
NON-FUNCTIONAL. Fable-designed (correct attribution this time), Sonnet-impl, Opus-reviewed (found + fixed a real
walk-wedge defect), FLAT 6042/0, gate verify_reentry_pace 15/0. Design: gate the WRITTEN view growth on the LIVE
VoxelEngine.get_stats().tasks.generation backlog (admit only < REENTRY_GEN_BACKLOG_MAX=256, step ≤ REENTRY_GROW_STEP=8)
+ hold the 64 landing disc while plunging fast above alt 460. LIVE A/B across 4 fix-ON runs: vox_gen bound to 1438
only ONCE (run1, 8.4fps); the other 3 (incl a clean WARM run, bg_inflight=0) FLOODED to 5727-7531 (≥ baseline
5874), 2-3fps. The reviewer's walk-wedge fix (gate on `falling_fast` = _fall_vy_ema < -ENV_FALL_HOLD_VY) is what
BROKE it: **_fall_vy_ema is FROZEN above ATMO_TOP (FP_ALT_REGIME), so at the exact atmosphere-entry crossing where
the view re-grows and floods, falling_fast is STALE/false → both the DEFER hold and the backlog gate bypass → full
flood fires before the EMA catches up.** run1's 1438 was a timing fluke. Tuning tighter (128/4) made it WORSE
(crawl 2.9fps, flood 6000 — starves the view).

MEASUREMENT LESSONS (hard-won this session): (1) to measure a de-orbit fall you MUST establish orbit first
(set_alt 2500 → freeze_player on → settle → freeze_player OFF to release) — a real ~38 b/s drag fall, 1Hz-resolvable
(~60 samples); set_alt unfrozen snaps to surface <1s. (2) vox_gen is a GLOBAL counter — a fresh-load whole-planet
prebake grind (P7, fm_baked climbing, bg_inflight>0) competes for the SAME workers and poisons the fall measurement;
WARM the session first (park frozen at orbit until fm_baked plateaus + bg_inflight→0, ~1-2min) for a clean read.
(3) run-to-run variance was huge until warmed — always warm + repeat. (4) consent lapses on link_lost → ops nack
"no_consent"; the relay link dropped repeatedly. (5) proc_ms is whole-frame on threaded web (unreliable) — use
frame_ms + vox_gen.

2026-08-31 RE-TEST (BACKLOG_GATE rev-2 SOLO, post-shell-fix): with the shell re-emit now fixed (prewarm+slice live)
the gen flood is the exposed top descent cost (measured set_alt-600 fall: worst frames vox_gen 2731-3953, st_bms ≤56
so NOT village). The rev-2 gate is ALREADY freeze-independent (arms on reentry_descent_step radial-Δ latch, not
_fall_vy_ema) and was enabled ALONE (no REGROW_DEFER). VERDICT: **INCONCLUSIVE — dominated by run-to-run variance.**
2 unwarmed set_alt-600 runs: vox_gen peak 4299 then 1405; descent worst_ms 508 then 818 — vs baseline 3953 / 1093,
all overlapping within noise. The BIGGEST flood (surface-entry alt 70-150) is STRUCTURALLY EXEMPT (REENTRY_DESCENT_MIN_ALT
=128 blocks the gate below 128 to avoid grounded-wedge). Not shipped. A real verdict needs the WARMED freeze-release
multi-run protocol (park frozen at orbit until fm_baked plateau + bg_inflight→0), interleaved arms — the same
hard-won hygiene below. Confirms the "noisy fall lever" trap. Live reverted to clean village-memo build.

CANDIDATE NEXT APPROACH (if ever revisited): gate the DEFER/backlog on a FREEZE-INDEPENDENT airborne-descent signal
(e.g. `offsurf and alt-decreasing`) instead of the ATMO-frozen _fall_vy_ema, so it engages AT the crossing (fixes
the flood-gate) AND releases when grounded (keeps the walk-wedge fix). OR stage the near-field view re-growth in the
engine (godot_voxel mesh/gen budget). OR the engine WASM convoy itself (mimalloc-class, rejected on heap — the deep
common cause of ALL these streaming stalls). [[voxiverse-fall-stream-pace]] [[voxiverse-fall-instrumentation]]
[[voxiverse-walk-perf-root-cause]] [[voxiverse-prebake-pacing-p7]]
