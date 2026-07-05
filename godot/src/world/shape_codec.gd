class_name ShapeCodec
extends RefCounted
## Static, pure sub-voxel SHAPE math for the modifier axis (VOXEL-DATA-STRUCTURE
## §13.1.2 / SUB-VOXEL-SMOOTHING §3-§5). The modifier field of a packed cell value
## (CellCodec.modifier) selects an in-cell occupancy shape; this class turns a
## modifier into the geometric queries the merged analytic-physics contract
## (INTEGRATION-DECISIONS §3) composes against: vertical spans, surface heights,
## point occupancy, joint contact areas and side-face profiles. It is the SHAPE
## half of the contract — `BlockCatalog.solidity_of` is the material GATE that runs
## first (`WorldManager._occ_span`); a non-solid material's modifier is never
## reached, so these functions may assume a solid host.
##
## P2 SHIPS THE FULL-CUBE IDENTITY ONLY. modifier 0 is the plain full cube — the
## sole shape that exists in the world today — so every query returns its full-cube
## value, and any non-zero modifier is (defensively) treated as full too: no shapes
## have been authored yet. P5 fills in the real corner-height math (ramps, slabs,
## stairs); it changes only these function BODIES, never their call sites, because
## the merged contract already routes every query through here.

## Filled vertical interval (lo, hi) within the unit cell at footprint (fx, fz),
## fx/fz each in [0, 1). Full cube → the whole height, (0, 1). `Vector2.ZERO` would
## mean "empty at this footprint" (a shape's cut-away corner). P2: always full-cube.
## P5 fills the corner-height math; P2 ships the full-cube identity.
static func span(_modifier: int, _fx: float, _fz: float) -> Vector2:
	return Vector2(0.0, 1.0)

## Local surface height (top of the filled column) at footprint (fx, fz), in [0, 1].
## Equals `span().y` for a bottom-anchored shape. Full cube → 1.0 (top flush with the
## cell's upper face). P5 fills the ramp/stair corner interpolation; P2 ships the
## full-cube identity.
static func local_top(_modifier: int, _fx: float, _fz: float) -> float:
	return 1.0

## True if the sub-cell point (fx, fy, fz), each in [0, 1), lies inside the shape's
## solid volume. Full cube → always true. P5 fills the half-space / corner test; P2
## ships the full-cube identity.
static func occupied(_modifier: int, _fx: float, _fy: float, _fz: float) -> bool:
	return true

## Shared-face contact area (0..1) between two adjacent cells' shapes across `axis`
## (0 = x, 1 = y, 2 = z), for the structural solver's joint capacity (VDS §13.3).
## Two full cubes → the whole unit face, 1.0. P5 fills the min-overlap of the two
## side profiles; P2 ships the full-cube identity.
static func contact_area(_modifier_a: int, _modifier_b: int, _axis: int) -> float:
	return 1.0

## True if the shape's `face` side profile FULLY covers the unit face — so a
## neighbour on the far side of it is occluded (composed by `occludes_face`). `face`
## is a 6-neighbour direction index (0..5). Full cube → every side profile is full,
## true. P5 fills the per-face coverage for ramps/slabs; P2 ships the full-cube
## identity.
static func side_profile_full(_modifier: int, _face: int) -> bool:
	return true
