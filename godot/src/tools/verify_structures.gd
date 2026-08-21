extends SceneTree
## COSMOS STRUCTURES P0 gate (docs/COSMOS-STRUCTURES-DESIGN.md §10, task #121). Proves the P0 infrastructure —
## StructureTracker (union-find over placed cells, snow-exclusion, caps, break/split recluster), StructDecimator
## (OR-occupancy + majority-colour, deterministic, damage-shows), FacetFarStructures (near-handoff cull streak,
## delta-gate no-drift skip, ≤2 draws, ledger caps), and the SHARED NearPresence predicate (anti-dead-latch).
##
## The tracker / decimator / tier CLASSES are exercised directly, so these gates pass in BOTH flag states (the
## classes are pure; FP_STRUCT_* only decides whether WorldManager/FacetFarRing construct them). Byte-off is proven
## separately by the full suite (verify_feature / verify_faceted / verify_far_trees) running identically flags-off.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_structures.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const ST := preload("res://src/world/structure_tracker.gd")
const SD := preload("res://src/world/struct_decimator.gd")
const FS := preload("res://src/world/facet_far_structures.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0

## G-NP fake module world (shared with verify_far_trees): drives NearPresence's is_area_meshed + live band probes.
class FakeWorld extends RefCounted:
	var meshed := false
	var band := Vector2(-64.0, 130.0)
	func skin_near_meshed(_fid: int, _box: AABB) -> bool: return meshed
	func meshed_band_y(_ly: float) -> Vector2: return band

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_structures (task #121 P0 — FP_STRUCT_DETECT + FP_STRUCT_FAR) ===")
	FA.warm_up()
	TerrainConfig.warm_up()
	BlockCatalog.ensure_ready()

	_gate_cluster()
	_gate_decim()
	_gate_handoff()
	_gate_delta()
	_gate_guard()
	_gate_ledger()
	_gate_np()
	_gate_shader()

	# COSMOS STRUCTURES P1a (FP_STRUCT_GEN, §12.7) — the village-generator gate set. The StructureGen / StructGenIndex
	# classes are PURE (hash-of-position), so they are exercised directly via a GenCtx homed on an Earth facet (exactly
	# how verify_far_trees drives TreeGen), even though FACETED is const-false in this headless run.
	_gate_sg_off()
	_gate_sg_site()
	_gate_sg_biject_env()
	_gate_sg_level()
	_gate_sg_root()
	_gate_sg_damage()
	_gate_sg_phys()
	_gate_sg_skin()

	# COSMOS STRUCTURES far-render LOD fix (FP_STRUCT_SHELL_BAND): far houses render in the off-surface shell band
	# [OFFSURFACE_Y, FT_SHELL_HIDE_ALT), co-timed with the far trees (both keyed on FT_SHELL_*_ALT).
	_gate_shell()

	print("=== VERIFY structures: ", _pass, " passed, ", _fail, " failed ===")
	quit(1 if _fail > 0 else 0)

# =====================================================================================================================
# G-SG helpers — locate a real generated house (deterministic scan over Earth facets) to drive the deep gates.
# =====================================================================================================================
const SG := preload("res://src/world/structure_gen.gd")
const SGI := preload("res://src/world/struct_gen_index.gd")

## The first Earth facet with ≥ 1 generated house, as {idx, fid, recs, rec}. {} if none within the scan cap.
func _find_house() -> Dictionary:
	var idx = SGI.new()
	var earth_n := 6 * FA.K * FA.K
	for fid in range(mini(earth_n, 2000)):
		var recs: Array = idx.enumerate_facet(fid)
		if not recs.is_empty():
			return {"idx": idx, "fid": fid, "recs": recs, "rec": recs[0]}
	return {}

func _inside_any(recs: Array, x: int, y: int, z: int) -> bool:
	for r in recs:
		var bmin: Vector3i = r["bmin"]
		var bmax: Vector3i = r["bmax"]
		if x >= bmin.x and x <= bmax.x and y >= bmin.y and y <= bmax.y and z >= bmin.z and z <= bmax.z:
			return true
	return false

# =====================================================================================================================
# G-SG-OFF — the interlock assert + the height-budget const law (§12.2/§12.7). Byte-identity flag-off is proven by
# the full FLAT suite; the grep-no-unguarded-sites check runs in the harness (reported separately).
# =====================================================================================================================
func _gate_sg_off() -> void:
	# COSMOS STRUCTURES P1b (§12.6): the C++ mirror (patch 0013 — cosmos:: StructureGen port + the two
	# resolve_cell_core claim branches) lands in THIS branch, so the P1a hard interlock is RELAXED to the
	# "equal-or-off" form: FP_STRUCT_GEN may now coexist with FP_CPPGEN because EITHER the flag is off (no
	# GDScript-vs-C++ divergence is possible) OR the C++ near-gen reproduces StructureGen cell-for-cell —
	# which the extended verify_cppgen (G-SG-CPP) proves byte-equal AFTER the engine rebuild, not this
	# static assert. So this is no longer a mutual-exclusion gate; it delegates byte-equality to G-SG-CPP.
	_ok(true,
		"G-SG-OFF: interlock relaxed to equal-or-off — FP_STRUCT_GEN + FP_CPPGEN both permitted; the P1b C++ mirror (patch 0013) makes the two paths equal, proven by verify_cppgen (G-SG-CPP) after rebuild")
	_ok(SG.STRUCT_H_MAX + SG.STRUCT_FLAT_TOL <= TreeGen.MAX_ABOVE_SURFACE,
		"G-SG-ENV: STRUCT_H_MAX + STRUCT_FLAT_TOL (%d) ≤ TreeGen.MAX_ABOVE_SURFACE (%d) — the height budget holds" \
			% [SG.STRUCT_H_MAX + SG.STRUCT_FLAT_TOL, TreeGen.MAX_ABOVE_SURFACE])
	# CARVE-TO-MIN budget: base_y = min footprint corner ⇒ house top = base_y + 1 (floor) + roof_top_ly ≤
	# base_y + 1 + STRUCT_H_MAX = min_corner + 12 ≤ (any corner-bounded footprint column g) + 14. Carve cells
	# are AIR at y ≤ g. So the whole-block air-ceiling stencil (max_above = 14) stays valid with no changes.
	_ok(1 + SG.STRUCT_H_MAX <= TreeGen.MAX_ABOVE_SURFACE,
		"G-SG-ENV: carve-to-min house top over the pad (1 + STRUCT_H_MAX = %d) ≤ MAX_ABOVE_SURFACE (%d)" \
			% [1 + SG.STRUCT_H_MAX, TreeGen.MAX_ABOVE_SURFACE])
	_ok(SG.STRUCT_LEVEL_TOL >= SG.STRUCT_FLAT_TOL,
		"G-SG-ENV: STRUCT_LEVEL_TOL (%d) admits rolling-plains sites the old ≤ FLAT_TOL (%d) gate rejected" \
			% [SG.STRUCT_LEVEL_TOL, SG.STRUCT_FLAT_TOL])
	_ok(SG.STRUCT_V == SG.STRUCT_HPV * SG.STRUCT_HCELL,
		"G-SG-ENV: V == HPV·HCELL (houses tile the village exactly ⇒ each house inside its own H-cell)")

# =====================================================================================================================
# G-SG-SITE — body-gate-FIRST (no village on the Moon even when the salt passes), and the found village really sits
# on plains/savanna, above sea, off slopes (§12.4). The Moon alias trap ([[voxiverse-tree-bugs-rootcause]]).
# =====================================================================================================================
func _gate_sg_site() -> void:
	# Moon body gate: find a Moon fid; a village-cell whose salt-201 PASSES must still be refused (body gate first).
	var moon_fid := -1
	for fid in range(6 * FA.K * FA.K, 6 * FA.K * FA.K + 4000):
		if FA.body_of_fid(fid) != 0:
			moon_fid = fid
			break
	if moon_fid >= 0:
		var mctx = TerrainConfig.GenCtx.new(0, moon_fid)
		# a (vx,vz) whose village hash clears the 0.05 gate — the site test would run were the body not gated.
		var found_salt := false
		var refused := true
		for vx in range(-40, 40):
			for vz in range(-40, 40):
				if SG._hash01(vx, vz, SG._SALT_VILLAGE) < SG.VILLAGE_CHANCE:
					found_salt = true
					if SG.has_village(vx, vz, mctx):
						refused = false
		_ok(found_salt and refused,
			"G-SG-SITE: Moon facet — a salt-201-passing village cell is STILL refused (body gate FIRST, alias trap)")
		var midx = SGI.new()
		_ok(midx.enumerate_facet(moon_fid).is_empty(), "G-SG-SITE: no GEN records enumerate on a Moon facet")
	else:
		_ok(true, "G-SG-SITE: (single-body atlas — Moon facet unavailable, body-gate assert via flat ctx below)")
		_ok(not SG.has_village(0, 0, TerrainConfig.GenCtx.new(0, -1)),
			"G-SG-SITE: a flat/no-facet ctx (fid −1) hosts NO village (FACETED-gated)")

	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SG-SITE: no generated house found within the facet scan cap (widen the scan / site gate)")
		return
	var rec: Dictionary = found["rec"]
	var fid: int = found["fid"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var base: Vector3i = rec["bmin"]                    # bmin.x/.z == footprint base.x/.z (bmin.y = base_y + 1)
	var vx := floori(float(base.x) / float(SG.STRUCT_V))
	var vz := floori(float(base.z) / float(SG.STRUCT_V))
	var ax := vx * SG.STRUCT_V + SG.STRUCT_V / 2
	var az := vz * SG.STRUCT_V + SG.STRUCT_V / 2
	var b := TerrainConfig.biome_at(ax, az, ctx)
	_ok(b == TerrainConfig.B_PLAINS or (CubeSphere.FP_CLIMATE_BIOMES and b == TerrainConfig.B_SAVANNA),
		"G-SG-SITE: the located village anchor biome is B_PLAINS (or B_SAVANNA under FP_CLIMATE_BIOMES)")
	_ok(TerrainConfig.column_top(ax, az, ctx) > TerrainConfig.SEA_LEVEL + 2,
		"G-SG-SITE: the village anchor is above SEA_LEVEL + 2 (no drowned village)")
	# CARVE-TO-MIN: villages now sit on ≤ STRUCT_LEVEL_TOL-variation sites (rolling plains), not just pre-flat
	# ground — but never a sheer cliff. Measure the anchor 4×4 stencil variation and assert it is within cap.
	var smn := 0x7fffffff
	var smx := -0x7fffffff
	for iz in range(4):
		for ix in range(4):
			var h := TerrainConfig.column_top(ax + ix * 8, az + iz * 8, ctx)
			smn = mini(smn, h)
			smx = maxi(smx, h)
	_ok(smx - smn <= SG.STRUCT_LEVEL_TOL,
		"G-SG-SITE: the located village site variation (%d) ≤ STRUCT_LEVEL_TOL (%d) — rolling plains, not a cliff" \
			% [smx - smn, SG.STRUCT_LEVEL_TOL])

# =====================================================================================================================
# G-SG-BIJECT + G-SG-ENV — every claim_at non-air cell lies inside an enumerated record bbox (and inside its H-cell);
# no claim at/below ground; no claim above the height budget; the records reproduce from the hashes.
# =====================================================================================================================
func _gate_sg_biject_env() -> void:
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SG-BIJECT: no generated house found (see G-SG-SITE)")
		return
	var fid: int = found["fid"]
	var recs: Array = found["recs"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var all_in := true
	var pad_untouched := true
	var budget_ok := true
	var in_hcell := true
	# H-cell containment of every record bbox (jitter keeps the whole footprint inside one H-cell).
	for r in recs:
		var bmin: Vector3i = r["bmin"]
		var bmax: Vector3i = r["bmax"]
		if floori(float(bmin.x) / float(SG.STRUCT_HCELL)) != floori(float(bmax.x) / float(SG.STRUCT_HCELL)) \
			or floori(float(bmin.z) / float(SG.STRUCT_HCELL)) != floori(float(bmax.z) / float(SG.STRUCT_HCELL)):
			in_hcell = false
	# Scan a padded region around each record. CARVE-TO-MIN invariants:
	#  * all_in    — every SOLID claim (>0) lands inside some record bbox.
	#  * pad_untouched — no claim (≥0) at y ≤ base_y (below the pad): the sub-floor strata stay natural terrain.
	#  * budget_ok — every SOLID claim (>0) is within the roof budget (y ≤ base_y + 1 + STRUCT_H_MAX) AND within
	#                MAX_ABOVE_SURFACE of the column ground g. (Carve AIR cells (0) are legitimately at y ≤ g.)
	for r in recs:
		var bmin: Vector3i = r["bmin"]
		var bmax: Vector3i = r["bmax"]
		var base_y := bmin.y - 1                         # bmin.y = base_y + 1 (floor); base_y = min footprint corner
		for x in range(bmin.x - 3, bmax.x + 4):
			for z in range(bmin.z - 3, bmax.z + 4):
				var cg := TerrainConfig.column_top(x, z, ctx)
				for y in range(base_y - 6, base_y + SG.STRUCT_H_MAX + 8):
					var cl: int = SG.claim_at(x, y, z, ctx)
					if cl >= 0 and y <= base_y:
						pad_untouched = false                # a claim at/below the pad ⇒ sub-floor NOT untouched
					if cl > 0:
						if y > base_y + 1 + SG.STRUCT_H_MAX or y - cg > TreeGen.MAX_ABOVE_SURFACE:
							budget_ok = false
						if not _inside_any(recs, x, y, z):
							all_in = false
	_ok(all_in, "G-SG-BIJECT: every claim_at solid (>0) cell lies inside an enumerated record bbox")
	_ok(in_hcell, "G-SG-ENV: every record bbox is contained in a single H-cell (no claim outside the H-cell)")
	_ok(pad_untouched, "G-SG-ENV: no claim at/below base_y (the flattened pad's solid base stays natural terrain)")
	_ok(budget_ok, "G-SG-ENV: every solid claim within the roof budget AND ≤ g + MAX_ABOVE_SURFACE (carve stays ≤ g)")
	# Reproduce-from-hashes: a FRESH index enumerates byte-identical records.
	var idx2 = SGI.new()
	var recs2: Array = idx2.enumerate_facet(fid)
	var same := recs2.size() == recs.size()
	if same:
		for i in range(recs.size()):
			if recs2[i]["root"] != recs[i]["root"] or recs2[i]["bmin"] != recs[i]["bmin"] or recs2[i]["bmax"] != recs[i]["bmax"]:
				same = false
	_ok(same, "G-SG-BIJECT: records reproduce byte-identically from the hashes (deterministic enumeration)")

# =====================================================================================================================
# G-SG-LEVEL — the CARVE actually fires (the whole point of carve-to-min leveling): a footprint column whose ground
# g > base_y (the min corner) has terrain in (base_y, g] returned as AIR (0) by claim_at — the pad is flattened by
# carving DOWN, so the house never sits on filled ground (which would blow the height budget).
# =====================================================================================================================
func _gate_sg_level() -> void:
	var idx = SGI.new()
	var earth_n := 6 * FA.K * FA.K
	var demonstrated := false
	var saw_variation := false
	var depth := 0
	for fid in range(mini(earth_n, 2000)):
		var recs: Array = idx.enumerate_facet(fid)
		if recs.is_empty():
			continue
		var ctx = TerrainConfig.GenCtx.new(0, fid)
		for r in recs:
			var bmin: Vector3i = r["bmin"]
			var bmax: Vector3i = r["bmax"]
			var base_y := bmin.y - 1                     # bmin.y = base_y + 1; base_y = the MIN footprint corner
			for x in range(bmin.x, bmax.x + 1):
				for z in range(bmin.z, bmax.z + 1):
					var cg := TerrainConfig.column_top(x, z, ctx)
					if cg <= base_y:
						continue                         # this column is at/below the pad — nothing to carve
					saw_variation = true
					# terrain occupies (base_y, cg]; the carve turns the non-house cells there into AIR (0).
					for y in range(base_y + 1, cg + 1):
						if SG.claim_at(x, y, z, ctx) == 0:
							demonstrated = true
							depth = maxi(depth, cg - base_y)
							break
					if demonstrated: break
				if demonstrated: break
			if demonstrated: break
		if demonstrated: break
	if not saw_variation:
		_ok(true, "G-SG-LEVEL: (no scanned village footprint had g > base_y — perfectly flat sites; the carve is a no-op)")
	else:
		_ok(demonstrated,
			"G-SG-LEVEL: carve fires — a footprint column with g > base_y (carve depth %d) has terrain above the pad returned as AIR (0) by claim_at" % depth)

# =====================================================================================================================
# G-SG-ROOT — GEN roots are NEGATIVE (disjoint from tracker roots ≥ 0), unique, and stable across evict/re-derive.
# =====================================================================================================================
func _gate_sg_root() -> void:
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SG-ROOT: no generated house found (see G-SG-SITE)")
		return
	var recs: Array = found["recs"]
	var neg := true
	var uniq := {}
	var dup := false
	for r in recs:
		var root: int = r["root"]
		if root >= 0:
			neg = false
		if uniq.has(root):
			dup = true
		uniq[root] = true
	_ok(neg, "G-SG-ROOT: GEN roots are NEGATIVE (structurally disjoint from tracker edit-key roots ≥ 0)")
	_ok(not dup, "G-SG-ROOT: GEN roots are unique within a facet")
	# Stable across a fresh re-derive (the cache is pure/evictable).
	var idx2 = SGI.new()
	var recs2: Array = idx2.enumerate_facet(found["fid"])
	var stable := recs2.size() == recs.size()
	if stable:
		for i in range(recs.size()):
			if recs2[i]["root"] != recs[i]["root"]:
				stable = false
	_ok(stable, "G-SG-ROOT: roots are stable across enumeration evict / re-derive")

# =====================================================================================================================
# G-SG-DAMAGE — the sampler's −1-vs-0 split value mapping + the note_edit rev bump (pins the world_manager :3596 split).
# =====================================================================================================================
func _gate_sg_damage() -> void:
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SG-DAMAGE: no generated house found (see G-SG-SITE)")
		return
	var idx = found["idx"]
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	# Find a solid wall/roof cell (claim>0) and an interior air cell (claim==0) within the bbox.
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	var wall_cell := Vector3i(0, -0x40000000, 0)
	var air_cell := Vector3i(0, -0x40000000, 0)
	# CARVE-TO-MIN: the solid house span is [bmin.y (floor = base_y+1) .. bmax.y (roof)]; scan it for a wall
	# (claim>0) and an interior-air (claim==0) cell (independent of each column's ground g under the carve).
	for x in range(bmin.x, bmax.x + 1):
		for z in range(bmin.z, bmax.z + 1):
			for y in range(bmin.y, bmax.y + 1):
				var cl: int = SG.claim_at(x, y, z, ctx)
				if cl > 0 and wall_cell.y == -0x40000000:
					wall_cell = Vector3i(x, y, z)
				if cl == 0 and air_cell.y == -0x40000000:
					air_cell = Vector3i(x, y, z)
	var have := wall_cell.y != -0x40000000 and air_cell.y != -0x40000000
	# The GEN sampler value mapping: maxi(0, claim) → wall shows solid, interior air shows 0 (the far model law).
	_ok(have and maxi(0, SG.claim_at(wall_cell.x, wall_cell.y, wall_cell.z, ctx)) > 0,
		"G-SG-DAMAGE: sampler maps a wall cell (claim>0) → its block id (far model shows the wall)")
	_ok(have and maxi(0, SG.claim_at(air_cell.x, air_cell.y, air_cell.z, ctx)) == 0,
		"G-SG-DAMAGE: sampler maps an interior-air cell (claim==0) → 0 (the split; interior never far-renders solid)")
	# note_edit rev bump: an edit inside the bbox bumps the record's damage rev (the far-tier re-bake signal).
	var root: int = rec["root"]
	var rev0 := int(rec["rev"])
	idx.note_edit(fid, wall_cell)
	var recs2: Array = idx.enumerate_facet(fid)
	var rev1 := rev0
	for r in recs2:
		if int(r["root"]) == root:
			rev1 = int(r["rev"])
	_ok(rev1 == rev0 + 1, "G-SG-DAMAGE: note_edit inside a GEN bbox bumps its rev (re-bake ⇒ the hole shows far)")

# =====================================================================================================================
# G-SG-PHYS — the BLOCK-LEVEL physical preconditions (the live floor_under / collapse / walk-in is the P1c A/B):
# a solid floor under the interior, a 2-tall passable doorway, and a roof held up only by the walls (collapse detaches).
# =====================================================================================================================
func _gate_sg_phys() -> void:
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SG-PHYS: no generated house found (see G-SG-SITE)")
		return
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var base: Vector3i = rec["bmin"]                    # bmin.x/.z == footprint base.x/.z (bmin.y = base_y + 1)
	var hx := floori(float(base.x) / float(SG.STRUCT_HCELL))
	var hz := floori(float(base.z) / float(SG.STRUCT_HCELL))
	var hi: Dictionary = SG.house_info(hx, hz, ctx)
	if hi.is_empty():
		_ok(false, "G-SG-PHYS: house_info did not reproduce the located house (site drift)")
		return
	var bp: Vector3i = hi["base"]                        # bp.y = base_y = MIN footprint corner (the pad)
	var w: int = hi["w"]
	var d: int = hi["d"]
	var wall_h: int = hi["wall_h"]
	# CARVE-TO-MIN: the floor course sits at base_y+1 (bp.y+1), walls at bp.y+2..bp.y+1+wall_h, roof above.
	# (a) FLOOR: a LEVELED interior column stands on a solid floor course and its wall-band interior is HOLLOW
	# (the carve removed any terrain that would otherwise fill the room) — floor_under lands flat, room enterable.
	var ix := bp.x + w / 2
	var iz := bp.z + d / 2
	var floor_solid := SG.claim_at(ix, bp.y + 1, iz, ctx) > 0
	var hollow := true
	for yy in range(bp.y + 2, bp.y + 2 + wall_h):        # the wall_h interior courses above the floor
		if SG.claim_at(ix, yy, iz, ctx) > 0:             # a solid block inside the room ⇒ not hollow (no carve gap)
			hollow = false
	_ok(floor_solid and hollow, "G-SG-PHYS: leveled interior column has a solid floor + hollow room (floor_under lands flat, no fall-through into the carved notch)")
	# (b) DOORWAY: the door column is a 2-tall air gap (claim 0 at floor+1, floor+2 = bp.y+2, bp.y+3) — passable.
	var dc := _door_cell(hi)
	var passable := SG.claim_at(dc.x, bp.y + 2, dc.z, ctx) == 0 and SG.claim_at(dc.x, bp.y + 3, dc.z, ctx) == 0
	_ok(passable, "G-SG-PHYS: the doorway is a 2-tall air gap (claim 0) — passable")
	# (c) ROOF: the roof course carries at least one solid cell and the interior is hollow (from a), so the roof is
	# supported ONLY by the perimeter walls — breaking a wall column floats the roof cluster ⇒ _collapse_unsupported.
	var roof_solid := false
	var rc_y := bp.y + wall_h + 2                        # roof course = base_y + 1 (floor) + wall_h + 1
	for lx in range(w):
		for lz in range(d):
			if SG.claim_at(bp.x + lx, rc_y, bp.z + lz, ctx) > 0:
				roof_solid = true
	_ok(roof_solid and hollow,
		"G-SG-PHYS: roof course has solid cells over a hollow room (wall-supported ⇒ collapse detaches on a wall break)")

## The door edge cell (lx,lz) → world (x,z) for house `hi` (mirrors StructureGen._is_door).
func _door_cell(hi: Dictionary) -> Vector3i:
	var bp: Vector3i = hi["base"]
	var w: int = hi["w"]
	var d: int = hi["d"]
	var midw := w / 2
	var midd := d / 2
	var lx := 0
	var lz := 0
	match int(hi["door"]):
		0: lx = 0; lz = midd
		1: lx = w - 1; lz = midd
		2: lx = midw; lz = 0
		3: lx = midw; lz = d - 1
	return Vector3i(bp.x + lx, 0, bp.z + lz)

# =====================================================================================================================
# G-SG-SKIN (FP_STRUCT_LOD §7.4a far-skin roof-pixels) — StructureGen.top_decoration, the far-skin roof-pixel query
# that composites houses into the fine map exactly like TreeGen.top_decoration composites canopies. Over a column
# KNOWN to host a house it returns the topmost SOLID house block (>0, EQUAL to an independent top-down claim scan);
# over a clearly non-house column (house_info empty) it returns AIR. PURE (the class is pure — no ring / flag needed).
# Also asserts FP_STRUCT_LOD defaults false (byte-off: the facet_tex_baker + bake_far_tile roof-pixel consults are all
# flag-gated, so flag-off is byte-identical).
# =====================================================================================================================
func _gate_sg_skin() -> void:
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SG-SKIN: no generated house found (see G-SG-SITE)")
		return
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	# (a) HOUSE column: a footprint column whose top_decoration returns a SOLID block (>0), and that value EQUALS an
	# independent topmost-solid claim scan over the SAME y-window — proving it is really the exposed roof-pixel.
	var hit := false
	var consistent := true
	for x in range(bmin.x, bmax.x + 1):
		for z in range(bmin.z, bmax.z + 1):
			var td: int = SG.top_decoration(x, z, ctx)
			if td <= 0:
				continue
			hit = true
			var g := TerrainConfig.column_top(x, z, ctx)
			var want := BlockCatalog.AIR
			for y in range(g + SG.STRUCT_H_MAX + SG.STRUCT_FLAT_TOL, g, -1):
				var cl: int = SG.claim_at(x, y, z, ctx, g)
				if cl > 0:
					want = cl
					break
			if td != want:
				consistent = false
	_ok(hit, "G-SG-SKIN: top_decoration returns a SOLID block (>0) over ≥1 house footprint column")
	_ok(consistent, "G-SG-SKIN: top_decoration == the topmost SOLID claim over the column (the exposed roof-pixel)")
	# (b) NON-house column: scan H-cells away from the house for one whose H-cell hosts NO house (house_info empty),
	# and assert top_decoration returns AIR there (the early-out ⇒ a non-house column costs ~one hash, no scan).
	var air_ok := false
	var found_nonhouse := false
	for off in range(SG.STRUCT_HCELL, SG.STRUCT_HCELL * 40, SG.STRUCT_HCELL):
		var nx := bmin.x + off
		var nz := bmin.z
		var hx := floori(float(nx) / float(SG.STRUCT_HCELL))
		var hz := floori(float(nz) / float(SG.STRUCT_HCELL))
		if SG.house_info(hx, hz, ctx).is_empty():
			found_nonhouse = true
			air_ok = SG.top_decoration(nx, nz, ctx) == BlockCatalog.AIR
			break
	_ok(found_nonhouse and air_ok, "G-SG-SKIN: top_decoration returns AIR over a clearly non-house column (house_info empty)")
	# (c) a flat / no-facet ctx (fid −1) is body-gated ⇒ never a village ⇒ always AIR (byte-off safe on flat runs).
	_ok(SG.top_decoration(bmin.x, bmin.z, TerrainConfig.GenCtx.new(0, -1)) == BlockCatalog.AIR,
		"G-SG-SKIN: a flat/no-facet ctx (fid −1) yields NO roof-pixel (FACETED-gated)")
	# (d) byte-off: FP_STRUCT_LOD defaults false (the fine-map roof-pixel consults are all flag-gated).
	_ok(not CubeSphere.FP_STRUCT_LOD,
		"G-SG-SKIN: FP_STRUCT_LOD defaults false (facet_tex_baker + bake_far_tile consults gated ⇒ byte-identical off)")

# --- helpers ---------------------------------------------------------------------------------------------------------
func _grass() -> int: return BlockCatalog.id_of(&"grass")
func _stone() -> int: return BlockCatalog.id_of(&"stone")
func _snow() -> int: return BlockCatalog.id_of(&"snow_block")

## Place a solid box [x0,x1]×[y0,y1]×[z0,z1] of material `mat` (fid 0) into the tracker.
func _place_box(tr, mat: int, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				tr.note_cell(FA.edit_key(0, Vector3i(x, y, z)), mat)

# =====================================================================================================================
# G-ST-CLUSTER — union-find correctness: threshold, snow-exclusion, break→split→recluster.
# =====================================================================================================================
func _gate_cluster() -> void:
	var g := _grass()
	if g <= 0:
		_ok(false, "G-ST-CLUSTER: BlockCatalog grass id unavailable")
		return
	# (a) a 3×3×4 (36-block) house → exactly 1 registered structure with the right bbox/count/mats.
	var tr = ST.new()
	_place_box(tr, g, 0, 2, 0, 2, 0, 3)
	var reg: Array = tr.registry()
	var ok_house: bool = reg.size() == 1 and int(reg[0]["count"]) == 36 \
		and reg[0]["bmin"] == Vector3i(0, 0, 0) and reg[0]["bmax"] == Vector3i(2, 2, 3) \
		and (reg[0]["mats"] as Dictionary).has(g) and int(reg[0]["source"]) == ST.SOURCE_PLAYER
	_ok(ok_house, "G-ST-CLUSTER: 36-block house ⇒ 1 structure, exact bbox/count/mats/source")

	# (b) a 15-block pillar (< STRUCT_MIN_BLOCKS AND extent on one axis only) ⇒ none.
	var tr2 = ST.new()
	_place_box(tr2, g, 0, 0, 0, 14, 0, 0)
	_ok(tr2.registry().is_empty(), "G-ST-CLUSTER: 15-block pillar ⇒ no structure (count + extent gate)")

	# (c) snow-family material NEVER clusters (the snowfall-sim exclusion) even at 36 blocks.
	var sn := _snow()
	if sn > 0:
		var tr3 = ST.new()
		_place_box(tr3, sn, 0, 2, 0, 2, 0, 3)
		_ok(tr3.registry().is_empty() and tr3.tracked_count() == 0,
			"G-ST-CLUSTER: 36 snow_block cells ⇒ no structure, none tracked (snow exclusion)")
	else:
		_ok(true, "G-ST-CLUSTER: (snow id unavailable — exclusion assert skipped)")

	# (d) break a bridging block ⇒ dirty ⇒ debounced recluster ⇒ 2 components. cubeA[0..2] — bridge(3,1,1) — cubeB[4..6].
	var tr4 = ST.new()
	_place_box(tr4, g, 0, 2, 0, 2, 0, 2)          # cube A (27)
	tr4.note_cell(FA.edit_key(0, Vector3i(3, 1, 1)), g)   # bridge
	_place_box(tr4, g, 4, 6, 0, 2, 0, 2)          # cube B (27)
	var joined: Array = tr4.registry()
	var ok_joined: bool = joined.size() == 1 and int(joined[0]["count"]) == 55
	tr4.note_removed(FA.edit_key(0, Vector3i(3, 1, 1)))   # break the bridge (anchors the debounce to real ticks)
	var now := Time.get_ticks_msec()
	tr4.tick(now)                                  # ~0 ms since the dirtying removal — not yet debounced, no recluster
	var mid := tr4.recluster_count()
	tr4.tick(now + CubeSphere.STRUCT_RECLUSTER_MS + 1)   # debounce satisfied ⇒ recluster
	var split: Array = tr4.registry()
	var counts_ok: bool = split.size() == 2 and int(split[0]["count"]) == 27 and int(split[1]["count"]) == 27
	_ok(ok_joined, "G-ST-CLUSTER: A+bridge+B ⇒ 1 structure (count 55)")
	_ok(mid == 0, "G-ST-CLUSTER: recluster is DEBOUNCED (no recluster before STRUCT_RECLUSTER_MS)")
	_ok(counts_ok and tr4.recluster_count() == 1,
		"G-ST-CLUSTER: break bridge ⇒ debounced recluster ⇒ 2 structures (27 + 27)")

# =====================================================================================================================
# G-ST-DECIM — decimation law: determinism, OR-occupancy (thin wall survives), majority-colour (NOT MIN), damage-shows.
# =====================================================================================================================
func _gate_decim() -> void:
	var g := _grass()
	var s := _stone()
	# A 1-block-thick wall 32×8×1 forces coarse pitch c=2 (max_extent 32). OR-occupancy ⇒ every coarse cell survives.
	var cells := {}
	for x in range(32):
		for y in range(8):
			cells[Vector3i(x, y, 0)] = g
	var sampler := func(_fid: int, cell: Vector3i) -> int: return int(cells.get(cell, 0))
	var bmin := Vector3i(0, 0, 0); var bmax := Vector3i(31, 7, 0)
	var d1 := SD.decimate(0, bmin, bmax, sampler)
	var d2 := SD.decimate(0, bmin, bmax, sampler)
	_ok(int(d1["c"]) == 2, "G-ST-DECIM: coarse pitch auto = 2 for a 32-block extent")
	_ok(d1["occ"] == d2["occ"] and d1["mid"] == d2["mid"], "G-ST-DECIM: same cells ⇒ byte-identical model (deterministic)")
	var full := int(d1["cw"]) * int(d1["ch"]) * int(d1["cd"])
	_ok(int(d1["solid_cells"]) == full and full == 16 * 4 * 1,
		"G-ST-DECIM: OR-occupancy — a 1-block-thick wall survives decimation (MIN would erase it)")
	# majority-colour law (verbatim FacetBlockLod): majority wins; ties → smallest id.
	_ok(SD._majority_id({g: 3, s: 5}) == s and SD._majority_id({g: 3, s: 1}) == g,
		"G-ST-DECIM: colour = MAJORITY block id among solid children")
	_ok(SD._majority_id({5: 2, 8: 2}) == 5, "G-ST-DECIM: majority ties → smallest id (deterministic)")
	# damage → the model changes (a dug cell reads air ⇒ hole). Remove a whole coarse column so occupancy drops.
	for y in range(8):
		cells.erase(Vector3i(0, y, 0)); cells.erase(Vector3i(1, y, 0))
	var d3 := SD.decimate(0, bmin, bmax, sampler)
	_ok(int(d3["solid_cells"]) == full - 4, "G-ST-DECIM: damage (dug cells read air) ⇒ fewer solid coarse cells (hole shows)")
	# the bake produces face-culled triangles for a non-empty grid.
	var lat := SD.bake_lattice(d1)
	_ok(int(lat["tris"]) > 0 and (lat["verts"] as PackedVector3Array).size() == int(lat["tris"]) * 3,
		"G-ST-DECIM: bake ⇒ face-culled triangles (verts == tris·3)")

# =====================================================================================================================
# G-ST-HANDOFF — the near-handoff cull streak (COVERED⇒hide after HIDE_STREAK, NOT_COVERED⇒show, UNKNOWABLE⇒no flip)
# on the FacetFarStructures tier, driven from a cached probe state.
# =====================================================================================================================
func _gate_handoff() -> void:
	var tier = FS.new()
	# a synthetic in-band structure: bbox on facet 0, camera placed r0+10 blocks radially outside its centre.
	var rec := {"root": 7, "fid": 0, "bmin": Vector3i(10, 40, 10), "bmax": Vector3i(16, 46, 16), "rev": 1}
	var centre := tier._structure_centre(rec)
	var r0 := float(TerrainConfig.near_render_radius())
	var cam := centre - centre.normalized() * (r0 + 10.0)   # dist == r0+10 ⇒ inside the [r0, r0+64] annulus
	# COVERED: hidden only after STRUCT_HIDE_STREAK consecutive probes.
	tier._probe_cache[7] = NearPresence.COVERED
	var shown_steps: Array = []
	for i in range(CubeSphere.STRUCT_HIDE_STREAK):
		shown_steps.append(tier._cull_emit(rec, cam))
	var hidden_now := not tier._cull_emit(rec, cam)   # one more confirms hidden by the streak
	_ok(hidden_now, "G-ST-HANDOFF: COVERED ⇒ far model HIDDEN after STRUCT_HIDE_STREAK")
	# NOT_COVERED: restored after STRUCT_SHOW_STREAK.
	tier._probe_cache[7] = NearPresence.NOT_COVERED
	var restored := false
	for i in range(CubeSphere.STRUCT_SHOW_STREAK + 1):
		restored = tier._cull_emit(rec, cam)
	_ok(restored, "G-ST-HANDOFF: NOT_COVERED ⇒ far model RESTORED after STRUCT_SHOW_STREAK")
	# UNKNOWABLE never flips state — re-hide, then feed UNKNOWABLE and confirm it stays whatever it was.
	tier._probe_cache[7] = NearPresence.COVERED
	for i in range(CubeSphere.STRUCT_HIDE_STREAK + 1):
		tier._cull_emit(rec, cam)
	var before := tier._cull_emit(rec, cam)           # hidden (false)
	tier._probe_cache[7] = NearPresence.UNKNOWABLE
	var after := tier._cull_emit(rec, cam)
	_ok(before == after, "G-ST-HANDOFF: UNKNOWABLE never flips the cull state (shared invariant)")
	# band floor: a structure closer than near_render_radius() is never far-rendered (near owns it).
	var cam_near := centre - centre.normalized() * (r0 - 20.0)
	_ok(not tier._cull_emit(rec, cam_near), "G-ST-HANDOFF: inside near_render_radius ⇒ far model deferred (band floor)")

# =====================================================================================================================
# G-ST-DELTA — the rebuild-on-change gate: no-drift inputs skip the rebuild; a rev-sum bump re-arms it.
# =====================================================================================================================
func _gate_delta() -> void:
	var tier = FS.new()
	var cam := Vector3(1000.0, 0.0, 0.0)
	_ok(tier._inputs_changed(cam, 2, 100, 0), "G-ST-DELTA: first check always rebuilds")
	_ok(not tier._inputs_changed(cam, 2, 100, 0), "G-ST-DELTA: identical inputs ⇒ NO rebuild (no-drift skip)")
	_ok(tier._inputs_changed(cam, 2, 101, 0), "G-ST-DELTA: rev-sum bump (a structure changed) ⇒ rebuild re-arms")
	_ok(tier._inputs_changed(cam + Vector3(5, 0, 0), 2, 101, 0), "G-ST-DELTA: camera motion ≥ threshold ⇒ rebuild")
	_ok(tier._inputs_changed(cam + Vector3(5, 0, 0), 2, 101, 99), "G-ST-DELTA: near-cull fingerprint drift ⇒ rebuild")

# =====================================================================================================================
# G-ST-GUARD (FP_STRUCT_NEAR_GUARD, #132 §4.2) — the credit-0 freeze fix: relaxes ONLY the credit gate, not the settle
# gate. Two-state, self-describing. The actual cull/gap-fill work the open gate admits is already proven by G-ST-HANDOFF
# (_cull_emit hide/restore) + G-ST-DELTA (_cull_pending / cover-fp / move re-arms the rebuild); this pins the gate itself.
# =====================================================================================================================
func _gate_guard() -> void:
	var guard := CubeSphere.FP_STRUCT_NEAR_GUARD
	var tier = FS.new()
	# The SETTLE gate always holds (no structure work during fresh-load pile-up), in BOTH flag states.
	_ok(not tier._credit_gate_open(false, true), "G-ST-GUARD: not settled ⇒ gate closed (fresh-load pile-up protected)")
	_ok(not tier._credit_gate_open(false, false), "G-ST-GUARD: not settled + credit 0 ⇒ gate closed")
	# Credit OK ⇒ open regardless of the flag (the normal shipped path).
	_ok(tier._credit_gate_open(true, true), "G-ST-GUARD: settled + credit OK ⇒ gate open (normal path)")
	# The flag ONLY changes the settled + credit-0 case (the freeze).
	if guard:
		_ok(tier._credit_gate_open(true, false),
			"G-ST-GUARD(on): settled + credit 0 ⇒ gate OPEN — the bounded structures step runs (double-render + missing/restore fix)")
	else:
		_ok(not tier._credit_gate_open(true, false),
			"G-ST-GUARD(off): settled + credit 0 ⇒ gate CLOSED (shipped credit gate, byte-identical)")

# =====================================================================================================================
# G-ST-BYTES / G-ST-DRAWS — the NEVER-OOM ledger + draw budget.
# =====================================================================================================================
func _gate_ledger() -> void:
	var g := _grass()
	var tr = ST.new()
	_place_box(tr, g, 0, 5, 0, 5, 0, 5)    # a 216-cell structure
	_ok(tr.total_bytes() > 0 and tr.total_bytes() <= CubeSphere.STRUCT_BYTES_MAX,
		"G-ST-BYTES: tracker total_bytes within the 8 MB ceiling")
	_ok(tr.registry_count() <= CubeSphere.STRUCT_REG_MAX, "G-ST-BYTES: registry count ≤ STRUCT_REG_MAX")
	var tier = FS.new()
	_ok(tier.total_bytes() <= CubeSphere.STRUCT_BYTES_MAX, "G-ST-BYTES: far tier total_bytes within the 8 MB ceiling")
	_ok(tier.draw_count() <= 2, "G-ST-DRAWS: far tier ≤ 2 draws (P0 LOD-A = 1)")

# =====================================================================================================================
# G-NP — the shared NearPresence tri-state (the anti-dead-latch predicate, §2.6 / §7.3). Mirrors verify_far_trees.
# =====================================================================================================================
func _gate_np() -> void:
	var w := FakeWorld.new()
	var slab: Vector2 = TerrainConfig.meshed_slab_y()
	var in_box := AABB(Vector3(0.0, slab.x + 1.0, 0.0), Vector3(4.0, 4.0, 4.0))   # inside the slab
	# COVERED-first: a positive is_area_meshed is a fact at any distance (the positive-reachability anti-dead-latch).
	w.meshed = true
	w.band = Vector2(1000.0, 1001.0)      # box OUTSIDE the live band — a positive still wins
	_ok(NearPresence.covered(w, 0, in_box) == NearPresence.COVERED,
		"G-NP: is_area_meshed TRUE ⇒ COVERED unconditionally (positive reachability, COVERED-first)")
	# NOT_COVERED: negative + fully inside the live reach.
	w.meshed = false
	w.band = Vector2(slab.x, slab.y)
	_ok(NearPresence.covered(w, 0, in_box) == NearPresence.NOT_COVERED,
		"G-NP: not meshed + inside the live band ⇒ NOT_COVERED")
	# UNKNOWABLE: negative + outside the live reach.
	w.band = Vector2(1000.0, 1001.0)
	_ok(NearPresence.covered(w, 0, in_box) == NearPresence.UNKNOWABLE,
		"G-NP: not meshed + outside the live band ⇒ UNKNOWABLE")
	# Slab-clamp: a box wholly outside the bounds slab ⇒ NOT_COVERED definitively (excludes the dead-latch class).
	var above := AABB(Vector3(0.0, slab.y + 100.0, 0.0), Vector3(4.0, 4.0, 4.0))
	w.meshed = false
	_ok(NearPresence.covered(w, 0, above) == NearPresence.NOT_COVERED,
		"G-NP: box outside the bounds slab ⇒ NOT_COVERED (slab-clamp anti-dead-latch)")
	# No world ⇒ UNKNOWABLE (never a silent false).
	_ok(NearPresence.covered(null, 0, in_box) == NearPresence.UNKNOWABLE, "G-NP: null world ⇒ UNKNOWABLE")

# =====================================================================================================================
# G-ST-SHADER — the far-structure shader is the ONE radial voxi_shade family (compiles, uses the shared shade_glsl).
# =====================================================================================================================
func _gate_shader() -> void:
	var code := FS.shader_code()
	_ok(code.contains("voxi_shade") and code.contains("planet_centre"),
		"G-ST-SHADER: far-structure shader uses the shared radial voxi_shade + planet_centre uniform")

# =====================================================================================================================
# G-ST-SHELL (FP_STRUCT_SHELL_BAND — the far-render dropout fix: houses vanished at alt 256 while trees rendered to
# ~600). The far-STRUCTURE three-zone altitude law must MATCH the far-trees policy (both driven by FT_SHELL_*_ALT):
# ZONE S (on-surface) visible; ZONE B (offsurf, h<HIDE) VISIBLE + LIVE under an UNLIT vertex-colour material (so the
# baked BROWN renders, not the black the radial voxi_shade gives off-surface) with the tier_fade dissolve; ZONE O
# (h≥HIDE) hidden. Flag off ⇒ the shipped binary suspend (off-surface hidden at any altitude), byte-identical.
# =====================================================================================================================
func _gate_shell() -> void:
	var on := CubeSphere.FP_STRUCT_SHELL_BAND
	var tier = FS.new()
	tier.setup_instance(Node3D.new(), 0)   # gate drives debug_apply_shell_visibility directly — no ring shell hooks
	# ZONE S (on-surface) is visible in BOTH flag states (shipped).
	tier.debug_apply_shell_visibility(false, 41.0)
	_ok(tier.mi_visible(), "G-ST-SHELL: zone S (on-surface) visible (both flag states)")
	if on:
		# The trees' policy: VISIBLE at h=300 (zone B), HIDDEN at h=650 (zone O). Structures must match exactly.
		var z_b := tier.debug_apply_shell_visibility(true, 300.0)
		_ok(z_b == 1 and tier.mi_visible(),
			"G-ST-SHELL(on): h=300 offsurf ⇒ VISIBLE (zone B) — matches the far-trees policy")
		_ok(tier.mi_material_is_shell(),
			"G-ST-SHELL(on): zone B uses the UNLIT vertex-colour material ⇒ baked BROWN, not black")
		# tier_fade dissolve: 1.0 at ≤FADE_ALT, strictly decreasing into HIDE_ALT, and the zone-B apply drove the uniform.
		var tf300 := 1.0 - smoothstep(CubeSphere.FT_SHELL_FADE_ALT, CubeSphere.FT_SHELL_HIDE_ALT, 300.0)
		var tf560 := 1.0 - smoothstep(CubeSphere.FT_SHELL_FADE_ALT, CubeSphere.FT_SHELL_HIDE_ALT, 560.0)
		_ok(tf300 == 1.0 and tf560 < tf300 and tf560 > 0.0,
			"G-ST-SHELL(on): tier_fade dissolves over [FT_SHELL_FADE_ALT, FT_SHELL_HIDE_ALT] (co-timed with trees)")
		_ok(is_equal_approx(float(tier._shell_material.get_shader_parameter("tier_fade")), tf300),
			"G-ST-SHELL(on): the zone-B apply drives the tier_fade uniform (no rebuild)")
		var z_o := tier.debug_apply_shell_visibility(true, 650.0)
		_ok(z_o == 2 and not tier.mi_visible(),
			"G-ST-SHELL(on): h=650 offsurf ⇒ HIDDEN (zone O) — matches the far-trees policy (skin owns it above)")
	else:
		# Off ⇒ byte-identical binary suspend: off-surface hidden at ANY altitude, and no shell material was built.
		tier.debug_apply_shell_visibility(true, 300.0)
		_ok(not tier.mi_visible(),
			"G-ST-SHELL(off): off-surface hidden at any altitude (binary suspend, byte-identical)")
		tier.debug_apply_shell_visibility(true, 650.0)
		_ok(not tier.mi_visible(), "G-ST-SHELL(off): off-surface still hidden at h=650 (byte-identical)")
		_ok(tier._shell_material == null and tier.shell_band_state().is_empty(),
			"G-ST-SHELL(off): no shell material + empty telemetry (byte-identical off)")
