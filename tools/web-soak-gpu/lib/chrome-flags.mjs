// Chromium launch-flag recipes for the two soak modes.
//
// ── The 2026 hard-won facts (do NOT "simplify" these) ──────────────────────────
//
//  * Chrome 137+ no longer auto-falls-back to SwiftShader — it FAILS CLOSED. If the
//    box has no working GPU/driver, WebGL is simply unavailable; there is no silent
//    software path. So on a GPU box you either get the real GPU or nothing, which is
//    exactly why the UNMASKED_RENDERER gate (soak.mjs) is load-bearing.
//
//  * The popular `--headless=new --use-angle=vulkan --disable-vulkan-surface`
//    recipe DISABLES canvas drawing. It is WRONG for us — we render to a canvas.
//    Do not add --disable-vulkan-surface, and do not use --headless for GPU mode.
//
//  * THE RECIPE THAT WORKS on a Linux GPU box: run Chromium HEADFUL (NOT --headless)
//    under `xvfb-run`, with ANGLE-over-Vulkan. Playwright launches headful when
//    `headless:false`; you wrap the whole `node soak.mjs --gpu` invocation in
//    `xvfb-run -a` so there is a virtual X display for the headful browser.
//    See README "Cloud T4 run recipe".

// GPU MODE — the REAL test. Requires: a real GPU + driver + Vulkan ICD on the box,
// and the process launched under `xvfb-run -a` (headful needs a display).
export const GPU_FLAGS = [
  '--use-gl=angle',
  '--use-angle=vulkan',
  '--enable-features=Vulkan',
  '--disable-gpu-blocklist',
  '--ignore-gpu-blocklist',
  '--no-sandbox', // required as root / in most CI + cloud spot images
  '--disable-dev-shm-usage', // small /dev/shm on cloud images crashes the renderer
  '--enable-precise-memory-info', // un-bucketed performance.memory (heap fallback)
];

// CPU-FALLBACK MODE — a LOCAL SMOKE ONLY, never the real gate. Forces ANGLE over
// SwiftShader (software rasteriser) so the harness plumbing (boot, [PERF] scrape,
// heap API, soak driving) can be proven on a box with no GPU. The UNMASKED_RENDERER
// will read "SwiftShader"/"llvmpipe" — which is precisely what the real-GPU gate
// must REJECT. Clearly labelled in all output as CPU-only.
export const CPU_FALLBACK_FLAGS = [
  '--use-gl=angle',
  '--use-angle=swiftshader',
  '--enable-unsafe-swiftshader', // Chrome 137+: opt back into software WebGL for the smoke
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--enable-precise-memory-info', // un-bucketed performance.memory (heap fallback)
];

// Substrings that mark a SOFTWARE renderer. If UNMASKED_RENDERER_WEBGL matches any
// of these, we are NOT on a real GPU — the gate fails (in --gpu mode) or is expected
// (in --cpu-fallback mode).
export const SOFTWARE_RENDERER_MARKERS = [
  'swiftshader',
  'llvmpipe',
  'software',
  'microsoft basic render',
  'mesa offscreen',
  'softpipe',
];

export function isSoftwareRenderer(renderer) {
  if (!renderer) return true; // no renderer string at all => treat as not-a-real-GPU
  const r = String(renderer).toLowerCase();
  return SOFTWARE_RENDERER_MARKERS.some((m) => r.includes(m));
}

// mode -> { flags, headless } for playwright chromium.launch()
export function launchProfile(mode) {
  if (mode === 'gpu') {
    return { flags: GPU_FLAGS, headless: false }; // headful under xvfb
  }
  // cpu-fallback: headless is fine (and simpler) for the software smoke
  return { flags: CPU_FALLBACK_FLAGS, headless: true };
}
