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

`grass` ships as a single static state `default` (unbreakable: `break_force =
INF`) with **no** transitions, so it never changes — but the mechanism runs for
it every frame like any other material. `material_registry.gd` includes a
commented, ready-to-uncomment example of a temperature-driven `grass -> frosted`
transition to show exactly how ice/water/steam-style materials will be authored.

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

Air is the ambient environment temperature. Ground uses a simple surface/depth
model: the exposed top grass block is warmed slightly above air (sun on the
surface), and temperature relaxes exponentially toward a stable subsurface value
as depth increases.

Let `surface_y = height_at(x, z)` (the y of the topmost grass block) and, for a
solid cell, `depth = surface_y - cell_y` (0 at the top block, increasing
downward). Then:

```
depth < 0  (cell is air, at/above surface):
    T = T_AIR = 21.5 °C

depth >= 0 (cell is grass/ground):
    T = T_DEEP + (T_SURFACE - T_DEEP) * exp(-depth / DECAY_DEPTH)
```

with the constants (in `per_voxel_environment.gd`):

| Constant | Value | Meaning |
|---|---|---|
| `T_AIR` | 21.5 °C | ambient air temperature (DESIGN §1) |
| `SURFACE_OFFSET` | +1.5 °C | how much the sun-warmed top grass sits above air |
| `T_SURFACE` | 23.0 °C | `T_AIR + SURFACE_OFFSET`, the temperature at `depth = 0` |
| `T_DEEP` | 12.0 °C | stable subsurface temperature the deep ground trends to |
| `DECAY_DEPTH` | 4.0 m | e-folding depth of the exponential relaxation |

Properties: continuous and monotonic in depth; `T_ground(0) = 23.0 °C`,
`T_ground(∞) → 12.0 °C`. The thermometer's **Air temp** reads the air voxel at
the player's head (always 21.5 °C) and **Ground temp** reads the grass voxel
directly under the player's feet (≈ 23.0 °C at the surface) — both through this
model, with no special-casing in the HUD.

Verified headlessly with Godot 4.4: air = 21.5, surface = 23.0, and a cell 20 m
down = 12.07 °C.

## 5. Light model

Air and the exposed surface block are fully lit; light attenuates exponentially
below the surface:

```
depth <= 0:  light = 1.0
depth  > 0:  light = exp(-depth / LIGHT_DEPTH)      LIGHT_DEPTH = 1.5 m
```

Normalised to `[0, 1]`. (Verified: air = 1.0, 5 m deep = 0.036.)

## 6. Why this extends cleanly

The full engine (DESIGN §8) wants multi-material voxels, richer state machines
(ice ↔ water ↔ steam driven by temperature/light/current), and more fields. That
is purely: author more `VoxelMaterialDef`/`VoxelState`/`VoxelStateTransition`
resources, register them, and flesh out the stub fields in `PerVoxelEnvironment`.
Because rendering and gameplay both read through these interfaces — never the
geometry — none of that touches the mesher, the player, or the HUD.
