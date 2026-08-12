extends SceneTree
## COSMOS NEAR-LEAF-CUTOUT gate (docs/COSMOS-NEAR-LEAF-CUTOUT-DESIGN.md §8, task #116) — the see-through (alpha-tested)
## NEAR leaf blocks. Proves, on the ACTUAL built module library (not by eye), that the 7 leaf ids (BlockCatalog.is_leaf_id)
## split off the shared opaque atlas material onto a transparent-cutout twin, that the leaf atlas cells carry the stipple
## hole-punch, and that flag-off is byte-identical.
##
## Runs in TWO modes, selected by the sed state of CubeSphere.FP_LEAF_CUTOUT (FP_ATLAS_MATERIAL must be on in BOTH to
## build the atlas at all):
##   OFF  → G-LEAF-OFF: the atlas leaf cells hold NO transparency (hole-punch never ran ⇒ atlas image byte-identical),
##          no leaf twin exists, every leaf id is on the ONE shared atlas material. (Run with only FP_ATLAS_MATERIAL on.)
##   ON   → G-LEAF-CELL / G-LEAF-MAT / G-LEAF-SHADE. The live bake fingerprint (FP_ATLAS_MATERIAL + FP_NEAR_DAYLIGHT +
##          FP_SHADE_UNIFIED + FP_LEAF_CUTOUT) must ALL be sed-on — pinned via LIVE_* below so a forgotten sed fails
##          LOUDLY rather than vacuously (a repo-default-false CubeSphere.FP_* would void the pin).
##
## RUN (OFF):
##   sed -i 's/const FP_ATLAS_MATERIAL := false/const FP_ATLAS_MATERIAL := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_leaf_cutout.gd
##   # then REVERT the sed.
## RUN (ON): additionally sed FP_NEAR_DAYLIGHT, FP_SHADE_UNIFIED, FP_LEAF_CUTOUT := true, run, then REVERT all.
## Exits 0 all-pass / 1 on any failure. FLAT world (FACETED stays false — the module library build is facet-independent).

const BA := preload("res://src/world/voxel_module/block_atlas.gd")

# The live bake fingerprint this gate's ON mode pins against (design gate-gotcha: baseline pins read gate-local LIVE_*
# consts, NOT CubeSphere.FP_* — the repo default is false, which would make a forgotten sed pass vacuously).
const LIVE_ATLAS := true
const LIVE_NEAR_DAYLIGHT := true
const LIVE_SHADE_UNIFIED := true
const LIVE_LEAF := true

# The 7 leaf ids (LEAF 5 + *_leaves), the byte-off/on contract set. Cross-checked against BlockCatalog.is_leaf_id.
const LEAF_IDS := [5, 51, 53, 55, 57, 59, 61]

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_leaf_cutout (COSMOS NEAR-LEAF-CUTOUT: see-through near leaf blocks) ===")
	if not CubeSphere.FP_ATLAS_MATERIAL:
		print("  FAIL: CubeSphere.FP_ATLAS_MATERIAL is false — sed-toggle it true to build the atlas for this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent (ClassDB has no VoxelTerrain) — this gate needs the module binary.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return

	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()

	# is_leaf_id predicate cross-check (independent of the flag): exactly the 7-id family, and NOT moss_block/cactus.
	_gate_predicate()

	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	var ok_setup: bool = bool(mod.call("setup"))
	_ok(ok_setup, "setup: module_world built the terrain + baked library (atlas routed)")
	if not ok_setup:
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail]); _teardown(mod); return
	var atlas = mod.call("atlas")
	_ok(atlas != null and atlas.image != null, "setup: the module built a BlockAtlas with an image")
	if atlas == null:
		_teardown(mod); return

	if CubeSphere.FP_LEAF_CUTOUT:
		# ON mode: pin the live fingerprint, then discriminate the feature.
		_ok(CubeSphere.FP_ATLAS_MATERIAL == LIVE_ATLAS and CubeSphere.FP_NEAR_DAYLIGHT == LIVE_NEAR_DAYLIGHT
			and CubeSphere.FP_SHADE_UNIFIED == LIVE_SHADE_UNIFIED and CubeSphere.FP_LEAF_CUTOUT == LIVE_LEAF,
			"fingerprint: live bake flags all sed-on (ATLAS/NEAR_DAYLIGHT/SHADE_UNIFIED/LEAF_CUTOUT) — else the ON pins are vacuous")
		_gate_cell(mod, atlas)
		_gate_mat(mod, atlas)
		_gate_shade(mod, atlas)
	else:
		_gate_off(mod, atlas)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	_teardown(mod)

func _teardown(mod: Node3D) -> void:
	if is_instance_valid(mod):
		if mod.get_parent() != null:
			mod.get_parent().remove_child(mod)
		mod.free()
	quit(1 if _fail > 0 else 0)

# ---------- predicate: is_leaf_id is exactly the 7-id family (NOT foliage moss_block/cactus) ----------
func _gate_predicate() -> void:
	print("  --- predicate: BlockCatalog.is_leaf_id == the 7 leaf ids, and foliage moss_block/cactus stay solid ---")
	var found := []
	for id in range(1, BlockCatalog.count()):
		if BlockCatalog.is_leaf_id(id):
			found.append(id)
	found.sort()
	_ok(found == LEAF_IDS, "predicate: is_leaf_id == %s (got %s)" % [str(LEAF_IDS), str(found)])
	# moss_block (43) + cactus (77) are structural_class foliage but must NOT be leaves.
	_ok(not BlockCatalog.is_leaf_id(43) and not BlockCatalog.is_leaf_id(77),
		"predicate: foliage moss_block(43)/cactus(77) are NOT leaves (class-foliage != leaf)")

# ---------- G-LEAF-OFF (byte-identity): no hole-punch, no twin, leaves on the ONE shared atlas material ----------
func _gate_off(mod: Node3D, atlas) -> void:
	print("  --- G-LEAF-OFF: flag off ⇒ atlas leaf cells un-punched (byte-identical) + leaves on the shared material ---")
	_ok(atlas.leaf_material == null, "G-LEAF-OFF: no leaf twin material was built (flag off)")
	var shared: Object = atlas.material
	var min_alpha := 255
	var on_shared := 0
	var checked := 0
	for id in LEAF_IDS:
		if not atlas.has_cell(id):
			continue
		checked += 1
		min_alpha = mini(min_alpha, _cell_min_alpha(atlas, atlas.cell_of(id)))
		var model: Object = mod.call("library_model", mod.call("cube_arid_of", id))
		if model != null and model.has_method("get_material_override") and is_same(model.call("get_material_override", 0), shared):
			on_shared += 1
	_ok(checked == LEAF_IDS.size(), "G-LEAF-OFF: all %d leaf ids have an atlas cell (%d checked)" % [LEAF_IDS.size(), checked])
	_ok(min_alpha == 255, "G-LEAF-OFF: every leaf cell is fully opaque (min-alpha 255 ⇒ hole-punch never ran) — got %d" % min_alpha)
	_ok(on_shared == checked, "G-LEAF-OFF: every leaf model is on the ONE shared atlas material (%d/%d)" % [on_shared, checked])

# ---------- G-LEAF-CELL (ON discriminates): leaf cells 22-40% transparent, non-leaf min-alpha 255, no cell sharing ----------
func _gate_cell(mod: Node3D, atlas) -> void:
	print("  --- G-LEAF-CELL: leaf cells stipple-punched to 22-40%% transparent; non-leaf cells min-alpha 255; no sharing ---")
	var leaf_cells := {}
	var bad_frac := 0
	var first_bad := -1
	for id in LEAF_IDS:
		_ok(atlas.has_cell(id), "G-LEAF-CELL: leaf id %d (%s) has an atlas cell" % [id, BlockCatalog.name_of(id)])
		var cell: Vector2i = atlas.cell_of(id)
		leaf_cells[cell] = true
		var frac := _cell_transparent_fraction(atlas, cell)
		if frac < 0.22 or frac > 0.40:
			bad_frac += 1
			if first_bad < 0: first_bad = id
			print("    id %d (%s) cell (%d,%d): transparent fraction %.3f out of [0.22,0.40]" % [id, BlockCatalog.name_of(id), cell.x, cell.y, frac])
	_ok(bad_frac == 0, "G-LEAF-CELL: every leaf cell is 22-40%% transparent (%d out of range%s)" % [
		bad_frac, "" if first_bad < 0 else ", first id=%d" % first_bad])
	# Non-leaf opaque cells stay fully opaque, and never share a cell with a leaf id.
	var non_leaf_opaque := 0
	var non_leaf_transparent := 0
	var shared_cell := 0
	var first_share := -1
	for id in range(1, BlockCatalog.count()):
		if not BA.is_opaque_cube(id) or BlockCatalog.is_leaf_id(id) or not atlas.has_cell(id):
			continue
		non_leaf_opaque += 1
		var cell: Vector2i = atlas.cell_of(id)
		if leaf_cells.has(cell):
			shared_cell += 1
			if first_share < 0: first_share = id
		if _cell_min_alpha(atlas, cell) < 255:
			non_leaf_transparent += 1
	_ok(non_leaf_transparent == 0, "G-LEAF-CELL: every non-leaf opaque cell stays min-alpha 255 (%d punched)" % non_leaf_transparent)
	_ok(shared_cell == 0 and non_leaf_opaque > 0,
		"G-LEAF-CELL: no non-leaf opaque id shares a leaf cell (%d checked, %d shared%s)" % [
			non_leaf_opaque, shared_cell, "" if first_share < 0 else ", first id=%d" % first_share])

# ---------- G-LEAF-MAT: the 7 leaf ids on ONE twin instance; shader == atlas shader + EXACTLY the discard; tx-index 0 ----------
func _gate_mat(mod: Node3D, atlas) -> void:
	print("  --- G-LEAF-MAT: leaf ids on ONE cutout twin; shader == near-daylight source + exactly one discard; tx-index 0 ---")
	var twin: Object = atlas.leaf_material
	_ok(twin != null, "G-LEAF-MAT: the leaf twin material exists under the flag")
	if twin == null:
		return
	var shared: Object = atlas.material
	_ok(not is_same(twin, shared), "G-LEAF-MAT: the leaf twin is a DISTINCT instance from the shared atlas material")
	# All 7 leaf ids point at the SAME twin instance; every non-leaf opaque id stays on the shared atlas material.
	var on_twin := 0
	var same_instance := true
	for id in LEAF_IDS:
		var model: Object = mod.call("library_model", mod.call("cube_arid_of", id))
		if model == null or not model.has_method("get_material_override"):
			continue
		if is_same(model.call("get_material_override", 0), twin):
			on_twin += 1
		# transparency_index stays 0 (the overdraw cap is load-bearing): the source is cull_group 0, and if the model
		# exposes the getter, it must read 0 too.
		_ok(BlockCatalog.cull_group_of(id) == 0, "G-LEAF-MAT: leaf id %d cull_group is 0 (transparency_index source)" % id)
		if model.has_method("get_transparency_index"):
			_ok(int(model.call("get_transparency_index")) == 0, "G-LEAF-MAT: leaf id %d model transparency_index is 0" % id)
	_ok(on_twin == LEAF_IDS.size(), "G-LEAF-MAT: all %d leaf ids are on the ONE cutout twin (%d)" % [LEAF_IDS.size(), on_twin])
	# String-diff: the twin's shader source is EXACTLY near_daylight_shader_code() + one `if (t.a < LEAF_SCISSOR) discard;`.
	if twin is ShaderMaterial:
		var got_code: String = ((twin as ShaderMaterial).shader as Shader).code
		var base := BA.near_daylight_shader_code()
		var expected := BA.leaf_shader_code()
		var discard_line := "\tif (t.a < %s) discard;\n" % String.num(CubeSphere.LEAF_SCISSOR, 3)
		_ok(got_code == expected, "G-LEAF-MAT: twin shader source == BlockAtlas.leaf_shader_code()")
		_ok(expected != base and expected.count(discard_line) == 1 and expected.replace(discard_line, "") == base,
			"G-LEAF-MAT: twin shader == atlas near-daylight shader + EXACTLY one discard line (string-diff)")
	else:
		# Shader-off path: the StandardMaterial cutout clone (alpha-scissor in the opaque queue).
		var sm := twin as StandardMaterial3D
		_ok(sm != null and sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			and is_equal_approx(sm.alpha_scissor_threshold, CubeSphere.LEAF_SCISSOR),
			"G-LEAF-MAT: shader-off twin is a StandardMaterial ALPHA_SCISSOR clone at LEAF_SCISSOR")

# ---------- G-LEAF-SHADE: the twin shades through voxi_shade + the sun_dir/planet_centre feed reaches it ----------
func _gate_shade(mod: Node3D, atlas) -> void:
	print("  --- G-LEAF-SHADE: the twin carries voxi_shade + the sun_dir/planet_centre uniform feed reaches it ---")
	var twin: Object = atlas.leaf_material
	if not (twin is ShaderMaterial):
		_ok(false, "G-LEAF-SHADE: twin is not a ShaderMaterial (needs FP_NEAR_DAYLIGHT for the shaded path)")
		return
	var sm := twin as ShaderMaterial
	_ok(((sm.shader as Shader).code).contains("voxi_shade"),
		"G-LEAF-SHADE: the twin shader contains voxi_shade (FP_SHADE_UNIFIED terminator composition)")
	# Push a distinctive Sun + planet centre through the SAME module→atlas feed the live frame uses; read it back off the twin.
	var sun := Vector3(0.0, 1.0, 0.0)
	var centre := Vector3(12.0, -34.0, 56.0)
	mod.call("set_near_daylight_sun_dir", sun)
	mod.call("set_near_daylight_planet_centre", centre)
	_ok(_vec_close(sm.get_shader_parameter("sun_dir"), sun),
		"G-LEAF-SHADE: set_near_daylight_sun_dir reaches the twin's sun_dir uniform")
	_ok(_vec_close(sm.get_shader_parameter("planet_centre"), centre),
		"G-LEAF-SHADE: set_near_daylight_planet_centre reaches the twin's planet_centre uniform")

# ---------- helpers ----------
func _cell_min_alpha(atlas, cell: Vector2i) -> int:
	var ox := cell.x * BA.CELL_PX
	var oy := cell.y * BA.CELL_PX
	var m := 255
	for y in BA.CELL_PX:
		for x in BA.CELL_PX:
			m = mini(m, int(round(atlas.image.get_pixel(ox + x, oy + y).a * 255.0)))
	return m

func _cell_transparent_fraction(atlas, cell: Vector2i) -> float:
	var ox := cell.x * BA.CELL_PX
	var oy := cell.y * BA.CELL_PX
	var transparent := 0
	for y in BA.CELL_PX:
		for x in BA.CELL_PX:
			if atlas.image.get_pixel(ox + x, oy + y).a < 0.5:
				transparent += 1
	return float(transparent) / float(BA.CELL_PX * BA.CELL_PX)

func _vec_close(v: Variant, want: Vector3) -> bool:
	return v is Vector3 and (v as Vector3).distance_to(want) < 1e-4
