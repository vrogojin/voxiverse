class_name PerVoxelEnvironment
extends RefCounted
## Per-voxel environment fields (DESIGN §3). One query interface the rest of the
## engine reads through: the thermometer HUD, and later the material state
## machine (VoxelMaterialDef.resolve_state consumes sample()). Nothing here
## knows about meshing; it derives everything from TerrainConfig's heightmap, so
## it stays valid for both the fallback and the godot_voxel path.
##
## `temperature` and `light` are modelled for real; the rest return sane physical
## defaults as stubs, ready to be fleshed out for the full engine.

# --- temperature model ---------------------------------------------------------
# ABSOLUTE-ALTITUDE lapse off a per-climate SEA-LEVEL baseline (M1 snowy-world ADR §3;
# DESIGN §1 amended). The one authority for the curve is ClimateModel — a pure,
# dependency-free sink that BOTH this class (THE temperature query interface, engine rule 2)
# AND TerrainConfig (the snow-cap worldgen predicate) call, so the two can never disagree at
# the snow-line boundary and no const-cycle forms between them.
#
# The OLD per-column re-anchoring (every surface pinned to 21.5) is GONE — it made altitude
# irrelevant. Let  surface = height_at(x, z),  t = column_profile(x, z).w (climate noise),
# and for a ground voxel  depth d = surface - y:
#
#   climate offset:  ClimateModel.climate_base(t) — 21.5 C at SEA LEVEL for a temperate column
#       (t ≥ −0.15), −8 C for a frozen biome (t < −0.55), C0-linear between (B_TAIGA ramp).
#   altitude lapse:  ~0.224 C/block. The SAME line anchors both the air voxels and the ground's
#       surface temperature, so surface↔air is exact and monotone.
#
#   AIR (y > surface):  ClimateModel.air_temperature(y, t) — 0 C at y=96 for a temperate column,
#       NEGATIVE above with NO clamp (a y=256 air voxel ≈ −35.8 C). Monotone-decreasing forever.
#   GROUND (y ≤ surface):  cool from the surface anchor toward the 3 C plateau at 1 C/block,
#       SIGNED (a cold column's permafrost WARMS downward toward the plateau), plus the
#       geothermal excess (GEO_RATE·(−40 − y) for y < −40) — 3 C at y=−40 climbing to 27 C at
#       the bedrock floor (y = WORLD_BOTTOM_Y = −64). Deep ground forgets the surface anchor
#       (toward saturates at 3), so the geothermal pins are altitude/biome-independent.
#
# FROZEN-SEA SEAM (structural dependency, do not remove). A generated sea-ice sheet sits at
# y = SEA_LEVEL, ABOVE the ocean floor, so to this heightmap model it is an "air" voxel. `ice`
# is structural class "brittle", SOUND (φ=1) only below ~−5 C. So a climatically FROZEN OCEAN
# column keeps its sea-level air/ice at exactly T_FROZEN_SEA (−8) — else StructuralSolver would
# read the (vertically unsupported) sheet as tissue-paper and detach it on the first nearby
# break. This branch is now CONSISTENT WITH the general model (a frozen column reads ≈ −8 at sea
# level anyway) but stays explicit to CLAMP the ice zone to exactly −8 (pinned).
const CLIMATE_FROZEN := ClimateModel.CLIMATE_FROZEN   # alias — frozen-ocean seam threshold (structural dep)
const T_FROZEN_SEA := ClimateModel.T_FROZEN_SEA       # alias — frozen sea-level air/ice temperature, −8 C
const COOL_RATE := 1.0        # ground cools 1 C per block of depth toward the plateau
const COOL_FLOOR := 3.0       # cooling plateau, deg C
const GEO_SPAN := 24          # geothermal rise band: this many blocks above bedrock
const GEO_RATE := 1.0         # geothermal rise, 1 C per block toward bedrock
# The y at which the geothermal rise begins (3 C here, climbing below it to the floor).
const _GEO_REF_Y := TerrainConfig.WORLD_BOTTOM_Y + GEO_SPAN   # -64 + 24 = -40

## Surface AIR temperature at column (x, z): the climate offset minus the altitude lapse at the
## column's own solid surface (ClimateModel). Public so the HUD/state machine can reuse it.
static func surface_air_temperature(x: int, z: int) -> float:
	var surface := TerrainConfig.height_at(x, z)
	return ClimateModel.surface_temperature(surface, TerrainConfig.column_profile(x, z).w)

## Air temperature at altitude `y` for climate `t` (default: temperate). Public so the HUD/state
## machine can reuse it; the absolute-altitude lapse (0 C at y=96 for a temperate column, negative
## above). The 1-arg call reads a temperate column.
static func air_temperature(y: float, t: float = ClimateModel.CLIMATE_TEMPERATE) -> float:
	return ClimateModel.air_temperature(y, t)

# --- light model ---------------------------------------------------------------
# Air and the exposed surface block are fully lit (1.0); light attenuates
# exponentially below the surface:  light(depth) = exp(-depth / LIGHT_DEPTH).
const LIGHT_DEPTH := 1.5

# --- stub defaults -------------------------------------------------------------
const PRESSURE_KPA := 101.325                       # standard atmosphere
const EARTH_MAGNETIC := Vector3(0.0, 0.0, 5.0e-5)   # ~50 microtesla
const GRAVITY := Vector3(0.0, -9.81, 0.0)           # m/s^2, world down

# COSMOS M3 (§4.5 / M2 curved-render follow-up): the floating-origin chart. NULL in FLAT_WORLD →
# every query below reads TerrainConfig on the WINDOW column directly (byte-identical). Non-null in
# curved mode (WorldManager injects it on install/flip): `pos` is a WINDOW position, so the surface/
# climate reads MUST fold the window column → GLOBAL cell (add the origin, fold across an edge) or
# temperature/light would read the wrong column at a non-zero origin. THE curved-render fix for the
# per-voxel environment the task calls out.
var _chart: CosmosChart = null

## Inject (or clear) the floating-origin chart. Called by WorldManager on chart install / flip.
func set_chart(chart: CosmosChart) -> void:
	_chart = chart

# COSMOS CLIMATE W1 (§1.5): the weather grid this interface READS (engine rule 2). Null unless
# FP_CLIMATE_GRID (WorldManager injects it). Every query below falls back to a static default when it is
# null or not yet spun up, so a flag-off / pre-init build is byte-identical.
var _weather: WeatherSystem = null

## Inject the weather grid. Called by WorldManager under FP_CLIMATE_GRID.
func set_weather(w: WeatherSystem) -> void:
	_weather = w

## Unit sphere direction of WINDOW column (x, z): via the chart (curved) or the active facet (FACETED);
## ZERO in a pure flat world (no sphere). The ONE column→direction funnel for the season term and every
## weather-grid read, so gameplay and the sim agree on which weather cell a column sits in.
func _dir_of_col(x: int, z: int) -> Vector3:
	if _chart != null:
		return CosmosTruePlace.dir_of_window(_chart, float(x) + 0.5, float(z) + 0.5)
	if CubeSphere.FACETED:
		var d := FacetAtlas.cell_dir(TerrainConfig.active_facet(), x, z)
		return Vector3(float(d.x), float(d.y), float(d.z))
	return Vector3.ZERO

func _dir_of_pos(pos: Vector3) -> Vector3:
	var c := _cell(pos)
	return _dir_of_col(c.x, c.z)

static func _cell(pos: Vector3) -> Vector3i:
	return Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))

## Surface height at WINDOW column (x, z), folded to the GLOBAL cell in curved mode (§4.3).
func _surface_h(x: int, z: int) -> int:
	if _chart == null:
		return TerrainConfig.height_at(x, z)
	var p := _chart.raw_of(x, z)                 # COSMOS-FRAME-ORIENTATION §5.3: window→raw via M_win
	return TerrainConfig.height_at(p.x, p.y)

## Climate temperature term (column_profile.w) at WINDOW column (x, z), folded to the GLOBAL cell.
func _climate_w(x: int, z: int) -> float:
	if _chart == null:
		return TerrainConfig.column_profile(x, z).w
	var p := _chart.raw_of(x, z)                 # COSMOS-FRAME-ORIENTATION §5.3: window→raw via M_win
	return TerrainConfig.column_profile(p.x, p.y).w

## Depth below the surface for a solid cell (0 at top block); -1 if the cell is
## air (at or above the surface). Folds the window column → global cell in curved mode.
func _depth(c: Vector3i) -> int:
	var surface := _surface_h(c.x, c.z)
	if c.y > surface:
		return -1
	return surface - c.y

## CLIMATE W0 (§3): signed sin-latitude at WINDOW column (x, z) — the spin-axis (+Z) component of the
## column's sphere direction (curved/faceted). A pure flat world (no direction) ⇒ 0 (no hemispheres), so
## the seasonal offset vanishes there. The ONE source of latitude sign (N vs S) for the season term; the
## climate `t` (column_profile.w) can't provide it — it uses |sinφ| and loses the hemisphere.
func signed_sinlat(x: int, z: int) -> float:
	return _dir_of_col(x, z).z

## The seasonal temperature offset (°C) at column (x, z) — 0 unless FP_SEASONS is on, so the flag-off path
## never even evaluates it (byte-identical). Applied to the air/ground branches below (NOT the frozen-sea
## structural pin, which stays exactly −8 — the ice sheet is annual-mean static, §3.4).
func _season_term(x: int, z: int) -> float:
	return ClimateModel.season_offset(signed_sinlat(x, z), ClimateModel.current_sin_delta)

## CLIMATE W1 (§1.5): the BOUNDED weather temperature anomaly (°C) at column (x, z) — the grid's local T
## deviation, hard-clamped to ±8 so weather can never dominate the climate/altitude structure. 0 unless the
## weather grid exists and is spun up (⇒ pre-init / flag-off is byte-identical).
func _weather_term(x: int, z: int) -> float:
	if _weather == null or not _weather.is_ready():
		return 0.0
	return clampf(_weather.temp_anomaly_at_dir(_dir_of_col(x, z)), -8.0, 8.0)

## Temperature in degrees Celsius at the voxel containing `pos`.
func temperature(pos: Vector3) -> float:
	var c := _cell(pos)
	var surface := _surface_h(c.x, c.z)
	if c.y > surface:                          # air voxel (incl. water/sea ice above the floor)
		# Frozen-sea seam (verbatim): a frozen OCEAN column's sea-level air/ice stays exactly
		# −8 so the brittle-ice structural curve reads the sheet as sound (see const block). The
		# season offset is deliberately NOT added here — the ice sheet is annual-mean static (§3.4).
		if surface < TerrainConfig.SEA_LEVEL and c.y <= TerrainConfig.SEA_LEVEL \
				and _climate_w(c.x, c.z) < CLIMATE_FROZEN:
			return T_FROZEN_SEA
		var air := ClimateModel.air_temperature(float(c.y), _climate_w(c.x, c.z))
		if CubeSphere.FP_SEASONS:
			air += _season_term(c.x, c.z)
		if CubeSphere.FP_CLIMATE_GRID:
			air += _weather_term(c.x, c.z)
		return air
	# Ground: cool from the surface anchor toward the 3 C plateau at COOL_RATE/block, SIGNED
	# (a cold column with ts < COOL_FLOOR warms downward toward the plateau — permafrost), plus
	# the geothermal excess in the 24 blocks above bedrock (3 C at y=-40, climbing to 27 C at y=-64).
	var ts := ClimateModel.surface_temperature(surface, _climate_w(c.x, c.z))
	if CubeSphere.FP_SEASONS:
		ts += _season_term(c.x, c.z)
	if CubeSphere.FP_CLIMATE_GRID:
		ts += _weather_term(c.x, c.z)
	var d := surface - c.y
	var toward := maxf(ts - COOL_RATE * float(d), COOL_FLOOR) if ts >= COOL_FLOOR \
		else minf(ts + COOL_RATE * float(d), COOL_FLOOR)
	var geo := GEO_RATE * maxf(0.0, float(_GEO_REF_Y - c.y))
	return toward + geo

## Normalised light level [0..1] at the voxel containing `pos`.
func light(pos: Vector3) -> float:
	var d := _depth(_cell(pos))
	if d <= 0:
		return 1.0
	return exp(-float(d) / LIGHT_DEPTH)

# CLIMATE W1: pressure scale height (blocks) for the hydrostatic altitude term. Matches the SN4 fog
# scale so space stays low-pressure; only consulted under FP_CLIMATE_GRID (flag-off returns the constant).
const P_SCALE_HEIGHT := 900.0
const P_ANOM_KPA := 0.03            # kPa per unit of grid pressure anomaly (thermal low/high)

## Air/hydrostatic pressure in kPa. Stub (flag off): standard atmosphere everywhere (byte-identical).
## CLIMATE W1: the hydrostatic altitude term (101.325·exp(−y/H)) plus the weather grid's pressure anomaly.
func pressure(pos: Vector3) -> float:
	if not CubeSphere.FP_CLIMATE_GRID:
		return PRESSURE_KPA
	var base := PRESSURE_KPA * exp(-maxf(pos.y, 0.0) / P_SCALE_HEIGHT)
	if _weather != null and _weather.is_ready():
		base += P_ANOM_KPA * _weather.pressure_anomaly_at_dir(_dir_of_pos(pos))
	return base

## CLIMATE W1 (§1.5): specific humidity at `pos` — the grid `q` at the column's weather cell (the sub-cell
## downscale noise is a later refinement). Falls back to a climatological proxy from the local temperature
## when the grid is absent, so callers always get a sane value.
func humidity(pos: Vector3) -> float:
	if _weather != null and _weather.is_ready():
		return _weather.humidity_at_dir(_dir_of_pos(pos))
	# proxy: warmer air holds more moisture (Clausius-Clapeyron), at ~half saturation.
	var t_abs := temperature(pos)
	return clampf(WeatherSystem.QSAT_REF * exp(WeatherSystem.QSAT_K * (t_abs - WeatherSystem.QSAT_T0)) * 0.5,
		0.0, WeatherSystem.Q_MAX)

## CLIMATE W1: wind vector (blocks/s) at `pos`. The grid stores geographic (east, north); this maps them
## to a local world frame with the convention east→+X, north→−Z (the facet's flat lattice orientation) — an
## approximate local mapping adequate for cloud advection / particle drift (W2/W3). ZERO without the grid.
func wind(pos: Vector3) -> Vector3:
	if _weather == null or not _weather.is_ready():
		return Vector3.ZERO
	var en := _weather.wind_en_at_dir(_dir_of_pos(pos))
	return Vector3(en.x, 0.0, -en.y)

## CLIMATE W1 (§1.5): precipitation {rate: blocks-equiv intensity 0..1, kind: "none"|"rain"|"snow"} at the
## column of `pos`. Rate is a threshold read-out of the grid cloud water; kind is resolved by the ONE
## zero-crossing authority (surface_temperature + season), so precip agrees with the snow-cap boundary.
func precipitation(pos: Vector3) -> Dictionary:
	if _weather == null or not _weather.is_ready():
		return {"rate": 0.0, "kind": "none"}
	var c := _cell(pos)
	var d := _dir_of_col(c.x, c.z)
	var cw := _weather.cloud_water_at_dir(d)
	var rate := clampf((cw - WeatherSystem.RAIN_HOLD) / WeatherSystem.CW_MAX, 0.0, 1.0)
	if rate <= 0.0:
		return {"rate": 0.0, "kind": "none"}
	var surface := _surface_h(c.x, c.z)
	var ts := ClimateModel.surface_temperature(surface, _climate_w(c.x, c.z))
	if CubeSphere.FP_SEASONS:
		ts += _season_term(c.x, c.z)
	return {"rate": rate, "kind": "snow" if ts < 0.0 else "rain"}

## CLIMATE W1/W2 (§1.5): normalised cloud cover [0..1] at the column of `pos` (the grid cloud water,
## scaled). `layer` selects an altitude band's threshold for W2's multi-layer meshes (0 = any cloud).
func cloud_cover(pos: Vector3, _layer: int = 0) -> float:
	if _weather == null or not _weather.is_ready():
		return 0.0
	return clampf(_weather.cloud_water_at_dir(_dir_of_pos(pos)) / WeatherSystem.CW_MAX, 0.0, 1.0)

## Electric current density (stub: none).
func electric_current(_pos: Vector3) -> float:
	return 0.0

## Magnetic field vector in Tesla (stub: a uniform Earth-like field).
func magnetic_field(_pos: Vector3) -> Vector3:
	return EARTH_MAGNETIC

## Gravity acceleration vector in m/s^2 (COSMOS M1 §6.1 — the toward-centre field).
## FLAT_WORLD (default): the fixed-down stub, byte-identical to today. Curved: the real radial
## field. In window space its DIRECTION is exactly −Y for every column (the §3.3 y↦r theorem — no
## per-position tilt on the surface), and its MAGNITUDE is GM/(R+r)² with r = pos.y (y ↦ r), so it
## is exactly SURFACE_GRAVITY (9.81) at the datum r=0 and falls off with altitude. Implemented as
## the real field (not a hardcoded −9.81) so it generalises to other bodies/altitudes unchanged.
func gravity(pos: Vector3) -> Vector3:
	if CubeSphere.FLAT_WORLD:
		return GRAVITY
	var rr := float(CubeSphere.radius_for(CubeSphere.HOME_BODY))
	var r := rr + pos.y
	if r <= 0.0:
		return GRAVITY
	return Vector3(0.0, -CubeSphere.gm_for(CubeSphere.HOME_BODY) / (r * r), 0.0)

## All fields at once, as the dictionary VoxelMaterialDef.resolve_state expects.
func sample(pos: Vector3) -> Dictionary:
	return {
		"temperature": temperature(pos),
		"light": light(pos),
		"pressure": pressure(pos),
		"electric_current": electric_current(pos),
		"magnetic_field": magnetic_field(pos),
		"gravity": gravity(pos),
		"gravity_magnitude": gravity(pos).length(),
	}
