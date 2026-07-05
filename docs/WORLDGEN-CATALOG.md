# VOXIVERSE — Minecraft-Parity Block Catalog & Worldgen (Design)

> **⚠ Reconciled — read alongside `docs/INTEGRATION-DECISIONS.md`.** (Referenced in earlier
> sibling docs as `BLOCK-CATALOG-MC.md` — same workstream, this file.)
> The provisional **structural** columns in §3.2/§3.4 are superseded: durability/attachment now
> come from the `(ρ,C,T)→(P,H,D)` converter (INTEGRATION-DECISIONS §1.2/§1.3). The scalar
> **`A` column is deleted** — its meaning is absorbed by the anchor-derived (σ_t, σ_s) plus the
> `attachment` **participation multiplier** (non-1.0 only for sand/gravel = 0.0, §1.4); the `D`
> power-laws survive only as the **`break_force`** (mining-effort) derivation. Commit the numeric
> cohesion values (grass 30, dirt 25, mud 10, clay 100, sand 0, gravel 2 kPa) the soil branch
> consumes. The block set, worldgen pipeline, and translucency design here stand as authored.

Status: **DESIGN — not implemented.** Branch `feat/voxiverse-sim-extensions`.
Author: world-generation & content architecture workstream, 2026-07-04.

This document specifies (a) the extension of `BlockCatalog` from 6 block ids to a
Minecraft-parity natural/worldgen material set (~77 shipped ids, ~40 more
streamable), (b) the data model that makes the catalog authorable as data instead
of hand-written consts, (c) translucent-block rendering in BOTH render paths, and
(d) an adaptation of default Minecraft worldgen (biomes, surface rules, deepslate,
ores, sea level, caves) onto our `TerrainConfig.generated_block` architecture,
preserving the project's hard invariants: determinism, path-agnostic gameplay
through `block_id_at`, and analytic (collider-less) player physics.

Sibling workstreams referenced (in flight; **not yet on this branch** at time of
writing — every dependency on them is flagged inline with ⚠SEAM):

| Sibling | Doc | What we consume / provide |
|---|---|---|
| Structural integrity | `docs/STRUCTURAL-INTEGRITY.md` | consumes our per-material real-world priors (ρ, compressive C, tensile T); produces the final durability/attachment derivation. Our D/A columns are **provisional stand-ins**. |
| Runtime material streaming | `docs/RUNTIME-MATERIAL-STREAMING.md` | id-at-scale model; our catalog is tiered (`core`/`world`/`extended`) and data-driven so the `extended` tier can stream. |
| Textures | (no doc yet) | consumes §3's stable name list; our swatch colours are the pre-texture fallback. |
| Sub-voxel smoothing | `docs/SUB-VOXEL-SMOOTHING.md` | smooths surfaces our worldgen emits; see §9.6. |

---

## 1. Research findings

### 1.1 Version researched

The latest stable Minecraft release at time of writing is **Java Edition 26.2
("Chaos Cubed", released 2026-06-16)**; Mojang switched to date-based versioning
after 1.21.x. 26.1 ("Tiny Takeover", 2026-03-24) and 26.2 added the sulfur-caves
biome with **sulfur** and **cinnabar** block families; the *worldgen system
itself* (noise router, ore distribution, cave generation) has been **stable since
Java 1.18 "Caves & Cliffs II" (2021) through 26.2** — sources describe the ore
system as "unchanged from 1.18 through 1.21.11" and 26.x only adds biomes/blocks
on top. So we adapt the 1.18-era system as it exists in 26.2.

Sources:
- [Java Edition 26.2 — Minecraft Wiki](https://minecraft.wiki/w/Java_Edition_26.2), [minecraft.net 26.2 release notes](https://www.minecraft.net/en-us/article/minecraft-java-edition-26-2) (sulfur caves, sulfur/cinnabar blocks)
- [Java Edition version history — Minecraft Wiki](https://minecraft.wiki/w/Java_Edition_version_history)
- [Ore — Minecraft Wiki](https://minecraft.wiki/w/Ore) (distribution table, deepslate variants "under layer 8")
- [World generation — Minecraft Wiki](https://minecraft.wiki/w/World_generation) (noise router, sea level, bedrock/deepslate gradients, cave types, surface rules)
- Ore-distribution cross-checks: [progameguides 1.21 ore distribution](https://progameguides.com/minecraft/minecraft-1-21-ore-distribution-best-level-for-all-ores-diamonds-gold-restone-and-more/), [blog.berrybyte.net ore guide](https://blog.berrybyte.net/minecraft-ore-distribution-guide-1-21-best-y-levels-for-every-ore/)
- godot_voxel blocky transparency: [VoxelBlockyModel — voxel-tools docs](https://voxel-tools.readthedocs.io/en/latest/api/VoxelBlockyModel/)

### 1.2 Minecraft's natural / worldgen-relevant block set (26.2)

Grouped; (†) marks blocks we deliberately **exclude** from our shipped set with the
reason.

- **Stones:** stone, deepslate, granite, diorite, andesite, tuff, calcite,
  dripstone block, sandstone, red sandstone, obsidian, bedrock, amethyst (geodes),
  sulfur + cinnabar (26.2 sulfur caves). † smooth basalt/basalt (Nether-leaning),
  † infested stone (mob mechanic), † pointed dripstone / sulfur spike (non-cube
  partial blocks).
- **Ores:** coal, copper, iron, gold, redstone, lapis, diamond, emerald — each
  with a **deepslate variant** below the deepslate transition. † nether ores.
- **Soils/surface:** grass block, dirt, coarse dirt, rooted dirt (†, tied to
  azalea trees), podzol, mycelium, mud, clay, sand, red sand, gravel, moss block,
  snow block, suspicious sand/gravel (†, archaeology).
- **Fluids:** water, lava (flowing states †: we model source-only static fluids).
- **Cryo:** ice, packed ice, blue ice, powder snow, snow *layer* (†, partial
  block — full `snow_block` only).
- **Woods (log + leaves per species):** oak, spruce, birch, jungle, acacia, dark
  oak, mangrove, cherry, pale oak (1.21.4) — we ship 7 species, stream the rest.
- **Glass:** glass, tinted glass, 16 stained-glass colours (we ship glass + tinted
  + 4 representative stained colours; the other 12 are `extended` tier).
- **Terracotta:** plain + 16 colours; badlands strata naturally use ~6 colours (we
  ship plain + the 6 banding colours; rest `extended`).
- † Plants/decor (flowers, grasses, kelp, coral, sculk family, golden dandelion
  26.1): non-cube or gameplay-first; out of scope for this workstream.

### 1.3 Minecraft's default Overworld generation (1.18 system, as of 26.2)

Facts we adapt (all from the [World generation](https://minecraft.wiki/w/World_generation)
and [Ore](https://minecraft.wiki/w/Ore) wiki pages):

1. **Vertical bounds:** world spans y −64…320. **Bedrock** is a hash-dithered
   gradient: 100 % at y=−64 fading to 0 % by y=−59. **Deepslate** replaces stone
   in a dithered gradient from y=8 (0 %) down to y=0 (100 %); everything below
   y=0 is deepslate. Ores below the transition generate as deepslate variants.
2. **Sea level: y=63.** Aquifers place local water/lava bodies; below y≈−55
   liquid pockets are lava.
3. **Terrain shape:** three low-frequency 2D noises — *continentalness*
   (ocean↔inland), *erosion* (mountain↔flat), *peaks&valleys/weirdness* — mapped
   through splines into a target height/squash, combined with a **3D density
   noise** (density > 0 ⇒ solid) which is what produces overhangs and cliff
   faces.
4. **Caves:** *cheese* (large chambers, 3D noise threshold), *spaghetti* (long
   tunnels: two 3D noises simultaneously near zero), *noodle* (thinner variant),
   plus legacy *carvers* (y −56…180). Aquifers flood cave sections below their
   local water level.
5. **Ores:** per-ore placement attempts per chunk with a Y-**distribution shape**
   — *triangle* (peaked) or *uniform* — e.g. diamond y −64…16 peaking at −59
   (triangle); coal peaks at 96 + uniform band above; iron has a deep peak (~16)
   and a mountain peak; gold −64…32 peak −16 (plus badlands bonus); redstone
   deep uniform + triangle at −59; lapis triangle ~0 + buried uniform; copper
   −16…112 peak ~48; emerald only in mountain biomes, peaked high. "Reduced air
   exposure" culls ore touching cave air (we skip this rule).
6. **Surface rules:** biome-keyed column recipe — grass block on top + 3–4 dirt
   below in temperate biomes; desert/beach = sand with a sandstone slab beneath;
   badlands = red sand + banded terracotta strata; mushroom fields = mycelium;
   swamp = mud; frozen biomes = snow; underwater floors = sand/gravel/clay
   patches.
7. **Biomes** are selected from a multi-noise point lookup (temperature,
   humidity, continentalness, erosion, depth, weirdness) — deterministic pure
   function of position + seed.

---

## 2. Design constraints recap (what the codebase fixes for us)

- `TerrainConfig.generated_block(x,y,z)` is a **pure, deterministic, O(1)-ish
  per-cell function**; `WorldManager.block_id_at` = sparse edit overlay else
  `generated_block`. Every consumer (both meshers, DDA ray, `floor_under`,
  `blocked`, `GroundCollider`, collapse flood-fill) routes through it
  (`world_manager.gd:92`). We extend the *function*, never add a parallel query.
- Block ids are **dense**, shared by the godot_voxel blocky library (model index
  == id — asserted in `module_world.gd:_configure_library`), the fallback mesher,
  the overlay, `VoxelBody` and inventory. Ids **0–5 are frozen forever**.
- The world is currently a **pure heightmap, never hollow** — assumptions baked
  into `effective_height` (top-down removed scan), the collapse pass's
  bottom-row seeding, and the fallback mesher's column model. §8 audits every one
  before caves.
- All placement randomness is **hash-of-position** (`TreeGen._hash01` family) —
  no `randi()`/`randf()`, no per-run state. New systems reuse the same hash.
- Web export runs godot_voxel meshing+generation on **one** thread; per-voxel
  cost budgets matter (§7.4).

---

## 3. The extended block catalog

### 3.1 Id strategy

- Ids stay **dense** (0…COUNT−1) and are assigned by **record order in the data
  file** (§4). The file is **append-only**: a mid-file insertion renumbers
  everything after it and silently recolours the world — the existing
  library-order assert generalises to *every* id, and a golden catalog checksum
  (§10) makes a reorder a hard test failure, not a visual surprise.
- Ids **0–5 keep their exact meaning** (`air, grass, dirt, stone, wood, leaf`).
  `wood`/`leaf` are retroactively *oak*: the data records get
  `alias: "oak_log"` / `alias: "oak_leaves"` so the texture workstream and new
  code use species names while old code keeps compiling. The `const` block in
  `block_catalog.gd` remains, now **asserted against** the loaded data rather
  than being the data.
- **Tiers** (consumed by ⚠SEAM runtime-material-streaming):
  - `core` (ids 0–5): frozen, always loaded, gameplay baseline.
  - `world` (ids 6–76): everything the generator can emit + glass family —
    always loaded (77 records is trivial memory; the tier exists so the *id
    model* scales, not to save RAM today).
  - `extended` (no fixed ids in this doc): the remaining 12 stained-glass
    colours, remaining 10 terracottas, mangrove/pale-oak/azalea woods, wools,
    concretes… Assigned ids only when streamed in. ⚠SEAM: we **assume** the
    streaming design provides a stable-name → runtime-dense-id mapping and
    guarantees persisted ids (edit overlay, inventory, VoxelBody cells) are
    never renumbered; our contract is that *generator output uses only
    `core`+`world` ids*, so terrain never depends on a streamed id.

### 3.2 Derived-value rules (how every number below was computed)

- **Mass** (kg per 1 m³ voxel). The existing catalog is gameplay-scaled, not
  physical (stone 1500 vs real ~2700; wood 80 vs real ~700 — deliberately light
  so the push sandbox works). New materials preserve those anchors:
  - mineral family: `mass = ρ_real × 0.556` (anchor: stone 2700→1500),
  - wood logs: `mass = ρ_real × 0.114` (anchor: oak 700→80),
  - organics/cryo/fluids: hand-placed on the same scale, ordering-checked in §10.
- **Durability D** (the existing `break_force`, newtons) and **attachment A**
  (0–1) must come from the ⚠SEAM structural-integrity derivation method. Until
  that lands, the tables carry **provisional stand-ins** anchored to today's
  values so nothing regresses:
  - rock family: `D = 2500 · (C/100 MPa)^0.75` (anchor: stone C=100 → 2500 N),
  - wood family: `D = 600 · (C∥/50 MPa)^0.75` (anchor: oak C∥=50 → 600 N),
  - `A = clamp(T/10 MPa, 0.02, 1.0)` (anchor: stone T=10 → 1.0),
  - soils don't fit a compressive prior (cohesion-dominated): hand values, and we
    flag to the sibling that its method **needs a soil/cohesion branch**.
  - Ores: host rock ± 10 % (D ×1.1, mass = host + mineral enrichment).
  The **real contract** with the sibling is the *priors* columns (analog, ρ, C,
  T) — recompute D/A with their method and only the two columns change.
  - Note: today every block implicitly has `attachment = 1.0` (the `VoxelState`
    default; `BlockCatalog._make` never sets it). This table assigns real values
    (sand 0.05, glass 0.1, …). Attachment is currently **unread** by the collapse
    pass (binary flood-fill), so this is data-only until the sibling consumes it
    — but flagging: once consumed, sand/gravel columns will behave very
    differently (they should — falling sand is the point).

### 3.3 Catalog table — identity, look, render class

Legend: **sol** = solidity (≥0.5 ⇒ collides, see §6.3), **perm** = permeability,
**trₛ** = sim translucence (`VoxelState.translucence`, feeds the light field),
**render** = O(paque) / T(ranslucent, with alpha) / E(missive), **cull** =
transparency cull group (§5). Swatches are pre-texture fallbacks (⚠SEAM textures).

**Frozen core (ids 0–5, unchanged values):**

| id | name | tier | swatch | render | cull | sol | perm | trₛ |
|---|---|---|---|---|---|---|---|---|
| 0 | air | core | — | — | — | 0 | 1.0 | 1.0 |
| 1 | grass | core | #4d8c3d (baked PNG) | O | 0 | 1 | 0.2 | 0 |
| 2 | dirt | core | #734f2e | O | 0 | 1 | 0.2 | 0 |
| 3 | stone | core | #85858c | O | 0 | 1 | 0 | 0 |
| 4 | wood (alias oak_log) | core | #9e7042 (baked PNG) | O | 0 | 1 | 0 | 0 |
| 5 | leaf (alias oak_leaves) | core | #216b1f | O (future cutout) | 0 (future 9) | 1 | 0.9 | 0.3 |

**Stones (ids 6–17):**

| id | name | tier | swatch | render | cull | sol | perm | trₛ |
|---|---|---|---|---|---|---|---|---|
| 6 | bedrock | world | #565656 | O | 0 | 1 | 0 | 0 |
| 7 | deepslate | world | #46464b | O | 0 | 1 | 0 | 0 |
| 8 | granite | world | #956755 | O | 0 | 1 | 0 | 0 |
| 9 | diorite | world | #bcbcbe | O | 0 | 1 | 0 | 0 |
| 10 | andesite | world | #808085 | O | 0 | 1 | 0 | 0 |
| 11 | tuff | world | #6d6f68 | O | 0 | 1 | 0.1 | 0 |
| 12 | calcite | world | #dfe0dc | O | 0 | 1 | 0 | 0 |
| 13 | dripstone_block | world | #7d6353 | O | 0 | 1 | 0.1 | 0 |
| 14 | sandstone | world | #dbcfa3 | O | 0 | 1 | 0.1 | 0 |
| 15 | red_sandstone | world | #ba631d | O | 0 | 1 | 0.1 | 0 |
| 16 | sulfur_block | world | #d8c93c | O | 0 | 1 | 0 | 0 |
| 17 | cinnabar_block | world | #8f3a32 | O | 0 | 1 | 0 | 0 |

**Ores (ids 18–33; swatch = host blended with mineral fleck):**

| id | name | swatch | | id | name | swatch |
|---|---|---|---|---|---|---|
| 18 | coal_ore | #55555a | | 26 | deepslate_coal_ore | #38383c |
| 19 | copper_ore | #8a6a4e | | 27 | deepslate_copper_ore | #5f4a38 |
| 20 | iron_ore | #8f7d73 | | 28 | deepslate_iron_ore | #635750 |
| 21 | gold_ore | #96843f | | 29 | deepslate_gold_ore | #6a5d2e |
| 22 | redstone_ore | #7d4a4a | | 30 | deepslate_redstone_ore | #573434 |
| 23 | lapis_ore | #4a5a80 | | 31 | deepslate_lapis_ore | #343f5a |
| 24 | diamond_ore | #6d9c9e | | 32 | deepslate_diamond_ore | #4c6d6f |
| 25 | emerald_ore | #5d8f68 | | 33 | deepslate_emerald_ore | #416348 |

All ores: tier `world`, render O, cull 0, sol 1, perm 0, trₛ 0.

**Soils & surface (ids 34–43):**

| id | name | swatch | render | cull | sol | perm | trₛ |
|---|---|---|---|---|---|---|---|
| 34 | coarse_dirt | #6a4c33 | O | 0 | 1 | 0.25 | 0 |
| 35 | podzol | #7a5430 | O | 0 | 1 | 0.2 | 0 |
| 36 | mycelium | #6f6265 | O | 0 | 1 | 0.2 | 0 |
| 37 | mud | #3c3a3d | O | 0 | 1 | 0.1 | 0 |
| 38 | clay | #9aa3b3 | O | 0 | 1 | 0.02 | 0 |
| 39 | sand | #dbd3a0 | O | 0 | 1 | 0.35 | 0 |
| 40 | red_sand | #be6721 | O | 0 | 1 | 0.35 | 0 |
| 41 | gravel | #837f7e | O | 0 | 1 | 0.4 | 0 |
| 42 | snow_block | #f4fdfd | O | 0 | 1 | 0.5 | 0.1 |
| 43 | moss_block | #59742c | O | 0 | 1 | 0.6 | 0 |

**Fluids & cryo (ids 44–49):**

| id | name | swatch (alpha) | render | cull | sol | perm | trₛ |
|---|---|---|---|---|---|---|---|
| 44 | water | #3f76e4 (a 0.65) | T | 1 | **0** | 1.0 | 0.6 |
| 45 | lava | #d45a12 | O + E(glow 1.0) | 0 | **0** | 0.3 | 0 |
| 46 | ice | #7dadff (a 0.84) | T | 2 | 1 | 0 | 0.7 |
| 47 | packed_ice | #8ab5fd | O | 0 | 1 | 0 | 0.3 |
| 48 | blue_ice | #74a8fd | O | 0 | 1 | 0 | 0.2 |
| 49 | powder_snow | #f8fdfd | O | 0 | **0.15** | 0.8 | 0.2 |

**Woods, 6 new species (ids 50–61; oak is core ids 4/5):**

| id | name | swatch | | id | name | swatch |
|---|---|---|---|---|---|---|
| 50 | spruce_log | #4a3520 | | 51 | spruce_leaves | #40573c |
| 52 | birch_log | #c8c0a8 | | 53 | birch_leaves | #80a755 |
| 54 | jungle_log | #574427 | | 55 | jungle_leaves | #48941f |
| 56 | acacia_log | #6d655c | | 57 | acacia_leaves | #679a2e |
| 58 | dark_oak_log | #3f2d17 | | 59 | dark_oak_leaves | #2c5e12 |
| 60 | cherry_log | #55283e | | 61 | cherry_leaves | #f0b4cd |

Logs: render O, sol 1, perm 0. Leaves: like id 5 (O today, cutout group 9 later,
perm 0.9, trₛ 0.3).

**Glass (ids 62–67) — the mandated translucents:**

| id | name | swatch (render alpha) | render | cull | sol | perm | trₛ (sim light) |
|---|---|---|---|---|---|---|---|
| 62 | glass | #ffffff (a 0.30) | T | 3 | 1 | 0 | **0.95** |
| 63 | tinted_glass | #2b2633 (a 0.85) | T | 4 | 1 | 0 | **0.0** |
| 64 | white_stained_glass | #ffffff (a 0.55) | T | 5 | 1 | 0 | 0.5 |
| 65 | red_stained_glass | #b02e26 (a 0.55) | T | 6 | 1 | 0 | 0.5 |
| 66 | blue_stained_glass | #3c44aa (a 0.55) | T | 7 | 1 | 0 | 0.5 |
| 67 | green_stained_glass | #5e7c16 (a 0.55) | T | 8 | 1 | 0 | 0.5 |

Note tinted_glass is the showcase for the physics/look split the sim model was
built for: **visually** translucent (render alpha 0.85 dark pane) but **sim**
translucence 0.0 — it blocks the light field completely, exactly like Minecraft.

**Terracotta (ids 68–74) + misc (75–76):**

| id | name | swatch | | id | name | swatch |
|---|---|---|---|---|---|---|
| 68 | terracotta | #985f45 | | 72 | brown_terracotta | #4d3324 |
| 69 | white_terracotta | #d2b2a1 | | 73 | red_terracotta | #8f3d2f |
| 70 | orange_terracotta | #a25426 | | 74 | light_gray_terracotta | #876b62 |
| 71 | yellow_terracotta | #ba8523 | | 75 | obsidian | #100b19 |
| — | — | — | | 76 | amethyst_block | #8662bf |

All O, cull 0, sol 1, perm 0, trₛ 0. **COUNT = 77.**

`extended` tier name list (ids assigned by streaming, generator never emits
them): `orange/magenta/light_blue/yellow/lime/pink/gray/light_gray/cyan/purple/`
`brown/black_stained_glass`, `magenta/light_blue/lime/pink/gray/cyan/purple/`
`blue/green/black_terracotta`, `mangrove_log/leaves`, `pale_oak_log/leaves`,
`crimson_stem`, `warped_stem`, `mud_bricks`, `packed_mud`, `rooted_dirt`,
`smooth_basalt`, `basalt`, `sculk`, `bone_block` (≈ 41 names; texture workstream
gets the full list as data).

### 3.4 Structural priors table (the ⚠SEAM structural-integrity contract)

Columns: real-world analog, real density ρ (kg/m³), compressive prior C (MPa),
tensile prior T (MPa) → game mass (kg/voxel), provisional durability D (N),
provisional attachment A. **D and A get recomputed by the sibling's method; ρ/C/T
are the inputs we commit to.**

| name | analog | ρ | C | T | mass | D | A |
|---|---|---|---|---|---|---|---|
| grass | sod/topsoil (legacy) | — | — | (cohesion ~30 kPa) | 750* | 800* | 0.6 |
| dirt | loam (legacy) | — | — | (cohesion ~25 kPa) | 900* | 900* | 0.6 |
| stone | generic competent rock | 2700 | 100 | 10 | 1500* | 2500* | 1.0 |
| wood/oak_log | oak, along grain | 700 | 50 | ~90 (∥ grain) | 80* | 600* | 1.0 |
| leaf | foliage (legacy) | — | — | — | 100* | 100* | 0.15 |
| bedrock | (unbreakable by decree) | — | ∞ | ∞ | 3000 | ∞ | 1.0 |
| deepslate | slate/gneiss | 2900 | 150 | 15 | 1610 | 3390 | 1.0 |
| granite | granite | 2650 | 130 | 8 | 1470 | 3040 | 0.8 |
| diorite | diorite | 2800 | 120 | 8 | 1560 | 2870 | 0.8 |
| andesite | andesite | 2750 | 120 | 8 | 1530 | 2870 | 0.8 |
| tuff | volcanic tuff | 1600 | 30 | 2 | 890 | 1010 | 0.2 |
| calcite | calcite/marble | 2710 | 50 | 4 | 1510 | 1490 | 0.4 |
| dripstone_block | limestone | 2400 | 60 | 5 | 1330 | 1700 | 0.5 |
| sandstone / red_sandstone | sandstone | 2300 | 60 | 4 | 1280 | 1700 | 0.4 |
| sulfur_block | native sulfur | 2070 | 20 | 1 | 1150 | 750 | 0.1 |
| cinnabar_block | cinnabar-bearing rock | 3000 | 70 | 5 | 1670 | 1910 | 0.5 |
| *_ore (stone host) | host +10 % | — | — | — | 1450–2200 | 2750 | 1.0 |
| deepslate_*_ore | host +10 % | — | — | — | 1560–2310 | 3730 | 1.0 |
| coarse_dirt / podzol / mycelium | dry loam (soil branch) | 1600 | — | cohesion | 900/850/800 | 850/820/820 | 0.5/0.55/0.55 |
| mud | saturated clay-silt | 1800 | — | cohesion | 1000 | 500 | 0.35 |
| clay | stiff clay | 1750 | — | cohesion ~100 kPa | 970 | 1000 | 0.7 |
| sand / red_sand | dry sand, cohesionless | 1600 | — | ~0 | 890 | 400 | **0.05** |
| gravel | loose gravel, cohesionless | 1700 | — | ~0 | 945 | 500 | 0.08 |
| snow_block | compacted snow | 500 | 1 | 0.1 | 280 | 250 | 0.3 |
| moss_block | moss mat | 320 | — | fibrous | 180 | 200 | 0.25 |
| water | water (fluid) | 1000 | — | — | 560 | — (unbreakable-as-fluid) | 0 |
| lava | molten basalt (fluid) | 2770 | — | — | 1540 | — | 0 |
| ice | lake ice | 917 | 8 | 3 | 510 | 380 | 0.3 |
| packed_ice | glacial ice | 920 | 10 | 3.5 | 520 | 440 | 0.35 |
| blue_ice | dense glacial ice | 921 | 12 | 4 | 530 | 510 | 0.4 |
| powder_snow | fresh powder | 200 | ~0 | ~0 | 110 | 30 | 0.02 |
| spruce_log | spruce ∥ grain | 450 | 40 | high ∥ | 50 | 510 | 1.0 |
| birch_log | birch ∥ grain | 640 | 45 | high ∥ | 70 | 555 | 1.0 |
| jungle_log | keruing/mahogany | 660 | 52 | high ∥ | 75 | 620 | 1.0 |
| acacia_log | acacia | 830 | 60 | high ∥ | 95 | 690 | 1.0 |
| dark_oak_log | black oak | 790 | 58 | high ∥ | 90 | 670 | 1.0 |
| cherry_log | cherry | 570 | 45 | high ∥ | 65 | 555 | 1.0 |
| *_leaves | foliage | — | — | — | 90–110 | 100 | 0.15 |
| glass / stained | soda-lime glass, **brittle**: moderate compression, near-zero practical tension (flaw-governed, ~1 MPa design) | 2500 | 50 | **1** | 1390 | 1490 | **0.1** |
| tinted_glass | thicker/laminated glass | 2600 | 55 | 1 | 1450 | 1600 | 0.1 |
| terracotta family | fired clay | 2000 | 25 | 3 | 1110 | 890 | 0.3 |
| obsidian | dense volcanic glass (gameplay-toughest) | 2400 | 300 | 5 | 1330 | 5700 | 0.5 |
| amethyst_block | quartz aggregate | 2650 | 80 | 5 | 1470 | 2110 | 0.5 |

\* frozen legacy value, not recomputed. The §12-addendum ordering invariant
generalises to: *bedrock > deepslate family > stone family > terracotta/glass >
soils > cryo > water > leaves ≥ logs*, with **logs the lightest solid family**
(spruce 50 … acacia 95 < leaf 100) — asserted in §10.

---

## 4. Material data model (authoring)

**Decision: one JSON file, `godot/src/sim/data/blocks.json`,** loaded once by
`BlockCatalog.ensure_ready()` into the existing `VoxelState` array. Record order
IS the id. Schema per record:

```json
{ "name": "glass", "alias": null, "tier": "world",
  "mass": 1390.0, "break_force": 1490.0, "attachment": 0.10,
  "permeability": 0.0, "translucence": 0.95, "solidity": 1.0,
  "swatch": "#ffffff", "render": { "mode": "translucent", "alpha": 0.30,
      "cull_group": 3, "emissive": 0.0 },
  "priors": { "analog": "soda-lime glass", "rho": 2500, "C": 50, "T": 1 } }
```

Why JSON, not `.tres`: (a) diffable/reviewable — a 77-record table in a resource
file is opaque in PRs; (b) trivially consumed by the texture workstream and any
offline tooling; (c) no editor round-trip; (d) the ⚠SEAM streaming workstream can
fetch/patch `extended` records as data. A `.tres` `Array[VoxelState]` was the
runner-up; rejected only for diffability — the loader produces the *same*
`VoxelState` objects either way, so switching later is contained to
`ensure_ready()`. Implementation notes:

- `BlockCatalog` keeps its full public API (`mass_of`, `color_of`, `name_of`,
  `state_of`, `is_solid_id`) and gains `id_of(name: StringName) -> int`,
  `solidity_of(id)`, `cull_group_of(id)`, `render_def_of(id)`, `count()`.
  `COUNT` becomes derived-but-asserted (the const stays for the frozen 6; a
  startup assert checks `count() == 77` against the golden checksum, §10).
- The `const AIR…LEAF` block stays and `ensure_ready()` asserts
  `id_of(&"stone") == STONE` etc. — the consts become *checked aliases*.
- `BlockMaterials.get_for()` becomes data-driven: build a `StandardMaterial3D`
  from the record's `render` block (mode/alpha/emissive/swatch) instead of the
  `match` statement; the grass/wood baked-texture builders stay as per-id
  overrides (and the texture workstream later replaces swatches per-name).
- **Web export gotcha:** `*.json` under `res://` must be included in the export
  preset's non-resource export filter, or the deployed build ships an empty
  catalog. Phase-0 checklist item + a verify assertion that runs in the exported
  context (the headless verify uses the editor binary, so also assert at
  `WorldManager._ready` and fail loudly).
- Load cost: one `FileAccess` + `JSON.parse` of ~30 KB on the main thread at
  startup — negligible; must happen in `ensure_ready()` *before* the voxel
  worker thread starts (already guaranteed: `module_world.setup()` warms it).

---

## 5. Translucent rendering (both paths, one behaviour)

### 5.1 godot_voxel (module) path

godot_voxel's blocky mesher culls the face of voxel A against neighbour B when
B's side geometry fully covers it AND, per
[`VoxelBlockyModel.transparency_index`](https://voxel-tools.readthedocs.io/en/latest/api/VoxelBlockyModel/):
*"If the neighbor voxel at a given side has a transparency index lower or equal
to the current voxel, the side will be culled."* Consequences with our cull
groups mapped 1:1 onto `transparency_index`:

- stone(0) | glass(3): glass's face culled (0 ≤ 3), **stone's face drawn**
  (3 ≰ 0) → you see the stone wall through the pane. Correct.
- glass(3) | glass(3): both culled (equal) → no internal faces inside a glass
  wall. Correct (Minecraft parity).
- red(6) | blue(7) stained: blue's face drawn, red's culled → exactly one face
  between different colours. Correct and cheap.
- water(1) | glass(3): glass draws its face (1 ≤ 3 culls the *water* side… i.e.
  water's face against glass is culled (3 ≰ 1 → drawn? apply rule per-voxel:
  water's neighbour glass has index 3 > 1 → **not** culled → water face drawn;
  glass's neighbour water has 1 ≤ 3 → glass face culled). One face, water's.
  Acceptable either way — the invariant is *exactly one* face at every
  transparent/transparent boundary and *the opaque side's* face at every
  opaque/transparent boundary.
- `culls_neighbors` stays `true` (default) for glass/water/ice — a transparent
  model with full cube sides still only culls via the index rule above. For
  future cutout leaves (group 9) we may set `culls_neighbors = false` for the
  dense-foliage look; **not** on web by default (face-count blowup on the single
  voxel thread).

Library build (`module_world._configure_library`) changes:
- loop over `BlockCatalog.count()` in id order (replacing the hardcoded 5-id
  array), assert `add_model() == id` for **every** id (invariant now machine-
  checked at 77 models);
- per model: `set_transparency_index(cull_group)`, `set_material_override(0,
  BlockMaterials.get_for(id))` — the material carries the actual alpha blend;
- `transparent` StandardMaterial3D config: `transparency =
  TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` (kills most sorting artifacts for thick
  glass/water at cube scale), `cull_mode = CULL_DISABLED` for water (visible
  from below), `render_priority` water < glass so the sea draws before panes.

### 5.2 GDScript fallback path

The fallback mesher culls with `world.cell_solid(...)` (`chunk_mesher.gd:207`),
which after §6.3 means "solidity ≥ 0.5" — glass would occlude like stone and
water like air. Both are wrong for faces. Introduce one predicate on
`WorldManager` (single owner, mirrored from the module rule):

```gdscript
## True when neighbour cell `nb` occludes a face of a cell whose cull group is
## `my_group` (mirror of the module path's transparency_index rule).
func occludes_face(nb: Vector3i, my_group: int) -> bool:
    var nid := block_id_at(nb)
    if nid == BlockCatalog.AIR:
        return false
    var ng := BlockCatalog.cull_group_of(nid)
    if ng == 0:
        return BlockCatalog.solidity_of(nid) >= 0.5   # opaque solid occludes all
    return ng >= my_group                             # index rule, one face per boundary
```

- `_emit_cube` (trees/placed blocks — where placed **glass** lives) swaps its
  `world.cell_solid(cell + nrm)` check for
  `world.occludes_face(cell + nrm, my_group)`.
- Each block id already gets its own `SurfaceTool` surface + `BlockMaterials`
  material, so translucent ids automatically land in separate surfaces with a
  transparent material — Godot then depth-sorts those surfaces against opaques.
  No mesher-level sorting is added (per-mesh sort is Godot's; artifacts noted in
  §11).
- **Water in the fallback** is NOT per-cell cubes (the fallback stays a
  heightmap skin): per chunk, emit one translucent quad at `y = SEA_LEVEL + 1`
  (top face) over the bounding rect of columns with `effective_height < SEA_LEVEL`,
  plus side skirts at the chunk border where the neighbour chunk is dry. Sea
  floors get their surface-rule id (sand/gravel) from the normal top/side
  passes, tinted by depth only via the water quad's alpha — safety-net grade,
  matching the fallback's existing fidelity contract.
- Fallback top/side passes read ids via `block_id_at` already; the only rule
  added: a column whose *top* is water renders its **solid** top at
  `effective_height` (the seafloor), never a water "top id" — i.e. the
  heightmap passes are computed over solid-only heights (`effective_height`
  semantics unchanged, see §6.3).

### 5.3 Fit with the per-id BlockMaterials / 1×1-atlas model

Nothing about the 1×1-tile atlas changes: transparent cubes use the same
`set_atlas_size_in_tiles(1,1)` + full-face tile; alpha comes from the material,
not the mesh. When the texture workstream lands real textures, translucent ids
use textured materials with `transparency` still set from the catalog's `render`
record — the catalog field, not the texture, stays the source of truth.

---

## 6. The adapted worldgen pipeline

All new constants live in `TerrainConfig`; all new noises are built inside the
existing `_ensure_noise()` (single warm-up point — `module_world.setup()`'s
main-thread warm call then covers everything; forgetting a noise there is a
race, see §11.6).

### 6.1 Vertical structure (world-space, our scale)

Our surface sits at y ≈ 5 ± a few; Minecraft's spans −64…320 with sea at 63. We
keep our surface scale and adopt Minecraft's *below-ground* structure nearly 1:1:

| Constant | Value | Minecraft analog |
|---|---|---|
| `WORLD_BOTTOM_Y` | −64 | −64 |
| bedrock gradient | 100 % at −64 → 0 % at −59, hash-dithered | identical |
| `DEEPSLATE_FULL_Y` / `DEEPSLATE_TOP_Y` | −24 / −16 (dithered band between) | 0 / 8 (shifted down: our surface is ~58 lower) |
| `SEA_LEVEL` | 0 | 63 |
| `generated_block` for y < −64 | AIR (void; unreachable — bedrock is unbreakable) | void |

The "never hollow" invariant becomes "**never hollow above bedrock**"; the void
below −64 is unreachable by construction (bedrock D = ∞, and `place_block`/break
can't get past it), so `floor_under`'s −1024 scan bound stays safe.

### 6.2 Pipeline stages (order matters; each stage is a pure function)

```
biome_at(x,z)                       # stage 1: 2D climate noises -> biome enum
height_at(x,z)                      # stage 2: continentalness spline + existing hills/detail
surface_rule(biome, g, y, underwater)  # stage 3: top / filler band / default-rock
deep_family(x,y,z)                  # stage 4: stone -> deepslate gradient -> strata blobs
ore_at(x,y,z, host)                 # stage 5: host-aware ore lattice
water/ice fill                      # stage 6: air below SEA_LEVEL -> water (ice cap in frozen biomes)
TreeGen (biome-aware species)       # stage 7: existing overlay, parameterised
[caves]                             # stage 8: STAGED — see §6.8
```

Composed (target shape of `TerrainConfig.generated_block`):

```gdscript
static func generated_block(x: int, y: int, z: int) -> int:
    if y < WORLD_BOTTOM_Y:
        return BlockCatalog.AIR
    if _bedrock_at(x, y, z):                       # dithered floor gradient
        return BlockCatalog.BEDROCK
    var g := height_at(x, z)                       # continent-aware (§6.4)
    if y > g:                                      # above solid ground
        if y <= SEA_LEVEL:                         # sea fill (g < y <= 0)
            return _sea_block(x, y, z)             # WATER, or ICE cap in frozen biomes
        return TreeGen.block_at(x, y, z)           # species per biome (§6.7)
    var b := biome_at(x, z)
    var id := _surface_rule(b, x, y, z, g)         # top / filler / STONE default
    if id == BlockCatalog.STONE:
        id = _deep_family(x, y, z)                 # deepslate gradient + strata blobs
        id = _ore_at(x, y, z, id)                  # host-aware replacement
    # [stage 8, later] if _cave_carved(x, y, z, g): return cave fluid or AIR
    return id
```

### 6.3 Solidity becomes id-aware (the one gameplay-visible semantic change)

`WorldManager.cell_solid` changes from `id != AIR` to
`BlockCatalog.solidity_of(id) >= 0.5`. Effects, audited per consumer:

- **water / lava / powder_snow are non-colliding**: `blocked()` lets the player
  walk into the sea, `floor_under` scans through water to the seafloor — the
  player wades/sinks and walks on the bottom. Swimming/buoyancy/breath and lava
  damage are explicitly **out of scope** (⚠SEAM: future player workstream); the
  Stage-1 sea is shallow (≤ ~14 deep) so this is playable, if unglamorous.
- `aimed_voxel` (DDA) uses `_cell_solid` → automatically **targets through
  water** to the seafloor. Correct default. Breaking water is impossible
  (`break_terrain` early-outs on `not cell_solid`), placing INTO a water cell:
  `place_block`'s `cell_solid` check returns false for water → placement into
  water **succeeds and overwrites it** via the overlay. That is the desired
  Minecraft behaviour, for free — but note the overlay now hides a water cell,
  and *breaking* that placed block writes overlay 0 = **air**, leaving a dry
  hole in the sea. Accepted for Stage 1 (no fluid flow model); documented
  quirk, revisit with fluid sim.
- `_collapse_unsupported` flood-fills through `_cell_solid` → water never
  supports and never becomes a `VoxelBody`. Sand undercut by digging still
  behaves as today (binary support) until the ⚠SEAM structural-integrity work
  consumes `attachment`.
- `effective_height(x,z)` semantics: **"top-most solid"** — its `while
  is_removed(...)` loop is unchanged, but its starting `height_at` is the solid
  ground height `g` by definition (water sits *above* g), so no change needed.
- `place_block`'s id validation (`>= BlockCatalog.COUNT`) reads `count()`; it
  additionally rejects ids with `solidity < 0.5` (no placing water/lava from the
  hotbar until fluids are real).

### 6.4 Biomes + terrain shape (stage 1–2)

Three new 2D noises (all `TYPE_SIMPLEX_SMOOTH`, FBM 2 octaves, seeds
`SEED+101/102/103`): `_continent` (freq 0.0015), `_temperature` (freq 0.002),
`_humidity` (freq 0.002).

`height_at` gains a continental offset through a 4-knot spline (piecewise-linear,
deterministic float math):

| continent c | offset | meaning |
|---|---|---|
| −1.0 … −0.45 | −14 … −6 | deep ocean basin |
| −0.45 … −0.15 | −6 … 0 | shelf / coast |
| −0.15 … 0.4 | 0 … +2 | inland plains (today's look preserved) |
| 0.4 … 1.0 | +2 … +11 | highlands (emerald host; snow-capped later) |

Surface range becomes ≈ −14 … +16; existing `BASE_HEIGHT/HILLS/DETAIL` unchanged
on top. **Plains at c ≈ 0 look exactly like today's world** (offset ~0) — the
current demo terrain is a proper subset of the new generator.

Biome selection: an ordered, deterministic rule chain on (c, T=`_temperature`,
H=`_humidity`) — first match wins:

| # | biome | rule | top | filler (depth) | underwater floor | trees |
|---|---|---|---|---|---|---|
| 1 | ocean | `c < −0.32` | — (seafloor rule) | — | sand (T>0) / gravel (T≤0) | — |
| 2 | beach | `g ∈ [SEA_LEVEL−2, SEA_LEVEL+2]` | sand | sand(3), sandstone(3) | sand | — |
| 3 | badlands | `T > 0.45 and H < −0.45` | red_sand | terracotta bands(8) → red_sandstone(4) | red_sand | — |
| 4 | desert | `T > 0.45 and H < 0.0` | sand | sand(3), sandstone(4) | sand | — |
| 5 | swamp | `T > 0.15 and H > 0.5` | mud | mud(3), dirt(2) | mud | oak, sparse |
| 6 | snowy | `T < −0.55` | snow_block | dirt(3) | gravel | spruce, sparse |
| 7 | taiga | `T < −0.15` | grass (podzol patches, hash 20 %) | dirt(3) | gravel | spruce, medium |
| 8 | forest | `H > 0.1` | grass | dirt(3) | gravel | oak+birch, dense |
| 9 | plains | (default) | grass | dirt(3) | gravel | oak, sparse (today's density) |

(mycelium/mushroom-fields, jungle/acacia/dark-oak/cherry biomes: authored the
same way in a follow-up — their *blocks* are already in the catalog, which is
the hard part; the rule table is data.)

Badlands terracotta bands: `band_color = BAND_SEQ[posmod(y + _band_shift(x, z),
BAND_SEQ.size())]` where `BAND_SEQ` is a fixed const sequence of the 7
terracotta ids and `_band_shift` is a hash on a 512-column lattice (bands drift
slowly, MC-style).

### 6.5 Surface rule + deepslate + strata (stages 3–4)

`_surface_rule` generalises today's grass/dirt/stone stackup: `y == g` → biome
top (underwater columns use the *underwater floor* id instead — **no grass below
sea level**), `y > g − filler_depth` → biome filler (banded for badlands),
else `STONE`. `stone_height_at` (the decorrelated stone relief) is retired in
favour of per-biome filler depths — its "stone has its own relief" role is
superseded by strata blobs below; the §10 relief test is replaced accordingly.

`_deep_family(x,y,z)` for cells that resolved to STONE:
1. deepslate gradient: below `DEEPSLATE_FULL_Y` → DEEPSLATE; in
   `[DEEPSLATE_FULL_Y, DEEPSLATE_TOP_Y]` → DEEPSLATE iff
   `_hash01(x,y,z, salt) < (DEEPSLATE_TOP_Y − y) / float(band)` (per-cell
   dither, MC-style ragged boundary).
2. strata blobs (granite/diorite/andesite/tuff/calcite/dripstone + rare
   sulfur/cinnabar pockets below −32): a 16³ lattice; per lattice cell one hash
   decides (p = 0.25) whether it hosts a blob, which variant, its centre
   (jittered, clamped so centre ± radius stays inside the cell — the **TreeGen
   containment trick**, so any world cell consults exactly ONE lattice cell)
   and its ellipsoid radii (3–7). Query: distance test against the own-cell
   blob; if inside, replace STONE→variant / DEEPSLATE→(tuff stays tuff, others
   skipped below the transition — deepslate remains dominant at depth, MC-like).

### 6.6 Ores (stage 5) — deterministic lattice, triangle distributions

One **6³ ore-attempt lattice**. Per lattice cell: `_hash01(cell, salt_a)` →
attempt exists (p = 0.55); attempt centre jittered with containment clamp
(radius ≤ 2 ⇒ jitter ∈ [2, 3]); ore type drawn from the depth table below by
sampling each ore's triangle/uniform density at the centre's y and picking via
one weighted hash; blob = ellipsoid of 1–8 voxels. A queried cell checks only
its own lattice cell (a handful of integer hashes — same budget class as
`TreeGen.block_at`). Replacement is **host-aware at query time**: STONE →
`X_ore`, DEEPSLATE → `deepslate_X_ore`, any other host → unchanged (ore never
appears in dirt/strata — mirrors MC's stone-replaceable rule). Host-awareness
after stage 4 is what guarantees the *"deepslate ores only below the
transition"* invariant with zero extra logic.

Depth table (our scale; shapes and relative rates adapted from the
[1.18-era distribution](https://minecraft.wiki/w/Ore), vertical range compressed
from −64…320 to −64…+16):

| ore | y-range | shape | peak | weight (rel.) | notes |
|---|---|---|---|---|---|
| coal | −8 … +16 | triangle | +8 | 30 | shallow; most common |
| copper | −16 … +12 | triangle | +4 | 25 | |
| iron | −56 … +12 | triangle | −8 | 25 | |
| gold | −60 … −8 | triangle | −32 | 10 | ×4 weight in badlands columns (MC parity) |
| redstone | −64 … −24 | triangle | −56 | 14 | |
| lapis | −52 … −6 | triangle | −28 | 8 | |
| diamond | −64 … −40 | triangle | −58 | 6 | deepest |
| emerald | −8 … +16 | triangle | +12 | 3 | **only** where continent c > 0.4 (highlands = our "mountains") |

Expected ore fraction of deep-stone volume ≈ 1.2 % (tunable via lattice p and
blob size); §10 asserts measured rates within ×⅓…×3 of the table per ore.

### 6.7 Water, ice, beaches, trees (stages 6–7)

- `_sea_block`: y ≤ SEA_LEVEL and y > g → WATER, except `y == SEA_LEVEL` in
  biome `snowy` → ICE (frozen cap; ice is solid — you can walk the frozen sea,
  and breaking it exposes non-solid water below: the first genuinely
  Minecraft-feeling emergent interaction this design ships).
- Beaches/seafloors come from the biome table (rules 1–2).
- **TreeGen** keeps its grid/patch/containment machinery verbatim and gains a
  species layer: `species_of(gx, gz)` = biome of the base column + one hash
  (forest: 70 % oak / 30 % birch; taiga/snowy: spruce; swamp: oak; plains: oak).
  Per-species param rows `(log_id, leaf_id, trunk_min, trunk_max, canopy)`:
  oak keeps today's exact shape **and today's hash salts** (existing trees
  don't move); spruce is taller (5–8) with a 2-layer conical canopy; birch =
  oak shape with birch ids. `MAX_ABOVE_SURFACE` rises 7 → 10 (spruce), which
  transparently widens the collapse-scan and collider vertical bounds that
  already read it. Desert/badlands/ocean/beach: `has_tree` returns false
  (biome gate added before the patch gate). Jungle/acacia/dark-oak/cherry
  species ship with their biomes later; their blocks exist now.

### 6.8 Caves & overhangs — the staged decision

**Recommendation: ship Stages 0–2 heightmap-only; add caves in Stage 3 as a
per-cell noise predicate; do NOT adopt 3D-density terrain (true overhangs) in
this workstream.** Reasoning:

- *Cost of staying heightmap-only:* zero risk; the biggest visible wins of this
  design (biomes, sea, deepslate strata, ores, species, glass) don't need holes.
  Digging already provides underground gameplay; ores make digging worthwhile.
- *Cost of caves:* (a) generator: MC-style spaghetti caves need two 3D noise
  samples per cell — on the web's **single voxel thread** that roughly doubles
  generation cost unless gated (`only evaluate for y < g − 3`, early-out above);
  (b) **fallback mesher** is a heightmap skin and cannot show a mid-column
  hole: gameplay would stay correct (all physics is `block_id_at`-driven and
  per-cell — `floor_under` scans cells, `blocked` scans cells, `GroundCollider`
  builds per-cell boxes, collapse seeds the boundary shell) but the fallback
  would render terrain over an open cave: the player *sees* ground, *falls*
  through a hole — a "two paths, one behaviour" violation on the visual axis;
  (c) `_collapse_unsupported`'s bottom-row seeding already tolerates hollow
  cells (it seeds the whole boundary *shell*, biased to "supported"), so
  correctness holds, at most missing some floaters near cave mouths.
- *Cost of 3D density terrain (overhangs):* invalidates `height_at` as "the
  surface" — surface rules, TreeGen ground anchoring, sea fill, the thermometer
  depth model and the fallback mesher all key off it. That's an
  engine-milestone rewrite, not a worldgen patch. Defer; the seam is that
  `generated_block` remains the only contract, so density terrain later
  replaces internals without touching consumers.

Stage-3 cave shape (when taken): spaghetti = carve iff
`a(x,y,z)² + b(x,y,z)² < r(y)²` with two `FastNoiseLite` 3D simplex noises
(seeds SEED+201/202, freq 0.02) — MC's actual formulation, and a **pure
per-cell predicate** (no carver state, deterministic, both generators agree by
construction); cheese chambers = one 3D noise > depth-dependent threshold,
below y = −8 only. Sub-stage 3a keeps caves **sealed** (carve only y < g − 4;
no surface entrances; fallback visual mismatch invisible from above ground);
3b opens entrances once the fallback path either gets a local 3D cube pass
around carved columns or is formally demoted to "flat-world safety net"
(decision owned by whoever lands 3b; `module_in_web=yes` today makes the
module path the only user-facing one). Cave fluids: below y −52 carved cells
emit LAVA, below local water pockets WATER — a fixed-y rule, not MC aquifers,
to stay per-cell pure.

---

## 7. Determinism & performance guarantees

1. **No per-run randomness**: every new decision is `FastNoiseLite` with a
   const seed derived from `TerrainConfig.SEED` + a documented salt, or
   `TreeGen._hash01`-family integer hashing. Salt registry table goes into the
   implementation PR (one place, no collisions).
2. **Both render paths agree by construction**: the module generator (the
   runtime-compiled `VoxelGeneratorScript` in `module_world.gd`) is rewritten to
   call the *same* staged helpers; like today it caches per-column values
   (g, biome, filler depths) in arrays per 16³ buffer and keeps the
   whole-buffer-above-max-height early-out. Per-voxel work added: 1 hash
   (deepslate dither, only in the band) + 1 lattice check (strata) + 1 lattice
   check (ores, only for stone-family hosts). Per-column work added: 3 2D noise
   samples (continent/temp/humidity). Within the ~2× budget of today's
   generator on the web thread.
3. **Cross-run / cross-path float caveat**: intra-process agreement (module
   generator vs analytic queries vs collapse) is exact — same functions, same
   binary. Cross-*platform* bit-identity of FastNoiseLite floats (wasm vs
   native) is NOT asserted; nothing persists worlds across platforms today, so
   only intra-session determinism is load-bearing. Flagged for whenever world
   persistence lands.
4. **Main-thread noise warm-up**: all new noises are constructed inside
   `_ensure_noise()`; `module_world.setup()`'s existing
   `TerrainConfig.height_at(0,0)` warm call must be extended to a dedicated
   `TerrainConfig.warm_up()` that touches *every* lazy singleton (noises +
   catalog + strata/ore salt tables), because a lazily-built noise first touched
   on the voxel worker thread is a data race → run-to-run divergence (§11.6).

---

## 8. Player-physics implications (audit)

| Consumer | Assumption today | After this design |
|---|---|---|
| `floor_under` (`world_manager.gd:318`) | per-cell down-scan; "always finds a block" | unchanged; water is non-solid so the scan lands on the seafloor. Void below −64 unreachable (bedrock). Caves (Stage 3): still correct — scan is per-cell. |
| `blocked` | per-cell span check | unchanged; water doesn't block (wading). Powder snow doesn't block (sinking-in feel, crude but right-ish). |
| `GroundCollider` | boxes from per-cell solidity around player | unchanged (reads `cell_solid`); water columns simply produce no boxes. |
| `aimed_voxel` DDA | first solid cell | targets through water; ICE targets normally. |
| `effective_height` / `surface_y` | heightmap top minus top-dug | unchanged Stage 0–2; Stage 3a caves are sealed below g−4 so the top stays honest; 3b revisits. |
| `_collapse_unsupported` | bottom row solid in every column | boundary-shell seeding already tolerates non-solid cells; water never supports (correct: sand shelf over water can collapse). y-bounds via `MAX_ABOVE_SURFACE` pick up the spruce raise automatically. |
| `VoxelBody` | mass from catalog | new masses flow in automatically; heaviest breakable body cell = deepslate ore 2310 kg — pushable-but-barely, consistent with the §12 mass sandbox. |
| Player spawn | `surface_y` at origin | origin is plains by construction? **No** — c at origin is seed-dependent. Add `TerrainConfig.find_spawn()`: deterministic outward ring scan from (0,0) for the first column with `g > SEA_LEVEL + 1` and biome ∈ {plains, forest}. Tiny, but without it the demo can spawn in the sea (§11.9). |

---

## 9. Integration summary (what changes where)

1. `sim/block_catalog.gd` — loads `sim/data/blocks.json`; consts become checked
   aliases; new accessors (`id_of`, `solidity_of`, `cull_group_of`,
   `render_def_of`, `count()`).
2. `sim/data/blocks.json` — NEW; the §3 table verbatim.
3. `world/block_materials.gd` — data-driven material builder (mode/alpha/
   emissive/swatch); grass/wood texture builders kept as overrides.
4. `world/terrain_config.gd` — new constants + noises; `generated_block`
   restructured into the §6.2 stages; `height_at` continent spline;
   `warm_up()`; `stone_height_at` retired.
5. `world/tree_gen.gd` — species layer + biome gate; oak bit-identical.
6. `world/world_manager.gd` — `cell_solid` reads solidity; `occludes_face`
   added; `place_block` validity = `0 < id < count() && solidity ≥ 0.5`.
7. `world/voxel_module/module_world.gd` — library loop over full catalog with
   per-id assert + `transparency_index`; generator source mirrors the staged
   pipeline with per-column caching.
8. `world/fallback/chunk_mesher.gd` — `occludes_face` in `_emit_cube`; water
   quad pass; (tops/sides already per-id, nothing else changes).
9. `src/tools/verify_feature.gd` — §10.
10. Export preset — include `*.json`.
- ⚠SEAM sub-voxel smoothing: it consumes the same `generated_block` ids; our
  only promise is that *surface* ids (grass/sand/snow/mud tops) are stable
  per-column and biome boundaries are noise-smooth (no single-column biome
  speckle at our noise frequencies) so its normals don't flicker. Cull groups
  are irrelevant to it (it smooths opaque terrain; translucents excluded).

## 10. Phased implementation plan

- **Phase 0 — data-driven catalog (no visual change).** blocks.json with ONLY
  the frozen 6; loader + asserts + golden checksum; BlockMaterials data-driven;
  module library loop generalised; export-preset json. Verify: world renders
  identically on both paths; catalog integrity tests green.
- **Phase 1 — depth.** Full 77-record json. Bedrock, deepslate gradient,
  strata blobs, ore lattice. World surface unchanged; digging gets a payoff.
- **Phase 2 — breadth + translucency.** Continent spline, biomes, surface
  rules, sea/ice/beaches, tree species, water rendering both paths, glass
  place/break, `cell_solid` solidity semantics, `find_spawn()`.
- **Phase 3 — caves.** 3a sealed spaghetti/cheese + cave fluids; 3b open
  entrances + fallback decision. Each behind one `TerrainConfig` feature const.
- **Phase 4 — extended tier** streaming integration (⚠SEAM) + textures (⚠SEAM).

Each phase independently shippable and verified headlessly before the next.

### verify_feature.gd extensions (per phase)

- *Catalog (P0):* dense ids 0…count−1; unique names; frozen-6 values
  bit-identical; `id_of` round-trips; **golden checksum** of
  (name,id) pairs — a reorder/insertion fails loudly; module library assert
  loop covers every id; json loads in exported pack.
- *Depth (P1):* `generated_block(x,−64,z) == BEDROCK` everywhere; no bedrock
  above −59; deepslate fraction ≈0/≈1 sampled above/below the band, mixed
  inside; **ores:** volume scan (e.g. 64×88×64 cells) → per-ore rate within
  ×⅓…×3 of §6.6; ore hosts are stone/deepslate only; deepslate_* variants only
  below `DEEPSLATE_TOP_Y`; diamond never above −40.
- *Breadth (P2):* biome determinism (two calls agree) + coverage (≥6 biomes in
  a 4096² sample); no grass below SEA_LEVEL; every column with g < SEA_LEVEL is
  water-filled up to it and **no water above** SEA_LEVEL; beach sand present on
  a found coast; snowy sea surface is ICE and `cell_solid(ice)==true` while
  `cell_solid(water)==false`; place GLASS → `block_id_at` returns it, catalog
  says trₛ>0 ∧ solidity==1, its render material has `transparency != DISABLED`,
  cull_group ≠ 0; `occludes_face`: glass|glass culls both, stone|glass draws
  stone's face only, water|glass draws exactly one (table-driven micro-test);
  place_block rejects water id; spruce tree found in taiga with spruce_log
  trunk; masses: logs lightest family, legacy ordering intact.
- *Caves (P3):* sealed-mode: no carved cell with y > g−4; a found cave cell has
  `floor_under` returning a real floor beneath it; collapse near a cave mouth
  spawns no phantom bodies (break, assert body count sane).

## 11. How it breaks (adversarial self-review)

1. **Id explosion / silent recolour.** One mid-file json insertion shifts 50 ids;
   module path asserts, but the *fallback* path would just recolour. Mitigation:
   golden checksum test + append-only rule in the json header comment + the
   per-id library assert. Residual risk: someone updates the checksum blindly —
   review rule: checksum changes require a catalog-diff in the PR description.
2. **Persisted-id drift vs streaming.** ⚠SEAM: if runtime streaming ever
   *renumbers* dense ids, the edit overlay/inventory/VoxelBody cells poison.
   Our catalog assumes stable-forever ids for `core`+`world`; streaming may
   only append. Stated here as a hard interface requirement.
3. **Transparency culling divergence between paths.** The module rule
   (`neighbor_index ≤ mine ⇒ cull`) and fallback `occludes_face` are written in
   two places; a drift makes glass walls double-faced in one path or hollow in
   the other. Mitigation: the P2 table-driven micro-test encodes the truth
   table once and the fallback predicate is the single `WorldManager` owner;
   module side is config (indices), not logic.
4. **Godot transparent sorting artifacts.** Per-surface sorting: two translucent
   surfaces in one chunk mesh can pop against each other (stained glass behind
   water). `ALPHA_DEPTH_PRE_PASS` + water render_priority mitigates; cube-scale
   worlds tolerate the rest. Not fully solvable without per-face sorting —
   accepted, documented.
5. **`!= AIR` solidity audit misses.** Any forgotten `!= BlockCatalog.AIR`
   solidity check treats water as ground (e.g. a future spawn check). Grep-audit
   in P2: every solidity decision must go through `cell_solid`/`is_solid_id`;
   `is_solid_id` itself is redefined to solidity-aware and its name kept.
6. **Lazy-noise thread race.** A new noise first touched on the voxel worker
   thread = two half-built noise stacks = *non-deterministic terrain per run*,
   the project's worst-case bug class. Mitigation: single `warm_up()` +
   verify asserts that `_ensure_noise` constructs every declared noise (count
   check), and module `setup()` calls `warm_up()` before creating the terrain.
7. **Lattice containment bugs** (strata/ore blob leaking into a neighbour cell
   → cell queries would need neighbour scans they don't do → holes in blobs at
   lattice borders). Mitigation: the jitter-clamp is a shared helper with the
   TreeGen-proven formula + a property test (sample 10⁵ blobs, assert
   centre±radius inside cell).
8. **Web perf regression.** 77 models bake fine, but per-voxel hashes add up on
   1 thread; and the fallback's per-id surfaces could hit 20+ surfaces/chunk in
   ore-rich chunks — acceptable (fallback is safety-net), but the *module*
   generator must keep the early-outs (§7.2), and cave noise (P3) must be
   depth-gated or web chunk latency doubles.
9. **Sea spawn / sea-adjacent regressions.** Player spawns in ocean; trees at
   beach edges; thermometer over water reads ground temp of the seafloor
   (PerVoxelEnvironment keys on `height_at` — water cells sit above g, so
   "ground" under a boat is the seafloor: fine, but the HUD's "Ground temp"
   over deep ocean is a 14 m-deep value — cosmetic oddity, noted for the sim
   workstream ⚠SEAM: water temperature model).
10. **Placing-then-breaking in water leaves air holes** (§6.3) — intended-for-now
   quirk; becomes wrong the day fluids flow. Tracked here so fluid-sim work
   knows to migrate overlay-0-in-sea cells.
11. **Badlands band determinism**: `posmod` (not `%`) for negative y, or bands
   mirror-glitch below 0 — encode in the helper, cover with one assert.

---

## Appendix A — texture workstream name list (stable, final)

`air, grass, dirt, stone, wood(oak_log), leaf(oak_leaves), bedrock, deepslate,
granite, diorite, andesite, tuff, calcite, dripstone_block, sandstone,
red_sandstone, sulfur_block, cinnabar_block, coal_ore, copper_ore, iron_ore,
gold_ore, redstone_ore, lapis_ore, diamond_ore, emerald_ore,
deepslate_coal_ore, deepslate_copper_ore, deepslate_iron_ore,
deepslate_gold_ore, deepslate_redstone_ore, deepslate_lapis_ore,
deepslate_diamond_ore, deepslate_emerald_ore, coarse_dirt, podzol, mycelium,
mud, clay, sand, red_sand, gravel, snow_block, moss_block, water, lava, ice,
packed_ice, blue_ice, powder_snow, spruce_log, spruce_leaves, birch_log,
birch_leaves, jungle_log, jungle_leaves, acacia_log, acacia_leaves,
dark_oak_log, dark_oak_leaves, cherry_log, cherry_leaves, glass, tinted_glass,
white_stained_glass, red_stained_glass, blue_stained_glass,
green_stained_glass, terracotta, white_terracotta, orange_terracotta,
yellow_terracotta, brown_terracotta, red_terracotta, light_gray_terracotta,
obsidian, amethyst_block` — 77 names, ids 0–76 in this exact order.
