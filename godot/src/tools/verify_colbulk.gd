extends SceneTree
## verify_colbulk — STREAM-SCHED R1/R1b (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.3-§2.4 / §9.2) truth gate.
##
## FP_COLBULK guesses deep cells (plain stone/deepslate instead of their ore/strata variant). That is only
## legitimate for cells the player CANNOT SEE. So the oracle here is EXPOSURE, not depth:
##
##   G-CB-EXPOSED  the load-bearing gate. Over a WIDE sweep of blocks (deliberately including shorelines and
##                 the steepest terrain the generator can make), EVERY cell with any see-through face-neighbour
##                 is byte-identical to the analytic per-cell truth. "see-through" is strict: a neighbour is
##                 see-through unless it is a FULL OPAQUE CUBE — air, ANY liquid field (water is transparent,
##                 so a coastal face renders), or ANY non-zero modifier (a slope/cap/layer neighbour is a
##                 partial shape and leaves a real gap). Neighbours are read ANALYTICALLY, so this crosses
##                 block boundaries — the buffer's own edge cells are checked against terrain outside it.
##                 v1 of this gate asked "is the cell below its column's g-12", which is a DEPTH oracle, not
##                 an exposure oracle: it passed 8/0 while FLAT failed. That is the hole this closes.
##   G-CB-BURIED   every remaining (buried) mismatch is the plain stone/deepslate cube ARID — the
##                 FP_BULK_UNDERGROUND loss class, never air/hole, never a different material.
##   G-CB-TRUTH    physics ground truth intact: the analytic path (the block_id_at source) still returns the
##                 TRUE material for every guessed cell. Holds by construction (block_id_at never reads this
##                 buffer) — pinned anyway, because it is the claim physics rests on.
##   G-CB-SURFACE  no-fall-through: the centre column's top solid cell still equals column_profile g.
##
## Requires FP_COLBULK ON (a const): run with the flag sed-toggled true, e.g.
##   sed -i 's/const FP_COLBULK := false/const FP_COLBULK := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_colbulk.gd
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

func _tru(x: int, y: int, z: int) -> int:
	return TerrainConfig.generated_cell(x, y, z)

## A face against this neighbour is VISIBLE unless the neighbour is a full opaque cube.
func _see_through(v: int) -> bool:
	return CellCodec.mat(v) == BlockCatalog.AIR or CellCodec.liquid_field(v) != 0 or CellCodec.modifier(v) != 0

func _gen_into(gen: Object, origin: Vector3i) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 16, 16, 16)
	buf.call("set_channel_depth", 0, 1)          # DEPTH_16_BIT (matches the live TYPE channel)
	buf.call("fill", 0, 0)
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

	var gb: Object = mod.call("get_generator")
	var stone_arid := int(gb.get("bulk_stone_arid"))
	var deep_arid := int(gb.get("bulk_deepslate_arid"))
	_ok(bool(gb.get("fp_colbulk")), "setup: shipped generator has fp_colbulk ON (flag sed-toggled)")
	_ok(stone_arid >= 0 and deep_arid >= 0, "setup: fill ARIDs baked (stone=%d, deepslate=%d)" % [stone_arid, deep_arid])

	# The sweep. Surface blocks + the block under each, over a wide area, so shorelines and the steepest
	# relief the height field produces are included — those are exactly where a per-column (non-neighbour-
	# aware) deep bound would expose a guessed cell. Plus the fixed deep origins verify_feature drives, plus
	# the MOUNTAINS massifs (amplitude 92 — the steepest steps the generator can make).
	var origins: Array[Vector3i] = []
	for bx in range(-8, 9, 2):
		for bz in range(-8, 9, 2):
			var ox := bx * 16
			var oz := bz * 16
			var gy: int = TerrainConfig.height_at(ox + 8, oz + 8)
			origins.append(Vector3i(ox, floori(gy / 16.0) * 16, oz))
			origins.append(Vector3i(ox, floori(gy / 16.0) * 16 - 16, oz))
	for o: Vector3i in [Vector3i(0, -64, 0), Vector3i(0, -16, 0), Vector3i(-80, -32, 16), Vector3i(128, -8, -64)]:
		origins.append(o)
	for mc: Vector2i in TerrainConfig.find_mountains(3):
		var mg: int = TerrainConfig.height_at(mc.x, mc.y)
		origins.append(Vector3i(floori(mc.x / 16.0) * 16, floori(mg / 16.0) * 16, floori(mc.y / 16.0) * 16))
		origins.append(Vector3i(floori(mc.x / 16.0) * 16, floori(mg / 16.0) * 16 - 16, floori(mc.y / 16.0) * 16))

	var exposed_bad := 0
	var buried_wrong_class := 0
	var buried := 0
	var truth_bad := 0
	var first := ""
	for origin: Vector3i in origins:
		var buf: Object = _gen_into(gb, origin)
		for lz in range(16):
			for lx in range(16):
				var wx := origin.x + lx
				var wz := origin.z + lz
				var p := TerrainConfig.column_profile(wx, wz, {})
				for ly in range(16):
					var wy := origin.y + ly
					var got := int(buf.call("get_voxel", lx, ly, lz, 0))
					var v := _tru(wx, wy, wz)
					var expected := int(mod.call("gen_arid_for", CellCodec.mat(v), CellCodec.modifier(v),
						CellCodec.liquid_level(v), CellCodec.liquid_kind(v), CellCodec.state(v)))
					if got == expected:
						continue
					# This cell was guessed. It is only legitimate if NOTHING can see it.
					var vis := _see_through(_tru(wx + 1, wy, wz)) or _see_through(_tru(wx - 1, wy, wz)) \
						or _see_through(_tru(wx, wy + 1, wz)) or _see_through(_tru(wx, wy - 1, wz)) \
						or _see_through(_tru(wx, wy, wz + 1)) or _see_through(_tru(wx, wy, wz - 1))
					if vis:
						exposed_bad += 1
						if first == "":
							first = "(%d,%d,%d) own_g=%d depth=%d got=%d expected=%d" % [wx, wy, wz, int(p.x), int(p.x) - wy, got, expected]
						continue
					buried += 1
					if got != stone_arid and got != deep_arid:
						buried_wrong_class += 1
					if CellCodec.mat(v) == BlockCatalog.AIR:
						truth_bad += 1

	_ok(exposed_bad == 0,
		"G-CB-EXPOSED: over %d blocks (incl. shorelines + mountain massifs), every cell with a see-through face-neighbour is byte-identical to analytic truth (%d violations%s)"
			% [origins.size(), exposed_bad, ("" if first == "" else "; first " + first)])
	_ok(buried_wrong_class == 0,
		"G-CB-BURIED: every buried guess is the plain stone/deepslate cube ARID — the FP_BULK_UNDERGROUND loss class, never wider (%d wrong)" % buried_wrong_class)
	_ok(truth_bad == 0,
		"G-CB-TRUTH: the analytic path (the block_id_at / physics source) returns real material for all %d guessed cells — never air" % buried)
	print("      %d blocks swept; %d buried ore/strata variant cells guessed (accepted, invisible); %d exposed violations"
		% [origins.size(), buried, exposed_bad])

	_gate_surface(gb, 0, 0)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## no-fall-through: the walkable top must still be the real surface (the whole-block gate's G-BULK-SURFACE).
func _gate_surface(gb: Object, ox: int, oz: int) -> void:
	var g0 := int(TerrainConfig.column_profile(ox + 8, oz + 8, {}).x)
	var oy := floori(g0 / 16.0) * 16
	var buf: Object = _gen_into(gb, Vector3i(ox, oy, oz))
	var top_solid := -0x7fffffff
	for y in range(16):
		if int(buf.call("get_voxel", 8, y, 8, 0)) != 0:
			top_solid = oy + y
	_ok(top_solid == g0,
		"G-CB-SURFACE: centre column top solid cell == column_profile g (%d == %d) — no fall-through" % [top_solid, g0])
