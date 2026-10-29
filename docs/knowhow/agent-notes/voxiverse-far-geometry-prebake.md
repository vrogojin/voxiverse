---
name: voxiverse-far-geometry-prebake
description: "2026-08-10 far-GEOMETRY prebake design (mountains from orbit) — flat-from-orbit = CELLS=4 shell under-sampled + slope-UNSHADED + relief mesh hop-2..4 view-local; fix = 7.5MB global i16 DEM + slope-shade skin layer + view-dependent relief mesh from data; ~37MB total FITS NEVER-OOM"
metadata:
  node_type: memory
  type: project
---

2026-08-10 DESIGN (analysis-only): docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md on deploy/cheats-eyeball. User ask: far terrain GEOMETRY flat from orbit; mountains only appear on approach. Follows [[voxiverse-bg-prebake-design]] (colour-skin prebake, live).

**WHY FLAT FROM ORBIT (3 stacked causes, file-proven):** orbit renders the FacetFarRing shell = per-facet CELLS=4 grids (5×5 nodes ≈104-block cells, cube_sphere.gd:481; near set BACKSTOP_CELLS=16). Relief IS emitted (facet_far_ring.gd:5,28 radial relief per g−SEA_LEVEL) but (a) 104-block cells under-sample the ~92-block-amplitude/~1250-block-wavelength mountains; (b) shell shades by RADIAL normal only → ZERO slope shading → no contrast (the DOMINANT term from orbit — 92 blocks is angularly sub-pixel at alt≥2000; real orbit reads mountains via SHADING not parallax); (c) real relief mesh = FP_SMOOTH_V2 hop-2..4 annulus only (facet_smooth_v2.gd:327-369) → gone beyond ~4 facets.

**DESIGN (3 flags, one data source, ~37MB total = 1.8% of 2048MB ceiling — FITS NEVER-OOM, no compromise):**
- G2 FP_GLOBAL_RELIEF_DATA: whole-planet coarse DEM as DATA — i16 relief @ 32 cells/facet (33² nodes, 13-block pitch) = 3456×33²×2B = **7.5MB** CPU-only always-resident. Baked by the existing FP_BG_PREBAKE governed pacer via bake_smooth_tile (patch 0012, FP_CPP_SMOOTH_BAKE — resolution-AGNOSTIC: any corner_dirs+cells → per-node dir/g/relief arrays; the C++ kernel already exists, flip the flag for the bake path). Edit-invariant (dig is sub-texel).
- G1 FP_SKIN_RELIEF_SHADE: slope shading at ALL distances — G1a SAFE first (L8 slope-magnitude/AO hillshade @64²/facet, +13.5MB, sun-agnostic ⇒ structurally excludes the FP_SMOOTH_V2_LIT wrong-sun-shadow failure class); G1b optional upgrade (RG8 packed normal +27MB, shader runs voxi_shade(n_relief,sun_dir) → live sun-tracking relief light; SAME risk class as V2_LIT so separately gated/rollback-able, ship only after G1a eyeballs).
- G3 FP_ORBIT_RELIEF: view-dependent coarse relief mesh FROM the G2 data (whole-planet mesh stays impossible — 158MB lesson; 3.8M verts). Hop 5..~12 tiles @13-block pitch, built as pure array→mesh transforms (ZERO worldgen sampling at build ⇒ the shelved S-ladder's warmup convoy is structurally gone — its failure mode was per-tile profile_at_dir sampling). V2 policies: residency pure fn of active_fid, draw-over NO exclusion (V2 no-seam law), whole-surface ArrayMesh commits (ANGLE lesson), commits ≤K tiles/frame (REV7 rate-cap lesson). ~150-250 tiles ≈ **≤16MB** transient ledgered. Orbit = nadir-cap set same budget.
- CONTINUUM (no pop): all layers derive from ONE profile_at_dir law through canon facet_corner_dirs ⇒ agree by construction; draw-over ordering near > V2(hop≤4, 8-blk) > G3(hop 5-12, 13-blk) > shell+G1 ⇒ every transition is refinement-on-top, no exclusion holes. No geomorph.

Gates: G-GP-OFF byte-off FLAT 6042/0; G-GP-DATA-EQ (G2==FarDensity.node_at ≤1 quantum, reuse G-CSB-EQ harness); G-GP-BYTES ≤40MB cap; G-GP-WELD (canon-edge bit-equal + no-protrusion under V2); G-GP-PACE (hot frame ⇒ 0 dispatches/commits). Ship order G2→G1a→G3→G1b(optional). Live A/B arbiter: orbit nadir mountains READ shaded; descent relief-to-horizon no pop.

Related: [[voxiverse-bg-prebake-design]] [[voxiverse-far-smooth-geometry]] [[voxiverse-block-lod-design]] [[voxiverse-never-oom-web]].
