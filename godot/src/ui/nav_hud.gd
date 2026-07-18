class_name NavHUD
extends CanvasLayer
## SN-FIX #1 (flag SN_HUD_NAV, 2026-07-18 live pilot request): a small always-on readout of the player's
## current lattice POSITION, radial ALTITUDE, and NAV MODE — near the temperature/hint HUDs. Additive and
## read-only (mirrors ThermometerHUD): it computes nothing, it reads player.position / player.radial_altitude()
## / player.nav_mode_name(). Built by main.gd ONLY under SN_HUD_NAV; with the flag off no NavHUD node exists,
## so the shipped HUD stack is byte-identical.

var player: Player           # injected by Main

var _pos_label: Label
var _mode_label: Label

func _ready() -> void:
	var panel := PanelContainer.new()
	# SN-FIX (2026-07-18 live-pilot HUD overlap): BOTTOM-RIGHT corner, grown up-left from that corner. This is
	# the one free quadrant — the always-on PerfHUD owns TOP-RIGHT (perf_hud.gd: anchor_right=1, offset_top=16),
	# the thermometer owns TOP-LEFT (16,16), and the hotbar owns the BOTTOM-CENTRE band (bottom-wide, ~68 px tall).
	# offset_bottom = −84 lifts the panel's bottom edge 84 px off the screen bottom → 16 px clear ABOVE the hotbar
	# band's top (−68) AND far right of the centred hotbar slots ⇒ no overlap with any HUD rect. Mirrors PerfHUD's
	# anchored-corner + GROW_DIRECTION_BEGIN idiom (auto-sizes to content, grows toward the interior).
	panel.anchor_left = 1.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_right = -16.0
	panel.offset_bottom = -84.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.modulate = Color(1, 1, 1, 0.92)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "NAV"
	title.add_theme_font_size_override("font_size", 12)
	title.modulate = Color(0.75, 0.82, 0.9)
	vbox.add_child(title)

	_pos_label = Label.new()
	_pos_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_pos_label)

	_mode_label = Label.new()
	_mode_label.add_theme_font_size_override("font_size", 16)
	_mode_label.modulate = Color(0.85, 0.9, 0.8)
	vbox.add_child(_mode_label)

func _process(_delta: float) -> void:
	if player == null:
		return
	_pos_label.text = format_pos(player.position, player.radial_altitude())
	_mode_label.text = format_mode(player.nav_mode_name())

## Pure formatters (gate-testable, no node state). Position rounded to whole blocks + radial altitude.
static func format_pos(pos: Vector3, alt: float) -> String:
	return "pos %d, %d, %d\nalt %d" % [roundi(pos.x), roundi(pos.y), roundi(pos.z), roundi(alt)]

static func format_mode(mode_name: String) -> String:
	return "mode: %s" % mode_name.to_upper()
