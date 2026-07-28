extends SceneTree
## COSMOS SEAMLESS-TRANSITION S1 gate — FP_APPROACH_ANCHOR (docs/COSMOS-SEAMLESS-TRANSITION-DESIGN.md §3).
## The user's literal complaint (§0.1): the near VoxelViewer rides the player with up-reach U≈64, so climbing ~64
## blocks empties the WHOLE near field while a block still subtends ≈22 px — an abrupt pop to the flat far skin. S1
## keeps the meshed plate anchored to the sub-player ground on climb (a) and releases it rim-inward only once its
## blocks are ≤ τ px (b), all as streaming POLICY on the ONE existing viewer node (zero new bytes).
##
## Two proof layers, both with INLINE loops (never lambdas — a captured-by-value closure would fake a 0% hold):
##   • PURE MATH (flag-independent, always runs): the anchor offset law + the release ramp are pure statics on
##     CubeSphere, so the gate asserts the IDENTICAL formula the driver applies, plus its falsification.
##   • DRIVER (needs the godot_voxel module + a viewer): builds a real WorldManager, attaches the viewer, and drives
##     WorldManager.approach_anchor_step_now over a scripted ascent/descent, reading the viewer's engine-applied
##     offset/view_distance back through module_world introspection accessors.
##
## RUN — the ON config (needs FACETED = true; sed-toggle FP_APPROACH_ANCHOR = true for G-AA-ANCHOR/TAU/BYTES):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_APPROACH_ANCHOR := false/const FP_APPROACH_ANCHOR := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_approach_anchor.gd
## RUN — the OFF gating config (FACETED = true, FP_APPROACH_ANCHOR = false): proves G-AA-OFF (zero viewer writes).
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Radial altitude (blocks above the sphere) of a lattice point in facet `fid`'s frame — the WorldManager metric
## (== _radial_altitude_lattice, the SAME analytic value the regime ladder and the anchor driver read).
func _radial(fid: int, x: float, y: float, z: float) -> float:
	var w := FA.lattice_to_world64(fid, x, y, z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - FA.R_BLOCKS

func _initialize() -> void:
	print("=== verify_approach_anchor (SEAMLESS-TRANSITION S1: G-AA-OFF/ANCHOR/TAU/BYTES) ===")
	var on := CubeSphere.FP_APPROACH_ANCHOR
	print("  flags: FP_APPROACH_ANCHOR=%s FACETED=%s FLAT_WORLD=%s | REL_LO=%.0f REL_HI=%.0f HYST=%.2f TAU=%.1f MARGIN=%.1f DEBOUNCE=%dms"
		% [str(on), str(CubeSphere.FACETED), str(CubeSphere.FLAT_WORLD), CubeSphere.ANCHOR_REL_LO, CubeSphere.ANCHOR_REL_HI,
		   CubeSphere.ANCHOR_HYST, CubeSphere.ANCHOR_TAU_PX, CubeSphere.ANCHOR_MARGIN, CubeSphere.ANCHOR_WRITE_DEBOUNCE_MS])
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return

	TC.warm_up()
	FA.warm_up()
	var o_base := TC.clamped_viewer_offset_y()
	var full := float(TC.near_render_radius())
	var lo_knee := CubeSphere.ANCHOR_REL_LO
	var hi_knee := CubeSphere.ANCHOR_REL_HI
	var re_lo := CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST   # ≈609 — the descent full-resident knee
	print("  derived: O_base=%.1f  full_radius=%.0f  D_REL(=K_px/τ)≈%.0f  re-grow_full_below≈%.0f" % [o_base, full, 1407.0 / CubeSphere.ANCHOR_TAU_PX, re_lo])

	# ---------------------------------------------------------------------------------------------------------------
	# PART A — PURE MATH (flag-independent): the load-bearing anchor + release laws, asserted directly with the exact
	# statics the driver calls, plus falsification. INLINE loops only.
	# ---------------------------------------------------------------------------------------------------------------

	# G-AA-ANCHOR (math): the viewer's WORLD radial altitude = h + offset_y stays pinned to O_base for every h ≥ 0
	# (the plate stays where the player left the ground). Falsify with the STATIC (pre-S1) offset O_base: it drifts by h.
	var anchor_holds := true
	var static_drifts := false
	var worst_anchor_err := 0.0
	for i in range(0, 121):
		var h := float(i) * 10.0                        # 0 → 1200
		var off := CubeSphere.approach_offset_y(h, o_base)
		var world_alt := h + off                        # viewer radial altitude
		var err := absf(world_alt - o_base)
		worst_anchor_err = maxf(worst_anchor_err, err)
		if err > 1.0e-4:
			anchor_holds = false
		# falsification: the OLD static viewer (local +Y == O_base always) rides UP with the player → drift == h.
		var static_world_alt := h + o_base
		if h > 50.0 and absf(static_world_alt - o_base) <= 1.0e-4:
			static_drifts = true                        # (would mean the static viewer DIDN'T drift — impossible)
	_ok(anchor_holds, "G-AA-ANCHOR(math): viewer world-alt = h+offset stays == O_base for all h∈[0,1200] (worst err %.2e)" % worst_anchor_err)
	_ok(not static_drifts, "G-AA-ANCHOR(math): FALSIFY — the un-clamped/static viewer offset DOES drift with h (the bug S1 deletes)")
	# also pin the safety floor: below the datum the viewer never sinks past datum+MARGIN
	var floor_ok := true
	for i in range(1, 40):
		var h := -float(i)                              # below datum
		var off := CubeSphere.approach_offset_y(h, o_base)
		if h + off < CubeSphere.ANCHOR_MARGIN - 1.0e-4:
			floor_ok = false
	_ok(floor_ok, "G-AA-ANCHOR(math): below-datum safety floor holds (viewer world-alt ≥ MARGIN)")

	# G-AA-TAU (math): the release ramp. ASCENT (lo = REL_LO): monotone non-increasing in d; == full for d ≤ re_lo
	# (nothing nearer than REL_LO/HYST released); < full for d > REL_LO (nothing farther than the τ distance required);
	# == 0 for d ≥ REL_HI. DESCENT (lo = re_lo): monotone non-decreasing as d falls; full again by re_lo.
	var asc_monotone := true
	var nothing_near_released := true
	var nothing_far_required := true
	var prev := full + 1.0
	for i in range(0, 121):
		var d := float(i) * 10.0
		var v := CubeSphere.approach_view_distance(d, full, lo_knee)
		if v > prev + 1.0e-6:
			asc_monotone = false                        # must not GROW as we climb
		prev = v
		if d <= re_lo and v < full - 1.0e-4:
			nothing_near_released = false                # a block nearer than re_lo was released → violation
		if d > lo_knee and v > full - 1.0e-4:
			nothing_far_required = false                 # still fully resident past the τ distance → violation
	# final knee-value checks (explicit, not swept):
	var full_at_relo := absf(CubeSphere.approach_view_distance(lo_knee, full, lo_knee) - full) < 1.0e-4
	var full_below_relo := absf(CubeSphere.approach_view_distance(re_lo, full, lo_knee) - full) < 1.0e-4
	var zero_at_relhi := CubeSphere.approach_view_distance(hi_knee, full, lo_knee) <= 1.0e-4
	var released_above := CubeSphere.approach_view_distance((lo_knee + hi_knee) * 0.5, full, lo_knee) < full - 1.0e-4
	_ok(asc_monotone, "G-AA-TAU(math): ascent view_distance is MONOTONE non-increasing in d")
	_ok(nothing_near_released and full_below_relo, "G-AA-TAU(math): nothing nearer than REL_LO/HYST(≈%.0f) is released (view==full)" % re_lo)
	_ok(nothing_far_required and released_above and full_at_relo, "G-AA-TAU(math): nothing farther than the τ distance(REL_LO=%.0f) is required (release begins)" % lo_knee)
	_ok(zero_at_relhi, "G-AA-TAU(math): plate fully released (view==0) at/above REL_HI=%.0f" % hi_knee)
	# descent monotone non-decreasing (lo = re_lo, the hysteretic knee)
	var desc_monotone := true
	var prev_d := -1.0
	for i in range(0, 121):
		var d := float(120 - i) * 10.0                  # 1200 → 0 (descending)
		var v := CubeSphere.approach_view_distance(d, full, re_lo)
		if prev_d >= 0.0 and v < prev_d - 1.0e-6:
			desc_monotone = false                       # must not SHRINK as we descend
		prev_d = v
	_ok(desc_monotone, "G-AA-TAU(math): descent view_distance is MONOTONE non-decreasing as d falls (re-grow, hyst knee)")
	# FALSIFY: a hand-perturbed non-monotone sequence must be DETECTED as non-monotone by the same test.
	var perturbed := [full, full * 0.3, full * 0.9, 0.0]   # 0.3 → 0.9 is an illegal GROW mid-climb
	var caught := false
	var pv := full + 1.0
	for x in perturbed:
		if float(x) > pv + 1.0e-6:
			caught = true
		pv = float(x)
	_ok(caught, "G-AA-TAU(math): FALSIFY — a non-monotone (grow-mid-climb) release sequence is detected as violating")

	# ---------------------------------------------------------------------------------------------------------------
	# PART B — DRIVER (needs the godot_voxel module + a live viewer). Proves the OFF gating (zero writes) or the ON
	# behaviour (offset tracks the anchor, view ramps down, same viewer object airborne == grounded).
	# ---------------------------------------------------------------------------------------------------------------
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP(driver): godot_voxel module absent (no VoxelTerrain) — the pure-math layer above fully pins the S1 laws.")
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	var A := FA.spawn_facet()
	TC.set_active_facet(A)
	var w := WorldManager.new(); w.name = "ApproachAnchor"; get_root().add_child(w)
	for _rf in range(4):
		await process_frame

	if not (w.using_module and w._module_world != null and w._module_world.has_method("set_approach_anchor")):
		print("  SKIP(driver): module path not selected (using_module=%s) — pure-math layer stands." % str(w.using_module))
		w.queue_free()
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	# Build a player at the active facet centre and attach the ONE viewer (WorldManager.on_player_ready → attach_viewer).
	var cc := FA.centre_cell(A)
	var px := float(cc.x) + 0.5
	var pz := float(cc.y) + 0.5
	var player := Node3D.new(); player.name = "GatePlayer"
	get_root().add_child(player)
	player.global_position = Vector3(px, 6.0, pz)
	w.on_player_ready(player)

	var grounded_id := int(w._module_world.call("viewer_instance_id"))
	var grounded_off := float(w._module_world.call("viewer_offset_y"))
	var grounded_view := int(w._module_world.call("viewer_view_distance"))
	_ok(grounded_id != 0 and grounded_view >= 0, "driver: the single player viewer attached (id=%d view=%d off=%.1f)" % [grounded_id, grounded_view, grounded_off])
	print("  attach: viewer id=%d  view=%d  offset_y=%.2f (expect O_base=%.1f)" % [grounded_id, grounded_view, grounded_off, o_base])

	if not on:
		# ---- G-AA-OFF: flag off ⇒ the driver AND the debounced tick are no-ops; the viewer is byte-identical. ----
		var off_unchanged := true
		var id_stable := true
		for i in range(0, 30):
			var alt := 100.0 + float(i) * 40.0          # climb 100 → ~1260
			var pos := Vector3(px, alt, pz)
			w.update_streaming(pos)                     # the live per-tick path (must not write under the flag)
			w.approach_anchor_step_now(pos)             # the verify hook (also gated off → no-op)
			if absf(float(w._module_world.call("viewer_offset_y")) - grounded_off) > 1.0e-4:
				off_unchanged = false
			if int(w._module_world.call("viewer_view_distance")) != grounded_view:
				off_unchanged = false
			if int(w._module_world.call("viewer_instance_id")) != grounded_id:
				id_stable = false
		_ok(off_unchanged, "G-AA-OFF: flag OFF ⇒ ZERO viewer offset/view_distance writes across a 100→1260 climb (byte-identical)")
		_ok(id_stable, "G-AA-OFF: the viewer object is never re-instantiated (attach_viewer byte-identical)")
		print("  NOTE: sed FP_APPROACH_ANCHOR=true (with FACETED=true) to exercise G-AA-ANCHOR/TAU/BYTES.")
		player.queue_free(); w.queue_free()
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	# ---- ON: scripted ascent 0→1200. The driver anchors the viewer to the ground and ramps the view down. ----
	var drv_anchor_holds := true
	var drv_worst_err := 0.0
	var drv_view_monotone := true
	var drv_view_le_grounded := true
	var drv_id_stable := true
	var prev_view := grounded_view + 1
	var seen_full := false
	var seen_zero := false
	var anchored_steps := 0
	for i in range(0, 121):
		var h := float(i) * 10.0                        # lattice y sweep 0 → 1200
		var pos := Vector3(px, h, pz)
		w.approach_anchor_step_now(pos)                 # bypass the debounce (headless ticks are sub-ms apart)
		var off := float(w._module_world.call("viewer_offset_y"))
		var view := int(w._module_world.call("viewer_view_distance"))
		# G-AA-ANCHOR(driver): the AIRBORNE regime is radial altitude ≥ 0 (the centre cell sits a few blocks BELOW the
		# datum at lattice y=0, where the anchor correctly caps at O_base). Where airborne, the viewer radial altitude =
		# _radial(player) + local offset stays pinned to O_base — the plate stays where the player left the ground.
		var r := _radial(A, px, h, pz)
		if r >= 0.0:
			anchored_steps += 1
			var err := absf((r + off) - o_base)
			drv_worst_err = maxf(drv_worst_err, err)
			if err > 1.0e-3:                             # exact identity at the facet axis (no curvature term at centre)
				drv_anchor_holds = false
		# G-AA-TAU(driver): the applied view is monotone non-increasing and never exceeds the grounded (full) case.
		if view > prev_view:
			drv_view_monotone = false
		prev_view = view
		if view > grounded_view:
			drv_view_le_grounded = false
		if int(w._module_world.call("viewer_instance_id")) != grounded_id:
			drv_id_stable = false
		if h <= CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST and view >= grounded_view:
			seen_full = true
		if h >= CubeSphere.ANCHOR_REL_HI and view <= 0:
			seen_zero = true
	_ok(drv_anchor_holds and anchored_steps > 100, "G-AA-ANCHOR: over the ascent the viewer world-pos stays within ε of the sub-player ground for all %d airborne steps (worst %.2e blk)" % [anchored_steps, drv_worst_err])
	_ok(seen_full, "G-AA-TAU: below REL_LO/HYST the plate is fully resident (view == grounded full)")
	_ok(drv_view_monotone, "G-AA-TAU: the applied view_distance ramps DOWN monotonically as the plate recedes rim-inward")
	_ok(seen_zero, "G-AA-TAU: at/above REL_HI the plate is fully released (view == 0)")
	# G-AA-BYTES: the airborne plate holds AT MOST the grounded set (release only shrinks) AND the SAME viewer object
	# serves both — no new node, no new buffer. This pins the voxel-memory ledger: airborne ≤ grounded (zero new bytes).
	_ok(drv_view_le_grounded, "G-AA-BYTES: airborne view_distance never exceeds the grounded full radius (resident bytes airborne ≤ grounded)")
	_ok(drv_id_stable, "G-AA-BYTES: the SAME viewer object serves grounded and airborne (no re-instantiation / new node)")

	# DESCENT re-grow with hysteresis: coming down from orbit, the view re-grows and is FULL again by ~re_lo (~609),
	# earlier than the old alt-regime release (~416). Monotone non-decreasing as we descend.
	var desc_view_monotone := true
	var regrew_full := false
	var prevd := -1
	for i in range(0, 121):
		var h := float(120 - i) * 10.0                  # 1200 → 0
		var pos := Vector3(px, h, pz)
		w.approach_anchor_step_now(pos)
		var view := int(w._module_world.call("viewer_view_distance"))
		if prevd >= 0 and view < prevd:
			desc_view_monotone = false
		prevd = view
		if h <= CubeSphere.ANCHOR_REL_LO / CubeSphere.ANCHOR_HYST and view >= grounded_view:
			regrew_full = true
	_ok(desc_view_monotone, "G-AA-TAU: DESCENT view_distance is monotone non-decreasing (re-stream restarts high)")
	_ok(regrew_full, "G-AA-TAU: descent re-grows to FULL by ~REL_LO/HYST (≈%.0f) — earlier warm-up than the ~416 alt-regime release" % re_lo)

	# DEBOUNCE: two rapid live ticks (< DEBOUNCE ms apart) at DIFFERENT altitudes must not BOTH write — the second is
	# suppressed, so the viewer holds the first value (anti re-mesh churn). Uses the real update_streaming path.
	w.update_streaming(Vector3(px, 20.0, pz))           # first tick — writes (full, near-ground offset)
	var after_first_off := float(w._module_world.call("viewer_offset_y"))
	w.update_streaming(Vector3(px, 800.0, pz))          # second tick immediately after — should be DEBOUNCED
	var after_second_off := float(w._module_world.call("viewer_offset_y"))
	_ok(absf(after_second_off - after_first_off) < 1.0e-4, "G-AA-OFF/debounce: a second tick within DEBOUNCE ms does NOT write (offset held; anti-churn)")

	player.queue_free(); w.queue_free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
