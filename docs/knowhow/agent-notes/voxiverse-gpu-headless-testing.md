---
name: voxiverse-gpu-headless-testing
description: "How to automate rendered-outcome tests (frame-timing, visuals, heap-under-render) for VOXIVERSE despite no GPU on the build host"
metadata: 
  node_type: memory
  type: reference
---

Our build/CI host has NO usable GPU (AMD 164e present but no /dev/dri/libEGL/libvulkan exposed), so `--headless` verify scripts test logic/invariants only — not rendering, real worst-frame, visual correctness, or heap-under-render. Research (2026-07-14, 3-agent sweep) concluded two tiers. See [[voxiverse-faceted-planet]] (FP-M2's live worst-frame is exactly the gap this closes).

**Tier A — native, buildable NOW on our host (~0.5–1 day):** Godot 4.4 has no offscreen-GPU flag; run the native `opengl3` renderer under `xvfb-run` + Mesa `llvmpipe` (software). Because the project is locked to the **Compatibility renderer — the same path web uses** — this faithfully catches render crashes, broken shaders, disappeared geometry, and heap-under-render (`Performance.MEMORY_STATIC`/`RENDER_*_MEM_USED`), plus `get_viewport().get_texture().get_image().save_png()` visual-regression after `await RenderingServer.frame_post_draw`. Needs a real running main loop (not the `--script` one-shot). Frame-timing is CPU-rendered → NOT representative of real FPS. Extend the `verify_feature.gd` pattern into a `soak_render.gd`.

**Tier B — real web worst-frame/heap, needs a cloud GPU (~2–3 days):** the production metric requires the WASM build in a GPU-backed headless Chrome. 2026 recipe (traps: SwiftShader no longer auto-falls-back in Chrome 137+; the popular `--headless=new --disable-vulkan-surface` recipe disables canvas): run Chrome **headful under `xvfb-run`** (NOT `--headless`) with `--use-gl=angle --use-angle=vulkan --enable-features=Vulkan`, Playwright serving `build/web/` with COOP/COEP on every response, scrape the `[PERF]` console line + `performance.measureUserAgentSpecificMemory()` (needs crossOriginIsolated, which we already have) + canvas screenshots (need `preserveDrawingBuffer` — a small game-side tweak). Gate every run on `UNMASKED_RENDERER_WEBGL` ≠ SwiftShader/llvmpipe. It's a regression/floor signal on pinned hardware, not a per-user FPS promise (GPU-model dependent).

**Platform for Tier B:** #1 **RunsOn** (self-hosted GitHub Actions runner on AWS spot g4dn.xlarge T4) — <$1/mo compute + ~€300/yr license, native `workflow_dispatch`+artifact; #2 **Vast.ai** T4 $0.13–0.20/hr (DIY orchestration); fallback official GitHub GPU runner $0.07/min (~$12/mo). Use a full-VM platform (not CUDA-first serverless like Modal/Cloud Run) so the container exposes graphics (`NVIDIA_DRIVER_CAPABILITIES` graphics/display) — 30-min smoke test to confirm before committing.
