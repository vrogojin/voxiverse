---
name: voxiverse-overnight-2026-07-19
description: "2026-07-19 overnight unattended directive — 4 big features (LOD/multi-body, sky+lighting+terminator, physical weather, biomes) + walkable Moon; user decisions locked"
metadata: 
  node_type: memory
  type: project
---

Overnight unattended run starting 2026-07-19 ~01:00. User went to bed; directed me to implement 4 large features with the team + Fable, take best autonomous decisions, flip features ON live as they pass gates. NEVER-OOM ([[voxiverse-never-oom-web]]) still HARD (memory > visuals) even where it caps the user's ambition.

**Foundation deployed first (LIVE 8f1686c, 22:57 GMT):** natural Earth/1000 — R_BLOCKS=6371, consistent 9.8 gravity (walk==orbit), ÷√1000 clock (day 45.5min, v_circ≈250 b/s, escape 354, r_geo 42241), far-side shell renders, sub-camera hole fixed, stream-safe re-entry (ATMO_BRAKE_TERMINAL=20), velocity HUD. See [[voxiverse-orbit-decay]], [[voxiverse-orbital-shell]], [[voxiverse-two-gravity-systems]].

**USER DECISIONS (AskUserQuestion):**
1. Priority = LISTED ORDER 1→2→3→4 (go deep in order).
2. Deploy policy = FLIP ON LIVE as each passes gates (aggressive; user wakes to fully-featured live build). Still keep NEVER-OOM + headless gates as the bar before baking ON.
3. Moon = render + detail-on-approach LOD AND START the walkable surface (big SN6, may not finish).
4. Weather = MORE PHYSICAL simulation (wind/pressure/moisture) — but MUST stay memory-bounded (NEVER-OOM overrides; design the most physical model that fits a hard ceiling).

**THE 4 TASKS:**
1. Multi-body distance-LOD: higher detail from low orbit; render the Moon in the sky (currently unrendered = memory); gradual detail-on-approach (no pop, seamless-scales); telescope-ready generic per body (angular-size-driven LOD). Tier ladder above/below the far-ring shell (CELLS=4) → dense-cap (S3 FP_SHELL_DENSE_CAP) → near voxels.
2. Sky+lighting: Sun DirectionalLight (day lit/night dark, same from space+surface), Moon shine (phase-scaled), Moon PHASES from real Sun-Moon-Earth ephemeris geometry, spectral EARTH TERMINATOR (real-data scattering ramp blue→green→orange→red vs optical air mass), sunrises/sunsets (same scattering model at the horizon).
3. Physical-but-bounded weather/climate: coarse global grid (pressure/temp/humidity/wind) → clouds (semi-cubic smoothed, multi-type/multi-altitude: cumulus/stratus/cirrus/cumulonimbus), rain/snow/fog/wind/thunderstorms/hail; drivers terrain(orographic)+water(evap)+latitude(Hadley); SEASONS from 23.4° axial tilt (subsolar latitude oscillates over the DAY_GAME-year). Lives in the DECOUPLED sim layer (godot/src/sim/per_voxel_environment).
4. Biomes: Minecraft biome set by climate zone/LATITUDE — Whittaker temp×moisture classification, per-biome trees/mountains/forests, DATA-change into generated_block/BlockCatalog, deterministic on-demand (no per-voxel biome storage), coherent with shell colours (profile_at_dir), works with climate OFF (static latitude/altitude/moisture proxy).

**In flight:** Fable design-lod-sky → docs/COSMOS-LOD-SKY-DESIGN.md (tasks 1+2); Fable design-climate-biomes → docs/COSMOS-CLIMATE-BIOMES-DESIGN.md (tasks 3+4); rescale-planet closing the dormant G-TIER-ENVELOPE R-scaling gate (FP_TIER_ENVELOPE off in live, zero live impact). Then Opus implements per each staged flag-gated plan; gate; bake ON + deploy per decision 2.

**Process notes:** always `git checkout -- cube_sphere.gd` before FLAT (contamination→false 6020/15; clean base 6035/0). Committing another agent's uncommitted work: BEWARE `git checkout -- <file>` also reverts THEIR uncommitted edits (I clobbered BACKSTOP_SINK_FRAC once; restored 0.5 = sink at R=3072). Merge each fix branch off the current deploy HEAD; re-run the FULL sweep on the merged tree (per-gate flag configs) before deploy — the rescale surfaced 2 R-coupled issues (stale verify_odecay seeds; real BACKSTOP_SINK poke-through) only visible when combined.

## DEPLOY LOG (overnight progress)
- Foundation LIVE 8f1686c (natural Earth/1000).
- Batch 1 LIVE 23:48 (113f245→): FP_CLIMATE_BIOMES + SKY_MOONSHINE + SKY_SCATTER_RAMP ON.
- Batch 2 LIVE 00:21 (6249825): + FP_SEASONS FP_CLIMATE_GRID FP_CLOUDS FP_PRECIP FP_STORMS ON (full weather). CPU caveat: weather grid sweep CELLS_PER_FRAME=24, agent ×4-projected 0.53ms/frame (×25 doesn't apply — zero-alloc compute); the ONE live-unverified item; knob=CELLS_PER_FRAME, disable=FP_CLIMATE_GRID.
- M2 moon ring MERGED 2dbcff1 (FP_MOON_RING, verify_moonring 26/0, budget ≤2.5MB GPU/0.94MB CPU) — HELD OFF (Moon terrain look live-only; crater-seam-clip flagged for taste pass). Moon impostor disc ALREADY live (ORBITAL_SKY).
- Gate baselines shifted: FLAT byte-identity now 6042/0 (biomes cactus +7). Gates: verify_weather 48/0, verify_climate(biomes) 20/0, verify_lod_sky 42/0, verify_body_lod 34/0, verify_multibody 8/0-off 25/0-on, verify_moonring 26/0.

## HELD FLAG-OFF for user AM screenshot review (render/look-risk, can't verify headless):
SHELL_TERMINATOR_TINT (space terminator shader, P3-class gl_compat risk), SKY_MOONSHINE_LIGHT (2nd DirectionalLight draw-doubling), FP_BODY_LOD+FP_SKY_DSKY_R (LOD law + star-dome-dist fix; law needs M2), MULTI_BODY+FP_MOON_RING (Moon real-terrain render). Each one-flag-on; gated headless.

## REMAINING: impl-o4c (walkable Moon: SOI swap + landing + surface walk) in flight off 2dbcff1.

## O4c DONE — walkable Moon COMPLETE at infra level (2026-07-19 ~01:00)
O4c merged 6a4ed23 (flag SOI_SWAP, default off): SOI dominant-body swap Earth↔Moon, Moon landing (airless, no atmo braking), Moon surface walk (lower g, moon_profile terrain, multi-body edit overlay). verify_o4c 26/0; byte-identity off KEYSTONE = _dominant_body() collapses to "earth" unconditionally with SOI_SWAP off. Core-gameplay regression all green (FLAT 6042/0, multibody 8/0, nav 52/0, orbital 32/0, dev_flight 24/0, ocoast 24/0, odecay 42/0, snfix2 48/0). NOT redeployed (all Moon flags off ⇒ live build byte-identical to batch 2).

**TO ENABLE THE WALKABLE MOON (live fly): bake MULTI_BODY + FP_MOON_RING + FP_BODY_LOD + SOI_SWAP ON, export, fly to the Moon.** All live-unvalidated (landing/walking on a 2nd body needs a real fly) — held OFF for the user, not baked unattended.

## OVERNIGHT COMPLETE — all 4 tasks + walkable Moon delivered.
LIVE: natural Earth/1000, biomes, moonshine+sunsets, full weather (W0-W4). MERGED+GATED+FLAG-OFF (AM review): Moon foundation+render+walk (O4a/O4b/M2/O4c), LOD law (M1), space terminator shader, 2nd moon-light, star-dome-dist fix. Everything byte-identical off, headless-gated. NEVER-OOM held throughout (all measured ≤ ledger). Only live-unverified item baked ON = weather-grid CPU (conservative ×4 est).

## SESSION 2 (2026-07-19 PM) — pilot found bugs, gave unattended-finish mandate
User tested the overnight build, reported bugs, then went to bed AGAIN with mandate: "finish all the fixes unattended, do all tests + merges properly, browser left running." DECISION (AskUserQuestion): BAKE ON EVERYTHING I CAN VERIFY (headless + live self-test via the running browser + flight scripts); walkable Moon ON if I self-verify an Earth→Moon transfer+landing; hold OFF only pure-look items needing human screenshots.

PILOT BUGS (this session):
- Walking jerkiness → FIXED: weather sim on worker thread (FP_WEATHER_THREAD, EnvSimWorker, main cost 136µs→0.76µs). MERGED e1a8628-era.
- Clouds 90°-off + rain-in-space → FIXED: cloud_layers radial local-surface shell + altitude gate (≤ATMO_TOP). verify_weather 55/0. MERGED.
- Sun/Moon invisible, dark-side-lights-up, sky-color-in-space, no atmosphere-halo → design-atmo-sky DONE (docs/COSMOS-ATMO-SKY-DESIGN.md): 4 root causes incl BUG0 = SN3 scaled-body block DEAD behind main.gd FLAT_WORLD return (same class as shell-driver bug). Impl NOT yet dispatched (sequence after re-entry to avoid main.gd conflict).
- **GAME-BREAKING: de-orbit teleport** — descending through ATMO_TOP(384), position teleports 392→11473 alt in one frame, garbage v_bci=642074 (=Δp/dt of the teleport), nav STUCK in low_orbit (never→planetary), then escapes to 224k alt + 27s/frame freeze. fix-reentry-blowup (Fable, TOP PRIORITY) in flight. Likely natural-rescale mis-calibrated the classifier bands + atmosphere-entry handoff. Telemetry evidence in the brief.
- Facet-seam misalignment 8+ blocks + far-LOD see-through holes + multi-fidelity-queue question → design-facet-seams (Fable) in flight. Likely rescale-amplified (facet edge 200→417).

BANKED (merged, flag-off, deploy HEAD e1a8628): weather-thread, cloudfix, spacefly (flight self-test: tools/remote-bridge/flight.mjs + flights/{ascent-to-orbit,deorbit-land,earth-moon-transfer,o-coast-hold}.json; verify_spacefly 27/0), atmo-sky design doc, facet-seams design (pending). LIVE = review build (20:43: biomes+seasons+moonshine+terminator+moonlight+dsky ON; weather/scatter OFF).

SELF-TEST CAVEAT: live flight-script test needs (a) a deployed build with the SPACE-FLY control flag ON, (b) the browser tab to RELOAD it (won't auto-reload; try a remote reload via the relay). The CURRENTLY-loaded review build lacks spacefly, so can't drive it yet. Headless gates are the reliable verification; live self-test is a bonus if reload works.

PLAN: (1) land+verify+deploy re-entry fix FIRST, self-test deorbit-land. (2) dispatch atmo-sky impl on top. (3) facet-seams impl when design lands. (4) bake ON all headless+self-test-verified, final deploy. Sequence merges to avoid main.gd/player.gd/nav conflicts (re-entry touches those). FLAT baseline 6042/0 (textured env); fresh-worktree shows 6027/15 texture artifact — always verify FLAT in the main worktree (import cache present).

## SESSION-2 PROGRESS (2026-07-19 ~22:00)
- RE-ENTRY FIX done+merged (a62bb5e) + LIVE. verify_reentry 20/0 (heal reproduces+fixes the 25737 teleport→0.9; latch 664796→v 91.5), verify_nav 52→70/0, full orbital suite unmoved, FLAT 6042/0. Root cause = half-committed facet crossing (set_active_facet commits but player reframe applied after a fallible pipeline; abort → pose in new facet's ±32768 frame = 1-frame teleport; FD velocity=Δp/dt=642074). Fix = player._heal_frame_desync invariant + CosmosNav FD_SPEED_MAX/sane_v + clamp_bci_state(NaN revert, SOI clamp strips outward v).
- CHECKPOINT DEPLOY LIVE 21:53:50: re-entry fix + WEATHER BACK ON (FP_CLIMATE_GRID+FP_WEATHER_THREAD+FP_CLOUDS+FP_PRECIP+FP_STORMS, threaded+radial-frame clouds) + biomes+seasons+moonshine+terminator+moonlight+dsky. SKY_SCATTER_RAMP still OFF (atmo impl will fix). Still-buggy in this build: sky (sun/moon 8px, dark-side-lights-up, no atmosphere halo) + facet seams — both being fixed now.
- SELF-TEST GATED: flight.mjs drives via control/outbox → relay → browser, BUT control needs a HUMAN-ARMED grant (mission-control security, #113) which the sleeping user hasn't given. Can OBSERVE telemetry, cannot DRIVE. Do NOT bypass the security gate. Verification stays HEADLESS + user's morning fly. (reload IS in OP_WHITELIST but still grant-gated.)
- IN FLIGHT: impl-atmo (A0-A6 atmosphere/lighting, off a62bb5e) + impl-seams (FS0/FS1/FS2 facet-seam + C++ mirror needing scripts/build.sh rebuild). When both land → merge+verify+FINAL deploy bake-everything-verified-ON.

## FINAL DEPLOY PLAN (session 2, ~22:40) — full merged tree c91ec37, GDScript FULLY VERIFIED
GDScript gates ALL GREEN on the combined tree (re-entry+FIXD + seams FS0/FS1/FS2 + atmo A0-A6): FLAT 6042/0 (byte-identity OFF — every new system flag-gated), verify_atmo_sky 55-58/0, verify_reentry 20/0, verify_nav 72/0, verify_facet_seams 12/0, verify_shell_weld 4/0, verify_facet_datum 7/0, verify_faceted 84/0, verify_fixed_frame 240/0, verify_farring_cover 14/0, verify_multibody 8/0 (G-O4-EQ Earth hashes unchanged), verify_orbital 32/0, verify_orbital_sky 38/0, verify_sn_atmo 29/0. Pushed c91ec37.

BAKE DECISION (final deploy): ON = all fixes (re-entry shipped-path) + weather (FP_CLIMATE_GRID+FP_WEATHER_THREAD+FP_CLOUDS+FP_PRECIP+FP_STORMS+FP_SEASONS) + FP_CLIMATE_BIOMES + FULL ATMOSPHERE A0-A6 (FP_SN3_MAIN_LIVE+FP_SKY_PLANET_OCCLUDE+FP_SUN_PRESENCE+FP_ATMO_SPACE_ZERO+FP_LIGHT_ABSOLUTE+FP_SHELL_ABSOLUTE+FP_ATMO_SHELL) + SKY_MOONSHINE(+LIGHT) + SKY_SCATTER_RAMP (now space-safe via A3) + FP_SKY_DSKY_R + FP_SHELL_WELD (see-through). Reasoning for baking atmo shaders: user explicitly asked to "enable terminator+moonlight for review" → wants to SEE shaders; all have permanent fallbacks (can't break); headless-compiled clean; per-flag revertible. HOLD OFF: walkable Moon (MULTI_BODY/FP_MOON_RING/FP_BODY_LOD/SOI_SWAP — user conditioned on self-verified transfer+landing, blocked by control-security gate).

BLOCKER: FP_RADIAL_DATUM (FS2 8-block-step fix) needs the C++ mirror — patch 0008 is TRUNCATED/mis-targeted (generate_block hunk, should be sample_columns; corrupt at line 202). build.sh aborts. Asked impl-seams to regenerate/delete 0008 + confirm git-apply-check clean. THEN: scripts/build.sh (~24min) → G-CG-COLUMNS C++↔GDScript parity → bake FP_RADIAL_DATUM too. FALLBACK if 0008 unfixable: ship FP_SHELL_WELD ON (far see-through fixed) + FP_RADIAL_DATUM OFF (step-fix = 1-rebuild follow-up). 0007 (generator) applies clean.

## FINAL BUILD LIVE (session 2 complete, 2026-07-20 ~00:53 local / 22:52 GMT)
Deploy 5b1d276 + 53 flags baked. NEW ENGINE confirmed deployed: index.wasm 45345567→45346412 bytes (FS2 C++ datum mirror 0007/0008/0009 compiled in). C++↔GDScript parity G-CG-CELL 0/605184 mismatched (datum on+off). FLAT 6042/0 new engine.
LIVE (baked ON): re-entry fix (teleport heal+dwell), weather (grid+worker-thread+radial-clouds+precip+storms+seasons), biomes, FULL ATMOSPHERE A0-A6 (FP_SN3_MAIN_LIVE+SKY_PLANET_OCCLUDE+SUN_PRESENCE+ATMO_SPACE_ZERO+LIGHT_ABSOLUTE+SHELL_ABSOLUTE+ATMO_SHELL + moonshine+scatter+dsky+terminator), seams (FP_SHELL_WELD see-through→0 + FP_RADIAL_DATUM 8-block-step→1.04). HELD OFF: walkable Moon (MULTI_BODY/FP_MOON_RING/FP_BODY_LOD/SOI_SWAP — control-gated self-test).
CAVEATS for pilot: (1) atmosphere shaders are gl_compat P3-class, headless-compiled + permanent-fallback but LOOK unverified (no GPU/screenshot) — per-flag revertible if any looks wrong. (2) FP_RADIAL_DATUM runtime look (cliffs-gone/ocean-continuous) headless-geometry-proven but not live-flown. (3) verify_cppgen G-CG-CELLCOVER sea-fill-coverage assertion fails identically datum-off (test region has no sea at R=6371) — coverage artifact, not a correctness regression. (4) walkable Moon fully built+gated, one flag-set from ON, awaits a live fly.
ALL overnight session-2 bugs fixed: jerkiness (thread), clouds (frame+gate), de-orbit teleport (heal+dwell+guards), sky (atmosphere A0-A6), facet seams (weld+datum). 6 Fable designs + ~10 Opus impls integrated, every merge FLAT-6042/0-verified.
