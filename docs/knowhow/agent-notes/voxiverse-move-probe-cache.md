---
name: voxiverse-move-probe-cache
description: 2026-08-15
metadata: 
  node_type: memory
  type: project
---

2026-08-15, task #129 motion residual after [[voxiverse-stream-idle-diet]]'s FP_STREAM_TICK_ONCE (phys 24.6→14.9ms). Design-only, doc: docs/COSMOS-MOTION-PHYS-DESIGN.md §6 (Lessons renumbered §7).

**Root cause of t_move 8.8ms walking:** the 6 `blocked()` wall probes (player.gd:1775-1783) each run floor_under (2 cell_value_at/iter, world_manager.gd:4348-4352) + _headroom_clear (2-3 cells) — and `cell_value_at` (wm:1475) is UN-memoized: full generated_cell→resolve_cell + TreeGen.block_at per forest cell. FP_FLOOR_MEMO is doubly dead under canopy walking (populate only on fall-path ceil-jump wm:4377; tree cells flip memo_safe false wm:4404). PLAYER_RADIUS 0.4 ⇒ the ± corner probes usually floor to the SAME column ⇒ ~36-48 queries/tick → ~8-16 unique cells (60-75% redundant).

**Design FP_MOVE_PROBE_CACHE (byte-off):** cache the GENERATED value only, inside cell_value_at's generated branch — the `_edits` overlay get (wm:1476-1478) stays live on EVERY query, and both dig (e=0) and place live in the overlay, so an edited cell can never be served from cache BY CONSTRUCTION ⇒ zero edit-invalidation surface (clip-through structurally impossible). Per-tick transient epoch via Engine.get_physics_frames() stamp self-clear; main-thread-only (mirror TerrainConfig._on_main_thread, tc:1926 — mesher/snow threads bypass); wholesale clears at FP_FLOOR_MEMO's two remap chokes (_rebuild_window_indices wm:3781, _shift_window_bookkeeping wm:3874 — covers facet flip/datum/origin); cap 512 stop-insert (never-OOM). REJECTED: caching blocked() booleans by quantized key (§4.5 sketch) — own_dist + _occ_span(fx,fz) are continuous ⇒ quantized cache can lie on slopes/seams; and full-result caching (needs _write_cell invalidation = safety-critical for one dict-get saved).

**Ship gate:** P0 first — add t_probe_us (bracket player.gd:1773-1784) + n_probe_cva/hit counters to FP_FALL_TIMING; if probe median < ~3ms the cost is move_and_collide and the cache must NOT ship. G-MPC-ID pins byte-identity incl. same-epoch _write_cell → immediate blocked()=true.

**LESSON:** when a cache would be collision-safety-critical, restructure so the mutable layer (edit overlay) is checked BEFORE the cache instead of invalidating the cache on mutation — provable in one paragraph vs an invalidation audit. Same class as [[voxiverse-fartree-shift-residual]]'s delta-gate lesson: encode the consumer's mutable state outside the memo.
