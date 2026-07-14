#!/usr/bin/env bash
# run-remote.sh — ONE-COMMAND turnkey Tier-B GPU web-soak on Vast.ai.
#
#   provision cheap T4  ->  wait running + ssh  ->  rsync harness  ->  setup box
#   ->  run soak against the LIVE public site under xvfb with real-GPU flags
#   ->  pull results back  ->  ALWAYS destroy the instance (trap)  ->  print spend.
#
# The soak points headless Chrome at the ALREADY-PUBLIC live build
# (https://voxiverse.game-host.org) — no game code or export is uploaded to the box.
# soak.mjs asserts a real GPU (UNMASKED_RENDERER): SwiftShader/llvmpipe => exit 1.
#
# TEARDOWN GUARANTEE: the instance is destroyed in an EXIT/INT/TERM trap, so it is
# torn down even on failure, Ctrl-C, or a mid-run error. The instance id is read back
# from the state file if the shell variable was never set, so teardown cannot "lose"
# the instance. Pass --keep to leave it up for debugging (you then destroy it yourself).
#
# Usage:
#   ./run-remote.sh                          # live site, 900s, cap $0.30/hr T4
#   ./run-remote.sh --duration 300           # shorter soak
#   ./run-remote.sh --url http://host/       # a different origin
#   ./run-remote.sh --gpu L4 --max-price 0.50
#   ./run-remote.sh --keep                   # don't auto-destroy (debug)
set -euo pipefail
VAST_TAG=run-remote
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vast-common.sh
. "$HERE/lib/vast-common.sh"

# ── defaults ────────────────────────────────────────────────────────────────────
URL="https://voxiverse.game-host.org"
DURATION="900"
MAX_PRICE="0.30"
DISK="32"
GPU_NAME="Tesla_T4"
IMAGE="nvidia/cuda:12.4.1-runtime-ubuntu22.04"
KEEP=0
STATE_FILE="$HERE/results/vast-instance.env"
REMOTE_DIR="/root/web-soak-gpu"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes)

while [ $# -gt 0 ]; do
  case "$1" in
    --url)        URL="$2"; shift 2 ;;
    --duration)   DURATION="$2"; shift 2 ;;
    --max-price)  MAX_PRICE="$2"; shift 2 ;;
    --disk)       DISK="$2"; shift 2 ;;
    --gpu)        GPU_NAME="$2"; shift 2 ;;
    --image)      IMAGE="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    --keep)       KEEP=1; shift ;;
    -h|--help)    grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

START_EPOCH="$(date +%s)"
INSTANCE_ID=""
DPH="0"
DESTROYED=0

# ── teardown (ALWAYS runs) ───────────────────────────────────────────────────────
# shellcheck disable=SC2317  # body is reached only via the EXIT/INT/TERM trap
teardown() {
  local ec="${1:-$?}"
  trap - EXIT INT TERM
  if [ "$DESTROYED" = "1" ]; then exit "$ec"; fi
  # Recover the id from the state file if we never captured it in-shell.
  if [ -z "$INSTANCE_ID" ] && [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    INSTANCE_ID="${VAST_INSTANCE_ID:-}"
    DPH="${VAST_DPH:-$DPH}"
  fi
  if [ "$KEEP" = "1" ] && [ -n "$INSTANCE_ID" ]; then
    warn "--keep set; NOT destroying instance $INSTANCE_ID. Destroy it yourself:  vastai destroy instance $INSTANCE_ID"
  elif [ -n "$INSTANCE_ID" ]; then
    log "TEARDOWN: destroying instance $INSTANCE_ID …"
    if vast destroy instance "$INSTANCE_ID"; then
      DESTROYED=1
      rm -f "$STATE_FILE"
    else
      warn "destroy FAILED — DESTROY MANUALLY NOW to stop billing:  vastai destroy instance $INSTANCE_ID"
    fi
  else
    log "no instance was created; nothing to tear down."
  fi
  local mins=$(( ( $(date +%s) - START_EPOCH + 59 ) / 60 ))
  spend_estimate "$mins" "$DPH"
  exit "$ec"
}
# EXIT passes the script's final status; INT/TERM force a non-zero code so an
# interrupted run is never mistaken for a clean pass (teardown still destroys).
trap 'teardown $?' EXIT
trap 'teardown 130' INT
trap 'teardown 143' TERM

vast_preflight

# ── 1. provision ────────────────────────────────────────────────────────────────
log "== 1/6 provision cheapest verified $GPU_NAME (<= \$$MAX_PRICE/hr) =="
INSTANCE_ID="$("$HERE/provision-vast.sh" \
  --gpu "$GPU_NAME" --max-price "$MAX_PRICE" --disk "$DISK" \
  --image "$IMAGE" --state-file "$STATE_FILE")"
[ -n "$INSTANCE_ID" ] || die "provision returned no instance id"
# shellcheck disable=SC1090
. "$STATE_FILE"
DPH="${VAST_DPH:-0}"
log "instance $INSTANCE_ID at \$$DPH/hr"

# ── 2. wait for running + ssh ────────────────────────────────────────────────────
log "== 2/6 wait for running + ssh =="
wait_running "$INSTANCE_ID" 600
read -r SSH_HOST SSH_PORT SSH_USER < <(get_ssh "$INSTANCE_ID") \
  || die "could not resolve ssh endpoint for $INSTANCE_ID"
log "ssh endpoint: $SSH_USER@$SSH_HOST:$SSH_PORT"
wait_ssh "$SSH_HOST" "$SSH_PORT" "$SSH_USER" 300

ssh_box()   { ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"; }
RSYNC_RSH="ssh ${SSH_OPTS[*]} -p $SSH_PORT"

# ── 3. rsync harness -> box ──────────────────────────────────────────────────────
log "== 3/6 rsync harness -> box:$REMOTE_DIR =="
ssh_box "mkdir -p $REMOTE_DIR"
rsync -az --delete \
  --exclude 'node_modules' --exclude 'results' --exclude '*.log' \
  --exclude 'baseline' \
  -e "$RSYNC_RSH" \
  "$HERE/" "$SSH_USER@$SSH_HOST:$REMOTE_DIR/"

# ── 4. setup box ─────────────────────────────────────────────────────────────────
log "== 4/6 setup box (deps + GPU validation) =="
ssh_box "HARNESS_DIR=$REMOTE_DIR bash $REMOTE_DIR/setup-box.sh"

# ── 5. run the soak against the LIVE site ────────────────────────────────────────
log "== 5/6 soak: $URL for ${DURATION}s (headful chromium under xvfb, real-GPU gate) =="
set +e
ssh_box "cd $REMOTE_DIR && xvfb-run -a node soak.mjs --gpu --url '$URL' --duration '$DURATION' --out results"
SOAK_EC=$?
set -e
log "soak exit=$SOAK_EC"

# ── 6. pull results back (ALWAYS, even on soak failure) ───────────────────────────
log "== 6/6 pull results =="
LOCAL_OUT="$HERE/results/gpu-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOCAL_OUT"
rsync -az -e "$RSYNC_RSH" \
  "$SSH_USER@$SSH_HOST:$REMOTE_DIR/results/" "$LOCAL_OUT/" \
  || warn "results pull failed (soak may not have produced any)"
log "results -> $LOCAL_OUT"
[ -f "$LOCAL_OUT/latest.json" ] && log "sign-off artefact: $LOCAL_OUT/latest.json"

if [ "$SOAK_EC" -ne 0 ]; then
  warn "SOAK FAILED (exit $SOAK_EC). Common cause: real-GPU gate rejected a software renderer, or a perf/heap threshold. See $LOCAL_OUT/latest.json."
fi

# teardown (destroy + spend estimate) runs on EXIT via the trap.
exit "$SOAK_EC"
