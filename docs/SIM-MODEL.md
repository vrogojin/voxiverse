# VOXIVERSE — Simulation Model

This document specifies the decoupled simulation layer built for the grass test
environment (DESIGN §3). The layer lives under `godot/src/sim/` and knows nothing
about rendering: it derives everything from the shared heightmap in
`godot/src/world/terrain_config.gd`, so it is identical for both the
`godot_voxel` module path and the pure-GDScript fallback path.

## 1. Layers and files

| Concept | File | Role |
|---|---|---|
| Material definition | `sim/voxel_material_def.gd` (`VoxelMaterialDef`) | id + states + the state machine (`resolve_state`) |
| Material state | `sim/voxel_state.gd` (`VoxelState`) | per-state **physics** + **look** + outgoing transitions |
| State transition | `sim/voxel_state_transition.gd` (`VoxelStateTransition`) | "switch state when field crosses threshold" |
| Material registry | `sim/material_registry.gd` (`MaterialRegistry`) | registers known materials (ships `grass`) |
| Environment fields | `sim/per_voxel_environment.gd` (`PerVoxelEnvironment`) | `temperature/light/pressure/electric_current/magnetic_field/gravity` per voxel |

The thermometer HUD and the material state machine read **only** through
`PerVoxelEnvironment`. No temperatures are computed anywhere else — adding or
changing a field or material never touches the mesher or the HUD.

## 2. Voxel material & state machine

A `VoxelMaterialDef` is an `id` plus one or more `VoxelState`s. Each state carries
the physics the simulation cares about (`mass`, `density`, `break_force`,
`attachment`, `permeability`, `albedo`, `translucence`, `emission`, `solidity`)
and the look the renderer cares about (`texture`, `tint`, `glow`). The two sets
are independent: rendering reads only the look, simulation reads only the physics.

`VoxelMaterialDef.resolve_state(current, sample)` is the state machine: it walks
the current state's transitions in order and returns the first one whose
condition fires (`VoxelStateTransition.is_triggered`), else the current state.

The ground `surface` material (`sim/surface_model.gd`) ships as a single state
`grass` (unbreakable: `break_force = INF`) with **no** transitions, so it never
changes — but `block_id_at` still resolves it through the material framework, so
adding more surface states (mud, sand, ice, …) and temperature/light/current
transitions is a pure data change here, with no mesher or HUD edits.

## 3. Per-voxel environment fields

`PerVoxelEnvironment` exposes one query per field, plus `sample(pos)` returning
all fields as a dictionary (the input format `resolve_state` consumes). A voxel
is identified by flooring a world position to its integer cell. Solidity/height
come from `TerrainConfig` (a cell is solid grass when `y <= height_at(x, z)`).

`temperature` and `light` are modelled for real; the rest are physically-sane
stubs ready to be fleshed out:

| Field | Status | Value |
|---|---|---|
| `temperature(pos)` | **modelled** | see §4 |
| `light(pos)` | **modelled** | see §5 |
| `pressure(pos)` | stub | `101.325` kPa (standard atmosphere) |
| `electric_current(pos)` | stub | `0.0` |
| `magnetic_field(pos)` | stub | `Vector3(0, 0, 5.0e-5)` T (~50 µT, Earth-like) |
| `gravity(pos)` | stub | `Vector3(0, -9.81, 0)` m/s² |

## 4. Temperature model (the formula)

Air is a **uniform 21.5 °C** (DESIGN §1). Ground uses a surface/depth model: the
exposed surface sits a touch above air (sun-warmed), then relaxes exponentially
toward a stable subsurface value with depth.

```
air                                    = T_AIR

cell is air (cell_y > surface_y):
    T = T_AIR

cell is ground (depth = surface_y - cell_y >= 0):
    T_surface = T_AIR + SURFACE_OFFSET
    T = T_DEEP + (T_surface - T_DEEP) * exp(-depth / DECAY_DEPTH)
```

with the constants (in `per_voxel_environment.gd`):

| Constant | Value | Meaning |
|---|---|---|
| `T_AIR` | 21.5 °C | uniform air temperature (DESIGN §1) |
| `SURFACE_OFFSET` | +1.5 °C | sun-warmed exposed surface sits this much above air |
| `T_DEEP` | 12.0 °C | stable subsurface temperature the deep ground trends to |
| `DECAY_DEPTH` | 4.0 m | e-folding depth of the exponential relaxation |

The HUD's **Air temp** and **Ground temp** read this model directly (no
special-casing). Verified headlessly with Godot 4.4: air = 21.5 °C everywhere;
exposed ground surface = 23.0 °C; deep ground trends to 12.0 °C.

> An earlier iteration made air fall with altitude (a lapse rate) to drive
> temperature-based snow caps on tall mountains. The mountains were removed for
> the physics sandbox (terrain is now gentle, shallow hills), so the lapse rate
> and the snow state were dropped and air returned to a uniform value.

## 5. Light model

Air and the exposed surface block are fully lit; light attenuates exponentially
below the surface:

```
depth <= 0:  light = 1.0
depth  > 0:  light = exp(-depth / LIGHT_DEPTH)      LIGHT_DEPTH = 1.5 m
```

Normalised to `[0, 1]`. (Verified: air = 1.0, 5 m deep = 0.036.)

## 6. The block catalog (five materials today)

`BlockCatalog` (`sim/block_catalog.gd`) is the authoritative block-id table, built
on the §2 `VoxelState` framework so ids, masses, colours and names live in one
place. Everyone reads from it: physics reads masses, the render layer reads
ids/looks, the hotbar UI reads colours/names.

| id | name | mass (kg/voxel) | look | notes |
|----|-------|-----------------|------|-------|
| 0 | air | — | — | passable |
| 1 | grass | 750 | baked grass PNG | generated **only** as the top cell of a column |
| 2 | dirt | 900 | solid brown | band under grass |
| 3 | stone | **1500 (heaviest)** | solid grey | deep layer, own noise, ≥3 below grass |
| 4 | wood | **80 (lightest)** | baked wood grain (never tinted) | tree trunks; the pushable sandbox |
| 5 | leaf | 100 | solid dark green | tree canopy |

`SurfaceModel` keeps `GRASS_ID` (== `BlockCatalog.GRASS`) and delegates mass/break
to the catalog; `BlockMaterials.get_for(id)` supplies the cached render material
per id (textured for grass/wood, solid-colour swatch for dirt/stone/leaf).

**Layered terrain (`TerrainConfig.generated_block(x,y,z)`).** A column is grass at
the surface `g = height_at(x,z)`, then a dirt band, then stone from
`stone_top = min(stone_height_at(x,z), g-3)` downward (never hollow). `stone_height_at`
uses a **second, decorrelated noise field**, so the stone relief has its own hills
that don't coincide with the grass surface and always sit ≥3 blocks deeper.

**Trees (`world/tree_gen.gd`).** A deterministic, hash-of-position overlay (no
per-run randomness, so both render paths and reloads agree): patches of wood-trunk
+ leaf-canopy trees scattered over the terrain, produced by the same
`generated_block` both paths derive from. Chopping a trunk detaches the canopy as a
mixed wood+leaf `VoxelBody` via the collapse pass. Trees replaced the old wooden
test pillars.

**Editing.** `WorldManager` holds one sparse edit overlay (`_edits: Vector3i→id`;
0 = dug to air, >0 = player-placed). `block_id_at(cell)` = overlay-else-generated is
THE cell query for floor/raycast/collider/collapse. Breaking returns the broken id
(→ hotbar); right-click `place_block` writes the overlay, mirrors into the active
render path, and rebuilds the local ground collider.

Both rendering paths agree because both derive from `generated_block` + the overlay:
* **godot_voxel path** — the generator writes stone/dirt/grass runs + tree cells;
  the blocky library has cube models 0..5 in catalog-id order (asserted at build).
* **GDScript fallback** — `ChunkMesher` emits one surface per present id, banding
  hillsides by material and cube-rendering trees & placed blocks (safety-net grade).

Adding a material is still a data change: extend `BlockCatalog`, add one library id
+ a `BlockMaterials` entry, and (for generation) a rule in `generated_block` — no
HUD or player changes. Temperature-driven states (snow/ice/water) drop in the same way (see §4).

## 7. Why this extends cleanly

The full engine (DESIGN §8) wants multi-material voxels, richer state machines
(ice ↔ water ↔ steam driven by temperature/light/current), and more fields. That
is purely: author more `VoxelMaterialDef`/`VoxelState`/`VoxelStateTransition`
resources, register them, and flesh out the stub fields in `PerVoxelEnvironment`.
Because rendering and gameplay both read through these interfaces — never the
geometry — none of that touches the mesher, the player, or the HUD.
