# VOXIVERSE — Design & Build Specification

VOXIVERSE is a Minecraft-like, highly-detailed **voxel immersive simulation engine** built in **Godot 4.4**, shipped as a browser (Web/HTML5) game and served live at **https://voxiverse.game-host.org**.

This document is the single source of truth for all build agents. Read it fully before writing code.

---

## 1. First deliverable — the "grass test env"

A first-person voxel sandbox:

- **World:** static, unbreakable, **infinitely** procedurally-generated grid of **grass blocks** only. Simple hilly terrain via `FastNoiseLite`. 1 voxel = 1 m.
- **Rendering:** render radius **256 blocks** around the player, then **fog** out to hide the boundary. Scene lit by **ambient / omnidirectional** light only (flat, no sun, no shadows).
- **Grass texture:** procedurally generated **64×64** RGBA texture (green noise + subtle blades/tint), baked to PNG at build time, applied to the grass material.
- **Player / "FPS":** first-person controller — walk/run/jump, mouse-look (pointer-lock in browser), plus a fly/noclip toggle. A **look-at interaction ray** probes the voxel the player is aiming at (feeds thermometer + future material inspection).
- **Thermometer:** always-on **HUD** readout showing two live values:
  - **Air temp** = temperature of the air voxel at the player's head. **21.5 °C is the temperate SEA-LEVEL baseline**, not a global constant (M1 snowy-world, `docs/M1-SNOWY-WORLD.md` §3): it is the climate offset for a temperate column (climate noise `t ≥ −0.15`) at `y = 0`, from which an **absolute-altitude lapse** subtracts ~0.224 °C/block (0 °C at **y = 96**, negative above with no clamp — `ClimateModel`). Winter biomes carry a **climate offset**: a snowy column (`t < −0.55`) reads **−8 °C** at sea level, with the taiga fringe ramping linearly between −8 and 21.5. So a low temperate column reads ~21.5, a frozen sea-level column ~−8, and a frozen peak colder still by altitude — the snow line climbs with elevation within a cold biome.
  - **Ground temp** = temperature of the voxel directly under the player, derived from the **per-voxel environment model** (§3): it cools from the column's own surface anchor toward a 3 °C plateau at 1 °C/block (signed — permafrost warms downward), plus the geothermal rise near bedrock.
- **Units:** Celsius.

## 2. Engine tech decision (LOCKED)

- **Godot 4.4** + **Zylann `godot_voxel`** C++ module (https://github.com/Zylann/godot_voxel).
- The web demo requires a **custom Godot Web (Emscripten) engine build + export templates** that include the module. This is the long pole — build it in Docker (§5).
- **Fallback (agent's discretion):** if the custom web build cannot be made to work in time, ship the web demo using a **pure-GDScript chunked greedy-mesher** while keeping `godot_voxel` for native. The demo MUST always be shippable to the live domain. Log clearly which path was used.

## 3. Simulation foundations (start these — scope is "demo + begin next systems")

Model a small, *correctly-abstracted* slice now so it extends to the full engine (see the long-term spec in memory / §7):

- **Voxel material** — data-driven resource (`VoxelMaterialDef`): id, states, per-state physics (mass/density, break force, attachment, permeability, albedo, translucence, emission, solidity) + look (texture, tint, glow). Ship one material now: `grass`.
- **Voxel state & transitions** — a material defines state transitions keyed on environment (temperature/light/current). Grass has one static state now, but the *mechanism* must exist.
- **Per-voxel environment fields** — an interface exposing, per voxel position: `temperature, light, pressure, electric_current, magnetic_field, gravity`. Implement `temperature` and `light` for real; stub the rest returning sane defaults.
  - `temperature(pos)`: air voxels → a **per-climate, absolute-altitude** value (21.5 °C is the temperate **sea-level** baseline; 0 °C at y = 96; winter biomes offset down to −8 °C at sea level — `ClimateModel`, M1). Ground voxels → a **surface/depth model**: cool from the column's surface anchor toward a stable subsurface plateau, plus geothermal rise near bedrock; document the formula. The thermometer reads through this interface — no special-casing in the HUD.
- Keep this layer **decoupled** from rendering so future materials/fields drop in without touching the mesher.

## 4. Repository layout

```
/godot            Godot 4.4 project (project.godot, scenes, scripts, src/)
  /src/world      chunk streaming, terrain gen, voxel mesh integration
  /src/sim        VoxelMaterialDef, states, per-voxel environment model
  /src/player     first-person controller + interaction ray
  /src/ui         thermometer HUD
  /assets         generated grass texture, materials
/docker/engine    Dockerfile + scripts to build custom Godot web engine + templates (godot_voxel)
/docker/server    runtime container: serves web export w/ COOP/COEP + ssl-manager autossl
/deploy           compose + haproxy registration for voxiverse.game-host.org
/scripts          build.sh, export-web.sh, deploy.sh, gen-grass-texture.* (the harness)
/docs             this file + build notes
```

## 5. Build & export pipeline (Docker, headless)

1. **Engine image** (`docker/engine`): build/obtain Godot 4.4 editor **with** `godot_voxel`, and the **Web export template** (`.zip`) with the module compiled via Emscripten. Prefer a reproducible Dockerfile; cache heavy artifacts. If upstream prebuilt `godot_voxel` web templates exist, use them; otherwise compile (`scons platform=web target=template_release`).
2. **Export image / step**: headless `godot --headless --export-release "Web" build/web/index.html` against the project.
3. Output: `build/web/` (index.html, .wasm, .pck, .js). Must export **with threads** where possible.

## 6. Serving & deploy (LOCKED: auto-deploy live)

- Serve `build/web/` from an **nginx** (or equivalent) container that sends, on every response:
  - `Cross-Origin-Opener-Policy: same-origin`
  - `Cross-Origin-Embedder-Policy: require-corp`
  - correct MIME types (`.wasm` → `application/wasm`), gzip/br for `.wasm`/`.pck`.
- The container terminates its **own TLS** for `voxiverse.game-host.org` and self-registers with haproxy: **ssl-manager autossl** pattern — env `HAPROXY_HOST=haproxy`, `SSL_DOMAIN=voxiverse.game-host.org`; join the external `haproxy-net` network; container name stable (e.g. `voxiverse-game`). haproxy (`/home/vrogojin/haproxy`) does SNI SSL-passthrough — do NOT publish host 80/443.
- `deploy/` holds the compose file + any haproxy `domains.map` registration; `scripts/deploy.sh` brings it up and verifies `https://voxiverse.game-host.org` serves the game (HTTP 200, isolation headers present, playable).
- Reference: `/home/vrogojin/haproxy/BACKEND-SETUP.md`, ssl-manager: https://github.com/unicitynetwork/ssl-manager.

## 7. Non-negotiables

- **Git:** all work on branch `feat/voxiverse-bootstrap` (or sub-branches merged into it). Conventional Commits, scope `voxiverse`. Never commit to `main`.
- **Adversarial self-review** after each non-trivial piece (see project CLAUDE.md `/steelman`).
- The **live demo must load and be playable in a desktop browser**; that gate outranks feature depth.
- Document every real decision in `docs/`.

## 7a. Shipped feature layers (built on the decoupled sim/render split)

Each extends the engine without touching the others (see the named doc for the contract):
multi-material voxels + waterlogging (`MULTI-MATERIAL.md`, `WATERLOGGING.md`,
`MULTI-LIQUID.md`), sub-voxel smoothing + sharp slopes (`SUB-VOXEL-SMOOTHING.md`,
`SHARP-SLOPE.md`), snow accumulation + climate (`SNOW-ACCUMULATION.md`,
`M1-SNOWY-WORLD.md`), the far-field LOD (`LOD-DESIGN.md`), and — **see-through linked
portals**: obsidian frames linked by a portal-linking tool, each interior a live
window-frustum SubViewport view of the other frame with the far side's blocks streamed
in behind it, plus optional walk-through teleport (`PORTALS.md`; entirely outside both
render paths, `PortalManager.ENABLED` gate).

## 8. Long-term vision (context, not this milestone)

Full engine: physical pickable items (mass/durability, convertible into voxel material), voxel meshes with varied geometry (grid/sphere/ragdoll), multi-material voxels (ground+puddle+ice+snow+grass), material state machines driven by temperature/light/current, and per-voxel fields (temperature/light/pressure/current/magnetic/gravity). Build the test env so these extend cleanly.
