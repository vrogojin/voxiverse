# COSMOS NEAR-LEAF-CUTOUT — see-through (alpha-tested) near leaf blocks

Status: DESIGN (task #116). Flag: `FP_LEAF_CUTOUT` (default **false** — byte-identical off).
Author: Fable architect session 2026-08-12. Companion docs: `COSMOS-ATLAS-DESIGN.md`
(the shared opaque atlas this rides), `COSMOS-FAR-TREES-DESIGN.md` (the far cards whose
look this matches), `COSMOS-TEXTURED-LOD-DESIGN.md` §2V (FP_SHADE_UNIFIED near shader).

## 1. The request

The FAR tree card impostors read as *airy, stippled foliage*: their atlas is CPU-rasterised
with a fully-transparent background and the card shader discards `t.a < 0.5`
(`facet_far_trees.gd:132-137`), so sky shows through the canopy silhouette gaps. The NEAR
voxel leaf blocks render as SOLID opaque cube faces on the shared atlas material — flat
green slabs. The user wants the near leaf blocks to read see-through like the far cards,
ideally so the far-card → near-block LOD transition stays visually consistent.

## 2. Ground truth (what actually renders today)

**Near leaf blocks.** Every opaque cube id is routed onto the ONE shared atlas material in
`module_world._configure_library` (`module_world.gd:3176-3198`): `use_atlas =
_atlas.has_cell(id)` → `_add_cube(library, _atlas.material, cull_group, cell)`
(`module_world.gd:3215-3244`), which points all 6 faces at the id's atlas cell via
`set_tile` and forces `material_override(0) = _atlas.material` (`:3230-3234`). The atlas is
a 16×16 grid of 64 px cells in one 1024² RGBA8 image (`block_atlas.gd:38-40`), built once
at setup (`module_world.gd:331-339`), textured cells blitted from the 128² pack PNGs
(`block_atlas.gd:281-295`), mipmapped (`:270`), behind one material — the
StandardMaterial3D, or under FP_NEAR_DAYLIGHT/FP_SHADE_UNIFIED the ShaderMaterial twin
(`block_atlas.gd:329-363`, shader source `near_daylight_shader_code`, `:130-136`). The
unified fragment is `ALBEDO = v_col.rgb * t.rgb * voxi_shade(n, sun_dir)`
(`block_atlas.gd:92-96`). **Nothing in this path reads texture alpha.**

**The leaf tile art has NO holes.** Measured directly: `leaf.png`, `spruce_leaves.png`,
`birch_leaves.png`, `jungle_leaves.png`, `acacia_leaves.png` (128² RGBA8 under
`godot/assets/textures/pack/`) are min-alpha = 255 — 0.0 % transparent texels. The 16 px
`pack/src/oak_leaves.png` source is opaque too. So there is no latent cutout waiting to be
enabled; an alpha source must be created (see §5).

**The leaf id family.** `BlockCatalog.LEAF := 5` (`block_catalog.gd:37`, alias
`oak_leaves`), plus from `assets/blocks.json`: `spruce_leaves` 51, `birch_leaves` 53,
`jungle_leaves` 55, `acacia_leaves` 57, `dark_oak_leaves` 59, `cherry_leaves` 61 — **7
ids**, all `structural_class "foliage"`, all render mode `"opaque"` (cull_group 0). NOTE
the foliage class is NOT a sufficient key: `moss_block` (43) and `cactus` (77) are also
foliage but must stay solid. The gate is therefore an explicit leaf predicate: `id ==
BlockCatalog.LEAF or name_of(id).ends_with("_leaves")`. TreeGen live-places 5 of the 7
(`tree_gen.gd:274-279`); dark_oak/cherry are catalog-only today but join the family for
free. Tile stems (`block_textures.gd:24-40`): oak/spruce/birch/jungle/acacia have real
tiles, `dark_oak_leaves` reuses stem `"leaf"` (⇒ SHARES oak's atlas cell — fine, both are
leaves), `cherry_leaves` has no tile ⇒ a colour-keyed SWATCH cell (`block_atlas.gd:207-235`)
— which a future non-leaf id of the same colour could share; §6 adds a key-namespace guard.

**Atlas family structure.** Stage 2 keeps translucent (glass/ice/water), emissive (lava)
and fluid ids OFF the atlas — `has_cell` false, per-id materials (`block_atlas.gd:20-26`,
`module_world.gd:3180-3182`). The existing translucent pass is **alpha-BLEND with depth
pre-pass** (`block_materials.gd:466-476`, `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`; daylight
twins `:66-109` use `depth_prepass_alpha`). Leaves must NOT join it: blend needs
back-to-front sorting; a canopy is hundreds of interleaved quads and gl_compat sorts
per-mesh, not per-face — it would z-fight and shimmer. There is **no existing alpha-TEST
(cutout) pass** in the near field to reuse. The only shipped cutout shader in the project
is the far card's (`facet_far_trees.gd:114-137`) — opaque queue + `discard`, proven
gl_compat/WebGL2-safe live.

**The far card hole pattern.** The card atlas is 256×64, filled `Color(0,0,0,0)`, then each
species' `TreeGen.archetype_cells` are orthographically projected and painted as small
OPAQUE rects (`facet_far_trees.gd:867-910`; `colr.a = 1.0` at `:909`). A texel is opaque
iff some archetype cube covers it — i.e. the far "holes" are the **whole-tree silhouette
gaps at 32² card scale**, not a per-block leaf texture. There is no per-texel leaf pattern
to literally share with a 64 px per-CELL near tile; §5 matches the *style* (hole fraction,
stipple scale, same hash family), and states that plainly.

## 3. Approach decision: (b) a separate leaf cutout material pass — RECOMMENDED

Two candidates were weighed:

**(a) alpha_scissor on the ONE shared atlas material**, holes only in leaf cells so
non-leaf texels (a = 1) never discard. Rejected. The killer is not correctness but GPU
scheduling: a fragment shader containing `discard` disables early-Z *for every draw using
that shader* — and the shared atlas material draws essentially the ENTIRE near terrain
(that was the whole point of FP_ATLAS_MATERIAL). On the WebGL2/ANGLE/integrated-GPU
targets this trades the terrain's early-Z rejection (the thing that makes dense voxel
scenes cheap) for a feature that touches ~1 % of surfaces. Risk is a several-ms whole-scene
regression to give leaves holes. It also entangles the flag with every other block's
byte-identity. No draw-call saving justifies it (0 vs +1 surface per leafy mesh block).

**(b) split the leaf family onto ONE shared transparent-cutout sibling material** — the
same split discipline the atlas already applies to translucent/emissive/slope families
(`block_atlas.gd:20-26`). All 7 leaf ids share ONE new material (the atlas material's twin
+ one `discard` line), sampling the SAME 1024² atlas texture at the SAME cells. Chosen
because:

- `discard` cost is confined to leaf surfaces only; the terrain pass keeps early-Z.
- VoxelMesherBlocky emits one surface per distinct material per 32³ block
  (`block_atlas.gd:5-11`), so the cost is exactly **+1 draw call per in-view mesh block
  containing leaves** (~20-60 in a dense forest, against a few hundred total — noise).
- Alpha-TEST stays in the **opaque queue** (no ALPHA write): depth-written, no sorting, no
  render-order interaction with water/glass. This is the exact recipe the far card ships
  (`facet_far_trees.gd:134`), so it is *already proven* on the live web build.
- Render-path blast radius is one material-selection branch + one shader string.

alpha-blend was considered and rejected for leaves outright (sorting, §2). **alpha_scissor
(cutout, opaque-queue discard) is the right call**, and (b) is the right home for it.

## 4. Perf budget (quantified, honest)

- **Draw calls:** +1 surface per leafy 32³ mesh block. Dense forest view ≈ 20-60 blocks ⇒
  +20-60 calls. Atlas Stage 1 bought back hundreds; this spends a few percent of that.
- **Shader compiles:** +1 (the leaf twin). One-time at setup.
- **Vertex load:** unchanged — same cubes, same faces; only the material binding differs.
  Canopy face counts are small anyway (~110 shell quads/tree, ~22 k quads for 200 trees).
- **Fill/overdraw (the real cost):** `discard` removes fine-grained early-Z *within* the
  leaf draws. Mitigation baked into the design: leaf models KEEP `transparency_index 0`
  (opaque) and default neighbour culling, so leaf-against-leaf interior faces are still
  culled by the blocky mesher — a canopy renders as its shell only (front + back faces,
  `cull_disabled` on the material), NOT as N stacked interior layers. That caps leaf
  overdraw at ≈ 2 layers of canopy screen coverage. Worst case (standing inside a dense
  oak forest, canopy filling the screen at 1080p): ~1-2.5 M leaf fragments of a
  1-texture-fetch unshaded + voxi_shade shader ⇒ **~1-2 ms on a low-end integrated GPU**,
  ~0.3-0.6 ms on anything discrete. Against the 16-25 ms frame budget at the 40-60 fps
  near-field target: **expected ≤ ~5 % fps cost inside a forest, ~0 elsewhere**. This
  matches the evidence that the far-card layer (same discard shader, planet-scale card
  counts) ships at ~40 fps today.
- **Resident bytes (NEVER-OOM):** **zero new textures.** The atlas is already RGBA8 with a
  live alpha plane (4 MB + ~1.3 MB mips, `block_atlas.gd:35`); the holes are written into
  the existing leaf cells at build. +1 ShaderMaterial (~KB). (Optional Stage 2 debris
  parity: +5 × 64 KB = 320 KB of per-species holed ImageTextures — still trivial.)

These are estimates; the user has remote control, so the gate plan (§8) requires a live
dense-forest fps A/B before the flag is baked ON at export.

## 5. The alpha source — procedural stipple, style-matched to the far cards

New authored art is unavailable (the CC0 pack has no cutout leaves — measured, §2) and the
far card pattern is a whole-tree silhouette, not a tileable texel pattern (§2). So the
holes are **procedural, deterministic, punched at atlas build time** into the leaf cells
only:

- Mask domain: the 64×64 cell, partitioned into **2×2 px clusters** (32×32 clusters). A
  cluster is punched (alpha → 0) when `hash(cx, cy, species_cell_index) < HOLE_P`, using
  the same integer-mix hash family as `facet_far_trees._hue01` (`:932-934`) for stylistic
  kinship and determinism. RGB under punched texels is left as-is (irrelevant — discarded;
  keeping it avoids dark mip bleed).
- **`HOLE_P ≈ 0.30`** (30 % transparent). Tuned to sit near the far card's interior gap
  read; live A/B refines it. Kept a const next to the flag.
- 2×2 clusters (not 1×1) so mip 1 (32 px) still contains real holes and mip 2+ decays
  gracefully (§7 mip note). Per-cell-index hash offset so oak and spruce canopies don't
  show pixel-aligned identical stipple.
- Honest limitation, stated up front: near↔far consistency here is **perceptual** (both
  layers airy, similar transparency fraction, same hash flavour), NOT texel-identical —
  texel identity is impossible because the far pattern is a per-tree projection and the
  near pattern is per-block. The LOD transition still improves categorically: today it is
  *stippled card → solid slab*; with this it is *stippled card → stippled blocks*.

## 6. Implementation plan

Flag: **`const FP_LEAF_CUTOUT := false`** in `cube_sphere.gd` (joins the FP block; baked ON
at export only after the live A/B). Every site below is guarded by it; OFF touches nothing.

1. **`block_catalog.gd`** — `static func is_leaf_id(id: int) -> bool`: `id == LEAF or
   name_of(id).ends_with("_leaves")`. (Explicitly NOT `structural_class == "foliage"` —
   moss_block/cactus stay solid.) Ungated (a pure predicate; nothing calls it when off).
2. **`block_atlas.gd` cell keys** — in `build()` (`:207-235`), under the flag, namespace
   leaf look-keys (`"leaftile:"`/`"leafswatch:"` instead of `"tile:"`/`"swatch:"`) so a
   leaf cell can never be shared with a non-leaf id (the cherry-swatch collision, §2).
   dark_oak still shares oak's cell (same `leaftile:leaf` key — desired).
3. **`block_atlas.gd` hole punch** — after the cell loop, before
   `image.generate_mipmaps()` (`:270`): for every cell owned only by leaf ids, apply the §5
   stipple mask (`_punch_leaf_holes(cell, salt)`). Off ⇒ not called ⇒ atlas bytes
   byte-identical.
4. **`block_atlas.gd` leaf material twin** — new `var leaf_material: Material` built in
   `_make_material`-style: the SAME shader source as `near_daylight_shader_code()` with one
   string insertion before the ALBEDO line: `\tif (t.a < 0.5) discard;\n` (threshold const
   `LEAF_SCISSOR := 0.5`; drop to 0.4 if the live A/B shows mip-fade — §7). Same uniforms,
   same atlas texture. On the flag-off / FP_NEAR_DAYLIGHT-off path: a StandardMaterial3D
   clone of `_make_material` with `transparency = TRANSPARENCY_ALPHA_SCISSOR`,
   `alpha_scissor_threshold = 0.5` (works headless + FLAT gates without the shader twin).
   Exposed as `leaf_shader_code(...)` static, like `near_daylight_shader_code`, so gates
   build every variant without toggling consts.
5. **`block_atlas.gd` uniform feeds** — `set_near_daylight_sun_dir` (`:368-372`) and
   `set_near_daylight_planet_centre` (`:380-384`) also set the leaf twin when it exists.
   Same guards ⇒ off is a no-op. (Terminator lighting composes for free: discard runs
   before the ALBEDO sink; kept texels take the identical `voxi_shade(n, sun_dir)` /
   shipped shade-law path — the exact composition the far card already ships,
   `facet_far_trees.gd:132-137`.)
6. **`module_world.gd` routing** — in `_configure_library` (`:3183-3185`): when
   `FP_LEAF_CUTOUT and BlockCatalog.is_leaf_id(block_id) and use_atlas`, pass the leaf
   material through to `_add_cube`. `_add_cube` (`:3230-3234`) currently FORCES
   `_atlas.material` whenever a cell is valid — relax that one line to honour an explicit
   leaf-material argument (default keeps today's force ⇒ byte-identical off). Leaf models
   keep `transparency_index 0` and default neighbour culling (the §4 overdraw cap:
   canopy-interior faces stay culled). The runtime-placed-shape site
   (`module_world.gd:882-887`) needs no change — leaves are cubes, never shaped.
7. **Stage 2 (optional, separate commit): debris + fallback parity** — chopped-canopy
   `VoxelBody` debris and the GDScript fallback mesher render leaves via
   `BlockMaterials.get_for` (`block_materials.gd:146-161`), NOT the atlas. Under the flag,
   for leaf ids: build the per-id textured material from a runtime-holed copy of the pack
   tile (same §5 mask) with scissor/discard, in both `_standard` and `_standard_daylight`.
   +320 KB worst case. Without Stage 2 the shipped web path (module_in_web=yes) is still
   fully consistent for the world itself; falling debris briefly shows solid leaves —
   acceptable to defer.

## 7. Side effects audited

- **Raycast / break / place / collapse:** unaffected — all analytic through
  `WorldManager.block_id_at`; a leaf cell stays a full solid cell. Aiming *through* a
  visual hole still hits the leaf block (Minecraft-identical; accepted).
- **Snow:** leaves are NOT snow-cappable (`terrain_config.gd:2101-2103` — GRASS, PODZOL,
  SAND, STONE only), so no snow-cap leaf cell exists to punch or protect. Snow LAYER
  models sitting on canopy tops are separate models/materials — untouched.
- **Other blocks:** the shared atlas material's shader is not edited (the twin is a new
  compiled program); non-leaf cells' alpha stays 255; the key-namespace guard (§6.2) makes
  cell-sharing contamination impossible.
- **Far skin / fine map / hotbar:** far colours resolve from `BlockCatalog.color_of` /
  pack PNGs, not the runtime atlas (`block_textures.gd:62,91` already skips transparent
  texels defensively) — no interaction. Pack PNGs on disk are never modified.
- **Mip alpha erosion:** `generate_mipmaps()` averages alpha, so distant mips drift toward
  a ≈ 0.7 (at HOLE_P 0.30) — holes soften and leaves read *more solid* with distance. That
  is the desirable direction (the far cards take over anyway); if the live A/B shows
  leaves *thinning* instead (threshold riding above eroded alpha), lower LEAF_SCISSOR
  0.5 → 0.4. A per-mip re-punch is possible via raw `Image` data as a later refinement;
  not needed for V1.
- **verify_atlas.gd:** G-ATLAS-MAT asserts every opaque cube shares the ONE atlas material
  (`verify_atlas.gd:169-202`) — under the flag, leaf ids move to the sibling material;
  the gate becomes flag-aware (leaf ids asserted onto `leaf_material`, all others
  unchanged).

## 8. Gate plan

`verify_leaf_cutout.gd` (pattern: `verify_atlas.gd`), plus a flag-aware touch-up of
G-ATLAS-MAT:

- **G-LEAF-OFF (byte-identity):** with the flag forced off — atlas `image` hash equals the
  shipped build's; every leaf model's `material_override(0)` is the ONE atlas material;
  `near_daylight_shader_code()` byte-equal; no leaf twin exists.
- **G-LEAF-CELL (ON discriminates):** every leaf id has an atlas cell whose transparent
  (<128) fraction ∈ [0.22, 0.40] (HOLE_P 0.30 ± cluster quantisation) at mip 0; every
  NON-leaf id's cell is min-alpha 255; no cell is shared between a leaf and a non-leaf id.
- **G-LEAF-MAT:** each of the 7 leaf ids' library model override is the leaf twin (one
  shared instance); its shader source == `near_daylight_shader_code()` + exactly the one
  discard insertion (string-diff); non-leaf opaque cubes still on the atlas material;
  leaf models' `transparency_index` still 0 (the overdraw cap is load-bearing).
- **G-LEAF-SHADE:** the twin contains `voxi_shade` under FP_SHADE_UNIFIED (terminator
  composition) and receives the same `sun_dir`/`planet_centre` feed (uniform read-back
  after a fed frame, the `daylight_sun_dir_telemetry` pattern).
- **Perf (live, not headless):** remote dense-forest A/B (flag on vs off), p90 frame time;
  budget: ≤ 10 % frame-time regression standing inside a dense oak forest, ~0 on open
  terrain. Fail ⇒ ship flag-off (see §9 fallbacks).

## 9. Risks + ship recommendation

| Risk | Likelihood | Containment |
|---|---|---|
| Web fill-rate regression in dense forest | low-moderate | discard confined to leaf surfaces; interior faces stay mesher-culled (≈2-layer cap); live A/B gate before bake-on; worst-case fallback = flag off |
| Mip-fade shimmer at mid distance | moderate | 2×2 clusters + threshold 0.5→0.4 knob; erosion direction is toward *solid*, not holes |
| Look mismatch vs far cards (pattern not identical) | certain, by construction | stated honestly (§5); transition still strictly better than today's solid slabs |
| Gate drift (G-ATLAS-MAT) | certain | flag-aware gate update shipped in the same PR |
| Cell-shared swatch contamination | eliminated | leaf key namespace (§6.2) + G-LEAF-CELL |

**Verdict: SHIP — approach (b), flag default OFF, bake ON only after the live dense-forest
A/B passes the ≤ 10 % budget.** The cost profile is small and *localised* (leaf surfaces
only, zero new resident textures, +1 shader, tens of draw calls), the discard recipe is
already proven live in the far-card layer on this exact web stack, and the feature
directly upgrades the worst LOD pop the trees have (stippled card → solid slab). If the
A/B fails on low-end hardware, the fallback ladder is: HOLE_P 0.30 → 0.20 (fewer holes =
fewer discards ≈ cheaper + more solid), then flag-off — never a distance-switched second
material (that would reintroduce the pop this feature exists to remove).
