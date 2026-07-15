// Loopback smoke test for the remote-bridge relay (no game, no browser required).
// ----------------------------------------------------------------------------------------------
// PART A — Phase-1 observe path (unchanged): good client streams telemetry + a frame; bad-token
//   client is closed; authed sessions survive a pending flood.
// PART B — P1 CONTROL CORE (agent→game command path). A FAKE GAME CLIENT emulates the rover: auths,
//   optionally grants/overrides/revokes control, responds to control_ping, and — on a forwarded
//   cmd_seq — echoes cmd_ack + step_start/step_done + a 0x02 shot frame + seq_done. Asserts:
//     (a) a valid outbox seq is forwarded ONLY after a grant (and its results land on disk);
//     (b) NO grant => the command is NEVER forwarded  ← the key security assertion;
//     (c) an override ENDS the grant; a later command is not forwarded until a fresh grant;
//     (d) a preempt seq aborts a running seq (and a non-preempt seq during a run is `busy`);
//     (e) oversize/garbage/over-cap/stale/duplicate seqs are rejected with a reason, never forwarded,
//         and cannot crash the relay (a valid seq still forwards afterwards);
//     (f) Part-A telemetry/frame capture still works unchanged.
// Exits 0 on all-pass, 1 on any failure. Zero external deps beyond `ws`.

import { spawn } from 'node:child_process';
import { WebSocket } from 'ws';
import { mkdtempSync, readFileSync, existsSync, statSync, writeFileSync, renameSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOKEN = 'smoke-secret-' + Math.random().toString(36).slice(2);
const PORT = 8100 + Math.floor(Math.random() * 800);
const RESULTS = mkdtempSync(join(tmpdir(), 'vox-relay-smoke-'));
const CONTROL = join(RESULTS, 'control');
const OUTBOX = join(CONTROL, 'outbox');
const SENT = join(CONTROL, 'sent');
const REJECTED = join(CONTROL, 'rejected');
const CTRL_RESULTS = join(CONTROL, 'results');
const TELEMETRY_FILE = join(RESULTS, 'telemetry.jsonl');
const FRAME_LATEST = join(RESULTS, 'frame-latest.jpg');
const URL = `ws://127.0.0.1:${PORT}`;

// A minimal valid 1x1 JPEG (FF D8 ... FF D9).
const JPEG_1x1 = Buffer.from(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof' +
  'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB' +
  'AAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AfwD/2Q==',
  'base64');

const FRAME_TAG = 0x01;
const SHOT_TAG = 0x02;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function ok(cond, msg) {
  console.log((cond ? '  PASS ' : '  FAIL ') + msg);
  if (!cond) failures++;
}

// Atomically drop an outbox command file (temp write + rename — mirrors the agent/relay idiom).
function dropOutbox(cmd) {
  const name = `${cmd.seq}.json`;
  const tmp = join(OUTBOX, `.${name}.tmp`);
  writeFileSync(tmp, typeof cmd === 'string' ? cmd : JSON.stringify(cmd));
  renameSync(tmp, join(OUTBOX, name));
}
function dropRawOutbox(seq, rawBytes) {
  const name = `${seq}.json`;
  const tmp = join(OUTBOX, `.${name}.tmp`);
  writeFileSync(tmp, rawBytes);
  renameSync(tmp, join(OUTBOX, name));
}
function mkCmd(seq, steps, extra = {}) {
  return { type: 'cmd_seq', seq, issued: Date.now() / 1000, steps, ...extra };
}
async function waitFor(fn, timeoutMs = 4000, stepMs = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) { if (fn()) return true; await sleep(stepMs); }
  return fn();
}

// A fake game client that emulates the rover for control tests.
//   opts.autoRun: on receiving a cmd_seq, echo ack + per-step events + shot + seq_done (default true).
//   It records every received cmd_seq in `received` and control_offers in `offers`.
function makeFakeGame(tag) {
  const g = {
    ws: null, authed: false, received: [], offers: [], pings: 0, revokes: [],
    autoRun: true, holdSeq: null,   // holdSeq: a seq to ACK but NOT finish (simulate a long run)
    lastNonce: '',                  // F1: the relay-minted grant_nonce from the most recent control_offer
    answerPings: true,              // F2: set false to stop ponging → trip the relay's ping-timeout revoke
    sendRaw(obj) { g.ws.send(JSON.stringify(obj)); },
    // A proper grant ECHOES the minted nonce (F1) — the real game does this from control_offer.
    grant(grantId) { g.ws.send(JSON.stringify({ type: 'control_state', state: 'granted', grant_id: grantId || ('gid-' + tag), grant_nonce: g.lastNonce })); },
    grantRaw(grantId) { g.ws.send(JSON.stringify({ type: 'control_state', state: 'granted', grant_id: grantId || ('gid-' + tag) })); },           // NO nonce → must be refused
    grantWithNonce(nonce, grantId) { g.ws.send(JSON.stringify({ type: 'control_state', state: 'granted', grant_id: grantId || ('gid-' + tag), grant_nonce: nonce })); },
    deny() { g.ws.send(JSON.stringify({ type: 'control_state', state: 'denied' })); },
    override() { g.ws.send(JSON.stringify({ type: 'control_state', state: 'override' })); },
    revoke() { g.ws.send(JSON.stringify({ type: 'control_state', state: 'revoked' })); },
    close() { try { g.ws.close(); } catch { /* ignore */ } },
  };
  function runSeq(cmd) {
    const seq = cmd.seq;
    g.ws.send(JSON.stringify({ type: 'cmd_ack', seq, steps: cmd.steps.length, grant_id: 'gid-' + tag, t: Date.now() / 1000 }));
    if (g.holdSeq === seq) return;            // simulate a long-running seq: ack only, never finish
    (async () => {
      let completed = 0;
      for (const st of cmd.steps) {
        g.ws.send(JSON.stringify({ type: 'step_start', seq, id: st.id, op: st.op, t: Date.now() / 1000 }));
        await sleep(15);
        if (st.op === 'screenshot') {
          const label = (st.label || 'shot');
          const hdr = Buffer.from(JSON.stringify({ seq, id: st.id, label, t: Date.now() / 1000 }), 'utf8');
          const head = Buffer.alloc(3);
          head[0] = SHOT_TAG; head.writeUInt16BE(hdr.length, 1);
          g.ws.send(Buffer.concat([head, hdr, JPEG_1x1]), { binary: true });
        }
        g.ws.send(JSON.stringify({ type: 'step_done', seq, id: st.id, op: st.op, status: 'ok', t: Date.now() / 1000 }));
        completed++;
      }
      g.ws.send(JSON.stringify({ type: 'seq_done', seq, status: 'ok', completed, t: Date.now() / 1000 }));
    })();
  }
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    g.ws = ws;
    const timer = setTimeout(() => reject(new Error('fake-game auth timeout: ' + tag)), 4000);
    ws.on('open', () => ws.send(JSON.stringify({ type: 'hello', token: TOKEN, ua: 'fake-game-' + tag, ver: 'test' })));
    ws.on('message', (data, isBinary) => {
      if (isBinary) return;
      let m; try { m = JSON.parse(data.toString('utf8')); } catch { return; }
      switch (m.type) {
        case 'auth_ok': if (!g.authed) { g.authed = true; clearTimeout(timer); resolve(g); } break;
        case 'control_offer': g.offers.push(m.seq); g.lastNonce = m.grant_nonce || ''; break;   // F1: capture the minted nonce
        case 'control_ping': g.pings++; if (g.answerPings) ws.send(JSON.stringify({ type: 'control_pong', t: Date.now() / 1000 })); break;
        case 'control_revoke': g.revokes.push(m.reason); break;
        case 'cmd_seq': g.received.push(m); if (g.autoRun) runSeq(m); break;
        default: break;
      }
    });
    ws.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

function reasonFileFor(seq) {
  const p = join(REJECTED, `${seq}.reject.txt`);
  return existsSync(p) ? readFileSync(p, 'utf8') : '';
}
function gotSeq(game, seq) { return game.received.some((c) => c.seq === seq); }

async function main() {
  const relay = spawn(process.execPath,
    [join(HERE, 'relay.mjs'), '--port', String(PORT), '--results', RESULTS, '--control', CONTROL], {
      env: {
        ...process.env, REMOTE_BRIDGE_TOKEN: TOKEN,
        REMOTE_BRIDGE_MAX_PENDING: '2', REMOTE_BRIDGE_PREAUTH_PER_IP: '100', REMOTE_BRIDGE_MAX_CONNS: '4',
        REMOTE_BRIDGE_POLL_MS: '150', REMOTE_BRIDGE_PING_MS: '1000',
      },
      stdio: ['ignore', 'inherit', 'inherit'],
    });
  await sleep(700); // give it time to listen

  try {
    // ══ PART A — Phase-1 observe path (unchanged) ═════════════════════════════════════════════
    console.log('\n── PART A: Phase-1 observe path ──');
    // ── A1. GOOD client — real handshake: hello, WAIT for auth_ok, THEN stream ─────────────────
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
    let telem = existsSync(TELEMETRY_FILE) ? readFileSync(TELEMETRY_FILE, 'utf8') : '';
    ok(telem.includes('marker-A'), 'telemetry line contains our marker field');
    ok(telem.includes('"_rx"'), 'relay stamped a server receive time (_rx)');
    ok(existsSync(FRAME_LATEST), 'frame-latest.jpg was written');
    if (existsSync(FRAME_LATEST)) {
      const jpg = readFileSync(FRAME_LATEST);
      ok(jpg.length >= 2 && jpg[0] === 0xff && jpg[1] === 0xd8, 'frame-latest.jpg has JPEG magic (FF D8)');
    } else { ok(false, 'frame-latest.jpg has JPEG magic (FF D8)'); }

    const telemBytesBefore = existsSync(TELEMETRY_FILE) ? statSync(TELEMETRY_FILE).size : 0;

    // ── A2. BAD-token client ──────────────────────────────────────────────────────────────────
    const badResult = await new Promise((resolve) => {
      const ws = new WebSocket(URL);
      let closedCode = null, sawAuthOk = false;
      const timer = setTimeout(() => resolve({ closedCode, sawAuthOk, timedOut: true }), 4000);
      ws.on('open', () => {
        ws.send(JSON.stringify({ type: 'hello', token: 'WRONG-' + TOKEN, ua: 'smoke-bad', ver: 'test' }));
        ws.send(JSON.stringify({ type: 'telemetry', _smoke: 'marker-B-should-not-appear' }));
      });
      ws.on('message', (data, isBinary) => { if (!isBinary && data.toString('utf8').includes('auth_ok')) sawAuthOk = true; });
      ws.on('close', (code) => { closedCode = code; clearTimeout(timer); resolve({ closedCode, sawAuthOk, timedOut: false }); });
      ws.on('error', () => { /* close follows */ });
    });
    ok(badResult.closedCode === 4001, `bad-token connection CLOSED by relay (code ${badResult.closedCode})`);
    ok(!badResult.sawAuthOk, 'bad-token connection received NO auth_ok (never authed)');
    await sleep(300);
    let telemAfter = existsSync(TELEMETRY_FILE) ? readFileSync(TELEMETRY_FILE, 'utf8') : '';
    ok(!telemAfter.includes('marker-B-should-not-appear'), 'bad-token telemetry was NOT written');
    ok((existsSync(TELEMETRY_FILE) ? statSync(TELEMETRY_FILE).size : 0) === telemBytesBefore,
      'telemetry file did not grow after the bad-token attempt');

    // ── A3. AUTHED-NEVER-EVICTED — a stranger flood can't displace a real session ──────────────
    const authedWs = [];
    for (let i = 0; i < 2; i++) {
      await new Promise((resolve, reject) => {
        const ws = new WebSocket(URL);
        const timer = setTimeout(() => reject(new Error('authed setup timeout')), 4000);
        ws.on('open', () => ws.send(JSON.stringify({ type: 'hello', token: TOKEN, ua: 'authed-' + i, ver: 'test' })));
        ws.on('message', (data, isBinary) => {
          if (!isBinary && data.toString('utf8').includes('auth_ok')) { clearTimeout(timer); authedWs.push(ws); resolve(); }
        });
        ws.on('error', (e) => { clearTimeout(timer); reject(e); });
      });
    }
    const floodWs = [];
    for (let i = 0; i < 6; i++) { const w = new WebSocket(URL); floodWs.push(w); w.on('error', () => {}); }
    await sleep(600);
    const authedStillOpen = authedWs.filter((w) => w.readyState === WebSocket.OPEN).length;
    ok(authedStillOpen === 2, `both authed sessions stayed OPEN through a pending flood (${authedStillOpen}/2)`);
    const beforeStream = existsSync(TELEMETRY_FILE) ? statSync(TELEMETRY_FILE).size : 0;
    authedWs[0].send(JSON.stringify({ type: 'telemetry', _smoke: 'marker-C-post-flood' }));
    await sleep(300);
    const telemC = existsSync(TELEMETRY_FILE) ? readFileSync(TELEMETRY_FILE, 'utf8') : '';
    ok(telemC.includes('marker-C-post-flood'), 'authed session still streamed after the pending flood');
    ok((existsSync(TELEMETRY_FILE) ? statSync(TELEMETRY_FILE).size : 0) > beforeStream, 'telemetry grew from the authed post-flood write');
    for (const w of authedWs) try { w.close(); } catch { /* ignore */ }
    for (const w of floodWs) try { w.close(); } catch { /* ignore */ }
    await sleep(200);

    // ══ PART B — P1 CONTROL CORE ══════════════════════════════════════════════════════════════

    // ── B(b) THE KEY SECURITY ASSERTION: no grant => NEVER forwarded ───────────────────────────
    console.log('\n── PART B(b): no consent => NEVER forwarded (key security assertion) ──');
    {
      const game = await makeFakeGame('nogrant');
      await sleep(200);
      dropOutbox(mkCmd('sec-noconsent', [{ id: 1, op: 'wait', seconds: 1 }]));
      // Give the poller ample time; the game intentionally NEVER grants.
      await sleep(1000);
      ok(!gotSeq(game, 'sec-noconsent'), 'B(b) ungranted game NEVER received the cmd_seq');
      ok(!existsSync(join(SENT, 'sec-noconsent.json')), 'B(b) command was NOT moved to sent/ (not forwarded)');
      ok(!existsSync(join(CTRL_RESULTS, 'sec-noconsent')), 'B(b) no results dir created (never forwarded)');
      ok(!existsSync(join(REJECTED, 'sec-noconsent.json')), 'B(b) command was NOT rejected (it waits for consent)');
      ok(existsSync(join(OUTBOX, 'sec-noconsent.json')), 'B(b) command still HELD in outbox awaiting a grant');
      ok(game.offers.includes('sec-noconsent'), 'B(b) relay offered control to the authed game (consent prompt)');
      game.close();
      await sleep(300);
    }

    // ── B(a) valid seq forwarded ONLY after a grant; results land on disk ──────────────────────
    console.log('\n── PART B(a): forwarded ONLY after a grant, results routed ──');
    {
      const game = await makeFakeGame('grant');
      await sleep(200);
      dropOutbox(mkCmd('walkabout-a', [
        { id: 1, op: 'wait', seconds: 0.2 },
        { id: 2, op: 'screenshot', label: 'ridge-approach' },
        { id: 3, op: 'stop' },
      ]));
      await sleep(500);
      ok(!gotSeq(game, 'walkabout-a'), 'B(a) BEFORE grant: cmd_seq not yet forwarded');
      game.grant();
      await waitFor(() => existsSync(join(CTRL_RESULTS, 'walkabout-a', 'done.json')), 4000);
      ok(gotSeq(game, 'walkabout-a'), 'B(a) AFTER grant: game received the cmd_seq');
      ok(existsSync(join(SENT, 'walkabout-a.json')), 'B(a) forwarded file moved to sent/');
      ok(existsSync(join(CTRL_RESULTS, 'walkabout-a', 'ack.json')), 'B(a) ack.json written');
      ok(existsSync(join(CTRL_RESULTS, 'walkabout-a', 'events.jsonl')), 'B(a) events.jsonl written');
      ok(existsSync(join(CTRL_RESULTS, 'walkabout-a', 'done.json')), 'B(a) done.json written');
      const shots = existsSync(join(CTRL_RESULTS, 'walkabout-a'))
        ? readdirSync(join(CTRL_RESULTS, 'walkabout-a')).filter((f) => f.startsWith('shot-') && f.endsWith('.jpg')) : [];
      ok(shots.length === 1 && shots[0] === 'shot-2-ridge-approach.jpg', `B(a) correlated shot written (${shots.join(',') || 'none'})`);
      if (shots.length) {
        const jpg = readFileSync(join(CTRL_RESULTS, 'walkabout-a', shots[0]));
        ok(jpg[0] === 0xff && jpg[1] === 0xd8, 'B(a) shot has JPEG magic');
      } else { ok(false, 'B(a) shot has JPEG magic'); }
      const done = JSON.parse(readFileSync(join(CTRL_RESULTS, 'walkabout-a', 'done.json'), 'utf8'));
      ok(done.status === 'ok' && done.completed === 3, `B(a) done.json status ok, completed=${done.completed}`);
      const evTypes = readFileSync(join(CTRL_RESULTS, 'walkabout-a', 'events.jsonl'), 'utf8').trim().split('\n')
        .map((l) => JSON.parse(l).type);
      const nStart = evTypes.filter((t) => t === 'step_start').length;
      const nDone = evTypes.filter((t) => t === 'step_done').length;
      ok(nStart === 3 && nDone === 3 && evTypes.includes('seq_done'),
        `B(a) events.jsonl has 3 step_start + 3 step_done + seq_done (${evTypes.join(',')})`);
      game.close();
      await sleep(300);
    }

    // ── B(c) override ENDS the grant; next command not forwarded until a fresh grant ───────────
    console.log('\n── PART B(c): override ends grant; re-consent required ──');
    {
      const game = await makeFakeGame('override');
      await sleep(200);
      dropOutbox(mkCmd('ovr-first', [{ id: 1, op: 'wait', seconds: 0.1 }, { id: 2, op: 'stop' }]));
      await waitFor(() => game.offers.includes('ovr-first'), 4000);   // relay offers control (mints the nonce)
      game.grant();                                                    // echo the minted nonce (F1)
      await waitFor(() => existsSync(join(CTRL_RESULTS, 'ovr-first', 'done.json')), 4000);
      ok(gotSeq(game, 'ovr-first'), 'B(c) first command forwarded under the grant');
      // Human touches a key: override ends the grant.
      game.override();
      await sleep(300);
      dropOutbox(mkCmd('ovr-second', [{ id: 1, op: 'wait', seconds: 0.1 }, { id: 2, op: 'stop' }]));
      await sleep(1000);
      ok(!gotSeq(game, 'ovr-second'), 'B(c) after override: second command NOT forwarded (grant ended)');
      ok(!existsSync(join(SENT, 'ovr-second.json')), 'B(c) second command not in sent/ (held, awaiting re-consent)');
      // Fresh consent: the relay re-offered (fresh nonce); the held command now flushes.
      await waitFor(() => game.offers.includes('ovr-second'), 4000);
      game.grant();
      await waitFor(() => gotSeq(game, 'ovr-second'), 4000);
      ok(gotSeq(game, 'ovr-second'), 'B(c) after RE-grant: held command forwarded');
      ok(existsSync(join(SENT, 'ovr-second.json')), 'B(c) re-granted command moved to sent/');
      game.close();
      await sleep(300);
    }

    // ── B(d) preempt aborts a running seq; non-preempt during a run is `busy` ──────────────────
    console.log('\n── PART B(d): busy + preempt ──');
    {
      const game = await makeFakeGame('preempt');
      game.autoRun = true;
      game.holdSeq = 'run-long';        // ack but never finish run-long => it stays in flight
      await sleep(200);
      dropOutbox(mkCmd('run-long', [{ id: 1, op: 'wait', seconds: 30 }]));
      await waitFor(() => game.offers.includes('run-long'), 4000);   // relay offers control (mints the nonce)
      game.grant();                                                  // echo the minted nonce (F1)
      await waitFor(() => gotSeq(game, 'run-long'), 4000);
      ok(gotSeq(game, 'run-long'), 'B(d) long-running seq forwarded and in flight');
      // A non-preempt seq while one is in flight => busy reject, never forwarded.
      dropOutbox(mkCmd('run-busy', [{ id: 1, op: 'stop' }]));
      await waitFor(() => existsSync(join(REJECTED, 'run-busy.json')), 4000);
      ok(!gotSeq(game, 'run-busy'), 'B(d) non-preempt seq during a run was NOT forwarded');
      ok(reasonFileFor('run-busy').includes('busy'), 'B(d) rejected with reason=busy');
      // A preempt seq aborts run-long and is forwarded.
      dropOutbox(mkCmd('run-preempt', [{ id: 1, op: 'stop' }], { preempt: true }));
      await waitFor(() => gotSeq(game, 'run-preempt'), 4000);
      ok(gotSeq(game, 'run-preempt'), 'B(d) preempt seq was forwarded (aborts+replaces the running one)');
      const rl = existsSync(join(CTRL_RESULTS, 'run-long', 'done.json'))
        ? JSON.parse(readFileSync(join(CTRL_RESULTS, 'run-long', 'done.json'), 'utf8')) : null;
      ok(rl && rl.status === 'aborted', `B(d) preempted seq got a synthesized aborted done.json (${rl && rl.status})`);
      game.close();
      await sleep(300);
    }

    // ── B(e) invalid/oversize/over-cap/stale/duplicate rejected; relay stays alive ─────────────
    console.log('\n── PART B(e): validation rejects, no crash ──');
    {
      const game = await makeFakeGame('reject');
      await sleep(200);
      // Establish a grant the F1 way: a valid priming command triggers an offer (+ minted nonce), then grant.
      dropOutbox(mkCmd('rej-prime', [{ id: 1, op: 'stop' }]));
      await waitFor(() => game.offers.includes('rej-prime'), 4000);
      game.grant();
      await waitFor(() => existsSync(join(CTRL_RESULTS, 'rej-prime', 'done.json')), 4000);
      ok(gotSeq(game, 'rej-prime'), 'B(e) priming command established the grant');

      // Even WITH a grant, invalid commands must be rejected (never forwarded).
      dropRawOutbox('rej-garbage', Buffer.from('this is not json at all {{{'));
      dropOutbox({ type: 'cmd_seq', seq: 'rej-badop', issued: Date.now() / 1000, steps: [{ id: 1, op: 'launch_missiles' }] });
      dropOutbox(mkCmd('rej-toomany', Array.from({ length: 65 }, (_, i) => ({ id: i, op: 'stop' }))));
      dropOutbox(mkCmd('rej-farmove', [{ id: 1, op: 'move', blocks: 500 }]));
      dropOutbox(mkCmd('rej-oversize', [{ id: 1, op: 'screenshot', label: 'x' }], { pad: 'P'.repeat(17 * 1024) }));
      dropOutbox({ type: 'cmd_seq', seq: 'rej-stale', issued: Date.now() / 1000 - 999, steps: [{ id: 1, op: 'stop' }] });

      await sleep(1000);
      for (const [seq, reason] of [
        ['rej-garbage', 'bad_json'], ['rej-badop', 'caps'], ['rej-toomany', 'caps'],
        ['rej-farmove', 'caps'], ['rej-oversize', 'caps'], ['rej-stale', 'stale'],
      ]) {
        ok(existsSync(join(REJECTED, `${seq}.json`)), `B(e) ${seq} moved to rejected/`);
        ok(reasonFileFor(seq).includes(reason), `B(e) ${seq} reason contains '${reason}'`);
        ok(!gotSeq(game, seq), `B(e) ${seq} was NEVER forwarded`);
      }

      // Duplicate: forward one valid seq, then re-drop the same seq id => duplicate reject.
      dropOutbox(mkCmd('dup-seq', [{ id: 1, op: 'stop' }]));
      await waitFor(() => existsSync(join(CTRL_RESULTS, 'dup-seq', 'done.json')), 4000);
      ok(gotSeq(game, 'dup-seq'), 'B(e) first dup-seq forwarded');
      dropOutbox(mkCmd('dup-seq', [{ id: 1, op: 'stop' }]));
      await waitFor(() => existsSync(join(REJECTED, 'dup-seq.json')), 4000);
      ok(reasonFileFor('dup-seq').includes('duplicate'), 'B(e) re-used seq id rejected as duplicate');

      // Relay is still alive: a fresh valid command forwards end-to-end.
      dropOutbox(mkCmd('alive-check', [{ id: 1, op: 'wait', seconds: 0.1 }, { id: 2, op: 'stop' }]));
      const alive = await waitFor(() => existsSync(join(CTRL_RESULTS, 'alive-check', 'done.json')), 4000);
      ok(alive, 'B(e) relay survived the bad inputs — a subsequent valid seq still forwards');
      game.close();
      await sleep(300);
    }

    // ── B(g) F1: a grant must echo the relay-MINTED nonce (no nonce / wrong nonce ⇒ refused) ───
    console.log('\n── PART B(g): F1 — a grant requires the relay-minted nonce ──');
    {
      const game = await makeFakeGame('nononce');
      await sleep(200);
      // Claim control BEFORE any offer exists → the relay minted no nonce for this socket → refused.
      game.grantRaw();
      await sleep(300);
      dropOutbox(mkCmd('f1-nononce', [{ id: 1, op: 'wait', seconds: 0.1 }, { id: 2, op: 'stop' }]));
      await sleep(900);
      ok(!gotSeq(game, 'f1-nononce'), 'B(g) grant with NO minted nonce refused → command NOT forwarded');
      ok(!existsSync(join(SENT, 'f1-nononce.json')), 'B(g) command not moved to sent/ (never forwarded)');
      ok(existsSync(join(OUTBOX, 'f1-nononce.json')), 'B(g) command HELD, still awaiting a valid grant');
      ok(game.offers.includes('f1-nononce'), 'B(g) relay offered control (minted a fresh nonce) for the held command');
      // A wrong/guessed nonce is likewise refused.
      game.grantWithNonce('deadbeefdeadbeefdeadbeefdeadbeef');
      await sleep(500);
      ok(!gotSeq(game, 'f1-nononce'), 'B(g) grant with a WRONG nonce refused → still not forwarded');
      // Echoing the REAL minted nonce now grants and flushes the held command.
      game.grant();
      await waitFor(() => gotSeq(game, 'f1-nononce'), 4000);
      ok(gotSeq(game, 'f1-nononce'), 'B(g) grant echoing the CORRECT minted nonce forwarded the held command');
      ok(existsSync(join(SENT, 'f1-nononce.json')), 'B(g) valid-nonce grant moved the file to sent/');
      game.close();
      await sleep(300);
    }

    // ── B(h) F1: a 2nd authed socket cannot steal a standing grant nor forge results ────────────
    console.log('\n── PART B(h): F1 — a 2nd socket cannot steal control or poison results ──');
    {
      const legit = await makeFakeGame('legit');
      const attacker = await makeFakeGame('attacker');
      attacker.autoRun = false;                 // attacker forges by hand (never auto-runs a forwarded seq)
      legit.holdSeq = 'f1-run';                  // legit acks but never finishes → seq stays in flight
      await sleep(200);
      dropOutbox(mkCmd('f1-run', [{ id: 1, op: 'wait', seconds: 30 }]));
      // Both authed sockets receive an offer (each with its OWN nonce). Legit grants first.
      await waitFor(() => legit.offers.includes('f1-run') && attacker.offers.includes('f1-run'), 4000);
      legit.grant();
      await waitFor(() => gotSeq(legit, 'f1-run'), 4000);
      ok(gotSeq(legit, 'f1-run'), 'B(h) legit socket holds the grant + the in-flight seq');
      ok(!gotSeq(attacker, 'f1-run'), 'B(h) attacker never received the forwarded seq');
      // Attacker tries to STEAL control by granting with its OWN valid minted nonce → no-supersede refuses it.
      attacker.grant();
      await sleep(500);
      // Attacker forges downlink RESULTS for legit's in-flight seq → dropped by per-socket ownership.
      attacker.sendRaw({ type: 'step_done', seq: 'f1-run', id: 99, op: 'wait', status: 'ok', t: Date.now() / 1000 });
      attacker.sendRaw({ type: 'seq_done', seq: 'f1-run', status: 'ok', completed: 1, t: Date.now() / 1000 });
      await sleep(500);
      ok(!existsSync(join(CTRL_RESULTS, 'f1-run', 'done.json')), 'B(h) forged seq_done from a NON-OWNER dropped (results not poisoned)');
      const evForged = existsSync(join(CTRL_RESULTS, 'f1-run', 'events.jsonl'))
        ? readFileSync(join(CTRL_RESULTS, 'f1-run', 'events.jsonl'), 'utf8') : '';
      ok(!evForged.includes('"id":99'), 'B(h) forged step_done from a NON-OWNER did not land in events.jsonl');
      // The real owner can still finalize its own sequence — control was never stolen.
      legit.holdSeq = null;
      legit.sendRaw({ type: 'step_done', seq: 'f1-run', id: 1, op: 'wait', status: 'ok', t: Date.now() / 1000 });
      legit.sendRaw({ type: 'seq_done', seq: 'f1-run', status: 'ok', completed: 1, t: Date.now() / 1000 });
      await waitFor(() => existsSync(join(CTRL_RESULTS, 'f1-run', 'done.json')), 4000);
      const doneReal = existsSync(join(CTRL_RESULTS, 'f1-run', 'done.json'))
        ? JSON.parse(readFileSync(join(CTRL_RESULTS, 'f1-run', 'done.json'), 'utf8')) : null;
      ok(doneReal && doneReal.status === 'ok', 'B(h) the OWNER socket still finalized its own seq (grant intact)');
      legit.close(); attacker.close();
      await sleep(300);
    }

    // ── B(i) F2: the relay DELIVERS control_revoke on a ping timeout (client no longer lies) ────
    console.log('\n── PART B(i): F2 — relay delivers control_revoke on a ping timeout ──');
    {
      const game = await makeFakeGame('pingrevoke');
      game.holdSeq = 'f2-cmd';                  // keep the seq in flight so the grant + heartbeat stay live
      await sleep(200);
      dropOutbox(mkCmd('f2-cmd', [{ id: 1, op: 'wait', seconds: 30 }]));
      await waitFor(() => game.offers.includes('f2-cmd'), 4000);
      game.grant();
      await waitFor(() => gotSeq(game, 'f2-cmd'), 4000);
      ok(gotSeq(game, 'f2-cmd'), 'B(i) command forwarded under the grant (relay heartbeat now running)');
      // Stop answering control_ping → after CTRL_MAX_MISSED_PINGS the relay revokes AND sends control_revoke.
      game.answerPings = false;
      const gotRevoke = await waitFor(() => game.revokes.length > 0, 8000);
      ok(gotRevoke, 'B(i) relay delivered a control_revoke frame to the client (F2 — was previously silent)');
      ok(game.revokes.includes('link_lost'), `B(i) control_revoke reason was link_lost (${game.revokes.join(',') || 'none'})`);
      game.close();
      await sleep(300);
    }

    // ── B(f) audit log recorded the control lifecycle ─────────────────────────────────────────
    console.log('\n── PART B: audit trail ──');
    {
      const auditTxt = existsSync(join(CONTROL, 'audit.log')) ? readFileSync(join(CONTROL, 'audit.log'), 'utf8') : '';
      ok(auditTxt.includes('grant'), 'audit.log recorded a grant');
      ok(auditTxt.includes('forward'), 'audit.log recorded a forward');
      ok(auditTxt.includes('reject'), 'audit.log recorded a reject');
      ok(auditTxt.includes('override'), 'audit.log recorded an override');
      ok(auditTxt.includes('grant_rejected'), 'audit.log recorded a grant_rejected (F1 nonce/no-supersede gate)');
      ok(auditTxt.includes('result_forged'), 'audit.log recorded a result_forged drop (F1 per-socket result tagging)');
    }

    // ── (f) Part-A telemetry still intact after all control traffic ───────────────────────────
    const telemFinal = existsSync(TELEMETRY_FILE) ? readFileSync(TELEMETRY_FILE, 'utf8') : '';
    ok(telemFinal.includes('marker-A') && telemFinal.includes('marker-C-post-flood'),
      'Phase-1 telemetry markers survived the full control run (observe path unchanged)');
  } finally {
    relay.kill('SIGTERM');
  }

  console.log(failures === 0 ? '\nSMOKE: ALL PASS' : `\nSMOKE: ${failures} FAILURE(S)`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => { console.error('smoke error:', e); process.exit(1); });
