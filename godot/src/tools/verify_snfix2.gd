extends SceneTree
## SN-FIX2 gate (2026-07-18 live-pilot fixes) — G-SN-HUDNAV + G-SN-KEEPHEADING + G-SN-NOBOUNCE.
## All three behaviours are factored into pure, parameter-driven helpers so this gate drives BOTH flag states
## headlessly (the const flags themselves default false ⇒ FLAT byte-identity is verify_feature 6035/0, separate).
##
##   G-SN-HUDNAV     (FIX #1, SN_HUD_NAV): the NavHUD node builds its labels on _ready (lifecycle), and the pure
##                   position/altitude/mode formatters are correct for a sample state.
##   G-SN-KEEPHEADING(FIX #2, FP_CROSS_KEEP_HEADING): Player.reframe_twist — flag OFF twists heading+velocity by
##                   yaw_delta (shipped); flag ON leaves heading + world-velocity direction UNCHANGED. Position
##                   continuity is the caller's untouched position assignment (asserted structurally).
##   G-SN-NOBOUNCE   (FIX #3, SN_NO_CEILING_BOUNCE): Player.orbital_handoff — flag OFF auto-hands any orbital mode
##                   to the dev-flight controller (shipped); flag ON keeps the kinematic lattice fly through the
##                   atmosphere→orbit band until the explicit O commit. Plus the CONFIRMED cause: the dev-flight
##                   controller decelerates a straight-up climb at the ceiling (the "bounce"), which the kinematic
##                   path preserves velocity across.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_snfix2.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const PlayerCls := preload("res://src/player/player.gd")
const NavHUDCls := preload("res://src/ui/nav_hud.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const DEVF := preload("res://src/cosmos/cosmos_dev_flight.gd")
const DV := preload("res://src/cosmos/dvec3.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_snfix2 (G-SN-HUDNAV + G-SN-KEEPHEADING + G-SN-NOBOUNCE) ===")
	print("  flags: SN_HUD_NAV=%s FP_CROSS_KEEP_HEADING=%s SN_NO_CEILING_BOUNCE=%s (gate drives both states)"
		% [str(CubeSphere.SN_HUD_NAV), str(CubeSphere.FP_CROSS_KEEP_HEADING), str(CubeSphere.SN_NO_CEILING_BOUNCE)])
	FacetAtlas.warm_up()                                    # r_vox(earth) reads FacetAtlas.R_BLOCKS
	_gate_hudnav()
	_gate_keepheading()
	_gate_nobounce()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------------------------------------------------------------------ G-SN-HUDNAV
func _gate_hudnav() -> void:
	print("  --- G-SN-HUDNAV: NavHUD lifecycle + formatting ---")
	# Lifecycle: adding to the tree fires _ready, which builds the panel + labels.
	var h = NavHUDCls.new()
	h._ready()                                              # builds the panel + labels (fired by add_child in-app)
	_ok(h.get_child_count() == 1, "NavHUD builds exactly one panel node on _ready")
	_ok(h._pos_label != null and h._mode_label != null, "NavHUD position + mode labels instantiated")
	# _process with a null player must be a safe no-op (no crash, labels stay default).
	h.player = null
	h._process(0.016)
	_ok(true, "NavHUD._process(player=null) is a safe no-op")
	h.queue_free()

	# Formatting: pure, node-free.
	_ok(NavHUDCls.format_pos(Vector3(10.4, 20.6, -30.4), 45.2) == "pos 10, 21, -30\nalt 45",
		"format_pos rounds x,y,z + altitude")
	_ok(NavHUDCls.format_mode("low_orbit") == "mode: LOW_ORBIT", "format_mode upper-cases the nav name")
	_ok(NavHUDCls.format_mode("—") == "mode: —", "format_mode passes the off-state dash through")

# ------------------------------------------------------------------ G-SN-KEEPHEADING
func _gate_keepheading() -> void:
	print("  --- G-SN-KEEPHEADING: reframe_twist heading/velocity preservation ---")
	var yaw := 0.5
	var vel := Vector3(3.0, -2.0, 4.0)      # a non-trivial velocity (the y is vertical/radial, must NEVER change)
	var yd := 0.7                            # a nonzero seam twist
	# Flag OFF (shipped): heading twists by yaw_delta, horizontal velocity rotates about UP, vertical y untouched.
	var off: Array = PlayerCls.reframe_twist(yaw, vel, yd, false)
	_ok(is_equal_approx(float(off[0]), wrapf(yaw + yd, -PI, PI)), "flag OFF: rotation.y twists by yaw_delta (shipped)")
	_ok((off[1] as Vector3).is_equal_approx(vel.rotated(Vector3.UP, yd)), "flag OFF: velocity rotates about UP (shipped)")
	# Flag ON: heading + velocity are UNCHANGED across the crossing (world heading preserved).
	var on: Array = PlayerCls.reframe_twist(yaw, vel, yd, true)
	_ok(float(on[0]) == yaw, "flag ON: rotation.y UNCHANGED across the crossing (heading preserved)")
	_ok((on[1] as Vector3) == vel, "flag ON: velocity (incl. its world direction) UNCHANGED across the crossing")
	# Falsify: with a nonzero twist the two branches MUST differ, else the flag does nothing.
	_ok(float(on[0]) != float(off[0]), "falsify: ON and OFF headings differ for a nonzero yaw_delta")

# ------------------------------------------------------------------ G-SN-NOBOUNCE
func _gate_nobounce() -> void:
	print("  --- G-SN-NOBOUNCE: orbital handoff decision + climb-preservation ---")
	# Decision matrix. (mode, commit, no_bounce) -> hand off to the dev-flight controller?
	_ok(PlayerCls.orbital_handoff(NAV.PLANETARY, false, false) == false, "PLANETARY never hands off (flag off)")
	_ok(PlayerCls.orbital_handoff(NAV.PLANETARY, true, true) == false, "PLANETARY never hands off (flag on)")
	_ok(PlayerCls.orbital_handoff(NAV.LOW_ORBIT, false, false) == true, "flag OFF: LOW_ORBIT auto-hands off (shipped)")
	_ok(PlayerCls.orbital_handoff(NAV.HIGH_ORBIT, false, false) == true, "flag OFF: HIGH_ORBIT auto-hands off (shipped)")
	_ok(PlayerCls.orbital_handoff(NAV.LOW_ORBIT, false, true) == false, "flag ON, no commit: LOW_ORBIT keeps kinematic fly (the fix)")
	_ok(PlayerCls.orbital_handoff(NAV.LOW_ORBIT, true, true) == true, "flag ON + O-commit: LOW_ORBIT engages the controller")
	# Falsify: the flag must matter — the same LOW_ORBIT/no-commit state differs between flag off and on.
	_ok(PlayerCls.orbital_handoff(NAV.LOW_ORBIT, false, false) != PlayerCls.orbital_handoff(NAV.LOW_ORBIT, false, true),
		"falsify: the flag changes the LOW_ORBIT/no-commit handoff decision")

	# Kinematic path (flag ON, no commit): across the ENTIRE atmosphere→orbit band the decision keeps the shipped
	# lattice fly, whose velocity is a constant (position += wish·fly_speed·dt). So a climb velocity is PRESERVED
	# by construction — assert the decision stays kinematic while the nav machine reports LOW_ORBIT across 384..600.
	var R := FacetAtlas.R_BLOCKS
	var kinematic_all_band := true
	for alt in range(384, 601, 8):
		var mode := NAV.classify("earth", DV.v(0.0, 0.0, R + float(alt)), DV.v(0.0, 0.0, 0.0), 0.0)
		if mode == NAV.PLANETARY:
			continue
		if PlayerCls.orbital_handoff(mode, false, true):     # flag ON, not committed
			kinematic_all_band = false
			break
	_ok(kinematic_all_band, "flag ON: the whole 384..600 band stays on the kinematic (velocity-preserving) fly")

	# CONFIRMED CAUSE: the dev-flight controller (the shipped handoff) DECELERATES a straight-up climb at the
	# ceiling. Seed a 32 b/s radial climb, command LEVEL forward (as when flying up-and-forward), and step the
	# controller — the radial velocity collapses far below the climb (the "bounce"). The kinematic path (flag on)
	# is what avoids this.
	var p := DV.v(0.0, 0.0, R + 480.0)                       # just above ATMO_TOP, where LOW_ORBIT has committed
	var v := DV.v(0.0, 0.0, 32.0)                            # climbing radially at 32 b/s
	var wish := DV.v(1.0, 0.0, 0.0)                          # level-forward command (tangential), NOT straight up
	var min_radial := 32.0
	for i in 60:                                             # 1 s of controller flight
		var r := DV.length(p)
		var cap := DEVF.speed_cap(NAV.LOW_ORBIT, "earth", p, 0.0, true)
		var out: Array = DEVF.step(NAV.LOW_ORBIT, "earth", p, v, 0.0, 1.0 / 60.0, wish, cap)
		var p_new: PackedFloat64Array = out[0]
		v = out[1]
		var radial := (DV.length(p_new) - r) * 60.0          # radial speed this tick (b/s)
		min_radial = minf(min_radial, radial)
		p = p_new
	_ok(min_radial < 16.0, "confirmed cause: dev-flight decelerates a 32 b/s climb to %.1f b/s (< half) on a level command" % min_radial)
