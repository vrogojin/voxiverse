class_name ZoneChunk
extends RefCounted
## Tier-3 at-rest / transport container for a 32³ voxel region (VOXEL-DATA-STRUCTURE
## §4 tier 3, §5 exact layout). A ZoneChunk is the compact, self-describing byte form
## of the world's *deviations from the pure generated function* — the edit overlay
## (`WorldManager._edits` + `_meta`) serialized per 32³ region. The pristine generated
## world is never stored (it is a function, tier 2); only present (edited) cells occupy
## the chunk, and unedited cells resolve back through the generator on read (§4).
##
## LAYERS (§5). A ZoneChunk carries, in this byte order:
##   * version byte + layer_flags byte (which optional layers are present);
##   * an ALWAYS-present MATERIAL layer — a per-chunk palette (the id-map header: palette
##     index → stable material NAME) + a bit-packed dense index array (variable bit width
##     sized to the palette). Materials travel by NAME (VDS §10.1 / RUNTIME-MATERIAL-
##     STREAMING §2.6) so a saved chunk stays valid even if the runtime catalog assigns
##     different dense ids — the loader resolves name → LRID at load time;
##   * optional SPARSE modifier / state / metadata layers, present only when a cell
##     actually carries a non-default value on that axis (the zero-cost-default proof,
##     §5.4: an all-cube, stateless, metadata-free chunk has NONE of the three layers).
##
## PALETTE & UNSET. Palette entries are material names. A distinguished palette entry —
## the empty string `UNSET_NAME` — marks a cell that is NOT present in this chunk (it
## falls back to the generated function on load, tier composition §4). Air (a dug-to-air
## edit, packed value 0) is a REAL present material named "air" and is stored, distinct
## from an unedited/unset cell — the two must never be confused (an edit to air overrides
## a generated-solid cell; an unset cell keeps the generated value).
##
## IN-MEMORY vs ON-DISK (P6b simplification, flagged for P6c). This class keeps present
## cells in sparse per-axis Dictionaries in memory (simple + resolver-independent: the
## material is stored as a NAME, not yet a runtime id). `to_bytes()` emits the §5-exact
## compact layout (palette + bit-packed dense material indices + sparse layers); the
## on-disk/transport form IS §5-compliant and zero-cost-default. Reading back through the
## compact form without inflating (§5's "read-through" access) and sparse→dense escalation
## (§6.3) are optimizations deferred to the persistence workstream (P6c); the payload
## FORMAT they will read is already the format written here.

## Region edge in cells (§5: one ZoneChunk covers 32³ = 32 768 cells).
const SIZE := 32
const CELLS := SIZE * SIZE * SIZE          # 32 768 — fits a u16 cell index exactly

## Payload format version (bumped only on an incompatible layout change).
const VERSION := 1

## layer_flags bits (§5). Bits 3..7 are reserved 0 in P6b: MODIFIER_DENSE / STATE_DENSE
## (the sparse→dense escalation of §6.3) are a future size optimization — P6b writes the
## sparse form for any count (a u16 count covers all 32 768 cells), so the reader never
## sees a dense scalar layer and both bits stay clear.
const F_MODIFIER := 1 << 0
const F_STATE := 1 << 1
const F_META := 1 << 2

## The palette entry that marks a cell as NOT present in this chunk (falls back to the
## generated function on load). No real material has an empty name, so it can never
## collide with a stored material (BlockCatalog.name_of never returns "").
const UNSET_NAME := ""

## Visible, solid placeholder material for an unknown palette name on load (P6b). A chunk
## authored against a material the runtime catalog does not know still loads losslessly at
## the geometry level (the shape/state bits are kept); only the substance degrades, and
## loudly. RUNTIME-MATERIAL-STREAMING §8's real UNRESOLVED placeholder (magenta checker,
## provisional physics, late resolution by GMID) lands with dynamic catalogs in P6c.
const PLACEHOLDER_MATERIAL := &"stone"

# Present cells only — the sparse in-memory form (unset cells are simply absent). Keyed by
# local cell index 0..CELLS-1. Material is stored as a NAME so the container is independent
# of the runtime dense-id assignment until a cell is resolved on load.
var _mat_name: Dictionary = {}    # local_idx -> String   (material name; present cells)
var _modifier: Dictionary = {}    # local_idx -> int      (only non-zero modifiers)
var _state: Dictionary = {}       # local_idx -> int      (only non-zero states)
var _meta: Dictionary = {}        # local_idx -> Dictionary (block-entity documents)

var _version: int = VERSION       # set by from_bytes to the payload's version

# --- local cell indexing (§5: Y fastest, column-major) --------------------------------

## Local cell index for an in-chunk coordinate (each of x, y, z ∈ [0, SIZE)): the
## Y-fastest column-major order `idx = ((z<<5) | x) << 5 | y` (matches the module's
## [z][x][y] layout V3 and every columnar physics scan, §6.4).
static func local_index(x: int, y: int, z: int) -> int:
	return (((z << 5) | x) << 5) | y

## Inverse of `local_index`: the in-chunk (x, y, z) for a local cell index.
static func from_local_index(idx: int) -> Vector3i:
	var y := idx & 31
	var t := idx >> 5
	return Vector3i(t & 31, y, t >> 5)

# --- build API (used by WorldManager.save_edits and the verify harness) ---------------

## Mark local cell `idx` present with the PACKED cell value `packed` (CellCodec: material |
## modifier<<16 | state<<32) and optional block-entity metadata `meta`. The material is
## recorded by NAME (BlockCatalog.name_of); the modifier/state axes are recorded only when
## non-default (so an all-cube stateless chunk populates neither sparse layer). `meta` is
## stored as a DEEP COPY (later caller mutation cannot alias the stored document). A packed
## value of 0 (air) is a valid present cell — a dug-to-air edit, distinct from unset.
func set_cell(idx: int, packed: int, meta: Variant = null) -> void:
	assert(idx >= 0 and idx < CELLS, "ZoneChunk.set_cell: local index out of range")
	_mat_name[idx] = BlockCatalog.name_of(CellCodec.mat(packed))
	var modifier := CellCodec.modifier(packed)
	if modifier != 0:
		_modifier[idx] = modifier
	else:
		_modifier.erase(idx)
	var state := CellCodec.state(packed)
	if state != 0:
		_state[idx] = state
	else:
		_state.erase(idx)
	if meta != null and meta is Dictionary and not (meta as Dictionary).is_empty():
		_meta[idx] = (meta as Dictionary).duplicate(true)
	else:
		_meta.erase(idx)

# --- decoded queries (used by WorldManager.load_edits and the verify harness) ---------

## Sorted-ascending local indices of the present (stored) cells.
func present_indices() -> PackedInt32Array:
	var ks := _mat_name.keys()
	ks.sort()
	var out := PackedInt32Array()
	out.resize(ks.size())
	for i in range(ks.size()):
		out[i] = ks[i]
	return out

## Number of present (stored) cells.
func present_count() -> int:
	return _mat_name.size()

## Stored material NAME at a present cell (UNSET_NAME semantics never surface here — unset
## cells are simply absent). Empty string for an absent cell.
func material_name_at(idx: int) -> String:
	return _mat_name.get(idx, UNSET_NAME)

## Modifier axis at a present cell (0 = full cube / default).
func modifier_at(idx: int) -> int:
	return int(_modifier.get(idx, 0))

## State axis at a present cell (0 = default).
func state_at(idx: int) -> int:
	return int(_state.get(idx, 0))

## Block-entity metadata document at a present cell, or null when the cell carries none.
## Returns the STORED dictionary reference (callers treat it read-only; load re-copies).
func meta_at(idx: int) -> Variant:
	return _meta.get(idx, null)

## The layer_flags byte this chunk would serialize with (which optional layers are present).
func layer_flags() -> int:
	var f := 0
	if not _modifier.is_empty():
		f |= F_MODIFIER
	if not _state.is_empty():
		f |= F_STATE
	if not _meta.is_empty():
		f |= F_META
	return f

# --- serialization (§5 exact byte layout; all integers little-endian) -----------------

## Serialize to the §5 compact byte layout. Deterministic (no wall-clock / RNG): the palette
## is built in first-encountered order over the Y-fastest cell scan, sparse layers are written
## in ascending cell-index order. Zero-cost-default holds by construction: absent optional
## layers contribute NO bytes and their layer_flags bits are clear (§5.4).
func to_bytes() -> PackedByteArray:
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u8(VERSION)
	spb.put_u8(layer_flags())

	# MATERIAL layer (always present — it IS the chunk). Build the palette (id-map header:
	# index → material name) in a deterministic first-encountered order; reserve index 0 for
	# UNSET_NAME whenever any cell is absent (so unset cells resolve to "fall back to the
	# generator" on load, never to a real material).
	var has_unset := _mat_name.size() < CELLS
	var palette := PackedStringArray()
	var palette_index := {}                      # name -> palette index
	if has_unset:
		palette.append(UNSET_NAME)
		palette_index[UNSET_NAME] = 0
	for idx in range(CELLS):
		if not _mat_name.has(idx):
			continue
		var nm: String = _mat_name[idx]
		if not palette_index.has(nm):
			palette_index[nm] = palette.size()
			palette.append(nm)

	spb.put_u16(palette.size())
	for nm: String in palette:
		var nb := nm.to_utf8_buffer()
		spb.put_u16(nb.size())
		if nb.size() > 0:
			spb.put_data(nb)

	# Bit-packed dense index array, unless the chunk is uniform (a single palette entry →
	# every cell is that one value → NO index array, §5 "if n == 1: 0 B").
	if palette.size() > 1:
		var bits := _bits_for(palette.size())
		spb.put_u8(bits)
		var unset_pi: int = palette_index.get(UNSET_NAME, 0)
		var per_word := 32 / bits
		var nwords := CELLS / per_word           # exact: bits ∈ {1,2,4,8,16} divide 32; CELLS = 2^15
		var words := []                          # 64-bit ints (no 32-bit sign truncation while OR-ing)
		words.resize(nwords)
		words.fill(0)
		for idx in range(CELLS):
			var pi: int = palette_index[_mat_name[idx]] if _mat_name.has(idx) else unset_pi
			var w := idx / per_word
			var slot := idx % per_word
			words[w] = words[w] | ((pi & ((1 << bits) - 1)) << (slot * bits))
		for w in range(nwords):
			spb.put_u32(words[w] & 0xFFFFFFFF)

	# Optional SPARSE scalar layers (ascending cell index — the sweep order §6.2).
	if not _modifier.is_empty():
		_put_sparse_u16(spb, _modifier)
	if not _state.is_empty():
		_put_sparse_u16(spb, _state)

	# Optional METADATA layer — cell index + length-prefixed UTF-8 JSON bytes (§5). JSON is
	# the canonical metadata transport (VDS §3.2 / §10); numeric values normalize to float on
	# reload (JSON has no int/float distinction) — the documented fidelity is canonical-JSON.
	if not _meta.is_empty():
		var mk := _meta.keys()
		mk.sort()
		spb.put_u16(mk.size())
		for idx: int in mk:
			var jb := JSON.stringify(_meta[idx]).to_utf8_buffer()
			spb.put_u16(idx)
			spb.put_u32(jb.size())
			if jb.size() > 0:
				spb.put_data(jb)

	return spb.data_array

## Rebuild a ZoneChunk from the §5 byte layout produced by `to_bytes`. Bounds-checks the
## adversarial surfaces called out in §16 (palette count, bit width) so a crafted payload
## cannot over-allocate. Returns a fresh ZoneChunk; on a malformed payload it logs and
## returns whatever was decoded so far (never crashes the loader).
static func from_bytes(bytes: PackedByteArray) -> ZoneChunk:
	var zc := ZoneChunk.new()
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.data_array = bytes
	spb.seek(0)
	zc._version = spb.get_u8()
	var flags := spb.get_u8()

	# MATERIAL layer: palette (id-map header) then the bit-packed dense index array.
	var pcount := spb.get_u16()
	if pcount > CELLS:
		push_error("ZoneChunk.from_bytes: palette_count %d exceeds %d cells — rejecting chunk" % [pcount, CELLS])
		return zc
	var palette := PackedStringArray()
	for _i in range(pcount):
		var nlen := spb.get_u16()
		var nm := ""
		if nlen > 0:
			var res: Array = spb.get_data(nlen)
			if int(res[0]) == OK:
				nm = (res[1] as PackedByteArray).get_string_from_utf8()
		palette.append(nm)

	if pcount <= 1:
		# Uniform chunk: the single palette entry applies to every cell. UNSET → nothing is
		# present (an empty overlay region); a real name → all CELLS present with it.
		if pcount == 1 and palette[0] != UNSET_NAME:
			for idx in range(CELLS):
				zc._mat_name[idx] = palette[0]
	else:
		var bits := spb.get_u8()
		if not _valid_bits(bits):
			push_error("ZoneChunk.from_bytes: illegal index bit width %d — rejecting chunk" % bits)
			return zc
		var per_word := 32 / bits
		var nwords := CELLS / per_word
		var mask := (1 << bits) - 1
		var words := []                          # 64-bit ints (get_u32 returns 0..2^32-1, unsigned)
		words.resize(nwords)
		for w in range(nwords):
			words[w] = spb.get_u32()
		for idx in range(CELLS):
			var w := idx / per_word
			var slot := idx % per_word
			var pi: int = (words[w] >> (slot * bits)) & mask
			if pi < 0 or pi >= pcount:
				continue                          # crafted index out of palette range — skip (unset)
			var nm: String = palette[pi]
			if nm != UNSET_NAME:
				zc._mat_name[idx] = nm

	# Optional SPARSE scalar layers.
	if flags & F_MODIFIER:
		_get_sparse_u16(spb, zc._modifier)
	if flags & F_STATE:
		_get_sparse_u16(spb, zc._state)

	# Optional METADATA layer.
	if flags & F_META:
		var mcount := spb.get_u16()
		for _i in range(mcount):
			var idx := spb.get_u16()
			var blen := spb.get_u32()
			if blen == 0:
				continue
			var res: Array = spb.get_data(blen)
			if int(res[0]) != OK:
				break
			var parsed: Variant = JSON.parse_string((res[1] as PackedByteArray).get_string_from_utf8())
			if parsed is Dictionary:
				zc._meta[idx] = parsed
	return zc

# --- internal helpers -----------------------------------------------------------------

## Smallest index bit width in {1,2,4,8,16} that addresses `n` palette entries. n ≤ 1 is
## the uniform case (0 bits, no index array). Every width divides 32, so packed indices
## never straddle a u32 word (no padding bits needed — §5 / §1.1 Minecraft-1.16 style).
static func _bits_for(n: int) -> int:
	if n <= 2:
		return 1
	if n <= 4:
		return 2
	if n <= 16:
		return 4
	if n <= 256:
		return 8
	return 16

static func _valid_bits(b: int) -> bool:
	return b == 1 or b == 2 or b == 4 or b == 8 or b == 16

## Write a sparse u16 scalar layer: count(u16) then ascending {cell_idx(u16), value(u16)}.
static func _put_sparse_u16(spb: StreamPeerBuffer, layer: Dictionary) -> void:
	var ks := layer.keys()
	ks.sort()
	spb.put_u16(ks.size())
	for idx: int in ks:
		spb.put_u16(idx)
		spb.put_u16(int(layer[idx]) & 0xFFFF)

## Read a sparse u16 scalar layer into `out` (local_idx -> value).
static func _get_sparse_u16(spb: StreamPeerBuffer, out: Dictionary) -> void:
	var count := spb.get_u16()
	for _i in range(count):
		var idx := spb.get_u16()
		out[idx] = spb.get_u16()
