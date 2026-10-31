---
name: voxiverse-slope-material-design
description: 2026-08-12
metadata: 
  node_type: memory
  type: project
---

Task #122 (design done 2026-08-12, doc `docs/COSMOS-SLOPE-MATERIAL-DESIGN.md`): the "smooth slope
only for stone" bug is a **biome** gate, not a material gate. `_slope_fires_only`
(terrain_config.gd:1749-1750) fires the 1–2 blk/cell (~45°) band ONLY in B_MOUNTAINS (SHARP-SLOPE
DEFECT 2 "don't touch hills"); >2 blk/cell fires in any biome. The slope model bake
(`all_slope_materials()` :2896 × `all_slope_payloads()`) already covers GRASS/DIRT/STONE/SAND/
RED_SAND/MUD/SNOW/PODZOL — zero new models needed.

**Why:** B_MOUNTAINS tops are stone → users read the biome gate as a material gate. The C++ twin
(patch 0007 `slope_fires_only` ~:888) has the identical gate.

**How to apply:** Fix = FP_SLOPE_ALL_MATERIALS widening the gate to all Earth biomes EXCEPT
B_BADLANDS (sub-g run cells hit terracotta bands, deliberately unbaked → would mass-produce the
[[voxiverse-sharp-slope-manifest-stale]] render-above-physics sink). MUST edit GDScript AND patch
0007 together + plumb via `gen.set`/`_make_cpp_generator` cfg like `m5c_corner` — GDScript-only
deploy breaks render↔physics parity (#111 class). Engine rebuild required. Physics follows for
free: ONE predicate feeds floor_under/GroundCollider/memo/fallback mesher. Player edits stay
cubic by construction (edit overlay writes cube ARIDs, predicate never reads edits). Moon exits
resolve_cell before the slope branch. Related: [[voxiverse-seam-slope-weld]].
