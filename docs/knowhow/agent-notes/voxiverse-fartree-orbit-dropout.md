---
name: voxiverse-fartree-orbit-dropout
description: 2026-08-15 far-trees vanish above alt 256 (OFFSURFACE_Y hard-suspend) though cards designed to 2400 blocks — root cause + fix direction
metadata:
  node_type: memory
  type: project
---

2026-08-15 (live A/B session). User observed: flying up, the 3D trees disappear — "we should see trees from orbit
(600-700 blocks)". ROOT-CAUSED live: trees abundant at alt 41, GONE by alt 362.

MECHANISM: `FacetFarTrees.step()` (facet_far_trees.gd:767-769) reads `_ring.shell_offsurface()` and if true, calls
`_apply_visibility(offsurf)` which HIDES THE ENTIRE far-tree node + returns early (frozen instance set). Comment
:765-766 "NO far-over-near / orbit suspend (§4.2): trees show ON-surface only; off-surface the whole node is hidden
(mirror of G3's off-surface-only visibility, inverted)". `shell_offsurface()` = `_cam_set and not _emit_floored_last`
(facet_far_ring.gd:3255), armed above **OFFSURFACE_Y = 256.0** (cube_sphere.gd:2240; FR:1198 `_offsurface = h > OFFSURFACE_Y`).

THE CONTRADICTION (the actual bug): the far-tree ladder (docs/COSMOS-FAR-TREES-DESIGN.md) is rung-1 voxel meshes to
FAR_TREES_MESH_MAX=448, **rung-2 cross+cap CARDS to FAR_TREES_CARD_MAX=2400 blocks** (≥ FOG_BEGIN 2200 so fog dissolves
them), rung-3 = fine-map canopy TEXELS (color speckle, ships today, no flag). The cards are built to render out to 2400
blocks camera distance — but the whole tier HARD-SUSPENDS above alt 256. So in the 256→~600 flight band AND from orbit
looking at the limb (terrain within 2400 blocks laterally), 3D trees that are visible + meaningful get culled prematurely.
Design rationale for on-surface-only (§ line 33-34): from TRUE orbit (alt 600+) a 5-12 blk tree is SUB-PIXEL, so 3D is
meaningless and rung-3 canopy speckle (green biome tint on the fine-map skin) is the correct orbit representation —
CONFIRMED working in the orbit shots (forests read as green vs tan desert). So orbit-proper is fine-by-design; the GAP is
the OFFSURFACE_Y=256 suspend firing ~350 blocks BELOW where 3D actually becomes sub-pixel.

The suspend was added (FP_FAR_TREES_COLORFIX §4.2 #115 + NEARCULL #130) for DE-ORBIT correctness: avoid stale band
membership + far-over-near during the descent transition ("correct-or-nothing"). G3 FacetOrbitRelief is the opposite
(off-surface-ONLY, on-surface suspends) — the two tiers were split at the surface boundary.

SHIPPED+MERGED 2026-08-15 (PR #71 main e518742): FP_FT_SHELL_BAND. Three-zone altitude law (h = shell_cam_alt = _dbg_h,
NEW ring accessor): S(h<256) shipped; B(offsurf, 256≤h<FT_SHELL_HIDE_ALT=600) = CARDS live off-surface + mesh rung
HIDDEN + near-cull/guard SKIPPED (vacuous: every tree dist ≥ h > probe_hi) + calmed cadence (move_thr=max(FT_DELTA_MOVE_HYST,
FT_SHELL_MOVE_FRAC=0.25·h), FT_SHELL_REBUILD_MS=500 cap, card-only via _rebuild_cards(shell_mode)/card_inner_radius(shell_mode));
O(h≥600) hidden+frozen, _stale latch moved from any-offsurf to any-zone-O. tier_fade uniform dither-dissolve [520,600]
(shader splice into _CARD_TAIL_FADE, `> v_fade` → `> v_fade * tier_fade`, both plain+XFADE_COMPL variants; set per-frame).
Gate verify_far_trees G-FTSB-OFF/VIS/BAND/LATCH/CADENCE/LEDGER 138/0 (family+flag on); FLAT 6042/0 + far_trees 7/0 byte-off.
LIVE PROOF (confound-free ft_zone telemetry — the KEY lesson: visual/draws A/B was HOPELESSLY confounded by biome +
reload-resets-player-position + scale-convergence of cards≈rung3-speckle + draws dominated by view-extent-not-card-tier
[cards=1 MultiMesh draw]; only a non-visual zone readback settled it): alt 7-227 zone 0 cards+mesh shown; 255-582 zone 1
cards SHOWN mesh HIDDEN (THE FIX — old build suspends here); 603 zone 2 cards HIDDEN (clean handoff to rung-3 speckle).
GOTCHA: shell_offsurface()=_cam_set and not _emit_floored_last (NOT sh_off=_offsurface=h>256); at orbit it IS true so
zone O engages. LESSON: for a far-render A/B add a state-readback field (ft_zone) BEFORE flying — screenshots can't
distinguish tiers at 1:1000. Also: `git checkout -- cube_sphere.gd` after a sed-flag-run DROPS the uncommitted flag
block (commit BEFORE the flag-on gate run; happened twice this session across FT_STALE + SHELL_BAND).
FIX DIRECTION (dispatched to Fable to design): let the 3D card rung render OFF-surface up to its natural distance-fade /
sub-pixel handoff (fog at 2200 / a ~600-blk altitude handoff to rung-3 canopy speckle) instead of the hard OFFSURFACE_Y
cull — carrying the §4.2 stale-band + §5.5 far-over-near correctness filters into the shell regime, and watching perf
(rebuilding the card band while flying, currently frozen off-surface). Byte-off FP flag as always. NOT a regression from
FP_V2_NEARFILL_UNSINK (that's V2 smooth terrain; trees are a separate subsystem).
Related: [[voxiverse-far-trees-design]] [[voxiverse-fartree-polish132]] [[voxiverse-orbit-relief-g3]] [[voxiverse-far-height-72-73]]

DESIGN DONE (2026-08-15, docs/COSMOS-FARTREE-ORBIT-DESIGN.md in the deploy worktree): flag **FP_FT_SHELL_BAND** —
three-zone law: surface (<256) shipped verbatim; shell band [256,600) = CARDS-only visible+live (mesh rung hidden,
guard/NEARCULL geometrically dead since all tree dist ≥ h > probe_hi=168 — asserted not probed), calmed rebuilds
(move_thr = max(12, 0.25·h), 500ms cap, card-only ≈20-30ms — vs #119's 2-4Hz×50-60ms); orbit (≥600) hidden+frozen
(shipped economics), §4.2 _stale latch moved to the 600 boundary (correct-or-nothing de-orbit preserved). 600 chosen
because card footprint ≈ fine-map texel footprint there (~7px both) — rung-3 speckle takes over losslessly. tier_fade
uniform dither dissolve over [520,600] (no rebuild-driven fade). Zero new allocations (NEVER-OOM unchanged).
