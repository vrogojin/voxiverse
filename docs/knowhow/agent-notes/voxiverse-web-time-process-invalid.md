---
name: voxiverse-web-time-process-invalid
description: Godot Performance.TIME_PROCESS is invalid on the threaded web export (~77-136ms at 60fps) — never use it as a frame-cost signal on web; measure real frame deltas instead
metadata: 
  node_type: memory
  type: project
---

On the VOXIVERSE threaded Web/HTML5 export, `Performance.TIME_PROCESS` (+TIME_PHYSICS_PROCESS) does NOT measure main-thread frame cost: the 2026-07-15 live border-walk telemetry (482 samples, tools/remote-bridge/results/telemetry.jsonl) showed it never below 18.4 ms and median 77 ms while demonstrably idle at 60 fps with vox_gen=0 — physically impossible as per-frame work (16.7 ms frame period). It evidently includes present/rAF-wait time under the emscripten threaded main loop.

**Why:** this broken sensor pinned the FP-M2 StreamLoadController credit at 0 from boot for an entire live session, rendering the whole M2 LOD investment inert (zero LOD facets, every crossing a spawn-at-cross hitch). Root-cause + fix design: docs/COSMOS-FP-M2-CONTROLLER-FIX.md (commit 67cbb4b on fix/voxiverse-crossing-hitches).

**STATUS 2026-07-15: fix IMPLEMENTED + gate-validated + COMMITTED (05bcabf on fix/voxiverse-crossing-hitches).** Three prongs shipped across 6 files (stream_load_controller / world_manager / module_world / facet_lod_mesher / cube_sphere / verify_fp_m2): P1 LiveSource.poll() = measured inter-poll wall delta clamped at CTRL_FRAME_SAMPLE_CLAMP_MS=250; P2 overload statistic = window p90 (CTRL_WINDOW_PCTL=0.9, ≡max under constant signal so gate traces bit-identical); P3 relief floor CTRL_RELIEF_FLOOR=0.25 floors surfaces 1-2 + imminent ramp, relief_only() restricts budgeter to meshless+imminent facets, imminent live promote gets geometric commit inside POOL_D_COMMIT=64 via promote_admit_imminent(ctrl, ridge_dist), set_imminent_fid plumbed WM→module→mesher, demote spares imminent. New regression gate G-M2-STARVE(a–f). Gates: FP-M2 (FACETED+FP_M1_POOL+FP_M2_LOD on) = 127/0; FLAT byte-identity (flags off) = 6027/0. Native editor rebuilt to docker/engine/bin/ after the crash wiped it (SKIP_WEB=1 build). Remaining: docs §6.5.3 surface-table update + commit.

**How to apply:** any load/perf signal on web must use measured inter-frame wall deltas (as the PerfHUD's min_fps/worst does), never TIME_PROCESS. Also: a max-over-window statistic vs a sub-vsync setpoint is unrecoverable in a browser (isolated dropped frames every few hundred ms are browser-normal) — use a percentile (p90). Related: [[voxiverse-faceted-planet]], [[voxiverse-gpu-headless-testing]], [[voxiverse-remote-bridge]].
