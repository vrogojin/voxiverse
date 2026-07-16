extends RefCounted
class_name DVecF64
## COSMOS ORBITAL O0 — the minimal f64 3-vector helper (docs/COSMOS-ORBITAL-DESIGN.md §4.2, §4.3).
## Celestial POSITIONS span Earth–Sun = 1.496e8 blocks; a Godot `Vector3` is f32 (≈7 sig digits,
## ulp ~10 blocks at that magnitude), so positions MUST be carried in f64. GDScript `float` is
## IEEE-754 f64, and a `PackedFloat64Array` stores three of them contiguously — so a DVec3 here is
## just a length-3 `PackedFloat64Array` [x, y, z]. This is the f64-vector contract the O1+ orbital
## integrator and ephemeris reuse; DIRECTIONS handed to the render layer downgrade to `Vector3`
## (f32 is exact enough for a unit vector at a clamped sky distance — §4.4).
##
## Pure static math, engine-free and deterministic (no singletons, no wall clock) — worker-safe and
## headless-gate-testable, matching the CubeSphere kernel discipline. NEVER-OOM: every op returns a
## fresh 24-byte packed array (three f64) — O(1), no growth.

## Construct a DVec3 from three f64 scalars.
static func v(x: float, y: float, z: float) -> PackedFloat64Array:
	return PackedFloat64Array([x, y, z])

## a + b (component-wise).
static func add(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] + b[0], a[1] + b[1], a[2] + b[2]])

## a − b (component-wise).
static func sub(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] - b[0], a[1] - b[1], a[2] - b[2]])

## a · s (scalar multiply).
static func scale(a: PackedFloat64Array, s: float) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] * s, a[1] * s, a[2] * s])

## a · b (dot product, f64).
static func dot(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

## |a| (Euclidean length, f64).
static func length(a: PackedFloat64Array) -> float:
	return sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])

## Unit direction of `a` as a render-side `Vector3` (f32). The normalization is done in f64 THEN
## downgraded, so the direction is exact to f32 even when `a`'s magnitude is 1e8. A zero vector
## maps to Vector3.ZERO (caller's responsibility to avoid, matching CubeSphere.DVec3.normalized()).
static func normalized_v3(a: PackedFloat64Array) -> Vector3:
	var l := length(a)
	if l == 0.0:
		return Vector3.ZERO
	return Vector3(float(a[0] / l), float(a[1] / l), float(a[2] / l))

## `a · s` downgraded to a render-side `Vector3` (f32). Used to place a sky impostor at a clamped
## distance: pass a UNIT direction and s = D_SKY so the f32 coords stay tiny (≤ D_SKY) regardless of
## the true celestial distance (§4.4).
static func to_v3_scaled(a: PackedFloat64Array, s: float) -> Vector3:
	return Vector3(float(a[0] * s), float(a[1] * s), float(a[2] * s))
