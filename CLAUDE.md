# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Workflow/process rules (git branching, model routing, Serena semantic search,
> adversarial `/steelman`) live in `.claude/CLAUDE.md` and still apply. This file
> covers the **VOXIVERSE project itself**: what it is, how to build/export/deploy,
> and how the engine is architected.

## What this is

VOXIVERSE is a Minecraft-like **voxel immersive simulation engine** in **Godot 4.4.1**,
exported to the browser (Web/HTML5) and served live at **https://voxiverse.game-host.org**.
The current milestone is a first-person voxel sandbox (procedural layered terrain,
trees, breakable/placeable blocks, a hotbar, a per-voxel-temperature HUD) that is
deliberately built on top of a **decoupled simulation layer** so the full engine
(multi-material voxels, state machines, per-voxel physical fields) extends without
touching rendering or gameplay.

`docs/DESIGN.md` is the single source of truth for scope and locked decisions.
`docs/SIM-MODEL.md`, `docs/ENGINE-BUILD.md`, `docs/DEPLOY.md` cover the sim layer,
the toolchain, and serving respectively — read the relevant one before changing
that area.

## The three-stage pipeline (build → export → deploy)

Each stage is one script; they are independent and each is safe to re-run.

```bash
scripts/build.sh        # Docker: compile custom Godot 4.4.1 editor + Web export templates (with godot_voxel)
scripts/export-web.sh   # Docker: headless Web export of godot/ -> build/web/
scripts/deploy.sh       # Docker: containerize build/web/, self-register with HAProxy, verify live
```

**`scripts/build.sh`** — the long pole (~24 min cold, minutes warm). Builds a
custom Godot engine + Emscripten Web templates that include the Zylann
`godot_voxel` C++ module. Heavy caches live under `docker/engine/cache/`
(git-ignored). Version pins are the single source of truth in
`docker/engine/versions.env` — **do not bump `emsdk` (3.1.64) independently**; it
must match Godot 4.4.1's CI emsdk or the web build fails at link/runtime. Flags:
`--rebuild`, `SKIP_WEB=1`, `SKIP_LINUX=1`, `FORCE_STOCK_WEB=1`. If the module web
compile fails, the script auto-falls back to stock templates (records
`module_in_web=no` in `BUILD-INFO.txt`) and the game then uses its GDScript mesher
on web. As built today, `module_in_web=yes`.

**`scripts/export-web.sh`** — runs the custom editor headless in the toolchain
container, installs templates into `export_templates/4.4.1.stable/`, exports the
preset named `Web` to `build/web/`. Exits cleanly (not an error) if the project or
`Web` preset is absent.

**`scripts/deploy.sh`** — builds a content-agnostic nginx image, bind-mounts
`build/web/` (`:ro`), joins the external `haproxy-net` network, terminates its own
TLS via ssl-manager (Let's Encrypt), self-registers with HAProxy's Registration
API, and **verifies** the live site returns HTTP 200 with the COOP/COEP headers.
A content redeploy is just re-running it (the bind mount picks up the new export).
Flags: `--test-mode` (self-signed, offline), `--staging` (LE staging CA),
`--no-build`. Never publish host 80/443 — those belong to HAProxy.

### Why COOP/COEP is mandatory
The web export is **threaded** (`godot_voxel` is multithreaded), which needs
`SharedArrayBuffer`, which needs cross-origin isolation. The runtime container
sends `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy:
require-corp` on **every** response. Without both, `crossOriginIsolated` is false
and the engine refuses to start (blank page). This is the #1 web-serving gotcha.

## Running / testing the game logic

There is no unit-test framework; verification is a headless Godot SceneTree script
that asserts the gameplay invariants (terrain stackup, stone relief, trees, mass
ordering, inventory, and a live break/place/collapse loop):

```bash
# Requires the custom editor from scripts/build.sh at docker/engine/bin/godot.linuxbsd.editor.x86_64
docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
    --script res://src/tools/verify_feature.gd     # exits 0 all-pass, 1 on any failure
```

`godot/src/tools/verify_feature.gd` is the pattern to extend when you add a
feature — assert its invariants there rather than reasoning by eye.

## Engine architecture (`godot/src/`)

The scene is assembled **in code** — `main.gd` (`res://scenes/main.tscn` is a
one-node stub). No autoloads: every subsystem is a global `class_name` class.
`main.gd` builds the environment/fog/ambient lighting, then wires the core graph:

```
WorldManager  ── owns "the world": render path + edit overlay + sim layer
  ├─ GroundCollider     local blocky physics collider around the player
  ├─ module_world (godot_voxel)  OR  ChunkStreamer+ChunkMesher (GDScript fallback)
  └─ (queries) PerVoxelEnvironment, MaterialRegistry, BlockCatalog, SurfaceModel, TreeGen
Player (CharacterBody3D) ── FPS controller, injected `world`; break/place via WorldManager
Inventory ── one model shared by Player and HotbarHUD
HotbarHUD, ThermometerHUD ── read-only views of Inventory / the sim layer
```

### Three architectural rules that make the engine extend cleanly

1. **`WorldManager.block_id_at(cell)` is THE cell query.** It is
   `edit-overlay-else-generated`: a sparse `_edits` dict (`Vector3i → id`; 0 = dug
   to air, >0 = player-placed) layered over `TerrainConfig.generated_block()` +
   `TreeGen`. Floor collision, the DDA raycast, the ground collider, and the
   collapse pass **all** route through it, so the overlay, procedural terrain, and
   trees can never disagree. Don't add a parallel notion of "what's solid here."

2. **Rendering and gameplay never read geometry — they read the sim layer.**
   `godot/src/sim/` (see `docs/SIM-MODEL.md`) is decoupled from the mesher and
   derives everything from the shared heightmap in `world/terrain_config.gd`, so
   it is identical for both render paths. `BlockCatalog` is the authoritative
   block-id table (ids, masses, colours, names in one place); `PerVoxelEnvironment`
   is the only place temperatures/light/etc. are computed (the HUD and any material
   state machine read through it — no special-casing). Adding a material is a data
   change: extend `BlockCatalog`, add a `BlockMaterials` entry and a rule in
   `generated_block`; adding a field/transition is authoring
   `VoxelMaterialDef`/`VoxelState`/`VoxelStateTransition` + fleshing a stub field.

3. **Two render paths, one behaviour.** If the running engine has `godot_voxel`
   compiled in (`ClassDB.class_exists("VoxelTerrain")`), `WorldManager` uses
   `world/voxel_module/module_world.gd`; otherwise it uses the pure-GDScript
   `world/fallback/` chunk streamer+mesher. Both derive from `generated_block` +
   the edit overlay, so gameplay downstream is path-agnostic. `module_world.gd`
   only touches `godot_voxel` via strings/`ClassDB`, so it loads safely even when
   the module is absent (returns false from `setup()`).

### Physics is analytic, not a trimesh
The terrain has no mesh collider. The player samples surface height / per-axis
`blocked()` / `floor_under()` from `WorldManager` (cheap, web-friendly, identical
across render paths). Only two things use the real physics server: a small
`GroundCollider` of blocky shapes kept centred on the player, and detached
`VoxelBody` rigid bodies. Breaking a block runs `_collapse_unsupported()` — a
local flood-fill from the region boundary; any solid cluster not connected to
supported terrain is carved out and dropped as a loose `VoxelBody` (this is how
chopping a tree trunk detaches its canopy). Block **mass** (from `BlockCatalog`)
genuinely matters: the player's fixed push force means light wood shoves easily
and heavy stone barely moves.

## Non-negotiables (from DESIGN §7)
- The **live web demo must load and be playable in a desktop browser** — that gate
  outranks feature depth. Threaded export + COOP/COEP is what makes or breaks it.
- All work on `feat/voxiverse-bootstrap` or sub-branches merged into it; Conventional
  Commits, scope `voxiverse`; never commit to `main`.
- Document every real decision in `docs/`.
- Build artifacts (`docker/engine/bin/`, `docker/engine/templates/`, `build/web/`,
  `docker/engine/cache/`) are git-ignored — never commit them.
