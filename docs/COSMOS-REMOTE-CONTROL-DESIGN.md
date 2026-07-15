# COSMOS Remote-Control Channel — Phase 2 of the remote-play bridge ("Houston → Mars rover")

**Status: DESIGN — not implemented.** Companion to the shipped Phase-1 observe-only bridge
(`tools/remote-bridge/README.md`). This document specifies the CONTROL feedback channel: a Claude
agent on our host ("mission control") uplinks a **timed sequence of control instructions** to the
running browser game (the "rover"), the rover executes them with closed-loop verification, and the
agent reads back correlated telemetry + screenshots. The loop is deliberately **half-duplex and
latency-tolerant** — read telemetry → author a sequence → uplink → wait → read results → repeat —
not realtime full-duplex teleoperation.

Everything here is **flag-gated and byte-identical when off** (project convention): with the
control flag off, the game binary behaves exactly as today's Phase 1, and Phase 1 with no token
behaves exactly as a normal visit.

---

## 0. What exists today (investigated baseline)

### 0.1 The observe-only pipe

| Piece | Where | Load-bearing facts |
|---|---|---|
| Relay | `tools/remote-bridge/relay.mjs` | WS server behind nginx; token auth on first-message `hello` with timing-safe compare (`relay.mjs:77-83`, `221`); app-level `{"type":"auth_ok"}` ack (`relay.mjs:240`) that the comment already earmarks as "the handshake Phase-2 controls will ride" (`relay.mjs:239`); authed/pending pool split + per-IP pre-auth rate limit (`relay.mjs:136-183`); per-conn 60 msg/s cap (`relay.mjs:54`, `199-206`); **"NEVER sends anything back that the game acts on"** (`relay.mjs:6`) — the one thing Phase 2 must change, carefully. Authed text frames → `results/remote/telemetry.jsonl`; binary `[0x01][jpeg]` → `frame-latest.jpg` + ring (`relay.mjs:245-260`). |
| Game bridge | `godot/src/net/remote_bridge.gd` | Dial-OUT `wss://voxiverse.game-host.org/remote` (`remote_bridge.gd:41`); created only on activation, dead in normal play (`remote_bridge.gd:8-13`); **SEND-ONLY** — every inbound packet except the single `auth_ok` is drained and discarded (`remote_bridge.gd:23-25`, `238-252`); `PHASE_STATUS := "observing"` const explicitly staged for the Phase-2 badge upgrade (`remote_bridge.gd:43-45`); telemetry ~4/s assembled in `_send_telemetry()` + `_merge_rich_state()` with `pos [x,y,z]`, `facet`, `facet_neighbours`, `stream_credit`, `lod` (`remote_bridge.gd:295-362`); frames ~2/s via `_maybe_capture_frame()`/`_capture_frame_async()` (`remote_bridge.gd:367-410`). |
| Activator / trust UI | `godot/src/net/remote_bridge_activator.gd` | Ctrl+Shift+F9 chord (`remote_bridge_activator.gd:29`, `57-63`); on-canvas **token-only** prompt (never a URL — `remote_bridge_activator.gd:150-211`); always-visible LIVE badge driven by real `link_state` (`remote_bridge_activator.gd:113-141`); "PHASE 2 READINESS: control slots into this SAME toggle … badge upgrades to 'observing + CONTROLLING'" (`remote_bridge_activator.gd:24-25`). Wired in `godot/src/main.gd:81-84`. |
| Transport | `docker/server/voxiverse.conf.template:87-97` | `location = /remote` WS-upgrade proxy to the private `voxiverse-relay` container on `haproxy-net`; relay never host-published; no `add_header` so game-page COOP/COEP untouched. **No transport change is needed for Phase 2** — a WS is already bidirectional; only the endpoints' policies change. |

### 0.2 The rover's actuators — the player controller

`godot/src/player/player.gd` (`Player extends CharacterBody3D`):

- **Movement is read directly from the keyboard each physics tick** — `_move()` polls
  `Input.is_key_pressed(KEY_W/S/A/D/SHIFT/SPACE/CTRL)` (`player.gd:245-268`). There is **no
  InputMap action layer**, so command injection cannot ride `Input.action_press()`; it needs a
  small explicit intent seam in `_move()` (§4.2).
- **Frame & units.** The player's local frame is the **active facet's flat chart**: gravity is
  always local **−Y** (`player.gd:64-66` — "'down' is always −Y in window space"), yaw is
  `rotation.y` (mouse-look: `rotate_y(-relative.x * sens)`, `player.gd:169` — so **turn left =
  +yaw**), pitch is `_pitch` clamped to ±1.5 rad (`player.gd:170`), and **forward =
  `-transform.basis.z`** (W maps to `input.z -= 1`, `player.gd:248`). One **block = 1.0 world
  unit** (a cell cube occupies `[c, c+1)` — `player.gd:475-478`).
- **Speeds:** walk 5.5, run 9.5, fly 16.0 blocks/s; `jump_velocity` 8.0; gravity 22.0
  (`player.gd:17-21`) — so "walk 10.5 blocks" ≈ 1.9 s of locomotion.
- **Locomotion is analytic, not trimesh:** per-axis `world.blocked()` wall tests can zero an axis
  of the intended move (`player.gd:282-293`) — this is exactly the "obstruction" a closed-loop
  executor must detect; floor via `world.floor_under()` (`player.gd:333`); jumping only fires when
  grounded (`player.gd:357-361`).
- **Fly mode exists**: `flying` toggled by KEY_F, capsule disabled while flying, Space/Ctrl for
  vertical (`player.gd:197-204`, `258-266`). `set_fly` is therefore a trivial actuator.
- **Position is NOT a stable integral.** Three things rewrite `global_position`/`rotation.y`
  outside locomotion, all inside `_physics_process` (`player.gd:206-241`): floating-origin
  re-anchor (`maybe_reanchor` shift, `player.gd:215-217`), home-face flip, and **facet crossing**
  (`maybe_flip_home_face`/`maybe_cross_facet` → `apply_reframe(new_pos, yaw_delta)`,
  `player.gd:136-139`, `228-231`; WM side `world_manager.gd:1410`). ⇒ "walked 10.5 blocks" must be
  measured by **per-tick displacement integration**, never end-pos − start-pos (§4.4), and turn
  targets must be **remaining-degrees counters**, never absolute yaw targets.
- **`frozen` gate** (`player.gd:49`) blocks all input+physics — already used by the shader prewarm
  and by the activator's token prompt (`remote_bridge_activator.gd:156`).
- Telemetry `pos`+`facet` (~4/s, `remote_bridge.gd:349-353`) is how mission control independently
  confirms the rover's claims.

### 0.3 The consent gate this design must respect (#113)

Phase 2 is **gated on not letting control ride the observe token**: the shared Phase-1 URL token
grants OBSERVE only. Control requires a **separate, per-session, short-TTL grant** with **explicit
in-game re-consent** when the badge upgrades to CONTROLLING (task #113). §6 designs that grant as
an in-game human consent handshake (the human at the keyboard *is* the second factor), plus TTL,
caps, and instant override.

---

## 1. Command protocol — the uplink schema

One uplink unit is a **command sequence**: a JSON document, authored by the agent as a file on the
host (§5), forwarded verbatim by the relay to the consented game socket as a single WS text frame.

```jsonc
{
  "type": "cmd_seq",
  "seq": "walkabout-007",          // agent-chosen unique id (correlates ALL results)
  "issued": 1784500000.0,          // agent wall clock (unix s) — staleness check, see caps
  "on_fail": "abort",              // "abort" (default) | "continue": policy when a step fails
  "steps": [
    { "id": 1,  "op": "move",       "blocks": 10.5, "heading": "forward", "gait": "walk" },
    { "id": 2,  "op": "wait",       "seconds": 5.0 },
    { "id": 3,  "op": "turn",       "degrees": 25.0, "dir": "left" },
    { "id": 4,  "op": "move",       "blocks": 4.0,  "heading": "forward" },
    { "id": 5,  "op": "turn",       "degrees": 100.0, "dir": "right" },
    { "id": 6,  "op": "wait",       "seconds": 3.0 },
    { "id": 7,  "op": "screenshot", "label": "ridge-approach" },
    { "id": 8,  "op": "jump" },
    { "id": 9,  "op": "move",       "blocks": 20.0, "heading": "forward" },
    { "id": 10, "op": "screenshot", "label": "after-run" },
    { "id": 11, "op": "set_fly",    "on": true },
    { "id": 12, "op": "look",       "pitch_deg": -30.0 }
  ]
}
```

### 1.1 Ops (v1 whitelist — locomotion + observation ONLY)

| op | params | semantics |
|---|---|---|
| `move` | `blocks` (float > 0), `heading` ∈ `forward\|back\|left\|right` (default `forward`), `gait` ∈ `walk\|run` (default `walk`) | Closed-loop locomotion: drive the normal movement pipeline in the given **body-local** direction until the **integrated along-heading displacement** reaches `blocks` (±tolerance), or blocked/timeout (§4). While flying, `move` flies horizontally at fly speed. |
| `turn` | `degrees` (float > 0), `dir` ∈ `left\|right` | Yaw by the given angle **relative to current heading**. `left` = +yaw (counter-clockwise from above — matches mouse-look sign, `player.gd:169`). Rate-limited easing, not a snap (§4.5). |
| `look` | `pitch_deg` ∈ [−85, 85] (absolute) and/or `yaw_deg` (relative, signed, +=left) | Camera aim. `pitch_deg` is absolute (horizon = 0, up = +); `yaw_deg` is a signed relative turn (sugar for `turn`). |
| `wait` | `seconds` (0 < s ≤ 60) | Idle; telemetry keeps flowing — this is how the agent watches settling behaviour. |
| `jump` | — | One grounded jump: latch a jump request consumed the first tick the floor check allows it (`player.gd:357-361`); completes on lift-off. No-op + `ok` with note `"flying"` while in fly mode. |
| `screenshot` | `label` (≤ 40 chars, `[a-z0-9-]`) | On-demand full-quality canvas capture, uplinked as a **tagged, correlated** binary frame (§3.3) distinct from the ambient ~2/s stream. |
| `set_fly` | `on` (bool) | Enter/leave fly mode — exactly the KEY_F path (`player.gd:197-204`), including capsule disable. |
| `break` | `target` ∈ `aim\|{dx,dy,dz}` | Break/mine the aimed (or player-relative offset) block via the SAME `WorldManager` break + `_collapse_unsupported` pipeline a human uses (reach + gameplay rules enforced). **Added per resolved D5 (full agency).** |
| `place` | `block` (id/name), `target` ∈ `aim\|{dx,dy,dz}` | Place the selected block via the human place pipeline (reach + rules enforced). **Added per D5.** |
| `select_slot` | `n` (hotbar index) | Select the active hotbar slot (the human `1`–`9` path). **Added per D5.** |
| `reload` | — | Reload the browser tab via `JavaScriptBridge.eval("location.reload()")` → re-fetch the freshly deployed build (deploy sends `cache-control: no-cache`, so the reload gets the new `wasm`/`pck`). The `?remote=<token>` URL param re-arms the observe bridge automatically; CONTROL re-arms **without** a human click ONLY when persistent unattended mode is active (§6.5). **Added 2026-07-15 for unattended deploy→reload→re-test loops.** |
| `stop` | — | Explicit sequence end / no-op step (useful as a labelled fence). |

**Scope (resolved D5 — FULL AGENCY):** v1 includes world mutation — `break`, `place`,
`select_slot` — in addition to locomotion + observation. Every mutation routes through the SAME
`WorldManager` break/place/collapse pipeline a human uses (reach, gameplay rules, edit-overlay,
NEVER-OOM all enforced) — no new mutation path, no call-by-name. Still EXCLUDED: raw key/mouse
synthesis and anything reaching outside game actions. The executor dispatches through a **closed op
table** — an unknown `op` fails the step (with `on_fail:"abort"`, the sequence) with status
`bad_op`; it is never interpreted loosely. The consent modal MUST enumerate this full power set in
plain language (§6).

### 1.2 Units and frame (normative)

- **blocks** — 1.0 world unit (one voxel cell edge) in the player's **current active-facet local
  frame**. Distance is measured as horizontal (XZ) displacement projected on the heading direction
  *sampled at step start* (re-sampled across a facet reframe by the same `yaw_delta` the reframe
  applies — §4.4). Vertical motion never counts toward `move` distance.
- **degrees** — body yaw about local +Y. Positive `left`. Facet crossings add their dihedral
  `yaw_delta` to *both* current and target heading (remaining-degrees counter, §4.5), so a `turn`
  spanning a seam still turns exactly the commanded amount **relative to the terrain**.
- **seconds** — rover wall clock (`Time.get_ticks_msec()` deltas).

### 1.3 Caps (validated at BOTH relay and rover; violation = whole sequence rejected)

| Cap | Value (const, tunable) | Why |
|---|---|---|
| steps per sequence | ≤ 64 | bound queue memory + a single consent's blast radius |
| `move.blocks` per step | ≤ 128 | bound a runaway walk; long traverses = several sequences (that's the rover model) |
| total commanded duration (Σ expected step time) | ≤ 180 s | the watchdog's outer bound; one sequence can't own the session |
| sequence JSON size | ≤ 16 KiB | relay `maxPayload` already 2 MiB; commands are tiny |
| sequences in flight | exactly 1 | half-duplex by construction; a new `cmd_seq` while one runs is rejected (`busy`) unless it carries `"preempt": true` (open decision D3) |
| `issued` staleness | > 120 s old = rejected (`stale`) | a delayed/re-sent file must not fire long after authoring |

---

## 2. The closed control loop (agent's contract)

```
 host (mission control)                       relay                          rover (browser)
────────────────────────                ────────────────                ──────────────────────
read results/remote/telemetry.jsonl
read results/remote/frame-latest.jpg
        │
write control/outbox/walkabout-007.json ──► validate, forward ─────────► {"type":"cmd_seq",...}
        │                               (only to the CONSENTED socket)          │
        │                                                             ◄── {"type":"cmd_ack","seq"}
        │                               append events.jsonl ◄──────────  per step:
        │                                                                 {"type":"step_start"}
        │                                                                 …executes, verifies…
        │                                                                 {"type":"step_done", pos/yaw/…}
        │                                                                 [0x02-tagged shot frames]
        │                                                             ◄── {"type":"seq_done","status"}
poll control/results/walkabout-007/  ◄── writes ack/events/shots/done
  ├─ ack.json        (uplink accepted by the rover)
  ├─ events.jsonl    (step_start / step_done stream, _rx-stamped)
  ├─ shot-007-ridge-approach.jpg
  └─ done.json       (terminal status for the whole sequence)
        │
compare expected vs actual (Δpos, Δyaw, facet) → author next sequence → repeat
```

### 2.1 Downlink event schema (rover → relay, ordinary WS text frames)

Every event carries `seq` and (where applicable) `id`, so correlation is `(seq, id)` end-to-end:

```jsonc
{ "type": "cmd_ack",   "seq": "walkabout-007", "steps": 12, "t": 1784500001.2 }
{ "type": "cmd_nack",  "seq": "walkabout-007", "reason": "busy|bad_json|caps|stale|no_consent" }
{ "type": "step_start","seq": "walkabout-007", "id": 1, "op": "move",
  "pos": [12.34, 8.00, -71.20], "yaw_deg": 41.3, "facet": 17, "t": … }
{ "type": "step_done", "seq": "walkabout-007", "id": 1, "op": "move",
  "status": "ok",                       // ok | blocked | timeout | aborted | user_override | link_lost | bad_op
  "moved_blocks": 10.46,                // integrated along-heading displacement (§4.4)
  "turned_deg": 0.0,
  "pos": [4.11, 8.00, -63.05], "yaw_deg": 41.3, "facet": 17,
  "reframes": 0,                        // facet crossings during the step (explains pos discontinuities)
  "dur_s": 1.94, "t": … }
{ "type": "seq_done",  "seq": "walkabout-007",
  "status": "ok | failed | aborted | user_override | link_lost",
  "completed": 12, "t": … }
```

**Verifiability contract:** for a `move` step, `status:"ok"` means
`|moved_blocks − blocks| ≤ MOVE_TOL` (§4.4). The agent can *independently* re-derive this from the
ambient 4/s telemetry (`pos` samples bracketing `step_start.t … step_done.t`, minding `reframes`),
and from `step_done.pos − step_start.pos` when `reframes == 0`. For `turn`, `turned_deg` vs
`degrees` with `TURN_TOL` (0.5°). A rover that lies about `moved_blocks` is caught by the
telemetry it cannot avoid streaming — self-report and observation are separate channels.

### 2.2 Relay-side result layout (all under `tools/remote-bridge/`, gitignored)

```
control/
  outbox/          ← agent WRITES <seq>.json here (the ONLY command source, §5.1)
  sent/            ← relay moves a forwarded file here (atomic rename; audit trail)
  rejected/        ← relay moves an invalid file here + writes <seq>.reject.txt (reason)
  results/<seq>/   ← ack.json, events.jsonl, done.json, shot-<id>-<label>.jpg
  audit.log        ← append-only: every forward, nack, consent grant/expiry, override
results/remote/    ← unchanged Phase-1 sinks (telemetry.jsonl, frame-latest.jpg, frames/)
```

Control events are **also** appended to `telemetry.jsonl` (they arrive on the same socket and are
JSON text — zero-cost), but `control/results/<seq>/` is the correlated, per-sequence view the
agent actually consumes.

---

## 3. Wire protocol changes (relay ↔ game)

### 3.1 New message types (all JSON text frames, `type`-discriminated)

| Direction | Types |
|---|---|
| relay → game | `auth_ok` (existing), `control_offer` (§6.2, carries the relay-minted `grant_nonce` — F1), `cmd_seq`, `control_ping` (5 s heartbeat while control is granted), `control_revoke` (relay ended the grant — ping timeout / echoed revoke) |
| game → relay | telemetry (existing), `control_state` (consent granted/denied/revoked/expired — `granted` echoes the offer's `grant_nonce`, F1 — drives relay gating + audit), `cmd_ack`/`cmd_nack`, `step_start`/`step_done`, `seq_done`, `control_pong` |

The game's inbound drain (`remote_bridge.gd:238-252`) grows from "only `auth_ok`" to a **strict
type-whitelist dispatch** (`auth_ok`, `control_offer`, `cmd_seq`, `control_ping`, `control_revoke`);
anything else stays drained-and-discarded. `control_revoke` (F2) makes the client drop its grant +
free the executor + revert the badge the instant the relay revokes, instead of lying until the
~16 s local ping timeout. When the control flag is OFF (compile-time const, §7 P2), the dispatch
table simply doesn't contain the new types — byte-identical Phase-1 behaviour.

### 3.2 Relay policy inversion, stated precisely

The Phase-1 safety property "the relay NEVER sends anything back that the game acts on"
(`relay.mjs:6`) is **replaced**, not weakened, by:

> The relay forwards to a game socket **only** bytes that originate from a **local file the host
> agent wrote into `control/outbox/`**, and only to a socket that is (a) token-authed, (b)
> **control-consented** by the human in the game (§6), and (c) within its consent TTL. **Nothing a
> WS client sends is ever forwarded to any other socket or reflected back** — game-originated
> messages are still record-only. The relay itself never authors commands.

Concretely: `relay.mjs` gains an outbox poller (500 ms `readdir` — `fs.watch` is unreliable on
bind mounts; polling is fine at this cadence), JSON + caps validation (§1.3), and a per-socket
`control` state machine (`none → offered → granted(expiry) → …`). The 60 msg/s per-conn inbound
cap (`relay.mjs:54`) already covers the added event traffic (a step emits ~2 events).

### 3.3 Correlated screenshots (new binary tag)

Ambient frames keep tag `0x01`. A commanded `screenshot` uplinks:

```
[0x02][u16 header_len BE][header JSON: {"seq","id","label","t"}][jpeg bytes]
```

Relay writes it to `control/results/<seq>/shot-<id>-<label>.jpg` (and refreshes
`frame-latest.jpg` too — it is, after all, the latest frame). Same 2 MiB `maxPayload`, same JPEG
magic check. Commanded shots bypass the ~2/s ambient throttle but respect the outbound
backpressure guard (`remote_bridge.gd:61`, `372-373`) — under backpressure the step **retries
next frame** (up to its watchdog) rather than silently dropping, since the agent explicitly asked
for the pixels; quality/size stays the Phase-1 960 px / q0.6 default (open decision D4).

---

## 4. Execution semantics on the rover

### 4.1 New node: `RemoteControlExecutor` (`godot/src/net/remote_control.gd`)

Created by `RemoteBridge` **only after** consent is granted (§6); freed on revoke/expiry/link
loss. Holds the step queue, the per-step state machine, the watchdog, and the player intent seam.
It never exists in normal play, in observe-only sessions, or when the control flag is off — the
same "dead in normal play" discipline as `RemoteBridge` itself (`remote_bridge.gd:8-13`).

### 4.2 The player intent seam (the ONLY player.gd change)

`_move()` polls the keyboard directly (`player.gd:245-268`), so the executor injects at the same
level a human does — **intent, not teleport**:

```gdscript
# player.gd — remote-drive seam (flag-gated; all zero/false in normal play)
var remote_drive := false          # executor sets true only while a move/turn step runs
var remote_input := Vector3.ZERO   # body-local wish, same shape as the WASD `input` vector
var remote_run := false
var remote_jump := false           # one-shot latch, consumed by the grounded-jump branch
var remote_yaw_rate := 0.0         # rad/s applied in _physics_process while turning
```

In `_move()`: `if remote_drive: input = remote_input; running = remote_run` replaces the key
polls for that tick (mouse-look, Esc, hotbar untouched). The commanded motion then flows through
the **identical** analytic wall/floor/ceiling pipeline (`player.gd:282-333`) — the rover can be
blocked, bonk ceilings, shove wood, and fall exactly like a keyboard player. This is what makes
"walk 10.5 blocks" honest: it is real locomotion at walk speed, verified by measurement, never a
`global_position` write.

**Scope guarantee:** the executor's entire actuator surface is these five fields plus
`flying`/`set_fly` and the screenshot request. It calls no other Player/World method.

### 4.3 Step state machine

```
IDLE ── cmd_seq accepted ──► RUN(step i) ──ok──► RUN(step i+1) … ──► DONE(ok)
                              │  │  │
                              │  │  └─ watchdog fired ───────► step timeout → on_fail policy
                              │  └─ progress stall (blocked) ─► step blocked → on_fail policy
                              └─ local input / link loss / revoke ─► ABORT (halt intent, drain queue,
                                                                     emit seq_done immediately)
```

- Executor ticks from `Player._physics_process` (player calls
  `remote_exec.physics_tick(delta, tick_move_delta, reframe_yaw_delta)` right after `_move()` and
  **before** the reanchor/flip/cross corrections, `player.gd:210-231`) — so measurement sees pure
  locomotion displacement, uncontaminated by origin shifts.
- **On any terminal event the intent fields are zeroed first** (rover stops moving within one
  physics tick), then events are emitted on a best-effort basis.

### 4.4 `move` — closed-loop displacement, robust to reframes

- At `step_start`: capture heading unit vector `h = -player.transform.basis.z` (or ±basis.x for
  strafe headings), zero the accumulator.
- Each tick: `acc += clampf(tick_move_delta.dot(h), 0.0, INF)` where `tick_move_delta` is that
  tick's `_move()` horizontal displacement (pre-reanchor, §4.3). Negative projections (rubber-band
  revert, slide-back) don't add.
- **Facet reframe during the step:** `apply_reframe` rotates velocity/heading by `yaw_delta`
  (`player.gd:136-139`); the executor rotates `h` by the same `yaw_delta` (forwarded via
  `physics_tick`) and increments `reframes`. The accumulator itself is frame-free (a scalar), so
  distance walked is continuous across seams; reanchor shifts never enter it at all.
- **Stop condition:** `acc ≥ blocks − v·dt/2` (half-tick anticipation) → zero intent, report
  `moved_blocks = acc` (one more tick of measurement drains). `MOVE_TOL = 0.15` blocks (walk
  covers ~0.09 blocks/tick @60 fps; 0.15 absorbs a slow frame).
- **Obstruction:** if `acc` gains < 0.05 blocks over a sliding 1.5 s while intent is nonzero →
  `status:"blocked"` (the analytic wall zeroed the axis, `player.gd:282-293`, or wood pinned us).
  Report `moved_blocks` so far; `on_fail` policy decides continue/abort.
- **Watchdog:** `timeout = blocks / speed(gait) * 3 + 2 s`, capped at 60 s → `status:"timeout"`.

### 4.5 `turn` / `look` — remaining-degrees easing

- Executor keeps `remaining_deg` (signed). Each tick applies
  `dyaw = sign * min(TURN_RATE·dt, |remaining|)` via `player.rotate_y(dyaw)` and decrements.
  `TURN_RATE = 120°/s`. Complete at `|remaining| ≤ 0.5°`; report `turned_deg`.
- A reframe's `yaw_delta` changes current yaw and target identically (both are heading-relative),
  so **`remaining_deg` is untouched by crossings** — the counter design makes seam-correctness
  free. Watchdog 10 s (can't realistically fire; belt-and-braces).
- `look.pitch_deg`: ease `_pitch` at the same rate to the absolute target (Player gains a tiny
  `remote_set_pitch(rad)` or the executor writes `_pitch`+camera via one setter — implementer's
  choice, same seam discipline).

### 4.6 `jump`, `wait`, `screenshot`, `set_fly`, `stop`

- `jump`: set `remote_jump = true`; the grounded branch (`player.gd:357-361`) consumes it exactly
  as `KEY_SPACE`; done when consumed (lift-off), watchdog 5 s (`timeout` if never grounded).
- `wait`: timer; telemetry flows; done.
- `screenshot`: request the tagged capture (§3.3); done when the frame is handed to the socket
  (or watchdog 10 s under sustained backpressure → `timeout`).
- `set_fly`: replicate the KEY_F branch (`player.gd:197-204`) including capsule disable + velocity
  zero; done next tick.
- `stop`: immediately terminal `ok`; queue continues (it is a fence, not an abort — aborts come
  from the human or `on_fail`).

### 4.7 Failure taxonomy (exhaustive)

| status | meaning | queue effect |
|---|---|---|
| `ok` | completed within tolerance | next step |
| `blocked` | progress stall (wall/wood/pit) | `on_fail` policy |
| `timeout` | watchdog fired | `on_fail` policy |
| `bad_op` | unknown/invalid step reached execution (defense-in-depth; normally caught at ack) | `on_fail` policy |
| `aborted` | earlier failure + `on_fail:"abort"` drained this step unrun | reported per remaining step in `seq_done.completed` count only (no per-step spam) |
| `user_override` | **any local input** (§6.4) | whole queue halts NOW |
| `link_lost` | WS left OPEN state, or 3 missed `control_ping`s | whole queue halts NOW |

---

## 5. Transport & relay changes

### 5.1 Command ingress = host filesystem ONLY

The agent uplinks by **writing a file** into `tools/remote-bridge/control/outbox/` (write to a
temp name, `rename` in — same atomicity idiom as `writeFrame`, `relay.mjs:107-110`). This is the
whole trust anchor on the host side: only a process with write access to that directory on our
host can command a rover. No WS client, no HTTP endpoint, no game socket can inject a command.
The relay: validate → forward to the consented socket → move to `sent/` (or `rejected/` + reason
file). Every action appends to `control/audit.log`.

### 5.2 Socket selection

`MAX_CONNS = 4` (`relay.mjs:49`) allows several authed sockets. Commands go **only** to the
socket whose control state is `granted` and unexpired. If none: the outbox file waits (up to its
`issued` staleness cap) and is then rejected `no_consent`.

**Grant authenticity (F1 — hardened 2026-07-15).** The observe token is a *shared* URL secret, so
without further binding a 2nd token-holding socket could forge/steal/oscillate the grant and inject
forged downlink results. Three relay-side rules close this:

1. **Relay-minted `grant_nonce`.** When the relay offers control it mints a cryptographically-random
   per-socket nonce (`node:crypto` `randomBytes`) and sends it in that socket's `control_offer`. A
   `control_state:granted` is honoured **only** if it echoes the exact nonce the relay minted for
   *that* socket (constant-time compare). A socket that auths and immediately claims control (no
   offer ⇒ no nonce) or echoes a wrong/guessed nonce is refused. The nonce is per-socket (delivered
   only on that socket's wss offer) and stays valid until the next offer re-mints it — so an
   unattended re-arm (§6.6, no fresh offer) can legitimately re-echo it, while a *cross-socket* forge
   still fails (each socket has a distinct nonce it cannot observe on another's link).
2. **No-supersede.** While one socket holds a valid grant, a second socket's `granted` is **rejected**
   (previously "most-recently-granted wins"). A standing grant can never be wrested away; it ends only
   by the owner's revoke/override, link loss, or ping timeout.
3. **Per-socket result tagging.** `cmd_ack`/`cmd_nack`/`step_*`/`seq_done` and `0x02` shot frames are
   accepted **only** from the socket that owns the in-flight sequence (the one the relay forwarded it
   to); a forged event from any other socket is dropped and audited (`result_forged`) — it never
   touches `control/results/<seq>/`.

**Residual (documented, out of F1 scope):** the relay cannot itself verify a *human* clicked Allow —
it trusts that `control_state:granted` came from a consented game (the human at the keyboard is the
game-side second factor, §6.1). So a token-holding attacker who wins the *first* grant race (before
any legit human consents) can receive the agent's commands; the human consent gate lives game-side,
and the shared-token limitation is what task #113 ultimately removes by not letting control ride the
observe token (a future per-session control credential). F1 bounds the damage: no result poisoning,
no stealing a standing grant, no grant without a real relay offer.

### 5.3 Game socket stays outbound-dial; auth model unchanged for observe

No listener is added anywhere in the game. The observe token, hello, `auth_ok`, pools, per-IP
limits — all unchanged. Control is a **second, in-band, human-granted layer on top** (§6), per
the #113 requirement that control never rides the observe token.

### 5.4 Fail-safe-to-stop on link loss

- **Rover:** while any step runs, if the WS is not OPEN → immediate ABORT (`link_lost`) — checked
  every tick, plus `control_ping` (relay, 5 s) / `control_pong`; 3 missed pings while granted →
  drop consent to `none` and free the executor. Reconnect after a drop re-enters at **observe**;
  control requires a fresh offer + consent.
- **Relay:** socket close → mark grant dead, fail any queued outbox files for it (`no_consent`),
  audit-log.

---

## 6. SECURITY + CONSENT (first-class, non-negotiable)

The threat model: this channel drives a real human's browser session on a public site. The design
answers with **(a)** a louder, separate, expiring consent; **(b)** an unmissable indicator;
**(c)** an always-armed instant human override; **(d)** a hard scope wall; **(e)** caps and
fail-safe-to-stop everywhere.

### 6.1 Control is a SEPARATE, louder consent than observe (#113)

The Phase-1 token only ever grants OBSERVE. The control grant is **created in-game by the human**:

1. Agent drops the first command file (or an explicit `control-request.json`) → relay sends
   `control_offer` to the authed socket.
2. The game shows a **modal consent dialog** (same canvas-layer machinery as the token prompt,
   `remote_bridge_activator.gd:150-211`, but visually distinct — red border, large type):

   > **MISSION CONTROL requests DRIVE access**
   > The remote agent will be able to: walk/turn/jump the player, toggle fly mode, aim the
   > camera, and take screenshots of the game canvas. It can NOT break/place blocks, read
   > anything outside the game, or keep control if you touch any key or the mouse.
   > Grant expires automatically after **15 minutes**.
   > `[ Deny ]` `[ Allow for 15 min ]`

3. Allow → game sends `control_state: granted` (+ a game-generated random `grant_id` echoed on
   every subsequent `cmd_ack`, binding results to this exact consent) → relay arms forwarding with
   `expiry = now + TTL`. Deny → `control_state: denied`; relay rejects pending outbox files.
4. **TTL expiry** (default 15 min — open decision D1): rover halts any running step
   (`link_lost`-equivalent status `expired` folded into `user_override` semantics: queue stops),
   frees the executor, badge drops back to *observing*, relay stops forwarding. Renewal = a fresh
   offer + a fresh human click. No silent renewals, ever.

The human at the keyboard is the second factor; there is deliberately **no second typed token**
(nothing to phish, nothing to leak in logs) — possession of the machine + explicit click is
strictly stronger, and it satisfies #113's "server-issued per-session short-TTL grant" via the
relay's `granted(expiry, grant_id)` state.

### 6.2 Persistent indicator

The existing badge (`remote_bridge_activator.gd:113-141`, layer 200, never hidden) upgrades via
the already-staged `PHASE_STATUS` seam (`remote_bridge.gd:43-45`):

- observe only: `● REMOTE ACTIVE — observing` (red, as today)
- control granted, idle: `● REMOTE CONTROL ACTIVE — any input takes over` (brighter red + slow pulse)
- executing: `● REMOTE DRIVING — step 3/12: move 10.5 ▸ any input takes over` (live step readout)

The "any input takes over" text is part of the indicator by design — the override affordance is
advertised at all times, not documented somewhere.

### 6.3 Scope wall

- Op table is a **closed whitelist** (§1.1); executor's actuator surface is the five intent
  fields + fly + screenshot (§4.2) — no `call()`-by-name, no JS eval, no reflection, no world
  mutation, no input synthesis outside the seam.
- Screenshots remain **viewport-only** (`get_viewport().get_texture().get_image()`,
  `remote_bridge.gd:26-27`) — never the screen, never other tabs.
- Relay forwards only outbox files (§5.1) — the public internet has no path to the command stream
  even with a stolen observe token.

### 6.4 Human OVERRIDE — instant, unconditional, zero-configuration

**Any** local player input while a step is running — any key press (except the badge's own
Ctrl+Shift+F9 which is a full revoke), any mouse motion/button — triggers, *in the same frame*:

1. zero all remote intent fields (movement stops this physics tick);
2. abort the queue; emit `step_done: user_override` + `seq_done: user_override`;
3. control drops to **granted-but-suspended**: the grant survives (TTL keeps ticking) but the
   relay is told (`control_state: suspended`) and will not forward the *next* sequence until the
   rover has been idle-of-local-input for 5 s (so a human actively playing is never fought for
   the controls);
4. the badge flashes `— YOU HAVE CONTROL` for 2 s.

Implementation: the executor observes `_unhandled_input`-level events via a high-priority hook
(the activator already demonstrates the event-driven pattern, `remote_bridge_activator.gd:55-63`)
plus a per-tick `Input.is_anything_pressed()`/mouse-velocity check as belt-and-braces — the
override must not depend on event delivery order. **Esc or the chord = full revoke**
(`control_state: revoked`, executor freed, back to observe; chord pressed again tears down the
whole bridge as today, `remote_bridge_activator.gd:66-72`).

### 6.5 Caps & audit (defense-in-depth summary)

Sequence/step caps (§1.3); one sequence in flight; consent TTL (§6.1); grant bound to one socket
+ `grant_id`; staleness cap on outbox files; relay `audit.log` of every forward/nack/grant/
override; all Phase-1 anti-DoS unchanged. Nothing in this design increases per-frame cost or
memory when off (NEVER-OOM: the executor's queue is ≤ 64 tiny dictionaries, freed with the node).

### 6.6 Persistent UNATTENDED mode (resolved 2026-07-15 — enables the `reload` op + walk-away loops)

To leave dev/test running headless, control must survive a `reload` (§1.1) — but a reload drops the
socket, which per D2 ends the grant, so normal per-session consent would demand a fresh human click
each cycle. Unattended mode resolves this with an EXPLICIT, LOUDER, one-time opt-in — never a silent
weakening of the human-second-factor model:

- **Distinct, louder consent.** A second modal beyond the per-session control grant: "Allow MISSION
  CONTROL to DRIVE **and RELOAD** this game **UNATTENDED**, persisting across reloads, until you
  revoke — it can move, build, MINE/BREAK, PLACE, and manage INVENTORY with no further prompts."
  Red-bordered, capability-enumerating (matches the resolved D5 full-agency scope), requires a
  deliberate click (not the default button).
- **Persistence (same-origin model — corrected F3 2026-07-15).** On opt-in the game stores an opaque
  per-grant `unattended_id` in `localStorage` under a non-reversible key (`sha256(observe token)` —
  NOT the secret). The id is CSPRNG-generated (browser `crypto.getRandomValues`, native `Crypto`) and
  bound to a hash of the observe token. After a `reload`, boot reads it and re-arms CONTROL
  automatically (no human click) IFF: the `?remote=<token>` matches (so the socket re-auths), the
  stored id is present **same-origin** (localStorage is origin-scoped — another site cannot read or
  plant it), and the mode has not been revoked. **The trust anchors are token-auth + the F1
  relay-minted grant_nonce + same-origin localStorage — NOT a relay-held unattended registry.** An
  earlier draft claimed the id "validates against the relay"; there is deliberately no such registry:
  it would add stateful relay memory that a relay restart wipes (silently breaking every unattended
  re-arm), and it buys nothing over the nonce gate the re-arm already passes. The `unattended_id`
  remains a pure client-side opaque correlator (echoed on `cmd_ack`), never a relay credential.
  Otherwise (no stored id / token mismatch / revoked) it falls back to normal per-session consent.
- **Override semantics preserved, escalated.** Any local key/mouse still aborts the running queue in
  the same frame (§6.4). In unattended mode a plain override SUSPENDS (auto-resumes after idle, so a
  curious human glance doesn't tear down an overnight run) — but **Esc / the revoke chord CLEARS the
  `localStorage` grant entirely** (hard, permanent until re-opted-in). The persistent indicator
  reads "● UNATTENDED REMOTE CONTROL — press Esc to revoke".
- **Fail-safe + bounds.** Link loss still stops the rover (§3); on reconnect it re-arms only via the
  stored grant. Before forwarding the relay still enforces token-auth **and the F1 minted-nonce grant
  gate** (the re-arm echoes the nonce from the fresh offer on the reconnected socket); an optional
  wall-clock lifetime cap on the unattended grant (default none = until-revoked per D1) is available.
  This is an explicit trust escalation the human performs ONCE and can kill instantly.
- **Deploy→reload loop (agent side).** Orchestrator: build+export+deploy (host-side, unchanged) →
  uplink a `reload` step → the browser re-fetches the new build + re-arms via the stored grant →
  orchestrator reads the new build's telemetry and resumes driving. `reload` is only honoured while
  a grant (session or unattended) is active.

Ships in P2 (consent modal + `localStorage` + `reload` receiver) hardened in P4; the relay's op
whitelist (P1) simply includes `reload`. Goes live only at P4 with the same security review + your
explicit sign-off.

---

## 7. Phased implementation plan (each phase independently shippable + flag-gated)

> Branch discipline: one branch per phase off the integration branch; Conventional Commits scope
> `voxiverse`. Every phase keeps `verify_feature.gd` at 6027/0 (none of these nodes exist under
> the headless gate — `remote_bridge.gd:12-13`) and adds its own executable acceptance check.

### P1 — Relay: bidirectional core + command-file protocol
- **Files:** `tools/remote-bridge/relay.mjs`, `tools/remote-bridge/smoke.mjs`, `README.md`.
- **Contract:** outbox poller (§5.1 atomic-rename ingress; validation per §1.3; `sent/`,
  `rejected/`, `audit.log`); per-socket control state machine (`none/offered/granted(expiry,
  grant_id)/suspended`, §5.2, §6.1 steps 1+3+4 relay side); forward `cmd_seq` only to a granted
  socket; route inbound control events + `0x02` shot frames to `control/results/<seq>/` (§2.2,
  §3.3); `control_ping` heartbeat. Game side untouched — an old client simply never consents, and
  every new relay→game type is already drained-and-discarded by the Phase-1 client
  (`remote_bridge.gd:238-252`), so P1 deploys safely against live Phase-1 rovers.
- **Acceptance (headless, no browser):** extend `smoke.mjs` with a fake game client that (a)
  auths, (b) receives `control_offer` after a file lands in `outbox/`, (c) replies `granted`,
  (d) receives the `cmd_seq`, (e) emits ack/step/done events + one `0x02` shot → assert
  `control/results/<seq>/{ack.json,events.jsonl,done.json,shot-*.jpg}` and `sent/` move; assert a
  second client WITHOUT consent never receives a forward; assert caps + staleness rejections land
  in `rejected/` with reasons; assert an oversized/garbage outbox file cannot crash the relay.
- **Risks:** poller vs bind-mount semantics (use polling, §3.2); accidental forward-before-consent
  (state machine must default-deny; the no-consent smoke assertion is the gate).

### P2 — Game: command receiver, consent dialog, badge upgrade, override skeleton
- **Files:** `godot/src/net/remote_bridge.gd` (inbound dispatch whitelist §3.1; event send
  helpers; `PHASE_STATUS` becomes state-driven), `godot/src/net/remote_bridge_activator.gd`
  (consent modal §6.1; badge states §6.2), new `godot/src/net/remote_control.gd` (queue + ack/nack
  + state machine, with ONLY `wait`, `screenshot`, `stop` ops live), `godot/src/main.gd` (no
  change expected — activator already owns wiring).
- **Flag:** `RemoteBridge.CONTROL_ENABLED := false` const — OFF ships byte-identical Phase-1
  behaviour (dispatch table without the new types); flipped per-build for testing until P4.
- **Contract:** full consent lifecycle (`offer → dialog → granted(grant_id)/denied → expiry/
  revoke/suspend`, §6.1, §6.4 minus locomotion); `cmd_ack`/`cmd_nack` with rover-side cap
  re-validation; `wait`/`screenshot`/`stop` execute end-to-end (screenshot = §3.3 tagged frame);
  override hook aborts a running `wait`.
- **Acceptance:** native run (`VOXIVERSE_REMOTE_TOKEN` + `VOXIVERSE_REMOTE_URL` → local relay,
  `remote_bridge.gd:111-127`): uplink `{wait 3, screenshot, stop}` → human clicks Allow → assert
  ack + 3 events + a correlated shot on disk; deny path → `cmd_nack no_consent`; keypress during
  the wait → `user_override`; TTL forced to 30 s → expiry drops the badge. (Manual-click test,
  scripted assertions on the result files.)
- **Risks:** consent dialog vs pointer-lock (reuse the token prompt's mouse-release/freeze
  pattern, `remote_bridge_activator.gd:152-156`); the dispatch whitelist must be additive-only so
  observe-only sessions are untouched.

### P3 — The locomotion executor (closed-loop move/turn/jump/fly/look)
- **Files:** `godot/src/net/remote_control.gd` (the §4 state machine), `godot/src/player/player.gd`
  (the §4.2 intent seam + `physics_tick` forwarding of `tick_move_delta`/`reframe_yaw_delta`,
  §4.3).
- **Contract:** §4 in full — displacement integration robust to reanchor/reframe, remaining-degree
  turns, obstruction stall detection, per-step watchdogs, `on_fail` policy, exhaustive §4.7
  statuses; `step_done` carries `moved_blocks/turned_deg/pos/yaw_deg/facet/reframes`.
- **Acceptance:** (a) **headless-scripted**: a SceneTree tool script (pattern:
  `godot/src/tools/verify_feature.gd`) that instantiates WorldManager+Player without the bridge,
  drives the executor directly with a canned sequence, and asserts `moved_blocks` within
  `MOVE_TOL`, turn within 0.5°, a wall-facing move reports `blocked`, a watchdog fires on an
  impossible step, and a facet-crossing move (spawn near a ridge, FACETED on) keeps the
  accumulator continuous (`reframes ≥ 1`, distance still within tolerance); (b) native end-to-end
  re-run of the P2 harness with the §1 example sequence.
- **Risks:** the pos-discontinuity trio (reanchor/flip/cross) — mitigated by measuring pre-
  correction inside `_physics_process` (§4.3) and by the headless crossing test; fly-mode `move`
  measurement (same integrator; fly sets `velocity = ZERO` and moves `global_position` directly,
  `player.gd:258-266`, so `tick_move_delta` must be captured in the fly branch too).

### P4 — Hardening, steelman, live enablement
- **Files:** all of the above (fixes only), `tools/remote-bridge/README.md` (security model v2),
  this doc (final semantics).
- **Contract:** flip `CONTROL_ENABLED := true` for the web export ONLY after: `/steelman` pass on
  the whole channel (attack the consent state machine, the override race, the relay forward gate,
  the caps); fail-safe matrix exercised (link cut mid-move → rover halts ≤ 1 tick; relay restart
  mid-sequence; tab close; consent expiry mid-step; two-socket grant supersession §5.2); NEVER-OOM
  audit of the executor + relay result dirs (ring/size caps on `control/results/`).
- **Acceptance:** live deploy + a real browser session: agent runs the §1 example sequence
  end-to-end on voxiverse.game-host.org, user takes over mid-walk with the mouse, agent's
  `seq_done` reads `user_override` — the demo IS the acceptance.
- **Risks:** this is the phase where the public-site exposure becomes real — do not ship P4
  without the steelman + a security review of §5/§6 (the README already flags the boundary:
  "do not deploy without a security review").

### P5 — Mission-control agent tooling + docs
- **Files:** new `tools/remote-bridge/mission.mjs` (host-side helper), `README.md` §"Driving the
  rover", memory-file update.
- **Contract:** `node mission.mjs send <seq.json>` (validate locally against §1, write to outbox
  atomically); `node mission.mjs wait <seq>` (block until `done.json`, exit code by status, print
  the events + shot paths); `node mission.mjs tail` (live event follow). The Claude control loop
  is then: read `results/remote/telemetry.jsonl` → author `seq.json` → `send` → `wait` → read
  `control/results/<seq>/` → repeat.
- **Acceptance:** `mission.mjs` driven against the P1 smoke fake-game (no browser needed) — full
  loop in CI-able form; plus a documented transcript of a real closed loop from P4.
- **Risks:** none structural; keep it dependency-free (`ws` is the only package today —
  `mission.mjs` needs zero new deps, it only touches files).

---

## 8. Decisions — RESOLVED by the user 2026-07-15

- **D1 — Consent TTL: UNTIL REVOKED.** No time-based expiry; a granted control session persists
  for the whole game session until the human explicitly revokes (Esc / revoke chord) or the link
  drops. Implication: the grant is a large standing capability — the persistent on-screen indicator
  (§6.3) and the D2 re-consent-on-override are the primary safety valves, not a TTL. Link-loss
  still fail-safes to stop (§3/§6.4); a fresh dial-in after a drop requires a fresh consent click.
- **D2 — Post-override resume: REQUIRE FULL RE-CONSENT.** Any local human input aborts the queue in
  the same frame (unchanged) AND ENDS the grant — the agent cannot resume until the human clicks the
  consent modal again. The keyboard is a hard kill-switch; agent control never silently resumes.
- **D3 — Preemption: ALLOWED.** A new `cmd_seq` may carry `"preempt": true` to abort-and-replace the
  running sequence (still file-gated + consent-gated). Fits the closed-loop replan model.
- **D4 — Commanded-screenshot fidelity: FULL allowed**, capped at the 2 MiB frame cap
  (`screenshot{full:true}`); ambient frames keep the 960 px / q0.6 default.
- **D5 — Actuator scope: FULL AGENCY — move/look/jump/fly PLUS break, place, hotbar, inventory.**
  The user widened v1 beyond the design's navigation-only default to full world mutation. This is a
  materially larger security surface; therefore (a) the consent modal MUST enumerate these exact
  powers in plain language ("MISSION CONTROL requests DRIVE access: move, build, MINE/BREAK blocks,
  PLACE blocks, and manage your INVENTORY, until you revoke"), red-bordered; (b) every mutation op
  routes through the SAME break/place/collapse pipeline a human uses (WorldManager) — no new mutation
  path, no call-by-name; (c) the command whitelist adds `break{target}`, `place{block,target}`,
  `select_slot{n}` as typed ops with the same per-step ack/verification + caps as movement. World
  mutation still respects all existing gameplay rules (reach, collapse, edit-overlay). NEVER-OOM and
  flag-off byte-identity unchanged.

Combined posture: a persistent, full-agency grant that the human can hard-revoke at any keystroke,
with re-authorization required to resume. Control still only goes LIVE at P4 (§7) after a security
review + /steelman + explicit user sign-off.
