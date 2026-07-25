extends SceneTree
## DEV TIME-CHEAT gate (remote `set_time`, docs/COSMOS-REMOTE-CONTROL-DESIGN.md). Proves the celestial
## time-of-day cheat MATH end-to-end WITHOUT a live browser. All the mapping (local solar hour ↔ clock
## offset) and the clock offset are PURE (CosmosEphemeris.* statics + CosmosClock), so this gate drives them
## DIRECTLY and is FLAG-INDEPENDENT: it passes identically with ORBITAL_SKY / FP_SEASONS / CONTROL_ENABLED
## true or false — those flags only decide whether the in-game op COMPOSES this math (the executor exists only
## under a live grant). The in-game path (player.remote_set_time → world.cosmos_clock().add_offset) folds the
## SAME offset_for_local_hours delta into the SAME clock, so this gate pins the shipped behaviour by construction.
##
## CONVENTION (matches CosmosSky._update_sky): the ephemeris body-fixed frame IS the world/scene frame, planet
## centred at the world origin, so a surface point's body-fixed up == its world position; +Z = spin/north axis.
##
## Gates:
##   G-TIME-SET:           set local_hours=12 ⇒ the Sun is at/near its daily-MAX elevation at the point (well
##                         above the horizon, ≈ the local-noon max for the latitude); local_hours=0 ⇒ Sun below
##                         the horizon (night). Also the optional sun_elev_deg lands the Sun at that elevation.
##   G-TIME-CONSISTENT:    one offset moves EVERYTHING — Sun AND Moon AND planet spin all read the SAME clock
##                         (clock reads == direct t=base+offset reads), and Sun & Moon both actually moved.
##   G-TIME-DETERMINISTIC: offset default 0 reproduces the un-cheated direction EXACTLY (byte-identical
##       + REVERSIBLE:     baseline); set-then-reset-to-0 restores it exactly; the solve is deterministic.
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_time_cheat.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const OBS := "earth"

## Sun elevation (deg) above the local horizon at surface point `up` (body-fixed == world) at clock time t.
func _sun_elev_deg(up: Vector3, t: float) -> float:
	var s := EPH.dir_to_bodyfixed(OBS, "sun", t)
	return rad_to_deg(asin(clampf(s.dot(up.normalized()), -1.0, 1.0)))

## A surface up-vector at latitude/longitude (rad). z = spin/north axis.
func _surface_up(lat: float, lon: float) -> Vector3:
	return Vector3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))

func _new_clock(t0: float) -> EPH.CosmosClock:
	return EPH.CosmosClock.new(t0)

func _initialize() -> void:
	print("=== verify_time_cheat (DEV TIME-CHEAT: G-TIME-SET/CONSISTENT/DETERMINISTIC+REVERSIBLE) ===")
	print("  ORBITAL_SKY=%s FP_SEASONS=%s CONTROL_ENABLED=%s (gate is flag-independent; math is pure static)" % [
		str(CubeSphere.ORBITAL_SKY), str(CubeSphere.FP_SEASONS), str(RemoteBridge.CONTROL_ENABLED)])
	_gate_set()
	_gate_consistent()
	_gate_deterministic()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------------------------------------------------------------------------------------
# G-TIME-SET — noon puts the Sun high; midnight puts it below the horizon; sun_elev lands the target.
# ---------------------------------------------------------------------------------------
func _gate_set() -> void:
	var t_base := 1234.0

	# Equatorial point: noon ⇒ Sun essentially overhead (dec≈0, max elevation ≈ 90°).
	var up_eq := _surface_up(0.0, 0.7)
	var c := _new_clock(t_base)
	c.add_offset(EPH.offset_for_local_hours(OBS, up_eq, c.now(), 12.0))
	var elev_noon := _sun_elev_deg(up_eq, c.now())
	_ok(elev_noon > 40.0, "equator local_hours=12 ⇒ sun well above horizon (elev %.2f° > 40°)" % elev_noon)
	# ...and it is AT the daily max for the latitude (dec spin-invariant): max = 90 − |lat − dec|.
	var dec := rad_to_deg(asin(clampf(EPH.dir_to_bodyfixed(OBS, "sun", c.now()).z, -1.0, 1.0)))
	var max_elev := 90.0 - absf(0.0 - dec)
	_ok(absf(elev_noon - max_elev) < 0.5, "equator noon elev %.2f° ≈ daily max %.2f° (Δ<0.5°)" % [elev_noon, max_elev])
	# local_solar_hours round-trips to ≈12 after the set.
	var lsh := EPH.local_solar_hours(OBS, up_eq, c.now())
	_ok(absf(lsh - 12.0) < 0.02, "local_solar_hours after set ≈ 12 (got %.4f)" % lsh)

	# Midnight ⇒ Sun below the horizon (night).
	var c0 := _new_clock(t_base)
	c0.add_offset(EPH.offset_for_local_hours(OBS, up_eq, c0.now(), 0.0))
	var elev_mid := _sun_elev_deg(up_eq, c0.now())
	_ok(elev_mid < 0.0, "equator local_hours=0 ⇒ sun below horizon / night (elev %.2f° < 0°)" % elev_mid)

	# Mid-latitude point (30°N): noon ⇒ elev ≈ 60° (still comfortably above 40°).
	var up_mid := _surface_up(deg_to_rad(30.0), -2.1)
	var cm := _new_clock(t_base)
	cm.add_offset(EPH.offset_for_local_hours(OBS, up_mid, cm.now(), 12.0))
	var elev_mid_noon := _sun_elev_deg(up_mid, cm.now())
	_ok(elev_mid_noon > 40.0, "30°N local_hours=12 ⇒ sun high (elev %.2f° > 40°)" % elev_mid_noon)
	_ok(absf(elev_mid_noon - 60.0) < 1.0, "30°N noon elev %.2f° ≈ 60° (dec≈0)" % elev_mid_noon)

	# sun_elev_deg (optional param): request 30° at the equator ⇒ the Sun lands at 30°.
	var ce := _new_clock(t_base)
	ce.add_offset(EPH.offset_for_sun_elev(OBS, up_eq, ce.now(), 30.0))
	var elev_req := _sun_elev_deg(up_eq, ce.now())
	_ok(absf(elev_req - 30.0) < 0.5, "sun_elev_deg=30 ⇒ resulting elevation %.2f° ≈ 30° (Δ<0.5°)" % elev_req)

# ---------------------------------------------------------------------------------------
# G-TIME-CONSISTENT — ONE offset moves the whole ephemeris: sun, moon, and spin all read the same clock.
# ---------------------------------------------------------------------------------------
func _gate_consistent() -> void:
	var t_base := 8600.0
	var up := _surface_up(deg_to_rad(15.0), 1.3)
	var c := _new_clock(t_base)
	var delta := EPH.offset_for_local_hours(OBS, up, c.now(), 9.0)
	c.add_offset(delta)

	# The clock is the ONE mutable state: now() == t + offset, offset == delta.
	_ok(absf(c.offset - delta) < 1e-9, "clock.offset == applied delta (%.6f)" % delta)
	_ok(absf(c.now() - (t_base + delta)) < 1e-6, "clock.now() == base + offset (one clock)")

	# Reading through the clock == reading directly at base+delta, for sun, moon, AND spin — proving the
	# offset feeds every body uniformly (no per-body special-casing).
	var td := t_base + delta
	var sun_clk := EPH.dir_to_bodyfixed(OBS, "sun", c.now())
	var sun_dir := EPH.dir_to_bodyfixed(OBS, "sun", td)
	_ok(sun_clk == sun_dir, "sun dir via clock == direct(base+offset)")
	var moon_clk := EPH.dir_to_bodyfixed(OBS, "moon", c.now())
	var moon_dir := EPH.dir_to_bodyfixed(OBS, "moon", td)
	_ok(moon_clk == moon_dir, "moon dir via clock == direct(base+offset)")
	var spin_clk := EPH.spin_angle(OBS, c.now())
	var spin_dir := EPH.spin_angle(OBS, td)
	_ok(absf(spin_clk - spin_dir) < 1e-9, "planet spin via clock == direct(base+offset)")

	# Both Sun AND Moon actually MOVED under the single offset (not just the sun special-cased).
	if absf(delta) > 1e-3:
		var sun0 := EPH.dir_to_bodyfixed(OBS, "sun", t_base)
		var moon0 := EPH.dir_to_bodyfixed(OBS, "moon", t_base)
		_ok(sun0.distance_to(sun_clk) > 1e-5, "sun moved under the offset (Δ %.5f)" % sun0.distance_to(sun_clk))
		_ok(moon0.distance_to(moon_clk) > 1e-5, "moon moved under the offset (Δ %.5f)" % moon0.distance_to(moon_clk))
	else:
		_ok(false, "test t_base coincidentally already at target — pick another base")

# ---------------------------------------------------------------------------------------
# G-TIME-DETERMINISTIC + REVERSIBLE — offset default 0 is byte-identical; set→reset restores; solve is stable.
# ---------------------------------------------------------------------------------------
func _gate_deterministic() -> void:
	var t_base := 4321.0
	var up := _surface_up(deg_to_rad(-40.0), 2.9)

	# Default offset is exactly 0 ⇒ now() == t ⇒ un-cheated (byte-identical) baseline.
	var c := _new_clock(t_base)
	_ok(c.offset == 0.0, "CosmosClock.offset defaults to exactly 0.0 (byte-identical when unused)")
	_ok(c.now() == t_base, "now() == t with default offset (no phase shift)")
	var sun_base := EPH.dir_to_bodyfixed(OBS, "sun", t_base)
	_ok(EPH.dir_to_bodyfixed(OBS, "sun", c.now()) == sun_base, "offset-0 sun dir EXACTLY the un-cheated baseline")

	# Set a cheat offset, then reset to 0 ⇒ the baseline is restored exactly.
	c.add_offset(EPH.offset_for_local_hours(OBS, up, c.now(), 18.0))
	_ok(EPH.dir_to_bodyfixed(OBS, "sun", c.now()) != sun_base, "after a set, the sun dir differs from baseline")
	c.set_offset(0.0)
	_ok(c.now() == t_base, "set_offset(0) restores now() == t")
	_ok(EPH.dir_to_bodyfixed(OBS, "sun", c.now()) == sun_base, "set_offset(0) restores the sun dir EXACTLY")

	# Deterministic: the same inputs give the same delta; applying from two fresh clocks yields the same now().
	var d1 := EPH.offset_for_local_hours(OBS, up, t_base, 15.0)
	var d2 := EPH.offset_for_local_hours(OBS, up, t_base, 15.0)
	_ok(d1 == d2, "offset_for_local_hours is deterministic (same args ⇒ identical delta)")
	var ca := _new_clock(t_base); ca.add_offset(EPH.offset_for_local_hours(OBS, up, ca.now(), 15.0))
	var cb := _new_clock(t_base); cb.add_offset(EPH.offset_for_local_hours(OBS, up, cb.now(), 15.0))
	_ok(ca.now() == cb.now(), "two independent sets to local_hours=15 land the same now()")
