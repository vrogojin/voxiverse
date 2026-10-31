# Open work — unfinished threads

Compiled at import time (2026-10-29) from the notes in [`agent-notes/`](agent-notes/), the PR #84
description in [`agent-reviews/pr84-body.md`](agent-reviews/pr84-body.md), commit messages, and the
current code on `main` (last commit `f305400`, 2026-09-09). The working roadmap
([`ROADMAP-working-copy.md`](ROADMAP-working-copy.md), identical to [`../ROADMAP.md`](../ROADMAP.md))
lists no in-progress, stalled or planned items: everything on it was completed in PR #84. Everything
below is therefore taken from the notes, not from an agreed plan.

Development stopped after PR #84/#85 (2026-09-08/09). The live site's `index.pck` was last modified
2026-09-07 (checked with `curl -I` at import time).

**Confidence column.** *Verified* = checked against the code on `main` or git history at import time.
*From notes* = the latest note says so, not re-checked. *Uncertain* = notes conflict or are old
enough that later work may have resolved or superseded the item.

Paths without a directory are notes in `agent-notes/`.

## 1. Infrastructure gaps (do these first)

| Item | Source | Latest status | Confidence |
|---|---|---|---|
| The live A/B deploy script `deploy_cheats.sh` (and `deploy_novillage.sh`, `dump_flags.gd`) was never committed; it lived in an agent session scratchpad. The list of ~212-217 `FP_*` flags that the live build turns on (`CS_FLAGS`) is therefore not in the repo. | `voxiverse-deploy-cheats-pipeline.md`, `docs/COSMOS-BUILDING-RENDER-PERF-STRUGGLE.md` (deploy section) | Not recoverable from git (searched all branches). The served set can be recovered by downloading the live `index.pck` and dumping `cube_sphere.gd` constants headlessly (technique in `voxiverse-atmo-sky-design.md`, `voxiverse-fartree-shift-residual.md`, `voxiverse-lod-ladder-midband.md`). Recommended: recover it, then commit the list and a deploy script. | Verified |
| `main` with all flags at their source defaults is the old flat world (`FACETED := false` in `godot/src/cosmos/cube_sphere.gd`). Exporting `main` as-is and deploying it would replace the live faceted-planet game. | `godot/src/cosmos/cube_sphere.gd:47` | Unchanged. | Verified |
| `scripts/deploy.sh` and `deploy/docker-compose.yml` hard-code paths of the original host (HAProxy directory, default web root). A new host needs these adjusted, and needs the external `haproxy-net` network and HAProxy registration API that `docs/DEPLOY.md` describes. | `scripts/deploy.sh:25`, `deploy/docker-compose.yml:27,31`, `docs/DEPLOY.md` | Unchanged. | Verified |
| Telemetry observer effect: the remote-bridge relay connection itself costs about 200-450 ms hitches, even in `FP_TELEM_LITE` (1 Hz) mode, so frame-time telemetry cannot resolve anything below that floor. A fundamentally lighter telemetry (off-main-thread emit, batched binary) was proposed but not built. | `voxiverse-gen-convoy-mechanism.md` (resolution and "arc closed" sections), `voxiverse-near-radius-diet.md` | Open. Workaround: judge feel on the bare URL, use counters (vox_gen, draws, prims) for A/B. | From notes |
| `CLAUDE.md` and `docs/DESIGN.md` §7 still say all work goes on `feat/voxiverse-bootstrap`; the actual flow since July is feature branches off `main` with PRs to `main`. | `CLAUDE.md`, `docs/DESIGN.md:72`, `git log --merges` | Docs not updated. | Verified |
| `COSMOS-TURN-IN-PLACE-DESIGN.md` (turn-in-place diagnosis) was never committed to `main`; it exists only on a `wip/.../deploy-cheats` snapshot branch. | `voxiverse-gen-convoy-mechanism.md` | Its conclusion was superseded by the observer-effect finding; low priority. | Verified |

## 2. Rendering and LOD

| Item | Source | Latest status | Confidence |
|---|---|---|---|
| LOD-dropout residual for trees: after `FP_SKIN_READY_GATE` + `FP_SKIN_HANDOFF_PREWARM`, structures show no gap but trees can still vanish for about 1.2 s worst case (was about 30 s). | `agent-reviews/pr84-body.md`, `docs/COSMOS-LOD-DROPOUT-DESIGN.md` | Open residual. | From notes |
| Far-tier cross-fades `FP_FT_NEARCULL_XFADE` and `FP_STRUCT_XFADE` (flicker at LOD handoff) are declared but have no implementation; they need live GPU validation. | `voxiverse-ground-walk-perf.md`, `godot/src/cosmos/cube_sphere.gd:1245,1549`, `docs/COSMOS-FARTIER-WALK-DESIGN.md` | Not implemented. | Verified |
| Surface-entry S3 `FP_SHELL_ASCENT_LAZY` is inert under the served flags (`FP_SHELL_SURF_CAP` + fall hold); deferred. | commit `6d58454`, `docs/COSMOS-SURFACE-ENTRY-SPIKE-DESIGN.md` | Deferred; only worth revisiting if surface-entry hitches return. | Verified (commit message) |
| Far-height task #72 residual: about 6-block near-fill skirt on mountainsides; designed fix `FP_V2_NEARFILL_UNSINK` (per-vertex `COLOR.a`) needs a user visual A/B. | `voxiverse-far-height-72-73.md`, `voxiverse-far-height-verdict.md`, `voxiverse-tasks-72-73-state.md` | Deferred. Flag is declared on `main` (`cube_sphere.gd:2357`). Do not tighten the epsilon-sink; check `sh_applied_r` first. | Verified (flag exists) / from notes |
| Far-height task #73 (misalignment report): no code; needs a reproducible scripted flight. | `voxiverse-tasks-72-73-state.md` | Waiting for a repro. | From notes |
| Far-structure "walk calm" (`FP_STRUCT_WALK_CALM`): measured negative while walking (re-commit rate unchanged), later reported as helping orbit jerk, and then the real village-jerk root turned out to be `FP_STRUCT_REG_EPOCH`. Whether it is in the served set now is unclear. | `voxiverse-ground-walk-perf.md`, `voxiverse-village-bake-memo.md` | Default-off on `main`. Check the served pck before relying on it. | Uncertain |
| Seamless-scales requirement vs the O1 design's hard `H_FARSWAP` impostor swap at the atmosphere-space border. | `voxiverse-seamless-scales.md`, `docs/COSMOS-ORBITAL-O1O4-DESIGN.md` §2.8 | The requirement is LOCKED; later far tiers (orbit relief, far trees/cards to orbit, sky fixes) work toward it. Whether any hard swap remains in the served build is not recorded. | Uncertain |
| Block-LOD pyramid open items from July: per-block band not rendering from orbit, band worker priority over base tier, gates assuming at most 9 band layers, diagnostic telemetry to remove, live edit re-bake. | `voxiverse-block-lod-design.md`, `voxiverse-block-lod.md` | `FP_BLOCK_LOD` is false on `main` and was reported not live in August (`voxiverse-lod-ladder-midband.md`). Much of this was overtaken by later far-render work. | Uncertain |
| `FP_SKIN_TIER` kept off live until wider rings exist. | `voxiverse-seamless-scales.md` | From July; probably superseded by the fine-map/band skin work. | Uncertain |
| Dev border overlay `DEV_BORDERS := true` ships by default (thin emissive markers at facet borders). Flagged as a cleanup candidate. | `voxiverse-night-terrain-centre.md`, `godot/src/world/cosmos_border_overlay.gd:22` | Still true on `main`. | Verified |
| Object LOD: framework is on `main` behind `FP_OBJ_LOD`/`_DEBRIS`/`_SPACE` (default off); P2 decimated-mesh rung deferred until a voxel-celled ship/station exists to verify on; minor follow-ons (dev HUD, brighter card). | `voxiverse-object-lod.md` | Deferred. | From notes |
| Smooth far geometry: the slot-mesh path was declared a dead end on web (2026-08-03) and RenderingServer region writes were called unsafe. PR #84's `FP_OR_COMMIT_PARTIAL` later used RenderingServer region uploads with a boot self-check and was confirmed working live. | `voxiverse-far-smooth-geometry.md`, `agent-reviews/pr84-body.md` | The older verdict is contradicted by the newer result; re-evaluate before assuming either. Branch `feat/voxiverse-far-smooth-milestone` was never merged. | Verified (branch) / uncertain (scope) |

## 3. Performance

| Item | Source | Latest status | Confidence |
|---|---|---|---|
| Near-surface landing hitch at the end of a de-orbit fall (alt about 70-150, near-field generation flood); about 150 ms after subtracting the observer floor. | `voxiverse-gen-convoy-mechanism.md` ("de-orbit fall measured"), `voxiverse-fall-mesh-stall.md` | Minor residual; existing levers are `FP_LANDING_STREAM_KICK`, `FP_SUMMIT_STREAM`. The "next approach" in `voxiverse-fall-mesh-stall.md` (freeze-independent descent signal) was never tried. | From notes |
| Near-radius diet `FP_NEAR_RADIUS_DIET`: near field 64 instead of 128 cuts descent generation by 77% at a visual cost; the radius is the user's call. Next suggested step: measure the far-tier residual (near on, far off). | `voxiverse-near-radius-diet.md` | Value in the served build not recorded after 2026-09-01. | Uncertain |
| WASM dlmalloc single-lock convoy during chunk generation (worker-side per-block allocation storm). Stage-1 probes and diet landed as engine patches 0003/0015/0016/0017; a buffer recycler was held for "Build #2"; a native per-process admission budget in `VoxelTerrain::process_viewers` was the fallback. | `voxiverse-gen-convoy-mechanism.md`, `voxiverse-gen-convoy-stage1-patches.md`, `docs/COSMOS-GEN-CONVOY-DESIGN.md` | Arc closed on 2026-08-31 after the observer-effect finding (surface perf judged fine on the bare URL). Build #2 never done. Reopen only with bare-URL evidence. | From notes |
| Background fine-baker governor (P4) and other deferred items from the orbit far-ring churn plan. | `voxiverse-orbit-perf-farring-churn.md` | P4 deferred; P6 (mimalloc) rejected. Later prebake pacing (P7, `voxiverse-prebake-pacing-p7.md`) addressed the orbit grind. | Uncertain |
| De-orbit stream pacing `FP_STREAM_FALL_PACE` + `FP_REENTRY_VIEW_RAMP`: neutral result, shelved; lives only on unmerged branch `perf/fall-stream-pace` (investigation record merged as PR #82). | `voxiverse-fall-stream-pace.md` | Shelved. Not on `main`. | Verified |

## 4. Gameplay, agents and control

| Item | Source | Latest status | Confidence |
|---|---|---|---|
| Agent autonomy A1-A4 (`break_cell`, `aim_cell`, `goto`, `chop_tree`) is merged (PRs #74/#75); live `chop_tree` A/B was pending a browser session. Scoped-out follow-ups: dig-through goto edge, long-range goto with a path cache, a collect skill, fly-goto. | `voxiverse-agent-autonomy.md`, `voxiverse-agent-autonomy-design.md` | Follow-ups not started. | From notes |
| Agent-control P0-P2 (low-latency outbox, `FP_AGENT_POSE`, `FP_AGENT_QUERY`) merged (commit `f338706` is on `main`); the harness side (await `done.json`, use `query_ray` for aiming) was listed as next. | `voxiverse-agent-control-design.md`, `voxiverse-agent-control-initiative.md` | Harness update status unknown. | Uncertain |
| Remote control on the public site: `CONTROL_ENABLED := false` in source; control needs a second host secret on the relay and a human consent step. The go-live procedure is in the note. | `voxiverse-mission-control.md`, `tools/remote-bridge/README.md`, `godot/src/net/remote_bridge.gd:63` | Source default off; the live A/B builds turn it on for dev cheats. Do not enable on the public default build without a security review. | Verified (source) |
| Faceted planet: debris reframe at a seam and `(fid, cell)` edit keys (edits made before a crossing could misplace afterwards) were deferred as rare. | `voxiverse-faceted-planet.md` | A `verify_edit_fid_index.gd` gate exists, so edit keys may have been addressed; not confirmed. | Uncertain |

## 5. Platform and engine

| Item | Source | Latest status | Confidence |
|---|---|---|---|
| Migration from Godot 4.4.1 + godot_voxel 1.4.1 to Godot 4.6 + voxel 1.6 "after FP-M2"; renderer-gated. | `voxiverse-godot-migration.md` | Not started. Pins in `docker/engine/versions.env`. | Verified (pins) |
| WebGPU: module compatibility green, but real WebGPU with compute on the web export is not achievable with the current fork/toolchain (red). | `voxiverse-webgpu-fork-spike.md`, `voxiverse-godot-migration.md` | Do not migrate the live pipeline; revisit if the fork gains an emscripten WebGPU backend. | From notes |
| Per-body configuration: planetary constants (`ATMO_TOP`, rim constants, `R_BLOCKS`, climate, day length) are still global; standing rule is to derive per body and consolidate into one body-config struct when scheduled. | `voxiverse-generic-body-params.md`, `godot/src/cosmos/cube_sphere.gd:3361`, `godot/src/cosmos/facet_atlas.gd:13` | Not scheduled. | Verified (constants still global) |
| Multi-body / walkable Moon (`MULTI_BODY`, `SOI_SWAP`, `FP_MOON_RING`) and climate/weather (`FP_CLOUDS`, `FP_PRECIP`, `FP_STORMS`) exist on `main`, default off. Weather flags were in the deploy script's must-stay-off set. | `voxiverse-o4c-soi-walk.md`, `voxiverse-climate-w0-w4.md`, `voxiverse-deploy-cheats-pipeline.md` | Not enabled live as of the last notes. Turning them on needs a live visual review. | Verified (flags) / from notes |
| Orbital O1 live wiring (player orbital mode, re-entry orchestration, HUD) was deferred in July to a browser-available session; later space-nav and de-orbit work implemented most of the flight loop. | `voxiverse-orbital-o1o4-staging.md`, `voxiverse-sn1-orbital-substrate.md`, `voxiverse-spacenav-design.md` | Probably largely done; open D-O4 decisions (airless-Moon landing pacing etc.) not recorded as resolved. | Uncertain |

## 6. Unmerged branches with possible value

From `git branch -r --no-merged origin/main` at import time (excluding `backup/*` and `wip/*`
snapshot branches, which mirror local worktrees):

- `feat/voxiverse-block-lod-p1` (2026-07-25) — block-LOD P1 visible L2 ring.
- `feat/voxiverse-tile-bake-block-exact` (2026-08-03) — later docs/telemetry on top of the C++ tile bake.
- `feat/voxiverse-far-smooth-milestone` (2026-08-04) — smooth far-geometry milestone, awaited a user eyeball.
- `perf/fall-stream-pace` (2026-08-22) — shelved fall stream pacing.
- `deploy/cheats-eyeball` (2026-08-02) — an old deploy branch.
- `feat/voxiverse-portals` and several `docs/voxiverse-*` study branches from July.

Check with `git log origin/main..<branch>` before reviving any of them; most were superseded.
