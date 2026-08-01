# COSMOS FAR-RENDER OVERHAUL — whole-planet map, smooth far terrain, structure impostors

**Status: DESIGN (contract for tonight's unattended build). Author: Fable. Implementer: Opus (main loop).**
Grounded against branch `deploy/cheats-eyeball` @ 7b5de57 (the worktree this doc lives in).

The user's three asks, in their words:
- **A** — no coarse/unbaked zones from orbit: an always-resident whole-planet FINE map tier (+ grow the sharp band past 180 layers).
- **B** — SMOOTH far-terrain geometry (rounded mountains/valleys) **including overhangs/arches/cave-mouths** (true isosurface, not a heightfield) — the high-fidelity option.
- **C** — structures (trees now, user builds later) render far as **boxes wearing baked side-shots**, SSE-culled down to the map skin.

Everything below respects the verified hard constraints:
- gl_compatibility/ANGLE: vertex+fragment only. No compute/geometry/tessellation. Mesh + texture generation is CPU.
- `GL_MAX_ARRAY_TEXTURE_LAYERS` ~2048; `MAX_FRAGMENT_UNIFORM_VECTORS` ~1024 (a 400-entry uniform array already broke the shell live — commit e106c8e → reverted 7b5de57); `MAX_TEXTURE_SIZE` ~4096.
- `VoxelGeneratorCosmos.sample_columns` **serializes on a global lock**; parallel bakes must use the GDScript sampler (`SurfaceShot` / `TerrainConfig.column_profile` — proven parallel in `facet_tex_baker.gd:1643` `_pbm_compute`).
- RAM budget raised to ~1 GB; `FACET_TEX_BYTES_MAX` is already 512 MB (`facet_tex_baker.gd:1741`). NEVER-OOM = bounded, fixed-at-creation.
- Every behaviour behind `const FP_* := false` in `cube_sphere.gd`, byte-identical off (FLAT gate `verify_feature.gd` 6042/0).
- **Deploy discipline**: `scratchpad/deploy_cheats.sh` `git checkout`-reverts `cube_sphere.gd` + `remote_bridge.gd` before sed-ing flags ON — anything in those two files MUST be committed or it silently never ships (this bit us twice; see memory `voxiverse-fallthrough-loc-bug`).

---

## 0. RECOMMENDED SEQUENCE: **A → B → C**

| Item | Impact | Feasibility | Risk | Call |
|---|---|---|---|---|
| A (planet map + band growth) | High from orbit — kills the last coarse zones | **Highest** — every mechanism already exists (pages, `_pbm_*` parallel bake, shader string-splice) | Low | **First** |
| B (smooth far geometry) | **Highest** at mid/low altitude — this is the look the user asked for | Medium — new mesher, but seam law + async build + skin painting all have shipped precedents | Medium (seams) | **Second** |
| C (structure impostors) | High delight, medium coverage (trees already exist top-down in the skin) | Medium — CPU side-raster is genuinely easy; new draw path | Low-medium | **Third** |

Rationale and dependencies:
1. **A first** because it is the lowest-risk, highest-certainty win and two of its pieces are *enablers* for B and C: the band data-texture reverse-map (A1) frees ~720 uniform slots and lets any later tier grow, and the fine planet tier (A3/A4) is the **paint** that B's smooth geometry and C's SSE-cull hand-off both land on. If the night dies after A, the live game is strictly better and nothing is half-wired.
2. **B before C**: B changes what the far surface *is*; C's boxes merely stand on it (they are positioned analytically at `tree_base` radial positions, so they are correct over either geometry — C does **not** block on B, but B is the bigger visual promise and should get the prime hours).
3. **The skin does NOT need repainting for B.** The smooth mesh emits the *same* facet-param `UV`/`UV2` attributes the current far ring emits (`facet_far_ring.gd:2719-2732`), so the ONE shell material (base/band/fine tiers) paints it unchanged. This is the key decoupling that makes A and B independently shippable.
4. Cut-line if the night runs short: ship A complete, B through Phase B3 (smooth heightfield tiers, no edit-overhang patches), C through C2 (tree boxes). B4 (edit overhangs) and C3 (per-instance user-build boxes) are the designated sacrifices — both are additive patches on machinery the earlier phases land.

---

## 1. ITEM A — WHOLE-PLANET FINE MAP TIER + BAND GROWTH

### 1.1 Current state (verified)

- **Base tier**: 6 face pages, `BASE_TEXELS := 16`/facet (`facet_tex_baker.gd:33`) ⇒ 384² RGBA8 pages, ~26 blocks/texel. Always resident, serial budgeted bake (`_bake_base_progressive`, `facet_tex_baker.gd:687`). From alt ~2000 a 26-block texel ≈ 11 px — the "blocky orbit" complaint.
- **Band tier**: `BAND_TEXELS := 512`, `BAND_LAYERS := 180` (`cube_sphere.gd:603-604`), L8 palette-index under FP_SKIN_FLATCOLOR, SSE residency (`_recompute_band_want_sse`, `facet_tex_baker.gd:1086`), **multi-core** GDScript bake (`_update_band_parallel` / `_pbm_compute`, `facet_tex_baker.gd:1595/1643`).
- **The 180 wall**: the shell shader declares `uniform vec2 band_facet[N]; uniform vec2 band_n[N]` (`facet_far_ring.gd:3111-3114`, spliced with `%d = BAND_LAYERS` at `:3171`). Each array element burns a full uniform vec4 slot on ANGLE ⇒ 2×400 = 800 slots + `far_lut` + the rest blew past ~1024 → live breakage → revert 7b5de57. **Uniform arrays cannot scale; a data texture can.**

### 1.2 A1 — band reverse-map data texture (`FP_BAND_META_TEX`)

Replace the two uniform arrays with **one RGBA32F `Texture2D` of size (BAND_LAYERS × 1)**, `filter_nearest`, one texel per layer: `texel[i] = (a, b, Nx, Ny)` — exactly the values `_bm_facet[layer]` / `_bm_n[layer]` hold today (`facet_tex_baker.gd:1320-1321`).

- **Shader change** (string-splice, same discipline as `_apply_flatcolor`, `facet_far_ring.gd:3209`): in `_FLAT_UNIFORMS`/`_BAND_UNIFORMS`, replace the two arrays with `uniform sampler2D band_meta : filter_nearest;`; in the ALBEDO branch replace
  `vec2 _ab = band_facet[_bs]; … vec2 _N = band_n[_bs];` with
  `vec4 _m = texelFetch(band_meta, ivec2(_bs, 0), 0); vec2 _ab = _m.xy; vec2 _N = _m.zw;`
  `texelFetch` on a float texture is core GLSL ES 3.00 — safe on ANGLE. Everything else in the branch is untouched.
- **CPU side**: `FacetTexBaker` keeps `_bm_facet`/`_bm_n` as the source of truth; on epoch bump, instead of WorldManager pushing arrays into shader params (`world_manager.gd:1158` → `set_band_slots`, `facet_far_ring.gd:3441`), the baker writes the packed `PackedFloat32Array` into an `Image` (FORMAT_RGBAF) and `ImageTexture.update()`s it (one tiny 512×1 upload). `set_band_slots` keeps its signature; it just routes to the texture when the flag is on.
- **RGBA32F support**: unfiltered float textures (texelFetch, no linear filtering) are universally supported on WebGL2. Fallback if a driver refuses RGBA32F sampling: pack the same data as RGBA16F (a=0..23, b=0..23, N≤512 all fit in half floats exactly ≤ 2048) — one-line format swap, decide by a boot-time capability probe only if the gate on real ANGLE fails.
- Gate `verify_band_meta.gd`: (i) with the flag on and BAND_LAYERS still 180, the meta texel values equal the reverse-map arrays byte-for-byte for every resident slot; (ii) shader string golden: flag off ⇒ splice output byte-identical to today's; (iii) FLAT 6042/0.

### 1.3 A2 — grow the band (`BAND_LAYERS_BIG := 512`)

With uniforms out of the way the caps left are the 2048-layer array limit and RAM.

- **Call: 512 layers.** 512 × 512² L8 = **134 MB GPU** + 1 staging layer (existing ledger law, `facet_tex_baker.gd:1762-1767`). UV2.y band encoding `64 + layer` (`facet_far_ring.gd:2839`) reaches 576 — exact in float, and the close-up guard `v_slot < 63.5` (`:3182/:3218`) still separates the spaces.
- Implement as `const BAND_LAYERS_BIG := 512` used when `FP_BAND_META_TEX` is on (the array-uniform path physically cannot host it — tie the growth to the flag, never independently). SSE promote reach: raise `BAND_PROMOTE_DIST` (`cube_sphere.gd:607`) 3600 → 8000 so high orbit actually fills the new layers (this was the intent of the reverted e106c8e).
- The `_pbm_*` parallel bake needs **zero changes** — it is already layer-count-agnostic.

### 1.4 A3/A4 — the always-resident FINE planet tier (`FP_PLANET_MAP`)

**Geometry of the tier** — the call: **L8 palette-index pages + `far_lut`, 128 texels/facet edge, stored as a 24-layer Texture2DArray of 1536² sub-pages.**

- 128 texels over a ~417-block facet edge (edge = (π/2·R)/K, `facet_atlas.gd:12-13`) ⇒ **3.26 blocks/texel** — 8× the base tier; at alt 2000 a texel ≈ 1.4 px ⇒ orbit never looks blocky again.
- Whole-face page would be K·128 = 3072² (fits 4096 cap) but a single `update_layer` is then a 9.4 MB upload hitch. **Sub-page split**: each cube face = 2×2 sub-pages of 12×12 facets (12·128 = 1536), layer = `face*4 + qy*2 + qx` ⇒ 24 layers, upload unit 2.36 MB (≈ the shipped band-layer upload we already pay without hitching). Shader addressing from the existing `v_uv`/`v_face`: `vec2 q = floor(v_uv * 2.0); int layer = int(v_face+0.5)*4 + int(q.y)*2 + int(q.x); vec2 luv = fract(v_uv * 2.0);`.
- **L8 + `far_lut`, not RGBA8**: the skin is palette-indexed everywhere else (FP_SKIN_FLATCOLOR `_FLAT_ALBEDO`, `facet_far_ring.gd:3195-3207`); RGBA8 would cost 4× (226 MB GPU + 226 CPU) for zero fidelity gain over the same 14-colour tile-mean palette. L8: **56.6 MB GPU + 56.6 MB CPU staging** (staging retained for progressive re-blits, mirroring the base pages `_pages` model, `facet_tex_baker.gd:39`).
- **No mips** (palette indices must never be filtered). Anti-shimmer: the fine branch fades out when its texel drops sub-pixel — `w_fine = 1.0 - smoothstep(FINE_FADE_LO, FINE_FADE_HI, v_cam)` with LO/HI ≈ where 3.26 blocks ≈ 1.5/1.0 px (≈ 4600/6800 via K_px≈1407, `cube_sphere.gd:731`) — beyond that the mipped RGBA base tier (which exists precisely for this) wins. Cheap, and it kills the sparkle risk at the limb.

**Shader splice** (`FP_PLANET_MAP`, applied inside `_apply_flatcolor`'s chain): add `uniform sampler2DArray fine_map : filter_nearest;` (+ reuse the already-declared `far_lut` — declare-once guard when both flags on). Resolution order in the ALBEDO tail becomes **band → fine → base**: in the non-band else-branch (`facet_far_ring.gd:3205-3207`):
```
int _fid8 = int(texelFetch(fine_map, ivec3(ivec2(luv * 1536.0), layer), 0).r * 255.0 + 0.5);
vec3 _fcol = (_fid8 > 0) ? far_lut[_fid8 - 1] : col;
float _fw = (_fid8 > 0) ? w_fine : 0.0;
ALBEDO = mix(v_col_raw, mix(col, _fcol, _fw), max(wt, _fw)) * v_st;
```
Un-baked fine texels (id 0) fall through to the base/vertex-colour composite exactly like the band's un-baked law — never black (the FP_FACET_TEX alpha-coverage lesson).

**Bake — a SEPARATE parallel tier, not the base sweep.** The base tier's serialized progressive bake + synchronous boot prewarm must not be touched (instant boot depends on it). New machinery `_pfm_*` cloned from the proven `_pbm_*` slots (`facet_tex_baker.gd:1566-1671`):
- Unit = one facet's 128² tile = 16,384 columns through **`SurfaceShot.surface_shot`** (`surface_shot.gd:40` — includes trees; plus the `_edit_snap` override exactly as `_pbm_compute` does at `:1663-1668`), point-sampled at texel centres (3.26-block pitch; no box-average — the palette quantization dominates anyway).
- Dispatch: same `cores−1 ≤ 8` worker slots, **nearest-first from the emit axis** (reuse `_next_base_fid`'s axis ordering, `facet_tex_baker.gd:701`), then a global cursor sweep for the far hemisphere; **never evicted**, cursor-resumable, `_fine_baked: Dictionary` fid→true. ~56.6 M column-shots total ⇒ minutes of background wall-time on the 16-thread web pool; converges to full-planet coverage in one orbit session.
- Commit on main: blit the 128² tile bytes into the sub-page staging Image (`blit_rect`), mark the sub-page dirty; **upload throttle: ≤1 sub-page `update_layer` per 15 frames** (2.36 MB ≈ the band-layer upload we know doesn't hitch).
- Priority: fine-tier slots yield to band-tier slots when both want workers (band = what the player is looking at up close; fine = background convergence). Simple rule: dispatch fine only into worker slots the band dispatcher left idle this frame.

**Memory ledger (A total)**: band 134 MB GPU + fine 56.6 GPU + 56.6 CPU + existing base/id/closeup/detail ≈ 46 MB ⇒ **~295 MB**, under the 512 MB `FACET_TEX_BYTES_MAX`, well under 1 GB with the engine's ~150-200 MB baseline. Extend `total_bytes()` (`facet_tex_baker.gd:1742`) with both tiers; gate asserts the ledger.

**Gates** `verify_planet_map.gd`: G-PM-COVERAGE (bake N facets, coverage monotone, cursor resumes), G-PM-ROUNDTRIP (fine texel index == `far_color_index_of_block`/`far_color_index` recomputed for that column, incl. a tree column and an edit), G-PM-BYTES (ledger arithmetic), G-PM-OFF (flag off ⇒ no allocation, shader golden, FLAT 6042/0).

### 1.5 A risks + fallbacks

| Risk | Mitigation / fallback |
|---|---|
| RGBA32F texelFetch quirk on some ANGLE (A1) | RGBA16F pack (values all exactly representable); worst case RGBA8 dual-texel encode. Gate on live before building A2 on top. |
| 512-layer band = 134 MB allocation fails on a weak client | `BAND_LAYERS_BIG` is one const; ship 512, keep 320 as the tested fallback sed in deploy_cheats.sh. Allocation is at setup (fixed-at-creation) so failure is loud at boot, not mid-session. |
| Fine-tier bake starves band bake | The yield rule above; band always dispatches first. |
| update_layer hitches | 2.36 MB units + 15-frame throttle (measured-equivalent to shipped band uploads). |
| far_lut declared twice (A4 + FLATCOLOR both on) | Splice guard: insert fine uniforms *after* `_FLAT_UNIFORMS` and reference, never redeclare. Golden-string gate catches it headless. |

### 1.6 A phased checklist (each step: implement → gate → FLAT → deploy)

1. **A1** `FP_BAND_META_TEX`: meta texture + shader splice + `verify_band_meta.gd`. Deploy, eyeball band unchanged. *(small, ~1-2 h)*
2. **A2** `BAND_LAYERS_BIG=512` + `BAND_PROMOTE_DIST=8000` under the same flag. Deploy, orbit: sharp band covers the visible disc. *(tiny)*
3. **A3** `FP_PLANET_MAP` data + parallel bake + ledger + G-PM gates (no shader yet — tier invisible). *(2-3 h)*
4. **A4** shader fine branch + upload throttle + fade. Deploy, orbit: no coarse zones anywhere after convergence. *(1-2 h)*

---

## 2. ITEM B — SMOOTH FAR-TERRAIN GEOMETRY (incl. overhangs)

### 2.1 Current state (verified)

The far ring is a **radial heightfield**: per-facet vertex grids at `CELLS := 4` (32 tris/facet, `facet_far_ring.gd:19`), limb ring at 8 (`:21`), backstop at `BACKSTOP_CELLS := 16` (`cube_sphere.gd:300`) — i.e. 26-104-block flat cells, vertices placed radially at `g` (via `TerrainConfig.profile_at_dir`, e.g. `facet_far_ring.gd:2290`, relief law `:1363`), min-enveloped under FP_ENV_ALL (`_env_weld_grid`, `:2308`). The FP_BLOCK_LOD family renders *blocky* megablocks — the exact opposite of what the user now wants; **B supersedes the block-LOD rings visually** (deploy config: smooth flags ON ⇒ block-LOD ring/orbit flags OFF; both stay in the tree, flags arbitrate).

Terrain truth: **heightmap-only, no 3-D caves in worldgen** (`terrain_config.gd:20` — WGC §6.8 staged decision). Overhangs/arches/cave-mouths exist today **only where the player digs/builds** (the `_edits` overlay, `world_manager.gd:209`, per-facet index `_edits_by_fid` `:222`), and in the future cave stage. The isosurface must therefore be architected as *density-general* but *cost-heightfield* in the 99.99 % case.

### 2.2 Algorithm — the call: **Naive Surface Nets** (not marching cubes, not dual contouring, not transvoxel)

- **Surface Nets**: one vertex per surface-crossing cell (placed at the density-weighted centroid of its edge crossings), quads joining the vertices of face-adjacent surface cells. Produces the *smoothest* mesh per triangle of the whole family, has no lookup tables, is trivially parallel, gives analytic-gradient normals, and — decisive here — **on a heightfield density it degenerates to a smooth displaced grid**, so the fast path and the general path produce the same surface class.
- **Marching cubes** rejected: 2-4× the triangles for the same visual smoothness, per-edge vertex dedup across cells is the expensive part on CPU-GDScript, and its LOD stitching (transvoxel) is a 512-case table monster we don't need because our stitch set is exactly "facet borders + pitch changes", which this codebase already solves with a shipped weld law (§2.4).
- **Dual contouring** rejected: needs Hermite data + QEF solves to preserve *sharp* features — we explicitly want them rounded; all cost, negative benefit.

### 2.3 Density source (GDScript, worker-parallel, facet-scoped)

New static class `godot/src/world/far/far_density.gd` (`FarDensity`), pure + deterministic, `GenCtx`-threaded like `SurfaceShot` (`terrain_config.gd:828`):

- **Simple cells (no edit overlap)** — analytic signed height density:
  `d(x,y,z) = y − h_s(x,z)`, with `h_s = max(g, SEA_LEVEL)` sampled at cell-lattice nodes from `TerrainConfig.column_profile` (`terrain_config.gd:727`) — the sea renders as the flat surface exactly like the relief law (`facet_far_ring.gd:1363`). Surface cells are found **per column, not per volume**: only the cells straddling `h_s` at each lattice (x,z) can cross ⇒ O(columns), not O(volume). This is the trick that keeps a 104²-cell facet tile at ~10-21 k cells instead of 1 M.
  Trilinear interpolation of node densities inside the cell is what rounds the mountains; the vertex centroid + gradient normal give C¹-looking relief with zero extra sampling.
- **Complex cells (inside an edit-cluster bbox)** — occupancy density:
  `d = 0.5 − occ`, where `occ` = fraction of the cell's 2^L×2^L×2^L underlying blocks that are solid, sampled from **terrain + edit overlay, EXCLUDING TreeGen** (trees belong to item C): solid iff `edit_override(cell)` if present else `TerrainConfig.generated_block(x,y,z) != AIR` (`terrain_config.gd:2465`). A dug tunnel mouth ⇒ occ dips ⇒ the isosurface smoothly wraps the arch — true overhang handling. Cluster bboxes come from `_edits_by_fid` (§2.7), dilated by one cell.
  For pitch ≥ 8, full 8³ sub-sampling is wasteful — sample a 4×4×4 stratified subset (occ resolution 1/64 is plenty for a smooth far surface).
- Water colour/identity is not density's problem — the skin paints it (§2.6).

### 2.4 LOD tiers, seams, watertightness

**Tier ladder** (per-facet pitch, engaged by the shipped screen-space law `K_px ≈ 1407` px·blocks/dist, `cube_sphere.gd:731`, with `SSE_HYST=1.25` hysteresis `cube_sphere.gd:946`):

| Tier | pitch (blocks) | cells/facet edge | ~tris/facet | residency cap | engages (cam_dist) |
|---|---|---|---|---|---|
| S2 | 4 | 104 | ≤ 21.6 k | active ∪ ring-1, ≤ 9 (`SMOOTH_S2_MAX := 9`) | < ~1400 |
| S3 | 8 | 52 | ≤ 5.4 k | ≤ 25 | < ~2800 |
| S4 | 16 | 26 | ≤ 1.4 k | ≤ 64 | < ~5600 |
| S5 | 32 | 13 | ≤ 340 | ≤ 200 | else (near hemisphere) |
| shipped shell | 104 (CELLS=4) + limb 8 | — | 32 | unchanged | everything beyond / orbit fallback |

Worst-case far-tri budget ≈ 9·21.6k + 25·5.4k + 64·1.4k + 200·0.34k ≈ **488 k tris hard ceiling**; typical (heightfield ⇒ ~2 tris per surface column-cell, many facets partially engaged) ≈ 250-350 k. Draws: merge each tier into **≤ 2 ArrayMeshes** (precedent: `BLOCK_LOD_GLOBAL_DRAWS := 6`, `cube_sphere.gd:779`) ⇒ **+8 draws max**. Web perf history says draws, not tris, were the ceiling (204-draw vsync ladder — memory `voxiverse-web-perf-architecture`); +8 is safe.

**Watertightness — reuse the shipped weld law, don't invent one:**
1. **Same-pitch facet borders**: boundary lattice nodes are computed from **shared canonical samples** keyed to the shared corner-dirs — the edge-canon rule already proven at `facet_far_ring.gd:2302-2346` (`_env_weld_grid`). Both facets compute identical boundary densities ⇒ identical boundary vertices ⇒ weld by construction. Boundary surface-net vertices are additionally **clamped to the shared border plane** (their cell centroid is free only tangentially) so quads from both sides meet edge-exactly.
2. **Pitch transitions** (S2↔S3 etc. and smooth↔shipped-shell): fine-side boundary vertices are **snapped onto the coarse-side chord** — the shipped `_weld_snap_edges` discipline (`facet_far_ring.gd:2293/:2358`) applied to net vertices. MIN-height snapping keeps the no-protrusion direction safe.
3. **Fallback (always on under the flag, costs ~2 %):** a 4-block radial **skirt** dropped along every facet-tile border. At far-tier distances a 4-block skirt is sub-pixel-to-a-few-px and reads as terrain; it guarantees no see-through crack survives an implementation bug on night one. `SMOOTH_SKIRT_BLOCKS := 4.0`.
4. **Overhang cells never cross facet borders**: edit-cluster bboxes are clipped to their owner facet (edits are facet-keyed already — `edit_key`, `facet_atlas.gd:172`), and clusters within one cell of a border render blocky-fallback (excluded from smoothing) rather than risk a cross-facet isosurface stitch. Disclosed limitation, invisible in practice (players rarely build tunnels exactly on a 417-block facet border; if they do, it looks like today).

**Interaction with the near voxel field (no-protrusion):** the smooth tiers render **only outside the near field**. Under and around the player the shipped sunk envelope backstop (`BACKSTOP_SINK`/envelope law) is kept *verbatim* — it exists to never poke through near voxels and its law is min-envelope, which a smooth (both-ways-deviating) surface cannot satisfy. Concretely: the active facet + live-pool facets (the `_excluded`/backstop set, `facet_far_ring.gd:587-596`) are **never** given smooth tiers; S2 starts at ring-1. At the rim, the existing U2 coverage-cull + depth-bias machinery (`FP_FARRING_CULL_COVERED` `cube_sphere.gd:658`, `FP_TIER_DEPTH_BIAS` `:415`) continues to arbitrate. Smooth tiers additionally apply the ε sink (`TierPlace` env ε) at emit like the shipped dense path (`facet_far_ring.gd:2653-2683`).

### 2.5 Normals + lighting

Per-vertex `NORMAL` = normalized density gradient (central differences of `h_s` at ±pitch on the simple path; occupancy gradient on the complex path), rotated into the radial frame. The shell shaders currently shade with the *radial* normal (`n = normalize(wp − centre)`, `facet_far_ring.gd:2949/:2983`) — correct for a sphere at orbit, flat-looking for relief up close. Under `FP_FAR_SMOOTH` the smooth-tier vertices carry true normals and the LIGHT head uses `NORMAL` (world-transformed) instead of the radial `n` **for the smooth surfaces only** (they get their own splice of the same shader string; the shipped shell keeps radial). With `FP_SHADE_UNIFIED` (`cube_sphere.gd:641`, `VoxiLight.SHADE_GLSL`) this automatically matches the near-block lighting law — rounded sunlit slopes, shaded lee sides, correct terminator.

### 2.6 How the map skin paints the smooth geometry (the top-down ↔ 3-D reconciliation)

Every smooth-tier vertex carries the **same attributes the shipped emit writes**: `UV = ((a + s)/K, (b + t)/K)` facet-param, `UV2 = (face, slot)` with slot = close-up / `64+band` / −1 (`facet_far_ring.gd:2705-2732`, band encode `:2839`). The fragment then resolves band → fine → base exactly as on the heightfield — **zero skin/shader work is B-specific** beyond the normal swap in §2.5.

- Tops and slopes: correct by construction (the skin is a top-down map; the param *is* the column).
- **Cliffs/overhang side-walls**: the fragment samples the map at its own (x,z) param ⇒ the column's top colour smears vertically down the face. This is the accepted v1 look (it is what every satellite-textured terrain engine does); it reads as rock/ground shadowing at far distances because the baked `shade` byte already darkens cliff bases (`surface_shot.gd:59-69`). The upgrade path (не tonight) is item C's side-shot tech applied to terrain macro-cliffs.
- Under-surfaces of edit arches sample the same column colour; at far distance an arch is pixels — fine.

### 2.7 Integration points + data flow

- New `godot/src/world/facet_smooth_tier.gd` (`FacetSmoothTier`): owns per-(facet,tier) mesh caches `{fid → {pos, nrm, uv, uv2, idx}}`, LRU per tier, byte ledger `SMOOTH_BYTES_MAX := 96 << 20` (worst case above ≈ 488 k tris × ~44 B/vert ≈ 40 MB; 96 MB gives edit-patch headroom — NEVER-OOM, fixed caps).
- **Build off-thread**: WorkerThreadPool tasks, `cores−1 ≤ 8` slots, cloned from the `_pbm_*` slot pattern (`facet_tex_baker.gd:1595-1671`); one task = one (facet, tier) tile. Commit on main = `ArrayMesh` surface add + tier-mesh swap, ≤ 1 swap/frame (precedent: the far-ring async rebuild `_async_build_worker`/`_swap_in_arrays`, `facet_far_ring.gd:988/:1078`).
- **Driver**: `FacetFarRing._process` (`facet_far_ring.gd:611`) already receives the emit axis, cam distance, active fid each frame; it calls `_smooth.update(axis, cam_dist, active_fid, excluded_set)`. Facets that have a resident smooth tier are dropped from the heightfield emit set the same way `_excluded` pool facets are (`set_excluded`, `:587`) — with the *heightfield-until-ready* rule: a facet leaves the heightfield set only the frame its smooth mesh commits (no gap, no double-draw beyond one crossfade frame).
- **Edit invalidation**: `WorldManager._write_cell` choke point (`world_manager.gd:164`) already indexes edits by fid; add a `_smooth.invalidate(fid)` hook there (rebuild that facet's resident tiers lazily, worker-paced).
- Placement/anchor: meshes are built in ABSOLUTE planet coords like every far-ring cache (`_pos_cache` comment `facet_far_ring.gd:59`) and parented under the ring's node so `shift_anchor`/`_placement_xform` (`:578/:402`) apply unchanged.

### 2.8 Flags, gates

- `FP_FAR_SMOOTH := false` — master: FacetSmoothTier exists, S2-S5 ladder, heightfield-until-ready swap, skirts, normals.
- `FP_FAR_SMOOTH_OVERHANG := false` — the edit-cluster occupancy patches (requires FP_FAR_SMOOTH).
- Consts: `SMOOTH_S2_MAX/S3_MAX/S4_MAX/S5_MAX`, `SMOOTH_SKIRT_BLOCKS`, `SMOOTH_BYTES_MAX`, `SMOOTH_BUILD_SLOTS`.
- Gate `verify_far_smooth.gd`:
  - G-FS-WELD: for adjacent facet pairs (same pitch and S2|S3 mixed), boundary vertex sets are byte-equal / chord-snapped — no crack (assert per shared edge node).
  - G-FS-BOUND: every smooth vertex height ∈ [min g, max g] over its cell footprint + ε (no hallucinated relief, no protrusion above truth).
  - G-FS-DEGEN: on a flat facet the net degenerates to the plane (tri count == 2·cells², all normals radial).
  - G-FS-OVERHANG: dig a 3-wide tunnel through a test ridge via the edit overlay ⇒ the S2 mesh has a through-hole (ray through the tunnel axis hits no smooth tri).
  - G-FS-BYTES / G-FS-OFF (no allocation, FLAT 6042/0).

### 2.9 B risks + fallbacks

| Risk | Mitigation / fallback |
|---|---|
| Seam cracks despite the weld law (the classic isosurface failure) | Three independent layers: shared-canonical boundary samples, chord-snap at pitch changes, **always-on skirts**. If G-FS-WELD still fails on some pair class, ship with skirts only (visually sufficient at far distance) and file the weld for daytime. |
| GDScript mesher too slow on web (×25 penalty history) | Per-tile cost is bounded (S2 tile ≈ 10-21 k cells, column-driven); tiles build over frames on workers; the heightfield-until-ready rule means slowness = delayed beauty, never holes or hitches. If S2 proves too slow live, cap the ladder at S3 (one const). |
| Protrusion/z-fight vs near field at the rim | Smooth never enters the backstop set; ε sink + shipped depth-bias + U2 cull at the rim. Same arbitration that already works for the dense backstop. |
| Player sees smooth↔heightfield pop at tier hand-off | Tiers replace *coarser far geometry* where blocks are ≤ 4 px — same class of transition the shipped LOD already does; hysteresis 1.25 prevents churn. Optional 0.3 s dither (precedent `BLOCK_LOD_DITHER_S`, `cube_sphere.gd:733`) if eyeballing demands it. |
| Memory | Hard per-tier facet caps + ledger + gate. Fixed at creation. |

### 2.10 B phased checklist

1. **B1** `FP_FAR_SMOOTH` data model: `FarDensity` (simple path) + surface-net mesher for one (facet,tier) tile + G-FS-DEGEN/BOUND gates. No render. *(2-3 h)*
2. **B2** render S3 only, ring-1/2, heightfield-until-ready swap + skirts + normals + skin UVs; G-FS-WELD (same-pitch). Deploy, eyeball: rounded mid-distance terrain. *(2-3 h)*
3. **B3** full ladder S2-S5 + pitch-change chord-snap + caps/ledger; G-FS-WELD (mixed-pitch). Deploy. *(2 h)*
4. **B4** `FP_FAR_SMOOTH_OVERHANG` edit-cluster occupancy patches + invalidation hook + G-FS-OVERHANG. Deploy. *(2 h; the designated cut if behind schedule)*

---

## 3. ITEM C — STRUCTURE IMPOSTOR BOXES (baked side-shots)

### 3.1 Enumeration (per facet)

- **Trees (procedural)**: iterate the G=10 tree grid over the facet's core lattice (~42×42 = 1764 grid cells for a 417-block facet): `has_tree(gx,gz,ctx)` → `_base_pos` → `column_top` → species (`tree_gen.gd:130-146/:105`). Expected ~13 % occupancy ⇒ **~200 trees/facet**. All queries are pure hash + `GenCtx`-scoped ⇒ enumeration runs on a worker, cached per facet (`PackedVector3Array` bases + `PackedByteArray` variant ids), invalidated never (deterministic).
- **User-built structures (C3, per-instance)**: cluster the facet's placed-block edits from `_edits_by_fid` (`world_manager.gd:222`) — flood-fill edit keys (placed only, y > surface) into connected clusters, bbox each, split bboxes > 32³. Re-cluster lazily on edit-epoch bump for the active ∪ ring-1 facets only.

### 3.2 Box fit + side-shot bake (CPU, no offscreen GPU — the tricky part, solved analytically)

A tree's voxel set is a *pure function*: `TreeGen.block_at(x,y,z)` over the ≤ 5×(t+3)×5 local volume (`tree_gen.gd:161`). So the bake never needs the world, a camera, or a render target:

- **Variant key = (species, trunk_height)**: oak 4-6, birch 4-6, spruce 5-8 (+ flag-gated jungle 8-11, acacia 4-6, cactus 1-3) ⇒ **≤ 22 variants**. All oaks of height 5 are voxel-identical by construction (the shape functions take only `t`, `dx`, `dz` — `tree_gen.gd:230-338`), so one box per variant is *exact*, not approximate. (Canopy-species hash variation doesn't exist — shapes are deterministic per species+height.)
- **Box fit**: tight AABB of the non-air cells of `block_at` over the local volume (oak/birch: 3×3 canopy ⇒ 3×(t+2)×3; spruce/jungle skirt radius 2 ⇒ 5×…×5; cactus 1×h×1).
- **Side-shot raster** (per face of the box; 4 sides + top, no bottom): orthographic CPU ray-march at **1 texel = 1 block**. For the +X face: image (depth Z × height Y); for each texel scan x from the +X boundary inward; first non-air block → RGBA texel = `BlockCatalog.color_of(id)` (the same tile-mean colour source the skin uses — `surface_shot.gd:51`, `block_textures.gd:64` behind it) × the near-mesher's per-face shade constant (match the near chunk mesher's E/W/N/S/top face factors so the box's lit face equals a real block face) ; no hit → (0,0,0,0). Cost: a 5×16 face = 80 texels × ≤ 5 steps — **the entire 22-variant × 5-face bake is < 10 k block_at calls, one worker task at boot**. Same palette, same lighting family as the terrain skin (the user's fidelity rule).
- **Per-instance bake (C3)** is the identical raster with `block_id_at` (`world_manager.gd:1333`) over the cluster bbox instead of `block_at` — bounded 32×32 faces, LRU'd.

### 3.3 Atlas / memory model

- **Species atlas**: one 256×256 RGBA8 `ImageTexture` (~0.26 MB + CPU staging) packing all ≤ 22×5 face shots (max face 5×13 texels — they're tiny); a static rect table variant→face→uv-rect, built once. NEVER-OOM: fixed.
- **Instance pool (C3)**: `IMPOSTOR_INST_MAX := 64` layers of 64² RGBA8 Texture2DArray = 1 MB, LRU on cluster distance, same slot discipline as the close-up tier (`_cu_slots`, `facet_tex_baker.gd:87-98`).

### 3.4 Draw path

- **True axis-aligned box faces** (user's choice; billboards rejected — parallax under flight looks wrong at 100-800 m and the user explicitly asked for boxes): each instance = 5 quads in the facet tangent frame, up = the base column's radial dir (`FacetAtlas.cell_dir`, `facet_atlas.gd:391`), footprint axes = the facet's a/b lattice axes, base at `tree_base` (`tree_gen.gd:142`) world position.
- **One ArrayMesh per facet** (all its surviving instances merged, ~200 × 5 × 2 = 2 k tris), all impostor facets under **one MeshInstance + one ShaderMaterial** (merge into ≤ 2 draws total, same face-merge discipline as `BLOCK_LOD_ORBIT_DRAWS`, `cube_sphere.gd:877`). Built off-thread (same worker-slot pattern), committed on main.
- **Material**: one spatial shader, `render_mode unshaded, cull_back` + **ALPHA_SCISSOR** (cutout in the opaque queue — no sorting, gl_compat-safe); vertex carries atlas uv-rect; lighting = the same LIGHT-head law as the shell (radial n is fine at these distances; with FP_SHADE_UNIFIED the law matches near blocks). Optional baked-shade multiplier from the canopy `shade` idea is *not* applied (single-owner rule — the box faces already carry face shading).
- **Residency ring**: impostors exist for facets in [near-field rim … SSE-cull radius]. Inner hand-off: the near voxel field renders real tree voxels — impostor facets = exactly the smooth/heightfield far facets outside the backstop set (reuse the same excluded-set signal, §2.7). Outer: per-instance **SSE cull** — screen px = `K_px · box_height / cam_dist`; drop the instance from the mesh when < `IMPOSTOR_MIN_PX := 3.0` (with 1.25 hysteresis). For a 10-block tree that's a ~4700-block radius ⇒ in practice the ring is the active ∪ ring-1-2 facets, ~25 facets × 2 k tris = **≤ 50 k tris, 2 draws**. Beyond, the structure survives as its map-skin texel (the band/fine bake already composites canopy tops — `surface_shot.gd:48-52`; **hand-off is automatic, zero code**).

### 3.5 Flags, gates, budget

- `FP_IMPOSTOR_TREES := false` (C1+C2), `FP_IMPOSTOR_EDITS := false` (C3, requires TREES). Consts: `IMPOSTOR_MIN_PX`, `IMPOSTOR_FACETS_MAX := 32`, `IMPOSTOR_INST_MAX := 64`, `IMPOSTOR_BYTES_MAX := 8 << 20`.
- Memory: species atlas 0.5 MB + instance pool 1 MB + meshes (50 k tris × 36 B ≈ 2 MB) ⇒ **< 8 MB ledger**. Trivial.
- Gate `verify_impostor.gd`: G-IM-ENUM (facet enumeration == brute-force `top_decoration` column scan tree count), G-IM-BAKE (raster determinism: re-raster == stored; a known oak-5 face's texel equals `BlockCatalog.color_of(LEAF)`×face-shade), G-IM-BBOX (every non-air block inside the fitted box), G-IM-SSE (cull monotone in distance, hysteresis no-churn), G-IM-OFF (FLAT 6042/0).

### 3.6 C risks + fallbacks

| Risk | Mitigation |
|---|---|
| Alpha-scissor cutout shimmer at distance | Faces are 1 texel/block with nearest filter — scissor at 0.5; instances are SSE-culled before they get sub-3-px anyway. |
| 200 boxes/facet rebuild churn on crossing | Per-facet meshes are cached (deterministic — never invalidated for trees); crossing just swaps which cached meshes are merged; worker-built. |
| Boxes float/sink on smooth terrain (B changes the surface under them) | Base y = `column_top` truth, box base extended 1 block down (skirt into ground); both geometries pass through the true column height at tree bases (heightfield exactly; smooth within ε — G-FS-BOUND). |
| Edit clusters unbounded (C3) | 32³ bbox split + 64-instance LRU + byte ledger. |

### 3.7 C phased checklist

1. **C1** enumeration + variant bake + atlas + G-IM-ENUM/BAKE/BBOX. No render. *(1-2 h)*
2. **C2** box mesh build + merged draw + SSE cull + ring residency; deploy, eyeball: forests visible from flight altitude as textured boxes, vanishing into map dots at range. *(2 h)*
3. **C3** `FP_IMPOSTOR_EDITS` per-instance clusters + LRU pool. *(stretch; designated cut)*

---

## 4. CROSS-CUTTING

### 4.1 Combined memory ledger (target ≤ 1 GB total process)

| Component | Bytes |
|---|---|
| Existing engine baseline (near field, block-LOD, sky, heap) | ~200-260 MB (measured class) |
| A: band 512 layers L8 GPU + staging | 134.5 MB |
| A: fine planet tier L8 GPU + CPU staging | 113 MB |
| Existing base/id/close-up/detail tiers | ~46 MB |
| B: smooth tier meshes (hard cap) | ≤ 96 MB |
| C: impostors | ≤ 8 MB |
| **Total added** | **≈ 400 MB → ~660 MB worst-case process** ✓ |

All caps are consts, all allocations fixed-at-creation or LRU'd under a ledger, all asserted by gates.

### 4.2 Frame budget (60 fps target)

- Main thread adds: ≤ 1 texture upload/frame (≤ 2.4 MB), ≤ 1 mesh swap/frame, want-set recomputes throttled as today. All sampling/meshing/rasterising on WorkerThreadPool (GDScript sampler — **never** route new bake work through C++ `sample_columns`, it serializes).
- Draws: +8 (smooth tiers) + 2 (impostors) = **+10** on top of today's ~200-draw budget.
- Worker contention order: band > fine-map > smooth tiles > impostors (visible-first).

### 4.3 Flag summary (all `const … := false` in `cube_sphere.gd`, committed — deploy script reverts that file)

`FP_BAND_META_TEX` (+`BAND_LAYERS_BIG`), `FP_PLANET_MAP`, `FP_FAR_SMOOTH`, `FP_FAR_SMOOTH_OVERHANG`, `FP_IMPOSTOR_TREES`, `FP_IMPOSTOR_EDITS`.
Deploy config note: when `FP_FAR_SMOOTH` is sed-ON, sed the block-LOD visual rings (`FP_BLOCK_LOD_RINGS`/`_GLOBAL`/`_ORBIT`, `FP_BLOCKY_FARRING`) OFF — B supersedes them; they remain the rollback look.

### 4.4 Gate roster to add

`verify_band_meta.gd`, `verify_planet_map.gd`, `verify_far_smooth.gd`, `verify_impostor.gd` — plus FLAT `verify_feature.gd` 6042/0 after every phase, and the shader-string golden checks piggyback the existing `verify_shot_prep` pattern. Remember the fresh-worktree `--import` gotcha (memory: `voxiverse-flat-gate-import`).

### 4.5 Audit hooks (what Fable will check against this doc)

1. Byte-off identity per flag (FLAT + golden shader strings).
2. G-FS-WELD/OVERHANG pass logs — not eyeballs — for watertightness and the arch case.
3. The ledger numbers in §4.1 reproduced by `total_bytes()`-class accounting at runtime telemetry.
4. No new `sample_columns` call sites on worker paths (grep).
5. Live: orbit shows zero coarse zones post-convergence (A), mid-altitude mountains rounded with no cracks at facet borders (B), forests as textured boxes that dissolve into map dots (C).

---

## Item A — Fable audit (2026-08-02)

Audited the shipped A1→A4 (commits a7b812f→35d7639) against §1 of this doc. Files cited from this worktree.
Summary: **the core math is right and the threading discipline is sound; the ship-blockers are policy/accounting,
not addressing.** Verdicts: A1 **PASS**, A2 **PASS-WITH-DEFECTS**, A3 **PASS-WITH-DEFECTS**, A4 **CONDITIONAL PASS**.

### A-audit-1 Findings, ranked

**F1 — CONFIRMED (HIGH): the centre-quad artifact is the band tier operating at an altitude where it cannot win,
plus two churn races — NOT a band/fine composite mismatch.**
Diagnosis against the three hypotheses in order:

- **(b) composite mismatch — RULED OUT.** The band branch (`_FLAT_ALBEDO_META`, `facet_far_ring.gd:3225-3238`) and
  the fine branch (`_FINE_ELSE`, `:3212-3219`) apply the *identical* law: `far_lut[id-1]`, weight
  `max(wt, baked?1:0)`, `* v_st`. A committed band facet and a fine facet draw from the same frozen palette under
  the same lighting — neither can render systematically paler than the other.
- **(a)+(c) — CONFIRMED, in combination.** At alt ~2000 with `BAND_PROMOTE_DIST = 8000`
  (`cube_sphere.gd:626`), `_recompute_band_want_sse` (`facet_tex_baker.gd:1106-1123`) wants the nearest
  `band_layers()=240` facets — a ~15×16 quad centred on the nadir = **screen centre**. Three compounding effects
  paint that quad pale:
  1. **Bake starvation.** A band facet costs Nx·Ny ≈ 417² ≈ 174k column-shots vs 128² = 16.4k for a fine tile
     (16× slower), and band dispatch has absolute priority over fine (`_update_band_parallel` step 2 before
     step 3, `facet_tex_baker.gd:1695-1738`). Until commit, a want-set facet carries **no band slot** in the mesh
     (UV2.y is frozen from committed residents only, `facet_far_ring.gd:2836-2841`), so it falls to the
     else-branch; if its fine tile is also unbaked (`_f8==0` — and fine is starved of workers by the same band
     grind) the fallback is the coarse 26-block/texel mip-filtered **base page = the washed-out light colour**.
  2. **Stale-slot stretch.** On ring-exit eviction the layer returns to `_bm_free` and is re-baked for a *new*
     facet (`update_layer` + meta row overwritten at commit, `facet_tex_baker.gd:1684-1691`), but the *old*
     facet's mesh still carries `UV2.y = 64+layer` until the deferred re-emit lands. Its fragments then compute
     `_luv = clamp(v_uv·K − new_ab, 0, 1)` (`facet_far_ring.gd:3229`) → clamps to a single corner texel → the
     whole facet renders as **one solid stretched colour**. At orbital ground-track speed with 240 churning
     layers there is a standing population of such facets at the want-set frontier — i.e. around screen centre.
  3. **Zero benefit.** At cam_dist 2000+ a band texel (1 block) is `K_px/d ≈ 1407/2000 ≈ 0.7 px` — sub-pixel.
     The fine tier (3.26 blocks/texel ≈ 1.4-2.3 px there) already saturates the screen. The band's 42M-column
     grind at mid-orbit buys nothing visible and costs F1.1/F1.2.

  **Exact fix (three parts, in order of importance):**
  1. **Altitude-arbitrate the band**: promote only while the band out-resolves the fine tier — i.e. restore
     `BAND_PROMOTE_DIST` to ≤ 3600 (or gate promote on `cam_dist < ~2800 ≈ 2·K_px`, where a band texel is still
     ≥ 0.5 px). Above that, fine owns the disc — that is exactly what A3/A4 was built for. The 240 layers keep
     their value at low altitude (bigger sharp ring while flying), which was A2's real purpose.
  2. **Sentinel the meta row on evict**: when a slot leaves `_bm_slots`, push `a = -1` into its `band_meta` row
     and have the band branch treat `_m.x < -0.5` as "no band" → fall through to the fine sample. This kills the
     stale-slot stretch (F1.2) structurally, at any altitude.
  3. **Band→fine→base fallback in-shader**: in `_FLAT_ALBEDO_META`, when `_bid == 0` (or the sentinel fires),
     sample `fine_map` instead of falling to `col` — the chain §1.4 specified. Cheap (the fine fetch already
     exists in the else-branch) and makes every band-tier gap invisible.

**F2 — CONFIRMED (HIGH, ledger law): `total_bytes()` was NOT extended for the fine tier.**
`facet_tex_baker.gd:1850-1874` counts base/close-up/id/band (band correctly via `band_layers()`), but has **no
`_fm_on` term**: the fine tier's 24×1536² L8 GPU array (56.6 MB) *and* the permanently-retained `_fm_pages` CPU
staging Images (another 56.6 MB, `facet_tex_baker.gd:1600-1605`) — **113 MB unaccounted**. §1.4 explicitly
required the ledger extension; the NEVER-OOM rule is that ceilings bind on real bytes, and this ledger now lies
by ~113 MB. No runtime assert breached today (512 MB cap, `facet_tex_baker.gd:1849`), but the deferred
G-PM-BYTES gate would have caught it — which is why F7 matters. Fix: add
`if _fm_on: total += 2 * 24 * _fm_page * _fm_page` (+ the 240×4×16 B meta texture for completeness).
*Reconciliation asked for in the audit: live vmem 220 MB vs the ~295 MB design estimate is fully explained by the
band shipping at 240 layers (63 MB) instead of the designed 512 (134 MB): 295 − 71 ≈ 224 MB. No hidden loss.*

**F3 — CONFIRMED (MEDIUM, flag discipline): two consts changed UNCONDITIONALLY.**
`BAND_PROMOTE_DIST 3600→8000` and `BAND_BYTES_MAX 48→70 MB` (`cube_sphere.gd:625-626`) are not gated on
`FP_BAND_META_TEX` — they alter the behaviour of the *already-live* FP_SKIN_SSE band path even with every new
flag OFF (a 180-layer band now promotes/churns out to 8000). §1.3 said "under the same flag". FLAT 6042/0
didn't catch it because FLAT runs all-flags-off. Fix: route promote reach through a
`band_promote_dist()` helper keyed on the flag (and see F1.1 — the 8000 value is wrong anyway).

**F4 — CONFIRMED (MEDIUM, perf): `_next_fine_fid` scans forever after convergence.**
`facet_tex_baker.gd:1610-1631`: once all 3456 facets are baked, every frame the first idle slot still walks the
axis loop (3456 `Dictionary.has` + dot products) *and* the cursor loop (3456 more) before returning −1 —
~7k iterations of WASM GDScript per frame, **permanently** (~0.5-1.5 ms at the shipped 40 fps). One-line fix at
the top: `if _fine_baked.size() >= _base_all: return -1`.

**F5 — RISK (MEDIUM, visual): the §1.4 `w_fine` sub-pixel fade was skipped.**
`_FINE_ELSE` weights the fine sample 1.0 whenever baked, at any distance. The fine map is nearest-filtered L8
with no mips; a fine texel (3.26 blocks) drops below 1 px at cam_dist ≈ 3.26·K_px ≈ **4600** and below 0.5 px by
~9200 — beyond that every pixel nearest-picks one of 4-8 texels and the disc shimmers/crawls under motion,
worst at the limb (anisotropy). The only live verification was alt 1982 (fine ≈ 1.6 px — safely above the
threshold), so the shimmer regime is **unobserved, not absent**. The mipped RGBA base tier underneath exists
precisely for this hand-off: add the designed
`w_fine = 1.0 − smoothstep(4600, 6800, v_cam)` (`mix(col, _fc, w_fine)` in the else-branch) before calling A4 done.

**F6 — DEFECT (LOW-MEDIUM): the fine quadrant select repeats the documented edge-ambiguity mistake.**
`_FINE_ELSE` derives the layer in-shader: `_q = floor(v_uv*2.0)` (`facet_far_ring.gd:3213-3214`). At a face
boundary a fragment can land on exactly `v_uv = 1.0` → `_q = 2` → `_fl = v_face*4 + 6` — outside the face's
4 layers (and up to 29 ≥ the 24-layer array): out-of-range `texelFetch` is *undefined* on GLES3. `_fi` is
clamped; `_q`/`_fl` are not. The codebase itself rejects in-shader `floor(v_uv)` as "edge-ambiguous"
(`facet_far_ring.gd:3019-3021` — the reason close-up slots ride UV2.y). Consequence today: a potential
1-fragment hairline of wrong/undefined colour along cube-face borders. Fix: `_q = min(floor(v_uv*2.0), vec2(1.0))`.

**F7 — CONFIRMED (MEDIUM as a class): both gates were skipped — and they guard the two things that actually broke.**
`verify_band_meta.gd` / `verify_planet_map.gd` do not exist in `godot/src/tools/` (checked). Missing assertions
and their live risk:
- *G-BM parity* (meta texel == `_bm_facet`/`_bm_n` per resident): guards `_push_band_meta` packing — currently
  correct, but any (a,b)/(Nx,Ny) swap regression ships silently.
- *G-BM/G-PM golden-off shader strings*: the splices are `String.replace` — a non-matching anchor is a **silent
  no-op**. The `_FINE_ELSE` splice target (`facet_far_ring.gd:3252`) must byte-match the `_FLAT_ALBEDO_META`
  tail; today it does, but one whitespace edit kills A4 with zero errors. A golden pin is the only headless guard.
- *G-PM-ROUNDTRIP* (fine texel == recomputed `far_color_index` incl. a tree column + an edit): the layer/offset
  algebra (see A-audit-2) is currently proven only by one eyeball at one altitude.
- *G-PM-BYTES*: **would have caught F2 outright.**
- *G-PM-COVERAGE* (monotone, cursor-resume): would also expose F4.

**F8 — RISK (LOW): FP_PLANET_MAP is a silent dead 113 MB without its real dependency chain.**
The shader splices `fine_map` only under `FP_BAND_META_TEX ∧ FP_PLANET_MAP` (`facet_far_ring.gd:3244-3252`),
but the bake arms on `_fm_on = FP_PLANET_MAP ∧ _pbm_on` (`facet_tex_baker.gd:1593`), where
`_pbm_on = FP_SKIN_FLATCOLOR ∧ FP_BAND_BLOCK_MAP ∧ ¬FP_BAND_SHOT ∧ FP_TEX_BAKE_WORKER(+lane) ∧ FP_SKIN_SSE`
(`:251-258`, `:1580`). So META-off + PLANET-on allocates and bakes the full 113 MB tier that can never render;
the `cube_sphere.gd` comment claims only "Requires FP_SKIN_FLATCOLOR". Fix: make `_fm_on` also require
`FP_BAND_META_TEX` + document the chain (a deploy-sed one-flag-off mistake currently fails silently and
expensively).

**F9 — NITS (LOW):**
- `_FLAT_ALBEDO_META` dropped the `_bs < N` upper-bound guard the array path has (`facet_far_ring.gd:3198` vs
  `:3226`); with the sentinel meta row `_N=(0,0)`, `clamp(x, 0, _N−1)` is `clamp` with lo>hi — undefined in GLSL.
  Unreachable today (mesh never carries un-committed slots) but latent; F1-fix-2's sentinel check subsumes it.
- Comment drift: `band_layers()` doc says "512 … else … 180" while `BAND_LAYERS_BIG=240`
  (`cube_sphere.gd:620-621` vs `:618`); the BAND_LAYERS_BIG doc line is orphaned above the FP_PLANET_MAP block (`:609`);
  `_push_band_meta` says "512×1" and "~400 layers" (`facet_far_ring.gd:3515-3516`).
- `_setup_fine_map` is not re-entrant — a second `set_job_lane()` call would double-append `_fm_pages`
  (`facet_tex_baker.gd:1592-1607`).
- `_fine_commit` size-mismatch returns without marking baked → infinite re-dispatch of a failing facet
  (`facet_tex_baker.gd:1633-1635`). Benign today, unbounded by design.

### A-audit-2 What was verified CORRECT (the audit's task 1/3/4 checks)

- **Fine round-trip addressing (task 1): PASS, byte-exact.** `v_uv = UV` spans the whole cube face 0..1 (the
  base tier samples `texture(base_map, vec3(v_uv, v_face))`, `facet_far_ring.gd:2991/2997`); K=24
  (`facet_atlas.gd:12`). `_decode` gives fid → (face, a, b) with a↔u, b↔v — the same convention the
  live-verified band uses (`_bm_facet[layer] = (d[1], d[2])` at `facet_tex_baker.gd:1689` feeding
  `v_uv.x·K − a` at `facet_far_ring.gd:3229`). Layer: `_fine_commit`'s `face*4 + (b/12)*2 + (a/12)`
  (`facet_tex_baker.gd:1636-1639`) ≡ shader `_fl = v_face*4 + floor(v_uv.y*2)*2 + floor(v_uv.x*2)`
  (`facet_far_ring.gd:3213-3214`). Offset: for u ∈ [a/24, (a+1)/24), `fract(2u)·1536` spans exactly
  `[(a%12)·128, (a%12)·128+128)` — the `blit_rect` destination (`facet_tex_baker.gd:1641`). Tile interior:
  `_pbm_compute` writes row-major `bytes[by·tex + bx]` with `s=(bx+0.5)/nx` over the same
  `facet_planar_corner` bilerp the mesh uses, and fine forces `nx=ny=tex=128` → full-facet span, matching
  `texelFetch(x,y)` row order. Only the `v_uv==1.0` edge case escapes (F6).
- **Thread safety (task 4): PASS.** `_pbm_mode[i]` is written on main only in the two dispatch sites
  (`facet_tex_baker.gd:1712`, `:1733`) strictly before `add_task`, read by the worker after spawn (`:1755`) —
  the same happens-before discipline as `_pbm_fid`. Reap does `wait_for_task_completion` (memory barrier,
  `:1675`) before touching results; workers write only `_pbm_bytes[i]` under `_pbm_mutex` (`:1777-1779`);
  `_fm_pages`/`_fine_baked`/`_fm_dirty`/`update_layer` are main-thread-only (`_fine_commit` runs in reap).
  `_next_fine_fid`'s scan cost during convergence is acceptable (idle-slot-gated); post-convergence it is F4.
- **Byte-off integrity (task 3): PASS except F3.** With the three flags off: `_apply_flatcolor` takes the
  unchanged legacy path with `%d` pinned to `BAND_LAYERS=180` (`facet_far_ring.gd:3259-3264` — strings
  byte-identical to pre-A); `band_layers()` returns 180 so every routed alloc/residency/ledger site is
  unchanged; `_setup_fine_map` early-outs (zero allocation); `far_lut` is declared exactly once in the meta
  uniforms (`_FLAT_UNIFORMS_META`, reused by `_FINE_ELSE` — no double declaration); `fine_map` is spliced only
  under both flags. FLAT 6042/0 confirmed by the implementer. The two unconditional consts (F3) are the only
  breach.
- **A2 pinning**: array-path `%d` stays 180 while the meta path is layer-count-free; UV2.y `64+layer` reaches
  303 (exact in float); `v_slot < 63.5` close-up guard preserved in both paths (`:3257`, `:3263`). The 512→240
  retreat is correctly commented against GL_MAX_ARRAY_TEXTURE_LAYERS ≈ 256.

### A-audit-3 Verdicts

| Phase | Verdict | Basis |
|---|---|---|
| A1 FP_BAND_META_TEX | **PASS** | Addressing byte-equivalent to the array path; live-verified at 180; nits F9 only. |
| A2 band 240 + promote 8000 | **PASS-WITH-DEFECTS** | Layer growth + routing correct; but F3 (unconditional consts) and the promote-8000 policy is the enabler of F1 — revert/gate it. |
| A3 FP_PLANET_MAP data+bake | **PASS-WITH-DEFECTS** | Round-trip math and threading correct; F2 (ledger, must-fix), F4 (perf, one-liner), F8 (dependency), F9 nits. |
| A4 shader fine branch | **CONDITIONAL PASS** | Correct at the verified altitude; conditional on F1 fixes (band arbitration + sentinel + fallback chain), F5 (the skipped fade) before high-orbit soak, F6 clamp. |

**Must-fix before building B on top of A**: F1 (all three parts), F2, F4 (one line), F5. F6/F8 next deploy;
F7 gates should land with the F1/F2 fixes so the fixes are themselves gate-proven rather than eyeballed again.
