class_name BlockCatalog
extends RefCounted
## Authoritative block-id table (DESIGN §1.1, WORLDGEN-CATALOG §3-§4). Everyone reads
## ids, masses, looks from here: physics reads masses, world/UI read ids/colors/names.
## Built on the VoxelState framework so the sim layer stays the source of truth.
##
## DYNAMIC CATALOG behind a STATIC FACADE (RUNTIME-MATERIAL-STREAMING §6.1): the fixed
## per-id arrays are now a session table keyed by GMID (RMS §2.4) with an APPEND-ONLY
## LRID counter — materials can be registered at runtime (`register_material`) without a
## restart. The query API below (`state_of`/`mass_of`/`color_of`/`name_of`/`is_solid_id`/
## `id_of`/`solidity_of`/`anchors_of`/`class_of`/`has_block_entity`/`count`) keeps its
## EXACT signatures, so the rule "everyone reads ids/masses/looks from BlockCatalog"
## survives untouched — callers cannot tell the catalog grew.
##
## IDENTITY (RMS §2): a Local Render ID (LRID, the dense int callers use) is allocated
## per (material, state) and NEVER recycled/reordered in a session (F4/§7.4). A Global
## Material ID (GMID, content hash of the material document) is the cross-session/peer
## identity; LRIDs never travel, GMIDs do. `_by_key` maps "<gmid>#<state>" → LRID.
##
## BOOTSTRAP SET (RMS §2.5): today's core+world materials from `assets/blocks.json` are
## registered first thing at `ensure_ready()` IN DENSE ID ORDER, pinning their LRIDs to
## exactly today's ids (0..76) — the frozen core consts (AIR..LEAF, `CORE_COUNT`) are
## KEPT and ASSERTED against the loaded data (`_assert_frozen_core`), so a reorder/
## renumber is a hard failure, not a silent recolour. AIR==0 is a permanent reserved
## LRID (air is absence — no document; its key is the literal "air").
##
## Block ids are DENSE (0..count()-1) and shared by the godot_voxel blocky library
## (model index == id for the bootstrap set), the fallback mesher, the edit overlay,
## VoxelBody cells, and inventory stacks. The library-order invariant is the single most
## fragile coupling.

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

## Fixed session-table capacity = the 16-bit TYPE-channel ceiling (godot_voxel
## MAX_MODELS, RMS F1/F6). The table arrays are preallocated to this ONCE and never
## resized, so a growing catalog never reallocates under a concurrent worker-thread
## reader (RMS §6.1 publish-before-use discipline); `_count` is published only after a
## row is fully built.
const CAPACITY := 65536

## Per-LRID resolution status (RMS §7.1/§8): a RESOLVED row has real physics+look; an
## UNRESOLVED row is a placeholder registered under a known GMID whose document has not
## arrived yet (magenta look, default physics) — world data round-trips losslessly and
## late-resolution fills the SAME LRID in place.
enum { RESOLVED = 0, UNRESOLVED = 1 }

# --- session table (index == LRID; entry 0 is reserved AIR) ---------------------
static var _ready := false
static var _count := 0                              # published dense count (0..count()-1)
static var _states: Array[VoxelState] = []          # LRID -> VoxelState (null for AIR)
static var _keys: PackedStringArray = PackedStringArray()   # LRID -> "<gmid>#<state>" ("air" for AIR)
static var _defs: Array[VoxelMaterialDef] = []      # LRID -> owning material def (null for AIR)
static var _status: PackedByteArray = PackedByteArray()     # LRID -> RESOLVED | UNRESOLVED
static var _by_key: Dictionary = {}                 # "<gmid>#<state>" -> int LRID (reverse index)
static var _id_by_name: Dictionary = {}             # StringName -> int (name AND alias -> LRID)
static var _lrid_by_liquid_kind: Dictionary = {}    # CellCodec liquid kind -> LRID (reverse map, first-declared wins; MULTI-LIQUID §2.1)
static var _state_mask: PackedInt32Array = PackedInt32Array()   # LRID -> STATE-axis mask (low state_layout.size() bits; 0xFFFF for an UNRESOLVED placeholder)

## Idempotent; preallocates the table and registers the bootstrap set from blocks.json
## (main thread). Safe to call from SurfaceModel.ensure_ready() / module_world.setup()
## and repeatedly. `_ready` is set BEFORE registering so the re-entrant ensure_ready()
## inside register_material is a no-op (no recursion).
static func ensure_ready() -> void:
	if _ready:
		return
	_ready = true
	_init_table()
	var records := load_data()
	if records.is_empty():
		# The live web demo is non-negotiable (CLAUDE.md): if the JSON failed to ship
		# or parse, fall back to the frozen core built in code so the world still loads,
		# and shout loudly so CI/verify catches the export misconfig.
		push_error("[BlockCatalog] could not load %s — falling back to frozen core only" % DATA_PATH)
		_build_core_fallback()
		return
	# Register in DENSE ID ORDER so each bootstrap LRID lands exactly on today's id.
	var by_id := {}
	var max_id := -1
	for rec: Variant in records:
		if rec is Dictionary and rec.has("id"):
			by_id[int(rec["id"])] = rec
			max_id = maxi(max_id, int(rec["id"]))
	for id in range(0, max_id + 1):
		if id == AIR:
			_append_air()
			continue
		if not by_id.has(id):
			push_error("[BlockCatalog] blocks.json has a hole at id %d (dense catalog requires contiguous ids)" % id)
			continue
		var rec: Dictionary = by_id[id]
		var st := _from_record(rec)
		var alias: StringName = &""
		if rec.has("alias") and rec["alias"] != null:
			alias = StringName(String(rec["alias"]))
		# Optional STATE-axis layout (VDS §10.3, M1): a "state_layout" name list on the record
		# declares the material's ordered state bits (empty for all but grass/podzol/sand/stone).
		var layout: Array[StringName] = []
		var lr: Variant = rec.get("state_layout", [])
		if lr is Array:
			for nm: Variant in lr:
				layout.append(StringName(String(nm)))
		var lrid := _register_bootstrap_state(st, alias, layout)
		assert(lrid == id, "bootstrap LRID %d != id %d (append order broke)" % [lrid, id])
	_assert_frozen_core()
	_build_liquid_index()

## Session-boundary reset (RMS §2.6): drop the entire session table and re-register the
## bootstrap set, modelling a DISTINCT process/peer/world-load that allocates dense LRIDs
## from scratch — so the same GMIDs registered in a different order land on DIFFERENT dense
## LRIDs than another session did. This is exactly the boundary a zone bundle must survive:
## dense ids never travel, GMIDs do (RMS §2.1). GAMEPLAY NEVER CALLS THIS — LRIDs are never
## recycled/reordered mid-session (§7.4); it exists for world-load / peer-session boundaries
## and the zone-bundle round-trip proof. Also clears BlockMaterials' per-LRID render cache so
## a reused dense id never keeps a stale look from the previous session (§5.3).
static func reset_session() -> void:
	_ready = false
	BlockMaterials.reset_cache()
	ensure_ready()

## Reset + preallocate the session table (once). Fixed-capacity arrays never resized
## again (RMS §6.1).
static func _init_table() -> void:
	_count = 0
	_lrid_by_liquid_kind.clear()                    # re-resolve per session (LRIDs may differ, RMS §2.6)
	_by_key.clear()
	_id_by_name.clear()
	_states.resize(CAPACITY)
	_defs.resize(CAPACITY)
	_keys.resize(CAPACITY)
	_status.resize(CAPACITY)
	_state_mask.resize(CAPACITY)                     # zero-filled: AIR + every non-stated LRID → mask 0

## Reserve LRID 0 for AIR: null state, literal "air" key/name, no document (RMS §2.5).
static func _append_air() -> void:
	_states[AIR] = null
	_defs[AIR] = null
	_keys[AIR] = "air"
	_status[AIR] = RESOLVED
	_by_key["air"] = AIR
	_id_by_name[&"air"] = AIR
	_count = 1

## Build a single-state material def around `st`, hash its document to a GMID, and
## register it (bootstrap path). Also maps the optional alias to the new LRID.
static func _register_bootstrap_state(st: VoxelState, alias: StringName, layout: Array[StringName] = []) -> int:
	var def := VoxelMaterialDef.new()
	def.id = st.state_name
	def.states = [st]
	def.default_state_index = 0
	def.state_layout = layout                        # STATE-axis bit names (feeds the GMID + state_mask)
	var gmid := MaterialDocument.gmid_of(MaterialDocument.to_document(def))
	var lrid := register_material(gmid, def)
	if alias != &"" and lrid > 0:
		_id_by_name[alias] = lrid
	return lrid

# ---------------------------------------------------------------------------
# Runtime registration (RMS §6.1) — the append-only heart of streaming.

## Register a material's states behind the static facade, one LRID per (gmid, state) in
## document order (RMS §2.3/§6.1). Returns the LRID of the material's DEFAULT state (the
## id a freshly-placed cell of this material carries). APPEND-ONLY and IDEMPOTENT:
## re-registering an already-present (gmid, state) reuses its LRID and changes nothing.
## LATE RESOLUTION (RMS §8): if the (gmid, state) exists as an UNRESOLVED placeholder,
## the real state fills that SAME LRID in place (physics/look become real, id unchanged).
static func register_material(gmid: StringName, def: VoxelMaterialDef) -> int:
	ensure_ready()
	if def == null or def.states.is_empty():
		return -1
	var default_name := ""
	var ds := def.get_default_state()
	if ds != null:
		default_name = String(ds.state_name)
	var default_lrid := -1
	for st: VoxelState in def.states:
		var key := _key(gmid, st.state_name)
		var lrid: int
		if _by_key.has(key):
			lrid = int(_by_key[key])
			if _status[lrid] == UNRESOLVED:
				# Late resolution: fill the placeholder LRID in place — no new id.
				st.block_id = lrid
				_states[lrid] = st
				_defs[lrid] = def
				_status[lrid] = RESOLVED
				_state_mask[lrid] = _layout_mask(def)    # placeholder 0xFFFF → the real layout mask
				_register_name(def.id, lrid)
				_register_name(st.state_name, lrid)
				BlockMaterials.refresh(lrid)         # swap the placeholder look in place (§5.3)
			# else: already resolved — idempotent, leave untouched.
		else:
			lrid = _append(key, st, def, RESOLVED)
			_register_name(def.id, lrid)
			_register_name(st.state_name, lrid)
		if String(st.state_name) == default_name:
			default_lrid = lrid
	if default_lrid < 0 and not def.states.is_empty():
		default_lrid = int(_by_key.get(_key(gmid, def.states[0].state_name), -1))
	return default_lrid

## Register an UNRESOLVED placeholder LRID for a known (gmid, state) whose document is
## not available (RMS §8): default physics (mass 1000, break_force 1000, solidity 1),
## magenta look — so world data referencing this GMID loads losslessly (cells keep their
## true identity) and late-resolution can fill the SAME LRID. Idempotent.
static func register_placeholder(gmid: StringName, state_name: StringName) -> int:
	ensure_ready()
	var key := _key(gmid, state_name)
	if _by_key.has(key):
		return int(_by_key[key])
	var st := _make_placeholder_state(state_name)
	var def := VoxelMaterialDef.new()
	def.id = state_name
	def.states = [st]
	def.default_state_index = 0
	var lrid := _append(key, st, def, UNRESOLVED)
	_register_name(state_name, lrid)
	return lrid

## Append one (state) row at the next free LRID and PUBLISH the count last (RMS §6.1).
## Sets state.block_id to the allocated LRID (its look id, shared by both render paths).
static func _append(key: String, st: VoxelState, def: VoxelMaterialDef, status: int) -> int:
	var lrid := _count
	if lrid >= CAPACITY:
		push_error("[BlockCatalog] session catalog full (%d) — refusing further registrations" % CAPACITY)
		return -1
	st.block_id = lrid
	_states[lrid] = st
	_defs[lrid] = def
	_keys[lrid] = key
	_status[lrid] = status
	# STATE-axis mask (M1): the low state_layout.size() bits, or 0xFFFF for an UNRESOLVED
	# placeholder whose layout is unknown — permissive so bits loaded from a zone bundle survive
	# until the real document resolves (RMS §8 losslessness). Set BEFORE publishing _count.
	_state_mask[lrid] = 0xFFFF if status == UNRESOLVED else _layout_mask(def)
	_by_key[key] = lrid
	_count = lrid + 1                                # publish AFTER the row is fully built
	return lrid

## The magenta-checker default state of an UNRESOLVED placeholder (RMS §8).
static func _make_placeholder_state(state_name: StringName) -> VoxelState:
	var s := VoxelState.new()
	s.state_name = state_name
	s.mass = 1000.0
	s.density = 1000.0
	s.break_force = 1000.0
	s.solidity = 1.0
	s.tint = Color(1.0, 0.0, 1.0, 1.0)              # magenta — the universal "missing" swatch
	s.structural_class = &"rock"
	s.strength_anchors = Vector3i(1, 1, 1)
	return s

## The "<gmid>#<state>" reverse-index key (RMS §2.3).
static func _key(gmid: StringName, state_name: StringName) -> String:
	return "%s#%s" % [String(gmid), String(state_name)]

## Map a name/alias to an LRID, first-writer-wins so a streamed material can never
## clobber a bootstrap name (aliases are non-authoritative, RMS §2.2).
static func _register_name(nm: StringName, lrid: int) -> void:
	if nm != &"" and not _id_by_name.has(nm):
		_id_by_name[nm] = lrid

# ---------------------------------------------------------------------------

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
	# Optional liquid identity (MULTI-LIQUID §2.1): a "liquid_kind" NAME ("water"/"lava")
	# resolves through CellCodec's authoritative name→value map to the LIQ_KIND int stored on
	# VoxelState.liquid_kind (0 when absent). A non-empty unknown name warns and stays 0 — only
	# liquid records carry this key, so every solid keeps liquid_kind 0 (no record bloat).
	var lk_name := String(rec.get("liquid_kind", ""))
	if lk_name != "":
		var k := int(CellCodec.LIQ_KIND_BY_NAME.get(StringName(lk_name), CellCodec.LIQ_NONE))
		if k == CellCodec.LIQ_NONE:
			push_warning("[BlockCatalog] '%s' declares unknown liquid_kind '%s' — ignored" % [s.state_name, lk_name])
		s.liquid_kind = k
	var rnd: Variant = rec.get("render", {})
	if rnd is Dictionary:
		s.cull_group = int((rnd as Dictionary).get("cull_group", 0))
		s.glow = float((rnd as Dictionary).get("emissive", 0.0))
		s.emission = s.glow
	# Optional STATE-axis transitions (VDS §10.3, M1): the same shape MaterialDocument parses,
	# reusing its comparator map. A "to_state" that names a state_layout bit SETS that bit (the
	# STATE machine's evaluator resolves it); an own-state-name target clears the layout bits.
	# Only cappable materials carry this, so every other state's transitions stay empty.
	var trs: Variant = rec.get("transitions", [])
	if trs is Array:
		for traw: Variant in trs:
			if not (traw is Dictionary):
				continue
			var t := VoxelStateTransition.new()
			t.to_state = StringName(String((traw as Dictionary).get("to", "")))
			t.field = String((traw as Dictionary).get("field", "temperature"))
			t.comparator = MaterialDocument._str_to_cmp(String((traw as Dictionary).get("cmp", "<")))
			t.threshold = float((traw as Dictionary).get("threshold", 0.0))
			s.transitions.append(t)
	return s

## Frozen-core tripwire (WGC §3.1 "consts asserted against data"): the loaded core
## ids/names/masses/anchors must match the hard-frozen values. A drift here means the
## file was reordered/renumbered or a core value was silently changed — fail loudly.
static func _assert_frozen_core() -> void:
	assert(_count >= CORE_COUNT, "blocks.json has fewer than the %d core ids" % CORE_COUNT)
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
## misconfig safety net). Mirrors the ids 0-5 rows of blocks.json exactly — registered
## through the SAME dynamic path so LRIDs still land on the frozen consts.
static func _build_core_fallback() -> void:
	_append_air()
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
	s.mass = mass
	s.density = mass
	s.break_force = break_force
	s.tint = swatch
	s.strength_anchors = strength_anchors
	s.structural_class = structural_class
	var lrid := _register_bootstrap_state(s, &"")
	assert(lrid == block_id, "fallback-core LRID %d != id %d" % [lrid, block_id])

## Total number of live block ids (dense 0..count()-1). Derived from the session table
## (77 for core+world at start; grows as materials stream in) — WGC §3.1/§4, RMS §6.1.
static func count() -> int:
	ensure_ready()
	return _count

## Dense id for a material NAME or ALIAS StringName (WGC §4); -1 if unknown.
static func id_of(material_name: StringName) -> int:
	ensure_ready()
	return int(_id_by_name.get(material_name, -1))

## The VoxelState for `block_id`; null for AIR or out of range.
static func state_of(block_id: int) -> VoxelState:
	ensure_ready()
	if block_id <= AIR or block_id >= _count:
		return null
	return _states[block_id]

## The owning VoxelMaterialDef for `lrid` (shared across its states); null for AIR / out of
## range. Used by the zone-bundle writer to reconstruct a material's document (RMS §5) when
## its exact bytes are not held in the content store — `to_document(def_of(lrid))` reproduces
## the byte-identical document, hence the same GMID (RMS §2.2).
static func def_of(lrid: int) -> VoxelMaterialDef:
	ensure_ready()
	if lrid <= AIR or lrid >= _count:
		return null
	return _defs[lrid]

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

## The STATE-axis MASK for `lrid` (M1 snowy-world, VDS §10.3): the set of valid STATE bits for
## this material — the low `state_layout.size()` bits (O(1), filled per-LRID at registration).
## Two edge rules: AIR / out-of-range → 0 (air never carries state); an UNRESOLVED placeholder →
## 0xFFFF (permissive — its layout is unknown, so stripping would lose bits loaded before late
## resolution; render falls back to the plain look, the real mask governs after resolution). The
## codec's `_validate_state` masks a cell's raw state bits against this; the snow-cap worldgen
## predicate gates on `state_mask_of(mat) & STATE_SNOW_CAPPED` (catalog declaration is the one
## authority, so stone is accepted-but-never-produced without a second list). Worker-safe: the
## backing array is fixed-capacity (never resized), so a concurrent reader never races a realloc.
static func state_mask_of(lrid: int) -> int:
	ensure_ready()
	if lrid <= AIR or lrid >= _count:
		return 0
	return _state_mask[lrid]

## The STATE-axis mask a resolved def declares: the low `state_layout.size()` bits.
static func _layout_mask(def: VoxelMaterialDef) -> int:
	if def == null:
		return 0
	var n := def.state_layout.size()
	return ((1 << n) - 1) if n > 0 else 0

## Liquid identity of a material (MULTI-LIQUID §2.1): the CellCodec LIQ_KIND value this
## material declares (water → LIQ_WATER, lava → LIQ_LAVA, …), LIQ_NONE for every non-liquid.
## Data-driven from VoxelState.liquid_kind (parsed from the blocks.json "liquid_kind" key).
## CellCodec._canonical_liquid rule 5 uses it to gate which liquid a non-solid host may carry.
static func liquid_kind_of(block_id: int) -> int:
	var s := state_of(block_id)
	return s.liquid_kind if s != null else CellCodec.LIQ_NONE

## The LRID whose material declares liquid kind `kind` (the reverse of liquid_kind_of),
## or -1 if no material declares it this session. Resolved once at ensure_ready (first-declared
## wins); the module wiring registers one VoxelBlockyFluid per kind through this.
static func liquid_lrid_of(kind: int) -> int:
	ensure_ready()
	return int(_lrid_by_liquid_kind.get(kind, -1))

## True iff some material declares liquid kind `kind` this session (a reverse-map hit). This is
## CellCodec._canonical_liquid rule 6's gate: a solid composite may carry any KNOWN liquid kind,
## and only a genuinely unknown/reserved kind is stripped. LIQ_NONE is never "known".
static func is_liquid_kind_known(kind: int) -> bool:
	ensure_ready()
	return kind != CellCodec.LIQ_NONE and _lrid_by_liquid_kind.has(kind)

## Build the kind → LRID reverse index over the registered bootstrap set (MULTI-LIQUID §2.1).
## Load-time validation: a material declaring liquid_kind must be non-solid (solidity < 0.5) —
## a "solid liquid" is a data error, warned and STRIPPED (its liquid_kind zeroed) so it never
## enters the map; and two materials must not claim the same kind (first-declared wins, warn).
static func _build_liquid_index() -> void:
	_lrid_by_liquid_kind.clear()
	for lrid in range(1, _count):                   # skip AIR (LRID 0, null state)
		var s := _states[lrid]
		if s == null or s.liquid_kind == CellCodec.LIQ_NONE:
			continue
		if s.solidity >= 0.5:
			push_warning("[BlockCatalog] material '%s' (id %d) declares liquid_kind %d but is solid (solidity %.2f) — stripped"
				% [s.state_name, lrid, s.liquid_kind, s.solidity])
			s.liquid_kind = CellCodec.LIQ_NONE
			continue
		if _lrid_by_liquid_kind.has(s.liquid_kind):
			push_warning("[BlockCatalog] liquid_kind %d already claimed by id %d — ignoring '%s' (id %d)"
				% [s.liquid_kind, int(_lrid_by_liquid_kind[s.liquid_kind]), s.state_name, lrid])
			continue
		_lrid_by_liquid_kind[s.liquid_kind] = lrid

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
# GMID ⇄ LRID identity queries (RMS §6.1) — the streaming-facing surface. Callers that
# don't stream never touch these; the query API above stays the one everyone reads.

## LRID for a serialized "<gmid>#<state>" reference, or -1 if not registered this
## session (RMS §2.4). The load-side translation entry point.
static func lrid_of(key: StringName) -> int:
	ensure_ready()
	return int(_by_key.get(String(key), -1))

## The serialized "<gmid>#<state>" key an LRID means ("air" for AIR, "" out of range).
## The save-side translation: dense LRID → cross-session identity.
static func key_of(lrid: int) -> StringName:
	ensure_ready()
	if lrid < 0 or lrid >= _count:
		return &""
	return StringName(_keys[lrid])

## The GMID an LRID belongs to (the "<gmid>" part of its key; "air" for AIR).
static func gmid_of(lrid: int) -> StringName:
	var k := String(key_of(lrid))
	var hash_pos := k.find("#")
	return StringName(k.substr(0, hash_pos)) if hash_pos >= 0 else StringName(k)

## True iff `lrid` is RESOLVED (real physics+look); false for an UNRESOLVED placeholder
## (RMS §8). AIR and out-of-range read as resolved/false-safe.
static func is_resolved(lrid: int) -> bool:
	ensure_ready()
	if lrid < 0 or lrid >= _count:
		return false
	return _status[lrid] == RESOLVED

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
