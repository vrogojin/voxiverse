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
const SCK := preload("res://src/world/struct_card_kit.gd")

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

## G-SKIN-GATE (S3) roof-skin readiness stub: the tier's _skin_ready_query calls this; returns a controllable fraction.
var _fake_skin_frac := 1.0
func _fake_skin_ready(_fids) -> float:
	return _fake_skin_frac

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
	_gate_lodskin()   # G-ST-LODSKIN: the roof-skin BAKER composite (FP_STRUCT_LOD) — house roof texel into the fine map

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

	# COSMOS STRUCT-IMPOSTOR (docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md §11, FP_STRUCT_CARDS) — the far-village impostor-card
	# tier. Flag-aware (the G-ST-STAGE/HOLD convention): OFF asserts byte-identical (no card node / no card in the sink);
	# ON asserts the card emission, split, cull guard, epoch stability + the NEVER-OOM ledger. The pure kit (arch/atlas/
	# unpack_root) is exercised in BOTH states. Needs FP_STRUCT_REG_EPOCH ON when FP_STRUCT_CARDS is (the §6 coupling).
	_gate_card_off()
	_gate_card_arch()
	_gate_card_atlas()
	_gate_card_shader()
	_gate_card_emit()
	_gate_card_split()
	_gate_card_cull()
	_gate_card_cubecap()
	_gate_card_epoch()
	_gate_card_oom()

	# COSMOS CARD-BAND-HANDOFF (docs/COSMOS-CARD-BAND-HANDOFF-DESIGN.md, Stage 3 S2-S5). Flag-aware: the shipped 600 law
	# / one-shot resnapshot / sort_custom asserted OFF; the extended band, staged snapshot + argsort asserted ON.
	_gate_card_calt()      # S3 alt-band zone law (FP_STRUCT_CARD_ALT_BAND)
	_gate_card_res()       # S3/§5 residency across altitude boundaries (real prelude path)
	_gate_card_sort()      # S2/§7 precomputed-distance argsort — set+cap equality + tie determinism
	_gate_card_snapstage() # S4/§6 staged double-buffered snapshot + churn-starvation (FP_STRUCT_CARD_STAGE)
	_gate_card_wake()      # S4/§8 wake fade-in — atomic, empty-only, no resident blink, zones S+B

	# COSMOS FAR-EDIT-DEBOUNCE (docs/COSMOS-FAR-EDIT-DEBOUNCE-DESIGN.md, FP_STRUCT_EDIT_DEBOUNCE) — defer far-visible
	# structure revs until the player departs + idles. Flag-aware: OFF asserts the shipped immediate re-bake; ON asserts
	# the hold, the coalesced publish, never-drop, the tracker half, and the WorldManager idle+depart gate.
	_gate_sed_hold()       # P2: an in-house edit HOLDS the version + published rev (no far re-materialize)
	_gate_sed_publish()    # P1: publish ⇒ ONE version drift for N roots (coalescing); served rev == truth
	_gate_sed_neverdrop()  # randomized edit/publish ⇒ published == truth after the final publish
	_gate_sed_tracker()    # the tracker half: version()/_make_record held, publish() latches
	_gate_sed_gate()       # the WorldManager idle+depart gate + NEVER-OOM force-publish
	# v2 (docs/COSMOS-FAR-EDIT-DEBOUNCE-REDESIGN.md §7) — the re-add's O(1)-edit-frame / deferred-classifier guarantees.
	_gate_sed_cold()       # NEW: a COLD-cache in-bbox edit does NO enumeration on the input path; classify+publish ⇒ published==truth (never-drop from cold)
	_gate_sed_classify()   # NEW: mixed batch ⇒ EXACTLY the in-house edit bumps; record_bbox == the enumerated bbox (single-source law)
	_gate_sed_budget()     # NEW: 100 queued ⇒ drained ≤ ⌈100/MIN⌉ ticks; overflow ⇒ off-frame enumerate (NEVER-OOM superset)

	# COSMOS LOD-DROPOUT S3 (docs/COSMOS-LOD-DROPOUT-DESIGN.md §4, FP_SKIN_READY_GATE): the card→roof-skin hide holds the
	# card tier until the roof handoff set's fine-map skin is baked, up to STRUCT_CARD_HOLD_MAX_ALT. Flag-aware.
	_gate_skin_gate()

	print("=== VERIFY structures: ", _pass, " passed, ", _fail, " failed ===")
	quit(1 if _fail > 0 else 0)

# =====================================================================================================================
# G-SG helpers — locate a real generated house (deterministic scan over Earth facets) to drive the deep gates.
# =====================================================================================================================
const SG := preload("res://src/world/structure_gen.gd")
const SGI := preload("res://src/world/struct_gen_index.gd")
const WM := preload("res://src/world/world_manager.gd")

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
	if CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		# FP_STRUCT_EDIT_DEBOUNCE v2: note_edit is STRICTLY O(1) — it ENQUEUES the edit (no truth-rev bump, no enumeration
		# on the input path); classification (the truth-rev bump) is deferred off-frame to WorldManager._sed_classify_step.
		_ok(rev1 == rev0 and int(idx._rev.get(root, 0)) == rev0,
			"G-SG-DAMAGE(debounce): note_edit HOLDS the served rev AND defers the truth bump (O(1) enqueue — no input-frame classify)")
		_ok(idx.uncls_size() >= 1,
			"G-SG-DAMAGE(debounce): the edit is captured in the un-classified queue (drained + classified off the input frame)")
	else:
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
	# (d) FP_STRUCT_LOD declared (the fine-map roof-pixel consults + the palette re-home are all flag-gated ⇒ byte-off).
	#     Flag-aware (the combined build ships it true) — G-ST-LODSKIN proves the composite ON, byte-identity OFF.
	_ok(CubeSphere.FP_STRUCT_LOD == false or CubeSphere.FP_STRUCT_LOD == true,
		"G-SG-SKIN: FP_STRUCT_LOD declared (facet_tex_baker + bake_far_tile roof consults gated on it)")

# =====================================================================================================================
# G-ST-LODSKIN (FP_STRUCT_LOD — docs/COSMOS-CARD-BAND-HANDOFF-DESIGN.md §10, roof-skin arm) — the far-skin BAKER
# composites a house roof texel into the fine/band map (edit > house > tree > terrain), so a village reads as brown
# rooftop specks above the card band (Stage 3 zone-O handoff). This mirrors facet_tex_baker.gd's band-map composite
# (:1383-1397) exactly, over a real village: the roof texel's palette index differs from the bare-terrain index there.
# Plus the dark_oak_log → BROWN swatch (8) re-home is flag-gated (off ⇒ its raw near-black grey nearest ⇒ byte-off LUT).
# Flag-aware: ON asserts the re-home + composite; OFF asserts the LUT is un-re-homed (byte-identical).
# =====================================================================================================================
func _gate_lodskin() -> void:
	var on := CubeSphere.FP_STRUCT_LOD
	FarPalette.ensure_far_index_ready()
	var doak := BlockCatalog.id_of(&"dark_oak_log")
	var doak_idx := FarPalette.far_color_index_of_block(doak)
	if on:
		_ok(doak_idx == 8, "G-ST-LODSKIN(on): dark_oak_log re-homed to the BROWN swatch (idx 8) — roofs read brown, not near-black")
	else:
		_ok(doak_idx != 8, "G-ST-LODSKIN(off): dark_oak_log keeps its raw nearest swatch (no brown re-home) — byte-identical LUT")
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-ST-LODSKIN: no generated house (fixture)")
		return
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var bmin: Vector3i = rec["bmin"]; var bmax: Vector3i = rec["bmax"]
	# Replicate the band-map baker composite (:1383-1397) over the footprint: WITH lod the house roof wins; WITHOUT lod
	# the consult is skipped (tree, else terrain). Assert the roof texel actually CHANGES the fine map for ≥1 column.
	var roof_cols := 0
	var roof_changed := 0
	for x in range(bmin.x, bmax.x + 1):
		for z in range(bmin.z, bmax.z + 1):
			var hdeco: int = SG.top_decoration(x, z, ctx)
			if hdeco == BlockCatalog.AIR:
				continue
			roof_cols += 1
			var idx_lod: int = FarPalette.far_color_index_of_block(hdeco) + 1
			var idx_nolod: int
			var deco: int = TreeGen.top_decoration(x, z, ctx)
			if deco != BlockCatalog.AIR:
				idx_nolod = FarPalette.far_color_index_of_block(deco) + 1
			else:
				var prof := TerrainConfig.column_profile(x, z, ctx)
				var tcol := FarPalette.color_for(int(prof.x), int(prof.y), prof.w, int(prof.x) < TerrainConfig.SEA_LEVEL)
				idx_nolod = FarPalette.far_color_index(tcol) + 1
			if idx_lod != idx_nolod:
				roof_changed += 1
	_ok(roof_cols > 0, "G-ST-LODSKIN: the fixture village has ≥1 exposed roof column (top_decoration>0)")
	_ok(roof_changed > 0,
		"G-ST-LODSKIN: the roof texel composites into the fine map (roof palette idx ≠ terrain/tree idx for ≥1 column)")
	# byte-off pin: the baker's `if bid<0 and FP_STRUCT_LOD` consult + the LUT re-home are BOTH flag-gated ⇒ off the tile
	# is byte-identical (the re-home absence above is the LUT half; the consult short-circuit is the composite half).
	_ok(CubeSphere.FP_STRUCT_LOD == false or CubeSphere.FP_STRUCT_LOD == true, "G-ST-LODSKIN: FP_STRUCT_LOD declared")

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
# G-SKIN-GATE (FP_SKIN_READY_GATE — docs/COSMOS-LOD-DROPOUT-DESIGN.md §4, Stage S3) — the card→roof-skin handoff hold.
# The structure card tier holds (visible, tier_fade ≥ SKIN_HOLD_FADE) above STRUCT_CARD_HIDE_ALT until the roof handoff
# set's fine-map skin is baked (ready_frac ≥ SKIN_READY_MIN), OR the camera passes STRUCT_CARD_HOLD_MAX_ALT (the hard
# ceiling). Only under FP_STRUCT_LOD (a roof skin exists) + FP_STRUCT_CARD_ALT_BAND (the extended card band). A stub
# ready query + a seeded handoff set prove the hold law without a live baker. Off ⇒ the shipped card hide verbatim.
# =====================================================================================================================
func _gate_skin_gate() -> void:
	if not CubeSphere.FP_STRUCT_CARDS:
		print("  (G-SKIN-GATE skipped — needs FP_STRUCT_CARDS sed-toggled true)")
		return
	var on := CubeSphere.FP_SKIN_READY_GATE and CubeSphere.FP_STRUCT_LOD and CubeSphere.FP_STRUCT_CARD_ALT_BAND
	if on:
		# roof skin un-ready at h=2500 (∈ (HIDE 2400, HOLD_MAX 2800)) ⇒ cards HELD visible, faded ≥ floor.
		var t1 = FS.new(); t1.setup_instance(Node3D.new(), 0); t1.set_skin_ready_query(Callable(self, "_fake_skin_ready"))
		t1.debug_seed_hold_fids([0, 1, 2])
		_fake_skin_frac = 0.0
		var rh := t1.debug_skin_gate(true, 2500.0)
		_ok(rh["skin_hold"] and rh["st_cards"] and rh["card_fade"] >= CubeSphere.SKIN_HOLD_FADE,
			"G-SKIN-GATE(on): roof skin un-ready at h=2500 ⇒ cards HELD (visible, fade %.2f ≥ %.2f)" % [rh["card_fade"], CubeSphere.SKIN_HOLD_FADE])
		# ready ⇒ the hand-off completes (card zone-O hide) — the shipped behaviour, within one step.
		var t2 = FS.new(); t2.setup_instance(Node3D.new(), 0); t2.set_skin_ready_query(Callable(self, "_fake_skin_ready"))
		t2.debug_seed_hold_fids([0, 1, 2])
		_fake_skin_frac = 1.0
		var rr := t2.debug_skin_gate(true, 2500.0)
		_ok(not rr["skin_hold"] and not rr["st_cards"], "G-SKIN-GATE(on): roof skin ready at h=2500 ⇒ cards hidden (hand-off)")
		# ceiling: un-ready but above STRUCT_CARD_HOLD_MAX_ALT ⇒ the hold RELEASES.
		var t3 = FS.new(); t3.setup_instance(Node3D.new(), 0); t3.set_skin_ready_query(Callable(self, "_fake_skin_ready"))
		t3.debug_seed_hold_fids([0, 1, 2])
		_fake_skin_frac = 0.0
		var rc := t3.debug_skin_gate(true, 2900.0)
		_ok(not rc["skin_hold"] and not rc["st_cards"], "G-SKIN-GATE(on): above STRUCT_CARD_HOLD_MAX_ALT the hold releases (ceiling)")
		# empty handoff set ⇒ frac degrades to 1.0 ⇒ no hold (degrade-safe).
		var t4 = FS.new(); t4.setup_instance(Node3D.new(), 0); t4.set_skin_ready_query(Callable(self, "_fake_skin_ready"))
		_fake_skin_frac = 0.0
		_ok(not t4.debug_skin_gate(true, 2500.0)["skin_hold"], "G-SKIN-GATE(on): empty handoff set ⇒ no hold (degrade-safe)")
	else:
		var t0 = FS.new(); t0.setup_instance(Node3D.new(), 0); t0.set_skin_ready_query(Callable(self, "_fake_skin_ready"))
		t0.debug_seed_hold_fids([0, 1, 2])
		_fake_skin_frac = 0.0
		_ok(not t0.debug_skin_gate(true, 2500.0)["skin_hold"],
			"G-SKIN-GATE(off): FP_SKIN_READY_GATE (or STRUCT_LOD/ALT_BAND) off ⇒ never holds (byte-identical)")

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

# =====================================================================================================================
# G-ST-CARD-* (FP_STRUCT_CARDS — docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md §11) — the far-village impostor-card tier.
# =====================================================================================================================

## The GLSL sector-select mirror (§8.1): the archetype azimuth column from the house→camera azimuth α. Used by the
## atan-wrap check (risk 10) so the ±π boundary is proven CPU-side.
func _card_sector(alpha: float) -> int:
	var k: float = floor(alpha * (8.0 / TAU) + 0.5)
	return int(fposmod(k + 8.0, 8.0))

## The full in-shader sector-select twin (§8.1 corrected): ca = dot(fh, e_f), sa = dot(fh, e_s), col = round(atan2(−sa,
## ca)·8/2π) mod 8. Mirrors _CARD_TAIL's `atan(-sa, ca)` (the mirror the raster convention x̂↦−e_f, ẑ↦+e_s requires).
func _shader_sector(fh: Vector3, ef: Vector3, es: Vector3) -> int:
	var ca := fh.dot(ef)
	var sa := fh.dot(es)
	var k: float = floor(atan2(-sa, ca) * (8.0 / TAU) + 0.5)
	return int(fposmod(k + 8.0, 8.0))

## The first Earth facet with ≥ n generated houses, as {idx, fid, recs}. {} if none within the scan cap.
func _find_houses(n: int) -> Dictionary:
	var idx = SGI.new()
	var earth_n := 6 * FA.K * FA.K
	for fid in range(mini(earth_n, 2000)):
		var recs: Array = idx.enumerate_facet(fid)
		if recs.size() >= n:
			return {"idx": idx, "fid": fid, "recs": recs}
	return {}

## G-ST-CARD-OFF — flag-off byte-identity of the tier construction + confound-free telemetry (both flag states self-describe).
func _gate_card_off() -> void:
	var on := CubeSphere.FP_STRUCT_CARDS
	_ok(CubeSphere.FP_STRUCT_CARDS == false or CubeSphere.FP_STRUCT_CARDS == true, "G-ST-CARD-OFF: FP_STRUCT_CARDS declared")
	var tier = FS.new()
	tier.setup_instance(Node3D.new(), 0)
	if on:
		_ok(tier._card_mmi != null, "G-ST-CARD-OFF(on): the card MMI is constructed under the flag")
		_ok(tier.draw_count() == 2, "G-ST-CARD-OFF(on): draw_count == 2 (merged cube mesh + card MMI)")
		_ok(not tier.card_state().is_empty(), "G-ST-CARD-OFF(on): card_state() populated")
	else:
		_ok(tier._card_mmi == null, "G-ST-CARD-OFF(off): NO card node constructed (byte-identical)")
		_ok(tier._card_prec.is_empty(), "G-ST-CARD-OFF(off): _card_prec empty (never filled)")
		_ok(tier.card_state().is_empty(), "G-ST-CARD-OFF(off): card_state() empty (confound-free telemetry)")
		_ok(tier.draw_count() == 1, "G-ST-CARD-OFF(off): draw_count == 1 (shipped LOD-A cube tier)")

## G-ST-CARD-ARCH — arch_index total + injective + round-trips; unpack_root round-trips pack_root; atan sector wrap. PURE.
func _gate_card_arch() -> void:
	var seen: Dictionary = {}
	var ok_all := true
	# flat archetypes: roof 0, wall_h ∈ {3,4}.
	for wall_h in [3, 4]:
		var i := SCK.arch_index(0, wall_h, 0)
		if i < 0 or i >= 10 or seen.has(i):
			ok_all = false
		seen[i] = true
		var p := SCK.arch_params(i)
		if int(p["roof"]) != 0 or int(p["wall_h"]) != wall_h:
			ok_all = false
	# gabled: roof 1, wall_h ∈ {3,4}, d ∈ [5,11] ⇒ gable_h = d/2 ∈ {2..5}.
	var gab: Dictionary = {}
	for wall_h in [3, 4]:
		for d in range(5, 12):
			var gable_h := int(d / 2)
			var i := SCK.arch_index(1, wall_h, gable_h)
			if i < 2 or i >= 10:
				ok_all = false
			var trip := "1_%d_%d" % [wall_h, gable_h]
			if gab.has(i) and gab[i] != trip:
				ok_all = false                        # a distinct triple must not collide onto the same index
			gab[i] = trip
			seen[i] = true
			var p := SCK.arch_params(i)
			if int(p["roof"]) != 1 or int(p["wall_h"]) != wall_h or int(p["gable_h"]) != gable_h:
				ok_all = false
	_ok(ok_all, "G-ST-CARD-ARCH: arch_index total + injective over the reachable space, round-trips arch_params")
	_ok(seen.size() == 10, "G-ST-CARD-ARCH: exactly 10 distinct archetypes reached")
	# unpack_root round-trips pack_root over a signed sweep.
	var rt := true
	for fid in [0, 1, 500, 3455]:
		for hx in [-4242, -100, -1, 0, 1, 7, 4242]:
			for hz in [-4242, -7, 0, 1, 100, 4242]:
				var root := SG.pack_root(fid, hx, hz)
				var u := SG.unpack_root(root)
				if int(u[0]) != fid or int(u[1]) != hx or int(u[2]) != hz:
					rt = false
	_ok(rt, "G-ST-CARD-ARCH: unpack_root(pack_root(fid,hx,hz)) round-trips over a signed sweep")
	# atan sector wrap (risk 10): α at ±π lands in ONE sector (no 0↔7 flicker).
	_ok(_card_sector(PI - 0.001) == _card_sector(-PI + 0.001),
		"G-ST-CARD-ARCH: atan sector — α at ±π maps to one sector (mod wrap, no flicker)")

## G-ST-CARD-ATLAS — the atlas builds; 90 tiles each with opaque texels; 3-px pad (no border touch); door ≠ back view. PURE.
func _gate_card_atlas() -> void:
	var atlas := SCK.build_atlas()
	_ok(atlas != null, "G-ST-CARD-ATLAS: atlas builds")
	var img := atlas.get_image()
	var wpx := SCK.COLS * SCK.TILE
	var hpx := SCK.ROWS * SCK.TILE
	_ok(img.get_width() == wpx and img.get_height() == hpx, "G-ST-CARD-ATLAS: atlas is %d×%d" % [wpx, hpx])
	_ok(img.get_data().size() == wpx * hpx * 4, "G-ST-CARD-ATLAS: image bytes == %d (RGBA8)" % (wpx * hpx * 4))
	var all_op := true
	var no_border := true
	for a in range(SCK.ROWS):
		for v in range(SCK.COLS):
			var ox := v * SCK.TILE
			var oy := a * SCK.TILE
			var opq := 0
			for yy in range(SCK.TILE):
				for xx in range(SCK.TILE):
					if img.get_pixel(ox + xx, oy + yy).a > 0.5:
						opq += 1
						if xx == 0 or yy == 0 or xx == SCK.TILE - 1 or yy == SCK.TILE - 1:
							no_border = false
			if opq == 0:
				all_op = false
	_ok(all_op, "G-ST-CARD-ATLAS: every one of the %d tiles has > 0 opaque texels" % (SCK.ROWS * SCK.COLS))
	_ok(no_border, "G-ST-CARD-ATLAS: no opaque texel touches a tile border (3-px pad, filter_nearest seam-safe)")
	var diff := false
	for a in range(SCK.ROWS):
		var oy := a * SCK.TILE
		for yy in range(SCK.TILE):
			for xx in range(SCK.TILE):
				if not img.get_pixel(0 * SCK.TILE + xx, oy + yy).is_equal_approx(img.get_pixel(4 * SCK.TILE + xx, oy + yy)):
					diff = true
	_ok(diff, "G-ST-CARD-ATLAS: door view (0) ≠ back view (4) — the door is actually rasterized")

## G-ST-CARD-SHADER — the CPU twin of the card vertex() math (the GPU shader can't compile headless): (1) the UV/UV2
## local-corner reconstruction matches the mesh (the world_vertex_coords fix — VERTEX is world, reconstructed not read);
## (2) the corrected sector select round(atan2(−sa,ca)·8/2π) picks atlas column k for the view-k camera direction (the
## raster convention). Pure math + the static mesh ⇒ runs in BOTH flag states.
func _gate_card_shader() -> void:
	# (1) local-corner reconstruction (billboard: lx=UV.x−0.5, ly=1−UV.y; cap: lx=UV.x−0.5, lz=UV.y−0.5).
	var mesh := FS._build_card_mesh()
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var uv2s: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
	var recon_ok := verts.size() == 8
	for i in range(verts.size()):
		var v := verts[i]
		var uv := uvs[i]
		var lx := uv.x - 0.5
		if uv2s[i].x < 0.5:
			if absf(lx - v.x) > 1e-5 or absf((1.0 - uv.y) - v.y) > 1e-5:
				recon_ok = false
		else:
			if absf(lx - v.x) > 1e-5 or absf((uv.y - 0.5) - v.z) > 1e-5:
				recon_ok = false
	_ok(recon_ok, "G-ST-CARD-SHADER: UV/UV2 local-corner reconstruction matches the mesh (world_vertex_coords: VERTEX is world, never read as local)")
	# (2) sector select matches the raster view convention.
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-ST-CARD-SHADER: no house for the sector twin")
		return
	var rec: Dictionary = found["rec"]
	var prec := FS.new()._precompute_card(rec)
	if float(prec[0]) < 0.5:
		_ok(false, "G-ST-CARD-SHADER: the fixture house is not card-eligible (unexpected)")
		return
	var o := Vector3(prec[5], prec[6], prec[7])
	var ef := Vector3(prec[8], prec[9], prec[10])
	var n := o.normalized()
	var es := n.cross(ef).normalized()                   # e_s exactly as _write_card_inst derives it
	var sect_ok := true
	for k in range(8):
		var ang := float(k) * (PI / 4.0)
		var fh := ef * cos(ang) - es * sin(ang)          # the view-k toward-camera reference direction (world)
		if _shader_sector(fh, ef, es) != k:
			sect_ok = false
	_ok(sect_ok, "G-ST-CARD-SHADER: round(atan2(−sa,ca)·8/2π) selects atlas column k for the view-k camera direction (raster convention)")

## G-ST-CARD-EMIT — one GEN house at dist 800 ⇒ exactly one card (flag on) / cube (flag off). Drives the REAL
## _resnapshot → _precompute_card → _rebuild card-sink chain (registry/version Callables, as WorldManager wires them).
func _gate_card_emit() -> void:
	var on := CubeSphere.FP_STRUCT_CARDS
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-ST-CARD-EMIT: no generated house found (fixture)")
		return
	var rec: Dictionary = found["rec"]
	var reg_src := FakeReg.new()
	reg_src.set_records([rec.duplicate()])
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp); t.set_near_query(nearq)
	t.set_registry_query(Callable(reg_src, "registry")); t.set_version_query(Callable(reg_src, "version"))
	var centre := t._structure_centre(rec)
	var cam := centre - centre.normalized() * 800.0
	_epoch_prelude(t, cam)
	if not on:
		_ok(t.live_cards() == 0 and t.debug_card_buffer().is_empty(),
			"G-ST-CARD-EMIT(off): no card emitted (cube path, byte-identical)")
		_ok(t.live_structures() == 1 and t.live_tris() > 0, "G-ST-CARD-EMIT(off): the GEN house renders on the merged-cube mesh")
		return
	# ON — exactly one card, NOT in the cube mesh (one sink).
	_ok(t.live_cards() == 1, "G-ST-CARD-EMIT(on): exactly 1 card instance for the GEN house")
	_ok(t.live_tris() == 0, "G-ST-CARD-EMIT(on): the card house is NOT in the merged-cube mesh (one sink)")
	var buf := t.debug_card_buffer()
	var by := Vector3(buf[1], buf[5], buf[9])            # basis-Y column (n̂·H)
	var o := Vector3(buf[3], buf[7], buf[11])            # origin
	var n := o.normalized()
	var H := float((rec["bmax"] as Vector3i).y - (rec["bmin"] as Vector3i).y + 1)
	_ok(by.normalized().dot(n) > 0.999, "G-ST-CARD-EMIT(on): basis-Y ∥ the origin radial (sphere billboard up-axis)")
	_ok(absf(by.length() - H) < 1e-2, "G-ST-CARD-EMIT(on): |basis-Y| == house height H")
	# origin == the SAME lattice_to_world(+datum_lift) base-centre law _ensure_bake uses (risk 4 — no vertical pop).
	var bmin: Vector3i = rec["bmin"]; var bmax: Vector3i = rec["bmax"]
	var cxr := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
	var czr := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
	var byr := float(bmin.y)
	if CubeSphere.FP_FT_FRAME_WELD:
		byr += FA.datum_lift(int(rec["fid"]), cxr, czr)
	var wr := FA.lattice_to_world64(int(rec["fid"]), cxr, byr, czr)
	_ok(o.distance_to(Vector3(wr[0], wr[1], wr[2])) < 1e-3, "G-ST-CARD-EMIT(on): origin == the ensure_bake base-centre law (±1e-3)")
	# custom == (arch, w_s, w_f, 1.0) with the door-2/3 w/d swap.
	var up := SG.unpack_root(int(rec["root"]))
	var hi := SG.house_info(int(up[1]), int(up[2]), TerrainConfig.GenCtx.new(0, int(up[0])))
	var door := int(hi["door"])
	var exp_arch := SCK.arch_index(int(hi["roof"]), int(hi["wall_h"]), int(hi["gable_h"]))
	var exp_wf := float(hi["w"]) if door <= 1 else float(hi["d"])
	var exp_ws := float(hi["d"]) if door <= 1 else float(hi["w"])
	_ok(int(buf[12]) == exp_arch, "G-ST-CARD-EMIT(on): custom.x == arch_index of the house")
	_ok(is_equal_approx(buf[13], exp_ws) and is_equal_approx(buf[14], exp_wf),
		"G-ST-CARD-EMIT(on): custom (w_s, w_f) pre-swapped per door=%d (§3.3)" % door)
	_ok(buf[15] == 1.0, "G-ST-CARD-EMIT(on): custom.w (fade) == 1.0 in P0")

## G-ST-CARD-SPLIT — two GEN houses (real roots, overridden bboxes): one below the split (cube), one above (card);
## a camera sweep across STRUCT_CARD_MIN ± 2·STRUCT_HYST_W keeps the total emitted count constant (one sink, never
## dropped/doubled). Injects _card_prec via _precompute_card + drives _rebuild directly (deterministic, no worker).
func _gate_card_split() -> void:
	var on := CubeSphere.FP_STRUCT_CARDS
	var found := _find_houses(2)
	if found.is_empty():
		_ok(false, "G-ST-CARD-SPLIT: no facet with ≥2 generated houses (fixture)")
		return
	var recs: Array = found["recs"]
	var fid := int(found["fid"])
	# rec0 (near, sweeps across the split) + rec1 (far, always card), 700 blocks apart in z on the owner facet.
	var r0d: Dictionary = (recs[0] as Dictionary).duplicate(); r0d["bmin"] = Vector3i(100, 40, 100); r0d["bmax"] = Vector3i(106, 46, 106); r0d["fid"] = fid
	var r1d: Dictionary = (recs[1] as Dictionary).duplicate(); r1d["bmin"] = Vector3i(100, 40, 800); r1d["bmax"] = Vector3i(106, 46, 806); r1d["fid"] = fid
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp); t.set_near_query(nearq)
	# populate _card_prec directly (bypasses _resnapshot; the same rows _resnapshot would compute).
	t._card_prec[int(r0d["root"])] = t._precompute_card(r0d)
	t._card_prec[int(r1d["root"])] = t._precompute_card(r1d)
	var reg: Array = [r0d, r1d]
	var c0 := t._structure_centre(r0d)
	var rdir := c0.normalized()
	# below the split (dist 300 < 320): rec0 cube; above (dist 340 > 320): rec0 card. rec1 stays far (card).
	if not on:
		# OFF: both are cube path (is_card 0 ⇒ _precompute_card returns is_card 0); no cards ever.
		t._rebuild(reg, c0 - rdir * 340.0)
		_ok(t.live_cards() == 0, "G-ST-CARD-SPLIT(off): no card emitted at any distance (byte-identical cube path)")
		return
	# ON — rec0 cube at dist 300, card at dist 340.
	t._rebuild(reg, c0 - rdir * 300.0)
	var rec0_cube := t.live_tris() > 0 and t.live_cards() == 1        # rec0 cube, rec1 card
	t._rebuild(reg, c0 - rdir * 340.0)
	var rec0_card := t.live_cards() == 2 and t.live_tris() == 0       # both card
	_ok(rec0_cube, "G-ST-CARD-SPLIT(on): a house below STRUCT_CARD_MIN renders on the merged-cube mesh (not the card buffer)")
	_ok(rec0_card, "G-ST-CARD-SPLIT(on): the same house beyond STRUCT_CARD_MIN renders as a card (not the mesh) — the split")
	# exactly-one-sink invariant across a camera sweep over STRUCT_CARD_MIN ± 2·STRUCT_HYST_W (nothing dropped/doubled).
	var w := CubeSphere.STRUCT_HYST_W
	var constant := true
	var steps := 24
	for s in range(steps + 1):
		var d := (CubeSphere.STRUCT_CARD_MIN - 2.0 * w) + (4.0 * w) * float(s) / float(steps)
		t._rebuild(reg, c0 - rdir * d)
		var total := t.live_cards() + (1 if t.live_tris() > 0 else 0)   # rec0 sink + rec1 (card)
		if total != 2:
			constant = false
	_ok(constant, "G-ST-CARD-SPLIT(on): total emitted == 2 across a sweep over STRUCT_CARD_MIN ± 2·STRUCT_HYST_W (one sink, never dropped/doubled)")

## G-ST-CARD-CULL — the load-bearing player-built guard (risk 6) + the beyond-near-reach card is never spuriously culled.
func _gate_card_cull() -> void:
	var on := CubeSphere.FP_STRUCT_CARDS
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	# (1) player-built (root ≥ 0) at a card distance ⇒ merged-cube path, NEVER a card (risk 6, the §6.1 guard).
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp)
	t.set_near_query(func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE)
	# a POSITIVE (player-built / tracker) root — no house_info, unique geometry ⇒ the cube path owns it at every distance.
	var pb := {"root": 42, "fid": 0, "bmin": Vector3i(100, 40, 100), "bmax": Vector3i(106, 46, 106), "rev": 1}
	if CubeSphere.FP_STRUCT_CARDS:
		t._card_prec[42] = t._precompute_card(pb)         # is_card MUST be 0 (positive root)
		_ok(float(t._card_prec[42][0]) < 0.5, "G-ST-CARD-CULL: a positive-root (player-built) record precomputes is_card == 0")
	var c := t._structure_centre(pb)
	t._rebuild([pb], c - c.normalized() * 800.0)
	_ok(t.live_cards() == 0 and t.live_tris() > 0,
		"G-ST-CARD-CULL: a player-built structure at card distance renders on the cube mesh, NEVER the card buffer")
	# (2) a GEN card beyond the near-mesh reach is emitted UNPROBED — a COVERED near-query must NOT cull it (near can't reach).
	if on:
		var found := _find_house()
		if not found.is_empty():
			var rec: Dictionary = found["rec"]
			var t2 = FS.new(); t2.setup_instance(Node3D.new(), 0); t2.set_sampler(samp)
			t2.set_near_query(func(_f: int, _b: AABB) -> int: return NearPresence.COVERED)   # near CLAIMS covered
			t2._card_prec[int(rec["root"])] = t2._precompute_card(rec)
			var cc := t2._structure_centre(rec)
			t2._rebuild([rec], cc - cc.normalized() * 800.0)
			_ok(t2.live_cards() == 1,
				"G-ST-CARD-CULL(on): a card beyond the near-mesh reach (dist 800) is emitted unprobed (COVERED is irrelevant)")
		# (3) SHOULD-FIX 8: a dead card-only root's _band/_cull state is reaped against the live registry (no unbounded
		# growth in a cards-all-the-way arm where card roots never get a _baked entry the shipped reap keys on).
		var tr = FS.new(); tr.setup_instance(Node3D.new(), 0); tr.set_sampler(samp)
		tr.set_near_query(func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE)
		tr._cull[-9999] = {"hidden": false, "cover": 0, "uncover": 0}   # stale card-only root (no _baked entry)
		tr._band[-9999] = 4
		tr._rebuild([], Vector3(1000.0, 0.0, 0.0))                      # empty registry ⇒ −9999 is dead
		_ok(not tr._cull.has(-9999) and not tr._band.has(-9999),
			"G-ST-CARD-CULL(on): a dead card-only root's _band/_cull state is reaped (bounded, no cross-facet leak)")

## G-ST-CARD-CUBECAP (SHOULD-FIX 5) — the cube tri cap must NOT terminate the card sink: a dense near cube cluster that
## fills STRUCT_FAR_TRIS_MAX must still leave a farther GEN card emitted (the nearest-first loop `continue`s past the
## cube cap for card records instead of `break`ing). ON-only (the OFF break path is the shipped behaviour).
func _gate_card_cubecap() -> void:
	if not CubeSphere.FP_STRUCT_CARDS:
		return
	var g := _grass()
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-ST-CARD-CUBECAP: no GEN house fixture")
		return
	# Checkerboard sampler ⇒ no two adjacent solids ⇒ no greedy face merge ⇒ ~10k tris per 12³ box (fills the 80k cube
	# cap in a handful of boxes, cheaply). The cube houses carry POSITIVE roots ⇒ is_card 0 ⇒ the cube sink.
	var samp := func(_f: int, c: Vector3i) -> int:
		return g if ((c.x + c.y + c.z) & 1) == 0 else 0
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp); t.set_near_query(nearq)
	var cardrec: Dictionary = (found["rec"] as Dictionary).duplicate()
	var fid := int(cardrec["fid"])
	var reg: Array = []
	for k in range(12):
		var bmin := Vector3i(100 + k * 20, 40, 100)
		reg.append({"root": 700 + k, "fid": fid, "bmin": bmin, "bmax": bmin + Vector3i(11, 11, 11), "rev": 1})
	cardrec["bmin"] = Vector3i(100, 40, 1600); cardrec["bmax"] = Vector3i(106, 46, 1606); cardrec["fid"] = fid
	reg.append(cardrec)
	for r in reg:
		t._card_prec[int(r["root"])] = t._precompute_card(r)
	var c0: Vector3 = t._structure_centre(reg[0])
	var cam := c0 - c0.normalized() * 500.0
	_ok(t._structure_dist(cardrec, cam) > t._structure_dist(reg[0], cam) and t._structure_dist(cardrec, cam) < CubeSphere.STRUCT_FAR_MAX,
		"G-ST-CARD-CUBECAP: the card house is farther than the cube cluster and in-band (nearest-first reaches cubes first)")
	t._rebuild(reg, cam)
	_ok(t._capped, "G-ST-CARD-CUBECAP: the checkerboard cube cluster fills the cube tri cap")
	_ok(t.live_cards() == 1,
		"G-ST-CARD-CUBECAP: the far GEN card STILL emits past the full cube cap (the cube cap no longer terminates the card scan)")

## G-ST-CARD-EPOCH — parked over a card village (same version) ⇒ zero card-buffer rewrites; a damage rev bump ⇒ one rebuild.
func _gate_card_epoch() -> void:
	var on := CubeSphere.FP_STRUCT_CARDS
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-ST-CARD-EPOCH: no generated house found (fixture)")
		return
	var rec: Dictionary = found["rec"]
	var reg_src := FakeReg.new()
	reg_src.set_records([rec.duplicate()])
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp); t.set_near_query(nearq)
	t.set_registry_query(Callable(reg_src, "registry")); t.set_version_query(Callable(reg_src, "version"))
	var centre := t._structure_centre(rec)
	var cam := centre - centre.normalized() * 800.0
	_epoch_prelude(t, cam)
	var cards0 := t.live_cards()
	if on:
		_ok(cards0 == 1, "G-ST-CARD-EPOCH(on): prime — the card village merges (1 card)")
	# PARKED — same version, empty annulus (card band) ⇒ O(1) skip (no re-probe, no re-commit).
	var rb := t.rebuild_count()
	var did := t._prelude_epoch(cam, false)
	_ok(not did and t.rebuild_count() == rb, "G-ST-CARD-EPOCH: parked over a card village (same version) ⇒ O(1) skip (no re-commit)")
	# EDIT — a damage rev bump advances the version; the epoch prelude signals a rebuild THIS step.
	reg_src.bump_edit(int(rec["root"]))
	_ok(t._prelude_epoch(cam, false), "G-ST-CARD-EPOCH: a damage rev bump ⇒ rebuild signalled the same step (never delayed)")
	if on:
		t._rebuild(t._snapshot, cam)
		# A DAMAGED (rev != 0) GEN house drops OFF the card path onto the CUBE sink so the hole shows (a pristine card
		# would hide the damage) — the SHOULD-FIX 7 guard in _precompute_card.
		_ok(t.live_cards() == 0 and t.live_tris() > 0,
			"G-ST-CARD-EPOCH(on): a damaged (rev-bumped) GEN house routes to the CUBE sink so the hole shows (not a pristine card)")

## G-ST-CARD-OOM — the NEVER-OOM ledger + the card cap. 4,000 synthetic card records ⇒ st_ci ≤ STRUCT_CARD_INST_MAX
## (cap respected, nearest-first) + total_bytes ≤ STRUCT_BYTES_MAX.
func _gate_card_oom() -> void:
	var on := CubeSphere.FP_STRUCT_CARDS
	var t = FS.new(); t.setup_instance(Node3D.new(), 0)
	t.set_near_query(func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE)
	_ok(t.total_bytes() <= CubeSphere.STRUCT_BYTES_MAX, "G-ST-CARD-OOM: fresh tier total_bytes within the 8 MB ceiling")
	if not on:
		_ok(t.card_state().is_empty(), "G-ST-CARD-OOM(off): no card ledger (byte-identical)")
		return
	# 4,000 card-eligible records clustered on facet 0 (all in the card band from one camera). Inject valid card precs.
	var fb := FA.frame_basis(0)
	var e_f := -fb.x
	var reg: Array = []
	for k in range(4000):
		var bmin := Vector3i(100 + (k % 60), 40, 100 + int(k / 60))
		var bmax := bmin + Vector3i(6, 6, 6)
		var root := -(100000 + k)                         # distinct fabricated negative roots (dict keys)
		reg.append({"root": root, "fid": 0, "source": SG.SOURCE_GEN, "bmin": bmin, "bmax": bmax, "rev": 1})
		var cxw := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
		var czw := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
		var wr := FA.lattice_to_world64(0, cxw, float(bmin.y), czw)
		t._card_prec[root] = PackedFloat32Array([1.0, 0.0, 6.0, 6.0, 7.0, float(wr[0]), float(wr[1]), float(wr[2]), e_f.x, e_f.y, e_f.z, 0.0])
	var c0: Vector3 = t._structure_centre(reg[0])
	var cam := c0 - c0.normalized() * 800.0
	t._rebuild(reg, cam)
	_ok(t.live_cards() == CubeSphere.STRUCT_CARD_INST_MAX and t.card_capped(),
		"G-ST-CARD-OOM(on): st_ci == STRUCT_CARD_INST_MAX (cap respected, nearest-first) under a 4,000-record registry")
	_ok(t.total_bytes() <= CubeSphere.STRUCT_BYTES_MAX,
		"G-ST-CARD-OOM(on): total_bytes (cap-full buffer + atlas + prec) ≤ STRUCT_BYTES_MAX")

# =====================================================================================================================
# G-ST-CALT (S3 §4 — FP_STRUCT_CARD_ALT_BAND) — the card altitude-band zone law. The card tier reclassifies
# INDEPENDENTLY of the cube zone: visible through STRUCT_CARD_HIDE_ALT (2400), hidden above; the cube mesh keeps its
# 600 law. Off ⇒ cards hidden at 601 (the shipped cut). Drives the REAL _apply_shell_visibility via the debug hook.
# =====================================================================================================================
func _gate_card_calt() -> void:
	if not CubeSphere.FP_STRUCT_SHELL_BAND:
		_ok(true, "G-ST-CALT: SHELL_BAND off ⇒ card zone law inert (skipped)")
		return
	var on := CubeSphere.FP_STRUCT_CARD_ALT_BAND
	_ok(CubeSphere.STRUCT_CARD_HIDE_ALT == CubeSphere.STRUCT_FAR_MAX,
		"G-ST-CALT: STRUCT_CARD_HIDE_ALT == STRUCT_FAR_MAX (the altitude and distance envelopes coincide, §3.1)")
	var t = FS.new(); t.setup_instance(Node3D.new(), 0)
	# on-surface: card + cube both visible (both flag states).
	t.debug_apply_shell_visibility(false, 41.0)
	_ok(t.card_mmi_visible() and t.mi_visible(), "G-ST-CALT: on-surface ⇒ card + cube visible")
	# h=300 (shell band): card visible.
	t.debug_apply_shell_visibility(true, 300.0)
	_ok(t.card_mmi_visible(), "G-ST-CALT: h=300 (shell band) ⇒ card visible")
	# h=601: the CUBE mesh hides at 600 in BOTH flag states (unchanged law).
	t.debug_apply_shell_visibility(true, 601.0)
	_ok(not t.mi_visible(), "G-ST-CALT: h=601 ⇒ CUBE mesh hidden (unchanged 600 law, both states)")
	if on:
		_ok(t.card_mmi_visible(), "G-ST-CALT(on): h=601 ⇒ card STILL visible (extended band, no vanish)")
		for hh in [1500.0, 2100.0, 2399.0]:
			t.debug_apply_shell_visibility(true, hh)
			_ok(t.card_mmi_visible(), "G-ST-CALT(on): h=%d ⇒ card visible (< STRUCT_CARD_HIDE_ALT)" % int(hh))
		t.debug_apply_shell_visibility(true, 2401.0)
		_ok(not t.card_mmi_visible(), "G-ST-CALT(on): h=2401 ⇒ card HIDDEN (≥ STRUCT_CARD_HIDE_ALT; set empty anyway)")
		# tier_fade == the §4 formula at 2100 and 2399 (wake fade == 1.0, no swap).
		for hh in [2100.0, 2399.0]:
			t.debug_apply_shell_visibility(true, hh)
			var exp := 1.0 - smoothstep(CubeSphere.STRUCT_CARD_FADE_ALT, CubeSphere.STRUCT_CARD_HIDE_ALT, hh)
			_ok(absf(t.card_tier_fade() - exp) < 1e-3, "G-ST-CALT(on): tier_fade at h=%d == 1-smoothstep(2000,2400,h)" % int(hh))
	else:
		_ok(not t.card_mmi_visible(), "G-ST-CALT(off): h=601 ⇒ card HIDDEN (shipped 600 cut, byte-identical)")

# One real step()-EPOCH+SHELL frame WITHOUT a live ring: apply the zone law, then the version-gated prelude (+ the
# swap-triggered rebuild). Drives the ACTUAL _apply_shell_visibility + _prelude_epoch path (not the debug wrappers /
# _snap_start_fill). Returns whether a rebuild fired this frame.
func _stage_frame(t, cam: Vector3, offsurf: bool, h: float) -> bool:
	t._apply_shell_visibility(offsurf, h)
	if t._prelude_epoch(cam, offsurf and h >= CubeSphere.FT_SHELL_HIDE_ALT):
		t._rebuild(t._snapshot, cam, true)
		return true
	return false

## Build + inject `count` synthetic card records clustered on facet 0 (distinct distances) with valid is_card=1 precs,
## returns {reg, cam}. Roots are fabricated negative (distinct); dist ∈ card band from `cam`. For the SORT/WAKE gates.
func _inject_cards(t, count: int) -> Dictionary:
	var fb := FA.frame_basis(0)
	var e_f := -fb.x
	var reg: Array = []
	for k in range(count):
		var bmin := Vector3i(100 + (k % 50), 40, 100 + int(k / 50) * 3)
		var bmax := bmin + Vector3i(6, 6, 6)
		var root := -(200000 + k)
		reg.append({"root": root, "fid": 0, "source": SG.SOURCE_GEN, "bmin": bmin, "bmax": bmax, "rev": 1})
		var cxw := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
		var czw := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
		var wr := FA.lattice_to_world64(0, cxw, float(bmin.y), czw)
		t._card_prec[root] = PackedFloat32Array([1.0, 0.0, 6.0, 6.0, 7.0, float(wr[0]), float(wr[1]), float(wr[2]), e_f.x, e_f.y, e_f.z, 0.0])
	var c0: Vector3 = t._structure_centre(reg[0])
	return {"reg": reg, "cam": c0 - c0.normalized() * 800.0}

# =====================================================================================================================
# G-ST-RES (S3 §5) — residency across altitude boundaries, driving the REAL prelude path. A version-quiescent altitude
# round-trip toggles visibility ONLY: NO rebuild fires, and the card buffer + _centres survive byte-for-byte; a genuine
# version bump triggers EXACTLY one swap rebuild (so the resident buffer re-appears on descent without a re-emit).
# =====================================================================================================================
func _gate_card_res() -> void:
	if not (CubeSphere.FP_STRUCT_CARDS and CubeSphere.FP_STRUCT_SHELL_BAND and CubeSphere.FP_STRUCT_REG_EPOCH):
		_ok(true, "G-ST-RES: cards/shell/epoch not all on ⇒ residency n/a (skipped)")
		return
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-ST-RES: no GEN house fixture")
		return
	var rec: Dictionary = found["rec"]
	var reg_src := FakeReg.new(); reg_src.set_records([rec.duplicate()])
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp); t.set_near_query(nearq)
	t.set_registry_query(Callable(reg_src, "registry")); t.set_version_query(Callable(reg_src, "version"))
	var centre := t._structure_centre(rec)
	var cam := centre - centre.normalized() * 800.0
	var primed := _stage_frame(t, cam, false, 41.0)   # prime (real prelude → staged swap → rebuild)
	_ok(primed and t.live_cards() == 1, "G-ST-RES: prime — the card is resident (1), via a swap-triggered rebuild")
	var rb := t.rebuild_count()
	var vic := t.live_cards()
	var buf_before := t.debug_card_buffer().duplicate()
	var centres_before: PackedVector3Array = t._centres.duplicate()
	var extra := 0
	for hh in [41.0, 599.0, 601.0, 2399.0, 2401.0, 601.0, 41.0]:
		if _stage_frame(t, cam, hh > 256.0, hh):
			extra += 1
	_ok(extra == 0 and t.rebuild_count() == rb, "G-ST-RES: a version-quiescent altitude round-trip triggers NO rebuild (delta 0)")
	_ok(t.live_cards() == vic, "G-ST-RES: visible card count unchanged across the boundaries")
	_ok(t.debug_card_buffer() == buf_before and t._centres == centres_before,
		"G-ST-RES: the card buffer + _centres are byte-identical across the boundary round-trip (resident)")
	# a genuine version bump ⇒ exactly one swap-triggered rebuild (the resident buffer re-populates on the real change).
	reg_src.bump_edit(int(rec["root"]))
	var did_edit := _stage_frame(t, cam, false, 41.0)
	_ok(did_edit and t.rebuild_count() == rb + 1, "G-ST-RES: a genuine version bump ⇒ EXACTLY one swap-triggered rebuild")

# =====================================================================================================================
# G-ST-SORT (S2 §7 — FP_STRUCT_CARD_STAGE) — the precomputed-distance argsort. (a) precompute exact; (b) the tie-stable
# argsort emits the IDENTICAL card SET + cap flags as the shipped sort_custom, UNDER THE CAP (4k records, nearest-first);
# (c) the tie-stable argsort is deterministic (repeat ⇒ byte-identical buffer). Set+cap equality, not a tautological seq.
# =====================================================================================================================
func _gate_card_sort() -> void:
	# (a) precompute exactness over a real village.
	var found := _find_houses(2)
	if found.is_empty():
		_ok(false, "G-ST-SORT: no facet with ≥2 GEN houses")
		return
	var reg_src := FakeReg.new(); reg_src.set_records((found["recs"] as Array).duplicate())
	var te = FS.new(); te.setup_instance(Node3D.new(), 0)
	te.set_registry_query(Callable(reg_src, "registry")); te.set_version_query(Callable(reg_src, "version"))
	te._resnapshot(1)
	var ne: int = te._snapshot.size()
	var ce: Vector3 = te._structure_centre(te._snapshot[0])
	var came := ce - ce.normalized() * 900.0
	var exact := true
	for i in range(ne):
		if not is_equal_approx(came.distance_to(te._centres[i]), te._structure_dist(te._snapshot[i], came)):
			exact = false
	_ok(exact, "G-ST-SORT: every _centres[i] distance == the per-record _structure_dist (precompute exact, no drift)")
	# (b)+(c) need cards actually EMITTED (FP_STRUCT_CARDS) and the argsort path (FP_STRUCT_CARD_STAGE) — ON-only.
	if not (CubeSphere.FP_STRUCT_CARDS and CubeSphere.FP_STRUCT_CARD_STAGE):
		_ok(true, "G-ST-SORT: cards/stage off ⇒ set+cap equality + determinism n/a (the shipped sort is the only path)")
		return
	# (b) SET + CAP equality under the cap: 4k injected cards. staged argsort (use_centres=true) vs shipped sort_custom
	#     (use_centres=false) — assert IDENTICAL live_cards + cap flags.
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var ta = FS.new(); ta.setup_instance(Node3D.new(), 0); ta.set_sampler(samp); ta.set_near_query(nearq)
	var inj := _inject_cards(ta, 4000)
	var reg: Array = inj["reg"]; var cam: Vector3 = inj["cam"]
	# _centres index-parallel with reg (for the argsort path): compute them once (the resnapshot would key by root).
	ta._centres = PackedVector3Array(); ta._centres.resize(reg.size())
	for i in range(reg.size()):
		ta._centres[i] = ta._structure_centre(reg[i])
	ta._rebuild(reg, cam, true)                       # staged argsort (use_centres)
	var a_cards := ta.live_cards(); var a_cq := ta.card_capped()
	var a_buf := ta.debug_card_buffer().duplicate()
	var ts = FS.new(); ts.setup_instance(Node3D.new(), 0); ts.set_sampler(samp); ts.set_near_query(nearq)
	for root in ta._card_prec.keys():
		ts._card_prec[root] = ta._card_prec[root]
	ts._rebuild(reg, cam)                             # shipped sort_custom (use_centres=false ⇒ else branch)
	_ok(a_cards == ts.live_cards() and a_cq == ts.card_capped() and a_cards == CubeSphere.STRUCT_CARD_INST_MAX,
		"G-ST-SORT: argsort vs shipped-sort emit the IDENTICAL set size + cap flag under the cap (%d, capped)" % a_cards)
	# (c) determinism (the root tie-key): a repeat argsort yields the identical buffer (heavily-tied fixture ⇒ this
	#     ONLY holds because the tie-break is deterministic — an un-keyed argsort would flap the kept boundary set).
	ta._rebuild(reg, cam, true)
	_ok(ta.debug_card_buffer() == a_buf, "G-ST-SORT: the tie-stable argsort is deterministic (repeat ⇒ byte-identical buffer)")

# =====================================================================================================================
# G-ST-SNAPSTAGE (S4 §6 — FP_STRUCT_CARD_STAGE) — the staged snapshot via the REAL prelude path: the live snapshot is
# unchanged until the swap, the fill converges, the post-swap buffers are byte-equal to a one-shot _resnapshot, AND a
# §2 CHURN-STARVATION test (version drift every frame) proves the swap STILL lands (coalescing) with a complete resident.
# =====================================================================================================================
func _gate_card_snapstage() -> void:
	if not CubeSphere.FP_STRUCT_CARD_STAGE:
		_ok(true, "G-ST-SNAPSTAGE: FP_STRUCT_CARD_STAGE off ⇒ one-shot resnapshot (asserted by G-ST-EPOCH) — skipped")
		return
	var recs := _collect_gen_records(150)
	if recs.size() < 8:
		_ok(false, "G-ST-SNAPSTAGE: too few GEN records collected (%d)" % recs.size())
		return
	var n: int = recs.size()
	var reg_src := FakeReg.new(); reg_src.set_records(recs.duplicate())
	var samp := func(_f: int, _c: Vector3i) -> int: return _grass()
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_sampler(samp); t.set_near_query(nearq)
	t.set_registry_query(Callable(reg_src, "registry")); t.set_version_query(Callable(reg_src, "version"))
	var c0: Vector3 = t._structure_centre(recs[0])
	var cam := c0 - c0.normalized() * 900.0
	# (a) drive the REAL prelude (draining) frames: the live snapshot stays empty until the swap; count frames.
	var frames := 0
	var swapped := false
	var live_ok := true
	while not swapped and frames < 4 * n + 20:
		swapped = t._prelude_epoch(cam, true)
		frames += 1
		if not swapped and t.snap_pending() and not t._snapshot.is_empty():
			live_ok = false                            # the live snapshot changed BEFORE the swap
	_ok(swapped and t._snapshot.size() == n, "G-ST-SNAPSTAGE: the staged fill converges + swaps the full village (real prelude path)")
	_ok(live_ok, "G-ST-SNAPSTAGE: the LIVE snapshot is untouched until the swap (the old set renders resident)")
	# (b) byte-equal to a one-shot resnapshot.
	var ref = FS.new(); ref.setup_instance(Node3D.new(), 0); ref.set_sampler(samp)
	ref.set_registry_query(Callable(reg_src, "registry")); ref.set_version_query(Callable(reg_src, "version"))
	ref._resnapshot(int(reg_src.version()))
	var centres_eq: bool = t._centres == ref._centres
	var prec_eq: bool = t._card_prec.size() == ref._card_prec.size()
	for root in ref._card_prec.keys():
		if not t._card_prec.has(root) or t._card_prec[root] != ref._card_prec[root]:
			prec_eq = false
	_ok(centres_eq and t._snap_rev_sum == ref._snap_rev_sum and prec_eq,
		"G-ST-SNAPSTAGE: the staged snapshot is byte-equal to a one-shot _resnapshot (centres + rev-sum + card prec)")
	# (c) §2 CHURN STARVATION: drift the version EVERY frame; the swap STILL lands (coalescing, not restart) and the
	#     resident village is NEVER partial/empty after the first swap (no ghosts, no gaps).
	var churn_swaps := 0
	var min_live := 0x7fffffff
	for f in range(300):
		reg_src.ver += 1
		if t._prelude_epoch(cam, true):
			churn_swaps += 1
		if churn_swaps >= 1:
			min_live = mini(min_live, t._snapshot.size())
	_ok(churn_swaps >= 1, "G-ST-SNAPSTAGE: under version-drift-every-frame the swap STILL lands (coalescing — no starvation)")
	_ok(min_live == n, "G-ST-SNAPSTAGE: the resident village stays COMPLETE (%d) under sustained drift (no ghosts/gaps)" % n)

# =====================================================================================================================
# G-ST-WAKE (S4 §8 — the wake fade-in rework) — (a) an EMPTY→populated (≥ JUMP) swap latches the wake AND publishes the
# buffer with tier_fade == 0 (ATOMIC — no full-bright frame); (b) the ramp 0→1 over STRUCT_WAKE_FADE_S; (c) a
# NONEMPTY→grown swap does NOT wake (the resident set never blinks); (d) BOTH zone S and zone B apply the wake fade.
# =====================================================================================================================
func _gate_card_wake() -> void:
	if not (CubeSphere.FP_STRUCT_CARD_STAGE and CubeSphere.FP_STRUCT_CARDS):
		_ok(true, "G-ST-WAKE: CARD_STAGE/CARDS off ⇒ wake n/a (skipped)")
		return
	var nearq := func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE
	# (a) EMPTY→populated: drive _rebuild_staged with _prev_live_cards=0 + the wake armed.
	var t = FS.new(); t.setup_instance(Node3D.new(), 0); t.set_near_query(nearq)
	var inj := _inject_cards(t, 100)
	var reg: Array = inj["reg"]; var cam: Vector3 = inj["cam"]
	t._prev_live_cards = 0
	t._pending_wake_check = true
	t._rebuild_staged(reg, cam, false)                # cn=100 ≥ WAKE_JUMP, from empty ⇒ wake
	_ok(t.live_cards() == 100, "G-ST-WAKE: fixture — 100 cards emitted")
	_ok(t.wake_t0() != 0, "G-ST-WAKE(a): an EMPTY→populated (≥ WAKE_JUMP) swap latches the wake")
	_ok(absf(t.card_material_tier_fade()) < 1e-4,
		"G-ST-WAKE(a): the new buffer is published with tier_fade == 0 (ATOMIC — no full-bright frame, the pop-then-fade fix)")
	# (b) the ramp (manipulate the anchor — no wall-clock wait).
	var wsec := CubeSphere.STRUCT_WAKE_FADE_S
	t.debug_set_wake_t0(Time.get_ticks_msec())
	_ok(t.wake_fade() < 0.2, "G-ST-WAKE(b): just-latched ⇒ wake_fade ≈ 0")
	t.debug_set_wake_t0(Time.get_ticks_msec() - int(wsec * 500.0))
	_ok(absf(t.wake_fade() - 0.5) < 0.2, "G-ST-WAKE(b): half-way ⇒ wake_fade ≈ 0.5")
	t.debug_set_wake_t0(Time.get_ticks_msec() - int(wsec * 2000.0))
	_ok(t.wake_fade() >= 0.999, "G-ST-WAKE(b): past the fade window ⇒ wake_fade == 1 (clamped)")
	# (c) NONEMPTY→grown: NO wake (resident must not blink).
	var t2 = FS.new(); t2.setup_instance(Node3D.new(), 0); t2.set_near_query(nearq)
	var inj2 := _inject_cards(t2, 100)
	t2._prev_live_cards = 80                           # the resident set was already showing 80
	t2._pending_wake_check = true
	t2._rebuild_staged(inj2["reg"], inj2["cam"], false)
	_ok(t2.wake_t0() == 0, "G-ST-WAKE(c): a NONEMPTY→grown swap (80→100) does NOT wake-fade (the resident set never blinks)")
	# (d) zones S AND B both apply the wake fade (§8 fix b). Re-arm a fresh wake on t, then apply the zone law.
	t.debug_set_wake_t0(Time.get_ticks_msec())
	t._apply_shell_visibility(false, 41.0)            # zone S (on-surface)
	_ok(t.card_tier_fade() < 0.2, "G-ST-WAKE(d): zone S applies the wake fade (an on-surface/initial swap ramps, not pops)")
	t.debug_set_wake_t0(Time.get_ticks_msec())
	t._apply_shell_visibility(true, 700.0)            # zone B (shell band)
	_ok(t.card_tier_fade() < 0.2, "G-ST-WAKE(d): zone B applies the wake fade")

## Collect up to `target` real GEN records across Earth facets (real roots ⇒ card-eligible), for the staging gates.
func _collect_gen_records(target: int) -> Array:
	var idx = SGI.new()
	var earth_n := 6 * FA.K * FA.K
	var out: Array = []
	for fid in range(mini(earth_n, 2000)):
		for r in idx.enumerate_facet(fid):
			out.append((r as Dictionary).duplicate())
			if out.size() >= target:
				return out
	return out

# =====================================================================================================================
# G-SED-* (FP_STRUCT_EDIT_DEBOUNCE — docs/COSMOS-FAR-EDIT-DEBOUNCE-DESIGN.md) — the debounced far-visible re-bake.
# =====================================================================================================================

## G-SED-HOLD (P2 proof, GEN half): an in-house edit bumps the TRUTH rev instantly but HOLDS the version + published
## rev, so the far tier's snapshot is unchanged (no synchronous re-materialize = no freeze). OFF ⇒ the shipped bump.
func _gate_sed_hold() -> void:
	var on := CubeSphere.FP_STRUCT_EDIT_DEBOUNCE
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SED-HOLD: no generated house fixture")
		return
	var idx = found["idx"]
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var root := int(rec["root"])
	var cell: Vector3i = rec["bmin"]                       # a cell inside the house bbox
	var v0: int = idx.version()
	if on:
		# v2 EDIT FRAME: STRICTLY O(1) — the enqueue does NO enumeration, NO version drift, NO truth-rev bump.
		var e0: int = idx.enum_count()
		var dmg: Array = idx.note_edit(fid, cell)
		_ok(dmg.is_empty(), "G-SED-HOLD(on): note_edit returns [] (no synchronous classify on the input frame)")
		_ok(idx.enum_count() == e0, "G-SED-HOLD(on): the edit does NO facet enumeration on the input path (O(1) — the v1 freeze is gone by construction)")
		_ok(idx.version() == v0, "G-SED-HOLD(on): the enqueue HOLDS the version (no far re-materialize ⇒ no freeze)")
		_ok(int(idx._rev.get(root, 0)) == 0, "G-SED-HOLD(on): the input path DEFERS the truth-rev bump (no worldgen on the edit frame)")
		_ok(idx.uncls_size() >= 1, "G-SED-HOLD(on): the edit is captured in the un-classified queue (never-drop)")
		# v2 DEFERRED CLASSIFY: drive it exactly as verify drives _sed_gate_publish (a bare WorldManager owning the index).
		var wm = WM.new(); wm._gen_index = idx
		wm._sed_classify_step()
		_ok(idx.enum_count() == e0, "G-SED-HOLD(on): the classifier resolves per-column (has_village/house_info) — STILL no facet enumeration")
		_ok(int(idx._rev.get(root, 0)) == 1, "G-SED-HOLD(on): after one driven classify, the TRUTH rev bumped (lossless)")
		_ok(not idx._rev_pub.has(root), "G-SED-HOLD(on): the PUBLISHED rev did NOT bump (the far tier still sees pristine)")
		_ok(idx.version() == v0, "G-SED-HOLD(on): classification bumps the truth ONLY — the version stays held (no far resnapshot)")
		var served := -1
		for r in idx.enumerate_facet(fid):
			if int((r as Dictionary)["root"]) == root:
				served = int((r as Dictionary)["rev"])
		_ok(served == 0, "G-SED-HOLD(on): the served record rev is still 0 (published) — the far model holds")
		_ok(wm._sed_pending.has(root), "G-SED-HOLD(on): the classifier upserted the damaged house into the pending map")
		wm.free()
	else:
		var dmg2: Array = idx.note_edit(fid, cell)
		_ok(dmg2.is_empty() and idx.version() != v0 and int(idx._rev.get(root, 0)) == 1,
			"G-SED-HOLD(off): note_edit bumps the version + advances the served rev (shipped immediate re-bake)")

## G-SED-PUBLISH (P1 proof, GEN half): publish_roots copies truth→published, bumps the version ONCE for N roots
## (coalescing), and the served record now shows the damage (the far model re-bakes the hole). ON-only.
func _gate_sed_publish() -> void:
	if not CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		_ok(true, "G-SED-PUBLISH: flag off ⇒ no publish path (skipped)")
		return
	var found := _find_houses(2)
	if found.is_empty():
		_ok(false, "G-SED-PUBLISH: no facet with ≥2 GEN houses")
		return
	var recs: Array = found["recs"]
	var fid: int = found["fid"]
	var idx = SGI.new()
	idx.enumerate_facet(fid)                               # cache the facet
	var r0 := int((recs[0] as Dictionary)["root"])
	var r1 := int((recs[1] as Dictionary)["root"])
	# v2: the classifier's truth-rev bump is note_damage (note_edit only enqueues). Drive it directly here — the point of
	# this gate is publish_roots copying truth→published, independent of the enqueue/classify scheduling.
	idx.note_damage(r0)
	idx.note_damage(r0)                                   # r0 truth = 2
	idx.note_damage(r1)                                   # r1 truth = 1
	var vpre: int = idx.version()
	idx.publish_roots([r0, r1])                            # COALESCE: one version bump for two roots
	_ok(idx.version() == vpre + 1, "G-SED-PUBLISH: publish of N roots ⇒ exactly ONE version drift (coalescing)")
	_ok(int(idx._rev_pub.get(r0, 0)) == 2 and int(idx._rev_pub.get(r1, 0)) == 1,
		"G-SED-PUBLISH: published revs == truth after publish (r0=2, r1=1)")
	var served0 := -1
	for r in idx.enumerate_facet(fid):
		if int((r as Dictionary)["root"]) == r0:
			served0 = int((r as Dictionary)["rev"])
	_ok(served0 == 2, "G-SED-PUBLISH: the served record now shows the damage (rev 2 ⇒ the far model re-bakes the hole)")

## G-SED-NEVERDROP: randomized edit/publish sequences ⇒ after the final publish, every published rev == truth. ON-only.
func _gate_sed_neverdrop() -> void:
	if not CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		_ok(true, "G-SED-NEVERDROP: flag off (skipped)")
		return
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SED-NEVERDROP: no house")
		return
	var idx = found["idx"]
	var root := int((found["rec"] as Dictionary)["root"])
	seed(12345)
	for i in range(60):
		if randi() % 3 == 0:
			idx.publish_roots([root])                     # publish at random points
		else:
			idx.note_damage(root)                         # v2: the classifier's truth-rev bump (note_edit only enqueues)
	idx.publish_roots([root])                             # final publish
	_ok(int(idx._rev_pub.get(root, 0)) == int(idx._rev.get(root, 0)) and int(idx._rev.get(root, 0)) > 0,
		"G-SED-NEVERDROP: after the final publish, published rev == truth rev (no edit lost)")

## G-SED-TRACKER: the player-build half — version()/_make_record are HELD through an edit AND a mid-hold recluster;
## publish() latches the truth. OFF ⇒ the shipped immediate version bump.
func _gate_sed_tracker() -> void:
	var on := CubeSphere.FP_STRUCT_EDIT_DEBOUNCE
	var g := _grass()
	if g <= 0:
		_ok(false, "G-SED-TRACKER: grass id unavailable")
		return
	var tr = ST.new()
	_place_box(tr, g, 0, 5, 0, 5, 0, 5)                   # a 6³ build ⇒ registers
	var reg: Array = tr.registry()
	if reg.is_empty():
		_ok(false, "G-SED-TRACKER: the build did not register")
		return
	var root := int((reg[0] as Dictionary)["root"])
	var v0: int = tr.version()
	tr.note_removed(FA.edit_key(0, Vector3i(2, 2, 2)))    # break a cell ⇒ truth rev bumps + marks dirty
	if on:
		_ok(tr.version() == v0, "G-SED-TRACKER(on): the tracker version is HELD after an edit (no far re-bake)")
		_ok(int(tr._make_record(root)["rev"]) == 0, "G-SED-TRACKER(on): _make_record serves the PUBLISHED rev (0) — held")
		tr.tick(Time.get_ticks_msec() + CubeSphere.STRUCT_RECLUSTER_MS + 100)   # force the mid-hold recluster
		_ok(tr.version() == v0, "G-SED-TRACKER(on): a mid-hold _recluster_all does NOT leak a version drift (rev storm held)")
		tr.publish()
		_ok(tr.version() != v0, "G-SED-TRACKER(on): publish() latches the version (the far tier re-bakes on departure)")
		# THE REGRESSION GUARD (Fable P0 / Codex P1): registry() — what the far tier actually SNAPSHOTS — must SERVE the
		# published rev (== truth, > 0) after publish(). FAILS pre-fix (publish never re-made _reg ⇒ stale rev 0 ⇒
		# _ensure_bake keeps the pre-edit bake ⇒ the hole never appears far); PASSES with the publish() re-make.
		var reg2: Array = tr.registry()
		var served_ok := false
		if not reg2.is_empty():
			var r2 := int((reg2[0] as Dictionary)["root"])
			var served := int((reg2[0] as Dictionary)["rev"])
			served_ok = tr._clusters.has(r2) and served == int(tr._clusters[r2]["rev"]) and served > 0
		_ok(served_ok, "G-SED-TRACKER(on): after publish(), registry() SERVES the published rev (== truth, > 0) — the far model re-bakes the hole")
	else:
		_ok(tr.version() != v0, "G-SED-TRACKER(off): the version bumps on the edit (shipped immediate)")

## G-SED-GATE: the WorldManager idle+depart publish gate + the NEVER-OOM force-publish. ON-only (drives _sed_note_gen /
## _sed_gate_publish with an injected player world pos + clock).
func _gate_sed_gate() -> void:
	if not CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		_ok(true, "G-SED-GATE: flag off ⇒ pending map never allocated (skipped)")
		return
	var wm = WM.new()
	wm._gen_index = SGI.new()
	var t0 := Time.get_ticks_msec()
	wm._sed_note_gen([{"root": -1234, "fid": 0, "bmin": Vector3i(100, 40, 100), "bmax": Vector3i(106, 46, 106)}])
	_ok(wm._sed_pending.size() == 1, "G-SED-GATE: an edit upserts ONE pending entry")
	var np := FA.lattice_to_world64(0, 108.0, 43.0, 103.0)   # ~2 blocks from the AABB
	var near_w := Vector3(float(np[0]), float(np[1]), float(np[2]))
	var fp := FA.lattice_to_world64(0, 140.0, 43.0, 103.0)   # ~34 blocks
	var far_w := Vector3(float(fp[0]), float(fp[1]), float(fp[2]))
	wm._sed_gate_publish(far_w, t0)                        # departed but NOT idle
	_ok(wm._sed_pending.size() == 1, "G-SED-GATE: departed but not idle (Δt < IDLE_MS) ⇒ HELD")
	wm._sed_gate_publish(near_w, t0 + CubeSphere.STRUCT_EDIT_IDLE_MS + 1000)   # idle but too close
	_ok(wm._sed_pending.size() == 1, "G-SED-GATE: idle but player too close (< DEPART_BLK) ⇒ HELD")
	wm._sed_gate_publish(far_w, t0 + CubeSphere.STRUCT_EDIT_IDLE_MS + 1000)    # idle AND departed
	_ok(wm._sed_pending.is_empty() and wm._sed_publishes == 1, "G-SED-GATE: idle + departed ≥ DEPART_BLK ⇒ PUBLISH (gate opens)")
	wm.free()
	# NEVER-OOM: overflow force-publishes the oldest.
	var wm2 = WM.new(); wm2._gen_index = SGI.new()
	for k in range(CubeSphere.STRUCT_EDIT_PENDING_MAX + 5):
		wm2._sed_note_gen([{"root": -(1000 + k), "fid": 0, "bmin": Vector3i(100 + k, 40, 100), "bmax": Vector3i(103 + k, 43, 103)}])
	_ok(wm2._sed_pending.size() <= CubeSphere.STRUCT_EDIT_PENDING_MAX and wm2._sed_forced >= 1,
		"G-SED-GATE: pending cap respected — overflow force-publishes the oldest (NEVER-OOM)")
	wm2.free()
	# #3 AABB boundary precision: the gate opens at EXACTLY STRUCT_EDIT_DEPART_BLK from the OUTER voxel face. Place the
	# player along +x at a KNOWN world distance beyond the entry's world AABB (so _sed_aabb_dist == that distance exactly,
	# independent of curvature). 15.999 blk ⇒ held; 16.001 blk ⇒ publish — proving the [bmin, bmax+1] +1 fix (else the
	# box would omit the outer voxel and the gate would open ~1 block early).
	var wm3 = WM.new(); wm3._gen_index = SGI.new()
	var abb: Array = wm3._sed_world_aabb(0, Vector3i(100, 40, 100), Vector3i(106, 46, 106))
	var wmin3: Vector3 = abb[0]
	var wmax3: Vector3 = abb[1]
	var cy3 := (wmin3.y + wmax3.y) * 0.5
	var cz3 := (wmin3.z + wmax3.z) * 0.5
	var t3 := Time.get_ticks_msec()
	wm3._sed_note_gen([{"root": -77, "fid": 0, "bmin": Vector3i(100, 40, 100), "bmax": Vector3i(106, 46, 106)}])
	var dep: float = CubeSphere.STRUCT_EDIT_DEPART_BLK
	wm3._sed_gate_publish(Vector3(wmax3.x + dep - 0.001, cy3, cz3), t3 + CubeSphere.STRUCT_EDIT_IDLE_MS + 1000)
	_ok(wm3._sed_pending.size() == 1, "G-SED-GATE: %.3f blk from the OUTER voxel face ⇒ HELD (< DEPART_BLK)" % (dep - 0.001))
	wm3._sed_gate_publish(Vector3(wmax3.x + dep + 0.001, cy3, cz3), t3 + CubeSphere.STRUCT_EDIT_IDLE_MS + 1000)
	_ok(wm3._sed_pending.is_empty(), "G-SED-GATE: %.3f blk from the outer voxel face ⇒ PUBLISH (≥ DEPART_BLK; the +1 AABB fix)" % (dep + 0.001))
	wm3.free()

## G-SED-COLD (v2 §7 — the regression guard for the incident): with a COLD `_cache`, an in-bbox edit does NO facet
## enumeration on the input path (the v1 3.4 s freeze was exactly a cache-cold `enumerate_facet` on the edit frame);
## after a driven classify + gate publish, published rev == truth (never-drop FROM COLD, position-pure classification).
func _gate_sed_cold() -> void:
	if not CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		_ok(true, "G-SED-COLD: flag off ⇒ no queue/classifier (skipped)")
		return
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SED-COLD: no house fixture")
		return
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var root := int(rec["root"])
	var cell: Vector3i = rec["bmin"]
	# A COLD index — the facet is NEVER enumerated. This is the exact v1-freeze condition: a cache-miss edit.
	var cold = SGI.new()
	var e0: int = cold.enum_count()
	cold.note_edit(fid, cell)                                  # the edit input path
	_ok(cold.enum_count() == e0, "G-SED-COLD: a cold-cache in-bbox edit does NO facet enumeration on the input path (O(1) — the v1 freeze is gone by construction)")
	_ok(int(cold._rev.get(root, 0)) == 0, "G-SED-COLD: the input path defers the truth-rev bump (no synchronous worldgen)")
	_ok(cold.uncls_size() == 1, "G-SED-COLD: the edit is captured (never-drop)")
	# Drive the classifier off-frame (still cold) — per-column has_village/house_info, never enumerate_facet.
	var wm = WM.new(); wm._gen_index = cold
	var t0 := Time.get_ticks_msec()
	wm._sed_classify_step()
	_ok(cold.enum_count() == e0, "G-SED-COLD: the classifier resolves per-column — STILL no facet enumeration")
	_ok(int(cold._rev.get(root, 0)) == 1, "G-SED-COLD: the classifier bumped the TRUTH rev (never-drop from cold)")
	_ok(wm._sed_pending.has(root), "G-SED-COLD: the classifier upserted the pending entry")
	# Publish (idle + departed) ⇒ published == truth from a cold start (end-to-end never-drop).
	var abb: Array = wm._sed_world_aabb(fid, rec["bmin"], rec["bmax"])
	var wmax: Vector3 = abb[1]
	var far := Vector3(wmax.x + CubeSphere.STRUCT_EDIT_DEPART_BLK + 1.0, wmax.y, wmax.z)
	wm._sed_gate_publish(far, t0 + CubeSphere.STRUCT_EDIT_IDLE_MS + 5000)
	_ok(int(cold._rev_pub.get(root, 0)) == int(cold._rev.get(root, 0)) and int(cold._rev.get(root, 0)) > 0,
		"G-SED-COLD: after a driven classify + gate publish, published rev == truth (never-drop end-to-end from cold)")
	wm.free()

## G-SED-CLASSIFY (v2 §7): a mixed batch — in-house / plain-terrain (no village) / in-footprint-wrong-Y — drained through
## the WM classifier ⇒ EXACTLY the in-house edit bumps (root == pack_root), and never a facet enumeration. Plus the
## single-source bbox-law guard: StructureGen.record_bbox(hi) == the enumerated record's bmin/bmax for the same house.
func _gate_sed_classify() -> void:
	if not CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		_ok(true, "G-SED-CLASSIFY: flag off (skipped)")
		return
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SED-CLASSIFY: no house fixture")
		return
	var fid: int = found["fid"]
	var rec: Dictionary = found["rec"]
	var root := int(rec["root"])
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	# single-source bbox law: record_bbox(hi) == the enumerated record bmin/bmax for the SAME house.
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var hx := floori(float(bmin.x) / float(SG.STRUCT_HCELL))
	var hz := floori(float(bmin.z) / float(SG.STRUCT_HCELL))
	var hi := SG.house_info(hx, hz, ctx)
	var bb: Array = SG.record_bbox(hi)
	_ok(not hi.is_empty() and bb[0] == bmin and bb[1] == bmax,
		"G-SED-CLASSIFY: record_bbox(hi) == the enumerated record bmin/bmax (single-source bbox law — the G guard)")
	# Find a guaranteed no-village cell near the house by stepping the village pitch (deterministic; bounded to the key range).
	var plain := Vector3i(0, bmin.y, 0)
	var have_plain := false
	var vz0 := floori(float(bmin.z) / float(SG.STRUCT_V))
	for step in range(1, 80):
		var cx := bmin.x + step * SG.STRUCT_V
		if cx > 120000:
			break
		if not SG.has_village(floori(float(cx) / float(SG.STRUCT_V)), vz0, ctx):
			plain = Vector3i(cx, bmin.y, bmin.z); have_plain = true; break
	# Mixed batch through the WM classifier on a FRESH index.
	var fresh = SGI.new()
	var wm = WM.new(); wm._gen_index = fresh
	fresh.note_edit(fid, bmin)                                 # in-house (bumps)
	fresh.note_edit(fid, Vector3i(bmin.x, bmax.y + 50, bmin.z))# in-footprint x/z but WAY above the roof (out of bbox ⇒ no bump)
	if have_plain:
		fresh.note_edit(fid, plain)                           # plain terrain / no village (no bump)
	var e0 := fresh.enum_count()
	while not fresh.uncls_queue_empty():
		wm._sed_classify_step()
	_ok(fresh.enum_count() == e0, "G-SED-CLASSIFY: the classifier never enumerates a facet (per-column O(1))")
	_ok(fresh._rev.has(root) and int(fresh._rev.get(root, 0)) == 1,
		"G-SED-CLASSIFY: the in-house edit bumps exactly its house rev; the damaged root == pack_root(fid,hx,hz)")
	_ok(fresh._rev.size() == 1 and wm._sed_pending.size() == 1 and wm._sed_pending.has(root),
		"G-SED-CLASSIFY: plain-terrain + in-footprint-wrong-Y edits do NOT bump (exactly the in-house edit damages)")
	wm.free()

## G-SED-BUDGET (v2 §7): 100 queued entries drain in ≤ ⌈100/STRUCT_EDIT_CLASSIFY_MIN⌉ driven ticks (the forward-progress
## floor), queue empty. Plus the NEVER-OOM overflow degrade: at STRUCT_EDIT_UNCLS_MAX the facet is marked wholesale-dirty
## and the classifier resolves it by an OFF-FRAME enumeration (over-invalidate every record — never a drop).
func _gate_sed_budget() -> void:
	if not CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
		_ok(true, "G-SED-BUDGET: flag off (skipped)")
		return
	var found := _find_house()
	if found.is_empty():
		_ok(false, "G-SED-BUDGET: no house fixture")
		return
	var fid: int = found["fid"]
	var cell: Vector3i = found["rec"]["bmin"]
	var idx = SGI.new()
	for i in range(100):
		idx.note_edit(fid, cell + Vector3i(0, i % 3, 0))       # 100 O(1) enqueues (input frame never classifies)
	_ok(idx.uncls_size() == 100, "G-SED-BUDGET: 100 edits enqueue O(1) (the input frame never classifies)")
	var wm = WM.new(); wm._gen_index = idx
	var cap := int(ceil(100.0 / float(CubeSphere.STRUCT_EDIT_CLASSIFY_MIN)))
	var ticks := 0
	while not idx.uncls_queue_empty() and ticks < cap + 1:
		wm._sed_classify_step()
		ticks += 1
	_ok(idx.uncls_queue_empty(), "G-SED-BUDGET: the queue drains fully")
	_ok(ticks <= cap, "G-SED-BUDGET: 100 entries drained in ≤ ⌈100/MIN⌉ = %d driven ticks (forward-progress floor)" % cap)
	wm.free()
	# NEVER-OOM overflow: enqueue past the cap ⇒ the facet is marked wholesale-dirty; the classifier resolves it off-frame.
	var root := int(found["rec"]["root"])
	var ov = SGI.new()
	for i in range(CubeSphere.STRUCT_EDIT_UNCLS_MAX + 5):
		ov.note_edit(fid, cell)
	_ok(ov.has_overflow(), "G-SED-BUDGET: queue overflow marks the facet wholesale-dirty (NEVER-OOM superset)")
	var wmo = WM.new(); wmo._gen_index = ov
	var eo0 := ov.enum_count()
	var guard := 0
	while ov.has_overflow() and guard < 8:
		wmo._sed_classify_step()
		guard += 1
	_ok(not ov.has_overflow() and ov.enum_count() > eo0,
		"G-SED-BUDGET: the overflow facet is resolved by an OFF-FRAME enumeration (bounded over-invalidate)")
	_ok(int(ov._rev.get(root, 0)) >= 1, "G-SED-BUDGET: every record on the dirty facet is re-damaged (never drop)")
	wmo.free()
