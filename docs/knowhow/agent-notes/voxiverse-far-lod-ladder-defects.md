---
name: voxiverse-far-lod-ladder-defects
description: 2026-08-21 three far-render defects (houses-vanish LOD / black facet seam / near-far colour) root-caused by Fable + fixes
metadata: 
  node_type: memory
  type: project
---

2026-08-21 (branch feat/voxiverse-struct-gen): user climbing over a village+forest saw THREE far-render defects. Fable
investigation (self-verifying, headless C++ bake probe + pixel sampling) root-caused all three. KEY: NONE are bugs in the
FP_STRUCT_LOD village-skin bake — Fable byte-verified houses bake into BOTH the fine (64²) and coarse BAND (512²) skin
tiers (refuting my "houses only in fine" hypothesis; band diff 290 texels, fine 6, all idx-8 brown, no edge artifacts).

DEFECT 1 (houses vanish at alt while trees stay) — ROOT: the far-TREE tier has an off-surface shell band FP_FT_SHELL_BAND
(cards fade over FT_SHELL_FADE_ALT..FT_SHELL_HIDE_ALT = 520→600), but FacetFarStructures BINARY-suspends off-surface
(_mi.visible = not shell_offsurface(), flips at OFFSURFACE_Y=256). So houses HARD-CUT at 256 while trees render to 600 →
in 256-600 only sparse house skin texels remain vs prominent tree cards. FIX SHIPPED (commit 942da95, FP_STRUCT_SHELL_BAND,
GDScript-only no rebuild): mirror the trees' 3-zone law onto the structure mesh, REUSING FT_SHELL_HIDE_ALT/FADE_ALT so both
hand off together. CRITICAL: the per-house mesh's radial voxi_shade _material renders BLACK in the orbital-shell frame
(same bug as the reverted aggregate box) → zone-B swaps _mi to an UNLIT vertex-colour material (baked brown) + tier_fade
dissolve. Gate G-ST-SHELL verify_structures 70/0, FLAT 6042/0. Deployed 12:06 GMT. [[voxiverse-fartree-orbit-dropout]]
GOTCHA: the impl agent (isolation:worktree) branched off a STALE base d4c9046 (pre-village) → its commit couldn't ff-merge;
grafted by taking its facet_far_structures.gd (byte-identical P0 base so clean) + re-adding the flag + G-ST-SHELL to the
diverged cube_sphere/verify_structures. LESSON: isolation-worktree agents can spawn on a stale branch ref — always tell the
agent to verify `git log -1`/reset to an explicit commit, and check merge-base before ff-merging.

DEFECT 2 (thin BLACK see-through diagonal seam under player) — PRE-EXISTING (reproduces FP_STRUCT_LOD off; streak colour
(2,12,0) isn't in the 14-colour palette; ruled out bake/index-0/cards/dev-pillars — index 0 renders vertex colour not
black per facet_far_ring.gd:4939/4952). ROOT CLASS (0.9): a geometric see-through crack along a facet-tile boundary of the
far smooth mesh = black void behind shell through the slit. PRIME SUSPECT (0.65): FP_SMOOTH_V2_NEARFILL sinks hop≤1 tiles
by V2_NEARFILL_SINK=6, FP_V2_NEARFILL_UNSINK un-sinks to TRUE−1.5 where uncovered; the adjoining hop-2/orbit-relief sits at
TRUE → open 1.5-6 blk radial step with NO wall along the shared facet edge (documented #72 residual). FIX IN PROGRESS
(FP_V2_EDGE_APRON, agent a0db938c): emit a skirt quad-strip along sunk-tile boundary edges (apron top = neighbour-weld
node_at height, bottom = sunk edge vertex) to close the slit WITHOUT touching the sink (tapering the sink would reinstate
#113 far-over-near protrusion). GDScript-only. Live A/B after deploy is the confirmation of the 0.65 attribution.

DEFECT 3 (near vs far blocky terrain differ in COLOUR under player — olive near bubble vs brighter far skin) — far pipeline
WORKS (FP_SKIN_BLOCK_COLOR/TEXTURE_MEAN/BLOCK_EXACT all ON; far grass samples bit-exact = far_lut[9] = mean_color_of(grass)).
The step is STRUCTURAL/inherent: the far skin samples ONLY each column's nadir TOP block, while the near mesh is 3D (side
faces, strata, shore mixing) → far reads "cleaner". Dominant term = content aggregation, not palette quantisation. Designed
cure = FP_BAND_SHOT (cube_sphere.gd:1843, default false) which bakes the real top-down shot + an analytic SHADE byte,
restoring sub-texel relief/tree shading — but the C++ bake_far_tile returns L8 only, so it bakes on the slower GDScript
surface_shot path OR needs a patch-0011 RG8 extension + ENGINE REBUILD. USER CHOSE to build it 2026-08-21 → FP_BAND_SHOT is DEAD (gate-proven: RG8 90MB>6MB cap; wrong FP_BLOCK_DETAIL
lineage vs live FLATCOLOR; GDScript bake 3.2s/slice) — DO NOT enable it. INSTEAD shipped FP_SKIN_SHADE_PACK (commit
b2cec50, patch 0014): bake a quantised analytic relief-shade (SurfaceShot._shade mirror) PACKED into the existing flat
L8 byte as `b = 1 + idx + 14·shade_q`, idx∈[0,13], shade_q∈[0,17] (18 steps, max 252≤255, 0=un-baked sentinel);
shader decodes `p=b-1; idx=p%14; shade=0.15+0.85·(p/14)/17` × far_lut[idx] under the sun term (single-owner). C++
bake_far_tile computes it near-free from the heights it already has (both band 512² + fine 64² ⇒ no fine↔band seam) +
mirror in facet_orbit_relief shader (same byte). Keeps L8 size (no OOM) + multi-core C++ bake. GATE verify_skin_shade_pack
(G-SSP): C++ packed == GDScript SurfaceShot._shade byte-equal **0/38400 columns**, SPREAD 7 distinct shade steps + tree
(shade VARIES, not uniformly dark), OFF byte-identical, CAP≤252. FLAT 6042/0. GATE-RUN GOTCHA: run it with the GLOBAL
FP_SKIN_SHADE_PACK **OFF** (FACETED + flat-lineage flags on) — the gate builds gen_off/gen_on via _build_cpp_gen
OVERRIDES; global-on makes gen_off pack too → G-SSP-OFF + SPREAD cascade-fail (off_bad continue starves q_hist). Rebuilt
(editor 15s + full web 4min, module_in_web=yes) + DEPLOYED 13:32 GMT w/ FP_SKIN_SHADE_PACK in CS_FLAGS. All 3 defects
(FP_STRUCT_SHELL_BAND / FP_V2_EDGE_APRON / FP_SKIN_SHADE_PACK) LIVE; live A/B pending user reload+re-arm. SIDE: my
FP_STRUCT_LOD dark_oak→idx-8 remap widened the skin↔mesh HANDOFF pop (near dark_oak texture vs skin lighter idx-8); cleaner
option FP_STRUCT_PALETTE_EXT = append a 15th palette entry = mean_color_of(dark_oak_log), BUT need to verify the C++
far_colors config ingests >14 entries (FarColor enum sized 14 for terrain classification — deco indices are LUT-driven so
likely fine, UNVERIFIED, possible rebuild). SHARED ROOT: defects 1 & 3 both = "the flat nadir skin is the only rep left
once the 3D tiers drop out"; defect 2 is an unrelated pre-existing geometry seam.


MERGED TO MAIN 2026-08-21: PR #77 (merge commit 818657a) — the 3 far-render defect fixes all shipped to origin/main. Branch feat/voxiverse-struct-gen (13 commits: e3a634c..b2cec50). All byte-off (FLAT 6042/0), C++ byte-equal proven (G-SG-CPP 0/1535, G-SG-SKIN-CPP 0/590, G-SSP 0/38400), live-verified. patches 0013 (village mirror) + 0014 (skin-shade-pack) now in the engine build.