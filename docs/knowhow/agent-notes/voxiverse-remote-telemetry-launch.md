---
name: voxiverse-remote-telemetry-launch
description: How to launch the live VOXIVERSE web game with remote-play telemetry capture (connect URL + token + relay + where telemetry.jsonl lands)
metadata: 
  node_type: memory
  type: reference
---

Launch the live game with observe-only remote telemetry (Phase 1 bridge: telemetry JSON + JPEG frames, no control).

**Connect (web):** open `https://voxiverse.game-host.org/?remote=<TOKEN>` — the `?remote=` URL param pre-arms the bridge at boot. Alternatively press **Ctrl+Shift+F9** in the running game and paste the token into the on-canvas prompt. A "REMOTE ACTIVE" badge appears once the encrypted wss hello authenticates.

**Token:** in `tools/remote-bridge/.token` (also the `REMOTE_BRIDGE_TOKEN` env on the relay container). As of 2026-07-15: `<redacted-token>` — it may rotate, so read `.token` rather than trusting this. Secret; git-ignored; never commit.

**Relay:** docker container `voxiverse-relay` (node:22-slim), CMD `node relay.mjs --host 0.0.0.0 --port 8090 --results /app/results`, on `haproxy-net`, NOT host-published. Reachable ONLY via the deployed nginx route `location = /remote { proxy_pass http://voxiverse-relay:8090; }` (`docker/server/voxiverse.conf.template`). Health check: `curl -sS -o /dev/null -w "%{http_code}" https://voxiverse.game-host.org/remote` → **426 Upgrade Required** = route wired + relay up (404 = broken). `docker logs voxiverse-relay --tail 5` shows "Waiting for the game to dial in."

**Where telemetry lands (agent reads here):** `tools/remote-bridge/results/telemetry.jsonl` — append-only, ~4 samples/s, rolls to `.1` at 32 MB. Plus `results/frame-latest.jpg` + `results/frames/` (60-frame ring). Files are written as **root** by the container, but `results/` is USER-owned, so you can `mv`/archive files (rename needs dir-write, not file-ownership). Client: `godot/src/net/remote_bridge.gd` (`DEFAULT_URL wss://voxiverse.game-host.org/remote`), activator `godot/src/net/remote_bridge_activator.gd`.

**Clean session:** archive/rename the existing `results/telemetry.jsonl` BEFORE playing (relay recreates a fresh one on the next dial-in); the pre-fix 482-sample baseline is at `results/baseline-2026-07-14-prefix/telemetry.jsonl`.

**Gotcha:** the deployed build must have `FACETED+FP_M1_POOL+FP_M2_LOD` baked ON (the sed-at-export pattern; source keeps them `false`, only the exported PCK carries them ON) or the FP-M2 LOD/pool telemetry fields stay zero.

Related: [[voxiverse-remote-bridge]], [[voxiverse-web-time-process-invalid]], [[voxiverse-faceted-planet]].
