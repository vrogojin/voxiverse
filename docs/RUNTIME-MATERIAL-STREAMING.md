# VOXIVERSE — Runtime Material Streaming (Design)

> **⚠ Partially superseded — read alongside the authoritative reconciliation.**
> `docs/VOXEL-DATA-STRUCTURE.md` §8.1 replaces the **"reserved upper band" library model**
> (§4.5 / §9.5 / §12) with the **ARID** (Appearance Render ID) table: `add_model() == ARID`,
> with `cube ARID == LRID` asserted for the bootstrap set only. Container payloads adopt VDS §5
> **ZoneChunk** layers (§2.6). The content-addressed `tex:sha256` scheme + async `TextureStore`
> (§5.3 / §9.4) are **future** work owned by the textures workstream (static pipeline stands this
> milestone — `docs/INTEGRATION-DECISIONS.md` §D). The GMID⇄LRID identity model is unchanged and
> authoritative.

Status: **DESIGN — not implemented.** Branch: `feat/voxiverse-sim-extensions`.

This document designs **run-time voxel material streaming**: loading block
materials on the fly, after the world is already running — with no fixed
materials library baked at game start. The drivers (not needed yet, designed
for now):

* **Global world-state persistence + p2p sync** — acquiring a remote world zone
  brings block materials the local client has never seen.
* **Lazy loading at scale** — the Minecraft-parity catalog workstream
  (`docs/WORLDGEN-CATALOG.md`) will produce hundreds→thousands of materials;
  loading them all up-front is neither necessary nor desirable.

Everything here was checked against the **pinned engine source**
(`docker/engine/versions.env`: Godot `4.4.1-stable`, godot_voxel `v1.4.1`,
cached at `docker/engine/cache/godot/modules/voxel/`). Claims about the module
cite that source, not the online docs.

---

## 0. Verified engine facts (godot_voxel v1.4.1)

These facts shape the whole design; each was read from the pinned module
source in `docker/engine/cache/godot/modules/voxel/`:

| # | Fact | Source |
|---|------|--------|
| F1 | `VoxelBlockyLibrary.add_model()` **appends** and returns the new index; it is script-bound. Hard cap `MAX_MODELS = 65536`. | `meshers/blocky/voxel_blocky_library.cpp:113`, `blocky_baked_library.h:22` |
| F2 | `bake()` is script-bound and **re-bakes the entire library** (all models, material re-index, side-culling matrix) under `RWLockWrite(_baked_data_rw_lock)`. It is *not* incremental. | `voxel_blocky_library.cpp:55-101` |
| F3 | The mesher reads baked data under `RWLockRead` on the same lock, so **re-baking while terrain meshing runs is thread-safe** — bake blocks meshing for its duration and vice-versa; no crash, no torn reads. | `voxel_mesher_blocky.cpp:627, 740, 837` |
| F4 | Re-baking **does not invalidate or remesh existing chunks**. Built chunk meshes are plain ArrayMeshes holding their Material refs; because models are append-only, existing voxel ids keep their meaning, and the material indexer (first-seen order over models 0..N) keeps previously assigned material indices stable. | `voxel_blocky_library.cpp:70-92` |
| F5 | The mesher **skips voxel ids ≥ models.size()** — a chunk containing a not-yet-loaded id renders that cell as *invisible* (a hole), it does not crash. | `voxel_mesher_blocky.cpp:25, 157, 215` |
| F6 | The TYPE channel defaults to **16-bit depth** → voxel data can hold ids 0..65535, matching MAX_MODELS. | `storage/voxel_buffer.h:89` |
| F7 | `VoxelTerrain.remesh_all_blocks()` exists in C++ but is **not script-bound**; there is no cheap "remesh everything" from GDScript. (Consequence: never let stale ids get meshed — see §6 gating.) | `terrain/fixed_lod/voxel_terrain.cpp:648` + `_bind_methods` |
| F8 | Upstream precedent: the (experimental) `VoxelBlockyTypeLibrary` pairs the model array with a **serializable id-map** (`serialize_id_map_to_json`, index = model id, value = stable string name) exactly to keep persisted 16-bit data valid across library evolution. We adopt the same pattern in our own layer rather than depending on the experimental class. | `meshers/blocky/types/voxel_blocky_type_library.h:61-90` |
| F9 | Bake cost is O(models): per model, 6 side rasterizations onto a 32×32 grid + pattern dedup (all full cubes share one pattern, so the O(patterns²) culling matrix stays tiny). The O(N²) `generate_library_cutout_sides` pass only runs for models with `cutout_sides_enabled` — **keep that disabled**. | `voxel_blocky_library_base.cpp:679-809, 560-572` |
| F10 | `VoxelTerrain.try_set_block_data(position, voxels)` is script-bound — bulk voxel-data injection for whole zones without per-voxel `VoxelTool` calls. | `voxel_terrain.cpp:2364` |

**Headline conclusion:** the module path supports append-and-rebake at runtime,
safely, with a full-rebake cost that is linear in library size. The design
therefore does **not** need pre-allocated id ranges or library swaps — it needs
(a) a strict *register → model → bake → only then reference* ordering, and
(b) **batched** re-bakes so thousands of arrivals don't trigger thousands of
O(N) bakes.

---

## 1. Goals & non-goals

Goals:

1. A **stable global identity** for materials that survives save/reload and is
   identical across peers, while the engine keeps compact dense ids everywhere
   hot (voxel channel, edit overlay, VoxelBody cells, inventory).
2. Materials **arrive as data** (one self-contained document) over network or
   disk and become placeable/breakable/renderable without a restart, on **both
   render paths**, with identical behaviour.
3. Scale target: **thousands of materials**, no fixed library at game start,
   graceful memory behaviour (texture-level eviction).
4. Preserve the three architectural rules (CLAUDE.md): `block_id_at` stays THE
   cell query; rendering/gameplay keep reading the sim layer; two render paths,
   one behaviour.

Non-goals (explicitly out of scope here, owned by siblings):

* Authoring the actual thousands of materials (→ `docs/WORLDGEN-CATALOG.md`).
* The texture asset pipeline itself (→ textures workstream; we only fix the
  *reference* format, §5.3).
* Non-cube shapes / partial fills (→ `docs/SUB-VOXEL-SMOOTHING.md`; §4.5 states
  the seam).
* The p2p transport, signing, and trust model (we define the payload format and
  the id-translation rule at the boundary, not the wire protocol).

---

## 2. The identity model: GMID ⇄ LRID

### 2.1 Two id spaces, one principle

| | Global Material ID (**GMID**) | Local Render ID (**LRID**) |
|---|---|---|
| What | Content-addressed hash of the material document | Dense int `0..count-1`, allocated per session |
| Form | `"sha256:<64 hex>"` (StringName) | `int` |
| Scope | Universal — same bytes ⇒ same GMID on every peer, forever | This process, this session only |
| Lives in | Serialized data: saves, p2p zone bundles, inventory persistence | Everything hot: voxel TYPE channel, `_edits`, VoxelBody `cells`, Inventory slots, BlockCatalog index, blocky-library model index |
| Allocation | By hashing (no allocator, no coordination) | Append-only counter in the dynamic BlockCatalog |

**The one principle: dense ids never cross a process/session boundary; GMIDs
do.** Every serialized container of voxel data (a save, a p2p zone bundle, a
persisted loose body) carries its own **id-map header** — a string array where
index `i` gives the GMID(+state) that container-local dense id `i` means.
Readers translate container-local ids → their own session LRIDs through the
GMID; writers translate session LRIDs → compact container-local ids. Nobody
ever assumes two containers (or two peers) agree on dense ids.

### 2.2 GMID: content addressing over document bytes

The GMID is `sha256` over the **exact transmitted/stored bytes** of the
material document (§5) — like a git blob. The document is immutable: it is
never re-serialized for hashing (this deliberately sidesteps float/JSON
canonicalization, the classic content-addressing trap). Consequences, accepted:

* Two semantically identical documents that differ in whitespace are two
  different materials. Fine — authors ship one blessed byte-form; the
  WORLDGEN-CATALOG generator is the single producer for the standard set.
* Editing a material (rebalancing mass, new texture) produces a **new GMID** —
  which is correct: old worlds keep referencing the exact material they were
  built with; upgrades are an explicit re-mapping someone performs, not a
  silent mutation.

Documents also carry a human alias (`"name": "voxiverse:basalt"`). Aliases are
**non-authoritative** — display + authoring convenience only; collisions are
legal and harmless because nothing keys on them.

### 2.3 State addressing

Today one BlockCatalog entry == one `VoxelState` (§SIM-MODEL: the catalog is
built on the VoxelState framework), and one blocky-library model == one look.
A streamed material may carry several states (ice/water/steam). Therefore:

* **The unit that gets an LRID is a (material, state) pair**, exactly matching
  the current invariant "one catalog id = one VoxelState = one library model".
* Serialized references are `"<gmid>#<state_name>"` (the fragment defaults to
  the material's default state when omitted).

So a 3-state streamed material consumes 3 LRIDs; `VoxelMaterialDef.resolve_state`
switching a voxel's state maps to writing a different LRID into the cell —
no new mechanism, the state machine's output is already a block id
(`VoxelState.block_id`).

### 2.4 Session table (the core data structure)

`BlockCatalog` (made dynamic, §6.1) owns one append-only table:

```gdscript
# index == LRID (dense). Entry 0 is reserved: AIR.
var _states:  Array[VoxelState]     # the sim/physics/look record (null for AIR)
var _keys:    PackedStringArray     # "<gmid>#<state>" per LRID ("" for AIR)
var _defs:    Array[VoxelMaterialDef]  # owning material def per LRID (shared across its states)
var _by_key:  Dictionary            # "<gmid>#<state>" -> int LRID  (reverse index)
var _status:  PackedByteArray       # per LRID: RESOLVED | UNRESOLVED (placeholder, §8)
```

Registration is idempotent: registering a (gmid, state) already in `_by_key`
returns the existing LRID and changes nothing. LRIDs are **never recycled and
never reordered within a session** (§7.4) — the table only grows, which is what
makes F4 (append-only ⇒ old chunks stay valid) hold end-to-end.

### 2.5 Bootstrap set and migration of the six consts

`BlockCatalog.AIR..LEAF` (0..5) stop being the *definition* of identity and
become the **bootstrap set**: six well-known material documents shipped with
the game, registered first thing at startup **in const order**, so their LRIDs
land exactly on today's consts (assert this — it keeps every existing call
site, the generator, and `verify_feature.gd` valid during migration). Their
GMIDs are pinned in one place (`sim/bootstrap_materials.gd`) next to their
alias names (`voxiverse:air`, `voxiverse:grass`, …). `AIR == 0` is a permanent
reserved LRID and has a reserved pseudo-GMID (air is absence, it has no
document; id-maps write the literal `"air"` at index 0).

The WORLDGEN-CATALOG workstream's hundreds of materials are *not* bootstrap:
they ship as ordinary material documents in a local content store and load
through the same streaming path (its worldgen needs a manifest — §6.5).

### 2.6 Id stability across save/reload and across peers

* **Save:** the writer walks the data being saved, collects the set of LRIDs
  actually referenced, assigns compact container-local ids `0..k` in
  first-encountered order, writes the id-map header (`k+1` strings) and the
  translated data. Saves are therefore self-describing and independent of
  session load order, and dead LRIDs (materials loaded but never used) don't
  bloat or pin anything.
* **Load:** for each id-map entry, ensure the material is registered (fetch
  from the content store by GMID; placeholder if missing, §8), then build the
  `container-id → session LRID` translation array and rewrite ids on the way
  in. O(1) per voxel via a flat `PackedInt32Array`.
* **Peers:** identical rule — a zone bundle is just a container. Two peers
  *always* have different LRID tables; it never matters because LRIDs never
  travel.
* **Payload layout (revised — VDS §5):** the container's voxel data payload
  now adopts `docs/VOXEL-DATA-STRUCTURE.md` §5 **ZoneChunk** layers rather than
  one flat id-remapped body. Each ZoneChunk carries its **own material palette**
  of container-local ids (one palette per 32³ chunk, resolved through this
  section's id-map header), plus the optional sparse modifier/state/metadata
  layers. The container-local palette *is* the "compact on save" mechanism, now
  scoped per chunk instead of per container body. The **id-map header
  (index → GMID#state string) is unchanged** — it remains the one place a
  container-local id is bound to a global identity; per-chunk palette ids index
  into it. (VDS §13.2.4.)

Rejected alternative — *deterministic global dense ids* (e.g. sort by GMID):
would force renumbering (= full-world remap + remesh, impossible per F7) every
time a lazily-loaded material arrives "in the middle" of the ordering. Append
order is the only order that never invalidates anything.

---

## 3. Render path A: godot_voxel module (`module_world.gd`)

### 3.1 Mechanism: append + batched re-bake

Chosen mechanism (per F1–F4): **grow the one live library, re-bake in
batches.** No pre-allocated dummy-model ranges (wasted bake cost per F9, and
appends are cheap anyway), no library rebuild-and-swap (needless — the RWLock
already makes in-place bake safe, and a swap would orphan the mesher's ref).

`module_world.gd` gains:

```gdscript
var _lib: Object                    # the VoxelBlockyLibrary, kept from setup()
var _lib_model_count: int           # models appended so far (== catalog count after flush)
var _baked_model_count: int         # models covered by the last bake()
var _bake_pending := false

## Called by WorldManager when the catalog grew. Appends one cube model per new
## LRID (same _add_cube as setup, material from BlockMaterials.get_for(lrid))
## and asserts the returned model index == the allocated ARID — the library-order
## invariant (VDS §8.1), now enforced at runtime, forever. (For the bootstrap
## cube set, ARID == LRID; see the supersession banner.)
func append_models_up_to(catalog_count: int) -> void: ...

## Deferred, coalesced: one bake() per frame at most, regardless of how many
## models arrived (F2: bake is a full O(N) rebake — never per-model).
func _flush_bake() -> void:
    _lib.call("bake")
    _baked_model_count = _lib_model_count

## True when `arid` (an appearance render id, VDS §8.1) is safe to write into
## the voxel TYPE channel.
func can_render(arid: int) -> bool:
    return arid < _baked_model_count

## The gameplay-facing gate: is this cell's *composed appearance* baked yet?
## Resolves (material, modifier, visual-state) → ARID (VDS §8.1) then checks it.
## Replaces the old bare-LRID `can_render_id`, so the gate now covers shaped and
## visual-state combos, not just plain cubes.
func can_render_cell(mat: int, modifier: int, vstate: int) -> bool:
    var arid: int = arid_of(mat, modifier, vstate)   # -1 until baked
    return arid >= 0 and can_render(arid)
```

Ordering protocol (the load pipeline, §7, enforces it): **catalog/appearance
register → append model → bake → only then may that appearance (ARID) be written
into voxel data.** `_paint_cell` gates on `can_render_cell` (the composed
appearance), **not** on the bare LRID — a cell whose material is baked but whose
shape/visual-state combo is not yet baked must not be painted. Because both the
catalog and the library are append-only and fed from a single main-thread loader,
indexes stay in lockstep by construction; the runtime assertion makes drift a
loud failure instead of a silently recoloured world
(the exact failure mode the current `_configure_library` assert guards).

### 3.2 Costs, and the web single-thread cap

* `add_model()` — O(1) push_back, negligible.
* `bake()` — full rebake, O(models) with a small constant (F9: 6 × 32×32
  raster per model; all full cubes share one culling pattern). Estimate at
  4096 cube models: ~25M point-in-triangle tests + geometry copies — order
  tens of ms native, plausibly 100–300 ms on wasm. **Mitigations, in order:**
  1. **Batch**: one bake per arrival burst (deferred call), so a 200-material
     zone costs one bake, not 200.
  2. **Front-load**: a zone bundle's manifest registers all its materials
     before its voxel data is injected — one bake per zone.
  3. Keep `cutout_sides_enabled` off (F9's O(N²) trap).
  4. If profiling ever shows bake stalls at high counts (>~8k), the escape
     hatch is sharding *textures* into atlases so many GMIDs share few models —
     an optimization of the look layer only; identity/LRID model unchanged.
* **Web threading:** bake runs on the caller's thread (main). It takes the
  write lock; the single voxel worker (pool capped to 1 on Emscripten — see
  `module_world.gd` header) blocks on its read lock only for the bake duration,
  then resumes. No deadlock possible (two plain RWLock parties, no nesting, no
  re-entry). The cost is a main-thread hitch per batch — acceptable at zone
  granularity; measured by the Phase-4 benchmark (§10).

### 3.3 Already-meshed chunks

Appending models never changes existing ids' meaning (F4), so **no remesh is
ever required by a material arrival** — provided the gating rule held (no LRID
written before bake). If gating is ever violated, F5 says the symptom is an
invisible cell, and the recovery is re-writing that cell via `set_cell` (a
local remesh), not a global remesh (F7 makes global remesh unavailable anyway).
The design treats F5 as a safety net, not a mechanism.

### 3.4 Bulk zone injection

Zones arriving over p2p inject via `try_set_block_data` (F10) after id
translation (§2.6), not via per-voxel `VoxelTool` calls. Cells that overlap the
current session's `_edits` overlay resolve in favour of the overlay (overlay is
THE truth per rule 1; zone data is "generated/base" layer input — final
semantics belong to the persistence workstream, flagged §9.3).

---

## 4. Render path B: GDScript fallback, VoxelBody, and the sub-voxel seam

### 4.1 Fallback mesher/streamer — already dynamic

`ChunkMesher` keys SurfaceTools by whatever int comes out of
`world.block_id_at()` and resolves looks via `BlockMaterials.get_for(id)`; it
has **no** count-based assumptions. `ChunkStreamer` doesn't know ids exist. The
only changes: `BlockMaterials` goes registry-backed (§6.2) and gains the same
`can_render_cell()` gate trivially satisfied (no bake step — a shaped/visual-state
appearance is renderable the moment its `ShapeMesh`/material variant exists).
Both paths therefore expose one predicate with one meaning; gameplay code gates
on `WorldManager.can_render_cell()` which delegates to the active path.
**Two paths, one behaviour, preserved.**

### 4.2 VoxelBody

`VoxelBody` reads `BlockCatalog.mass_of(id)` and `BlockMaterials.get_for(id)`
per cell — both become dynamic-catalog reads with unchanged signatures, so
loose bodies support streamed materials with **zero changes** to
`voxel_body.gd`. The wood special-case (`_has_wood()` keys sandbox-dynamics on
`BlockCatalog.WOOD`) generalizes to a `VoxelState` boolean
(`sandbox_dynamic: bool`, carried in the document's physics block) — flagged
as a shared field with the structural-integrity workstream (§9.1). Persisted
loose bodies serialize `{local_cell: container_id}` + id-map, same container
rule as everything else.

### 4.3 Inventory & hotbar

`Inventory` slots hold LRIDs — correct and unchanged in-session. The hotbar
reads names/colours through the catalog (dynamic, same API). Inventory
**persistence** writes GMID#state strings per slot (inventories are tiny;
skip the id-map indirection). An inventory slot whose material is UNRESOLVED
renders the placeholder swatch and stays placeable (§8 — placing places the
placeholder LRID, which is the *same identity*, so when the real document
arrives the cells are already correct).

### 4.4 `place_block` / validity checks

Every `>= BlockCatalog.COUNT` range check (e.g. `WorldManager.place_block`,
`BlockCatalog.is_solid_id`) becomes a catalog lookup:
`BlockCatalog.is_valid_id(id)` = `id > 0 and id < catalog.count()`, **plus**
the render gate `can_render_cell(mat, modifier, vstate)` on the composed
appearance before painting. `COUNT` the const is
retired in favour of `BlockCatalog.count()` (Phase 1 keeps a deprecated alias
so diffs stay small).

### 4.5 Seam: sub-voxel partial fills

Per `docs/SUB-VOXEL-SMOOTHING.md` (parallel workstream), partial cells carry
shape+orientation *beyond* a bare id. This design's contract with it:

* **LRID/GMID identify material only.** Shape/orientation is a separate
  per-cell payload (its own channel / parallel overlay — that doc's call), so
  the id spaces here never fork per shape variant. (Anti-goal: minting an LRID
  per (material × shape × orientation) — with thousands of materials that
  multiplies straight into the 65k ceiling, F1/F6.)
* If sub-voxel rendering on the module path is realized as extra blocky models
  (e.g. N shape models per material), those models are **look-layer entries
  above the material LRID space**: ~~allocated in a reserved upper band of the
  library and mapped (LRID, shape) → model index by the sub-voxel layer
  itself~~. Serialized data still stores (material id-map entry + shape payload),
  never raw model indices.
  > **Superseded (VDS §8.1):** the "reserved upper band" is retired — shape and
  > visual-state models interleave in the one append-only model space as **ARIDs**
  > (one per used `(LRID, modifier, visual-state)` combo, `add_model() == ARID`
  > asserted), lazily allocated rather than pre-banded. The identity contract
  > above (id spaces never fork per shape; serialized data carries material +
  > shape payload, never model indices) is unchanged and confirmed.

---

## 5. The material document (serialization / transport format)

### 5.1 Requirements

One self-contained, immutable byte blob per material that (a) hashes to its
GMID, (b) reconstitutes a `VoxelMaterialDef` + its `VoxelState`s +
`VoxelStateTransition`s fully, (c) references textures indirectly by
content-addressed asset id, (d) degrades gracefully when assets are missing.

### 5.2 Format

UTF-8 JSON (readable, diffable, hash-over-bytes per §2.2 so canonicalization
is a non-issue). Top-level:

```json
{
  "voxiverse_material": 1,
  "name": "voxiverse:basalt",
  "default_state": "solid",
  "state_layout": [],
  "visual_mask": 0,
  "has_block_entity": false,
  "states": [
    {
      "name": "solid",
      "physics": {
        "mass": 2900.0, "density": 2900.0, "break_force": 3200.0,
        "permeability": 0.0, "albedo": 0.12,
        "translucence": 0.0, "emission": 0.0, "solidity": 1.0,
        "sandbox_dynamic": false,
        "structural_class": "rock",
        "strength_anchors": [74, 7, 4],
        "priors": { "analog": "rock", "C": 120.0, "T": 12.0 }
      },
      "look": {
        "swatch": [0.20, 0.19, 0.22, 1.0],
        "texture": "tex:sha256:9f2a…c41",
        "tint": [1.0, 1.0, 1.0, 1.0],
        "glow": 0.0
      },
      "transitions": [
        { "to": "molten", "field": "temperature",
          "cmp": ">=", "threshold": 984.0 }
      ]
    },
    {
      "name": "molten",
      "physics": { "mass": 2650.0, "density": 2650.0, "break_force": 50.0,
                   "permeability": 0.6, "albedo": 0.05,
                   "translucence": 0.1, "emission": 4.0, "solidity": 0.8,
                   "sandbox_dynamic": false,
                   "structural_class": "rock",
                   "strength_anchors": [4, 1, 1], "anchors_override": true,
                   "priors": { "analog": "rock", "C": 6.0, "T": 0.5 } },
      "look": { "swatch": [0.95, 0.35, 0.05, 1.0],
                "texture": "tex:sha256:77b0…e02",
                "tint": [1.0, 1.0, 1.0, 1.0], "glow": 3.0 },
      "transitions": [
        { "to": "solid", "field": "temperature", "cmp": "<", "threshold": 900.0 }
      ]
    }
  ]
}
```

Mapping is 1:1 onto the existing resources: each `states[i]` →
`VoxelState` (every `@export` in `voxel_state.gd` §Physics/§Look has a key;
unknown keys are ignored — forward compatibility; missing keys take the
resource's default), each `transitions[j]` → `VoxelStateTransition`
(`cmp` ∈ `">", ">=", "<", "<="` → the Comparator enum), the document →
`VoxelMaterialDef` (its `id` = the alias name; the registry keys on GMID,
§6.3). `VoxelState.block_id` is **not** serialized — it *is* the LRID,
assigned at registration; a document never contains dense ids.

**Structural-integrity fields (physics block; `docs/INTEGRATION-DECISIONS.md`
Decision A).** The gameplay-facing strength truth is stored, not derived at
runtime:

* `strength_anchors: [P, H, D]` — the anchor triple (max pillar height, max
  horizontal shelf, max dangling depth; three small ints, SI §7). This is what
  the solver calibrates against; `σ_c/σ_t/σ_s` and joint capacities are
  **computed** from anchors + mass, never stored.
* `structural_class` — a StringName selecting the converter branch and
  `κ_class` (e.g. `"rock"`, `"timber"`, `"brittle"`, `"soil"`, `"granular"`,
  `"fluid"`, `"bedrock"`).
* `priors` — the physical priors `(analog, C [MPa], T [MPa])` for stress-governed
  materials, or `cohesion c [kPa]` for soils. Retained as **provenance** so
  anchors can be re-proposed if mass is rebalanced; they feed the offline
  converter (INTEGRATION-DECISIONS §1.2/§1.3) that *proposes* anchors.
* `anchors_override: bool` (optional, default `false`) — set `true` when the
  stored anchors are hand-tuned away from the converter's proposal (molten,
  above). `verify_feature.gd`'s **drift gate** asserts
  `propose_anchors(priors, class) == strength_anchors` for every record **not**
  so flagged, keeping priors and anchors from silently diverging.
* `attachment: float` — the **joint participation multiplier** (SI §7 /
  INTEGRATION-DECISIONS §1.4), *not* a strength. Default `1.0` (composed as
  `att_A · att_B` on tension/shear/moment capacities only — never the
  compression path); it **appears in the document only when ≠ 1.0**, and in v1
  is non-default solely for `sand`/`gravel` (`0.0`, so undercut granular cells
  do not hang). The old scalar `A` (0..1) column from WGC §3.4 is superseded and
  is *not* this field.

**State/appearance keys (top level; VDS §10.3).** `state_layout` (an ordered
list of `{name, bits}` packed LSB-first, default `[]`), `visual_mask` (which
state bits affect appearance, default `0`), and `has_block_entity` (whether
cells of this material may carry metadata, default `false`) are
forward-compatible: old documents omit them and keep their GMIDs; old engines
ignore them (§2.2 hash-over-bytes is unaffected). Basalt above declares the
trivial defaults; a facing/lit machine would populate `state_layout` and
`visual_mask` per VDS §10.3.

Validation on ingest (before registration): schema version supported, ≥1
state, `default_state` exists, transition targets exist, all numerics finite,
`mass > 0` for `solidity > 0` states, states count sane (cap: 16). A document
failing validation is rejected whole (→ requester keeps/creates the
UNRESOLVED placeholder for its GMID, §8) — never half-registered.

### 5.3 Texture references (seam with the textures workstream)

> **Future work (INTEGRATION-DECISIONS §D):** the content-addressed
> `tex:<algo>:<hash>` scheme and the async `TextureStore` described below are a
> **forward seam owned by the textures workstream**, not this milestone. The
> **static** texture pipeline stands for now (CC0 pack → deterministic bake →
> committed `pack/<name>.png` → `BlockTextures.TILES`, `docs/TEXTURES.md`); the
> stable material-name file keys it uses are exactly what a content-addressed
> store will hash, so nothing here needs to change to adopt it later.

`look.texture` is a content-addressed asset id, format
`tex:<algo>:<hash-hex>` (assumed `sha256`; **flagged assumption** — the
textures workstream owns the id scheme and must confirm or amend). Contract
this design needs from that workstream's asset store:

```gdscript
# TextureStore (owned by textures workstream)
func request(asset_id: StringName) -> void         # async fetch/decode
signal ready(asset_id: StringName, tex: Texture2D) # main-thread delivery
func get_if_loaded(asset_id: StringName) -> Texture2D  # nullable
```

Texture arrival is **decoupled from material registration**: a material is
fully registered, placeable, and meshable before its texture exists locally —
its per-LRID `StandardMaterial3D` simply shows the placeholder pattern tinted
with `look.swatch` until `ready` fires, at which point the texture is swapped
**into the existing Material instance** (`albedo_texture = tex`). Because
every consumer (module library model, fallback mesher surface, VoxelBody
surface) holds a ref to that *same* shared Material (BlockMaterials contract),
the swap takes effect everywhere instantly — **no re-bake, no remesh** (the
bake indexes Material *references*, not their contents — F2/F4). This
texture-swap-in-place trick is also the eviction mechanism (§7.3).

---

## 6. Registry, catalog, environment: making the sim layer dynamic

### 6.1 `BlockCatalog` → dynamic, same façade

The static consts+arrays become the session table of §2.4 behind the **same
static API** (`state_of`, `mass_of`, `color_of`, `name_of`, `is_solid_id` —
signatures unchanged), so the rule "everyone reads ids/masses/looks from
BlockCatalog" survives untouched; callers cannot tell the catalog grew at
runtime. Added:

```gdscript
static func count() -> int
static func register_material(gmid: StringName, def: VoxelMaterialDef) -> PackedInt32Array
    # one LRID per state, in document order; idempotent per (gmid, state)
static func lrid_of(key: StringName) -> int          # "<gmid>#<state>" -> LRID | -1
static func key_of(lrid: int) -> StringName          # LRID -> "<gmid>#<state>"
static func is_resolved(lrid: int) -> bool           # false for placeholders (§8)
signal grew(new_count: int)   # via a tiny relay object (statics can't emit) —
                              # WorldManager listens and drives §3.1 append+bake
```

Thread-safety: registration is **main-thread-only** (the loader lives there).
Cross-thread readers exist (the module generator samples the catalog on the
voxel worker thread), and a growing GDScript `Array` may *reallocate* under a
concurrent reader — so the table arrays are **preallocated to fixed capacity**
(`resize(MAX_MODELS)`, ≈0.5 MB of pointers — cheap) and never resized again;
`count` is published (plain int store) only *after* the row is fully built.
This extends today's `ensure_ready()` warm-up discipline to runtime growth;
additionally the manifest gate (§6.5) guarantees the generator only ever reads
rows registered before the render path activated.

### 6.2 `BlockMaterials` → per-LRID stable Material instances

Cache becomes catalog-backed: on miss, build a `StandardMaterial3D` from the
state's look (swatch/tint immediately; texture when `TextureStore` delivers).
The instance per LRID is **permanent for the session** — it is the stable
anchor that makes texture swap-in/out (§5.3, §7.3) propagate everywhere for
free. The grass/wood procedural builders remain the bootstrap materials'
"texture source" (they short-circuit the TextureStore).

### 6.3 `MaterialRegistry`

Gains a GMID index alongside the alias index; `build_default()` becomes
"register bootstrap set"; new `register_document(bytes) -> gmid` runs
§5.2 validation → constructs resources → `BlockCatalog.register_material` →
stores the raw bytes in the local content store (so this peer can re-serve or
re-hash them — the bytes are the identity, keep them). The registry is where
`resolve_state` lookups already happen; unchanged otherwise.

### 6.4 `PerVoxelEnvironment` — unchanged

Environment fields are functions of *position*, not of material identity;
nothing in `per_voxel_environment.gd` reads the catalog. Streamed materials
plug into the environment exclusively through their transitions (which consume
`sample()` — already generic). No change. (When a future field wants
material-dependent behaviour — e.g. thermal conductivity — it reads the
VoxelState through the catalog like everyone else; still no special-casing.)

### 6.5 The generator manifest (gating rule for worldgen)

The runtime-compiled module generator (and `TerrainConfig.generated_cell`)
emit enriched cells for terrain/trees. Rule: **a generator declares its
appearance manifest — the exact set of `(material, modifier)` pairs it may emit
(not just the bare material set) — and `WorldManager` activates the render path
only after that manifest is registered *and* baked** (so every ARID the
generator can produce, VDS §8.1, exists before the voxel worker can reference
it). Today the manifest is the bootstrap set of plain cubes (trivially satisfied
in `_ready`). When WORLDGEN-CATALOG lands its worldgen (hundreds of materials)
and SUB-VOXEL lands terrain smoothing (surface cells carry modifiers, VDS §4.2),
its biome generator declares the full `(material, modifier)` appearance set and
they stream+bake once before terrain starts — "no fixed library at start" means
*no library baked before its appearance manifest is known*, not "terrain may
reference appearances that aren't baked". Extends VDS §8.3's appearance-manifest
gate.
*Assumption flagged for WORLDGEN-CATALOG: worldgen appearances — materials ×
the smoothing shapes they emit — are enumerable per-generator (per-biome-set)
ahead of chunk generation.*

---

## 7. Lifecycle: load → use → evict

### 7.1 States of a material (per GMID)

```
UNKNOWN ──request──▶ FETCHING ──bytes──▶ VALIDATING ──ok──▶ REGISTERED (LRIDs live)
   ▲                    │                    │                   │
   │                 timeout/fail          reject             append+bake (module)
   │                    ▼                    ▼                   ▼
   └───────────── UNRESOLVED (placeholder LRIDs, §8) ──late bytes──▶ RESOLVED
                                                     RESOLVED ⇄ look evicted/restored (§7.3)
```

Triggers for `request`: a container id-map names an unknown GMID (save load,
zone arrival); a generator manifest names one; UI/debug preloads one. All
ingestion funnels through one main-thread `MaterialLoader` that owns dedupe,
the bake batcher (§3.1), and the content store.

### 7.2 Memory budget (why eviction targets textures only)

Per (material, state), steady-state costs: VoxelState + def + strings
(~0.5 KB), catalog/table row (~0.1 KB), blocky **baked model** (~2–6 KB),
StandardMaterial3D (~0.5 KB), **texture** (64×64 RGBA ≈ 16 KB now; 256²+
mipped later ≈ 350 KB+). At 4096 states: sim+library ≈ 15–30 MB (fine, keep
resident); textures ≈ 64 MB → 1.4 GB (the actual pressure, especially under
the wasm heap).

### 7.3 Eviction = drop looks, never identity

* **Never evicted:** catalog rows, VoxelStates (physics — the sim must answer
  `mass_of` for any cell that exists), baked models, Material instances,
  LRIDs. Identity and behaviour are permanent for the session.
* **Evicted:** texture pixel data. Far-zone eviction sets
  `material.albedo_texture = placeholder` (same in-place swap as §5.3 —
  instant, global, no rebake/remesh) and releases the Texture2D to the
  TextureStore's LRU. Policy input: distance of the nearest chunk/zone/body
  using the LRID (the persistence workstream's zone index provides this;
  until then, a simple LRU over `TextureStore` is sufficient — flagged seam).
* This is effectively **material LOD**: near = textured, far/evicted = swatch
  colour — visually reasonable because the swatch is mandatory (§5.2).

### 7.4 The id-recycling problem, resolved by construction

In-session recycling is **forbidden**: freeing LRID *n* while any chunk mesh,
voxel buffer, VoxelBody, or inventory slot still holds *n* would recolour it
on reuse (the exact "silently recoloured world" failure the current assert
exists to prevent) — and F7 means we couldn't even remesh our way out.
Growth is bounded and cheap: even 10,000 session-loaded states cost ~30 MB of
permanently-resident non-texture data, far under the ceiling of 65,536
(F1/F6). **Compaction happens only at the serialization boundary** (§2.6:
saves write compact container-local ids), so the *next* session starts dense
again. If a pathological session ever approaches the 16-bit ceiling, the
loader refuses further registrations with a loud error (and the honest answer
is: restart — a mid-session full renumber is designed out on purpose).

---

## 8. Failure & degradation modes

| Failure | Behaviour |
|---|---|
| **Material document unfetchable** (zone references GMID nobody serves / timeout) | Register an **UNRESOLVED placeholder** under that exact GMID: one LRID per state named by id-map entries, default physics (mass 1000, break_force 1000, solidity 1), magenta-checker look. World data loads *losslessly* — cells keep their true identity (the GMID), only behaviour/look are provisional. |
| **Late resolution** | When real bytes arrive, validate → fill the *existing* LRIDs in place (states matched by name; document states not referenced by any id-map get fresh LRIDs). Physics updates live; look updates via texture swap. No remesh needed — model geometry (cube) is unchanged. |
| **Document fails validation / hash mismatch** (bytes don't hash to the requested GMID) | Reject whole; stay UNRESOLVED; log with both hashes. Never trust a peer's claimed GMID — always re-hash received bytes. |
| **Texture missing/slow** | §5.3: swatch-tinted placeholder, swap-in on arrival. |
| **`add_model` returns index ≠ ARID** (library-order drift; ARID per VDS §8.1) | Assert/crash in dev; in release: push_error + hard-disable further streaming (frozen library is safe; drifted library recolours the world — worse). |
| **Cell painted before bake** (gating bug) | F5: invisible cell, no crash. Detected by a debug check in `_paint_cell` (`can_render_cell`); repaired by re-painting the cell after the batch bake. |
| **Library full** (65,536) | Loader refuses registration (loud); placeholder path keeps data lossless. Practically unreachable (§7.4). |
| **Two documents, same alias** | Irrelevant — aliases are display-only (§2.2). |
| **Same document loaded twice / from two zones** | Same bytes ⇒ same GMID ⇒ idempotent registration ⇒ same LRIDs. Free dedup. |

---

## 9. Interactions & flagged assumptions (sibling seams)

### 9.1 Structural integrity (`docs/STRUCTURAL-INTEGRITY.md`)
Structural parameters ride in the document's `physics` block (§5.2, ratified by
`docs/INTEGRATION-DECISIONS.md` Decision A): `strength_anchors: [P,H,D]`,
`structural_class`, optional `anchors_override`, the `priors` provenance block,
and `attachment` (the joint participation multiplier, §1.4 — *not* a durability
scalar). `VoxelState` exports these as plain numerics, so streaming carries them
unchanged; `break_force` stays the tool-facing mining-effort number (SI §4
orthogonality). `sandbox_dynamic` (§4.2) is ratified there. The offline anchor
converter and the drift gate live in tooling/`verify_feature.gd`, not in this
load path. **No impact on the id model.**

### 9.2 Minecraft-parity catalog (`docs/WORLDGEN-CATALOG.md`)
Assumed: (a) it emits its hundreds of materials as §5.2 documents (it is the
primary producer and the primary scale test); (b) its aliases use a namespace
(`mc:` suggested); (c) its worldgen can enumerate a per-generator manifest
(§6.5); (d) it does **not** hardcode new dense consts — new materials get ids
only via registration. If it wants stable *human* ordering for creative-menu
UI, that's a display sort, not an id ordering.

### 9.3 Persistence / p2p (future workstream)
This doc defines the container rule (§2.6), the id-map header, and bulk inject
(§3.4). Assumed open questions left to it: zone↔overlay merge semantics,
content-store layout, who serves material bytes (inline in bundle vs
fetch-by-GMID — the format supports both: a bundle MAY inline documents,
receivers MUST re-hash), signing/trust.

### 9.4 Textures workstream
Assumed: `tex:<algo>:<hash>` ids (§5.3), the 3-member TextureStore contract,
and LRU + placeholder ownership living there. This design's only hard need:
**texture identity is content-addressed and texture delivery is async and
main-thread.** Per INTEGRATION-DECISIONS §D this content-addressed store +
async `TextureStore` are **future** work owned by that workstream; the static
pipeline (`docs/TEXTURES.md`) is the current milestone.

### 9.5 Sub-voxel (`docs/SUB-VOXEL-SMOOTHING.md`)
§4.5: material id ≠ shape; shape payload is separate; per-shape blocky models
are **ARIDs** in the one append-only model space (VDS §8.1 — the reserved-band
model is superseded) and never appear in serialized data.

---

## 10. Phased implementation plan

**Phase 1 — Dynamic catalog under the same façade** (no behaviour change)
`BlockCatalog` → session table (§2.4/§6.1) with bootstrap set registered in
const order; retire `COUNT` behind `count()`; range checks → `is_valid_id`;
`BlockMaterials` → catalog-backed with stable per-LRID instances;
`MaterialRegistry.register_document` + validation; GMID hashing + content
store (bytes in `user://materials/<gmid>`). Verify: all existing
`verify_feature.gd` green (bootstrap LRIDs == old consts).

**Phase 2 — Runtime library growth (module path)**
`grew` signal → `append_models_up_to` + batched `bake()` (§3.1);
`can_render`/`can_render_cell` on both paths + gate in `_paint_cell`/`place_block`;
runtime library-order assert (`add_model() == ARID`). Verify: register a synthetic
material mid-run, place/break/collapse it
on **both** paths headlessly.

**Phase 3 — Containers: id-map save/load**
Container writer/reader (§2.6) for the edit overlay + loose bodies + inventory
(GMID strings); compact-on-save; translate-on-load; placeholder path (§8) incl.
late resolution filling LRIDs in place.

**Phase 4 — Scale & eviction**
Bake-cost benchmark (register 1k/4k/8k synthetic materials; assert one bake per
batch; record ms — native + web); TextureStore integration + swap-in/out
eviction; wasm-heap measurement at 4k materials. Tune batch/debounce.

**Phase 5 — Zone bundles (p2p-ready payloads)**
Bundle format = manifest (inline docs or GMID refs) + id-map + voxel data;
ingest via translation + `try_set_block_data`; re-hash verification. (Actual
transport: persistence workstream.)

---

## 11. Extending `verify_feature.gd` (new invariants to assert)

Add, following the existing `_ok()` pattern (each phase lands its block):

1. **Bootstrap stability:** after init, `count() >= 6` and
   `lrid_of("<grass-gmid>#grass") == 1` … `== 5` for all five (the const
   compatibility invariant); `key_of(0) == "air"`.
2. **Idempotent registration:** register the same synthetic document bytes
   twice → identical `PackedInt32Array` both times; `count()` unchanged after
   the second.
3. **Runtime library-order invariant (module path only, skipped on fallback):**
   for each newly appended model, the module's returned model index == the
   allocated ARID (VDS §8.1; == LRID for the bootstrap cube set) — surface the
   assert's result to the test — and `can_render_cell(mat, 0, 0)` flips
   false→true across the batch bake.
4. **Bake batching:** register N=32 materials in one frame → module bake
   counter increments by exactly 1.
5. **Live loop with a streamed material:** register synthetic "testium"
   (mass 1234), `place_block` succeeds only after `can_render_cell`;
   `block_id_at` returns its LRID; `break_terrain` returns it; a spawned
   VoxelBody of it has `mass == 1234`; hotbar name/colour read through the
   catalog.
6. **Container round-trip:** build edits referencing bootstrap + testium →
   serialize (assert id-map is compact: only referenced entries, index 0 =
   "air") → reset catalog to bootstrap-only in a fresh `BlockCatalog` table →
   load → assert every cell's `key_of(block_id_at(cell))` equals the
   pre-serialization key (GMID-level equality, *not* LRID equality — assert
   the LRIDs may legitimately differ by loading testium late so its LRID
   moves).
7. **Placeholder degradation:** load a container naming an unavailable GMID →
   cells solid, `is_resolved()==false`, `mass_of` == default, name renders;
   then feed the real bytes → same LRIDs now resolved, mass updated, world
   unchanged.
8. **Rejection:** a document whose bytes don't hash to the requested GMID, and
   a malformed document (missing default state), both leave `count()`
   unchanged and the GMID unresolved.
9. **Transitions:** a 2-state streamed material with a temperature transition:
   `resolve_state` at a hot sample returns the state whose `block_id` is the
   second LRID (state machine ↔ LRID mapping intact).

---

## 12. Adversarial review — how this breaks

* **Id collision across peers.** Two peers "colliding" on an LRID is the
  *normal case* and harmless — LRIDs never travel (§2.1). A GMID collision
  requires a sha256 collision; out of scope. The realistic attack is a peer
  sending bytes that don't match the GMID it advertises — countered by
  mandatory re-hash on receipt (§8). Alias collisions are cosmetic by design.
* **Library-order drift.** The single deadliest failure inherited from today
  (a swap silently recolours the world). Countered by: single main-thread
  loader as the only writer to both append-only sequences, the runtime
  `add_model() == ARID` assert (VDS §8.1), and streaming hard-disable on
  violation (§8). Residual risk: a *future* contributor adding a model to the
  library outside the loader (e.g. a sub-voxel shape model) — now bounded by the
  ARID discipline (VDS §8.1 supersedes §4.5's reserved-upper-band model: shape/
  visual-state models interleave in the one append-only model space, each with
  `add_model() == ARID` asserted); the assert catches an out-of-band append in
  dev.
* **Chunk meshed before its material loads.** Cannot happen from worldgen
  (generator manifest gate, §6.5) or from edits/zones (paint gate on
  `can_render_cell`, §3.1). If a gating bug ships anyway, F5 bounds the damage
  at invisible cells + a logged error, repaired by local repaint — never a
  crash, never wrong-material rendering.
* **Web thread starvation.** The two hazards: (1) bake holding the write lock
  stalls the single voxel worker — bounded by batching (one O(N) bake per
  burst) and measured in Phase 4; (2) doing fetch/decode/hash on the main
  thread — sha256 of a ~4 KB document is trivial, texture decode is the heavy
  part and is the TextureStore's async problem (§9.4). Worst realistic case is
  a one-frame hitch per zone arrival.
* **Bake grows O(N) forever.** At 8k+ models a single bake may reach hundreds
  of ms on wasm — every *later* small arrival pays for the whole library
  (F2, non-incremental). Mitigations in §3.2; the honest unresolved risk is
  that upstream has no incremental bake, so if measurements at target scale
  are bad, the fixes are atlasing (fewer models than GMIDs) or an upstream
  patch — both flagged early by the Phase-4 benchmark rather than discovered
  in production.
* **Placeholder physics is wrong physics.** An UNRESOLVED material's default
  mass/break_force can differ wildly from the truth → collapse/push behaviour
  changes when it resolves (a frozen VoxelBody's mass is recomputed only on
  `_rebuild`). Accepted as inherent to graceful degradation; bounded by
  resolving before *interaction* in practice (materials are small and fetch
  fast; zones without their documents are rare). Late resolution triggers a
  `_rebuild()` on bodies containing the LRID (cheap scan; bodies are few).
* **Eviction races a spawn.** A VoxelBody spawning from far-zone cells whose
  texture was evicted renders swatch-coloured until restored — cosmetic by
  construction, because eviction never touches physics or identity (§7.3).
* **Save/load remap bugs.** The classic corruption source. Countered by making
  translation the *only* path (no "fast path" that assumes LRID==container id
  — even for bootstrap materials, on purpose, so the translation code is
  exercised 100% of the time), and by verify item 6 asserting GMID-level
  round-trip with deliberately shuffled load order.
* **Session LRID growth as a slow leak.** Unbounded registration with no
  in-session recycling (§7.4) is a deliberate trade. 16-bit ceiling + refusal
  behaviour bound the failure; compact-on-save guarantees it never compounds
  across sessions.
* **The `_edits` dictionary at zone scale** is today an unbounded
  `Vector3i→int` dict; streaming whole edited zones through it will not scale
  — but that is the persistence workstream's chunked-storage problem; this
  design only fixes what the *values* mean (LRIDs in memory, GMIDs at rest).

---

## 13. Decision log (locked by this doc)

1. **Identity = sha256 over immutable document bytes** (git-blob style); no
   canonical re-serialization, ever. Aliases are cosmetic.
2. **LRID = append-only per-session dense int; one LRID per (material, state);
   never recycled, never reordered in-session; compaction only at the
   container boundary.**
3. **Every serialized voxel container carries an id-map header; dense ids are
   container-local.** (Pattern validated by upstream `VoxelBlockyTypeLibrary`,
   F8.)
4. **Module path grows one live library: append + batched full re-bake**,
   guarded by the runtime `add_model() == ARID` assert (VDS §8.1) and the
   `can_render_cell` paint gate on the composed appearance. No pre-allocated
   ranges, no library swaps. The append+batched-bake mechanics and all bake-cost
   analysis (§3, §7.2) are **unchanged** by the ARID model — they now simply
   cover appearance-model appends (one model per used `(material, modifier,
   visual-state)` combo) rather than one model per LRID; a bake still re-bakes
   the whole library once per arrival burst, cost O(models). (VDS §13.2.6.)
5. **Per-LRID Material instances are stable; textures swap in-place** — one
   mechanism serves async texture arrival, placeholder degradation, and
   far-zone eviction, with zero rebake/remesh on all three, on both render
   paths and VoxelBody alike.
6. **Missing materials degrade to UNRESOLVED placeholders that preserve
   identity** — world data is never lossy, resolution is in-place.
