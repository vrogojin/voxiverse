---
name: voxiverse-stream-idle-diet
description: 2026-08-13
metadata: 
  node_type: memory
  type: project
---

Designs (worktree deploy-cheats, branch deploy/perf-plus-sky): docs/COSMOS-STREAM-IDLE-DIET-DESIGN.md + docs/COSMOS-APPLIED-PROBE-CALM-DESIGN.md (§R2 is authoritative).

**FP_STREAM_IDLE_DIET (#119 P0b, floor fix, design stands):** update_streaming tail ≈2-4.5ms/tick stationary (dominant: baker SSE 3456-facet scans/tick, FP_SMOOTH_IDLE const false); one guarded early-return after `_update_approach_anchor` (world_manager.gd:1210) → 5Hz heartbeat, work-sensed arm, same-tick wake edges. Re-baseline AFTER CALM (floor contaminated by spikes).

**#123 spike attribution — TWICE mis-pinned, now 2 live candidates:**
1st mis-pin: cull APPLY (FP_FARRING_CULL_COVERED) — analysis right, **flag NOT DEPLOYED** (served FARRING set: ACTIVE_NOBLACK, APPLIED_COVER, ASYNC_REBUILD, FAST_REBUILD, FULL_COVER, UNCOVERED_TRUE + PROBE_SLAB/VIEW_BAND). c02eb30 impl HELD. **LESSON (bit twice): filter every root-cause through the SERVED flag set, never tree constants; and per-window telemetry samples ALIAS sub-window excursions** — team-lead's "sh_applied_r steady 96" did NOT refute the ladder (a 96→0→96 excursion completes in ~0.1-0.2s inside one 0.25s window).
Live candidates (both driven by the credit-0 near remesh trickle): **A** noblack unsink flips (facet_far_ring.gd:1584-92, per-frame 20×192×20 is_area_meshed under camera); **B** applied-ladder shrink-regrow excursions (:1728-34, r=96 box ~192 blk wide). R4.2 "endless train" ruled out unless FP_FAR_SMOOTH served (_front_visible :2283 forces active into emit set under NOBLACK+FULL_COVER; train needs _smooth_covered exclusion :2880/:2912; its fix = serve FP_RING_QUIESCE). Verts-monotone-down is PASSIVE (FP_SMOOTH_V2_EXCL_BLKLOD assembler skip :2940 absorbed per rebuild).
Discriminators: inter-event gap histogram on existing jsonl (regular 2-3s = train; clusters = A/B); next deploy add `sh_pending_src` per-site arm counters (13 sites).

**Fix R2.5 BUILD-READY (green-lit; served flags: FP_FAR_SMOOTH off ⇒ train ruled out, SMOOTH_V2+BLOCKY_FARRING on, RELIEF_REEMIT/SLOT_INDIRECT/RING_QUIESCE/V2_EXCL off):** sink-side classified pending — ALL 18 arm sites tabled (doc R2.5.2), `_arm_pending(src, luxury)` choke helper + `sh_pending_src` per-site counters (the anti-mis-pin sensor, same flag). **CRITICAL partition correction caught pre-build: ladder GROW = SAFETY-at-fixpoint NOT luxury** (grow removes the #113/#117 grey; luxury-coalescing it = grey regression at spawn/crossings, and at credit=0 it would never promote). Net-zero TIME debounce (CALM_NETZERO_HOLD_MS=250, hold arm+state, cancel if probe reverts) replaced 2-read confirm (misses multi-frame web remeshes) on NB_UNCOVER/NB_RESINK/LADDER_SHRINK. Luxury rail (credit+2s+10s) idles on the deployed set — live win = debounce + per-climb single-arm; c02eb30 folds into the rail. Gates G-APC-1..8. Ship order: CALM > DELTA > IDLE_DIET (CALM releases the pinned credit; DELTA gated at credit=0 via facet_far_trees.gd:481).

Related: [[voxiverse-forest-fps-root]] [[voxiverse-grassbase-backstop]] [[voxiverse-mesa-viewband]] [[voxiverse-fast-load]] [[voxiverse-seam-mask-fallthru-law]]
