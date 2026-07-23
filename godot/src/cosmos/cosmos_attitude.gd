extends RefCounted
class_name CosmosAttitude
## COSMOS ORBIT-FRAME — the pure attitude kernel (docs/COSMOS-ORBIT-FRAME-DESIGN.md §7). Engine-free static
## math for the INERTIAL 6DOF space camera: the body-centred-inertial (BCI) attitude quaternion, the scene
## (render) composition R_z(−θ)·q, camera-local look/roll increments, the lattice look-fly basis, and the
## landing-recovery target + eased-slerp blend. Every function is a pure function of its arguments — NO scene,
## NO engine singletons, NO per-frame allocation beyond the fresh return value — so the whole thing is
## headless-gate-testable (verify_orbit_frame.gd), following the CosmosNav/OrbitalState pattern.
##
## FRAME CONVENTION (§1): the spin axis is world +Z (the CubeSphere face / cosmos convention). R_z(±θ) is the
## BCI↔body-fixed rotation — the SAME rotation OrbitalState.bci_to_fixed applies (−θ about +Z) and the SAME the
## star dome renders (cosmos_sky.gd: Basis(+Z, −spin)). A star pattern fixed in BCI therefore renders in the
## body-fixed scene as R_z(−θ)·P; an inertially-held camera whose BCI basis is a constant q renders as
## R_z(−θ)·Basis(q), so the view-relative star rotation B_rel = Basis(q)⁻¹ is CONSTANT — the theorem (§2) that
## makes both live-pilot bugs one bug. This kernel supplies the composition; the sky render is UNTOUCHED.

## The planet spin / BCI axis (+Z) — the axis R_z rotates about.
const SPIN_AXIS := Vector3(0.0, 0.0, 1.0)
## Recovery / surface pitch clamp (rad) — the shipped surface FPS clamp (player.gd set_initial_look ±1.5).
const PITCH_CLAMP := 1.5
## Degeneracy floor for the recovery forward-vector azimuth (|f.xz| below this ⇒ derive yaw from camera X).
const DEGEN_EPS := 1.0e-4

## R_z(ang) about the spin axis (+Z) as a Basis. Pure rotation.
static func rot_z(ang: float) -> Basis:
	return Basis(SPIN_AXIS, ang)

## Seed the BCI camera quaternion from the current displayed SCENE basis (§3.3 eq (3)):
## q_bci = Quaternion(R_z(+θ)·B_scene). By construction scene_basis(seed_bci(B,θ),θ) == B (C0 — no view pop).
static func seed_bci(b_scene: Basis, theta: float) -> Quaternion:
	return (rot_z(theta) * b_scene.orthonormalized()).get_rotation_quaternion()

## The SCENE (render) basis from the BCI quaternion at spin angle θ (§3.2 eq (2)): B = R_z(−θ)·Basis(q).
## Contains NO facet term ⇒ the space attitude is facet-independent (crossing-immune, §6.2).
static func scene_basis(q: Quaternion, theta: float) -> Basis:
	return rot_z(-theta) * Basis(q)

## Camera-local look increment (§3.4): yaw about local +Y by −dx·sens, then pitch about local +X by −dy·sens.
## Right-multiplied (camera-local) ⇒ NO gimbal lock, NO ±90° pitch clamp. Renormalized (f32 drift guard).
static func apply_look(q: Quaternion, dx: float, dy: float, sens: float) -> Quaternion:
	var out := q * Quaternion(Vector3(0, 1, 0), -dx * sens)
	out = out * Quaternion(Vector3(1, 0, 0), -dy * sens)
	return out.normalized()

## Camera-local roll increment (§3.4): roll about local +Z by dir·rate·dt (dir = +1 / −1). Renormalized.
static func apply_roll(q: Quaternion, dir: float, dt: float, rate: float) -> Quaternion:
	return (q * Quaternion(Vector3(0, 0, 1), dir * rate * dt)).normalized()

## The camera basis expressed in the active facet's LATTICE frame (§5(a)): fid_basisᵀ · B_scene (scene→lattice;
## fid_basis is orthonormal ⇒ transpose == inverse). Phase B flies the columns of this basis.
static func lat_cam_basis(fid_basis: Basis, b_scene: Basis) -> Basis:
	return fid_basis.transposed() * b_scene

## Landing-recovery target (§3.5): [yaw*, pitch*] gravity-aligned SURFACE parameters recovered from the frozen
## scene basis b_start in the active facet frame b_active. In the lattice frame b_lat = b_activeᵀ·b_start the
## forward f = −b_lat.z; yaw* = atan2(−f.x, −f.z), pitch* = clamp(asin(f.y/|f|), ±1.5), roll* ≡ 0 (implicit:
## the target basis R_y·R_x has a horizontal right-axis). Degenerate |f.xz| < ε (looking straight along the
## facet normal): derive yaw from the camera X-axis instead — yaw* = atan2(−x.z, x.x). Returns Vector2(yaw*, pitch*).
static func recover_target(b_active: Basis, b_start: Basis) -> Vector2:
	var b_lat := b_active.transposed() * b_start
	var f := -b_lat.z
	var yaw: float
	if Vector2(f.x, f.z).length() < DEGEN_EPS:
		var x := b_lat.x
		yaw = atan2(-x.z, x.x)
	else:
		yaw = atan2(-f.x, -f.z)
	var fl := maxf(f.length(), 1.0e-9)
	var pitch := clampf(asin(clampf(f.y / fl, -1.0, 1.0)), -PITCH_CLAMP, PITCH_CLAMP)
	return Vector2(yaw, pitch)

## The eased-slerp recovery SCENE basis (§3.5): b_active · slerp(b_lat_start, Quaternion(R_y(yaw*)·R_x(pitch*)),
## smoothstep(α)). smoothstep gives C¹ endpoints (zero angular-velocity step). At α=0 it equals b_active·b_lat_start
## (== the frozen scene start when b_lat_start = b_activeᵀ·b_start ⇒ C0 continuity); at α=1 it equals the surface
## FPS reconstruction b_active·R_y(yaw*)·R_x(pitch*) (== the hand-back euler basis ⇒ no jump at hand-back either).
static func recover_blend(b_active: Basis, b_lat_start: Quaternion, yaw_t: float, pitch_t: float, alpha: float) -> Basis:
	var target := Basis(Vector3(0, 1, 0), yaw_t) * Basis(Vector3(1, 0, 0), pitch_t)
	var s := smoothstep(0.0, 1.0, clampf(alpha, 0.0, 1.0))
	var blended := b_lat_start.normalized().slerp(target.get_rotation_quaternion(), s)
	return b_active * Basis(blended)

## The surface FPS reconstruction basis in the LATTICE frame from (yaw, pitch): R_y(yaw)·R_x(pitch). The
## hand-back target — b_active·this is the displayed basis at α=1, and its right-axis (X column) is horizontal
## (zero component along the facet normal +Y) ⇒ roll == 0 by construction. Exposed for the gate.
static func surface_lat_basis(yaw: float, pitch: float) -> Basis:
	return Basis(Vector3(0, 1, 0), yaw) * Basis(Vector3(1, 0, 0), pitch)
