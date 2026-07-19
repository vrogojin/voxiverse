extends SceneTree
## COSMOS SPACE-NAV SN2 gate — the nav-frame state machine (docs/COSMOS-SPACE-NAV-DESIGN.md §4/§5/§10).
## Proves the pure CosmosNav kernel: the §4.3 classifier + §4.5 hysteresis/dwell/R-latch (G-SN-CLASS), the
## §5.4 CONTINUITY THEOREM over a full scripted trajectory (G-SN-CONT — the crux), and geostationary
## exactness (G-SN-GEO). Every assert is PURE-KERNEL (CosmosNav / OrbitalState / CosmosGravity are
## engine-free statics), so this gate is FLAG-INDEPENDENT: it passes identically with SN_NAV_MODES true or
## false (the machine is DEAD — never instantiated in-game — when the flag is off; the gate drives it
## directly). Byte-identity (G-SN-OFF) is the FLAT verify_feature (6035/0), run separately.
##
## Asserts:
##   G-SN-CLASS  the §4.3 sanity table (Earth interim, every row → expected mode, incl. the r=12R→DEEP
##               "Earth-bound but classified deep" row); boundary crossings both directions honour the
##               ±10%/±5%/±32 hysteresis; the 2-s dwell delays a commit; the R-latch forces DEEP from HIGH.
##   G-SN-CONT   a trajectory crossing every reachable boundary both ways (prograde spiral surface→LEO→high
##               →heliocentric coast→retro re-entry), the full stack stepped (SN1 integrator + classifier +
##               machine): per tick the machine NEVER mutates [pos,vel] (control-run bit-identity); Δv equals
##               the integrator's own trapezoid (no impulse term) INCLUDING flip ticks; every frame
##               round-trip (fix→bci→fix, bci→helio→bci) < 1e-9; the committed mode sequence matches
##               expectation with the dwell honoured. DEEP↔INTER (identity map) asserted separately.
##   G-SN-GEO    at r_geo_dyn: |ω⃗×p| == v_circ(r_geo) (circular) AND |v_fix| == 0 (scene-stationary) AND
##               classify → HIGH_ORBIT; Moon: r_geo > SOI ⇒ has_stationary_orbit == false ("none").
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_nav.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")

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

func _name(m: int) -> String:
	return NAV.NAV_NAMES[m] if m >= 0 and m < NAV.NAV_NAMES.size() else "NONE"

func _initialize() -> void:
	print("=== verify_nav (COSMOS SPACE-NAV SN2: classifier + continuity theorem + geostationary) ===")
	print("  CubeSphere.SN_NAV_MODES = %s (gate is flag-independent; kernel is a pure static)" % str(CubeSphere.SN_NAV_MODES))
	FacetAtlas.warm_up()                                    # r_vox(earth) reads FacetAtlas.R_BLOCKS
	_gate_class()
	_gate_cont()
	_gate_geo()
	_gate_nospiral()
	_gate_reentry_guards()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ G-NAV-REENTRY (2026-07-19 blowup fixes)
## The re-entry classifier bands at the natural Earth/1000 scale, plus the two guard kernels added for the
## live de-orbit blowup (position teleport → 642074 b/s finite-difference latch → escape + 27 s frames):
## sane_v (G-NAV-SANEV) and clamp_bci_state (G-NAV-SOICLAMP). All pure statics.
func _gate_reentry_guards() -> void:
	print("  --- G-NAV-REENTRY: atmosphere-band classification at Earth/1000 + velocity/state guards ---")
	var r_vox := GRAV.r_vox("earth")
	# A de-orbit descent state just ABOVE the atmosphere (h=392, 82 b/s radial fall — the live telemetry):
	# raw AND low_orbit-incumbent both classify LOW_ORBIT (h > 384; > 352 with the incumbent's −32 margin).
	var p_hi := DV.v(0.0, 0.0, r_vox + 392.0)
	var v_fall := DV.v(0.0, 0.0, -82.0)
	_ok(NAV.classify("earth", p_hi, v_fall, 0.0) == NAV.LOW_ORBIT, "h=392 (raw): LOW_ORBIT (above the 384 band)")
	_ok(NAV.classify("earth", p_hi, v_fall, 0.0, NAV.LOW_ORBIT) == NAV.LOW_ORBIT, "h=392 (incumbent LOW): LOW_ORBIT (hysteresis keeps it above 352)")
	# Just BELOW the band: raw at h=380 → PLANETARY; incumbent LOW_ORBIT flips only under 352 (the −32 margin).
	_ok(NAV.classify("earth", DV.v(0.0, 0.0, r_vox + 380.0), v_fall, 0.0) == NAV.PLANETARY, "h=380 (raw): PLANETARY (inside the 384 band)")
	_ok(NAV.classify("earth", DV.v(0.0, 0.0, r_vox + 360.0), v_fall, 0.0, NAV.LOW_ORBIT) == NAV.LOW_ORBIT, "h=360 (incumbent LOW): still LOW_ORBIT (hysteresis)")
	_ok(NAV.classify("earth", DV.v(0.0, 0.0, r_vox + 344.0), v_fall, 0.0, NAV.LOW_ORBIT) == NAV.PLANETARY, "h=344 (incumbent LOW): PLANETARY (crossed 352 — the descent hands off)")
	# The live blowup radius r≈17844 (alt 11473) is inside the 4R vicinity ⇒ LOW_ORBIT is the DESIGNED
	# classification there — the live "stuck low_orbit" at that altitude was correct; the bug was upstream.
	_ok(NAV.classify("earth", DV.v(0.0, 0.0, 17844.0), v_fall, 0.0, NAV.LOW_ORBIT) == NAV.LOW_ORBIT, "r=17844 (4R vicinity): LOW_ORBIT by design")

	# G-NAV-SANEV — the finite-difference/adopted-velocity guard.
	var good := DV.v(10.0, -80.0, 3.0)
	var prev := DV.v(1.0, -60.0, 0.0)
	var out := NAV.sane_v(good, prev)
	_ok(out[0] == 10.0 and out[1] == -80.0 and out[2] == 3.0, "sane_v passes a physical velocity through unchanged")
	var junk := DV.v(0.0, 642074.0, 0.0)                     # the live latch value — the teleport's Δp/dt
	out = NAV.sane_v(junk, prev)
	_ok(out[0] == prev[0] and out[1] == prev[1] and out[2] == prev[2], "sane_v rejects the 642074 b/s teleport artifact → last-good fallback (velocity-continuous)")
	out = NAV.sane_v(junk, junk)
	_ok(DV.length(out) == 0.0, "sane_v with no good fallback rests (never adopts garbage)")
	out = NAV.sane_v(DV.v(NAN, 0.0, 0.0), prev)
	_ok(out[1] == prev[1], "sane_v rejects NaN components")
	_ok(NAV.v_is_sane(DV.v(0.0, NAV.FD_SPEED_MAX - 1.0, 0.0)), "v_is_sane admits speeds up to FD_SPEED_MAX (no legit flight clipped: 2x SN_DEV_V_MAX)")
	_ok(not NAV.v_is_sane(PackedFloat64Array()), "v_is_sane rejects a malformed (empty) vector")

	# G-NAV-SOICLAMP — the integrated-state guard.
	var p0 := DV.v(0.0, 0.0, r_vox + 300.0)
	var v0 := DV.v(250.0, 0.0, 0.0)
	var soi := NAV.soi_radius("earth")
	_ok(soi > 4.0 * r_vox and not is_inf(soi), "earth SOI is finite and far outside the vicinity (%.0f)" % soi)
	# In-bounds state passes through bit-equal.
	var st := NAV.clamp_bci_state(p0, v0, DV.v(0.0, 0.0, r_vox + 301.0), DV.v(249.0, 0.0, 0.0), soi)
	_ok(st[0][2] == p0[2] and st[1][0] == v0[0], "clamp_bci_state passes an in-SOI finite state through unchanged")
	# NaN reverts the WHOLE state to the pre-step pair.
	st = NAV.clamp_bci_state(DV.v(NAN, 0.0, 0.0), v0, p0, v0, soi)
	_ok(st[0][2] == p0[2] and st[1][0] == v0[0], "clamp_bci_state reverts a NaN integration to the pre-step state")
	# Beyond-SOI clamps onto the SOI sphere and strips ONLY the outward radial velocity.
	var p_far := DV.v(0.0, 0.0, soi * 2.0)
	var v_out := DV.v(30.0, 0.0, 100.0)                      # 100 outward radial + 30 tangential
	st = NAV.clamp_bci_state(p_far, v_out, p0, v0, soi)
	_ok(absf(DV.length(st[0]) - soi) < 1.0e-6 * soi, "clamp_bci_state clamps a beyond-SOI radius onto the SOI sphere")
	_ok(absf(float(st[1][0]) - 30.0) < 1.0e-9 and absf(float(st[1][2])) < 1.0e-9, "clamp: outward radial velocity stripped, tangential preserved (velocity-continuous)")
	# Inward motion at the clamp is NOT stripped (a fall back toward the planet proceeds).
	st = NAV.clamp_bci_state(p_far, DV.v(0.0, 0.0, -50.0), p0, v0, soi)
	_ok(absf(float(st[1][2]) + 50.0) < 1.0e-9, "clamp keeps INWARD radial velocity (recovery fall proceeds)")

	# FIX D — dwell starvation (the corroborated "stuck low_orbit at 160k"). The dwell is UX seconds: fed
	# real (capped) frame time, a persistent raw reclassification commits in ceil(2s/dt) frames even when
	# frames are seconds long; fed the CLAMPED integrator dt (1/30) it would take 60 frames (~15 min wall at
	# 14 s/frame — the live starvation). Drive the kernel with both dts and assert the bound the player
	# wiring now uses (NAV_DWELL_DT_MAX = 1.0) commits in 2-3 slow frames.
	var ns := NAV.NavState.new()
	ns.mode = NAV.LOW_ORBIT
	var p_deep := DV.v(0.0, 0.0, 20.0 * r_vox)               # far outside the well/vicinity ⇒ raw != LOW_ORBIT
	var v_deep := DV.v(0.0, 0.0, 0.0)
	var n_slow := 0
	while int(ns.mode) == NAV.LOW_ORBIT and n_slow < 10:
		ns.tick("earth", p_deep, v_deep, 0.0, NAV.NAV_DWELL_DT_MAX)   # the wiring's capped REAL dt per slow frame
		n_slow += 1
	_ok(int(ns.mode) != NAV.LOW_ORBIT and n_slow <= 3, "dwell fed capped REAL dt commits the reclassification in %d slow frames (≤3)" % n_slow)
	var ns2 := NAV.NavState.new()
	ns2.mode = NAV.LOW_ORBIT
	for i in 10:
		ns2.tick("earth", p_deep, v_deep, 0.0, NAV.MAX_NAV_DT)        # the OLD wiring's clamped dt
	_ok(int(ns2.mode) == NAV.LOW_ORBIT, "falsify: dwell fed the clamped integrator dt is still STARVED after 10 slow frames (the live stuck-mode)")

# ---------- a BCI state at radius r on the equator (XY plane) with speed-ratio u tangential ----------
# Tangential (prograde-east) velocity of magnitude u·v_circ(r). Pure setup helper for synthetic rows.
func _state_at(body: String, r: float, u: float) -> Array:
	var mu := GRAV.gm_dyn(body)
	var v_circ := sqrt(mu / r)
	var p := DV.v(r, 0.0, 0.0)
	var v := DV.v(0.0, u * v_circ, 0.0)
	return [p, v]

# ---------- G-SN-CLASS: the §4.3 sanity table + hysteresis + dwell + R-latch ----------
func _gate_class() -> void:
	print("  --- G-SN-CLASS: §4.3 table + boundary hysteresis + 2-s dwell + R-latch ---")
	var body := "earth"
	var R := GRAV.r_vox(body)                               # 3072 interim
	var r_geo := NAV.r_geo_dyn(body)                        # ≈ 20370
	var t := 0.0

	# The sanity table (Earth interim radii). incumbent = NONE ⇒ raw (interior points, no boundary ambiguity).
	# Standing on the surface: r=R, eastward spin speed ω·R ⇒ u≈0.06, h=0 < 384.
	var w := EPH.omega_spin(body)
	var surf_p := DV.v(R, 0.0, 0.0)
	var surf_v := DV.v(0.0, w * R, 0.0)                     # = ω⃗×p (rest on the rotating surface)
	_ok(NAV.classify(body, surf_p, surf_v, t) == NAV.PLANETARY, "row: surface (h=0, u≈%.3f) → PLANETARY" % (DV.length(surf_v) / sqrt(GRAV.gm_dyn(body) / R)))

	# Hovering at h=500 (above atmo 384), slow u≈0.07 ⇒ LOW_ORBIT. The atmosphere ceiling IS the planetary↔
	# low-orbit divide (user decision 2026-07-18): above 384 blocks the slow-hover "suborbital stays PLANETARY"
	# clause is gone, so a slow hover just above the atmosphere falls through the vicinity rule → LOW_ORBIT.
	var hov := _state_at(body, R + 500.0, 0.07)
	_ok(NAV.classify(body, hov[0], hov[1], t) == NAV.LOW_ORBIT, "row: hover h=500 u=0.07 → LOW_ORBIT (above atmo ⇒ low orbit regardless of speed)")

	# LEO circular at h=500, u=1 ⇒ vicinity, super-suborbital → LOW_ORBIT.
	var leo := _state_at(body, R + 500.0, 1.0)
	_ok(NAV.classify(body, leo[0], leo[1], t) == NAV.LOW_ORBIT, "row: LEO h=500 u=1 → LOW_ORBIT")

	# Circular at r=5R (below r_geo), u=1 ⇒ γ-gated speed clause → LOW_ORBIT.
	var r5 := _state_at(body, 5.0 * R, 1.0)
	_ok(NAV.classify(body, r5[0], r5[1], t) == NAV.LOW_ORBIT, "row: r=5R u=1 → LOW_ORBIT (below geostationary)")

	# Geostationary (r_geo ≈ 6.6R), u=1 ⇒ the D-SN-CLASS-1 resolution puts it at the low/high divide → HIGH_ORBIT.
	var rgeo_s := _state_at(body, r_geo, 1.0)
	_ok(NAV.classify(body, rgeo_s[0], rgeo_s[1], t) == NAV.HIGH_ORBIT, "row: geostationary r=%.0f u=1 → HIGH_ORBIT" % r_geo)

	# Just ABOVE geostationary, still bound γ>0.01 u<2 → HIGH_ORBIT (in the well, above the divide).
	var rgeo_hi := _state_at(body, r_geo * 1.2, 1.0)
	_ok(NAV.classify(body, rgeo_hi[0], rgeo_hi[1], t) == NAV.HIGH_ORBIT, "row: r=1.2·r_geo u=1 → HIGH_ORBIT")

	# Circular at r=12R, u=1 ⇒ γ=0.0069<0.01, r>cap ⇒ per the user's thresholds → DEEP_SPACE (Earth-bound but deep).
	var r12 := _state_at(body, 12.0 * R, 1.0)
	_ok(NAV.classify(body, r12[0], r12[1], t) == NAV.DEEP_SPACE, "row: r=12R u=1 → DEEP_SPACE (Earth-bound but classified deep — CORRECT)")

	# Hyperbolic escape at r=20R, u=2.5, s<1 ⇒ HIGH_ORBIT (escape clause). Near Earth the heliocentric speed
	# is dominated by Earth's own 2145-b/s orbital velocity (≈ v_sol), so s < 1 needs the escape burn RETROGRADE
	# to Earth's motion (Earth's t=0 velocity is +Y here; the −Y burn subtracts from the solar-frame speed).
	var mu := GRAV.gm_dyn(body)
	var resc_p := DV.v(20.0 * R, 0.0, 0.0)
	var resc_v := DV.v(0.0, -2.5 * sqrt(mu / (20.0 * R)), 0.0)
	_ok(NAV.classify(body, resc_p, resc_v, t) == NAV.HIGH_ORBIT, "row: r=20R u=2.5 retrograde (s<1) → HIGH_ORBIT (hyperbolic escape)")

	# INTERSTELLAR: a heliocentric state far beyond R_SYSTEM at ≥10× solar speed. Build it in BCI over the Sun
	# (parentless ⇒ p_helio == p_bci, v_helio == v_bci) at r_helio = 50 AU, |v| = 12× local v_sol.
	var au := 1.496e8
	var r_far := 50.0 * au
	var v_sol_far := sqrt(EPH.gm_game("sun") / r_far)
	var inter_p := DV.v(r_far, 0.0, 0.0)
	var inter_v := DV.v(0.0, 12.0 * v_sol_far, 0.0)
	_ok(NAV.classify("sun", inter_p, inter_v, t) == NAV.INTERSTELLAR, "row: r_helio=50 AU, s=12 → INTERSTELLAR")

	# DEEP_SPACE just inside the system at modest speed (s=5 < 10) beyond gravity wells.
	var r_mid := 20.0 * au
	var v_sol_mid := sqrt(EPH.gm_game("sun") / r_mid)
	var deep_p := DV.v(r_mid, 0.0, 0.0)
	var deep_v := DV.v(0.0, 5.0 * v_sol_mid, 0.0)
	_ok(NAV.classify("sun", deep_p, deep_v, t) == NAV.DEEP_SPACE, "row: r_helio=20 AU, s=5 → DEEP_SPACE (in system)")

	# --- hysteresis both directions across the PLANETARY↔LOW atmosphere boundary (±32 blocks) ---
	# Incumbent PLANETARY holds until h > 384+32 = 416; incumbent LOW re-enters PLANETARY below 384−32 = 352.
	var u_orb := 1.0                                        # super-suborbital so the ONLY divider is the atmo band
	var s_plan_hold := _state_at(body, R + 400.0, u_orb)    # h=400, between 352 and 416
	_ok(NAV._classify_inputs(body, NAV.inputs(body, s_plan_hold[0], s_plan_hold[1], t), NAV.PLANETARY) == NAV.PLANETARY,
		"hyst: h=400 with incumbent PLANETARY stays PLANETARY (band+32)")
	_ok(NAV._classify_inputs(body, NAV.inputs(body, s_plan_hold[0], s_plan_hold[1], t), NAV.LOW_ORBIT) == NAV.LOW_ORBIT,
		"hyst: h=400 with incumbent LOW_ORBIT stays LOW_ORBIT (band−32)")
	# Beyond the margin the incumbent CANNOT hold: h=430 > 416 ⇒ LOW even from PLANETARY.
	var s_above := _state_at(body, R + 430.0, u_orb)
	_ok(NAV._classify_inputs(body, NAV.inputs(body, s_above[0], s_above[1], t), NAV.PLANETARY) == NAV.LOW_ORBIT,
		"hyst: h=430 forces LOW even from PLANETARY (past +32 margin)")
	# h=340 < 352 ⇒ PLANETARY even from LOW.
	var s_below := _state_at(body, R + 340.0, u_orb)
	_ok(NAV._classify_inputs(body, NAV.inputs(body, s_below[0], s_below[1], t), NAV.LOW_ORBIT) == NAV.PLANETARY,
		"hyst: h=340 forces PLANETARY even from LOW (past −32 margin)")

	# --- hysteresis across the LOW↔HIGH geostationary divide (±5 % on r_geo) ---
	var s_div := _state_at(body, r_geo * 1.02, 1.0)         # 2 % above r_geo, inside the ±5 % band
	_ok(NAV._classify_inputs(body, NAV.inputs(body, s_div[0], s_div[1], t), NAV.LOW_ORBIT) == NAV.LOW_ORBIT,
		"hyst: r=1.02·r_geo with incumbent LOW stays LOW (r_geo+5%)")
	_ok(NAV._classify_inputs(body, NAV.inputs(body, s_div[0], s_div[1], t), NAV.HIGH_ORBIT) == NAV.HIGH_ORBIT,
		"hyst: r=1.02·r_geo with incumbent HIGH stays HIGH (r_geo−5%)")

	# --- the 2-s dwell: a raw change does NOT commit until held NAV_DWELL_S ---
	var ns := NAV.NavState.new()
	ns.mode = NAV.PLANETARY
	# Feed a persistent LOW_ORBIT state; before 2 s it must stay PLANETARY, after 2 s commit to LOW.
	var dt := 1.0 / 60.0
	var committed_early := true
	var tt := 0.0
	while tt < 1.9:
		ns.tick(body, leo[0], leo[1], t, dt)
		if ns.mode != NAV.PLANETARY:
			committed_early = false                         # (would be a FAIL — recorded below)
		tt += dt
	_ok(committed_early and ns.mode == NAV.PLANETARY, "dwell: mode holds PLANETARY through 1.9 s of a LOW input")
	# Cross the 2-s mark.
	var loops := 0
	while ns.mode == NAV.PLANETARY and loops < 60:
		ns.tick(body, leo[0], leo[1], t, dt)
		loops += 1
	_ok(ns.mode == NAV.LOW_ORBIT, "dwell: mode commits to LOW_ORBIT after 2 s held")

	# --- the R-latch forces DEEP_SPACE from HIGH_ORBIT until cleared ---
	_ok(NAV.classify(body, rgeo_s[0], rgeo_s[1], t, NAV.HIGH_ORBIT, false) == NAV.HIGH_ORBIT,
		"R-latch OFF: geostationary classify → HIGH_ORBIT")
	_ok(NAV.classify(body, rgeo_s[0], rgeo_s[1], t, NAV.HIGH_ORBIT, true) == NAV.DEEP_SPACE,
		"R-latch ON: same HIGH_ORBIT state expresses DEEP_SPACE")

# ---------- G-SN-CONT: the §5.4 CONTINUITY THEOREM (the crux) ----------
# Two complementary scripted-trajectory proofs:
#   (A) INTEGRATED no-impulse theorem — a bounded powered orbit-raise stepped through the FULL stack
#       (SN1 integrator + classifier + machine). Proves per tick: the machine never writes [pos,vel]; a
#       live run and a machine-free CONTROL run stay BIT-IDENTICAL (⇒ zero impulse, incl. flip ticks); Δv
#       equals the integrator's own trapezoid; every frame round-trip is exact to f64 relative precision.
#   (B) MODE-SEQUENCE sweep — a scripted near-circular radial trajectory crossing EVERY boundary both
#       directions (surface→LEO→high→heliocentric→return→re-entry), driving the machine (dwell + hysteresis)
#       and asserting the committed mode sequence. Kinematic (the machine only READS state) — the no-impulse
#       theorem is (A)'s job; this proves the boundary/dwell logic over the full crossing set.
func _gate_cont() -> void:
	print("  --- G-SN-CONT: no-impulse continuity (A) + full boundary/mode sequence (B) — the theorem ---")
	_cont_integrated()
	_cont_sequence()

# (A) the integrated no-impulse theorem over a bounded powered orbit-raise (LOW→HIGH→LOW).
func _cont_integrated() -> void:
	var body := "earth"
	var R := GRAV.r_vox(body)
	var mu := GRAV.gm_dyn(body)
	# dt = 0.01 s < SUBSTEP_MAX (1/60) so step() runs EXACTLY one velocity-Verlet substep per tick — the
	# per-tick Δv then equals ½(a0+a1)·dt exactly (a multi-substep tick would fold in an intermediate
	# acceleration my single-a1 trapezoid can't see, a false failure unrelated to any impulse).
	var dt := 0.01
	var r0 := R + 500.0
	var v_circ0 := sqrt(mu / r0)
	var live := ORB.make(body, DV.v(r0, 0.0, 0.0), DV.v(0.0, v_circ0, 0.0))
	# CONTROL: identical initial state, integrator ONLY. If it ever diverges from `live`, the machine wrote state.
	var ctrl := ORB.make(body, DV.v(r0, 0.0, 0.0), DV.v(0.0, v_circ0, 0.0))
	var ns := NAV.NavState.new()
	ns.mode = NAV.LOW_ORBIT

	var worst_drift := 0.0          # max |live − ctrl| (must be 0.0 exactly)
	var worst_dv := 0.0             # max relative |Δv − ½(a0+a1)h| (no impulse term)
	var worst_rt := 0.0             # max relative frame round-trip error
	var machine_mutation := 0.0     # max |v before machine − v after machine| (must be 0.0)
	var flip_dv := 0.0              # max Δv from a mode-flip tick specifically (must be 0.0)
	var flips := 0

	# Prograde burn raises the orbit past geostationary (LOW→HIGH); reverse on r ≥ 7.2R (bounded — never
	# escapes, so the heliocentric magnitude stays ≈ 1 AU and the round-trips stay f64-exact); retrograde
	# back to re-entry, drag engaging in the band. r stays in [R, 7.2R] ⇒ the trajectory is bounded.
	var A := 6.0
	var ascending := true
	var tick := 0
	while tick < 120000:
		var t := float(tick) * dt
		var spd := DV.length(live.vel)
		var vhat := DV.scale(live.vel, 1.0 / spd) if spd > 0.0 else DV.v(0.0, 1.0, 0.0)
		var sign := 1.0 if ascending else -1.0
		var a_ext := DV.add(DV.scale(vhat, sign * A), ORB.atmos_drag_bci(body, live.pos, live.vel))

		var v_before := PackedFloat64Array([live.vel[0], live.vel[1], live.vel[2]])
		var a0 := DV.add(GRAV.gravity_bci(body, live.pos), a_ext)
		live.step(dt, a_ext)
		var a1 := DV.add(GRAV.gravity_bci(body, live.pos), a_ext)
		var dv_expect := DV.scale(DV.add(a0, a1), 0.5 * dt)
		var dv_err := DV.length(DV.sub(DV.sub(live.vel, v_before), dv_expect))
		# Scale by the magnitude of the contributing terms (not their possibly-cancelling sum) so a
		# near-zero-net-accel tick can't inflate the ratio. err/scale ~ machine ε.
		var dv_scale := (DV.length(a0) + DV.length(a1)) * 0.5 * dt
		worst_dv = maxf(worst_dv, dv_err / dv_scale if dv_scale > 1.0e-30 else dv_err)

		# CONTROL steps with the SAME sign, its own velocity-derived thrust; bit-identical iff machine is inert.
		var cspd := DV.length(ctrl.vel)
		var cvhat := DV.scale(ctrl.vel, 1.0 / cspd) if cspd > 0.0 else DV.v(0.0, 1.0, 0.0)
		ctrl.step(dt, DV.add(DV.scale(cvhat, sign * A), ORB.atmos_drag_bci(body, ctrl.pos, ctrl.vel)))
		worst_drift = maxf(worst_drift, DV.length(DV.sub(live.pos, ctrl.pos)) + DV.length(DV.sub(live.vel, ctrl.vel)))

		# Run the machine; it must not touch [pos,vel].
		var v_pre := PackedFloat64Array([live.vel[0], live.vel[1], live.vel[2]])
		var prev := ns.mode
		ns.tick(body, live.pos, live.vel, t, dt)
		machine_mutation = maxf(machine_mutation, DV.length(DV.sub(live.vel, v_pre)))
		if ns.mode != prev:
			flips += 1
			flip_dv = maxf(flip_dv, DV.length(DV.sub(live.vel, v_pre)))

		# Frame round-trips (relative to the heliocentric magnitude — the maps are exact to f64 ulp, and the
		# helio leg carries the 1.5e8-block Earth offset whose ulp ≈ 3e-8, so ABSOLUTE < 1e-9 is unachievable
		# at 1 AU; RELATIVE ε is the correct, honest statement).
		var fx := ORB.bci_to_fixed(body, t, live.pos, live.vel)
		var bk := ORB.fixed_to_bci(body, t, fx[0], fx[1])
		var e_fix := (DV.length(DV.sub(bk[0], live.pos)) + DV.length(DV.sub(bk[1], live.vel))) / maxf(DV.length(live.pos), 1.0)
		var hl := ORB.bci_to_helio(body, t, live.pos, live.vel)
		var hb := ORB.helio_to_bci(body, t, hl[0], hl[1])
		var e_hel := (DV.length(DV.sub(hb[0], live.pos)) + DV.length(DV.sub(hb[1], live.vel))) / maxf(DV.length(hl[0]), 1.0)
		worst_rt = maxf(worst_rt, maxf(e_fix, e_hel))

		var r := DV.length(live.pos)
		if ascending and r >= 7.2 * R:
			ascending = false
		if not ascending and r <= R + 300.0:
			break
		tick += 1

	_ok(machine_mutation == 0.0, "G-SN-CONT(A): the machine NEVER mutates [pos,vel] (max Δ = %.1e — must be 0)" % [machine_mutation])
	_ok(worst_drift == 0.0, "G-SN-CONT(A): live vs machine-free control run bit-identical (max |Δstate| = %.1e — zero impulse)" % [worst_drift])
	_ok(flips >= 1, "G-SN-CONT(A): the powered orbit-raise crossed ≥1 mode boundary (LOW↔HIGH); flips = %d" % flips)
	_ok(flip_dv == 0.0, "G-SN-CONT(A): zero Δv at every mode-flip tick (max = %.1e)" % [flip_dv])
	# Tolerance scales with the coordinate magnitude: the trapezoid residual is the f64 round-off of a
	# velocity-Verlet update whose absolute ulp grows with √(GM·r). Earth/1000 (R=6371, GM=2.07e9) makes the
	# BCI coordinates/velocities ~2× larger than the interim R=3072 world, so the relative residual grows from
	# ~6e-13 to ~1.3e-12. 1e-11 keeps this a meaningful "no impulse" assertion — a real impulse is a RELATIVE
	# O(1) jump, ~10 orders of magnitude above this floor — while `worst_drift == 0.0` (bit-identical control
	# run, asserted separately below) is the exact zero-impulse proof this only corroborates.
	_ok(worst_dv < 1.0e-11, "G-SN-CONT(A): per-tick Δv == integrator trapezoid to %.1e (no impulse term)" % [worst_dv])
	_ok(worst_rt < 1.0e-12, "G-SN-CONT(A): frame round-trips (fix↔bci, bci↔helio) relative err %.1e (f64-exact)" % [worst_rt])

# (B) the full boundary crossing set + committed mode sequence, both directions, dwell honoured.
func _cont_sequence() -> void:
	var body := "earth"
	var R := GRAV.r_vox(body)
	var mu := GRAV.gm_dyn(body)
	var dt := 1.0 / 60.0
	var ns := NAV.NavState.new()
	ns.mode = NAV.PLANETARY

	# Waypoint radii the scripted trajectory visits (near-circular, u=1). Each leg RAMPS r over the boundaries;
	# a HOLD at each waypoint lets the 2-s dwell commit. Up: atmo→LEO→below-geo→geo→high→deep. Down: reverse.
	var wps := [R + 100.0, R + 600.0, 5.0 * R, NAV.r_geo_dyn(body), 8.0 * R, 11.5 * R,
			8.0 * R, 5.0 * R, R + 600.0, R + 100.0]
	var seq: Array = [ns.mode]
	var t := 0.0
	var r_prev: float = wps[0]
	for wi in range(wps.size()):
		var r_target: float = wps[wi]
		# Ramp from r_prev to r_target over RAMP ticks (crossing whatever boundaries lie between).
		var ramp := 400
		for i in range(ramp + 1):
			var r: float = lerp(r_prev, r_target, float(i) / float(ramp))
			var st := _state_at(body, r, 1.0)
			var prev := ns.mode
			ns.tick(body, st[0], st[1], t, dt)
			if ns.mode != prev:
				seq.append(ns.mode)
			t += dt
		# Hold at the waypoint > 2 s so the terminal mode of the leg commits.
		var hold := 200
		for _i in range(hold):
			var st := _state_at(body, r_target, 1.0)
			var prev := ns.mode
			ns.tick(body, st[0], st[1], t, dt)
			if ns.mode != prev:
				seq.append(ns.mode)
			t += dt
		r_prev = r_target

	var names: Array = []
	for m in seq:
		names.append(_name(m))
	print("    committed mode sequence: %s" % str(names))
	# Expected committed progression: P→LOW→HIGH→DEEP (up) then DEEP→HIGH→LOW→P (down).
	var expected := [NAV.PLANETARY, NAV.LOW_ORBIT, NAV.HIGH_ORBIT, NAV.DEEP_SPACE,
			NAV.HIGH_ORBIT, NAV.LOW_ORBIT, NAV.PLANETARY]
	var match_ok: bool = seq.size() == expected.size()
	if match_ok:
		for i in range(expected.size()):
			if int(seq[i]) != expected[i]:
				match_ok = false
	_ok(match_ok, "G-SN-CONT(B): committed sequence P→LOW→HIGH→DEEP→HIGH→LOW→P (every boundary, both ways, dwell honoured)")

	# DEEP ↔ INTERSTELLAR is the identity velocity map (§5.2) — HUD/control expression only, physical state
	# untouched. Assert the two express the SAME v_bci with different frame speeds (solar → self=0).
	var au := 1.496e8
	var r_far := 42.0 * au
	var v_sol := sqrt(EPH.gm_game("sun") / r_far)
	var pf := DV.v(r_far, 0.0, 0.0)
	var vf := DV.v(0.0, 9.8 * v_sol, 0.0)
	var deep_hud := NAV.hud_velocity(NAV.DEEP_SPACE, "sun", pf, vf, 0.0)
	var inter_hud := NAV.hud_velocity(NAV.INTERSTELLAR, "sun", pf, vf, 0.0)
	_ok(float(deep_hud["speed"]) > 0.0 and float(inter_hud["speed"]) == 0.0,
		"G-SN-CONT: DEEP↔INTER HUD-only (solar %.1f → self 0); v_bci untouched (identity map)" % float(deep_hud["speed"]))

# ---------- G-SN-GEO: geostationary exactness + the Moon "no stationary orbit" case ----------
func _gate_geo() -> void:
	print("  --- G-SN-GEO: |ω⃗×p| == v_circ(r_geo), scene-stationary, HIGH_ORBIT; Moon ⇒ none ---")
	var body := "earth"
	var r_geo := NAV.r_geo_dyn(body)
	var mu := GRAV.gm_dyn(body)
	var v_circ := sqrt(mu / r_geo)
	# Place at r_geo on the equator, v = ω⃗×p (the geostationary velocity).
	var p := DV.v(r_geo, 0.0, 0.0)
	var v := ORB.omega_cross(body, p)
	_ok(_rel(DV.length(v), v_circ) < 1.0e-9, "G-SN-GEO: |ω⃗×p| = %.4f == v_circ(r_geo) = %.4f (exactly circular)" % [DV.length(v), v_circ])
	# Scene-stationary: the body-fixed velocity is zero (a geostationary point does not move on the surface).
	var vf: PackedFloat64Array = ORB.bci_to_fixed(body, 0.0, p, v)[1]
	_ok(DV.length(vf) < 1.0e-9, "G-SN-GEO: |v_fix| = %.1e < 1e-9 (scene-stationary in the pinned body frame)" % [DV.length(vf)])
	# It classifies HIGH_ORBIT (the §4.4 requirement).
	_ok(NAV.classify(body, p, v, 0.0) == NAV.HIGH_ORBIT, "G-SN-GEO: geostationary classifies HIGH_ORBIT")
	# r_geo consistency: (GM/ω²)^{1/3} and ω·r_geo == v_circ both hold ⇒ ω²r_geo³ == GM.
	var w := EPH.omega_spin(body)
	_ok(_rel(w * w * r_geo * r_geo * r_geo, mu) < 1.0e-9, "G-SN-GEO: ω²·r_geo³ == GM_dyn (r_geo definition exact)")

	# Earth HAS a stationary orbit (r_geo 20370 < SOI ≈ 385 k).
	_ok(NAV.has_stationary_orbit("earth"), "G-SN-GEO: Earth has_stationary_orbit == true (r_geo %.0f < SOI %.0f)" % [r_geo, NAV.soi_radius("earth")])
	# The Moon does NOT (r_geo ≈ 88.5 k > SOI ≈ 66.1 k) — the §4.4 corner the G key reports as "none".
	var moon_rgeo := NAV.r_geo_dyn("moon")
	var moon_soi := NAV.soi_radius("moon")
	_ok(moon_rgeo > moon_soi, "G-SN-GEO: Moon r_geo %.0f > SOI %.0f (no selenostationary orbit)" % [moon_rgeo, moon_soi])
	_ok(not NAV.has_stationary_orbit("moon"), "G-SN-GEO: Moon has_stationary_orbit == false (G key reports 'none')")
	# Earth r_geo = (GM·DAY²/4π²)^⅓ ≈ 42,241. This is MODEL-INVARIANT across the natural 1:1000 retune: GM
	# shrank ×(1e-6/5.184e-6)=0.193 while DAY² grew ×(√1000/72·1200... )² so GM·DAY² is unchanged — the
	# geostationary altitude is the real 42,164-km orbit scaled ÷1000, independent of the clock rate. (Natural:
	# GM_dyn=GM_game=3.986e8, DAY_GAME≈2732 s.) Moon unchanged (R_vox==R_eph): r_geo ≈ 88.5 k, SOI ≈ 66.1 k.
	_ok(_rel(r_geo, 42241.0) < 5.0e-3, "G-SN-GEO: Earth r_geo = %.0f ≈ 42,241 (geostationary, model-invariant)" % r_geo)
	_ok(_rel(moon_soi, 66100.0) < 2.0e-2, "G-SN-GEO: Moon SOI = %.0f ≈ 66,100" % moon_soi)

# ---------- G-SN-NOSPIRAL: the per-frame work is BOUNDED regardless of dt (the freeze / spiral-of-death fix) ----------
# The live symptom was an exponential frame-time runaway (worst_ms 433→893→1024→1995→…→15974) with EVERY
# measured cost flat — the signature of a per-frame loop whose iteration count scales with the frame dt: one
# streaming hitch seeds a large dt, the loop does proportionally more work, the frame gets slower, dt grows.
# The unbounded loop is OrbitalState.step's `n = ceil(dt/SUBSTEP_MAX)` (dt = 16 s ⇒ ~960 Verlet substeps in
# ONE frame). This gate proves the three defensive bounds hold, and is FALSIFIABLE: remove the SUBSTEP_MAX_N
# cap and substep_count(16) jumps to ~960 (assert fails); remove clamp_nav_dt and the live dt is unbounded.
func _gate_nospiral() -> void:
	print("  --- G-SN-NOSPIRAL: substep cap + nav-dt clamp + finite-difference guard (bounded per-frame work) ---")
	var body := "earth"

	# (1) A normal 60-fps tick is a couple of substeps at most, and the CAP is INERT there — the uncapped count
	#     for dt ≤ 1/60 is well below SUBSTEP_MAX_N, so every accuracy gate (all step at dt ≤ 1/60) is
	#     byte-unchanged by the cap (min(uncapped, cap) == uncapped when uncapped < cap). (Note: 1/60 ÷ the
	#     0.016666… SUBSTEP_MAX literal rounds to a hair over 1.0, so ceil is 2, not 1 — a couple of substeps,
	#     exactly as before this fix; the cap never touches it.)
	_ok(ORB.substep_count(1.0 / 60.0) <= 2, "substep_count(1/60) <= 2 (a normal frame is a couple of substeps)")
	_ok(int(ceil((1.0 / 60.0) / ORB.SUBSTEP_MAX)) < ORB.SUBSTEP_MAX_N, "the cap is INERT for a normal frame (uncapped %d < cap %d ⇒ accuracy gates untouched)" % [int(ceil((1.0 / 60.0) / ORB.SUBSTEP_MAX)), ORB.SUBSTEP_MAX_N])
	_ok(ORB.substep_count(0.01) == 1, "substep_count(0.01) == 1 (the G-SN-CONT(A) dt is still 1 substep)")

	# (2) A post-hitch HUGE dt is CAPPED at SUBSTEP_MAX_N — NOT the ~960 it would be uncapped. This is the line
	#     that kills the spiral: the per-frame Verlet count can never scale with dt past the cap.
	var uncapped := int(ceil(16.0 / ORB.SUBSTEP_MAX))       # ~960 — what the loop ran BEFORE the fix
	_ok(uncapped > 900, "without a cap a 16-s frame would run ~%d substeps (the unbounded loop)" % uncapped)
	_ok(ORB.substep_count(16.0) == ORB.SUBSTEP_MAX_N, "substep_count(16 s) == SUBSTEP_MAX_N (%d) — CAPPED, not %d" % [ORB.SUBSTEP_MAX_N, uncapped])
	_ok(ORB.substep_count(1.0e9) == ORB.SUBSTEP_MAX_N, "substep_count(1e9 s) == SUBSTEP_MAX_N (bound holds for any dt)")

	# (2b) The real step() over a huge dt returns a FINITE state in bounded work (the cap makes it survive the
	#      recovery frame — it does not hang looping ~960 times, nor produce NaN/inf).
	var st := ORB.make(body, DV.v(GRAV.r_vox(body) + 500.0, 0.0, 0.0), DV.v(0.0, 100.0, 0.0))
	st.step(16.0, DV.v(0.0, 0.0, 0.0))
	_ok(_dv_finite(st.pos) and _dv_finite(st.vel), "step(16 s) returns a finite [pos,vel] in bounded work (no hang, no NaN/inf)")

	# (3) The per-frame dt clamp: a runaway dt is capped to MAX_NAV_DT; a normal frame is BYTE-NEUTRAL (dt < clamp
	#     passes through unchanged); a non-positive dt is 0. And the CLAMPED dt through step is ≤ 2 substeps —
	#     the actual live wiring (player clamps, then any integrator steps) is bounded to a trivial count.
	_ok(NAV.clamp_nav_dt(16.0) == NAV.MAX_NAV_DT, "clamp_nav_dt(16 s) == MAX_NAV_DT (%.4f) — runaway dt bounded" % NAV.MAX_NAV_DT)
	_ok(NAV.clamp_nav_dt(1.0 / 60.0) == 1.0 / 60.0, "clamp_nav_dt(1/60) == 1/60 (a normal frame is untouched — byte-neutral)")
	_ok(NAV.clamp_nav_dt(-1.0) == 0.0, "clamp_nav_dt(negative) == 0 (no negative dt reaches the path)")
	_ok(ORB.substep_count(NAV.clamp_nav_dt(16.0)) <= 3, "clamp→step over a huge dt is a tiny substep count (≤ 3, vs ~%d uncapped — the live-wired bound)" % uncapped)

	# (4) The finite-difference guard: v_fix = Δp · fd_inv_dt cannot blow up on a near-zero delta. fd_inv_dt is
	#     bounded by 1/MIN_FD_DT, so an enormous Δp / near-zero dt yields a bounded (if capped) derived velocity.
	var inv_max := 1.0 / NAV.MIN_FD_DT
	_ok(NAV.fd_inv_dt(0.0) == inv_max, "fd_inv_dt(0) == 1/MIN_FD_DT (%.0f) — near-zero delta cannot divide-by-zero" % inv_max)
	_ok(NAV.fd_inv_dt(1.0e-12) == inv_max, "fd_inv_dt(1e-12) is clamped to 1/MIN_FD_DT (bounded, not 1e12)")
	_ok(NAV.fd_inv_dt(1.0 / 60.0) == 60.0, "fd_inv_dt(1/60) == 60 (a normal delta is exact — byte-neutral)")
	# A concrete blow-up attempt: a 1000-block position jump over a 1e-15-s delta.
	var v_blow := DV.scale(DV.v(1000.0, 0.0, 0.0), NAV.fd_inv_dt(1.0e-15))
	_ok(_dv_finite(v_blow) and DV.length(v_blow) <= 1000.0 * inv_max, "v_fix from a 1000-block jump over ~0 dt is bounded (|v| ≤ 1000/MIN_FD_DT, finite)")

## True iff every component of a DVec3 is finite (no NaN / inf) — the bounded-work sanity check.
func _dv_finite(p: PackedFloat64Array) -> bool:
	return is_finite(p[0]) and is_finite(p[1]) and is_finite(p[2])
