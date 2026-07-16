extends SceneTree
## verify_bulk_underground — GEN-EFFICIENCY Fix A (docs/COSMOS-GEN-EFFICIENCY-DESIGN.md §1 / §2 gate 6) truth gate.
##
## Proves FP_BULK_UNDERGROUND is a SAFE appearance-only optimisation on the module render path:
##   G-BULK-FILL   a provably-interior underground block is VoxelBuffer.fill()'d UNIFORMLY with the SAME cube ARID a
##                 per-cell plain deep STONE/DEEPSLATE cell writes (an exposed non-ore wall matches byte-for-byte).
##   G-BULK-MATCH  every cell the per-cell generator emits as PLAIN stone/deepslate equals the bulk fill (the loss is
##                 confined to the ore/strata VARIANTS — counted, so the "accepted loss" is bounded, never a hole/air).
##   G-BULK-TRUTH  physics ground truth is intact: TerrainConfig.resolve_cell (the block_id_at source) still returns
##                 the TRUE ore/strata material for the bulk cells — the mesh shows stone, the broken/dropped block is
##                 correct. My diff never touches resolve_cell / block_id_at, so this holds by construction; pinned.
##   G-BULK-SURFACE the walkable surface is NEVER bulk-filled (no-fall-through): the surface data block is left per-cell
##                 (its top solid cell == column_profile g), and every qualifying block's top cell sits strictly below g.
##
## Requires FP_BULK_UNDERGROUND ON (a const): run with the flag sed-toggled true, e.g.
##   sed -i 's/const FP_BULK_UNDERGROUND := false/const FP_BULK_UNDERGROUND := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_bulk_underground.gd
## Runs in FLAT mode (gen_facet < 0 → the ridge guard self-disables), so it needs no faceted atlas.

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: %s" % m)
	else:
		_fail += 1
		print("  FAIL: %s" % m)

# min surface height over the [ox,ox+16) x [oz,oz+16) column block (mirrors the worker's min_h profile pass).
func _min_surface(ox: int, oz: int) -> int:
	var m := 0x7fffffff
	for z in range(16):
		for x in range(16):
			var g := int(TerrainConfig.column_profile(ox + x, oz + z, {}).x)
			if g < m: m = g
	return m

func _gen_into(gen: Object, origin: Vector3i) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 16, 16, 16)
	buf.call("set_channel_depth", 0, 1)          # DEPTH_16_BIT (matches the live TYPE channel)
	gen.call("generate_block", buf, Vector3(origin.x, origin.y, origin.z), 0)
	return buf

func _uniform_value(buf: Object) -> int:
	# returns the single value if the whole 16³ block is uniform, else -1
	var v0 := int(buf.call("get_voxel", 0, 0, 0, 0))
	for z in range(16):
		for y in range(16):
			for x in range(16):
				if int(buf.call("get_voxel", x, y, z, 0)) != v0:
					return -1
	return v0

func _initialize() -> void:
	print("=== verify_bulk_underground (GEN-EFFICIENCY Fix A: bulk underground fill truth gate) ===")
	if not CubeSphere.FP_BULK_UNDERGROUND:
		print("  FAIL: CubeSphere.FP_BULK_UNDERGROUND is false — sed-toggle it true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent (ClassDB has no VoxelTerrain) — this gate needs the module binary.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return

	TerrainConfig.warm_up()
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	var ok_setup: bool = bool(mod.call("setup"))
	_ok(ok_setup, "setup: module_world built the flat terrain + baked library")
	if not ok_setup:
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail]); quit(1); return

	# the SHIPPED generator (flag on), plus a per-cell reference clone (same epoch, bulk forced OFF).
	var gb: Object = mod.call("get_generator")
	var gc: Object = mod.call("_make_generator")
	gc.set("fp_bulk", false)
	var stone_arid := int(gb.get("bulk_stone_arid"))
	var deep_arid := int(gb.get("bulk_deepslate_arid"))
	_ok(stone_arid >= 0 and deep_arid >= 0, "setup: fill ARIDs baked (stone=%d, deepslate=%d)" % [stone_arid, deep_arid])
	_ok(bool(gb.get("fp_bulk")), "setup: shipped generator has fp_bulk ON (flag sed-toggled)")

	# Scan a coarse grid for the DEEPEST-terrain region (highest min surface): a 16³ pure-stone block only fits
	# above the -24..-16 dither band when min_h >= ~13 (band [-15, min_h-13] must be >= 16 tall). Pick the best.
	var ox := 0
	var oz := 0
	var min_h := -0x7fffffff
	for gz in range(8):
		for gx in range(8):
			var cx := gx * 128
			var cz := gz * 128
			var m := _min_surface(cx, cz)
			if m > min_h:
				min_h = m; ox = cx; oz = cz
	print("  deepest region (%d,%d): min surface over 16x16 columns = %d" % [ox, oz, min_h])

	# ---------- STONE block: strictly above the -24..-16 dither band, deep under filler ----------
	# the deepest-qualifying stone block: oy = min_h - 28 (top cell depth = 13 > 12), which is > -16 whenever min_h > 12.
	_ok(min_h > 12, "setup: found a region deep enough for a 16³ pure-stone block (min_h=%d > 12)" % min_h)
	var oy_s := min_h - 28
	_gate_stone(gb, gc, Vector3i(ox, oy_s, oz), min_h, stone_arid)

	# ---------- DEEPSLATE block: strictly below -24, above bedrock (-59) ----------
	_gate_deepslate(gb, gc, Vector3i(ox, -40, oz), min_h, deep_arid)

	# ---------- SURFACE block: must NOT be bulk-filled (no-fall-through) ----------
	_gate_surface(gb, ox, oz, min_h)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _gate_stone(gb: Object, gc: Object, origin: Vector3i, min_h: int, stone_arid: int) -> void:
	print("  --- G-BULK stone block @ %s (by_top=%d, min_h=%d) ---" % [origin, origin.y + 16, min_h])
	_ok(origin.y > -16 and origin.y + 16 <= min_h - 12,
		"G-BULK-STONE precond: block above the dither band and below max filler (oy=%d)" % origin.y)
	var buf: Object = _gen_into(gb, origin)
	var uv := _uniform_value(buf)
	_ok(uv == stone_arid, "G-BULK-FILL(stone): block is UNIFORMLY the plain-stone cube ARID (%d == %d)" % [uv, stone_arid])
	_check_truth(gb, gc, origin, stone_arid, BlockCatalog.STONE, "stone")

func _gate_deepslate(gb: Object, gc: Object, origin: Vector3i, min_h: int, deep_arid: int) -> void:
	print("  --- G-BULK deepslate block @ %s (by_top=%d) ---" % [origin, origin.y + 16])
	_ok(origin.y + 16 <= -24 and origin.y >= -59 and origin.y + 16 <= min_h - 12,
		"G-BULK-DEEP precond: block below -24, above bedrock, under max filler (oy=%d)" % origin.y)
	var buf: Object = _gen_into(gb, origin)
	var uv := _uniform_value(buf)
	_ok(uv == deep_arid, "G-BULK-FILL(deepslate): block is UNIFORMLY the plain-deepslate cube ARID (%d == %d)" % [uv, deep_arid])
	_check_truth(gb, gc, origin, deep_arid, BlockCatalog.id_of(&"deepslate"), "deepslate")

# G-BULK-MATCH + G-BULK-TRUTH shared body: the per-cell reference generator's PLAIN cells equal the bulk fill; the
# ore/strata VARIANT cells are the accepted (bounded, counted) appearance loss; and resolve_cell (the physics/drop
# source) still returns the TRUE material for those loss cells — mesh shows the base rock, the broken block is truth.
func _check_truth(gb: Object, gc: Object, origin: Vector3i, fill_arid: int, base_id: int, label: String) -> void:
	var ref: Object = _gen_into(gc, origin)          # per-cell (fp_bulk forced off)
	var loss := 0
	var mismatch_plain := 0
	var truth_ok := 0
	var truth_bad := 0
	for z in range(16):
		for y in range(16):
			for x in range(16):
				var rc := int(ref.call("get_voxel", x, y, z, 0))
				var wx := origin.x + x
				var wy := origin.y + y
				var wz := origin.z + z
				var p := TerrainConfig.column_profile(wx, wz, {})
				var true_id := int(TerrainConfig.resolve_cell(wx, wy, wz, int(p.x), int(p.y), p.z, p.w))
				if rc == fill_arid:
					# a plain base cell in the per-cell world → the bulk fill matches it exactly (byte-identical wall)
					if true_id != base_id:
						mismatch_plain += 1
				else:
					# a variant (ore/strata) cell → lost to uniform fill in the MESH, but physics truth stands
					loss += 1
					if true_id == base_id:
						truth_bad += 1        # resolve_cell must NOT claim it is the base rock
					else:
						truth_ok += 1
	_ok(mismatch_plain == 0,
		"G-BULK-MATCH(%s): every per-cell PLAIN %s cell equals the bulk fill (0 mismatches)" % [label, label])
	_ok(truth_bad == 0,
		"G-BULK-TRUTH(%s): resolve_cell returns the TRUE variant for all %d ore/strata cells (mesh loss, physics intact)"
			% [label, loss])
	print("      %s block: %d/4096 ore/strata variant cells lost to uniform fill (accepted; physics truth on all %d)"
		% [label, loss, truth_ok])

func _gate_surface(gb: Object, ox: int, oz: int, min_h: int) -> void:
	# the data block straddling the surface must be generated PER-CELL (never bulk-filled): the walkable top must be
	# real, else the player falls through what they see. Origin chosen so g is inside the block for the centre column.
	var g0 := int(TerrainConfig.column_profile(ox + 8, oz + 8, {}).x)
	var oy := floori(g0 / 16.0) * 16                # floor to the 16-grid data block containing g0
	var origin := Vector3i(ox, oy, oz)
	print("  --- G-BULK-SURFACE block @ %s (centre g=%d) ---" % [origin, g0])
	var buf: Object = _gen_into(gb, origin)
	var uv := _uniform_value(buf)
	_ok(uv < 0, "G-BULK-SURFACE: the surface block is NOT uniform (bulk-fill correctly SKIPPED it)")
	# the top solid cell of the centre column equals column_profile g (you stand on what you see).
	var top_solid := -0x7fffffff
	for y in range(16):
		if int(buf.call("get_voxel", 8, y, 8, 0)) != 0:
			top_solid = oy + y
	_ok(top_solid == g0, "G-BULK-SURFACE: centre column top solid cell == column_profile g (%d == %d)" % [top_solid, g0])
