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
## `surface` material — a single data-driven material whose (currently one) grass
## state lives in SurfaceModel. More materials/states register the same way.
static func build_default() -> MaterialRegistry:
	var reg := MaterialRegistry.new()
	reg.register(SurfaceModel.material())
	return reg
