## What this is

A byte-off-gated overhaul of the **far-tier render path and the surface→space transition** for the faceted voxel planet, served live at https://voxiverse.game-host.org. It started as "far villages make the game jerky" and grew, through iterative live A/B on the real WebGL2 build, into the whole far-tier + surface-entry story: far-village render diet, an impostor-card tier, a debounced far-edit re-bake, an LOD-dropout handoff, a chopped-body render fix, and — the deep one — the surface-entry spike taken from a **1.1-second freeze to a one-time ~32–60 ms hitch**.

**Every feature is behind a `FP_*` flag defaulting `false`.** The FLAT gate (`verify_feature.gd`) holds **6042 passed / 0 failed** with all flags off, so `main`'s shipped build is byte-identical; the live build turns the validated flags on via the export pipeline. Design decisions are documented in `docs/COSMOS-*.md`.

## User-facing problems solved

| Problem (as reported) | Fix | Result (live-measured) |
|---|---|---|
| Far villages make the game jerky (2 Hz spike at first far house) | `FP_STRUCT_REG_EPOCH` version-gate + `FP_STRUCT_CARDS` impostor tier + render diet (`GATE_MEMO`/`COARSE_FAR`/`NEAR_RADIUS_DIET`/`SHADER_LITE`) | jerk gone; far-structure step prelude ~20–50 ms → 0 stationary |
| **Break/place freezes the game for seconds near a village** | root-caused to `FP_STRUCT_EDIT_DEBOUNCE` v1's cache-cold facet enumeration; **v2** makes the edit frame provably **O(1)** (enqueue-only) + a budgeted O(1) deferred classifier | 3547 ms → **42–92 ms**, no freeze |
| Far-village edits not reflected at distance | `FP_STRUCT_EDIT_DEBOUNCE` v2 publishes after depart (~16 blk) + idle (~3 s), NEVER-DROP preserved | far model updates after you leave |
| Trees/buildings vanish for moments–seconds crossing an LOD step | `FP_SKIN_READY_GATE` + `FP_SKIN_HANDOFF_PREWARM` — hold the card/mesh tier until the fine-map skin is baked; gap-A last-good-resident freeze | structures: **0 drawable gap** both directions; trees: ~1.2 s worst-case (was ~30 s) |
| Chopped tree part renders totally black | `FP_SHADE_UNIFIED` branch never fed `planet_centre` to the `BlockMaterials` debris twins → night-floor shading | detached canopy renders lit |
| Spawn at midnight (dark) | `SPAWN_LOCAL_HOURS = 7.0` | spawns at early morning |
| **~1.1 s freeze entering space (surface→off-surface at alt 256)** | `FP_FT_SHELL_FLIP_CALM` (far-tree flip rebuild) + `FP_OR_COMMIT_PARTIAL` (orbit-relief mesh commit) | **1111 ms → ~32–60 ms one-time**, then free |

## The surface-entry spike — the headline

Decomposed the 1111 ms flip via added **worst-frame sub-timing** (measure-first, after two guessed fixes missed):

- **Primary** — `FacetFarTrees` zone S→B forced unbudgeted rebuild on the flip frame → `FP_FT_SHELL_FLIP_CALM` defers/paces it (holds the mesh visible, no gap): ~600 ms → ~1 ms.
- **Secondary** — the *entire* residual was `FacetOrbitRelief._commit()` rebuilding the whole 384-tile arena (~27 MB) into a fresh `ArrayMesh` every commit. `FP_OR_COMMIT_PARTIAL` replaces it with a **persistent surface + `RenderingServer` region uploads** (partial `glBufferSubData` per changed slot), plus **coalesced** consecutive-slot runs (one call per run) and a static index buffer: **111 ms/commit → ~32 ms one-time cold-fill → 0 steady**. Live-confirmed `or_partial_ok = 1` (the boot color-quant self-check passed on the real WebGL2 backend — not silently degraded to full-rebuild).
- Two mis-targeted attempts (`FP_OR_FLIP_STAGE`, `FP_OR_WORKER_DECODE`) are kept in history and byte-off — the sub-timing proved they weren't the dominant term (they're **not** in the served config).

## How it was validated

- **Byte-off discipline:** every flag defaults false; FLAT `verify_feature.gd` = **6042/0** off. Feature gates run flag-on: `verify_structures`, `verify_orbit_relief` (**149/0**, incl. G-OR-PART-PACK/EQ/DEGEN/COALESCE with falsifiability-proven asserts), `verify_far_trees`, `verify_facet_tex`.
- **Multi-model adversarial review:** Fable for architecture/design, Codex for adversarial byte-level review (e.g. the GPU-buffer commit was verified offset/stride/quant against pinned Godot 4.4.1 source — no corruption P0; two P1s fixed with a falsifiability-proven eviction gate).
- **Live A/B on the real build:** measured on https://voxiverse.game-host.org via the `?remote=` telemetry bridge — freeze A/B, the LOD-dropout ascent/descent, the surface-entry crossing decomposition, and the chop-dark + relief visual checks.

## Notes for the reviewer

- Large branch (39 commits) because it's an iterative live-tuned investigation — the commit history is the story (root-cause → design → impl → adversarial review → live A/B), including two honestly-labeled mis-targeted attempts that the sub-timing corrected.
- Nothing on the byte-off path allocates or changes behaviour when flags are false; the risky new code (raw GPU buffer region updates) self-checks at boot and **degrades to the verbatim full-rebuild** on any mismatch rather than corrupting.
- Served-config flag set (turned on at export, not in source): the `FP_STRUCT_*` card/diet stack, `FP_STRUCT_EDIT_DEBOUNCE`, `FP_SKIN_READY_GATE`/`HANDOFF_PREWARM`, `FP_FT_SHELL_FLIP_CALM`, `FP_OR_COMMIT_PARTIAL`, plus the `FP_WF_TIER_ATTR`/`FP_WORST_FRAME_ATTR` telemetry.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
