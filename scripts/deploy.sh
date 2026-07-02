#!/usr/bin/env bash
#
# VOXIVERSE deploy harness
# ------------------------
# Builds the game-server image against the CURRENT build/web/, (re)starts the
# `voxiverse-game` container on haproxy-net, ensures HAProxy is up and the
# domain is registered, then verifies the live site.
#
# Usage:
#   scripts/deploy.sh                 # production Let's Encrypt cert (default)
#   scripts/deploy.sh --staging       # LE staging CA (untrusted, high rate limits)
#   scripts/deploy.sh --test-mode     # self-signed cert, no ACME (fully offline)
#   scripts/deploy.sh --no-build      # recreate container without rebuilding image
#
# Env:
#   VOXIVERSE_WEB_ROOT   override the web export dir (default: <repo>/build/web)
#   SSL_ADMIN_EMAIL      Let's Encrypt contact email
#
set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/deploy/docker-compose.yml"
HAPROXY_DIR="/home/vrogojin/haproxy"
DOMAIN="voxiverse.game-host.org"
CONTAINER="voxiverse-game"
NETWORK="haproxy-net"
export VOXIVERSE_WEB_ROOT="${VOXIVERSE_WEB_ROOT:-${REPO_ROOT}/build/web}"

# ─── Colours / logging ───────────────────────────────────────────────────────
C_G='\033[0;32m'; C_Y='\033[0;33m'; C_R='\033[0;31m'; C_B='\033[1m'; C_0='\033[0m'
log()  { printf "${C_G}==>${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[warn]${C_0} %s\n" "$*" >&2; }
err()  { printf "${C_R}[err]${C_0} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Args ────────────────────────────────────────────────────────────────────
DO_BUILD=1
export SSL_STAGING="${SSL_STAGING:-false}"
export SSL_TEST_MODE="${SSL_TEST_MODE:-false}"
while [ $# -gt 0 ]; do
  case "$1" in
    --staging)    SSL_STAGING=true ;;
    --test-mode)  SSL_TEST_MODE=true ;;
    --no-build)   DO_BUILD=0 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done
export SSL_STAGING SSL_TEST_MODE

command -v docker >/dev/null || die "docker not found"
DC=(docker compose)
docker compose version >/dev/null 2>&1 || DC=(docker-compose)

log "Repo:      ${REPO_ROOT}"
log "Web root:  ${VOXIVERSE_WEB_ROOT}"
log "Cert mode: staging=${SSL_STAGING} test-mode=${SSL_TEST_MODE}"

# ─── 1. Web export present ───────────────────────────────────────────────────
if [ ! -f "${VOXIVERSE_WEB_ROOT}/index.html" ]; then
  die "No index.html in ${VOXIVERSE_WEB_ROOT}. Build the Godot web export first (or restore the placeholder)."
fi
log "Web export OK: $(find "${VOXIVERSE_WEB_ROOT}" -maxdepth 1 -type f | wc -l) file(s)"

# ─── 2. Precompress assets for gzip_static ───────────────────────────────────
if command -v gzip >/dev/null; then
  log "Pre-compressing assets (gzip_static siblings)…"
  # Regenerate .gz so they never go stale relative to their source.
  find "${VOXIVERSE_WEB_ROOT}" -type f \
       \( -name '*.wasm' -o -name '*.pck' -o -name '*.js' -o -name '*.mjs' \
          -o -name '*.json' -o -name '*.html' -o -name '*.css' -o -name '*.svg' \) \
       -print0 2>/dev/null |
  while IFS= read -r -d '' f; do
    gzip -9 -f -k "$f" 2>/dev/null || true
  done
fi

# ─── 3. Shared network ───────────────────────────────────────────────────────
if ! docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  log "Creating docker network ${NETWORK}"
  docker network create "${NETWORK}" >/dev/null
fi

# ─── 4. HAProxy up ───────────────────────────────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -qx haproxy; then
  warn "HAProxy container not running — starting it via ${HAPROXY_DIR}/run-haproxy.sh"
  [ -x "${HAPROXY_DIR}/run-haproxy.sh" ] || die "run-haproxy.sh not found/executable at ${HAPROXY_DIR}"
  ( cd "${HAPROXY_DIR}" && ./run-haproxy.sh )
  for _ in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx haproxy && break; sleep 1
  done
fi
docker ps --format '{{.Names}}' | grep -qx haproxy || die "HAProxy still not running"
log "HAProxy is up"

# ─── 5. Build + (re)create container ─────────────────────────────────────────
if [ "${DO_BUILD}" -eq 1 ]; then
  log "Building image ${CONTAINER}…"
  "${DC[@]}" -f "${COMPOSE_FILE}" build
fi
log "(Re)creating container ${CONTAINER}…"
"${DC[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate

# ─── 6. Wait for ssl-setup (registration + cert) ─────────────────────────────
log "Waiting for ${CONTAINER} to obtain its cert and register with HAProxy…"
ok=0
for i in $(seq 1 60); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    err "Container exited during startup. Last logs:"
    docker logs --tail 40 "${CONTAINER}" 2>&1 | sed 's/^/    /' || true
    die "voxiverse-game failed to start (likely ssl-setup failure — see logs above)."
  fi
  # Registered with HAProxy including HTTPS port?
  reg="$(docker exec haproxy sh -c "curl -s http://localhost:8404/v1/backends/${DOMAIN}" 2>/dev/null || true)"
  if echo "$reg" | grep -q '"https_port":443'; then
    ok=1; break
  fi
  sleep 2
done
[ "$ok" -eq 1 ] || { docker logs --tail 40 "${CONTAINER}" 2>&1 | sed 's/^/    /'; die "Timed out waiting for HAProxy HTTPS registration."; }
log "Registered with HAProxy: ${DOMAIN} → ${CONTAINER}:443"

# ─── 7. Verify the live site ─────────────────────────────────────────────────
log "Verifying https://${DOMAIN} …"
headers=""
for i in $(seq 1 30); do
  headers="$(curl -skI "https://${DOMAIN}/" 2>/dev/null || true)"
  echo "$headers" | grep -qiE '^HTTP/.* 200' && break
  sleep 2
done

echo "-------------------------------------------------------------------"
echo "$headers"
echo "-------------------------------------------------------------------"

fail=0
echo "$headers" | grep -qiE '^HTTP/.* 200'                                   || { err "no HTTP 200"; fail=1; }
echo "$headers" | grep -qi '^Cross-Origin-Opener-Policy: *same-origin'       || { err "missing/!=  COOP: same-origin"; fail=1; }
echo "$headers" | grep -qi '^Cross-Origin-Embedder-Policy: *require-corp'    || { err "missing/!= COEP: require-corp"; fail=1; }

if [ "$fail" -ne 0 ]; then
  err "Verification FAILED. Recent container logs:"
  docker logs --tail 30 "${CONTAINER}" 2>&1 | sed 's/^/    /' || true
  exit 1
fi

log "${C_B}LIVE:${C_0} https://${DOMAIN} — HTTP 200 with COOP/COEP present."
if [ "${SSL_STAGING}" = "true" ] || [ "${SSL_TEST_MODE}" = "true" ]; then
  warn "Non-production cert in use (staging/self-signed). Re-run WITHOUT --staging/--test-mode for a browser-trusted cert."
fi
