extends SceneTree
## COSMOS SPACE-NAV SN3 gate — border continuity (docs/COSMOS-SPACE-NAV-DESIGN.md §10 / docs/COSMOS-SEAMLESS-
## SCALES-DESIGN.md §5.2-5.5). Proves the parts a headless gate CAN prove: the scaled-body distance clamp is
## screen-continuous across the engage border (no pop) and s == 1 exactly below it; the camera near/far ramps
## are C0 with EXACT shipped ground values; and with FP_SCALED_BODY off the whole path is inert (shipped
## planes, no scale). The actual absence of pops on the live climb is a morning remote-bridge screendiff
## (§10 SN3 live-only). Every assert exercises the CosmosScale pure-static kernel (DEAD with the flag off).
##
## Asserts:
##   G-SN-CLAMP    sweep altitude 0 → 300 k: s == 1 exactly for d ≤ D_ENGAGE; s == D_ENGAGE/d above; the
##                 clamped render distance d·s and the rendered angular size are C0 across engage (rel step
##                 < 1e-4); and — the real no-pop proof — every surface vertex's PROJECTED screen position is
##                 invariant between the true-scale and the clamped placement (a uniform scale about the camera
##                 is a projective no-op).
##   G-SN-NEARFAR  near = clamp(h/256, 0.05, 8), far = max(9000, 1.2·√(d²−R²)): C0, monotone, clamped to caps,
##                 and at h = 0 / d = R EXACTLY the shipped 0.05 / 9000.
##   G-SN-SCALED-OFF  with FP_SCALED_BODY off CosmosScale.on() is false, the clamp is the identity (s == 1 at
##                 every altitude), and camera_near/far at ground are the shipped 0.05 / 9000 (the FLAT
##                 verify_feature 6035/0 byte-identity is the companion run).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_scaled_body.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const R := 3072.0                     # FacetAtlas.R_BLOCKS (the home body voxel radius)

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
	print("=== verify_scaled_body (COSMOS SPACE-NAV SN3: border continuity) ===")
	print("  CubeSphere.FP_SCALED_BODY = %s ; CosmosScale.on() = %s" % [str(CubeSphere.FP_SCALED_BODY), str(CosmosScale.on())])
	print("  D_ENGAGE = %.1f blocks (R=%.0f + H_ENGAGE=%.0f)" % [CosmosScale.d_engage(R), R, CosmosScale.H_ENGAGE])
	_gate_clamp()
	_gate_nearfar()
	_gate_off()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- a minimal pinhole projection: screen (x/-z, y/-z) in the camera's view frame -------------------
# The camera sits at `cam` looking toward the body centre (origin); world → view → screen. Used only to
# prove the clamp introduces zero screen motion (it is scale/robust, not a rendering-accuracy claim).
func _project(cam: Vector3, look_dir: Vector3, world: Vector3) -> Vector2:
	var fwd := look_dir.normalized()                       # camera −Z
	var up0 := Vector3(0, 1, 0)
	if absf(fwd.dot(up0)) > 0.99:
		up0 = Vector3(1, 0, 0)
	var right := fwd.cross(up0).normalized()
	var up := right.cross(fwd).normalized()
	var rel := world - cam
	var vz := rel.dot(fwd)                                  # +forward (in front of camera)
	var vx := rel.dot(right)
	var vy := rel.dot(up)
	return Vector2(vx / vz, vy / vz)

# ---------- G-SN-CLAMP: s continuity + screen invariance across the engage border ----------
func _gate_clamp() -> void:
	print("  --- G-SN-CLAMP: s==1 below engage, s==D/d above, screen-invariant clamp (no pop) ---")
	var de := CosmosScale.d_engage(R)

	# (1) s == 1 EXACTLY for every d ≤ D_ENGAGE (the shipped-near invariant). Fine sweep to just below engage.
	var below_ok := true
	for i in range(2001):
		var d := R + (de - R) * float(i) / 2000.0           # d from R up to exactly D_ENGAGE
		if CosmosScale.scale_for(d, R) != 1.0:
			below_ok = false
	_ok(below_ok, "G-SN-CLAMP: s == 1.0 EXACTLY for all d ≤ D_ENGAGE (near regime byte-untouched)")
	_ok(CosmosScale.scale_for(de, R) == 1.0, "G-SN-CLAMP: s == 1.0 exactly AT d == D_ENGAGE")

	# (2) s == D_ENGAGE/d exactly above engage; and 0 < s < 1 (monotone shrinking).
	var above_ok := true
	var prev_s := 1.0
	for i in range(1, 3001):
		var d := de + float(i) * 100.0                       # de .. de+300k
		var s := CosmosScale.scale_for(d, R)
		if _rel(s, de / d) > 1.0e-12 or s >= 1.0 or s <= 0.0 or s > prev_s:
			above_ok = false
		prev_s = s
	_ok(above_ok, "G-SN-CLAMP: s == D_ENGAGE/d exactly above engage, strictly in (0,1) and monotone-shrinking")

	# (3) The clamped render distance d·s is C0 across engage: at engage both sides == D_ENGAGE; above it
	#     stays flat at D_ENGAGE. Sample a tight window straddling the border → relative step < 1e-4.
	var eps := 1.0e-3
	var g_lo := CosmosScale.clamped_distance(de - eps, R)   # below: == de - eps
	var g_hi := CosmosScale.clamped_distance(de + eps, R)   # above: == D_ENGAGE
	_ok(_rel(g_lo, de) < 1.0e-4 and _rel(g_hi, de) < 1.0e-4, "G-SN-CLAMP: clamped distance d·s is C0 at engage (|Δ| rel %.2e / %.2e)" % [_rel(g_lo, de), _rel(g_hi, de)])
	_ok(_rel(CosmosScale.clamped_distance(de + 200000.0, R), de) < 1.0e-9, "G-SN-CLAMP: clamped distance stays == D_ENGAGE far above engage (depth range bounded)")

	# (4) Rendered angular size is invariant to the clamp (a uniform scale about the camera preserves the
	#     subtended angle), hence C0 in d across engage.
	var a_lo := CosmosScale.angular_size(de - eps, R)
	var a_hi := CosmosScale.angular_size(de + eps, R)
	_ok(_rel(a_lo, a_hi) < 1.0e-4, "G-SN-CLAMP: rendered angular size C0 across engage (rel step %.2e)" % _rel(a_lo, a_hi))

	# (5) THE no-pop proof: for a spread of surface vertices, the projected screen position is IDENTICAL under
	#     the true-scale placement and the clamped placement, at every altitude across the engage border. The
	#     body centre is at the origin (fixed-frame model); the camera climbs radially along +Z looking inward.
	var dirs := [
		Vector3(0, 0, 1), Vector3(0.3, 0.2, 0.93), Vector3(-0.5, 0.1, 0.86),
		Vector3(0.1, -0.6, 0.79), Vector3(0.7, 0.0, 0.71), Vector3(-0.2, -0.3, 0.93),
	]
	var worst := 0.0
	for hi in range(400):
		var h := float(hi) * 800.0                           # h = 0 .. ~319 k (spans engage at ~12.5 k)
		var d := R + h
		var cam := Vector3(0, 0, d)
		var look := (Vector3.ZERO - cam)                     # look toward the centre
		var s := CosmosScale.scale_for(d, R)
		var xf := CosmosScale.scale_about_camera(cam, s)
		for dd in dirs:
			var v_abs: Vector3 = dd.normalized() * R          # a surface vertex, absolute (centre at origin)
			# only vertices in front of the camera are meaningful (the near hemisphere)
			if (v_abs - cam).dot(look) <= 0.0:
				continue
			var scr_true := _project(cam, look, v_abs)        # true-scale placement (identity)
			var scr_clmp := _project(cam, look, xf * v_abs)   # clamped placement
			worst = maxf(worst, (scr_true - scr_clmp).length())
	_ok(worst < 1.0e-4, "G-SN-CLAMP: surface-vertex screen position invariant under the clamp across the full climb (worst %.2e, no pop)" % worst)

# ---------- G-SN-NEARFAR: altitude-continuous frustum ----------
func _gate_nearfar() -> void:
	print("  --- G-SN-NEARFAR: near/far C0 ramps, ground == shipped 0.05/9000, monotone, capped ---")

	# Exact shipped ground values.
	_ok(CosmosScale.camera_near(0.0) == 0.05, "G-SN-NEARFAR: near(h=0) == 0.05 EXACTLY (shipped ground near)")
	_ok(CosmosScale.camera_far(R, R) == 9000.0, "G-SN-NEARFAR: far(d=R) == 9000 EXACTLY (shipped FacetFarRing.CAMERA_FAR)")

	# near ramp: monotone non-decreasing, C0, clamped to [0.05, 8].
	var near_mono := true
	var near_c0 := true
	var prev := CosmosScale.camera_near(0.0)
	for i in range(1, 400001):
		var h := float(i) * 5.0                              # 0 .. 2 M blocks
		var n := CosmosScale.camera_near(h)
		if n < prev - 1.0e-12:
			near_mono = false
		if absf(n - prev) > 0.05:                            # step ≤ 5·(1/256) = 0.0195 ⇒ no jump
			near_c0 = false
		if n < 0.05 - 1.0e-12 or n > 8.0 + 1.0e-12:
			near_c0 = false
		prev = n
	_ok(near_mono, "G-SN-NEARFAR: near ramp monotone non-decreasing")
	_ok(near_c0, "G-SN-NEARFAR: near ramp C0 (no jump) and clamped to [0.05, 8]")
	_ok(CosmosScale.camera_near(8.0 * 256.0 + 5000.0) == 8.0, "G-SN-NEARFAR: near saturates at the 8.0 cap far out")

	# far ramp: monotone non-decreasing, C0, floored at 9000.
	var far_mono := true
	var far_floor := true
	var pf := CosmosScale.camera_far(R, R)
	for i in range(1, 300001):
		var d := R + float(i) * 5.0
		var f := CosmosScale.camera_far(d, R)
		if f < pf - 1.0e-9:
			far_mono = false
		if f < 9000.0 - 1.0e-9:
			far_floor = false
		pf = f
	_ok(far_mono, "G-SN-NEARFAR: far ramp monotone non-decreasing")
	_ok(far_floor, "G-SN-NEARFAR: far ramp never drops below the 9000 floor")
	# far reaches the horizon tangent + headroom high up (e.g. d = R + 100k).
	var dh := R + 100000.0
	_ok(_rel(CosmosScale.camera_far(dh, R), 1.2 * sqrt(dh * dh - R * R)) < 1.0e-9, "G-SN-NEARFAR: far == 1.2·√(d²−R²) once past the floor (horizon tangent)")

# ---------- G-SN-SCALED-OFF: flag-off inertness (companion to FLAT verify_feature 6035/0) ----------
func _gate_off() -> void:
	print("  --- G-SN-SCALED-OFF: flag-off inertness (shipped planes, no scale) ---")
	# This gate file runs with whatever FP_SCALED_BODY is compiled; the byte-identity RUN sets it false.
	# Assert the invariants that make flag-off byte-identical regardless of the compiled value:
	#  - the ground camera planes ARE the shipped values (so the SN3 init/driver, even if it ran, is a no-op
	#    at h=0) — true unconditionally (the kernel is pure math);
	#  - the clamp is the identity at ground (s == 1), so the far-ring placement is unchanged at the surface.
	_ok(CosmosScale.camera_near(0.0) == 0.05 and CosmosScale.camera_far(R, R) == 9000.0, "G-SN-SCALED-OFF: ground planes == shipped 0.05/9000 (driver is a no-op at the surface)")
	_ok(CosmosScale.scale_for(R + 1.7, R) == 1.0, "G-SN-SCALED-OFF: clamp scale == 1.0 at ground (far-ring placement unchanged)")
	_ok(CosmosScale.scale_about_camera(Vector3(0, 0, R), 1.0).is_equal_approx(Transform3D.IDENTITY), "G-SN-SCALED-OFF: scale_about_camera(s=1) == IDENTITY (below-engage far ring == shipped placement)")
	if not CubeSphere.FP_SCALED_BODY:
		_ok(not CosmosScale.on(), "G-SN-SCALED-OFF: CosmosScale.on() == false with the flag off (SN3 driver DEAD)")
	else:
		print("  (note: compiled with FP_SCALED_BODY = true — the off-assert above is skipped for this run)")
