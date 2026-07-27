# COSMOS-TEXTURED-LOD-DESIGN — Textured real-block-surface far-terrain LOD

**The user's core visual vision: far terrain = the SAME world at lower resolution — "scaled-down
screenshots of the real facets rendering with real blocks surface" projected onto decimated blocky
geometry. NOT low-res colored skins, NOT unblended plain-colored squares.**

Status: DESIGN (Fable). Parents: `docs/COSMOS-LOD-TEXTURE-DESIGN.md` (the FP_FACET_TEX satellite
texture — the TEXTURE mechanism), `docs/COSMOS-BLOCK-LOD-DESIGN.md` (the decimated-block pyramid —
the GEOMETRY mechanism), `docs/COSMOS-SEAMLESS-SCALES-DESIGN.md` (composition law §0.5),
`docs/COSMOS-NO-PROTRUSION-FIDELITY-DESIGN.md`.

Code citations are pinned to **`deploy/cheats-eyeball`** (the live deploy line: FP_BLOCKY_FARRING +
block-LOD P0 + FacetTexBaker Phases 1/2/4 + FP_BOOT_ASYNC) except `facet_block_lod_ring.gd`, which
exists only on **`feat/voxiverse-block-lod-p1`**.

---

## 0. The one-sentence synthesis (and why it is small)

**Both halves of the user's vision are already built and shipped separately; they are currently
mutually exclusive by a single early-return.** `FacetFarRing._emit_cached` routes to `_emit_blocky`
*before* the texture branch:

```gdscript
# facet_far_ring.gd:2129-2132 (deploy/cheats-eyeball)
if CubeSphere.FP_BLOCKY_FARRING:
    return _emit_blocky(st, pos, col, cells, stride)   # ← no UVs ever emitted
var tex := _tex_on()                                   # ← the FP_FACET_TEX UV/UV2 path, never reached
```

`_emit_blocky` (:2034-2094) emits flat-topped mega-blocks with **one vertex color per cell**
(`var c: Color = col[i0]` — one corner's palette color painted over a 26–104-block top). That is
the "unblended plain-colored squares" the user rejected — and its own doc comment already names the
fix: *"tex-UV mapping is added by the caller's tex branch (v1: vertex-colored)"* (:2038). The blocky
deploy therefore shipped with FP_FACET_TEX off — not because the texture failed, but because the
blocky geometry couldn't receive it.

**The design: emit the FP_FACET_TEX UVs on the blocky geometry.** The baked satellite pages (real
top-block colors, box-averaged — a literal downscaled screenshot of the block surface, §2) then
paint every mega-block top and wall with the actual image of the blocks it decimates. One flag, ~40
lines in `_emit_blocky`, zero new shader strings, zero new memory.

## 1. Chosen synthesis: (a) texture the blocky geometry with the satellite pages

### 1.1 The decision

Of the lead's options:

- **(a) UV the blocky/decimated geometry into the baked face pages — CHOSEN.**
- (b) keep the smooth textured shell, drive its geometry from block-LOD heights — **rejected**: the
  silhouette would be blocky but every surface would still be the smooth welded sheet; the user
  explicitly rejected the smooth representation ("no representation swap"), and BLOCK-LOD-DESIGN §0
  locked "far terrain = the SAME blocky surface at power-of-2 block sizes". (b) is also *more* code:
  a new height source for `_ensure_cached` instead of a UV channel on an existing emit.
- (c) per-mega-block flat color from the pyramid's MAJORITY id — **rejected as the end state**
  (kept as the automatic fallback where texel pitch ≥ block pitch): it is Distant Horizons' flat
  biome-color look, i.e. exactly the "low-res colored skins" clause of the rejection. The baked
  image gives per-fragment variation *within* a mega-block top — the downscaled screenshot — which
  flat colors cannot.

**Why (a) is right structurally**: the satellite texture already *is* "the real block surface,
downscaled" (§2); the blocky geometry already *is* "the real relief, decimated, no-protrusion by
MIN-containment" (`_emit_blocky` corner-MIN, block-LOD `decimate()` MIN rule,
`facet_block_lod.gd:91-134`). Composing them per-fragment inside the one opaque shell material is
precisely the locked composition law (SEAMLESS-SCALES §0.5: albedo blends in-material, geometry
composes by overlap+sink — never alpha layers). Nothing new has to stream, page, or sort.

### 1.2 Mechanics — far ring (the T1 core)

Under a new flag `FP_BLOCKY_TEX` (requires `FP_BLOCKY_FARRING && FP_FACET_TEX &&
FP_SHELL_ABSOLUTE`, mirroring `_tex_on()` at `facet_far_ring.gd:2256-2257`):

1. `_emit_blocky` gains the same UV/UV2 emission the smooth path has (:2144-2167):
   - **Top quad** of cell `(gi,gj)`: UV at the 4 corners = the node params
     `((a + node_s)/K, (b + node_t)/K)` — the identical pure function of loop indices the smooth
     emit uses (:2155). The top face then samples the baked image *across* its footprint: a
     104-block horizon cell shows a 4×4-texel patch of real terrain; a 26-block backstop cell
     shows ~1 texel + bilinear gradient.
   - **Walls and skirts** (`_emit_wall`, :2094): all 4 verts take the UV of the wall's **top edge**
     nodes — the wall wears a vertical smear of its own top's image stripe (the DH side-color
     idiom, upgraded from flat color to the local texel).
   - **UV2** = `(face, _slot_of(fid))` per vertex — the existing per-facet constant (:2144).
2. **No shader change.** The blocky mesh binds the already-shipped `_SHELL_ABS_TEX_SHADER` /
   close-up variant (:2381-2495) selected exactly as today (:2497-2505). The coverage-gated blend
   is already live-hardened: `wt = smoothstep(600,1800,cam) * tx.a` with premultiplied-alpha
   un-premultiply (:2416-2428) — an un-baked facet shows the shipped vertex-color blocks (never
   black), a baked one cross-fades to the satellite image.
3. **Geometry is untouched by the flag** — `FP_BLOCKY_TEX` adds two vertex channels and nothing
   else; no-protrusion (G-BLK-RING) and the mesh silhouette are bit-identical with tex on/off.

Thread contract unchanged: `_emit_blocky` already "reads only the passed arrays (thread-safe on the
worker)" (:2039); UVs are pure index arithmetic.

### 1.3 Mechanics — block-LOD L2 tiles (T3)

`FacetBlockLodRing._mesh_l2` (`facet_block_lod_ring.gd:174-250`, branch p1) emits per-column flat
tops from the P0 pyramid with `FarPalette.color_for` vertex colors (:200). Under
`FP_BLOCK_LOD_TEX` (requires `FP_BLOCK_LOD && FP_BLOCKY_TEX`):

- Top-quad UVs from the column's lattice node params (the tile already computes node positions on
  the `(w+1)×(h+1)` corner lattice, :203-206 — UV is the same nodes divided through the facet-grid
  param, one line next to `_node_dir`); walls/skirts inherit top-edge UVs; UV2 = `(face, slot)`.
- Material: the tile already mirrors the far ring's shared material verbatim (`_mat`, :35, :46-48)
  — so the textured shader arrives **for free, zero new compiles**. One change: the tile band sits
  at 700–1400 blocks (`BLOCK_LOD_BAND_MIN/MAX`, p1 `cube_sphere.gd:523-524`) where the shipped
  literal ramp `smoothstep(600,1800,…)` gives wt≈0.06–0.66 — half vertex-color. Fix: hoist
  `TEX_D0/TEX_D1` from literals to shader **uniforms** (defaults 600/1800 ⇒ ring visual
  unchanged), give the L2 tiles their own `ShaderMaterial` sharing the **same `Shader` object**
  (same compiled program — zero new ANGLE compiles) with `TEX_D0=300, TEX_D1=700` so tiles are
  fully textured across their band.

### 1.4 Resolution pairing (which texel tier feeds which block pitch)

| Geometry | block pitch | albedo source | texels per block top |
|---|---|---|---|
| near voxels 0..128 | 1 | real per-block textures (`FP_ATLAS_MATERIAL`) | native |
| L2 tiles 700..1400 | 4 | close-up pages 3.3 blk/texel (base-map fallback) | ~1.2 — per-block color |
| backstop ≤ horizon | 26 | base map 26 blk/texel | ~1 + bilinear |
| horizon cells | 104 | base map | 4×4 patch |
| orbit / whole planet | — | base map + close-up cap | the satellite image |

Every hue at every tier derives from `BlockCatalog.color_of` via `FarPalette.color_for`
(`far_palette.gd:36-63`, `sample_columns` colors) — the near blocks and the far image track the
catalog together by construction, so the blend is hue-stable end to end.

**Filter knob (disclosed)**: `filter_linear_mipmap` gives the "scaled-down screenshot" gradient
across a mega-block top; if the user prefers DH-crisp one-color-per-texel blockiness, a
NEAREST-filter (or UV-quantize-to-texel-center) variant is a one-uniform A/B — decide at T5 live
review, not now.

## 2. Bake source: analytic `sample_columns` composite — RTT rejected (again, harder)

The user's words are "screenshots of the real blocks surface". The analytic bake **is that
screenshot, computed instead of photographed**: `FacetTexBaker.sample_fine` samples a 32²-column
grid per facet through `VoxelGeneratorCosmos.sample_columns` — each fine texel is the actual top
block's catalog color at that column, the same pixel a top-down orthographic render of the meshed
blocks would produce — then box-averages 2×2 into the stored page (`facet_tex_baker.gd:13,
145-194`). Downscaling the fine grid *is* "scaling down the screenshot".

RTT (SubViewport top-down render of the near mesh) is rejected for the same reasons
LOD-TEXTURE §1.1 gave, which have only gotten stronger since:

1. **You cannot photograph what isn't meshed.** Only the ≤128-block near disc + pool neighbours
   ever have real voxel meshes; 3450+ facets would have nothing to shoot.
2. **WebGL readback stalls**: per-bake `get_image()` is a multi-ms GPU sync on ANGLE, on the main
   thread, times thousands of facets — vs. the C++ `sample_columns` at 1-3 ms/facet off the render
   pipeline, already budget-sliced under `FACET_TEX_BAKE_BUDGET_MS=2.0` with check-before-each-unit
   discipline (`facet_tex_baker.gd:223-251`).
3. **Determinism**: the analytic bake is byte-reproducible and headless-gateable (G-FT-BAKE); an
   RTT is neither (GPU/driver variance), so every gate downstream would weaken.
4. The honest fidelity delta of analytic vs. a true screenshot: per-block AO/side-shading and
   `FP_ATLAS_MATERIAL` intra-block texel detail. Both are sub-texel at ≥3.3 blocks/texel — invisible
   at every distance where the texture is sampled (wt ramps in from 600 blocks). Canopy tint is
   already encoded in `FarPalette._forest/_taiga/_jungle` (R8 of the parent doc); per-column
   TreeGen-hash darkening stays the disclosed v2 refinement.
5. Player edits — the one thing a live screenshot would capture that the pure generator doesn't —
   are the parent doc's **Phase 3 `FP_FACET_TEX_EDITS`** (fid-keyed choke-point invalidation at
   `_write_cell`/`sim_revert_cell` + incremental splat), which composes with this design unchanged:
   it re-bakes the *pages*; blocky geometry and L2 tiles read the same pages.

## 3. Near→far blend — no swap, ever

The #1 aesthetic requirement decomposes into three independent mechanisms, all existing:

1. **Representation continuity**: blocks at every tier — 1-block voxels → (P2 ladder: 2-blk L1) →
   4-blk L2 tiles → 26-blk backstop → 104-blk horizon mega-blocks. Only pitch changes. The smooth
   welded look survives nowhere the eye can land (the sunk smooth backstop is *under* the blocky
   emit when covered; FacetSkinTier stays retired — BLOCK-LOD §6).
2. **Geometric containment, not stitching**: every coarser tier is pointwise ≤ the finer one
   (corner-MIN `_emit_blocky`:2050-2053; pyramid MIN-decimate `facet_block_lod.gd:21`; env sink) —
   finer strictly overdraws coarser in the overlap band, skirts close silhouette steps
   (`_emit_blocky`:2055, `_mesh_l2`:240-244). No swap event exists in the geometry at all.
3. **Albedo continuity, per-fragment, in one opaque draw**: near real block textures →
   `wt·tx.a`-blended satellite image over the same catalog-derived vertex colors — the shipped
   coverage-gated ramp (:2416-2428). Temporal arrivals (L2 tile build/evict) use the block-LOD
   design's 0.3 s screen-door dither (§4), never transparency.

Descent path (orbit → touchdown): satellite image (close-up cap sharpening from d≈4000) → textured
104-blk mega-blocks → textured 26-blk backstop under them → textured 4-blk L2 tiles at 700 →
vertex-color/texture ramp hands back below 600 exactly where near voxels + `FP_ATLAS_MATERIAL`
per-block textures take over. Every hand-off is a fragment blend or a sink-overdraw.

## 4. Close-up pages in the surface regime (T2)

The close-up tier today is **off-surface only** — on-surface it evicts every promotion
(`facet_tex_baker.gd:240-244`). But the L2 tile band (700–1400) is a *surface* feature needing
3.3-blk/texel pages: the annulus is ~26 facets (π·(1400²−700²)/417²), comfortably inside
`CLOSEUP_MAX=64`. Under `FP_FACET_TEX_SURF` (requires `FP_FACET_TEX_CLOSEUP`):

- On-surface, `_recompute_want` targets the band annulus around the active facet's centre
  (`_facet_centre_dir` idiom, `facet_block_lod_ring.gd:102-105`) instead of evicting; LRU and the
  75%-budget split (:239) unchanged; eviction remains outside-band-only (wc≈0 there → invisible,
  the G-FT-SLOT invariant).
- Off ⇒ the shipped evict-on-surface branch verbatim.
- Fallback is already safe: slot −1 ⇒ base map (softening, never a hole).

## 5. NEVER-OOM ledger (combined, explicit)

| Subsystem | Ceiling | Enforcement |
|---|---|---|
| FacetTexBaker base pages (GPU 4.7 MB + staging 3.5 MB) | 8.2 MB | fixed-size at creation (parent §4) |
| Close-up pages (GPU 5.6 + staging 4.0) | 9.6 MB | 64 layers fixed; LRU outside-cap only |
| `FACET_TEX_BYTES_MAX` subtotal | **20 MB** | `total_bytes()` ledger; wholesale-clear on breach |
| Blocky far-ring mesh delta (walls/skirts vs smooth) | ≤ ~3× shipped ring surface bytes; **0 new data memory** (same `_pos/_col` caches, :2034-2094) | measured by gate G-BT-BYTES; transient single merged mesh |
| L2 tiles `BLOCK_LOD_BYTES_MAX` | **16 MB** | per-tile ledger + LRU + wholesale-clear (`facet_block_lod_ring.gd:28-31,134-136,153-161`) |
| **`FP_BLOCKY_TEX` / `FP_BLOCK_LOD_TEX` themselves** | **+2 UV channels on existing meshes (~+25% mesh bytes), 0 textures, 0 staging** | flag-gated array construction |
| **Combined worst case (all flags)** | **≈ 36 MB + ring delta** | new gate **G-TL-LEDGER** sums all three ledgers and asserts the arithmetic every step |

All ceilings are structural (fixed-size buffers, capped LRUs); every breach response is wholesale
clear + re-prewarm, never partial thrash. Zero-extra-memory when off: every piece is gate-constructed
(`world_manager.gd:366-373` pattern).

## 6. Does this retire the plain-blocky far ring? (the subsume question)

**There is no second system to retire — the plain look is upgraded in place.** FP_BLOCKY_FARRING
*is* the geometry carrier of this design; `FP_BLOCKY_TEX` converts its albedo from
one-corner-color-per-cell to the baked image. We keep exactly ONE far-geometry system (the ring +
its L2 tile sibling) and ONE texture system (the baker). What is retired / already handled:

- **The plain-color look**: gone wherever a page is baked (coverage-gated, degrades to plain —
  never worse than today).
- **The re-emit churn / render hang**: was redundant *geometry* re-uploads of an identical
  hemisphere set — root-caused and guarded (`FP_SHELL_CLIMB_NO_CHURN`, comment at
  `facet_far_ring.gd:440`). Texture updates make this structurally better: an albedo change is a
  384² **page upload** (`texture_2d_update`, 576 KB/layer), never a mesh rebuild. Geometry now only
  rebuilds on coverage/role changes.
- **The ~90 s boot cache**: already deferred (`FP_BOOT_ASYNC`, `cube_sphere.gd:719-734`). The bake
  rides the same posture: T4 replaces the synchronous `prewarm(visible_fids)` at setup
  (`world_manager.gd:368`) with the progressive budgeted path (`_bake_base_progressive`,
  `facet_tex_baker.gd:259-273`) behind the boot-screen "essential ready" milestone (task #75
  hooks) — coverage-gating means partial coverage is cosmetically safe from frame one.
- **FacetSkinTier**: stays superseded (BLOCK-LOD §6); `FP_SKIN_TIER` never re-enables (closes #60
  by obsolescence).
- **v2, flagged, later**: suppress the ring's backstop emission where a resident L2 tile fully
  covers the band (`FP_FARRING_SUPPRESS_COVERED`) — a perf knob, not a correctness need (the sink
  law already hides it).

The blocky rebuild does bypass the memcpy fast path (`facet_far_ring.gd:1247-1249` routes blocky to
`_build_surfacetool`); if live crossing telemetry shows it matters, a pre-triangulated *blocky* tri
soup cache is the symmetric fix — a T4 knob, default off.

## 7. Web/ANGLE constraints

- **Draw calls**: ring stays **ONE** opaque draw (merged mesh, per-fragment blend — no layers). L2
  tiles add ≈ band population (~26) draws (`_tiles` one MeshInstance each) — small against the
  204-draw budget; merging the band into one ArrayMesh per update is a v2 draw-cut if needed.
- **Shader variants**: **zero new shader strings.** T1/T3 reuse `_SHELL_ABS_TEX_SHADER` /
  `_SHELL_ABS_TEX_CLOSEUP_SHADER` verbatim; variant choice stays static-per-session (:2497-2505) so
  exactly one shell program compiles, same as today. The T3 `TEX_D0/D1` literal→uniform hoist edits
  the *existing* strings (no additional variant; defaults reproduce today's bytes-on-screen). The
  ~3 s/compile ANGLE cost is untouched — this design adds **0** compile frames.
- **`sampler2DArray` on ANGLE (parent R6)**: the one item never visually confirmed live (memory:
  user-morning eyeball pending when the blocky deploy turned TEX off). T1's live smoke *is* that
  confirmation; the specified fallback (single 2304×384 ImageTexture + packed-face UVs) is
  unchanged and costs only upload granularity.
- **No HDR / gl_compat**: the blend multiplies the existing `shade·tint` law in-shader (:2426-2428)
  — no new lighting path, terminator/night gates (G-AS-TERM) unaffected.
- **Threaded export**: bake on main under a 2 ms check-before-unit budget (shipped discipline);
  UV emission rides the existing async ring worker unchanged.

## 8. Staged plan — flags, gates, each shippable + FLAT 6042/0 + byte-identical off

| Stage | Flag (requires) | Delivers | Gates |
|---|---|---|---|
| **T0** design-validate | — (no engine code) | headless combined-flags build proving today's mutual exclusion (blocky mesh has no `ARRAY_TEX_UV`) + full baseline suites green on the integration branch | existing: verify_facet_tex, G-BLK-RING, verify_block_lod, FLAT 6042/0 |
| **T1** textured blocky ring | `FP_BLOCKY_TEX` (BLOCKY_FARRING ∧ FACET_TEX ∧ SHELL_ABSOLUTE) | UV/UV2 in `_emit_blocky` tops+walls+skirts; **the vision visible from orbit + horizon** | **G-BT-OFF** (flag off ⇒ blocky surface arrays bit-identical), **G-BT-UV** (every blocky vert's UV inside its facet rect; wall UV == top-edge UV), **G-BT-NOPROT** (geometry identical tex on/off), G-BT-BYTES; live smoke = R6 confirm |
| **T2** surface close-up | `FP_FACET_TEX_SURF` (FACET_TEX_CLOSEUP) | band-annulus page promotion on-surface (no more evict-all) | **G-FT-SURF** (band facets promoted ≤64 slots; eviction outside-band only; off ⇒ evict-all branch verbatim) |
| **T3** textured L2 tiles | `FP_BLOCK_LOD_TEX` (BLOCK_LOD ∧ BLOCKY_TEX) | UVs in `_mesh_l2`; shared-Shader second material with `TEX_D0/D1` uniforms (300/700) | **G-BLD-UV**, G-BLD suite re-run, **G-TD-UNIFORM** (default uniforms ⇒ ring pixels/bytes unchanged) |
| **T4** boot + churn hygiene | rides `FP_BOOT_ASYNC` (no new flag) | async prewarm→progressive bake behind boot milestone; churn-guard verified under textured blocky; combined ledger telemetry | **G-TL-LEDGER**, G-FT-BUDGET re-run with blocky on, boot-time budget assert |
| **T5** flip + retire plain | sed-ON at export: BLOCKY_FARRING, FACET_TEX(+CLOSEUP, +SURF), BLOCKY_TEX, BLOCK_LOD(+TEX) | live A/B (Xvfb sweep: orbit both hemispheres, descent, horizon, night limb, cube edges) + browser-heap A/B; NEAREST-vs-LINEAR filter call; optional `FP_FARRING_SUPPRESS_COVERED` | the only visual-judgment stage; rollback = flags off (byte-identical by the T1-T3 gates) |

Order rationale: T1 is the largest visual payoff per line of code and carries the single open
platform risk (R6) to live proof *before* anything builds on it; T2/T3 are independent after T1;
T4 is pure hygiene; T5 is judgment. Each stage off ⇒ the previous stage's exact bytes (the
`FP_SHELL_WELD` textually-separate-branch pattern throughout).

## 9. Risks

| # | Risk | Mitigation / catch |
|---|---|---|
| 1 | `sampler2DArray`/per-layer update on ANGLE (inherited R6 — never eyeballed live) | T1 live smoke first; specified single-ImageTexture fallback |
| 2 | Texture "swims" over flat mega-block tops (bilinear gradient reads as non-blocky) | disclosed aesthetic knob (§1.4): NEAREST/texel-quantize A/B at T5 — one uniform, no recompile |
| 3 | Blocky SurfaceTool rebuild slower than memcpy fast path on crossings | shipped churn guard + async worker already cover; pre-triangulated blocky soup cache as T4 knob |
| 4 | wt ramp mismatch for L2 band | TEX_D0/D1 uniform hoist (T3), G-TD-UNIFORM pins default-equivalence |
| 5 | Combined memory (~36 MB worst) | per-subsystem structural ceilings + G-TL-LEDGER + T5 browser-heap A/B before any sed-ON |
| 6 | Bake coverage lag on fresh spawn (textureless far ring for seconds) | coverage-gated alpha ⇒ degrades to today's shipped look, never worse; nearest-first priority + boot milestone |
| 7 | Cube-edge texture seams on blocky walls | same argument as parent R1 (one continuous page per face; edge texels agree by worldgen continuity); T5 limb screenshots at the 12 edges |

## 10. Rejected alternatives (summary)

- **SubViewport RTT bake** — cannot photograph unmeshed facets; readback stalls; non-deterministic
  (§2). The analytic composite produces the same pixels.
- **Smooth shell over block-LOD heights** (option b) — keeps the rejected smooth representation (§1.1).
- **Flat MAJORITY-id color per mega-block** (option c) — is the rejected "low-res colored skin";
  survives only as the automatic sub-texel fallback.
- **Alpha-blended tier cross-fades** — locked out (SEAMLESS-SCALES §0.5): sorting hazard + double
  fill on WebGL2; all fades stay per-fragment in one opaque material or screen-door dither.
- **A new texture system for mega-blocks** (per-block atlas tiles on LOD geometry) — duplicates the
  baker; the satellite pages already carry the per-column real-surface image at every needed pitch.
