class_name FallThrottle
extends RefCounted
## COSMOS-PERF FALL-ALTRATE (fix/voxiverse-fall-altrate) — the PURE decision core for the three descent-rate
## throttle flags (FP_FALL_CAMFAR_HOLD / FP_FALL_ATMO_THROTTLE / FP_FALL_RING_HOLD). No state, no engine deps
## beyond CubeSphere, so the gate (G-FALL-ALTRATE) drives it directly with synthetic inputs. Each consumer node
## holds its own tiny scalar state (prev radial distance + timestamps) and calls these to decide whether to
## RE-APPLY its per-frame altitude-ramped write this frame or HOLD the last one.
##
## The contract (proved in verify_fall_altrate.gd):
##   • flag OFF                     ⇒ should_reapply == true ALWAYS ⇒ the consumer writes every frame ⇒ byte-identical.
##   • vertical speed ≤ threshold   ⇒ should_reapply == true ALWAYS ⇒ a slow/steady/at-rest state writes the EXACT
##                                    value every frame ⇒ the held value converges to the exact steady-state instantly.
##   • vertical speed > threshold   ⇒ should_reapply is true only every FALL_THROTTLE_MS of wall time ⇒ the re-apply
##                                    RATE is ≤ 1000/FALL_THROTTLE_MS per second, INDEPENDENT of descent rate and frame
##                                    rate (the "bounded per-frame work regardless of |dAlt/dt|" the gate asserts).

## Absolute radial (altitude) speed in blocks/s from two successive camera-to-body-centre distances and the
## real wall dt (s) between them. Guards dt ≤ 0 (returns 0 ⇒ treated as steady). Pure.
static func radial_speed(prev_d: float, cur_d: float, dt_s: float) -> float:
	if dt_s <= 0.0:
		return 0.0
	return absf(cur_d - prev_d) / dt_s

## True iff |radial speed| counts as a FAST descent/climb (the throttle-engage condition). Pure.
static func is_fast(vspeed_abs: float) -> bool:
	return vspeed_abs > CubeSphere.FALL_THROTTLE_VSPEED

## THE decision: should the consumer RE-APPLY its altitude-ramped write this frame (vs hold the last value)?
##   flag_on            — the consumer's own FP_FALL_* flag (false ⇒ always true ⇒ byte-identical).
##   vspeed_abs         — the current absolute radial speed (blocks/s).
##   ms_since_applied   — wall-ms since this consumer last re-applied (Time.get_ticks_msec() delta).
## Pure; no allocation.
static func should_reapply(flag_on: bool, vspeed_abs: float, ms_since_applied: int) -> bool:
	if not flag_on:
		return true                       # byte-identical off: the shipped every-frame write
	if not is_fast(vspeed_abs):
		return true                       # slow / steady / at rest: write the exact value (converges instantly)
	return ms_since_applied >= CubeSphere.FALL_THROTTLE_MS
