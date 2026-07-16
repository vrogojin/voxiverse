extends RefCounted
class_name OrbitalState
## COSMOS ORBITAL O1 (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.3 + the §2.4 frame algebra) — the ONE orbital-state
## implementation the player (O1) and later grids/debris (O2) share (parent §5.2). All math is f64 (DVecF64), in
## the CosmosEphemeris discipline: engine-free, deterministic, worker-safe. An instance is ~100 B of state; the
## heavy lifting (integrate / freeze / thaw / rails / drag / the frame maps) is static and allocation-light (DVec3
## 24-B temps only), so it never touches per-frame memory beyond those temps (NEVER-OOM). Nothing runs at load —
## instances are created only under FP_M3_ORBIT by the live-wiring stage; O1 headless gates drive it directly.
##
## The state is carried in the body-centred INERTIAL frame (BCI): integrating there means exact Newton with no
## fictitious forces (the rotating scene/body-fixed frame is a render-side re-expression, §2.4). ACTIVE = stepped
## by the symplectic integrator; RAILS = frozen to Kepler elements, closed-form position on demand (drift-free,
## zero per-tick cost). v1 freezes ONLY elliptic bound orbits (e < 1−ε, apoapsis inside SOI); hyperbolic/escape
## stays ACTIVE (correct, cheap, and cuts the universal-variable solver from scope).

const DV := preload("res://src/cosmos/dvec3.gd")

enum { ACTIVE, RAILS }

## Integrator substep clamp — a single physics tick is subdivided so no sub-step exceeds this (§2.3). At 60 Hz on
## the ~79-s LEO, dt·ω ≈ 1.3e-3 ⇒ bounded ~1e-3 relative energy oscillation, zero secular drift (symplectic).
const DT_SUB_MAX := 1.0 / 60.0

## Eccentricity guard: only orbits with e < 1 − ECC_EPS freeze to RAILS (bound, elliptic). ECC_EPS keeps the
## thaw's Newton solve well-conditioned and never mistakes a marginal parabola for an ellipse.
const ECC_EPS := 1.0e-4

## Atmosphere drag scale height (blocks) — k(h) = K0·exp(−h/H_SCALE) (§2.6, D10).
const DRAG_H_SCALE := 128.0

var body: String = "earth"                     # dominant attractor
var mode: int = ACTIVE                          # ACTIVE (integrated) | RAILS (Kepler elements)
var pos: PackedFloat64Array = DV.v(0.0, 0.0, 0.0)   # DVec3, body-centred INERTIAL (BCI), blocks
var vel: PackedFloat64Array = DV.v(0.0, 0.0, 0.0)   # DVec3, BCI, blocks/s
var elems: PackedFloat64Array = PackedFloat64Array() # RAILS: [a, e, i, raan, argp, m0, epoch] (f64 ×7)

func _init(body_name: String = "earth") -> void:
	body = body_name

# ---------------------------------------------------------------------------------------
# ACTIVE integrator (semi-implicit / symplectic Euler) — §2.3
# ---------------------------------------------------------------------------------------

## Point-mass gravitational acceleration at BCI position `p` over `body`: g = −gm·p/|p|³ (DVec3 f64). This is the
## EXACT inertial-frame force the integrator uses (the CosmosGravity three-regime blend is for the near-field/mode
## boundary; in orbit — above H_BLEND_HI — the blend IS this radial GM/r², so they agree).
static func grav_accel(body_name: String, p: PackedFloat64Array) -> PackedFloat64Array:
	var r := DV.length(p)
	if r <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var k := -CosmosEphemeris.gm_game(body_name) / (r * r * r)
	return DV.scale(p, k)

## Advance this ACTIVE state by real `dt` seconds under gravity + a constant thrust accel `a_thrust` (BCI DVec3),
## sub-stepping so no step exceeds DT_SUB_MAX (§2.3). Drag is added per-substep from the live velocity (it depends
## on v, so it cannot be a constant like thrust). Semi-implicit: v update uses the accel at the CURRENT position,
## then p advances with the NEW v — the symplectic ordering that kills secular energy drift.
func integrate(dt: float, a_thrust: PackedFloat64Array = DV.v(0.0, 0.0, 0.0), t: float = 0.0) -> void:
	if dt <= 0.0:
		return
	var nsub := int(ceil(dt / DT_SUB_MAX))
	if nsub < 1:
		nsub = 1
	var h := dt / float(nsub)
	for i in range(nsub):
		var a := grav_accel(body, pos)
		a = DV.add(a, a_thrust)
		var ad := drag_accel(body, pos, vel, t)
		a = DV.add(a, ad)
		vel = DV.add(vel, DV.scale(a, h))          # v += a·h  (accel at current p)
		pos = DV.add(pos, DV.scale(vel, h))         # p += v·h  (with the updated v — symplectic)

## Specific orbital energy ε = |v|²/2 − gm/r (blocks²/s²) — the ENERGY gate's conserved quantity.
func specific_energy() -> float:
	var r := DV.length(pos)
	var v2 := DV.dot(vel, vel)
	if r <= 0.0:
		return 0.0
	return 0.5 * v2 - CosmosEphemeris.gm_game(body) / r

## Specific angular momentum vector h = r × v (DVec3 f64); |h| is the ENERGY gate's second invariant.
func angular_momentum() -> PackedFloat64Array:
	return _cross(pos, vel)

# ---------------------------------------------------------------------------------------
# Atmosphere drag — §2.6 (only bodies with an atmosphere, only below ATMO_TOP)
# ---------------------------------------------------------------------------------------

## Drag acceleration (BCI DVec3) at BCI position `p`, velocity `v`, time `t`. Zero unless `body` has an atmosphere
## AND h < ATMO_TOP. The air CO-ROTATES with the body (v_air = v_bci − ω⃗ × p_bci); a_drag = −k(h)·|v_air|·v_air
## with k(h) = K0·exp(−h/H_SCALE), K0 = FEEL_G/DRAG_TERMINAL² ⇒ terminal speed ≈ DRAG_TERMINAL at h=0.
static func drag_accel(body_name: String, p: PackedFloat64Array, v: PackedFloat64Array, t: float) -> PackedFloat64Array:
	if not CosmosEphemeris.has_atmo(body_name):
		return DV.v(0.0, 0.0, 0.0)
	var r := DV.length(p)
	var h := r - CosmosEphemeris.radius_of(body_name)
	if h >= CubeSphere.ATMO_TOP:
		return DV.v(0.0, 0.0, 0.0)
	# air velocity in BCI: the co-rotating atmosphere ω⃗ × p (ω⃗ = ω ẑ)
	var w := CosmosEphemeris.omega_spin(body_name)
	var v_atmo := DV.v(-w * p[1], w * p[0], 0.0)          # ω ẑ × p = (−ω·p_y, ω·p_x, 0)
	var v_air := DV.sub(v, v_atmo)
	var spd := DV.length(v_air)
	if spd <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var k0 := CosmosGravity.feel_g(body_name) / (CubeSphere.DRAG_TERMINAL * CubeSphere.DRAG_TERMINAL)
	var kh := k0 * exp(-h / DRAG_H_SCALE)
	var coef := -kh * spd                                  # a = −k·|v_air|·v_air
	return DV.scale(v_air, coef)

# ---------------------------------------------------------------------------------------
# Kepler freeze / thaw — §2.3 (elliptic bound orbits only)
# ---------------------------------------------------------------------------------------

## True iff the current ACTIVE state is a bound ellipse eligible to freeze to RAILS (ε < 0 ⇒ e < 1). Hyperbolic /
## parabolic states return false and stay ACTIVE (correct + cheap; the universal-variable solver stays out of v1).
func is_elliptic() -> bool:
	var gm := CosmosEphemeris.gm_game(body)
	var r := DV.length(pos)
	if r <= 0.0:
		return false
	var e := _ecc_vector(gm)
	return DV.length(e) < 1.0 - ECC_EPS

## Freeze rv → the 7 Kepler elements [a, e, i, raan, argp, m0, epoch] at time `t`, and switch to RAILS. Standard
## f64 orbital-element extraction (circular/equatorial-safe: raan and argp collapse to 0 with the conventional
## fallbacks when their defining vectors vanish). Returns false (stays ACTIVE) if the orbit is not a bound ellipse.
func freeze(t: float) -> bool:
	var gm := CosmosEphemeris.gm_game(body)
	var r := DV.length(pos)
	if r <= 0.0:
		return false
	var hvec := _cross(pos, vel)
	var hmag := DV.length(hvec)
	var evec := _ecc_vector(gm)
	var e := DV.length(evec)
	if e >= 1.0 - ECC_EPS:
		return false                                       # not bound → stay ACTIVE
	var energy := 0.5 * DV.dot(vel, vel) - gm / r
	var a := -gm / (2.0 * energy)                          # ε = −gm/2a
	# inclination i = acos(h_z/|h|)
	var inc := 0.0
	if hmag > 0.0:
		inc = acos(clampf(hvec[2] / hmag, -1.0, 1.0))
	# node vector n = ẑ × h ; RAAN = atan2(n_y, n_x)
	var nvec := DV.v(-hvec[1], hvec[0], 0.0)
	var nmag := DV.length(nvec)
	var raan := 0.0
	if nmag > 0.0:
		raan = atan2(nvec[1], nvec[0])
	# argument of periapsis argp = angle(n, e); fall back sensibly for circular/equatorial
	var argp := 0.0
	if nmag > 0.0 and e > 0.0:
		var ca := DV.dot(nvec, evec) / (nmag * e)
		argp = acos(clampf(ca, -1.0, 1.0))
		if evec[2] < 0.0:
			argp = TAU - argp
	elif e > 0.0:
		# equatorial: measure from +x
		argp = atan2(evec[1], evec[0])
		if hvec[2] < 0.0:
			argp = TAU - argp
	# true anomaly ν = angle(e, r); then E and M
	var nu := 0.0
	if e > 0.0:
		var cnu := DV.dot(evec, pos) / (e * r)
		nu = acos(clampf(cnu, -1.0, 1.0))
		if DV.dot(pos, vel) < 0.0:
			nu = TAU - nu
	else:
		# circular: measure ν from the node (or +x if none)
		var refx := nvec if nmag > 0.0 else DV.v(1.0, 0.0, 0.0)
		var rl := DV.length(refx)
		var cnu := DV.dot(refx, pos) / (rl * r)
		nu = acos(clampf(cnu, -1.0, 1.0))
		if pos[2] < 0.0:
			nu = TAU - nu
	var ecc_anom := _true_to_ecc(nu, e)
	var m := ecc_anom - e * sin(ecc_anom)                  # Kepler's equation, M at epoch t
	elems = PackedFloat64Array([a, e, inc, raan, argp, m, t])
	mode = RAILS
	return true

## Thaw: recompute rv at time `t` from the frozen elements and switch back to ACTIVE. Solves Kepler's equation
## M(t) = E − e·sinE by Newton (~4 iters, f64), builds the perifocal position/velocity, and rotates it into BCI by
## R_z(raan)·R_x(i)·R_z(argp). Pure — safe to call at any t; `mode` is set ACTIVE so the caller can integrate on.
func thaw(t: float) -> void:
	var s := rails_state(t)
	pos = s[0]
	vel = s[1]
	mode = ACTIVE

## The closed-form RAILS [pos, vel] (both BCI DVec3) at time `t` WITHOUT changing mode — the zero-cost coast query
## (§2.3). period() and mean-anomaly wrap make rails_state(t+T) == rails_state(t) exactly.
func rails_state(t: float) -> Array:
	var a := elems[0]; var e := elems[1]; var inc := elems[2]
	var raan := elems[3]; var argp := elems[4]; var m0 := elems[5]; var epoch := elems[6]
	var gm := CosmosEphemeris.gm_game(body)
	var n := sqrt(gm / (a * a * a))                        # mean motion
	var m := m0 + n * (t - epoch)
	var ea := _solve_kepler(m, e)
	var cE := cos(ea); var sE := sin(ea)
	var rmag := a * (1.0 - e * cE)
	# perifocal position
	var px := a * (cE - e)
	var py := a * sqrt(1.0 - e * e) * sE
	# perifocal velocity: d/dt via Ė = n/(1−e·cosE)
	var edot := n / (1.0 - e * cE)
	var vx := -a * sE * edot
	var vy := a * sqrt(1.0 - e * e) * cE * edot
	var p_pf := DV.v(px, py, 0.0)
	var v_pf := DV.v(vx, vy, 0.0)
	var p_bci := _rot_perifocal_to_bci(p_pf, raan, inc, argp)
	var v_bci := _rot_perifocal_to_bci(v_pf, raan, inc, argp)
	return [p_bci, v_bci]

## Orbital period (s) of the frozen RAILS orbit = 2π√(a³/gm). Undefined (0) if not on rails.
func period() -> float:
	if elems.size() < 7:
		return 0.0
	var a := elems[0]
	var gm := CosmosEphemeris.gm_game(body)
	return TAU * sqrt((a * a * a) / gm)

# ---------------------------------------------------------------------------------------
# §2.4 frame algebra — pure statics, BCI ↔ body-fixed (scene). θ = spin_angle(body,t); ω⃗ = omega_spin·ẑ.
# ---------------------------------------------------------------------------------------

## BCI → body-fixed (scene): p_fixed = R_z(−θ)·p_bci. Pure static DVec3 map.
static func pos_bci_to_fixed(body_name: String, p_bci: PackedFloat64Array, t: float) -> PackedFloat64Array:
	return _rot_z(p_bci, -CosmosEphemeris.spin_angle(body_name, t))

## BCI → body-fixed velocity: v_fixed = R_z(−θ)·(v_bci − ω⃗ × p_bci). The ω×r term removes the frame's rotation.
static func vel_bci_to_fixed(body_name: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float) -> PackedFloat64Array:
	var w := CosmosEphemeris.omega_spin(body_name)
	var wxp := DV.v(-w * p_bci[1], w * p_bci[0], 0.0)      # ω ẑ × p
	return _rot_z(DV.sub(v_bci, wxp), -CosmosEphemeris.spin_angle(body_name, t))

## body-fixed → BCI: p_bci = R_z(θ)·p_fixed. Pure static DVec3 map.
static func pos_fixed_to_bci(body_name: String, p_fixed: PackedFloat64Array, t: float) -> PackedFloat64Array:
	return _rot_z(p_fixed, CosmosEphemeris.spin_angle(body_name, t))

## body-fixed → BCI velocity: v_bci = R_z(θ)·(v_fixed + ω⃗ × p_fixed) — THE ω×r term (33.4 m/s eastward at the
## Earth equator; the free eastward-launch Δv). Note the ω×p is formed in the body-fixed frame then rotated by
## R_z(θ) together with v_fixed — algebraically identical to the inverse of vel_bci_to_fixed.
static func vel_fixed_to_bci(body_name: String, p_fixed: PackedFloat64Array, v_fixed: PackedFloat64Array, t: float) -> PackedFloat64Array:
	var w := CosmosEphemeris.omega_spin(body_name)
	var wxp := DV.v(-w * p_fixed[1], w * p_fixed[0], 0.0)  # ω ẑ × p_fixed
	return _rot_z(DV.add(v_fixed, wxp), CosmosEphemeris.spin_angle(body_name, t))

## The exact equatorial spin speed |v_bci| for a point standing still (body-fixed) at radius `r` on the equator
## (z=0): ω·r. Earth surface ⇒ ω·R = (2π/1200)·6371 ≈ 33.36 m/s eastward (the pinned G-O1-HANDOFF number).
static func equatorial_spin_speed(body_name: String, r: float) -> float:
	return CosmosEphemeris.omega_spin(body_name) * r

# ---------------------------------------------------------------------------------------
# internal f64 helpers
# ---------------------------------------------------------------------------------------

static func _cross(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return DV.v(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

## Eccentricity vector e = (v×h)/gm − r̂ (points to periapsis; |e| is the scalar eccentricity).
func _ecc_vector(gm: float) -> PackedFloat64Array:
	var r := DV.length(pos)
	var hvec := _cross(pos, vel)
	var vxh := _cross(vel, hvec)
	var t1 := DV.scale(vxh, 1.0 / gm)
	var t2 := DV.scale(pos, 1.0 / r)
	return DV.sub(t1, t2)

## True anomaly ν → eccentric anomaly E (elliptic): tan(E/2) = √((1−e)/(1+e))·tan(ν/2).
static func _true_to_ecc(nu: float, e: float) -> float:
	var half := atan2(sqrt(1.0 - e) * sin(nu / 2.0), sqrt(1.0 + e) * cos(nu / 2.0))
	return 2.0 * half

## Solve Kepler's equation M = E − e·sinE for E by Newton (~5 iters; converges from E0 = M for e < 1).
static func _solve_kepler(m: float, e: float) -> float:
	var ea := m
	for i in range(8):
		var f := ea - e * sin(ea) - m
		var fp := 1.0 - e * cos(ea)
		ea -= f / fp
	return ea

## R_z(ang)·v about +Z (the spin/north axis); z untouched.
static func _rot_z(v: PackedFloat64Array, ang: float) -> PackedFloat64Array:
	var c := cos(ang); var s := sin(ang)
	return DV.v(c * v[0] - s * v[1], s * v[0] + c * v[1], v[2])

## R_x(ang)·v about +X.
static func _rot_x(v: PackedFloat64Array, ang: float) -> PackedFloat64Array:
	var c := cos(ang); var s := sin(ang)
	return DV.v(v[0], c * v[1] - s * v[2], s * v[1] + c * v[2])

## perifocal → BCI: R_z(raan)·R_x(inc)·R_z(argp)·v.
static func _rot_perifocal_to_bci(v: PackedFloat64Array, raan: float, inc: float, argp: float) -> PackedFloat64Array:
	return _rot_z(_rot_x(_rot_z(v, argp), inc), raan)
