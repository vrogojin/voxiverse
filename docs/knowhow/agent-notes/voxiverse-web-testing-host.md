---
name: voxiverse-web-testing-host
description: "dev host has NO GPU and lacks Chrome's system libs; rootless workaround to run Playwright here; real GPU web-soak must run on a cloud T4"
metadata: 
  node_type: memory
  type: reference
---

The VOXIVERSE dev host (`~/voxiverse`) has **no GPU** and **no sudo**, and
is missing the shared libs Playwright's Chromium needs (`libnspr4`, `libnss3`,
`libasound2`, `libgbm1`, `libwayland-server0`). So the real Tier-B GPU web-soak
(`tools/web-soak-gpu`, real `UNMASKED_RENDERER` + worst-frame) CANNOT run here — it must
run on a cloud NVIDIA T4 (AWS g4dn spot / Vast.ai), headful under `xvfb-run`, per that
dir's README.

To run Playwright/Chromium locally for the CPU-fallback SMOKE only (software SwiftShader):
1. `cd tools/web-soak-gpu && npm install && npx playwright install chromium` (network OK; browsers cache under `~/.cache/ms-playwright`).
2. Rootless system libs: `apt-get download libnspr4 libnss3 libasound2 libgbm1 libwayland-server0` into a temp dir, `dpkg -x each.deb ./root`, then export `LD_LIBRARY_PATH=<dir>/root/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH` before `node soak.mjs`. (`apt-get download`/`dpkg -x` work without root.)

Gotcha: `performance.measureUserAgentSpecificMemory()` throws `SecurityError: not
available` in `chrome-headless-shell` (headless:true) — the harness falls back to
`performance.memory.usedJSHeapSize`. The measure-memory primary works only in
full/headful Chrome (the cloud `--gpu` run). See [[voxiverse-never-oom-web]].
