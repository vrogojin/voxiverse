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

static func _cell(pos: Vector3) -> Vector3i:
	return Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))

## Depth below the surface for a solid cell (0 at top block); -1 if the cell is
## air (at or above the surface).
static func _depth(c: Vector3i) -> int:
	var surface := TerrainConfig.height_at(c.x, c.z)
	if c.y > surface:
		return -1
	return surface - c.y

## Temperature in degrees Celsius at the voxel containing `pos`.
func temperature(pos: Vector3) -> float:
	var c := _cell(pos)
	var surface := TerrainConfig.height_at(c.x, c.z)
	if c.y > surface:                          # air voxel (incl. water/sea ice above the floor)
		# Frozen-sea seam (verbatim): a frozen OCEAN column's sea-level air/ice stays exactly
		# −8 so the brittle-ice structural curve reads the sheet as sound (see const block).
		if surface < TerrainConfig.SEA_LEVEL and c.y <= TerrainConfig.SEA_LEVEL \
				and TerrainConfig.column_profile(c.x, c.z).w < CLIMATE_FROZEN:
			return T_FROZEN_SEA
		return ClimateModel.air_temperature(float(c.y), TerrainConfig.column_profile(c.x, c.z).w)
	# Ground: cool from the surface anchor toward the 3 C plateau at COOL_RATE/block, SIGNED
	# (a cold column with ts < COOL_FLOOR warms downward toward the plateau — permafrost), plus
	# the geothermal excess in the 24 blocks above bedrock (3 C at y=-40, climbing to 27 C at y=-64).
	var ts := ClimateModel.surface_temperature(surface, TerrainConfig.column_profile(c.x, c.z).w)
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

## Air/hydrostatic pressure in kPa (stub: standard atmosphere everywhere).
func pressure(_pos: Vector3) -> float:
	return PRESSURE_KPA

## Electric current density (stub: none).
func electric_current(_pos: Vector3) -> float:
	return 0.0

## Magnetic field vector in Tesla (stub: a uniform Earth-like field).
func magnetic_field(_pos: Vector3) -> Vector3:
	return EARTH_MAGNETIC

## Gravity acceleration vector in m/s^2 (stub: uniform world gravity).
func gravity(_pos: Vector3) -> Vector3:
	return GRAVITY

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
