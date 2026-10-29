---
name: voxiverse-seam-slope-weld
description: "2026-08-11 border-slope fall-through MEASURED — seam floor step 1.5-3 blocks (junction cube ladder hi_A vs hi_B + carve fires-flip + One-Surface residual), double-datum flags DOUBLE it; fix FP_SEAM_SLOPE_WELD; doc COSMOS-SEAM-SLOPE-WELD-DESIGN.md"
metadata: 
  node_type: memory
  type: project
---

Task #112 (falls through terrain at facet border on a slope, residual after [[voxiverse-sharp-slope-manifest-stale]]/#111) ROOT-CAUSED by headless measurement (probe godot/src/tools/probe_seam_slope.gd, worktree deploy-cheats), NOT the hysteresis-strip theory alone:

* At fid 578 slot-2 seam (B=579, the user's repro corner), the two facets' analytic floors (== their renders, per #111 parity) at the SAME physical ridge point differ by −1.5..−1.7 blocks (FP_RADIAL_DATUM only), −1.02 (FP_DATUM_BAKE only), **−3.02 with BOTH datum flags on** (plain surface −4.02 — double-datum: datum_shift S + datum_lift s both apply, nothing guards exclusivity, per-facet parity stays green so no gate catches it). Crossing commit = floor pop 1.7–3.0 blocks; pre-commit strip sink up to +2.02 below the neighbour's visible slope.
* Seam band floor rides the FAM_JUNCTION clipped-cube LADDER top hi (junction_modify discards the SLOPE modifier wholesale — C++ patch 0007 ~:1724, GDScript facet_atlas.gd:749), so the carve spread (≤3) is ADDED to the One-Surface residual → slope-specific.
* One station of four had a carve fires-FLIP (A fires, B doesn't) — worst sink there.
* FP_QUERY_FRAME_GUARD/#90 and FP_FLOOR_SURFACE_WELD don't cover this: they never consult the NEIGHBOUR frame's surface.

Fix design (docs/COSMOS-SEAM-SLOPE-WELD-DESIGN.md): FP_SEAM_SLOPE_WELD — in the |own_dist|≤1.5 band, floor = max over both frames of the frame-pure junction-aware band surface (GenCtx(facet=F) statics, reframe_position64, no set_active_facet); inject in floor_under + GroundCollider._emit_column; render untouched (seam ledge stays, sealed). ALSO: confirm served flag set — if FP_RADIAL_DATUM AND FP_DATUM_BAKE are both baked, dropping one halves every seam step planet-wide.

LESSON: the deployed flag COMBINATION can be a bug class of its own — per-facet parity gates cannot see a self-consistent double-shift; only a cross-frame radius compare can. Related: [[voxiverse-facet-seams]] [[voxiverse-floor-surface-root-cause]] [[voxiverse-seam-mask-fallthru-law]] [[voxiverse-nb-junction-weld]]
