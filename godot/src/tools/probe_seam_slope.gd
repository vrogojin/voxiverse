extends SceneTree
## probe_seam_slope v2 — MEASUREMENT probe for task #112 (fall-through at a facet BORDER on a slope).
## READ-ONLY investigation tool. Compares the ANALYTIC FLOOR (which — per #111's proven per-facet
## render==floor parity — equals each facet's rendered surface, junction band included) ACROSS the
## two frames that meet at a seam:
##
##   M1 — at stations on the shared ridge line of facet 578's slope seams: floor radius computed in
##        frame A vs frame B at the same physical point. dR = r_A − r_B is the physical step between
##        the two facets' surfaces at the seam (what the eye sees as a cliff/crack and what the body
##        feels as a pothole/hover at the crossing instant).
##
##   M2 — a world-space walk transect across the seam, active facet following the game's crossing
##        law (commit at own_dist < −0.1). Per step: r_active (the collision floor the player gets)
##        vs r_owner (the SOIL-OWNER frame's floor = the surface the owner facet's mesh SHOWS
##        there). gap = r_owner − r_active > 0 ⇒ collision floor BELOW the visible ground (sink /
##        fall-through depth); < 0 ⇒ invisible shelf (hover). Also logs the floor jump at the
##        crossing commit.
##
## RUN (flags: FACETED + RADIAL_DATUM + DATUM_BAKE + COL_MEMO + GUARD + WELD; FLOOR_BOUNDED/MEMO off
## to keep the scan exact):  see sed line in the task doc; then
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/probe_seam_slope.gd

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

const PIN_FID := 578

var _w: WorldManager

## Floor of frame F at world point wp (Array [x,y,z]); returns {r: world radius of the floor point,
## y: floor play-y in F lattice, fires, srun, junc, col}. Leaves the active facet on F.
func _frame_floor(F: int, wp: Array) -> Dictionary:
	TC.set_active_facet(F)
	_w._floor_top = {}
	var l: Array = FA.world_to_lattice64(F, wp[0], wp[1], wp[2])
	var fy: float = _w.floor_under(l[0], l[2], l[1] + 1.0)
	var xi := floori(l[0])
	var zi := floori(l[2])
	var ctx = TC.GenCtx.new(0, F)
	var srun: int = TC.slope_run_of(xi, zi, ctx)
	var S: int = FA.datum_shift(F, xi, zi)
	var g: int = TC.column_top(xi, zi, ctx)
	var v0 := CellCodec.pack(1, 0, 0, 0)
	var junc: bool = FA.junction_modify(F, Vector3i(xi, int(floor(fy - 0.01)), zi), v0) != v0
	var p: Array = FA.lattice_to_world64(F, l[0], fy, l[2])
	# The PLAIN (uncarved) surface radius: g + S + 1 + lift at this column — the One-Surface-Law
	# quantity. If plain radii agree across the seam while floor radii don't, the step is
	# carve/junction-specific, not a datum-weld violation.
	var lift: float = FA.datum_lift(F, l[0], l[2])
	var pp: Array = FA.lattice_to_world64(F, l[0], float(g + S + 1) + lift, l[2])
	# Carve targets decode (whole corner heights) for the report.
	var tw := Vector4i.ZERO
	if TC.slope_run_fires(srun):
		var rng: Vector2i = TC.slope_run_range(srun, g)
		tw = Vector4i(rng.x, rng.x, rng.x, rng.x) + CellCodec.slope_deltas(TC.slope_run_modifier_at(srun, g, rng.x))
	return {"r": sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]), "y": fy, "g": g, "S": S,
		"r_plain": sqrt(pp[0] * pp[0] + pp[1] * pp[1] + pp[2] * pp[2]), "tw": tw, "lift": lift,
		"fires": TC.slope_run_fires(srun), "srun": srun, "junc": junc, "col": Vector2i(xi, zi)}

func _initialize() -> void:
	print("=== probe_seam_slope v2 (task #112) ===")
	print("  flags: FACETED=%s RADIAL_DATUM=%s DATUM_BAKE=%s COL_MEMO=%s GUARD=%s WELD=%s BOUNDED=%s MEMO=%s" % [
		CubeSphere.FACETED, CubeSphere.FP_RADIAL_DATUM, CubeSphere.FP_DATUM_BAKE,
		CubeSphere.FP_ANALYTIC_COL_MEMO, CubeSphere.FP_QUERY_FRAME_GUARD, CubeSphere.FP_FLOOR_SURFACE_WELD,
		CubeSphere.FP_FLOOR_BOUNDED, CubeSphere.FP_FLOOR_MEMO])
	if not CubeSphere.FACETED:
		print("  ABORT: FACETED off"); quit(1); return
	TC.warm_up(); FA.warm_up()
	TC.set_active_facet(PIN_FID)
	_w = WorldManager.new(); _w.name = "ProbeWM"; get_root().add_child(_w)

	# ---- stations: A-side near-ridge slope columns per seam slot --------------------------------
	var pl: PackedFloat64Array = FA.seam_planes_f64(PIN_FID)
	var stations := []
	for slot in 4:
		var B: int = FA.seam_neighbour(PIN_FID, slot)
		if B < 0:
			continue
		var A2 := pl[slot * 4 + 0]; var B2 := pl[slot * 4 + 1]; var C2 := pl[slot * 4 + 2]; var D2 := pl[slot * 4 + 3]
		var gl := sqrt(A2 * A2 + B2 * B2 + C2 * C2)
		var lo_d: Vector2i = FA.dom_min(PIN_FID)
		var hi_d: Vector2i = FA.dom_max(PIN_FID)
		var found := 0
		var cx := lo_d.x
		while cx <= hi_d.x and found < 4:
			var cz := lo_d.y
			while cz <= hi_d.y and found < 4:
				var ctx0 = TC.GenCtx.new(0, PIN_FID)
				var g0: int = TC.column_top(cx, cz, ctx0)
				var yq := float(g0 + FA.datum_shift(PIN_FID, cx, cz))
				var od := (A2 * (float(cx) + 0.5) + B2 * yq + C2 * (float(cz) + 0.5) + D2) / gl
				if od > 0.0 and od <= 1.5 and TC.slope_run_fires(TC.slope_run_of(cx, cz, ctx0)):
					var gxz := Vector2(A2, C2)
					if gxz.length() > 1e-9:
						# ridge point: move od down the (x,z) gradient of own_dist
						var k := od * gl / gxz.length_squared()
						stations.append({"slot": slot, "B": B,
							"lx": float(cx) + 0.5 - A2 * k, "lz": float(cz) + 0.5 - C2 * k,
							"col": Vector2i(cx, cz), "y": yq})
						found += 1
				cz += 4
			cx += 4
	if stations.is_empty():
		print("  NO slope seam stations on fid %d" % PIN_FID); quit(1); return
	print("  %d stations" % stations.size())

	# ---- M1: seam step (floor-vs-floor at the ridge point) --------------------------------------
	print("\n-- M1 seam surface step at the ridge (r_A - r_B, blocks) --")
	var worst := 0.0
	var flips := 0
	for st in stations:
		TC.set_active_facet(PIN_FID)
		var wp: Array = FA.lattice_to_world64(PIN_FID, st["lx"], float(st["y"]) + 2.0, st["lz"])
		var fa: Dictionary = _frame_floor(PIN_FID, wp)
		var fb: Dictionary = _frame_floor(st["B"], wp)
		TC.set_active_facet(PIN_FID)
		var dd: float = float(fa["r"]) - float(fb["r"])
		worst = maxf(worst, absf(dd))
		if bool(fa["fires"]) != bool(fb["fires"]):
			flips += 1
		print("  slot %d col%s | A: y=%.2f g=%d S=%d lift=%.2f tw=%s fires=%s junc=%s | B(%d): y=%.2f g=%d S=%d lift=%.2f tw=%s fires=%s junc=%s | dR=%+.3f dR_plain=%+.3f" % [
			st["slot"], str(st["col"]), fa["y"], fa["g"], fa["S"], fa["lift"], str(fa["tw"]), fa["fires"], fa["junc"],
			st["B"], fb["y"], fb["g"], fb["S"], fb["lift"], str(fb["tw"]), fb["fires"], fb["junc"],
			dd, float(fa["r_plain"]) - float(fb["r_plain"])])
	print("  M1: max|dR|=%.3f blocks, fires-flips=%d/%d" % [worst, flips, stations.size()])

	# ---- M2: world-space walk transects ---------------------------------------------------------
	print("\n-- M2 walk transect (gap = r_owner - r_active; >0 = collision floor BELOW visible ground) --")
	for st in stations:
		_transect(st)
	quit(0)

func _transect(st: Dictionary) -> void:
	var slot: int = st["slot"]
	var pl: PackedFloat64Array = FA.seam_planes_f64(PIN_FID)
	var A2 := pl[slot * 4 + 0]; var C2 := pl[slot * 4 + 2]
	var gxz := Vector2(A2, C2).normalized()
	TC.set_active_facet(PIN_FID)
	var active := PIN_FID
	# start 3 blocks inside A of the ridge point, standing on the A floor
	var lx: float = st["lx"] + gxz.x * 3.0
	var lz: float = st["lz"] + gxz.y * 3.0
	var wp0: Array = FA.lattice_to_world64(active, lx, float(st["y"]) + 2.0, lz)
	var f0: Dictionary = _frame_floor(active, wp0)
	var feet: float = float(f0["y"]) + 0.05
	var worst_gap := -1e9
	var worst_at := ""
	var cross_jump := 0.0
	var prev_r := float(f0["r"])
	var crossed := false
	print("  -- transect slot %d col%s (A=%d B=%d) --" % [slot, str(st["col"]), PIN_FID, st["B"]])
	for i in 40:
		lx -= gxz.x * 0.2
		lz -= gxz.y * 0.2
		# game crossing law in the ACTIVE frame
		var plc: PackedFloat64Array = FA.seam_planes_f64(active)
		var od := 1e9
		var od_slot := -1
		for s in 4:
			var a := plc[s * 4]; var b := plc[s * 4 + 1]; var c := plc[s * 4 + 2]; var d := plc[s * 4 + 3]
			var v := (a * lx + b * feet + c * lz + d) / sqrt(a * a + b * b + c * c)
			if v < od:
				od = v
				od_slot = s
		if od < -0.1 and not crossed:
			var to: int = FA.seam_neighbour(active, od_slot)
			if to >= 0:
				var np: Array = FA.reframe_position64(active, to, lx, feet, lz)
				# transect direction re-expressed: rotate gxz via the two frames' world step
				var wa: Array = FA.lattice_to_world64(active, lx - gxz.x, feet, lz - gxz.y)
				active = to
				TC.set_active_facet(active)
				lx = np[0]; feet = np[1]; lz = np[2]
				var la: Array = FA.world_to_lattice64(active, wa[0], wa[1], wa[2])
				gxz = Vector2(float(la[0]) - lx, float(la[2]) - lz).normalized() * -1.0
				crossed = true
		# the physical sample point (feet in the active frame)
		TC.set_active_facet(active)
		var wp: Array = FA.lattice_to_world64(active, lx, feet, lz)
		var f_act: Dictionary = _frame_floor(active, wp)
		var dl := sqrt(wp[0] * wp[0] + wp[1] * wp[1] + wp[2] * wp[2])
		var owner: int = FA.facet_of_dir(CubeSphere.DVec3.new(wp[0] / dl, wp[1] / dl, wp[2] / dl))
		var f_own: Dictionary = f_act
		if owner != active and owner >= 0:
			f_own = _frame_floor(owner, wp)
		TC.set_active_facet(active)
		var gap := float(f_own["r"]) - float(f_act["r"])
		var jump := float(f_act["r"]) - prev_r
		prev_r = float(f_act["r"])
		if crossed and absf(jump) > absf(cross_jump) and i > 0:
			cross_jump = jump if absf(jump) > 0.6 else cross_jump
		if gap > worst_gap:
			worst_gap = gap
			worst_at = "i=%d od=%.2f active=%d owner=%d fires=%s/%s junc=%s/%s" % [
				i, od, active, owner, f_act["fires"], f_own["fires"], f_act["junc"], f_own["junc"]]
		print("    i=%02d od=%+.2f act=%d own=%d rAct=%.2f rOwn=%.2f gap=%+.2f stepJump=%+.2f fires=%s/%s junc=%s/%s" % [
			i, od, active, owner, f_act["r"], f_own["r"], gap, jump,
			f_act["fires"], f_own["fires"], f_act["junc"], f_own["junc"]])
		feet = float(f_act["y"]) + 0.05
	print("  transect worst sink gap: %+.2f (%s); biggest post-cross floor jump %+.2f" % [worst_gap, worst_at, cross_jump])
	TC.set_active_facet(PIN_FID)
