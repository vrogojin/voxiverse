# docs/knowhow — imported agent know-how

This folder holds the working knowledge that earlier AI coding agents accumulated while building
VOXIVERSE between July and early September 2026. It was imported so that a new agent (or a human)
can pick the project up without re-deriving two months of root-cause analysis. Start with
[`../../AGENTS.md`](../../AGENTS.md); come here when you need the detail behind a claim.

## What is in here

| Path | What it is |
|---|---|
| [`agent-notes/`](agent-notes/) | 134 short notes plus an index ([`agent-notes/MEMORY.md`](agent-notes/MEMORY.md)). Each note records one investigation, design, decision, gotcha or shipped change, written by the agent at the time. |
| [`agent-notes/MEMORY.md`](agent-notes/MEMORY.md) | The agents' own one-line index of the notes, newest material mostly at the top and bottom. Some index lines point at a different file than their title suggests (for example the "Building-render perf struggle DOC" line links `voxiverse-village-bake-memo.md`); the themed list below is generated from each note's own front matter. |
| [`agent-reviews/`](agent-reviews/) | Raw multi-model review material from the last branch (PR #84): the prompts given to an external reviewer model (`codex-*-prompt.md`, `codex-*-review.md`), its full transcripts (`codex-*-out.md`, very large), and the PR #84 description (`pr84-body.md`). Useful as worked examples of adversarial review, not as current documentation. |
| [`ROADMAP-working-copy.md`](ROADMAP-working-copy.md) | A copy of the working roadmap. At import time it is identical to the committed [`../ROADMAP.md`](../ROADMAP.md) (all items completed in PR #84; the In-progress / Stalled / Planned sections are empty). |
| [`OPEN-WORK.md`](OPEN-WORK.md) | Unfinished threads extracted from the notes and the roadmap, with source and latest known status. |

The design documents that the notes refer to (`COSMOS-*.md`, `DESIGN.md`, `DEPLOY.md`, ...) live one
level up in [`../`](../). Some notes say a design doc is "in the deploy-cheats worktree"; most of those
were later committed to `docs/` on `main`. One that was not is `COSMOS-TURN-IN-PLACE-DESIGN.md`, which
exists only on a `wip/.../deploy-cheats` snapshot branch on the remote.

## How to read a note

Each note is Markdown with a small YAML front matter block:

```yaml
---
name: voxiverse-fartree-frame        # same as the filename
description: one-line summary        # some got truncated at a '#' character; MEMORY.md has the full line
metadata:
  type: project | reference | feedback
---
```

- `type: project` (123 notes) — an investigation, design or change record for a specific problem.
- `type: reference` (8 notes) — how-to material: deploy pipeline, remote bridge, telemetry launch,
  web testing host, headless GPU testing, core count, FLAT gate import.
- `type: feedback` (3 notes) — standing rules distilled from mistakes: GDScript closure trap,
  generic per-body parameters, and the falsified seam-mask theory.

`[[note-name]]` inside a note is a wiki-style link to `agent-notes/note-name.md`. `#NNN` numbers
(for example `#72`, `#129`, `#137`) are the agents' internal task-tracker ids, not GitHub issue
numbers; `PR #NN` refers to pull requests on GitHub. Short commit hashes refer to this repository
(some only exist on unmerged or backup branches).

Notes are dense and written in a terse lab-notebook style: capitalised words mark the conclusion
(ROOT, FALSIFIED, SHIPPED), numbers are live or headless measurements, and `file.gd:NNN` line
references were correct when written but have drifted since.

## Status vocabulary

| Term | Meaning in these notes |
|---|---|
| ROOT / ROOT-CAUSED | The cause was identified, usually by measurement or code trace. Says nothing about whether a fix shipped. |
| SOLVED | Root cause found and a fix shipped and was checked live. |
| DESIGN | A design or spec exists (often a `docs/COSMOS-*-DESIGN.md`); implementation may or may not have followed. |
| SHIPPED | Code is committed behind a flag. Often means "deployed to the live build for A/B", not necessarily merged to `main`. |
| SHIPPED+MERGED | Merged to `main` via a PR (PR number given). |
| SHIPPED-not-MERGED | Built and deployed for testing but deliberately not merged (usually because the A/B was negative). |
| byte-off / default-off | The `FP_*` flag defaults to `false` in source, so `main` behaves byte-identically to before; the live build turns it on at export time. |
| LIVE / DEPLOYED | Turned on in the build served at voxiverse.game-host.org at the time of writing. |
| FALSIFIED / REFUTED | A hypothesis was tested and shown wrong. Do not retry it without new evidence. |
| REJECTED | A built or designed fix was measured and not adopted (or the user rejected it on visual grounds). |
| SHELVED | Built, found ineffective or neutral, kept in history default-off. |
| DEFERRED / HELD | Deliberately postponed, usually because verification needs a live browser session or a user visual check. |
| PENDING / awaiting | Waiting on a live A/B, a user reload, or a user decision. Many of these were resolved later; check newer notes and `git log`. |
| UNSOLVED | Root cause or fix still open at the time of writing. |
| LOCKED | A user (owner) decision that should not be changed without asking. |
| LESSON / LAW / RULE / GOTCHA | A process or technical rule learned the hard way. These are the most reusable part of the notes. |
| EXONERATED | A suspect component was measured and cleared. |

## These are historical records

The notes were written at the moment of each investigation and were not maintained afterwards.
They contradict each other in places, because later work overturned earlier conclusions (for
example the ground-walk "jerkiness" arc in `voxiverse-gen-convoy-mechanism.md` ends by attributing
most of it to the telemetry relay's own overhead, and `voxiverse-backstop-diet.md` calls a flag
"not merged" that is now on `main`). When sources disagree:

1. The current code on `main` wins.
2. Then `git log` and merged PR descriptions.
3. Then the newer note over the older one (dates are in the description or body).
4. Then the design doc in `docs/`.

Notes also refer to things that are not in this repository: session scratchpad scripts
(`deploy_cheats.sh`, `deploy_novillage.sh`, `dump_flags.gd`), local worktrees, a private relay
token, and the original host's HAProxy setup. Treat those as descriptions of a workflow to
recreate, not as files you can find.

## The notes, by theme

Each line is the note's own front-matter description (or its `MEMORY.md` index line where the
description was truncated), lightly shortened.

### Project scope, locked decisions and constraints

- [voxiverse-project](agent-notes/voxiverse-project.md) — VOXIVERSE Godot voxel simulation engine — locked spec, decisions, and deployment target
- [voxiverse-engine-longterm-spec](agent-notes/voxiverse-engine-longterm-spec.md) — VOXIVERSE long-term engine vision — physical objects, voxel materials/states, per-voxel environment fields
- [voxiverse-physics-scale](agent-notes/voxiverse-physics-scale.md) — VOXIVERSE will have MANY persistent physical objects worldwide; physics must be dormant-by-default, activated only on disturbance
- [voxiverse-never-oom-web](agent-notes/voxiverse-never-oom-web.md) — Hard user constraint — the web build must never risk OOM; memory safety outranks visual quality; memory-costly upgrades ship flag-gated OFF behind a measured A/B go-gate
- [voxiverse-seamless-scales](agent-notes/voxiverse-seamless-scales.md) — LOCKED user requirement 2026-07-17 — walking→flying→orbiting must be ONE seamless continuum; no stitches/jumps at facet crossings or the atmosphere-space border; consider rendering surface blocks ...
- [voxiverse-generic-body-params](agent-notes/voxiverse-generic-body-params.md) — ARCHITECTURAL RULE — all planetary params (gravity, radius, terragen, atmosphere, etc.) must be generic/configurable per-body, not Earth-hardcoded, so any planet/planetoid/satellite can be ...
- [voxiverse-neighbour-underground-direction](agent-notes/voxiverse-neighbour-underground-direction.md) — User design direction (2026-07-15) after live post-fix test — neighbour LOD blocks look ugly/misaligned so generate neighbours normally; underground stone-fill + lazy exposure-driven regen to ...
- [voxiverse-godot-migration](agent-notes/voxiverse-godot-migration.md) — Decision on whether/when to migrate VOXIVERSE off Godot 4.4.1, and why visuals don't justify it
- [voxiverse-webgpu-fork-spike](agent-notes/voxiverse-webgpu-fork-spike.md) — WebGPU-fork migration feasibility — module compat GREEN, overall YELLOW (Rust-wasm lib chain is the blocker)
- [voxiverse-overnight-plan](agent-notes/voxiverse-overnight-plan.md) — 2026-07-15/16 overnight unattended directive — finish on-planet mechanics (via the live mission-control loop) + self-merge to main, then implement multi-scale orbital mechanics; full scope + ...
- [voxiverse-overnight-2026-07-19](agent-notes/voxiverse-overnight-2026-07-19.md) — 2026-07-19 overnight unattended directive — 4 big features (LOD/multi-body, sky+lighting+terminator, physical weather, biomes) + walkable Moon; user decisions locked
- [voxiverse-live-review-2026-07-20](agent-notes/voxiverse-live-review-2026-07-20.md) — 2026-07-20/21 live-review deploy chain (seams-v2 + streaming + ATMO2) + confirmed live regressions and the fix agents in flight
- [voxiverse-unattended-perf-2026-07-21](agent-notes/voxiverse-unattended-perf-2026-07-21.md) — 2026-07-21 unattended perf task — user granted live control; loop setup, measured per-mode perf, pervasive drains (shell-weld thrash + main-thread snow), agents in flight
- [roadmap-board-sync](agent-notes/roadmap-board-sync.md) — This project keeps docs/ROADMAP.md and its GitHub Project board auto-synced (four-state model); run /roadmap-sync to reconcile.

### Tooling, deploy pipeline and test discipline

- [voxiverse-deploy-cheats-pipeline](agent-notes/voxiverse-deploy-cheats-pipeline.md) — How live A/B builds are deployed to voxiverse.game-host.org — deploy_cheats.sh (lives ONLY in scratchpad, NOT git) seds ~217 CS_FLAGS + env CLITE_FLAGS ON → export-web → deploy.sh --no-build → ...
- [voxiverse-deploy-cheats-cs-rb-revert-trap](agent-notes/voxiverse-deploy-cheats-cs-rb-revert-trap.md) — deploy_cheats.sh git-checkout-reverts cube_sphere.gd + remote_bridge.gd every run — any UNCOMMITTED flag/const there is wiped, breaking refs in other files
- [voxiverse-remote-bridge](agent-notes/voxiverse-remote-bridge.md) — How the agent observes/instruments a live real-GPU VOXIVERSE session in the user's browser (remote-play bridge)
- [voxiverse-remote-telemetry-launch](agent-notes/voxiverse-remote-telemetry-launch.md) — How to launch the live VOXIVERSE web game with remote-play telemetry capture (connect URL + token + relay + where telemetry.jsonl lands)
- [voxiverse-mission-control](agent-notes/voxiverse-mission-control.md) — Mission-control remote-control channel (Houston→rover) — built P1-P3, security-audited, go-live GATED on
- [voxiverse-spacefly-selftest](agent-notes/voxiverse-spacefly-selftest.md) — 2026-07-19 SPACE-FLY self-test flight control — injectable space-nav verbs + two harnesses for headless orchestrator self-verification
- [voxiverse-gpu-headless-testing](agent-notes/voxiverse-gpu-headless-testing.md) — How to automate rendered-outcome tests (frame-timing, visuals, heap-under-render) for VOXIVERSE despite no GPU on the build host
- [voxiverse-web-testing-host](agent-notes/voxiverse-web-testing-host.md) — dev host has NO GPU and lacks Chrome's system libs; rootless workaround to run Playwright here; real GPU web-soak must run on a cloud T4
- [voxiverse-flat-gate-import](agent-notes/voxiverse-flat-gate-import.md) — verify_feature FLAT shows 15 texture failures in a fresh worktree until godot --import is run
- [voxiverse-gdscript-closure-trap](agent-notes/voxiverse-gdscript-closure-trap.md) — GDScript lambdas capture by value — headless verify_*.gd drivers must use inline loops, not closures
- [voxiverse-web-time-process-invalid](agent-notes/voxiverse-web-time-process-invalid.md) — Godot Performance.TIME_PROCESS is invalid on the threaded web export (~77-136ms at 60fps) — never use it as a frame-cost signal on web; measure real frame deltas instead
- [voxiverse-web-core-count](agent-notes/voxiverse-web-core-count.md) — TRUE core count on VOXIVERSE web = navigator.hardwareConcurrency (telemetry cores=8); OS.get_processor_count() UNDER-REPORTS on Godot web (telemetry os_cores=2 — do NOT use it for sizing/offload ...
- [voxiverse-mimalloc-fit-build](agent-notes/voxiverse-mimalloc-fit-build.md) — 2026-08-23 mimalloc-FIT engine build (arena_reserve 128→16 MiB) — the 3 build-plumbing traps that silently ship a STALE web template, and how build-engine.sh guards them
- [voxiverse-gen-convoy-stage1-patches](agent-notes/voxiverse-gen-convoy-stage1-patches.md) — GEN-CONVOY Stage-1 engine patches (probe + diet), the memnew-bypass allocator finding, and the git-ignored-cache editing gotcha

### Agent control and autonomy (remote play)

- [voxiverse-agent-control-initiative](agent-notes/voxiverse-agent-control-initiative.md) — 2026-08-15 initiative — agent-grade remote control + situational awareness (low latency, orientation telemetry, direct voxel-data queries)
- [voxiverse-agent-control-design](agent-notes/voxiverse-agent-control-design.md) — 2026-08-15 agent-control+awareness DESIGN done (docs/COSMOS-AGENT-CONTROL-DESIGN.md in deploy-cheats worktree) — P0 fs.watch outbox + await ack/done (576→~100ms), P1 FP_AGENT_POSE two-frame ...
- [voxiverse-agent-autonomy-design](agent-notes/voxiverse-agent-autonomy-design.md) — Agent-autonomy DESIGN #140 — 2026-08-17 break-by-cell no-op ROOT = _target_arg array→"aim" silent downgrade; scripted A*+skills+LLM, all-LATTICE params
- [voxiverse-agent-autonomy](agent-notes/voxiverse-agent-autonomy.md) — 2026-08-17 agent autonomy A1-A4 (break_cell/place_cell/aim_cell/goto/chop_tree) — the scripted play-loop that makes find→approach→aim→chop one call; SHIPPED byte-off, deployed+relay-swapped, live ...

### Faceted planet, seams, frames and collision

- [voxiverse-faceted-planet](agent-notes/voxiverse-faceted-planet.md) — PIVOT (2026-07-12): abandon the smooth cube→sphere warp; build a FACETED piecewise-flat planet (k×k flat quad facets, UNDISTORTED cubes per facet, curvature only at seams). User loved the FP0 ...
- [voxiverse-corner-seam](agent-notes/voxiverse-corner-seam.md) — COSMOS seam misalignment ROOT CAUSE = window frame rotates by edge D4 per flip (retained covers rebased translation-only); fix = M_win orientation pin (task #74, docs/COSMOS-FRAME-ORIENTATION.md). ...
- [voxiverse-facet-seams](agent-notes/voxiverse-facet-seams.md) — 2026-07-19 ROOT-CAUSED: facet-seam 8-block cliffs = plane-datum step (height g is d̂-pure but PLACED g blocks up each facet's own mean plane; adjacent planes differ at the shared edge by max 5.30 ...
- [voxiverse-seam-slope-weld](agent-notes/voxiverse-seam-slope-weld.md) — 2026-08-11 border-slope fall-through MEASURED — seam floor step 1.5-3 blocks (junction cube ladder hi_A vs hi_B + carve fires-flip + One-Surface residual), double-datum flags DOUBLE it; fix ...
- [voxiverse-nb-junction-weld](agent-notes/voxiverse-nb-junction-weld.md) — 2026-08-11 NB junction "tilted floating slab" root cause = dead CORRECTION-2 exclusion latch (pool_seam_meshed geometrically unsatisfiable), NOT placement transforms; fix FP_NB_WELD SHIPPED+MERGED ...
- [voxiverse-border-shade-weld](agent-notes/voxiverse-border-shade-weld.md) — 2026-08-11 SHIPPED+MERGED PR #44 (1c5112b) FP_BORDER_SHADE_WELD — bright interfacet-border strip at dawn/night = FP-CARVE seam-junction carve cubes still on the PRE-unification BlockMaterials ...
- [voxiverse-crossing-phys-spike](agent-notes/voxiverse-crossing-phys-spike.md) — Facet-crossing 200-772ms phys_ms spike is the redesignate PlanetRoot transform write, NOT the GroundCollider
- [voxiverse-upvector-strip-tilt](agent-notes/voxiverse-upvector-strip-tilt.md) — 2026-08-06 post-de-orbit horizon tilt ROOT = hysteresis-strip facet desync (active facet ≠ soil owner), NOT a stale basis; measured 3.744° = facet step; fix design FP_UPVECTOR_FACET_HEAL; doc ...
- [voxiverse-seam-mask-fallthru-law](agent-notes/voxiverse-seam-mask-fallthru-law.md) — FALSIFIED 2026-08-06 — my seam-mask fall-through theory was measured wrong (sign backwards + fallback==surface_y); real cause = facet/pose frame desync (fable-fallthrough's doc); lessons + what ...
- [voxiverse-floor-surface-root-cause](agent-notes/voxiverse-floor-surface-root-cause.md) — 2026-08-06 ROOT of falls-under-ground — floor_under/surface_y disagree only via cross-frame reads (facet/pose transient desync + every-frame re-fire band), NOT datum/junction; fix = ...
- [voxiverse-fallthrough-loc-bug](agent-notes/voxiverse-fallthrough-loc-bug.md) — 2026-07-31 SOLVED — dev geo-teleport lat8/lon2 buried alt-−17 = floor_under≠surface_y (NOT facet); fixed FP_TP_FLOOR_WELD (live alt 7 grass); + deploy-pipeline reverts CS/RB lesson
- [voxiverse-flight-fallthrough-sun](agent-notes/voxiverse-flight-fallthrough-sun.md) — 2026-07-31 flight-landing fall-through (stale active facet during far flight → flat facet datum dives below sphere → surface_y deep) fixed FP_DESCENT_FACET_RESYNC; + dim sunrise sun disc (double ...
- [voxiverse-reentry-blowup](agent-notes/voxiverse-reentry-blowup.md) — 2026-07-19 de-orbit teleport root cause (fid/pose desync + FD-velocity latch) + headless live-scene gate pitfalls (import cache, in-tree/global_position no-op)
- [voxiverse-sharp-slope-manifest-stale](agent-notes/voxiverse-sharp-slope-manifest-stale.md) — 2026-08-11 mountain ladder + fall-under ROOT = FP_MANIFEST_SLICE defers slope-manifest bake past generator freeze (empty slope_arid + stale model_count in GDScript gen AND C++ VoxelGeneratorCosmos ...
- [voxiverse-slope-material-design](agent-notes/voxiverse-slope-material-design.md) — Slope-material root + design — #122 = B_MOUNTAINS-only biome gate (terrain_config + patch 0007 twin); FP_SLOPE_ALL_MATERIALS
- [voxiverse-nb-fullres-design](agent-notes/voxiverse-nb-fullres-design.md) — 2026-08-10 FP_NB_FULLRES Phase C spec (full-res near blocks on edge neighbours); get_statistics has no memory counters, use get_stats().memory_pools.voxel_used
- [voxiverse-nb-fullres](agent-notes/voxiverse-nb-fullres.md) — 2026-08-11 FP_NB_FULLRES SHIPPED+MERGED (PR #41 de2d35e) — full-res near blocks on ALL 4 edge neighbours (was active+1 imminent = seam see-through); post-settle want-4-edges, ≤1 spawn/interval, ...
- [voxiverse-tree-bugs-rootcause](agent-notes/voxiverse-tree-bugs-rootcause.md) — 2026-08-06 acacia no-collision = B_SAVANNA/B_JUNGLE(11/12)==B_MOON_MARIA/HIGHLANDS enum collision (resolve_cell moon-hijack, analytic only, C++ mesh correct); canopy flip+sink = gravity box ±160 ...

### Orbit, space navigation, gravity and multi-body

- [voxiverse-orbital-o1o4-staging](agent-notes/voxiverse-orbital-o1o4-staging.md) — Fable's O1 orbit + O4 walkable-Moon design landed (docs/COSMOS-ORBITAL-O1O4-DESIGN.md); 6-stage plan, tonight = O1 pure kernels only (live-wiring deferred b/c browser-asleep); key op fact = ...
- [voxiverse-sn1-orbital-substrate](agent-notes/voxiverse-sn1-orbital-substrate.md) — SN1 orbital substrate (FP_M3_ORBIT) — f64 kernel landed+gated; interactive player/world loop deferred to live session
- [voxiverse-spacenav-design](agent-notes/voxiverse-spacenav-design.md) — 2026-07-18 space-nav architecture landed on feat/voxiverse-spacenav — five nav-frame modes as pure re-expressions over one BCI f64 state, GM_dyn interim scale fix, SN1-SN6 phase plan
- [voxiverse-orbit-decay](agent-notes/voxiverse-orbit-decay.md) — 2026-07-18 O-orbit decay root cause = coast stored in ROTATING lattice frame → 1-tick spin desync pumps eccentricity; fix = carry [p,v] in f64 BCI + prograde station-keeping
- [voxiverse-two-gravity-systems](agent-notes/voxiverse-two-gravity-systems.md) — VOXIVERSE gravity — orbit uses cosmos_gravity.gm_dyn (=ephemeris gm_game); after the natural 1:1000 retune gm_game EQUALS cube_sphere.gm_for, so orbit g == walk g == 9.8
- [voxiverse-o4c-soi-walk](agent-notes/voxiverse-o4c-soi-walk.md) — 2026-07-19 O4c SOI-swap + walkable Moon landed on feat/voxiverse-o4c behind SOI_SWAP (default off)
- [voxiverse-orbital-shell](agent-notes/voxiverse-orbital-shell.md) — 2026-07-18 far-LOD-from-orbit is a camera-set POLICY fix, not a new mesh — FacetFarRing already meshes the whole globe
- [voxiverse-orbit-real-space](agent-notes/voxiverse-orbit-real-space.md) — 2026-07-30 real-space-at-orbit fix (FP_SKY_DSKY_ALT) + vacuum thermometer (FP_HUD_VACUUM_TEMP) — star dome must TRACK altitude, not raise CAMERA_FAR

### Sky, lighting and climate

- [voxiverse-atmo-sky-design](agent-notes/voxiverse-atmo-sky-design.md) — 2026-07-19 atmo-sky root causes — deployed flags readable from pck via get_script_constant_map; SN3 scaled-body driver DEAD below FLAT_WORLD return; sun invisible = 8px no-glare salience; night ...
- [voxiverse-atmo2-design](agent-notes/voxiverse-atmo2-design.md) — ATMO2 root causes (2026-07-20) — the night "artifact" IS the Sun; near blocks are UNSHADED (why A4 light dimming does nothing); A6 shell 6-80x overbright; no HDR on gl_compat; path-length sun ...
- [voxiverse-terminator-sun-fix](agent-notes/voxiverse-terminator-sun-fix.md) — 2026-07-24: terminator Sun/disc POPS per walk-step (bright-but-no-Sun then pops over horizon) = PRE-EXISTING binary occ>=0.5 flip + dep(h) singularity; fixed FP_TERM_SUN_CONT (continuous presence ...
- [voxiverse-far-terminator](agent-notes/voxiverse-far-terminator.md) — 2026-08-09 far-render day-lit-at-night root cause — terminator is CORRECT+unified in code across all far tiers (refutes missing/wrong-normal/rolled-back); bug is RUNTIME sun_dir staleness, prime ...
- [voxiverse-night-terrain-centre](agent-notes/voxiverse-night-terrain-centre.md) — 2026-07-31 SOLVED "red lava/terrain lit at night, per-facet offset, reversed sweep" = near-field terrain/sea shader normal used normalize(v_wp) assuming planet centre=origin; faceted render centre ...
- [voxiverse-climate-w0-w4](agent-notes/voxiverse-climate-w0-w4.md) — Climate/weather sim W0-W4 landed on feat/voxiverse-climate; flags, measured byte ledger, and the CPU-projection deviation

### Far terrain render and the LOD ladder

- [voxiverse-lod-texture](agent-notes/voxiverse-lod-texture.md) — 2026-07-23 LOD terrain feature — progressive per-facet baked satellite textures (Fable design COSMOS-LOD-TEXTURE-DESIGN); user's 4 locked decisions; phased plan; Phase 1 in flight
- [voxiverse-block-lod](agent-notes/voxiverse-block-lod.md) — 2026-07-25: decimated-block terrain LOD pyramid — user's 'far = coarser BLOCKS not smooth skin' vision. Design COSMOS-BLOCK-LOD-DESIGN.md (FableLOD). Phase 1 FP_BLOCKY_FARRING SHIPPED LIVE. Plan ...
- [voxiverse-block-lod-design](agent-notes/voxiverse-block-lod-design.md) — Block-LOD design accepted — FacetBlockLod pyramid P0-P2 SHIPPED; LESSON never restart relay mid-session
- [voxiverse-textured-lod-design](agent-notes/voxiverse-textured-lod-design.md) — 2026-07-27 textured real-block-surface far-LOD design (3 live-feedback rounds) — blocky+tex composition, FP_BLOCK_DETAIL faces, then 2U band block-map + gridless + cull-not-sink
- [voxiverse-seamless-transition-design](agent-notes/voxiverse-seamless-transition-design.md) — 2026-07-28 Fable design — fly-up near→far pop root cause = VoxelViewer child-of-player ellipsoid (up-reach 64 blk) unloads entire near field at h≈64 (22 px/block, ~10× the τ≈2px invisibility bar); ...
- [voxiverse-far-render-overhaul](agent-notes/voxiverse-far-render-overhaul.md) — 2026-08-02 far-render overhaul — whole-planet fine map (Item A) shipped+Fable-audited, centre-quad root-caused to the sub-pixel band, fine-bake perf wall on 2-core browsers + C++ fix; ...
- [voxiverse-cpp-tile-bake-block-exact](agent-notes/voxiverse-cpp-tile-bake-block-exact.md) — 2026-08-02 C++ lock-free parallel far-skin bake (FP_CPP_TILE_BAKE) + block-exact far colours (FP_SKIN_BLOCK_EXACT) — root cause, byte-exact approach, live deploy
- [voxiverse-far-smooth-geometry](agent-notes/voxiverse-far-smooth-geometry.md) — 2026-08-03 far smooth-geometry ladder (P0-P3) — real far relief + lit mountains + seamless near-transition + invisible facet borders; DEPLOYED headless-gated, awaiting visual eyeball
- [voxiverse-far-geometry-prebake](agent-notes/voxiverse-far-geometry-prebake.md) — 2026-08-10 far-GEOMETRY prebake design (mountains from orbit) — flat-from-orbit = CELLS=4 shell under-sampled + slope-UNSHADED + relief mesh hop-2..4 view-local; fix = 7.5MB global i16 DEM + ...
- [voxiverse-bg-prebake-design](agent-notes/voxiverse-bg-prebake-design.md) — 2026-08-07 background whole-planet prebake design + ugly-facet-in-front root cause — coarse-base fallback from on-surface fine pause; fix = governed view-first pacer over the existing ~27MB fine tier
- [voxiverse-far-skin-block-color](agent-notes/voxiverse-far-skin-block-color.md) — 2026-08-10 far skin painted BIOME colour not block colour on 9 GDScript color_for sites (C++ fine-map already block-exact); fix FP_SKIN_BLOCK_COLOR routes them through fine-map's law, ...
- [voxiverse-orbit-relief-g3](agent-notes/voxiverse-orbit-relief-g3.md) — 2026-08-10 G3 far-terrain 3D relief from orbit SHIPPED+MERGED (PR #39 447d038) — FacetOrbitRelief tier: DEM-displaced mesh + fine-map texture + terminator-only light (no slope shade) + ...
- [voxiverse-lod-ladder-midband](agent-notes/voxiverse-lod-ladder-midband.md) — LOD-ladder mid-band ROOT — #107 giant blocks = 26-blk BLOCKY backstop on live-pool facets
- [voxiverse-lod-ladder-smooth](agent-notes/voxiverse-lod-ladder-smooth.md) — 2026-08-11 blocky-mountain mid-band ROOT = M2 FacetLodMesher l2/l3 megablocks protrude OVER resident SmoothV2 (no arbitration) + hop-0/1 covered by NOTHING but 27-block far-ring backstop; NOT ...
- [voxiverse-far-near-coverage](agent-notes/voxiverse-far-near-coverage.md) — Far-over-near mountain blob ROOT — #110 FacetOrbitRelief frozen un-sunk; FP_ORBIT_RELIEF_SURFACE_HIDE
- [voxiverse-grassbase-backstop](agent-notes/voxiverse-grassbase-backstop.md) — 2026-08-12 #113 SHIPPED+MERGED PR #50 (3af5953) FP_APPLIED_PROBE_SLAB — grey far-over-near at mountain grass BASE = far-ring dense backstop stuck in zone-B because FP_FARRING_APPLIED_COVER ladder ...
- [voxiverse-mesa-viewband](agent-notes/voxiverse-mesa-viewband.md) — 2026-08-12 SHIPPED+MERGED PR #56 (main 5df69bb) FP_APPLIED_VIEW_BAND — mesa grey-oval far-over-near = #113 probe wants full slab but engine loads only mesh rows [c−4,c+3] ⇒ ladder alive only ...
- [voxiverse-far-height-verdict](agent-notes/voxiverse-far-height-verdict.md) — Far-height verdict (pck audit) — 2026-08-15 #72 chain-fixed, residual V2_NEARFILL_SINK skirt; #73 structural classes excluded; LESSON wrong-height vs deliberate-sink class
- [voxiverse-far-height-72-73](agent-notes/voxiverse-far-height-72-73.md) — 2026-08-15 #72/#73 far-render height/misalign — Fable audit verdict + the merged-mesh wrinkle that blocks the designed #72 fix
- [voxiverse-tasks-72-73-state](agent-notes/voxiverse-tasks-72-73-state.md) — Tasks #72/#73 state — never tighten ε-sink, check sh_applied_r first; #73 gate must be scripted flight
- [voxiverse-far-lod-ladder-defects](agent-notes/voxiverse-far-lod-ladder-defects.md) — 2026-08-21 three far-render defects (houses-vanish LOD / black facet seam / near-far colour) root-caused by Fable + fixes
- [voxiverse-tier-depth-priority](agent-notes/voxiverse-tier-depth-priority.md) — Far-ring-over-blocks poke root-caused (2026-07-17) — NOT depth precision; skew+staleness; envelope+bias+ordering design in docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md
- [voxiverse-atlas-staging](agent-notes/voxiverse-atlas-staging.md) — COSMOS-ATLAS draw-call cut (FP_ATLAS_MATERIAL) — Stage 1 cubes + Stage 2 shaped families shipped; slopes/carve/water deliberately per-material

### Far trees, structures (villages) and physical objects

- [voxiverse-far-trees-design](agent-notes/voxiverse-far-trees-design.md) — 2026-08-12 far-trees design — 3-rung hybrid (archetype mini-mesh 128-448 / cross+cap cards to 2400 / fine-map canopy to orbit), octahedral REJECTED for blocky trees; doc COSMOS-FAR-TREES-DESIGN.md
- [voxiverse-far-trees-colorfix](agent-notes/voxiverse-far-trees-colorfix.md) — 2026-08-12 SHIPPED+MERGED PR #55 (main 8ca78bf) — far-trees mesh-band black/cyan/green ROOT = GLES3 MultiMesh color-slot aliasing (custom-only MM + COLOR-reading shader), NOT snow/planet_centre; ...
- [voxiverse-fartree-align](agent-notes/voxiverse-fartree-align.md) — Far-tree align+cull ROOT — #120 sunk = 3 constants; FP_FAR_TREES_ALIGN + NEARCULL
- [voxiverse-fartree-frame](agent-notes/voxiverse-fartree-frame.md) — Far-tree frame weld ROOT — #131 = datum_lift omission + world-axis basis; FP_FT_FRAME_WELD; LESSON dump the DEPLOY WORKTREE pck
- [voxiverse-fartree-shift-residual](agent-notes/voxiverse-fartree-shift-residual.md) — Far-tree shift residual ROOT — #120/#130 FT_SINK_MAX + card dither + state-fold streak; pck const dump via load_resource_pack
- [voxiverse-fartree-polish132](agent-notes/voxiverse-fartree-polish132.md) — Fartree-polish #132 SHIPPED — PRs #62/#63 FT_NEAR_GUARD + TEXMEAN_COLOR + STALE_REBUILD; GOTCHA set_instance_transform NO-OP on set_buffer MM
- [voxiverse-fartree-orbit-dropout](agent-notes/voxiverse-fartree-orbit-dropout.md) — 2026-08-15 far-trees vanish above alt 256 (OFFSURFACE_Y hard-suspend) though cards designed to 2400 blocks — root cause + fix direction
- [voxiverse-fartree-chop-farrender](agent-notes/voxiverse-fartree-chop-farrender.md) — 2026-08-15 chopped tree still FAR-renders — ROOT CAUSE = rung-3 fine-map skin bakes tree canopy colour edit-unaware (cards/mesh ARE chop-filtered)
- [voxiverse-fartree-chop-design](agent-notes/voxiverse-fartree-chop-design.md) — 2026-08-15 #137 chopped-tree far-skin leak IMPLEMENTED 8b1b927 (FP_FT_SKIN_CHOP Stage-B edit-snap writer; gates 21/21+76/0+6042/0); rung-3 = FacetTexBaker band/fine L8 maps NOT facet_skin_tier; NO ...
- [voxiverse-near-leaf-cutout](agent-notes/voxiverse-near-leaf-cutout.md) — SHIPPED+MERGED PR #55 (main 8ca78bf) FP_LEAF_CUTOUT V2 = shared-shader gated discard (0 extra draws); twin FAILED live A/B (57→28fps, draws 58→190) → V2 keeps draws at baseline; early-Z verdict — ...
- [voxiverse-structures-design](agent-notes/voxiverse-structures-design.md) — Structures design #121 — P0 edit-cluster union-find at _write_cell (snow filter!) + OR-occupancy far models; P1 village gen
- [voxiverse-village-bake-memo](agent-notes/voxiverse-village-bake-memo.md) — 2026-08-31 village descent bake spike ROOT + FP_STRUCT_GATE_MEMO fix (6.3x, byte-identical, shipped)
- [voxiverse-object-lod](agent-notes/voxiverse-object-lod.md) — 2026-08-17 physical-object far-render + LOD ladder (FP_OBJ_LOD) — VoxelBody debris/ships/stations/asteroids get a size-derived mesh→decimated→cards→beacon-dot ladder; P0 law SHIPPED byte-off, ...

### Performance: streaming, generation, allocator, frame floor

- [voxiverse-walk-perf-root-cause](agent-notes/voxiverse-walk-perf-root-cause.md) — 2026-07-17 walking-perf root cause — WASM runtime serialization (dlmalloc convoy), NOT worker count / apply budget / movement; fix = mimalloc engine build + alloc diet
- [voxiverse-streaming-supply-demand](agent-notes/voxiverse-streaming-supply-demand.md) — 2026-07-17 SETTLED — walk jank is supply<demand (23-35 blocks/s vs ~90-100 needed, 130ms/block = ~10x WASM penalty); NOT allocator/apply/draws/workers. User's direction = cut+reorder demand ...
- [voxiverse-gen-class-costs](agent-notes/voxiverse-gen-class-costs.md) — MEASURED per-class web gen costs (2026-07-17 T1) — surface 560ms/46%, underground 338ms/51%, web factor ×25 not ×10; R1/R7 correct-but-rejected; L5 C++ generator port promoted to THE plan, R3 skin ...
- [voxiverse-l5a-cppgen](agent-notes/voxiverse-l5a-cppgen.md) — L5(a) C++ worldgen port SHIPPED (flag FP_CPPGEN, patch 0007) — byte-equal, 8-20x native, A/B pending
- [voxiverse-postport-applybound](agent-notes/voxiverse-postport-applybound.md) — 2026-07-17 post-C++-port re-profile — the perf bottleneck INVERTED from generation to main-thread mesh APPLY/upload; supply≥demand now (kills the "supply<demand / cut demand" model); fix = ...
- [voxiverse-postport-apply-bound](agent-notes/voxiverse-postport-apply-bound.md) — Post-C++-port (2026-07-17 PM) perf verdict — streaming is now APPLY/upload-bound not gen-bound; crossing C1=343ms; periodic 2s-capture + 0.5s-snowfall spikes; plan in COSMOS-PERF-POSTPORT-DESIGN.md
- [voxiverse-perf-next-architecture](agent-notes/voxiverse-perf-next-architecture.md) — Post-atlas perf roadmap 2026-07-17 — far-ring exclusion gap root cause + underlay/static-ring design; architecture verdict = keep faceted stack; unexplained 8-15ms frame gap needs ...
- [voxiverse-web-perf-architecture](agent-notes/voxiverse-web-perf-architecture.md) — Fable's first-principles web perf analysis (2026-07-16): the walk/crossing jerkiness is the 204-draw GL-compat vsync-ladder ceiling + a far-ring re-emit bomb + a self-inflicted capture hitch — NOT ...
- [voxiverse-p1-sticky-isolation](agent-notes/voxiverse-p1-sticky-isolation.md) — P1 sticky-alone does NOT hitch in the deployed async far-ring config — rebuild is off-thread; the combined-build hitch was P2-envelope/P3-shader
- [voxiverse-stream-parallel-design](agent-notes/voxiverse-stream-parallel-design.md) — 2026-08-10 fresh-reload 2-3min root cause = G2 DEM bake gate-not-bounded duty-cycle on main thread; design COSMOS-STREAM-PARALLEL-DESIGN.md (FP_DEM_DEFER/ASYNC, FP_NB_FULLRES, one bg token)
- [voxiverse-fast-load-design](agent-notes/voxiverse-fast-load-design.md) — 2026-08-11 fresh-load pile-up root-caused — smooth_v2 whole-annulus commit (185ms, O(N²) fill) + env-converge + snow on main; setpoint_ms is NOT a cost; fix = FP_LOAD_DEFER settle gate; doc ...
- [voxiverse-fast-load](agent-notes/voxiverse-fast-load.md) — 2026-08-11 fast fresh-load SHIPPED+MERGED (PR #42 FP_LOAD_DEFER + PR #43 FP_SMOOTH_V2_PACE/_ASYNC_MERGE) — load pile-up was DEFERRABLE main-thread far/sim work (smooth_v2 185ms commit dominant, ...
- [voxiverse-summit-stream-priority](agent-notes/voxiverse-summit-stream-priority.md) — 2026-08-11 summit near-blocks arrive last ROOT = approach-anchor pins viewer to DATUM not sub-player ground (offset −62 at h=66 → priority inversion) + landing-kick pace floor dead in 96-block ...
- [voxiverse-stream-idle-diet](agent-notes/voxiverse-stream-idle-diet.md) — Idle-diet + probe-calm designs — FP_STREAM_IDLE_DIET + FP_APPLIED_PROBE_CALM R2; LESSON filter root-cause through served flags
- [voxiverse-move-probe-cache](agent-notes/voxiverse-move-probe-cache.md) — Move-probe cache P2b design — #129 t_move 8.8ms = un-memoized cell_value_at; FP_MOVE_PROBE_CACHE; LESSON check mutable layer BEFORE the cache
- [voxiverse-motion-phys-root](agent-notes/voxiverse-motion-phys-root.md) — 2026-08-15 motion phys_ms 5.6→24.6 ROOT — TIME_PHYSICS_PROCESS is a 1Hz MAX-of-single-step monitor (not per-frame sum); GroundCollider exonerated (debris-gated); real cost = update_streaming tail ...
- [voxiverse-forest-fps-root](agent-notes/voxiverse-forest-fps-root.md) — Forest-fps ROOT — #119 = FacetFarTrees 250ms UNCONDITIONAL rebuild PWM'd by credit cycle; FP_FAR_TREES_DELTA
- [voxiverse-forest-fps-limiter](agent-notes/voxiverse-forest-fps-limiter.md) — Forest-fps limiter ROOT #129 — 2026-08-14 rest stall = 4Hz telemetry + controller floor-trap; FP_TELEM_FRAME_DECOMP, FP_CTRL_FLOOR_VSYNC pairs with FT_DELTA_MIN_MOVE
- [voxiverse-forest-snow-warmskip](agent-notes/voxiverse-forest-snow-warmskip.md) — 2026-08-12 SHIPPED+MERGED PR #56 (main 72453ee) FP_SNOW_PRECIP_GATE — warm-forest snow_ms 18-44ms ROOT = SnowfallSystem steps every biome unconditionally (zero writes); fix = whitelist process ...
- [voxiverse-backstop-diet](agent-notes/voxiverse-backstop-diet.md) — Backstop-diet #129 SHIPPED-not-MERGED — FP_SHELL_SURF_CAP −72% verts but fps unlock FALSIFIED (vsync-bound); LESSON A/B the perf premise first
- [voxiverse-ground-walk-perf](agent-notes/voxiverse-ground-walk-perf.md) — 2026-08-30 ground-walk jerkiness near villages (worst_ms median 150/max 378, ~7fps moving) ROOT = far-tier (far-trees+far-structures) rebuild churn every 2 blocks + credit-starvation; draws are a ...
- [voxiverse-gen-convoy-mechanism](agent-notes/voxiverse-gen-convoy-mechanism.md) — 2026-08-30 ground-walk jerkiness Layer B (the deep root) PINNED via wf_* telemetry + 3 engine censuses = WASM dlmalloc single-global-lock convoy from WORKER-side per-block alloc storm (6-7 CoW ...
- [voxiverse-gen-convoy-alloc-census](agent-notes/voxiverse-gen-convoy-alloc-census.md) — Ground-walk dlmalloc convoy per-block allocation census + C++-vs-GDScript generator runtime probe
- [voxiverse-near-radius-diet](agent-notes/voxiverse-near-radius-diet.md) — 2026-08-31 ground/descent jerkiness — near voxel field is a MAJOR cost (DEV_HIDE_NEAR bisection); FP_NEAR_RADIUS_DIET lever; descent gen scales r² (128→3953, 96→2190, 64→900)
- [voxiverse-mimalloc-reab-rejected](agent-notes/voxiverse-mimalloc-reab-rejected.md) — 2026-08-22 P6 mimalloc re-A/B REJECTED on NEVER-OOM (+398MB heap) and no orbit frame win — dlmalloc stays
- [voxiverse-mimalloc-arena-root](agent-notes/voxiverse-mimalloc-arena-root.md) — 2026-08-23 arena_reserve hypothesis MEASURED-REFUTED — capping 128→16MiB did NOT cut mimalloc peak heap (fall peak 842MB ≈ uncapped 834, +430 over dlmalloc); arena_reserve is per-step SIZE not ...

### Performance: fall, de-orbit and orbit

- [voxiverse-deorbit-phys-fix](agent-notes/voxiverse-deorbit-phys-fix.md) — 2026-07-25 de-orbit perf saga SOLVED in 3 rounds — analytic column-memo gap, env-warm convoy, landing stream burst; key non-obvious mechanics + telemetry map
- [voxiverse-orbit-perf-farring-churn](agent-notes/voxiverse-orbit-perf-farring-churn.md) — 2026-08-21 orbit/fall jerkiness ROOT = FacetFarRing SRC_UNSINK rebuild churn (not scaled-body); P0 fix + P2/P3/P5 plan
- [voxiverse-prebake-pacing-p7](agent-notes/voxiverse-prebake-pacing-p7.md) — 2026-08-22 P7 prebake pacing/scoping SHIPPED — coast-cap + view-scope end the orbit fine-map grind convoy (worst frame 147→43ms)
- [voxiverse-fall-instrumentation](agent-notes/voxiverse-fall-instrumentation.md) — 2026-08-22 de-orbit fall perf instrumented — STREAMING (t_stream_us) is the dominant main-thread cost the whole descent; hot bands alt~700 (regime/phys 48ms) + alt~70 (surface entry 83ms); NOT ...
- [voxiverse-fall-stream-pacing](agent-notes/voxiverse-fall-stream-pacing.md) — 2026-08-22 de-orbit fall jerk ROOT = update_streaming tail (skin re-rank + tex SSE re-tier + DEM) unpaced by motion; alt-700 spike = ANCHOR_REL_LO knee NOT ATMO_TOP; design FP_STREAM_FALL_PACE + ...
- [voxiverse-fall-stream-pace](agent-notes/voxiverse-fall-stream-pace.md) — 2026-08-23 FP_STREAM_FALL_PACE + FP_REENTRY_VIEW_RAMP — de-orbit fall stream-pacing fix DEPLOYED + verified offline; live A/B blocked by fall <1s + ?telem=10hz not loading
- [voxiverse-fall-mesh-stall](agent-notes/voxiverse-fall-mesh-stall.md) — 2026-08-23 de-orbit atmosphere-entry ~2-3fps stall = near-field view-regrow GenerateBlock flood (vox_gen 6-7k WASM convoy); FP_REENTRY_BACKLOG_GATE fix SHELVED (non-functional — falling_fast stale ...
- [voxiverse-deorbit-shell-reemit](agent-notes/voxiverse-deorbit-shell-reemit.md) — 2026-08-23 de-orbit stall ROOT (matched live A/B) = far-ring SHELL RE-EMIT burst at the anchor-release knee (~alt 590, sh_emit 1386, ~1M prims, ~1200-2400ms), NOT the near-field gen flood; C-lite ...
