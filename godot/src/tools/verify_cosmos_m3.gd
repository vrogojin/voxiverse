extends SceneTree
## COSMOS M3 — headless property tests for seam crossing (fallback-grade) + curved-render
## integration (docs/COSMOS-PLANET-TOPOLOGY.md §9 M3, §4.2/§4.3/§4.4/§4.5). Run:
##   godot --headless --path godot --script res://src/tools/verify_cosmos_m3.gd
## Exits 0 all-pass, 1 on any failure. Like M2 it exercises the CURVED-mode invariants WITHOUT
## flipping CubeSphere.FLAT_WORLD (a const): a CosmosChart is injected into a WorldManager and the
## curved worldgen functions are called directly, so the extended-window fold + home-face flip are
## proven while the live FLAT_WORLD path stays byte-identical.
##
## Gates (§9 M3 + the task VERIFY list):
##   (a) cross-window EDIT IDENTITY — an edit written in a window straddling a face edge is
##       retrieved by its global (NEIGHBOUR-face) key from a window homed on the OTHER side.
##   (b) SEAM CONTINUITY — curved worldgen height/material is continuous across a face edge (the
##       extended-window read equals the neighbour face's own generation; the 1:1 neighbour is one
##       cell away; a run of cells spanning the edge maps 1:1 to distinct global cells).
##   (c) the D4 fold matches M0's remap tables (window→global→window round-trip; the doc's worked
##       face-4↔face-0 example).
##   (d) HOME-FACE FLIP preserves edits + the player's world position (no teleport) and worldgen
##       determinism (same global cell identical before/after the flip).
##   (e) CURVED-RENDER INTEGRATION — GroundCollider / PerVoxelEnvironment.temperature / fallback-
##       mesher reads resolve to the correct GLOBAL cell at a non-zero origin (window-independent).

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TC := preload("res://src/world/terrain_config.gd")
const PVE := preload("res://src/sim/per_voxel_environment.gd")

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
	print("COSMOS M3 — seam crossing + curved-render verification (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	BlockCatalog.ensure_ready()
	TC.warm_up()
	_test_cross_edge_edit_identity()   # (a)
	_test_seam_continuity()            # (b)
	_test_d4_fold_matches_m0()         # (c)
	_test_home_face_flip()             # (d)
	_test_curved_render_integration()  # (e)
	_test_edge_table_race_safety()     # (f) crash-fix regression
	# Leave the shared active face back on HOME_FACE so a subsequent run in the same process is clean.
	TC.set_active_face(CS.HOME_FACE)
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _bare_world() -> WorldManager:
	return WorldManager.new()

func _wp_equal(a: CubeSphere.DVec3, b: CubeSphere.DVec3) -> bool:
	return absf(a.x - b.x) == 0.0 and absf(a.y - b.y) == 0.0 and absf(a.z - b.z) == 0.0

# ---------------------------------------------------------------------------------------
# (a) Cross-window edit identity across a face edge.
# ---------------------------------------------------------------------------------------
func _test_cross_edge_edit_identity() -> void:
	print("[a] cross-window EDIT IDENTITY — an edit made across a face edge is found from a window on the other side")
	var n := CS.n_for(CS.HOME_BODY)
	var w := _bare_world()
	# A window on face 4 whose EAST strip spills past i = N: origin near the edge, mid-j (away from corners).
	var chart_a := CHART.new(CS.HOME_BODY, 4, n - 3, 4000)
	w.install_chart(chart_a)
	var wc_a := Vector3i(5, 6, 200)                     # global i = (n-3)+5 = n+2 → past EAST by 3
	var g: Dictionary = chart_a.to_global(wc_a)
	_ok(int(g["face"]) != 4, "the straddling window cell folds onto a NEIGHBOUR face (%d)" % int(g["face"]))
	_ok(int(g["i"]) >= 0 and int(g["i"]) < n and int(g["j"]) >= 0 and int(g["j"]) < n,
		"the folded cell is in-range on the neighbour face (i=%d, j=%d)" % [int(g["i"]), int(g["j"])])

	# Grass + the snow_capped STATE bit: a VALID state that survives the merged CellCodec.canonical write
	# choke point, so this proves the full value (material + state axis) crosses the face seam intact.
	var packed := CellCodec.canonical(CellCodec.pack(BlockCatalog.id_of(&"grass"), 0, CellCodec.STATE_SNOW_CAPPED))
	w._write_cell(wc_a, packed)
	var key := chart_a.to_global_key(wc_a)
	_ok(key == CS.edit_key(int(g["face"]), int(g["i"]), int(g["j"]), 6),
		"the edit key is the NEIGHBOUR-face global key (not the home-face raw key)")
	_ok(w._edits.has(key) and w._edits.size() == 1, "the overlay stores exactly one edit, under the folded key")

	# Re-home the SAME world on the neighbour face so a window there reaches the same global cell.
	var chart_b := CHART.new(CS.HOME_BODY, int(g["face"]), int(g["i"]), int(g["j"]))
	w.install_chart(chart_b)
	var wc_b := Vector3i(0, 6, 0)                       # window (0,·,0) → global (B, gi, gj) exactly
	_ok(chart_b.to_global_key(wc_b) == key, "a window homed on the OTHER side folds to the SAME global key")
	_ok(w.cell_value_at(wc_b) == packed, "the cross-edge edit is FOUND AGAIN from the other-side window (full value intact)")
	_ok(CellCodec.state(w.cell_value_at(wc_b)) == CellCodec.STATE_SNOW_CAPPED, "the state axis survived the cross-edge read")
	w.free()

# ---------------------------------------------------------------------------------------
# (b) Seam continuity — curved worldgen is continuous across a face edge.
# ---------------------------------------------------------------------------------------
func _test_seam_continuity() -> void:
	print("[b] SEAM CONTINUITY — curved worldgen height/material continuous across a face edge (no cliff/gap)")
	var n := CS.n_for(CS.HOME_BODY)
	var byte_ok := true
	var cont_ok := true
	var adj_ok := true
	var cell_ang := (PI / 2.0) / float(n)               # ~angular size of one cell along an axis
	for j in [1000, 3000, 5008, 8000]:
		# The across-EAST-edge neighbour of the boundary column (4, N-1, j).
		var gg: Dictionary = CS.fold_cell(4, n, j, n)
		if int(gg["face"]) == 4:
			byte_ok = false
		# The extended-window generation of (4, N, j) MUST equal the neighbour face's OWN generation of
		# its (face', i', j') — that IS "no cliff/gap": both sides read one identical value at the seam.
		var ext: Vector4 = TC._curved_profile(4, n, j)
		var nat: Vector4 = TC._curved_profile(int(gg["face"]), int(gg["i"]), int(gg["j"]))
		if ext != nat:
			byte_ok = false
		# Surface height is continuous across the boundary (gentle terrain: a small per-cell gradient).
		var h_in := int(TC._curved_profile(4, n - 1, j).x)
		var h_out := int(ext.x)
		if absi(h_in - h_out) > 4:
			cont_ok = false
		# The 1:1 neighbour is ~one cell away geometrically (no T-junction, no gap — §4.1).
		var d_in := CS.face_cell_to_dir(4, n - 1, j, n)
		var d_out := LatticeNav.dir_of(4, n, j, n)
		if d_in.angle_to(d_out) > 5.0 * cell_ang:
			adj_ok = false
	_ok(byte_ok, "the extended-window worldgen == the neighbour face's OWN generation at the seam (byte-identical)")
	_ok(cont_ok, "surface height is continuous across the edge (≤ a few blocks per cell; no cliff)")
	_ok(adj_ok, "the across-edge 1:1 neighbour is ~1 cell away (no T-junction / gap)")

	# A run of cells spanning the edge maps 1:1 to DISTINCT global cells — a wall/tunnel/water cell
	# straddling the seam has no missing or duplicated cell (§4.3).
	var seen := {}
	var span_ok := true
	var mid_j := n / 2
	for x in range(-3, 9):                              # crosses i = N at x = 3 (origin n-3)
		var gc: Dictionary = CS.fold_cell(4, (n - 3) + x, mid_j, n)
		if int(gc["face"]) < 0:
			span_ok = false
			continue
		var kk := CS.edit_key(int(gc["face"]), int(gc["i"]), int(gc["j"]), 0)
		if seen.has(kk):
			span_ok = false
		seen[kk] = true
	_ok(span_ok, "a run of cells spanning the edge maps 1:1 to distinct global cells (no missing/duplicate cell)")

# ---------------------------------------------------------------------------------------
# (c) The D4 fold matches M0's remap tables.
# ---------------------------------------------------------------------------------------
func _test_d4_fold_matches_m0() -> void:
	print("[c] the D4 fold matches M0's remap tables (window→global→window round-trip; the worked example)")
	var n := CS.n_for(CS.HOME_BODY)
	# The doc's worked example (§4.2): face-4 cells exiting the j=0 (SOUTH, v̂₄=−X) side land on face 0.
	_ok(int(CS.edge_remap(4, CS.SIDE_SOUTH, n)["b"]) == 0, "face-4 SOUTH edge folds to face 0 (the doc's worked example)")
	# Every one of the 4 direct edges of face 4 is a valid D4 map (det ±1) landing on a distinct face.
	var faces_seen := {}
	var det_ok := true
	for side in range(4):
		var e: Dictionary = CS.edge_remap(4, side, n)
		var m: Array = e["m"]
		var det: int = int(m[0]) * int(m[3]) - int(m[1]) * int(m[2])
		if absi(det) != 1:
			det_ok = false
		faces_seen[int(e["b"])] = true
	_ok(det_ok, "every face-4 edge remap is a D4 element (|det| = 1)")
	_ok(faces_seen.size() == 4 and not faces_seen.has(4), "the 4 edges of face 4 reach 4 distinct OTHER faces")

	# window → global → window round-trips exactly across the edge (the D4 inverse is exact).
	var chart := CHART.new(CS.HOME_BODY, 4, n - 4, 3000)
	var rt_ok := true
	for x in [-2, 0, 3, 5, 7]:                          # some in-range, some past EAST
		var wc := Vector3i(x, 0, 200)
		var gcol: Dictionary = chart.to_global_column(wc.x, wc.z)
		var back: Dictionary = chart.window_of_global(int(gcol["face"]), int(gcol["i"]), int(gcol["j"]))
		if not bool(back["found"]) or int(back["x"]) != wc.x or int(back["z"]) != wc.z:
			rt_ok = false
	_ok(rt_ok, "window→global→window round-trips across the edge (unfold_to_window inverts fold exactly)")

# ---------------------------------------------------------------------------------------
# (d) Home-face flip — preserves edits + player world position + worldgen determinism.
# ---------------------------------------------------------------------------------------
func _test_home_face_flip() -> void:
	print("[d] HOME-FACE FLIP — preserves edits + player world position (no teleport) + worldgen determinism")
	var n := CS.n_for(CS.HOME_BODY)
	var w := _bare_world()
	var chart := CHART.new(CS.HOME_BODY, 4, n - 10, 3000)
	w.install_chart(chart)

	# An edit on the home face near the seam (in-range on face 4).
	var wc_edit := Vector3i(2, 6, 10)                   # global i = n-8, j = 3010
	# Grass + snow_capped: a VALID state that survives CellCodec.canonical, so the full value (material +
	# state axis) is proven to survive the home-face flip via its unchanged global key.
	var packed := CellCodec.canonical(CellCodec.pack(BlockCatalog.id_of(&"grass"), 0, CellCodec.STATE_SNOW_CAPPED))
	w._write_cell(wc_edit, packed)
	var key := chart.to_global_key(wc_edit)

	# A fixed GLOBAL cell reached via a window straddling the EAST edge — its generated value must be
	# identical before and after the flip (worldgen determinism, §8.2).
	var wc_probe := Vector3i(80, 4, 20)                 # global i = n+70 (past EAST by 70)
	var g_probe: Dictionary = chart.to_global(wc_probe)
	var gen_before := w.cell_value_at(wc_probe)

	# The player, 80 cells into the window at the edge → ≥ FLIP_HYST (64) past it → flip.
	var player := Vector3(80.0, 6.0, 20.0)
	var pcell := Vector3i(80, 6, 20)
	var wp_before := chart.world_point_of(pcell)
	_ok(chart.flip_needed(player), "the flip triggers ≥ FLIP_HYST cells past the edge")
	var flipped := w.maybe_flip_home_face(player)
	_ok(flipped, "the home-face flip executed")
	_ok(chart.face == int(g_probe["face"]), "the home face is now the neighbour face (%d)" % chart.face)

	# No teleport: the player's window cell maps to the same physical cell → same world point (bit-exact).
	var wp_after := chart.world_point_of(pcell)
	_ok(_wp_equal(wp_before, wp_after), "the player's world point is BIT-IDENTICAL across the flip (no teleport)")

	# Edits preserved: the global key is untouched, and the edit is found again via its new window cell.
	_ok(w._edits.has(key) and w._edits.size() == 1, "the edit's global key is unchanged by the flip")
	var ge := CS.unpack_key(key)
	var wback: Dictionary = chart.window_of_global(int(ge["face"]), int(ge["i"]), int(ge["j"]))
	_ok(bool(wback["found"]) and w.cell_value_at(Vector3i(int(wback["x"]), int(ge["r"]), int(wback["z"]))) == packed,
		"the edit is FOUND AGAIN after the flip (full value intact)")
	# The window-keyed collider index is rebuilt from the overlay onto the new face (fallback fully).
	_ok(bool(wback["found"]) and w.is_edited_column(int(wback["x"]), int(wback["z"])),
		"the collider's window edit-column index is rebuilt onto the new face after the flip")

	# Worldgen determinism: the same global cell generates identically before/after the flip.
	var wprobe2: Dictionary = chart.window_of_global(int(g_probe["face"]), int(g_probe["i"]), int(g_probe["j"]))
	_ok(bool(wprobe2["found"]) and w.cell_value_at(Vector3i(int(wprobe2["x"]), 4, int(wprobe2["z"]))) == gen_before,
		"the same global cell generates identically before and after the flip (§8.2)")
	w.free()

# ---------------------------------------------------------------------------------------
# (e) Curved-render integration — collider / temperature / mesher reads resolve the GLOBAL cell.
# ---------------------------------------------------------------------------------------
func _test_curved_render_integration() -> void:
	print("[e] CURVED-RENDER INTEGRATION — collider / temperature / mesher reads resolve the GLOBAL cell at a non-zero origin")
	var n := CS.n_for(CS.HOME_BODY)
	var i_org := 4000
	var j_org := 6000
	var w := _bare_world()
	w.install_chart(CHART.new(CS.HOME_BODY, 4, i_org, j_org))
	var x := 17
	var z := -9
	# The wrappers fold to the GLOBAL column and read TerrainConfig — which honours FLAT_WORLD, so in
	# this verify (const on) the reference is the generator sampled at the GLOBAL (folded) column. The
	# point of the gate is that it is the GLOBAL column, NOT the raw window column (which differs here).
	var expect_h := TC.height_at(i_org + x, j_org + z)
	_ok(w.col_height(x, z) == expect_h, "col_height resolves the GLOBAL cell (folds the origin), not the window column")
	# Prove the fold ROBUSTLY (not on a fixed column whose two heights may coincidentally match): search a
	# small patch for a column where the GLOBAL and raw-window heights genuinely differ, then assert
	# col_height matches the global and NOT the window there. Terrain varies over the patch → always found.
	var fold_proved := false
	for dx in range(0, 16):
		for dz in range(0, 16):
			var gh := TC.height_at(i_org + x + dx, j_org + z + dz)
			var wh := TC.height_at(x + dx, z + dz)
			if gh != wh:
				fold_proved = w.col_height(x + dx, z + dz) == gh and w.col_height(x + dx, z + dz) != wh
				break
		if fold_proved:
			break
	_ok(fold_proved, "col_height folds the origin: at some column the global height ≠ the raw-window height and col_height == global")
	_ok(w.effective_height(x, z) == expect_h, "effective_height resolves the GLOBAL cell")

	# Window-independence: a second world at a DIFFERENT origin whose window maps to the SAME global
	# cell reads the same height / modifier — the collider builds the right columns after a re-anchor.
	var w2 := _bare_world()
	w2.install_chart(CHART.new(CS.HOME_BODY, 4, i_org + 50, j_org + 70))
	_ok(w.col_height(x, z) == w2.col_height(x - 50, z - 70), "col_height is window-independent (same global cell, two origins)")
	_ok(w.col_surface_modifier(x, z) == w2.col_surface_modifier(x - 50, z - 70), "col_surface_modifier is window-independent")
	_ok(w.col_surface_cap_modifier(x, z) == w2.col_surface_cap_modifier(x - 50, z - 70), "col_surface_cap_modifier is window-independent")

	# PerVoxelEnvironment.temperature reads the GLOBAL surface, so it is window-independent AND takes a
	# concrete value from the global column (a ground cell 5 below the global surface reads 21.5−5 C).
	var pve_a := PVE.new(); pve_a.set_chart(w.chart())
	var pve_b := PVE.new(); pve_b.set_chart(w2.chart())
	# 5 blocks below the GLOBAL surface (expect_h is the flat-global reference above) → depth 5.
	var pos_a := Vector3(float(x) + 0.5, float(expect_h - 5) + 0.5, float(z) + 0.5)
	var pos_b := Vector3(float(x - 50) + 0.5, float(expect_h - 5) + 0.5, float(z - 70) + 0.5)
	_ok(pve_a.temperature(pos_a) == pve_b.temperature(pos_b), "PerVoxelEnvironment.temperature is window-independent (global-cell fold)")
	# Robust value check (not a hardcoded 16.5, which depends on the column's seed/latitude climate): the
	# sub-surface temperature is LINEAR in depth (a constant per-block lapse), read off the GLOBAL column.
	# Assert equal decrements over equal depth steps + a non-flat profile — deterministic for any seed.
	var t1 := pve_a.temperature(Vector3(float(x) + 0.5, float(expect_h - 1) + 0.5, float(z) + 0.5))
	var t3 := pve_a.temperature(Vector3(float(x) + 0.5, float(expect_h - 3) + 0.5, float(z) + 0.5))
	var t5 := pve_a.temperature(Vector3(float(x) + 0.5, float(expect_h - 5) + 0.5, float(z) + 0.5))
	_ok(absf((t1 - t3) - (t3 - t5)) < 1e-4 and absf(t1 - t5) > 1e-3,
		"temperature is LINEAR in depth off the GLOBAL surface (constant per-block lapse), not the window column")

	# Fallback-mesher overlay iteration: placed_cells_window unfolds BOTH a home-face edit and an
	# across-seam edit back into the window (so the mesher renders placed blocks across the seam).
	var we := _bare_world()
	var ce := CHART.new(CS.HOME_BODY, 4, n - 3, 5000)
	we.install_chart(ce)
	var wc_home := Vector3i(-1, 5, 100)                 # global i = n-4 (in range)
	var wc_seam := Vector3i(6, 5, 100)                  # global i = n+3 (past EAST)
	we._write_cell(wc_home, CellCodec.pack(BlockCatalog.GRASS))
	we._write_cell(wc_seam, CellCodec.pack(BlockCatalog.STONE))
	var pw := we.placed_cells_window()
	_ok(pw.has(wc_home) and CellCodec.mat(pw[wc_home]) == BlockCatalog.GRASS,
		"placed_cells_window has the home-face edit at its window cell")
	_ok(pw.has(wc_seam) and CellCodec.mat(pw[wc_seam]) == BlockCatalog.STONE,
		"placed_cells_window unfolds the across-seam edit back into the window")
	_ok(we.overlay_at(wc_seam) == CellCodec.pack(BlockCatalog.STONE),
		"overlay_at reads the across-seam edit via its window cell (folds to the global key)")
	w.free(); w2.free(); we.free()

# ---------------------------------------------------------------------------------------
# (f) CRASH-FIX REGRESSION — the CubeSphere edge-remap table is a lazily-built static Dictionary/
# Array. In curved mode the worldgen fold runs on BOTH the voxel WORKER and the main thread; if the
# worker first-touches the lazy build while the main thread folds concurrently, the shared container
# corrupts → the worker dies with "index out of bounds" (the browser hang this suite guards against).
# The fix pre-builds the table on the main thread in TerrainConfig.warm_up() (via
# CubeSphere.warm_edge_tables) BEFORE the worker attaches, so every later fold is a pure concurrent
# READ of a frozen table. This test reproduces the exact hazard: WARM first, then storm fold_cell
# from many threads (incl. the main thread) over out-of-range columns (the WEST/EAST edge strips),
# and assert every fold returns a valid neighbour face with NO error/crash — and matches the
# single-threaded reference. Pre-fix this SIGSEGVs; post-fix it is deterministic and clean.
# ---------------------------------------------------------------------------------------
func _test_edge_table_race_safety() -> void:
	print("[f] CRASH-FIX — edge-remap table is race-safe once warm_edge_tables() has pre-built it (WGC §7.4)")
	var n := CS.n_for(CS.HOME_BODY)
	# The fix under test: pre-build on the main thread (TerrainConfig.warm_up already did this when
	# curved; call explicitly so the test stands alone regardless of the FLAT_WORLD const).
	CS.warm_edge_tables(n)
	# Single-threaded reference for a set of out-of-range (edge-strip) columns.
	var cols := []
	var ref := []
	for k in range(64):
		var col := Vector2i(-1 - (k % 40), (k * 131) % n)   # WEST spill (in-range j)
		cols.append(col)
		var g := CS.fold_cell(CS.HOME_FACE, col.x, col.y, n)
		ref.append(int(g["face"]) * 1000000007 + int(g["i"]) * 131 + int(g["j"]))
	# Concurrent storm: every thread folds the SAME columns many times; a corrupt table would crash or
	# return a face outside [0, 6). Each thread accumulates a mismatch count against the reference.
	var mism := [0]
	var lock := Mutex.new()
	var worker := func(_seed: int) -> void:
		var local := 0
		for _rep in range(2000):
			for idx in range(cols.size()):
				var col: Vector2i = cols[idx]
				var g := CS.fold_cell(CS.HOME_FACE, col.x, col.y, n)
				var f := int(g["face"])
				if f < 0 or f >= 6:
					local += 1
					continue
				if f * 1000000007 + int(g["i"]) * 131 + int(g["j"]) != int(ref[idx]):
					local += 1
		lock.lock(); mism[0] += local; lock.unlock()
	var threads := []
	for i in range(6):
		var t := Thread.new()
		t.start(worker.bind(i))
		threads.append(t)
	worker.call(999)   # the main thread folds concurrently too
	for t in threads:
		t.wait_to_finish()
	_ok(mism[0] == 0, "concurrent edge folds across %d threads are race-free after warm_edge_tables (mismatches=%d)" % [threads.size() + 1, mism[0]])
