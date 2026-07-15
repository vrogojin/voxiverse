#!/usr/bin/env bash
# setup-box.sh — provision the RENTED GPU box for a web-soak run. Runs ON the box
# (invoked over ssh by run-remote.sh, or as an onstart command).
#
# Installs: Xvfb + vulkan-tools + Chromium system libs + Node LTS + the harness'
# npm deps + the Playwright chromium browser. Then VALIDATES the real GPU is visible
# to both CUDA (nvidia-smi) and Vulkan (vulkaninfo) — a software-only Vulkan (llvmpipe)
# is a HARD FAIL here, because the whole point of Tier-B is a real GPU.
#
# The harness itself is expected at $HARNESS_DIR (default /root/web-soak-gpu),
# rsync'd there by run-remote.sh before this runs.
#
# Env:
#   HARNESS_DIR     where the harness lives on the box (default /root/web-soak-gpu)
#   INSTALL_CHROME  =1 to also install Google Chrome stable (default 0; Playwright's
#                   bundled chromium is what soak.mjs launches, so Chrome is optional)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
HARNESS_DIR="${HARNESS_DIR:-/root/web-soak-gpu}"

log() { printf '\n[setup-box] %s\n' "$*"; }

log "apt-get update + base packages (Xvfb, Vulkan tools, Chromium libs, rsync)…"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg xz-utils rsync \
  xvfb x11-utils \
  vulkan-tools libvulkan1 \
  libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
  libpango-1.0-0 libcairo2 libatspi2.0-0 fonts-liberation

# ── Node LTS (20.x) via NodeSource ────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  log "installing Node LTS (20.x)…"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
log "node $(node --version), npm $(npm --version)"

# ── optional Google Chrome stable ─────────────────────────────────────────────
if [ "${INSTALL_CHROME:-0}" = "1" ] && ! command -v google-chrome >/dev/null 2>&1; then
  log "installing Google Chrome stable…"
  wget -qO /tmp/google-chrome.deb \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y /tmp/google-chrome.deb || apt-get -f install -y
fi

# ── GPU validation (fail CLOSED if the GPU / Vulkan ICD is not really present) ──
log "nvidia-smi (CUDA userspace must see the GPU):"
if ! nvidia-smi; then
  echo "[setup-box] FATAL: nvidia-smi failed — no GPU visible to the container." >&2
  exit 2
fi

log "vulkaninfo (Vulkan must see the REAL GPU, not llvmpipe):"
VK="$(vulkaninfo 2>/dev/null || true)"
if ! printf '%s' "$VK" | grep -iqE 'deviceName|GPU id'; then
  echo "[setup-box] FATAL: vulkaninfo found no Vulkan device." >&2
  echo "[setup-box] The NVIDIA Vulkan ICD is missing — the container needs the 'graphics'" >&2
  echo "[setup-box] driver capability. Recreate with NVIDIA_DRIVER_CAPABILITIES=all." >&2
  exit 2
fi
printf '%s' "$VK" | grep -iE 'deviceName' | head -4
if printf '%s' "$VK" | grep -iE 'deviceName' | grep -iq 'llvmpipe'; then
  echo "[setup-box] FATAL: Vulkan resolves to llvmpipe (SOFTWARE), not the GPU." >&2
  echo "[setup-box] Recreate the instance with NVIDIA_DRIVER_CAPABILITIES=all." >&2
  exit 2
fi

# ── harness npm deps + Playwright browser ─────────────────────────────────────
[ -d "$HARNESS_DIR" ] || { echo "[setup-box] FATAL: harness not found at $HARNESS_DIR" >&2; exit 2; }
cd "$HARNESS_DIR"
log "npm install (harness deps)…"
npm install --no-audit --no-fund
log "playwright install chromium (+ system deps)…"
npx --yes playwright install --with-deps chromium

log "setup complete — box is ready for:  xvfb-run -a node soak.mjs --gpu --url <URL>"
