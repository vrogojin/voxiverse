class_name MaterialRegistry
extends RefCounted
## Holds every VoxelMaterialDef known to the world, keyed by id. Built in code
## for now (one material: grass); later this is where authored .tres materials
## get registered. Kept separate from rendering and from the environment so new
## materials drop in without touching either.

var _by_id := {}  # StringName -> VoxelMaterialDef

func register(def: VoxelMaterialDef) -> void:
	_by_id[def.id] = def

func get_material(id: StringName) -> VoxelMaterialDef:
	return _by_id.get(id, null)

func has(id: StringName) -> bool:
	return _by_id.has(id)

## Build the default registry for the grass test environment.
static func build_default() -> MaterialRegistry:
	var reg := MaterialRegistry.new()
	reg.register(_make_grass())
	return reg

static func _make_grass() -> VoxelMaterialDef:
	var default_state := VoxelState.new()
	default_state.state_name = &"default"
	default_state.mass = 1500.0
	default_state.density = 1500.0
	default_state.break_force = INF          # unbreakable (DESIGN §1)
	default_state.attachment = 1.0
	default_state.permeability = 0.05
	default_state.albedo = 0.25
	default_state.translucence = 0.0
	default_state.emission = 0.0
	default_state.solidity = 1.0
	default_state.texture = load(GrassMaterial.TEXTURE_PATH) as Texture2D
	default_state.tint = Color.WHITE
	default_state.glow = 0.0

	# --- Extensibility demonstration (inert today) ------------------------------
	# Grass ships as a single static state. To show the state machine is real and
	# not vestigial, here is exactly how a temperature-driven transition would be
	# authored — commented out so grass stays static per the spec:
	#
	#   var frost := VoxelStateTransition.new()
	#   frost.field = "temperature"
	#   frost.comparator = VoxelStateTransition.Comparator.LESS
	#   frost.threshold = 0.0                 # below 0 C -> frosted grass
	#   frost.to_state = &"frosted"
	#   default_state.transitions.append(frost)
	#   ...plus a second VoxelState named "frosted" added to `states`.

	var grass := VoxelMaterialDef.new()
	grass.id = &"grass"
	grass.states = [default_state]
	grass.default_state_index = 0
	return grass
