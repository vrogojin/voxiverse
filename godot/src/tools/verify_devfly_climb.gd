extends SceneTree
## COSMOS DEV-FLY HANG gate — G-DEVFLY-CLIMB (flag CubeSphere.FP_SHELL_CLIMB_NO_CHURN).
##
## ROOT CAUSE (fix/voxiverse-devfly-hang): a straight powered dev-fly climb from the ground to ~150-210 blocks hard-
## hangs live (render freezes on the last frame while telemetry advances, then the main loop blocks — the Godot threaded-
## renderer command-queue backpressure signature ⇒ a RENDER-THREAD stall, which is why every --headless gate, on the
## dummy renderer, stays green). Every MAIN-THREAD path active during a PLANETARY dev-fly climb is bounded or gated off:
## the fly move is pure kinematic (player.gd _kinematic_look_fly / the lattice fly — no world scans); floor_under is gated
## by `flying` (_attitude_ground_contact returns false, player.gd:526); the GroundCollider is gated off with no debris;
## snow/pool/alt-regime/fall-hold do not trip below ATMO_TOP while climbing. So the stall is on the render thread.
##
## The one system uploading meshes to the render thread during the climb is the FAR RING. Below OFFSURFACE_Y the emitted
## cap is FLOORED to 90° (shell_set_camera_abs), and that floor BINDS for every θ_h < 90 − (RELIEF+SLACK) = 67° (every
## altitude below ~9900 blocks). So the climb grows θ_h = acos(R/d) but the EMITTED SET stays the identical 90° hemisphere
## — yet the shipped reactive trigger fires a full re-emit (rebuild + GL/ANGLE mesh upload) every |Δθ_h| > 5°. Those climb
## re-emits are pure CHURN (identical coverage) and the suspected render-thread-stall trigger. FP_SHELL_CLIMB_NO_CHURN
## suppresses a re-emit while floored + cap-cos-unchanged + no axis sweep (the set is provably identical); axis drift,
## floor/regime crossings, and any genuine cap change still re-emit (correctness — no limb holes).
##
## This gate drives the far-ring shell core (shell_set_camera_abs — the flag-independent driver the guard lives in) through
## a simulated vertical climb (FIXED absolute axis, growing distance, floored) and counts SCHEDULED re-emits (snapshot_count).
##   • FLAG OFF (byte-identical baseline): the climb schedules ≥ 2 re-emits (the churn is REAL).
##   • FLAG ON  (sed-toggle): the climb schedules 0 EXTRA re-emits past the first engage (churn bounded), while an axis
##     SWEEP and a floor CROSSING still each schedule a re-emit (correctness preserved).
##
## RUN — baseline (proves the churn; FACETED needed for R_BLOCKS/atlas warm):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_SHELL_CAMERA_SET := false/const FP_SHELL_CAMERA_SET := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_devfly_climb.gd
## RUN — with the guard (proves it is bounded + correct):
##   ... also: sed -i 's/const FP_SHELL_CLIMB_NO_CHURN := false/const FP_SHELL_CLIMB_NO_CHURN := true/' godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_devfly_climb (COSMOS DEV-FLY HANG: G-DEVFLY-CLIMB) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate needs FACETED = true (sed-toggled) for the far-ring atlas.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()
	var on := CubeSphere.FP_SHELL_CLIMB_NO_CHURN
	print("  FP_SHELL_CLIMB_NO_CHURN=%s  FP_SHELL_CAMERA_SET=%s  OFFSURFACE_Y=%.0f  R_BLOCKS=%.0f  RELIEF+SLACK=%.0f°"
		% [str(on), str(CubeSphere.FP_SHELL_CAMERA_SET), CubeSphere.OFFSURFACE_Y, FA.R_BLOCKS,
		   CubeSphere.SHELL_RELIEF_DEG + CubeSphere.SHELL_SLACK_DEG])

	var ring := FFR.new()
	# A FIXED absolute climb axis (a straight radial climb keeps the sub-camera direction constant) and a swept axis
	# ~1.3·SLACK away (a horizontal move) for the correctness sub-test.
	var axis := Vector3(0.3, 0.9, 0.32).normalized()
	var up := Vector3(0, 1, 0)
	var e1 := (up - axis * up.dot(axis))
	e1 = (e1.normalized() if e1.length() > 1e-6 else Vector3(1, 0, 0))
	var sweep_ang := deg_to_rad(CubeSphere.SHELL_SLACK_DEG * 1.3)
	var swept_axis := (cos(sweep_ang) * axis + sin(sweep_ang) * e1).normalized()

	# Engage on the ground (floored). First engage always snapshots once (forces the initial emit onto the axis).
	var d0 := FA.R_BLOCKS + 5.0
	ring.shell_set_camera_abs([axis.x, axis.y, axis.z], d0, true)
	var base_snap: int = ring.snapshot_count()
	_ok(bool(ring.shell_cam_set()), "engage: camera-set law engaged on the ground")
	_ok(base_snap == 1, "engage: exactly ONE snapshot on first engage (got %d)" % base_snap)

	# --- Climb: SAME axis, altitude 5 → 250 (all floored, < OFFSURFACE_Y=256). θ_h grows through several 5° steps. ---
	var climb_snaps := 0
	for step in range(1, 50):
		var h := 5.0 + float(step) * 5.0        # 10 .. 250
		if h >= CubeSphere.OFFSURFACE_Y:
			break
		var before: int = ring.snapshot_count()
		ring.shell_set_camera_abs([axis.x, axis.y, axis.z], FA.R_BLOCKS + h, true)
		climb_snaps += ring.snapshot_count() - before
	print("  climb (floored, fixed axis, h 10..250): extra scheduled re-emits = %d" % climb_snaps)

	if not on:
		# BASELINE: the shipped |Δθ_h| > 5° trigger re-emits the identical floored hemisphere repeatedly — the churn.
		_ok(climb_snaps >= 2, "OFF: the floored climb schedules the redundant re-emit churn (extra >= 2, got %d)" % climb_snaps)
		print("  NOTE: sed FP_SHELL_CLIMB_NO_CHURN=true to prove the churn is bounded + correctness preserved.")
	else:
		# GUARD: the identical-cap floored climb schedules NO extra re-emit (churn removed).
		_ok(climb_snaps == 0, "ON: the floored climb schedules ZERO extra re-emits (churn bounded, got %d)" % climb_snaps)
		# CORRECTNESS 1 — an axis SWEEP (horizontal move) past slack still re-emits, even floored.
		var s_before: int = ring.snapshot_count()
		ring.shell_set_camera_abs([swept_axis.x, swept_axis.y, swept_axis.z], FA.R_BLOCKS + 120.0, true)
		_ok(ring.snapshot_count() - s_before == 1, "ON: an axis SWEEP still schedules a re-emit (no limb holes)")
		# CORRECTNESS 2 — crossing OFF the surface floor (floored true → false) still re-emits (the cap changes).
		var f_before: int = ring.snapshot_count()
		ring.shell_set_camera_abs([swept_axis.x, swept_axis.y, swept_axis.z], FA.R_BLOCKS + CubeSphere.OFFSURFACE_Y + 200.0, false)
		_ok(ring.snapshot_count() - f_before == 1, "ON: the OFFSURFACE_Y floor crossing still schedules a re-emit")

	ring.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
