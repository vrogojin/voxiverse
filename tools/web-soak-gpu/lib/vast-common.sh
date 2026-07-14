# shellcheck shell=bash
# Shared helpers for the Vast.ai turnkey GPU web-soak flow (provision / run / teardown).
#
# Source this from the *.sh drivers:  . "$HERE/lib/vast-common.sh"
#
# Design rules:
#  * log/warn/die write to STDERR so a driver's STDOUT stays clean (e.g. provision
#    prints ONLY the new instance id on stdout).
#  * The Vast.ai API key is read the way the vastai CLI itself reads it: from the file
#    ~/.config/vastai/vast_api_key. If VAST_API_KEY is exported instead, we persist it
#    to that file once (chmod 600) so the CLI picks it up — no --api-key plumbing.
#  * No jq dependency: JSON from `vastai … --raw` is parsed by lib/vastjson.mjs (node).

set -euo pipefail

# ── logging (stderr) ────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "${VAST_TAG:-vast}" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "${VAST_TAG:-vast}" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "${VAST_TAG:-vast}" "$*" >&2; exit 1; }

VAST_KEY_FILE="${VAST_API_KEY_FILE:-$HOME/.config/vastai/vast_api_key}"

# vastai wrapper (the CLI reads the key file itself; see vast_preflight).
vast() { vastai "$@"; }

# Ensure the vastai CLI + an API key are present. Refuse to do anything without a key.
vast_preflight() {
  if ! command -v vastai >/dev/null 2>&1; then
    die "vastai CLI not found. Install it first:  pip install --upgrade vastai"
  fi
  if [ -n "${VAST_API_KEY:-}" ] && [ ! -s "$VAST_KEY_FILE" ]; then
    mkdir -p "$(dirname "$VAST_KEY_FILE")"
    printf '%s' "$VAST_API_KEY" > "$VAST_KEY_FILE"
    chmod 600 "$VAST_KEY_FILE"
    log "persisted VAST_API_KEY -> $VAST_KEY_FILE"
  fi
  if [ ! -s "$VAST_KEY_FILE" ]; then
    die "No Vast.ai API key. Put it in $VAST_KEY_FILE (the vastai CLI reads it automatically), \
or export VAST_API_KEY before running. Get a key at https://cloud.vast.ai/account/"
  fi
}

# ── instance state ──────────────────────────────────────────────────────────────
# write_state <file> <instance_id> <dph> <offer_id>
write_state() {
  local file="$1" id="$2" dph="$3" offer="$4"
  mkdir -p "$(dirname "$file")"
  {
    printf 'VAST_INSTANCE_ID=%s\n' "$id"
    printf 'VAST_DPH=%s\n' "$dph"
    printf 'VAST_OFFER_ID=%s\n' "$offer"
    printf 'VAST_CREATED_EPOCH=%s\n' "$(date +%s)"
  } > "$file"
}

# actual_status of an instance id, e.g. "running" / "loading" (empty if not found).
instance_status() {
  local id="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  vast show instances --raw 2>/dev/null | node "$here/vastjson.mjs" instance-state "$id" 2>/dev/null || true
}

# Block until the instance reports "running" (or timeout seconds elapse).
wait_running() {
  local id="$1" timeout="${2:-600}" t0 st
  t0="$(date +%s)"
  while :; do
    st="$(instance_status "$id")"
    [ "$st" = "running" ] && { log "instance $id is running"; return 0; }
    if [ $(( $(date +%s) - t0 )) -ge "$timeout" ]; then
      die "instance $id did not reach 'running' within ${timeout}s (last status: '${st:-unknown}')"
    fi
    log "  … instance $id status='${st:-?}' (waiting)"
    sleep 10
  done
}

# Print "host port user" for an instance by parsing `vastai ssh-url` (ssh://user@host:port).
get_ssh() {
  local id="$1" u user rest host port
  u="$(vast ssh-url "$id" 2>/dev/null)" || return 1
  u="$(printf '%s' "$u" | tr -d '[:space:]')"
  u="${u#ssh://}"
  case "$u" in
    *@*) user="${u%%@*}"; rest="${u#*@}" ;;
    *)   user="root";     rest="$u" ;;
  esac
  host="${rest%%:*}"
  port="${rest##*:}"
  [ -n "$host" ] && [ -n "$port" ] || return 1
  printf '%s %s %s\n' "$host" "$port" "$user"
}

# Block until ssh accepts a command on the box (or timeout seconds elapse).
# args: host port user timeout
wait_ssh() {
  local host="$1" port="$2" user="$3" timeout="${4:-300}" t0
  t0="$(date +%s)"
  while :; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=10 -o BatchMode=yes -p "$port" "$user@$host" true 2>/dev/null; then
      log "ssh is up ($user@$host:$port)"
      return 0
    fi
    if [ $(( $(date +%s) - t0 )) -ge "$timeout" ]; then
      die "ssh to $user@$host:$port not reachable within ${timeout}s"
    fi
    log "  … waiting for ssh ($user@$host:$port)"
    sleep 8
  done
}

# Print a one-line spend estimate. args: minutes dph
spend_estimate() {
  local mins="$1" dph="${2:-0}"
  awk -v m="$mins" -v d="$dph" \
    'BEGIN { printf "[spend] ~$%.2f  (%d min at $%.3f/hr)\n", d*m/60.0, m, d }' >&2
}
