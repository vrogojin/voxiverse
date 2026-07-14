// VOXIVERSE remote-play bridge — RELAY (Phase 1, OBSERVE-ONLY).
// ----------------------------------------------------------------------------------------------
// A token-gated WebSocket server the GAME dials OUT to. It receives TELEMETRY (JSON text frames)
// and FRAMES (binary: 1-byte type tag + JPEG) from a real-GPU play session and writes them to
// files under results/remote/ that only the agent on this host reads. It NEVER serves the received
// data publicly and NEVER sends anything back that the game acts on (Phase 1 is observe-only).
//
// SECURITY MODEL (this sits behind nginx on a PUBLIC domain — see README.md §Security):
//   * TOKEN AUTH. The shared secret comes from REMOTE_BRIDGE_TOKEN env or tools/remote-bridge/.token
//     (gitignored). Every connection MUST send, as its first message, a JSON hello whose `token`
//     matches — within AUTH_TIMEOUT_MS — or it is closed (code 4001) and the auth failure is logged.
//   * CONNECTION CAP + RATE LIMIT. At most MAX_CONNS live sockets; new connections beyond the cap
//     are refused. A per-connection message-rate cap drops abusive floods.
//   * BIND LOCAL. Listens on 127.0.0.1 only — reachable from the public internet solely via the
//     nginx `location /remote { proxy_pass ... }` route (which itself is the wss endpoint). The
//     relay never terminates TLS and is never directly exposed.
//   * The token is read from the hello frame (inside wss), never from the URL, so it stays out of
//     nginx access logs.
//
// Run:   REMOTE_BRIDGE_TOKEN=... node relay.mjs           (or drop the secret in ./.token)
//        node relay.mjs --port 8090 --results ./results/remote
//
// Read (agent): results/remote/telemetry.jsonl  (append-only, capped)  and
//               results/remote/frame-latest.jpg (most recent frame) + results/remote/frames/ (ring).

import { WebSocketServer } from 'ws';
import { createServer } from 'node:http';
import { readFileSync, mkdirSync, appendFileSync, writeFileSync, statSync, readdirSync, unlinkSync, renameSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));

// ── Config (CLI flags override env override defaults) ────────────────────────────────────────
function argOf(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return (i >= 0 && i + 1 < process.argv.length) ? process.argv[i + 1] : fallback;
}

const PORT = parseInt(argOf('port', process.env.REMOTE_BRIDGE_PORT || '8090'), 10);
const HOST = argOf('host', process.env.REMOTE_BRIDGE_HOST || '127.0.0.1');
const RESULTS_DIR = argOf('results', process.env.REMOTE_BRIDGE_RESULTS || join(HERE, 'results', 'remote'));
const FRAMES_DIR = join(RESULTS_DIR, 'frames');
const TELEMETRY_FILE = join(RESULTS_DIR, 'telemetry.jsonl');
const FRAME_LATEST = join(RESULTS_DIR, 'frame-latest.jpg');

const AUTH_TIMEOUT_MS = 5000;        // a socket must send a valid hello within this window
const MAX_CONNS = 4;                 // live connection cap
const MAX_MSG_PER_SEC = 60;          // per-connection message-rate cap (telemetry ~4/s + frames ~2/s + slack)
const MAX_FRAME_BYTES = 2 * 1024 * 1024;   // reject a JPEG frame larger than 2 MB
const TELEMETRY_CAP_BYTES = 32 * 1024 * 1024;  // roll telemetry.jsonl when it exceeds this
const FRAME_RING = 60;               // keep the newest N frames in frames/ (older ones pruned)

const FRAME_TAG = 0x01;              // must match RemoteBridge.FRAME_TAG on the game side

// ── Token ────────────────────────────────────────────────────────────────────────────────────
function loadToken() {
  const env = (process.env.REMOTE_BRIDGE_TOKEN || '').trim();
  if (env) return env;
  try {
    const t = readFileSync(join(HERE, '.token'), 'utf8').trim();
    if (t) return t;
  } catch { /* no file */ }
  return '';
}
const TOKEN = loadToken();
if (!TOKEN) {
  console.error('[relay] FATAL: no token. Set REMOTE_BRIDGE_TOKEN or create tools/remote-bridge/.token');
  process.exit(2);
}

// Constant-time-ish token compare (avoid trivial length/short-circuit leaks).
function tokenOk(candidate) {
  const a = Buffer.from(String(candidate));
  const b = Buffer.from(TOKEN);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ── Result sinks ───────────────────────────────────────────────────────────────────────────────
mkdirSync(FRAMES_DIR, { recursive: true });

function ts() { return new Date().toISOString(); }
function log(...a) { console.log(`[relay ${ts()}]`, ...a); }

function rollTelemetryIfBig() {
  try {
    const sz = statSync(TELEMETRY_FILE).size;
    if (sz > TELEMETRY_CAP_BYTES) {
      renameSync(TELEMETRY_FILE, TELEMETRY_FILE + '.1');  // keep one previous roll
    }
  } catch { /* file absent — fine */ }
}

function writeTelemetry(obj) {
  rollTelemetryIfBig();
  appendFileSync(TELEMETRY_FILE, JSON.stringify(obj) + '\n');
}

let frameSeq = 0;
function writeFrame(jpg) {
  // Latest — written atomically (tmp + rename) so a reader never sees a half-written file.
  const tmp = FRAME_LATEST + '.tmp';
  writeFileSync(tmp, jpg);
  renameSync(tmp, FRAME_LATEST);
  // Timestamped ring.
  const name = `frame-${Date.now()}-${(frameSeq++ % FRAME_RING).toString().padStart(3, '0')}.jpg`;
  writeFileSync(join(FRAMES_DIR, name), jpg);
  pruneFrameRing();
}

function pruneFrameRing() {
  try {
    const files = readdirSync(FRAMES_DIR).filter((f) => f.endsWith('.jpg')).sort();
    while (files.length > FRAME_RING) {
      const victim = files.shift();
      try { unlinkSync(join(FRAMES_DIR, victim)); } catch { /* raced */ }
    }
  } catch { /* dir vanished — fine */ }
}

// ── WS server (behind an http server so nginx can proxy_pass to it) ──────────────────────────────
const httpServer = createServer((req, res) => {
  // Anything that is NOT a WS upgrade gets a bare 426 — the relay serves no content.
  res.writeHead(426, { 'Content-Type': 'text/plain' });
  res.end('Upgrade Required\n');
});

const wss = new WebSocketServer({ server: httpServer, maxPayload: MAX_FRAME_BYTES });

let liveConns = 0;

wss.on('connection', (ws, req) => {
  const peer = req.socket.remoteAddress + ':' + req.socket.remotePort;
  if (liveConns >= MAX_CONNS) {
    log('REFUSE (cap):', peer);
    try { ws.close(4009, 'busy'); } catch { /* ignore */ }
    return;
  }
  liveConns++;

  let authed = false;
  let msgWindowStart = Date.now();
  let msgInWindow = 0;

  const authTimer = setTimeout(() => {
    if (!authed) {
      log('AUTH-FAIL (timeout, no hello):', peer);
      try { ws.close(4001, 'auth timeout'); } catch { /* ignore */ }
    }
  }, AUTH_TIMEOUT_MS);

  log('CONNECT:', peer, `(live=${liveConns})`);

  ws.on('message', (data, isBinary) => {
    // Per-connection rate limit.
    const now = Date.now();
    if (now - msgWindowStart >= 1000) { msgWindowStart = now; msgInWindow = 0; }
    if (++msgInWindow > MAX_MSG_PER_SEC) {
      log('RATE-LIMIT close:', peer);
      try { ws.close(4008, 'rate'); } catch { /* ignore */ }
      return;
    }

    if (!authed) {
      // The FIRST message MUST be a valid JSON hello with a matching token.
      if (isBinary) {
        log('AUTH-FAIL (binary before hello):', peer);
        try { ws.close(4001, 'auth'); } catch { /* ignore */ }
        return;
      }
      let hello;
      try { hello = JSON.parse(data.toString('utf8')); } catch {
        log('AUTH-FAIL (bad hello json):', peer);
        try { ws.close(4001, 'auth'); } catch { /* ignore */ }
        return;
      }
      if (hello.type !== 'hello' || !tokenOk(hello.token)) {
        log('AUTH-FAIL (bad token):', peer, 'ua=', String(hello.ua || '').slice(0, 60));
        try { ws.close(4001, 'auth'); } catch { /* ignore */ }
        return;
      }
      authed = true;
      clearTimeout(authTimer);
      log('AUTH-OK:', peer, 'ver=', String(hello.ver || '?'), 'ua=', String(hello.ua || '?').slice(0, 80));
      return;
    }

    // ── Authenticated data ──────────────────────────────────────────────────────────────────
    if (isBinary) {
      // Binary = a frame: [FRAME_TAG][jpeg...].
      if (data.length < 2 || data[0] !== FRAME_TAG) return;  // unknown binary type — ignore
      const jpg = data.subarray(1);
      // Sanity: JPEG magic FF D8.
      if (jpg.length < 2 || jpg[0] !== 0xff || jpg[1] !== 0xd8) return;
      try { writeFrame(jpg); } catch (e) { log('frame write error:', e.message); }
    } else {
      // Text = telemetry JSON. Stamp with server receive time + peer, then append.
      let obj;
      try { obj = JSON.parse(data.toString('utf8')); } catch { return; }
      obj._rx = ts();
      obj._peer = peer;
      try { writeTelemetry(obj); } catch (e) { log('telemetry write error:', e.message); }
    }
  });

  ws.on('close', (code) => {
    clearTimeout(authTimer);
    liveConns = Math.max(0, liveConns - 1);
    log('DISCONNECT:', peer, 'code=', code, `(live=${liveConns})`);
  });

  ws.on('error', (e) => {
    log('SOCKET-ERR:', peer, e.message);
  });
});

httpServer.listen(PORT, HOST, () => {
  log(`listening ws://${HOST}:${PORT}  results=${RESULTS_DIR}  cap=${MAX_CONNS}`);
  log('token loaded (' + TOKEN.length + ' chars). Waiting for the game to dial in.');
});

// Clean shutdown.
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => { log('shutting down on', sig); wss.close(); httpServer.close(() => process.exit(0)); setTimeout(() => process.exit(0), 1000); });
}
