// Parser for the in-game PerfHUD console lines (godot/src/ui/perf_hud.gd).
//
// The HUD print()s two kinds of line to the browser console; on the threaded web
// export these surface through page.on('console'). We scrape them into a time
// series — this is the HARD signal for the soak (screenshots are best-effort;
// heap is secondary). Keep these regexes in lockstep with perf_hud.gd.
//
//   [PERF]  — every WINDOW (0.25 s). The exact printf (perf_hud.gd:136):
//     "[PERF] fps=%.0f min=%.0f worst=%.0fms hitches=%d drained=%d/s
//      proc=%.1f phys=%.1f draws=%d prims=%d vox_gen=%d vox_mesh=%d"
//
//   [PERF-HITCH] — every frame slower than LOG_MS (60 ms). perf_hud.gd:87:
//     "[PERF-HITCH] %.0f ms frame  vox_gen_backlog=%s  vox_mesh_backlog=%s"

const PERF_RE =
  /\[PERF\]\s+fps=([\d.]+)\s+min=([\d.]+)\s+worst=([\d.]+)ms\s+hitches=(\d+)\s+drained=(\d+)\/s\s+proc=([\d.]+)\s+phys=([\d.]+)\s+draws=(\d+)\s+prims=(\d+)\s+vox_gen=(\d+)\s+vox_mesh=(\d+)/;

const HITCH_RE =
  /\[PERF-HITCH\]\s+([\d.]+)\s+ms frame\s+vox_gen_backlog=(\S+)\s+vox_mesh_backlog=(\S+)/;

// Returns a plain sample object, or null if the line is not a [PERF] line.
export function parsePerfLine(text, tMs = Date.now()) {
  const m = PERF_RE.exec(text);
  if (!m) return null;
  return {
    t: tMs,
    fps: parseFloat(m[1]),
    min_fps: parseFloat(m[2]),
    worst_ms: parseFloat(m[3]),
    hitches: parseInt(m[4], 10),
    drained_per_s: parseInt(m[5], 10),
    proc_ms: parseFloat(m[6]),
    phys_ms: parseFloat(m[7]),
    draws: parseInt(m[8], 10),
    prims: parseInt(m[9], 10),
    vox_gen: parseInt(m[10], 10),
    vox_mesh: parseInt(m[11], 10),
  };
}

// Returns a hitch object, or null if the line is not a [PERF-HITCH] line.
export function parseHitchLine(text, tMs = Date.now()) {
  const m = HITCH_RE.exec(text);
  if (!m) return null;
  return {
    t: tMs,
    frame_ms: parseFloat(m[1]),
    vox_gen_backlog: m[2] === '?' ? null : parseInt(m[2], 10),
    vox_mesh_backlog: m[3] === '?' ? null : parseInt(m[3], 10),
  };
}

// Reduce a [PERF] series to the summary metrics the gate asserts against.
export function summarizePerf(series) {
  if (series.length === 0) {
    return { count: 0 };
  }
  const worst = series.map((s) => s.worst_ms);
  const budgetMs = 18; // CTRL_FRAME_BUDGET_MS — the 18ms floor from FP-M2 §11 / HEAP-AB.
  const overBudget = worst.filter((w) => w > budgetMs).length;
  const sorted = [...worst].sort((a, b) => a - b);
  const pct = (p) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
  const last = series[series.length - 1];
  return {
    count: series.length,
    worst_frame_ms_max: Math.max(...worst),
    worst_frame_ms_p50: pct(50),
    worst_frame_ms_p95: pct(95),
    worst_frame_ms_p99: pct(99),
    frames_over_18ms: overBudget,
    pct_frames_le_18ms: (100 * (series.length - overBudget)) / series.length,
    // hitches is a running total on the HUD, so the final value is the count.
    hitches_total: last.hitches,
    vox_gen_max: Math.max(...series.map((s) => s.vox_gen)),
    vox_mesh_max: Math.max(...series.map((s) => s.vox_mesh)),
    fps_mean: series.reduce((a, s) => a + s.fps, 0) / series.length,
    proc_ms_max: Math.max(...series.map((s) => s.proc_ms)),
    phys_ms_max: Math.max(...series.map((s) => s.phys_ms)),
  };
}
