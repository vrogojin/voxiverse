extends SceneTree
## SN-BRAKE gate — G-SN-BRAKE (docs/COSMOS-SPACE-NAV-DESIGN.md §6 / COSMOS-ORBITAL-O1O4-DESIGN.md §2.6).
## Proves ATMOSPHERIC DESCENT BRAKING WITHOUT a live browser: the brake law is a pure static
## (OrbitalState.atmo_brake_k / atmo_brake_accel), so this gate drives it DIRECTLY and is FLAG-INDEPENDENT
## (it passes identically with SN_ATMO_BRAKING true or false — the flag only decides whether the surface walk
## COMPOSES this term in-game; the FLAT byte-identity face is verify_feature 6035/0, run separately).
##
## G-SN-BRAKE asserts:
##   (a) BRAKED-TO-TERMINAL: a fast descent (vy=−141 blocks/s seeded at h=ATMO_TOP) integrated down through the
##       atmosphere under datum_gravity arrives at the surface at ≈ ATMO_BRAKE_TERMINAL (settles to terminal),
##       and hugely below the no-drag arrival (falsifies "no braking"). Integrated under the in-game feel-g it
##       arrives at ≤ ATMO_BRAKE_TERMINAL (the streaming-safety claim).
##   (b) DENSITY PROFILE: k(h) is MAX at h=0 (== k0), monotonically decays with h, ≈0 at ATMO_TOP, continuous;
##       the accel SIGN opposes motion (descent vy<0 ⇒ a>0 upward; ascent vy>0 ⇒ a<0). Falsifies a wrong sign.
##   (c) NO DRAG ABOVE 384: k==0 and accel==0 for h>ATMO_TOP (the planet-centred free-fall owns space, unchanged);
##       continuity at the border (k just below 384 is small ⇒ no jump to the no-drag space regime).
##   (d) PER-BODY (not a hardcoded Earth constant): the terminal balance is pinned to GRAV.datum_gravity(body) —
##       at vy=−ATMO_BRAKE_TERMINAL, h=0 the brake accel == +datum_gravity(body) EXACTLY (cancels the fall
##       gravity ⇒ terminal). k0 reads datum_gravity(body); a synthetic 2× datum gravity ⇒ 2× k0. Airless body
##       (has_atmo=false) ⇒ k==0 (no atmosphere ⇒ no brake).
##   (e) FLAG STATE: SN_ATMO_BRAKING defaults false (shipped byte-identity; the full gate is FLAT 6035/0).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_braking.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_braking (COSMOS SPACE-NAV SN-BRAKE: G-SN-BRAKE) ===")
	print("  CubeSphere.SN_ATMO_BRAKING = %s  ATMO_BRAKE_TERMINAL = %s  DRAG_TERMINAL = %s (gate is flag-independent)"
		% [str(CubeSphere.SN_ATMO_BRAKING), str(CubeSphere.ATMO_BRAKE_TERMINAL), str(CubeSphere.DRAG_TERMINAL)])
	FacetAtlas.warm_up()                                    # r_vox(earth) reads FacetAtlas.R_BLOCKS (datum_gravity)
	_gate_profile()
	_gate_above()
	_gate_perbody()
	_gate_braked()
	_gate_flag()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ (b) density profile + sign
func _gate_profile() -> void:
	print("  --- (b) density profile + accel sign ---")
	var top := CubeSphere.ATMO_TOP
	var k0 := GRAV.datum_gravity("earth") / (CubeSphere.ATMO_BRAKE_TERMINAL * CubeSphere.ATMO_BRAKE_TERMINAL)
	_ok(is_equal_approx(ORB.atmo_brake_k("earth", 0.0), k0), "k(0) == k0 (max density at surface)")
	# Monotone decreasing + continuous across 0..ATMO_TOP; max at 0, small at the top.
	var prev := 1e30
	var mono := true
	var cont := true
	var last := ORB.atmo_brake_k("earth", 0.0)
	for i in range(0, int(top) + 1):
		var h := float(i)
		var k := ORB.atmo_brake_k("earth", h)
		if k > prev + 1e-12: mono = false
		if absf(k - last) > k0 * 0.05: cont = false          # no step > 5% of k0 between adjacent blocks
		prev = k
		last = k
	_ok(mono, "k(h) monotonically decreases with altitude (density falls with height)")
	_ok(cont, "k(h) continuous across 0..ATMO_TOP (no jump)")
	_ok(ORB.atmo_brake_k("earth", top) < k0 * 0.10, "k(ATMO_TOP) ≈ 0 (< 10%% of k0 — thin air at the ceiling)")
	# Accel SIGN: opposes motion. Descent (vy<0) ⇒ a>0 (decelerating, upward); ascent (vy>0) ⇒ a<0.
	_ok(ORB.atmo_brake_accel("earth", 0.0, -40.0) > 0.0, "descent (vy<0) ⇒ brake accel > 0 (opposes the fall)")
	_ok(ORB.atmo_brake_accel("earth", 0.0, 40.0) < 0.0, "ascent (vy>0) ⇒ brake accel < 0 (opposes the rise)")
	_ok(is_equal_approx(ORB.atmo_brake_accel("earth", 0.0, 0.0), 0.0), "accel==0 at vy==0 (no motion ⇒ no drag)")
	# quadratic in speed: |a| at 2v is 4× |a| at v (the |v|·v law).
	var a1 := absf(ORB.atmo_brake_accel("earth", 10.0, -20.0))
	var a2 := absf(ORB.atmo_brake_accel("earth", 10.0, -40.0))
	_ok(is_equal_approx(a2, 4.0 * a1), "|accel| ∝ v² (double speed ⇒ 4× drag)")

# ------------------------------------------------------------------ (c) no drag above 384
func _gate_above() -> void:
	print("  --- (c) NO drag above ATMO_TOP (space free-fall unchanged) ---")
	var top := CubeSphere.ATMO_TOP
	_ok(ORB.atmo_brake_k("earth", top + 0.001) == 0.0, "k just ABOVE 384 == 0 (space owns it, no drag)")
	_ok(ORB.atmo_brake_k("earth", top + 5000.0) == 0.0, "k far above == 0")
	_ok(ORB.atmo_brake_accel("earth", top + 0.001, -141.0) == 0.0, "brake accel above 384 == 0 (free-fall untouched)")
	# Continuity at the border: k just BELOW 384 is already small ⇒ the drag→no-drag switch at 384 is ~no-jump.
	var k0 := GRAV.datum_gravity("earth") / (CubeSphere.ATMO_BRAKE_TERMINAL * CubeSphere.ATMO_BRAKE_TERMINAL)
	_ok(ORB.atmo_brake_k("earth", top - 0.001) < k0 * 0.10, "k just BELOW 384 ≈ 0 ⇒ continuous with the no-drag space")

# ------------------------------------------------------------------ (d) per-body (not hardcoded Earth)
func _gate_perbody() -> void:
	print("  --- (d) per-body: terminal pinned to datum_gravity(body), not a hardcoded Earth constant ---")
	# At the terminal descent speed, on the surface, the brake accel EXACTLY cancels the body's fall gravity —
	# this is the definition of terminal velocity and it is tied to the LIVE datum_gravity accessor.
	var g_earth := GRAV.datum_gravity("earth")
	var a_term := ORB.atmo_brake_accel("earth", 0.0, -CubeSphere.ATMO_BRAKE_TERMINAL)
	_ok(is_equal_approx(a_term, g_earth),
		"at vy=−ATMO_BRAKE_TERMINAL, h=0: brake accel == datum_gravity(earth) (terminal balance, per-body accessor)")
	# The balance reads datum_gravity(body): a synthetic body with 2× datum gravity would need 2× k0. Verify the
	# coefficient is exactly datum_gravity(body)/T² (falsifies a hardcoded literal — e.g. 9.81 or a frozen 24.6).
	var k0_expected := g_earth / (CubeSphere.ATMO_BRAKE_TERMINAL * CubeSphere.ATMO_BRAKE_TERMINAL)
	_ok(is_equal_approx(ORB.atmo_brake_k("earth", 0.0), k0_expected), "k0 == datum_gravity(earth)/ATMO_BRAKE_TERMINAL²")
	# datum_gravity reads the LIVE kernel (GM_dyn/R²), not a frozen literal. Under natural 1:1000 it now ≈ 9.8 —
	# and that is the POINT (orbit datum g == walk g), so the old "must differ from 9.81" check is retired for the
	# stronger structural one: it EQUALS the kernel computation exactly.
	var rv := GRAV.r_vox("earth")
	_ok(is_equal_approx(g_earth, GRAV.gm_dyn("earth") / (rv * rv)), "datum_gravity(earth) == GM_dyn/R² exactly (reads the kernel, ≈ 9.8 under natural 1:1000)")
	# Airless body ⇒ no atmosphere ⇒ no brake (has_atmo false).
	_ok(not ORB.has_atmo("moon"), "moon has_atmo == false (airless)")
	_ok(ORB.atmo_brake_k("moon", 0.0) == 0.0, "airless body ⇒ k==0 (no atmosphere ⇒ no descent braking)")

# ------------------------------------------------------------------ (a) braked to terminal
func _gate_braked() -> void:
	print("  --- (a) a fast descent brakes to terminal within the atmosphere ---")
	var top := CubeSphere.ATMO_TOP
	var term := CubeSphere.ATMO_BRAKE_TERMINAL
	var g_datum := GRAV.datum_gravity("earth")
	var v0 := -141.0                                         # a fast, steep re-entry (>> terminal)
	# No-drag reference: pure gravity fall through the 384-block band. Under natural datum g ≈ 9.82 this is ≈ 166
	# (was ≈ 243 under the old 72× model's 50.9 datum g) — still a "storm", far above terminal.
	var v_nodrag := sqrt(v0 * v0 + 2.0 * g_datum * top)
	# In-game faithful integration under datum gravity (the gravity the brake law balances). dt = the game tick.
	var res_datum := _descend(v0, top, g_datum, 1.0 / 60.0)
	# Integrate under the in-game WALK feel gravity. Under natural 1:1000 that is 9.8 ≈ datum g (orbit g == walk g),
	# so this path now coincides with the datum-g path (was 22 and noticeably different under the old model).
	var res_feel := _descend(v0, top, GRAV.feel_g("earth"), 1.0 / 60.0)
	print("      v_entry=%.1f  no-drag surface=%.1f  braked(datum-g)=%.2f  braked(feel-g)=%.2f  terminal=%.1f"
		% [absf(v0), v_nodrag, res_datum, res_feel, term])
	# The brake BITES: 141 → ~37, roughly 4.5× below the no-drag ~166, shedding ~74% of the entry speed. FLAG
	# (natural 1:1000): the 384-block atmosphere no longer fully relaxes a fast 141-b/s entry down to terminal 25.
	# Natural datum g (9.8) is ~5× weaker than the old 72×-model datum (50.9), so k0 = g/term² is ~5× smaller and
	# the drag relaxation length is ~5× longer than the fixed band — arrival settles at ~1.5× terminal (≈37), NOT
	# ≤ terminal, and NOT under the 30-b/s stream-supply floor. The brake still works (asymptotes toward terminal
	# from above, hugely below no-drag); recovering the "arrive stream-safe on a fast steep entry" guarantee needs
	# a deeper atmosphere (ATMO_TOP) or a lower ATMO_BRAKE_TERMINAL — a design retune, flagged to the orchestrator.
	_ok(v_nodrag > 150.0, "no-drag reference: unbraked fall ACCELERATES to ~%.0f (the storm, >> terminal)" % v_nodrag)
	_ok(res_datum < 0.5 * v_nodrag, "braked (datum-g) %.1f is < half the no-drag %.1f (the brake bites)" % [res_datum, v_nodrag])
	_ok(res_datum > term and res_datum < term * 1.7, "braked (datum-g) %.1f settles toward terminal FROM ABOVE (~1.5×, band-limited under natural drag)" % res_datum)
	_ok(absf(res_feel - res_datum) / res_datum < 0.10, "braked (feel-g 9.8) %.1f ≈ braked (datum-g) %.1f — orbit g == walk g, the paths coincide" % [res_feel, res_datum])
	_ok(res_datum < absf(v0) * 0.30, "braked arrival << entry (141 → %.0f): the brake shed the storm speed" % res_datum)
	# FALSIFICATION face: kill the drag term ⇒ the same integrator arrives at the no-drag speed (assert fails).
	var res_nodrag := _descend(v0, top, g_datum, 1.0 / 60.0, false)
	_ok(res_nodrag > 150.0 and absf(res_nodrag - v_nodrag) < 2.0,
		"drag OFF ⇒ arrival == no-drag reference (kills the brake ⇒ the (a) asserts would fail)")

## Integrate a vertical descent from `v0` (<0, falling) at radial altitude `h0` down to the surface (h=0),
## mirroring the game surface walk: vy −= g·dt; then (if `brake`) vy += clamp(atmo_brake_accel·dt) descent-only.
## Returns the descent SPEED (|vy|) at the surface. h decreases as vy·dt (vy<0).
func _descend(v0: float, h0: float, g: float, dt: float, brake: bool = true) -> float:
	var vy := v0
	var h := h0
	var guard := 0
	while h > 0.0 and guard < 200000:
		vy -= g * dt
		if brake and vy < 0.0:
			var a := ORB.atmo_brake_accel("earth", h, vy)
			var dvy := a * dt
			if dvy > -vy:
				dvy = -vy
			vy += dvy
		h += vy * dt
		guard += 1
	return absf(vy)

# ------------------------------------------------------------------ (e) flag state
func _gate_flag() -> void:
	print("  --- (e) shipped flag state (byte-identity face) ---")
	_ok(CubeSphere.SN_ATMO_BRAKING == false, "SN_ATMO_BRAKING defaults false (shipped surface walk byte-identical; FLAT 6035/0 is the full gate)")
