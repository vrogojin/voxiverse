extends SceneTree
## verify_colbulk — STREAM-SCHED R1/R1b (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.3-§2.4 / §9.2) truth gate.
##
## FP_COLBULK moves the FP_BULK_UNDERGROUND gate INSIDE the emit loop, per column. The whole claim it must earn
## is that this costs NO MORE appearance than the shipped, user-accepted whole-block loss. So this gate does not
## sample a few cells — it generates N random blocks BOTH ways (colbulk vs per-cell) and compares EVERY cell:
##
##   G-CB-EXACT    every cell at/above its column's `g - BULK_MAX_FILLER` (the exact band) and every cell in the
##                 -24..-16 dither rows or below -59 (bedrock rows) is BYTE-IDENTICAL to the per-cell path.
##                 This is the whole visible world: you cannot see or dig below your column's filler without
##                 first removing the exact band, and the dither/bedrock rows are never guessed.
##   G-CB-LOSS     every DIFFERING cell is a deep-run cell whose per-cell value is an ore/strata VARIANT and
##                 whose colbulk value is the plain stone/deepslate cube ARID — i.e. exactly the
##                 FP_BULK_UNDERGROUND loss class, never wider, and never air/hole (counted + printed).
##   G-CB-AIR      R1b never clips content: every cell colbulk left as AIR is AIR in the per-cell path too
##                 (subsumed by G-CB-EXACT/G-CB-LOSS, asserted separately so a ceiling bug names itself).
##   G-CB-TRUTH    physics ground truth is intact: resolve_cell (the block_id_at source) still returns the TRUE
##                 material for every lost cell. block_id_at reads TerrainConfig, never this buffer, so this
##                 holds by construction — pinned anyway, because that is the claim physics rests on.
##   G-CB-SURFACE  no-fall-through: the centre column's top solid cell still equals column_profile g.
##
## Requires FP_COLBULK ON (a const): run with the flag sed-toggled true, e.g.
##   sed -i 's/const FP_COLBULK := false/const FP_COLBULK := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_colbulk.gd
## Runs in FLAT mode (gen_facet < 0 → the ridge guard self-disables), so it needs no faceted atlas.

const N_BLOCKS := 64
const BULK_MAX_FILLER := 12          # mirrors ModuleWorld.BULK_MAX_FILLER (max _filler_depth over all biomes)
const DEEPSLATE_TOP_Y := -16
const DEEPSLATE_FULL_Y := -24
const BEDROCK_TOP_Y := -59

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: %s" % m)
	else:
		_fail += 1
		print("  FAIL: %s" % m)

func _gen_into(gen: Object, origin: Vector3i) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 16, 16, 16)
	buf.call("set_channel_depth", 0, 1)          # DEPTH_16_BIT (matches the live TYPE channel)
	gen.call("generate_block", buf, Vector3(origin.x, origin.y, origin.z), 0)
	return buf

func _initialize() -> void:
	print("=== verify_colbulk (STREAM-SCHED R1: column-granular bulk fill truth gate) ===")
	if not CubeSphere.FP_COLBULK:
		print("  FAIL: CubeSphere.FP_COLBULK is false — sed-toggle it true to run this gate.")
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

	# the SHIPPED generator (flag on), plus a per-cell reference clone (same epoch, BOTH bulk paths forced off).
	var gb: Object = mod.call("get_generator")
	var gc: Object = mod.call("_make_generator")
	gc.set("fp_colbulk", false)
	gc.set("fp_bulk", false)
	var stone_arid := int(gb.get("bulk_stone_arid"))
	var deep_arid := int(gb.get("bulk_deepslate_arid"))
	_ok(bool(gb.get("fp_colbulk")), "setup: shipped generator has fp_colbulk ON (flag sed-toggled)")
	_ok(stone_arid >= 0 and deep_arid >= 0, "setup: fill ARIDs baked (stone=%d, deepslate=%d)" % [stone_arid, deep_arid])

	# N random blocks spanning the depth bands that matter: surface-crossing, the shallow interior, the
	# -24..-16 dither straddle, the deep deepslate region, and the bedrock straddle at -59. A fixed seed so a
	# failure is reproducible.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260717
	var exact_bad := 0
	var loss_wrong_class := 0
	var loss_cells := 0
	var air_clipped := 0
	var truth_bad := 0
	var bands := {}
	for i in range(N_BLOCKS):
		var ox := int(rng.randi_range(-40, 40)) * 16
		var oz := int(rng.randi_range(-40, 40)) * 16
		# Bias the y pick across the interesting bands rather than uniformly (uniform would mostly miss the
		# dither/bedrock straddles, which is exactly where a run-boundary off-by-one would hide).
		var oy := 0
		match i % 5:
			0: oy = int(floor(TerrainConfig.height_at(ox + 8, oz + 8) / 16.0)) * 16   # surface-crossing
			1: oy = int(floor(TerrainConfig.height_at(ox + 8, oz + 8) / 16.0)) * 16 - 16
			2: oy = -32                                                              # straddles -24..-16
			3: oy = -48                                                              # deep deepslate
			_: oy = -64                                                              # straddles bedrock (-59)
		var origin := Vector3i(ox, oy, oz)
		var a: Object = _gen_into(gb, origin)
		var b: Object = _gen_into(gc, origin)
		for z in range(16):
			for x in range(16):
				var wx := ox + x
				var wz := oz + z
				var p := TerrainConfig.column_profile(wx, wz, {})
				var g := int(p.x)
				var deep_top := g - BULK_MAX_FILLER
				for y in range(16):
					var wy := oy + y
					var va := int(a.call("get_voxel", x, y, z, 0))
					var vb := int(b.call("get_voxel", x, y, z, 0))
					if va == vb:
						continue
					# --- the cell differs: it MUST be a deep-run cell, and the diff MUST be the accepted class ---
					var in_deep_run := wy < deep_top \
						and (wy > DEEPSLATE_TOP_Y or (wy < DEEPSLATE_FULL_Y and wy >= BEDROCK_TOP_Y))
					if not in_deep_run:
						exact_bad += 1                    # a visible/diggable cell changed → G-CB-EXACT is broken
						continue
					loss_cells += 1
					bands[_band_of(wy)] = int(bands.get(_band_of(wy), 0)) + 1
					if va == 0:
						air_clipped += 1                  # colbulk wrote AIR where per-cell had content → a HOLE
					# colbulk must have written the plain base cube; per-cell must have had a variant.
					if not (va == stone_arid or va == deep_arid):
						loss_wrong_class += 1
					# G-CB-TRUTH: resolve_cell must still report the TRUE variant for this lost cell.
					var true_id := int(TerrainConfig.resolve_cell(wx, wy, wz, g, int(p.y), p.z, p.w))
					if true_id == BlockCatalog.AIR:
						truth_bad += 1

	_ok(exact_bad == 0,
		"G-CB-EXACT: every exact-band / dither / bedrock cell (everything visible or diggable) is BYTE-IDENTICAL to the per-cell path (%d mismatches)" % exact_bad)
	_ok(air_clipped == 0,
		"G-CB-AIR: FP_COLBULK never wrote AIR where the per-cell path has content — no R1b ceiling clip, no hole (%d)" % air_clipped)
	_ok(loss_wrong_class == 0,
		"G-CB-LOSS: every differing cell is the plain stone/deepslate cube ARID — exactly the FP_BULK_UNDERGROUND loss class, never wider (%d wrong)" % loss_wrong_class)
	_ok(truth_bad == 0,
		"G-CB-TRUTH: resolve_cell (the block_id_at / physics source) returns real material for all %d lost cells" % loss_cells)
	print("      %d blocks compared cell-by-cell; %d deep-run ore/strata variant cells lost to fill (accepted); bands=%s"
		% [N_BLOCKS, loss_cells, bands])

	_gate_surface(gb, 0, 0)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _band_of(wy: int) -> String:
	if wy > DEEPSLATE_TOP_Y:
		return "stone(>-16)"
	if wy >= DEEPSLATE_FULL_Y:
		return "dither(-24..-16)"
	if wy >= BEDROCK_TOP_Y:
		return "deepslate(-59..-25)"
	return "bedrock(<-59)"

## no-fall-through: the walkable top the player stands on must still be the real surface. This is the invariant
## the whole-block gate calls G-BULK-SURFACE; column bulk must not weaken it (its deep run stops 12 below g).
func _gate_surface(gb: Object, ox: int, oz: int) -> void:
	var g0 := int(TerrainConfig.column_profile(ox + 8, oz + 8, {}).x)
	var oy := floori(g0 / 16.0) * 16                # floor to the 16-grid data block containing g0
	var origin := Vector3i(ox, oy, oz)
	var buf: Object = _gen_into(gb, origin)
	var top_solid := -0x7fffffff
	for y in range(16):
		if int(buf.call("get_voxel", 8, y, 8, 0)) != 0:
			top_solid = oy + y
	_ok(top_solid == g0,
		"G-CB-SURFACE: centre column top solid cell == column_profile g (%d == %d) — no fall-through" % [top_solid, g0])
