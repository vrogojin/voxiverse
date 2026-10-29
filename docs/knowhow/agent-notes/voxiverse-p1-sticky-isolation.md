---
name: voxiverse-p1-sticky-isolation
description: P1 sticky-alone does NOT hitch in the deployed async far-ring config — rebuild is off-thread; the combined-build hitch was P2-envelope/P3-shader
metadata: 
  node_type: memory
  type: project
---

2026-07-18, branch feat/voxiverse-p1-sticky (worktree .claude/worktrees/p1-sticky, commit 7f0248e).
Isolated FP_TIER_STICKY_BACKSTOP to ship alone (P2 FP_TIER_ENVELOPE / P3 FP_TIER_DEPTH_BIAS stay default-OFF).

MEASURED (godot/src/tools/probe_sticky_perf.gd, real T2e rebuild timer, native host):
- Sticky's ONLY runtime delta = larger backstop set in the far-ring rebuild (≤12 vs ≤5 facets).
- In the DEPLOYED config (FP_FARRING_ASYNC_REBUILD on) that build runs on the WORKER thread. The
  ONLY main-thread cost is the swap = add_surface_from_arrays: 173088 verts (sticky off) 5.29ms vs
  183168 verts (sticky on) 5.52ms → **+0.23ms/crossing** (6% bigger upload). The +~4ms build is off-thread.
- A single plain (non-envelope) dense-cache warm = 0.88ms native << the 3ms WARM_BUDGET (no per-facet spike).

**Verdict: sticky-ALONE does not meaningfully hitch in the async config — NO runtime fix needed.** This
FALSIFIES the orchestrator's hypothesis that "more sticky facets = bigger main-thread rebuild = hitch":
the rebuild is off-thread. The combined-build hitches the user rejected came from P2-envelope (4225-sample
fine-grid warm, ~15x the plain path, can blow the 3ms budget on one facet) and P3's ShaderMaterial swap
(the "did not look right"), both OFF in this build. See [[voxiverse-tier-depth-priority]].

Caveats: verdict assumes async is ON in deploy (it must be — sticky-OFF sync crossings already cost ~33ms
native / ~300-700ms web, the documented re-emit bomb). PRE-EXISTING (not sticky's fault): _bpos_cache never
evicts → grows unbounded with crossing count (5→26→44 over 8 crossings, sticky-off too); the +96kB ledger is
the INSTANTANEOUS 12-vs-5-facet delta, not a lifetime cap.

Gate: verify_tier_depth.gd now splits each phase by its flag → STICKY-only green 10/0, combined 23/0,
each phase SKIPs when its flag is off. FLAT verify_feature = 6035/0 (byte-identical; zero runtime edits).
