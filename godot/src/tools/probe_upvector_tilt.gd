extends SceneTree
## Diagnostic probe (task #91 root-cause): post-de-orbit up-vector tilt.
## Hypothesis under test: the player's up is ALWAYS the ACTIVE facet's up (ActiveFrame = T_active),
## so a persistent horizon cant requires a STATIONARY state where the active facet is NOT the facet
## whose mesh renders the soil under the feet. Hunt the real atlas for such equilibria:
##   TILT_H — no crossing trigger (all own_dist > -HYST) yet the feet's soil cell is junction-MASKED
##            for the active facet (a neighbour renders it);
##   TILT_C — crossing triggers but containment fails AND the corner-commit resolver defers ({}).
## For each, measure the up-vector divergence angle(active up, true-owner up).
## Run: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##      --script res://src/tools/probe_upvector_tilt.gd

const HYST := 0.1
const SLACK := 2.0

func _init() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	# ---- P1: dihedral (up-vector step) magnitude between adjacent facets ----
	var fids := [1356, 348, 0, 300, 1000, 2000, 3000, 3455]
	print("[P1] facet-step up-vector angles (deg):")
	for fid: int in fids:
		var up_a: Vector3 = FacetAtlas.facet_transform(fid).basis.y
		var line := "  fid %d:" % fid
		for slot in range(4):
			var nb: int = FacetAtlas.seam_neighbour(fid, slot)
			if nb < 0:
				continue
			var up_b: Vector3 = FacetAtlas.facet_transform(nb).basis.y
			line += " s%d->%d: %.3f" % [slot, nb, rad_to_deg(up_a.angle_to(up_b))]
		print(line)
	# seam-plane y-coefficient stats (the lean lever: live FP_DATUM_BAKE lift <=6.9 shifts own_dist by B*lift)
	var bmax := 0.0
	var bsum := 0.0
	var nseam := 0
	var nf: int = 6 * FacetAtlas.K * FacetAtlas.K
	for f in range(nf):
		var p: PackedFloat64Array = FacetAtlas.seam_planes_f64(f)
		for slot in range(4):
			var babs: float = absf(p[slot * 4 + 1])
			bmax = maxf(bmax, babs)
			bsum += babs
			nseam += 1
	print("[P1] seam-plane |B| (y-coeff): mean %.4f max %.4f  -> own_dist shift at lift 6.9: mean %.3f max %.3f"
		% [bsum / nseam, bmax, 6.9 * bsum / nseam, 6.9 * bmax])

	# ---- P2: stationary-equilibrium scan along every ridge of sample facets ----
	var tot := {"SELF": 0, "COMMIT": 0, "CORNER_COMMIT": 0, "TILT_H": 0, "TILT_C": 0, "DEFER_OK": 0}
	var examples := []
	for fid: int in fids:
		TerrainConfig.set_active_facet(fid)
		var corners := []
		for ci in range(4):
			var wc: Array = FacetAtlas.facet_planar_corner(fid, ci)
			corners.append(FacetAtlas.world_to_lattice64(fid, wc[0], wc[1], wc[2]))
		var cnt := {"SELF": 0, "COMMIT": 0, "CORNER_COMMIT": 0, "TILT_H": 0, "TILT_C": 0, "DEFER_OK": 0}
		for e in range(4):
			var c0: Array = corners[e]
			var c1: Array = corners[(e + 1) % 4]
			for ti in range(0, 41):
				var t := 0.005 + 0.99 * float(ti) / 40.0
				var px := lerpf(c0[0], c1[0], t)
				var pz := lerpf(c0[2], c1[2], t)
				# nearest ridge plane at this station (own_dist ~ 0 on the ridge polyline)
				for dtarget in [-0.02, -0.05, -0.08, -0.15, -0.3, -0.5, -0.8, -1.2, -1.8]:
					var q := _place_at_own(fid, px, pz, dtarget)
					if q.is_empty():
						continue
					var cls := _classify(fid, q["x"], q["y"], q["z"])
					cnt[cls["state"]] += 1
					if (cls["state"] == "TILT_H" or cls["state"] == "TILT_C") and examples.size() < 12:
						examples.append("  %s fid %d edge %d t %.2f d %.2f cell(%d,%d,%d) own_min %.3f owner %d tilt %.3f deg"
							% [cls["state"], fid, e, t, dtarget, q["xi"], int(q["gy"]), q["zi"],
							cls["own_min"], cls["owner"], cls["tilt_deg"]])
		print("[P2] fid %d: %s" % [fid, str(cnt)])
		for k in tot:
			tot[k] += cnt[k]
	print("[P2] TOTAL over %d facets: %s" % [fids.size(), str(tot)])
	for ex in examples:
		print(ex)
	# ---- P3: at TILT_H points, prove the OWNER's mask renders the soil (complementarity) and the
	# two facet surfaces agree in height there (the player stands at the correct altitude either way).
	print("[P3] owner-side soil + surface agreement at TILT_H points (fid 1356):")
	var fid3 := 1356
	TerrainConfig.set_active_facet(fid3)
	var corners3 := []
	for ci in range(4):
		var wc: Array = FacetAtlas.facet_planar_corner(fid3, ci)
		corners3.append(FacetAtlas.world_to_lattice64(fid3, wc[0], wc[1], wc[2]))
	var shown := 0
	for e in range(4):
		if shown >= 6:
			break
		var c0: Array = corners3[e]
		var c1: Array = corners3[(e + 1) % 4]
		for ti in range(0, 41):
			if shown >= 6:
				break
			var t := 0.005 + 0.99 * float(ti) / 40.0
			var px := lerpf(c0[0], c1[0], t)
			var pz := lerpf(c0[2], c1[2], t)
			for dtarget in [-0.02, -0.05, -0.08]:
				var q := _place_at_own(fid3, px, pz, dtarget)
				if q.is_empty():
					continue
				var cls := _classify(fid3, q["x"], q["y"], q["z"])
				if cls["state"] != "TILT_H":
					continue
				var owner: int = cls["owner"]
				var g_a: int = int(q["gy"])
				# reframe the soil-cell centre into the owner's lattice; check the owner's mask + surface
				var cc: Array = FacetAtlas.reframe_position64(fid3, owner,
					float(q["xi"]) + 0.5, float(g_a) + 0.5, float(q["zi"]) + 0.5)
				var oxi := int(floor(cc[0]))
				var ozi := int(floor(cc[2]))
				var oyi := int(floor(cc[1]))
				TerrainConfig.set_active_facet(owner)
				var g_b := int(TerrainConfig.column_profile(oxi, ozi).x)
				var owner_air: bool = FacetAtlas.cell_seam_state(owner, oxi, oyi, ozi)["air"]
				TerrainConfig.set_active_facet(fid3)
				print("  fid %d cell(%d,%d,%d) owner %d: owner_cell(%d,%d,%d) masked=%s  g_active=%d g_owner=%d dy=%d"
					% [fid3, q["xi"], g_a, q["zi"], owner, oxi, oyi, ozi, str(owner_air), g_a, g_b, g_b - g_a])
				shown += 1
				break
	quit(0)

## Place a probe point near (px, pz) with min-slot own_dist == dtarget, feet at surface+1.
## Returns {} if no plane gradient (degenerate) or the point escapes the sampled ridge.
func _place_at_own(fid: int, px: float, pz: float, dtarget: float) -> Dictionary:
	var y := 64.0
	var x := px
	var z := pz
	for _it in range(3):
		# find the slot with the minimum own_dist at (x,y,z) and move along ITS horizontal gradient
		var pl: PackedFloat64Array = FacetAtlas.seam_planes_f64(fid)
		var best_slot := -1
		var best := INF
		for slot in range(4):
			var s: float = FacetAtlas.own_dist(fid, slot, x, y, z)
			if s < best:
				best = s
				best_slot = slot
		var A := pl[best_slot * 4 + 0]
		var C := pl[best_slot * 4 + 2]
		var gh := sqrt(A * A + C * C)
		if gh < 1e-9:
			return {}
		# step along the inward gradient so own_dist(best_slot) becomes dtarget
		x += (dtarget - best) * A / (gh * gh)
		z += (dtarget - best) * C / (gh * gh)
		var xi := int(floor(x))
		var zi := int(floor(z))
		var g: float = float(int(TerrainConfig.column_profile(xi, zi).x))
		y = g + 1.0
	var xi2 := int(floor(x))
	var zi2 := int(floor(z))
	var g2 := float(int(TerrainConfig.column_profile(xi2, zi2).x))
	return {"x": x, "y": g2 + 1.0, "z": z, "xi": xi2, "zi": zi2, "gy": g2}

## Replicate the shipped maybe_cross_facet decision (post-cooldown, FP_CROSS_CORNER_COMMIT on) at a
## STATIONARY point, then check whether the active facet's junction mask renders the soil cell.
func _classify(fid: int, x: float, y: float, z: float) -> Dictionary:
	var own_min := INF
	var trig := []
	for slot in range(4):
		var s: float = FacetAtlas.own_dist(fid, slot, x, y, z)
		own_min = minf(own_min, s)
		if s < -HYST:
			trig.append(slot)
	var xi := int(floor(x))
	var zi := int(floor(z))
	var gy := int(y - 1.0)
	var soil_masked: bool = FacetAtlas.cell_seam_state(fid, xi, gy, zi)["air"]
	var w := FacetAtlas.lattice_to_world64(fid, x, y, z)
	var owner: int = FacetAtlas.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
	var tilt := rad_to_deg(FacetAtlas.facet_transform(fid).basis.y.angle_to(
		FacetAtlas.facet_transform(owner).basis.y)) if owner >= 0 else -1.0
	if trig.is_empty():
		if soil_masked:
			return {"state": "TILT_H", "own_min": own_min, "owner": owner, "tilt_deg": tilt}
		return {"state": "SELF", "own_min": own_min, "owner": owner, "tilt_deg": 0.0}
	# shipped slot loop: first triggering slot, containment on the destination
	for slot in trig:
		var to: int = FacetAtlas.seam_neighbour(fid, slot)
		var np: Array = FacetAtlas.reframe_position64(fid, to, x, y, z)
		var contained := true
		for bslot in range(4):
			if FacetAtlas.own_dist(to, bslot, np[0], np[1], np[2]) < -HYST:
				contained = false
				break
		if contained:
			return {"state": "COMMIT", "own_min": own_min, "owner": owner, "tilt_deg": 0.0}
	# corner-commit resolver (FP_CROSS_CORNER_COMMIT live): candidates = crossed neighbours + facet_of_dir
	var cands := {}
	for slot in trig:
		cands[FacetAtlas.seam_neighbour(fid, slot)] = true
	if owner >= 0 and owner != fid:
		cands[owner] = true
	var best_score := -INF
	for c in cands:
		var cnp: Array = FacetAtlas.reframe_position64(fid, c, x, y, z)
		var mind := INF
		for bslot in range(4):
			mind = minf(mind, FacetAtlas.own_dist(c, bslot, cnp[0], cnp[1], cnp[2]))
		best_score = maxf(best_score, mind)
	if best_score < -(HYST + SLACK):
		# resolver defers forever at a stationary point
		if soil_masked:
			return {"state": "TILT_C", "own_min": own_min, "owner": owner, "tilt_deg": tilt}
		return {"state": "DEFER_OK", "own_min": own_min, "owner": owner, "tilt_deg": 0.0}
	return {"state": "CORNER_COMMIT", "own_min": own_min, "owner": owner, "tilt_deg": 0.0}
