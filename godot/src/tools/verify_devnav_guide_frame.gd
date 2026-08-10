extends SceneTree
## FP_DEVNAV_GUIDE_FRAME headless gate — G-DGF.
##
## Falsifies:
##   (A) WorldManager.planet_render_transform() — IDENTITY with no faceted ring; the ring's OWN global_transform
##       once one exists (no copy/derivation drift — it's the exact same Transform3D).
##   (B) DevNavOverlay.set_guides_transform(xf) — a documented no-op before build() (the guide root doesn't exist
##       yet, so it must not crash and must leave the overlay un-built); after build(), the guide root's
##       global_transform becomes EXACTLY xf (origin + basis, to float precision) — this is what makes the
##       axis/equator/border guides ride the planet's live render placement instead of the world origin.
##
## Both are plain Node3D/Node methods with no scene-tree membership requirement, so this runs green on any build
## (the flag FP_DEVNAV_GUIDE_FRAME only gates whether Player calls set_guides_transform per-frame — see player.gd).
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_devnav_guide_frame.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const CS := preload("res://src/cosmos/cube_sphere.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _xf_eq(a: Transform3D, b: Transform3D, eps: float) -> bool:
	if a.origin.distance_to(b.origin) > eps:
		return false
	return a.basis.x.distance_to(b.basis.x) <= eps and a.basis.y.distance_to(b.basis.y) <= eps and a.basis.z.distance_to(b.basis.z) <= eps

func _initialize() -> void:
	print("=== verify_devnav_guide_frame (FP_DEVNAV_GUIDE_FRAME: G-DGF) ===")
	_run()

func _run() -> void:
	# Node3D.global_transform is only valid once the node (and `root`) has actually entered the live tree — during
	# _initialize() root itself is not yet inside_tree, so reads/writes silently no-op. One process_frame is enough.
	await process_frame
	_gate_render_transform()
	_gate_guides_transform()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- (A) WorldManager.planet_render_transform() ----------
func _gate_render_transform() -> void:
	print("  --- (A) planet_render_transform: IDENTITY with no ring; exactly the ring's global_transform once set ---")
	var wm := WorldManager.new()
	_ok(wm.planet_render_transform() == Transform3D.IDENTITY, "(A) IDENTITY when there is no faceted ring yet")

	var ring := FacetFarRing.new()
	root.add_child(ring)                                      # global_transform needs tree membership
	ring.set_process(false)                                   # Godot 4 auto-enables _process() on enter-tree; we never call setup()
	var xf := Transform3D(Basis(Vector3(0, 1, 0), deg_to_rad(35.0)).scaled(Vector3(0.9, 0.9, 0.9)), Vector3(120.5, -30.2, 4000.0))
	ring.transform = xf
	wm._facet_ring = ring
	_ok(_xf_eq(wm.planet_render_transform(), ring.global_transform, 1.0e-5),
		"(A) once a ring exists, planet_render_transform() IS the ring's own global_transform (no drift)")
	ring.queue_free()
	wm.free()

# ---------- (B) DevNavOverlay.set_guides_transform ----------
func _gate_guides_transform() -> void:
	print("  --- (B) set_guides_transform: no-op pre-build; exact global_transform write post-build ---")
	var ov := DevNavOverlay.new()
	var xf_early := Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	ov.set_guides_transform(xf_early)                        # must not crash before build()
	_ok(not ov.is_built(), "(B) calling set_guides_transform before build() leaves the overlay un-built (documented no-op)")

	var parent := Node3D.new()
	root.add_child(parent)                                    # global_transform needs tree membership
	ov.build(parent, 6371.0)
	_ok(ov.is_built(), "(B) fixture precondition: build() succeeded")

	var xf := Transform3D(Basis(Vector3(1, 0, 0), deg_to_rad(-22.0)), Vector3(-500.0, 88888.0, 3.25))
	ov.set_guides_transform(xf)
	_ok(_xf_eq(ov._line_root.global_transform, xf, 1.0e-4),
		"(B) after build(), the guide root's global_transform becomes exactly the given xf")

	# A second, different transform overwrites cleanly (per-frame call, not a one-shot).
	var xf2 := Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(90.0)), Vector3(1.0, 1.0, 1.0))
	ov.set_guides_transform(xf2)
	_ok(_xf_eq(ov._line_root.global_transform, xf2, 1.0e-4), "(B) a second call overwrites to the new xf (per-frame follow)")

	ov.free_overlays()
	ov.free()
	parent.queue_free()
