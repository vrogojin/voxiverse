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

## Build the default registry for the test environment. Registers the ground
## `surface` material (whose grass state lives in SurfaceModel) PLUS one
## data-driven material per BlockCatalog entry (id = the block name StringName,
## single state), so the registry knows every block material. More materials/
## states register the same way.
static func build_default() -> MaterialRegistry:
	var reg := MaterialRegistry.new()
	reg.register(SurfaceModel.material())
	BlockCatalog.ensure_ready()
	for block_id in range(1, BlockCatalog.count()):
		var state: VoxelState = BlockCatalog.state_of(block_id)
		if state == null:
			continue
		var def := VoxelMaterialDef.new()
		def.id = state.state_name
		def.states = [state]
		def.default_state_index = 0
		reg.register(def)
	return reg
