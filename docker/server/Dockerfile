# VOXIVERSE game server
# ----------------------
# nginx serving the Godot 4 Web export with cross-origin isolation
# (COOP/COEP), correct WASM MIME + gzip, on top of unicity's ssl-manager which
# provides automatic Let's Encrypt certs + HAProxy self-registration.
#
# ssl-manager base (Debian trixie) already ships: certbot, openssl, curl, jq,
# nc, python3 and the ssl-setup/ssl-renew/ssl-http-proxy scripts.
FROM ghcr.io/unicitynetwork/ssl-manager:latest

# nginx (full: includes ngx_http_gzip_static_module + http_v2) and envsubst.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx-full gettext-base curl \
 && rm -rf /var/lib/apt/lists/* \
 # Fail the build if the gzip_static module is missing (our nginx.conf needs it).
 && nginx -V 2>&1 | grep -q -- '--with-http_gzip_static_module' \
 # Ensure `.wasm` maps to application/wasm (recent nginx already ships this).
 && (grep -q 'application/wasm' /etc/nginx/mime.types \
     || sed -i 's|^}|    application/wasm                                  wasm;\n}|' /etc/nginx/mime.types) \
 && rm -f /etc/nginx/sites-enabled/default \
 && mkdir -p /srv/web /etc/nginx/templates /etc/nginx/conf.d

COPY nginx.conf                 /etc/nginx/nginx.conf
COPY voxiverse.conf.template    /etc/nginx/templates/voxiverse.conf.template
COPY entrypoint.sh              /usr/local/bin/voxiverse-entrypoint
RUN chmod +x /usr/local/bin/voxiverse-entrypoint

# 80  = ssl-manager ACME/HTTP proxy (Let's Encrypt HTTP-01 + redirect upstream)
# 443 = TLS (the game)   |   8080 = plain-HTTP upstream behind the :80 proxy
# NOTE: none of these are published to the host — HAProxy fronts 80/443 via SNI.
EXPOSE 80 443 8080

ENTRYPOINT ["/usr/local/bin/voxiverse-entrypoint"]
