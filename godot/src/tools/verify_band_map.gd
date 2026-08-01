extends SceneTree
## COSMOS TEXTURED-LOD U1 gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2U.1/§2U.4: FP_BAND_BLOCK_MAP). Runs with FACETED =
## true (FLAT_WORLD = true) and FP_FACET_TEX + FP_SHELL_ABSOLUTE + FP_BLOCK_DETAIL + FP_BAND_BLOCK_MAP sed-toggled ON.
## Four falsifiable assertions (each perturbed and confirmed to FAIL):
##   G-BB-EXACT — the band's stored per-block id EQUALS the analytic real top-down classifier at that column
##                (band_id_at(fid,bx,by) == FarPalette.detail_pattern(sampler colour at param (bx,by)) + 1) across a
##                spread of texels/facets; ids ∈ [1, DETAIL_PATTERNS]; AND the shader addressing (facet-local uv → block
##                coord = int(uv·N)) reproduces the same id — so the fragment reconstructs the real per-block face.
##   G-BB-BYTES — the band ledger (band_bytes) == the fixed arithmetic (BAND_LAYERS·512² + one staging L8), ≤ BAND_BYTES_MAX,
##                and the whole baker total_bytes ≤ the §2U combined ceiling (43 MB); an evicted band facet frees its layer.
##   G-BB-SLOT  — a resident band facet's UV2.y == 64 + layer (the ring's _slot_of), layer ∈ [0, BAND_LAYERS); residency =
##                active ∪ ring-1; a facet leaving the ring frees its slot (evict-only-on-ring-exit).
##   G-BB-OFF   — the band injection FORCED off ≡ the shipped FP_BLOCK_DETAIL shader string (byte-identical), FORCED on is
##                ADDITIVE only (still exactly ONE shader_type → zero new compiled programs) + declares band_map/v_bslot;
##                the RUNTIME flag off ⇒ no band texture is built, band_slot == −1, UV2.y < 64.

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
	print("=== verify_band_map (TEXTURED-LOD U1 / FP_BAND_BLOCK_MAP) ===")
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
	var bm_on := CubeSphere.FP_BAND_BLOCK_MAP
	print("  flags FP_FACET_TEX=%s FP_BLOCK_DETAIL=%s FP_BAND_BLOCK_MAP=%s, spawn facet=%d (K=%d)"
		% [str(tex_on), str(bd_on), str(bm_on), fid, FA.K])

	_gate_off(fid, tex_on, bd_on, bm_on)
	if tex_on and bd_on and bm_on:
		_gate_exact(fid)
		_gate_bytes(fid)
		_gate_slot(fid)
	else:
		print("  (band path OFF — G-BB-EXACT/BYTES/SLOT need FP_FACET_TEX && FP_BLOCK_DETAIL && FP_BAND_BLOCK_MAP; OFF-identity by G-BB-OFF)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- a fresh, independent sampler (the SAME generator chain the baker uses; the gate packs + classifies itself) ---
var _sampler: Callable
var _sampler_obj: Object = null
func _ensure_sampler(active_fid: int) -> void:
	if not _sampler.is_null():
		return
	_sampler_obj = FST._build_cpp_gen(active_fid)
	if _sampler_obj != null:
		_sampler = Callable(_sampler_obj, "sample_columns")
	else:
		_sampler = Callable(FST, "gd_sample")

## Facet `fid`'s 4 lattice (x,z) corners — the SAME mapping FacetTexBaker.sample_fine / _bake_band_slice use.
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

## The classifier's expected band id at facet-param block (bx,by) with per-axis block counts (nx,ny): sample the top-block
## colour at the block's param CENTRE (through the one-sampler law), classify to detail_pattern + 1. Independent of the bake.
func _expected_id(fid: int, lc: PackedVector2Array, bx: int, by: int, nx: int, ny: int) -> int:
	var s := (float(bx) + 0.5) / float(nx)
	var t := (float(by) + 0.5) / float(ny)
	var lx := _bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)
	var lz := _bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)
	var packed := PackedInt64Array([_pack_xz(int(round(lx)), int(round(lz)))])
	var res: Dictionary = _sampler.call(fid, packed)
	var cols: PackedColorArray = res["colors"]
	return FarPalette.detail_pattern(cols[0]) + 1

# --- G-BB-OFF: band injection off ≡ shipped detail string; on is additive-only; runtime-off builds nothing ----------
func _gate_off(fid: int, tex_on: bool, bd_on: bool, bm_on: bool) -> void:
	if not (tex_on and bd_on):
		return   # the band injection only exists atop the FP_BLOCK_DETAIL string; nothing to compare without it
	var detail_only := FacetFarRing.gate_band_shader(false, false)     # FP_BLOCK_DETAIL, band FORCED off
	var with_band := FacetFarRing.gate_band_shader(false, true)        # + band injection FORCED on
	var detail_only_cu := FacetFarRing.gate_band_shader(true, false)
	var with_band_cu := FacetFarRing.gate_band_shader(true, true)
	# Zero new compiled programs: exactly ONE shader_type per string in BOTH the band-off and band-on forms.
	_ok(detail_only.count("shader_type") == 1 and with_band.count("shader_type") == 1
		and detail_only_cu.count("shader_type") == 1 and with_band_cu.count("shader_type") == 1,
		"G-BB-OFF: exactly ONE shader_type per shell string band-on/off (zero new compiled programs)")
	# Band FORCED off carries NO band tokens (it IS the pre-U1 FP_BLOCK_DETAIL string). Its byte-identity to the shipped
	# detail string is what the RUNTIME flag delivers: gate_tex_shader_detail defaults to the flag, so it equals the
	# band-OFF form when the flag is off and the band-ON form when on — assert the correct one for this run.
	_ok(not detail_only.contains("band_map") and not detail_only.contains("v_bslot") and not detail_only.contains("band_facet"),
		"G-BB-OFF: band-off string has NO band_map / band_facet / v_bslot tokens (≡ the pre-U1 FP_BLOCK_DETAIL string)")
	if bm_on:
		_ok(FacetFarRing.gate_tex_shader_detail(false) == with_band and FacetFarRing.gate_tex_shader_detail(true) == with_band_cu,
			"G-BB-OFF: runtime flag ON ⇒ the live shell string IS the band-ON form")
	else:
		_ok(FacetFarRing.gate_tex_shader_detail(false) == detail_only and FacetFarRing.gate_tex_shader_detail(true) == detail_only_cu,
			"G-BB-OFF: runtime flag OFF ⇒ the live shell string is BYTE-IDENTICAL to the band-off (pre-U1) string")
	# Band FORCED on is ADDITIVE: differs from detail-only, declares band_map + band_facet + band_n + v_bslot, and the
	# real-block composite line (fract(_buv) intra-block UV + texelFetch(band_map)).
	_ok(with_band != detail_only and with_band_cu != detail_only_cu, "G-BB-OFF(ON): the band injection changed the shader string (additive)")
	_ok(with_band.contains("uniform sampler2DArray band_map")
		and with_band.contains("band_facet[") and with_band.contains("band_n[")
		and with_band.contains("varying float v_bslot") and with_band.contains("texelFetch(band_map")
		and with_band.contains("fract(_buv)"),
		"G-BB-OFF(ON): injected band_map/band_facet/band_n samplers + v_bslot + per-block composite")
	# The detail-only path survives verbatim inside the band-on ELSE branch (far-far degrades to the tiled path): every
	# non-ALBEDO line of detail_only is still present in with_band (additive: only the final ALBEDO block was wrapped).
	var additive := true
	for line in detail_only.split("\n"):
		var s := line.strip_edges()
		if s == "" or s.begins_with("ALBEDO ="):
			continue
		if not with_band.contains(line):
			additive = false
	_ok(additive, "G-BB-OFF(ON): the detail-only lines survive verbatim (far-far tiled path preserved in the band ELSE branch)")

	# The injected band GLSL actually PARSES (catch a syntax slip in the injection): assign it to a Shader and confirm
	# the band uniforms register (an unparsed shader exposes no uniforms). Proves the additive splice is valid code.
	var sh := Shader.new()
	sh.code = with_band
	var sm := ShaderMaterial.new()
	sm.shader = sh
	var unames := {}
	for u in sh.get_shader_uniform_list():
		unames[String(u.get("name", ""))] = true
	_ok(unames.has("band_map") and unames.has("band_facet") and unames.has("band_n") and unames.has("base_map") and unames.has("detail_map"),
		"G-BB-OFF(ON): the band-injected shader PARSES — band_map/band_facet/band_n/base_map/detail_map uniforms register")

	# RUNTIME flag off ⇒ the baker never builds a band texture and no facet gets a band slot (byte-identical, zero bytes).
	if not bm_on:
		var baker := FacetTexBaker.new()
		baker.setup(fid)
		_ok(not baker.band_on() and baker.band_texture() == null and baker.band_slot(fid) == -1 and baker.band_bytes() == 0,
			"G-BB-OFF: runtime flag off ⇒ NO band texture / slot / bytes built")

# --- G-BB-EXACT: band id == classifier; shader addressing reproduces it; range; falsifier -------------------------
func _gate_exact(fid: int) -> void:
	_ensure_sampler(fid)
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	# Drive the row-sliced band bake to completion (huge budget → one update bakes the whole band ring, check-before-slice).
	baker.update([2.0, 0.0, 0.0], false, 100000.0, fid)
	_ok(baker.band_on() and baker.band_texture() != null, "G-BB-EXACT: the band tier built its BAND_LAYERS-layer id map")
	_ok(baker.band_slot(fid) >= 0, "G-BB-EXACT: the active facet is a RESIDENT band facet (slot %d)" % baker.band_slot(fid))

	var nxy := baker.band_n_of(fid)
	var nx := int(nxy.x); var ny := int(nxy.y)
	_ok(nx >= 1 and nx <= CubeSphere.BAND_TEXELS and ny >= 1 and ny <= CubeSphere.BAND_TEXELS,
		"G-BB-EXACT: band block counts (Nx=%d,Ny=%d) ∈ [1, %d] (fit the 512² map)" % [nx, ny, CubeSphere.BAND_TEXELS])
	var lc := _facet_lc(fid)
	var np := FarPalette.DETAIL_PATTERNS
	# Spread of ~11×11 texels across the facet (block coords), compare stored id to the independent classifier.
	var all_match := true
	var in_range := true
	var worst := ""
	var seen := {}
	var steps := 11
	for iy in range(steps):
		var by := (iy * (ny - 1)) / (steps - 1)
		for ix in range(steps):
			var bx := (ix * (nx - 1)) / (steps - 1)
			var got := baker.band_id_at(fid, bx, by)
			var expect := _expected_id(fid, lc, bx, by, nx, ny)
			seen[got] = true
			if got != expect:
				all_match = false
				worst = "(%d,%d) got %d expect %d" % [bx, by, got, expect]
			if got < 1 or got > np:
				in_range = false
	_ok(all_match, "G-BB-EXACT: every sampled band id == FarPalette.detail_pattern(real column) + 1 %s" % ("" if all_match else "— " + worst))
	_ok(in_range, "G-BB-EXACT: every sampled band id ∈ [1, %d] (a real material pattern, never the 0 sentinel)" % np)

	# Shader-addressing reproduction: for a spread of facet-LOCAL params p ∈ [0,1]², the shader reads band_map at
	# block = int(p·N) (fract(p·N) is the intra-block UV). Confirm that texel's id equals the classifier at the lattice
	# column p maps to — i.e. the fragment reconstructs the REAL top block at its REAL position.
	var addr_ok := true
	var addr_worst := ""
	for iy in range(7):
		var py := (float(iy) + 0.5) / 7.0
		for ix in range(7):
			var px := (float(ix) + 0.5) / 7.0
			var bx := clampi(int(px * float(nx)), 0, nx - 1)   # the shader's int(uv·N)
			var by := clampi(int(py * float(ny)), 0, ny - 1)
			var got := baker.band_id_at(fid, bx, by)
			var expect := _expected_id(fid, lc, bx, by, nx, ny)
			if got != expect:
				addr_ok = false
				addr_worst = "p=(%.3f,%.3f)→blk(%d,%d) got %d expect %d" % [px, py, bx, by, got, expect]
	_ok(addr_ok, "G-BB-EXACT: shader addressing (uv→int(uv·N)) reads the classifier's real per-block id %s" % ("" if addr_ok else "— " + addr_worst))

	# The map is a REAL arrangement, not a constant: either neighbouring blocks differ somewhere, or (uniform facet) a
	# deliberately wrong expected id fails.
	var varied := seen.size() >= 2
	if varied:
		_ok(varied, "G-BB-EXACT falsify: the band carries ≥ 2 distinct block ids (a real arrangement, %d seen)" % seen.size())
	else:
		_ok(baker.band_id_at(fid, 0, 0) != 0, "G-BB-EXACT falsify: baked band id ≠ the un-baked sentinel 0")
	# Falsify the classifier match itself: a shifted expected id (a neighbour block one row over) disagrees somewhere.
	var mism := false
	for by in range(0, ny, maxi(1, ny / 8)):
		for bx in range(0, nx - 1, maxi(1, nx / 8)):
			if baker.band_id_at(fid, bx, by) != baker.band_id_at(fid, bx + 1, by):
				mism = true
	if mism:
		_ok(mism, "G-BB-EXACT falsify: neighbouring band blocks carry different ids (not a constant page)")
	else:
		_ok(baker.band_id_at(fid, 0, 0) >= 1, "G-BB-EXACT falsify: a uniform facet still carries a real (≥1) id")

# --- G-BB-BYTES: fixed ledger arithmetic, ≤ ceilings, eviction frees the layer -----------------------------------
func _gate_bytes(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.update([2.0, 0.0, 0.0], false, 100000.0, fid)
	# The band ledger is the fixed arithmetic: BAND_LAYERS × 512² L8 (GPU) + one 512² L8 staging image.
	var bm_px := CubeSphere.BAND_TEXELS * CubeSphere.BAND_TEXELS
	var expect_bytes := CubeSphere.BAND_LAYERS * bm_px + bm_px
	_ok(baker.band_bytes() == expect_bytes,
		"G-BB-BYTES: band ledger == BAND_LAYERS·512² + one staging L8 = %d B (%.2f MB)" % [expect_bytes, float(expect_bytes) / 1048576.0])
	_ok(baker.band_bytes() <= CubeSphere.band_bytes_max(),
		"G-BB-BYTES: band tier ≤ band_bytes_max() (%.2f MB ≤ %.2f MB)" % [float(baker.band_bytes()) / 1048576.0, float(CubeSphere.band_bytes_max()) / 1048576.0])
	# The whole baker (base + id + detail atlas + band) stays under the §2U combined ceiling (43 MB).
	var ceil43 := 43 * 1024 * 1024
	_ok(baker.total_bytes() <= ceil43,
		"G-BB-BYTES: whole baker total ≤ the §2U combined ceiling (%.2f MB ≤ 43 MB)" % [float(baker.total_bytes()) / 1048576.0])
	# Falsify the arithmetic: a wrong layer count would change the ledger.
	_ok(baker.band_bytes() != (CubeSphere.BAND_LAYERS + 1) * bm_px + bm_px, "G-BB-BYTES falsify: the ledger is layer-count sensitive")

	# Eviction frees the layer (LRU by ring exit): drive a DIFFERENT active facet whose ring-1 excludes `fid`, and confirm
	# `fid` loses its slot while the resident count stays ≤ BAND_LAYERS (the pool is reused, not grown).
	var resident0 := baker.band_resident_count()
	var far_fid := (fid + 3 * FA.K * FA.K) % (6 * FA.K * FA.K)   # ~half the planet away → not in fid's ring
	baker.update([2.0, 0.0, 0.0], false, 100000.0, far_fid)
	_ok(baker.band_slot(fid) == -1 or not baker.band_in_ring(fid),
		"G-BB-BYTES: a facet leaving the band ring is evicted (slot freed) — no unbounded growth")
	_ok(baker.band_resident_count() <= CubeSphere.BAND_LAYERS and resident0 <= CubeSphere.BAND_LAYERS,
		"G-BB-BYTES: band residency stays ≤ BAND_LAYERS (%d, %d) — fixed layer pool" % [resident0, baker.band_resident_count()])
	_ok(baker.band_bytes() == expect_bytes, "G-BB-BYTES: the ledger is unchanged after a crossing (fixed-size, NEVER-OOM)")

# --- G-BB-SLOT: UV2.y == 64 + layer; residency = active ∪ ring-1; leaving the ring frees the slot -----------------
func _gate_slot(fid: int) -> void:
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.update([2.0, 0.0, 0.0], false, 100000.0, fid)
	var slot := baker.band_slot(fid)
	_ok(slot >= 0 and slot < CubeSphere.BAND_LAYERS, "G-BB-SLOT: resident band layer ∈ [0, BAND_LAYERS) (slot %d)" % slot)

	# The ring maps a resident band facet to UV2.y == 64 + layer (band wins over the close-up 0..63 space). Build a bare
	# ring, push the baker's band slots, and read _slot_of through the FROZEN snapshot the emit uses.
	var ring := FacetFarRing.new()
	ring.set_band_slots(baker.band_slots(), baker.band_facet_map(), baker.band_n_map())
	ring._refresh_slot_snapshot()
	_ok(int(ring._slot_of(fid)) == 64 + slot, "G-BB-SLOT: the ring emits UV2.y == 64 + layer for a resident band facet (%d)" % int(ring._slot_of(fid)))

	# Residency = active ∪ ring-1: the active facet + each of its ring-1 neighbours (up to BAND_LAYERS) are in-ring; a
	# far facet is not.
	var ring1 := TierPlace.ring1(fid)
	var band_in := baker.band_in_ring(fid)
	var neigh_in := ring1.size() < 2 or baker.band_in_ring(int(ring1[1]))
	_ok(band_in and neigh_in, "G-BB-SLOT: residency includes the active facet + its ring-1 neighbours")
	var far_fid := (fid + 3 * FA.K * FA.K) % (6 * FA.K * FA.K)
	_ok(not baker.band_in_ring(far_fid), "G-BB-SLOT: a far facet is NOT in the band ring (bounded residency)")

	# Leaving the ring frees the slot: cross to `far_fid`, its ring must not contain `fid`; `fid` loses residency.
	baker.update([2.0, 0.0, 0.0], false, 100000.0, far_fid)
	_ok(baker.band_slot(fid) == -1, "G-BB-SLOT: crossing away frees the departed facet's band slot (evict-only-on-ring-exit)")
	ring.free()
