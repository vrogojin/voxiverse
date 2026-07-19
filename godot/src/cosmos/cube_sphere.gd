extends RefCounted
class_name CubeSphere
## COSMOS M0 — the cube-sphere math kernel (docs/COSMOS-PLANET-TOPOLOGY.md §1.2, §1.3,
## §4.2, §5.2/§5.3). Pure, deterministic f64 scalar math. NO engine dependencies, NO
## `randi()`/`Time` — every function is a pure function of its arguments.
##
## PRECISION NOTE (the load-bearing constraint): GDScript `float` is IEEE-754 f64 but
## `Vector3` is f32. Using `Vector3` for the direction math would FAIL the exact
## `cell -> dir -> cell` round-trip gate (§9 M0). All direction math therefore runs on the
## `DVec3` inner class below (three f64 fields) — NEVER `Vector3`. GDScript ints are 64-bit,
## so the 43-bit global edit key (§1.3) fits with room to spare.
##
## The two normative functions (§1.2) are `face_cell_to_dir` and `dir_to_face_cell`; the
## equal-angle warp is isolated behind `warp()`/`unwarp()` so a later distortion-tuning pass
## can swap it without touching topology, remap tables, or persistence (§1.2, §11.1).

# ---------------------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------------------

const QUARTER_PI := PI / 4.0

## The persistence region grid tiles each face 32^3 (ZoneChunk.SIZE); N is a multiple of 32
## so no region ever straddles a face (§1.1, §8.2).
const REGION_SIZE := 32

## Corner-zone constants (§5.3) — carried here so later milestones (M5) read them from the
## single kernel source. `CORNER_SEA_R`: worldgen forces deep ocean within this many cells of
## a cube corner; `CORNER_LOCK_R`: edits are refused within this many cells of a corner column.
const CORNER_SEA_R := 48
const CORNER_LOCK_R := 8

## COSMOS M5c (docs/COSMOS-M5C-CORNER.md §9) — the walkable-land-corner seal: bedrock pillar + anomaly
## teleport. All gated behind M5C_CORNER (default OFF → shipped build byte-identical). M5C_TELEPORT=false
## degrades §5's bisector teleport to §8's solid energy barrier over the same cylinder. CORNER_ZONE_R /
## FLIP_HYST_CORNER are the eager-flip zone/hysteresis (corrected from the ADR's 32/8 — see the doc §7/§13);
## PILLAR_R_CELLS / PILLAR_TOP_UP size the bedrock monument.
## COSMOS FP0 (docs/COSMOS-FACETED-PLANET-STUDY.md §11) — the faceted-planet VISUAL SPIKE. When true, main.gd
## builds a static demo faceted planet (flat square facets meeting at dihedral ridges, real terrain colours,
## free-fly camera) INSTEAD of the normal world, so the faceted look can be judged live. Default OFF.
const FACETED_SPIKE := false
## COSMOS FACETED (docs/COSMOS-FACETED-IMPL.md §1.1) — the PLAYABLE faceted engine master toggle. When true the
## world is ONE flat voxel facet (FacetAtlas) carrying the sphere terrain, played with the flat engine wholesale
## (gravity −Y local, break/place/collapse). REQUIRES FLAT_WORLD=true (a facet IS a flat world). All faceted
## worldgen is gated behind this, so default OFF → the shipped build is byte-identical (FLAT gate 6027/0). FP1
## renders the single home facet; FP2+ add the neighbour ring + walkable junction blocks.
const FACETED := false
## COSMOS FACETED (§5) — the 8 grid-twist singularities (cube-vertex facets where the lattice cannot align). FP5.
const FACET_TWIST := false
## COSMOS FP-R0 (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §8) — the multi-facet rotation kill-shot SPIKE. When
## true it unlocks module_world's spike_* methods (a rotated neighbour VoxelTerrain + a LOD-stride probe) used
## ONLY by verify_fp_r0. Default OFF → shipped build byte-identical (the spike methods no-op, the generator's
## lod>0 stride stays disabled). Requires FACETED = true. Never ship this on.
const FP_R0 := false

## COSMOS FP-M1c (docs/COSMOS-FP-M1-DESIGN.md §3–§5) — the Planet Assembly master toggle. When true the faceted
## world runs the POOLED rotated-neighbour terrains under a PlanetRoot (≥2 facets rendering real voxels at a
## ridge) and crossings become sub-frame RE-DESIGNATION (root-transform swap + view rebalance, NO teardown/
## restream). Exactly ONE global player VoxelViewer serves every facet terrain (the spike's per-neighbour static
## viewers are BANNED, §2); every pool terrain is `bounds`-clamped to its own facet slab (§3.2). Requires
## FACETED = true. Default OFF → faceted behaves as FP-S1 (single active terrain + far-ring quads + set_facet
## teardown crossing); with FACETED also off, FLAT is byte-identical (6027/0). Flipped ON at export after the A/B.
const FP_M1_POOL := false
## FP-M1c pool policy (§4.3) + memory ledger (§10). Consts so the gate can assert the caps (never-OOM: the pool
## has a geometric ceiling independent of viewer behaviour). D_WARM: spawn a neighbour when the player's own-side
## ridge distance drops below this. D_RETIRE: free it once past this (32-block hysteresis ≫ jitter). MIN_LIVE_S:
## minimum lifetime before a retire (anti-thrash at the D_WARM shell). MAX_NEIGHBOURS: hard cap (geometry wants
## ≤3 concurrently; 4 is slack + LRU backstop). SPAWN_INTERVAL_S: ≤1 spawn AND ≤1 retire per second (amortized).
## MEM_BUDGET_MB: pool worst-case ceiling (1×40 + 4×20 = 120 ⇒ 128). SINGULAR_EXCLUDE: cells near a cube-vertex
## singularity kept single-plane (excluded from the two-live-facet complementarity assert, §8).
const POOL_D_WARM := 96.0
const POOL_D_RETIRE := 128.0
const POOL_MIN_LIVE_S := 10.0
const POOL_MAX_NEIGHBOURS := 4
const POOL_SPAWN_INTERVAL_S := 1.0
const POOL_MEM_BUDGET_MB := 128
const POOL_SINGULAR_EXCLUDE := 4

## COSMOS FP-M2d (docs/COSMOS-FP-M2-DESIGN.md §3.2 / §9) — the Z1-hybrid pool-policy consts (beside the POOL_* family,
## §3.2). CONSULTED ONLY under FP_M2_LOD; with the flag off the pool reverts to the shipped FP-M1c policy verbatim
## (POOL_MAX_NEIGHBOURS = 4 stays the hard backstop, asserted by G-M1-POOL). D_WARM2: a SECOND live neighbour spawns
## only when a 2nd ridge is within this (the corner approach; mid-edge it never fires). FP2_LIVE_CAP: the effective
## live-neighbour cap (1 imminent + 1 corner-second) — the throughput win (worst pool volume 2.1V → 1.56V). SWITCH_MARGIN:
## an incumbent imminent neighbour is displaced only when a challenger's ridge distance beats it by this (anti-thrash on
## a diagonal-walk sweep). PROMOTE_EVICT_MAX_S / DEMOTE_RETIRE_MAX_S: hard lifetime caps on the promote/demote overlap
## windows (§9.1/§9.2) — never let a laggard mesh/terrain pin double geometry (NEVER-OOM outranks the pop).
const POOL_D_WARM2 := 48.0
const FP2_LIVE_CAP := 2
const POOL_SWITCH_MARGIN := 16.0
const PROMOTE_EVICT_MAX_S := 20.0
const DEMOTE_RETIRE_MAX_S := 20.0
## W10 — while the load controller is STARVING the stream (vox_gen backlog-gated), the promoting terrain's seam band
## may not mesh within PROMOTE_EVICT_MAX_S; dropping the held LOD cover then would open a real see-through hole over
## un-meshed live terrain. So the promote-evict timeout is EXTENDED by this factor while backlog-gated (the hard-cap
## escape stays — it just becomes much longer under starvation, never infinite).
const PROMOTE_EVICT_STARVE_MULT := 6.0

## COSMOS FP-M2 (docs/COSMOS-FP-M2-DESIGN.md §0.8) — the LOD-mesh-neighbours master toggle. When true (AND
## FACETED AND FP_M1_POOL AND the module binary present) non-imminent facets stop being live full-res
## VoxelTerrains and become screen-space-error-selected blocky meshes built entirely OFF the voxel worker pool
## (FacetLodMesher), cutting the generation-throughput ceiling. FP-M2a (this stage) ships ONLY the off-terrain
## build primitive + the LOD0 byte-identity gate as DEAD CODE behind this flag — no scene consumer yet. Default
## OFF → the faceted world is byte-identical to FP-M1c; FLAT stays 6027/0. Flipped ON at export after the
## FP-M2e browser-heap A/B (the established sed-at-export deploy pattern). Requires FP_M1_POOL = true.
const FP_M2_LOD := false

## COSMOS GEN-EFFICIENCY (docs/COSMOS-GEN-EFFICIENCY-DESIGN.md §1 Fix A) — bulk-fill invisible underground blocks.
## Underground `resolve_cell` is ~76% of a land column's generation cost (~84 unseen cells × 2.9 µs); a fully-
## underground 16³ data block runs 4096 resolve_cell calls (~13.7 ms), and a crossing restreams ~500 of them →
## the multi-second freeze + fall-through. When true, a data block whose ENTIRE y-range is provably interior
## stone/deepslate (below every column's dirt/biome filler, above bedrock, clear of the -24..-16 deepslate dither
## band, and — on a facet — fully interior to all four ridges) is filled with ONE material via VoxelBuffer.fill
## instead of the per-cell pass (~27× on that block). NOT byte-identical: the block's ore/strata VARIANTS become
## uniform stone/deepslate — the ACCEPTED, near-invisible loss (unseen until dug; WM.block_id_at → resolve_cell
## reads TerrainConfig directly, never this buffer, so physics + the broken/dropped block stay ground-truth).
## Ships A-accept (uniform-stone walls on exposure; the appearance-only loss), with A-lazy exposure regen a
## documented follow-up. Default OFF → the generator is per-cell, byte-identical (FLAT verify pin 6035/0 stays,
## G-M2-ID stays module==module). LOD0 only. Independent of FACETED; the ridge guard self-disables when flat.
const FP_BULK_UNDERGROUND := false

## COSMOS STREAM-SCHED R1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.3-§2.4 / §9.2) — COLUMN-granular bulk fill.
## FP_BULK_UNDERGROUND above qualifies on the WHOLE BOX (by_top <= min_h − 12), so every block under ROUGH
## terrain fails its min_h gate and pays the full 4096-cell per-cell pass (~13.7 ms native, ~10× on web) —
## §2.3 measures that gate-failed class as the largest recoverable term left in the generator. R1 moves the
## same gate INSIDE the emit loop, per column: each column's provably-deep run (below its OWN g − 12) is
## fill_area'd with stone/deepslate, its exact band (g−12 .. surface) stays per-cell and BYTE-EXACT, and the
## air above its content ceiling is skipped (R1b). slope_run_of is computed only for columns that still need
## a resolve_cell. Same appearance class as FP_BULK_UNDERGROUND — and no wider: the loss stays the interior
## ore/strata VARIANTS of cells >12 deep (invisible until dug; block_id_at → resolve_cell reads TerrainConfig,
## never this buffer, so physics + the dropped block stay ground truth). The −24..−16 deepslate dither rows and
## any row below −59 (bedrock) stay PER-CELL, so no dithered/bedrock cell is ever guessed.
## Independent of FP_BULK_UNDERGROUND (both may run; the whole-block fill wins when it qualifies). LOD0 + flat
## branch only. FACETED: v1 applies column bulk only when the WHOLE block is interior to all four ridges
## (the same cell_interior_scaled gate the whole-block fill uses) — ridge straddlers stay fully per-cell.
## Default OFF → the emit loop is textually the shipped per-cell path (FLAT verify pin 6035/0 stays).
## Truth gate: src/tools/verify_colbulk.gd (run with this flag sed-toggled true).
## NOTE (shared with FP_BULK_UNDERGROUND): both gates assume nothing but stone/deepslate/strata/ore exists
## below a column's biome filler. Any FUTURE deep carver (caves, dungeons) must update BOTH gates together.
const FP_COLBULK := false

## COSMOS STREAM-SCHED R7 (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.5 / §9.6) — the gather→scatter inversion
## that makes FP_COLBULK's bulk fill LOSSLESS. FP_COLBULK's deep fill_area writes plain stone/deepslate,
## flattening the interior strata/ore VARIANTS — an accepted loss, but one that costs it the FLAT gate
## (verify_feature's coast/TYPE tests are strict truth-mirrors of TerrainConfig.generated_cell over EVERY
## non-air cell, so any bulk fill fails them by construction). R7 puts the variants back: instead of asking
## all 4096 cells "is a blob here?" (the GATHER), it enumerates the handful of blobs that can reach the
## block and stamps them (the SCATTER). Exact and local because a blob is confined to its lattice cell
## (see TerrainConfig.strata_blob), so the only blobs that can touch a block live in the lattice cells
## overlapping it — 1-8 strata cells (16³ pitch) and ~27-64 ore cells (6³ pitch, ~45% populated).
## The output is byte-identical to the per-cell path BY SHARED CONSTRUCTION: both paths derive every blob
## parameter from the same TerrainConfig statics (strata_blob / strata_variant_of / ore_blob /
## ore_pick_for / ore_apply / deep_family_at), so they cannot drift. With FP_COLBULK + FP_STAMP the
## generator is EXACT — no appearance loss and no gate carve-out (FLAT reads 6035/0).
## Requires FP_COLBULK (it stamps that flag's deep runs, and only the cells those runs actually wrote —
## the −24..−16 dither rows and the sub-−59 bedrock rows are per-cell already and are never stamped).
## Does NOT cover FP_BULK_UNDERGROUND's whole-block fill, which returns before the stamp pass and keeps
## its own accepted loss. Default OFF → not a byte of the generator changes (FLAT pin 6035/0 stays).
## Truth gate: src/tools/verify_stamp.gd — a HARD cell-for-cell equality assert (fill+stamp == per-cell)
## over blocks spanning surface/deep/coast/mountain/deepslate-band/bedrock, not a lossy-appearance oracle.
const FP_STAMP := false

## COSMOS L5(a) — THE C++ WORLDGEN PORT (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.6). When true (AND the patched
## module binary is present — ClassDB.class_exists("VoxelGeneratorCosmos")), module_world installs the compiled
## VoxelGeneratorCosmos (engine patch 0007) instead of the runtime-compiled GDScript generator.
##
## WHY: measured live 2026-07-17, 97% of ALL block-generation time sits in two per-cell classes that are
## INTERPRETER-bound, not algorithm-bound — underground gate-failed 337.7 ms/block and surface-crossing
## 559.8 ms/block, against a 13.7 ms native twin (a ~×25 WASM/GDScript multiplier, not the ×10 long assumed).
## Supply 23-35 blocks/s vs walking demand ~90-100 blocks/s: supply < demand ALWAYS, and that gap IS the
## freezes. Every script-side lever was built and measured out — R1 column-bulk + R7 blob-stamp are CORRECT
## and byte-identical yet moved M4 only −13% (the profile pass and loop mechanics still carry the full VM
## tax). No script-side transformation removes a multiplier; only compilation does.
##
## THE ONE-SAMPLER LAW (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §7.1) — the architectural constraint, and NOT
## the "C++ renders, GDScript answers queries" split it is tempting to assume. That split would institutionalise
## a BIFURCATION: C++ for voxel workers while analytic physics (block_id_at → resolve_cell), the skin tier, the
## far ring (facet_far_ring.gd:390,434) and the LOD builder keep calling GDScript. Two implementations of
## resolve_cell/column_profile maintained in parallel WILL drift, and a drift between the physics oracle and the
## rendered mesh is WORSE than a seam — it is the float-through/fall-through class this project already fought.
## So VoxelGeneratorCosmos is THE worldgen implementation and must be able to serve the query path too (§7.2
## exposes sample_columns + scalar column_profile/resolve_cell for exactly that); the GDScript twin is retained
## permanently as the byte-equality ORACLE, never as a live second path. Today the law holds because everything
## funnels through TerrainConfig.profile_at_dir/facet_profile/resolve_cell — the port must INHERIT that choke
## point, not break it. Byte-equality is therefore the whole argument that every tier and the physics oracle
## agree. Default OFF → the C++ class is never instantiated → the GDScript generator is untouched, FLAT 6035/0.
## Truth gate: src/tools/verify_cppgen.gd — an N-block cell-for-cell equality assert (C++ buffer == GDScript
## buffer) over blocks spanning biomes, depth bands, ridges/seams, coasts/liquid and tree stencils. The gate is
## the oracle: it is proven able to FAIL (a deliberately perturbed C++ path must be caught) and is never
## weakened to make the port pass.
const FP_CPPGEN := false

## COSMOS CLIMATE-BIOMES B1 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §6/§7) — the Whittaker temperature×moisture
## biome classifier. When true, TerrainConfig._biome swaps its shipped first-match chain for a
## temperature-band × humidity-band table that appends B_SAVANNA / B_JUNGLE, TreeGen grows acacia (savanna),
## jungle (jungle) and cactus (desert) species, and FarPalette shows tan/green savanna/jungle bands from orbit.
## Biome is a PURE function of position (+ static latitude/humidity proxy) — zero per-voxel storage, no RNG, no
## climate-sim dependency (it reads only worldgen noise, exactly like today). This is a NEW-WORLD look change:
## default OFF → _biome runs the shipped chain verbatim, TreeGen never plants the new species, and the world is
## BYTE-IDENTICAL (FLAT 6035/0 + the terrain hash unchanged — the compatibility proof). Independent of the W*
## weather flags (biomes never read the sim). Gates: src/tools/verify_climate.gd (band ordering, determinism,
## byte-identical OFF, new-species determinism, palette bands).
const FP_CLIMATE_BIOMES := false

## COSMOS FP-NEIGHBOUR-SEAM-POLISH (docs/COSMOS-FP-M2-DESIGN.md §7.6) — polish the ACTIVE↔LOD seam LOOK so the
## LOD neighbour blocks coincide with the live full-res facet at the shared ridge (the user's "ugly seam"
## complaint). Two in-budget, off-pool (builder-thread) moves, BOTH inside the LOD memory ledger (LOD_MAX_BYTES_MB
## = 96, NOT the 128 MB vox pool): (A1) a PLANE-CLAMPED ridge apron on the live↔LOD seam — the owner-side HALF of
## the normal LOD↔LOD apron, so it fills the LOD-side eroded shelf but STOPS at the welded ridge plane and can never
## protrude into / z-fight the live facet; (A2) the active facet's ≤4 near edge-neighbours are pinned to ℓ1 (2-block
## megablocks) + spared from pressure-demotion, so the ridges the player looks across are never coarse ℓ2-3. DEAD
## unless FP_M2_LOD (the mesher never exists otherwise) → byte-identical with the faceted flags off. Default true:
## it is pure LOD-side polish already bounded by the NEVER-OOM caps, so it rides on whenever the LOD path is live.
const FP_NEIGHBOUR_SEAM_POLISH := true

## COSMOS RENDER-SIMPLIFY (docs/COSMOS-RENDER-SIMPLIFY-DESIGN.md §1/§2) — REMOVE the intermediate near-neighbour LOD.
## When true (AND FACETED AND FP_M1_POOL), the whole FacetLodMesher stack is bypassed: the mesher is never created
## (_lod_setup returns early → _lod_mesher stays null → its builder Thread never starts and the 96 MB LOD ledger never
## allocates), the promote-hold / _lod_promote_pass / demote-relief / apron paths self-disable, and the FacetFarRing
## exclusion set shrinks to live-pool-neighbours-only so every ex-LOD facet shows its far-ring quad instead (§2.5 — the
## far ring already renders behind everything, so removing the LOD opens NO horizon gap). This is the logical INVERSE of
## FP_M2_LOD (they are mutually exclusive): every FP_M2_LOD *creation/policy* read routes through _near_lod_on() =
## FP_M2_LOD and not FP_NO_NEAR_LOD, so with this flag off _near_lod_on() == FP_M2_LOD exactly (byte-identical; the
## passive lod_* generator/terrain accessors stay on raw FP_M2_LOD — only consumed by a mesher that no longer exists).
## Memory-SAFE on its own (only FREES the 96 MB LOD ledger). Default OFF → byte-identical; FLAT stays 6035/0. Flipped ON
## at export after the browser-heap A/B (the established sed-at-export pattern). Requires FP_M1_POOL = true.
const FP_NO_NEAR_LOD := false

## COSMOS RENDER-SIMPLIFY (docs/COSMOS-RENDER-SIMPLIFY-DESIGN.md §1/§3) — widen the near render radius 128 → 256 and
## ridge-band + rescale the neighbour pool into the envelope the LOD removal frees. This is the memory-RISKY half (it
## SPENDS the 96 MB FP_NO_NEAR_LOD reclaims) and is gated + A/B'd INDEPENDENTLY of the removal (§1: bundling them would
## make a memory regression indistinguishable from a seam regression). Consulted only via near_render_radius() (the single
## widening lever) + the pool rescale/ceiling; requires FP_NO_NEAR_LOD. THIS PASS wires only the flag + the flag-aware
## near_render_radius() scaffold — the ridge-band, pool-ceiling raise (224 MB) and real-bytes ceiling are a later pass
## (design §3-§4, Steps 3-5). Default OFF → near_render_radius() stays the shipped faceted 128 → byte-identical.
const FP_FULLRES_256 := false

## COSMOS-ATLAS (docs/COSMOS-ATLAS-DESIGN.md, Perf L3) — collapse the OPAQUE terrain onto ONE shared atlas material.
## Every block id today carries its OWN StandardMaterial3D (block_materials.gd), and VoxelMesherBlocky emits ONE
## surface (= one draw call) per distinct material per 32³ mesh block, so materials MULTIPLY the draw count
## (~90 surface blocks × ~2.1 materials/block ≈ 190 of the ~204 measured draws → the GL-compatibility per-draw
## ceiling that caps walking at ~30 fps). When true (STAGE 1), the 67 OPAQUE VoxelBlockyModelCube models
## (_configure_library → _add_cube) are packed into ONE 8×8×128px = 1024² atlas behind ONE shared opaque
## StandardMaterial3D (BlockAtlas): per-face set_tile() picks the id's atlas cell instead of a per-id
## set_material_override, so the mesher MERGES all opaque cubes in a block into one surface (draws 204 → ~130-150;
## shaped/snow/slope/carve models + the translucent glass/ice + emissive lava stay per-material — STAGE 2+). The
## cube ARID == LRID invariant is UNTOUCHED (only material + UVs change, never the model index / TYPE channel), so
## G-M2-ID stays green. Default OFF → the shipped per-id-material path, byte-identical (FLAT verify pin 6035/0
## stays; the atlas is never built). Flipped ON at export after the browser-heap + visual A/B (the established
## sed-at-export deploy pattern). Independent of FACETED (the module library build is the same both ways).
const FP_ATLAS_MATERIAL := false

## COSMOS-PERF STEP 1 / L1 (docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md §3.1) — the far-ring FAST packed-array rebuild.
## FacetFarRing._rebuild_full() re-emits ~1728 front-hemisphere facets every crossing AND every neighbour-pool change
## via ~332k per-vertex SurfaceTool add_vertex/set_color GDScript→C++ round-trips + generate_normals() over ~55k tris —
## ~300–700 ms on ONE main-thread frame (the dominant post-crossing spike). When true, _rebuild_full assembles the
## mesh from PRE-TRIANGULATED per-facet pos/col caches (built once per facet) via append_array (C++ memcpy) into two big
## PackedArrays + ONE add_surface_from_arrays, then computes normals with SurfaceTool.create_from + generate_normals —
## both C++, so NONE of the per-vertex GDScript emission remains. VISUALLY EQUIVALENT: the fast path expands each cell
## into the SAME triangle order/winding + per-vertex colors as the SurfaceTool path, and its normals are BIT-IDENTICAL
## because create_from replays the identical vertex list into the identical generate_normals — the GLOBAL smoothing
## (which merges vertices across facet SEAMS) is preserved exactly (G-L1-FARRING proves normal/pos/col deviation 0.0).
## Default OFF → the SurfaceTool path, byte-identical mesh. +~5 MB bounded by the front-hemisphere
## facet cache (NEVER-OOM OK; the tri caches are built lazily, only when the fast path or the gate runs). Flipped ON at
## export after the A/B (the established sed-at-export pattern).
const FP_FARRING_FAST_REBUILD := false

## COSMOS-PERF STEP 2 / L1-async (docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md §3.1) — move the far-ring rebuild OFF the
## main thread. Even the fast packed-array assembler still runs synchronously on ONE frame: a headless breakdown of the
## full front-hemisphere rebuild (~1727 facets / ~55k tris) shows the main-thread cost is SPREAD, not one hotspot —
## SurfaceTool assembly + generate_normals + commit dominate, and on the threaded web export (~5-8× the native host)
## that is the residual ~180-227 ms crossing/pool spike. When true, FacetFarRing hands ALL the mesh-DATA work (per-vertex
## assembly + generate_normals + commit_to_arrays — pure CPU, NO RenderingServer) to a WorkerThreadPool task on the
## warmed (read-only) per-facet caches, then swaps the finished ArrayMesh onto the MeshInstance3D on the main thread
## (only the single add_surface_from_arrays / mesh RID create touches RenderingServer — kept on main, ~5 ms native).
## Double-buffered: the previous far ring stays visible until the new mesh is ready, so a crossing/pool change costs the
## main thread only the ~5 ms swap instead of the whole rebuild. VISUALLY IDENTICAL: commit_to_arrays yields the EXACT
## arrays the synchronous path commits (pos/col/normal deviation 0.0 — G-L1-FARRING-ASYNC proves it), so smooth seam
## normals are preserved. Single-flight; a crossing while a build is in flight is honoured after it lands; _exit_tree
## joins any in-flight task. Independent of FP_FARRING_FAST_REBUILD (the worker emits from the grid caches, so the swapped
## mesh is byte-identical to BOTH sync assemblers); needs a multi-core build, else it falls back to the synchronous
## rebuild. Default OFF → the synchronous path, byte-identical (FLAT stays 6035/0).
const FP_FARRING_ASYNC_REBUILD := false

## COSMOS far-ring full coverage (docs/COSMOS-FARRING-COVERAGE-DESIGN.md) — the see-through-gap fix. The shipped far
## ring EXCLUDES the active facet + the live-pool neighbours (`_excluded`), so beyond the ~128-block near-blocky disk on
## those facets there is no far quad at all and the camera sees straight through to the opposite inner side of the globe
## (the annular hole). When true (requires FACETED), the ring draws ALL front-hemisphere facets INCLUDING the active +
## `_excluded` set; those "backstop" facets are emitted sunk radially inward by BACKSTOP_SINK blocks at the denser
## BACKSTOP_CELLS resolution, so the opaque near voxels overdraw them with no z-fight and no poke-through (§2–§3). The
## back-hemisphere cull (BACK_CULL) is UNCHANGED. Default OFF → `_front_visible` excludes active+`_excluded` exactly as
## today, no backstop cache is ever populated, FLAT stays byte-identical (6035/0). Flipped ON at export after the live A/B.
const FP_FARRING_FULL_COVER := false
## Backstop tuning (§3). BACKSTOP_SINK: blocks the backstop facets are pushed radially inward, so they sit strictly
## behind the near blocky surface (clears facet chord sagitta + relief quantization + the residual flank dip). BACKSTOP_CELLS:
## the backstop-facet heightmap resolution (vs the shipped CELLS=4 for non-backstop facets) — denser cells shrink the
## between-sample chord error so a coarse triangle cannot stab up through fine mountain terrain. G-FRC-NOPOKE is the tuning
## oracle: if a mountain-foothill spawn pokes, raise BACKSTOP_CELLS to 32 (cell ≈ 6 blocks) before raising the sink, so the
## boundary step at the near edge stays small (< 0.05° at ≥128 blocks). Consulted ONLY under FP_FARRING_FULL_COVER.
const BACKSTOP_SINK := 6.0
const BACKSTOP_CELLS := 16
## Rescale-safe backstop sink: TierPlace.backstop_sink() derives the radial sink as BACKSTOP_SINK_FRAC × the facet
## cell size (cell = facet_edge/BACKSTOP_CELLS, facet_edge = (π/2·R)/K), so it scales with R and clears the coarse-grid
## facet chord sagitta at any radius (≈6 at R=3072, ≈13 at R=6371). 0.5 reproduces the shipped 6-block sink at R=3072.
const BACKSTOP_SINK_FRAC := 0.5

## COSMOS FS1 (docs/COSMOS-FACET-SEAMS-DESIGN.md §4 / §6) — the SHELL WELD. The shipped far ring builds each facet
## quad by bilerping its OWN planarized corners (facet_planar_corner) then adding radial relief: adjacent facets
## project the shared true edge onto DIFFERENT planes, so their shared-edge chords disagree by up to the ∝R datum
## step (5.30 blocks @ R=6371) — a see-through slit along every seam (RC2a), which generate_normals cannot merge
## (positions never bit-identical) and no skirt covers. When true (requires FACETED), the ring emits every vertex
## RADIALLY from a bilerp of the SHARED cube-sphere corner DIRECTIONS (FacetAtlas.facet_corner_dirs): v = d̂·(R +
## relief(g(d̂))). Two facets sharing a grid edge then compute the SAME edge vertices (same shared corner dirs,
## same t) ⇒ the shell welds and closes (One-Surface Law §0). Mixed tessellation (backstop 16 vs horizon 4) is
## handled by the COARSE-OWNS-EDGE rule: a dense facet's outer-ring vertices are snapped onto the CELLS=4 coarse
## chord (role-agnostic — a 16-facet always meets a 4-chord, so it welds a horizon 4-edge AND a backstop that did
## the same). The current uniform BACKSTOP_SINK is KEPT (§4.3: radial verts sunk ~13 stay under the plane-anchored
## near field, 13 > sagitta 6.8 + chord error — G-SHELL-UNDER holds); FS3 re-derives the sink once the datum fix
## (FS2) removes the sagitta. Zero new memory (same caches, radial VALUES not new counts). Default OFF → the shipped
## planar-corner path verbatim, FLAT byte-identical (6042/0). Flipped ON at export after the live no-see-through pass.
const FP_SHELL_WELD := false

## COSMOS FS2 (docs/COSMOS-FACET-SEAMS-DESIGN.md §3 / §6) — the RADIAL DATUM shift (the seam-step KILL). The near
## field places a column's surface g blocks up from the facet's OWN mean plane along its OWN normal
## (lattice_to_world64's y·n̂ term); adjacent facets' planes sit at DIFFERENT signed distances from the shared true
## edge, so the same g lands at different altitudes — the ∝R datum step (5.30 blocks @ R=6371), the 8-block cliff.
## When true (requires FACETED), each column gains an integer datum shift S = round(solve |p0 + s·n̂| = R) ∈ [0, ~7]
## applied as a PURE RE-INDEX: a cell at lattice y resolves worldgen at true y − S (resolve_cell/worldgen run
## UNCHANGED in true-height space — strata, sea fill, snow, trees all ride S), and every surface funnel returns
## g + S. The placed surface then sits at altitude R + g (a pure function of d̂), so adjacent facets agree to ≤1
## block quantization + ≤0.15 cosine at every seam. S is pure arithmetic over the frozen atlas frame + R — zero new
## persistent memory, worker-safe, C++-mirrorable (VoxelGeneratorCosmos already receives facet_frame/off/r). The
## vertical envelope grows by ≤ DATUM_SHIFT_MAX (worldgen y-bounds get that headroom under the flag). Default OFF ⇒
## S ≡ 0 at every call site (FacetAtlas.datum_shift returns 0), so the world is byte-identical (FLAT 6042/0, G-O4-EQ
## hashes unchanged). Flipped ON at export after the live cliffs-gone pass. Truth gate: verify_facet_datum.gd.
const FP_RADIAL_DATUM := false

## COSMOS TIER-DEPTH-PRIORITY (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.3 / §7 P1) — STICKY / MAKE-BEFORE-BREAK
## roles. Fixes RC-B (the dominant *visible* event): a facet ENTERING the live pool keeps its unsunk CELLS=4
## (50-block-pitch) far quad for the whole deferred-rebuild window (~0.1-1 s) while near meshes are already
## applied on it — a 15-25-block poke-through FLASH on every crossing/pool change near mountains. When true (requires
## FP_FARRING_FULL_COVER), the far ring's backstop role is made STICKY: the set is grown EAGERLY to active ∪ the
## active facet's ring-1 neighbours ∪ recently-active (so a facet is ALREADY drawn sunk BEFORE it enters the pool and
## near meshes arrive — "sink early"), and a facet LEAVING the set keeps its backstop role for STICKY_HOLD more
## role-events ("unsink late") so it never reverts to a coarse unsunk quad while near meshes may still be applied.
## NEVER-OOM: the dense backstop cache grows from ≤ 1+POOL_MAX_NEIGHBOURS (5) to ≤ 1+STICKY_RING1_MAX (12) facets
## ≈ +96 kB — a stated, bounded ceiling (G-TIER-STICKY-BOUND). Default OFF → `_sticky` stays empty, `_is_backstop`
## is the shipped active∪`_excluded`, FLAT stays 6035/0 (byte-identical). Flipped ON at export after the live A/B.
const FP_TIER_STICKY_BACKSTOP := false
const STICKY_HOLD := 2            # role-events an ex-backstop facet stays sunk before it may revert (≥ worst rebuild latency)
const STICKY_RING1_MAX := 12      # hard cap on the sticky backstop set (1 active + ≤8 ring-1 + a few recently-active)

## COSMOS TIER-DEPTH-PRIORITY (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.1 / §7 P2) — the MIN-ENVELOPE vertex rule.
## Fixes RC-A (the steady ~4-block poke at a mountain flank near a facet corner): the constant BACKSTOP_SINK is
## arithmetically insufficient in the tail because the far ring pushes relief along the sphere RADIUS d̂ while the
## near lattice stacks blocks along the facet NORMAL n̂ — a resolution-independent skew of up to ~5-8 blocks that no
## sink/cell tuning removes. When true (requires FP_FARRING_FULL_COVER), each dense backstop vertex's height becomes a
## PROVABLE LOWER ENVELOPE: env(i) = min{ near g over i's dilated 2×2-coarse-cell footprint } − ε, sampled at
## TierPlace.ENV_FINE_MULT × the coarse resolution (the footprint min bounds the interpolation/aliasing/skew terms by
## construction, §5.1). The constant sink then collapses to the small ε guard (TierPlace.backstop_sink()). Zero
## PERSISTENT memory (same 17² grids, different values); +~(ENV_FINE_MULT·CELLS+1)² transient profile samples per facet
## cache build. Applies to BACKSTOP facets (distant CELLS=4 facets are a follow-up). Default OFF → the vertex height is
## the shipped profile_at_dir g and the sink is BACKSTOP_SINK (byte-identical, FLAT 6035/0). Truth gate: verify_tier_depth.gd G-TIER-ENVELOPE.
const FP_TIER_ENVELOPE := false

## COSMOS TIER-DEPTH-PRIORITY (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §5.2 / §3.3 / §7 P3) — per-tier WINDOW-SPACE
## depth bias + a raised camera near plane. Addresses RC-C (24-bit depth precision, latent past ~1 km): a constant
## window-space offset of k depth quanta (POSITION.z += 2k·2⁻²⁴·w) pushes each coarser tier exactly k quanta behind at
## EVERY distance, so coincident surfaces resolve in tier order (blocks > skin > far ring) even where an eye-space sink
## has collapsed into one quantum. When true, the far-ring + skin StandardMaterial3D are replaced by an equivalent LIT
## vertex-colour ShaderMaterial carrying the bias (k = TierPlace.FAR_BIAS_K = 8 far ring, TierPlace.SKIN_BIAS_K = 4 skin;
## near blocks stay UNBIASED/authoritative), and player.gd raises the faceted camera near plane 0.05 → 0.25 (5× depth
## precision for free — precision scales linearly with near). Zero memory (2 small shaders). Default OFF → the shipped
## StandardMaterial3D + near 0.05, byte-identical (FLAT 6035/0). Truth gate: verify_tier_depth.gd G-TIER-DEPTH-BIAS.
const FP_TIER_DEPTH_BIAS := false

## COSMOS SEAMLESS-SCALES §4/§10 C3 — the heightfield SKIN tier (FacetSkinTier). Between the near voxel field
## (0..~128) and the far-ring backstop (~12.5-block cells) is a resolution gap where, post-L5, arriving voxel
## meshes still visibly change the ground shape (obs-2/3). The skin fills it: per-facet pitch-1 heightfield tiles
## built from VoxelGeneratorCosmos.sample_columns (§7.2 item 2) — exact 1-block silhouette, SUNK SKIN blocks so
## the near voxels strictly overdraw it and it overdraws the backstop (overlap + shared sampling + sink, no fade).
## Requires FACETED (flat has no atlas). Default OFF → WorldManager never creates the node, FLAT stays byte-identical
## (6035/0). Flipped ON at export after the live A/B. HARD 8 MB ceiling (FacetSkinTier.MAX_BYTES) — evict-farthest,
## never grow. CDLOD morph / pitch-2..8 extension rings / tree impostors are LATER stages, not built here.
const FP_SKIN_TIER := false

## COSMOS FP-M2c (docs/COSMOS-FP-M2-DESIGN.md §6) — the SSE selector + request-grant budgeter + the closed-loop
## load-adaptive controller tunables. Consts so the gates assert them and M2d builds against a frozen contract.
## SELECTOR (§6.1/§6.3): LOD_TAU_PX — the screen-space-error threshold (px per megablock, desired ℓ = largest with
## p ≤ τ). LOD_HYST_BAND — a re-tier only fires when the continuous ℓ_c crosses the current tier's band by this
## much (no boundary thrash). LOD_QUEUE_MAX_EST_S — the FIXED (load-independent, §6.5.7) est-build-seconds admission
## bound the budgeter grants under. CONTROLLER (§6.5): the closed loop on measured main-thread load. FRAME_BUDGET_MS
## — the worst-frame setpoint. TICK_S — control cadence. WINDOW_FRAMES — the worst-frame sliding window. BACKLOG_MAX
## — the vox_gen feed-forward gate (holds full-res admission at 0 until the pool drains; == the M2e definition of
## done). PROMOTE_SUSTAIN_S — credit must sit ≥ PROMOTE_CREDIT this long before a live spawn is admitted (M2d).
## OVERLOAD_SUSTAIN_S — only sustained credit-0 overload this long triggers a (pause-first) demote (§6.5.4). AIMD:
## CREDIT_MDF (×0.5 on overload) / CREDIT_AI (+0.1 under headroom). OFFSURFACE_Y — the flight altitude above which
## the pool freezes spawns (risk #6 defensive stub; M2d consumes it).
const LOD_TAU_PX := 3.0
const LOD_HYST_BAND := 0.25
const LOD_QUEUE_MAX_EST_S := 30.0
const CTRL_FRAME_BUDGET_MS := 18.0
const CTRL_TICK_S := 0.25
const CTRL_WINDOW_FRAMES := 30
const CTRL_BACKLOG_MAX := 300
const CTRL_PROMOTE_SUSTAIN_S := 1.5
const CTRL_OVERLOAD_SUSTAIN_S := 3.0
const CTRL_CREDIT_MDF := 0.5
const CTRL_CREDIT_AI := 0.1
const CTRL_PROMOTE_CREDIT := 0.5
const OFFSURFACE_Y := 256.0

## COSMOS-FP-M2-CONTROLLER-FIX (un-starving the StreamLoadController; credit was pinned at 0 in production).
## RELIEF_FLOOR — the min credit-equivalent that surfaces 1-2 (LOD build grants + apply-ms) and the imminent view-ramp
## are floored to, so COVERAGE relief flows even at credit 0 (§P3a/§P3c); a relief-only candidate restriction keeps it
## terminal. FRAME_SAMPLE_CLAMP_MS — the per-sample clamp on the P1 measured inter-poll frame delta (a backgrounded tab
## cannot poison the window with a multi-second sample; §P1). WINDOW_PCTL — the P2 order statistic over the frame window
## (was: max; a max makes one browser-normal dropped frame per half-second read as sustained overload forever, §1.2).
## POOL_D_COMMIT — inside this ridge distance the imminent live promote is admitted GEOMETRICALLY (the crossing is
## committed; the cost is unavoidable and pre-paying it strictly dominates paying it at the seam, §P3b). D_WARM→D_COMMIT
## is the politeness window (defer to a headroom tick); D_COMMIT→0 is the commit band.
const CTRL_RELIEF_FLOOR := 0.25
const CTRL_FRAME_SAMPLE_CLAMP_MS := 250.0
const CTRL_WINDOW_PCTL := 0.9
const POOL_D_COMMIT := 64.0

## COSMOS-PERF STEP 1 / L5 (docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md §1.2/§4 L5) — the ADAPTIVE overload setpoint.
## The shipped overload test is `EMA(window p90) > CTRL_FRAME_BUDGET_MS` (18 ms). But the HEALTHY full-radius steady
## frame is 33 ms (2 vsyncs) on a 30-fps-floor client → p90 = 33 > 18 → PERMANENT overload → stream_credit pinned 0 all
## session, optional streaming stuck at the relief floor forever (live telemetry: credit 0 on every row). When true, the
## setpoint becomes RELATIVE to this client's OWN achievable floor: setpoint = clamp(floor_p10 × CTRL_ADAPTIVE_MARGIN,
## CTRL_FRAME_BUDGET_MS, CTRL_ADAPTIVE_MAX_MS), where floor_p10 is the p10 of a long rolling frame window (the "best
## recent minute", robust to short hitch trains). Overload then means "worse than this client's floor," not an absolute
## 60-fps-derived number: a 30-fps-floor client at a steady 33 ms is NOT flagged (setpoint ≈ 43), but a genuine
## transient spike ABOVE its floor still IS. The clamp floor (CTRL_FRAME_BUDGET_MS) means the adaptive setpoint is
## NEVER stricter than shipped — it only ever RELAXES upward for slow clients, so a fast client is never made MORE
## overload-prone than today. DETERMINISM (§6.5.7): floor_p10 is a pure order statistic over the injected-source samples
## + injected clock — no wall clock; the G-M2-CTRL-ADAPTIVE gate asserts it as a machine-speed-independent square wave.
## Default OFF → the absolute CTRL_FRAME_BUDGET_MS path, byte-identical (the per-frame floor-window push is inert — it
## never touches credit with the flag off). The controller is created only under FP_M2_LOD, so FLAT stays byte-identical
## regardless. Instance-overridable via StreamLoadController.set_adaptive() so the gates pin either mode explicitly.
## Flipped ON at export after the browser A/B (the established sed-at-export pattern). Requires FP_M1_POOL = true live.
const FP_CTRL_ADAPTIVE := false
const CTRL_FLOOR_WINDOW_FRAMES := 1800   # the best-floor rolling window (~1 min at 30 fps); floor_p10 is taken over it
const CTRL_FLOOR_PCTL := 0.1             # p10 — the client's achievable floor (robust to short hitch trains)
# CROSSING-FASTGEN obs-2 fix (1) — UN-PIN THE CONTROLLER. The margin was 1.3 → setpoint ≈ floor_p10×1.3 ≈ 22.8 ms, which
# the client's own frame exceeds in 52% of windows → credit stays pinned 0 → the imminent promotes only via the geometric
# D_COMMIT fallback (~3.4 s less gen lead). Raising it to 2.0 floats the setpoint above the client's steady frame so credit
# recovers and the imminent promotes at D_WARM. Only consumed when the setpoint is adaptive (`_adaptive`, defaulting to
# FP_CTRL_ADAPTIVE, default OFF) — so the flag-OFF absolute-setpoint path is byte-identical; this is the FLAGGED value.
const CTRL_ADAPTIVE_MARGIN := 2.0        # setpoint = floor_p10 × this (overload ⇔ ~2× worse than the client's floor)
const CTRL_ADAPTIVE_MAX_MS := 45.0       # setpoint upper clamp (never tolerate worse than ~22 fps as "not overload")

## COSMOS FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §2/§7) — the fixed absolute render-frame keystone
## master toggle (the crossing-hitch fix). When true, the player + GroundCollider + loose VoxelBody debris live
## under a new ActiveFrame Node3D whose transform is the active facet's true placement, so gameplay math stays in
## the facet-local play frame while the physics server + renderer consume planet-absolute globals — and a crossing
## becomes an O(1) node-transform swap instead of re-placing every loaded mesh block (the 200–772 ms stall).
## PHASE 1 (this stage) is the FRAME-NEUTRAL refactor ONLY: ActiveFrame pins at IDENTITY and every global↔local
## conversion routes through FrameAdapter, which is then a numeric no-op → byte-identical to today (flag on OR off).
## Phase 2 flips ActiveFrame to T_active and skips the PlanetRoot write. Requires FACETED = true AND FP_M1_POOL =
## true (decision 5; the FP-S1 teardown crossing stays the untouched fallback). Default OFF → byte-identical
## (the ActiveFrame is never created, FrameAdapter is transparent); FLAT stays 6027/0. Flipped ON at export A/B.
const FP_FIXED_FRAME := false

## COSMOS FP-FIXED-FRAME re-anchor (docs/COSMOS-FIXED-FRAME-DESIGN.md §3 / §10 decision 1) — the |player render-abs|
## magnitude (blocks) at which the faceted floating-origin re-anchor fires: an INTEGER world shift of PlanetRoot +
## every absolute FacetSlot/LOD tile + the far ring + the ActiveFrame (hence player/debris/collider/viewer) toward
## the origin, bounding f32 precision for LARGE planets (R ≫ 3072). At the shipped R = 3072 the rendered absolute
## coords are ≤ ~3.3 k (§3), so with this at 8192 the trigger NEVER fires and the committed build is byte-identical;
## it exists purely as large-planet headroom and is validated by the headless gate (which forces a shift directly).
const REANCHOR_TRIGGER_BLOCKS := 8192.0

## COSMOS-FP-CROSSING-PREGEN (#114) — kill the post-crossing vox_gen BURST by pre-generating the crossing-target facet
## to the ACTIVE near-render radius DURING the approach, so redesignate's 96→128 fill (the "SECOND crossing burst",
## module_world.gd:1661) is ALREADY done at the seam → the crossing frame requests ZERO new generation. Mechanism: the
## committed imminent slot's view_target is raised from the neighbour radius (96) to POOL_IMMINENT_PREFILL_BLOCKS the
## moment it becomes the imminent (WorldManager.set_imminent_fid / pool_spawn); the relief-floored imminent leg of
## _ramp_pool_step (module_world.gd:432) then paces the extra 96→128 annulus across the ~6 s approach — SPREAD, never a
## seam burst. When a slot STOPS being the imminent (reverse / corner-switch) it drops back to 96 (a shrink → snapped
## unload) so the enlarged live volume is held only for the facet we are actually crossing to.
##
## GATED ON FP_FIXED_FRAME (via _fixed_frame_on()): only cheap under the fixed frame — crossing cost is O(1) in
## live-terrain count (docs/COSMOS-FIXED-FRAME-DESIGN.md §9), so a fuller imminent adds NO transform-write cost; WITHOUT
## the fixed frame a 128-view imminent would ENLARGE the redesignate PlanetRoot re-place (the 200–772 ms spike). Off ⇒
## view_target stays 96, byte-identical to the shipped FP-M2d ramp. NEVER-OOM: only the SINGLE imminent slot is enlarged
## (Z1-hybrid caps live at 1 active + 1 imminent + 1 corner-second, FP2_LIVE_CAP=2); worst pool bytes = active(40 @128)
## + imminent(40 @128) + corner-second(20 @96) = 100 MB < POOL_MEM_BUDGET_MB (128). The corner-second stays at 96.
const POOL_CROSSING_PREGEN := true
## The view radius (blocks) the committed imminent slot is pre-grown to. Clamped at runtime to near_render_radius() (128
## faceted). Tunable DOWN to trade the post-crossing spread for lower peak pool memory (e.g. 112 ⇒ imminent ≈ 30 MB); at
## the default 128 the crossing's 96→128 fill fully disappears. Consulted only under POOL_CROSSING_PREGEN + fixed frame.
const POOL_IMMINENT_PREFILL_BLOCKS := 128.0

## CROSSING-FASTGEN obs-2 fix (2) — LOWER PREFILL. When on, the committed imminent slot is pre-grown to 112 instead of
## 128 blocks: a STRICT byte reduction (imminent live volume ~40 → ~30 MB) that also shrinks the approach vox_gen backlog,
## for the cost of a thin 112→128 annulus that stays hidden behind fog / the curved far-ring (and is filled at the seam
## by the ordinary neighbour ramp). Default OFF → 128 == today (`imminent_prefill_blocks()` returns the base const). NEVER-
## OOM: strictly reduces resident bytes. Flipped ON at export A/B (the sed-at-export pattern) alongside FP_CTRL_ADAPTIVE.
const FP_PREFILL_112 := false
const POOL_IMMINENT_PREFILL_BLOCKS_LOW := 112.0

## CROSSING-FASTGEN obs-2 fix (3) — VELOCITY-AWARE PREDICTIVE STREAMING. When on, the imminent promote/commit distances
## (POOL_D_WARM select + POOL_D_COMMIT geometric commit) gain a speed-proportional lead `+ min(K·|v|, MAX_ADD)` so a fast
## player promotes/commits the crossing-target facet EARLIER in TIME (more gen lead before the seam). Memory behaviour is
## unchanged — the live cap (FP2_LIVE_CAP=2: imminent + corner-second) is untouched, only the TIMING of the transitions
## shifts; and the lead is clamped so the effective D_WARM never exceeds the near render radius (128). Default OFF →
## vel_lead() ≡ 0 → the effective distances are the base consts, byte-identical. The `speed` param on the policy statics
## defaults to 0, so the headless gates (which pass no speed) are unaffected even with the flag on. Flipped ON at export.
const FP_VEL_PREDICT := false
const VEL_PREDICT_K := 2.0               # blocks of extra promote/commit lead per (block/s) of player speed
const VEL_PREDICT_MAX_ADD := 32.0        # ceiling on the additive lead — bounds effective D_WARM ≤ 96+32 = 128 (near radius)
const VEL_PREDICT_SPEED_CLAMP := 40.0    # reject a per-update speed above this as a crossing/flip discontinuity, not motion

## CROSSING-FASTGEN obs-2 fix (2): the pre-grow radius for the committed imminent slot — 112 under FP_PREFILL_112, else the
## shipped 128. Static so both module_world consumers (set_imminent_fid, pool_spawn) share one gate; OFF == the base const.
static func imminent_prefill_blocks() -> float:
	return POOL_IMMINENT_PREFILL_BLOCKS_LOW if FP_PREFILL_112 else POOL_IMMINENT_PREFILL_BLOCKS

## CROSSING-FASTGEN obs-2 fix (3): the speed-proportional promote/commit lead (blocks). Zero when FP_VEL_PREDICT is off →
## every effective distance collapses to its base const (byte-identical). Clamped to VEL_PREDICT_MAX_ADD so the effective
## D_WARM/D_COMMIT stay inside the near render radius (NEVER-OOM: the live-facet count/cap is unchanged — only timing).
static func vel_lead(speed: float) -> float:
	if not FP_VEL_PREDICT:
		return 0.0
	return minf(VEL_PREDICT_K * maxf(speed, 0.0), VEL_PREDICT_MAX_ADD)

## CROSSING-JERKINESS FIX (3-agent root-cause 2026-07-16) — the committed imminent slot's view-ramp pace FLOOR. The
## shipped build floored it at CTRL_RELIEF_FLOOR (0.25 → ~6 s to fill 96→128, LONGER than a facet traversal → the
## residual fill BURSTS at the seam = the post-crossing mesh-upload spike the player feels as a jerk). Once the crossing
## is GEOMETRICALLY COMMITTED (imminent ridge_dist < POOL_D_COMMIT — the SAME gate promote_admit_imminent already uses),
## the fill cost is unavoidable and pre-paying it at FULL pace during the commit band strictly dominates paying it at the
## seam, so the committed imminent ramps at this pace instead. Memory-NEUTRAL (same view_target; only the fill RATE
## changes). Set == CTRL_RELIEF_FLOOR to restore the shipped 0.25 trickle (the A/B knob).
const CTRL_IMMINENT_COMMIT_PACE := 1.0

## COSMOS-PERF POST-PORT P1 (docs/COSMOS-PERF-POSTPORT-DESIGN.md §4 P1) — FP_INFLIGHT_GATE: admission paced by TOTAL
## in-flight work, not the gen backlog alone. The C++ worldgen port made generation fast (supply ≥ demand at every
## speed), so the freeze bottleneck INVERTED to the main-thread mesh apply/upload stage — vox_main (mean 0.002 the
## entire pre-port history) now spikes 17–87 exactly inside the 300–881 ms worst frames. The shipped admission signal
## (vox_gen > CTRL_BACKLOG_MAX) paces the stage that is no longer the choke and is blind to the one that is: it admits
## shell bursts the downstream apply stage cannot absorb, so they land compressed. When true, the StreamLoadController's
## backlog_gated() switches to the in-flight signal F = tasks.generation + tasks.meshing + INFLIGHT_MAIN_K·tasks.main_thread
## with hysteresis (close at F > INFLIGHT_MAX, re-open at F < INFLIGHT_MIN), and module_world's per-slot view ramp applies
## a feed-forward pace cut  pace *= clampf(1 − main_q/APPLY_CHOKE, 0, 1)  (main_q = tasks.main_thread) INCLUDING the
## committed-imminent floor — the imminent slot keeps priority ORDER but must not outrun the apply stage (its old
## exemption assumed gen was the choke). Zero memory: it strictly DELAYS admission (NEVER-OOM). Default OFF ⇒
## backlog_gated() is the exact shipped  vox_gen > CTRL_BACKLOG_MAX(300)  behaviour byte-identical, the ramp pace is
## untouched, FLAT stays 6035/0. Flipped ON at export after the live SW-1C A/B (the established sed-at-export pattern).
const FP_INFLIGHT_GATE := false
const INFLIGHT_MAX := 192        # close the gate above this F (≈0.6 s of pipe at the measured 300+/s drain)
const INFLIGHT_MIN := 64         # re-open below this F (≈0.2 s) — the hysteresis band prevents admission thrash
const INFLIGHT_MAIN_K := 2       # an apply is main-thread-priced: weight tasks.main_thread K× in F
const APPLY_CHOKE := 24          # feed-forward: full ramp pace at main_q 0, linearly to 0 at main_q ≥ APPLY_CHOKE

## COSMOS ORBITAL O0 (docs/COSMOS-ORBITAL-DESIGN.md §4.4 / §11 O0) — the SKY master toggle. When true,
## main.gd builds a CosmosSky (Sun sphere + THE DirectionalLight + Moon impostor + star dome + a
## day-night environment ramp) driven by the pure f64 CosmosEphemeris kernel, and the planet gains a
## living sky (spin/orbit expressed by MOVING THE SKY, never the pinned voxel planet — §4.1). O0 is
## pure sky: NO gameplay/physics change, O(few) reused nodes, no per-frame allocation (NEVER-OOM).
## Default OFF → main._setup_environment's shipped flat-ambient look is byte-identical and NO sky node
## is added; the FLAT gate stays green. The CosmosEphemeris/DVecF64 kernels are pure statics — DEAD
## (never instantiated) with the flag off. Flipped ON at export after the live-GPU sunset screenshot.
const ORBITAL_SKY := false

## COSMOS ORBITAL O1 / SPACE-NAV SN1 (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.1, docs/COSMOS-SPACE-NAV-DESIGN.md
## §10 SN1) — the ORBITAL substrate master flag + its constants. FP_M3_ORBIT defaults FALSE ⇒ the engine is
## BYTE-IDENTICAL: nothing below is created, the CosmosGravity/OrbitalState kernels are pure statics DEAD with the
## flag off, and SURFACE/FLY locomotion is untouched. The blend band is radial altitude h = |p_fixed| − R_body:
## below H_BLEND_LO = pure shipped lattice feel gravity (walking game intact); above H_BLEND_HI = pure GM_dyn/r²
## inertial regime; in between a slerp/lerp blend (CosmosGravity.gravity_fixed). NOTE (SPACE-NAV R1): the parent
## O1O4 §2.8 H_FARSWAP impostor-swap is REJECTED (SEAMLESS-SCALES) and the const is deliberately NOT created here —
## far-ring persistence + the SN3 scaled clamp replace it. All local dynamics read GM_dyn (SPACE-NAV §3), not the
## sky's GM_game. NEVER-OOM: OrbitalState ~100 B/entity, hard-capped at ORBIT_ACTIVE_MAX (player = 1 in O1).
const FP_M3_ORBIT := false        # master flag; OFF ⇒ byte-identical (nothing below is created)
const H_BLEND_LO := 128.0         # radial altitude (blocks): below = pure lattice feel gravity (shipped)
const H_BLEND_HI := 512.0         # above = pure GM_dyn/r² inertial regime (> ATMO_TOP, > OFFSURFACE_Y)
const ATMO_TOP := 384.0           # atmosphere ceiling (D10; near-field scale, user-locked)
const ORBIT_THRUST_G2 := 25.0     # gear-2 thrust authority, m/s²
const ORBIT_ACTIVE_MAX := 8       # hard cap on actively-integrated orbital entities (NEVER-OOM)
const DRAG_TERMINAL := 55.0       # sea-level terminal speed target, m/s (co-tuned with the controller commit band)
const ORBIT_PREWARM_H := 1024.0   # descending through this altitude designates + pre-warms the landing facet

## COSMOS SPACE-NAV SN3 (docs/COSMOS-SPACE-NAV-DESIGN.md §10 / docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.2-5.5) —
## the BORDER-CONTINUITY master flag: the atmosphere↔space border + the climb to orbit render with NO pop. Off
## ⇒ BYTE-IDENTICAL: the scaled-body clamp is absent (nothing scales — CosmosScale.on() is false so its whole
## path is DEAD), the camera keeps its shipped near/far (0.05 / FacetFarRing.CAMERA_FAR = 9000), and the far
## ring retires exactly as today (never at an altitude cutoff). On ⇒ the far ring persists to any altitude under
## the continuous distance clamp s = min(1, D_ENGAGE/d) placed camera-relative, and the camera near/far ramp
## with altitude (CosmosScale). ZERO added bytes (§9: same far-ring mesh/nodes; only camera params + a per-frame
## node-transform scale). REPLACES the rejected O1O4 §2.8 H_FARSWAP impostor-swap (SPACE-NAV R1). Flipped ON at
## export after the AM remote-bridge screendiff proves the climb is pop-free (§10 SN3 live-only).
const FP_SCALED_BODY := false

## COSMOS ORBITAL-SHELL S1 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3) — drive the far-ring emitted set from the
## CAMERA radial direction instead of the player's active-facet normal, so the WHOLE visible cap renders from
## orbit (fixing the "far hemisphere blank from space" bug). The shipped ring emits only the hemisphere around
## `_active_fid`'s normal and refreshes it only on surface crossings; off-surface the radial direction drifts
## across facets with NO crossing fired, so the emitted hemisphere stays pinned near the departure region and the
## far side is simply ABSENT from the mesh (facet_far_ring.gd:291-302 / world_manager.gd:2117-2122). When true,
## the emit cull axis becomes ĉ = normalize(camera − body_centre) (ABSOLUTE planet space) with an altitude-derived
## cap θ_emit = min(arccos(R/d) + SHELL_RELIEF_DEG + SHELL_SLACK_DEG, SHELL_CAP_MAX_DEG), re-emitted (via the
## EXISTING deferred-warm + async-build + single-swap pipeline, verbatim — no new mesh/build path) when ĉ drifts
## past SHELL_SLACK_DEG − 2° or θ_h shifts > 5°. A SURFACE FLOOR keeps θ_emit ≥ 90° below OFFSURFACE_Y, so the
## on-foot regime is byte-VISUALLY identical to shipped (the facets that then differ from the active-facet law all
## sit behind the limb, occluded by the planet body). This is a POLICY change only: no second globe/representation,
## the same absolute vertex-coloured merged mesh, ONE draw call. Worst emitted mesh at the 96° cap ≈ 61 k tris /
## 7.3 MB (Δ ≤ +0.7 MB over the shipped hemisphere) — NEVER-OOM: capped by θ_cap, flat vs time/altitude. Default
## OFF ⇒ the shipped active-facet law runs verbatim, byte-identical (FLAT 6035/0). Requires FACETED. The full
## altitude range above h ≈ 6.3 k also needs FP_SCALED_BODY (SN3 near/far ramp); S1 is standalone-correct below.
## Flipped ON at export after the live orbit re-fly. Truth gate: src/tools/verify_shell.gd.
const FP_SHELL_CAMERA_SET := false
const SHELL_RELIEF_DEG := 8.0     # relief margin: terrain of height h pokes past the limb by ≈ √(2h/R); 8° covers ≥ 30-block relief
const SHELL_SLACK_DEG := 15.0     # drift slack: re-emits are scheduled (fired at SLACK − 2° = 13°), not reactive, so the old set still contains the visible cap until the new build lands
const SHELL_CAP_MAX_DEG := 96.0   # emit cap ceiling (facet-centre test grants ~half-facet slop like BACK_CULL = 0); 105° is the pre-approved limb fallback

## COSMOS ORBITAL-SHELL S2 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §4/§9) — a ONE-SHOT background whole-planet warm of
## the far-ring COARSE cache (all 6·K² facets) once sustained off-surface, so passing over a never-visited longitude
## from orbit is a pure cached emit + async build (no warm lag). Fills ONLY the same fid-keyed _pos_cache/_col_cache
## the ring already uses (hard cap 6·K² ≈ 2.4 MB — a ceiling already reachable by circumnavigating on foot; the shell
## reaches it in one orbit), never a parallel store, under the existing WARM_BUDGET_MS per frame, strictly once per
## session (a cursor). Default OFF ⇒ never armed, byte-identical (FLAT 6035/0). Requires FACETED. Depends on S1 only.
const FP_SHELL_PREWARM := false
const SHELL_PREWARM_DWELL_S := 5.0   # seconds sustained above OFFSURFACE_Y before the one-shot warm arms (ignores a brief pop above the ceiling)
## COSMOS ORBITAL-SHELL S1b (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3) — PROGRESSIVE emit in the true-orbit regime.
## The shipped far ring emits only after _warm_front caches EVERY front-hemisphere facet within one WARM_BUDGET_MS
## frame (all-or-nothing). On the surface that holds — you cross facet-by-facet and the cap stays warm — but entering
## orbit exposes ~1900 never-visited facets AT ONCE, and on web (×25 profile cost) that cap can never cache in a
## single 3 ms frame, so _begin_rebuild never fires post-ascent and the far side stays stale (the live bug the
## direct-call gates never exercised). Under FP_SHELL_CAMERA_SET, off-surface (not floored) the emit proceeds on the
## CACHED SUBSET each rebuild and grows as _warm_front + FP_SHELL_PREWARM fill the cache — re-emitted every
## SHELL_REEMIT_GROWTH newly-cached facets — so coverage appears immediately and converges, never stalling. The
## async worker still only ever reads cached facets (the emitted set is cache-filtered), preserving its read-only
## contract. The SURFACE (floored) + flag-off paths keep the shipped all-or-nothing warm gate verbatim (byte-identical).
const SHELL_REEMIT_GROWTH := 64      # re-emit the growing cached cap every N newly-cached facets (progressive-fill cadence)

## COSMOS SPACE-NAV SN2 (docs/COSMOS-SPACE-NAV-DESIGN.md §4/§5/§10) — the five-mode NAV-FRAME machine
## master flag. When true, the player maintains a CosmosNav.NavState (classify + 2-s dwell + R-latch),
## re-expresses the HUD velocity in the current nav frame, and stamps nav_mode/frame_v/|v_bci| into the
## RemoteBridge telemetry. Default FALSE ⇒ BYTE-IDENTICAL: the NavState is never created, CosmosNav is a
## pure DEAD static, the HUD/telemetry are unchanged (nav_telemetry() returns {} ⇒ the guarded merge adds
## nothing). The five modes are RE-EXPRESSIONS of the ONE SN1 f64 BCI state (§0.1) — a mode flip touches
## NOTHING physical, so this flag adds zero per-frame allocation and cannot perturb the scene or state.
const SN_NAV_MODES := false

## COSMOS SPACE-NAV SN5 (docs/COSMOS-SPACE-NAV-DESIGN.md §7/§10) — the DEV-NAV master flag. When true, F enters
## dev-nav (the mode-appropriate velocity-command flight controller + the overlay set) instead of the bare fly
## toggle; the controller re-expresses the shipped fly input into the current nav frame (planetary hover tracks
## the spinning surface, orbital hover station-keeps) and is SN-R1-seamless across mode boundaries. Default
## FALSE ⇒ BYTE-IDENTICAL: F is the shipped bare fly toggle, no dev-flight controller runs, no overlay node is
## created, CosmosDevFlight is a pure DEAD static. Requires SN_NAV_MODES (the controller reads the NavState).
## NEVER-OOM: the controller is O(bytes) (no retained state — the caller owns [p,v]); the SN5b overlays are
## lazy, reused, freed on toggle, hard-capped ≤ 64 KB (§9). The FEEL of flying + the LOOK of the overlays are
## LIVE-ONLY (morning validation); the controller MATH + mode-transition trajectory are headless-gated
## (verify_dev_flight — G-SN-DEVFLIGHT). Flipped ON at export after the AM live pilot pass.
const SN_DEVNAV := false

## COSMOS SPACE-NAV SN4a (docs/COSMOS-SPACE-NAV-DESIGN.md §6.2) — the ALTITUDE ATMOSPHERE RAMP. When true,
## CosmosSky._ramp_environment composes altitude terms (all C¹ in radial altitude h = |cam| − R_vox) onto
## the shipped sun-elevation ramp: fog thins (fog_density = exp(−h/H_SCALE)), the sky lerps to BLACK as
## space_mix rises (smoothstep 0.5·H_ATMO..2.5·H_ATMO), stars emerge (star_fade = max(night_fade, space_mix)),
## ambient dims to AMBIENT_SPACE. On an airless body (has_atmo=false) space_mix≡1 ⇒ black starry sky at the
## surface. Default FALSE ⇒ BYTE-IDENTICAL: _ramp_environment writes exactly the shipped day-night values
## (fog_density stays 1.0, no altitude term is evaluated). Requires ORBITAL_SKY (the ramp lives in CosmosSky).
## ZERO added bytes (O(1) Environment property writes/frame), NO shaders/materials — Environment props only.
## Headless-PROVEN: the curve MATH + endpoints (G-SN-RAMP). LIVE-ONLY: the actual LOOK (limb, sunset legibility).
const ATMO_VISUAL_RAMP := false

## COSMOS SPACE-NAV SN4b (docs/COSMOS-SPACE-NAV-DESIGN.md §6.3) — the ANALYTIC SUN-OCCLUSION DIMMER. Without
## shadow maps the DirectionalLight lights a player behind the planet; this dims light_energy to 0 when the
## body occludes the sun (α between ŝ and −p̂ < asin(R_vox/|p|), soft ±0.005 rad penumbra). Pure f64, one
## scalar/frame, ZERO bytes. Blended by altitude with the shipped elevation ramp (authority = space_mix(h)) so
## exactly one driver owns any regime — at the surface the elevation ramp owns (light_energy stays 1.0), in
## space the occlusion dimmer owns (night side dark from orbit). Airless bodies: occlusion owns from the
## surface. Default FALSE ⇒ BYTE-IDENTICAL: light_energy is never written (stays the shipped 1.0). Gate
## G-SN-OCCLUDE (headless-proven math); the LOOK of the orbital night side is LIVE-ONLY.
const SN_SUN_OCCLUSION := false

## COSMOS-LOD-SKY L1 (docs/COSMOS-LOD-SKY-DESIGN.md §7.3) — MOONSHINE (v0: zero-draw ambient moonlight). When
## true, CosmosSky._ramp_environment adds a cool ambient term to the NIGHT side scaled by the Moon's ephemeris
## illuminated fraction × how high the Moon rides × the night authority (1−twilight): full moon ⇒ a meaningfully
## brighter blue-grey night, new moon ⇒ the shipped floor EXACTLY. Composes UNDER the SN4a/b altitude authorities.
## Lunar eclipse falls out for free (CosmosSky.moon_eclipse_factor reuses occlusion_factor with the Moon behind
## Earth) — it dims the ambient term and reddens the Moon impostor toward the §6 umbra crimson. ZERO draws, ZERO
## bytes (Environment ambient-energy write + one impostor albedo write per frame). Default FALSE ⇒ BYTE-IDENTICAL:
## no ambient term, the Moon albedo stays the shipped grey. Requires ORBITAL_SKY. Gate G-SKY-MOONSHINE; the night
## LOOK is live-only. SAFE to bake ON (no shader/draw risk).
const SKY_MOONSHINE := false

## COSMOS-LOD-SKY L1 v1 (docs/COSMOS-LOD-SKY-DESIGN.md §7.3) — MOONSHINE as a REAL second DirectionalLight for
## actual moon-shadows-on-terrain. In gl_compat every extra per-pixel light renders lit geometry in an ADDITIVE
## pass — worst case approaches DOUBLING the ~200-draw budget — so this is the draw-count VISUAL-RISK half and is
## a SEPARATE flag from the v0 ambient above, DEFAULT OFF even at export until a live draw-count/worst-frame A/B
## passes. v0 is the permanent fallback. Requires SKY_MOONSHINE. LIVE-ONLY (measured A/B); no headless gate beyond
## the energy formula (shared with v0).
const SKY_MOONSHINE_LIGHT := false
const MOON_LIGHT_MAX := 0.08      # v1 second-light peak energy (× illuminated_fraction × night authority)

## COSMOS-LOD-SKY L2 (docs/COSMOS-LOD-SKY-DESIGN.md §6a) — the GROUND sunrise/sunset scattering ramp. When true,
## CosmosSky._ramp_environment recolours the sky/fog/ambient toward the real Rayleigh direct-light transmittance
## T_c(μ)=exp(−τ_c·m(μ)) — sea-level optical depths τ=(0.245,0.098,0.042) B/G/R, Kasten–Young air mass m(μ) — as
## the Sun nears the horizon: deep-blue → cyan → gold → orange → crimson, EMERGING from the physics with no
## hand-painted gradient. Environment property writes ONLY (the SN4a pattern) — ZERO bytes, ZERO shaders. Default
## FALSE ⇒ BYTE-IDENTICAL: the shipped two-colour NIGHT→DAY lerp is untouched. Requires ORBITAL_SKY. Gate
## G-SKY-SCATTER (curve/endpoints/monotone/C¹/off-identity); the sunset LOOK is live-only. SAFE class (no shader).
const SKY_SCATTER_RAMP := false

## COSMOS-LOD-SKY L3 (docs/COSMOS-LOD-SKY-DESIGN.md §6b) — the SPACE-side terminator band. When true, the far-ring
## shell material becomes a lit vertex-colour SHADER carrying a `sun_dir` uniform; per vertex μ = normalize(v)·sun_dir
## and ALBEDO *= mix(1, scatter_tint(μ), band(μ)) — the SAME T(μ) ramp as L2, so the sunset arc you saw from orbit
## and the sky you see on the ground agree by construction. THIS IS THE ONE VISUAL-RISK stage (the P3 shader-failure
## class on gl_compat): DEFAULT FALSE, screenshot-gated, and the StandardMaterial fallback is retained PERMANENTLY
## (flag off ⇒ FacetFarRing._make_material returns the shipped StandardMaterial verbatim — byte-identical, the shell
## is untouched). Gate G-SHELL-TINT proves the per-vertex tint MATH + the fallback identity; the render is live-only.
## Requires ORBITAL_SKY + FACETED. Do NOT bake ON without a live screenshot.
const SHELL_TERMINATOR_TINT := false
## COSMOS-LOD-SKY M1 (docs/COSMOS-LOD-SKY-DESIGN.md §2/§5/§9) — the multi-body distance-LOD SELECTION LAW.
## When true, CosmosSky consults BodyLod each frame to classify every celestial body's presented tier
## (POINT → IMPOSTOR → RING) from its angular size — relief_px = e_relief/d·K_px vs TAU_POP, ±25% hysteresis —
## and logs each impostor↔ring handover under the G-SSE-INV sub-pixel no-pop discipline. M1 SELECTS + ACCOUNTS
## only: the law's output for the real Sun/Moon at their true distances is IMPOSTOR (Sun e_relief=0 ⇒ impostor
## forever; Moon relief_px≈0.23 px ≪ 1), so NO placement/mesh changes — the visible detail-on-approach needs
## M2's per-body RING build (FP_MOON_RING, rides O4c). The BodyLod kernel is pure statics (no engine deps, no
## alloc, caller owns the latched tier) and DEAD with this flag off ⇒ BYTE-IDENTICAL (FLAT 6035/0): the sky's
## per-frame writes are untouched, no BodyLod call is made. NEVER-OOM: selection + byte bookkeeping only, no new
## allocation — the 32 MB far-tier ceiling (N_RING_MAX=2 resident rings, dominant-exclusive dense/skin) is
## ACCOUNTING the gate asserts, not new bytes. Requires ORBITAL_SKY (the consult lives in CosmosSky). Truth
## gate: src/tools/verify_body_lod.gd (G-BODY-LOD / G-LOD-CEILING / G-LOD-NOPOP).
const FP_BODY_LOD := false

## COSMOS-LOD-SKY M2 (docs/COSMOS-LOD-SKY-DESIGN.md §3/§4/§5, the M2 stage). The Moon's own coarse far-ring:
## when FP_BODY_LOD promotes the Moon IMPOSTOR→RING on approach (relief_px ≥ TAU_POP, d ≲ 120 k), CosmosSky
## builds a body-parameterized far ring for the Moon body (MoonFarRing over FacetAtlas' moon fid range, K=14,
## r_of=1737, moon_profile_at_dir + a moon regolith/maria/highlands palette) so the Moon shows REAL cratered
## terrain instead of the flat impostor disc — airless (no atmosphere/clouds). The ring is placed to MATCH the
## impostor exactly (same sky centre + angular radius, scaled about the camera), so the handover is sub-pixel BY
## the law that triggers it (G-SSE-INV). Built WHOLE on promotion, FREED WHOLE on eviction (demote, d ≳ 150 k) —
## nothing grows with time/approach count. HARD budget (§3/§5): ≤ 2.5 MB GPU + 0.94 MB CPU, inside the 32 MB
## far-tier ceiling (N_RING_MAX=2). Requires MULTI_BODY (the Moon facets exist) + FP_BODY_LOD (the tier decision).
## Default FALSE ⇒ BYTE-IDENTICAL (FLAT 6042/0): the MoonFarRing node is never created and the CosmosSky ring
## block is never entered. Truth gate: src/tools/verify_moonring.gd (G-MOON-RING / -BUDGET / -NOPOP).
const FP_MOON_RING := false

## COSMOS-LOD-SKY M1 — the D_SKY O3 revisit (docs/COSMOS-LOD-SKY-DESIGN.md §1/§11, cosmos_sky.gd:26). The sky
## impostor/star-dome placement radius CosmosSky.D_SKY = 8000 was sized for R = 3072 (2.6·R); after the rescale
## to R = 6371 it sits at only 1.26·R — too close to the planet — and its literal value no longer tracks the
## far clip. When true, CosmosSky uses CosmosSky.d_sky_derived() = CAMERA_FAR·SKY_FAR_MARGIN/STAR_DOME_MULT
## (≈ 8143): as far OUTSIDE the planet as the 9000-block camera far clip allows, with the star dome (radius
## D·1.05) fully inside the clip by a stated margin — derived from CAMERA_FAR so it can never clip and tracks
## any future far-plane change. Default FALSE ⇒ BYTE-IDENTICAL: CosmosSky keeps the shipped literal 8000
## everywhere (placement + star mesh). Requires ORBITAL_SKY. Gate: the D_SKY section of verify_body_lod.gd
## (impostor outside R, star dome inside the far clip). NOTE: at R=6371 with a 9000 far clip the impostor
## CANNOT be a large multiple of R (the far plane boxes it at ≤ 1.35·R); raising that further is a CAMERA_FAR
## change, out of M1 scope — the gate asserts the derived value clears R and flags loudly if R ever approaches it.
const FP_SKY_DSKY_R := false
## COSMOS CLIMATE W0 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §3 / §7) — REAL AXIAL SEASONS. When true the
## ephemeris fills Earth's reserved axial_tilt slot (23.4° = 0.4084 rad): dir_to_bodyfixed composes the
## obliquity (R_spin·R_tilt) so CosmosSky's sun arcs get seasonal (low winter / high summer / polar
## day-night) for free, and ClimateModel.season_offset(sinlat, sinδ) shifts the sim-layer temperature and
## the SnowfallSystem snow line with the subsolar latitude δ(t). WORLDGEN IS UNTOUCHED — the offset is added
## ONLY by sim-layer callers (PerVoxelEnvironment / SnowfallSystem), so generated_cell/profile_at_dir stay
## pure of the clock (G-SEAS-PURE) and the C++ frozen epoch survives. Default FALSE ⇒ effective_tilt≡0
## (R_tilt=I) and no offset is ever added ⇒ BYTE-IDENTICAL to the shipped no-tilt kernel; the O1/tidal gates
## stay green. Gate verify_climate G-SEAS-TILT (δ=±23.4° at solstices) + G-SEAS-PURE.
const FP_SEASONS := false

# =====================================================================================================
# COSMOS ATMO-SKY (docs/COSMOS-ATMO-SKY-DESIGN.md) — the unified atmosphere + celestial + day/night
# rebuild. ONE physically-motivated model consistent from outer space and from the surface (the
# terminator from orbit and the sunset on the ground are the SAME curves). Staged A0..A6, every flag
# default FALSE ⇒ BYTE-IDENTICAL (the curve math is pure static in CosmosSky, driven directly by the
# gates; the flags only decide whether the sky/light/shell COMPOSE it in-game). All shaders (shell v2,
# atmosphere halo, moon phase) keep a PERMANENT StandardMaterial/analytic fallback (P3 gl_compat class):
# any compile failure ⇒ the flag stays off and the shipped path ships. See the design §4 stage table.
# =====================================================================================================

## A0 (design §2.0 / §4). Move the SN3 scaled-body driver block (main._process) ABOVE the FLAT_WORLD
## early-return, so with FP_SCALED_BODY baked ON it actually RUNS in the faceted production game
## (FLAT_WORLD=true) — the camera near/far ramp with altitude and the far ring gets its distance clamp,
## un-clipping the planet from altitude/deep space (the shipped 9000 far plane clips the far side above
## h≈3-6 k; from the pilot's d=167 k the planet is entirely gone). The SAME stranded-driver class as the
## shell-driver fix (0b2a934). Off ⇒ the block stays below the return, DEAD in faceted (byte-identical).
## Must bake WITH A1 (once the planet renders at d≫D_SKY the sky impostors/dome would draw over it —
## occlusion becomes mandatory). Gate G-AS-FARRAMP.
const FP_SN3_MAIN_LIVE := false

## A1 (design §2.1 hazard / §3 C5 / §4). Analytic planet-disc OCCLUSION of the sky. Once A0 renders the
## planet at distances ≫ D_SKY, the opaque Sun/Moon impostors (at D_SKY≈8143) would draw IN FRONT of the
## Earth disc and the additive star dome would sprinkle stars OVER the planet. When true, the Sun/Moon
## impostors are hidden (visible=false) when the planet disc covers their direction (occlusion_factor
## reused: the sun/moon is behind the disc ⇔ occ==0), and the star-dome shader discards fragments inside
## the planet disc via planet_dir/planet_cos_ang uniforms. D_SKY stays const — the sky is angular, occlusion
## is analytic (NOT distance-chased). Off ⇒ impostors always visible, star mask uniform passes everything
## (planet_cos_ang = 2.0 > 1 ⇒ never discards) ⇒ byte-identical. Requires ORBITAL_SKY. Gate G-AS-OCC.
const FP_SKY_PLANET_OCCLUDE := false

## A2 (design §3 C5 / §4). Sun/Moon PERCEPTUAL PRESENCE. The impostor is sized to the real 0.53° angular
## diameter → ≈8 px, and gl_compat has no bloom/HDR glare, so the Sun is an invisible dot. When true: an
## angular-size FLOOR is applied to each impostor radius (SUN_MIN_ANG/MOON_MIN_ANG), an additive
## radial-falloff GLARE quad is added on the Sun (~5× disc radius, brightness ×occ(cam) so it dies at
## sunset/eclipse/umbra), and the Sun disc colour reddens by T(μ_cam,0). Off ⇒ exact-angular impostors,
## no glare node ⇒ byte-identical. Requires ORBITAL_SKY. LIVE-ONLY LOOK; the floor math is gated.
const FP_SUN_PRESENCE := false
const SUN_MIN_ANG_DEG := 2.0      # perceptual angular-diameter floor for the Sun impostor (taste)
const MOON_MIN_ANG_DEG := 1.5     # perceptual angular-diameter floor for the Moon impostor (taste)
const SUN_GLARE_RADII := 5.0      # glare quad half-size in Sun-disc radii

## A3 (design §2.3 / §3 C3 / §4). atmo_vis(h) replaces the space_mix 192..960 band with a 0.5·ATMO_TOP..
## ATMO_TOP fade (exactly 0 at/above ATMO_TOP=384 — the tint is star-black in space, fixing the orbit
## sky-colour bug). star_fade = max(night_fade, 1−atmo_vis(h)); SKY_SCATTER_RAMP's weight gains ·atmo_vis
## so it can finally bake ON. Off ⇒ CosmosSky uses space_mix + the shipped scatter weight (byte-identical).
## Requires ORBITAL_SKY. Gate G-AS-ZERO.
const FP_ATMO_SPACE_ZERO := false

## A4 (design §2.2 / §3 C1 / §4). ABSOLUTE day/night light. The DirectionalLight energy becomes occ(cam)
## ALWAYS (no space_mix authority lerp) with an altitude-widened penumbra pen(h) (long twilight at the
## ground, sharp in vacuum), the light COLOUR reddens by T(μ_cam,0), and the ambient umbra authority is
## likewise removed (continuous, absolute). Fixes "the dark side lights up as you descend" (the through-
## planet DirectionalLight lit the night side below h≈192). The Moon self-phase shader lands HERE
## (regression guard: with C1 dimming the global light at night the shaded-Moon impostor would black out —
## the shader computes Lambert phase from a sun_dir uniform, unshaded). Off ⇒ occlusion_light /
## occlusion_ambient authority lerps + the shipped shaded Moon material (byte-identical). Gate G-AS-ABSLIGHT.
const FP_LIGHT_ABSOLUTE := false

## A5 (design §2.2-3/4 / §3 C2 / §4). The globe far-ring shell shader v2: UNSHADED (immune to the global
## light/ambient, so the globe's look stops tracking the camera), per-vertex NIGHT_FLOOR + (1−NIGHT_FLOOR)·
## day(n̂) darkening with n̂ = normalize(wp − planet_centre) where planet_centre is a UNIFORM fed the scaled
## render centre (fixes the origin-assumption that breaks under scale-about-camera), × the kept terminator
## band tint. Supersedes SHELL_TERMINATOR_TINT v1 (the band tint is retained inside v2). StandardMaterial
## fallback retained permanently. Off ⇒ FacetFarRing._make_material returns the shipped path (byte-identical).
## Requires ORBITAL_SKY + FACETED. Gate G-AS-TERM. Do NOT bake ON without a live screenshot (P3 shader class).
const FP_SHELL_ABSOLUTE := false

## A6 (design §2.4 / §3 C4 / §4). The atmosphere shell — ONE inverted additive SphereMesh (radius
## R + 2·ATMO_TOP, planet-centred, riding the same scaled placement as the far ring; cull_front +
## blend_add + depth_draw_never so it never occludes and the planet's depth kills it behind the disc).
## Its closed-form fragment shader is the blue limb HALO from outside AND the horizon-band sky from inside,
## by the SAME day/T/band curves as C2/C5 (seamless by construction). C3 (the camera Environment sky) is
## gated by atmo_vis so the base tint is 0 in space and this shell composes additively. Off ⇒ no shell node,
## no camera-sky change beyond A3 ⇒ byte-identical. Requires ORBITAL_SKY. Depends on A3 (no double tint) +
## A5 (matching curves). Gate G-AS-LIMB. LIVE-ONLY LOOK (P3 shader class); analytic StandardMaterial fallback.
const FP_ATMO_SHELL := false

## COSMOS CLIMATE W1 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §1 / §7) — the ONE coarse prognostic weather
## grid (WeatherSystem). 6 faces × 32×32 = 6144 cells, 8 f32 fields double-buffered (384 KiB) + a 44 B/cell
## static basis (264 KiB), allocated ONCE, exploration-independent, ZERO growth paths (SnowfallSystem
## discipline). A sliced sweep (128 cells/frame) integrates insolation → T, a diagnostic thermal-low
## pressure, an analytic + geostrophic + friction DIAGNOSTIC wind (cannot go unstable), semi-Lagrangian
## moisture with evap/condense/rain-out + orographic lift, and a CAPE instability proxy. NO rendering (that
## is W2/W3/W4); PerVoxelEnvironment exposes humidity/wind/pressure/precip/cloud reads. Deterministic (pure
## of SEED + state + sweep index). Default FALSE ⇒ WeatherSystem is never instantiated ⇒ zero bytes / zero
## CPU / byte-identical. Gate verify_climate G-W1-BYTES/CPU/DET/PHYS/ITCZ/INIT.
const FP_CLIMATE_GRID := false

## COSMOS CLIMATE W2 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §4 / §7) — the 3-layer semi-cubic CLOUD mesher
## (CloudLayers). A read-only view of the weather grid: blocky prisms (cumulus/stratus/cirrus at 3
## altitudes, all < ATMO_TOP 384) in the terrain's own vertex-colour language, from a camera-following
## world-snapped 64×64 tile lattice + SEED+106 noise, greedy row-merged into ONE reused CPU scratch
## uploaded to exactly 3 ArrayMesh surfaces (3 draw calls). HARD vertex cap ⇒ overcast is the cheapest
## mesh, the worst case bounded (≤2.4 MiB, G-W2-BYTES/DRAWS). Requires FP_CLIMATE_GRID (reads its cloud
## water). Default FALSE ⇒ no CloudLayers node ⇒ zero bytes / byte-identical. Cloud LOOK is LIVE-ONLY.
const FP_CLOUDS := false

## COSMOS CLIMATE W3 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §5 / §7) — PRECIPITATION as threshold read-outs
## of the weather grid: rain/snow/fog. ONE reused camera-following particle node (hard amount cap ≤1024),
## the Environment fog density driven from grid humidity (composed MULTIPLICATIVELY with SN4a's altitude
## ramp so space stays clear), and SnowfallSystem.is_snowing upgraded to couple to the grid (kind==snow,
## the SEED+105 noise becoming the sub-cell structure). Kind (rain/snow) resolves through the ONE
## surface_temperature+season zero-crossing, so precip agrees with the snow-cap boundary (G-W3-COUPLE).
## Requires FP_CLIMATE_GRID. Default FALSE ⇒ no FX node, is_snowing verbatim ⇒ byte-identical. Precip
## FEEL/fog mood is LIVE-ONLY.
const FP_PRECIP := false

## COSMOS CLIMATE W4 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §4.4/§5 / §7) — THUNDERSTORMS from the grid's
## CAPE-proxy instability field. Convective cells (instability over threshold + cloud water) become
## towering cumulonimbus in CloudLayers (dark, up to 256, capped ≤64 towers/rebuild — bounded extra
## height, no extra draws), flash lightning (ONE reused omni flash, energy writes only) and drop hail
## (WeatherFX kind swap) in WeatherFX. Emergent from state, NEVER scripted per-phenomenon (G-W4-EMERGE).
## The behaviours live INSIDE the W2 (CloudLayers) / W3 (WeatherFX) nodes, gated on this flag — so it needs
## FP_CLOUDS + FP_PRECIP. Default FALSE ⇒ those nodes behave exactly as W2/W3 ⇒ byte-identical. Storm
## drama (flash timing, tower look) is LIVE-ONLY.
const FP_STORMS := false

## COSMOS CLIMATE — WEATHER ON A WORKER THREAD (live pilot request: "use a separate dedicated thread for the
## weather simulation, and later for all other environmental simulations, to offload the main game cycle").
## When true AND FP_CLIMATE_GRID is on, WorldManager runs the WeatherSystem sweep on a DEDICATED worker thread
## (EnvSimWorker) instead of slicing it on the main loop: the worker advances the grid into the BACK buffer,
## the main thread only does a pointer-flip SWAP of the already-existing double buffer at one sync point and
## READS the front buffer — so the per-frame main-thread weather cost drops to ~0 (kills the walking hitch the
## coarse per-frame sweep caused). The sweep advances by SIM-TIME so it stays frame-rate-independent and
## deterministic given (SEED + game_time); the worker writes back / main reads front / the swap is the only
## sync (no data race — G-WTHREAD-SAFE). Composes with FP_CLIMATE_GRID (thread only matters when the grid is
## on). Default FALSE ⇒ the shipped main-thread sliced sweep runs verbatim ⇒ BYTE-IDENTICAL (FLAT unchanged);
## the class isn't even instantiated. NEVER-OOM: adds only the thread stack + a mutex/semaphore, no buffers
## (the double buffer already exists). Gate verify_weather_thread G-WTHREAD-SAFE/EVOLVE/MAINCOST + teardown.
const FP_WEATHER_THREAD := false

## SN-FIX #1 (2026-07-18, live pilot request) — the NAV HUD readout. When true, main.gd builds a small
## NavHUD CanvasLayer that shows the player's lattice position (rounded x,y,z), radial altitude (|world|−R_BLOCKS
## when faceted, else lattice y) and the current nav-mode name (the same string as the RemoteBridge nav_mode;
## "—" when SN_NAV_MODES is off). Default FALSE ⇒ BYTE-IDENTICAL: no NavHUD node is created, no new per-frame
## work. Additive, read-only (mirrors the ThermometerHUD pattern). Gate G-SN-HUDNAV (lifecycle + formatting).
const SN_HUD_NAV := false

## SN-FIX #2 (2026-07-18, live pilot report) — PRESERVE HEADING across facet crossings. The shipped fixed-frame
## reframe (player.gd apply_reframe) twists rotation.y + velocity by the seam's horizontal `yaw_delta` so a
## walk stays world-continuous; the pilot reports this SWINGS their horizontal heading at crossings and wants
## it FIXED (the ground may tilt — carried by the ActiveFrame/camera — but the heading must NOT rotate). When
## true, apply_reframe does the POSITION reframe exactly as shipped but SKIPS the horizontal yaw twist of
## heading + velocity (and forwards a zero twist to the remote executor). Default FALSE ⇒ the shipped yaw-twist
## is BYTE-IDENTICAL. This gates a SHIPPED fixed-frame behaviour. Gate G-SN-KEEPHEADING. Live-only: the feel.
const FP_CROSS_KEEP_HEADING := false

## SN-FIX #3 (2026-07-18, live pilot report "bounced back at the atmosphere ceiling" + the full F-mode model the
## pilot then specified). The intended physics, gated as ONE switch:
##   (1) F-MODE (dev-nav fly) is GRAVITY-OFF ALWAYS — a kinematic fly in the FULL look direction (camera forward
##       incl. pitch), constant speed at every altitude. Looking up + forward climbs straight through the
##       atmosphere ceiling (ATMO_TOP=384) into orbit with NO deceleration/bounce. (The bounce was the shipped
##       dev-nav auto-handoff to the CosmosDevFlight velocity-command controller, which ramped the climb toward
##       the command at DEV_ACCEL — headless-confirmed 32→~1 b/s. That controller now runs ONLY after the pilot
##       EXPLICITLY commits with the O "release-to-orbit" verb; O behaviour itself is a follow-up, untouched.)
##   (2) F-OFF gravity is WHERE-aware: ABOVE 384 the player free-falls in the PLANET-CENTRED (inertial) frame
##       under GM_dyn/r² toward the planet centre — NO surface-rotation drag (you keep the planet's solar orbit,
##       don't co-rotate with the surface). Crossing BACK DOWN under 384, the SURFACE frame + surface-feel
##       gravity resume. The frame/rotation-drag switch at 384 is the existing nav-mode carrier (ω⃗×p → 0); the
##       flight↔fall and fall↔surface handoffs seed velocity so there is NO jump.
## Default FALSE ⇒ BYTE-IDENTICAL: dev-nav keeps its shipped auto-handoff fly and F-off is the shipped lattice
## walk gravity; nothing free-falls. Requires SN_DEVNAV + FACETED to have any effect. Gate G-SN-NOBOUNCE
## (decision/regime/gravity/continuity, headless). Live-only: the FEEL of the seamless climb + the fall.
const SN_NO_CEILING_BOUNCE := false

## SN-BRAKE (2026-07-18, live pilot "fell F-off from orbit at ~141 m/s → generation storm on landing";
## docs/COSMOS-SPACE-NAV-DESIGN.md §6 / COSMOS-ORBITAL-O1O4-DESIGN.md §2.6). ATMOSPHERIC DESCENT BRAKING: a
## craft entering the atmosphere fast decelerates toward a low terminal velocity BEFORE it reaches the surface,
## so the descent never outruns terrain streaming (the fast landing was outrunning the generator). The SN1 drag
## law a_drag = −k(h)·|v|·v, k(h) = k0·exp(−h/DRAG_H_SCALE) (density ~0 at ATMO_TOP, max at h=0), is applied to
## the DESCENT vertical velocity on the below-ATMO_TOP surface-frame path (where the F-off fall velocity is
## handed to velocity.y). k0 = datum_gravity(body)/ATMO_BRAKE_TERMINAL² ⇒ terminal == ATMO_BRAKE_TERMINAL for
## ANY body (per-body generic — reads the dominant body, NOT a hardcoded Earth). ABOVE ATMO_TOP: NO drag (the
## planet-centred free-fall owns space, unchanged). Continuous at 384 (density ≈ 0 there ⇒ no jump). SEPARATE
## from the ORBITAL integrator's own DRAG_TERMINAL (that drag is untouched). Default FALSE ⇒ BYTE-IDENTICAL:
## no brake term is evaluated, the shipped surface walk is byte-for-byte. Requires FACETED. Gate G-SN-BRAKE
## (braked-to-terminal / density profile / no-drag-above-384 / per-body, headless). LIVE-ONLY: that streaming
## actually keeps up (no storm) needs a live re-fly — the gate proves the descent is braked, not that the
## generator wins. Follow-up if braking alone is insufficient: pre-generate the landing column during the fall.
const SN_ATMO_BRAKING := false
## SN-BRAKE descent terminal speed (blocks/s) — the speed a re-entry brakes to below ATMO_TOP. Set to 20 for
## the natural 1:1000 model: datum gravity is now 9.8 (≈5× weaker than the old 72×-model 50.9), so k0 =
## datum_gravity/ATMO_BRAKE_TERMINAL² is smaller and the drag relaxes SLOWER over the fixed 384-block band
## (ATMO_TOP is USER-LOCKED at 384 — retune drag, not the border). 20 is the strongest reasonable terminal that
## keeps a STEEP re-entry from the natural 250-b/s orbit STREAM-SAFE within 384 blocks: a −250 dive arrives
## ≈25.3 b/s, a −300 dive ≈26.5, even a −350 (escape-speed) dive ≈27.8 — all under the ~30-b/s stream-supply
## floor (voxiverse-streaming-supply-demand), while 20 b/s reads as a firm descent, not a hard stop. Terminal ==
## √(datum_gravity/k0) == ATMO_BRAKE_TERMINAL by construction (per-body generic). Single named const — dial live
## (raise toward the orbital DRAG_TERMINAL 55 once a pre-gen landing column removes the streaming constraint).
const ATMO_BRAKE_TERMINAL := 20.0

## COSMOS ORBIT-FRAME Phase A (docs/COSMOS-ORBIT-FRAME-DESIGN.md §3 / §8) — the INERTIAL ATTITUDE machine
## master flag. When true, the player holds its camera ORIENTATION as a BCI quaternion (CosmosAttitude) while
## in space: on the committed nav mode leaving PLANETARY it seeds q_bci from the current displayed basis (C0,
## no pop), decouples the camera from the facet frame (top_level global write B_cam = R_z(−θ)·Basis(q)), and
## routes mouse to camera-local yaw + UNLIMITED pitch and Q/E to roll. Returning to PLANETARY re-derives the
## surface FPS yaw/pitch and hands back INSTANTLY (Phase A — yaw/pitch continuous, any roll snaps to 0; the
## smooth slerp is Phase C, ORBIT_LAND_RECOVER). This alone fixes BOTH live-pilot bugs ("sky rotates with the
## planet" + "roll/pitch tied to the facet"): the star dome is ALREADY inertially fixed (R_z(−θ)), so making the
## camera inertial freezes the stars and detaches the attitude with ZERO sky-render change. Requires SN_NAV_MODES
## (reads player._nav) AND FACETED. Default FALSE ⇒ BYTE-IDENTICAL: the machine never leaves SURFACE, the
## input/camera/window_camera_transform branches all fall through to the shipped surface FPS path, the camera
## node is never emancipated. Gates G-ORBIT-ATT (seed round-trip / >90° pitch / roll / inertial hold) + G-ORBIT-SKY
## (the −θ dome counter-rotation regression). LIVE-ONLY: the top_level camera render + the feel of 6DOF + frozen stars.
const ORBIT_ATTITUDE := false
## ORBIT-FRAME tunable (live-tuned): the Q/E roll rate (rad/s). Consulted only under ORBIT_ATTITUDE in SPACE;
## the pure kernel takes it as an argument so the gate drives it directly. (Phases B/C add their own flags.)
const ORBIT_ROLL_RATE := 1.2
## COSMOS ORBIT-FRAME Phase B (docs/COSMOS-ORBIT-FRAME-DESIGN.md §5) — fly the FULL 6DOF look. When true (AND
## ORBIT_ATTITUDE AND in SPACE), the kinematic look-fly builds its direction from the inertial camera basis
## re-expressed in the lattice (frame_basis-transpose times B_cam_scene = CosmosAttitude.lat_cam_basis), with
## Space/Ctrl on CAMERA-local +/-Y (microgravity has no world vertical); the hover carrier drift composes
## UNCHANGED (a zero-input hover still holds the BCI rest, G-SN-HOVERDRIFT stays valid). The dev-flight velocity
## controller becomes fully 6DOF for FREE via the window_camera_transform seam (asserted, not edited). Default
## FALSE ⇒ the shipped body-yaw+pitch lattice construction, byte-identical (and _kinematic_look_fly is only
## reached under SN_NO_CEILING_BOUNCE dev-nav). Requires ORBIT_ATTITUDE + SN_DEVNAV. Gate G-ORBIT-FLY.
const ORBIT_6DOF_FLY := false
## COSMOS ORBIT-FRAME Phase C (docs/COSMOS-ORBIT-FRAME-DESIGN.md §3.5) — the SMOOTH landing recovery. When true
## (AND ORBIT_ATTITUDE), leaving SPACE enters a RECOVER blend instead of the Phase A instant hand-back: the
## displayed basis slerps (smoothstep, C1) from the frozen space attitude to the gravity-aligned surface FPS pose
## over ORBIT_T_REC seconds, mouse-drivable during the blend, converging from ANY attitude (incl. roll pi) along
## the shortest great-circle arc; ground contact is an extra leave trigger. At alpha=1 the hand-back writes exactly
## the basis already displayed (no jump). Re-leaving PLANETARY mid-blend re-seeds q_bci from the displayed basis
## (always continuous). Default FALSE ⇒ the Phase A INSTANT hand-back. Requires ORBIT_ATTITUDE. Gate G-ORBIT-REC.
const ORBIT_LAND_RECOVER := false
## ORBIT-FRAME tunable (live-tuned): the RECOVER blend duration (s). Consulted only under ORBIT_LAND_RECOVER.
const ORBIT_T_REC := 0.8

## COSMOS SPACE-NAV §7.4 (docs/COSMOS-SPACE-NAV-DESIGN.md) — the O toggle becomes a REAL Keplerian free-coast.
## Pressing O seeds v_bci = v_circ·t̂ (t̂ = the player's YAW-heading tangent ⊥ r̂, PITCH IGNORED) and then each
## physics frame integrates the OrbitalState under GM_dyn/r² gravity — the SAME symplectic coast the SN-FIX #3
## free-fall uses — so a circular seed HOLDS a stable orbit and an off-circular seed evolves into an ellipse /
## decay / escape (KSP-style, emergent from the vector). Fixes the live bug where O set a dev-flight velocity-
## COMMAND that ramped back to rest ("orbits a few seconds then hangs in space") because nothing integrated
## gravity. Movement/thrust input exits to the dev-flight velocity-command (SN-R1 continuity — the coast mirrors
## its BCI velocity into the controller each tick, so there is no jump); dropping into the atmosphere (PLANETARY)
## also exits to the shipped surface/dev path. Per-body generic (reads the dominant body, not a hardcoded Earth).
## Requires SN_DEVNAV (O is a dev-nav toggle) + FACETED. Default FALSE ⇒ BYTE-IDENTICAL: O keeps its shipped
## velocity-command behaviour and no coast state is ever set. Gate G-OCOAST (verify_ocoast.gd).
const ORBIT_COAST := false

const M5C_CORNER := false        # master M5c toggle — default OFF: shipped build unchanged
const M5C_TELEPORT := true       # true = §5 anomaly teleport; false = §8 energy barrier
const CORNER_ZONE_R := 72        # eager-flip zone radius (raw cells about a vertex)   [§4, §7]
const FLIP_HYST_CORNER := 5      # eager flip hysteresis inside the zone               [§4, §7]
const PILLAR_R_CELLS := 3        # pillar angular radius in cells                      [§2.1]
const PILLAR_TOP_UP := 6         # pillar top above the max corner-cell base height    [§2.2]

## 1/sqrt(3): the |z| of every cube corner direction; asin(1/sqrt3) = 35.264 deg is the
## latitude the 8 corners are parked at with the poles-on-face-centres orientation (§5.2).
const INV_SQRT3 := 0.5773502691896258

# Per-face local axes (§1.1). Faces are numbered by outward normal in the body-fixed frame:
# 0:+X 1:-X 2:+Y 3:-Y 4:+Z 5:-Z, with +Z = spin axis (north). Faces 4/5 are polar (face
# centres at the poles, §5.2); faces 0-3 tile the equatorial belt. Stored as integer axis
# triples (each is +/- a unit axis) so the reflection generator below stays exact-integer.
const FACE_N := [
	[ 1, 0, 0], [-1, 0, 0], [ 0, 1, 0], [ 0,-1, 0], [ 0, 0, 1], [ 0, 0,-1],
]  # n^  (outward normal)
const FACE_U := [
	[ 0, 1, 0], [ 0,-1, 0], [-1, 0, 0], [ 1, 0, 0], [ 0, 1, 0], [ 0, 1, 0],
]  # u^  (i axis)
const FACE_V := [
	[ 0, 0, 1], [ 0, 0, 1], [ 0, 0, 1], [ 0, 0, 1], [-1, 0, 0], [ 1, 0, 0],
]  # v^  (j axis)

# COSMOS frozen-epoch / F4 (docs/COSMOS-AUDIT.md §3.2 item 1): container-FREE axis accessors for the
# worker hot path. Indexing the nested `const` Arrays above (`FACE_N[face]` → an inner Array) increments
# that inner Array's copy-on-write refcount, and CONCURRENT `_ref` from the voxel worker pool + the main
# thread corrupts it (Godot array.cpp:61 "!success") → "Out of bounds get index" → the worker crash /
# vox_blocks=0. The flat path never hit this because its const-array reads return INTS (no inner
# refcount). These match-of-literals return a Vector3i VALUE (no container, no refcount), so every
# concurrent direction sample is lock-free by construction. The nested FACE_* consts stay for the
# main-thread-only setup (_gen_edge / corner tables), which never races the worker.
static func _axis_n(face: int) -> Vector3i:
	match face:
		0: return Vector3i(1, 0, 0)
		1: return Vector3i(-1, 0, 0)
		2: return Vector3i(0, 1, 0)
		3: return Vector3i(0, -1, 0)
		4: return Vector3i(0, 0, 1)
		_: return Vector3i(0, 0, -1)

static func _axis_u(face: int) -> Vector3i:
	match face:
		0: return Vector3i(0, 1, 0)
		1: return Vector3i(0, -1, 0)
		2: return Vector3i(-1, 0, 0)
		3: return Vector3i(1, 0, 0)
		_: return Vector3i(0, 1, 0)

static func _axis_v(face: int) -> Vector3i:
	match face:
		4: return Vector3i(-1, 0, 0)
		5: return Vector3i(1, 0, 0)
		_: return Vector3i(0, 0, 1)

# Side ids for the edge-remap tables (§4.2). A "side" is the face edge the window can spill
# across: EAST = past i=N-1 (a=+1), WEST = past i=0 (a=-1), NORTH = past j=N-1 (b=+1),
# SOUTH = past j=0 (b=-1).
const SIDE_EAST := 0   # +i
const SIDE_WEST := 1   # -i
const SIDE_NORTH := 2  # +j
const SIDE_SOUTH := 3  # -j

# Per-body N (cells per face edge) and datum radius R in blocks (§1.1 table). N is 32-aligned.
const BODY_N := {
	"earth": 10016,   # = 313 * 32
	"mars": 5312,
	"mercury": 3840,
	"moon": 2720,
}
const BODY_R := {
	"earth": 6371,
	"mars": 3390,
	"mercury": 2440,
	"moon": 1737,
}

## COSMOS-ORBITAL-O1O4 §3.1 (Part B, O4) — the WALKABLE-MOON master toggle. When true, FacetAtlas.warm_up
## APPENDS the Moon's 6·14² = 1176 facets into the global fid namespace (Earth fids 0..3455 at base 0 stay
## BIT-UNCHANGED; Moon fids at base 3456) and TerrainConfig.facet_profile dispatches Moon fids to the airless
## moon worldgen. Default FALSE ⇒ ONLY Earth rows exist — facet_count/memory/terrain-hash are BYTE-IDENTICAL
## to the pre-refactor tree (the G-O4-OFF / G-O4-EQ keystone). Flipped ON (sed-toggled) only by the multibody
## gate + the future O4c SOI/landing wiring; the Moon soaks DARK (unreachable in-game) until then.
const MULTI_BODY := false

## COSMOS-ORBITAL-O1O4 §3.5 / SPACE-NAV SN6c (Part B, O4c) — the SOI-swap + walkable-Moon LANDING master toggle.
## MULTI_BODY builds the Moon atlas DARK (unreachable); SOI_SWAP is what makes the Moon a REAL destination —
## the dominant gravitational body switches Earth↔Moon at the sphere-of-influence boundary, the player's local
## dynamics (spin frame, GM_dyn, feel-gravity, drag) re-express around whichever body owns the deepest SOI,
## and walking/landing read that body's terrain. It is the ONE flag `player._dominant_body()` consults: OFF ⇒
## `_dominant_body()` returns "earth" unconditionally, so EVERY generalized "earth"→_dominant_body() call site
## resolves to the shipped literal and the walk/nav/coast paths are BYTE-IDENTICAL to Earth-only (the G-O4C-OFF
## keystone). Requires MULTI_BODY (the Moon facets must exist) — asserted lazily by _dominant_body only ever
## returning a body that FacetAtlas registered. Gates G-SOI-SWAP / G-MOON-LAND / G-MOON-WALK (verify_o4c).
## LIVE-ONLY residue: actually flying a transfer to + landing on + walking the Moon (the coast-to-SOI integration
## across 384 k blocks is a real fly, not headless-provable) — baked ON only after MULTI_BODY + a live round trip.
const SOI_SWAP := false

## SPACE-NAV §5.2 — the ±band on the SOI boundary for the dominant-body swap hysteresis (fractional). A craft on a
## grazing trajectory must cross INTO a body's SOI below r_soi·(1−SOI_HYST) to be captured and back OUT above
## r_soi·(1+SOI_HYST) to be released — so it cannot flap bodies at the boundary. 2 % per the design. Data.
const SOI_HYST := 0.02

## SPACE-NAV §8.3 / D-O4-5 — the re-entry pre-warm altitude (blocks) is PER-BODY: an ATMOSPHERE-LESS body has no
## terminal-velocity drag cap, so a ballistic descent arrives 2–3× faster than Earth's braked re-entry and needs a
## deeper pool pre-warm to keep streaming ahead of the lander (≥ 24 s at ~170 b/s). Airless ⇒ 4096; Earth (drag-
## capped) keeps the shipped ORBIT_PREWARM_H. Pure per-body accessor. Earth is the ONLY atmosphere body
## (mirrors OrbitalState.has_atmo — inlined here to keep this core file free of a cosmos-kernel preload cycle).
static func orbit_prewarm_h(body: String) -> float:
	return ORBIT_PREWARM_H if body == "earth" else 4096.0

# ---------------------------------------------------------------------------------------
# COSMOS M1 — the single, easily-flippable planet toggle (docs/COSMOS-PLANET-TOPOLOGY.md §9 M1,
# §3.5, §3.4, §6.1). THIS is the whole safety net: when FLAT_WORLD is true (the default) the
# engine is BYTE-IDENTICAL to the pre-M1 flat world — the terrain adapter is the identity, the
# §3.4 render bend is off, and gravity is the fixed-down stub. Flip it to false to enable the
# curved face-4 window: 3D-noise worldgen sampled along d̂, the camera-centred exact-sphere
# vertex bend (sea horizon at ~147 blocks), and the real toward-centre gravity field.
#
# TO BUILD A CURVED DEMO: change the one line below to `const FLAT_WORLD := false`.
const FLAT_WORLD := true

## COSMOS M5a (docs/COSMOS-M5-ADR.md §2): the TRUE-POSITION render toggle. DEFAULT false → the shipped
## camera-centred CosmosBend sagitta is used (byte-identical to M4). Flip to true to place every vertex at
## its exact sphere position P = (R+y)·d̂ via CosmosTruePlace (kills the §4.6 metric-lie shear everywhere —
## home + strips + corner, via the corner-closure theorem, from the SAME single near volume). A/B-able
## live; requires FLAT_WORLD = false (curved). FLAT_WORLD untouched by M5.
const M5_RENDER := false

## COSMOS R1 (docs/COSMOS-REAL-GEOMETRY-STUDY §8): the REAL-BAKED-GEOMETRY toggle — "the inflated rubber
## cube". DEFAULT false → the shipped CosmosBend shader path (byte-identical to M4). Flip to true to bake
## the FAR layer (+ later water/debris) at TRUE sphere positions on the CPU via CosmosTruePlace.place_true
## (per-tile local origin), cull the far wedge tiles, and level the render with a rigid alignment-root
## transform — NO custom shader crosses the GPU boundary (the class that broke M5a twice). Supersedes the
## M5a placement shader (M5_RENDER); the two are mutually exclusive (M5_REAL wins). Requires FLAT_WORLD =
## false (curved). Bake-parity is a headless gate (baked vertex == place_true == world_point).
const M5_REAL := false

## COSMOS R1 DEV (task #76 follow-up): hide the NEAR chunk render (module VoxelTerrain / fallback streamer)
## so the baked FAR layer can be assessed in isolation. RENDER-ONLY (physics — analytic + GroundCollider —
## is untouched, so you still walk on the invisible near ground). Curved + dev only; default false, no
## gameplay change. Flip to true with a curved (FLAT_WORLD=false) build to inspect the far layer alone.
const DEV_HIDE_NEAR := false

## The cube face the M1 window is homed on (§3.5: "flat world reinterpreted as a face-4 window").
## Face 4 is +Z polar (a pole on the face centre, §5.2) so the window is defect-free lattice.
const HOME_FACE := 4

## The body the M1 window lives on (§1.1 table). Earth: N=10016, R=6371.
const HOME_BODY := "earth"

## Datum surface gravity in m/s² (§6.1). The standard-gravity anchor used to derive GM = g0·R²
## so the field is exactly g0 at the datum (r = 0) and falls off as 1/r² above it.
const SURFACE_GRAVITY := 9.81

## GM (gravitational parameter, in block·m²/s² bookkeeping units) for a body: g0·R² so that
## |gravity| = GM/(R+r)² equals SURFACE_GRAVITY exactly at the datum r = 0 (§6.1).
static func gm_for(body: String) -> float:
	var rr := float(radius_for(body))
	return SURFACE_GRAVITY * rr * rr

# Edge-remap table cache, keyed by N (the affine offsets scale with N). Built on first use.
# ONLY used for a FOREIGN n (a non-home body in a verify/test): the runtime home-body table lives in
# the FROZEN flat array below, which is the lock-free, allocation-free source the voxel worker reads.
static var _edge_cache: Dictionary = {}

# COSMOS frozen-epoch contract (docs/COSMOS-AUDIT.md §3.2 item 1): the home-body edge-remap table,
# built ONCE on the main thread in warm_edge_tables() BEFORE any voxel worker spawns and NEVER
# mutated again. A FLAT PackedInt32Array (24 entries × 7 ints: b, m00, m01, m10, m11, t0, t1) instead
# of the Dictionary-of-Array-of-Dictionary form, so every concurrent worker fold is a pure read of a
# frozen Packed array — lock-free and allocation-free by construction (Godot documents reads of a
# never-written Packed array as thread-safe). This subsumes the pass-1 prewarm AND removes the nested
# container as a memory-corruption candidate (COSMOS-AUDIT §2 #4 / F4). Empty until warm_edge_tables().
const _EDGE_STRIDE := 7                   # ints per (face, side) entry in the flat table
static var _edge_flat: PackedInt32Array = PackedInt32Array()
static var _edge_flat_n := 0             # the n `_edge_flat` was built for (0 = not built)
static var _edge_frozen := false         # true once warm_edge_tables() has published `_edge_flat`

# ---------------------------------------------------------------------------------------
# DVec3 — a minimal three-f64 vector. Deliberately NOT Vector3 (which is f32); the exact
# round-trip gate depends on f64 all the way through the direction math.
# ---------------------------------------------------------------------------------------
class DVec3:
	var x: float
	var y: float
	var z: float

	func _init(px := 0.0, py := 0.0, pz := 0.0) -> void:
		x = px
		y = py
		z = pz

	func length() -> float:
		return sqrt(x * x + y * y + z * z)

	func normalized() -> DVec3:
		var l := length()
		if l == 0.0:
			return DVec3.new()
		return DVec3.new(x / l, y / l, z / l)

	func dot(o: DVec3) -> float:
		return x * o.x + y * o.y + z * o.z

	## Angular distance (radians) to another (assumed unit) direction. Uses acos of the
	## clamped dot — good enough for the "are these two cells one apart?" adjacency check.
	func angle_to(o: DVec3) -> float:
		return acos(clampf(dot(o), -1.0, 1.0))

# ---------------------------------------------------------------------------------------
# The warp (§2). Isolated so it can be swapped later without touching topology/tables.
# ---------------------------------------------------------------------------------------

## The equal-angle (tangent) warp: face parameter a in [-1,1] -> plane coordinate u.
static func warp(a: float) -> float:
	return tan(a * QUARTER_PI)

## Exact inverse of warp() in f64 (tan/atan are inverses to < 1 ULP).
static func unwarp(u: float) -> float:
	return atan(u) / QUARTER_PI

# ---------------------------------------------------------------------------------------
# The two normative functions (§1.2)
# ---------------------------------------------------------------------------------------

## face/cell -> unit direction in the body-fixed frame (f64 scalar math, §1.2). `fi`/`fj`
## are floats so callers can request off-cell or off-face points, but for a lattice cell
## pass the integer indices.
static func face_cell_to_dir(face: int, fi: float, fj: float, n: int) -> DVec3:
	var a := 2.0 * (fi + 0.5) / float(n) - 1.0   # [-1, 1] across the face
	var b := 2.0 * (fj + 0.5) / float(n) - 1.0
	var u := warp(a)                             # THE warp (equal-angle, §2)
	var v := warp(b)
	var nn := _axis_n(face)   # container-free (F4): Vector3i value, no inner-Array refcount race
	var uu := _axis_u(face)
	var vv := _axis_v(face)
	var d := DVec3.new(
		float(nn.x) + u * float(uu.x) + v * float(vv.x),
		float(nn.y) + u * float(uu.y) + v * float(vv.y),
		float(nn.z) + u * float(uu.z) + v * float(vv.z),
	)
	# Normalize IN PLACE (F4): avoid the extra DVec3 `.normalized()` allocates — one fewer RefCounted per
	# column on the worker hot path. Value-identical (same f64 x/l arithmetic).
	var l := d.length()
	if l != 0.0:
		d.x /= l
		d.y /= l
		d.z /= l
	return d

## unit direction -> {face, fi, fj} (§1.2). face = argmax|component|; the warp is inverted
## per axis. Because it recovers u,v as ratios dot(d,u^)/dot(d,n^) and dot(d,v^)/dot(d,n^),
## the normalization factor cancels exactly — this is what makes the round-trip robust.
static func dir_to_face_cell(d: DVec3, n: int) -> Dictionary:
	var face := face_of_dir(d)
	var nn := _axis_n(face)   # container-free (F4)
	var uu := _axis_u(face)
	var vv := _axis_v(face)
	var nc := d.x * float(nn.x) + d.y * float(nn.y) + d.z * float(nn.z)  # dot(d, n^) = 1/L > 0
	var uc := d.x * float(uu.x) + d.y * float(uu.y) + d.z * float(uu.z)  # dot(d, u^) = u/L
	var vc := d.x * float(vv.x) + d.y * float(vv.y) + d.z * float(vv.z)  # dot(d, v^) = v/L
	var u := uc / nc
	var v := vc / nc
	var a := unwarp(u)
	var b := unwarp(v)
	var fi := roundi((a + 1.0) * float(n) * 0.5 - 0.5)
	var fj := roundi((b + 1.0) * float(n) * 0.5 - 0.5)
	return {"face": face, "fi": fi, "fj": fj}

## Continuous (un-rounded) inverse — used by the round-trip test to measure the precision
## margin (how far the recovered float lands from the integer, and thus from the rounding
## boundary). Returns {face, fa, fb} as floats.
static func dir_to_face_cell_f(d: DVec3, n: int) -> Dictionary:
	var face := face_of_dir(d)
	var nn := _axis_n(face)   # container-free (F4)
	var uu := _axis_u(face)
	var vv := _axis_v(face)
	var nc := d.x * float(nn.x) + d.y * float(nn.y) + d.z * float(nn.z)
	var uc := d.x * float(uu.x) + d.y * float(uu.y) + d.z * float(uu.z)
	var vc := d.x * float(vv.x) + d.y * float(vv.y) + d.z * float(vv.z)
	var a := unwarp(uc / nc)
	var b := unwarp(vc / nc)
	return {
		"face": face,
		"fa": (a + 1.0) * float(n) * 0.5 - 0.5,
		"fb": (b + 1.0) * float(n) * 0.5 - 0.5,
	}

## face = argmax|component|, with the sign of the dominant component selecting which of the
## two faces on that axis. Cell centres never lie exactly on an edge/corner (a = (2*fi+1)/N - 1
## is never +/-1 for integer fi), so this is unambiguous for every real cell.
static func face_of_dir(d: DVec3) -> int:
	var ax := absf(d.x)
	var ay := absf(d.y)
	var az := absf(d.z)
	if ax >= ay and ax >= az:
		return 0 if d.x > 0.0 else 1
	elif ay >= az:
		return 2 if d.y > 0.0 else 3
	else:
		return 4 if d.z > 0.0 else 5

## World-space point of a lattice cell (§1.2): P = (R + r) * face_cell_to_dir(...).
static func world_point(face: int, fi: float, fj: float, r: float, radius: float, n: int) -> DVec3:
	var d := face_cell_to_dir(face, fi, fj, n)
	var s := radius + r
	return DVec3.new(d.x * s, d.y * s, d.z * s)

# ---------------------------------------------------------------------------------------
# The global edit key (§1.3): key = face<<40 | i<<26 | j<<12 | (r+2048)
#   3 bits face | 14 bits i | 14 bits j | 12 bits (r+2048)   -> 43 bits, fits int64.
# 14 bits holds N <= 16384 (Earth's 10016 fits); 12 bits holds r in [-2048, +2047].
# ---------------------------------------------------------------------------------------

static func edit_key(face: int, i: int, j: int, r: int) -> int:
	return (face << 40) | (i << 26) | (j << 12) | (r + 2048)

static func key_face(key: int) -> int:
	return (key >> 40) & 0x7

static func key_i(key: int) -> int:
	return (key >> 26) & 0x3FFF

static func key_j(key: int) -> int:
	return (key >> 12) & 0x3FFF

static func key_r(key: int) -> int:
	return (key & 0xFFF) - 2048

static func unpack_key(key: int) -> Dictionary:
	return {"face": key_face(key), "i": key_i(key), "j": key_j(key), "r": key_r(key)}

## The region-key prefix (§1.3): the same layout over region indices (i>>5, j>>5, r/32).
## Every cell in one 32^3 region shares this key; adjacent regions differ. Used to extend
## `region_origin_of` and the ZoneChunk/ZoneBundle stores to (body, face, region_i/j/r).
static func region_key(face: int, i: int, j: int, r: int) -> int:
	var ri := i >> 5
	var rj := j >> 5
	var rr := _floordiv(r, REGION_SIZE)      # floor division, correct for negative r
	return (face << 40) | (ri << 26) | (rj << 12) | (rr + 2048)

# ---------------------------------------------------------------------------------------
# Edge-remap tables (§4.2) — GENERATED at first use from the §1.1 axis table, then cached.
#
# The remap is the RIGID unfold of the extended window (§4.3), NOT the gnomonic
# classification of off-edge cells. Off-edge, a "straight" index line kinks in ground truth
# (§4.6); the design keeps INDICES exact by using an exact D4 (dihedral) index map + integer
# offset, absorbing the kink as a ground-truth metric lie. Generation:
#
#   1. mirror map A->B: the cube reflection R that swaps the two face normals maps A's
#      equal-angle grid onto B's exactly (R is a cube symmetry, so it preserves the whole
#      construction). Sampling three interior cells and classifying R*dir recovers the exact
#      integer affine map {M_mirror, t_mirror} (A's cell <-> its across-edge mirror in B).
#   2. compose with the side's in-range reflection so an OUT-of-range window cell folds to the
#      correct B cell: unfold = mirror . reflect_side.
#
# Each entry: {b:int, m:[m00,m01,m10,m11], t:[t0,t1]} with (i',j') = M*(i,j) + t, r untouched.
# ---------------------------------------------------------------------------------------

## Returns the remap entry for crossing `side` of `face` (Dictionary {b, m, t}) for a given N. Reads
## the FROZEN flat table for the home body (lock-free); a foreign n falls back to the Dictionary cache
## (main-thread verify only — the voxel worker only ever folds at the home-body n).
static func edge_remap(face: int, side: int, n: int) -> Dictionary:
	if n == _edge_flat_n and _edge_flat.size() == 24 * _EDGE_STRIDE:
		var b := (face * 4 + side) * _EDGE_STRIDE
		return {
			"b": _edge_flat[b],
			"m": [_edge_flat[b + 1], _edge_flat[b + 2], _edge_flat[b + 3], _edge_flat[b + 4]],
			"t": [_edge_flat[b + 5], _edge_flat[b + 6]],
		}
	_ensure_edge_table(n)
	return _edge_cache[n][face * 4 + side]

# --- D4 orientation indices (COSMOS-FRAME-ORIENTATION §5.1/§6) -------------------------------------
## The quarter-turn index (0..3) of a C4 rotation matrix `m` = [a,b,c,d] (row-major, det +1): the
## angle atan2(m[2], m[0]) measured in +90° units. Used to express M_win / M_strip / the fold Jacobian
## J as small ints (C4 is abelian, so composing rotations is d4 addition mod 4). d4=1 is +90° — the
## same convention ShapeCodec.rotate_modifier uses.
static func d4_of(m: Array) -> int:
	var q := int(round(atan2(float(m[2]), float(m[0])) / (PI / 2.0)))
	return ((q % 4) + 4) % 4

## The strip fold's D4 quarter-turn taking `from_face`'s lattice → `to_face`'s across their shared edge
## (COSMOS-FRAME-ORIENTATION §6.6 / §5.4). 0 when to_face == from_face (native cell, or a corner wedge
## the canonical fold clamped back onto the home face). Otherwise it is the D4 of the (unique) edge of
## `from_face` whose remap lands on `to_face` — so a single-edge fold and a corner-wedge cell both get
## their strip D4 from the face the fold ACTUALLY RESOLVED to. Total + deterministic on the 24-edge graph.
static func strip_d4_to(from_face: int, to_face: int, n: int) -> int:
	if to_face == from_face or from_face < 0 or to_face < 0:
		return 0
	for side in 4:
		var e := edge_remap(from_face, side, n)
		if int(e["b"]) == to_face:
			return d4_of(e["m"])
	# Not edge-adjacent — must never happen within the extended window (the resolved face is always a
	# direct neighbour of the home face). Warn loudly instead of silently returning 0 (a wrong orientation).
	push_warning("CubeSphere.strip_d4_to: face %d is not edge-adjacent to home %d — returning identity (unexpected)" % [to_face, from_face])
	return 0

## Fold a window cell that has spilled across exactly ONE face edge back to its true global
## (face, i, j). Returns {face, i, j}. In-range cells are the identity. A cell out of range in
## BOTH i and j is a corner quadrant (§5.3) — undefined here (handled at M5); this returns
## {face:-1,...} for that case so callers can detect it.
static func fold_cell(face: int, i: int, j: int, n: int) -> Dictionary:
	var oi := i < 0 or i >= n
	var oj := j < 0 or j >= n
	if not oi and not oj:
		return {"face": face, "i": i, "j": j}
	if oi and oj:
		return {"face": -1, "i": i, "j": j}   # corner quadrant, §5.3 (M5)
	var side := -1
	if i >= n:
		side = SIDE_EAST
	elif i < 0:
		side = SIDE_WEST
	elif j >= n:
		side = SIDE_NORTH
	else:
		side = SIDE_SOUTH
	# Frozen-table fast path (the voxel-worker fold, COSMOS-AUDIT §3.2 item 1): read the affine map
	# straight out of the flat PackedInt32Array by index — no Dictionary/Array allocation, lock-free.
	if n == _edge_flat_n and _edge_flat.size() == 24 * _EDGE_STRIDE:
		var b := (face * 4 + side) * _EDGE_STRIDE
		return {
			"face": _edge_flat[b],
			"i": _edge_flat[b + 1] * i + _edge_flat[b + 2] * j + _edge_flat[b + 5],
			"j": _edge_flat[b + 3] * i + _edge_flat[b + 4] * j + _edge_flat[b + 6],
		}
	var e := edge_remap(face, side, n)
	var m: Array = e["m"]
	var t: Array = e["t"]
	return {
		"face": int(e["b"]),
		"i": m[0] * i + m[1] * j + t[0],
		"j": m[2] * i + m[3] * j + t[1],
	}

# COSMOS-CORNER-CANONICAL (task #69, docs/COSMOS-CORNER-CANONICAL.md): the F8 `oob_seen` fence. Counts ONLY
# a REAL out-of-range — the gnomonic-wrap branch |a| ≥ 2, which never occurs in practice (R_FAR → |a| ≤
# 1.62): a real out-of-range must NEVER pass silently, so verify asserts this stays zero. Because it never
# fires in practice it is never written on the worker path → no worker-written-static race (the audit
# discipline). NOTE (Opus deviation, flagged to team-lead): doc §2.3 also wanted the boundary CLAMP counted
# on this fence, but §7c1 expects the fence zero over the sweep — contradictory, since the a=±1 boundary
# clamp fires routinely on the exact wedge diagonal an integer lattice hits (and, being on the worker hot
# path, a counter for it would be a worker-written static). The clamp is the INTENDED nearest-edge
# projection (not an anomaly), so it is applied silently and NOT counted; the fence keeps its stated
# meaning. c1's fence-zero then holds; c1 separately asserts every fold lands in-range (the clamp working).
static var _corner_fence := 0
static func corner_fence_seen() -> int:
	return _corner_fence
static func reset_corner_fence() -> void:
	_corner_fence = 0

## COSMOS-CORNER-CANONICAL (#69): the CONTENT/key fold. Like `fold_cell`, but the corner quadrant (out of
## range in BOTH axes — which `fold_cell` refuses with face −1, having no single-edge D4 fold) resolves to
## the nearest TRUE global cell of its physical DIRECTION rather than the raw home-face overshoot. In-range
## → identity; single-out → the exact `fold_cell` D4 branch (delegated); double-out → canonicalise by
## POSITION: take the raw gnomonic overshoot direction d̂ = face_cell_to_dir(face, i, j) (UNCHANGED —
## placement/the §4.6 metric lie is out of scope) and project it to its nearest real cell via
## `dir_to_face_cell` (the M0 inverse), clamping i',j' to [0, n−1]. NEVER returns face −1 — every physical
## direction has a nearest real cell. This makes the wedge's COLUMN IDENTITY a pure function of position
## (no home-face argument), so the whole F2-folded feature stack downstream (trees/ore/strata/bedrock/
## smoothing/snow) is home-face-INDEPENDENT → §8.2 restored (docs/COSMOS-CORNER-CANONICAL §2). Pure f64 +
## frozen tables → worker-safe under the frozen-epoch contract; runs ONLY for double-out columns (corner-
## overlapping blocks; zero cost everywhere else). `fold_cell` itself is UNTOUCHED — the −1 sentinel still
## marks the topological "no D4 fold" where refusal is wanted (e.g. `chart.flip`'s corner guard).
static func fold_cell_canonical(face: int, i: int, j: int, n: int) -> Dictionary:
	var oi := i < 0 or i >= n
	var oj := j < 0 or j >= n
	if not oi and not oj:
		return {"face": face, "i": i, "j": j}            # in range → identity (the >99.9% fast path)
	if not (oi and oj):
		return fold_cell(face, i, j, n)                  # single-out → the exact D4 edge fold
	# Double-out (corner quadrant): canonicalise by physical position (§2.1).
	var a := 2.0 * (float(i) + 0.5) / float(n) - 1.0     # face overshoot params (mirror face_cell_to_dir)
	var b := 2.0 * (float(j) + 0.5) / float(n) - 1.0
	if absf(a) >= 2.0 or absf(b) >= 2.0:
		_corner_fence += 1                               # REAL out-of-range: gnomonic wrap — never in practice
	var d := face_cell_to_dir(face, float(i), float(j), n)   # the raw overshoot direction — UNCHANGED
	var c := dir_to_face_cell(d, n)                           # nearest TRUE global cell (M0 inverse)
	var ci := int(c["fi"])
	var cj := int(c["fj"])
	# Clamp the a=±1 boundary (roundi can give n on a neighbour's own edge) to the nearest in-range cell —
	# the intended nearest-cell projection, applied silently (see the fence note above; not counted).
	return {"face": int(c["face"]), "i": clampi(ci, 0, n - 1), "j": clampi(cj, 0, n - 1)}

## Inverse of the edge unfold: given the HOME face and a TRUE global column `(gface, gi, gj)`
## on a NEIGHBOUR face, recover the out-of-range home-face window column `(i, j)` that folds to
## it — the reverse of `fold_cell` for the single-edge strips (§4.3). Returns {found, i, j}. Used
## to place a neighbour-face edit back into the extended window (render/collider) and by the
## home-face flip. Only the 4 direct edges of `home_face` are checked (single-axis strips); a
## corner quadrant (double cover, §5.3 M5) returns found=false. The D4 map has det ±1, so its
## integer inverse is exact.
static func unfold_to_window(home_face: int, gface: int, gi: int, gj: int, n: int) -> Dictionary:
	if gface == home_face:
		return {"found": true, "i": gi, "j": gj}
	for side in range(4):
		var e := edge_remap(home_face, side, n)
		if int(e["b"]) != gface:
			continue
		var m: Array = e["m"]
		var t: Array = e["t"]
		var inv := invert_affine(m, t)
		var im: Array = inv["m"]
		var it: Array = inv["t"]
		var wi: int = im[0] * gi + im[1] * gj + it[0]
		var wj: int = im[2] * gi + im[3] * gj + it[1]
		# Only accept if the recovered window cell is genuinely in THIS side's out-of-range strip
		# (so an ambiguous corner cell reachable from two sides is not mis-claimed).
		var ok := false
		match side:
			SIDE_EAST:  ok = wi >= n and wj >= 0 and wj < n
			SIDE_WEST:  ok = wi < 0 and wj >= 0 and wj < n
			SIDE_NORTH: ok = wj >= n and wi >= 0 and wi < n
			_:          ok = wj < 0 and wi >= 0 and wi < n
		if ok:
			return {"found": true, "i": wi, "j": wj}
	return {"found": false, "i": 0, "j": 0}

## Inverse of a 2D integer affine map {m:[a,b,c,d], t:[t0,t1]} with det(m) = ±1 (a D4 element):
## if (gi,gj) = M·(i,j)+t then (i,j) = M⁻¹·((gi,gj)−t). Exact integers (M⁻¹ = det·adj(M)).
static func invert_affine(m: Array, t: Array) -> Dictionary:
	var a: int = m[0]; var b: int = m[1]; var c: int = m[2]; var d: int = m[3]
	var t0: int = t[0]; var t1: int = t[1]
	var det: int = a * d - b * c                 # ±1 for a D4 element
	# For det = ±1, 1/det == det, so M⁻¹ = det · [[d, −b], [−c, a]] is exact-integer.
	var im: Array = [det * d, -det * b, -det * c, det * a]
	var it: Array = [-(im[0] * t0 + im[1] * t1), -(im[2] * t0 + im[3] * t1)]
	return {"m": im, "t": it}

static func _ensure_edge_table(n: int) -> void:
	if _edge_cache.has(n):
		return
	var table: Array = []
	table.resize(24)
	for face in range(6):
		for side in range(4):
			table[face * 4 + side] = _gen_edge(face, side, n)
	_edge_cache[n] = table

## COSMOS frozen-epoch contract (docs/COSMOS-AUDIT.md §3.2 item 1): build the edge-remap table for
## `n` ONCE on the MAIN thread and FREEZE it into the flat `_edge_flat` PackedInt32Array, BEFORE any
## voxel worker exists. Every subsequent fold (worker or main) is then a pure lock-free READ of a
## never-mutated Packed array — no lazy build, no nested Dictionary/Array container to corrupt (the
## pass-1 crash class AND the F4 corruption candidate are both structurally removed). Called from
## TerrainConfig.warm_up() in module setup(), before the generator/viewer attaches. Idempotent (a
## no-op once frozen for this n). FLAT_WORLD never folds, so it need not (and does not) call this.
static func warm_edge_tables(n: int) -> void:
	if _edge_frozen and _edge_flat_n == n:
		return
	var flat := PackedInt32Array()
	flat.resize(24 * _EDGE_STRIDE)
	for face in range(6):
		for side in range(4):
			var e := _gen_edge(face, side, n)
			var m: Array = e["m"]
			var t: Array = e["t"]
			var b := (face * 4 + side) * _EDGE_STRIDE
			flat[b] = int(e["b"])
			flat[b + 1] = int(m[0]); flat[b + 2] = int(m[1])
			flat[b + 3] = int(m[2]); flat[b + 4] = int(m[3])
			flat[b + 5] = int(t[0]); flat[b + 6] = int(t[1])
	# Publish the fully-built table, then set the guards LAST so no reader ever sees a half-built
	# array (a reader checks `_edge_flat_n` / size before indexing). After this the array is const.
	_edge_flat = flat
	_edge_flat_n = n
	_edge_frozen = true

## Generate one {b, m, t} unfold entry for (face, side) at resolution n.
static func _gen_edge(face: int, side: int, n: int) -> Dictionary:
	# Exit axis (the neighbour's outward normal): the axis you head toward crossing this side.
	var uu: Array = FACE_U[face]
	var vv: Array = FACE_V[face]
	var exit_axis: Array
	match side:
		SIDE_EAST:  exit_axis = uu                     # +u^
		SIDE_WEST:  exit_axis = [-uu[0], -uu[1], -uu[2]]  # -u^
		SIDE_NORTH: exit_axis = vv                     # +v^
		_:          exit_axis = [-vv[0], -vv[1], -vv[2]]  # -v^ (SOUTH)
	var b := _face_of_axis(exit_axis)

	# The cube reflection R that swaps n^_A <-> n^_B: R = I - w w^T with w = n_A - n_B
	# (|w|^2 = 2 for orthogonal unit axes, so the factor 2/|w|^2 = 1 and R is exact-integer).
	var na: Array = FACE_N[face]
	var nb: Array = FACE_N[b]
	var w := [na[0] - nb[0], na[1] - nb[1], na[2] - nb[2]]
	var rmat := _reflection_matrix(w)

	# mirror map A->B: sample three interior cells, classify R*dir, read off the affine map.
	var half := n / 2
	var q0 := _classify_reflected(face, half, half, rmat, n)
	var qi := _classify_reflected(face, half + 1, half, rmat, n)
	var qj := _classify_reflected(face, half, half + 1, rmat, n)
	# columns of M_mirror are the images of the i- and j- unit steps.
	var mm := [
		int(qi["fi"]) - int(q0["fi"]), int(qj["fi"]) - int(q0["fi"]),
		int(qi["fj"]) - int(q0["fj"]), int(qj["fj"]) - int(q0["fj"]),
	]
	var tm := [
		int(q0["fi"]) - (mm[0] * half + mm[1] * half),
		int(q0["fj"]) - (mm[2] * half + mm[3] * half),
	]

	# side reflection (folds the out-of-range coordinate back in range before the mirror):
	#   EAST  (i>=N): i -> 2N-1-i        WEST  (i<0): i -> -1-i
	#   NORTH (j>=N): j -> 2N-1-j        SOUTH (j<0): j -> -1-j
	var mr: Array
	var tr: Array
	match side:
		SIDE_EAST:  mr = [-1, 0, 0, 1]; tr = [2 * n - 1, 0]
		SIDE_WEST:  mr = [-1, 0, 0, 1]; tr = [-1, 0]
		SIDE_NORTH: mr = [1, 0, 0, -1]; tr = [0, 2 * n - 1]
		_:          mr = [1, 0, 0, -1]; tr = [0, -1]

	# unfold = mirror . reflect_side  (apply the side reflection first, then the mirror).
	var comp := _compose(mm, tm, mr, tr)
	return {"b": b, "m": comp["m"], "t": comp["t"]}

## Classify R*face_cell_to_dir(face, i, j) -> {face, fi, fj} (exact integer, cells interior).
static func _classify_reflected(face: int, i: int, j: int, rmat: Array, n: int) -> Dictionary:
	var d := face_cell_to_dir(face, i, j, n)
	var rd := DVec3.new(
		rmat[0] * d.x + rmat[1] * d.y + rmat[2] * d.z,
		rmat[3] * d.x + rmat[4] * d.y + rmat[5] * d.z,
		rmat[6] * d.x + rmat[7] * d.y + rmat[8] * d.z,
	)
	return dir_to_face_cell(rd, n)

## R = I - w w^T for integer axis vector w with |w|^2 = 2. Row-major 3x3 flat array.
static func _reflection_matrix(w: Array) -> Array:
	var m := []
	m.resize(9)
	for p in range(3):
		for q in range(3):
			var iden := 1 if p == q else 0
			m[p * 3 + q] = iden - w[p] * w[q]
	return m

## Compose two 2D affine maps: result = A . B  (apply B first, then A).
static func _compose(am: Array, at: Array, bm: Array, bt: Array) -> Dictionary:
	var m := [
		am[0] * bm[0] + am[1] * bm[2], am[0] * bm[1] + am[1] * bm[3],
		am[2] * bm[0] + am[3] * bm[2], am[2] * bm[1] + am[3] * bm[3],
	]
	var t := [
		am[0] * bt[0] + am[1] * bt[1] + at[0],
		am[2] * bt[0] + am[3] * bt[1] + at[1],
	]
	return {"m": m, "t": t}

## Face index whose outward normal is the given axis vector (+/- unit axis).
static func _face_of_axis(axis: Array) -> int:
	for f in range(6):
		var nn: Array = FACE_N[f]
		if nn[0] == axis[0] and nn[1] == axis[1] and nn[2] == axis[2]:
			return f
	return -1

# ---------------------------------------------------------------------------------------
# Corner tables (§5.2 / §5.3): the 8 valence-3 cube corners.
# ---------------------------------------------------------------------------------------

## Signs of the 8 cube corner directions (sx, sy, sz), each direction = (sx,sy,sz)/sqrt(3).
const CORNER_SIGNS := [
	[ 1, 1, 1], [ 1, 1,-1], [ 1,-1, 1], [ 1,-1,-1],
	[-1, 1, 1], [-1, 1,-1], [-1,-1, 1], [-1,-1,-1],
]

## Unit direction to cube corner k (0..7).
static func corner_dir(k: int) -> DVec3:
	var s: Array = CORNER_SIGNS[k]
	return DVec3.new(float(s[0]) * INV_SQRT3, float(s[1]) * INV_SQRT3, float(s[2]) * INV_SQRT3)

## The 3 faces meeting at corner k, and each face's corner cell (i, j) at that corner, for a
## given N. Returns an Array of 3 dicts {face, i, j}. A corner cell's i is N-1 where the
## corner direction has a positive projection on that face's u^, else 0 (likewise j for v^).
static func corner_cells(k: int, n: int) -> Array:
	var s: Array = CORNER_SIGNS[k]
	var faces := [
		0 if s[0] > 0 else 1,   # the X face
		2 if s[1] > 0 else 3,   # the Y face
		4 if s[2] > 0 else 5,   # the Z face
	]
	var out: Array = []
	for f in faces:
		var uu: Array = FACE_U[f]
		var vv: Array = FACE_V[f]
		var du: int = s[0] * uu[0] + s[1] * uu[1] + s[2] * uu[2]   # sign of corner . u^
		var dv: int = s[0] * vv[0] + s[1] * vv[1] + s[2] * vv[2]   # sign of corner . v^
		out.append({
			"face": f,
			"i": (n - 1) if du > 0 else 0,
			"j": (n - 1) if dv > 0 else 0,
		})
	return out

# ---------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------

## Floor division of integers (GDScript `/` truncates toward zero; this floors for negatives).
static func _floordiv(a: int, b: int) -> int:
	var q := a / b
	if (a % b != 0) and ((a < 0) != (b < 0)):
		q -= 1
	return q

static func n_for(body: String) -> int:
	return int(BODY_N.get(body, 0))

static func radius_for(body: String) -> int:
	return int(BODY_R.get(body, 0))
