# COSMOS BORDER-SHADE WELD — the bright interfacet border strip (root cause + design)

**Status:** ROOT-CAUSED (live pck fingerprinted + pixel-measured + code-proven). Fix designed behind
`FP_BORDER_SHADE_WELD` (byte-off). Task #106.

**Symptom (live, user repro):** standing on the surface at a facet junction (facet 3 ↔ 2, BCI
[4310.45, −3790.26, −2778.54], alt 6, PLANETARY, pool_active=0), a jagged block-quantized strip of
terrain ALONG the facet border renders at near-daytime brightness while all surrounding near terrain
correctly darkens with the sun. Dawn (~local 6h): glaring pure-green strip across dark warm-tinted
terrain. Night: strip faintly (~2×) brighter than the dark surroundings. Noon: nearly blends; a faint
dark line from the far side.

---

## 1. What the strip IS (discrimination — candidates eliminated)

The live build was fingerprinted from the deployed pck (`build/web/index.pck`, the exact bytes served —
headless `get_script_constant_map`, the ATMO-SKY flag-dump technique). Key baked flags:
`FP_NEAR_DAYLIGHT=true, FP_SHADE_UNIFIED=true, FP_ATLAS_MATERIAL=true, FP_NIGHT_TERRAIN_CENTRE=true,
FP_SHELL_ABSOLUTE=true, FP_FAR_TERMINATOR_WELD=true, FP_FARRING_FULL_COVER=true,
FP_FARRING_APPLIED_COVER=true, FP_NB_FULLRES=true, FP_M2_LOD=true BUT FP_NO_NEAR_LOD=true,
FP_MID_DENSE=false, FP_SKIN_TIER=false, FP_TIER_DEPTH_BIAS=false`.

Eliminated (each was a live-set candidate, each proven not the emitter):

| Candidate | Why not |
|---|---|
| FacetLodMesher ridge apron / `_apron_mat` (facet_lod_mesher.gd:107, StandardMaterial3D LIT) | `FP_NO_NEAR_LOD=true` retires FP_M2_LOD (`_near_lod_on()` false, cube_sphere.gd:255-257) — the mesher is never created live. |
| Far-ring cover / FULL_COVER backstop / applied-cover weld (facet_far_ring.gd 1836-2210) | ALL far-ring geometry lives in the ONE `_mi` MeshInstance (facet_far_ring.gd:487-489) under the `FP_SHELL_ABSOLUTE` sm2 shader — `render_mode unshaded` + per-pixel radial normal + live `sun_dir` + the full shade·tint law (`_SHELL_ABS_TEX_*`, 4274-4360). It darkens correctly. |
| FacetSmoothV2 / FacetOrbitRelief stale `sun_dir` (the [[voxiverse-far-terminator]] failure mode) | Both `render_mode unshaded` + sun law; `FP_FAR_TERMINATOR_WELD=true` (shipped #98) reseeds rebuilt materials from `TierPlace._last_sun_dir`. Also refuted by measurement: a stale-μ mesh is CONSTANT-bright; the strip demonstrably darkens (see §2). |
| GDScript fallback mesher / `FP_NEIGHBOUR_SEAM_POLISH` clamp-live apron | module_in_web=yes → fallback dead; apron requires the (retired) LOD mesher. |
| NB pool (FP_NB_FULLRES) materials | pool_active=0 at repro — no NB terrain resident; and the pool reuses the shared atlas library/material anyway. |
| TierPlace biased material (LIT `_TIER_SHADER`) / FacetSkinTier | `depth_bias_on()` = FP_TIER_DEPTH_BIAS = false; FP_SKIN_TIER=false. Never built. |
| CosmosBorderOverlay | dev pillars are magenta, MultiMesh, emissive — visibly not this. |

What remains at the border with the near field on both sides (the dawn screenshot shows normal dark
near terrain WITH 3-D trees on BOTH sides of the strip) is the active facet's own near mesh — and the
one model family the compiled mesher draws exclusively along the facet ridge:

### THE SMOKING GUN

**The FP-CARVE seam-junction carve-sentinel cubes** (docs/COSMOS-FACETED-CARVE.md, engine patch 0004):
worldgen writes a carve-SENTINEL cube per material along the ridge; `VoxelMesherBlocky.set_facet_carve`
clips it by the active facet's ridge planes at mesh time. These cells form exactly a jagged,
block-quantized band tracking the facet border — the strip's shape in all three screenshots.

Their material is baked at `module_world.gd:1503` (dry) / `:1513` (snow twin), in
`_build_carve_manifest`:

```gdscript
var got: int = _add_cube(library, BlockMaterials.get_for(mat), BlockCatalog.cull_group_of(mat))
```

— NO atlas cell. In `_add_cube` (module_world.gd:3150-3171) `use_atlas=false` ⇒
`set_material_override(0, material)` = **`BlockMaterials.get_for(mat)`** — the
`_NEAR_DAYLIGHT_OPAQUE_SHADER` twin (block_materials.gd:35-61).

Every REGULAR near cube around it instead carries `_atlas.material` (block_atlas.gd) which, under the
baked `FP_SHADE_UNIFIED=true`, is the `_NEAR_UNIFIED_HEAD` + `VoxiLight.shade_glsl()` shader.

## 2. Why it is bright at dawn/night — the one-line shading diff

Two different laws on adjacent blocks:

```glsl
// carve strip — BlockMaterials twin (block_materials.gd:50-58), the PRE-UNIFICATION ATMO2-B3 law:
float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);   // night_floor = 0.10
ALBEDO = base.rgb * shade;                                                    // NO scatter tint

// everything else near+far — VoxiLight unified law (voxi_light.gd:50-55), night_floor = 0.06:
vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));             // sunrise/sunset extinction
return vec3(shade) * tint;
```

The strip's `sun_dir`/`planet_centre` are FRESH (fed per frame with all twins via
`BlockMaterials.set_near_daylight_sun_dir`, world_manager.gd:3478-3506 — this is NOT the (1,0,0)
staleness bug). The divergence is purely the missing `_scatter_tint·_scatter_band` multiply + the
un-unified 0.10 floor:

- **Dawn, μ≈0:** both shades ≈ 0.53-0.55 (smoothstep midpoint), but the unified neighbours multiply
  the scatter tint — at μ≈0 the air mass is ~38 and the green channel collapses to
  exp(−0.098·m) ≈ 0.03-0.2 with a warm hue. The strip skips the tint ⇒ ~0.55 pure green vs ~0.02-0.1
  warm-dark ⇒ the glaring green diagonal.
- **Night, μ<−term_mu:** strip floor 0.10 vs unified 0.06 ⇒ ~1.7× brighter ⇒ the faint residue.
- **Noon, μ≥0.25:** `_scatter_band`→0 ⇒ tint=1; both shades→1 ⇒ blends (the faint dark line is the
  carve cube's non-atlas 1×1 UV sampling vs the atlas cell, cosmetic).

**Pixel-measured proof** (screenshots border-{dawn,night,noon}.jpg, sampled headlessly):
strip green dawn/noon = 0.31/0.58 ≈ 0.53 (= the untinted midpoint) while surrounding ground =
0.11/0.65 ≈ 0.17; dawn HUE: strip g>r (0.267,0.310 — untinted green), ground r>g (0.153,0.122 —
scatter-tinted warm); night strip 0.027 vs ground 0.012 ≈ the 0.10/0.06 floor ratio. All three
regimes match the law diff and refute a constant-bright (stale-sun / unlit-LIT-ambient) mesh.

**History:** before V1 FP_SHADE_UNIFIED every near block used this same B3 law, so the strip matched.
Unification upgraded the ATLAS material and the far shell but never the `BlockMaterials` twins — the
carve strip (plus the smaller consumers below) was left on the old law.

**Same-family co-victims** (all render through the same 3 twin shader strings; the fix covers them
for free): sharp-slope per-material surfaces (module_world.gd:1440/1453 — deliberately not atlassed,
Stage-2 NEVER-OOM), lazily streamed cubes (`_append_cube_for`, :914), runtime-placed shapes with no
atlas cell (:874), snow-capped variants (`snow_capped_for`), and the translucent liquids
(water/glass/ice, lava emission unaffected — EMISSION is post-shade).

## 3. Fix design — FP_BORDER_SHADE_WELD (byte-off)

Unify the BlockMaterials daylight twins onto the SAME VoxiLight law, as a pure string transform on the
three shipped shader consts — no new geometry, no new bytes, no new compiled-program count.

**Flag:** `cube_sphere.gd`: `const FP_BORDER_SHADE_WELD := false`. Effective gate =
`FP_BORDER_SHADE_WELD and FP_NEAR_DAYLIGHT and FP_SHADE_UNIFIED` (without unification there is no
law split to weld; expose as `CubeSphere.border_shade_weld_on()`).

**Injection point:** `block_materials.gd::near_daylight_code(src, centre_fix)` — the ONE choke point
all three twin builders (`_daylight_opaque`, both `_daylight_translucent` variants) already route
through. Order: apply `_centre_fix_code` FIRST (its anchors are the shipped strings), then the new
`_unified_law_code(src)` transform:

1. Replace the twin's inline uniform block
   (`uniform vec3 sun_dir …` through `uniform float moonshine = 0.0;`) + its `float _day(...)`
   helper line with `VoxiLight.shade_glsl()` (declares the SAME uniform names + helpers +
   `voxi_shade`; string-include, one shader_type, gl_compat-safe — the identical snippet already
   compiles on web inside the atlas shader).
2. Replace
   `float mu = dot(nrm, normalize(sun_dir));\n\tfloat shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);`
   and the `ALBEDO = base.rgb * shade;` sink with
   `ALBEDO = base.rgb * voxi_shade(nrm, sun_dir);` (translucent variants: same, `ALPHA` line kept;
   opaque variant: `EMISSION` line kept — lava glow stays post-shade).
   `nrm` keeps the centre-fixed `normalize(v_wp - planet_centre)` under FP_NIGHT_TERRAIN_CENTRE.
3. Uniform seeding in the builders: under the gate seed `VoxiLight.NIGHT_FLOOR` (0.06),
   `VoxiLight.TERM_MU`, `VoxiLight.MOONSHINE` instead of `CosmosSky.NEAR_NIGHT_FLOOR`(0.10)/
   `TERMINATOR_MU` — same uniform NAMES, so the existing per-frame feed hub and the
   `daylight_sun_dir_telemetry` echo keep working unchanged.

**sun_dir plumbing (already correct, unchanged):** all twins register in `_daylight_twins` and are fed
each frame from the ONE WorldManager site (world_manager.gd:3478 `set_near_daylight_sun_dir` →
block_materials.gd:251; planet_centre likewise :3500-3506 → :274). Materials are built on the MAIN
thread only (manifest bake in setup + `_append_cube_for` is documented main-thread-only) — no worker
access to the builders; `VoxiLight.shade_glsl()` is a const string. No thread hazard.

**Crossing/staleness:** twins are cached in the static `_cache` and NEVER rebuilt on crossing ⇒ no
rebuild-relatch risk (the far-terminator failure mode does not apply). Residual: a twin built lazily
AFTER this frame's feed shows the (1,0,0) default for ≤1 frame (shipped behaviour, unchanged).
Recommended one-line hardening under the same flag: seed `sun_dir` at build from the
`TierPlace.note_sun_dir` cache (`FP_FAR_TERMINATOR_WELD` hub) instead of the (1,0,0) literal.

**Invariants respected:** OFF ⇒ every string byte-identical (transform never runs, seeds untouched).
ON at noon ⇒ `voxi_shade` = 1·(1,1,1) ⇒ `ALBEDO = base` — matches the near blocks exactly (both laws
saturate; the noon look is byte-preserved). NEVER-OOM: zero new resident bytes (recolour only).
gl_compatibility: no HDR, no derivatives/loops; snippet already ships on web.

## 4. Gate plan — verify_border_shade.gd (headless; pattern of verify_shade_unified)

- **G-BSW-OFF (byte-identity):** flag false ⇒ `near_daylight_code()` of all three twin consts
  byte-equal the shipped strings; builder seeds equal `CosmosSky.NEAR_NIGHT_FLOOR`/`TERMINATOR_MU`;
  full FLAT gate count unchanged.
- **G-BSW-LAW:** flag on ⇒ generated twin code contains `voxi_shade(` and `_scatter_tint(` and NOT
  the old `float shade = max(night_floor` line; exactly ONE `uniform vec3 sun_dir` declaration
  (no duplicate from the include); seeds equal `VoxiLight.NIGHT_FLOOR/TERM_MU/MOONSHINE`.
- **G-BSW-DISC (discriminates the bug):** GDScript numeric twins — old law vs
  `VoxiLight.shade_tint` at the SAME (n, sun): dawn μ=0 ⇒ old green 0.55 vs new
  0.53·tint_g — assert new < old/3 (the measured ≥3× dawn excess disappears); noon μ=1 ⇒
  |old−new| < 1e-6 per channel (blend preserved); night μ=−0.5 ⇒ new = 0.06, old = 0.10
  (floor unification).
- **G-BSW-CARVE (the actual strip material):** after module setup, walk `_carve_arid` →
  `library.models[arid].material_override(0)` — flag on ⇒ its `shader.code` contains
  `_scatter_tint`; off ⇒ it does not. Proves the ridge geometry, not just the string builder.
- **G-BSW-STALE:** feed `set_near_daylight_sun_dir(v)`, build a NEW twin (lazy `get_for` of an
  unbuilt id), feed again ⇒ its `sun_dir` uniform == v (registry covers late twins); with the
  hardening, assert the build-time seed equals the TierPlace cache, never (1,0,0).

## 5. Measurement appendix

Live pck flag dump: headless editor + `ProjectSettings.load_resource_pack(build/web/index.pck)` +
`get_script_constant_map` on cube_sphere.gd. Screenshot sampling: headless `Image.load_from_file` +
`get_pixel` (values in §2). Repro screenshots preserved in the session scratchpad
(border-dawn/night/noon.jpg).
