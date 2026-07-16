extends SceneTree
## COSMOS-ATLAS Stage 1+2 gate (docs/COSMOS-ATLAS-DESIGN.md §4.2/§2.4) — the OPAQUE atlas: coverage, UVs, and the ONE
## shared material, over BOTH the cubes (Stage 1) AND the shaped/composite families (Stage 2). Runs headless with
## FP_ATLAS_MATERIAL sed-toggled true (like verify_fp_m2's FACETED/FP_M2_LOD). Proves, on the ACTUAL built library
## (not by eye):
##   G-ATLAS-COVER          every opaque cube id maps to a baked atlas cell holding its REAL tile/swatch, and every
##                          cappable base has a snow-CAP cell holding the snow tile × its base tint (§2.6) — no look
##                          points at an unbaked / empty / wrong cell.
##   G-ATLAS-UV             every opaque cube model uses the atlas grid + points its 6 faces at its cell (rect in
##                          [0,1]²); and every atlas-routed SHAPED surface's baked vertex UVs lie inside its cell rect.
##   G-ATLAS-MAT            every opaque cube AND every atlas-routed shaped surface's material_override(i) is the ONE
##                          shared atlas material INSTANCE (is_same) so the mesher merges them; a translucent id (glass)
##                          is NOT on it (kept per-id).
## The shaped gates replay the manifest's own probe record (module capture_atlas_probes → atlas_shaped_probes()), so
## they cover exactly the (mat,modifier) shapes the bake routed onto the atlas.
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

	# Build the module world (which builds the atlas + routes the opaque cubes AND shaped families under the flag).
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	mod.set("capture_atlas_probes", true)   # Stage 2: arm the shaped-model probe record BEFORE setup bakes the manifest
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
	# Stage 2 — the shaped OPAQUE families (dry corner shapes, snow caps, layers, composites, slopes).
	_gate_snowcap_cover(atlas)
	_gate_shaped(mod, atlas)

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

# ---------- G-ATLAS-COVER (Stage 2): every snow-CAP variant cell holds the tinted snow tile ----------
func _gate_snowcap_cover(atlas) -> void:
	print("  --- G-ATLAS-COVER(snow-cap): every cappable/fill base has a snow-cap cell holding the tinted snow tile ---")
	# The union the atlas registers (module snow variants + slope twins over snow_cappable; composite skins over
	# snow_fill — which adds snow_block itself). Every one must have a cell holding snow×tint, or a composite skin holes.
	var capset := {}
	for m in TerrainConfig.snow_cappable_materials():
		capset[m] = true
	for m in TerrainConfig.snow_fill_materials():
		capset[m] = true
	var caps := PackedInt32Array()
	for m: int in capset.keys():
		caps.append(m)
	var missing := 0
	var wrong := 0
	var first_missing := -1
	var first_wrong := -1
	# The snow_block source tile, resized to the atlas cell, sampled at centre — the un-tinted reference.
	var snow_id := BlockCatalog.id_of(&"snow_block")
	var snow_stem: String = BlockTextures.TILES.get(StringName(BlockCatalog.name_of(snow_id)), "")
	var snow_center := Color(1, 1, 1, 1)
	if snow_stem != "":
		var src: Image = (load("%s/%s.png" % [BlockTextures.DIR, snow_stem]) as Texture2D).get_image()
		if src.is_compressed(): src.decompress()
		if src.get_format() != Image.FORMAT_RGBA8: src.convert(Image.FORMAT_RGBA8)
		if src.get_width() != BA.CELL_PX or src.get_height() != BA.CELL_PX:
			src.resize(BA.CELL_PX, BA.CELL_PX, Image.INTERPOLATE_NEAREST)
		snow_center = src.get_pixel(BA.CELL_PX / 2, BA.CELL_PX / 2)
	for base in caps:
		if not atlas.has_snow_cap_cell(base):
			missing += 1
			if first_missing < 0: first_missing = base
			continue
		var cell: Vector2i = atlas.snow_cap_cell_of(base)
		if cell.x < 0 or cell.y < 0 or cell.x >= BA.GRID or cell.y >= BA.GRID:
			wrong += 1
			if first_wrong < 0: first_wrong = base
			continue
		var tint: Color = lerp(Color.WHITE, BlockCatalog.color_of(base), BA.SNOW_CAP_TINT)
		var want := Color(snow_center.r * tint.r, snow_center.g * tint.g, snow_center.b * tint.b, snow_center.a)
		var cx: int = cell.x * BA.CELL_PX + BA.CELL_PX / 2
		var cy: int = cell.y * BA.CELL_PX + BA.CELL_PX / 2
		var got: Color = atlas.image.get_pixel(cx, cy)
		if not _color_close(got, want):
			wrong += 1
			if first_wrong < 0: first_wrong = base
			print("    snow-cap base %d (%s) cell (%d,%d): atlas=%s want=%s" % [base, BlockCatalog.name_of(base), cell.x, cell.y, str(got), str(want)])
	_ok(caps.size() > 0, "G-ATLAS-COVER(snow-cap): there are cappable materials to check (%d)" % caps.size())
	_ok(missing == 0, "G-ATLAS-COVER(snow-cap): every cappable base has a snow-cap cell (%d missing%s)" % [
		missing, "" if first_missing < 0 else ", first base=%d" % first_missing])
	_ok(wrong == 0, "G-ATLAS-COVER(snow-cap): every snow-cap cell holds snow×tint (%d wrong%s)" % [
		wrong, "" if first_wrong < 0 else ", first base=%d" % first_wrong])

# ---------- G-ATLAS-MAT/-UV (Stage 2): shaped models share the atlas material + their UVs land in the right cell ----
func _gate_shaped(mod: Node3D, atlas) -> void:
	print("  --- G-ATLAS-MAT/-UV(shaped): every atlas-routed shaped model surface is on the ONE material, UVs in-cell ---")
	var probes: Array = mod.call("atlas_shaped_probes")
	_ok(probes.size() > 0, "G-ATLAS(shaped): the manifest recorded atlas-routed shaped models (%d probes)" % probes.size())
	if probes.is_empty():
		return
	var shared: Object = atlas.material
	var bad_mat := 0
	var bad_uv := 0
	var checked_surf := 0
	var first_bad_mat := -1
	var first_bad_uv := -1
	var tol := 1.0 / float(BA.GRID) * 0.001 + 1e-5   # a sub-texel slack on the cell rect containment
	for probe: Dictionary in probes:
		var arid: int = probe["arid"]
		var cells: Array = probe["cells"]
		var model: Object = mod.call("library_model", arid)
		if model == null:
			bad_mat += 1
			if first_bad_mat < 0: first_bad_mat = arid
			continue
		var mesh: Mesh = mod.call("library_model_mesh", arid)
		# A CUBE probe (the snow-cap variant cube at modifier 0) has no mesh — its faces sample the atlas via set_tile,
		# so verify it the Stage-1 way: material_override(0) shared + every face's tile == the cell (UVs bake() emits).
		if mesh == null:
			checked_surf += 1
			if not (model.has_method("get_material_override") and is_same(model.call("get_material_override", 0), shared)):
				bad_mat += 1
				if first_bad_mat < 0: first_bad_mat = arid
			var ccell: Vector2i = cells[0]
			var tile_bad := not model.has_method("get_tile")
			if not tile_bad:
				for side in 6:
					if model.call("get_tile", side) != ccell:
						tile_bad = true
						break
			if tile_bad:
				bad_uv += 1
				if first_bad_uv < 0: first_bad_uv = arid
			continue
		for si in cells.size():
			checked_surf += 1
			# G-ATLAS-MAT: this surface is on the ONE shared atlas material instance (so the mesher merges it).
			if not (model.has_method("get_material_override") and is_same(model.call("get_material_override", si), shared)):
				bad_mat += 1
				if first_bad_mat < 0: first_bad_mat = arid
			# G-ATLAS-UV: every vertex UV of the surface lies inside the surface's expected atlas cell rect.
			var cell: Vector2i = cells[si]
			var rect: Rect2 = atlas.rect_of_cell(cell)
			if si >= mesh.get_surface_count():
				bad_uv += 1
				if first_bad_uv < 0: first_bad_uv = arid
				continue
			var arrays: Array = mesh.surface_get_arrays(si)
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var surf_bad := false
			for uv: Vector2 in uvs:
				if uv.x < rect.position.x - tol or uv.y < rect.position.y - tol \
						or uv.x > rect.end.x + tol or uv.y > rect.end.y + tol:
					surf_bad = true
					break
			if surf_bad:
				bad_uv += 1
				if first_bad_uv < 0: first_bad_uv = arid
	_ok(bad_mat == 0, "G-ATLAS-MAT(shaped): every shaped surface is on the shared atlas material (%d off%s)" % [
		bad_mat, "" if first_bad_mat < 0 else ", first arid=%d" % first_bad_mat])
	_ok(bad_uv == 0, "G-ATLAS-UV(shaped): every shaped surface's UVs lie in its atlas cell over %d surfaces (%d out%s)" % [
		checked_surf, bad_uv, "" if first_bad_uv < 0 else ", first arid=%d" % first_bad_uv])

func _color_close(a: Color, b: Color) -> bool:
	var tol := 3.0 / 255.0
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol and absf(a.a - b.a) <= tol
