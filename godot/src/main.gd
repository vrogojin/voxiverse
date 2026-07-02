extends Node3D
## Bootstraps the grass test environment. Assembles the scene in code so the
## committed .tscn stays trivial (one node): environment + fog + lighting, the
## WorldManager (which picks the rendering path), the player, and the HUD.

# Soft overcast blue used for both the sky background and the fog, so the render
# boundary at 256 blocks dissolves into the horizon (DESIGN §1).
const SKY_COLOR := Color(0.62, 0.74, 0.86)

func _ready() -> void:
	_setup_environment()

	var world := WorldManager.new()
	world.name = "WorldManager"
	add_child(world)

	var player := Player.new()
	player.name = "Player"
	player.world = world
	add_child(player)
	# Spawn just above the surface at the origin and let gravity settle us.
	var spawn_y := world.surface_y(0.0, 0.0) + 2.0
	player.global_position = Vector3(0.5, spawn_y, 0.5)
	world.on_player_ready(player)

	var hud := ThermometerHUD.new()
	hud.name = "ThermometerHUD"
	hud.world = world
	hud.player = player
	add_child(hud)

func _setup_environment() -> void:
	var env := Environment.new()

	# Flat, even ambient lighting — no sun, no shadows.
	env.background_mode = Environment.BG_COLOR
	env.background_color = SKY_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0

	# Depth fog: clear near, fully occluding by the render radius.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = SKY_COLOR
	env.fog_light_energy = 1.0
	env.fog_depth_begin = float(TerrainConfig.RENDER_RADIUS_BLOCKS) * 0.62  # ~160
	env.fog_depth_end = float(TerrainConfig.RENDER_RADIUS_BLOCKS)           # 256
	env.fog_depth_curve = 1.0
	env.fog_density = 1.0

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
