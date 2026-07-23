extends SceneTree
## COSMOS LOD-TEXTURE Phase 1 gate (docs/COSMOS-LOD-TEXTURE-DESIGN.md §6 Phase 1). Runs with FACETED = true and
## FP_FACET_TEX sed-toggled. Four falsifiable assertions:
##   G-FT-OFF     — with FP_FACET_TEX OFF the far-ring mesh carries NO UV/UV2 channels (bit-identical to shipped);
##                  with it ON the UV channels are present and index-aligned with the geometry (additive only).
##   G-FT-BAKE    — a baked texel == the 2×2 box average of the fine sample_columns colours it covers (ε = 8-bit
##                  quantization); the bake is deterministic across two bakes of the same facet.
##   G-FT-UV      — every emitted vertex's TEX_UV lands inside its own facet's rect [(a/K,b/K),((a+1)/K,(b+1)/K)];
##                  two same-face neighbour facets map to ADJACENT texels (shared-edge u continuity).
##   G-FT-PALETTE — a texel's colour matches FarPalette.color_for at the texel-centre sphere direction (within
##                  tolerance), over the facet's interior texels (savanna/jungle skipped — the C++ frozen-14
##                  far-palette maps them to grass, a disclosed one-sampler divergence, not a bake fault).
## Each assertion is perturbed and confirmed to FAIL, per the falsifiability contract.

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
	print("=== verify_facet_tex (LOD-TEXTURE Phase 1) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true) — sed-toggled.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	print("  flag FP_FACET_TEX = %s, spawn facet = %d (K=%d, R=%d)" % [str(CubeSphere.FP_FACET_TEX), fid, FA.K, int(FA.R_BLOCKS)])

	var tex_on := CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE   # LOW #3: the textured ring needs BOTH
	_gate_off(fid)
	if tex_on:
		_gate_bake(fid)
		_gate_uv(fid)
		_gate_palette(fid)
		_gate_cover(fid)
	else:
		print("  (texture path OFF — G-FT-BAKE/UV/PALETTE/COVER need FP_FACET_TEX && FP_SHELL_ABSOLUTE ON; OFF-identity by G-FT-OFF)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-FT-OFF: OFF ⇒ no UV channels (byte-identical); ON ⇒ UV channels present + geometry-aligned -----------
func _gate_off(spawn_fid: int) -> void:
	var ring := FacetFarRing.new()
	get_root().add_child(ring)
	ring.setup(spawn_fid)
	ring.force_rebuild()
	var arr := ring.mesh_arrays()
	var ok_built := arr.size() == Mesh.ARRAY_MAX and (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0
	_ok(ok_built, "G-FT-OFF: far ring built a non-empty mesh (%d verts)" % (0 if not ok_built else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()))
	if not ok_built:
		ring.queue_free()
		return
	var nverts := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var uv: Variant = arr[Mesh.ARRAY_TEX_UV]
	var uv2: Variant = arr[Mesh.ARRAY_TEX_UV2]
	if CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE:
		var nu := (uv as PackedVector2Array).size() if uv != null else 0
		var nu2 := (uv2 as PackedVector2Array).size() if uv2 != null else 0
		_ok(nu == nverts and nu2 == nverts,
			"G-FT-OFF(ON): UV/UV2 channels present and index-aligned with geometry (uv=%d uv2=%d verts=%d)" % [nu, nu2, nverts])
		# UV2.y (close-up slot) is always -1 in Phase 1; UV2.x is a valid face 0..5.
		var slot_ok := true
		var face_ok := true
		if uv2 != null:
			for v in (uv2 as PackedVector2Array):
				if absf(v.y - (-1.0)) > 1e-4: slot_ok = false
				if v.x < -0.5 or v.x > 5.5: face_ok = false
		_ok(slot_ok, "G-FT-OFF(ON): every UV2.y (close-up slot) == -1 (no close-up tier in Phase 1)")
		_ok(face_ok, "G-FT-OFF(ON): every UV2.x (base-map layer) is a valid cube face 0..5")
	else:
		var no_uv := (uv == null or (uv as PackedVector2Array).size() == 0)
		var no_uv2 := (uv2 == null or (uv2 as PackedVector2Array).size() == 0)
		_ok(no_uv and no_uv2, "G-FT-OFF: flag OFF ⇒ far-ring mesh carries NO UV/UV2 channels (bit-identical to shipped)")
	ring.queue_free()

# --- G-FT-BAKE: baked texel == 2×2 box average of the fine sample_columns colours; deterministic -----------
func _gate_bake(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.bake_facet(fid)
	var fine := baker.sample_fine(fid)
	var bs := FacetTexBaker.BAKE_SRC
	var bt := FacetTexBaker.BASE_TEXELS
	var down := FacetTexBaker.DOWNS
	var eps := 0.01                                   # RGBA8 mip-0 quantization (~1/255) + fp
	var worst := 0.0
	for ty in range(bt):
		for tx in range(bt):
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + tx * down
				for sx in range(down):
					var c: Color = fine[row + sx]
					r += c.r; g += c.g; b += c.b
			var inv := 1.0 / float(down * down)
			var expect := Color(r * inv, g * inv, b * inv, 1.0)
			var got := baker.texel_color(fid, tx, ty)
			worst = maxf(worst, maxf(absf(got.r - expect.r), maxf(absf(got.g - expect.g), absf(got.b - expect.b))))
	_ok(worst <= eps, "G-FT-BAKE: every texel == the 2×2 box average of its fine colours (worst Δ=%.4f ≤ %.3f)" % [worst, eps])

	# Falsify: comparing a texel to a SHIFTED box average (a different texel's block) must exceed ε somewhere.
	var mism := 0.0
	for ty in range(bt - 1):
		for tx in range(bt - 1):
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + (tx + 1) * down   # shifted +1 texel in x
				for sx in range(down):
					var c: Color = fine[row + sx]
					r += c.r; g += c.g; b += c.b
			var inv := 1.0 / float(down * down)
			var got := baker.texel_color(fid, tx, ty)
			mism = maxf(mism, absf(got.r - r * inv) + absf(got.g - g * inv) + absf(got.b - b * inv))
	_ok(mism > eps, "G-FT-BAKE falsify: a shifted box average disagrees (worst Δ=%.4f > %.3f)" % [mism, eps])

	# Determinism: re-bake the same facet → identical stored texels.
	var b2 := FacetTexBaker.new()
	b2.setup(fid)
	b2.bake_facet(fid)
	var det := true
	for ty in range(bt):
		for tx in range(bt):
			if baker.texel_color(fid, tx, ty) != b2.texel_color(fid, tx, ty):
				det = false
	_ok(det, "G-FT-BAKE: the bake is deterministic across two independent bakes of facet %d" % fid)

	# NEVER-OOM ledger (§4): base-tier-only footprint under the all-flags-on ceiling.
	baker.prewarm(PackedInt32Array([fid]))
	var mb := float(baker.total_bytes()) / (1024.0 * 1024.0)
	_ok(baker.total_bytes() <= FacetTexBaker.FACET_TEX_BYTES_MAX,
		"G-FT-BAKE: total_bytes = %.2f MB ≤ %.0f MB ceiling (base-tier-only)" % [mb, float(FacetTexBaker.FACET_TEX_BYTES_MAX) / (1024.0 * 1024.0)])
	_ok(baker.base_texture() != null, "G-FT-BAKE: prewarm built the 6-layer base-map Texture2DArray")

# --- G-FT-UV: every UV inside its facet rect; same-face neighbours map to adjacent texels ------------------
func _gate_uv(fid: int) -> void:
	var ring := FacetFarRing.new()
	get_root().add_child(ring)
	ring.setup(fid)
	# Pick an interior facet on cube face 0 with a same-face East neighbour (a+1 < K).
	var k := FA.K
	var a := 5; var b := 5; var face := 0
	var f0 := (face * k + a) * k + b
	var fe := (face * k + (a + 1)) * k + b
	var kf := 1.0 / float(k)
	var eps := 1e-5

	var uv0 := ring.gate_facet_uvs(f0)
	_ok(uv0.size() > 0, "G-FT-UV: facet %d emits UVs (%d)" % [f0, uv0.size()])
	var inside := true
	var umin := 1e9; var umax := -1e9; var vmin := 1e9; var vmax := -1e9
	for uv in uv0:
		if uv.x < a * kf - eps or uv.x > (a + 1) * kf + eps: inside = false
		if uv.y < b * kf - eps or uv.y > (b + 1) * kf + eps: inside = false
		umin = minf(umin, uv.x); umax = maxf(umax, uv.x)
		vmin = minf(vmin, uv.y); vmax = maxf(vmax, uv.y)
	_ok(inside, "G-FT-UV: every UV of facet (%d,%d,%d) lands inside its rect [%.4f..%.4f]×[%.4f..%.4f]" % [face, a, b, a * kf, (a + 1) * kf, b * kf, (b + 1) * kf])
	_ok(absf(umin - a * kf) < eps and absf(umax - (a + 1) * kf) < eps and absf(vmin - b * kf) < eps and absf(vmax - (b + 1) * kf) < eps,
		"G-FT-UV: facet UV span fills its full rect (u:%.5f..%.5f v:%.5f..%.5f)" % [umin, umax, vmin, vmax])

	# Continuity: facet (a,b)'s east edge (max u) == east-neighbour (a+1,b)'s west edge (min u) == (a+1)/K.
	var uve := ring.gate_facet_uvs(fe)
	var emin := 1e9
	for uv in uve:
		emin = minf(emin, uv.x)
	_ok(absf(umax - emin) < eps and absf(emin - (a + 1) * kf) < eps,
		"G-FT-UV: same-face neighbours map to ADJACENT texels (facet umax=%.5f == neighbour umin=%.5f == %.5f)" % [umax, emin, (a + 1) * kf])

	# Falsify: the UVs do NOT fill a NEIGHBOUR facet's rect (they must not spill one cell over).
	var wrong_inside := true
	for uv in uv0:
		if uv.x < (a + 1) * kf - eps or uv.x > (a + 2) * kf + eps:
			wrong_inside = false
			break
	_ok(not wrong_inside, "G-FT-UV falsify: facet UVs do NOT lie inside the next facet's rect")
	ring.queue_free()

# --- G-FT-PALETTE: texel colour ≈ FarPalette.color_for at the texel-centre sphere direction ----------------
func _gate_palette(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.bake_facet(fid)
	var bt := FacetTexBaker.BASE_TEXELS
	# The facet's 4 lattice corners (same mapping the baker uses).
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var w := FA.facet_planar_corner(fid, ci)
		var l := FA.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))

	var tol := 0.10
	var sum := 0.0
	var cnt := 0
	for ty in range(1, bt - 1):                       # facet-interior texels (exclude the 1-texel border)
		for tx in range(1, bt - 1):
			var s := (float(tx) + 0.5) / float(bt)
			var t := (float(ty) + 0.5) / float(bt)
			var lx := int(round(_bil(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bil(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var d := FA.cell_dir(fid, lx, lz)
			var prof: Vector4 = TerrainConfig.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS)
			var g := int(prof.x)
			var biome := int(prof.y)
			if biome == TerrainConfig.B_SAVANNA or biome == TerrainConfig.B_JUNGLE:
				continue                              # C++ frozen-14 far-palette maps these to grass (disclosed)
			var expect := FarPalette.color_for(g, biome, prof.w, g < TerrainConfig.SEA_LEVEL)
			var got := baker.texel_color(fid, tx, ty)
			sum += absf(got.r - expect.r) + absf(got.g - expect.g) + absf(got.b - expect.b)
			cnt += 1
	var mean := (sum / float(cnt)) if cnt > 0 else 9.9
	_ok(cnt >= 16 and mean < tol, "G-FT-PALETTE: baked texels match FarPalette.color_for at the centre direction (mean Δ=%.4f < %.2f over %d texels)" % [mean, tol, cnt])

	# Falsify: comparing against a ROTATED direction (a different facet's terrain) must blow the mean up.
	var other := (fid + FA.K * FA.K * 3) % (6 * FA.K * FA.K)   # ~antipodal facet
	var lc2 := PackedVector2Array(); lc2.resize(4)
	for ci in range(4):
		var w := FA.facet_planar_corner(other, ci)
		var l := FA.world_to_lattice64(other, w[0], w[1], w[2])
		lc2[ci] = Vector2(float(l[0]), float(l[2]))
	var sum2 := 0.0; var cnt2 := 0
	for ty in range(1, bt - 1):
		for tx in range(1, bt - 1):
			var s := (float(tx) + 0.5) / float(bt)
			var t := (float(ty) + 0.5) / float(bt)
			var lx := int(round(_bil(lc2[0].x, lc2[1].x, lc2[2].x, lc2[3].x, s, t)))
			var lz := int(round(_bil(lc2[0].y, lc2[1].y, lc2[2].y, lc2[3].y, s, t)))
			var d := FA.cell_dir(other, lx, lz)
			var prof: Vector4 = TerrainConfig.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS)
			var expect := FarPalette.color_for(int(prof.x), int(prof.y), prof.w, int(prof.x) < TerrainConfig.SEA_LEVEL)
			var got := baker.texel_color(fid, tx, ty)
			sum2 += absf(got.r - expect.r) + absf(got.g - expect.g) + absf(got.b - expect.b)
			cnt2 += 1
	var mean2 := (sum2 / float(cnt2)) if cnt2 > 0 else 0.0
	_ok(mean2 > mean, "G-FT-PALETTE falsify: a wrong (antipodal) facet's palette disagrees more (mean Δ=%.4f > %.4f)" % [mean2, mean])

# --- G-FT-COVER: un-baked facets contribute ZERO texture (alpha 0 → wt 0 → shipped vertex-colour, never black) --
func _gate_cover(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.bake_facet(fid)                               # bake ONLY this facet — every other facet stays un-baked
	var bt := FacetTexBaker.BASE_TEXELS
	var k := FA.K
	# A same-face neighbour of `fid` shares its page but was NOT baked (proves partial-page coverage).
	var face := int(fid / (k * k))
	var rem := fid - face * k * k
	var a := int(rem / k); var b := rem - a * k
	var other := (face * k + ((a + 1) % k)) * k + b
	_ok(other != fid, "G-FT-COVER: chose an un-baked same-face neighbour (%d) of the baked facet (%d)" % [other, fid])

	# The baked facet: every texel is opaque (alpha 1) → the shader's wt gate can engage → textured from orbit.
	var baked_opaque := true
	for ty in range(bt):
		for tx in range(bt):
			if absf(baker.texel_color(fid, tx, ty).a - 1.0) > 1e-4: baked_opaque = false
	_ok(baked_opaque and baker.is_baked(fid), "G-FT-COVER: a BAKED facet's texels are alpha 1 (wt can engage → satellite image)")

	# The un-baked facet: every texel is transparent (alpha 0). In the shader wt = smoothstep(...) * alpha = 0,
	# so it renders the shipped vertex-colour far ring — the far hemisphere is NEVER black from orbit (the bug).
	var unbaked_clear := true
	for ty in range(bt):
		for tx in range(bt):
			if baker.texel_color(other, tx, ty).a != 0.0: unbaked_clear = false
	_ok(unbaked_clear and not baker.is_baked(other),
		"G-FT-COVER: an UN-BAKED facet's texels are alpha 0 (wt → 0 → shipped vertex-colour, never black)")

	# Falsify: the un-baked sentinel must be TRANSPARENT, not opaque black — an opaque (alpha 1) sentinel is
	# exactly the reported blocker (black far hemisphere). Assert the two states DIFFER in alpha.
	_ok(baker.texel_color(fid, 8, 8).a != baker.texel_color(other, 8, 8).a,
		"G-FT-COVER falsify: bake FLIPS coverage alpha 0→1 (baked %.1f ≠ un-baked %.1f)" % [baker.texel_color(fid, 8, 8).a, baker.texel_color(other, 8, 8).a])

static func _bil(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t
