# COSMOS FAR-TREES — far-terrain tree rendering, ground to orbit

Status: DESIGN (research phase; build phase follows). Flags: `FP_FAR_TREES` family, all default `false`, byte-identical off.
Author: Fable architect session 2026-08-12. Companion docs: COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md (G2 DEM),
COSMOS-FAR-NEAR-COVERAGE (G3 on-surface hide), COSMOS-FAR-TERMINATOR-DESIGN.md (sun_dir weld law).

---

## 1. Problem

Trees exist in exactly two forms today, with a hard cliff between them:

1. **Near voxel trees** — `TreeGen.block_at` emits real WOOD/LEAF cells inside the near VoxelTerrain,
   which covers `TerrainConfig.near_render_radius()` = `CURVED_RENDER_RADIUS_BLOCKS = 128` blocks
   (`godot/src/world/terrain_config.gd:143,171-176`; wired at `godot/src/world/voxel_module/module_world.gd:381`).
2. **Baked colour texels** — the whole-planet fine map composites `TreeGen.top_decoration` leaf colours
   over the C++ terrain bake (`godot/src/world/facet_tex_baker.gd:2009-2034`), so forests already read
   as green speckle on the far skin and from orbit.

Between 128 blocks and orbit there is **no tree geometry at all**: forests vanish at the near-field edge
and reappear only as flat texel colour. The goal is a per-species tree representation that spans
128 blocks → horizon → orbit, bounded in memory (NEVER-OOM), bounded in draws/verts (web
gl_compatibility, 40 fps target), matching the near voxel trees 1:1 in placement, species, silhouette
and lighting, with no popping at any handoff.

### Scale reality (why this must be procedural + view-dependent)

- Tree lattice: one candidate tree per `G=10`-column grid cell, gated by
  `PATCH_CHANCE 0.30 × TREE_CHANCE 0.45 = 13.5%` then the biome gate (`godot/src/world/tree_gen.gd:20-23,130-138`).
- Per facet (~417-block edge, `cube_sphere.gd:957`): ~41.7² ≈ 1 739 grid cells → ~235 candidate trees.
- Planet: 3 456 facets × 1 739 ≈ 6.0 M grid cells → ~810 k candidates → **~300 k real trees**
  after the biome gate (order-of-magnitude; "effectively millions" of potential sites).
- At 1:1000 a tree is 5–12 blocks tall. From orbit (alt 600+) that is **sub-pixel** — per-tree
  geometry at the top of the ladder is physically meaningless; the top rung must be a canopy/texel
  representation. The fine map already is one.

Therefore: never store the global tree set. Enumerate per-facet, on demand, from the same hashes the
near world uses; instance only the visible bounded set.

---

## 2. Codebase ground truth (what the design must reuse)

### 2.1 The deterministic placement law (MUST be reused verbatim)

`godot/src/world/tree_gen.gd` — everything is hash-of-position, no state:

| Fact | Where |
|---|---|
| One tree per 10×10-column grid cell, jittered base `_base_pos` ∈ [2,7] keeps canopy r≤2 inside the cell → O(1) lookup | tree_gen.gd:3-6, 98-101 |
| Gates: patch hash (salt 11), cell hash (salt 22), then biome | tree_gen.gd:130-138 |
| Species = f(biome, hash): forest 70 % oak / 30 % birch (salt 88), taiga/snowy → spruce, swamp/plains → oak; flag-gated jungle/acacia/cactus under `FP_CLIMATE_BIOMES` | tree_gen.gd:105-125 |
| Trunk heights: oak/birch 4-6 (salt 55), spruce 5-8 (salt 66), jungle 8-11 (salt 121), acacia 4-6 (salt 122), cactus 1-3 (salt 123) | tree_gen.gd:150-154, 280-284, 335 |
| Base = `(bx, height_at(bx,bz), bz)` via `tree_base`; submerged bases (`gy <= SEA_LEVEL`) suppressed | tree_gen.gd:142-146, 169-171 |
| Canopy shapes: oak/birch 3×3 ring + plus cap; spruce r2 diamond skirt + r1 crown; jungle r2 square ×2 + cap; acacia flat r2 disc + cap; cactus 1×1 column | tree_gen.gd:230-338 |
| `MAX_ABOVE_SURFACE = 14` bounds every species | tree_gen.gd:33 |
| `top_decoration(x,z,pcache)` — queryable topmost tree block, already used by the far skin | tree_gen.gd:208-224 |

The far-tree system's per-instance data (position, species, trunk height) is a **pure function of
(gx, gz)** through these same hashes — alignment with near voxel trees is by construction, not by
synchronisation.

### 2.2 The far-tier stack the trees must slot into

All far tiers are children of the one `FacetFarRing` node and inherit its placement transform,
anchor shifts, and SN3 scaled placement (`facet_far_ring.gd:1054-1091, 1230-1234`):

| Tier | Band | Granularity | Notes |
|---|---|---|---|
| Near VoxelTerrain | 0–128 blocks | voxels | real trees via `resolve_cell` (module_world.gd:3658-3675) |
| FacetSmoothV2 (`FP_SMOOTH_V2`) | hop 0–3(4) annulus | 53×53 grid, 8-block chords (CS:1455-1473) | near-fill hop≤1 tiles **sink 6 blocks** (`V2_NEARFILL_SINK`, CS:1509-1510; V2:424,537) |
| FacetOrbitRelief G3 (`FP_ORBIT_RELIEF`) | off-surface priority set, ≤384 tiles | 32 cells/facet = G2 DEM 1:1 (G3:64) | **fully suspends on-surface** (G3:652-653), mesh hidden under `FP_ORBIT_RELIEF_SURFACE_HIDE` (G3:645-651) |
| Far-ring shell (always on) | whole visible cap | 4 cells/facet edge (FR:19) | camera-set emit cap (FR:1126-1139); `FOG_BEGIN = 2200`, `CAMERA_FAR = 9000` (FR:30-31) |
| Fine map skin (`FP_PLANET_MAP`) | everywhere far | 64 texels/facet edge ≈ 6.5 blocks/texel, L8 palette index, ≈13.8 MB (CS:707; facet_tex_baker.gd:1690-1705) | **already bakes canopy texels** via `top_decoration` (facet_tex_baker.gd:2009-2011, 2030-2034) |

On/off-surface predicate: `shell_offsurface()` = camera above `OFFSURFACE_Y` (FR:1106-1107, 2933).

### 2.3 Lighting law (ONE law, shared)

Every tier strings `VoxiLight.shade_glsl()` (`godot/src/world/voxi_light.gd:44-58`) into its inline
shader and computes `voxi_shade(n, sun_dir)` with the **radial normal** `n = normalize(world_pos −
planet_centre)` — explicitly NOT slope shading (user-rejected). `sun_dir` is pushed per frame from the
single hub `world_manager.gd:3496-3538`; newly-built materials must seed from the last live sun via
the `FP_FAR_TERMINATOR_WELD` cache (`TierPlace.note_sun_dir`, FR:4920; V2:333-351) or they freeze at
`(1,0,0)` until the next feed. Far trees follow this law exactly.

### 2.4 Memory-ledger convention

Every tier owns a `total_bytes()`/`resident_bytes()`/`arena_bytes()` method asserted against a hard
`*_BYTES_MAX` const by its verify gate: GRD `resident_bytes()` (global_relief_data.gd:384-390, ~7.5 MB),
G3 `arena_bytes()` (facet_orbit_relief.gd:357-360, ~26.5 MB), FacetTexBaker `total_bytes()`
(facet_tex_baker.gd:2167-2171). Global web ceiling cited repeatedly as **40 MB** (cube_sphere.gd:1862).
Far trees get the same: `FacetFarTrees.total_bytes()` ≤ `FAR_TREES_BYTES_MAX`.

### 2.5 MultiMesh precedent on this exact web export

`godot/src/world/cosmos_border_overlay.gd` extends `MultiMeshInstance3D` and ships live
(`:2, :61-86`) — fixed-size instance pool, per-frame repositioning. So MultiMesh + gl_compatibility +
threaded WASM is **proven in this project**, not a hope. WebGL2 has native instanced rendering
(`glVertexAttribDivisor` is core); Godot's compatibility renderer maps MultiMesh onto it. The known
web MultiMesh issue (#81926) is 2D/RenderingServer-path; the 3D node path is what we use and what
already ships.

---

## 3. Technique survey + recommendation

### 3.1 Candidates

**(a) Camera-facing billboards (spherical/cylindrical).** One quad per tree, rotated to face the
camera (Godot `BILLBOARD_ENABLED` or vertex-shader). Cheapest possible: 4 verts/tree.
Fatal flaw here: **top-down degeneracy**. This game's core loop is walk→fly→orbit as one continuum
([[voxiverse-seamless-scales]]); looking straight down at a forest during ascent is a *primary* view,
and a camera-facing quad seen from above is an edge-on sliver or a flat pancake of wrong silhouette.
Also billboards "swim" (rotate) when the camera strafes at mid distance. Rejected as the sole
technique; acceptable only >≈1 500 blocks where trees are ≤3 px.

**(b) Octahedral / hemi-octahedral baked impostors** (UE-style, Ryan Brucks lineage; Amplify;
three.js `InstancedMesh2` forests). Bake the tree from N view directions into an atlas
(hemi-octa 8×8 = 64 views typical), pick + blend 3 nearest views per frame in the shader.
View-correct from every angle including top-down. Costs: per-species atlas
(e.g. 8×8 views × 128² × RGBA + depth/normal maps → 4-12 MB per species set), a frame-selection +
3-tap blend shader (fine on WebGL2, but the depth-reproject variants need dFdx/depth tricks that are
expensive on gl_compat), and a bake pipeline (offline or viewport-based at runtime).
**Key observation that changes the verdict for VOXIVERSE:** octahedral impostors earn their memory
when the source model has high angular variance (a photoreal oak looks different from every azimuth).
Our trees are **blocky voxel archetypes with 4-fold near-symmetry** — an oak is a 1-block trunk +
3×3 canopy ring + plus cap (tree_gen.gd:230-248). Its silhouette from any azimuth is one of ~2
distinct images; its top-down view is one image. A 64-view atlas would store ~60 near-duplicates.
Overkill: pay the atlas memory + blend shader and get almost nothing over a 3-quad cross.

**(c) Low-res decimated 3D LOD meshes (voxel archetype mini-meshes).** Because near trees are
*already* low-poly (30–80 visible cubes), a face-merged archetype mesh per species is ~100–250 tris
— this is not "decimation", it is the actual asset. MultiMesh-instanced, it is view-correct from
every angle (including top-down and while orbiting past), silhouette-identical to the near tree by
construction, lit by the same radial law, zero texture memory, zero bake pipeline (built once from
`TreeGen.block_at` samples). Cost: tris. 1 024 instances × ~180 tris ≈ 184 k tris — affordable;
8 000 instances would not be.

**(d) Static cross+cap card impostors.** Per tree: 2 vertical crossed quads (X-cross) with the
species side-view texture + 1 horizontal quad at canopy height with the species top-view texture.
12 tris/tree, alpha-scissor (no sorting, works on gl_compat). The horizontal cap quad is precisely
what fixes the top-down problem billboards have — from orbit-ward views the cap reads as the canopy
disc, from the side the X-cross reads as the silhouette. For blocky low-angular-variance trees this
captures ~95 % of what an octahedral atlas would, at ~1 % of the memory and no view-blend shader.
Textures are CPU-rasterised from `TreeGen.block_at` (project the cubes of the archetype onto a 32²
texel grid — deterministic, no viewport, one-time, ~KB).

**(e) Canopy texture / density splat (the flight-simulator answer for orbit).** At distance, stop
representing trees and represent *forest*: colour + stochastic speckle in the ground texture.
**This already exists and ships**: the fine map composites `top_decoration` leaf colours per ~6.5-block
texel (facet_tex_baker.gd:2009-2034), and the tree lattice pitch is 10 blocks, so each tree is ~1-2
texels → forests already read as stochastic canopy speckle from orbit, in the correct biome colours
(`far_palette.gd:172-176, 235-249`). The orbit rung is *extend-don't-fight*: keep it.

### 3.2 Tradeoff table

| Technique | GPU cost/tree | Resident bytes | Top-down correct | Silhouette match to near tree | Web gl_compat | Bake pipeline | Verdict |
|---|---|---|---|---|---|---|---|
| (a) camera-facing billboard | 2 tris | ~50 KB atlas | **NO** | poor (swims) | yes | tiny | reject (orbit views core) |
| (b) octahedral impostor | 2-8 tris + 3-tap blend | **4-12 MB/species-set** | yes | good | shader OK, memory poor | heavy (64 views) | reject: pays for angular variance our blocky trees don't have |
| (c) voxel archetype mini-mesh | ~180 tris | ~60 KB meshes | **perfect** | **exact** | yes (MultiMesh) | none (from TreeGen) | **WINNER near-mid** |
| (d) cross+cap cards | 12 tris | ~50 KB atlas | **yes (cap quad)** | very good | yes (alpha-scissor) | tiny (CPU rasterise) | **WINNER mid-far** |
| (e) fine-map canopy texels | 0 | 0 new (ships today) | yes | n/a (sub-pixel) | yes | ships | **WINNER orbit** |

### 3.3 RECOMMENDATION

**A three-rung hybrid, all rungs driven by the same TreeGen hashes:**

- **Rung 1 (mid): voxel archetype mini-meshes**, MultiMesh-instanced, ~128→448 blocks.
- **Rung 2 (far): cross+cap cards**, MultiMesh-instanced with deterministic hash-thinning,
  ~448→2 400 blocks (into `FOG_BEGIN = 2200` so the fog performs the final dissolve on-surface).
- **Rung 3 (orbit): the existing fine-map canopy texels** — zero new work, zero new bytes.

Octahedral impostors are explicitly rejected for this art style (§3.1b). If the art style ever moves
to high-detail trees, rung 2 upgrades to hemi-octahedral without touching rungs 1/3 — the instancing,
enumeration, caps and gates below are technique-agnostic.

---

## 4. The LOD ladder, exactly

Angular-size arithmetic (1080 px, ~90° FOV → ≈688 px/rad; tree height h≈6-11 blocks):

| Distance | 6-block tree on screen | Representation |
|---|---|---|
| 128 (near edge) | ~32 px | rung 0→1 handoff: archetype mesh (a flat card would visibly be flat at 32 px) |
| 448 | ~9 px | rung 1→2 handoff: cards indistinguishable from meshes at ≤9 px |
| 1 200 | ~3.4 px | hash-thinning begins (keep-fraction ramp) |
| 2 200–2 400 | ~1.7 px + fog | rung 2 dissolves into fog + fine-map texels |
| orbit (alt 600+) | sub-pixel | rung 3: fine-map canopy speckle (ships today) |

### 4.1 Band definitions

```
R0 = TerrainConfig.near_render_radius()      # 128 — the voxel-tree edge (terrain_config.gd:171-176)
D1 = FAR_TREES_MESH_MAX   := 448.0           # rung-1 outer edge
D2 = FAR_TREES_CARD_MAX   := 2400.0          # rung-2 outer edge (≥ FOG_BEGIN 2200)
H_SUSPEND = per-tree rungs suspend when shell_offsurface() (FR:2933) — same law as G3 (G3:652)
```

All bands are **camera distance** (3D, in far-ring frame), so ascent automatically pushes trees down
the ladder — one law covers walking away AND flying up; no separate altitude machinery.

### 4.2 Handoffs (no-pop laws)

- **Rung 0→1 (128):** voxel tree chunks unload at the near view edge; archetype instances dither-fade
  IN over d ∈ [R0, R0+24] via alpha-scissor threshold ramp (per-instance camera distance computed in
  the vertex shader; `INSTANCE_CUSTOM` carries a per-tree hash for the dither phase). Brief
  coexistence at the band edge is masked by the dither; A/B against a gap-instead-of-overlap variant
  in the build phase (open question §10.3).
- **Rung 1→2 (448):** cross-dither over [D1−32, D1+32]: meshes fade out, cards fade in, same dither
  phase per tree → per-pixel handoff, never both fully opaque.
- **Rung 2→3 (1 200→2 400):** *density geomorph by deterministic hash survival*: tree (gx,gz)
  survives at distance d iff `_hash01(gx, gz, SALT_THIN) < keep(d)`, with `keep` ramping 1.0→0.15 over
  [1 200, 2 400]. Deterministic ⇒ the same trees always die first/last — the thinning is stable frame
  to frame, reads as forest density falloff, and no wave of popping sweeps the horizon. Survivors
  shrink-fade into fog; the fine-map speckle (same lattice, same colours) is already underneath.
- **Ascent to orbit:** distance-driven rungs collapse naturally (everything > D2 within ~2 s of
  climb); hard suspend at `shell_offsurface()` flips the whole `FacetFarTrees` node like G3
  (visible = !offsurf mirror of G3:645-651 — inverted: trees show ON-surface, G3 shows OFF-surface).

### 4.3 What each rung stands on (height + sink law)

Tree base Y = `TerrainConfig.height_at(bx, bz)` (exact, via `tree_base` tree_gen.gd:142-146) **minus
the owning tier's sink**: the mid band sits on V2 near-fill tiles which are deliberately sunk
`V2_NEARFILL_SINK = 6.0` blocks at hop≤1 (CS:1509-1510, applied V2:424, 537) — trees placed at exact
height would float 6 blocks. Law: `tree_y = height_at − tier_sink(hop) − BURY`, `BURY := 1.0`
(trunk base buried 1 block absorbs the ≤half-chord DEM/mesh interpolation error of the 8-block V2
grid; mirrors the skirt-drop convention V2:37-40). `tier_sink` reuses the exact V2 constants — one
source of truth, no parallel notion of surface (CLAUDE.md rule 1 analogue).

---

## 5. Architecture: `FacetFarTrees`

New file `godot/src/world/facet_far_trees.gd` (`class_name FacetFarTrees extends RefCounted`),
owned/stepped by `FacetFarRing` exactly like V2 and G3:

- **Construction**: in `FacetFarRing.setup()` beside V2 (FR:503-505), gated `if CubeSphere.FP_FAR_TREES`.
- **Step**: one call from `FacetFarRing._process` beside `_smooth_v2.step(...)` / `_orbit_relief.step()`
  (FR:1283-1291), passing `_load_settled` + stream credit — far trees must respect the
  FP_LOAD_DEFER settle gate like every other far tier (no tree work during fresh-load pile-up).
- **Nodes**: `MultiMeshInstance3D` children of the FacetFarRing node (inherit placement transform,
  anchor shifts FR:1230-1234, SN3 scaled placement FR:1073-1091 — orbit-frame correctness for free):
  - rung 1: one MMI per species (6 max live; cactus/jungle/acacia only under `FP_CLIMATE_BIOMES`) — ≤6 draws;
  - rung 2: **one** MMI total (all species share one 256×64 card atlas; per-instance
    `INSTANCE_CUSTOM` selects the species UV window) — 1 draw.
  - Total added draws: ≤7 (the project fought 204→~6; this is acceptable and capped).

### 5.1 Per-facet tree enumeration (the TreeGen hook)

```
FacetFarTrees.enumerate_facet(fid) -> PackedFloat32Array   # worker-side, cached
  for each grid cell (gx,gz) overlapping the facet:        # ~1 739 cells/facet
      if not TreeGen.has_tree(gx, gz, pcache): continue    # two hash gates first — tree_gen.gd:130-138
      b   = TreeGen._base_pos(gx, gz)                      # tree_gen.gd:98-101
      gy  = TerrainConfig.column_top(b.x, b.y, pcache)     # worker-safe fid-scoped profile (terrain_config.gd:1050,1659)
      if gy <= TerrainConfig.SEA_LEVEL: continue           # same suppression as block_at (tree_gen.gd:169-171)
      sp  = TreeGen._species_for(biome_at(b), gx, gz)      # tree_gen.gd:105-125
      t   = species trunk height (same salts 55/66/121/122/123)
      emit [world_pos (via FacetAtlas.lattice_to_world64, facet_atlas.gd:401), sp, t, hash]
```

Runs on the existing worker machinery (V2's worker-slot pool pattern V2:355-361, or a JobLane token —
[[voxiverse-stream-parallel-design]] one-bg-token law), one facet per job, `pcache` = a `GenCtx`
scoped to `fid` so terrain + trees resolve on the same facet (the exact contract `top_decoration`
documents, tree_gen.gd:206-207). Results cached in an LRU keyed by fid
(`FAR_TREES_CACHE_FACETS := 64` × ~235 trees × 32 B ≈ **0.5 MB**), dwell-evicted like V2/G3
(`EVICT_DWELL_STEPS = 20` convention, V2:363).

Required (tiny) TreeGen change: `_base_pos`/`_species_for` are private; expose a public
`TreeGen.tree_info(gx, gz, pcache) -> Dictionary{base, species, trunk_h}` refactored over the
existing code paths (same pattern as the `top_decoration` refactor, tree_gen.gd:200-207) — **no new
placement logic**, so near/far cannot drift.

### 5.2 Instance-set maintenance

Per step (rate-capped, `FAR_TREES_STEP_MS := 250`): compute the wanted facet set = facets whose
centre is within D2+facet-radius of the camera (reuse the hop-annulus/neighbour machinery,
V2:187-210); enqueue enumeration for missing facets; rebuild the MultiMesh buffers from cached lists,
nearest-first, applying band membership + hash-thinning + caps. Buffer writes are
`multimesh.set_buffer(PackedFloat32Array)` — one upload, no per-instance calls;
`visible_instance_count` for partial fill. Frustum culling: MultiMesh is one AABB — rely on band
radius + Godot's cull of the single node; per-instance frustum culling is NOT attempted (CPU cost >
GPU savings at these counts).

### 5.3 Shaders (inline, per project convention — no .gdshader files exist)

Both rungs: `HEAD + VoxiLight.shade_glsl() + TAIL`, `ALBEDO = base_col * voxi_shade(n, sun_dir)`,
`n = normalize(world_pos − planet_centre)` — the radial terminator law, identical to V2/G3
(V2:288-301, G3:381-407). **Not slope-shaded** (user-rejected). Sun feed: add
`FacetFarRing.set_far_trees_sun_dir` beside the V2/G3 setters (FR:4932-4941), fed from the
world_manager hub (world_manager.gd:3496-3538), seeded from `TierPlace.note_sun_dir`'s last-sun cache
on material build (`FP_FAR_TERMINATOR_WELD` lesson — never seed `(1,0,0)`).

Rung 1 extra: trunk-height variance without per-height meshes — archetype verts carry a UV2 flag
(0 = trunk, 1 = canopy); vertex shader stretches trunk verts and translates canopy verts up by
`INSTANCE_CUSTOM.x = trunk_h − archetype_h`. One mesh per species, exact per-tree heights.

Rung 2 extra: alpha-scissor (`discard` below threshold) — no blend sorting, gl_compat-safe; the
scissor threshold doubles as the dither cross-fade knob (§4.2). Per-instance hue jitter from
`INSTANCE_CUSTOM.y` (±4 % value) breaks the clone look for free.

### 5.4 Archetype + atlas baking (one-time, deterministic, no viewport)

At first flag-on setup, per species: sample `TreeGen.block_at` over the archetype's local bounding
box (median trunk height), producing the cube set; greedy-merge faces → ArrayMesh (~100–250 tris);
CPU-rasterise side + top orthographic projections of the same cube set into a 32² texel window of the
shared card atlas, colours from `BlockCatalog.color_of` (the same source FarPalette resolves from,
far_palette.gd:40-43 — colour-consistent with skin and near blocks by construction). Snow-dusted
spruce variant (optional, `FP_FAR_TREES_SNOW`): second atlas window with `_snow`-lerped canopy,
selected when the tree's column passes the FarPalette snow-line predicate (far_palette.gd:387).
Total bake cost: milliseconds, main thread, once.

### 5.5 Correctness filters

- **No far-over-near protrusion** (#110/#113 lesson): instances are only emitted for trees whose base
  distance > R0 (with the §4.2 fade band); the near region owns its view. On-surface the whole system
  is mid/far-band only; off-surface it suspends entirely (§4.2). Trees additionally sink per §4.3 —
  they can never ride a tier that protrudes, because they stand on the tier's own sunk datum.
- **Edit awareness** (chopped trees must not resurrect at distance): during buffer rebuild, drop any
  tree whose trunk-base cell has an edit-overlay entry (the per-fid edit index from the R4/R5 work
  makes this a cheap per-facet lookup; hook `WorldManager` edit index, not a full `block_id_at` scan).
  P2 scope — the visible window where this matters is 128–448 blocks around a chopped tree.
- **Body gate**: enumeration runs for Earth facets only. The Moon reuses biome ids 11/12/13
  (terrain_config.gd:317-319) which alias B_SAVANNA/B_JUNGLE — the exact enum collision that caused
  the acacia no-collision bug ([[voxiverse-tree-bugs-rootcause]]). The far-tree enumeration must gate
  on body identity BEFORE consulting `_species_for`, not rely on biome ids being unambiguous.

---

## 6. Memory ledger + caps (NEVER-OOM)

| Item | Formula | Bytes |
|---|---|---|
| Rung-1 MultiMesh buffers | 6 species × `FAR_TREES_MESH_INST_MAX := 512` × (12 xform + 4 custom) floats × 4 B | 786 KB |
| Rung-2 MultiMesh buffer | `FAR_TREES_CARD_INST_MAX := 8192` × 16 floats × 4 B | 512 KB |
| Facet tree-list LRU | 64 facets × 256 trees × 32 B | 512 KB |
| Archetype meshes | 6 × ~250 verts × ~36 B + indices | ~70 KB |
| Card atlas | 256×64 RGBA8 (+mips) | ~87 KB |
| **Total** | | **< 2.0 MB** |

`FAR_TREES_BYTES_MAX := 4 << 20` (4 MB hard cap, 2× headroom), asserted by
`FacetFarTrees.total_bytes()` in the gate — the tier convention (§2.4). Against the 40 MB web ceiling
this is a rounding error; the binding budgets are draws (≤7) and tris.

**Frame budget:**

| | draws | worst-case tris |
|---|---|---|
| Rung 1 | ≤6 | 6×512 inst… capped at 1 024 live total × ~180 tris ≈ **184 k** |
| Rung 2 | 1 | 8 192 × 12 tris ≈ **98 k** |

Instance-count arithmetic behind the caps: rung-1 annulus [128,448] holds ~782 candidate sites
(π(448²−128²)/100 × 13.5 %) → ≤ ~400 real trees worst case → 1 024 cap is 2.5× headroom. Rung-2
annulus [448,2 400] holds ~23.6 k candidates worst case (all-forest horizon); the keep(d) thinning
ramp (§4.2) + nearest-first fill bounds the live set under 8 192 deterministically. Overdraw: cards
are ≤9 px at their nearest — alpha-scissor overdraw is negligible; no blended transparency anywhere.

Degrade ladder (in flag order, if measured A/B shows cost): halve `CARD_INST_MAX` → drop rung-1 to
cards → raise thinning ramp start. All caps are consts beside the flag, per the FP family convention
(CS:857-862 pattern).

---

## 7. Flag family (all default `false`, byte-identical off)

Declared in `godot/src/cosmos/cube_sphere.gd` per the registry convention (§2.4 of the flag doc,
CS:857 pattern), each consumed only behind its own guard:

```
FP_FAR_TREES        := false   # master: FacetFarTrees constructed + stepped at all
FP_FAR_TREES_CARDS  := false   # rung 2: cross+cap card band (P0)
FP_FAR_TREES_MESH   := false   # rung 1: archetype mini-mesh band (P1)
FP_FAR_TREES_FADE   := false   # dither cross-fades + hash-thinning ramp (P2; without it, hard band cuts)
FP_FAR_TREES_SNOW   := false   # snow-dusted spruce atlas variant (P3, optional)
+ consts: FAR_TREES_MESH_MAX/CARD_MAX/MESH_INST_MAX/CARD_INST_MAX/CACHE_FACETS/STEP_MS/BYTES_MAX
```

Off-path byte identity: with `FP_FAR_TREES` false, `FacetFarRing.setup` never constructs the object,
no node exists, no step call runs — same inertness pattern as `FP_ORBIT_RELIEF` (FR:4953-4955).

---

## 8. Staged plan P0→P3

**P0 — enumeration + card band (the visibility win).**
`TreeGen.tree_info` refactor; `FacetFarTrees` skeleton under FacetFarRing; worker enumeration + LRU;
card atlas CPU bake; rung-2 MMI (one draw) over [128, 2 400] (rung 1 absent, cards serve the whole
band initially); radial-normal voxi_shade shader + sun feed + weld seed; suspend on
`shell_offsurface()`; caps + ledger. Flags: `FP_FAR_TREES + FP_FAR_TREES_CARDS`.
*Exit: forests visible to the fog line from the ground, matching near trees at the 128 edge.*

**P1 — archetype mini-mesh band.** Per-species face-merged archetypes + trunk-stretch shader;
rung 1 over [128, 448]; cards retreat to [448, 2 400]. Flag: `FP_FAR_TREES_MESH`.
*Exit: the 128-edge handoff is silhouette-exact; top-down flyover reads correct 3D canopies.*

**P2 — no-pop + correctness polish.** Dither cross-fades at both handoffs; keep(d) hash-thinning
ramp; edit-overlay filter (chopped trees stay chopped); A/B overlap-vs-gap at the 128 edge.
Flag: `FP_FAR_TREES_FADE`.
*Exit: no visible pop walking, flying, or ascending; chop test clean.*

**P3 — orbit polish + tuning (mostly measurement).** Confirm rung-3 (fine map) reads as forest from
orbit across biomes; optional `FP_FAR_TREES_SNOW`; live A/B fps + ledger on the deployed web build;
tune caps/bands from measured numbers. *Exit: user eyeball from ground AND orbit; 40 fps held.*

Each stage independently flag-gated, A/B-able, and ledgered — a stage can ship or be pulled alone.

---

## 9. Gate plan (verify_far_trees.gd, per stage)

1. **OFF byte-identity**: full existing suite (verify_faceted, verify_feature, …) unchanged with all
   FP_FAR_TREES* false; grep-level assert no unguarded call sites.
2. **ON placement equality**: for N sample facets × every emitted instance, assert
   `TreeGen.has_tree(gx,gz)` true, base == `tree_base`, species/trunk_h reproduce from the same salts,
   and no instance exists where `has_tree` is false (bijection on the sampled band). Assert zero
   instances with base distance < R0, zero on submerged bases, zero on Moon facets.
3. **Ledger**: `total_bytes() ≤ FAR_TREES_BYTES_MAX`; live instance counts ≤ caps under a worst-case
   all-forest synthetic camera; added draws ≤ 7.
4. **No-protrusion**: on-surface with `shell_offsurface()` false→true transition, node visibility
   flips like G3's (mirror of G3:645-651); no instance inside the near radius (re-assert after a
   simulated crossing — the #110/#113 regression shape).
5. **Lighting weld**: after material rebuild, `sun_dir` uniform ≠ (1,0,0) seed when
   `TierPlace.note_sun_dir` has a live sun (the FP_FAR_TERMINATOR_WELD gate shape, V2:652-658).
6. **No-pop (P2)**: headless camera walk across each band edge; assert instance-set churn per step ≤
   dwell-hysteresis bound (no full-set flips), and thinning survival is deterministic across runs.

---

## 10. Risks + open questions for the build phase

1. **V2/G3 flag reality**: the mid band assumes ground beyond 128 is rendered (V2 near-fill / shell).
   All far relief tiers currently ship flag-off; trees standing on the always-on CELLS=4 shell will
   see larger height mismatch (~104-block cells) than on V2's 8-block chords. The §4.3 sink law
   absorbs ~1-3 blocks, not ~10 on steep slopes. Build phase must measure float/bury on the actual
   deployed tier mix and possibly deepen BURY on high-slope columns (slope from G2 DEM,
   global_relief_data.gd:116-119). Worst case: gate rung-1 band on FP_SMOOTH_V2 being live.
2. **Enumeration cost on 2-core web**: 1 739 grid cells × hash gates per facet is cheap natively but
   web is ×25 ([[voxiverse-gen-class-costs]]); with ~60 facets in the D2 disc the P0 warm-up is
   ~10⁵ hash evaluations. Paced at one facet/job under the settle gate this should vanish, but it is
   unmeasured — the P0 gate must record enumeration ms/facet.
3. **128-edge overlap vs gap**: dither-overlap (recommended) risks brief double-tree; gap risks a
   pop-out flash. A/B in P2; the near voxel view-distance ramp (module_world.gd:431+) may also move
   the effective edge — read the live ramp value, don't hardcode 128.
4. **MultiMesh buffer rebuild hitch**: full 8 192×16-float `set_buffer` per step is ~0.5 MB upload;
   at STEP_MS=250 this is ~2 MB/s — likely fine, but the postport lesson ([[voxiverse-postport-applybound]])
   says main-thread apply/upload is THE web bottleneck; if measured hot, split the rebuild across
   steps (the G3 commit-tiles pattern, G3:469-533).
5. **Shader compile stutter on first flag-on**: WebGL2 compiles shaders on demand; the 2 new
   materials should be warmed during the boot screen prewarm, not on first tree sighting.
6. **Cactus/acacia/jungle are FP_CLIMATE_BIOMES-gated** (tree_gen.gd:117-124): the far system must
   consult the same flag or Earth deserts grow phantom far-cacti with the flag off. Covered by
   reusing `_species_for` verbatim, but the gate must assert it.
7. **Fine-map dependency for rung 3**: FP_PLANET_MAP also ships flag-off. "Trees to orbit" at the top
   rung is only as live as the fine map; if it stays off, orbit forests fall back to the far LUT
   biome colour (still green, but no speckle). The design deliberately requires no new orbit work —
   but the *claim* "canopy from orbit" should be A/B-eyeballed with FP_PLANET_MAP on.
