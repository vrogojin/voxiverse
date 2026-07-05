class_name BlockCatalog
extends RefCounted
## Authoritative block-id table (DESIGN §1.1, WORLDGEN-CATALOG §3-§4). Everyone reads
## ids, masses, looks from here: physics reads masses, world/UI read ids/colors/names.
## Built on the VoxelState framework so the sim layer stays the source of truth.
##
## DATA-DRIVEN (WGC §4): `ensure_ready()` loads `assets/blocks.json` into the per-id
## VoxelState array — record order IS the dense id (APPEND-ONLY file). `count()` is
## derived from the data (77 today: `core` ids 0-5 + `world` ids 6-76). The frozen
## core consts below (AIR..LEAF, `CORE_COUNT`) are KEPT and ASSERTED against the loaded
## data (`_assert_frozen_core`), so a reorder/renumber of the core is a hard failure,
## not a silent recolour. The `extended` tier (WGC §3.1) streams ids in later (P6).
##
## Block ids are DENSE (0..count()-1) and shared by the godot_voxel blocky library
## (model index == id), the fallback mesher, the edit overlay, VoxelBody cells, and
## inventory stacks. The library-order invariant (module_world asserts each returned
## model id equals the id here, now over ALL ids) is the single most fragile coupling.

const AIR := 0
const GRASS := 1
const DIRT := 2
const STONE := 3
const WOOD := 4
const LEAF := 5
const CORE_COUNT := 6                 # frozen core ids 0..CORE_COUNT-1 (always loaded)

## The data-driven catalog authoring source (WGC §4). Loaded once by ensure_ready();
## also read by verify/tooling. Web export ships it (export_presets include_filter).
const DATA_PATH := "res://assets/blocks.json"

# Lazily-built VoxelStates indexed by block id. Index AIR stays null (air carries no
# state). Built on the main thread via ensure_ready() before any meshing/sim.
static var _states: Array[VoxelState] = []
static var _id_by_name: Dictionary = {}    # StringName -> int (name AND alias -> id)

## Idempotent; loads blocks.json and builds the per-id VoxelStates (main thread).
## Safe to call from SurfaceModel.ensure_ready() / module_world.setup() and repeatedly.
static func ensure_ready() -> void:
	if not _states.is_empty():
		return
	var records := load_data()
	if records.is_empty():
		# The live web demo is non-negotiable (CLAUDE.md): if the JSON failed to ship
		# or parse, fall back to the frozen core built in code so the world still loads,
		# and shout loudly so CI/verify catches the export misconfig.
		push_error("[BlockCatalog] could not load %s — falling back to frozen core only" % DATA_PATH)
		_build_core_fallback()
		return
	# Size by the highest id so the array is dense; ids are assigned by record order.
	var max_id := -1
	for rec: Variant in records:
		if rec is Dictionary and rec.has("id"):
			max_id = maxi(max_id, int(rec["id"]))
	_states.resize(max_id + 1)
	_id_by_name.clear()
	for rec: Variant in records:
		if not (rec is Dictionary and rec.has("id")):
			continue
		var id := int(rec["id"])
		var nm := String(rec.get("name", ""))
		_id_by_name[StringName(nm)] = id
		if rec.has("alias") and rec["alias"] != null:
			_id_by_name[StringName(String(rec["alias"]))] = id
		if id == AIR:
			_states[id] = null            # air carries no state
			continue
		_states[id] = _from_record(rec)
	_assert_frozen_core()

## Build one VoxelState from a blocks.json record. Missing break_force -> INF
## (bedrock/water/lava); missing render -> opaque (cull_group 0, no glow).
static func _from_record(rec: Dictionary) -> VoxelState:
	var s := VoxelState.new()
	s.state_name = StringName(String(rec.get("name", "?")))
	s.block_id = int(rec.get("id", -1))
	s.mass = float(rec.get("mass", 0.0))
	s.density = s.mass
	if rec.has("break_force"):
		s.break_force = float(rec["break_force"])
	# else: VoxelState default INF (unbreakable / fluid — outside the mining model)
	var sw: Variant = rec.get("swatch", [])
	if sw is Array and (sw as Array).size() >= 3:
		var a := float(sw[3]) if (sw as Array).size() >= 4 else 1.0
		s.tint = Color(float(sw[0]), float(sw[1]), float(sw[2]), a)
	var an: Variant = rec.get("anchors", [1, 1, 1])
	if an is Array and (an as Array).size() == 3:
		s.strength_anchors = Vector3i(int(an[0]), int(an[1]), int(an[2]))
	s.structural_class = StringName(String(rec.get("structural_class", "rock")))
	s.attachment = float(rec.get("attachment", 1.0))
	s.solidity = float(rec.get("solidity", 1.0))
	s.permeability = float(rec.get("permeability", 0.0))
	s.translucence = float(rec.get("translucence", 0.0))
	# Optional block-entity capability (VDS §3.1); default false. Read via .get like
	# every other optional key (alias/render/anchors_override) — no record bloat and
	# no material declares it yet, so gameplay + the drift gate are untouched.
	s.has_block_entity = bool(rec.get("has_block_entity", false))
	var rnd: Variant = rec.get("render", {})
	if rnd is Dictionary:
		s.cull_group = int((rnd as Dictionary).get("cull_group", 0))
		s.glow = float((rnd as Dictionary).get("emissive", 0.0))
		s.emission = s.glow
	return s

## Frozen-core tripwire (WGC §3.1 "consts asserted against data"): the loaded core
## ids/names/masses/anchors must match the hard-frozen values. A drift here means the
## file was reordered/renumbered or a core value was silently changed — fail loudly.
static func _assert_frozen_core() -> void:
	assert(_states.size() >= CORE_COUNT, "blocks.json has fewer than the %d core ids" % CORE_COUNT)
	assert(id_of(&"grass") == GRASS and id_of(&"dirt") == DIRT and id_of(&"stone") == STONE
		and id_of(&"wood") == WOOD and id_of(&"leaf") == LEAF,
		"core ids drifted from the frozen consts (blocks.json reorder?)")
	assert(id_of(&"oak_log") == WOOD and id_of(&"oak_leaves") == LEAF,
		"core aliases (oak_log/oak_leaves) do not resolve to the frozen ids")
	assert(is_equal_approx(mass_of(STONE), 1500.0) and is_equal_approx(mass_of(WOOD), 80.0)
		and is_equal_approx(mass_of(GRASS), 750.0),
		"core masses drifted from the frozen values")
	assert(anchors_of(STONE) == Vector3i(64, 6, 4) and anchors_of(WOOD) == Vector3i(36, 24, 16),
		"core anchors drifted from the frozen values")

## In-code frozen core, built only when blocks.json cannot be loaded (web export
## misconfig safety net). Mirrors the ids 0-5 rows of blocks.json exactly.
static func _build_core_fallback() -> void:
	_states.resize(CORE_COUNT)
	_id_by_name.clear()
	_states[AIR] = null
	_id_by_name[&"air"] = AIR
	_make(GRASS, &"grass", 750.0, 800.0, Color(0.30, 0.55, 0.24), Vector3i(4, 2, 1), &"soil")
	_make(DIRT, &"dirt", 900.0, 900.0, Color(0.45, 0.31, 0.18), Vector3i(4, 2, 1), &"soil")
	_make(STONE, &"stone", 1500.0, 2500.0, Color(0.52, 0.52, 0.55), Vector3i(64, 6, 4), &"rock")
	_make(WOOD, &"wood", 80.0, 600.0, Color(0.62, 0.44, 0.26), Vector3i(36, 24, 16), &"timber")
	_make(LEAF, &"leaf", 100.0, 100.0, Color(0.13, 0.42, 0.12), Vector3i(4, 3, 2), &"foliage")
	_id_by_name[&"oak_log"] = WOOD
	_id_by_name[&"oak_leaves"] = LEAF

static func _make(block_id: int, state_name: StringName, mass: float,
		break_force: float, swatch: Color, strength_anchors := Vector3i(1, 1, 1),
		structural_class := &"rock") -> void:
	var s := VoxelState.new()
	s.state_name = state_name
	s.block_id = block_id
	s.mass = mass
	s.density = mass
	s.break_force = break_force
	s.tint = swatch
	s.strength_anchors = strength_anchors
	s.structural_class = structural_class
	_states[block_id] = s
	_id_by_name[state_name] = block_id

## Total number of loaded block ids (dense 0..count()-1). Derived from the data (77
## for core+world today), NOT a hardcoded const — WGC §3.1/§4.
static func count() -> int:
	ensure_ready()
	return _states.size()

## Dense id for a material NAME or ALIAS StringName (WGC §4); -1 if unknown.
static func id_of(material_name: StringName) -> int:
	ensure_ready()
	return int(_id_by_name.get(material_name, -1))

## The VoxelState for `block_id`; null for AIR or out of range.
static func state_of(block_id: int) -> VoxelState:
	ensure_ready()
	if block_id <= AIR or block_id >= _states.size():
		return null
	return _states[block_id]

## Mass in kg for one voxel of `block_id`; 0.0 for AIR / out of range.
static func mass_of(block_id: int) -> float:
	var s := state_of(block_id)
	return s.mass if s != null else 0.0

## Mass in kg of a PACKED cell value (SUB-VOXEL-SMOOTHING §6): the full-cube mass
## scaled by the shape's fill fraction, `density × volume(modifier)`. A full-cube
## value (modifier 0) is exactly `mass_of(mat)`, so this is byte-identical for the
## current world; a stone RAMP (volume ½) weighs half a full stone cube. Used by
## VoxelBody._rebuild and anything mass-aware about partial cells.
static func mass_of_value(packed: int) -> float:
	var m := mass_of(CellCodec.mat(packed))
	var modifier := CellCodec.modifier(packed)
	if modifier == 0:
		return m
	return m * ShapeCodec.volume(modifier)

## Swatch / solid-material colour (with alpha) for `block_id` (hotbar UI + solid
## materials). Returns opaque black for AIR / out of range (callers guard AIR).
static func color_of(block_id: int) -> Color:
	var s := state_of(block_id)
	return s.tint if s != null else Color(0, 0, 0)

## Human-readable material name ("grass", "dirt", … "air").
static func name_of(block_id: int) -> String:
	if block_id == AIR:
		return "air"
	var s := state_of(block_id)
	return String(s.state_name) if s != null else "air"

## True for any non-air block id within range (a VALID placeable id, NOT a solidity
## test — solidity is `solidity_of`).
static func is_solid_id(block_id: int) -> bool:
	return block_id > AIR and block_id < count()

## Material solidity (0 = passable like air, 1 = full solid block) for `block_id` —
## the GATE of the merged analytic-physics contract (INTEGRATION-DECISIONS §3): a cell
## contributes collision geometry iff `solidity_of(mat) >= 0.5`. AIR / out-of-range →
## 0.0 (non-solid); fluids (water/lava) and powder_snow ship solidity < 0.5.
static func solidity_of(block_id: int) -> float:
	var s := state_of(block_id)
	return s.solidity if s != null else 0.0

## Render cull-group / transparency index (WGC §5.1, INTEGRATION-DECISIONS §3):
## 0 = fully opaque, higher = more transparent. Mapped 1:1 onto the godot_voxel blocky
## `transparency_index` and mirrored by `WorldManager.occludes_face`. Read from the
## material's `cull_group` (blocks.json render block). AIR / out of range → a huge value
## (a null material never occludes anything). Every core material is opaque (0).
static func transparency_index_of(block_id: int) -> int:
	var s := state_of(block_id)
	if s == null:
		return 0x7FFFFFFF
	return s.cull_group

## Alias of `transparency_index_of` under the WGC §3.3 "cull group" name.
static func cull_group_of(block_id: int) -> int:
	return transparency_index_of(block_id)

## Render description for `block_id`: {mode, cull_group, emissive, alpha, translucent,
## emissive_glow}. Consumed by BlockMaterials to build opaque/translucent/emissive
## materials without re-deriving the rules. Empty for AIR / out of range.
static func render_def_of(block_id: int) -> Dictionary:
	var s := state_of(block_id)
	if s == null:
		return {}
	var translucent := s.cull_group > 0
	var mode := "translucent" if translucent else ("emissive" if s.glow > 0.0 else "opaque")
	return {
		"mode": mode,
		"cull_group": s.cull_group,
		"translucent": translucent,
		"emissive": s.glow > 0.0,
		"emissive_glow": s.glow,
		"alpha": s.tint.a,
	}

## Structural strength anchors `(P, H, D)` for `block_id`; Vector3i(0,0,0) for AIR.
static func anchors_of(block_id: int) -> Vector3i:
	var s := state_of(block_id)
	return s.strength_anchors if s != null else Vector3i.ZERO

## Structural class StringName for `block_id`; `&""` for AIR / out of range.
static func class_of(block_id: int) -> StringName:
	var s := state_of(block_id)
	return s.structural_class if s != null else &""

## True iff `block_id` may carry per-cell METADATA (VDS §3.1). AIR / out of range →
## false (null state). The GATE of `WorldManager.set_metadata`: writing metadata to a
## material that returns false here is a validation error. Default false for every
## shipped material (no block entities in the catalog yet).
static func has_block_entity(block_id: int) -> bool:
	var s := state_of(block_id)
	return s != null and s.has_block_entity

# ---------------------------------------------------------------------------
# blocks.json parsing + the golden "consts asserted against data" check.

## Parse blocks.json into an Array of record Dictionaries. Empty on failure (the
## caller reports "could not load").
static func load_data(path := DATA_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var txt := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("blocks"):
		return []
	var blocks: Variant = parsed["blocks"]
	return blocks if blocks is Array else []

## Assert the frozen core consts/values (ids, masses, anchors, class, swatch,
## break_force, attachment) match assets/blocks.json for the frozen core ids
## 0..CORE_COUNT-1. Returns a list of discrepancies; empty == the golden file agrees.
## (Since ensure_ready now loads FROM the file, this is a redundant tripwire that also
## guards the fallback-built core and any offline edit that skipped a re-verify.)
static func check_against_data(path := DATA_PATH) -> PackedStringArray:
	ensure_ready()
	var out := PackedStringArray()
	var records := load_data(path)
	if records.is_empty():
		out.append("could not load %s (or it has no `blocks` array)" % path)
		return out
	var by_name := {}
	for rec: Variant in records:
		if rec is Dictionary and rec.has("name"):
			by_name[String(rec["name"])] = rec
	for id in range(CORE_COUNT):
		var nm := name_of(id)
		if not by_name.has(nm):
			out.append("blocks.json missing record for '%s' (id %d)" % [nm, id])
			continue
		var rec: Dictionary = by_name[nm]
		if int(rec.get("id", -1)) != id:
			out.append("'%s' id: json=%s const=%d" % [nm, str(rec.get("id")), id])
		if id == AIR:
			continue
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
