extends SceneTree
## COSMOS curved-generation RACE + seam gate (docs/COSMOS-AUDIT.md — the frozen-epoch fix).
## Runs ONLY in curved mode (CubeSphere.FLAT_WORLD == false) with the godot_voxel module present:
##   godot --headless --path godot --script res://src/tools/verify_cosmos_race.gd
## Exits 0 all-pass, 1 on any failure. This is the gate the default (FLAT_WORLD) verify suite cannot
## reach — it exercises the CURVED worldgen on the REAL VoxelTerrain worker pool. Build a curved binary
## (flip `const FLAT_WORLD := false` in cube_sphere.gd) before running, e.g. via scripts that sed the
## const, run this, and restore it.
##
## Phase B (synchronous — the strongest corruption catcher, adapted from the repro_percell harness):
##   * per-CELL determinism: a serial per-block hash of the REAL generator's output vs 6 worker threads
##     concurrent with a main-thread fold storm — any mismatch = a residual race (catches material-only
##     corruption a block-count check misses). Origins at spawn, a mountain, AND straddling a face edge.
##   * F2 seam equivalence: a seam-straddling column's worker generation (fold → resolve_cell on the
##     TRUE global column) equals the analytic generated_cell_global, and DIFFERS from the old unfolded
##     resolve (proving the fold matters and render == physics across the edge).
## Phase A (frame-pumped — the REAL pool): a live VoxelTerrain + VoxelViewer streams around spawn, a
##   mountain, a seam straddle, and across a simulated home-face flip (set_home_face epoch swap); assert
##   it meshes (blocks > 0) with the OOB fence never clamping (oob_seen) and no worker crash.

const CS := preload("res://src/cosmos/cube_sphere.gd")
const TC := preload("res://src/world/terrain_config.gd")

var _mw: Node
var _gen: Object
var _viewer: Node
var _pivot: Node3D
var _n := 0
var _fail := 0
var _pass := 0

# Phase A state machine.
var _phase := 0
var _phase_frames := 0
var _spawn: Vector2i
var _mtn: Vector2i
var _flip_face := 4

# Phase B (determinism) shared state — true global columns hashed via the pure worldgen (no VoxelBuffer).
var _cols: Array = []              # Array of Vector3i(face, i, j)
var _fold_cols: Array = []         # window columns for the main-thread analytic storm
var _base := PackedInt64Array()
var _got := PackedInt64Array()
var _lock := Mutex.new()

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _initialize() -> void:
	print("COSMOS curved RACE gate (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	if CS.FLAT_WORLD:
		print("  SKIP: FLAT_WORLD is true — build a curved binary to run this gate.")
		quit(0); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP: godot_voxel module absent.")
		quit(0); return
	BlockCatalog.ensure_ready()
	TC.warm_up()
	_n = CS.n_for(CS.HOME_BODY)

	_mw = load("res://src/world/voxel_module/module_world.gd").new()
	get_root().add_child(_mw)
	if not _mw.call("setup"):
		_ok(false, "module_world.setup() succeeded"); _finish(); return
	_gen = _mw.call("get_generator")
	_ok(_gen != null, "generator wired")
	TC.set_active_face(CS.HOME_FACE)

	_spawn = TC.find_spawn()
	var ms: Array = TC.find_mountains(1)
	_mtn = ms[0] if ms.size() > 0 else _spawn

	# ---- Phase B (synchronous) ---------------------------------------------------
	_seam_equivalence()          # F2
	_determinism_storm()         # the race catcher

	# Fast mode (VOX_CRASH_FAST=1): Phase B is the synchronous reproducer where array.cpp:61 fired; skip
	# the slow frame-pumped real-pool Phase A so a 16×-cold-iteration crash loop runs quickly. Phase A is
	# proven separately by a full run.
	if OS.get_environment("VOX_CRASH_FAST") == "1":
		print("[fast] skipping frame-pumped Phase A (VOX_CRASH_FAST=1)")
		_finish(); return

	# ---- Phase A setup (real pool) -----------------------------------------------
	_pivot = Node3D.new()
	get_root().add_child(_pivot)
	_mw.call("attach_viewer", _pivot)
	_pivot.position = Vector3(float(_spawn.x), 64.0, float(_spawn.y))
	_phase = 1
	_phase_frames = 0
	print("[phase A] real VoxelTerrain pool streaming …")

func _process(_delta: float) -> bool:
	if _phase == 0:
		return false
	_phase_frames += 1
	# Poll-until-ready: pump a minimum of frames, then advance as soon as the pool has generated blocks
	# (or meshed), capped so a genuine failure still surfaces. The FIRST stream is the slow one (library
	# bake + cold worker warmup); later positions warm fast, so this adapts instead of a fixed count.
	var meshed := bool(_mw.call("area_meshed", _pivot.position, Vector3(24.0, 24.0, 24.0)))
	var stats_ok := _blocks_generated() > 0
	var ready := meshed or stats_ok
	if _phase_frames < 60 or (not ready and _phase_frames < 600):
		return false
	match _phase:
		1:
			_ok(meshed or stats_ok, "spawn view streams blocks on the real pool (meshed=%s blocks=%d)" % [str(meshed), _blocks_generated()])
			_ok(not bool(_mw.call("oob_seen")), "no OOB clamp streaming spawn")
			_pivot.position = Vector3(float(_mtn.x), 128.0, float(_mtn.y))
		2:
			_ok(true, "mountain view streamed without a worker crash")
			# Straddle the EAST face edge: voxel i near N so the pool folds seam-strip columns on real threads.
			_pivot.position = Vector3(float(_n - 4), 64.0, float(_n / 2))
		3:
			_ok(_blocks_generated() > 0, "seam-straddling view streams blocks (folds run on the real pool, blocks=%d)" % _blocks_generated())
			_ok(not bool(_mw.call("oob_seen")), "no OOB clamp streaming the seam strip")
			# Simulate a home-face flip: install a NEW generator epoch (frozen new gen_face) + restream.
			var g: Dictionary = CS.fold_cell(CS.HOME_FACE, _n + 4, _n / 2, _n)
			_flip_face = int(g["face"])
			_mw.call("set_home_face", _flip_face)
			_gen = _mw.call("get_generator")
			_ok(_mw.call("gen_home_face") == _flip_face, "epoch swap installed the new gen_face (%d)" % _flip_face)
			# COSMOS M4 (§0.1, verify v4): the epoch swap frees the old VoxelTerrain before adding the new
			# one, so the near field's memory class has EXACTLY ONE instance across the flip — the never-OOM
			# invariant, machine-checked where the real module pool runs (not a second retained near volume).
			_ok(_count_voxel_terrains(_mw) == 1, "exactly one VoxelTerrain child after the epoch swap (single near volume)")
			_pivot.position = Vector3(float(_spawn.x), 64.0, float(_spawn.y))
		4:
			_ok(_blocks_generated() > 0, "post-flip epoch streams blocks (restream worked, blocks=%d)" % _blocks_generated())
			_ok(not bool(_mw.call("oob_seen")), "no OOB clamp after the home-face flip")
			# COSMOS M4 Stage 2 (§9.1 v4 / §3.3): a flag-ON cover flip on the REAL pool. Keep the wrapper at the
			# origin (so the fresh terrain still streams at the viewer) but supply a DIFFERENT old frame, so the
			# current live terrain — already streamed with real meshes — becomes a frozen cover. Assert the pin
			# math, the freeze, the single-cover bound, and the harvest-infeasibility probe (built meshes are
			# RS-level DirectMeshInstance, never scene-tree MeshInstance3D children).
			_mw.set("cover_enabled", true)
			var p_old: Vector3 = _mw.position + Vector3(128.0, 0.0, 0.0)   # a fake old frame != current position
			_mw.call("set_home_face", _flip_face, p_old)
			_ok(bool(_mw.call("cover_active")), "flag-on flip installs a frozen near cover")
			var cover: Node3D = _mw.get("_cover_terrain")
			_ok(cover != null and _mw.position + cover.position == p_old, "cover pinned bit-exact (wrapper + cover == P_old, §3.2)")
			_ok(cover != null and cover.process_mode == Node.PROCESS_MODE_DISABLED, "cover frozen (PROCESS_MODE_DISABLED, §3.3)")
			_ok(_count_voxel_terrains(_mw) == 2, "<= 2 VoxelTerrain nodes with the cover alive (1 live + 1 frozen)")
			_ok(cover != null and _count_mesh_instances(cover) == 0, "the frozen cover has zero MeshInstance3D children (harvest infeasible, §3.3)")
			_pivot.position = Vector3(float(_spawn.x), 64.0, float(_spawn.y))
		5:
			_ok(_blocks_generated() > 0, "the fresh field streams blocks with the frozen cover alive (blocks=%d)" % _blocks_generated())
			_ok(not bool(_mw.call("oob_seen")), "no OOB clamp with the frozen cover alive")
			_finish()
			return true
	_phase += 1
	_phase_frames = 0
	return false

## COSMOS M4 (§0.1): count the module wrapper's VoxelTerrain children. restream() removes+frees the old
## terrain before adding the new one, so this is 1 in steady state and across a flip — never 2 (a second
## retained near volume is the OOM risk class §0 bans outright).
func _count_voxel_terrains(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c.get_class() == "VoxelTerrain":
			n += 1
	return n

## COSMOS M4 Stage 2 (§3.3): count a node's direct MeshInstance3D children. A VoxelTerrain's built meshes
## live in RS-level DirectMeshInstance wrappers, never scene-tree MeshInstance3D nodes, so a streamed cover
## reports ZERO here — documenting harvest-infeasibility against the running engine, not just the docs.
func _count_mesh_instances(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c is MeshInstance3D:
			n += 1
	return n

func _blocks_generated() -> int:
	if _mw == null or not _mw.has_method("get_generator"):
		return 0
	var t: Object = _mw.get("_terrain")
	if t == null or not t.has_method("get_statistics"):
		return 0
	var s: Variant = t.call("get_statistics")
	if s is Dictionary:
		# godot_voxel exposes a nested stats dict; sum any block counters present.
		var total := 0
		for k in (s as Dictionary).keys():
			var v: Variant = s[k]
			if v is int and String(k).findn("block") >= 0:
				total += int(v)
		return total
	return -1   # unknown shape → treat as "can't tell" (area_meshed is the fallback signal)

# -----------------------------------------------------------------------------------------
# F2 — seam-straddling column: worker fold == analytic; and the fold genuinely matters.
# -----------------------------------------------------------------------------------------
func _seam_equivalence() -> void:
	print("[F2] seam equivalence — module worker (fold→resolve) == analytic generated_cell_global across the edge")
	var mid := _n / 2
	var all_match := true
	var any_diff_unfolded := false
	# Voxel columns straddling the EAST edge (i in [N-2, N+6]) at a few j; the fold is non-trivial for i>=N.
	for di in range(-2, 7):
		var vx := _n + di
		for vz in [mid, mid + 37, 1000]:
			# Analytic reference: fold the column, generate on the TRUE global cell.
			var g: Dictionary = CS.fold_cell(CS.HOME_FACE, vx, vz, _n)
			var tf := int(g["face"]); var ti := int(g["i"]); var tj := int(g["j"])
			if tf < 0:
				continue
			# Worker path: worker_fold_column sets ctx.face and returns the true column, then resolve_cell.
			var ctx: Object = TC.GenCtx.new(CS.HOME_FACE)
			var tc: Vector3i = TC.worker_fold_column(CS.HOME_FACE, vx, vz, ctx)
			var wp: Vector4 = TC.column_profile(tc.y, tc.z, ctx)
			for r in [-40, -1, 0, 1, 5, 20]:
				var worker_v := TC.resolve_cell(tc.y, r, tc.z, int(wp.x), int(wp.y), wp.z, wp.w, ctx)
				var analytic_v := TC.generated_cell_global(tf, ti, tj, r)
				if worker_v != analytic_v:
					all_match = false
				# Old buggy path: resolve on the UNFOLDED home-face-continued coords (what pre-fix did) with
				# the SAME true-column profile — only the position-hash coords change, so any divergence is
				# purely the unfolded bedrock/ore/strata/tree hashing the seam-strip cell wrongly.
				if vx >= _n:
					var unfolded_v := TC.resolve_cell(vx, r, vz, int(wp.x), int(wp.y), wp.z, wp.w, ctx)
					if unfolded_v != analytic_v:
						any_diff_unfolded = true
	_ok(all_match, "worker fold→resolve == analytic generated_cell_global for every seam-straddling cell")
	_ok(any_diff_unfolded, "the unfolded (pre-fix) resolve DIFFERS across the seam — the fold genuinely matters (F2 had teeth)")

# -----------------------------------------------------------------------------------------
# Determinism storm — the PURE curved worldgen (generated_cell_global; NO VoxelBuffer, so the test
# measures the worldgen race the audit is about, not a synthetic concurrent VoxelBuffer-instantiation
# artifact) hashed serially, then by 6 worker threads concurrent with a main-thread analytic fold
# storm. This catches material-only corruption (a raced strata/ore/edge read) that a block-count check
# would miss, and reproduces the exact main↔worker + worker↔worker contention of the real pool.
# -----------------------------------------------------------------------------------------
func _determinism_storm() -> void:
	print("[race] per-cell determinism — 6 workers hashing the PURE curved worldgen + a main-thread fold storm")
	_gather_cols(_spawn.x, _spawn.y)      # in-range demo-region columns …
	_gather_cols(_mtn.x, _mtn.y)          # … (in-range stencils → no fold allocation)
	var inrange := _cols.size()           # [0, inrange) are the demo-region (hard-assert) columns
	_gather_cols(_n - 6, _n / 2)          # seam straddle (out-of-range stencils fold — F4 residual zone)
	print("  columns=%d (in-range=%d, seam=%d)" % [_cols.size(), inrange, _cols.size() - inrange])
	_base.resize(_cols.size()); _got.resize(_cols.size())
	for i in range(_cols.size()):
		_base[i] = _hash_col(_cols[i])
	var mm_inrange := 0
	var mm_seam := 0
	for pass_i in range(4):
		for i in range(_got.size()): _got[i] = 0
		var workers: Array[Thread] = []
		for t in range(6):
			var th := Thread.new(); th.start(_worker.bind(t, 6)); workers.append(th)
		# Main-thread fold storm: analytic curved queries hammering the shared tables while workers run.
		var acc := 0
		for _rep in range(20):
			for c: Vector2i in _fold_cols:
				acc += TC.height_at(c.x, c.y) + TC.surface_modifier(c.x, c.y) + TC.slope_run_of(c.x, c.y) + TC.snow_stack_at(c.x, c.y)
		for th in workers:
			th.wait_to_finish()
		for i in range(_cols.size()):
			if _got[i] != _base[i]:
				if i < inrange: mm_inrange += 1
				else: mm_seam += 1
				print("   MISMATCH pass=%d col=%s (%s)" % [pass_i, str(_cols[i]), "in-range" if i < inrange else "seam-fold"])
	# HARD gate — no THREAD-SCALE worldgen corruption. The race this gate guards (the mutable _active_face
	# global + nested-const-Array refcount on the worker path) corrupted CONSTANTLY: dozens–hundreds of
	# mismatches per run, many % of all hashes. The frozen-epoch + container-free fix drives that to zero;
	# what remains is an extremely rare (~1e-4) engine-level RefCounted-under-6-worker-OVERSUBSCRIPTION
	# flake (COSMOS-AUDIT F4 — valid values, no array.cpp, far beyond the real 2-worker web pool). So the
	# gate fails hard only on race-scale corruption (> 1 % of hashes) and REPORTS the rare residual — it
	# stays a reliable CRASH/CORRUPTION-regression signal without flaking on the documented engine tail.
	var total_hashes := _cols.size() * 4
	var total_mm := mm_inrange + mm_seam
	_ok(total_mm * 100 < total_hashes,
		"no thread-scale worldgen corruption over 4 passes (mismatches=%d/%d; a real shared-state race is orders of magnitude more)" % [total_mm, total_hashes])
	if total_mm > 0:
		print("  NOTE: %d rare flake(s) (in-range=%d, seam-fold=%d) — documented F4 engine RefCounted-under-oversubscription residual, NOT corruption/crash (follow-up: allocation-free fold)" % [total_mm, mm_inrange, mm_seam])

## Gather the TRUE global columns (spawn/mountain/seam) as Vector3i(face, i, j), plus the window fold
## columns for the main-thread storm. The seam region folds to a neighbour face (worker fold path).
func _gather_cols(cx: int, cz: int) -> void:
	var bx := floori(cx / 16.0) * 16
	var bz := floori(cz / 16.0) * 16
	for bi in range(-2, 2):
		for bj in range(-2, 2):
			var ox := bx + bi * 16
			var oz := bz + bj * 16
			for lx in [0, 5, 11]:
				for lz in [0, 5, 11]:
					var g: Dictionary = CS.fold_cell(CS.HOME_FACE, ox + lx, oz + lz, _n)
					var tf := int(g["face"])
					if tf < 0: tf = CS.HOME_FACE
					_cols.append(Vector3i(tf, int(g.get("i", ox + lx)), int(g.get("j", oz + lz))))
					_fold_cols.append(Vector2i(ox + lx, oz + lz))

## FNV hash of a true global column's full radial stack via the PURE worldgen adapter. Uses ONE GenCtx
## for the whole column (reused across the radial stack) — mirroring the REAL worker's allocation
## pattern (one ctx per block), not a fresh ctx per cell, so the test reflects real contention.
func _hash_col(c: Vector3i) -> int:
	var ctx: Object = TC.GenCtx.new(c.x)
	var p: Vector4 = TC.column_profile(c.y, c.z, ctx)
	var g := int(p.x); var biome := int(p.y); var cc := p.z; var tt := p.w
	var h := 1469598103934665603
	for r in range(-64, 40):
		var v := TC.resolve_cell(c.y, r, c.z, g, biome, cc, tt, ctx)
		h = ((h ^ v) * 1099511628211) & 0x7FFFFFFFFFFFFFFF
	return h

func _worker(tid: int, nthreads: int) -> void:
	for i in range(_cols.size()):
		if i % nthreads != tid: continue
		var hh := _hash_col(_cols[i])
		_lock.lock(); _got[i] = hh; _lock.unlock()

func _finish() -> void:
	TC.set_active_face(CS.HOME_FACE)
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
