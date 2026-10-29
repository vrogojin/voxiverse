---
name: voxiverse-forest-fps-limiter
description: 2026-08-14
metadata: 
  node_type: memory
  type: project
---

2026-08-14 task #129 (rest-median deep dive after FP_SHELL_SURF_CAP null result). Doc
`docs/COSMOS-FOREST-FPS-LIMITER-DESIGN.md` (worktree deploy-cheats). ROOT FINDINGS
from 1,544 live windows (all-rest, warm forest) + served-pck dump:

1. **Rest "25ms worst-frame" = a quasi-periodic ~5Hz ≥33ms stall present in 99.5% of
   0.25s windows (worst_ms p50 37.4, hitches 5.04/s) with EVERY instrumented subsystem
   ≈0** (vt/vox/main_commit/snow/env/tex/smooth all zero; sh_reemit + sh_pending_src
   FROZEN — CALM holds at rest; DELTA skips). Under-dispersed counts ⇒ clocked, not
   stochastic. Prime suspect = **the telemetry observer itself**: 4Hz `_send_telemetry`
   (remote_bridge.gd:544; sync JavaScriptBridge.eval :536; stringify+send :715) + 0.5Hz
   viewport get_image() capture (":895 — the ~35 ms readback lands this frame"). The
   #119 cap=0 exoneration covered ONLY the capture, never the snapshot — **the observer
   had no timer on itself**. Not fully provable from current fields → P0 patch
   FP_TELEM_FRAME_DECOMP (fh histogram, telem_ms/eval_ms/cap_ms, sub_ms via
   frame_pre/post_draw, phys_worst_ms, ft_ms/ring_ms/wm_proc_ms, `unattr` verdict
   field) + `?telem=1hz` knob = one-deploy discriminator.
2. **Controller floor-trap (proven live):** LiveSource samples frame PERIODS
   (stream_load_controller.gd:277); rAF catch-up after each slow frame mints ~12ms
   period samples ⇒ floor_p10=12.2 < vsync ⇒ adaptive setpoint clamp(12.2×2.0)=24.4
   sits just under the p90 25.5 the spikes produce ⇒ credit pinned 0/osc 0-0.3 at rest
   with vox_gen=0. More hitches ⇒ LOWER floor ⇒ setpoint chases its own attacker
   (measurement-in-the-loop, obs-2 class). Fix **F1 FP_CTRL_FLOOR_VSYNC**:
   CTRL_FLOOR_MIN_MS=16.0 clamp in _floor_p_low ⇒ setpoint 32; genuine 30fps overload
   still trips. Gate G-CTRL-VSYNC (37/12ms alternating source).
3. **INTERLOCK — never ship F1 alone:** un-pinned credit re-admits far-tree full
   rebuilds in MOTION (FT_DELTA_MIN_MOVE=2.0, walk 5.5 b/s ⇒ ~2Hz, run 9.5 ⇒ 4Hz ×
   ~50-60ms = 10-23% duty — the #119 attacker returns). **F2a** = FT_DELTA_MIN_MOVE
   2.0→12.0 (6× duty cut, ≤12blk handoff hysteresis at ≥128blk, NEARCULL guard
   unaffected); **F2b** = FP_FT_REBUILD_ASYNC on JobLane (buffers off-main, set_buffer
   commit only).
4. **Honest verdict:** rest ≈ vsync between spikes (fps p90=60.0); the played problem
   is MOTION (streaming starved at credit 0 → burst duty + far-tree PWM). Ship order:
   P0 decomp → P1 F1+F2a together (export A/B, Run C walk protocol: fps p50 ≥45) →
   P2 F2b + IDLE_DIET (ABSENT from served build per pck dump — not shipped yet).
**SHIPPED+MERGED 2026-08-15 (unattended): P0 FP_TELEM_FRAME_DECOMP (PR #66 main 6ad82bf) + F1 FP_CTRL_FLOOR_VSYNC
+ F2a FP_FT_MOVE_HYST (PR #67 main 842fb62), all byte-off + deployed live.** LIVE VERDICTS:
- **Observer CONFIRMED**: telem_ms median 13.6ms / max 28.6ms every 4Hz snapshot (eval_ms only 0.16 → it's the JSON
  build + world.call() gathering, NOT the JS bridge). Self-inflicted 4Hz main-thread stall, observed-session-only
  (played game never runs the bridge) → real players at rest are fine; the rest "fps problem" was a measurement artifact.
- **F1 gate-proven** (verify_ctrl_floor.gd G-CTRL-VSYNC 3/0 off, 4/0 on): the rAF-trap pattern [16,16,29,12] pins credit
  OFF (setpoint 24 < p90 29) and un-pins ON (floor clamp 16 → setpoint 32); a genuine 50ms spike overloads BOTH.
- **F2a gate-proven** verify_far_trees 120/0 (full live set + hyst on); G-FT-MOVEHYST + G-FTD-2 effective-threshold.
- **MOTION A/B — the p50≥45 target was NOT met, and the reason RE-DIRECTS the motion root cause**: walking fps median
  17.6, credit STAYS 0 while moving — but that is CORRECT: motion is a GENUINE overload (worst_ms 71ms ≫ setpoint 32),
  not the floor-trap, so F1 rightly does not un-pin it. DECOMP OF THE 71ms MOTION FRAME: **phys_ms median 24.6ms / max
  44.5 (vs 5.6 at REST) = the DOMINANT motion chunk** (prime suspect the GroundCollider rebuild/re-centre around the
  moving player, CLAUDE.md's "blocky shapes kept centred on the player"); vt_total/vt_load_resp ≈0 (godot_voxel mesh-
  apply NOT the cost, ruled out); + observer 8ms + render (draws 142, prims 465k). So the MOTION limiter = PHYSICS, not
  streaming, not the far-tree rebuild, not the controller. Dispatched fable-motion-phys to root-cause the GroundCollider
  cost. F2b (async far-tree rebuild) + IDLE_DIET still not shipped (lower priority — not the motion lever). RELOAD OP
  (control-channel location.reload) WORKS for autonomous A/B after a deploy (cold-boot reconnect ~90s).
**MOTION FIX SHIPPED+MERGED 2026-08-15 (PR #68 main ec4028f): FP_STREAM_TICK_ONCE — the real motion win.** motion-phys
Fable (docs/COSMOS-MOTION-PHYS-DESIGN.md) CORRECTED the premise TWICE: (a) phys_ms is the 1Hz MAX of per-STEP wall time
(main.cpp:4517/4588), NOT per-frame, NOT additive; (b) GroundCollider EXONERATED (debris-gated, idle while walking).
REAL cause: WorldManager.update_streaming's ~200-line render-facing ORCHESTRATION TAIL (_update_alt_regime down) runs
INSIDE the physics bracket EVERY tick, and a slow frame runs 2 physics steps (project.godot max_physics_steps_per_frame=2)
→ the tail runs TWICE on already-slow frames + corrupts _bg/_g2 headroom governors with a ~0ms 2nd-step inter-call delta.
Fix = run the tail once per RENDER frame (guard on Engine.get_process_frames(), which increments AFTER the physics loop);
safety HEAD (streamer/GroundCollider/pos-latch/floor funnels) stays per-tick → ZERO fall-through (tail writes no collision
state). 6-line diff world_manager.gd (after the _have_player_pos latch, before _update_alt_regime). Gate verify_stream_tick
G-MTP-ONCE/FLOOR 3/0 both. **LIVE A/B BIG WIN: walking fps ~18→30.8, phys_ms 24.6→14.9 (−40%), worst_ms 71→45.5 (−36%),
no fall-through.** DECOMP via FP_FALL_TIMING (shipped instrument, export-flipped, adds t_move/t_stream/t_floor_us window-max
to telemetry): t_stream 4.2ms (tail, deduped) vs **t_move_us 8.8ms/max20.5 = the movement funnel (6 blocked() probes,
player.gd:1773) is now the #1 residual = P2b** (per-tick blocked() column cache — collision-adjacent, needs careful design,
Fable §4.5 flagged _occ_span footprint-dependence). P2a (deferred-flush drain) + IDLE_DIET still unshipped.
**P2b SHIPPED+MERGED 2026-08-15 (unattended, PR #69 main 908cbae): FP_MOVE_PROBE_CACHE — the walking t_move fix.**
P0 first: added t_probe_us (brackets the 6 blocked() probes, player.gd:1773) → LIVE probe p50 5.72ms = 80% of t_move
(≥5ms ship threshold MET). Fix = generated-value cell cache in WorldManager.cell_value_at consulted AFTER the live
edit-overlay get (design choice B: an edited cell can NEVER be served from cache → clip-through impossible by
construction; zero write-site invalidation). Vector3i→packed; per-physics-tick transient epoch (Engine.get_physics_frames
self-clear, no call-site wiring); MAIN-THREAD ONLY (mesher+snow call cell_value_at off-main → bypass, no locks);
wholesale clear at the 2 remap chokes FP_FLOOR_MEMO patrols (_rebuild_window_indices/_shift_window_bookkeeping); NEVER-OOM
double bound (per-tick clear + MOVE_PROBE_CACHE_CAP 512). Generated branch extracted to _cell_value_generated. Gate
verify_move_probe_cache G-MPC-ID/OFF/OVERLAY/EPOCH/CAP 14/0 BOTH flag states (incl clip-through w/ warm cache); FLAT
verify_feature 6042/0 BOTH states (break/place/collapse byte-identical w/ cache live). LIVE A/B (walk-square n=29):
t_move 6900→2881µs (−58%), t_probe 5720→2181 (−62%), phys_ms 11.64→10.86, worst_ms 46.2→37.7, fps 35.5→39.0 (+10%),
hit-rate 0.53, gen_cache_sz max 16 (≪512), **offsurf 0.00 = ZERO fall-through**. NB the FIRST A/B sample (n=11, run gait,
right after reload) showed a FALSE phys/fps regression = reload-outlier + location confound (different forest density →
t_stream 3.7→5.8ms); the clean walk-square re-measure exonerated it. Residual after P2b: t_stream (~4-5ms, location-
dependent) + render now dominate the motion frame — P2a deferred-flush drain + IDLE_DIET still unshipped (diminishing).
LESSON: t_move/t_probe brackets isolate the movement funnel LOCATION-INDEPENDENTLY; phys_ms/fps aggregates are confounded
by where the player walked — trust the intrinsic brackets, re-measure aggregates warm + same-ish terrain.
LESSONS: any periodic measurement emitter must emit its own previous-cycle duration;
never feed a floor estimator raw frame periods on a vsynced browser; window-MAX fields
can't split clocked vs stochastic — per-window COUNT dispersion can, free. And: decompose MOTION separately from REST —
they had entirely different limiters (rest=observer+floor-trap artifact; motion=genuine physics overload).
Related: [[voxiverse-forest-fps-root]] [[voxiverse-stream-idle-diet]]
[[voxiverse-web-time-process-invalid]] [[voxiverse-seam-mask-fallthru-law]]
