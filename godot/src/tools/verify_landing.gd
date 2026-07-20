extends SceneTree
## G-LANDING gate — the 2026-07-20 live landing bugs (flight-exit fall + landed HUD speed).
##
## LIVE TELEMETRY: after de-orbit the pilot descended in F-mode fly (frame_v == fly_speed 16, gravity off by
## design), radial rate ~3 b/s — read as "falling almost parallel to the surface / gravity not properly
## reinstantiated when quitting orbiting and flight mode". And a LANDED player's HUD speed read 14.5 b/s
## forever — the ω×r spin carrier (raw |v_bci| never reads 0 on a rotating planet).
##
## Asserts:
##   G-LANDING-RADIAL  fall_seed_radial kernel: tangential dropped, radial preserved (both signs), degenerate
##                     input passthrough. Pure.
##   G-LANDING-FOFF    the EXPLICIT F flight-off toggle (SN_FOFF_RADIAL_FALL) commits the free-fall seed to the
##                     radial component: an orbital-speed tangential seed becomes a radial fall that DESCENDS
##                     and LANDS; an AUTOMATIC free-fall entry (no latch) keeps the tangential seed verbatim
##                     (SN-R1 continuity falsifier — the latch, not the regime, gates the projection).
##   G-LANDING-HUD     a LANDED (standing) player's nav_speed_bci() reads the SURFACE-frame speed ~0 while the
##                     raw |v_bci| telemetry still reads the spin carrier |ω×p| — the live 14.5 confusion,
##                     reproduced and fixed.
##
## RUN (requires the faceted+SN flag set + SN_FOFF_RADIAL_FALL sed-toggled ON, like verify_reentry):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_landing.gd 2>/dev/null | grep -E "VERIFY|FAIL"
## Exits 0 all-pass / 1 on any failure.

const PlayerCls := preload("res://src/player/player.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

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
	print("=== verify_landing (G-LANDING: flight-exit radial fall + landed HUD speed) ===")
	print("  flags: FACETED=%s SN_NAV_MODES=%s SN_NO_CEILING_BOUNCE=%s SN_FOFF_RADIAL_FALL=%s"
		% [str(CubeSphere.FACETED), str(CubeSphere.SN_NAV_MODES), str(CubeSphere.SN_NO_CEILING_BOUNCE), str(CubeSphere.SN_FOFF_RADIAL_FALL)])
	if not (CubeSphere.FACETED and CubeSphere.SN_NAV_MODES and CubeSphere.SN_NO_CEILING_BOUNCE and CubeSphere.SN_FOFF_RADIAL_FALL):
		print("  FAIL: gate requires FACETED + SN_NAV_MODES + SN_NO_CEILING_BOUNCE + SN_FOFF_RADIAL_FALL sed-toggled ON")
		_fail += 1
		_finish()
		return
	FacetAtlas.warm_up()
	TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
	_wm = WorldManager.new()
	_wm.name = "LandingWorld"
	get_root().add_child(_wm)
	await process_frame
	_gate_radial_kernel()
	await _gate_foff_commit()
	await _gate_hud_speed()
	_finish()

func _finish() -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _wpos(pl: Node) -> Vector3:
	var f := TerrainConfig.active_facet()
	if f < 0:
		return Vector3.ZERO
	var w: Array = FA.lattice_to_world64(f, pl.position.x, pl.position.y, pl.position.z)
	return Vector3(w[0], w[1], w[2])

# ------------------------------------------------------------------ G-LANDING-RADIAL (pure kernel)
func _gate_radial_kernel() -> void:
	print("  --- G-LANDING-RADIAL: fall_seed_radial projection kernel ---")
	var p := DV.v(0.0, 0.0, 6771.0)                          # radial = +Z here
	var v := DV.v(250.0, 30.0, -40.0)                        # 250/30 tangential, −40 radial (falling)
	var out := PlayerCls.fall_seed_radial(v, p)
	_ok(absf(float(out[0])) < 1.0e-12 and absf(float(out[1])) < 1.0e-12, "tangential components dropped (250/30 → 0)")
	_ok(absf(float(out[2]) + 40.0) < 1.0e-12, "inward radial component preserved (−40)")
	out = PlayerCls.fall_seed_radial(DV.v(100.0, 0.0, 25.0), p)
	_ok(absf(float(out[2]) - 25.0) < 1.0e-12, "OUTWARD radial preserved too (+25 — gravity decelerates it; no injected impulse)")
	out = PlayerCls.fall_seed_radial(v, DV.v(0.0, 0.0, 0.0))
	_ok(out[0] == v[0] and out[2] == v[2], "degenerate p (centre) passes the seed through unchanged")
	# oblique radial: projection magnitude == v·r̂ for a non-axis-aligned p
	var p2 := DV.v(3000.0, 4000.0, 0.0)
	var v2 := DV.v(10.0, 0.0, 7.0)
	var out2 := PlayerCls.fall_seed_radial(v2, p2)
	var rhat := DV.scale(p2, 1.0 / DV.length(p2))
	_ok(absf(DV.length(out2) - absf(DV.dot(v2, rhat))) < 1.0e-12, "oblique radial: |projection| == |v·r̂|")

# ------------------------------------------------------------------ G-LANDING-FOFF (live scene)
func _gate_foff_commit() -> void:
	print("  --- G-LANDING-FOFF: explicit flight-off commits to a radial fall that lands ---")
	var fid := TerrainConfig.active_facet()
	var cc := FacetAtlas.centre_cell(fid)
	var pl = PlayerCls.new()
	pl.world = _wm
	get_root().add_child(pl)
	await process_frame
	pl.position = Vector3(float(cc.x), 600.0, float(cc.y))
	pl.flying = false
	# Orbital-exit state: near-circular tangential 250 b/s + slight descent, as _nav_last_v_bci (the seed source).
	var w: Array = FA.lattice_to_world64(fid, pl.position.x, pl.position.y, pl.position.z)
	var p_bci: PackedFloat64Array = ORB.fixed_to_bci("earth", pl._nav_clock, DV.v(w[0], w[1], w[2]), DV.v(0.0, 0.0, 0.0))[0]
	var rh := DV.scale(p_bci, 1.0 / DV.length(p_bci))
	# a unit tangent ⊥ r̂ (pick any: t = normalize(ẑ×r̂), fall back if degenerate)
	var t := DV.v(-rh[1], rh[0], 0.0)
	var tl := DV.length(t)
	t = DV.scale(t, 1.0 / tl)
	var v_seed := DV.add(DV.scale(t, 250.0), DV.scale(rh, -20.0))
	pl._nav_last_v_bci = PackedFloat64Array([v_seed[0], v_seed[1], v_seed[2]])
	pl._fall_have_v = false                                  # the awaited engine frame may have pre-seeded a fall
	pl._foff_radial = true                                   # the EXPLICIT F-off latch (set by the toggles)
	var alt0 := _wpos(pl).length() - FA.R_BLOCKS
	var dt := 1.0 / 60.0
	pl._physics_process(dt)                                  # first free-fall tick seeds + projects
	# the seeded fall velocity must be RADIAL: tangential component ~0, radial ≈ −20.
	var fv: PackedFloat64Array = pl._fall_v_bci
	var v_rad := DV.dot(fv, rh)
	var v_tan := DV.length(DV.sub(fv, DV.scale(rh, v_rad)))
	print("    post-seed: v_radial=%.2f v_tangential=%.2f (seed was 250 tangential / −20 radial)" % [v_rad, v_tan])
	_ok(v_tan < 1.0, "F-off commit drops the 250 b/s tangential coast (residual %.3f < 1)" % v_tan)
	_ok(absf(v_rad + 20.0) < 1.0, "F-off commit keeps the −20 b/s radial descent (got %.2f)" % v_rad)
	_ok(not pl._foff_radial, "the land-commit latch is one-shot (cleared after the seed)")
	# and the fall LANDS: descend to the surface, walk path catches (bounded frames).
	var landed := false
	for i in 3600:
		pl._physics_process(dt)
		var alt := _wpos(pl).length() - FA.R_BLOCKS
		if alt < 120.0 and absf(pl.velocity.y) < 0.01 and i > 60:
			landed = true
			break
	var alt_f := _wpos(pl).length() - FA.R_BLOCKS
	_ok(landed and alt_f < 120.0 and alt_f < alt0, "the committed fall descends %d→%.0f and LANDS on the surface" % [int(alt0), alt_f])
	# FALSIFIER (SN-R1): an AUTOMATIC free-fall entry (latch NOT set) keeps the tangential seed verbatim.
	pl.position = Vector3(float(cc.x), 600.0, float(cc.y))
	pl._nav_last_v_bci = PackedFloat64Array([v_seed[0], v_seed[1], v_seed[2]])
	pl._fall_have_v = false
	pl._foff_radial = false
	pl._physics_process(dt)
	var fv2: PackedFloat64Array = pl._fall_v_bci
	var v_tan2 := DV.length(DV.sub(fv2, DV.scale(rh, DV.dot(fv2, rh))))
	_ok(v_tan2 > 200.0, "falsify: an AUTOMATIC entry (no latch) keeps the tangential seed (%.0f b/s — SN-R1 continuity intact)" % v_tan2)
	pl.queue_free()
	await process_frame

# ------------------------------------------------------------------ G-LANDING-HUD (live scene)
func _gate_hud_speed() -> void:
	print("  --- G-LANDING-HUD: a landed player reads ~0 surface speed, not the 14.5 spin carrier ---")
	var fid := TerrainConfig.active_facet()
	var cc := FacetAtlas.centre_cell(fid)
	var pl = PlayerCls.new()
	pl.world = _wm
	get_root().add_child(pl)
	await process_frame
	pl.flying = false
	# stand at a fixed lattice point just above the terrain; tick the nav machine only (no movers) so the
	# position is EXACTLY body-fixed static — the pure "landed and standing" reading.
	pl.position = Vector3(float(cc.x), 80.0, float(cc.y))
	var dt := 1.0 / 60.0
	for i in 10:
		pl._nav_tick(dt)
	var tele: Dictionary = pl.nav_telemetry()
	var w: Array = FA.lattice_to_world64(fid, pl.position.x, pl.position.y, pl.position.z)
	var carrier := DV.length(ORB.omega_cross("earth", DV.v(w[0], w[1], w[2])))
	print("    tele frame_v=%s v_bci=%s expected carrier=%.2f hud=%.2f" %
		[str(tele.get("frame_v")), str(tele.get("v_bci")), carrier, pl.nav_speed_bci()])
	_ok(tele.has("v_bci") and absf(float(tele["v_bci"]) - carrier) < 0.5,
		"raw |v_bci| of a standing player == the spin carrier |ω×p| = %.2f (the live 14.5 reading)" % carrier)
	_ok(tele.has("frame_v") and float(tele["frame_v"]) < 0.5, "surface-frame speed of a standing player ≈ 0 (carrier subtracted)")
	_ok(pl.nav_speed_bci() < 0.5, "HUD nav_speed_bci() now reads the frame speed ≈ 0 (was pinned at the carrier)")
	# falsify: the two frames genuinely differ for the standing player (the fix is load-bearing).
	_ok(absf(float(tele["v_bci"]) - float(tele["frame_v"])) > 5.0, "falsify: |v_bci| and frame_v differ by the carrier (>5 b/s)")
	pl.queue_free()
	await process_frame
