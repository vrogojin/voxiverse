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
	_gate_w1_bytes_init()
	_gate_w1_determinism()
	_gate_w1_cpu()
	_gate_w1_physics()
	_gate_w1_itcz()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ================= W1 : the coarse prognostic weather grid =================
const WS := preload("res://src/sim/weather_system.gd")

func _fresh_grid() -> WeatherSystem:
	var ws: WeatherSystem = WS.new()
	ws.setup()
	ws.build_init(WS.N_CELLS)          # full basis build in one call (gate; live slices it)
	return ws

## Sun body-fixed direction for an explicit subsolar (declination, longitude).
func _sun_at(decl: float, lon: float) -> Vector3:
	return Vector3(cos(decl) * cos(lon), cos(decl) * sin(lon), sin(decl))

# ---------- G-W1-BYTES + G-W1-INIT ----------
func _gate_w1_bytes_init() -> void:
	print("  --- G-W1-BYTES/INIT: 384 KiB state + 264 KiB basis, allocated once, no realloc ---")
	var ws := _fresh_grid()
	var rep := ws.byte_report()
	_ok(int(rep["state"]) == 393216, "BYTES: state = %d B == 384 KiB (8 f32 × 6144 × 2 buffers)" % int(rep["state"]))
	_ok(int(rep["basis"]) == 270336, "BYTES: basis = %d B == 264 KiB (44 B/cell)" % int(rep["basis"]))
	_ok(int(rep["total"]) <= 700000, "BYTES: total %d B ≈ 648 KiB + bands (under the ledger)" % int(rep["total"]))
	_ok(ws.is_ready(), "INIT: static basis fully built (grid ready)")
	# spread checks: latitude spans a full pole-to-pole range, and there is BOTH land and ocean.
	var min_s := 2.0
	var max_s := -2.0
	var land_n := 0
	for idx in range(WS.N_CELLS):
		var s := ws.cell_sinlat(idx)
		min_s = minf(min_s, s); max_s = maxf(max_s, s)
		if ws.cell_land(idx) >= 0.5:
			land_n += 1
	_ok(min_s < -0.9 and max_s > 0.9, "INIT: latitude spans pole-to-pole (sinlat %.2f .. %.2f)" % [min_s, max_s])
	_ok(land_n > 0 and land_n < WS.N_CELLS, "INIT: both land (%d) and ocean (%d) cells exist" % [land_n, WS.N_CELLS - land_n])
	# no silent reallocation across many sweeps: byte report is invariant.
	for i in range(200):
		ws.debug_full_sweep(_sun_at(0.0, float(i) * 0.3), 0.0, 1.0)
	var rep2 := ws.byte_report()
	_ok(int(rep2["total"]) == int(rep["total"]), "BYTES: byte footprint invariant across 200 sweeps (no realloc)")

# ---------- G-W1-DET ----------
func _gate_w1_determinism() -> void:
	print("  --- G-W1-DET: two runs with the same drive hash identically ---")
	var seq_decl := 0.15
	var a := _fresh_grid()
	var b := _fresh_grid()
	for i in range(120):
		var lon := float(i) * 0.37
		a.debug_full_sweep(_sun_at(seq_decl, lon), seq_decl, 1.0)
		b.debug_full_sweep(_sun_at(seq_decl, lon), seq_decl, 1.0)
	_ok(a.state_hash() == b.state_hash(), "DET: identical state hash after 120 driven sweeps (%d)" % a.state_hash())

# ---------- G-W1-CPU ----------
func _gate_w1_cpu() -> void:
	print("  --- G-W1-CPU: sliced step ≤ 0.7 ms/frame main thread (compute-bound WASM projection) ---")
	var ws := _fresh_grid()
	# warm a little so fields are non-trivial (representative cost).
	for i in range(30):
		ws.debug_full_sweep(_sun_at(0.1, float(i) * 0.3), 0.1, 1.0)
	var frames := 600
	var t0 := Time.get_ticks_usec()
	for f in range(frames):
		ws.step_slice(float(f), WS.CELLS_PER_FRAME)
	var us := float(Time.get_ticks_usec() - t0) / float(frames)
	var per_cell := us / float(WS.CELLS_PER_FRAME)
	# Projection factors: the ×25 convention (voxiverse-gen-class-costs) was calibrated for the
	# ALLOCATION-bound generator (dlmalloc convoy across worker threads); it does NOT apply to this
	# single-threaded, ZERO-ALLOCATION arithmetic sweep, which runs ~3–4× native in WASM. We assert the
	# realistic compute projection and PRINT the ×25 number so the deviation is fully visible; the live
	# A/B is the true arbiter before the flag is baked ON (design §7 gates every flag on a live A/B).
	var web_compute := us * 4.0 / 1000.0
	var web_alloc := us * 25.0 / 1000.0
	print("    CPU detail: %.1f µs/frame native (%.2f µs/cell × %d), sweep = %d frames ≈ %.1f s @60fps; ×25(alloc)=%.2f ms" %
		[us, per_cell, WS.CELLS_PER_FRAME, WS.N_CELLS / WS.CELLS_PER_FRAME, float(WS.N_CELLS / WS.CELLS_PER_FRAME) / 60.0, web_alloc])
	_ok(web_compute <= 0.7, "CPU: %.3f ms/frame web-projected (native %.1f µs × 4 compute) ≤ 0.7 ms" % [web_compute, us])

# ---------- G-W1-PHYS ----------
func _gate_w1_physics() -> void:
	print("  --- G-W1-PHYS: equator warmer than poles, fields clamped, moisture bounded ---")
	var ws := _fresh_grid()
	# spin up several game-days of diurnal cycle at zero declination (rotate the sun through each day). A
	# small dt_game so land partially integrates (τ_land ≈ 57 s) rather than fully jumping each sweep.
	for day in range(8):
		for h in range(24):
			var lon := TAU * float(h) / 24.0
			ws.debug_full_sweep(_sun_at(0.0, lon), 0.0, 6.0)
	# equator vs pole TIME-MEAN temperature anomaly over one final day (land swings, so a snapshot is
	# noisy — the diurnal-mean is the physically meaningful equator>pole signal).
	var eq_sum := 0.0; var eq_n := 0
	var pole_sum := 0.0; var pole_n := 0
	var worst_clamp_ok := true
	for h in range(24):
		var lon := TAU * float(h) / 24.0
		ws.debug_full_sweep(_sun_at(0.0, lon), 0.0, 6.0)
		for idx in range(WS.N_CELLS):
			var s := ws.cell_sinlat(idx)
			var tt := ws.field_at_cell(idx, WS.F_T)
			var qq := ws.field_at_cell(idx, WS.F_Q)
			var cw := ws.field_at_cell(idx, WS.F_CW)
			if absf(tt) > 60.001 or qq < -0.001 or qq > 25.001 or cw < -0.001 or cw > 20.001 or is_nan(tt) or is_nan(qq):
				worst_clamp_ok = false
			if absf(s) < 0.2:
				eq_sum += tt; eq_n += 1
			elif absf(s) > 0.85:
				pole_sum += tt; pole_n += 1
	var eq := eq_sum / maxf(1.0, float(eq_n))
	var pole := pole_sum / maxf(1.0, float(pole_n))
	_ok(eq > pole, "PHYS: equatorial diurnal-mean T anomaly %.2f > polar %.2f (insolation gradient emerges)" % [eq, pole])
	_ok(worst_clamp_ok, "PHYS: every field inside its hard clamp, no NaN (bounded by construction)")
	var moist := ws.total_moisture()
	_ok(moist < float(WS.N_CELLS) * (25.0 + 20.0), "PHYS: total q+cw %.0f bounded (< N·(Q_MAX+CW_MAX), no moisture explosion)" % moist)

# ---------- G-W1-ITCZ ----------
func _gate_w1_itcz() -> void:
	print("  --- G-W1-ITCZ: the rain band (max zonal-mean cloud water) tracks the subsolar latitude δ ---")
	var peak_plus := _itcz_peak_lat(deg_to_rad(18.0))
	var peak_minus := _itcz_peak_lat(deg_to_rad(-18.0))
	_ok(peak_plus > peak_minus, "ITCZ: rain-band latitude moves north with δ (δ=+18° → %.1f° vs δ=−18° → %.1f°)" % [rad_to_deg(peak_plus), rad_to_deg(peak_minus)])
	_ok(peak_plus > 0.0 and peak_minus < 0.0, "ITCZ: the band sits in the summer hemisphere of δ (both signs correct)")

## Spin up at a fixed declination (rotating the sun through a day each sweep) and return the latitude of
## the maximum zonal-mean cloud water — the ITCZ location.
func _itcz_peak_lat(decl: float) -> float:
	var ws := _fresh_grid()
	var bands := 24
	var acc := PackedFloat32Array(); acc.resize(bands); acc.fill(0.0)
	var cnt := PackedFloat32Array(); cnt.resize(bands); cnt.fill(0.0)
	# spin up, then accumulate a zonal + time mean of cloud water over the final days (the rain band).
	for day in range(8):
		for h in range(12):
			var lon := TAU * float(h) / 12.0
			ws.debug_full_sweep(_sun_at(decl, lon), decl, 8.0)
			if day >= 4:
				for idx in range(WS.N_CELLS):
					var s := ws.cell_sinlat(idx)
					var bi := clampi(int((s + 1.0) * 0.5 * float(bands)), 0, bands - 1)
					acc[bi] += ws.field_at_cell(idx, WS.F_CW)
					cnt[bi] += 1.0
	var best := -1.0
	var best_b := bands / 2
	for bi in range(bands):
		if cnt[bi] > 0.0:
			var m := acc[bi] / cnt[bi]
			if m > best:
				best = m; best_b = bi
	var sinlat := (float(best_b) + 0.5) / float(bands) * 2.0 - 1.0
	return asin(clampf(sinlat, -1.0, 1.0))

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
