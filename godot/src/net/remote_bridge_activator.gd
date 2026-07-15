class_name RemoteBridgeActivator
extends Node
## RUNTIME ACTIVATION + TRUST UI for the remote-play bridge (net/remote_bridge.gd). Always present in
## the normal game (added by main.gd), but INPUT-ONLY and per-frame-FREE: it defines `_unhandled_key_input`
## (event-driven — fires on key events, never per frame) and NO `_process`. Until the activation chord
## fires with a valid token, it holds NOTHING live — no WebSocket, no capture. The headless verify gate
## never runs main.gd, so this node never exists there (verify_feature stays 6027/0).
##
## WHAT IT DOES:
##   * HOTKEY (Ctrl+Shift+F9) TOGGLES dial mode at runtime — connect ↔ disconnect. This is IN ADDITION
##     to the `?remote=<token>` URL param (which still auto-activates on boot). The chord avoids every
##     game keybind (WASD/Shift/Space/Ctrl/1-9/Esc/F) and common browser/OS shortcuts.
##   * TOKEN IS ALWAYS REQUIRED and RELAY-VALIDATED — the hotkey NEVER bypasses auth. On activation it
##     uses the URL-param/env token if present; otherwise it shows a small on-canvas token prompt and
##     dials only once a token is entered. The relay URL is FIXED (RemoteBridge.resolve_url()); the
##     prompt collects ONLY a token, never a URL, so a visitor can't be redirected to a rogue relay.
##     A visitor who presses the chord with NO token gets a prompt and, on empty/bad input, dials
##     nothing (or the relay rejects it) — no stream, no control.
##   * LIVE BADGE — a prominent, always-visible on-canvas indicator whenever the channel is live, so the
##     user can ALWAYS tell when the agent can observe (Phase 2: control) their session. It reflects the
##     real link state (dialing vs live) via RemoteBridge.link_state. Toggling off or closing the tab
##     tears the bridge down and hides the badge.
##
## PHASE 2 READINESS: control slots into this SAME toggle. The bridge already reports PHASE_STATUS
## ("observing"); when control lands the badge upgrades to "observing + CONTROLLING" with no new surface.

# Activation chord: Ctrl+Shift+F9. Deliberate + non-conflicting (F9 is free in major browsers; no game
# binding uses it). Change here if a conflict ever surfaces.
const CHORD_KEY := KEY_F9

var world: Node = null
var player: Node3D = null
var _preset_token := ""              # URL-param/env token captured at boot (may be "")

var _bridge: RemoteBridge = null
var _badge: CanvasLayer = null
var _badge_label: Label = null
var _prompt: CanvasLayer = null
var _prompt_field: LineEdit = null

# ── P2 CONTROL UI state (all inert while RemoteBridge.CONTROL_ENABLED is false) ──────────────────────
var _active_token := ""             # the token this session dialed with — keys the localStorage unattended grant
var _live := false                  # last link_state (dialing vs live) so the badge stays honest
var _ctl_phase := "observing"       # observing | granted | driving | suspended | override | revoked
var _ctl_unattended := false        # the active grant is the persistent §6.6 mode
var _driving_text := ""             # live "step N/M …" readout for the DRIVING badge
var _flashing := false              # a "— YOU HAVE CONTROL" override flash is up (§6.4 step 4)
var _consent: CanvasLayer = null    # the red consent / unattended modal (null = none up)
var _pending_offer_seq := ""        # the seq that triggered the offer (informational)
var _native_unattended := ""        # native/dev fallback for localStorage (web uses JavaScriptBridge)


func configure(world_ref: Node, player_ref: Node3D, preset_token: String) -> void:
	world = world_ref
	player = player_ref
	_preset_token = preset_token


func _ready() -> void:
	# URL-param / env pre-arm keeps the original Phase-1 behaviour: auto-dial on boot when a token was
	# supplied out-of-band. No token → nothing happens until the chord (then the prompt) is used.
	if _preset_token.strip_edges() != "":
		_activate(_preset_token.strip_edges())


## INPUT-ONLY, event-driven. Only the exact chord is consumed; every other key falls through untouched
## so normal play is byte-unchanged.
func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	# ── P2 control: Esc cancels an open consent modal, else REVOKES an active grant (§6.4). Gated so
	# that with control disabled Esc is byte-identically untouched (no grant + no modal ever exist). ──
	if RemoteBridge.CONTROL_ENABLED and k.keycode == KEY_ESCAPE:
		if _consent != null:
			get_viewport().set_input_as_handled()
			_deny_consent()
			return
		if is_instance_valid(_bridge) and _bridge.is_control_granted():
			get_viewport().set_input_as_handled()
			_bridge.revoke_control()
			_clear_unattended()               # Esc CLEARS the persistent unattended grant (hard, §6.6)
			return
	if k.keycode == CHORD_KEY and k.ctrl_pressed and k.shift_pressed and not k.alt_pressed and not k.meta_pressed:
		get_viewport().set_input_as_handled()
		_toggle()


func _toggle() -> void:
	if is_instance_valid(_bridge):
		_deactivate()
	elif _prompt != null:
		_close_prompt()               # chord again while the prompt is up = cancel it
	else:
		_begin_activation()


## Decide the token source: URL-param/env if present (no prompt needed), else ask for one on-canvas.
func _begin_activation() -> void:
	var tok := RemoteBridge.preset_token()
	if tok.strip_edges() != "":
		_activate(tok.strip_edges())
	else:
		_open_prompt()


## Build + attach the bridge with the FIXED relay URL and the given token. Show the badge (dialing).
func _activate(token: String) -> void:
	if is_instance_valid(_bridge):
		return
	_active_token = token
	_ctl_phase = "observing"
	_ctl_unattended = false
	_driving_text = ""
	_bridge = RemoteBridge.new()
	_bridge.name = "RemoteBridge"
	_bridge.configure({"token": token, "url": RemoteBridge.resolve_url()})
	_bridge.world = world
	_bridge.player = player
	_bridge.link_state.connect(_on_link_state)
	# P2 control wiring — ONLY when the master gate is on, so observe-only sessions are byte-identical.
	if RemoteBridge.CONTROL_ENABLED:
		_bridge.control_offer_in.connect(_on_control_offer_ui)
		_bridge.control_phase.connect(_on_control_phase)
		var uid := _load_unattended(token)      # persistent §6.6 grant restored across a reload?
		if uid != "":
			_bridge.arm_unattended_rearm(uid)   # auto re-arm on the next relay offer (no human click)
	add_child(_bridge)
	_show_badge(false)                # "dialing…" until the socket actually opens
	print("[REMOTE] activation requested (token-gated, fixed relay)")


func _deactivate() -> void:
	# The chord is a FULL revoke: if a grant is live, end it + clear the persistent unattended grant
	# before tearing the bridge down (§6.4 — the chord teardown implies revoke).
	if RemoteBridge.CONTROL_ENABLED and is_instance_valid(_bridge) and _bridge.is_control_granted():
		_bridge.revoke_control()
		_clear_unattended()
	if _consent != null:
		_close_consent()
	if is_instance_valid(_bridge):
		_bridge.queue_free()          # _exit_tree closes the socket + emits link_state(false)
	_bridge = null
	_ctl_phase = "observing"
	_ctl_unattended = false
	_hide_badge()
	print("[REMOTE] deactivated by user")


func _on_link_state(open: bool) -> void:
	# Keep the badge honest: reflect the REAL link, not just the intent to dial.
	_live = open
	if is_instance_valid(_bridge):
		_show_badge(open)


# ── Live badge ──────────────────────────────────────────────────────────────────────────────────
func _show_badge(live: bool) -> void:
	if _badge == null:
		_badge = CanvasLayer.new()
		_badge.layer = 200            # above the perf HUD (100) — the trust signal must never be hidden
		add_child(_badge)
		var panel := PanelContainer.new()
		panel.anchor_left = 0.5
		panel.anchor_right = 0.5
		panel.offset_top = 12.0
		panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.72)
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(8.0)
		panel.add_theme_stylebox_override("panel", sb)
		_badge.add_child(panel)
		_badge_label = Label.new()
		_badge_label.add_theme_font_size_override("font_size", 18)
		_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		panel.add_child(_badge_label)
	_live = live
	_badge.visible = true
	_refresh_badge()


## Compute the badge text/colour from the link + control state. With CONTROL_ENABLED off, _ctl_phase
## is permanently "observing", so this collapses to the exact Phase-1 two-state badge.
func _refresh_badge() -> void:
	if _badge_label == null:
		return
	if _flashing:
		_badge_label.text = "— YOU HAVE CONTROL"
		_badge_label.modulate = Color(1.0, 0.9, 0.3)       # bright flash on takeover (§6.4 step 4)
		return
	if not _live:
		_badge_label.text = "◌ REMOTE — dialing…"
		_badge_label.modulate = Color(1.0, 0.78, 0.24)     # amber = connecting, not yet live
		return
	var bright := Color(1.0, 0.18, 0.18)                   # brighter red = the agent can DRIVE
	var red := Color(1.0, 0.32, 0.32)                      # red = observing / control ended
	match _ctl_phase:
		"granted":
			if _ctl_unattended:
				_badge_label.text = "● UNATTENDED REMOTE CONTROL — press Esc to revoke"
			else:
				_badge_label.text = "● REMOTE CONTROL ACTIVE — any input takes over"
			_badge_label.modulate = bright
		"driving":
			var tail := "press Esc to revoke" if _ctl_unattended else "any input takes over"
			_badge_label.text = "● REMOTE DRIVING — %s ▸ %s" % [_driving_text, tail]
			_badge_label.modulate = bright
		"suspended":
			_badge_label.text = "● REMOTE CONTROL SUSPENDED — resuming when idle"
			_badge_label.modulate = Color(1.0, 0.6, 0.2)   # amber-red = paused after a takeover
		_:  # observing | override | revoked → back to the Phase-1 observe surface
			_badge_label.text = "● REMOTE ACTIVE — %s" % RemoteBridge.PHASE_STATUS
			_badge_label.modulate = red


func _hide_badge() -> void:
	if _badge != null:
		_badge.visible = false


# ══════════════════════════════════════════════════════════════════════════════════════════════════
# P2 CONTROL UI — consent modal (§6.1 / D5), unattended opt-in (§6.6), badge phases (§6.2), override
# flash (§6.4). All reached ONLY when RemoteBridge.CONTROL_ENABLED is true (wired in _activate).
# ══════════════════════════════════════════════════════════════════════════════════════════════════

## Badge driver from the bridge. Flashes "YOU HAVE CONTROL" on a takeover (override/suspend).
func _on_control_phase(phase: String, info: Dictionary) -> void:
	_ctl_phase = phase
	_ctl_unattended = bool(info.get("unattended", _ctl_unattended))
	_driving_text = str(info.get("text", _driving_text)) if phase == "driving" else ""
	if phase == "override" or phase == "suspended":
		_flash_you_have_control()
	if is_instance_valid(_badge):
		_refresh_badge()


func _flash_you_have_control() -> void:
	_flashing = true
	_refresh_badge()
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		_flashing = false
		if is_instance_valid(_badge):
			_refresh_badge())


## The relay offered control. If the bridge already re-armed from a stored unattended grant it never
## emits this; so reaching here always means a HUMAN CLICK is required — show the consent modal.
func _on_control_offer_ui(seq: String) -> void:
	_pending_offer_seq = seq
	if _consent != null:
		return
	_open_consent_modal(false)


# ── Consent modals (session + louder unattended). Red-bordered, capability-enumerating (D5). ────────
func _open_consent_modal(unattended: bool) -> void:
	_close_consent()
	# Release the mouse + freeze the player so the buttons are clickable without driving the camera —
	# the exact pattern the token prompt uses.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(player):
		player.set("frozen", true)

	_consent = CanvasLayer.new()
	_consent.layer = 220                # above the badge (200) and the token prompt (210)
	add_child(_consent)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_consent.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.03, 0.03, 0.98)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(20.0)
	sb.border_color = Color(1.0, 0.2, 0.2)
	sb.set_border_width_all(4 if unattended else 3)         # louder border for the unattended opt-in
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.custom_minimum_size = Vector2(560, 0)
	panel.add_child(vb)

	var title := Label.new()
	title.add_theme_font_size_override("font_size", 24 if unattended else 22)
	title.modulate = Color(1.0, 0.55, 0.55)
	vb.add_child(title)

	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(560, 0)
	body.add_theme_font_size_override("font_size", 15)
	vb.add_child(body)

	if unattended:
		title.text = "⚠  ALLOW UNATTENDED REMOTE CONTROL"
		body.text = "Allow MISSION CONTROL to DRIVE and RELOAD this game UNATTENDED — persisting " \
			+ "ACROSS PAGE RELOADS, until you revoke. With no further prompts it can:\n" \
			+ "  • move, look, jump, and toggle fly\n" \
			+ "  • MINE / BREAK blocks\n" \
			+ "  • PLACE blocks\n" \
			+ "  • manage your INVENTORY\n" \
			+ "  • RELOAD the browser tab to pick up new builds\n\n" \
			+ "It can NOT read anything outside the game. Press Esc anytime to revoke and CLEAR this " \
			+ "permission. This is a standing grant — enable it only if you are walking away."
	else:
		title.text = "●  MISSION CONTROL requests DRIVE access"
		body.text = "The remote agent will be able to, UNTIL YOU REVOKE:\n" \
			+ "  • move, look, jump, and toggle fly\n" \
			+ "  • MINE / BREAK blocks\n" \
			+ "  • PLACE blocks\n" \
			+ "  • manage your INVENTORY\n\n" \
			+ "It can NOT read anything outside the game, and it LOSES control the instant you press " \
			+ "any key or move the mouse. Press Esc anytime to revoke."
	vb.add_child(HSeparator.new())

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)

	var deny := Button.new()
	deny.text = "Deny" if not unattended else "Cancel"
	deny.pressed.connect(_deny_consent)
	row.add_child(deny)

	if unattended:
		var enable := Button.new()
		enable.text = "Enable UNATTENDED"
		enable.pressed.connect(_allow_unattended)
		row.add_child(enable)                              # deliberately NOT the default focus (§6.6)
		deny.grab_focus()
	else:
		var allow_un := Button.new()
		allow_un.text = "Allow UNATTENDED…"
		allow_un.pressed.connect(func() -> void: _open_consent_modal(true))
		row.add_child(allow_un)
		var allow := Button.new()
		allow.text = "Allow — until I revoke"
		allow.pressed.connect(_allow_session)
		row.add_child(allow)


func _allow_session() -> void:
	var gid := _gen_id()
	_close_consent()
	if is_instance_valid(_bridge):
		_bridge.grant_control(gid, false)


func _allow_unattended() -> void:
	var uid := _gen_id()
	_store_unattended(uid)                                  # opaque id in localStorage, keyed to the token (§6.6)
	_close_consent()
	if is_instance_valid(_bridge):
		_bridge.grant_control(uid, true)


func _deny_consent() -> void:
	_close_consent()
	if is_instance_valid(_bridge):
		_bridge.deny_control()


func _close_consent() -> void:
	if _consent != null:
		_consent.queue_free()
		_consent = null
	# Restore play (mirror the token prompt): recapture the mouse + unfreeze.
	if is_instance_valid(player):
		player.set("frozen", false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ── Persistent UNATTENDED grant in localStorage (§6.6). We store an OPAQUE per-grant id, NEVER the
# observe secret; the storage KEY is a non-reversible hash of the token so the secret isn't there
# either. On web this is real localStorage via JavaScriptBridge; native/dev uses an in-memory field. ──
func _ls_key(token: String) -> String:
	return "vxv_unattended_%d" % hash(token)


func _js_str(s: String) -> String:
	return JSON.stringify(s)                                # safe JS string literal (no injection)


func _store_unattended(uid: String) -> void:
	if not OS.has_feature("web"):
		_native_unattended = uid
		return
	JavaScriptBridge.eval("localStorage.setItem(%s,%s)" % [_js_str(_ls_key(_active_token)), _js_str(uid)], true)


func _load_unattended(token: String) -> String:
	if not OS.has_feature("web"):
		return _native_unattended
	var v = JavaScriptBridge.eval("localStorage.getItem(%s)" % _js_str(_ls_key(token)), true)
	return "" if v == null else str(v)


func _clear_unattended() -> void:
	_native_unattended = ""
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("localStorage.removeItem(%s)" % _js_str(_ls_key(_active_token)), true)


func _gen_id() -> String:
	var s := ""
	for i in 8:
		s += "%02x" % (randi() & 0xFF)
	return s


# ── On-canvas token prompt (token ONLY — never a URL) ─────────────────────────────────────────────
func _open_prompt() -> void:
	if _prompt != null:
		return
	# Release the mouse + freeze the player so the field is usable without moving/looking.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(player):
		player.set("frozen", true)

	_prompt = CanvasLayer.new()
	_prompt.layer = 210
	add_child(_prompt)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_prompt.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.96)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(16.0)
	sb.border_color = Color(1.0, 0.32, 0.32)
	sb.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "Enable REMOTE OBSERVE"
	title.add_theme_font_size_override("font_size", 20)
	vb.add_child(title)

	var hint := Label.new()
	hint.text = "Enter the access token to let the agent OBSERVE this session.\nStreams telemetry + periodic frames of the game canvas to our host only."
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(0.8, 0.82, 0.88)
	vb.add_child(hint)

	_prompt_field = LineEdit.new()
	_prompt_field.placeholder_text = "access token"
	_prompt_field.secret = true
	_prompt_field.custom_minimum_size = Vector2(320, 0)
	_prompt_field.text_submitted.connect(func(_t): _submit_prompt())
	vb.add_child(_prompt_field)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_close_prompt)
	row.add_child(cancel)
	var connect_btn := Button.new()
	connect_btn.text = "Connect"
	connect_btn.pressed.connect(_submit_prompt)
	row.add_child(connect_btn)

	_prompt_field.grab_focus()


func _submit_prompt() -> void:
	var tok := ""
	if _prompt_field != null:
		tok = _prompt_field.text.strip_edges()
	if tok == "":
		return                        # empty → dial nothing; leave the prompt up
	_close_prompt()
	_activate(tok)


func _close_prompt() -> void:
	if _prompt != null:
		_prompt.queue_free()
		_prompt = null
		_prompt_field = null
	# Restore play: recapture the mouse + unfreeze (only if we aren't mid-shader-prewarm freeze).
	if is_instance_valid(player):
		player.set("frozen", false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
