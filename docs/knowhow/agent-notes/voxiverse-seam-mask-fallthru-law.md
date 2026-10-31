---
name: voxiverse-seam-mask-fallthru-law
description: "FALSIFIED 2026-08-06 — my seam-mask fall-through theory was measured wrong (sign backwards + fallback==surface_y); real cause = facet/pose frame desync (fable-fallthrough's doc); lessons + what survived"
metadata: 
  node_type: memory
  type: feedback
---

2026-08-06 task #90: my "seam domain mask + 30.6·d depth lever" fall-under-ground theory was **FALSIFIED by fable-fallthrough's measurement** (probe_seam_tilt.gd, deploy-cheats worktree) on two independent grounds, both of which I then verified in code:

1. **Sign backwards**: all 13,824 seam planes have own-side y-coefficient B > 0 (mhat oriented toward the facet centroid, Bc = mhat·nA in the atlas builder) — descending a column DECREASES own_dist, so a past-ridge column gets MORE masked with depth and is never re-admitted. My straddle-at-depth mechanism does not exist. My lever MAGNITUDE (atan(208/6371)=0.0327) matched their measured 0.024-0.033 — but it describes the mask-boundary slope, not a floor mechanism.
2. **Fallback identity**: a fully-masked column exhausts floor_under's scan and returns `effective_height+1+s` — textually identical to surface_y. The mask is INCAPABLE of floor < surface on un-edited columns; its worst case is a ~1000-iteration perf hit and a SAFE floor.

**The real root cause** (docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md, fable-fallthrough): (active_facet, position) is only eventually consistent — two-phase crossing commit (set_active_facet wm:2522 vs apply_reframe player.gd:779, healed next frame :429) + the measured every-frame re-fire band; wrong-phase queries interpret raw (x,z) in a lattice decorrelated by ±32768 → a DIFFERENT physical column (ocean g≈−15 elsewhere = the observed −12.1). Fixes (design complete 2026-08-06, impl pending): FP_QUERY_FRAME_GUARD (entry-once _pos_fid stamp check, reframe on mismatch path only, read-only vs _heal_frame_desync) + FP_FLOOR_SURFACE_WELD with `FLOOR_WELD_EPS := 2.0` (my catch: shaped spans/snow/smoothed-seafloor make floor legitimately fractionally below surface_y — bare `<` would fire on every slope/swim; gate arms for slope/snow/water no-fire). Probe + masked-cell perf early-out (§5) also in the doc.

**What survived from my analysis**: the entrance-window inventory (move-before-cross same-tick ordering player.gd:665 vs :694, 6-tick cooldown, corner containment strand — deadly only when they DECOUPLE facet from pose frame); the FP_FALLTHRU_PROBE telemetry design (+ adjudicator field: active_fid vs _pos_fid stamp); and a perf ticket — masked columns burn ~1000×2 queries to return what the fallback already knows, so a masked-surface-cell short-circuit is behaviour-identical BY the fallback-identity argument.

**Why:** I reverse-derived d from the observed 24/28 gaps and presented the arithmetic fit as evidence — a fit to the answer is not a prediction. And I asserted a plane-orientation sign from mental geometry instead of reading the builder or measuring.
**How to apply:** before claiming a geometric mechanism, measure the sign/coefficients from the actual data structure (the atlas arrays are dumpable in minutes); treat any "exact arithmetic match" obtained by fitting free parameters to the observation as zero evidence; check whether the accused code path can even REACH the bad value (the fallback identity killed the theory in one line).
