extends SceneTree
## COSMOS-PERF FALL-COLLAPSE FIX C gate — G-SNOW-AIRBORNE (flag CubeSphere.FP_SNOW_SKIP_AIRBORNE).
## The live fall-from-orbit telemetry shows snow_ms spiking to ~71 ms: SnowfallSystem.process runs a main-thread
## fixed-step batch every frame around the player's ground column, which is pure wasted work while the player is a
## HIGH FLYER (falling from orbit, hundreds of blocks up — no walkable ground snow under the camera). FIX C skips the
## step above OFFSURFACE_Y (the same cheap lattice-y test the pool off-surface freeze uses). This gate drives the pure
## predicate WorldManager.snow_skip_airborne(alt_y) — no WorldManager instance — and is FLAG-AGNOSTIC: it asserts the
## skip decision EQUALS the compiled flag above the ceiling and is ALWAYS false on/below it (snow keeps running on the
## ground) and strictly at the boundary. Flag-off byte-identity (the snow step runs exactly as today) is the FLAT
## verify_feature (6042/0), run separately.
##
## RUN (flag-agnostic — passes with FP_SNOW_SKIP_AIRBORNE either way):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_snow_airborne.gd
## Exits 0 all-pass / 1 on any failure.

const WM := preload("res://src/world/world_manager.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_snow_airborne (COSMOS-PERF FALL-COLLAPSE FIX C: G-SNOW-AIRBORNE) ===")
	var on := CubeSphere.FP_SNOW_SKIP_AIRBORNE
	var ceil_y := CubeSphere.OFFSURFACE_Y
	print("  FP_SNOW_SKIP_AIRBORNE = %s, OFFSURFACE_Y = %.0f" % [str(on), ceil_y])
	# Airborne (well above the ceiling): the skip decision EQUALS the flag (skips only when the flag is on).
	_ok(WM.snow_skip_airborne(ceil_y + 1000.0) == on, "airborne (y = ceiling+1000) → skip == flag (%s)" % str(on))
	_ok(WM.snow_skip_airborne(ceil_y + 1.0) == on, "just above the ceiling → skip == flag (%s)" % str(on))
	# On/below the surface ceiling: NEVER skip regardless of the flag — snow keeps evolving on the walkable ground.
	_ok(WM.snow_skip_airborne(10.0) == false, "on the surface (y = 10) → NEVER skip (snow runs on the ground)")
	_ok(WM.snow_skip_airborne(0.0) == false, "at the ground (y = 0) → NEVER skip")
	_ok(WM.snow_skip_airborne(ceil_y) == false, "exactly at the ceiling (y == OFFSURFACE_Y) → NOT skipped (strict >)")
	_ok(WM.snow_skip_airborne(-50.0) == false, "below the plane (y = −50) → NEVER skip")
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
