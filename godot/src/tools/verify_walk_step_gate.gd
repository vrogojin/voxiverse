extends SceneTree
## COSMOS-GEN-BURST-THROTTLE gate — FP_WALK_STEP_GATE (docs/COSMOS-GEN-BURST-THROTTLE-DESIGN.md §4/§6).
## G-WALK-STEP-GATE. The lever: ground-walk gen-burst throttle = hold the ONE streaming VoxelViewer on a committed
## step ANCHOR and advance it toward the player one 16-voxel data-block quantum along one axis per drain-gated STEP,
## so a walking crossing's C++ box-diff strip serializes instead of flooding one process pass.
##
## This gate drives the ACTUAL ModuleWorld.walk_gate_update / walk_gate_lag / walk_gate_counts logic (the runtime-dead
## lesson: exercise the real method, not a re-implementation). It is module-INDEPENDENT: it constructs a ModuleWorld
## and hands it a plain Node3D as the viewer child of a scripted player holder (the post-attach_viewer topology; _wg_y0
## = 0 with the downward-reach clamp off), then calls walk_gate_update with explicit (speed, backlog) params — the
## codebase's gate-override convention, no flag flip needed (the flag stays const false; the LIVE call-site is gated in
## WorldManager.update_streaming, off ⇒ never called, viewer never written). The gate clock (_wg_last_step_ms) and the
## step counters are driven directly so the drain condition is isolated from the headless wall clock.
##
## RUN (needs the custom editor; --import first on a fresh worktree):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_walk_step_gate.gd
## Exits 0 all-pass / 1 on any failure. FLAT verify_feature.gd must independently stay 6042/0 (this never flips the flag).

const MW := preload("res://src/world/voxel_module/module_world.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _max_axis(v: Vector3) -> float:
	return maxf(absf(v.x), maxf(absf(v.y), absf(v.z)))

# Reset the gate to the unarmed state (as if freshly attached) and put the player at the origin. Drives the private
# vars directly (GDScript has no true privacy — the codebase's gate-override convention).
func _reset(mw: Node3D, player: Node3D) -> void:
	mw.set("_wg_anchor", Vector3.INF)
	mw.set("_wg_last_step_ms", -1)
	mw.set("_wg_steps", 0)
	mw.set("_wg_forced", 0)
	player.global_position = Vector3.ZERO

func _initialize() -> void:
	print("=== verify_walk_step_gate (GEN-BURST-THROTTLE: G-WALK-STEP-GATE a–f) ===")
	var Q := CubeSphere.WALK_STEP_QUANTUM
	var OPEN := CubeSphere.WALK_STEP_OPEN
	var MAXLAG := CubeSphere.WALK_GATE_MAX_LAG
	var SNAP := CubeSphere.WALK_GATE_SNAP_DIST
	var MAXSPD := CubeSphere.WALK_GATE_MAX_SPEED
	print("  flags: FP_WALK_STEP_GATE=%s | QUANTUM=%.0f OPEN=%d MIN_INTERVAL=%.2fs MAX_LAG=%.0f SNAP_DIST=%.0f MAX_SPEED=%.0f"
		% [str(CubeSphere.FP_WALK_STEP_GATE), Q, OPEN, CubeSphere.WALK_STEP_MIN_INTERVAL_S, MAXLAG, SNAP, MAXSPD])

	# The shipped tree MUST default the flag off (byte-off discipline). If someone sed-flipped it on, this gate's OFF
	# identity claim (E3 never calls walk_gate_update) no longer holds — fail loudly.
	_ok(CubeSphere.FP_WALK_STEP_GATE == false, "byte-off: FP_WALK_STEP_GATE defaults false on the shipped tree (E3 dead, viewer never written)")

	# ONE in-tree rig, reused across sub-tests (nodes must be inside the tree for global_position to apply — hence the
	# await below before any driving). Mirrors the post-attach_viewer topology without needing the VoxelViewer class.
	var mw: Node3D = MW.new(); mw.name = "WGRig"; get_root().add_child(mw)
	var player := Node3D.new(); player.name = "WGPlayer"; get_root().add_child(player)
	var viewer := Node3D.new(); player.add_child(viewer); viewer.position = Vector3.ZERO
	mw.set("_viewer", viewer)
	await process_frame                                   # flush the nodes into the tree

	# ---------------------------------------------------------------------------------------------------------------
	# (a) DEFAULT-OFF IDENTITY. With the flag off, WorldManager.update_streaming never calls walk_gate_update, so the
	# viewer stays the plain player child written once by attach_viewer. Model that: across a 64-voxel walk with NO gate
	# call the viewer's global tracks the player exactly (plain child), the anchor stays UNARMED (INF → lag 0), and
	# walk_gate_counts() == (0,0) — no anchor hold, no steps.
	# ---------------------------------------------------------------------------------------------------------------
	_reset(mw, player)
	var off_follows := true
	for i in range(0, 17):
		player.global_position = Vector3(float(i) * 4.0, 0.0, 0.0)   # 0 → 64 voxels
		if not viewer.global_position.is_equal_approx(player.global_position):
			off_follows = false                                      # plain child rides the player (no gate)
	_ok(off_follows, "(a) OFF-identity: with no gate call the viewer global == player global across a 64-voxel walk (plain child follow)")
	_ok((mw.call("walk_gate_counts") as Vector2i) == Vector2i(0, 0), "(a) OFF-identity: walk_gate_counts() == (0,0) — no anchor hold, no admitted steps")
	_ok((mw.call("walk_gate_lag") as Vector3) == Vector3.ZERO, "(a) OFF-identity: walk_gate_lag() == 0 while the anchor is unarmed (INF sentinel)")

	# ---------------------------------------------------------------------------------------------------------------
	# (b) DRAIN-GATE. A step is WITHHELD while backlog ≥ WALK_STEP_OPEN and ADMITTED once it drops. Isolate the drain
	# condition from the wall clock by forcing interval_ok (_wg_last_step_ms = -1) each call, and keep lag < MAX_LAG so
	# the forced path never masks the drain decision.
	# ---------------------------------------------------------------------------------------------------------------
	_reset(mw, player)
	mw.call("walk_gate_update", 5.0, 0)                    # arm: anchor := origin (snap, INF → want)
	var armed_anchor := viewer.global_position
	player.global_position = Vector3(18.0, 0.0, 0.0)       # lag 18: pending (>Q/2=8), NOT forced (<MAX_LAG=24)
	mw.set("_wg_last_step_ms", -1)
	mw.call("walk_gate_update", 5.0, OPEN + 1000)          # backlog saturated ⇒ WITHHELD
	var after_closed: Vector2i = mw.call("walk_gate_counts")
	_ok(after_closed == Vector2i(0, 0) and viewer.global_position.is_equal_approx(armed_anchor),
		"(b) DRAIN-GATE: backlog ≥ OPEN(%d) ⇒ step WITHHELD (counts (0,0), anchor held at origin)" % OPEN)
	mw.set("_wg_last_step_ms", -1)
	mw.call("walk_gate_update", 5.0, 0)                    # backlog drained ⇒ ADMITTED
	var after_open: Vector2i = mw.call("walk_gate_counts")
	var advanced := absf(viewer.global_position.x - armed_anchor.x)
	_ok(after_open == Vector2i(1, 0), "(b) DRAIN-GATE: backlog < OPEN ⇒ exactly one NON-forced step admitted once the queue drains (counts (1,0))")
	_ok(is_equal_approx(advanced, Q), "(b) DRAIN-GATE: the admitted step advanced the anchor by one quantum (%.0f voxels)" % Q)

	# ---------------------------------------------------------------------------------------------------------------
	# (c) ONE-QUANTUM-PER-STEP, ONE AXIS. A diagonal walk that leaves several axes pending advances at most one quantum
	# on exactly one axis per admitted step. Drive small per-tick moves (speed under MAX_SPEED) with backlog 0 and
	# forced interval, and assert per-call anchor advance ≤ QUANTUM and on a single axis.
	# ---------------------------------------------------------------------------------------------------------------
	_reset(mw, player)
	mw.call("walk_gate_update", 5.0, 0)                    # arm at origin
	var single_axis := true
	var quantum_capped := true
	var target := Vector3(40.0, 0.0, 40.0)                 # diagonal; each axis stays < SNAP=48 so it is a walk, not a snap
	var prev_anchor := viewer.global_position
	for i in range(0, 40):
		player.global_position = player.global_position.move_toward(target, 6.0)   # small walking-speed deltas
		mw.set("_wg_last_step_ms", -1)
		mw.call("walk_gate_update", 5.0, 0)
		var step := viewer.global_position - prev_anchor
		var nz := 0
		if absf(step.x) > 1.0e-4: nz += 1
		if absf(step.y) > 1.0e-4: nz += 1
		if absf(step.z) > 1.0e-4: nz += 1
		if nz > 1: single_axis = false
		if _max_axis(step) > Q + 1.0e-4: quantum_capped = false
		prev_anchor = viewer.global_position
	var reached := viewer.global_position.distance_to(target)
	_ok(single_axis, "(c) ONE-AXIS: every admitted step advances the anchor on at most one axis (diagonal split into serialized strips)")
	_ok(quantum_capped, "(c) ONE-QUANTUM: no admitted step advances the anchor more than WALK_STEP_QUANTUM(%.0f) on its axis" % Q)
	_ok(reached < Q, "(c) THROUGHPUT: the anchor still reaches the walk target (residual %.1f < quantum) — latency-shaped, not starved" % reached)

	# ---------------------------------------------------------------------------------------------------------------
	# (d) FORCED-STEP at the lag cap. Under a permanently saturated queue the drain gate never opens, yet the frontier
	# must keep receding: once per-axis lag exceeds WALK_GATE_MAX_LAG a step is FORCED. Drive small per-tick moves with
	# backlog pinned above OPEN and assert steps keep firing as forced AND per-axis lag never exceeds MAX_LAG+QUANTUM.
	# ---------------------------------------------------------------------------------------------------------------
	_reset(mw, player)
	mw.call("walk_gate_update", 5.0, OPEN + 1000)          # arm at origin (snap ignores backlog)
	var worst_lag := 0.0
	for i in range(0, 60):
		player.global_position = player.global_position + Vector3(5.0, 0.0, 0.0)   # steady walk +5/tick along x
		mw.set("_wg_last_step_ms", -1)
		mw.call("walk_gate_update", 5.0, OPEN + 1000)      # queue never drains
		worst_lag = maxf(worst_lag, _max_axis(mw.call("walk_gate_lag")))
	var counts_d: Vector2i = mw.call("walk_gate_counts")
	_ok(counts_d.y > 0 and counts_d.x == counts_d.y, "(d) FORCED-STEP: every step under a saturated queue is a FORCED step (steps=%d forced=%d)" % [counts_d.x, counts_d.y])
	_ok(worst_lag <= MAXLAG + Q + 1.0e-3, "(d) FRONTIER-BOUND: per-axis lag never exceeds MAX_LAG+QUANTUM (%.0f) even with the queue saturated (worst %.1f)" % [MAXLAG + Q, worst_lag])

	# ---------------------------------------------------------------------------------------------------------------
	# (e) SPEED-SNAP (fast motion ungated). A player above WALK_GATE_MAX_SPEED (running-hard / flying / falling) must
	# NOT be gated — the anchor snaps to the player every call so a fast mover is never stranded behind the frontier.
	# ---------------------------------------------------------------------------------------------------------------
	_reset(mw, player)
	mw.call("walk_gate_update", 5.0, 0)                    # arm at origin
	var snap_follows := true
	for i in range(1, 21):
		player.global_position = Vector3(float(i) * 20.0, 0.0, 0.0)   # 20 voxels/call at fly speed
		mw.set("_wg_last_step_ms", -1)
		mw.call("walk_gate_update", 16.0, OPEN + 1000)     # speed 16 > MAX_SPEED 12 ⇒ snap, backlog irrelevant
		if not viewer.global_position.is_equal_approx(player.global_position):
			snap_follows = false
	_ok(snap_follows, "(e) SPEED-SNAP: speed > MAX_SPEED(%.0f) ⇒ viewer snaps to the player every call (fly/fall ungated)" % MAXSPD)
	_ok((mw.call("walk_gate_counts") as Vector2i) == Vector2i(0, 0), "(e) SPEED-SNAP: a snap is not a step (walk_gate_counts stays (0,0) across the fast run)")

	# ---------------------------------------------------------------------------------------------------------------
	# (f) DISCONTINUITY-SNAP (teleport / crossing-flip re-place). A single jump beyond WALK_GATE_SNAP_DIST at walking
	# speed is a relocation, not motion — snap once, no step spam, counters unchanged.
	# ---------------------------------------------------------------------------------------------------------------
	_reset(mw, player)
	mw.call("walk_gate_update", 5.0, 0)                    # arm at origin
	player.global_position = Vector3(100.0, 0.0, 0.0)      # teleport 100 > SNAP 48, walking speed
	mw.set("_wg_last_step_ms", -1)
	mw.call("walk_gate_update", 5.0, 0)
	_ok(viewer.global_position.is_equal_approx(player.global_position),
		"(f) DISCONTINUITY-SNAP: a >SNAP_DIST(%.0f) jump at walk speed snaps the viewer to the player (crossing/flip/teleport re-place)" % SNAP)
	_ok((mw.call("walk_gate_counts") as Vector2i) == Vector2i(0, 0),
		"(f) DISCONTINUITY-SNAP: no step spam — walk_gate_counts stays (0,0) (a snap re-arms, it does not step)")

	mw.queue_free(); player.queue_free()

	# ---------------------------------------------------------------------------------------------------------------
	# (a′) LIVE off-path (best-effort): if the godot_voxel module is present, build a real WorldManager, attach the real
	# VoxelViewer, and drive update_streaming across a walk with the flag OFF — the gate must never be called and the
	# viewer local transform must be bit-unchanged. SKIP (not fail) if the module/path is unavailable.
	# ---------------------------------------------------------------------------------------------------------------
	if ClassDB.class_exists("VoxelTerrain"):
		var w := WorldManager.new(); w.name = "WGLive"; get_root().add_child(w)
		for _rf in range(4):
			await process_frame
		if w.using_module and w._module_world != null and w._module_world.has_method("walk_gate_update"):
			var lp := Node3D.new(); lp.name = "WGLivePlayer"; get_root().add_child(lp)
			lp.global_position = Vector3(0.0, 6.0, 0.0)
			w.on_player_ready(lp)
			var v0 := float(w._module_world.call("viewer_offset_y"))     # attach-time local +Y (NAN if no viewer)
			var live_unwritten := true
			for i in range(0, 24):
				w.update_streaming(Vector3(float(i) * 4.0, 6.0, 0.0))    # a 92-voxel walk on the LIVE per-tick path
				if not is_equal_approx(float(w._module_world.call("viewer_offset_y")), v0):
					live_unwritten = false
			var live_counts: Vector2i = w._module_world.call("walk_gate_counts")
			_ok(live_counts == Vector2i(0, 0), "(a′) LIVE off-path: update_streaming with the flag off NEVER calls walk_gate_update (counts (0,0))")
			_ok(live_unwritten, "(a′) LIVE off-path: the viewer local offset is bit-unchanged across the walk (gate never wrote it — byte-identical)")
			lp.queue_free()
		else:
			print("  SKIP(live): module path not selected (using_module=%s) — the standalone driver above fully pins the gate logic." % str(w.using_module))
		w.queue_free()
	else:
		print("  SKIP(live): godot_voxel module absent (no VoxelTerrain) — the standalone driver above fully pins the gate logic.")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
