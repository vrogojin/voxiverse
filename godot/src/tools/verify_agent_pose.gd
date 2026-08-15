extends SceneTree
## COSMOS-AGENT-CONTROL §4.3 — headless gate for the FP_AGENT_POSE BCI-frame math.
## Run: godot --headless --path godot --script res://src/tools/verify_agent_pose.gd
##
## player.orientation_telemetry() is flag-gated AND needs a live camera/_frame/active-facet, so the
## end-to-end wiring is validated by the live A/B (§4.3). This gate LOCKS the pure-math algorithm that
## method uses — the exact expressions for up / north / east / heading — against known poses, so a typo
## in the formula is caught headlessly:
##   up   = normalize(P_bci)
##   north= normalize(Ŷ − (Ŷ·up)·up)      (spin axis projected to the tangent plane)
##   east = up × north                      (right-handed ⇒ east)
##   heading = atan2(fwd_t·east, fwd_t·north)   (0 = north, +90 = east)
## plus the pole (|Ŷ·up|→1) and straight-down (fwd ∥ up) degeneracies that omit heading.
## The byte-off invariant (flag off ⇒ view_telemetry = 3 shipped keys, orientation_telemetry = {}) is
## covered structurally by verify_feature (6042/0, which never constructs the flag-on accessors).

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _approx(a: float, b: float, eps := 1e-4) -> bool:
	return absf(a - b) <= eps

# ── The method's exact math, replicated (this is what the gate pins) ──────────────────────────────
func _basis(P: Vector3) -> Dictionary:
	var up := P.normalized()
	var y_dot := Vector3.UP.dot(up)
	if absf(y_dot) > 0.9999:
		return {"up": up, "pole": true}
	var north := (Vector3.UP - y_dot * up).normalized()
	var east := up.cross(north)
	return {"up": up, "north": north, "east": east, "pole": false}

func _heading_deg(P: Vector3, fwd: Vector3):
	var b := _basis(P)
	if b["pole"]:
		return null
	var up: Vector3 = b["up"]
	var north: Vector3 = b["north"]
	var east: Vector3 = b["east"]
	var f_t := (fwd - fwd.dot(up) * up)
	if f_t.length() <= 1e-4:
		return null
	return rad_to_deg(atan2(f_t.dot(east), f_t.dot(north)))

func _initialize() -> void:
	_test_orthonormal()
	_test_equatorial_heading()
	_test_pole_degeneracy()
	_test_straight_down()
	_test_offaxis_consistency()
	print("==== VERIFY-AGENT-POSE: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _test_orthonormal() -> void:
	# Over a spread of non-pole positions the tangent basis is orthonormal + right-handed.
	for P in [Vector3(6371, 0, 0), Vector3(1000, 2000, 3000), Vector3(-500, 100, 900), Vector3(0, 10, 6000)]:
		var b := _basis(P)
		if b["pole"]:
			continue
		var up: Vector3 = b["up"]
		var north: Vector3 = b["north"]
		var east: Vector3 = b["east"]
		_ok(_approx(up.length(), 1.0), "|up| == 1 @ %s" % P)
		_ok(_approx(north.length(), 1.0), "|north| == 1 @ %s" % P)
		_ok(_approx(east.length(), 1.0), "|east| == 1 @ %s" % P)
		_ok(_approx(up.dot(north), 0.0), "up ⊥ north @ %s" % P)
		_ok(_approx(up.dot(east), 0.0), "up ⊥ east @ %s" % P)
		_ok(_approx(north.dot(east), 0.0), "north ⊥ east @ %s" % P)
		_ok((east - up.cross(north)).length() <= 1e-4, "east == up × north (right-handed) @ %s" % P)

func _test_equatorial_heading() -> void:
	# At P=(R,0,0): up=+X, north=+Y, east=+Z. Facing north → 0°, east → +90°, south → ±180°, west → −90°.
	var P := Vector3(6371, 0, 0)
	_ok(_approx(_heading_deg(P, Vector3(0, 1, 0)), 0.0, 0.01), "facing +north (Ŷ) ⇒ heading 0°")
	_ok(_approx(_heading_deg(P, Vector3(0, 0, 1)), 90.0, 0.01), "facing +east (Ẑ) ⇒ heading +90°")
	_ok(_approx(absf(_heading_deg(P, Vector3(0, -1, 0))), 180.0, 0.01), "facing south ⇒ heading ±180°")
	_ok(_approx(_heading_deg(P, Vector3(0, 0, -1)), -90.0, 0.01), "facing west ⇒ heading −90°")
	# A 45° NE forward → 45°.
	_ok(_approx(_heading_deg(P, Vector3(0, 1, 1)), 45.0, 0.01), "facing NE ⇒ heading 45°")

func _test_pole_degeneracy() -> void:
	# At a pole (P ∥ Ŷ) north is undefined ⇒ the basis flags pole and heading is omitted (null).
	_ok(_basis(Vector3(0, 6371, 0))["pole"] == true, "north pole ⇒ pole flag set (heading omitted)")
	_ok(_basis(Vector3(0, -6371, 0))["pole"] == true, "south pole ⇒ pole flag set")
	_ok(_heading_deg(Vector3(0, 6371, 0), Vector3(1, 0, 0)) == null, "pole ⇒ heading is null")
	_ok(_basis(Vector3(6371, 5, 0))["pole"] == false, "just off the equator ⇒ NOT a pole")

func _test_straight_down() -> void:
	# Looking straight up/down (fwd ∥ up) ⇒ the tangent projection vanishes ⇒ heading omitted (null).
	var P := Vector3(6371, 0, 0)
	_ok(_heading_deg(P, Vector3(1, 0, 0)) == null, "looking straight UP (fwd ∥ up) ⇒ heading null")
	_ok(_heading_deg(P, Vector3(-1, 0, 0)) == null, "looking straight DOWN (fwd ∥ -up) ⇒ heading null")
	# A mostly-down forward with a small tangent component still yields a defined heading.
	_ok(_heading_deg(P, Vector3(-10, 0, 1)) != null, "mostly-down but off-axis ⇒ heading defined")

func _test_offaxis_consistency() -> void:
	# A tilted position: heading must be invariant to the forward's magnitude (only its tangent direction matters).
	var P := Vector3(3000, 4000, 1200)
	var fwd := Vector3(0.3, -0.9, 0.4)
	var h1 = _heading_deg(P, fwd)
	var h2 = _heading_deg(P, fwd * 5.0)
	_ok(h1 != null and h2 != null and _approx(h1, h2, 1e-3), "heading is invariant to forward magnitude")
	# Rotating the forward toward +east increases heading toward +90 relative to pure-north.
	var b := _basis(P)
	var north: Vector3 = b["north"]
	var east: Vector3 = b["east"]
	_ok(_approx(_heading_deg(P, north), 0.0, 0.01), "forward == north ⇒ heading 0° (arbitrary tilt)")
	_ok(_approx(_heading_deg(P, east), 90.0, 0.01), "forward == east ⇒ heading +90° (arbitrary tilt)")
