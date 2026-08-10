extends SceneTree
## FP_ORBIT_RELIEF gate (docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md, task #99 G3).
##
## Proves `FacetOrbitRelief` — the real relief-mesh tier that supersedes the rejected shading-only fix
## (FP_SKIN_RELIEF_SHADE/FP_RELIEF_REEMIT) — is byte-off by default, reads heights/positions that agree exactly
## with the already-baked `GlobalReliefData` DEM, welds bit-identically at shared facet edges, stays inside its
## NEVER-OOM byte cap, and never dispatches (or commits) more than its rate caps allow even under a pathological
## all-at-once burst.
##
## Gates (mirrors `verify_far_geometry.gd`/`verify_relief_reemit.gd`'s self-describing convention — this run's
## compiled flags decide which assertions are meaningful):
##   G-OR-OFF     — FP_ORBIT_RELIEF off: `FacetFarRing.set_relief_data` never constructs a `FacetOrbitRelief`.
##   G-OR-DATA-EQ — `build_tile`'s stored height at every one of a real facet's 1089 nodes equals
##                  `GlobalReliefData.height_at` EXACTLY. Falsifier: a hand-perturbed `heights` snapshot entry
##                  diverges from the oracle at that same node.
##   G-OR-BYTES   — `tile_bytes` matches the real per-component arithmetic; `want_set` truncates to
##                  `ORBIT_RELIEF_MAX_TILES` even when EVERY facet on the planet is a candidate; the resulting
##                  cap × real tile_bytes stays under a 32 MB safety ceiling.
##   G-OR-WELD    — two real adjacent facets' shared-edge node positions coincide (≤1e-4·R_BLOCKS, f32 rounding)
##                  — the One-Surface Law proof. No-protrusion: `sink_edges` set on a boundary sinks EXACTLY
##                  that boundary (by `TierPlace.backstop_sink()`) and leaves every interior node untouched.
##   G-OR-PACE    — a pathological "every facet on the planet wants a tile" burst still dispatches at most one
##                  build per free worker slot in ONE `step()` call (never a storm); the commit rate-cap
##                  (`should_commit`, pure) blocks a second commit inside the same window, allows one outside it.
##   G-OR-COMMIT-COST — the PERF FIX (live A/B regression, root-caused to a ≈250ms/commit main-thread
##                  `SurfaceTool.generate_normals()` pass over the whole merged mesh): (a) a real facet's
##                  `build_tile` normals are NOT the degenerate placeholder (pure radial) — real slope-informed
##                  analytic normals actually reach the tile, computed off-thread; (b) `_commit()`'s source
##                  contains no `SurfaceTool`/`generate_normals` call at all (static, grep-asserted — the fix
##                  removed the whole-mesh CPU pass, not just made it cheaper); (c) ONE `step()` + `_commit()`
##                  call folds AT MOST `ORBIT_RELIEF_COMMIT_TILES` newly-built tiles into the live mesh, even
##                  when the ENTIRE 384-tile want-set is ready at once (falsifier: mark all resident ⇒ still
##                  ≤ORBIT_RELIEF_COMMIT_TILES newly added this commit, not all 384).
##
## RUN (needs FACETED + FP_GLOBAL_RELIEF_DATA sed-toggled true for the ON-path gates, per the design's
## dependency on G2):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbit_relief.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FOR_ := preload("res://src/world/facet_orbit_relief.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-4

func _initialize() -> void:
	print("=== verify_orbit_relief (task #99 G3 — FP_ORBIT_RELIEF) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	_gate_off()
	if CubeSphere.FP_ORBIT_RELIEF and CubeSphere.FP_GLOBAL_RELIEF_DATA:
		_gate_data_eq()
		_gate_bytes()
		_gate_weld()
		_gate_pace()
		_gate_commit_cost()
	else:
		_ok(true, "G-OR-DATA-EQ/BYTES/WELD/PACE/COMMIT-COST: skipped this run (needs FP_ORBIT_RELIEF + FP_GLOBAL_RELIEF_DATA both sed-toggled true)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-OR-OFF: self-describing, run only when FP_ORBIT_RELIEF is off this run ----------------------------------------
func _gate_off() -> void:
	if CubeSphere.FP_ORBIT_RELIEF:
		_ok(true, "G-OR-OFF: skipped this run (flag currently ON — the ON-path gates below cover behaviour)")
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	var ring := FacetFarRing.new()
	ring._active_fid = 12
	ring.set_relief_data(rd)
	_ok(ring._orbit_relief == null, "G-OR-OFF: set_relief_data never constructs FacetOrbitRelief with the flag off")
	ring.free()

# --- G-OR-DATA-EQ: build_tile's stored heights == the GlobalReliefData oracle, falsifiable ----------------------------
func _gate_data_eq() -> void:
	var fid := 12   # real terrain, the same facet the STAGE-1/FIRES gates already use
	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-OR-DATA-EQ: GlobalReliefData.setup() allocates (FP_GLOBAL_RELIEF_DATA on)")
	_ok(rd.bake_facet(fid), "G-OR-DATA-EQ: bake_facet(fid) succeeds")

	var heights := rd.height_grid(fid)
	_ok(heights.size() == GlobalReliefData.NODES_PER_FACET, "G-OR-DATA-EQ: height_grid returns the full %d-node snapshot" % GlobalReliefData.NODES_PER_FACET)

	var tile := FOR_.build_tile(fid, heights, PackedColorArray(), 0)
	_ok(not tile.is_empty(), "G-OR-DATA-EQ: build_tile succeeds on a baked facet")
	var g: PackedInt32Array = tile["g"]
	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var worst := 0
	for j in range(stride):
		for i in range(stride):
			var want := rd.height_at(fid, i, j)
			var got := g[j * stride + i]
			worst = maxi(worst, absi(got - want))
	_ok(worst == 0, "G-OR-DATA-EQ: every one of %d nodes' stored height == GlobalReliefData.height_at exactly (worst Δ=%d)" % [heights.size(), worst])

	# Falsification: perturb ONE entry of a COPY before building, and confirm THAT node's stored height now
	# diverges from the (unperturbed) oracle — proving this gate actually reads through build_tile, not just
	# echoing back whatever it was fed.
	var bad := heights.duplicate()
	bad[100] += 77
	var bad_tile := FOR_.build_tile(fid, bad, PackedColorArray(), 0)
	var bad_g: PackedInt32Array = bad_tile["g"]
	_ok(bad_g[100] != rd.height_at(fid, 100 % stride, int(100 / stride)),
		"G-OR-DATA-EQ: a perturbed heights[100] DIVERGES from the true oracle at that node (gate is falsifiable)")

	# A refusal contract: wrong-size / empty heights never returns a non-empty tile.
	_ok(FOR_.build_tile(fid, PackedInt32Array(), PackedColorArray(), 0).is_empty(),
		"G-OR-DATA-EQ: build_tile refuses (returns {}) on an empty/malformed heights snapshot")

# --- G-OR-BYTES: real tile_bytes arithmetic + the hard want_set cap, even under an all-planet burst -------------------
func _gate_bytes() -> void:
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var heights := rd.height_grid(fid)
	var tile := FOR_.build_tile(fid, heights, PackedColorArray(), 0)
	var tb := FOR_.tile_bytes(tile)
	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	var want_bytes := nv * (12 + 12 + 16) + ni * 4
	_ok(tb == want_bytes, "G-OR-BYTES: tile_bytes matches the real per-component arithmetic (%d verts, %d indices) exactly" % [nv, ni])
	_ok(nv >= stride * stride, "G-OR-BYTES: vertex count accounts for at least the core %d-node grid (skirt adds more)" % (stride * stride))

	# The pathological burst: EVERY facet on the planet is a candidate (a huge reach, huge theta_h) — want_set
	# must still truncate to the hard cap.
	var n := FA.facet_count()
	var all_fids := PackedInt32Array(); all_fids.resize(n)
	for i in range(n):
		all_fids[i] = i
	var order := FOR_.want_set(fid, Vector3(0, 0, 1), PI, 0, CubeSphere.ORBIT_RELIEF_MAX_TILES, all_fids, PI)
	_ok(order.size() <= CubeSphere.ORBIT_RELIEF_MAX_TILES, "G-OR-BYTES: want_set NEVER exceeds ORBIT_RELIEF_MAX_TILES(%d) even when all %d facets are candidates (got %d)" % [CubeSphere.ORBIT_RELIEF_MAX_TILES, n, order.size()])
	_ok(order.size() == CubeSphere.ORBIT_RELIEF_MAX_TILES, "G-OR-BYTES: the all-planet burst actually SATURATES the cap (proves this isn't a vacuous pass)")

	var cap_bytes := CubeSphere.ORBIT_RELIEF_MAX_TILES * tb
	var cap_mb := float(cap_bytes) / (1024.0 * 1024.0)
	_ok(cap_mb <= 32.0, "G-OR-BYTES: ORBIT_RELIEF_MAX_TILES × real tile_bytes stays under the 32 MB safety ceiling (got %.2f MB)" % cap_mb)

# --- G-OR-WELD: shared-edge positions coincide + the boundary-only no-protrusion sink ---------------------------------
func _gate_weld() -> void:
	var fid_a := 12
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	_ok(fid_b >= 0, "G-OR-WELD: facet %d has a real EAST neighbour" % fid_a)
	if fid_b < 0:
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid_a)
	rd.bake_facet(fid_b)
	var tile_a := FOR_.build_tile(fid_a, rd.height_grid(fid_a), PackedColorArray(), 0)
	var tile_b := FOR_.build_tile(fid_b, rd.height_grid(fid_b), PackedColorArray(), 0)
	var pos_a: PackedVector3Array = tile_a["pos"]
	var pos_b: PackedVector3Array = tile_b["pos"]
	var cells := FOR_.ORBIT_RELIEF_CELLS
	var stride := cells + 1
	# fid_a's EAST edge (i=cells) vs fid_b's WEST edge (i=0) — as SETS (order/direction-of-travel across the
	# shared cube edge may differ between the two facets' own (a,b) parametrizations; a set comparison sidesteps
	# that without assuming a specific index correspondence, while still being a genuine coincidence proof).
	var edge_a: Array = []
	for j in range(stride):
		edge_a.append(pos_a[j * stride + cells])
	var edge_b: Array = []
	for j in range(stride):
		edge_b.append(pos_b[j * stride + 0])
	var scale := float(FacetAtlas.R_BLOCKS)
	var matched := 0
	for pa in edge_a:
		var best := INF
		for pb in edge_b:
			best = minf(best, (pa as Vector3).distance_to(pb as Vector3))
		if best <= EPS * scale:
			matched += 1
	_ok(matched == edge_a.size(), "G-OR-WELD: every one of fid %d's EAST-edge nodes has a coincident node on fid %d's WEST edge (%d/%d matched, ≤%.4f blocks)" % [fid_a, fid_b, matched, edge_a.size(), EPS * scale])

	# No-protrusion: sink ONLY the WEST edge (bit for EDGE_WEST) and compare against the unsunk tile.
	var mask := 1 << FacetSmoothV2.EDGE_WEST
	var tile_sunk := FOR_.build_tile(fid_a, rd.height_grid(fid_a), PackedColorArray(), mask)
	var pos_sunk: PackedVector3Array = tile_sunk["pos"]
	var sink := TierPlace.backstop_sink()
	var boundary_ok := true
	var interior_ok := true
	for j in range(stride):
		for i in range(stride):
			var k := j * stride + i
			var d_raw := (pos_a[k] as Vector3).length()
			var d_sunk := (pos_sunk[k] as Vector3).length()
			if i == 0:
				if absf((d_raw - d_sunk) - sink) > EPS * scale:
					boundary_ok = false
			else:
				if pos_a[k].distance_to(pos_sunk[k]) > EPS * scale:
					interior_ok = false
	_ok(boundary_ok, "G-OR-WELD: the flagged WEST-edge (i=0) nodes are sunk by EXACTLY TierPlace.backstop_sink() (%.2f blocks)" % sink)
	_ok(interior_ok, "G-OR-WELD: every non-flagged node (i>0) is untouched by the sink — scoped, not tier-wide")

# --- G-OR-PACE: pathological all-planet burst ⇒ dispatch bounded by free slots; commit rate-cap is falsifiable --------
func _gate_pace() -> void:
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)

	var n := FA.facet_count()
	var burst := {}
	var order: Array = []
	for i in range(n):
		burst[i] = true
		order.append(i)
	relief._want = burst
	relief._want_order = order
	relief.step()
	var dispatched := 0
	for i in range(relief._sn):
		if int(relief._s_fid[i]) >= 0:
			dispatched += 1
	_ok(dispatched >= 1, "G-OR-PACE: the all-%d-facet burst dispatches at least one build" % n)
	_ok(dispatched <= relief._sn, "G-OR-PACE: ONE step() call dispatches AT MOST RELIEF_BUILD_SLOTS(%d) builds, never all %d (dispatched %d)" % [relief._sn, n, dispatched])
	_ok(dispatched == relief._sn, "G-OR-PACE: the burst actually SATURATES every free slot (proves this isn't a vacuous pass)")

	# Cleanup: never let a RefCounted go out of scope while a worker task still references it.
	for i in range(relief._sn):
		if int(relief._s_task[i]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(relief._s_task[i]))
	ring.free()

	# The commit rate-cap, tested as a PURE function (mirrors GlobalReliefData's own pacer gate pattern) —
	# deterministic, no real wall-clock waiting needed.
	_ok(FOR_.should_commit(true, 1000, 0, 500), "G-OR-PACE: should_commit fires on the FIRST call (0 -> 1000ms, well past the 500ms cap)")
	_ok(not FOR_.should_commit(true, 1100, 1000, 500), "G-OR-PACE: an IMMEDIATE second commit-worthy event (1000->1100ms, only 100ms later) is BLOCKED by the rate-cap")
	_ok(FOR_.should_commit(true, 1600, 1000, 500), "G-OR-PACE: a commit-worthy event AFTER the window (1000->1600ms, 600ms later) is allowed")
	_ok(not FOR_.should_commit(false, 5000, 0, 500), "G-OR-PACE: should_commit never fires when nothing is dirty, regardless of elapsed time")

# --- G-OR-COMMIT-COST: the PERF FIX — real off-thread normals, no SurfaceTool in _commit(), batch-capped upload ------
func _gate_commit_cost() -> void:
	var fid := 12   # real terrain, the same facet every other gate above already uses
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var heights := rd.height_grid(fid)
	var tile := FOR_.build_tile(fid, heights, PackedColorArray(), 0)
	var nrm: PackedVector3Array = tile["nrm"]
	var pos: PackedVector3Array = tile["pos"]
	var any_off_radial := false
	for k in range(nrm.size()):
		if nrm[k].distance_to(pos[k].normalized()) > EPS:
			any_off_radial = true
			break
	_ok(any_off_radial, "G-OR-COMMIT-COST: build_tile's normals are REAL analytic slope normals, not the degenerate pure-radial placeholder (computed off-thread)")

	# Static source check: _commit()'s body — NOT the whole file (the class/flag doc comments legitimately mention
	# SurfaceTool/generate_normals when describing what was REMOVED) — contains no SurfaceTool/generate_normals call.
	var f := FileAccess.open("res://src/world/facet_orbit_relief.gd", FileAccess.READ)
	_ok(f != null, "G-OR-COMMIT-COST: opened facet_orbit_relief.gd for the static source check")
	if f != null:
		var text := f.get_as_text()
		var start := text.find("func _commit()")
		_ok(start >= 0, "G-OR-COMMIT-COST: found _commit()'s definition")
		if start >= 0:
			var next_func := text.find("\nfunc ", start + 1)
			var body := text.substr(start, (next_func - start) if next_func >= 0 else -1)
			_ok(body.find("SurfaceTool") == -1, "G-OR-COMMIT-COST: _commit()'s body never references SurfaceTool")
			_ok(body.find("generate_normals") == -1, "G-OR-COMMIT-COST: _commit()'s body never calls generate_normals")
			_ok(body.find("add_surface_from_arrays") != -1, "G-OR-COMMIT-COST: _commit() still commits via the SAFE high-level add_surface_from_arrays API")

	# The batch cap: mark the WHOLE 384-tile want-set as already BUILT (bypassing real dispatch — this gate only
	# needs to prove the COMMIT-time batching, not re-prove dispatch pacing, already covered by G-OR-PACE) and
	# confirm ONE _commit() call folds at most ORBIT_RELIEF_COMMIT_TILES of them into the live mesh.
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)
	var n := CubeSphere.ORBIT_RELIEF_MAX_TILES
	for i in range(n):
		relief._tiles[i] = tile   # any valid tile dict works — this gate is about COUNT, not per-fid content
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.size() <= CubeSphere.ORBIT_RELIEF_COMMIT_TILES,
		"G-OR-COMMIT-COST: ONE _commit() call folds at most ORBIT_RELIEF_COMMIT_TILES(%d) of the %d-tile burst into the live mesh (got %d)" % [CubeSphere.ORBIT_RELIEF_COMMIT_TILES, n, relief._committed_tiles.size()])
	_ok(relief._committed_tiles.size() == CubeSphere.ORBIT_RELIEF_COMMIT_TILES,
		"G-OR-COMMIT-COST: the burst actually SATURATES the batch cap (proves this isn't a vacuous pass)")
	_ok(relief._commit_dirty, "G-OR-COMMIT-COST: still dirty after one capped commit — the rest of the burst is NOT silently dropped")
	# Drain the remaining batches (mirrors real steady-state operation) and confirm full convergence.
	var iterations := 0
	while relief._commit_dirty and iterations < n:
		relief._commit()
		iterations += 1
	_ok(not relief._commit_dirty and relief._committed_tiles.size() == n,
		"G-OR-COMMIT-COST: repeated capped commits eventually converge to the full %d-tile resident set (took %d more commits)" % [n, iterations])
	ring.free()
