class_name CellCodec
extends RefCounted
## Static, pure packing/projection for the enriched voxel cell value
## (VOXEL-DATA-STRUCTURE.md §3.3). The scalar axes — material, modifier, state,
## and the LIQUID overlay (WATER-SHORE §2) — pack into one 64-bit int (GDScript's
## native int, stored inline in a Variant, no heap):
##
##   bit 63   62……54   53      50 49    48 47      32 31      16 15         0
##  ┌───┬───────────┬────────────┬─────────┬──────────┬──────────┬────────────┐
##  │ 0 │ reserved  │ LIQ_LEVEL  │ LIQ_KIND│  STATE   │ MODIFIER │ MATERIAL   │
##  │   │  (= 0)    │  (4 bits)  │ (2 bits)│          │          │   LRID     │
##  └───┴───────────┴────────────┴─────────┴──────────┴──────────┴────────────┘
##
## value 0 == air (air never carries modifier/state/liquid; enforced by canonical()).
## A bare legacy block id (0..65535) IS a valid packed value meaning "full cube,
## state 0, no liquid" — so `_edits`, VoxelBody.cells and every generated id migrate
## for free. This class is the single composed-query codec: material, modifier,
## state and the liquid overlay are bit-projections of ONE int, so they can never
## desync. The LIQUID axis (bits 48..53) is a pure render+sim overlay — no physics
## function reads it; field 0 = no liquid (the zero-cost default). Bits 54..62 and
## bit 63 are always 0 after any pack()/canonical().

const MAT_MASK := 0xFFFF

## Modifier sub-fields (VDS §3.2 / SUB-VOXEL §3.1). Corner heights live in bits 0..7
## (two bits each), the anchor in bit 8, a family tag in bit 15.
const MOD_CORNERS_MASK := 0xFF
const MOD_ANC_BIT := 1 << 8
const MOD_FAM_BIT := 1 << 15

## FAM shape-family dispatch (SHARP-SLOPE §1.1 / SNOW-ACCUMULATION §1.1). When MOD_FAM_BIT is
## set the modifier is a "family" shape whose 3-bit KIND field (bits 14..12) selects the family:
## kind 0 = LAYER (snow accumulation — lives on a DIFFERENT branch, NOT implemented here; strips
## to full cube on this branch), kind 1 = SLOPE (this ADR). Any other kind (or an unimplemented
## one) strips to full cube + warns in _canonical_modifier. The bare marker MOD_FAM_BIT (kind 0,
## no payload) is the shared "empty FAM shape" → collapsed to AIR by canonical().
const MOD_FAM_KIND_SHIFT := 12
const MOD_FAM_KIND_MASK := 0x7
const FAM_SLOPE := 1

## SLOPE family (SHARP-SLOPE §1.2): four 3-bit signed WHOLE-block corner deltas, bias +3, packed
## low-bits-first in ShapeCodec corner order (c00 @ bits 0..2, c10 @ 3..5, c11 @ 6..8, c01 @ 9..11).
## `k_i = d_i + 3`, `d_i ∈ {−3..+4}` = the height of corner i's terrain plane above THIS cell's
## floor, in blocks. Always BOTTOM-anchored (no anchor bit under FAM). The encoding is total —
## all 4096 payloads decode to a valid tuple.
const MOD_SLOPE_BIAS := 3

## True iff `m` is a canonical SLOPE modifier (FAM bit set AND kind field == FAM_SLOPE).
static func is_slope(m: int) -> bool:
	return (m & MOD_FAM_BIT) != 0 and ((m >> MOD_FAM_KIND_SHIFT) & MOD_FAM_KIND_MASK) == FAM_SLOPE

## Biased-decode a SLOPE modifier to its four signed WHOLE-block corner deltas (d00, d10, d11, d01),
## in ShapeCodec corner order. Assumes is_slope(m); on any other value the result is meaningless.
static func slope_deltas(m: int) -> Vector4i:
	return Vector4i(
		(m & 7) - MOD_SLOPE_BIAS,
		((m >> 3) & 7) - MOD_SLOPE_BIAS,
		((m >> 6) & 7) - MOD_SLOPE_BIAS,
		((m >> 9) & 7) - MOD_SLOPE_BIAS)

## Build the CANONICAL modifier for a SLOPE cell whose four corner terrain-plane heights above the
## cell FLOOR are (d00, d10, d11, d01) whole blocks (SHARP-SLOPE §1.2/§1.3). Applies the same
## canonical collapse rules _canonical_modifier's SLOPE branch does, so a hand-built slope is
## already in canonical form: full cube (all d ≥ 1 → 0), empty (all d ≤ 0 → MOD_FAM_BIT, which
## canonical() collapses to AIR), legacy-expressible (all d ∈ {0,1} → the corner modifier), else
## the raw SLOPE encoding.
static func make_slope(d00: int, d10: int, d11: int, d01: int) -> int:
	return _canonical_slope(d00, d10, d11, d01)

## The raw (non-canonical) SLOPE bit encoding for a delta tuple — clamps each delta to {−3..+4}.
static func _slope_raw(d00: int, d10: int, d11: int, d01: int) -> int:
	var k00 := clampi(d00 + MOD_SLOPE_BIAS, 0, 7)
	var k10 := clampi(d10 + MOD_SLOPE_BIAS, 0, 7)
	var k11 := clampi(d11 + MOD_SLOPE_BIAS, 0, 7)
	var k01 := clampi(d01 + MOD_SLOPE_BIAS, 0, 7)
	return MOD_FAM_BIT | (FAM_SLOPE << MOD_FAM_KIND_SHIFT) | (k01 << 9) | (k11 << 6) | (k10 << 3) | k00

## Canonicalize a SLOPE delta tuple (SHARP-SLOPE §1.3): rules 1 (full) / 2 (empty) / 3 (legacy
## collapse) / 4 (keep). ONE authority shared by make_slope and _canonical_modifier so a shape maps
## to a unique modifier int (mesher keying + equality).
static func _canonical_slope(d00: int, d10: int, d11: int, d01: int) -> int:
	if d00 >= 1 and d10 >= 1 and d11 >= 1 and d01 >= 1:
		return 0                              # rule 1: full cube (plane at/above the ceiling everywhere)
	if d00 <= 0 and d10 <= 0 and d11 <= 0 and d01 <= 0:
		return MOD_FAM_BIT                    # rule 2: empty (shared FAM marker → AIR via canonical())
	if d00 >= 0 and d00 <= 1 and d10 >= 0 and d10 <= 1 and d11 >= 0 and d11 <= 1 and d01 >= 0 and d01 <= 1:
		# rule 3: every delta in [0,1] → the clip is inert, so the clipped plane IS the legacy linear
		# ramp; use the legacy corner encoding (reuses the collider-proven baked models).
		return ShapeCodec.make_modifier(2 * d00, 2 * d10, 2 * d11, 2 * d01, ShapeCodec.ANCHOR_BOTTOM)
	return _slope_raw(d00, d10, d11, d01)     # rule 4: keep the tuple

## Liquid axis (WATER-SHORE §2): bits 48..53. Kind in 48..49, level (tenths) in 50..53.
## A pure render+sim overlay orthogonal to material/modifier/state — no physics function
## reads it. Field 0 = no liquid (zero-cost default). The bare water id is THE canonical
## full-water cell (level 10 strips to field 0), so today's deep-water values are unchanged.
const LIQ_SHIFT := 48
const LIQ_FIELD_MASK := 0x3F
const LIQ_KIND_MASK := 0x3
const LIQ_NONE := 0
const LIQ_WATER := 1
const LIQ_LAVA := 2               # was reserved (WATER-SHORE §2.1); kind 3 stays reserved for a third liquid
const LIQ_LEVEL_SURFACE := 9      # top at 0.9 — the water-line cell
const LIQ_LEVEL_FULL := 10        # top at 1.0 — submerged composite

## Liquid-kind name → value map (MULTI-LIQUID §2.1). This codec is the single authority
## on the LIQ_KIND bit meanings; BlockCatalog resolves blocks.json "liquid_kind" strings
## through this map. Extend with the next reserved value (3) when a third liquid lands.
const LIQ_KIND_BY_NAME := {&"water": LIQ_WATER, &"lava": LIQ_LAVA}

## STATE axis (VDS §3.2/§10.3): behavioural variants of a material, bits 32..47. Positional +
## per-material — the name at index i of a material's `state_layout` names bit i, and the material's
## valid-bit mask is `BlockCatalog.state_mask_of`. `snow_capped` is bit 0 (M1 snowy world), pinned
## to index 0 on every material that declares it (verify), so this GLOBAL shorthand is safe for
## worldgen/render. State is disjoint from the liquid overlay at the STAMPING level (worldgen never
## produces both on one cell); the codec does not forbid the combination.
const STATE_SNOW_CAPPED := 1                     # bit 0 of STATE (bits 32..47)

## STATE-bit name → value map (mirrors LIQ_KIND_BY_NAME). The reverse global shorthand for
## worldgen/render; per-material bit MEANING still comes from each material's declared state_layout.
const STATE_BIT_BY_NAME := {&"snow_capped": STATE_SNOW_CAPPED}

## The 16-bit STATE field (bits 32..47) of a packed cell.
const STATE_MASK := 0xFFFF

## True iff the cell's STATE field has (all of) `bit` set.
static func has_state(v: int, bit: int) -> bool:
	return (state(v) & bit) != 0

## Replace the STATE field of `v` with `bits`, leaving material/modifier/liquid intact.
static func with_state(v: int, bits: int) -> int:
	return (v & ~(STATE_MASK << 32)) | ((bits & STATE_MASK) << 32)

## The 6-bit liquid field (kind + level) — 0 means "no liquid".
static func liquid_field(v: int) -> int:
	return (v >> LIQ_SHIFT) & LIQ_FIELD_MASK

## Liquid kind (0 = none, 1 = water, 2 = lava, 3 reserved).
static func liquid_kind(v: int) -> int:
	return (v >> LIQ_SHIFT) & LIQ_KIND_MASK

## Liquid top height in tenths of a block (canonical 1..10; 9 = 0.9 surface, 10 = full).
static func liquid_level(v: int) -> int:
	return (v >> (LIQ_SHIFT + 2)) & 0xF

## Liquid top height as a fraction of a block (level / 10.0).
static func liquid_top(v: int) -> float:
	return float(liquid_level(v)) / 10.0

## Clear the liquid field (bits 48..53), leaving material/modifier/state intact.
static func strip_liquid(v: int) -> int:
	return v & ~(LIQ_FIELD_MASK << LIQ_SHIFT)

## The 6-bit liquid FIELD value for (kind, level) — combine into a cell via pack()/with_liquid().
static func make_liquid(kind: int, level: int) -> int:
	return (kind & LIQ_KIND_MASK) | ((level & 0xF) << 2)

## Set the liquid field of `v` to (kind, level), replacing any existing liquid.
static func with_liquid(v: int, kind: int, level: int) -> int:
	return strip_liquid(v) | (make_liquid(kind, level) << LIQ_SHIFT)

## Material (LRID) — low 16 bits.
static func mat(v: int) -> int:
	return v & MAT_MASK

## Modifier (geometric occupancy) — bits 16..31.
static func modifier(v: int) -> int:
	return (v >> 16) & 0xFFFF

## State (behavioural variant) — bits 32..47.
static func state(v: int) -> int:
	return (v >> 32) & 0xFFFF

## Compose a packed cell value from the axes. `liquid` is the 6-bit liquid FIELD
## (make_liquid(kind, level)); it defaults to 0 so every existing 1..3-arg call site
## packs an unchanged value. Bits 54..62 and 63 are masked to 0 by construction.
static func pack(mat: int, modifier := 0, state := 0, liquid := 0) -> int:
	return (mat & MAT_MASK) | ((modifier & 0xFFFF) << 16) | ((state & 0xFFFF) << 32) \
		| ((liquid & LIQ_FIELD_MASK) << LIQ_SHIFT)

## True when the cell is a plain full cube in its default state (modifier 0,
## state 0) — the overwhelming common case and the zero-cost-default fast path.
## Equivalent to "bits 16..63 all zero".
static func is_plain(v: int) -> bool:
	return (v >> 16) == 0

## The canonical form of a packed value — the ONE transform every write funnels
## through (WorldManager._write_cell). Guarantees:
##   * air-zeroing: any cell whose material is AIR collapses to exactly 0, so air
##     can never carry a stray modifier/state/liquid (keeps `is_plain`/equality honest);
##   * modifier canonical form: delegated to _canonical_modifier (P5 hook);
##   * state validation: delegated to _validate_state (P6 hook);
##   * liquid canonical form: delegated to _canonical_liquid (WATER-SHORE §2.3).
## In P0 the state hook is a pass-through stub (documented below).
static func canonical(v: int) -> int:
	var m := mat(v)
	if m == BlockCatalog.AIR:
		return 0                              # air never carries modifier/state/liquid
	var cm := _canonical_modifier(m, modifier(v))
	# The shared empty-FAM marker (MOD_FAM_BIT bare, no kind/payload — SHARP-SLOPE §1.3 rule 2) is an
	# EMPTY shape → the cell is AIR.
	if cm == MOD_FAM_BIT:
		return 0
	# A canonicalized corner-height shape with all four corners 0 but a nonzero
	# encoding (e.g. a TOP anchor bit) is an EMPTY shape — the cell is AIR (VDS §3.2 /
	# SUB-VOXEL §3.1). Modifier 0 (the FULL-cube encoding) is deliberately excluded.
	if cm != 0 and (cm & MOD_FAM_BIT) == 0 and (cm & MOD_CORNERS_MASK) == 0:
		return 0
	return pack(m, cm, _validate_state(m, state(v)), _canonical_liquid(m, cm, liquid_field(v)))

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
	# FAM shape families (bit 15): dispatch on the KIND field (SHARP-SLOPE §1.3). The bare empty
	# marker passes through (canonical() collapses it to AIR); kind 1 = SLOPE canonicalizes via the
	# shared _canonical_slope; any other kind (incl. kind 0 LAYER, not implemented on this branch)
	# strips to full cube + warns. This kind-1 dispatch is ADDITIVE — it reconciles at merge with the
	# snow branch's kind-0 LAYER dispatch (see the SHARP-SLOPE ADR FAM-branch note).
	if modifier_bits & MOD_FAM_BIT:
		if modifier_bits == MOD_FAM_BIT:
			return MOD_FAM_BIT                # bare empty-FAM marker → AIR (via canonical())
		var kind := (modifier_bits >> MOD_FAM_KIND_SHIFT) & MOD_FAM_KIND_MASK
		if kind == FAM_SLOPE:
			var d := slope_deltas(modifier_bits)
			return _canonical_slope(d.x, d.y, d.z, d.w)
		push_warning("CellCodec: unknown FAM kind %d in modifier %d — stripped to full cube (0)"
			% [kind, modifier_bits])
		return 0
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
## (VOXEL-DATA-STRUCTURE §3.2/§10.3, M1 snowy world): undeclared bits are silently masked
## to 0 (the "0 is absent" convention — not a warning). The mask is the low
## `state_layout.size()` bits (BlockCatalog.state_mask_of): AIR/out-of-range → 0 (air carries
## no state); an UNRESOLVED placeholder → 0xFFFF (permissive, keeps bits until late resolution).
static func _validate_state(material: int, state_bits: int) -> int:
	if state_bits == 0:
		return 0
	return state_bits & BlockCatalog.state_mask_of(material)

## Liquid-axis canonicalization (WATER-SHORE §2.3). Takes the cell's material, its
## ALREADY-canonicalized modifier, and the raw 6-bit liquid field; returns the canonical
## 6-bit field (0 = absent). The air case (rule 1) is handled by canonical() zeroing the
## whole value. Silent strip where 0 is simply "absent"; push_warning on genuine
## violations, mirroring _canonical_modifier's style. NOTE: this NEVER touches the
## modifier — the non-solid-modifier strip ("no ramp of water") stays entirely in
## _canonical_modifier; water is expressed ONLY on this axis.
static func _canonical_liquid(material: int, canonical_mod: int, liquid: int) -> int:
	if liquid == 0:
		return 0
	var kind := liquid & LIQ_KIND_MASK
	var level := (liquid >> 2) & 0xF
	if kind == 0:
		return 0                              # rule 2: level bits without a kind mean nothing
	if level == 0:
		return 0                              # rule 3: a kind with no height is absent
	if level > LIQ_LEVEL_FULL:
		level = LIQ_LEVEL_FULL                # rule 4: clamp to full
	if BlockCatalog.solidity_of(material) < 0.5:
		# Rule 5: the cell IS a liquid (non-solid host). Kind must match the material's own
		# liquid identity; level 10 strips to the bare id (the canonical full-water cell).
		if kind != BlockCatalog.liquid_kind_of(material):
			push_warning("CellCodec: liquid kind %d != non-solid host %d liquid identity — stripped"
				% [kind, material])
			return 0
		if level == LIQ_LEVEL_FULL:
			return 0                          # bare water id IS canonical full water (no dual encoding)
		return make_liquid(kind, level)       # levels 1..9 kept (9 = the sunk 0.9 surface)
	# Rule 6: solid host. A full cube (modifier 0) has no remainder to fill — waterlogged
	# full cubes are out of v1 scope; any nonzero modifier (either anchor) may carry liquid.
	if canonical_mod == 0:
		push_warning("CellCodec: liquid on a full solid cube (material %d) is out of v1 scope — stripped"
			% material)
		return 0
	# The overlay kind on a solid composite is an OVERLAY liquid (independent of the solid
	# host material, so liquid_kind_of(host) does not apply here). Validate it against the
	# DECLARED-liquid set — mirroring rule 5's kind check so a reserved/garbage kind can't
	# survive on a solid host either. Any KNOWN kind (water, lava, a future third) may
	# waterlog a solid composite; only a genuinely unknown/reserved kind is stripped.
	if not BlockCatalog.is_liquid_kind_known(kind):
		push_warning("CellCodec: unknown liquid kind %d on solid composite (material %d) — stripped"
			% [kind, material])
		return 0
	return make_liquid(kind, level)
