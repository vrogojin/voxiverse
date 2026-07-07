# MULTI-LIQUID — generalizing borderless waterlogging to ANY liquid (lava first), plus the DESIGN §79 multi-material plan

Status: **DESIGN — Phase 1 (Part A) is buildable now.** Branch family: `feat/voxiverse-multi-liquid-*`.

This document generalizes the shipped native-waterlogging result (WATERLOGGING.md,
WATER-SHORE.md, merged to `main`) along two axes:

* **Part A (concrete, the primary deliverable):** any liquid — lava now, a third
  liquid later — rendered borderless within itself and with a crisp, correct
  boundary against *different* liquids, driven by data instead of the current
  water-hardcoded wiring.
* **Part B (scope + phased plan):** the DESIGN §79 multi-material voxel cases
  ("ground+puddle+ice+snow+grass"), assessed honestly against the blocky-mesher
  engine limits, staged by feasibility.

Sibling ground truth verified while writing this design (refs as of
`feat/voxiverse-multi-liquid` @ b168eea): `cell_codec.gd`, `block_catalog.gd`,
`terrain_config.gd`, `module_world.gd`, `world_manager.gd`, `blocks.json`,
`block_materials.gd`, the applied engine patch
`docker/engine/patches/godot_voxel/0001-native-waterlogging.patch`, and the
patched module source under `docker/engine/cache/godot/modules/voxel/`.

---

## 0. Executive summary

* **Feasible without any new engine feature.** The 0001 waterlogging patch
  already made the engine multi-liquid: `VoxelBlockyFluid` resources register
  into `indexed_fluids` with distinct `fluid_index` per fluid, and every
  borderless-culling rule keys on `fluid_index` **equality** — so water↔water
  stays borderless, lava↔lava becomes borderless, and water↔lava shows a crisp
  boundary, all for free. What is water-hardcoded today is the **game wiring**
  (one fluid, one twin table, water-only worldgen) and one **codec rule**
  (CellCodec `_canonical_liquid` rule 6 rejects kind > WATER on solid hosts).
* **The one real rendering subtlety is that lava is an OPAQUE fluid.** An opaque
  fluid's full side patterns would cull the faces of adjacent solids
  (full-vs-full at equal transparency index), opening a 1/16-block sliver of
  see-through terrain above the 0.9375 lava surface at every steep pool wall.
  The fix needs **no engine change**: set `culls_neighbors = false` on the pure
  lava fluid model (the property is already exposed on the base
  `VoxelBlockyModel` and copied into the baked fluid model). §2.3 works through
  every face pair.
* **Lava placement: a climate-keyed sea regime.** The sea machinery already has
  a regime switch (frozen: `t < -0.55` → ice). Add the symmetric hot end:
  `t >= LAVA_SEA_T (0.60)` → the sea fill IS lava — molten seas in extreme-hot
  ocean regions, reusing the sea-fill + shore-composite + submerged-composite
  machinery verbatim with a `kind` parameter. Deterministic, demonstrable
  (walk to a hot coast; borderless lava shore, glowing surface), and no new
  worldgen machinery.
* **Engine rebuild:** required **only** for the deferred 0002 signal-safety
  hardening of `copy_base_properties_from` (a one-line fix folded in per the
  review). The Part A *feature* runs on the already-built binaries — the game
  wiring is pure GDScript against APIs that already exist. The rebuild is
  therefore an independent, non-blocking work-stream.
* **Part B verdict:** waterlogging + the liquid axis already cover the
  solid+liquid half of §79 (puddles are liquid levels — codec-ready). Thin
  layers (snow/ice sheets) and decorations (grass tufts) are best expressed as
  **stacked cells** (half-slab modifiers today, a thin-layer shape family
  later). True two-solids-in-one-cell is possible via baked combined models
  (bounded like the twin manifest) but is the lowest-value/highest-cost case;
  the STATE axis (bits 32..47, already live) covers appearance-only variants
  (snowy grass) far cheaper. Phased in §3.

---

## 1. Verified ground truth

### 1.1 The engine is already multi-fluid (0001 patch, applied source)

* `get_or_register_fluid` find-or-appends each distinct `VoxelBlockyFluid` into
  `indexed_fluids`, assigning it the next `fluid_index`
  (`voxel_blocky_model_fluid.cpp`, factored per WATERLOGGING §3.5). Two fluids
  → two indexes.
* Every borderless rule tests `fluid_index` **equality**:
  * pure-fluid visibility short-circuit — "a fluid voxel's faces are never
    drawn against a neighbour carrying the same fluid"
    (`voxel_mesher_blocky.cpp:160-168` patched);
  * the waterlogged fluid-pass mask — `other.fluid_index == voxel.fluid_index
    → continue` (`voxel_mesher_blocky.cpp:216-222` patched);
  * fluid top cover + corner levels — neighbour counts as fluid iff same
    `fluid_index` (`blocky_fluids_meshing_impl.h`, WATERLOGGING §1.3).

  So *different* liquids do NOT cull each other: the boundary face is drawn —
  physically correct, and exactly what we want at a water/lava interface.
* `culls_neighbors` is a stock, exposed base-model property:
  `voxel_blocky_model.cpp:648/695` (`set_culls_neighbors` bound + property),
  consumed by `is_face_visible_regardless_of_shape`
  (`voxel_mesher_blocky.h:121`), and **copied into the baked model of pure
  fluids** (`voxel_blocky_model_fluid.cpp:156`). Settable from GDScript today.
* CRITICAL ORDERING FACT: in the patched visibility loop the same-fluid
  short-circuit fires **before** `is_face_visible_regardless_of_shape`
  (`voxel_mesher_blocky.cpp:160-170`), so `culls_neighbors = false` on a fluid
  can never re-open same-fluid borders — equality culling wins first.

### 1.2 What is water-hardcoded in the game (the generalization surface)

* `module_world.gd`: ONE `_water_fluid`; the water LRID special-case in
  `_configure_library` (line 819); one twin table `_gen_wet_arid` + one
  `_water_surface_arid`; the worker routes liquid 9/10 through those two tables
  with no notion of kind (lines 976-994).
  ⚠ Latent bug-if-unfixed: `arid_for_cell`/the worker route **any** liquid-9
  modifier-0 cell to `_water_surface_arid` — a lava surface cell would render
  as the *water* model. Kind-keying the tables is correctness, not polish.
* `block_catalog.gd`: `liquid_kind_of` returns LIQ_WATER for the water LRID
  only (line 411-414), name-keyed, with the recorded note "a data-driven
  `liquid_kind` key in blocks.json is a future nicety" — this design makes it
  real.
* `cell_codec.gd`: `_canonical_liquid` rule 6 strips `kind > LIQ_WATER` on
  solid composites (lines 196-199, "extend when lava lands" — now).
  Rules 1-5 are already kind-generic (rule 5 delegates to `liquid_kind_of`).
* `terrain_config.gd`: `_sea_block` (777-785) and `_with_shore_water` (435-441)
  emit only WATER; `emitted_shore_pairs`/`emitted_submerged_pairs`
  (1037-1107) sample only the water regime; `find_coast` (1009) is
  regime-blind.
* `blocks.json`: water id 44 (`solidity 0`, `cull_group 1`, translucent),
  **lava id 45** (`solidity 0`, `cull_group 0`, `emissive 1.0`, opaque,
  `structural_class "fluid"`, `break_force` absent → INF) — lava already
  exists as a material; it is generated nowhere and placeable never
  (`world_manager.gd:342` rejects non-solid placement).
* Physics is solidity-gated everywhere, never water-id-gated: `_occ_span`,
  `floor_under`, `blocked`, `aimed_voxel`, `occludes_face` all read
  `solidity_of`/mat projections (`world_manager.gd:751/815/845/967`), and the
  liquid axis is read by no physics function (WATER-SHORE §6). Lava (solidity
  0) inherits water's physics behaviour by construction.

---

## 2. Part A — the liquid generalization

### 2.1 Data model: liquids are declared in blocks.json

**blocks.json** — one new optional key on liquid materials:

```json
{ "name": "water", "id": 44, ..., "liquid_kind": "water" }
{ "name": "lava",  "id": 45, ..., "liquid_kind": "lava"  }
```

Absent key = not a liquid (every other record unchanged; no bloat — the
`has_block_entity` precedent).

**CellCodec** — claim one reserved kind value:

```gdscript
const LIQ_WATER := 1
const LIQ_LAVA := 2        # was reserved (WATER-SHORE §2.1 "2..3 reserved (lava, …)")
                           # kind 3 remains reserved for a third liquid.
```

The kind name → value map is a CellCodec const Dictionary
(`{&"water": LIQ_WATER, &"lava": LIQ_LAVA}`) so the codec stays the single
authority on the bit meanings and BlockCatalog resolves names through it.

**Kind ceiling (be honest):** LIQ_KIND is 2 bits → at most **3** liquid kinds
(1..3). A fourth liquid requires widening the field into the reserved band
54..62 — a re-layout that is cheap **while liquids remain worldgen-only**
(the ZoneChunk liquid layer is deferred, WATER-SHORE deviation banner; nothing
serialized carries the bits), and must happen before liquids ever become
editable/persisted. Recorded as the extension path, not built now.

**BlockCatalog** — generalize resolution (replacing the water-only cache):

```gdscript
## Parsed in _from_record: rec.get("liquid_kind","") → CellCodec kind (0 if absent
## or unknown-name, with a push_warning on unknown). Stored on VoxelState.liquid_kind
## (new int field, default 0).
static func liquid_kind_of(block_id: int) -> int      # state_of(id).liquid_kind
static func liquid_lrid_of(kind: int) -> int          # kind -> LRID; -1 unknown (reverse map,
                                                      #   built at ensure_ready, first-declared wins)
static func is_liquid_kind_known(kind: int) -> bool   # reverse-map hit (rule-6 gate)
```

Load-time validation in `ensure_ready()`: a record declaring `liquid_kind`
must have `solidity < 0.5` (a "solid liquid" is a data error — warn + strip),
and two records must not claim the same kind (first wins, warn).

⚠ **GMID discipline:** `VoxelState.liquid_kind` must be **omitted from the
material document when 0** (`MaterialDocument.to_document`), so every existing
material's GMID stays byte-identical. Water's and lava's GMIDs do change (they
now declare the field) — safe, because liquids are never placeable/editable, so
their GMIDs can appear in no zone bundle (placement gate
`world_manager.gd:342`; VoxelBody capture strips liquid). Verify pins this:
GMID of a non-liquid material computed before/after the change is identical.

**CellCodec rule 6 relaxation** (`_canonical_liquid`, cell_codec.gd:196-199):

```gdscript
# was: if kind > LIQ_WATER: strip
if not BlockCatalog.is_liquid_kind_known(kind):
    push_warning("CellCodec: unknown liquid kind %d on solid composite (material %d) — stripped"
        % [kind, material])
    return 0
```

Any KNOWN kind (water, lava, a future third) may waterlog a solid composite;
unknown/reserved kinds are still stripped. Rule 5 needs **no change** — with
lava's declared identity, `liquid_kind_of(lava) == LIQ_LAVA` makes the bare
lava id THE canonical full-lava cell and keeps levels 1..9 on lava hosts,
exactly mirroring water (no dual encoding, byte-stable deep lava).

### 2.2 Module wiring generalization (`module_world.gd`)

Replace the singular water objects with per-kind tables (kind ∈ 1..3, so all
tables are tiny fixed arrays; index 0 unused):

```gdscript
var _fluids: Array = [null, null, null, null]        # kind -> VoxelBlockyFluid (null = no such liquid)
var _gen_twin_arid: Array = [ ... ]                   # kind -> PackedInt32Array (mat*_GEN_STRIDE+mod -> ARID)
var _surface_arid := PackedInt32Array([-1, -1, -1, -1])  # kind -> liquid-surface model ARID
```

1. **Fluids** (`setup()`): for each kind with `liquid_lrid_of(kind) > 0`,
   build one `VoxelBlockyFluid`: material `BlockMaterials.get_for(lrid)`
   (water: translucent; lava: **emissive opaque** — `get_for` already builds
   the glow from `render_def_of`, block_materials.gd:37-40),
   `dip_when_flowing_down = false`. Iterate kinds **ascending** so fluid
   registration order — hence `fluid_index` — is deterministic.
2. **Pure fluid models** (`_configure_library`, generalizing the line-819
   special case): for each block id, `var lk := BlockCatalog.liquid_kind_of(block_id)`;
   if `_waterlog_enabled and lk != LIQ_NONE and _fluids[lk] != null` → a
   `VoxelBlockyModelFluid` (fluid `_fluids[lk]`, level 1,
   `transparency_index = cull_group_of(block_id)`), preserving the
   index==LRID invariant with the cube fallback as today. **Additionally, iff
   `cull_group_of(block_id) == 0` (an opaque fluid — lava):
   `set_culls_neighbors(false)`.** This is the sliver fix; the full culling
   proof is §2.3. Data-driven: any future opaque liquid gets it automatically.
3. **Twin tables**: `_build_waterlog_manifest` runs once per kind with a
   registered fluid, over
   `TerrainConfig.emitted_shore_pairs(kind) ∪ emitted_submerged_pairs(kind)`
   (§2.4), building twins via `_make_waterlogged_model(modifier,
   terrain_material, kind)`: same dry `_shape_mesh_cache[modifier]` ArrayMesh
   (no mesh multiplier — meshes are shared across kinds too), solid
   `transparency_index 0` (unchanged, load-bearing), `set_waterlog_fluid(_fluids[kind])`,
   `set_waterlog_level(1)`,
   `set_waterlog_fluid_transparency_index(cull_group_of(liquid_lrid_of(kind)))`
   (water 1, lava **0**). Twins keep `culls_neighbors` default TRUE — their
   side patterns are their solid ramp and must keep culling neighbours
   normally (see §2.3, row "solid vs twin").
4. **Surface table**: native path `_surface_arid[kind] = _cube_arid_of(liquid_lrid_of(kind))`
   (the pure fluid model). Legacy path (`_waterlog_enabled == false`):
   `_surface_arid[LIQ_WATER]` = the 0.9 slab as today; **other kinds stay -1**
   → a legacy engine renders lava surface cells as plain lava cubes (bordered,
   blocky, emissive — degraded, never a hole, and never *water-skinned*).
   Same for legacy wet composites: water-only, other kinds fall to the dry
   shape. This fixes the ⚠ mis-skin noted in §1.2 on both engines.
5. **Worker route** (the runtime generator + `arid_for_cell` + `gen_arid_for`,
   all three kept in lock-step as today): the liquid branch reads the kind:

   ```gdscript
   var lf = CellCodec.liquid_field(v)
   if lf != 0:
       var lk = lf & 3                      # CellCodec.LIQ_KIND_MASK inline (worker: consts hoisted)
       var lvl = lf >> 2
       if lvl == 9:
           if modifier == 0: arid = surface_arid[lk] if surface_arid[lk] >= 0 else cube-fallback
           else: twin-lookup in twin_arid_for_kind, dry-shape/cube fallback
       elif waterlog and lvl == 10 and modifier != 0:
           twin-lookup, dry-shape/cube fallback
   ```

   Zero-allocation discipline preserved: the per-kind `PackedInt32Array`s are
   hoisted into block-frame locals at the top of `_generate_block`
   (`var twin_w = gen_twin_arid[1]; var twin_l = gen_twin_arid[2]; …` — three
   locals, not a per-cell Array index), and `gen_arid_for` grows a
   `liquid_kind := LIQ_WATER` arg so verify's both-path mirror stays exact.
   Deep lava (bare id, field 0) takes the unchanged cube fast path — whose
   cube ARID **is** the lava pure-fluid model, exactly like deep water today.
6. **Manifest growth bound**: water twins today = |shore ∪ submerged| ≈ 132.
   Lava adds its own submerged set (same 4 underwater-floor materials ×
   emitted modifiers ≈ 120, `emitted_submerged_pairs` is kind-independent in
   content) + sampled lava-shore pairs (tens) ≈ **+130 twins; total ≈ 260–270
   models, ~2× today, bound linear in |liquids| (≤ 3)**. All twins share the
   ≤79 dry ArrayMeshes, so GPU mesh readback count does not grow — only model
   bake/pattern work does. If load-stall telemetry says otherwise, the recorded
   trim is: bake lava twins only when a lava coast/sea is inside the sample
   radius (degrade: dry-shape border, never a hole — the standing exhaustion
   policy).

### 2.3 Lava rendering — the opaque-fluid culling analysis (the load-bearing section)

Lava's properties: **opaque** (`cull_group 0`), **emissive** (`emissive 1.0`,
BlockMaterials builds the glow), fluid surface at the native TOP_HEIGHT
**0.9375** (same constant as water — `WATER_SURFACE_HEIGHT` already equals it,
terrain_config.gd:54; the name is water-flavoured but the value is THE liquid
line; renaming is optional polish).

The mesher visibility rule (`voxel_mesher_blocky.h:119-135`): neighbour B never
culls A's face if B is empty, or `B.transparency_index > A.transparency_index`,
or `!B.culls_neighbors`; otherwise culling is side-pattern-based (pure fluids
carry FULL patterns on all six sides, `voxel_blocky_library_base.cpp:711-721`).
Water avoids opaque-fluid problems because its index 1 > 0 makes solids draw
against it. Lava at index 0 does not — hence:

**The sliver hazard.** With defaults, a stone face adjacent to a pure lava cell
is culled (stone idx 0 vs lava idx 0, full-vs-full patterns) while the lava's
own lateral face toward stone is also culled (symmetric) — but uncovered lava's
visible geometry tops out at 0.9375, so the band 0.9375..1.0 of every steep
pool wall would be a see-through hole into the terrain.

**Why not a nonzero transparency index for lava?** A total order cannot express
"opaque to look at, but doesn't occlude": lava idx 1 (== water) makes water↔lava
*mutually* culled → a hole at every water/lava interface; lava idx 2 culls
lava's own boundary face against water while water's face draws → you would see
through the translucent water pane into an unmeshed lava interior. Both wrong.

**The fix: `culls_neighbors = false` on the pure lava fluid model** (stock
property, §1.1 — no engine change). Full face-pair audit, citing the rules:

| face of… | against… | result | why (rule) |
|---|---|---|---|
| lava | lava (or lava-twin) | **culled** | same-`fluid_index` short-circuit, fires BEFORE the culls_neighbors test (`voxel_mesher_blocky.cpp:160-170`) — borderless preserved |
| solid cube | lava | **drawn** | `!B.culls_neighbors` (`voxel_mesher_blocky.h:121`) — closes the sliver; below the lava line it is hidden overdraw behind the opaque fluid (same cost class as solids under water today) |
| lava | solid cube | culled | stone culls_neighbors=true, idx 0 ≯ 0 → full-vs-full pattern | 
| lava | air | drawn | neighbour empty |
| water | lava | **drawn** | `!lava.culls_neighbors` → the translucent water pane at the interface |
| lava | water | **drawn** | `water.idx 1 > lava.idx 0` → the opaque emissive lava face behind the pane. Both faces drawn ⇒ a crisp, physically-plausible boundary (lava seen through tinted water) |
| ice/glass | lava | drawn | `!lava.culls_neighbors` (fine — translucent over opaque face) |
| water-twin fluid | pure lava | drawn | fluid pass mask: kinds differ (no equality cull), then `!other.culls_neighbors` (`voxel_mesher_blocky.cpp:222-228`) |
| lava-twin fluid (`fluid_transparency_index 0`) | solid cube | culled | pattern test `ai == bi` (full vs full) — correct, it is hidden |
| lava-twin fluid | pure water | drawn | `other.transparency_index 1 > 0` — the boundary face |
| solid cube | lava-**twin** | drawn | the twin's side patterns are its SOLID ramp (partial — a nonzero modifier can never rasterize all-full on every side; an edge-full side is covered by the twin's own solid geometry there), so no sliver arises and twins keep `culls_neighbors = true` |
| lava interior (covered, all-lava neighbourhood) | — | nothing emitted | equality culls all sides + covered-top fast path — the ocean-interior optimization holds for lava seas |

Conclusion: lava keeps `transparency_index 0`, gains `culls_neighbors false`,
twins keep both defaults except `waterlog_fluid_transparency_index 0`. No
engine change; verify pins the table's hot rows with a hand-built 3×3×3 buffer
(§5 checklist, mirroring WATERLOGGING §4.8).

**Physics — confirmed no regression** (task item A3): lava is `solidity 0`;
every physics/structural consumer is solidity- or mat-projection-gated
(§1.2), the liquid axis stays read by none of them, placement already rejects
lava, `aimed_voxel` passes through it, `occludes_face` returns false for it,
and `VoxelBody` capture strips the (kind-agnostic) liquid field
(`CellCodec.strip_liquid`). The GroundCollider's debris-floats box
(`ground_collider.gd:454`) keys on `y <= SEA_LEVEL`, kind-agnostic → debris
floats on lava too (accepted: pumice). No lava damage in v1 — the sim-layer
follow-up is a `PerVoxelEnvironment` molten-sea seam (below) plus a future
state-machine burn rule; out of scope here.

### 2.4 Worldgen: the climate-keyed sea regime (`terrain_config.gd`)

**Chosen: the sea itself is regime-keyed by temperature — frozen / water /
molten.** The frozen end already exists (`t < -0.55` → ice cap); add the hot
end. One new pure function is the single authority:

```gdscript
const LAVA_SEA_T := 0.60          # extreme-hot ocean regions: the sea fill IS lava

## The liquid kind of the sea fill for climate t (frozen-cap handling stays where
## it is — ice is a SOLID regime at the surface cell, not a liquid kind).
static func _sea_liquid_kind(t: float) -> int:
    return CellCodec.LIQ_LAVA if t >= LAVA_SEA_T else CellCodec.LIQ_WATER
```

* `_sea_block(t, y)` (777-785): resolve `kind` + its LRID
  (`_ID_LAVA` joins the cached ids, `_ensure_ids`); `y == SEA_LEVEL` frozen
  branch unchanged (disjoint: `t < -0.55` vs `t >= 0.60`); otherwise
  `pack(lrid, 0, 0, make_liquid(kind, 9))` at the line, bare `lrid` below —
  the exact water pattern, kind-parameterized.
* `_with_shore_water` → **`_with_shore_liquid`** (435-441): same guards
  (`y > SEA_LEVEL`, `modifier == 0`, frozen at the line), and the composed kind
  is `_sea_liquid_kind(t)` — shore and submerged composites of a molten sea
  carry LIQ_LAVA. Still pure in (v, y, t).
* `find_coast_of(kind)` generalizes `find_coast` (1009): same deterministic
  scan, matching `height_at == SEA_LEVEL` **and** `_sea_liquid_kind(t) == kind`
  (and non-frozen for water). Lava coasts are rarer (temperature freq 0.002 →
  climate regions of hundreds of blocks, same rarity class as frozen oceans),
  so the lava scan radius extends to 1024; **not found ⇒ return a sentinel and
  skip lava SHORE-pair sampling** (see next bullet for why that is safe).
* `emitted_shore_pairs(kind := CellCodec.LIQ_WATER)`: the existing sampler,
  centred on `find_coast_of(kind)`, with the frozen skip generalized to
  "column's regime == kind" (this also stops water-pair sampling from
  wandering into a molten shore). `emitted_submerged_pairs(kind)` is already
  material-complete by construction (4 floor materials × emitted modifiers —
  it never depended on the coast sample), so **distant/unfound lava seas still
  get their submerged twins**; only unsampled *shore* pairs degrade to the
  dry-shape border (the standing sample-superset policy, never a hole).
* Underwater floor of a molten sea: reuse `_underwater_floor` as-is (hot ocean
  → sand). A basalt/scorched floor material is future flavour, not scope.
* Trees: biome-gated off ocean/beach already; hot regions are
  badlands/desert — no interaction.

**Determinism & byte-identity statement:** every changed value is a pure
function of (SEED-noise, position). Byte-identical to today: all cells with
`t < LAVA_SEA_T` (all temperate + frozen output), all land, all sub-surface,
deep-water bodies, ice caps. The ONLY changed generated values are sea-fill and
shore/submerged-composite cells in `t >= 0.60` ocean regions — previously
water, now lava. **This is the deliberate feature**, and it flips any existing
verify sweep that asserts "sea cell == water" over a hot ocean: those asserts
must be retargeted to `_sea_liquid_kind(t)` (checklist item; do not weaken —
retarget).

**Rejected placements:** a deep lava sea below a Y-threshold (invisible — the
world is a heightmap with no caves; fails the "user can SEE borderless lava"
gate, only visible by digging); a volcano biome with crater carving
(over-build for v1 — new height machinery for one demo; the molten sea is one
regime function). Both recorded as future options; the molten sea does not
preclude either.

**Sim follow-up (small, optional, demonstrable):** mirror the frozen-sea seam
in `PerVoxelEnvironment` — over a molten sea (`surface < SEA_LEVEL`,
`y <= SEA_LEVEL + 1`, `t >= LAVA_SEA_T`) report a hot air band (e.g. +150 °C
at the surface) so the thermometer HUD reacts at a lava coast. One clause in
the exact spot the −8 °C frozen seam lives; verify-pinned like the frozen one.

### 2.5 Engine hardening — patch 0002 (independent stream)

The deferred review item: `voxel_blocky_model.cpp` `copy_base_properties_from`
(0001 patch hunk at line ~405) assigns `_waterlog_fluid = src._waterlog_fluid;`
directly, bypassing `set_waterlog_fluid` — the destination model's previously
connected fluid keeps its `changed` connection (stale signal → spurious
`emit_changed` targets) and the newly copied fluid is never connected (missed
invalidation). Fix (one line):

```cpp
set_waterlog_fluid(src._waterlog_fluid);   // handles disconnect/connect + guards
```

(plus, belt-and-braces, an `is_connected` guard inside `set_waterlog_fluid`'s
disconnect path). Ship as
`docker/engine/patches/godot_voxel/0002-waterlog-copy-hardening.patch`;
`build-engine.sh` already applies the `patches/godot_voxel/*.patch` glob in
order, and BUILD-INFO records the patch list + shas. **This is the only item
in Part A needing an engine rebuild** (warm, minutes; `module_in_web=yes`
release gate as always). Nothing in §2.1-2.4 depends on it — the copy path is
exercised only by editor model-type conversions, not by the game — so it lands
as its own stream, in either order relative to the game wiring.

---

## 3. Part B — DESIGN §79 multi-material voxels: scope, feasibility, phases

§79 asks for "multi-material voxels (ground+puddle+ice+snow+grass)".
Waterlogging shipped the SOLID+LIQUID case. Decomposing the rest honestly:

### 3.1 Case-by-case

| §79 case | mechanism | status / phase |
|---|---|---|
| ground + water/lava remainder (shore, submerged) | waterlogged twins (liquid axis) | **SHIPPED** (water) / Phase 1 (lava, Part A) |
| **puddle** on a smoothed (modifier ≠ 0) surface | liquid axis levels 1..8 on a solid host — codec rules already keep them; engine `set_waterlog_level(n)` + `BakedFluid.max_level` auto-raise are native | Phase 2. Cost: twins × |levels used| — bound by registering only the levels worldgen emits (e.g. {3, 9, 10}) |
| **puddle** on flat ground | a shallow pure-liquid cell ABOVE the ground: water-material cell at liquid level 1..2 (rule 5 keeps levels 1..9 on liquid hosts — codec-ready TODAY); render = per-level `VoxelBlockyModelFluid`s (native, ≤10 models per liquid) | Phase 2. Blocker is a SOURCE, not a mechanism: nothing generates puddles yet (needs a weather/moisture rule) |
| **ice** sheet on water | solid ice cell above water | **SHIPPED** (frozen seas) |
| ice/snow as a **half-block** layer | a stacked cell above, with the existing corner-height modifier (all-corners-1 slab) — physics (`_occ_span`, collider, solver) already handles modifiers | Phase 2 — worldgen-only change (e.g. snowy-biome snow slabs on grass) |
| ice/snow as a **thin** (<½ block) layer | NOT expressible: ShapeCodec is half-block-granular by design (corners ∈ {0,1,2}, WATER-SHORE §4.1). Needs the reserved FAM-bit shape family (`MOD_FAM_BIT`, cell_codec.gd:29): a "thin-layer" family (thickness in tenths), + ShapeMesh builder + `_occ_span`/collider/solver span support + manifest entries | Phase 3 — game-side only (models are just meshes; **no engine patch**), but cross-cutting through the physics span math — the most expensive game-side item |
| **grass tuft** / plant decoration on ground | (i) a stacked non-solid decoration cell above (cross-quad model, solidity 0, like Minecraft) — cheap, physics-invisible by the solidity gate; or (ii) appearance-only variant of the SAME cell via the **STATE axis** (bits 32..47, already live) — e.g. dirt state `tufted`, one extra baked model per state | Phase 2 (either; (ii) is cheapest and also covers "snowy grass" tops) |
| TRUE two solids in one cell (snow-cap-on-grass in the same voxel) | see §3.2 | Phase 3+, only if a case demands it |

### 3.2 The two-solids-in-one-cell options (evaluated)

* **(a) Baked combined models** (the twin pattern extended to solid+solid): a
  `VoxelBlockyModelMesh` whose ArrayMesh holds both solids' geometry. The
  mesher is indifferent (a model is any mesh) — **feasible with zero engine
  change**, and the manifest discipline bounds it exactly like twins:
  |emitted (base-mat, cap-mat, shape) triples| from a deterministic sample.
  Real costs: id growth is a *product* (must stay a sampled subset, never a
  cross-product of the catalog); **identity questions** — which material does
  `block_id_at` report? what does breaking yield? what mass? — require a
  primary/secondary convention on a new axis (the natural home: a second
  16-bit "secondary material" field would exceed the remaining reserved bits;
  a small curated combo table indexed from the STATE axis fits bits we have).
  And the **transparency constraint bites**: one model has ONE
  `transparency_index`, so a solid+*translucent-solid* combo (ground+ice in
  one cell) recreates the exact wall that forced the waterlogging engine
  patch — the fluid two-pass solved it for fluids ONLY. Verdict: usable for
  opaque+opaque combos with curated identity semantics; **never** for
  translucent caps (use stacked cells for ice).
* **(b) A second data channel / second material axis in the engine**: rejected
  again for the same reason WATERLOGGING §2 rejected it — `VoxelMesherBlocky`
  reads exactly one TYPE channel; threading a second channel touches mesher,
  storage, streaming, generator API and the game's bulk-inject: the 5-10×
  patch. Revisit only if a future milestone makes multi-solid cells pervasive
  rather than decorative.
* **(c) Stacked cells** (Minecraft's answer): already fully supported by
  physics/codec/manifest today at half-block granularity; the thin-layer shape
  family (Phase 3) removes the granularity limit. **Default choice** for
  snow/ice layers and standalone decorations.

### 3.3 The phased plan

* **Phase 1 (now, buildable): Part A** — liquids generalized + lava + the 0002
  hardening. Work-streams in §5.
* **Phase 2 (game-side only, independent items):**
  1. liquid **levels** (puddles on composites + shallow pure-liquid cells) —
     needs a worldgen moisture/weather source to be visible;
  2. STATE-axis appearance variants (snowy grass, tufted dirt) — the state
     machinery's first render tenant; models per (mat, state) join the
     manifest;
  3. stacked half-slab snow on snowy-biome grass — worldgen + one manifest
     material.
* **Phase 3 (flagged costs):**
  1. thin-layer shape family (FAM bit) — game-wide span math, no engine patch;
  2. curated opaque+opaque combined models IF a concrete need lands —
     identity-semantics design first;
  3. the under-ice covered-top refinement (WATERLOGGING §5 risk 8) — the one
     item here that would need a further **engine** patch
     (`fluid_top_covered` extended to full-bottom-pattern solids).

---

## 4. Risk table

| # | risk | analysis / mitigation |
|---|---|---|
| 1 | **Lava sliver returns** (opaque-fluid culling wrong) | §2.3 table; the two live rules are `culls_neighbors=false` on the pure lava model and the pre-existing equality short-circuit ordering (verified in patched source, `voxel_mesher_blocky.cpp:160-170`). Verify pins a 3×3×3 lava-pool buffer: stone wall face PRESENT, lava-lava faces ABSENT, water-lava boundary faces PRESENT both sides. |
| 2 | **Water↔lava interface hole** via a wrong transparency index | Locked: lava stays index 0. The two rejected index choices and their failure modes are recorded in §2.3 so nobody "simplifies" this later. |
| 3 | **Lava surface cell renders as water** (the latent single-table route) | Kind-keyed `_surface_arid`/twin tables on BOTH native and legacy paths (§2.2.4). Verify: a lava liquid-9 cell's ARID ≠ any water model ARID on both paths. |
| 4 | **GMID drift** from the new VoxelState field | Omit-when-zero in `to_document` (§2.1); verify pins a non-liquid GMID before/after. Water/lava GMID change is safe (never serialized — placement gate + capture strip). |
| 5 | **Hot-ocean byte-flip breaks existing verify sweeps** | Deliberate regime change; sweeps asserting sea==water retarget to `_sea_liquid_kind(t)` (§2.4). The flipped-assert list is Stream B's exit criterion, mirroring WATER-SHORE §8's "expect these, do not weaken". |
| 6 | **Manifest growth / load stall** | ≈ 2× twins (~260 total), zero new ArrayMeshes (shared dry meshes). Setup timing print already exists; trim policy recorded (§2.2.6). Linear in kinds, kinds ≤ 3. |
| 7 | **Worker allocation/race regression** | Same frozen-publish discipline; per-kind arrays hoisted to block-frame locals; tables built+baked on main thread before the generator wires (§2.2.5). |
| 8 | **2-bit kind ceiling** (max 3 liquids) | Documented with the re-layout escape while liquids are unserialized (§2.1). A 4th liquid is a design event, not a silent overflow — `is_liquid_kind_known` strips anything undeclared. |
| 9 | **`find_coast_of(LAVA)` not found** for a given seed | Shore pairs skip; submerged pairs are material-complete regardless → distant lava seas still borderless below the line; unsampled shore pairs degrade to the dry border (standing policy). |
| 10 | **fluid_index nondeterminism** | Fluids registered in ascending kind order; model bake order is library order (LRID order) — both deterministic per session (§2.2.1). |
| 11 | **Emissive fluid material on flow UVs** | The native fluid encodes axis/flow in UVs; water already ships this way with a StandardMaterial3D and looks right — lava uses the same path with the emissive material. Eyeball gate at deploy (§5 integration). |
| 12 | **Legacy engine visuals** | Feature-detection unchanged; legacy = water slab/composites as today + plain emissive lava cubes. Degraded, never a hole, never mis-skinned (§2.2.4). |
| 13 | **Frozen/molten overlap** | Impossible: `t < -0.55` vs `t >= 0.60` are disjoint; `_sea_liquid_kind` is the single regime authority consumed by `_sea_block` and `_with_shore_liquid` alike. |

---

## 5. Implementation checklist — ordered, independent work-streams

Contracts frozen by this doc: the `liquid_kind` blocks.json key + name map;
`LIQ_LAVA := 2`; `is_liquid_kind_known` as rule 6's gate;
`_sea_liquid_kind(t)` + `LAVA_SEA_T := 0.60`; per-kind table shapes in §2.2;
lava = index 0 + `culls_neighbors false` (pure model only).

### Stream A — data model *(owns: `godot/assets/blocks.json`, `godot/src/world/cell_codec.gd`, `godot/src/sim/block_catalog.gd`, `godot/src/sim/voxel_state.gd`, `godot/src/sim/material_document.gd`)*
1. blocks.json: `"liquid_kind"` on water + lava.
2. `VoxelState.liquid_kind` (default 0) + omit-when-zero in
   `MaterialDocument.to_document` (+ GMID-stability pin, risk 4).
3. `BlockCatalog`: parse in `_from_record`; `liquid_kind_of` general;
   `liquid_lrid_of`, `is_liquid_kind_known` (+ load-time validation, §2.1);
   drop `_water_lrid`.
4. `CellCodec`: `LIQ_LAVA`, the kind-name map, rule 6 relaxation (§2.1);
   header comment updated.
5. Gate: codec round-trips (lava on solids kept, kind 3 stripped, bare-lava-id
   canonical full lava), full existing verify green.

### Stream B — worldgen *(owns: `godot/src/world/terrain_config.gd`; after A)*
1. `_ID_LAVA` in `_ensure_ids`; `LAVA_SEA_T`; `_sea_liquid_kind`.
2. `_sea_block` + `_with_shore_water`→`_with_shore_liquid` kind-parameterized
   (§2.4).
3. `find_coast_of(kind)` (water compat wrapper stays);
   `emitted_shore_pairs(kind)` regime-gated; `emitted_submerged_pairs(kind)`.
4. Optional: the `PerVoxelEnvironment` molten-sea seam (sim file, one clause).
5. Gate: regime-retargeted sea asserts (risk 5 list); determinism double-sample
   including bits 48+; byte-identity spot-checks for `t < LAVA_SEA_T`.

### Stream C — module wiring *(owns: `godot/src/world/voxel_module/module_world.gd`; after A, parallel with B against frozen contracts)*
1. `_fluids` per kind (ascending order); `_make_water_fluid` → `_make_fluid(kind)`.
2. `_configure_library` liquid generalization + **`set_culls_neighbors(false)`
   iff opaque fluid** (§2.2.2).
3. Per-kind twin manifest + `_surface_arid` (both engine flavours, §2.2.3-4);
   `_make_waterlogged_model(modifier, material, kind)`.
4. Worker generator + `arid_for_cell` + `gen_arid_for(…, liquid_kind)` route by
   kind, hoisted locals (§2.2.5); publish the new tables.
5. Gate: native run at a water coast (no visual change) and — via a temporary
   teleport — a lava coast: borderless lava, crisp water/lava boundary if
   present, glow, no sliver at steep walls.

### Stream D — engine 0002 hardening *(owns: `docker/engine/patches/godot_voxel/0002-waterlog-copy-hardening.patch`; fully independent)*
1. Author the one-line `copy_base_properties_from` fix (+`is_connected` guard).
2. `scripts/build.sh` (warm); checkpoint: BUILD-INFO lists both patches +
   `module_in_web=yes`; editor + web-template method probe as in
   WATERLOGGING §6.3.

### Stream E — verification *(owns: `godot/src/tools/verify_feature.gd`; after A-C)*
1. Codec: Stream A gates as asserts; canonical-preservation pins extended to
   LIQ_LAVA.
2. Worldgen: locate a molten-sea column deterministically (scan by
   `_sea_liquid_kind`); assert sea-fill lava values (surface 9 / deep bare id),
   shore composite carries (LAVA, 9); frozen + temperate regression unchanged.
3. Module (class-guarded): generated buffer over a lava block maps ARIDs
   through `gen_arid_for(…, LIQ_LAVA)`; lava ARIDs disjoint from water ARIDs;
   anti-drift held.
4. Mesher face-count test (risk 1): 3×3×3 lava pool vs stone wall vs water —
   wall face present, lava-lava culled, boundary faces both drawn.
5. Gate: headless verify exit 0.

### Integration
1. `/steelman` with §2.3's table and the risk table as the attack surface.
2. Export + deploy; DESIGN §7 gate (live site loads, playable); eyeball a lava
   coast in the browser (risk 11).

---

## 6. Decision log (locked by this doc)

1. **Liquids are data**: `blocks.json "liquid_kind"` → `VoxelState.liquid_kind`
   → `BlockCatalog.liquid_kind_of/liquid_lrid_of/is_liquid_kind_known`;
   CellCodec owns the name→value map; `LIQ_LAVA := 2`; unknown kinds strip.
2. **Rule 6 gates on known kinds**, not `<= LIQ_WATER`; rules 1-5 unchanged
   (rule 5 was already generic — bare lava id is canonical full lava).
3. **One `VoxelBlockyFluid` per kind, per-kind twin/surface tables on both
   engine flavours**; legacy engines render non-water liquids as plain cubes
   (degrade, never mis-skin, never a hole).
4. **Lava is transparency_index 0 + `culls_neighbors false` (pure model only;
   twins keep culling)** — the §2.3 audit is the record; no engine change.
5. **Lava placement = the climate-keyed sea regime** (`_sea_liquid_kind`,
   `LAVA_SEA_T 0.60`): frozen / water / molten seas from one function; deep
   lava seas and volcano biomes recorded as rejected-for-v1 alternates.
6. **Manifest growth is linear in kinds** (≤3 by the 2-bit field), ~2× twins
   for water+lava, zero new ArrayMeshes; the kind-field widening path is
   recorded and must precede any liquid serialization.
7. **Part A needs no engine rebuild for the feature**; the 0002
   `copy_base_properties_from` hardening is folded in as an independent stream
   with its own rebuild.
8. **§79 phasing**: puddles = liquid levels (Phase 2); snow/ice layers +
   decorations = stacked cells / STATE-axis variants (Phase 2), thin-layer
   FAM-bit shape family (Phase 3); true two-solids-per-cell only via curated
   baked combos, opaque+opaque only, if a need lands (Phase 3+); a second
   engine data channel stays rejected.
