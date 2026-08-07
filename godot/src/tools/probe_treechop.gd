extends SceneTree
## probe_treechop — Bug-2 end-to-end repro: chop a REAL TreeGen tree via WorldManager.break_terrain
## (the live player path: collapse pass, detach kick, stale ground-collider timing) under
## FACETED + FP_M1_POOL + FP_FIXED_FRAME, and track the canopy VoxelBody for 45 s.

func _initialize() -> void:
	print("=== probe_treechop (Bug 2 end-to-end) ===")
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	var w := WorldManager.new()
	w.name = "TreeChopWM"
	get_root().add_child(w)
	for i in range(5):
		await process_frame
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	var host: Node = af if af != null else w
	# find a real tree near the facet centre (above sea, inside the domain)
	var cc := FacetAtlas.centre_cell(fid)
	var lo: Vector2i = FacetAtlas.dom_min(fid)
	var hi: Vector2i = FacetAtlas.dom_max(fid)
	var base := Vector3i.ZERO
	var found := false
	for gx in range(floori(float(lo.x) / 10.0) + 1, floori(float(hi.x) / 10.0)):
		if found:
			break
		for gz in range(floori(float(lo.y) / 10.0) + 1, floori(float(hi.y) / 10.0)):
			var tb := TreeGen.tree_base(gx, gz)
			if tb.y > TerrainConfig.SEA_LEVEL \
					and tb.x - 2 >= lo.x and tb.x + 2 <= hi.x and tb.z - 2 >= lo.y and tb.z + 2 <= hi.y:
				# require an actual trunk cell (species with a real canopy — skip cactus)
				if TreeGen.block_at(tb.x, tb.y + 1, tb.z) > 0 and TreeGen.block_at(tb.x, tb.y + 3, tb.z) > 0:
					base = tb
					found = true
					break
	if not found:
		print("ABORT: no tree found on facet %d" % fid)
		quit(1)
		return
	var trunk_id := TreeGen.block_at(base.x, base.y + 1, base.z)
	print("  fid=%d tree base=%s trunk_id=%d" % [fid, str(base), trunk_id])
	var up_expected: Vector3 = -w.gravity_vector()
	var player_pos := Vector3(float(base.x) + 2.5, w.surface_y(float(base.x) + 2.5, float(base.z) + 0.5), float(base.z) + 0.5)

	# park a tiny debris marker to open the collider gate BEFORE the chop (like a live session where
	# the collider has already served debris) and let the collider build the tree's boxes
	VoxelBody.spawn_loose(host, {Vector3i(base.x + 3, int(player_pos.y) + 1, base.z): BlockCatalog.STONE}, w)
	var gc: Node = null
	for ch in host.get_children():
		if ch is GroundCollider:
			gc = ch
	for i in range(90):
		if gc != null:
			gc.call("update", player_pos)
		await physics_frame

	# CHOP the two bottom trunk cells (the live two-click chop) via the real path
	var r1 := w.break_terrain(Vector3i(base.x, base.y + 1, base.z), player_pos)
	var r2 := w.break_terrain(Vector3i(base.x, base.y + 2, base.z), player_pos)
	print("  chopped trunk cells -> ids %d, %d" % [r1, r2])
	await physics_frame
	# find the biggest (canopy) body
	var body: VoxelBody = null
	for ch in host.get_children():
		if ch is VoxelBody and (body == null or (ch as VoxelBody).block_count() > body.block_count()):
			body = ch
	if body == null or body.block_count() < 3:
		print("ABORT: no canopy body spawned (body=%s)" % (str(body.block_count()) if body != null else "null"))
		quit(1)
		return
	print("  canopy body: %d cells is_wood=%s" % [body.block_count(), str(body._is_wood)])

	for step in range(2701):
		if gc != null:
			gc.call("update", player_pos)
		await physics_frame
		if step % 120 == 0 or step == 2700:
			var st := PhysicsServer3D.body_get_direct_state(body.get_rid())
			var grav: Vector3 = st.total_gravity if st != null else Vector3.INF
			var centre_lat: Vector3 = body.transform * body._cells_center()
			var surf := w.surface_y(centre_lat.x, centre_lat.z)
			var updot: float = body.global_transform.basis.y.dot(up_expected)
			print("  t=%5.1fs lat_c=(%.1f,%.2f,%.1f) surf=%.2f depth=%.2f updot=%.3f gdot=%.3f frozen=%s sleep=%s v=%.3f w=%.3f" % [
				step / 60.0, centre_lat.x, centre_lat.y, centre_lat.z, surf, surf - centre_lat.y, updot,
				(grav.normalized().dot(-up_expected)) if grav.is_finite() and grav.length() > 0.01 else NAN,
				str(body.freeze), str(body.sleeping), body.linear_velocity.length(), body.angular_velocity.length()])
	var centre_end: Vector3 = body.transform * body._cells_center()
	var surf_end := w.surface_y(centre_end.x, centre_end.z)
	var updot_end: float = body.global_transform.basis.y.dot(up_expected)
	print("VERDICT: sunk=%s (centre %.2f vs surf %.2f) flipped=%s (updot %.3f)" % [
		str(centre_end.y < surf_end - 1.5), centre_end.y, surf_end, str(updot_end < 0.5), updot_end])
	quit(0)
