class_name ThermometerHUD
extends CanvasLayer
## Always-on thermometer (DESIGN §1). Shows Air temp (the air voxel at the
## player's head) and Ground temp (the voxel directly under the player), both in
## Celsius, read THROUGH PerVoxelEnvironment — no temperatures are computed here,
## so any future field/material change is reflected automatically.

var world: WorldManager      # injected by Main
var player: Player           # injected by Main

var _air_label: Label
var _ground_label: Label
var _info_label: Label

func _ready() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	panel.modulate = Color(1, 1, 1, 0.92)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "THERMOMETER"
	title.add_theme_font_size_override("font_size", 12)
	title.modulate = Color(0.75, 0.85, 0.75)
	vbox.add_child(title)

	_air_label = _make_value_label(vbox)
	_ground_label = _make_value_label(vbox)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 11)
	_info_label.modulate = Color(0.8, 0.8, 0.8)
	vbox.add_child(_info_label)

func _make_value_label(parent: Node) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 18)
	parent.add_child(l)
	return l

func _process(_delta: float) -> void:
	if world == null or player == null or world.environment == null:
		return
	var env := world.environment
	var air := env.temperature(player.head_position())
	var ground := env.temperature(player.ground_probe_position())
	_air_label.text = "Air temp:     %5.1f °C" % air
	_ground_label.text = "Ground temp:  %5.1f °C" % ground

	var aimed: Dictionary = player.get_aimed()
	var aim_txt := "aim: (none)"
	if aimed.get("hit", false):
		var v: Vector3i = aimed["voxel"]
		var vt := env.temperature(Vector3(v.x + 0.5, v.y + 0.5, v.z + 0.5))
		aim_txt = "aim: grass %s  %.1f °C" % [str(v), vt]
	var mode := "FLY" if player.flying else "WALK"
	_info_label.text = "%s | %s\nWASD move  Shift run  Space jump  F fly  Esc free" % [mode, aim_txt]
