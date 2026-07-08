class_name PortalMath
extends RefCounted
## Pure/static portal math (PORTALS §3.5.1–3.5.3): the source→destination isometry and
## the off-axis "window" frustum (Kooima's generalized perspective projection) whose near
## plane IS the destination portal opening. No stencil, no oblique clip — plain
## projection-matrix state the GL Compatibility renderer fully supports.
##
## The whole technical risk of the chosen approach lives here and is retired by the
## headless NDC-corner reprojection assert in verify (_test_portal_math): the four
## destination interior corners must project to the NDC rectangle corners (±1, ±1).

## Minimum near distance — clamps the last-centimetre degeneracy as the eye approaches
## the source plane (the image is briefly imperfect there, masked by the opening filling
## the screen and by teleport when enabled).
const NEAR_MIN := 0.01

## The source→destination isometry T_SD (PORTALS §3.5.1). Entering S's front exits D's
## front: R = 180° about local up. Pure yaw + translation (frames are axis-aligned), so
## T_SD·T_DS == identity and up is preserved.
static func isometry(s: PortalFrame, d: PortalFrame) -> Transform3D:
	var r := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	return d.global_transform() * r * s.global_transform().affine_inverse()

## The window-frustum camera parameters for rendering source frame S's portal (which
## shows destination frame D), given the player camera origin `eye` and the far plane
## `far`. Returns a Dictionary:
##   transform : Transform3D — virtual camera pose (position = T_SD·eye; basis perpendicular
##               to D's plane, NOT tracking the player's look — only the eye position and
##               near/offset update per frame).
##   near, offset, size, aspect : the PROJECTION_FRUSTUM parameters (size = D height in
##               metres; aspect = W/H; near = ⊥ distance eye→D-plane; offset positions the
##               window rectangle so the near plane == the destination opening).
##   flip_u    : bool — the per-side horizontal UV flip (§3.5.3), from the REAL eye's side
##               of S (not the virtual eye).
##   side      : +1/-1 — which side of D the virtual eye landed on.
static func window_camera(eye: Vector3, s: PortalFrame, d: PortalFrame, far: float) -> Dictionary:
	var t := isometry(s, d)
	var eye2 := t * eye                                   # virtual eye E'
	var dtx := d.global_transform()
	var n_d := dtx.basis.z                               # destination plane normal
	var up := dtx.basis.y                               # +Y
	var d_org := dtx.origin
	var to_eye := eye2 - d_org
	var side := 1.0 if to_eye.dot(n_d) >= 0.0 else -1.0
	var z_cam := n_d * side                              # camera backward (looks toward/through the window)
	var x_cam := up.cross(z_cam)                         # right-handed: X = Y × Z (== side · D.basis.x)
	var cam_xf := Transform3D(Basis(x_cam, up, z_cam), eye2)
	var near := maxf(to_eye.dot(z_cam), NEAR_MIN)        # ⊥ eye→plane distance (clamped)
	var rel := d_org - eye2
	var offset := Vector2(rel.dot(x_cam), rel.dot(up))   # window centre projected onto the camera plane
	var size := float(d.height)
	var aspect := float(d.width) / float(d.height)
	# U-flip: horizontal correspondence mirrors when the player is on S's BACK (§3.5.3).
	var stx := s.global_transform()
	var sigma := (eye - stx.origin).dot(stx.basis.z)
	return {
		"transform": cam_xf, "near": near, "offset": offset, "size": size,
		"aspect": aspect, "flip_u": sigma < 0.0, "side": side,
	}

## The four WORLD-space corners of a frame's interior opening (centre ± half-width along
## right, ± half-height along up). Used by the verify NDC-corner reprojection assert and
## (later) any window-bounds work.
static func opening_corners(f: PortalFrame) -> Array:
	var tx := f.global_transform()
	var hw := float(f.width) * 0.5
	var hh := float(f.height) * 0.5
	var out := []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			out.append(tx * Vector3(sx * hw, sy * hh, 0.0))
	return out
