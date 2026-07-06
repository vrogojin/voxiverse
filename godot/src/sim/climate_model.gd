class_name ClimateModel
extends RefCounted
## The one authority for the world's surface/air TEMPERATURE curve (M1 snowy-world ADR,
## Decision 3). A pure, DEPENDENCY-FREE sink: it references no other project class, so both
## PerVoxelEnvironment (THE temperature query interface, engine rule 2) AND TerrainConfig
## (the snow-cap worldgen predicate) can call it without creating a const-cycle between them.
##
## MODEL (Decision 3.2): temperature is an ABSOLUTE-ALTITUDE lapse off a per-climate sea-level
## baseline — NOT the old per-column re-anchoring that made altitude irrelevant.
##   * climate offset: the temperate world reads T_SEA_LEVEL (21.5 C) at the water line; a
##     winter-biome column (`t` = column climate noise below CLIMATE_FROZEN) reads T_FROZEN_SEA
##     (-8 C) there, with B_TAIGA ramping linearly between the two over t ∈ [FROZEN, TEMPERATE].
##   * lapse: 0 C at y = ALT_ZERO_Y (=96) for a TEMPERATE column, dropping LAPSE_RATE per block,
##     negative above with NO clamp (a y=256 air voxel reads ≈ -35.8 C). Same line anchors both
##     the air voxels and the ground's surface temperature, so surface↔air is exact and monotone.
## Because the cap predicate (surface_temperature < 0) and the melt transition (temperature >= 0)
## share ONE zero crossing on ONE field, worldgen and the state machine agree at the boundary.
##
## Reachability (Risk 1): this world maxes at y≈20, so temperate altitude caps (freezing at y=96)
## are LATENT — M1's visible winter comes from the climate offset (frozen biomes) plus altitude
## modulation of the snow line WITHIN those cold biomes. Tall terrain lights temperate peaks up
## automatically, no code change.

const T_SEA_LEVEL   := 21.5           # temperate surface temp at sea level (y = 0)
const ALT_ZERO_Y    := 96             # temperate air/surface reaches 0 C at this altitude
const LAPSE_RATE    := T_SEA_LEVEL / float(ALT_ZERO_Y)   # 21.5/96 ≈ 0.22396 C/block
const CLIMATE_TEMPERATE := -0.15      # climate t at/above this → no climate offset (full 21.5)
const CLIMATE_FROZEN    := -0.55      # climate t below this → full winter offset (−8 at sea level)
const T_FROZEN_SEA      := -8.0       # winter sea-level surface temp (== the frozen-sea structural pin)

## The SEA-LEVEL surface temperature for a column of climate `t` (the climate offset alone,
## before altitude). Temperate (t ≥ CLIMATE_TEMPERATE) → 21.5; frozen (t < CLIMATE_FROZEN) → -8;
## C0-linear between, so the snow line unrolls smoothly over the (0.002-freq) climate noise.
static func climate_base(t: float) -> float:
	if t >= CLIMATE_TEMPERATE:
		return T_SEA_LEVEL
	if t < CLIMATE_FROZEN:
		return T_FROZEN_SEA
	return lerpf(T_FROZEN_SEA, T_SEA_LEVEL, (t - CLIMATE_FROZEN) / (CLIMATE_TEMPERATE - CLIMATE_FROZEN))

## Surface temperature of a column whose solid top is at `surface_y`, climate `t`: the climate
## offset minus the absolute-altitude lapse. THE snow-cap predicate field (worldgen stamps a cap
## where this is < 0; the melt transition clears where the sampled ground temperature is ≥ 0).
static func surface_temperature(surface_y: int, t: float) -> float:
	return climate_base(t) - LAPSE_RATE * float(surface_y)

## Air temperature at altitude `y` for a column of climate `t`: the same absolute-altitude lapse
## off the climate base, so surface↔air is exact. Monotone-decreasing forever (0 at y=96 for a
## temperate column, negative above — no clamp).
static func air_temperature(y: float, t: float) -> float:
	return climate_base(t) - LAPSE_RATE * float(y)
