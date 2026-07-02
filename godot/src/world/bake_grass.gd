extends SceneTree
## Headless entry point to regenerate the grass texture with a real engine:
##   godot --headless -s res://src/world/bake_grass.gd
## The committed PNG is normally produced by scripts/gen-grass-texture (Python),
## which needs no engine; this is the engine-native equivalent.

func _initialize() -> void:
	var err := GrassTextureBaker.bake()
	if err == OK:
		print("[bake_grass] wrote ", GrassTextureBaker.OUT_PATH)
	else:
		push_error("[bake_grass] failed: %d" % err)
	quit(0 if err == OK else 1)
