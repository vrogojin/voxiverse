extends SceneTree
## COSMOS-ORBITAL-O1O4 §3.6 — the walkable-Moon (O4a+O4b) gate suite. Runs in WHATEVER CubeSphere.MULTI_BODY
## state it is launched in (the gate runner runs it BOTH ways: default false, then sed-toggled true). The
## keystone (G-O4-EQ) asserts the pinned Earth atlas hash + worldgen sample hash are UNCHANGED in BOTH states,
## proving the BodyAtlas namespace refactor + Moon append never perturb Earth. Gates:
##   G-O4-OFF     MULTI_BODY=false ⇒ only Earth rows (total==6·K², 1 active body); k_of/r_of/body_of_fid==Earth
##   G-O4-EQ      Earth atlas hash + worldgen samples == the pre-refactor pin (both flag states)
##   G-O4-MOONGEN moon_profile determinism; NO liquid; height ∈ [MOON_FLOOR_Y, MAX_SURFACE_Y]; craters present; no trees
##   G-O4-ATLAS2  every Moon facet frame passes verify_frame; facet_of_dir_body round-trips; seams close within the Moon
##   G-O4-KEY     edit_key/unpack bijection over the FULL Earth+Moon fid range (incl. the max fid + cell extremes)
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

# The PRE-REFACTOR pin (captured by src/tools/dump_earth_pin.gd against HEAD 765d8fc, K=24 R=6371).
const PIN_ATLAS := "a5881fd1f584ffb15c1a57243b1315d4"
const PIN_WORLDGEN := "f3eb81cf4a6ae55179b862923d1d00eb"

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_multibody (O4a+O4b) — MULTI_BODY=%s ===" % CubeSphere.MULTI_BODY)
	TC.warm_up()
	FA.warm_up()
	var earth_nf := 6 * FA.K * FA.K
	print("  bodies=%d total_facets=%d (earth=%d) spawn=%d" % [
		FA.active_body_count(), FA.total_facet_count(), earth_nf, FA.spawn_facet()])

	_gate_off(earth_nf)
	_gate_equivalence(earth_nf)
	if CubeSphere.MULTI_BODY:
		_gate_moongen()
		_gate_atlas2()
		_gate_key()
	else:
		_ok(FA.active_body_count() == 1, "G-O4-OFF: exactly ONE active body (Earth) when MULTI_BODY=false")
		_ok(FA.total_facet_count() == earth_nf, "G-O4-OFF: total facets == 6·K² (no Moon rows)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---- G-O4-OFF: Earth's registry rows are exactly the shipped constants ----
func _gate_off(earth_nf: int) -> void:
	_ok(FA.body_index("earth") == 0 and FA.fid_base(0) == 0, "G-O4-OFF: Earth is body 0 at fid_base 0")
	_ok(FA.body_facet_count(0) == earth_nf, "G-O4-OFF: Earth facet count == 6·K² = %d" % earth_nf)
	var mid := earth_nf / 2
	_ok(FA.body_of_fid(mid) == 0 and FA.k_of(mid) == FA.K and is_equal_approx(FA.r_of(mid), FA.R_BLOCKS),
		"G-O4-OFF: k_of/r_of/body_of_fid over an Earth fid return the shipped K/R_BLOCKS")
	_ok(FA.facet_count() == earth_nf, "G-O4-OFF: facet_count() stays the home-body (Earth) count")

# ---- G-O4-EQ (keystone): the Earth atlas + worldgen are byte-identical to the pinned pre-refactor tree ----
func _gate_equivalence(earth_nf: int) -> void:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(FA._frame.slice(0, earth_nf * 12).to_byte_array())
	ctx.update(FA._off.slice(0, earth_nf * 2).to_byte_array())
	ctx.update(FA._poly.slice(0, earth_nf * 8).to_byte_array())
	ctx.update(FA._dom.slice(0, earth_nf * 4).to_byte_array())
	ctx.update(FA._seam_plane.slice(0, earth_nf * 16).to_byte_array())
	ctx.update(FA._seam_neigh.slice(0, earth_nf * 4).to_byte_array())
	ctx.update(FA._seam_ring.slice(0, earth_nf * 24).to_byte_array())
	ctx.update(FA._seam_mhat.slice(0, earth_nf * 12).to_byte_array())
	ctx.update(PackedInt32Array([FA._spawn_fid]).to_byte_array())
	var atlas_hash := ctx.finish().hex_encode()
	_ok(atlas_hash == PIN_ATLAS, "G-O4-EQ: Earth atlas hash == pin (%s%s)" % [
		atlas_hash, "" if atlas_hash == PIN_ATLAS else " != " + PIN_ATLAS])

	var wctx := HashingContext.new()
	wctx.start(HashingContext.HASH_MD5)
	var fids: Array[int] = [0, 37, 100, 500, 999, 1728, 2000, 3455]
	for fid in fids:
		var cc := FA.centre_cell(fid)
		for dx: int in [-40, -7, 0, 11, 33]:
			for dz: int in [-25, 0, 19]:
				var x := cc.x + dx
				var z := cc.y + dz
				var p: Vector4 = TC.facet_profile(fid, x, z)
				wctx.update(PackedFloat64Array([p.x, p.y, p.z, p.w]).to_byte_array())
				var g := int(p.x); var biome := int(p.y)
				var cells := PackedInt32Array()
				for y in range(g - 3, g + 3):
					cells.append(TC.resolve_cell(x, y, z, g, biome, p.z, p.w))
				wctx.update(cells.to_byte_array())
	var worldgen_hash := wctx.finish().hex_encode()
	_ok(worldgen_hash == PIN_WORLDGEN, "G-O4-EQ: Earth worldgen hash == pin (%s%s)" % [
		worldgen_hash, "" if worldgen_hash == PIN_WORLDGEN else " != " + PIN_WORLDGEN])

# ---- G-O4-MOONGEN: the Moon body generates valid airless terrain ----
func _gate_moongen() -> void:
	var bi := FA.body_index("moon")
	_ok(bi == 1, "G-O4-MOONGEN: Moon is active body 1")
	_ok(FA.body_facet_count(bi) == 6 * 14 * 14 and FA.body_facet_count(bi) == 1176,
		"G-O4-MOONGEN: Moon appended 6·14² = 1176 facets")
	_ok(FA.total_facet_count() == 6 * FA.K * FA.K + 1176, "G-O4-MOONGEN: total == Earth + Moon facets")
	var base := FA.fid_base(bi)
	_ok(FA.body_of_fid(base) == 1 and FA.k_of(base) == 14 and is_equal_approx(FA.r_of(base), 1737.0),
		"G-O4-MOONGEN: k_of/r_of/body_of_fid over a Moon fid == (14, 1737, moon)")

	# Determinism: moon_profile_at_dir is a pure function.
	var det_ok := true
	# Height bound + no-liquid + no-tree over a dense sample of Moon columns; crater presence via variance.
	var minb := 1 << 30; var maxb := -(1 << 30)
	var samples := 0
	var liquid_seen := 0; var tree_seen := 0; var air_above_ok := true
	var wid := BlockCatalog.id_of(&"water"); var lid := BlockCatalog.id_of(&"lava")
	var iceid := BlockCatalog.id_of(&"ice"); var woodid := BlockCatalog.WOOD; var leafid := BlockCatalog.LEAF
	var mcount := FA.body_facet_count(bi)
	for lf in range(0, mcount, 7):                       # ~168 facets sampled
		var fid := base + lf
		var cc := FA.centre_cell(fid)
		for dx: int in [-30, 0, 30]:
			for dz: int in [-30, 0, 30]:
				var x := cc.x + dx; var z := cc.y + dz
				var p: Vector4 = TC.facet_profile(fid, x, z)
				var p2: Vector4 = TC.facet_profile(fid, x, z)
				if p != p2:
					det_ok = false
				var g := int(p.x); var biome := int(p.y)
				samples += 1
				minb = mini(minb, g); maxb = maxi(maxb, g)
				# air strictly above the surface; strata + no liquid/tree from the top down through the crust
				if TC.resolve_cell(x, g + 1, z, g, biome, p.z, p.w) != BlockCatalog.AIR:
					air_above_ok = false
				for y in range(g, g - 8, -1):
					var v := TC.resolve_cell(x, y, z, g, biome, p.z, p.w)
					if CellCodec.liquid_field(v) != 0:
						liquid_seen += 1
					var mat := CellCodec.mat(v)
					if mat == wid or mat == lid or mat == iceid:
						liquid_seen += 1
					if mat == woodid or mat == leafid:
						tree_seen += 1
	_ok(det_ok, "G-O4-MOONGEN: moon_profile_at_dir is deterministic (same d̂ → same profile)")
	_ok(minb >= TC.MOON_FLOOR_Y and maxb <= TC.MAX_SURFACE_Y,
		"G-O4-MOONGEN: g ∈ [%d, MAX_SURFACE_Y=%d] over %d samples (min %d max %d)" % [TC.MOON_FLOOR_Y, TC.MAX_SURFACE_Y, samples, minb, maxb])
	_ok(liquid_seen == 0, "G-O4-MOONGEN: NO liquid emitted anywhere on the Moon (%d liquid cells)" % liquid_seen)
	_ok(tree_seen == 0, "G-O4-MOONGEN: NO trees on the Moon (%d wood/leaf cells)" % tree_seen)
	_ok(air_above_ok, "G-O4-MOONGEN: vacuum (AIR) directly above every sampled Moon surface")
	_ok(maxb - minb >= 8, "G-O4-MOONGEN: relief spread ≥ 8 blocks (min %d max %d — maria/highlands + craters)" % [minb, maxb])
	# Crater field present: dense sample of the raw crater kernel over Moon directions shows bowls AND rims.
	var bowls := 0; var rims := 0; var probes := 0
	for lf in range(0, mcount, 3):
		var fid := base + lf
		var cc := FA.centre_cell(fid)
		var d := FA.cell_dir(fid, cc.x, cc.y)
		var ch := TC._moon_crater_height(d.x, d.y, d.z, FA.r_of(fid))
		probes += 1
		if ch < -1.0: bowls += 1
		if ch > 0.5: rims += 1
	_ok(bowls > 0 and rims > 0, "G-O4-MOONGEN: crater field present (%d bowls, %d rims over %d probes)" % [bowls, rims, probes])

# ---- G-O4-ATLAS2: Moon facet frames + facet_of_dir + seam closure ----
func _gate_atlas2() -> void:
	var bi := FA.body_index("moon")
	var base := FA.fid_base(bi)
	var mcount := FA.body_facet_count(bi)
	var worst_ortho := 0.0; var worst_rt := 0.0; var min_ndc := 1.0; var bad_det := 0; var worst_dev := 0.0
	var cos1 := cos(deg_to_rad(1.0))
	var dir_bad := 0; var seam_bad := 0
	for lf in range(mcount):
		var fid := base + lf
		var m: Dictionary = FA.verify_frame(fid)
		worst_ortho = maxf(worst_ortho, m["ortho"])
		worst_rt = maxf(worst_rt, m["roundtrip"])
		min_ndc = minf(min_ndc, m["n_dot_centre"])
		if absf(float(m["det"]) - 1.0) > 1e-6: bad_det += 1
		var edge: float = m["edge"]
		if edge > 0.0: worst_dev = maxf(worst_dev, float(m["plane_dev"]) / edge)
		# facet_of_dir_body round-trips the facet centre direction back to this fid
		var cc := FA.centre_cell(fid)
		var d := FA.cell_dir(fid, cc.x, cc.y)
		if FA.facet_of_dir_body(bi, d) != fid: dir_bad += 1
		# seams close WITHIN the Moon body (neighbour fid is a Moon fid — seams never cross bodies)
		for slot in range(4):
			var nb := FA.seam_neighbour(fid, slot)
			if nb < base or nb >= base + mcount or FA.body_of_fid(nb) != 1: seam_bad += 1
	_ok(worst_ortho < 1e-9, "G-O4-ATLAS2: Moon frames orthonormal (worst %s < 1e-9)" % worst_ortho)
	_ok(bad_det == 0, "G-O4-ATLAS2: every Moon basis right-handed (%d off)" % bad_det)
	_ok(min_ndc >= cos1, "G-O4-ATLAS2: Moon n̂ outward within 1° (min %.6f ≥ %.6f)" % [min_ndc, cos1])
	_ok(worst_dev < 0.02, "G-O4-ATLAS2: Moon facets near-planar (worst dev/edge %.4f < 0.02)" % worst_dev)
	_ok(worst_rt < 1e-3, "G-O4-ATLAS2: Moon W_fid round-trips (worst %s < 1e-3)" % worst_rt)
	_ok(dir_bad == 0, "G-O4-ATLAS2: facet_of_dir_body(moon, centre_dir) == fid for ALL %d Moon facets (%d bad)" % [mcount, dir_bad])
	_ok(seam_bad == 0, "G-O4-ATLAS2: every Moon seam closes within the Moon graph (%d cross-body/out-of-range)" % seam_bad)

# ---- G-O4-KEY: edit_key/unpack bijection over the full Earth+Moon fid range ----
func _gate_key() -> void:
	var max_fid := FA.total_facet_count() - 1
	var test_fids: Array[int] = [0, 1, 3455, 3456, FA.fid_base(FA.body_index("moon")), max_fid]
	var cells := [Vector3i(0, 0, 0), Vector3i(131071, 1535, -131072), Vector3i(-131072, -512, 131071), Vector3i(500, 40, -300)]
	var bad := 0
	for fid in test_fids:
		for cell: Vector3i in cells:
			var key := FA.edit_key(fid, cell)
			if key < 0: bad += 1
			var un: Array = FA.edit_key_unpack(key)
			if int(un[0]) != fid or un[1] != cell: bad += 1
			if FA.edit_key_fid(key) != fid: bad += 1
	_ok(bad == 0, "G-O4-KEY: edit_key/unpack bijection over Earth+Moon fids incl. max fid %d (%d mismatches)" % [max_fid, bad])
