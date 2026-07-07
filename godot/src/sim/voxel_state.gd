class_name VoxelState
extends Resource
## A single state of a voxel material (e.g. grass "default", or later ice/water/
## steam). Bundles the per-state *physics* the simulation cares about with the
## *look* the renderer cares about, plus outgoing state transitions. Rendering
## reads only the look fields; the sim reads only the physics/transition fields —
## the two never need to know about each other.

@export var state_name: StringName = &"default"
## Mesher/library block id for this state's LOOK (air=0, grass=1, …).
## Lets the state machine's output map straight onto a voxel block id, shared by
## the godot_voxel library and the GDScript fallback. -1 = unset.
@export var block_id: int = -1

## Block-entity capability (VOXEL-DATA-STRUCTURE §3.1): true iff cells of this
## material may carry per-cell METADATA (container inventories, sign text, machine
## progress — the Minecraft TileEntity / Luanti node-metadata analogue). Default
## false; a metadata write to a non-block-entity material is a validation error
## (WorldManager.set_metadata). Metadata never encodes solidity/occupancy/mass — it
## can never disagree with the scalar axes about "what is here". No shipped material
## declares it yet (like state layouts), so this is inert for today's catalog.
@export var has_block_entity: bool = false

## Liquid identity of this material (MULTI-LIQUID §2.1): the CellCodec LIQ_KIND value this
## material IS as a liquid — 0 = not a liquid (the default for every solid), LIQ_WATER for
## water, LIQ_LAVA for lava. Parsed from the optional blocks.json "liquid_kind" name key
## (BlockCatalog._from_record). BlockCatalog.liquid_kind_of/liquid_lrid_of read it; the
## material document OMITS it when 0 so every non-liquid GMID stays byte-identical.
@export var liquid_kind: int = 0

@export_group("Physics")
## Mass of one voxel of this state, in kilograms (1 m^3 cell).
@export var mass: float = 1500.0
## Density, kg/m^3 (redundant with mass for a 1 m^3 cell but kept explicit for
## sub-voxel / partial-fill materials later).
@export var density: float = 1500.0
## Force (newtons) needed to break/detach this voxel. INF = unbreakable.
@export var break_force: float = INF
## Joint participation multiplier (default 1.0; 0.0 = does not bond, e.g. sand).
## Composed as `att_A · att_B` on a joint's tension/shear/moment capacities only
## (never the compression path) — INTEGRATION-DECISIONS §1.4. Superseded the old
## scalar "attachment strength" reading; the real (tension, shear) strengths now
## live in `strength_anchors`.
@export_range(0.0, 1.0) var attachment: float = 1.0
## Structural strength anchors `(P, H, D)` — max pillar height, max horizontal
## shelf, max dangling depth (three small integers with direct in-game meaning;
## SI §7 / INTEGRATION-DECISIONS §1.1). The structural solver derives σ_c=P·m·g,
## σ_s=H·m·g, σ_t=D·m·g, M₀=σ_s·H/2 from these + mass — the single source of
## truth for joint/node capacities. NOT precomputed here.
@export var strength_anchors: Vector3i = Vector3i(1, 1, 1)
## Structural family keying the anchor converter's branch and solver behaviour:
## `&"rock"`/`&"soil"`/`&"timber"`/`&"foliage"`/`&"brittle"`/`&"granular"`/
## `&"metal"`/`&"soft"`/`&"fluid"`/`&"bedrock"` (INTEGRATION-DECISIONS §1.2/§1.3).
@export var structural_class: StringName = &"rock"
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
## Render transparency / face-cull group (WGC §5.1): 0 = fully opaque, higher = more
## transparent. Mapped 1:1 onto the godot_voxel blocky `transparency_index`; the
## fallback mirrors it through `WorldManager.occludes_face`. A face of a cell in group
## G is culled by a neighbour whose group ≤ G (an opaque group-0 neighbour occludes
## everything; you see THROUGH a higher-group neighbour). Every opaque material is 0.
@export var cull_group: int = 0

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
