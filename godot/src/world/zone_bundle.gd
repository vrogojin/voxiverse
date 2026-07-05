class_name ZoneBundle
extends RefCounted
## Self-contained, peer-transmissible payload for one or more 32³ world regions
## (RUNTIME-MATERIAL-STREAMING §2.6 / §3.4 / §5, VOXEL-DATA-STRUCTURE §5). A zone bundle is
## the unit runtime material streaming moves over the wire: acquiring a remote zone brings
## the block MATERIALS the receiver has never seen, packaged with the voxel data.
##
## THREE SECTIONS (RMS §2.6):
##   * MANIFEST — every GMID the zone references, each with its immutable material DOCUMENT
##     (RMS §5, one per GMID; a multi-state material contributes one document that carries all
##     states). A receiver registers these to learn materials it lacks.
##   * ID-MAP — container-local dense id → "<gmid>#<state>" key (a StringName). THE one place a
##     container-local id binds to a global identity; the ZoneChunk palettes below index into
##     this same key space. (The reserved key "air" needs no manifest document — air is absence.)
##   * ZoneChunk(s) — the P6b per-cell payload (material/modifier/state/metadata) for each
##     region, whose material palette entries ARE the id-map keys (built via
##     `ZoneChunk.set_cell_keyed`).
##
## THE PRINCIPLE (RMS §2.1): dense session LRIDs NEVER cross the boundary — the bundle carries
## GMIDs; the receiver translates to its OWN dense LRIDs at load. Two peers always have
## different LRID tables and it never matters (the shuffled-load-order round-trip proves this).
## Identical bytes ⇒ identical GMID ⇒ idempotent registration ⇒ same LRID on a peer, so loading
## a bundle whose GMID is already known reuses the existing LRID (free dedup, RMS §8).
##
## OUT OF SCOPE (RMS §9.3): the p2p transport, signing, and trust model. This is the payload
## FORMAT + the id-translation rule at the boundary — nothing sends or receives bytes here.
## A receiver MUST re-hash inlined documents (register_document does, via MaterialDocument);
## a document whose bytes don't hash to the advertised GMID is simply a different material.

## Byte-format magic + version (bumped only on an incompatible layout change).
const MAGIC := "VXZB"
const VERSION := 1

## The reserved id-map key for air (RMS §2.5): air is absence, has no document, and always
## resolves to the permanent reserved LRID 0. Matches BlockCatalog.key_of(AIR).
const AIR_KEY := "air"

# StringName gmid -> PackedByteArray document bytes (one entry per referenced material).
var _manifest: Dictionary = {}
# [{origin: Vector3i, chunk: ZoneChunk}] — one entry per serialized region, in add order.
var _chunks: Array = []
# Cached id-map (container-local id -> "<gmid>#<state>" key). Populated by from_bytes; for a
# freshly-built bundle it is derived on demand from the chunk palettes (id_map()).
var _idmap: PackedStringArray = PackedStringArray()

var _version: int = VERSION

# --- build API (used by WorldManager.save_bundle + the verify harness) -----------------

## Add a region's ZoneChunk to the bundle (palette entries must be id-map keys — see
## `ZoneChunk.set_cell_keyed`). `origin` is the 32-aligned region min corner.
func add_chunk(origin: Vector3i, chunk: ZoneChunk) -> void:
	_chunks.append({"origin": origin, "chunk": chunk})
	_idmap = PackedStringArray()          # invalidate the derived id-map cache

## Ensure `lrid`'s material document is in the manifest (dedup by GMID; air is skipped — it
## needs no document). Prefers the exact stored bytes from the content store (RMS §6.3), else
## reconstructs the byte-identical document from the catalog def (`to_document`, RMS §2.2/§5).
func reference_material(lrid: int) -> void:
	if lrid <= BlockCatalog.AIR:
		return
	var gmid := BlockCatalog.gmid_of(lrid)
	var gs := String(gmid)
	if gs == "" or gs == AIR_KEY or _manifest.has(gmid):
		return
	var doc := MaterialRegistry.document_bytes(gmid)
	if doc.is_empty():
		var def := BlockCatalog.def_of(lrid)
		if def != null:
			doc = MaterialDocument.to_document(def)
	if not doc.is_empty():
		_manifest[gmid] = doc

# --- load API (used by WorldManager.load_bundle) ---------------------------------------

## Register every manifest material into the dynamic catalog (RMS §6.3): each document is
## re-hashed + validated + registered, allocating fresh session LRIDs for unknown GMIDs and
## reusing existing LRIDs for known ones (idempotent, RMS §8 — the free-dedup guarantee). A
## malformed document registers nothing; `resolve_key` then falls back to a placeholder.
func register_manifest() -> void:
	for gmid: StringName in _manifest.keys():
		MaterialRegistry.register_document(_manifest[gmid])

## Translate one id-map key to THIS session's LRID (RMS §2.6). "air" → the reserved LRID 0; a
## registered "<gmid>#<state>" → its session LRID; an unresolvable key (its document was absent
## or rejected) → an UNRESOLVED placeholder under the TRUE GMID (RMS §8) so the cell keeps its
## global identity and the data loads losslessly. -1 only for a malformed key (no '#', not air).
func resolve_key(key: String) -> int:
	var lrid := BlockCatalog.lrid_of(StringName(key))
	if lrid >= 0:
		return lrid
	var hp := key.find("#")
	if hp < 0:
		return -1
	return BlockCatalog.register_placeholder(StringName(key.substr(0, hp)), StringName(key.substr(hp + 1)))

# --- queries ---------------------------------------------------------------------------

## The id-map (container-local id -> "<gmid>#<state>" key). Read from bytes when the bundle was
## deserialized; otherwise derived as the sorted union of every chunk's palette keys (so a
## freshly-built bundle exposes the same list it would serialize).
func id_map() -> PackedStringArray:
	if not _idmap.is_empty():
		return _idmap
	var seen := {}
	for entry: Dictionary in _chunks:
		var chunk: ZoneChunk = entry["chunk"]
		for idx: int in chunk.present_indices():
			seen[chunk.material_name_at(idx)] = true
	var keys := seen.keys()
	keys.sort()
	_idmap = PackedStringArray(keys)
	return _idmap

## GMID -> document bytes for every referenced material (the manifest).
func manifest() -> Dictionary:
	return _manifest

## Number of distinct materials (GMIDs) in the manifest.
func material_count() -> int:
	return _manifest.size()

## The stored region entries ([{origin, chunk}]).
func chunks() -> Array:
	return _chunks

func chunk_count() -> int:
	return _chunks.size()

# --- serialization (§5; all integers little-endian) ------------------------------------

## Serialize to the bundle byte layout (deterministic: manifest sorted by GMID, id-map sorted,
## chunks in add order — so equal bundles produce equal bytes).
func to_bytes() -> PackedByteArray:
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_data(MAGIC.to_utf8_buffer())
	spb.put_u8(VERSION)

	# MANIFEST: sorted by GMID for byte-stability.
	var gmids := _manifest.keys()
	gmids.sort()
	spb.put_u16(gmids.size())
	for gmid: StringName in gmids:
		_put_str(spb, String(gmid))
		var doc: PackedByteArray = _manifest[gmid]
		spb.put_u32(doc.size())
		if doc.size() > 0:
			spb.put_data(doc)

	# ID-MAP: container-local id -> "<gmid>#<state>" key.
	var idmap := id_map()
	spb.put_u16(idmap.size())
	for key: String in idmap:
		_put_str(spb, key)

	# CHUNKS: {origin(3×i32), len(u32), ZoneChunk bytes}.
	spb.put_u16(_chunks.size())
	for entry: Dictionary in _chunks:
		var origin: Vector3i = entry["origin"]
		spb.put_32(origin.x)
		spb.put_32(origin.y)
		spb.put_32(origin.z)
		var cb: PackedByteArray = (entry["chunk"] as ZoneChunk).to_bytes()
		spb.put_u32(cb.size())
		if cb.size() > 0:
			spb.put_data(cb)

	return spb.data_array

## Rebuild a ZoneBundle from `bytes`. Bounds-checked against crafted payloads (magic, version,
## and every length prefix) — on a malformed payload it logs and returns whatever decoded so
## far, never crashing the loader (mirrors ZoneChunk.from_bytes' defensive contract).
static func from_bytes(bytes: PackedByteArray) -> ZoneBundle:
	var zb := ZoneBundle.new()
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.data_array = bytes
	spb.seek(0)
	if bytes.size() < 5:
		push_error("ZoneBundle.from_bytes: truncated payload (%d bytes)" % bytes.size())
		return zb
	var magic_res: Array = spb.get_data(4)
	if int(magic_res[0]) != OK or (magic_res[1] as PackedByteArray).get_string_from_utf8() != MAGIC:
		push_error("ZoneBundle.from_bytes: bad magic — rejecting payload")
		return zb
	zb._version = spb.get_u8()

	# MANIFEST.
	var mcount := spb.get_u16()
	for _i in range(mcount):
		var gmid := _get_str(spb)
		var dlen := spb.get_u32()
		var doc := PackedByteArray()
		if dlen > 0:
			var res: Array = spb.get_data(dlen)
			if int(res[0]) != OK:
				push_error("ZoneBundle.from_bytes: truncated manifest document — stopping")
				return zb
			doc = res[1]
		zb._manifest[StringName(gmid)] = doc

	# ID-MAP.
	var kcount := spb.get_u16()
	var idmap := PackedStringArray()
	for _i in range(kcount):
		idmap.append(_get_str(spb))
	zb._idmap = idmap

	# CHUNKS.
	var ccount := spb.get_u16()
	for _i in range(ccount):
		var ox := spb.get_32()
		var oy := spb.get_32()
		var oz := spb.get_32()
		var clen := spb.get_u32()
		var cbytes := PackedByteArray()
		if clen > 0:
			var res: Array = spb.get_data(clen)
			if int(res[0]) != OK:
				push_error("ZoneBundle.from_bytes: truncated chunk payload — stopping")
				return zb
			cbytes = res[1]
		zb._chunks.append({"origin": Vector3i(ox, oy, oz), "chunk": ZoneChunk.from_bytes(cbytes)})

	return zb

# --- helpers ---------------------------------------------------------------------------

static func _put_str(spb: StreamPeerBuffer, s: String) -> void:
	var b := s.to_utf8_buffer()
	spb.put_u16(b.size())
	if b.size() > 0:
		spb.put_data(b)

static func _get_str(spb: StreamPeerBuffer) -> String:
	var n := spb.get_u16()
	if n <= 0:
		return ""
	var res: Array = spb.get_data(n)
	if int(res[0]) != OK:
		return ""
	return (res[1] as PackedByteArray).get_string_from_utf8()
