---
name: voxiverse-fall-stream-pace
description: 2026-08-23 FP_STREAM_FALL_PACE + FP_REENTRY_VIEW_RAMP — de-orbit fall stream-pacing fix DEPLOYED + verified offline; live A/B blocked by fall <1s + ?telem=10hz not loading
metadata: 
  node_type: memory
  type: project
---

2026-08-23 (branch perf/fall-stream-pace off main 1c76461, after P7). Fixes the de-orbit fall jerkiness that
task #143 instrumented (t_stream_us 14-16ms/frame the whole descent, alt~700 phys 48.6ms, alt~70 frame 83ms).

MULTI-AGENT BUILD: Fable design agent → docs/COSMOS-FALL-STREAM-PACING-DESIGN.md (root-caused t_stream_us to
player.gd:922's update_streaming timer wrapping THREE render-side tail drivers with no motion signal — skin
re-rank + facet-tex SSE re-tier + G2 DEM; and the alt~700 spike to ANCHOR_REL_LO=700 approach-anchor view
re-growth jumping view_distance 13-40 blk/write, NOT ATMO_TOP). Sonnet impl agent → commit cc2ee78. Opus
adversarial reviewer → no defects. (LESSON: two agents shared one worktree — the design agent left UNCOMMITTED
partial impl then idled without reporting; the fresh impl agent found + reconciled it. Idle agents can silently
half-do work — always verify the committed diff yourself, don't trust an idle_notification as "done".)

THE FIX (2 byte-off flags, cube_sphere.gd + world_manager.gd):
- FP_STREAM_FALL_PACE: a NEW radial-altitude-rate EMA (_stream_pace_update_rate; the existing _fall_vy_ema is
  useless — VEL_PREDICT_SPEED_CLAMP=40 rejects orbital plunge speeds). While rate < -STREAM_FALL_PACE_VY(15 b/s),
  round-robin the 3 tail drivers (phase=counter%3) so ≤1 pays per frame → tail 14-16ms → ~5-6ms; each still 20Hz.
  Rate calm (walk/settled-orbit/touchdown) ⇒ phase −1 ⇒ every driver runs ⇒ byte-identical.
- FP_REENTRY_VIEW_RAMP: CubeSphere.anchor_grow_clamp bounds view GROWTH to ANCHOR_GROW_STEP=8 blk/write on fast
  descent (shrink never clamped; teleport paths pass bypass_ramp=true). Stages the alt~700 annulus over ~1.6s.
- Sub-attribution telemetry skin_ms/tex_ms/relief_ms (mirrors snow_ms).
FALL-THROUGH SAFE: physics analytic; paced blocks render-only, write no collision state; the critical steps
(_update_alt_regime 416 re-entry, _update_approach_anchor, pool, load-defer, flip-settle) run EVERY frame unpaced.

VERIFIED: FLAT 6042/0 (byte-off, independently re-run); gate verify_stream_fall_pace.gd G-SFP-PACE/CALM/EST/
FLOOR + G-AVR-CLAMP = 8/0 (off arm) + 12/0 (on arm); Opus adversarial review no defects. DEPLOYED live 16:41 GMT
(flags in deploy_cheats CS_FLAGS; GDScript-only, no engine rebuild). Branch perf/fall-stream-pace, NOT yet PR'd.

LIVE A/B BLOCKED (measurement harness, not the fix):
- The de-orbit fall from alt 2500 completes in <1 TELEMETRY SAMPLE (set_alt 2500 unfrozen → gravity yanks to
  surface in <1s; nav detach / set_fly off both snap). Unresolvable at 1Hz.
- ?telem=10hz (FP_TELEM_10HZ, in the build; remote_bridge.gd:400-402 interval→0.1 is correct) requires
  &telem=10hz in window.location.search AT PAGE BOOT. Failed 3× — the param isn't in the address bar at load
  (bookmark/tab without it, or re-arm ≠ fresh-load). Server JS reads location.search correctly (not a code bug).
- CONFIRMED the root-cause driver live regardless: tex_ms 11-18ms (skin/relief ~0) = the facet-tex baker IS the
  dominant t_stream driver the round-robin targets. Frozen set_alt bands = pacing DORMANT (rate 0) = the
  no-regression control (can't show the fix working — pacing needs continuous descent).
LIVE A/B VERDICT 2026-08-23 (fix-ON vs fix-OFF, identical continuous fall, orbit-established→unfreeze→full descent
to touchdown): **SHELVED — the fix is NEUTRAL (safe, no regression) but does NOT fix the fall.** The real de-orbit
jerkiness is a PRE-EXISTING ~3 fps stall at ATMOSPHERE ENTRY (alt 200-800) that is IDENTICAL with the flags off:
frame_ms median 354 (off) vs 343-385 (on), fps 3.2 (off) vs 2-3 (on). Dominated by NEAR-FIELD MESHING —
proc_ms ~300-650 ms while t_stream_us (the tail the fix paces) is only ~17 ms. godot_voxel meshes a huge burst
as the player plunges through alt 800→300; that work runs in its OWN node process, NOT the update_streaming tail.

ROOT LESSON: instrumentation #143 (voxiverse-fall-instrumentation) MISMEASURED — it used FROZEN stepped set_alt
bands, which have the near-field already settled, so t_stream (14-16 ms) looked dominant and the continuous-fall
mesh burst never appeared. The ENTIRE streaming-pacing design was aimed at the wrong cost. KEY METHODOLOGY FIX:
to measure a de-orbit fall you MUST establish orbit first (set_alt 2500 → freeze_player on → settle → freeze_player
OFF to release), then it descends as a real ~38 b/s drag-limited physics fall RESOLVABLE AT 1Hz (~60 samples).
set_alt unfrozen just snaps back to surface in <1s. (Also: consent lapses on link_lost → ops nack "no_consent";
?telem=10hz needs &telem=10hz in the URL at PAGE BOOT — a plain reload/re-arm keeps 1Hz.)

STATUS: branch perf/fall-stream-pace (commit cc2ee78 + doc 6fc1413) NOT merged, NOT deployed (live reverted to
fix-OFF = main/P7-equivalent). The fix is verified-safe (FLAT 6042/0, gate 12/0, Opus review clean, lands cleanly)
so it COULD be a minor tail optimization on the high-alt descent (fps 30-56 there), but it's not worth shipping
alone. REAL NEXT FIX must target the near-field MESH stall at atmosphere entry (alt 200-800): stage the FP_ALT_REGIME
416 near-field re-engagement over frames, and/or cap godot_voxel's per-frame near mesh budget during a fast plunge,
and/or slow the descent through that band. [[voxiverse-fall-instrumentation]] [[voxiverse-prebake-pacing-p7]]
