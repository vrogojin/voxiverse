class_name WeatherFX
extends Node3D
## COSMOS CLIMATE W3 — precipitation + fog FX (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §5). A read-only VIEW
## of the weather grid (engine rule 2): rain/snow/hail and fog are THRESHOLD read-outs of the grid state
## via PerVoxelEnvironment — no phenomenon has its own simulation.
##
## NEVER-OOM (§8 rows 6): ONE reused camera-following particle node (hard `amount` cap ≤1024, fixed pool,
## zero growth) whose emission ratio and mesh/velocity swap by the grid's precip {rate, kind}; and the
## Environment fog density driven (property writes only) from grid humidity, composed MULTIPLICATIVELY with
## the shipped fog so it only ADDS haze where the air is near-saturated. Snow ACCUMULATION stays
## SnowfallSystem's existing budgeted machinery (coupled via is_snowing, §1.5) — no world edits here.

const AMOUNT_CAP := 1024              ## hard particle-pool cap (§8 row 6)
const BOX := 48.0                     ## emission box half-extent around the camera (blocks)
const SPAWN_H := 40.0                 ## height above the camera the precip spawns at (along the radial up)
const FOG_GAIN := 2.5                 ## how strongly near-saturated air thickens the fog
const RAIN_G := 120.0                 ## rain/hail fall acceleration magnitude (applied along −up = radial down)
const SNOW_G := 14.0                  ## snow fall acceleration magnitude (gentler)

var _env: PerVoxelEnvironment = null
var _environment: Environment = null
var _cam_provider: Node = null
var _particles: GPUParticles3D = null
var _rain_mat: ParticleProcessMaterial
var _snow_mat: ParticleProcessMaterial
var _base_fog := 0.0
var _kind := "none"
# W4: ONE reused flash light for lightning + a fade timer (bounded, property/energy writes only).
var _flash: OmniLight3D = null
var _flash_energy := 0.0
var _flash_cooldown := 0.0

func setup(env: PerVoxelEnvironment, environment: Environment, cam_provider: Node = null) -> void:
	_env = env
	_environment = environment
	_cam_provider = cam_provider
	if _environment != null:
		_base_fog = _environment.fog_density
	_rain_mat = _make_process(Vector3(0.0, -120.0, 0.0), 2.0, Color(0.7, 0.75, 0.85))
	_snow_mat = _make_process(Vector3(0.0, -14.0, 0.0), 6.0, Color(0.98, 0.98, 1.0))
	_particles = GPUParticles3D.new()
	_particles.name = "PrecipParticles"
	_particles.amount = AMOUNT_CAP
	_particles.lifetime = 2.2
	_particles.visibility_aabb = AABB(Vector3(-BOX, -SPAWN_H, -BOX), Vector3(BOX * 2.0, SPAWN_H * 2.0, BOX * 2.0))
	_particles.local_coords = false
	_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_particles.process_material = _rain_mat
	_particles.draw_pass_1 = _make_particle_mesh(Color(0.7, 0.75, 0.85))
	_particles.emitting = false
	_particles.amount_ratio = 0.0
	add_child(_particles)
	# W4 lightning: one reused omni flash (off until a storm fires); zero cost otherwise.
	_flash = OmniLight3D.new()
	_flash.name = "LightningFlash"
	_flash.omni_range = 2048.0
	_flash.light_energy = 0.0
	_flash.light_color = Color(0.85, 0.9, 1.0)
	_flash.shadow_enabled = false
	add_child(_flash)

func _make_process(gravity: Vector3, spread: float, _col: Color) -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(BOX, 1.0, BOX)
	m.direction = Vector3(0, -1, 0)
	m.spread = spread
	m.gravity = gravity
	m.initial_velocity_min = 2.0
	m.initial_velocity_max = 6.0
	return m

func _make_particle_mesh(col: Color) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.4, 0.9)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_fog = true
	q.material = mat
	return q

func _process(delta: float) -> void:
	if _particles == null:
		return
	var cam := _cam_origin()
	# LOCAL-SURFACE FRAME (cloudfix 2026-07-19): the planet centre is the scene origin, so the radial up at the
	# camera is cam.normalized() (the CosmosSky convention the clouds share). Orient the emitter so its slab is
	# horizontal over the terrain and precip falls along −up (radial down), NOT global −Y — otherwise on a tilted
	# facet the rain streaks sideways ("90° wrong"). ZERO allocation: transform + property writes only.
	var up := cam.normalized() if cam.length() > 1.0 else Vector3.UP
	var ref := Vector3(0, 1, 0)
	if absf(up.dot(ref)) > 0.99:
		ref = Vector3(1, 0, 0)
	var t1 := up.cross(ref).normalized()
	var t2 := up.cross(t1).normalized()
	var emit_basis := Basis(t1, up, t2)
	_particles.global_transform = Transform3D(emit_basis, cam + up * SPAWN_H)
	# ATMOSPHERE GATE: no precip / no fog thickening in orbit or space (radial altitude > ATMO_TOP).
	if not _in_atmosphere(cam):
		_apply(0.0, "none")
		if _environment != null:
			_environment.fog_density = _base_fog
		_drive_lightning(delta, false)
		return
	# Sample the weather grid at the camera's ACTIVE-FACET LATTICE column (the frame _dir_of_pos folds); the FX
	# geometry above is in scene space, but the grid is indexed by lattice columns. Falls back to the scene cam
	# for a provider without the lattice accessor (headless/no player) — harmless, the grid is null there anyway.
	var col := _grid_pos(cam)
	var precip := _env.precipitation(col) if _env != null else {"rate": 0.0, "kind": "none"}
	var rate := float(precip.get("rate", 0.0))
	var kind := String(precip.get("kind", "none"))
	# W4: a convective column upgrades falling rain to HAIL and can flash lightning.
	var storm := CubeSphere.FP_STORMS and _env != null and _env.is_convective(col)
	if storm and rate > 0.0 and kind == "rain":
		kind = "hail"
	_apply(rate, kind)
	# steer the active fall acceleration along the radial down (−up) so streaks/flakes drop toward the ground.
	var g := SNOW_G if _kind == "snow" else RAIN_G
	(_particles.process_material as ParticleProcessMaterial).gravity = -up * g
	_drive_fog(col)
	_drive_lightning(delta, storm)

## True while the camera is inside the atmosphere band — precip/fog exist only here (never in orbit/space).
func _in_atmosphere(cam: Vector3) -> bool:
	return (cam.length() - FacetAtlas.R_BLOCKS) <= CubeSphere.ATMO_TOP

## The camera position in the active-facet LATTICE frame (what the weather grid indexes). Uses the player's
## accessor when present; otherwise the scene cam (headless gate has no grid, so the value is unused).
func _grid_pos(cam: Vector3) -> Vector3:
	if _cam_provider != null and _cam_provider.has_method("camera_lattice_origin"):
		return _cam_provider.camera_lattice_origin()
	return cam

## Lightning: while a storm is overhead, fire a brief flash on a cooldown and fade it out. A single
## reused OmniLight (energy writes only) — bounded, no per-frame allocation. Distance-delayed thunder
## audio is an optional live-only add (no bundled asset).
func _drive_lightning(delta: float, storm: bool) -> void:
	if _flash == null:
		return
	var cam := _cam_origin()
	var up := cam.normalized() if cam.length() > 1.0 else Vector3.UP
	_flash.global_transform = Transform3D(Basis.IDENTITY, cam + up * SPAWN_H)
	_flash_cooldown -= delta
	if storm and _flash_cooldown <= 0.0:
		_flash_energy = 4.0                          # strike
		_flash_cooldown = randf_range(1.5, 5.0)
	_flash_energy = maxf(0.0, _flash_energy - delta * 12.0)   # fast decay (a 2-frame-ish pulse)
	_flash.light_energy = _flash_energy

func _apply(rate: float, kind: String) -> void:
	if rate <= 0.0:
		_particles.emitting = false
		_particles.amount_ratio = 0.0
		return
	_particles.emitting = true
	_particles.amount_ratio = clampf(rate, 0.05, 1.0)
	if kind != _kind:
		_kind = kind
		# swap the process material + look between rain streaks and snow flakes (hail reuses rain physics).
		_particles.process_material = _snow_mat if kind == "snow" else _rain_mat

## Fog: thicken the shipped fog where grid humidity approaches saturation (calm, low sun ⇒ radiation fog).
## Multiplicative on the base so it never darkens clear/space air; a pure property write (no allocation).
func _drive_fog(cam: Vector3) -> void:
	if _environment == null:
		return
	var hum := _env.humidity(cam) if _env != null else 0.0
	var sat := clampf(hum / WeatherSystem.Q_MAX, 0.0, 1.0)
	var mult := 1.0 + FOG_GAIN * smoothstep(0.55, 0.95, sat)
	# B5 (FP_FOG_ARBITER, §2.6): COMPOSE onto CosmosSky's altitude fog — read the CURRENT fog_density (which
	# CosmosSky._ramp_environment set to the altitude ρ(h)·atmo_vis(h) earlier this frame) and multiply, instead
	# of overwriting from the captured sea-level base (which stomped the altitude thinning dead). No compounding:
	# CosmosSky rewrites fog_density every frame before WeatherFX (which _processes later in the tree). Off ⇒ the
	# shipped overwrite from _base_fog ⇒ byte-identical.
	if CubeSphere.FP_FOG_ARBITER:
		_environment.fog_density = _environment.fog_density * mult
	else:
		_environment.fog_density = _base_fog * mult

func _cam_origin() -> Vector3:
	if _cam_provider != null and _cam_provider.has_method("camera_global_transform"):
		return (_cam_provider.camera_global_transform() as Transform3D).origin
	return global_transform.origin

# --- gate / inspection support -------------------------------------------------
func debug_apply(rate: float, kind: String) -> void:
	_apply(rate, kind)

## Gate hook: is a scene camera position inside the atmosphere band? (the precip/fog altitude gate predicate)
func debug_in_atmosphere(cam: Vector3) -> bool:
	return _in_atmosphere(cam)

func particle_cap() -> int:
	return _particles.amount if _particles != null else 0

func is_emitting() -> bool:
	return _particles != null and _particles.emitting

func current_kind() -> String:
	return _kind
