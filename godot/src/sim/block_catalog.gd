class_name BlockCatalog
extends RefCounted
## Authoritative block-id table (DESIGN §1.1). Everyone reads ids, masses, looks
## from here: physics reads masses, world/UI read ids/colors/names. Built on the
## existing VoxelState framework so the sim layer stays the source of truth.
##
## Block ids are DENSE (0..COUNT-1) and shared by the godot_voxel blocky library
## (model index == id), the fallback mesher, the edit overlay, VoxelBody cells,
## and inventory stacks. The library-order invariant (module_world asserts each
## returned model id equals the const here) is the single most fragile coupling —
## a swap silently recolours the world — so these consts are the one place ids
## live.

const AIR := 0
const GRASS := 1
const DIRT := 2
const STONE := 3
const WOOD := 4
const LEAF := 5
const COUNT := 6                      # ids are 0..COUNT-1, dense

# Lazily-built VoxelStates indexed by block id. Index AIR stays null (air carries
# no state). Built on the main thread via ensure_ready() before any meshing/sim.
static var _states: Array[VoxelState] = []

## Idempotent; builds the per-id VoxelStates (main thread). Safe to call from
## SurfaceModel.ensure_ready() and repeatedly (same pattern as SurfaceModel).
static func ensure_ready() -> void:
	if not _states.is_empty():
		return
	_states.resize(COUNT)
	_states[AIR] = null
	# mass (kg / 1 m³ voxel), break_force (N), swatch/solid colour. Masses per the
	# §12 addendum ordering: stone heaviest, wood lightest.
	_states[GRASS] = _make(GRASS, &"grass", 750.0, 800.0, Color(0.30, 0.55, 0.24))
	_states[DIRT] = _make(DIRT, &"dirt", 900.0, 900.0, Color(0.45, 0.31, 0.18))
	_states[STONE] = _make(STONE, &"stone", 1500.0, 2500.0, Color(0.52, 0.52, 0.55))
	_states[WOOD] = _make(WOOD, &"wood", 80.0, 600.0, Color(0.62, 0.44, 0.26))
	_states[LEAF] = _make(LEAF, &"leaf", 100.0, 100.0, Color(0.13, 0.42, 0.12))

static func _make(block_id: int, state_name: StringName, mass: float,
		break_force: float, swatch: Color) -> VoxelState:
	var s := VoxelState.new()
	s.state_name = state_name
	s.block_id = block_id
	s.mass = mass
	s.density = mass
	s.break_force = break_force
	s.tint = swatch
	return s

## The VoxelState for `block_id`; null for AIR or out of range.
static func state_of(block_id: int) -> VoxelState:
	ensure_ready()
	if block_id <= AIR or block_id >= COUNT:
		return null
	return _states[block_id]

## Mass in kg for one voxel of `block_id`; 0.0 for AIR / out of range.
static func mass_of(block_id: int) -> float:
	var s := state_of(block_id)
	return s.mass if s != null else 0.0

## Swatch / solid-material colour for `block_id` (hotbar UI + solid materials).
## Returns opaque black for AIR / out of range (callers guard AIR themselves).
static func color_of(block_id: int) -> Color:
	var s := state_of(block_id)
	return s.tint if s != null else Color(0, 0, 0)

## Human-readable material name ("grass", "dirt", … "air").
static func name_of(block_id: int) -> String:
	if block_id == AIR:
		return "air"
	var s := state_of(block_id)
	return String(s.state_name) if s != null else "air"

## True for any non-air block id within range.
static func is_solid_id(block_id: int) -> bool:
	return block_id > AIR and block_id < COUNT
