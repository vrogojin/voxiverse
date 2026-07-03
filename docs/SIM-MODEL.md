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

## 6. The surface material (single state today)

`SurfaceModel` (`sim/surface_model.gd`) owns one ground **surface** material.
Today it ships a single state — `grass` (block id: air=0, grass=1) — so the world
is uniformly grass, but the decision still runs through the material framework:
`SurfaceModel.block_id_at(x, z)` returns the material's default-state `block_id`
via the §2 machinery, so there is no ad-hoc `if` in any mesher.

Both rendering paths call this one function, so they always agree:
* **godot_voxel path** — the generator fills grass at and below the heightmap,
  air above; the blocky library has cube models at id 0 (air) and 1 (grass), the
  grass cube carrying its own material (atlas `(1,1)` + per-face tile `(0,0)` +
  `bake()` so UVs span 0..1 — see the degenerate-UV note in the code).
* **GDScript fallback** — `ChunkMesher` greedy-merges top faces by height and
  emits one grass wall per downward step.

To add surface variety (mud, sand, ice, snow) you add more `VoxelState`s +
transitions in `SurfaceModel`, one more library id, and route the mesher's
surface faces by the resolved `block_id` — no HUD or player changes. The engine
supported temperature-driven snow this way in an earlier iteration (see §4).

## 7. Why this extends cleanly

The full engine (DESIGN §8) wants multi-material voxels, richer state machines
(ice ↔ water ↔ steam driven by temperature/light/current), and more fields. That
is purely: author more `VoxelMaterialDef`/`VoxelState`/`VoxelStateTransition`
resources, register them, and flesh out the stub fields in `PerVoxelEnvironment`.
Because rendering and gameplay both read through these interfaces — never the
geometry — none of that touches the mesher, the player, or the HUD.
