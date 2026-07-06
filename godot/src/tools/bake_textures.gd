extends SceneTree
## Headless entry point to (re)bake the enhanced block textures from the CC0 base
## tiles:  godot --headless --path godot -s res://src/tools/bake_textures.gd
## The committed pack/*.png are the output of this script; re-run it after editing
## the spec or the enhancement in src/world/texture_pack_baker.gd.

func _initialize() -> void:
	var err := TexturePackBaker.bake_all()
	if err == OK:
		print("[bake_textures] all tiles baked to ", TexturePackBaker.OUT_DIR)
	else:
		push_error("[bake_textures] failed: %d" % err)
	quit(0 if err == OK else 1)
