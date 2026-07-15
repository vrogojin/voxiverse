# VOXIVERSE remote-play bridge — Phase 1 (OBSERVE-ONLY)

A token-gated bridge that lets a remote agent **observe a real-GPU play session** of the live
game. The game, when dialed, opens an **outbound** WebSocket to a relay on our host and streams:

- **Telemetry** (JSON, ~4/s): the `perf_hud.gd` numbers (fps, worst-frame ms, hitches, proc/phys,
  draws, prims, vox gen/mesh backlog) plus rich state (player world position, active facet, facet
  pool neighbour count, LOD ledger, stream-load credit) — each field guarded for absence.
- **Frames** (binary JPEG, ~2/s): a downscaled snapshot of the **game canvas only**.

Phase 1 is **observe-only**: the game only *sends*. There is **no control surface** and **no
restart** (those are Phase 2/3, gated separately). The relay writes files that only the agent on
this host reads; it never serves the received data publicly.

---

## Security model (this is a PUBLIC live site)

1. **Dead in normal play.** The bridge is instantiated by the game **only** when dial mode is
   detected. On the web that is the URL query `?remote=<token>`; with no such param the
   `RemoteBridge` node is **never created** — no WebSocket, no frame capture, no per-frame cost,
   zero behavioural change. A normal visitor streams **nothing** and is observed by **no one**. The
   headless `verify_feature` gate never runs `main.gd`, so the bridge is structurally unreachable
   there (the 6027/0 gate is unaffected).
2. **Token auth.** The relay requires a valid shared-secret token. The game sends it in its `hello`
   frame; the relay **rejects + closes** (code `4001`) any connection whose first message is not a
   valid hello with a matching token, and **logs the auth failure**. The token lives in a gitignored
   `.token` file (or `REMOTE_BRIDGE_TOKEN` env) on the host and is passed to the game via the URL.
   Because the token travels inside the `wss` hello frame (encrypted) and **not** in the WS URL, it
   never lands in nginx access logs.
3. **Viewport-only capture.** Frames are `get_viewport().get_texture().get_image()` — the game
   canvas only, never the user's screen or other tabs.
4. **Auth-ack gate.** After the hello the client streams **nothing** and captures **nothing** until
   the relay returns an app-level `{"type":"auth_ok"}` (sent only after a valid token). An
   unauthenticated visitor (bad/absent token → closed `4001`, never acked) never reads back or
   streams a single frame — the brief pre-rejection window is closed. `auth_ok` is also the handshake
   Phase-2 controls will ride.
5. **No inbound control.** The only inbound message the client acts on is that one `auth_ok`
   handshake; everything else is drained and discarded — it never influences play.
6. **Anti-DoS + timing-safe auth.** The token compare is `crypto.timingSafeEqual` over SHA-256
   digests (constant-time, leaks no length). Connections are split into an **authed** pool (cap
   `MAX_CONNS`, never evicted) and a **pending** pool (unauthed; the oldest is evicted when full), so
   anonymous sockets can never lock a real session out of the channel. Short 1.5 s auth timeout, a
   per-IP pre-auth connection rate limit, a per-connection message-rate cap, bounded frame size,
   rolled/capped telemetry log, pruned frame ring, and an optional `REMOTE_BRIDGE_ORIGIN` allow-list
   (defense-in-depth — WS isn't subject to CORS). Every connect/disconnect/auth-fail is logged.

Tunables (env): `REMOTE_BRIDGE_MAX_CONNS` (4), `REMOTE_BRIDGE_MAX_PENDING` (8),
`REMOTE_BRIDGE_PREAUTH_PER_IP` (10/10s), `REMOTE_BRIDGE_ORIGIN` (unset).
5. **Relay hardening.** Binds `127.0.0.1` only (reachable solely through the nginx `/remote` route),
   caps concurrent connections, rate-limits per connection, bounds frame size, rolls/caps the
   telemetry log and prunes the frame ring, and logs every connect/disconnect/auth-fail.

---

## Setting the token

```bash
cd tools/remote-bridge
# EITHER a gitignored file …
printf '%s' "$(openssl rand -hex 24)" > .token      # .token is gitignored
# … OR an env var (takes precedence):
export REMOTE_BRIDGE_TOKEN="$(cat .token)"
```

The **same** value activates the game two ways:

- **URL param** — `https://voxiverse.game-host.org/?remote=<token>` auto-dials on load.
- **Hotkey (`Ctrl+Shift+F9`)** — toggles dial mode at runtime. If the URL param is absent, an
  on-canvas prompt asks for the token; the game dials only once a token is entered. The prompt takes
  a **token only** — the relay URL is fixed to our host and is never user-specifiable, so a visitor
  can't be redirected to a rogue relay. Pressing the chord again (or closing the tab) disconnects.

Whenever the channel is live, a prominent **"● REMOTE ACTIVE — observing"** badge is shown on the
game canvas (amber "◌ REMOTE — dialing…" while connecting), so the user can always tell when the
agent can observe the session. In Phase 2 (control) the same toggle/badge upgrade to
"observing + CONTROLLING".

> Never commit `.token`. It is listed in `.gitignore` alongside `node_modules/` and `results/`.

---

## Running the relay

```bash
cd tools/remote-bridge
npm install                       # installs `ws` (only dependency)
REMOTE_BRIDGE_TOKEN=$(cat .token) node relay.mjs
# flags: --port 8090  --host 127.0.0.1  --results ./results/remote
```

Defaults: `--host 127.0.0.1 --port 8090 --results ./results/remote`.

Run it under a process manager (systemd / `pm2` / `nohup`) so it survives your shell. It must be
listening **before** you open the game with `?remote=<token>`.

### Loopback smoke test (no game/browser needed)

```bash
npm run smoke      # boots the relay on a scratch port and asserts, headless (no browser):
                   #   PART A (observe): telemetry.jsonl + frame-latest.jpg written; bad token
                   #     rejected (4001); authed sessions survive a pending flood.
                   #   PART B (P1 control): a FAKE GAME client auths/grants/overrides/preempts and
                   #     echoes ack/step/shot/seq_done — asserts a command is forwarded ONLY after a
                   #     grant, NEVER without consent, results routed to control/results/<seq>/,
                   #     override ends the grant, preempt aborts a run, and caps/oversize/garbage/
                   #     stale/duplicate are rejected with a reason. Exits non-zero on any failure.
node --check relay.mjs   # syntax only
```

---

## How the agent reads the session

Everything lands under `results/remote/` (gitignored):

| Path | What | How to read |
|---|---|---|
| `results/remote/telemetry.jsonl` | Append-only JSON-lines, one object per telemetry tick. Each line is stamped by the relay with `_rx` (server receive time) and `_peer`. Rolls to `.1` past 32 MB. | `tail -n 40 results/remote/telemetry.jsonl \| jq .` — watch `fps`, `worst_ms`, `hitches`, `vox_mesh`, `pos`, `facet`, `stream_credit`, `lod`. |
| `results/remote/frame-latest.jpg` | The **most recent** frame, written atomically (tmp+rename) so a reader never sees a torn file. | `Read` the file (it renders as an image). Re-read to poll the live view. |
| `results/remote/frames/` | A timestamped ring of the newest ~60 frames. | Browse for a short visual timeline. |

Telemetry field reference (all optional except `type`/`t`): `fps`, `min_fps`, `worst_ms`, `hitches`,
`proc_ms`, `phys_ms`, `draws`, `prims`, `vmem_mb`, `objects`, `vox_gen`, `vox_mesh`, `vox_main`,
`vox_gpu`, `pos` `[x,y,z]`, `facet`, `facet_neighbours`, `stream_credit`, `lod` `{…}`.

---

## P1 control channel (relay core — NOT yet live)

The relay now also carries the **agent → game command path** (design
`docs/COSMOS-REMOTE-CONTROL-DESIGN.md` §7 "P1"). This is the relay-side **core only**: it validates,
consent-gates, forwards, and result-routes commands. **Live control is NOT enabled** — the game
client does not yet receive, consent to, or execute commands (that is P2–P4, and the game's
`CONTROL_ENABLED` flag is off). Against today's live observe-only rover, every new relay→game message
is simply drained-and-discarded, so **deploying this relay is byte-identical for a client that never
grants control**.

### The one rule (Phase-1 policy inversion, design §3.2)

> The relay forwards to a game socket **only** bytes that originate from a **local file the host
> agent wrote into `control/outbox/`**, and **only** to a socket that is token-authed **and** has an
> active human-armed control **grant**. Nothing a WS client sends is ever forwarded onward or
> reflected back — game messages stay record-only. The relay never authors commands. **Default is
> DENY:** no outbox file + no grant ⇒ the observe path behaves exactly as Phase 1.

Command ingress is the **host filesystem only** — the single trust anchor. No WS client, HTTP path,
or game message can inject a command.

### File layout (all under `control/`, gitignored)

```
control/
  outbox/          ← agent WRITES <seq>.json here (atomic temp+rename); the ONLY command source
  sent/            ← relay moves a forwarded file here (audit trail)
  rejected/        ← relay moves an invalid file here + <seq>.reject.txt (reason)
  results/<seq>/   ← ack.json, events.jsonl, done.json, shot-<id>-<label>.jpg
  audit.log        ← append-only: grant / forward / reject / revoke / override / seq_done …
```

### Uplink = one `cmd_seq` JSON file

```jsonc
{ "type": "cmd_seq", "seq": "walkabout-007", "issued": 1784500000.0,
  "on_fail": "abort",            // "abort" (default) | "continue"
  "preempt": false,              // true = abort-and-replace the running sequence (D3)
  "steps": [ { "id": 1, "op": "move", "blocks": 10.5, "heading": "forward", "gait": "walk" },
             { "id": 2, "op": "screenshot", "label": "ridge" }, { "id": 3, "op": "stop" } ] }
```

**Caps (rejected whole-sequence, design §1.3):** ≤ 64 steps, `move.blocks` ≤ 128, Σ expected step
time ≤ 180 s, JSON ≤ 16 KiB, `issued` not older than 120 s. Ops are a **closed whitelist**:
`move turn look wait jump screenshot set_fly stop break place select_slot` (D5 full-agency set) — any
other op fails validation. Reject reasons written to `rejected/<seq>.reject.txt`: `bad_json`, `caps`,
`stale`, `duplicate`, `busy`, `no_consent`.

### Consent state machine (relay side)

- The game arms control by sending `{"type":"control_state","state":"granted","grant_id":"…"}`;
  the relay then forwards held/incoming commands to that socket. Exactly **one** sequence is in
  flight; a second non-`preempt` command while one runs is rejected `busy`.
- **`override`** (any local human input, D2) or **`revoked`**/**socket-close**/**3 missed
  `control_ping`s** ends the grant. Forwarding **suspends and never silently resumes** — a fresh
  `granted` is required. A command dropped while ungranted **waits** (it is offered via
  `control_offer`) and is failed `no_consent` only if it goes stale or the last authed socket leaves.
- Grant persists **until revoked** (D1 — no TTL). Most-recently-granted socket wins (§5.2).

### Downlink results

Game→relay events (`cmd_ack`/`cmd_nack`, `step_start`/`step_done`, `seq_done`) route to
`control/results/<seq>/{ack.json, events.jsonl, done.json}`; a commanded screenshot arrives as a
`0x02`-tagged binary frame (`[0x02][u16 hlen][{seq,id,label,t}][jpeg]`) written to
`shot-<id>-<label>.jpg`. `seq`/`id`/`label` are strictly sanitized — a rogue game message cannot
escape `control/results/`, and results are only written for a seq the relay actually forwarded.

> **Not a deploy step.** This is code + headless test only. Live enablement (P4) requires the game
> client (P2/P3), a `/steelman` pass, and a security review of the §5/§6 boundary — do not flip the
> game's `CONTROL_ENABLED` before then.

---

## Infra: the `wss://voxiverse.game-host.org/remote` route

The game page is served **https + cross-origin-isolated** (COOP `same-origin` + COEP
`require-corp`), so the bridge must dial a **same-origin `wss://`** endpoint — a `ws://` or
cross-origin target would be blocked as mixed content. We expose the relay at
`wss://voxiverse.game-host.org/remote` by adding one `location` block to the game's nginx server
(`docker/server/voxiverse.conf.template`).

> **COEP note.** COEP `require-corp` on the game page does **not** block the outbound WebSocket —
> WebSocket connections are not subject to CORP/COEP the way `fetch`/subresource loads are. The only
> hard requirement is `wss` **same-origin** to avoid mixed-content blocking on the https page. No CORP
> header is needed on the WS itself.

### The nginx snippet

Add this **inside** the existing HTTPS `server { … }` block in
`docker/server/voxiverse.conf.template` (e.g. just before `location = /healthz`). It declares **no**
`add_header` of its own, so it does not touch the server-scope COOP/COEP that the game pages inherit
— and the WS itself does not need them:

```nginx
    # --- /remote : remote-play bridge relay (Phase 1, observe-only) --------------
    # Same-origin wss endpoint the GAME dials out to (?remote=<token>). Proxies the
    # WebSocket upgrade to the loopback-bound relay (tools/remote-bridge/relay.mjs).
    # No add_header here → inherits nothing it shouldn't and strips nothing from the
    # game pages. The relay does token auth on the hello; nginx just forwards bytes.
    location = /remote {
        proxy_pass http://127.0.0.1:8090;   # relay --host 127.0.0.1 --port 8090
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       $host;
        proxy_set_header X-Real-IP  $remote_addr;
        proxy_read_timeout  3600s;          # long-lived session; don't idle-kill it
        proxy_send_timeout  3600s;
    }
```

`127.0.0.1:8090` is the relay running **on the same host as the game container**. Because the game
runs in Docker (`docker/server`), `127.0.0.1` inside the container is **not** the host — so either:

- run the relay **inside** the game container / same network namespace, or
- point `proxy_pass` at the host gateway (e.g. `http://host.docker.internal:8090`, adding
  `extra_hosts: ["host.docker.internal:host-gateway"]` to `deploy/docker-compose.yml`), or
- run the relay as a sibling service on `haproxy-net` and `proxy_pass http://<relay-container>:8090`.

Pick one when wiring the deploy; the default assumes the relay is reachable at `127.0.0.1:8090` from
nginx. **This is deploy-time infra — do not deploy it without a security review of the boundary.**

### How it slots into `deploy.sh`

`scripts/deploy.sh` rebuilds the game container against `voxiverse.conf.template` unchanged; adding
the `location = /remote` block to the template is all nginx needs. The relay is a **separate**
long-lived process (systemd/pm2) — it is not part of the game image and `deploy.sh` neither starts
nor stops it. Bring the relay up first, add the nginx block, redeploy the game, then verify the
route upgrades:

```bash
# after the relay is running and the template block is added + game redeployed:
curl -sI https://voxiverse.game-host.org/remote        # 426 Upgrade Required (relay answers)
```
