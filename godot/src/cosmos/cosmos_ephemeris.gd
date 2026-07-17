extends RefCounted
class_name CosmosEphemeris
## COSMOS ORBITAL O0 — the pure f64 celestial-mechanics kernel (docs/COSMOS-ORBITAL-DESIGN.md
## §3.3, §3.4, §4.2). Static, engine-free, deterministic: every function is a pure function of
## its arguments plus the frozen body table — NO engine singletons, NO wall clock inside the math,
## NO randi(). This makes it worker-safe and headless-gate-testable (verify_orbital_sky.gd), and it
## carries the whole scale/time/mass model that O1+ (real orbits, SOI, grids) reads as data.
##
## THE LOCKED SCALE MODEL (§3.3, decision D2, USER-LOCKED):
##   1 unit = 1 block = 1 m. Celestial lengths are real km ÷ 1000. One Earth rotation = 20 min real,
##   so time runs 72× (86400 s ÷ 1200 s). 1:1000 lengths + 72× time cannot keep real masses, so
##   GM is the FREE PARAMETER chosen (via Kepler) to keep Newton exact at those two scales:
##       GM_game = GM_real × s_L³ / s_T²  = GM_real × (10⁻³)³ × 72²  = GM_real × 5.184×10⁻⁶
##   Corollaries: every period = real ÷ 72, every orbital speed = real × 0.072, every dimensionless
##   ratio (angular sizes, eclipse geometry, orbits-per-day) is EXACTLY real. One clock: ephemeris
##   time = real seconds; the scaled GM alone produces the 72× sky.
##
## This table is SEPARATE from CubeSphere.gm_for() — that stays the near-field FEEL anchor (§3.3.1,
## walk gravity 22); this GM table is the far-field Kepler truth (supersedes gm_for above the blend
## band, which is O1). O0 uses this kernel for the sky only (Sun/Moon direction + day-night).
##
## PRECISION: positions are DVecF64 (PackedFloat64Array) — Earth–Sun 1.496e8 needs f64; the render
## layer downgrades DIRECTIONS to Vector3 (§4.3).

const DV := preload("res://src/cosmos/dvec3.gd")

# ---------------------------------------------------------------------------------------
# Scale constants (§3.3) — the three locked numbers everything else derives from.
# ---------------------------------------------------------------------------------------

## Time compression: game runs this many times faster than reality (86400 s day / 1200 s day).
const TIME_COMPRESSION := 72.0
## One Earth solar day in game seconds (= real 86400 s ÷ 72). The Earth spin period.
const DAY_GAME := 1200.0
## Length scale: 1 game block = 1000 real metres for celestial quantities (real km → blocks).
const LENGTH_SCALE := 1.0e-3
## The GM scaling law (§3.3): GM_game = GM_real × s_L³/s_T² = (10⁻³)³ × 72². Written as the literal
## 5.184e-6 (== 1e-9 × 5184) so the intent is legible; asserted against the computed product by the
## gate (they agree to f64 ulp — the direct == is a 1-ulp miss, hence a tolerance there).
const GM_SCALE := 5.184e-6

## Global time-warp multiplier (D2 note / §3.4): v1 = 1 (a warp>1 scales the SKY only unless GM is
## co-scaled, so it ships at 1). The clock multiplies real dt by this — the ONE knob for fast-forward.
const TIME_WARP := 1.0

# ---------------------------------------------------------------------------------------
# The body table (§3.3) — fundamental REAL inputs only; GM_game / mean-motion / spin are DERIVED so
# the Newton scaling law holds BY CONSTRUCTION (no hand-rounded GM that could drift from the law).
#   gm_real      : m³/s² (real).                        r        : body radius in blocks (= real km).
#   parent       : the body it orbits ("" = system centre, the Sun).
#   a            : circular orbit radius in blocks (= real km ÷ 1000; 0 for the Sun).
#   m0           : orbit mean-anomaly phase at t=0 (rad; ecc=0 ⇒ mean == true).
#   spin_period  : body-fixed spin period in game seconds (0 ⇒ use the tidal rule or no spin).
#   spin_phase0  : spin angle at t=0 (rad).
#   tidal        : true ⇒ spin_angle = orbit_angle + PI (same face parent-ward always — the Moon).
#   ecc, incl, axial_tilt : v1 = 0 (slots reserved for O5 eccentric orbits / seasons).
# Canonical GM_game / period cross-checks are in the doc §3.3 table and asserted by the gate.
# ---------------------------------------------------------------------------------------
const BODIES := {
	"sun": {
		"gm_real": 1.327e20, "r": 696000.0, "parent": "", "a": 0.0, "m0": 0.0,
		"spin_period": 0.0, "spin_phase0": 0.0, "tidal": false,
		"ecc": 0.0, "incl": 0.0, "axial_tilt": 0.0,
	},
	"earth": {
		"gm_real": 3.986e14, "r": 6371.0, "parent": "sun", "a": 149.6e6, "m0": 0.0,
		"spin_period": 1200.0, "spin_phase0": 0.0, "tidal": false,
		"ecc": 0.0, "incl": 0.0, "axial_tilt": 0.0,
	},
	"moon": {
		"gm_real": 4.905e12, "r": 1737.0, "parent": "earth", "a": 384400.0, "m0": 0.0,
		"spin_period": 0.0, "spin_phase0": 0.0, "tidal": true,
		"ecc": 0.0, "incl": 0.0, "axial_tilt": 0.0,
	},
}

# ---------------------------------------------------------------------------------------
# CosmosClock — the ONLY mutable state in the celestial layer (§4.2). `t` = f64 seconds since the
# world epoch; a savegame is this one float. advance(real_dt) folds in TIME_WARP so a global
# fast-forward composes cleanly. Deterministic: advance(a); advance(b) leaves t == a+b exactly
# (the gate asserts the sum), and the ephemeris is a pure function of t (no hidden clock read).
# ---------------------------------------------------------------------------------------
class CosmosClock extends RefCounted:
	var t: float = 0.0                         # f64 seconds since epoch

	func _init(t0: float = 0.0) -> void:
		t = t0

	## Advance the clock by a REAL frame delta (seconds); the sky moves 72× via the scaled GM, and
	## TIME_WARP (=1) is the only extra multiplier. Pure accumulation — no wall clock is read here.
	func advance(real_dt: float) -> void:
		t += real_dt * CosmosEphemeris.TIME_WARP

	func now() -> float:
		return t

# ---------------------------------------------------------------------------------------
# Body-table accessors (pure reads of the frozen const table).
# ---------------------------------------------------------------------------------------

static func has_body(body: String) -> bool:
	return BODIES.has(body)

static func gm_real(body: String) -> float:
	return float(BODIES[body]["gm_real"])

## GM_game = GM_real × GM_SCALE — DERIVED so the scaling law is exact (§3.3). Matches the doc's
## canonical hand-values (2.066e9 / 2.543e7 / 6.880e14) to 4 sig figs (gate asserts).
static func gm_game(body: String) -> float:
	return float(BODIES[body]["gm_real"]) * GM_SCALE

static func radius_of(body: String) -> float:
	return float(BODIES[body]["r"])

static func parent_of(body: String) -> String:
	return String(BODIES[body]["parent"])

static func orbit_a(body: String) -> float:
	return float(BODIES[body]["a"])

## Mean motion n = √(GM_parent / a³) rad/s (§4.2, circular v1). DERIVED from GM and a so the
## ephemeris obeys Newton exactly; the resulting period (2π/n) matches the locked calendar to
## <0.01% for Earth and ~0.45% for the Moon (the real Moon's mean-distance/mass/period triple is
## not a clean one-body Kepler set — the Earth–Moon barycentre + osculating elements — an
## inconsistency the ÷1000/÷72 scaling preserves EXACTLY; see the gate's month tolerance).
static func omega_orbit(body: String) -> float:
	var par := parent_of(body)
	var a := orbit_a(body)
	if par == "" or a <= 0.0:
		return 0.0
	return sqrt(gm_game(par) / (a * a * a))

## Orbital period (game seconds) = 2π / n. 0 for the system centre (the Sun).
static func orbit_period(body: String) -> float:
	var n := omega_orbit(body)
	if n == 0.0:
		return 0.0
	return TAU / n

## Spin angular rate (rad/s). Tidal bodies inherit their orbital rate (spin == orbit); otherwise
## 2π/spin_period; 0 if no spin is defined.
static func omega_spin(body: String) -> float:
	if bool(BODIES[body]["tidal"]):
		return omega_orbit(body)
	var sp := float(BODIES[body]["spin_period"])
	if sp <= 0.0:
		return 0.0
	return TAU / sp

# ---------------------------------------------------------------------------------------
# Ephemeris — pure functions of t (circular orbits v1; ecc/incl slots = 0).
# ---------------------------------------------------------------------------------------

## Orbit phase (mean anomaly, rad) of `body` about its parent at time t: M0 + n·t.
static func orbit_angle(body: String, t: float) -> float:
	return float(BODIES[body]["m0"]) + omega_orbit(body) * t

## Position of `body` RELATIVE TO ITS PARENT (DVec3 blocks), in the parent's inertial frame. Circular
## orbit of radius a in the XY plane (incl = 0 ⇒ the ecliptic == the equatorial plane, the axial_tilt=0
## slot). The system centre / any parentless body sits at the origin of its own frame.
static func body_pos_parent(body: String, t: float) -> PackedFloat64Array:
	var a := orbit_a(body)
	if parent_of(body) == "" or a <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var th := orbit_angle(body, t)
	return DV.v(a * cos(th), a * sin(th), 0.0)

## Heliocentric (system-centre) position of `body` (DVec3 blocks): the chain of parent-relative
## offsets up to the Sun at the origin. Pure recursion over the (acyclic) parent graph.
static func body_pos_helio(body: String, t: float) -> PackedFloat64Array:
	var par := parent_of(body)
	if par == "":
		return DV.v(0.0, 0.0, 0.0)                     # the Sun is the origin
	return DV.add(body_pos_helio(par, t), body_pos_parent(body, t))

## Body-fixed spin angle (rad) of `body` at t. Tidal lock is the one-line rule (§4.2):
## spin_angle(moon) = orbit_angle(moon) + PI ⇒ the same face stays parent-ward forever.
static func spin_angle(body: String, t: float) -> float:
	if bool(BODIES[body]["tidal"]):
		return orbit_angle(body, t) + PI
	return float(BODIES[body]["spin_phase0"]) + omega_spin(body) * t

## Unit direction (render-side Vector3) from `from_body` to `to_body` at t, in the INERTIAL frame.
## e.g. dir_to("earth","sun",t) is the Sun direction from Earth (before the body-fixed spin rotation).
static func dir_to(from_body: String, to_body: String, t: float) -> Vector3:
	var d := DV.sub(body_pos_helio(to_body, t), body_pos_helio(from_body, t))
	return DV.normalized_v3(d)

## f64 unit direction (DVec3) from `from_body` to `to_body` at t, INERTIAL frame — the exact-precision
## twin of dir_to (which downgrades to f32 Vector3 for the render side). Used where an INVARIANT must
## hold to f64 (tidal lock, SOI math in O1); the f32 Vector3 path drifts ~1e-7, far above such gates.
static func dir_to_f64(from_body: String, to_body: String, t: float) -> PackedFloat64Array:
	var d := DV.sub(body_pos_helio(to_body, t), body_pos_helio(from_body, t))
	var l := DV.length(d)
	if l == 0.0:
		return DV.v(0.0, 0.0, 0.0)
	return DV.scale(d, 1.0 / l)

## Distance (blocks, f64) between two bodies at t.
static func distance_between(a_body: String, b_body: String, t: float) -> float:
	return DV.length(DV.sub(body_pos_helio(b_body, t), body_pos_helio(a_body, t)))

## Angular DIAMETER (radians) that `body` subtends as seen from `from_body` at t:
## 2·atan(R_body / distance). At ÷1000 uniform scale this is the real angle (Sun ≈ 0.533°, Moon
## ≈ 0.518°) — the near-equality that makes eclipses work.
static func angular_diameter(body: String, from_body: String, t: float) -> float:
	var dist := distance_between(from_body, body, t)
	if dist <= 0.0:
		return 0.0
	return 2.0 * atan(radius_of(body) / dist)

## Unit direction (Vector3) from `from_body` to `to_body`, expressed in `from_body`'s BODY-FIXED
## frame at t — the inertial direction rotated by −spin_angle(from_body) about the spin axis (+Z,
## north per the CubeSphere face frame). This is what the sky layer consumes: as Earth spins the
## Sun sweeps around the observer (day-night) with zero geometry work (§4.1/§8.2). incl/tilt = 0,
## so a −Z-axis rotation is exact for v1.
static func dir_to_bodyfixed(from_body: String, to_body: String, t: float) -> Vector3:
	var d_inertial := dir_to(from_body, to_body, t)
	var ang := -spin_angle(from_body, t)
	var c := cos(ang)
	var s := sin(ang)
	# R_z(ang) · d : rotate about +Z (the spin/north axis); Z component is untouched.
	return Vector3(
		c * d_inertial.x - s * d_inertial.y,
		s * d_inertial.x + c * d_inertial.y,
		d_inertial.z)

## Sub-`target` longitude (rad) on `body`'s surface — the body-fixed azimuth of the direction from
## `body` to `target`. For a tidally-locked moon toward its parent this is CONSTANT (the tidal-lock
## invariant the gate samples across a month). Computed in f64 (NOT the f32 Vector3 render path) so
## the invariant holds to f64 ulp: inertial f64 direction rotated by −spin_angle about +Z, then atan2.
static func sub_longitude(body: String, target: String, t: float) -> float:
	var di := dir_to_f64(body, target, t)
	var ang := -spin_angle(body, t)
	var c := cos(ang)
	var s := sin(ang)
	var bx := c * di[0] - s * di[1]
	var by := s * di[0] + c * di[1]
	return atan2(by, bx)
