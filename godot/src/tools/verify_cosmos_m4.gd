extends SceneTree
## COSMOS M4 — headless property tests for the seam-cross near-field HANDOFF (docs/COSMOS-M4-HANDOFF.md
## §9.1, revision 3 SHIP-BOTH). Run:
##   godot --headless --path godot --script res://src/tools/verify_cosmos_m4.gd
## Exits 0 all-pass, 1 on any failure. Like the M2/M3 suites it exercises the CURVED-mode invariants
## WITHOUT flipping CubeSphere.FLAT_WORLD (a const): the far-layer gates drive a bare FarTerrain; the cover
## gates drive a REAL module_world with `cover_enabled` overridden per-instance (the §3.1 discipline — the
## const stays false, prod is a one-line flip); the edit-re-mirror gate injects a chart + recording stub.
##
## Gates (§9.1):
##   (v1) TURBO SELECTION-NEUTRAL — desired set (+ capped output) identical with the window open vs closed.
##   (v2) WINDOW LIFECYCLE — begin/end/active; HANDOFF_MAX_SECONDS backstop; re-begin resets, not stacks.
##   (v3) NEAREST-FIRST WHILE OPEN — commit order ascends min_dist (the under-player tile first).
##   (v4) COVER MECHANICS (cover_enabled = true, real pool) — pin bit-exact (§3.2); frozen
##        (PROCESS_MODE_DISABLED); ≤ 2 VoxelTerrain nodes; a second flip supersedes; timeout retirement.
##   (v5) DEFAULT-FLAG BYTE-IDENTITY (cover_enabled = false) — old terrain freed immediately, exactly one
##        VoxelTerrain across a flip; the flag (not the argument) decides free-vs-cover.
##   (v6) FLAT_WORLD BYTE-IDENTITY — a chartless world never flips/latches/covers; a fresh FarTerrain
##        never opens a window; stock 3.0 ms / 1-commit constants unchanged.
##   (v7) EDIT RE-MIRROR (both modes) — a pre-flip in-near-radius edit (and a dug-to-air cell) arrive in
##        one bulk_inject after ramp_done(), keyed by the correct window cells; an out-of-radius edit does
##        not; and the bulk_inject is recorded BEFORE release_cover (§5.1 cover-mode sequencing).

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TC := preload("res://src/world/terrain_config.gd")
const MW := preload("res://src/world/voxel_module/module_world.gd")

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

## A recording stub for the module render path (M3 discipline): logs bulk_inject payloads + the ORDER of
## bulk_inject vs release_cover (for the §5.1 cover-mode sequencing check) and reports a caller-controlled
## ramp_done(). No set_home_face — the re-mirror gate drives the settling handshake directly.
class RecordingModule extends Node3D:
	var ramp := false
	var injected: Array = []
	var events: Array = []           # ordered log: "inject" / "release"
	func ramp_done() -> bool:
		return ramp
	func bulk_inject(cells: Dictionary) -> void:
		injected.append(cells.duplicate())
		events.append("inject")
	func release_cover() -> void:
		events.append("release")

func _initialize() -> void:
	print("COSMOS M4 — seam-cross handoff verification (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	BlockCatalog.ensure_ready()
	TC.warm_up()
	_test_selection_neutral()          # (v1)
	_test_window_lifecycle()           # (v2)
	_test_nearest_first()              # (v3)
	_test_cover_mechanics()            # (v4)
	_test_default_flag_byte_identity() # (v5)
	_test_flat_byte_identity()         # (v6)
	_test_edit_remirror()              # (v7)
	TC.set_active_face(CS.HOME_FACE)
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _bare_world() -> WorldManager:
	return WorldManager.new()

## Count a module wrapper's VoxelTerrain children (the §0.1 / §5.2 volume invariant).
func _count_vt(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c.get_class() == "VoxelTerrain":
			n += 1
	return n

func _far_capped_ok(far: FarTerrain) -> bool:
	# The capped desired set must respect all three hard caps in _apply_caps (LOD-DESIGN §1.2).
	var tiles := far.desired_keys().size()
	var tris := 0
	for k in far.desired_keys():
		tris += int(far.desired_info(k)["tris"])
	return tiles <= FarTerrain.FAR_MAX_TILES and tiles <= FarTerrain.FAR_MAX_DRAWS and tris <= FarTerrain.FAR_MAX_TRIS

# ---------------------------------------------------------------------------------------
# (v1) The turbo is selection-neutral — same desired set open vs closed, caps respected in both.
# ---------------------------------------------------------------------------------------
func _test_selection_neutral() -> void:
	print("[v1] TURBO SELECTION-NEUTRAL — the desired set + its capped output are identical with the window open vs closed")
	var far := FarTerrain.new()
	get_root().add_child(far)
	var e := Vector2(400.0, -250.0)
	far.end_handoff()
	far._recompute(e)
	var closed := {}
	for k in far.desired_keys():
		closed[k] = true
	var closed_caps_ok := _far_capped_ok(far)
	far.begin_handoff()
	far._recompute(e)
	var open_keys := far.desired_keys()
	var same := open_keys.size() == closed.size()
	for k in open_keys:
		if not closed.has(k):
			same = false
	_ok(same, "the desired set is identical open vs closed (turbo changes WHEN, not WHAT — %d tiles)" % open_keys.size())
	_ok(closed_caps_ok and _far_capped_ok(far), "the capped set respects FAR_MAX_TILES/DRAWS/TRIS in both states")
	far.free()

# ---------------------------------------------------------------------------------------
# (v2) Window lifecycle — begin/end/active, the backstop, and reset-not-stack.
# ---------------------------------------------------------------------------------------
func _test_window_lifecycle() -> void:
	print("[v2] WINDOW LIFECYCLE — begin/end/active + HANDOFF_MAX_SECONDS backstop + re-begin resets (not stacks)")
	var far := FarTerrain.new()
	get_root().add_child(far)
	far.end_handoff()
	_ok(not far.handoff_active(), "a fresh window is inactive")
	far.begin_handoff()
	_ok(far.handoff_active() and far._handoff_left == FarTerrain.HANDOFF_MAX_SECONDS,
		"begin_handoff opens the window for HANDOFF_MAX_SECONDS (%.1fs)" % FarTerrain.HANDOFF_MAX_SECONDS)
	far.end_handoff()
	_ok(not far.handoff_active(), "end_handoff closes the window")
	far.begin_handoff()
	far._process(FarTerrain.HANDOFF_MAX_SECONDS + 0.1)
	_ok(not far.handoff_active(), "the window self-closes past HANDOFF_MAX_SECONDS (starvation backstop)")
	far.begin_handoff()
	far._process(3.0)
	_ok(absf(far._handoff_left - (FarTerrain.HANDOFF_MAX_SECONDS - 3.0)) < 1e-6, "_process decrements the window clock")
	far.begin_handoff()
	_ok(far._handoff_left == FarTerrain.HANDOFF_MAX_SECONDS, "re-begin RESETS the clock (does not stack)")
	# The rung-2 short-circuit (HANDOFF_ENABLED = false) is a COMPILE-TIME const (the SMOOTHING_ENABLED
	# diagnostic-toggle discipline), verified by inspection of begin_handoff's `if ENABLED and HANDOFF_ENABLED`
	# guard; the shipped build has it true (rung 0). Cannot be flipped at runtime without a rebuild.
	_ok(FarTerrain.ENABLED and FarTerrain.HANDOFF_ENABLED, "the shipped build is rung 0 (ENABLED and HANDOFF_ENABLED both true)")
	far.free()

# ---------------------------------------------------------------------------------------
# (v3) Nearest-first while the window is open — commit order is ascending min_dist.
# ---------------------------------------------------------------------------------------
func _test_nearest_first() -> void:
	print("[v3] NEAREST-FIRST WHILE OPEN — with the window open (no cover) the commit order is ascending min_dist")
	var far := FarTerrain.new()
	get_root().add_child(far)
	far.begin_handoff()                    # window open, no cover → nearest-first sort
	far._recompute(Vector2(0.0, 0.0))
	far.drain_for_test()                   # commits in queue (nearest-first) order; _live insertion == commit order
	var ascending := true
	var prev := -1.0
	var n_checked := 0
	for k in far.live_keys():
		var info := far.desired_info(k)
		if not info.has("min_dist"):
			continue
		var d := float(info["min_dist"])
		if d + 1e-3 < prev:
			ascending = false
		prev = d
		n_checked += 1
	_ok(n_checked > 0, "the handoff drain committed tiles to inspect (%d)" % n_checked)
	_ok(ascending, "commit order is nearest-first (min_dist non-decreasing) while the window is open")
	far.free()

# ---------------------------------------------------------------------------------------
# (v4) Cover mechanics — the flag-on frozen near cover, on a real module pool.
# ---------------------------------------------------------------------------------------
func _test_cover_mechanics() -> void:
	print("[v4] COVER MECHANICS (cover_enabled=true, real module) — pin bit-exact, freeze, superseded, timeout")
	if not ClassDB.class_exists("VoxelTerrain"):
		print("     SKIP: godot_voxel module absent in this binary.")
		return
	var mw := MW.new()
	get_root().add_child(mw)
	if not mw.call("setup"):
		_ok(false, "module_world.setup() for the cover gate")
		mw.free(); return
	mw.set("cover_enabled", true)
	# Emulate a flip: move the wrapper to the NEW frame, then hand set_home_face the OLD frame position.
	var p_old := Vector3(-4000.0, 0.0, -6000.0)
	var p_new := Vector3(-4128.0, 0.0, -6000.0)
	mw.position = p_new
	mw.call("set_home_face", 3, p_old)
	_ok(bool(mw.call("cover_active")), "a flag-on flip installs a frozen near cover")
	var cover: Node3D = mw.get("_cover_terrain")
	_ok(cover != null, "the cover terrain node exists")
	if cover != null:
		_ok(mw.position + cover.position == p_old, "cover pinned bit-exact: wrapper.position + cover.position == P_old (§3.2)")
		_ok(cover.process_mode == Node.PROCESS_MODE_DISABLED, "cover is frozen (PROCESS_MODE_DISABLED, §3.3)")
	_ok(_count_vt(mw) == 2, "≤ 2 VoxelTerrain children with a cover alive (1 live + 1 frozen)")
	# Second flip → the prior cover is freed FIRST ("superseded"); still ≤ 2, still exactly one cover (§5.2).
	var p_new2 := Vector3(-4256.0, 0.0, -6000.0)
	mw.position = p_new2
	mw.call("set_home_face", 4, p_new)
	_ok(bool(mw.call("cover_active")) and _count_vt(mw) == 2, "a second flip supersedes the prior cover (still ≤ 2, exactly one cover)")
	# Timeout retirement: _process past NEAR_COVER_MAX_SECONDS with no release frees it ("timeout").
	mw._process(MW.NEAR_COVER_MAX_SECONDS + 0.1)
	_ok(not bool(mw.call("cover_active")) and _count_vt(mw) == 1, "the cover retires by timeout past NEAR_COVER_MAX_SECONDS (back to one volume)")
	mw.free()

# ---------------------------------------------------------------------------------------
# (v5) Default-flag byte-identity — flag off frees immediately; the flag (not the arg) decides.
# ---------------------------------------------------------------------------------------
func _test_default_flag_byte_identity() -> void:
	print("[v5] DEFAULT-FLAG BYTE-IDENTITY (cover_enabled=false) — old terrain freed immediately, exactly one volume")
	if not ClassDB.class_exists("VoxelTerrain"):
		print("     SKIP: godot_voxel module absent in this binary.")
		return
	var mw := MW.new()
	get_root().add_child(mw)
	if not mw.call("setup"):
		_ok(false, "module_world.setup() for the default gate")
		mw.free(); return
	# cover_enabled stays at the shipped false. Emulate a flip WITH an old frame supplied (2-arg) — the flag,
	# not the argument, must decide free-vs-cover.
	var p_old := Vector3(-4000.0, 0.0, -6000.0)
	mw.position = Vector3(-4128.0, 0.0, -6000.0)
	mw.call("set_home_face", 3, p_old)
	_ok(not bool(mw.call("cover_active")), "flag off → no cover even when an old frame is supplied")
	_ok(_count_vt(mw) == 1, "exactly ONE VoxelTerrain child across the flip (today's teardown byte-for-byte)")
	# The 1-arg call path (verify_cosmos_race compatibility) also frees immediately.
	mw.call("set_home_face", 4)
	_ok(not bool(mw.call("cover_active")) and _count_vt(mw) == 1, "the 1-arg set_home_face frees immediately too")
	mw.free()

# ---------------------------------------------------------------------------------------
# (v6) FLAT_WORLD byte-identity — no chart → no flip, no latch, no window; stock constants unchanged.
# ---------------------------------------------------------------------------------------
func _test_flat_byte_identity() -> void:
	print("[v6] FLAT_WORLD BYTE-IDENTITY — a chartless world never flips/latches/covers; a fresh FarTerrain never opens a window")
	var w := _bare_world()                 # no install_chart → _chart == null (the FLAT_WORLD default)
	_ok(not w.maybe_flip_home_face(Vector3(10000.0, 6.0, 10000.0)), "maybe_flip_home_face is a no-op with no chart")
	_ok(not w._flip_settling, "no flip → _flip_settling stays false")
	w.update_streaming(Vector3(1.0, 6.0, 1.0))
	_ok(not w._flip_settling, "update_streaming never latches _flip_settling in flat play")
	w.free()
	var far := FarTerrain.new()
	get_root().add_child(far)
	_ok(not far.handoff_active() and far._handoff_left == 0.0, "a fresh FarTerrain never opens a handoff window on its own")
	_ok(FarTerrain.FAR_BUILD_BUDGET_MS == 3.0 and FarTerrain.MAX_COMMITS_PER_FRAME == 1,
		"the stock drain budget/commit constants are unchanged (3.0 ms / 1 commit)")
	far.free()

# ---------------------------------------------------------------------------------------
# (v7) Edit re-mirror (both modes) — the §5.4 correctness fix + §5.1 cover-mode sequencing.
# ---------------------------------------------------------------------------------------
func _test_edit_remirror() -> void:
	print("[v7] EDIT RE-MIRROR — in-near-radius edits (incl. a dug-to-air cell) arrive in one bulk_inject after ramp_done(), before release_cover")
	var w := _bare_world()
	# A chart homed at the identity origin: window cell (x, z) → global (face, x, z), so window_of_global
	# folds each edit back to its ORIGINAL window cell (no flip between write and re-mirror in this gate).
	w.install_chart(CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0))
	var stub := RecordingModule.new()
	get_root().add_child(stub)
	w._module_world = stub

	var radius := float(TC.near_render_radius())     # FLAT → 256
	var player := Vector3(0.0, 6.0, 0.0)
	var placed := Vector3i(10, 20, 12)
	var dug := Vector3i(5, 15, 5)
	var far_edit := Vector3i(int(radius) + 40, 20, 0)
	w._write_cell(placed, CellCodec.pack(BlockCatalog.STONE))
	w._write_cell(dug, 0)                             # dug to air (overlay value 0)
	w._write_cell(far_edit, CellCodec.pack(BlockCatalog.GRASS))
	var placed_stored := w.cell_value_at(placed)
	_ok(placed_stored == CellCodec.canonical(CellCodec.pack(BlockCatalog.STONE)),
		"the placed edit is found again via its global key (M3 gate (d) intact)")

	# Simulate the flip's settling window WITHOUT a real flip: latch, then drive update_streaming.
	w._flip_settling = true
	stub.ramp = false
	w.update_streaming(player)
	_ok(stub.injected.is_empty() and w._flip_settling, "before ramp_done() no re-mirror fires and the latch holds")
	stub.ramp = true
	w.update_streaming(player)
	_ok(not w._flip_settling, "once ramp_done() is true the latch clears (one-shot)")
	_ok(stub.injected.size() == 1, "the re-mirror is exactly ONE bulk_inject call")
	if stub.injected.size() == 1:
		var cells: Dictionary = stub.injected[0]
		_ok(cells.has(placed) and int(cells[placed]) == placed_stored, "the in-radius placed edit re-mirrors at its window cell")
		_ok(cells.has(dug) and int(cells[dug]) == 0, "the dug-to-air cell re-mirrors as packed 0 (holes re-carve)")
		var has_far := false
		for k: Vector3i in cells.keys():
			if k.x == far_edit.x:
				has_far = true
		_ok(not has_far, "the out-of-near-radius edit is NOT re-mirrored (its block is unloaded)")
	# §5.1 cover-mode sequencing: the bulk_inject is recorded BEFORE release_cover, so a flag-on cover shows
	# every edit the frame it retires (no pop-out of player builds).
	var i_inject := stub.events.find("inject")
	var i_release := stub.events.find("release")
	_ok(i_inject >= 0 and i_release >= 0 and i_inject < i_release, "bulk_inject is sequenced before release_cover (§5.1)")
	stub.free()
	w.free()
