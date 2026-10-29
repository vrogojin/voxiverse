---
name: voxiverse-structures-design
description: 2026-08-12 task
metadata: 
  node_type: memory
  type: project
---

Task #121 DESIGN complete (2026-08-12): docs/COSMOS-STRUCTURES-DESIGN.md. Player-built + generated
structures rendered far/orbit like far-trees. Architecture: ONE StructureRegistry, two producers —
(a) P0 `FP_STRUCT_DETECT` incremental union-find over placed `_edits` at the ONLY two choke points
(`_write_cell` wm:1901 / `sim_revert_cell` wm:1968; snow-material filter — the snowfall sim writes
edits too); (b) P1 `FP_STRUCT_GEN` StructureGen = TreeGen-pattern hash placement (village lattice
V=192, house sub-lattice H=32, jitter-bounded footprint ⇒ O(1) block_at bijection), consulted beside
TreeGen.block_at in resolve_cell so physics/collapse/streaming are free. FAR = `FP_STRUCT_FAR`
per-structure OR-occupancy decimation (NOT FacetBlockLod's MIN — MIN erases 1-blk walls; majority-
colour law reused verbatim) baked off-thread via JobLane, merged into 2 ArrayMesh band draws under
FacetFarStructures (FacetFarTrees clone, delta-gated), 8 MB hard cap.

P1 AS-BUILT REVISION (2026-08-15, doc §12, SUPERSEDES §5.4/§6.4): served-pck dump proved
FP_CPPGEN=true + FP_CLIMATE_BIOMES=true + FP_STRUCT_DETECT/FAR/NEAR_GUARD=true LIVE ⇒ interlock is
live-real (never flip FP_STRUCT_GEN in a pck before the C++ mirror is deployed byte-equal). (a) The
air-ceiling col_hi widening DISSOLVED by the HEIGHT-BUDGET LAW: STRUCT_H_MAX 11 + FLAT_TOL 3 = 14 ≤
TreeGen.MAX_ABOVE_SURFACE ⇒ both fast paths' existing envelopes cover houses, zero hot-path edits
(gate G-SG-ENV). (b) Mirror ships as NEW cumulative patch 0013 (the 0011 climate-species precedent
— amend generators/cosmos/, config-key "struct_gen" sentinel, reuse cosmos::tree_hash01 w/ salts
201-209), NOT edits to 0007. (c) FOUND pre-existing latent divergence: 0007 max_above literal still
10 vs tree_gen 14 (jungle) — C++ can clip jungle canopies at block boundaries under live flags;
0013 fixes to shared 14. (d) claim_at is TRI-STATE (−1 no-claim / 0 authoritative interior air /
>0 id) — binary AIR re-opens snow-filled interiors + doorway lips; 2 consult sites in resolve_cell
(tc:1384-1387, 1394+). (e) structure_cell_at:3596 `v<=0→0` merges dug(0)/absent(−1) — MUST split or
GEN damage never shows far (G-SG-DAMAGE). (f) GEN roots = negative packed site ids (disjoint from
edit-key roots); registry = tracker.registry() + StructGenIndex concat behind the ONE callable.

KEY TRAPS DESIGNED AROUND (P0-era; (1)(2) superseded above): (1) patch 0007 C++ generator fully mirrors TreeGen — FP_STRUCT_GEN must
interlock with FP_CPPGEN until a P1b mirror lands (engine rebuild); (2) module_world 5×5 air-ceiling
stencil (mw:3692-3707) exists because tree reach ≤2 cols — houses reach ~5, need a hash-gated col_hi
term, NOT an 11×11 stencil; (3) handoff cull = shared [[voxiverse-far-trees-design]] #120 predicate
`NearPresence.covered(fid, box) -> COVERED|NOT_COVERED|UNKNOWABLE`, CONTRACT AGREED with
fable-fartree-align (they own near_presence.gd): evaluation order is COVERED-FIRST and load-bearing
— slab-clamp (empty ⇒ NOT_COVERED definitively), then is_area_meshed TRUE ⇒ COVERED at ANY distance
(radius-gate-first would make the [reach, reach+32] mesh_block_size-32 quantisation shell
permanently UNKNOWABLE = exactly the #120 double-render band, module_world.gd:393); only a FALSE
answer is radius-ambiguous (outside live reach ⇒ UNKNOWABLE). Pure read; UNKNOWABLE never changes
consumer state; streaks per-consumer (trees hide at 1, structures 2). Dead-latch lineage:
[[voxiverse-grassbase-backstop]]. Orbit honesty: houses sub-pixel from orbit → P2 fine-map
roof texels + ≥48-blk large-structure exception only.

BUILD STARTED 2026-08-18: user chose the FULL build (GDScript StructureGen + C++ mirror + engine rebuild) over
fast-GDScript-gen / orbit-only-preview — real villages near+far at full C++ streaming speed. Rollout interlock
(§12.6, the ONLY safe order since FP_CPPGEN is live-true): P1a GDScript StructureGen + struct_gen_index + 2 resolve_cell
claim sites + registry/sampler/rev, ALL byte-off, gate incl assert not(FP_STRUCT_GEN and FP_CPPGEN) → P1b patch 0013
C++ mirror (reuse cosmos::tree_hash01, salts 201-209, config-key "struct_gen", max_above 10→14 fix) + scripts/build.sh
rebuild (~24min, ALLOWED this session) + verify_cppgen byte-equal over village blocks, THEN relax the interlock →
P1c deploy new engine+pck with FP_STRUCT_GEN flipped TOGETHER (never pck alone). P1a dispatched to a worktree team
agent 2026-08-18.

P1a+P1b BUILT + BYTE-EQUAL 2026-08-18 (branch feat/voxiverse-struct-gen). P1a e3a634c (GDScript StructureGen +
struct_gen_index + 2 resolve_cell claim sites tc:1397/1415 + registry/sampler/rev): verify_structures 57/0, FLAT 6042/0.
P1b patch 0013 (C++ mirror, reuse cosmos::tree_hash01, salts 201-209, config "struct_gen"/house-mat-ids single-home,
max_above 10→14) + verify_cppgen G-SG-CPP byte-equal gate + interlock relaxed to equal-or-off. RE-VERIFY GOTCHAS: (1) the
G-SG-CPP gate initially swept g-4 + non-house cells → lumped in a PRE-EXISTING FACETED C++↔GDScript divergence (G-CG-
COLUMNS colours 3252 + below-ground 690, present with FP_STRUCT_GEN OFF, NOT from 0013) → I restricted G-SG-CPP to
claim>=0 village-owned cells (commit 872c4c2). (2) THEN a real climate-only bug: byte-equal FP_CLIMATE_BIOMES off (0/1250)
but 177/1250 ON. ROOT (commit 301e7b4, moon-alias weld) — NOT a hash trap: with FP_BIOME_SPACE_FIX OFF moon_biome_id(0..2)
=11/12/13 ALIAS Earth B_SAVANNA=11/B_JUNGLE=12; GDScript resolve_cell intercepts moon-id columns FIRST via is_moon_biome→
_moon_cell (airless above surface, tc:1365) BEFORE the struct claim, but C++ resolve_cell_core had NO moon branch → built a
house where GD renders air. FIX = mirror the moon branch in C++ (`biome∈[moon_lo,moon_lo+2] && y>g → AIR`) + a moon_biome_lo
config passthrough (sentinel -100=absent→legacy). Rebuilt (SKIP_WEB, ccache 14s incrementals) + re-verified: G-SG-CPP
**0/1250 in BOTH FP_BIOME_SPACE_FIX states** (off + on=LIVE) under climate ON, FLAT 6042/0. The C++ village mirror is
byte-equal to GDScript. P1c DEPLOYED 2026-08-18: full web build (module_in_web=yes) + deploy w/ FP_STRUCT_GEN on (last-mod 21:46 GMT), byte-off.
Then bumped VILLAGE_CHANCE 0.05→0.5 (BOTH structure_gen.gd:29 AND patch 0013 const, byte-equal maintained: G-SG-CPP
0/1391) + rebuilt + redeployed for easier viewing. FINDABILITY SNAG: villages are TERRAIN-GATED (has_village site test:
anchor biome∈{B_PLAINS,+B_SAVANNA under climate}, 4×4 flat stencil max−min≤4, above SEA_LEVEL+2), so even 10× density
only places them on suitable flat plains/savanna — enumerate found 0 villages on facets 0-12 (spawn=facet 2 lacks a
suitable site); the verify gate scans up to 4000 facets to find any. So density bump alone does NOT put a village at
spawn. LIVE SMOKE BLOCKED: remote-drive consent grant lapsed (browser reload, no re-arm) — could not screenshot/teleport
to confirm. OPTIONS for eyeball (user to pick): (A) re-arm ?remote consent → I teleport session to nearest village +
frame tour; (B) relax the site gate (drop biome restriction / loosen flatness) so villages are common on all land near
spawn — one more C++-mirror rebuild+byte-equal cycle. NOT merged to main yet (holding for a live smoke). LESSON: village
findability is dominated by the SITE gate (suitable terrain), not VILLAGE_CHANCE — to make them common near spawn, relax
the site gate, not just the chance. Superseded plan note below (was "full web build + CS_FLAGS += FP_STRUCT_GEN"):
[SUPERSEDED] P1c IN PROGRESS: full web build (patch 0013 → web templates) + deploy_cheats CS_FLAGS += FP_STRUCT_GEN
(FP_STRUCT_DETECT/FAR/NEAR_GUARD/BIOME_SPACE_FIX/CLIMATE_BIOMES/OBJ_LOD_DEBRIS already there) + live A/B. LESSON: run
verify_cppgen under the FACETED toggle (not just FLAT) for any C++-gen mirror — the pre-existing faceted divergence + the
moon-id alias only show FACETED; salts 201-209; GDScript is frozen truth, fix the C++. NOTE FP_STRUCT_DETECT/FAR/NEAR_GUARD already live-true in the served build (so the far-render
pipeline is already active for player builds). Also enable FP_OBJ_LOD_DEBRIS in the P1c deploy (user: billboard card
far-render of detached voxel objects is "good enough for now"; note canopies are sub-pixel so villages are the real
eyeball target). Eyeball plan (P1c): dev-nav/walk to a village (enter house, no fall-through, break wall→roof collapse)
+ fly to orbit (far decimated village models). LESSON: the C++/GDScript worldgen interlock (FP_CPPGEN live) means any
worldgen-adding feature needs the C++ mirror + rebuild before its flag can flip, or physics↔render diverge (fall-through).

CARVE-TO-MIN LEVELING BUILT + BYTE-EQUAL 2026-08-19 (branch feat/voxiverse-struct-gen, commits 5f136f6 leveling +
b2b8421 re-apply VILLAGE_CHANCE 0.5). User: "just level the whole area where the village to be placed" (blend-into-
terrain algos are a LATER followup). Design (height-budget-safe): base_y = MIN of 4 footprint-corner column_tops (was
MAX) ⇒ CARVE-ONLY, never fill above natural g (filling up would blow max_above=14 → clipped roofs/fall-through). Dropped
the flatness SITE gate; added STRUCT_LEVEL_TOL=16 cliff guard (footprint variation >16 → skip). NEW hot-path consult: the
old claim consults were airspace-only (y>g); carving removes terrain at y<=g, so added an FP_STRUCT_GEN-gated
StructureGen.claim_at consult in the SOLID path of resolve_cell (tc:~1471) AND resolve_cell_core (patch 0013) — cl>=0→
return cl (0=carved AIR override). claim_at early-out changed y<=cg→-1 to cg-y>STRUCT_LEVEL_TOL→-1 (bounds carve depth+
perf band). Gates: FLAT 6042/0; verify_structures 61/0 (new G-SG-LEVEL carve-fires, rewritten G-SG-ENV/SITE/PHYS floor@
base_y+1); G-SG-CPP village byte-equal **0/1535** (883 solid house cells) under FACETED+STRUCT_GEN+CLIMATE+BIOME_SPACE_FIX.
The 2 OTHER verify_cppgen FACETED fails (G-CG-COLUMNS 3252 colours + G-CG-CELLCOVER sea-fill-0) are IDENTICAL with
FP_STRUCT_GEN on AND off ⇒ pre-existing faceted C++↔GD divergence, NOT from leveling. FINDABILITY (warmed-atlas scan, the
UNWARMED scan lied 0/300): villages are COMMON — 27365 houses across 1589 of 3456 Earth facets; spawn=facet 2 (lat -37.28
lon -35.65); NEAREST village ON the spawn facet, bmin=(-24570,7,-31314) ≈ ~180 BLOCKS from spawn col (-24750,-31281), lat
-35.66 lon -35.32 (great-circle "183km" is bogus 6371km scaling; in-block it's ~180 blocks = short walk). So leveling +
0.5 density puts a walkable village at spawn; NO need to drop the biome gate. DEPLOY GOTCHA: web RENDER uses the C++
generator (FP_CPPGEN on, module_in_web=yes) so the web TEMPLATES must be rebuilt with the leveled patch 0013 (full
scripts/build.sh, SKIP_LINUX=1 ok since editor already has 0013) BEFORE deploy_cheats.sh (export --no-build) — else C++
render (un-leveled) diverges from GDScript physics (leveled). Teleport-to-village: relay `teleport {lat_deg,lon_deg,alt}`;
compute a village's lat/lon via FacetAtlas.lattice_to_world64(fid,x,y,z)→normalize→asin(y)/atan2(z,x).

P2 FP_STRUCT_LOD BUILT 2026-08-19 (commit fa2f8a2, branch feat/voxiverse-struct-gen) — "villages visible from orbit".
ROOT of the user's "village won't render from orbit": (1) DOMINANT = a ~10-block house is sub-pixel from orbit (10/1500
blocks <1px) — geometry, not a bug; the far-structure tier (FacetFarStructures/FP_STRUCT_FAR) IS wired+enabled+working
(confirmed decimated village cluster visible live at alt 708 LOW_ORBIT); (2) per-house LOD-A culls beyond STRUCT_FAR_MAX
2400 (vanished at alt 4000 dev-fly = dist>2400, NOT the offsurf suspend). shell_offsurface()=_cam_set and h>=OFFSURFACE_Y
(256) — but _cam_set is the ORBITAL-SHELL camera, FALSE in dev-fly PLANETARY/LOW_ORBIT (per-house rendered at 708 ⇒ offsurf
false there). LESSON: don't gate an orbit tier on shell_offsurface — dev-fly never trips it; gate on DISTANCE. Fix = P2
aggregate LOD-B (pure GDScript render in facet_far_structures.gd, NO worldgen/C++/rebuild): GEN houses group by their
STRUCT_V(192) village cell (vkey derived from record bbox — make_record UNTOUCHED, cleaner byte-off), player builds each
their own aggregate; a settlement whose union-bbox max-extent ≥ STRUCT_ORBIT_MIN(48) emits ONE coarse roof-brown box
(12 tris) via a SECOND MeshInstance _mi_agg (the §7.4 LOD-A+LOD-B two-draw), beacon-floored (ObjectLod.proj_px + scale-to
STRUCT_LOD_BEACON_PX=3px so a distant settlement never vanishes). Disjoint handoff: per-house owns [R0,2400] on-surface;
aggregate emits only dist>STRUCT_FAR_MAX OR offsurf ⇒ no double-render, works in BOTH dev-fly + shell regimes. _mi_agg
created ONLY under FP_STRUCT_LOD ⇒ flag-off the offsurface `return` is byte-identical. Gates: G-SG-LOD (group/extent/
player/beacon/off) verify_structures 66/0, FLAT 6042/0. DEPLOYED live w/ FP_STRUCT_LOD in CS_FLAGS (last-mod 07:38 GMT).
Camera kpx via (_ring).get_viewport().get_camera_3d()+visible_rect (the FacetFarObjects plumbing).
LIVE-VERIFIED 2026-08-19: at alt 1800/4500 LOW_ORBIT (villages INVISIBLE pre-P2 at alt 4000) villages now render as
tan-brown settlement blobs scattered across the planet. BUG FOUND+FIXED live: boxes first rendered PURE BLACK — root =
the aggregate reused the per-house voxi_shade _material whose planet_centre radial normal is UNRELIABLE in the orbital-
shell frame (a path the on-surface-only P0 per-house tier NEVER exercised → shaded to night-floor black). Fix = give the
aggregate its OWN UNLIT vertex-colour material (_make_agg_material: shader_type spatial; render_mode unshaded,cull_disabled;
ALBEDO=COLOR.rgb), colour Color(0.45,0.32,0.20). LESSON: don't reuse the radial-lit far material for an orbit tier the
suspended-on-surface tiers never ran — unlit is frame-independent. NOTE offsurf(shell_offsurface) IS true at alt≥~1500
LOW_ORBIT (shell cam engages there; per-house suspends) — so the aggregate carries the whole LOW_ORBIT view. POLISH TODO:
(a) unlit ⇒ no night-side darkening (markers glow on the night hemisphere); (b) villages dense from orbit (VILLAGE_CHANCE
0.5); (c) §7.4a roof-texel-in-fine-map deferred. SEPARATE ARTIFACT: the black blob tracking the camera in orbit shots is
the FP_OBJ_LOD_SPACE dev CLASS_SPACE test object (world_manager _maybe_spawn_dev_space_object) — NOT a village; drop
FP_OBJ_LOD_SPACE from the deploy CS_FLAGS to remove it. Branch feat/voxiverse-struct-gen NOT yet merged to main (holding
for user's call after the orbit eyeball).

P2 PIVOT 2026-08-19 (USER REDIRECT): the single box per village was REJECTED — "villages from orbit must look like a set
of DISTINCT real buildings, not a single square. Wherever we render trees, render houses (exactly same mode: billboard OR
terrain-color pixels depending on distance)." So: (a) dropped FP_OBJ_LOD_SPACE from the deploy CS_FLAGS (removes the dev
CLASS_SPACE black test-blob — NOT a village); (b) REVERTED the aggregate box (commit 6b7d330, facet_far_structures back to
P0); (c) REPURPOSED FP_STRUCT_LOD to the FAR-SKIN ROOF-PIXELS path (§7.4a) — houses composite their roof colour into the
fine-map far skin EXACTLY like tree canopy, so from orbit a village reads as a cluster of distinct roof-colour terrain
pixels across the WHOLE planet (the existing per-house decimated LOD-A mesh already gives distinct 3D houses at mid-range
[128,2400] — together that's the full tree-parity ladder, no separate card tier needed). Impl (commit 7d3ae73, agent
a85eb56): StructureGen.top_decoration(x,z,pcache) = pure analogue of TreeGen.top_decoration (has_village+house_info early-
out ~1 hash, else column_top top-down scan g+1..g+STRUCT_H_MAX+STRUCT_FLAT_TOL calling claim_at, first >0 = roof; 0 carved-
air is NOT decoration). Consulted at the 3 facet_tex_baker.gd TreeGen.top_decoration sites (~1383/2080/2106) precedence
EDIT>HOUSE>TREE>terrain, each `if <unset> and FP_STRUCT_LOD:` (short-circuit ⇒ byte-off). C++ mirror in patch 0013:
struct_top_decoration (line-for-line port) + a struct branch in bake_far_tile between edit+tree branches gated p.struct_lod
(passthrough "struct_lod" in terrain_config material_tables ~:549). Cell math hx=floori(x/STRUCT_HCELL), village vx=
floori(x/STRUCT_V); STRUCT_V=STRUCT_HPV*STRUCT_HCELL=6*32 ⇒ floor(floor(x/32)/6)=floor(x/192) so the early-out matches
claim_at ordering. GATES: FLAT 6042/0, verify_structures 66/0 (new G-SG-SKIN), verify_cppgen G-SG-SKIN-CPP **0/590 roof-
pixel columns byte-equal** (262 solid roof-pixels; C++ struct_top_decoration==GDScript) + G-SG-CPP still 0/1535 (the 2
other faceted fails G-CG-COLUMNS 3252 + sea-fill-0 are pre-existing, flag-independent). Editor rebuilt (15s), FULL WEB
BUILD in progress → deploy w/ FP_STRUCT_LOD in CS_FLAGS → live orbit A/B. NOTE the live skin bake is C++ (FP_CPP_TILE_BAKE)
so this needed the patch+rebuild (unlike the GDScript-only box).

FAR-SKIN ROOF DEPLOYED 2026-08-21 (commit 7d3ae73 skin + 714c57a colour-fix) + LIVE BLACK-BLOB BUG FOUND+FIXED. Live orbit
A/B (alt 900-2200 over the village): the aggregate box is GONE (good), houses DO render in the skin — BUT the village
showed as a SOLID BLACK BLOB. Misdiagnosis trap: first thought it was a camera-locked object or nadir artifact (tilting UP
made it vanish — but that just pushed the below-player point off the frame BOTTOM; flawed discriminator). ROOT CAUSE (probe
of FarPalette): StructureGen.top_decoration returns the ROOF = dark_oak_log (id 58) for most house columns, and dark_oak_
log's NEAREST frozen-palette swatch (14-colour palette, nearest-RGB in ensure_far_index_ready) is index 7 = (0.23,0.23,
0.24) — a near-black GREY (palette[8]=(0.48,0.33,0.19) brown is the right hue but farther in Euclidean RGB: 0.085 vs 0.025).
So a dense village's roof-pixels ALL mapped to near-black ⇒ black smudge from orbit. NOT a mesh, NOT the box, NOT a nadir
hole — the houses ARE in the skin, just coloured black. FIX (714c57a, GDScript-only NO rebuild): in FarPalette.ensure_far_
index_ready, after building _block_idx, `if CubeSphere.FP_STRUCT_LOD: _block_idx[dark_oak_log] = 8` (warm brown). The
deco_far_idx LUT is handed FROZEN to the C++ bake at runtime (config "deco_far_idx"), so this ONE LUT override fixes BOTH
the GDScript baker AND the C++ bake_far_tile house branch — no rebuild. Byte-off: gated on the flag ⇒ FLAT 6042/0 (LUT
unchanged flag-off); flag-on dark_oak_log far_idx=8 confirmed. LESSON: the byte-equal gate (G-SG-SKIN-CPP) proves the
top_decoration BLOCK-ID is byte-equal but NOT the id→far-palette-colour step — a block whose nearest-palette swatch is
near-black renders as a black hole; always probe far_color_index_of_block for new decoration materials. LIVE re-verify
PENDING (reload+re-arm). USER pref: villages from orbit = distinct buildings/roof-pixels (the per-house skin pixels), never
one merged square.


MERGED TO MAIN 2026-08-21: PR #77 (merge commit 818657a) — village generator + far-render (leveling, orbit roof-pixels, LOD, seam, shade) all shipped to origin/main. Branch feat/voxiverse-struct-gen (13 commits: e3a634c..b2cec50). All byte-off (FLAT 6042/0), C++ byte-equal proven (G-SG-CPP 0/1535, G-SG-SKIN-CPP 0/590, G-SSP 0/38400), live-verified. patches 0013 (village mirror) + 0014 (skin-shade-pack) now in the engine build.