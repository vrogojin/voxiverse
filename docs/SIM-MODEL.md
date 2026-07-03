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

Air temperature varies with **altitude** via an atmospheric lapse rate (warm at
sea level, cold on the peaks — this is what drives the snow caps in §7). Ground
uses a surface/depth model whose surface tracks the LOCAL air temperature at that
column's height, then relaxes exponentially toward a stable subsurface value with
depth.

```
air(y)         = T_SEA_LEVEL - LAPSE_RATE * y        (y in blocks/metres)

cell is air (cell_y > surface_y):
    T = air(cell_y)

cell is ground (depth = surface_y - cell_y >= 0):
    T_surface = air(surface_y) + SURFACE_OFFSET
    T = T_DEEP + (T_surface - T_DEEP) * exp(-depth / DECAY_DEPTH)
```

with the constants (in `per_voxel_environment.gd`):

| Constant | Value | Meaning |
|---|---|---|
| `T_SEA_LEVEL` | 21.5 °C | air temperature at `y = 0` (DESIGN §1) |
| `LAPSE_RATE` | 2.2 °C/block | air-temperature drop per block of altitude |
| `SURFACE_OFFSET` | +1.5 °C | sun-warmed surface sits this much above local air |
| `T_DEEP` | 12.0 °C | stable subsurface temperature the deep ground trends to |
| `DECAY_DEPTH` | 4.0 m | e-folding depth of the exponential relaxation |

`LAPSE_RATE` is **exaggerated for gameplay**: this world's terrain tops out near
~19 blocks, so a realistic lapse (~0.0065 °C/m) would never freeze. At 2.2 °C
per block the snow line (surface ≤ 0 °C) sits around y ≈ 11 — the top ~15-20% of
hills — and peaks are clearly sub-zero, so the thermometer visibly changes as the
player climbs or descends. The HUD's **Air temp** and **Ground temp** read this
model directly (no special-casing).

Verified headlessly with Godot 4.4: air(0)=21.5, air(10)=-0.5, air(19)=-20.3;
ground surface at y=8 = 5.4 °C; snow covers ~24% of the terrain.

## 5. Light model

Air and the exposed surface block are fully lit; light attenuates exponentially
below the surface:

```
depth <= 0:  light = 1.0
depth  > 0:  light = exp(-depth / LIGHT_DEPTH)      LIGHT_DEPTH = 1.5 m
```

Normalised to `[0, 1]`. (Verified: air = 1.0, 5 m deep = 0.036.)

## 6. Snow caps — the environment→state→look triad

Snow caps are the first end-to-end use of the core triad: a per-voxel
environment field drives a material state transition that yields a distinct look.

`SurfaceModel` (`sim/surface_model.gd`) owns one ground **surface** material with
two states — `grass` (default) and `snow` — carrying full physics/look and a
`block_id` (air=0, grass=1, snow=2). Temperature transitions connect them:

```
grass --(temperature <= 0 °C)--> snow
snow  --(temperature >  0 °C)--> grass
```

`SurfaceModel.block_id_at(x, z)` samples the environment at the column's surface
voxel and runs `VoxelMaterialDef.resolve_state(...)` — the SAME state machine
from §2 — to decide the surface block. There is no ad-hoc `if` in any mesher.

Both rendering paths call this one function, so they always agree:
* **godot_voxel path** — the generator writes `block_id_at` for the top voxel and
  grass below; the blocky library has cube models at ids 1 (grass) and 2 (snow),
  each with its own material (atlas `(1,1)` + per-face tile `(0,0)` + `bake()` so
  UVs span 0..1 — see the degenerate-UV note in the code).
* **GDScript fallback** — `ChunkMesher` greedy-merges top faces by (height,
  surface id) and routes the top block's faces to the grass/snow surface, deeper
  walls to grass.

Verified headlessly on the module binary: warm column (h=8) → surface id 1
(grass), cold peak (h=17) → surface id 2 (snow) with grass beneath; library holds
3 models; fallback chunk emits both grass and snow surfaces.

Extending to more surface materials (mud, sand, ice) is just more states +
transitions here and one more library id — no mesher or HUD changes.

## 7. Why this extends cleanly

The full engine (DESIGN §8) wants multi-material voxels, richer state machines
(ice ↔ water ↔ steam driven by temperature/light/current), and more fields. That
is purely: author more `VoxelMaterialDef`/`VoxelState`/`VoxelStateTransition`
resources, register them, and flesh out the stub fields in `PerVoxelEnvironment`.
Because rendering and gameplay both read through these interfaces — never the
geometry — none of that touches the mesher, the player, or the HUD.
