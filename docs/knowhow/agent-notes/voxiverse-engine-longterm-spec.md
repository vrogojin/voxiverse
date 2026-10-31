---
name: voxiverse-engine-longterm-spec
description: "VOXIVERSE long-term engine vision — physical objects, voxel materials/states, per-voxel environment fields"
metadata: 
  node_type: memory
  type: project
---

Long-term VOXIVERSE engine design (partial/initial spec from the owner; the grass-block FPS is just the first test env — see [[voxiverse-project]]):

**Physical objects:**
- *Physical items*: pickable 3D-model items, may have multiple states and animation; obey physics; can be picked into inventory; have mass + durability. An item can be *converted into its voxel material and integrated into the voxel mesh* by filling a voxel, carrying its metadata. Items are usually unique.
- *Voxel meshes* (modular/granular modifiable objects): made of voxels. Each object defines voxel size + mesh geometry — standard = 3D grid; advanced = spheres, ragdolls (NPCs/characters), etc.

**Voxel materials:**
- A material has different *states* depending on environment: temperature, light, electric current. Material defines a state-transition mapping (heat melts ice→water, current lights a lamp, …).
- A voxel *state* defines: physics (mass/density, resistance/break force, attachment strength to neighbors, permeability for liquids/gases, reflection/albedo, translucence, light emission, solidity: solid/liquid/gas) and look (textures, reflection, translucence, glow).
- A voxel may be filled by **zero, one, or more materials** (ground + puddle + ice + snow + grass; sand that passes water; a switch/cable/lamp on a wall). Each material entity in a voxel may carry its own custom metadata (storages, electronics, machines, biological plant parts, …).

**Per-voxel environment fields:** temperature, light, pressure, electric current, magnetic field, gravitational field.

The initial test env models a tiny slice: one material (grass), one state, temperature field only (air 21.5 °C, ground from a simple surface/depth model).
