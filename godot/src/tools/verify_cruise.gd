extends SceneTree
## DEV-FLIGHT CRUISE MODE headless gate — G-CRUISE.
##
## Falsifies the PURE, flag-independent parts of the Elite-Dangerous-style dev supercruise (CubeSphere.CRUISE_MODE):
##   (A) SPEED LAW  — CubeSphere.cruise_speed(alt): == MIN at/below alt 0, doubles per CRUISE_SPEED_BAND, monotone
##                    increasing, clamped to [MIN, MAX], MAX sized so the Earth→Moon gap crosses in ~1–3 min.
##   (B) ENGAGE     — CubeSphere.cruise_engaged(dev_fly, in_space, c_held) is TRUE only with all three, FALSE if any
##                    input is false (so C on the surface / when not dev-flying / not-in-space is a no-op).
##   (C) LOOKDIR    — CubeSphere.cruise_look_dir(use_new, cam_basis, lattice_basis, pitch) (FP_CRUISE_LOOKDIR):
##                    OFF reproduces the shipped lattice-yaw·pitch composition; ON picks the true camera forward
##                    (cam_basis · −Z) REGARDLESS of lattice_basis/pitch — the ATT_SPACE bug fix. Always unit length.
## All three kernels are flag-INDEPENDENT statics (CRUISE_MODE/FP_CRUISE_LOOKDIR gate only the player's poll), so
## this runs green on any build.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_cruise.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const CS := preload("res://src/cosmos/cube_sphere.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _rel(a: float, b: float) -> float:
	var d := absf(b)
	if d < 1.0e-300:
		return absf(a - b)
	return absf(a - b) / d

func _initialize() -> void:
	print("=== verify_cruise (DEV-FLIGHT CRUISE: G-CRUISE — pure speed law + engage predicate + lookdir) ===")
	_gate_speed_law()
	_gate_engage()
	_gate_lookdir()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- (A) the exponential speed law ----------
func _gate_speed_law() -> void:
	print("  --- (A) SPEED LAW: floor at MIN, double per BAND, cap at MAX, monotone ---")
	var mn := CS.CRUISE_SPEED_MIN
	var mx := CS.CRUISE_SPEED_MAX
	var band := CS.CRUISE_SPEED_BAND
	# Floor: at/below alt 0 the speed is exactly MIN (slow but non-zero just above the atmosphere).
	_ok(_rel(CS.cruise_speed(0.0), mn) < 1.0e-9, "(A) speed == MIN at alt 0 (got %.3f, MIN %.3f)" % [CS.cruise_speed(0.0), mn])
	_ok(_rel(CS.cruise_speed(-5000.0), mn) < 1.0e-9, "(A) speed clamps to MIN below alt 0")
	# Doubling: one BAND of altitude doubles the speed (while still under the cap).
	_ok(_rel(CS.cruise_speed(band), 2.0 * mn) < 1.0e-9, "(A) speed doubles over one BAND (%.3f -> %.3f)" % [mn, CS.cruise_speed(band)])
	_ok(_rel(CS.cruise_speed(2.0 * band), 4.0 * mn) < 1.0e-9, "(A) speed quadruples over two BANDs")
	# Cap: far out the speed saturates at MAX and never exceeds it.
	_ok(_rel(CS.cruise_speed(1.0e9), mx) < 1.0e-9, "(A) speed clamps to MAX far away")
	_ok(CS.cruise_speed(1.0e9) <= mx + 1.0e-6, "(A) speed never exceeds MAX")
	# Monotone non-decreasing across the whole domain (floor -> exp ramp -> cap).
	var mono := true
	var prev := CS.cruise_speed(-1000.0)
	var a := 0.0
	while a <= 60000.0:
		var s := CS.cruise_speed(a)
		if s < prev - 1.0e-6:
			mono = false
			break
		prev = s
		a += 250.0
	_ok(mono, "(A) speed is monotone non-decreasing in altitude")
	# Sanity: MAX < the naive 200000 placeholder, and the Earth->Moon crossing at cap is in the 1..3 min window.
	var earth_moon := 384400.0
	var trip_s := earth_moon / mx
	_ok(mx < 200000.0, "(A) MAX (%.0f) is scale-tuned, not the naive 200000" % mx)
	_ok(trip_s >= 60.0 and trip_s <= 180.0, "(A) Earth->Moon at cap is ~1-3 min (got %.0f s)" % trip_s)

# ---------- (B) the engage predicate ----------
func _gate_engage() -> void:
	print("  --- (B) ENGAGE: dev-fly AND in-space AND C held; false if any input false ---")
	_ok(CS.cruise_engaged(true, true, true), "(B) engaged when dev-fly + in-space + C all true")
	_ok(not CS.cruise_engaged(false, true, true), "(B) NOT engaged when not dev-flying")
	_ok(not CS.cruise_engaged(true, false, true), "(B) NOT engaged when not in space (on surface / in atmosphere)")
	_ok(not CS.cruise_engaged(true, true, false), "(B) NOT engaged when C is not held")
	_ok(not CS.cruise_engaged(false, false, false), "(B) NOT engaged when nothing is true")

# ---------- (C) FP_CRUISE_LOOKDIR: pure look-direction selector ----------
func _gate_lookdir() -> void:
	print("  --- (C) LOOKDIR: OFF = shipped lattice·pitch (ignores camera); ON = true camera forward (ignores lattice/pitch) ---")
	var lattice := Basis(Vector3(0, 1, 0), deg_to_rad(40.0))                                    # arbitrary yawed lattice frame
	var pitch := deg_to_rad(-15.0)
	var cam := Basis(Vector3(1, 0, 0), deg_to_rad(70.0)).rotated(Vector3(0, 1, 0), deg_to_rad(160.0))  # a very different look

	# OFF: exactly the shipped lattice·pitch composition, and IGNORES cam_basis entirely.
	var off_expected := (lattice * (Basis(Vector3(1, 0, 0), pitch) * Vector3(0.0, 0.0, -1.0))).normalized()
	var off_got := CS.cruise_look_dir(false, cam, lattice, pitch)
	_ok(off_got.distance_to(off_expected) < 1.0e-6, "(C) OFF reproduces the shipped lattice·pitch composition")
	var off_got_other_cam := CS.cruise_look_dir(false, Basis.IDENTITY, lattice, pitch)
	_ok(off_got.distance_to(off_got_other_cam) < 1.0e-6, "(C) OFF ignores cam_basis entirely")

	# ON: exactly cam_basis · −Z, and IGNORES lattice_basis/pitch entirely.
	var on_expected := (cam * Vector3(0.0, 0.0, -1.0)).normalized()
	var on_got := CS.cruise_look_dir(true, cam, lattice, pitch)
	_ok(on_got.distance_to(on_expected) < 1.0e-6, "(C) ON reproduces the true camera forward")
	var on_got_other_lattice := CS.cruise_look_dir(true, cam, Basis.IDENTITY, 0.0)
	_ok(on_got.distance_to(on_got_other_lattice) < 1.0e-6, "(C) ON ignores lattice_basis/pitch entirely")

	# Falsifier: with a camera aimed away from the lattice frame, ON and OFF fly DIFFERENT directions — proves the
	# fix actually changes the flown direction (not a vacuous no-op in ATT_SPACE, the bug's exact scenario).
	_ok(on_got.distance_to(off_got) > 0.5,
		"(C) ON and OFF diverge for a camera aimed away from the lattice frame (Δ=%.3f)" % on_got.distance_to(off_got))

	# Both are always unit length.
	_ok(absf(off_got.length() - 1.0) < 1.0e-6, "(C) OFF result is unit length")
	_ok(absf(on_got.length() - 1.0) < 1.0e-6, "(C) ON result is unit length")
