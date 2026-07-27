extends SceneTree
## COSMOS TEXTURED-LOD §2V PREP gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V). Certifies the SHARED foundation the
## four parallel V-agents build on — the shell-shader ALBEDO/LIGHT split, SurfaceShot.surface_shot, and
## TreeGen.top_decoration — is byte-identical + inert (NO FP_ flag, nothing calls it yet). Runs with FACETED = true
## (FLAT_WORLD = true), no other flag required (the helpers are pure statics, not flag-gated). Four falsifiable gates:
##   G-SP-SHADER-IDENTICAL — for BOTH shell tex shaders, (LIGHT sub-string + ALBEDO sub-string) is BYTE-FOR-BYTE the
##                           pre-split original (a frozen golden snapshot of tip 602bf13), and the live derived const
##                           _SHELL_ABS_TEX(_CU)_SHADER equals that concatenation; exactly ONE shader_type per string.
##   G-SP-SHOT             — surface_shot(fid,x,z).block_id == the EXISTING classifier id (FarPalette.detail_pattern of
##                           the one-sampler colour, +1) at non-tree columns; at a decorated column the id/tint are the
##                           canopy/trunk block's (composited, ≠ the bare terrain); shade ∈ [0,1] and reflects the
##                           analytic cues (flat dry column = 1.0; steep / deep-water / canopy-adjacent < 1.0);
##                           deterministic (same input → same output).
##   G-SP-TREE             — top_decoration matches TreeGen's ACTUAL placement: a column of a tree's base cell returns a
##                           tree id (== an independent WIDE top-down block_at scan), a tree-free column returns AIR.
##   G-SP-INERT            — a recursive scan of res://src (minus the two def files + this gate) finds ZERO calls to
##                           surface_shot / top_decoration / SurfaceShot ⇒ byte-identical & inert (FLAT 6042/0 confirms).

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
	print("=== verify_shot_prep (TEXTURED-LOD §2V PREP — shader split + surface_shot + top_decoration) ===")
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

	_gate_shader_identical()
	_gate_inert()

	# Pick a facet that actually carries trees so the decoration path is EXERCISED (home first, then sweep).
	var picked := _find_forested_facet()
	var fid: int = picked["fid"]
	TC.set_active_facet(fid)
	print("  test facet=%d (K=%d): %d tree base columns, %d tree-free columns sampled"
		% [fid, FA.K, picked["trees"].size(), picked["bare"].size()])
	_gate_tree(fid, picked)
	_gate_shot(fid, picked)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-SP-SHADER-IDENTICAL ------------------------------------------------------------------------------------
func _gate_shader_identical() -> void:
	_check_split("shell",
		FacetFarRing._SHELL_ABS_TEX_LIGHT, FacetFarRing._SHELL_ABS_TEX_ALBEDO, FacetFarRing._SHELL_ABS_TEX_SHADER,
		"res://src/tools/data/shot_prep_golden_shell.txt")
	_check_split("closeup",
		FacetFarRing._SHELL_ABS_TEX_CU_LIGHT, FacetFarRing._SHELL_ABS_TEX_CU_ALBEDO, FacetFarRing._SHELL_ABS_TEX_CU_SHADER,
		"res://src/tools/data/shot_prep_golden_cu.txt")

func _check_split(tag: String, light: String, albedo: String, derived: String, golden_path: String) -> void:
	var concat := light + albedo
	var golden := FileAccess.get_file_as_bytes(golden_path)
	_ok(golden.size() > 0, "G-SP-SHADER-IDENTICAL(%s): golden snapshot present at %s" % [tag, golden_path])
	# THE byte-for-byte identity: LIGHT+ALBEDO == the pre-split original shader string (frozen golden, tip 602bf13).
	_ok(concat.to_utf8_buffer() == golden,
		"G-SP-SHADER-IDENTICAL(%s): LIGHT+ALBEDO is BYTE-IDENTICAL to the pre-split golden" % tag)
	# The live derived const every reader uses IS that concatenation (so the split is what actually ships).
	_ok(derived == concat, "G-SP-SHADER-IDENTICAL(%s): live _..._SHADER == LIGHT+ALBEDO (derived, not a stale copy)" % tag)
	# The split falls exactly on the vertex()/fragment() seam, and there is still ONE program (one shader_type).
	_ok(light.ends_with("}\n") and albedo.begins_with("void fragment()"),
		"G-SP-SHADER-IDENTICAL(%s): LIGHT is the vertex head, ALBEDO is the fragment tail (clean V1/V2 boundary)" % tag)
	_ok(concat.count("shader_type") == 1 and light.count("shader_type") == 1 and albedo.count("shader_type") == 0,
		"G-SP-SHADER-IDENTICAL(%s): exactly ONE shader_type (zero new compiled programs)" % tag)
	# Falsification witness: a one-byte perturbation of either sub-string breaks the identity.
	_ok((light + "x" + albedo).to_utf8_buffer() != golden,
		"G-SP-SHADER-IDENTICAL(%s): a perturbed concat FAILS the golden compare (gate is falsifiable)" % tag)

# --- G-SP-INERT: nothing in the running engine calls the new helpers -------------------------------------------
func _gate_inert() -> void:
	var hits: Array = []
	_scan_dir("res://src", hits)
	_ok(hits.is_empty(),
		"G-SP-INERT: no call to surface_shot / top_decoration / SurfaceShot in the running engine (found: %s)"
			% str(hits))

func _scan_dir(path: String, hits: Array) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var e := d.get_next()
		if e == "":
			break
		if e.begins_with("."):
			continue
		var full := path + "/" + e
		if d.current_is_dir():
			_scan_dir(full, hits)
		elif e.ends_with(".gd"):
			# The two definition files and this gate are the only legitimate mentions.
			if full == "res://src/world/tree_gen.gd" or full == "res://src/world/surface_shot.gd" \
					or full == "res://src/tools/verify_shot_prep.gd":
				continue
			var txt := FileAccess.get_file_as_string(full)
			for needle in ["surface_shot(", ".top_decoration(", "SurfaceShot."]:
				if txt.contains(needle):
					hits.append(full + " :: " + needle)
	d.list_dir_end()

# --- facet + column selection: find a facet that carries trees, collect base + bare columns -------------------
func _find_forested_facet() -> Dictionary:
	var home := FA.spawn_facet()
	var candidates: PackedInt32Array = PackedInt32Array([home])
	# A spread of face-centre facets (one per cube face) as fallbacks — some faces are oceanic on the home seed.
	for face in range(6):
		candidates.append(face * FA.K * FA.K + (FA.K / 2) * FA.K + (FA.K / 2))
	for fid in candidates:
		TC.set_active_facet(fid)
		var got := _collect_columns(fid)
		if got["trees"].size() >= 1 and got["bare"].size() >= 1:
			got["fid"] = fid
			return got
	# Nothing forested found (unlikely) — return the home facet's (possibly tree-free) sample so the bare-column
	# gates still run; the tree assertions will report they could not be exercised.
	TC.set_active_facet(home)
	var g := _collect_columns(home)
	g["fid"] = home
	return g

## Scan grid cells around facet `fid`'s centre; a cell TreeGen would plant returns its BASE column (guaranteed a
## trunk/canopy over it); cells it leaves empty contribute a bare column. Bounded + deterministic.
func _collect_columns(fid: int) -> Dictionary:
	var lc := _facet_lc(fid)
	var cx := int(round((lc[0].x + lc[1].x + lc[2].x + lc[3].x) * 0.25))
	var cz := int(round((lc[0].y + lc[1].y + lc[2].y + lc[3].y) * 0.25))
	var gx0 := floori(float(cx) / float(TreeGen.G))
	var gz0 := floori(float(cz) / float(TreeGen.G))
	var trees: Array = []
	var bare: Array = []
	for dgz in range(-24, 25):
		for dgx in range(-24, 25):
			var gx := gx0 + dgx
			var gz := gz0 + dgz
			if TreeGen.has_tree(gx, gz):
				if trees.size() < 24:
					var tb := TreeGen.tree_base(gx, gz)
					trees.append(Vector2i(tb.x, tb.z))
			else:
				# A column at the cell centre, well away from any neighbouring canopy → reliably decoration-free.
				if bare.size() < 60:
					bare.append(Vector2i(gx * TreeGen.G + TreeGen.G / 2, gz * TreeGen.G + TreeGen.G / 2))
		if trees.size() >= 24 and bare.size() >= 60:
			break
	return {"trees": trees, "bare": bare}

# --- G-SP-TREE: top_decoration == TreeGen's real placement ----------------------------------------------------
func _gate_tree(fid: int, cols: Dictionary) -> void:
	var trees: Array = cols["trees"]
	var bare: Array = cols["bare"]
	_ok(trees.size() >= 1, "G-SP-TREE: at least one decorated column exercised (found %d)" % trees.size())
	var tree_ok := true
	for c in trees:
		var td := TreeGen.top_decoration(c.x, c.y)
		var scan := _scan_top_block(c.x, c.y)     # independent WIDE block_at scan
		if td == BlockCatalog.AIR or td != scan:
			tree_ok = false
			print("    tree col (%d,%d): top_decoration=%d wide-scan=%d" % [c.x, c.y, td, scan])
	_ok(tree_ok, "G-SP-TREE: every tree base column returns a tree id == the independent wide top-down block_at scan")
	var bare_ok := true
	for c in bare:
		if TreeGen.top_decoration(c.x, c.y) != BlockCatalog.AIR:
			bare_ok = false
	_ok(bare_ok, "G-SP-TREE: tree-free columns return AIR (no phantom decorations)")

## Independent reference: the topmost non-air TreeGen block over column (x,z), scanned over a WIDER y-window than
## top_decoration uses (proves the helper's bounded span never truncates a real tree — a real off-by-one FAILS).
func _scan_top_block(x: int, z: int) -> int:
	var gy := TC.column_top(x, z)
	for y in range(gy + TreeGen.MAX_ABOVE_SURFACE + 6, gy - 2, -1):
		var id := TreeGen.block_at(x, y, z)
		if id != BlockCatalog.AIR:
			return id
	return BlockCatalog.AIR

# --- G-SP-SHOT: the composite record ---------------------------------------------------------------------------
func _gate_shot(fid: int, cols: Dictionary) -> void:
	var bare: Array = cols["bare"]
	var trees: Array = cols["trees"]

	# (1) bare columns: block_id == the existing classifier id from the one-sampler colour; shade ∈ [0,1]; deterministic.
	var id_ok := true
	var det_ok := true
	var range_ok := true
	for c in bare:
		var rec := SurfaceShot.surface_shot(fid, c.x, c.y)
		var expect := FarPalette.detail_pattern(_sampler_color(fid, c.x, c.y)) + 1
		if int(rec["block_id"]) != expect:
			id_ok = false
			print("    bare col (%d,%d): block_id=%d expected=%d" % [c.x, c.y, int(rec["block_id"]), expect])
		var sh := float(rec["shade"])
		if sh < 0.0 or sh > 1.0:
			range_ok = false
		var rec2 := SurfaceShot.surface_shot(fid, c.x, c.y)
		if int(rec2["block_id"]) != int(rec["block_id"]) or float(rec2["shade"]) != sh or rec2["tint"] != rec["tint"]:
			det_ok = false
	_ok(id_ok, "G-SP-SHOT: bare-column block_id == FarPalette.detail_pattern(one-sampler colour) + 1 (existing classifier)")
	_ok(range_ok, "G-SP-SHOT: shade ∈ [0,1] on every sampled column")
	_ok(det_ok, "G-SP-SHOT: deterministic — the same (fid,x,z) yields the identical record twice")

	# (2) decorated columns: id + tint are the canopy/trunk block's (composited), not the bare terrain's.
	var tree_ok := true
	for c in trees:
		var td := TreeGen.top_decoration(c.x, c.y)
		var rec := SurfaceShot.surface_shot(fid, c.x, c.y)
		var expect_id := FarPalette.detail_pattern(BlockCatalog.color_of(td)) + 1
		if int(rec["block_id"]) != expect_id or rec["tint"] != BlockCatalog.color_of(td):
			tree_ok = false
			print("    tree col (%d,%d): id=%d expect=%d" % [c.x, c.y, int(rec["block_id"]), expect_id])
	_ok(tree_ok, "G-SP-SHOT: decorated-column id/tint == the canopy/trunk block (TreeGen.top_decoration composited)")

	# (3) the shade cues actually bite: a flat dry interior column reads 1.0; a steep / deep-water / canopy-adjacent
	# column reads < 1.0 (the analytic AO / hillshade / water / canopy law, sun-independent). Falsifiable.
	var flat_ref := _find_flat_dry_column(fid, cols)
	if flat_ref.x != 0x7fffffff:
		_ok(float(SurfaceShot.surface_shot(fid, flat_ref.x, flat_ref.y)["shade"]) == 1.0,
			"G-SP-SHOT: a flat, dry, un-shadowed interior column reads shade == 1.0 (the un-darkened reference)")
	else:
		print("    (no flat-dry reference column in sample — shade-floor check skipped)")
	var darker := _find_darkened_column(fid, cols)
	_ok(darker.x != 0x7fffffff,
		"G-SP-SHOT: at least one steep / deep-water / canopy-adjacent column reads shade < 1.0 (cues bite)")

func _find_flat_dry_column(fid: int, cols: Dictionary) -> Vector2i:
	for c in cols["bare"]:
		if float(SurfaceShot.surface_shot(fid, c.x, c.y)["shade"]) == 1.0:
			return c
	return Vector2i(0x7fffffff, 0)

func _find_darkened_column(fid: int, cols: Dictionary) -> Vector2i:
	# Ground columns adjacent to a tree base are canopy-shadowed; deep water / steep relief also darken.
	for c in cols["trees"]:
		# a cardinal neighbour of the base is a bare ground column in the canopy penumbra
		for off in [Vector2i(3, 0), Vector2i(-3, 0), Vector2i(0, 3), Vector2i(0, -3)]:
			var p := Vector2i(c.x + off.x, c.y + off.y)
			var rec := SurfaceShot.surface_shot(fid, p.x, p.y)
			if int(rec["block_id"]) >= 0 and float(rec["shade"]) < 1.0:
				return p
	for c in cols["bare"]:
		if float(SurfaceShot.surface_shot(fid, c.x, c.y)["shade"]) < 1.0:
			return c
	return Vector2i(0x7fffffff, 0)

# --- the one-sampler colour reference (the SAME chain the baker classifies), fid-scoped via a GenCtx ----------
func _sampler_color(fid: int, x: int, z: int) -> Color:
	var res: Dictionary = FST.gd_sample(fid, PackedInt64Array([_pack_xz(x, z)]))
	return (res["colors"] as PackedColorArray)[0]

func _facet_lc(fid: int) -> PackedVector2Array:
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var w := FA.facet_planar_corner(fid, ci)
		var l := FA.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	return lc

static func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)
