extends SceneTree
## COSMOS SUMMIT-STREAM gate — FP_SUMMIT_STREAM (docs/COSMOS-SUMMIT-STREAM-PRIORITY-DESIGN.md, task #109).
## Symptom: standing on a mountain SUMMIT the near-field voxel blocks arrive tens of seconds late while the same flat
## surface streams instantly on a plain. ROOT: (S1) the approach-anchor viewer is pinned to the DATUM not the ground
## under the player, so on a 66-block summit the streaming VoxelViewer sits ~62 blocks INSIDE the mountain and
## godot_voxel's distance-priority serves the invisible interior first, the visible surface last; (S2) the active-slot
## pace floor + view-target repair go DEAD across the 96-block ridge warm band, freezing the player's own footprint
## facet at credit-0. Fix = pure priority REORDER (S1 ground-relative anchor input + S2 always-live active floor).
##
## Three proof layers, INLINE loops only (a captured-by-value closure would fake a hold):
##   PART A — PURE MATH S1 (flag-independent, always runs): the anchor+release laws (CubeSphere.approach_offset_y /
##     approach_view_distance are pure statics) fed the gate-local h_eff = max(h−ground_h,0) re-centre the viewer on
##     the ground (near-first) for a synthetic 66-block summit, vs the shipped radial-h that buries it 62 below.
##   PART B — S2 machinery (needs FP_LANDING_STREAM_KICK): a bare ModuleWorld with a scripted credit-0 pool + an
##     imminent-neighbour set. Flag ON ⇒ the collapsed active slot is repaired to the full radius AND floored so it
##     fills; flag OFF ⇒ it is frozen (the shipped dead-floor/dead-repair baseline). Single-grow-channel + NEVER-OOM
##     cap asserted (G-SS-BUDGET).
##   PART C — DRIVER S1 (needs the godot_voxel module + FP_APPROACH_ANCHOR): a real WorldManager, a scanned summit
##     column, grounded + airborne poses; the engine-applied viewer offset must equal the S1 (ON) / shipped (OFF)
##     formula — proving the world_manager wiring, not just the law. SKIPs cleanly if the module / flag is absent.
##
## RUN — OFF gating config (byte-identity baseline; needs FACETED + FP_LANDING_STREAM_KICK; add FP_APPROACH_ANCHOR for C):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_LANDING_STREAM_KICK := false/const FP_LANDING_STREAM_KICK := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_APPROACH_ANCHOR := false/const FP_APPROACH_ANCHOR := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_summit_stream.gd
## RUN — ON config: additionally sed FP_SUMMIT_STREAM := true. Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const MW := preload("res://src/world/voxel_module/module_world.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Radial altitude (blocks above the sphere) of a lattice point in facet `fid`'s frame — the WorldManager metric
## (== WorldManager._radial_altitude_lattice, the SAME analytic value the anchor driver reads).
func _radial(fid: int, x: float, y: float, z: float) -> float:
	var w := FA.lattice_to_world64(fid, x, y, z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - FA.R_BLOCKS

## The gate-local S1 law (docs §S1): height above the sub-player ground, NOT radial altitude above the datum sphere.
func _h_eff(h: float, ground_h: float) -> float:
	return maxf(h - ground_h, 0.0)

func _initialize() -> void:
	print("=== verify_summit_stream (SUMMIT-STREAM: G-SS-OFF/ANCHOR/FLOOR/ORDER/BUDGET) ===")
	var on: bool = CubeSphere.FP_SUMMIT_STREAM
	print("  flags: FP_SUMMIT_STREAM=%s FACETED=%s FP_LANDING_STREAM_KICK=%s FP_APPROACH_ANCHOR=%s"
		% [str(on), str(CubeSphere.FACETED), str(CubeSphere.FP_LANDING_STREAM_KICK), str(CubeSphere.FP_APPROACH_ANCHOR)])
	if not CubeSphere.FACETED:
		print("  FAIL: needs FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1); return
	if not CubeSphere.FP_LANDING_STREAM_KICK:
		print("  FAIL: needs FP_LANDING_STREAM_KICK = true (S2 floors the resident active slot; the guard S2 relaxes).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1); return

	TC.warm_up()
	FA.warm_up()
	var o_base := TC.clamped_viewer_offset_y()
	var margin := CubeSphere.ANCHOR_MARGIN
	var full := float(TC.near_render_radius())
	var relief := 66.0                                  # the live repro summit relief (ground_h) above the datum
	# The viewer's anchored world radial altitude is h + offset_y (offset is the LOCAL +Y on the player-child viewer).
	var anchor_floor := maxf(o_base, margin)            # approach_offset_y pins the viewer to datum+max(o_base,MARGIN)
	print("  derived: O_base=%.1f  MARGIN=%.1f  full_radius=%.0f  relief(ground_h)=%.0f  anchor_floor=%.1f  CTRL_RELIEF_FLOOR=%.2f  RAMP_SECONDS=%.2f"
		% [o_base, margin, full, relief, anchor_floor, CubeSphere.CTRL_RELIEF_FLOOR, MW.RAMP_SECONDS])

	# ===============================================================================================================
	# PART A — PURE MATH S1 (flag-independent). The anchor/release laws are pure statics; feeding them the S1 input
	# h_eff re-centres the viewer on the sub-player ground (surface = nearest to godot_voxel's distance priority),
	# vs the shipped radial-h which sinks it `relief` blocks below the summit. All asserts computed directly.
	# ===============================================================================================================

	# --- G-SS-ANCHOR: grounded on a `relief`-block summit (h == ground_h ⇒ h_eff == 0). ---
	var h_ground := relief
	var heff_ground := _h_eff(h_ground, relief)          # == 0: standing ON the surface
	_ok(absf(heff_ground) < 1.0e-6, "G-SS-ANCHOR: h_eff == 0 when grounded on the summit (h == ground_h == %.0f)" % relief)
	var off_s1 := CubeSphere.approach_offset_y(heff_ground, o_base)     # S1 input
	var off_ship := CubeSphere.approach_offset_y(h_ground, o_base)      # shipped input (radial-h)
	var viewer_alt_s1 := h_ground + off_s1               # viewer WORLD radial altitude under S1
	var viewer_alt_ship := h_ground + off_ship           # ... under the shipped law
	# S1: viewer sits at ground + anchor_floor (a few blocks ABOVE the summit surface) — near-first.
	_ok(absf(viewer_alt_s1 - (relief + anchor_floor)) < 1.0e-4,
		"G-SS-ANCHOR: S1 anchors the viewer to the GROUND (world-alt %.1f == ground_h+anchor_floor %.1f)" % [viewer_alt_s1, relief + anchor_floor])
	# Shipped: viewer pinned to the datum (relief blocks BELOW the summit) — the buried-interior bug.
	_ok(absf(viewer_alt_ship - anchor_floor) < 1.0e-4,
		"G-SS-ANCHOR: FALSIFY — the shipped law pins the viewer to the DATUM (world-alt %.1f == anchor_floor %.1f, %.0f below the summit)" % [viewer_alt_ship, anchor_floor, relief])
	_ok(absf((viewer_alt_s1 - viewer_alt_ship) - relief) < 1.0e-4,
		"G-SS-ANCHOR: S1 lifts the viewer by exactly the ground relief (%.0f) vs the shipped datum anchor" % relief)

	# --- G-SS-ORDER: the priority proxy — the viewer→standing-surface distance (godot_voxel bands by 3D distance). ---
	var dist_s1 := absf(viewer_alt_s1 - relief)          # how far the viewer is from the surface it stands over
	var dist_ship := absf(viewer_alt_ship - relief)
	_ok(dist_s1 <= anchor_floor + 1.0e-4,
		"G-SS-ORDER: S1 viewer→surface distance %.1f ≤ anchor_floor %.1f (the visible surface is NEAREST → drains first)" % [dist_s1, anchor_floor])
	_ok(dist_ship >= h_ground - anchor_floor - 1.0e-4,
		"G-SS-ORDER: shipped viewer→surface distance %.1f ≥ h−anchor_floor %.1f (the summit surface is FARTHEST → drains last)" % [dist_ship, h_ground - anchor_floor])
	_ok(dist_ship > dist_s1 + 1.0,
		"G-SS-ORDER: S1 strictly reduces the viewer→surface distance (%.1f → %.1f) — the reorder" % [dist_ship, dist_s1])

	# --- G-SS-ANCHOR (airborne law preserved): 300 blocks above the summit surface ⇒ h_eff == 300. The S1 offset AND
	# release must equal the SHIPPED behaviour of a player 300 above FLAT ground (ground_h = 0, h = 300) — the
	# invariance "the law is over height-above-ground". The shipped-at-summit law (radial h = relief+300) does NOT. ---
	var h_air := relief + 300.0
	var heff_air := _h_eff(h_air, relief)
	_ok(absf(heff_air - 300.0) < 1.0e-6, "G-SS-ANCHOR(air): h_eff == 300 when 300 above the summit (h == %.0f)" % h_air)
	var flat_ref_off := CubeSphere.approach_offset_y(300.0, o_base)          # shipped, 300 above a flat datum
	var s1_air_off := CubeSphere.approach_offset_y(heff_air, o_base)         # S1, 300 above the summit
	_ok(absf(s1_air_off - flat_ref_off) < 1.0e-6,
		"G-SS-ANCHOR(air): S1 airborne offset == the shipped flat-ground offset at d=300 (airborne law PRESERVED)")
	# release ramp: driven by d = h_eff. S1 airborne release == the flat-ground reference at d=300.
	var lo := CubeSphere.ANCHOR_REL_LO
	var flat_ref_view := CubeSphere.approach_view_distance(300.0, full, lo)
	var s1_air_view := CubeSphere.approach_view_distance(heff_air, full, lo)
	_ok(absf(s1_air_view - flat_ref_view) < 1.0e-4,
		"G-SS-ANCHOR(air): S1 airborne release view_distance == the shipped flat reference at d=300 (release law PRESERVED)")
	# FALSIFY: the shipped-at-summit law would treat this as radial h = relief+300 — a DIFFERENT offset (differs by relief).
	var ship_air_off := CubeSphere.approach_offset_y(h_air, o_base)
	_ok(absf(s1_air_off - ship_air_off) > relief - 1.0e-4,
		"G-SS-ANCHOR(air): FALSIFY — the shipped radial-h airborne offset differs from S1 by the ground relief (~%.0f)" % relief)

	# ===============================================================================================================
	# PART B — S2 machinery: a scripted credit-0 pool with an imminent neighbour set. Exercises BOTH S2 changes (the
	# active-slot view-target REPAIR guard + the active-slot pace FLOOR guard) through the REAL _ramp_pool_step.
	# ===============================================================================================================
	var stub := Node3D.new(); get_root().add_child(stub)        # stub terrain: _set_if no-ops (no max_view_distance)
	var stub2 := Node3D.new(); get_root().add_child(stub2)
	var mw = MW.new(); get_root().add_child(mw)
	var A := FA.spawn_facet()
	var phantom_imminent := (A + 1)                             # an imminent NEIGHBOUR fid ≠ active ⇒ the guard is DEAD
	# Collapsed active slot (view_f == view_target == 48): needs BOTH the repair (bump target → full) AND the floor.
	mw.test_seed_pool_slot(A, 48.0, 48.0, true, stub)           # _pool_active = A
	mw._imminent_fid = phantom_imminent                        # the ⅔-of-facet warm-band condition that kills the guard
	mw._imminent_committed = false
	mw.set_stream_pace(0.0)                                     # credit-0 client: raw grow pace 0 (frozen without a floor)
	_ok(mw._pool_active == A and mw._imminent_fid == phantom_imminent and absf(mw._stream_pace) < 1.0e-6,
		"B setup: active=%d, imminent-neighbour=%d (≠active), stream_pace=0 (credit-0)" % [A, phantom_imminent])

	var series: Array = [mw.test_pool_view_f(A)]
	var frames := 0
	var max_pace_ok := true
	var target_after_first := -1
	while mw.test_pool_view_f(A) < full - 0.01 and frames < 60:
		mw.pool_ramp_tick(0.5)                                  # synthetic 0.5 s ticks (headless dt is unstable)
		if frames == 0:
			target_after_first = mw.pool_view_target(A)
		series.append(mw.test_pool_view_f(A))
		frames += 1
	var end_vf := mw.test_pool_view_f(A)
	# per-frame delta ≤ full span × dt × 1.0 / RAMP_SECONDS (pace can never exceed 1.0 — NEVER a supply spike).
	var pace_cap_delta := (full - 48.0) * 0.5 * 1.0 / MW.RAMP_SECONDS + 1.0e-3
	var max_advance := 0.0
	for i in range(1, series.size()):
		var adv := float(series[i]) - float(series[i - 1])
		max_advance = maxf(max_advance, adv)
		if adv > pace_cap_delta:
			max_pace_ok = false
	print("  Part B: frames=%d end_view_f=%.1f target_after_first=%d (series head=%s)" % [frames, end_vf, target_after_first, str(series.slice(0, 5))])

	if on:
		# G-SS-FLOOR: the collapsed active slot is repaired to the full radius AND floored so it fills (bounded ~6 s).
		_ok(target_after_first == int(full),
			"G-SS-FLOOR: S2 repairs the collapsed active view_target to the full near radius (%d) even with an imminent neighbour" % int(full))
		_ok(absf(end_vf - full) < 0.5,
			"G-SS-FLOOR: the resident active slot FILLS to the full radius at credit-0 (%.1f → %.0f)" % [48.0, full])
		# bound: RAMP_SECONDS/CTRL_RELIEF_FLOOR synthetic seconds = 6 s ⇒ ≤ 12 ticks of 0.5 s (+1 for the repair tick).
		var bound_ticks := int(ceil((MW.RAMP_SECONDS / CubeSphere.CTRL_RELIEF_FLOOR) / 0.5)) + 2
		_ok(frames <= bound_ticks,
			"G-SS-FLOOR: the fill is BOUNDED (%d ticks ≤ RAMP_SECONDS/CTRL_RELIEF_FLOOR bound %d) — no unbounded pace" % [frames, bound_ticks])
	else:
		# G-SS-OFF (b): the shipped dead-floor/dead-repair baseline — the active slot is FROZEN at 48 (byte-identical).
		_ok(target_after_first == 48,
			"G-SS-OFF(b): flag OFF ⇒ the collapsed active view_target is NOT repaired (stays 48; the imminent guard kills it)")
		_ok(absf(end_vf - 48.0) < 0.5 and max_advance < 0.001,
			"G-SS-OFF(b): flag OFF ⇒ the active slot NEVER advances (frozen at 48 over %d ticks; dead floor, byte-identical)" % frames)

	# G-SS-BUDGET: the single grow-channel invariant — with a second (non-imminent) neighbour also below target, at
	# most ONE slot advances per tick (active wins), and the pool grow pace is bounded ≤ 1.0 (asserted above).
	var mw2 = MW.new(); get_root().add_child(mw2)
	var B := FA.seam_neighbour(A, 0)
	if B < 0 or B == A:
		B = (A + 2)
	mw2.test_seed_pool_slot(A, 48.0, full, true, stub)         # active, growing 48 → full
	mw2.test_seed_pool_slot(B, 48.0, 96.0, false, stub2)       # a warm non-active, non-imminent neighbour, growing 48 → 96
	mw2._imminent_fid = phantom_imminent
	mw2.set_stream_pace(0.0)
	var single_channel := true
	for _t in range(6):
		var a0 := mw2.test_pool_view_f(A)
		var b0 := mw2.test_pool_view_f(B)
		mw2.pool_ramp_tick(0.5)
		var da := absf(mw2.test_pool_view_f(A) - a0)
		var db := absf(mw2.test_pool_view_f(B) - b0)
		if da > 0.001 and db > 0.001:
			single_channel = false                             # two slots advanced the same tick → channel violated
	_ok(single_channel, "G-SS-BUDGET: ≤ ONE slot advances per tick (single grow-channel invariant preserved)")
	_ok(max_pace_ok, "G-SS-BUDGET: the grow pace never exceeds 1.0 (NEVER-OOM: a REORDER, not a supply spike)")
	# NEVER-OOM cap: any repaired/advanced view_target is clamped at near_render_radius (no new resident volume).
	_ok(mw2.pool_view_target(A) <= int(full) + 0.5,
		"G-SS-BUDGET: the active view_target never exceeds near_render_radius (%d) — no new resident bytes" % int(full))

	# ===============================================================================================================
	# PART C — DRIVER S1 (needs the godot_voxel module + FP_APPROACH_ANCHOR). Proves the WorldManager WIRING of h_eff.
	# ===============================================================================================================
	if not CubeSphere.FP_APPROACH_ANCHOR:
		print("  SKIP(driver): FP_APPROACH_ANCHOR off — the S1 driver is inert; PART A pins the law. (sed it true to exercise C.)")
		_finish(); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP(driver): godot_voxel module absent (no VoxelTerrain) — PART A pins the S1 law.")
		_finish(); return

	var Adrv := FA.spawn_facet()
	TC.set_active_facet(Adrv)
	var w := WorldManager.new(); w.name = "SummitStream"; get_root().add_child(w)
	for _rf in range(4):
		await process_frame
	if not (w.using_module and w._module_world != null and w._module_world.has_method("set_approach_anchor")):
		print("  SKIP(driver): module path not selected (using_module=%s) — PART A stands." % str(w.using_module))
		w.queue_free(); _finish(); return

	# Scan a grid of columns for the local SUMMIT (max ground radial altitude) — the headless repro of the live case.
	var cc := FA.centre_cell(Adrv)
	var sx := float(cc.x) + 0.5
	var sz := float(cc.y) + 0.5
	var best_ground := -1.0e30
	for ix in range(-10, 11):
		for iz in range(-10, 11):
			var qx := float(cc.x) + float(ix) * 24.0 + 0.5
			var qz := float(cc.y) + float(iz) * 24.0 + 0.5
			var surf := w.surface_y(qx, qz)
			var gh := _radial(Adrv, qx, surf, qz)
			if gh > best_ground:
				best_ground = gh; sx = qx; sz = qz
	var ssurf := w.surface_y(sx, sz)                     # the summit column's surface (play-space lattice y)
	var ground_h := _radial(Adrv, sx, ssurf, sz)         # its radial altitude above the datum — the S1 `ground_h`
	print("  driver: summit column (%.1f, %.1f) surface_y=%.1f ground_h=%.1f" % [sx, sz, ssurf, ground_h])
	_ok(ground_h > 8.0, "C setup: found a relief column with ground_h=%.1f > 8 blocks (a real summit to discriminate on)" % ground_h)

	# Attach the single viewer via on_player_ready (WorldManager.attach_viewer), then drive the anchor at each pose.
	var player := Node3D.new(); player.name = "SummitPlayer"; get_root().add_child(player)
	player.global_position = Vector3(sx, ssurf, sz)
	w.on_player_ready(player)

	# --- Grounded summit pose: feet ON the surface ⇒ h == ground_h ⇒ h_eff == 0. ---
	var grounded_pos := Vector3(sx, ssurf, sz)
	w.approach_anchor_step_now(grounded_pos)
	var drv_off_ground := float(w._module_world.call("viewer_offset_y"))
	var h_g := _radial(Adrv, sx, ssurf, sz)
	var exp_off_ground := CubeSphere.approach_offset_y(_h_eff(h_g, ground_h) if on else h_g, o_base)
	print("  driver grounded: viewer offset_y=%.2f  expected(%s)=%.2f  (h=%.1f, h_eff=%.1f)" % [drv_off_ground, ("S1" if on else "shipped"), exp_off_ground, h_g, _h_eff(h_g, ground_h)])
	_ok(absf(drv_off_ground - exp_off_ground) < 0.75,
		"G-SS-ANCHOR(driver): the engine-applied viewer offset matches the %s formula at the grounded summit" % ("S1 h_eff" if on else "shipped radial-h"))
	if on:
		# The viewer's WORLD radial altitude must be the ground + anchor_floor (near-first), NOT the datum (buried).
		var drv_view_alt := h_g + drv_off_ground
		_ok(absf(drv_view_alt - (ground_h + anchor_floor)) < 1.0,
			"G-SS-ORDER(driver): S1 anchors the viewer to the summit ground (world-alt %.1f ≈ ground_h+anchor_floor %.1f), not the datum" % [drv_view_alt, ground_h + anchor_floor])

	# --- Airborne pose: 300 above the summit surface ⇒ the release law is over height-above-ground (S1) / radial (off). ---
	var air_pos := Vector3(sx, ssurf + 300.0, sz)
	w.approach_anchor_step_now(air_pos)
	var drv_off_air := float(w._module_world.call("viewer_offset_y"))
	var h_a := _radial(Adrv, sx, ssurf + 300.0, sz)
	var exp_off_air := CubeSphere.approach_offset_y(_h_eff(h_a, ground_h) if on else h_a, o_base)
	print("  driver airborne(+300): viewer offset_y=%.2f  expected(%s)=%.2f  (h=%.1f, h_eff=%.1f)" % [drv_off_air, ("S1" if on else "shipped"), exp_off_air, h_a, _h_eff(h_a, ground_h)])
	_ok(absf(drv_off_air - exp_off_air) < 0.75,
		"G-SS-ANCHOR(driver,air): the engine-applied offset matches the %s formula airborne (the airborne law is preserved by construction)" % ("S1 h_eff" if on else "shipped"))

	player.queue_free(); w.queue_free()
	_finish()

func _finish() -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
