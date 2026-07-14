// Tier-B web-soak driver.
//
// Launches Chromium against the REAL threaded WASM web build (build/web/) served
// with COOP/COEP, verifies cross-origin isolation + a real GPU, boots the engine,
// auto-walks the planet, scrapes the in-game [PERF] console series, samples the
// real WASM/worker heap, captures screenshots, then asserts thresholds and diffs a
// stored baseline. Exit 0 = all gates pass, 1 = any gate/threshold failed, 2 = setup
// error (no build, browser missing, etc.).
//
// The SAME script runs two ways:
//   --gpu            REAL test. Headful under xvfb (see README). Real-GPU REQUIRED:
//                    a SwiftShader/llvmpipe renderer is a HARD FAIL (Chrome 137+
//                    fails closed, so software here means the GPU path is broken).
//   --cpu-fallback   LOCAL SMOKE ONLY. Software rasteriser; proves the plumbing on a
//                    box with no GPU. By itself it also SELF-TESTS the real-GPU gate:
//                    it confirms the strict gate WOULD reject SwiftShader (exit 1).
//                    Add --allow-software to bypass that and run the full smoke.
//
// Usage:
//   node soak.mjs --gpu            [--duration 900] [--url https://voxiverse.game-host.org]
//   node soak.mjs --cpu-fallback   [--allow-software] [--duration 30]
// See `node soak.mjs --help`.

import { chromium } from 'playwright';
import { createServer } from './server.mjs';
import { launchProfile, isSoftwareRenderer } from './lib/chrome-flags.mjs';
import { parsePerfLine, parseHitchLine, summarizePerf } from './lib/perf-parse.mjs';
import { REQUIRED_ISOLATION_HEADERS } from './lib/coop-headers.mjs';
import { mkdir, writeFile, readFile, stat as fsstat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── CLI ────────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const a = {
    mode: null, // 'gpu' | 'cpu-fallback'
    allowSoftware: false,
    requireGpu: false, // force the strict real-GPU gate regardless of browser mode
    durationS: null,
    url: null, // external URL; if unset we start the local server on build/web
    root: path.resolve(__dirname, '../../build/web'),
    port: 0,
    outDir: path.resolve(__dirname, 'results'),
    shots: 6,
    baseline: path.resolve(__dirname, 'baseline/baseline.json'),
    floorMs: 18, // CTRL_FRAME_BUDGET_MS
    minPctLeFloor: 99, // % of frames that must be <= floorMs
    maxHitches: 0, // additional hitches (>33ms) allowed during the WALK phase
    heapCeilingMb: 900, // hard WASM+worker heap ceiling (NEVER-OOM guard)
    enforcePerf: null, // default: true in gpu mode, false in cpu-fallback
    regressPct: 20, // baseline regression tolerance on worst-frame p99 / heap
    bootTimeoutS: 150,
    heapEverySamples: 8, // sample heap once per this many [PERF] lines (~2s)
  };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    const next = () => argv[++i];
    switch (v) {
      case '--gpu': a.mode = 'gpu'; break;
      case '--cpu-fallback': a.mode = 'cpu-fallback'; break;
      case '--allow-software': a.allowSoftware = true; break;
      case '--require-gpu': a.requireGpu = true; break;
      case '--duration': a.durationS = parseFloat(next()); break;
      case '--url': a.url = next(); break;
      case '--root': a.root = path.resolve(next()); break;
      case '--port': a.port = parseInt(next(), 10); break;
      case '--out': a.outDir = path.resolve(next()); break;
      case '--shots': a.shots = parseInt(next(), 10); break;
      case '--baseline': a.baseline = path.resolve(next()); break;
      case '--floor-ms': a.floorMs = parseFloat(next()); break;
      case '--min-pct': a.minPctLeFloor = parseFloat(next()); break;
      case '--max-hitches': a.maxHitches = parseInt(next(), 10); break;
      case '--heap-ceiling-mb': a.heapCeilingMb = parseFloat(next()); break;
      case '--enforce-perf': a.enforcePerf = true; break;
      case '--no-enforce-perf': a.enforcePerf = false; break;
      case '--regress-pct': a.regressPct = parseFloat(next()); break;
      case '--boot-timeout': a.bootTimeoutS = parseFloat(next()); break;
      case '--help': case '-h': a.help = true; break;
      default: console.error(`[soak] unknown arg: ${v}`); a.help = true;
    }
  }
  if (a.mode === null) a.mode = a.help ? null : 'cpu-fallback';
  if (a.durationS === null) a.durationS = a.mode === 'gpu' ? 900 : 30;
  if (a.enforcePerf === null) a.enforcePerf = a.mode === 'gpu';
  return a;
}

const HELP = `Tier-B web-soak-gpu driver
  node soak.mjs --gpu           REAL test (headful under xvfb; real GPU required)
  node soak.mjs --cpu-fallback  local software smoke (self-tests the GPU gate)
Flags:
  --allow-software        proceed on a software renderer (smoke only)
  --require-gpu           apply the strict real-GPU gate even in --cpu-fallback
                          (proves the gate exits 1 on SwiftShader, headlessly)
  --duration <s>          soak walk length (default 900 gpu / 30 cpu)
  --url <u>               test an external origin instead of the local server
  --root <dir>            static root when serving locally (default ../../build/web)
  --out <dir>             results dir (default ./results)
  --shots <n>             screenshots to capture (default 6)
  --baseline <file>       regression baseline JSON (default ./baseline/baseline.json)
  --floor-ms <ms>         worst-frame floor (default 18)
  --min-pct <pct>         min % of frames <= floor (default 99)
  --max-hitches <n>       extra hitches allowed during the walk (default 0)
  --heap-ceiling-mb <mb>  hard heap ceiling (default 900)
  --[no-]enforce-perf     force perf gate on/off (default: on in --gpu)
  --regress-pct <pct>     baseline regression tolerance (default 20)`;

// ── in-page probes ───────────────────────────────────────────────────────────
const PROBE_RENDERER = () => {
  const c = document.createElement('canvas');
  const gl = c.getContext('webgl2') || c.getContext('webgl');
  if (!gl) return { ok: false, renderer: null, vendor: null, reason: 'no webgl context' };
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  const renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  const vendor = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
  return { ok: true, renderer: String(renderer), vendor: String(vendor) };
};

const PROBE_ISOLATION = () => ({
  crossOriginIsolated: self.crossOriginIsolated === true,
  hasSAB: typeof SharedArrayBuffer !== 'undefined',
  hasMeasureMemory: typeof performance.measureUserAgentSpecificMemory === 'function',
});

// Heap sampling with a fallback chain, because the PRIMARY API is environment-gated:
//   1. performance.measureUserAgentSpecificMemory() — the real WASM+worker breakdown.
//      Requires crossOriginIsolated (we have it) AND full site isolation. Available in
//      FULL/headful Chrome (our --gpu cloud run, headful under xvfb) but NOT in the
//      chrome-headless-shell used by headless:true — it throws SecurityError there.
//   2. performance.memory.usedJSHeapSize — always present in Chromium; the local
//      headless smoke falls back to this (JS-heap only; launch with
//      --enable-precise-memory-info for un-bucketed values). This is the DevTools
//      `performance.memory` number the HEAP-AB doc §2.1 also lists.
// We record which source produced the number so the artefact is unambiguous.
const PROBE_HEAP = async () => {
  const out = { source: null, bytes: null };
  if (typeof performance.measureUserAgentSpecificMemory === 'function') {
    try {
      const m = await performance.measureUserAgentSpecificMemory();
      out.source = 'measureUserAgentSpecificMemory';
      out.bytes = m.bytes;
      out.breakdown = m.breakdown;
      return out;
    } catch (e) {
      out.measureError = String(e);
    }
  }
  if (performance.memory && typeof performance.memory.usedJSHeapSize === 'number') {
    out.source = 'performance.memory';
    out.bytes = performance.memory.usedJSHeapSize;
    out.jsHeapLimit = performance.memory.jsHeapSizeLimit;
    return out;
  }
  out.supported = false;
  return out;
};

// ── small helpers ────────────────────────────────────────────────────────────
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowMs = () => Date.now();
const mb = (bytes) => (bytes == null ? null : +(bytes / 1048576).toFixed(1));

async function pathExists(p) {
  try { await fsstat(p); return true; } catch { return false; }
}

// Drive the in-game player: hold forward, periodically strafe / jump / turn so the
// walk crosses facet seams and exercises streaming. Mouse-look (yaw) needs pointer
// lock, which is best-effort under headless/xvfb — see README "Driving the soak".
async function drivePlanetWalk(page, durationMs, log) {
  const t0 = nowMs();
  // Focus + attempt pointer capture (Godot captures the mouse on first interaction).
  try { await page.locator('#canvas').click({ timeout: 3000, position: { x: 640, y: 360 } }); }
  catch { /* canvas may not be a Playwright-clickable element; keyboard still routes */ }
  await page.keyboard.down('KeyW'); // hold forward for the whole soak
  let turn = 0;
  while (nowMs() - t0 < durationMs) {
    // periodic heading/altitude variation to spread the walk over many facets
    const strafe = turn % 2 === 0 ? 'KeyA' : 'KeyD';
    await page.keyboard.down(strafe);
    // best-effort mouse-look turn (only bites if pointer lock engaged)
    try { await page.mouse.move(640 + (turn % 2 ? 220 : -220), 360, { steps: 8 }); } catch {}
    await sleep(1500);
    await page.keyboard.up(strafe);
    await page.keyboard.down('Space'); // hop, so uneven terrain/collapse is exercised
    await sleep(200);
    await page.keyboard.up('Space');
    await sleep(1300);
    turn++;
    if (turn % 20 === 0) log(`  … walking (${Math.round((nowMs() - t0) / 1000)}s / ${Math.round(durationMs / 1000)}s)`);
  }
  await page.keyboard.up('KeyW');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.mode) { console.log(HELP); process.exit(args.mode ? 0 : 2); }

  const log = (...m) => console.log('[soak]', ...m);
  const fail = [];
  const pass = [];
  const record = (ok, name, detail) => {
    (ok ? pass : fail).push({ name, detail });
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
  };

  log(`mode=${args.mode} duration=${args.durationS}s enforcePerf=${args.enforcePerf}`);
  if (args.mode === 'cpu-fallback' && !args.allowSoftware) {
    log('CPU-FALLBACK gate self-test: expecting a SOFTWARE renderer and asserting the real-GPU gate REJECTS it.');
  } else if (args.mode === 'cpu-fallback') {
    log('CPU-FALLBACK SMOKE (software) — proving plumbing only; NOT a real perf measurement.');
  }

  // ── static origin ─────────────────────────────────────────────────────────
  let server = null;
  let baseUrl = args.url;
  if (!baseUrl) {
    if (!(await pathExists(path.join(args.root, 'index.html')))) {
      console.error(`[soak] no build at ${args.root}/index.html — run scripts/export-web.sh first (or pass --url).`);
      process.exit(2);
    }
    server = createServer(args.root);
    await new Promise((res) => server.listen(args.port, '127.0.0.1', res));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
    log(`serving ${args.root} at ${baseUrl}`);
  } else {
    log(`testing external origin ${baseUrl}`);
  }

  // ── header check (only meaningful for our own server; also probe external) ──
  try {
    const res = await fetch(baseUrl + '/index.html', { redirect: 'manual' });
    let allHeaders = true;
    for (const [h, want] of REQUIRED_ISOLATION_HEADERS) {
      const got = (res.headers.get(h) || '').toLowerCase();
      if (got !== want) allHeaders = false;
    }
    record(allHeaders, 'COOP/COEP headers on /index.html',
      `COOP=${res.headers.get('cross-origin-opener-policy')} COEP=${res.headers.get('cross-origin-embedder-policy')}`);
  } catch (e) {
    record(false, 'COOP/COEP header fetch', String(e));
  }

  // ── browser ────────────────────────────────────────────────────────────────
  const prof = launchProfile(args.mode);
  log(`launching chromium headless=${prof.headless} flags: ${prof.flags.join(' ')}`);
  let browser;
  try {
    browser = await chromium.launch({ headless: prof.headless, args: prof.flags });
  } catch (e) {
    console.error('[soak] chromium.launch failed:', String(e));
    console.error('[soak] run `npm i && npx playwright install chromium` in tools/web-soak-gpu.');
    if (server) server.close();
    process.exit(2);
  }
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page = await context.newPage();

  const perfSeries = [];
  const hitches = [];
  const consoleErrors = [];
  const benignConsole = [];
  // Benign in automation, NOT a game fault: the game requests pointer lock
  // (MOUSE_MODE_CAPTURED) which the browser denies without a "real" user gesture
  // when Playwright drives input. Harmless — keyboard walk still routes.
  const BENIGN_RE = /Pointer Lock|user gesture is required|requestPointerLock/i;
  const classify = (text) => {
    if (BENIGN_RE.test(text)) { benignConsole.push(text); return; }
    consoleErrors.push(text);
  };
  page.on('console', (msg) => {
    const text = msg.text();
    const p = parsePerfLine(text, nowMs());
    if (p) { perfSeries.push(p); return; }
    const h = parseHitchLine(text, nowMs());
    if (h) { hitches.push(h); return; }
    if (msg.type() === 'error') classify(text);
  });
  page.on('pageerror', (err) => classify(String(err)));

  const outDir = args.outDir;
  await mkdir(outDir, { recursive: true });
  const shotDir = path.join(outDir, 'screenshots');
  await mkdir(shotDir, { recursive: true });

  let exitCode = 0;
  const heapSamples = [];
  let renderer = null;
  try {
    await page.goto(baseUrl + '/index.html', { waitUntil: 'domcontentloaded', timeout: 60000 });

    // ── GATE 1: real GPU (the load-bearing gate) ──────────────────────────────
    const gpu = await page.evaluate(PROBE_RENDERER);
    renderer = gpu.renderer;
    const software = isSoftwareRenderer(gpu.renderer);
    // The strict real-GPU gate binds whenever the caller asked for a GPU run (either
    // --gpu, or --require-gpu to exercise the gate headlessly) and did not opt out.
    const requireGpu = (args.mode === 'gpu' || args.requireGpu) && !args.allowSoftware;
    log(`UNMASKED_RENDERER_WEBGL = ${gpu.renderer}  (vendor ${gpu.vendor})  software=${software}`);
    if (requireGpu) {
      record(!software, 'real-GPU gate (no SwiftShader/llvmpipe)', gpu.renderer || gpu.reason);
      if (software) { exitCode = 1; throw new Error('GATE: software renderer on a GPU-required run — fail fast, exit 1'); }
    } else if (args.mode === 'cpu-fallback' && !args.allowSoftware) {
      // Self-test: prove the strict gate correctly REJECTS software. This RUN is a
      // pass iff the renderer is software (so the gate would exit 1 on a real --gpu run).
      record(software, 'GPU-gate-fails-correctly (SwiftShader rejected)', gpu.renderer || gpu.reason);
      log('gate self-test complete — the real-GPU gate would exit 1 on this renderer, as designed.');
      throw new Error('__gate_selftest_done__'); // clean early exit; not a failure
    } else {
      record(true, `renderer read (software=${software}, allowed)`, gpu.renderer || gpu.reason);
    }

    // ── GATE 2: cross-origin isolation ────────────────────────────────────────
    const iso = await page.evaluate(PROBE_ISOLATION);
    record(iso.crossOriginIsolated, 'crossOriginIsolated === true', JSON.stringify(iso));
    if (!iso.crossOriginIsolated) { exitCode = 1; }

    // ── boot: wait for the first [PERF] line ─────────────────────────────────
    log(`waiting for engine boot (first [PERF] line, timeout ${args.bootTimeoutS}s)…`);
    const bootT0 = nowMs();
    while (perfSeries.length === 0 && nowMs() - bootT0 < args.bootTimeoutS * 1000) {
      await sleep(500);
    }
    const booted = perfSeries.length > 0;
    record(booted, 'engine boots ([PERF] line seen)', booted ? `after ${((nowMs() - bootT0) / 1000).toFixed(1)}s` : 'timeout');
    if (!booted) { exitCode = 1; throw new Error('engine did not boot'); }

    // ── heap API smoke (before the walk) ─────────────────────────────────────
    const heap0 = await page.evaluate(PROBE_HEAP);
    record(heap0.bytes != null,
      'heap API returns (measureUserAgentSpecificMemory / performance.memory)',
      heap0.bytes != null ? `${mb(heap0.bytes)} MB via ${heap0.source}` : JSON.stringify(heap0));
    if (heap0.bytes != null) heapSamples.push({ t: nowMs(), phase: 'boot', mb: mb(heap0.bytes), source: heap0.source });
    const heapSource = heap0.source;

    // ── the soak walk ────────────────────────────────────────────────────────
    log(`driving the planet walk for ${args.durationS}s…`);
    const walkStart = perfSeries.length;
    const shotEvery = Math.max(1, Math.floor((args.durationS * 1000) / args.shots));
    let shotIdx = 0;
    const heapEveryMs = 25000;
    let lastHeap = nowMs();

    const walkPromise = drivePlanetWalk(page, args.durationS * 1000, log);
    const sampleT0 = nowMs();
    while (nowMs() - sampleT0 < args.durationS * 1000) {
      await sleep(1000);
      // periodic heap sample
      if (nowMs() - lastHeap >= heapEveryMs) {
        lastHeap = nowMs();
        const h = await page.evaluate(PROBE_HEAP);
        if (h.bytes != null) {
          heapSamples.push({ t: nowMs(), phase: 'walk', mb: mb(h.bytes), source: h.source });
          log(`  heap ${mb(h.bytes)} MB (${h.source})`);
        }
      }
      // periodic screenshot (best-effort; see README on preserveDrawingBuffer)
      if (shotIdx < args.shots && (nowMs() - sampleT0) >= shotIdx * shotEvery) {
        const sp = path.join(shotDir, `shot-${String(shotIdx).padStart(2, '0')}.png`);
        try { await page.screenshot({ path: sp }); } catch (e) { log('screenshot failed', String(e)); }
        shotIdx++;
      }
    }
    await walkPromise;

    // final heap
    const heapEnd = await page.evaluate(PROBE_HEAP);
    if (heapEnd.bytes != null) heapSamples.push({ t: nowMs(), phase: 'end', mb: mb(heapEnd.bytes), source: heapEnd.source });

    // ── summarise + assert ───────────────────────────────────────────────────
    const walkSeries = perfSeries.slice(walkStart);
    const summary = summarizePerf(walkSeries.length ? walkSeries : perfSeries);
    log('PERF summary:', JSON.stringify(summary, null, 2));

    const heapPeak = heapSamples.length ? Math.max(...heapSamples.map((s) => s.mb)) : null;
    const heapSteady = heapSamples.length ? heapSamples[heapSamples.length - 1].mb : null;

    if (args.enforcePerf) {
      record(summary.pct_frames_le_18ms >= args.minPctLeFloor,
        `${args.minPctLeFloor}% of frames <= ${args.floorMs}ms`,
        `got ${summary.pct_frames_le_18ms?.toFixed(1)}% (p99=${summary.worst_frame_ms_p99}ms, max=${summary.worst_frame_ms_max}ms)`);
      if (summary.pct_frames_le_18ms < args.minPctLeFloor) exitCode = 1;

      const walkHitches = hitches.length; // hitches during the observed window
      record(walkHitches <= args.maxHitches, `hitches (>33ms via LOG_MS lines) <= ${args.maxHitches}`, `got ${walkHitches}`);
      if (walkHitches > args.maxHitches) exitCode = 1;
    } else {
      log(`perf gate NOT enforced (${args.mode}); reporting only: ${summary.pct_frames_le_18ms?.toFixed(1)}% <= ${args.floorMs}ms, p99=${summary.worst_frame_ms_p99}ms`);
    }

    if (heapPeak != null) {
      record(heapPeak <= args.heapCeilingMb, `heap peak <= ${args.heapCeilingMb} MB`, `peak ${heapPeak} MB, steady ${heapSteady} MB`);
      if (heapPeak > args.heapCeilingMb) exitCode = 1;
    }

    record(consoleErrors.length === 0, 'no console/page errors during soak',
      consoleErrors.length ? `${consoleErrors.length}: ${consoleErrors.slice(0, 3).join(' | ')}`
        : (benignConsole.length ? `clean (${benignConsole.length} benign pointer-lock notice ignored)` : 'clean'));
    if (consoleErrors.length) exitCode = 1;

    // ── baseline regression diff ─────────────────────────────────────────────
    let baselineDiff = null;
    if (await pathExists(args.baseline)) {
      try {
        const base = JSON.parse(await readFile(args.baseline, 'utf8'));
        baselineDiff = {};
        const cmp = (label, cur, prev, higherIsWorse = true) => {
          if (prev == null || cur == null) return;
          const deltaPct = prev === 0 ? 0 : (100 * (cur - prev)) / prev;
          const regressed = higherIsWorse ? deltaPct > args.regressPct : deltaPct < -args.regressPct;
          baselineDiff[label] = { cur, baseline: prev, deltaPct: +deltaPct.toFixed(1) };
          record(!regressed, `no regression: ${label}`, `cur ${cur} vs baseline ${prev} (${deltaPct.toFixed(1)}%)`);
          if (regressed && args.enforcePerf) exitCode = 1;
        };
        cmp('worst_frame_ms_p99', summary.worst_frame_ms_p99, base.summary?.worst_frame_ms_p99);
        cmp('heap_peak_mb', heapPeak, base.heap_peak_mb);
      } catch (e) { log('baseline read/parse failed:', String(e)); }
    } else {
      log(`no baseline at ${args.baseline} — writing this run to results/ for promotion.`);
    }

    // ── emit artefact ─────────────────────────────────────────────────────────
    const artefact = {
      when: new Date().toISOString(),
      mode: args.mode,
      url: baseUrl,
      renderer,
      software,
      crossOriginIsolated: iso.crossOriginIsolated,
      durationS: args.durationS,
      perf_samples: perfSeries.length,
      summary,
      hitches: hitches.length,
      hitch_detail: hitches.slice(0, 50),
      heap_source: heapSource,
      heap_samples: heapSamples,
      heap_peak_mb: heapPeak,
      heap_steady_mb: heapSteady,
      console_errors: consoleErrors,
      benign_console: benignConsole,
      baseline_diff: baselineDiff,
      thresholds: {
        floorMs: args.floorMs, minPctLeFloor: args.minPctLeFloor,
        maxHitches: args.maxHitches, heapCeilingMb: args.heapCeilingMb,
        enforcePerf: args.enforcePerf,
      },
      pass, fail,
    };
    const outFile = path.join(outDir, `soak-${Date.now()}.json`);
    await writeFile(outFile, JSON.stringify(artefact, null, 2));
    await writeFile(path.join(outDir, 'latest.json'), JSON.stringify(artefact, null, 2));
    log(`wrote ${outFile}`);
    log(`screenshots: ${shotDir} (${shotIdx} captured)`);
  } catch (e) {
    if (String(e).includes('__gate_selftest_done__')) {
      // cpu-fallback self-test path — exit reflects whether the gate behaved.
      exitCode = fail.length ? 1 : 0;
    } else {
      log('run error:', String(e));
      if (exitCode === 0) exitCode = 1;
    }
  } finally {
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
    if (server) server.close();
  }

  console.log(`\n[soak] ${pass.length} passed, ${fail.length} failed → exit ${exitCode}`);
  process.exit(exitCode);
}

main().catch((e) => { console.error('[soak] fatal', e); process.exit(2); });
