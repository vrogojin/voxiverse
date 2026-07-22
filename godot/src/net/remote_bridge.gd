class_name RemoteBridge
extends Node
## REMOTE-PLAY BRIDGE — Phase 1 (OBSERVE-ONLY). A token-gated, dial-OUT WebSocket that streams
## TELEMETRY (the perf_hud.gd numbers + rich engine state) and periodic downscaled FRAMES of the
## GAME CANVAS to a relay on our host, so a remote agent can OBSERVE a real-GPU play session.
##
## SECURITY MODEL (this is a PUBLIC live site — these are load-bearing):
##   * DEAD IN NORMAL PLAY. This streaming node is created ONLY on activation — the `?remote=<token>`
##     URL param at boot, or the Ctrl+Shift+F9 hotkey + a token (RemoteBridgeActivator). Until then
##     there is no WebSocket, no frame capture, no per-frame cost, zero behavioural change. (The
##     RemoteBridgeActivator itself IS always present in main.gd, but it is an input-only key listener
##     with no `_process` and no network — it just decides when to spawn/despawn THIS node.) The
##     headless verify gate never runs main.gd, so it sees neither (6027/0 stays structural).
##   * TOKEN AUTH. The token comes from the URL query on web (`location.search`) or the
##     VOXIVERSE_REMOTE_TOKEN env var on native/headless (local testing only). It is sent to the
##     relay in the `hello`; the relay rejects+closes any connection whose hello token is
##     missing/mismatched. The token travels inside the wss (encrypted) hello frame — NOT in the WS
##     URL — so it never lands in nginx access logs.
##   * AUTH-ACK GATE. After the hello, the client sends NOTHING and captures NOTHING until the relay
##     returns an app-level {"type":"auth_ok"}. So an unauthenticated visitor (bad/absent token → the
##     relay closes 4001, never acks) never reads back or streams a single frame — the brief
##     pre-rejection capture window is closed. auth_ok is also the handshake Phase-2 controls ride.
##   * SEND-ONLY. Phase 1 has NO control surface: the bridge only SENDS (telemetry + frames). The only
##     inbound packet it acts on is that one auth_ok handshake; everything else is DRAINED and
##     DISCARDED — it never influences the game. (Controls are Phase 2, gated separately.)
##   * VIEWPORT-ONLY CAPTURE. Frames are get_viewport().get_texture().get_image() — the game canvas
##     ONLY, never the user's screen or other tabs.
##
## Reconnect with capped backoff on drop; clean teardown on _exit_tree. Robust to readback cost:
## a frame is SKIPPED (not queued) when the socket is backpressured or a capture is already inflight.
##
## The RemoteBridgeActivator (net/remote_bridge_activator.gd) owns runtime toggling (the Ctrl+Shift+F9
## chord + the on-canvas token prompt) and the always-visible LIVE badge; it listens to `link_state`
## below to keep that badge honest. This node stays a pure dumb pipe — activation policy lives there.

## Emitted when the WS link opens (true) or drops/closes (false). The activator drives the on-screen
## "REMOTE ACTIVE" badge from this, so the user can ALWAYS tell when the channel is live.
signal link_state(open: bool)

## P2 CONTROL lifecycle → the activator (owns all UI + localStorage). Emitted ONLY when CONTROL_ENABLED
## (below) is true — with the flag off these never fire, so the control UI is dead code and the badge
## stays exactly the Phase-1 "observing" surface (byte-identical).
signal control_offer_in(seq: String)                  # relay offered control → activator shows the consent modal
signal control_phase(phase: String, info: Dictionary) # badge driver: observing|granted|driving|suspended|override|revoked
## #113 (§9.3): the RELAY REFUSED our `granted` (bad/absent grant_proof, control disabled, or already
## held). The activator drops the badge to observing and, on a killed UNATTENDED re-arm, clears the
## stale stored key and re-opens the attended modal so the human can type the rotated control key.
signal control_denied_relay(reason: String, was_unattended: bool)

# ── Configuration ──────────────────────────────────────────────────────────────────────────────
const DEFAULT_URL := "wss://voxiverse.game-host.org/remote"

## Phase-1 badge status verb. Phase 2 (control) upgrades this surface to "observing + CONTROLLING"
## through the SAME toggle + badge — the activator reads PHASE_STATUS, so the upgrade is one const.
const PHASE_STATUS := "observing"

## ══ P2 REMOTE-CONTROL MASTER GATE ════════════════════════════════════════════════════════════════
## While false the game behaves EXACTLY as the Phase-1 observe-only bridge: the inbound drain never
## dispatches a control type (it stays drained-and-discarded), no RemoteControl executor is ever
## created, and the control_* signals never fire. DEFAULT-DENY control is dead code until P4 flips
## this true — AND ONLY after the §6 security review + /steelman + explicit user sign-off. Do NOT flip
## it here. Everything below is written so the OFF path is byte-identical to Phase 1.
const CONTROL_ENABLED := false

const SHOT_TAG := 0x02                       # commanded screenshot: [0x02][u16 hlen BE][hdr json][jpeg] (design §3.3)
const SHOT_JPG_QUALITY := 0.9               # commanded shots are FULL fidelity (resolved D4)…
const MAX_SHOT_BYTES := (2 << 20) - 512     # …capped just under the relay's 2 MiB maxPayload (header slack)
const SHOT_MAX_WAIT_MS := 9000              # backpressure retry budget for a commanded shot (< executor watchdog)
const CTRL_PING_TIMEOUT_MS := 16000         # no control_ping for ~3×5 s while granted ⇒ link-lost fail-safe (§5.4)
const UNATTENDED_RESUME_IDLE_MS := 5000     # §6.6: after an override in UNATTENDED mode, auto re-arm once idle this long
# Rover-side cap re-validation (mirror of relay.mjs; a granted rover NEVER trusts the relay blindly).
const MAX_STEPS := 64
const MAX_MOVE_BLOCKS := 128
const STALE_S := 120.0
const OP_WHITELIST := ["move", "turn", "look", "wait", "jump", "screenshot", "set_fly", "stop", "break", "place", "select_slot", "reload",
	# COSMOS SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md) — the dev/test space-nav verbs. Behind CONTROL_ENABLED like
	# every op; the executor that runs them exists only under a live grant, so this list is dead in normal play.
	"dev_nav", "nav", "thrust", "roll"]
const MAX_HOLD_S := 120.0                    # SPACE-FLY: hard cap on a single thrust/roll HELD-input step (watchdog outer bound)

const TELEMETRY_INTERVAL := 0.25    # s — one telemetry JSON per window (matches perf_hud WINDOW)
# COSMOS-PERF L2 (docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md §1.1/§4 L2) — capture hygiene. The synchronous
# get_texture().get_image() (WebGL2 glReadPixels = full GPU pipeline stall) + resize + JPEG on the engine thread cost
# ~35 ms and, at the old 500 ms cadence, landed a hitch 2×/second in EVERY remote session — self-inflicted jank that
# also polluted every worst-frame statistic used to judge feel. The interval is raised to 2000 ms (~0.5 fps) AND the
# scheduled capture is SKIPPED when the last telemetry window already hitched (worst > CAPTURE_SKIP_WORST_MS) so a
# readback never piles onto a frame that is already slow. The COMMANDED screenshot (§3.3, _commanded_shot_async) is a
# SEPARATE path — unaffected by both throttles — so an explicit agent screenshot request always captures.
const FRAME_INTERVAL_MS := 2000     # ms — ~0.5 fps ambient frame stream (was 500; L2 capture hygiene)
const CAPTURE_SKIP_WORST_MS := 45.0 # ms — skip a scheduled auto-capture if the last window's worst frame exceeded this
const FRAME_MAX_WIDTH := 960        # px — downscale cap for the JPEG (keeps bytes + readback modest)
const FRAME_JPG_QUALITY := 0.6
# COSMOS-PERF L2 (threaded encode): the get_image() readback (WebGL2 glReadPixels) MUST stay on the engine thread —
# gl_compatibility has no async GPU→CPU path from GDScript — but the resize + JPEG encode that follow it are pure CPU.
# When true, those are handed to a WorkerThreadPool task on an OWNED image copy, so only the (unavoidable) readback
# stall remains on the engine thread; the finished bytes are queued back and sent from the main thread on a later frame
# (WebSocketPeer is NOT thread-safe). Default true (dev tooling; strictly cheaper). false → the synchronous path.
const CAPTURE_THREADED_ENCODE := true
const FRAME_TAG := 0x01             # 1-byte type tag prefixing a binary JPEG frame (distinguish from JSON text)
## The WebSocketPeer's Godot-side outbound ring buffer. MUST be set (before connect) well above a single
## frame (~45 KB) — the DEFAULT is only ~64 KB, so one JPEG + a telemetry JSON overflowed it and every
## subsequent send errored `ERR_OUT_OF_MEMORY (emws_peer.cpp:_send)`, corrupting the stream and the very
## measurement we are here to take. 1 MiB gives ~20 frames of drain headroom; it is a hard bound (frames
## are SHED below it, never queued past it), so it does not threaten NEVER-OOM.
const OUTBOUND_BUFFER_BYTES := 1 << 20        # 1 MiB Godot-side outbound buffer (was default ~64 KB)
## Shed a frame when this many bytes are still queued. MUST stay comfortably BELOW OUTBOUND_BUFFER_BYTES
## so that the in-flight frame + a telemetry JSON still fit after the check passes — otherwise the guard
## is dead (the old 256 KB threshold sat ABOVE the real ~64 KB buffer, so it never tripped).
const OUTBOUND_BACKPRESSURE_BYTES := 393216   # skip a frame if > 384 KB is still queued (< 1 MiB buffer)

const HITCH_MS := 33.0              # perf_hud.gd parity: a frame slower than ~30 fps counts as a hitch

const RECONNECT_BACKOFF_MIN := 1.0  # s
const RECONNECT_BACKOFF_MAX := 30.0 # s

# ── Injected by main.gd (both optional; every read is guarded for absence) ──────────────────────
var world: Node = null
var player: Node3D = null

# ── State ──────────────────────────────────────────────────────────────────────────────────────
var _token := ""
var _url := DEFAULT_URL
var _ws: WebSocketPeer = null
var _was_open := false
var _hello_sent := false
var _authed := false                # relay returned auth_ok → cleared to stream telemetry + frames
var _flags_emitted := false         # CROSSING-FASTGEN obs-2 fix (4): the exported FP_* flag set is stamped ONCE (first telemetry)
var _reconnect_at := 0.0            # msec (Time.get_ticks_msec) at which to attempt reconnect; 0 = connect now
var _backoff := RECONNECT_BACKOFF_MIN

var _voxel_engine: Object = null    # godot_voxel VoxelEngine singleton (perf_hud.gd parity)

# Frame-timing window (accumulated in _process, flushed with each telemetry send).
# NOTE: we measure the frame period from Time.get_ticks_usec() deltas, NOT the _process(delta)
# param — Godot CLAMPS that param (~50 ms / 1/20 s spiral-of-death guard), which censored worst_ms
# at exactly 50 in the border-walk telemetry (proc_ms via TIME_PROCESS read 282 ms the same frame).
# The usec delta is the true wall frame time, so crossing spikes above 50 ms become measurable.
var _win_acc := 0.0
var _win_frames := 0
var _win_worst := 0.0               # slowest frame (s) in the current window (true wall delta)
var _win_had_capture := false       # T2f: this window initiated an ambient frame capture (~35 ms readback) — stamp cap=1 so analysis can exclude it

# MAIN-THREAD BREAKDOWN (streaming-hitch instrumentation, 2026-07-17) — per-WINDOW MAXIMA of
# godot_voxel's own VoxelTerrain::_process timing breakdown (usec; see WorldManager.terrain_main_thread_stats).
# WHY MAXIMA, POLLED EVERY FRAME: a telemetry window is 250 ms ≈ 15 frames and the hitch is BURSTY —
# sampling the stats once at send time would almost always miss the one bad frame and read ~0, which is
# exactly the false-negative that would "prove" the wrong conclusion. We poll every frame and keep the
# worst, so vt_total_max is directly comparable against worst_ms for the SAME window: if
# vt_total_max << worst_ms, the streaming hitch is NOT inside VoxelTerrain::_process at all.
var _win_vt_detect := 0             # usec, max: time_detect_required_blocks
var _win_vt_req_load := 0           # usec, max: time_request_blocks_to_load
var _win_vt_load_resp := 0          # usec, max: time_process_load_responses (the APPLY path)
var _win_vt_req_upd := 0            # usec, max: time_request_blocks_to_update
var _win_vt_total := 0              # usec, max of the per-frame SUM of the four (time in _process)
var _win_vt_dropped_loads := 0      # max seen (counters are cumulative-ish per frame in godot_voxel)
var _win_vt_dropped_meshs := 0
var _win_vt_updated := 0            # max updated_blocks in one frame (apply burst size)
var _win_vt_seen := false           # any sample at all this window (module path present)
# STREAM-SCHED T1: last window's cumulative per-class generator counters, so telemetry can report the WINDOW
# delta (blocks + total ms per class) instead of an ever-growing total. See _send_telemetry for the epoch-reset
# and racy-counter caveats.
var _gen_prev_ct := [0, 0, 0, 0]
var _gen_prev_us := [0, 0, 0, 0]
var _hitches := 0                   # cumulative frames slower than HITCH_MS since start
var _last_frame_usec := -1          # previous _process wall time (usec); -1 = first frame

# A1-REFINE (#114): the crossing's transform-WRITE is ~0.02 ms, but Godot flushes the
# NOTIFICATION_TRANSFORM_CHANGED re-place AFTER _physics_process returns — the real ~290-816 ms
# spike lands in the FOLLOWING frame(s), not in the write bracket. So for each crossing we track the
# WORST frame over the next ~1.2 s and emit a {"ev":"crossing_after"} record — the clean deferred-cost
# KPI (before/after the fixed-frame keystone). Only fills on real crossings (faceted); empty otherwise.
var _post_cross: Array = []         # open windows: [{from,to,end_usec,worst_ms,frames}]
const POST_CROSS_WINDOW_MS := 1200  # attribute the worst frame for this long after a crossing
const POST_CROSS_MAX := 8           # NEVER-OOM: hard cap on concurrent windows

var _frame_acc_ms := 0.0
var _capturing := false             # a frame readback+send is inflight (skip overlapping captures)
# COSMOS-PERF L2 threaded encode: a single-flight worker task carrying the resize+JPEG off the engine thread. Only one
# capture is ever in flight (guarded by _capturing), so these three are never touched by two threads at once: the worker
# reads/mutates _cap_img and writes _cap_jpg; the main thread reads _cap_jpg ONLY after WorkerThreadPool reports the task
# complete (a happens-before), then sends it. -1 = no task pending.
var _cap_task_id := -1
var _cap_img: Image = null
var _cap_jpg: PackedByteArray = PackedByteArray()
var _link_open := false             # last emitted link_state (so we emit only on transitions)
# COSMOS-PERF L2: ambient auto-capture controls. `_auto_frames_enabled` is the re-baseline kill switch — set false by
# `?frames=0` / `?capture=0` (web) or VOXIVERSE_REMOTE_FRAMES=0 (native), and toggleable at runtime via set_auto_frames()
# so the agent/relay can request frames-off for a clean measurement. `_last_window_worst_ms` is the just-closed
# telemetry window's worst frame — the threshold gate reads it so a readback never lands on an already-hitching frame.
var _auto_frames_enabled := true
var _last_window_worst_ms := 0.0

# ── P2 control state (all inert while CONTROL_ENABLED is false — never touched on the Phase-1 path) ──
var _control_state := "none"        # none | granted
var _grant_id := ""                 # game-generated random id echoed on cmd_ack (binds results to this consent)
var _grant_nonce := ""              # F1: the relay-MINTED nonce from control_offer, echoed back on control_state:granted
## #113 (§9.1): the CONTROL SECRET, held RAM-ONLY for the bridge's lifetime. Never stored for an attended
## grant; under an explicit UNATTENDED opt-in the activator ALSO keeps a copy in localStorage (§9.4) and
## re-supplies it here on a boot re-arm. Cleared only on revoke/deny/_exit_tree (kept across override/
## suspend/link-loss so a session re-consent or an unattended auto-resume re-proves without a retype).
var _control_secret := ""
var _rearm_control_secret := ""     # boot re-arm (§9.4): the stored control secret handed in with the uid
var _unattended := false            # this grant is the persistent §6.6 mode (survives override via auto-resume)
var _exec: RemoteControl = null     # the step executor — created ON GRANT, freed on revoke/override/link-loss
var _last_ping_ms := 0              # Time.get_ticks_msec of the last control_ping (0 = none yet)
var _suspend_resume_at := 0         # msec; >0 = an UNATTENDED override is waiting out the idle window to re-arm
var _rearm_unattended_id := ""      # set by the activator at boot from localStorage → auto-grant on the next offer


## Emit link_state only when the live/down status actually flips (drives the badge).
func _set_link(open: bool) -> void:
	if open != _link_open:
		_link_open = open
		link_state.emit(open)


## Detect dial mode. Returns {} when NOT active — the normal path, in which main.gd creates NO
## bridge (byte-identical). Otherwise {"token": String, "url": String}.
## Web: the ONLY production trigger is the URL query `?remote=<token>` (read via JavaScriptBridge).
## Native/headless: the VOXIVERSE_REMOTE_TOKEN env var (local testing). URL overridable via
## VOXIVERSE_REMOTE_URL in both cases.
static func dial_config() -> Dictionary:
	var token := ""
	var frames := true                       # L2: ambient frame stream on unless explicitly disabled (re-baseline knob)
	if OS.has_feature("web"):
		# location.search is inherent to the page; a single boot-time eval decides whether to dial.
		# No param → empty token → {} → dead. This is the whole activation gate on the public site.
		var qs := ""
		var raw = JavaScriptBridge.eval("window.location.search", true)
		if raw != null:
			qs = str(raw)
		token = _parse_query_token(qs)
		frames = _parse_frames_flag(qs)
	else:
		token = OS.get_environment("VOXIVERSE_REMOTE_TOKEN")
		var fenv := OS.get_environment("VOXIVERSE_REMOTE_FRAMES").strip_edges()
		frames = not (fenv == "0" or fenv.to_lower() == "false" or fenv.to_lower() == "off")
	token = token.strip_edges()
	if token == "":
		return {}
	return {"token": token, "url": resolve_url(), "frames": frames}


## The relay URL is FIXED to our host — resolved from VOXIVERSE_REMOTE_URL (native/dev only) else the
## hard-coded default. It is NEVER derived from user input: the on-canvas token prompt collects ONLY a
## token, never a URL, so a visitor can't be tricked into streaming to an attacker's relay. On the web
## the env var is unset, so this is always DEFAULT_URL (same-origin wss).
static func resolve_url() -> String:
	var url := OS.get_environment("VOXIVERSE_REMOTE_URL").strip_edges()
	return url if url != "" else DEFAULT_URL


## The URL-param / env token if dial mode is pre-armed, else "" (the hotkey path then prompts for one).
static func preset_token() -> String:
	var cfg := dial_config()
	return str(cfg.get("token", ""))


## Extract the `remote` value from a raw `?a=b&remote=TOK&c=d` query string (leading `?` optional).
static func _parse_query_token(query: String) -> String:
	var q := query
	if q.begins_with("?"):
		q = q.substr(1)
	for pair in q.split("&", false):
		var eq := pair.find("=")
		if eq < 0:
			continue
		if pair.substr(0, eq) == "remote":
			return pair.substr(eq + 1).uri_decode()
	return ""


## L2: the ambient-frame gate from the query string. Returns false iff `frames`/`capture` is explicitly disabled
## (`=0`/`false`/`off`) — the re-baseline knob (`?remote=TOK&frames=0`). Absent → true (frames on, unchanged default).
static func _parse_frames_flag(query: String) -> bool:
	var q := query
	if q.begins_with("?"):
		q = q.substr(1)
	for pair in q.split("&", false):
		var eq := pair.find("=")
		if eq < 0:
			continue
		var key := pair.substr(0, eq)
		if key == "frames" or key == "capture":
			var v := pair.substr(eq + 1).uri_decode().strip_edges().to_lower()
			return not (v == "0" or v == "false" or v == "off" or v == "no")
	return true


## Called by main.gd BEFORE add_child, with the dial_config() dictionary.
func configure(cfg: Dictionary) -> void:
	_token = str(cfg.get("token", ""))
	_url = str(cfg.get("url", DEFAULT_URL))
	_auto_frames_enabled = bool(cfg.get("frames", true))   # L2: honor ?frames=0 / VOXIVERSE_REMOTE_FRAMES=0


## L2 runtime kill switch for the AMBIENT auto-capture (the commanded screenshot path is never affected). Lets the
## agent/relay turn periodic frames off for a clean re-baseline measurement without a page reload.
func set_auto_frames(on: bool) -> void:
	_auto_frames_enabled = on


func _ready() -> void:
	if _token == "":
		# Defensive: never dial without a token. (main.gd only creates us when one exists.)
		set_process(false)
		return
	if Engine.has_singleton("VoxelEngine"):
		_voxel_engine = Engine.get_singleton("VoxelEngine")
	_ws = WebSocketPeer.new()
	_open_socket()
	print("[REMOTE] bridge active → %s (observe-only)" % _url)


func _open_socket() -> void:
	_was_open = false
	_hello_sent = false
	_authed = false
	# Enlarge the outbound ring buffer BEFORE connecting — the default (~64 KB) is smaller than one
	# JPEG frame, so sends overflowed with ERR_OUT_OF_MEMORY. Set each open (a fresh connect can reset
	# peer buffers). Frames are still shed at OUTBOUND_BACKPRESSURE_BYTES, so this is a bounded ceiling.
	_ws.outbound_buffer_size = OUTBOUND_BUFFER_BYTES
	var err := _ws.connect_to_url(_url)
	if err != OK:
		# Connect failed to even start — schedule a backed-off retry.
		push_warning("[REMOTE] connect_to_url failed (%d); backing off %.0fs" % [err, _backoff])
		_schedule_reconnect()


func _schedule_reconnect() -> void:
	_reconnect_at = float(Time.get_ticks_msec()) + _backoff * 1000.0
	_backoff = minf(_backoff * 2.0, RECONNECT_BACKOFF_MAX)


func _process(delta: float) -> void:
	if _ws == null:
		return

	# ── Frame-timing accumulation — use the TRUE wall delta (usec), not the engine-clamped `delta` param. ──
	var now_usec := Time.get_ticks_usec()
	var real_delta := delta                                   # first frame: fall back to the engine param
	if _last_frame_usec >= 0:
		real_delta = float(now_usec - _last_frame_usec) / 1_000_000.0
	_last_frame_usec = now_usec
	_win_acc += real_delta
	_win_frames += 1
	if real_delta > _win_worst:
		_win_worst = real_delta
	if real_delta * 1000.0 > HITCH_MS:
		_hitches += 1
	_poll_voxel_main_thread_stats()
	# A1-REFINE (#114): fold this frame's true delta into any open post-crossing attribution window.
	if not _post_cross.is_empty():
		_update_post_cross(now_usec, real_delta)

	# L2 threaded encode: drain a finished worker EVERY frame (before the state machine's early returns) so a pending
	# capture never gets stuck across a disconnect — _send_frame_jpg guards the send on the socket being open.
	_poll_capture_encode()

	# ── Socket state machine ──────────────────────────────────────────────────────────────────
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_set_link(false)                     # link is down → badge reverts to "dialing…"
		if CONTROL_ENABLED and _control_state == "granted":
			_drop_grant_link_lost()          # §5.4 fail-safe: a lost socket halts the rover + ends the grant
		# Reconnect on the backoff schedule.
		if _reconnect_at == 0.0:
			_schedule_reconnect()
		if float(Time.get_ticks_msec()) >= _reconnect_at:
			_reconnect_at = 0.0
			_open_socket()
		return

	_ws.poll()
	state = _ws.get_ready_state()
	if state != WebSocketPeer.STATE_OPEN:
		return

	if not _was_open:
		_was_open = true
		_send_hello()                        # socket open, but NOT yet live — wait for auth_ok
		# NB: the backoff ladder is reset only on auth_ok (below), NOT here. A bad/stale token OPENS the
		# socket but never gets auth_ok, so resetting on open would hot-loop reconnects at ~1/s forever;
		# leaving it to grow lets a rejected link back off to the 30s cap instead of hammering the relay.

	# Drain inbound. Pre-auth: the ONLY message acted on is the one auth_ok handshake. Post-auth on the
	# PHASE-1 path (CONTROL_ENABLED false) EVERYTHING is drained-and-discarded — send-only, unchanged.
	# Post-auth WITH control enabled, text frames go to a STRICT type-whitelist dispatch (§3.1);
	# anything not in the whitelist is still drained-and-discarded. Binary inbound is never expected.
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		var was_string := _ws.was_string_packet()
		if not _authed:
			if not was_string:
				continue                     # pre-auth binary is never expected — ignore
			_try_auth(pkt.get_string_from_utf8())
			continue
		if CONTROL_ENABLED and was_string:
			_dispatch_control(pkt.get_string_from_utf8())
		# else: authed Phase-1 send-only — inbound is drained and discarded (byte-identical Phase 1).

	# Nothing streams until the relay has acked our token.
	if not _authed:
		return

	# ── Control lifecycle tick (heartbeat timeout + UNATTENDED auto-resume). Gated so the OFF path is
	# byte-identical; _control_state stays "none" when the flag is off, so this is a no-op anyway. ──
	if CONTROL_ENABLED:
		_control_tick()

	# ── Crossing events (A1 instrumentation, #114) ──────────────────────────────────────────────
	# EVENT-driven: drained every frame (not folded into the 0.25 s telemetry window) so a facet-crossing
	# spike is reported as its own record the moment it happens. Cheap: a guarded has_method + an is_empty
	# array check when there is nothing to send (the normal case), which is byte-free vs the ambient stream.
	_drain_crossing_events()

	# ── Far-ring build/swap timing events (T2e) ──────────────────────────────────────────────────
	# Same event-drain discipline as the crossing events: drained every frame, published as distinct {"type":"farring"}
	# records the moment a rebuild swaps in. Normally empty (a rebuild is seconds apart), so this is a guarded no-op.
	_drain_farring_events()

	# ── Telemetry tick ────────────────────────────────────────────────────────────────────────
	if _win_acc >= TELEMETRY_INTERVAL:
		_send_telemetry()

	# ── Frame tick ────────────────────────────────────────────────────────────────────────────
	_frame_acc_ms += delta * 1000.0
	if _frame_acc_ms >= float(FRAME_INTERVAL_MS):
		_frame_acc_ms = 0.0
		_maybe_capture_frame()


func _send_hello() -> void:
	if _hello_sent:
		return
	_hello_sent = true
	var ua := OS.get_name()
	if OS.has_feature("web"):
		var nav = JavaScriptBridge.eval("navigator.userAgent", true)
		if nav != null:
			ua = str(nav)
	var hello := {
		"type": "hello",
		"token": _token,
		"ua": ua,
		"ver": _engine_version(),
	}
	_ws.send_text(JSON.stringify(hello))


func _engine_version() -> String:
	var v := Engine.get_version_info()
	var s := str(v.get("string", "godot"))
	if _voxel_engine != null:
		s += "+voxel"
	return s


## MAIN-THREAD BREAKDOWN (streaming-hitch instrumentation): sample godot_voxel's per-_process timing
## breakdown ONCE PER FRAME and keep the window maxima. Called from _process before any early return so
## the sample set covers every frame in the window (including the hitching one — the whole point).
## Read-only + fully guarded: no world / fallback path / missing method ⇒ silently no-ops.
func _poll_voxel_main_thread_stats() -> void:
	if not is_instance_valid(world) or not world.has_method("terrain_main_thread_stats"):
		return
	var d = world.call("terrain_main_thread_stats")
	if not (d is Dictionary) or (d as Dictionary).is_empty():
		return
	var s := d as Dictionary
	_win_vt_seen = true
	var detect := int(s.get("time_detect_required_blocks", 0))
	var req_load := int(s.get("time_request_blocks_to_load", 0))
	var load_resp := int(s.get("time_process_load_responses", 0))
	var req_upd := int(s.get("time_request_blocks_to_update", 0))
	var total := detect + req_load + load_resp + req_upd
	_win_vt_detect = maxi(_win_vt_detect, detect)
	_win_vt_req_load = maxi(_win_vt_req_load, req_load)
	_win_vt_load_resp = maxi(_win_vt_load_resp, load_resp)
	_win_vt_req_upd = maxi(_win_vt_req_upd, req_upd)
	_win_vt_total = maxi(_win_vt_total, total)
	_win_vt_dropped_loads = maxi(_win_vt_dropped_loads, int(s.get("dropped_block_loads", 0)))
	_win_vt_dropped_meshs = maxi(_win_vt_dropped_meshs, int(s.get("dropped_block_meshs", 0)))
	_win_vt_updated = maxi(_win_vt_updated, int(s.get("updated_blocks", 0)))


## NEVER-OOM INSTRUMENT (WALK-PERF L2 heap A/B) — the live WASM heap in MB, or -1 off-web/unavailable.
## docs/COSMOS-FP-M2-HEAP-AB.md's pass criterion is a heap A/B, but its instrument is MANUAL browser
## DevTools (performance.memory), and telemetry carried only vmem_mb (VIDEO memory — a different thing
## entirely). Without this the mimalloc A/B could not be judged against the NEVER-OOM ceiling at all,
## and "it got faster" would be the only number in the room — exactly the trade the rule forbids.
## mimalloc reserves per-thread segments, so this is THE number that can veto the frame-time win.
## `wasmMemory.buffer.byteLength` is the true linear-memory size (what actually OOMs a tab); HEAP8 is
## the fallback name. Evaluated once per telemetry window (4 Hz) — a trivial eval, not per frame.
func _wasm_heap_mb() -> float:
	if not OS.has_feature("web"):
		return -1.0
	# v1 tried `wasmMemory` / `HEAP8` from page scope and always read -1: Godot's web export keeps the
	# Module (and its heap views) inside a closure, so they are NOT page-scope globals. Don't chase that.
	# `performance.measureUserAgentSpecificMemory()` is the supported route and requires exactly the
	# crossOriginIsolated state our COOP/COEP deploy ALWAYS guarantees (it is why threads work at all).
	# It is ASYNC, so: kick a measurement off, stash the result on window, and read the PREVIOUS tick's
	# value. A one-tick (250 ms) lag is irrelevant for a peak/steady-state gate. `_measuring` prevents
	# stacking overlapping measurements (the call is not free).
	JavaScriptBridge.eval(
		"(function(){try{" +
		"if(!self.crossOriginIsolated||!performance.measureUserAgentSpecificMemory){window.__voxHeapBytes=-2;return;}" +
		"if(window.__voxHeapBusy)return;" +
		"window.__voxHeapBusy=1;" +
		"performance.measureUserAgentSpecificMemory().then(function(m){window.__voxHeapBytes=m.bytes;window.__voxHeapBusy=0;})" +
		".catch(function(){window.__voxHeapBytes=-3;window.__voxHeapBusy=0;});" +
		"}catch(e){window.__voxHeapBytes=-4;}})()", true)
	var v = JavaScriptBridge.eval("(typeof window.__voxHeapBytes==='number')?window.__voxHeapBytes:-1", true)
	if v == null:
		return -1.0
	var b := float(v)
	# Negative sentinels are diagnostics, not sizes: -2 not crossOriginIsolated / API absent, -3 the
	# promise rejected, -4 threw, -1 not yet resolved. Passed through so the trace says WHY it is absent
	# rather than silently reading as a measured value.
	return b if b < 0.0 else b / 1048576.0


func _send_telemetry() -> void:
	# Window stats (fps + worst frame over the just-elapsed window), then reset the window.
	var fps := (float(_win_frames) / _win_acc) if _win_acc > 0.0 else 0.0
	var worst_ms := _win_worst * 1000.0
	var min_fps := 1000.0 / maxf(worst_ms, 0.001)
	_last_window_worst_ms = worst_ms          # L2: the threshold gate reads this before scheduling the next auto-capture
	_win_acc = 0.0
	_win_frames = 0
	_win_worst = 0.0

	# MAIN-THREAD BREAKDOWN: latch + reset this window's maxima (ms, 0.01 precision). vt_total is the
	# headline: compare it against worst_ms for the SAME window. vt_total ≈ worst_ms ⇒ the hitch IS
	# VoxelTerrain::_process (and vt_load_resp says whether it is the apply path); vt_total << worst_ms
	# ⇒ the hitch is OUTSIDE _process entirely (render / GPU upload / elsewhere) and the streaming-
	# throughput framing is aimed at the wrong term.
	var vt: Dictionary = {}
	if _win_vt_seen:
		vt = {
			"vt_total_ms": snappedf(float(_win_vt_total) / 1000.0, 0.01),
			"vt_load_resp_ms": snappedf(float(_win_vt_load_resp) / 1000.0, 0.01),
			"vt_detect_ms": snappedf(float(_win_vt_detect) / 1000.0, 0.01),
			"vt_req_load_ms": snappedf(float(_win_vt_req_load) / 1000.0, 0.01),
			"vt_req_upd_ms": snappedf(float(_win_vt_req_upd) / 1000.0, 0.01),
			"vt_updated_max": _win_vt_updated,
			"vt_dropped_loads": _win_vt_dropped_loads,
			"vt_dropped_meshs": _win_vt_dropped_meshs,
		}
	_win_vt_detect = 0
	_win_vt_req_load = 0
	_win_vt_load_resp = 0
	_win_vt_req_upd = 0
	_win_vt_total = 0
	_win_vt_dropped_loads = 0
	_win_vt_dropped_meshs = 0
	_win_vt_updated = 0
	_win_vt_seen = false

	# godot_voxel worker backlog (perf_hud.gd reads the TASK counts — memory_pools.block_count lies).
	var vox_gen := 0
	var vox_mesh := 0
	var vox_main := 0
	var vox_gpu := 0
	# WALK-PERF L1 (docs/COSMOS-WALK-PERF-DESIGN.md §4 L1) — the H-A/H-B discriminator. The dlmalloc-convoy
	# hypothesis (workers and main thread throttling each other through the single global malloc lock) predicts
	# the pool runs its FULL thread_count but each thread CRAWLS: during a stationary drain active_threads ≈ 10
	# ⇒ H-A. If instead active_threads ≤ 3, few threads are actually running ⇒ H-B (pool/scheduling), and the
	# mimalloc rebuild would be wasted. Free: get_stats() is already fetched+built here.
	# NOTE std_current is #ifdef DEBUG_ENABLED in voxel_engine_gd.cpp:149-158 — a RELEASE web export returns
	# -1. Emitted anyway so the trace records "unavailable" explicitly rather than looking like a real zero.
	var pool_threads := -1
	var pool_active := -1
	var pool_tasks := ""
	var vox_std_current := -1
	if _voxel_engine != null and _voxel_engine.has_method("get_stats"):
		var st: Dictionary = _voxel_engine.call("get_stats")
		var tasks: Dictionary = st.get("tasks", {})
		var gpool: Dictionary = (st.get("thread_pools", {}) as Dictionary).get("general", {})
		pool_threads = int(gpool.get("thread_count", -1))
		pool_active = int(gpool.get("active_threads", -1))
		var tn = gpool.get("task_names", null)
		if tn is PackedStringArray:
			var names := PackedStringArray()
			for n in (tn as PackedStringArray):
				if String(n) != "":
					names.append(String(n))
			pool_tasks = ",".join(names)
		vox_std_current = int((st.get("memory_pools", {}) as Dictionary).get("std_current", -1))
		vox_gen = int(tasks.get("generation", 0))
		vox_mesh = int(tasks.get("meshing", 0))
		vox_main = int(tasks.get("main_thread", 0))
		vox_gpu = int(tasks.get("gpu", 0))

	var msg := {
		"type": "telemetry",
		"t": Time.get_unix_time_from_system(),
		"up_ms": Time.get_ticks_msec(),
		"fps": snappedf(fps, 0.1),
		"min_fps": snappedf(min_fps, 0.1),
		"worst_ms": snappedf(worst_ms, 0.1),
		"hitches": _hitches,
		"proc_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
		"phys_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"vmem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		# NEVER-OOM: the WASM linear-memory size (what actually OOMs a tab) + Godot's own tracked static
		# allocation. vmem_mb above is VIDEO memory and is NOT the NEVER-OOM signal. heap_mb is the number
		# that can VETO the mimalloc win (per-thread segments raise the baseline) — see _wasm_heap_mb.
		"heap_mb": snappedf(_wasm_heap_mb(), 0.1),
		"mem_static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"objects": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"vox_gen": vox_gen,
		"vox_mesh": vox_mesh,
		"vox_main": vox_main,
		"vox_gpu": vox_gpu,
		# WALK-PERF L1: the dlmalloc-convoy discriminator (see above). pool_active ≈ pool_threads during a
		# stationary drain ⇒ threads run-but-crawl ⇒ H-A (convoy) ⇒ the mimalloc rebuild is justified.
		"pool_threads": pool_threads,
		"pool_active": pool_active,
		"pool_tasks": pool_tasks,
		"vox_std_current": vox_std_current,
	}
	# MAIN-THREAD BREAKDOWN: fold in this window's VoxelTerrain::_process maxima (omitted entirely on the
	# fallback path / before setup, so a missing key means "no module terrain", never "measured zero").
	msg.merge(vt)
	# STREAM-SCHED T1 (docs/COSMOS-STREAM-SCHED-DESIGN.md §7 row T1 / §9.1) — the generator's per-class block
	# histogram: 0 = air/cheap early-out, 1 = whole-block bulk fill, 2 = underground per-cell (the min_h-gate-
	# FAILED class R1 targets), 3 = surface-crossing. §2.3's supply model ASSUMES a 30/25/25/20 mix and names
	# that its own soft spot; these fields MEASURE it, so R1 is judged on the real histogram. Reported as this
	# window's DELTA — gen_ms_N / gen_ct_N reads directly as mean ms/block for class N.
	# Two caveats that must travel with the numbers:
	#  • the counters are cumulative per generator EPOCH and restart at 0 when a crossing installs a new
	#    generator, so a negative delta means "epoch changed", not negative work — floored at 0 (that one
	#    window under-reports rather than emitting nonsense).
	#  • TELEMETRY-GRADE: the voxel workers share one generator instance and race the `+=`, so both ct and ms
	#    UNDERCOUNT under load. The per-class SHARES and the ms/block ratios are the signal; the absolute
	#    block count is not (compare it against vox_gen/dropped, don't treat it as a census).
	# `dropped_block_loads` — T1's other half, the R4 go/no-go stale share — already ships as vt_dropped_loads.
	var gcs: Dictionary = {}
	if is_instance_valid(world) and world.has_method("gen_class_stats"):
		var g = world.call("gen_class_stats")
		if g is Dictionary:
			gcs = g as Dictionary
	if not gcs.is_empty():
		var cct: Array = gcs.get("ct", [])
		var cus: Array = gcs.get("us", [])
		for i in range(4):
			var c := int(cct[i]) if i < cct.size() else 0
			var u := int(cus[i]) if i < cus.size() else 0
			msg["gen_ct_%d" % i] = maxi(0, c - int(_gen_prev_ct[i]))
			msg["gen_ms_%d" % i] = snappedf(float(maxi(0, u - int(_gen_prev_us[i]))) / 1000.0, 0.01)
			_gen_prev_ct[i] = c
			_gen_prev_us[i] = u
	_merge_rich_state(msg)

	# T2f (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): per-consumer attribution + the capture-window marker. snow_ms/ctrl_ms
	# are this window's WORST single-frame snowfall-step / controller-tick cost (WorldManager accumulates the max, resets on
	# read); cap=1 marks a window whose frames include the ambient capture readback (~35 ms) so the §6 metrics can exclude
	# capture-polluted windows honestly. Telemetry-only — no frame behaviour changes.
	if is_instance_valid(world) and world.has_method("take_perf_attrib"):
		var pa = world.call("take_perf_attrib")
		if pa is Dictionary:
			msg.merge(pa as Dictionary)
	if _win_had_capture:
		msg["cap"] = 1
		_win_had_capture = false

	# CROSSING-FASTGEN obs-2 fix (4): stamp the EXPORTED FP_* flag set into the FIRST telemetry record (deploy flips these
	# via sed before export, so reading the compiled consts gives exactly-what-shipped provenance — BUILD-INFO.txt is
	# written during the earlier engine build, before the sed, so it cannot). Emitted once (small, static); read live.
	if not _flags_emitted:
		_flags_emitted = true
		msg["flags"] = {
			"FACETED": CubeSphere.FACETED, "FP_M1_POOL": CubeSphere.FP_M1_POOL, "FP_M2_LOD": CubeSphere.FP_M2_LOD,
			"FP_CTRL_ADAPTIVE": CubeSphere.FP_CTRL_ADAPTIVE, "FP_PREFILL_112": CubeSphere.FP_PREFILL_112,
			"FP_VEL_PREDICT": CubeSphere.FP_VEL_PREDICT, "FP_FIXED_FRAME": CubeSphere.FP_FIXED_FRAME,
			"FP_FARRING_FULL_COVER": CubeSphere.FP_FARRING_FULL_COVER, "FP_NO_NEAR_LOD": CubeSphere.FP_NO_NEAR_LOD,
			"FP_ATLAS_MATERIAL": CubeSphere.FP_ATLAS_MATERIAL, "POOL_CROSSING_PREGEN": CubeSphere.POOL_CROSSING_PREGEN,
			# T2d (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): the post-port provenance gap — we could not prove what build
			# produced a telemetry file (the async far-ring / CPPGEN / sky deploy state was unknown from telemetry alone).
			"FP_CPPGEN": CubeSphere.FP_CPPGEN, "FP_FARRING_FAST_REBUILD": CubeSphere.FP_FARRING_FAST_REBUILD,
			"FP_FARRING_ASYNC_REBUILD": CubeSphere.FP_FARRING_ASYNC_REBUILD, "ORBITAL_SKY": CubeSphere.ORBITAL_SKY,
			"FP_COLBULK": CubeSphere.FP_COLBULK, "FP_STAMP": CubeSphere.FP_STAMP,
			"FP_INFLIGHT_GATE": CubeSphere.FP_INFLIGHT_GATE,
		}

	# Telemetry is small (~1 KB) and the signal we most want to keep, so it is NOT shed at the frame
	# threshold — but under a total network stall the buffer could still creep up, so only send while
	# there is clear headroom below the ring cap. This keeps ERR_OUT_OF_MEMORY out of the console.
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and _ws.get_current_outbound_buffered_amount() < OUTBOUND_BUFFER_BYTES - 65536:
		_ws.send_text(JSON.stringify(msg))


## A1 CROSSING INSTRUMENTATION (#114): drain WorldManager's per-crossing attribution queue and send each record as a
## DISTINCT {"type":"crossing", …} text message on the SAME authed socket as the ambient telemetry (the relay appends
## any unknown JSON line to telemetry.jsonl — no relay change needed). Each record carries the transform-write ms (the
## NOTIFICATION_TRANSFORM_CHANGED spike), the crossing total + phase split, and the re-placed block/neighbour/LOD
## counts, so a real-GPU walkthrough can ATTRIBUTE the hitch. Guarded for absence (non-faceted / GDScript path) and
## backpressure so it never crashes the bridge nor piles onto a stalled socket. The ambient telemetry stream is intact.
func _drain_crossing_events() -> void:
	if not is_instance_valid(world) or not world.has_method("take_crossing_events"):
		return
	var events: Array = world.call("take_crossing_events")
	if events.is_empty():
		return
	for ev in events:
		if not (ev is Dictionary):
			continue
		# Only send while there is clear ring-buffer headroom (parity with _send_telemetry) — a crossing record is
		# small (~250 B) and the signal we most want, but under a total stall we still refuse to grow the buffer.
		if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN \
				or _ws.get_current_outbound_buffered_amount() >= OUTBOUND_BUFFER_BYTES - 65536:
			break
		var msg: Dictionary = (ev as Dictionary).duplicate()
		msg["type"] = "crossing"          # relay/reader message discriminator (the record keeps its own "ev":"crossing")
		msg["t"] = Time.get_unix_time_from_system()
		msg["up_ms"] = Time.get_ticks_msec()
		_ws.send_text(JSON.stringify(msg))
		# A1-REFINE (#114): open a post-crossing attribution window (the deferred re-place lands in the next ~1.2 s).
		if _post_cross.size() < POST_CROSS_MAX:
			_post_cross.append({"from": int((ev as Dictionary).get("from_fid", -1)), "to": int((ev as Dictionary).get("to_fid", -1)),
				"end_usec": Time.get_ticks_usec() + POST_CROSS_WINDOW_MS * 1000, "worst_ms": 0.0, "frames": 0})


## T2e (docs/COSMOS-PERF-POSTPORT-DESIGN.md §3): drain WorldManager's far-ring build/swap timing queue and publish each
## record as a distinct {"type":"farring", path, build_ms, swap_ms, verts} JSON on the authed telemetry socket (the relay
## appends any unknown JSON line to telemetry.jsonl — no relay change). Same guards/backpressure as the crossing drain, so
## it never crashes the bridge nor piles onto a stalled socket. The record already carries its own "type":"farring".
func _drain_farring_events() -> void:
	if not is_instance_valid(world) or not world.has_method("take_farring_events"):
		return
	var events: Array = world.call("take_farring_events")
	if events.is_empty():
		return
	for ev in events:
		if not (ev is Dictionary):
			continue
		if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN \
				or _ws.get_current_outbound_buffered_amount() >= OUTBOUND_BUFFER_BYTES - 65536:
			break
		var msg: Dictionary = (ev as Dictionary).duplicate()
		msg["t"] = Time.get_unix_time_from_system()
		msg["up_ms"] = Time.get_ticks_msec()
		_ws.send_text(JSON.stringify(msg))


## A1-REFINE (#114): track the worst frame in each open post-crossing window; when a window closes, emit a
## {"ev":"crossing_after"} record attributing that DEFERRED spike to its crossing — the real cost the
## synchronous transform_ms bracket misses. Bounded (POST_CROSS_MAX), no-op when no window is open.
func _update_post_cross(now_usec: int, real_delta: float) -> void:
	var still: Array = []
	for w in _post_cross:
		w["frames"] = int(w["frames"]) + 1
		var ms := real_delta * 1000.0
		if ms > float(w["worst_ms"]):
			w["worst_ms"] = ms
		if now_usec >= int(w["end_usec"]):
			if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN \
					and _ws.get_current_outbound_buffered_amount() < OUTBOUND_BUFFER_BYTES - 65536:
				_ws.send_text(JSON.stringify({
					"type": "crossing_after", "ev": "crossing_after",
					"from_fid": int(w["from"]), "to_fid": int(w["to"]),
					"post_worst_ms": snappedf(float(w["worst_ms"]), 0.1), "frames": int(w["frames"]),
					"window_ms": POST_CROSS_WINDOW_MS,
					"t": Time.get_unix_time_from_system(), "up_ms": Time.get_ticks_msec()}))
		else:
			still.append(w)
	_post_cross = still


## Rich engine/world state — every field guarded for absence so a render-path/flag combination that
## lacks a method simply omits it (never crashes the bridge).
func _merge_rich_state(msg: Dictionary) -> void:
	if is_instance_valid(player):
		var p := player.global_position
		msg["pos"] = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]
		# COSMOS SPACE-NAV SN2 (§7.5): the nav-frame machine telemetry (nav_mode/frame_v/|v_bci|/nav_frame),
		# ADDITIVE + GUARDED — an empty dict (flag-off, or the method absent) merges nothing, so a build with
		# SN_NAV_MODES=false stamps exactly the shipped fields (byte-identical telemetry).
		if player.has_method("nav_telemetry"):
			var nt = player.call("nav_telemetry")
			if nt is Dictionary and not (nt as Dictionary).is_empty():
				msg.merge(nt as Dictionary)
			# COSMOS SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md): the self-verification telemetry (alt/v_circ/orbit_r/
			# body/dev_nav/coasting/flying/on_ground/att) a scripted test flight asserts each mechanic on. ADDITIVE +
			# empty-dict-guarded — space_telemetry() returns {} when the nav machine is off (byte-identical stream).
			if player.has_method("space_telemetry"):
				var stel = player.call("space_telemetry")
				if stel is Dictionary and not (stel as Dictionary).is_empty():
					msg.merge(stel as Dictionary)
		# COSMOS-PERF FALL-TIMING (FP_FALL_TIMING): the per-segment CPU µs (window MAX) for the free-fall hotspot hunt.
		# ADDITIVE + empty-dict-guarded exactly like space_telemetry — fall_timing() returns {} with the flag off (the
		# accumulator was never written), so a shipped build stamps NO t_*_us keys (byte-identical telemetry).
		if player.has_method("fall_timing"):
			var ft = player.call("fall_timing")
			if ft is Dictionary and not (ft as Dictionary).is_empty():
				msg.merge(ft as Dictionary)
		# COSMOS-ORBITAL-SHELL H-B: the live camera far plane, so "shell emitted but far side clipped" (far-plane) is
		# directly readable next to sh_d/sh_h (compare far to the limb tangent √(d²−R²)). Guarded; 0 when absent.
		if player.has_method("camera_far"):
			msg["cam_far"] = snappedf(float(player.call("camera_far")), 0.1)
	# Active facet is a global (faceted mode); -1 when non-faceted. Static call is always safe.
	msg["facet"] = TerrainConfig.active_facet()
	if is_instance_valid(world):
		if world.has_method("facet_pool_neighbour_count"):
			msg["facet_neighbours"] = int(world.call("facet_pool_neighbour_count"))
		if world.has_method("stream_load_credit"):
			msg["stream_credit"] = snappedf(float(world.call("stream_load_credit")), 0.001)
		# CROSSING-FASTGEN obs-2 fix (4): the controller setpoint/floor/overload trace, so "adaptive off" vs "on but
		# genuinely over setpoint" is directly readable alongside the credit. Guarded + empty-dict-guarded so a
		# flag/render-path combination without a live controller simply omits these (never crashes the bridge).
		if world.has_method("stream_load_stats"):
			var cs = world.call("stream_load_stats")
			if cs is Dictionary and not (cs as Dictionary).is_empty():
				msg["setpoint_ms"] = snappedf(float((cs as Dictionary).get("setpoint_ms", 0.0)), 0.1)
				msg["frame_worst_ema"] = snappedf(float((cs as Dictionary).get("frame_worst_ema", 0.0)), 0.1)
				msg["floor_p10"] = snappedf(float((cs as Dictionary).get("floor_p10_ms", 0.0)), 0.1)
				msg["backlog_gated"] = bool((cs as Dictionary).get("backlog_gated", false))
		# COSMOS FP-FIXED-FRAME Phase-0 guard (§3): the max |player render-abs| seen — the f32-precision headroom
		# signal that tells us whether a re-anchor is ever needed at the current R (0 unless the fixed frame is on).
		if world.has_method("player_abs_max"):
			msg["player_abs_max"] = snappedf(float(world.call("player_abs_max")), 0.1)
		if world.has_method("lod_stats"):
			var ls = world.call("lod_stats")
			if ls is Dictionary and not (ls as Dictionary).is_empty():
				msg["lod"] = ls
			# COSMOS-ORBITAL-SHELL live-path telemetry — the far-ring driver→warm→emit→draw state, so ONE orbit fly
			# disambiguates the far-side-blank stage (warm/emit stall vs draw/far-plane vs wrong axis). ADDITIVE +
			# empty-dict-guarded: with the camera-set law off/never-engaged shell_telemetry() is {} → nothing stamped.
		if world.has_method("shell_telemetry"):
			var sh = world.call("shell_telemetry")
			if sh is Dictionary and not (sh as Dictionary).is_empty():
				msg.merge(sh as Dictionary)


## Capture the game canvas and send it as a binary JPEG frame, unless a capture is already inflight
## or the socket is backpressured (skip, don't queue — a stale frame helps no one).
func _maybe_capture_frame() -> void:
	if _capturing or not _authed:
		return                            # never read back a frame before the relay's auth_ok
	if not _auto_frames_enabled:
		return                            # L2: ambient frames disabled (?frames=0 / set_auto_frames(false)) — clean measure
	if _last_window_worst_ms > CAPTURE_SKIP_WORST_MS:
		return                            # L2: last window already hitched — do not pile a ~35 ms readback onto a slow run
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if _ws.get_current_outbound_buffered_amount() > OUTBOUND_BACKPRESSURE_BYTES:
		return   # socket is behind — drop this frame rather than pile on latency
	_capturing = true
	_win_had_capture = true           # T2f: the ~35 ms readback lands this frame → mark the window for capture-exclusion in analysis
	_capture_frame_async()


func _capture_frame_async() -> void:
	# Wait for the frame to finish drawing so the viewport texture is complete, then read it back.
	# NOTE (web caveat): GPU→CPU readback of the viewport works on native; on the web Compatibility
	# (WebGL2) path it is unverified here — get_image() may be costly or unavailable. Guarded so a
	# null image simply skips the frame rather than erroring.
	await RenderingServer.frame_post_draw
	if not is_inside_tree() or _ws == null:
		_capturing = false
		return
	var vp := get_viewport()
	var img: Image = null
	if vp != null:
		var tex := vp.get_texture()
		if tex != null:
			img = tex.get_image()
	if img == null:
		_capturing = false
		return

	# L2 threaded encode: the readback is DONE (unavoidably on this thread). Hand the resize + JPEG to a worker on an
	# OWNED image so the engine thread pays nothing more; the finished bytes are sent from _poll_capture_encode (main).
	if CAPTURE_THREADED_ENCODE and _thread_encode_available():
		_cap_img = img                    # get_image() returned a fresh instance owned only by us — the worker is its sole toucher
		_cap_jpg = PackedByteArray()
		_cap_task_id = WorkerThreadPool.add_task(Callable(self, "_encode_worker"), false, "remote-bridge frame JPEG")
		return                            # stays _capturing until the worker finishes and the main thread sends (§ poll)

	# Synchronous fallback (flag off / no thread pool): downscale + encode + send inline, as before.
	_resize_to_cap(img)
	var jpg := img.save_jpg_to_buffer(FRAME_JPG_QUALITY)
	_send_frame_jpg(jpg)
	_capturing = false


## Whether the WorkerThreadPool has real background threads for the off-thread encode. On >1 core it sizes a worker pool
## (so is_task_completed flips without an explicit wait); on a single-core build there are no background workers → fall
## back to the synchronous path rather than risk a task that only runs when waited on. Our threaded web export is multi-core.
func _thread_encode_available() -> bool:
	return OS.get_processor_count() > 1


## WORKER THREAD (L2): pure CPU, NO scene tree / WS / RenderingServer access. Resizes the owned capture image to the
## width cap, then JPEG-encodes into _cap_jpg. The main thread reads _cap_jpg only after is_task_completed (happens-before).
func _encode_worker() -> void:
	if _cap_img == null:
		return
	_resize_to_cap(_cap_img)
	_cap_jpg = _cap_img.save_jpg_to_buffer(FRAME_JPG_QUALITY)


## MAIN THREAD (L2): drain a finished threaded encode — send the bytes over the (non-thread-safe) WebSocket, then release
## the task + owned image and clear the single-flight guard. Called every frame from _process while a task is pending.
func _poll_capture_encode() -> void:
	if _cap_task_id == -1:
		return
	if not WorkerThreadPool.is_task_completed(_cap_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_cap_task_id)   # already done — reclaims the task handle (never blocks here)
	var jpg := _cap_jpg
	_cap_task_id = -1
	_cap_img = null
	_cap_jpg = PackedByteArray()
	_send_frame_jpg(jpg)
	_capturing = false


## Downscale an image to FRAME_MAX_WIDTH (preserve aspect). Safe to call on a worker thread (pure CPU, no server).
func _resize_to_cap(img: Image) -> void:
	var w := img.get_width()
	if w > FRAME_MAX_WIDTH and w > 0:
		var scale := float(FRAME_MAX_WIDTH) / float(w)
		img.resize(FRAME_MAX_WIDTH, maxi(1, int(round(float(img.get_height()) * scale))),
			Image.INTERPOLATE_BILINEAR)


## MAIN THREAD ONLY: send an encoded JPEG as a tagged BINARY frame, honoring the same open/backpressure guards as before.
func _send_frame_jpg(jpg: PackedByteArray) -> void:
	if jpg.size() > 0 and _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and _ws.get_current_outbound_buffered_amount() <= OUTBOUND_BACKPRESSURE_BYTES:
		var packet := PackedByteArray([FRAME_TAG])
		packet.append_array(jpg)
		_ws.send(packet)


## Phase-1 auth handshake (extracted so the inbound loop reads cleanly). Only a real {"type":"auth_ok"}
## flips the gate + resets the backoff ladder — identical semantics to the original inline check.
func _try_auth(txt: String) -> void:
	if txt.find("auth_ok") == -1:
		return
	var j = JSON.parse_string(txt)
	if j is Dictionary and str((j as Dictionary).get("type", "")) == "auth_ok":
		_authed = true
		_backoff = RECONNECT_BACKOFF_MIN     # only a REAL auth resets the backoff ladder
		_set_link(true)                      # authenticated + open → badge "REMOTE ACTIVE — observing"


# ══════════════════════════════════════════════════════════════════════════════════════════════════
# P2 REMOTE CONTROL. Everything below runs ONLY when CONTROL_ENABLED is true (the dispatch + tick are
# gated in _process). DEFAULT-DENY: no command executes without an active, human-consented grant.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

## Strict type-whitelist dispatch of an authed inbound text frame (§3.1). Unknown types are dropped.
func _dispatch_control(txt: String) -> void:
	var j = JSON.parse_string(txt)
	if not (j is Dictionary):
		return
	var m: Dictionary = j
	match str(m.get("type", "")):
		"control_offer":  _on_control_offer(m)
		"cmd_seq":        _on_cmd_seq(m)
		"control_ping":   _on_control_ping()
		"control_revoke": _on_control_revoke(m)
		"control_result": _on_control_result(m)
		# auth_ok (duplicate) and anything else: drained-and-discarded.


# ── Consent grant lifecycle (activator drives the UI + the human click; the bridge owns the wire) ──

## The relay offers control (a command is waiting on a granted socket). If a valid UNATTENDED grant
## was restored from localStorage at boot (§6.6) we re-arm WITHOUT a human click; otherwise the
## activator shows the capability-enumerating consent modal (§6.1 / resolved D5).
func _on_control_offer(m: Dictionary) -> void:
	var seq := str(m.get("seq", ""))
	# F1: remember the relay-minted nonce so grant_control can echo it back (proving this exact socket
	# received the offer). Refreshed on every offer, so a session re-consent uses the freshly-minted one.
	_grant_nonce = str(m.get("grant_nonce", ""))
	if _control_state == "granted":
		return                               # already driving — the relay just (re)advertised
	if _rearm_unattended_id != "":
		var uid := _rearm_unattended_id
		var ck := _rearm_control_secret       # §9.4: the stored control secret proves the fresh nonce
		_rearm_unattended_id = ""
		_rearm_control_secret = ""
		grant_control(uid, true, ck)          # persistent mode: auto re-arm, no modal
		return
	control_offer_in.emit(seq)               # → activator consent modal


## Called by the activator when the human ALLOWS (session) or ENABLES UNATTENDED. grant_id is a
## game-generated opaque token bound to this consent (echoed on every cmd_ack). control_secret (#113) is
## the host control key the human typed / the stored key on an unattended re-arm; a non-empty value is
## latched into RAM (_control_secret) so a later D2 re-consent within the session is click-only ("" keeps
## the existing RAM copy). The proof is computed inside _send_control_state.
func grant_control(grant_id: String, unattended: bool, control_secret: String = "") -> void:
	if not CONTROL_ENABLED:
		return
	if control_secret != "":
		_control_secret = control_secret     # latch the typed/stored key; kept RAM-only for the session
	_control_state = "granted"
	_grant_id = grant_id
	_unattended = unattended
	_suspend_resume_at = 0
	_last_ping_ms = Time.get_ticks_msec()
	_send_control_state("granted", grant_id)
	_ensure_executor()
	control_phase.emit("granted", {"unattended": unattended})


## Human DENIED the offer — tell the relay so it rejects the pending outbox file (no_consent).
func deny_control() -> void:
	if not CONTROL_ENABLED:
		return
	_send_control_state("denied", "")
	_control_state = "none"
	_grant_id = ""
	_control_secret = ""                     # #113: drop the RAM secret on an explicit deny
	control_phase.emit("observing", {})


## Esc / the revoke chord (§6.4). Hard stop: end the grant, tear down the executor, back to observe.
## (The activator additionally CLEARS the localStorage unattended grant on this path.)
func revoke_control() -> void:
	if not CONTROL_ENABLED:
		return
	_send_control_state("revoked", "")
	if is_instance_valid(_exec):
		_exec.abort("aborted")
	_free_executor()
	_control_state = "none"
	_grant_id = ""
	_control_secret = ""                     # #113: hard stop clears the RAM secret (re-consent must retype)
	_unattended = false
	_suspend_resume_at = 0
	control_phase.emit("revoked", {})


func is_control_granted() -> bool:
	return _control_state == "granted"


func control_is_unattended() -> bool:
	return _unattended


## Activator → bridge at boot: a valid localStorage unattended grant exists for this token; auto-arm
## on the next relay offer (no human click). The opaque id is never the observe secret (§6.6); the
## control_secret (#113/§9.4) is the stored key that lets the re-arm PROVE the fresh nonce after a reload
## destroyed the RAM copy. Attended sessions never reach here (they store nothing).
func arm_unattended_rearm(unattended_id: String, control_secret: String = "") -> void:
	_rearm_unattended_id = unattended_id
	_rearm_control_secret = control_secret


## Same-process getter so the activator can PREFILL the control-key field on a D2 re-consent (§9.4),
## making it click-only. Returns "" when no key is held. Never crosses the process/trust boundary.
func peek_control_secret() -> String:
	return _control_secret


# ── Command sequence intake ────────────────────────────────────────────────────────────────────────

func _on_cmd_seq(m: Dictionary) -> void:
	var seq := str(m.get("seq", ""))
	if _control_state != "granted":
		_send_cmd_nack(seq, "no_consent")     # DEFAULT-DENY: no grant ⇒ nothing runs (defence-in-depth; relay also gates)
		return
	var reason := _validate_cmd(m)            # rover-side cap re-validation — never trust the relay blindly
	if reason != "":
		_send_cmd_nack(seq, reason)
		return
	if is_instance_valid(_exec) and _exec.is_running():
		if m.get("preempt", false) == true:
			_exec.abort("aborted")            # D3: abort-and-replace the running sequence
		else:
			_send_cmd_nack(seq, "busy")       # exactly one sequence in flight (§1.3)
			return
	_ensure_executor()
	_send_cmd_ack(seq, (m.get("steps", []) as Array).size())
	_exec.begin_sequence(m)


## Mirror of the relay's validateCmd (relay.mjs) — caps re-checked on the rover. Returns "" if OK,
## else a nack reason (bad_json | caps | stale).
func _validate_cmd(m: Dictionary) -> String:
	if str(m.get("type", "")) != "cmd_seq":
		return "bad_json"
	if str(m.get("seq", "")) == "":
		return "bad_json"
	var issued = m.get("issued", null)
	if not (issued is float or issued is int):
		return "bad_json"
	if Time.get_unix_time_from_system() - float(issued) > STALE_S:
		return "stale"
	var steps_val = m.get("steps", null)
	if not (steps_val is Array):
		return "bad_json"
	var steps: Array = steps_val
	if steps.is_empty() or steps.size() > MAX_STEPS:
		return "caps"
	for st in steps:
		if not (st is Dictionary):
			return "bad_json"
		var op := str((st as Dictionary).get("op", ""))
		if not OP_WHITELIST.has(op):
			return "caps"
		if op == "move":
			var b = (st as Dictionary).get("blocks", null)
			if not (b is float or b is int) or float(b) <= 0.0 or float(b) > MAX_MOVE_BLOCKS:
				return "caps"
		# SPACE-FLY: thrust/roll are TIMED holds — the seconds must be a finite, bounded, positive number.
		if op == "thrust" or op == "roll":
			var s = (st as Dictionary).get("seconds", null)
			if not (s is float or s is int) or float(s) <= 0.0 or float(s) > MAX_HOLD_S:
				return "caps"
		# SPACE-FLY: dev_nav.on must be a bool; nav.verb must be a known verb.
		if op == "dev_nav" and not ((st as Dictionary).get("on", null) is bool):
			return "caps"
		if op == "nav" and not ["orbit", "geostation", "detach"].has(str((st as Dictionary).get("verb", ""))):
			return "caps"
	return ""


# ── Downlink send helpers (executor callbacks → WS text/binary frames) ──────────────────────────────

func _on_step_started(rec: Dictionary) -> void:
	_send_text_guarded(rec)


func _on_step_finished(rec: Dictionary) -> void:
	_send_text_guarded(rec)


func _on_sequence_finished(rec: Dictionary) -> void:
	_send_text_guarded(rec)
	_assert_idle_badge()                          # driving → idle (but NOT if this seq ended via override/suspend)


func _on_exec_progress(text: String) -> void:
	if text == "":
		_assert_idle_badge()
	else:
		control_phase.emit("driving", {"text": text, "unattended": _unattended})


## Re-assert the idle "granted" badge ONLY while the grant is genuinely live — never right after an
## override (session: _control_state left "none") or an unattended suspend (_suspend_resume_at > 0),
## whose terminal step_done/seq_done/progress("") callbacks would otherwise clobber the takeover badge.
func _assert_idle_badge() -> void:
	if _control_state == "granted" and _suspend_resume_at == 0:
		control_phase.emit("granted", {"unattended": _unattended})


## Any local input while granted (§6.4). D2: the grant ENDS (re-consent). §6.6 UNATTENDED: SUSPEND +
## auto-resume after the idle window (a curious glance must not tear down an overnight run). The
## executor is freed deferred so its own step_done/seq_done:user_override records flush first.
func _on_exec_override() -> void:
	_send_control_state("override", "")
	if _unattended:
		_suspend_resume_at = Time.get_ticks_msec() + int(UNATTENDED_RESUME_IDLE_MS)
		control_phase.emit("suspended", {"unattended": true})
	else:
		_control_state = "none"
		_grant_id = ""
		control_phase.emit("override", {})
	call_deferred("_free_executor")


## reload op (§1.1). Only honoured while a grant is active + on web. Deferred one frame so any pending
## step_done/seq_done frames drain before the page navigates away.
func _on_reload_requested() -> void:
	if _control_state != "granted":
		return
	if OS.has_feature("web"):
		call_deferred("_do_reload")


func _do_reload() -> void:
	if _control_state == "granted" and OS.has_feature("web"):
		JavaScriptBridge.eval("location.reload()", true)


# ── Commanded screenshot: full-fidelity (D4), 0x02-tagged + correlated (§3.3) ───────────────────────

func _on_shot_requested(seq: String, id: int, label: String) -> void:
	_commanded_shot_async(seq, id, label)


func _commanded_shot_async(seq: String, id: int, label: String) -> void:
	var deadline := Time.get_ticks_msec() + SHOT_MAX_WAIT_MS
	while true:
		await RenderingServer.frame_post_draw
		if _ws == null or not is_inside_tree() or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			_notify_shot(id, false); return
		if _ws.get_current_outbound_buffered_amount() > OUTBOUND_BACKPRESSURE_BYTES:
			if Time.get_ticks_msec() > deadline:
				_notify_shot(id, false); return   # sustained backpressure → executor reports timeout
			continue                              # retry next frame — the agent explicitly asked for these pixels
		var img := _grab_viewport_image()
		if img == null:
			_notify_shot(id, false); return
		var jpg := _encode_shot(img)
		if jpg.size() == 0:
			_notify_shot(id, false); return
		_send_shot_frame(seq, id, label, jpg)
		_notify_shot(id, true); return


func _grab_viewport_image() -> Image:
	var vp := get_viewport()
	if vp == null:
		return null
	var tex := vp.get_texture()
	if tex == null:
		return null
	return tex.get_image()                        # viewport ONLY — the game canvas, never the screen (§6.3)


## Encode full-resolution, then step quality/size DOWN only if needed to fit under the 2 MiB cap (D4).
func _encode_shot(img: Image) -> PackedByteArray:
	var q := SHOT_JPG_QUALITY
	var jpg := img.save_jpg_to_buffer(q)
	while jpg.size() > MAX_SHOT_BYTES and q > 0.4:
		q -= 0.15
		jpg = img.save_jpg_to_buffer(q)
	if jpg.size() > MAX_SHOT_BYTES:
		var w := img.get_width()
		if w > 1280 and w > 0:
			var scale := 1280.0 / float(w)
			img.resize(1280, maxi(1, int(round(float(img.get_height()) * scale))), Image.INTERPOLATE_BILINEAR)
			jpg = img.save_jpg_to_buffer(0.6)
	if jpg.size() > MAX_SHOT_BYTES:
		return PackedByteArray()                  # give up rather than exceed the relay maxPayload
	return jpg


func _send_shot_frame(seq: String, id: int, label: String, jpg: PackedByteArray) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var hdr := JSON.stringify({"seq": seq, "id": id, "label": label, "t": Time.get_unix_time_from_system()})
	var hdr_bytes := hdr.to_utf8_buffer()
	var hlen := hdr_bytes.size()
	var packet := PackedByteArray([SHOT_TAG, (hlen >> 8) & 0xFF, hlen & 0xFF])
	packet.append_array(hdr_bytes)
	packet.append_array(jpg)
	_ws.send(packet)


func _notify_shot(id: int, ok: bool) -> void:
	if is_instance_valid(_exec):
		_exec.notify_shot(id, ok)


# ── Executor lifecycle ──────────────────────────────────────────────────────────────────────────────

func _ensure_executor() -> void:
	if is_instance_valid(_exec):
		return
	_exec = RemoteControl.new()
	_exec.name = "RemoteControl"
	_exec.player = player
	_exec.step_started.connect(_on_step_started)
	_exec.step_finished.connect(_on_step_finished)
	_exec.sequence_finished.connect(_on_sequence_finished)
	_exec.shot_requested.connect(_on_shot_requested)
	_exec.reload_requested.connect(_on_reload_requested)
	_exec.progress.connect(_on_exec_progress)
	_exec.override_triggered.connect(_on_exec_override)
	add_child(_exec)
	# P3 intent seam: hand the player a reference so Player._physics_process ticks the executor (§4.3).
	if is_instance_valid(player):
		player.set("remote_exec", _exec)


func _free_executor() -> void:
	# Clear the player's seam reference FIRST so a lingering physics_tick can't touch a freed executor.
	if is_instance_valid(player):
		player.set("remote_exec", null)
	if is_instance_valid(_exec):
		_exec.queue_free()
	_exec = null


# ── Heartbeat + fail-safes ────────────────────────────────────────────────────────────────────────

func _on_control_ping() -> void:
	_last_ping_ms = Time.get_ticks_msec()
	_send_text_guarded({"type": "control_pong", "t": Time.get_unix_time_from_system()})


## F2: the RELAY revoked our grant (ping timeout, or it echoed our own revoke). Previously this frame was
## outside the inbound whitelist, so the grant + badge stayed live until the ~16 s local ping timeout — a
## lying badge. Now we drop the grant the instant the relay says so: halt + free the executor and revert
## the badge to observing. Mirrors the link-loss fail-safe (§5.4): in unattended mode we keep the grant id
## so the next relay offer re-arms without a human click; otherwise re-consent is required.
func _on_control_revoke(_m: Dictionary) -> void:
	if _control_state != "granted" and _suspend_resume_at == 0:
		return
	if is_instance_valid(_exec):
		_exec.abort("aborted")
	_free_executor()
	_control_state = "none"
	_suspend_resume_at = 0
	if _unattended and _grant_id != "":
		_rearm_unattended_id = _grant_id
	else:
		_grant_id = ""
	control_phase.emit("observing", {})


func _control_tick() -> void:
	if _control_state == "granted":
		if _last_ping_ms > 0 and Time.get_ticks_msec() - _last_ping_ms > CTRL_PING_TIMEOUT_MS:
			_drop_grant_link_lost()
			return
	# UNATTENDED override → auto-resume once the human has been idle for the full window (§6.6).
	if _suspend_resume_at > 0 and Time.get_ticks_msec() >= _suspend_resume_at:
		if _local_input_idle():
			_suspend_resume_at = 0
			grant_control(_grant_id, true)        # re-arm from the stored grant (no human click)
		else:
			_suspend_resume_at = Time.get_ticks_msec() + 500   # human still active — keep waiting


## Socket left OPEN while granted (§5.4): halt the rover, drop consent to observe. In UNATTENDED mode
## the grant id is KEPT so a reconnect can re-arm via the stored grant; otherwise it is cleared.
func _drop_grant_link_lost() -> void:
	if is_instance_valid(_exec):
		_exec.abort("link_lost")
	_free_executor()
	_control_state = "none"
	_suspend_resume_at = 0
	if _unattended and _grant_id != "":
		_rearm_unattended_id = _grant_id     # §6.6: reconnect re-arms via the stored grant (no human click)
	else:
		_grant_id = ""
	control_phase.emit("observing", {})


func _local_input_idle() -> bool:
	return not Input.is_anything_pressed() and Input.get_last_mouse_velocity().length() < 40.0


func _send_control_state(state: String, grant_id: String) -> void:
	var msg := {"type": "control_state", "state": state}
	if grant_id != "":
		msg["grant_id"] = grant_id
	if state == "granted" and _grant_nonce != "":
		msg["grant_nonce"] = _grant_nonce   # F1: echo the relay-minted offer nonce so the grant is honoured
		# #113 (§9.2): PROVE knowledge of the control secret without ever transmitting it — a nonce-bound
		# HMAC. The relay recomputes it from its own secret + the nonce it minted for this socket and
		# accepts only on a match. An empty proof (no secret in RAM) will be refused (control_result).
		msg["grant_proof"] = _compute_grant_proof(_grant_nonce)
	_send_text_guarded(msg)


## #113 (§9.2): proof = hex(HMAC-SHA256(control_secret, "vxv-ctl-grant.v1\n" + nonce)). "" when no secret
## is held (an unprovable grant the relay refuses). The secret never leaves this function's inputs.
func _compute_grant_proof(nonce: String) -> String:
	if _control_secret == "":
		return ""
	var key := _control_secret.to_utf8_buffer()
	var message := ("vxv-ctl-grant.v1\n" + nonce).to_utf8_buffer()
	return _hmac_sha256_hex(key, message)


## HMAC-SHA256 → lowercase hex. Primary path is Godot's Crypto.hmac_digest (mbedTLS). Its availability on
## the THREADED WEB export is not verified on this host, so we fall back to a pure HashingContext HMAC
## (RFC 2104) — HashingContext/SHA-256 is used elsewhere in the engine and is known-present on web — so
## the proof is computed identically on every platform regardless of whether Crypto is compiled into the
## web template. Both produce the same bytes for the same key+message.
func _hmac_sha256_hex(key: PackedByteArray, message: PackedByteArray) -> String:
	var crypto := Crypto.new()
	if crypto.has_method("hmac_digest"):
		var digest: PackedByteArray = crypto.hmac_digest(HashingContext.HASH_SHA256, key, message)
		if digest.size() == 32:
			return digest.hex_encode()
	return _hmac_sha256_fallback(key, message).hex_encode()


## RFC 2104 HMAC-SHA256 built from HashingContext (guaranteed on the web export). Block size 64 B: keys
## longer than the block are hashed first; then inner = H((K⊕ipad)‖msg), out = H((K⊕opad)‖inner).
func _hmac_sha256_fallback(key: PackedByteArray, message: PackedByteArray) -> PackedByteArray:
	const BLOCK := 64
	var k := key
	if k.size() > BLOCK:
		k = _sha256_bytes(k)
	while k.size() < BLOCK:
		k.append(0)
	var ipad := PackedByteArray()
	var opad := PackedByteArray()
	ipad.resize(BLOCK)
	opad.resize(BLOCK)
	for i in range(BLOCK):
		ipad[i] = k[i] ^ 0x36
		opad[i] = k[i] ^ 0x5c
	var inner := ipad.duplicate()
	inner.append_array(message)
	var inner_hash := _sha256_bytes(inner)
	var outer := opad.duplicate()
	outer.append_array(inner_hash)
	return _sha256_bytes(outer)


func _sha256_bytes(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()


## #113 (§9.3): the relay's answer to our `granted`. accepted:true arms forwarding (badge already shows
## CONTROL from the optimistic grant, so nothing to do). accepted:false is a legitimate runtime refusal
## (typo'd key, rotated/stale control secret): drop the local grant so the badge never lies, clear the
## RAM secret, and signal the activator to re-open the attended modal (and, if this killed an UNATTENDED
## re-arm, clear the stale stored key first). The relay's forward gate never trusted our belief, so this
## is honesty, not enforcement.
func _on_control_result(m: Dictionary) -> void:
	if bool(m.get("accepted", false)):
		return
	var reason := str(m.get("reason", ""))
	var was_unattended := _unattended
	if is_instance_valid(_exec):
		_exec.abort("aborted")
	_free_executor()
	_control_state = "none"
	_grant_id = ""
	_control_secret = ""                     # the offered key was rejected — force a fresh retype
	_unattended = false
	_suspend_resume_at = 0
	control_phase.emit("observing", {})
	control_denied_relay.emit(reason, was_unattended)


func _send_cmd_ack(seq: String, steps: int) -> void:
	_send_text_guarded({
		"type": "cmd_ack", "seq": seq, "steps": steps, "grant_id": _grant_id,
		"t": Time.get_unix_time_from_system(),
	})


func _send_cmd_nack(seq: String, reason: String) -> void:
	_send_text_guarded({"type": "cmd_nack", "seq": seq, "reason": reason})


## Send a JSON text frame only while the socket is OPEN with clear ring headroom (parity with
## _send_telemetry) — keeps ERR_OUT_OF_MEMORY out of the console under a stall.
func _send_text_guarded(msg: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if _ws.get_current_outbound_buffered_amount() >= OUTBOUND_BUFFER_BYTES - 65536:
		return
	_ws.send_text(JSON.stringify(msg))


func _exit_tree() -> void:
	# L2: a threaded encode may still be running — BLOCK until it finishes so the worker never touches this freed node's
	# members after teardown (the task is a bound Callable on self). It is at most one resize+JPEG, so the wait is short.
	if _cap_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_cap_task_id)
		_cap_task_id = -1
		_cap_img = null
	# Clean teardown — free any executor, then close the socket so the relay sees a prompt disconnect.
	_free_executor()
	_control_secret = ""                     # #113: never leave the control secret in a freed node's RAM
	_rearm_control_secret = ""
	_set_link(false)
	if _ws != null:
		if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN or _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
			_ws.close(1000, "bye")
			_ws.poll()
		_ws = null
