extends SceneTree
## COSMOS ORBIT-FRAME gate — the inertial-attitude kernel (docs/COSMOS-ORBIT-FRAME-DESIGN.md §8). Proves the
## pure CosmosAttitude math + the root-cause theorem, entirely headless. Every assert is PURE-KERNEL (CosmosAttitude
## / CosmosEphemeris are engine-free statics), so the gate is FLAG-INDEPENDENT: it passes identically whether
## ORBIT_ATTITUDE/ORBIT_6DOF_FLY/ORBIT_LAND_RECOVER are true or false (the machine is DEAD — never instantiated —
## in-game with the flags off; the gate drives the kernel directly). Byte-identity (G-ORBIT-OFF) is the FLAT
## verify_feature (6035/0) + the faceted suite, run separately.
##
## Asserts:
##   G-ORBIT-ATT   seed round-trip scene_basis(seed_bci(B,θ),θ) == B (random B,θ); pitch composes past ±90° with
##                 no clamp / axis-flip (200 × 1° increments ⇒ net 200°); roll composes (4×90° returns to start);
##                 zero-input INERTIAL HOLD — scene_basis(q,θ(t)) vs the star-dome basis is CONSTANT across a day.
##   G-ORBIT-SKY   the −θ dome counter-rotation regression: R_z(−θ)·R_z(+θ) == I; the view-relative star rotation
##                 B_rel = B_cam⁻¹·R_z(−θ) is CONSTANT when B_cam follows the inertial-hold formula (fixed q), and
##                 rotates at exactly −ω (the θ-step rotation) when B_cam is a constant body-fixed basis.
##   G-ORBIT-FLY   (Phase B) lat_cam_basis maps forward to the BCI look direction to f32 tol through random
##                 facet/θ; Space/Ctrl move along CAMERA ±Y not lattice ±Y.
##   G-ORBIT-REC   (Phase C) recovery converges (roll==0, pitch∈[−1.5,1.5], heading/elevation preserved) from ANY
##                 start incl. roll π + the forward=±facet-normal degenerate; continuity at α=0/α=1; no spike.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbit_frame.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const ATT := preload("res://src/cosmos/cosmos_attitude.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Max column-wise deviation between two bases (f32 tolerance metric).
func _basis_dev(a: Basis, b: Basis) -> float:
	return maxf(maxf((a.x - b.x).length(), (a.y - b.y).length()), (a.z - b.z).length())

## A deterministic pseudo-random rotation basis from an integer seed (no randi — reproducible).
func _rand_basis(seed: int) -> Basis:
	var s := float(seed)
	var yaw := fmod(s * 1.31, TAU)
	var pitch := fmod(s * 0.77, TAU)
	var roll := fmod(s * 2.19, TAU)
	return Basis(Vector3(0, 1, 0), yaw) * Basis(Vector3(1, 0, 0), pitch) * Basis(Vector3(0, 0, 1), roll)

func _initialize() -> void:
	print("=== verify_orbit_frame (COSMOS ORBIT-FRAME: inertial attitude + sky theorem + 6DOF + recovery) ===")
	print("  ORBIT_ATTITUDE=%s (gate is flag-independent; the CosmosAttitude kernel is a pure static)"
		% str(CubeSphere.ORBIT_ATTITUDE))
	FacetAtlas.warm_up()
	_gate_att()
	_gate_sky()
	_gate_fly()
	_gate_rec()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-ORBIT-ATT: seed round-trip + unlimited pitch/roll + inertial hold ----------
func _gate_att() -> void:
	# Seed round-trip over random (B, θ): scene_basis(seed_bci(B,θ),θ) == B to f32.
	var worst := 0.0
	for i in range(64):
		var b := _rand_basis(i * 7 + 3)
		var theta := fmod(float(i) * 0.911, TAU) - PI
		var q := ATT.seed_bci(b, theta)
		var back := ATT.scene_basis(q, theta)
		worst = maxf(worst, _basis_dev(b, back))
	_ok(worst < 1.0e-5, "G-ORBIT-ATT seed round-trip max dev %s" % worst)

	# Unlimited pitch: compose 200 camera-local 1° pitch increments ⇒ net 200° with NO clamp / axis flip. Check by
	# tracking the forward vector; at net +200° pitch (past straight-up +90° and over the top) the forward has
	# rotated well past vertical. Reference: a single Quaternion(+X, 200°) applied to the same start.
	# apply_look pitch is q·Quaternion(+X, −dy·sens); pick dy = 1°/sens so each call applies Quaternion(+X, −1°).
	var q0 := Quaternion.IDENTITY
	var sens := 0.0025
	var dy_1deg := deg_to_rad(1.0) / sens
	for _i in range(200):
		q0 = ATT.apply_look(q0, 0.0, dy_1deg, sens)
	# 200 × Quaternion(+X, −1°) == Quaternion(+X, −200°) — no clamp would cap this at ±90°.
	var q_ref := (Quaternion(Vector3(1, 0, 0), -deg_to_rad(200.0))).normalized()
	var fwd_inc := Basis(q0) * Vector3(0, 0, -1)
	var fwd_ref := Basis(q_ref) * Vector3(0, 0, -1)
	_ok((fwd_inc - fwd_ref).length() < 1.0e-4, "G-ORBIT-ATT 200×1° pitch == −200° (dev %s)" % (fwd_inc - fwd_ref).length())
	# And it genuinely passed the pole: net −200° about +X takes forward −Z below then behind — y-component non-trivial.
	_ok(absf(fwd_inc.y) > 0.3 or absf(fwd_inc.z + 1.0) > 0.5, "G-ORBIT-ATT pitch passed the ±90° pole (no clamp)")

	# Roll: 4 × 90° roll returns to the start (identity round-trip, f32).
	var qr := Quaternion.IDENTITY
	for _i in range(4):
		qr = ATT.apply_roll(qr, 1.0, deg_to_rad(90.0), 1.0)   # dir·rate·dt = 90°
	var roll_dev := _basis_dev(Basis(qr), Basis.IDENTITY)
	_ok(roll_dev < 1.0e-5, "G-ORBIT-ATT 4×90° roll == identity (dev %s)" % roll_dev)

	# Zero-input INERTIAL HOLD: with a FIXED q_bci, the view-relative rotation between the camera and the star dome
	# is CONSTANT across a sampled game day. B_rel(t) = scene_basis(q,θ(t))⁻¹ · dome(θ(t)), dome = R_z(−θ).
	var q_hold := ATT.seed_bci(_rand_basis(99), 0.37)
	var ref_rel := Basis()
	var have_ref := false
	var hold_worst := 0.0
	for k in range(48):
		var t := float(k) / 48.0 * EPH.DAY_GAME
		var theta := EPH.spin_angle("earth", t)
		var b_cam := ATT.scene_basis(q_hold, theta)
		var dome := ATT.rot_z(-theta)
		var b_rel := b_cam.transposed() * dome
		if not have_ref:
			ref_rel = b_rel
			have_ref = true
		else:
			hold_worst = maxf(hold_worst, _basis_dev(b_rel, ref_rel))
	_ok(hold_worst < 1.0e-4, "G-ORBIT-ATT inertial hold: B_rel constant over a day (dev %s)" % hold_worst)

# ---------- G-ORBIT-SKY: the −θ dome counter-rotation regression ----------
func _gate_sky() -> void:
	# R_z(−θ)·R_z(+θ) == identity across a sampled day (the dome basis is the exact fixed-frame expression of an
	# inertial pattern — pins the sky's counter-rotation formula the whole result depends on).
	var worst := 0.0
	for k in range(64):
		var t := float(k) / 64.0 * EPH.DAY_GAME
		var theta := EPH.spin_angle("earth", t)
		var prod := ATT.rot_z(-theta) * ATT.rot_z(theta)
		worst = maxf(worst, _basis_dev(prod, Basis.IDENTITY))
	_ok(worst < 1.0e-6, "G-ORBIT-SKY R_z(−θ)·R_z(+θ)==I (dev %s)" % worst)

	# Surface (body-fixed constant B_cam): B_rel = B_cam⁻¹·R_z(−θ) rotates at exactly −ω — the successive-sample
	# relative rotation equals the θ-step rotation (the stars wheel once per game day, CORRECT for the surface).
	var b_fixed := _rand_basis(11)
	var step_worst := 0.0
	var t_prev := 0.0
	var rel_prev := b_fixed.transposed() * ATT.rot_z(-EPH.spin_angle("earth", 0.0))
	for k in range(1, 32):
		var t := float(k) / 32.0 * EPH.DAY_GAME
		var rel := b_fixed.transposed() * ATT.rot_z(-EPH.spin_angle("earth", t))
		# rel_prev⁻¹·rel = R_z(θ_prev)·R_z(−θ) = R_z(−(θ−θ_prev)) — the b_fixed factors cancel, so the measured
		# world-frame relative step is exactly the dome's −ω rotation over dt (the surface stars wheel once per day).
		var dtheta := EPH.spin_angle("earth", t) - EPH.spin_angle("earth", t_prev)
		var expected := ATT.rot_z(-dtheta)
		var measured := rel_prev.transposed() * rel
		step_worst = maxf(step_worst, _basis_dev(measured, expected))
		rel_prev = rel
		t_prev = t
	_ok(step_worst < 1.0e-4, "G-ORBIT-SKY surface stars wheel at −ω (step dev %s)" % step_worst)

# ---------- G-ORBIT-FLY (Phase B): the lattice look-fly basis ----------
func _gate_fly() -> void:
	# lat_cam_basis(frame_basis(fid), B_scene) maps a lattice input to the camera axes; lifting the mapped forward
	# back to scene via frame_basis must reproduce B_scene·(0,0,−1) (the look direction). Random facet + attitude.
	var nf := FacetAtlas.facet_count()
	var worst := 0.0
	var vy_ok := true
	for i in range(40):
		var fid := i % nf
		var fb := FacetAtlas.frame_basis(fid)
		var theta := fmod(float(i) * 0.53, TAU)
		var q := ATT.seed_bci(_rand_basis(i * 5 + 1), theta)
		var b_scene := ATT.scene_basis(q, theta)
		var b_lat_cam := ATT.lat_cam_basis(fb, b_scene)
		# forward: lattice input (0,0,−1) → lattice dir; lift by fb → scene; compare to the true look −B_scene.z.
		var dir_lat := b_lat_cam * Vector3(0, 0, -1)
		var dir_scene := fb * dir_lat
		var look := -b_scene.z
		worst = maxf(worst, (dir_scene - look).length())
		# Space (+Y input) must move along the CAMERA up axis (scene b_scene.y), not the lattice up (fb.y).
		var up_lat := b_lat_cam * Vector3(0, 1, 0)
		var up_scene := (fb * up_lat).normalized()
		if (up_scene - b_scene.y.normalized()).length() > 1.0e-4:
			vy_ok = false
	_ok(worst < 1.0e-4, "G-ORBIT-FLY forward maps to BCI look (dev %s)" % worst)
	_ok(vy_ok, "G-ORBIT-FLY Space/Ctrl move along CAMERA ±Y (not lattice ±Y)")
# ---------- G-ORBIT-REC (Phase C): landing recovery convergence + continuity ----------
func _gate_rec() -> void:
	var nf := FacetAtlas.facet_count()
	var conv_ok := true
	var cont0_worst := 0.0
	var cont1_worst := 0.0
	var roll_worst := 0.0
	var spike_worst := 0.0
	var heading_ok := true
	# Include degenerate start attitudes: forward = ±facet normal, and a roll-π (upside-down) view.
	for i in range(48):
		var fid := i % nf
		var b_active := FacetAtlas.frame_basis(fid)
		# A start scene basis: rotate the facet frame by a random full 3D rotation (covers roll π, look ±normal).
		var b_start := b_active * _rand_basis(i * 3 + 2)
		var degenerate := i % 7 == 0
		if degenerate:
			# Degenerate: forward exactly along +normal (look straight down the facet normal), rolled.
			b_start = b_active * (Basis(Vector3(1, 0, 0), -PI * 0.5) * Basis(Vector3(0, 0, 1), fmod(float(i), TAU)))
		var tp := ATT.recover_target(b_active, b_start)
		# α=1: the displayed basis equals the surface FPS reconstruction; roll==0 (right-axis horizontal), pitch clamped.
		var b_lat_start_q := (b_active.transposed() * b_start).orthonormalized().get_rotation_quaternion()
		var b_end := ATT.recover_blend(b_active, b_lat_start_q, tp.x, tp.y, 1.0)
		var b_hand := b_active * ATT.surface_lat_basis(tp.x, tp.y)
		cont1_worst = maxf(cont1_worst, _basis_dev(b_end, b_hand))
		# roll == 0: the right-axis (X column) of the lattice-frame basis has no facet-normal (+Y) component.
		var lat_end := b_active.transposed() * b_end
		roll_worst = maxf(roll_worst, absf(lat_end.x.y))
		if tp.y < -1.5 - 1.0e-6 or tp.y > 1.5 + 1.0e-6:
			conv_ok = false
		# HEADING PRESERVED: the recovered forward keeps the incoming view's horizontal azimuth (you look the SAME
		# way, just level + roll-free). Non-degenerate only (a straight-down look has no defined azimuth). The
		# elevation sign is preserved too (looking up recovers to a positive pitch). Catches a wrong target sign.
		if not degenerate:
			var f_start := -(b_active.transposed() * b_start).z
			var f_end := -lat_end.z
			var hs := Vector2(f_start.x, f_start.z)
			var he := Vector2(f_end.x, f_end.z)
			if hs.length() > 1.0e-3 and he.length() > 1.0e-3 and hs.normalized().dot(he.normalized()) < 0.999:
				heading_ok = false
			if signf(f_end.y) != signf(clampf(f_start.y, -sin(1.5), sin(1.5))) and absf(f_start.y) > 1.0e-3:
				heading_ok = false
		# α=0: the displayed basis equals the frozen scene start (C0 continuity).
		var b0 := ATT.recover_blend(b_active, b_lat_start_q, tp.x, tp.y, 0.0)
		cont0_worst = maxf(cont0_worst, _basis_dev(b0, b_start))
		# No spike: the per-α-step angular delta is bounded (sample the blend; max step small over a fine sweep).
		var prev := b0
		for k in range(1, 33):
			var a := float(k) / 32.0
			var b := ATT.recover_blend(b_active, b_lat_start_q, tp.x, tp.y, a)
			spike_worst = maxf(spike_worst, _basis_dev(prev, b))
			prev = b
	_ok(cont0_worst < 1.0e-4, "G-ORBIT-REC continuity α=0 == frozen start (dev %s)" % cont0_worst)
	_ok(cont1_worst < 1.0e-4, "G-ORBIT-REC continuity α=1 == hand-back euler (dev %s)" % cont1_worst)
	_ok(roll_worst < 1.0e-5, "G-ORBIT-REC roll==0 at α=1 (right-axis normal comp %s)" % roll_worst)
	_ok(conv_ok, "G-ORBIT-REC pitch converges within ±1.5 rad from any start")
	_ok(heading_ok, "G-ORBIT-REC recovered heading preserves the incoming view azimuth + elevation sign")
	# A π tumble over 32 steps ⇒ each step ≤ ~π/32·(smoothstep peak 1.5) ≈ 0.15 rad ⇒ basis dev < ~0.25. Generous bound.
	_ok(spike_worst < 0.3, "G-ORBIT-REC no angular spike across the blend (max step dev %s)" % spike_worst)
