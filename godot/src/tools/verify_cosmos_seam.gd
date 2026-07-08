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

## Task #68/#69 CORNER-QUADRANT gate staging. The cube corner wedge folds to face −1 and is resolved at
## the RAW home-face overshoot coords (worker_fold_column terrain_config.gd:707-709), so the same physical
## cell generates DIFFERENT blocks per home face — a §8.2 violation (reproduced: sub-surface strata/ore
## ids flip). #69 replaces that raw fallback with a canonical position-only fold. Until it lands this flag
## is false: the corner gate DOCUMENTS the divergence and asserts it is still present (a canary — passes
## now, and the assertion fails the day someone lands #69 without flipping this, prompting them to). Flip
## to true when #69 lands: the gate then asserts full corner path-independence (identical block column
## across ≥ 2 home-face epochs for the same physical cell).
const CORNER_CANONICAL_FIX := true

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
	_test_corner_quadrant(n)
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Generate the full vertical block-id column exactly as the module worker does (worker_fold_column →
## column_profile → slope_run_of → resolve_cell), over [g−64, g+40]. Returns {g, ids, cf, ci, cj}.
func _gen_full_column(gen_face: int, vx: int, vz: int) -> Dictionary:
	var ctx := TC.GenCtx.new(gen_face)
	var tc: Vector3i = TC.worker_fold_column(gen_face, vx, vz, ctx)   # corner wedge → raw (gen_face, vx, vz)
	var p: Vector4 = TC.column_profile(tc.y, tc.z, ctx)
	var srun := TC.slope_run_of(tc.y, tc.z, ctx)
	var g := int(p.x)
	var ids := {}
	for y in range(g - 64, g + 41):
		ids[y] = TC.resolve_cell(tc.y, y, tc.z, g, int(p.y), p.z, p.w, ctx, srun)
	return {"g": g, "ids": ids, "cf": tc.x, "ci": tc.y, "cj": tc.z}

## (v-corner) FULL-BLOCK corner-quadrant path-independence (task #68/#69). CURVED-ONLY: resolve_cell's
## nested slope/snow/tree stencils fold through column_profile, which short-circuits to flat under
## FLAT_WORLD — so this runs on the curved binary and SKIPs on the flat CI binary (the 24-edge gate above
## stays intact there). For physical directions in each cube corner's wedge it generates the full block
## column TWO ways for the SAME physical cell — homed on face A (the raw overshoot fallback) vs the cell's
## OWN true face (the canonical in-range generation, itself a second home-face epoch) — and compares every
## y. While CORNER_CANONICAL_FIX is false it documents the divergence (canary); when true it asserts zero.
func _test_corner_quadrant(n: int) -> void:
	if CS.FLAT_WORLD:
		print("[corner] SKIP full-block corner gate: needs FLAT_WORLD=false (run on the curved binary).")
		return
	# §8.2 CORNER BAND: sweep every face's 4 corner wedges over a depth band; group the full generated
	# block column by its CANONICAL (face,i,j) key + the home face it was reached from. Any canonical cell
	# reached from ≥ 2 DISTINCT home faces must generate byte-identically (that IS §8.2), and equal the true
	# face's own native in-range generation. Post-#69 this is 0 divergences; pre-#69 the raw fallback made
	# the same physical cell key on (home, raw) → the divergence the canary documented.
	var corners := [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	var by_key := {}                                     # canonical_key -> {home_face -> column}
	for face in range(6):
		for c: Vector2i in corners:
			for depth: int in [1, 2, 3, 4, 6, 8, 12, 18, 26, 40]:
				var vx: int = (n - 1) + depth if c.x > 0 else -depth
				var vz: int = (n - 1) + depth if c.y > 0 else -depth
				if int(CS.fold_cell(face, vx, vz, n)["face"]) >= 0:
					continue                            # not the corner quadrant — skip
				var g := CS.fold_cell_canonical(face, vx, vz, n)
				var k := CS.edit_key(int(g["face"]), int(g["i"]), int(g["j"]), 0)
				if not by_key.has(k):
					by_key[k] = {}
				if not by_key[k].has(face):
					by_key[k][face] = _gen_full_column(face, vx, vz)
	var multi := 0
	var total_cell_div := 0
	var snow_family := 0
	var native_div := 0
	for k in by_key.keys():
		var homes: Dictionary = by_key[k]
		var any: Dictionary = homes.values()[0]
		var native := _gen_full_column(int(any["cf"]), int(any["ci"]), int(any["cj"]))
		for hf in homes.keys():
			var col: Dictionary = homes[hf]
			for y in col["ids"].keys():
				if native["ids"].has(y) and int(col["ids"][y]) != int(native["ids"][y]):
					total_cell_div += 1
					if _is_snow_family(int(col["ids"][y])) or _is_snow_family(int(native["ids"][y])):
						snow_family += 1
					if hf == int(any["cf"]):
						native_div += 1
		if homes.size() >= 2:
			multi += 1
	print("[corner] %d canonical cells (%d reached from ≥2 home faces); %d (cell,y) divergences vs native (%d snow-family)"
		% [by_key.size(), multi, total_cell_div, snow_family])

	# FRINGE (Fable mechanism 2b): an IN-RANGE strip cell near a corner, reached from its true home face
	# vs a NEIGHBOUR home face (via the inverse unfold). worker_fold_column sets ctx.face to the cell's
	# TRUE face in both epochs, so its stencils (which may reach a wedge neighbour) fold identically — this
	# empirically tests whether a strip cell's own block is home-face-independent (expected: yes, the bug is
	# bounded to the wedge; fixing the wedge canonically then also fixes what the fringe reads).
	var fringe_cols := 0
	var fringe_div := 0
	for off: int in [2, 3, 5, 8]:
		var ci: int = (n - 1) - off       # in-range face-4 cell near the +i,+j corner
		var cj: int = (n - 1) - off
		var base := _gen_full_column(4, ci, cj)                  # homed on the true face (4)
		for h: int in range(6):
			if h == 4:
				continue
			var uw: Dictionary = CS.unfold_to_window(h, 4, ci, cj, n)
			if not bool(uw["found"]):
				continue
			var alt := _gen_full_column(h, int(uw["i"]), int(uw["j"]))   # same cell reached from home face h
			fringe_cols += 1
			for y in base["ids"].keys():
				if alt["ids"].has(y) and int(base["ids"][y]) != int(alt["ids"][y]):
					fringe_div += 1
	print("[corner-fringe] %d in-range near-corner cells reached from a neighbour home face; %d (cell,y) divergences" % [fringe_cols, fringe_div])
	_ok(multi > 0 and fringe_cols > 0, "the corner band reached shared canonical cells + fringe cells")
	if CORNER_CANONICAL_FIX:
		_ok(total_cell_div == 0 and fringe_div == 0,
			"corner quadrant + fringe: full block column is home-face-independent (§8.2 canonical fold landed)")
	else:
		# Canary (pre-#69): the divergence must still be present. If this fails, someone landed the fix —
		# flip CORNER_CANONICAL_FIX to true to switch this gate to the real path-independence assertion.
		_ok(total_cell_div > 0,
			"corner quadrant divergence is PRESENT (pending #69 canonical fold — flip CORNER_CANONICAL_FIX when fixed)")

## True iff `id`'s material is snow-family (the time-based snowfall sim, Fable mechanism 3 — distinct from
## the corner-quadrant worldgen bug). Used to classify corner divergences (expected: none are snow).
func _is_snow_family(id: int) -> bool:
	var mat := CellCodec.mat(id)
	return mat == BlockCatalog.id_of(&"snow") or mat == BlockCatalog.id_of(&"snow_block") \
		or mat == BlockCatalog.id_of(&"powder_snow")
