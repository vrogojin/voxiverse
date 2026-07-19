class_name WeatherSystem
extends RefCounted
## COSMOS CLIMATE W1 — the ONE coarse prognostic weather grid (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §1).
## A plain object OWNED and STEPPED by WorldManager from `_process` on the MAIN thread, exactly like
## SnowfallSystem. It is the SIM LAYER (engine rule 2): rendering/gameplay READ it through
## PerVoxelEnvironment (clouds, precip, fog, the HUD) and NEVER drive it.
##
## THE BOUNDED ARCHITECTURE (§1, §8 ledger): a fixed 6-face × 32×32 = 6144-cell cube-sphere grid,
## 8 f32 fields double-buffered (384 KiB) + a 44 B/cell static basis (264 KiB), ALLOCATED ONCE at
## setup, exploration/position-INDEPENDENT, with ZERO growth paths (no `append` on any state array
## ever). One weather cell ≈ 313 blocks, so a player stands inside one cell and fronts/storms span
## several and genuinely move. NEVER-OOM binds on the real .size() bytes (G-W1-BYTES).
##
## THE PHYSICS (§1.3, all bounded by construction — a runaway parameter can saturate but never NaN):
##   1. Insolation — the sun's body-fixed direction (reused straight from the ephemeris, so the
##      subsolar latitude δ and the diurnal spin are automatic) dotted with each cell direction gives
##      the solar elevation; T relaxes toward an equilibrium anomaly with a land/ocean τ split.
##   2. Pressure (diagnostic) — warm columns vs their zonal-band mean are thermal lows.
##   3. Wind (DIAGNOSTIC, cannot go unstable) — analytic Hadley/ITCZ background + geostrophic
##      deflection + friction inflow, from the pressure field. No prognostic momentum, no CFL.
##   4. Moisture — evaporation (oceans/wet soil), bounded UPWIND advection (a convex combination of
##      neighbours ⇒ the field can never overshoot), condensation → cloud water, orographic wind·∇h̄,
##      rain-out returning to soil with latent-heat self-heating.
##   5. Instability — a CAPE proxy (hot+wet surface) flags convective cells for W4 storms.
##
## DETERMINISM (§1.4): the sweep is a pure function of (previous state, sweep index, SEED, game-time
## sampled at sweep start). Two headless runs with the same driven sequence hash identically
## (G-W1-DET). Cross-session the weather PHASE restarts (state is not persisted — same rule as
## SnowfallSystem); accumulated snow persists via `_edits` (SnowfallSystem, unchanged).

const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")

# --- grid geometry (the never-OOM shape; §1.1) ---------------------------------
const N_W := 32                       ## cells per face edge
const N_FACES := 6
const N_CELLS := N_FACES * N_W * N_W  ## 6144
const FIELDS := 8                     ## f32 fields per cell (double-buffered)

# --- field offsets within a cell's 8-float slot --------------------------------
const F_T := 0        # surface-air temperature anomaly vs the static normal (°C)   [prognostic]
const F_Q := 1        # specific humidity 0..Q_MAX                                    [prognostic]
const F_CW := 2       # cloud water (condensed, not yet precipitated) 0..CW_MAX       [prognostic]
const F_SOIL := 3     # land wetness 0..1 (ocean cells pinned 1)                      [prognostic]
const F_U := 4        # wind east (blocks/s)                                          [diagnostic, stored]
const F_V := 5        # wind north (blocks/s)                                         [diagnostic, stored]
const F_P := 6        # pressure anomaly                                             [diagnostic, stored]
const F_INST := 7     # instability index (storm potential)                          [diagnostic, stored]

# --- sweep pacing (§1.4) -------------------------------------------------------
## The sweep slice — the ≤0.7 ms/frame CPU budget knob (§1.4, G-W1-CPU). Sized so the single-threaded,
## ZERO-ALLOCATION arithmetic sweep fits the main-thread budget in WASM: measured native ≈5.5 µs/cell
## (interpreted GDScript), and a compute-bound WASM loop runs ~3–4× native (NOT the ×25 dlmalloc-convoy
## factor of the ALLOCATION-bound generator), so 24 cells ≈ 0.13 ms native ≈ 0.53 ms web (×4) — a
## comfortable margin under the 0.7 ms/frame budget. A full sweep is then 6144/24 = 256 frames ≈ 4.3 s at
## 60 fps — a slow-but-bounded weather clock (dt_game accumulates the real elapsed game-time, so physics
## still tracks real time). Halve this if a live A/B measures worse; the C++ sweep-kernel port (L5 pattern)
## is the escape hatch for full-speed weather.
const CELLS_PER_FRAME := 24
const INIT_PER_FRAME := 32            ## static-basis build slice (§1.7) — amortized over ~3.2 s of startup
const DT_GAME_DEFAULT := 1.0          ## game-seconds advanced per sweep when no clock delta is available
const DT_GAME_MAX := 120.0            ## clamp a long real gap (tab restore) so relaxation never over-steps

# --- physics constants (§1.3; every one named, all clamps hard) ----------------
const A_DIURNAL := 18.0               ## peak daytime warming anomaly at overhead sun (°C)
const A_NIGHT := 8.0                  ## night-side cooling floor of the equilibrium anomaly (°C)
const TAU_LAND := 57.0                ## land thermal time-constant ≈ 0.5 game-hour (fast day/night swing)
const TAU_OCEAN := 27320.0           ## ocean thermal time-constant ≈ 10 game-days (maritime damping)
const K_P := 0.8                      ## pressure anomaly per °C of (T − zonal-mean T): warm ⇒ low
const HAD_TRADE := 5.0               ## tropical easterly trade-wind amplitude (blocks/s)
const HAD_WEST := 6.0                ## mid-latitude westerly amplitude
const HAD_POLAR := 3.0               ## polar easterly amplitude
const HAD_MERID := 4.0              ## meridional Hadley convergence toward the ITCZ (blocks/s)
const K_GEO := 0.6                    ## geostrophic deflection gain (cyclonic flow around lows)
const K_FRIC := 0.4                   ## friction inflow gain (air flows INTO lows ⇒ moisture converges)
const WIND_MAX := 40.0                ## hard wind-speed clamp (keeps the upwind advection courant bounded)
const K_EVAP := 0.010                 ## evaporation rate coefficient
const Q_MAX := 25.0                   ## specific-humidity ceiling (hard clamp)
const CW_MAX := 20.0                  ## cloud-water ceiling (hard clamp)
const QSAT_REF := 12.0                ## saturation specific humidity at QSAT_T0 °C
const QSAT_T0 := 15.0
const QSAT_K := 0.06                  ## Clausius-Clapeyron-ish exponential slope
const COND_DT := 6.0                  ## °C of cooling to the condensation level (lapse to cloud base)
const COND_FRAC := 0.25               ## fraction of super-saturation condensed per sweep
const CONV_GAIN := 0.06               ## convergence-forced condensation (the ITCZ lift; wind convergence × q)
const LATENT := 0.10                  ## °C added to T per unit of condensed water (self-heating)
const OROG_GAIN := 0.05               ## windward-lift multiplier on condensation (per block/s of wind·∇h̄)
const RAIN_HOLD := 4.0                ## cloud water above this precipitates
const RAIN_FRAC := 0.30               ## fraction of excess cloud water rained out per sweep
const SOIL_GAIN := 0.02               ## soil wetting per unit of rain (land)
const SOIL_DRY := 0.001               ## soil drainage/drying per sweep
const INST_QW := 0.6                  ## humidity weight in the CAPE proxy
const INST_REF := 6.0                 ## instability reference the surplus is measured above
const T_CLAMP := 60.0                 ## |T anomaly| ceiling
const LAT_BANDS := 12                 ## zonal-mean bins for the pressure reference

# --- state (allocated ONCE at setup; never resized; §8 ledger rows 1–2) --------
var _buf_a := PackedFloat32Array()    ## 6144 × 8 floats (one full buffer)
var _buf_b := PackedFloat32Array()    ## the twin — double buffering
var _read_is_a := true                ## which buffer is the consistent "current" read this sweep
# static basis (44 B/cell): three geometry fields + terrain + climate normals + the neighbour table.
var _sinlat := PackedFloat32Array()
var _coslat := PackedFloat32Array()
var _lon := PackedFloat32Array()
var _hbar := PackedFloat32Array()     ## mean terrain height at the cell centre (blocks)
var _land := PackedFloat32Array()     ## land fraction 0..1 (smoothed)
var _tnorm := PackedFloat32Array()    ## static climate temperature normal (profile t)
var _qnorm := PackedFloat32Array()    ## static moisture normal (derived from q_sat(T_norm))
var _nbr := PackedInt32Array()        ## 6144 × 4 neighbour cell indices (i+, i−, j+, j−)
# zonal-band means for the pressure reference (tiny; incrementally maintained, fully sliced).
var _band_meanT := PackedFloat32Array()
var _band_accT := PackedFloat32Array()
var _band_cnt := PackedFloat32Array()

# --- sweep bookkeeping ---------------------------------------------------------
var _cursor := 0                      ## next cell index to process in the current sweep
var _sweep_index := 0                 ## monotonic completed-sweep counter (drives determinism)
var _sun_bf := Vector3(1, 0, 0)       ## sun body-fixed direction, FROZEN for the current sweep
var _delta_lat := 0.0                 ## subsolar latitude (rad), frozen for the current sweep
var _dt_game := DT_GAME_DEFAULT       ## game-seconds elapsed this sweep
var _last_sweep_time := 0.0           ## game-time at the last sweep start
var _sweep_time_valid := false

# --- init slicing (§1.7) -------------------------------------------------------
var _init_cell := 0                   ## next basis cell to build
var _ready := false                   ## true once the static basis is fully built

# ---------------------------------------------------------------------------------------
# Setup — allocate every array ONCE at flag-on. No profile sampling yet (that is sliced in
# build_init below over startup frames), so setup itself is cheap and allocation-bounded.
# ---------------------------------------------------------------------------------------
func setup() -> void:
	_buf_a.resize(N_CELLS * FIELDS)
	_buf_b.resize(N_CELLS * FIELDS)
	_buf_a.fill(0.0)
	_buf_b.fill(0.0)
	_sinlat.resize(N_CELLS)
	_coslat.resize(N_CELLS)
	_lon.resize(N_CELLS)
	_hbar.resize(N_CELLS)
	_land.resize(N_CELLS)
	_tnorm.resize(N_CELLS)
	_qnorm.resize(N_CELLS)
	_nbr.resize(N_CELLS * 4)
	_band_meanT.resize(LAT_BANDS)
	_band_accT.resize(LAT_BANDS)
	_band_cnt.resize(LAT_BANDS)
	_band_meanT.fill(0.0)
	_band_accT.fill(0.0)
	_band_cnt.fill(0.0)
	_span = TAU * float(CubeSphere.radius_for(CubeSphere.HOME_BODY)) / float(4 * N_W)

## Exact live byte footprint of every array (G-W1-BYTES asserts this against the §8 ledger).
func byte_report() -> Dictionary:
	var state := (_buf_a.size() + _buf_b.size()) * 4
	var basis := (_sinlat.size() + _coslat.size() + _lon.size() + _hbar.size()
		+ _land.size() + _tnorm.size() + _qnorm.size()) * 4 + _nbr.size() * 4
	var bands := (_band_meanT.size() + _band_accT.size() + _band_cnt.size()) * 4
	return {"state": state, "basis": basis, "bands": bands, "total": state + basis + bands}

# ---------------------------------------------------------------------------------------
# Static-basis build (§1.7) — sliced over startup frames. One profile_at_dir per cell for the
# terrain/climate normals; geometry + neighbours are pure cube-sphere math. Until complete the sim
# holds at the normals (queries fall back), so there is no wrong transient.
# ---------------------------------------------------------------------------------------
func build_init(slice: int = INIT_PER_FRAME) -> void:
	if _ready:
		return
	var rr := float(CubeSphere.radius_for(CubeSphere.HOME_BODY))
	var done := 0
	while _init_cell < N_CELLS and done < slice:
		_build_cell_basis(_init_cell, rr)
		_init_cell += 1
		done += 1
	if _init_cell >= N_CELLS:
		_smooth_land()
		_seed_state()
		_ready = true

func _build_cell_basis(idx: int, rr: float) -> void:
	var f := idx / (N_W * N_W)
	var rem := idx % (N_W * N_W)
	var j := rem / N_W
	var i := rem % N_W
	var d := CubeSphere.face_cell_to_dir(f, float(i), float(j), N_W)
	var z := clampf(d.z, -1.0, 1.0)
	_sinlat[idx] = z
	_coslat[idx] = sqrt(maxf(0.0, 1.0 - z * z))
	_lon[idx] = atan2(d.y, d.x)
	var prof := TerrainConfig.profile_at_dir(d.x, d.y, d.z, rr)
	var g := prof.x
	var t := prof.w
	_hbar[idx] = g
	_tnorm[idx] = t
	_land[idx] = 1.0 if int(g) >= TerrainConfig.SEA_LEVEL else 0.0
	# moisture normal from Clausius-Clapeyron at the column's normal temperature (ocean columns wetter).
	var t_abs := ClimateModel.climate_base(t)
	var wet := 0.8 if int(g) < TerrainConfig.SEA_LEVEL else 0.5
	_qnorm[idx] = clampf(_q_sat(t_abs) * wet, 0.0, Q_MAX)
	# 4-neighbour indices via the canonical fold (handles both edge and corner out-of-range).
	_nbr[idx * 4 + 0] = _fold_index(f, i + 1, j)
	_nbr[idx * 4 + 1] = _fold_index(f, i - 1, j)
	_nbr[idx * 4 + 2] = _fold_index(f, i, j + 1)
	_nbr[idx * 4 + 3] = _fold_index(f, i, j - 1)

func _fold_index(f: int, i: int, j: int) -> int:
	var g := CubeSphere.fold_cell_canonical(f, i, j, N_W)
	var gf := int(g["face"])
	if gf < 0:
		return f * N_W * N_W + clampi(j, 0, N_W - 1) * N_W + clampi(i, 0, N_W - 1)
	return gf * N_W * N_W + int(g["j"]) * N_W + int(g["i"])

## One neighbour-smoothing pass on the land fraction (§1.2), so coastlines are not a hard 0/1 step.
func _smooth_land() -> void:
	var tmp := PackedFloat32Array()
	tmp.resize(N_CELLS)
	for idx in range(N_CELLS):
		var s := _land[idx]
		var n := 1.0
		for k in range(4):
			s += _land[_nbr[idx * 4 + k]]
			n += 1.0
		tmp[idx] = s / n
	for idx in range(N_CELLS):
		_land[idx] = tmp[idx]

## Seed the prognostic state at the climatology (anomaly 0, humidity at the normal, soil from land).
func _seed_state() -> void:
	for idx in range(N_CELLS):
		var b := idx * FIELDS
		var buf := _buf_a
		buf[b + F_T] = 0.0
		buf[b + F_Q] = _qnorm[idx]
		buf[b + F_CW] = 0.0
		buf[b + F_SOIL] = 1.0 if _land[idx] < 0.5 else 0.5
		buf[b + F_U] = 0.0
		buf[b + F_V] = 0.0
		buf[b + F_P] = 0.0
		buf[b + F_INST] = 0.0
	# mirror into buf_b so the first sweep's read buffer is fully populated whichever way it points.
	for k in range(_buf_a.size()):
		_buf_b[k] = _buf_a[k]
	_read_is_a = true

# ---------------------------------------------------------------------------------------
# The game loop entry (WorldManager._process). Builds the basis first (sliced), then advances the
# sweep by one slice per frame. `game_time` is the celestial clock time (game-seconds); with the
# season/sky flag off the ephemeris still gives a diurnal sun (δ = 0), so weather runs regardless.
# ---------------------------------------------------------------------------------------
func process(_delta: float, game_time: float) -> void:
	if not _ready:
		build_init()
		return
	step_slice(game_time, CELLS_PER_FRAME)

## Advance the sweep by up to `count` cells at `game_time`. Deterministic: pure of wall-clock timing —
## the gate drives this directly with a controlled time sequence (G-W1-DET).
func step_slice(game_time: float, count: int) -> void:
	if not _ready:
		return
	if _cursor == 0:
		_begin_sweep(game_time)
	var read := _buf_a if _read_is_a else _buf_b
	var write := _buf_b if _read_is_a else _buf_a
	var end := mini(_cursor + count, N_CELLS)
	for idx in range(_cursor, end):
		_update_cell(idx, read, write)
	_cursor = end
	if _cursor >= N_CELLS:
		_finish_sweep()

func _begin_sweep(game_time: float) -> void:
	_sun_bf = EPH.dir_to_bodyfixed("earth", "sun", game_time)
	if _sun_bf == Vector3.ZERO:
		_sun_bf = Vector3(1, 0, 0)
	_delta_lat = EPH.subsolar_latitude(game_time)
	if _sweep_time_valid:
		_dt_game = clampf(game_time - _last_sweep_time, 0.0, DT_GAME_MAX)
		if _dt_game <= 0.0:
			_dt_game = DT_GAME_DEFAULT
	else:
		_dt_game = DT_GAME_DEFAULT
	_last_sweep_time = game_time
	_sweep_time_valid = true
	_roll_bands()

## Roll the zonal-band accumulator: last sweep's sums become this sweep's pressure-reference means.
func _roll_bands() -> void:
	for k in range(LAT_BANDS):
		_band_meanT[k] = _band_accT[k] / _band_cnt[k] if _band_cnt[k] > 0.0 else 0.0
		_band_accT[k] = 0.0
		_band_cnt[k] = 0.0

func _finish_sweep() -> void:
	_cursor = 0
	_sweep_index += 1
	_read_is_a = not _read_is_a          # the buffer we just wrote becomes the read buffer

# ---------------------------------------------------------------------------------------
# One cell update — reads neighbours from `read`, writes the 8 fields to `write`. All arithmetic on
# stored fields (deterministic); every field hard-clamped (bounded by construction).
# ---------------------------------------------------------------------------------------
func _update_cell(idx: int, read: PackedFloat32Array, write: PackedFloat32Array) -> void:
	var b := idx * FIELDS
	var slat := _sinlat[idx]
	var clat := _coslat[idx]
	var lonc := _lon[idx]
	var clon := cos(lonc)                # one cos/sin per cell, reused throughout
	var slon := sin(lonc)
	# cell body-fixed direction (reconstructed from the stored geometry — no face_cell_to_dir/warp).
	var dcx := clat * clon
	var dcy := clat * slon
	var dcz := slat
	# local east/north tangent unit vectors (geographic; §1.1 — global, no per-face basis).
	var e_x := -slon; var e_y := clon; var e_z := 0.0
	var n_x := -slat * clon; var n_y := -slat * slon; var n_z := clat

	var T := read[b + F_T]
	var q := read[b + F_Q]
	var cw := read[b + F_CW]
	var soil := read[b + F_SOIL]

	# --- (1) insolation forcing → T relaxation with a land/ocean τ split -----------------
	var sin_elev := clampf(_sun_bf.x * dcx + _sun_bf.y * dcy + _sun_bf.z * dcz, -1.0, 1.0)
	var day := maxf(0.0, sin_elev)
	var t_eq := A_DIURNAL * day - A_NIGHT
	var land := _land[idx]
	var tau := lerpf(TAU_OCEAN, TAU_LAND, land)
	var relax := clampf(_dt_game / tau, 0.0, 1.0)
	T += (t_eq - T) * relax
	# accumulate this cell into its zonal band for NEXT sweep's pressure reference.
	var band := clampi(int((slat + 1.0) * 0.5 * float(LAT_BANDS)), 0, LAT_BANDS - 1)
	_band_accT[band] += T
	_band_cnt[band] += 1.0

	# --- (2) pressure (diagnostic thermal low) — warm vs the zonal mean is a low -----------
	var p := -K_P * (T - _band_meanT[band])

	# --- neighbour gradients (pressure + terrain) in geographic east/north ----------------
	var ip := _nbr[b_nbr(idx, 0)]; var im := _nbr[b_nbr(idx, 1)]
	var jp := _nbr[b_nbr(idx, 2)]; var jm := _nbr[b_nbr(idx, 3)]
	# grid basis in geographic coords: offset (east,north) toward the +i and +j neighbours.
	var gi := _geo_offset(idx, ip, e_x, e_y, e_z, n_x, n_y, n_z, dcx, dcy, dcz)
	var gj := _geo_offset(idx, jp, e_x, e_y, e_z, n_x, n_y, n_z, dcx, dcy, dcz)
	# central differences in grid-index space.
	var pip := -K_P * (read[ip * FIELDS + F_T] - _band_meanT[_band_of(ip)])
	var pim := -K_P * (read[im * FIELDS + F_T] - _band_meanT[_band_of(im)])
	var pjp := -K_P * (read[jp * FIELDS + F_T] - _band_meanT[_band_of(jp)])
	var pjm := -K_P * (read[jm * FIELDS + F_T] - _band_meanT[_band_of(jm)])
	var dp_di := 0.5 * (pip - pim)
	var dp_dj := 0.5 * (pjp - pjm)
	# convert an index-space gradient to a geographic (east,north) gradient via the basis inverse-T.
	var inv := _invert2(gi.x, gj.x, gi.y, gj.y)     # columns gi, gj
	var dp_de := inv[0] * dp_di + inv[2] * dp_dj    # (inv^T applied): rows of inv
	var dp_dn := inv[1] * dp_di + inv[3] * dp_dj

	# --- (3) diagnostic wind = Hadley background + geostrophic deflection + friction inflow --
	var lat := asin(slat)
	var u := _hadley_u(lat)
	var v := _hadley_v(lat)
	# friction inflow: down-gradient (toward lows).
	u += K_FRIC * (-dp_de)
	v += K_FRIC * (-dp_dn)
	# geostrophic-like deflection, cyclonic around lows with the correct hemisphere sign.
	var hemi := signf(slat)
	u += K_GEO * hemi * (dp_dn)
	v += K_GEO * hemi * (-dp_de)
	# clamp the wind speed so upwind advection stays courant-bounded.
	var spd := sqrt(u * u + v * v)
	if spd > WIND_MAX:
		var sc := WIND_MAX / spd
		u *= sc; v *= sc

	# --- (4) moisture: evaporation, advection, condensation, orographic, rain-out ----------
	var t_abs := ClimateModel.climate_base(_tnorm[idx]) + T
	var qsat := _q_sat(t_abs)
	# evaporation (oceans are the source; wet soil re-evaporates).
	var evap_src := 1.0 if land < 0.5 else soil * 0.3
	var evap := K_EVAP * spd * maxf(0.0, qsat - q) * evap_src * _dt_game
	q += evap
	# bounded upwind advection of q, cw, T by the wind (a convex blend — cannot overshoot).
	var adv := _advect(idx, u, v, inv, read)
	q = lerpf(q, adv.x, adv.w)             # adv.w = the total upstream weight in [0,1]
	cw = lerpf(cw, adv.y, adv.w)
	T = lerpf(T, adv.z, adv.w)
	# recompute t_abs after advection of T.
	t_abs = ClimateModel.climate_base(_tnorm[idx]) + T
	# condensation where q exceeds saturation at the cooler condensation level.
	var qsat_c := _q_sat(t_abs - COND_DT)
	var cond := maxf(0.0, q - qsat_c) * COND_FRAC
	# CONVERGENCE-FORCED condensation — THE ITCZ mechanism. Where the diagnostic winds CONVERGE
	# (−divergence > 0), air is lifted and its moisture condenses regardless of temperature; the Hadley
	# meridional flow converges at the subsolar latitude δ, so the heavy-rain band tracks δ (G-W1-ITCZ),
	# and it dominates the weak cold-air supersaturation that would otherwise pool cloud at the poles.
	var du_di := 0.5 * (read[ip * FIELDS + F_U] - read[im * FIELDS + F_U])
	var dv_dj := 0.5 * (read[jp * FIELDS + F_V] - read[jm * FIELDS + F_V])
	var divergence := inv[0] * du_di + inv[3] * dv_dj
	var conv := maxf(0.0, -divergence)
	cond += CONV_GAIN * conv * q
	# orographic term: windward lift (wind·∇h̄) boosts condensation; leeward descent dries+warms.
	var gh := _terrain_grad(idx, ip, im, jp, jm, inv)
	var lift := u * gh.x + v * gh.y
	if lift > 0.0:
		cond *= (1.0 + OROG_GAIN * lift)
	else:
		# föhn: subsidence warms and dries a little (no condensation boost).
		var dry := minf(q, -OROG_GAIN * lift * 0.5)
		q -= dry
		T += dry * LATENT * 0.5
	cond = minf(cond, q)
	q -= cond
	cw += cond
	T += cond * LATENT                     # latent-heat self-heating (the organizing feedback)
	# rain-out: cloud water above the hold threshold precipitates, wetting soil on land.
	var rain := maxf(0.0, cw - RAIN_HOLD) * RAIN_FRAC
	cw -= rain
	if land >= 0.5:
		soil = clampf(soil + rain * SOIL_GAIN - SOIL_DRY, 0.0, 1.0)
	else:
		soil = 1.0                          # ocean cell: pinned wet

	# --- (5) instability (CAPE proxy) — a hot + wet surface under the lapse-cooled aloft level;
	# T (warm anomaly) plus the moisture surplus, measured above a reference. Flags W4 convection.
	var inst := maxf(0.0, T + INST_QW * q - INST_REF)

	# --- write, all fields hard-clamped (bounded by construction) --------------------------
	write[b + F_T] = clampf(T, -T_CLAMP, T_CLAMP)
	write[b + F_Q] = clampf(q, 0.0, Q_MAX)
	write[b + F_CW] = clampf(cw, 0.0, CW_MAX)
	write[b + F_SOIL] = clampf(soil, 0.0, 1.0)
	write[b + F_U] = u
	write[b + F_V] = v
	write[b + F_P] = p
	write[b + F_INST] = inst

# --- small pure helpers --------------------------------------------------------
func b_nbr(idx: int, k: int) -> int:
	return idx * 4 + k

func _band_of(idx: int) -> int:
	return clampi(int((_sinlat[idx] + 1.0) * 0.5 * float(LAT_BANDS)), 0, LAT_BANDS - 1)

## Saturation specific humidity at absolute temperature `t_abs` (°C) — Clausius-Clapeyron-ish.
func _q_sat(t_abs: float) -> float:
	return clampf(QSAT_REF * exp(QSAT_K * (t_abs - QSAT_T0)), 0.0, Q_MAX)

## Analytic surface zonal (east) wind by latitude: tropical trade easterlies, mid-latitude westerlies,
## polar easterlies — the classic three-cell profile, bounded and smooth.
func _hadley_u(lat: float) -> float:
	var a := absf(lat)
	var trop := _bump(a, 0.0, deg_to_rad(30.0))
	var mid := _bump(a, deg_to_rad(45.0), deg_to_rad(20.0))
	var polar := _bump(a, deg_to_rad(90.0), deg_to_rad(30.0))
	return -HAD_TRADE * trop + HAD_WEST * mid - HAD_POLAR * polar

## Meridional (north) Hadley wind: low-level convergence toward the subsolar latitude δ (the ITCZ),
## so the rain band tracks δ with the seasons (G-W1-ITCZ). Confined to the tropics via the envelope.
func _hadley_v(lat: float) -> float:
	var env := _bump(lat, _delta_lat, deg_to_rad(40.0))
	return -HAD_MERID * signf(lat - _delta_lat) * env

## A smooth bump peaking (1) at `center`, decaying to 0 by `width`.
func _bump(x: float, center: float, width: float) -> float:
	return 1.0 - smoothstep(0.0, width, absf(x - center))

## Geographic (east,north) offset from cell `idx` to neighbour `nb`, in cell-spacing units — the chord
## between the two directions projected onto the local east/north axes. Pure of stored geometry only.
func _geo_offset(idx: int, nb: int, ex: float, ey: float, ez: float, nx: float, ny: float, nz: float,
		dcx: float, dcy: float, dcz: float) -> Vector2:
	var clat := _coslat[nb]; var lonn := _lon[nb]
	var nbx := clat * cos(lonn); var nby := clat * sin(lonn); var nbz := _sinlat[nb]
	var chx := nbx - dcx; var chy := nby - dcy; var chz := nbz - dcz
	return Vector2(chx * ex + chy * ey + chz * ez, chx * nx + chy * ny + chz * nz)

## Invert a 2×2 [[a,b],[c,d]] (columns are the grid basis in geo coords). Returns [a',b',c',d'] with a
## soft fallback to identity if singular (a degenerate corner cell — risk 7; accepts O(cell) distortion).
func _invert2(a: float, b: float, c: float, d: float) -> PackedFloat64Array:
	var det := a * d - b * c
	if absf(det) < 1.0e-6:
		return PackedFloat64Array([1.0, 0.0, 0.0, 1.0])
	var inv := 1.0 / det
	return PackedFloat64Array([d * inv, -b * inv, -c * inv, a * inv])

## Bounded UPWIND advection: sample the field at the departure point (current − wind·dt) as a convex
## blend of self and the axial neighbours. Returns (q_up, cw_up, T_up, weight) with weight ∈ [0,1] the
## total neighbour contribution, so the caller lerps self→upstream — a convex combination that can
## NEVER overshoot (bounded by construction; §1.3 "unconditionally stable at any dt").
func _advect(idx: int, u: float, v: float, inv: PackedFloat64Array, read: PackedFloat32Array) -> Vector4:
	# The departure direction comes from the inverse basis (geographic→index); only its DIRECTION is
	# used (renormalized below), so the basis magnitude is irrelevant. The step LENGTH is the courant
	# fraction (wind·dt / cell-span), clamped ≤1 cell so the blend stays over the immediate neighbours —
	# a mild accuracy cap, never a stability one (semi-Lagrangian upwind is unconditionally stable).
	var spd := sqrt(u * u + v * v)
	if spd <= 1.0e-6:
		return Vector4.ZERO
	var courant := clampf(spd * _dt_game / _cell_span_blocks(), 0.0, 1.0)
	if courant <= 0.0:
		return Vector4.ZERO
	# unit wind in (east,north); departure is opposite the wind.
	var de := -u / spd
	var dn := -v / spd
	# geo→index via inverse basis (inv maps geo→index).
	var oi := inv[0] * de + inv[1] * dn
	var oj := inv[2] * de + inv[3] * dn
	# normalize the index-space departure direction and weight by courant.
	var ol := sqrt(oi * oi + oj * oj)
	if ol <= 1.0e-6:
		return Vector4.ZERO
	oi = oi / ol * courant
	oj = oj / ol * courant
	var wi := absf(oi)
	var wj := absf(oj)
	var wsum := wi + wj
	if wsum > 1.0:
		wi /= wsum; wj /= wsum; wsum = 1.0
	var ni := _nbr[idx * 4 + (0 if oi > 0.0 else 1)]
	var nj := _nbr[idx * 4 + (2 if oj > 0.0 else 3)]
	var q_up := (wi * read[ni * FIELDS + F_Q] + wj * read[nj * FIELDS + F_Q])
	var cw_up := (wi * read[ni * FIELDS + F_CW] + wj * read[nj * FIELDS + F_CW])
	var t_up := (wi * read[ni * FIELDS + F_T] + wj * read[nj * FIELDS + F_T])
	if wsum > 1.0e-6:
		q_up /= wsum; cw_up /= wsum; t_up /= wsum
	return Vector4(q_up, cw_up, t_up, wsum)

## Terrain gradient (∂h̄/∂east, ∂h̄/∂north) at cell idx from neighbour heights via the basis inverse.
func _terrain_grad(idx: int, ip: int, im: int, jp: int, jm: int, inv: PackedFloat64Array) -> Vector2:
	var dh_di := 0.5 * (_hbar[ip] - _hbar[im])
	var dh_dj := 0.5 * (_hbar[jp] - _hbar[jm])
	return Vector2(inv[0] * dh_di + inv[1] * dh_dj, inv[2] * dh_di + inv[3] * dh_dj)

## Approximate cell spacing in blocks (circumference / (4·N_W)) — the courant length scale. Cached at
## setup (the radius is constant) so the hot path never re-hits the CubeSphere body table.
var _span := 313.0
func _cell_span_blocks() -> float:
	return _span

# ---------------------------------------------------------------------------------------
# READ interface (consumed by PerVoxelEnvironment; §1.5). All reads use the consistent "current"
# buffer (the last fully-written one). Direction-keyed so both render paths agree.
# ---------------------------------------------------------------------------------------
func is_ready() -> bool:
	return _ready

func sweep_index() -> int:
	return _sweep_index

## Flat cell index of a unit body-fixed direction.
func cell_of_dir(d: Vector3) -> int:
	var dv := CubeSphere.DVec3.new(d.x, d.y, d.z)
	var fc := CubeSphere.dir_to_face_cell(dv, N_W)
	var f := int(fc["face"])
	var i := clampi(int(fc["fi"]), 0, N_W - 1)
	var j := clampi(int(fc["fj"]), 0, N_W - 1)
	return f * N_W * N_W + j * N_W + i

func _read_buf() -> PackedFloat32Array:
	return _buf_a if _read_is_a else _buf_b

func field_at_cell(cell: int, field: int) -> float:
	return _read_buf()[cell * FIELDS + field]

## Field value at a body-fixed direction (nearest cell; the sub-cell downscale noise is added by the
## caller/PerVoxelEnvironment, §1.6). Falls back to the static normal until the basis is ready.
func field_at_dir(d: Vector3, field: int) -> float:
	if not _ready:
		return 0.0
	return field_at_cell(cell_of_dir(d), field)

## Convenience reads for PerVoxelEnvironment.
func temp_anomaly_at_dir(d: Vector3) -> float:
	return field_at_dir(d, F_T)

func humidity_at_dir(d: Vector3) -> float:
	if not _ready:
		return 0.0
	var c := cell_of_dir(d)
	return _read_buf()[c * FIELDS + F_Q]

func cloud_water_at_dir(d: Vector3) -> float:
	return field_at_dir(d, F_CW)

func instability_at_dir(d: Vector3) -> float:
	return field_at_dir(d, F_INST)

func pressure_anomaly_at_dir(d: Vector3) -> float:
	return field_at_dir(d, F_P)

## Wind (east, north) blocks/s at a direction.
func wind_en_at_dir(d: Vector3) -> Vector2:
	if not _ready:
		return Vector2.ZERO
	var c := cell_of_dir(d)
	return Vector2(_read_buf()[c * FIELDS + F_U], _read_buf()[c * FIELDS + F_V])

# ---------------------------------------------------------------------------------------
# Gate / inspection support (headless verify_climate). None of these are on the live hot path.
# ---------------------------------------------------------------------------------------

## Run ONE full sweep with EXPLICIT solar forcing — bypasses the ephemeris so a headless gate can place
## the subsolar point at an arbitrary (declination, longitude) regardless of the FP_SEASONS default. This
## is how G-W1-ITCZ proves the rain band tracks δ, and G-W1-DET/PHYS drive deterministic spin-up.
func debug_full_sweep(sun_bf: Vector3, delta_lat: float, dt_game: float) -> void:
	if not _ready:
		return
	_cursor = 0
	_roll_bands()
	_sun_bf = sun_bf if sun_bf != Vector3.ZERO else Vector3(1, 0, 0)
	_delta_lat = delta_lat
	_dt_game = dt_game
	var read := _buf_a if _read_is_a else _buf_b
	var write := _buf_b if _read_is_a else _buf_a
	for idx in range(N_CELLS):
		_update_cell(idx, read, write)
	_finish_sweep()

func cell_sinlat(idx: int) -> float:
	return _sinlat[idx]

func cell_land(idx: int) -> float:
	return _land[idx]

## FNV-1a hash of the whole current state buffer — G-W1-DET compares two driven runs.
func state_hash() -> int:
	var buf := _read_buf()
	var h := 1469598103934665603
	for k in range(buf.size()):
		# hash the raw f32 bit pattern so tiny value differences are caught.
		var bits := _f32_bits(buf[k])
		h = (h ^ (bits & 0xFFFFFFFF)) * 1099511628211
		h &= 0x7FFFFFFFFFFFFFFF
	return h

func _f32_bits(f: float) -> int:
	var b := PackedFloat32Array([f]).to_byte_array()
	return b.decode_u32(0)

## Total moisture q+cw over the grid — G-W1-PHYS asserts it stays bounded (no moisture explosion).
func total_moisture() -> float:
	var buf := _read_buf()
	var s := 0.0
	for idx in range(N_CELLS):
		s += buf[idx * FIELDS + F_Q] + buf[idx * FIELDS + F_CW]
	return s
