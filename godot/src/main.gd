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
	# Minecraft-style hotbar inventory: one model, injected into Player (break/place)
	# and the HotbarHUD. Starts EMPTY — the loop is break-first-then-place.
	var inv := Inventory.new()
	player.inventory = inv
	add_child(player)
	# Spawn on flat, open ground looking out over the gentle hills. The world is
	# now biome/continent-shaped, so origin can be ocean — find_spawn() scans out
	# for a temperate land column above the sea (WGC §8), then _find_flat picks the
	# flattest spot near it. The physics/breaking sandbox is the deterministic
	# trees from the generator (chop a trunk and the canopy detaches as a loose body).
	# TEMPORARY snow-accumulation demo spawn — drops the player on a deep-snow B_SNOWY flat (surface
	# ≈ -8.4 °C near (-187, 289)) so the new variable-height snow accumulation (SNOW-ACCUMULATION
	# Phase A2: graded snow_block cubes + a top LAYER filling the terrain into a white plane) is visible
	# immediately, without the trek from origin. _find_snow_demo scans outward from the known good spot
	# for the nearest deep-snow land column with a solid all-land 5×5 neighbourhood; _find_flat then picks
	# the flattest patch there. REVERT before the PR — restore `var spawn := TerrainConfig.find_spawn()`.
	const SNOW_DEMO_CENTER := Vector2i(-187, 289)
	var spawn := _find_snow_demo(SNOW_DEMO_CENTER.x, SNOW_DEMO_CENTER.y)
	var col := _find_flat(spawn.x, spawn.y)
	player.global_position = Vector3(col.x + 0.5, world.surface_y(col.x, col.y) + 0.1, col.y + 0.5)
	player.set_initial_look(0.0, -0.12)
	world.on_player_ready(player)

	var hotbar := HotbarHUD.new()
	hotbar.name = "HotbarHUD"
	hotbar.inventory = inv
	add_child(hotbar)

	var hud := ThermometerHUD.new()
	hud.name = "ThermometerHUD"
	hud.world = world
	hud.player = player
	add_child(hud)

	# Diagnostic performance overlay (top-right): FPS, main-thread proc/phys ms, draw
	# calls + primitives (GPU load), and godot_voxel pending-task counts (worker
	# saturation). Lets us see the real frame-drop bottleneck in the browser. Remove
	# once perf is settled.
	var perf := PerfHUD.new()
	perf.name = "PerfHUD"
	add_child(perf)

	# Load-time shader/material PIPELINE pre-warm (RENDER-STREAMING-SPIKES). The GL
	# Compatibility renderer compiles each material pipeline synchronously on the main
	# thread the first time it is DRAWN, so on a real device every distinct look
	# stutters (800–950 ms via ANGLE) the first time it scrolls into view during
	# exploration. ShaderPrewarm draws one instance of every material/mesh-format
	# combination for a few frames, hidden behind a "Loading…" overlay, so ANGLE does
	# all the compiles up front. The player is FROZEN until it reports finished.
	player.frozen = true
	var prewarm := ShaderPrewarm.new()
	prewarm.name = "ShaderPrewarm"
	add_child(prewarm)
	prewarm.begin(player, func() -> void: player.frozen = false)

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
	# "sea", which would wash out the grass right at the player's feet.
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
## least in height, so the player starts on even ground.
## TEMPORARY (snow-demo): the nearest deep-snow land column to (cx, cz) with a solid all-land 5×5
## neighbourhood — a spot where the snow accumulation stack (SNOW-ACCUMULATION Phase A2) is graded and
## visible. Scans outward in a growing box; requires the column to carry at least one full snow cube
## (snow_stack_at whole >= 1) and every cell of its 5×5 footprint to be land at/above sea level (so the
## player does not spawn on a snowy shore edge). Falls back to the centre if none is found in range.
func _find_snow_demo(cx: int, cz: int) -> Vector2i:
	for r in range(0, 160, 2):
		for dz in range(-r, r + 1, 2):
			for dx in range(-r, r + 1, 2):
				if maxi(absi(dx), absi(dz)) != r:
					continue                              # only the growing box RING (nearest-first)
				var x := cx + dx
				var z := cz + dz
				var g := TerrainConfig.height_at(x, z)
				if g < TerrainConfig.SEA_LEVEL + 1:
					continue
				if (((TerrainConfig.snow_stack_at(x, z, {}) >> 4) & 0xF) < 1):
					continue                              # need a full snow cube (deep snow), not just a dusting
				var all_land := true
				for oz in range(-2, 3):
					for ox in range(-2, 3):
						if TerrainConfig.height_at(x + ox, z + oz) < TerrainConfig.SEA_LEVEL + 1:
							all_land = false
				if all_land:
					return Vector2i(x, z)
	return Vector2i(cx, cz)

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
