extends RefCounted
class_name CosmosDevFlight
## COSMOS SPACE-NAV SN5 — the DEV-FLIGHT velocity-command controller (docs/COSMOS-SPACE-NAV-DESIGN.md §7.2,
## §5.3 SN-R1). This is the mechanism that makes dev-nav (F) actually PILOTABLE across the five nav frames:
## camera-frame input sets a commanded velocity `v_cmd` IN THE CURRENT NAV FRAME, which is converted each tick
## to a BCI velocity and applied KINEMATICALLY (gravity off — a dev/creative verb, exactly like the shipped
## fly toggle). Zero input ⇒ rest in the frame ⇒ planetary hover tracks the spinning surface (carrier = ω⃗×p),
## orbital hover station-keeps to the planet centre (carrier = 0), deep-space hover rests in the sun frame
## (carrier = −body_vel_helio).
##
## KEYSTONE — SN-R1 BY CONSTRUCTION (§5.3). The controller's STATE is the PHYSICAL BCI velocity, not a stored
## `v_cmd`. Each tick the frame-relative command is DERIVED as `v_cmd = v_bci − carrier(mode)` — a pure
## re-expression of the current physical velocity in the current frame. Then it is ramped toward the input's
## desired command at a bounded rate (DEV_ACCEL), and the new physical velocity is `v_bci' = carrier + v_cmd'`.
## Because `carrier` cancels between the derivation and the reconstruction:
##     v_bci' − v_bci  ==  move_toward(v_bci − carrier, desired, DEV_ACCEL·dt) − (v_bci − carrier)
## whose magnitude is ≤ DEV_ACCEL·dt at EVERY tick — INCLUDING a mode-flip tick, where `carrier` (and `desired`)
## change discontinuously but the physical velocity does NOT. The commanded velocity is re-expressed, never
## reset to frame-rest; there is no code path that can inject an impulse at a boundary. That is the SN-R1
## no-jerk guarantee, and it is what G-SN-DEVFLIGHT proves headless (verify_dev_flight.gd, scenario (c)).
##
## PRECISION: all math f64 (GDScript float is IEEE-754 f64); positions/velocities are DVec3
## (PackedFloat64Array). Reuses the SN1 frame algebra (CosmosNav.carrier_velocity / OrbitalState maps,
## CosmosGravity.gm_dyn) — NOT reimplemented. NEVER-OOM: pure statics, O(1) per call (a handful of 24-B DVec3
## temps), zero retained state (the caller owns [p,v]). DEAD unless CubeSphere.SN_DEVNAV drives it in-game;
## the headless gate exercises it directly.
##
## HONESTY (per SN1's precedent): the controller MATH + the mode-transition TRAJECTORY are headless-proven by
## G-SN-DEVFLIGHT. Only the in-game FEEL (how it flies) and the rendered LOOK are LIVE-ONLY (morning session).

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")

# ---------------------------------------------------------------------------------------
# Tunables — all DATA (feel is live-only; retune + re-gate cheaply). §7.2 speed table + the SN-R1 assist.
# ---------------------------------------------------------------------------------------
const PLANETARY_FLY_SPEED := 16.0   # shipped fly base (player.gd fly_speed); ×2 while running. Lattice path unchanged.
const HIGH_ORBIT_FLOOR := 50.0      # §7.2: HIGH_ORBIT cap = 0.25·v_circ(r), floored at 50 b/s as r grows
const DEEP_FRAC := 0.25             # DEEP_SPACE cap = 0.25·v_sol(r_helio)
const LOW_FRAC := 0.25              # LOW/HIGH cap = 0.25·v_circ(r)
const SN_DEV_V_MAX := 10000.0       # INTERSTELLAR: a const acceleration authority (self-frame; space is empty, §13)
## The velocity-command ramp / SN-R1 assist (blocks/s²). Bounds the per-tick Δv so powered flight is C0 across
## every mode boundary (§5.3: "any assist/damping ramps in over ≥1 s"). Sized so the largest carrier jump — the
## HIGH↔DEEP heliocentric handoff (~2145 b/s) — is a smooth reference change, never an impulse. Retunable.
const DEV_ACCEL := 40.0

# ---------------------------------------------------------------------------------------
# Per-mode dev-fly speed cap (§7.2 table). Pure read; `run` doubles ONLY PLANETARY (the shipped fly ×2), the
# orbital caps are physically defined (fractions of the local circular / solar speed) and ignore run.
# ---------------------------------------------------------------------------------------
static func speed_cap(mode: int, body: String, p_bci: PackedFloat64Array, t: float, run: bool = false) -> float:
	match mode:
		NAV.PLANETARY:
			return PLANETARY_FLY_SPEED * (2.0 if run else 1.0)
		NAV.LOW_ORBIT:
			var r := DV.length(p_bci)
			return LOW_FRAC * sqrt(GRAV.gm_dyn(body) / r) if r > 0.0 else 0.0
		NAV.HIGH_ORBIT:
			var r := DV.length(p_bci)
			var vc := LOW_FRAC * sqrt(GRAV.gm_dyn(body) / r) if r > 0.0 else 0.0
			return maxf(HIGH_ORBIT_FLOOR, vc)
		NAV.DEEP_SPACE:
			# 0.25·v_sol at the heliocentric radius (the sun-frame speed). p_hel = p_bci + body_pos_helio.
			var p_hel := DV.add(p_bci, EPH.body_pos_helio(body, t))
			var rh := DV.length(p_hel)
			return DEEP_FRAC * sqrt(EPH.gm_game("sun") / rh) if rh > 0.0 else 0.0
		NAV.INTERSTELLAR:
			return SN_DEV_V_MAX
	return 0.0

# ---------------------------------------------------------------------------------------
# Camera-frame input → a BCI wish DIRECTION. `cam_x/cam_y/cam_z` are the camera basis columns expressed in BCI
# (each a DVec3; the caller maps the scene camera into BCI live — that mapping is the live-only seam, the gate
# passes explicit BCI axes). `wish_local` is the raw WASD/Space/Ctrl vector in the camera's local frame
# (Godot convention: forward = −z, strafe = x, up = y). Returns a UNIT BCI direction, or the zero vector when
# there is no input. Pure; fully camera-relative (6-DOF spectator fly).
# ---------------------------------------------------------------------------------------
static func wish_dir(cam_x: PackedFloat64Array, cam_y: PackedFloat64Array, cam_z: PackedFloat64Array,
		wish_local: Vector3) -> PackedFloat64Array:
	var w := DV.add(DV.add(DV.scale(cam_x, wish_local.x), DV.scale(cam_y, wish_local.y)),
			DV.scale(cam_z, wish_local.z))
	var l := DV.length(w)
	if l <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	return DV.scale(w, 1.0 / l)

# ---------------------------------------------------------------------------------------
# THE controller step (§7.2 / SN-R1). Advance the physical BCI state ONE tick, kinematically. `mode` is the
# CURRENT committed nav mode (from CosmosNav.NavState); `wish_dir_bci` is a unit BCI direction (or zero);
# `cap` is speed_cap(mode, …) for this tick (passed in so the caller can apply run / clamp policy once).
# Returns [p_new, v_new] (fresh DVec3). Reads only its arguments — no engine, no singletons, no retained state.
#
# SN-R1: v_new − v_bci has magnitude ≤ DEV_ACCEL·dt at EVERY tick (see the header proof), so a nav-mode flip
# (which changes `carrier` and `cap`) cannot jerk the physical velocity. G-SN-DEVFLIGHT scenario (c) asserts it.
# ---------------------------------------------------------------------------------------
static func step(mode: int, body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array,
		t: float, dt: float, wish_dir_bci: PackedFloat64Array, cap: float) -> Array:
	var carrier := NAV.carrier_velocity(mode, body, p_bci, v_bci, t)
	# The current frame-relative command, RE-EXPRESSED from the physical velocity (never reset ⇒ continuity).
	var v_cmd := DV.sub(v_bci, carrier)
	var desired := DV.scale(wish_dir_bci, cap)          # the input's commanded frame velocity (|·| = cap, or 0)
	v_cmd = _move_toward(v_cmd, desired, DEV_ACCEL * dt)
	var v_new := DV.add(carrier, v_cmd)                 # v_bci = carrier + v_cmd (§7.2 A⁻¹·v_cmd + carrier)
	var p_new := DV.add(p_bci, DV.scale(v_new, dt))     # kinematic (gravity off — dev/creative verb)
	return [p_new, v_new]

## f64 DVec3 move-toward: step `cur` toward `target` by at most `step` (clamps exactly on arrival). The bounded
## step is the whole SN-R1 guarantee — a mode flip changes `target`/`carrier` but never the per-tick bound.
static func _move_toward(cur: PackedFloat64Array, target: PackedFloat64Array, step: float) -> PackedFloat64Array:
	var d := DV.sub(target, cur)
	var l := DV.length(d)
	if l <= step or l == 0.0:
		return PackedFloat64Array([target[0], target[1], target[2]])
	return DV.add(cur, DV.scale(d, step / l))

# ---------------------------------------------------------------------------------------
# The dev-nav TOGGLES (§7.4). O and G are explicit user COMMANDS (allowed dev verbs), not seams — each sets a
# specific BCI state the caller then either keeps flying or hands to the ORBITAL integrator. R (frame detach) is
# the NavState.toggle_r_latch bit (SN2), not a state edit — no kernel here. All pure, gateable (G-SN-DEVNAV).
# ---------------------------------------------------------------------------------------

## O — circular-orbit release (§7.4): the BCI velocity of a circular orbit at the current radius, in the
## tangential direction picked by the look vector: `v_bci = v_circ(r)·t̂`, `t̂ = normalize(look − (look·r̂)r̂)`.
## A degenerate look (parallel to r̂) keeps the current tangential heading, else falls back to east (ẑ×r̂). The
## result is exactly circular (|v| == v_circ) and purely tangential (v ⊥ r̂). The caller hands it to the ORBITAL
## integrator (freeze-to-Kepler) — the initial impulse is a user command, not a seam.
static func release_circular(body: String, p_bci: PackedFloat64Array, look_bci: PackedFloat64Array,
		cur_v_bci: PackedFloat64Array) -> PackedFloat64Array:
	var r := DV.length(p_bci)
	if r <= 0.0:
		return DV.v(0.0, 0.0, 0.0)
	var v_circ := sqrt(GRAV.gm_dyn(body) / r)
	var rhat := DV.scale(p_bci, 1.0 / r)
	var tang := _tangent_of(look_bci, rhat)
	if DV.length(tang) < 1.0e-9:                        # look parallel to r̂: keep the current tangential heading…
		tang = _tangent_of(cur_v_bci, rhat)
	if DV.length(tang) < 1.0e-9:                        # …else east.
		tang = _east(p_bci)
	var tl := DV.length(tang)
	return DV.scale(tang, v_circ / tl) if tl > 0.0 else DV.v(0.0, 0.0, 0.0)

## G — geostationary snap (§7.4, HIGH only): move to the equatorial point at r_geo preserving the current
## longitude, with `v_bci = ω⃗×p` (exactly circular there, and scene-stationary since the scene frame is
## body-fixed). Returns [p_new, v_new], or an EMPTY array when the body has no stationary orbit (the Moon —
## r_geo > SOI), which the G key reports as "none". A user-invoked dev teleport (§7.4 D-SN-4: instant).
static func geostationary_snap(body: String, p_bci: PackedFloat64Array) -> Array:
	if not NAV.has_stationary_orbit(body):
		return []
	var rg := NAV.r_geo_dyn(body)
	var phi := atan2(p_bci[1], p_bci[0])                # current longitude in the equatorial (XY) plane
	var p_new := DV.v(rg * cos(phi), rg * sin(phi), 0.0)
	var v_new := ORB.omega_cross(body, p_new)          # exactly circular + scene-stationary
	return [p_new, v_new]

## The component of `d` in the tangent plane at r̂ (⊥ r̂): d − (d·r̂)r̂. A pure projection.
static func _tangent_of(d: PackedFloat64Array, rhat: PackedFloat64Array) -> PackedFloat64Array:
	return DV.sub(d, DV.scale(rhat, DV.dot(d, rhat)))

## East at p: normalize(ẑ × r̂) (prograde-east on the equatorial sense). Zero at the poles (caller guards).
static func _east(p: PackedFloat64Array) -> PackedFloat64Array:
	var c := DV.v(-p[1], p[0], 0.0)                     # ẑ × p = (−p_y, p_x, 0)
	var l := DV.length(c)
	return DV.scale(c, 1.0 / l) if l > 0.0 else DV.v(0.0, 1.0, 0.0)
