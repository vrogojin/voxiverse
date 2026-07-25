extends SceneTree
## G-FALLPHYS — FP_ANALYTIC_COL_MEMO: the analytic column-profile memo that collapses the de-orbit floor-scan
## cost (phys_ms 100-330ms -> ~3-8ms). Two proofs, run with the flag sed'd ON (like the other faceted gates):
##  (A) EQUIVALENCE  — generated_cell (the memo path when the flag is on) == the RAW null-pcache reference,
##      bit-for-bit, over slopes / a tree tile / snow band / datum-shifted band / a Moon facet. Proves the
##      memo introduces ZERO behaviour change (it is a pure fn of (facet,x,z); resolve_cell(ctx)==resolve_cell(null)).
##  (B) BOUNDEDNESS — a vertical column scan (floor_under's ~400 cells/frame) recomputes the EXPENSIVE
##      facet_profile only a HANDFUL of times with the flag on (memo hit) vs ~once-per-cell with it off (the
##      phys_ms explosion). Measured via the always-on TerrainConfig._profile_computes counter.
## Exits 0 all-pass, 1 on any failure. Byte-off (flag false) is covered by verify_feature (FLAT 6042/0).

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

# The RAW shipped null-pcache compute — replicates generated_cell's flag-OFF body exactly, independent of the flag.
func _ref_cell(x: int, y: int, z: int) -> int:
	var p := TerrainConfig.column_profile(x, z)
	var yy := y
	if CubeSphere.FACETED and TerrainConfig._active_facet >= 0:
		yy = y - FacetAtlas.datum_shift(TerrainConfig._active_facet, x, z)
	return TerrainConfig.resolve_cell(x, yy, z, int(p.x), int(p.y), p.z, p.w)

func _initialize() -> void:
	print("=== verify_fall_phys (G-FALLPHYS: FP_ANALYTIC_COL_MEMO) ===")
	print("  FP_ANALYTIC_COL_MEMO=%s FACETED=%s" % [str(CubeSphere.FP_ANALYTIC_COL_MEMO), str(CubeSphere.FACETED)])
	FacetAtlas.warm_up()
	if not CubeSphere.FACETED:
		print("  SKIP: not FACETED (the analytic memo is faceted-only)")
		print("==== VERIFY: 0 passed, 0 failed ===="); quit(0); return
	TerrainConfig.set_active_facet(0)   # Earth facet 0 — makes _active_facet >= 0 (the memo-path precondition)

	# (A) EQUIVALENCE: the memo path == the raw reference, bit-for-bit, over a broad (x,z,y) grid.
	print("  --- A: generated_cell (memo) == raw null-pcache reference, bit-identical ---")
	var mism := 0
	var n := 0
	for xz in [Vector2i(10, 20), Vector2i(-40, 130), Vector2i(500, -300), Vector2i(3, 7),
			Vector2i(-777, 888), Vector2i(2048, 2048), Vector2i(-1, -1)]:
		for y in range(-30, 320, 2):
			if TerrainConfig.generated_cell(xz.x, y, xz.y) != _ref_cell(xz.x, y, xz.y): mism += 1
			n += 1
	_ok(mism == 0, "A generated_cell == reference over %d (x,z,y) samples (mismatches %d)" % [n, mism])
	# A Moon facet too (airless branch of facet_profile).
	var moon_fid := FacetAtlas.K * FacetAtlas.K * 6   # first fid of body 1 (Moon), if present
	if FacetAtlas.body_of_fid(moon_fid) == 1:
		TerrainConfig.set_active_facet(moon_fid)
		var mm := 0
		for y in range(-30, 200, 3):
			if TerrainConfig.generated_cell(55, -66, 77) != _ref_cell(55, -66, 77): mm += 1
			if TerrainConfig.generated_cell(55, y, 77) != _ref_cell(55, y, 77): mm += 1
		_ok(mm == 0, "A Moon facet generated_cell == reference (mismatches %d)" % mm)
		TerrainConfig.set_active_facet(0)

	# (B) BOUNDEDNESS: a fixed-(x,z) vertical scan of ~400 cells. Flag ON => ~1 profile compute (+ tree stencil);
	# flag OFF => ~1 per cell (the bug). set_active_facet clears the memo so the first compute counts.
	print("  --- B: 400-cell column scan profile-compute count (memo vs the bug) ---")
	TerrainConfig.set_active_facet(0)
	var x := 12345
	var z := -6789
	var before: int = TerrainConfig._profile_computes
	for y in range(-50, 350):
		TerrainConfig.generated_cell(x, y, z)
	var delta: int = TerrainConfig._profile_computes - before
	print("    400-cell scan @ (%d,%d): profile computes = %d" % [x, z, delta])
	if CubeSphere.FP_ANALYTIC_COL_MEMO:
		_ok(delta <= 20, "B memo: scan did %d profile computes (<=20 — own column + tree stencil; was ~400)" % delta)
	else:
		_ok(delta >= 300, "B (flag OFF) UNFIXED: scan did %d profile computes (the phys_ms explosion)" % delta)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
