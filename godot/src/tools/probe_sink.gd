extends SceneTree
## probe_sink — INTERMITTENT canopy sink hunt. Chop many round-canopy oaks on the SPAWN facet the
## live way: gate CLOSED until the chop opens it (the canopy is the first body), collider follows the
## player. For each tree track the canopy VoxelBody depth-below-surface over 8 s and report SINK vs OK,
## correlating with distance(player→trunk), canopy footprint, and whether the landing columns actually
## carry a GroundCollider box (the physical rest surface — analytic terrain has none).

var w: WorldManager
var gc: Node
var host: Node

func _initialize() -> void:
	print("=== probe_sink ===")
	print("  FLAGS grav_cover=%s carve=%s calm=%s treephys=%s" % [
		str(CubeSphere.FP_GRAV_BOX_COVER), str(CubeSphere.FP_CHOP_COLLIDER_CARVE),
		str(CubeSphere.FP_CHOP_DEBRIS_CALM), str(CubeSphere.FP_TREEPHYS_BOUND)])
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	w = WorldManager.new()
	w.name = "SinkWM"
	get_root().add_child(w)
	for i in range(5):
		await process_frame
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	host = af if af != null else w
	for ch in host.get_children():
		if ch is GroundCollider:
			gc = ch
	var cc := FacetAtlas.centre_cell(fid)
	print("  spawn fid=%d centre=%s" % [fid, str(cc)])

	# collect round-canopy oak/birch trees near the centre (the live "spawn area" case)
	var trees: Array = []
	for gx in range(floori(float(cc.x - 120) / 10.0), floori(float(cc.x + 120) / 10.0)):
		for gz in range(floori(float(cc.y - 120) / 10.0), floori(float(cc.y + 120) / 10.0)):
			var tb := TreeGen.tree_base(gx, gz)
			if tb.y <= TerrainConfig.SEA_LEVEL:
				continue
			if absi(tb.x - cc.x) > 120 or absi(tb.z - cc.y) > 120:
				continue
			var tid := _world_trunk_id(tb)
			if tid == BlockCatalog.WOOD or tid == BlockCatalog.id_of(&"birch_log"):
				trees.append(tb)
			if trees.size() >= 12:
				break
		if trees.size() >= 12:
			break
	print("  %d round-canopy trees found" % trees.size())

	var sinks := 0
	for i in trees.size():
		var res := await _chop(i, trees[i])
		if res:
			sinks += 1
	print("=== probe_sink done: %d/%d SANK ===" % [sinks, trees.size()])
	quit(0)

func _world_trunk_id(tb: Vector3i) -> int:
	var sy := int(w.surface_y(float(tb.x) + 0.5, float(tb.z) + 0.5))
	for y in range(sy - 4, sy + 12):
		var id := w.block_id_at(Vector3i(tb.x, y, tb.z))
		if id == BlockCatalog.WOOD or id == BlockCatalog.id_of(&"birch_log"):
			return id
	return 0

## Is there a GroundCollider box spanning cell (x,y,z)? Ray a short segment down through the cell centre.
func _collider_solid_at(gx: float, gy: float, gz: float) -> bool:
	if not gc.is_inside_tree():
		return false
	var space: PhysicsDirectSpaceState3D = gc.get_world_3d().direct_space_state
	if space == null:
		return false
	var wp: Vector3 = (host as Node3D).global_transform * Vector3(gx, gy + 0.4, gz)
	var wp2: Vector3 = (host as Node3D).global_transform * Vector3(gx, gy - 0.4, gz)
	var q := PhysicsRayQueryParameters3D.create(wp, wp2, 1 << 0)   # terrain layer
	return not space.intersect_ray(q).is_empty()

func _chop(idx: int, base: Vector3i) -> bool:
	for ch in host.get_children():
		if ch is VoxelBody:
			ch.queue_free()
	await physics_frame
	await physics_frame
	var player_pos := Vector3(float(base.x) + 2.5, w.surface_y(float(base.x) + 2.5, float(base.z) + 0.5), float(base.z) + 0.5)
	var dist := maxf(absf(2.5), 0.0)
	# WALK the collider up to the tree with the gate CLOSED (no debris) — exactly like live approach.
	# Use a far start so the gate is closed, then step in; the collider only builds once a body is near,
	# so we simulate the real "arrive + chop" by just settling a couple frames (gate closed => idle).
	for i in range(10):
		if gc != null:
			gc.call("update", player_pos)     # gate closed (no body) => idle, KEEPS old shapes
		await physics_frame
	# find + break the trunk's two bottom cells (world view)
	var ty0 := -0x40000000
	var sy := int(w.surface_y(float(base.x) + 0.5, float(base.z) + 0.5))
	for y in range(sy - 4, sy + 12):
		var id := w.block_id_at(Vector3i(base.x, y, base.z))
		if id == BlockCatalog.WOOD or id == BlockCatalog.id_of(&"birch_log"):
			ty0 = y
			break
	if ty0 == -0x40000000:
		print("  [%d] no trunk @ %s — skip" % [idx, str(base)])
		return false
	print("  [%2d] PRE-CHOP collider _phase=%s _live=%s _live_center=%s _dirty=%s" % [idx,
		str(gc.get("_phase")), str(gc.get("_live")), str(gc.get("_live_center")), str(gc.get("_dirty"))])
	w.break_terrain(Vector3i(base.x, ty0, base.z), player_pos)
	w.break_terrain(Vector3i(base.x, ty0 + 1, base.z), player_pos)
	await physics_frame
	var body: VoxelBody = null
	for ch in host.get_children():
		if ch is VoxelBody and (body == null or (ch as VoxelBody).block_count() > body.block_count()):
			body = ch
	if body == null:
		print("  [%d] no canopy @ %s — skip" % [idx, str(base)])
		return false
	# footprint span of the canopy (columns)
	var minx := 0x7fffffff; var maxx := -0x7fffffff; var minz := 0x7fffffff; var maxz := -0x7fffffff
	for c: Vector3i in body.cells.keys():
		minx = mini(minx, c.x); maxx = maxi(maxx, c.x); minz = mini(minz, c.z); maxz = maxi(maxz, c.z)
	var trunk_dist := maxf(absf(float(base.x) - player_pos.x), absf(float(base.z) - player_pos.z))
	var min_depth := 1e9
	var max_depth := -1e9
	var landed_covered := true
	for step in range(8 * 60):
		if gc != null:
			gc.call("update", player_pos)
		await physics_frame
		if not is_instance_valid(body):
			break
		var cl: Vector3 = body.transform * body._cells_center()
		var surf := w.surface_y(cl.x, cl.z)
		var depth := surf - cl.y
		min_depth = minf(min_depth, depth)
		max_depth = maxf(max_depth, depth)
		if step % 30 == 0 and idx in [2, 3, 7, 8]:
			print("      [%2d] t=%.1f depth=%+.2f awake=%s v=%.2f phase=%s live=%s dirty=%s ec=%s" % [idx, step/60.0, depth,
				str(body.is_awake()), body.linear_velocity.length(), str(gc.get("_phase")), str(gc.get("_live")),
				str(gc.get("_dirty")), str(gc.get("_edit_age")) if gc.get("_dirty") else "-"])
	var cl2: Vector3 = body.transform * body._cells_center() if is_instance_valid(body) else Vector3.ZERO
	var surf2 := w.surface_y(cl2.x, cl2.z) if is_instance_valid(body) else 0.0
	# check collider coverage at each landing footprint column (at surface level)
	var covered_cols := 0
	var total_cols := 0
	if is_instance_valid(body):
		var seen := {}
		for c: Vector3i in body.cells.keys():
			var wc: Vector3 = body.transform * Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)
			var key := Vector2i(int(floor(wc.x)), int(floor(wc.z)))
			if seen.has(key):
				continue
			seen[key] = true
			total_cols += 1
			var s := w.surface_y(float(key.x) + 0.5, float(key.y) + 0.5)
			if _collider_solid_at(float(key.x) + 0.5, s - 0.5, float(key.y) + 0.5):
				covered_cols += 1
	var end_depth := (surf2 - cl2.y) if is_instance_valid(body) else -99.0
	var sank := end_depth > 1.5
	print("  [%2d] base=%s trunk_dist=%.1f canopy=%d fp=(%d..%d,%d..%d) | end_depth=%.2f max_depth=%.2f | collider_cov=%d/%d | %s" % [
		idx, str(base), trunk_dist, body.block_count() if is_instance_valid(body) else -1,
		minx - base.x, maxx - base.x, minz - base.z, maxz - base.z,
		end_depth, max_depth, covered_cols, total_cols, ("SANK <<<<" if sank else "ok")])
	return sank
