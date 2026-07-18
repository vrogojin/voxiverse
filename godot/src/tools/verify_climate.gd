extends SceneTree
## COSMOS CLIMATE gate (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §7). Headless proof of the staged
## weather/climate simulation — the MATH, the BYTES, the DETERMINISM, and the SEASON GEOMETRY that can
## be asserted without a GPU. The cloud/precip/storm LOOK and the real web worst-frame are LIVE-ONLY.
##
## Stages proven here (each independently flag-gated; every flag default-FALSE):
##   W0 FP_SEASONS      — G-SEAS-TILT (δ = ±23.4° at solstices, longer summer day), G-SEAS-PURE
##                        (worldgen never sees the clock), flag-off byte-identity, tidal-lock still green.
##   (W1+ appended as the stages land.)
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_climate.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_climate (COSMOS CLIMATE: seasons + weather grid) ===")
	print("  CubeSphere.FP_SEASONS = %s (gate proves both the flag-off byte-identity AND the flag-on math)" % str(CubeSphere.FP_SEASONS))

	_gate_seasons_tilt()
	_gate_seasons_pure()
	_gate_seasons_flag_off()
	_gate_tidal_still_locked()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-SEAS-TILT: obliquity geometry (pure, flag-independent via the _eps form) ----------
func _gate_seasons_tilt() -> void:
	print("  --- G-SEAS-TILT: subsolar latitude δ = +23.4°/0/−23.4° at solstice/equinox marks ---")
	var eps := 0.4084                                   # the table obliquity (23.4°)
	_ok(absf(float(EPH.BODIES["earth"]["axial_tilt"]) - eps) < 1.0e-6, "TILT: BODIES.earth.axial_tilt == 0.4084 rad (23.4°)")
	var year := EPH.orbit_period("earth")
	# δ at the four quarter-year marks (m0 = 0 ⇒ M = n·t; June solstice at t = year/4).
	var d_equinox0 := EPH.subsolar_latitude_eps(0.0, eps)
	var d_june := EPH.subsolar_latitude_eps(year * 0.25, eps)
	var d_equinox1 := EPH.subsolar_latitude_eps(year * 0.5, eps)
	var d_dec := EPH.subsolar_latitude_eps(year * 0.75, eps)
	_ok(absf(d_equinox0) < 1.0e-3, "TILT: δ(spring equinox) = %.4f° ≈ 0" % rad_to_deg(d_equinox0))
	_ok(absf(rad_to_deg(d_june) - 23.4) < 0.1, "TILT: δ(June solstice) = %.4f° ≈ +23.4°" % rad_to_deg(d_june))
	_ok(absf(d_equinox1) < 1.0e-3, "TILT: δ(autumn equinox) = %.4f° ≈ 0" % rad_to_deg(d_equinox1))
	_ok(absf(rad_to_deg(d_dec) + 23.4) < 0.1, "TILT: δ(Dec solstice) = %.4f° ≈ −23.4°" % rad_to_deg(d_dec))
	# Day length at 45°N: the sun is above the horizon for the fraction H/π of a rotation, where
	# cos H = −tanφ·tanδ (elevation-zero hour angle). Summer (δ=+23.4) MUST be longer than winter.
	var summer := _day_fraction(deg_to_rad(45.0), d_june)
	var winter := _day_fraction(deg_to_rad(45.0), d_dec)
	_ok(summer > 0.5 and winter < 0.5 and summer > winter, "TILT: 45°N day length — summer %.3f > 0.5 > winter %.3f (seasonal day/night)" % [summer, winter])
	# The pole axis tilts off +Z by exactly ε (fixed in inertial space).
	var pole := Vector3(0.0, -sin(eps), cos(eps))
	_ok(absf(pole.angle_to(Vector3(0, 0, 1)) - eps) < 1.0e-6, "TILT: inertial pole axis leans ε from +Z")

## Fraction of a full rotation the sun stays above the horizon at latitude φ under declination δ.
func _day_fraction(phi: float, delta: float) -> float:
	var cos_h := -tan(phi) * tan(delta)
	if cos_h <= -1.0:
		return 1.0                                      # polar day
	if cos_h >= 1.0:
		return 0.0                                      # polar night
	return acos(cos_h) / PI

# ---------- G-SEAS-PURE: worldgen never sees the seasonal clock ----------
func _gate_seasons_pure() -> void:
	print("  --- G-SEAS-PURE: generated_cell + surface_temperature are clock-independent ---")
	# Drive the seasonal phase to two opposite extremes; worldgen output must be byte-identical.
	var samples: Array[Vector3i] = []
	for i in range(64):
		samples.append(Vector3i((i * 37) % 512 - 256, (i * 13) % 48 - 8, (i * 91) % 512 - 256))
	ClimateModel.current_sin_delta = 0.95
	var h_a := _hash_cells(samples)
	var st_a := ClimateModel.surface_temperature(12, -0.6)
	ClimateModel.current_sin_delta = -0.95
	var h_b := _hash_cells(samples)
	var st_b := ClimateModel.surface_temperature(12, -0.6)
	ClimateModel.current_sin_delta = 0.0                # restore
	_ok(h_a == h_b, "PURE: generated_cell hash identical across current_sin_delta = ±0.95 (worldgen clock-free)")
	_ok(st_a == st_b, "PURE: ClimateModel.surface_temperature (the snow-cap predicate) ignores current_sin_delta")
	# The season offset itself is a pure function that DOES respond — proving it is a real, sim-only term.
	var off_summer := ClimateModel.season_offset(0.5, 0.95)
	var off_winter := ClimateModel.season_offset(0.5, -0.95)
	_ok(off_summer > 0.0 and off_winter < 0.0 and absf(off_summer + off_winter) < 1.0e-9, "PURE: season_offset warms summer (+%.2f) / cools winter (%.2f), antisymmetric" % [off_summer, off_winter])
	_ok(ClimateModel.season_offset(0.0, 0.95) == 0.0, "PURE: season_offset at the equator (sinlat=0) is exactly 0")

func _hash_cells(cells: Array[Vector3i]) -> int:
	var h := 1469598103934665603
	for c in cells:
		var v := TerrainConfig.generated_cell(c.x, c.y, c.z)
		h = (h ^ (v & 0xFFFFFFFF)) * 1099511628211
		h &= 0x7FFFFFFFFFFFFFFF
	return h

# ---------- Flag-off byte-identity: dir_to_bodyfixed collapses to the untilted kernel ----------
func _gate_seasons_flag_off() -> void:
	print("  --- FLAG-OFF: effective_tilt ≡ 0 and dir_to_bodyfixed == the shipped no-tilt formula ---")
	# With FP_SEASONS off (the shipped default), the obliquity must be inert everywhere.
	_ok(EPH.effective_tilt("earth") == 0.0, "OFF: effective_tilt('earth') == 0 (byte-identical sky/nav)")
	_ok(EPH.subsolar_latitude(1234.0) == 0.0, "OFF: subsolar_latitude ≡ 0 (no seasons drive the sim)")
	if CubeSphere.FP_SEASONS:
		return                                          # a flag-ON run legitimately skips the identity check
	# dir_to_bodyfixed must equal a manual R_z(−spin)·dir_to (i.e. NO tilt rotation) at every sample.
	var worst := 0.0
	for i in range(24):
		var t := float(i) * 137.0
		var got := EPH.dir_to_bodyfixed("earth", "sun", t)
		var di := EPH.dir_to("earth", "sun", t)
		var ang := -EPH.spin_angle("earth", t)
		var c := cos(ang)
		var s := sin(ang)
		var want := Vector3(c * di.x - s * di.y, s * di.x + c * di.y, di.z)
		worst = maxf(worst, (got - want).length())
	_ok(worst < 1.0e-6, "OFF: dir_to_bodyfixed matches the untilted R_z(−spin)·dir_to (worst Δ %s)" % worst)

# ---------- Tidal lock survives the tilt (Moon axial_tilt = 0; risk 4) ----------
func _gate_tidal_still_locked() -> void:
	print("  --- TIDAL: sub-Earth longitude of the Moon still constant across a month (tilt didn't perturb it) ---")
	var month := EPH.orbit_period("moon")
	var lon0 := EPH.sub_longitude("moon", "earth", 0.0)
	var worst := 0.0
	for i in range(401):
		var t := month * float(i) / 400.0
		var lon := EPH.sub_longitude("moon", "earth", t)
		var d := lon - lon0
		while d > PI: d -= TAU
		while d < -PI: d += TAU
		worst = maxf(worst, absf(d))
	_ok(worst < 1.0e-9, "TIDAL: sub-Earth longitude drift over a month = %s rad < 1e-9" % worst)
