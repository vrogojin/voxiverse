# COSMOS-SEAMLESS-TRANSITION-DESIGN — the FAR→NEAR planetary approach

**Make the near-blocks ↔ far-skin hand-off imperceptible during fly-up, fly-down and horizon view — Elite-Dangerous/Star-Citizen-grade approach continuity under gl_compat/WebGL2, NEVER-OOM, flag-gated.**

Status: DESIGN (Fable). Parent docs: `docs/COSMOS-TEXTURED-LOD-DESIGN.md` (§2V real-shot far skin — closed the **color** gap), `docs/COSMOS-BLOCK-LOD-DESIGN.md` (decimated-block pyramid, impl in flight, task #76), `docs/COSMOS-SEAMLESS-SCALES-DESIGN.md` (locked composition law §0.5: no alpha cross-fade between tiers; overlap + shared sampling + sink), `docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md`, `docs/COSMOS-FARRING-COVERAGE-DESIGN.md`.

User requirement (verbatim, paraphrased): *"When I fly up a little, the near blocks stop rendering and there's an immediate, clear transition to the far terrain — it is NOT seamless. It must be a seamless transition from FAR to NEAR so I don't notice a difference during an approach."*

---

## 0. Ground truth — the exact pop mechanisms (verified file:line)

The §2V skin matched far **albedo** to the near world (V1 one shade law, V2 real-shot band, V3 shot pages). What remains is a **geometry/relief/parallax gap** plus one **streaming-policy event** that reveals it all at once. Four mechanisms, in causal order:

### 0.1 THE headline cause: the near field unloads at h ≈ 64 because the viewer rides the player

`module_world.attach_viewer` (`godot/src/world/voxel_module/module_world.gd:2852-2877`) instantiates ONE `VoxelViewer` as a **child of the player** with:

- `view_distance = TerrainConfig.near_render_radius() = 128` (`godot/src/world/terrain_config.gd:171-176`, CURVED),
- a symmetric vertical ellipsoid `view_distance_vertical_ratio` clamped by the A2 downward-reach clamp: up-reach **U = 128·0.5 = 64** blocks (`terrain_config.gd:190,213`), down-reach D = 40 (`terrain_config.gd:210`), i.e. half-height H = 52 centred at a +12 local offset (`terrain_config.gd:219-225`, applied at `module_world.gd:2875-2877`).

The viewer node **rises with the player**. A ground mesh block directly below the player leaves the ellipsoid when the player is ~**64 blocks up**; the whole near field is gone shortly after. That is precisely "fly up a little". godot_voxel unloads whole 16³ mesh blocks with **no fade** — each vanishes in one frame, instantly revealing the far skin behind it (the z-composite, §0.3). At h = 64 a single block still subtends ≈ `K_px/64 ≈ 1407/64 ≈ 22 px` (screen-space law, SEAMLESS-SCALES §3.1) — the unload happens **~2 orders of magnitude above** the ≈2 px invisibility threshold. This is a *streaming policy*, not a renderer or memory limit — the same class of finding as the orbital-shell fix (camera-set policy, not a new mesh).

The altitude freezes are NOT the visible cause (important discrimination): `_pool_off_surface` at `OFFSURFACE_Y = 256` (`godot/src/world/world_manager.gd:2613-2620`) freezes pool spawns, and `FP_ALT_REGIME` freezes near-field machinery above `ATMO_TOP = 384` (+prep/hyst, `world_manager.gd:526-537`, `cube_sphere.gd:1148-1161`). Both freeze CPU work; by the time they engage, §0.1 has already emptied the view.

### 0.2 What the reveal exposes: a flat painted shell with 26-block relief, historically sunk 13 blocks

The far ring (`godot/src/world/facet_far_ring.gd`) is the whole globe as one merged draw:

- **Geometry**: backstop facets (active ∪ live pool) at `BACKSTOP_CELLS = 16` per facet edge → **~26-block** height cells; every other facet at `CELLS = 4` (`facet_far_ring.gd:19`) → ~104-block cells. Backstop cells are radially sunk by `TierPlace.backstop_sink() ≈ 13` blocks at R=6371 (`godot/src/world/tier_place.gd:81-88`) unless `FP_FARRING_CULL_COVERED`+`FP_FARRING_LEVEL` (U2/U3, `cube_sphere.gd:618,648`; `tier_place.gd:104`) cull covered cells and collapse the sink to the ~1.5-5-block ε guard.
- **Albedo**: the §2V ladder — band facets (active ∪ ring-1, `BAND_LAYERS = 9`, `cube_sphere.gd:563-586`) render the RG8 real shot at **1 texel/block incl. trees + static shade** (`_BAND_SHOT_ALBEDO`, `facet_far_ring.gd:2880-2896`); farther facets the id-map/tiled and shot-page tiers. Color now matches near by construction; weight is bake-coverage-only (`wt = tx.a`, `facet_far_ring.gd:2743` — texture everywhere).
- **Lighting**: per-VERTEX `shade·tint` on the **planet-radial** normal (`facet_far_ring.gd:2720-2731`) — shared with near via `FP_SHADE_UNIFIED` (`cube_sphere.gd:601`), but with **no slope/relief response**: a mountainside and a plain shade identically.
- So the residual gap is exactly: per-block **relief** (1-blk → 26/104-blk cells), **3D trees → painted pixels**, **silhouette/parallax** (none), and (pre-U3) a **13-block level drop**.

### 0.3 The composite is a hard z-test with no cross-fade

Far is drawn everywhere; near voxel meshes overdraw it by depth (+`FAR_BIAS_K = 8` window-space bias, `tier_place.gd:40`). There is no blend band: the instant a near mesh block unloads (§0.1), its pixels flip to the far skin in one frame.

### 0.4 The standing horizontal boundary at the bubble rim (grazing view)

At walk level the near field ends at ~112-128 blocks; a rim block subtends `1407/112 ≈ 12.6 px`. Beyond it: the flat band skin. At grazing angles the missing relief/parallax is maximally visible. This is the second, always-present seam (independent of altitude) — task #72's "far too low" was one component (U2/U3 address the level); the relief step remains.

---

## 1. Survey — how the SOTA does seamless planetary approach, and what survives WebGL2/gl_compat

| Technique (who) | Mechanism | Verdict here |
|---|---|---|
| **Quadtree sphere patches** (Elite Dangerous) | Patch tree subdivides around the **camera's sub-surface point**; detail persists under you on climb and is released only when sub-pixel; new detail streams in on approach before it is discernible | **The core lesson → S1.** Anchor detail to the sub-camera ground point; release on screen-space error, not on altitude |
| **CDLOD vertex geomorph** (Strugar; Star Citizen planet tech) | CPU LOD meshes + per-vertex lerp between levels in the vertex shader (no tessellation needed) | Viable in WebGL2, but morphing **block** terrain reads as melting (rejected in BLOCK-LOD §4); reserve for smooth-mesh seams only (§6) |
| **Geometry clipmaps** (Losasso/Hoppe) | Nested rings around viewer, boundary morph | Same as above; our facet/ring architecture already plays this role |
| **Column LOD pyramid** (Distant Horizons, Minecraft) | Discrete power-of-2 blocky LODs, containment, overlap, fog; **no morph** — proves discrete steps read as seamless when each step is small and albedo-continuous | **Adopted** — this is FP_BLOCK_LOD (#76), the geometry backbone → S2 |
| **Dithered/stochastic LOD cross-fade** (Unreal dithered LOD, HZD) | Temporal screen-door discard during a swap | Viable (fragment `discard`); adopted for **tile arrival** fades (already in BLOCK-LOD §4). NOT as a standing spatial band — the locked law rejects co-resident alpha tiers (SEAMLESS-SCALES §0.5), and `discard` breaks early-z for the whole material |
| **Parallax-occlusion relief** (Tatarchuk) | Fragment ray-march against a height texture | Viable but 8-16 taps over horizon-filling far pixels is the riskiest budget on gl_compat; only as a narrow-band, grazing-angle-gated option (§5) — real coarse geometry (S2) is cheaper and better |
| **GPU continuous tessellation / screen-error subdivision** | Hull/domain or compute-driven | **Not available** on WebGL2 — excluded |

**The transition law this design adopts** (one sentence, testable): *a representation may hand off only when the detail it loses subtends ≤ τ px on screen, and both sides already share albedo and shade.* The albedo/shade half is **shipped** (§2V V1-V3). The τ half is codified nowhere for the near field — `LOD_TAU_PX = 3.0` exists for tier selection (`cube_sphere.gd:719`) but the near bubble unloads at ~22 px (§0.1). Every stage below is this law applied to one seam.

---

## 2. Staged plan overview

| Stage | Name | Attacks | Mechanism class | New memory | First-order risk |
|---|---|---|---|---|---|
| **S1** | `FP_APPROACH_ANCHOR` — ground-anchored viewer + SSE-timed release | §0.1 + §0.3 (the fly-up pop) | streaming **policy** (node position + view_distance ramp) | **0 bytes** | view_distance write churn |
| **S1b** | `FP_FARRING_LEVEL` live A/B flip | §0.2 (13-blk drop at reveal) | already implemented (U3) | 0 bytes | z-order fringe (biased) |
| **S2** | FP_BLOCK_LOD rings P1-P3 (in flight, #76) + transition addenda | §0.4 (rim/grazing relief) + descent steps | CPU coarse-block meshes, containment | 16 MB ledger (already budgeted in BLOCK-LOD §5) | draw calls / heap A/B |
| **S3** | Band height channel + POM (optional polish) | residual band flatness at grazing | fragment relief | +~2.6 MB (46→49 ceiling) | gl_compat fragment cost — likely **cut** |
| **S4** | North star: the τ-continuum (assessment) | everything residual | SSE-timed discrete steps + dither + one shade law | 0 | — |

Lead's starting hypothesis, challenged where due: the S1-as-crossfade idea is **refined into a policy fix** — a draw-composite cross-fade cannot fix content that is *no longer resident*; the pop is a streaming event, so the streaming policy is the correct layer (§3). Dither survives only as tile-arrival fade. The lead's S2 (relief on the far skin) is re-ranked **below** real coarse geometry (S2 here = the block pyramid) and kept as optional S3. The lead's S3 (intermediate tier) is exactly FP_BLOCK_LOD and is already being implemented — this doc specifies its transition contract instead of redesigning it. The lead's S4 (continuous geomorph) is **rejected** for block terrain with reasons (§6).

---

## 3. S1 — `FP_APPROACH_ANCHOR`: ground-anchored viewer + SSE-timed release *(FIRST SHIP)*

The Elite-Dangerous move, transplanted: keep the already-meshed near plate resident and anchored to the **sub-player surface point** while the player climbs; release it only when its blocks are sub-τ on screen; on descent, begin re-streaming at the same τ distance (earlier than today). Three parts, all policy:

### 3.1 (a) Anchor — a viewer-offset law, not a new system

Today the viewer sits at player + (0, +12, 0) local (`module_world.gd:2875-2877`). Under the flag, `WorldManager.update_streaming` drives the existing offset each frame (debounced) when airborne:

```
h        = player_alt_above_surface()          # analytic, already computed for the regime ladder
offset_y = clamp(O_clamp - h, -h + margin, O_clamp)   # pins the viewer to ~the sub-player surface point
```

i.e. the viewer node stays at the ground the player left, so the meshed plate remains inside the unchanged ±52 ellipsoid regardless of player altitude. Horizontal motion: the offset is vertical-only, so the anchor naturally tracks the sub-player point; horizontal streaming behaves exactly as walk streaming does today (same machinery, unchanged). The analytic physics never reads the voxel buffer (CLAUDE.md), so collision/floor queries are untouched — this is render/streaming-only, the same safety class as `DEV_HIDE_NEAR` (`module_world.gd:589-593`), which already proves both levers (offset/view_distance writes) are safe live.

### 3.2 (b) Release — the τ law, rim-first

A block at camera-distance d subtends `1407/d` px → sub-τ at `D_REL = K_px/τ ≈ 700` for τ = 2. As the camera's distance to the plate approaches D_REL, ramp `view_distance` down (the DEV_HIDE_NEAR lever) across a band (`ANCHOR_REL_LO = 700 → ANCHOR_REL_HI = 900`), so the plate recedes **rim-inward** — every block that unloads is already ≤ τ px, and the rim blocks (most foreshortened) go first. Above the band the plate is empty, exactly today's orbit state; `FP_ALT_REGIME`/`OFFSURFACE_Y` freezes engage unchanged and keep their perf wins (retained meshes above 384 are static draws — the frozen machinery never touches them).

**Descent bonus**: re-grow at `ANCHOR_REL_LO` with hysteresis — near streaming starts at ~700 instead of effectively ~416 (the alt-regime release, `world_manager.gd:531-535`), giving the stream ~300 blocks more warm-up before touchdown. This composes with (not replaces) `FP_LANDING_STREAM_KICK` and the V4 `FP_SKIN_SSE` monotone paint law: paint sharpens (V4) while real blocks stream in underneath (S1), each 16³ chunk arriving at ~`16·1407/700 ≈ 32` px where its only visible change is relief sharpening over an identical-albedo painted texel (§2V) — a sharpening, not a pop.

### 3.3 (c) Level hand-off — flip `FP_FARRING_LEVEL` (with U2) in the same deploy

Implemented (U2/U3); needs its live A/B. Without it every S1 reveal/steal still jumps 13 blocks vertically at the frontier. With it the revealed skin sits at the near surface's level (ε guard only), and z-order rides the shipped `FAR_BIAS_K` bias. S1 and S1b ship in one deploy — each is inert without the other's effect being tested anyway (independent flags, one A/B session).

### 3.4 Cost, gates, risks

- **Memory: zero new bytes.** Same viewer, same 128-block bubble, same `POOL_MEM_BUDGET_MB = 128` — the plate at altitude holds *at most* what standing on the ground holds today. `G-AA-BYTES` pins the voxel-memory ledger airborne == grounded.
- **Perf**: airborne frames re-gain the plate's draw cost (which ground frames already pay — the binding case is unchanged; the 138-186 draw ceiling is a ground number). Streaming cost while hovering is ~zero (content static, viewer static). Worst-frame A/B on the scripted ascent is the gate.
- **Flag**: `const FP_APPROACH_ANCHOR := false` in `cube_sphere.gd`; OFF ⇒ no per-frame offset/view writes, `attach_viewer` byte-identical, FLAT 6042/0 (the offset law requires FACETED like all cosmos flags). Consts: `ANCHOR_TAU_PX = 2.0`, `ANCHOR_REL_LO/HI = 700/900`, `ANCHOR_HYST = 1.15`, write-debounce ≥ 100 ms.
- **Gate `verify_approach_anchor.gd`**: **G-AA-OFF** (flag off ⇒ zero writes; byte-off suites unmoved) · **G-AA-ANCHOR** (scripted ascent 0→1200: viewer world-pos stays within ε of the sub-player surface point until the release band) · **G-AA-TAU** (at every step, no resident block farther than the τ distance is *required*, and no block nearer than `REL_LO/HYST` is *released* — monotone both directions) · **G-AA-BYTES** (ledger airborne == grounded) · falsify each by perturbation (e.g. break the clamp → G-AA-ANCHOR must fail).
- **Risks**: (R-S1-1) `view_distance` writes causing godot_voxel re-mesh churn — mitigated by debounce + monotone ramp (the FP-M1c ramp already does staged `max_view_distance` writes safely, `module_world.gd:425-436`); (R-S1-2) the plate reads as a "detail island" with a visible rim from mid-altitude — true today at ground level too (§0.4); albedo is matched now, and S2 closes the relief rim; (R-S1-3) fast horizontal flight at h < 700 outruns streaming — identical to today's fast-fly streaming behaviour, not a regression (G-AA-TAU only *releases*, never demands new content faster than the controller admits).

**Why this is the best first ship**: it directly deletes the reported event (the fly-up cliff) with zero new memory, zero new draw types, zero shader changes, and ~a day of implementation risk concentrated in one node-position law that a headless gate can fully pin.

---

## 4. S2 — the geometry backbone: FP_BLOCK_LOD rings (in flight as #76) + the transition contract

The rim/grazing relief gap (§0.4) and the ascent/descent mid-band need **real coarse geometry**, and that design exists and is being implemented (COSMOS-BLOCK-LOD-DESIGN.md; P0 data model landed as `godot/src/world/facet_block_lod.gd`). This doc does not redesign it — it binds it to the transition with four requirements the implementation must honor:

1. **Rim engagement**: L1 (2-blk pitch, real near content) must engage at the near rim (~128) so the first step outward is 1-blk → 2-blk pitch — a ≤ 1-block containment step ≈ ≤ 12 px worst-case at the rim, vs today's 1-blk → flat-paint cliff. With `FP_FARRING_LEVEL` the vertical alignment is exact (both sample the shared lattice).
2. **One τ**: ring distances key off the same screen-space law (`d_max(Ln) ≈ 2^n·K_px/4` already ≈ the τ law with τ≈4); S1's `ANCHOR_REL_LO` collapses from 700 to the L1/L2 engagement distance once rings ship — the plate releases into *coarse blocks*, not paint, and each hand-off step is a factor-2 pitch change at sub-τ size.
3. **Temporal fades stay**: tile-arrival 0.3 s screen-door dither (BLOCK-LOD §4) is the ONLY sanctioned dither use; skirts close ring-boundary silhouettes.
4. **Containment + shade**: min-rule containment (no protrusion) and the `FP_SHADE_UNIFIED` law make every spatial boundary an at-or-below, same-lit overlap — no stitching geometry, nothing to crack.

Memory/perf: the BLOCK-LOD 16 MB ledger and draw accounting stand as designed; nothing here adds to them.

## 5. S3 — optional band relief polish (POM / height channel): specified, deprioritized, likely cut

If, **after** S1+S2 ship, grazing views of the band still read flat between L-ring geometry steps: grow the band shot RG8 → RGBA8 with a height byte (`surface_shot` already computes column tops), +~2.6 MB (ceiling 46 → 49 MB, flag-gated `FP_BAND_RELIEF`), and add an 8-tap parallax march in the band branch only, gated by `grazing = 1−|dot(view, radial)|` and d < 1800. Honest assessment: horizon-filling far pixels are exactly where gl_compat fragment budget is scarcest, real L1/L2 geometry supersedes most of the benefit, and a POM silhouette still lies at the limb. **Recommendation: do not build unless a live A/B after S2 demonstrates the residual gap; expect to cut.**

## 6. S4 — north star: the τ-continuum, and why continuous geomorph is rejected here

The north star is **not** vertex-morph geomorph for this engine. Reasons: (1) morphing block terrain between pitches animates "melting" voxels — aesthetically wrong for a blocky world (BLOCK-LOD §4 reached the same verdict; Distant Horizons ships without morph and reads seamless); (2) the τ law + containment + arrival dither achieves the same perceptual continuity — a step that subtends ≤ 2-4 px with identical albedo/shade is below notice; (3) morph needs both LOD levels resident per vertex (custom vertex streams) — real memory and mesh-build cost for imperceptible gain. The continuum law to carry forward: **every seam in the ladder must be (a) screen-error-timed (≤ τ px), (b) albedo-shared (one sampler chain), (c) shade-shared (one light law), (d) level-aligned (no sink), (e) temporally dithered on arrival.** S1 fixes (a) for the near field; §2V fixed (b)(c); U2/U3 fix (d); BLOCK-LOD carries (e). CDLOD-style morph remains a labeled fallback for exactly one smooth-mesh seam — the far ring's CELLS=4 ↔ BACKSTOP_CELLS=16 boundary — if it is ever visible from under the pyramid (it is currently covered).

---

## 7. Recommendation and sequence (design lead's call)

**Ship S1 (`FP_APPROACH_ANCHOR`) + S1b (`FP_FARRING_LEVEL` A/B) first, in one deploy.** It is the highest seamlessness-per-risk move available: the user's literal complaint is §0.1, S1 deletes it as a policy change with zero memory and a fully headless-provable contract, and it makes the descent path better simultaneously. Then: **S2** = land #76 P1-P3 under the four-point transition contract (§4) — this closes the standing rim/grazing gap and lets S1's release threshold tighten. **S3** only on post-S2 A/B evidence (expect to cut). **S4** is a law, not a build.

Acceptance test for "seamless" (applies to every stage): a scripted ascent/descent 0→2000→0 over fixed terrain, Tier-A llvmpipe frame capture; assert no single frame-to-frame pixel-delta spike above threshold in the terrain region (the pop detector), plus the live remote-bridge eyeball on real GPU. This turns the user's subjective bar into a regression gate.

### Flag/gate summary

| Flag | Stage | Default | Gate |
|---|---|---|---|
| `FP_APPROACH_ANCHOR` | S1 | false | `verify_approach_anchor.gd` G-AA-OFF/ANCHOR/TAU/BYTES |
| `FP_FARRING_LEVEL` (+U2) | S1b | false (implemented) | existing G-LV-NOPROT/SEAM + live A/B |
| `FP_BLOCK_LOD*` chain | S2 | false (in flight #76) | existing G-BLD-* + the §4 contract asserted in G-BLD-SEAM |
| `FP_BAND_RELIEF` | S3 (conditional) | false | G-BR-BYTES/GRAZE — only if built |

### Risk register (transition-specific)

| # | Risk | Stage | Mitigation |
|---|---|---|---|
| 1 | view_distance ramp re-mesh churn | S1 | debounce ≥100 ms, monotone ramp, FP-M1c ramp precedent |
| 2 | Detail-island rim visible mid-altitude | S1 | albedo already matched (§2V); closed by S2 rim contract |
| 3 | Airborne worst-frame regression from retained draws | S1 | draws ≤ ground case (binding case unchanged); scripted-ascent worst-frame A/B |
| 4 | Rim step still visible at walk level (12 px) | S2 | L1 containment step ≤1 blk + skirts + FARRING_LEVEL alignment |
| 5 | POM cost on horizon pixels | S3 | grazing+distance gating; default recommendation is cut |
| 6 | Any stage regresses FLAT/byte-off suites | all | every flag default-false, gated construction, FLAT 6042/0 in every gate |
