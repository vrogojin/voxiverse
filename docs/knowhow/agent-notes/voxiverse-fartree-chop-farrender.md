---
name: voxiverse-fartree-chop-farrender
description: 2026-08-15 chopped tree still FAR-renders — ROOT CAUSE = rung-3 fine-map skin bakes tree canopy colour edit-unaware (cards/mesh ARE chop-filtered)
metadata:
  node_type: memory
  type: project
---

2026-08-15 user goal (after agent-control PR #72 merged to main f338706): "trees FAR rendering. Ensure chopped
tree will not FAR render." A near tree the player chops must NOT reappear in ANY far tier.

ROOT-CAUSED (branch fix/voxiverse-fartree-chop off main f338706). The far-tree ladder has THREE rungs:
- rung-1 voxel MESH (FacetFarTrees, to FAR_TREES_MESH_MAX=448) — CHOP-FILTERED ✓
- rung-2 cross+cap CARDS (to FAR_TREES_CARD_MAX=2400) — CHOP-FILTERED ✓
- rung-3 fine-map SKIN canopy colour (FacetSkinTier, 96-256 blk + owns orbit zone O) — NOT FILTERED ✗ = THE LEAK

MECHANISM of the working filter (rungs 1-2): facet_far_trees.gd `_is_chopped(fid,bx,gy,bz)` (:753) →
`_chop_query.call(fid, Vector3i(bx, gy+1, bz))` = is the FIRST TRUNK cell (gy+1) edited. Applied at card rebuild
(:1183) + mesh rebuild (:1299): a chopped tree is `continue`-skipped. Fed by WorldManager.far_tree_chopped
(world_manager.gd:3673) = `_edits.has(FacetAtlas.edit_key(fid,cell))`, guarded `_edits.is_empty() or _chart != null
or not FACETED`. In the SERVED build _chart == null (FLAT+FACETED; _chart only set in curved M5_REAL mode,
:355-357) and FP_FAR_TREES_FADE is in CS_FLAGS → filter ACTIVE. Rebuild is retriggered on a chop via edit_count()
bumping `_edits_rev` (facet_far_trees :1069 `_current_edits_rev() != _last_rebuild_edits_rev`).

**CORRECTION (Fable, verified against served code — see [[voxiverse-fartree-chop-design]] + docs/COSMOS-FARTREE-CHOP-DESIGN.md):**
the leaking rung-3 is NOT facet_skin_tier.gd — its `sample_columns`/`far_color` (cpp:1930-1948) classify terrain-only
`top_block_id`, never a tree branch (and FP_SKIN_TIER isn't even served). The REAL leaking skin is **facet_tex_baker.gd**
(FacetTexBaker): the FP_SKIN_FLATCOLOR BAND map (512²/facet, 96-256 underlay) + FP_PLANET_MAP whole-planet FINE map
(owns orbit). Its 3 `_pbm_compute` paths (C++ bake_far_tile tree branch cpp:2264 / TreeGen.top_decoration) paint procedural
trees ignoring _edits. ALSO: patch 0011's `bake_far_tile(…, edit_cells, edit_far_idx)` ALREADY ships a per-column EDIT
override that runs BEFORE the tree branch (EDIT→TREE→TERRAIN, cpp:2255-2276) — but its GDScript writer `_edit_snap`
(facet_tex_baker.gd:124) is DEAD ("empty until Stage-B wires it"). So the fix = FP_FT_SKIN_CHOP Stage-B snapshot writer,
GDScript-ONLY, NO engine rebuild (NOT the C++-rebuild option I feared). The mechanism paragraph below (procedural tree
bake edit-unaware) is RIGHT; only the FILE was wrong (facet_tex_baker, not facet_skin_tier).

THE LEAK (was mis-attributed to facet_skin_tier; see correction above): facet_skin_tier.gd `_build_tile` (:446) → `_sampler.call(fid, packed)` returns per-column
{heights,colors}. The LIVE sampler is the C++ VoxelGeneratorCosmos.bake_far_tile (docker/engine/.../voxel_generator_
cosmos.cpp + patches 0011-cosmos-parallel-tile-bake / 0012-cosmos-smooth-tile-bake) whose "tree branch" (deco_far_idx
= FarPalette.far_index_lut, facet_skin_tier :591) paints LEAF/WOOD far-palette colour where PROCEDURAL TreeGen puts
a tree — sampled from column_profile + tree gen, NEVER consulting _edits. So a chopped tree's canopy colour STILL
bakes into the skin tile. (The GDScript oracle `gd_sample` :606 paints ONLY terrain `FarPalette.color_for(g,biome,..)`
— NO trees — so it's a fallback that happens to not leak; the C++ path is what serves + leaks.) The skin underlays
the cards at 96-256 (tier-depth: cards/blocks beat skin) so where a chopped card is now gone the skin speckle shows;
and from orbit (zone O, cards+mesh hidden by FP_FT_SHELL_BAND) the skin/fine-map IS the tree representation → chopped
tree shows as green speckle.

FIX DIRECTION (dispatched to Fable): make the skin tile edit-aware for chopped trees. Two families —
(A) C++: pass the chopped-tree base set (or the edit overlay) into bake_far_tile; skip the tree branch for a column
whose tree base is edited → falls back to terrain colour. Byte-equal off. Needs an ENGINE REBUILD (~24min, the long
pole) + patch 0011/0012 edit + gd_sample mirror. (B) GDScript no-rebuild: post-process `_build_tile`'s returned
colors — for each chopped tree overlapping the tile, overwrite its canopy-footprint columns with the terrain colour
(recompute via the gd_sample color_for path / a second terrain-only sample). Needs to enumerate chopped trees in the
tile (reuse the TreeGen enumeration FacetFarTrees already does + the _is_chopped predicate) + map canopy footprint →
columns. Prefer (B) if the canopy-column mapping is tractable (no rebuild, faster live A/B); else (A).
CAVEATS: skin tile bake is CACHED (rebuild on edit_count bump like the far-trees — wire the skin rebuild to the chop
revision too, else stale tiles keep the speckle). Byte-off FP flag (e.g. FP_FT_SKIN_CHOP). Robustness: `_is_chopped`
checks only gy+1 — a mid-trunk chop leaving the gy+1 stump won't register (edge case, note but likely out of scope).
Gate verify_far_trees + a skin-tile gate (chopped column reads terrain colour, un-chopped reads tree colour) + FLAT
byte-off. Live A/B: chop a near tree, fly to orbit, confirm no green speckle where it was.
SHIPPED 2026-08-17: FP_FT_SKIN_CHOP implemented (fable-fartree-chop wrote it into the shared worktree
alongside the design; I reviewed line-by-line) + committed 8b1b927 on fix/voxiverse-fartree-chop (off main
f338706). Gates GREEN: verify_ft_skin_chop 21/0 (incl. C++ bake_far_tile ≡ GDScript with the chop snapshot,
chopped-footprint texel==terrain index, ≥1 changed non-vacuous, invalidate+in-flight _skin_stale) +
verify_tile_bake 76/0 + FLAT verify_feature 6042/0 byte-off. DEPLOYED live (deploy_cheats CS_FLAGS +=
FP_FT_SKIN_CHOP). LIVE A/B: single tree chopped + confirmed gone from the top-down far view; multi-tree
cluster visual NOT completed (see below). NOT PR'd/merged yet — still on fix/voxiverse-fartree-chop.
AGENT-CONTROL PAID OFF: swapped the relay (update_relay.sh, dawn1 guard bypassed per user — dawn1 timed out
6h) → P0 fs.watch + P2 query LIVE. query_box returned a real 567-cell u8 grid; query_ray gave the exact
crosshair cell + block_id + IN_RANGE → the remote tree-chop that was IMPOSSIBLE last session (5 fails) worked
FIRST TRY: fly until query_ray in_range=true, then break target:"aim". THE chop that motivated the whole initiative.
LIVE-DRIVING LESSONS (remote ACTUATION is the remaining rough edge — points at the P3 follow-ups goto/pathfind +
reach-aware break): (1) break target:"aim" only fires when query_ray in_range=true (dist ≤ break_reach ~4);
aim=none ≠ no tree, it = out of reach or ray threading past a 1-wide trunk. (2) break target:[x,y,z] EXPLICIT
CELL does NOT fell terrain (8 wood cells survived teleport+cell-break) — only "aim" works; cell-break is a
dead path for terrain (needs a P3 reach-aware break-by-cell). (3) walk "move forward" STALLS on grass ledges/
slopes (pos frozen); set_fly on advances reliably. (4) telemetry `pos` = GLOBAL/scene; NAV HUD `pos` = LATTICE
cell — different frames, don't mix. (5) query_box center y must reach DOWN to trunk bases on sloping terrain
(a player-centered box while flying is all air). (6) relay restart resets the frozen celestial clock → re-set
time; freeze_time must be OFF to let a new set_time apply (freeze holds the old time against set_time).
SKIN-ONLY VISUAL is inherently confounded at 1:1000: at 96-256blk cards(rung-2, already filtered) AND band-skin
both remove the chopped tree; only zone-O (>600blk, cards hidden) isolates rung-3 but one tree is sub-pixel →
the GATE is the definitive rung-3 proof, not the eyeball. Trees are SPARSE (savanna thinning) so no dense cluster
to gap here anyway.
Related: [[voxiverse-agent-control-initiative]] [[voxiverse-fartree-chop-design]] [[voxiverse-far-trees-design]] [[voxiverse-fartree-orbit-dropout]] [[voxiverse-skin-block-color]] [[voxiverse-cpp-tile-bake-block-exact]] [[voxiverse-far-skin-block-color]] [[voxiverse-agent-control-initiative]]
