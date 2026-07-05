class_name MaterialRegistry
extends RefCounted
## Holds every VoxelMaterialDef known to the world, keyed by id. Built in code
## for now (one material: grass); later this is where authored .tres materials
## get registered. Kept separate from rendering and from the environment so new
## materials drop in without touching either.

var _by_id := {}  # StringName -> VoxelMaterialDef

## Local content store: GMID -> the exact material-document bytes this peer holds
## (RUNTIME-MATERIAL-STREAMING §6.3). The bytes ARE the identity, so we keep them to
## re-serve or re-hash. Session-global (a material loaded once is available everywhere).
static var _content: Dictionary = {}    # StringName gmid -> PackedByteArray

func register(def: VoxelMaterialDef) -> void:
	_by_id[def.id] = def

## Ingest a material document (RMS §6.3): validate the bytes into a VoxelMaterialDef,
## content-address them to a GMID, register the material in the dynamic BlockCatalog
## (allocating LRIDs, or late-resolving a placeholder in place), and keep the raw bytes
## in the local content store. Returns the GMID, or `&""` if the document is malformed
## (rejected whole — the caller keeps/creates the UNRESOLVED placeholder for its GMID).
## Static (identity + catalog are session-global): a MaterialRegistry instance is not
## required, matching how streaming funnels through one main-thread loader.
static func register_document(bytes: PackedByteArray) -> StringName:
	var def := MaterialDocument.from_document(bytes)
	if def == null:
		return &""
	var gmid := MaterialDocument.gmid_of(bytes)
	BlockCatalog.register_material(gmid, def)
	_content[gmid] = bytes
	return gmid

## The stored document bytes for a GMID (empty if this peer never received them).
static func document_bytes(gmid: StringName) -> PackedByteArray:
	return _content.get(gmid, PackedByteArray())

## True iff this peer holds the document bytes for `gmid`.
static func has_document(gmid: StringName) -> bool:
	return _content.has(gmid)

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
