class_name VoxelMaterialDef
extends Resource
## Data-driven definition of a voxel material (DESIGN §3). A material is an id
## plus one or more VoxelStates and the machinery to pick the current state from
## the environment. Ships with one instance now — `grass` — but adding water,
## ice, snow, lava, … is purely authoring new resources of this type.

@export var id: StringName = &"grass"
## All states this material can be in. `states[default_state_index]` is the
## state a freshly-placed voxel starts in.
@export var states: Array[VoxelState] = []
@export var default_state_index: int = 0

func get_default_state() -> VoxelState:
	if states.is_empty():
		return null
	return states[clampi(default_state_index, 0, states.size() - 1)]

func get_state_by_name(name: StringName) -> VoxelState:
	for s in states:
		if s.state_name == name:
			return s
	return null

## Resolve which state a voxel should be in given an environment sample and its
## current state. Evaluates the current state's transitions; first triggered
## transition wins. Returns the (possibly unchanged) state. This is THE state
## machine — grass simply has no transitions today, so it never changes, but the
## mechanism is exercised for every material uniformly.
func resolve_state(current: VoxelState, sample: Dictionary) -> VoxelState:
	if current == null:
		return get_default_state()
	for t in current.transitions:
		if t.is_triggered(sample):
			var next := get_state_by_name(t.to_state)
			if next != null:
				return next
	return current
