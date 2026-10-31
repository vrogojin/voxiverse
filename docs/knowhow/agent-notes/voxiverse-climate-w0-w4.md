---
name: voxiverse-climate-w0-w4
description: "Climate/weather sim W0-W4 landed on feat/voxiverse-climate; flags, measured byte ledger, and the CPU-projection deviation"
metadata: 
  node_type: memory
  type: project
---

Bounded climate/weather sim (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md) implemented staged on
`feat/voxiverse-climate` (off deploy/perf-plus-sky), 5 commits c4bf771..27cbc08. Every flag default-FALSE
⇒ byte-identical (verify_climate 48/0; regression snowfall 48/0, orbital 38/0+32/0, flat 6020 pass — the
15 fails are missing-baked-texture asserts, a pre-existing env artifact, NOT a regression).

Flags (CubeSphere): FP_SEASONS (W0), FP_CLIMATE_GRID (W1), FP_CLOUDS (W2), FP_PRECIP (W3), FP_STORMS (W4).
Home = godot/src/sim/ (decoupled sim layer, engine rule 2). New files: sim/weather_system.gd,
world/cloud_layers.gd, world/weather_fx.gd, tools/verify_climate.gd.

**Measured byte ledger (G-W1-BYTES, real .size() bytes):** weather state = 393216 B = 384 KiB exact
(6144 cells × 8 f32 × 2 buffers); static basis = 270336 B = 264 KiB exact (44 B/cell); cloud scratch ONE
reused buffer ≤ ~0.66 MiB (better than the design's 2.36 MiB — I share one scratch across 3 layers, not 3).
All allocated once, zero growth paths, identity-stable across 200+ sweeps/rebuilds.

**KEY DEVIATION flagged for re-verify — CPU projection factor.** The sweep is compute-bound (pure FP, ZERO
allocation), so the design's ×25 web factor (calibrated for the ALLOCATION-bound generator's dlmalloc
convoy, per [[voxiverse-gen-class-costs]]) does NOT apply. Measured native = 5.5 µs/cell interpreted
GDScript. I project ~4× (realistic compute-bound WASM) and set CELLS_PER_FRAME=24 → 0.53 ms/frame web,
sweep 4.3 s. Under ×25 it would be 3.3 ms (infeasible — would force ~5 cells/frame). CELLS_PER_FRAME is the
knob; C++ sweep-kernel port (L5 pattern) is the full-speed escape hatch; the LIVE A/B is the real arbiter
before baking ON (design gates every flag on a live A/B anyway).

Insolation reuses EPH.dir_to_bodyfixed (subsolar-δ + diurnal automatic). Wind is DIAGNOSTIC (Hadley +
geostrophic + friction) — cannot blow up. Moisture advection is bounded UPWIND (convex blend). ITCZ tracks
δ via CONVERGENCE-forced condensation (the fix — pure supersaturation alone pooled cloud at cold poles).
Signed latitude for the season offset comes from _dir_of_col (chart | FACETED FacetAtlas.cell_dir | flat=0).

HEADLESS-PROVEN: seasons geometry, byte ledger, determinism, physics signals (equator>pole, ITCZ, clamps,
emergence). LIVE-ONLY: cloud/precip/storm LOOK, fog mood, seasonal sun arc, real web worst-frame A/B.
W5 (shell clouds) + Task-4 biomes (B1 FP_CLIMATE_BIOMES) NOT done — optional / independent flag family.
