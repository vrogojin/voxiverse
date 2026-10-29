---
name: voxiverse-atlas-staging
description: COSMOS-ATLAS draw-call cut (FP_ATLAS_MATERIAL) — Stage 1 cubes + Stage 2 shaped families shipped; slopes/carve/water deliberately per-material
metadata: 
  node_type: memory
  type: project
---

COSMOS-ATLAS (docs/COSMOS-ATLAS-DESIGN.md) collapses per-id `StandardMaterial3D`s onto ONE shared atlas material so VoxelMesherBlocky merges a mesh block's opaque surfaces into one draw. Flag `CubeSphere.FP_ATLAS_MATERIAL` (default OFF, sed-on at export A/B). Built once at `module_world.setup()` in `block_atlas.gd` (`BlockAtlas`).

- **Stage 1** (commit 191b4a5): 67 opaque CUBE ids → one atlas material. Measured live 200→97 draws, fps ~20→43.
- **Stage 2** (commit 1a5720a, 2026-07-16): the DOMINANT opaque SHAPED families — dry corner-height shapes, snow-cap cubes+shapes, snow LAYER, snow-FILL composites — routed onto the SAME material by baking atlas-remapped UVs into per-(cell,modifier) ArrayMeshes (`module_world._atlas_shape_mesh`/`_atlas_remap_geom`). Atlas grid grew 8×8×128px → **16×16×64px (still 1024²=4MB)**; +5 snow-cap tinted cells (§2.6, snow tile × lerp(WHITE,base,0.18)). Shaped meshes ≈ **4.4 MB** (net +~3.7MB, flag-ON only).

**Deliberately LEFT per-material (residual surfaces), NOT bugs:**
- **Sharp SLOPE family** — atlassing = ~5160 per-(cell,payload) meshes ≈ 5.9 MB, over the NEVER-OOM ≤-few-MB budget for a minority steep-terrain surface. Residual slope surface only where sharp slopes appear.
- **Carve SENTINELS** (seam bevels) — the C++ `set_facet_carve` cut-face UVs are unverifiable headless; faceted-only, small count.
- **Water/fluid twins, translucent (glass/ice/stained), emissive (lava)** — Stage 3 (translucent atlas).

Gates: `verify_feature` FLAT **6035/0** flag-off (byte-identical); `verify_atlas` (flag on) **17/0** incl. shaped G-ATLAS-COVER/UV/MAT (replays module `atlas_shaped_probes()`, armed by `capture_atlas_probes`); `verify_fp_m2` faceted G-M2-ID green, atlas adds 0 fails (138/2 both, the 2 are pre-existing atlas-independent G-M2-XPD). See [[voxiverse-faceted-planet]] [[voxiverse-never-oom-web]].
