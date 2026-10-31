---
name: voxiverse-far-trees-design
description: "2026-08-12 far-trees design — 3-rung hybrid (archetype mini-mesh 128-448 / cross+cap cards to 2400 / fine-map canopy to orbit), octahedral REJECTED for blocky trees; doc COSMOS-FAR-TREES-DESIGN.md"
metadata: 
  node_type: memory
  type: project
---

2026-08-12 FAR-TREES research verdict (doc docs/COSMOS-FAR-TREES-DESIGN.md, deploy-cheats worktree; build phase pending):

- **Hybrid 3-rung ladder**, all rungs pure functions of the SAME TreeGen hashes (tree_gen.gd `has_tree`/`_base_pos`/`_species_for`, salts 11/22/88/55/66/121-125): rung 1 = per-species face-merged voxel **archetype mini-meshes** (~180 tris) MultiMesh 128→448; rung 2 = **cross+cap card impostors** (2 vertical X quads + 1 horizontal canopy-cap quad, 12 tris, alpha-scissor) one merged-atlas MultiMesh 448→2400 (into FOG_BEGIN 2200); rung 3 = **existing fine-map canopy texels** (facet_tex_baker already bakes `top_decoration` leaf colours, ~1-2 texels/tree → orbit forests already speckle; zero new work).
- **Octahedral impostors REJECTED**: blocky voxel trees have ~zero angular variance — 64-view atlas stores near-duplicates; cross+cap gets top-down correctness (the billboard killer) at ~1% memory. Pure camera-facing billboards rejected (orbit/top-down views are core).
- Key mechanisms: trunk-height variance via INSTANCE_CUSTOM vertex trunk-stretch (one mesh/species); deterministic **hash-survival thinning** keep(d) 1200→2400 (stable no-pop density geomorph); sink law mirrors V2_NEARFILL_SINK + BURY=1 so trees stand on the tier's sunk datum (no far-over-near); suspend on shell_offsurface() like G3; radial voxi_shade + FP_FAR_TERMINATOR_WELD sun seed; body gate BEFORE _species_for (Moon biome-id 11/12 alias trap [[voxiverse-tree-bugs-rootcause]]); edit-overlay filter so chopped trees stay chopped.
- Ledger: **<2MB total** (cap FAR_TREES_BYTES_MAX=4MB), ≤7 draws, ≤282k worst tris; caps MESH_INST 1024 / CARD_INST 8192. MultiMesh-on-web precedent: cosmos_border_overlay.gd ships it.
- Stages: P0 cards+enumeration (FP_FAR_TREES+_CARDS) → P1 archetype band (_MESH) → P2 fades+thinning+edits (_FADE) → P3 orbit eyeball+tuning (_SNOW opt). Top risks: mid-band ground tiers (V2/G3) ship flag-off → trees may float on CELLS=4 shell; web enumeration cost unmeasured; 128-edge overlap-vs-gap A/B.

**Why:** placement drift is impossible only if far trees are a refactor-query over TreeGen (the top_decoration pattern), never a parallel placement law.
**How to apply:** build phase implements godot/src/world/facet_far_trees.gd per the doc; hooks: FacetFarRing.setup (FR:503-505 beside V2), step (FR:1283-1291), sun setters (FR:4932-4941).
