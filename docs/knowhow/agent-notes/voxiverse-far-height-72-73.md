---
name: voxiverse-far-height-72-73
description: 2026-08-15 #72/#73 far-render height/misalign — Fable audit verdict + the merged-mesh wrinkle that blocks the designed #72 fix
metadata:
  node_type: memory
  type: project
---

2026-08-15 (unattended). Doc `docs/COSMOS-FAR-HEIGHT-DESIGN.md` (Fable, in main @ 908cbae). Audited the two oldest
open far-render tasks against the SERVED deploy-worktree pck (542 consts, non-stale — per the #131 stale-main-pck
lesson). VERDICT:

- **#73 (orbit/de-orbit facet misalignment): NO code to write.** Every STRUCTURAL misalignment class is proven CLOSED
  live (flags ON in served pck): FS1 FP_SHELL_WELD (radial emit from shared corner dirs — adjacent facets weld
  bit-identical), FS2′ FP_DATUM_BAKE (near lift onto sphere), FP_FIXED_FRAME (set_active re-place is identity),
  FP_DESCENT_FACET_RESYNC + FP_QUERY_FRAME_GUARD, FP_UPVECTOR_FACET_HEAL (#91). §2.1 proves NO per-facet relative tilt
  is expressible: all far tiers are children of the ONE ring node sharing its transform, meshes in ABSOLUTE planet
  coords, welded radially — a single rigid transform can't express facet-vs-facet tilt. The only un-excluded class is a
  RUNTIME pose-desync TRANSIENT (§2.2 C1: re-anchor timing — if PlanetRoot re-anchors frame N and the ring's
  (identity−anchor) pin updates N+1, the WHOLE far stack skews vs NEAR for 1 frame; re-anchors CLUSTER on descent →
  reads as "facets misaligned falling from orbit"). **Build nothing until one reproducing frame exists**; discriminator
  = a scripted de-orbit flight logging re-anchor timestamps vs the captured-misalignment frame (NOT a static weld gate —
  those never caught a runtime desync). If a de-orbit eyeball shows nothing → close as fixed-by. Fix IF repro = ORDERING
  (apply ring pin in the same callback as the re-anchor), ~5 lines, no geometry.

- **#72 (far terrain too low / near blocks float): historical mechanism FIXED live** (the coverage chain
  FP_FARRING_UNCOVERED_TRUE → APPLIED_COVER #89 → APPLIED_PROBE_SLAB #113 → VIEW_BAND #117 → PROBE_CALM #123; live
  sh_applied_r 0→96). **Real residual** = the FP_SMOOTH_V2_NEARFILL tiles sink a UNIFORM 6.0 blk (V2_NEARFILL_SINK,
  hop≤1) so they ride under near blocks; on RELIEF beyond the applied radius the corner-MIN backstop falls away and this
  6-blk sunk skirt becomes the visible surface around the near bubble (near blocks proud above it). Designed fix =
  **FP_V2_NEARFILL_UNSINK** (§3): a VERTEX-shader zone un-sink — recover p_true = p + n̂·u_sink, test the SAME applied
  ellipsoid as facet_far_ring.gd:_applied_covered (:3639, uniforms u_col/u_applied_r/u_params(r,O,H)/u_band_top), keep
  the shipped sunk pos in zone C (under real near mesh), else TRUE − ENV_EPS_G(1.5) → skirt 6→1.5. Byte-off, render-only,
  physics untouched, gl_compat-safe.

**BLOCKER discovered at impl (not in the design): the design assumed SEPARABLE per-tile materials, but
`FacetSmoothV2._build_and_swap` MERGES ALL tiles into ONE ArrayMesh with ONE `_material` (surface_set_material(0,...)).**
There is no per-tile material to swap the un-sink onto. Faithful impl therefore needs a per-VERTEX sink channel: encode
each tile's sink in the FREE `COLOR.a` (shipped shaders read COLOR.rgb only — alpha unused) during merge, and gate the
shader un-sink to `v_sink>0` vertices (sink=0 hop≥2 vertices pass VERTEX=p unchanged → byte-identical; else the un-sink
would drop hop≥2 tiles TRUE→TRUE−1.5). Uniforms updated per step() on MAIN from ring state (V2 HAS a `ring` ref, line
416, + an existing per-frame uniform pattern `set_sun_dir` :650). Composition caveat (design §3.1): shader uniforms
update per-FRAME but backstop geometry per-REBUILD (_async_applied_r frozen at dispatch :2104) → transient zone
disagreement at a ladder step — gate G-FH-UNSINK must assert it closes within ONE rebuild, not assume sync.

DECISION (unattended): did NOT implement #72 blind — it became a design REVISION (per-vertex channel) in the
worst-regression-history subsystem, verifiable ONLY visually, user asleep. Deferred to a with-user-visual-A/B session.
The CPU-mirror zone-law (ellipsoid test) IS headless-gateable; only the final "looks better" needs the eye. When
resuming: extend verify_near_far_height.gd (G-FH-DATUM/UNSINK/OFF), deploy flag-on, screenshot the mountainside
frontier annulus 112–152 flag-off vs on (6-blk skirt → ≤2, sh_applied_r stays ≥64).
Related: [[voxiverse-fartree-frame]] [[voxiverse-mesa-viewband]] [[voxiverse-grassbase-backstop]]
