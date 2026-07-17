extends SceneTree
## COSMOS ORBITAL O4a/O4b — the multi-body suite (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §3.4, §3.6).
##
## G-O4-EQ (the keystone) proves the fid-namespace refactor + the Moon's arrival leave EARTH
## byte-identical. The golden pins below were captured by the throwaway dump version of this file on
## the PRE-refactor tree (single-body atlas, facet_count 3456). They are asserted over EARTH's fid
## range [0, 3456) in BOTH MULTI_BODY states — Earth's rows sit at fid_base 0 and are built by the
## same math with the same values, so appending the Moon cannot move them. If a hash differs, the
## build-math threading perturbed Earth: that is a hard FAIL to be FIXED, never re-pinned.
##
## The remaining gates are O4b: ATLAS2 (Moon frames/classifier/seams), KEY (edit_key bijection over
## the FULL Earth+Moon namespace), OFF (flag-off identity). Moon gates self-skip when MULTI_BODY is
## false (the shipped default) — the suite is green in both states.
##
## Requires NO world flags — it warms TerrainConfig + FacetAtlas directly and samples the pure worldgen.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

# --- GOLDEN PINS (pre-refactor capture; see header) ---
const GOLDEN_ATLAS_MD5 := "bb5ddf6455e2f3e341b577c65fb1fd0d"
const GOLDEN_WORLDGEN_MD5 := "9e0dd84924b2bdf34e3b9e252c80af24"
const GOLDEN_EARTH_FACETS := 3456
const GOLDEN_SPAWN_FID := 2
# pre-refactor packed-array element counts (memory identity: 616 B/fid ⇒ no new bytes for Earth)
const GOLDEN_FRAME := 41472       # 3456 · 12
const GOLDEN_OFF := 6912          # 3456 · 2
const GOLDEN_POLY := 27648        # 3456 · 8
const GOLDEN_DOM := 13824         # 3456 · 4
const GOLDEN_SEAM_PLANE := 55296  # 3456 · 16
# O4b Moon expectations (§3.1): k=14 ⇒ 6·14² facets appended at fid_base 3456, r=1737
const MOON_FACETS := 1176
const MOON_BASE := 3456
const MOON_K := 14
const MOON_R := 1737.0

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## MD5 over the raw bytes of every packed atlas table for the fid range [lo, hi) + the spawn fid.
## Slicing by fid RANGE is what lets the EARTH pin hold verbatim once the Moon is appended after it.
func _atlas_hash(lo: int, hi: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(FA._frame.slice(lo * 12, hi * 12).to_byte_array())
	ctx.update(FA._off.slice(lo * 2, hi * 2).to_byte_array())
	ctx.update(FA._poly.slice(lo * 8, hi * 8).to_byte_array())
	ctx.update(FA._dom.slice(lo * 4, hi * 4).to_byte_array())
	ctx.update(FA._seam_plane.slice(lo * 16, hi * 16).to_byte_array())
	ctx.update(FA._seam_neigh.slice(lo * 4, hi * 4).to_byte_array())
	ctx.update(FA._seam_ring.slice(lo * 24, hi * 24).to_byte_array())
	ctx.update(FA._seam_mhat.slice(lo * 12, hi * 12).to_byte_array())
	ctx.update(PackedInt32Array([FA._spawn_fid]).to_byte_array())
	return ctx.finish().hex_encode()

func _worldgen_digest(ne: int) -> String:
	# 1000 deterministic facet_profile samples (full Vector4) + 200 resolve_cell columns through the choke point.
	var pf := PackedFloat64Array()
	for i in range(1000):
		var fid := (i * 2647) % ne
		var cc: Vector2i = FA.centre_cell(fid)
		var x := cc.x + ((i * 131) % 321) - 160
		var z := cc.y + ((i * 197) % 321) - 160
		var p: Vector4 = TC.facet_profile(fid, x, z)
		pf.push_back(p.x); pf.push_back(p.y); pf.push_back(p.z); pf.push_back(p.w)
	var rc := PackedInt32Array()
	for i in range(200):
		var fid := (i * 617) % ne
		var cc: Vector2i = FA.centre_cell(fid)
		var x := cc.x + ((i * 53) % 201) - 100
		var z := cc.y + ((i * 91) % 201) - 100
		var p: Vector4 = TC.facet_profile(fid, x, z)
		var g := int(p.x); var biome := int(p.y); var c := p.z; var t := p.w
		for y in range(g - 6, g + 3):
			rc.push_back(TC.resolve_cell(x, y, z, g, biome, c, t))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(pf.to_byte_array())
	ctx.update(rc.to_byte_array())
	return ctx.finish().hex_encode()

func _initialize() -> void:
	var multi: bool = CubeSphere.MULTI_BODY
	print("=== verify_multibody (O4a/O4b — MULTI_BODY=%s) ===" % multi)
	TC.warm_up()
	FA.warm_up()

	_gate_eq()
	_gate_off(multi)
	_gate_atlas2(multi)
	_gate_key()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------------------------------------------------------------------------------
# G-O4-EQ — THE KEYSTONE: Earth is bit-for-bit what it was before the namespace/Moon existed.
# ---------------------------------------------------------------------------------------
func _gate_eq() -> void:
	print("[G-O4-EQ] Earth byte-identity (asserted in BOTH MULTI_BODY states)")
	var ne: int = FA.body_facet_count("earth")
	_ok(ne == GOLDEN_EARTH_FACETS, "Earth facet count == %d" % GOLDEN_EARTH_FACETS)
	_ok(FA.fid_base("earth") == 0, "fid_base(earth) == 0 (Earth's rows never move)")
	_ok(FA.body_slot("earth") == 0, "body_slot(earth) == 0")
	_ok(FA.r_of(FA.fid_base("earth")) == 3072.0, "r_of(earth base) == 3072.0 (SHIPPED radius; NOT the O3 6371)")
	_ok(FA.r_of(FA.fid_base("earth")) == FA.R_BLOCKS, "r_of(earth) == FacetAtlas.R_BLOCKS")
	_ok(FA.k_of(FA.fid_base("earth")) == FA.K, "k_of(earth) == FacetAtlas.K (24)")
	# hold over the WHOLE Earth range: k_of ≡ 24, r_of ≡ 3072, body_of_fid ≡ 0
	var bad_k := 0; var bad_r := 0; var bad_body := 0
	for fid in range(ne):
		if FA.k_of(fid) != 24: bad_k += 1
		if FA.r_of(fid) != 3072.0: bad_r += 1
		if FA.body_of_fid(fid) != 0: bad_body += 1
	_ok(bad_k == 0, "k_of(fid) == 24 over all %d Earth fids (%d bad)" % [ne, bad_k])
	_ok(bad_r == 0, "r_of(fid) == 3072.0 over all %d Earth fids (%d bad)" % [ne, bad_r])
	_ok(bad_body == 0, "body_of_fid(fid) == 0 (Earth) over all %d Earth fids (%d bad)" % [ne, bad_body])
	_ok(FA._spawn_fid == GOLDEN_SPAWN_FID, "spawn_fid == %d (== pre-refactor; spawn stays Earth-only)" % GOLDEN_SPAWN_FID)

	# THE pins: atlas byte-hash + worldgen sample digest over EARTH's fid range.
	var ah := _atlas_hash(0, ne)
	print("  atlas MD5    = %s" % ah)
	_ok(ah == GOLDEN_ATLAS_MD5, "atlas byte-hash over Earth's range == golden pin (Earth atlas bit-for-bit unchanged)")
	var wh := _worldgen_digest(ne)
	print("  worldgen MD5 = %s" % wh)
	_ok(wh == GOLDEN_WORLDGEN_MD5, "worldgen digest over Earth's range == golden pin (facet_profile + resolve_cell unchanged)")

	# the classifier still round-trips every Earth facet centre (K=24 grid, base 0)
	var dir_bad := 0
	for fid in range(ne):
		var cc: Vector2i = FA.centre_cell(fid)
		var d: CubeSphere.DVec3 = FA.cell_dir(fid, cc.x, cc.y)
		if int(FA.facet_of_dir("earth", d)) != fid:
			dir_bad += 1
	_ok(dir_bad == 0, "facet_of_dir(\"earth\", cell_dir(centre)) == fid over all %d Earth facets (%d bad)" % [ne, dir_bad])
	# Earth's seam graph stays closed WITHIN Earth's range (a Moon fid can never leak in)
	var seam_bad := 0
	for fid in range(ne):
		for slot in range(4):
			var nb: int = FA.seam_neighbour(fid, slot)
			if nb < 0 or nb >= ne:
				seam_bad += 1
	_ok(seam_bad == 0, "Earth seam neighbours all stay inside Earth's fid range (%d escaped)" % seam_bad)

# ---------------------------------------------------------------------------------------
# G-O4-OFF — MULTI_BODY=false ⇒ no Moon rows: facet_count and every table size identical to O4a.
# ---------------------------------------------------------------------------------------
func _gate_off(multi: bool) -> void:
	if multi:
		print("[G-O4-OFF] skipped (MULTI_BODY=true run — see the flag-off run for this gate)")
		return
	print("[G-O4-OFF] flag-off identity (this is the SHIPPING configuration)")
	_ok(FA.body_count() == 1, "body_count() == 1 (Earth only, no Moon rows built)")
	_ok(FA.facet_count() == GOLDEN_EARTH_FACETS, "facet_count() == %d (Moon absent)" % GOLDEN_EARTH_FACETS)
	_ok(FA._frame.size() == GOLDEN_FRAME, "_frame size == %d" % GOLDEN_FRAME)
	_ok(FA._off.size() == GOLDEN_OFF, "_off size == %d" % GOLDEN_OFF)
	_ok(FA._poly.size() == GOLDEN_POLY, "_poly size == %d" % GOLDEN_POLY)
	_ok(FA._dom.size() == GOLDEN_DOM, "_dom size == %d" % GOLDEN_DOM)
	_ok(FA._seam_plane.size() == GOLDEN_SEAM_PLANE, "_seam_plane size == %d" % GOLDEN_SEAM_PLANE)
	# the registry still DECLARES the Moon (it is a data row); it is simply NOT BUILT.
	_ok(FA.BODY_TABLE.size() == 2, "BODY_TABLE declares Earth+Moon (append-only registry, fact 5)")
	_ok(int(FA.BODY_TABLE[1]["k"]) == MOON_K and float(FA.BODY_TABLE[1]["r"]) == MOON_R,
		"Moon registry row is k=%d r=%s" % [MOON_K, MOON_R])
	# risk #3: Earth's fold table is warm before warm_up returned, even with no Moon
	_ok(CubeSphere.edge_tables_warm(FA.K), "fold/edge table warmed for Earth k=%d before warm_up returned" % FA.K)

# ---------------------------------------------------------------------------------------
# G-O4-ATLAS2 — the Moon's 1176 facets are REAL geometry: frames pass the same thresholds Earth's do
# (verify_faceted G-F1e), the classifier round-trips, and the seam graph closes inside Moon's range.
# ---------------------------------------------------------------------------------------
func _gate_atlas2(multi: bool) -> void:
	if not multi:
		print("[G-O4-ATLAS2] skipped (MULTI_BODY=false — no Moon rows built)")
		return
	print("[G-O4-ATLAS2] Moon faceted geometry")
	var base: int = FA.fid_base("moon")
	var nm: int = FA.body_facet_count("moon")
	_ok(base == MOON_BASE, "fid_base(moon) == %d (== 6·24², appended after Earth)" % MOON_BASE)
	_ok(nm == MOON_FACETS, "moon facet count == 6·14² == %d" % MOON_FACETS)
	_ok(FA.facet_count() == GOLDEN_EARTH_FACETS + MOON_FACETS, "facet_count() == 3456+1176 == 4632")
	_ok(CubeSphere.edge_tables_warm(MOON_K), "fold/edge table warmed for Moon k=%d before warm_up returned (risk #3)" % MOON_K)
	_ok(CubeSphere.edge_tables_warm(FA.K), "fold/edge table for Earth k=%d STILL warm after the Moon warmed (append, not evict)" % FA.K)
	# per-fid accessors resolve to the MOON's registry row across its whole range
	var bad := 0
	for fid in range(base, base + nm):
		if FA.body_of_fid(fid) != 1 or FA.k_of(fid) != MOON_K or FA.r_of(fid) != MOON_R:
			bad += 1
	_ok(bad == 0, "body_of_fid/k_of/r_of == (1, %d, %s) over all %d Moon fids (%d bad)" % [MOON_K, MOON_R, nm, bad])

	# --- the Earth frame gate (verify_faceted G-F1e), re-run over the Moon's fid range ---
	var worst_ortho := 0.0
	var worst_rt := 0.0
	var worst_dev_ratio := 0.0
	var min_ndc := 1.0
	var bad_det := 0
	var min_edge := 1.0e18
	var max_edge := 0.0
	var cos1 := cos(deg_to_rad(1.0))
	for fid in range(base, base + nm):
		var m: Dictionary = FA.verify_frame(fid)
		worst_ortho = maxf(worst_ortho, m["ortho"])
		worst_rt = maxf(worst_rt, m["roundtrip"])
		min_ndc = minf(min_ndc, m["n_dot_centre"])
		if absf(float(m["det"]) - 1.0) > 1e-6:
			bad_det += 1
		var edge: float = m["edge"]
		if edge > 0.0:
			worst_dev_ratio = maxf(worst_dev_ratio, float(m["plane_dev"]) / edge)
			min_edge = minf(min_edge, edge); max_edge = maxf(max_edge, edge)
	_ok(worst_ortho < 1e-9, "moon frames orthonormal (worst Gram residual %s < 1e-9)" % worst_ortho)
	_ok(bad_det == 0, "every moon basis right-handed det=+1 (%d facets off)" % bad_det)
	_ok(min_ndc >= cos1, "moon n̂ outward within 1° (min n̂·centre = %.6f ≥ cos1°=%.6f)" % [min_ndc, cos1])
	_ok(worst_dev_ratio < 0.02, "moon facets near-planar (worst plane-dev/edge = %.4f < 0.02)" % worst_dev_ratio)
	_ok(worst_rt < 1e-3, "moon W_fid round-trips (worst |T⁻¹∘W − id| = %s < 1e-3)" % worst_rt)
	print("  moon facet edge: %.1f … %.1f blocks (Earth ≈ 200)" % [min_edge, max_edge])

	# --- classifier round-trip over every Moon facet centre (k=14 grid, base 3456) ---
	var dir_bad := 0
	for fid in range(base, base + nm):
		var cc: Vector2i = FA.centre_cell(fid)
		var d: CubeSphere.DVec3 = FA.cell_dir(fid, cc.x, cc.y)
		if int(FA.facet_of_dir("moon", d)) != fid:
			dir_bad += 1
	_ok(dir_bad == 0, "facet_of_dir(\"moon\", cell_dir(centre)) == fid over all %d Moon facets (%d bad)" % [nm, dir_bad])
	# ...and an EARTH direction must never classify into the Moon's range (the namespaces are disjoint)
	var cross := 0
	for fid in range(0, GOLDEN_EARTH_FACETS, 17):
		var cc2: Vector2i = FA.centre_cell(fid)
		var d2: CubeSphere.DVec3 = FA.cell_dir(fid, cc2.x, cc2.y)
		if int(FA.facet_of_dir("earth", d2)) >= MOON_BASE:
			cross += 1
	_ok(cross == 0, "facet_of_dir(\"earth\", …) never returns a Moon fid (%d crossed)" % cross)

	# --- seam closure: every Moon neighbour is a MOON fid, and the relation is symmetric ---
	var out_of_range := 0
	var not_mutual := 0
	for fid in range(base, base + nm):
		for slot in range(4):
			var nb: int = FA.seam_neighbour(fid, slot)
			if nb < base or nb >= base + nm:
				out_of_range += 1
				continue
			var mutual := false
			for s2 in range(4):
				if int(FA.seam_neighbour(nb, s2)) == fid:
					mutual = true
			if not mutual:
				not_mutual += 1
	_ok(out_of_range == 0, "moon seam neighbours never leave the Moon's fid range (%d escaped — a body-crossing seam)" % out_of_range)
	_ok(not_mutual == 0, "moon seam graph symmetric: every neighbour names this facet back (%d one-way)" % not_mutual)

# ---------------------------------------------------------------------------------------
# G-O4-KEY — edit_key/unpack bijection over the FULL Earth+Moon namespace + int64 headroom (§3.1 fact 4).
# ---------------------------------------------------------------------------------------
func _gate_key() -> void:
	print("[G-O4-KEY] edit_key bijection over the full registered fid range")
	var nf: int = FA.facet_count()
	var cells := [Vector3i(-131072, -512, -131072), Vector3i(0, 0, 0), Vector3i(131071, 1535, 131071), Vector3i(37, 12, -900)]
	var key_bad := 0
	for fid in range(0, nf, 7):
		for cell in cells:
			var k: int = FA.edit_key(fid, cell)
			var u: Array = FA.edit_key_unpack(k)
			if int(u[0]) != fid or Vector3i(u[1]) != cell or FA.edit_key_fid(k) != fid or k < 0:
				key_bad += 1
	_ok(key_bad == 0, "edit_key pack/unpack bijection over sampled fid×cell range, ALL bodies (%d bad)" % key_bad)
	# the LAST registered fid must still pack positive and unpack exactly — the int64 headroom claim.
	# Asserted at the FULL registry (not just the built bodies) so the contract covers MULTI_BODY=true.
	var last: int = FA.fid_base_slot(FA.BODY_TABLE.size() - 1) + 6 * int(FA.BODY_TABLE[FA.BODY_TABLE.size() - 1]["k"]) * int(FA.BODY_TABLE[FA.BODY_TABLE.size() - 1]["k"]) - 1
	var extreme := Vector3i(131071, 1535, 131071)
	var mk: int = FA.edit_key(last, extreme)
	var mu: Array = FA.edit_key_unpack(mk)
	_ok(mk > 0, "max REGISTERED fid %d packs POSITIVE (int64 not overflowed): key = %d" % [last, mk])
	_ok(int(mu[0]) == last and Vector3i(mu[1]) == extreme, "max registered fid round-trips exactly")
	# Headroom, stated as the doc states it (§3.1 fact 4): the pack is ≈ fid·2^47, so a plain int64
	# holds fid to ~65,000. Assert the CEILING directly — pack the documented bound and require it to
	# stay positive and round-trip — then require the live registry to sit comfortably under it. (The
	# ratio max_int/max_key is ~14× here and that is CORRECT: 4631 × 14 ≈ 65,000, the same statement.)
	const FID_CEILING := 65000
	var ck: int = FA.edit_key(FID_CEILING, extreme)
	var cu: Array = FA.edit_key_unpack(ck)
	_ok(ck > 0 and int(cu[0]) == FID_CEILING and Vector3i(cu[1]) == extreme,
		"the documented fid ceiling %d still packs positive + round-trips (key = %d < 2^63)" % [FID_CEILING, ck])
	_ok(last < FID_CEILING / 4, "registered fids (max %d) sit under a 4× margin of the %d ceiling — room for O3's K=50 resize + more bodies" % [last, FID_CEILING])
