extends SceneTree
## COSMOS-ATLAS Stage 1 gate (docs/COSMOS-ATLAS-DESIGN.md §4.2) — the OPAQUE-cube atlas: coverage, UVs, and the ONE
## shared material. Runs headless with FP_ATLAS_MATERIAL sed-toggled true (like verify_fp_m2's FACETED/FP_M2_LOD).
## Proves, on the ACTUAL built library (not by eye):
##   G-ATLAS-COVER  every opaque cube id maps to a baked atlas cell, and that cell holds the id's REAL tile/swatch
##                  (sample the atlas image at the cell centre vs the source tile centre / the swatch colour) — no id
##                  points at an unbaked / empty / wrong cell.
##   G-ATLAS-UV     every opaque cube model is configured with the library-wide atlas grid + every face's set_tile is
##                  the id's cell (the exact UV rect bake() emits), and that rect is inside [0,1]².
##   G-ATLAS-MAT    every opaque cube model's material_override(0) is the ONE shared atlas material INSTANCE (is_same),
##                  so the mesher merges them into one surface; a translucent id (glass) is NOT on it (kept per-id).
##
## RUN:
##   sed -i 's/const FP_ATLAS_MATERIAL := false/const FP_ATLAS_MATERIAL := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_atlas.gd 2> stderr.log
## then REVERT the sed. Exits 0 all-pass / 1 on any failure. Runs in the default FLAT world (FACETED stays false) —
## the module library build (and the atlas routing) is facet-independent.

const BA := preload("res://src/world/voxel_module/block_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_atlas (COSMOS-ATLAS Stage 1: opaque cubes on a shared atlas material) ===")
	if not CubeSphere.FP_ATLAS_MATERIAL:
		print("  FAIL: CubeSphere.FP_ATLAS_MATERIAL is false — sed-toggle it true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent (ClassDB has no VoxelTerrain) — this gate needs the module binary.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return

	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()

	# Build the module world (which builds the atlas + routes the opaque cubes under the flag).
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	var ok_setup: bool = bool(mod.call("setup"))
	_ok(ok_setup, "setup: module_world built the terrain + baked library (atlas routed)")
	if not ok_setup:
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail]); quit(1); return

	var atlas = mod.call("atlas")
	_ok(atlas != null, "setup: the module built a BlockAtlas under FP_ATLAS_MATERIAL")
	if atlas == null:
		_teardown(mod); return
	_ok(atlas.material != null and atlas.image != null and atlas.texture != null,
		"setup: atlas has a material + image + texture")

	# enumerate the opaque cube ids (the atlas set) and a couple of NON-opaque controls.
	var total := BlockCatalog.count()
	var opaque := PackedInt32Array()
	var translucent := PackedInt32Array()
	for id in range(1, total):
		if BA.is_opaque_cube(id):
			opaque.append(id)
		elif BlockCatalog.cull_group_of(id) > 0:
			translucent.append(id)
	print("  opaque cube ids=%d  translucent controls=%d  atlas cells used=%d/%d" % [
		opaque.size(), translucent.size(), atlas.celled_ids().size(), BA.GRID * BA.GRID])

	_gate_cover(atlas, opaque)
	_gate_uv(mod, atlas, opaque)
	_gate_mat(mod, atlas, opaque, translucent)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	_teardown(mod)

func _teardown(mod: Node3D) -> void:
	if is_instance_valid(mod):
		if mod.get_parent() != null:
			mod.get_parent().remove_child(mod)
		mod.free()
	quit(1 if _fail > 0 else 0)

# ---------- G-ATLAS-COVER: every opaque id → a cell holding its REAL look ----------
func _gate_cover(atlas, opaque: PackedInt32Array) -> void:
	print("  --- G-ATLAS-COVER: every opaque cube id maps to a baked cell holding its real tile/swatch ---")
	var missing := 0
	var wrong := 0
	var first_missing := -1
	var first_wrong := -1
	for id in opaque:
		if not atlas.has_cell(id):
			missing += 1
			if first_missing < 0: first_missing = id
			continue
		var cell: Vector2i = atlas.cell_of(id)
		# out-of-range cell would sample outside the atlas → a hole/wrong tile.
		if cell.x < 0 or cell.y < 0 or cell.x >= BA.GRID or cell.y >= BA.GRID:
			wrong += 1
			if first_wrong < 0: first_wrong = id
			continue
		var cx: int = cell.x * BA.CELL_PX + BA.CELL_PX / 2
		var cy: int = cell.y * BA.CELL_PX + BA.CELL_PX / 2
		var got: Color = atlas.image.get_pixel(cx, cy)
		var stem: String = BlockTextures.TILES.get(StringName(BlockCatalog.name_of(id)), "")
		var want: Color
		if stem != "":
			var src: Image = (load("%s/%s.png" % [BlockTextures.DIR, stem]) as Texture2D).get_image()
			if src.is_compressed(): src.decompress()
			if src.get_format() != Image.FORMAT_RGBA8: src.convert(Image.FORMAT_RGBA8)
			if src.get_width() != BA.CELL_PX or src.get_height() != BA.CELL_PX:
				src.resize(BA.CELL_PX, BA.CELL_PX, Image.INTERPOLATE_NEAREST)
			want = src.get_pixel(BA.CELL_PX / 2, BA.CELL_PX / 2)
		else:
			var c := BlockCatalog.color_of(id)
			want = Color(c.r, c.g, c.b, 1.0)
		if not _color_close(got, want):
			wrong += 1
			if first_wrong < 0: first_wrong = id
			print("    id %d (%s) cell (%d,%d): atlas=%s want=%s" % [id, BlockCatalog.name_of(id), cell.x, cell.y, str(got), str(want)])
	_ok(missing == 0, "G-ATLAS-COVER: every opaque cube id has an atlas cell (%d missing%s)" % [
		missing, "" if first_missing < 0 else ", first id=%d" % first_missing])
	_ok(wrong == 0, "G-ATLAS-COVER: every atlas cell holds the id's real tile/swatch (%d wrong%s)" % [
		wrong, "" if first_wrong < 0 else ", first id=%d" % first_wrong])

# ---------- G-ATLAS-UV: each opaque cube's faces point at the id's cell ----------
func _gate_uv(mod: Node3D, atlas, opaque: PackedInt32Array) -> void:
	print("  --- G-ATLAS-UV: every opaque cube model's 6 faces sample the id's atlas cell (UVs in [0,1]) ---")
	var bad_grid := 0
	var bad_tile := 0
	var bad_rect := 0
	var checked := 0
	var first_bad := -1
	for id in opaque:
		var arid: int = mod.call("cube_arid_of", id)
		var model: Object = mod.call("library_model", arid)
		if model == null or not model.has_method("get_tile") or not model.has_method("get_atlas_size_in_tiles"):
			continue
		checked += 1
		var cell: Vector2i = atlas.cell_of(id)
		var gsz: Vector2i = model.call("get_atlas_size_in_tiles")
		if gsz != atlas.grid:
			bad_grid += 1
			if first_bad < 0: first_bad = id
		for side in 6:
			var t: Vector2i = model.call("get_tile", side)
			if t != cell:
				bad_tile += 1
				if first_bad < 0: first_bad = id
				break
		# the UV rect the bake emits (cell / grid) must sit inside [0,1]² for all 4 corners.
		var r: Rect2 = atlas.cell_uv_rect(id)
		if r.position.x < 0.0 or r.position.y < 0.0 or r.end.x > 1.0 + 1e-6 or r.end.y > 1.0 + 1e-6:
			bad_rect += 1
			if first_bad < 0: first_bad = id
	_ok(checked == opaque.size(), "G-ATLAS-UV: read back all %d opaque cube models (%d checked)" % [opaque.size(), checked])
	_ok(bad_grid == 0, "G-ATLAS-UV: every opaque cube uses the atlas grid %s (%d wrong%s)" % [
		str(atlas.grid), bad_grid, "" if first_bad < 0 else ", first id=%d" % first_bad])
	_ok(bad_tile == 0, "G-ATLAS-UV: every opaque cube's 6 faces point at the id's cell (%d wrong)" % bad_tile)
	_ok(bad_rect == 0, "G-ATLAS-UV: every opaque cube's UV rect lies inside [0,1]² (%d out-of-range)" % bad_rect)

# ---------- G-ATLAS-MAT: opaque cubes share ONE material instance; translucent stays per-id ----------
func _gate_mat(mod: Node3D, atlas, opaque: PackedInt32Array, translucent: PackedInt32Array) -> void:
	print("  --- G-ATLAS-MAT: all opaque cubes share the ONE atlas material instance (mesher merges them) ---")
	var shared: Object = atlas.material
	var not_shared := 0
	var first_bad := -1
	var on_atlas := 0
	for id in opaque:
		var arid: int = mod.call("cube_arid_of", id)
		var model: Object = mod.call("library_model", arid)
		if model == null or not model.has_method("get_material_override"):
			continue
		var mo: Object = model.call("get_material_override", 0)
		if is_same(mo, shared):
			on_atlas += 1
		else:
			not_shared += 1
			if first_bad < 0: first_bad = id
	_ok(not_shared == 0 and on_atlas == opaque.size(),
		"G-ATLAS-MAT: all %d opaque cubes are on the SAME atlas material instance (%d not shared%s)" % [
			opaque.size(), not_shared, "" if first_bad < 0 else ", first id=%d" % first_bad])
	# a translucent control (glass/ice/…) must NOT be on the atlas material (kept per-id — Stage 3).
	var control_off_atlas := true
	var checked_ctrl := 0
	for id in translucent:
		var arid: int = mod.call("cube_arid_of", id)
		var model: Object = mod.call("library_model", arid)
		if model == null or not model.has_method("get_material_override"):
			continue
		checked_ctrl += 1
		if is_same(model.call("get_material_override", 0), shared):
			control_off_atlas = false
	_ok(checked_ctrl > 0 and control_off_atlas,
		"G-ATLAS-MAT: translucent ids (%d checked) are NOT on the atlas material (kept per-id for Stage 3)" % checked_ctrl)

func _color_close(a: Color, b: Color) -> bool:
	var tol := 3.0 / 255.0
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol and absf(a.a - b.a) <= tol
