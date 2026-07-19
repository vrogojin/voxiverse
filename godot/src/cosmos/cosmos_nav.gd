extends RefCounted
class_name CosmosNav
## COSMOS SPACE-NAV SN2 — the five-mode NAV-FRAME state machine (docs/COSMOS-SPACE-NAV-DESIGN.md §4/§5/§10).
## The user's five navigation modes {PLANETARY, LOW_ORBIT, HIGH_ORBIT, DEEP_SPACE, INTERSTELLAR} are NOT
## five physics regimes — they are five RE-EXPRESSIONS of the ONE f64 BCI [pos,vel] state (SN1's
## OrbitalState). This kernel is: (1) `classify()` — the §4.3 priority decision list over the §4.2 f64
## inputs, with the §4.5 multiplicative hysteresis folded in the incumbent's favour and the R-detach latch;
## (2) `NavState` — the small machine wrapper holding the incumbent mode + the 2-s dwell timer + the R-latch;
## (3) the frame-explicit HUD velocity + carrier-velocity re-expressions (reusing SN1's OrbitalState frame
## algebra — NOT reimplemented here) + the telemetry dict.
##
## KEYSTONE (SPACE-NAV §0.1, §4.1): a mode flip is a pure HUD/controller re-expression. This kernel
## NEVER touches the scene graph, NEVER moves geometry, NEVER mutates the physical [pos,vel] state — every
## function is const in its inputs and returns fresh values. That is what makes seamlessness a THEOREM
## (G-SN-CONT): the classifier/machine cannot inject Δv, so `v_bci(t+dt) − v_bci(t) == (g+a_thrust+a_drag)·dt`
## at EVERY tick, including mode-flip ticks. There are no impulse terms because there is no code path here
## that could write velocity.
##
## PRECISION: all math f64 (GDScript float is IEEE-754 f64); positions/velocities are DVec3
## (PackedFloat64Array). Every local dynamic reads CosmosGravity.gm_dyn (SPACE-NAV §3), never the sky's
## GM_game. NEVER-OOM: pure statics + a ~40-byte NavState (four scalars); zero per-frame allocation beyond
## the fresh DVec3 temps the frame maps already return.
##
## AMBIGUITY RESOLVED (D-SN-CLASS-1, flagged): the §4.3 decision list as literally written is
## self-contradictory with its own sanity table — LOW rule 2's "(γ>0.01 and u<2.0)" and HIGH rule 3's
## "γ>0.01" both fire for a bound sub-escape orbit (geostationary has γ=0.023>0.01, u≈1<2), so a naive
## first-match makes geostationary LOW_ORBIT, but the table demands HIGH_ORBIT. The only input that
## distinguishes r=5R (table: LOW) from geostationary r=6.6R (table: HIGH) is r vs r_geo_dyn. Resolution:
## LOW rule 2's speed clause is gated `r < r_geo_dyn` — geostationary altitude is the low/high divide (the
## user's own low-vs-high mental model). This makes ALL sanity-table rows self-consistent AND leaves the
## §4.4 geo-guard exactly "redundant here" as the table annotates. See `classify()`.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
# Self-preload so the inner NavState class can reference the outer statics/enum without depending on the
# global class-name cache (CosmosNav may not be registered when a headless gate compiles this in isolation).
const SELF := preload("res://src/cosmos/cosmos_nav.gd")

# The five nav modes (SPACE-NAV §4). Ordered planet-bound → free so the hysteresis can reason "in the
# incumbent's favour" by ordinal position. NONE is the raw / no-incumbent sentinel (no hysteresis applied).
enum { PLANETARY, LOW_ORBIT, HIGH_ORBIT, DEEP_SPACE, INTERSTELLAR }
const NONE := -1
const NAV_NAMES := ["planetary", "low_orbit", "high_orbit", "deep_space", "interstellar"]
## HUD frame labels per mode (SPACE-NAV §7.5): the reference frame the speed is expressed in.
const FRAME_LABELS := ["surface", "orbital", "orbital", "solar", "self"]

# ---------------------------------------------------------------------------------------
# The §4 thresholds — all DATA (retune + re-gate in minutes; risk #2). §4.2/§4.3 numbers verbatim.
# ---------------------------------------------------------------------------------------
const VICINITY_R := 4.0                 # vicinity = r ≤ 4·R_vox (D-SN-1: measured from body centre, §4.2(2))
const GRAV_FRAC_MIN := 0.01             # γ threshold: 1 % of surface gravity. γ = (R/r)² > 0.01 ⟺ r < 10·R
const U_SUBORBITAL := 0.25              # orbital-speed ratio below which a vicinity craft is "planetary" (suborbital)
const U_ESCAPE := 2.0                   # ratio at/above which flight is "hyperbolic escape" (200 % orbital speed)
const S_SOLAR := 1.0                    # solar-speed ratio: 1× solar orbital speed
const S_INTER := 10.0                   # 10× solar orbital speed — the interstellar gate
const R_SYSTEM := 6.0e9                 # solar-system radius (≈ 40 AU = 40·1.496e8 blocks) — DEEP/INTER helio gate
const GEO_GUARD_K := 1.2                # HIGH geo-guard: r ≤ 1.2·r_geo_dyn (§4.4)
const GEO_SOI_CAP := 0.9               # geo-guard capped at 0.9·R_SOI for bodies where r_geo > SOI (the Moon, §4.4)

# Hysteresis (§4.5): margins applied in the incumbent's favour; the caller enforces the 2-s dwell.
const NAV_DWELL_S := 2.0                # a committed mode change requires the raw mode held this long
const SPEED_MARGIN := 0.10              # ±10 % on every speed-ratio threshold (u, s)
const RADIUS_MARGIN := 0.05             # ±5 % on every radius threshold (4R, 10R, 1.2·r_geo, R_SYSTEM)
const ATMO_MARGIN := 32.0               # ±32 blocks absolute on the atmosphere band (the O1O4 band)

# ---------------------------------------------------------------------------------------
# Space-nav per-frame dt safety (G-SN-NOSPIRAL). A post-hitch frame can hand the space-nav path a huge dt
# (a 16-s recovery frame was observed live). The nav tick + any integration must NEVER see a runaway dt, or
# a per-frame loop whose count scales with dt lengthens the next frame → an exponential freeze. Two guards:
#   MAX_NAV_DT — the per-frame dt clamp fed to the nav tick / dev-flight. 1/30 s: a normal 60-fps frame
#     (dt = 1/60 < 1/30) is UNTOUCHED, so this is byte-neutral in the common case; a spike is bounded to
#     ≤ 2 integrator substeps. clamp_nav_dt keeps the clamp in ONE place (player + gate agree).
#   MIN_FD_DT — the floor on the finite-difference dt (v_fix = (p − prev)/dt in player._nav_tick). Guards a
#     near-zero delta from exploding the derived velocity. fd_inv_dt(dt) = 1/max(dt, MIN_FD_DT) is bounded.
# ---------------------------------------------------------------------------------------
const MAX_NAV_DT := 0.03333333333333333  # 1/30 s — clamp on the dt fed to the space-nav per-frame path
const MIN_FD_DT := 1.0e-4                 # floor (s) on the finite-difference dt so v_fix cannot blow up
# G-REENTRY FIX D: cap on the REAL frame dt fed to the NavState DWELL (which is UX seconds, not integrator
# time). Feeding it MAX_NAV_DT starves the 2-s dwell under multi-second frames (the live "stuck low_orbit
# at 160k": ~10 frames in 147 s accrued 0.3 s) — the dwell must see wall time. Capped at 1 s so one absurd
# hitch frame cannot alone commit a transient mode flap (still needs ≥ 2 consecutive agreeing frames).
const NAV_DWELL_DT_MAX := 1.0

## Clamp a per-frame dt to the space-nav safe range [0, MAX_NAV_DT] (G-SN-NOSPIRAL). Pure; the player and the
## gate call this ONE function so the bound they enforce/assert are identical. dt ≤ 0 passes through as 0.
static func clamp_nav_dt(dt: float) -> float:
	return minf(dt, MAX_NAV_DT) if dt > 0.0 else 0.0

## Bounded reciprocal for the finite-difference velocity (v_fix = Δp · fd_inv_dt): 1/max(dt, MIN_FD_DT).
## Never larger than 1/MIN_FD_DT, so a near-zero delta cannot produce an unbounded derived velocity.
static func fd_inv_dt(dt: float) -> float:
	return 1.0 / maxf(dt, MIN_FD_DT)

# ---------------------------------------------------------------------------------------
# G-REENTRY velocity/state sanity (2026-07-19 live de-orbit blowup). The SN2 finite-difference velocity is
# Δp/dt of whatever the position DID — including a discontinuity (a half-committed crossing left the lattice
# pose in a stale frame → an ~11 k-block one-frame jump → v_fd = 642074 b/s). That garbage was then ADOPTED
# as a physical velocity by the free-fall re-seed and latched (the player "escaped" outward for minutes).
# Two invariants close the class:
#   sane_v        — a derived/adopted BCI velocity must be finite and ≤ FD_SPEED_MAX, else fall back to the
#                   last known-good velocity (velocity-continuous, SN-R1) or rest. A position discontinuity
#                   can then never become motion.
#   clamp_bci_state — an integrated BCI [p,v] must be finite and inside the body's SOI, else revert to the
#                   pre-step state / clamp to the SOI sphere with the outward radial velocity removed. A
#                   garbage state can then never take the player to work-unbounded altitudes (the 27 s/frame
#                   streaming collapse observed at 35·R).
# FD_SPEED_MAX = 20000 b/s: 2× the largest legitimate speed authority in the game (SN_DEV_V_MAX = 10000,
# INTERSTELLAR; every orbital/escape speed at this scale is ≤ ~600), so no real flight is ever clipped,
# while the 642074-class finite-difference of any frame-sized teleport is rejected outright.
# ---------------------------------------------------------------------------------------
const FD_SPEED_MAX := 20000.0

## True iff `v` is a well-formed, finite, ≤ FD_SPEED_MAX DVec3. Pure.
static func v_is_sane(v: PackedFloat64Array) -> bool:
	if v.size() != 3:
		return false
	if is_nan(v[0]) or is_nan(v[1]) or is_nan(v[2]) or is_inf(v[0]) or is_inf(v[1]) or is_inf(v[2]):
		return false
	return DV.length(v) <= FD_SPEED_MAX

## Sanitize a derived/adopted BCI velocity: return `v` if sane; else the last-good `fallback` if sane; else
## rest. Always returns a fresh 3-vector (never aliases the inputs). Pure; gate G-NAV-SANEV.
static func sane_v(v: PackedFloat64Array, fallback: PackedFloat64Array) -> PackedFloat64Array:
	if v_is_sane(v):
		return PackedFloat64Array([v[0], v[1], v[2]])
	if v_is_sane(fallback):
		return PackedFloat64Array([fallback[0], fallback[1], fallback[2]])
	return DV.v(0.0, 0.0, 0.0)

## Sanitize an integrated BCI [p, v] against the pre-step [p_prev, v_prev]: any non-finite component reverts
## the WHOLE state to the pre-step pair (never adopt a broken integration); a radius beyond `r_max` (the
## body's SOI, or any caller cap; INF ⇒ no radius clamp) is clamped onto the r_max sphere with the OUTWARD
## radial velocity component removed (the tangential part is preserved — velocity-continuous at the clamp).
## Returns [p, v] as fresh vectors. Pure; gate G-NAV-SOICLAMP.
static func clamp_bci_state(p: PackedFloat64Array, v: PackedFloat64Array,
		p_prev: PackedFloat64Array, v_prev: PackedFloat64Array, r_max: float) -> Array:
	var bad := p.size() != 3 or v.size() != 3
	if not bad:
		for i in 3:
			if is_nan(p[i]) or is_inf(p[i]) or is_nan(v[i]) or is_inf(v[i]):
				bad = true
				break
	if bad:
		return [PackedFloat64Array([p_prev[0], p_prev[1], p_prev[2]]),
			PackedFloat64Array([v_prev[0], v_prev[1], v_prev[2]])]
	var r := DV.length(p)
	if is_inf(r_max) or r <= r_max or r <= 0.0:
		return [PackedFloat64Array([p[0], p[1], p[2]]), PackedFloat64Array([v[0], v[1], v[2]])]
	var rhat := DV.scale(p, 1.0 / r)
	var v_out := DV.dot(v, rhat)
	var v_new := DV.sub(v, DV.scale(rhat, maxf(v_out, 0.0)))   # strip only the OUTWARD radial part
	return [DV.scale(rhat, r_max), v_new]

# ---------------------------------------------------------------------------------------
# Per-body derived radii (SPACE-NAV §3/§4). Pure reads of the ephemeris + GM_dyn scale bridge.
# ---------------------------------------------------------------------------------------

## Classification atmosphere band (blocks) for `body` — the h below which the machine reads PLANETARY.
## Earth 384 (CubeSphere.ATMO_TOP); Moon 256 (§8.2 — CLASSIFICATION-only, has_atmo stays false); else 0.
static func h_atmo(body: String) -> float:
	if body == "earth":
		return CubeSphere.ATMO_TOP
	if body == "moon":
		return 256.0
	return 0.0

## Geostationary (body-fixed circular) orbit radius under GM_dyn (blocks): r_geo = (GM_dyn/ω_spin²)^{1/3}
## (§3 table). Earth interim ≈ 20,370. A body with no spin (ω_spin == 0) has no such radius ⇒ +INF.
static func r_geo_dyn(body: String) -> float:
	var w := EPH.omega_spin(body)
	if w <= 0.0:
		return INF
	var mu := GRAV.gm_dyn(body)
	return pow(mu / (w * w), 1.0 / 3.0)

## Sphere-of-influence radius (blocks): a·(GM_dyn(body)/GM_game(parent))^{2/5} (§3 table). Earth interim
## ≈ 385 k, Moon ≈ 66.1 k. NOTE (disclosed, §3/R7): the PARENT GM is the un-rescaled GM_game (the real
## mass ratio), matching the design's tabulated numbers (Moon SOI 66.1 k < r_geo 88.5 k ⇒ no
## selenostationary orbit — the load-bearing §4.4 corner). The body GM is GM_dyn (collapses to GM_game
## post-O3). A parentless body (the Sun) has no SOI ⇒ +INF.
static func soi_radius(body: String) -> float:
	var par := EPH.parent_of(body)
	var a := EPH.orbit_a(body)
	if par == "" or a <= 0.0:
		return INF
	return a * pow(GRAV.gm_dyn(body) / EPH.gm_game(par), 0.4)

## The DEEPEST-SOI body dominating a point at BCI position `p_bci` relative to `from_body`, at time t
## (O1O4 §3.5 / SPACE-NAV §5.2, O4c). Two moves, mirror images:
##   (a) CHILD CAPTURE — for each satellite of `from_body`, re-express the point into that child's BCI frame
##       (OrbitalState.reexpress_soi) and, if it lies within the child's SOI·(1∓hyst), the child dominates.
##   (b) PARENT ESCAPE — if `from_body` itself orbits a parent and the point has left `from_body`'s own
##       SOI·(1±hyst), the parent dominates.
## Else `from_body` keeps dominion. `hyst` is the fractional SOI hysteresis band (SPACE-NAV §5.2, 0.02): the
## boundary is contracted for capture and expanded for release IN THE INCUMBENT'S FAVOUR (incumbent == the body
## the point is currently expressed relative to, `from_body`), so a grazing trajectory cannot flap. hyst == 0 ⇒
## the raw geometric boundary (the gate drives both). Pure: no engine state, no allocation beyond frame temps.
## NOTE this returns the IMMEDIATE neighbour in the SOI tree (child or parent) — one hop per call; the caller
## re-tests from the new body next tick, which walks a multi-level hierarchy one boundary at a time (correct:
## you cannot enter a grandchild's SOI without first entering the child's, by nesting).
static func soi_dominant(from_body: String, p_bci: PackedFloat64Array, t: float, hyst: float = 0.0) -> String:
	# (a) child capture — a satellite whose (contracted) SOI contains the point wins.
	for child in EPH.children_of(from_body):
		var pc: PackedFloat64Array = ORB.reexpress_soi(from_body, child, t, p_bci, DV.v(0.0, 0.0, 0.0))[0]
		if DV.length(pc) < soi_radius(child) * (1.0 - hyst):
			return child
	# (b) parent escape — left our own (expanded) SOI ⇒ hand up to the parent.
	var par := EPH.parent_of(from_body)
	if par != "":
		var rs := soi_radius(from_body)
		if not is_inf(rs) and DV.length(p_bci) > rs * (1.0 + hyst):
			return par
	return from_body

## The §4.4 geo-guard radius: min(1.2·r_geo_dyn, 0.9·R_SOI). Below it, the body's own spin defines a
## stationary orbit ⇒ planet-frame (HIGH_ORBIT) territory. Handles r_geo == INF (no spin).
static func geo_cap(body: String) -> float:
	var rg := r_geo_dyn(body)
	if is_inf(rg):
		return 0.0                                          # no spin ⇒ the guard clause never fires
	return minf(GEO_GUARD_K * rg, GEO_SOI_CAP * soi_radius(body))

## True iff a geostationary orbit physically exists for `body` (r_geo ≤ SOI). The G key reports "none"
## when false (the Moon: r_geo 88.5 k > SOI 66.1 k). §4.4 / §7.4.
static func has_stationary_orbit(body: String) -> bool:
	var rg := r_geo_dyn(body)
	if is_inf(rg):
		return false
	return rg <= soi_radius(body)

# ---------------------------------------------------------------------------------------
# The classifier inputs (§4.2) — packed once, reused by classify() and the HUD/telemetry. All f64.
# ---------------------------------------------------------------------------------------

## Compute the §4.2 scalar inputs for a BCI state over `body` at time t. Returns a Dictionary
## {r, h, v_circ, u, gamma, r_helio, s} — pure, no allocation beyond the frame-map temps.
static func inputs(body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float) -> Dictionary:
	var rv := GRAV.r_vox(body)
	var r := DV.length(p_bci)
	var mu := GRAV.gm_dyn(body)
	var v_circ := sqrt(mu / r) if r > 0.0 else 0.0
	var speed := DV.length(v_bci)
	var u := speed / v_circ if v_circ > 0.0 else 0.0
	var gamma := (rv / r) * (rv / r) if r > 0.0 else INF
	# Heliocentric: p_hel = p_bci + body_pos_helio; v_hel = v_bci + body_vel_helio (SN1 frame algebra).
	var hel := ORB.bci_to_helio(body, t, p_bci, v_bci)
	var p_hel: PackedFloat64Array = hel[0]
	var v_hel: PackedFloat64Array = hel[1]
	var r_helio := DV.length(p_hel)
	var v_sol := sqrt(EPH.gm_game("sun") / r_helio) if r_helio > 0.0 else 0.0
	var s := DV.length(v_hel) / v_sol if v_sol > 0.0 else 0.0
	return {"r": r, "h": r - rv, "v_circ": v_circ, "u": u, "gamma": gamma, "r_helio": r_helio, "s": s}

# ---------------------------------------------------------------------------------------
# The classifier (§4.3 decision list + §4.5 hysteresis + R-latch). ONE pure function.
# ---------------------------------------------------------------------------------------

## Classify a BCI state over `body` at time t into a NavMode. `incumbent` is the current committed mode
## (NONE ⇒ raw, no hysteresis — used for the sanity table's interior points); the §4.5 margins are applied
## in the incumbent's favour so a boundary must be crossed by its margin to leave. `r_latch` (the §7.4
## R-detach bit) forces DEEP_SPACE expression whenever the raw mode is HIGH_ORBIT, until cleared.
##
## This is a PURE READ: it computes a mode from immutable inputs and returns it. It cannot and does not
## alter the physical state — the property G-SN-CONT relies on.
static func classify(body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float,
		incumbent: int = NONE, r_latch: bool = false) -> int:
	var inp := inputs(body, p_bci, v_bci, t)
	var m := _classify_inputs(body, inp, incumbent)
	if r_latch and m == HIGH_ORBIT:
		return DEEP_SPACE                                   # §7.4 R-detach: express deep-space HUD/controls from high orbit
	return m

## The decision list over pre-computed inputs, with the incumbent-favoured effective thresholds. Split out
## so gates can drive it with synthetic inputs directly.
static func _classify_inputs(body: String, inp: Dictionary, incumbent: int) -> int:
	var rv := GRAV.r_vox(body)
	var r := float(inp["r"])
	var h := float(inp["h"])
	var u := float(inp["u"])
	var s := float(inp["s"])
	var r_helio := float(inp["r_helio"])

	# --- effective thresholds (§4.5): expand the incumbent's region so leaving needs the margin ---
	# Atmosphere band (absolute ±32): PLANETARY leaves above H+32, re-enters below H−32.
	var atmo := h_atmo(body)
	var atmo_eff := atmo
	if incumbent == PLANETARY: atmo_eff = atmo + ATMO_MARGIN
	elif incumbent != NONE: atmo_eff = atmo - ATMO_MARGIN
	# Escape speed 2.0 (LOW↔HIGH via u): LOW stays low until u > 2.2; HIGH re-enters below 1.8.
	var u_esc := _speed_thr(U_ESCAPE, incumbent == LOW_ORBIT, incumbent, incumbent == HIGH_ORBIT)
	# Solar-speed 1.0 (HIGH escape clause, u≥2 and s<1): HIGH stays until s>1.05; others below 0.95.
	var s_sol := _speed_thr(S_SOLAR, incumbent == HIGH_ORBIT, incumbent, incumbent == DEEP_SPACE or incumbent == INTERSTELLAR)
	# Interstellar-speed 10.0 (DEEP↔INTER): DEEP stays until s>10.5; INTER re-enters below 9.5.
	var s_int := _speed_thr(S_INTER, incumbent == DEEP_SPACE, incumbent, incumbent == INTERSTELLAR)
	# Vicinity 4R (radius ±5 %): favour "inside" (PLANETARY / LOW) ⇒ larger.
	var vic := VICINITY_R * rv * _rad_scale(incumbent == PLANETARY or incumbent == LOW_ORBIT, incumbent, incumbent >= HIGH_ORBIT)
	# Gravity-well edge 10R (γ = 0.01 ⟺ r = R/√0.01): favour "inside well" (LOW / HIGH) ⇒ larger.
	var r_well := (rv / sqrt(GRAV_FRAC_MIN)) * _rad_scale(incumbent == LOW_ORBIT or incumbent == HIGH_ORBIT, incumbent, false)
	# Geostationary divide r_geo (LOW↔HIGH split, D-SN-CLASS-1): LOW stays below r_geo·1.05; HIGH above ·0.95.
	var r_geo := r_geo_dyn(body) * _rad_scale(incumbent == LOW_ORBIT, incumbent, incumbent == HIGH_ORBIT)
	# Geo-guard cap and system radius.
	var cap := geo_cap(body)
	if not is_inf(cap):
		cap *= _rad_scale(incumbent == HIGH_ORBIT, incumbent, false)
	var rsys := R_SYSTEM * _rad_scale(incumbent == DEEP_SPACE, incumbent, incumbent == INTERSTELLAR)

	# --- the §4.3 priority decision list (first match wins) ---
	# 1. PLANETARY: inside the atmosphere band ONLY. The atmosphere ceiling (h < H_ATMO = 384 blocks, ±32
	#    hysteresis) IS the planetary↔low-orbit divide — the user's live decision 2026-07-18, which OVERRIDES
	#    the §4.3 "suborbital in the vicinity stays PLANETARY" clause. Crossing 384 upward is LOW_ORBIT
	#    regardless of speed: a slow hover just above the atmosphere falls through to rule 2 (vicinity).
	if h < atmo_eff:
		return PLANETARY
	# 2. LOW_ORBIT: in the vicinity (above the atmosphere), or bound-ish flight in the well BELOW geostationary
	#    (the D-SN-CLASS-1 `r < r_geo` gate — see the header ambiguity note).
	if r <= vic:
		return LOW_ORBIT
	if r < r_well and u < u_esc and r < r_geo:
		return LOW_ORBIT
	# 3. HIGH_ORBIT: gravity > 1 % (r < 10R), or the geostationary guard, or hyperbolic-but-sub-solar escape.
	if r < r_well:
		return HIGH_ORBIT
	if r <= cap:
		return HIGH_ORBIT
	if u >= u_esc and s < s_sol:
		return HIGH_ORBIT
	# 4. DEEP_SPACE: within the solar system, or below 10× solar speed.
	if r_helio <= rsys:
		return DEEP_SPACE
	if s < s_int:
		return DEEP_SPACE
	# 5. INTERSTELLAR.
	return INTERSTELLAR

## Speed threshold with the ±10 % hysteresis. `favor_up` ⇒ the incumbent sits BELOW the threshold and wants
## to stay (raise the bar to 1+m). `favor_down` ⇒ the incumbent sits ABOVE and wants to stay (lower to 1−m).
## NONE / neither ⇒ base. (One clause; the two flags are mutually exclusive by construction of the callers.)
static func _speed_thr(base: float, favor_up: bool, incumbent: int, favor_down: bool = false) -> float:
	if incumbent == NONE:
		return base
	if favor_up:
		return base * (1.0 + SPEED_MARGIN)
	if favor_down:
		return base * (1.0 - SPEED_MARGIN)
	return base

## Radius scale with the ±5 % hysteresis. `favor_larger` ⇒ expand the incumbent's region (×1.05);
## `favor_smaller` ⇒ shrink it (×0.95); NONE / neither ⇒ 1.0.
static func _rad_scale(favor_larger: bool, incumbent: int, favor_smaller: bool) -> float:
	if incumbent == NONE:
		return 1.0
	if favor_larger:
		return 1.0 + RADIUS_MARGIN
	if favor_smaller:
		return 1.0 - RADIUS_MARGIN
	return 1.0

# ---------------------------------------------------------------------------------------
# Frame-explicit HUD velocity + carrier velocities (§5.1 / §7.2 / §7.5). REUSE the SN1 frame algebra —
# these are thin re-expressions, NOT new physics. Every one is a pure read.
# ---------------------------------------------------------------------------------------

## The player's speed re-expressed in `mode`'s reference frame, plus the frame label (§7.5). PLANETARY →
## surface (body-fixed rotating) speed |v_bci − ω⃗×p|; LOW/HIGH → BCI speed |v_bci|; DEEP → heliocentric
## speed |v_bci + body_vel_helio|; INTERSTELLAR → 0 (the self frame, attitude only). Returns {speed, label}.
static func hud_velocity(mode: int, body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float) -> Dictionary:
	var speed := 0.0
	match mode:
		PLANETARY:
			var vf: PackedFloat64Array = ORB.bci_to_fixed(body, t, p_bci, v_bci)[1]
			speed = DV.length(vf)
		LOW_ORBIT, HIGH_ORBIT:
			speed = DV.length(v_bci)
		DEEP_SPACE:
			var vh: PackedFloat64Array = ORB.bci_to_helio(body, t, p_bci, v_bci)[1]
			speed = DV.length(vh)
		INTERSTELLAR:
			speed = 0.0
	return {"speed": speed, "label": FRAME_LABELS[mode]}

## The BCI velocity of a point AT REST in `mode`'s nav frame at (p, t) — the dev-flight carrier (§7.2):
## v_bci = carrier when the frame-relative command is zero. PLANETARY → ω⃗×p (co-rotates with the surface);
## LOW/HIGH → 0 (station-keeps at the planet centre); DEEP → −body_vel_helio (rest in the sun frame);
## INTERSTELLAR → the passed v_bci (the self frame moves with the craft). Pure; SN5's velocity-command
## controller consumes this. NOTE: SN5 not this phase — provided so the controller has ONE truth.
static func carrier_velocity(mode: int, body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float) -> PackedFloat64Array:
	match mode:
		PLANETARY:
			return ORB.omega_cross(body, p_bci)
		DEEP_SPACE:
			return DV.scale(EPH.body_vel_helio(body, t), -1.0)
		INTERSTELLAR:
			return PackedFloat64Array([v_bci[0], v_bci[1], v_bci[2]])
		_:
			return DV.v(0.0, 0.0, 0.0)                       # LOW_ORBIT / HIGH_ORBIT: BCI rest

## SN-FIX (2026-07-18 live-pilot FIX-B, SN_NO_CEILING_BOUNCE) — the BODY-FIXED (scene/lattice) velocity a
## zero-input kinematic hover must carry so it rests in the NAV FRAME, not in the body-fixed lattice.
##   PLANETARY: the lattice IS the body-fixed rotating frame ⇒ a lattice-fixed hover already co-rotates with
##     the surface (the pilot flies OVER the ground). Nav rest == lattice rest ⇒ ZERO drift (unchanged behaviour).
##   LOW_ORBIT and above: the nav frame is planet-centred INERTIAL (carrier_velocity == 0 in BCI). To hold a
##     BCI-inertial point while the body-fixed surface rotates beneath it, the point's velocity IN THE BODY-FIXED
##     FRAME must be −ω⃗×p_fix: from v_fix = R_z(−θ)·(v_bci − ω⃗×p_bci) with v_bci = 0 and ω⃗∥ẑ (so R_z commutes
##     with the cross product), v_fix = −R_z(−θ)(ω⃗×p_bci) = −ω⃗×p_fix. NO clock needed — it is a closed form in
##     p_fix alone. Magnitude == |ω×p| (the surface spin speed at that radius); direction OPPOSITE the surface's
##     inertial motion, so the observer stays inertial and the surface appears to spin by (the pilot's intent).
## Pure; gate G-SN-HOVERDRIFT. The player applies it as an additive lattice velocity ON TOP of the look-fly input.
static func hover_drift_fixed(mode: int, body: String, p_fix: PackedFloat64Array) -> PackedFloat64Array:
	if mode == PLANETARY:
		return DV.v(0.0, 0.0, 0.0)
	return DV.scale(ORB.omega_cross(body, p_fix), -1.0)

# ---------------------------------------------------------------------------------------
# NavState — the machine wrapper (§4.5): the incumbent mode + the 2-s dwell timer + the R-detach latch.
# The ONLY mutable state in SN2, ~40 bytes. tick() is the per-physics-frame driver; it reads the BCI
# state and updates ONLY its own bookkeeping — it NEVER writes pos/vel (the theorem's precondition).
# ---------------------------------------------------------------------------------------

class NavState extends RefCounted:
	var mode: int = SELF.PLANETARY              # the committed nav mode
	var _pending: int = SELF.PLANETARY          # the raw mode currently accumulating dwell
	var _dwell: float = 0.0                      # seconds the pending mode has been held
	var r_latch: bool = false                   # §7.4 R-detach override bit

	## Advance the machine one physics tick. Reads the BCI state over `body` at time t; applies the raw
	## classifier (with hysteresis in the incumbent's favour) and the 2-s dwell before COMMITTING a change.
	## Returns the committed mode. Mutates ONLY mode/_pending/_dwell/r_latch — never the passed arrays.
	func tick(body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float, dt: float) -> int:
		var raw := SELF._classify_inputs(body, SELF.inputs(body, p_bci, v_bci, t), mode)
		# The R-latch auto-clears the moment the raw expression is no longer HIGH_ORBIT (a natural
		# reclassification, §4.5) — so a detached craft that drifts out of high orbit stops overriding.
		if r_latch and raw != SELF.HIGH_ORBIT:
			r_latch = false
		var eff := SELF.DEEP_SPACE if (r_latch and raw == SELF.HIGH_ORBIT) else raw
		if eff == mode:
			_pending = mode
			_dwell = 0.0
			return mode
		# A different mode: it must persist for NAV_DWELL_S before we commit (UX only — transitions are
		# lossless, so flapping is at worst a cosmetic HUD flicker, §4.5).
		if eff == _pending:
			_dwell += dt
		else:
			_pending = eff
			_dwell = dt
		if _dwell >= SELF.NAV_DWELL_S:
			mode = eff
			_pending = eff
			_dwell = 0.0
		return mode

	## Toggle the R-detach latch (§7.4). Only meaningful from HIGH_ORBIT (else it is a no-op the next tick
	## auto-clears). Returns the new latch state.
	func toggle_r_latch() -> bool:
		r_latch = not r_latch
		return r_latch

# ---------------------------------------------------------------------------------------
# Telemetry (§7.5) — the additive RemoteBridge fields the live loop reads. Guarded, gated, additive: a
# dict built only when the machine is live. Keys: nav_mode (name), frame_v (speed in the nav frame),
# v_bci (raw BCI speed). Pure read of the state + the passed BCI vectors.
# ---------------------------------------------------------------------------------------

static func telemetry(state: NavState, body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float) -> Dictionary:
	var hv := hud_velocity(state.mode, body, p_bci, v_bci, t)
	return {
		"nav_mode": NAV_NAMES[state.mode],
		"frame_v": snappedf(float(hv["speed"]), 0.01),
		"v_bci": snappedf(DV.length(v_bci), 0.01),
		"nav_frame": String(hv["label"]),
	}

## One-line HUD string (§7.5): "<MODE>  <speed> b/s (<frame>)". Additive text; no node work here.
static func hud_line(state: NavState, body: String, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, t: float) -> String:
	var hv := hud_velocity(state.mode, body, p_bci, v_bci, t)
	return "%s  %.1f b/s (%s)" % [NAV_NAMES[state.mode].to_upper(), float(hv["speed"]), String(hv["label"])]
