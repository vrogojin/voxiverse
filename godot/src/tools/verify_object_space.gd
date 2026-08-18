extends SceneTree
## COSMOS-OBJECT-LOD P3 gate (FP_OBJ_LOD_SPACE). Certifies the PURE P3 beacon law (ObjectLod) that the far tier
## (FacetFarObjects) consumes behind the flag — all pure math, so it runs FLAT regardless of the flag state:
##   - CLASS_SPACE never-cull: draw=true even below CULL_DEBRIS_PX (0.5 px), clamped to the P_POINT (2 px) beacon.
##   - beacon brightness ∝ p² (flux-conserving sub-pixel emitter), saturating at P_POINT.
##   - ray-sphere planet occlusion (must-fix #4): a synthetic object BEHIND the body sphere ⇒ occluded; the same
##     object moved IN FRONT of the body (or off its disc) ⇒ visible.
##   - clamped-distance placement preserves the projected px (2·hs/d_place·kpx == screen_px) AND caps the placement
##     distance to BEACON_CLAMP_DIST while leaving nearer objects at their true distance.
## Run: godot --headless --path godot --script res://src/tools/verify_object_space.gd

var _fail := 0
var _pass := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else: _fail += 1; push_error("FAIL: " + m); print("  FAIL: ", m)
func _near(a: float, b: float, m: String, eps := 0.001) -> void:
	_ok(absf(a - b) <= eps, "%s (got %f, want %f)" % [m, a, b])

const K := 771.3            # k_px(1080, 70°) reference (matches the P0/P1 gates)

func _initialize() -> void:
	_test_never_cull()
	_test_beacon_brightness()
	_test_occlusion()
	_test_clamped_placement()
	print("==== VERIFY-OBJECT-SPACE: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _test_never_cull() -> void:
	# CLASS_SPACE is NEVER hard-culled: draw stays true and the dot clamps to P_POINT even far below the debris
	# cull floor. CLASS_DEBRIS at the same sub-0.5 px size is fully culled (draw=false) — the classes diverge.
	for p in [1.5, 0.5, 0.1, 0.001]:
		var s := ObjectLod.cull(ObjectLod.CLASS_SPACE, p)
		_ok(bool(s["draw"]), "space: draw=true at p=%f (never hard-culled)" % p)
		_near(float(s["dot_px"]), ObjectLod.P_POINT, "space: dot clamped to P_POINT at p=%f" % p)
		_near(float(s["fade"]), 1.0, "space: fade stays 1.0 at p=%f" % p)
	_ok(not bool(ObjectLod.cull(ObjectLod.CLASS_DEBRIS, 0.4)["draw"]), "debris: culled below 0.5 px (class divergence)")
	# at/above P_POINT both classes just draw at true size.
	var big := ObjectLod.cull(ObjectLod.CLASS_SPACE, 5.0)
	_ok(bool(big["draw"]) and absf(float(big["dot_px"]) - 5.0) < 0.001, "space: p≥P_POINT draws at true size")

func _test_beacon_brightness() -> void:
	# Flux-conserving p² falloff normalised to 1.0 at the P_POINT floor; monotone; never above 1.
	_near(ObjectLod.beacon_brightness(2.0), 1.0, "brightness saturates at P_POINT")
	_near(ObjectLod.beacon_brightness(1.0), 0.25, "brightness ∝ p² (p=1 → 0.25)")
	_near(ObjectLod.beacon_brightness(0.5), 0.0625, "brightness ∝ p² (p=0.5 → 0.0625)")
	_ok(ObjectLod.beacon_brightness(4.0) == 1.0, "brightness never exceeds 1.0 above P_POINT")
	_ok(ObjectLod.beacon_brightness(1.5) > ObjectLod.beacon_brightness(0.75), "brightness monotone in p")

func _test_occlusion() -> void:
	# Body sphere: centre (0,0,1000), radius 300. Eye at the origin looks down +Z.
	var eye := Vector3.ZERO
	var bc := Vector3(0.0, 0.0, 1000.0)
	var br := 300.0
	# (a) Object directly BEHIND the body (farther along +Z, within the disc) ⇒ occluded.
	_ok(ObjectLod.beacon_occluded(eye, Vector3(0.0, 0.0, 5000.0), bc, br), "occlusion: object behind the body is occluded")
	# (b) Same direction but IN FRONT of the near limb (closer than the sphere) ⇒ visible.
	_ok(not ObjectLod.beacon_occluded(eye, Vector3(0.0, 0.0, 500.0), bc, br), "occlusion: object in front of the body is visible")
	# (c) Object far off to the side (well outside the body's angular disc) ⇒ visible even though it is farther away.
	_ok(not ObjectLod.beacon_occluded(eye, Vector3(4000.0, 0.0, 5000.0), bc, br), "occlusion: object clear of the disc is visible")
	# (d) Just grazing outside the limb (offset ≈ ang_radius) ⇒ visible; just inside ⇒ occluded. ang_radius=asin(300/1000).
	var ang := asin(300.0 / 1000.0)
	var far_z := 5000.0
	var inside := tan(ang * 0.85) * far_z      # a lateral offset inside the disc at that depth
	var outside := tan(ang * 1.15) * far_z     # outside the disc
	_ok(ObjectLod.beacon_occluded(eye, Vector3(inside, 0.0, far_z), bc, br), "occlusion: inside the disc + behind ⇒ occluded")
	_ok(not ObjectLod.beacon_occluded(eye, Vector3(outside, 0.0, far_z), bc, br), "occlusion: outside the disc ⇒ visible")
	# (e) Degenerate body (radius 0) ⇒ never occludes.
	_ok(not ObjectLod.beacon_occluded(eye, Vector3(0.0, 0.0, 5000.0), bc, 0.0), "occlusion: zero-radius body never occludes")

func _test_clamped_placement() -> void:
	var eye := Vector3(10.0, 20.0, 30.0)
	var clamp := 8000.0
	# (1) A FAR object (true distance ≫ clamp): placed AT the clamp distance, on the eye→object ray, projected px preserved.
	var far_c := eye + Vector3(0.0, 0.0, 1.0) * 40000.0     # 40 000 blocks away
	var screen_px := 2.0                                   # the P_POINT beacon size the caller wants preserved
	var pf := ObjectLod.beacon_placement(eye, far_c, screen_px, K, clamp)
	_near(float(pf["d_place"]), clamp, "placement: far object clamped to BEACON_CLAMP_DIST", 0.01)
	var of: Vector3 = pf["origin"]
	_near(eye.distance_to(of), clamp, "placement: clamped origin sits at clamp distance from the eye", 0.01)
	# the placed origin is ON the eye→object ray (colinear, same side).
	var dir := (far_c - eye).normalized()
	_near((of - eye).normalized().dot(dir), 1.0, "placement: clamped origin lies on the eye→object ray")
	# projected px preserved: 2·hs/d_place·kpx == screen_px.
	var proj_at_place := 2.0 * float(pf["hs"]) / float(pf["d_place"]) * K
	_near(proj_at_place, screen_px, "placement: clamped placement preserves projected px (far)")
	# (2) A NEAR object (true distance < clamp): NOT clamped — placed at its true distance, projected px still preserved.
	var near_c := eye + Vector3(1.0, 0.0, 0.0) * 3000.0
	var pn := ObjectLod.beacon_placement(eye, near_c, screen_px, K, clamp)
	_near(float(pn["d_place"]), 3000.0, "placement: near object keeps its true distance (< clamp)", 0.01)
	var on: Vector3 = pn["origin"]
	_near(on.distance_to(near_c), 0.0, "placement: near origin == true object centre", 0.01)
	var proj_near := 2.0 * float(pn["hs"]) / float(pn["d_place"]) * K
	_near(proj_near, screen_px, "placement: near placement preserves projected px")
	# (3) A CARD-size target (screen_px = true angular size) is likewise preserved after clamping.
	var r := 20.0
	var true_dist := 40000.0
	var card_px := 2.0 * r / true_dist * K                 # the object's true angular diameter in px
	var pc := ObjectLod.beacon_placement(eye, far_c, card_px, K, clamp)
	var proj_card := 2.0 * float(pc["hs"]) / float(pc["d_place"]) * K
	_near(proj_card, card_px, "placement: card angular size preserved under clamp")
	# (4) Degenerate (kpx ≤ 0) ⇒ origin = target, hs = 0 (no NaN).
	var pd := ObjectLod.beacon_placement(eye, far_c, screen_px, 0.0, clamp)
	_ok((pd["origin"] as Vector3) == far_c and float(pd["hs"]) == 0.0, "placement: degenerate kpx ⇒ origin=target, hs=0")
