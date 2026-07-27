extends SceneTree
## COSMOS TEXTURED-LOD §2V V2 gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.1: FP_BAND_SHOT). Runs with FACETED = true
## (FLAT_WORLD = true) and FP_FACET_TEX + FP_SHELL_ABSOLUTE + FP_BLOCK_DETAIL + FP_BAND_BLOCK_MAP + FP_BAND_SHOT
## sed-toggled ON. Certifies the band renders the REAL top-down SHOT (RG8 {id, shade}, incl TREES + baked depth) rather
## than the U1 L8 id-only reconstruction. Three falsifiable gate families:
##   G-VS-SHOT  — the band fragment reconstruction == the analytic shot at sampled texels. Concretely: the RG8 band's
##                stored R (=block_id) and G (=shade) EXACTLY round-trip SurfaceShot.surface_shot(fid, column) across a
##                spread of texels (id exact; shade within RG8 quantization 1/255), so the shader composite
##                `col · detail_tile[id] · 2 · shade` (which G-VS-OFF pins as the ONLY additive change to the U1 branch)
##                equals `tile[surface_shot.id] × tint × shade`. TREES appear: a known tree column's band texel carries
##                the canopy id (== surface_shot's composited tree id), which DIFFERS from the bare-terrain classifier
##                id — the falsification that the band genuinely composites decorations (salting the hash / perturbing
##                shade would break the exact round-trip these assert).
##   G-VS-BYTES — the RG8 band ledger == the fixed arithmetic (BAND_LAYERS+1)·512²·2 B = EXACTLY 2 B/block = 2× the L8
##                band, ≤ BAND_SHOT_BYTES_MAX, and the whole baker total ≤ the §2V combined ceiling (46 MB).
##   G-VS-OFF   — FP_BAND_SHOT forced off ⇒ the shader band branch is BYTE-IDENTICAL to the U1 L8 band branch (the shade
##                multiply is additive-only, appearing only in the forced-on form); the baker band format is L8 and its
##                ledger is the L8 arithmetic. The live shipped shader string is the correct one for this run's flag.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const FST := preload("res://src/world/facet_skin_tier.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_band_shot (TEXTURED-LOD §2V V2 / FP_BAND_SHOT) ===")
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
	TreeGen.warm_up()

	var tex_on := CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE
	var bd_on := CubeSphere.FP_BLOCK_DETAIL
	var bm_on := CubeSphere.FP_BAND_BLOCK_MAP
	var shot_on := CubeSphere.FP_BAND_SHOT
	print("  flags FP_FACET_TEX=%s FP_BLOCK_DETAIL=%s FP_BAND_BLOCK_MAP=%s FP_BAND_SHOT=%s"
		% [str(tex_on), str(bd_on), str(bm_on), str(shot_on)])

	# Pick a facet that actually carries trees so the decoration path is EXERCISED (home first, then a per-face sweep).
	var picked := _find_forested_facet()
	var fid: int = picked["fid"]
	TC.set_active_facet(fid)
	print("  test facet=%d (K=%d): %d tree base columns in sample" % [fid, FA.K, picked["trees"].size()])

	_gate_off(fid, tex_on, bd_on, bm_on, shot_on)
	if tex_on and bd_on and bm_on and shot_on:
		_gate_shot(fid, picked)
		_gate_bytes(fid)
	else:
		print("  (shot path OFF — G-VS-SHOT/BYTES need FP_FACET_TEX && FP_BLOCK_DETAIL && FP_BAND_BLOCK_MAP && FP_BAND_SHOT; OFF-identity by G-VS-OFF)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- geometry helpers (the SAME lattice mapping FacetTexBaker._bm_compute_slice_shot uses) ---------------------
func _facet_lc(fid: int) -> PackedVector2Array:
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var w := FA.facet_planar_corner(fid, ci)
		var l := FA.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	return lc

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

static func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)

## The lattice column (lx,lz) a band block (bx,by) samples — identical to the baker's per-slice mapping.
func _lattice_of(lc: PackedVector2Array, bx: int, by: int, nx: int, ny: int) -> Vector2i:
	var s := (float(bx) + 0.5) / float(nx)
	var t := (float(by) + 0.5) / float(ny)
	var lx := int(round(_bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)))
	var lz := int(round(_bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)))
	return Vector2i(lx, lz)

## The BARE-terrain classifier id at column (x,z) — surface_shot WITHOUT the tree composite (the U1 L8 band value). The
## divergence from surface_shot's id at a tree column is the "trees appear" proof.
func _bare_terrain_id(fid: int, x: int, z: int, ctx) -> int:
	var res: Dictionary = FST.gd_sample(fid, PackedInt64Array([_pack_xz(x, z)]))
	return FarPalette.detail_pattern((res["colors"] as PackedColorArray)[0]) + 1

## Pump the band bake until the active facet is resident (or a bounded number of updates elapse). Each update pays one
## FACET_TEX_BAKE budget (100 ms here) worth of row-slices; the SHOT path's per-column surface_shot needs several.
func _bake_active(baker: FacetTexBaker, fid: int) -> void:
	for _i in range(20):
		baker.update([2.0, 0.0, 0.0], false, 60000000.0, fid)   # a large budget → one update bakes the whole active facet
		if baker.band_slot(fid) >= 0:
			return

# --- G-VS-SHOT: RG8 {id, shade} round-trips surface_shot; trees appear; falsifiable ---------------------------
func _gate_shot(fid: int, picked: Dictionary) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	# Drive the row-sliced band bake to completion. The SHOT bake is per-column GDScript surface_shot (heavier than the
	# U1 C++ sampler), so pump update() until the active facet is resident (bounded loop; each update pays one budget).
	_bake_active(baker, fid)
	_ok(baker.band_on() and baker.band_shot_on() and baker.band_texture() != null,
		"G-VS-SHOT: the band tier built its RG8 {id,shade} shot map (band_shot_on)")
	_ok(baker.band_slot(fid) >= 0, "G-VS-SHOT: the active facet is a RESIDENT band facet (slot %d)" % baker.band_slot(fid))

	var nxy := baker.band_n_of(fid)
	var nx := int(nxy.x); var ny := int(nxy.y)
	_ok(nx >= 1 and ny >= 1, "G-VS-SHOT: band block counts (Nx=%d,Ny=%d) valid" % [nx, ny])
	var lc := _facet_lc(fid)
	var ctx = TC.GenCtx.new(0, fid)

	# F2 WATCH (§2V.6): the SHOT bake's per-slice tree/shade pass is GDScript surface_shot (heavier than the U1 C++
	# sampler). Time ONE slice's worth (BAND_SLICE_ROWS × Nx surface_shot) so the report carries the real per-slice cost
	# vs the 2 ms bake-unit budget — informational (the shipped bake runs on the TH1 WORKER, so this is worker latency,
	# not a main-frame hitch; the C++ mirror is the design's v2 knob if the on-main path needs it).
	var slice_rows := mini(CubeSphere.BAND_SLICE_ROWS, ny)
	var t0 := Time.get_ticks_usec()
	var _sink := 0.0
	for ry in range(slice_rows):
		for bx in range(nx):
			var c := _lattice_of(lc, bx, ry, nx, ny)
			_sink += float(SurfaceShot.surface_shot(fid, c.x, c.y, ctx)["shade"])
	var slice_us := Time.get_ticks_usec() - t0
	print("  F2 tree/shade bake cost: one %d-row slice (%d cols) = %.2f ms (%.2f us/col, Nx=%d) — budget 2 ms/unit"
		% [slice_rows, slice_rows * nx, float(slice_us) / 1000.0, float(slice_us) / float(maxi(1, slice_rows * nx)), nx])

	# (1) an 11×11 spread of texels: stored R == surface_shot.block_id (exact), stored G ≈ surface_shot.shade (≤ 1/255).
	var id_ok := true
	var shade_ok := true
	var id_worst := ""
	var shade_worst := ""
	var shade_lt1 := false
	var steps := 11
	for iy in range(steps):
		var by := (iy * (ny - 1)) / (steps - 1) if ny > 1 else 0
		for ix in range(steps):
			var bx := (ix * (nx - 1)) / (steps - 1) if nx > 1 else 0
			var col := _lattice_of(lc, bx, by, nx, ny)
			var rec := SurfaceShot.surface_shot(fid, col.x, col.y, ctx)
			var want_id := int(rec["block_id"])
			var want_sh := float(rec["shade"])
			var got_id := baker.band_id_at(fid, bx, by)
			var got_sh := baker.band_shade_at(fid, bx, by)
			if got_id != want_id:
				id_ok = false
				id_worst = "blk(%d,%d)@col(%d,%d) got %d want %d" % [bx, by, col.x, col.y, got_id, want_id]
			if absf(got_sh - want_sh) > 1.5 / 255.0:
				shade_ok = false
				shade_worst = "blk(%d,%d) got %.4f want %.4f" % [bx, by, got_sh, want_sh]
			if want_sh < 0.999:
				shade_lt1 = true
	_ok(id_ok, "G-VS-SHOT: every sampled band R == surface_shot.block_id (the real shot id) %s" % ("" if id_ok else "— " + id_worst))
	_ok(shade_ok, "G-VS-SHOT: every sampled band G == surface_shot.shade within RG8 quantization %s" % ("" if shade_ok else "— " + shade_worst))
	_ok(shade_lt1, "G-VS-SHOT: the baked shade actually varies (≥ 1 texel reads < 1.0 — AO/depth cues bite, not a constant)")

	# (2) TREES appear: find band texels whose lattice column is a tree canopy/trunk; the stored id == surface_shot's
	# composited tree id AND DIFFERS from the bare-terrain classifier id (the band genuinely composites decorations).
	var tree_texels := 0
	var tree_id_ok := true
	var tree_differs := false
	var cx := nx / 2
	var cy := ny / 2
	var rad := 100
	for dy in range(-rad, rad + 1):
		var by := cy + dy
		if by < 0 or by >= ny:
			continue
		for dx in range(-rad, rad + 1):
			var bx := cx + dx
			if bx < 0 or bx >= nx:
				continue
			var col := _lattice_of(lc, bx, by, nx, ny)
			if TreeGen.top_decoration(col.x, col.y, ctx) == BlockCatalog.AIR:
				continue
			var rec := SurfaceShot.surface_shot(fid, col.x, col.y, ctx)
			var want_id := int(rec["block_id"])
			var got_id := baker.band_id_at(fid, bx, by)
			var bare := _bare_terrain_id(fid, col.x, col.y, ctx)
			if got_id != want_id:
				tree_id_ok = false
			if want_id != bare:
				tree_differs = true
			tree_texels += 1
			if tree_texels >= 12 and tree_differs:
				break
		if tree_texels >= 12 and tree_differs:
			break
	_ok(tree_texels >= 1, "G-VS-SHOT: at least one TREE canopy/trunk texel landed in the band (found %d)" % tree_texels)
	_ok(tree_id_ok, "G-VS-SHOT: every tree texel's stored band id == surface_shot's composited canopy/trunk id (trees are IN the shot)")
	_ok(tree_differs, "G-VS-SHOT falsify: a tree texel's band id DIFFERS from the bare-terrain classifier id (decorations genuinely change the stored shot, not terrain-only)")

	# (3) falsify the shade round-trip: a deliberately perturbed shade does NOT match the stored G (the gate is falsifiable).
	var pbx := clampi(cx, 0, nx - 1)
	var pby := clampi(cy, 0, ny - 1)
	var pcol := _lattice_of(lc, pbx, pby, nx, ny)
	var prec := SurfaceShot.surface_shot(fid, pcol.x, pcol.y, ctx)
	var pshade := float(prec["shade"])
	_ok(absf(baker.band_shade_at(fid, pbx, pby) - clampf(pshade + 0.1, 0.0, 1.0)) > 1.5 / 255.0
			or absf(pshade - clampf(pshade + 0.1, 0.0, 1.0)) < 1.0e-6,
		"G-VS-SHOT falsify: a perturbed shade (+0.1) fails the stored-G compare (the shade is genuinely surface_shot's)")

# --- G-VS-BYTES: RG8 ledger arithmetic, 2 B/block, ≤ ceilings ------------------------------------------------
func _gate_bytes(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	# The band ledger is FIXED at setup (BAND_LAYERS × 512² × bpp + one staging) — bake progress does not change it.
	var bm_px := CubeSphere.BAND_TEXELS * CubeSphere.BAND_TEXELS
	var expect_rg8 := (CubeSphere.BAND_LAYERS + 1) * bm_px * 2       # (9 GPU layers + 1 staging) × 512² × 2 B
	var expect_l8 := (CubeSphere.BAND_LAYERS + 1) * bm_px           # the U1 L8 arithmetic
	_ok(baker.band_bytes() == expect_rg8,
		"G-VS-BYTES: RG8 band ledger == (BAND_LAYERS+1)·512²·2 = %d B (%.2f MB)" % [expect_rg8, float(expect_rg8) / 1048576.0])
	_ok(baker.band_bytes() == 2 * (CubeSphere.BAND_LAYERS + 1) * bm_px,
		"G-VS-BYTES: EXACTLY 2 B/block (the {id,shade} pair) — 2× the L8 band")
	_ok(baker.band_bytes() <= CubeSphere.BAND_SHOT_BYTES_MAX,
		"G-VS-BYTES: RG8 band tier ≤ BAND_SHOT_BYTES_MAX (%.2f MB ≤ %.2f MB)"
			% [float(baker.band_bytes()) / 1048576.0, float(CubeSphere.BAND_SHOT_BYTES_MAX) / 1048576.0])
	var ceil46 := 46 * 1024 * 1024
	_ok(baker.total_bytes() <= ceil46,
		"G-VS-BYTES: whole baker total ≤ the §2V combined ceiling (%.2f MB ≤ 46 MB)" % [float(baker.total_bytes()) / 1048576.0])
	_ok(baker.band_bytes() != expect_l8, "G-VS-BYTES falsify: the RG8 ledger is NOT the L8 arithmetic (it grew to 2 B/block)")

# --- G-VS-OFF: shot off ≡ U1 L8 band branch (shade multiply is additive-only); L8 format + ledger off ---------
func _gate_off(fid: int, tex_on: bool, bd_on: bool, bm_on: bool, shot_on: bool) -> void:
	if not (tex_on and bd_on and bm_on):
		return   # the shot injection only exists atop the FP_BAND_BLOCK_MAP band branch; nothing to compare without it
	# Build the band branch with shot FORCED off (the U1 L8 form) and FORCED on (the RG8 shade-multiply form).
	var band_off := FacetFarRing.gate_band_shader(false, true, false)
	var band_on := FacetFarRing.gate_band_shader(false, true, true)
	var band_off_cu := FacetFarRing.gate_band_shader(true, true, false)
	var band_on_cu := FacetFarRing.gate_band_shader(true, true, true)
	# Zero new compiled programs: exactly ONE shader_type per string in BOTH shot-on and shot-off forms.
	_ok(band_off.count("shader_type") == 1 and band_on.count("shader_type") == 1
		and band_off_cu.count("shader_type") == 1 and band_on_cu.count("shader_type") == 1,
		"G-VS-OFF: exactly ONE shader_type per shell string shot-on/off (zero new compiled programs)")
	# Shot FORCED off is BYTE-IDENTICAL to the U1 band branch: it reads the single .r channel, with NO {id,shade} pair
	# read (`_rg =`) and NO shade multiply (`_rg.g`). (Guard against `.rgb` in the tiled path by testing the shot tokens.)
	_ok(band_off.contains("int _bid = int(texelFetch(band_map, ivec3(_ib, _bs), 0).r * 255.0 + 0.5);")
		and not band_off.contains("_rg = texelFetch") and not band_off.contains("_rg.g"),
		"G-VS-OFF: shot-off band branch is the U1 L8 form (reads .r only, no {id,shade} pair, no shade multiply)")
	# Shot FORCED on is ADDITIVE: it differs, reads BOTH channels (.rg), and multiplies the shade byte (_rg.g) into the face.
	_ok(band_on != band_off and band_on_cu != band_off_cu, "G-VS-OFF(ON): the shot injection changed the band branch (additive)")
	_ok(band_on.contains("texelFetch(band_map, ivec3(_ib, _bs), 0).rg")
		and band_on.contains("* 2.0 * _rg.g"),
		"G-VS-OFF(ON): shot-on band branch reads .rg and multiplies detail_tile[id]·tint by the baked shade (_rg.g)")
	# The far-far ELSE tiled path is untouched (present verbatim in BOTH forms) — only the band-facet branch gained shade.
	_ok(band_on.contains("vec3 _face = col * texture(detail_map, vec3(v_uv * DETAIL_PAGE, float(_mid))).rgb * 2.0;")
		and band_off.contains("vec3 _face = col * texture(detail_map, vec3(v_uv * DETAIL_PAGE, float(_mid))).rgb * 2.0;"),
		"G-VS-OFF: the far-far tiled ELSE path is byte-identical in shot-on/off (only the band-facet branch changed)")
	# The shot-on shader PARSES (catch a syntax slip in the splice): the band uniforms still register.
	var sh := Shader.new()
	sh.code = band_on
	var unames := {}
	for u in sh.get_shader_uniform_list():
		unames[String(u.get("name", ""))] = true
	_ok(unames.has("band_map") and unames.has("detail_map") and unames.has("base_map"),
		"G-VS-OFF(ON): the shot-injected shader PARSES — band_map/detail_map/base_map uniforms register")
	# The LIVE shipped shell string is the correct one for THIS run's flag (the default-param path production uses).
	if shot_on:
		_ok(FacetFarRing.gate_band_shader(false, true) == band_on and FacetFarRing.gate_band_shader(true, true) == band_on_cu,
			"G-VS-OFF: runtime flag ON ⇒ the live band branch IS the shot (RG8) form")
	else:
		_ok(FacetFarRing.gate_band_shader(false, true) == band_off and FacetFarRing.gate_band_shader(true, true) == band_off_cu,
			"G-VS-OFF: runtime flag OFF ⇒ the live band branch is BYTE-IDENTICAL to the U1 L8 form")
	# RUNTIME flag off ⇒ the baker builds an L8 band (not RG8) with the L8 ledger (byte-identical, +0 shot bytes).
	if not shot_on:
		var baker := FacetTexBaker.new()
		baker.setup(fid)
		var bm_px := CubeSphere.BAND_TEXELS * CubeSphere.BAND_TEXELS
		_ok(not baker.band_shot_on() and (not baker.band_on() or baker.band_bytes() == (CubeSphere.BAND_LAYERS + 1) * bm_px),
			"G-VS-OFF: runtime flag off ⇒ band is L8 (band_shot_on false, ledger is the L8 arithmetic)")

# --- forested-facet + tree/bare column selection (mirrors verify_shot_prep) -----------------------------------
func _find_forested_facet() -> Dictionary:
	var home := FA.spawn_facet()
	var candidates: PackedInt32Array = PackedInt32Array([home])
	for face in range(6):
		candidates.append(face * FA.K * FA.K + (FA.K / 2) * FA.K + (FA.K / 2))
	for fid in candidates:
		TC.set_active_facet(fid)
		var got := _collect_columns(fid)
		if got["trees"].size() >= 1:
			got["fid"] = fid
			return got
	TC.set_active_facet(home)
	var g := _collect_columns(home)
	g["fid"] = home
	return g

func _collect_columns(fid: int) -> Dictionary:
	var lc := _facet_lc(fid)
	var cx := int(round((lc[0].x + lc[1].x + lc[2].x + lc[3].x) * 0.25))
	var cz := int(round((lc[0].y + lc[1].y + lc[2].y + lc[3].y) * 0.25))
	var gx0 := floori(float(cx) / float(TreeGen.G))
	var gz0 := floori(float(cz) / float(TreeGen.G))
	var trees: Array = []
	for dgz in range(-24, 25):
		for dgx in range(-24, 25):
			var gx := gx0 + dgx
			var gz := gz0 + dgz
			if TreeGen.has_tree(gx, gz):
				if trees.size() < 24:
					var tb := TreeGen.tree_base(gx, gz)
					trees.append(Vector2i(tb.x, tb.z))
		if trees.size() >= 24:
			break
	return {"trees": trees}
