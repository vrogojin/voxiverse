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
	# Spawn on flat, open ground looking out over the gentle hills, with a small
	# field of wooden pillars a few steps ahead as the physics/breaking sandbox.
	var col := _find_flat(0, 0)
	player.global_position = Vector3(col.x + 0.5, world.surface_y(col.x, col.y) + 0.1, col.y + 0.5)
	player.set_initial_look(0.0, -0.12)
	world.on_player_ready(player)

	_spawn_pillars(world, col)

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

	# Depth fog: a long, soft gradient that is fully opaque a little before the
	# render edge, so the terrain boundary at 256 is hidden and the horizon reads
	# as haze. A ground-level player is IMMERSED in the world, so fog must be
	# distance-based (crisp nearby, dissolving far) — NOT a dense low-altitude
	# "sea", which would wash out the grass right at the player's feet. Distant
	# snow-capped peaks (~150 blocks out) show through as pale, hazed silhouettes.
	var r := float(TerrainConfig.RENDER_RADIUS_BLOCKS)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = SKY_COLOR
	env.fog_light_energy = 1.0
	env.fog_depth_begin = r * 0.45    # ~115: crisp near/mid terrain, then fade
	env.fog_depth_end = r * 0.95      # ~243: fully occluded before the 256 edge
	env.fog_depth_curve = 0.9         # soft, slightly front-loaded ramp
	env.fog_sky_affect = 0.0          # keep the sky pure at the horizon
	env.fog_density = 1.0

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

## Find the FLATTEST column near (cx, cz): the one whose 3x3 neighbourhood varies
## least in height, so the player and the wooden pillars start on even ground.
func _find_flat(cx: int, cz: int) -> Vector2i:
	var best := Vector2i(cx, cz)
	var best_spread := 0x7fffffff
	for dz in range(-16, 17, 2):
		for dx in range(-16, 17, 2):
			var x := cx + dx
			var z := cz + dz
			var lo := 0x7fffffff
			var hi := -0x7fffffff
			for oz in range(-1, 2):
				for ox in range(-1, 2):
					var h := TerrainConfig.height_at(x + ox, z + oz)
					lo = mini(lo, h)
					hi = maxi(hi, h)
			var spread := hi - lo
			if spread < best_spread:
				best_spread = spread
				best = Vector2i(x, z)
			if spread == 0:
				return best
	return best

## Spawn a small field of wooden pillars a few steps ahead of the spawn (the
## player looks down -Z). Each is a stack of wooden blocks resting on its own
## column, ready to be broken apart and knocked around.
func _spawn_pillars(world: WorldManager, spawn: Vector2i) -> void:
	# (dx, dz) offset from spawn, and pillar height in blocks. All ahead (-z).
	var layout := [
		[-3, -5, 5], [-1, -6, 7], [1, -6, 4],
		[3, -5, 6], [-2, -9, 8], [2, -9, 5],
	]
	for p in layout:
		var wx: int = spawn.x + p[0]
		var wz: int = spawn.y + p[1]
		var base_y := world.surface_y(wx, wz)
		VoxelBody.spawn_pillar(world, wx, wz, base_y, p[2], world)
