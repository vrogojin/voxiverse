extends SceneTree
## Diagnostic probe (task #90 root-cause): hunt for columns where the floor_under content scan
## (generated_cell + junction_modify + span-at-footprint) disagrees with the surface law
## (facet_profile g), replicating WorldManager.cell_value_at/floor_under for un-edited columns.
## Run: godot --headless --path godot --script res://src/tools/probe_seam_tilt.gd

func _init() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	# --- (1) sign structure of the seam-plane vertical tilt B (own-side y-coefficient) ---
	var neg := 0
	var pos := 0
	var nf: int = 6 * FacetAtlas.K * FacetAtlas.K
	for f in range(nf):
		var p: PackedFloat64Array = FacetAtlas.seam_planes_f64(f)
		for slot in range(4):
			if p[slot * 4 + 1] < 0.0:
				neg += 1
			else:
				pos += 1
	print("[probe] seam B sign: B>0 (domain narrows with depth): %d   B<0 (domain WIDENS with depth): %d" % [pos, neg])
	# --- (2) brute-force fall-through column hunt on a sample of facets, incl. the observed fid 348 ---
	var fids := [348, 300, 0, 12, 299, 1000, 2000, 3000]
	for fid: int in fids:
		TerrainConfig.set_active_facet(fid)
		var pl: PackedFloat64Array = FacetAtlas.seam_planes_f64(fid)
		var c := FacetAtlas.centre_cell(fid)
		var worst := 0
		var worst_info := ""
		var checked := 0
		for slot in range(4):
			var A := pl[slot * 4 + 0]
			var B := pl[slot * 4 + 1]
			var C := pl[slot * 4 + 2]
			var D := pl[slot * 4 + 3]
			var gh := sqrt(A * A + C * C)
			if gh < 1e-9:
				continue
			# walk along the ridge in ~24-block steps; at each station probe columns own_dist in [-3, +0.5]
			for tstep in range(0, 22):
				# param the ridge line at y=6: pick the dominant horizontal axis to solve
				var zz := float(c.y) + float(tstep - 11) * 12.0
				if absf(A) < 1e-6:
					continue
				var xr := (-(B * 6.0 + C * zz + D)) / A
				for k in range(-2, 7):
					var eps := 0.5 * float(k)     # own_dist target: +1.0 .. -3.0
					var xo := xr - signf(A) * eps * (gh / absf(A))
					var xi := int(floor(xo))
					var zi := int(floor(zz))
					var fx := clampf(xo - float(xi), 0.01, 0.99)
					checked += 1
					var g := int(TerrainConfig.column_profile(xi, zi).x)
					# replicate cell_value_at + floor_under tail for the un-edited column at this footprint
					var top := -999
					for y in range(g + 16, g - 90, -1):
						var vf := TerrainConfig.generated_cell(xi, y, zi)
						var v := FacetAtlas.junction_modify(fid, Vector3i(xi, y, zi), vf)
						var sp := _occ(v, fx, 0.5)
						if sp == Vector2.ZERO:
							continue
						var va := FacetAtlas.junction_modify(fid, Vector3i(xi, y + 1, zi),
							TerrainConfig.generated_cell(xi, y + 1, zi))
						if _occ(va, fx, 0.5) == Vector2.ZERO:
							top = y
							break
					if top != -999 and (g - top) > worst:
						worst = g - top
						var od := FacetAtlas.own_dist(fid, slot, xo, 6.0, zz)
						worst_info = "slot=%d cell=(%d,%d) fx=%.2f own=%.2f g=%d floor_top=%d tunnel=%d" % [slot, xi, zi, fx, od, g, top, g - top]
		print("[probe] fid=%d: checked=%d worst tunnel: %s" % [fid, checked, worst_info if worst > 0 else "none (0)"])
	quit(0)

static func _occ(v: int, fx: float, fz: float) -> Vector2:
	if BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5:
		return Vector2.ZERO
	return ShapeCodec.span(CellCodec.modifier(v), fx, fz)
