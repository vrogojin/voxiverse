# VOXIVERSE — Deploy Guide

How the Godot 4 **Web export** is served live at
**https://voxiverse.game-host.org**, and how to (re)deploy and roll back.

---

## 1. Architecture

```
        Internet (443/tcp, SNI)                Internet (80/tcp, Host header)
                 │                                        │
                 ▼                                        ▼
        ┌─────────────────────────────────────────────────────────┐
        │  HAProxy  (container `haproxy`, /home/vrogojin/haproxy)   │
        │  • :443 SNI SSL-PASSTHROUGH (mode tcp, no termination)    │
        │  • :80  Host-header routing (mode http)                   │
        │  • :8404 Registration API (haproxy-net only)              │
        └─────────────────────────────────────────────────────────┘
                 │ voxiverse.game-host.org            (docker network: haproxy-net)
                 ▼
        ┌─────────────────────────────────────────────────────────┐
        │  Container `voxiverse-game`  (docker/server)             │
        │  • ssl-manager: Let's Encrypt cert + HAProxy self-reg    │
        │    ├─ :80  ACME HTTP-01 proxy  →  redirects to HTTPS      │
        │    └─ renewal loop (~12h)                                 │
        │  • nginx:                                                 │
        │    ├─ :443 TLS  → serves /srv/web  (the game)            │
        │    │     COOP: same-origin / COEP: require-corp          │
        │    │     application/wasm MIME, gzip_static              │
        │    └─ :8080 plain HTTP upstream (301 → https)            │
        └─────────────────────────────────────────────────────────┘
                 │ bind mount (ro)
                 ▼
          <repo>/build/web/    ← Godot `--export-release "Web"` output
```

**Why this shape**

- HAProxy does **SNI SSL-passthrough** — it never sees our private key; the
  container **terminates its own TLS** on `:443`. So the game container must
  hold a valid cert for `voxiverse.game-host.org`.
- **Cross-origin isolation** (`COOP: same-origin` + `COEP: require-corp`) is
  mandatory for Godot 4 web builds that use threads / `SharedArrayBuffer`.
  Without both headers `crossOriginIsolated` is false and the threaded engine
  refuses to start. nginx sends them on **every** response (server-scope
  `add_header … always`; asset locations use only `expires`/`try_files` so the
  headers are inherited, never dropped).
- The container **self-registers** its `voxiverse.game-host.org → voxiverse-game`
  mapping with HAProxy's Registration API (`http://haproxy:8404/v1/backends`).
  No host file edits, no HAProxy restart.
- Host ports 80/443 belong to HAProxy. This container **publishes nothing** to
  the host (`expose`, not `ports`).

## 2. Files

| Path | Purpose |
|---|---|
| `docker/server/Dockerfile` | `FROM ghcr.io/unicitynetwork/ssl-manager` + nginx-full |
| `docker/server/nginx.conf` | http-level config: MIME (wasm), gzip/gzip_static |
| `docker/server/voxiverse.conf.template` | server blocks (TLS :443, redirect :8080), COOP/COEP |
| `docker/server/entrypoint.sh` | render config → `ssl-setup` → `exec nginx` |
| `deploy/docker-compose.yml` | `voxiverse-game` on `haproxy-net`, cert volume, web bind mount |
| `scripts/deploy.sh` | build + (re)start + register + **verify** live |

## 3. Go-live (the one command)

```bash
# From the repo root, with the real build/web/ present:
./scripts/deploy.sh
```

That script:
1. Checks `build/web/index.html` exists.
2. Pre-compresses `*.wasm *.pck *.js *.json *.html *.css *.svg` → `*.gz`
   (served by `gzip_static`).
3. Ensures the `haproxy-net` network exists and HAProxy is running
   (starts it via `/home/vrogojin/haproxy/run-haproxy.sh` if needed).
4. Builds the `voxiverse-game` image and (re)creates the container.
5. Waits until the container registers with HAProxy (`https_port:443`).
6. **Verifies** `https://voxiverse.game-host.org` returns **HTTP 200** with
   `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp`.

### Redeploy after a new Godot export

The web export is **bind-mounted** (`build/web/ → /srv/web:ro`), so a redeploy
just rebuilds the (content-agnostic) image and recreates the container:

```bash
./scripts/deploy.sh              # ← the single redeploy command
```

The Let's Encrypt cert lives in the `voxiverse_voxiverse-letsencrypt` volume and
is **reused** across redeploys (no re-issue, no rate-limit risk).

### Flags (dry runs — avoid burning Let's Encrypt production limits)

```bash
./scripts/deploy.sh --test-mode  # self-signed cert, NO ACME (fully offline test)
./scripts/deploy.sh --staging    # Let's Encrypt STAGING CA (untrusted, high limits)
./scripts/deploy.sh --no-build   # recreate container without rebuilding the image
```

`--test-mode` still exercises HAProxy registration, the domain-reachability
nonce check, TLS on :443 and the COOP/COEP headers — everything except a real
CA. Use it to validate changes; then run the plain `./scripts/deploy.sh` for a
browser-trusted cert.

> **Switching cert mode:** ssl-manager reuses any cert in the volume that is
> valid for >30 days. To force a fresh cert (e.g. after testing with a
> self-signed/staging cert), drop the volume first:
> `docker compose -f deploy/docker-compose.yml down && docker volume rm voxiverse_voxiverse-letsencrypt && ./scripts/deploy.sh`

## 4. Verify by hand

```bash
# Trusted cert + isolation headers (NO -k → also proves browser trust):
curl -sI https://voxiverse.game-host.org/ | grep -iE 'HTTP/|cross-origin'

# Issuer / validity:
echo | openssl s_client -connect voxiverse.game-host.org:443 \
      -servername voxiverse.game-host.org 2>/dev/null | openssl x509 -noout -issuer -dates

# HAProxy registration:
docker exec haproxy curl -s http://localhost:8404/v1/backends/voxiverse.game-host.org

# Asset MIME + compression:
curl -skI https://voxiverse.game-host.org/index.html -H 'Accept-Encoding: gzip' | grep -i content-encoding
```

Expected: `HTTP/2 200`, `cross-origin-opener-policy: same-origin`,
`cross-origin-embedder-policy: require-corp`, issuer `Let's Encrypt`,
`content-encoding: gzip`, and `.wasm` served as `application/wasm`.

## 5. Rollback

```bash
# Stop serving (container down; HAProxy keeps running for other domains):
docker compose -f deploy/docker-compose.yml down

# Optional: remove the HAProxy route so 443 for this domain returns no-match:
docker exec haproxy curl -s -X DELETE \
    http://localhost:8404/v1/backends/voxiverse.game-host.org
```

To roll back **content** only, restore the previous `build/web/` and rerun
`./scripts/deploy.sh`. The image is content-agnostic, so rolling back the app is
just pointing the bind mount at a previous export (or `git checkout` of the
export) and redeploying.

## 6. What was changed in the shared HAProxy

**Nothing was edited by hand.** The container self-registered via the
Registration API, which added the route and gracefully reloaded HAProxy:

```
voxiverse.game-host.org → voxiverse-game  (http_port 80, https_port 443)
```

`domains.map`, `generate-config.sh`, and the HAProxy container start were **not**
touched. HAProxy was already running; it was not restarted. To remove the route,
use the `DELETE` call in §5.

## 7. Operational notes / gotchas

- **Stable name:** compose pins `container_name` **and** `hostname` to
  `voxiverse-game`. ssl-manager registers `$(hostname)`, and Docker DNS on
  `haproxy-net` resolves `voxiverse-game` to the current container, so the
  HAProxy backend target never changes across redeploys.
- **Cert renewal** is automatic (ssl-manager runs a background loop, renews
  within 30 days of expiry). Nothing to cron on the host.
- **Ports:** the container exposes 80/443/8080 on `haproxy-net` only. Never add
  a host `ports:` mapping for 80/443 — that would collide with HAProxy.
- **Brotli:** stock nginx has no brotli module, so only gzip is provided
  (`gzip_static` + on-the-fly `gzip`). Adequate for `.wasm`/`.pck`/`.js`.
- **First issuance** needs the domain reachable on `:80` through HAProxy
  (Let's Encrypt HTTP-01). DNS `voxiverse.game-host.org → 213.199.61.236` and
  HAProxy publishing host :80 are the prerequisites.
```
