extends SceneTree
## COSMOS HUD gate (FP_HUD_VACUUM_TEMP, cube_sphere.gd). Proves the VACUUM-AWARE thermometer DISPLAY LOGIC
## end-to-end WITHOUT a live player/world. All the decision logic lives in ThermometerHUD's PURE STATIC
## helpers (clamp_temp / hud_air_text / hud_ground_text), so this gate drives them DIRECTLY and is
## FLAG-INDEPENDENT: the helpers always compute the vacuum-aware form; the FP_HUD_VACUUM_TEMP flag only
## decides whether _process() COMPOSES them in-game (the flag-off byte-identity of the shipped "%5.1f °C"
## strings is proven separately by the full FLAT gate verify_feature.gd, 6042/0).
##
## Gates:
##   G-HUD-CLAMP : absolute-zero floor — clamp_temp(−541) == −273, clamp_temp(18.4) unchanged, boundary at −273.
##   G-HUD-AIR   : air "--" iff radial altitude > ATMO_TOP; a real clamped number at/below the ceiling.
##   G-HUD-GROUND: ground "--" iff (in space) AND (not on a surface); real number on a surface or below the ceiling.
##   G-HUD-FMT   : the "--" strings keep the label prefix + " °C" suffix and the 5-wide field the number used.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_hud_temp.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const HUD := preload("res://src/ui/thermometer.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_hud_temp (COSMOS HUD: G-HUD-CLAMP/AIR/GROUND/FMT) ===")
	print("  FP_HUD_VACUUM_TEMP=%s (gate is flag-independent; display logic is pure static)" % str(CubeSphere.FP_HUD_VACUUM_TEMP))
	print("  ATMO_TOP=%.1f" % CubeSphere.ATMO_TOP)
	_gate_clamp()
	_gate_air()
	_gate_ground()
	_gate_fmt()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ G-HUD-CLAMP
func _gate_clamp() -> void:
	print("  --- G-HUD-CLAMP: absolute-zero floor (≥ −273.0 °C) ---")
	_ok(HUD.clamp_temp(-541.0) == -273.0, "clamp_temp(−541) == −273 (physically-impossible lapse floored)")
	_ok(HUD.clamp_temp(18.4) == 18.4, "clamp_temp(18.4) unchanged (above the floor)")
	_ok(HUD.clamp_temp(-273.0) == -273.0, "clamp_temp(−273) == −273 (boundary)")
	_ok(HUD.clamp_temp(-272.9) == -272.9, "clamp_temp(−272.9) unchanged (just above floor)")
	_ok(HUD.clamp_temp(-1000.0) >= -273.0, "no value can ever read below −273")

# ------------------------------------------------------------------ G-HUD-AIR
func _gate_air() -> void:
	print("  --- G-HUD-AIR: air '--' iff radial altitude > ATMO_TOP ---")
	var top: float = CubeSphere.ATMO_TOP
	# In vacuum (above the ceiling) → "--".
	var vac := HUD.hud_air_text(top + 1.0, -541.0)
	_ok(vac.contains("--"), "alt > ATMO_TOP ⇒ air shows '--' (no number)")
	_ok(not vac.contains("-541"), "vacuum air hides the raw sub-zero number")
	# At/below the ceiling → a real clamped number, never "--".
	var at := HUD.hud_air_text(top, -541.0)
	_ok(not at.contains("--"), "alt == ATMO_TOP ⇒ air shows a number (not vacuum)")
	_ok(at.contains("-273.0"), "at-ceiling air is CLAMPED to −273.0")
	var below := HUD.hud_air_text(10.0, 18.4)
	_ok(not below.contains("--"), "alt below ATMO_TOP ⇒ air shows a number")
	_ok(below.contains("18.4"), "below-ceiling air shows the real value")

# ------------------------------------------------------------------ G-HUD-GROUND
func _gate_ground() -> void:
	print("  --- G-HUD-GROUND: ground '--' iff in space AND not on a surface ---")
	var top: float = CubeSphere.ATMO_TOP
	# In space, off any surface → "--".
	var g_space := HUD.hud_ground_text(top + 100.0, false, -541.0)
	_ok(g_space.contains("--"), "in space + not on surface ⇒ ground '--'")
	# In space but STANDING on a surface (Moon/Earth) → real clamped number.
	var g_land := HUD.hud_ground_text(top + 100.0, true, -50.0)
	_ok(not g_land.contains("--"), "in space + on surface ⇒ ground shows a number (landed body)")
	_ok(g_land.contains("-50.0"), "landed ground shows the real (clamped) value")
	# Below the ceiling always shows a number regardless of on-surface state.
	var g_low := HUD.hud_ground_text(5.0, false, 12.3)
	_ok(not g_low.contains("--"), "below ATMO_TOP ⇒ ground shows a number even if not on surface")
	_ok(g_low.contains("12.3"), "below-ceiling ground shows the real value")
	# Clamp still applies on the surface path.
	var g_clamp := HUD.hud_ground_text(top + 100.0, true, -541.0)
	_ok(g_clamp.contains("-273.0"), "landed ground is CLAMPED to −273.0")

# ------------------------------------------------------------------ G-HUD-FMT
func _gate_fmt() -> void:
	print("  --- G-HUD-FMT: '--' keeps label prefix + ' °C' suffix + the 5-wide number field ---")
	var top: float = CubeSphere.ATMO_TOP
	var air := HUD.hud_air_text(top + 1.0, -541.0)
	var ground := HUD.hud_ground_text(top + 1.0, false, -541.0)
	# Prefix + suffix preserved.
	_ok(air.begins_with("Air temp:"), "vacuum air keeps 'Air temp:' label prefix")
	_ok(air.ends_with(" °C"), "vacuum air keeps ' °C' suffix")
	_ok(ground.begins_with("Ground temp:"), "space ground keeps 'Ground temp:' label prefix")
	_ok(ground.ends_with(" °C"), "space ground keeps ' °C' suffix")
	# The "--" is right-aligned in the SAME 5-wide field "%5.1f" used, so the whole line width is stable:
	# it must byte-match the number line's width (label + 5-char field + " °C").
	var air_num := HUD.hud_air_text(10.0, -8.4)          # e.g. "Air temp:      -8.4 °C"
	_ok(air.length() == air_num.length(), "vacuum air line width == number air line width (5-wide field)")
	var ground_num := HUD.hud_ground_text(10.0, false, -8.4)
	_ok(ground.length() == ground_num.length(), "space ground line width == number ground line width (5-wide field)")
	# Exact expected strings (the "%5s" % "--" right-align → three leading spaces before '--').
	_ok(air == "Air temp:        -- °C", "vacuum air exact: 'Air temp:        -- °C' (got: '%s')" % air)
	_ok(ground == "Ground temp:     -- °C", "space ground exact: 'Ground temp:     -- °C' (got: '%s')" % ground)
