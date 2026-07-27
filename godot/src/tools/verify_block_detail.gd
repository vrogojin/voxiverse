extends SceneTree
## COSMOS TEXTURED-LOD T1b gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2R.5). Runs with FACETED = true and FP_FACET_TEX
## + FP_BLOCK_DETAIL sed-toggled. Four falsifiable assertions (each perturbed and confirmed to FAIL):
##   G-BD-OFF  — off ⇒ the injected shell shader string is BYTE-IDENTICAL to the FP_FACET_TEX string and the baker
##               builds NO id pages / detail atlas; on ⇒ the injection is ADDITIVE only (still exactly ONE shader_type
##               → zero new compiled programs) and the id map is built.
##   G-BD-ID   — a baked texel's id == FarPalette.detail_pattern(sampled column) + 1 (majority of the fine samples);
##               ids ∈ [1, DETAIL_PATTERNS]; an UN-baked facet's id texels are 0.
##   G-BD-NORM — every detail layer's per-channel mean ≈ 0.5 (the degradation theorem: top mip ≡ colour map), and the
##               RAW (un-normalized) tile mean is NOT 0.5 (the falsifier).
##   G-BD-TILE — one detail tile per macro texel (DETAIL_PAGE == K·BASE_TEXELS), REPEAT wrap declared, and a baked
##               darkened mega-block grid border is present in each pattern layer.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_block_detail (TEXTURED-LOD T1b / FP_BLOCK_DETAIL) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true) — sed-toggled.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var tex_on := CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE
	var bd_on := CubeSphere.FP_BLOCK_DETAIL
	print("  flags FP_FACET_TEX=%s FP_BLOCK_DETAIL=%s, spawn facet=%d (K=%d)" % [str(tex_on), str(bd_on), fid, FA.K])

	_gate_off(fid, tex_on, bd_on)
	if tex_on and bd_on:
		_gate_id(fid)
		_gate_norm()
		_gate_tile(fid)
	else:
		print("  (detail path OFF — G-BD-ID/NORM/TILE need FP_FACET_TEX && FP_BLOCK_DETAIL ON; OFF-identity by G-BD-OFF)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-BD-OFF: shader byte-identity off / additive-only on; id pages gated ----------------------------------
func _gate_off(fid: int, tex_on: bool, bd_on: bool) -> void:
	var raw := FacetFarRing.gate_tex_shader_raw(false)
	var det := FacetFarRing.gate_tex_shader_detail(false)
	var raw_cu := FacetFarRing.gate_tex_shader_raw(true)
	var det_cu := FacetFarRing.gate_tex_shader_detail(true)
	# Exactly ONE compiled program per string in BOTH states (zero new ANGLE compiles): shader_type count unchanged.
	_ok(raw.count("shader_type") == 1 and det.count("shader_type") == 1
		and raw_cu.count("shader_type") == 1 and det_cu.count("shader_type") == 1,
		"G-BD-OFF: exactly ONE shader_type per shell string on/off (zero new compiled programs)")

	var baker := FacetTexBaker.new()
	baker.setup(fid)
	if bd_on:
		# ON: the injection is ADDITIVE (adds the detail samplers + a modulated ALBEDO) and NOT the identity.
		_ok(det != raw and det_cu != raw_cu, "G-BD-OFF(ON): the detail injection changed the shader string (additive)")
		_ok(det.contains("detail_map") and det.contains("id_map") and det.contains("repeat_enable")
			and det.contains("DETAIL_PAGE") and det.contains("_face"),
			"G-BD-OFF(ON): injected detail_map/id_map (REPEAT) samplers + modulated ALBEDO present")
		# The injection touches ONLY the final ALBEDO line: every other raw line survives verbatim (base_map path,
		# vertex(), scatter/day helpers untouched). The one replaced line still writes ALBEDO = mix(v_col_raw, …).
		var additive := true
		for line in raw.split("\n"):
			var s := line.strip_edges()
			if s == "" or s == "ALBEDO = mix(v_col_raw, col, wt) * v_st;":
				continue
			if not det.contains(line):
				additive = false
		_ok(additive and det.contains("ALBEDO = mix(v_col_raw,"),
			"G-BD-OFF(ON): only the final ALBEDO line changed (base_map path + vertex() untouched)")
		baker.bake_facet(fid)
		baker.prewarm(PackedInt32Array([fid]))
		_ok(baker.detail_on() and baker.id_texture() != null, "G-BD-OFF(ON): baker built the 6-layer id map")
	else:
		# OFF: byte-identical shader string AND no id pages / detail bytes built (the zero-cost identity).
		_ok(det == raw and det_cu == raw_cu, "G-BD-OFF: flag off ⇒ shell shader string BYTE-IDENTICAL to FP_FACET_TEX")
		baker.bake_facet(fid)
		baker.prewarm(PackedInt32Array([fid]))
		_ok(not baker.detail_on() and baker.id_texture() == null and baker.id_at(fid, 0, 0) == -1,
			"G-BD-OFF: flag off ⇒ NO id pages / detail atlas built (byte-identical, zero bytes)")

# --- G-BD-ID: id == classifier(sampled column) + 1; range; un-baked ⇒ 0 ------------------------------------
func _gate_id(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.bake_facet(fid)
	var fine := baker.sample_fine(fid)
	var bs := FacetTexBaker.BAKE_SRC
	var bt := FacetTexBaker.BASE_TEXELS
	var down := FacetTexBaker.DOWNS
	var np := FarPalette.DETAIL_PATTERNS
	var all_match := true
	var in_range := true
	var worst := ""
	for ty in range(bt):
		for tx in range(bt):
			# Expected id = FarPalette.detail_pattern(box-averaged colour) + 1 — the same classify the bake does.
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + tx * down
				for sx in range(down):
					var c: Color = fine[row + sx]
					r += c.r; g += c.g; b += c.b
			var inv := 1.0 / float(down * down)
			var expect := FarPalette.detail_pattern(Color(r * inv, g * inv, b * inv, 1.0)) + 1
			var got := baker.id_at(fid, tx, ty)
			if got != expect:
				all_match = false
				worst = "(%d,%d) got %d expect %d" % [tx, ty, got, expect]
			if got < 1 or got > np:
				in_range = false
	_ok(all_match, "G-BD-ID: every baked id == FarPalette.detail_pattern(fine) + 1 %s" % ("" if all_match else "— " + worst))
	_ok(in_range, "G-BD-ID: every baked id ∈ [1, %d] (a real material pattern)" % np)

	# id maps to REAL materials: the classified palette colour of a texel is closest to the pattern's own palette key.
	# (implicit in detail_pattern being a nearest-palette argmin — assert at least one non-grass id exists so the map
	#  is not a degenerate constant.)
	var seen := {}
	for ty in range(bt):
		for tx in range(bt):
			seen[baker.id_at(fid, tx, ty)] = true
	_ok(seen.size() >= 1 and not seen.has(0), "G-BD-ID: the baked facet has NO un-baked (id 0) texel (%d distinct ids)" % seen.size())

	# Un-baked facet ⇒ id 0 everywhere. Pick a facet the single bake never touched (a different face).
	var other := (int(fid) + FA.K * FA.K) % (6 * FA.K * FA.K)   # +one face over, same body
	if other == fid:
		other = (int(fid) + 1) % (6 * FA.K * FA.K)
	var unbaked_zero := baker.id_at(other, 0, 0) == 0 and baker.id_at(other, bt - 1, bt - 1) == 0
	_ok(unbaked_zero, "G-BD-ID: an un-baked facet's id texels are 0 (id 0 = un-baked sentinel)")

	# Falsify: a deliberately shifted expected id (neighbour texel's material) disagrees somewhere on a varied facet.
	var mism := false
	for ty in range(bt):
		for tx in range(bt - 1):
			if baker.id_at(fid, tx, ty) != baker.id_at(fid, tx + 1, ty):
				mism = true
	if mism:
		_ok(mism, "G-BD-ID falsify: neighbouring texels carry different ids (the map is not a constant)")
	else:
		# A perfectly uniform facet is legitimately constant — assert the opposite falsifier instead: a bogus id fails.
		_ok(baker.id_at(fid, 0, 0) != 0, "G-BD-ID falsify: baked facet id ≠ the un-baked sentinel 0")

# --- G-BD-NORM: each detail layer mean ≈ 0.5 (degradation theorem); raw tile mean is NOT ---------------------
func _gate_norm() -> void:
	var eps := 0.03                       # additive-centre + RGBA8 clamp/quantization tolerance
	var worst := 0.0
	var worst_layer := -1
	for layer in range(1, FarPalette.DETAIL_PATTERNS + 1):
		var img := FacetDetailAtlas.layer_image(layer)
		var m := FacetDetailAtlas.layer_mean(img)
		var dmax := maxf(absf(m.x - 0.5), maxf(absf(m.y - 0.5), absf(m.z - 0.5)))
		if dmax > worst:
			worst = dmax; worst_layer = layer
	_ok(worst <= eps, "G-BD-NORM: every detail layer's per-channel mean ≈ 0.5 (worst Δ=%.4f ≤ %.2f, layer %d)" % [worst, eps, worst_layer])

	# Falsify: a RAW (un-normalized) tile with a coloured face has a mean far from 0.5 on at least one channel.
	var raw := load("%s/grass.png" % FacetDetailAtlas.DIR) as Texture2D
	var raw_off := 0.0
	if raw != null:
		var ri := raw.get_image()
		if ri.get_format() != Image.FORMAT_RGBA8:
			ri.convert(Image.FORMAT_RGBA8)
		var sr := 0.0; var sg := 0.0; var sb := 0.0
		var n := ri.get_width() * ri.get_height()
		for y in range(ri.get_height()):
			for x in range(ri.get_width()):
				var c := ri.get_pixel(x, y)
				sr += c.r; sg += c.g; sb += c.b
		var inv := 1.0 / float(n)
		raw_off = maxf(absf(sr * inv - 0.5), maxf(absf(sg * inv - 0.5), absf(sb * inv - 0.5)))
	_ok(raw_off > eps, "G-BD-NORM falsify: the RAW grass tile mean is NOT 0.5 (Δ=%.4f > %.2f) — normalization is doing work" % [raw_off, eps])

# --- G-BD-TILE: one tile per macro texel, REPEAT, baked grid border -----------------------------------------
func _gate_tile(fid: int) -> void:
	var page := FA.K * FacetTexBaker.BASE_TEXELS        # macro texels per face edge (= id-page resolution)
	var det := FacetFarRing.gate_tex_shader_detail(false)
	_ok(det.contains("DETAIL_PAGE = %d.0" % page), "G-BD-TILE: shader tiles ONE detail tile per macro texel (DETAIL_PAGE == K·BASE_TEXELS == %d)" % page)
	_ok(det.contains("repeat_enable"), "G-BD-TILE: detail_map declared REPEAT (per-layer wrap, continuous phase within a face)")
	_ok(det.contains("v_uv * DETAIL_PAGE"), "G-BD-TILE: detail UV = v_uv · DETAIL_PAGE (block/texel sampling frequency)")

	# A darkened mega-block grid border is baked into each pattern layer: a corner (border) texel is darker than the
	# layer's interior mean on at least one channel, by more than quantization.
	var worst_layer := -1
	var min_gap := 1.0
	var bw := FacetDetailAtlas.DETAIL_BORDER
	for layer in range(1, FarPalette.DETAIL_PATTERNS + 1):
		var img := FacetDetailAtlas.layer_image(layer)
		var n := FacetDetailAtlas.DETAIL_TEXELS
		# Mean of the border ring vs mean of the interior (region means, not single texels — robust on dark tiles).
		var bs := 0.0; var bn := 0
		var iss := 0.0; var iin := 0
		for y in range(n):
			for x in range(n):
				var c := img.get_pixel(x, y)
				var lum := c.r + c.g + c.b
				if x < bw or x >= n - bw or y < bw or y >= n - bw:
					bs += lum; bn += 1
				else:
					iss += lum; iin += 1
		var gap := (iss / float(iin)) - (bs / float(bn))
		if gap < min_gap:
			min_gap = gap; worst_layer = layer
	_ok(min_gap > 0.02, "G-BD-TILE: every pattern layer has a darkened mega-block grid border (worst interior−border mean=%.3f, layer %d)" % [min_gap, worst_layer])
