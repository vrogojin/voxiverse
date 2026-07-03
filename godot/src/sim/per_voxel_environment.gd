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
# Air temperature now varies with ALTITUDE via an atmospheric lapse rate: warm at
# sea level, cold on the peaks. This is what drives snow caps (§ SurfaceModel).
#
#   air(y) = T_SEA_LEVEL - LAPSE_RATE * y          (y in blocks/metres)
#
# Ground uses the same surface/depth model as before, but the SURFACE tracks the
# LOCAL air at that column's height (so high ground is cold too), then relaxes
# exponentially toward a stable subsurface value with depth:
#
#   depth        = surface_y - voxel_y             (0 at the top surface block)
#   T_surface    = air(surface_y) + SURFACE_OFFSET (sun-warmed local surface)
#   T_ground(d)  = T_DEEP + (T_surface - T_DEEP) * exp(-d / DECAY_DEPTH)
#
# At sea level air = 21.5 C. LAPSE_RATE is calibrated so air crosses 0 C at
# y ~= 200 (21.5 / 0.1075 ~= 200) — snow therefore appears only on the genuinely
# high, 200+ mountain peaks (the surface freezes, with the +1.5 offset, a touch
# above y = 200). The thermometer reads ~21.5 at sea level and drops smoothly to
# sub-zero on the peaks.
const T_SEA_LEVEL := 21.5      # air temperature at y = 0, deg C (DESIGN §1)
const LAPSE_RATE := 0.1075     # air temperature drop per block of altitude, deg C
const SURFACE_OFFSET := 1.5    # sun-warmed surface sits this much above local air
const T_DEEP := 12.0           # stable subsurface temperature, deg C
const DECAY_DEPTH := 4.0       # e-folding depth, metres

## Air temperature at altitude y (blocks). Public so SurfaceModel/HUD can reuse.
static func air_temperature(y: float) -> float:
	return T_SEA_LEVEL - LAPSE_RATE * y

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
	if c.y > surface:                          # air voxel
		return air_temperature(float(c.y))
	# Ground: surface tracks LOCAL air at this column's height, then relaxes to
	# the stable subsurface temperature with depth.
	var depth := surface - c.y
	var t_surface := air_temperature(float(surface)) + SURFACE_OFFSET
	return T_DEEP + (t_surface - T_DEEP) * exp(-float(depth) / DECAY_DEPTH)

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
