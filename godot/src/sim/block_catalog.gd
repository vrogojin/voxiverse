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
	# mass (kg / 1 m³ voxel), break_force (N), swatch/solid colour, structural
	# anchors (P,H,D) + class. Masses per the §12 addendum ordering: stone
	# heaviest, wood lightest. Anchors/classes are the calibrated core values
	# (STRUCTURAL-INTEGRITY §2.4, INTEGRATION-DECISIONS §1.2/§1.3) and are ASSERTED
	# against assets/blocks.json (WGC §3.1 "consts asserted against data").
	_states[GRASS] = _make(GRASS, &"grass", 750.0, 800.0, Color(0.30, 0.55, 0.24), Vector3i(4, 2, 1), &"soil")
	_states[DIRT] = _make(DIRT, &"dirt", 900.0, 900.0, Color(0.45, 0.31, 0.18), Vector3i(4, 2, 1), &"soil")
	_states[STONE] = _make(STONE, &"stone", 1500.0, 2500.0, Color(0.52, 0.52, 0.55), Vector3i(64, 6, 4), &"rock")
	_states[WOOD] = _make(WOOD, &"wood", 80.0, 600.0, Color(0.62, 0.44, 0.26), Vector3i(36, 24, 16), &"timber")
	_states[LEAF] = _make(LEAF, &"leaf", 100.0, 100.0, Color(0.13, 0.42, 0.12), Vector3i(4, 3, 2), &"foliage")

static func _make(block_id: int, state_name: StringName, mass: float,
		break_force: float, swatch: Color, strength_anchors := Vector3i(1, 1, 1),
		structural_class := &"rock") -> VoxelState:
	var s := VoxelState.new()
	s.state_name = state_name
	s.block_id = block_id
	s.mass = mass
	s.density = mass
	s.break_force = break_force
	s.tint = swatch
	s.strength_anchors = strength_anchors
	s.structural_class = structural_class
	# attachment stays at VoxelState's 1.0 default (joint participation multiplier);
	# only sand/gravel will ship 0.0 once they enter the catalog (§1.4).
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

## Material solidity (0 = passable like air, 1 = full solid block) for `block_id` —
## the GATE of the merged analytic-physics contract (INTEGRATION-DECISIONS §3): a
## cell contributes collision geometry iff `solidity_of(mat) >= 0.5`. AIR and any
## out-of-range id have no VoxelState → 0.0 (non-solid); every core material → 1.0.
## Future fluids (water/lava/powder_snow) ship solidity < 0.5 and drop out here.
static func solidity_of(block_id: int) -> float:
	var s := state_of(block_id)
	return s.solidity if s != null else 0.0

## Render cull-group / transparency index (WGC §5.2, INTEGRATION-DECISIONS §3):
## 0 = fully opaque, higher = more transparent. Composed by `WorldManager.occludes_face`:
## an opaque neighbour always occludes; a translucent neighbour occludes only cells
## of the same-or-higher transparency group (glass-behind-glass culls, but
## glass-behind-stone does not). Derived from the material's `translucence`; AIR /
## out of range → a huge value (a null material never occludes anything). Every core
## material is opaque today (index 0), so occludes_face reduces to cell_solid.
static func transparency_index_of(block_id: int) -> int:
	var s := state_of(block_id)
	if s == null:
		return 0x7FFFFFFF
	return 0 if s.translucence <= 0.0 else 1

## Structural strength anchors `(P, H, D)` for `block_id`; Vector3i(0,0,0) for AIR.
static func anchors_of(block_id: int) -> Vector3i:
	var s := state_of(block_id)
	return s.strength_anchors if s != null else Vector3i.ZERO

## Structural class StringName for `block_id`; `&""` for AIR / out of range.
static func class_of(block_id: int) -> StringName:
	var s := state_of(block_id)
	return s.structural_class if s != null else &""

# ---------------------------------------------------------------------------
# blocks.json golden authoring source (WGC §3.1: consts asserted against data).
# The catalog above is the runtime source of truth; this data file is the
# authoring source P3 extends. `check_against_data()` proves they never diverge.

## The data-driven catalog authoring source (loaded only by verify / tooling —
## the runtime path reads the consts above, not this file).
const DATA_PATH := "res://assets/blocks.json"

## Parse blocks.json into an Array of record Dictionaries. Empty on failure
## (the caller reports "could not load"). Offline/verify only — never runtime.
static func load_data(path := DATA_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var txt := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("blocks"):
		return []
	var blocks: Variant = parsed["blocks"]
	return blocks if blocks is Array else []

## Assert the hardcoded core consts/values (ids, masses, anchors, class, swatch,
## break_force, attachment) match assets/blocks.json for the frozen core ids
## 0..COUNT-1. Returns a list of discrepancies; empty == the golden file agrees.
static func check_against_data(path := DATA_PATH) -> PackedStringArray:
	ensure_ready()
	var out := PackedStringArray()
	var records := load_data(path)
	if records.is_empty():
		out.append("could not load %s (or it has no `blocks` array)" % path)
		return out
	# Index by name so record order in the file does not have to match ours.
	var by_name := {}
	for rec: Variant in records:
		if rec is Dictionary and rec.has("name"):
			by_name[String(rec["name"])] = rec
	for id in range(COUNT):
		var nm := name_of(id)
		if not by_name.has(nm):
			out.append("blocks.json missing record for '%s' (id %d)" % [nm, id])
			continue
		var rec: Dictionary = by_name[nm]
		if int(rec.get("id", -1)) != id:
			out.append("'%s' id: json=%s const=%d" % [nm, str(rec.get("id")), id])
		if id == AIR:
			continue                          # air carries no state to compare
		var s := _states[id]
		if not is_equal_approx(float(rec.get("mass", -1.0)), s.mass):
			out.append("'%s' mass: json=%s catalog=%.3f" % [nm, str(rec.get("mass")), s.mass])
		if not is_equal_approx(float(rec.get("break_force", -1.0)), s.break_force):
			out.append("'%s' break_force: json=%s catalog=%.3f" % [nm, str(rec.get("break_force")), s.break_force])
		if String(rec.get("structural_class", "")) != String(s.structural_class):
			out.append("'%s' class: json=%s catalog=%s" % [nm, str(rec.get("structural_class")), s.structural_class])
		var a: Variant = rec.get("anchors", [])
		if not (a is Array and a.size() == 3
				and int(a[0]) == s.strength_anchors.x
				and int(a[1]) == s.strength_anchors.y
				and int(a[2]) == s.strength_anchors.z):
			out.append("'%s' anchors: json=%s catalog=%s" % [nm, str(a), str(s.strength_anchors)])
		if not is_equal_approx(float(rec.get("attachment", 1.0)), s.attachment):
			out.append("'%s' attachment: json=%s catalog=%.3f" % [nm, str(rec.get("attachment", 1.0)), s.attachment])
		var sw: Variant = rec.get("swatch", [])
		if sw is Array and sw.size() == 4:
			var c := Color(float(sw[0]), float(sw[1]), float(sw[2]), float(sw[3]))
			if not (is_equal_approx(c.r, s.tint.r) and is_equal_approx(c.g, s.tint.g)
					and is_equal_approx(c.b, s.tint.b) and is_equal_approx(c.a, s.tint.a)):
				out.append("'%s' swatch: json=%s catalog=%s" % [nm, str(c), str(s.tint)])
		else:
			out.append("'%s' swatch missing/!= rgba4: %s" % [nm, str(sw)])
	return out
