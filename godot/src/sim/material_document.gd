class_name MaterialDocument
extends RefCounted
## The material-document format (RUNTIME-MATERIAL-STREAMING §5): one self-contained,
## immutable UTF-8-JSON blob per material that (a) hashes to its GMID (content address),
## (b) reconstitutes a VoxelMaterialDef + its VoxelStates + VoxelStateTransitions. This
## is the transport/serialization unit of runtime material streaming — a material
## "arrives as data" as one of these documents.
##
## GMID = sha256 over the EXACT transmitted/stored bytes (RMS §2.2, git-blob style): the
## document is hashed as-is, NEVER re-serialized for hashing, so JSON/float
## canonicalization is a non-issue (same bytes ⇒ same GMID on every peer, forever). A
## producer serializes once with `to_document`; everyone else hashes the bytes they
## received. `gmid_of(to_document(def))` is the producer path and is byte-stable across
## a `from_document`→`to_document` round-trip (see verify _test_dynamic_catalog).
##
## `VoxelState.block_id` is NOT serialized — it IS the LRID, assigned at registration
## (RMS §2.3/§5.2); a document never contains a dense session id. `look.texture` is a
## static material-name reference this milestone (INTEGRATION-DECISIONS §D) — provenance
## only; the render path keys textures by block id (BlockTextures), not this field.

const SCHEMA_VERSION := 1
## Cap on states per material (RMS §5.2 validation): a material carries a small,
## bounded state machine (ice/water/steam …), never an unbounded set.
const MAX_STATES := 16

# --- serialization (VoxelMaterialDef -> immutable document bytes) ---------------

## Serialize `def` to its canonical document bytes (UTF-8 JSON, §5.2). Deterministic:
## a fixed key order + Dictionary insertion-order-preserving JSON.stringify means the
## same def always produces the same bytes, hence the same GMID.
static func to_document(def: VoxelMaterialDef) -> PackedByteArray:
	var default_state := def.get_default_state()
	var doc := {
		"voxiverse_material": SCHEMA_VERSION,
		"name": String(def.id),
		"default_state": String(default_state.state_name) if default_state != null else "",
		"state_layout": [],                          # VDS §10.3 — trivial default this milestone
		"visual_mask": 0,
		"has_block_entity": default_state.has_block_entity if default_state != null else false,
		"states": [],
	}
	var states: Array = doc["states"]
	for st: VoxelState in def.states:
		states.append(_state_doc(st, def.id))
	return JSON.stringify(doc).to_utf8_buffer()

## One states[] entry (§5.2): physics (incl. structural anchors/class/attachment), look
## (swatch + static texture name + glow), and outgoing transitions. break_force is
## OMITTED when INF (bedrock/water/lava) — validation forbids non-finite numerics, and a
## missing key takes VoxelState's INF default on parse.
static func _state_doc(st: VoxelState, mat_name: StringName) -> Dictionary:
	var physics := {
		"mass": st.mass,
		"density": st.density,
		"solidity": st.solidity,
		"permeability": st.permeability,
		"albedo": st.albedo,
		"translucence": st.translucence,
		"emission": st.emission,
		"attachment": st.attachment,
		"cull_group": st.cull_group,
		"structural_class": String(st.structural_class),
		"strength_anchors": [st.strength_anchors.x, st.strength_anchors.y, st.strength_anchors.z],
	}
	if is_finite(st.break_force):
		physics["break_force"] = st.break_force
	var look := {
		"swatch": [st.tint.r, st.tint.g, st.tint.b, st.tint.a],
		"texture": String(mat_name),                 # static name reference (§5.3 / Decision D)
		"glow": st.glow,
	}
	var transitions := []
	for t: VoxelStateTransition in st.transitions:
		transitions.append({
			"to": String(t.to_state),
			"field": t.field,
			"cmp": _cmp_to_str(t.comparator),
			"threshold": t.threshold,
		})
	return {
		"name": String(st.state_name),
		"physics": physics,
		"look": look,
		"transitions": transitions,
	}

# --- content addressing ---------------------------------------------------------

## GMID = "sha256:<64 hex>" over the EXACT bytes (RMS §2.2). Hash what you received —
## never re-serialize for hashing.
static func gmid_of(bytes: PackedByteArray) -> StringName:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return StringName("sha256:" + ctx.finish().hex_encode())

# --- deserialization (document bytes -> VoxelMaterialDef, validated) -------------

## Parse + VALIDATE `bytes` into a VoxelMaterialDef (§5.2). Returns null on ANY
## validation failure (schema version, ≥1 state, default_state exists, transition
## targets exist, all present numerics finite, mass>0 for solid states, ≤MAX_STATES) —
## a document is rejected WHOLE, never half-registered (the caller keeps/creates the
## UNRESOLVED placeholder for its GMID, RMS §8). `VoxelState.block_id` is left unset
## (-1); registration assigns the LRID.
static func from_document(bytes: PackedByteArray) -> VoxelMaterialDef:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var doc: Dictionary = parsed
	if int(doc.get("voxiverse_material", 0)) != SCHEMA_VERSION:
		return null
	var states_raw: Variant = doc.get("states", [])
	if not (states_raw is Array) or (states_raw as Array).is_empty():
		return null
	if (states_raw as Array).size() > MAX_STATES:
		return null
	var be := bool(doc.get("has_block_entity", false))
	var states: Array[VoxelState] = []
	var names := {}
	for sraw: Variant in states_raw:
		if not (sraw is Dictionary):
			return null
		var st := _state_from(sraw, be)
		if st == null:
			return null
		names[String(st.state_name)] = true
		states.append(st)
	# default_state must name one of the states.
	var default_name := String(doc.get("default_state", ""))
	var di := -1
	for i in states.size():
		if String(states[i].state_name) == default_name:
			di = i
			break
	if di < 0:
		return null
	# transition targets must exist.
	for st: VoxelState in states:
		for t: VoxelStateTransition in st.transitions:
			if not names.has(String(t.to_state)):
				return null
	var def := VoxelMaterialDef.new()
	def.id = StringName(String(doc.get("name", "")))
	def.states = states
	def.default_state_index = di
	return def

## Build one VoxelState from a states[] entry, validating every present numeric is
## finite and (for a solid state) mass>0. Returns null on any violation.
static func _state_from(sraw: Dictionary, block_entity: bool) -> VoxelState:
	var st := VoxelState.new()
	st.state_name = StringName(String(sraw.get("name", "")))
	if String(st.state_name) == "":
		return null
	st.has_block_entity = block_entity
	var ph: Variant = sraw.get("physics", {})
	if ph is Dictionary:
		var p: Dictionary = ph
		if p.has("mass"):
			if not _fin(p["mass"]): return null
			st.mass = float(p["mass"])
		if p.has("density"):
			if not _fin(p["density"]): return null
			st.density = float(p["density"])
		if p.has("break_force"):                    # present ⇒ must be finite (INF is omitted)
			if not _fin(p["break_force"]): return null
			st.break_force = float(p["break_force"])
		if p.has("solidity"):
			if not _fin(p["solidity"]): return null
			st.solidity = float(p["solidity"])
		if p.has("permeability"):
			if not _fin(p["permeability"]): return null
			st.permeability = float(p["permeability"])
		if p.has("albedo"):
			if not _fin(p["albedo"]): return null
			st.albedo = float(p["albedo"])
		if p.has("translucence"):
			if not _fin(p["translucence"]): return null
			st.translucence = float(p["translucence"])
		if p.has("emission"):
			if not _fin(p["emission"]): return null
			st.emission = float(p["emission"])
		if p.has("attachment"):
			if not _fin(p["attachment"]): return null
			st.attachment = float(p["attachment"])
		if p.has("cull_group"):
			st.cull_group = int(p["cull_group"])
		if p.has("structural_class"):
			st.structural_class = StringName(String(p["structural_class"]))
		var an: Variant = p.get("strength_anchors", null)
		if an is Array and (an as Array).size() == 3:
			st.strength_anchors = Vector3i(int(an[0]), int(an[1]), int(an[2]))
	# A solid material must have positive mass (RMS §5.2).
	if st.solidity > 0.0 and st.mass <= 0.0:
		return null
	var lk: Variant = sraw.get("look", {})
	if lk is Dictionary:
		var l: Dictionary = lk
		var sw: Variant = l.get("swatch", [])
		if sw is Array and (sw as Array).size() >= 3:
			var a := float(sw[3]) if (sw as Array).size() >= 4 else 1.0
			st.tint = Color(float(sw[0]), float(sw[1]), float(sw[2]), a)
		if l.has("glow"):
			if not _fin(l["glow"]): return null
			st.glow = float(l["glow"])
	var trs: Variant = sraw.get("transitions", [])
	if trs is Array:
		for traw: Variant in trs:
			if not (traw is Dictionary):
				return null
			var t := VoxelStateTransition.new()
			t.to_state = StringName(String((traw as Dictionary).get("to", "")))
			t.field = String((traw as Dictionary).get("field", "temperature"))
			t.comparator = _str_to_cmp(String((traw as Dictionary).get("cmp", "<")))
			var th: Variant = (traw as Dictionary).get("threshold", 0.0)
			if not _fin(th):
				return null
			t.threshold = float(th)
			st.transitions.append(t)
	return st

# --- helpers --------------------------------------------------------------------

static func _fin(v: Variant) -> bool:
	if not (v is float or v is int):
		return false
	return is_finite(float(v))

static func _cmp_to_str(cmp: int) -> String:
	match cmp:
		VoxelStateTransition.Comparator.GREATER: return ">"
		VoxelStateTransition.Comparator.GREATER_EQUAL: return ">="
		VoxelStateTransition.Comparator.LESS: return "<"
		VoxelStateTransition.Comparator.LESS_EQUAL: return "<="
	return "<"

static func _str_to_cmp(s: String) -> int:
	match s:
		">": return VoxelStateTransition.Comparator.GREATER
		">=": return VoxelStateTransition.Comparator.GREATER_EQUAL
		"<": return VoxelStateTransition.Comparator.LESS
		"<=": return VoxelStateTransition.Comparator.LESS_EQUAL
	return VoxelStateTransition.Comparator.LESS
