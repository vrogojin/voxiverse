# M1 — Snowy World: locked build ADR

Status: **LOCKED, implementation-ready.** This is the consolidated architecture
decision record for the "snowy world" milestone (MULTI-MATERIAL.md §4), produced by
a design pass + a revision for the altitude/temperature requirements. It is the
single source of truth the implementer follows; decisions already locked by
`docs/MULTI-MATERIAL.md` §6 are cited, not relitigated.

**Scope decision (user, 2026-07-06):** ship the sub-zero **winter biomes** now
(days, game-side only, **no engine rebuild**). The unified altitude-cap predicate
ships but is **latent for temperate peaks** (this world maxes at y≈20 vs the y=96
freezing altitude — see Risk 1); making temperate peaks white is a **deferred
tall-mountains milestone**, not M1. Nothing here changes terrain height or streaming.

Every mechanism below is existing module API (`VoxelBlockyModelMesh`/`Cube` +
per-model material override, frozen sampled tables) — zero engine LOC.

---

## Decision 1 — State-bit layout, real `_validate_state`, `canonical()`

**1.1** `snow_capped` is **bit 0 of the STATE axis** (bit 32 of the packed cell). In
`cell_codec.gd`, beside the liquid constants:

```
const STATE_SNOW_CAPPED := 1                     # bit 0 of STATE (bits 32..47)
const STATE_BIT_BY_NAME := {&"snow_capped": STATE_SNOW_CAPPED}   # mirrors LIQ_KIND_BY_NAME
static func has_state(v: int, bit: int) -> bool  # (state(v) & bit) != 0
static func with_state(v: int, bits: int) -> int # replace STATE field, mat/mod/liquid intact
```

**1.2 State layouts are positional and per-material.** A material declares an ordered
`state_layout: Array[StringName]`; **the name at index i names bit i**; its state mask
is the low `state_layout.size()` bits. This is what the document format reserved
(`material_document.gd:37`, VDS §10.3). "snow_capped" **must** be index 0 on every
material that declares it (verify-pinned), so `CellCodec.STATE_SNOW_CAPPED` is a valid
global shorthand for worldgen/render.

**1.3 Declared materials.** `blocks.json` optional key `"state_layout": ["snow_capped"]`
on **grass (1), podzol (35), sand (39), stone (3)**. Threaded through the catalog on the
`liquid_kind` precedent: `VoxelMaterialDef` gains `@export var state_layout:
Array[StringName] = []`; `BlockCatalog` gains `static func state_mask_of(lrid: int) ->
int` (O(1), per-LRID `PackedInt32Array` filled at register), with two edge rules:
* **AIR / out-of-range → 0** (air never carries state).
* **UNRESOLVED placeholder LRIDs → `0xFFFF` (permissive)** — a placeholder has unknown
  layout; stripping would destroy bits loaded from a zone bundle before late
  resolution (RMS §8 losslessness). Permissive keeps the bits; render falls back to the
  plain look (no hole); the real mask governs after resolution.

**1.4 The real `_validate_state`** (replaces the stub):

```
static func _validate_state(material: int, state_bits: int) -> int:
    if state_bits == 0:
        return 0
    return state_bits & BlockCatalog.state_mask_of(material)
```

Undeclared bits silently masked to 0 (the "0 is absent" convention; not a warning).

**1.5 `canonical()`** already routes state through the hook — no structural change.
Pin in verify: `canonical(generated_cell(..)) == generated_cell(..)` on a capped column.
**Retarget** the verify sites that wrote arbitrary state ints under the pass-through
stub: `verify_feature.gd:3155-3160` (state 5), `:3336/3360` (state 5), `:3625/3663/3694`
(state 5), `:3896` (state 7) — give those *test-local* material docs a ≥3-entry
`state_layout` so 5/7 stay legal (retarget the sweeps, don't weaken). `:1620-1630` uses
raw `pack()` (no canonical) → untouched.

**1.6 State–liquid coexistence** is disjoint at the *stamping* level (Decision 2): a
generated cell never carries both `snow_capped` and a liquid field. The codec does not
forbid the combination; render simply prefers the liquid twin (Decision 5.3).

---

## Decision 2 — Cap predicate, cappable set, stamping site  *(REVISED)*

**2.1 The cap predicate is the surface temperature, not a climate threshold.**
`SNOW_CAP_T` does **not** exist. A surface cell is `snow_capped` **iff its own
`ClimateModel` surface temperature < 0 °C** (climate offset + absolute-altitude lapse,
Decision 3). Cap predicate and melt predicate (Decision 4) are then the **same zero
crossing on the same field**: worldgen stamps where `surface_temperature(g, t) < 0`; the
transition melts where `temperature(surface) ≥ 0`. They agree at the boundary (stamp
strict `< 0`, melt `>= 0`).

**2.2 Cappable set (declared):** grass, podzol, sand, **stone**. **Baked render
variants:** grass, podzol, sand only. Honest rationale for stone: worldgen has **no
stone-topped surface cells** (`_biome_top` never returns stone; high forest/plains peaks
are grass-topped). So `stone` is declared *capable* (codec/state machine accept a stone
cap; a future "bare rock peak" is then data-only) but **inert and unbaked** in M1 — no
worldgen path stamps it, no variant model. `red_sand`/`mud`/`gravel` are excluded (they
top only hot or underwater columns, never `surface_temperature < 0`).
`TerrainConfig.snow_cappable_materials()` returns `{grass, podzol, sand}` (baked set) for
the render manifest; the *stamp* gate uses `BlockCatalog.state_mask_of(mat) &
STATE_SNOW_CAPPED` (catalog declaration is the one authority) so stone is
accepted-but-never-produced without a second list.

**2.3 Stamping site — one regime authority (the `_with_shore_liquid` pattern), keyed on
temperature.**

```
static func _with_snow_state(v: int, g: int, t: float) -> int:
    if g < SEA_LEVEL:                     return v          # underwater column: no land cap
    if CellCodec.liquid_field(v) != 0:    return v          # wet shore composite (1.6 disjointness)
    var mat := CellCodec.mat(v)
    if BlockCatalog.state_mask_of(mat) & CellCodec.STATE_SNOW_CAPPED == 0: return v
    if ClimateModel.surface_temperature(g, t) >= 0.0:       return v   # warm surface: bare
    return CellCodec.with_state(v, CellCodec.STATE_SNOW_CAPPED)
```

Applied at the two surface-appearance return sites in `resolve_cell` — the surface cell
(`:432-433`) and the smoothing cap cell (`:414-416`) — each composed **outside**
`_with_shore_liquid`. `ClimateModel` is a pure, dependency-free sink → no
`TerrainConfig ↔ PerVoxelEnvironment` cycle. `surface_temperature(g, t)` uses only
scalars already in `resolve_cell` → **no extra noise sampling** in the hot path.

**2.4 Byte-identity (state axis).** Any column with `surface_temperature(g, t) >= 0`
returns `v` unchanged. At reachable heights (g ≤ ~20) that is every temperate column and
all but the coldest taiga fringe — so temperate spawn areas stay state-0 (pinned).
Temperature *values* are no longer byte-identical for elevated temperate columns
(Decision 3) — `_test_temperature` is retargeted, not preserved.

---

## Decision 3 — Absolute-altitude temperature model (0 °C at y=96) + climate offset  *(REVISED)*

**3.1 New pure `ClimateModel` (sim layer), the one authority for the surface/air curve.**
Both `PerVoxelEnvironment` (the query interface) and `TerrainConfig` (the cap predicate)
call it. Dependency-free sink → keeps `PerVoxelEnvironment` as THE temperature query
(rule 2) while avoiding a const-cycle.

```
class_name ClimateModel extends RefCounted
const T_SEA_LEVEL   := 21.5           # temperate surface temp at sea level (y = 0)
const ALT_ZERO_Y    := 96             # temperate air/surface reaches 0 °C here (was 256)
const LAPSE_RATE    := T_SEA_LEVEL / float(ALT_ZERO_Y)   # 21.5/96 ≈ 0.22396 °C/block
const CLIMATE_TEMPERATE := -0.15      # t at/above this → no climate offset
const CLIMATE_FROZEN    := -0.55      # t below this → full winter offset (−8 at sea level)
const T_FROZEN_SEA      := -8.0       # winter sea-level surface temp (== the frozen-sea pin)

static func climate_base(t: float) -> float:     # sea-level surface temp for climate t
    if t >= CLIMATE_TEMPERATE: return T_SEA_LEVEL
    if t <  CLIMATE_FROZEN:    return T_FROZEN_SEA
    return lerpf(T_FROZEN_SEA, T_SEA_LEVEL, (t - CLIMATE_FROZEN) / (CLIMATE_TEMPERATE - CLIMATE_FROZEN))

static func surface_temperature(surface_y: int, t: float) -> float:   # climate + absolute altitude
    return climate_base(t) - LAPSE_RATE * float(surface_y)

static func air_temperature(y: float, t: float) -> float:             # absolute-altitude lapse, keeps dropping
    return climate_base(t) - LAPSE_RATE * float(y)
```

`PerVoxelEnvironment.CLIMATE_FROZEN` / `T_FROZEN_SEA` become aliases of ClimateModel's;
`T_AIR`/`T_SURFACE`/`ALT_ZERO_Y` on PerVoxelEnvironment are removed in favour of these.

**3.2 The lapse.** Absolute altitude, 21.5 °C at **y=0**, 0 °C at **y=96**, negative above
(no clamp): `air = 21.5 − 0.22396·y`. Same line for air and the surface anchor, so
surface↔air is exact and monotone. The old per-column re-anchoring to 21.5 at every
surface is **removed** — that is what made altitude irrelevant.

**3.3 `temperature(pos)` rework** (`per_voxel_environment.gd:107-123`), order + pins:
1. **Frozen-ocean branch first and verbatim** (`:111-116`): unchanged, returns
   `T_FROZEN_SEA` for a frozen-ocean air/ice voxel at `y ≤ SEA_LEVEL`. Now *consistent
   with* (not an exception to) the general model, but stays explicit (pinned structural
   dependency; clamps the ice zone to exactly −8).
2. **Air (`y > surface`)**: `return ClimateModel.air_temperature(float(c.y),
   column_profile(c.x,c.z).w)`. Monotone-decreasing forever (0 at y=96, negative above).
3. **Ground (`y ≤ surface`)**: cool from the surface anchor toward the 3 °C plateau at
   1 °C/block, *signed* (permafrost warms downward), plus geothermal excess:
   ```
   var ts := ClimateModel.surface_temperature(surface, column_profile(c.x,c.z).w)
   var d  := surface - c.y
   var toward := maxf(ts - d, COOL_FLOOR) if ts >= COOL_FLOOR else minf(ts + d, COOL_FLOOR)
   var geo := GEO_RATE * maxf(0.0, float(_GEO_REF_Y - c.y))
   return toward + geo
   ```

**3.4 Retargeted `_test_temperature` pins.** For a temperate `_grass_column`
(`climate_base = 21.5`) at height g: surface = `21.5 − 0.224·g` (plains g=5 → **20.38**);
air(g+1) just under; d=1 → `(21.5−0.224·g) − 1`; deep plateau (d>18.5) → **3.0**;
geothermal y=−40→3, y=−52→15, y=−64→27 (**unchanged** — deep ground forgets the anchor);
air(96)→**0**, air(256)→**−35.8** (old "clamp 0 above 256" is retired); frozen-sea
surface → **−8** (`< −5` pin intact).

**3.5 Seams.** surface↔air exact; cold↔temperate land C0-linear in t over `[−0.55,−0.15]`
(t is 0.002-freq noise → snow line unrolls over hundreds of blocks); land↔frozen-sea
continuous (beach at t=−0.56,g=0 reads −8, adjacent ice −8; the old ~28 °C step above the
sheet is gone); depth/geo unchanged (cold columns join the plateau from below).

**3.6 HUD readings (intended):** sea-level temperate → **21.5**; temperate y=96 peak →
**0** *(hypothetical/unreachable, Risk 1)*; low frozen biome (g≈2, t≈−0.6) → **≈ −8.4**
(capped); frozen peak (g≈18, t≈−0.7) → **≈ −12** (capped, colder by altitude). Low
temperate ground is firmly warm — **not** accidentally sub-zero. Amend DESIGN §1 (21.5 =
temperate **sea-level** baseline) + rewrite the `per_voxel_environment.gd` header.

**3.7 Structural safety.** On T ∈ [−12, 0] every class present reads φ ≥ 1 (soil rises to
~3, timber ≤1.05, foliage/soft ≤1.2, rock/metal 1.0, brittle sound below −5) — no class
weaker than today ⇒ zero new detachments; frozen-sea brittle seam untouched.

**3.8 Multiple winter biomes — keep `_biome` as-is.** `climate_base` gives temperate
offset 0, B_SNOWY (t<−0.55) → −8 at sea level, B_TAIGA ramping between. Two distinct
sub-zero land regions + altitude modulation: (a) B_SNOWY — snow-topped, fully capped,
slabbed; (b) cold fringe of B_TAIGA — grass/podzol-topped, capped where surface temp < 0
(sea-level cap boundary at t ≈ **−0.44**, migrating warmer-t with elevation). **No
`_biome` change** (the minimal answer).

---

## Decision 4 — Melt evaluation: defer the runtime tick to M2; ship evaluator + data + verify proof

**4.1** Because the cap and melt predicates share one zero crossing and the field is
static in M1, **the generated world is already the fixed point of the transition** — a
periodic tick would never fire in M1, adding re-mesh churn for zero payoff. Tick → M2
(where temperature first becomes dynamic; puddles are the melt product per
MULTI-MATERIAL §4).

**4.2 What ships in M1 (so the machine is genuinely live):**
* **Data**: the two transition edges authored on the cappable materials (Decision 7.3).
* **The evaluator** in `world_manager.gd`:
  ```
  func apply_state_transitions(cell: Vector3i) -> bool
  # read v; air/no-def → false. sample = environment.sample(cell centre).
  # first triggered transition of the material's default VoxelState wins:
  #   to_state in def.state_layout → new_bits = state | (1 << index)
  #   to_state == default state's name → new_bits = state & ~mask(all layout bits)
  # changed → set_state(cell, new_bits) → _write_cell → _edits (overlay-persisted, re-mesh); true
  ```
  `VoxelMaterialDef.resolve_state` is **untouched** (unifying the two machines waits for a
  second machine — deferred framework).
* **Persistence**: a fired melt writes through `_edits`, authoritative over generation —
  worldgen re-streaming can never un-melt a cell (same guarantee as break/place).
* **Verify-level end-to-end proof** (Decision 8 item 7).

**4.3 Visible payoff without a tick:** caps appear/disappear *spatially* across the
gradient; warm edge bare; slabs dig. **No periodic tick, no disturbance hook in M1.**

---

## Decision 5 — Render manifest keying for the state axis, both paths

**5.1** A **parallel per-state frozen table `_snow_arid`** (the liquid-twin discipline),
*not* a re-keyed `_gen_arid` stride: frozen at setup before the worker wires,
sampled/dense, dry/plain fallback, never a hole.

**5.2 Module path (`module_world.gd`).**
* `var _snow_arid: PackedInt32Array` — sized `total * _GEN_STRIDE`, filled −1, populated
  in `_build_gen_manifest` after the dry loop, frozen before `_make_generator`.
* Contents: for each `mat` in `snow_cappable_materials()` (grass/podzol/sand): slot
  `mat*_GEN_STRIDE + 0` → a snow-variant **cube** (`_add_cube` with the variant material —
  procedural, no readback); for each `modifier` in `emitted_modifiers()`:
  `_make_shape_model(modifier, variant_material)` **reuses `_shape_mesh_cache[modifier]`**
  ⇒ **zero new ArrayMeshes, zero GPU readbacks**. Anti-drift asserts identical to the dry
  loop.
* Size: 3 mats × (1 + |emitted|≈40–60 + slab) ≈ **125–190 models** (below the 280–420
  budget; the curated cappable set is 3). Model ceiling 65536 untouched.
* **`arid_for_cell`** (`:284-314`): after the liquid branch (liquid wins if both ever
  coexist — defensive), before the final dry resolve:
  ```
  if CellCodec.state(packed) & CellCodec.STATE_SNOW_CAPPED and liquid_field == 0:
      slot = mat * _GEN_STRIDE + modifier
      if modifier < _GEN_STRIDE and slot < _snow_arid.size() and _snow_arid[slot] >= 0:
          return _snow_arid[slot]
      # else fall through: plain look — a bare cap, never a hole
  ```
* **Worker generator**: publish `snow_arid` like the twin tables; per-cell in the `lf==0`
  arm: `var sb = (v >> 32) & 0xFFFF`; if `sb & 1`, try `snow_arid[slot]`, else the existing
  modifier/cube chain. One masked shift on the hot path, branch taken only for stated cells.
* **`gen_arid_for`**: gains a trailing `state := 0` param (existing callers unchanged) —
  the main-thread mirror verify diffs against the worker.
* **`bulk_inject` fix**: it currently resolves `arid_for(mat, modifier)`, dropping state
  (and liquid) — switch to `arid_for_cell(packed)` so a bundle-loaded capped cell renders
  capped.

**5.3 Variant material — one authority.** `BlockMaterials.snow_capped_for(base_id) ->
StandardMaterial3D`, cached: the **snow_block texture** through the standard `_textured`
recipe with `albedo_color = lerp(Color.WHITE, BlockCatalog.color_of(base_id), 0.18)` — a
whole-cell reskin toward snow with a subtle base hue (§3d v1 tier). **Zero new texture
assets.** v2 (top/side split) stays deferred (MAX_SURFACES contention).

**5.4 Fallback path (`chunk_mesher.gd`) — same (mat, state, modifier) projection.** A
render **look key** `mat | 0x10000` for a cell whose value has the snow bit (and nonzero
`state_mask_of`): used as (a) greedy-top merge key (capped/bare tops must not merge), (b)
the SurfaceTool key, (c) the sides-segment key + `_emit_terrain_shapes` tool id. At
commit: flagged key → `snow_capped_for(mat)`, else `get_for(mat)`. AIR/solidity/physics
logic keeps reading the *material* projection — the look key is render-local.

**5.5 Accepted degrades (documented, verify-visible):** a detached `VoxelBody` renders by
material — a chopped capped cell falls as bare grass; an unbaked (mat, modifier) state
slot renders the plain look. Both "wrong skin, correct substance, never a hole".

---

## Decision 6 — Half-slab snow (fires on deep-frozen flats: climate or altitude)  *(REVISED)*

**6.1 The cell.** `SNOW_SLAB_MODIFIER := 85` (all-corners-1 BOTTOM slab; verify-pinned
`== ShapeCodec.make_modifier(1,1,1,1,ANCHOR_BOTTOM)`), emitted as
`CellCodec.pack(_ID_SNOW, SNOW_SLAB_MODIFIER)` — walkable (top +0.5 ≤ STEP_MAX 0.55),
breakable (yields snow_block, mass 280·0.5 = 140 kg), no liquid, no state.

**6.2 Trigger — keyed on surface temperature, not biome.** New constant beside
`LAVA_SEA_T`:

```
const SNOW_SLAB_T := -4.0     # surface temp below which flat ground accumulates a snow slab
```

In `resolve_cell`'s `y == g + 1` branch, after the smoothing-cap check returns AIR, emit
the slab iff **all**: `g >= SEA_LEVEL` **and** flat (surface modifier 0 **and** cap
modifier 0, from the shared stencil / `_shape_entry` memo) **and** `TreeGen.block_at(x,
g+1, z, pcache) == AIR` **and** `ClimateModel.surface_temperature(g, t) < SNOW_SLAB_T`.
Since `SNOW_SLAB_T (−4) < 0`, every slab column is also capped (consistent stack). Fires
on all flat B_SNOWY ground (sea-level ≈ −8), the coldest taiga fringe, and cold elevated
flats where reachable. Temperate flats never slab. No regression: all flat B_SNOWY
columns still slab.

**6.3 Collider / cheap-query contract — retarget, don't weaken.** `surface_cap_modifier`
and `_shape_entry`'s cap byte are contractually `== CellCodec.modifier(generated_cell(x,
g+1, z))` (machine-checked, `verify_feature.gd:952`). Fold the slab into **both**
`_shape_entry` (`:546-568`) and the direct branch of `surface_cap_modifier`/`_surface_cap`
(`:596-660`): on a slab-firing column the cap byte/return is **85**. Adds a
`column_profile` + `surface_temperature` eval to those queries **only after** the cheap
`g >= SEA_LEVEL && sm == 0 && cm == 0` gate (rare) → hot path unaffected. The memo's
"shape is biome-independent" note is amended: the cap byte now depends on climate/altitude
but is still a pure deterministic function of SEED (no randi/Time), so the memo stays
byte-identical to recompute; thread-safety reasoning unchanged (main-thread memo; worker
uses non-null pcache + direct branch). Slab (85) and any smoothing cap are mutually
exclusive by the flat gate.

**6.4 Render.** Module: `snow_block` already in `appearance_surface_materials()`; **union
`SNOW_SLAB_MODIFIER` into `emitted_modifiers()`'s output** so `(snow, 85)` is always baked
(the sample is temperate and won't contain 85). Fallback: `_emit_terrain_shapes` emits any
solid shaped cell at `h+1` with zero changes; extend the greedy-top "used" marking
(`:100-102`) to columns whose `h+1` cell is a solid shaped cell to kill the coincident-
plane z-fight between the flat surface top quad and the slab's bottom face.

**6.5 Asserts.** `_test_stackup` invariants untouched; new snowy/cold-flat sweeps *added*,
not loosening any existing sweep. `MAX_SURFACE_Y` bound unaffected (slab at g+1 ≤ 21 < 24).

---

## Decision 7 — GMID / document discipline + authoring

**7.1 Serialization (omit-when-default, the `liquid_kind` discipline).**
* `to_document`: `"state_layout"` becomes the def's declared name list — **`[]` exactly as
  today for every non-cappable material ⇒ their bytes/GMIDs are byte-identical** (verify
  pin). State *bits* are per-cell (`_edits`/ZoneChunk, which already round-trips `state_at`
  — zero changes).
* `from_document`: parse `state_layout` back onto the def, and **extend transition-target
  validation** to accept `to_state ∈ state names ∪ state_layout names`. **Required** —
  transitions on a `VoxelState` serialize automatically, so without this the grass document
  is rejected by its own round-trip (`_test_dynamic_catalog`).
* `_from_record` (`block_catalog.gd`): parse the optional `"state_layout"` (onto the def)
  and the optional `"transitions"` array (reusing `MaterialDocument._str_to_cmp`) onto the
  state — the same shape `from_document` parses.

**7.2 GMID churn, eyes open:** grass/podzol/sand/stone documents change ⇒ new GMIDs.
Dense LRIDs unaffected (registration is by dense id order; the frozen-core tripwire checks
ids/masses/anchors, not GMIDs). Pre-M1 zone bundles referencing an old GMID degrade to
placeholders on load — the existing accepted RMS §8 class for any document change; note it.

**7.3 The authored transition (blocks.json, on grass/podzol/sand *and* stone):**
```json
"state_layout": ["snow_capped"],
"transitions": [
  {"to": "snow_capped", "field": "temperature", "cmp": "<",  "threshold": 0.0},
  {"to": "<own state_name>", "field": "temperature", "cmp": ">=", "threshold": 0.0}
]
```
Comparators chosen so the boundary (`T == 0`) is *bare*, matching worldgen's strict
`< 0` stamp — the two authorities agree everywhere. First-match-wins is safe (disjoint
predicates). **No new `VoxelState` entries** (a second VoxelState would allocate a second
LRID — exactly what the STATE axis avoids). `MAX_STATES` untouched.

**7.4 Look authoring:** Decision 5.3 (shared snow texture + 0.18 base tint; zero meshes,
zero textures).

---

## Decision 8 — Verify plan (`verify_feature.gd`; new `_test_snowy_world()` + retargets)

1. **Codec:** `canonical` keeps `snow_capped` on grass/podzol/sand/stone cube+ramp; strips
   it on dirt/water; strips undeclared bits (e.g. `1<<3`) on grass; air-zeroing with state
   unchanged; bits 54..63 stay 0; `STATE_SNOW_CAPPED == 1`, `grass.state_layout[0] ==
   &"snow_capped"`; `SNOW_SLAB_MODIFIER == make_modifier(1,1,1,1,ANCHOR_BOTTOM)`; plus
   `ClimateModel.surface_temperature(0,0.0)==21.5`, `surface_temperature(96,0.0)==0` (±ε),
   `climate_base(−0.6)==−8`, `climate_base(0.0)==21.5`, `climate_base(−0.35)≈6.75`.
2. **Retargets (1.5):** `:3155-3160`, `:3336/3360`, `:3625/3663/3694`, `:3896` — test docs
   gain ≥3-entry layouts so states 5/7 stay legal; **placeholder permissiveness pin**: a
   bundle cell with state bits landing on an UNRESOLVED placeholder keeps its bits through
   `_write_cell`.
3. **GMID byte-identity:** stone... *(note: stone is now cappable — use dirt + water as the
   unchanged controls)*: **dirt + water** documents contain `"state_layout":[]` and no
   snow content ⇒ GMIDs stable; grass carries both.
4. **Worldgen sweep (deterministic, loud-fail on not-found):**
   (a) capped column = `surface_temperature(g,t) < 0` (cold-biome low ground or taiga cold
   fringe): state bit set, mat/modifier unchanged, `temperature(surface) < 0`,
   `canonical(v)==v`; (b) warm-edge column (`surface_temperature ≥ 0`): state 0,
   `temperature(surface) ≥ 0`; (c) B_SNOWY flat tree-free column: top snow_block state 0,
   cell at g+1 `== pack(snow, 85)`, `surface_temperature < −4`; (d) wet cold shore
   composite: liquid kept, state 0 (disjointness); (e) wide sea-level temperate sweep
   (`surface_temperature(g,t) ≥ 0`): `state(generated_cell) == 0`; (f) **altitude-cap
   probe**: assert `surface_temperature(96,0.0) < 0` (mechanism correct) **and** report
   whether any real column reaches sub-zero surface *by altitude alone* (temperate, t ≥
   −0.15) in a wide scan — expected **none** for this seed (documents the Risk 1 gap).
5. **Temperature:** replace fixed-21.5 expectations with `21.5 − 0.224·g`; pin
   `air(96)==0`, `air(256)<0`, monotonic decrease; frozen-land surface `== −8` at g=0;
   frozen-sea pin green; a frozen peak (found cold column g ≥ 12) reads colder than the same
   biome at sea level.
6. **Both-path render mirror (module-guarded):** `_snow_arid` frozen (appearance_count
   stable across resolves); `arid_for_cell(pack(grass,0,SNOW))` ≠ plain grass ARID and ==
   `gen_arid_for(grass, 0, …, state)`; unbaked state pair (**stone**+snow-bit — declared,
   unbaked → plain look, never 0) falls back to plain ARID; generated TYPE buffer over a
   capped region == the `gen_arid_for` mirror (extend `_test_both_paths` sampling into the
   cold band); mesh-level: the capped variant model meshes with the variant material;
   fallback: a chunk over the capped column committed with `snow_capped_for(grass)`, and
   capped/bare tops did not greedy-merge.
7. **Transition fires end-to-end (4.2):** at the capped column `sample()` triggers no melt;
   copy the capped value into a warm column via `_write_cell`, `apply_state_transitions` →
   true, state cleared, `_edits` holds the cleared value (persists over re-query), second
   call → false (idempotent); reverse edge: bare grass in a cold column gains the bit.
8. **Slab physics:** gate on `surface_temperature(g,t) < −4` columns; `floor_under` == g +
   1.5; `blocked` auto-steps onto it; `surface_cap_modifier == 85 ==
   modifier(generated_cell(g+1))` there (extend the cheap-query test's area to include one);
   `break_terrain` yields snow_block id; `mass_of_value(pack(snow,85)) == 140`.
9. **Manifest:** `emitted_modifiers()` contains `SNOW_SLAB_MODIFIER`; `_test_manifest_trim`
   coverage sweep still green.

---

## Decision 9 — Risks / open issues

1. **HARD REACHABILITY GAP — altitude caps on temperate peaks are INERT for this seed
   (accepted per user scope decision).**
   > **UPDATE (Mountains biome milestone):** this gap is now **CLOSED**. A separate, tall
   > **B_MOUNTAINS** biome (a low-frequency mask term added in `_height_c`, gated to inland columns,
   > exactly 0 elsewhere so the rest of the world stays byte-identical) raises peaks to y≈100–112,
   > crossing the y=96 freeze line. The already-wired altitude cap (`surface_temperature < 0`) whitens
   > those peaks with no new cap code; `stone` was added to `snow_cappable_materials()` (baked set) so
   > bare-rock peaks render white on both paths. `MAX_SURFACE_Y` 24→116 and `VIEWER_VERTICAL_RATIO`
   > 0.2→0.5 (bounded ~2.5× vertical stream) support the taller terrain. The verify altitude-cap probe
   > was FLIPPED from "expected none" to "FOUND". See the Mountains commit on `feat/voxiverse-multi-liquid`.

   Max ground height (pre-Mountains) = `BASE_HEIGHT(5) + max
   continent_offset(11) + HILLS_AMPLITUDE(3) + DETAIL_AMPLITUDE(1) = 20`; `MAX_SURFACE_Y =
   24` is the verify-proven bound. Temperate freezing altitude = y=96. A reachable temperate
   peak (y≈20) reads `21.5 − 0.224·20 = 17 °C` — never sub-zero. So the unified predicate is
   **correct and future-proof but produces no visible temperate-peak caps** now. M1's visible
   winter comes from **climate-offset winter biomes** (B_SNOWY −8, cold taiga fringe — both
   reachable, genuinely sub-zero) + **altitude modulation of the snow line within** those cold
   biomes (a frozen peak at y=18 reads −12 vs −8 at sea level, so the snow line visibly climbs
   with elevation). Temperate-peak caps light up automatically when taller terrain lands — no
   code change. **Deferred tall-mountains milestone** (raises MAX_SURFACE_Y, the generator
   air early-out, and VIEWER_VERTICAL_RATIO=0.2's ±51-block stream slab which wouldn't stream a
   y≈100 peak) is out of M1.
2. **Temperature model no longer byte-identical for elevated temperate columns** — retargeted
   in Decision 8. Frozen-sea −8 and geothermal 27 °C bedrock pins **are** preserved.
3. **New `ClimateModel` file + air-branch noise sampling** — one static file, one
   `column_profile` per air query (HUD ≤3/frame, per-edit solver joints; no per-voxel tick) —
   negligible. The `ClimateModel` sink is what keeps the cap call cycle-free; if a cyclic-ref
   parse error appears, the extraction *is* the fix.
4. **`from_document` validation change** (transition targets vs `state_layout`) touches the
   RMS rejection path — implement first, verify (`_test_dynamic_catalog` + item 3) before
   wiring worldgen; a slip rejects bootstrap docs and trips the frozen-core fallback loudly.
5. **`_validate_state` semantic change** breaks the four enumerated verify sites unless the
   retargets (8.2) are in the SAME commit.
6. **Module-path edit eviction**: if godot_voxel drops an edited data block and re-generates
   it, the render briefly shows the generated (capped) cell while `_edits` holds the melt —
   pre-existing class for all overlay edits; not M1-specific.
7. **DESIGN §1 amendment mandatory** (temperate **sea-level** baseline + the y=96 lapse +
   winter offsets); rewrite the `per_voxel_environment.gd` header or the next reader "fixes" it
   back.
8. **GMID churn** for grass/podzol/sand/stone — accepted; old bundles degrade to placeholders
   losslessly.
9. **Scope guard:** no `_biome` additions, no taller terrain, no runtime tick, no v2 texture
   split, no snowy tree leaves, no puddle emission, no second state bit — all M2/Phase-3.
   Anything reaching for those re-opens this ADR.

---

## File-by-file touch list (implementation order)

| # | file | change |
|---|---|---|
| 1 | **NEW `godot/src/sim/climate_model.gd`** | `ClimateModel`: consts + `climate_base`, `surface_temperature`, `air_temperature`. Dependency-free sink. |
| 2 | `godot/src/sim/voxel_material_def.gd` | `state_layout: Array[StringName]` export |
| 3 | `godot/src/sim/material_document.gd` | serialize/parse `state_layout`; transition targets may name layout bits (7.1) |
| 4 | `godot/src/sim/block_catalog.gd` | parse `state_layout`/`transitions` in `_from_record`/`ensure_ready`; `state_mask_of()` (per-LRID mask array; placeholder → 0xFFFF) |
| 5 | `godot/assets/blocks.json` | `state_layout` + 2 transitions on grass/podzol/sand/stone |
| 6 | `godot/src/world/cell_codec.gd` | `STATE_SNOW_CAPPED`, `STATE_BIT_BY_NAME`, `has_state`/`with_state`, real `_validate_state` |
| 7 | `godot/src/sim/per_voxel_environment.gd` | depend on `ClimateModel`; rework `_air_at`/`air_temperature`/`surface_air_temperature`, air branch + ground anchor of `temperature()`; keep frozen-ocean branch, depth cool, geothermal; header rewrite |
| 8 | `godot/src/world/terrain_config.gd` | delete `SNOW_CAP_T`; add `SNOW_SLAB_T := -4.0`; `_with_snow_state` (temp-keyed) + two call sites; slab rule in `y==g+1`; fold slab into `_shape_entry` + `surface_cap_modifier`/`_surface_cap`; union `SNOW_SLAB_MODIFIER` into `emitted_modifiers()`; `snow_cappable_materials()` = {grass,podzol,sand} |
| 9 | `godot/src/world/block_materials.gd` | `snow_capped_for(base_id)` cached variant material |
| 10 | `godot/src/world/voxel_module/module_world.gd` | `_snow_arid` bake+freeze, `arid_for_cell` state branch, generator publish + inline branch, `gen_arid_for(state)`, `bulk_inject` → `arid_for_cell` |
| 11 | `godot/src/world/fallback/chunk_mesher.gd` | look-key projection (tops/sides/shapes/commit), top-quad-under-slab skip |
| 12 | `godot/src/world/world_manager.gd` | `apply_state_transitions(cell)`; `set_state` doc comment |
| 13 | `godot/src/tools/verify_feature.gd` | `_test_snowy_world()`, the four retargets, `_test_both_paths`/collider/manifest sweep extensions |
| 14 | `docs/DESIGN.md` | temperate **sea-level** baseline amendment + y=96 lapse + winter offsets |

Conventional Commits, scope `voxiverse`, on `feat/voxiverse-multi-liquid` (or a sub-branch);
`/steelman` before PR per standing policy.
