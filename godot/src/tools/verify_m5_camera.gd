extends SceneTree
## COSMOS R2.2 regression gate — the DESIGN-Z camera must never fly to the wedge sentinel (blank screen).
## The 2026-07-09 blank-screen bug: the player spawned in the double-out corner WEDGE (window x<0 AND z<0),
## place_true() returned _WEDGE (1e18), alignment_transform folded it into F.origin, and F⁻¹·window_cam put
## the DISPLAYED camera at ~1e18 → near + far (both baked in the epoch frame) left the frustum → HUD only.
## Two guards, both asserted here:
##   (1) main._find_flat skips wedge columns  → is_wedge_column keeps the spawn on a real face.
##   (2) m5_epoch_camera bails to window_cam when place_true(player) is _WEDGE → no 1e18 camera even if the
##       player walks up to the 3-face vertex before the M5c seal lands.
## Pure topology/frame math (no module) — runs under curved (FLAT_WORLD=false); loud-skip in FLAT.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TP := preload("res://src/cosmos/cosmos_true_place.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _init() -> void:
	print("=== verify_m5_camera (R2.2 wedge-blank guard) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — M5_REAL camera is curved-only. NOT A PASS."); print("==== VERIFY: SKIPPED ===="); quit(2); return

	var chart: CHART = CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0)

	# T1 — the double-out corner quadrant (x<0 AND z<0) IS a wedge (no sphere position).
	_ok(TP.is_wedge(chart, -15.5, -15.5), "T1 (-15.5,-15.5) double-out quadrant is a WEDGE")
	_ok(TP.is_wedge(chart, -3.0, -7.0), "T1b (-3,-7) double-out is a WEDGE")

	# T2 — a single-out / home column is NOT a wedge (the fixed spawn lands here).
	_ok(not TP.is_wedge(chart, 0.5, -15.5), "T2 (0.5,-15.5) single-out (fixed spawn) is NOT a wedge")
	_ok(not TP.is_wedge(chart, 8.0, 8.0), "T2b (8,8) home column is NOT a wedge")

	# T3 — place_true at a wedge column returns the _WEDGE sentinel (what the m5_epoch_camera guard checks).
	var anchor := Vector3(8.5, 4.0, 8.5)                 # a valid, non-wedge epoch anchor near the corner
	var frame := TP.bake_frame(chart, anchor)
	var wedge_pos := Vector3(-15.5, 5.0, -15.5)
	_ok(TP.place_true(chart, wedge_pos, frame) == TP._WEDGE, "T3 place_true(wedge player) == _WEDGE sentinel")

	# T4 — the guarded camera: window_cam fallback at the wedge (FINITE), and a finite camera at a valid pos.
	var window_cam := Transform3D(Basis(Vector3(1, 0, 0), -0.12), wedge_pos + Vector3(0, 1.7, 0))
	_ok(_guarded_camera(chart, frame, wedge_pos, window_cam) == window_cam,
		"T4 wedge player -> camera falls back to window_cam (not 1e18)")

	var valid_pos := Vector3(8.5, 4.0, 8.5)
	var wcam2 := Transform3D(Basis(Vector3(1, 0, 0), -0.12), valid_pos + Vector3(0, 1.7, 0))
	var cam := _guarded_camera(chart, frame, valid_pos, wcam2)
	var finite := cam.origin.length() < 1.0e6 and is_finite(cam.origin.x) and is_finite(cam.origin.y) and is_finite(cam.origin.z)
	_ok(finite, "T5 valid player -> finite camera (origin=%s)" % str(cam.origin))
	# at the anchor itself the camera sits ~eye-height above the epoch origin
	_ok(cam.origin.length() < 50.0, "T5b camera near the epoch origin (|o|=%.2f)" % cam.origin.length())

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Mirror of WorldManager.m5_epoch_camera's guard chain (the class under test forwards to these same fns).
func _guarded_camera(chart, frame: Dictionary, player_pos: Vector3, window_cam: Transform3D) -> Transform3D:
	var pe := TP.place_true(chart, player_pos, frame)
	if pe == TP._WEDGE:
		return window_cam
	var f := TP.alignment_transform(chart, frame, player_pos)
	if absf(f.basis.determinant()) < 1.0e-6:
		return window_cam
	return f.affine_inverse() * window_cam
