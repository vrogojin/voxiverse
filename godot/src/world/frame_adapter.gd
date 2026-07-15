class_name FrameAdapter
extends RefCounted
## COSMOS FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §2.1 "the bridge", RESOLVED decision 3) — the
## coordinate-frame adapter every global↔ActiveFrame-local conversion routes through. It owns nothing but a
## reference to the ActiveFrame Node3D (the play frame @ T_active); gameplay math runs in the ActiveFrame's
## LOCAL (facet-lattice) frame, and the physics server + renderer consume PLANET-ABSOLUTE globals, so the two
## must be bridged at exactly the enumerated physics-boundary sites in player.gd + voxel_body.gd (§2.3).
##
## PHASE 1 CONTRACT (byte-identity): the adapter is a numeric NO-OP whenever the frame is either
##   • disabled  (FP_FIXED_FRAME off  ⇒ `_frame == null`)                — returns every input verbatim, or
##   • @ identity (Phase 1: ActiveFrame is pinned at Transform3D.IDENTITY) — Transform3D.IDENTITY·x == x exactly
##     (multiply by 1.0, add 0.0 — no rounding), so every map returns its input to the bit.
## Phase 2 flips ActiveFrame to the active facet's transform; the SAME adapter then does the real rotate/translate
## with ZERO call-site churn — that pivot is the whole reason this is a full adapter, not scattered renames.
##
## Naming: `l2g_*` map ActiveFrame-LOCAL (lattice) → GLOBAL (absolute); `g2l_*` map the reverse.

## The ActiveFrame node whose transform bridges local↔global. `null` ⇒ the frame is disabled (flag off) and
## every method is the strict identity. Set once via setup() at WorldManager wiring; never reassigned.
var _frame: Node3D = null

## Wire the adapter to its ActiveFrame node (or null to leave it disabled/transparent). `enabled` mirrors this.
func setup(active_frame: Node3D) -> void:
	_frame = active_frame

## True when an ActiveFrame is installed (FP_FIXED_FRAME on). Even then, in Phase 1 the frame is @ identity so
## every map below is still a numeric no-op — `enabled` is about STRUCTURE (is there a frame), not about numerics.
func enabled() -> bool:
	return _frame != null

# --- raw frame accessors (the transform the maps are built from) --------------------------------------------

## The LOCAL→GLOBAL transform (ActiveFrame's transform). Identity when disabled or in Phase 1.
func xform() -> Transform3D:
	return _frame.transform if _frame != null else Transform3D.IDENTITY

## The rotational part only (ActiveFrame's basis) — for direction/gravity mapping. Identity when disabled/Phase 1.
func basis() -> Basis:
	return _frame.transform.basis if _frame != null else Basis.IDENTITY

## The active facet's up axis expressed in GLOBAL coords (= basis().y) — the rigid-body gravity direction target
## for Phase 2's `PhysicsServer3D.area_set_param(...GRAVITY_VECTOR, -up())`. Vector3.UP when disabled/Phase 1.
func up() -> Vector3:
	return _frame.transform.basis.y if _frame != null else Vector3.UP

# --- point maps (translation + rotation) --------------------------------------------------------------------

## ActiveFrame-LOCAL point → GLOBAL point (T·p). No-op when disabled/Phase 1.
func l2g_point(p: Vector3) -> Vector3:
	return (_frame.transform * p) if _frame != null else p

## GLOBAL point → ActiveFrame-LOCAL point (T⁻¹·p). No-op when disabled/Phase 1.
func g2l_point(p: Vector3) -> Vector3:
	return (_frame.transform.affine_inverse() * p) if _frame != null else p

# --- direction maps (rotation only — no translation) --------------------------------------------------------

## ActiveFrame-LOCAL direction → GLOBAL direction (B·d). No-op when disabled/Phase 1.
func l2g_dir(d: Vector3) -> Vector3:
	return (_frame.transform.basis * d) if _frame != null else d

## GLOBAL direction → ActiveFrame-LOCAL direction (B⁻¹·d). No-op when disabled/Phase 1.
func g2l_dir(d: Vector3) -> Vector3:
	return (_frame.transform.basis.inverse() * d) if _frame != null else d

# --- transform maps (whole poses — carry basis + origin) ----------------------------------------------------

## ActiveFrame-LOCAL transform → GLOBAL transform (T·t). No-op when disabled/Phase 1.
func l2g_xform(t: Transform3D) -> Transform3D:
	return (_frame.transform * t) if _frame != null else t

## GLOBAL transform → ActiveFrame-LOCAL transform (T⁻¹·t). No-op when disabled/Phase 1.
func g2l_xform(t: Transform3D) -> Transform3D:
	return (_frame.transform.affine_inverse() * t) if _frame != null else t
