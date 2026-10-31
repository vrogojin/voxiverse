---
name: voxiverse-deploy-cheats-pipeline
description: How live A/B builds are deployed to voxiverse.game-host.org — deploy_cheats.sh (lives ONLY in scratchpad, NOT git) seds ~217 CS_FLAGS + env CLITE_FLAGS ON → export-web → deploy.sh --no-build → git-revert → curl-verify; GDScript-only flags = NO engine rebuild
metadata:
  node_type: memory
  type: reference
---

The live-A/B deploy pipeline (recovered 2026-08-30). Script: **`<scratchpad>/deploy_cheats.sh`** (executable, ~7.7KB;
scratchpad = /tmp/claude-1000/-home-USER-voxiverse/<session>/scratchpad). It is **NOT in git** — it lives only in
the session scratchpad, so it can be lost between sessions; the flag list + mechanism below are the source of truth to
recreate it. Runs FROM this worktree (`.claude/worktrees/deploy-cheats`, toolchain symlinked). GDScript+shell only ⇒
**no engine rebuild** (export+deploy is minutes, not the ~24min build).

5 steps: (1) `git checkout -- cube_sphere.gd remote_bridge.gd` then `sed -i 's/^\(const NAME := \)false/\1true/'`
for every flag in `CS_FLAGS` (a ~217-name string in the script) + append `${CLITE_FLAGS:-}` env, + flip
`CONTROL_ENABLED := true` in remote_bridge.gd (needed for dev cheats: set_time, injected flight). Then a hard
verify loop aborts if any flag `!= true` or if the must-stay-OFF set (FP_RADIAL_DATUM FP_CLOUDS FP_PRECIP FP_STORMS
FP_TIER_DEPTH_BIAS) isn't false. (2) `scripts/export-web.sh` (branded shell; guards: index.html must contain
VOXIVERSE_BOOT_SPLASH_MARKER + engine.startGame + "Starting engine" or ABORT). (3) `scripts/deploy.sh --no-build`
(containerize build/web, HAProxy self-register, LE TLS, HTTP-200+COOP/COEP verify). (4) `git checkout --` revert
BOTH files (worktree stays byte-off/clean). (5) curl live verify: HTTP/ + cross-origin-*-policy headers + marker
count + index.wasm last-modified. Every failure path reverts the two files first.

KEY POINTS: source stays default-false (byte-off) — flags are ON only in the transient exported .pck, reverted
immediately. The ~217 `CS_FLAGS` = the cumulative shipped-ON cheats set (FACETED + all the FP_* wins). New flag
FAMILIES are added ON per-A/B via the **`CLITE_FLAGS` env var** (append at invoke: `CLITE_FLAGS="FP_X FP_Y"
./deploy_cheats.sh`) so arms toggle without editing the script; the de-orbit PR#83 stack (FP_SHELL_STAGE_REEMIT
FP_SHELL_PREWARM_DESCENT FP_SHELL_SECTOR_FINE FP_FARRING_EMIT_ACCUM FP_SV2_SHELL_YIELD FP_STRUCT_NEAR_HOLD
FP_STRUCT_BAKE_STAGE) ships this way — they're merged-to-main consts (default false) NOT in CS_FLAGS. An A/B arm =
one deploy with a chosen flag set → user reloads browser → walk/fall → relay telemetry.jsonl. Relay token lives in
tools/remote-bridge/.token; worst_ms (window-worst) is the rate-robust metric. See [[voxiverse-remote-bridge]]
[[voxiverse-deorbit-shell-reemit]] [[voxiverse-ground-walk-perf]].

CRITICAL TRAP (bit hard 2026-08-30): step 1 + every abort/success path run `git checkout -- cube_sphere.gd
remote_bridge.gd` to strip the flag-flip sed afterward. This WIPES any UNCOMMITTED changes to those two files.
So ANY new GDScript feature that adds consts to cube_sphere.gd or emission to remote_bridge.gd MUST BE COMMITTED
before the first deploy — else the deploy silently reverts it (the sed then fails "NOT SET: FP_X" → ABORT, and any
sibling file like module_world.gd that references the now-undefined const is left DANGLING → game crashes on load).
The gen-convoy Build #1 hit exactly this: ConvoyCpp's uncommitted FP_GEN_*/wf_alloc_* glue in CS+RB was wiped on the
first arm-1 deploy while module_world.gd's forwarding survived. FIX = commit the feature's CS/RB edits first; the
checkout then reverts to the COMMITTED (flags-default) version, not to a wiped one. (Same root as the note in
[[voxiverse-fallthrough-loc-bug]].) Also: scripts/build.sh (OUTER wrapper) must forward any new build knob into its
`docker run -e` list — versions.env + build-engine.sh alone are inner-only; WEB_ALLOC_PROBE needed `-e WEB_ALLOC_PROBE`
added there or the container defaults it off (same class as [[voxiverse-mimalloc-fit-build]] baked-knob trap).
