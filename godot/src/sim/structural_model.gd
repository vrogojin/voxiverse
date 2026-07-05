class_name StructuralModel
extends RefCounted
## Static, pure structural capacity model (STRUCTURAL-INTEGRITY §2/§4). The single
## place the per-material node strengths (σ_c, σ_t, σ_s, M₀) and per-joint
## capacities (F_t, F_s, M₀) are computed — the solver and any future UI read
## through here. NOTHING is stored: every capacity derives from the material's
## `strength_anchors (P,H,D)` + `mass` in BlockCatalog (the single source of truth,
## SI §2 / INTEGRATION-DECISIONS §1.1).
##
## INTEGER-NEWTON DOMAIN (SI §5.4/§8): everything is kept in ONE consistent integer
## domain keyed on `w_int = round(m·g)`. Node capacities are integer multiples of
## `w_int` (σ_c = P·w_int, …) and cell weights are the same `w_int`, so a pillar of
## P binds EXACTLY (both sides are multiples of the same integer) — there is no
## float-epsilon flakiness at "exactly at capacity", and the Dinic max-flow the
## solver runs is deterministic across float paths. The temperature factor φ (=1
## across the entire current world, SI §4.1) and the contact-area factor (=1 for
## full cubes, SI §4.3) only perturb this once future content leaves the plateau.

const G := 9.81
## Neighbour-bracing coefficient (SI §3): σ_c_eff = σ_c·(1 + β·N_lat).
const BRACE_BETA := 0.75
## Attachment temperature floor (SI §4.1): heat never takes φ fully to 0 (melting/
## charring is the state machine's job, not the structural model's).
const PHI_MIN := 0.05
## "Infinite" integer capacity for confined bulk / compression edges (fits int64;
## the min-cut can never select it because it never saturates).
const INF_CAP := 1 << 50

# --- per-material node capacities (integer-Newton) ------------------------------

## Integer per-voxel weight w = round(m·g). The shared unit of the whole domain.
static func weight_int(id: int) -> int:
	return roundi(BlockCatalog.mass_of(id) * G)

## Compressive node capacity σ_c = P·m·g (max weight routed THROUGH the cell before
## it crushes). P is anchors.x.
static func sigma_c(id: int) -> int:
	return BlockCatalog.anchors_of(id).x * weight_int(id)

## Tensile joint strength σ_t = D·m·g (a joint pulled apart along its normal). D is
## anchors.z.
static func sigma_t(id: int) -> int:
	return BlockCatalog.anchors_of(id).z * weight_int(id)

## Shear joint strength σ_s = H·m·g (a joint loaded across its plane). H is anchors.y.
static func sigma_s(id: int) -> int:
	return BlockCatalog.anchors_of(id).y * weight_int(id)

## Joint face moment capacity M₀ = σ_s·H/2 (SI §2.1) — derived from σ_s, not a free
## parameter. Kept in the same integer domain (odd H·σ_s rounds down, negligible).
static func moment0(id: int) -> int:
	return sigma_s(id) * BlockCatalog.anchors_of(id).y / 2

## Braced compressive capacity for a node with `n_lat` column-supported lateral
## neighbours (SI §3). Isolated pillar cell → ×1 (anchors calibrate unbraced).
static func braced_sigma_c(id: int, n_lat: int) -> int:
	return int(round(float(sigma_c(id)) * (1.0 + BRACE_BETA * float(n_lat))))

# --- temperature factor φ(T) (SI §4.1) ------------------------------------------

## Per-class φ parameters: [φ_frost, T_frost_full, T_cold_on, T_hot_on, T_fail] (°C).
## The plateau [cold_on, hot_on] maps to φ = 1 and — for every class — covers the
## entire current world (air 21.5 °C, surface 23 °C, deep 12 °C all sit inside it),
## so the anchor numbers hold EVERYWHERE today; temperature only bites once future
## content pushes T out of the band. Brittle (ice) is the sole class that weakens as
## it warms toward 0 °C (melting): φ = 1 below −5 °C, ramping to φ_min at 0 °C.
static func _phi_params(sclass: StringName) -> Array:
	match sclass:
		&"soil":    return [3.0, -10.0, 0.0, 150.0, 800.0]
		&"rock":    return [1.0, -10.0, 0.0, 600.0, 1200.0]
		&"timber":  return [1.05, -10.0, 0.0, 100.0, 300.0]
		&"foliage": return [1.2, -10.0, 0.0, 50.0, 150.0]
		&"metal":   return [1.0, -10.0, 0.0, 400.0, 1200.0]
		&"soft":    return [1.2, -10.0, 0.0, 50.0, 150.0]     # snow: foliage-like
		&"brittle": return [1.0, -5.0, -5.0, -5.0, 0.0]       # ice melt curve
		_:          return [1.0, -10.0, 0.0, 600.0, 1200.0]   # default rock-like

## Attachment temperature factor at joint temperature `T` for structural class
## `sclass`. Multiplies σ_t, σ_s and M₀ (M₀ scales once, with σ_s). σ_c is
## temperature-independent in v1.
static func phi(T: float, sclass: StringName) -> float:
	var p := _phi_params(sclass)
	var frost: float = p[0]
	var frost_full: float = p[1]
	var cold_on: float = p[2]
	var hot_on: float = p[3]
	var fail: float = p[4]
	if T <= frost_full:
		return frost
	if T < cold_on:
		return 1.0 + (frost - 1.0) * (cold_on - T) / (cold_on - frost_full)
	if T <= hot_on:
		return 1.0                                            # the plateau
	return maxf(PHI_MIN, 1.0 - (T - hot_on) / (fail - hot_on))

# --- reinforcement table (SI §4.2) ----------------------------------------------

## Per-reinforcement parameters keyed by id: [k_mult, R_t (N), R_s (N), T_fail_R (°C)].
## id 0 = none. Additive R terms are material-independent (a glue line's strength
## doesn't care what it glues); k_mult amplifies the AVERAGED base term.
static func _reinf(reinf_id: int) -> Array:
	match reinf_id:
		1: return [1.0, 10000.0, 10000.0, 90.0]    # glue
		2: return [1.0, 40000.0, 40000.0, 500.0]   # cement
		3: return [2.0, 0.0, 0.0, 800.0]           # weld (metal-only in authoring)
		4: return [1.5, 15000.0, 15000.0, 600.0]   # rebar spike
		_: return [1.0, 0.0, 0.0, INF]             # none

## Reinforcement heat ramp φ_R: linear 1 → 0 over [T_fail_R − 50, T_fail_R], so glue
## softens long before the glued material does.
static func _phi_r(T: float, t_fail_r: float) -> float:
	if T <= t_fail_r - 50.0:
		return 1.0
	if T >= t_fail_r:
		return 0.0
	return (t_fail_r - T) / 50.0

# --- joint capacities (SI §4) ---------------------------------------------------
# F_t/F_s/M₀ use the arithmetic-mean-of-the-two-materials rule with each side's φ
# applied BEFORE averaging, times the participation product att_A·att_B (which
# NEVER multiplies the compression path — that is the node's σ_c), times the
# contact-area factor `a` (a for forces, a^(3/2) for moment), plus reinforcement.
# Same-material, plateau, full-cube, unreinforced ⇒ the material value exactly, so
# the §2 calibration is untouched. Returned rounded to int (integer-Newton flow).

static func _attach(id: int) -> float:
	var s := BlockCatalog.state_of(id)
	return s.attachment if s != null else 0.0

## Tensile joint capacity F_t (N), integer.
static func joint_ft(id_a: int, id_b: int, T: float = 21.5, reinf_id: int = 0, area: float = 1.0) -> int:
	var r := _reinf(reinf_id)
	var phi_a := phi(T, BlockCatalog.class_of(id_a))
	var phi_b := phi(T, BlockCatalog.class_of(id_b))
	var base: float = 0.5 * (float(sigma_t(id_a)) * phi_a + float(sigma_t(id_b)) * phi_b) * float(r[0])
	var reinf: float = float(r[1]) * _phi_r(T, float(r[3]))
	var cap := area * _attach(id_a) * _attach(id_b) * (base + reinf)
	return int(round(cap))

## Shear joint capacity F_s (N), integer.
static func joint_fs(id_a: int, id_b: int, T: float = 21.5, reinf_id: int = 0, area: float = 1.0) -> int:
	var r := _reinf(reinf_id)
	var phi_a := phi(T, BlockCatalog.class_of(id_a))
	var phi_b := phi(T, BlockCatalog.class_of(id_b))
	var base: float = 0.5 * (float(sigma_s(id_a)) * phi_a + float(sigma_s(id_b)) * phi_b) * float(r[0])
	var reinf: float = float(r[2]) * _phi_r(T, float(r[3]))
	var cap := area * _attach(id_a) * _attach(id_b) * (base + reinf)
	return int(round(cap))

## Joint moment capacity M₀ (N·m), integer. Section modulus scales a^(3/2).
static func joint_m0(id_a: int, id_b: int, T: float = 21.5, reinf_id: int = 0, area: float = 1.0) -> int:
	var r := _reinf(reinf_id)
	var phi_a := phi(T, BlockCatalog.class_of(id_a))
	var phi_b := phi(T, BlockCatalog.class_of(id_b))
	var base: float = 0.5 * (float(moment0(id_a)) * phi_a + float(moment0(id_b)) * phi_b) * float(r[0])
	var reinf: float = float(r[2]) * _phi_r(T, float(r[3])) * 0.5
	var cap := pow(area, 1.5) * _attach(id_a) * _attach(id_b) * (base + reinf)
	return int(round(cap))
