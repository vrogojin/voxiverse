extends SceneTree
## COSMOS-ORBITAL-SHELL gate (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3/§9) — proves the "far hemisphere blank from
## orbit" fix (FP_SHELL_CAMERA_SET / FP_SHELL_PREWARM). The shipped far ring emits only the hemisphere around the
## player's ACTIVE FACET normal and refreshes it on surface crossings; off-surface the camera radial drifts across
## facets with no crossing, so the emitted hemisphere stays pinned near the departure region and the far side is
## ABSENT from the mesh. S1 drives the emit cull axis from the CAMERA radial direction ĉ with an altitude-derived
## cap θ_emit, re-emitted on angular drift. This gate exercises the S1 law directly via shell_set_camera_abs (the
## flag-independent core; the driver apply_camera_set is what the FP flag gates), then falsifies the OLD active-
## facet law at the spawn ANTIPODE.
##
##   G-SHELL-COVER    multi-altitude × multi-longitude sweep: every facet containing a direction inside the visible
##                    cap θ_h of ĉ is emitted (zero misses), INCLUDING the spawn antipode.
##   G-SHELL-ANTIPODE camera over the antipode at LEO ⇒ the visible cap is fully emitted; and the SHIPPED active-
##                    facet law FAILS the same check (the direct regression for "far side blank").
##   G-SHELL-BOUND    worst-case emitted mesh ≤ the 96°-cap tri budget at every altitude; coarse cache ≤ 6·K² (NEVER-OOM).
##   G-SHELL-NOPOP    containment at swap (the OLD set still covers the NEW visible cap) + every set change happens
##                    behind the limb (a changed facet is outside the visible cap at the ĉ where it is absent).
##   G-SHELL-BYTEOFF  _cam_set false ⇒ visible_fids is byte-identical to the shipped active-facet law; apply_camera_set
##                    does NOT engage with FP_SHELL_CAMERA_SET off; the floored surface set differs only behind the limb.
##   G-SHELL-LIMB     the relief margin is actually applied: facets out to θ_h + SHELL_RELIEF_DEG are emitted (limb peaks).
##   G-SHELL-PREWARM  (only when FP_SHELL_PREWARM) the one-shot whole-planet warm fills ≤ 6·K² coarse caches, is dwell-gated
##                    and idempotent (NEVER-OOM: no parallel store, bounded by fid).
##
## RUN (S1 + S2, flags on):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_SHELL_CAMERA_SET := false/const FP_SHELL_CAMERA_SET := true/;s/const FP_SHELL_PREWARM := false/const FP_SHELL_PREWARM := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_shell.gd
##   then REVERT the sed. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

var _pass := 0
var _fail := 0
var _centres: Array = []          # precomputed facet-centre unit directions (Vector3), indexed by fid
var _R := 0.0

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_shell (orbital shell: camera-set far ring — the far-hemisphere-from-orbit fix) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	_R = FA.R_BLOCKS
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	_precompute_centres()
	print("  atlas: k=%d, R=%.0f, active(spawn)=%d, OFFSURFACE_Y=%.0f, CAP_MAX=%.0f°, RELIEF=%.0f°, SLACK=%.0f°, CAMERA_SET=%s, PREWARM=%s" % [
		FA.K, _R, active, CubeSphere.OFFSURFACE_Y, CubeSphere.SHELL_CAP_MAX_DEG,
		CubeSphere.SHELL_RELIEF_DEG, CubeSphere.SHELL_SLACK_DEG, str(CubeSphere.FP_SHELL_CAMERA_SET), str(CubeSphere.FP_SHELL_PREWARM)])
	_gate_cover(active)
	_gate_antipode(active)
	_gate_bound(active)
	_gate_nopop(active)
	_gate_byteoff(active)
	_gate_limb(active)
	if CubeSphere.FP_SHELL_PREWARM:
		_gate_prewarm(active)
	else:
		print("  (G-SHELL-PREWARM skipped — sed FP_SHELL_PREWARM = true to run S2)")
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------- geometry helpers (independent of the ring's private methods → a true oracle) ----------------

func _precompute_centres() -> void:
	var k := FA.K
	_centres.resize(6 * k * k)
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				_centres[fid] = _centre_dir(fid)

func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(c[0], c[1], c[2])
	return s.normalized()

## The facet the unit direction `d` belongs to (the SAME classifier worldgen/physics use).
func _facet_of(d: Vector3) -> int:
	return FA.facet_of_dir(CubeSphere.DVec3.new(d.x, d.y, d.z))

## An orthonormal pair spanning the plane ⊥ ĉ (for cap sampling / drifting ĉ).
func _perp(c: Vector3) -> Array:
	var up := Vector3(0, 1, 0) if absf(c.y) < 0.9 else Vector3(1, 0, 0)
	var e1 := up.cross(c).normalized()
	var e2 := c.cross(e1).normalized()
	return [e1, e2]

## Unit direction at angular distance `ang` from ĉ, azimuth `phi`.
func _dir_at(c: Vector3, e1: Vector3, e2: Vector3, ang: float, phi: float) -> Vector3:
	return (cos(ang) * c + sin(ang) * (cos(phi) * e1 + sin(phi) * e2)).normalized()

func _theta_h(d: float) -> float:
	return acos(clampf(_R / maxf(d, _R), -1.0, 1.0))

func _theta_emit(d: float, floored: bool) -> float:
	var te := minf(_theta_h(d) + deg_to_rad(CubeSphere.SHELL_RELIEF_DEG + CubeSphere.SHELL_SLACK_DEG),
			deg_to_rad(CubeSphere.SHELL_CAP_MAX_DEG))
	if floored:
		te = maxf(te, deg_to_rad(90.0))
	return te

## Engage the camera-set law at (ĉ, d, floored), rebuild, and return the emitted set as a {fid:true} dict.
func _emit_set(ring: Node3D, c: Vector3, d: float, floored: bool) -> Dictionary:
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], d, floored)
	ring.call("force_rebuild")
	var vis: PackedInt32Array = ring.call("visible_fids")
	var s := {}
	for f in vis:
		s[int(f)] = true
	return s

## The six well-separated test longitudes: the spawn normal, its ANTIPODE, and ±the two perpendiculars.
func _test_axes(active: int) -> Array:
	var nrm := FA.facet_normal64(active)
	var n := Vector3(nrm[0], nrm[1], nrm[2]).normalized()
	var pe := _perp(n)
	return [n, -n, pe[0], -pe[0], pe[1], -pe[1]]

# ---------------- G-SHELL-COVER ----------------
func _gate_cover(active: int) -> void:
	print("  --- G-SHELL-COVER: the visible cap is fully emitted at every altitude × longitude (incl. antipode) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	# With FP_FARRING_FULL_COVER off (this gate), _front_visible legitimately skips the ACTIVE facet — the near voxel
	# world / the FULL_COVER backstop covers the sub-camera facet, and that is never the far-hemisphere-blank bug. So
	# the coverage oracle excludes the active facet (it is emitted-as-backstop under FULL_COVER, the deployed config).
	var alts := [500.0, 2000.0, 8000.0, 30000.0, 200000.0]
	var axes := _test_axes(active)
	var total_miss := 0            # oracle (a) sampled-point misses (a facet containing a visible dir not emitted)
	var interior_miss := 0        # sampled-point misses NOT at the extreme limb (fr ≤ 0.9 — a real far-side hole)
	var centre_miss := 0          # oracle (b) misses (a facet whose CENTRE is inside the visible cap not emitted — the direct far-side-blank regression)
	var total_checked := 0
	var worst := ""
	for h in alts:
		var d: float = _R + h
		var th := _theta_h(d)
		var te := _theta_emit(d, false)
		for c in axes:
			var emitted := _emit_set(ring, c, d, h < CubeSphere.OFFSURFACE_Y)
			var pe := _perp(c)
			# (a) sampled-direction oracle: every facet CONTAINING a direction inside the visible cap is emitted.
			for fr in [0.0, 0.3, 0.6, 0.85, 0.98]:
				var ang: float = th * fr
				var naz := 1 if fr == 0.0 else 12
				for ai in range(naz):
					var phi := TAU * float(ai) / float(naz)
					var p := _dir_at(c, pe[0], pe[1], ang, phi)
					var fid := _facet_of(p)
					if fid == active:
						continue                  # active facet covered by near voxels / FULL_COVER backstop (not the shell's cap)
					total_checked += 1
					if not emitted.has(fid):
						total_miss += 1
						if fr <= 0.9:
							interior_miss += 1
						var cang := rad_to_deg(acos(clampf((_centres[fid] as Vector3).dot(c), -1.0, 1.0)))
						if worst == "" or cang > 0.0:
							worst = "h=%.0f fr=%.2f facet=%d centre@%.2f° (θ_h=%.2f° θ_emit=%.2f°)" % [h, fr, fid, cang, rad_to_deg(th), rad_to_deg(te)]
			# (b) centre oracle: every facet whose CENTRE is inside the visible cap is emitted.
			var cosb := cos(th)
			for fid2 in range(_centres.size()):
				if fid2 == active:
					continue                      # active facet excluded (see above)
				var cv: Vector3 = _centres[fid2]
				if cv.dot(c) >= cosb:
					total_checked += 1
					if not emitted.has(fid2):
						centre_miss += 1
	# The far-side-blank regression is oracle (b) (centre inside the visible cap) + interior sampled points: those must be ZERO.
	# The extreme-limb rim (fr=0.98, at the saturated 96° cap) may nick a silhouette sliver — the design's accepted ≤4px limb nick.
	_ok(centre_miss == 0, "G-SHELL-COVER: 0 facet-CENTRE misses inside the visible cap (the direct far-side-blank regression); got %d" % centre_miss)
	_ok(interior_miss == 0, "G-SHELL-COVER: 0 interior (fr ≤ 0.9) sampled-point misses; got %d" % interior_miss)
	_ok(total_miss == 0, "G-SHELL-COVER: %d visible-cap samples across %d alt×lon states, %d misses (%d at the extreme fr=0.98 limb rim). worst: %s" % [total_checked, alts.size() * axes.size(), total_miss, total_miss - interior_miss, worst])
	ring.free()

# ---------------- G-SHELL-ANTIPODE (+ falsify the shipped law) ----------------
func _gate_antipode(active: int) -> void:
	print("  --- G-SHELL-ANTIPODE: LEO over the spawn antipode is covered; the SHIPPED active-facet law FAILS ---")
	var nrm := FA.facet_normal64(active)
	var n := Vector3(nrm[0], nrm[1], nrm[2]).normalized()
	var anti := -n
	var d: float = _R + 500.0        # LEO — the pilot's repro
	var th := _theta_h(d)
	var pe := _perp(anti)
	# facets whose centres lie inside the antipode visible cap (what MUST be drawn).
	var cap_fids := []
	var cosb := cos(th)
	for fid in range(_centres.size()):
		if (_centres[fid] as Vector3).dot(anti) >= cosb:
			cap_fids.append(fid)
	# FIX: the camera-set law emits every antipode-cap facet.
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var emitted := _emit_set(ring, anti, d, false)
	var fix_miss := 0
	for fid in cap_fids:
		if not emitted.has(int(fid)):
			fix_miss += 1
	_ok(fix_miss == 0, "G-SHELL-ANTIPODE: camera-set emits all %d antipode-cap facets (%d missing)" % [cap_fids.size(), fix_miss])
	ring.free()
	# FALSIFY: the SHIPPED active-facet law (no camera-set engaged) leaves the antipode cap BLANK.
	var old: Node3D = FFR.new()
	get_root().add_child(old)
	old.call("setup", active)
	old.call("force_rebuild")                 # shipped law: hemisphere around facet_normal64(active) — never engaged camera-set
	var oldvis: PackedInt32Array = old.call("visible_fids")
	var oldset := {}
	for f in oldvis:
		oldset[int(f)] = true
	var old_miss := 0
	for fid in cap_fids:
		if not oldset.has(int(fid)):
			old_miss += 1
	_ok(not bool(old.call("shell_cam_set")), "G-SHELL-ANTIPODE: shipped ring never engaged the camera-set law")
	_ok(old_miss == cap_fids.size() and cap_fids.size() > 0,
		"G-SHELL-ANTIPODE (falsify): shipped active-facet law misses ALL %d antipode-cap facets (missed %d) — the far side is blank" % [cap_fids.size(), old_miss])
	old.free()

# ---------------- G-SHELL-BOUND ----------------
func _gate_bound(active: int) -> void:
	print("  --- G-SHELL-BOUND: emitted mesh within the 96°-cap tri budget; coarse cache ≤ 6·K² (NEVER-OOM) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	# worst case: the highest altitude saturates the 96° cap. The analytic cap N(θ) = 6·K²·(1 − cos θ)/2 facets.
	var n: Vector3 = _test_axes(active)[0]
	var d: float = _R + 200000.0
	var emitted := _emit_set(ring, n, d, false)
	var tris := int(ring.call("triangle_count"))
	var whole_planet := 6 * FA.K * FA.K * FFR.CELLS * FFR.CELLS * 2
	# analytic facet cap at the emit cap angle (96° here — θ_emit saturates), + a half-facet-ring slack for straddlers.
	var cap_ang := _theta_emit(d, false)
	var n_cap := int(ceil(6.0 * float(FA.K * FA.K) * (1.0 - cos(cap_ang)) / 2.0))
	var slack := 6 * FA.K   # a generous one-facet-wide perimeter allowance
	var tri_bound := (n_cap + slack) * FFR.CELLS * FFR.CELLS * 2
	_ok(tris == emitted.size() * FFR.CELLS * FFR.CELLS * 2, "G-SHELL-BOUND: tris %d == emitted %d × %d (CELLS consistency)" % [tris, emitted.size(), FFR.CELLS * FFR.CELLS * 2])
	_ok(tris <= tri_bound, "G-SHELL-BOUND: tris %d ≤ 96°-cap bound %d (N(96°)=%d facets + %d slack)" % [tris, tri_bound, n_cap, slack])
	_ok(tris <= whole_planet, "G-SHELL-BOUND: tris %d ≤ whole-planet cap %d (one draw)" % [tris, whole_planet])
	_ok(int(ring.call("coarse_cache_size")) <= 6 * FA.K * FA.K, "G-SHELL-BOUND: coarse cache %d facets ≤ 6·K² = %d (fixed fid-keyed ceiling)" % [int(ring.call("coarse_cache_size")), 6 * FA.K * FA.K])
	_ok(int(ring.call("backstop_cache_size")) == 0, "G-SHELL-BOUND: no dense backstop cache (FULL_COVER off in this gate ⇒ zero extra bytes)")
	print("    BOUND worst-case (h=200000, θ_emit=%.1f°): %d tris across %d facets, whole-planet cap %d" % [rad_to_deg(cap_ang), tris, emitted.size(), whole_planet])
	ring.free()

# ---------------- G-SHELL-NOPOP ----------------
func _gate_nopop(active: int) -> void:
	print("  --- G-SHELL-NOPOP: containment at swap + every set change is behind the limb ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var d: float = _R + 4000.0                 # mid orbit — a real re-emit cadence
	var th := _theta_h(d)
	var c0: Vector3 = _test_axes(active)[2]    # an off-axis longitude
	var pe := _perp(c0)
	var set0 := _emit_set(ring, c0, d, false)
	# drift ĉ by 14° (just past the 13° re-emit trigger) about e1.
	var drift := deg_to_rad(14.0)
	var c1 := _dir_at(c0, pe[0], pe[1], drift, 0.0)
	# (1) CONTAINMENT: BEFORE the re-emit lands, the OLD set0 still covers the NEW visible cap of ĉ1 (no hole
	#     during the ≤1-build async latency). Assert every facet whose centre is inside θ_h(ĉ1) is in set0.
	var cosb := cos(th)
	var contain_miss := 0
	var contain_checked := 0
	for fid in range(_centres.size()):
		var cv: Vector3 = _centres[fid]
		if cv.dot(c1) >= cosb:
			contain_checked += 1
			if not set0.has(fid):
				contain_miss += 1
	_ok(contain_miss == 0, "G-SHELL-NOPOP: OLD set contains the NEW visible cap (%d facets, %d holes at swap)" % [contain_checked, contain_miss])
	# (2) BEHIND-THE-LIMB: re-emit to ĉ1; every facet that entered/left is outside the visible cap at the ĉ where it is absent.
	var set1 := _emit_set(ring, c1, d, false)
	var changed_ok := true
	var left := 0
	var entered := 0
	for fid in set0.keys():
		if not set1.has(fid):                 # LEFT the set (dropped) → must be outside θ_h of ĉ1 (invisible now)
			left += 1
			if (_centres[int(fid)] as Vector3).dot(c1) >= cosb:
				changed_ok = false
	for fid in set1.keys():
		if not set0.has(fid):                 # ENTERED the set → was outside θ_h of ĉ0 before (was invisible)
			entered += 1
			if (_centres[int(fid)] as Vector3).dot(c0) >= cosb:
				changed_ok = false
	_ok(changed_ok, "G-SHELL-NOPOP: every set change (%d entered, %d left) happens outside the visible cap (behind the limb)" % [entered, left])
	_ok(entered + left > 0, "G-SHELL-NOPOP: the 14° drift did fire a real re-emit (set changed by %d facets)" % [entered + left])
	ring.free()

# ---------------- G-SHELL-BYTEOFF ----------------
func _gate_byteoff(active: int) -> void:
	print("  --- G-SHELL-BYTEOFF: _cam_set false == shipped law; driver gated by the flag; floored surface behind-limb-only ---")
	# (1) _cam_set false ⇒ visible_fids is EXACTLY the shipped active-facet-normal + BACK_CULL set (byte-identical).
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("force_rebuild")
	var vis: PackedInt32Array = ring.call("visible_fids")
	var got := {}
	for f in vis:
		got[int(f)] = true
	var nrm := FA.facet_normal64(active)
	var nv := Vector3(nrm[0], nrm[1], nrm[2])
	var ref_miss := 0
	var ref_extra := 0
	for fid in range(_centres.size()):
		var want := (_centres[fid] as Vector3).dot(nv) >= FFR.BACK_CULL and fid != active
		if want and not got.has(fid):
			ref_miss += 1
		if got.has(fid) and not want:
			ref_extra += 1
	_ok(not bool(ring.call("shell_cam_set")), "G-SHELL-BYTEOFF: _cam_set is false before any camera-set drive")
	_ok(ref_miss == 0 and ref_extra == 0, "G-SHELL-BYTEOFF: visible_fids == shipped active-facet law (miss %d, extra %d)" % [ref_miss, ref_extra])
	# (2) apply_camera_set must NOT engage the law when FP_SHELL_CAMERA_SET is off (the driver, not the core, gates the flag).
	var base := FA.facet_transform(active).affine_inverse()
	var cam_orbit: Vector3 = base * (nv * (_R + 5000.0))     # a render-frame camera 5 k above the active facet
	ring.call("apply_camera_set", cam_orbit)
	if CubeSphere.FP_SHELL_CAMERA_SET:
		_ok(bool(ring.call("shell_cam_set")), "G-SHELL-BYTEOFF: flag ON ⇒ apply_camera_set engages the law")
	else:
		_ok(not bool(ring.call("shell_cam_set")), "G-SHELL-BYTEOFF: flag OFF ⇒ apply_camera_set does NOT engage (byte-identical)")
	ring.free()
	# (3) FLOORED SURFACE (flag-ON regime): θ_emit ≥ 90° near the surface, so the ĉ-set differs from the active-facet
	#     hemisphere ONLY in facets behind the limb (occluded) — byte-VISUALLY identical. Drive at h just above 0.
	var ring2: Node3D = FFR.new()
	get_root().add_child(ring2)
	ring2.call("setup", active)
	var ds: float = _R + 2.0                                  # ~2 blocks up, on foot
	var ths := _theta_h(ds)                                   # ≈ 2°
	# camera radial ≈ the active-facet normal on the surface; use the active normal as ĉ (a facet-centred stand-in).
	var camset := _emit_set(ring2, nv, ds, true)             # floored = true
	# reference shipped hemisphere (active-facet law).
	var shipped := {}
	for fid in range(_centres.size()):
		if (_centres[fid] as Vector3).dot(nv) >= FFR.BACK_CULL and fid != active:
			shipped[fid] = true
	# any facet in the symmetric difference must lie BEHIND the limb (angle from ĉ > θ_h ⇒ occluded by the body).
	var vis_diff_bad := 0
	var diff_total := 0
	var cosb := cos(ths)
	for fid in camset.keys():
		if not shipped.has(fid):
			diff_total += 1
			if (_centres[int(fid)] as Vector3).dot(nv) >= cosb:
				vis_diff_bad += 1
	for fid in shipped.keys():
		if not camset.has(fid):
			diff_total += 1
			if (_centres[int(fid)] as Vector3).dot(nv) >= cosb:
				vis_diff_bad += 1
	_ok(vis_diff_bad == 0, "G-SHELL-BYTEOFF: floored-surface set differs from shipped only behind the limb (%d diffs, %d inside the visible cap)" % [diff_total, vis_diff_bad])
	ring2.free()

# ---------------- G-SHELL-LIMB ----------------
func _gate_limb(active: int) -> void:
	print("  --- G-SHELL-LIMB: the relief margin is applied — facets out to θ_h + SHELL_RELIEF_DEG are emitted ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var relief := deg_to_rad(CubeSphere.SHELL_RELIEF_DEG)
	var axes := _test_axes(active)
	var alts := [500.0, 2000.0, 8000.0, 30000.0]   # below the 96° saturation, where θ_emit = θ_h + RELIEF + SLACK
	var miss := 0
	var checked := 0
	for h in alts:
		var d: float = _R + h
		var th := _theta_h(d)
		for c in axes:
			var emitted := _emit_set(ring, c, d, false)
			var pe := _perp(c)
			# sample the limb ring at θ_h + RELIEF (a peak of the design's relief bound just past the geometric horizon).
			var ang: float = th + relief
			for ai in range(24):
				var phi := TAU * float(ai) / 24.0
				var p := _dir_at(c, pe[0], pe[1], ang, phi)
				var fid := _facet_of(p)
				checked += 1
				if not emitted.has(fid):
					miss += 1
	_ok(miss == 0, "G-SHELL-LIMB: %d limb-ring (θ_h + %.0f°) samples emitted, %d culled (want 0)" % [checked, CubeSphere.SHELL_RELIEF_DEG, miss])
	ring.free()

# ---------------- G-SHELL-PREWARM (S2, only when FP_SHELL_PREWARM) ----------------
func _gate_prewarm(active: int) -> void:
	print("  --- G-SHELL-PREWARM: one-shot whole-planet warm — dwell-gated, ≤ 6·K², idempotent (NEVER-OOM) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var total := 6 * FA.K * FA.K
	# (1) dwell gate: below the surface ceiling the warm never arms.
	ring.set("_offsurface", false)
	for i in range(10):
		ring.call("_prewarm_step", 1.0)
	_ok(int(ring.call("prewarm_cursor")) < 0, "G-SHELL-PREWARM: on-surface ⇒ prewarm never starts (cursor %d)" % int(ring.call("prewarm_cursor")))
	# (2) off-surface but below the dwell threshold ⇒ still not started.
	ring.set("_offsurface", true)
	ring.call("_prewarm_step", CubeSphere.SHELL_PREWARM_DWELL_S * 0.5)
	_ok(int(ring.call("prewarm_cursor")) < 0, "G-SHELL-PREWARM: dwell < %.0fs ⇒ not armed yet" % CubeSphere.SHELL_PREWARM_DWELL_S)
	# (3) sustained off-surface ⇒ arms and completes over budgeted frames, filling ALL facets exactly once.
	var frames := 0
	while int(ring.call("prewarm_cursor")) < total and frames < 100000:
		ring.call("_prewarm_step", 1.0)
		frames += 1
	_ok(int(ring.call("prewarm_cursor")) >= total, "G-SHELL-PREWARM: completed one-shot warm (cursor %d ≥ %d) in %d frames" % [int(ring.call("prewarm_cursor")), total, frames])
	_ok(int(ring.call("coarse_cache_size")) == total, "G-SHELL-PREWARM: all %d facets' coarse caches warmed (size %d, no parallel store)" % [total, int(ring.call("coarse_cache_size"))])
	_ok(int(ring.call("coarse_cache_size")) <= total, "G-SHELL-PREWARM: coarse cache ≤ 6·K² = %d (fixed ceiling, NEVER-OOM)" % total)
	# (4) idempotent: further steps do not grow the cache or move the cursor.
	var csize := int(ring.call("coarse_cache_size"))
	var cur := int(ring.call("prewarm_cursor"))
	ring.call("_prewarm_step", 100.0)
	_ok(int(ring.call("coarse_cache_size")) == csize and int(ring.call("prewarm_cursor")) == cur, "G-SHELL-PREWARM: idempotent after completion (cache %d, cursor %d unchanged)" % [csize, cur])
	ring.free()
