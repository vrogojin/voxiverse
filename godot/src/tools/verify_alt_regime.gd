extends SceneTree
## COSMOS-PERF UNATTENDED R3 gate — G-ALT-REGIME (flag CubeSphere.FP_ALT_REGIME).
## The §0-W3 killer: at orbital altitude (draws ≈ 30 = shell + sky only) the near-field active-facet machinery still
## churns every physics tick — the ground track sweeps facets so maybe_cross_facet commits redesignations (each an
## O(all-edits) window rebuild + a 128→96 view SHRINK SNAP block-unload burst + gravity/collider/far-ring resync) and
## _manage_facet_pool re-manages the pool — none of it on screen. FP_ALT_REGIME FREEZES that above ATMO_TOP and does
## exactly ONE restore redesignation on RE-ENTRY (crossing back below the gate) so a landing has terrain.
##
## This gate drives a SCRIPTED FALL (the RIGHT condition — a descending, facet-drifted state, not a settled one): the
## player starts high (radial altitude ~900, ORBITAL) at a horizontal position that has drifted PAST the active facet's
## ridge into a neighbour, and falls straight down to the surface. It asserts (FP_ALT_REGIME on):
##   • FREEZE: while above the gate, EVERY maybe_cross_facet returns {} (no crossing / redesignation / window-rebuild /
##     shrink-snap) even though the position is past the ridge (it WOULD cross when not frozen), and the active facet
##     never changes; alt_regime_orbital() (the predicate that also gates the pool manager + the main-thread snow step)
##     is true across the whole orbital band.
##   • RE-ENTRY: exactly ONE redesignation (alt_redesignate_count() == 1) restores the near field, onto the TRUE
##     sub-camera facet (FacetAtlas.facet_of_dir) — not a slow seam-by-seam walk.
##   • LANDING: at touchdown the active facet == the physically-correct sub-camera facet (identical to what any correct
##     scheme, flag on or off, must converge to) AND the near field is present (solid terrain under the player).
## With FP_ALT_REGIME OFF it asserts the machine is fully inert (no freeze, zero restores) — the byte-identical baseline.
##
## LANDING-SAFETY UNDER THE FULL DEPLOY SET: the gate awaits the WorldManager's _ready so the ActiveFrame node
## (FP_FIXED_FRAME) and the near-field pool (FP_M1_POOL + module) are really built before the fall — the re-entry
## restore then exercises the REAL fixed-frame flip + pool re-designation, and the landing assertions prove the player
## ends on the correct facet with SOLID terrain even with the crossing/terrain flags on (FP_FIXED_FRAME, FP_DATUM_BAKE,
## FP_RADIAL_DATUM, FP_CROSS_CORNER_COMMIT, FP_TWIST_FRAME_AWARE, FP_CPPGEN, FP_LANDING_STREAM_KICK, the SN nav flags).
## The gate prints the compiled deploy-flag state; it passes under BOTH the minimal set and the full deploy set.
##
## RUN — minimal (needs FACETED = true; sed-toggle FP_ALT_REGIME = true for the freeze/restore asserts):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_ALT_REGIME := false/const FP_ALT_REGIME := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_alt_regime.gd
## RUN — full deploy set (the landing-safety config; also sed these true):
##   FP_FIXED_FRAME FP_M1_POOL FP_M2_LOD FP_CPPGEN FP_DATUM_BAKE FP_RADIAL_DATUM FP_CROSS_CORNER_COMMIT
##   FP_TWIST_FRAME_AWARE FP_LANDING_STREAM_KICK SN_NAV_MODES SN_NO_CEILING_BOUNCE SN_FOFF_RADIAL_FALL (+ atmosphere B0-B5)
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

## Radial altitude (blocks above the sphere) of a lattice point in facet `fid`'s frame — the WorldManager gate metric.
func _radial(fid: int, x: float, y: float, z: float) -> float:
	var w := FA.lattice_to_world64(fid, x, y, z)
	return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - FA.R_BLOCKS

## The facet the world-direction of a lattice point (in `fid`'s frame) classifies to — the true sub-camera facet.
func _dir_facet(fid: int, x: float, y: float, z: float) -> int:
	var w := FA.lattice_to_world64(fid, x, y, z)
	return FA.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))

func _initialize() -> void:
	print("=== verify_alt_regime (COSMOS-PERF UNATTENDED R3: G-ALT-REGIME) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true.")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	var on := CubeSphere.FP_ALT_REGIME
	# RE-ENTRY FIX: the freeze RELEASES at ATMO_TOP + ALT_REGIME_REENTRY_PREP (ABOVE the surface ceiling, so the near
	# field is correct before surface physics) and ENTERS one hysteresis band higher. `gate_hi` is the ENTER (freeze)
	# threshold; `gate_lo` is the RELEASE (re-entry restore) threshold.
	var gate_hi := CubeSphere.ATMO_TOP + CubeSphere.ALT_REGIME_REENTRY_PREP + CubeSphere.ALT_REGIME_HYST
	var gate_lo := CubeSphere.ATMO_TOP + CubeSphere.ALT_REGIME_REENTRY_PREP
	print("  FP_ALT_REGIME=%s  ATMO_TOP=%.0f  HYST=%.0f  PREP=%.0f  (enter ORBITAL >%.0f, re-enter SURFACE <%.0f)"
		% [str(on), CubeSphere.ATMO_TOP, CubeSphere.ALT_REGIME_HYST, CubeSphere.ALT_REGIME_REENTRY_PREP, gate_hi, gate_lo])
	# The deploy-relevant flags this gate must prove landing-safe UNDER (the re-entry restore interacts with the
	# fixed-frame flip + datum-baked terrain heights + corner-commit crossing + the landing stream kick).
	print("  deploy flags: FIXED_FRAME=%s M1_POOL=%s M2_LOD=%s CPPGEN=%s DATUM_BAKE=%s RADIAL_DATUM=%s CORNER_COMMIT=%s TWIST_FRAME_AWARE=%s LANDING_STREAM_KICK=%s"
		% [str(CubeSphere.FP_FIXED_FRAME), str(CubeSphere.FP_M1_POOL), str(CubeSphere.FP_M2_LOD), str(CubeSphere.FP_CPPGEN),
		   str(CubeSphere.FP_DATUM_BAKE), str(CubeSphere.FP_RADIAL_DATUM), str(CubeSphere.FP_CROSS_CORNER_COMMIT),
		   str(CubeSphere.FP_TWIST_FRAME_AWARE), str(CubeSphere.FP_LANDING_STREAM_KICK)])

	# ---- Build the fall path. Start at facet A's centre; the fall has two phases matching the live W3 scenario:
	#   Phase 1 (ORBITAL ground-track sweep): at a fixed high altitude the horizontal position moves HUNDREDS of blocks
	#     across facet boundaries (the ground track the orbit sweeps). Because the near field is frozen, maybe_cross_facet
	#     returns {} the whole way — so the active facet stays A while the TRUE sub-camera facet (facet_of_dir) drifts to a
	#     neighbour D. This is the exact W3 churn (up to ~10 redesignations/s) the gate must prove is now ZERO.
	#   Phase 2 (descent): straight down at the drifted column; crossing the gate fires the ONE restore onto D. ----
	var A := FA.spawn_facet()
	TC.set_active_facet(A)
	var w := WorldManager.new(); w.name = "AltRegime"; get_root().add_child(w)
	# Let the WorldManager's _ready run to completion — under the full deploy set (FP_FIXED_FRAME + FP_M1_POOL + the
	# module) _ready builds the ActiveFrame node + the near-field pool. Pumping frames makes the gate exercise the REAL
	# fixed-frame restore path (the ActiveFrame flip + pool re-designation), not a half-constructed harness stub.
	for _rf in range(4):
		await process_frame

	var cc := FA.centre_cell(A)
	var feet := w.surface_y(float(cc.x) + 0.5, float(cc.y) + 0.5)
	# Sweep direction: down the −gradient of a ridge's own_dist (heads straight across the facet toward a neighbour).
	var slot := 0
	var px := float(cc.x) + 0.5
	var pz := float(cc.y) + 0.5
	var d0 := FA.own_dist(A, slot, px, feet, pz)
	var g := Vector2(FA.own_dist(A, slot, px + 1.0, feet, pz) - d0, FA.own_dist(A, slot, px, feet, pz + 1.0) - d0)
	g = g.normalized() if g.length() > 1e-9 else Vector2(1, 0)

	if not on:
		# BYTE-IDENTICAL baseline: with FP_ALT_REGIME off the whole regime machine is inert — even at orbital altitude
		# the freeze predicate stays false and no restore path exists. (The full off-byte-identity is verify_feature
		# FLAT = 6042/0; the freeze + re-entry-restore behaviour needs the flag sed-toggled on.)
		var hp := Vector3(float(cc.x) + 0.5, 800.0, float(cc.y) + 0.5)
		w.update_streaming(hp)
		var _c := w.maybe_cross_facet(hp)
		_ok(not w.alt_regime_orbital(), "OFF: alt_regime_orbital() false at orbital altitude (regime machine inert)")
		_ok(w.alt_redesignate_count() == 0, "OFF: zero R3 restores (no re-entry redesignation path)")
		print("  NOTE: sed FP_ALT_REGIME=true (with FACETED=true) to exercise the freeze + re-entry-restore assertions.")
		w.queue_free()
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	var HI := 800.0                        # a fixed ORBITAL altitude (well above the gate) for the sweep
	var cpx := px
	var cpz := pz
	var crossings_above_gate := 0
	var total_crossings := 0
	var orbital_seen := false
	var frozen_all_above := true          # every above-gate maybe_cross_facet returned {} AND stayed ORBITAL
	var swept_off_A := false              # the sub-camera facet drifted off A while frozen (the ground-track sweep)

	# --- Phase 1: orbital horizontal sweep (near field frozen). Move up to ~2400 blocks, checking freeze each tick. ---
	for _step in range(600):
		var pos := Vector3(cpx, HI, cpz)
		var alt := _radial(A, cpx, HI, cpz)   # active is still A (frozen) → measure in A's frame
		w.update_streaming(pos)
		if on and alt > gate_hi:
			if w.alt_regime_orbital(): orbital_seen = true
			else: frozen_all_above = false
		var cr := w.maybe_cross_facet(pos)
		if bool(cr.get("crossed", false)):
			total_crossings += 1
			crossings_above_gate += 1     # any crossing up here is a FREEZE violation
			frozen_all_above = false
		if TC.active_facet() != A:
			break                         # (only if a crossing slipped through — freeze broken)
		if _dir_facet(A, cpx, HI, cpz) != A:
			swept_off_A = true
			break                         # ground track has swept to a neighbour — descend from here
		cpx -= g.x * 4.0
		cpz -= g.y * 4.0

	var drift_D := _dir_facet(A, cpx, HI, cpz)
	var froze_facet := (TC.active_facet() == A)   # the active facet never left A during the whole sweep

	# --- Phase 2: descend straight down at the drifted column. The gate crossing fires the ONE restore. ---
	var cur_fid := A
	var y := HI
	while y > -40.0:
		cur_fid = TC.active_facet()
		var pos := Vector3(cpx, y, cpz)
		var alt := _radial(cur_fid, cpx, y, cpz)
		w.update_streaming(pos)
		if on and alt > gate_hi:
			if w.alt_regime_orbital(): orbital_seen = true
			else: frozen_all_above = false
		var cr := w.maybe_cross_facet(pos)
		if bool(cr.get("crossed", false)):
			total_crossings += 1
			if alt > gate_hi:
				crossings_above_gate += 1
				frozen_all_above = false
			var np: Vector3 = cr["new_pos"]
			cpx = np.x; cpz = np.z          # reframe into the new facet (as the player's apply_reframe would)
		y -= 8.0

	var land_fid := TC.active_facet()
	var land_sub := _dir_facet(land_fid, cpx, 6.0, cpz)
	# Near-field present at touchdown: scan a few cells below the analytic surface for solid terrain.
	var land_surf := int(round(w.surface_y(cpx, cpz)))
	var land_solid := false
	for dy in range(0, 6):
		if w.block_id_at(Vector3i(int(floor(cpx)), land_surf - dy, int(floor(cpz)))) > 0:
			land_solid = true; break

	print("  fall: orbital_seen=%s swept_off_A=%s froze_facet=%s drift_D=%d | crossings_total=%d above_gate=%d restore_count=%d land_fid=%d land_sub=%d solid=%s"
		% [str(orbital_seen), str(swept_off_A), str(froze_facet), drift_D, total_crossings, crossings_above_gate, w.alt_redesignate_count(), land_fid, land_sub, str(land_solid)])

	# FREEZE: the orbital ground-track sweep does ZERO near-field work — no crossing / redesignation / window-rebuild
	# / shrink-snap — even as the sub-camera facet drifts away. This is the §0-W3 phys_ms → 0.
	_ok(orbital_seen, "FREEZE: the fall entered the ORBITAL regime above the gate (the right condition)")
	_ok(swept_off_A, "FREEZE: the ground track swept to a neighbour facet while frozen (drift D=%d ≠ A=%d)" % [drift_D, A])
	_ok(froze_facet, "FREEZE: the active facet stayed A through the whole orbital sweep (no redesignation churn)")
	_ok(crossings_above_gate == 0, "FREEZE: ZERO redesignations above the gate (facet frozen; the fall's phys_ms → 0)")
	_ok(frozen_all_above, "FREEZE: alt_regime_orbital() true across the whole orbital band (pool + snow suspended)")
	# RE-ENTRY: exactly ONE restore redesignation, onto the true sub-camera facet.
	_ok(w.alt_redesignate_count() == 1, "RE-ENTRY: exactly ONE redesignation restores the near field (count == 1)")
	_ok(land_fid != A, "RE-ENTRY: the restore moved the active facet off the stale frozen facet A")
	# LANDING: the near field is correct + present for touchdown.
	_ok(land_fid == land_sub, "LANDING: active facet == sub-camera facet at touchdown (landing facet correct)")
	_ok(land_solid, "LANDING: solid near-field terrain is present under the player at touchdown")

	w.queue_free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
