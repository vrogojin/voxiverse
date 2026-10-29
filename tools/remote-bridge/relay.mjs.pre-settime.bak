// VOXIVERSE remote-play bridge — RELAY (Phase 1 observe + P1 control CORE).
// ----------------------------------------------------------------------------------------------
// A token-gated WebSocket server the GAME dials OUT to. It receives TELEMETRY (JSON text frames)
// and FRAMES (binary: 1-byte type tag + JPEG) from a real-GPU play session and writes them to
// files under results/remote/ that only the agent on this host reads.
//
// P1 CONTROL CORE (this file) adds the agent→game command path WITHOUT enabling live control
// (that is gated in the GAME client, P2/P4 — see docs/COSMOS-REMOTE-CONTROL-DESIGN.md §7). The
// Phase-1 policy "the relay NEVER sends anything back that the game acts on" is REPLACED, not
// weakened, by a strict rule (design §3.2):
//
//   The relay forwards to a game socket ONLY bytes that originate from a local file the host
//   agent wrote into control/outbox/, and ONLY to a socket that is (a) token-authed AND (b) has an
//   active control GRANT that the human in the game armed. Nothing a WS client sends is ever
//   forwarded to another socket or reflected back — game-originated messages remain record-only.
//   The relay itself never authors commands. Default is DENY: no outbox file + no grant => the
//   game behaves EXACTLY as Phase-1 observe-only (byte-identical for a client that never grants).
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
//   * COMMAND INGRESS IS THE HOST FILESYSTEM ONLY. The single trust anchor for control is write
//     access to control/outbox/ on this host — no WS client, HTTP path, or game message can inject
//     a command. Files are ingested atomically (act only on a fully-renamed *.json).
//
// Run:   REMOTE_BRIDGE_TOKEN=... node relay.mjs           (or drop the secret in ./.token)
//        node relay.mjs --port 8090 --results ./results/remote --control ./control
//
// Read (agent): results/remote/telemetry.jsonl  (append-only, capped)  and
//               results/remote/frame-latest.jpg (most recent frame) + results/remote/frames/ (ring).
//               control/results/<seq>/{ack.json,events.jsonl,done.json,shot-<id>-<label>.jpg}.

import { WebSocketServer } from 'ws';
import { createServer } from 'node:http';
import { readFileSync, mkdirSync, appendFileSync, writeFileSync, statSync, readdirSync, unlinkSync, renameSync, existsSync } from 'node:fs';
import { createHash, createHmac, timingSafeEqual, randomBytes } from 'node:crypto';
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

// Control (P1) sinks — see design §2.2. All gitignored (received/agent-written runtime data).
const CONTROL_DIR = argOf('control', process.env.REMOTE_BRIDGE_CONTROL || join(HERE, 'control'));
const OUTBOX_DIR = join(CONTROL_DIR, 'outbox');        // agent WRITES <seq>.json here (only command source)
const SENT_DIR = join(CONTROL_DIR, 'sent');            // relay moves a forwarded file here (audit trail)
const REJECTED_DIR = join(CONTROL_DIR, 'rejected');    // relay moves an invalid file here + <seq>.reject.txt
const CONTROL_RESULTS_DIR = join(CONTROL_DIR, 'results'); // results/<seq>/{ack,events,done,shot}
const AUDIT_LOG = join(CONTROL_DIR, 'audit.log');      // append-only: grants/forwards/rejects/revokes

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

const FRAME_TAG = 0x01;              // ambient frame  [0x01][jpeg]           — must match RemoteBridge.FRAME_TAG
const SHOT_TAG = 0x02;               // commanded shot [0x02][u16 hlen][hdr][jpeg] — design §3.3

// ── Control caps (design §1.3; validated here AND re-validated on the rover) ──────────────────
const POLL_MS = parseInt(process.env.REMOTE_BRIDGE_POLL_MS || '500', 10);     // outbox poll cadence (fs.watch is unreliable on bind mounts)
const CTRL_PING_MS = parseInt(process.env.REMOTE_BRIDGE_PING_MS || '5000', 10); // control heartbeat while granted
const CTRL_MAX_MISSED_PINGS = 3;     // missed pongs while granted => drop consent (fail-safe to stop, §5.4)
const MAX_STEPS = 64;                // steps per sequence
const MAX_MOVE_BLOCKS = 128;         // move.blocks per step
const MAX_TOTAL_DURATION_S = 180;    // Σ expected step time (watchdog outer bound)
const MAX_CMD_BYTES = 16 * 1024;     // sequence JSON size
const STALE_S = 120;                 // `issued` older than this => rejected (a delayed/re-sent file must not fire late)
// Closed op whitelist (design §1.1 + resolved D5 full-agency set). Validation only routes in P1.
const OP_WHITELIST = new Set(['move', 'turn', 'look', 'wait', 'jump', 'screenshot', 'set_fly', 'stop', 'break', 'place', 'select_slot', 'reload',
  // COSMOS SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md) — dev/test space-nav verbs. Still consent-gated + control-token
  // gated exactly like every op; the relay only ROUTES, the rover re-validates and executes behind the grant.
  'dev_nav', 'nav', 'thrust', 'roll']);
const MAX_HOLD_S = 120;              // SPACE-FLY: cap on a single thrust/roll timed HELD-input step

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

// Constant-time equality for the relay-minted grant nonce (F1). Both sides are SHA-256 digested to a
// fixed 32 bytes first, so a length mismatch never throws and the compare leaks no timing.
function nonceOk(candidate, minted) {
  if (!minted || typeof candidate !== 'string') return false;
  const h = (s) => createHash('sha256').update(String(s)).digest();
  return timingSafeEqual(h(candidate), h(minted));
}

// ── Control credential (#113) — a SECOND host secret, distinct from the observe token ────────────
// The observe token above only ever grants OBSERVE. A control GRANT must ADDITIONALLY prove knowledge
// of this secret (nonce-bound HMAC, §9.2), so control cryptographically cannot ride the shared,
// URL-carried observe token. Source mirrors loadToken(): env → sibling .control-token file → ''.
function loadControlToken() {
  const env = (process.env.REMOTE_BRIDGE_CONTROL_TOKEN || '').trim();
  if (env) return env;
  try {
    const t = readFileSync(join(HERE, '.control-token'), 'utf8').trim();
    if (t) return t;
  } catch { /* no file */ }
  return '';
}
const CONTROL_TOKEN = loadControlToken();
// FAIL-CLOSED (§9.1): control is enabled ONLY when a control secret is present AND it is DISTINCT from
// the observe token (never collapse the two factors into one). Otherwise every grant is refused, no
// offers are sent, and outbox files are rejected `control_disabled` — the observe path is untouched, so
// a relay deployed with no .control-token is byte-for-byte the Phase-1 observe bridge for live clients.
const CONTROL_AVAILABLE = !!CONTROL_TOKEN && CONTROL_TOKEN !== TOKEN;

// The grant proof (#113, §9.2): proof = hex(HMAC-SHA256(control_secret, "vxv-ctl-grant.v1\n" + nonce)).
// Recompute from OUR copy of the secret + the nonce WE minted for this socket, then constant-time compare
// against the candidate with the same double-SHA256 idiom as tokenOk/nonceOk (so the raw proof length
// never leaks and timingSafeEqual never throws). The secret itself never appears on the wire or in logs.
const CTRL_GRANT_MAC_PREFIX = 'vxv-ctl-grant.v1\n';
function proofOk(candidate, mintedNonce) {
  if (!CONTROL_AVAILABLE || !mintedNonce || typeof candidate !== 'string') return false;
  const expected = createHmac('sha256', CONTROL_TOKEN).update(CTRL_GRANT_MAC_PREFIX + mintedNonce).digest('hex');
  const h = (s) => createHash('sha256').update(String(s)).digest();
  return timingSafeEqual(h(candidate), h(expected));
}

// ── Result sinks ───────────────────────────────────────────────────────────────────────────────
mkdirSync(FRAMES_DIR, { recursive: true });
for (const d of [OUTBOX_DIR, SENT_DIR, REJECTED_DIR, CONTROL_RESULTS_DIR]) mkdirSync(d, { recursive: true });

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

// ── Control: audit + path safety ───────────────────────────────────────────────────────────────
function audit(event, fields = {}) {
  const parts = Object.entries(fields).map(([k, v]) => `${k}=${JSON.stringify(v)}`);
  try { appendFileSync(AUDIT_LOG, `${ts()} ${event} ${parts.join(' ')}\n`); } catch (e) { log('audit write error:', e.message); }
}

// A seq/id used to build a filesystem path MUST be a strict, traversal-proof token — a rogue game
// message can never escape control/results/. Anything else is refused (orphan-audited, never written).
const SAFE_ID = /^[A-Za-z0-9._-]{1,120}$/;
function safeId(s) { return typeof s === 'string' && SAFE_ID.test(s) && s !== '.' && s !== '..'; }

// A results dir is only valid for a seq we FORWARDED (its dir exists) — this binds every downlink
// result to a real, host-authored, consent-gated command and blocks arbitrary dir creation by the game.
function resultsDirFor(seq) {
  if (!safeId(seq)) return null;
  const d = join(CONTROL_RESULTS_DIR, seq);
  return existsSync(d) ? d : null;
}

function writeResult(seq, name, obj) {
  const d = resultsDirFor(seq);
  if (!d) { audit('result_orphan', { seq: String(seq).slice(0, 60), name }); return; }
  const stamped = { ...obj, _rx: obj._rx || ts() };
  const tmp = join(d, name + '.tmp');
  try { writeFileSync(tmp, JSON.stringify(stamped)); renameSync(tmp, join(d, name)); }
  catch (e) { log('result write error:', e.message); }
}

function appendEvent(seq, obj) {
  const d = resultsDirFor(seq);
  if (!d) { audit('event_orphan', { seq: String(seq).slice(0, 60), type: obj && obj.type }); return; }
  try { appendFileSync(join(d, 'events.jsonl'), JSON.stringify({ ...obj, _rx: obj._rx || ts() }) + '\n'); }
  catch (e) { log('event write error:', e.message); }
}

// ── Control: command validation (design §1) ──────────────────────────────────────────────────
function rej(reason, detail) { return { ok: false, reason, detail, est: 0 }; }
function okEst(est) { return { ok: true, est }; }

// A break/place `target` is intentionally loosely specified in the design (D5). Accept the safe
// shapes only: a [x,y,z] cell, the raycast sentinel "aim"/"look", or a small object — never a string
// that could be interpreted elsewhere (the relay only routes; the rover re-validates against reach).
function validTarget(t) {
  if (typeof t === 'string') return t === 'aim' || t === 'look';
  if (Array.isArray(t)) return t.length === 3 && t.every((n) => typeof n === 'number' && isFinite(n));
  return typeof t === 'object' && t !== null;
}

function validateStep(st) {
  switch (st.op) {
    case 'move': {
      if (typeof st.blocks !== 'number' || !(st.blocks > 0)) return rej('caps', 'move.blocks must be > 0');
      if (st.blocks > MAX_MOVE_BLOCKS) return rej('caps', `move.blocks ${st.blocks} > ${MAX_MOVE_BLOCKS}`);
      const heading = st.heading ?? 'forward';
      if (!['forward', 'back', 'left', 'right'].includes(heading)) return rej('caps', `bad heading '${heading}'`);
      const gait = st.gait ?? 'walk';
      if (!['walk', 'run'].includes(gait)) return rej('caps', `bad gait '${gait}'`);
      return okEst(st.blocks / (gait === 'run' ? 9.5 : 5.5));
    }
    case 'turn': {
      if (typeof st.degrees !== 'number' || !(st.degrees > 0)) return rej('caps', 'turn.degrees must be > 0');
      if (!['left', 'right'].includes(st.dir)) return rej('caps', `bad turn dir '${st.dir}'`);
      return okEst(st.degrees / 120);
    }
    case 'look': {
      if (st.pitch_deg !== undefined && (typeof st.pitch_deg !== 'number' || st.pitch_deg < -85 || st.pitch_deg > 85))
        return rej('caps', 'look.pitch_deg out of [-85,85]');
      if (st.yaw_deg !== undefined && typeof st.yaw_deg !== 'number') return rej('caps', 'look.yaw_deg not a number');
      return okEst(Math.max(0.2, st.yaw_deg ? Math.abs(st.yaw_deg) / 120 : 0));
    }
    case 'wait': {
      if (typeof st.seconds !== 'number' || !(st.seconds > 0) || st.seconds > 60) return rej('caps', 'wait.seconds must be in (0,60]');
      return okEst(st.seconds);
    }
    case 'jump': return okEst(1.0);
    case 'screenshot': {
      if (st.label !== undefined && (typeof st.label !== 'string' || !/^[a-z0-9-]{0,40}$/.test(st.label)))
        return rej('caps', 'screenshot.label must be [a-z0-9-]{0,40}');
      return okEst(0.5);
    }
    case 'set_fly': {
      if (typeof st.on !== 'boolean') return rej('caps', 'set_fly.on must be a bool');
      return okEst(0.2);
    }
    case 'stop': return okEst(0.1);
    case 'reload': return okEst(2.0);                   // §6.6: reload the browser to pick up a fresh deploy (grant-gated, game-side)
    // COSMOS SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md) — the space-nav test verbs.
    case 'dev_nav': {                                   // F: toggle dev-nav to a definite state
      if (typeof st.on !== 'boolean') return rej('caps', 'dev_nav.on must be a bool');
      return okEst(0.2);
    }
    case 'nav': {                                       // O/G/R: orbit-coast / geostationary / detach
      if (!['orbit', 'geostation', 'detach'].includes(st.verb)) return rej('caps', `bad nav.verb '${st.verb}'`);
      return okEst(0.2);
    }
    case 'thrust': {                                     // WASD+Space/Ctrl held: dx/dy/dz body-local wish for `seconds`
      if (typeof st.seconds !== 'number' || !(st.seconds > 0) || st.seconds > MAX_HOLD_S) return rej('caps', `thrust.seconds must be in (0,${MAX_HOLD_S}]`);
      for (const k of ['dx', 'dy', 'dz']) if (st[k] !== undefined && (typeof st[k] !== 'number' || !isFinite(st[k]))) return rej('caps', `thrust.${k} not finite`);
      if (st.gait !== undefined && !['walk', 'run'].includes(st.gait)) return rej('caps', `bad gait '${st.gait}'`);
      return okEst(st.seconds);
    }
    case 'roll': {                                       // Q/E held: roll for `seconds`
      if (typeof st.seconds !== 'number' || !(st.seconds > 0) || st.seconds > MAX_HOLD_S) return rej('caps', `roll.seconds must be in (0,${MAX_HOLD_S}]`);
      if (st.dir !== undefined && !['left', 'right'].includes(st.dir)) return rej('caps', `bad roll dir '${st.dir}'`);
      return okEst(st.seconds);
    }
    case 'break': {                                     // D5 world mutation — routed the same, still consent-gated
      if (st.target === undefined || !validTarget(st.target)) return rej('caps', 'break.target invalid');
      return okEst(0.5);
    }
    case 'place': {
      if (st.block === undefined || (typeof st.block !== 'number' && typeof st.block !== 'string')) return rej('caps', 'place.block required');
      if (st.target === undefined || !validTarget(st.target)) return rej('caps', 'place.target invalid');
      return okEst(0.5);
    }
    case 'select_slot': {
      if (typeof st.n !== 'number' || !Number.isInteger(st.n) || st.n < 0 || st.n > 15) return rej('caps', 'select_slot.n out of range');
      return okEst(0.1);
    }
    default: return rej('caps', `unhandled op '${st.op}'`); // unreachable — whitelist checked in validateCmd
  }
}

function validateCmd(cmd) {
  if (typeof cmd !== 'object' || cmd === null) return rej('bad_json', 'not an object');
  if (cmd.type !== 'cmd_seq') return rej('bad_json', `type != cmd_seq ('${cmd.type}')`);
  if (!safeId(cmd.seq)) return rej('bad_json', 'missing/invalid seq id');
  if (typeof cmd.issued !== 'number' || !isFinite(cmd.issued)) return rej('bad_json', 'issued not a finite number');
  const onFail = cmd.on_fail ?? 'abort';
  if (onFail !== 'abort' && onFail !== 'continue') return rej('caps', `on_fail invalid '${onFail}'`);
  if (cmd.preempt !== undefined && typeof cmd.preempt !== 'boolean') return rej('bad_json', 'preempt not a bool');
  if (!Array.isArray(cmd.steps)) return rej('bad_json', 'steps not an array');
  if (cmd.steps.length < 1) return rej('caps', 'no steps');
  if (cmd.steps.length > MAX_STEPS) return rej('caps', `steps ${cmd.steps.length} > ${MAX_STEPS}`);
  let est = 0;
  for (let i = 0; i < cmd.steps.length; i++) {
    const st = cmd.steps[i];
    if (typeof st !== 'object' || st === null) return rej('bad_json', `step ${i} not an object`);
    if (!OP_WHITELIST.has(st.op)) return rej('caps', `step ${i} op '${st.op}' not in whitelist`);
    const e = validateStep(st);
    if (!e.ok) return { ...e, detail: `step ${i}: ${e.detail}` };
    est += e.est;
  }
  if (est > MAX_TOTAL_DURATION_S) return rej('caps', `est duration ${est.toFixed(1)}s > ${MAX_TOTAL_DURATION_S}`);
  return { ok: true };
}

// ── Control: consent state machine + forward gate ─────────────────────────────────────────────
const authedSockets = new Set();     // conn records for token-authed sockets
const ingestedFiles = new Set();     // outbox filenames already processed (waiting or resolved) — avoids re-ingest
const seenSeqs = new Map();          // seq id -> first-seen ms (duplicate detection; pruned past staleness, F5)
const waiting = [];                  // validated commands awaiting a grant: {seq,text,file,issued,preempt}
let inFlightSeq = null;              // the ONE sequence currently forwarded+running (exactly 1 in flight)
let inFlightOwner = null;            // conn running inFlightSeq

function activeGranted() {
  for (const c of authedSockets) if (c.controlState === 'granted') return c;
  return null;
}

// F1: a downlink RESULT (cmd_ack/nack, step_*, seq_done, shot) is honoured ONLY from the granted socket
// that actually owns the in-flight sequence — the one the relay forwarded it to. Any other socket's
// event for that seq is a forgery and dropped, so a 2nd token-holding socket cannot poison results.
function ownsDownlink(conn, seq) {
  return conn === inFlightOwner && conn.controlState === 'granted'
    && inFlightSeq !== null && String(seq) === String(inFlightSeq);
}

function rejectFile(file, seq, reason, detail) {
  const src = join(OUTBOX_DIR, file);
  const base = safeId(seq) ? seq : String(file).replace(/\.json$/, '');
  const dst = join(REJECTED_DIR, file);
  try { renameSync(src, dst); } catch { try { unlinkSync(src); } catch { /* raced/gone */ } }
  try { writeFileSync(join(REJECTED_DIR, `${base}.reject.txt`), `${ts()} reason=${reason} detail=${detail || ''}\n`); }
  catch (e) { log('reject-reason write error:', e.message); }
  ingestedFiles.delete(file);
  audit('reject', { seq: seq || null, file, reason, detail: detail || '' });
  log('REJECT outbox:', file, `[${reason}]`, detail || '');
}

// Offer control to any authed, ungranted socket so the human can arm a grant (design §6.1 step 1).
// F1: mint a fresh, cryptographically-random per-socket `grant_nonce` and include it in the offer. The
// game must echo THIS exact nonce back in its `control_state:granted` — a socket that never received (or
// cannot guess) the nonce it was minted cannot forge a grant. The nonce is per-socket (delivered only on
// that socket's wss offer) and stays valid until the next offer re-mints it, so an unattended re-arm
// (§6.6, no fresh offer) can legitimately re-echo it while a cross-socket forge still fails.
function offerControlToAll(seq) {
  if (!CONTROL_AVAILABLE) return;   // #113 fail-closed: no control secret ⇒ no offers, so no grant can arm.
  for (const c of authedSockets) {
    if (c.controlState === 'none' && !c.offerSent) {
      c.offerSent = true;
      c.grantNonce = randomBytes(24).toString('hex');
      try { c.ws.send(JSON.stringify({ type: 'control_offer', seq, grant_nonce: c.grantNonce, t: Date.now() / 1000 })); } catch { /* ignore */ }
      audit('offer', { peer: c.peer, seq });
    }
  }
}

function forward(entry, conn, preempted) {
  const src = join(OUTBOX_DIR, entry.file);
  const dst = join(SENT_DIR, entry.file);
  try { renameSync(src, dst); } catch { /* may already be gone; forward is still authoritative */ }
  ingestedFiles.delete(entry.file);
  try { mkdirSync(join(CONTROL_RESULTS_DIR, entry.seq), { recursive: true }); } catch { /* ignore */ }
  if (preempted && inFlightSeq && inFlightSeq !== entry.seq) {
    // D3: the running sequence is aborted-and-replaced. Synthesize its terminal record for the agent.
    writeResult(inFlightSeq, 'done.json', { type: 'seq_done', seq: inFlightSeq, status: 'aborted', reason: 'preempted', _rx: ts() });
    audit('preempt', { new_seq: entry.seq, aborted_seq: inFlightSeq });
  }
  inFlightSeq = entry.seq;
  inFlightOwner = conn;
  try { conn.ws.send(entry.text); } catch (e) { log('forward send error:', e.message); }  // verbatim host bytes
  audit('forward', { seq: entry.seq, peer: conn.peer, grant_id: conn.grantId, preempt: !!preempted });
  log('FORWARD:', entry.seq, '->', conn.peer, preempted ? '(preempt)' : '');
}

// The single forward gate. DEFAULT-DENY: with no active grant a valid command WAITS (never forwards).
function dispatchOrHold(entry) {
  const wi = waiting.indexOf(entry); if (wi >= 0) waiting.splice(wi, 1);
  // #113 fail-closed (§9.1): with no usable control secret, control is disabled entirely — a command can
  // never be consented to, so REJECT (do not hold) rather than let a file wait forever for an offer that
  // will never come. This is the outbox counterpart of the disabled offer/grant paths.
  if (!CONTROL_AVAILABLE) {
    rejectFile(entry.file, entry.seq, 'control_disabled', 'relay has no control secret (control disabled)');
    return;
  }
  const granted = activeGranted();
  if (!granted) {
    waiting.push(entry);
    offerControlToAll(entry.seq);
    audit('hold', { seq: entry.seq, reason: 'no_consent' });
    log('HOLD (no consent):', entry.seq);
    return;
  }
  if (inFlightSeq !== null) {
    if (entry.preempt) forward(entry, granted, true);
    else rejectFile(entry.file, entry.seq, 'busy', `seq '${inFlightSeq}' already in flight`);
    return;
  }
  forward(entry, granted, false);
}

// Try to move held commands once a grant exists (FIFO). The first forwards; any further while one is
// in flight resolve via the same gate (busy unless preempt).
function flushWaiting() {
  if (!activeGranted()) return;
  for (const entry of waiting.slice()) {
    if (waiting.indexOf(entry) < 0) continue;   // already resolved this pass
    dispatchOrHold(entry);
    if (!activeGranted()) break;
  }
}

function failWaiting(reason, detail) {
  for (const entry of waiting.slice()) {
    const wi = waiting.indexOf(entry); if (wi >= 0) waiting.splice(wi, 1);
    rejectFile(entry.file, entry.seq, reason, detail);
  }
}

function sweepWaiting() {
  const nowS = Date.now() / 1000;
  for (const entry of waiting.slice()) {
    if (nowS - entry.issued > STALE_S) {
      const wi = waiting.indexOf(entry); if (wi >= 0) waiting.splice(wi, 1);
      rejectFile(entry.file, entry.seq, 'no_consent', `waited past ${STALE_S}s staleness with no grant`);
    }
  }
}

function ingestFile(file) {
  ingestedFiles.add(file);
  const src = join(OUTBOX_DIR, file);
  let raw;
  try { raw = readFileSync(src); } catch { ingestedFiles.delete(file); return; }  // vanished/raced — retry next poll
  if (raw.length > MAX_CMD_BYTES) { rejectFile(file, null, 'caps', `oversize ${raw.length}B > ${MAX_CMD_BYTES}`); return; }
  let cmd;
  try { cmd = JSON.parse(raw.toString('utf8')); } catch { rejectFile(file, null, 'bad_json', 'JSON parse error'); return; }
  const v = validateCmd(cmd);
  if (!v.ok) { rejectFile(file, cmd && cmd.seq, v.reason, v.detail); return; }
  const seq = cmd.seq;
  if (seenSeqs.has(seq)) { rejectFile(file, seq, 'duplicate', 'seq already seen this run'); return; }
  if (Date.now() / 1000 - cmd.issued > STALE_S) { rejectFile(file, seq, 'stale', `issued ${(Date.now() / 1000 - cmd.issued).toFixed(0)}s ago > ${STALE_S}`); return; }
  seenSeqs.set(seq, Date.now());
  dispatchOrHold({ seq, text: raw.toString('utf8'), file, issued: cmd.issued, preempt: cmd.preempt === true });
}

function pollOutbox() {
  let files;
  try { files = readdirSync(OUTBOX_DIR); } catch { return; }
  for (const f of files) {
    if (!f.endsWith('.json') || f.startsWith('.') || f.endsWith('.tmp') || ingestedFiles.has(f)) continue;
    try { ingestFile(f); }
    catch (e) { log('ingest error:', f, e.message); try { rejectFile(f, null, 'bad_json', 'ingest exception'); } catch { /* ignore */ } }
  }
  // NEVER-OOM (F5): forget ingest markers whose outbox file is gone (forwarded→sent/ or moved to
  // rejected/). Files still waiting for a grant remain present in the listing, so they are kept; the
  // set therefore tracks only live files and cannot grow without bound over a long-lived relay.
  const present = new Set(files);
  for (const f of ingestedFiles) if (!present.has(f)) ingestedFiles.delete(f);
  sweepWaiting();
}

// NEVER-OOM (F5): prune the run-lifetime maps so a long-lived relay's memory stays bounded.
//   * seenSeqs — drop entries older than the staleness window (+ margin); a replay past that window is
//     rejected `stale` by ingest anyway (§1.3), so forgetting it changes nothing security-relevant.
//   * ipConnects — drop IPs whose recent-connect list has fully aged out of the pre-auth window.
function pruneMaps() {
  const now = Date.now();
  const seqTtl = (STALE_S + 60) * 1000;
  for (const [seq, t] of seenSeqs) if (now - t > seqTtl) seenSeqs.delete(seq);
  for (const [ip, arr] of ipConnects) {
    const keep = arr.filter((t) => now - t < PREAUTH_WINDOW_MS);
    if (keep.length) ipConnects.set(ip, keep); else ipConnects.delete(ip);
  }
}

// ── Control: heartbeat + grant lifecycle ─────────────────────────────────────────────────────
function startHeartbeat(conn) {
  stopHeartbeat(conn);
  conn.missedPings = 0;
  conn.heartbeat = setInterval(() => {
    if (conn.ws.readyState !== conn.ws.OPEN) { stopHeartbeat(conn); return; }
    if (conn.missedPings >= CTRL_MAX_MISSED_PINGS) {
      audit('ping_timeout', { peer: conn.peer });
      log('CONTROL ping timeout — dropping grant:', conn.peer);
      revokeGrant(conn, 'link_lost');
      return;
    }
    conn.missedPings++;                       // reset to 0 on each control_pong
    try { conn.ws.send(JSON.stringify({ type: 'control_ping', t: Date.now() / 1000 })); } catch { /* ignore */ }
  }, CTRL_PING_MS);
}

function stopHeartbeat(conn) {
  if (conn.heartbeat) { clearInterval(conn.heartbeat); conn.heartbeat = null; }
}

// If a granted socket ends its grant while a sequence it owns is running, synthesize that sequence's
// terminal record so the agent's loop always terminates (fail-safe-to-stop, §5.4).
function abortInFlight(conn, status) {
  if (inFlightOwner === conn && inFlightSeq) {
    writeResult(inFlightSeq, 'done.json', { type: 'seq_done', seq: inFlightSeq, status, _rx: ts(), _synthesized: true });
    audit('seq_end', { seq: inFlightSeq, status, synthesized: true });
    inFlightSeq = null; inFlightOwner = null;
  }
}

function revokeGrant(conn, reason) {
  if (conn.controlState === 'none') { stopHeartbeat(conn); return; }
  abortInFlight(conn, reason === 'link_lost' ? 'link_lost' : 'aborted');
  conn.controlState = 'none'; conn.grantId = null; conn.offerSent = false;
  stopHeartbeat(conn);
  try { conn.ws.send(JSON.stringify({ type: 'control_revoke', reason })); } catch { /* ignore */ }
  audit('revoke', { peer: conn.peer, reason });
  log('CONTROL revoked:', conn.peer, `[${reason}]`);
}

// #113 (§9.3): tell the game whether a `granted` was accepted or refused so its CONTROL badge never
// lies on a refusal (typo'd/rotated/stale key). Sent on EVERY granted attempt — the reason is never a
// secret, and the received proof is NEVER echoed back or logged.
function sendControlResult(conn, accepted, reason) {
  try { conn.ws.send(JSON.stringify({ type: 'control_result', accepted, reason: reason || null })); } catch { /* ignore */ }
}

function onControlState(conn, msg) {
  const state = msg.state;
  switch (state) {
    case 'granted': {
      if (conn.controlState === 'granted') return;   // already driving — ignore a duplicate granted
      const gid = typeof msg.grant_id === 'string' ? msg.grant_id : null;
      // F1a — MINTED-NONCE GATE: accept `granted` ONLY when it echoes the exact relay-minted nonce this
      // socket received in ITS `control_offer`. A socket that auths and immediately claims control (no
      // offer ⇒ no nonce), or echoes a wrong/guessed nonce, is refused. The human consent still gates it
      // game-side; this binds the wire grant to a real relay offer delivered to THIS socket.
      if (!nonceOk(msg.grant_nonce, conn.grantNonce)) {
        audit('grant_rejected', { peer: conn.peer, reason: 'bad_nonce' });
        log('CONTROL grant REJECTED (bad/absent minted nonce):', conn.peer);
        sendControlResult(conn, false, 'bad_nonce');
        return;
      }
      // #113 — CONTROL-SECRET GATE. Two AND-ed requirements ON TOP of the F1 nonce:
      //   (1) control must be enabled relay-side at all (fail-closed if no/degenerate secret), and
      //   (2) the grant must carry a valid `grant_proof` = HMAC(control_secret, minted nonce). An
      // observe-token-only socket receives the offer + nonce but CANNOT forge this proof, so the
      // first-grant race (§9.0 residual) is closed — control cannot ride the observe token.
      if (!CONTROL_AVAILABLE) {
        audit('grant_rejected', { peer: conn.peer, reason: 'no_control_secret' });
        log('CONTROL grant REFUSED (control disabled — no control secret):', conn.peer);
        sendControlResult(conn, false, 'no_control_secret');
        return;
      }
      if (!proofOk(msg.grant_proof, conn.grantNonce)) {
        audit('grant_rejected', { peer: conn.peer, reason: 'bad_proof' });   // NB: never log the received proof
        log('CONTROL grant REFUSED (bad/absent grant_proof):', conn.peer);
        sendControlResult(conn, false, 'bad_proof');
        return;
      }
      // F1b — NO-SUPERSEDE: a second authed socket can NEVER wrest a standing valid grant away (was:
      // "most-recently-granted wins"). While one socket holds control, another's grant is refused —
      // this is what stops a 2nd token-holder from stealing/oscillating the grant.
      const holder = activeGranted();
      if (holder && holder !== conn) {
        audit('grant_rejected', { peer: conn.peer, reason: 'already_held', holder: holder.peer });
        log('CONTROL grant REJECTED (another socket already holds control):', conn.peer);
        sendControlResult(conn, false, 'already_held');
        return;
      }
      conn.controlState = 'granted'; conn.grantId = gid; conn.offerSent = false;
      startHeartbeat(conn);
      audit('grant', { peer: conn.peer, grant_id: gid });
      log('CONTROL granted:', conn.peer, 'grant_id=', gid);
      sendControlResult(conn, true, null);
      flushWaiting();
      break;
    }
    case 'denied':
      conn.controlState = 'none'; conn.grantId = null; conn.offerSent = false; stopHeartbeat(conn);
      audit('deny', { peer: conn.peer });
      log('CONTROL denied:', conn.peer);
      failWaiting('no_consent', 'control denied by human');
      break;
    case 'revoked':
      revokeGrant(conn, 'revoked');
      break;
    case 'override':
      // D2: any local human input ENDS the grant. Forwarding suspends and NEVER silently resumes —
      // a fresh `granted` is required. Held commands stay held (they wait for the re-grant).
      audit('override', { peer: conn.peer, grant_id: conn.grantId });
      log('CONTROL override — grant ended, re-consent required:', conn.peer);
      abortInFlight(conn, 'user_override');
      conn.controlState = 'none'; conn.grantId = null; conn.offerSent = false;
      stopHeartbeat(conn);
      break;
    default:
      audit('control_state_unknown', { peer: conn.peer, state: String(state).slice(0, 40) });
  }
}

// Set of downlink RESULT types that must be tagged to the owning granted socket (F1).
const RESULT_TYPES = new Set(['cmd_ack', 'cmd_nack', 'step_start', 'step_done', 'seq_done']);

// Route a downlink text frame. Returns true if it was a recognized control event. Game-originated
// messages are RECORD-ONLY — never forwarded to another socket or reflected back.
function routeControlEvent(conn, obj) {
  if (obj.type === 'control_state') { onControlState(conn, obj); return true; }
  if (obj.type === 'control_pong') { conn.missedPings = 0; return true; }
  if (!RESULT_TYPES.has(obj.type)) return false;   // telemetry etc. — already recorded by the caller
  // F1c — PER-SOCKET RESULT TAGGING: only the socket that owns the in-flight seq may write its results.
  // A forged event from a non-owning (e.g. 2nd token-holding) socket is dropped, never touching disk.
  if (!ownsDownlink(conn, obj.seq)) {
    audit('result_forged', { peer: conn.peer, type: obj.type, seq: String(obj && obj.seq).slice(0, 60) });
    return true;
  }
  switch (obj.type) {
    case 'cmd_ack':
      writeResult(obj.seq, 'ack.json', obj);
      if (conn.grantId && obj.grant_id && obj.grant_id !== conn.grantId)
        audit('grant_id_mismatch', { seq: obj.seq, got: String(obj.grant_id).slice(0, 40), want: conn.grantId });
      audit('ack', { seq: obj.seq, steps: obj.steps });
      return true;
    case 'cmd_nack':
      writeResult(obj.seq, 'ack.json', obj);
      writeResult(obj.seq, 'done.json', { type: 'seq_done', seq: obj.seq, status: 'nack', reason: obj.reason, _rx: ts() });
      if (inFlightSeq === obj.seq) { inFlightSeq = null; inFlightOwner = null; }
      audit('nack', { seq: obj.seq, reason: obj.reason });
      return true;
    case 'step_start':
    case 'step_done':
      appendEvent(obj.seq, obj);
      return true;
    case 'seq_done':
      appendEvent(obj.seq, obj);
      writeResult(obj.seq, 'done.json', obj);
      if (inFlightSeq === obj.seq) { inFlightSeq = null; inFlightOwner = null; }
      audit('seq_done', { seq: obj.seq, status: obj.status });
      return true;
  }
  return true;
}

// A commanded screenshot: [0x02][u16 BE header_len][header JSON: {seq,id,label,t}][jpeg]. Written to
// the correlated results dir AND refreshed as frame-latest.jpg (it is, after all, the latest frame).
function handleShotFrame(conn, data) {
  if (data.length < 3) return;
  const hlen = data.readUInt16BE(1);
  if (data.length < 3 + hlen) return;
  let hdr;
  try { hdr = JSON.parse(data.subarray(3, 3 + hlen).toString('utf8')); } catch { return; }
  const jpg = data.subarray(3 + hlen);
  if (jpg.length < 2 || jpg[0] !== 0xff || jpg[1] !== 0xd8) return;         // JPEG magic
  const d = resultsDirFor(hdr.seq);
  if (!d) { audit('shot_orphan', { seq: String(hdr.seq).slice(0, 60) }); return; }
  // F1c: a commanded shot is a downlink result — accept it only from the owning granted socket.
  if (!ownsDownlink(conn, hdr.seq)) { audit('shot_forged', { peer: conn.peer, seq: String(hdr.seq).slice(0, 60) }); return; }
  const idPart = safeId(String(hdr.id)) ? String(hdr.id) : 'x';
  const labelPart = (typeof hdr.label === 'string' && /^[a-z0-9-]{1,40}$/.test(hdr.label)) ? hdr.label : 'shot';
  try { writeFileSync(join(d, `shot-${idPart}-${labelPart}.jpg`), jpg); } catch (e) { log('shot write error:', e.message); }
  try { writeFrame(jpg); } catch { /* frame-latest refresh is best-effort */ }
  audit('shot', { seq: hdr.seq, id: idPart, label: labelPart, bytes: jpg.length });
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

// F5: the real browser IP for the per-IP rate limit. The relay only ever sees traffic via our own nginx
// (never host-published), so `req.socket.remoteAddress` is ALWAYS the nginx container IP — keying the
// limit on it would make a global limit any one attacker could trip to lock out every browser. nginx
// sets `X-Real-IP: $remote_addr` (voxiverse.conf.template) with the true client IP; use it, validated to
// a single IP literal (only hex/digit/dot/colon, ≤ 45 chars) so a malformed value falls back safely.
function clientIp(req) {
  const xri = req.headers['x-real-ip'];
  if (typeof xri === 'string') {
    const v = xri.trim();
    if (v && v.length <= 45 && /^[0-9a-fA-F.:]+$/.test(v)) return v;
  }
  return req.socket.remoteAddress || 'unknown';
}

wss.on('connection', (ws, req) => {
  const ip = clientIp(req);
  const peer = ip + ':' + req.socket.remotePort;
  // Per-connection control record. Inert until this socket both authenticates AND is granted control.
  const conn = { ws, peer, ip, controlState: 'none', grantId: null, grantNonce: '', heartbeat: null, missedPings: 0, offerSent: false };

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
      authedSockets.add(conn);
      clearTimeout(authTimer);
      // App-level AUTH-ACK: the client withholds ALL telemetry + frame capture until it receives this,
      // so an unauthenticated visitor never reads back or streams a single frame (closes the brief
      // pre-rejection capture window). It is also the handshake the P1 controls ride.
      try { ws.send(JSON.stringify({ type: 'auth_ok' })); } catch { /* ignore */ }
      log('AUTH-OK:', peer, 'ver=', String(hello.ver || '?'), 'ua=', String(hello.ua || '?').slice(0, 80));
      return;
    }

    // ── Authenticated data ──────────────────────────────────────────────────────────────────
    if (isBinary) {
      if (data.length < 2) return;
      if (data[0] === FRAME_TAG) {
        // Ambient frame: [FRAME_TAG][jpeg...].
        const jpg = data.subarray(1);
        if (jpg.length < 2 || jpg[0] !== 0xff || jpg[1] !== 0xd8) return;  // JPEG magic FF D8
        try { writeFrame(jpg); } catch (e) { log('frame write error:', e.message); }
      } else if (data[0] === SHOT_TAG) {
        // Commanded screenshot: [SHOT_TAG][u16 hlen][header][jpeg...].
        try { handleShotFrame(conn, data); } catch (e) { log('shot frame error:', e.message); }
      }
      // unknown binary tag — ignore
      return;
    }

    // Text = telemetry JSON. Stamp with server receive time + peer, append (Phase-1, UNCHANGED),
    // then additionally route any recognized control event (record-only — never forwarded onward).
    let obj;
    try { obj = JSON.parse(data.toString('utf8')); } catch { return; }
    obj._rx = ts();
    obj._peer = peer;
    try { writeTelemetry(obj); } catch (e) { log('telemetry write error:', e.message); }
    try { routeControlEvent(conn, obj); } catch (e) { log('control route error:', e.message); }
  });

  ws.on('close', (code) => {
    clearTimeout(authTimer);
    if (authed) {
      authedConns = Math.max(0, authedConns - 1);
      authedSockets.delete(conn);
      // Link loss fail-safe (§5.4): end any grant this socket held and terminate its in-flight seq.
      if (conn.controlState !== 'none') {
        abortInFlight(conn, 'link_lost');
        audit('link_lost', { peer });
        conn.controlState = 'none'; conn.grantId = null;
      }
      stopHeartbeat(conn);
      // With no authed socket left, no one can consent — fail held commands rather than let them
      // leak into a later, different session's grant (§5.4: fail queued files on socket loss).
      if (authedSockets.size === 0) failWaiting('no_consent', 'authed socket closed; no consenter remains');
    } else pending.delete(ws);
    log('DISCONNECT:', peer, 'code=', code, `(pending=${pending.size} authed=${authedConns})`);
  });

  ws.on('error', (e) => {
    log('SOCKET-ERR:', peer, e.message);
  });
});

httpServer.listen(PORT, HOST, () => {
  log(`listening ws://${HOST}:${PORT}  results=${RESULTS_DIR}  control=${CONTROL_DIR}  cap=${MAX_CONNS}`);
  log('token loaded (' + TOKEN.length + ' chars). Waiting for the game to dial in.');
  // #113 control-credential status, logged ONCE, loudly (§9.1). Fail-closed is the safe default.
  if (CONTROL_AVAILABLE) {
    log('CONTROL credential loaded (' + CONTROL_TOKEN.length + ' chars) — grants require a valid grant_proof.');
  } else if (!CONTROL_TOKEN) {
    log('CONTROL DISABLED (no control secret: set REMOTE_BRIDGE_CONTROL_TOKEN or create .control-token) — all grants refused, outbox files rejected control_disabled; OBSERVE unaffected.');
  } else {
    log('CONTROL DISABLED (control secret EQUALS the observe token — refusing to collapse the two factors) — all grants refused, outbox files rejected control_disabled; OBSERVE unaffected.');
  }
});

// Outbox poller — the ONLY command ingress (design §5.1). Polling (not fs.watch) because fs.watch is
// unreliable on bind mounts, and 500 ms is ample for a half-duplex, latency-tolerant control loop.
const outboxPoller = setInterval(pollOutbox, POLL_MS);

// F5: periodic NEVER-OOM housekeeping for the run-lifetime maps (seenSeqs / ipConnects).
const MAINT_MS = 30000;
const maintPoller = setInterval(pruneMaps, MAINT_MS);

// Clean shutdown.
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    log('shutting down on', sig);
    clearInterval(outboxPoller);
    clearInterval(maintPoller);
    for (const c of authedSockets) stopHeartbeat(c);
    wss.close();
    httpServer.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000);
  });
}
