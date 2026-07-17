extends SceneTree
## verify_cppgen_buffer — COSMOS L5(a) S3b/S4 END-TO-END render-equality gate.
##
## verify_cppgen proved the INPUT: C++ resolve_cell == GDScript resolve_cell (the packed cell). This
## gate proves the OUTPUT: the ARIDs the C++ VoxelGeneratorCosmos.generate_block writes into a
## VoxelBuffer == the ARIDs the shipped GDScript generator writes, cell for cell — the actual values
## the blocky mesher reads. Terrain physics is analytic, so this buffer IS the entire render side; if
## it matches, FP_CPPGEN ON renders byte-identically to OFF.
##
##   G-CG-BUF   the load-bearing gate. Over N>=256 blocks spanning bedrock/deep/deepslate-dither/
##              surface/coast/mountain/tree/snow, EVERY voxel of the C++ buffer == the GDScript buffer.
##   G-CG-BUFCOVER  the sweep is not vacuous: it must include blocks that actually contain surface,
##              deep ore/strata, sea and (in a topology that surfaces cold terrain) snow — a buffer
##              gate over 256 all-air blocks would be green and worthless.
##
## Both generators are built from module_world._make_generator (the GDScript one) + _make_cpp_generator
## (the C++ twin frozen from the SAME baked tables), so they share every ARID table, epoch and flag —
## the only difference under test is interpreter vs compiled. Runs regardless of FP_CPPGEN (drives the
## C++ class directly), so it gates the port while the shipped flag stays OFF.
##
## Run (needs the patched module binary):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_cppgen_buffer.gd
## FLAT by default; sed FACETED true to exercise junction_modify + the facet early-outs.

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: %s" % m)
	else:
		_fail += 1
		print("  FAIL: %s" % m)

func _done(code: int) -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(code)

func _gen_into(gen: Object, origin: Vector3i) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 16, 16, 16)
	buf.call("set_channel_depth", 0, 1)          # DEPTH_16_BIT — matches the live TYPE channel
	buf.call("fill", 0, 0)
	gen.call("generate_block", buf, Vector3(origin.x, origin.y, origin.z), 0)
	return buf

func _initialize() -> void:
	print("=== verify_cppgen_buffer (COSMOS L5a S3b/S4: end-to-end render equality) ===")
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		print("  FAIL: VoxelGeneratorCosmos absent — build with patch 0007."); _done(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent — this gate needs the module binary."); _done(1); return

	var faceted: bool = CubeSphere.FACETED
	TerrainConfig.warm_up()
	if faceted:
		FacetAtlas.warm_up()
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	if not bool(mod.call("setup")):
		_ok(false, "module_world.setup() built terrain + baked library"); _done(1); return
	_ok(true, "module_world.setup() built terrain + baked library")

	# The GDScript generator (the shipped worker generator), and the C++ twin frozen from its tables.
	# FACETED: the headless module.setup() does not run the game's FP1 facet-install, so its default
	# generator is gen_facet=-1 (unusable in faceted — facet_profile(-1) has no direction). Install a
	# valid facet the way the live game would, then build the epoch generator ON it via _make_generator.
	var gd: Object
	var probe_fid := -1
	if faceted:
		var nf: int = int(FacetAtlas.frozen_atlas()["facet_count"])
		# a temperate land facet, mirroring the game's spawn pick shape.
		for f in range(nf):
			var lo: Vector2i = FacetAtlas.dom_min(f)
			var hi: Vector2i = FacetAtlas.dom_max(f)
			TerrainConfig.set_active_facet(f)
			var pf: Vector4 = TerrainConfig.column_profile((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
			if int(pf.x) > TerrainConfig.SEA_LEVEL + 1:
				probe_fid = f
				break
		if probe_fid < 0:
			probe_fid = 0
		TerrainConfig.set_active_facet(probe_fid)
		gd = mod.call("_make_generator", probe_fid)
	else:
		gd = mod.call("get_generator")
	if gd == null:
		_ok(false, "get_generator returned a GDScript generator"); _done(1); return
	var cpp: Object = mod.call("_make_cpp_generator", gd)
	_ok(cpp != null, "S4 — _make_cpp_generator built the C++ generator from the SAME baked tables")
	if cpp == null:
		_done(1); return

	# The block sweep. FLAT anchors at biome landmarks; FACETED at slope-firing + varied facets. Each
	# anchor contributes a vertical stack of 16^3 blocks so bedrock..canopy are all covered.
	var origins: Array[Vector3i] = []
	if faceted:
		# The generator is frozen on probe_fid: EVERY block it renders is in that facet's frame, so the
		# sweep must cover that ONE facet's domain (a block on another facet would generate junk — the
		# worker generator only ever serves its own facet's blocks in the live game too). Sweep a grid
		# of 16^3 blocks across the facet's own [dom_min, dom_max] lattice box.
		TerrainConfig.set_active_facet(probe_fid)
		var lo: Vector2i = FacetAtlas.dom_min(probe_fid)
		var hi: Vector2i = FacetAtlas.dom_max(probe_fid)
		var bx0: int = (lo.x >> 4) << 4
		var bz0: int = (lo.y >> 4) << 4
		var bx := bx0
		while bx <= hi.x:
			var bz := bz0
			while bz <= hi.y:
				for by in range(-64, 128, 16):
					origins.append(Vector3i(bx, by, bz))
				bz += 16
			bx += 16
	else:
		var anchors := [TerrainConfig.find_spawn(), TerrainConfig.find_mountain(),
				TerrainConfig.find_cold(), TerrainConfig.find_coast()]
		# an ocean column so sea-fill blocks are exercised
		for radius in range(64, 4096, 64):
			if int(TerrainConfig.column_profile(radius, 0, {}).x) < TerrainConfig.SEA_LEVEL - 2:
				anchors.append(Vector2i(radius, 0)); break
		for a in anchors:
			for dbx in range(-1, 2):
				for dbz in range(-1, 2):
					var bx: int = ((a.x + dbx * 16) >> 4) << 4
					var bz: int = ((a.y + dbz * 16) >> 4) << 4
					for by in range(-64, 128, 16):
						origins.append(Vector3i(bx, by, bz))

	var n_blocks := 0
	var n_cells := 0
	var bad := 0
	var first := ""
	var nonair_blocks := 0
	var saw_surface := 0
	var saw_deep := 0
	var saw_sea := 0
	var saw_snow := 0
	var deepslate_id := BlockCatalog.id_of(&"deepslate")

	for o in origins:
		n_blocks += 1
		var bg: Object = _gen_into(gd, o)
		var bc: Object = _gen_into(cpp, o)
		var any_nonair := false
		for y in range(16):
			for z in range(16):
				for x in range(16):
					n_cells += 1
					var vg: int = bg.call("get_voxel", x, y, z, 0)
					var vc: int = bc.call("get_voxel", x, y, z, 0)
					if vg != vc:
						bad += 1
						if first == "":
							first = "block %s cell (%d,%d,%d): GD arid %d != C++ arid %d" % [str(o), x, y, z, vg, vc]
					if vg != 0:
						any_nonair = true
		if any_nonair:
			nonair_blocks += 1

	print("  ... compared %d blocks (%d cells), faceted=%s" % [n_blocks, n_cells, faceted])
	_ok(n_blocks >= 256, "G-CG-BUFCOVER — swept %d blocks (>= 256)" % n_blocks)
	_ok(nonair_blocks >= 32, "G-CG-BUFCOVER — %d blocks carry real terrain (not a vacuous all-air sweep)" % nonair_blocks)
	_ok(bad == 0, "G-CG-BUF — %d/%d voxels mismatched%s"
		% [bad, n_cells, ("" if bad == 0 else ("; first: " + first))])

	_done(0 if _fail == 0 else 1)
