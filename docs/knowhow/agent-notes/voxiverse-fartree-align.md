---
name: voxiverse-fartree-align
description: 2026-08-12
metadata: 
  node_type: memory
  type: project
---

Task #120 (design done 2026-08-12, docs/COSMOS-FARTREE-ALIGN-DESIGN.md; impl pending). FAR trees render 1.5-2 blk
BELOW near voxel twins + both render in a ~[128,160] band.

**Offset root (3 stacked constants, NOT a far datum):** E1 enum anchors at ground CELL gy not the stood-on surface
gy+1 (facet_far_trees.gd:566; trunk cells [gy+1,gy+t] tree_gen.gd:331; near render corner-anchored shape_mesh.gd:176);
E2 deliberate BURY=1.0 radial sink (:54,:573); E3 archetype cubes centred at integer cells (+0.5 back, meshes only,
:926); E4 no +0.5 cell centring in lattice_to_world64 (corner-exact, facet_atlas.gd:402) ⇒ 0.71 blk lateral skew.
Cards −2.0, meshes −1.5.

**Overlap root:** inner boundary is a fixed dist<128 cut + FADE dither-in [128,152], but near mesh extent is
32-block-chunk-quantised + view-ramped ⇒ actual reach ~160 (double) or <128 (gap).

**Fix:** FP_FAR_TREES_ALIGN — anchor lattice_to_world64(fid, bx+0.5, gy+1, bz+0.5) == near trunk-bottom-face centre
by construction (same W_fid map + same column_top); archetype −0.5 Y; BURY → distance ramp sink(d)=smoothstep at
rebuild (exact at boundary, buried deep). FP_FAR_TREES_NEARCULL — per-tree ACTUAL-presence probe
skin_near_meshed(fid, 1-cell trunk-base AABB clamped to meshed_slab_y — [[voxiverse-grassbase-backstop]] probe-slab
law) over the live-reach annulus only; probe fingerprint folded into [[voxiverse-far-trees-design]]'s
FP_FAR_TREES_DELTA inputs so mesh arrival under a still camera re-arms the rebuild. Strictly fewer instances, 0 draws.

**Shared predicate (agreed with #121 structures architect):** ONE file godot/src/world/near_presence.gd,
`NearPresence.covered(world, fid, box) -> COVERED|NOT_COVERED|UNKNOWABLE`, #120 owns/implements first
(also COSMOS-STRUCTURES-DESIGN.md §7.3). Order is LOAD-BEARING: slab-clamp (empty ⇒ NOT_COVERED definitive) →
probe COVERED-FIRST (positive is_area_meshed trustworthy at ANY distance) → live-radius gate downgrades only the
NEGATIVE to UNKNOWABLE — radius-gate-first would make the [reach, reach+32] chunk shell (THE double-render band)
permanently UNKNOWABLE and un-fix the bug. UNKNOWABLE never changes consumer state; streaks are consumer policy
(trees HIDE=1 immediate, SHOW=FT_CULL_DWELL=2); pure read (fingerprintable per-step). Gate prefix G-NP-* incl.
positive-reachability assert.

**LESSON:** every far-impostor tier must anchor at the near representation's corner-convention surface cell
(stood-ON = cell+1) and cull on measured near-mesh presence, never a hardcoded band.
