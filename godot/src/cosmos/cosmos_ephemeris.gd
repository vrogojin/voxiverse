extends RefCounted
class_name CosmosEphemeris
## COSMOS ORBITAL O0 — the pure f64 celestial-mechanics kernel (docs/COSMOS-ORBITAL-DESIGN.md
## §3.3, §3.4, §4.2). Static, engine-free, deterministic: every function is a pure function of
## its arguments plus the frozen body table — NO engine singletons, NO wall clock inside the math,
## NO randi(). This makes it worker-safe and headless-gate-testable (verify_orbital_sky.gd), and it
## carries the whole scale/time/mass model that O1+ (real orbits, SOI, grids) reads as data.
##
## THE SCALE MODEL — STRICT 1:1000 SPACETIME (§3.3, USER-LOCKED 2026-07-18, natural Earth/1000):
##   1 unit = 1 block = 1 m. Celestial lengths are real km ÷ 1000 (s_L = 1/1000). Time is scaled by the
##   SAME rule so acceleration (length/time²) is INVARIANT: s_T² = s_L ⇒ s_T = √s_L = 1/√1000, i.e. game
##   time runs √1000 = 31.62× faster than reality (NOT the old 72×). Then the GM that keeps Newton exact is
##       GM_game = GM_real × s_L³ / s_T²  = GM_real × (10⁻³)³ × (√1000)²  = GM_real × 1×10⁻⁶
##   which for Earth is 3.986e8 = SURFACE_GRAVITY·R² (CubeSphere.gm_for) — so the far-field Kepler GM and the
##   near-field FEEL anchor COINCIDE. Consequences (all self-consistent, ONE clock): gravity is 9.8 for BOTH
##   walking AND orbit (no split); surface v_circ = √(GM/R) = 250 b/s, low-orbit period ≈ 160 s, escape ≈ 354;
##   one Earth day = 86400/√1000 ≈ 2732.6 s ≈ 45.5 min. Because the SKY (sun/moon/day/eclipses) runs on the
##   same clock it slows to the same √1000 rate — orbit ↔ day ↔ gravity stay in sync, no desync. Every
##   dimensionless ratio (angular sizes, eclipse geometry, orbits-per-day) is still EXACTLY real.
##
## Since GM_game now EQUALS CubeSphere.gm_for by construction (§3.3.1, walk gravity 9.8), the far-field Kepler
## truth and the near-field feel anchor agree at the datum — the O1 blend band is continuous with no GM step.
## O0 uses this kernel for the sky (Sun/Moon direction + day-night); O1+ read the same GM for real orbits.
##
## PRECISION: positions are DVecF64 (PackedFloat64Array) — Earth–Sun 1.496e8 needs f64; the render
## layer downgrades DIRECTIONS to Vector3 (§4.3).

const DV := preload("res://src/cosmos/dvec3.gd")

# ---------------------------------------------------------------------------------------
# Scale constants (§3.3) — the three locked numbers everything else derives from.
# ---------------------------------------------------------------------------------------

## Length scale: 1 game block = 1000 real metres for celestial quantities (real km → blocks).
## s_L = 1/1000. Defined first — the time and GM scales derive from it under the STRICT 1:1000 rule.
const LENGTH_SCALE := 1.0e-3
## Time compression: game runs this many times faster than reality. STRICT 1:1000 SPACETIME (§3.3):
## for acceleration = length/time² to be scale-INVARIANT we need s_T² = s_L ⇒ s_T = √s_L = 1/√1000, i.e.
## time compression = 1/s_T = √1000 = 31.6227766 (NOT the old 72×). This is the value that keeps gravity
## the SAME 9.8 for walking AND orbit and keeps the whole clock — orbits, day, sun/moon, eclipses — on ONE
## coherent scale. Written as the literal √1000 (sqrt is not allowed in a const expr); the gate checks it.
const TIME_COMPRESSION := 31.622776601683793
## One Earth solar day in game seconds (= real 86400 s ÷ √1000 ≈ 2732.6 s ≈ 45.5 min). DERIVED from
## TIME_COMPRESSION so the day tracks the one time scale (was 1200 s / 20 min under the old 72× model).
const DAY_GAME := 86400.0 / TIME_COMPRESSION
## The GM scaling law (§3.3): GM_game = GM_real × s_L³/s_T² = (10⁻³)³ × (√1000)² = 1e-9 × 1000 = 1e-6.
## DERIVED (not a hand literal) so the Newton scaling law holds by construction. Under strict 1:1000 this
## makes GM_game(earth) = 3.986e14 × 1e-6 = 3.986e8 ≈ SURFACE_GRAVITY·R² (CubeSphere.gm_for) — the far-field
## Kepler GM and the near-field feel anchor now COINCIDE, so orbit gravity == walk gravity == 9.8 (no split).
const GM_SCALE := LENGTH_SCALE * LENGTH_SCALE * LENGTH_SCALE * TIME_COMPRESSION * TIME_COMPRESSION

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
		"spin_period": DAY_GAME, "spin_phase0": 0.0, "tidal": false,   # one solar day = √1000-scaled ≈ 2732.6 s
		# CLIMATE W0 (§3): real obliquity ε = 23.4° = 0.4084 rad. USED only when CubeSphere.FP_SEASONS is on
		# (effective_tilt gates it → 0 with the flag off, so dir_to_bodyfixed stays byte-identical). incl still
		# 0 (the orbit plane == the ecliptic); the tilt lives purely in the body-fixed frame, so orbit/period/
		# tidal math is untouched.
		"ecc": 0.0, "incl": 0.0, "axial_tilt": 0.4084,
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

	## Advance the clock by a REAL frame delta (seconds); the sky moves √1000× via the scaled GM, and
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

## GM_game = GM_real × GM_SCALE — DERIVED so the scaling law is exact (§3.3). Under the natural strict-1:1000
## clock (GM_SCALE = 1e-6) the canonical values are 3.986e8 (earth) / 4.905e6 (moon) / 1.327e14 (sun) — the
## earth value equals SURFACE_GRAVITY·R² (gate asserts).
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

## Velocity of `body` RELATIVE TO ITS PARENT (DVec3 blocks/s), parent inertial frame — the exact
## closed-form time-derivative of body_pos_parent for a circular orbit (SPACE-NAV §5.1): with
## angle θ = M0 + n·t, d/dt (a cos θ, a sin θ, 0) = a·n·(−sin θ, cos θ, 0). Pure f64; the twin of
## body_pos_parent that the HIGH_ORBIT↔DEEP_SPACE handoff and the SOI-swap re-expression consume.
static func body_vel_parent(body: String, t: float) -> PackedFloat64Array:
	var a := orbit_a(body)
	if parent_of(body) == "" or a <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var n := omega_orbit(body)
	var th := orbit_angle(body, t)
	return DV.v(-a * n * sin(th), a * n * cos(th), 0.0)

## Heliocentric (system-centre) velocity of `body` (DVec3 blocks/s): the chain of parent-relative
## velocities up to the Sun (at rest at the origin). Pure recursion over the acyclic parent graph —
## the exact analogue of body_pos_helio, so p_helio and v_helio are a consistent (position, velocity)
## pair at every t. This is the ONE new ephemeris accessor SN1 adds (SPACE-NAV §5.1).
static func body_vel_helio(body: String, t: float) -> PackedFloat64Array:
	var par := parent_of(body)
	if par == "":
		return DV.v(0.0, 0.0, 0.0)                     # the Sun is at rest at the origin
	return DV.add(body_vel_helio(par, t), body_vel_parent(body, t))

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

## CLIMATE W0 (§3): the axial obliquity (rad) actually APPLIED to `body`'s body-fixed frame. The frozen
## table value gated by CubeSphere.FP_SEASONS — with the flag OFF this returns 0 for every body, so
## dir_to_bodyfixed / subsolar_latitude below collapse to the shipped no-tilt kernel (R_tilt = I) and are
## BYTE-IDENTICAL. ON, Earth reads 0.4084 rad (23.4°) → seasonal sun arcs and the subsolar-latitude wave.
## Reading a CubeSphere const keeps the kernel pure (CubeSphere is engine-free math, no singleton/clock).
static func effective_tilt(body: String) -> float:
	if not CubeSphere.FP_SEASONS:
		return 0.0
	return float(BODIES[body]["axial_tilt"])

## Unit direction (Vector3) from `from_body` to `to_body`, expressed in `from_body`'s BODY-FIXED
## frame at t — the inertial direction rotated by −spin_angle(from_body) about the spin axis (+Z,
## north per the CubeSphere face frame). This is what the sky layer consumes: as Earth spins the
## Sun sweeps around the observer (day-night) with zero geometry work (§4.1/§8.2).
##
## CLIMATE W0: the body-fixed frame is R_spin(θ)·R_tilt(ε) — the obliquity tilts the pole off the orbit
## normal, fixed in inertial space, so as Earth orbits its north pole leans sun-ward in summer and away in
## winter (the WHOLE of seasons). We express the inertial direction in that frame: first R_x(−ε) (tilt the
## pole from +Z toward the equinox line), then R_z(−θ) (spin about the tilted pole). ε=0 (flag off) ⇒ only
## the spin rotation runs ⇒ byte-identical to the shipped kernel. The Z-component after R_x(−ε) IS the sine
## of the local declination, so this and subsolar_latitude() agree by construction.
static func dir_to_bodyfixed(from_body: String, to_body: String, t: float) -> Vector3:
	var d := dir_to(from_body, to_body, t)
	var eps := effective_tilt(from_body)
	if eps != 0.0:
		# R_x(−ε): (x, y·cosε + z·sinε, −y·sinε + z·cosε) — tilt the north axis by the obliquity.
		var ce := cos(eps)
		var se := sin(eps)
		d = Vector3(d.x, d.y * ce + d.z * se, -d.y * se + d.z * ce)
	var ang := -spin_angle(from_body, t)
	var c := cos(ang)
	var s := sin(ang)
	# R_z(ang) · d : rotate about +Z (the spin/north axis); Z component is untouched.
	return Vector3(
		c * d.x - s * d.y,
		s * d.x + c * d.y,
		d.z)

## CLIMATE W0 (§3): the SUBSOLAR LATITUDE δ(t) (rad) — the latitude where the Sun stands at zenith. It is
## the sine of the Sun's north-axis component in Earth's tilted (but unspun) frame: with the inertial Sun
## direction ŝ and R_x(−ε) applied, z' = −ŝ_y·sinε + ŝ_z·cosε, δ = asin(z'). Since the Sun sits in the
## ecliptic (ŝ_z ≈ 0) this is δ ≈ asin(sinε·sinM) → +23.4° at the June solstice (M=π/2), −23.4° in
## December, 0 at the equinoxes. This is the SAME z' the tilted dir_to_bodyfixed produces, so the sky sun
## arc and the season offset can never disagree. Pure; ε gated by FP_SEASONS (0 ⇒ δ≡0, no seasons).
static func subsolar_latitude(t: float) -> float:
	return subsolar_latitude_eps(t, effective_tilt("earth"))

## The explicit-obliquity form of subsolar_latitude — a pure function of (t, ε) that does NOT read the
## flag, so a gate can assert δ = ±23.4° at the solstices regardless of the shipped FP_SEASONS default.
static func subsolar_latitude_eps(t: float, eps: float) -> float:
	var s := dir_to_f64("earth", "sun", t)          # inertial f64 unit direction to the Sun
	var z_pole := -s[1] * sin(eps) + s[2] * cos(eps)
	return asin(clampf(z_pole, -1.0, 1.0))

## CLIMATE W0: `body`'s spin-axis (north-pole) unit direction in the INERTIAL frame = R_x(ε)·(+Z) =
## (0, −sinε, cosε). Fixed in inertial space (obliquity is constant) — celestial north for the sky/nav.
## ε gated by FP_SEASONS ⇒ (0,0,1) with the flag off (byte-identical to the untilted +Z pole).
static func pole_axis_inertial(body: String) -> Vector3:
	var eps := effective_tilt(body)
	return Vector3(0.0, -sin(eps), cos(eps))

## COSMOS-LOD-SKY L0 (docs/COSMOS-LOD-SKY-DESIGN.md §7.2, G-MOON-PHASE) — celestial PHASE geometry, pure f64.
## The phase angle ψ at `body` is the Source–body–Observer angle: the angle, seen AT `body`, between the
## direction to the light source and the direction to the observer. For the Moon (observer=earth, source=sun):
## full moon ⇒ Sun and Earth lie the same way from the Moon ⇒ ψ≈0; new moon ⇒ opposite ⇒ ψ≈π. This is exactly
## the light-vs-view geometry the shipped CosmosSky Moon impostor is rendered with (a sphere lit along −sun_dir,
## viewed from earth), so the illuminated fraction below IS the rendered lit fraction — the gate proves it, no
## new render code. Pure statics: dead unless a gate / the moonshine term calls them (no byte impact).
static func phase_angle(observer: String, body: String, source: String, t: float) -> float:
	var pb := body_pos_helio(body, t)
	var to_source := DV.normalized_v3(DV.sub(body_pos_helio(source, t), pb))
	var to_observer := DV.normalized_v3(DV.sub(body_pos_helio(observer, t), pb))
	if to_source == Vector3.ZERO or to_observer == Vector3.ZERO:
		return 0.0
	return to_source.angle_to(to_observer)

## Illuminated fraction of `body`'s disc as seen from `observer`, lit by `source`: f = (1+cos ψ)/2 ∈ [0,1].
## 1 = full (ψ=0), 0.5 = quarter (ψ=π/2), 0 = new (ψ=π). This is the textbook lit fraction of a sphere at
## phase angle ψ — the value the shipped lit-sphere impostor shows automatically (§7.2). Reused by SKY_MOONSHINE.
static func illuminated_fraction(observer: String, body: String, source: String, t: float) -> float:
	return 0.5 * (1.0 + cos(phase_angle(observer, body, source, t)))

## Sky-plane direction, seen from `observer`, of `body`'s bright limb (the illuminated edge points toward the
## source). = the component of the observer→source direction perpendicular to the observer→body line of sight,
## normalized. Perpendicular to the line of sight by construction; the terminator on the disc is ⊥ to it. The
## gate asserts it is a valid unit vector, ⊥ the view direction, and sunward — i.e. the shipped sphere's
## terminator orientation is the real ephemeris one (§7.2 bright-limb position angle == projected sun direction).
static func bright_limb_dir(observer: String, body: String, source: String, t: float) -> Vector3:
	var po := body_pos_helio(observer, t)
	var m_hat := DV.normalized_v3(DV.sub(body_pos_helio(body, t), po))       # observer → body (line of sight)
	var s_hat := DV.normalized_v3(DV.sub(body_pos_helio(source, t), po))     # observer → source
	if m_hat == Vector3.ZERO or s_hat == Vector3.ZERO:
		return Vector3.ZERO
	var proj := s_hat - m_hat * s_hat.dot(m_hat)                             # sunward, projected onto the sky plane
	if proj.length() < 1.0e-12:
		return Vector3.ZERO
	return proj.normalized()

## Solar ELONGATION of `body` from `observer`: the on-sky angle between the source and the body (Sun–observer–
## body angle). Ties phase to geometry — at first/last quarter (f=0.5) the elongation is ≈90° (the gate checks it).
static func elongation(observer: String, body: String, source: String, t: float) -> float:
	var po := body_pos_helio(observer, t)
	var to_body := DV.normalized_v3(DV.sub(body_pos_helio(body, t), po))
	var to_source := DV.normalized_v3(DV.sub(body_pos_helio(source, t), po))
	if to_body == Vector3.ZERO or to_source == Vector3.ZERO:
		return 0.0
	return to_source.angle_to(to_body)

## Position of `body` relative to its parent as a render-side Vector3 (blocks). Thin wrapper over the f64
## body_pos_parent for the eclipse geometry in CosmosSky (the Moon's offset from Earth's centre).
static func body_pos_parent_v3(body: String, t: float) -> Vector3:
	return DV.to_v3_scaled(body_pos_parent(body, t), 1.0)

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
