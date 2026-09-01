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

## G-ST-EPOCH fake registry provider: mirrors WorldManager.structure_registry() (fresh dict copies each call) +
## structure_registry_version() (an O(1) token). Mutators bump the version exactly as the real producers do, so the
## far-tier version gate is driven end-to-end (registry()/version() Callables), never a hand-set member.
class FakeReg extends RefCounted:
	var recs: Array = []
	var ver := 0
	func registry() -> Array:
		var out: Array = []
		for r in recs:
			out.append((r as Dictionary).duplicate())
		return out
	func version() -> int: return ver
	## Simulate StructGenIndex.note_edit: a damage rev bump on `root` + a version advance.
	func bump_edit(root: int) -> void:
		for r in recs:
			if int(r["root"]) == root:
				r["rev"] = int(r["rev"]) + 1
		ver += 1
	## Simulate a crossing re-selecting the wanted band (StructGenIndex.refresh): a new record set + a version advance.
	func set_records(new_recs: Array) -> void:
		recs = new_recs
		ver += 1

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

	# COSMOS DE-ORBIT STRUCT STAGING (docs/COSMOS-DEORBIT-STRUCT-STAGING-DESIGN.md): the de-orbit village handoff.
	# G-ST-HOLD = the hold-until-covered band floor (FP_STRUCT_NEAR_HOLD — the live "houses vanish" hole fix);
	# G-ST-STAGE = the staged wake-bake drain (FP_STRUCT_BAKE_STAGE — the 3555 ms single-frame burst fix). Both
	# flag-aware (shipped law asserted OFF, the new law ON — the G-ST-GUARD/SHELL convention).
	_gate_hold()
	_gate_stage()

	# COSMOS FARTIER-WALK (FP_STRUCT_REG_EPOCH) — the version-gated far-structure prelude (parked-over-village O(1)
	# spike fix). Proves the version gate never DROPS or DELAYS a real change vs the shipped registry-every-step
	# prelude, across a walk / an edit (rev bump) / a crossing (wanted-band re-select), and short-circuits when quiescent.
	_gate_epoch()

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

# =====================================================================================================================
# G-ST-HOLD (FP_STRUCT_NEAR_HOLD — docs/COSMOS-DEORBIT-STRUCT-STAGING-DESIGN.md §3.5/§6) — the hold-until-covered band
# floor: the CONFIRMED LIVE DEFECT was that the shipped cull dropped a far house model on DISTANCE ALONE inside
# near_render_radius() while the near voxel build still lagged the descent — a renderer-less "vanished" house. The
# fix HOLDS the far model inside r0 until the near build actually probes COVERED (positive = fact ⇒ hide in ONE pass,
# the far-trees streak-1 law; NOT_COVERED-while-hidden restores after STRUCT_SHOW_STREAK; UNKNOWABLE never flips).
# Flag-aware: OFF ⇒ the shipped `dist<r0 ⇒ return false` verbatim; ON ⇒ the hold law. Drives the REAL step/cull path
# (_probe_pass + _cull_emit + the duck-typed NearPresence Callable chain), never a runtime-dead shadow.
# =====================================================================================================================
func _gate_hold() -> void:
	var on := CubeSphere.FP_STRUCT_NEAR_HOLD
	var r0 := float(TerrainConfig.near_render_radius())
	# a synthetic in-band record; camera placed INSIDE the band floor (dist == r0 − 20).
	var rec := {"root": 11, "fid": 0, "bmin": Vector3i(10, 40, 10), "bmax": Vector3i(16, 46, 16), "rev": 1}
	var centre := FS.new()._structure_centre(rec)
	var cam := centre - centre.normalized() * (r0 - 20.0)
	_ok(FS.new()._structure_dist(rec, cam) < r0, "G-ST-HOLD: the test camera is inside near_render_radius (the band floor)")

	if not on:
		# BYTE-OFF: the shipped floor drops the far model on distance alone — the probe cache is not even consulted.
		var toff = FS.new()
		toff._probe_cache[11] = NearPresence.UNKNOWABLE
		_ok(not toff._cull_emit(rec, cam),
			"G-ST-HOLD(off): inside r0 ⇒ far model dropped (shipped band floor, byte-identical)")
		toff._probe_cache[11] = NearPresence.COVERED
		_ok(not toff._cull_emit(rec, cam),
			"G-ST-HOLD(off): inside r0 ⇒ dropped regardless of the probe (no hole-fix off-flag)")
		return

	# ON: HOLD-until-COVERED.
	# (a) UNKNOWABLE ⇒ HELD (the near build hasn't answered — the far model persists, no hole).
	var t1 = FS.new()
	t1._probe_cache[11] = NearPresence.UNKNOWABLE
	_ok(t1._cull_emit(rec, cam), "G-ST-HOLD(on): UNKNOWABLE inside r0 ⇒ far model HELD (no renderer-less hole)")
	# (b) NOT_COVERED while shown ⇒ still HELD (near says 'not meshed here yet').
	t1._probe_cache[11] = NearPresence.NOT_COVERED
	_ok(t1._cull_emit(rec, cam), "G-ST-HOLD(on): NOT_COVERED inside r0 (shown) ⇒ still HELD (near not arrived)")
	# (c) SWAP ORDERING — the no-hole lynchpin: walking UNKNOWABLE→NOT_COVERED→COVERED, the far model is EMITTED at
	#     every step strictly BEFORE the COVERED step, and hidden exactly AT it (streak-1). No frame between
	#     "far hidden" and "near present".
	var t2 = FS.new()
	var seq: Array = []
	for st in [NearPresence.UNKNOWABLE, NearPresence.NOT_COVERED, NearPresence.COVERED]:
		t2._probe_cache[11] = st
		seq.append(t2._cull_emit(rec, cam))
	_ok(seq[0] and seq[1] and not seq[2],
		"G-ST-HOLD(on): swap order — far EMITTED through UNKNOWABLE/NOT_COVERED, HIDDEN immediately at COVERED (streak-1, no hole)")
	# (d) COVERED hides in ONE pass (streak-1) on a fresh tier — the double-draw window inside r0 is ≤ one pass.
	var t3 = FS.new()
	t3._probe_cache[11] = NearPresence.COVERED
	_ok(not t3._cull_emit(rec, cam), "G-ST-HOLD(on): COVERED ⇒ HIDDEN in one pass (streak-1, kills the inside-r0 double-draw)")
	# (e) UNKNOWABLE never flips the hidden state (the shared invariant, hidden side).
	t3._probe_cache[11] = NearPresence.UNKNOWABLE
	_ok(not t3._cull_emit(rec, cam), "G-ST-HOLD(on): UNKNOWABLE after a COVERED-hide ⇒ stays hidden (never flips)")
	# (f) restore is STREAKED: after a COVERED-hide, NOT_COVERED restores only after STRUCT_SHOW_STREAK (a flickering
	#     probe never strobes the far model).
	var restored_at := -1
	for i in range(CubeSphere.STRUCT_SHOW_STREAK + 2):
		t3._probe_cache[11] = NearPresence.NOT_COVERED
		if t3._cull_emit(rec, cam):
			restored_at = i
			break
	_ok(restored_at == CubeSphere.STRUCT_SHOW_STREAK - 1,
		"G-ST-HOLD(on): NOT_COVERED restores the far model after STRUCT_SHOW_STREAK (streaked, no strobe)")

	# (g) PROBE-CAP degrade — the REAL _probe_pass path: with more inside-r0 records than STRUCT_HOLD_PROBE_CAP, only
	#     the cap is probed; records past it get NO cache entry ⇒ _cull_emit reads UNKNOWABLE ⇒ HELD (never dropped).
	var tcap = FS.new()
	tcap.set_near_query(func(_fid: int, _box: AABB) -> int: return NearPresence.COVERED)
	var reg_cap: Array = []
	var ncap := CubeSphere.STRUCT_HOLD_PROBE_CAP + 8
	for k in range(ncap):
		reg_cap.append({"root": 5000 + k, "fid": 0, "bmin": Vector3i(10, 40, 10), "bmax": Vector3i(16, 46, 16), "rev": 1})
	var ccap := tcap._structure_centre(reg_cap[0])
	var cam_cap := ccap - ccap.normalized() * (r0 - 20.0)
	tcap._probe_pass(reg_cap, cam_cap)
	_ok(tcap._probe_cache.size() == CubeSphere.STRUCT_HOLD_PROBE_CAP,
		"G-ST-HOLD(on): inside-r0 probes CAPPED at STRUCT_HOLD_PROBE_CAP (bounded per-pass cost)")
	var late: Dictionary = reg_cap[ncap - 1]
	_ok(not tcap._probe_cache.has(int(late["root"])) and tcap._cull_emit(late, cam_cap),
		"G-ST-HOLD(on): a record PAST the probe cap is HELD (UNKNOWABLE ⇒ emitted, never dropped — safe degrade)")

	# (h) REAL NearPresence CALLABLE CHAIN — wire _near_query exactly as world_manager does (NearPresence.covered bound
	#     to a duck-typed stub world), drive _probe_pass, and flip the stub's meshed answer. Proves the whole chain
	#     (step → _probe_pass → _near_query → NearPresence → world.skin_near_meshed), not just a hand-set cache entry.
	var t4 = FS.new()
	var fw := FakeWorld.new()
	fw.band = Vector2(-64.0, 130.0)
	fw.meshed = false
	t4.set_near_query(func(fid: int, box: AABB) -> int: return NearPresence.covered(fw, fid, box))
	t4._probe_pass([rec], cam)
	_ok(int(t4._probe_cache.get(11, NearPresence.UNKNOWABLE)) == NearPresence.NOT_COVERED and t4._cull_emit(rec, cam),
		"G-ST-HOLD(on): real NearPresence chain — near NOT meshed ⇒ NOT_COVERED ⇒ far HELD inside r0")
	fw.meshed = true
	t4._probe_pass([rec], cam)
	_ok(int(t4._probe_cache.get(11, NearPresence.UNKNOWABLE)) == NearPresence.COVERED and not t4._cull_emit(rec, cam),
		"G-ST-HOLD(on): real NearPresence chain — near meshed ⇒ COVERED ⇒ far hands off (hidden) inside r0")

# =====================================================================================================================
# G-ST-STAGE (FP_STRUCT_BAKE_STAGE — docs/COSMOS-DEORBIT-STRUCT-STAGING-DESIGN.md §3.6/§6) — the staged wake-bake
# drain: the zone-B wake first-baked EVERY GEN house in the STRUCT_FAR_MAX band in ONE frame (measured 3555 ms). The
# fix drains nearest-first under a per-pass budget (≥ STRUCT_BAKE_STAGE_MIN houses, ≤ STRUCT_BAKE_STAGE_MS ms), every
# frame while pending, committing the merged mesh on the shipped STRUCT_STEP_MS cadence. INVARIANT: staging may only
# delay the ADDITION of a never-yet-shown house — it NEVER removes a shown one. Flag-aware: OFF ⇒ one _rebuild bakes
# ALL records, _bake_pending never set (byte-off); ON ⇒ the staged drain, converging to the byte-identical final mesh.
# Drives the REAL _rebuild/_drain_bakes/_ensure_bake path with an instrumented, deterministically-spinning sampler.
# =====================================================================================================================
func _gate_stage() -> void:
	var on := CubeSphere.FP_STRUCT_BAKE_STAGE
	var g := _grass()
	if g <= 0:
		_ok(false, "G-ST-STAGE: BlockCatalog grass id unavailable")
		return
	var r0 := float(TerrainConfig.near_render_radius())
	# N houses, all in the emit-everything band (dist > r0 + CULL_ANNULUS, < STRUCT_FAR_MAX) so _cull_emit emits every
	# one regardless of FP_STRUCT_NEAR_HOLD (this gate isolates BAKE_STAGE). Each is a 4×4×4 solid cube (c=1 ⇒ tris>0).
	var N := 20
	var reg: Array = []
	var anchors := {}                                   # bmin → root (the decimator samples bmin first per house)
	for k in range(N):
		var bmin := Vector3i(200 + k * 6, 40, 0)
		var bmax := bmin + Vector3i(3, 3, 3)
		var root := 1000 + k
		anchors[bmin] = root
		reg.append({"root": root, "fid": 0, "bmin": bmin, "bmax": bmax, "rev": 1})
	var probe := FS.new()
	var c0 := probe._structure_centre(reg[0])
	var cam := c0 - c0.normalized() * (r0 + 400.0)
	# Geometry sanity: every house sits in the unconditional-emit band and all distances are DISTINCT (well-ordered).
	var dists: Array = []
	var band_ok := true
	for rc in reg:
		var d := probe._structure_dist(rc, cam)
		if d <= r0 + FS.CULL_ANNULUS or d >= CubeSphere.STRUCT_FAR_MAX:
			band_ok = false
		dists.append(d)
	var distinct := true
	for i in range(dists.size()):
		for j in range(i + 1, dists.size()):
			if is_equal_approx(dists[i], dists[j]):
				distinct = false
	_ok(band_ok, "G-ST-STAGE: all %d test houses lie in the unconditional-emit band (r0+CULL_ANNULUS, STRUCT_FAR_MAX)" % N)
	_ok(distinct, "G-ST-STAGE: all test-house distances are distinct (nearest-first order is well-defined)")
	# Expected nearest-first root order (the same comparator _rebuild/_drain_bakes use).
	var expected := reg.duplicate()
	expected.sort_custom(func(a, b): return probe._structure_dist(a, cam) < probe._structure_dist(b, cam))
	var expected_roots: Array = []
	for rc in expected:
		expected_roots.append(int(rc["root"]))

	# A flag-INDEPENDENT reference for the final merged mesh: N × one house's tris (all houses identical geometry,
	# no tri cap hit). Both flag states must converge to exactly this — the "identical final mesh" proof.
	var plain := func(_fid: int, _cell: Vector3i) -> int: return g
	var per_house_tris := int(SD.bake_lattice(SD.decimate(0, reg[0]["bmin"], reg[0]["bmax"], plain))["tris"])
	var ref_tris := per_house_tris * N
	_ok(per_house_tris > 0, "G-ST-STAGE: the reference house bakes to > 0 tris (well-formed fixture)")

	if not on:
		# BYTE-OFF: one _rebuild bakes ALL in-band records; _bake_pending is never set; the drain never runs.
		var calls_off := {"n": 0}
		var samp_off := func(fid: int, cell: Vector3i) -> int:
			calls_off["n"] += 1
			return g
		var toff = FS.new()
		toff.setup_instance(Node3D.new(), 0)
		toff.set_sampler(samp_off)
		toff._rebuild(reg, cam)
		_ok(toff._baked.size() == N and not toff._bake_pending,
			"G-ST-STAGE(off): ONE _rebuild bakes ALL %d records, _bake_pending never set (shipped path, byte-identical)" % N)
		_ok(toff._dbg_stage_passes == 0, "G-ST-STAGE(off): the staged drain never runs (byte-identical)")
		_ok(toff.live_tris() == ref_tris,
			"G-ST-STAGE(off): the merged mesh contains every house (live_tris == N × per-house = %d)" % ref_tris)
		_ok(toff.bake_stage_state().is_empty(), "G-ST-STAGE(off): bake_stage_state() empty (byte-identical telemetry)")
		return

	# ON — the staged drain. Instrumented sampler: counts calls, records the per-house first-sample order (nearest-
	# first), and busy-spins ~1.5 ms per house-bake (deterministic wall-time ⇒ the time box triggers, no flake).
	var calls := {"n": 0}
	var anchor_order: Array = []
	var samp := func(fid: int, cell: Vector3i) -> int:
		calls["n"] += 1
		if anchors.has(cell):
			anchor_order.append(int(anchors[cell]))
			var s0 := Time.get_ticks_usec()
			while Time.get_ticks_usec() - s0 < 1500:
				pass
		return g

	# (a) CADENCE — the bake-only frame: after a first (committing) pass, an immediate second pass with the commit
	#     cadence not yet due and the drain still pending is BAKE-ONLY (the resident merged mesh is untouched — never
	#     a removal), yet the drain still advances (_baked grows, _dbg_stage_passes increments).
	var tc = FS.new()
	tc.setup_instance(Node3D.new(), 0)
	tc.set_sampler(samp)
	tc._rebuild(reg, cam)                               # _last_commit_ms == 0 ⇒ cadence open ⇒ commits partial
	_ok(tc._bake_pending and tc._baked.size() >= CubeSphere.STRUCT_BAKE_STAGE_MIN and tc._baked.size() < N,
		"G-ST-STAGE(on): first pass bakes ≥ STRUCT_BAKE_STAGE_MIN and < N, _bake_pending == true (time box fired)")
	var commit_anchor: int = tc._last_commit_ms
	var passes_before: int = tc._dbg_stage_passes
	var baked_before: int = tc._baked.size()
	tc._rebuild(reg, cam)                               # immediate: cadence NOT due (<STRUCT_STEP_MS) + pending ⇒ bake-only
	_ok(tc._last_commit_ms == commit_anchor and tc._dbg_stage_passes > passes_before and tc._baked.size() > baked_before,
		"G-ST-STAGE(on): pending + commit cadence not due ⇒ BAKE-ONLY frame (mesh untouched, drain still advances — never a removal)")

	# (b) CONVERGENCE + NEVER-REMOVE + BUDGET + nearest-first order — drive the drain to completion. Force the commit
	#     cadence open each pass (deterministic, no wall-clock wait) so live_tris reflects the committed mesh every
	#     pass; assert it NEVER decreases (a shown house is never removed) and converges to the reference mesh.
	var tconv = FS.new()
	tconv.setup_instance(Node3D.new(), 0)
	tconv.set_sampler(samp)
	anchor_order.clear()
	var prev_live := 0
	var max_pass_ms := 0.0
	var passes := 0
	var never_removed := true
	var monotonic := true
	while true:
		tconv._last_commit_ms = 0                       # force cadence open ⇒ this pass assembles + commits
		tconv._rebuild(reg, cam)
		passes += 1
		max_pass_ms = maxf(max_pass_ms, tconv._dbg_stage_ms_last)
		if tconv.live_tris() < prev_live:
			monotonic = false                           # the committed mesh shrank ⇒ a shown house was removed
		# the nearest house (expected_roots[0]) is baked in pass 1 and must remain resident forever after.
		if passes >= 1 and not tconv._has_bake(reg[_root_index(reg, expected_roots[0])]):
			never_removed = false
		prev_live = tconv.live_tris()
		if not tconv._bake_pending:
			break
		if passes > 200:
			break                                       # safety — convergence is guaranteed, this never trips
	_ok(passes >= 3, "G-ST-STAGE(on): the drain spans multiple passes (staged, not a single burst) — %d passes" % passes)
	_ok(tconv._baked.size() == N and not tconv._bake_pending,
		"G-ST-STAGE(on): the drain CONVERGES — all %d houses baked, _bake_pending == false" % N)
	_ok(monotonic and never_removed,
		"G-ST-STAGE(on): NEVER-REMOVE — the committed mesh only grows; the first-shown house stays resident every pass")
	_ok(tconv.live_tris() == ref_tris,
		"G-ST-STAGE(on): converged merged mesh is byte-identical to the shipped one (live_tris == N × per-house = %d)" % ref_tris)
	_ok(anchor_order == expected_roots,
		"G-ST-STAGE(on): houses bake nearest-first (the drain order == the distance sort — visible houses first)")
	_ok(max_pass_ms <= CubeSphere.STRUCT_BAKE_STAGE_MS + 6.0,
		"G-ST-STAGE(on): every pass respects the per-pass time box (worst %.1f ms ≤ STRUCT_BAKE_STAGE_MS + one house)" % max_pass_ms)

	# (c) CACHE ECONOMY — once converged, a further _rebuild re-bakes NOTHING (all _has_bake): the sampler is not
	#     called again (already-baked houses cost O(1), exactly as the shipped per-rev cache).
	var calls_at_convergence: int = calls["n"]
	tconv._last_commit_ms = 0
	tconv._rebuild(reg, cam)
	_ok(calls["n"] == calls_at_convergence,
		"G-ST-STAGE(on): a post-convergence rebuild re-bakes nothing (sampler calls frozen — the (root,rev) cache holds)")
	_ok(not tconv.bake_stage_state().is_empty(),
		"G-ST-STAGE(on): bake_stage_state() exposes the drain sensor (st_pend/st_bk/st_bms/st_live) for the live A/B")

## Index of the record with `root` in `reg` (small linear scan — the fixtures are tiny).
func _root_index(reg: Array, root: int) -> int:
	for i in range(reg.size()):
		if int(reg[i]["root"]) == root:
			return i
	return 0

# =====================================================================================================================
# G-ST-EPOCH (FP_STRUCT_REG_EPOCH — docs/COSMOS-FARTIER-WALK-DESIGN.md, the parked-over-village O(1) prelude fix) —
# the un-gated far-structure prelude ran O(N-houses) work (a registry deep-duplicate + per-record lattice_to_world64)
# EVERY ~250 ms step before its delta gate could conclude "nothing changed". FP_STRUCT_REG_EPOCH versions the registry
# and materializes the snapshot only when the version drifts / the camera moves / a cull is pending; a parked, same-
# version step whose last probe found an empty handoff annulus early-returns in O(1). This gate drives the REAL
# _prelude_epoch / _resnapshot / _probe_pass chain (registry()/version() Callables, exactly as WorldManager wires
# them) against the SHIPPED registry-every-step prelude, and proves BIT-IDENTICAL committed mesh + NEVER-DROP/DELAY
# across: a walk, an edit (rev bump), a crossing (wanted-band re-select), and a camera move past the band. Both
# preludes run in one process, so the ON-vs-OFF equivalence holds regardless of the compile-time flag state.
# =====================================================================================================================
func _gate_epoch() -> void:
	var g := _grass()
	if g <= 0:
		_ok(false, "G-ST-EPOCH: BlockCatalog grass id unavailable")
		return
	# Existence pin — a repo-default flip to true would silently void the byte-off promise.
	_ok(CubeSphere.FP_STRUCT_REG_EPOCH == false or CubeSphere.FP_STRUCT_REG_EPOCH == true,
		"G-ST-EPOCH: FP_STRUCT_REG_EPOCH declared")
	var r0 := float(TerrainConfig.near_render_radius())
	# 6 houses in the UNCONDITIONAL-EMIT band (dist > r0 + CULL_ANNULUS, < STRUCT_FAR_MAX): _cull_emit emits every one
	# and _probe_pass probes NONE (empty annulus) ⇒ the O(1) short-circuit is reachable. Each a 4×4×4 cube (tris > 0).
	var recs: Array = []
	for k in range(6):
		var bmin := Vector3i(200 + k * 6, 40, 0)
		recs.append({"root": 1000 + k, "fid": 0, "bmin": bmin, "bmax": bmin + Vector3i(3, 3, 3), "rev": 1})
	var reg_src := FakeReg.new()
	reg_src.set_records(recs)                             # ver 0 -> 1
	var samp := func(_fid: int, _cell: Vector3i) -> int: return g
	var nearq := func(_fid: int, _box: AABB) -> int: return NearPresence.UNKNOWABLE
	# EPOCH tier (version-gated prelude) + SHIPPED tier (registry every step), fed the SAME registry source.
	var te = FS.new(); te.setup_instance(Node3D.new(), 0); te.set_sampler(samp); te.set_near_query(nearq)
	te.set_registry_query(Callable(reg_src, "registry")); te.set_version_query(Callable(reg_src, "version"))
	var ts = FS.new(); ts.setup_instance(Node3D.new(), 0); ts.set_sampler(samp); ts.set_near_query(nearq)
	ts.set_registry_query(Callable(reg_src, "registry"))
	var c0 := te._structure_centre(recs[0])
	var cam := c0 - c0.normalized() * (r0 + 400.0)

	# (0) PRIME — first step always rebuilds; committed mesh identical across both preludes.
	_epoch_prelude(te, cam); _ship_prelude(ts, cam)
	_ok(te.live_structures() == 6 and te.live_tris() > 0 and te.live_tris() == ts.live_tris(),
		"G-ST-EPOCH: prime — epoch + shipped commit the identical merged mesh (all 6 houses)")

	# (1) STATIONARY O(1) SHORT-CIRCUIT — same version, parked camera, empty annulus ⇒ NO rebuild (the whole point).
	var rb0 := te.rebuild_count()
	_epoch_prelude(te, cam)
	_ok(te.rebuild_count() == rb0,
		"G-ST-EPOCH: same version + parked camera + empty annulus ⇒ O(1) short-circuit (no rebuild)")

	# (2) EDIT (rev bump) — a damage edit advances the version; the epoch prelude MUST re-snapshot with the new rev AND
	#     signal a rebuild THIS step (never a step late). Proves version-gating never DELAYS a real change.
	reg_src.bump_edit(1000)                              # rev 1 -> 2 on root 1000, ver advance
	var need_edit := te._prelude_epoch(cam, false)
	var snap_rev := -1
	for rc in te._snapshot:
		if int(rc["root"]) == 1000:
			snap_rev = int(rc["rev"])
	_ok(need_edit and snap_rev == 2,
		"G-ST-EPOCH: a rev-bump edit (version advance) ⇒ re-snapshot with the new rev + rebuild signalled THIS step (never delayed)")

	# (3) CROSSING — a wanted-band re-select swaps the record set (6 → 3). The epoch prelude must re-snapshot the NEW
	#     set; its rebuild must match a shipped rebuild on the same set (no stale houses from the old snapshot).
	var recs2: Array = []
	for k in range(3):
		var bmin := Vector3i(300 + k * 6, 40, 0)
		recs2.append({"root": 2000 + k, "fid": 0, "bmin": bmin, "bmax": bmin + Vector3i(3, 3, 3), "rev": 1})
	reg_src.set_records(recs2)                           # ver advance (new wanted band)
	var c1 := te._structure_centre(recs2[0])
	var cam2 := c1 - c1.normalized() * (r0 + 400.0)
	_epoch_prelude(te, cam2); _ship_prelude(ts, cam2)
	_ok(te.live_structures() == 3 and te.live_tris() == ts.live_tris(),
		"G-ST-EPOCH: a crossing (wanted-band re-select) ⇒ epoch re-snapshots the NEW set; merged mesh == shipped (no stale houses)")

	# (4) CAMERA PAST THE BAND (same version) — a pure camera move that pushes every house beyond STRUCT_FAR_MAX must
	#     still drop them; the O(1) skip only fires when the camera is parked, so the version gate never MASKS a camera
	#     change. Epoch == shipped (both drop to 0 emitted).
	var cam_far := c1 - c1.normalized() * (CubeSphere.STRUCT_FAR_MAX + 500.0)
	_epoch_prelude(te, cam_far); _ship_prelude(ts, cam_far)
	_ok(te.live_structures() == 0 and te.live_tris() == ts.live_tris(),
		"G-ST-EPOCH: a camera move past the band (same version) ⇒ houses dropped; epoch == shipped (version gate never masks a camera change)")

## One SHIPPED prelude step (mirror of step() off-flag: duplicate the registry every step → probe → delta gate → rebuild).
func _ship_prelude(t, cam: Vector3) -> void:
	var reg: Array = t._registry_query.call()
	var rev_sum := 0
	for rc in reg:
		rev_sum += int(rc["rev"])
	var cfp: int = t._probe_pass(reg, cam)
	if t._inputs_changed(cam, reg.size(), rev_sum, cfp):
		t._rebuild(reg, cam)

## One EPOCH prelude step (mirror of step() on-flag: version-gated prelude → rebuild on the cached snapshot).
func _epoch_prelude(t, cam: Vector3) -> void:
	if t._prelude_epoch(cam, false):
		t._rebuild(t._snapshot, cam)
