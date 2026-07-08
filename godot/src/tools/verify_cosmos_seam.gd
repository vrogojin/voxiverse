extends SceneTree
## COSMOS seam-continuity gate (task #68). Pins the §8.2 fold invariant across ALL 24 cube-face edges
## (m3 gate (b) only covered the EAST edge of face 4). Run:
##   godot --headless --path godot --script res://src/tools/verify_cosmos_seam.gd
## Exits 0 all-pass, 1 on any failure. Runs on the FLAT binary by calling the curved statics directly
## (the M2/M3 discipline): _curved_profile / fold_cell / face_cell_to_dir bypass the FLAT_WORLD short-circuit.
##
## For every (face, side) it takes the cell just INSIDE the edge and the cell just OUTSIDE (one past),
## folds the outside cell via CubeSphere.fold_cell (the D4 rigid unfold worldgen samples through dir_of),
## and asserts:
##   (1) ADJACENCY — the folded-outside cell's direction is ~1 cell from the inside cell's direction (the
##       mirror across the shared edge lands on the geometric 1:1 neighbour; a broken edge_remap would land
##       far away → a real worldgen discontinuity).
##   (2) HEIGHT CONTINUITY — the curved-profile solid height agrees across the seam (≤ a few blocks; no cliff).
##   (3) §8.2 PATH-INDEPENDENCE — the home-face EXTENDED-window profile of the outside column (folded
##       internally by dir_of) is byte-identical to the neighbour face's OWN in-face profile of the folded
##       cell. This is the exact "in-face == folded" determinism the seam-misalignment investigation checked:
##       a true global cell generates identically whether reached in-face or by folding from another face.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const TC := preload("res://src/world/terrain_config.gd")

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _initialize() -> void:
	print("COSMOS seam-continuity — all 24 cube-face edges (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	BlockCatalog.ensure_ready()
	TC.warm_up()
	var n := CS.n_for(CS.HOME_BODY)
	CS.warm_edge_tables(n)
	var cell_ang := (PI / 2.0) / float(n)
	var side_name := ["EAST", "WEST", "NORTH", "SOUTH"]

	var worst_cells := 0.0
	var worst_desc := ""
	for face in range(6):
		for s in range(4):
			var adj_ok := true
			var cont_ok := true
			var det_ok := true
			for frac in [0.2, 0.4, 0.5, 0.6, 0.8]:
				var t := int(float(n) * frac)
				var ins: Vector2i
				var outs: Vector2i
				match s:
					0: ins = Vector2i(n - 1, t); outs = Vector2i(n, t)     # EAST  (i past n)
					1: ins = Vector2i(0, t);     outs = Vector2i(-1, t)    # WEST  (i < 0)
					2: ins = Vector2i(t, n - 1); outs = Vector2i(t, n)     # NORTH (j past n)
					_: ins = Vector2i(t, 0);     outs = Vector2i(t, -1)    # SOUTH (j < 0)
				var g: Dictionary = CS.fold_cell(face, outs.x, outs.y, n)
				var gf := int(g["face"])
				if gf < 0:
					continue                                           # corner quadrant (M5 stub) — not a single-edge fold
				var gi := int(g["i"])
				var gj := int(g["j"])
				# (1) adjacency: folded-outside direction ~1 cell from the inside cell's direction.
				var d_in: CS.DVec3 = CS.face_cell_to_dir(face, float(ins.x), float(ins.y), n)
				var d_out: CS.DVec3 = CS.face_cell_to_dir(gf, float(gi), float(gj), n)
				var dot := d_in.x * d_out.x + d_in.y * d_out.y + d_in.z * d_out.z
				var ang := acos(clampf(dot, -1.0, 1.0))
				var cells := ang / cell_ang
				if cells > worst_cells:
					worst_cells = cells
					worst_desc = "face %d %s @%d -> (%d,%d,%d)" % [face, side_name[s], t, gf, gi, gj]
				if cells > 2.5:
					adj_ok = false
				# (2) height continuity across the seam.
				var ext: Vector4 = TC._curved_profile(face, outs.x, outs.y)   # home-face extended (folds via dir_of)
				var nat: Vector4 = TC._curved_profile(gf, gi, gj)             # neighbour's own in-face profile
				var h_in := int(TC._curved_profile(face, ins.x, ins.y).x)
				if absi(h_in - int(ext.x)) > 4:
					cont_ok = false
				# (3) §8.2 path-independence: extended-window profile == neighbour in-face profile, byte-identical.
				if ext != nat:
					det_ok = false
			_ok(adj_ok, "face %d %s: folded cell is the geometric 1:1 neighbour (~1 cell across the edge)" % [face, side_name[s]])
			_ok(cont_ok, "face %d %s: surface height is continuous across the edge (no cliff)" % [face, side_name[s]])
			_ok(det_ok, "face %d %s: §8.2 — extended-window profile == neighbour in-face profile (in-face == folded)" % [face, side_name[s]])
	print("  worst adjacency across all 24 edges: %.2f cells (%s)" % [worst_cells, worst_desc])
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
