extends RefCounted
class_name OrbitalState
## COSMOS ORBITAL O1 / SPACE-NAV SN1 — the ONE f64 orbital-state the player/grids/debris share
## (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.3, docs/COSMOS-SPACE-NAV-DESIGN.md §5). Carries a body-centred
## INERTIAL (BCI) [pos, vel] pair in f64 blocks / blocks·s⁻¹, integrated symplectically (velocity-Verlet
## with a 1/60-s substep clamp), frozen to Kepler elements when coasting (drift-free, zero per-tick cost)
## and thawed on demand. It also hosts the pure-static FRAME ALGEBRA (§2.4/§5.1): the exact affine maps
## between the surface (body-fixed rotating), BCI, and heliocentric frames — the maps that make every
## nav/locomotion handoff a lossless re-expression rather than a teleport.
##
## PRECISION: all math is f64 (GDScript float is IEEE-754 f64); positions/velocities are DVec3
## (PackedFloat64Array) — NEVER truncated through an f32 Vector3 inside the integrator or the maps.
## GM: every local dynamic reads CosmosGravity.gm_dyn (SPACE-NAV §3), never the sky's GM_game.
##
## NEVER-OOM: an instance is ~100 B (two DVec3 + a 7-f64 element array + scalars); ORBIT_ACTIVE_MAX = 8
## ACTIVE entities is the hard cap (O1 uses 1 — the player). Every op returns fresh 24-B DVec3 temps.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")

enum { ACTIVE, RAILS }

var body: String = "earth"
var mode: int = ACTIVE
var pos: PackedFloat64Array = DV.v(0.0, 0.0, 0.0)      # DVec3 BCI, blocks
var vel: PackedFloat64Array = DV.v(0.0, 0.0, 0.0)      # DVec3 BCI, blocks/s
var elems: PackedFloat64Array = PackedFloat64Array()   # RAILS: [a, e, i, raan, argp, M, epoch] (f64 ×7)

const SUBSTEP_MAX := 0.016666666666666666              # 1/60 s — the integrator substep clamp (§2.3)
## HARD CAP on the Verlet substep count per step() (G-SN-NOSPIRAL). Without it, `n = ceil(dt/SUBSTEP_MAX)`
## scales linearly with dt, so a post-hitch huge frame (dt = 16 s ⇒ ~960 substeps) does proportionally more
## work IN one frame, lengthening the next frame's dt → an unbounded per-frame loop (the live "spiral of
## death"). Capped at 8, a spike costs at most 8 substeps; a normal 60 fps tick (dt = 1/60) is still exactly
## 1 substep, so every accuracy gate (all step at dt ≤ 1/60) is byte-unchanged. The caller ALSO clamps the
## per-frame dt (CosmosNav.MAX_NAV_DT) so under normal wiring step never even approaches the cap — belt +
## suspenders. NOTE: a capped huge-dt tick trades integration accuracy for bounded work — correct, because
## the point is to survive the recovery frame, not to integrate 16 s of orbit precisely in it.
const SUBSTEP_MAX_N := 8
const DRAG_H_SCALE := 128.0                            # atmosphere scale height (blocks) — shared with SN4a ramp
const FREEZE_ECC_MAX := 0.999                          # v1 freezes only elliptic bound orbits (e < 1 − ε)

# ---------------------------------------------------------------------------------------
# Construction.
# ---------------------------------------------------------------------------------------

static func make(body_: String, pos_bci: PackedFloat64Array, vel_bci: PackedFloat64Array) -> OrbitalState:
	var s := OrbitalState.new()
	s.body = body_
	s.mode = ACTIVE
	s.pos = PackedFloat64Array([pos_bci[0], pos_bci[1], pos_bci[2]])
	s.vel = PackedFloat64Array([vel_bci[0], vel_bci[1], vel_bci[2]])
	return s

# ---------------------------------------------------------------------------------------
# The symplectic integrator (ACTIVE). velocity-Verlet (kick-drift-kick) with substep clamp: for a pure
# central force it is symplectic ⇒ bounded energy oscillation, zero secular drift (G-O1-ENERGY). `a_ext`
# is the external (thrust + drag) acceleration in BCI, held constant across the tick's substeps (drag is
# recomputed per physics tick by the caller — terminal velocity is a per-tick fixed point). Thaws first.
# ---------------------------------------------------------------------------------------

func step(dt: float, a_ext: PackedFloat64Array) -> void:
	if dt <= 0.0 or mode == RAILS:
		return                                          # RAILS coasts on rails; caller thaws before stepping
	var n := substep_count(dt)
	var h := dt / float(n)
	for _i in range(n):
		_verlet(h, a_ext)

## The number of velocity-Verlet substeps step() runs for `dt`: ceil(dt/SUBSTEP_MAX) clamped to [1, SUBSTEP_MAX_N].
## Pure + static so G-SN-NOSPIRAL can assert the bound directly (substep_count(16.0) == SUBSTEP_MAX_N, not ~960)
## without instrumenting the loop. This is THE line that makes the per-frame work bounded regardless of dt.
static func substep_count(dt: float) -> int:
	var n := int(ceil(dt / SUBSTEP_MAX))
	if n < 1:
		n = 1
	return mini(n, SUBSTEP_MAX_N)

func _verlet(h: float, a_ext: PackedFloat64Array) -> void:
	var a0 := DV.add(GRAV.gravity_bci(body, pos), a_ext)
	# drift: p += v·h + ½·a₀·h²
	pos = DV.add(pos, DV.add(DV.scale(vel, h), DV.scale(a0, 0.5 * h * h)))
	# kick: v += ½·(a₀ + a₁)·h, a₁ at the new position
	var a1 := DV.add(GRAV.gravity_bci(body, pos), a_ext)
	vel = DV.add(vel, DV.scale(DV.add(a0, a1), 0.5 * h))

# ---------------------------------------------------------------------------------------
# Freeze-to-Kepler / thaw (§2.3). v1 freezes ONLY elliptic bound orbits (e < FREEZE_ECC_MAX);
# hyperbolic/escape states stay ACTIVE (correct, cheap, one entity). A coasting elliptic orbit costs
# zero per tick on RAILS; any thrust/drag/input thaws it back to ACTIVE.
# ---------------------------------------------------------------------------------------

## True iff the current ACTIVE state is an elliptic bound orbit that may be frozen (no thrust/drag is the
## caller's precondition). `soi_radius` caps the apoapsis (< 0 ⇒ no SOI cap).
func can_freeze(soi_radius: float = -1.0) -> bool:
	var mu := GRAV.gm_dyn(body)
	var e := _eccentricity(mu, pos, vel)
	if e >= FREEZE_ECC_MAX:
		return false
	var r := DV.length(pos)
	var v2 := DV.dot(vel, vel)
	var energy := 0.5 * v2 - mu / r
	if energy >= 0.0:
		return false                                    # unbound
	var a := -mu / (2.0 * energy)
	var r_ap := a * (1.0 + e)
	if soi_radius > 0.0 and r_ap > soi_radius:
		return false
	return true

## Convert the ACTIVE [pos,vel] into Kepler elements at epoch `t` and go RAILS. Pure once frozen.
func freeze(t: float) -> void:
	elems = rv_to_coe(GRAV.gm_dyn(body), pos, vel, t)
	mode = RAILS

## Re-expand the RAILS elements to [pos,vel] at time `t` and go ACTIVE (any disturbance thaws).
func thaw(t: float) -> void:
	var rv := coe_to_rv(GRAV.gm_dyn(body), elems, t)
	pos = rv[0]
	vel = rv[1]
	mode = ACTIVE

## Closed-form BCI position at time `t` for a RAILS state (zero per-tick cost). ACTIVE ⇒ current pos.
func position_at(t: float) -> PackedFloat64Array:
	if mode == RAILS:
		return coe_to_rv(GRAV.gm_dyn(body), elems, t)[0]
	return pos

## Closed-form BCI velocity at time `t` for a RAILS state. ACTIVE ⇒ current vel.
func velocity_at(t: float) -> PackedFloat64Array:
	if mode == RAILS:
		return coe_to_rv(GRAV.gm_dyn(body), elems, t)[1]
	return vel

# ---------------------------------------------------------------------------------------
# Classical orbital-element conversions (pure static f64). Standard rv↔coe; robust to the equatorial
# (n≈0) and circular (e≈0) degeneracies by the usual conventions (RAAN→0 equatorial, argp→0 circular,
# the freed angle folded into the true anomaly / longitude). Round-trips to f64 ε for a generic orbit.
# elems = [a, e, inc, raan, argp, M, epoch].
# ---------------------------------------------------------------------------------------

const _DEGEN := 1.0e-11

static func rv_to_coe(mu: float, r_vec: PackedFloat64Array, v_vec: PackedFloat64Array, epoch: float) -> PackedFloat64Array:
	var r := DV.length(r_vec)
	var v2 := DV.dot(v_vec, v_vec)
	var rv_dot := DV.dot(r_vec, v_vec)
	var h_vec := _cross(r_vec, v_vec)
	var h := DV.length(h_vec)
	# node vector n = ẑ × h = (−h_y, h_x, 0)
	var n_vec := DV.v(-h_vec[1], h_vec[0], 0.0)
	var n := DV.length(n_vec)
	# eccentricity vector e = ((v²−μ/r)·r − (r·v)·v)/μ
	var e_vec := DV.scale(DV.sub(DV.scale(r_vec, v2 - mu / r), DV.scale(v_vec, rv_dot)), 1.0 / mu)
	var e := DV.length(e_vec)
	var energy := 0.5 * v2 - mu / r
	var a := -mu / (2.0 * energy)
	var inc := acos(clampf(h_vec[2] / h, -1.0, 1.0)) if h > 0.0 else 0.0

	var raan := 0.0
	if n > _DEGEN:
		raan = acos(clampf(n_vec[0] / n, -1.0, 1.0))
		if n_vec[1] < 0.0:
			raan = TAU - raan

	var argp := 0.0
	if n > _DEGEN and e > _DEGEN:
		argp = acos(clampf(DV.dot(n_vec, e_vec) / (n * e), -1.0, 1.0))
		if e_vec[2] < 0.0:
			argp = TAU - argp
	elif e > _DEGEN:                                     # equatorial, non-circular: longitude of periapsis
		argp = atan2(e_vec[1], e_vec[0])
		if h_vec[2] < 0.0:
			argp = TAU - argp

	var nu := 0.0
	if e > _DEGEN:
		nu = acos(clampf(DV.dot(e_vec, r_vec) / (e * r), -1.0, 1.0))
		if rv_dot < 0.0:
			nu = TAU - nu
	elif n > _DEGEN:                                     # circular inclined: argument of latitude
		nu = acos(clampf(DV.dot(n_vec, r_vec) / (n * r), -1.0, 1.0))
		if r_vec[2] < 0.0:
			nu = TAU - nu
	else:                                               # circular equatorial: true longitude
		nu = acos(clampf(r_vec[0] / r, -1.0, 1.0))
		if r_vec[1] < 0.0:
			nu = TAU - nu

	# eccentric → mean anomaly (elliptic form)
	var big_e := 2.0 * atan2(sqrt(maxf(1.0 - e, 0.0)) * sin(nu * 0.5), sqrt(1.0 + e) * cos(nu * 0.5))
	var m := big_e - e * sin(big_e)
	return PackedFloat64Array([a, e, inc, raan, argp, m, epoch])

static func coe_to_rv(mu: float, el: PackedFloat64Array, t: float) -> Array:
	var a := el[0]
	var e := el[1]
	var inc := el[2]
	var raan := el[3]
	var argp := el[4]
	var m0 := el[5]
	var epoch := el[6]
	var n := sqrt(mu / (a * a * a))
	var m := m0 + n * (t - epoch)
	var big_e := _solve_kepler(m, e)
	var nu := 2.0 * atan2(sqrt(1.0 + e) * sin(big_e * 0.5), sqrt(maxf(1.0 - e, 0.0)) * cos(big_e * 0.5))
	var r := a * (1.0 - e * cos(big_e))
	# perifocal position + velocity
	var p_pf := DV.v(r * cos(nu), r * sin(nu), 0.0)
	var p_semi := a * (1.0 - e * e)                     # semi-latus rectum
	var vfac := sqrt(mu / p_semi)
	var v_pf := DV.v(-vfac * sin(nu), vfac * (e + cos(nu)), 0.0)
	# perifocal → inertial: R_z(raan)·R_x(inc)·R_z(argp)
	var p := _rot_z(_rot_x(_rot_z(p_pf, argp), inc), raan)
	var v := _rot_z(_rot_x(_rot_z(v_pf, argp), inc), raan)
	return [p, v]

## Newton solve of Kepler's equation E − e·sinE = M for the eccentric anomaly (elliptic). ~6 iterations
## to f64 ε; the initial guess M (or M+e·sign) is well inside the basin for e < 1.
static func _solve_kepler(m: float, e: float) -> float:
	var big_e := m if e < 0.8 else PI
	for _i in range(12):
		var f := big_e - e * sin(big_e) - m
		var fp := 1.0 - e * cos(big_e)
		var d := f / fp
		big_e -= d
		if absf(d) < 1.0e-15:
			break
	return big_e

# ---------------------------------------------------------------------------------------
# The frame algebra (§2.4 / §5.1) — pure static exact affine maps. θ = spin_angle(body,t),
# ω⃗ = omega_spin(body)·ẑ. Every map is invertible in closed form ⇒ each handoff has a continuity gate.
# ---------------------------------------------------------------------------------------

## ω⃗ × p for ω⃗ = ω·ẑ = (0,0,ω): (−ω·p_y, ω·p_x, 0). The Coriolis/spin term.
static func omega_cross(body: String, p: PackedFloat64Array) -> PackedFloat64Array:
	var w := EPH.omega_spin(body)
	return DV.v(-w * p[1], w * p[0], 0.0)

## BCI → body-fixed (scene) frame at t: p_fix = R_z(−θ)·p_bci; v_fix = R_z(−θ)·(v_bci − ω⃗×p_bci).
static func bci_to_fixed(body: String, t: float, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array) -> Array:
	var th := EPH.spin_angle(body, t)
	var p_fix := _rot_z(p_bci, -th)
	var v_fix := _rot_z(DV.sub(v_bci, omega_cross(body, p_bci)), -th)
	return [p_fix, v_fix]

## body-fixed → BCI at t: p_bci = R_z(θ)·p_fix; v_bci = R_z(θ)·(v_fix + ω⃗×p_fix). The +ω⃗×r term is
## the eastward-launch bonus (16.1 m/s interim / 33.4 post-O3 at the equator — G-O1-HANDOFF's pinned number).
static func fixed_to_bci(body: String, t: float, p_fix: PackedFloat64Array, v_fix: PackedFloat64Array) -> Array:
	var th := EPH.spin_angle(body, t)
	var p_bci := _rot_z(p_fix, th)
	var v_bci := _rot_z(DV.add(v_fix, omega_cross(body, p_fix)), th)
	return [p_bci, v_bci]

## BCI → heliocentric inertial: p_hel = p_bci + body_pos_helio(body,t); v_hel = v_bci + body_vel_helio(body,t).
static func bci_to_helio(body: String, t: float, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array) -> Array:
	return [DV.add(p_bci, EPH.body_pos_helio(body, t)), DV.add(v_bci, EPH.body_vel_helio(body, t))]

## heliocentric → BCI: the exact inverse of bci_to_helio.
static func helio_to_bci(body: String, t: float, p_hel: PackedFloat64Array, v_hel: PackedFloat64Array) -> Array:
	return [DV.sub(p_hel, EPH.body_pos_helio(body, t)), DV.sub(v_hel, EPH.body_vel_helio(body, t))]

# ---------------------------------------------------------------------------------------
# Off-surface render placement — anchor-follow (§2.8; SPACE-NAV R2, ADOPTED). The shipped integer
# floating-origin anchor (world_manager `_anchor_offset`, REANCHOR_TRIGGER_BLOCKS = 8192) starts firing
# in ORBITAL mode: when |p_fixed − anchor| > trigger, step the anchor by INTEGER multiples of `quantum`
# (4096) toward the player and re-place every absolute node. anchor_snap is the pure step rule; place_rel
# is the f64-subtract-then-f32-downgrade placement (sub-mm ulp at ≤ 8k magnitude). The anchor is
# render-only — it never touches the BCI OrbitalState (asserted by G-O1-ANCHOR). NOTE: SPACE-NAV R1
# REJECTS the O1O4 §2.8 H_FARSWAP impostor swap; only the anchor-follow half of §2.8 is adopted here.
# ---------------------------------------------------------------------------------------

## The new anchor for a player at body-fixed position `p` (DVec3): unchanged while |p − anchor| ≤ trigger,
## else snapped onto the global integer `quantum` grid nearest the player (each axis independently). The
## returned anchor is always an exact integer multiple of `quantum` away from the old one ⇒ every
## already-placed node shifts by the SAME integer vector, so relative positions are preserved exactly.
static func anchor_snap(anchor: PackedFloat64Array, p: PackedFloat64Array, trigger: float, quantum: float) -> PackedFloat64Array:
	var d := DV.sub(p, anchor)
	if DV.length(d) <= trigger:
		return PackedFloat64Array([anchor[0], anchor[1], anchor[2]])
	return DV.v(
		anchor[0] + round(d[0] / quantum) * quantum,
		anchor[1] + round(d[1] / quantum) * quantum,
		anchor[2] + round(d[2] / quantum) * quantum)

## Place an f64 world position `p` relative to the f64 `anchor` as a render-side Vector3 — the subtraction
## is done in f64 BEFORE the f32 downgrade, so a node ≤ 8k blocks from the anchor is placed to sub-mm ulp.
static func place_rel(p: PackedFloat64Array, anchor: PackedFloat64Array) -> Vector3:
	return Vector3(float(p[0] - anchor[0]), float(p[1] - anchor[1]), float(p[2] - anchor[2]))

# ---------------------------------------------------------------------------------------
# Atmosphere drag (§2.6) — pure static. Air co-rotates with the body: v_air = v_bci − ω⃗×p_bci;
# a_drag = −k(h)·|v_air|·v_air, k(h) = K0·exp(−h/H_SCALE). K0 = datum_gravity/DRAG_TERMINAL² ⇒ terminal
# speed == DRAG_TERMINAL at h = 0 EXACTLY, balanced against the gravity the ACTIVE integrator actually
# applies (point-mass GM_dyn/R² = datum_gravity). NOTE: the parent §2.6 wrote K0 = FEEL_G/DRAG_TERMINAL²,
# which assumed the integrator used the blend field (== feel-g at the surface); this build integrates the
# pure point-mass gravity for clean energy conservation, so datum_gravity is the self-consistent K0
# (interim: 24.6 vs the design's 22 — a 12% K0 shift that makes terminal exactly 55 not 58). Only bodies
# with an atmosphere (Earth yes, Moon no), only below ATMO_TOP.
# ---------------------------------------------------------------------------------------

static func has_atmo(body: String) -> bool:
	return body == "earth"

static func atmos_drag_bci(body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array) -> PackedFloat64Array:
	if not has_atmo(body):
		return DV.v(0.0, 0.0, 0.0)
	var r := DV.length(p_bci)
	var h := r - GRAV.r_vox(body)
	if h > CubeSphere.ATMO_TOP:
		return DV.v(0.0, 0.0, 0.0)                      # no drag above the atmosphere
	var v_air := DV.sub(v_bci, omega_cross(body, p_bci))
	var speed := DV.length(v_air)
	if speed <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var k0 := GRAV.datum_gravity(body) / (CubeSphere.DRAG_TERMINAL * CubeSphere.DRAG_TERMINAL)
	var k := k0 * exp(-h / DRAG_H_SCALE)
	return DV.scale(v_air, -k * speed)

# ---------------------------------------------------------------------------------------
# Conserved-quantity accessors (for gates / HUD).
# ---------------------------------------------------------------------------------------

## Specific orbital energy ξ = v²/2 − μ/r (blocks²/s²). Constant along a coasting orbit.
static func specific_energy(mu: float, p: PackedFloat64Array, v: PackedFloat64Array) -> float:
	return 0.5 * DV.dot(v, v) - mu / DV.length(p)

## Specific angular momentum vector h = r × v (blocks²/s). Constant along a coasting orbit.
static func ang_momentum(p: PackedFloat64Array, v: PackedFloat64Array) -> PackedFloat64Array:
	return _cross(p, v)

static func _eccentricity(mu: float, r_vec: PackedFloat64Array, v_vec: PackedFloat64Array) -> float:
	var r := DV.length(r_vec)
	var v2 := DV.dot(v_vec, v_vec)
	var rv_dot := DV.dot(r_vec, v_vec)
	var e_vec := DV.scale(DV.sub(DV.scale(r_vec, v2 - mu / r), DV.scale(v_vec, rv_dot)), 1.0 / mu)
	return DV.length(e_vec)

# ---------------------------------------------------------------------------------------
# f64 vector primitives (cross + axis rotations) — DVecF64 has add/sub/scale/dot/length only.
# ---------------------------------------------------------------------------------------

static func _cross(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return DV.v(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

## Rotate DVec3 about +Z by `ang`: (x·c − y·s, x·s + y·c, z).
static func _rot_z(p: PackedFloat64Array, ang: float) -> PackedFloat64Array:
	var c := cos(ang)
	var s := sin(ang)
	return DV.v(p[0] * c - p[1] * s, p[0] * s + p[1] * c, p[2])

## Rotate DVec3 about +X by `ang`: (x, y·c − z·s, y·s + z·c).
static func _rot_x(p: PackedFloat64Array, ang: float) -> PackedFloat64Array:
	var c := cos(ang)
	var s := sin(ang)
	return DV.v(p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c)
