#!/usr/bin/env node
// COSMOS SPACE-FLY scriptable test-flight harness (docs/COSMOS-SPACEFLY-DESIGN.md).
//
// Drives a LIVE (real-GPU) space mission through the remote-bridge control channel and self-verifies each
// mechanic from the streamed telemetry — so the orchestrator can fly ascent→orbit→coast→de-orbit→land and
// Earth→Moon transfers WITHOUT a human at the browser, and assert the result headlessly.
//
// HOW IT WORKS (no new trust surface — it is just a scripted OUTBOX author + telemetry reader):
//   * A flight script (JSON) is a list of LEGS. Each leg is a cmd_seq (steps) plus optional `settle_s` and
//     `expect` (telemetry assertions to check once the leg's `done.json` lands and the world has settled).
//   * For each leg the harness atomically writes control/outbox/<seq>.json (the ONE command source the relay
//     honours — §ingress), polls control/results/<seq>/done.json for completion, then reads the latest
//     results/remote/telemetry.jsonl line(s) and evaluates `expect`.
//   * The security model is UNTOUCHED: the harness only writes local outbox files; the relay still requires a
//     token-authed socket AND a human-armed grant AND the control token to forward. With CONTROL_ENABLED off
//     (the shipped default) every leg is rejected and the harness reports the legs as un-forwarded — it never
//     weakens the gate, it exercises it.
//
// USAGE:
//   node flight.mjs flights/ascent-to-orbit.json            # run one flight script
//   node flight.mjs flights/ascent-to-orbit.json --control ./control --results ./results/remote
//   node flight.mjs --list                                  # list the canned flights
// Exits 0 when every leg forwarded + every assertion passed; 1 otherwise. Times out per leg (default 200 s).

import { readFileSync, writeFileSync, renameSync, existsSync, readdirSync, mkdirSync, statSync } from 'node:fs';
import { join, dirname, basename, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

function argOf(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}
function hasFlag(name) { return process.argv.includes(`--${name}`); }

const CONTROL_DIR = argOf('control', process.env.REMOTE_BRIDGE_CONTROL || join(HERE, 'control'));
const RESULTS_DIR = argOf('results', process.env.REMOTE_BRIDGE_RESULTS || join(HERE, 'results', 'remote'));
const OUTBOX_DIR = join(CONTROL_DIR, 'outbox');
const CONTROL_RESULTS_DIR = join(CONTROL_DIR, 'results');
const TELEMETRY_FILE = join(RESULTS_DIR, 'telemetry.jsonl');
const FLIGHTS_DIR = join(HERE, 'flights');
const LEG_TIMEOUT_MS = parseInt(argOf('leg-timeout', '200000'), 10);
const POLL_MS = 400;

const C = { g: '\x1b[32m', r: '\x1b[31m', y: '\x1b[33m', d: '\x1b[2m', x: '\x1b[0m' };
function ok(m) { console.log(`  ${C.g}PASS${C.x} ${m}`); }
function bad(m) { console.log(`  ${C.r}FAIL${C.x} ${m}`); }
function info(m) { console.log(`${C.d}${m}${C.x}`); }
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

// ── telemetry reader ────────────────────────────────────────────────────────────────────────────
// The space-fly self-verification fields are streamed by RemoteBridge (player.space_telemetry + nav_telemetry):
//   nav_mode, v_bci, alt, v_circ, orbit_r, body, dev_nav, coasting, flying, on_ground, att.
function readTelemetryTail(n = 200) {
  if (!existsSync(TELEMETRY_FILE)) return [];
  const lines = readFileSync(TELEMETRY_FILE, 'utf8').split('\n').filter((l) => l.trim());
  const out = [];
  for (const l of lines.slice(-n)) { try { out.push(JSON.parse(l)); } catch { /* skip partial */ } }
  return out;
}
// The latest telemetry object that actually carries nav state (a plain perf tick may predate the flight).
function latestNav(rows) {
  for (let i = rows.length - 1; i >= 0; i--) if (rows[i] && rows[i].nav_mode !== undefined) return rows[i];
  return rows.length ? rows[rows.length - 1] : null;
}
// Collect nav rows whose relay receive-time (_rx, seconds) is within the last `windowS` seconds.
function navRowsSince(sinceRxS) {
  return readTelemetryTail(2000).filter((r) => r && r.nav_mode !== undefined && (r._rx ?? 0) >= sinceRxS);
}

// ── assertion evaluation ────────────────────────────────────────────────────────────────────────
function assertExpect(expect, t, rowsWindow) {
  let pass = true;
  const chk = (cond, m) => { if (cond) ok(m); else { bad(m); pass = false; } };
  if (!t) { bad('no telemetry to assert against (is the relay running + the game streaming?)'); return false; }
  const landed = t.on_ground === true && !t.flying && t.nav_mode === 'planetary';
  for (const [k, v] of Object.entries(expect || {})) {
    switch (k) {
      case 'nav_mode': {
        const allow = Array.isArray(v) ? v : [v];
        chk(allow.includes(t.nav_mode), `nav_mode ${t.nav_mode} ∈ ${JSON.stringify(allow)}`); break;
      }
      case 'body': chk(t.body === v, `body ${t.body} == ${v}`); break;
      case 'att': chk(t.att === v, `att ${t.att} == ${v}`); break;
      case 'alt_gt': chk(t.alt > v, `alt ${t.alt} > ${v}`); break;
      case 'alt_lt': chk(t.alt < v, `alt ${t.alt} < ${v}`); break;
      case 'v_bci_gt': chk(t.v_bci > v, `|v_bci| ${t.v_bci} > ${v}`); break;
      case 'v_bci_lt': chk(t.v_bci < v, `|v_bci| ${t.v_bci} < ${v}`); break;
      case 'near_v_circ_pct': {
        const d = t.v_circ > 0 ? Math.abs(t.v_bci - t.v_circ) / t.v_circ * 100 : 999;
        chk(d <= v, `|v_bci − v_circ| ${d.toFixed(2)}% ≤ ${v}% (v_bci=${t.v_bci}, v_circ=${t.v_circ})`); break;
      }
      case 'coasting': chk(!!t.coasting === v, `coasting == ${v}`); break;
      case 'flying': chk(!!t.flying === v, `flying == ${v}`); break;
      case 'dev_nav': chk(!!t.dev_nav === v, `dev_nav == ${v}`); break;
      case 'on_ground': chk(!!t.on_ground === v, `on_ground == ${v}`); break;
      case 'landed': chk(landed === v, `landed == ${v} (on_ground=${t.on_ground}, nav=${t.nav_mode}, flying=${t.flying})`); break;
      case 'orbit_r_spread_lt_pct': {
        const rs = rowsWindow.map((r) => r.orbit_r).filter((x) => typeof x === 'number');
        if (rs.length < 3) { bad(`orbit_r_spread needs ≥3 samples in the hold window (got ${rs.length})`); pass = false; break; }
        const lo = Math.min(...rs), hi = Math.max(...rs), mid = (lo + hi) / 2 || 1;
        const spread = (hi - lo) / mid * 100;
        chk(spread <= v, `orbit_r spread over hold ${spread.toFixed(3)}% ≤ ${v}% (${rs.length} samples, ${lo.toFixed(0)}…${hi.toFixed(0)})`); break;
      }
      default: bad(`unknown assertion '${k}'`); pass = false;
    }
  }
  return pass;
}

// ── outbox submit + result wait ──────────────────────────────────────────────────────────────────
function submitLeg(seq, leg) {
  mkdirSync(OUTBOX_DIR, { recursive: true });
  const cmd = {
    type: 'cmd_seq', seq, issued: Date.now() / 1000,
    on_fail: leg.on_fail ?? 'abort',
    ...(leg.preempt ? { preempt: true } : {}),
    steps: leg.steps.map((s, i) => ({ id: s.id ?? i + 1, ...s })),
  };
  const tmp = join(OUTBOX_DIR, `.${seq}.tmp`);
  writeFileSync(tmp, JSON.stringify(cmd));
  renameSync(tmp, join(OUTBOX_DIR, `${seq}.json`));         // atomic publish — the relay ingests only the final file
  return cmd;
}

function readResult(seq, name) {
  const p = join(CONTROL_RESULTS_DIR, seq, name);
  if (!existsSync(p)) return null;
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; }
}
function rejectReason(seq) {
  const p = join(CONTROL_DIR, 'rejected', `${seq}.reject.txt`);
  if (existsSync(p)) { try { return readFileSync(p, 'utf8').trim(); } catch { return 'rejected'; } }
  return null;
}

async function waitLeg(seq) {
  const deadline = Date.now() + LEG_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const done = readResult(seq, 'done.json');
    if (done) return { status: 'done', done };
    const rej = rejectReason(seq);
    if (rej) return { status: 'rejected', detail: rej };
    await sleep(POLL_MS);
  }
  return { status: 'timeout' };
}

// ── flight runner ─────────────────────────────────────────────────────────────────────────────────
async function runFlight(scriptPath) {
  const flight = JSON.parse(readFileSync(scriptPath, 'utf8'));
  const stamp = Date.now().toString(36);
  console.log(`\n=== FLIGHT: ${flight.name} — ${flight.description || ''} ===`);
  if (!existsSync(TELEMETRY_FILE)) info(`  (note: ${TELEMETRY_FILE} not found — start the relay and a ?remote=<token> session first)`);
  let allPass = true;
  let legNo = 0;
  for (const leg of flight.legs) {
    legNo += 1;
    const seq = `${flight.name}-${stamp}-${String(legNo).padStart(2, '0')}`;
    const label = leg.name || `leg ${legNo}`;
    console.log(`\n${C.y}▸ ${label}${C.x}  (${leg.steps.length} steps, seq=${seq})`);
    submitLeg(seq, leg);
    const res = await waitLeg(seq);
    if (res.status === 'rejected') { bad(`leg REJECTED by relay: ${res.detail}`); allPass = false; continue; }
    if (res.status === 'timeout') { bad(`leg TIMED OUT after ${LEG_TIMEOUT_MS / 1000}s (no done.json — grant active? game streaming?)`); allPass = false; continue; }
    const seqStatus = res.done?.status ?? 'unknown';
    if (seqStatus === 'ok') ok(`sequence completed (status=ok, ${res.done?.completed ?? '?'} steps)`);
    else { bad(`sequence ended status=${seqStatus} (completed ${res.done?.completed ?? '?'})`); allPass = false; }

    // Settle, then optionally HOLD (sample telemetry over a window) before asserting.
    const settleMs = Math.round((leg.settle_s ?? 1.0) * 1000);
    if (settleMs > 0) await sleep(settleMs);
    let windowRows = [];
    if (leg.hold_s) {
      const t0 = Date.now() / 1000;
      info(`  holding ${leg.hold_s}s, sampling orbit telemetry…`);
      await sleep(leg.hold_s * 1000);
      windowRows = navRowsSince(t0);
    }
    if (leg.expect) {
      const t = latestNav(readTelemetryTail());
      if (!assertExpect(leg.expect, t, windowRows)) allPass = false;
      else info(`  telemetry: nav=${t.nav_mode} alt=${t.alt} v_bci=${t.v_bci} v_circ=${t.v_circ} body=${t.body} coasting=${t.coasting} on_ground=${t.on_ground}`);
    }
  }
  console.log(`\n=== ${allPass ? C.g + 'FLIGHT PASSED' : C.r + 'FLIGHT FAILED'}${C.x}: ${flight.name} ===\n`);
  return allPass;
}

// ── main ────────────────────────────────────────────────────────────────────────────────────────
async function main() {
  if (hasFlag('list') || process.argv.length < 3) {
    console.log('Canned flights (tools/remote-bridge/flights/):');
    if (existsSync(FLIGHTS_DIR)) for (const f of readdirSync(FLIGHTS_DIR).filter((x) => x.endsWith('.json'))) {
      try { const j = JSON.parse(readFileSync(join(FLIGHTS_DIR, f), 'utf8')); console.log(`  ${f.padEnd(28)} — ${j.description || ''}`); }
      catch { console.log(`  ${f}`); }
    }
    console.log('\nRun one:  node flight.mjs flights/<name>.json');
    process.exit(0);
  }
  let arg = process.argv[2];
  if (!isAbsolute(arg) && !existsSync(arg)) {
    const cand = join(FLIGHTS_DIR, basename(arg).endsWith('.json') ? basename(arg) : `${basename(arg)}.json`);
    if (existsSync(cand)) arg = cand;
  }
  if (!existsSync(arg)) { console.error(`flight script not found: ${arg}`); process.exit(2); }
  const pass = await runFlight(arg);
  process.exit(pass ? 0 : 1);
}
main().catch((e) => { console.error(e); process.exit(2); });
