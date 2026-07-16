extends RefCounted
class_name CosmosGravity
## COSMOS ORBITAL O1 (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §2.2) — the three-regime gravity FIELD, the single
## named truth every off-surface consumer reads (the ORBITAL integrator in O1; gravity-aware debris / O2 grids
## later). Pure f64 static kernel in the CosmosEphemeris/DVecF64/FacetAtlas discipline: engine-free, deterministic,
## worker-safe, headless-gate-testable (verify_orbital.gd G-O1-FIELD). It creates and runs NOTHING at load — it is
## consulted only when called, so FP_M3_ORBIT=false is byte-identical by construction.
##
## The blend (parent §5.1): at radial altitude h = |p| − R_body,
##   w   = smoothstep(H_BLEND_LO, H_BLEND_HI, h)
##   dir = slerp(−facet_normal(fid), −p̂, w)        # lattice "down" below the band → radial "down" above it
##   |g| = lerp(FEEL_G_body, gm_game(body)/r², w)   # walking feel below → Kepler truth above
## Below H_BLEND_LO (w=0) this is EXACTLY the shipped facet-−normal at feel magnitude (the walking game is
## untouched — and the production walk path never even consults this function; §2.2 "Consumers"). Above H_BLEND_HI
## (w=1) it is pure GM/r² radial, the exact Newton force the integrator wants. fid == −1 ⇒ off-facet caller:
## radial-down is used below the band too (there is no facet normal to lean on).
##
## R_body / gm_game come from CosmosEphemeris (the far-field Kepler table). NOTE (surfaced honestly): the O0
## ephemeris radius_of("earth") = 6371 is the POST-O3 planet radius; the shipped faceted planet is still
## FacetAtlas.R_BLOCKS = 3072 (O3 resize not yet landed). This kernel follows the design and uses radius_of, so
## its altitudes are self-consistent for the headless gates and for the post-O3 world; the live-wiring stage must
## reconcile R_body with the actual planet R (== FacetAtlas.r_of post-O4a) before feeding it real p_fixed. See the
## report / §2.2 line-ref.

const DV := preload("res://src/cosmos/dvec3.gd")

## The player's near-field FEEL gravity at the Earth datum (player.gd:25, `gravity := 22.0`). Every other body's
## feel-g is the real-datum ratio off this, so player and debris agree (§2.2 / player.gd:90-99).
const FEEL_G_EARTH := 22.0

## Feel-g magnitude (m/s²) for `body`: 22 × (gm_real_body/R_body²)/(gm_real_earth/R_earth²). Earth ⇒ 22 exactly;
## Moon ⇒ ~3.6 (the s≈0.165 surface-gravity ratio the shipped player hook uses).
static func feel_g(body: String) -> float:
	var r_b := CosmosEphemeris.radius_of(body)
	var r_e := CosmosEphemeris.radius_of("earth")
	var g_b := CosmosEphemeris.gm_real(body) / (r_b * r_b)
	var g_e := CosmosEphemeris.gm_real("earth") / (r_e * r_e)
	return FEEL_G_EARTH * (g_b / g_e)

## The gravity ACCELERATION vector (DVec3 f64, blocks/s²) at body-fixed position `p` (DVec3) over `body`. `fid` is
## the active facet supplying the lattice-down normal below the band; −1 ⇒ radial-down everywhere. The returned
## vector points DOWN (toward the planet) at feel magnitude below H_BLEND_LO, radially at GM/r² above H_BLEND_HI,
## and smoothstep-blends direction+magnitude between. Pure: reads only the frozen atlas + the const body table.
static func gravity_fixed(body: String, fid: int, p: PackedFloat64Array) -> PackedFloat64Array:
	var r := DV.length(p)
	if r <= 0.0:
		return DV.v(0.0, 0.0, 0.0)                       # degenerate: at the centre, no defined direction
	var rr := CosmosEphemeris.radius_of(body)
	var h := r - rr
	var w := smoothstep(CubeSphere.H_BLEND_LO, CubeSphere.H_BLEND_HI, h)
	# radial-down unit (−p̂), always available
	var rad_in := DV.v(-p[0] / r, -p[1] / r, -p[2] / r)
	var dir: PackedFloat64Array
	if fid < 0:
		dir = rad_in                                     # off-facet: radial-down below the band too
	else:
		var n := FacetAtlas.facet_normal64(fid)          # outward facet normal (f64 Array [x,y,z])
		var facet_in := DV.v(-n[0], -n[1], -n[2])        # lattice "down"
		dir = _slerp_unit(facet_in, rad_in, w)
	# magnitude: feel-g below → gm_game/r² above
	var g_far := CosmosEphemeris.gm_game(body) / (r * r)
	var mag: float = lerp(feel_g(body), g_far, w)
	return DV.scale(dir, mag)

## Spherical linear interpolation of two f64 UNIT vectors (result stays unit). Falls back to normalized lerp when
## the two are nearly parallel (sin θ → 0); an exactly-antiparallel pair (no unique great circle) returns `a` — a
## case that cannot arise here (facet-down and radial-down never oppose: their dihedral half-angle ≤ ~π/8).
static func _slerp_unit(a: PackedFloat64Array, b: PackedFloat64Array, w: float) -> PackedFloat64Array:
	var d := clampf(DV.dot(a, b), -1.0, 1.0)
	var theta := acos(d)
	var s := sin(theta)
	if s < 1.0e-9:
		var l := DV.add(DV.scale(a, 1.0 - w), DV.scale(b, w))
		var ll := DV.length(l)
		if ll < 1.0e-12:
			return a
		return DV.scale(l, 1.0 / ll)
	var wa := sin((1.0 - w) * theta) / s
	var wb := sin(w * theta) / s
	return DV.add(DV.scale(a, wa), DV.scale(b, wb))
