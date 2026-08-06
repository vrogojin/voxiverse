extends SceneTree
## COSMOS PLAYER-UPVECTOR-FACET-DESYNC FIX gate (FP_CAMERA_RADIAL_LEVEL, task #92,
## docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md §5.4). Most arms exercise the PURE static roll math
## (Player.cam_rl_phi_raw/w/v/phi, Player._CAM_RL_SIGN) directly — no live scene needed — matching the pattern
## `probe_radial_vs_facet_up.gd` already validated the §1.6 residual numbers with; a live Player+WorldManager is
## used only where the test genuinely needs the dynamic (the ATT_SURFACE scope guard, the heal composition).
##
## RUN (flags ON — the roll flag + the fall-through/heal stack it composes with):
##   sed -i 's/const FACETED := false/const FACETED := true/; \
##           s/const FP_QUERY_FRAME_GUARD := false/const FP_QUERY_FRAME_GUARD := true/; \
##           s/const FP_FLOOR_SURFACE_WELD := false/const FP_FLOOR_SURFACE_WELD := true/; \
##           s/const FP_UPVECTOR_FACET_HEAL := false/const FP_UPVECTOR_FACET_HEAL := true/; \
##           s/const FP_CAMERA_RADIAL_LEVEL := false/const FP_CAMERA_RADIAL_LEVEL := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_camera_radial_level.gd
##   then REVERT via sed (NEVER `git checkout -- <file>` — it discards uncommitted work in this worktree).
##   Exits 0 all-pass / 1 on any failure.
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const PlayerCls := preload("res://src/player/player.gd")

const HYST := 0.1   # mirrors WorldManager.FACET_CROSS_HYST (private to that class) for this gate's own hunts

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_camera_radial_level (FP_CAMERA_RADIAL_LEVEL) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED (+FP_CAMERA_RADIAL_LEVEL, +FP_UPVECTOR_FACET_HEAL for the heal-composition arm) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	print("  FP_CAMERA_RADIAL_LEVEL=%s FP_UPVECTOR_FACET_HEAL=%s CAM_RL_ALT_LO=%.1f CAM_RL_ALT_HI=%.1f" % [
		str(CubeSphere.FP_CAMERA_RADIAL_LEVEL), str(CubeSphere.FP_UPVECTOR_FACET_HEAL), CubeSphere.CAM_RL_ALT_LO, CubeSphere.CAM_RL_ALT_HI])

	await _gate_att_surface_guard()
	_gate_analytic_roll()
	_gate_blend_law()
	_gate_aim_invariance()
	_gate_crossing_continuity()
	_gate_heal_composition()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ============================================================ arm 1 (structural byte-off proxy) =================
## `verify_feature.gd` (flags off) is the actual byte-off proof (6042/0, separately confirmed). Since this gate's
## own binary is compiled with FP_CAMERA_RADIAL_LEVEL ON (needed for every other arm), it cannot re-demonstrate
## "flag off ⇒ no write" in-process — instead it pins the OTHER half of the write's guard: `_att_mode ==
## ATT_SURFACE`. A live player forced into ATT_SPACE must see NO camera-transform write from `_move`, proving the
## scope guard (not just the flag) gates the roll.
func _gate_att_surface_guard() -> void:
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var wm := WorldManager.new(); wm.name = "CamRLGuardWM"; get_root().add_child(wm)
	var pl = PlayerCls.new()
	pl.world = wm
	get_root().add_child(pl)                                # fires _ready (camera rig, frame adapter)
	await process_frame                                      # let _ready() land before touching pl._camera
	pl.frozen = true
	var c := FA.centre_cell(fid)
	var g := float(int(TC.column_profile(c.x, c.y).x))
	pl.position = Vector3(float(c.x) + 0.5, g + 1.0, float(c.y) + 0.5)
	pl.velocity = Vector3.ZERO
	pl._att_mode = PlayerCls.ATT_SPACE
	var before: Transform3D = pl._camera.transform
	pl._move(1.0 / 60.0)
	var after: Transform3D = pl._camera.transform
	print("  G-ATT-GUARD: att_mode=SPACE camera transform unchanged=%s" % str(before.is_equal_approx(after)))
	_ok(before.is_equal_approx(after),
		"camera transform changed even though _att_mode != ATT_SURFACE — the roll's scope guard is broken")
	pl.queue_free()
	wm.queue_free()

# ============================================================ arm 2 (analytic roll) ==============================
## Pure math: at facet centre/edge-mid/corner (`facet_planar_corner`, mirroring probe_radial_vs_facet_up.gd's own
## validated construction), across 8 yaw headings at pitch 0: phi_raw must equal the independently-constructed
## projection form to high precision, satisfy the sign post-condition, and never exceed the (yaw-independent)
## geometric angle(facet_up, u_r) — which itself must land near the §1.6 measured residuals (~0° / ~1.8° / ~2.6°).
func _gate_analytic_roll() -> void:
	var fids := [1356, 348, 1000]
	for fid: int in fids:
		var up_f: Vector3 = FA.frame_basis(fid).y
		var corners := []
		for ci in range(4):
			var wc: Array = FA.facet_planar_corner(fid, ci)
			corners.append(FA.world_to_lattice64(fid, wc[0], wc[1], wc[2]))
		var cx := 0.0
		var cz := 0.0
		for c in corners:
			cx += float(c[0]) / 4.0
			cz += float(c[2]) / 4.0
		var m0x: float = (float(corners[0][0]) + float(corners[1][0])) / 2.0
		var m0z: float = (float(corners[0][2]) + float(corners[1][2])) / 2.0
		var samples := [
			{"label": "centre", "x": cx, "z": cz, "expect_lo": 0.0, "expect_hi": 0.5},
			{"label": "edge-mid", "x": m0x, "z": m0z, "expect_lo": 1.0, "expect_hi": 2.3},
			{"label": "corner", "x": float(corners[0][0]), "z": float(corners[0][2]), "expect_lo": 1.8, "expect_hi": 3.0},
		]
		for s in samples:
			var w := FA.lattice_to_world64(fid, float(s["x"]), 64.0, float(s["z"]))
			var u_r := Vector3(w[0], w[1], w[2]).normalized()
			var geo_deg := rad_to_deg(up_f.angle_to(u_r))
			_ok(geo_deg >= float(s["expect_lo"]) and geo_deg <= float(s["expect_hi"]),
				"fid=%d %s: geometric angle(facet_up,u_r)=%.3f° outside expected [%.1f,%.1f]° — atlas/probe changed" % [
					fid, s["label"], geo_deg, s["expect_lo"], s["expect_hi"]])
			for yaw_i in range(8):
				var yaw := TAU * float(yaw_i) / 8.0
				var b0 := FA.frame_basis(fid) * Basis(Vector3(0, 1, 0), yaw)   # pitch = 0
				var f_hat: Vector3 = -b0.z
				var phi_raw := PlayerCls.cam_rl_phi_raw(u_r, b0.x, b0.y)
				_ok(absf(phi_raw) <= deg_to_rad(geo_deg) + 1e-4,
					"fid=%d %s yaw_i=%d: |phi_raw|=%.4f° exceeds the geometric bound %.4f°" % [
						fid, s["label"], yaw_i, rad_to_deg(absf(phi_raw)), geo_deg])
				var u_proj := u_r - f_hat * u_r.dot(f_hat)
				if u_proj.length() < 1e-6:
					continue                              # degenerate (gaze ~along u_r) — skip the projection check
				u_proj = u_proj.normalized()
				var rolled := b0 * Basis(Vector3(0, 0, 1), PlayerCls._CAM_RL_SIGN * phi_raw)
				var r_rolled: Vector3 = rolled.x
				var u_rolled: Vector3 = rolled.y
				_ok(absf(r_rolled.dot(u_r)) < 1e-4,
					"fid=%d %s yaw_i=%d: r̂'·u_r=%.6f (expected ~0)" % [fid, s["label"], yaw_i, r_rolled.dot(u_r)])
				_ok(u_rolled.dot(u_r) > -1e-6,
					"fid=%d %s yaw_i=%d: û'·u_r=%.6f (expected > 0)" % [fid, s["label"], yaw_i, u_rolled.dot(u_r)])
				_ok((u_rolled - u_proj).length() < 1e-5,
					"fid=%d %s yaw_i=%d: rolled û'=%s != projection form=%s (Δ=%.6f)" % [
						fid, s["label"], yaw_i, str(u_rolled), str(u_proj), (u_rolled - u_proj).length()])

# ============================================================ arm 3 (blend law) ==================================
## Pure math. `cam_rl_phi` must equal `w·v·ease·phi_raw` exactly (it IS that product); `w` must be exact 0 at/below
## LO, exact 1 at/above HI, monotone and C1 (no kink) in between; `v` matches cos² at spot values.
func _gate_blend_law() -> void:
	var u_r := Vector3(0.1, 1.0, 0.3).normalized()
	var r0 := Vector3(1, 0, 0)
	var u0 := Vector3(0, 1, 0)
	var phi_raw := PlayerCls.cam_rl_phi_raw(u_r, r0, u0)
	var lo := CubeSphere.CAM_RL_ALT_LO
	var hi := CubeSphere.CAM_RL_ALT_HI
	var alts := [0.0, lo, (lo + hi) * 0.5, hi, hi * 2.0]
	var pitches := [0.0, 0.75, -0.75, 1.5, -1.5]
	for alt in alts:
		for pitch in pitches:
			var expected: float = PlayerCls.cam_rl_w(alt) * PlayerCls.cam_rl_v(pitch) * phi_raw
			var got := PlayerCls.cam_rl_phi(u_r, r0, u0, alt, pitch, 1.0)
			_ok(absf(got - expected) < 1e-9,
				"blend law mismatch at alt=%.1f pitch=%.2f: got %.8f expected %.8f" % [alt, pitch, got, expected])
	_ok(PlayerCls.cam_rl_w(lo) == 0.0, "w(ALT_LO) != 0 exactly (got %.6f)" % PlayerCls.cam_rl_w(lo))
	_ok(PlayerCls.cam_rl_w(lo - 5.0) == 0.0, "w(below ALT_LO) != 0 exactly")
	_ok(PlayerCls.cam_rl_w(hi) == 1.0, "w(ALT_HI) != 1 exactly (got %.6f)" % PlayerCls.cam_rl_w(hi))
	_ok(PlayerCls.cam_rl_w(hi + 5.0) == 1.0, "w(above ALT_HI) != 1 exactly")
	var prev := -1.0
	for i in range(21):
		var a := lo + (hi - lo) * float(i) / 20.0
		var w := PlayerCls.cam_rl_w(a)
		_ok(w >= prev - 1e-9, "w(alt) not monotone at alt=%.2f (w=%.6f < prev=%.6f)" % [a, w, prev])
		prev = w
	var h := 0.01
	for i in range(1, 20):
		var a := lo + (hi - lo) * float(i) / 20.0
		var d2 := (PlayerCls.cam_rl_w(a + h) - 2.0 * PlayerCls.cam_rl_w(a) + PlayerCls.cam_rl_w(a - h)) / (h * h)
		_ok(absf(d2) < 50.0,
			"w(alt) 2nd-difference blew up at alt=%.2f (d2=%.2f) — a C0/kinked curve, not the C1 smoothstep spec" % [a, d2])
	_ok(is_equal_approx(PlayerCls.cam_rl_v(0.0), 1.0), "v(0) != 1 (got %.6f)" % PlayerCls.cam_rl_v(0.0))
	_ok(PlayerCls.cam_rl_v(1.5) < 0.02, "v(1.5) is not small near the pitch clamp (got %.4f)" % PlayerCls.cam_rl_v(1.5))

# ============================================================ arm 5 (aim invariance) =============================
## Pure math: for the ACTUAL formula (Rx(pitch) * Rz(s·phi)), the .z column (forward) is unchanged for ANY phi —
## a rotation about local Z leaves local Z fixed. Pins the formula's structure, not just the abstract identity.
func _gate_aim_invariance() -> void:
	var pitches := [0.0, 0.4, -0.9, 1.2]
	var phis := [0.0, 0.1, -0.3, deg_to_rad(2.6), -deg_to_rad(2.6)]
	for pitch in pitches:
		var b_off := Basis(Vector3(1, 0, 0), pitch)
		for phi in phis:
			var b_on := Basis(Vector3(1, 0, 0), pitch) * Basis(Vector3(0, 0, 1), PlayerCls._CAM_RL_SIGN * phi)
			_ok((b_on.z - b_off.z).length() < 1e-6,
				"roll changed the forward axis (pitch=%.2f phi=%.3f rad): Δ=%.8f" % [pitch, phi, (b_on.z - b_off.z).length()])

# ============================================================ arm 4 (crossing continuity) =========================
## Find a normal deep, CONTAINED crossing at high altitude (w≈1). The dihedral rotation's own axis (the ridge) is
## `crossing_basis(A,B)`'s rotation axis in A's local coords; a gaze parallel to it ("along-ridge") must show the
## roll erasing the WHOLE crossing snap (displayed screen-up continuous); a gaze perpendicular to it
## ("across-ridge") must show forward itself jumping (the accepted, undocumented-by-roll residue).
func _gate_crossing_continuity() -> void:
	var fids := [1356, 348, 1000, 0, 300, 2000, 3000]
	var found := {}
	for fid: int in fids:
		TC.set_active_facet(fid)
		var c := FA.centre_cell(fid)
		var pl: PackedFloat64Array = FA.seam_planes_f64(fid)
		for slot in 4:
			var A := pl[slot * 4 + 0]
			if absf(A) < 1e-6:
				continue
			var base_z := float(c.y) + 0.5
			var base_y := 200.0                           # high altitude ⇒ w(alt) ≈ 1
			var base_own := FA.own_dist(fid, slot, float(c.x) + 0.5, base_y, base_z)
			var target := -0.8
			var x := float(c.x) + 0.5 + (target - base_own) / A
			var s := FA.own_dist(fid, slot, x, base_y, base_z)
			if s >= -0.5:
				continue
			var to: int = FA.seam_neighbour(fid, slot)
			var np := FA.reframe_position64(fid, to, x, base_y, base_z)
			var contained := true
			for bslot in 4:
				if FA.own_dist(to, bslot, np[0], np[1], np[2]) < -HYST:
					contained = false
					break
			if contained:
				found = {"fid": fid, "to": to, "x": x, "y": base_y, "z": base_z, "np": np}
				break
		if not found.is_empty():
			break
	_ok(not found.is_empty(), "G-CROSS-CONTINUITY: could not find a normal deep contained crossing point — atlas/probe changed")
	if found.is_empty():
		return
	var fid: int = found["fid"]
	var to: int = found["to"]
	var x: float = found["x"]
	var y: float = found["y"]
	var z: float = found["z"]
	var np: Array = found["np"]

	var xb: Basis = FA.crossing_basis(fid, to)
	var axis_local: Vector3 = xb.get_rotation_quaternion().normalized().get_axis()
	_ok(absf(axis_local.y) < 0.2,
		"crossing_basis rotation axis is not tangent to the facet (y-component %.3f) — not a genuine ridge axis" % axis_local.y)
	var yaw_along := atan2(-axis_local.x, -axis_local.z)

	_check_crossing_case(fid, to, x, y, z, np, yaw_along, "along-ridge", true)
	_check_crossing_case(fid, to, x, y, z, np, yaw_along + PI / 2.0, "across-ridge", false)

## `yaw_after` uses the SHIPPED default twist convention (FP_TWIST_FRAME_AWARE off, FP_CROSS_KEEP_HEADING off,
## FP_FIXED_FRAME off ⇒ this gate's own flag config): `reframe_twist` falls through to `+yaw_delta` in that case
## (player.gd's `reframe_twist`) — matches what a real `apply_reframe` call would compute here.
func _check_crossing_case(fid: int, to: int, x: float, y: float, z: float, np: Array, yaw: float, label: String, expect_continuous: bool) -> void:
	TC.set_active_facet(fid)
	var b0_before := FA.frame_basis(fid) * Basis(Vector3(0, 1, 0), yaw)
	var w_before := FA.lattice_to_world64(fid, x, y, z)
	var u_r_before := Vector3(w_before[0], w_before[1], w_before[2]).normalized()
	var phi_before := PlayerCls.cam_rl_phi_raw(u_r_before, b0_before.x, b0_before.y)
	var rolled_before := b0_before * Basis(Vector3(0, 0, 1), PlayerCls._CAM_RL_SIGN * phi_before)
	var u_screen_before: Vector3 = rolled_before.y
	var f_before: Vector3 = -b0_before.z

	var ex: Vector3 = FA.crossing_basis(fid, to) * Vector3(1.0, 0.0, 0.0)
	var yaw_delta := atan2(ex.z, ex.x)
	var yaw_after := yaw + yaw_delta                     # shipped default twist (see doc comment above)
	TC.set_active_facet(to)
	var b0_after := FA.frame_basis(to) * Basis(Vector3(0, 1, 0), yaw_after)
	var w_after := FA.lattice_to_world64(to, np[0], np[1], np[2])
	var u_r_after := Vector3(w_after[0], w_after[1], w_after[2]).normalized()
	var phi_after := PlayerCls.cam_rl_phi_raw(u_r_after, b0_after.x, b0_after.y)
	var rolled_after := b0_after * Basis(Vector3(0, 0, 1), PlayerCls._CAM_RL_SIGN * phi_after)
	var u_screen_after: Vector3 = rolled_after.y
	var f_after: Vector3 = -b0_after.z

	var f_jump_deg := rad_to_deg(f_before.angle_to(f_after))
	var roll_jump_deg := rad_to_deg(u_screen_before.angle_to(u_screen_after))
	print("  G-CROSS-CONTINUITY-%s: fid=%d->%d f_jump=%.3f° screen-up_jump=%.3f°" % [label.to_upper(), fid, to, f_jump_deg, roll_jump_deg])
	TC.set_active_facet(fid)
	if expect_continuous:
		# Sanity on the CONSTRUCTION (not the claim under test): yaw_along_ridge is solved from the (x,z)
		# in-plane part of the rotation axis, ignoring its small y-component (measured ~0.2° residual) — a
		# looser bound than the actual claim below, which is what §5.4 arm 4 asserts.
		_ok(f_jump_deg < 0.5,
			"along-ridge gaze: forward direction jumped %.3f° (expected <0.5° — yaw_along_ridge construction broken)" % f_jump_deg)
		_ok(roll_jump_deg < 0.05,
			"along-ridge gaze: displayed screen-up jumped %.3f° (expected <0.05° — the roll should absorb the whole crossing snap here)" % roll_jump_deg)
	else:
		_ok(f_jump_deg > 1.0,
			"across-ridge gaze: forward direction did not jump (%.3f°) — not a genuine across-ridge sample" % f_jump_deg)
		# The roll cannot fix a forward-direction jump — this is the accepted, undocumented-by-roll residue
		# (§5.2's "net claim, stated honestly"). No upper bound asserted here; the case is recorded for the record.

# ============================================================ arm 6 (heal composition) ============================
## With FP_UPVECTOR_FACET_HEAL also ON: at a live TILT_H equilibrium, the roll must read the POST-heal (owner)
## basis, not the stale one — a §1.6-sized residual (a few degrees at most), never left un-healed or magnified.
func _gate_heal_composition() -> void:
	if not CubeSphere.FP_UPVECTOR_FACET_HEAL:
		print("  SKIP G-HEAL-COMPOSITION: requires FP_UPVECTOR_FACET_HEAL also ON for this arm")
		return
	var wm := WorldManager.new(); wm.name = "CamRLHealWM"; get_root().add_child(wm)
	var tilt := _find_tilt_h()
	_ok(not tilt.is_empty(), "G-HEAL-COMPOSITION: could not find a live TILT_H equilibrium — atlas/probe changed")
	if tilt.is_empty():
		wm.queue_free()
		return
	var fid: int = tilt["fid"]
	var owner: int = tilt["owner"]
	TC.set_active_facet(fid)
	wm._cross_cooldown = 0
	var pos := Vector3(tilt["x"], tilt["y"], tilt["z"])
	var w_pos := FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
	var u_r := Vector3(w_pos[0], w_pos[1], w_pos[2]).normalized()
	var b0_stale := FA.frame_basis(fid)
	var phi_stale := PlayerCls.cam_rl_phi_raw(u_r, b0_stale.x, b0_stale.y)
	var heal := wm.maybe_cross_facet(pos, 0.0, true)
	_ok(not heal.is_empty(), "G-HEAL-COMPOSITION: heal did not commit at the TILT_H point")
	if not heal.is_empty():
		var now := TC.active_facet()
		_ok(now == owner, "healed to %d, expected owner %d" % [now, owner])
		var b0_healed := FA.frame_basis(now)
		var phi_healed := PlayerCls.cam_rl_phi_raw(u_r, b0_healed.x, b0_healed.y)
		print("  G-HEAL-COMPOSITION: fid=%d owner=%d |phi_pre-heal_basis|=%.3f° |phi_post-heal_basis|=%.3f°" % [
			fid, owner, rad_to_deg(absf(phi_stale)), rad_to_deg(absf(phi_healed))])
		_ok(rad_to_deg(absf(phi_healed)) <= 3.0,
			"post-heal phi (%.3f°) exceeds the §1.6 residual bound (~2.6° corner max, 3.0° generous) — the roll is not reading the post-heal (owner) basis" % rad_to_deg(absf(phi_healed)))
		TC.set_active_facet(fid)
	wm.queue_free()

## Port of probe_upvector_tilt.gd's `_place_at_own` + TILT_H classification (see verify_upvector_heal.gd — same
## technique, duplicated here so this gate has no cross-file dependency on it).
func _place_at_own(fid: int, px: float, pz: float, dtarget: float) -> Dictionary:
	var y := 64.0
	var x := px
	var z := pz
	for _it in range(3):
		var pl: PackedFloat64Array = FA.seam_planes_f64(fid)
		var best_slot := -1
		var best := INF
		for slot in range(4):
			var s: float = FA.own_dist(fid, slot, x, y, z)
			if s < best:
				best = s
				best_slot = slot
		var A := pl[best_slot * 4 + 0]
		var C := pl[best_slot * 4 + 2]
		var gh := sqrt(A * A + C * C)
		if gh < 1e-9:
			return {}
		x += (dtarget - best) * A / (gh * gh)
		z += (dtarget - best) * C / (gh * gh)
		var xi := int(floor(x))
		var zi := int(floor(z))
		var g: float = float(int(TC.column_profile(xi, zi).x))
		y = g + 1.0
	var xi2 := int(floor(x))
	var zi2 := int(floor(z))
	var g2 := float(int(TC.column_profile(xi2, zi2).x))
	return {"x": x, "y": g2 + 1.0, "z": z, "xi": xi2, "zi": zi2, "gy": g2}

func _find_tilt_h() -> Dictionary:
	var fids := [1356, 348, 0, 300, 1000, 2000, 3000, 3455]
	var wm := WorldManager.new(); wm.name = "CamRLTiltHuntWM"; get_root().add_child(wm)
	for fid: int in fids:
		TC.set_active_facet(fid)
		var corners := []
		for ci in range(4):
			var wc: Array = FA.facet_planar_corner(fid, ci)
			corners.append(FA.world_to_lattice64(fid, wc[0], wc[1], wc[2]))
		for e in range(4):
			var c0: Array = corners[e]
			var c1: Array = corners[(e + 1) % 4]
			for ti in range(0, 41):
				var t := 0.005 + 0.99 * float(ti) / 40.0
				var px := lerpf(c0[0], c1[0], t)
				var pz := lerpf(c0[2], c1[2], t)
				for dtarget in [-0.02, -0.05, -0.08, -0.15, -0.3, -0.5]:
					var q := _place_at_own(fid, px, pz, dtarget)
					if q.is_empty():
						continue
					var qx: float = q["x"]
					var qy: float = q["y"]
					var qz: float = q["z"]
					TC.set_active_facet(fid)
					wm._cross_cooldown = 0
					var shipped := wm.maybe_cross_facet(Vector3(qx, qy, qz))
					if not shipped.is_empty():
						continue
					var xi: int = q["xi"]
					var zi: int = q["zi"]
					var gy: int = int(q["gy"])
					var soil_masked: bool = FA.cell_seam_state(fid, xi, gy, zi)["air"]
					if not soil_masked:
						continue
					var w := FA.lattice_to_world64(fid, qx, qy, qz)
					var owner := FA.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
					if owner < 0 or owner == fid:
						continue
					var tilt_deg := rad_to_deg(FA.facet_transform(fid).basis.y.angle_to(FA.facet_transform(owner).basis.y))
					if tilt_deg <= 3.5:
						continue
					wm.queue_free()
					return {"fid": fid, "owner": owner, "x": qx, "y": qy, "z": qz}
	wm.queue_free()
	return {}
