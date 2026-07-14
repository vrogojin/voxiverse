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
	_bridge = RemoteBridge.new()
	_bridge.name = "RemoteBridge"
	_bridge.configure({"token": token, "url": RemoteBridge.resolve_url()})
	_bridge.world = world
	_bridge.player = player
	_bridge.link_state.connect(_on_link_state)
	add_child(_bridge)
	_show_badge(false)                # "dialing…" until the socket actually opens
	print("[REMOTE] activation requested (token-gated, fixed relay)")


func _deactivate() -> void:
	if is_instance_valid(_bridge):
		_bridge.queue_free()          # _exit_tree closes the socket + emits link_state(false)
	_bridge = null
	_hide_badge()
	print("[REMOTE] deactivated by user")


func _on_link_state(open: bool) -> void:
	# Keep the badge honest: reflect the REAL link, not just the intent to dial.
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
	_badge.visible = true
	if live:
		_badge_label.text = "● REMOTE ACTIVE — %s" % RemoteBridge.PHASE_STATUS
		_badge_label.modulate = Color(1.0, 0.32, 0.32)     # red = someone is watching
	else:
		_badge_label.text = "◌ REMOTE — dialing…"
		_badge_label.modulate = Color(1.0, 0.78, 0.24)     # amber = connecting, not yet live


func _hide_badge() -> void:
	if _badge != null:
		_badge.visible = false


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
