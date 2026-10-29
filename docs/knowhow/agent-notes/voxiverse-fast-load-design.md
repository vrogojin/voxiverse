---
name: voxiverse-fast-load-design
description: "2026-08-11 fresh-load pile-up root-caused — smooth_v2 whole-annulus commit (185ms, O(N²) fill) + env-converge + snow on main; setpoint_ms is NOT a cost; fix = FP_LOAD_DEFER settle gate; doc COSMOS-FAST-LOAD-DESIGN.md"
metadata: 
  node_type: memory
  type: project
---

2026-08-11 (task #103, follows [[voxiverse-bg-prebake-design]]'s FP_DEM_DEFER which was NOT the residual cause — g2_baked=0 through load). Fresh-load main-thread pile-up root-caused on an 8-core client (proc_ms 156-804, workers idle, stream_credit=0):

- **smooth_v2_commit_ms 185.66 = the dominant stall**: `FacetSmoothV2._commit` re-merges the whole hop-2..4 annulus (~36 tiles, ~630k indices) with a per-index GDScript loop (`merge_tiles` idx shift), and `step()` commits on every reap ⇒ O(N²) during fill; runs from the first boot frames (above the FP_BOOT_ASYNC early return in `facet_far_ring._process`).
- **setpoint_ms 38.5 is NOT a cost** — it is StreamLoadController's adaptive overload threshold (floor_p10 × margin). phys_ms includes update_streaming (overlaps other counters).
- **Priority inversion**: the controller throttles ONLY the near field; far tiers + sims (env-converge 29.6ms, snow 20-25ms) bypass it — so their stalls cut credit for exactly the work the loading player needs.

Fix design (docs/COSMOS-FAST-LOAD-DESIGN.md): `FP_LOAD_DEFER` one-owner settle latch in WorldManager off `initial_view_meshed` (FP_DEM_DEFER shape, 45s failsafe) freezing smooth_v2 (WS1a reap-only pattern from FacetOrbitRelief), env load-hold (reuse FP_ENV_FALL_HOLD chord-only branch), snow gate; Phase 2 `FP_SMOOTH_V2_PACE` (500ms commit cadence, G3 pattern) + `FP_SMOOTH_V2_ASYNC_MERGE` (merge_tiles is pure ⇒ WTP; main pays only add_surface, ~10-30ms). Arena-slot variant rejected: arrival-order slots break G-V2-PURE's canonical ascending-fid byte-equality. Expected: ~230ms off worst load frames, time-to-usable 2-3min → ≤30s (direct + credit-recovery second-order effect).
