class_name RemoteBridge
extends Node
## REMOTE-PLAY BRIDGE — Phase 1 (OBSERVE-ONLY). A token-gated, dial-OUT WebSocket that streams
## TELEMETRY (the perf_hud.gd numbers + rich engine state) and periodic downscaled FRAMES of the
## GAME CANVAS to a relay on our host, so a remote agent can OBSERVE a real-GPU play session.
##
## SECURITY MODEL (this is a PUBLIC live site — these are load-bearing):
##   * DEAD IN NORMAL PLAY. This node is instantiated by main.gd ONLY when dial mode is detected
##     (dial_config() non-empty). With no `?remote=<token>` in the page URL, main.gd never creates
##     it — no WebSocket, no frame capture, no per-frame cost, zero behavioural change. The headless
##     verify gate never runs main.gd, so it never sees this node (6027/0 stays structural).
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

# ── Configuration ──────────────────────────────────────────────────────────────────────────────
const DEFAULT_URL := "wss://voxiverse.game-host.org/remote"

## Phase-1 badge status verb. Phase 2 (control) upgrades this surface to "observing + CONTROLLING"
## through the SAME toggle + badge — the activator reads PHASE_STATUS, so the upgrade is one const.
const PHASE_STATUS := "observing"

const TELEMETRY_INTERVAL := 0.25    # s — one telemetry JSON per window (matches perf_hud WINDOW)
const FRAME_INTERVAL_MS := 500      # ms — ~2 fps frame stream
const FRAME_MAX_WIDTH := 960        # px — downscale cap for the JPEG (keeps bytes + readback modest)
const FRAME_JPG_QUALITY := 0.6
const FRAME_TAG := 0x01             # 1-byte type tag prefixing a binary JPEG frame (distinguish from JSON text)
const OUTBOUND_BACKPRESSURE_BYTES := 262144   # skip a frame if > 256 KB is still queued in the socket

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
var _win_acc := 0.0
var _win_frames := 0
var _win_worst := 0.0               # slowest frame (s) in the current window
var _hitches := 0                   # cumulative frames slower than HITCH_MS since start

var _frame_acc_ms := 0.0
var _capturing := false             # a frame readback+send is inflight (skip overlapping captures)
var _link_open := false             # last emitted link_state (so we emit only on transitions)


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

	# ── Frame-timing accumulation (perf_hud.gd parity) — cheap, runs whether or not connected. ──
	_win_acc += delta
	_win_frames += 1
	if delta > _win_worst:
		_win_worst = delta
	if delta * 1000.0 > HITCH_MS:
		_hitches += 1

	# ── Socket state machine ──────────────────────────────────────────────────────────────────
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_set_link(false)                     # link is down → badge reverts to "dialing…"
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
		_backoff = RECONNECT_BACKOFF_MIN     # a clean open resets the backoff ladder
		_send_hello()                        # socket open, but NOT yet live — wait for auth_ok

	# Drain inbound. The ONLY message the client acts on is the one auth_ok handshake (Phase 1 has no
	# control surface); everything else is discarded. auth_ok flips the gate that lets telemetry +
	# frames flow and turns the badge live.
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		if not _authed and not _ws.was_string_packet():
			continue                         # pre-auth binary is never expected — ignore
		if not _authed:
			var txt := pkt.get_string_from_utf8()
			if txt.find("auth_ok") != -1:
				var j = JSON.parse_string(txt)
				if j is Dictionary and str((j as Dictionary).get("type", "")) == "auth_ok":
					_authed = true
					_set_link(true)          # authenticated + open → badge "REMOTE ACTIVE — observing"

	# Nothing streams until the relay has acked our token.
	if not _authed:
		return

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

	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))


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


func _exit_tree() -> void:
	# Clean teardown — close the socket so the relay sees a prompt disconnect.
	_set_link(false)
	if _ws != null:
		if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN or _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
			_ws.close(1000, "bye")
			_ws.poll()
		_ws = null
