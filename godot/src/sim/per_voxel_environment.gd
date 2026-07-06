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
# A SIMPLE, BIOME-INDEPENDENT piecewise profile (DESIGN §1, temperature rework).
# Every column's SURFACE reads the same normal room temperature (21.5 C for BOTH
# the air voxel and the exposed surface block); the four regions below join up
# continuously. "Baseline height" here just means each column's own surface, i.e.
# `TerrainConfig.height_at(x, z)` (the y of the topmost solid ground cell) — the
# model is derived only from that heightmap, so it is identical for both render
# paths and needs no meshing.
#
# Let  surface = height_at(x, z),  and for a ground voxel  depth d = surface - y.
#
#   AIR (y > surface):  linear from 21.5 C at y = surface down to 0 C at y = 256,
#       then clamped at 0 C above 256. Anchored per-column at the surface (=21.5)
#       and globally at ALT_ZERO_Y (=0), so the slope is (256 - surface)/21.5
#       blocks per degree — ~11.9 blocks/°C for a sea-level column (surface≈0),
#       ~11.7 blocks/°C for the baseline hills (surface≈5). This guarantees 21.5
#       at the surface of EVERY column and 0 at altitude 256.
#
#   GROUND (y <= surface):  the maximum of two curves —
#       cool = max(21.5 - d, 3.0)                      # −1 C per block of depth,
#                                                        # plateauing at 3 C (d≥18.5)
#       geo  = 3.0 + max(0, (WORLD_BOTTOM_Y+24) - y)   # +1 C per block below y=-40
#       T_ground = max(cool, geo)
#     Near the surface `cool` dominates: 21.5 at d=0, 20.5 one block down, reaching
#     the 3 C floor at depth 18.5. A flat 3 C plateau then sits between the cooling
#     zone and the geothermal rise. In the 24 blocks just above bedrock, `geo`
#     dominates and climbs 1 C per block from 3 C at y=-40 to 27 C at the bedrock
#     floor (y = WORLD_BOTTOM_Y = -64). BEDROCK REFERENCE: bedrock occupies the
#     very bottom of the world (100% at y=-64), so the geothermal "24 blocks till
#     the bedrock" band is measured from WORLD_BOTTOM_Y (-64) upward → y ∈ [-64,-40].
#     The two curves meet continuously (both = 3 C at y=-40), and the surface block
#     (d=0) reads exactly 21.5 C.
const T_AIR := 21.5           # surface baseline temperature, deg C (air AND surface block)
const ALT_ZERO_Y := 256       # altitude at which air cools to 0 C (requirement 2)
const T_SURFACE := T_AIR      # the surface block reads the same 21.5 C as the surface air
const COOL_RATE := 1.0        # ground cools 1 C per block of depth (requirement 3)
const COOL_FLOOR := 3.0       # cooling plateau, deg C (reached at depth 18.5)
const GEO_SPAN := 24          # geothermal rise band: this many blocks above bedrock
const GEO_RATE := 1.0         # geothermal rise, 1 C per block toward bedrock (requirement 4)
# The y at which the geothermal rise begins (3 C here, climbing below it to the floor).
const _GEO_REF_Y := TerrainConfig.WORLD_BOTTOM_Y + GEO_SPAN   # -64 + 24 = -40

## Air temperature at altitude `y` above a `baseline` height: 21.5 C at/below the
## baseline, cooling linearly to 0 C at ALT_ZERO_Y and clamped at 0 C above it.
static func _air_at(y: float, baseline: float) -> float:
	if y <= baseline:
		return T_SURFACE
	if y >= float(ALT_ZERO_Y):
		return 0.0
	return T_SURFACE * (float(ALT_ZERO_Y) - y) / (float(ALT_ZERO_Y) - baseline)

## Air temperature at altitude `y`. Public so the HUD/state machine can reuse it.
## Uses the nominal baseline hills height (TerrainConfig.BASE_HEIGHT) as the
## surface anchor for a generic column: 21.5 C at/below it, dropping to 0 C at 256.
static func air_temperature(y: float) -> float:
	return _air_at(y, TerrainConfig.BASE_HEIGHT)

## Surface air temperature at column (x, z). Biome-independent now: every column's
## surface air is the 21.5 C baseline (the air/ground meet point of the model).
static func surface_air_temperature(_x: int, _z: int) -> float:
	return T_SURFACE

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
		return _air_at(float(c.y), float(surface))
	# Ground: cool 1 C per block down (floored at 3 C), overridden by the geothermal
	# rise in the 24 blocks above bedrock (3 C at y=-40, climbing to 27 C at y=-64).
	var depth := surface - c.y
	var cool := maxf(T_SURFACE - COOL_RATE * float(depth), COOL_FLOOR)
	var geo := COOL_FLOOR + GEO_RATE * maxf(0.0, float(_GEO_REF_Y - c.y))
	return maxf(cool, geo)

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
