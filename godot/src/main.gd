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
	# Spawn cleanly ON the surface at a local high point so no hill wall looms in
	# front, then face downhill for an open view over the terrain.
	var spawn := _pick_spawn()
	player.global_position = Vector3(spawn.x + 0.5, world.surface_y(spawn.x, spawn.y) + 0.1, spawn.y + 0.5)
	player.set_initial_look(_downhill_yaw(spawn.x, spawn.y), -0.18)
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

	# Depth fog: a long, soft gradient that is FULLY opaque a little before the
	# render edge, so the terrain boundary at 256 is hidden and the horizon reads
	# as a smooth fade into the sky rather than a hard line.
	var r := float(TerrainConfig.RENDER_RADIUS_BLOCKS)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = SKY_COLOR
	env.fog_light_energy = 1.0
	env.fog_depth_begin = r * 0.40   # ~102: start fading well before the edge
	env.fog_depth_end = r * 0.92     # ~236: fully occluded before the 256 boundary
	env.fog_depth_curve = 0.85       # slightly front-loaded ramp for a soft horizon
	env.fog_density = 1.0

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

## Find a pleasant spawn column: the highest ground within a small area around
## the origin. Standing on a local peak guarantees no adjacent taller block wall
## fills the view. Returns the (x, z) world column.
func _pick_spawn() -> Vector2i:
	var best := Vector2i(0, 0)
	var best_h := -0x7fffffff
	var radius := 40
	var step := 2
	for z in range(-radius, radius + 1, step):
		for x in range(-radius, radius + 1, step):
			var h := TerrainConfig.height_at(x, z)
			if h > best_h:
				best_h = h
				best = Vector2i(x, z)
	return best

## Yaw (rotation about Y) that faces downhill from column (x, z), so the player
## looks out over the descending terrain.
func _downhill_yaw(x: int, z: int) -> float:
	var gx := float(TerrainConfig.height_at(x + 8, z) - TerrainConfig.height_at(x - 8, z))
	var gz := float(TerrainConfig.height_at(x, z + 8) - TerrainConfig.height_at(x, z - 8))
	var dir := Vector2(-gx, -gz)  # downhill = negative gradient
	if dir.length() < 0.01:
		return 0.0
	dir = dir.normalized()
	# Godot: forward (-Z) for yaw a is (-sin a, -cos a); solve to face `dir`.
	return atan2(-dir.x, -dir.y)
