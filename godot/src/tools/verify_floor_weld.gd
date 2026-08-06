extends SceneTree
## COSMOS FALL-THROUGH FIX gate (FP_QUERY_FRAME_GUARD + FP_FLOOR_SURFACE_WELD, task #90,
## docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md §3). FLAT byte-off (both flags default false) is covered by
## verify_feature.gd (must stay 6042/0) — this gate focuses on the LIVE mechanism, reproduced headlessly for the
## first time (§1.2's whole point: the bug needs a mutable cross-frame state no PURE gate at a consistent
## (facet, position) can see, so this gate deliberately DRIVES that inconsistency by hand):
##   G-REPRO / G-GUARD  — the cross-frame aliasing bug is real (a raw query re-read under a facet that was flipped
##                         WITHOUT reframing aliases a different physical column), and FP_QUERY_FRAME_GUARD's
##                         `pos_fid` reframe restores the true column's answer.
##   G-WELD-NORMAL      — FP_FLOOR_SURFACE_WELD is a no-op (byte-equivalent landing) on ordinary re-fire-band
##                         columns (own_dist ∈ (−0.6, −0.1), the live teleport-band signature) when nothing is wrong.
##   G-WELD-FIRES        — fault-injected: an edit whose `_edit_columns` index entry never landed (the "unknown
##                         entrance" §2.2 backstops — e.g. a partial/aborted crossing pipeline) still gets welded
##                         UP to the surface, never left buried.
##   G-WELD-SHAFT       — a PROPERLY-indexed dug shaft is exempt: the weld never clamps a real, indexed edit.
##   G-WELD-NOFIRE-*     — FablePhys hardening #1 (BLOCKING): the weld's clamp threshold is `surface_y - EPS`, not
##                         a bare `<` — a bare `<` would false-fire on every smoothed slope, snow-filled cell, and
##                         open-water swim (all legitimately sit fractionally below `surface_y` on UN-EDITED
##                         columns). Finds a genuine natural instance of each class and PROVES (from the value
##                         itself, not an A/B rerun of a compile-time const) that the weld's condition cannot have
##                         fired there — bit-identical to flag-off by construction.
##
## RUN (flags ON):
##   sed -i 's/const FACETED := false/const FACETED := true/; \
##           s/const FP_QUERY_FRAME_GUARD := false/const FP_QUERY_FRAME_GUARD := true/; \
##           s/const FP_FLOOR_SURFACE_WELD := false/const FP_FLOOR_SURFACE_WELD := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_floor_weld.gd
##   then REVERT (git checkout godot/src/cosmos/cube_sphere.gd). Exits 0 all-pass / 1 on any failure.
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

# Candidate facet ids to hunt across (6·K² = 3456 total, K=24 — stay in range). spawn_facet() first (the
# canonical "home" facet every other gate anchors on), then a spread so the hunt isn't tied to one facet's
# particular terrain (a flat/oceanless sample would starve the divergence hunt).
const _CANDIDATE_FIDS_EXTRA := [0, 12, 300, 1000, 2000, 3000, 3200, 3400]

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _w: WorldManager

func _initialize() -> void:
	print("=== verify_floor_weld (FP_QUERY_FRAME_GUARD + FP_FLOOR_SURFACE_WELD) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED (+ FP_QUERY_FRAME_GUARD/FP_FLOOR_SURFACE_WELD) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	var home := FA.spawn_facet()
	TC.set_active_facet(home)
	_w = WorldManager.new(); _w.name = "FloorWeldWM"; get_root().add_child(_w)   # _ready() builds the collider
	print("  FP_QUERY_FRAME_GUARD=%s FP_FLOOR_SURFACE_WELD=%s home_fid=%d" % [
		str(CubeSphere.FP_QUERY_FRAME_GUARD), str(CubeSphere.FP_FLOOR_SURFACE_WELD), home])

	_gate_repro_and_guard(home)
	_gate_weld_normal_band(home)
	_gate_weld_fires_on_stale_index(home)
	_gate_weld_dug_shaft(home)
	_gate_weld_no_fire()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Is `b` an EDGE-neighbour of `a` (or a itself)? (mirrors verify_descent_facet_resync's helper)
func _adjacent(a: int, b: int) -> bool:
	if a == b:
		return true
	for slot in 4:
		if FA.seam_neighbour(a, slot) == b:
			return true
	return false

## Hunt for a NEAR-RIDGE column of facet `A` (own_dist to some seam slot inside (0, +6] — solidly interior, but a
## realistic "walked near a seam" spot) whose raw (x,z) numbers, RE-READ under the neighbour B active (the exact
## "committed set_active_facet, pose not yet reframed" aborted-crossing harness pattern, §1.2), alias a genuinely
## different, far-diverged physical column. Returns {} if none found in the sampled facets (atlas/probe changed).
func _find_repro_column() -> Dictionary:
	var fids: Array = [FA.spawn_facet()] + _CANDIDATE_FIDS_EXTRA
	for A: int in fids:
		for slot in range(4):
			var B := FA.seam_neighbour(A, slot)
			if B < 0 or B == A:
				continue
			var pl: PackedFloat64Array = FA.seam_planes_f64(A)
			var pA: float = pl[slot * 4 + 0]
			var pB: float = pl[slot * 4 + 1]
			var pC: float = pl[slot * 4 + 2]
			var pD: float = pl[slot * 4 + 3]
			if absf(pA) < 1e-6:
				continue                                  # ridge line ~parallel to x here — solve a different slot
			var c := FA.centre_cell(A)
			for tstep in range(-15, 16):
				var zz := float(c.y) + float(tstep) * 12.0
				# own(x, 8, zz) = pA·x + pB·8 + pC·zz + pD = 0 at x = xr (exact, own_dist is affine in x with
				# slope pA); +4/pA lands own_dist == +4.0 — solidly inside A, close to the ridge.
				var xr := (-(pB * 8.0 + pC * zz + pD)) / pA
				var x := xr + 4.0 / pA
				TC.set_active_facet(A)
				var floor_a := _w.floor_under(x, zz, 8.0)
				TC.set_active_facet(B)
				var floor_b := _w.floor_under(x, zz, 8.0)
				TC.set_active_facet(A)
				if absf(floor_b - floor_a) > 8.0:
					return {"A": A, "B": B, "slot": slot, "x": x, "z": zz, "floor_a": floor_a, "floor_b": floor_b}
	return {}

## G-REPRO + G-GUARD (§2.1, the ROOT fix).
##
## Ground truth for G-GUARD is a MANUAL reframe (FacetAtlas.reframe_position64 called directly by the gate, then
## an ordinary self-consistent floor_under under active=B) — NOT facet A's own reading. A's generation is only
## authoritative WITHIN A's own domain; away from the exact welded ridge line, adjacent facets' independently-
## generated terrain is not guaranteed to match block-for-block (only the ridge itself is welded — the piecewise-
## flat facet model's whole premise), so comparing the guard against A's reading would conflate "does the guard
## reframe correctly" with "do two facets' terrain models agree a few cells apart" (a separate, out-of-scope
## question). The manual-reframe comparison isolates exactly what FP_QUERY_FRAME_GUARD claims to do: reproduce,
## bit-for-bit, what an already-healed caller (reframed pose, self-consistent facet) would have gotten.
func _gate_repro_and_guard(_home: int) -> void:
	var found := _find_repro_column()
	_ok(not found.is_empty(), "could not find a near-ridge column with a genuine cross-facet floor divergence — atlas/probe changed")
	if found.is_empty():
		return
	var A: int = found["A"]
	var B: int = found["B"]
	var x: float = found["x"]
	var z: float = found["z"]
	var feet_y := 8.0

	TC.set_active_facet(A)
	var true_floor := _w.floor_under(x, z, feet_y)
	var true_surface := _w.surface_y(x, z)
	print("  setup: A=%d B=%d slot=%d col=(%.2f,%.2f) true_floor=%.2f true_surface=%.2f" % [
		A, B, int(found["slot"]), x, z, true_floor, true_surface])
	_ok(absf(true_floor - true_surface) < 1.0,
		"sanity: floor_under/surface_y disagree at a SELF-consistent (A, column) — §1.1's proof / probe/atlas assumption broken")

	# G-REPRO (falsifier — the bug MUST be real): commit set_active_facet(B) WITHOUT reframing the query point (the
	# aborted-crossing harness pattern, G-REENTRY-CONTINUOUS precedent) and re-issue the SAME raw (x,z) — it now
	# aliases B's own, physically unrelated terrain (reproduces the live −12.1/+11.9 class headlessly).
	TC.set_active_facet(B)
	var diverged_floor := _w.floor_under(x, z, feet_y)
	print("  G-REPRO: wrong-phase active=%d raw floor=%.2f (was %.2f under A) Δ=%.2f" % [
		B, diverged_floor, true_floor, diverged_floor - true_floor])
	_ok(absf(diverged_floor - true_floor) > 5.0,
		"bug NOT reproduced: wrong-phase floor_under barely moved (Δ=%.2f) — the desync harness picked a coincidentally-aliased column" % (diverged_floor - true_floor))

	# Ground truth: reframe by hand (the same FacetAtlas call the guard uses internally) and query self-consistently.
	var w64: Array = FA.reframe_position64(A, B, x, feet_y, z)
	var manual_floor := _w.floor_under(w64[0], w64[2], w64[1])

	# G-GUARD (the fix): pass pos_fid=A while active=B — FP_QUERY_FRAME_GUARD reframes the query point ONCE via
	# FacetAtlas.reframe_position64 before scanning, so it must reproduce the manual reframe exactly.
	var guarded_floor := _w.floor_under(x, z, feet_y, A)
	print("  G-GUARD: pos_fid=%d (active=%d) guarded floor=%.2f manual-reframe floor=%.2f" % [A, B, guarded_floor, manual_floor])
	_ok(absf(guarded_floor - manual_floor) < 1e-4,
		"guard did NOT reproduce a manual reframe: guarded=%.4f vs manual=%.4f" % [guarded_floor, manual_floor])

	TC.set_active_facet(A)   # leave state clean for the following gates

## Exact-plane column finder: solves own_dist(A, slot, x, 8, z) == target analytically (own_dist is affine in x
## with slope = the plane's own A-coefficient, so x = xr + target/coeff hits it to float precision) — no scanning.
func _band_column(A: int, target: float) -> Dictionary:
	for slot in range(4):
		var pl: PackedFloat64Array = FA.seam_planes_f64(A)
		var pA: float = pl[slot * 4 + 0]
		var pB: float = pl[slot * 4 + 1]
		var pC: float = pl[slot * 4 + 2]
		var pD: float = pl[slot * 4 + 3]
		if absf(pA) < 1e-6:
			continue
		var c := FA.centre_cell(A)
		var zz := float(c.y) + 6.0
		var xr := (-(pB * 8.0 + pC * zz + pD)) / pA
		var x := xr + target / pA
		var od := FA.own_dist(A, slot, x, 8.0, zz)
		if od > minf(target - 0.05, -0.6) and od < maxf(target + 0.05, -0.1):
			return {"slot": slot, "x": x, "z": zz}
	return {}

## G-WELD-NORMAL (§3.3, literal design text) — over a re-fire-band column (own_dist ∈ (−0.6, −0.1), the exact
## 288-column teleport-band signature §1.2 names), a SELF-consistent scripted descent (single active facet, no
## injected desync) still lands at surface_y ± ε with the weld ON — proves the weld never perturbs ordinary
## landings (it is a no-op whenever floor_under and surface_y already agree, §1.1).
func _gate_weld_normal_band(A: int) -> void:
	TC.set_active_facet(A)
	var found := _band_column(A, -0.3)
	_ok(not found.is_empty(), "could not find a re-fire-band (own_dist ∈ (-0.6,-0.1)) column — atlas/probe changed")
	if found.is_empty():
		return
	var x: float = found["x"]
	var z: float = found["z"]
	var sy := _w.surface_y(x, z)
	var landed := _w.floor_under(x, z, sy + 50.0)   # scripted descent: start well above, fall to the floor
	print("  G-WELD-NORMAL: band column slot=%d (%.2f,%.2f) surface_y=%.2f landed=%.2f" % [int(found["slot"]), x, z, sy, landed])
	_ok(absf(landed - sy) < 0.6,
		"normal descent on a re-fire-band column did not land at the surface with the weld on (landed=%.2f vs %.2f)" % [landed, sy])

## Dig a MID-COLUMN tunnel void at (xi, zi): cells h-3..h-5 removed, h/h-1/h-2 (the topmost, roof) and h-6 (the
## tunnel floor) left intact. `effective_height` walks DOWN past removed cells from the TOP only (world_manager.gd
## effective_height), so leaving the roof untouched keeps `surface_y` at the TRUE, unedited height — exactly the
## "horizontal tunnel through a hillside" signature §2.2 names as the one legitimate below-surface stand (a
## straight-DOWN shaft instead would drag effective_height/surface_y down WITH it at every step, so floor_under and
## surface_y would never actually disagree there — this mid-column construction is the one that genuinely does).
func _dig_tunnel(xi: int, zi: int) -> int:
	var h := _w.effective_height(xi, zi)
	for dy in range(3, 6):
		_w.break_terrain(Vector3i(xi, h - dy, zi))
	return h

## G-WELD-FIRES — fault injection: dig the tunnel via the SHIPPED break_terrain choke point (which marks
## `_edit_columns`), confirm floor_under genuinely sees the tunnel floor (below the untouched surface) with the
## index intact, then ERASE that column's index entry to simulate the exact failure mode §2.2 backstops — an edit
## whose PERF index never landed (a partial/aborted crossing pipeline, §1.2's "long fallible pipeline"; or any
## future actor that mutates the overlay without going through the index). With the index blind to the edit, the
## un-edited-column exemption can't see it — the weld MUST now clamp the SAME query up to the surface.
func _gate_weld_fires_on_stale_index(A: int) -> void:
	TC.set_active_facet(A)
	var c := FA.centre_cell(A)
	var xi := c.x - 5
	var zi := c.y - 5
	var h := _dig_tunnel(xi, zi)
	var col := Vector2i(xi, zi)
	_ok(_w._edit_columns.has(col), "sanity: break_terrain did not index the dug column — API/index changed")
	var sy := _w.surface_y(float(xi) + 0.5, float(zi) + 0.5)
	var feet_y := float(h - 3)                            # feet already inside the tunnel void
	var real_tunnel_floor := _w.floor_under(float(xi) + 0.5, float(zi) + 0.5, feet_y)
	_ok(real_tunnel_floor < sy - 3.0,
		"sanity: pre-fault floor_under does not see the tunnel void (%.2f vs surface %.2f) — dig/scan construction broken" % [real_tunnel_floor, sy])
	_w._edit_columns.erase(col)                          # fault injection: index entry lost
	var welded := _w.floor_under(float(xi) + 0.5, float(zi) + 0.5, feet_y)
	print("  G-WELD-FIRES: fault-injected stale _edit_columns at (%d,%d) surface_y=%.2f pre-fault floor=%.2f post-fault(welded)=%.2f" % [
		xi, zi, sy, real_tunnel_floor, welded])
	_ok(absf(welded - sy) < 0.6,
		"FP_FLOOR_SURFACE_WELD did not clamp the stale-indexed tunnel floor up to the surface (welded=%.2f vs surface=%.2f)" % [welded, sy])

## G-WELD-SHAFT (§3.3, no-false-clamp) — the SAME mid-column tunnel, PROPERLY indexed (the normal break_terrain
## path, index intact): floor_under must return the tunnel's real floor, never clamp it up to the surface.
func _gate_weld_dug_shaft(A: int) -> void:
	TC.set_active_facet(A)
	var c := FA.centre_cell(A)
	var xi := c.x + 5
	var zi := c.y + 5
	var h := _dig_tunnel(xi, zi)
	_ok(_w._edit_columns.has(Vector2i(xi, zi)), "sanity: break_terrain did not index the dug column — API/index changed")
	var sy := _w.surface_y(float(xi) + 0.5, float(zi) + 0.5)
	_ok(absf(sy - float(h + 1)) < 0.6,
		"sanity: surface_y moved after a MID-column dig (%.2f, expected %.2f) — effective_height isn't top-tracking as documented" % [sy, float(h + 1)])
	var shaft_floor := _w.floor_under(float(xi) + 0.5, float(zi) + 0.5, float(h - 3))   # feet already inside the tunnel
	var expected := float(h - 5)                          # cells h-3..h-5 dug ⇒ topmost solid below them is h-6 ⇒ top = h-5
	print("  G-WELD-SHAFT: dug column (%d,%d) surface_y=%.2f floor_under(from inside tunnel)=%.2f (expected≈%.2f)" % [xi, zi, sy, shaft_floor, expected])
	_ok(shaft_floor < sy - 3.0,
		"dug tunnel floor (%.2f) is not meaningfully below the surface (%.2f) — the dig didn't take" % [shaft_floor, sy])
	_ok(absf(shaft_floor - expected) < 0.6,
		"tunnel floor (%.2f) != expected dug bottom (%.2f) — FP_FLOOR_SURFACE_WELD falsely clamped a PROPERLY-indexed edit" % [shaft_floor, expected])

## G-WELD-NOFIRE-* (FablePhys hardening #1, BLOCKING). Hunts a genuine NATURAL (never-written) instance of each
## legitimate-deficit class the epsilon exists for, then proves — from the returned values alone, not an A/B rerun
## of the compile-time flag — that the weld's `found < surface − FLOOR_WELD_EPS` condition cannot have fired: if
## `floor_under()` is within [surface − EPS, surface) of `surface_y()`, the clamp test is false BY CONSTRUCTION, so
## the function took the exact same return path as it would with the flag off — bit-identical there, regardless of
## what any other column does.
func _gate_weld_no_fire() -> void:
	_check_no_fire_column("slope", _find_shaped_column(false), true)
	_check_no_fire_column("snow", _find_snow_column(), false)
	_check_no_fire_column("water", _find_shaped_column(true), true)

## `require_deficit`: SLOPE and WATER (a shaped/smoothed cap) legitimately read BELOW `surface_y` — the case the
## epsilon exists for, so the sanity check demands a genuine deficit was found. SNOW is different: `_occ_span`
## (world_manager.gd) composes a snow fill as `maxf(shape_top, fill/10)` — snow can only RAISE the span, never
## lower it (verified from the actual compositing code, not assumed) — so its no-fire check only needs to confirm
## the weld's condition still can't fire, not that a deficit exists.
func _check_no_fire_column(label: String, found: Dictionary, require_deficit: bool) -> void:
	_ok(not found.is_empty(), "G-WELD-NOFIRE-%s: could not find a natural %s column — atlas/probe changed" % [label.to_upper(), label])
	if found.is_empty():
		return
	var A: int = found["A"]
	var xi: int = found["xi"]
	var zi: int = found["zi"]
	TC.set_active_facet(A)
	var x := float(xi) + 0.5
	var z := float(zi) + 0.5
	var sy := _w.surface_y(x, z)
	var fl := _w.floor_under(x, z, sy + 50.0)          # scripted descent: start well above, fall to the natural floor
	print("  G-WELD-NOFIRE-%s: fid=%d col=(%d,%d) surface_y=%.3f floor_under=%.3f Δ=%.3f" % [
		label.to_upper(), A, xi, zi, sy, fl, sy - fl])
	_ok(not _w._edit_columns.has(Vector2i(xi, zi)), "sanity: %s column is unexpectedly marked edited" % label)
	if require_deficit:
		_ok(fl < sy - 0.001,
			"sanity: no legitimate deficit at the %s column (floor=%.3f == surface=%.3f) — the probe found a flush column, not a genuine shaped/deficit one" % [label, fl, sy])
	_ok(fl >= sy - CubeSphere.FLOOR_WELD_EPS,
		"FLOOR_WELD_EPS (%.1f) is too small for the %s column's deficit (Δ=%.3f) — would false-fire the weld on ordinary terrain" % [CubeSphere.FLOOR_WELD_EPS, label, sy - fl])

## Hunt several facets for a natural (un-edited) SOLID surface cell whose in-cell top at the query footprint
## (0.5, 0.5) is genuinely < 1.0 (ShapeCodec.local_top — the SAME footprint floor_under/surface_y's callers use for
## a column-centre descent): a slope/ramp/slab, SUB-VOXEL-SMOOTHING, or (`underwater=true`) the equivalent
## WATER-SHORE smoothed seafloor cap (a shaped cell whose column sits at/below SEA_LEVEL). Pure reads only
## (cell_value_at/effective_height/col_height) — never writes, so the column stays un-edited.
func _find_shaped_column(underwater: bool) -> Dictionary:
	var fids: Array = [FA.spawn_facet()] + _CANDIDATE_FIDS_EXTRA
	for A: int in fids:
		TC.set_active_facet(A)
		var c := FA.centre_cell(A)
		var reach := 150 if underwater else 80          # water is rarer near an arbitrary centre — search wider
		var step := 3 if underwater else 2
		for dx in range(-reach, reach + 1, step):
			for dz in range(-reach, reach + 1, step):
				var xi := c.x + dx
				var zi := c.y + dz
				if underwater and _w.col_height(xi, zi) > TerrainConfig.SEA_LEVEL:
					continue                          # dry land — not the underwater-cap case
				var h := _w.effective_height(xi, zi)
				var v := _w.cell_value_at(Vector3i(xi, h, zi))
				var m := CellCodec.modifier(v)
				if m == 0 or BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5:
					continue                          # unshaped, or a non-solid (water/lava) top cell itself
				if ShapeCodec.local_top(m, 0.5, 0.5) >= 1.0 - 0.01:
					continue                          # this particular shape happens to be flush at centre — keep hunting
				return {"A": A, "xi": xi, "zi": zi}
	return {}

## Hunt several facets for a natural (un-edited) surface cell with nonzero snow fill (SNOW-ACCUMULATION).
func _find_snow_column() -> Dictionary:
	var fids: Array = [FA.spawn_facet()] + _CANDIDATE_FIDS_EXTRA
	for A: int in fids:
		TC.set_active_facet(A)
		var c := FA.centre_cell(A)
		for dx in range(-80, 81, 2):
			for dz in range(-80, 81, 2):
				var xi := c.x + dx
				var zi := c.y + dz
				var h := _w.effective_height(xi, zi)
				var v := _w.cell_value_at(Vector3i(xi, h, zi))
				if CellCodec.snow_fill(v) != 0:
					return {"A": A, "xi": xi, "zi": zi}
	return {}
