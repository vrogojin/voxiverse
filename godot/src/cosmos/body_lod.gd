class_name BodyLod
extends RefCounted
## COSMOS-LOD-SKY M1 — the multi-body distance LOD SELECTION LAW (docs/COSMOS-LOD-SKY-DESIGN.md §2/§3/§5).
## Pure statics, engine-free, deterministic: every function is a pure function of its arguments (viewport
## px, fov, body radius/relief, distance) plus the frozen per-body tables — NO engine singletons, NO wall
## clock, NO alloc. This makes it worker-safe and fully headless-gateable (verify_body_lod.gd), and it is
## DEAD (never referenced on a hot path) with CubeSphere.FP_BODY_LOD off, so the engine is byte-identical.
##
## WHAT THIS IS (M1 scope): the angular-size law that decides WHICH EXISTING tier a body presents —
## POINT → IMPOSTOR → RING — plus the impostor↔ring handover DECISION, the ±25% hysteresis that stops
## thrash, the G-SSE-INV sub-pixel no-pop bookkeeping, and the multi-body far-tier BYTE accounting
## (N_RING_MAX resident rings, dominant-exclusive dense/skin, the 32 MB global ceiling). It invents NO new
## representation and builds NO new mesh: the per-body RING build is M2 (FP_MOON_RING, rides O4c). The law
## only SELECTS + ACCOUNTS. The dominant body's deeper tiers (DENSE_CAP/SKIN/VOXEL) are driven by the
## EXISTING shell/seamless ladder (CosmosScale retire altitudes), NOT here — tier_raw/tier_hyst cap at RING;
## the deeper enum values exist only for the byte ledger and future M3.
##
## THE LAW (§2), all lengths in blocks, all screen quantities in DEVICE px:
##   K_px            = viewport_height_device_px / (2·tan(fov/2))     # px per radian; recomputed on resize AND zoom
##   ang_px(r,d)     = 2·r / d · K_px                                 # the body's disc in device px (small-angle)
##   relief_px(e,d)  = e / d · K_px                                   # the impostor's max silhouette error in px
##   tier = POINT     if ang_px < P_POINT                             # unshaded dot; phase moot
##          IMPOSTOR  if relief_px < TAU_POP                          # shaded sphere, exact angular size (the shipped sky)
##          RING      if relief_px ≥ TAU_POP                          # the body's own FacetFarRing (built in M2)
##   e_relief is a per-body constant (Earth 112 max mountain, Moon 64 crater amplitude, Sun 0 ⇒ the Sun is
##   IMPOSTOR forever BY THE LAW — genericity, not special-casing). The telescope falls out for free: a narrow
##   fov scales K_px, so relief_px of a distant body crosses TAU_POP and the SAME machinery promotes it (M4).
##
## NO-POP (G-SSE-INV, §2/§8): a tier may only swap when its screen-space delta ≤ its threshold — the
## impostor⇄ring handover fires exactly as relief_px crosses TAU_POP (≈1 px), so the pop is sub-pixel BY THE
## LAW THAT TRIGGERS IT; no cross-fade needed (SEAMLESS-SCALES §0.5: overlap/agreement, not fades). Hysteresis
## is one-sided-sticky: PROMOTE (toward detail) at the nominal threshold, DEMOTE (toward coarse) only once the
## driver falls HYST below it — the ±25% band that kills flip-flop at the boundary (same discipline as
## CosmosScale.should_retire).
##
## NEVER-OOM (§5): this file allocates nothing and retains nothing — the caller owns the latched tier (the
## stateless-hysteresis pattern, cf. CosmosScale.should_retire). The byte ledger below is ACCOUNTING ONLY: it
## reproduces the shell/LOD-sky ledger so the gate can PROVE the worst legal multi-body state (Earth dominant +
## Moon ring resident + impostors) stays under the 32 MB far-tier ceiling. Nothing scales with planet area,
## session length, or body count beyond the table.

# ---------------------------------------------------------------------------------------
# The tier ladder (ordered least → most detail). tier_raw/tier_hyst return only POINT/IMPOSTOR/RING (the
# far-tier selection this law owns); DENSE_CAP/SKIN/VOXEL are the dominant body's NEAR ladder (owned by the
# shell/seamless tiers) — present here for the byte ledger (§5) and M3, never returned by the selection law.
# ---------------------------------------------------------------------------------------
const POINT := 0
const IMPOSTOR := 1
const RING := 2
const DENSE_CAP := 3
const SKIN := 4
const VOXEL := 5

const TIER_NAMES := ["POINT", "IMPOSTOR", "RING", "DENSE_CAP", "SKIN", "VOXEL"]

static func tier_name(t: int) -> String:
	if t < 0 or t >= TIER_NAMES.size():
		return "?"
	return String(TIER_NAMES[t])

# ---------------------------------------------------------------------------------------
# Screen-space thresholds (device px, §2). P_POINT: a disc smaller than this is indistinguishable from a
# bright dot. TAU_POP: the impostor's tolerable silhouette error — at/above it the coarse ring's relief is
# visible and the body promotes. HYST: the ±25% hysteresis band (matches CosmosScale.RETIRE_HYST).
# ---------------------------------------------------------------------------------------
const P_POINT := 2.0
const TAU_POP := 1.0
const HYST := 0.25

# ---------------------------------------------------------------------------------------
# Per-body constants (M1 stand-in for O4c's BodyDescriptor fields §4.2). e_relief = max silhouette relief in
# blocks; facet_k = the body's faceting resolution K (ring facet count = 6·K²), chosen so facet edge ∈
# ~100–450 blocks (§3). Sun has no ring (impostor-only) ⇒ e_relief 0, no K. These migrate onto BodyDescriptor
# when O4c lands; the law reads them the same way (e_relief_of / facet_count).
# ---------------------------------------------------------------------------------------
const E_RELIEF := {"earth": 112.0, "moon": 64.0, "sun": 0.0}
const FACET_K := {"earth": 24, "moon": 14}      # 6·24²=3456 (Earth), 6·14²=1176 (Moon); §3 table

static func e_relief_of(body: String) -> float:
	return float(E_RELIEF.get(body, 0.0))

static func facet_k_of(body: String) -> int:
	return int(FACET_K.get(body, 0))

## Ring facet count 6·K² for `body` (0 if the body has no ring, e.g. the Sun).
static func facet_count(body: String) -> int:
	var k := facet_k_of(body)
	return 6 * k * k

# ---------------------------------------------------------------------------------------
# The angular-size primitives (§2). Pure math; small-angle (2r/d) matches the shipped impostor sizing.
# ---------------------------------------------------------------------------------------

## px per radian for a viewport `viewport_h_px` tall at vertical field-of-view `fov_rad`. The ONE knob the
## telescope (M4) turns: a narrow fov raises K_px, promoting distant bodies with no LOD-specific code.
static func k_px(viewport_h_px: float, fov_rad: float) -> float:
	var t := tan(fov_rad * 0.5)
	if t <= 0.0:
		return 0.0
	return viewport_h_px / (2.0 * t)

## The body's disc diameter in device px at camera distance d (blocks). 0 if d ≤ 0.
static func ang_px(r_body: float, d: float, kpx: float) -> float:
	if d <= 0.0:
		return 0.0
	return 2.0 * r_body / d * kpx

## The impostor's max silhouette error in device px at distance d — the coarse ring's relief projected to
## screen. 0 for a body with no relief (the Sun) ⇒ it never promotes past IMPOSTOR.
static func relief_px(e_relief: float, d: float, kpx: float) -> float:
	if d <= 0.0:
		return 0.0
	return e_relief / d * kpx

# ---------------------------------------------------------------------------------------
# The selection law (§2). tier_raw is the stateless law (no hysteresis); tier_hyst is the latched, anti-thrash
# form the driver actually uses — the caller passes the previously-latched tier and stores the result.
# ---------------------------------------------------------------------------------------

## The bare law: POINT (ang_px < P_POINT) → IMPOSTOR (relief_px < TAU_POP) → RING (relief_px ≥ TAU_POP).
## Caps at RING (the dominant near ladder owns deeper tiers). Used by the gate to certify the tier table.
static func tier_raw(r_body: float, e_relief: float, d: float, kpx: float) -> int:
	if ang_px(r_body, d, kpx) < P_POINT:
		return POINT
	if relief_px(e_relief, d, kpx) < TAU_POP:
		return IMPOSTOR
	return RING

## The latched form: PROMOTE at the nominal threshold, DEMOTE only once the driver drops HYST below it
## (one-sided-sticky ±25% band). `current` is the caller's previously-latched tier (POINT if none). Two
## independent boundaries — POINT⇄IMPOSTOR on ang_px vs P_POINT, IMPOSTOR⇄RING on relief_px vs TAU_POP —
## composed so a swap always fires at ≤ its threshold (the sub-pixel no-pop guarantee). Because ang_px and
## relief_px both scale as 1/d and ang_px/relief_px = 2r/e_relief ≫ 1, the two boundaries are far apart, so
## the POINT→RING skip never occurs in practice (well-separated regimes); the code is still correct if it does.
static func tier_hyst(current: int, r_body: float, e_relief: float, d: float, kpx: float) -> int:
	var ap := ang_px(r_body, d, kpx)
	var rp := relief_px(e_relief, d, kpx)
	# POINT ⇄ IMPOSTOR (driver: ang_px). Stay a disc until ang_px drops below P_POINT·(1−HYST).
	var disc: bool = (ap >= P_POINT * (1.0 - HYST)) if current >= IMPOSTOR else (ap >= P_POINT)
	if not disc:
		return POINT
	# IMPOSTOR ⇄ RING (driver: relief_px). Stay a ring until relief_px drops below TAU_POP·(1−HYST).
	var ring: bool = (rp >= TAU_POP * (1.0 - HYST)) if current >= RING else (rp >= TAU_POP)
	return RING if ring else IMPOSTOR

# ---------------------------------------------------------------------------------------
# No-pop bookkeeping (§2/§8, G-SSE-INV). The screen-space delta of a tier swap is the appearance difference
# it introduces: a POINT⇄IMPOSTOR swap shows/hides a disc (metric = ang_px, bounded by P_POINT because it
# fires there); an IMPOSTOR⇄RING swap adds/removes the ring's relief (metric = relief_px, bounded by TAU_POP).
# The gate asserts, over a synthetic approach, that every latched transition's delta ≤ its threshold — proving
# the handover is sub-pixel by the law that triggers it.
# ---------------------------------------------------------------------------------------

## The threshold (device px) governing the swap between two adjacent tiers.
static func swap_threshold(a_tier: int, b_tier: int) -> float:
	var lo := mini(a_tier, b_tier)
	var hi := maxi(a_tier, b_tier)
	if lo == POINT and hi == IMPOSTOR:
		return P_POINT
	if lo == IMPOSTOR and hi == RING:
		return TAU_POP
	# POINT⇄RING (a skip; should not occur — see tier_hyst): the coarser of the two bounds.
	return maxf(P_POINT, TAU_POP)

## The screen-space delta (device px) a swap between two tiers introduces AT distance d — see the header.
static func swap_delta_px(a_tier: int, b_tier: int, r_body: float, e_relief: float, d: float, kpx: float) -> float:
	var lo := mini(a_tier, b_tier)
	var hi := maxi(a_tier, b_tier)
	if lo == POINT and hi == IMPOSTOR:
		return ang_px(r_body, d, kpx)
	if lo == IMPOSTOR and hi == RING:
		return relief_px(e_relief, d, kpx)
	return maxf(ang_px(r_body, d, kpx), relief_px(e_relief, d, kpx))

## G-SSE-INV transition log line — `(body, from, to, d, relief_px)` per §2. The driver prints this whenever a
## body's latched tier changes; the gate emits it on synthetic approaches. Zero-alloc on the no-change path.
static func transition_log(body: String, from_tier: int, to_tier: int, d: float, rp: float) -> String:
	return "[G-SSE-INV] %s %s->%s  d=%.0f  relief_px=%.3f" % [body, tier_name(from_tier), tier_name(to_tier), d, rp]

# ---------------------------------------------------------------------------------------
# The NEVER-OOM byte ledger (§5). ACCOUNTING ONLY — no allocation happens here; these constants reproduce the
# shell (COSMOS-ORBITAL-SHELL §10) + LOD-sky ledger so the gate can prove the ceiling is STRUCTURAL. The
# per-facet ring costs are derived from Earth's shell totals (7.3 MB GPU + 2.77 MB CPU at 6·24²=3456 facets)
# so both Earth AND Moon (6·14²=1176) reproduce the doc's numbers from one constant each.
# ---------------------------------------------------------------------------------------
const _MB := 1048576.0

## Global far-tier ceiling (§5): 32 MB. The 128 MB voxel pool is SEPARATE and dominant-body-exclusive (not
## counted here). far_tier_bytes(...) worst legal state must sit under this.
const FAR_TIER_CEILING_BYTES := 32.0 * _MB

## Max resident per-body rings (§2/§5): dominant + the largest-relief_px non-dominant. A third body stays
## IMPOSTOR even zoomed (the stated v1 telescope limit) — this is what bounds the byte ledger under zoom.
const N_RING_MAX := 2

# Ring cost per facet (§3/§5): GPU tri-soup (40 B/vert, capped by the 96° emit) + CPU coarse cache
# (700 B/facet) + facet centres — derived from Earth's 3456-facet totals so the per-body number is exact.
const RING_GPU_BYTES_PER_FACET := (7.3 * _MB) / 3456.0     # ≈ 2213 B/facet
const RING_CPU_BYTES_PER_FACET := (2.77 * _MB) / 3456.0    # ≈ 840 B/facet (700 B coarse cache + centres)

const DENSE_CAP_BYTES := 4.2 * _MB      # ≤ 64 facets @ 16-cell: +3.7 MB mesh + 0.5 MB cache (§3, dominant-exclusive)
const SKIN_BYTES := 8.0 * _MB           # existing FP_SKIN_TIER ceiling (§3, dominant-exclusive)
const IMPOSTOR_BYTES := 50.0 * 1024.0   # 32×16 SphereMesh + material per table body (§3)
const POINT_BYTES := 0.0                # reused quad/dot, negligible (§3)
const ATMO_SHELL_BYTES := 0.1 * _MB     # SN4c limb shell (one sphere), reserved (§5)

## Bytes a body's resident RING costs at its facet count (0 for a ring-less body such as the Sun).
static func ring_bytes(body: String) -> float:
	var f := facet_count(body)
	if f <= 0:
		return 0.0
	return float(f) * (RING_GPU_BYTES_PER_FACET + RING_CPU_BYTES_PER_FACET)

## Bytes a single body's FAR-TIER residency costs given its presented tier + whether it is the dominant body.
## Impostor node bytes are counted for EVERY table body (the reused node persists even while a ring draws —
## make-before-break, §3). Ring bytes add once tier ≥ RING. Dense/skin add ONLY for the dominant body (the
## O4c pool-exclusive invariant). The 128 MB voxel pool is NOT part of the far-tier ceiling (separate).
static func body_far_tier_bytes(body: String, tier: int, is_dominant: bool) -> float:
	var total := IMPOSTOR_BYTES                       # every table body keeps its impostor node
	if tier >= RING:
		total += ring_bytes(body)
	if is_dominant:
		if tier >= DENSE_CAP:
			total += DENSE_CAP_BYTES
		if tier >= SKIN:
			total += SKIN_BYTES
	return total

## Total far-tier resident bytes for a multi-body state. `states` = Array of {body, tier, dominant}. Adds the
## reserved atmo-shell line once. The gate feeds the worst legal state (Earth dominant at ground with its full
## shell stack + Moon ring resident + Sun impostor) and asserts the sum ≤ FAR_TIER_CEILING_BYTES.
static func far_tier_bytes(states: Array) -> float:
	var total := ATMO_SHELL_BYTES
	for s in states:
		var body := String(s.get("body", ""))
		var tier := int(s.get("tier", IMPOSTOR))
		var dom := bool(s.get("dominant", false))
		total += body_far_tier_bytes(body, tier, dom)
	return total

# ---------------------------------------------------------------------------------------
# N_RING_MAX enforcement (§2/§5). When more bodies than N_RING_MAX would present a RING (e.g. a telescope zoom
# promotes several at once), only N_RING_MAX rings may be RESIDENT: the dominant body always, then the highest
# relief_px non-dominant bodies. The rest are clamped back to IMPOSTOR (the stated v1 limit). This is the rule
# that makes the byte ceiling hold under an arbitrary zoom sweep.
# ---------------------------------------------------------------------------------------

## Choose which of `wants_ring` (bodies whose law says tier ≥ RING) actually get a resident ring, ≤ N_RING_MAX.
## `relief` maps body → relief_px (the LRU-by-relief_px key). `dominant` is always granted a ring if it wants
## one. Returns the granted bodies (order: dominant first, then descending relief_px).
static func select_ring_bodies(wants_ring: Array, relief: Dictionary, dominant: String) -> Array:
	var chosen: Array = []
	if dominant in wants_ring:
		chosen.append(dominant)
	var rest: Array = []
	for b in wants_ring:
		if String(b) != dominant:
			rest.append(b)
	rest.sort_custom(func(a, c): return float(relief.get(a, 0.0)) > float(relief.get(c, 0.0)))
	for b in rest:
		if chosen.size() >= N_RING_MAX:
			break
		chosen.append(b)
	return chosen

## The tier a body actually PRESENTS after N_RING_MAX arbitration: its law tier, but clamped to IMPOSTOR if the
## law wants a ring the budget cannot grant. `granted` is the output of select_ring_bodies.
static func present_tier(body: String, law_tier: int, granted: Array) -> int:
	if law_tier >= RING and not (body in granted):
		return IMPOSTOR
	return law_tier
