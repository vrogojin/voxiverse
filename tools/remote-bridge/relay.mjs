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
import { createHash, timingSafeEqual } from 'node:crypto';
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

const AUTH_TIMEOUT_MS = 1500;        // a socket must send a valid hello within this SHORT window (anti-DoS)
const MAX_CONNS = parseInt(process.env.REMOTE_BRIDGE_MAX_CONNS || '4', 10);   // AUTHED cap — never evicted
const MAX_PENDING = parseInt(process.env.REMOTE_BRIDGE_MAX_PENDING || '8', 10); // unauthed pool; OLDEST evicted when full
const PREAUTH_CONNECTS_PER_IP = parseInt(process.env.REMOTE_BRIDGE_PREAUTH_PER_IP || '10', 10); // new conns/IP/window
const PREAUTH_WINDOW_MS = 10000;
const ALLOWED_ORIGIN = (process.env.REMOTE_BRIDGE_ORIGIN || '').trim();  // optional Origin allow-list (defense-in-depth)
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

// Timing-safe token compare. Both sides are first SHA-256 digested to a fixed 32 bytes, so the raw
// token LENGTH never leaks (a bare `a.length !== b.length` check would, and timingSafeEqual throws on
// unequal lengths) and the comparison itself is constant-time.
function tokenOk(candidate) {
  const h = (s) => createHash('sha256').update(String(s)).digest();
  return timingSafeEqual(h(candidate), h(TOKEN));
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

// TWO separate pools so anonymous sockets can never lock out a real session:
//   * authed  — validated sessions, capped at MAX_CONNS, NEVER evicted by newcomers.
//   * pending — unauthed sockets awaiting a hello; capped at MAX_PENDING, OLDEST evicted when full.
let authedConns = 0;
const pending = new Map();          // ws -> connect-time ms
const ipConnects = new Map();       // ip -> recent connect timestamps (pre-auth rate limit)

// Per-IP pre-auth connection rate limit: at most PREAUTH_CONNECTS_PER_IP new sockets per window.
function ipRateOk(ip) {
  const now = Date.now();
  const arr = (ipConnects.get(ip) || []).filter((t) => now - t < PREAUTH_WINDOW_MS);
  arr.push(now);
  ipConnects.set(ip, arr);
  return arr.length <= PREAUTH_CONNECTS_PER_IP;
}

wss.on('connection', (ws, req) => {
  const ip = req.socket.remoteAddress;
  const peer = ip + ':' + req.socket.remotePort;

  // Optional Origin allow-list. WebSockets are NOT subject to CORS, so this is defense-in-depth only
  // (a native/dev client sends no Origin, so an unset ALLOWED_ORIGIN — the default — never blocks).
  if (ALLOWED_ORIGIN && req.headers.origin && req.headers.origin !== ALLOWED_ORIGIN) {
    log('REFUSE (origin):', peer, req.headers.origin);
    try { ws.close(4003, 'origin'); } catch { /* ignore */ }
    return;
  }

  // Per-IP pre-auth connection rate limit.
  if (!ipRateOk(ip)) {
    log('REFUSE (ip-rate):', peer);
    try { ws.close(4029, 'rate'); } catch { /* ignore */ }
    return;
  }

  // Register as pending. If the pending pool is full, evict the OLDEST pending (unauthed) socket —
  // strangers displace strangers; the SEPARATE authed pool is untouched, so a real session can never
  // be locked out by anonymous sockets holding the auth window.
  if (pending.size >= MAX_PENDING) {
    let oldestWs = null, oldestT = Infinity;
    for (const [w, t] of pending) { if (t < oldestT) { oldestT = t; oldestWs = w; } }
    if (oldestWs) {
      log('EVICT (pending full):', peer);
      try { oldestWs.close(4009, 'evicted'); } catch { /* ignore */ }
      pending.delete(oldestWs);
    }
  }
  pending.set(ws, Date.now());

  let authed = false;
  let msgWindowStart = Date.now();
  let msgInWindow = 0;

  const authTimer = setTimeout(() => {
    if (!authed) {
      log('AUTH-FAIL (timeout, no hello):', peer);
      try { ws.close(4001, 'auth timeout'); } catch { /* ignore */ }
    }
  }, AUTH_TIMEOUT_MS);

  log('CONNECT:', peer, `(pending=${pending.size} authed=${authedConns})`);

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
      // Valid token. Move from pending → authed, enforcing the authed cap. A real session is never
      // displaced (we refuse the newcomer if the authed pool is full, rather than evicting a session).
      pending.delete(ws);
      if (authedConns >= MAX_CONNS) {
        log('REFUSE (authed cap):', peer);
        try { ws.close(4009, 'busy'); } catch { /* ignore */ }
        return;
      }
      authed = true;
      authedConns++;
      clearTimeout(authTimer);
      // App-level AUTH-ACK: the client withholds ALL telemetry + frame capture until it receives this,
      // so an unauthenticated visitor never reads back or streams a single frame (closes the brief
      // pre-rejection capture window). It is also the handshake Phase-2 controls will ride.
      try { ws.send(JSON.stringify({ type: 'auth_ok' })); } catch { /* ignore */ }
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
    if (authed) authedConns = Math.max(0, authedConns - 1);
    else pending.delete(ws);
    log('DISCONNECT:', peer, 'code=', code, `(pending=${pending.size} authed=${authedConns})`);
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
