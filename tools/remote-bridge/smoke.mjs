// Loopback smoke test for the remote-bridge relay (no game, no browser required).
// ----------------------------------------------------------------------------------------------
// Spawns relay.mjs on a scratch port with a known token + scratch results dir, then:
//   1. GOOD client — connects, sends a hello (valid token), a telemetry JSON, and one JPEG frame;
//      asserts the relay wrote telemetry.jsonl (with our field) and frame-latest.jpg (JPEG magic).
//   2. BAD client — connects and sends a hello with the WRONG token; asserts the relay CLOSES it
//      (code 4001) and wrote NO new telemetry.
// Exits 0 on all-pass, 1 on any failure. Zero external deps beyond `ws`.

import { spawn } from 'node:child_process';
import { WebSocket } from 'ws';
import { mkdtempSync, readFileSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOKEN = 'smoke-secret-' + Math.random().toString(36).slice(2);
const PORT = 8100 + Math.floor(Math.random() * 800);
const RESULTS = mkdtempSync(join(tmpdir(), 'vox-relay-smoke-'));
const TELEMETRY_FILE = join(RESULTS, 'telemetry.jsonl');
const FRAME_LATEST = join(RESULTS, 'frame-latest.jpg');
const URL = `ws://127.0.0.1:${PORT}`;

// A minimal valid 1x1 JPEG (FF D8 ... FF D9).
const JPEG_1x1 = Buffer.from(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof' +
  'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB' +
  'AAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AfwD/2Q==',
  'base64');

let FRAME_TAG = 0x01;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function ok(cond, msg) {
  console.log((cond ? '  PASS ' : '  FAIL ') + msg);
  if (!cond) failures++;
}

async function main() {
  // Boot the relay.
  const relay = spawn(process.execPath, [join(HERE, 'relay.mjs'), '--port', String(PORT), '--results', RESULTS], {
    env: { ...process.env, REMOTE_BRIDGE_TOKEN: TOKEN },
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  await sleep(700); // give it time to listen

  try {
    // ── 1. GOOD client — real handshake: hello, WAIT for auth_ok, THEN stream ─────────────────
    let gotAuthOk = false;
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(URL);
      const timer = setTimeout(() => reject(new Error('good client timeout')), 4000);
      ws.on('open', () => {
        ws.send(JSON.stringify({ type: 'hello', token: TOKEN, ua: 'smoke', ver: 'test' }));
      });
      ws.on('message', (data, isBinary) => {
        if (isBinary) return;
        let m; try { m = JSON.parse(data.toString('utf8')); } catch { return; }
        if (m.type === 'auth_ok') {
          gotAuthOk = true;
          // Only NOW does the real client stream — mirrors the auth-ack gate.
          ws.send(JSON.stringify({ type: 'telemetry', fps: 59.5, worst_ms: 21.3, _smoke: 'marker-A' }));
          ws.send(Buffer.concat([Buffer.from([FRAME_TAG]), JPEG_1x1]), { binary: true });
          setTimeout(() => { clearTimeout(timer); ws.close(1000, 'done'); resolve(); }, 600);
        }
      });
      ws.on('error', (e) => { clearTimeout(timer); reject(e); });
    });
    await sleep(300);

    ok(gotAuthOk, 'relay sent app-level auth_ok after a valid hello');

    ok(existsSync(TELEMETRY_FILE), 'telemetry.jsonl was written');
    let telem = '';
    if (existsSync(TELEMETRY_FILE)) telem = readFileSync(TELEMETRY_FILE, 'utf8');
    ok(telem.includes('marker-A'), 'telemetry line contains our marker field');
    ok(telem.includes('"_rx"'), 'relay stamped a server receive time (_rx)');
    ok(existsSync(FRAME_LATEST), 'frame-latest.jpg was written');
    if (existsSync(FRAME_LATEST)) {
      const jpg = readFileSync(FRAME_LATEST);
      ok(jpg.length >= 2 && jpg[0] === 0xff && jpg[1] === 0xd8, 'frame-latest.jpg has JPEG magic (FF D8)');
    } else {
      ok(false, 'frame-latest.jpg has JPEG magic (FF D8)');
    }

    const telemBytesBefore = existsSync(TELEMETRY_FILE) ? statSync(TELEMETRY_FILE).size : 0;

    // ── 2. BAD-token client ─────────────────────────────────────────────────────────────────
    const badResult = await new Promise((resolve) => {
      const ws = new WebSocket(URL);
      let closedCode = null;
      let sawAuthOk = false;
      const timer = setTimeout(() => resolve({ closedCode, sawAuthOk, timedOut: true }), 4000);
      ws.on('open', () => {
        ws.send(JSON.stringify({ type: 'hello', token: 'WRONG-' + TOKEN, ua: 'smoke-bad', ver: 'test' }));
        ws.send(JSON.stringify({ type: 'telemetry', _smoke: 'marker-B-should-not-appear' }));
      });
      ws.on('message', (data, isBinary) => {
        if (!isBinary && data.toString('utf8').includes('auth_ok')) sawAuthOk = true;
      });
      ws.on('close', (code) => { closedCode = code; clearTimeout(timer); resolve({ closedCode, sawAuthOk, timedOut: false }); });
      ws.on('error', () => { /* close follows */ });
    });
    ok(badResult.closedCode === 4001, `bad-token connection CLOSED by relay (code ${badResult.closedCode})`);
    ok(!badResult.sawAuthOk, 'bad-token connection received NO auth_ok (never authed)');

    await sleep(300);
    const telemAfter = existsSync(TELEMETRY_FILE) ? readFileSync(TELEMETRY_FILE, 'utf8') : '';
    ok(!telemAfter.includes('marker-B-should-not-appear'), 'bad-token telemetry was NOT written');
    ok((existsSync(TELEMETRY_FILE) ? statSync(TELEMETRY_FILE).size : 0) === telemBytesBefore,
      'telemetry file did not grow after the bad-token attempt');
  } finally {
    relay.kill('SIGTERM');
  }

  console.log(failures === 0 ? '\nSMOKE: ALL PASS' : `\nSMOKE: ${failures} FAILURE(S)`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => { console.error('smoke error:', e); process.exit(1); });
