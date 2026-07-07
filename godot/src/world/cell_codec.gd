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

## FAM shape families (SNOW-ACCUMULATION §1.2). When MOD_FAM_BIT is set the corner-height
## semantics do NOT apply; bits 14..12 select the family KIND and the low bits carry
## family-specific data. FAM_LAYER (kind 0) is a UNIFORM thin layer — a flat top at height
## `level/10` block, BOTTOM-anchored — with the level (tenths, 1..9) in bits 3..0 and bits 11..4
## reserved 0. It is the variable-height snow depth (0→1) that replaces the fixed half-slab.
const MOD_FAM_KIND_SHIFT := 12
const MOD_FAM_KIND_MASK := 0x7                  # bits 14..12
const FAM_LAYER := 0
const MOD_LAYER_LEVEL_MASK := 0xF               # bits 3..0 — layer level in tenths
## Canonical form of LAYER level 5 (== a 0.5 uniform layer): the all-corners-1 BOTTOM slab
## (ShapeCodec.make_modifier(1,1,1,1,BOTTOM) == 85), so level 5 reuses the already-baked,
## collider-proven slab shape instead of a distinct FAM value (SNOW-ACCUMULATION §1.3 rule 5).
const LAYER_SLAB_MODIFIER := 85

## The canonical modifier for a snow LAYER of `level` tenths (1..10): level 10 → 0 (full cube;
## no dual encoding of a full cell), 5 → the corner slab (85), 1..4/6..9 → the FAM LAYER value,
## and level ≤ 0 → the empty marker MOD_FAM_BIT (canonical() then zeroes the whole cell to AIR).
static func make_layer(level: int) -> int:
	var lv := clampi(level, 0, 10)
	if lv <= 0:
		return MOD_FAM_BIT                       # empty layer → canonical() collapses the cell to AIR
	if lv >= 10:
		return 0                                 # full cube
	if lv == 5:
		return LAYER_SLAB_MODIFIER               # 0.5 uniform layer == the baked corner slab
	return MOD_FAM_BIT | lv                      # FAM LAYER, levels 1..4 / 6..9

## True when `m` is a FAM LAYER modifier (kind 0, reserved bits clear) — the case the ShapeCodec
## queries branch on. NOTE: the level-5 (85) and level-10 (0) canonical forms are NOT FAM values,
## so is_layer is false for them; use snow_tenths() for the level of ANY canonical snow modifier.
static func is_layer(m: int) -> bool:
	return (m & MOD_FAM_BIT) != 0 and ((m >> 4) & 0x7FF) == 0

## The level (tenths) of a FAM LAYER modifier — the raw low nibble. Only valid when is_layer(m);
## for the non-FAM canonical forms (the 85 slab, the 0 full cube) use snow_tenths().
static func layer_level(m: int) -> int:
	return m & MOD_LAYER_LEVEL_MASK

## Snow depth in tenths for a CANONICAL snow modifier (only meaningful on a snow cell): a FAM
## LAYER → its level; the corner slab (85) → 5; the full cube (0) → 10. Any other modifier → 0.
static func snow_tenths(m: int) -> int:
	if is_layer(m):
		return m & MOD_LAYER_LEVEL_MASK
	if m == LAYER_SLAB_MODIFIER:
		return 5
	if m == 0:
		return 10
	return 0

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

## Snow-fill nibble (SNOW-ACCUMULATION Decision 2.2): STATE bits 1..4 = the SNOW_FILL level in tenths
## (0 = none, 1..10 = the plane height inside a terrain remainder). It rides the STATE axis because the
## composite's identity IS a state variant (MULTI-MATERIAL §3a). The four bit NAMES on the declaring
## materials are `snow_fill_b0..b3` (binary weights), with `snow_capped` staying pinned at index 0.
const STATE_SNOW_FILL_SHIFT := 1                 # bits 1..4 of STATE
const STATE_SNOW_FILL_MASK := 0xF << STATE_SNOW_FILL_SHIFT

## STATE-bit name → value map (mirrors LIQ_KIND_BY_NAME). The reverse global shorthand for
## worldgen/render; per-material bit MEANING still comes from each material's declared state_layout.
const STATE_BIT_BY_NAME := {&"snow_capped": STATE_SNOW_CAPPED}

## The snow-fill level (tenths, 0..10) carried by `v` — the plane height inside the cell's terrain
## remainder (SNOW-ACCUMULATION §2.2). 0 = no fill. Only meaningful on a solid partial (ramp) cell of a
## declaring material; canonical() strips it everywhere else.
static func snow_fill(v: int) -> int:
	return (state(v) >> STATE_SNOW_FILL_SHIFT) & 0xF

## Set the snow-fill level (tenths) of `v`, leaving snow_capped + any other state bits, plus
## material/modifier/liquid, intact. Route real writes through canonical() (WorldManager._write_cell).
static func with_snow_fill(v: int, level: int) -> int:
	var st := state(v) & ~STATE_SNOW_FILL_MASK
	st |= (clampi(level, 0, 15) & 0xF) << STATE_SNOW_FILL_SHIFT
	return with_state(v, st)

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
	# A canonicalized shape with NO occupied volume is an EMPTY shape — the cell is AIR (VDS §3.2 /
	# SUB-VOXEL §3.1). Two forms: a corner-height shape with all four corners 0 but a nonzero
	# encoding (e.g. a TOP anchor bit); or a FAM LAYER of level 0 (the bare MOD_FAM_BIT marker).
	# Modifier 0 (the FULL-cube encoding) is deliberately excluded.
	if cm == MOD_FAM_BIT:
		return 0                              # empty FAM LAYER (level 0) → AIR
	if cm != 0 and (cm & MOD_FAM_BIT) == 0 and (cm & MOD_CORNERS_MASK) == 0:
		return 0
	return pack(m, cm, _canonical_snow_fill(m, cm, _validate_state(m, state(v))),
		_canonical_liquid(m, cm, liquid_field(v)))

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
	# FAM shape families (SNOW-ACCUMULATION §1.3). Only FAM_LAYER (kind 0) exists today; an
	# unknown family kind or a nonzero reserved band is malformed → strip to full cube (warn),
	# the "ramp of water" discipline. A LAYER canonicalizes via make_layer: level 10 → 0 (full
	# cube), 5 → the corner slab (85), 0 → MOD_FAM_BIT (the empty marker canonical() collapses to
	# AIR), 1..4/6..9 → the FAM value. This keeps ONE modifier int per geometric shape.
	if modifier_bits & MOD_FAM_BIT:
		var kind := (modifier_bits >> MOD_FAM_KIND_SHIFT) & MOD_FAM_KIND_MASK
		var reserved := (modifier_bits >> 4) & 0xFF
		if kind != FAM_LAYER or reserved != 0:
			push_warning("CellCodec: unknown FAM shape family (kind %d, reserved %d) — stripped to full cube (0)"
				% [kind, reserved])
			return 0
		return make_layer(modifier_bits & MOD_LAYER_LEVEL_MASK)
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

## Snow-fill canonicalization (SNOW-ACCUMULATION §2.3), mirroring `_canonical_liquid` rule-for-rule.
## Takes the cell's material, its ALREADY-canonicalized modifier, and the ALREADY-validated STATE
## bits; returns the canonical STATE (the fill nibble adjusted, other state bits untouched). A stripped
## fill is simply "absent" (0 in the nibble); a genuine violation logs. The fill can ONLY sit on a
## SOLID PARTIAL (corner-height ramp) cell — never on air (canonical() zeroed it), non-solid, a full
## cube (no remainder), or a LAYER (snow-on-snow is just a higher level, Decision 4 owns it).
static func _canonical_snow_fill(material: int, canonical_mod: int, state_bits: int) -> int:
	var fill := (state_bits >> STATE_SNOW_FILL_SHIFT) & 0xF
	if fill == 0:
		return state_bits                         # rule 1: absent
	var stripped := state_bits & ~STATE_SNOW_FILL_MASK
	if BlockCatalog.solidity_of(material) < 0.5:
		return stripped                           # rule 3: no snow-filled water
	if canonical_mod == 0:
		return stripped                           # rule 4: a full cube has no remainder to fill
	if (canonical_mod & MOD_FAM_BIT) != 0:
		return stripped                           # rule 5: fill on a LAYER — snow-on-snow, not a fill
	# rule 6: a plane at/below the terrain minimum everywhere adds nothing (corner half-units → 5 tenths).
	if fill <= 5 * _min_corner(canonical_mod):
		return stripped
	if fill > 10:
		return (state_bits & ~STATE_SNOW_FILL_MASK) | (10 << STATE_SNOW_FILL_SHIFT)   # rule 2: clamp
	return state_bits

## The smallest of a corner-height modifier's four 2-bit corners (half-block units 0..2) — the terrain
## minimum used by `_canonical_snow_fill` rule 6. `canonical_mod` is a non-zero, non-FAM modifier.
static func _min_corner(m: int) -> int:
	return mini(mini(m & 3, (m >> 2) & 3), mini((m >> 4) & 3, (m >> 6) & 3))

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
