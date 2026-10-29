---
name: voxiverse-generic-body-params
description: "ARCHITECTURAL RULE — all planetary params (gravity, radius, terragen, atmosphere, etc.) must be generic/configurable per-body, not Earth-hardcoded, so any planet/planetoid/satellite can be generated from config"
metadata: 
  node_type: memory
  type: feedback
---

User directive (2026-07-31): ALL planetary parameters — gravity, radius, terrain-gen algorithms, atmosphere thickness/"sickness", climate, day length, axial tilt, etc. — must be **generic and configurable per body**. The engine must be able to generate ALL sorts of bodies (planets, planetoids, moons/satellites) from generic procedures + pipelines driven by a per-body CONFIG, not from Earth-specific hardcoded constants.

**Why:** future scope = many diverse bodies. Every new fix/feature must derive from the body's config, not bake in Earth's numbers.

**How to apply (going forward):**
- Prefer per-body accessors over global consts. The engine ALREADY has a multi-body foundation: `CosmosGravity.r_vox(body)` / `gm_dyn(body)` (per-body radius+gravity), per-body worldgen (`resolve_cell` branch per body — Earth vs Moon profile/craters/materials, see [[voxiverse-o4c-soi-walk]]), `OrbitalState.has_atmo(body)`, `CosmosEphemeris` per-body radius/orbit, `FacetAtlas` BODY_TABLE namespace ([[voxiverse-o4c-soi-walk]]).
- Things still GLOBAL/Earth-hardcoded that SHOULD become per-body config eventually: `ATMO_TOP=384` (atmosphere ceiling — used by the sky blacken, air='--' boundary, FP_ATMO_RIM geometry, Cruise engage), the atmosphere rim consts (`H_RIM`, `SHELL_RIM_MULT`, `RAYLEIGH_BLUE` colour), `R_BLOCKS`, climate/biome params, day length. When touching these, route through the body (e.g. `atmo_ceiling(body)`, `has_atmo(body)`) rather than the global const where feasible.
- Cruise Mode already uses the nearest/dominant body's `radial_altitude()` (per-body) — good pattern to follow.
- The design goal is a CONFIG-DRIVEN body pipeline: one generator + one renderer parameterized by `{radius, gravity, gm, atmo_ceiling, has_atmo, rayleigh_colour, terragen_seed/profile, craters, materials, climate, tilt, day_len, ...}`.

Not a "build a config system now" task — a STANDING RULE: don't add Earth-only hardcoding; prefer per-body derivation; and when a dedicated "planet config" refactor is scheduled, consolidate the scattered per-body accessors + the still-global consts into one body-config struct. Related: [[voxiverse-two-gravity-systems]] [[voxiverse-orbit-real-space]] [[voxiverse-engine-longterm-spec]].
