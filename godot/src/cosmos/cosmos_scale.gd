class_name CosmosScale
extends RefCounted
## COSMOS SPACE-NAV SN3 (docs/COSMOS-SPACE-NAV-DESIGN.md §10 / docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.2-5.5) —
## THE border-continuity policy site: the scaled-body distance clamp, altitude-continuous camera near/far, and
## the fixed-conservative tier retire/persistence altitudes (v1). Pure statics, no state, no engine deps beyond
## CubeSphere. With FP_SCALED_BODY off every accessor is inert (nothing scales — s == 1 everywhere, the camera
## keeps its shipped 0.05/9000, the far ring never retires) and this class is DEAD (never referenced on a hot
## path), so the engine is byte-identical.
##
## The clamp is the KSP scaled-space / Elite supercruise identity made CONTINUOUS. A body at camera-distance d,
## uniformly scaled by s = min(1, D_ENGAGE/d) ABOUT THE CAMERA, keeps every vertex's SCREEN position exactly
## (the perspective divide cancels a uniform scale about the camera origin — projection of s·X equals projection
## of X) while pulling its geometry from d into the usable depth range at d·s = D_ENGAGE. Because s == 1 exactly
## at and below D_ENGAGE the near regime is byte-untouched: there is no switch, only a reparameterization. This
## REPLACES the rejected O1O4 §2.8 H_FARSWAP impostor-swap (SPACE-NAV R1) — the far ring IS the "impostor",
## persisted to any altitude under a continuous distance clamp, so the surface stays visible from space.

# --- retire / persistence altitudes (blocks), fixed conservative v1 (§10 SN3) -----------------------
const SKIN_RETIRE_H := 4000.0     # the skin heightfield tier goes sub-relief-pixel ≈ here (v1 conservative)
const POOL_RETIRE_H := 10000.0    # the live pool voxel mesh goes sub-relief-pixel ≈ here (v1 conservative)
const RETIRE_HYST := 0.25         # ±25% hysteresis band around each retire altitude (no flip-flop at the edge)
# The far ring is the LAST/coarsest tier; it persists until GENUINELY sub-relief-pixel — far above the playable
# envelope. v1 pins that at a conservative constant (never retired in-range) so the surface stays visible from
# space; the full SSE scheduler (FP_TIER_SSE) computes the real sub-pixel altitude at runtime later (R8).
const FARRING_RETIRE_H := 1.0e9   # effectively never (the §0.1 "surface from space" persistence guarantee)

# --- scaled-body engage distance (§5.2) -------------------------------------------------------------
# h_engage = max(all true-scale tier evict altitudes) + hysteresis. The pool tier is the highest, so
# h_engage = POOL_RETIRE_H·(1 + RETIRE_HYST) ≈ 12.5 k — below D_ENGAGE everything is true-scale; above it only
# the ring + sky remain (the two scale frames never coexist on interleaved geometry → no parallax-shear).
const H_ENGAGE := POOL_RETIRE_H * (1.0 + RETIRE_HYST)   # 12500 blocks

# --- camera plane ramp (§5.4, the Cozzi virtual-globe altitude-continuous frustum) ------------------
const NEAR_MIN := 0.05            # shipped ground near plane (byte-identical at h = 0)
const NEAR_MAX := 8.0             # near-plane cap far out (h ≥ NEAR_MAX·NEAR_H_DIV)
const NEAR_H_DIV := 256.0         # near = clamp(h / 256, NEAR_MIN, NEAR_MAX)
const FAR_MIN := 9000.0           # shipped ground far plane (== FacetFarRing.CAMERA_FAR)
const FAR_TANGENT_K := 1.2        # far = max(FAR_MIN, 1.2·√(d² − R²)): the horizon tangent distance + headroom

## Master gate: is the scaled-body border-continuity path live? Off ⇒ every accessor below is inert / DEAD.
static func on() -> bool:
	return CubeSphere.FP_SCALED_BODY

# ====================================================================================================
# The distance clamp (§5.2). scale_for returns the SHIPPED-equivalent 1.0 at/below engage (near regime
# untouched) and the angular-size-preserving min(1, D_ENGAGE/d) above it. C0-continuous at engage (s == 1
# there from both sides). d and r_body are in blocks; the home body's r_body is FacetAtlas.R_BLOCKS.
# ====================================================================================================
static func d_engage(r_body: float) -> float:
	return r_body + H_ENGAGE

static func scale_for(d: float, r_body: float) -> float:
	var de := d_engage(r_body)
	if d <= de:
		return 1.0
	return de / d

## The clamped RENDER distance of the body centre from the camera: d·s == min(d, D_ENGAGE). Monotone
## non-decreasing then flat at D_ENGAGE — the number the depth buffer actually sees. C0 at engage.
static func clamped_distance(d: float, r_body: float) -> float:
	return d * scale_for(d, r_body)

## The uniform-scale-about-the-camera transform applied to the far ring's TRUE-SCALE placement. Composing this
## on the left of the shipped placement scales the whole (camera-relative) body by s about `cam`: world(x) =
## cam + s·(true_world(x) − cam) = s·x + (1 − s)·cam. With s == 1 this is IDENTITY (⇒ transform == the shipped
## placement, byte-identical), so the flag-off / near-regime path is unchanged. Pure math; safe off-thread.
static func scale_about_camera(cam: Vector3, s: float) -> Transform3D:
	return Transform3D(Basis.IDENTITY.scaled(Vector3(s, s, s)), (1.0 - s) * cam)

## The body's rendered angular DIAMETER (radians) as the camera sees it: 2·asin(R/d). INVARIANT to the clamp s
## (a uniform scale about the camera preserves the subtended angle exactly), hence C0 in d — the "no pop across
## the border" numeric guarantee the gate asserts. Undefined inside the body (d ≤ R); clamped to π there.
static func angular_size(d: float, r_body: float) -> float:
	if d <= r_body:
		return PI
	return 2.0 * asin(r_body / d)

# ====================================================================================================
# Altitude-continuous camera planes (§5.4). Both are C0 ramps whose h = 0 / d = R values are EXACTLY the
# shipped 0.05 / 9000 (gate G-SN-NEARFAR), monotone non-decreasing, clamped to their caps. h is radial
# altitude (blocks) = d − R; d = |camera − body_centre| (blocks).
# ====================================================================================================
static func camera_near(h: float) -> float:
	return clampf(h / NEAR_H_DIV, NEAR_MIN, NEAR_MAX)

static func camera_far(d: float, r_body: float) -> float:
	var tangent_sq := d * d - r_body * r_body
	if tangent_sq <= 0.0:
		return FAR_MIN
	return maxf(FAR_MIN, FAR_TANGENT_K * sqrt(tangent_sq))

# ====================================================================================================
# Retire / persistence policy (§5.5, §10 SN3). Stateless hysteresis: given the tier's LATCHED state, decide
# whether it is retired at altitude h. Retire once h exceeds retire_h·(1 + hyst); un-retire only once h drops
# below retire_h·(1 − hyst) — the ±25% band that prevents flip-flop at the boundary. The far ring uses
# FARRING_RETIRE_H (≈ never), which is the persistence guarantee: it never retires at a skin/pool altitude.
# ====================================================================================================
static func retire_hi(retire_h: float) -> float:
	return retire_h * (1.0 + RETIRE_HYST)

static func retire_lo(retire_h: float) -> float:
	return retire_h * (1.0 - RETIRE_HYST)

static func should_retire(h: float, currently_retired: bool, retire_h: float) -> bool:
	if currently_retired:
		return h > retire_lo(retire_h)   # stay retired until we sink back below the low threshold
	return h > retire_hi(retire_h)       # retire only once we rise past the high threshold

## The far ring's persistence predicate: NEVER retired within the playable envelope (FARRING_RETIRE_H ≈ 1e9),
## so the surface stays visible from space at every altitude the clamp reaches (SEAMLESS-SCALES §0.1).
static func far_ring_retired(h: float, currently_retired: bool) -> bool:
	return should_retire(h, currently_retired, FARRING_RETIRE_H)
