extends SceneTree
## Far-LOD wedge-BRIDGING cull gate (window-space, reliable). At coarse far rings a tile straddling a cube
## corner has triangles whose 3 vertices are all valid (home/strips) but whose BODY spans the double-out
## wedge — the per-vertex cull keeps them, painting a stretched sheet across the corner at distance. This
## gate builds a COARSE (cell=32) corner tile, confirms it genuinely CONTAINS such bridging triangles, then
## bakes it via FarMeshBuilder.bake_arrays and asserts NONE survive (the centroid/edge-midpoint cull), while
## valid terrain still survives. Curved-only.

const TP := preload("res://src/cosmos/cosmos_true_place.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const FMB := preload("res://src/world/far/far_mesh_builder.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _init() -> void:
	print("=== verify_far_wedge (far bridging cull) FLAT_WORLD=", CubeSphere.FLAT_WORLD, " ===")
	if CubeSphere.FLAT_WORLD:
		print("  SKIPPED — curved-only. NOT A PASS."); print("==== VERIFY: SKIPPED ===="); quit(2); return

	var chart: CHART = CHART.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)   # M_win=I, org=0 → window==raw
	var frame := TP.bake_frame(chart, Vector3(8.5, 4.0, 8.5))

	# a COARSE tile spanning the corner (0,0): window [-64,64]^2, cell 32 (grid 4).
	var grid := 4
	var cell := 32.0
	var org := Vector2(-64.0, -64.0)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var stride := grid + 1
	for j in range(stride):
		for i in range(stride):
			verts.append(Vector3(org.x + float(i) * cell, 0.0, org.y + float(j) * cell))
			norms.append(Vector3.UP)
			cols.append(Color.WHITE)
	var idx := PackedInt32Array()
	for j in range(grid):
		for i in range(grid):
			var a := j * stride + i
			idx.append_array([a, a + 1, a + stride, a + 1, a + 1 + stride, a + stride])

	# classify SOURCE triangles: wedge-vertex (per-vertex culls) vs BRIDGING (no wedge vertex, wedge centroid).
	var src_bridging := 0
	var src_valid := 0
	for ti in range(0, idx.size(), 3):
		var wa := Vector2(verts[idx[ti]].x, verts[idx[ti]].z)
		var wb := Vector2(verts[idx[ti + 1]].x, verts[idx[ti + 1]].z)
		var wc := Vector2(verts[idx[ti + 2]].x, verts[idx[ti + 2]].z)
		var vw := TP.is_wedge(chart, wa.x, wa.y) or TP.is_wedge(chart, wb.x, wb.y) or TP.is_wedge(chart, wc.x, wc.y)
		var cen := (wa + wb + wc) / 3.0
		if not vw and TP.is_wedge(chart, cen.x, cen.y):
			src_bridging += 1
		elif not vw:
			src_valid += 1
	_ok(src_bridging > 0, "far tile genuinely has %d BRIDGING triangles (per-vertex cull would keep them)" % src_bridging)

	# bake with the fix and check no surviving triangle bridges the wedge.
	var arrays := {"verts": verts, "normals": norms, "colors": cols, "indices": idx,
		"origin": org, "grid": grid, "cell": cell}
	var baked: Dictionary = FMB.bake_arrays(arrays, chart, frame, Vector3.ZERO, {})
	var out_idx: PackedInt32Array = baked["indices"]
	var survive_bridge := 0
	var survivors := out_idx.size() / 3
	for ti in range(0, out_idx.size(), 3):
		var wa := Vector2(verts[out_idx[ti]].x, verts[out_idx[ti]].z)
		var wb := Vector2(verts[out_idx[ti + 1]].x, verts[out_idx[ti + 1]].z)
		var wc := Vector2(verts[out_idx[ti + 2]].x, verts[out_idx[ti + 2]].z)
		var cen := (wa + wb + wc) / 3.0
		if TP.is_wedge(chart, cen.x, cen.y):
			survive_bridge += 1
	print("  source: bridging=%d valid=%d ; baked survivors=%d bridging-survivors=%d" % [src_bridging, src_valid, survivors, survive_bridge])
	_ok(survive_bridge == 0, "NO surviving far triangle bridges the wedge (fix works)")
	_ok(survivors >= src_valid, "all fully-valid far terrain survives (no over-cull; %d >= %d)" % [survivors, src_valid])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
