extends SceneTree
## verify_seam_slope_weld — FP_SEAM_SLOPE_WELD gate (docs/COSMOS-SEAM-SLOPE-WELD-DESIGN.md §4, task #112).
##
## THE BUG (measured by probe_seam_slope.gd): after #111 FP_SLOPE_MANIFEST_HEAL healed the facet-INTERIOR slope
## carve, the player still FALLS THROUGH at a facet BORDER on a slope. Three stacked seam+slope discontinuities
## (design §2): the two facets' junction-banded slope surfaces disagree by 1.5–3 blocks at the shared ridge, so
## the collision floor pops down at the crossing commit (drop 1.7–3.0) and sinks below the neighbour's visible
## slope in the pre-commit hysteresis strip (up to +2.02). FP_FLOOR_SURFACE_WELD (#90) welds only to the ACTIVE
## facet's OWN surface_y — it never consults the NEIGHBOUR frame, so it cannot cover this.
##
## THE FIX: inside the seam band |own_dist| ≤ SEAM_WELD_BAND, `floor_under` (and GroundCollider._emit_column)
## clamp the collision floor UP to the NEIGHBOUR facet's frame-pure junction-aware band surface (a world radius,
## GenCtx(B) — no set_active_facet). max(own, neighbour) is symmetric ⇒ the two facets agree by construction.
##
## GATES (design §4):
##   G-SSW-OFF       — flag OFF ⇒ the weld helper is a pure pass-through EVERYWHERE (band + interior): byte-off.
##   G-SSW-INTERIOR  — the weld NEVER fires off the band: the #111 pin (fid 578, 13038,8155) and a 32-column
##                     interior sweep get `_ssw_weld == base` (interior byte-identical in BOTH flag states).
##   G-SSW-EDIT      — a dug (_edit_columns) column in the band is EXEMPT — never welded up (both states).
##   G-SSW-RIDGE     — flag ON: the weld target max(band_surface_A, band_surface_B) is FRAME-INDEPENDENT (computed
##                     with A active == with B active, within 1e-3) — the `max` symmetry / proof the neighbour
##                     surface is frame-pure (no set_active_facet leakage). This is what makes A and B agree.
##   G-SSW-TRANSECT  — flag ON: a world-space walk transect across the fid-578↔neighbour seam has a CROSSING-COMMIT
##                     welded-floor radius step ≤ STEP_MAX (0.6) — the fall-through-at-the-border drop (weld OFF
##                     this commit step is ~2–3 blocks). The residual quantized junction-ladder steps WITHIN the
##                     band are the design's accepted "sealed walk-over ledge" (gap=0, solid, never a fall-through)
##                     and are reported for transparency, not failed (v2 §3.3 carves them smooth).
##   G-SSW-STRIP     — flag ON: across the whole transect the welded floor radius ≥ the soil-owner frame's band
##                     surface radius − 0.1 (no sink / burial; weld OFF the pre-commit strip sinks up to ~2.0).
##
## LIVE FINGERPRINT PIN (design §1 / task): the served pck is FP_DATUM_BAKE=true, FP_RADIAL_DATUM=FALSE (NOT both),
## FP_FLOOR_SURFACE_WELD=true, FP_QUERY_FRAME_GUARD=true, FP_SLOPE_MANIFEST_HEAL=true. The weld is a parity max()
## ⇒ datum-agnostic; these LIVE_* are the datum fingerprint the gate expects (a warning, not a hard fail, if the
## running flag set differs — the max symmetry still holds).
##
## RUN (faceted + cppgen + datum-bake + slope-heal; toggle FP_SEAM_SLOPE_WELD; NOT FP_RADIAL_DATUM):
##   sed -i 's/const FACETED := false/const FACETED := true/;
##           s/const FP_CPPGEN := false/const FP_CPPGEN := true/;
##           s/const FP_DATUM_BAKE := false/const FP_DATUM_BAKE := true/;
##           s/const FP_QUERY_FRAME_GUARD := false/const FP_QUERY_FRAME_GUARD := true/;
##           s/const FP_FLOOR_SURFACE_WELD := false/const FP_FLOOR_SURFACE_WELD := true/;
##           s/const FP_SLOPE_MANIFEST_HEAL := false/const FP_SLOPE_MANIFEST_HEAL := true/;
##           s/const FP_SEAM_SLOPE_WELD := false/const FP_SEAM_SLOPE_WELD := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_seam_slope_weld.gd
##   git checkout godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure. Run OFF and ON — all pass both.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

const PIN_FID := 578
const PIN_X := 13038          # #111 interior pin column
const PIN_Z := 8155
const STEP_MAX := 0.6         # G-SSW-CONT per-0.2-block welded-floor radius step ceiling
const SINK_TOL := 0.1         # G-SSW-NOSINK allowed deficit below the owner surface

# The datum fingerprint the served pck runs (design §1). Warned-on, not asserted (the weld is datum-agnostic).
const LIVE_DATUM_BAKE := true
const LIVE_RADIAL_DATUM := false

var _w: WorldManager
var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: ", m)
	else:
		_fail += 1
		print("  FAIL: ", m)

func _done(code: int) -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(code)

func _rad(a: Array) -> float:
	return sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])

## The ACTUAL welded collision floor (floor_under now routes through _ssw_weld) at world point `wp`, evaluated in
## frame F. Returns {r: world radius of the floor point, y: floor play-y}. Leaves the active facet on F.
func _floor_r(F: int, wp: Array) -> Dictionary:
	TC.set_active_facet(F)
	_w._floor_top = {}
	var l: Array = FA.world_to_lattice64(F, wp[0], wp[1], wp[2])
	var fy: float = _w.floor_under(l[0], l[2], l[1] + 1.0)
	var p: Array = FA.lattice_to_world64(F, l[0], fy, l[2])
	return {"r": _rad(p), "y": fy, "col": Vector2i(floori(l[0]), floori(l[2]))}

func _initialize() -> void:
	print("=== verify_seam_slope_weld (FP_SEAM_SLOPE_WELD: G-SSW) ===")
	print("  flags: FP_SEAM_SLOPE_WELD=%s FACETED=%s FP_CPPGEN=%s FP_DATUM_BAKE=%s FP_RADIAL_DATUM=%s GUARD=%s SURF_WELD=%s HEAL=%s" % [
		CubeSphere.FP_SEAM_SLOPE_WELD, CubeSphere.FACETED, CubeSphere.FP_CPPGEN, CubeSphere.FP_DATUM_BAKE,
		CubeSphere.FP_RADIAL_DATUM, CubeSphere.FP_QUERY_FRAME_GUARD, CubeSphere.FP_FLOOR_SURFACE_WELD,
		CubeSphere.FP_SLOPE_MANIFEST_HEAL])
	if not CubeSphere.FACETED:
		print("  SKIP: FACETED off — the repro is a faceted mountain-slope seam (fid %d)." % PIN_FID); _done(0); return
	if CubeSphere.FP_DATUM_BAKE != LIVE_DATUM_BAKE or CubeSphere.FP_RADIAL_DATUM != LIVE_RADIAL_DATUM:
		print("  WARN: datum flags differ from the live fingerprint (DATUM_BAKE=%s RADIAL_DATUM=%s expected %s/%s) — the max weld is datum-agnostic, continuing." % [
			CubeSphere.FP_DATUM_BAKE, CubeSphere.FP_RADIAL_DATUM, LIVE_DATUM_BAKE, LIVE_RADIAL_DATUM])
	TC.warm_up(); FA.warm_up()
	if PIN_FID >= FA.total_facet_count():
		print("  SKIP: facet %d absent (facet_count=%d)." % [PIN_FID, FA.total_facet_count()]); _done(0); return
	TC.set_active_facet(PIN_FID)
	_w = WorldManager.new(); _w.name = "SeamWeldGate"; get_root().add_child(_w)

	# ---- G-SSW-INTERIOR — the weld is a NO-OP off the band (#111 untouched) --------------------------------------
	# The #111 pin column is a facet interior — its nearest seam is far, so _ssw_weld must return base unchanged
	# in BOTH flag states (ON = band-gated early return; OFF = flag early return). This is the interior byte-identity.
	TC.set_active_facet(PIN_FID)
	var ctx0 = TC.GenCtx.new(0, PIN_FID)
	var g_pin: int = TC.column_top(PIN_X, PIN_Z, ctx0)
	var base_pin := _w.floor_under(float(PIN_X) + 0.5, float(PIN_Z) + 0.5, float(g_pin) + 4.0)
	var weld_pin := _w._ssw_weld(PIN_X, PIN_Z, float(PIN_X) + 0.5, float(PIN_Z) + 0.5, base_pin)
	_ok(absf(weld_pin - base_pin) < 1e-9, "G-SSW-INTERIOR — #111 pin (%d,%d) floor unchanged by weld (base=%.3f weld=%.3f)" % [PIN_X, PIN_Z, base_pin, weld_pin])

	# 32-column interior sweep (step 5 across the domain, skip near-edge columns): weld == base everywhere.
	var lo_d: Vector2i = FA.dom_min(PIN_FID)
	var hi_d: Vector2i = FA.dom_max(PIN_FID)
	var interior_unchanged := 0
	var interior_total := 0
	var pl_pin: PackedFloat64Array = FA.seam_planes_f64(PIN_FID)
	var sx := lo_d.x + 8
	while sx <= hi_d.x - 8 and interior_total < 32:
		var sz := lo_d.y + 8
		while sz <= hi_d.y - 8 and interior_total < 32:
			# only sample true INTERIOR columns (min |own_dist| > band + margin)
			var b := _min_owndist(pl_pin, float(sx) + 0.5, float(TC.column_top(sx, sz, TC.GenCtx.new(0, PIN_FID)) + 1), float(sz) + 0.5)
			if b > CubeSphere.SEAM_WELD_BAND + 4.0:
				var gg: int = TC.column_top(sx, sz, TC.GenCtx.new(0, PIN_FID))
				var bse := _w.floor_under(float(sx) + 0.5, float(sz) + 0.5, float(gg) + 4.0)
				var wld := _w._ssw_weld(sx, sz, float(sx) + 0.5, float(sz) + 0.5, bse)
				interior_total += 1
				if absf(wld - bse) < 1e-9:
					interior_unchanged += 1
			sz += 40
		sx += 40
	_ok(interior_total > 0 and interior_unchanged == interior_total,
		"G-SSW-INTERIOR — interior sweep unchanged by weld (%d/%d columns)" % [interior_unchanged, interior_total])

	# ---- Locate slope-seam stations (probe_seam_slope's finder) --------------------------------------------------
	var stations := _find_stations()
	print("  %d slope-seam stations on fid %d" % [stations.size(), PIN_FID])
	if stations.is_empty():
		print("  NOTE: no firing slope-seam stations found — G-SSW seam arms skipped (no repro geometry).")

	# ---- G-SSW-EDIT — a dug column in the band is exempt ---------------------------------------------------------
	if not stations.is_empty():
		var st0: Dictionary = stations[0]
		var ecol := Vector2i(int(st0["col"].x), int(st0["col"].y))
		TC.set_active_facet(PIN_FID)
		var ex := float(ecol.x) + 0.5; var ez := float(ecol.y) + 0.5
		var gg: int = TC.column_top(ecol.x, ecol.y, TC.GenCtx.new(0, PIN_FID))
		var base_e := _w.floor_under(ex, ez, float(gg) + 4.0)
		var weld_undug := _w._ssw_weld(ecol.x, ecol.y, ex, ez, base_e)
		var edcols: Dictionary = _w.debug_edit_columns()
		edcols[ecol] = true
		var weld_dug := _w._ssw_weld(ecol.x, ecol.y, ex, ez, base_e)
		edcols.erase(ecol)
		_ok(absf(weld_dug - base_e) < 1e-9,
			"G-SSW-EDIT — dug band column %s exempt (base=%.3f dug-weld=%.3f, undug-weld=%.3f)" % [str(ecol), base_e, weld_dug, weld_undug])

	# ---- Flag-state split ----------------------------------------------------------------------------------------
	if not CubeSphere.FP_SEAM_SLOPE_WELD:
		# OFF arm: the weld is a pure pass-through even at the band stations — byte-off everywhere.
		var off_ok := true
		for st in stations:
			var col: Vector2i = st["col"]
			var cx := float(col.x) + 0.5; var cz := float(col.y) + 0.5
			TC.set_active_facet(PIN_FID)
			var gg: int = TC.column_top(col.x, col.y, TC.GenCtx.new(0, PIN_FID))
			var bse := _w.floor_under(cx, cz, float(gg) + 4.0)
			var wld := _w._ssw_weld(col.x, col.y, cx, cz, bse)
			if absf(wld - bse) >= 1e-9:
				off_ok = false
		_ok(off_ok or stations.is_empty(), "G-SSW-OFF — weld is a pure pass-through at all band stations (byte-off)")
		_w.queue_free(); _done(1 if _fail > 0 else 0); return

	# ON arm: RIDGE / TRANSECT / STRIP on the seam stations.
	_gate_ridge(stations)
	_gate_transect(stations)
	_w.queue_free()
	_done(1 if _fail > 0 else 0)

## Nearest seam-plane |own_dist| (blocks) for a lattice point, normalizing each plane by |n|.
func _min_owndist(pl: PackedFloat64Array, x: float, y: float, z: float) -> float:
	var best := 1e30
	for s in 4:
		var a := pl[s * 4]; var b := pl[s * 4 + 1]; var c := pl[s * 4 + 2]; var d := pl[s * 4 + 3]
		var gl := sqrt(a * a + b * b + c * c)
		if gl <= 1e-12:
			continue
		var v: float = absf(a * x + b * y + c * z + d) / gl
		if v < best:
			best = v
	return best

## probe_seam_slope's station finder — A-side near-ridge firing slope columns per seam slot, moved to the ridge.
func _find_stations() -> Array:
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
						var k := od * gl / gxz.length_squared()
						stations.append({"slot": slot, "B": B,
							"lx": float(cx) + 0.5 - A2 * k, "lz": float(cz) + 0.5 - C2 * k,
							"col": Vector2i(cx, cz), "y": yq})
						found += 1
				cz += 4
			cx += 4
	return stations

## G-SSW-RIDGE — the weld target max(band_surface_A, band_surface_B) is FRAME-INDEPENDENT: computing the neighbour
## surface with A active vs with B active gives the same max (the helper is frame-pure — no set_active_facet). This
## is the "max symmetry" that makes A and B agree across the crossing.
func _gate_ridge(stations: Array) -> void:
	if stations.is_empty():
		return
	var worst := 0.0
	for st in stations:
		var wp: Array = FA.lattice_to_world64(PIN_FID, st["lx"], float(st["y"]) + 2.0, st["lz"])
		TC.set_active_facet(PIN_FID)
		var a_A := _w._facet_band_surface_r(PIN_FID, wp[0], wp[1], wp[2])
		var b_A := _w._facet_band_surface_r(int(st["B"]), wp[0], wp[1], wp[2])
		var max_from_A := maxf(a_A, b_A)
		TC.set_active_facet(int(st["B"]))
		var a_B := _w._facet_band_surface_r(PIN_FID, wp[0], wp[1], wp[2])
		var b_B := _w._facet_band_surface_r(int(st["B"]), wp[0], wp[1], wp[2])
		var max_from_B := maxf(a_B, b_B)
		TC.set_active_facet(PIN_FID)
		worst = maxf(worst, absf(max_from_A - max_from_B))
	_ok(worst <= 1e-3, "G-SSW-RIDGE — weld target max(surf_A,surf_B) frame-independent (max delta=%.6f ≤ 1e-3)" % worst)

## G-SSW-TRANSECT (crossing-commit continuity) + G-SSW-STRIP (no sink) over world-space walk transects.
func _gate_transect(stations: Array) -> void:
	if stations.is_empty():
		return
	var worst_commit := 0.0
	var worst_commit_at := ""
	var worst_ledge := 0.0
	var worst_sink := -1e30
	var worst_sink_at := ""
	for st in stations:
		var res := _transect(st)
		if float(res["commit"]) > worst_commit:
			worst_commit = float(res["commit"]); worst_commit_at = str(res["commit_at"])
		worst_ledge = maxf(worst_ledge, float(res["ledge"]))
		if float(res["sink"]) > worst_sink:
			worst_sink = float(res["sink"]); worst_sink_at = str(res["sink_at"])
	_ok(worst_commit <= STEP_MAX, "G-SSW-TRANSECT — crossing-commit welded-floor step = %.3f ≤ %.2f (%s)" % [worst_commit, STEP_MAX, worst_commit_at])
	print("    (residual within-band quantized ladder step = %.3f — the accepted sealed walk-over ledge, gap=0)" % worst_ledge)
	_ok(worst_sink <= SINK_TOL, "G-SSW-STRIP — max sink below owner surface = %.3f ≤ %.2f (%s)" % [worst_sink, SINK_TOL, worst_sink_at])

## One world-space walk transect across the seam following the game crossing law, sampling the WELDED floor. Returns
## {commit: |welded floor-radius jump| AT the crossing-commit step, ledge: max |jump| at any OTHER (within-band,
## same-frame) step, sink: max (owner surface r − active welded floor r)}.
func _transect(st: Dictionary) -> Dictionary:
	var slot: int = st["slot"]
	var pl: PackedFloat64Array = FA.seam_planes_f64(PIN_FID)
	var A2 := pl[slot * 4 + 0]; var C2 := pl[slot * 4 + 2]
	var gxz := Vector2(A2, C2).normalized()
	TC.set_active_facet(PIN_FID)
	var active := PIN_FID
	var lx: float = st["lx"] + gxz.x * 3.0
	var lz: float = st["lz"] + gxz.y * 3.0
	var wp0: Array = FA.lattice_to_world64(active, lx, float(st["y"]) + 2.0, lz)
	var f0: Dictionary = _floor_r(active, wp0)
	var feet: float = float(f0["y"]) + 0.05
	var prev_r := float(f0["r"])
	var crossed := false
	var commit_step := 0.0
	var commit_at := ""
	var max_ledge := 0.0
	var max_sink := -1e30
	var sink_at := ""
	for i in 40:
		lx -= gxz.x * 0.2
		lz -= gxz.y * 0.2
		var plc: PackedFloat64Array = FA.seam_planes_f64(active)
		var od := 1e9
		var od_slot := -1
		for s in 4:
			var a := plc[s * 4]; var b := plc[s * 4 + 1]; var c := plc[s * 4 + 2]; var d := plc[s * 4 + 3]
			var v := (a * lx + b * feet + c * lz + d) / sqrt(a * a + b * b + c * c)
			if v < od:
				od = v; od_slot = s
		var this_is_commit := false
		if od < -0.1 and not crossed:
			var to: int = FA.seam_neighbour(active, od_slot)
			if to >= 0:
				var np: Array = FA.reframe_position64(active, to, lx, feet, lz)
				var wa: Array = FA.lattice_to_world64(active, lx - gxz.x, feet, lz - gxz.y)
				active = to
				TC.set_active_facet(active)
				lx = np[0]; feet = np[1]; lz = np[2]
				var la: Array = FA.world_to_lattice64(active, wa[0], wa[1], wa[2])
				gxz = Vector2(float(la[0]) - lx, float(la[2]) - lz).normalized() * -1.0
				crossed = true
				this_is_commit = true
		TC.set_active_facet(active)
		var wp: Array = FA.lattice_to_world64(active, lx, feet, lz)
		var f_act: Dictionary = _floor_r(active, wp)
		# owner-frame band surface radius (the SOIL owner's visible slope) for the sink test
		var dl := _rad(wp)
		var owner: int = FA.facet_of_dir(CubeSphere.DVec3.new(wp[0] / dl, wp[1] / dl, wp[2] / dl))
		var r_own_surface: float = _w._facet_band_surface_r(owner, wp[0], wp[1], wp[2]) if owner >= 0 else float(f_act["r"])
		TC.set_active_facet(active)
		var jump: float = absf(float(f_act["r"]) - prev_r)
		if i > 0:
			if this_is_commit:
				if jump > commit_step:
					commit_step = jump; commit_at = "i=%d od=%.2f A→%d" % [i, od, active]
			else:
				max_ledge = maxf(max_ledge, jump)
		var sink: float = r_own_surface - float(f_act["r"])
		if sink > max_sink:
			max_sink = sink; sink_at = "i=%d od=%.2f act=%d owner=%d" % [i, od, active, owner]
		prev_r = float(f_act["r"])
		feet = float(f_act["y"]) + 0.05
	TC.set_active_facet(PIN_FID)
	return {"commit": commit_step, "commit_at": commit_at, "ledge": max_ledge, "sink": max_sink, "sink_at": sink_at}
