class_name CellCodec
extends RefCounted
## Static, pure packing/projection for the enriched voxel cell value
## (VOXEL-DATA-STRUCTURE.md §3.3). The three scalar axes — material, modifier,
## state — pack into one 64-bit int (GDScript's native int, stored inline in a
## Variant, no heap):
##
##   bit 63      48 47           32 31           16 15            0
##  ┌───┬──────────┬───────────────┬───────────────┬───────────────┐
##  │ 0 │ reserved │     STATE     │   MODIFIER    │  MATERIAL LRID │
##  └───┴──────────┴───────────────┴───────────────┴───────────────┘
##
## value 0 == air (air never carries modifier/state; enforced by canonical()).
## A bare legacy block id (0..65535) IS a valid packed value meaning "full cube,
## state 0" — so `_edits`, VoxelBody.cells and every generated id migrate for
## free. This class is the single composed-query codec: material, modifier and
## state are three bit-projections of ONE int, so they can never desync.

const MAT_MASK := 0xFFFF

## Modifier sub-fields (VDS §3.2 / SUB-VOXEL §3.1). Corner heights live in bits 0..7
## (two bits each), the anchor in bit 8, a family tag in bit 15.
const MOD_CORNERS_MASK := 0xFF
const MOD_ANC_BIT := 1 << 8
const MOD_FAM_BIT := 1 << 15

## Material (LRID) — low 16 bits.
static func mat(v: int) -> int:
	return v & MAT_MASK

## Modifier (geometric occupancy) — bits 16..31.
static func modifier(v: int) -> int:
	return (v >> 16) & 0xFFFF

## State (behavioural variant) — bits 32..47.
static func state(v: int) -> int:
	return (v >> 32) & 0xFFFF

## Compose a packed cell value from the three axes.
static func pack(mat: int, modifier := 0, state := 0) -> int:
	return (mat & MAT_MASK) | ((modifier & 0xFFFF) << 16) | ((state & 0xFFFF) << 32)

## True when the cell is a plain full cube in its default state (modifier 0,
## state 0) — the overwhelming common case and the zero-cost-default fast path.
## Equivalent to "bits 16..63 all zero".
static func is_plain(v: int) -> bool:
	return (v >> 16) == 0

## The canonical form of a packed value — the ONE transform every write funnels
## through (WorldManager._write_cell). Guarantees:
##   * air-zeroing: any cell whose material is AIR collapses to exactly 0, so air
##     can never carry a stray modifier/state (keeps `is_plain`/equality honest);
##   * modifier canonical form: delegated to _canonical_modifier (P5 hook);
##   * state validation: delegated to _validate_state (P6 hook).
## In P0 the modifier/state hooks are pass-through stubs (documented below), so
## canonical() is exactly air-zeroing + re-pack — a no-op on bare ids.
static func canonical(v: int) -> int:
	var m := mat(v)
	if m == BlockCatalog.AIR:
		return 0                              # air never carries modifier/state
	var cm := _canonical_modifier(m, modifier(v))
	# A canonicalized corner-height shape with all four corners 0 but a nonzero
	# encoding (e.g. a TOP anchor bit) is an EMPTY shape — the cell is AIR (VDS §3.2 /
	# SUB-VOXEL §3.1). Modifier 0 (the FULL-cube encoding) is deliberately excluded.
	if cm != 0 and (cm & MOD_FAM_BIT) == 0 and (cm & MOD_CORNERS_MASK) == 0:
		return 0
	return pack(m, cm, _validate_state(m, state(v)))

## Corner-height canonicalization (VOXEL-DATA-STRUCTURE §3.2 / SUB-VOXEL §3.1), the
## packing half of the split `ShapeCodec` (VDS §13.1.2). Guarantees each geometric
## shape maps to a UNIQUE modifier int (needed for mesher keying + equality):
##   * INTEGRATION-DECISIONS §3 addendum: `modifier != 0` on a non-solid material — a
##     "ramp of water" — strips to full cube (0) with a logged warning, so the merged
##     material gate may soundly ignore modifiers on non-solid cells;
##   * corner value 3 (the 2-bit slot permits it) clamps to 2;
##   * all-corners-2 (BOTTOM or TOP) collapses to modifier 0 (FULL cube), so a flat
##     surface generates byte-identical values to a plain block.
## The all-corners-0 (empty-shape → AIR) collapse lives in `canonical` above, since it
## zeroes the whole cell value, not just the modifier.
static func _canonical_modifier(material: int, modifier_bits: int) -> int:
	# Merged-contract gate (INTEGRATION-DECISIONS §3): a modifier on a non-solid
	# material — a "ramp of water" — is invalid; strip to full cube (0), log once.
	if modifier_bits != 0 and BlockCatalog.solidity_of(material) < 0.5:
		push_warning("CellCodec: modifier %d on non-solid material %d is invalid — stripped to full cube (0)"
			% [modifier_bits, material])
		return 0
	if modifier_bits == 0:
		return 0                              # FULL cube (fast path)
	# Future shape families (FAM = 1) carry no corner-height semantics — pass through.
	if modifier_bits & MOD_FAM_BIT:
		return modifier_bits & 0xFFFF
	# Corner-height family: clamp each 2-bit corner (value 3 → 2, VDS §3.2).
	var c0 := mini(modifier_bits & 3, 2)
	var c1 := mini((modifier_bits >> 2) & 3, 2)
	var c2 := mini((modifier_bits >> 4) & 3, 2)
	var c3 := mini((modifier_bits >> 6) & 3, 2)
	# All-corners-2 (BOTTOM or TOP) is the FULL cube → modifier 0 (so a flat surface
	# generates byte-identical values to a plain block). Collapsing here BEFORE the
	# anchor is re-applied is what maps both anchor variants to 0.
	if c0 == 2 and c1 == 2 and c2 == 2 and c3 == 2:
		return 0
	var anc := modifier_bits & MOD_ANC_BIT
	return c0 | (c1 << 2) | (c2 << 4) | (c3 << 6) | anc

## P6 hook — validate state bits against the material's declared state_layout
## (VOXEL-DATA-STRUCTURE §3.2/§10.3), clamping unknown bits. Pass-through until
## the state machinery lands.
static func _validate_state(_material: int, state_bits: int) -> int:
	return state_bits
