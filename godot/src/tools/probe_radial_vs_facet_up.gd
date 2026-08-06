extends SceneTree
## Probe (task #91, live-signal adjudication): angle between the player's up (ACTIVE facet normal —
## piecewise CONSTANT) and the true RADIAL up (what the far-ring limb / sky / ocean horizon is level
## to — CONTINUOUS), sampled across a facet. Predicts the "tilt changes at every border, frequently
## a bit off" pattern: cant grows linearly toward the ridge, sign-flips by the full facet step at a
## crossing while the radial horizon stays continuous.
## Run: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##      --script res://src/tools/probe_radial_vs_facet_up.gd

func _init() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	for fid in [1356, 348, 1000]:
		var up_f: Vector3 = FacetAtlas.facet_transform(fid).basis.y
		var corners := []
		for ci in range(4):
			var wc: Array = FacetAtlas.facet_planar_corner(fid, ci)
			corners.append(FacetAtlas.world_to_lattice64(fid, wc[0], wc[1], wc[2]))
		# centre + walk from centre to the midpoint of edge 0 and to corner 0
		var cx := 0.0; var cz := 0.0
		for c in corners:
			cx += float(c[0]) / 4.0; cz += float(c[2]) / 4.0
		var m0x: float = (float(corners[0][0]) + float(corners[1][0])) / 2.0
		var m0z: float = (float(corners[0][2]) + float(corners[1][2])) / 2.0
		var line := "  fid %d cant(deg) centre->edge-mid: " % fid
		for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var x := lerpf(cx, m0x, t); var z := lerpf(cz, m0z, t)
			var w := FacetAtlas.lattice_to_world64(fid, x, 64.0, z)
			var rad := Vector3(w[0], w[1], w[2]).normalized()
			line += "%.3f " % rad_to_deg(up_f.angle_to(rad))
		line += " | centre->corner: "
		for t in [0.5, 1.0]:
			var x2 := lerpf(cx, float(corners[0][0]), t); var z2 := lerpf(cz, float(corners[0][2]), t)
			var w2 := FacetAtlas.lattice_to_world64(fid, x2, 64.0, z2)
			var rad2 := Vector3(w2[0], w2[1], w2[2]).normalized()
			line += "%.3f " % rad_to_deg(up_f.angle_to(rad2))
		print(line)
		# the crossing jump seen against the continuous radial horizon at the edge midpoint
		var nb: int = FacetAtlas.seam_neighbour(fid, 0)
		if nb >= 0:
			var up_n: Vector3 = FacetAtlas.facet_transform(nb).basis.y
			var wm := FacetAtlas.lattice_to_world64(fid, m0x, 64.0, m0z)
			var radm := Vector3(wm[0], wm[1], wm[2]).normalized()
			print("    at edge-mid: cant before cross %.3f -> after cross %.3f (jump = facet step %.3f)"
				% [rad_to_deg(up_f.angle_to(radm)), rad_to_deg(up_n.angle_to(radm)),
				rad_to_deg(up_f.angle_to(up_n))])
	quit(0)
