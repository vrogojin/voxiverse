---
name: voxiverse-spacefly-selftest
description: 2026-07-19 SPACE-FLY self-test flight control — injectable space-nav verbs + two harnesses for headless orchestrator self-verification
metadata: 
  node_type: memory
  type: project
---

Landed on `feat/voxiverse-spacefly` (commit 57bfde5) so the orchestrator can fly + self-verify orbit/interplanetary/Moon mechanics headlessly. All flag-gated, OFF byte-identical (FLAT 6042/0, verify_remote_control 18/0, new verify_spacefly 27/0).

**Command set** (behind the existing CONTROL_ENABLED gate — remote_control.gd ops + relay.mjs OP_WHITELIST): `dev_nav{on}`=F, `nav{verb}`=O(orbit-coast)/G(geostation)/R(detach), `thrust{dx,dy,dz,seconds,gait}`=WASD+Space/Ctrl held, `roll{dir,seconds}`=Q/E. Each routes through the SAME gated space-nav path a keystroke takes via new player.gd actuators `remote_set_dev_nav/remote_nav_verb/remote_set_thrust/remote_set_roll`. Telemetry `space_telemetry()` adds alt/v_circ/orbit_r/body/dev_nav/coasting/flying/on_ground/att (returns {} off ⇒ byte-identical).

**Two self-test paths:**
1. Headless mission gate `res://src/tools/verify_spacefly.gd` (runs TODAY, any build, no browser/GPU/relay) — deterministic per-mechanic proof against the same f64 kernels the wired player uses (ascent, coast N periods, station-keep, deorbit+brake, Earth→Moon SOI swap, Moon 1/6-g). This is the workhorse for autonomous verification.
2. Live scripted flight `tools/remote-bridge/flight.mjs flights/<name>.json` (real-GPU browser via relay; needs a dev build with space-nav flags + CONTROL_ENABLED flipped). Writes cmd_seq to control/outbox, waits done.json, asserts streamed telemetry. Canned: ascent-to-orbit, o-coast-hold, deorbit-land, earth-moon-transfer(template).

**Security unchanged**: mission-control audited gate preserved — outbox-only ingress, token+grant+control-secret; CONTROL_ENABLED stays false on the public site (don't flip without §6 review + /steelman + sign-off). See [[voxiverse-mission-control]], [[voxiverse-remote-bridge]], [[voxiverse-spacenav-design]].

**OPEN**: verbs give held-thrust+coast+station-keep but NOT closed-loop burn-to-target-orbit; precise Hohmann/Earth→Moon injection needs a maneuver planner (Fable design work). SOI swap itself proven by verify_spacefly gate F. Design doc: docs/COSMOS-SPACEFLY-DESIGN.md.
