# COSMOS SPACE-FLY — self-test flight/navigation control

**Branch:** `feat/voxiverse-spacefly` · **Status:** landed, flag-gated, OFF byte-identical (FLAT 6042/0)

## Why

The orchestrator (headless/remote — no human at the browser) must be able to **fly and self-verify
every new space mechanic**: take off, reach orbit, run orbital maneuvers (coast / station-keeping),
transfer toward the Moon (SOI swap), land, and walk. Until now the space-nav verbs (`F` dev-nav /
`O` orbit-coast / `G` geostationary / `R` detach / WASD / `Q`-`E` roll / thrust) were **keyboard-only**
(`player.gd`, behind `SN_DEVNAV` + the `ORBIT_*` flags), and the remote-control channel exposed only
ground locomotion (`move`/`turn`/`look`/`jump`/…). This work exposes the **full space-nav command set as
injectable commands** and adds **two scriptable self-test harnesses** + the **telemetry to verify each
mechanic**.

## The two paths (use both)

| Path | Where it runs | When to use |
|---|---|---|
| **Headless mission gate** — `godot/src/tools/verify_spacefly.gd` | native headless, **any build, today** | Deterministic per-mechanic proof (orbit sustained / coast velocity / station-keep / de-orbit brake / SOI swap / Moon feel). Flag-independent (drives the same f64 kernels the wired player does). Run it before/without a live session. |
| **Live scripted flight** — `tools/remote-bridge/flight.mjs` + `flights/*.json` | real-GPU browser session via the relay | Exercises the SAME mechanics through the real wired player + renderer, self-verified from the streamed telemetry. Needs a flag-flipped build **and** `CONTROL_ENABLED` (see security). |

The headless gate is the workhorse for autonomous self-testing (no browser, GPU, relay, or human). The
live harness is for validating the wired loop + visuals on a real GPU when that build is available.

## What was added

### 1. Player actuators (`godot/src/player/player.gd`)
New `remote_*` methods, each routing through the **exact gated space-nav path** a human keystroke takes
(no new flight math, no parallel state). All are safe no-ops when their gates are off:
- `remote_set_dev_nav(on)` — `F`, idempotent (guarded by `SN_DEVNAV`).
- `remote_nav_verb("orbit"|"geostation"|"detach")` — `O`/`G`/`R` (guarded exactly as the key handler).
- `remote_set_thrust(wish, run)` / `remote_stop_thrust()` — the WASD+Space/Ctrl held-input seam
  (`remote_input`/`remote_run`/`remote_drive`, consumed by the player's own `_move`/dev-flight/coast).
- `remote_set_roll(rate)` — the `Q`/`E` roll seam (`remote_roll_rate`, OR'd into `_attitude_tick`'s
  `ATT_SPACE` roll poll).
- `space_telemetry()` — additive, guarded self-verification telemetry (below). Returns `{}` when the nav
  machine is off → **byte-identical** stream with the flags off.

### 2. Executor ops (`godot/src/net/remote_control.gd`)
New ops behind the existing `CONTROL_ENABLED` gate: `dev_nav`, `nav`, `thrust`, `roll`. `dev_nav`/`nav`
resolve synchronously; `thrust`/`roll` are **timed held-input steps** — arm the seam for `seconds`, then
release it (via `_zero_intent`) at the deadline. Rover-side caps re-validated in
`remote_bridge.gd::_validate_cmd` (`MAX_HOLD_S = 120`, verb whitelist, finite dx/dy/dz).

### 3. Relay (`tools/remote-bridge/relay.mjs`)
The four ops added to `OP_WHITELIST` + `validateStep` (mirror caps). The relay still only **routes** — it
authors nothing and enforces the same consent/token gate.

### 4. Telemetry (self-verification fields)
`space_telemetry()` streams alongside the existing `nav_telemetry` (`nav_mode`, `v_bci`): `alt`, `v_circ`,
`orbit_r`, `body`, `dev_nav`, `coasting`, `flying`, `on_ground`, `att`. These are exactly what a scripted
flight asserts — orbit sustained (`orbit_r` spread), coast velocity (`v_bci` vs `v_circ`), SOI body
(`body`), landing (`on_ground` + `nav_mode == planetary`), Moon walk (`body == moon`).

## Command set (the injectable verbs)

```jsonc
{ "op": "dev_nav", "on": true }                                   // F — dev-nav on/off
{ "op": "nav", "verb": "orbit" }                                  // O — free-coast (also "geostation"=G, "detach"=R)
{ "op": "thrust", "dx": 0, "dy": 1, "dz": -1, "seconds": 25, "gait": "run" }  // WASD + Space/Ctrl, held
{ "op": "roll", "dir": "left", "seconds": 3 }                     // Q/E, held
// plus the existing surface verbs: move / turn / look / wait / jump / screenshot / set_fly / stop / …
```
`dx` = strafe, `dy` = vertical (Space/Ctrl), `dz` = forward (−Z, like WASD). In dev-nav the `look` yaw
already steers the orbit-plane heading (the O coast seeds along the body yaw, pitch stripped), so
`turn`/`look` suffice for aiming; `roll` is attitude polish under `ORBIT_ATTITUDE`.

## Security — the gate is preserved, not weakened

The injection path is **unchanged in trust**. Every new op rides the mission-control channel's audited
gate (docs `COSMOS-REMOTE-CONTROL-DESIGN.md` §5/§6): commands come **only** from a host-written
`control/outbox/` file, forwarded **only** to a socket that is token-authed **and** has a human-armed
grant **and** proves the control secret. `RemoteBridge.CONTROL_ENABLED` stays `false` (the shipped
default) — with it off the executor never exists, the new ops are dead code, and the telemetry additions
return `{}`. **OFF is byte-identical** (FLAT `verify_feature` = 6042/0). Do **not** flip `CONTROL_ENABLED`
without the §6 security review + `/steelman` + user sign-off; the live harness runs against a dev build
that flips it, not the public site.

## Maneuver targeting (open)

The current verbs give held thrust + coast + station-keep, not a **closed-loop burn-to-target-orbit**.
Precise transfers (a Hohmann to a target apoapsis, an Earth→Moon injection) need a maneuver planner —
worth Fable's design reasoning. The **SOI swap + re-expression** itself is proven deterministically by
`verify_spacefly.gd` gate F; the live `earth-moon-transfer.json` is a plumbing template pending that
planner.

## How the orchestrator invokes it

```bash
# Headless per-mechanic proof (any build, no browser):
docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
    --script res://src/tools/verify_spacefly.gd 2>/dev/null | grep VERIFY     # 27/0

# Live scripted flight (dev build with the space-nav flags + CONTROL_ENABLED, relay running, a
# ?remote=<token> session granted control):
cd tools/remote-bridge
node flight.mjs --list                          # the canned flights
node flight.mjs flights/ascent-to-orbit.json    # fly + self-verify from telemetry → exit 0/1
```
Canned flights: `ascent-to-orbit`, `o-coast-hold`, `deorbit-land`, `earth-moon-transfer` (template).
