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
npm run smoke      # boots the relay on a scratch port, drives a fake game client, asserts
                   # telemetry.jsonl + frame-latest.jpg are written AND a bad token is rejected
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
