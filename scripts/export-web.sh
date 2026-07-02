#!/usr/bin/env bash
# VOXIVERSE — headless Web export of the Godot project.
#
# Runs the custom Godot 4.4.1 editor (built by scripts/build.sh, WITH godot_voxel)
# headless inside the toolchain container, installs our custom Web export
# templates, imports the project and exports the "Web" preset to build/web/.
#
#   ./scripts/export-web.sh
#
# Output: build/web/{index.html,index.wasm,index.pck,index.js,...}
#
# Requires (produced by scripts/build.sh first):
#   docker/engine/bin/godot.linuxbsd.editor.x86_64
#   docker/engine/templates/web_release.zip  (+ web_debug.zip)
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="${REPO_ROOT}/docker/engine"
# shellcheck source=../docker/engine/versions.env
source "${ENGINE_DIR}/versions.env"

PROJECT_DIR="${REPO_ROOT}/godot"
TEMPLATES_DIR="${ENGINE_DIR}/templates"
BIN="${ENGINE_DIR}/bin/godot.linuxbsd.editor.x86_64"
OUT_DIR="${REPO_ROOT}/build/web"
PRESET="${PRESET:-Web}"

# --- Preflight -------------------------------------------------------------
missing=0
if [ ! -x "${BIN}" ]; then
  echo "!!! Missing editor binary: ${BIN}"
  echo "    Run ./scripts/build.sh first."
  missing=1
fi
if [ ! -f "${TEMPLATES_DIR}/web_release.zip" ]; then
  echo "!!! Missing Web export template: ${TEMPLATES_DIR}/web_release.zip"
  echo "    Run ./scripts/build.sh first."
  missing=1
fi
if [ ! -f "${PROJECT_DIR}/project.godot" ]; then
  echo "!!! No Godot project yet at ${PROJECT_DIR}/project.godot."
  echo "    This script is correct and ready — re-run once Stream B has created the project."
  # Not an error: the project is authored by another stream.
  exit 0
fi
if [ ! -f "${PROJECT_DIR}/export_presets.cfg" ]; then
  echo "!!! ${PROJECT_DIR}/export_presets.cfg is missing — cannot export preset '${PRESET}'."
  echo "    Stream B must define an export preset named '${PRESET}' (platform: Web)."
  exit 0
fi
if ! grep -q "name=\"${PRESET}\"" "${PROJECT_DIR}/export_presets.cfg"; then
  echo "!!! export_presets.cfg has no preset named '${PRESET}'."
  echo "    Presets found:"; grep 'name=' "${PROJECT_DIR}/export_presets.cfg" || true
  exit 0
fi
[ "${missing}" = "1" ] && exit 1

mkdir -p "${OUT_DIR}"

# --- Export inside the toolchain container (has GL/X11/alsa runtime libs) ---
# HOME=/gdhome (a writable tmpfs) so the editor's XDG data dir — where export
# templates are looked up as export_templates/<ver>/ — is under our control.
echo "==> Exporting project -> ${OUT_DIR} using preset '${PRESET}' (templates ${GODOT_TEMPLATE_VERSION}) ..."
# NOTE: the image's ENTRYPOINT is build-engine.sh (the compile driver). For the
# export we override it to bash — otherwise our command is passed as *arguments*
# to build-engine.sh, which then tries to mkdir the root-owned /work caches and
# aborts. EM_CACHE/SCONS_CACHE are also pointed at the writable tmpfs so nothing
# in the toolchain env can touch the root-owned /work during export.
docker run --rm \
  -u "$(id -u):$(id -g)" \
  -e HOME=/gdhome \
  -e EM_CACHE=/gdhome/emcache \
  -e SCONS_CACHE=/gdhome/scons-cache \
  --tmpfs /gdhome:exec \
  --entrypoint /bin/bash \
  -v "${BIN}:/usr/local/bin/godot:ro" \
  -v "${PROJECT_DIR}:/project" \
  -v "${TEMPLATES_DIR}:/templates:ro" \
  -v "${OUT_DIR}:/out" \
  "${ENGINE_IMAGE}" \
  -c '
    set -Eeuo pipefail
    TPL_DIR="/gdhome/.local/share/godot/export_templates/'"${GODOT_TEMPLATE_VERSION}"'"
    mkdir -p "${TPL_DIR}"
    cp -f /templates/web_release.zip "${TPL_DIR}/web_release.zip"
    [ -f /templates/web_debug.zip ] && cp -f /templates/web_debug.zip "${TPL_DIR}/web_debug.zip"
    echo "==> Godot version:"; godot --version || true
    echo "==> Importing project resources (headless) ..."
    # First headless run imports assets and generates the .godot/ cache.
    godot --headless --path /project --import || true
    echo "==> Exporting Web preset ..."
    godot --headless --path /project --export-release "'"${PRESET}"'" /out/index.html
  '

echo
echo "==> Web export contents:"
ls -lh "${OUT_DIR}" || true
if [ -f "${OUT_DIR}/index.html" ] && [ -f "${OUT_DIR}/index.wasm" ]; then
  echo "==> OK: build/web/ is ready to serve (index.html + index.wasm present)."
else
  echo "!!! Export finished but index.html/index.wasm not found — check output above."
  exit 1
fi
