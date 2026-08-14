extends SceneTree
## probe_choplag — CHOP-LAG root-cause harness: measure the PER-FRAME cost across a chopped
## canopy VoxelBody's ENTIRE lifetime. Scenarios:
##   S1 chop a WOOD (oak) tree, quiet world
##   S2 chop a NON-WOOD (birch/spruce) tree, quiet world
##   S3 chop a WOOD tree + background collider dirt every 30 frames (models the snowfall sim's
##      sim_ground_rebuild cadence — one writing step per 0.5 s)
##   S4 chop a WOOD tree, force-freeze it at t=3 s, KEEP the background dirt (gate-closed control)
## Per second prints: gc.update() usec (sum/max), physics step ms (mean/max), frames with a build
## phase active, builds started, dirty frames, body sleeping/freeze/velocities, collision pairs.
## Run with FACETED+FP_M1_POOL+FP_FIXED_FRAME+FP_CLIMATE_BIOMES+FP_TREEPHYS_BOUND (+ the tree-bug
## fix flags for the ON config) sed'd as desired.

var w: WorldManager
var gc: Node
var host: Node
var player_pos: Vector3

func _initialize() -> void:
	print("=== probe_choplag ===")
	print("  FLAGS: GRAV_BOX_COVER=%s CHOP_COLLIDER_CARVE=%s BIOME_SPACE_FIX=%s TREEPHYS_BOUND=%s" % [
		str(CubeSphere.FP_GRAV_BOX_COVER), str(CubeSphere.FP_CHOP_COLLIDER_CARVE),
		str(CubeSphere.FP_BIOME_SPACE_FIX), str(CubeSphere.FP_TREEPHYS_BOUND)])
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	w = WorldManager.new()
	w.name = "ChopLagWM"
	get_root().add_child(w)
	for i in range(5):
		await process_frame
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	host = af if af != null else w
	for ch in host.get_children():
		if ch is GroundCollider:
			gc = ch
	var cc := FacetAtlas.centre_cell(fid)

	# find one WOOD (oak, trunk id 4) and one non-wood tree within 170 of the centre
	var wood_base := Vector3i.ZERO
	var soft_base := Vector3i.ZERO
	var wood_base2 := Vector3i.ZERO
	var wood_base3 := Vector3i.ZERO
	var found_wood := 0
	for gx in range(floori(float(cc.x - 170) / 10.0), floori(float(cc.x + 170) / 10.0)):
		for gz in range(floori(float(cc.y - 170) / 10.0), floori(float(cc.y + 170) / 10.0)):
			var tb := TreeGen.tree_base(gx, gz)
			if tb.y <= TerrainConfig.SEA_LEVEL:
				continue
			if absi(tb.x - cc.x) > 170 or absi(tb.z - cc.y) > 170:
				continue
			var tid := _world_trunk_id(tb)
			if tid == BlockCatalog.WOOD:
				found_wood += 1
				if wood_base == Vector3i.ZERO:
					wood_base = tb
				elif wood_base2 == Vector3i.ZERO and (absi(tb.x - wood_base.x) > 20 or absi(tb.z - wood_base.z) > 20):
					wood_base2 = tb
				elif wood_base3 == Vector3i.ZERO and (absi(tb.x - wood_base2.x) > 20 or absi(tb.z - wood_base2.z) > 20):
					wood_base3 = tb
			elif tid > 0 and soft_base == Vector3i.ZERO:
				soft_base = tb
	print("  wood trees: %s %s %s  soft tree: %s" % [str(wood_base), str(wood_base2), str(wood_base3), str(soft_base)])
	if wood_base == Vector3i.ZERO or soft_base == Vector3i.ZERO or wood_base3 == Vector3i.ZERO:
		print("ABORT: trees not found")
		quit(1)
		return

	await _scenario("S1 WOOD quiet", wood_base, 30, false, -1.0, false, false)
	await _scenario("S5 WOOD full-fell", wood_base2, 60, false, -1.0, true, false)
	await _scenario("S6 WOOD rebuild-wake", wood_base3, 60, true, -1.0, false, true)
	print("=== probe_choplag done ===")
	quit(0)

## The trunk id as the WORLD sees it (block_id_at: datum shift + snow interception + junction), or 0.
func _world_trunk_id(tb: Vector3i) -> int:
	var sy := int(w.surface_y(float(tb.x) + 0.5, float(tb.z) + 0.5))
	for y in range(sy - 4, sy + 12):
		var id := w.block_id_at(Vector3i(tb.x, y, tb.z))
		if id == BlockCatalog.WOOD or id == BlockCatalog.id_of(&"birch_log") or id == BlockCatalog.id_of(&"spruce_log") \
				or id == BlockCatalog.id_of(&"jungle_log") or id == BlockCatalog.id_of(&"acacia_log"):
			return id
	return 0

func _free_bodies() -> void:
	for ch in host.get_children():
		if ch is VoxelBody:
			ch.queue_free()

func _scenario(tag: String, base: Vector3i, seconds: int, dirt: bool, freeze_at: float, fell: bool, wake_test: bool) -> void:
	print("--- %s: tree @ %s" % [tag, str(base)])
	_free_bodies()
	await physics_frame
	await physics_frame
	player_pos = Vector3(float(base.x) + 2.5, w.surface_y(float(base.x) + 2.5, float(base.z) + 0.5), float(base.z) + 0.5)
	# open the gate + let the collider build the region incl. the tree, then go quiet
	var marker: VoxelBody = VoxelBody.spawn_loose(host, {Vector3i(base.x + 4, int(player_pos.y) + 1, base.z): BlockCatalog.STONE}, w)
	for i in range(120):
		if gc != null:
			gc.call("update", player_pos)
		await physics_frame
	marker.queue_free()
	await physics_frame
	# chop: locate the trunk THROUGH THE WORLD (datum-shifted view), then break its two bottom cells
	var ty0 := -0x40000000
	var sy := int(w.surface_y(float(base.x) + 0.5, float(base.z) + 0.5))
	for y in range(sy - 4, sy + 12):
		var id := w.block_id_at(Vector3i(base.x, y, base.z))
		if id == BlockCatalog.WOOD or id == BlockCatalog.id_of(&"birch_log") or id == BlockCatalog.id_of(&"spruce_log") \
				or id == BlockCatalog.id_of(&"jungle_log") or id == BlockCatalog.id_of(&"acacia_log"):
			ty0 = y
			break
	if ty0 == -0x40000000:
		print("  (no trunk found in world view — skipping)")
		return
	var r1 := w.break_terrain(Vector3i(base.x, ty0, base.z), player_pos)
	var r2 := w.break_terrain(Vector3i(base.x, ty0 + 1, base.z), player_pos)
	print("  trunk at y=%d..: broke ids %d, %d" % [ty0, r1, r2])
	await physics_frame
	var body: VoxelBody = null
	for ch in host.get_children():
		if ch is VoxelBody and (body == null or (ch as VoxelBody).block_count() > body.block_count()):
			body = ch
	if body == null:
		print("  (no canopy body — skipping)")
		return
	print("  canopy=%d cells is_wood=%s" % [body.block_count(), str(body._is_wood)])
	var slept_at := -1.0
	var was_awake := true
	var rewakes := 0
	# per-second aggregates
	var gc_us_sum := 0
	var gc_us_max := 0
	var phys_ms_sum := 0.0
	var phys_ms_max := 0.0
	var build_frames := 0
	var builds_started := 0
	var dirty_frames := 0
	var was_idle := true
	for step in range(seconds * 60):
		var t := step / 60.0
		if dirt and step % 30 == 0:
			w.sim_ground_rebuild()          # models one writing snowfall step per 0.5 s
		if fell and step % 120 == 0 and step > 0 and step <= 480:
			# the player keeps felling: break the next remaining trunk/tree cell near the stump
			var by := -1
			for y in range(int(player_pos.y) - 4, int(player_pos.y) + 12):
				if w.block_id_at(Vector3i(base.x, y, base.z)) > 0:
					by = y
					break
			if by >= 0:
				var rid := w.break_terrain(Vector3i(base.x, by, base.z), player_pos)
				print("  [t=%.1f] FELL break y=%d -> id %d (bodies now %d)" % [t, by, rid, w.active_body_count()])
		if wake_test and step == 480:
			print("  [t=%.1f] WAKE-TEST: spawning fresh marker (gate reopens; dirt pending=%s)" % [t, str(bool(gc.get("_dirty")))])
			VoxelBody.spawn_loose(host, {Vector3i(base.x + 6, int(player_pos.y) + 2, base.z): BlockCatalog.STONE}, w)
		if freeze_at > 0.0 and absf(t - freeze_at) < 0.008:
			body.freeze = true
			body.sleeping = true
			print("  [t=%.1f] body force-frozen (gate should close)" % t)
		var t0 := Time.get_ticks_usec()
		if gc != null:
			gc.call("update", player_pos)
		var dgc := int(Time.get_ticks_usec() - t0)
		var wt0 := Time.get_ticks_usec()
		gc_us_sum += dgc
		gc_us_max = maxi(gc_us_max, dgc)
		var idle: bool = (gc == null) or (int(gc.get("_phase")) == 0)
		if not idle:
			build_frames += 1
			if was_idle:
				builds_started += 1
		was_idle = idle
		if gc != null and bool(gc.get("_dirty")):
			dirty_frames += 1
		await physics_frame
		var frame_us := int(Time.get_ticks_usec() - wt0)
		if step < 120 and step % 20 == 0:
			print("    f%03d frame_us=%6d pairs=%d awake=%s v=%.2f" % [step, frame_us,
				int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
				str(body.is_awake() if is_instance_valid(body) else false),
				body.linear_velocity.length() if is_instance_valid(body) else -1.0])
		var pms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		phys_ms_sum += pms
		phys_ms_max = maxf(phys_ms_max, pms)
		var awake_now := is_instance_valid(body) and body.is_awake()
		if slept_at < 0.0 and not awake_now:
			slept_at = t
			print("  [t=%.1f] body DORMANT (sleeping=%s freeze=%s)" % [t, str(body.sleeping), str(body.freeze)])
		if awake_now and not was_awake:
			rewakes += 1
			print("  [t=%.1f] body RE-WOKEN (rewake #%d)" % [t, rewakes])
		was_awake = awake_now
		if step % 60 == 59:
			var awake := is_instance_valid(body) and body.is_awake()
			print("  t=%2ds gc_us sum=%6d max=%5d | build_frames=%2d starts=%d dirty=%2d | phys_ms avg=%.2f max=%.2f | pairs=%d | awake=%s v=%.3f w=%.3f" % [
				int(t) + 1, gc_us_sum, gc_us_max, build_frames, builds_started, dirty_frames,
				phys_ms_sum / 60.0, phys_ms_max, int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
				str(awake), body.linear_velocity.length() if is_instance_valid(body) else -1.0,
				body.angular_velocity.length() if is_instance_valid(body) else -1.0])
			gc_us_sum = 0
			gc_us_max = 0
			phys_ms_sum = 0.0
			phys_ms_max = 0.0
			build_frames = 0
			builds_started = 0
			dirty_frames = 0
	print("  %s SUMMARY: slept_at=%.1fs (%s) rewakes=%d" % [tag, slept_at, "never in window" if slept_at < 0.0 else "ok", rewakes])
