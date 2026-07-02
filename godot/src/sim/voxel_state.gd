class_name VoxelState
extends Resource
## A single state of a voxel material (e.g. grass "default", or later ice/water/
## steam). Bundles the per-state *physics* the simulation cares about with the
## *look* the renderer cares about, plus outgoing state transitions. Rendering
## reads only the look fields; the sim reads only the physics/transition fields —
## the two never need to know about each other.

@export var state_name: StringName = &"default"

@export_group("Physics")
## Mass of one voxel of this state, in kilograms (1 m^3 cell).
@export var mass: float = 1500.0
## Density, kg/m^3 (redundant with mass for a 1 m^3 cell but kept explicit for
## sub-voxel / partial-fill materials later).
@export var density: float = 1500.0
## Force (newtons) needed to break/detach this voxel. INF = unbreakable.
@export var break_force: float = INF
## How strongly this voxel stays attached to neighbours (0..1).
@export_range(0.0, 1.0) var attachment: float = 1.0
## Fluid/gas permeability (0 = sealed, 1 = fully permeable).
@export_range(0.0, 1.0) var permeability: float = 0.0
## Fraction of incident light reflected (0..1).
@export_range(0.0, 1.0) var albedo: float = 0.25
## Light transmission through the voxel (0 = opaque, 1 = clear).
@export_range(0.0, 1.0) var translucence: float = 0.0
## Self-emitted light (0 = none).
@export var emission: float = 0.0
## Collidability/occupancy (0 = passable like air, 1 = full solid block).
@export_range(0.0, 1.0) var solidity: float = 1.0

@export_group("Look")
## Surface texture for this state (grass PNG for grass).
@export var texture: Texture2D
## Multiplicative tint applied over the texture.
@export var tint: Color = Color.WHITE
## Emissive glow strength for the look (paired with `emission` physics).
@export var glow: float = 0.0

@export_group("Transitions")
## Outgoing transitions, evaluated in order; first match wins.
@export var transitions: Array[VoxelStateTransition] = []
