class_name AnchorConverter
extends RefCounted
## Offline authoring tool: proposes structural strength anchors `(P, H, D)` from a
## material's physical priors + `structural_class` (INTEGRATION-DECISIONS §1.2
## stress branch, §1.3 soil/cohesion branch). Pure/static — NOT wired into runtime
## meshing or physics; it feeds the `blocks.json` authoring source and the
## `verify_feature.gd` drift gate, which pins `propose_anchors(priors,class) ==
## stored strength_anchors` for every non-overridden record so priors and anchors
## can never silently diverge.
##
## The returned Vector3i packs the anchors as (x=P pillar, y=H shelf, z=D dangle),
## matching VoxelState.strength_anchors. The solver (P4) derives σ_c=P·m·g,
## σ_s=H·m·g, σ_t=D·m·g, M₀=σ_s·H/2 from the ROUNDED ints stored here.

## Pinned constants — each βe is fixed by two calibration anchors (see §1.2):
##   βc = log₂(16/9): stone (C=100→P=64) & wood (C=50→P=36) ⇒ 64·½^βc = 36.
##   βt = log₃(2):    stone (T=10→D=4)  & wood (T=90→D=16)  ⇒ 4·9^βt  = 16.
const BETA_C := 0.830075          # log2(16.0/9.0)
const BETA_T := 0.630930          # log(2.0)/log(3.0)
const K_S := 1.5                  # shear:tension geometric ratio (H = k_s·D)
const KAPPA_BRITTLE := 1.0 / 3.0  # flaw-governed design strength for glass/ice
const P_REF_C := 100.0            # reference compressive strength, MPa
const D_REF_T := 10.0             # reference tensile strength, MPa
const P_BASE := 64.0              # stone's pillar anchor (κ=1, C=C_ref)
const D_BASE := 4.0               # stone's dangle anchor (T=T_ref)
const T_MIN := 0.05               # MPa: below this, D is not floored to ≥1
const SOIL_C_REF := 25.0          # kPa: dirt's cohesion anchor
const GRANULAR_C_MAX := 5.0       # kPa: below this a soil is cohesionless

## Round half-up: floori(x + 0.5). LOAD-BEARING — dirt's H exists only because
## 1.5 rounds up to 2 (INTEGRATION-DECISIONS §1.2/§1.5 risk 1). For the strictly
## positive anchor domain this equals GDScript's `roundi`, but the +0.5 form is
## the normative definition the drift gate pins.
static func _round_half_up(x: float) -> int:
	return floori(x + 0.5)

## κ_class multiplier on the compressive branch: ⅓ for brittle (flaw-governed),
## 1.0 for every other stress-governed class.
static func _kappa(structural_class: StringName) -> float:
	return KAPPA_BRITTLE if structural_class == &"brittle" else 1.0

## Propose the anchor triple (P, H, D) for a material. `priors` carries the
## stress inputs `C`/`T` (MPa) or the soil input `cohesion` (kPa); `structural_class`
## selects the branch (NEVER input magnitude — §1.3). Reproduces the §2.4 core
## calibration exactly: stone→(64,6,4), wood→(36,24,16), dirt→(4,2,1),
## grass→(4,2,1), leaf→(4,3,2).
static func propose_anchors(priors: Dictionary, structural_class: StringName) -> Vector3i:
	match structural_class:
		&"soil":
			return _soil_branch(float(priors.get("cohesion", 0.0)))
		&"granular":
			# Cohesionless: falling sand — never hangs (D=0), inert shear (H=1),
			# crushes at P=3; participation 0.0 (attachment) closes the mixed-joint
			# hole (§1.3). Class-keyed, not magnitude-keyed.
			return Vector3i(3, 1, 0)
		&"foliage":
			# No meaningful priors; the SI §2.4 foliage archetype (leaf, moss),
			# obeys k_s (H=3=round(1.5·2)). Hand-authored, reproduced here.
			return Vector3i(4, 3, 2)
		&"bedrock", &"fluid":
			# Sentinel classes: no anchors (∞ caps / outside the solver).
			return Vector3i.ZERO
		_:
			# rock / timber / brittle / metal / soft: the stress branch.
			return _stress_branch(
				float(priors.get("C", 0.0)),
				float(priors.get("T", 0.0)),
				structural_class)

## Stress branch: power laws in compressive C and tensile T (MPa). §1.2.
static func _stress_branch(c_mpa: float, t_mpa: float, structural_class: StringName) -> Vector3i:
	var p_hat := _kappa(structural_class) * P_BASE * pow(c_mpa / P_REF_C, BETA_C)
	var d_hat := D_BASE * pow(t_mpa / D_REF_T, BETA_T)
	var h_hat := K_S * d_hat
	var p := maxi(1, _round_half_up(p_hat))
	var d := _round_half_up(d_hat)
	if t_mpa >= T_MIN:
		d = maxi(1, d)
	var h := maxi(d, maxi(_round_half_up(h_hat), 1))
	return Vector3i(p, h, d)

## Soil/cohesion branch: laws in cohesion c (kPa). §1.3. Cohesionless soils
## (c < 5 kPa) are the granular family — route them through &"granular" (they
## are class-keyed there); here a soil is assumed cohesive and floored ≥1.
static func _soil_branch(c_kpa: float) -> Vector3i:
	if c_kpa < GRANULAR_C_MAX:
		# Defensive: a `soil`-classed record with negligible cohesion. Treat as
		# granular so a mis-classed row degrades sensibly rather than to (0,0,0).
		return Vector3i(3, 1, 0)
	var ratio := sqrt(c_kpa / SOIL_C_REF)
	var p := maxi(1, _round_half_up(4.0 * ratio))
	var d := maxi(1, _round_half_up(ratio))
	var h := maxi(1, _round_half_up(K_S * ratio))
	return Vector3i(p, h, d)
