---
name: voxiverse-motion-phys-root
description: 2026-08-15 motion phys_ms 5.6→24.6 ROOT — TIME_PHYSICS_PROCESS is a 1Hz MAX-of-single-step monitor (not per-frame sum); GroundCollider exonerated (debris-gated); real cost = update_streaming tail per physics TICK ×2 catch-up steps + governor 0ms-delta corruption; fix FP_STREAM_TICK_ONCE + flip FP_FALL_TIMING
metadata: 
  node_type: memory
  type: project
---

Motion-fps physics investigation (2026-08-15, forest facet ~1754, walking phys_ms med 24.6/max 44.5 vs rest 5.6). Design doc: `docs/COSMOS-MOTION-PHYS-DESIGN.md`.

- **phys_ms semantics**: `Performance.TIME_PHYSICS_PROCESS` (remote_bridge.gd:683) publishes ONCE PER SECOND the MAX duration of a SINGLE physics step in that second (custom-build main.cpp:4517 + :4588). NOT additive with observer/render terms; "frame = phys + telem + render" decompositions using it are invalid. Correct read: ≥1 tick/second costs ~24.6ms while walking.
- **GroundCollider exonerated**: fully gated on nearby awake VoxelBody debris (ground_collider.gd:195-201); zero work walking with nothing broken; when active it's drift-debounced (8 col) + op-budgeted (24 PhysicsServer ops/slice). Never a motion cost.
- **Real structure**: `Player._physics_process` runs `world.update_streaming` EVERY physics tick (player.gd:822); `max_physics_steps_per_frame=2` (project.godot:46) ⇒ the whole streaming tail (world_manager.gd:1185-1390 — tex baker 5ms budget/CALL, DEM step, pool, plumbing) runs 2× on exactly the slow frames. The 2nd catch-up step also feeds ~0ms inter-call deltas to the `_bg_frame_ms`/`_g2_frame_ms` headroom governors ⇒ bakers admit work during overloaded frames. Physics bracket also contains 2× MessageQueue flush/step ⇒ worker call_deferred commits bill to phys_ms.
- **Forest floor memo exclusion**: FP_FLOOR_MEMO can't cache columns with tree cells above the floor (memo_safe, world_manager.gd:4386-4387) ⇒ walking under canopy re-scans; rest is O(1) memo-hit and never calls blocked() (wish=0).
- **Fix**: P0 export-flip `FP_FALL_TIMING` (already-built t_move/t_stream decomposition, false in served pck). P1 `FP_STREAM_TICK_ONCE` — tail once per render frame via Engine.get_process_frames() guard (both catch-up steps share one value; _process_frames increments after the physics loop); safety head (GroundCollider update, streamer, pos latch) stays per-tick ⇒ zero fall-through risk. Expected walking phys_ms 24.6 → ~14-17.

**Why:** prevents re-suspecting the collider and repeating the additive-decomposition mistake. **How to apply:** any monitor-based decomposition must first check the monitor's aggregation window in engine source; any per-physics-tick call site with a budget or frame-delta governor is a catch-up amplification bug. Related: [[voxiverse-web-time-process-invalid]], [[voxiverse-forest-fps-limiter]], [[voxiverse-stream-idle-diet]].
