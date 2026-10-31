---
name: voxiverse-orbit-perf-farring-churn
description: 2026-08-21 orbit/fall jerkiness ROOT = FacetFarRing SRC_UNSINK rebuild churn (not scaled-body); P0 fix + P2/P3/P5 plan
metadata:
  type: project
---

2026-08-21: user reported the game FREEZES ~once/sec at orbit + jerky while falling/flying. Goal = ABSOLUTELY SMOOTH
(low FPS OK, jerkiness/latency NOT). Deep Fable research (analysed live telemetry tools/remote-bridge/results/telemetry.jsonl).

ROOT CAUSE (proven, NOT the scaled body): FacetFarRing._unsink_drift_check (facet_far_ring.gd:1755) re-arms _arm_pending(
SRC_UNSINK) on every UNSINK_DRIFT_BLOCKS(16) of column drift — at orbital coast ~244 blk/s that is EVERY frame → _pending
stays armed → the FP_SHELL_ORBIT_IDLE short-circuit (:1495) never engages → each frame dispatches a full-cap rebuild
(~790 facets, ~176k verts) on a WorkerThreadPool task (_dispatch_async_rebuild:2093 → _async_build_worker:2261 → _emit_
blocky:4182 ~700k SurfaceTool VM calls + alloc storm) then _swap_in_arrays:2335 on MAIN = 20-43ms swap, and immediately
re-dispatches. Back-to-back churn. PROOF: 33/34 rebuilds in 26s armed by SRC_UNSINK (sh_pending_src slot 10 +33); 24
consecutive builds byte-IDENTICAL output (verts=176100) = pure redundant work; at orbit _shell_orbit() empties the backstop
set + sh_applied_r=0 so the un-sink pattern doesn't even affect the emit. The once/sec "freeze" = the build+swap beat.
Task #58 (scaled-body engine reprocessing ∝ alt) REFUTED — cosmos_scale.gd is a 112-line math helper, t_scaledbody_us≈20µs;
the voxel engine is QUIESCENT at orbit (pool_active=0, vox_*=0).

TELEMETRY GOTCHAS (corrected misreads): frame_v == v_bci (nav VELOCITY, NOT frame time — don't misread it as ms);
pool_active reads the godot_voxel ENGINE pool (idle at orbit) NOT the WorkerThreadPool (where the far-ring build + 4 C++
bakers run at 100%); proc_ms = whole-frame on threaded web; phys_ms = 1Hz max-single-step monitor. The 120-line JSONL had
34 interleaved type:"farring" events = the key evidence. ALWAYS audit the SERVED pck (deploy flips FP_* the source shows
false — dump via load_resource_pack + get_script_constant_map on build/web/index.pck).

P0 SHIPPED (commit 6770185, FP_UNSINK_DRIFT_CALM, GDScript-only no rebuild, FLAT 6042/0, deployed 15:31): gate the arm —
`if _shell_orbit() or (_applied_r<=0 and not _emit_floored_last): return` + wall-clock-throttle the fall regime to
SHELL_FALL_REEMIT_MS(1000). Far-render UNCHANGED (only redundant re-emits dropped). LIVE MEASURED at orbit: fps ~10→~53,
proc_ms 335→~60, MAX FRAME 421-1106ms → ~100ms (the once/sec freeze GONE), hitches ~5/s→~1.6-3.5/s. (Measured stationary
at orbit — relay can't reproduce true coasting; fix gates on the regime so coasting is covered by construction.)

RESIDUAL hitches (~1.6-3.5/s) → P2/P3/P5 dispatched 2026-08-21 as parallel Fable agents:
- P5 (agent a82e506b, remote_bridge.gd): telemetry observer costs telem_ms 8-21ms/emit at 4Hz on MAIN → cheaper build /
  lower cadence / offload stringify; flag FP_TELEM_LITE; add a true frame_ms (frame_v is velocity). Separate file.
- P3+P2 (agent af8cc641, facet_far_ring.gd, 2 commits): P3 FP_FARRING_BULK_EMIT = replace _emit_blocky per-vertex
  SurfaceTool (~700k VM calls + alloc storm → dlmalloc convoy) with preallocated Packed*Array bulk fills + analytic
  normals (byte-EQUAL gate). P2 FP_FARRING_SECTORS = split the 176k-vert cap ArrayMesh into ~8-16 angular-sector
  MeshInstances, swap only DIRTY sectors → bound the residual swap 20-43ms→~3-5ms (seam-weld at sector borders).
DEFERRED: P4 (interactive-aware bg-bake governor: 4 C++ fine bakers at 100% duty), P6 (mimalloc engine rebuild — the
[[voxiverse-walk-perf-root-cause]] dlmalloc convoy; likely moot after P0-P3). Walking untested by user (should be calm —
16-blk drift takes seconds on foot). Key files: facet_far_ring.gd (_unsink_drift_check:1755, _emit_blocky:4182,
_swap_in_arrays:2335, _dispatch_async_rebuild:2093), cube_sphere.gd (UNSINK_DRIFT_BLOCKS:2028), remote_bridge.gd (telem :660-726).

P5/P3/P2 SHIPPED 2026-08-21 (deployed 16:41, all GDScript-only no rebuild, FLAT 6042/0, on feat/voxiverse-struct-gen —
NOT yet PR'd to main, holding for the smoothness A/B): P5 FP_TELEM_LITE (commit 7c6ea55) telemetry 4Hz→1Hz + heap-eval JS
round-trip cached 4× + has_method memoized + added true frame_ms field. P3 FP_FARRING_BULK_EMIT (808967a) _emit_blocky
per-vertex SurfaceTool → preallocated Packed*Array bulk fills via SurfaceTool.create_from_arrays (pure-CPU, worker-safe,
BIT-EXACT normals — NOT analytic which would've mismatched generate_normals' cross-seam smoothing; gate G-FR-BULK 9/0,
~2× faster). P2 FP_FARRING_SECTORS (a9dcdb6) split the 176k-vert cap into 24 STATIC face-quadrant sectors (6 faces×2×2,
NOT player-azimuth which would dirty-storm), swap only DIRTY sectors via a per-facet emit-signature + sunk-state
fingerprint; gate G-FR-SECT 23/0 (multiset-identity partition/weld/dirty-tracking). SECTORS is the one to EYEBALL live
(agent flagged: dirty-model residual = a future new emit input not added to _sector_fid_sig could leave a STALE sector
wedge; per-sector normals but dead in served config since FP_SHELL_ABSOLUTE shades radially, never reads NORMAL).
Merge-mechanics: P5 ff onto 6770185; P3+P2 (base 6770185) --no-ff merged (cube_sphere flag blocks auto-merged, no conflict).
LIVE A/B pending user reload+re-arm+fly-to-orbit: measure combined hitch reduction over the P0-only baseline (P0 already:
fps 10→53, max frame 421→100ms) + verify far terrain has no stale sector wedges during motion.
