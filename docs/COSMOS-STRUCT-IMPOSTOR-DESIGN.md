# COSMOS STRUCT-IMPOSTOR — `FP_STRUCT_CARDS`: the far-village impostor-card tier

Status: **DESIGN — accepted for implementation** (Stage 2 of the far-village perf fix).
Author: Fable 5 (rendering-architecture pass), 2026-09-01.
Predecessors: `docs/COSMOS-STRUCTURES-DESIGN.md` (the cube tier this replaces at range),
`docs/CODEX-BUILDING-RENDER-ANALYSIS-1.md` (the external Codex proposal this refines),
`docs/COSMOS-FAR-TREES-DESIGN.md` + `godot/src/world/facet_far_trees.gd` (the proven card pattern),
`docs/COSMOS-FARTIER-WALK-DESIGN.md` (WALK_CALM / HANDOFF_HYST / REG_EPOCH — Stage 0b, shipped).

---

## 0. Executive summary

Stage 0b (`FP_STRUCT_REG_EPOCH`, merged on this branch) killed the O(N-houses) per-step
control-loop prelude (`wf_st_step_us` = 0 stationary, user-confirmed improvement). The
**residual** far-village cost is a *steady* vertex/raster tax: every registered house in
[near_render_radius, 2400] renders as decimated cube voxels merged into ONE non-indexed
ArrayMesh — up to `STRUCT_FAR_TRIS_MAX` = 80k tris (`cube_sphere.gd:1307`), ~240k shaded
vertices, under `render_mode cull_disabled` (`facet_far_structures.gd:107`) with a
planet-scale `custom_aabb` (`facet_far_structures.gd:193`) that defeats frustum culling.
Measured: ~848k total prims with villages vs ~820k without, and the jerk survives a −70%
tri diet (FP_STRUCT_COARSE_FAR) because the raster/pixel cost stays.

**Stage 2 (`FP_STRUCT_CARDS`) replaces the DATA plane only**: procedurally generated
(SOURCE_GEN) houses beyond a split radius render as **directional impostor cards** — one
shared 4-triangle mesh (a camera-facing vertical quad + a planet-tangent roof cap) in one
`MultiMeshInstance3D`, textured from a CPU-rasterized archetype atlas, with the view
sector chosen **in the vertex shader** so camera rotation never rewrites the instance
buffer. All Stage-0/0b/1 control machinery — registry query, distance bands, NearPresence
handoff cull, rev/edit tracking, WALK_CALM band fingerprint, HANDOFF_HYST, the REG_EPOCH
version-gated snapshot with precomputed `_centres` — is **preserved verbatim**; the card
instance buffer is written from the same REG_EPOCH snapshot the cube path consumes.

Net effect at the worst case (2,048 emitted houses): **8,192 tris / one draw / ~64 KB of
instance floats / a 360 KB atlas**, vs 80,000 non-indexed tris today. Player-BUILT
structures (unique geometry, tracker roots ≥ 0) keep the merged-cube path unconditionally;
a small retained inner cube band `[r0, STRUCT_CARD_MIN)` keeps 3D parallax where houses
are tens of pixels tall.

Key deltas vs the Codex sketch (`docs/CODEX-BUILDING-RENDER-ANALYSIS-1.md`):
door orientation folds into a per-instance yaw (archetypes 16 → 10 while *adding* the
gable-height axis Codex missed), the atlas is CPU-rasterized at boot (not an imported
asset — single-source-of-truth with `StructureGen`/`BlockCatalog`), sector selection snaps
(no frame blend), the dither is a Bayer matrix (not the `sin()` hash Codex itself
flagged as a fragment tax), and the cube→card split edge is folded into the existing
WALK_CALM band-code fingerprint so the parked-camera zero-rebuild property survives.

---

## 1. The pattern being copied — far-tree card tier anatomy

`FacetFarTrees` proves every mechanism this design needs, on this exact renderer
(WebGL2 `gl_compatibility`, WASM, threaded). The implementer should keep this map open:

| Mechanism | Where (facet_far_trees.gd) | What Stage 2 reuses |
|---|---|---|
| Shared indexed card mesh (2 cross quads + cap, UV2.x = side/top row selector) | `_build_card_mesh` :1448-1469, `_quad` :1471-1479 | Same builder shape; ours is 1 vertical quad + 1 cap (no cross) |
| MultiMesh config: `TRANSFORM_3D`, **`use_colors=false`**, `use_custom_data=true`, `instance_count` = cap, huge `custom_aabb` | `setup_instance` :461-475 | Verbatim recipe |
| 16-float instance stride (12 transform + 4 custom) | `CARD_STRIDE` :43-45 | Verbatim (`STRUCT_CARD_STRIDE := 16`) |
| Whole-buffer `set_buffer` upload + `visible_instance_count` | `_rebuild_cards` :1208-1209 | Verbatim (never `set_instance_transform` — a no-op on a set_buffer-backed MM, :703-707) |
| CPU-rasterized atlas from the generator's cell sets, `filter_nearest`, 3-px pad | `_build_atlas` :1484-1495, `_raster_tile` :1499-1527 | Same approach, projected per azimuth view |
| Shader: HEAD + `VoxiLight.shade_glsl()` + TAIL; atlas tile UV from instance data; alpha-scissor discard; `ALBEDO = tex.rgb · voxi_shade(n̂_radial, sun_dir)`; `planet_centre` uniform (MultiMesh MODEL·0 is the *instance* origin, not the body centre — class doc :27-34) | `_CARD_HEAD/_CARD_TAIL` :188-212, `shader_code` :246-271, `make_material` :273-291 | Same composition, plus in-shader billboard + sector select |
| Sun feed + FP_FAR_TERMINATOR_WELD seeding | `set_sun_dir` :514-521, seed :278-280 | Reuse `FacetFarStructures.set_sun_dir` (:235-237), extended to the card material |
| `tier_fade` whole-tier dissolve uniform for the shell band | shader splice :263-270, step drive :820-824 | Same splice for zone B |
| Camera → absolute frame | `_cam_to_absolute` :1544-1547 | Already present in FacetFarStructures :317-320 |
| Near-handoff cull + streaks + fingerprint | `_nearcull_emit` :550-578 | **Not copied** — FacetFarStructures has its own (§7.3 streaks, `_cull_emit` :448-488), preserved untouched |

**The gl_compatibility COLOR-slot trap** ([[voxiverse-far-trees-colorfix]]): a MultiMesh
with `use_colors=false` has no instance-color slot, and the tree-card shader **never reads
vertex `COLOR`** — so the ungated `COLOR *= instance_color` repack garbage can't reach the
output. The rung-1 tree *meshes* needed FP_FAR_TREES_COLORFIX (`use_colors=true` + explicit
white at floats [12..15], stride 20 — :493-499, :1363-1374) because their archetype meshes
carry vertex colors. **Our card shader reads only the atlas — `use_colors=false`,
never read COLOR, stride stays 16.** This is a hard rule for the implementer.

---

## 2. Flag + constants (byte-off contract)

All in `godot/src/cosmos/cube_sphere.gd`, following the FP_STRUCT_* idiom
(:1284-1424 — every feature `const FP_* := false`, consts consulted only under the flag):

```gdscript
## FP_STRUCT_CARDS (docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md) — far GEN houses render as directional
## impostor cards (one MultiMesh, 4 tris/house, view sector chosen in-shader) beyond STRUCT_CARD_MIN;
## the merged-cube path retains [r0, STRUCT_CARD_MIN) + ALL player-built (tracker) structures. Off ⇒
## the shipped merged-cube tier verbatim (byte-identical; FLAT 6042/0). Needs FP_STRUCT_FAR (+_GEN
## for any GEN record to exist). Composes with WALK_CALM/HANDOFF_HYST/REG_EPOCH (§7) and SHELL_BAND (§9).
const FP_STRUCT_CARDS := false           # far-village impostor-card tier (data-plane swap)
const STRUCT_CARD_MIN := 320.0           # cube→card split radius (blocks); ≤ r0 ⇒ cards own the whole band
const STRUCT_CARD_INST_MAX := 2048       # card MultiMesh instance cap (nearest-first fill)
const STRUCT_CARD_TILE := 32             # atlas texels per tile (32² RGBA8)
const STRUCT_CARD_AZIMUTHS := 8          # side views per archetype (45° sectors, snap-select in-shader)
const STRUCT_CARD_ARCHES := 10           # §3: 2 flat + 8 gabled canonical archetypes
const STRUCT_CARD_FADE_W := 16.0         # P2 (optional) cube↔card dither cross-fade half-width (blocks)
```

Derived (not consts): atlas = `(AZIMUTHS+1) × TILE` wide × `ARCHES × TILE` high
= 288 × 320 RGBA8 = **368,640 B**; instance buffer = `INST_MAX × 16 × 4` = **128 KB**.

**Byte-off contract** (`FP_STRUCT_CARDS == false` ⇒ the shipped merged-cube path verbatim):

1. `FacetFarStructures.setup_instance` (:178-194) constructs the card MMI / MultiMesh /
   atlas / card material **only under the flag** — off, no node, no texture, no shader
   compile (the FP_STRUCT_SHELL_BAND `_shell_material` gating at :182-185 is the template).
2. `_resnapshot` (:346-355) runs the §6 per-record card-param precompute only under the
   flag — off, the loop body is the shipped two lines.
3. `_rebuild` (:554-596) grows a card sink only under the flag — off, the record loop,
   `_ensure_bake`, `_commit_mesh` all execute the shipped lines verbatim.
4. `_band_code` (:529-547) adds the split-edge band code (§7.3) only under the flag.
5. `shader_code()`-style string splices for the card shader exist in a new function that
   is only *called* under the flag.

Gate: `verify_feature.gd` FLAT stays **6042/0** with the flag off (villages are absent in
FLAT regardless, and every new line is behind the flag).

---

## 3. Archetype canonicalization

### 3.1 The parametric space (from `structure_gen.gd`)

`house_info` (:186-229) yields exactly these visual parameters:

| Param | Range | Source | Visual role at ≥ 320 blk |
|---|---|---|---|
| `w`, `d` | [5, 11] each (`STRUCT_FOOT_MIN/MAX` :34-35) | salts 205/206 | **continuous per-instance scale** |
| `wall_h` | {3, 4} (`WALL_MIN/MAX` :43-44) | salt 207 | silhouette proportion → **archetype axis** |
| `roof` | {0 flat, 1 gabled} | salt 209 | silhouette shape → **archetype axis** |
| `gable_h` | `min(d/2, 11−wall_h)` = `floor(d/2)` ∈ {2,3,4,5} (:220-224; the 11−wall_h cap ≥ 7 never binds for d ≤ 11) | derived | roof pitch/height → **archetype axis** |
| `door` | {0:−x, 1:+x, 2:−z, 3:+z} (:214, `_is_door` :349-361) | salt 208 | **folds into per-instance yaw** (§3.3) |
| materials | fixed: stone floor, wood walls, dark-oak posts+roof, glass windows (`warm_up` :74-84) | — | baked into tiles |

Total house height above the pad = `rtop + 1` where `rtop = wall_h + gable_h` (gabled) or
`wall_h + 1` (flat) (`_roof_top_ly` :237-238) — recoverable per instance from the registry
bbox as `bmax.y − bmin.y + 1` (`make_record` :410-411), so height needs no archetype slot.

### 3.2 The archetype table (10 rows)

Because `gable_h` is a pure function of `d` and the proportions (wall vs roof) change the
silhouette, gabled archetypes split on `(wall_h, gable_h)`; flat splits on `wall_h` only:

| `arch` | roof | wall_h | gable_h | canonical bake dims (w × d) | H (blocks) |
|---:|---|---:|---:|---|---:|
| 0 | flat | 3 | — | 8 × 8 | 5 |
| 1 | flat | 4 | — | 8 × 8 | 6 |
| 2 | gabled | 3 | 2 | 8 × 5 | 6 |
| 3 | gabled | 3 | 3 | 8 × 7 | 7 |
| 4 | gabled | 3 | 4 | 8 × 9 | 8 |
| 5 | gabled | 3 | 5 | 8 × 11 | 9 |
| 6 | gabled | 4 | 2 | 8 × 5 | 7 |
| 7 | gabled | 4 | 3 | 8 × 7 | 8 |
| 8 | gabled | 4 | 4 | 8 × 9 | 9 |
| 9 | gabled | 4 | 5 | 8 × 11 | 10 |

Canonical `d = 2·gable_h + 1` (odd ⇒ a 1-cell ridge row, the common look); canonical
`w = 8` (mid-range). The mapping, as ONE pure static (new small class `StructCardKit`,
or statics on `FacetFarStructures` — implementer's choice; a separate class keeps
`verify_` drivers hermetic):

```gdscript
static func arch_index(roof: int, wall_h: int, gable_h: int) -> int:
    if roof == 0:
        return wall_h - WALL_MIN                              # 0..1
    return 2 + (wall_h - WALL_MIN) * 4 + (gable_h - 2)        # 2..9
```

**Tile budget justification**: 10 archetypes × (8 azimuth + 1 top) = **90 tiles**, 360 KB
RGBA8 — *smaller* than Codex's 144-tile/576 KB proposal while capturing an axis
(`gable_h`) Codex's 16-archetype table ignored (its "flat/gabled × wall 3/4 × 4 doors"
collapses all roof pitches to one, a visible silhouette error at the band's inner edge,
while spending 4× tiles on door orientation that a free yaw rotation provides exactly).

### 3.3 Door → per-instance yaw; w/d → per-instance scale

Canonical bake frame: house-local axes `(x̂, ŷ, ẑ)` with the **door on the −x wall**
(door = 0 in `_template_block`'s frame) and azimuth 0 defined as *viewing the door face*.
Per instance, define the **door-forward axis** `e_f` and side axis `e_s` from the owner
facet's lattice basis `(ê_u, n̂, ê_w) = FacetAtlas.frame_basis(fid)` (the axes the near
voxel house is aligned to — the FP_FT_FRAME_WELD lesson, `facet_far_trees.gd:1230-1234`):

| `door` | `e_f` (outward door normal) | `e_s = n̂ × e_f` | extent along `e_f` / `e_s` |
|---|---|---|---|
| 0 (−x) | `−ê_u` | | `w_f = w`, `w_s = d` |
| 1 (+x) | `+ê_u` | | `w_f = w`, `w_s = d` |
| 2 (−z) | `−ê_w` | | `w_f = d`, `w_s = w` |
| 3 (+z) | `+ê_w` | | `w_f = d`, `w_s = w` |

`(w_f, w_s)` are pre-swapped at precompute time (§6) so the shader never branches on door.

---

## 4. Atlas generation — CPU-rasterized at setup (decision + method)

**Decision: CPU-rasterize from `StructureGen`, like the tree atlas — NOT a prebaked
imported asset.** Tradeoff, made explicit:

- *Prebaked asset* (Codex's preference): zero runtime cost, best possible pixels — but it
  forks the source of truth. The repo's law is that far representations derive from the
  same generator/palette as the near voxels *by construction* (`_build_atlas`
  :1481-1483 derives tree tiles from `TreeGen.archetype_cells` + `BlockCatalog.color_of`;
  `StructDecimator` colors from `BlockCatalog.color_of`, struct_decimator.gd:109). An
  imported PNG silently rots when `_template_block` or the palette changes, adds an
  import-pipeline artifact, and cannot follow `FP_FT_TEXMEAN_COLOR` palette switching.
- *CPU raster*: ~90 tiles × a few hundred cells ≈ tens of ms **once at setup_instance**
  (the tree atlas precedent — acceptable; it can move behind the boot-splash prewarm if it
  ever shows), always in lock-step with the generator.

### 4.1 Canonical cell enumeration

For archetype `a`, synthesize `hi = {base: Vector3i(0,0,0), w: 8, d: <table §3.2>,
wall_h, door: 0, roof, gable_h}` and enumerate solid cells by calling
**`StructureGen._template_block(hi, x, y, z, cg)` verbatim** (structure_gen.gd:308-346)
over the bbox `x ∈ [0,w)`, `z ∈ [0,d)`, `y ∈ [1, 1+rtop]` with `cg = 0` (so the
carve branch :327-329 never fires — no terrain in the canonical frame). Cells with
id > 0 are solid; color via a `_st_color_of(id)` mirroring `_ft_color_of`
(facet_far_trees.gd:385-388: `BlockTextures.mean_color_of` under FP_FT_TEXMEAN_COLOR,
else `BlockCatalog.color_of`). Using `_template_block` (not a re-derivation) means the
tiles can never drift from the near voxel house.

### 4.2 View projection (upper hemisphere only — houses sit on terrain)

Houses are ground objects viewed from at-or-above the horizon, so **no lower-hemisphere
views and no octahedral map**: 8 horizontal azimuth views + 1 top view per archetype.

- **Side view k (k = 0..7)**, camera azimuth `α_k = k · 45°` measured from `+x̂` toward
  `+ẑ` in the canonical frame, elevation 0 (orthographic, horizontal — representative of
  the near-ground camera that dominates gameplay at this band). Projection axes:
  `right = (−sin α_k, 0, cos α_k)`, `up = ŷ`; view dir `dir = (−cos α_k, 0, −sin α_k)`
  (α_0 looks at the door face). Painter's algorithm: sort cells by `cell · dir`
  ascending (far first), splat each as a filled rect (the `_raster_tile` /
  `_fill_rect` machinery, facet_far_trees.gd:1499-1536, generalized to a rotated
  projection), 3-px pad, ground row at tile bottom (v = 1). Tile horizontal span
  normalized to the canonical projected width `w·|cos α_k| + d·|sin α_k|` — the shader
  scales the quad to the *instance's* projected width (§8), so tile content always maps
  edge-to-edge.
- **Top view (column 8)**: for each `(lx, lz)` paint the topmost solid template block's
  color (the `top_decoration` law, structure_gen.gd:285-302, restricted to the canonical
  house) — u along `+x̂`, v along `+ẑ`.
- Tile background `Color(0,0,0,0)`; `filter_nearest` sampling (no mip bleed, the tree
  atlas convention :190) makes the 3-px pad sufficient against seams.

Atlas layout: **column = view (0..7 side, 8 top), row = archetype (0..9)**;
`ImageTexture.create_from_image` of a 288×320 FORMAT_RGBA8 image. Memory: 368,640 B.

**No frame blending** between azimuth sectors: at ≥ 320 blocks a house is ≲ 30 px; a 45°
sector snap changes a handful of texels and only while the camera *orbits* the house
(rare in walk gameplay). Blending would double texture fetches and need two sector
computations. Revisit only if live A/B shows popping (then: dither-blend over ±4° at the
sector edge, same Bayer mask as §8.3).

---

## 5. The card mesh + MultiMesh

### 5.1 Shared indexed mesh (built once, static, like `_card_mesh` :70, :1448-1469)

Two indexed quads, 8 verts / 12 indices / **4 triangles**:

- **Vertical billboard quad** (side tile): `VERTEX = (x, y, 0)`, `x ∈ {−0.5, +0.5}`,
  `y ∈ {0, 1}`; `UV` = tile-local with v flipped so y=0 samples tile-bottom (the `_quad`
  convention :1476); `UV2.x = 0.0`.
- **Roof cap quad** (top tile): `VERTEX = (x, 1, z)`, `x, z ∈ {−0.5, +0.5}`; `UV` maps
  `+x̂ → u`, `+ẑ → v`; `UV2.x = 1.0`.

The cap sits at local y = 1 (the ridge/roof top). For gabled archetypes the true roof
*eave* is lower; at ≥ 320 blk the ≤ 5-blk error is < 1° of elevation — accepted. (If a
later polish wants exact eave placement, pack `eave_frac` into the custom.x fraction —
`custom.x = arch + eave_frac·0.9`, the floor/fract idiom of facet_far_trees.gd:998-999 —
and lerp the cap's y in the shader. Not in scope for P0.)

### 5.2 MultiMesh + node (the verbatim tree recipe, :461-475)

```gdscript
_card_mm = MultiMesh.new()
_card_mm.transform_format = MultiMesh.TRANSFORM_3D
_card_mm.use_colors = false                 # §1 COLOR-trap rule: no color slot, shader never reads COLOR
_card_mm.use_custom_data = true             # set BEFORE instance_count (engine packs layout then)
_card_mm.mesh = _card_mesh
_card_mm.instance_count = CubeSphere.STRUCT_CARD_INST_MAX
_card_mm.visible_instance_count = 0
_card_mmi = MultiMeshInstance3D.new()
_card_mmi.name = "FacetFarStructCards"
_card_mmi.multimesh = _card_mm
_card_mmi.material_override = _card_material
_card_mmi.custom_aabb = AABB(Vector3(-12000,-12000,-12000), Vector3(24000,24000,24000))  # :474 convention
ring.add_child(_card_mmi)                   # child of FacetFarRing ⇒ placement/anchor/SN3 transforms free
```

Constructed in `setup_instance` (:178-194) **under the flag only**. The node rides the
same ring the cube `_mi` rides (`facet_far_ring.gd:627-628` constructs the tier;
`:1529-1530` steps it), so orbit-frame correctness is inherited exactly like the trees.

### 5.3 Per-instance layout — 16 floats (= tree `CARD_STRIDE`, :43-45)

Transform (floats 0..11, three rows of `[bx by bz | origin]`, the `_write_card` layout
:1241-1243):

| Basis column | Content | Length encodes |
|---|---|---|
| X | `e_f` (door-forward, unit in ring frame) | block→world scale (ring rigid ⇒ 1; SN3 orbit scale rides MODEL) |
| Y | `n̂ · H` (radial-up × height-in-blocks) | house height |
| Z | `e_s` (side axis, unit) | — |
| origin | house **base centre**: lattice `((bmin.x+bmax.x+1)/2, bmin.y, (bmin.z+bmax.z+1)/2)` → `+ FacetAtlas.datum_lift(fid, cx, cz)` under FP_FT_FRAME_WELD (mirror `_ensure_bake`'s vertex law :639-643) → `lattice_to_world64` | — |

`H = bmax.y − bmin.y + 1` (blocks). `n̂` = the radial at the origin (normalize of the
world position — the same construction the tree enum uses, :970-975); using
`frame_basis(fid).y` is equivalently acceptable and matches the near lattice exactly.

Custom data (floats 12..15): **`(arch, w_s, w_f, fade)`** — archetype row 0..9, side/forward
extents in blocks (pre-swapped per §3.3), dither fade (1.0 in P0).

---

## 6. Precompute — consuming the REG_EPOCH snapshot

`_resnapshot(ver)` (:346-355) is already the ONE per-version registry materialization
with per-record precomputed world centres. Under FP_STRUCT_CARDS it additionally fills a
parallel packed param array (`STRUCT_CARD_PREC := 12` floats/record):

```
_card_prec[i*12 .. ]: [is_card(0/1), arch, w_s, w_f, H, ox, oy, oz, fx, fy, fz, spare]
```

where `(ox,oy,oz)` is the §5.3 origin (ring-frame/absolute — the same frame `_centres`
lives in) and `(fx,fy,fz)` = `e_f`. Per record:

1. **`is_card = 0` for any record with `root >= 0` or `source != StructureGen.SOURCE_GEN`**
   (structure_gen.gd:59, :402-423 — player-built/tracked structures have no `house_info`
   and unique geometry; they stay on the merged-cube path at every distance).
2. For GEN records, recover `(fid, hx, hz)` by inverting `pack_root`
   (structure_gen.gd:428-432: `p = −root − 1; fid = (p >> 40) & 0xFFF;
   hx = zigzag⁻¹((p >> 20) & 0xFFFFF); hz = zigzag⁻¹(p & 0xFFFFF)` — add a
   `StructureGen.unpack_root` static + a round-trip gate) and call
   `StructureGen.house_info(hx, hz, ctx)` with a `TerrainConfig.GenCtx.new(0, fid)`
   (GATE_MEMO makes repeats O(1), structure_gen.gd:175-184; StructGenIndex enumerates
   with the same ctx shape, struct_gen_index.gd:85). Empty `hi` (cannot happen for a
   record StructGenIndex emitted, :100-102 — defensive) ⇒ `is_card = 0`.
3. `arch = arch_index(hi.roof, hi.wall_h, hi.gable_h)`; `(w_f, w_s)`, `e_f` per §3.3
   from `hi.door` + `FacetAtlas.frame_basis(fid)`; `H`, origin from the record bbox.

Cost: O(N-records) hashes + one `lattice_to_world64` each, **once per registry version**
(the REG_EPOCH law, :331-341) — the same order as the existing `_centres` fill, so the
stationary O(1)-skip and the parked-over-village fix are untouched. The shipped prelude
(`step()`'s non-EPOCH branch :302-315) has no snapshot; when FP_STRUCT_CARDS is on
**require FP_STRUCT_REG_EPOCH on in the same arm** (assert/log once at setup if not) —
Stage 0b is merged, so this costs nothing and avoids a second param-cache code path.

---

## 7. Preserving the control machinery — the rebuild becomes two sinks

### 7.1 What does NOT change

`step()` (:258-315), `_prelude_epoch` (:331-341), `_probe_pass` (:398-444), `_cull_emit`
(:448-488), `_inputs_changed` (:367-390), WALK_CALM's `_band_fp` fold (:413-424),
HANDOFF_HYST's Schmitt edges (:533-540), NEAR_HOLD (:452-471), NEAR_GUARD's credit gate
(:361-362), BAKE_STAGE's drain (:660-678, now only feeding the inner cube band), shell
visibility (:204-233), `_evict_stale_bakes` (:688-702), sun/centre uniform pushes
(:290-292 — extended to also set the card material's `planet_centre`/`sun_dir`). The cull
decision `_cull_emit(rec, cam_abs)` is representation-agnostic — a culled house is
withheld from *whichever* sink would have taken it, so the near-handoff behaves
identically for cards.

### 7.2 `_rebuild` (:554-596) — the data-plane swap

```gdscript
func _rebuild(reg: Array, cam_abs: Vector3) -> void:
    _dbg_rebuild_count += 1
    _evict_stale_bakes(reg)
    var ordered := ...                                   # shipped nearest-first sort :558-559
    if CubeSphere.FP_STRUCT_BAKE_STAGE: ...              # shipped drain :562-564 (cube sink only)
    var verts/colors/tris/count/capped                   # shipped cube accumulators
    var cbuf: PackedFloat32Array; var cn := 0; var ccapped := false   # card sink (flag-gated alloc)
    if CubeSphere.FP_STRUCT_CARDS:
        cbuf.resize(CubeSphere.STRUCT_CARD_INST_MAX * 16)
    for i-th rec in ordered:                             # keep index i ⇒ _card_prec row
        var dist := _structure_dist(rec, cam_abs)        # (or the _centres lookup where available)
        if dist > CubeSphere.STRUCT_FAR_MAX: continue
        if not _cull_emit(rec, cam_abs): continue        # near-handoff — UNCHANGED, both sinks
        if CubeSphere.FP_STRUCT_CARDS and _card_eligible(i, dist):
            if cn >= CubeSphere.STRUCT_CARD_INST_MAX: ccapped = true; continue
            _write_card_inst(cbuf, cn, i); cn += 1; count += 1
            continue                                     # a house renders in EXACTLY one sink
        ... shipped cube path: _ensure_bake / tri cap / append ...
    _commit_mesh(verts, colors)                          # shipped
    if CubeSphere.FP_STRUCT_CARDS:
        _card_mm.set_buffer(cbuf)                        # whole-buffer upload (tree law :1208)
        _card_mm.visible_instance_count = cn
        _live_cards = cn; _card_capped = ccapped
    ... shipped tail :592-596 ...
```

`_card_eligible(i, dist)` ⇔ `_card_prec[i].is_card == 1 AND dist ≥ split_lo(i)` where
`split_lo` applies the §7.3 hysteresis. `_write_card_inst` copies precomputed floats into
the §5.3 layout — **no bake, no decimate, no allocation per house**; the whole card pass
over 2,048 records is a tight packed-array loop (sub-ms). Note `_ensure_bake` is now
reached only by inner-band + player-built records, so `_baked`/`_baked_bytes` *shrink*
(most GEN houses never bake) — NEVER-OOM headroom improves.

The `debug_*` hooks (`verify_structures.gd` drives `_rebuild`/`_cull_emit` directly)
gain: `live_cards()`, `card_capped()`, `debug_card_buffer() -> PackedFloat32Array`
(the `_last_buf` read-back convention, facet_far_trees.gd:1615, :1737-1738).

### 7.3 The split edge joins the WALK_CALM fingerprint

WALK_CALM suppresses the raw camera re-arm (:372-375), so a walking camera that carries a
house across the 320 split would otherwise leave it in the wrong sink until some other
input drifts. Fix: under `FP_STRUCT_CARDS and FP_STRUCT_WALK_CALM`, `_band_code`
(:529-547) splits code 2 (BAND) at `STRUCT_CARD_MIN` into **2 (cube sub-band) and 4 (card
sub-band)**, with the same state-keyed Schmitt dead-band (`STRUCT_HYST_W`, :533-540 /
cube_sphere.gd:1406) on the new edge under FP_STRUCT_HANDOFF_HYST. The band-fp fold
(:419-424) then re-arms exactly one rebuild when any house crosses the split, and the
hysteresis stops razor-edge oscillation. Off-flag `_band_code` is untouched (codes 0..3).

With per-instance `fade ≡ 1.0` in P0, the card buffer is a pure function of
(snapshot version, membership bands, cull states) — **the parked-camera zero-rebuild
property of Stage 0b/1 is preserved bit-for-bit**.

### 7.4 Cube→card handoff visual law

P0: **hard handoff with hysteresis** (§7.3). Both representations share the same base
anchor (§5.3 origin == the bake's lattice→world law incl. datum_lift), the same
footprint/height, and the same palette family — the swap at ≥ 320 blk (< 30 px) is a
texel-level change. P2 (only if live A/B shows a pop): dither cross-fade over
`STRUCT_CARD_MIN ± STRUCT_CARD_FADE_W` — card side via custom `.w` (the tree
`card_fade` law, facet_far_trees.gd:419-425), cube side by baking the fade into the
merged mesh's unused `COLOR.a` and a one-line dither in `_TAIL`; this re-admits a
bounded camera-distance dependency, so it must also relax §7.3's purity note (fades
quantized to 1/16 steps to keep rebuild churn bounded).

### 7.5 Keep ANY cube band at all? — Recommendation

**Yes, keep `[r0, STRUCT_CARD_MIN=320)` as a cube band in P0**, for three reasons:
(1) at r0 ≈ 128 (FP_NEAR_RADIUS_DIET) a house is ~60-130 px — a flat billboard visibly
lacks parallax on approach; the trees solved the same band with rung-1 3D mini-meshes
(:84-95), and the cube bake *is* our mini-mesh; (2) the inner band holds only the nearest
village (≈ 20-40 houses ⇒ ~10-25k tris, further dietable by enabling FP_STRUCT_COARSE_FAR
/ its 8-target pitch, cube_sphere.gd:1318-1326, in the same arm); (3) it keeps
player-built structures and GEN houses on one near path. `STRUCT_CARD_MIN` is a single
const: the **cards-all-the-way A/B arm is `STRUCT_CARD_MIN := 0.0`** (then
`dist ≥ r0` from the shipped band floor governs) — ship both arms through deploy_cheats
and let the live A/B decide ([[voxiverse-deploy-cheats-pipeline]]).

---

## 8. The card shader

New strings beside `_HEAD/_TAIL` (facet_far_structures.gd:106-119), composed the tree
way (`head + VoxiLight.shade_glsl() + tail`, :121-125) in a flag-gated
`card_shader_code()` / `make_card_material()` (seed `sun_dir` from
`TierPlace.last_sun_dir()` under FP_FAR_TERMINATOR_WELD and set the FP_SHADE_UNIFIED
uniforms — the :127-139 recipe verbatim).

### 8.1 Vertex — billboard on a sphere + in-shader view sector

> **CORRECTED after the Fable+Codex review** (three defects the first draft encoded, all
> verified against the shipped tree shader). (a) Under `world_vertex_coords` the vertex
> shader *receives* `VERTEX` already in WORLD space (`MODEL·local`, ~planet-radius) — it
> must **never** be read as the unit-quad local coord (that rendered planet-scale streaks).
> The local corner is reconstructed from `UV`/`UV2`. (b) The canonical frame maps
> `x̂ ↦ −e_f`, `ẑ ↦ +e_s`, so the azimuth is `α = atan2(−sa, ca)` (the `sa` is **mirrored**;
> `atan2(sa,ca)` swapped left/right views). (c) The roof-cap `u` is canonical `+x̂ = −e_f`,
> so the cap's local x is **negated** along `mx`. (d) The atlas tiles carry a 3-px pad, so
> the tile-local UV is remapped onto the inset `[atlas_uv_lo, atlas_uv_lo+atlas_uv_span]`
> before the lookup (else houses render ~0.81× and float ~0.09·H above the base).

```glsl
shader_type spatial;
render_mode cull_disabled, world_vertex_coords;
uniform sampler2D house_atlas : source_color, filter_nearest;
uniform vec3 planet_centre = vec3(0.0);
uniform float atlas_cols = 9.0;   // 8 azimuth + 1 top
uniform float atlas_rows = 10.0;
uniform float atlas_uv_lo = 0.109375;    // (PAD+0.5)/TILE          — 3-px pad inset (P1-4)
uniform float atlas_uv_span = 0.78125;   // (TILE-2*PAD-1)/TILE
// + VoxiLight.shade_glsl()  (defines sun_dir + voxi_shade)

varying vec2 v_uv;
varying vec3 v_n;
// (+ varying flat float v_fade; only under FP_STRUCT_SHELL_BAND)

void vertex() {
    // Instance frame from MODEL_MATRIX columns (world; ring transform + SN3 scale ride along):
    vec3 o  = MODEL_MATRIX[3].xyz;                 // house base centre
    vec3 mx = MODEL_MATRIX[0].xyz;                 // e_f · s   (s = block→world scale)
    vec3 my = MODEL_MATRIX[1].xyz;                 // n̂ · H · s
    vec3 mz = MODEL_MATRIX[2].xyz;                 // e_s · s
    float s   = length(mx);
    vec3 up_n = normalize(my);
    float arch = floor(INSTANCE_CUSTOM.x);
    float w_s  = INSTANCE_CUSTOM.y;
    float w_f  = INSTANCE_CUSTOM.z;
    // Local unit-quad corner from UV/UV2 (VERTEX is WORLD here — reconstruct, never read it as local):
    float lx = UV.x - 0.5;

    // Horizontal house→camera direction (billboard axis + azimuth source):
    vec3 vc  = CAMERA_POSITION_WORLD - o;
    vec3 fh  = vc - up_n * dot(vc, up_n);
    float fl = length(fh);
    fh = (fl > 1e-4) ? fh / fl : normalize(mx);    // overhead degeneracy → cap owns the view

    vec3 wp; float col;
    if (UV2.x < 0.5) {
        float ly = 1.0 - UV.y;                     // ground (UV.y=1) → ly 0; top → ly 1
        vec3 raxis = normalize(cross(up_n, fh));
        float ca = dot(fh, normalize(mx));         // cos α  (α from e_f)
        float sa = dot(fh, normalize(mz));         // sin α  (from e_s)
        float halfw = 0.5 * (w_s * abs(ca) + w_f * abs(sa)) * s;
        wp = o + raxis * (lx * 2.0 * halfw) + my * ly;
        float alpha = atan(-sa, ca);               // canonical x̂↦−e_f, ẑ↦+e_s ⇒ mirror sa
        float k = floor(alpha * (8.0 / 6.2831853) + 0.5);
        col = mod(k + 8.0, 8.0);                    // sector 0..7
    } else {
        float lz = UV.y - 0.5;
        // roof cap: house-local tangent frame. Canonical +x̂ = −e_f ⇒ negate local x along mx.
        wp = o + mx * (-(lx) * w_f) + mz * (lz * w_s) + my;
        col = 8.0;                                  // top-view column
    }
    VERTEX = wp;                                    // world_vertex_coords (WRITE only)
    vec2 uv_in = atlas_uv_lo + UV * atlas_uv_span;  // remap tile-local UV onto the 3-px pad inset
    v_uv = vec2((col + uv_in.x) / atlas_cols, (arch + uv_in.y) / atlas_rows);
    v_n  = normalize(wp - planet_centre);           // the ONE radial law (tree class doc :27-34)
}
```

Notes for the implementer:
- `world_vertex_coords` is required for the `VERTEX = wp` OUTPUT; under it VERTEX is read-
  WORLD, so the local corner is reconstructed from UV/UV2 (never read from VERTEX). It is
  gl_compatibility-safe.
- All 8 verts of a quad compute the same `col`/`raxis` (same `o`) — no cross-vertex tear.
- The sector snap means **camera rotation and orbiting rewrite NOTHING on the CPU** — the
  design's central economy (Codex §2, kept).
- The `normalize(mx)` fallback for the overhead case is arbitrary-but-stable; the vertical
  quad is edge-on there and the cap owns the pixels.
- The sector math is gate-covered headless by a CPU twin (G-ST-CARD-SHADER): for the view-k
  reference direction `fh_k = cos(α_k)·e_f − sin(α_k)·e_s`, `round(atan2(−sa,ca)·8/2π)` == k.

### 8.2 Fragment

```glsl
void fragment() {
    vec4 t = texture(house_atlas, v_uv);
    if (t.a < 0.5) discard;                        // alpha scissor — opaque pass, no sorting
    // (P2 / shell-band dissolve — §8.3; absent in the P0 string)
    ALBEDO = t.rgb * voxi_shade(v_n, sun_dir);
}
```

Identical lighting law to every far tier (`ALBEDO = tex.rgb · voxi_shade(radial n̂,
sun_dir)`, facet_far_trees.gd:206-211). No hue jitter in P0 (houses of one village
sharing a palette is *correct*; add a ±4% jitter from a root hash later if it reads flat).

### 8.3 Dissolve dither — Bayer, not `sin()` (Codex's own critique, applied)

Where a dissolve is needed (§7.4 P2 fade; §9 zone-B `tier_fade`), use a 4×4 Bayer
matrix, guarded so fully-opaque pixels pay nothing — the exact defect class
FP_STRUCT_SHADER_LITE patches in the shell shader (cube_sphere.gd:1328-1341):

```glsl
float _bayer4(vec2 fc) {
    int x = int(mod(fc.x, 4.0)); int y = int(mod(fc.y, 4.0));
    int idx = (y * 4 + x);
    // 4x4 Bayer as a const-array-free arithmetic permutation:
    int b = (x ^ y) * 4 + ((y * 2 + x) & 3);   // implementer may substitute a mat4 const
    return (float(b) + 0.5) / 16.0;
}
...
float f = v_fade * tier_fade;
if (f < 0.999 && _bayer4(FRAGCOORD.xy) > f) discard;
```

(The exact Bayer expression is the implementer's to verify against the reference matrix;
the *requirements* are: no transcendental, guarded by `f < 0.999`, stable per-pixel.)

### 8.4 Shell band (zone B) composition

Mirror `FP_FT_SHELL_BAND` §3.3 exactly (facet_far_trees.gd:263-270 splice + :820-824
per-step drive): under `FP_STRUCT_SHELL_BAND`, the card material gains a
`uniform float tier_fade = 1.0`, driven from `_apply_shell_visibility`'s zone-B ramp
(:216-220) — cards stay **live and lit** off-surface with the standard radial-shade
material, exactly as the tree cards do in zone B (they prove the planet_centre-uniform
path does not black out off-surface; the historical black-out was specific to the merged
tier's material, :142-148 — the implementer should still eyeball zone B in the first live
arm). Zone O hides the card MMI with the rest (the fine-map roof texels own the view,
FP_STRUCT_LOD). `_apply_shell_visibility` extends: whatever it does to `_mi.visible`
today (:204-224), it does to `_card_mmi.visible` too; zone B may keep the *cube* band on
its shipped `_shell_material` path unchanged.

---

## 9. Culling — one MultiMesh, deliberately

Codex's caveat: one MultiMesh = one AABB = no per-instance frustum cull. **Decision:
keep ONE MultiMesh with the huge `custom_aabb`** (the tree-card convention :469-474):

- Worst-case vertex cost is 2,048 instances × 8 verts = **16k verts** of near-trivial
  shader — ~0.1% of the budget the cube tier was burning; per-instance frustum culling
  would save a fraction of nothing.
- Over-horizon houses resolve to fragments behind the terrain silhouette; the opaque
  pass's front-to-back ordering + early-Z discards them at raster, and a 4-tri sprite's
  worst case is a few hundred wasted fragments.
- Splitting per-village/facet batches restores culling at the cost of N draws, N
  `set_buffer` uploads, N dirty-tracking paths through WALK_CALM — real complexity for no
  measurable win at this instance count. **Escape hatch** (documented, not built): if
  instances ever grow ~10× (multi-planet mega-villages), split the buffer by facet
  (`wanted`-facet granularity like the tree cache) — nothing in this design blocks it.
- Optional-and-cheap alternative if a live profile ever implicates far-side instances: a
  CPU horizon test in the rebuild loop (`dot(n̂_house, n̂_cam) < cos θ(h)` ⇒ skip) — one
  dot per record, but it adds altitude-dependent membership churn to the fingerprint
  machinery, so it stays OUT unless measured necessary.

---

## 10. NEVER-OOM ledger + telemetry

`total_bytes()` (:711-716) adds, under the flag: the fixed card instance buffer
(`STRUCT_CARD_INST_MAX × 16 × 4` = 128 KB), the atlas (368,640 B), the shared card mesh
(~1 KB), and `_card_prec` (`records × 12 × 4`; ≤ ~96 facets × houses — bounded by the
registry itself, struct_gen_index.gd:14, :171-181). Total ≈ **0.5 MB + prec**, well
inside `STRUCT_BYTES_MAX` = 8 MB (cube_sphere.gd:1308) — while the `_baked` store
*shrinks* (§7.2). Gate-asserted (G-ST-CARD-OOM).

Telemetry (the ring dict at `facet_far_ring.gd:6247-6260`, beside `st_rb`/`st_step_us`):
- `st_ci` — live card instances (last rebuild)
- `st_cq` — card cap hit (bool)
- `st_crb_us` — card-sink self-time inside the last `_rebuild` (µs; proves the swap's
  rebuild is sub-ms and shows up in FP_WORST_FRAME_ATTR breakdowns)

All `{}`/absent off-flag (the `bake_stage_state()` convention :681-686 — confound-free A/B).

---

## 11. Gates (verify extensions) — proving it without eyes

Extend `godot/src/tools/verify_structures.gd` (pattern: the existing G-ST-* blocks,
:532-660, with the fake registry provider :31) and `verify_fartier_walk.gd` (G-WC-*):

1. **G-ST-CARD-OFF** — flag off: `setup_instance` creates no card node
   (`_card_mmi == null`), `_resnapshot` leaves `_card_prec` empty, a scripted
   rebuild sequence produces a merged mesh byte-identical to a control tier's
   (`surface_get_arrays` compare). Plus the repo-level FLAT gate: **6042/0**.
2. **G-ST-CARD-ARCH** — `arch_index` is total and injective over the reachable space:
   for every `roof ∈ {0,1}`, `wall_h ∈ {3,4}`, `d ∈ [5,11]` (⇒ `gable_h = d/2 ∈ [2,5]`),
   index ∈ [0,10) and round-trips to the (roof, wall_h, gable_h) triple. Plus
   `unpack_root(pack_root(fid,hx,hz)) == (fid,hx,hz)` over a signed sweep.
3. **G-ST-CARD-ATLAS** — the atlas builds; each of the 90 tiles has > 0 opaque texels;
   the door tile (arch any, view 0) differs from the back tile (view 4) (the door
   actually rasterized); image bytes == 368,640.
4. **G-ST-CARD-EMIT** — fake registry: one GEN record (known `hi`, dist 800) ⇒ rebuild
   emits exactly 1 instance; assert from `debug_card_buffer()`: basis-Y ∥ the record's
   radial (dot > 0.999), |basis-Y| == H, origin == lattice base-centre mapped through the
   same `lattice_to_world64`(+datum_lift) law as `_ensure_bake` (±1e-3), custom ==
   (arch, w_s, w_f, 1.0) with the door-2/3 w/d swap asserted.
5. **G-ST-CARD-SPLIT** — records at dist 200 and 800: the 200 house appears in the merged
   mesh and NOT the card buffer; the 800 house vice-versa; total emitted count constant
   across a scripted camera sweep over `STRUCT_CARD_MIN ± 2·STRUCT_HYST_W` (nothing
   dropped, nothing doubled — the exactly-one-sink invariant), and under
   WALK_CALM+HANDOFF_HYST the band-fp drifts exactly once per genuine crossing
   (extends G-WC-* in `verify_fartier_walk.gd`).
6. **G-ST-CARD-CULL** — drive the existing streak harness (G-ST-HANDOFF, :617-650)
   against the card sink: COVERED × STRUCT_HIDE_STREAK ⇒ the card instance disappears
   from the buffer; NOT_COVERED × STRUCT_SHOW_STREAK ⇒ returns; UNKNOWABLE never flips.
   Player-built record (root ≥ 0) at dist 800 ⇒ merged mesh, never the card buffer.
7. **G-ST-CARD-EPOCH** — parked camera, same registry version ⇒ zero card-buffer
   rewrites across N steps (the REG_EPOCH O(1)-skip holds); a `note_edit` rev bump
   (struct_gen_index.gd:119-130) ⇒ exactly one rebuild next step.
8. **G-ST-CARD-OOM** — `total_bytes()` with a cap-full buffer + atlas + prec ≤
   `STRUCT_BYTES_MAX`; `st_ci ≤ STRUCT_CARD_INST_MAX` under a 4,000-record synthetic
   registry (cap respected, nearest-first: the nearest record IS emitted).

Live A/B (deploy_cheats, [[voxiverse-deploy-cheats-pipeline]]): arm A = Stage 0b only;
arm B = + `FP_STRUCT_CARDS` (with REG_EPOCH + COARSE_FAR + SHADER_LITE + CULL_BACK);
arm C = B with `STRUCT_CARD_MIN := 0.0` (cards-all-the-way). Compare draw prims
(~848k → ~expected 820k + ε), worst-frame p90, and the visual handoff on approach.

---

## 12. Staged build order + effort (cheapest-testable-first)

| Stage | Content | Gate | Est. |
|---|---|---|---|
| C0 | Flag + consts; `arch_index`/`unpack_root` statics + G-ST-CARD-ARCH | headless | 0.5 d |
| C1 | Atlas baker (canonical cells via `_template_block`, 9-view raster) + G-ST-CARD-ATLAS; dump the atlas to PNG once for eyeball QA | headless | 1 d |
| C2 | Card mesh + MultiMesh node + shader; a debug hook that force-writes N synthetic instances (no registry) → visual smoke test in the editor/local web | manual | 1 d |
| C3 | `_resnapshot` prec + `_rebuild` card sink + split banding (§7) + G-ST-CARD-EMIT/SPLIT/CULL/EPOCH/OFF | headless | 1–1.5 d |
| C4 | Shell-band `tier_fade`, telemetry (`st_ci/st_cq/st_crb_us`), ledger + G-ST-CARD-OOM | headless | 0.5 d |
| C5 | deploy_cheats arms A/B/C, live verdict; P2 (cross-fade dither) only if the handoff pops | live | 0.5 d |

**Total: ~4.5–5 focused days** to a live-A/B-able tier (matches Codex's "basic tier
2-4 days, polished ~1 week" from the outside).

---

## 13. Risk register — what the implementer must watch

1. **The MultiMesh COLOR trap**: `use_colors=false`, shader never reads `COLOR`, set
   `use_custom_data` BEFORE `instance_count`, never flip either afterwards
   (setup_instance :461-466; [[voxiverse-far-trees-colorfix]]).
2. **`set_instance_transform` is a no-op on a set_buffer-backed MultiMesh** — all writes
   go through whole-buffer `set_buffer` (facet_far_trees.gd:703-707;
   [[voxiverse-fartree-polish132]]).
3. **The sphere billboard frame**: height axis is the *radial* (basis-Y), never world-Y;
   azimuth is measured in the *house's* `(e_f, e_s)` frame (facet lattice basis + door
   yaw), never a world-axis tangent — the exact FP_FT_FRAME_WELD failure class
   (facet_far_trees.gd:1230-1234, [[voxiverse-fartree-frame]]). Guard the overhead
   `fh → 0` degeneracy (§8.1).
4. **Anchor equality across the handoff**: the card origin must use the SAME
   lattice→world(+datum_lift) law as `_ensure_bake` (:639-643) or the cube→card swap
   pops vertically by the datum lift (±5.5 blk — task #131's bug, re-invitable here).
5. **Atlas seams**: 3-px tile pad + `filter_nearest`; assert no tile's opaque pixels
   touch its border in G-ST-CARD-ATLAS.
6. **Player-built structures must never reach the card sink** (no `house_info`); the
   `root >= 0 / source` guard in §6 is load-bearing — gate-asserted (G-ST-CARD-CULL).
7. **REG_EPOCH coupling**: the prec array lives and dies with `_snapshot`; index-parallel
   arrays must be rebuilt together in `_resnapshot` (a stale prec row against a fresh
   snapshot row renders the wrong archetype somewhere else on the planet).
8. **Dither cost**: any dissolve is Bayer + guarded (`f < 0.999`) — re-introducing an
   unguarded `sin()` hash re-creates the exact fragment tax Codex measured
   (cube_sphere.gd:1328-1341 context).
9. **Zone-B lighting**: verify off-surface cards are lit (not black) in the first live
   arm; the tree cards prove the path but the historical merged-tier black-out (:142-148)
   earns one eyeball check.
10. **`atan` sector wrap**: `alpha` at ±π must land in one sector, not flicker between
    0 and 7 — the `mod(k + 8, 8)` wrap handles it; assert in a shader-mirroring GDScript
    unit check (compute the sector CPU-side for α = π ± ε in G-ST-CARD-ARCH).

---

## 14. Deviations from the Codex proposal (and why)

| Codex (`docs/CODEX-BUILDING-RENDER-ANALYSIS-1.md`) | This design | Why |
|---|---|---|
| 16 archetypes (roof × wall_h × 4 doors), gable pitch ignored | 10 archetypes (roof × wall_h × gable_h), door → per-instance yaw | Door is a free rotation of the canonical frame; gable_h ∈ [2,5] is a real silhouette variable Codex's table flattened. Fewer tiles, more fidelity. |
| 144 tiles / 576 KB | 90 tiles / 360 KB | Above. |
| "preferably a prebaked imported asset" | CPU raster at setup from `_template_block` | Single source of truth with the generator + palette flags; tree-atlas precedent; tens of ms once (§4). |
| Frame-blend unspecified | Explicit **snap**, no blend | ≲ 30 px sprites; blend doubles fetches for an invisible win (§4.2). |
| Impostor for the whole band implied | Retained inner cube band `[r0, 320)` + `STRUCT_CARD_MIN := 0` as an A/B arm | Parallax at 60-130 px; the trees' rung-1 precedent; one const decides (§7.5). |
| Instance data "radial basis/origin, w, h, archetype, fade, azimuth basis" | 12-float transform encodes e_f/n̂·H/e_s/origin; custom = (arch, w_s, w_f, fade) | Fits the existing 16-float CARD_STRIDE exactly; no second buffer (§5.3). |
| sin-hash dither implied by the existing shaders | Bayer 4×4, opacity-guarded | Codex's own §4 finding, applied to the new tier from day one (§8.3). |
| Split village batches "if instance counts grow" | One MultiMesh + documented escape hatch | 16k verts worst case; splitting buys nothing measurable today (§9). |

---

## 15. Summary of touched files (implementation map)

| File | Change |
|---|---|
| `godot/src/cosmos/cube_sphere.gd` | §2 flag + 6 consts |
| `godot/src/world/facet_far_structures.gd` | card node/material/mesh/atlas in `setup_instance`; `_resnapshot` prec; `_rebuild` card sink; `_band_code` split code; `_apply_shell_visibility` card node; `set_sun_dir`/centre push; ledger; debug hooks |
| `godot/src/world/structure_gen.gd` | `unpack_root` static (inverse of :428-432) — pure, flag-free |
| new `godot/src/world/struct_card_kit.gd` (optional) | `arch_index`, canonical-cell enumerator, atlas raster statics (keeps FacetFarStructures readable; pure/static so gates drive it hermetically) |
| `godot/src/tools/verify_structures.gd` | G-ST-CARD-OFF/ARCH/ATLAS/EMIT/SPLIT/CULL/EPOCH/OOM |
| `godot/src/tools/verify_fartier_walk.gd` | G-WC split-edge fingerprint asserts |
| `godot/src/world/facet_far_ring.gd` | telemetry dict: `st_ci`, `st_cq`, `st_crb_us` (:6247-6260) |

No engine (C++) change — GDScript + shader only ⇒ export-web without `scripts/build.sh`,
A/B-able through deploy_cheats same-day.
