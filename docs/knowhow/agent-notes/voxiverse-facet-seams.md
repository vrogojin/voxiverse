---
name: voxiverse-facet-seams
description: "2026-07-19 ROOT-CAUSED: facet-seam 8-block cliffs = plane-datum step (height g is d̂-pure but PLACED g blocks up each facet's own mean plane; adjacent planes differ at the shared edge by max 5.30 blocks, exactly ∝R — old R=3072 was 2.56, hidden); far-shell holes = per-facet planar edge chords (crack 5.30) + 13-block sink cliffs + T-junctions; fix = FP_RADIAL_DATUM per-column shift S + FP_SHELL_WELD radial emission; docs/COSMOS-FACET-SEAMS-DESIGN.md"
metadata: 
  node_type: memory
  type: project
---

**The facet-seam misalignment (pilot report 2026-07-19, R=6371 K=24 edge≈417) is FULLY ROOT-CAUSED
— docs/COSMOS-FACET-SEAMS-DESIGN.md (commit 4b8cb1c on docs/voxiverse-atmo-sky-design) is the
authoritative writeup.** Key facts (f64 probe replicating _build_facet/_build_seam, all 6912 seams):

- Height g = profile_at_dir(d̂) IS seam-continuous as a function; the discontinuity is PLACEMENT:
  the surface is written at facet-lattice y=g and lattice_to_world64 counts y up each facet's OWN
  mean plane along its OWN normal (facet_atlas.gd:402-408; fill via column_profile→facet_profile,
  terrain_config.gd:754/986). Adjacent facets' planes sit at different signed distances from the
  shared true edge (spherical quad corners non-coplanar, warp-sheared): **step max 5.30, p90 3.37,
  p50 1.14 blocks at R=6371 — EXACTLY ∝R (×2.0739 vs R=3072 where max was 2.56 and hid under
  ±1-block terrain texture)**. + cross-seam sampling offset ×mountain gradient ≈1-3 → observed 8+.
  The rescale amplified a latent discontinuity linearly; the cube-sphere parameterization itself is
  NOT discontinuous and needs no change.
- Sagitta: facet plane sags 6.81 blocks below sphere datum mid-facet (3.66 mid-edge) — why
  BACKSTOP_SINK is ~13; all plane-anchored tiers share the bowl so it's not a seam step, but it
  blocks radial far placement until fixed.
- Far-shell holes: facet_far_ring builds each far facet from its OWN planarized corners → shared-
  edge chords disagree up to 5.30, never bit-weld, no skirt; + backstop(sunk 13)↔horizon(unsunk)
  role cliffs; + BACKSTOP_CELLS=16 vs CELLS=4 T-junctions.
- Skin tier uses lattice_to_world64 → agrees with near voxels (inherits the seam step, fixed by the
  same datum shift). SEA_LEVEL=0 so the far ring's (g−SEA_LEVEL) radial relief is NOT a datum bug.

**THE FIX (staged, flag-gated, One-Surface Law: every tier renders at P(d̂)=(R+relief)·d̂ − sink):**
FS0 pin gate (verify_facet_seams, expects 5.30/2.77/6.81/5.30 at 6371, ÷2.0739 at 3072) →
FS1 FP_SHELL_WELD (radial emission from SHARED corner dirs ⇒ bit-identical edge verts ⇒ shell
closes; coarse-owns-edge T-rule; sink ramp; safe BEFORE datum fix at current 13-sink) →
FS2 FP_RADIAL_DATUM (per-column S = round(solve |p0+s·n̂|=R) ∈[0,6.9], applied as a RE-INDEX
y−S at the two window exits (junction_modify pattern) + height funnels + skin sampler; resolve_cell
/worldgen untouched — runs in true-height space; sea surface = SEA_LEVEL+S rides the sphere;
C++ VoxelGeneratorCosmos mirror needs NO new frozen data (facet_frame/off/r already passed) but a
patch+full rebuild) → FS3 sink shrink 13→ε≈2-3 + G-TIER-ALT cross-tier gate → FS4 one build queue
(px_error_reduction/cost priority over existing executors, StreamLoadController admission,
make-before-break invariant). NEVER-OOM: ~0 bytes (S is arithmetic; weld changes cache values not
sizes; queue ≤16KB).

**V2 REVISION (2026-07-20, pilot-driven — docs/COSMOS-FACET-SEAMS-V2.md, commit 5cec701):** live
pilot confirmed FS1 (shell closed) + FS2 fixed the border cliffs, BUT **FS2's integer re-index
TERRACES the facet interior** (~7 S-contour rings/facet cut 1-block ledges across smooth plains
AND break smoothing ramps computed pre-shift) → **FS2 RETIRED**, replaced by **FS2′ FP_DATUM_BAKE**:
the SAME datum s(fid,X,Z) applied UNROUNDED/CONTINUOUS at the render/collision/input boundary
(y_play = y_cell + s), content byte-identical — near mesh via the patch-0003 set_cosmos_bake C++
vertex hook (exists in-tree, curved-R2 precedent), skin one line, far already radial (FS1), analytic
floor/DDA convert per column. Zero terracing by construction (gate G-D2-SHAPE: flag-on mesh ==
flag-off + s·ŷ per vertex). Border ≤0.2 (better than FS2's ±1). Also root-caused: **invisible
wall at border** = corner containment refusal (world_manager.gd:1807-1813) + cooldown letting the
analytic floor carry the player to the permanent −3 ridge wall (:2860-2865, FACET_WALL_EPS) → fix
FP_CROSS_CORNER_COMMIT (argmax-own-dist over {2 edge neighbours, diagonal}, cooldown void past
own_dist −1; GDScript-only, ship first). **Crossing orientation glitch** = handed off: under
FP_FIXED_FRAME the SHIPPED +yaw_delta twist is the world-heading-preserving branch and
FP_CROSS_KEEP_HEADING (local unchanged) SNAPS by the inter-frame yaw — the flag's semantics invert
between frame modes (player.gd:313-316 vs world_manager.gd:1880). CONFIRMED by team-lead: the live
deploy sed-flips BOTH FP_FIXED_FRAME and FP_CROSS_KEEP_HEADING ON → the snap is real, fix =
frame-aware twist (under fixed frame, KEEP_HEADING must apply +yaw_delta). V2 ACCEPTED 2026-07-20;
one impl agent builds FS2′+FS-W+twist together, ship order FS-W/twist (GDScript) → FS2′ (rebuild);
FS2 stays ON live in the interim (team-lead chose terraces over cliffs until FS2′ lands).

**Why:** three prior "accept it"-class conclusions on seams were wrong; this one is pinned by a
falsifiable number (5.30 ∝R) reproducible in-engine — and the V2 lesson: an integer content shift
can never be smooth (any post-resolve integer shift breaks smoothing at its contours); continuous
corrections belong at the render/physics BOUNDARY, not in content. **How to apply:** implementers
start at FS0; never re-anchor heights to facet planes in any new tier — sample H(d̂) and place at
P(d̂); the sink ladder must never again encode sagitta. See [[voxiverse-faceted-planet]],
[[voxiverse-seamless-scales]], [[voxiverse-tier-depth-priority]], [[voxiverse-never-oom-web]].
