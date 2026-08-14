# COSMOS FAR-TREES COLORFIX — mesh-band black/cyan/green trees (root cause + fix design)

Status: **DESIGN** (root cause verified against engine source + pixel-probe; fix behind `FP_FAR_TREES_COLORFIX`)
Scope: the just-shipped far-terrain-trees tier (`FP_FAR_TREES` + `_CARDS`/`_MESH`/`_FADE`/`_SNOW`, PRs #51–#54).
Related: docs/COSMOS-FAR-TREES-DESIGN.md, [[voxiverse-border-shade-weld]] (quantitative-screenshot lesson).

## 1. Symptom

Descending from orbit (and standing on the surface), far trees in the band **"close but not yet
near-voxel"** render as solid BLACK / CYAN / oversaturated-GREEN / BLUE squares, while (a) far
cards far away, (b) near voxel trees (< 128), and (c) everything else render correctly. Repro:
warm region (air 18.7 °C, ground 19.4 °C), facet 1754, pos (8665, 116, 14212).

Pixel-probe of the repro screenshots (`near-trees.jpg`, alt 113 — headless Image sample, not
eyeball):

| anomaly | sampled RGB | count |
|---|---|---|
| pure green | (18, 255, 19), (45, 194, 30) | ~1200 px |
| cyan | (38, 255, 255), (19, 200, 247) | ~300 px |
| azure/blue | (35, 204, 243), (25, 240, 222) | ~250 px |
| "black" (dark olive) | (24, 39, 0) | ~1100 px |

Two hard facts fall out of the numbers:
1. **Every anomalous pixel has near-zero RED.**
2. None of these colours is reachable as `albedo × voxi_shade`: the brightest leaf in
   `godot/assets/blocks.json` is birch (0.50, 0.655, 0.33) and `voxi_shade ≤ ~1.24`
   (day + twilight) — max green ≈ 207, and **no tree block has b > 0.2**, so (·,255,255)
   cyan is impossible from any tree albedo. The colours are *not shaded tree colours at all*.

## 2. Root cause — GLES3 MultiMesh color-slot aliasing (engine-level), hit only by the mesh shader

The rung-1 archetype-mesh MultiMeshes are created with `use_custom_data = true`,
`use_colors = false` (`godot/src/world/facet_far_trees.gd:369-370`), and the rung-1 mesh shader
is the **only** far-trees shader that reads per-vertex `COLOR`
(`facet_far_trees.gd:227` / `:249`, `v_col = vec4(COLOR.rgb * voxi_shade(...) ...)`).

In the **GL Compatibility renderer** (the web export) that combination is broken in the engine
(custom Godot 4.4.1, `docker/engine/cache/godot`):

1. `drivers/gles3/storage/mesh_storage.cpp:1542` — the instance buffer allocates the color and
   custom slots **together**: `color_and_custom_strides = (use_colors || use_custom_data) ? 2 : 0`.
   With custom-only, the layout is still `12 xform + 2 color-halves + 2 custom-halves` = 16 floats;
   a color slot exists even though `uses_colors == false`.
2. `mesh_storage.cpp:1955-2001` (`_multimesh_set_buffer`) — our GDScript buffer is
   `12 xform + 4 custom` = 16 floats/instance, the same stride as the internal layout, and the
   repack is **in place**: it packs `custom` into half-floats at floats 14–15, but because
   `uses_colors` is false it **never writes floats 12–13** — they keep the raw float32 bits of
   `custom.x` and `custom.y` from our buffer.
3. `drivers/gles3/rasterizer_scene_gles3.cpp:3607-3610` — at draw time, attribute 15 (the
   color+custom uvec4 at float offset 12) is enabled whenever the multimesh has colors **OR**
   custom data. The "default white color" fallback (`:3612-3617`) only runs when *neither* is used.
4. `drivers/gles3/shaders/scene.glsl:545-551` — if the user shader uses `COLOR` and instancing is
   active, the vertex color is multiplied by
   `instance_color = unpackHalf2x16(attr15.x) ⊕ unpackHalf2x16(attr15.y)` — **with no
   `uses_colors` gate**.

Net effect for every rung-1 mesh instance (custom = `(delta, hue + 2·snow, arch, fade)`,
written at `facet_far_trees.gd:764`):

```
COLOR.rgb *= vec3( f16(lo16(bits(delta))),      // r-multiplier
                   f16(hi16(bits(delta))),      // g-multiplier
                   f16(lo16(bits(hue+2·snow))) ) // b-multiplier
```

- `delta = trunk_h − arch_trunk` is a small **integer-valued** float → its low mantissa 16 bits
  are 0 → **r-multiplier = 0** → every anomalous pixel is red-less ✓.
- g-multiplier = the top 16 bits of `bits(delta)` read as f16: `delta 0 → 0`, `1 → 1.875`,
  `2 → 2.0`, `−1 → −1.875` → either **killed green (black/blue family)** or **~1.9× oversaturated
  green** ✓ (0.42 × 1.875 ≈ 0.79 → with twilight/scatter ≈ 1.0 → 255).
- b-multiplier = the low 16 bits of `bits(hue)` as f16 — hue is `k/65536`
  (`_hue01`, `facet_far_trees.gd:934-938`), so this is pseudo-random: mostly ~0 (**pure green /
  black**) or huge → clamps to 1 (**cyan / blue**) ✓.

`INSTANCE_CUSTOM` itself (`scene.glsl:586-588`, attr15.zw = the properly packed halves) decodes
**correctly** — trunk-stretch, fade and snow all work; only the spurious COLOR multiply is garbage.

### Why it is exactly the "close but not near" band
Only the rung-1 **mesh** shader declares `COLOR_USED`. The rung-2 **card** shader samples the
atlas and never reads `COLOR` → the multiply is compiled out → cards `[448±32, 2400]` correct.
Near voxel trees (< 128) are the ordinary block mesher → correct. The garbage band is precisely
the mesh band `[128, 448+32)` (with FADE the 448±32 cross-dither shows *mixed* garbage meshes +
correct cards — the reported "near edge of the card band"). These are the only two
`use_custom_data=true` MultiMeshes in the codebase — no other subsystem is exposed.

### Why no gate or desktop run caught it
The RD (Forward+) renderer keeps separate, correctly-gated color/custom paths — the same code is
correct on desktop. The headless verify gates never rasterise. This is a **web/gl_compat-only
runtime** defect: only a live screenshot probe could see it (the [[voxiverse-border-shade-weld]]
lesson, applied — the pixel histogram above is what falsified every albedo-side theory).

## 3. Theories checked and refuted (the task's leads)

| lead | verdict |
|---|---|
| INSTANCE_CUSTOM slot double-purposed between card and mesh paths | **No.** Producers/consumers agree per path: cards write `(col, hue, snow, fade)` (`_write_card`, `facet_far_trees.gd:673`) and the card shader reads `.x` col / `.y` hue / `.z` snow / `.w` fade (`:125-160`, `:179-182`); meshes write `(delta, hue+2·snow, arch, fade)` (`:764`) and the mesh shader reads exactly that (`:219-266`). The paths use separate MultiMeshes + materials — no cross-read. |
| P3 snow false-fires warm → cyan | **No.** Snow is decided by `ClimateModel.surface_temperature(base.y, t_col) < 0` at enumeration (`:516-519`) — warm columns get snow = 0; the decode (`step(1.5, y)` / `fract(y)`) is the exact inverse of the `hue + 2·snow` pack. And arithmetically snow cannot make cyan: `mix(albedo, snow_tint(0.90,0.93,0.97), 0.6)` is pale mint, never (38,255,255). |
| BLACK = stale/zero `planet_centre` → `voxi_shade` night | **Not the primary cause.** `step()` pushes `planet_centre` *before* the first rebuild in the same call (`:433-437` precede `:445-448`), so a fresh tile never first-renders with the default. The observed black is the same aliasing bug with `delta = 0` (g-multiplier 0). A real *secondary* window does exist — §4.2. |
| Transient half-initialised custom buffer during rebuild | **No.** Buffers are fully written before the single `set_buffer` upload; the anomaly persists while an instance stays in the mesh band (screenshots are from a settled, stationary view). |

## 4. Fix design — `FP_FAR_TREES_COLORFIX` (byte-identical off)

One new flag in `godot/src/cosmos/cube_sphere.gd` next to the far-trees block (`:886-890`):
`const FP_FAR_TREES_COLORFIX := false`. Baked ON at deploy like its siblings.

### 4.1 Primary: give the mesh MultiMeshes an explicit white instance color
Never leave the GLES3 color slot to hold repack garbage — make the engine pack it properly:

- `_setup_mesh_band` (`facet_far_trees.gd:367-372`): `mm.use_colors = CubeSphere.FP_FAR_TREES_COLORFIX`
  (set before `instance_count`, like `use_custom_data`).
- New one-liner `static func mesh_stride() -> int: return 20 if CubeSphere.FP_FAR_TREES_COLORFIX else MESH_STRIDE`
  — the RS buffer layout with colors is `12 xform + 4 COLOR + 4 CUSTOM`.
- `_rebuild_meshes` (`:693`): size each species buffer `per_cap * mesh_stride()`; pass
  `counts[col] * mesh_stride()` as the write base (`:734`).
- `_write_mesh_inst` (`:750-764`): under the flag write
  `buf[base+12..15] = (1.0, 1.0, 1.0, 1.0)` (identity multiplier) and shift custom to
  `buf[base+16..19] = (delta, hue + 2·snow, arch, fade)`. Off ⇒ the shipped 16-float layout,
  byte-identical.
- `total_bytes()` (`:952`): use `mesh_stride()` (6 × 512 × 20 × 4 = 240 KB, +48 KB — far under the
  4 MB `FAR_TREES_BYTES_MAX`).
- `mesh_buffer()` gate hook: unchanged (returns the raw buffer; the gate knows the stride via the flag).

Shaders unchanged: with `uses_colors=true` the engine packs half(1,1,1,1) into floats 12–13, the
ungated `COLOR *= instance_color` becomes a no-op, and `INSTANCE_CUSTOM` still decodes from the
(properly packed) custom slot. The cards stay untouched — their shader has no `COLOR` read (add a
class-doc warning: *never* read `COLOR` in the card shader without also enabling `use_colors`).

Rejected alternatives: (a) per-species trunk/leaf-colour uniforms + dropping the COLOR array —
also correct and stride-free, but needs 6 materials and re-plumbing every `sun_dir`/`planet_centre`
push, and loses per-vertex generality (multi-shade canopies, cherry/dark-oak later); (b) engine
patch to gate `scene.glsl:550` on a HAS_COLOR flag bit — correct upstream fix but a ~24 min engine
rebuild + template churn for something the 4-line buffer change avoids.

### 4.2 Secondary (same flag): no stale frozen buffers on de-orbit
`step()` sets node visibility from `shell_offsurface()` **before** the settle gate
(`facet_far_trees.gd:417-423`), so on de-orbit the tier re-appears instantly with the *pre-orbit*
instance set and uniforms and stays frozen until `FP_LOAD_DEFER` settles + stream credit — stale
band membership (trees can sit inside the near field) for tens of seconds. Under the flag: latch
`_stale = true` whenever `offsurf` is true; clear it at the end of the first completed
`_rebuild_meshes`/`_rebuild_cards`; visibility becomes `not offsurf and not _stale`. A fresh
descent shows *no* far trees until the first real rebuild (correct-or-nothing, the G3
`FP_ORBIT_RELIEF_SURFACE_HIDE` discipline).

### 4.3 Optional (separate micro-flag if wanted): descent bake pacing
Enumeration fills ~64 wanted facets at 1 dispatch / 250 ms step (`FAR_TREES_STEP_MS`,
`cube_sphere.gd:897`; dispatch at `facet_far_trees.gd:441-442`) ≈ **16 s** to full card reach
after settle — but the *visible* mesh band needs only the nearest ~8-10 facets (~2.5 s). The
"took a while" on descent is dominated by the `FP_LOAD_DEFER` settle latch (near-field drain),
which is by design. If faster is wanted: allow up to 3 in-flight enum workers while
`_cache.size() < wanted.size()/2` (cold-cache burst), keeping the 250 ms rebuild cadence. Not
required for the colour fix.

## 5. Slot table (who writes / who reads / what gl_compat actually delivers)

| slot | mesh path writes (`:764`) | mesh shader reads | card path writes (`:673`) | card shader reads | gl_compat delivery (custom-only MM) |
|---|---|---|---|---|---|
| CUSTOM.x | delta = trunk_h − arch | trunk-stretch (`:219`) | species col | atlas col (`:125`) | correct (f16) |
| CUSTOM.y | hue + 2·snow | hue+snow decode (`:265-266`) | hue | hue jitter (`:128`) | correct (f16) |
| CUSTOM.z | arch_trunk | stretch denominator (`:220`) | snow | snow lerp (`:180`) | correct (f16) |
| CUSTOM.w | fade α | dither (`:250-253`) | fade α | dither (`:153-160`) | correct (f16) |
| **COLOR (instance)** | **never written** | **implicit ×COLOR (engine, scene.glsl:550)** | never written | not read (no COLOR_USED) | **garbage = f16 halves of raw bits(custom.x/.y)** ← THE BUG |
| COLOR (vertex) | block colours (`:791`) | albedo (`:227`) | — (no array) | — | correct, then multiplied by the garbage above |

## 6. Gate plan (`verify_far_trees.gd` additions)

- **G-FT-CFIX-OFF** — flag off: `_setup_mesh_band` leaves `use_colors == false`; a
  `debug_rebuild` buffer is byte-identical to the shipped 16-float layout (existing P1 gates
  re-run green unchanged).
- **G-FT-CFIX-WHITE** — flag on: for every live instance in every species buffer,
  floats [12..15] == (1,1,1,1) exactly, and the custom quad at [16..19] equals the OFF-layout
  custom at [12..15] for the same scene (decode parity: same delta/hue/arch/fade per tree).
- **G-FT-CFIX-SNOW-WARM** (regression pin for the refuted lead) — enumerate the warm repro facet
  (1754): every record's snow bit (`int(rec[6]) & 8`) is 0 and the mesh custom.y < 1.5
  (decoded snow = 0); a cold facet (spruce/snow-line) yields ≥ 1 record with snow bit 1 and
  custom.y ≥ 2.0.
- **G-FT-CFIX-FRESH** — with `offsurf` toggled true→false (test hook), all MMIs stay invisible
  until one `debug_rebuild` completes, then visible.
- **Byte-off identity** — the standard two-state run: flag off ⇒ FLAT/faceted suites byte-green.
- **Live acceptance** (post-deploy, remote): re-shoot the repro pose (8665,116,14212 alt 113) and
  run the same pixel probe — assert zero pixels matching the anomaly predicate
  (`max(r,g,b) high ∧ r ≪ g` saturated / near-black clusters in the mesh band), i.e. the
  histogram in §1 collapses. Screenshot sampling is the merge gate, not eyeballing.

## 7. Lesson

`use_custom_data=true, use_colors=false` + a COLOR-reading shader is silently broken on the
compatibility renderer (ungated `COLOR *= instance_color` over an unpacked garbage slot;
correct on Forward+). Any future MultiMesh in this codebase either enables **both** colors and
custom data, or its shader must not touch `COLOR`. Also: INSTANCE_CUSTOM on gl_compat is
half-float — never pack anything needing > 11 mantissa bits into one custom component.
