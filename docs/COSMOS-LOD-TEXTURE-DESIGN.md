# COSMOS-LOD-TEXTURE-DESIGN

**Progressive multi-tier LOD terrain with per-facet baked "satellite" textures — baked from real block colors, edit-aware, gl_compat/WebGL2, NEVER-OOM.**

Status: DESIGN (Fable, final). Parent docs: `docs/COSMOS-SEAMLESS-SCALES-DESIGN.md` (SSE law §3, tier ladder §4, edit-delta ledger item C9/`FP_TIER_EDITS`), `docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md` (depth-bias composition), `docs/COSMOS-FARRING-COVERAGE-DESIGN.md` (backstop). This doc adds the **texture axis** to the already-designed geometry ladder; it deliberately re-uses the far ring's warm/emit/async pipeline instead of inventing a new streaming system.

---

## 0. Ground truth this design is built on

1. **The far ring already meshes the whole globe as one draw call** — `godot/src/world/facet_far_ring.gd:1-16`: one merged ArrayMesh over up to ~1900 emitted facets (camera-set law `shell_set_camera_abs`, `facet_far_ring.gd:214-242`), rebuilt off-thread (`_async_build_worker`, `facet_far_ring.gd:410-419`) and swapped on main (`_swap_in_arrays`, :438-453). Its **color resolution is the problem**: `CELLS := 4` (`facet_far_ring.gd:19`) means one FarPalette color per ~104-block vertex cell (facet edge = π/2·6371/24 ≈ **417 blocks**; K=24, R_BLOCKS=6371 at `godot/src/cosmos/facet_atlas.gd:12-13`). From orbit the planet reads as a Gouraud-shaded low-poly ball, not terrain. The smooth-texture tier's job is to fix **albedo** resolution; the geometry ladder (voxels → skin → backstop → horizon ring) is already designed and stays untouched.
2. **The per-column "real block color" sampler already exists and is C++-fast**: `VoxelGeneratorCosmos.sample_columns` returns `{heights, biomes, water, colors}` for packed (x,z) columns of a facet in ONE call (~1-3 ms per 33² tile; used by `godot/src/world/facet_skin_tier.gd:429-475`, built by `_build_cpp_gen` :552-581, GDScript oracle twin `gd_sample` :585-608). Its colors are `FarPalette.color_for` (`godot/src/world/far/far_palette.gd:152-158`) — every RGB resolved from `BlockCatalog.color_of` of the **actual surface block** (`far_palette.gd:36-63`), i.e. the color of the real block assembly at that column, per the one-sampler law.
3. **The runtime-baked-ImageTexture precedent exists**: `godot/src/world/voxel_module/block_atlas.gd:111-188` builds a 1024² RGBA8 atlas + mipmaps at setup on gl_compat web today (`FP_ATLAS_MATERIAL`, `godot/src/cosmos/cube_sphere.gd:250`).
4. **Edits are fid-keyed at one choke point**: `_write_cell` (`godot/src/world/world_manager.gd:1208`, overlay write at :1242), `sim_revert_cell` (:1261-1265); under FACETED the key is the packed `(fid, cell)` int and `FacetAtlas.edit_key_fid(key)` (`facet_atlas.gd:186`) recovers the facet in O(1). Per-facet invalidation is a one-line hook.
5. **Locked composition law** (SEAMLESS-SCALES §0.5): large-tier alpha cross-fades are rejected (sorting + double fill on WebGL2); geometry composes by **overlap + shared sampling + sink**. Requirement 4's "cross-fade, never a pop" is honored *inside one opaque material* — a per-fragment weight blending two albedo sources (vertex color ↔ baked texture, base-res ↔ close-up-res) is a texture blend, not transparency: zero sorting hazard, zero extra draws.
6. Key constants: `ATMO_TOP := 384.0` (`cube_sphere.gd:594`), `OFFSURFACE_Y := 256.0` (:410), `BACKSTOP_CELLS := 16` (:300), K=24 → 3456 facets. Screen-space law: `px(e,d) = e/d · K_px`, K_px ≈ 1407 at DPR2-1080p (SEAMLESS-SCALES §3.1).

---

## 1. Architecture — how the texture is produced and applied

### 1.1 Bake technique: **CPU composite from the one-generator sampler + edit overlay, then `Image.resize` downscale** (primary)

Per facet, the baker:

1. Samples a **fine grid** of the facet's surface at `BAKE_SRC×BAKE_SRC` columns (base tier: 32², pitch ≈ 13 blocks; close-up tier: 128², pitch ≈ 3.3) via `sample_columns`, one call per row-slice, exactly as `facet_skin_tier.gd:440` does. Each fine texel = the actual top block's catalog color at that column. This *is* "the real image formed by the assembly of the actual blocks forming the facet's surface" — the same pixels a top-down render of the meshed blocks would produce, without needing those blocks to be resident.
2. **Splats the edit overlay** over the fine grid (§3).
3. **Downscales** the fine Image to the stored resolution with `Image.resize(..., INTERPOLATE_BILINEAR)` — the literal "downscale the real image" of requirement 2 (box average of real block colors: a 50×50 quarry survives to the final texels; a single block honestly averages out).
4. Blits into the facet's cell of its **per-face page** and uploads only that page/layer.

**Why not SubViewport RTT** (the rejected alternative): an RTT of "the actual blocks" requires the blocks to be *meshed*, and only the ≤128-block near disc plus pool neighbours ever are (`facet_skin_tier.gd:5-10`) — you cannot photograph a facet whose voxels don't exist. It would also need a per-bake camera+viewport render pass and, for atlas packing, `get_image()` GPU readback — a known multi-ms pipeline stall on WebGL. The CPU composite produces the *same pixels* (top-block colors) from the sampler the whole engine is contractually bound to (one-sampler law, `facet_skin_tier.gd:18-21`), off the render pipeline, budget-sliceable, and byte-deterministic (headless-gateable — an RTT is not). WASM ×25 CPU penalty is absorbed by doing the heavy loop in the compiled generator (`sample_columns` is C++) and slicing the GDScript blit/resize under a per-frame ms budget.

**Fallback** (compiled generator absent — GDScript oracle only): keep the flag OFF at export, or degrade `BAKE_SRC` to 8² (64 columns ≈ 5-15 ms GDScript-web per facet, prewarm-only, no close-up tier). Recorded in telemetry. Today `module_in_web=yes`, so the C++ path is the live case.

### 1.2 Texture layout: **6 face pages; facets are sub-rects → within-face seams are free**

Base map = **Texture2DArray, 6 layers of `(K·BASE_TEXELS)² = 384×384`** (BASE_TEXELS=16 texels per facet edge → ground pitch ≈ 26 blocks). Facet `(face, a, b)` occupies rect `[a·16..a·16+16)×[b·16..b·16+16)` of layer `face`.

- **Within a cube face (24×24 = 576 facets), the map is one continuous image** — bilinear filtering across facet boundaries is *correct* continuity, so ~99% of potential per-facet texture seams do not exist by construction. Only the 12 cube edges are boundaries, and there both sides' edge texels sample near-identical sphere directions through the same generator, so their colors agree by worldgen continuity (same argument as the FS1 weld, `facet_far_ring.gd:786-800`). No gutters; CLAMP at layer edges.
- **Per-layer partial upload**: `RenderingServer.texture_2d_update(rid, image, layer)` re-uploads one 384² face page (576 KB + mips), never the whole map.
- **Close-up tier** (`FP_FACET_TEX_CLOSEUP`): a second Texture2DArray, `CLOSEUP_MAX=64` layers of 128², one facet per layer, LRU by angular distance from the sub-camera direction (the ring's `_emit_axis`, `facet_far_ring.gd:102`). Per-layer update = 64 KB.
- Mipmaps: `Image.generate_mipmaps()` per dirty page before upload (<1 ms at 384²; the `block_atlas.gd:182` pattern); filter LINEAR_WITH_MIPMAPS (satellite look wants smooth, not NEAREST).

### 1.3 Applying it to the far ring: UVs + one shader extension

The ring's merged mesh gains two vertex channels **only when `FP_FACET_TEX` is on** (arrays absent otherwise → byte-identical mesh):

- `ARRAY_TEX_UV` = `((a + s)/K, (b + t)/K)` — the facet-grid parameter (s,t) every cache builder already iterates (`_ensure_cached` `facet_far_ring.gd:808-811`; dense :869-877; envelope :932-955; weld :986-1002). Pure function of the loop indices — no new sampling.
- `ARRAY_TEX_UV2` = `(face, closeup_slot)` — face selects the base-map layer; `closeup_slot` is the facet's resident close-up layer or −1.

Touch points (each a ~3-line flag-guarded addition): `_ensure_cached`/`_ensure_backstop_cached`(+env/weld twins) grow parallel `_uv_cache/_buv_cache` dicts; `_emit_cached` (`facet_far_ring.gd:1048-1074`) adds `st.set_uv/set_uv2`; `_ensure_tri_cached` (:1080-1100) and `_append_backstop_tris` (:1025-1040) grow tri-order UV arrays; `_build_fast` (:621-646) and `_swap_in_arrays` (:438-453) carry `ARRAY_TEX_UV/UV2` through `add_surface_from_arrays`. The async worker only reads caches — the thread contract is unchanged.

**Material**: extend the absolute shell shader `_SHELL_ABS_SHADER` (`facet_far_ring.gd:1190-1210`) — the deployed orbital look — with:

```glsl
uniform sampler2DArray base_map : source_color, filter_linear_mipmap;
uniform sampler2DArray closeup_map : source_color, filter_linear_mipmap;
// fragment():
vec3 albedo_tex = texture(base_map, vec3(v_uv, v_face)).rgb;
if (v_slot >= 0.0) {
    float wc = smoothstep(CLOSEUP_FAR, CLOSEUP_NEAR, v_cam_dist);   // sharpen on approach
    albedo_tex = mix(albedo_tex, texture(closeup_map, vec3(v_facet_uv, v_slot)).rgb, wc);
}
float wt = smoothstep(TEX_D0, TEX_D1, v_cam_dist);                   // vertex-color <-> texture cross-fade
ALBEDO = mix(v_col_raw, albedo_tex, wt) * shade * tint;              // shade/tint = existing day-night law
```

All blends are per-fragment arithmetic inside one opaque material — no transparency, no sorting, and the ring stays ONE draw. `v_cam_dist` comes free from `CAMERA_POSITION_WORLD`. The same extension applies to the `SHELL_TERMINATOR_TINT` v1 shader (:1168-1182) and to `TierPlace.make_biased_material` (`godot/src/world/tier_place.gd:119`) far-tier variant so `FP_TIER_DEPTH_BIAS` composes. `sampler2DArray` is core WebGL2 (risk + fallback: §7-R6).

### 1.4 Relationship to FP_ATLAS_MATERIAL

Orthogonal and complementary: `FP_ATLAS_MATERIAL` (`block_atlas.gd`) textures **near voxel cubes** (per-block 64-px tiles, draw-call merge). This design textures the **far ring** (per-facet baked satellite images). They share the pattern (runtime `Image` → atlas → one material), not data — the baked facet texture derives from `sample_columns` colors, which derive from the same `BlockCatalog` colors the block atlas uses (`far_palette.gd:36-63`), so near-block look and satellite look track the catalog together by construction.

---

## 2. The tier ladder (with the texture axis added)

Distances in blocks; d = camera distance to the surface point; h = radial altitude. Geometry tiers and their composition (sink/overdraw) are the shipped/parent design — **unchanged**. New texture behavior in bold.

| # | Tier | Range (engage → saturate) | Geometry | Albedo source | Cross-fade mechanism |
|---|---|---|---|---|---|
| T0 | Voxel field | 0..128 | exact blocks (FacetLodMesher/module) | block textures / `FP_ATLAS_MATERIAL` | overdraws T1/T2 via sink (shipped) |
| T1 | Skin | 96..256 | pitch-1 heightfield, sunk 1.5 (`facet_skin_tier.gd:59`) | per-vertex `sample_columns` colors | overlap band 96..128 with T0 (shipped) |
| T2g | Far-ring backstop + horizon | 128..whole planet | `BACKSTOP_CELLS=16` sunk + `CELLS=4` (`cube_sphere.gd:300`, `facet_far_ring.gd:19`) | **mix(vertex-color, base map, wt)**; wt: 0 below `TEX_D0=600`, 1 above `TEX_D1=1800` | **per-fragment smoothstep in-material** — both sources derive from the same palette, so the blend is hue-stable; at d<600 the shipped look is bit-preserved (wt=0) |
| T2t | Close-up satellite cap | off-surface (h > `OFFSURFACE_Y=256`), facets within ~17° of nadir | same T2g mesh | **mix(base 26-blk/texel, close-up 3.3-blk/texel, wc)**; wc: 0 at `CLOSEUP_FAR=4000`, 1 at `CLOSEUP_NEAR=1200` | per-fragment; slot resident-or−1 — a missing slot degrades to base map (a softening, never a hole or pop) |
| T3 | Scaled body | d > D_ENGAGE (`apply_scaled_placement`, `facet_far_ring.gd:175-179`) | same mesh under distance clamp | texture rides the same UVs automatically | none needed — the clamp is screen-invariant |

- **Atmosphere-space border**: nothing above is keyed to ATMO_TOP=384 — wt saturates at 1800 (below orbit) and wc is distance-driven, so crossing 384 changes no tier state → the locked continuum holds through the border by construction.
- **Descent/re-entry** (the pop-critical path): base map (fully resident after prewarm) → close-up cells sharpen in from d≈4000 → below ~1800 texture yields to vertex colors → below ~600 the shipped ring/backstop look → skin at 256 → voxels at 128. Every hand-off is a fragment blend or a sink-overdraw; no swap event exists to pop.
- Screen check (K_px=1407): at h=2000 a facet subtends ≈ 417/2000·1407 ≈ 293 px → close-up texel ≈ 2.3 px (satellite-sharp); base texel 18 px (fine for oblique/limb facets, which are foreshortened). At LEO h=500, close-up texel ≈ 9 px — coarse but smooth, and this is the regime where wt is already handing back to vertex color + backstop relief. 64 close-up cells cover a ~17° nadir cap ≈ ~90% of non-foreshortened pixels.
- The "coarsest tier = a few thousand blocks of resolution for the whole planet, hidden under the smooth texture" maps to: base map = whole planet at ~26-block texel pitch, over CELLS=4 relief geometry (~55 k height cells planet-wide). If a strictly coarser geometry ask emerges, a CELLS=2 collapse is a trivial later knob — not needed for perf (the ring is one draw either way).

---

## 3. Edit-driven re-bake

### 3.1 Invalidation — same choke points as the edit index

- `world_manager.gd:1242` (`_edits[ek] = ...` inside `_write_cell`): under `FP_FACET_TEX_EDITS && FACETED`, add `_facet_tex.mark_edit(FacetAtlas.edit_key_fid(ek), cell)` — O(1) dict write.
- `world_manager.gd:1264` (`sim_revert_cell` erase): same call.
- Bulk paths already route through `_write_cell` (`world_manager.gd:2560/2635/2740`), so bundle loads invalidate for free. Crossing-clear: nothing to do — bakes are fid-keyed and absolute, exactly like the ring's caches.
- Baker state: `_dirty: Dictionary(fid → Dictionary(packed_xz → true))`, per-facet column set capped at `EDIT_COLS_MAX=256`; overflow flips the facet to "full re-bake" and drops the column list — bounded by construction.

### 3.2 Re-bake — bounded, off the hot path

Per frame in the baker's `update()` (driven from `WorldManager.update_streaming` next to the skin hook, `world_manager.gd:698-706`), under `BAKE_BUDGET_MS=2.0` (the ring's `WARM_BUDGET_MS` discipline, `facet_far_ring.gd:24`):

1. **Priority**: edit-dirty facets → uncached facets under the current emit axis (`_cull_params`, `facet_far_ring.gd:357-360`) → planet-wide prewarm cursor (one-shot, mirroring `_prewarm_step` :251-274).
2. A dirty facet with a small column set does an **incremental splat**: per edited column, recompute the exposed top block — walk down from `max(placed_top, g_gen)` through the overlay (placed id > 0 → that id; dug-to-air → continue; else the generated id at that depth) — paint `BlockCatalog.color_of(id)` into the covering *fine* staging texels, then re-`resize` + re-blit only that facet's cell. Cost ∝ edit count, not facet area. A full-rebake facet re-runs §1.1 sliced across frames (≤1 `sample_columns` row-slice per frame under budget).
3. **Coalescing**: dirty face pages/layers upload ≤1 per frame; a facet re-bakes at most once per `REBAKE_MIN_S=1.0` (a dig burst costs one re-bake, not one per block).
4. Result: a quarry or tower is visible from orbit within ~1-2 s of the last edit, with zero synchronous work on the edit frame itself.

Disclosed behavior (by design): a *single* block edit is sub-texel at base-map pitch and honestly averages out — exactly what "the real image, downscaled" means. Structures ≥ ~4 blocks appear in the close-up tier; ≥ ~2 fine texels (~13-26 blocks) in the base map.

## 4. NEVER-OOM budget (the arithmetic)

| Item | Size | Bytes |
|---|---|---|
| Base map GPU (Texture2DArray 6×384² RGBA8 + mips ×1.33) | | **4.7 MB** |
| Base map CPU staging (6 face Images, kept for partial re-blit) | 6×384²×4 | 3.5 MB |
| Close-up GPU (64×128² RGBA8 + mips) | | **5.6 MB** |
| Close-up CPU staging (resident cells only, 64×64 KB) | | 4.0 MB |
| Transient fine-bake buffer (one at a time, 128²×4 worst) | | 0.07 MB |
| Dirty/edit bookkeeping (≤3456 fids × ≤256 packed ints worst) | | ≤ 0.9 MB |
| **Total ceiling (all flags on)** | | **≈ 18.8 MB** → `FACET_TEX_BYTES_MAX := 20 MB` |

- Base-tier-only (`FP_FACET_TEX` without CLOSEUP): ≈ 8.2 MB — comparable to the skin's existing 8 MB ceiling (`facet_skin_tier.gd:68`).
- **Ceilings are structural, not policed**: every buffer is fixed-size at creation (6 layers, 64 layers, 384², 128²) — nothing grows with playtime, edits (capped column sets), or travel. `total_bytes()` reports the ledger for the gate; on any accounting breach the response is **wholesale clear + re-prewarm**, never partial thrash.
- **Eviction (close-up only)**: LRU by angular distance to `_emit_axis`; evict only facets **outside the current cap** (they render from the base map where wc≈0 → eviction invisible; gate G-FT-SLOT asserts it). The base map is never evicted — the floor that makes every miss safe.
- Zero-extra-memory when OFF: baker node, textures, staging Images, UV caches, and UV mesh arrays are **never created** (flag-gated construction, the `_skin` pattern at `world_manager.gd:293-296`).

## 5. Flag plan (all default-false `const` in `cube_sphere.gd`, sed'd ON at export after A/B)

| Flag | Gates | OFF ⇒ |
|---|---|---|
| `FP_FACET_TEX` | baker node creation, base-map textures, UV/UV2 cache + array emission in `facet_far_ring.gd`, the texture branch of the shell material | ring caches/arrays/material byte-identical (UV code paths textually separate — the `FP_SHELL_WELD` pattern); FLAT gate 6042/0 untouched (baker requires FACETED, like `FacetFarRing` at `world_manager.gd:281`) |
| `FP_FACET_TEX_CLOSEUP` | (requires FP_FACET_TEX) close-up array, slot LRU, wc blend | UV2.y stays −1, closeup sampler never bound, zero bytes |
| `FP_FACET_TEX_EDITS` | (requires FP_FACET_TEX) the two `_write_cell`/`sim_revert_cell` hooks + dirty/rebake machinery | edits invisible to bakes; the hooks are `if`-guarded no-ops — the write choke point is byte-identical |

Each higher flag requires the one below; any combination OFF degrades to the previous tier's exact behavior. Shader variants are chosen once at `_make_material` (`facet_far_ring.gd:1212-1244`) — flag-off builds compile the shipped shader strings verbatim.

## 6. Phased implementation plan (each phase independently shippable + headless-gated; lowest risk first)

**Phase 1 — smallest real baked-from-blocks texture on the far tier** (`FP_FACET_TEX`, static bake).
New `godot/src/world/facet_tex_baker.gd` (RefCounted, owned by WorldManager): §1.1 bake for the base map only, synchronous prewarm of the emitted set at setup (spawn masked by the ShaderPrewarm hold, same as the ring's initial `_rebuild_full`, `facet_far_ring.gd:132`); UV/UV2 emission in the ring; shader extension with wt blend. No scheduling, no edits, no close-up.
*Gate `verify_facet_tex.gd`*: **G-FT-OFF** — flag off ⇒ `_rebuild_full` surface arrays bit-identical to shipped (the G-L1-FARRING equivalence pattern) + FLAT 6042/0. **G-FT-BAKE** — baked texel == box-average of the fine `sample_columns` colors within ε; deterministic across two bakes. **G-FT-UV** — every emitted vertex's UV lands inside its facet's rect; same-face neighbours map to adjacent texels. **G-FT-PALETTE** — texel color vs `FarPalette.color_for` at the texel-centre direction within tolerance. Falsify each by perturbation.

**Phase 2 — progressive scheduling + budget + telemetry.**
Baking under the per-frame budget (§3.2 priorities minus edits), prewarm cursor, per-layer uploads, `tex_telemetry()` streamed via the remote bridge next to `shell_telemetry()` (`facet_far_ring.gd:722-761`).
*Gate*: **G-FT-BUDGET** — scripted 500-frame drive never exceeds `BAKE_BUDGET_MS`/frame and converges to full coverage; **G-FT-BYTES** — ledger equals §4 arithmetic exactly at every step.

**Phase 3 — edit-driven re-bake** (`FP_FACET_TEX_EDITS`).
The two choke-point hooks + incremental splat + debounce.
*Gate*: **G-FT-EDIT** — dig an 8×8 quarry via `break_block`; assert the facet goes dirty (fid via `edit_key_fid`), the re-baked texel shifts toward the exposed underground color, and `sim_revert_cell` restores the baseline texel bit-exactly. **G-FT-EDIT-BOUND** — 10 k scripted edits in one facet: column set caps at 256 → full-rebake mode, bytes ledger unmoved, ≤1 re-bake per `REBAKE_MIN_S`.

**Phase 4 — close-up cap** (`FP_FACET_TEX_CLOSEUP`).
64-layer array, slot LRU on `_emit_axis`, wc blend, slot index into UV2 at emit.
*Gate*: **G-FT-SLOT** — driving `shell_set_camera_abs` around the globe: resident slots ≤ 64 always; every evicted facet is outside the cap angle at eviction (the no-visible-pop invariant); an in-cap facet is never evicted. **G-FT-CLOSEUP-BAKE** — box-average check at 128².

**Phase 5 — live A/B + flip ON.**
Tier-A Xvfb/llvmpipe screenshot sweep (orbit, re-entry descent, surface horizon, night limb) + remote-bridge live session on real GPU; browser-heap A/B (the `FP_ATLAS_MATERIAL` protocol); then sed-ON at export. The only phase with visual judgment — everything structural is proven headless by then.

## 7. Risks and the visual failure modes each gate catches

| # | Risk | Mitigation | Caught by |
|---|---|---|---|
| R1 | **Facet-texture seams** | within-face: impossible (one continuous page, §1.2); cube edges: both sides' texels sample near-identical directions through one generator → agree | G-FT-UV + Phase-5 limb screenshots at the 12 cube edges |
| R2 | **Texture↔vertex-color hue jump at the wt crossfade** | both sources derive from `FarPalette`/`BlockCatalog` (§1.4); blend band 600→1800 is wide | G-FT-PALETTE (numeric) + Phase-5 descent sweep |
| R3 | **Edit re-bake hitch** | mark = dict write; bake sliced under 2 ms; upload ≤1 page (576 KB max)/frame; debounced | G-FT-BUDGET run *with* concurrent scripted edits |
| R4 | **Close-up eviction pop** | evict only outside-cap facets (wc≈0 there); missing slot falls to base map — never a hole | G-FT-SLOT |
| R5 | **Memory blowup** | all buffers fixed-size at creation; structural caps; wholesale-clear posture | G-FT-BYTES + browser-heap A/B |
| R6 | **`sampler2DArray` / `texture_2d_update(layer)` misbehaving on ANGLE/WebGL2** (the P3 shader-failure class) | fallback locked in advance: single 2304×384 (and 1024² close-up) `ImageTexture` with debounced ≥1 s full `update()`; shader falls back to 2D samplers with packed-face UVs | Phase-1 live smoke on the deployed export **before** Phases 2-4 build on the array path |
| R7 | **Day-night/terminator regression** | texture branch extends `_SHELL_ABS_SHADER` and multiplies the same `shade·tint`; GDScript twins already pinned (G-AS-TERM) | existing sky gates + Phase-5 night-limb screenshot |
| R8 | **Bald facets** (canopy missing from bakes vs near view) | `FarPalette._forest/_taiga/_jungle` already encode canopy-mean tints (`far_palette.gd:52-62`); per-column TreeGen-hash darkening is a disclosed v2 refinement | Phase-5 visual A/B decides if v2 is needed |

**Open questions / disclosed deviations** (nothing blocking Phase 1):

1. **R6 is the one genuinely unverifiable-headless item**: `RenderingServer.texture_2d_update` per-layer on gl_compat/ANGLE must be smoke-tested live in Phase 1; the single-ImageTexture fallback is fully specified and costs only upload granularity.
2. Requirement 4's "cross-fade" is implemented as in-material albedo blending + the locked sink/overdraw law, **not** alpha-blended co-resident tiers — that rejected mechanism both pops and breaks WebGL2 sorting (SEAMLESS-SCALES §0.5). Judged the locked continuum decision controlling; flag if the user meant literal alpha layers.
3. Single-block edits are sub-texel from orbit by construction (honest downscale of the real image) — if per-edit orbital visibility regardless of size is wanted, that is a marker/decal feature, not a bake feature, and should be scoped separately.
4. Close-up floor at LEO is ~9 px/texel under the 64×128² NEVER-OOM budget; raising it (128 layers / 256²) is a measured-A/B knob, never a default.
