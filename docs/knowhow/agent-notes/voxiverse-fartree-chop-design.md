---
name: voxiverse-fartree-chop-design
description: 2026-08-15 #137 chopped-tree far-skin leak IMPLEMENTED 8b1b927 (FP_FT_SKIN_CHOP Stage-B edit-snap writer; gates 21/21+76/0+6042/0); rung-3 = FacetTexBaker band/fine L8 maps NOT facet_skin_tier; NO engine rebuild
metadata: 
  node_type: memory
  type: project
---

Task #137 chopped-NEAR-tree-still-FAR-renders, design in docs/COSMOS-FARTREE-CHOP-DESIGN.md (deploy-cheats worktree, branch fix/voxiverse-fartree-chop). IMPLEMENTED 2026-08-15 commit 8b1b927 (6 files, +842): flag cube_sphere ~:713; WorldManager far_skin_edit_snap/_is_trunk_base_edit + _write_cell/erase hooks; FacetTexBaker _snap_slot per-slot freeze + invalidate_far_skin/_skin_stale drains; gate verify_ft_skin_chop 21/21 (incl C++ leg), G-CPB 76/0, FLAT verify_feature 6042/0. Gate-forcing `force := CubeSphere.FP_FT_SKIN_CHOP` default-arg params let the gate run without sed-flipping the flag. REMAINING: add FP_FT_SKIN_CHOP to the deploy flip set + live A/B.

**Corrected attribution**: the leaking rung-3 "fine-map skin" is FacetTexBaker's L8 index maps — BAND (FP_SKIN_FLATCOLOR, 96-256 underlay) + whole-planet FINE (FP_PLANET_MAP, owns orbit) — NOT facet_skin_tier.gd. FacetSkinTier/sample_columns colours are terrain-only (`far_color` uses top_block_id, never tree_top_decoration, cpp:1930-1948) — a non-leaking bystander.

**Decisive fact**: patch 0011's `bake_far_tile` ALREADY ships a per-column edit override (edit_cells/edit_far_idx → EditTable) that runs BEFORE the tree branch (texel law EDIT→TREE→TERRAIN, cpp:2255-2276), byte-gated by verify_tile_bake:164; the GDScript consumer `_edit_snap` (facet_tex_baker.gd:124) is a documented DEAD PATH "empty until Stage-B" (:1959-1963). So the fix is the Stage-B snapshot writer scoped to chopped trees — GDScript only, no 24-min engine rebuild.

**Design**: FP_FT_SKIN_CHOP. WorldManager.far_skin_edit_snap(fid) = {chopped tree footprint column → TerrainConfig.top_block_id} (footprint = the tree's own G×G gcell where TreeGen.top_decoration != AIR — columns only ever carry their own gcell's tree, so exact + no tile-boundary case); memoized per (fid, edit_count). Snapshot frozen MAIN-thread at each _pbm dispatch into per-slot arrays. Coherence: _write_cell/erase detect trunk-base toggle → _facet_tex.invalidate_far_skin(fid) (= _fine_baked.erase + _evict_band + in-flight _skin_stale guard).

**Why:** avoids re-deriving what the engine already does; keeps the one-classification-law byte-equality (chopped column bakes bit-equal to treeless terrain under FP_SKIN_BLOCK_EXACT via the same top_block_id call).
**How to apply:** before proposing any C++ bake change, check whether patch 0011's edit_cells parameter + the [[voxiverse-cpp-tile-bake-block-exact]] transport already carries it. Mid-trunk stump gap (gy+1-only chop predicate) deliberately kept consistent across rungs; upgrade = follow-up FP_FT_CHOP_TRUNK_SPAN in _is_chopped + the snapshot predicate. Related: [[voxiverse-far-trees-design]], [[voxiverse-fartree-orbit-dropout]].
