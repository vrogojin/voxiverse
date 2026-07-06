class_name SurfaceModel
extends RefCounted
## The shared surface-material decision, expressed through the material framework
## rather than an ad-hoc constant: the ground surface is one `VoxelMaterialDef`
## whose states/look/physics live in data, and `block_id_at(x, z)` runs it.
##
## Today it ships a single `grass` state (block id 1) with no transitions — the
## world is uniformly grass. The framework is still exercised for it, so more
## surface states (mud, sand, ice, …) drop in later as extra VoxelStates +
## VoxelStateTransitions plus one library id, with NO mesher or HUD changes.
##
## Both rendering paths call `block_id_at(x, z)` for a column's surface block id
## (air=0, grass=1), keeping the godot_voxel generator and the GDScript fallback
## in agreement.

## Kept for backward compatibility but now delegated to the authoritative catalog.
const GRASS_ID := BlockCatalog.GRASS

static var _material: VoxelMaterialDef

## Lazily build the surface material + its (currently trivial) state machine
## (idempotent). Call once on the main thread before meshing to avoid a race if
## generation is threaded. Also warms the BlockCatalog so masses/colors/break
## forces come from the one authoritative table.
static func ensure_ready() -> void:
	if _material != null:
		return
	BlockCatalog.ensure_ready()

	# Reuse the catalog's grass state so mass/break_force stay in one place; add
	# the surface texture for the LOOK (the catalog carries physics + swatch only).
	# Grass is now BREAKABLE (its old break_force = INF is dropped) so the
	# break→inventory loop works — the catalog sets a finite break_force.
	var grass: VoxelState = BlockCatalog.state_of(BlockCatalog.GRASS)
	grass.albedo = 0.25
	grass.texture = BlockTextures.texture_for(BlockCatalog.GRASS)

	var mat := VoxelMaterialDef.new()
	mat.id = &"surface"
	mat.states = [grass]
	mat.default_state_index = 0
	_material = mat

static func material() -> VoxelMaterialDef:
	ensure_ready()
	return _material

## Library/mesher block id for the surface voxel at column (x, z). One material
## state today (grass), so this is always GRASS_ID — but it is read through the
## material's default state, so adding states here changes both meshers at once.
static func block_id_at(_x: int, _z: int) -> int:
	ensure_ready()
	return _material.get_default_state().block_id
