extends SceneTree
## COSMOS ORBITAL O4a — G-O4-EQ, the keystone equivalence gate (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §3.4).
## Proves the fid-namespace refactor renders/simulates EARTH byte-identically before the Moon exists.
##
## The golden pins below were captured by the throwaway dump version of THIS file on the PRE-refactor tree
## (facet_count 3456, single-body atlas). Post-refactor (MULTI_BODY=false, one registered body) the atlas
## byte-hash + worldgen sample digest MUST equal them, and every per-fid accessor MUST collapse to the
## shipped constants. If the hash differs the refactor perturbed Earth — that is a hard FAIL, not a re-pin.
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

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _atlas_hash(ne: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(FA._frame.slice(0, ne * 12).to_byte_array())
	ctx.update(FA._off.slice(0, ne * 2).to_byte_array())
	ctx.update(FA._poly.slice(0, ne * 8).to_byte_array())
	ctx.update(FA._dom.slice(0, ne * 4).to_byte_array())
	ctx.update(FA._seam_plane.slice(0, ne * 16).to_byte_array())
	ctx.update(FA._seam_neigh.slice(0, ne * 4).to_byte_array())
	ctx.update(FA._seam_ring.slice(0, ne * 24).to_byte_array())
	ctx.update(FA._seam_mhat.slice(0, ne * 12).to_byte_array())
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
	print("=== verify_multibody (O4a G-O4-EQ — Earth byte-identity) ===")
	TC.warm_up()
	FA.warm_up()

	# --- G-O4-OFF: MULTI_BODY default false ⇒ exactly one built body, no Moon rows ---
	_ok(not CubeSphere.MULTI_BODY, "MULTI_BODY default false")
	_ok(FA.body_count() == 1, "body_count() == 1 (Earth only, no Moon rows built)")
	_ok(FA.BODY_TABLE.size() == 1, "BODY_TABLE holds exactly Earth in O4a (Moon is O4b)")

	# --- accessor contract: every per-fid read collapses to the shipped constants ---
	var ne := FA.facet_count()
	_ok(ne == GOLDEN_EARTH_FACETS, "facet_count() == %d (== pre-refactor)" % GOLDEN_EARTH_FACETS)
	_ok(FA.fid_base("earth") == 0, "fid_base(earth) == 0")
	_ok(FA.body_slot("earth") == 0, "body_slot(earth) == 0")
	_ok(FA.body_facet_count("earth") == GOLDEN_EARTH_FACETS, "body_facet_count(earth) == %d" % GOLDEN_EARTH_FACETS)
	_ok(FA.r_of(FA.fid_base("earth")) == 3072.0, "r_of(earth base) == 3072.0 (SHIPPED radius; NOT the O3 6371)")
	_ok(FA.r_of(FA.fid_base("earth")) == FA.R_BLOCKS, "r_of(earth) == FacetAtlas.R_BLOCKS")
	_ok(FA.k_of(FA.fid_base("earth")) == FA.K, "k_of(earth) == FacetAtlas.K (24)")
	# hold over the WHOLE range: k_of ≡ 24, r_of ≡ 3072, body_of_fid ≡ 0 for every valid fid
	var bad_k := 0; var bad_r := 0; var bad_body := 0
	for fid in range(ne):
		if FA.k_of(fid) != 24: bad_k += 1
		if FA.r_of(fid) != 3072.0: bad_r += 1
		if FA.body_of_fid(fid) != 0: bad_body += 1
	_ok(bad_k == 0, "k_of(fid) == 24 over all %d fids (%d bad)" % [ne, bad_k])
	_ok(bad_r == 0, "r_of(fid) == 3072.0 over all %d fids (%d bad)" % [ne, bad_r])
	_ok(bad_body == 0, "body_of_fid(fid) == 0 (Earth) over all %d fids (%d bad)" % [ne, bad_body])

	# --- memory identity: no new bytes for Earth (616 B/fid, same array sizes) ---
	_ok(FA._frame.size() == GOLDEN_FRAME, "_frame size == %d" % GOLDEN_FRAME)
	_ok(FA._off.size() == GOLDEN_OFF, "_off size == %d" % GOLDEN_OFF)
	_ok(FA._poly.size() == GOLDEN_POLY, "_poly size == %d" % GOLDEN_POLY)
	_ok(FA._dom.size() == GOLDEN_DOM, "_dom size == %d" % GOLDEN_DOM)
	_ok(FA._seam_plane.size() == GOLDEN_SEAM_PLANE, "_seam_plane size == %d" % GOLDEN_SEAM_PLANE)
	_ok(FA._spawn_fid == GOLDEN_SPAWN_FID, "spawn_fid == %d (== pre-refactor)" % GOLDEN_SPAWN_FID)

	# --- THE keystone: atlas byte-hash + worldgen sample digest == golden pins ---
	var ah := _atlas_hash(ne)
	print("  atlas MD5   = %s" % ah)
	_ok(ah == GOLDEN_ATLAS_MD5, "atlas byte-hash == golden pin (Earth atlas bit-for-bit unchanged)")
	var wh := _worldgen_digest(ne)
	print("  worldgen MD5 = %s" % wh)
	_ok(wh == GOLDEN_WORLDGEN_MD5, "worldgen sample digest == golden pin (facet_profile + resolve_cell unchanged)")

	# --- facet_of_dir(body, d): the body-param classifier round-trips every Earth facet centre ---
	var dir_bad := 0
	for fid in range(ne):
		var cc: Vector2i = FA.centre_cell(fid)
		var d: CubeSphere.DVec3 = FA.cell_dir(fid, cc.x, cc.y)
		if int(FA.facet_of_dir("earth", d)) != fid:
			dir_bad += 1
	_ok(dir_bad == 0, "facet_of_dir(\"earth\", cell_dir(centre)) == fid over all %d facets (%d bad)" % [ne, dir_bad])

	# --- edit_key pack/unpack bijection over the (sampled) global fid range (§3.1 fact 4) ---
	var key_bad := 0
	for fid in range(0, ne, 7):
		for cell in [Vector3i(-131072, -512, -131072), Vector3i(0, 0, 0), Vector3i(131071, 1535, 131071), Vector3i(37, 12, -900)]:
			var k: int = FA.edit_key(fid, cell)
			var u: Array = FA.edit_key_unpack(k)
			if int(u[0]) != fid or Vector3i(u[1]) != cell or FA.edit_key_fid(k) != fid or k < 0:
				key_bad += 1
	_ok(key_bad == 0, "edit_key pack/unpack bijection over sampled fid×cell range (%d bad)" % key_bad)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
