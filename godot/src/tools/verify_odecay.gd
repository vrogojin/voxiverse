extends SceneTree
## COSMOS SPACE-NAV §7.4 gate — G-ODECAY (docs/COSMOS-SPACE-NAV-DESIGN.md §7.4, flag CubeSphere.ORBIT_COAST).
## MEASURE-FIRST reproduction of the LIVE orbit-descent bug: with ORBIT_COAST on, pressing O engages a coast that
## curves correctly but DESCENDS — the player arcs to the opposite side and stops. The isolated G-OCOAST gate
## (verify_ocoast.gd) integrates the PURE OrbitalState.step kernel and proves a circular seed holds radius; it
## explicitly assumes "the lattice round-trip _coast_step wraps is a gated identity". THIS gate exercises the
## EXACT LIVE COMPOSITE that G-OCOAST skipped — Player._coast_step: read the f32 lattice `position`, map
## lattice→world (f64), FIXED→BCI at t, one OrbitalState.step, BCI→FIXED at the SAME t, world→lattice, WRITE
## the f32 `position` back — while the velocity is carried in full-precision f64 and NEVER round-tripped.
##
## The composite has two faults the pure kernel cannot see:
##   (1) f32 POSITION ROUND-TRIP — `position` is a Godot Vector3 (f32); os.pos (f64) is quantised to ~r·2^-23
##       every tick, while os.vel stays f64 ⇒ the symplectic (p,v) pairing is broken (energy leak).
##   (2) SAME-t SPIN ROUND-TRIP  — _coast_step maps fixed→bci and bci→fixed with the SAME t, but the stored
##       lattice frame is BODY-FIXED (rotating). Between consecutive ticks t advances by dt, so the position
##       re-read next tick is rotated by an EXTRA ω_spin·dt relative to the (un-rotated) f64 velocity ⇒ the
##       (p,v) pair desynchronises by one tick of planet spin every tick.
##
## This gate REPRODUCES the descent through a faithful copy of _coast_step (same calls, real f32 `position`),
## seeded exactly as the O handler seeds (release_circular tangential), driven ≥3 orbital periods at the real
## per-frame dt, then isolates each fault and PROVES the fix (carry BCI [p,v] in f64; project to lattice for
## DISPLAY ONLY, never read back). Pure static / engine-free — runs headless, flag-independent math.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##          --script res://src/tools/verify_odecay.gd 2>/dev/null | grep -E 'VERIFY|FAIL|---|cfg'
## Exits 0 all-pass / 1 on any failure.

const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const DEVF := preload("res://src/cosmos/cosmos_dev_flight.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

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
	print("=== verify_odecay (COSMOS SPACE-NAV §7.4: G-ODECAY — the O coast DESCENT reproduction + fix) ===")
	print("  CubeSphere.ORBIT_COAST = %s ; omega_spin(earth) = %.8f rad/s (spin period %.0f s)"
		% [str(CubeSphere.ORBIT_COAST), EPH.omega_spin("earth"), 1200.0])
	FA.warm_up()
	# The three test radii the mandate specifies (post-atmosphere orbital band, R=3072 + ATMO_TOP=384).
	for r in [3600.0, 4500.0, 6000.0]:
		_repro_and_fix(r, 3)
	_secular_pump(4500.0, 30)
	_hitchy_dt_case(4500.0)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------------------------------------------------------------------------------
# Seed helper — place the player on the spawn facet at radius r, directly above the facet centre (along its
# outward normal), and seed a purely-tangential circular velocity via release_circular EXACTLY as the O handler
# does. At t=0 spin_angle(earth,0)=spin_phase0=0 ⇒ BCI == FIXED, so p_fix = n̂·r maps to p_bci = n̂·r cleanly.
# Returns {fid, position(Vector3 f32 lattice), p_bci(f64), v_bci(f64), v_circ}.
# ---------------------------------------------------------------------------------------
func _seed(r: float, t0: float = 0.0) -> Dictionary:
	var fid := FA.spawn_facet()
	var nrm := FA.facet_normal64(fid)                       # world outward normal at the facet centre (unit, f64)
	var p_fix := DV.v(nrm[0] * r, nrm[1] * r, nrm[2] * r)   # directly above the facet centre (body-fixed), radius r
	# Seed at t0 (the live O-press happens at a large _nav_clock ⇒ θ(t0) ≠ 0 from the very first round-trip).
	var p_bci: PackedFloat64Array = ORB.fixed_to_bci("earth", t0, p_fix, DV.v(0.0, 0.0, 0.0))[0]
	# Look: any horizontal (⊥ n̂) direction; release_circular projects out the radial part and normalises to v_circ.
	var seedv := DV.v(0.0, 0.0, 1.0)
	if absf(DV.dot(seedv, nrm)) > 0.9:
		seedv = DV.v(1.0, 0.0, 0.0)
	var v_bci: PackedFloat64Array = DEVF.release_circular("earth", p_bci, seedv, DV.v(0.0, 0.0, 0.0))
	var lat: Array = FA.world_to_lattice64(fid, p_fix[0], p_fix[1], p_fix[2])
	var pos := Vector3(lat[0], lat[1], lat[2])              # the f32 lattice storage the live code keeps
	var v_circ := sqrt(GRAV.gm_dyn("earth") / r)
	return {"fid": fid, "position": pos, "p_bci": p_bci, "v_bci": v_bci, "v_circ": v_circ, "t0": t0}

# The stored-position radius the player actually experiences: |lattice→world|. (For the f64-position configs the
# radius is taken from the carried BCI directly.)
func _radius_of_pos(fid: int, pos) -> float:
	var w: Array = FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])

# NOTE ON THE DRIVER: GDScript lambdas capture locals BY VALUE and do NOT persist mutations across calls, so the
# per-tick state MUST be advanced by a plain inline loop (a `func(_i): pos = …` closure re-runs from the seed every
# call — a silent no-op that fakes a perfect "hold"). Every runner below is a direct loop for exactly this reason.

func _fresh_stats(r0: float, mu: float, v_circ: float) -> Dictionary:
	return {"r0": r0, "r_min": r0, "r_max": r0, "r_end": r0,
		"eps0": 0.5 * v_circ * v_circ - mu / r0, "eps_end": 0.5 * v_circ * v_circ - mu / r0, "v_circ": v_circ}

func _accum(st: Dictionary, r: float, eps: float) -> void:
	st["r_min"] = minf(float(st["r_min"]), r)
	st["r_max"] = maxf(float(st["r_max"]), r)
	st["r_end"] = r
	st["eps_end"] = eps

# ---------------------------------------------------------------------------------------
# CONFIG A — the SHIPPED composite, a faithful copy of Player._coast_step. `position` is a real f32 Vector3;
# the fixed↔bci round-trip uses the SAME t; the clock advances by dt AFTER the step (mirrors _physics_process
# running _move before _nav_tick).
# ---------------------------------------------------------------------------------------
func _run_composite_f32(seed: Dictionary, dt: float, steps: int) -> Dictionary:
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	var fid: int = seed["fid"]
	var pos: Vector3 = seed["position"]                     # f32 lattice storage
	var v: PackedFloat64Array = PackedFloat64Array([seed["v_bci"][0], seed["v_bci"][1], seed["v_bci"][2]])
	var t: float = seed["t0"]
	var st := _fresh_stats(_radius_of_pos(fid, pos), mu, seed["v_circ"])
	for _i in range(steps):
		# --- faithful _coast_step copy ---
		var w: Array = FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
		var p_bci: PackedFloat64Array = ORB.fixed_to_bci(body, t, DV.v(w[0], w[1], w[2]), DV.v(0.0, 0.0, 0.0))[0]
		var os = ORB.make(body, p_bci, v)
		os.step(NAV.clamp_nav_dt(dt), DV.v(0.0, 0.0, 0.0))
		var pf_new: PackedFloat64Array = ORB.bci_to_fixed(body, t, os.pos, os.vel)[0]
		var lat: Array = FA.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
		pos = Vector3(lat[0], lat[1], lat[2])              # f32 quantise
		v = os.vel
		t += NAV.clamp_nav_dt(dt) * EPH.TIME_WARP    # _nav_tick advances the clock by the SAME clamped dt
		var wr: Array = FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
		var pr := DV.v(wr[0], wr[1], wr[2])
		_accum(st, DV.length(pr), ORB.specific_energy(mu, pr, v))
	return st

# ---------------------------------------------------------------------------------------
# CONFIG B — the same round-trip but `position` kept in f64 (no f32 Vector3). Isolates the same-t spin round-trip
# from the f32 quantisation: if B still decays, the spin round-trip is a cause on its own.
# ---------------------------------------------------------------------------------------
func _run_composite_f64pos(seed: Dictionary, dt: float, steps: int) -> Dictionary:
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	var fid: int = seed["fid"]
	var p_lat := PackedFloat64Array([seed["position"].x, seed["position"].y, seed["position"].z])
	var v: PackedFloat64Array = PackedFloat64Array([seed["v_bci"][0], seed["v_bci"][1], seed["v_bci"][2]])
	var t: float = seed["t0"]
	var w0: Array = FA.lattice_to_world64(fid, p_lat[0], p_lat[1], p_lat[2])
	var st := _fresh_stats(DV.length(DV.v(w0[0], w0[1], w0[2])), mu, seed["v_circ"])
	for _i in range(steps):
		var w: Array = FA.lattice_to_world64(fid, p_lat[0], p_lat[1], p_lat[2])
		var p_bci: PackedFloat64Array = ORB.fixed_to_bci(body, t, DV.v(w[0], w[1], w[2]), DV.v(0.0, 0.0, 0.0))[0]
		var os = ORB.make(body, p_bci, v)
		os.step(NAV.clamp_nav_dt(dt), DV.v(0.0, 0.0, 0.0))
		var pf_new: PackedFloat64Array = ORB.bci_to_fixed(body, t, os.pos, os.vel)[0]
		var lat: Array = FA.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
		p_lat = PackedFloat64Array([lat[0], lat[1], lat[2]])
		v = os.vel
		t += NAV.clamp_nav_dt(dt) * EPH.TIME_WARP    # _nav_tick advances the clock by the SAME clamped dt
		var wr: Array = FA.lattice_to_world64(fid, p_lat[0], p_lat[1], p_lat[2])
		var pr := DV.v(wr[0], wr[1], wr[2])
		_accum(st, DV.length(pr), ORB.specific_energy(mu, pr, v))
	return st

# ---------------------------------------------------------------------------------------
# CONFIG C — THE FIX. Carry the BCI [p,v] in f64 ACROSS ticks; integrate purely in BCI; the lattice `position` is
# a DISPLAY-ONLY f32 projection NEVER read back into the integrator. Should match the pure kernel (REF) to f64.
# ---------------------------------------------------------------------------------------
func _run_fix_bci(seed: Dictionary, dt: float, steps: int) -> Dictionary:
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	var fid: int = seed["fid"]
	var p_bci: PackedFloat64Array = PackedFloat64Array([seed["p_bci"][0], seed["p_bci"][1], seed["p_bci"][2]])
	var v: PackedFloat64Array = PackedFloat64Array([seed["v_bci"][0], seed["v_bci"][1], seed["v_bci"][2]])
	var t: float = seed["t0"]
	var st := _fresh_stats(DV.length(p_bci), mu, seed["v_circ"])
	for _i in range(steps):
		var os = ORB.make(body, p_bci, v)
		os.step(NAV.clamp_nav_dt(dt), DV.v(0.0, 0.0, 0.0))
		p_bci = os.pos                                     # carried f64
		v = os.vel
		# DISPLAY-ONLY projection (computed, thrown away — never feeds the next tick)
		var pf: PackedFloat64Array = ORB.bci_to_fixed(body, t, p_bci, v)[0]
		var lat: Array = FA.world_to_lattice64(fid, pf[0], pf[1], pf[2])
		var _display := Vector3(lat[0], lat[1], lat[2])
		t += NAV.clamp_nav_dt(dt) * EPH.TIME_WARP    # _nav_tick advances the clock by the SAME clamped dt
		_accum(st, DV.length(p_bci), ORB.specific_energy(mu, p_bci, v))
	return st

# ---------------------------------------------------------------------------------------
# CONFIG D — the composite WITH FACET CROSSING. At orbital speed the player sweeps facets constantly; the live
# _physics_process reframes `position` into the neighbour facet each crossing (apply_reframe → world→lattice in the
# new facet's f32 chart) and leaves the BCI velocity untouched. Modelled here: each tick recompute the facet from
# the world DIRECTION (facet_of_dir); on a change reframe `position` via reframe_position64 (the exact live op).
# ---------------------------------------------------------------------------------------
func _run_composite_crossing(seed: Dictionary, dt: float, steps: int) -> Dictionary:
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	var fid: int = seed["fid"]
	var pos: Vector3 = seed["position"]
	var v: PackedFloat64Array = PackedFloat64Array([seed["v_bci"][0], seed["v_bci"][1], seed["v_bci"][2]])
	var t: float = seed["t0"]
	var crossings := 0
	var st := _fresh_stats(_radius_of_pos(fid, pos), mu, seed["v_circ"])
	for _i in range(steps):
		var w: Array = FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
		var p_bci: PackedFloat64Array = ORB.fixed_to_bci(body, t, DV.v(w[0], w[1], w[2]), DV.v(0.0, 0.0, 0.0))[0]
		var os = ORB.make(body, p_bci, v)
		os.step(NAV.clamp_nav_dt(dt), DV.v(0.0, 0.0, 0.0))
		var pf_new: PackedFloat64Array = ORB.bci_to_fixed(body, t, os.pos, os.vel)[0]
		var lat: Array = FA.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
		pos = Vector3(lat[0], lat[1], lat[2])
		v = os.vel
		t += NAV.clamp_nav_dt(dt) * EPH.TIME_WARP    # _nav_tick advances the clock by the SAME clamped dt
		var rn := DV.length(pf_new)
		if rn > 0.0:
			var dir = CubeSphere.DVec3.new(pf_new[0] / rn, pf_new[1] / rn, pf_new[2] / rn)
			var nf := FA.facet_of_dir(dir)
			if nf != fid:
				var rl: Array = FA.reframe_position64(fid, nf, pos.x, pos.y, pos.z)
				pos = Vector3(rl[0], rl[1], rl[2])         # apply_reframe: f32 position, BCI velocity untouched
				fid = nf
				crossings += 1
		var wr: Array = FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
		var pr := DV.v(wr[0], wr[1], wr[2])
		_accum(st, DV.length(pr), ORB.specific_energy(mu, pr, v))
	st["crossings"] = crossings
	return st

# REF — the pure BCI kernel (ground truth; what G-OCOAST proves). No frame maps at all.
func _run_ref(seed: Dictionary, dt: float, steps: int) -> Dictionary:
	var body := "earth"
	var mu := GRAV.gm_dyn(body)
	var os = ORB.make(body, seed["p_bci"], seed["v_bci"])
	var st := _fresh_stats(DV.length(seed["p_bci"]), mu, seed["v_circ"])
	for _i in range(steps):
		os.step(NAV.clamp_nav_dt(dt), DV.v(0.0, 0.0, 0.0))
		_accum(st, DV.length(os.pos), ORB.specific_energy(mu, os.pos, os.vel))
	return st

func _report(tag: String, res: Dictionary) -> void:
	var r0: float = res["r0"]
	var eps_pct: float = 100.0 * (float(res["eps_end"]) - float(res["eps0"])) / absf(float(res["eps0"]))
	print("    cfg %s  r0=%.2f  r_min=%.2f  r_max=%.2f  r_end=%.2f  dr_end=%.3f (%.4f%%)  eps_drift=%.5f%%"
		% [tag, r0, res["r_min"], res["r_max"], res["r_end"], float(res["r_end"]) - r0,
			100.0 * (float(res["r_end"]) - r0) / r0, eps_pct])

# ---------------------------------------------------------------------------------------
# Reproduce (composite descends) → isolate → prove the fix (holds radius), for one radius over `orbits` periods.
# ---------------------------------------------------------------------------------------
func _repro_and_fix(r: float, orbits: int) -> void:
	# t0 = 300 s: the live O-press happens after minutes of _nav_clock, so exercise the round-trip with θ(t0) ≠ 0
	# from the very first tick (θ = ω·300 ≈ 1.57 rad) — not the trivial θ=0 identity.
	print("  --- radius r = %.0f blocks (%.2f·R), %d orbital periods, dt = 1/60 s, t0 = 300 s (θ0 ≈ %.2f rad) ---"
		% [r, r / GRAV.r_vox("earth"), orbits, EPH.omega_spin("earth") * 300.0])
	var seed := _seed(r, 300.0)
	var v_circ: float = seed["v_circ"]
	var period := TAU * r / v_circ
	var dt := 1.0 / 60.0
	var steps := int(ceil(orbits * period / dt))
	# seed sanity — exactly circular, purely tangential (else the reproduction would be confounded)
	var rhat := DV.scale(seed["p_bci"], 1.0 / DV.length(seed["p_bci"]))
	_ok(_rel(DV.length(seed["v_bci"]), v_circ) < 1.0e-9, "seed |v| == v_circ (%.3f blocks/s)" % v_circ)
	_ok(absf(DV.dot(seed["v_bci"], rhat)) / v_circ < 1.0e-9, "seed v ⊥ r̂ (purely tangential, exactly circular)")

	var ref := _run_ref(seed, dt, steps)
	var cA := _run_composite_f32(seed, dt, steps)
	var cB := _run_composite_f64pos(seed, dt, steps)
	var cC := _run_fix_bci(seed, dt, steps)
	var cD := _run_composite_crossing(seed, dt, steps)
	_report("REF", ref)
	_report("A(f32+rt)", cA)
	_report("B(f64+rt)", cB)
	_report("C(FIX)", cC)
	_report("D(cross)", cD)
	print("    D crossings over %d orbits: %d facet reframes" % [orbits, int(cD["crossings"])])

	var a_spread: float = (float(cA["r_max"]) - float(cA["r_min"])) / float(cA["r0"])
	var b_spread: float = (float(cB["r_max"]) - float(cB["r_min"])) / float(cB["r0"])
	var c_spread: float = (float(cC["r_max"]) - float(cC["r_min"])) / float(cC["r0"])
	var d_spread: float = (float(cD["r_max"]) - float(cD["r_min"])) / float(cD["r0"])

	# GROUND TRUTH — the pure kernel (REF) and the FIX (carry BCI in f64) hold EXACTLY circular: a circular seed
	# stays circular to f64. This is what the coast is SUPPOSED to do.
	_ok(absf(float(cC["r_end"]) - float(ref["r_end"])) / r < 1.0e-9, "REF and FIX agree (both pure f64 BCI) to < 1e-9")
	_ok(c_spread < 1.0e-6, "FIX C HOLDS radius EXACTLY (spread %.6f%% — a perfect circle)" % (c_spread * 100.0))

	# REPRODUCED — the SHIPPED composite (A) does NOT hold: the same-t fixed↔BCI spin round-trip pumps eccentricity
	# (apoapsis rises, periapsis drops) even from an exactly-circular seed. This IS the live descent's mechanism.
	_ok(a_spread > 1.0e-3, "REPRO: SHIPPED composite A distorts the orbit (spread %.4f%% ≫ 0, from a circular seed)" % (a_spread * 100.0))
	_ok(a_spread > 50.0 * c_spread, "REPRO: A's radius spread is ≥ 50× the FIX's — the round-trip is the defect")

	# ISOLATE — config B (f64 position, SAME-t spin round-trip, NO f32) drifts essentially like A ⇒ the SPIN
	# round-trip is the dominant fault; f32 quantisation is a minor contributor (H2 confirmed, H1 secondary).
	_ok(absf(b_spread - a_spread) / a_spread < 0.2, "ISOLATE: B (no f32) spread %.4f%% ≈ A %.4f%% ⇒ SPIN round-trip dominates (not f32)" % [b_spread * 100.0, a_spread * 100.0])
	# The crossing config (D) — real facet reframes at orbital speed — drifts too ⇒ crossing neither causes nor
	# cures it (it is the SAME round-trip). The FIX removes it for all of A/B/D.
	_ok(d_spread > 1.0e-3, "composite+CROSSING D also distorts (spread %.4f%%, %d reframes) — crossing is not the cure" % [d_spread * 100.0, int(cD["crossings"])])

	# The classifier (H3): does a primed orbital NavState ever fall to PLANETARY over the coast? A circular orbit at
	# these radii stays above the atmosphere band — so the LIVE exit is NOT a mid-orbit misclassification; it is the
	# eccentricity pump above dropping the PERIAPSIS into the atmosphere on the far side after enough orbits.
	_classifier_probe(seed, dt, steps)

# ---------------------------------------------------------------------------------------
# H3 probe — run the REAL CosmosNav classifier over the coast orbit. Prime a NavState to its committed orbital
# mode (>NAV_DWELL_S at the circular seed), then step the pure-BCI orbit and tick the machine each frame. Assert
# the committed mode NEVER becomes PLANETARY (which is the sole auto-trigger of the coast exit at player.gd:995;
# the other trigger, _coast_thrust_input, is live keypress only). If it never trips, the coast never auto-exits ⇒
# H3 (premature classifier exit) is falsified for a legitimate circular orbit.
# ---------------------------------------------------------------------------------------
func _classifier_probe(seed: Dictionary, dt: float, steps: int) -> void:
	var body := "earth"
	var os = ORB.make(body, seed["p_bci"], seed["v_bci"])
	var t: float = seed["t0"]
	var nav = NAV.NavState.new()
	# Prime: 3 s of dwell at the (stationary-in-radius) circular state so the machine commits its orbital mode.
	for _i in range(int(ceil(3.0 / dt))):
		nav.tick(body, os.pos, os.vel, t, NAV.clamp_nav_dt(dt))
	var committed0: int = nav.mode
	var ever_planetary := (committed0 == NAV.PLANETARY)
	var modes_seen := {committed0: true}
	for _i in range(steps):
		os.step(NAV.clamp_nav_dt(dt), DV.v(0.0, 0.0, 0.0))
		t += NAV.clamp_nav_dt(dt) * EPH.TIME_WARP    # _nav_tick advances the clock by the SAME clamped dt
		var m: int = nav.tick(body, os.pos, os.vel, t, NAV.clamp_nav_dt(dt))
		modes_seen[m] = true
		if m == NAV.PLANETARY:
			ever_planetary = true
	var names := PackedStringArray()
	for k in modes_seen.keys():
		names.append(NAV.NAV_NAMES[int(k)])
	print("    classifier: committed mode=%s ; modes over orbit={%s} ; ever PLANETARY=%s"
		% [NAV.NAV_NAMES[committed0], ", ".join(names), str(ever_planetary)])
	_ok(committed0 == NAV.LOW_ORBIT or committed0 == NAV.HIGH_ORBIT, "primed NavState commits to an ORBITAL mode (%s)" % NAV.NAV_NAMES[committed0])
	_ok(not ever_planetary, "coast orbit NEVER classifies PLANETARY ⇒ no auto coast-exit (H3 falsified)")

# ---------------------------------------------------------------------------------------
# SECULAR pump — the smoking gun. Over MANY orbits the shipped composite's PERIAPSIS drops monotonically
# (eccentricity grows without bound) while the FIX stays exactly circular. The dropping periapsis is on the FAR
# side of the release point — so the player dips lowest on the opposite side and, once it reaches the atmosphere,
# the surface handoff arrests it there: EXACTLY the pilot's "arcs to the opposite side and stops".
# ---------------------------------------------------------------------------------------
func _secular_pump(r: float, orbits: int) -> void:
	print("  --- SECULAR pump: %d orbits at r = %.0f, dt = 1/30 (the web clamp) ---" % [orbits, r])
	var seed := _seed(r, 300.0)
	var v_circ: float = seed["v_circ"]
	var dt := 1.0 / 30.0
	var steps := int(ceil(orbits * TAU * r / v_circ / dt))
	var cA := _run_composite_f32(seed, dt, steps)
	var cC := _run_fix_bci(seed, dt, steps)
	_report("A(f32+rt)", cA)
	_report("C(FIX)", cC)
	var peri_drop_A: float = float(cA["r0"]) - float(cA["r_min"])
	var peri_drop_C: float = float(cC["r0"]) - float(cC["r_min"])
	print("    periapsis drop over %d orbits: A = %.1f blocks | FIX = %.4f blocks" % [orbits, peri_drop_A, peri_drop_C])
	_ok(peri_drop_A > 5.0, "SECULAR: shipped composite A periapsis drops %.1f blocks (eccentricity pump — the descent)" % peri_drop_A)
	_ok(peri_drop_C < 1.0e-3, "SECULAR: FIX periapsis drop ~0 (%.5f blocks) — stays exactly circular over %d orbits" % [peri_drop_C, orbits])
	_ok(peri_drop_A > 1000.0 * maxf(peri_drop_C, 1.0e-9), "SECULAR: A's periapsis drop is ≥ 1000× the FIX's")

# ---------------------------------------------------------------------------------------
# Hitchy-dt case — the substep-cap path (mandate): a post-hitch huge dt clamped, the FIX stays bounded + circular.
# ---------------------------------------------------------------------------------------
func _hitchy_dt_case(r: float) -> void:
	print("  --- HITCHY dt (post-hitch big frames, clamp_nav_dt) at r = %.0f ---" % r)
	var seed := _seed(r, 300.0)
	var v_circ: float = seed["v_circ"]
	var period := TAU * r / v_circ
	var dt := 0.25                                          # a chunky 4-fps frame; clamp_nav_dt bounds it to 1/30
	var steps := int(ceil(3.0 * period / dt))
	var cA := _run_composite_f32(seed, dt, steps)
	var cC := _run_fix_bci(seed, dt, steps)
	_report("A(f32+rt)", cA)
	_report("C(FIX)", cC)
	# The FIX holds bounded + circular even under repeated clamped huge frames (no spiral, no NaN).
	_ok(is_finite(cC["r_end"]) and not is_nan(cC["r_end"]), "HITCHY: FIX radius finite (no NaN/spiral)")
	var c_spread: float = (float(cC["r_max"]) - float(cC["r_min"])) / float(cC["r0"])
	_ok(c_spread < 1.0e-6, "HITCHY: FIX stays exactly circular (spread %.6f%%) even under clamped huge dt" % (c_spread * 100.0))
