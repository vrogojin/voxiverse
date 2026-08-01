extends SceneTree
## COSMOS TEXTURED-LOD V3 gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.1/§2V.5: FP_PAGES_SHOT). Runs with FACETED =
## true (FLAT_WORLD = true) and FP_FACET_TEX + FP_PAGES_SHOT (+ optionally FP_FACET_TEX_CLOSEUP) sed-toggled ON.
## Proves the base + close-up PAGE bake is rebaked as a true box-downscale of the REAL surface shot instead of the
## FarPalette biome-colour average, WITHOUT changing the g0 boot path:
##   G-VP-OFF        — the g0 (palette) bake path is byte-identical to the shipped bake (the added shot branch never
##                     touches g0); flag/force OFF ⇒ NO facet is ever shot-baked. Falsify: forcing shot ON re-bakes
##                     the same facet to a DIFFERENT (shot) page.
##   G-VP-DOWNSCALE  — a shot page texel == the box-mean of SurfaceShot.surface_shot samples within its footprint
##                     (ε = 8-bit quant), deterministic across two bakes, and DIFFERS from the old FarPalette biome
##                     colour where the terrain has sub-facet variation (trees / static shade). Falsify: a shifted
##                     footprint disagrees.
##   G-VP-BOOT       — with g0/g1, prewarm (boot) bakes ONLY g0 (palette) — the boot page == the palette box-average
##                     and NO facet is shot yet (boot timing/bytes unchanged); the background g1 cursor then converges
##                     covered facets to the shot over subsequent update()s, bounded per frame.
## Each assertion is perturbed and confirmed to FAIL, per the falsifiability contract.

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_pages_shot (TEXTURED-LOD V3 FP_PAGES_SHOT) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true) — sed-toggled.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TerrainConfig.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	var fid := FA.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	var shot_on := CubeSphere.FP_FACET_TEX and CubeSphere.FP_PAGES_SHOT
	print("  flags FP_FACET_TEX=%s FP_PAGES_SHOT=%s FP_FACET_TEX_CLOSEUP=%s, spawn facet=%d (K=%d, R=%d)" %
		[str(CubeSphere.FP_FACET_TEX), str(CubeSphere.FP_PAGES_SHOT), str(CubeSphere.FP_FACET_TEX_CLOSEUP), fid, FA.K, int(FA.R_BLOCKS)])

	# G-VP-OFF runs unconditionally: the g0 (palette) path is exercised via bake_facet (flag-independent) and must
	# match the shipped palette box-average; the force hook then proves the shot path is a genuinely different page.
	_gate_off(fid)
	if shot_on:
		_gate_downscale(fid)
		_gate_boot(fid)
		if CubeSphere.FP_FACET_TEX_CLOSEUP:
			_gate_closeup(fid)
		else:
			print("  (close-up shot sub-check OFF — needs FP_FACET_TEX_CLOSEUP ON)")
	else:
		print("  (shot path OFF — G-VP-DOWNSCALE/BOOT need FP_FACET_TEX && FP_PAGES_SHOT ON; g0 byte-identity by G-VP-OFF)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-VP-OFF: the g0 (palette) bake is byte-identical to the shipped bake; OFF ⇒ never shot-baked ----------
func _gate_off(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker._gate_set_shot(false)                     # force the shot generation OFF regardless of the sed flag
	baker.bake_facet(fid)                            # g0 — the palette path
	# The g0 page == the 2×2 box-average of sample_fine's FarPalette colours (the shipped bake, unchanged).
	var eps := 0.01
	var worst := _worst_vs_palette(baker, fid)
	_ok(worst <= eps, "G-VP-OFF: the g0 (palette) page == the shipped FarPalette box-average (worst Δ=%.4f ≤ %.3f)" % [worst, eps])
	_ok(not baker.shot_on() and baker.shot_baked_count() == 0,
		"G-VP-OFF: shot forced OFF ⇒ shot_on false and NO facet shot-baked (%d)" % baker.shot_baked_count())
	# Driving update() on-surface with shot OFF must never shot-bake (pure coverage/g0).
	var cd := _centre_dir(fid)
	for _f in range(30):
		baker.update([cd[0], cd[1], cd[2]], false, CubeSphere.FACET_TEX_BAKE_BUDGET_MS)
	_ok(baker.shot_baked_count() == 0, "G-VP-OFF: an on-surface drive with shot OFF shot-bakes nothing (%d)" % baker.shot_baked_count())

	# Falsify: forcing shot ON and re-baking the SAME facet produces a DIFFERENT (shot) page somewhere — proving the
	# shot path is not a no-op alias of the palette path.
	var b2 := FacetTexBaker.new()
	b2.setup(fid)
	b2._gate_set_shot(true)
	b2.bake_facet_shot(fid)
	var diff := 0.0
	var bt := FacetTexBaker.BASE_TEXELS
	for ty in range(bt):
		for tx in range(bt):
			var pc := baker.texel_color(fid, tx, ty)
			var sc := b2.texel_color(fid, tx, ty)
			diff = maxf(diff, absf(pc.r - sc.r) + absf(pc.g - sc.g) + absf(pc.b - sc.b))
	_ok(diff > 0.02, "G-VP-OFF falsify: the shot page differs from the palette page (worst Δ=%.4f > 0.02) — trees/shade change the picture" % diff)

# --- G-VP-DOWNSCALE: a shot page texel == the box-mean of surface_shot within its footprint ------------------
func _gate_downscale(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker._gate_set_shot(true)
	baker.bake_facet_shot(fid)
	# The expected value: the SAME BAKE_SRC² fine shot grid the baker box-averages (sample_fine_shot is public + pure).
	var sh := baker.sample_fine_shot(fid)
	var appear: PackedColorArray = sh[0]
	var bs := FacetTexBaker.BAKE_SRC
	var bt := FacetTexBaker.BASE_TEXELS
	var down := FacetTexBaker.DOWNS
	var inv := 1.0 / float(down * down)
	var eps := 0.01
	var worst := 0.0
	for ty in range(bt):
		for tx in range(bt):
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + tx * down
				for sx in range(down):
					var c: Color = appear[row + sx]
					r += c.r; g += c.g; b += c.b
			var expect := Color(r * inv, g * inv, b * inv, 1.0)
			var got := baker.texel_color(fid, tx, ty)
			worst = maxf(worst, maxf(absf(got.r - expect.r), maxf(absf(got.g - expect.g), absf(got.b - expect.b))))
	_ok(worst <= eps, "G-VP-DOWNSCALE: every shot texel == the box-mean of surface_shot in its footprint (worst Δ=%.4f ≤ %.3f)" % [worst, eps])

	# Falsify: a SHIFTED (+1 texel) box-average is a different block region → must disagree somewhere.
	var mism := 0.0
	for ty in range(bt - 1):
		for tx in range(bt - 1):
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + (tx + 1) * down
				for sx in range(down):
					var c: Color = appear[row + sx]
					r += c.r; g += c.g; b += c.b
			var got := baker.texel_color(fid, tx, ty)
			mism = maxf(mism, absf(got.r - r * inv) + absf(got.g - g * inv) + absf(got.b - b * inv))
	_ok(mism > eps, "G-VP-DOWNSCALE falsify: a shifted box-average disagrees (worst Δ=%.4f > %.3f)" % [mism, eps])

	# Determinism: two independent shot bakes → identical stored texels.
	var b2 := FacetTexBaker.new()
	b2.setup(fid)
	b2._gate_set_shot(true)
	b2.bake_facet_shot(fid)
	var det := true
	for ty in range(bt):
		for tx in range(bt):
			if baker.texel_color(fid, tx, ty) != b2.texel_color(fid, tx, ty):
				det = false
	_ok(det, "G-VP-DOWNSCALE: the shot bake is deterministic across two independent bakes of facet %d" % fid)

	# DIFFERS from the old FarPalette biome colour: scan facets around the globe; the shot page (tint × static-shade
	# incl trees) must diverge from the palette page by more than ε somewhere (sub-facet variation is not one colour).
	var total := 6 * FA.K * FA.K
	var max_div := 0.0
	var div_facet := -1
	for i in range(12):
		var f := (i * total) / 12
		var pal := FacetTexBaker.new(); pal.setup(f); pal._gate_set_shot(false); pal.bake_facet(f)
		var sho := FacetTexBaker.new(); sho.setup(f); sho._gate_set_shot(true); sho.bake_facet_shot(f)
		for ty in range(bt):
			for tx in range(bt):
				var pc := pal.texel_color(f, tx, ty)
				var sc := sho.texel_color(f, tx, ty)
				var dd := absf(pc.r - sc.r) + absf(pc.g - sc.g) + absf(pc.b - sc.b)
				if dd > max_div:
					max_div = dd; div_facet = f
	_ok(max_div > 0.02, "G-VP-DOWNSCALE: the shot blend differs from the FarPalette biome colour (worst Δ=%.4f > 0.02 at facet %d)" % [max_div, div_facet])

# --- G-VP-BOOT: prewarm bakes ONLY g0 (palette); the g1 cursor converges the shot afterwards -----------------
func _gate_boot(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker._gate_set_shot(true)                       # shot ON, yet prewarm must stay g0 (the boot-safety split)
	baker.prewarm(PackedInt32Array([fid]))           # the boot bake path (production runs this behind the load hold)
	# (1) boot page == the palette box-average, NOT the shot — i.e. prewarm never shot-baked.
	var eps := 0.01
	var worst_pal := _worst_vs_palette(baker, fid)
	_ok(worst_pal <= eps, "G-VP-BOOT: the prewarm (boot) page == the palette box-average (worst Δ=%.4f ≤ %.3f) — boot unchanged" % [worst_pal, eps])
	_ok(baker.shot_baked_count() == 0, "G-VP-BOOT: prewarm shot-bakes NOTHING (%d) — boot is g0-only" % baker.shot_baked_count())
	# (2) the boot page DIFFERS from the shot the g1 cursor will later produce (proving it is g0, not g1).
	var shot_avg := _shot_box_avg(baker, fid)
	var boot_div := 0.0
	var bt := FacetTexBaker.BASE_TEXELS
	for ty in range(bt):
		for tx in range(bt):
			var g0 := baker.texel_color(fid, tx, ty)
			var g1: Color = shot_avg[ty * bt + tx]
			boot_div = maxf(boot_div, absf(g0.r - g1.r) + absf(g0.g - g1.g) + absf(g0.b - g1.b))
	_ok(boot_div > 0.02, "G-VP-BOOT: the boot (g0) page differs from the shot (g1) the cursor will converge to (Δ=%.4f > 0.02)" % boot_div)

	# (3) drive update() on-surface (close-up inert): the g1 cursor must shot-bake covered facets over time (nearest-axis
	# first ⇒ the spawn facet upgrades early), and the spawn facet's page must CONVERGE to the shot box-average. (Per-frame
	# WALL boundedness of a whole-facet shot unit is V4's G-VD-BUDGET domain — a GDScript shot bake is heavy on the main
	# thread by design, F2; production runs the compute off-main on the TH1 worker.)
	var cd := _centre_dir(fid)
	var budget := CubeSphere.FACET_TEX_BAKE_BUDGET_MS
	var updates := 0
	for f in range(60):
		baker.update([cd[0], cd[1], cd[2]], false, budget)
		updates += 1
		if baker.is_shot_baked(fid):
			break
	_ok(baker.shot_baked_count() > 0, "G-VP-BOOT: the g1 cursor shot-bakes covered facets after boot (%d shot in %d updates)" % [baker.shot_baked_count(), updates])
	_ok(baker.is_shot_baked(fid), "G-VP-BOOT: the spawn facet became shot-covered under the g1 cursor drive (nearest-first)")
	# Check-before invariant: a 0-budget update starts NO shot unit (the cursor checks the budget line BEFORE each bake).
	var b0 := FacetTexBaker.new(); b0.setup(fid); b0._gate_set_shot(true); b0.prewarm(PackedInt32Array([fid]))
	b0.update([cd[0], cd[1], cd[2]], false, 0.0)
	_ok(b0.shot_baked_count() == 0, "G-VP-BOOT: a 0-budget update shot-bakes nothing (check-before, %d)" % b0.shot_baked_count())
	# Convergence: the spawn facet's page now == the shot box-average (g1 landed), not the palette any more.
	if baker.is_shot_baked(fid):
		var conv := 0.0
		for ty in range(bt):
			for tx in range(bt):
				var got := baker.texel_color(fid, tx, ty)
				var exp: Color = shot_avg[ty * bt + tx]
				conv = maxf(conv, maxf(absf(got.r - exp.r), maxf(absf(got.g - exp.g), absf(got.b - exp.b))))
		_ok(conv <= 0.02, "G-VP-BOOT: the spawn facet's page CONVERGED to the shot box-average (worst Δ=%.4f ≤ 0.02)" % conv)

	# Falsify: a shot generation that NEVER ran (fresh baker, no update) leaves shot_baked_count 0 — convergence is
	# driven by the cursor, not free.
	var b2 := FacetTexBaker.new(); b2.setup(fid); b2._gate_set_shot(true); b2.prewarm(PackedInt32Array([fid]))
	_ok(b2.shot_baked_count() == 0, "G-VP-BOOT falsify: without the cursor drive, nothing converges (shot %d)" % b2.shot_baked_count())

# --- close-up shot sub-check: a resident close-up layer's texels == surface_shot at its column (1:1) ---------
func _gate_closeup(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker._gate_set_shot(true)
	var cd := _centre_dir(fid)
	var resident := false
	for _f in range(500):
		baker.update([cd[0], cd[1], cd[2]], true, CubeSphere.FACET_TEX_BAKE_BUDGET_MS)
		if baker.closeup_slot(fid) >= 0:
			resident = true
			break
	_ok(resident, "G-VP-DOWNSCALE(close-up): facet %d became a resident close-up shot layer (slot %d)" % [fid, baker.closeup_slot(fid)])
	if not resident:
		return
	var n := CubeSphere.CLOSEUP_TEXELS
	var lc := PackedVector2Array(); lc.resize(4)
	for ci in range(4):
		var w := FA.facet_planar_corner(fid, ci)
		var l := FA.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	var pcache = TerrainConfig.GenCtx.new(0, fid) if CubeSphere.FACETED else null
	var stride := 11
	var eps := 0.02                                   # premult round-trip + 8-bit quant
	var worst := 0.0
	var cnt := 0
	for ty in range(0, n, stride):
		for tx in range(0, n, stride):
			var s := (float(tx) + 0.5) / float(n)
			var t := (float(ty) + 0.5) / float(n)
			var lx := int(round(_bil(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
			var lz := int(round(_bil(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
			var rec := SurfaceShot.surface_shot(fid, lx, lz, pcache)
			var tc: Color = rec["tint"]; var shf: float = rec["shade"]
			var expect := Color(tc.r * shf, tc.g * shf, tc.b * shf, 1.0)
			var got := baker.closeup_texel_color(fid, tx, ty)
			worst = maxf(worst, maxf(absf(got.r - expect.r), maxf(absf(got.g - expect.g), absf(got.b - expect.b))))
			cnt += 1
	_ok(worst <= eps, "G-VP-DOWNSCALE(close-up): every close-up texel == surface_shot (tint×shade) at its column (worst Δ=%.4f ≤ %.3f, %d texels)" % [worst, eps, cnt])

# --- helpers -------------------------------------------------------------------------------------

## The worst |texel - palette-box-average| over facet `fid`'s texels (the shipped FarPalette bake reference).
func _worst_vs_palette(baker: FacetTexBaker, fid: int) -> float:
	var fine := baker.sample_fine(fid)
	var bs := FacetTexBaker.BAKE_SRC
	var bt := FacetTexBaker.BASE_TEXELS
	var down := FacetTexBaker.DOWNS
	var inv := 1.0 / float(down * down)
	var worst := 0.0
	for ty in range(bt):
		for tx in range(bt):
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + tx * down
				for sx in range(down):
					var c: Color = fine[row + sx]
					r += c.r; g += c.g; b += c.b
			var expect := Color(r * inv, g * inv, b * inv, 1.0)
			var got := baker.texel_color(fid, tx, ty)
			worst = maxf(worst, maxf(absf(got.r - expect.r), maxf(absf(got.g - expect.g), absf(got.b - expect.b))))
	return worst

## The per-texel shot box-average for facet `fid` (BASE_TEXELS² Colors, row-major) — the g1 target.
func _shot_box_avg(baker: FacetTexBaker, fid: int) -> PackedColorArray:
	var sh := baker.sample_fine_shot(fid)
	var appear: PackedColorArray = sh[0]
	var bs := FacetTexBaker.BAKE_SRC
	var bt := FacetTexBaker.BASE_TEXELS
	var down := FacetTexBaker.DOWNS
	var inv := 1.0 / float(down * down)
	var out := PackedColorArray(); out.resize(bt * bt)
	for ty in range(bt):
		for tx in range(bt):
			var r := 0.0; var g := 0.0; var b := 0.0
			for sy in range(down):
				var row := (ty * down + sy) * bs + tx * down
				for sx in range(down):
					var c: Color = appear[row + sx]
					r += c.r; g += c.g; b += c.b
			out[ty * bt + tx] = Color(r * inv, g * inv, b * inv, 1.0)
	return out

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
