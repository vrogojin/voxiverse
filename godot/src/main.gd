extends Node3D
## Bootstraps the grass test environment. Assembles the scene in code so the
## committed .tscn stays trivial (one node): environment + fog + lighting, the
## WorldManager (which picks the rendering path), the player, and the HUD.

# Soft overcast blue used for both the sky background and the fog, so the render
# boundary at 256 blocks dissolves into the horizon (DESIGN §1).
const SKY_COLOR := Color(0.62, 0.74, 0.86)

var _player: Player

# COSMOS ORBITAL O0 (CubeSphere.ORBITAL_SKY): the celestial clock (advanced each frame) and the sky
# node it drives. Both stay null when the flag is off → no cost, byte-identical to the shipped game.
var _cosmos_clock: CosmosEphemeris.CosmosClock = null
var _cosmos_sky: CosmosSky = null

func _ready() -> void:
	# COSMOS FP0: the faceted-planet VISUAL SPIKE replaces the whole normal world (static demo planet + free
	# camera) so the faceted look can be judged live. Default OFF → the normal game builds below, unchanged.
	if CubeSphere.FACETED_SPIKE:
		add_child(FacetedSpike.new())
		return

	_setup_environment()

	# COSMOS FACETED (docs/COSMOS-FACETED-IMPL.md §4): build the facet atlas and install the spawn facet as the
	# active facet BEFORE the WorldManager (its module generator freezes TerrainConfig.active_facet() at
	# creation). warm_up is idempotent + reads worldgen to pick a temperate-land spawn facet, so TerrainConfig
	# is warmed first. Default OFF (FACETED=false) → this whole block is skipped and the flat game is unchanged.
	if CubeSphere.FACETED:
		TerrainConfig.warm_up()
		FacetAtlas.warm_up()
		TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
		print("[FP1] faceted engine: %d facets (k=%d), spawn facet=%d, spawn col=%s" % [
			FacetAtlas.facet_count(), FacetAtlas.K, FacetAtlas.spawn_facet(), FacetAtlas.spawn_column()])

	var world := WorldManager.new()
	world.name = "WorldManager"
	add_child(world)

	var player := Player.new()
	_player = player
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
	var spawn := TerrainConfig.find_spawn()
	var col := _find_flat(spawn.x, spawn.y, world)
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

	# SN-FIX #1 (docs/COSMOS-SPACE-NAV-DESIGN.md; live pilot request 2026-07-18): the NAV readout — lattice
	# position + radial altitude + nav-mode name. Behind SN_HUD_NAV (default OFF → no node is created and the
	# shipped HUD stack is byte-identical). Additive, read-only.
	if CubeSphere.SN_HUD_NAV:
		var nav_hud := NavHUD.new()
		nav_hud.name = "NavHUD"
		nav_hud.player = player
		add_child(nav_hud)

	# COSMOS ORBITAL O0 (docs/COSMOS-ORBITAL-DESIGN.md §4.4 / §11 O0): the living sky. Behind
	# CubeSphere.ORBITAL_SKY (default OFF → this block is skipped and the shipped flat-ambient
	# environment above is byte-identical). When on, CosmosSky OWNS/overrides the environment ramp
	# (day-night), placing the Sun light + Sun/Moon impostors + star dome from the pure ephemeris; the
	# clock is advanced in _process (below). The player is the parallax-free camera provider.
	# CLIMATE W0/W1 (FP_SEASONS / FP_CLIMATE_GRID) also need the celestial clock (subsolar latitude +
	# insolation game-time), so build it whenever ANY of them is on; the Sun/Moon/sky nodes stay
	# ORBITAL_SKY-only. The clock is injected into the WorldManager so the weather grid can read game-time.
	if CubeSphere.ORBITAL_SKY or CubeSphere.FP_SEASONS or CubeSphere.FP_CLIMATE_GRID:
		_cosmos_clock = CosmosEphemeris.CosmosClock.new()
		world.set_cosmos_clock(_cosmos_clock)
	if CubeSphere.ORBITAL_SKY:
		var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
		var env: Environment = we.environment if we != null else null
		_cosmos_sky = CosmosSky.new()
		_cosmos_sky.name = "CosmosSky"
		add_child(_cosmos_sky)
		_cosmos_sky.setup(_cosmos_clock, env, player)

	# CLIMATE W2 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §4): the 3-layer cloud mesher, a read-only view of the
	# weather grid (rule 2). Built only under BOTH flags (it reads the grid's cloud water); default OFF ⇒ no
	# node ⇒ byte-identical. The player is the camera provider; PerVoxelEnvironment is the grid read interface.
	if CubeSphere.FP_CLOUDS and CubeSphere.FP_CLIMATE_GRID:
		var clouds := CloudLayers.new()
		clouds.name = "CloudLayers"
		add_child(clouds)
		clouds.setup(world.environment, player)

	# CLIMATE W3 (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §5): precipitation particles + fog, a read-only view of
	# the grid (rule 2). Built only under both flags; default OFF ⇒ no node ⇒ byte-identical. The Environment
	# (from the WorldEnvironment stub) is driven for fog; the player is the camera provider.
	if CubeSphere.FP_PRECIP and CubeSphere.FP_CLIMATE_GRID:
		var we2 := get_node_or_null("WorldEnvironment") as WorldEnvironment
		var fx := WeatherFX.new()
		fx.name = "WeatherFX"
		add_child(fx)
		fx.setup(world.environment, we2.environment if we2 != null else null, player)

	# Diagnostic perf overlay (top-right): FPS/min-FPS, proc+phys ms, draw calls/primitives,
	# video mem, and godot_voxel worker/pool counts — so the COSMOS curved demos can be measured
	# on-device (esp. the M4 seam-handoff frame/memory budget). DEMO instrumentation — revert
	# before any PR to main.
	var perf := PerfHUD.new()
	perf.name = "PerfHUD"
	add_child(perf)

	# REMOTE-PLAY BRIDGE activation (Phase 1, observe-only). An INPUT-ONLY activator is always present:
	# it wires the Ctrl+Shift+F9 toggle, the on-canvas token prompt, and the live "REMOTE ACTIVE" badge,
	# but holds NOTHING live (no WebSocket, no frame capture, no per-frame cost) until the chord fires
	# with a valid token — or the `?remote=<token>` URL param pre-arms it (RemoteBridge.preset_token()).
	# The relay URL is fixed to our host; the prompt takes a token only. verify_feature never runs
	# main.gd, so the FLAT gate is unaffected. See net/remote_bridge_activator.gd for the trust model.
	var activator := RemoteBridgeActivator.new()
	activator.name = "RemoteBridgeActivator"
	activator.configure(world, player, RemoteBridge.preset_token())
	add_child(activator)

	# REMOTE-CONTROL P2 (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4/§7). The RemoteControl executor
	# (net/remote_control.gd) is deliberately NOT a persistent scene node: RemoteBridge instantiates it
	# ONLY after the human consents in-game and frees it on revoke/override/link-loss ("dead in normal
	# play", §4.1). The control graph is therefore owned by the activator+bridge wired just above —
	# main.gd only records the master gate. Guarded by RemoteBridge.CONTROL_ENABLED (default false → this
	# block is skipped, byte-identical Phase-1); P4 flips the flag ONLY after the §6 security review +
	# /steelman + sign-off. A parallel Track-B edit to the scene wiring merges cleanly around this block.
	if RemoteBridge.CONTROL_ENABLED:
		print("[REMOTE] P2 control ENABLED — executor is bridge-spawned on human consent (net/remote_control.gd)")

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

	# COSMOS M1 (§3.4): the render bend is camera-centred, so register + seed the global bend
	# uniforms now. FLAT_WORLD (default) leaves them untouched — no bend materials are ever built.
	if not CubeSphere.FLAT_WORLD:
		if CubeSphere.M5_RENDER:
			world.m5_push_camera(player.camera_global_transform().origin)   # true-position frame + chart table
		else:
			CosmosBend.set_camera(player.camera_global_transform().origin)

	# COSMOS DEV (task #66): the cube-face BORDER overlay — bright magenta pillars along the home face's
	# seam edges, so they can be walked up to for M4 crossing tests. Curved-only AND flag-gated; FLAT_WORLD
	# never reaches here (no chart, no borders) so the default path is byte-identical.
	if not CubeSphere.FLAT_WORLD and CosmosBorderOverlay.DEV_BORDERS:
		var borders := CosmosBorderOverlay.new()
		borders.name = "CosmosBorderOverlay"
		add_child(borders)
		borders.setup(world, player)

## Feed the camera position into the bend-origin global uniform each frame (curved mode only).
## The bend is continuous around the camera (§3.4), so walking simply rolls the world under you.
func _process(_delta: float) -> void:
	# COSMOS ORBITAL O0: advance the celestial clock every frame (independent of the render path). The
	# sky moves 72× via the scaled GM; CosmosSky reads this clock in its own _process. Null (flag off)
	# ⇒ untouched. Placed before the FLAT_WORLD early-return so the sky ticks in the flat/faceted game.
	if _cosmos_clock != null:
		_cosmos_clock.advance(_delta)
		# CLIMATE W0 (§3): publish the current subsolar sin-latitude once per frame (main thread) so the
		# sim-layer season offset (PerVoxelEnvironment / SnowfallSystem) tracks the seasons. Flag-off ⇒ never
		# written ⇒ stays 0 ⇒ zero seasonal offset (byte-identical). Pure ephemeris read, no allocation.
		if CubeSphere.FP_SEASONS:
			ClimateModel.current_sin_delta = sin(CosmosEphemeris.subsolar_latitude(_cosmos_clock.now()))
	# COSMOS-ORBITAL-SHELL S1/S2 (docs/COSMOS-ORBITAL-SHELL-DESIGN.md §3/§9): drive the far-ring emitted set from the
	# CAMERA radial direction + arm the one-shot prewarm. The FACETED production game ships FLAT_WORLD=true and RETURNS
	# below, so — exactly like the sky clock above — this MUST run BEFORE that early-return or the driver is DEAD (the
	# live far-side-blank bug: the hook used to sit after the return → update_shell_camera_set was never called →
	# shell_telemetry() came back {} every frame). Gated on the shell flags + FACETED (flag-off ⇒ never called ⇒
	# byte-identical); _player-null-guarded. At the user's low orbit the shipped faceted far plane (9000) already
	# reaches the far-ring limb √(d²−R²), so this driver-move alone renders the far side; the SN3 scaled-body ramp
	# (also stranded below the return) is only needed above h≈6.4k and is a separate FP_SCALED_BODY pass.
	if _player != null and (CubeSphere.FP_SHELL_CAMERA_SET or CubeSphere.FP_SHELL_PREWARM) and CubeSphere.FACETED:
		_player.world.update_shell_camera_set(_player.camera_global_transform().origin)
	# COSMOS-LOD-SKY L3 (SHELL_TERMINATOR_TINT): forward the sky's current Sun direction into the far-ring shell
	# tint shader so the space-side terminator band tracks the same Sun as the ground ramp. Gated on the flag +
	# a live sky; the WorldManager/ring setters self-guard, so flag-off is byte-identical (never called).
	if _player != null and _cosmos_sky != null and CubeSphere.SHELL_TERMINATOR_TINT and CubeSphere.FACETED:
		_player.world.set_far_ring_sun_dir(_cosmos_sky.current_sun_dir())
	# COSMOS ATMO-SKY A5 (docs/COSMOS-ATMO-SKY-DESIGN.md §3 C2): forward the Sun direction + the scaled planet
	# render centre into the far-ring shell v2 shader (absolute self-shaded globe). Same forwarding discipline as
	# the L3 tint above; the setter self-guards on FP_SHELL_ABSOLUTE so flag-off is byte-identical (never wired).
	if _player != null and _cosmos_sky != null and CubeSphere.FP_SHELL_ABSOLUTE and CubeSphere.FACETED:
		_player.world.set_far_ring_shell_absolute(_cosmos_sky.current_sun_dir())
	# COSMOS ATMO-SKY A0 (docs/COSMOS-ATMO-SKY-DESIGN.md §2.0/§4): the SN3 scaled-body driver, MOVED ABOVE the
	# FLAT_WORLD early-return so FP_SCALED_BODY actually RUNS in the faceted production game (FLAT_WORLD=true) —
	# the shipped block below the return is DEAD in faceted (FACETED ⇒ FLAT_WORLD ⇒ we already returned by 206),
	# the same stranded-driver class as the shell-driver fix (0b2a934). Camera near/far ramp with altitude + the
	# far ring gets its distance clamp, un-clipping the planet from altitude/deep space. Gated on FP_SN3_MAIN_LIVE
	# ⇒ flag-off is byte-identical (never runs; the legacy block below is untouched and stays dead in faceted).
	# The A0/legacy blocks are mutually exclusive by the FLAT⇔FACETED coupling, so there is no double-drive.
	if _player != null and CubeSphere.FP_SN3_MAIN_LIVE and CosmosScale.on() and CubeSphere.FACETED:
		var a0_cam := _player.camera_global_transform().origin
		var a0_d := a0_cam.distance_to(_player.world.planet_render_centre())
		_player.apply_scaled_camera_planes(a0_d - FacetAtlas.R_BLOCKS, a0_d)
		_player.world.apply_scaled_body(a0_cam)
	if CubeSphere.FLAT_WORLD or _player == null:
		return
	var cam := _player.camera_global_transform().origin
	if CubeSphere.M5_RENDER:
		_player.world.m5_push_camera(cam)
	elif CubeSphere.M5_REAL:
		# R2.2 real geometry (Design Z): the near + far are REAL baked geometry (no bend shader), static in
		# the epoch frame. Keep the far static (apply_alignment IDENTITY) and move the DISPLAYED camera into
		# that frame — camera_epoch = F⁻¹ · window_cam — so it flies through the static baked planet at the
		# player's true position/orientation. Physics, streaming and interaction stay in window space (exact
		# aim arrives with the J⁻¹ input map in R2.3). We do NOT rotate the VoxelTerrain (godot_voxel det==0).
		_player.world.m5_real_update(_player.global_position)
		_player.set_render_camera(
			_player.world.m5_epoch_camera(_player.global_position, _player.window_camera_transform()))
	else:
		CosmosBend.set_camera(cam)                     # near field: the camera-centred bend (R1, bend path)

	# SPACE-NAV SN3 (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.2-5.4): border continuity. Ramp the camera near/far
	# with altitude and place the far ring under the angular-size-preserving distance clamp, so the atmosphere↔
	# space border and the climb to orbit render with NO pop. Below D_ENGAGE the clamp scale is exactly 1 (near
	# regime byte-identical). DEAD with FP_SCALED_BODY off. Independent of the camera-write above (near/far are
	# separate properties from the camera transform), so it composes with the M5_REAL / bend paths untouched.
	if CosmosScale.on() and CubeSphere.FACETED:
		var centre := _player.world.planet_render_centre()
		var d := cam.distance_to(centre)
		_player.apply_scaled_camera_planes(d - FacetAtlas.R_BLOCKS, d)
		_player.world.apply_scaled_body(cam)

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
	if CubeSphere.FACETED:
		# COSMOS FACETED §5.2: the faceted planet fills the view out to ~2R; fog only far out so the whole
		# planet reads, opaque just before the camera far so the space-black rim is hidden.
		env.fog_depth_begin = FacetFarRing.FOG_BEGIN
		env.fog_depth_end = FacetFarRing.CAMERA_FAR * 0.98
		env.fog_depth_curve = 0.5
	elif FarTerrain.ENABLED:
		# Far field present (LOD-DESIGN §3.4): retune the 243 m wall into a ~2,750 m haze so
		# the distant mountains/coastlines read as silhouettes and dissolve into the horizon at
		# the R_FAR rim. Front-loaded curve keeps the seam band at ~26–49% (washing the residuals)
		# while the 115–192 near band stays crisper than today.
		env.fog_depth_begin = FarTerrain.FOG_BEGIN   # 115: unchanged near feel
		env.fog_depth_end = FarTerrain.FOG_END       # 2750: opaque before the 3,072 rim
		env.fog_depth_curve = FarTerrain.FOG_CURVE   # 0.38
	else:
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
## least in height, so the player starts on even ground. In curved mode the search
## SKIPS double-out corner WEDGE columns (world.is_wedge_column) — an impossible cell
## reads as perfectly flat void, so the un-filtered search parks the spawn there and
## the M5_REAL camera starts at the 1e18 wedge sentinel (blank screen).
func _find_flat(cx: int, cz: int, world: WorldManager = null) -> Vector2i:
	var best := Vector2i(cx, cz)
	var best_spread := 0x7fffffff
	var best_is_wedge := (world != null and world.is_wedge_column(cx, cz))
	for dz in range(-16, 17, 2):
		for dx in range(-16, 17, 2):
			var x := cx + dx
			var z := cz + dz
			if world != null:
				# COSMOS M5c (§4): under the corner seal, spawn must be HOME-NATIVE (both raw indices in [0,n),
				# no edge fold) or the eager hysteresis fires a flip + hard restream on the first physics frame.
				# The (+,+) home quadrant of the scan box always has candidates. Native ⊂ non-wedge, so this
				# subsumes the wedge skip. Flag off → the shipped wedge skip only.
				if CubeSphere.M5C_CORNER:
					if not world.is_home_native_column(x, z):
						continue
				elif world.is_wedge_column(x, z):
					continue
			var lo := 0x7fffffff
			var hi := -0x7fffffff
			for oz in range(-1, 2):
				for ox in range(-1, 2):
					var h := TerrainConfig.height_at(x + ox, z + oz)
					lo = mini(lo, h)
					hi = maxi(hi, h)
			var spread := hi - lo
			# Always prefer a non-wedge column over the wedge seed, then flattest.
			if best_is_wedge or spread < best_spread:
				best_spread = spread
				best = Vector2i(x, z)
				best_is_wedge = false
			if spread == 0 and not best_is_wedge:
				return best
	return best
