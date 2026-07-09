#!/usr/bin/env bash
# Compile Godot 4.4.1 + Zylann godot_voxel INSIDE the toolchain container.
#
# Produces:
#   /out/bin/godot.linuxbsd.editor.x86_64   native headless editor (with voxel)
#   /out/templates/web_release.zip          Web export template (threads)
#   /out/templates/web_debug.zip            Web export template (threads, debug)
#   /out/templates/BUILD-INFO.txt           provenance + whether module is in web
#
# The Godot source tree, SCons object cache and emscripten cache all live under
# /work (bind-mounted to docker/engine/cache/) so repeat runs are incremental.
#
# Env knobs (all optional):
#   GODOT_REF   git ref of godotengine/godot        (default 4.4.1-stable)
#   VOXEL_REF   git ref of Zylann/godot_voxel        (default v1.4.1)
#   JOBS        parallel compile jobs                (default: nproc)
#   SKIP_LINUX  =1 to skip the native editor build
#   SKIP_WEB    =1 to skip the web template build
#   FORCE_STOCK_WEB =1 to build web templates WITHOUT the module (stock)
set -Eeuo pipefail

GODOT_REF="${GODOT_REF:-4.4.1-stable}"
VOXEL_REF="${VOXEL_REF:-v1.4.1}"
JOBS="${JOBS:-$(nproc)}"

WORK=/work
SRC="${WORK}/godot"
VOXEL_DIR="${SRC}/modules/voxel"
OUT=/out
export SCONS_CACHE="${WORK}/scons-cache"
export EM_CACHE="${WORK}/emcache"

mkdir -p "${WORK}" "${OUT}/bin" "${OUT}/templates" "${SCONS_CACHE}" "${EM_CACHE}"

# We run as the host uid (bind mounts stay host-owned). Git refuses to operate on
# a tree whose owner differs from the process uid unless it is marked safe.
git config --global --add safe.directory '*' 2>/dev/null || true

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!!! %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Source checkout (shallow, pinned to a tag). Cached across runs.
# ---------------------------------------------------------------------------
clone_pinned() {
  local url="$1" dir="$2" ref="$3"
  if [ ! -d "${dir}/.git" ]; then
    log "Cloning ${url} @ ${ref}"
    git clone --depth 1 --branch "${ref}" "${url}" "${dir}"
  else
    log "Reusing cached checkout ${dir} (fetching ${ref})"
    git -C "${dir}" fetch --depth 1 origin "${ref}" || true
    git -C "${dir}" checkout -f "${ref}" 2>/dev/null || \
      git -C "${dir}" checkout -f FETCH_HEAD
    # checkout -f resets TRACKED files but leaves untracked ones. A patch that ADDS a file (e.g. 0003's
    # cosmos_bake.h) creates it untracked via `git apply`, so a warm rebuild would find it "already exists"
    # and the apply would FATAL. Clean untracked files so every warm build starts truly pristine like a
    # fresh clone. Excludes are unnecessary — the module tree carries no build outputs (those live elsewhere).
    git -C "${dir}" clean -fdq
  fi
}

clone_pinned "https://github.com/godotengine/godot.git"      "${SRC}"       "${GODOT_REF}"
clone_pinned "https://github.com/Zylann/godot_voxel.git"     "${VOXEL_DIR}" "${VOXEL_REF}"

# ---------------------------------------------------------------------------
# 1b. Apply in-repo patches to godot_voxel.
#     clone_pinned() just did `git checkout -f <ref>` above, so the module tree
#     is pristine — applying here is idempotent per run. A patch that fails to
#     apply is FATAL: a silently-unpatched build is the #1 failure mode.
#     Patches are mounted read-only at /patches (see scripts/build.sh).
# ---------------------------------------------------------------------------
PATCH_DIR=/patches/godot_voxel
PATCHES_APPLIED=""
if [ -d "${PATCH_DIR}" ]; then
  shopt -s nullglob
  for p in "${PATCH_DIR}"/*.patch; do
    log "Applying godot_voxel patch: $(basename "${p}")"
    if ! git -C "${VOXEL_DIR}" apply --whitespace=nowarn "${p}"; then
      warn "FAILED to apply ${p} — refusing to build a silently-unpatched engine."
      exit 1
    fi
    PATCHES_APPLIED="${PATCHES_APPLIED} $(basename "${p}"):$(sha256sum "${p}" | cut -d' ' -f1)"
  done
  shopt -u nullglob
fi
[ -z "${PATCHES_APPLIED}" ] && PATCHES_APPLIED=" (none)"
log "godot_voxel patches:${PATCHES_APPLIED}"

log "Toolchain versions"
echo "  Godot ref     : ${GODOT_REF}   ($(git -C "${SRC}" rev-parse --short HEAD))"
echo "  godot_voxel   : ${VOXEL_REF}   ($(git -C "${VOXEL_DIR}" rev-parse --short HEAD))"
echo "  emcc          : $(emcc --version | head -n1)"
echo "  scons         : $(scons --version | head -n2 | tail -n1)"
echo "  jobs          : ${JOBS}"

cd "${SRC}"

# ---------------------------------------------------------------------------
# 2. Native linuxbsd headless EDITOR (with godot_voxel) — Stream B uses this.
# ---------------------------------------------------------------------------
if [ "${SKIP_LINUX:-0}" != "1" ]; then
  log "Building Linux headless editor (with godot_voxel) ..."
  scons platform=linuxbsd target=editor arch=x86_64 \
        module_mono_enabled=no debug_symbols=no \
        -j"${JOBS}"
  ED_BIN="$(ls -1 bin/godot.linuxbsd.editor.x86_64* | grep -v '\.zip$' | head -n1)"
  cp -f "${ED_BIN}" "${OUT}/bin/godot.linuxbsd.editor.x86_64"
  chmod +x "${OUT}/bin/godot.linuxbsd.editor.x86_64"
  log "Linux editor -> ${OUT}/bin/godot.linuxbsd.editor.x86_64"
else
  warn "SKIP_LINUX=1 — skipping native editor build"
fi

# ---------------------------------------------------------------------------
# 3. Web (Emscripten) export templates.
#    Threaded builds are the Godot 4.4 default (threads=yes) and produce
#    web_release.zip / web_debug.zip once renamed. COOP/COEP headers on the
#    serving side (Stream C nginx) enable SharedArrayBuffer for these.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source /emsdk/emsdk_env.sh >/dev/null 2>&1 || true

MODULE_IN_WEB="unknown"

build_web_templates() {
  # $1 = "release", $2 = scons target
  log "Web template: scons platform=web target=$2 (production for release) ..."
  local extra=()
  [ "$1" = "release" ] && extra+=(production=yes)
  scons platform=web target="$2" "${extra[@]}" -j"${JOBS}"
}

web_build_all() {
  build_web_templates release template_release
  build_web_templates debug   template_debug
}

if [ "${SKIP_WEB:-0}" != "1" ]; then
  DISABLED=""
  if [ "${FORCE_STOCK_WEB:-0}" = "1" ]; then
    warn "FORCE_STOCK_WEB=1 — building STOCK web templates (module moved aside)"
    mv "${VOXEL_DIR}" "${VOXEL_DIR}.disabled"; DISABLED=1
  fi
  # Restore the module on any exit so the tree stays consistent for next run.
  restore_module() { [ -n "${DISABLED}" ] && [ -d "${VOXEL_DIR}.disabled" ] && \
      mv "${VOXEL_DIR}.disabled" "${VOXEL_DIR}" && DISABLED=""; return 0; }
  trap restore_module EXIT

  if [ -z "${DISABLED}" ]; then
    # Attempt #1: web templates WITH the godot_voxel module compiled in.
    if web_build_all; then
      MODULE_IN_WEB="yes"
    else
      warn "Web build WITH godot_voxel FAILED — falling back to STOCK web template (DESIGN §2 fallback)."
      warn "The game will need its GDScript fallback mesher for the web build."
      scons platform=web target=template_release --clean >/dev/null 2>&1 || true
      scons platform=web target=template_debug   --clean >/dev/null 2>&1 || true
      mv "${VOXEL_DIR}" "${VOXEL_DIR}.disabled"; DISABLED=1
      web_build_all
      MODULE_IN_WEB="no"
    fi
  else
    web_build_all
    MODULE_IN_WEB="no"
  fi
  restore_module; trap - EXIT

  # Rename SCons outputs to the names Godot's exporter expects in the
  # export_templates/<version>/ dir. Threaded template_release -> web_release.zip
  REL_ZIP="$(ls -1 bin/godot.web.template_release.wasm32*.zip 2>/dev/null | grep -v nothreads | head -n1 || true)"
  DBG_ZIP="$(ls -1 bin/godot.web.template_debug.wasm32*.zip   2>/dev/null | grep -v nothreads | head -n1 || true)"
  [ -n "${REL_ZIP}" ] && cp -f "${REL_ZIP}" "${OUT}/templates/web_release.zip"
  [ -n "${DBG_ZIP}" ] && cp -f "${DBG_ZIP}" "${OUT}/templates/web_debug.zip"
  log "Web templates -> ${OUT}/templates/{web_release.zip,web_debug.zip}  (module_in_web=${MODULE_IN_WEB})"
else
  warn "SKIP_WEB=1 — skipping web template build"
fi

# ---------------------------------------------------------------------------
# 4. Provenance manifest.
# ---------------------------------------------------------------------------
{
  echo "VOXIVERSE engine build"
  echo "date            : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "godot_ref       : ${GODOT_REF} ($(git -C "${SRC}" rev-parse HEAD))"
  echo "godot_voxel_ref : ${VOXEL_REF} ($(git -C "${VOXEL_DIR}" rev-parse HEAD 2>/dev/null || echo n/a))"
  echo "voxel_patches   :${PATCHES_APPLIED}"
  echo "emcc            : $(emcc --version | head -n1)"
  echo "module_in_web   : ${MODULE_IN_WEB}"
  echo "templates       : $(ls -1 "${OUT}/templates"/*.zip 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
} | tee "${OUT}/templates/BUILD-INFO.txt"

log "DONE."
