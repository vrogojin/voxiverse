# Tier-A rendered-soak runtime image (task #104).
#
# Standalone from the ENGINE build image: this adds ONLY the software-GL + virtual-X + image-diff
# runtime the rendered soak needs, on top of the toolchain base (which already carries the exact
# glibc/X client ABI the native godot binary was linked against, plus Mesa swrast_dri.so + libEGL +
# libgbm). It does NOT rebuild the engine — build with scripts/render-soak.sh, seconds not minutes.
FROM voxiverse/godot-build:4.4

# xvfb            — virtual X server (no GPU / no physical display on CI)
# x11-utils       — xdpyinfo etc. for probing the virtual display
# mesa-utils      — glxinfo (renderer identification / debugging)
# libgl1-mesa-dri — the llvmpipe/swrast software rasteriser DRI driver
# libegl1         — EGL loader (GL Compatibility context creation)
# imagemagick     — perceptual golden-compare (compare / identify)
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb x11-utils mesa-utils libgl1-mesa-dri libegl1 imagemagick \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/bin/bash"]
