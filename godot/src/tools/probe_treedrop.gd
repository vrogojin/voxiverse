extends SceneTree
## probe_treedrop — Bug-2 adjudicator: drop a chopped-canopy-like VoxelBody over faceted terrain
## (FACETED + FP_M1_POOL + FP_FIXED_FRAME sed'd ON, mirroring live) and record orientation,
## altitude vs surface, and the ACTUAL gravity the physics server applies to it.

func _initialize() -> void:
	print("=== probe_treedrop (Bug 2: canopy flip + sink) ===")
	print("  FACETED=%s FP_FIXED_FRAME=%s FP_M1_POOL=%s module=%s" % [str(CubeSphere.FACETED), str(CubeSphere.FP_FIXED_FRAME), str(CubeSphere.FP_M1_POOL), str(ClassDB.class_exists("VoxelTerrain"))])
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	var w := WorldManager.new()
	w.name = "TreeDropWM"
	get_root().add_child(w)
	for i in range(5):
		await process_frame
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	print("  fid=%d ActiveFrame=%s" % [fid, ("present t=" + str(af.transform.origin.round()) if af != null else "ABSENT")])
	var host: Node = af if af != null else w
	var cc := FacetAtlas.centre_cell(fid)
	var cx := cc.x
	var cz := cc.y
	var sy := w.surface_y(float(cx) + 0.5, float(cz) + 0.5)
	var up_expected: Vector3 = -w.gravity_vector()
	print("  centre=(%d,%d) surface_y=%.2f expected_up=%s" % [cx, cz, sy, str(up_expected)])

	# fake player standing next to the tree → keep the ground collider gate open + centred
	var player_pos := Vector3(float(cx) + 2.5, sy, float(cz) + 0.5)
	var gc: Node = null
	for ch in host.get_children():
		if ch is GroundCollider:
			gc = ch
	print("  GroundCollider=%s" % ("present" if gc != null else "ABSENT"))

	# canopy: 3x3 x2 leaf slab + cap (like a chopped oak canopy), 4 blocks above the surface
	var base_y := int(sy) + 4
	var cells := {}
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for dy in range(0, 2):
				cells[Vector3i(cx + dx, base_y + dy, cz + dz)] = BlockCatalog.LEAF
	cells[Vector3i(cx, base_y + 2, cz)] = BlockCatalog.LEAF
	var body: VoxelBody = VoxelBody.spawn_loose(host, cells, w)
	print("  canopy: %d cells @ lattice y=%d..%d  is_wood=%s angular_damp=%.1f" % [body.block_count(), base_y, base_y + 2, str(body._is_wood), body.angular_damp])

	for step in range(901):
		if gc != null and gc.has_method("update"):
			gc.call("update", player_pos)
		await physics_frame
		if step % 60 == 0 or step == 900:
			var st := PhysicsServer3D.body_get_direct_state(body.get_rid())
			var grav: Vector3 = st.total_gravity if st != null else Vector3.INF
			var centre_lat: Vector3 = body.transform * body._cells_center()
			var surf := w.surface_y(centre_lat.x, centre_lat.z)
			var updot: float = body.global_transform.basis.y.dot(up_expected)
			var gdot: float = (grav.normalized().dot(-up_expected)) if grav.is_finite() and grav.length() > 0.01 else NAN
			print("  t=%5.2fs lat_c=(%.1f,%.2f,%.1f) surf=%.2f depth=%.2f updot=%.3f grav=%s gdot=%.3f frozen=%s sleep=%s v=%.2f w=%.2f" % [
				step / 60.0, centre_lat.x, centre_lat.y, centre_lat.z, surf, surf - centre_lat.y, updot,
				str(grav.snapped(Vector3(0.01, 0.01, 0.01))), gdot, str(body.freeze), str(body.sleeping),
				body.linear_velocity.length(), body.angular_velocity.length()])
	# verdicts
	var centre_end: Vector3 = body.transform * body._cells_center()
	var surf_end := w.surface_y(centre_end.x, centre_end.z)
	var updot_end: float = body.global_transform.basis.y.dot(up_expected)
	print("VERDICT: sunk_below_surface=%s (centre %.2f vs surf %.2f) flipped=%s (updot %.3f)" % [
		str(centre_end.y < surf_end - 1.5), centre_end.y, surf_end, str(updot_end < 0.5), updot_end])
	quit(0)
