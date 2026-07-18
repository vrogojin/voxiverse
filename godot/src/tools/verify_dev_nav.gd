extends SceneTree
## COSMOS SPACE-NAV SN5 gate — G-SN-DEVNAV (docs/COSMOS-SPACE-NAV-DESIGN.md §7.3/§7.4, §10 SN5).
## Proves the dev-nav OVERLAYS + TOGGLES: the compass pure-heading function (east-at-equator == 90°, pole
## degeneracy), the O (circular-orbit release) and G (geostationary snap) commands, the R detach latch, the
## overlay build/free lifecycle + the ≤ 64 KB NEVER-OOM cap, and a re-run of the continuity theorem WITH the
## dev-flight controller active across boundaries BOTH directions (the SN-R1 proof under powered flight).
##
## The math (compass/O/G/R) is engine-free pure static (flag-independent). The overlay node test instantiates
## real nodes in this headless SceneTree (no display needed — _draw is never triggered). Byte-identity
## (flag-off == shipped) is the FLAT verify_feature (6035/0), run separately.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_dev_nav.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const DEVF := preload("res://src/cosmos/cosmos_dev_flight.gd")
const OVL := preload("res://src/player/dev_nav_overlay.gd")

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
	print("=== verify_dev_nav (COSMOS SPACE-NAV SN5: G-SN-DEVNAV — overlays + O/G/R + continuity) ===")
	print("  CubeSphere.SN_DEVNAV = %s (math is flag-independent; overlay nodes built in this SceneTree)" % str(CubeSphere.SN_DEVNAV))
	FacetAtlas.warm_up()
	_gate_compass()
	_gate_toggles()
	_gate_overlay_lifecycle()
	_gate_continuity_with_devflight()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- compass pure-heading pins (§7.3) ----------
func _gate_compass() -> void:
	print("  --- compass heading: east-at-equator == 90°, cardinals, pole degeneracy ---")
	var z := DV.v(0.0, 0.0, 1.0)                            # spin axis +Z
	var rhat := DV.v(1.0, 0.0, 0.0)                         # on the equator (r̂ ⊥ ẑ)
	# At the equator: north = +Z, east = ẑ×r̂ = +Y.
	var east := DV.v(0.0, 1.0, 0.0)
	var north := DV.v(0.0, 0.0, 1.0)
	_ok(_rel(OVL.compass_heading(z, rhat, east), 90.0) < 1.0e-9, "compass: looking EAST at the equator = 90° (the pin)")
	_ok(OVL.compass_heading(z, rhat, north) < 1.0e-9, "compass: looking NORTH (spin axis) = 0°")
	_ok(_rel(OVL.compass_heading(z, rhat, DV.v(0.0, 0.0, -1.0)), 180.0) < 1.0e-9, "compass: looking SOUTH = 180°")
	_ok(_rel(OVL.compass_heading(z, rhat, DV.v(0.0, -1.0, 0.0)), 270.0) < 1.0e-9, "compass: looking WEST = 270°")
	# Pole: r̂ ∥ ẑ ⇒ north degenerate ⇒ heading returns 0 (undefined there, handled).
	_ok(OVL.compass_heading(z, DV.v(0.0, 0.0, 1.0), east) == 0.0, "compass: at the pole (r̂ ∥ ẑ) heading = 0 (degeneracy handled)")

# ---------- O / G / R toggles (§7.4) ----------
func _gate_toggles() -> void:
	print("  --- O circular-orbit release, G geostationary snap, R detach latch ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	# O: at r = 5R, a mixed look (radial+tangential) ⇒ v = v_circ · t̂, exactly circular, ⊥ r̂.
	var p := DV.v(5.0 * R, 0.0, 0.0)
	var look := DV.v(0.6, 0.8, 0.0)                         # has both radial (x) and tangential (y) parts
	var v := DEVF.release_circular(body, p, look, DV.v(0.0, 0.0, 0.0))
	var v_circ := sqrt(GRAV.gm_dyn(body) / DV.length(p))
	_ok(_rel(DV.length(v), v_circ) < 1.0e-12, "O: |v_bci| == v_circ(r) (%.4f) — exactly circular" % v_circ)
	_ok(absf(DV.dot(v, DV.scale(p, 1.0 / DV.length(p)))) < 1.0e-9, "O: v_bci ⊥ r̂ (tangential release)")
	# O degenerate look (parallel to r̂) ⇒ falls back to the current tangential heading (here east via cur_v).
	var v_deg := DEVF.release_circular(body, p, DV.v(1.0, 0.0, 0.0), DV.v(0.0, 3.0, 0.0))
	_ok(_rel(DV.length(v_deg), v_circ) < 1.0e-12 and v_deg[1] > 0.0, "O: degenerate look keeps the current tangential heading (east)")

	# G: geostationary snap preserves longitude, lands at r_geo, v = ω⃗×p (circular + scene-stationary).
	var pg := DV.v(8.0 * R, 8.0 * R, 0.0)                   # longitude 45°, r = 8√2·R
	var snap := DEVF.geostationary_snap(body, pg)
	_ok(snap.size() == 2, "G: geostationary snap returns a state for Earth (has a stationary orbit)")
	if snap.size() == 2:
		var p_new: PackedFloat64Array = snap[0]
		var v_new: PackedFloat64Array = snap[1]
		var r_geo := NAV.r_geo_dyn(body)
		_ok(_rel(DV.length(p_new), r_geo) < 1.0e-9, "G: lands at r_geo = %.0f" % r_geo)
		_ok(_rel(atan2(p_new[1], p_new[0]), atan2(pg[1], pg[0])) < 1.0e-9, "G: longitude preserved (45°)")
		var omega_p := ORB.omega_cross(body, p_new)
		_ok(DV.length(DV.sub(v_new, omega_p)) < 1.0e-9, "G: |v − ω⃗×p| < 1e-9 (exactly geostationary)")
		var vf: PackedFloat64Array = ORB.bci_to_fixed(body, 0.0, p_new, v_new)[1]
		_ok(DV.length(vf) < 1.0e-9, "G: scene-stationary (|v_fix| < 1e-9)")
	# G over the Moon: no selenostationary orbit (r_geo > SOI) ⇒ empty ("none").
	var moon_snap := DEVF.geostationary_snap("moon", DV.v(2.0 * EPH.radius_of("moon"), 0.0, 0.0))
	_ok(moon_snap.is_empty(), "G: Moon has NO stationary orbit ⇒ snap returns 'none' (empty)")

	# R: the NavState detach latch forces DEEP_SPACE expression from HIGH_ORBIT until cleared (§4.5/§7.4).
	var r_geo2 := NAV.r_geo_dyn(body)
	var pr := DV.v(r_geo2, 0.0, 0.0)
	var vr := ORB.omega_cross(body, pr)                     # a HIGH_ORBIT (geostationary) state
	var ns := NAV.NavState.new()
	ns.mode = NAV.HIGH_ORBIT
	_ok(ns.toggle_r_latch() == true, "R: toggle sets the detach latch")
	ns.tick(body, pr, vr, 0.0, 1.0 / 60.0)
	_ok(NAV.classify(body, pr, vr, 0.0, NAV.HIGH_ORBIT, ns.r_latch) == NAV.DEEP_SPACE, "R: latched HIGH_ORBIT expresses DEEP_SPACE")
	_ok(ns.toggle_r_latch() == false, "R: toggle again clears the latch")

# ---------- overlay build / free lifecycle + the ≤ 64 KB cap (§9) ----------
func _gate_overlay_lifecycle() -> void:
	print("  --- overlay: build creates nodes, free removes them, bytes ≤ 64 KB cap ---")
	var R := GRAV.r_vox("earth")
	var ovl := OVL.new()
	get_root().add_child(ovl)
	var world := Node3D.new()
	get_root().add_child(world)
	_ok(not ovl.is_built(), "overlay: not built before F")
	ovl.build(world, R)
	_ok(ovl.is_built(), "overlay: build() instantiates the guide set")
	# Add the max facet-border loops (9 facets × a 4-vertex loop) to stress the cap.
	var loops: Array = []
	for _f in range(9):
		loops.append(PackedVector3Array([Vector3(0, 0, 0), Vector3(R, 0, 0), Vector3(R, 0, R), Vector3(0, 0, 0)]))
	ovl.set_facet_borders(loops)
	var bytes := ovl.bytes_estimate()
	_ok(bytes > 0, "overlay: retains bounded line-mesh bytes (%d B)" % bytes)
	_ok(bytes <= OVL.OVERLAY_CAP_BYTES, "overlay: bytes %d ≤ NEVER-OOM cap %d (64 KB)" % [bytes, OVL.OVERLAY_CAP_BYTES])
	ovl.update_hud(90.0, "low_orbit")                       # per-frame scalar update (no alloc, no crash)
	ovl.free_overlays()
	_ok(not ovl.is_built() and ovl.bytes_estimate() == 0, "overlay: free_overlays() releases everything (bytes → 0)")
	ovl.queue_free()
	world.queue_free()

# ---------- G-SN-CONT WITH dev-flight active (SN-R1 across every boundary, both directions) ----------
func _gate_continuity_with_devflight() -> void:
	print("  --- SN-R1 under powered flight: |Δv| ≤ DEV_ACCEL·dt across all flips, ascent AND descent ---")
	var body := "earth"
	var R := GRAV.r_vox(body)
	var dt := 1.0 / 60.0
	var step_bound := DEVF.DEV_ACCEL * dt
	var p := DV.v(R + 50.0, 0.0, 0.0)
	var v := ORB.omega_cross(body, p)
	var ns := NAV.NavState.new()
	ns.mode = NAV.PLANETARY
	var t := 0.0
	var worst_dv := 0.0
	var worst_flip_dv := 0.0
	var up_flips := 0
	var down_flips := 0
	var reached_deep := false
	var ascending := true
	var tick := 0
	while tick < 400000:
		var rhat := DV.scale(p, 1.0 / DV.length(p))
		var wish := rhat if ascending else DV.scale(rhat, -1.0)   # climb out, then descend back
		var mode := int(ns.mode)
		var cap := DEVF.speed_cap(mode, body, p, t, true)
		var v_prev := PackedFloat64Array([v[0], v[1], v[2]])
		var out := DEVF.step(mode, body, p, v, t, dt, wish, cap)
		p = out[0]; v = out[1]
		worst_dv = maxf(worst_dv, DV.length(DV.sub(v, v_prev)))
		var prev := ns.mode
		ns.tick(body, p, v, t, dt)
		if ns.mode != prev:
			worst_flip_dv = maxf(worst_flip_dv, DV.length(DV.sub(v, v_prev)))
			if ascending: up_flips += 1
			else: down_flips += 1
		if ascending and ns.mode == NAV.DEEP_SPACE:
			reached_deep = true
			ascending = false                               # turn around and descend
		# End the descent when the machine has actually re-committed PLANETARY (crossed every band back down),
		# not at a fixed altitude. The PLANETARY↔LOW divide is the atmosphere ceiling (h=384±32) with a 2-s
		# dwell; at the Earth/1000 scale the descent is ~2× faster, so that dwell now commits ~h=72 — below the
		# old fixed R+200 cutoff, which would end the loop before the final flip registered. R+5 is a safety floor.
		if not ascending and (ns.mode == NAV.PLANETARY or DV.length(p) <= R + 5.0):
			break
		t += dt
		tick += 1
	_ok(reached_deep, "continuity: powered ascent reached DEEP_SPACE (up flips = %d)" % up_flips)
	_ok(up_flips >= 3 and down_flips >= 3, "continuity: crossed every boundary BOTH ways (up=%d, down=%d)" % [up_flips, down_flips])
	_ok(worst_dv <= step_bound + 1.0e-9, "continuity: |Δv| ≤ DEV_ACCEL·dt at every tick (worst=%.6f, bound=%.6f)" % [worst_dv, step_bound])
	_ok(worst_flip_dv <= step_bound + 1.0e-9, "continuity: flip-tick |Δv| ≤ bound (worst flip=%.6f) — SN-R1 holds under dev-flight" % worst_flip_dv)
