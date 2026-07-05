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
	return pack(m, _canonical_modifier(modifier(v)), _validate_state(m, state(v)))

## P5 hook — corner-height canonicalization (FULL-cube shapes → 0, corner-value
## clamp; VOXEL-DATA-STRUCTURE §3.2). Pass-through until the modifier axis lands.
static func _canonical_modifier(modifier_bits: int) -> int:
	return modifier_bits

## P6 hook — validate state bits against the material's declared state_layout
## (VOXEL-DATA-STRUCTURE §3.2/§10.3), clamping unknown bits. Pass-through until
## the state machinery lands.
static func _validate_state(_material: int, state_bits: int) -> int:
	return state_bits
