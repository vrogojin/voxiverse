# MULTI-MATERIAL — the DESIGN §79 two-solids-in-one-voxel cases: feasibility spike + recommended path

Status: **FEASIBILITY SPIKE (read-only; no code written). Verdict: the §79 look is
COMPOSITIONAL — no case requires two solids in one cell, and no engine patch is
needed for the recommended path.** Deepens MULTI-LIQUID.md §3.2 into a concrete,
source-cited assessment, the way WATERLOGGING.md did for solid+fluid.

DESIGN §79 asks for "multi-material voxels (ground+puddle+ice+snow+grass)".
Waterlogging (shipped) solved solid+**fluid**; MULTI-LIQUID Part A (on this
branch) generalized it to any liquid. This document is the remaining half:
**solid+solid** — snow on grass, thin ice/snow layers, grass tufts — the cases
with **no fluid escape hatch** in the engine.

Ground truth verified while writing (refs as of `feat/voxiverse-multi-liquid`
@ 3018f97): the patched module source under
`docker/engine/cache/godot/modules/voxel/meshers/blocky/` (0001 applied),
`cell_codec.gd`, `shape_codec.gd`, `shape_mesh.gd`, `module_world.gd`,
`terrain_config.gd`, `world_manager.gd`, `block_materials.gd`, `blocks.json`.

---

## 0. Executive summary

* **The wall is real and it is threefold.** In the blocky mesher one voxel id is
  one baked model with ONE `transparency_index`, ONE `culls_neighbors`, and side
  patterns that ARE its rasterized geometry (no override) — and a baked model
  carries at most **2 surfaces** (`MAX_SURFACES = 2`,
  `blocky_baked_library.h:35`). Waterlogging tunneled through this wall only
  because fluids have an identity axis (`fluid_index`) for equality culling and
  **procedural** geometry for the second pass. Solids have neither (§1).
* **But no §79 case actually needs two solids in one cell.** Case-by-case (§2):
  puddles are the liquid axis (worldgen source missing, zero engine/codec work);
  walkable-depth snow/ice layers are **stacked cells** (half-block granular
  today, thin FAM family later); snow-*capped* grass is a **STATE-axis
  appearance variant** of one substance — the exact mechanism Minecraft uses
  (snowy grass is a block variant, snow depth is a stacked layer block); grass
  tufts are a stacked non-solid decoration cell. The full §79 lakeshore
  composes from axes that already exist.
* **Option verdicts (§3):** (a) curated combined 2-surface models — feasible
  borderlessly for opaque+opaque, bounded if curated (~350 models for snow caps
  on the 7 surface materials), but **never** for translucent caps (ice), and
  physics cannot see the cap — usable only for thin decorative caps, deferred
  until a case demands independent same-cell substances; (b) a second-solid
  engine pass — buys only per-surface transparency (ice caps in-cell), costs
  ~2× the waterlogging patch, **rejected** (stacked cells express ice already);
  (c) stacked cells — the default, zero engine work, half-block today; the thin
  FAM shape family is the priced Phase-3 item (game-side only, cross-cutting
  span math + a manifest-slot re-layout); (d) STATE-axis variants — cheapest,
  and not "just a skin": paired with `PerVoxelEnvironment` it is §79's
  *material-state-machine* tenant.
* **Recommended first build (§4): the snowy-world state bundle** — snow-capped
  STATE variants of the surface materials, driven by climate + per-voxel
  temperature (accumulate below freezing, melt above), plus stacked half-slab
  snow on flat snowy ground. Game-side only, no engine patch, no rebuild;
  zero new ArrayMeshes for the reskin variants (meshes shared, materials differ
  by per-surface override). It is the first render tenant of the STATE axis and
  the first consumer of the sim layer's temperature field — the two §79 muscles
  nothing exercises yet.
* **Patch 0002** (`copy_base_properties_from` hardening, MULTI-LIQUID §2.5):
  since no engine patch is recommended here, 0002 **stays a standalone tiny
  follow-up** — land it whenever the next engine rebuild happens for any reason.

---

## 1. The core problem, restated precisely

Why "snow AND grass in one voxel, both real" is hard in stock+0001 blocky:

1. **One model per voxel id.** The mesher reads one TYPE channel; each id
   indexes one `BakedModel` (`voxel_mesher_blocky.cpp:136-144`). Everything a
   cell renders must be baked into (or procedurally generated for) that one
   model. Ceiling: 65536 ids (`blocky_baked_library.h:22`).
2. **One transparency class per model.** Visibility first tests
   `other.transparency_index > vt.transparency_index || !other.culls_neighbors`
   (`voxel_mesher_blocky.h:119-122`) — both fields are single per-model scalars
   (`blocky_baked_library.h:120-121`). A model that is half opaque dirt and
   half translucent ice cannot present two transparency classes to its
   neighbours; whichever index it picks mis-culls one half (the exact wall that
   forced the waterlogging patch, WATERLOGGING §1.2).
3. **Geometry IS occlusion.** Side patterns are 32×32 rasterizations of the
   model's actual side geometry, combined across ALL its surfaces
   (`blocky_baked_library.h:89-97`: "Side patterns are still determined based
   on a combination of all surfaces. Side culling is all or nothing"). There is
   no API to claim a different footprint per material.
4. **No solid escape hatch.** Waterlogging's two-pass worked because (i) fluids
   carry an identity axis — `fluid_index` — and every borderless rule is an
   equality test on it (`voxel_mesher_blocky.cpp:166-169, 219-222` patched),
   and (ii) fluid geometry is **procedural** (`generate_fluid_model`), so the
   second pass needed no second set of baked surfaces or side patterns. A
   second *solid* has neither: solid-solid boundaries must be culled by shape
   (needing per-surface side patterns) and its geometry is baked (needing a
   second full surface/pattern set per model). That is why solid+solid cannot
   ride the 0001 mechanism.
5. **Two surfaces is the hard ceiling.** `MAX_SURFACES = 2`
   (`blocky_baked_library.h:35`); extra mesh surfaces are dropped with a
   warning (`voxel_blocky_model_mesh.cpp:467-474`). Any same-cell composite
   spends both slots (base + cap) — or one slot each for a top/side texture
   split (§3d) — they compete.

---

## 2. Case taxonomy — which §79 cases actually need two solids

| §79 case | verdict | mechanism |
|---|---|---|
| **Puddle** (shallow water on ground) | **NOT two solids — the liquid axis, already codec-ready.** | On a shaped composite: rule 6 keeps any known-kind level 1..10 on a nonzero modifier (`cell_codec.gd:192-207`). On flat ground: a shallow pure-liquid cell ABOVE it — rule 5 keeps levels 1..9 on liquid hosts (`cell_codec.gd:182-191`). Render is native: per-level `VoxelBlockyModelFluid`s (≤10 per kind; `max_level` auto-raises, `voxel_blocky_model_fluid.cpp:136`). **The only missing piece is a SOURCE** — nothing generates puddles (needs a worldgen moisture/weather rule). Zero engine work, zero codec work. |
| **Ice sheet on water** | **SHIPPED** | a stacked solid ice cell above water (frozen seas). |
| **Half-block snow/ice layer on a block** | **Stacked cell — zero new machinery.** | The all-corners-1 BOTTOM slab is an existing corner-height modifier; physics (`_occ_span`, collider, solver), codec, and the manifest already handle it. A worldgen-only change (emit a snow_block slab cell above flat ground in snowy biomes). |
| **Thin (<½ block) snow/ice layer** | **Stacked cell, thin FAM shape family — Phase 3, priced in §3c.** | Not expressible today: ShapeCodec is half-block-granular by design (corners ∈ {0,1,2}, `shape_codec.gd:13-22`). The reserved family bit (`MOD_FAM_BIT`, `cell_codec.gd:29`; canonicalization already passes FAM modifiers through, `cell_codec.gd:143-144`) is the designed extension point. Keeps ONE material per (sub)cell — sidesteps two-solids entirely. |
| **Grass tuft / flowers on dirt** | **Stacked non-solid decoration cell above.** | A `grass_tuft` material (solidity 0, like powder_snow) whose model is a cross-quad `VoxelBlockyModelMesh`. Cross-quads are interior geometry (never on a cell side) → empty side patterns → it occludes nothing; give it `culls_neighbors false` + alpha-scissor material. Physics-invisible via the solidity gate (`world_manager.gd:165-168`). One open question: `aimed_voxel` is solidity-gated, so tufts are not targetable/breakable without a small aiming exception — flag for the build. NOT a same-cell problem: the tuft lives in the air cell above the dirt. |
| **Snow-ON-grass, both visible** | **A STATE-axis appearance variant of ONE substance — not two substances.** | The Minecraft precedent is exact: "snowy grass" is a block-state skin (side rim + white top); snow *depth* is a separate stacked layer block. The look decomposes the same way here: state variant for the cap skin (§3d), stacked slab for depth. A TRUE two-substances-in-one-cell (cap independently breakable/meltable, own mass, own drop) is needed by **no current §79 case** — melting is a state *transition* (snowy → plain, optionally emitting a puddle level above), which is precisely §79's "material state machines driven by temperature". |

**Conclusion:** the §79 lakeshore ("ground+puddle+ice+snow+grass") is
compositional across existing axes — material + modifier + state + liquid + a
stacked cell — with the state axis and a moisture source being the two unbuilt
pieces. The true two-solids case is a *hypothetical future* need, not a §79
need.

---

## 3. The options, evaluated

### (a) Curated combined models (base solid + cap solid baked as one model)

**Mechanism.** A `VoxelBlockyModelMesh` whose ArrayMesh has two surfaces —
surface 0 the base ramp, surface 1 the cap layer — with per-surface material
overrides. This is the shipped wet-composite pattern verbatim
(`module_world.gd:756-775`; overrides consumed at
`voxel_blocky_model_mesh.cpp:531-536`). The mesher is indifferent (a model is
any mesh ≤ 2 surfaces).

**Does it work borderlessly?** For **opaque+opaque: yes, and honestly.** Side
patterns rasterize the union of both surfaces' geometry
(`blocky_baked_library.h:89-91`), so neighbour culling is geometric truth: a
snow-capped ramp culls and is culled exactly as its combined silhouette. Both
parts share `transparency_index 0` — no conflict. No equality-culling axis is
needed because adjacent snow caps meet as *geometry* (a shared side edge either
matches or draws — same as adjacent dry ramps today, which are borderless).
It even composes with waterlogging: pass 0 emits all `surface_count` solid
surfaces, the fluid pass is procedural and consumes no surface slot
(`voxel_mesher_blocky.cpp:188-256`) — a snow-capped shore ramp under water is
expressible.

**Failure modes.**
1. **Translucent caps are impossible.** An ice cap (cull_group 2, translucent —
   blocks.json id 46) inside an opaque model recreates the one-transparency
   wall (§1.2): index 0 makes neighbours' faces behind the ice vanish (seen
   through it — holes); index 2 lets water/solids cull the base's real geometry.
   No index is correct. **Ice layers must be stacked cells. Locked.**
2. **Combinatorics must be curated.** Uncurated, the space is
   |solid materials|² × |shapes| ≈ 75 × 75 × 79 ≈ **444k — exceeds the
   65536-model ceiling** (`blocky_baked_library.h:22`) before considering bake
   time. Curated — caps ∈ {snow}, bases = the 7 surface materials
   (`terrain_config.gd:672-676`), shapes = the emitted-modifier sample
   (`terrain_config.gd:712-727`, ≤79, realistically ~40–60) — it is ~**280–420
   models**, ~2–3× the water twin set, inside the manifest discipline. New
   ArrayMeshes: one per (modifier, cap-shape) — cap geometry is shared across
   base materials via overrides (the `_WET_MESH_FLAG` precedent) — so
   +~40–80 meshes, each a GPU readback at bake (the known load-stall cost the
   emitted-modifiers trim exists to bound, `terrain_config.gd:695-708`).
3. **Identity needs a new convention.** `block_id_at` returns `CellCodec.mat`
   (`world_manager.gd:144-145`); mass, break yield, structural class all key on
   it. A cap needs an encoding: a full second 16-bit material axis does NOT fit
   (reserved band is bits 54..62 = 9 bits, `cell_codec.gd:8-21`); a curated
   cap descriptor fits either the STATE axis (16 bits, live) or the reserved
   band. Primary = base material (break yields base, cap vanishes) is the sane
   default — at which point the encoding *is* a state variant, and (a) has
   collapsed into (d) plus real cap geometry.
4. **Physics cannot see the cap.** `_occ_span` composes solidity(mat) ×
   `ShapeCodec.span(modifier)` (`world_manager.gd:165-168`); the cap's volume
   is invisible to spans, floor, DDA, solver, collapse. For a thin decorative
   cap (≲0.1 blocks) this is the same accepted class as grass tufts; for
   anything walkable-depth it is wrong — which is exactly why walkable layers
   belong to stacked cells (c).

**Verdict: feasible, bounded, zero engine change — but only for thin, opaque,
decorative caps with base-primary identity, i.e. a strictly fancier version of
(d). Defer until a case needs cap geometry that a texture variant can't fake
(e.g. drifted snow overhanging a ramp edge).**

### (b) A second solid material axis + a second engine pass

What would waterlogging-for-solids need that 0001 didn't?

* **Per-surface side patterns + per-surface transparency.** The solid cap's
  boundary faces must cull by *its* shape and transparency class, independent
  of the base — `BakedModel::Model` has one `side_pattern_indices` set and the
  model one `transparency_index` (`blocky_baked_library.h:91, 120`); both
  become per-surface arrays, and `generate_side_culling_matrix`
  (`voxel_blocky_library_base.cpp:679-767`) plus the visibility loop
  (`voxel_mesher_blocky.cpp:148-181`) must consult them per pass.
* **A baked second geometry** — no procedural generator exists for "a layer
  following a corner-height surface"; either bake it (that's option (a)'s
  mesh) or write a `generate_layer_model` sibling of the fluid path
  (`blocky_fluids_meshing_impl.h`) — new engine machinery either way.
* **Data plumbing.** Model-driven (cap rides the model id like waterlog) keeps
  the TYPE channel — but then the id-space cost is identical to option (a),
  and for opaque+opaque the engine pass adds *nothing* over (a)'s plain baked
  mesh: union-geometry culling is already correct. The only genuine purchase
  is per-surface transparency — translucent ice caps in-cell. Channel-driven
  (a real second material channel) is the 5-10× cross-cutting change
  WATERLOGGING §2 already rejected (mesher reads exactly one channel,
  `voxel_mesher_blocky.cpp:551, 802-804`).

**Cost estimate:** per-surface patterns/transparency + a second solid pass +
culling-matrix rework ≈ **400–600 LOC touching the mesher's hottest loops**,
vs 0001's ~220-280 LOC — call it 2× waterlogging with a wider blast radius
(every existing model's bake shape changes) — to enable only the in-cell ice
cap that stacked ice cells already express with zero engine work.

**Verdict: REJECTED for now.** Revisit only if a future milestone makes
same-cell multi-solid *pervasive* (e.g. ore veining inside host rock at
per-voxel scale) rather than decorative.

### (c) Stacked cells (one material per cell; the layer is its own voxel)

**Today (half-block granularity): fully supported, zero new machinery.** A
snow_block slab (all-corners-1 modifier) above the surface cell round-trips the
codec, meshes on both paths, and is physics-correct through `_occ_span` /
collider / solver. Cost: a worldgen rule. This is the *only* option on this
page that gives **walkable, breakable, massive** snow — the cap is a real cell.

**Phase 3 (thin layers): the FAM shape family — priced honestly.** The
reserved `MOD_FAM_BIT` (`cell_codec.gd:29`) selects a second shape family,
e.g. "uniform thin layer, thickness 1..4 in tenths". The full touch list:

1. `cell_codec.gd` — `_canonical_modifier` already passes FAM through
   (`:143-144`); add the family's own canonical rules (thickness 0 → air etc.).
2. `shape_codec.gd` — every decode branches on the family: `corners`/`anchor`/
   `volume`/`height_at`/`span`/`occupied`/`side_profile`/`side_profile_full`/
   `surface_tris`. The 18-profile contact LUT (`:47-63`) assumes 2-bit corner
   heights; thin layers need either an extended profile enumeration or the
   closed-form integrals directly (they exist: `_profile_overlap_direct`).
3. `shape_mesh.gd` — a thin-slab builder (trivial next to the ramp builder).
4. `module_world.gd` — **a real snag: the dense manifest slot breaks.** The
   frozen tables key `mat * _GEN_STRIDE + modifier` with `_GEN_STRIDE := 256`
   (`module_world.gd:50`), valid because emitted modifiers are all
   BOTTOM-anchored < 256 (`terrain_config.gd:681`). A FAM modifier has bit 15
   set (≥ 32768) — thin-layer ARIDs need a side table or a re-keyed stride.
5. Fallback mesher, GroundCollider spans, StructuralSolver, collapse flood,
   `aimed_voxel`'s in-cell ray test — all consume the ShapeCodec queries; if
   (2) is exact they follow for free, but each needs a verify pin.

**No engine patch** — a thin slab is just a mesh; its side patterns rasterize
honestly (a 0.1-tall side band culls nothing, is culled by nothing full —
correct). Cross-cutting but mechanical; the most expensive *game-side* item in
this document, and it removes the granularity limit for every future layer
material (ash, sediment, frost), not just snow.

**Failure mode:** span math must be exact or the player floats/sinks by the
layer thickness — mitigated by the existing pattern of verify-pinned span
invariants.

**Verdict: the DEFAULT for any layer with substance. Half-block now; FAM thin
layers when a visible case (snow accumulation states) justifies Phase 3.**

### (d) STATE-axis appearance variants (snow-capped as a state of grass)

**Mechanism.** STATE bits 32..47 are live in the codec (`cell_codec.gd:86-87`)
with a pass-through validation hook (`_validate_state`, `:161-162`) — and are
**render-invisible today**: `arid_for_cell` projects only mat/modifier/liquid
(`module_world.gd:284-314`). The build is: give states render tenancy — extend
the manifest keying to (mat, state, modifier) for the curated states, register
variant models, and have worldgen/the state machine emit state bits.

**Cost.** Game-side only. The variant models **reuse the existing shared
ArrayMeshes** (`_shape_mesh_cache`, one mesh per modifier shared across
materials, `module_world.gd:628-640`) — a state variant is the same mesh with
a different material override ⇒ **zero new meshes, zero GPU readback**; model
count +|states| × |mats with that state| × |emitted modifiers| (snowy on 7
mats ≈ +280–420 models — same order as the lava twin set, risk-table §5).
Two texture-fidelity tiers:
* *v1 (recommended):* one snowy material per base (whole-cell reskin toward
  snow — reads as "snow-covered" at voxel scale; materials are single-texture
  planar-mapped, `block_materials.gd`).
* *v2 (optional polish):* split `ShapeMesh.build` output into two surfaces
  (top tris / sides+anchor) for true Minecraft-style white-top + rimmed-side.
  Costs both `MAX_SURFACES` slots — mutually exclusive with an (a) cap surface
  on the same model, fine with waterlogging (fluid needs no slot).

**Where's the line — is this "multi-material"?** A state variant is ONE
substance: no separate cap mass, no separate drop; `block_id_at` unchanged;
GMID discipline as with `liquid_kind` (omit default state from the material
document). That is not a cop-out — it is §79's own vocabulary: "material state
machines driven by temperature/light" are *states of a material*, and this is
the first feature that would actually exercise the state axis end-to-end:
`PerVoxelEnvironment.temperature` → transition rule (accumulate below 0 °C,
melt above; optionally melt emits a puddle liquid level in the cell above) →
state bits → render variant. The sim layer was built for exactly this and has
no consumer yet.

**Failure mode:** none structural; the risk is scope creep in the state
machine (author 1 transition, not a framework) and the manifest keying
(mirror the twin-table discipline: frozen, sampled, dry-fallback).

**Verdict: BUILD FIRST.**

---

## 4. Recommendation and phased plan

### First build — "snowy world" (Phase M1, game-side only, no engine rebuild)

1. **STATE-axis snow-capped variants** of the surface materials (d):
   * codec: claim state bit(s) for `snow_capped`; real `_validate_state` rule
     for the curated states; GMID omit-when-default pin.
   * worldgen: emit the state in cold climate (key it off the same temperature
     noise as frozen seas, `t < -0.55` — one regime authority, mirroring
     `_sea_liquid_kind`).
   * render: (mat, state, modifier) manifest keying on the module path (shared
     meshes, new materials only — zero readbacks); fallback path picks the
     variant texture; dry/plain fallback when unbaked, never a hole.
   * sim: ONE `VoxelStateTransition` — snow_capped ⇄ plain across 0 °C via
     `PerVoxelEnvironment` — the first live state machine.
2. **Stacked half-slab snow** on flat snowy ground (c-today): a worldgen rule
   emitting an all-corners-1 snow_block cell above the surface cell — real,
   walkable, breakable snow depth with zero new machinery.
3. Verify: state round-trip + GMID stability + manifest-keying pins + a
   deterministic snowy-column sweep; `/steelman` per standing policy.

Estimated cost: comparable to the MULTI-LIQUID Part A game wiring (it reuses
its table discipline), i.e. **days, not weeks; zero engine LOC**. Demo payoff:
walk from temperate into a snowy region and watch surfaces carry snow; dig a
slab; warm biome edge shows the melt transition — §79's state machine visibly
alive.

### Deferred, with reasons

* **Puddles** (Phase M2): mechanism is fully ready (liquid levels); blocked
  only on a worldgen moisture/weather source — build it as the melt product of
  M1's transition (melting snow_capped emits a level-2 water cell above) to
  get the source for free.
* **Grass tufts / decorations** (Phase M2): stacked non-solid decoration cell;
  needs a cross-quad model + an `aimed_voxel` targeting exception; independent
  of everything else.
* **Thin FAM layers** (Phase 3): build when snow *accumulation depth* becomes
  a feature (states: dusting → slab → drift); carries the §3c touch list and
  the `_GEN_STRIDE` re-keying. Game-side only.
* **Curated combined models (a)** (Phase 3+): only if a case needs true cap
  *geometry* a texture can't fake; design the identity convention first (it
  will sit on the STATE axis regardless, so M1 is prerequisite work, not
  throwaway).
* **Second-solid engine pass / second channel (b): rejected** — 2× the
  waterlogging patch to buy only in-cell translucent caps that stacked ice
  already expresses.
* **Patch 0002**: independent one-line hardening; not bundled (no engine work
  recommended here). Fold into the next rebuild whenever one happens;
  `module_in_web=yes` gate as always.

---

## 5. Risk table

| # | risk | analysis / mitigation |
|---|---|---|
| 1 | **State-variant manifest growth** (+~280–420 models) | Same order as the lava twin set (MULTI-LIQUID §2.2.6, risk 6); shares ALL existing ArrayMeshes → zero new GPU readbacks, only model bake/pattern work. Sampled + frozen like twins; unbaked → plain variant, never a hole. |
| 2 | **State bits leak into GMIDs / serialization** | Mirror the `liquid_kind` discipline: omit default state from the material document; verify pins a non-variant GMID byte-identical before/after. |
| 3 | **State machine scope creep** | M1 authors exactly ONE transition (snow ⇄ plain at 0 °C). The `VoxelMaterialDef`/`VoxelState`/`VoxelStateTransition` framework question is deferred until a second transition exists. |
| 4 | **Two render paths diverge on states** | Both paths key appearance off the same (mat, state, modifier) projection; verify's both-path ARID/texture mirror extends to one state, as it did for liquid kinds. |
| 5 | **Half-slab snow breaks stackup asserts** | It's a new generated cell above the old surface; retarget the snowy-biome surface sweeps deliberately (the WATER-SHORE "expect these, do not weaken" pattern). |
| 6 | **Thin-FAM span math wrong (Phase 3)** | The priced touch list in §3c; the `_GEN_STRIDE` dense-slot break is called out so it's a design line-item, not a surprise. Every ShapeCodec query gets a closed-form + verify pin before any consumer ships. |
| 7 | **Combined models built prematurely** | §3a records the exact preconditions (opaque-only, thin-only, curated, identity-on-STATE); anything else re-opens this document rather than "simplifying" in code. |
| 8 | **MAX_SURFACES contention** (top/side split vs cap surface) | Hard ceiling of 2 (`blocky_baked_library.h:35`). Recorded: v2 texture split and an (a)-cap are mutually exclusive per model; waterlogging never competes (procedural, no slot). |
| 9 | **Decoration cells untargetable** | `aimed_voxel` is solidity-gated; tufts need a targeting exception (small, flagged in §2) or remain unbreakable decor — decide at M2, not silently. |

---

## 6. Decision log (locked by this spike)

1. **No §79 case requires two solids in one voxel.** Puddle = liquid axis;
   ice = stacked (translucent caps in-cell are impossible — one
   `transparency_index` per model); snow depth = stacked; snow cap = STATE
   variant; tufts = stacked decoration cell.
2. **First build is the snowy-world state bundle** (state-axis variants +
   half-slab snow + one temperature transition) — game-side only, no engine
   patch, no rebuild.
3. **Second-solid engine pass and second data channel stay rejected** (~2×
   0001's size for translucent-cap-only gains).
4. **Curated combined models are the recorded escape hatch** for future cap
   geometry: opaque-only, thin-only, curated set, identity on the STATE axis,
   physics-invisible caps — never for ice.
5. **Thin layers are the FAM shape family** (Phase 3, game-side): §3c touch
   list including the `_GEN_STRIDE` re-keying is the cost record.
6. **0002 remains a standalone follow-up**, bundled with the next rebuild.
