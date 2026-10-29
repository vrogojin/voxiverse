---
name: voxiverse-near-leaf-cutout
description: "SHIPPED+MERGED PR #55 (main 8ca78bf) FP_LEAF_CUTOUT V2 = shared-shader gated discard (0 extra draws); twin FAILED live A/B (57→28fps, draws 58→190) → V2 keeps draws at baseline; early-Z verdict — discard kills early WRITE only, early TEST survives; LESSON weigh DRAW-COUNT before fill/early-Z theory"
metadata: 
  node_type: memory
  type: project
---

2026-08-12, task #116. FP_LEAF_CUTOUT (db916fd, NOT merged) — see-through stippled near
leaf blocks matching far cards. Look approved by user; live forest A/B FAILED: fps 57→28,
draws 58→190. ROOT: approach (b)'s separate cutout twin material un-merges every leafy
32³ block into 2 surfaces (VoxelMesherBlocky = 1 surface/material/block) → +132 web draws
+ gl_compat vsync-ladder snap to 30-lock. The discard/fill term was minor.

**V2 (docs/COSMOS-LEAF-CUTOUT-PERF-DESIGN.md): leaves STAY on the ONE shared atlas
material; splice `if (t.a < LEAF_SCISSOR) discard;` into the shared near-daylight shader
(alpha already fetched; non-leaf cells min-alpha 255 so they can never discard). 0 extra
draws/programs/bytes; revert module_world routing; keep punch + key-namespace +
is_leaf_id. Expected ~53-57fps.**

**Why:** the original design rejected shared-shader scissor over early-Z — but early-Z
loss from `discard` is static per-PROGRAM (branch guard never helps) and only disables
early depth WRITE; early depth TEST (the cross-draw occlusion win that makes voxel scenes
cheap) survives on all modern GPUs (AMD re-Z, Mali late-ZS-update-early-test, Adreno
LRZ-write-off). On a 1-fetch unshaded shader the write loss caps ≤~1.5ms — vs the
measured ~17ms of +132 draws. In-project proof discard is fine: far cards + far-tree
dither fades (facet_far_trees.gd:141,166,167,260) run planet-wide at 40fps.

**How to apply:** on this web stack always weigh DRAW-COUNT deltas before fill/early-Z
theory ([[voxiverse-web-perf-architecture]]); never split a material family off the atlas
without counting surfaces × chunks. Ship gate: draws == baseline (58) + forest fps ≥ 50;
if V2 fails there is NO cheaper variant — ship flag-off (playability non-negotiable).
Related: [[voxiverse-atlas-staging]] [[voxiverse-walk-perf-root-cause]].

**V2 SHIPPED+MERGED PR #55 (main 8ca78bf, 2026-08-12, byte-off const false), bundled with
[[voxiverse-far-trees-colorfix]].** Impl (ced9090): cutout param on near_daylight_shader_code
splices EXACTLY one `if (t.a < 0.500) discard;` after the atlas fetch in the live variant
(unified/centre_fix/base); ALPHA_SCISSOR on the StandardMaterial path for headless/FLAT
parity; module_world byte-reverted to shipped 4-arg single-material path; twin material
(_make_leaf_material) DELETED. Gates verify_leaf_cutout 37/0 on / 9/0 off, verify_atlas 17/0
both, FLAT 6042/0. LIVE A/B facet 1754: see-through leaves render great; draws 171 (= forest
baseline, NOT the twin's 190 — split removed); frame is CPU-bound (proc_ms 33-87ms, snow_ms
thrash) so the discard is NOT the fps limiter — the real forest-fps hog is the snow sim
([[voxiverse-near-leaf-cutout]]→see FP_SNOW_PRECIP_GATE task #118).
