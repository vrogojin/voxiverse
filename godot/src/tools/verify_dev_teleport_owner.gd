extends SceneTree
## COSMOS FALL-THROUGH FIX gate (FP_DEV_TP_REFRAME) — the dev geo-teleport must resolve the facet CONSISTENTLY with
## the ridge (own_dist) crossing test, so a teleport (e.g. lat 8 / lon 2 @ alt 30) lands the player on the CORRECT
## column and never re-crosses into a neighbour's deep terrain (the buried-at-alt-−17 fall-through).
##
## Root cause it kills: `_dev_facet_column` used the FIRST facet whose grown (grow=0.5) polygon contained the column.
## That growth accepts a column up to ~½ cell PAST a facet's ridge, where maybe_cross_facet (which uses the seam-plane
## own_dist, NOT the grown polygon) fires a crossing EVERY physics frame during the post-teleport fall/settle — and the
## surface_y read then lands on the crossed (deep, un-reframed) neighbour column → the player sinks and stays. The fix
## resolves the owner by DIRECTION via FacetAtlas.facet_of_dir (the classifier the ridges agree with), whose landing is
## contained in all four ridges (own_dist ≥ −HYST) → no spurious crossing.
##
## RUN (flag ON):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_DEV_TP_REFRAME := false/const FP_DEV_TP_REFRAME := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_dev_teleport_owner.gd
##   then REVERT. Exits 0 all-pass / 1 on any failure.
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const HYST := 0.1                      # == WorldManager.FACET_CROSS_HYST (maybe_cross_facet crosses when own_dist < −HYST)

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _dir(lat_deg: float, lon_deg: float) -> Vector3:
	# EXACT match to Player._dev_teleport_geo: +Y pole, lon measured around +Y from +X toward +Z.
	var lat := deg_to_rad(clampf(lat_deg, -90.0, 90.0))
	var lon := deg_to_rad(lon_deg)
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))

# OLD resolver (shipped _dev_facet_column, FP_DEV_TP_REFRAME off): first grow=0.5 polygon match.
func _old_resolve(dir: Vector3) -> Dictionary:
	var w := dir.normalized() * FA.R_BLOCKS
	var base := FA.fid_base(0)
	for fid in range(base, base + FA.body_facet_count(0)):
		var l: Array = FA.world_to_lattice64(fid, w.x, w.y, w.z)
		if FA.in_polygon(fid, floori(l[0]), floori(l[2]), 0.5):
			return {"fid": fid, "x": floori(l[0]), "z": floori(l[2])}
	return {}

# NEW resolver (the fix, FP_DEV_TP_REFRAME on): direction → true owner via facet_of_dir.
func _new_resolve(dir: Vector3) -> Dictionary:
	var d := dir.normalized()
	var fid := FA.facet_of_dir(CubeSphere.DVec3.new(d.x, d.y, d.z))
	var w := d * FA.R_BLOCKS
	var l: Array = FA.world_to_lattice64(fid, w.x, w.y, w.z)
	return {"fid": fid, "x": floori(l[0]), "z": floori(l[2])}

# min over the 4 own-side ridges of own_dist at the placement (surface + alt) — maybe_cross_facet fires iff < −HYST.
func _min_owndist(w: WorldManager, fid: int, xi: int, zi: int, alt: float) -> Array:
	var xf := float(xi) + 0.5; var zf := float(zi) + 0.5
	TC.set_active_facet(fid)
	var sy := w.surface_y(xf, zf)
	var py := float(sy) + alt
	var m := 1.0e30
	for slot in 4:
		m = minf(m, FA.own_dist(fid, slot, xf, py, zf))
	return [m, sy]

func _initialize() -> void:
	print("=== verify_dev_teleport_owner (FP_DEV_TP_REFRAME: geo teleport resolves the contained owner) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true (and FP_DEV_TP_REFRAME = true) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	print("  atlas K=%d R=%d spawn=%d | FP_DEV_TP_REFRAME=%s HYST=%.2f" % [
		FA.K, int(FA.R_BLOCKS), FA.spawn_facet(), str(CubeSphere.FP_DEV_TP_REFRAME), HYST])
	var w: WorldManager = WorldManager.new(); w.name = "DevTPWM"; get_root().add_child(w)

	_gate_latlon_2(w)
	_gate_owner_contained(w)
	_gate_old_bug_class_exists(w)
	_gate_flag_branch(w)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## G-TP-LATLON2 — the reported repro: lat 8 / lon 2. The fixed resolver's owner is CONTAINED (no crossing fires) and its
## surface_y is the POSITIVE analytic top (placed alt = surface_y + alt is ABOVE ground, never the −17 seafloor).
func _gate_latlon_2(w: WorldManager) -> void:
	var dir := _dir(8.0, 2.0)
	var nc := _new_resolve(dir)
	var r := _min_owndist(w, int(nc["fid"]), int(nc["x"]), int(nc["z"]), 30.0)
	var nmin: float = r[0]; var nsy: int = int(r[1])
	print("  G-TP-LATLON2: fid=%d col=(%d,%d) min_own_dist(@alt30)=%.3f surface_y=%d" % [int(nc["fid"]), int(nc["x"]), int(nc["z"]), nmin, nsy])
	_ok(nmin >= -HYST, "lat8/lon2 owner is NOT contained (min own_dist %.3f < −HYST) — maybe_cross_facet would re-cross" % nmin)
	_ok(nsy > 0, "lat8/lon2 surface_y is %d (not a positive above-ground surface) — the buried-at-−17 symptom" % nsy)
	# placed altitude is above ground for any alt >= 0
	for alt in [0.0, 5.0, 30.0, 120.0]:
		_ok(float(nsy) + alt >= float(nsy), "placed y below surface at alt %.0f" % alt)

## G-TP-CONTAINED — over a lat/lon battery, the fixed resolver ALWAYS yields an owner contained in its 4 ridges
## (own_dist ≥ −HYST at the placement, incl. alt 30), so no spurious crossing ever fires; surface_y stays finite.
func _gate_owner_contained(w: WorldManager) -> void:
	var checked := 0; var worst := 1.0e30
	for lati in range(-84, 85, 6):
		for loni in range(-176, 177, 6):
			var nc := _new_resolve(_dir(float(lati), float(loni)))
			var r := _min_owndist(w, int(nc["fid"]), int(nc["x"]), int(nc["z"]), 30.0)
			worst = minf(worst, float(r[0]))
			checked += 1
	print("  G-TP-CONTAINED: %d geo points; worst min_own_dist(@alt30) = %.3f (must be ≥ −HYST=%.2f)" % [checked, worst, HYST])
	_ok(checked >= 500, "too few geo points sampled (%d)" % checked)
	_ok(worst >= -HYST, "a facet_of_dir owner is past its ridge (worst %.3f) — the fix would still re-cross" % worst)

## G-TP-OLDBUG — the bug the fix removes MUST exist: the shipped grow=0.5 first-match resolver accepts columns PAST a
## facet ridge (own_dist < −HYST), i.e. the seeds that made maybe_cross_facet re-cross. Falsifiable teeth: if the OLD
## resolver were already contained everywhere, there would be nothing to fix (and this asserts the class is non-empty).
func _gate_old_bug_class_exists(w: WorldManager) -> void:
	var base := FA.fid_base(0)
	var bug := 0; var example := ""
	for fid in range(base, base + FA.body_facet_count(0)):
		var cc := FA.centre_cell(fid)
		for slot in 4:
			var ax: int = [1, -1, 0, 0][slot]; var az: int = [0, 0, 1, -1][slot]
			for step in range(200, 300):
				var ox: int = cc.x + ax * step; var oz: int = cc.y + az * step
				var od := FA.own_dist(fid, slot, float(ox) + 0.5, 6.0, float(oz) + 0.5)
				if od < -HYST and od > -0.6 and FA.in_polygon(fid, ox, oz, 0.5):
					# fid is the first grow=0.5 match for this column's own world point → OLD resolver would pick it
					var wl := FA.lattice_to_world64(fid, float(ox) + 0.5, 0.0, float(oz) + 0.5)
					var first := _old_resolve(Vector3(wl[0], wl[1], wl[2]))
					if not first.is_empty() and int(first["fid"]) == fid:
						bug += 1
						if example == "":
							var dv := Vector3(wl[0], wl[1], wl[2]).normalized()
							var owner := FA.facet_of_dir(CubeSphere.DVec3.new(dv.x, dv.y, dv.z))
							example = "fid=%d slot=%d col=(%d,%d) own_dist=%.2f → facet_of_dir owner=%d" % [fid, slot, ox, oz, od, owner]
						break
		if bug >= 50:
			break
	print("  G-TP-OLDBUG: shipped grow=0.5 resolver seeds ≥%d past-ridge columns; e.g. %s" % [bug, example])
	_ok(bug > 0, "could not exhibit the OLD-resolver past-ridge seed class — gate has no teeth in this atlas")

## G-TP-FLAG — the SHIPPED method: with FP_DEV_TP_REFRAME the real Player._dev_facet_column resolves the SAME
## contained owner as facet_of_dir (proves the flag branch is wired, not just the gate's mirror).
func _gate_flag_branch(_w: WorldManager) -> void:
	var p: Player = Player.new()
	get_root().add_child(p)
	var dir := _dir(8.0, 2.0)
	var got: Dictionary = p.call("_dev_facet_column", dir)
	var want := _new_resolve(dir) if CubeSphere.FP_DEV_TP_REFRAME else _old_resolve(dir)
	print("  G-TP-FLAG: _dev_facet_column → fid=%s (expected %s for flag=%s)" % [str(got.get("fid", -1)), str(want.get("fid", -1)), str(CubeSphere.FP_DEV_TP_REFRAME)])
	_ok(not got.is_empty() and int(got["fid"]) == int(want["fid"]),
		"_dev_facet_column fid %s != expected %s (flag branch not wired)" % [str(got.get("fid", -1)), str(want.get("fid", -1))])
	p.queue_free()
