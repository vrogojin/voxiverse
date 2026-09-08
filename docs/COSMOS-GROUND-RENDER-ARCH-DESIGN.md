# COSMOS GROUND-RENDER ARCHITECTURE — draw calls, chunk-baking, and the Minecraft delta

**Status: INVESTIGATION + DIRECTION (no code changes).**
Owner question: on-ground jerkiness while moving, worst near villages. Measured live:
at rest near a village ~38 fps at **171 draws / 631k prims / 157 objects**; walking near a
village **worst_ms median 150 / p90 238 / max 378** (~7 fps effective), draws swinging 63→152.

Three owner hypotheses are evaluated against the real code (every claim grounded file:line):
1. Are we overloading the main render CPU cycle with too many draw calls?
2. Can't we bake non-terrain structures (villages, player edits) into the chunk-render loop?
3. How are we different from Minecraft (facets + FAR rendering)?

**Verdict in one paragraph:** hypothesis 2 is *already the shipped architecture* — trees,
village houses, and player edits are all baked into the godot_voxel chunk meshes today; the
separate MeshInstances are exclusively the FAR tiers (impostors beyond the 128-block near
radius) plus loose `VoxelBody` debris. Hypothesis 1 is a *symptom*: 63–171 draws costs
roughly 1–4 ms of render-thread CPU on WebGL2/ANGLE — real money at 60 fps, but it cannot
produce 150-ms median frames. The 150/238/378-ms walking frames are **main-thread work
between draws**: movement-threshold far-tier rebuilds (a single far-trees rebuild is a
documented ~50–60 ms, re-armed every 2 blocks walked — `cube_sphere.gd:1093`), streaming
re-mesh/apply churn, and village-area worldgen cost on the streaming path. The highest-
leverage direction is (D) kill per-movement rebuild-and-reupload churn, with (C) cheap
draw-merges as a follow-up; (A) voxelize-into-chunks is a no-op because it is already done.

---

## 1. The near render path — what a "chunk" is and what it costs in draws

### 1.1 godot_voxel module path (the shipped path, `module_in_web=yes`)

`module_world.gd` stands up ONE `VoxelTerrain` + `VoxelMesherBlocky` + a runtime-compiled
generator (`module_world.gd:294–412`):

- **Near radius = 128 blocks** on the faceted planet
  (`terrain_config.gd:171-176`, `CURVED_RENDER_RADIUS_BLOCKS := 128` at `:153`;
  256 only in flat mode / under `FP_FULLRES_256`). Vertical streaming is an ellipsoid,
  ±`VIEWER_VERTICAL_RATIO`·view (`terrain_config.gd:214`).
- **Mesh block = 32³** (`module_world.gd:393`), chosen *specifically* for draw-call
  count: the in-code comment (`module_world.gd:383-392`) records that 16³ blocks at a
  256 view distance produce ~1000+ surface meshes = ~1000+ draw calls, and that on GL
  Compatibility via ANGLE→D3D11 "per-draw-call overhead — not triangle count — is what
  collapses the frame rate", so 32³ cuts the count 4–8×. Data blocks stay 16³.
- **Draws per chunk = number of distinct materials in that block.** `VoxelMesherBlocky`
  emits one surface (= one draw) per distinct material per mesh block. Under
  `FP_ATLAS_MATERIAL` every opaque cube/shape family rides ONE shared 1024² atlas
  material (`block_atlas.gd:1-26`), so a typical block is **1 opaque surface + residuals**:
  sharp-slope per-material surfaces (deliberately not atlassed, `block_atlas.gd:19-22`),
  translucent glass/ice (`block_atlas.gd:23-26` — Stage-3 translucent atlas not built),
  fluids, and seam-carve sentinels. Leaves are IN the opaque atlas (alpha-punched cells,
  `block_atlas.gd:224-298`) — near leaves cost no extra surface.
- **No physics meshes**: `generate_collisions = false` (`module_world.gd:396`); physics
  is analytic (CLAUDE.md), so chunks are render-only.

**Facet pool multiplier (`FP_M1_POOL`/`FP_NB_FULLRES`):** near a facet border the active
`VoxelTerrain` (view 128, ~40 MB budget) is joined by up to `POOL_MAX_NEIGHBOURS := 4`
render-only rotated neighbour `VoxelTerrain`s at view 96 (`module_world.gd:60,90-91`,
`cube_sphere.gd:74`). Each is its own full chunk field → the near-terrain draw count can
roughly double near a corner. This is a facet cost Minecraft does not have.

### 1.2 GDScript fallback path

`world/fallback/chunk_streamer.gd` + `chunk_mesher.gd`: one `MeshInstance3D` per
`TerrainConfig.CHUNK_SIZE` chunk (`chunk_streamer.gd:21-26`). Only used when the module is
absent from the binary; irrelevant to the live site (`module_in_web=yes`) — but it derives
from the same `generated_block` + overlay, so everything in §2 holds for it too.

---

## 2. What IS already baked into the chunk meshes (hypothesis 2: already done)

The owner's core idea — "keep baking non-terrain structures into the same chunk-render
loop" — is the shipped design. All three categories ride the voxel buffers and therefore
the same worker mesh path and the same draw batch as terrain:

### (a) Trees — chunk-baked, including leaves
`TreeGen.block_at` is consulted *inside worldgen* at the resolve_cell airspace sites
(`terrain_config.gd:1397,1433,1474`), so trunk/leaf cells are emitted into the
`VoxelBuffer` by the generator and meshed into the 32³ chunk mesh
(`module_world.gd:3692-3707` — the worker consults TreeGen per column). Near leaves are
atlas cells with punched alpha (`block_atlas.gd:231-258`), not separate geometry.
**Nothing to converge here.**

### (b) Villages — chunk-baked worldgen, not separate meshes
`StructureGen` is deliberately "worldgen (generated cells), NOT edits — mirroring
tree_gen.gd exactly" (`structure_gen.gd:3-9`). `claim_at` (tri-state: fall-through /
authoritative air / house block id, `structure_gen.gd:218-241`) is consulted beside the
terrain stackup at the resolve_cell sites (`terrain_config.gd:1425-1428,1446,1481`), so
walls, floors, roofs, posts, windows and the carve-to-min pad are **generated voxels in
the chunk mesh**. NEAR rendering, analytic physics, DDA raycast, GroundCollider and
`_collapse_unsupported` all see the house through `block_id_at` with zero new machinery
(CLAUDE.md rule 1). The only per-mesh-block draw overhead a village adds is the
**glass window residual surface** (glass is translucent → excluded from the atlas,
`block_atlas.gd:23`) — order +1 draw per 32³ block containing a window, i.e. single-digit
extra draws for a whole village.

### (c) Player edits — chunk-baked via the voxel edit path
`WorldManager._write_cell` records the edit in the sparse `_edits` overlay (gameplay
authority, `world_manager.gd:2224,2272`) AND injects it into the module:
`bulk_inject` groups cells by 16³ data block and writes them through
`get_voxel_tool().set_voxel` / direct buffer writes (`world_manager.gd:4220-4243,4534-4538`;
`module_world.gd:689-698,711-746`). godot_voxel then re-meshes the owning 32³ mesh block
**on the voxel worker**, with the main-thread apply capped
(`voxel/threads/main/time_budget_ms=4`, per the comment at `module_world.gd:388-391`).
Broken/placed blocks are therefore in the chunk mesh, not an overlay renderer.

**Cost/latency of this mechanism (already paid today):** an edit re-meshes a 32³ block
(~1 worker job, tens of ms off-thread, ~1 frame of apply); the trade was accepted
knowingly when mesh blocks went 16³→32³ (`module_world.gd:388-391`). This is exactly the
Minecraft model (edit → section rebuild) and is *not* a jerkiness source at walk time.

### Feasibility verdict per category
| Category | Already in chunk mesh? | Anything left to bake? |
|---|---|---|
| Trees (trunk+leaves, near) | **YES** (worldgen → VoxelBuffer) | No |
| Villages (near) | **YES** (`claim_at` worldgen) | Only the glass residual → Stage-3 translucent atlas |
| Player edits | **YES** (`bulk_inject` → block re-mesh) | No |
| Far impostors (trees/structures/ring/skin) | NO — by design | Cannot be voxelized (see §4) |
| `VoxelBody` debris | NO — free rigid bodies | Must stay separate (they move) |

---

## 3. Draw-call attribution — where 171 draws (rest) / 63–152 (walking) come from

There is no per-tier draw counter in the build (confirm with
`RenderingServer.get_rendering_info` deltas per hidden tier, or the parallel attribution
agent's `?frames=0` runs). The architecture bounds each tier as follows — near a village,
on the ground, faceted flags live:

| Tier | Node structure | Draws (bound / typical on-ground) | Reducible? |
|---|---|---|---|
| **Near terrain, active facet** | 1 `VoxelTerrain`, RID mesh block per 32³ (`module_world.gd:393`) | ~π·(128/32)² surface columns × 1–3 blocks × (1 atlas + residual glass/slope/water surfaces), frustum-culled → **~50–100** | Partly (residual surfaces → translucent atlas; already 32³) |
| **Near terrain, pooled neighbours** | ≤4 `VoxelTerrain` @ view 96 (`module_world.gd:90`) | **0 away from borders, ~20–60 near a corner** | No (facet requirement) |
| **FacetFarRing shell** | whole-cap `_mi` + `6·split²` sector MIs (`facet_far_ring.gd:287-292,2184-2235`): 24 sectors (split 2) or 96 (`FP_SHELL_SECTOR_FINE`, split 4), ~half populated, frustum-culled | **~5–20** | Yes: on-surface the horizon needs far fewer sectors |
| **FacetLodMesher (M2 LOD megablocks)** | per-facet `LodFacet_<fid>` nodes, per-tile MIs + ridge aprons (`facet_lod_mesher.gd:1-30,584,685`), ≤64 facets | **~10–40** | Yes: merge tiles per facet after settle |
| **Skin tier (textured far)** | per-tile MIs, or merged mode "cutting draws ~20×" (`facet_skin_tier.gd:44-49,433`) | **~2–10 merged** | Already has the merge |
| **Smooth tier / Smooth-V2 / orbit relief** | 1–2 MIs each (`facet_smooth_tier.gd:774,1376`, `facet_smooth_v2.gd:621`) | **~2–5** | No (already ~1 draw each) |
| **Far trees** | 1 archetype-mesh MultiMesh + card MMs (`facet_far_trees.gd:468,501`) | **~2–6** | No (already instanced) |
| **Far structures** | ONE merged ArrayMesh, `draw_count() == 1` (`facet_far_structures.gd:5-7,553`) | **1** | No (already merged) |
| **VoxelBody debris** | 1 MI + body each (`physics/voxel_body.gd`) | **0–5** | MultiMesh only if debris counts grow |
| **Sky/clouds/water/HUD/aim** | singles (`cloud_layers.gd`, `cosmos_sky.gd`, …) | **~5–10** | No |

Sum of typicals ≈ 80–170 — consistent with the measured 171 (and 157 objects: mesh blocks
are RenderingServer instances; multi-surface blocks give draws > objects). **The dominant
share is the near voxel terrain itself** — i.e. the tier that is *already* maximally
chunk-batched — followed by far-ring sectors and LOD tiles.

**Why draws swing 63→152 while walking:** mesh blocks stream in/out at the view edge
(each arrival/departure ±1–3 draws), the LOD/skin/far tiers rebuild and double-buffer
around the moving camera, and frustum culling churns as the heading changes. The *swing*
is streaming visibility, not a render-path bug — and the dips to 63 are the same
supply-starvation the see-through/flicker agents are chasing (fewer meshes present =
fewer draws = holes).

---

## 4. Why the far tiers CANNOT ride the chunk meshes (and don't need to)

The separate-mesh tiers all render geometry **outside voxel residency**. The near field
is hard-bounded at 128 blocks (2 web workers, NEVER-OOM); the far tiers cover 128 →
2400+ blocks (`STRUCT_FAR_MAX := 2400`, `cube_sphere.gd:1246`) to planet scale.
Voxelizing a village at 800 blocks into "the chunk loop" would require resident voxel
data + meshing there — that is just widening the near radius, which the 2-thread web
worker pool and the memory ceiling already forbid (`CURVED_RENDER_RADIUS_BLOCKS`
rationale, `terrain_config.gd:148-153`). The far tiers are the *replacement* for chunks
where chunks can't exist, and each is already at or near the 1-draw floor:

- far structures: one merged mesh, per-house bakes cached by `(root, rev)`
  (`facet_far_structures.gd:15-18,455-495`);
- far trees: MultiMesh instancing + card impostors + fine-map texels;
- far ring/skin/smooth: whole-cap or per-sector merged meshes.

What facets add on top of Minecraft's model: per-facet frames (a chunk mesh is only
valid in its facet's lattice basis; a crossing re-places `PlanetRoot` rather than
re-meshing), the pooled rotated neighbour terrains (§1.1), and the seam/carve machinery.
These bound how much *further* the near field could merge — a cross-facet chunk merge is
structurally impossible — but they are not where the frame time is going.

---

## 5. The Minecraft comparison, concretely (hypothesis 3)

Minecraft (Java, modern): 16³ sections, ~1 draw per non-empty section per pass
(opaque + translucent), frustum + cave culled; render distance 12 → **several hundred to
~2000 draws** is normal. Entities/mobs/tile-entities are separate draws. Villages, trees
and player edits are ALL just blocks in section meshes — there is no far field at all
beyond the fog line.

| Tier | Minecraft | VOXIVERSE | Chunk-baked? | Extra draws vs MC | Why |
|---|---|---|---|---|---|
| Terrain near | 16³ sections, 1–2 draw ea | 32³ blocks, 1–3 draw ea | both | **fewer** (32³ + atlas) | same model, coarser |
| Trees near | in section mesh | in chunk mesh (§2a) | both | 0 | same model |
| Village near | in section mesh | in chunk mesh (§2b) | both | +glass residual | translucent atlas unbuilt |
| Player edits | section rebuild | block re-mesh (§2c) | both | 0 | same model |
| Neighbour facets | n/a (flat world) | ≤4 pooled VoxelTerrains | chunks, but *extra fields* | +0–60 near borders | curved planet |
| Beyond fog line | nothing | far ring + skin + LOD + smooth + far trees/structs | no | **+~25–80** | whole-planet render to orbit |
| Debris/entities | entities | VoxelBody | no | comparable | — |

**Answer:** our draw count is *not* fundamentally higher than Minecraft's — it is lower
than a typical MC frame. The extra tiers exist because we render a whole curved planet to
orbit with no impostor swap (LOCKED, [[voxiverse-seamless-scales]]); they add ~25–80
draws that MC never pays, but they are each already merged/instanced near the 1-draw
floor. The structural delta is not "structures are needlessly separate" (they aren't) —
it is (i) the pooled neighbour terrains and (ii) the far-tier *rebuild machinery*, whose
cost is CPU rebuild time, not draw count.

---

## 6. Hypothesis 1 verdict: draws are a real but secondary cost; the jerkiness is rebuild churn

Arithmetic: WebGL2/ANGLE per-draw CPU overhead is of order 10–30 µs (the reason the 32³
decision was taken, `module_world.gd:383-392`). 171 draws ≈ **2–5 ms** render-thread CPU;
63→152 swings move that by ~1–3 ms. At rest that matters for 38→60 fps (together with
631k prims of vertex/fill on gl_compat — likely vsync-ladder territory,
[[voxiverse-web-perf-architecture]]), and known at-rest limiters (telemetry decomposition,
controller floor-trap — [[voxiverse-forest-fps-limiter]]) sit on top. But a **150-ms
median walking frame is 30–75× the total draw budget** — draw submission cannot be the
primary cost. What the architecture *does* predict for walking near a village:

1. **Movement-threshold far-tier rebuilds on the main thread.** Far trees: full rebuild
   re-armed every `FT_DELTA_MIN_MOVE := 2.0` blocks; the flag doc itself states "at a
   5.5 blk/s walk that is ~2 Hz, and each rebuild is the #119 ~50–60 ms"
   (`cube_sphere.gd:1090-1093`; hysteresis flag `FP_FT_MOVE_HYST` widens to 12 blocks,
   `:1100`). Far structures: same 2-block re-arm (`STRUCT_DELTA_MOVE := 2.0`,
   `facet_far_structures.gd:29`), each rebuild re-appending + re-uploading the merged
   band mesh (`_commit_mesh` → `clear_surfaces` + `add_surface_from_arrays`,
   `facet_far_structures.gd:444-453`) — near a village the band is dense, and the
   measured single-frame village bake burst was **3555 ms** before staging
   (`cube_sphere.gd:1272-1274`). A 50–60 ms rebuild landing at 2–4 Hz while walking IS a
   150-ms-median profile once it stacks with streaming.
2. **Village-aware worldgen on the streaming path.** Every newly streamed block near a
   village runs `claim_at`/`has_village`/`house_info` hash chains + the 16-sample site
   stencil per surviving column (`structure_gen.gd:115-140,218-241`) on the 2 web
   workers — slower block supply → the known producer/consumer convoy
   ([[voxiverse-fall-mesh-stall]] LESSON) → apply bursts + visible holes (the 63-draw dips).
3. **Near-presence probe passes each step** (`STRUCT_HOLD_PROBE_CAP := 96` probes/pass
   inside r0, `cube_sphere.gd:1281`; `facet_far_structures.gd:295-323`) — bounded but
   village-proportional.
4. The pre-existing walk baseline: `update_streaming` catch-up ×2 and allocator convoy
   ([[voxiverse-motion-phys-root]], [[voxiverse-walk-perf-root-cause]]).

---

## 7. Ranked architecture directions

**(D) — RECOMMENDED FIRST: movement-churn diet for the far tiers (the actual 150 ms).**
Effort M, risk LOW (all flags exist or are pattern-copies of shipped flags).
- Enable/extend rebuild hysteresis: `FP_FT_MOVE_HYST` (2→12 blocks) and a
  `STRUCT_DELTA_MOVE` analogue; on-ground the far band barely changes per step — scale
  the threshold with band distance (a 2-block camera move is invisible at 300+ blocks).
- Make far-structure commits incremental: today `_rebuild` re-appends every in-band bake
  and re-uploads one big surface (`facet_far_structures.gd:400-453`); with cached bakes
  keyed `(root, rev)` the merged mesh only *needs* re-commit when membership/rev/cull
  state changes — split membership-delta from camera-delta so walking never re-uploads.
- Keep `FP_STRUCT_BAKE_STAGE` (staged bake drain) on-ground, not just de-orbit.
- Confirm first (falsifiable A/B, the [[voxiverse-backstop-diet]] lesson): telemetry
  frame decomposition while walking near a village with far-trees/far-structures steps
  force-frozen vs live. If worst_ms median doesn't collapse, the residual is the
  streaming/gen convoy — go to the stream-pacing lane, not the render lane.

**(C) — SECOND: draw merges where the table says they're reducible.** Effort S–M, risk LOW.
- Stage-3 translucent atlas (glass/ice/water) — removes the per-village glass residual
  surfaces and the water surface split (`block_atlas.gd:23-26`).
- On-surface far-ring sector coarsening (few sectors are visible from the ground;
  the fine 96-split exists for de-orbit, not walking) and post-settle per-facet merge of
  LOD-mesher tiles. Expected total: −20–50 draws ≈ −0.5–1.5 ms — worth having, will not
  fix jerkiness. Do it for the at-rest 38-fps ceiling, after (D) is measured.

**(B) — MultiMesh/instancing for repeated props.** Effort M, risk MED (gl_compat MM
colour-slot trap, [[voxiverse-far-trees-colorfix]]). **Not recommended**: far trees are
already MM, far structures already 1 merged draw, near props are voxels. No target left.

**(A) — Voxelize structures/trees/edits into chunks.** **No-op — already the
architecture** (§2). The only version of this idea with substance is widening voxel
residency (128→256, `FP_FULLRES_256`) so more of the world is chunk-rendered — that is a
worldgen-throughput and memory question (2 web workers, NEVER-OOM), not a draw-call one,
and it *raises* streaming cost while walking.

### What to measure to confirm (before any implementation)
1. Walking-near-village A/B with far-trees + far-structures `step()` frozen: worst_ms
   median 150 → expected < 60 if (D) is right.
2. `RenderingServer.get_rendering_info(TOTAL_DRAW_CALLS_IN_FRAME)` with each tier hidden
   for 1 s (remote-bridge scriptable) → fills the §3 table with live numbers.
3. Same walk with `FP_STRUCT_GEN` off (no village) — separates village worldgen cost
   from village far-tier cost.

---

## 8. Relation to parallel work
Per-frame attribution and LOD flicker are owned by parallel agents; this doc fixes the
architecture frame they attribute into: near field is fully chunk-batched (nothing to
bake that isn't baked), far tiers are at the 1-draw floor but their *rebuild cadence* is
movement-coupled, and the facet pool is the one structural draw multiplier Minecraft
lacks. Any fix that "reduces draw calls" should be checked against §6's arithmetic before
it is credited with fixing jerkiness.
