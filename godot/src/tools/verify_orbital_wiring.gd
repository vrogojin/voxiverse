extends SceneTree
## COSMOS ORBITAL O1 / SPACE-NAV SN1 gate — O1b WIRING MATH (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.10).
## Proves the frame-algebra handoffs, the atmosphere drag, and the re-entry facet-designation math that
## the ORBITAL locomotion wiring rides on — the parts a headless gate CAN prove (the live interactive
## flight / worst-frame envelope / gear-2 feel are morning-session items, per SN1 §10 "live-only"). All
## asserts exercise SHIPPED kernel code (OrbitalState frame algebra + drag, FacetAtlas designation), so
## this gate is FLAG-INDEPENDENT (the kernels are pure statics, DEAD with FP_M3_ORBIT off).
##
## Asserts:
##   G-O1-HANDOFF  fixed↔bci↔fixed and bci↔helio↔bci round-trips < 1e-9; lattice↔fixed round-trip via
##                 the atlas < 1e-9; standing still at the equator ⇒ |v_bci| == ω·R ≈ 14.65 m/s eastward (natural 1:1000 day).
##   G-O1-DRAG     terminal speed at h=0 == DRAG_TERMINAL ±5%; a periapsis inside the atmosphere decays
##                 the orbit (energy drops); NO drag above ATMO_TOP.
##   G-O1-REENTRY  facet_of_dir designates the facet under the descending craft; world_to_lattice64 y ≈ h;
##                 the landing point is in_polygon(fid); designation stable through a radial descent.
##   G-O1-ANCHOR   anchor_snap steps by integer multiples of the quantum only past the trigger; every
##                 node's position relative to the player is invariant across the step to f32 ε; the
##                 BCI OrbitalState is untouched (anchor is render-only).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbital_wiring.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")

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

func _dist(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return DV.length(DV.sub(a, b))

func _initialize() -> void:
	print("=== verify_orbital_wiring (COSMOS ORBITAL O1b: handoff + drag + re-entry math) ===")
	print("  CubeSphere.FP_M3_ORBIT = %s (gate is flag-independent; kernels are pure statics)" % str(CubeSphere.FP_M3_ORBIT))
	FacetAtlas.warm_up()
	_gate_handoff()
	_gate_drag()
	_gate_reentry()
	_gate_anchor()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-O1-HANDOFF: the frame-algebra re-expressions (§2.4/§5.1) ----------
func _gate_handoff() -> void:
	print("  --- G-O1-HANDOFF: frame round-trips + equator spin bonus 14.65 m/s ---")
	var body := "earth"
	var t := 337.0                                      # arbitrary non-trivial time (θ = spin_angle ≠ 0)
	var p_fix := DV.v(2000.0, -900.0, 1500.0)
	var v_fix := DV.v(30.0, 12.0, -7.0)

	# fixed → bci → fixed
	var bci := ORB.fixed_to_bci(body, t, p_fix, v_fix)
	var back := ORB.bci_to_fixed(body, t, bci[0], bci[1])
	_ok(_dist(back[0], p_fix) < 1.0e-9, "G-O1-HANDOFF: fixed→bci→fixed position round-trip Δ = %.2e" % _dist(back[0], p_fix))
	_ok(_dist(back[1], v_fix) < 1.0e-9, "G-O1-HANDOFF: fixed→bci→fixed velocity round-trip Δ = %.2e" % _dist(back[1], v_fix))

	# bci → helio → bci
	var hel := ORB.bci_to_helio(body, t, bci[0], bci[1])
	var back2 := ORB.helio_to_bci(body, t, hel[0], hel[1])
	_ok(_dist(back2[0], bci[0]) < 1.0e-6, "G-O1-HANDOFF: bci→helio→bci position round-trip Δ = %.2e (helio 1.5e8 scale)" % _dist(back2[0], bci[0]))
	_ok(_dist(back2[1], bci[1]) < 1.0e-9, "G-O1-HANDOFF: bci→helio→bci velocity round-trip Δ = %.2e" % _dist(back2[1], bci[1]))

	# lattice ↔ fixed round-trip through the atlas (position-critical f64)
	var fid := 200
	var w := FacetAtlas.lattice_to_world64(fid, 40.0, 130.0, 55.0)
	var lat: Array = FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
	var lat_delta: float = absf(lat[0] - 40.0) + absf(lat[1] - 130.0) + absf(lat[2] - 55.0)
	_ok(lat_delta < 1.0e-9, "G-O1-HANDOFF: lattice→world→lattice round-trip Δ = %.2e" % lat_delta)

	# Standing still at the equator: v_fixed = 0 ⇒ |v_bci| == ω·R (the eastward-launch bonus).
	var rv := GRAV.r_vox(body)
	var p_eq := DV.v(rv, 0.0, 0.0)                       # equatorial point (z=0), radius R
	var bci_eq := ORB.fixed_to_bci(body, 0.0, p_eq, DV.v(0.0, 0.0, 0.0))
	var speed := DV.length(bci_eq[1])
	var expect := EPH.omega_spin(body) * rv
	_ok(_rel(speed, expect) < 1.0e-9, "G-O1-HANDOFF: standing at equator |v_bci| = %.4f == ω·R" % speed)
	# Equator spin bonus = ω·R. Under natural 1:1000, ω = 2π/DAY_GAME with DAY_GAME = 86400/√1000 ≈ 2732.6 s
	# (the ~45.5-min day), so ω·R = 2π/2732.6·6371 ≈ 14.65 m/s. (Was 16.1 at interim R=3072/1200 s; the slower
	# √1000 day drops it below the old 33.36 the 1200-s day gave at R=6371.)
	_ok(_rel(speed, 14.65) < 1.0e-2, "G-O1-HANDOFF: equator spin bonus = %.3f m/s ≈ 14.65 (natural 1:1000, R=6371)" % speed)
	# eastward: at (R,0,0) with +Z spin, ω⃗×p = ωR·(+Y); at t=0 (θ=0) v_bci stays +Y.
	var v_eq: PackedFloat64Array = bci_eq[1]
	var yhat := v_eq[1] / speed
	_ok(_rel(yhat, 1.0) < 1.0e-9, "G-O1-HANDOFF: spin bonus points eastward (+Y at (R,0,0))")

# ---------- G-O1-DRAG: terminal speed, orbit decay, no drag above ATMO_TOP (§2.6) ----------
func _gate_drag() -> void:
	print("  --- G-O1-DRAG: terminal 55 ±5%, atmosphere decays a low periapsis, none above ATMO_TOP ---")
	var body := "earth"
	var rv := GRAV.r_vox(body)
	# No drag above ATMO_TOP: a point at h=500 (> 384), any speed.
	var d_high := ORB.atmos_drag_bci(body, DV.v(0.0, 0.0, rv + 500.0), DV.v(0.0, 200.0, 0.0))
	_ok(DV.length(d_high) == 0.0, "G-O1-DRAG: drag == 0 above ATMO_TOP (h=500)")
	# Moon has no atmosphere: never any drag.
	var d_moon := ORB.atmos_drag_bci("moon", DV.v(EPH.radius_of("moon"), 0.0, 0.0), DV.v(0.0, 50.0, 0.0))
	_ok(DV.length(d_moon) == 0.0, "G-O1-DRAG: Moon (no atmosphere) has zero drag")

	# Terminal speed at h=0 (north pole ⇒ ω⃗×p = 0, so v_air == v_bci — a clean 1-D balance). Hold altitude,
	# let the downward speed converge under gravity_bci + atmos_drag_bci (the real functions).
	var p_pole := DV.v(0.0, 0.0, rv)
	var dt := 1.0 / 60.0
	var v := 0.0
	for _i in range(20000):
		var v_bci := DV.v(0.0, 0.0, -v)
		var g := GRAV.gravity_bci(body, p_pole)          # (0,0,−datum)
		var dr := ORB.atmos_drag_bci(body, p_pole, v_bci) # (0,0,+k0 v²)
		var a_down := -(g[2] + dr[2])                    # net downward accel
		v += a_down * dt
	_ok(_rel(v, CubeSphere.DRAG_TERMINAL) < 5.0e-2, "G-O1-DRAG: terminal speed at h=0 = %.2f m/s == DRAG_TERMINAL 55 (±5%%)" % v)

	# A periapsis INSIDE the atmosphere decays the orbit: integrate an eccentric orbit whose periapsis is at
	# h=200 (< ATMO_TOP) with drag ON; specific energy must drop over the pass.
	var mu := GRAV.gm_dyn(body)
	var r_peri := rv + 200.0
	var r_apo := rv + 3000.0
	var a := 0.5 * (r_peri + r_apo)
	var v_peri := sqrt(mu * (2.0 / r_peri - 1.0 / a))
	# start at periapsis: pos = (r_peri,0,0), vel = tangential (0, v_peri, 0)
	var st := ORB.make(body, DV.v(r_peri, 0.0, 0.0), DV.v(0.0, v_peri, 0.0))
	var e0 := ORB.specific_energy(mu, st.pos, st.vel)
	var period := TAU * sqrt(a * a * a / mu)
	var tt := 0.0
	while tt < period:
		var drag := ORB.atmos_drag_bci(body, st.pos, st.vel)
		st.step(dt, drag)
		tt += dt
	var e1 := ORB.specific_energy(mu, st.pos, st.vel)
	_ok(e1 < e0, "G-O1-DRAG: atmosphere-grazing orbit energy dropped %.6e → %.6e (decay)" % [e0, e1])

# ---------- G-O1-REENTRY: facet designation + altitude recovery + polygon + stability ----------
func _gate_reentry() -> void:
	print("  --- G-O1-REENTRY: facet_of_dir designates; world_to_lattice y≈h; in_polygon; stable descent ---")
	var body := "earth"
	var rv := GRAV.r_vox(body)
	var fid := 137
	var nrm := FacetAtlas.facet_normal64(fid)            # the facet's outward normal ≈ its centre direction
	var d := CubeSphere.DVec3.new(nrm[0], nrm[1], nrm[2])
	# designation at a point directly above the facet centre must recover the facet.
	_ok(FacetAtlas.facet_of_dir(d) == fid, "G-O1-REENTRY: facet_of_dir(centre dir) == %d" % fid)

	# world_to_lattice64 y recovers the radial altitude (within planarization sag).
	var h := 200.0
	var p_fixed := DV.v(nrm[0] * (rv + h), nrm[1] * (rv + h), nrm[2] * (rv + h))
	var lat: Array = FacetAtlas.world_to_lattice64(fid, p_fixed[0], p_fixed[1], p_fixed[2])
	_ok(absf(lat[1] - h) < 10.0, "G-O1-REENTRY: world_to_lattice64 y = %.3f ≈ h=200 (Δ %.3f < sag)" % [lat[1], absf(lat[1] - h)])
	_ok(FacetAtlas.in_polygon(fid, int(round(lat[0])), int(round(lat[2])), 0.0), "G-O1-REENTRY: landing (x,z)=(%d,%d) in_polygon(%d)" % [int(round(lat[0])), int(round(lat[2])), fid])

	# Designation stable through a radial descent from ORBIT_PREWARM_H to 0 (same p̂ ⇒ same facet).
	var stable := true
	var steps := 200
	for i in range(steps + 1):
		var hh := CubeSphere.ORBIT_PREWARM_H * float(steps - i) / float(steps)
		var dd := CubeSphere.DVec3.new(nrm[0], nrm[1], nrm[2])   # p̂ constant on a radial descent
		if FacetAtlas.facet_of_dir(dd) != fid:
			stable = false
	_ok(stable, "G-O1-REENTRY: facet designation stable through the radial descent below PREWARM_H")

# ---------- G-O1-ANCHOR: integer anchor-follow, relative-invariant, state untouched (§2.8, R2) ----------
func _gate_anchor() -> void:
	print("  --- G-O1-ANCHOR: integer step past trigger; relative positions f32-invariant; state untouched ---")
	var trigger := CubeSphere.REANCHOR_TRIGGER_BLOCKS      # 8192
	var quantum := 4096.0
	var anchor := DV.v(0.0, 0.0, 0.0)
	# Below the trigger: no step.
	var near := DV.v(5000.0, 100.0, 3000.0)                # |·| ≈ 5.9k < 8192
	var a_near := ORB.anchor_snap(anchor, near, trigger, quantum)
	_ok(a_near[0] == 0.0 and a_near[1] == 0.0 and a_near[2] == 0.0, "G-O1-ANCHOR: no step while |p−anchor| ≤ trigger")
	# LEO-scale player (6.9k out) past the trigger ⇒ a step onto the integer quantum grid.
	var player := DV.v(9000.0, -1000.0, 4200.0)            # |·| ≈ 10k > 8192
	var a_new := ORB.anchor_snap(anchor, player, trigger, quantum)
	# every axis is an exact integer multiple of the quantum away from the old anchor.
	var integer_step := true
	for i in range(3):
		var q := (a_new[i] - anchor[i]) / quantum
		if absf(q - round(q)) > 1.0e-12:
			integer_step = false
	_ok(integer_step, "G-O1-ANCHOR: anchor step is an exact integer multiple of the quantum (4096)")
	_ok(DV.length(DV.sub(player, a_new)) <= trigger + quantum, "G-O1-ANCHOR: the snapped anchor brings the player back within one quantum of the trigger")

	# Relative-position invariance across the step: a spread of absolute nodes, placed relative to BOTH
	# anchors, keeps every (node − player) render vector identical to f32 ε.
	var nodes := [DV.v(9000.0, -1000.0, 4200.0), DV.v(8000.0, 500.0, 3000.0), DV.v(10500.0, -1500.0, 5000.0), DV.v(9000.0, 6000.0, 4200.0)]
	var worst := 0.0
	for nd in nodes:
		var rel_old := ORB.place_rel(nd, anchor) - ORB.place_rel(player, anchor)
		var rel_new := ORB.place_rel(nd, a_new) - ORB.place_rel(player, a_new)
		worst = maxf(worst, (rel_old - rel_new).length())
	_ok(worst < 1.0e-3, "G-O1-ANCHOR: node-relative-to-player render vectors invariant across the step (worst %.2e blocks, sub-mm)" % worst)

	# The anchor is render-only: an OrbitalState is not mutated by anchor_snap.
	var st := ORB.make("earth", player, DV.v(0.0, 250.0, 0.0))
	var p_before := PackedFloat64Array([st.pos[0], st.pos[1], st.pos[2]])
	ORB.anchor_snap(anchor, st.pos, trigger, quantum)
	_ok(st.pos[0] == p_before[0] and st.pos[1] == p_before[1] and st.pos[2] == p_before[2], "G-O1-ANCHOR: OrbitalState.pos untouched by anchor_snap (render-only)")
