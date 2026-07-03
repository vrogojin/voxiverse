class_name SurfaceModel
extends RefCounted
## The shared surface-material decision — the VOXIVERSE core triad in one place:
##   per-voxel environment field (temperature)  ->  material STATE transition
##   (grass <-> snow, temperature-driven)         ->  distinct look (grass/snow).
##
## Grass and snow are modelled as two STATES of the ground-surface material, with
## temperature transitions between them (VoxelState / VoxelStateTransition). The
## environment→look decision therefore runs through the state machine, never an
## ad-hoc `if` in a mesher — so ice/mud/… drop in as more states/transitions.
##
## Both rendering paths call `block_id_at(x, z)` for a column's surface block id
## (air=0, grass=1, snow=2), so the godot_voxel generator and the GDScript
## fallback always agree on where snow appears.

const GRASS_ID := 1
const SNOW_ID := 2
const FREEZE_C := 0.0   # surface at/below this (deg C) freezes to snow

static var _material: VoxelMaterialDef
static var _env: PerVoxelEnvironment

## Lazily build the surface material + its state machine (idempotent). Call once
## on the main thread before meshing to avoid a race if generation is threaded.
static func ensure_ready() -> void:
	if _material != null:
		return
	_env = PerVoxelEnvironment.new()

	var grass := VoxelState.new()
	grass.state_name = &"grass"
	grass.block_id = GRASS_ID
	grass.break_force = INF          # unbreakable (DESIGN §1)
	grass.density = 1500.0
	grass.mass = 1500.0
	grass.albedo = 0.25
	grass.texture = load(GrassMaterial.TEXTURE_PATH) as Texture2D

	var snow := VoxelState.new()
	snow.state_name = &"snow"
	snow.block_id = SNOW_ID
	snow.break_force = INF
	snow.density = 300.0             # snow is light
	snow.mass = 300.0
	snow.albedo = 0.85              # snow reflects most light
	snow.permeability = 0.2
	snow.texture = load(GrassMaterial.SNOW_TEXTURE_PATH) as Texture2D

	# Temperature-driven transitions (a real two-way FSM for future stateful sim;
	# generation starts from grass and takes one step).
	var to_snow := VoxelStateTransition.new()
	to_snow.field = "temperature"
	to_snow.comparator = VoxelStateTransition.Comparator.LESS_EQUAL
	to_snow.threshold = FREEZE_C
	to_snow.to_state = &"snow"
	grass.transitions = [to_snow]

	var to_grass := VoxelStateTransition.new()
	to_grass.field = "temperature"
	to_grass.comparator = VoxelStateTransition.Comparator.GREATER
	to_grass.threshold = FREEZE_C
	to_grass.to_state = &"grass"
	snow.transitions = [to_grass]

	var mat := VoxelMaterialDef.new()
	mat.id = &"surface"
	mat.states = [grass, snow]
	mat.default_state_index = 0
	_material = mat

static func material() -> VoxelMaterialDef:
	ensure_ready()
	return _material

## Resolve the surface state at column (x, z): sample the environment at the
## surface voxel and run the material's state machine.
static func surface_state(x: int, z: int) -> VoxelState:
	ensure_ready()
	var h := TerrainConfig.height_at(x, z)
	var sample := _env.sample(Vector3(float(x), float(h), float(z)))
	return _material.resolve_state(_material.get_default_state(), sample)

## Library/mesher block id for the surface voxel at column (x, z): grass or snow.
static func block_id_at(x: int, z: int) -> int:
	return surface_state(x, z).block_id
