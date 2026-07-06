#!/usr/bin/env bash
# VOXIVERSE — build the custom Godot 4.4.1 engine (+ godot_voxel) and the Web
# export templates, in Docker, with one command.
#
#   ./scripts/build.sh              # build image (if needed) + linux editor + web templates
#   ./scripts/build.sh --rebuild    # force docker image rebuild first
#   SKIP_LINUX=1 ./scripts/build.sh # only web templates
#   SKIP_WEB=1   ./scripts/build.sh # only native editor
#   FORCE_STOCK_WEB=1 ./scripts/build.sh   # web templates WITHOUT the module (stock)
#
# Outputs (git-ignored, left in working tree — NOT committed):
#   docker/engine/bin/godot.linuxbsd.editor.x86_64
#   docker/engine/templates/web_release.zip
#   docker/engine/templates/web_debug.zip
#   docker/engine/templates/BUILD-INFO.txt
# Heavy build artifacts (source tree, scons cache, emcache) live under
#   docker/engine/cache/   (git-ignored)
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="${REPO_ROOT}/docker/engine"
# shellcheck source=../docker/engine/versions.env
source "${ENGINE_DIR}/versions.env"

CACHE_DIR="${ENGINE_DIR}/cache"
TEMPLATES_DIR="${ENGINE_DIR}/templates"
BIN_DIR="${ENGINE_DIR}/bin"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "${CACHE_DIR}" "${TEMPLATES_DIR}" "${BIN_DIR}"

# --- 1. Toolchain image ----------------------------------------------------
REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1
if [ "${REBUILD}" = "1" ] || ! docker image inspect "${ENGINE_IMAGE}" >/dev/null 2>&1; then
  echo "==> Building toolchain image ${ENGINE_IMAGE} (emsdk ${EMSDK_VERSION}) ..."
  docker build \
    --build-arg "EMSDK_VERSION=${EMSDK_VERSION}" \
    -t "${ENGINE_IMAGE}" \
    -f "${ENGINE_DIR}/Dockerfile" \
    "${ENGINE_DIR}"
else
  echo "==> Reusing toolchain image ${ENGINE_IMAGE} (pass --rebuild to force)"
fi

# --- 2. Compile inside the container ---------------------------------------
echo "==> Compiling Godot ${GODOT_REF} + godot_voxel ${VOXEL_REF} (jobs=${JOBS}) ..."
echo "    This is the long pole: expect ~20-45 min cold, minutes when cached."
docker run --rm \
  -u "$(id -u):$(id -g)" \
  -e HOME=/work \
  -e GODOT_REF="${GODOT_REF}" \
  -e VOXEL_REF="${VOXEL_REF}" \
  -e JOBS="${JOBS}" \
  -e SKIP_LINUX="${SKIP_LINUX:-0}" \
  -e SKIP_WEB="${SKIP_WEB:-0}" \
  -e FORCE_STOCK_WEB="${FORCE_STOCK_WEB:-0}" \
  -v "${CACHE_DIR}:/work" \
  -v "${TEMPLATES_DIR}:/out/templates" \
  -v "${BIN_DIR}:/out/bin" \
  -v "${ENGINE_DIR}/patches:/patches:ro" \
  "${ENGINE_IMAGE}"

echo
echo "==> Artifacts:"
ls -lh "${BIN_DIR}" 2>/dev/null || true
ls -lh "${TEMPLATES_DIR}" 2>/dev/null || true
echo "==> Done. See docker/engine/templates/BUILD-INFO.txt for provenance."
