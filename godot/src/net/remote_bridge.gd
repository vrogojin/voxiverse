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
const OP_WHITELIST := ["move", "turn", "look", "wait", "jump", "screenshot", "set_fly", "stop", "break", "place", "select_slot", "reload"]

const TELEMETRY_INTERVAL := 0.25    # s — one telemetry JSON per window (matches perf_hud WINDOW)
const FRAME_INTERVAL_MS := 500      # ms — ~2 fps frame stream
const FRAME_MAX_WIDTH := 960        # px — downscale cap for the JPEG (keeps bytes + readback modest)
const FRAME_JPG_QUALITY := 0.6
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
var _link_open := false             # last emitted link_state (so we emit only on transitions)

# ── P2 control state (all inert while CONTROL_ENABLED is false — never touched on the Phase-1 path) ──
var _control_state := "none"        # none | granted
var _grant_id := ""                 # game-generated random id echoed on cmd_ack (binds results to this consent)
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
	if OS.has_feature("web"):
		# location.search is inherent to the page; a single boot-time eval decides whether to dial.
		# No param → empty token → {} → dead. This is the whole activation gate on the public site.
		var qs := ""
		var raw = JavaScriptBridge.eval("window.location.search", true)
		if raw != null:
			qs = str(raw)
		token = _parse_query_token(qs)
	else:
		token = OS.get_environment("VOXIVERSE_REMOTE_TOKEN")
	token = token.strip_edges()
	if token == "":
		return {}
	return {"token": token, "url": resolve_url()}


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


## Called by main.gd BEFORE add_child, with the dial_config() dictionary.
func configure(cfg: Dictionary) -> void:
	_token = str(cfg.get("token", ""))
	_url = str(cfg.get("url", DEFAULT_URL))


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
	# A1-REFINE (#114): fold this frame's true delta into any open post-crossing attribution window.
	if not _post_cross.is_empty():
		_update_post_cross(now_usec, real_delta)

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


func _send_telemetry() -> void:
	# Window stats (fps + worst frame over the just-elapsed window), then reset the window.
	var fps := (float(_win_frames) / _win_acc) if _win_acc > 0.0 else 0.0
	var worst_ms := _win_worst * 1000.0
	var min_fps := 1000.0 / maxf(worst_ms, 0.001)
	_win_acc = 0.0
	_win_frames = 0
	_win_worst = 0.0

	# godot_voxel worker backlog (perf_hud.gd reads the TASK counts — memory_pools.block_count lies).
	var vox_gen := 0
	var vox_mesh := 0
	var vox_main := 0
	var vox_gpu := 0
	if _voxel_engine != null and _voxel_engine.has_method("get_stats"):
		var st: Dictionary = _voxel_engine.call("get_stats")
		var tasks: Dictionary = st.get("tasks", {})
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
		"objects": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"vox_gen": vox_gen,
		"vox_mesh": vox_mesh,
		"vox_main": vox_main,
		"vox_gpu": vox_gpu,
	}
	_merge_rich_state(msg)

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
	# Active facet is a global (faceted mode); -1 when non-faceted. Static call is always safe.
	msg["facet"] = TerrainConfig.active_facet()
	if is_instance_valid(world):
		if world.has_method("facet_pool_neighbour_count"):
			msg["facet_neighbours"] = int(world.call("facet_pool_neighbour_count"))
		if world.has_method("stream_load_credit"):
			msg["stream_credit"] = snappedf(float(world.call("stream_load_credit")), 0.001)
		# COSMOS FP-FIXED-FRAME Phase-0 guard (§3): the max |player render-abs| seen — the f32-precision headroom
		# signal that tells us whether a re-anchor is ever needed at the current R (0 unless the fixed frame is on).
		if world.has_method("player_abs_max"):
			msg["player_abs_max"] = snappedf(float(world.call("player_abs_max")), 0.1)
		if world.has_method("lod_stats"):
			var ls = world.call("lod_stats")
			if ls is Dictionary and not (ls as Dictionary).is_empty():
				msg["lod"] = ls


## Capture the game canvas and send it as a binary JPEG frame, unless a capture is already inflight
## or the socket is backpressured (skip, don't queue — a stale frame helps no one).
func _maybe_capture_frame() -> void:
	if _capturing or not _authed:
		return                            # never read back a frame before the relay's auth_ok
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if _ws.get_current_outbound_buffered_amount() > OUTBOUND_BACKPRESSURE_BYTES:
		return   # socket is behind — drop this frame rather than pile on latency
	_capturing = true
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

	# Downscale to the width cap (preserve aspect), then JPEG-encode.
	var w := img.get_width()
	if w > FRAME_MAX_WIDTH and w > 0:
		var scale := float(FRAME_MAX_WIDTH) / float(w)
		img.resize(FRAME_MAX_WIDTH, maxi(1, int(round(float(img.get_height()) * scale))),
			Image.INTERPOLATE_BILINEAR)
	var jpg := img.save_jpg_to_buffer(FRAME_JPG_QUALITY)
	if jpg.size() > 0 and _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and _ws.get_current_outbound_buffered_amount() <= OUTBOUND_BACKPRESSURE_BYTES:
		# 1-byte type tag + JPEG bytes, sent as a BINARY frame.
		var packet := PackedByteArray([FRAME_TAG])
		packet.append_array(jpg)
		_ws.send(packet)
	_capturing = false


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
		"control_offer": _on_control_offer(m)
		"cmd_seq":       _on_cmd_seq(m)
		"control_ping":  _on_control_ping()
		# auth_ok (duplicate) and anything else: drained-and-discarded.


# ── Consent grant lifecycle (activator drives the UI + the human click; the bridge owns the wire) ──

## The relay offers control (a command is waiting on a granted socket). If a valid UNATTENDED grant
## was restored from localStorage at boot (§6.6) we re-arm WITHOUT a human click; otherwise the
## activator shows the capability-enumerating consent modal (§6.1 / resolved D5).
func _on_control_offer(m: Dictionary) -> void:
	var seq := str(m.get("seq", ""))
	if _control_state == "granted":
		return                               # already driving — the relay just (re)advertised
	if _rearm_unattended_id != "":
		var uid := _rearm_unattended_id
		_rearm_unattended_id = ""
		grant_control(uid, true)             # persistent mode: auto re-arm, no modal
		return
	control_offer_in.emit(seq)               # → activator consent modal


## Called by the activator when the human ALLOWS (session) or ENABLES UNATTENDED. grant_id is a
## game-generated opaque token bound to this consent (echoed on every cmd_ack).
func grant_control(grant_id: String, unattended: bool) -> void:
	if not CONTROL_ENABLED:
		return
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
	_unattended = false
	_suspend_resume_at = 0
	control_phase.emit("revoked", {})


func is_control_granted() -> bool:
	return _control_state == "granted"


func control_is_unattended() -> bool:
	return _unattended


## Activator → bridge at boot: a valid localStorage unattended grant exists for this token; auto-arm
## on the next relay offer (no human click). Opaque id only — never the observe secret (§6.6).
func arm_unattended_rearm(unattended_id: String) -> void:
	_rearm_unattended_id = unattended_id


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


func _free_executor() -> void:
	if is_instance_valid(_exec):
		_exec.queue_free()
	_exec = null


# ── Heartbeat + fail-safes ────────────────────────────────────────────────────────────────────────

func _on_control_ping() -> void:
	_last_ping_ms = Time.get_ticks_msec()
	_send_text_guarded({"type": "control_pong", "t": Time.get_unix_time_from_system()})


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
	_send_text_guarded(msg)


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
	# Clean teardown — free any executor, then close the socket so the relay sees a prompt disconnect.
	_free_executor()
	_set_link(false)
	if _ws != null:
		if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN or _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
			_ws.close(1000, "bye")
			_ws.poll()
		_ws = null
