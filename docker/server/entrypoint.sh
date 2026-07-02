#!/usr/bin/env bash
#
# VOXIVERSE game-server entrypoint.
#
# 1. Render the nginx server block from its template.
# 2. Run ssl-manager's `ssl-setup`: registers this container with HAProxy,
#    obtains/renews a Let's Encrypt cert (HTTP-01 via its own :80 proxy),
#    and spawns the port-80 proxy + renewal loop in the background.
# 3. Exec nginx in the foreground so it becomes PID 1 and adopts/reaps the
#    ssl-manager background processes (this is ssl-manager's documented pattern).
#
set -euo pipefail

: "${SSL_DOMAIN:=voxiverse.game-host.org}"
: "${SSL_HTTPS_PORT:=443}"
: "${APP_HTTP_PORT:=8080}"
export SSL_DOMAIN SSL_HTTPS_PORT APP_HTTP_PORT

log() { printf '[voxiverse-entrypoint] %s\n' "$*"; }

# --- 1. Render nginx config -------------------------------------------------
log "Rendering nginx config for ${SSL_DOMAIN} (https :${SSL_HTTPS_PORT}, http :${APP_HTTP_PORT})"
envsubst '${SSL_DOMAIN} ${SSL_HTTPS_PORT} ${APP_HTTP_PORT}' \
    < /etc/nginx/templates/voxiverse.conf.template \
    > /etc/nginx/conf.d/voxiverse.conf

# --- 2. TLS + HAProxy registration -----------------------------------------
# ssl-setup exits non-zero on failure; `set -e` then aborts the container so
# the failure is loud and visible (deploy.sh surfaces it). SSL_TEST_MODE=true
# or SSL_STAGING=true can be used for dry runs without burning LE prod limits.
log "Running ssl-setup (HAProxy registration + certificate)…"
/usr/local/bin/ssl-setup
if [ -f /tmp/.ssl-env ]; then
    # shellcheck disable=SC1091
    . /tmp/.ssl-env
    log "SSL environment loaded (cert: ${SSL_CERT_FILE:-?})"
fi

# --- 3. Serve ---------------------------------------------------------------
log "Validating nginx configuration…"
nginx -t
log "Starting nginx (foreground, PID 1)…"
exec nginx -g 'daemon off;'
