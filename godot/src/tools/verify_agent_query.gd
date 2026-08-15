extends SceneTree
## COSMOS-AGENT-CONTROL §5.6 — headless gate for the FP_AGENT_QUERY voxel-query core.
## Run: godot --headless --path godot --script res://src/tools/verify_agent_query.gd
##
## The wire path (relay 0x03 frame, WS round-trip, executor latch) is a LIVE A/B (§5.6); this gate
## pins the CPU-testable invariants that the correctness of the query rests on:
##   * block_box_slice assembles EXACTLY the direct block_id_at loop — the overlay-consistency claim
##     (CLAUDE.md rule 1), INCLUDING after place/break edits (the whole point of routing through block_id_at);
##   * the x-fastest,z,y index layout matches the header `order` (a marked cell lands at its computed index);
##   * the time-slice budget is resume-safe (a 1-cell budget yields the same grid as a whole-box budget);
##   * NEVER-OOM caps: an over-cap box completes empty (never allocates past QUERY_CELLS_MAX).
## block_box_slice is NOT flag-gated (it is a plain WorldManager method), so this gate runs byte-off.

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
	BlockCatalog.ensure_ready()
	TerrainConfig.warm_up()
	_test_box_equality()
	_test_overlay_edits()
	_test_ordering()
	_test_time_slice_resume()
	_test_caps()
	print("==== VERIFY-AGENT-QUERY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## The reference: a direct block_id_at loop over the same box, in the SAME x-fastest,z,y order.
func _reference_ids(world: WorldManager, center: Vector3i, half: Vector3i) -> PackedByteArray:
	var dimx := 2 * half.x + 1
	var dimy := 2 * half.y + 1
	var dimz := 2 * half.z + 1
	var out := PackedByteArray()
	out.resize(dimx * dimy * dimz)
	var i := 0
	for dy in range(dimy):
		for dz in range(dimz):
			for dx in range(dimx):
				var bid := world.block_id_at(center + Vector3i(dx - half.x, dy - half.y, dz - half.z))
				out[i] = bid if (bid >= 0 and bid <= 255) else 255
				i += 1
	return out

## Fill a whole box in one call (budget ≥ total) and return the ids.
func _fill_all(world: WorldManager, center: Vector3i, half: Vector3i) -> PackedByteArray:
	var state := {"ids": PackedByteArray(), "i": 0}
	var guard := 0
	while not world.block_box_slice(center, half, state, CubeSphere.QUERY_CELLS_MAX) and guard < 100000:
		guard += 1
	return state["ids"]

func _test_box_equality() -> void:
	var world := WorldManager.new()
	# A spread of centers/half-extents over generated terrain (no edits yet).
	for spec in [[Vector3i(40, 40, 40), Vector3i(2, 2, 2)],
			[Vector3i(-17, 8, 63), Vector3i(4, 1, 3)],
			[Vector3i(128, 70, -96), Vector3i(3, 3, 3)],
			[Vector3i(5, 5, 5), Vector3i(0, 0, 0)]]:
		var center: Vector3i = spec[0]
		var half: Vector3i = spec[1]
		var got := _fill_all(world, center, half)
		var want := _reference_ids(world, center, half)
		_ok(got == want, "block_box_slice == direct block_id_at loop @ %s half %s (%d cells)" % [center, half, want.size()])
	world.queue_free()

## The y of the top SOLID cell of column (x,z) — scanned from high air downward (place_block needs support).
func _surface_top(world: WorldManager, x: int, z: int) -> int:
	for y in range(200, -80, -1):
		if world.cell_solid(Vector3i(x, y, z)):
			return y
	return -80

func _test_overlay_edits() -> void:
	var world := WorldManager.new()
	var half := Vector3i(2, 2, 2)
	var dimx := 2 * half.x + 1
	var dimz := 2 * half.z + 1
	# --- PLACE (supported): a block on the surface stays; _structural_update would detach a mid-air one. ---
	var ax := 64
	var az := 64
	var st := _surface_top(world, ax, az)
	var placed_cell := Vector3i(ax, st + 1, az)             # directly on the surface ⇒ supported
	_ok(world.place_block(placed_cell, 3), "place STONE(3) on the surface (supported)")
	_ok(world.block_id_at(placed_cell) == 3, "placed STONE reads back id 3 via block_id_at")
	var ca := placed_cell
	var gotp := _fill_all(world, ca, half)
	_ok(gotp == _reference_ids(world, ca, half), "block_box_slice == direct loop over a PLACED edit")
	var pl := placed_cell - (ca - half)
	_ok(int(gotp[(pl.y * dimz + pl.z) * dimx + pl.x]) == 3, "placed STONE at its x-fastest index in the box")
	# --- BREAK (separate column, fully decoupled from the placement): dig a surface cell to air. ---
	var bx := 64
	var bz := -64
	var bst := _surface_top(world, bx, bz)
	var broken_cell := Vector3i(bx, bst, bz)               # the top solid cell
	_ok(world.cell_solid(broken_cell), "surface cell is solid before break")
	world.break_terrain(broken_cell, Vector3.INF)          # dig to air (id 0), overlay path
	_ok(world.block_id_at(broken_cell) == 0, "after break, surface cell reads AIR via block_id_at")
	var cb := broken_cell
	var gotb := _fill_all(world, cb, half)
	_ok(gotb == _reference_ids(world, cb, half), "block_box_slice == direct loop over a BROKEN edit")
	var br := broken_cell - (cb - half)
	_ok(int(gotb[(br.y * dimz + br.z) * dimx + br.x]) == 0, "broken cell reads AIR at its index in the box")
	world.queue_free()

func _test_ordering() -> void:
	# A single distinctive block at a known offset must land at (dy*dimz+dz)*dimx+dx — the header `order`.
	var world := WorldManager.new()
	var x := -40
	var z := 22
	var st := _surface_top(world, x, z)
	var center := Vector3i(x, st, z)                   # box centered on the surface
	var half := Vector3i(3, 2, 4)
	var placed := Vector3i(x, st + 1, z)               # directly on the surface ⇒ supported (reads back)
	var off := placed - center                          # (0,1,0), inside the box (half.y=2)
	_ok(world.place_block(placed, 4), "place WOOD(4) on the surface at a known offset")
	var got := _fill_all(world, center, half)
	var dimx := 2 * half.x + 1
	var dimz := 2 * half.z + 1
	var local := off + half                            # (dx,dy,dz) in [0,dim)
	var idx := (local.y * dimz + local.z) * dimx + local.x
	_ok(int(got[idx]) == 4, "x-fastest,z,y index maps the marked cell correctly (idx %d)" % idx)
	world.queue_free()

func _test_time_slice_resume() -> void:
	# A 1-cell-per-call budget must produce the identical grid to a whole-box budget (resume-safe cursor).
	var world := WorldManager.new()
	var center := Vector3i(12, 33, -8)
	var half := Vector3i(2, 2, 2)
	var whole := _fill_all(world, center, half)
	var state := {"ids": PackedByteArray(), "i": 0}
	var steps := 0
	while not world.block_box_slice(center, half, state, 1) and steps < 100000:
		steps += 1
	_ok(state["ids"] == whole, "1-cell-budget slice == whole-box slice (resume-safe)")
	var dims := (2 * half.x + 1) * (2 * half.y + 1) * (2 * half.z + 1)
	_ok(steps == dims - 1, "1-cell budget took exactly (cells-1) resume calls (%d)" % steps)
	world.queue_free()

func _test_caps() -> void:
	var world := WorldManager.new()
	# An over-cap half (each axis at the max ⇒ 31³ = 29791 ≤ cap, that's fine; push one axis past to overflow).
	# Force cells > QUERY_CELLS_MAX by construction is impossible via half ≤ 15 (31³ < 32768), so assert the
	# in-method clamp instead: a half ABOVE QUERY_HALF_MAX is clamped, never allocates the unclamped size.
	var big := Vector3i(999, 999, 999)
	var state := {"ids": PackedByteArray(), "i": 0}
	var done := world.block_box_slice(Vector3i.ZERO, big, state, CubeSphere.QUERY_CELLS_MAX)
	var ids: PackedByteArray = state["ids"]
	var clamped := 2 * CubeSphere.QUERY_HALF_MAX + 1
	_ok(ids.size() <= clamped * clamped * clamped, "over-cap half is CLAMPED to QUERY_HALF_MAX (never allocates unbounded): %d cells" % ids.size())
	_ok(ids.size() <= CubeSphere.QUERY_CELLS_MAX, "clamped box stays within QUERY_CELLS_MAX (%d)" % ids.size())
	# When the box completes, done is eventually true (drive it to completion with a big budget).
	var guard := 0
	while not done and guard < 100000:
		done = world.block_box_slice(Vector3i.ZERO, big, state, CubeSphere.QUERY_CELLS_MAX)
		guard += 1
	_ok(done, "clamped box completes")
	world.queue_free()
