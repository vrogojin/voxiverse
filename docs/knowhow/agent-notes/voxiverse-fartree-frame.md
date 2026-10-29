---
name: voxiverse-fartree-frame
description: 2026-08-13
metadata: 
  node_type: memory
  type: project
---

Task #131 (far/near tree misalign at facet 1133 boundary) root-caused 2026-08-13, doc
COSMOS-FARTREE-FRAME-DESIGN.md. NOT the neighbour-frame anchor (near neighbour slots render in their
OWN facet frame == lattice_to_world64(owner) by construction — module_world.gd:1926 ==
facet_atlas.gd:542/402; FP_NB_WELD only changed the seam probe). Two real defects, both in
facet_far_trees.gd, both global-but-position-dependent:

- **A altitude**: enum anchor (:739-742) omits FS2′ `datum_lift` while FP_DATUM_BAKE=true live lifts
  the near mesh onto the sphere → far tree alone stays on the facet PLANE: s ∈ [−1.5 (corner float),
  +5.5 (centre bury)], +3.3 edge-mid. skin tier already adds it (facet_skin_tier.gd:560); V2/far-ring
  emit radially. G-FTA-1 pinned the plane law — the lift lives in C++ patch 0010, invisible headless.
- **B rotation**: card/mesh instance basis = (r×ŷ_world, r, ·) (:964-975, :1077-1085), not the owner
  lattice (ê_u, n̂, ê_w). Visible = yaw mod 90°: 1.2° on face-1 facets around 1133, **31-41° on the
  face-3 facets across 1133's cube-face fold** (i=23 row), 36.7° at 1754 (the "aligned" A/B checked
  height only). Boundary-specificity is visibility (two yaw families side by side at a fold), not
  mechanism.

Fix: FP_FT_FRAME_WELD — enum `ay += datum_lift(fid, ax, az)` (tracks FP_DATUM_BAKE by construction)
+ writers use frame_basis(owner fid) as instance basis. Gate G-FTF-3: cross-fold pose equality
(position AND rotation) + assert shipped-basis yaw > 30° there. FacetFarStructures has the SAME
datum omission (facet_far_structures.gd:266) — #121 follow-up.

LESSONS: (1) the served pck to dump is the DEPLOY WORKTREE's build/web/, not the main checkout's
(main's is stale — 243 consts vs 529); (2) a "looked aligned" live A/B only covers the property it
measured (1754's census counted trunk pixels, never orientation); (3) any tier anchoring via
lattice_to_world64 must add datum_lift or it sits below the sphere by the sagitta.

Related: [[voxiverse-far-trees-design]] [[voxiverse-fartree-shift-residual]] [[voxiverse-nb-junction-weld]]
[[voxiverse-facet-seams]]
