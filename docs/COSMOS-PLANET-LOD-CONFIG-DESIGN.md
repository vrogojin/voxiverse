# COSMOS-PLANET-LOD-CONFIG-DESIGN — the far→near planet LOD stack, crisp blocky orbit, and generic per-body config

*Rendering architecture. Read-only analysis of the shipped code on `feat/voxiverse-orbit-space-temp`.*
*Companions: COSMOS-BLOCK-LOD-DESIGN.md, COSMOS-TEXTURED-LOD-DESIGN.md, COSMOS-PLANET-VIEW-DESIGN.md, COSMOS-SEAMLESS-SCALES-DESIGN.md, COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md, COSMOS-LOD-SKY-DESIGN.md.*
*Every new behaviour gates behind a `const FP_* := false` in `godot/src/cosmos/cube_sphere.gd`; OFF ⇒ byte-identical (FLAT `verify_feature.gd` = 6042/0). NEVER-OOM: memory safety > visuals; every upgrade is a MEASURED A/B with an explicit byte cap + lifetime cap.*

---

## 0. The framing number: why the far skin is coarse and why detail must be geometry, not texture

`R_BLOCKS = 6371` (`cosmos/facet_atlas.gd:13`), 1 block = 1 km (1:1000 Earth). Planet surface area:

```
A = 4·π·R²  =  4·π·6371²  ≈  5.10 × 10⁸  blocks²
```

A **literal one-texel-per-block** planet texture is therefore:
- RGBA8: 5.10e8 × 4 B ≈ **2.04 GB**
- even a 1-byte id map: **≈ 510 MB**

Both are ~50–1000× over the whole web memory budget (< 40 MB combined). **This is the reason the §2V "satellite" skin is coarse** (`BASE_TEXELS = 16` texels per facet edge ⇒ **≈ 26 blocks per texel** on the ground — `facet_tex_baker.gd:33`), and the reason **surface detail at range must come from decimated block GEOMETRY (block-LOD), not from a finer texture.** Texture resolution is bounded by area×bytes; geometry resolution is bounded only by what is *on screen*, which is the whole point of an LOD ladder.

---

## 1. The far→near LOD stack as it renders TODAY

The scene is meshed by `FacetFarRing` (`world/facet_far_ring.gd`) — a whole-front-hemisphere chord mesh at `CELLS = 4` heightmap cells per facet edge (`facet_far_ring.gd:19`), 6·K·K = 6·24·24 = **3456 facets**, front hemisphere only (`BACK_CULL = 0.0`, `:29`), 32 tris/facet, `CAMERA_FAR = 9000` (`:30`). The §2V "satellite" **skin** is a set of textures *painted on that same ring* (`FacetTexBaker`), not a separate mesh. The near field is the real voxel world (`WorldManager` blocks). Between them sit the skin tiers.

| Regime | Altitude / cam-dist `d` | What actually renders | Selection law (file:line) | Resident bytes | Look |
|---|---|---|---|---|---|
| **Surface / walk** | on-ground, `d` 0..~128 | real 1-block voxels (`WorldManager`) | `WorldManager.block_id_at` overlay | streamed near-field | crisp voxels |
| **In-atmosphere / fly** | `h` < `ATMO_TOP=384` (`cube_sphere.gd:1020`) | voxels near + far-ring chord mesh wearing §2V skin (base map + **band** L8 512² id-map for active∪ring-1, `facet_tex_baker.gd:111`; **close-up** 128² for the sub-camera disc, `cube_sphere.gd:678`) | band residency active∪ring-1 ≤ `BAND_LAYERS=9`; close-up engages `CLOSEUP_FAR=4000`→`CLOSEUP_NEAR=1200` (`:683`) | base ≈ 8.2 MB, band ≈ 2.4–4.8 MB, close-up ≈ 4–6 MB | near crisp, far **smooth+blotchy** (26 blk/texel base) |
| **Near orbit** | `h` ~ 384..~4000 | far-ring chord mesh + §2V base skin; close-up fades OUT past `CLOSEUP_FAR=4000` | close-up promotion `CLOSEUP_CAP_DEG=17°` cap, LRU (`:685`) | as above | smooth blotchy disc |
| **Far orbit** | `h` ~ 4000..~12.5k | far-ring chord mesh + §2V **base only** (26 blk/texel), `FP_FARRING_LIMB_DENSE` silhouette ring at `LIMB_DENSE_CELLS=8` (`facet_far_ring.gd:21`), `FP_ATMO_RIM` hairline limb | scaled-body clamp `s = min(1, D_ENGAGE/d)` about camera (`facet_far_ring.gd:409`, `apply_scaled_placement`); engage ≈ `POOL_RETIRE_H·1.25 ≈ 12.5k` (`cosmos_scale.gd:29`) | base ≈ 8.2 MB | **smooth blotchy globe** — the look the user rejects |
| **Deep space** | body disc < ~few px | `BodyLod` POINT→IMPOSTOR→RING selection (`cosmos/body_lod.gd`, `FP_BODY_LOD`) | `ang_px = 2r/d·K_px`; `relief_px < TAU_POP` ⇒ IMPOSTOR else RING (`body_lod.gd` header) | impostor = 1 sphere; N_RING_MAX rings in a 32 MB far-tier ledger | shaded sphere / far-ring globe |

**Block-LOD is NOT in this table on purpose.** See §2.

### 1.1 The §2V skin byte ledger (the real numbers for the memory math)
- **Base map** (`facet_tex_baker.gd:23,27,33`): `Texture2DArray` 6 layers of `(K·BASE_TEXELS)² = 384²` RGBA8 + mips ⇒ **≈ 8.2 MB** ("base-tier-only" ledger, header). Ground pitch **≈ 26 blocks/texel** — the visible blotch at orbit.
- **Band id-map** (`cube_sphere.gd:557–573`): `BAND_LAYERS=9 × BAND_TEXELS=512²` L8 = **2.36 MB** GPU + 0.26 MB staging; ×2 (RG8) under `FP_BAND_SHOT` ⇒ ≈ 4.8 MB. Residency = active ∪ ring-1, evicts on ring exit.
- **Close-up** (`cube_sphere.gd:678–685`): `CLOSEUP_MAX=64 × CLOSEUP_TEXELS=128²` RGBA8 = **4.19 MB** (+mips ≈ 5.6 MB), LRU by angular distance to emit axis, `CLOSEUP_CAP_DEG=17°`.
- These are **the bytes the crisp-blocky-orbit change can reclaim** by retiring the skin above the swap (§2.3). At high orbit the band + close-up are already faded/evicted, so the reclaimable resident cost there is the **base map ≈ 8.2 MB**.

---

## 2. THE CHOSEN CHANGE — crisp BLOCKY megablocks from orbit

### 2.1 Root cause: why the smooth §2V skin (not blocky megablocks) owns the orbit disc today

Three compounding reasons, all verifiable in this branch's code:

1. **Block-LOD has no renderer on this branch — only the P0 data model exists.** `facet_block_lod.gd` (`FacetBlockLod`) builds the `L0..L5` decimated **column pyramid** (`LEVELS = 6`, pitch 1,2,4,8,16,32; `facet_block_lod.gd:33`) as pure data + arithmetic — "PURE DATA + arithmetic (no Node, no rendering, no streaming)" (`:3–5`). The only block-LOD flag present is `FP_BLOCK_LOD` at `cube_sphere.gd:666`, and its own comment says **"P0 ships ONLY the data model"** and lists `FP_BLOCK_LOD_RINGS`/`_GLOBAL`/`_REALBAKE` as *future* (`:659–665`). Those render flags **do not exist in code here** (grep of `godot/src` finds `block_lod` only in `facet_block_lod.gd`, `facet_tex_baker.gd`, `verify_block_lod.gd`, `cube_sphere.gd`). So block-LOD geometry never reaches the screen at *any* distance — the far ring + §2V skin is the *only* thing meshing the globe at orbit.
   > *Note vs memory: MEMORY.md records "P0/P1/P2 block-LOD shipped live 2026-07-28" (FP_BLOCK_LOD + RINGS + GLOBAL). That work is not merged into this worktree; treat §2 as building the orbit render phase here regardless of where the ring/ladder landed elsewhere. The architectural conclusion is identical.*

2. **Even by the block-LOD DESIGN, the ladder hands OFF to §2V at orbit by intent.** `COSMOS-BLOCK-LOD-DESIGN.md §4` ends the ladder at **L5 (32-blk), band 5600..~15k**, then: *"beyond — blocks <1-2 px — `FP_FACET_TEX` smooth satellite (fade blocky out under it)."* And L5 is explicitly a **"GLOBAL always-resident *data* floor + near-nadir mesh"** — NOT a full-globe mesh (MEMORY: "L5 fully-meshed globe = 158 MB infeasible → data floor + near-nadir mesh + skin"). So the design *deliberately* lets the §2V skin cover the full orbit disc; blocky geometry was only ever meshed for the nadir patch.

3. **Tier depth-priority never demotes §2V in favour of block-LOD, because block-LOD isn't in the chain.** `TierPlace` (`world/tier_place.gd`) encodes "near voxel blocks > skin > far-ring backstop > distant facets" via window-depth bias (`FAR_BIAS_K=8`, `SKIN_BIAS_K=4`, `:` P3). Block-LOD has no bias entry, so wherever it *would* draw it has no claim over the ring. The far ring, wearing §2V, is the coarsest resident tier and owns the disc by default.

**Conclusion:** making orbit crisp-blocky is a *new render phase* — mesh the visible disc as decimated megablocks and retire the §2V skin above the swap. It is the block-LOD design's `RINGS`/`GLOBAL` phases, re-scoped to *reach orbit distance* and to *replace* (not underlay) the skin there.

### 2.2 The megablock-size math — pick B so a megablock reads ~1–2 screen px at orbit

Screen size of a block of edge `B` at camera distance `d`: `px = (B/d)·K_px`, `K_px = viewport_h_px/(2·tan(fov/2))`. Solve for the block size that lands at a target `px*`:

```
B*(d) = px* · d / K_px
```

Worked at the live snapshot altitude **alt 8000** (nadir surface distance `d ≈ 8000`), `px* = 1.5` (crisp, not chunky):

| K_px (viewport/fov) | B* at nadir d=8000 | nearest ladder level |
|---|---|---|
| 771  (1080p, 70° fov) | ≈ **15.6 blocks** | **L4 (16-blk)** |
| 1407 (design K_px, `BLOCK-LOD §4`) | ≈ **8.5 blocks** | **L3 (8-blk)** |

So the *nadir* disc at alt 8000 wants **L4 (16-blk)** megablocks. Toward the limb `d` grows (grazing angle → the surface recedes to `~2R` away), so `B*` grows and the per-facet level coarsens to **L5 (32-blk)** and beyond. This is exactly the existing distance ladder `d_max(Ln) ≈ 2ⁿ·K_px/4` (`BLOCK-LOD §4`), just driven up to orbit `d`. **Key result: crisp-from-orbit is a per-facet distance-selected level (L4 nadir → L5+ limb), NOT one uniform level.**

### 2.3 The byte cap — why it must be a distance ladder, not a uniform-L4 hemisphere

Column data is cheap; **mesh** dominates (`BLOCK-LOD §5`). Take a greedy-merged megablock mesh at ~28 B/vertex, 4 verts/quad ⇒ ~112 B/quad. Budget the front hemisphere (~1728 facets):

- **Uniform L5 (32-blk)** hemisphere greedy ≈ 40–80 quads/facet (`BLOCK-LOD §5`) ⇒ ~70k–140k quads ⇒ **≈ 8–16 MB**. Matches the design's "L5 hemisphere greedy ≈ 8–12 MB."
- **Uniform L4 (16-blk)** = 4× the quads ⇒ **≈ 32–48 MB** — **busts the cap** by itself.

Therefore a *uniform* crisp (L4) hemisphere is infeasible; the crisp look must come from **L4 only on the near-nadir disc** (where it's needed for 1–2 px) blending to **L5 toward the limb** (where L5 is already sub-2-px). Because most of the visible disc is at grazing angles (far `d` → coarse `B` allowed), the aggregate stays near the **L5-hemisphere budget ≈ 8–16 MB**.

Solve the cap explicitly for a resident budget `BLOCK_LOD_ORBIT_BYTES_MAX`:
```
quads_max = BYTES_MAX / 112
at +12 MB → quads_max ≈ 107k → ≈ 62 quads/facet over 1728 facets  (an L4-nadir/L5-limb blend fits)
at +16 MB → quads_max ≈ 143k → ≈ 83 quads/facet                    (comfortable L4 nadir, headroom)
```

**Net memory is roughly flat-to-positive because §2V is RETIRED, not overlaid.** Above the swap altitude we free the base map (**≈ 8.2 MB**) and any resident band/close-up; the orbit block mesh costs **≈ +8–16 MB**. Net delta ≈ **0 to +8 MB**, inside the allowed "+10–20 MB behind a measured A/B" envelope, with a hard ledger + wholesale-clear on breach (same discipline as `BLOCK_LOD_BYTES_MAX`).

### 2.4 REPLACE, not overlay
Prefer **replace**. Above the swap altitude the block-LOD megablocks mesh the whole visible disc, and the §2V skin's base/band/close-up are **released** (frees ~8.2 MB, and — the win the user asked for — **removes the on-the-fly bake latency**: no `sample_columns` page rebakes while orbiting; the block pyramid is analytic + already decimated). Below the swap the shipped skin path runs unchanged. During the swap the two co-exist for the cross-fade window only (§2.5), then the skin frees. This directly satisfies "reduce bake dependence, not add to it."

### 2.5 Seamlessness — no pop across the swap or between block levels
- **Block level ↔ block level** (nadir L4 ↔ limb L5): the `MIN`-height decimation (`facet_block_lod.gd:22`, `top(coarse)=MIN(children)`) guarantees `Ln+1` sits at-or-below `Ln` (containment, no-protrusion), so a coarser tile always *underdraws* a finer one — spatial cross-fade is composition, not stitching, closed by a one-coarse-pitch skirt (`BLOCK-LOD §4`). No cracks to geomorph.
- **Block ↔ §2V** at the swap: 0.3 s **screen-door dither** in the one opaque material (`BLOCK-LOD §4`, discard pattern — no transparency/sort). The megablock tops read as the same FarPalette colours the skin box-averaged, so the dither is between two agreeing images (SEAMLESS-SCALES §0.5: overlap/agreement, not fade-to-different).
- **Atmosphere continuity**: the swap altitude sits **above** `ATMO_TOP=384` (deep in space), so `FP_ATMO_RIM` (hairline limb) + `FP_FARRING_LIMB_DENSE` (silhouette ring) keep working on the far ring, which stays resident as the **sunk backstop underneath** the block mesh (`BLOCK-LOD §6`: "FacetFarRing KEPT as the sunk always-there backstop"). The block mesh overdraws it; the ring guarantees no hole during streaming and carries the round silhouette + rim.
- **Scaled-body clamp**: the block-LOD orbit mesh must ride the **same** `apply_scaled_placement`/`scale_about_camera(cam, s=min(1,D_ENGAGE/d))` transform the far ring uses (`facet_far_ring.gd:409`), so it stays inside the `CAMERA_FAR=9000` depth range and scales screen-invariantly with the disc in deep space (no clip, no pop at `D_ENGAGE`).

### 2.6 The build — flag, files, gate, live check
- **Flag**: `const FP_BLOCK_LOD_ORBIT := false` (`cube_sphere.gd`), requires `FP_BLOCK_LOD` (needs the pyramid data) + `FACETED`. New consts: `BLOCK_LOD_ORBIT_BYTES_MAX` (start **12 MB**, expand to 16 on green A/B), `BLOCK_LOD_ORBIT_ENGAGE_H` (swap altitude, ~4000 — where the base map is already the only skin tier and its texels blow past 2 px), `BLOCK_LOD_ORBIT_PX` (target on-screen megablock px, 1.5).
- **Files**: new `world/facet_block_lod_orbit.gd` (the disc mesher + LRU ledger, sibling of `FacetFarRing`, reusing `FacetBlockLod.get_level(n)` columns + the greedy-merge/skirt/weld discipline); wire in `world/world_manager.gd` next to the far-ring/skin creation (gated construction, like `_facet_tex`/`_skin`); `world/tier_place.gd` gains the block-LOD depth-bias entry (between skin and far ring); `world/facet_far_ring.gd` gains a "suppress §2V above swap" hook (release base/band/close-up when the orbit block mesh reports full coverage).
- **Gate** (`verify_block_lod.gd` extended): G-BLD-ORBIT-MIN (megablock top ≤ true terrain), G-BLD-ORBIT-BYTES (ledger == arithmetic, LRU never evicts the resident disc, ≤ `BYTES_MAX`), G-BLD-ORBIT-LEVEL (per-facet level == `d_max` ladder for a given cam), G-BLD-ORBIT-COVER (no hole: every front-hemisphere facet has a block tile OR the sunk ring under it), FLAT 6042/0 with the flag off.
- **Live snapshot check**: teleport to alt 8000 via the nadir-lock dev op (`DevInstrument`), face nadir; expect **crisp megablocks with hard voxel edges, no §2V blotch**, round silhouette + rim intact, vmem within `BYTES_MAX` (skin freed), fps ≥ shipped orbit (36). Descend through the swap: expect dither cross-fade, no pop, no bake stutter.

---

## 3. Future "ultimate skin": per-fragment procedural surface colour (NOT this phase)

Considered and deferred. Instead of *any* texture, compute the surface colour **in the far-ring / block-LOD fragment shader** from the worldgen, giving **zero texture memory** and **infinite resolution** with **no bake latency**.

The colour law is already isolated and small: `SurfaceShot.surface_shot` (`world/surface_shot.gd:40`) + `FarPalette.color_for` (`far/far_palette.gd:213`) map `(g, biome, continent, temperature)` → one of ~16 palette colours via a nearest-key classifier (`FarPalette.detail_pattern`, `:194`, 16 keys) plus the sea/snow/biome branches, times analytic AO/hillshade (`SurfaceShot._shade`, `:59`). Porting *that* to GLSL is cheap. **The expensive part is the input**: `TerrainConfig.column_profile` (the height/biome/climate sampler) must be ported to GLSL too — the multi-octave noise + climate curve on gl_compat/ANGLE. That is a real worldgen-in-shader port and a per-fragment cost budget question.

Mark it the eventual **ultimate skin** that could supersede BOTH the §2V bake AND per-block textures (it is resolution-free and memory-free), gated behind its own `FP_PROC_SKIN`, with a measured per-fragment ms budget. **Not this phase** — the blocky-from-orbit geometry is the user's active want and needs no shader worldgen port.

---

## 4. Generic per-body config — any planet/planetoid/moon from a config

The engine already has a **partial** per-body foundation but leaks Earth constants throughout. The plan: one `BodyConfig` registry every subsystem reads, filled from a **default Earth config first** (byte-identical refactor), then extended per body.

### 4.1 What is ALREADY per-body (keep, route through the config)
| Parameter | Accessor | File |
|---|---|---|
| radius (blocks) | `CosmosGravity.r_vox(body)` = `EPH.radius_of(body)` | `cosmos_gravity.gd:47` |
| GM (dynamic / real / feel) | `gm_dyn/gm_real/feel_g(body)` | `cosmos_gravity.gd:54,68,60` |
| orbit (a, parent, m0, spin, tidal, ecc, incl, axial_tilt) | `CosmosEphemeris.BODIES[body]` | `cosmos_ephemeris.gd:69–89` |
| facet grid (k, r) | `FacetAtlas.BODY_TABLE` | `facet_atlas.gd:25–27` |
| worldgen surface | `TerrainConfig.resolve_cell` Earth/Moon branch | `terrain_config.gd` (`SEED_MOON`, `MOON_*`) |
| atmosphere presence | `OrbitalState.has_atmo(body)` | `orbital_state.gd:437` |

### 4.2 What is GLOBAL / Earth-hardcoded (the leaks to fix)
| Parameter | Current global | File:line |
|---|---|---|
| **atmosphere ceiling** | `ATMO_TOP = 384` (user-locked for Earth) | `cube_sphere.gd:1020` |
| **`has_atmo`** | `return body == "earth"` — literal | `orbital_state.gd:437` |
| rim scale height / mult | `H_RIM = 48`, `SHELL_RIM_MULT = 1.0` | `cosmos_sky.gd:477,471` |
| Rayleigh sky hue | `RAYLEIGH_BLUE = (0.15,0.38,0.92)` | `cosmos_sky.gd:463` |
| day length / spin | `DAY_GAME` used as Earth `spin_period`; obliquity `axial_tilt=0.4084` only Earth | `cosmos_ephemeris.gd:77,82` |
| sea level | `SEA_LEVEL = 0` | `terrain_config.gd:70` |
| Moon terrain/craters | `MOON_BASE_HEIGHT`, `MOON_CRATER_*`, `SEED_MOON` (a *second hardcode*, not a config) | `terrain_config.gd:36–54` |
| climate / biome params | Earth-tuned ClimateModel constants | `climate_model.gd` |
| block-LOD / skin resolutions | `BASE_TEXELS`, `CELLS`, `BLOCK_LOD_*`, `CLOSEUP_*` | `cube_sphere.gd`, `facet_far_ring.gd:19`, `facet_tex_baker.gd:33` |

### 4.3 The `BodyConfig` registry + accessor pattern
A single frozen registry `BodyConfig.BODIES[body] → { r_blocks, k, atmo_ceiling, has_atmo, sea_level, rim_h, rim_mult, rayleigh, day_period, axial_tilt, terragen: {seed, profile, crater_cfg…}, palette, lod: {far_cells, base_texels, block_lod_bytes…} }`, with typed accessors `body_cfg(body).atmo_ceiling`, `body_cfg(body).rayleigh`, etc. Every subsystem (generator, far-ring/skin renderer, atmosphere/sky, cruise/orbital) reads the **dominant body's** config instead of a global:
- `OrbitalState.has_atmo(body)` → `body_cfg(body).has_atmo`
- atmosphere/rim/sky reads → `body_cfg(dominant).atmo_ceiling / rim_h / rayleigh` (Moon: `has_atmo=false`, ceiling 0 ⇒ no rim, star-black limb — already the airless-moon intent)
- worldgen → `body_cfg(body).terragen` selects the Earth vs Moon (vs new planet) surface law + seed + crater kernel, replacing the hardcoded Earth/Moon branch
- block-LOD/skin → `body_cfg(body).lod` (a small planetoid needs fewer facets/texels)

### 4.4 Phasing (byte-identical first)
- **C0** `FP_BODY_CONFIG` (default OFF byte-identical): introduce `BodyConfig` with the **Earth row == today's globals verbatim** (asserted, like `facet_atlas.gd:96` asserts the Earth BODY_TABLE row mirrors `K/R_BLOCKS`). Route the existing globals through `body_cfg("earth").*` at each call site; with the flag reading Earth's row the values are identical ⇒ FLAT 6042/0.
- **C1**: fold `has_atmo`, `ATMO_TOP`, `H_RIM`, `RAYLEIGH_BLUE`, `SEA_LEVEL` into the config; Moon row makes the airless path fall out generically (no `body == "earth"` literals).
- **C2**: fold worldgen (`terragen` profile + seed + crater cfg) + climate/biome params; the Earth/Moon `resolve_cell` branch becomes a config dispatch — a **new** planet is then a new row, no code branch.
- **C3**: fold the LOD resolutions; a small planetoid gets a smaller ledger automatically.

This is the standing rule (MEMORY: kernels already per-body; the residue is *wiring*, and per-body genericity should be a config route, not a special-case). It is a **parallel track** to §2 — the orbit block mesh reads `body_cfg(body).r_blocks/lod` from day one so it is generic by construction.

---

## 5. Phased plan (impact ÷ risk, playability-first)

Ordered; each = one flag + measurable win + headless gate + live snapshot + memory delta.

| Phase | Flag | Deliverable | Gate | Mem delta | Live check |
|---|---|---|---|---|---|
| **P0 (BUILD FIRST)** | `FP_BLOCK_LOD_ORBIT` | Mesh the visible orbit disc as **distance-laddered megablocks** (L4 nadir → L5 limb), riding the scaled-body clamp, over the sunk far ring; **retire the §2V base/band/close-up above the swap**; dither cross-fade | G-BLD-ORBIT-MIN/BYTES/LEVEL/COVER; FLAT 6042/0 off | ≈ 0 to +8 MB (skin freed ≈8.2, mesh +8–16, cap 12–16) | alt 8000 nadir: crisp megablocks, no blotch, rim intact, no bake stutter, fps ≥ 36 |
| **P1** | `FP_BLOCK_LOD_LADDER` | Extend the crisp band **down** into fly (L2/L3 in the 700–2800 band), LRU + hysteresis, so approach is crisp-blocky all the way (kills #72 smooth→blocky swap + envelope poke) | G-BLD ladder/LRU/dither; live fps/heap A/B | within `BLOCK_LOD_BYTES_MAX` 16 MB | fly descent 4000→800: continuous blocky, no representation swap |
| **C0–C3** (parallel track) | `FP_BODY_CONFIG` | `BodyConfig` registry; route Earth globals through it (byte-identical), then fold `has_atmo`/atmo/rim/sea, worldgen+climate, LOD res per body | assert Earth row == globals; FLAT 6042/0; Moon airless falls out | 0 (refactor) | Moon orbit: airless (no rim), correct radius/gravity from config |
| **P2** | `FP_BLOCK_LOD_REALBAKE` | L0/L1 megablocks from **live voxels + edits** (player towers/quarries appear as coarse lumps at range) + edit cascade | G-BLD-EDIT (cascade == from-scratch) | within cap | build a tower, fly up: it survives as a lump |
| **P3 (last)** | `FP_PROC_SKIN` | Per-fragment procedural surface colour in-shader (port `column_profile`+`color_for` to GLSL) — zero-texture ultimate skin, supersedes §2V + per-block texture | G-PROC-COLOR (shader == GDScript colour, per-fragment ms budget) | **−8+ MB** (drops the base map) | orbit: infinite-res colour, zero bake, within ms budget |

**The single first phase to build: P0 `FP_BLOCK_LOD_ORBIT`** — it is the user's active want (crisp blocky from orbit), it *reduces* bake dependence (retires §2V + its on-the-fly page rebakes), it is net memory-neutral-to-positive under a hard cap, and it is headless-gateable (the pyramid data + greedy mesh are pure) with a concrete live snapshot at alt 8000.
