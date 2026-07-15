extends SceneTree
## R2.2 flip-epoch-reinstall check: instance the real main.tscn (M5_REAL + M5C_CORNER), let it set up, then
## FORCE a home-face flip and assert the epoch bake frame is re-installed (a NEW frame) with no errors — the
## fix for "terrain renders broken across faces" (the near mesher kept the stale spawn bake frame post-flip).

class Probe extends Node:
	var _f := 0
	var _did := false
	func _process(_dt: float) -> void:
		_f += 1
		if _f < 120 or _did:
			return
		_did = true
		var wm := _find(get_tree().get_root(), "WorldManager")
		var player := _find(get_tree().get_root(), "Player")
		if wm == null or player == null:
			print("!! missing wm/player"); get_tree().quit(); return
		var before: Dictionary = wm.get("_epoch_frame")
		var anchor_before: Variant = before.get("d_cam", null) if before != null else null
		print("epoch installed at spawn? ", before != null and not before.is_empty())
		# force a flip: put the player ~6 cells PAST the south edge (window z<0 → raw j<0 at M_win=I spawn),
		# which exceeds FLIP_HYST_CORNER=5 → maybe_flip_home_face flips.
		player.global_position = Vector3(20.0, 40.0, -6.0)
		var flipped: bool = wm.call("maybe_flip_home_face", player.global_position)
		print("maybe_flip_home_face returned: ", flipped)
		var after: Dictionary = wm.get("_epoch_frame")
		var anchor_after: Variant = after.get("d_cam", null) if after != null else null
		print("epoch frame present after flip? ", after != null and not after.is_empty())
		print("epoch frame CHANGED by the flip? ", str(anchor_before) != str(anchor_after))
		# and the camera stays finite (place_true(player) != WEDGE for the post-flip epoch):
		if wm.has_method("m5_epoch_camera"):
			var wc: Transform3D = player.call("window_camera_transform") if player.has_method("window_camera_transform") else Transform3D()
			var cam: Transform3D = wm.call("m5_epoch_camera", player.global_position, wc)
			print("post-flip camera origin finite? ", cam.origin.length() < 1.0e6, "  origin=", cam.origin)
		get_tree().quit()

	func _find(root: Node, nm: String) -> Node:
		if root.name == nm: return root
		for c in root.get_children():
			var r := _find(c, nm)
			if r != null: return r
		return null

func _initialize() -> void:
	if CubeSphere.FLAT_WORLD or not CubeSphere.M5_REAL or not CubeSphere.M5C_CORNER:
		print("SKIP: need FLAT_WORLD=false + M5_REAL=true + M5C_CORNER=true"); quit(2); return
	get_root().add_child(load("res://scenes/main.tscn").instantiate())
	var probe := Probe.new(); probe.name = "FlipProbe"
	get_root().add_child(probe)
