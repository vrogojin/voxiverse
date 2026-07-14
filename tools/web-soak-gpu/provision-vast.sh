#!/usr/bin/env bash
# provision-vast.sh — rent the CHEAPEST verified Vast.ai T4 (or L4) GPU box.
#
# Searches Vast.ai for verified/rentable offers matching the GPU + disk, picks the
# cheapest that is at or below --max-price, prints the $/hr BEFORE creating, creates
# the instance (with the NVIDIA graphics capability so Vulkan works — see note), and
# writes the instance id + $/hr to a state file so teardown always has something to
# destroy. Prints ONLY the new instance id on stdout.
#
# Refuses to do anything without an API key. Never exceeds --max-price.
#
# Usage:
#   ./provision-vast.sh [--gpu Tesla_T4] [--max-price 0.30] [--disk 32]
#                       [--image <img>] [--state-file <path>] [--label <name>]
set -euo pipefail
VAST_TAG=provision
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vast-common.sh
. "$HERE/lib/vast-common.sh"

# ── defaults ────────────────────────────────────────────────────────────────────
GPU_NAME="Tesla_T4"        # Vast.ai gpu_name for the NVIDIA T4; L4 = "L4"
MAX_PRICE="0.30"           # hard cap ($/hr) we will not exceed
DISK="32"                  # GB; Chrome + node_modules + playwright browser fit easily
# CUDA runtime image on Ubuntu 22.04. Vulkan/GL come from the host driver, injected by
# the nvidia container runtime ONLY when the container has the 'graphics' capability —
# which is why we set NVIDIA_DRIVER_CAPABILITIES=all at create time (below).
IMAGE="nvidia/cuda:12.4.1-runtime-ubuntu22.04"
STATE_FILE="$HERE/results/vast-instance.env"
LABEL="voxiverse-web-soak"

while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)        GPU_NAME="$2"; shift 2 ;;
    --max-price)  MAX_PRICE="$2"; shift 2 ;;
    --disk)       DISK="$2"; shift 2 ;;
    --image)      IMAGE="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    --label)      LABEL="$2"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

vast_preflight

# ── search ──────────────────────────────────────────────────────────────────────
# verified=true  -> vetted datacenter machines (stable, real GPUs)
# rentable=true  -> currently available
# order dph_total (ascending) -> cheapest first; pick-offer re-sorts + caps as a guard.
QUERY="gpu_name=${GPU_NAME} verified=true rentable=true disk_space>=${DISK} cuda_max_good>=12"
log "searching verified offers: [$QUERY]  cap=\$$MAX_PRICE/hr"
OFFERS_JSON="$(vast search offers "$QUERY" -o 'dph_total' --raw)" \
  || die "vastai search offers failed"

PICK="$(printf '%s' "$OFFERS_JSON" | node "$HERE/lib/vastjson.mjs" \
          pick-offer --max-price "$MAX_PRICE" --min-disk "$DISK")" || {
  rc=$?
  [ "$rc" = "3" ] && die "no verified ${GPU_NAME} offer <= \$$MAX_PRICE/hr with >=${DISK}GB disk. Raise --max-price or lower --disk."
  die "offer selection failed (rc=$rc)"
}
read -r OFFER_ID DPH OGPU ODISK <<<"$PICK"
log "cheapest match: offer=$OFFER_ID  \$$DPH/hr  gpu=$OGPU  disk=${ODISK}GB"

# ── hard price guard (belt + suspenders over pick-offer) ─────────────────────────
awk -v d="$DPH" -v c="$MAX_PRICE" 'BEGIN{ exit !(d+0 <= c+0) }' \
  || die "picked dph $DPH exceeds cap $MAX_PRICE — aborting (this should never happen)"

# ── create ──────────────────────────────────────────────────────────────────────
log "creating instance from offer $OFFER_ID at \$$DPH/hr (image=$IMAGE disk=${DISK}GB)…"
CREATE_JSON="$(vast create instance "$OFFER_ID" \
  --image "$IMAGE" \
  --disk "$DISK" \
  --ssh --direct \
  --env '-e NVIDIA_DRIVER_CAPABILITIES=all -e NVIDIA_VISIBLE_DEVICES=all' \
  --label "$LABEL" \
  --raw)" || die "vastai create instance failed"

NEW_ID="$(printf '%s' "$CREATE_JSON" | node "$HERE/lib/vastjson.mjs" field new_contract)" \
  || die "could not parse new instance id from create output: $CREATE_JSON"
[ -n "$NEW_ID" ] || die "empty instance id from create"

# Persist state IMMEDIATELY so an interrupt after this line still lets teardown destroy.
write_state "$STATE_FILE" "$NEW_ID" "$DPH" "$OFFER_ID"
log "instance $NEW_ID created; state -> $STATE_FILE"

# stdout: ONLY the id (run-remote.sh captures this)
printf '%s\n' "$NEW_ID"
