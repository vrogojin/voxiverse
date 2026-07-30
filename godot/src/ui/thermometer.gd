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
	# VACUUM-AWARE HUD (FP_HUD_VACUUM_TEMP, docs cube_sphere.gd): clamp to absolute zero, and blank
	# ("--") the air in vacuum / the ground when in space off any surface. Flag OFF ⇒ the exact shipped
	# strings (byte-identical). The predicates reuse the SAME accessors RemoteBridge streams as `alt` /
	# `on_ground` (Player.radial_altitude / Player.is_on_surface), so the HUD can never disagree with them.
	if CubeSphere.FP_HUD_VACUUM_TEMP:
		var alt := player.radial_altitude()
		var on_surf: bool = player.is_on_surface()
		_air_label.text = hud_air_text(alt, air)
		_ground_label.text = hud_ground_text(alt, on_surf, ground)
	else:
		_air_label.text = "Air temp:     %5.1f °C" % air
		_ground_label.text = "Ground temp:  %5.1f °C" % ground

	var aimed: Dictionary = player.get_aimed()
	var aim_txt := "aim: (none)"
	if aimed.get("hit", false):
		var v: Vector3i = aimed["voxel"]
		var vt := env.temperature(Vector3(v.x + 0.5, v.y + 0.5, v.z + 0.5))
		# VACUUM-AWARE HUD: the aimed-voxel temp is never "--", but it IS clamped to absolute zero when the flag is on.
		var vt_show := clamp_temp(vt) if CubeSphere.FP_HUD_VACUUM_TEMP else vt
		# Composed cell query -> real material name for whatever block is aimed
		# (grass/dirt/stone/wood/leaf/placed), via the authoritative BlockCatalog.
		var id: int = world.block_id_at(v)
		var mat_name := BlockCatalog.name_of(id)
		aim_txt = "aim: %s %s  %.1f °C" % [mat_name, str(v), vt_show]
	var mode := "FLY" if player.flying else "WALK"
	_info_label.text = "%s | %s\nWASD move  Shift run  Space jump  F fly  1-9/wheel slot  LMB break  RMB place  Esc free" % [mode, aim_txt]


# ── VACUUM-AWARE HUD helpers (FP_HUD_VACUUM_TEMP) ─────────────────────────────────────────────────
# Pure static functions so the gate (verify_hud_temp.gd) can exercise the display logic directly,
# with no live player/SceneTree. Used by _process above when the flag is on.

## Absolute-zero floor: no displayed temperature may read below −273.0 °C.
static func clamp_temp(t: float) -> float:
	return maxf(t, -273.0)

## Air-temp line. In vacuum (radial altitude above the atmosphere ceiling ATMO_TOP ⇒ no air) the number
## is replaced by "--" in the SAME 5-wide field the "%5.1f" number used; otherwise the real clamped value.
static func hud_air_text(alt: float, temp: float) -> String:
	if alt > CubeSphere.ATMO_TOP:
		return "Air temp:     %5s °C" % "--"
	return "Air temp:     %5.1f °C" % clamp_temp(temp)

## Ground-temp line. Blank ("--") only when in space (alt > ATMO_TOP) AND not standing on any surface;
## on a body surface (Moon/Earth) it shows the real clamped value even above the ceiling.
static func hud_ground_text(alt: float, on_surface: bool, temp: float) -> String:
	if alt > CubeSphere.ATMO_TOP and not on_surface:
		return "Ground temp:  %5s °C" % "--"
	return "Ground temp:  %5.1f °C" % clamp_temp(temp)
