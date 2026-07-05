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
# The surface AIR temperature is now BIOME-KEYED (WGC §6.7, INTEGRATION-DECISIONS
# §1.5): temperate columns read ~21.5 C as before, but COLD columns (snowy biomes
# / frozen oceans, climate temperature t < -0.55) read sub-zero air. This is the
# ordering dependency the frozen-sea seam needs: the generated sea-ice sheet sits
# ABOVE the solid floor (an "air" voxel to this model), so its temperature is the
# surface air; keeping snowy air below -5 C means the structural sibling's
# brittle-ice curve treats it as sound ice, not tissue-paper.
#
# The ground keeps its exposed-surface + exponential-relaxation-to-depth profile,
# but relaxes from the biome-keyed surface toward the same stable subsurface T_DEEP
# (geothermal floor, biome-independent):
#
#   air(biome)     = biome surface air                (above the surface)
#   depth          = surface_y - voxel_y              (0 at the top surface block)
#   T_surface      = air(biome) + SURFACE_OFFSET
#   T_ground(d)    = T_DEEP + (T_surface - T_DEEP) * exp(-d / DECAY_DEPTH)
#
# Temperate: air 21.5 C, exposed ground ~23.0 C, deep ~12 C (unchanged). Snowy:
# air -8 C, exposed ground -6.5 C, still trending to 12 C deep.
const T_AIR := 21.5           # temperate air temperature, deg C (DESIGN §1)
const T_SNOWY := -8.0         # snowy-biome / frozen-ocean air, deg C (< -5, WGC §6.7)
const T_TAIGA := 4.0          # cool taiga air, deg C
const T_HOT := 33.0           # desert / badlands air, deg C
const SURFACE_OFFSET := 1.5   # sun-warmed exposed surface sits this much above air
const T_DEEP := 12.0          # stable subsurface temperature, deg C
const DECAY_DEPTH := 4.0      # e-folding depth, metres

## Air temperature (temperate default). Public so the HUD can reuse it. Biome-aware
## callers should prefer `surface_air_temperature(x, z)`.
static func air_temperature(_y: float) -> float:
	return T_AIR

## Biome/climate-keyed surface air temperature at column (x, z). Keyed on the same
## climate temperature noise that drives biome + sea-ice, so cold columns are
## consistently sub-zero at the surface (WGC §6.7).
static func surface_air_temperature(x: int, z: int) -> float:
	var p := TerrainConfig.column_profile(x, z)
	return _air_for(int(p.y), p.w)

static func _air_for(biome: int, t: float) -> float:
	if t < -0.55:
		return T_SNOWY
	if t < -0.15:
		return T_TAIGA
	if biome == TerrainConfig.B_DESERT or biome == TerrainConfig.B_BADLANDS:
		return T_HOT
	return T_AIR

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
	var p := TerrainConfig.column_profile(c.x, c.z)
	var surface := int(p.x)
	var base_air := _air_for(int(p.y), p.w)    # biome/climate-keyed surface air
	if c.y > surface:                          # air voxel (incl. sea ice above the floor)
		return base_air
	# Ground: the exposed surface sits a touch above air, then relaxes to the
	# stable subsurface temperature with depth.
	var depth := surface - c.y
	var t_surface := base_air + SURFACE_OFFSET
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
