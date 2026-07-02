class_name VoxelStateTransition
extends Resource
## One edge of a material's state machine: "switch to `to_state` when an
## environment field crosses `threshold`". Kept deliberately tiny and data-only
## so the full engine (ice<->water<->steam driven by temperature, etc.) is just
## more of these resources — no new code in the mesher or environment.
##
## `field` names a key returned by PerVoxelEnvironment.sample(): one of
## "temperature", "light", "electric_current", "pressure", "gravity_magnitude".

enum Comparator { GREATER, GREATER_EQUAL, LESS, LESS_EQUAL }

@export var to_state: StringName = &""
@export var field: String = "temperature"
@export var comparator: Comparator = Comparator.LESS
@export var threshold: float = 0.0

## Does this transition fire for the given environment sample?
func is_triggered(sample: Dictionary) -> bool:
	if not sample.has(field):
		return false
	var v: float = sample[field]
	match comparator:
		Comparator.GREATER: return v > threshold
		Comparator.GREATER_EQUAL: return v >= threshold
		Comparator.LESS: return v < threshold
		Comparator.LESS_EQUAL: return v <= threshold
	return false
