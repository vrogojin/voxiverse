extends RefCounted
class_name CosmosGravity
## COSMOS ORBITAL O1 / SPACE-NAV SN1 — the three-regime gravity field + the GM_dyn scale bridge
## (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.2, docs/COSMOS-SPACE-NAV-DESIGN.md §3). House-style pure
## f64 kernel, matching the CosmosEphemeris / DVecF64 / FacetAtlas discipline: static, engine-free,
## deterministic, worker-safe, headless-gate-testable. NO engine singletons, NO wall clock, NO randi().
##
## GM_dyn (SPACE-NAV §3, decision D-SN-2) — THE one new scale decision. The ephemeris carries the REAL
## Earth (R_eph 6371, GM_game 2.066e9), but the voxel Earth is R_vox = 3072. Using GM_game raw at the
## voxel radius makes datum gravity 219 m/s² and pushes geostationary outside the 1 %-gravity radius —
## the user's own nav thresholds then misclassify. Fix: ALL local player dynamics (this field, the
## orbital integrator, v_circ/γ/SOI/r_geo) read
##     GM_dyn(body) = GM_game(body) × (R_vox(body) / R_eph(body))³
## which is Kepler-shape-exact at the voxel surface, collapses to identity the moment R_vox == R_eph
## (post-O3 resize, and the Moon TODAY: R_vox = R_eph = 1737), and leaves the SKY untouched
## (CosmosEphemeris keeps GM_game + real÷1000 distances — the 20-min day / eclipse geometry stay locked).
## The sky reads GM_game; every local dynamic reads GM_dyn. Disclosed inconsistency: a player at
## lunar distance under GM_dyn does not station-keep with the on-rails Moon — unobservable until O3,
## which erases the difference (R7). Gated by G-SN-SCALE.
##
## THE BLEND FIELD (§2.2). g at a planet-centred body-fixed position p over `body`, blending three
## regimes by radial altitude h = |p| − R_vox:
##   h ≤ H_BLEND_LO : pure shipped facet feel-gravity (−facet_normal · FEEL_G) — the walking game
##   h ≥ H_BLEND_HI : pure GM_dyn/r² radial (−p̂ · GM_dyn/r²) — the inertial regime
##   in between      : slerp the direction, lerp the magnitude, by w = smoothstep(LO, HI, h)
## The ORBITAL integrator itself uses the pure central point-mass form (gravity_bci below) — which is
## EXACTLY this field's h ≥ HI branch expressed in the inertial frame; they agree in the only regime
## the integrator runs conservatively (see orbital_state.gd). gravity_fixed is the near-surface field
## the mode-transition / re-entry logic and the gravity HUD read, and the single named truth later
## phases (gravity-aware debris, grids) share.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")

## Earth walking feel gravity (blocks/s²) — mirrors the player.gd `gravity` walk-feel constant (kept in
## lockstep so the near-surface blend field and the walking game agree). Rescale set both to realistic
## 9.8 (Earth/1000 model, 1 block = 1 m). FEEL_G(body) scales it by the real surface-gravity ratio (below).
const FEEL_G_EARTH := 9.8

# ---------------------------------------------------------------------------------------
# GM_dyn — the scale bridge (SPACE-NAV §3).
# ---------------------------------------------------------------------------------------

## The walkable body's VOXEL radius (blocks). Earth == FacetAtlas.R_BLOCKS (3072 today, 6371 post-O3
## resize ⇒ GM_dyn collapses to GM_game with no code change — the formula IS the migration). Every
## other body defaults to its ephemeris radius (Moon: R_vox == R_eph == 1737 ⇒ identity from day one),
## which is the conservative choice until the O4a multi-body atlas carries per-body voxel radii.
static func r_vox(body: String) -> float:
	if body == "earth":
		return FacetAtlas.R_BLOCKS
	return EPH.radius_of(body)

## GM_dyn(body) = GM_game(body) × (R_vox/R_eph)³ (SPACE-NAV §3, D-SN-2). Kepler-shape-exact at the
## voxel surface; identity when R_vox == R_eph.
static func gm_dyn(body: String) -> float:
	var k := r_vox(body) / EPH.radius_of(body)
	return EPH.gm_game(body) * k * k * k

## Datum surface gravity under GM_dyn (blocks/s²) = GM_dyn/R_vox². Earth interim ≈ 24.6, post-O3 ≈ 50.9.
static func datum_gravity(body: String) -> float:
	var rv := r_vox(body)
	return gm_dyn(body) / (rv * rv)

## Datum circular orbital speed under GM_dyn (blocks/s) = √(GM_dyn/R_vox). Earth interim ≈ 274.6.
static func datum_circular_speed(body: String) -> float:
	return sqrt(gm_dyn(body) / r_vox(body))

## The walking feel gravity for `body` (blocks/s²): the Earth feel (22.0) scaled by the REAL
## surface-gravity ratio (gm_real_body/R_eph_body²)/(gm_real_earth/R_eph_earth²) — the same real-datum
## ratio the shipped per-body feel hook uses (player.gd:90-99), so player and field agree. Earth == 22.0
## exactly; Moon ≈ 3.63 (hang-time ×2.5 at preserved jump height).
static func feel_g(body: String) -> float:
	var g_body := EPH.gm_real(body) / (EPH.radius_of(body) * EPH.radius_of(body))
	var g_earth := EPH.gm_real("earth") / (EPH.radius_of("earth") * EPH.radius_of("earth"))
	return FEEL_G_EARTH * (g_body / g_earth)

# ---------------------------------------------------------------------------------------
# The inertial point-mass gravity (what the ORBITAL integrator uses).
# ---------------------------------------------------------------------------------------

## Central point-mass gravitational acceleration (DVec3 blocks/s²) at BCI position p over `body`:
## g(p) = −GM_dyn·p/|p|³. Conservative ⇒ the symplectic integrator conserves energy (bounded
## oscillation, zero secular drift). Equals gravity_fixed's h ≥ H_BLEND_HI branch (both −p̂·GM_dyn/r²).
static func gravity_bci(body: String, p: PackedFloat64Array) -> PackedFloat64Array:
	var r := DV.length(p)
	if r <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var mag := gm_dyn(body) / (r * r)                  # |g| = GM_dyn/r²
	return DV.scale(p, -mag / r)                        # −(GM_dyn/r³)·p

# ---------------------------------------------------------------------------------------
# The blend field (§2.2).
# ---------------------------------------------------------------------------------------

## g vector (DVec3 f64, blocks/s²) at body-fixed position p over `body`, blending the three regimes.
## `fid` = the active facet (its outward normal gives the lattice-regime "up"); pass −1 off-facet to
## use radial-down below the band too. w == 0 (h ≤ LO) returns EXACTLY the shipped facet feel gravity
## (−facet_normal · FEEL_G); w == 1 (h ≥ HI) returns −p̂ · GM_dyn/r².
static func gravity_fixed(body: String, fid: int, p: PackedFloat64Array) -> PackedFloat64Array:
	var r := DV.length(p)
	if r <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var h := r - r_vox(body)
	var w := smoothstep(CubeSphere.H_BLEND_LO, CubeSphere.H_BLEND_HI, h)

	# Radial down (exact f64), always available.
	var down_radial := DV.scale(p, -1.0 / r)

	# Lattice down = −facet outward normal (the shipped "−Y in window space" up-vector). Off-facet
	# (fid < 0) or before warm_up, fall back to radial down — the band's LO edge then has no facet skew.
	var down_lattice := down_radial
	if fid >= 0:
		var n := FacetAtlas.facet_normal64(fid)         # world-space outward normal [x,y,z] f64
		down_lattice = DV.v(-n[0], -n[1], -n[2])

	var dir := _slerp_unit(down_lattice, down_radial, w)

	# Magnitude: feel-g near the surface → GM_dyn/r² above the band.
	var mag: float = lerp(feel_g(body), gm_dyn(body) / (r * r), w)
	return DV.scale(dir, mag)

## Spherical-linear interpolation between two UNIT DVec3 by t ∈ [0,1] (f64). Falls back to normalized
## lerp for near-parallel / near-antiparallel inputs (the facet normal and radial dir differ by ≤
## dihedral/2 ≪ 1 rad here, so this is the fast common path). Returns a unit DVec3.
static func _slerp_unit(a: PackedFloat64Array, b: PackedFloat64Array, t: float) -> PackedFloat64Array:
	if t <= 0.0:
		return a
	if t >= 1.0:
		return b
	var d := clampf(DV.dot(a, b), -1.0, 1.0)
	if d > 0.9999995:                                   # near-parallel: lerp+normalize (avoids /sin0)
		var m := DV.add(DV.scale(a, 1.0 - t), DV.scale(b, t))
		var l := DV.length(m)
		return DV.scale(m, 1.0 / l) if l > 0.0 else a
	var theta := acos(d)
	var st := sin(theta)
	var wa := sin((1.0 - t) * theta) / st
	var wb := sin(t * theta) / st
	return DV.add(DV.scale(a, wa), DV.scale(b, wb))
