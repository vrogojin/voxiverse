# VOXIVERSE engine toolchain
# ---------------------------
# Reproducible image that can compile:
#   * a native Linux (linuxbsd) headless Godot 4.4.1 EDITOR that includes the
#     Zylann godot_voxel module (used to run `--headless --export-release "Web"`)
#   * the Web (Emscripten) export templates (web_release.zip / web_debug.zip)
#     compiled WITH the godot_voxel module.
#
# Base: official Emscripten SDK image, pinned to the exact emsdk version that
# Godot 4.4.1 CI builds its web templates with. Using a MATCHING emsdk is the
# #1 cause of web build failures, so it is hard-pinned here.
#   Godot 4.4.1-stable .github/workflows/web_builds.yml -> EM_VERSION: 3.1.64
#
# The actual (heavy) compile is NOT baked into the image. It runs at
# `docker run` time via build-engine.sh, with the Godot source tree, the SCons
# object cache and the emscripten cache all bind-mounted from
# docker/engine/cache/ so repeated builds are fast and reproducible.
ARG EMSDK_VERSION=3.1.64
FROM emscripten/emsdk:${EMSDK_VERSION}

# Re-declare after FROM so it is visible in the build stage / labels.
ARG EMSDK_VERSION=3.1.64
LABEL org.opencontainers.image.title="voxiverse-godot-build" \
      org.opencontainers.image.description="Godot 4.4.1 + godot_voxel build toolchain (linuxbsd editor + web templates)" \
      org.voxiverse.emsdk="${EMSDK_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Toolchain + Godot linuxbsd editor build dependencies.
#   - scons / pkg-config / python3      : build system
#   - build-essential                   : native compiler for the linuxbsd editor
#   - libx11 / xcursor / xinerama / xi  : X11 windowing (editor build links these
#     xrandr / mesa GL / GLU              even when later run with --headless)
#   - alsa / pulse / udev               : audio + input subsystems
#   - libwayland / libxkbcommon         : wayland display backend
#   - libembree-dev is intentionally omitted (Godot bundles its own).
RUN apt-get update && apt-get install -y --no-install-recommends \
        scons \
        pkg-config \
        build-essential \
        git ca-certificates \
        python3 python3-pip \
        libx11-dev libxcursor-dev libxinerama-dev libxi-dev libxrandr-dev \
        libgl1-mesa-dev libglu1-mesa-dev \
        libasound2-dev libpulse-dev libudev-dev \
        libwayland-dev libxkbcommon-dev \
        yasm xz-utils zip unzip \
    && rm -rf /var/lib/apt/lists/*

# build-engine.sh drives clone + compile of both targets inside the container.
COPY build-engine.sh /usr/local/bin/build-engine.sh
RUN chmod +x /usr/local/bin/build-engine.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/build-engine.sh"]
