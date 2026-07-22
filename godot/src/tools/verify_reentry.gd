extends SceneTree
## G-REENTRY-CONTINUOUS gate — the 2026-07-19 live de-orbit blowup (GAME-BREAKING, deploy/perf-plus-sky).
##
## LIVE TELEMETRY (the bug): a pilot de-orbited and fell back; at atmosphere entry (~ATMO_TOP=384) the
## position TELEPORTED 392 → 11473 blocks altitude in ONE ~17 ms frame; v_bci spiked to 642074 b/s — exactly
## Δp/dt of the teleport (the SN2 finite-difference of the position jump, NOT real motion) — then LATCHED
## (the free-fall re-seeded its velocity from the poisoned finite difference), and the player slowly escaped
## to 224 k blocks with nav_mode STUCK at low_orbit and 27-second frames.
##
## This gate reproduces the descent HEADLESSLY through the REAL Player + WorldManager per-frame sequence
## (the exact _physics_process call order: _move → update_streaming → maybe_reanchor → maybe_flip_home_face
## → maybe_cross_facet/apply_reframe → _nav_tick) and asserts:
##   (a) CONTINUITY  — the planet-fixed position |Δw| per sub-call is bounded by real motion (no teleport)
##                     across the whole descent INCLUDING the atmosphere-entry handoff frame and crossings;
##   (b) VELOCITY    — the nav |v_bci| stays finite and physical (no 642074-style latch);
##   (c) CLASSIFY    — nav crosses low_orbit → planetary at the atmosphere band and the surface path lands;
##   (d) RESILIENCE  — inject the LIVE teleport artificially (one-frame +11081-block displacement, whatever
##                     its source) and assert the system RECOVERS: the fall velocity re-seed is BOUNDED (no
##                     garbage adoption), the player falls back instead of escaping (the guard gates).
##
## Scenario sweep for (a)-(c): facet centre, near-ridge (mid-descent crossing), past-ridge (immediate
## crossing at altitude), and near-corner (containment-deferral chain) — the candidate teleport triggers.
##
## RUN (requires the faceted+SN flag set sed-toggled ON, like verify_faceted):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_reentry.gd 2>/dev/null | grep -E "VERIFY|FAIL|JUMP|scenario|frames="
## Exits 0 all-pass / 1 on any failure.

const PlayerCls := preload("res://src/player/player.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")

var _pass := 0
var _fail := 0
var _wm: Node = null

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	_run()

func _run() -> void:
	print("=== verify_reentry (G-REENTRY-CONTINUOUS) ===")
	print("  flags: FACETED=%s SN_NAV_MODES=%s SN_NO_CEILING_BOUNCE=%s SN_ATMO_BRAKING=%s ORBIT_COAST=%s FP_M1_POOL=%s FP_FIXED_FRAME=%s"
		% [str(CubeSphere.FACETED), str(CubeSphere.SN_NAV_MODES), str(CubeSphere.SN_NO_CEILING_BOUNCE),
			str(CubeSphere.SN_ATMO_BRAKING), str(CubeSphere.ORBIT_COAST), str(CubeSphere.FP_M1_POOL), str(CubeSphere.FP_FIXED_FRAME)])
	if not CubeSphere.FACETED or not CubeSphere.SN_NAV_MODES or not CubeSphere.SN_NO_CEILING_BOUNCE:
		print("  FAIL: gate requires FACETED + SN_NAV_MODES + SN_NO_CEILING_BOUNCE sed-toggled ON")
		_fail += 1
		_finish()
		return
	FacetAtlas.warm_up()
	TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
	_wm = WorldManager.new()
	_wm.name = "ReentryWorld"
	get_root().add_child(_wm)
	await process_frame                                     # let the tree/world servers come up

	# --- (a)-(c): the descent scenario sweep (anchored to the CURRENT active facet each time) ---
	await _descent("centre", Vector2(0.0, 0.0), 450.0)
	# near-ridge: 40 blocks inside the east ridge boundary — the fall crosses mid-descent.
	await _descent("near-ridge", _edge_offset(0, -40.0), 450.0)
	# past-ridge: 48 blocks beyond the east ridge — a crossing must fire IMMEDIATELY at altitude.
	await _descent("past-ridge", _edge_offset(0, 48.0), 450.0)
	# near-corner: just inside the NE corner — the crossing containment-deferral chain.
	await _descent("near-corner", _corner_offset(-24.0), 450.0)

	# --- (d): resilience — inject the live teleport and require bounded recovery ---
	await _teleport_resilience()

	# --- (e): the ROOT-CAUSE desync — active facet flips WITHOUT the player reframe (an aborted
	# maybe_cross_facet pipeline: set_active_facet committed, apply_reframe never ran). The stale lattice
	# pose reinterpreted in the new facet's decorrelated frame IS the live one-frame teleport.
	await _fid_desync()

	# --- (f): FP_ALT_REGIME frozen-orbit re-entry — the live "fall-from-orbit tunnels through the planet to the
	# antipode surface" bug. A real tangential orbit sweeps the ground track to a FAR facet while the near field is
	# frozen; the ONE re-entry restore must land the near field onto the true sub-camera facet BEFORE the player drops
	# into the surface-physics regime (alt < ATMO_TOP: floor/collision/walk), else those queries run against the STALE
	# frozen launch facet — the real terrain isn't there → fall-through / late pop (the perceived teleport). Gated on
	# FP_ALT_REGIME (only meaningful with the freeze on).
	if CubeSphere.FP_ALT_REGIME:
		await _frozen_orbit_reentry()

	_finish()

func _finish() -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Planet-fixed (body-fixed absolute) position of the player's lattice pose — anchor/frame independent.
func _wpos(pl: Node) -> Vector3:
	var f := TerrainConfig.active_facet()
	if f < 0:
		return Vector3.ZERO
	var w: Array = FA.lattice_to_world64(f, pl.position.x, pl.position.y, pl.position.z)
	return Vector3(w[0], w[1], w[2])

## Start-offset helpers relative to the CURRENT active facet's centre, in its own lattice.
func _centre_xz() -> Vector2:
	var cc := FacetAtlas.centre_cell(TerrainConfig.active_facet())
	return Vector2(float(cc.x), float(cc.y))

## A point `inset` blocks inside (negative) / beyond (positive) the slot-`slot` ridge from the centre:
## walk from the centre along +x (slot 0 = east in domain terms) until own_dist crosses `-inset`.
func _edge_offset(slot: int, inset: float) -> Vector2:
	var fid := TerrainConfig.active_facet()
	var c := _centre_xz()
	# bisection along +x on own_dist(slot) at ground level: find own_dist == inset (inset<0 ⇒ inside).
	var lo := 0.0
	var hi := 600.0
	for i in 48:
		var mid := (lo + hi) * 0.5
		var d := FacetAtlas.own_dist(fid, slot, c.x + mid, 0.0, c.y)
		if d > -inset:
			lo = mid
		else:
			hi = mid
	return Vector2(c.x + (lo + hi) * 0.5, c.y)

func _corner_offset(inset: float) -> Vector2:
	var fid := TerrainConfig.active_facet()
	var hi: Vector2i = FA.dom_max(fid)
	return Vector2(float(hi.x) + inset, float(hi.y) + inset)

## Build a fresh player over the world, F-off, descending at `v_down` b/s from lattice (x, alt, z).
## `frozen = true` so the ENGINE's _physics_process is a no-op — the gate drives the exact sequence itself.
func _make_player(start_xz: Vector2, alt: float, v_down: float) -> Node:
	var pl = PlayerCls.new()
	pl.world = _wm
	get_root().add_child(pl)                                # fires _ready (camera, nav machine, frame adapter)
	pl.frozen = true
	pl.flying = false
	pl.position = Vector3(start_xz.x, alt, start_xz.y)
	# Seed the F-off fall exactly as live: the free-fall re-seeds from the last SN2 finite-difference
	# velocity (fall_seed(_nav_last_v_bci)) — give it a clean downward v_fix = (0, −v_down, 0).
	var fid := TerrainConfig.active_facet()
	var w: Array = FA.lattice_to_world64(fid, pl.position.x, pl.position.y, pl.position.z)
	var vw: Vector3 = FA.frame_basis(fid) * Vector3(0.0, -v_down, 0.0)
	var bci: Array = ORB.fixed_to_bci("earth", pl._nav_clock, DV.v(w[0], w[1], w[2]), DV.v(vw.x, vw.y, vw.z))
	pl._nav_last_v_bci = bci[1]
	return pl

## One physics frame in the EXACT _physics_process order, with per-sub-call teleport attribution.
## Returns the largest single-sub-call |Δw| this frame (blocks) and prints the culprit if > jump_thresh.
func _tick_attributed(pl: Node, dt: float, jump_thresh: float) -> float:
	var worst := 0.0
	var stage := ""
	var w0 := _wpos(pl)
	pl._move(dt)
	var w1 := _wpos(pl)
	if (w1 - w0).length() > worst: worst = (w1 - w0).length(); stage = "_move"
	_wm.update_streaming(pl.position)
	var w2 := _wpos(pl)
	if (w2 - w1).length() > worst: worst = (w2 - w1).length(); stage = "update_streaming"
	var sh: Vector3 = _wm.maybe_reanchor(pl.global_position)
	if sh != Vector3.ZERO:
		pl.global_position -= sh
	var w3 := _wpos(pl)
	if (w3 - w2).length() > worst: worst = (w3 - w2).length(); stage = "maybe_reanchor"
	_wm.maybe_flip_home_face(pl.global_position)
	var w4 := _wpos(pl)
	if (w4 - w3).length() > worst: worst = (w4 - w3).length(); stage = "maybe_flip_home_face"
	if CubeSphere.FACETED:
		var cross: Dictionary = _wm.maybe_cross_facet(pl.position)
		if not cross.is_empty():
			pl.apply_reframe(cross["new_pos"], cross["yaw_delta"])
	var w5 := _wpos(pl)
	if (w5 - w4).length() > worst: worst = (w5 - w4).length(); stage = "maybe_cross_facet"
	if pl._nav != null:
		pl._nav_tick(dt)
	if worst > jump_thresh:
		print("  JUMP %.1f blocks at stage=%s  alt=%.1f fid=%d pos=%s" %
			[worst, stage, _wpos(pl).length() - FA.R_BLOCKS, TerrainConfig.active_facet(), str(pl.position)])
	return worst

## The descent scenario: fall from `alt0` through ATMO_TOP to the ground; assert continuity/velocity/classify.
func _descent(name_: String, start_xz: Vector2, alt0: float) -> void:
	print("  --- descent scenario: %s ---" % name_)
	var xz := start_xz if start_xz != Vector2.ZERO else _centre_xz()
	var pl = _make_player(xz, alt0, 40.0)
	await process_frame                                     # settle the freshly-added nodes into the world
	var dt := 1.0 / 60.0
	var max_jump := 0.0
	var max_vbci := 0.0
	var saw_planetary := false
	var landed := false
	var min_alt := INF
	var frames := 0
	while frames < 3600:                                    # ≤ 60 s sim — ample for a 450-block fall
		frames += 1
		var jump := _tick_attributed(pl, dt, 25.0)
		if jump > max_jump: max_jump = jump
		var alt := _wpos(pl).length() - FA.R_BLOCKS
		if alt < min_alt: min_alt = alt
		var tele: Dictionary = pl.nav_telemetry()
		if tele.has("v_bci") and float(tele["v_bci"]) > max_vbci:
			max_vbci = float(tele["v_bci"])
		if tele.get("nav_mode", "") == "planetary":
			saw_planetary = true
		# landed: on the walk path resting on the terrain floor
		if alt < 120.0 and absf(pl.velocity.y) < 0.01 and frames > 60:
			landed = true
			break
		if alt > alt0 + 600.0 or alt < -200.0:
			break                                            # escaped / fell through — the asserts below catch it
	var alt_final := _wpos(pl).length() - FA.R_BLOCKS
	print("    frames=%d alt_final=%.1f min_alt=%.1f max_jump=%.2f max_vbci=%.1f planetary=%s landed=%s" %
		[frames, alt_final, min_alt, max_jump, max_vbci, str(saw_planetary), str(landed)])
	# (a) continuity: no single sub-call may move the planet-fixed position more than real motion can.
	# Descent ≤ ~110 b/s ⇒ ≤ 2 blocks/frame; crossings re-express exactly (≈0). 25 blocks = generous slack.
	_ok(max_jump <= 25.0, "%s: position continuous across the whole descent (max single-step %.2f ≤ 25 blocks; live bug was 11081)" % [name_, max_jump])
	# (b) velocity: the nav-read |v_bci| stays physical (fall ≤ ~120 b/s + spin; live bug read 642074).
	_ok(max_vbci > 0.0 and max_vbci < 500.0, "%s: |v_bci| live and physical (max %.1f in (0, 500) b/s; live latch was 642074)" % [name_, max_vbci])
	# (c) classification + landing: the descent must reach the planetary band and settle on the surface.
	_ok(saw_planetary, "%s: nav classifies low_orbit → planetary across the atmosphere band" % name_)
	_ok(landed and alt_final < 120.0, "%s: the surface path catches the fall (landed at alt %.1f)" % [name_, alt_final])
	pl.queue_free()
	await process_frame

## (d) RESILIENCE: inject the live one-frame teleport (+11081 blocks radial, source-agnostic) mid-descent and
## assert the system recovers instead of latching a garbage velocity and escaping (the live failure mode).
func _teleport_resilience() -> void:
	print("  --- teleport resilience (the live 642074-latch reproduction / guard) ---")
	var pl = _make_player(_centre_xz(), 420.0, 60.0)
	await process_frame
	pl.frozen = false                                       # full REAL _physics_process path end-to-end
	var dt := 1.0 / 60.0
	# Descend a few frames so the fall is live, then TELEPORT the lattice pose (the injected fault).
	for i in 30:
		pl._physics_process(dt)
	var alt_before := _wpos(pl).length() - FA.R_BLOCKS
	pl.position.y += 11081.0                                 # the live jump magnitude, one frame
	# Tick on: the OLD code seeds _fall_v_bci from the poisoned finite difference (642074-style) and ESCAPES.
	var max_vbci := 0.0
	var max_alt := 0.0
	for i in 600:                                            # 10 s sim
		pl._physics_process(dt)
		var tele: Dictionary = pl.nav_telemetry()
		if tele.has("v_bci") and float(tele["v_bci"]) > max_vbci:
			max_vbci = float(tele["v_bci"])
		var alt := _wpos(pl).length() - FA.R_BLOCKS
		if alt > max_alt: max_alt = alt
	print("    alt_before=%.1f max_alt=%.1f max_vbci=%.1f" % [alt_before, max_alt, max_vbci])
	# The guard bar: after ANY one-frame displacement the adopted velocity must stay bounded (never the
	# finite-difference of the jump) and the player must NOT be launched outward by it.
	_ok(max_vbci < 1500.0, "guard: post-teleport |v_bci| bounded (max %.1f < 1500; OLD code latches ~642074)" % max_vbci)
	_ok(max_alt < 16000.0, "guard: post-teleport altitude does not escape (max %.1f < 16000; OLD code → 224788)" % max_alt)
	pl.queue_free()
	await process_frame

## (e) FID/POSE DESYNC — the live teleport's mechanism. Mid-descent, flip the active facet to a seam
## neighbour WITHOUT reframing the player (what an error-abort between world_manager.gd:1823's
## set_active_facet and the caller's apply_reframe leaves behind). OLD code: the next frame reinterprets
## the stale lattice pose in the new facet's decorrelated frame — a one-frame teleport of |Δframe| blocks
## (≈45.9 k for the spawn pair; 11081 live) that the free-fall then makes REAL, plus the 642074-class
## velocity latch. FIXED code: the player detects the desync and re-expresses its pose losslessly (Δw ≈ 0).
func _fid_desync() -> void:
	print("  --- fid/pose desync (the live teleport mechanism: aborted crossing pipeline) ---")
	var pl = _make_player(_centre_xz(), 430.0, 50.0)
	await process_frame
	pl.frozen = false
	var dt := 1.0 / 60.0
	for i in 20:
		pl._physics_process(dt)
	var fid := TerrainConfig.active_facet()
	var nb := FacetAtlas.seam_neighbour(fid, 0)
	var w_before := _wpos(pl)
	TerrainConfig.set_active_facet(nb)                       # the half-committed crossing (NO reframe)
	pl._physics_process(dt)                                  # OLD code: reads the stale pose in nb's frame
	var w_after := _wpos(pl)
	var jump := (w_after - w_before).length()
	var max_vbci := 0.0
	var max_alt := 0.0
	for i in 300:                                            # 5 s on
		pl._physics_process(dt)
		var tele: Dictionary = pl.nav_telemetry()
		if tele.has("v_bci") and float(tele["v_bci"]) > max_vbci:
			max_vbci = float(tele["v_bci"])
		var alt := _wpos(pl).length() - FA.R_BLOCKS
		if alt > max_alt: max_alt = alt
	print("    desync %d→%d  one-frame |Δw|=%.1f  max_vbci=%.1f max_alt=%.1f" % [fid, nb, jump, max_vbci, max_alt])
	# FIXED code: the desync is healed losslessly — the world position never jumps (≤ real motion + slack)
	# and no garbage velocity is adopted. OLD code: jump ≈ 45.9 k here (11081 live), v_bci latch ~10⁵⁻⁶.
	_ok(jump <= 25.0, "desync healed: one-frame |Δw| %.1f ≤ 25 blocks (OLD code teleports ~45.9k; live 11081)" % jump)
	_ok(max_vbci < 1500.0, "desync healed: |v_bci| stays physical (max %.1f < 1500; OLD code latches the jump/dt)" % max_vbci)
	pl.queue_free()
	await process_frame

## (f) FP_ALT_REGIME frozen-orbit re-entry (the live fall-from-orbit teleport). Seed a REAL tangential orbit at high
## altitude over facet A; the freeze holds A while the ground track sweeps to a FAR facet, then the descent fires the
## ONE re-entry restore. Drives the REAL Player._physics_process end-to-end. Asserts:
##   • CONTINUITY  — planet-fixed |Δw| per frame ≤ real motion (no world teleport at the deferred redesignation);
##   • NEAR-FIELD-READY — the near field is redesignated onto the true sub-camera facet BEFORE the player enters the
##     surface-physics regime (alt < ATMO_TOP), so floor/collision/walk NEVER query the STALE frozen far facet. This
##     is the fails-before invariant: with the OLD release at ATMO_TOP−HYST the freeze holds ~32 blocks INTO the
##     surface regime, so surface physics runs against the launch facet's terrain (the real ground absent → the fall-
##     through / tunnel-to-antipode). The fix releases the freeze ABOVE ATMO_TOP.
##   • LANDING     — the descent lands on SOLID terrain on the physically-correct sub-camera facet.
func _frozen_orbit_reentry() -> void:
	print("  --- frozen-orbit re-entry (FP_ALT_REGIME: fall-from-orbit tunnel-to-antipode) ---")
	var A := TerrainConfig.active_facet()
	var cc := FacetAtlas.centre_cell(A)
	var pl = _make_player(Vector2(float(cc.x) + 0.5, float(cc.y) + 0.5), 900.0, 0.0)
	await process_frame
	# Seed a real sub-circular tangential orbit (an ellipse that plunges on the far side): the ground track sweeps a
	# large angular distance while the near field is frozen at A.
	var fid := TerrainConfig.active_facet()
	var w0: Array = FA.lattice_to_world64(fid, pl.position.x, pl.position.y, pl.position.z)
	var r0 := sqrt(w0[0]*w0[0] + w0[1]*w0[1] + w0[2]*w0[2])
	var vcirc := sqrt(GRAV.gm_dyn("earth") / r0)
	var wu: Array = FA.lattice_to_world64(fid, pl.position.x + 1.0, pl.position.y, pl.position.z + 0.37)
	var tang := Vector3(wu[0]-w0[0], wu[1]-w0[1], wu[2]-w0[2]).normalized()
	var vfix := tang * (0.72 * vcirc)
	var bci: Array = ORB.fixed_to_bci("earth", pl._nav_clock, DV.v(w0[0], w0[1], w0[2]), DV.v(vfix.x, vfix.y, vfix.z))
	pl._nav_last_v_bci = bci[1]
	pl._fall_have_v = false
	pl.frozen = false                      # drive the REAL _physics_process end-to-end (like scenarios (d)/(e))

	var dt := 1.0 / 60.0
	var prev_w := _wpos(pl)
	var max_jump := 0.0
	var swept_far := false                 # the ground track drifted off the launch facet A while frozen
	var restore_alt := -1.0                # radial altitude at the ONE re-entry redesignation
	var stale_surface_frames := 0          # frames where alt < ATMO_TOP but the active facet is NOT the sub-camera facet
	var worst_stale := ""                  # a sample of the worst stale-surface frame
	var landed := false
	var prev_fid := A
	for f in range(4000):
		pl._physics_process(dt)
		var w := _wpos(pl)
		var af := TerrainConfig.active_facet()
		var alt := w.length() - FA.R_BLOCKS
		var sub := FA.facet_of_dir(CubeSphere.DVec3.new(w.x, w.y, w.z))
		var jump := (w - prev_w).length()
		if jump > max_jump: max_jump = jump
		if sub != A and sub >= 0: swept_far = true
		if af != prev_fid and restore_alt < 0.0:
			restore_alt = alt              # the first (the ONE) re-entry redesignation
		# THE INVARIANT: once in the surface-physics regime (alt < ATMO_TOP), the active facet must be the sub-camera
		# facet — surface floor/collision/walk must query the terrain UNDER the player, never the stale frozen facet.
		if alt < CubeSphere.ATMO_TOP and af != sub and sub >= 0:
			stale_surface_frames += 1
			if worst_stale == "":
				worst_stale = "alt=%.1f active=%d sub=%d" % [alt, af, sub]
		prev_w = w; prev_fid = af
		if alt < 20.0 and absf(pl.velocity.y) < 0.1 and f > 120:
			landed = true; break
		if alt < -120.0:
			break                          # fell THROUGH the terrain
		if alt > 4000.0:
			break
	var land_fid := TerrainConfig.active_facet()
	var wl := _wpos(pl)
	var land_sub := FA.facet_of_dir(CubeSphere.DVec3.new(wl.x, wl.y, wl.z))
	var land_alt := wl.length() - FA.R_BLOCKS
	var land_solid := false
	var surf := int(round(_wm.surface_y(pl.position.x, pl.position.z)))
	for dy in range(0, 8):
		if _wm.block_id_at(Vector3i(int(floor(pl.position.x)), surf - dy, int(floor(pl.position.z)))) > 0:
			land_solid = true; break
	print("    swept_far=%s restore_alt=%.1f (ATMO_TOP=%.0f) stale_surface_frames=%d [%s] max_jump=%.2f land_fid=%d land_sub=%d land_alt=%.1f solid=%s"
		% [str(swept_far), restore_alt, CubeSphere.ATMO_TOP, stale_surface_frames, worst_stale, max_jump, land_fid, land_sub, land_alt, str(land_solid)])
	# The orbit must actually exercise the freeze (a far ground-track sweep) — else the scenario proves nothing.
	_ok(swept_far, "frozen-orbit: the ground track swept to a far facet while frozen (the freeze is exercised)")
	# CONTINUITY: the planet-fixed position never teleports at the deferred redesignation (the reframe is lossless).
	_ok(max_jump <= 25.0, "frozen-orbit: planet-fixed position continuous across re-entry (max |Δw| %.2f ≤ 25 blocks)" % max_jump)
	# NEAR-FIELD-READY (the fix): the near field is on the sub-camera facet BEFORE surface physics runs. OLD code
	# releases at ATMO_TOP−HYST ⇒ ~32 blocks of surface walk against the stale far facet ⇒ stale_surface_frames > 0.
	_ok(stale_surface_frames == 0, "frozen-orbit: surface physics NEVER runs against the stale frozen facet (stale_surface_frames=%d; OLD code: freeze holds below ATMO_TOP)" % stale_surface_frames)
	_ok(restore_alt >= CubeSphere.ATMO_TOP, "frozen-orbit: re-entry restore fires ABOVE the surface ceiling (restore_alt=%.1f ≥ ATMO_TOP=%.0f)" % [restore_alt, CubeSphere.ATMO_TOP])
	# LANDING: on solid terrain on the physically-correct sub-camera facet (not tunnelled through / stranded).
	_ok(landed and land_solid and land_fid == land_sub, "frozen-orbit: landed on SOLID correct-facet terrain (fid=%d sub=%d alt=%.1f solid=%s)" % [land_fid, land_sub, land_alt, str(land_solid)])
	pl.queue_free()
	await process_frame
