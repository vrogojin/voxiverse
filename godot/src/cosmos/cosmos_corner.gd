class_name CosmosCorner
extends RefCounted
## COSMOS M5c (docs/COSMOS-M5C-CORNER.md §1/§5/§6) — the pure corner-seal kernel: chart-free statics on the
## CONTINUOUS RAW home-face frame (never on window (x,z) directly — M_win rotates the window, and that is the
## #1 place to write the frame-rotation bug). WorldManager does the window↔raw conversion at the boundary
## (chart.raw_of_f / window_of_f) and passes raw coords + n in here. No state, no allocation beyond the small
## return dictionaries; deterministic; safe from any thread.
##
## Frame: nearest cube vertex is the raw corner (ci, cj) ∈ {0,n}²; σ_i = +1 if ci==0 else −1 makes the home
## face ALWAYS the (+,+) quadrant of the canonical offset u′ = (σ_i·(px−ci), σ_j·(pz−cj)). Band angle
## φ = wrap[0,360)(atan2(u′.y,u′.x)+90): J-strip (0,90), home (90,180), I-strip (180,270), wedge (270,360).
## φ=0 and φ=270 are two window images of the SAME physical line (the true B–C edge); [0,270] is the
## unrolled 270° cone of reality, the wedge its 90° of window excess.

const R_B := float(CubeSphere.CORNER_LOCK_R)   # 8 — anomaly trigger radius (raw cells, Euclidean)
const R_X := R_B + 0.5                          # 8.5 — teleport exit radius (> R_B so no same-frame retrigger)
const EPS_PHI := 4.0                            # deg — seam-ray exit clamp (§13.3): an exact 0/270 exit lands
                                                # on a face-boundary plane and classifies double-out at n-corners

## Nearest cube-vertex raw corner to continuous raw (px,pz), packed as Vector4(ci, cj, σ_i, σ_j). Unambiguous
## everywhere M5c operates (reach ≪ n/2).
static func nearest_corner(px: float, pz: float, n: int) -> Vector4:
	var half := 0.5 * float(n)
	var ci := 0.0 if px < half else float(n)
	var cj := 0.0 if pz < half else float(n)
	return Vector4(ci, cj, 1.0 if ci == 0.0 else -1.0, 1.0 if cj == 0.0 else -1.0)

## Corner-canonical offset u′ = (σ_i·(px−ci), σ_j·(pz−cj)) for the packed corner c.
static func uprime_of(px: float, pz: float, c: Vector4) -> Vector2:
	return Vector2(c.z * (px - c.x), c.w * (pz - c.y))

## Euclidean raw distance from (px,pz) to the nearest vertex (f64 scalars — no Vector2 truncation).
static func corner_dist(px: float, pz: float, c: Vector4) -> float:
	var dx := px - c.x
	var dz := pz - c.y
	return sqrt(dx * dx + dz * dz)

## Band angle φ ∈ [0,360) of a canonical offset u′ (Vector2 helper — for the algebra gate; the hot path
## below computes φ in f64 scalars via phi_raw so nothing round-trips through f32 near the n-corner).
static func phi_of_uprime(u: Vector2) -> float:
	return fposmod(rad_to_deg(atan2(u.y, u.x)) + 90.0, 360.0)

## Band angle φ of raw (px,pz) about corner c, computed entirely in f64 (σ applied to the f64 offset).
static func phi_raw(px: float, pz: float, c: Vector4) -> float:
	var ux := c.z * (px - c.x)
	var uy := c.w * (pz - c.y)
	return fposmod(rad_to_deg(atan2(uy, ux)) + 90.0, 360.0)

## True iff (px,pz) is inside the full-height anomaly cylinder (corner distance < R_B).
static func in_anomaly(px: float, pz: float, n: int) -> bool:
	return corner_dist(px, pz, nearest_corner(px, pz, n)) < R_B

## The §5.2 bisector teleport, RAW → RAW. Returns everything the (chart-owning) caller needs to finish the
## window mapping + outward radial: px/py (SCALAR f64 raw exit — NOT a Vector2, whose f32 storage would lose
## ~1e-3 cells at the n≈10016 corner), beta (β_out radians), si/sj (σ), and phi_in/out. The outward-radial
## direction, in raw, is (σ_i·cos β, σ_j·sin β) — the caller maps p_out and p_out+that through window_of_f
## and differences them (routes the direction through the SAME σ/M_win pipeline; nothing hand-rotated).
static func teleport_raw(px: float, pz: float, n: int) -> Dictionary:
	var c := nearest_corner(px, pz, n)
	var phi_in := phi_raw(px, pz, c)
	var phi_out := clampf(fposmod(phi_in + 135.0, 270.0), EPS_PHI, 270.0 - EPS_PHI)
	var beta := deg_to_rad(phi_out - 90.0)
	var uox := R_X * cos(beta)
	var uoy := R_X * sin(beta)
	return {
		"px": c.x + c.z * uox, "py": c.y + c.w * uoy,
		"beta": beta, "si": c.z, "sj": c.w, "phi_in": phi_in, "phi_out": phi_out,
	}

## The §6 universal seam GLUE, RAW → RAW. For an entity whose column is double-out (wedge, φ∈(270,360)):
## the exact ±90° deck transformation identifying the two B–C seam rays. 315° splits the (measure-zero)
## deep-wedge ambiguity by nearest seam. Returns p_new (Vector2 raw) + si/sj so the caller maps it back.
static func glue_raw(px: float, pz: float, n: int) -> Dictionary:
	var c := nearest_corner(px, pz, n)
	var ux := c.z * (px - c.x)      # f64 u′ components
	var uy := c.w * (pz - c.y)
	var phi := fposmod(rad_to_deg(atan2(uy, ux)) + 90.0, 360.0)
	var unx: float
	var uny: float
	if phi >= 315.0:
		unx = uy; uny = -ux         # −90°: φ → φ−90 ∈ (225,270) → I-strip (face B)
	else:
		unx = -uy; uny = ux         # +90°: φ → φ+90 (mod 360) ∈ (0,45] → J-strip (face C)
	# px/py are SCALAR f64 (a Vector2 would truncate to f32 at the n≈10016 corner):
	return {"px": c.x + c.z * unx, "py": c.y + c.w * uny, "si": c.z, "sj": c.w}
