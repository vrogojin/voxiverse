# SNOW-ACCUMULATION — locked build ADR (variable-height snow, terrain fill, bounded snowfall sim)

Status: **LOCKED, implementation-ready.** Consolidated ADR for the snow-accumulation feature: snow as a rising level H that fills uneven terrain into a flat white surface, plus a dormant-by-default snowfall simulation that grows it near the player. It builds on and **specializes** `docs/MULTI-MATERIAL.md` (§3a curated opaque+opaque composites, §3c the thin FAM shape family) and `docs/M1-SNOWY-WORLD.md` (the shipped snowy world); decisions those documents locked are cited, not relitigated. This feature **replaces** the fixed all-corners-1 half-slab (`SNOW_SLAB_MODIFIER=85`, `terrain_config.gd:63`, M1 Decision 6) with continuous 0→1 depth.

**Engine-patch verdict, stated up front and loudly: NO godot_voxel C++ patch is required for any part of this design.** Every mechanism is existing module API: `VoxelBlockyModelMesh` + per-surface material overrides (the shipped wet-composite pattern, `module_world.gd:836-871`), frozen sampled ARID tables (`module_world.gd:41-61`), and ≤2-surface baked models (MULTI-MATERIAL §1.5, `MAX_SURFACES=2`). The only conceivable patch — a native procedural "snow-layer pass" mirroring the fluid pass — was already priced and **rejected** in MULTI-MATERIAL §3b (~400-600 LOC in the mesher's hottest loops, ~2× the waterlogging patch) and this ADR's baked-composite path makes it unnecessary. Zero engine LOC; no rebuild beyond what's already deployed (`module_in_web=yes`).

**The model in one paragraph.** Every column (x,z) has a deterministic **snow surface** S(x,z) ≥ g+1·(has-snow) measured in tenths of a block above the solid top g. Between g and S, whole air cells become snow: full `snow_block` cubes below, one fractional **LAYER cell** (the new FAM shape family, Decision 1) at the top. Where S lands *inside* the smoothed terrain surface cell (the ramp at y=g), the ramp carries a **snow-fill STATE nibble** and renders as a baked 2-surface **composite** (Decision 2). Worldgen seeds S from climate (Decision 3: a thin blanket + a fill toward a smoothed local plane, which is what makes low spots converge flat); the snowfall sim (Decision 4) raises/lowers S near the player in bounded steps, persisting every change through `_edits` so leaving freezes the state and returning restores it.

---

## Decision 1 — The snow height lives on the MODIFIER axis: FAM family "LAYER" (uniform thin layer, level in tenths)

**1.1 The choice, and why the alternatives lose.** Four candidate encodings were weighed:

* **(chosen) FAM shape family** — `MOD_FAM_BIT` (bit 15 of the modifier field) is the *designed* extension point (`cell_codec.gd:29`; canonicalization already passes FAM modifiers through, `cell_codec.gd:166-167`; MULTI-MATERIAL §3c priced this exact build). Decisive properties: (a) the modifier axis is the **one axis physics reads** — `_occ_span` composes `solidity(mat) × ShapeCodec.span(modifier)` (`world_manager.gd:165-168`), so a LAYER cell is automatically walkable (`floor_under` `:797-817`), blocking (`blocked` `:836-847`), aimable (`_ray_vs_partial` `:957-978`), collidable (`GroundCollider._add_prisms` ← `surface_tris`, `ground_collider.gd:506-529`) and **massive** (`mass_of_value = mass × ShapeCodec.volume(modifier)`, `block_catalog.gd:419-424`) the moment ShapeCodec's queries branch on the family — zero physics call sites change; (b) the modifier is **persisted** by ZoneChunk's sparse `_modifier` layer (`zone_chunk.gd:99-103, 161-163`) and round-trips `load_edits` (`world_manager.gd:607`) — accumulated snow survives save/stream with no format change.
* **A liquid-level-style overlay** — rejected. The LIQUID axis is *contractually* physics-invisible ("no physics function reads it", `cell_codec.gd:19-21`) and is **not persisted** (`load_edits` packs only (id, modifier, state), `world_manager.gd:607`; `_structural_update` strips it at the capture boundary `:745-751`). Snow must be walkable and must persist — both violate the axis's core invariants. Also an in-cell overlay cannot grow past 1.0; a stacked-cell representation is needed anyway.
* **Reserved bits 54-62** — rejected. 9 bits would fit a level, but they are not persisted by ZoneChunk (new sparse layer + bundle format churn), invisible to physics unless every query is taught a *parallel* notion of solid height — exactly what rule 1 of the engine forbids — and they are the last reserved bits, spent on one feature.
* **STATE-encoded depth as the primary store** — rejected for the *stacked* snow (state bits are per-material behavioural variants validated against `state_layout`; physics never reads them). It **is** the right home for the *composite fill* descriptor, per MULTI-MATERIAL §3a failure-mode 3 ("the encoding IS a state variant") — see Decision 2.

**LOCKED: a stacked snow cell is a real cell — material `snow_block` (LRID 42, mass 280 kg, `blocks.json:1406-1437`), modifier = FAM LAYER with level in tenths.** This is MULTI-MATERIAL §3c built, specialized to snow and to tenths.

**1.2 Bit layout and granularity (locked).** Modifier field (16 bits, `cell_codec.gd:24-29`):

```
bit 15         bits 14..12      bits 11..4        bits 3..0
MOD_FAM_BIT    FAM_KIND (=0)    reserved (=0)     LAYER level, tenths
```

* `const FAM_LAYER := 0` — family-kind 0 within the FAM space is LAYER; bits 14..12 are a family selector so a future thin family (ash, sediment, frost — §3c's promise) does not collide. Bits 11..4 must be 0 for LAYER (canonical strips otherwise → full-cube fallback + warn).
* **Granularity: tenths, levels 1..10** — mirrors the liquid axis (`LIQ_LEVEL_*`, tenths, `cell_codec.gd:31-42`) so the codec has ONE "level" idiom; 0.1-block steps are visually continuous and give the sim a natural growth quantum. 4 bits, budget-free.
* New codec constants/helpers (in `cell_codec.gd`, beside `MOD_FAM_BIT`):

```
const MOD_LAYER_LEVEL_MASK := 0xF
static func make_layer(level: int) -> int        # canonical LAYER modifier for level (see 1.3)
static func is_layer(m: int) -> bool             # (m & MOD_FAM_BIT) != 0 and ((m >> 4) & 0x7FF) == 0
static func layer_level(m: int) -> int           # m & 0xF
```

**1.3 Canonicalization (locked — the uniqueness discipline of `cell_codec.gd:148-150`, "each geometric shape maps to a UNIQUE modifier int").** In `_canonical_modifier`'s FAM branch (replacing today's raw pass-through at `:166-167`):

1. non-LAYER FAM kind or nonzero reserved bits → **0** (full cube) + `push_warning` (the "ramp of water" style, `:159-162`).
2. level 0 → the **empty shape**: extend the empty-shape collapse in `canonical()` (`:141-142`) so a FAM LAYER with level 0 also zeroes the cell to AIR (§3c rule "thickness 0 → air").
3. level > 10 → clamp to 10.
4. **level 10 → modifier 0** (the full cube — no dual encoding of a full cell, mirroring liquid rule 5's "bare id IS canonical full water", `cell_codec.gd:216-217`).
5. **level 5 → `SNOW_SLAB_MODIFIER` (85)** — the 0.5 uniform layer is geometrically identical to the all-corners-1 BOTTOM slab (`make_modifier(1,1,1,1,ANCHOR_BOTTOM) == 85`, verify-pinned in M1 §8.1), which is already baked, collider-proven and verify-pinned. Canonicalizing the mid-level onto it preserves shape-uniqueness *and* reuses the whole existing 85 machinery. The `SNOW_SLAB_MODIFIER` constant therefore **survives** — repurposed from "the fixed slab worldgen emits" to "the canonical encoding of LAYER level 5".
6. The non-solid-material gate (`:159-162`) applies unchanged — no "layer of water".

**Canonical LAYER levels are therefore exactly {1,2,3,4,6,7,8,9}** — 8 new modifier values. `make_layer(level)` returns the canonical encoding (85 for 5, 0 for 10) so growth/melt code thinks purely in tenths.

**1.4 ShapeCodec query set — every public query branches on `is_layer` FIRST, with these closed forms** (h := level/10.0; all LAYER shapes are BOTTOM-anchored; there is no TOP layer in v1):

| query (`shape_codec.gd`) | LAYER closed form |
|---|---|
| `anchor` (:77) | `ANCHOR_BOTTOM` (0) |
| `is_full` (:81) | unchanged (m==0 only) |
| `corners` (:71) | **defensive quantization**: `Vector4i.ONE * clampi(roundi(h*2),0,2)` — any consumer missed by the sweep degrades to the nearest half-block shape, never nonsense |
| `bottom_face_covers` (:92) | `true` (uniform bottom layer tiles the floor — feeds the fallback z-fight suppression, `chunk_mesher.gd:80-87`) |
| `volume` (:110) | `h` (⇒ `mass_of_value(pack(snow, make_layer(2))) == 56.0` kg — pinned) |
| `height_at` (:160) | `h` (constant over the footprint) |
| `local_top` (:169) | `h` |
| `span` (:180) | `Vector2(0.0, h)` |
| `occupied` (:193) | `fy <= h + _EPS` (and `fy >= -_EPS`) |
| `side_profile` (:207) | lateral faces: return the sentinel `Vector3i(0, -2, -2)` ("non-corner profile"); no current consumer needs it for LAYER — `contact_area` bypasses (below) and `side_profile_full` is direct |
| `side_profile_full` (:226) | lateral faces: `false` (a 0<h<1 band never covers); `FACE_PY`: `false`; `FACE_NY`: `true` (bottom-anchored, per the existing convention at `:247-252`) |
| `contact_area` (:263) | lateral axes: **bypass the 18-entry LUT** (it assumes half-quantized profiles, `:47-63`) and call the existing float integrals directly — LAYER's edge pair is the constant (h,h): same-anchor `_integral_min(a0,a1,h,h)` (`:307`), opposite-anchor `_integral_pos(a0+h-1, a1+h-1)` (`:319`). AXIS_Y: LAYER top region = `_REG_EMPTY` (h<1 never reaches y=1 — consistent with partial BOTTOM corner shapes, `:347-352`); LAYER bottom region = `_REG_FULL` |
| `surface_tris` (:411) | the two triangles of the flat quad at y=h (diagonal irrelevant), normal UP — this **automatically** powers the DDA in-cell test (`world_manager.gd:957-978`) and the collider prisms (`ground_collider.gd:506-529`, where the two extruded prisms are exactly a box) |

`ShapeMesh.build` (`shape_mesh.gd:21-69`) gains a LAYER branch that runs the existing builder with the four corner heights all = h (the builder already works in float heights; §3c: "a thin-slab builder — trivial next to the ramp builder"). Mesh cache key on the module path: the raw FAM modifier (`_shape_mesh_cache[make_layer(level)]`) — bit 15 set keeps it disjoint from all corner keys and from `_WET_MESH_FLAG` (1<<20, `module_world.gd:92`).

**1.5 The `_GEN_STRIDE` manifest re-keying (the snag MULTI-MATERIAL §3c flagged) — resolved by NOT re-keying.** The frozen tables key `mat*_GEN_STRIDE + modifier` with `_GEN_STRIDE := 256` (`module_world.gd:50`); a FAM modifier is ≥ 0x8000 and cannot slot. Re-keying the stride to 65536 would balloon every table (75 mats × 65536 × 4 B ≈ 19.6 MB *per table*). **LOCKED: dedicated tiny frozen tables keyed by LEVEL** — the exact discipline M1 §5.1 chose for `_snow_arid` ("a PARALLEL per-state frozen table, NOT a re-keyed stride"):

```
var _layer_arid := PackedInt32Array()    # size 11, index = level (1..4, 6..9); -1 elsewhere
```

baked at setup for **snow_block only** (the curated LAYER material of this milestone), 8 models / 8 meshes, published to the worker generator like `snow_arid` (`module_world.gd:1215-1220`). The worker branch keys on bit 15 *before* the existing `modifier < GEN_STRIDE` guards; note those guards already make the safety default correct today — an unhandled FAM modifier falls through every `modifier < GEN_STRIDE` test to `cube_arid[id]` (`module_world.gd:1197-1204`), i.e. a too-tall full snow cube: wrong height, right substance, **never a hole**. `arid_for_cell` (`:294-333`), `gen_arid_for` (`:646-685`), `arid_for` (`:341` — placed layers reuse `_layer_arid`), and `is_manifest_baked` (`:689-693`) all gain the same level-table branch.

**1.6 Serialization/GMID discipline.** The level is per-cell modifier data — ZoneChunk already stores it sparsely (omit-when-zero, `zone_chunk.gd:99-103`), so **every non-snow cell stays byte-identical** and **no material document changes for Decision 1 ⇒ zero GMID churn from the LAYER family itself** (Decision 2 causes some — see 2.7). Break semantics: `break_terrain` on a LAYER cell removes the **whole cell** (one call, one `_write_cell(cell,0)`, `world_manager.gd:315-326`), yielding `snow_block` with `mass_of_value` = 280·h — no partial digging in v1 (melt is the sim's job, digging is the player's).

---

## Decision 2 — Snow-fills-a-partial-terrain-cell: a STATE fill nibble + curated baked 2-surface composites (§3a specialized)

**2.1 When the case arises.** Worldgen smoothing makes nearly every surface cell a corner-height ramp (`_smoothed_surface`, `terrain_config.gd:713-726`), so the flat-white look *requires* the in-cell fill: while g < S < g+1 the snow plane sits inside the ramp cell — snow fills where the ramp's H(fx,fz) < s, terrain pokes through where H ≥ s. Once S ≥ g+1 the ramp cell is **buried** (remainder filled to the ceiling) and everything above is pure LAYER/cube cells (Decision 1).

**2.2 Encoding (locked): STATE bits 1-4 = the SNOW_FILL level nibble, tenths.** MULTI-MATERIAL §3a locked that a composite's identity convention "will sit on the STATE axis regardless"; this is that convention made concrete. In `cell_codec.gd`:

```
const STATE_SNOW_FILL_SHIFT := 1                 # bits 1..4 of STATE (bits 33..36 packed)
const STATE_SNOW_FILL_MASK := 0xF << STATE_SNOW_FILL_SHIFT
static func snow_fill(v: int) -> int             # (state(v) >> 33) & 0xF — level in tenths, 0 = none
static func with_snow_fill(v: int, level: int) -> int
```

`blocks.json` `state_layout` on the fill-capable set — **grass, podzol, sand, stone, snow_block** (the M1 cappable set + snow_block, whose own B_SNOWY ramps also fill) — becomes `["snow_capped","snow_fill_b0","snow_fill_b1","snow_fill_b2","snow_fill_b3"]`: four positional bit NAMES carrying binary weights, staying honest with M1 §1.2's "the name at index i names bit i" (no layout-format change). `snow_capped` stays pinned at index 0 (M1 verify pin intact).

**2.3 Canonical rules — a `_canonical_snow_fill(material, canonical_mod, state)` hook called from `canonical()`, mirroring `_canonical_liquid` (`cell_codec.gd:198-234`) rule-for-rule:**

1. fill 0 encoded → 0 (absent).
2. fill > 10 → clamp 10.
3. fill on a **non-solid** material → strip + warn (no "snow-filled water").
4. fill on **modifier 0** (full cube — no remainder) → strip (liquid rule 6's twin, `:221-224`).
5. fill on a **LAYER** modifier → strip (snow-on-snow is just a higher level; Decision 4 owns that).
6. fill ≤ the terrain minimum → strip: `level <= 5 * min(c00,c10,c11,c01)` (corner half-units are 5 tenths each) — a plane below the ramp everywhere adds nothing; stripping keeps value-equality honest.
7. Coexistence with liquid: never stamped together (worldgen disjointness, the M1 §1.6 pattern — snow fill requires `liquid_field == 0`); the codec does not forbid it; render prefers liquid (the M1 §5.2 defensive order).
8. Undeclared-material bits are already masked by `_validate_state` (`cell_codec.gd:186-189`) — fill on dirt silently drops.

**2.4 Physics — the combined walkable surface (locked): one change, in THE one helper.** `WorldManager._occ_span` (`world_manager.gd:165-168`) becomes:

```
func _occ_span(v: int, fx: float, fz: float) -> Vector2:
    if BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5: return Vector2.ZERO
    var sp := ShapeCodec.span(CellCodec.modifier(v), fx, fz)
    var fill := CellCodec.snow_fill(v)
    if fill != 0:
        sp = Vector2(0.0, maxf(sp.y, float(fill) / 10.0))   # snow fills the remainder up to the plane
    return sp
```

Because `floor_under`, `blocked`, `_headroom_clear`, `ceiling_scan` and the collider's analytic contract all compose against this ONE helper, the player stands on `max(H_terrain, s)` **everywhere, by construction** — the exact "combined walkable surface height" requirement. Rising snow auto-steps (0.1 ≤ STEP_MAX 0.55, `:823`). Two accepted, documented degrades (both listed in verify + risks): (a) `aimed_voxel`'s in-cell refinement (`_ray_vs_partial`) tests the *terrain* shape's occupancy/tris — a ray into the snow part reports a hit point slightly deep (the cell targeted is correct; extendable later by also testing the flat plane at s); (b) `GroundCollider._add_prisms` builds from the terrain modifier only — loose *bodies* sink into the fill by ≤ s (thematically "soft snow"; the player never uses the collider).

**2.5 Break semantics (locked): snow first, terrain second.** `break_terrain` on a cell with `snow_fill > 0` clears the fill nibble (and the `snow_capped` bit) via `set_state`-style rewrite through `_write_cell` — terrain re-exposed, returns `snow_block` id; the *next* break takes the terrain. Yield mass: `280 · ShapeCodec.fill_volume(mod, level)` where `fill_volume` is a new closed form — the positive part of the plane-minus-ramp integral, per max-sum triangle (the `_integral_pos` machinery generalized to 2D; verify pins it against a Monte Carlo sample; precision is cosmetic, correctness of sign/monotonicity is pinned). At the VoxelBody capture boundary, `_structural_update` **strips the fill** exactly as it strips liquid (`world_manager.gd:745-751`) — snow stays worldgen/sim-owned; a detaching filled ramp falls bare (the M1 §5.5 accepted class).

**2.6 Render — the WaterMesh trick kills the geometry problem.** The wet composite's water fill is deliberately **modifier-independent** — a simple slab whose portion inside the opaque ramp is invisible (`module_world.gd:836-871`, `_WET_MESH_FLAG`). Snow composites do the same: the combined ArrayMesh = **surface 0: the dry ramp (`ShapeMesh.build(mod)`) + surface 1: the LAYER mesh at the fill level** (shared with Decision 1's builder). The part of the snow box inside the ramp hides inside opaque terrain; the ramp pokes above the plane where taller. No clipping math at all. Both `MAX_SURFACES=2` slots are spent (MULTI-MATERIAL §1.5) — recorded consequence: a snow-filled model can never also take the deferred M1 v2 top/side texture split (already deferred) — and waterlogging never competes (procedural, no slot; irrelevant anyway: fill and liquid are disjoint at stamping). Opaque+opaque honesty per §3a: side patterns rasterize the union — geometric truth. One epsilon: a ramp triangle with all three corners at height s (only possible at s=5 against corners=1) is coplanar with the snow plane → the LAYER surface in *composite* meshes is lifted by +0.001 (snow sits a hair proud; deterministic, invisible).

**2.7 Model/mesh budget (bounded, with the trim ladder).** Uncurated this explodes (mats × ~60 mods × 10 levels); **LOCKED curation**:

* **Baked composite levels: L ∈ {3, 5, 8, 10}.** The render maps the true tenth-level to the nearest baked level **rounding UP** (snow renders never lower than physics — feet slightly dusted, never floating). Physics always uses the true level.
* **Pair set: `TerrainConfig.emitted_cold_pairs()`** — a spatial sample (the `emitted_shore_pairs` pattern, `terrain_config.gd:1300-1355`) around a new `find_cold()` centre (first B_SNOWY column, the `find_coast` scan pattern) **plus** the existing `find_mountains(6)` centres (`:1226-1247`), collecting (surface-mat, surface/cap modifier) where `surface_temperature < 0`. Materials in practice: grass, podzol, sand, snow_block, stone.
* Meshes: one per (modifier, level) shared across materials via per-surface overrides — ≈ |cold mods ~40-60| × 4 ≈ **160-240 new ArrayMeshes/readbacks**; models ≈ |cold pairs| × 4 ≈ **600-1200** — comparable to 2-4× the waterlog twin set, well under the 65536 ceiling, but the **largest single bake-time line item in this ADR**. The existing setup timing print (`module_world.gd:159-160`) is the gate; the trim ladder, safe because of the fallback below, is: (1) levels {5,10} only; (2) drop stone composites (steep mountain faces read fine as the capped skin); (3) shrink the sample radius.
* **The fallback ladder (never a hole, and unusually good here):** unbaked composite slot → the **M1 snow-capped variant of the ramp** (`_snow_arid`, white skin, right colour, wrong micro-shape) → plain dry ramp → cube. The M1 skin being the composite's degrade is what makes every trim above cosmetically safe.
* New frozen tables: `_comp_arid_l3/_l5/_l8/_l10: PackedInt32Array` keyed `mat*_GEN_STRIDE + modifier` (corner modifiers < 256, so the stride is valid here), the twin-table discipline verbatim (`module_world.gd:89, 528-533`), published to the worker; worker branch keys on the state nibble `(v >> 33) & 0xF` in the `lf==0` arm, beside the existing snow-cap branch (`:1182-1196`).

**2.8 Fallback mesher (parity, trivial by design).** `chunk_mesher.gd` needs no baking: a cell with `snow_fill > 0` emits **both** geometry sets — `_emit_shaped(terrain look, terrain modifier)` + `_emit_shaped(snow_block look, make_layer(level))` (`:366-377` reused twice). LAYER cells above the surface need a new `_emit_snow` column pass (the `_emit_water` pattern, `:300-324`): for y in (h, S]: full snow cube → `_emit_cube`, top LAYER → `_emit_shaped`; extend the greedy-top "used"/capshaped marking (`:66-87, 117-124`) — `bottom_face_covers(LAYER)` = true already suppresses the z-fighting surface quad. Same (mat, state, modifier) projection on both paths.

---

## Decision 3 — The column snow surface S: definition, worldgen baseline, and how the sim's dynamic value composes

**3.1 S is defined in tenths above the solid top.** For column (x,z) with solid top g (`height_at`): `S = g + 1 + (D-10)/10` for total depth D tenths… concretely, **snow depth D(x,z) ∈ tenths**; cells: for `g < y ≤ g + D/10` rounded down in whole cells: full `snow_block` cubes; the fractional remainder `D mod 10` is the top LAYER cell; if D < 10 and the surface cell is a ramp, the first `min(D, 10)` tenths are the **fill nibble** on the ramp cell instead of a cell above (the fill consumes the remainder before stacking begins; a full-cube surface cell skips straight to a LAYER above — canonical rule 2.3.4).

**3.2 The baseline (static, pure SEED function — the feature has its look with the sim OFF).** Two composed terms, both keyed on the ONE temperature authority (`ClimateModel.surface_temperature`, `climate_model.gd:47-48` — the same zero crossing as the M1 cap/melt, so all three snow authorities agree at the boundary):

```
const SNOW_T0 := 0.0                 # depth begins strictly below freezing (matches the cap stamp, M1 §2.1)
const SNOW_BLANKET_PER_C := 0.4      # blanket tenths per °C below zero
const SNOW_BLANKET_MAX := 3          # blanket cap: a 0.3 dusting-to-crust
const SNOW_FILL_PER_C := 1.5         # fill-plane tenths per °C below zero
const SNOW_FILL_MAX_CELLS := 4       # fill never exceeds 4 blocks above g (deep-gully clamp)
const SNOW_REF_LATTICE := 8          # smoothed-terrain reference lattice pitch (blocks)
```

* **Blanket**: `D_blanket = clampi(roundi(SNOW_BLANKET_PER_C · max(0, -T_s)), 0, SNOW_BLANKET_MAX)` where `T_s = surface_temperature(g, t)` — a thin, terrain-following crust (this is what dusts peaks that poke through).
* **Fill (the flatness)**: a slowly-varying **snow plane** `P(x,z) = h_ref(x,z) + 1 + min(SNOW_FILL_PER_C·(-T_s), 10·SNOW_FILL_MAX_CELLS)/10`, where `h_ref` is terrain height **bilinearly interpolated over an `SNOW_REF_LATTICE` lattice of `height_at` samples** (deterministic, 4 lattice reads per column, memoizable in `pcache` exactly like the corner-target stencil, `terrain_config.gd:611-625`). Columns with g+1 below P fill up to P; columns above it poke through with just the blanket. **`S_baseline = max(g+1 + D_blanket/10, min(P, g+1 + SNOW_FILL_MAX_CELLS))` where T_s < 0, else no snow.** As T_s falls, P rises and the whole area converges to the flat white plane — the user's "rising level H", realized as a pure function.
* **Tree gate**: columns where `TreeGen.block_at(x, y, z) != AIR` for any affected y keep D = 0 above g (bare under canopy — the `_slab_fires` precedent, `terrain_config.gd:571-576`).
* **Sea gate**: `g >= SEA_LEVEL` (no snow fill on underwater floors — the `_with_snow_state` guard, `:549-559`).
* **Bound**: `S ≤ local h_ref max + 1 + SNOW_FILL_MAX_CELLS ≤ MAX_SURFACE_Y (116, `:134`) + margin` — the generator's cheap all-air early-out (`module_world.gd:1083`) gains `+ SNOW_FILL_MAX_CELLS` in its constant and verify re-proves the bound (a too-low bound punches holes — the loudest failure class).

**3.3 Where it plugs into `resolve_cell` (`terrain_config.gd:468-517`).** The `y > g` branch: after the smoothing-cap check and before the sea/tree returns, a new `_snow_stack(x, y, z, g, t, pcache)` resolves whether (x,y,z) is a snow cube / the top LAYER / air; the `y == g` surface return composes `_with_snow_fill(v, …)` **outside** `_with_shore_liquid` and beside `_with_snow_state` (`:511-516`) — one regime authority per axis, the established composition pattern. **The fixed half-slab rule is deleted**: `SNOW_SLAB_T` (`:58`) and `_slab_fires` (`:571`) are removed; every column that slabbed now carries D ≥ 5 by the constants above (-4 °C → blanket 2 + fill ≥ 6), so no regression to bare ground (verify-pinned). The `y == g+1` smoothing-lip branch keeps priority over snow at that cell — a lip cell *with* snow gets the fill nibble on the lip (it's a corner shape like the surface cell; same composite machinery).

**3.4 The collider cheap-query contract (retarget, don't weaken — M1 §6.3's discipline).** `surface_cap_modifier == CellCodec.modifier(generated_cell(x, g+1, z))` (machine-checked, cited at M1 §6.3 / `verify_feature.gd:952`) must keep holding. The `_shape_entry` memo (`terrain_config.gd:665-707`) repacks: the old single slab bit 32 (`:698-706`) is replaced by **bits 32..39 = the column's snow byte**: top-LAYER level (4 bits) + whole-snow-cell count above g (4 bits, capped by SNOW_FILL_MAX_CELLS) — pure SEED functions, so the memo stays byte-identical to recompute (same amendment M1 §6.3 already made for climate). `surface_cap_modifier` returns `make_layer(level)` / 0 / the raw lip modifier per the same precedence as `resolve_cell`; both the memo and the worker-direct (`pcache != null`) branches are implemented from ONE shared predicate so they cannot diverge (the `_slab_fires` single-predicate pattern). `GroundCollider._emit_column`'s above-heightmap loop (`ground_collider.gd:437-471`) gains a snow branch beside the sea/tree branches, driven by a new light query `TerrainConfig.snow_stack_at(x, z, pcache) -> int` (packed count+level; no `generated_cell` calls — the light-query family contract, `:762-816`).

**3.5 The dynamic value composes via `_edits`, full stop.** The sim writes **absolute resulting cells** through `_write_cell` → `_edits` (`world_manager.gd:378-391`), which is authoritative over generation (`cell_value_at`, `:134-138`) and persists (ZoneChunk). Re-streaming can never undo accumulation — the identical guarantee as break/place/melt (M1 §4.2). Byte-identity of the non-snow world: every new branch is gated `surface_temperature(g,t) < 0` — the M1 §2.4 pin extends verbatim (a wide temperate sweep stays byte-identical, including the state axis AND the new modifier family).

---

## Decision 4 — The snowfall simulation: `SnowfallSystem`, bounded, dormant-by-default, main-thread

**4.1 Shape of the system (locked).** A new `godot/src/sim/snowfall_system.gd` (`class_name SnowfallSystem`), a plain object owned and stepped by `WorldManager` from `_process` on the **main thread** (satisfying the M1 evaluator's MAIN-THREAD-ONLY contract, `world_manager.gd:457-459`, since all writes go through `_write_cell`). It is the M2 "disturbance/weather tick" M1 Decision 4 deferred — now with a real payload (levels), not just the skin bit.

**4.2 Region and cadence (the dormancy bounds).**

```
const STEP_SECONDS := 0.5          # fixed-timestep accumulator (frame-rate independent)
const SIM_RADIUS := 48             # columns (Chebyshev) around the player — the active region
const TILE := 16                   # one 16×16-column tile is visited per step
const MAX_COLUMN_UPDATES := 32     # per step, within the tile
const MAX_CELL_WRITES := 32        # hard per-step write cap
```

Per step, **exactly one tile** of the region is visited (deterministic rotation: `tile_index = step_counter % tile_count`, tiles enumerated around the player's current column). All of a step's writes therefore land in ≤ 4 godot_voxel data blocks → **≤ ~4 block remeshes per step** — the anti-remesh-storm mechanism, chosen over per-column random ticks precisely because scattered writes would queue a remesh per touched block on the web's single voxel thread. The region is (2·48+1)² ≈ 9.4k columns = 36 tiles → every column is revisited every ~18 s; at +1 tenth per snowing visit that is ≈ 0.1 block/18 s ≈ **20 blocks-per-hour maximum local growth** — visibly alive within a minute of standing in a storm, and every constant is a tunable in one block. **No global tick exists anywhere**: outside SIM_RADIUS nothing runs; when the player leaves, the accumulated `_edits` simply sit there (frozen state), and return restores them via the normal overlay — dormant-by-default is satisfied structurally, not by throttling.

**4.3 The per-step rule (per visited column).**

1. Compute `T_s = surface_temperature(g, t)` and the **weather gate** `is_snowing(x, z, step)` — a `FastNoiseLite` (seed SEED+105, a new salt in the registry `terrain_config.gd:157-175`) sampled at `(x·0.004, z·0.004, step_counter·WEATHER_SPEED)` thresholded at `WEATHER_THRESHOLD := 0.25`: deterministic *given the step counter*, spatially coherent storms hundreds of blocks wide.
2. **Accumulate**: snowing AND T_s < 0 AND the column's current dynamic depth `D_cur < D_storm_max = D_baseline + SNOW_STORM_EXTRA (:= 6 tenths)` → `D_cur += 1`, rewrite the (one) affected cell: bump the fill nibble, or the top LAYER's level, or birth the next LAYER cell above (all through `make_layer`/`with_snow_fill` canonical helpers → `_write_cell`). Skip if the affected cell is player-occupied, tree-occupied, or an overlay non-snow edit (never bury a player-placed block silently — snow stacks *on top of* placed cells instead, same rule as worldgen's tree gate).
3. **Melt**: T_s ≥ 0 (warm spell at a fringe, or future dynamic temperature) → `D_cur -= 1` toward 0, same write path; a melted-to-zero column's cells write to their bare generated form. (Puddle emission stays deferred to the MULTI-MATERIAL M2 item — the hook is one line here when it lands.)
4. **Piggyback the M1 evaluator**: call `apply_state_transitions` on the column's surface cell (`world_manager.gd:461-502`) — bounded (≤ MAX_COLUMN_UPDATES calls/step), main-thread, and its SET edge remains self-gated to the generated surface cell (`:482, 490-491`), so the contract is honoured, not reinterpreted. This finally gives the M1 melt/freeze machine its runtime tick without a new gating regime.
5. **Cost discipline of a write**: `_write_cell` + paint only. **No `_structural_update`** (snow adds mass on top; it detaches nothing — and deliberately does *not* wake dormant debris: a snow tick is not a "disturbance" in the memory-law sense, or a blizzard would keep every settled pile awake). **No per-write `rebuild_now`** — one `_ground.rebuild_now()` at step end, and only if a write happened; the collider's own debounce (`ground_collider.gd:90-91`) coalesces further, and its gate means it does zero work anyway unless a loose body is nearby.

**4.4 Persistence, determinism, and the worst failure modes — each bounded:**

* **Unbounded `_edits` growth (the roaming-blizzard leak).** Each touched column contributes ≤ (SNOW_FILL_MAX_CELLS+1) entries ≈ 50-90 B each. Bound 1: the sim never writes a cell whose new value equals its *generated* value (compare before write) — baseline-equal cells cost nothing. Bound 2: a hard budget `SNOW_EDIT_BUDGET := 200_000` snow-authored cells (a counter in SnowfallSystem); at the cap the sim stops *adding columns* (existing ones still evolve), logs loudly, and never touches player edits. 200k × ~90 B ≈ 18 MB worst case — acceptable on the desktop-web target; ZoneChunk saves compact it for real persistence.
* **Re-mesh churn / frame hitches.** Structurally bounded to ≤ 4 block remeshes and ≤ 32 cell writes per 0.5 s (4.2); verify pins the per-step write and touched-block counts; the M1 "bake()/edits must not thrash" note is satisfied because no snow write ever allocates a model (every ARID it can need is frozen at setup — Decisions 1.5/2.7).
* **Non-determinism.** Within a session everything is a pure function of (SEED, step_counter, player tile rotation). Across sessions the *weather phase* restarts (step_counter is not persisted — accepted and documented; the accumulated snow itself persists via `_edits`, which is the requirement). If cross-session weather continuity is ever wanted, persisting one int is the whole cost.
* **Module-path edit eviction** (M1 Risk 6): a re-generated data block briefly shows baseline snow while `_edits` holds deeper snow — pre-existing accepted class for all overlay edits; snow inherits it unchanged.

---

## Decision 5 — Both render paths, verify plan

**5.1 Parity statement.** Both paths key appearance off the same (mat, modifier-family, state, liquid) projection of one packed value: module = frozen tables (`_layer_arid`, `_comp_arid_l*`, existing `_gen/_snow/_twin`) consumed identically by `arid_for_cell`, `gen_arid_for`, the worker generator, and `bulk_inject` (`module_world.gd:259-262` already routes packed values); fallback = `_look_of`-style projection + direct dual-geometry emission (2.8). Physics is path-agnostic by construction (nothing reads geometry — rule 2).

**5.2 Verify plan (`verify_feature.gd`, new `_test_snow_accumulation()` + retargets):**

1. **Codec/shape round-trip**: `make_layer` canonical set {1..4,6..9}; `canonical(pack(snow, make_layer(5))) == pack(snow, 85)`; level 10 → modifier 0; level 0 → 0 (AIR); FAM junk bits → full cube + warn; `volume(make_layer(3)) == 0.3`; `span/occupied/height_at/local_top/bottom_face_covers/side_profile_full/contact_area/surface_tris` LAYER pins incl. a LAYER↔ramp lateral `contact_area` against the direct integral; `mass_of_value(pack(snow, make_layer(2))) == 56.0`.
2. **Fill-nibble canonical rules** 2.3.1-2.3.8 each pinned; `snow_capped` still index 0 on every declaring material.
3. **Worldgen sweep** (loud-fail-on-not-found, the M1 §8.4 pattern): (a) a B_SNOWY flat column: LAYER/cube stack matching the closed-form S_baseline; the old (snow,85) slab columns now carry D ≥ 5 (retarget M1 items 4c/8 — expect the new stack, do not weaken); (b) a cold ramp column: fill nibble == the closed form, `canonical(v)==v`; (c) a valley column vs its ridge: valley S == min(P, cap), ridge blanket-only — flatness asserted as `|S_valley_world - S_neighbour_world| ≤ 1 tenth` across a sampled basin; (d) tree-gated column bare; (e) **wide temperate sweep byte-identical** (modifier family AND state axis both 0 — the non-snow world untouched); (f) `MAX_SURFACE_Y + SNOW_FILL_MAX_CELLS` bound re-proven by wide sample.
4. **Physics**: `floor_under` on a LAYER-2 cell == g+1+0.2; on a filled ramp == max(ramp top, fill) at several footprints; `blocked` auto-steps a +1-tenth growth; collider: `surface_cap_modifier == modifier(generated_cell(g+1))` over a snow region (the cheap-query contract test extended); prisms/box equivalence for a LAYER cell (drop a body on deep snow, settles at the layer top ± the documented sink); `break_terrain` yields snow first, terrain second; detached body has fill stripped.
5. **Both-path mirror** (module-guarded): frozen tables stable across resolves (`appearance_count` unchanged); `arid_for_cell(pack(snow, make_layer(3)))` == `gen_arid_for` mirror == the worker TYPE buffer over a snow region (extend `_test_both_paths` sampling into the cold band); unbaked composite → `_snow_arid` skin → plain (the ladder, never 0); fallback chunk over a snow column commits snow material surfaces and suppresses the z-fight quad.
6. **Sim**: a deterministic scripted run (fixed step count, fixed player column) — S grows only inside the visited tiles, per-step writes ≤ MAX_CELL_WRITES, touched data blocks ≤ 4, all deltas present in `_edits` and identical after a save/load round-trip (ZoneChunk); melt column decrements and re-equal-to-baseline writes are skipped; budget counter respected; two identical runs byte-identical.
7. **Retargets**: every M1 slab pin (M1 §8.8) retargeted to the new stack; `emitted_modifiers` no longer needs the 85 union for worldgen (but 85 stays baked — it's canonical level 5).

---

## Decision 6 — PHASING (ship value incrementally; review gates between phases)

| Phase | Contents | Game-side? | Rough cost | Demo payoff / review gate |
|---|---|---|---|---|
| **A1 — the LAYER family** | cell_codec FAM/LAYER + canonical rules 1.3; ShapeCodec branch set 1.4; ShapeMesh LAYER builder; `_layer_arid` + worker branch + fallback `_emit_shaped`; `mass_of_value` for free; verify item 1 | 100% | ~2-3 days | Place/break snow layers of any tenth by hand; stand on them; they persist. No worldgen change yet — zero regression risk. |
| **A2 — static baseline (the LOOK, sim off)** | Decision 3: `_snow_stack`/S_baseline in `resolve_cell`, slab rule deleted, memo repack + light query, collider snow branch, fallback `_emit_snow`, `find_cold`, verify 3-4 | 100% | ~3-4 days | **The flat-white world**: walk into B_SNOWY/taiga/mountains and see graded, terrain-filling snow instead of fixed slabs. This alone delivers most of the user's visual ask. |
| **B — composites** | Decision 2: fill nibble + canonical hook, `_occ_span` change, `emitted_cold_pairs`, `_comp_arid_l*` bake + worker/mirror branches, fallback dual-emit, break-snow-first, blocks.json layouts | 100% | ~3-5 days (bake-budget tuning included) | Ramped terrain reads as one continuous snow plane; dig through snow into the ramp beneath. Gate: setup-timing print within budget on the live web build. |
| **C — the snowfall sim** | Decision 4: SnowfallSystem, weather noise, tile rotation, write caps, budget, `_ground` step-end debounce, verify 6 | 100% | ~3-4 days | Stand in a storm and watch the ground rise 0.1 at a time; leave and return — it's exactly where you left it. |
| **D — melt & interactions** | warm-edge melt path live (already coded in C's rule 3 — this phase tunes + proves it), `apply_state_transitions` piggyback, optional snowfall particles (cosmetic GPUParticles on the same weather gate), puddle hook stub | 100% | ~1-2 days | Cross the snow line and watch the fringe breathe; the M1 state machine finally ticks at runtime. |

Each phase is independently shippable and `/steelman`-gated per standing policy; A1/A2 can land while B's bake budget is still being measured.

---

## Decision 7 — Risks / open issues

1. **Composite bake budget is the #1 line item** (2.7): 160-240 new mesh readbacks + 600-1200 models on web load. Bounded by curation {3,5,8,10} × cold-sampled pairs, measured by the existing setup timing print, and every trim is safe because the degrade ladder ends at the M1 snow skin, not a hole. If it still hurts, levels {5,10} halves it with modest visual cost.
2. **FAM span-math exactness** — the §3c named failure mode ("the player floats/sinks by the layer thickness"): every LAYER query ships with a closed form + verify pin *before* any consumer (Phase A1 is gate-kept by verify item 1); `corners()`'s defensive quantization catches any missed consumer gracefully.
3. **Memo/light-query drift** — the cheap-query contract (`surface_cap_modifier == modifier(generated_cell(g+1))`) is the easiest thing to silently break; both branches are implemented from one shared predicate and the contract test's area is extended into snow country (verify 4).
4. **`_edits` growth & remesh churn** — bounded by construction (4.4); the budget counter and per-step caps are verify-pinned numbers, not intentions.
5. **Structural solver ignores snow load** — a blizzard adding 140 kg/cell to a player bridge does not re-audit it until the next disturbance (deliberate: snow writes skip `_structural_update`). Accepted for this milestone; a future "audit on Nth tick" is one call site.
6. **GMID churn** (2.2): grass/podzol/sand/stone/snow_block documents change (extended `state_layout`) ⇒ new GMIDs; the accepted RMS §8 class (M1 §7.2) — old bundles degrade to placeholders losslessly. Dirt/water remain the byte-identical controls.
7. **Accepted degrades, documented**: DDA hit-point slightly deep inside fill; loose bodies sink ≤ s into fill (soft snow); detached bodies fall bare (fill/skin stripped); cross-session weather phase restart; deep gullies clamp at SNOW_FILL_MAX_CELLS (level semantics yield to bound on extreme relief); render level rounds up to the nearest baked composite.
8. **Scope guard**: no puddles (M2 hook only), no per-level digging, no TOP-anchored layers, no snow insulation in the temperature field, no second FAM family, no engine patch. Anything reaching for those re-opens this ADR.

**Nothing here turns weeks into months** provided the composite budget (risk 1) is measured at Phase B's gate rather than assumed — that is the one place a surprise lives, and the trim ladder is the pre-authorized response. If the *full* vision had to shrink, the minimal scope that still delivers the user's look is **A1+A2** (variable-height, terrain-filling static snow) with composites at levels {10} only (buried-or-bare ramps) — but the locked design above is achievable game-side in full.

---

## File-by-file touch list (implementation order)

| # | file | change |
|---|---|---|
| 1 | `godot/src/world/cell_codec.gd` | FAM_LAYER constants, `make_layer/is_layer/layer_level`, `_canonical_modifier` FAM branch (1.3), empty-shape collapse for level 0, `STATE_SNOW_FILL_*` + `snow_fill/with_snow_fill`, `_canonical_snow_fill` hook (2.3) |
| 2 | `godot/src/world/shape_codec.gd` | LAYER branch in every public query (table 1.4), `fill_volume(mod, level)` closed form, LUT bypass for LAYER contact |
| 3 | `godot/src/world/shape_mesh.gd` | LAYER builder branch (uniform-height reuse of the corner builder) |
| 4 | `godot/src/sim/block_catalog.gd` | (no change to `mass_of_value` — it composes `ShapeCodec.volume` already) parse extended `state_layout` entries |
| 5 | `godot/assets/blocks.json` | `state_layout` = `["snow_capped","snow_fill_b0..b3"]` on grass/podzol/sand/stone/snow_block |
| 6 | `godot/src/world/world_manager.gd` | `_occ_span` fill composition (2.4), break-snow-first in `break_terrain`, fill strip at VoxelBody capture, own + step `SnowfallSystem` |
| 7 | `godot/src/world/terrain_config.gd` | delete `SNOW_SLAB_T`/`_slab_fires`; SNOW_* constants (3.2), `h_ref` lattice + `_snow_stack` + `_with_snow_fill` composition in `resolve_cell`, memo repack (3.4), `snow_stack_at` light query, `surface_cap_modifier` retarget, `find_cold`, `emitted_cold_pairs`, salt 105 registered |
| 8 | `godot/src/world/voxel_module/module_world.gd` | `_layer_arid` + `_comp_arid_l{3,5,8,10}` bake/freeze/publish, branches in `arid_for_cell`/`gen_arid_for`/`arid_for`/`is_manifest_baked` + worker generator (bit-15 and fill-nibble arms), composite mesh cache keys |
| 9 | `godot/src/world/fallback/chunk_mesher.gd` | dual-emit for filled cells, `_emit_snow` pass, capshaped/used extension (LAYER `bottom_face_covers` already true) |
| 10 | `godot/src/physics/ground_collider.gd` | snow branch in `_emit_column`'s above-heightmap loop via `snow_stack_at` (prisms come free via `surface_tris`) |
| 11 | **NEW `godot/src/sim/snowfall_system.gd`** | Decision 4 in full (weather noise, tile rotation, caps, budget) |
| 12 | `godot/src/tools/verify_feature.gd` | `_test_snow_accumulation()` (5.2), M1 slab-pin retargets, `_test_both_paths`/collider-contract extensions |
| 13 | `docs/` | this ADR checked in as `docs/SNOW-ACCUMULATION.md`; DESIGN §1 amended (snow depth model); M1 doc annotated "Decision 6 superseded by SNOW-ACCUMULATION Decision 1.3.5" |

Conventional Commits, scope `voxiverse`, on `feat/voxiverse-snow-accumulation` off the current integration branch; `/steelman` before each phase's PR per standing policy.

---

*Key sources verified while writing: `cell_codec.gd:8-29,141-167,198-234`; `shape_codec.gd:27-104,110-199,207-304,411-432`; `terrain_config.gd:58-63,468-576,602-726,735-816,833-913,1226-1247`; `module_world.gd:50-61,89-106,294-369,426-524,646-693,836-871,1041-1220`; `chunk_mesher.gd:66-124,212-229,300-324,366-404`; `world_manager.gd:38,134-168,315-391,437-502,595-609,699-754,797-892,957-978`; `ground_collider.gd:402-529`; `per_voxel_environment.gd:86-139`; `climate_model.gd:24-55`; `zone_chunk.gd:96-167`; `block_catalog.gd:410-424`; `blocks.json:1406-1437`; `docs/M1-SNOWY-WORLD.md` (all decisions); `docs/MULTI-MATERIAL.md` §1, §2, §3a-d, §5, §6; project memory: dormant-by-default law.*
