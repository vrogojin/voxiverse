class_name StructureGen
extends RefCounted
## COSMOS STRUCTURES P1a (docs/COSMOS-STRUCTURES-DESIGN.md §5 + §12) — the procedural VILLAGE generator.
## All static, hash-of-position, NO state — mirroring tree_gen.gd exactly so a house is worldgen (generated
## cells), NOT edits. Consulted BESIDE TreeGen.block_at at the two resolve_cell airspace sites (terrain_config.gd),
## so NEAR rendering, analytic physics, floor_under, the DDA raycast, GroundCollider, _collapse_unsupported and the
## far decimator ALL see the house through block_id_at with zero new machinery (CLAUDE.md rule 1). Everything is
## gated behind CubeSphere.FP_STRUCT_GEN at the CALL sites (this class is pure; the flag only decides consultation),
## so flag-off is byte-identical.
##
## THE LATTICE (§12.4): a village occupies one cell of a V×V column grid; a live village hosts up to HPV×HPV houses
## on an HCELL sub-lattice (V == HPV·HCELL, so a house is fully inside its own H-cell ⇒ block_at consults only (x,z)'s
## OWN sub-cell candidate — O(1), the identical bijection trick TreeGen._base_pos uses for a canopy).
##
## CARVE-TO-MIN LEVELING: a village LEVELS its build site instead of REQUIRING pre-flat terrain (per-house pad).
## base_y = the MINIMUM of the 4 footprint-corner column_tops, so the pad sits at/below every footprint column ⇒ a
## house only ever CARVES terrain DOWN (returns AIR for terrain above the pad), never FILLS above natural ground —
## which keeps the height budget: house top = base_y + 1 + roof ≤ min_g + 12 ≤ g + 14 for corner-bounded columns.
## The sub-floor (y ≤ base_y) is NATURAL terrain, byte-untouched (no foundation) — the solid base of the pad.
##
## THE HEIGHT-BUDGET LAW (§12.2): the tallest solid claim is the roof at base_y + 1 + roof_top_ly ≤ base_y + 12 ≤
## g + 14 (= TreeGen.MAX_ABOVE_SURFACE), and carve AIR cells are ≤ g. The whole-BLOCK air-ceiling stencil (max_above
## = 14, keyed on the block's MAX column height ≥ min corner) therefore stays valid with ZERO changes.
##
## claim_at TRI-STATE (§12.3): −1 (no claim — fall through to natural terrain / sea / snow / cap / tree), 0 (AIR —
## AUTHORITATIVE: interior/door air AND the carved footprint above the pad, suppressing the snow stack + smoothing
## lip), >0 (a house block id, which OVERRIDES the carve — a buried floor/wall course wins over the terrain it cuts).
## Consulted at y ≤ g (the solid stackup, to carve) AND y > g (airspace); flag-off ⇒ never consulted ⇒ byte-identical.

# --- placement lattice (columns) ---------------------------------------------------------------------------------
const STRUCT_V := 192               # village lattice pitch (columns) — ~2-4 candidate cells per facet
const STRUCT_HCELL := 32            # house sub-lattice pitch inside a live village
const STRUCT_HPV := 6               # HPV := STRUCT_V / STRUCT_HCELL — house sub-cells per axis in a village
const STRUCT_FOOT_MAX := 11         # footprint ≤ 11×11; jitter ∈ [2, HCELL−w−2] ⇒ whole footprint inside its H-cell
const STRUCT_FOOT_MIN := 5          # smallest footprint dimension
const VILLAGE_CHANCE := 0.05        # salt 201 gate on the (vx, vz) village cell
const HOUSE_CHANCE := 0.55          # salt 202 gate per (hx, hz) sub-cell inside a live village
const STRUCT_H_MAX := 11            # §12.2 tallest cell over base: walls ≤ 4 + roof ≤ 7 (gable capped to fit)
const STRUCT_FLAT_TOL := 3          # §12.2 height-budget slack: STRUCT_H_MAX + STRUCT_FLAT_TOL = MAX_ABOVE_SURFACE = 14
const STRUCT_LEVEL_TOL := 16        # CARVE-TO-MIN: site/footprint terrain-variation cap — villages on rolling plains,
									 # NOT sheer cliffs; also bounds the per-column carve depth to ≤ 16 below the pad
const FOUNDATION_MAX := 4           # legacy (no foundation under carve-to-min); kept for record/scan padding
const WALL_MIN := 3                 # wall course count ∈ [3, 4]
const WALL_MAX := 4

# --- salt registry: StructureGen OWNS 201-209 (disjoint from TreeGen 11-125 / TerrainConfig 101-105, 7xx) ---------
const _SALT_VILLAGE := 201          # village-cell gate
const _SALT_HOUSE := 202            # per-house gate
const _SALT_JITX := 203            # footprint x jitter
const _SALT_JITZ := 204            # footprint z jitter
const _SALT_W := 205               # footprint width
const _SALT_D := 206               # footprint depth
const _SALT_WALLH := 207           # wall-course count
const _SALT_DOOR := 208            # door side (0..3)
const _SALT_ROOF := 209            # roof type + material pick

const _NO_G := -0x40000000          # "no ground supplied" sentinel for claim_at's optional g fast-path

const SOURCE_GEN := 1               # §3 record `source` — mirrors StructureTracker.SOURCE_GEN

# Cached house material ids (resolved once, main thread, from the data-driven BlockCatalog).
static var _mat_ready := false
static var _FOUNDATION := 0         # cobble analogue (stone)
static var _FLOOR := 0              # solid floor (stone)
static var _WALL := 0              # plank walls (wood)
static var _POST := 0              # log corner posts (dark_oak_log)
static var _ROOF := 0              # roof planks (dark_oak_log)
static var _WINDOW := 0            # window pane (glass)


## Warm the house material id cache on the main thread (called from TerrainConfig.warm_up so the voxel worker
## never races BlockCatalog.id_of into existence). Behaviour-neutral when FP_STRUCT_GEN is off (claim_at is never
## consulted), so calling it unconditionally keeps flag-off byte-identical.
static func warm_up() -> void:
	if _mat_ready:
		return
	BlockCatalog.ensure_ready()
	_FOUNDATION = BlockCatalog.id_of(&"stone")
	_FLOOR = BlockCatalog.id_of(&"stone")
	_WALL = BlockCatalog.id_of(&"wood")
	_POST = BlockCatalog.id_of(&"dark_oak_log")
	_ROOF = BlockCatalog.id_of(&"dark_oak_log")
	_WINDOW = BlockCatalog.id_of(&"glass")
	_mat_ready = true


## Deterministic hash in [0,1) — a VERBATIM copy of TreeGen._hash01's integer mix (tree_gen.gd:89-93), so the C++
## mirror (P1b) reuses cosmos::tree_hash01 with new salts and inherits ZERO new transcription traps.
static func _hash01(ix: int, iz: int, salt: int) -> float:
	var n := (ix * 374761393 + iz * 668265263 + salt * 362437) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65536.0


# =====================================================================================================================
# Body gate (§12.4) — villages exist on EARTH facets ONLY. The Moon aliases biome ids 11/12/13 (B_SAVANNA/B_JUNGLE),
# so a biome-only site test would place villages on moon columns (the [[voxiverse-tree-bugs-rootcause]] alias trap).
# The body is a function of the FACET, carried by the GenCtx pcache (worker/enum) or the active facet (analytic).
# =====================================================================================================================
static func _fid_of(pcache) -> int:
	if pcache is TerrainConfig.GenCtx:
		return int((pcache as TerrainConfig.GenCtx).facet)
	return TerrainConfig.active_facet() if CubeSphere.FACETED else -1

## True iff the query is homed on an EARTH facet (villages require FACETED + body 0). −1 (flat / no facet) ⇒ false.
static func _is_earth(pcache) -> bool:
	var fid := _fid_of(pcache)
	return fid >= 0 and FacetAtlas.body_of_fid(fid) == 0


# =====================================================================================================================
# has_village (§12.4) — body gate FIRST, then salt-201, then the site test (biome / flatness / above-sea). Pure.
# =====================================================================================================================
static func has_village(vx: int, vz: int, pcache = null) -> bool:
	if not _is_earth(pcache):
		return false                                   # body gate FIRST (the Moon biome-id alias trap)
	if _hash01(vx, vz, _SALT_VILLAGE) >= VILLAGE_CHANCE:
		return false
	# Site test on the village ANCHOR column (deterministic centre of the V-cell).
	var ax := vx * STRUCT_V + STRUCT_V / 2
	var az := vz * STRUCT_V + STRUCT_V / 2
	if not _site_biome_ok(TerrainConfig.biome_at(ax, az, pcache)):
		return false
	# CARVE-TO-MIN cliff exclusion: measure the site's terrain variation over a 4×4 stencil (pitch 8, a
	# 24-block span) and reject only SHEER sites (variation > STRUCT_LEVEL_TOL). Villages now level rolling
	# plains instead of requiring pre-flat ground; the ≤16 cap bounds how deep a house carves its pad.
	var mn := 0x7fffffff
	var mx := -0x7fffffff
	for iz in range(4):
		for ix in range(4):
			var h := TerrainConfig.column_top(ax + ix * 8, az + iz * 8, pcache)
			mn = mini(mn, h)
			mx = maxi(mx, h)
	if mx - mn > STRUCT_LEVEL_TOL:
		return false
	# Above the water line so no half-drowned village.
	if TerrainConfig.column_top(ax, az, pcache) <= TerrainConfig.SEA_LEVEL + 2:
		return false
	return true

## Site biome gate — B_PLAINS always, B_SAVANNA only under FP_CLIMATE_BIOMES (reusing the flag EXACTLY as
## TreeGen._species_for does, so both flag states are correct — §12.1 consequence 2).
static func _site_biome_ok(b: int) -> bool:
	if b == TerrainConfig.B_PLAINS:
		return true
	if CubeSphere.FP_CLIMATE_BIOMES and b == TerrainConfig.B_SAVANNA:
		return true
	return false


# =====================================================================================================================
# house_info (§12.4) — the parametric house at H-cell (hx, hz), or {} when the cell hosts no house. Owning village
# live → salt-202 → footprint-corner flatness ≤ STRUCT_FLAT_TOL AND no corner on a firing slope → params from salts
# 203-209. Everything is a pure position hash, so near / far / physics reproduce the SAME house by construction.
# =====================================================================================================================
static func house_info(hx: int, hz: int, pcache = null) -> Dictionary:
	var vx := floori(float(hx) / float(STRUCT_HPV))
	var vz := floori(float(hz) / float(STRUCT_HPV))
	if not has_village(vx, vz, pcache):
		return {}
	if _hash01(hx, hz, _SALT_HOUSE) >= HOUSE_CHANCE:
		return {}
	# Footprint dimensions ∈ [FOOT_MIN, FOOT_MAX].
	var w := STRUCT_FOOT_MIN + int(_hash01(hx, hz, _SALT_W) * float(STRUCT_FOOT_MAX - STRUCT_FOOT_MIN + 1))
	var d := STRUCT_FOOT_MIN + int(_hash01(hx, hz, _SALT_D) * float(STRUCT_FOOT_MAX - STRUCT_FOOT_MIN + 1))
	# Jitter ∈ [2, HCELL−dim−2] keeps the WHOLE footprint inside its own H-cell ⇒ O(1) own-cell claim.
	var base_x := hx * STRUCT_HCELL + _jitter(hx, hz, _SALT_JITX, w)
	var base_z := hz * STRUCT_HCELL + _jitter(hx, hz, _SALT_JITZ, d)
	# Footprint-corner flatness + slope reject (terraces stay honest — sloped footprints are skipped).
	var cx := [base_x, base_x + w - 1, base_x + w - 1, base_x]
	var cz := [base_z, base_z, base_z + d - 1, base_z + d - 1]
	var mn := 0x7fffffff
	var mx := -0x7fffffff
	for i in range(4):
		var h := TerrainConfig.column_top(cx[i], cz[i], pcache)
		mn = mini(mn, h)
		mx = maxi(mx, h)
		if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(cx[i], cz[i], pcache)):
			return {}                                  # a corner on a firing slope — skip this house
	# CARVE-TO-MIN: skip only cliff footprints (variation > STRUCT_LEVEL_TOL); leveled sites are carved down.
	if mx - mn > STRUCT_LEVEL_TOL:
		return {}
	var wall_h := WALL_MIN + int(_hash01(hx, hz, _SALT_WALLH) * float(WALL_MAX - WALL_MIN + 1))
	var door := int(_hash01(hx, hz, _SALT_DOOR) * 4.0)           # 0=-x 1=+x 2=-z 3=+z
	var roof := 1 if _hash01(hx, hz, _SALT_ROOF) < 0.5 else 0    # 1 = gabled, 0 = flat
	# CARVE-TO-MIN: base.y = the LOWEST footprint corner. The pad sits at/below every footprint column ground,
	# so the house only ever CARVES terrain down (never fills above natural ground) — the height budget holds.
	var base_y := mn
	# Gable height, capped so wall_h + gable_h ≤ STRUCT_H_MAX (the height budget). < 1 ⇒ fall back to flat.
	var gable_h := 0
	if roof == 1:
		gable_h = mini(int(d / 2), STRUCT_H_MAX - wall_h)
		if gable_h < 1:
			roof = 0
	return {
		"vx": vx, "vz": vz, "hx": hx, "hz": hz,
		"base": Vector3i(base_x, base_y, base_z),
		"w": w, "d": d, "wall_h": wall_h, "door": door, "roof": roof, "gable_h": gable_h,
	}

## Footprint jitter for one axis: an offset ∈ [2, HCELL − dim − 2] (inclusive), so base+dim−1 ≤ HCELL−3 < next cell.
static func _jitter(hx: int, hz: int, salt: int, dim: int) -> int:
	var span := STRUCT_HCELL - dim - 3                  # count of offsets 2..(HCELL−dim−2)
	return 2 + int(_hash01(hx, hz, salt) * float(span))

## The topmost local y (relative to base.y) the roof reaches — the house's own vertical extent above the floor.
static func _roof_top_ly(hi: Dictionary) -> int:
	return int(hi["wall_h"]) + (int(hi["gable_h"]) if int(hi["roof"]) == 1 else 1)


# =====================================================================================================================
# claim_at (§12.3) — the hot-path tri-state query, consulted BESIDE the terrain stackup at the resolve_cell sites
# (airspace y>g for the house, AND the solid y≤g path for the CARVE). −1 fall-through / 0 authoritative air / >0 block.
#   `g` (optional): the column ground the caller already computed (resolve_cell passes it → zero recompute). Omitted
#   callers (the decimator sampler, the gates) supply _NO_G and claim_at reads column_top itself — the SAME value.
# =====================================================================================================================
static func claim_at(x: int, y: int, z: int, pcache = null, g: int = _NO_G) -> int:
	var cg := g if g != _NO_G else TerrainConfig.column_top(x, z, pcache)
	# y-window early-out with ZERO structure hashes (§12.3). The UPPER bound IS the height-budget law (§12.2): no
	# claim ever exceeds g + (STRUCT_H_MAX + STRUCT_FLAT_TOL) = g+14 = TreeGen.MAX_ABOVE_SURFACE, applied uniformly by
	# every consumer, so the streaming air-ceiling stencil never clips a house cell it didn't account for.
	# CARVE-TO-MIN LOWER early-out: a house never touches y ≤ base_y (the natural pad base), and base_y = the
	# min footprint corner ≥ cg − STRUCT_LEVEL_TOL for a corner-bounded column, so the deepest carve/floor cell
	# is > cg − STRUCT_LEVEL_TOL. Cells deeper than that can never be a claim (this bounds the carve depth too).
	# Replaces the old `y ≤ cg → −1` guard: the carve now DELIBERATELY fires at y ≤ g (to level the footprint).
	if cg - y > STRUCT_LEVEL_TOL:
		return -1                                      # below any possible flattened pad — natural terrain
	if y - cg > STRUCT_H_MAX + STRUCT_FLAT_TOL:
		return -1                                      # above every possible roof — the height-budget clamp
	# Village gate (1 hash kills ~95% of surviving columns), then the house gate, then the O(1) own-cell template.
	var vx := floori(float(x) / float(STRUCT_V))
	var vz := floori(float(z) / float(STRUCT_V))
	if not has_village(vx, vz, pcache):
		return -1
	var hx := floori(float(x) / float(STRUCT_HCELL))
	var hz := floori(float(z) / float(STRUCT_HCELL))
	var hi := house_info(hx, hz, pcache)
	if hi.is_empty():
		return -1
	return _template_block(hi, x, y, z, cg)


## The house TEMPLATE (§5.2) at world cell (x, y, z) given the house `hi` and this column's ground `cg`. Returns
## −1 (outside the house / above the roof / at-or-below ground), 0 (interior / door air — authoritative), or a
## house block id (>0). Materials are BlockCatalog ids only, resolved once in warm_up (a house style is a data change).
static func _template_block(hi: Dictionary, x: int, y: int, z: int, cg: int) -> int:
	if not _mat_ready:
		warm_up()
	var base: Vector3i = hi["base"]
	var w: int = hi["w"]
	var d: int = hi["d"]
	var lx := x - base.x
	var lz := z - base.z
	if lx < 0 or lx >= w or lz < 0 or lz >= d:
		return -1                                      # outside the footprint
	# CARVE-TO-MIN: the floor sits ONE course above the pad (base_y+1). ly < 0 (y ≤ base_y) is the natural
	# terrain forming the platform's solid base — byte-untouched, NO foundation fill (base_y = min footprint
	# corner ⇒ every footprint column is solid up to base_y, so there is nothing to fill).
	var ly := y - base.y - 1
	if ly < 0:
		return -1                                      # y ≤ base_y → natural pad base (fall through)
	if ly > _roof_top_ly(hi):
		# Above the house roof: terrain poking above the flattened pad (base_y < y ≤ g) is CARVED to air;
		# open sky above g stays fall-through.
		if y <= cg:
			return 0                                   # CARVE — authoritative air (levels the footprint)
		return -1                                      # open sky above g
	if ly == 0:
		return _FLOOR                                  # solid floor course at base_y+1
	var wall_h: int = hi["wall_h"]
	if ly <= wall_h:
		var edge := (lx == 0 or lx == w - 1 or lz == 0 or lz == d - 1)
		if not edge:
			return 0                                   # interior air — AUTHORITATIVE (suppresses snow stack + lip)
		# corner posts
		if (lx == 0 or lx == w - 1) and (lz == 0 or lz == d - 1):
			return _POST
		if _is_door(hi, lx, lz, ly):
			return 0                                   # door gap — authoritative air (passable)
		if _is_window(hi, lx, lz, ly, w, d):
			return _WINDOW
		return _WALL
	# Roof region (ly > wall_h).
	return _roof_block(hi, lx, lz, ly, w, d, wall_h)

## The door gap: a 1-wide, 2-tall opening at the centre of the hash-chosen wall (never a corner for w,d ≥ 3).
static func _is_door(hi: Dictionary, lx: int, lz: int, ly: int) -> bool:
	if ly > 2:
		return false
	var w: int = hi["w"]
	var d: int = hi["d"]
	var midw := w / 2
	var midd := d / 2
	match int(hi["door"]):
		0: return lx == 0 and lz == midd
		1: return lx == w - 1 and lz == midd
		2: return lz == 0 and lx == midw
		3: return lz == d - 1 and lx == midw
	return false

## One window per wall at mid height (ly == 2), the wall-centre cell — except where the door sits. Not a corner.
static func _is_window(hi: Dictionary, lx: int, lz: int, ly: int, w: int, d: int) -> bool:
	if ly != 2:
		return false
	if _is_door(hi, lx, lz, ly):
		return false
	var midw := w / 2
	var midd := d / 2
	if lz == 0 and lx == midw:
		return true
	if lz == d - 1 and lx == midw:
		return true
	if lx == 0 and lz == midd:
		return true
	if lx == w - 1 and lz == midd:
		return true
	return false

## Roof: a flat plank slab one course above the walls, OR a gable across the depth axis (two slope rows per course,
## the interior below is air). rtop = wall_h + gable_h ≤ STRUCT_H_MAX by construction (the height budget).
static func _roof_block(hi: Dictionary, lx: int, lz: int, ly: int, w: int, d: int, wall_h: int) -> int:
	if int(hi["roof"]) == 0:
		return _ROOF if ly == wall_h + 1 else 0        # flat slab (only ly == wall_h+1 reaches here)
	# Gabled across z: at course k, the two slope rows lz == k−1 and lz == d−k carry planks; inside is air.
	var k := ly - wall_h                                # ≥ 1
	if k - 1 > d - k:
		return 0                                       # above the ridge
	if lz == k - 1 or lz == d - k:
		return _ROOF
	return 0


# =====================================================================================================================
# Enumeration support (§12.5) — the record shape + the negative site-root pack the far tier / StructGenIndex reuse.
# =====================================================================================================================

## The §3-shape GEN record for house `hi` on facet `fid` (fid-lattice bbox). `root` is a NEGATIVE packed site id,
## structurally disjoint from tracker roots (edit keys ≥ 0), so the far tier's _baked/_cull keying + _root_hash
## (negative-safe mask) need ZERO changes. `rev` is 0 (pristine) — StructGenIndex overlays the damage counter.
static func make_record(fid: int, hi: Dictionary) -> Dictionary:
	if not _mat_ready:
		warm_up()
	var base: Vector3i = hi["base"]
	var w: int = hi["w"]
	var d: int = hi["d"]
	var rtop := _roof_top_ly(hi)
	# CARVE-TO-MIN: the house solid span is [base_y+1 (floor) .. base_y+1+rtop (roof)] — NO foundation below.
	var bmin := Vector3i(base.x, base.y + 1, base.z)
	var bmax := Vector3i(base.x + w - 1, base.y + 1 + rtop, base.z + d - 1)
	var ex := maxi(maxi(bmax.x - bmin.x + 1, bmax.y - bmin.y + 1), bmax.z - bmin.z + 1)
	return {
		"source": SOURCE_GEN,
		"root": pack_root(fid, int(hi["hx"]), int(hi["hz"])),
		"fid": fid,
		"bmin": bmin,
		"bmax": bmax,
		"rev": 0,
		"count": (bmax.x - bmin.x + 1) * (bmax.y - bmin.y + 1) * (bmax.z - bmin.z + 1),
		"mats": {_WALL: 1, _FLOOR: 1, _ROOF: 1},
		"max_extent": ex,
	}

## The NEGATIVE, unique, STABLE root for the house at H-cell (hx, hz) on facet `fid`. A house is owned by exactly one
## facet (the enumeration in_polygon test), so (fid, hx, hz) identifies it. 12-bit fid | 20-bit zig(hx) | 20-bit
## zig(hz), negated → always < 0 (disjoint from tracker roots ≥ 0), a pure function of position (evict/re-derive stable).
static func pack_root(fid: int, hx: int, hz: int) -> int:
	var a := (hx << 1) ^ (hx >> 63)                    # zigzag: signed → non-negative
	var b := (hz << 1) ^ (hz >> 63)
	var p := ((fid & 0xFFF) << 40) | ((a & 0xFFFFF) << 20) | (b & 0xFFFFF)
	return -(1 + p)
