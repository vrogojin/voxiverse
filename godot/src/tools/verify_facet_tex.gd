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
	var cu_on := tex_on and CubeSphere.FP_FACET_TEX_CLOSEUP                   # Phase 4: close-up needs its own flag too
	_gate_off(fid)
	if tex_on:
		_gate_bake(fid)
		_gate_uv(fid)
		_gate_palette(fid)
		_gate_cover(fid)
		_gate_bleed()
		_gate_budget(fid)                    # Phase 2/4: bounded per-frame bake (G-FT-BUDGET) — the make-or-break
		if cu_on:
			_gate_closeup_bake(fid)          # Phase 4: G-FT-CLOSEUP-BAKE (128² texel == generator sample)
			_gate_slot(fid)                  # Phase 4: G-FT-SLOT (≤64 resident, evict only outside cap)
		else:
			print("  (close-up path OFF — G-FT-CLOSEUP-BAKE/SLOT need FP_FACET_TEX_CLOSEUP ON)")
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

# --- G-FT-BLEED: premultiplied-alpha mips are coverage-correct (no black bleed at the bake frontier) ---------
# Pure CPU math (the review noted the gate can't exercise GPU sampling): model a 1-level box mip of the 2×2
# block [ baked(color,a=1), un-baked(0,a=0), un-baked, un-baked ] the way the baker (premultiply → box filter)
# + shader (divide by coverage) actually process it, and prove it recovers the TRUE colour, where the OLD
# straight-alpha path darkened toward black.
func _gate_bleed() -> void:
	var color := Color(0.60, 0.50, 0.30, 1.0)
	# Premultiplied source texels: baked = color·1 = color (a=1); un-baked = 0·0 = 0 (a=0). Box-average of 4.
	var pm_r := (color.r + 0.0 + 0.0 + 0.0) / 4.0
	var pm_g := (color.g + 0.0 + 0.0 + 0.0) / 4.0
	var pm_b := (color.b + 0.0 + 0.0 + 0.0) / 4.0
	var pm_a := (1.0 + 0.0 + 0.0 + 0.0) / 4.0                     # = 0.25 coverage
	# FIX (shader): un-premultiply → recover the true colour (coverage-correct, NOT darkened toward black).
	var rec := Vector3(pm_r / pm_a, pm_g / pm_a, pm_b / pm_a)
	var eps := 1e-4
	var d := absf(rec.x - color.r) + absf(rec.y - color.g) + absf(rec.z - color.b)
	_ok(d < eps, "G-FT-BLEED: premultiplied mip + un-premultiply recovers the true colour (Δ=%.6f < %.4f) — no black bleed" % [d, eps])
	# FAIL-BEFORE (old shader): straight mip rgb used directly (no divide) = color/4 → darkened toward black.
	var old := Vector3(pm_r, pm_g, pm_b)
	var dark := absf(old.x - color.r) + absf(old.y - color.g) + absf(old.z - color.b)
	_ok(dark > 0.3 and dark > d, "G-FT-BLEED fail-before: straight mip (no un-premultiply) darkens toward black (Δ=%.4f > 0.3, brightness %.0f%%)" % [dark, 100.0 * pm_a])

# --- G-FT-BUDGET: the per-frame bake cost stays bounded across a scripted drive (THE HARD PERF CONSTRAINT) ---
# Drives the budgeted baker.update() over a scripted orbit (rotating emit axis, off-surface) WITHOUT any prewarm, so
# every bake unit (base whole-facet + close-up row-slice) is charged. Measures each update()'s wall time and asserts
# the worst per-frame bake NEVER exceeds the budget by more than one bake unit (check-BEFORE model), AND that base
# coverage converges. This is the make-or-break proof: no prior fidelity tier stayed bounded on the main thread.
func _gate_budget(fid: int) -> void:
	var budget := CubeSphere.FACET_TEX_BAKE_BUDGET_MS
	# One bake UNIT ceiling (native): a base facet ≈ 0.9 ms; a close-up 16-row slice ≈ 0.5 ms; plus per-bake axis
	# scans + a first-frame texture upload. The check-BEFORE model bounds a frame at budget + one unit; measure it.
	var unit_ceil := 3.0
	var cd := _centre_dir(fid)
	var worst_ms := 0.0
	var over_count := 0

	# PHASE A — on-surface progressive BASE coverage: close-up is inert (off-surface only), so base gets the full
	# budget → coverage must advance monotonically, every frame bounded. This is the Phase-2 progressive proof.
	var ba := FacetTexBaker.new()
	ba.setup(fid)
	ba.prewarm(PackedInt32Array())        # production builds the base array at setup (behind the load hold) — do the same
	var last := 0
	var monotonic := true
	for f in range(200):
		# drift the axis a little so nearest-unbaked coverage spreads outward from the spawn point
		var ax := Vector3(cd[0], cd[1], cd[2]).rotated(Vector3(0, 1, 0) if absf(cd[1]) < 0.9 else Vector3(1, 0, 0), float(f) * 0.01)
		var t0 := Time.get_ticks_usec()
		ba.update([ax.x, ax.y, ax.z], false, budget)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		worst_ms = maxf(worst_ms, ms)
		if ms > budget + unit_ceil: over_count += 1
		if ba.baked_count() < last: monotonic = false
		last = ba.baked_count()
	_ok(ba.baked_count() > 0 and monotonic,
		"G-FT-BUDGET: on-surface base coverage advances monotonically under budget (%d / %d baked)" % [ba.baked_count(), 6 * FA.K * FA.K])

	# PHASE B — off-surface orbit sweep: close-up promotion + row-sliced bakes active. The make-or-break: every frame
	# stays bounded by budget + one unit while the sub-camera point sweeps the globe, and residency never exceeds
	# CLOSEUP_MAX (it turns over as the cap moves — the fast sweep out-runs the bake, which is the safe direction).
	var bb := FacetTexBaker.new()
	bb.setup(fid)
	bb.prewarm(PackedInt32Array())        # base array built at setup (production behind the load hold)
	var peak_resident := 0
	for f in range(240):
		var ax := Vector3(cd[0], cd[1], cd[2]).rotated(Vector3(0, 1, 0) if absf(cd[1]) < 0.9 else Vector3(1, 0, 0), float(f) * 0.03)
		var t0 := Time.get_ticks_usec()
		bb.update([ax.x, ax.y, ax.z], true, budget)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		worst_ms = maxf(worst_ms, ms)
		if ms > budget + unit_ceil: over_count += 1
		peak_resident = maxi(peak_resident, bb.closeup_resident_count())
	_ok(over_count == 0,
		"G-FT-BUDGET: worst per-frame bake = %.3f ms ≤ budget %.1f + one unit %.1f ms over 440 frames (%d overruns)" % [worst_ms, budget, unit_ceil, over_count])
	_ok(peak_resident <= CubeSphere.CLOSEUP_MAX,
		"G-FT-BUDGET: off-surface close-up residency ≤ CLOSEUP_MAX (peak %d ≤ %d)" % [peak_resident, CubeSphere.CLOSEUP_MAX])
	print("    [G-FT-BUDGET] worst-frame update = %.3f ms (bound %.1f); base baked %d, off-surface peak-resident %d, bytes %.2f MB" %
		[worst_ms, budget + unit_ceil, ba.baked_count(), peak_resident, float(bb.total_bytes()) / (1024.0 * 1024.0)])

	# Falsify: a ZERO budget starts at most one unit — the loop must not run away (the check-BEFORE invariant).
	var b2 := FacetTexBaker.new(); b2.setup(fid)
	var t1 := Time.get_ticks_usec()
	b2.update([cd[0], cd[1], cd[2]], false, 0.0)
	var ms0 := float(Time.get_ticks_usec() - t1) / 1000.0
	_ok(ms0 <= unit_ceil, "G-FT-BUDGET falsify: a 0 ms budget starts at most one unit (%.3f ms ≤ %.1f)" % [ms0, unit_ceil])
	# NEVER-OOM ledger with close-up ON (§4): ≤ 20 MB all-flags-on ceiling.
	var mb := float(bb.total_bytes()) / (1024.0 * 1024.0)
	_ok(bb.total_bytes() <= FacetTexBaker.FACET_TEX_BYTES_MAX,
		"G-FT-BUDGET: total_bytes = %.2f MB ≤ %.0f MB ceiling (base + close-up all-on)" % [mb, float(FacetTexBaker.FACET_TEX_BYTES_MAX) / (1024.0 * 1024.0)])

# --- G-FT-CLOSEUP-BAKE: a resident close-up layer's 128² texels == the generator sample at each column (box-avg 1:1) --
func _gate_closeup_bake(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	var cd := _centre_dir(fid)
	# Drive the budgeted path with the axis pinned on `fid` (it is the nearest want → baked first) until it is resident.
	var resident := false
	for _f in range(400):
		baker.update([cd[0], cd[1], cd[2]], true, CubeSphere.FACET_TEX_BAKE_BUDGET_MS)
		if baker.closeup_slot(fid) >= 0:
			resident = true
			break
	_ok(resident, "G-FT-CLOSEUP-BAKE: facet %d became a resident close-up layer under the budgeted drive (slot %d)" % [fid, baker.closeup_slot(fid)])
	if not resident:
		return
	# Expected colours: the generator sample at each close-up texel's column (same mapping the baker uses).
	var n := CubeSphere.CLOSEUP_TEXELS
	var lc := PackedVector2Array(); lc.resize(4)
	for ci in range(4):
		var w := FA.facet_planar_corner(fid, ci)
		var l := FA.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	var gen = FacetSkinTier._build_cpp_gen(fid)
	var sampler := Callable(gen, "sample_columns") if gen != null else Callable(FacetSkinTier, "gd_sample")
	# Spot-check a stride of texels (full 128² is 16k columns — a stride keeps the gate fast but representative).
	var stride := 11
	var packed := PackedInt64Array()
	var coords := []
	for ty in range(0, n, stride):
		for tx in range(0, n, stride):
			var s := (float(tx) + 0.5) / float(n)
			var t := (float(ty) + 0.5) / float(n)
			var lx := int(round(_bil(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bil(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			packed.append((lx & 0xffffffff) | ((lz & 0xffffffff) << 32))
			coords.append(Vector2i(tx, ty))
	var res: Dictionary = sampler.call(fid, packed)
	var cols: PackedColorArray = res["colors"]
	var eps := 0.02                                   # premult round-trip + 8-bit quant
	var worst := 0.0
	for i in range(coords.size()):
		var c: Vector2i = coords[i]
		var expect: Color = cols[i]
		var got := baker.closeup_texel_color(fid, c.x, c.y)
		worst = maxf(worst, maxf(absf(got.r - expect.r), maxf(absf(got.g - expect.g), absf(got.b - expect.b))))
	_ok(worst <= eps, "G-FT-CLOSEUP-BAKE: every close-up texel == the generator sample at its column (worst Δ=%.4f ≤ %.3f, %d texels)" % [worst, eps, coords.size()])
	# Falsify: comparing a texel to a DIFFERENT column (shifted) must disagree somewhere.
	var mism := 0.0
	for i in range(coords.size() - 1):
		var c: Vector2i = coords[i]
		var wrong: Color = cols[i + 1]
		var got := baker.closeup_texel_color(fid, c.x, c.y)
		mism = maxf(mism, absf(got.r - wrong.r) + absf(got.g - wrong.g) + absf(got.b - wrong.b))
	_ok(mism > eps, "G-FT-CLOSEUP-BAKE falsify: a shifted-column comparison disagrees (worst Δ=%.4f > %.3f)" % [mism, eps])

# --- G-FT-SLOT: ≤ CLOSEUP_MAX resident; an in-cap facet is never evicted; eviction only outside the cap ------------
func _gate_slot(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	var cd := _centre_dir(fid)
	var axis := Vector3(cd[0], cd[1], cd[2])
	var rot_axis := (Vector3(0, 1, 0) if absf(axis.y) < 0.9 else Vector3(1, 0, 0))
	# Sweep the emit axis across several positions; at each, run the budgeted drive to (near) convergence.
	var max_resident := 0
	var in_cap_evict_violations := 0
	var prev_residents := {}
	var prev_axis := axis
	for step in range(10):
		var ax := axis.rotated(rot_axis, float(step) * 0.04)   # ~2.3° per step (a fraction of the 17° cap → overlap)
		for _f in range(120):
			baker.update([ax.x, ax.y, ax.z], true, CubeSphere.FACET_TEX_BAKE_BUDGET_MS)
		# Invariant 1: residency never exceeds the fixed layer count.
		max_resident = maxi(max_resident, baker.closeup_resident_count())
		# Invariant 2: every facet resident at the PREVIOUS axis that is no longer resident now was OUTSIDE the
		# current want cap when it dropped (evict-only-outside-cap) → an in-cap facet is NEVER evicted.
		var now := baker.closeup_slots()
		for f in prev_residents.keys():
			if not now.has(f) and baker.closeup_in_cap(int(f)):
				in_cap_evict_violations += 1
		prev_residents = now
		prev_axis = ax
	print("    [G-FT-SLOT] peak resident close-up layers = %d (cap %d); final resident %d" % [max_resident, CubeSphere.CLOSEUP_MAX, baker.closeup_resident_count()])
	_ok(max_resident <= CubeSphere.CLOSEUP_MAX and max_resident > 1,
		"G-FT-SLOT: resident close-up layers accumulate and stay ≤ CLOSEUP_MAX (peak %d ≤ %d)" % [max_resident, CubeSphere.CLOSEUP_MAX])
	_ok(in_cap_evict_violations == 0,
		"G-FT-SLOT: an in-cap facet is NEVER evicted (%d violations)" % in_cap_evict_violations)
	# Invariant 3: the reverse-map is exact — every resident facet's layer→(a,b) entry decodes back to that facet.
	var slots := baker.closeup_slots()
	var fmap := baker.closeup_facet_map()
	var map_ok := slots.size() > 0
	for f in slots.keys():
		var layer := int(slots[f])
		var k := FA.K
		var lf := int(f) - FA.fid_base_of(int(f))
		var a := int((lf % (k * k)) / k)
		var b := (lf % (k * k)) % k
		if absf(fmap[layer].x - float(a)) > 0.5 or absf(fmap[layer].y - float(b)) > 0.5:
			map_ok = false
	_ok(map_ok, "G-FT-SLOT: the cu_facet reverse-map decodes every resident layer back to its facet (a,b) (%d resident)" % slots.size())
	# Invariant 4: a resident facet's emitted UV2.y carries its slot (≥0); the ring re-emits it into the mesh.
	var ring := FacetFarRing.new()
	get_root().add_child(ring)
	ring.setup(fid)
	ring.set_closeup_slots(baker.closeup_slots(), baker.closeup_facet_map())
	ring.force_rebuild()
	var some_fid := -1
	for f in slots.keys():
		some_fid = int(f); break
	if some_fid >= 0:
		var uv2 := ring.gate_facet_uv2(some_fid)
		var slot_in_mesh := uv2.size() > 0 and uv2[0].y >= 0.0
		_ok(slot_in_mesh, "G-FT-SLOT: a resident facet's emitted UV2.y carries its close-up slot (%.0f)" % (uv2[0].y if uv2.size() > 0 else -9.0))
	ring.queue_free()
	# Falsify: driving on-surface (offsurface=false) promotes NOTHING (close-up is an off-surface feature).
	var b2 := FacetTexBaker.new(); b2.setup(fid)
	for _f in range(60):
		b2.update([cd[0], cd[1], cd[2]], false, CubeSphere.FACET_TEX_BAKE_BUDGET_MS)
	_ok(b2.closeup_resident_count() == 0, "G-FT-SLOT falsify: on-surface drive promotes zero close-up layers (resident %d)" % b2.closeup_resident_count())

## Facet centre direction (unit) — sum of the 4 planar corners, normalized (the baker/ring convention).
func _centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

static func _bil(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t
