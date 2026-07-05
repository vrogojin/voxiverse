class_name WorldManager
extends Node3D
## Owns "the world": picks the rendering path, drives streaming, and exposes the
## analytic queries (solidity, surface height, voxel raycast) that the player and
## HUD use regardless of path. Also holds the decoupled sim layer (material
## registry + per-voxel environment) so gameplay reads simulation, not geometry.
##
## Path selection (DESIGN §2): if the Zylann godot_voxel module is compiled into
## the running engine (ClassDB has VoxelTerrain), use it; otherwise fall back to
## the pure-GDScript chunk streamer. Both render the same infinite grass hills
## from TerrainConfig, so everything downstream is identical.

signal path_selected(using_module: bool)

## Emitted when a cell's per-cell METADATA is DROPPED by a material change or break
## (VOXEL-DATA-STRUCTURE §14 P1 / §11): `_write_cell` settles the orphaned document
## through this signal so a future system (e.g. spilling a chest's contents as
## pickups) can react. No consumer is required today. Never fired by `set_state`
## (the one write that PRESERVES metadata) or by `set_metadata` (an explicit update).
signal block_entity_orphaned(cell: Vector3i, old_meta: Dictionary)

var environment: PerVoxelEnvironment
var materials: MaterialRegistry
var using_module: bool = false

var _streamer: ChunkStreamer          # fallback path
var _module_world: Node3D             # godot_voxel path
var _ground: GroundCollider           # local blocky physics collider

# Terrain edit overlay: the gameplay source of truth (floor + raycast + collider +
# collapse consult it), mirrored into whichever render path runs. This one
# dictionary replaces the old `_removed` set: 0 = dug to air, >0 = solid cell.
# Values are PACKED cell values (CellCodec: material | modifier<<16 | state<<32);
# a bare block id is a valid packed value meaning "full cube, state 0", so every
# value stored today is already canonical and no migration is needed. 0 stays
# "dug to air". `cell_value_at(cell)` = edits-overlay-else-generated is THE cell
# query; `block_id_at` is its material projection.
var _edits: Dictionary = {}           # Vector3i -> int packed cell value (0 = air)
# Per-cell METADATA store (VOXEL-DATA-STRUCTURE §4.1): a SECOND sparse dict holding
# ONLY the rare cells that carry a block-entity document (container inventory, sign
# text, …). It carries NO occupancy/solidity semantics (rule-1 objection answered) —
# it is settled by the same write choke point and NEVER queried for "what's solid".
# The zero-cost-default guarantee: a metadata-free world keeps this EMPTY (O(1), zero
# per-cell cost), and `_write_cell` skips it entirely while it is empty. Main-thread,
# lifecycle-locked: only set_metadata (write) / break/place/collapse (settle) touch it.
var _meta: Dictionary = {}            # Vector3i -> Dictionary (JSON-subset document)
# Per-column monotonic high-water mark of the highest y ever PLACED (breaking a
# placed block does NOT lower it). Only bounds the collider's above-surface scan.
var _placed_top: Dictionary = {}      # Vector2i(x, z) -> int
# Sparse per-joint reinforcement (glue/weld/cement; STRUCTURAL-INTEGRITY §4.2/§7):
# canonical key Vector4i(min_cell.x, .y, .z, axis) -> reinforcement id. Lives
# OUTSIDE the four cell axes (it is per-FACE, not per-cell). The structural solver
# reads it via `joint_mod`; breaking a block leaves stale entries harmless (a joint
# with a missing cell is never queried).
var _joint_mods: Dictionary = {}      # Vector4i -> int reinforcement id

func _ready() -> void:
	environment = PerVoxelEnvironment.new()
	materials = MaterialRegistry.build_default()
	SurfaceModel.ensure_ready()
	BlockCatalog.ensure_ready()

	if ClassDB.class_exists("VoxelTerrain"):
		_setup_module_path()
	if not using_module:
		_setup_fallback_path()

	# Local terrain physics collider (both render paths are collider-less).
	_ground = GroundCollider.new()
	_ground.name = "GroundCollider"
	add_child(_ground)
	_ground.setup(self)

	path_selected.emit(using_module)
	print("[WorldManager] rendering path: ",
		"godot_voxel module" if using_module else "GDScript fallback")

func _setup_module_path() -> void:
	# module_world.gd touches godot_voxel only via ClassDB/strings and a
	# runtime-compiled generator, so loading it is safe even when the module is
	# absent (it just returns false from setup()).
	var script: Script = load("res://src/world/voxel_module/module_world.gd")
	if script == null:
		return
	var world := script.new() as Node3D
	add_child(world)
	if world.call("setup"):
		_module_world = world
		using_module = true
	else:
		world.queue_free()

func _setup_fallback_path() -> void:
	_streamer = ChunkStreamer.new()
	_streamer.name = "ChunkStreamer"
	add_child(_streamer)
	_streamer.setup(self)

## Called once the player exists (module path attaches its VoxelViewer here).
func on_player_ready(player: Node3D) -> void:
	if using_module and _module_world != null:
		_module_world.call("attach_viewer", player)

## Called every frame with the player's world position (fallback streaming +
## keeping the local ground collider centred on the player).
func update_streaming(player_pos: Vector3) -> void:
	if _streamer != null:
		_streamer.update_center(player_pos)
	if _ground != null:
		_ground.update(player_pos)

# --- terrain editing (block breaking + placing) --------------------------------

## THE composed cell query (VOXEL-DATA-STRUCTURE §7.1): edit overlay first, else
## generated terrain+trees. Returns the full PACKED cell value (material |
## modifier<<16 | state<<32); material/modifier/state are bit-projections of this
## one int, so they cannot desync. There is no second lookup that could disagree.
func cell_value_at(cell: Vector3i) -> int:
	var e: int = _edits.get(cell, -1)
	if e >= 0:
		return e                                    # overlay (already canonical)
	return TerrainConfig.generated_cell(cell.x, cell.y, cell.z)

## Material id at `cell` — the material projection of the composed query. UNCHANGED
## contract: every existing call site (floor, blocked, DDA, collider, collapse,
## both meshers, catalog/sim checks) sees the exact same 0..COUNT-1 id it always
## did, because a bare id is a canonical packed value. THE cell query for gameplay.
func block_id_at(cell: Vector3i) -> int:
	return CellCodec.mat(cell_value_at(cell))

## Composed solidity — the MATERIAL half of the merged analytic-physics contract
## (INTEGRATION-DECISIONS §3): a cell is solid iff its material passes the solidity
## gate (`solidity_of(mat) >= 0.5`). Resolves the packed value ONCE, then gates on
## the material only — a shaped (ramp) cell IS solid; where inside the cell it
## collides is expressed by the interval functions (`_occ_span`), never by this
## boolean. Byte-identical to the old `!= AIR` test for the current world (AIR → 0.0,
## every core material → 1.0). `_cell_solid`/`is_solid` are aliases of this.
func cell_solid(cell: Vector3i) -> bool:
	return BlockCatalog.solidity_of(CellCodec.mat(cell_value_at(cell))) >= 0.5

## THE occupancy-composition helper (INTEGRATION-DECISIONS §3): material solidity
## GATES, modifier SHAPES. Returns the filled vertical interval (lo, hi) of packed
## cell value `v` at footprint (fx, fz); `Vector2.ZERO` = no occupancy (air / water /
## lava / powder_snow via the material gate, or a shape empty at this footprint).
## The four analytic queries and the collider all compose against this ONE helper,
## so the material gate and the shape test can never disagree. Full-cube today →
## (0, 1) for every solid cell, so callers reduce branch-for-branch to today's code
## (one extra solidity read); P5's ShapeCodec fills the sub-cube intervals.
func _occ_span(v: int, fx: float, fz: float) -> Vector2:
	if BlockCatalog.solidity_of(CellCodec.mat(v)) < 0.5:   # 1) MATERIAL GATE
		return Vector2.ZERO
	return ShapeCodec.span(CellCodec.modifier(v), fx, fz)  # 2) SHAPE (modifier 0 -> (0,1))

## True if the cell was dug out (edit overlay says air). Used by fast column loops
## (fallback mesher tops, ground collider) that only care about air-vs-solid at/
## below the heightmap.
func is_removed(cell: Vector3i) -> bool:
	return _edits.get(cell, -1) == 0

## Highest y the player ever PLACED a block at in column (x, z); returns a deep
## negative sentinel when the column has no placements. (Bounds collider scans.)
func placed_top(x: int, z: int) -> int:
	return _placed_top.get(Vector2i(x, z), -0x40000000)

## Read-only view of the edit overlay (Vector3i -> int PACKED cell value; 0 = dug
## air, >0 = solid). The fallback mesher reads placed (value > 0) cells from it and
## MUST project the material via CellCodec.mat (a bare id is a plain packed value,
## so it is identical today) rather than treating the raw value as a block id.
func placed_cells() -> Dictionary:
	return _edits

## Topmost still-solid column height at (x, z): the noise height, lowered past any
## blocks the player has broken from the top. Because every column is solid all
## the way down, this always finds a block — the ground is never hollow. (Ignores
## placed blocks ABOVE the heightmap; those are handled by placed_cells/placed_top.)
func effective_height(x: int, z: int) -> int:
	var h := TerrainConfig.height_at(x, z)
	while is_removed(Vector3i(x, h, z)):
		h -= 1
	return h

## Break the block at `cell` (terrain, layers, tree cells, placed blocks alike).
## Returns the BROKEN BLOCK ID (>0) on success, 0 if the cell was already air.
## `from_pos` (the breaker's position) propagates to the collapse pass so any
## detached floating cluster gets a slight kick away from the breaker; pass
## Vector3.INF (default) for "no kick". Mirrors into the active render path, runs
## a local support analysis so undercut terrain drops as loose rigid bodies, then
## refreshes ground collision.
func break_terrain(cell: Vector3i, from_pos: Vector3 = Vector3.INF) -> int:
	if _edits.get(cell, -1) == 0 or not cell_solid(cell):
		return 0
	var id: int = block_id_at(cell)     # capture the MATERIAL id BEFORE carving
	_write_cell(cell, 0)                # dig to air (0 = canonical air)
	_structural_update(cell, from_pos)  # only from the player break — never a spawn
	if _ground != null:
		_ground.rebuild_now()
	return id

## Place a block into `cell`. `value` is a PACKED cell value (CellCodec) so a shaped
## partial cell (material + modifier — a ramp/slab, SUB-VOXEL-SMOOTHING §9) can be
## placed; a bare block id is a valid packed value meaning "full cube", so the
## historical `place_block(cell, id)` call site is unchanged. Fails (returns false,
## no state change) if the cell is not air (composed query), the MATERIAL is invalid
## (<=0 or >= count()) or non-solid (water/lava/powder_snow — WGC §6.3). On success
## writes the CANONICAL overlay value (canonicalization strips a modifier that can't
## apply, e.g. a corner-3 clamp), updates _placed_top, mirrors into the active render
## path and rebuilds the ground collider. Player-overlap is the CALLER's check.
func place_block(cell: Vector3i, value: int) -> bool:
	var block_id := CellCodec.mat(value)
	if block_id <= BlockCatalog.AIR or block_id >= BlockCatalog.count():
		return false
	if BlockCatalog.solidity_of(block_id) < 0.5:
		return false                       # no placing water/lava/powder_snow from the hotbar (WGC §6.3)
	if cell_solid(cell):
		return false
	_write_cell(cell, value)              # _write_cell canonicalizes (full cube if value was a bare id)
	var key := Vector2i(cell.x, cell.z)
	var prev: int = _placed_top.get(key, -0x40000000)
	if cell.y > prev:
		_placed_top[key] = cell.y
	# The placement SUCCEEDS, then the structure is judged (SI §6): an over-tall
	# pillar crushes, an undercut/unsupported placement detaches. No breaker kick on
	# a placement collapse (from_pos = Vector3.INF).
	_structural_update(cell, Vector3.INF)
	if _ground != null:
		_ground.rebuild_now()
	return true

## THE single write choke point (VOXEL-DATA-STRUCTURE §7.2): the ONLY function
## that mutates a cell's overlay value, now owning ALL FOUR axes. break/place/collapse
## all route here. It canonicalizes the packed value (air-zeroing + P5/P6 hooks),
## stores it in `_edits`, SETTLES the cell's metadata, and mirrors the resulting
## MATERIAL into the active render path.
##
## Metadata settlement (the leak-proof invariant, §7.2/§16): a write DROPS the cell's
## existing metadata unless the SAME call supplies replacement `meta` for a block-entity
## material. break/place/collapse never pass `meta`, so they always drop+orphan any
## existing document — there is no code path that changes a cell's material and skips
## metadata cleanup, because there is only one write function. `set_state` re-passes the
## existing document (same material → block-entity) so it is PRESERVED without an orphan.
##
## Zero-cost default: with an empty `_meta` and no `meta` argument (today's every write),
## the settlement collapses to a single `is_empty()` check — gameplay stays byte-identical.
func _write_cell(cell: Vector3i, packed: int, meta: Variant = null) -> void:
	packed = CellCodec.canonical(packed)
	if meta != null and BlockCatalog.has_block_entity(CellCodec.mat(packed)):
		_meta[cell] = meta                       # the one write that (re)sets metadata
	elif not _meta.is_empty():
		var old_meta: Variant = _meta.get(cell, null)
		if old_meta != null:
			_meta.erase(cell)                    # material change / break settles it
			block_entity_orphaned.emit(cell, old_meta)
	_edits[cell] = packed
	_paint_cell(cell, packed)

# --- per-cell metadata + state axis (VOXEL-DATA-STRUCTURE §7.2 / §3.1) -----------

## Serialized-metadata size cap per cell (§16): the unbounded axis by nature, so
## `set_metadata` refuses (and logs) any document over this. Chest-heavy legit docs
## sit far below it.
const META_MAX_BYTES := 16 * 1024

## Attach/replace the block-entity METADATA document at `cell`. Validates loudly and
## returns false (no state change) if: the cell's MATERIAL is not a block-entity
## material (`has_block_entity` false — incl. air), the document is not JSON-representable
## (§3.2: String keys; bool/int/float/String/Array/Dictionary values; NO Object refs, NO
## NaN/INF), or it exceeds the §16 size cap. Stores a DEEP COPY so later caller mutations
## cannot alias the stored document. Keeps the scalar axes (`_edits`) untouched; fires no
## orphan signal (an explicit update is not a drop).
func set_metadata(cell: Vector3i, meta: Dictionary) -> bool:
	var mat := CellCodec.mat(cell_value_at(cell))
	if not BlockCatalog.has_block_entity(mat):
		push_error("WorldManager.set_metadata: material %d at %s is not a block-entity material (rejected)" % [mat, cell])
		return false
	if not _metadata_dict_ok(meta):
		push_error("WorldManager.set_metadata: document at %s is not JSON-representable (Object/NaN/INF or non-String key) — rejected" % cell)
		return false
	if JSON.stringify(meta).to_utf8_buffer().size() > META_MAX_BYTES:
		push_error("WorldManager.set_metadata: document at %s exceeds the %d-byte cap — rejected" % [cell, META_MAX_BYTES])
		return false
	_meta[cell] = meta.duplicate(true)
	return true

## The block-entity METADATA document at `cell`; an EMPTY dict when the cell carries
## none. Returns a DEEP COPY — mutating it never changes the stored document (route
## real updates through `set_metadata`).
func get_metadata(cell: Vector3i) -> Dictionary:
	var m: Variant = _meta.get(cell, null)
	return (m as Dictionary).duplicate(true) if m != null else {}

## True iff `cell` currently carries a metadata document.
func has_metadata(cell: Vector3i) -> bool:
	return _meta.has(cell)

## Set the STATE axis (bits 32..47) of `cell`, keeping its material + modifier and
## PRESERVING any metadata (the one write that does — §11). Returns false on air.
## The state bits are canonicalized/validated through `CellCodec` (today's validator is
## pass-through; no material declares a state layout yet, so any value round-trips).
func set_state(cell: Vector3i, state_bits: int) -> bool:
	var v := cell_value_at(cell)
	var mat := CellCodec.mat(v)
	if mat == BlockCatalog.AIR:
		return false                             # air carries no state
	var new_packed := CellCodec.pack(mat, CellCodec.modifier(v), state_bits)
	# Re-pass the existing document so the choke point KEEPS it (same material → still a
	# block-entity) rather than orphaning it: set_state is a behavioural, not material, edit.
	_write_cell(cell, new_packed, _meta.get(cell, null))
	return true

## JSON-subset validator (§3.2): a metadata document restricted to String keys and
## bool/int/finite-float/String/Array/Dictionary values, recursively. Rejects Object
## references (they cannot serialize / cross threads) and NaN/INF (they break byte-stable
## round-trips). Pure/static so it is trivially testable.
static func _metadata_dict_ok(d: Dictionary) -> bool:
	for k: Variant in d.keys():
		if typeof(k) != TYPE_STRING:
			return false
		if not _metadata_value_ok(d[k]):
			return false
	return true

static func _metadata_value_ok(v: Variant) -> bool:
	match typeof(v):
		TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(v)                  # no NaN / INF (byte-stable round-trips)
		TYPE_ARRAY:
			for e: Variant in v:
				if not _metadata_value_ok(e):
					return false
			return true
		TYPE_DICTIONARY:
			return _metadata_dict_ok(v)
		_:
			return false                         # Object refs and every other type rejected

## Mirror one cell's PACKED value into the active render path (0 = carve to air).
## Shared by _write_cell so the godot_voxel / fallback plumbing lives in one place.
## The module path resolves the (material, modifier) to a baked appearance id (ARID,
## VDS §8.1) so a placed ramp/slab renders its shape; the fallback re-reads the world
## query when it remeshes the cell, so it only needs the cell coordinate. The caller
## (_write_cell) owns the `_edits` overlay; break/place own the ground rebuild.
func _paint_cell(cell: Vector3i, packed: int) -> void:
	if using_module and _module_world != null:
		_module_world.call("set_cell", cell, packed)
	elif _streamer != null:
		_streamer.remesh_cell(cell)

# --- terrain collapse (unsupported/overloaded blocks fall) ---------------------
# The support analysis itself lives in StructuralSolver (STRUCTURAL-INTEGRITY §5);
# WorldManager owns only the resulting carve + VoxelBody spawn (_structural_update).

## The 6 axis neighbours, reused by the component grouping (and formerly the flood).
const _NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Structural-integrity update around a just-edited cell (STRUCTURAL-INTEGRITY §6):
## the StructuralSolver decides which cells detach or crumble (pass 0 connectivity —
## today's flood, so tree-chop is preserved — plus load-bearing flow + moment audit
## for player builds), and this function carves that set out and drops the 6-connected
## components as loose VoxelBody debris, exactly as the old collapse did. Cheap on the
## common case: flat digging that undercuts nothing early-outs inside solve() (pass 0
## reaches everything, pass 1 finds no overload → the solver returns an empty set).
##
## MUST be called only from the player-initiated break_terrain / place_block, never
## from a spawn path, so it cannot recurse (a landing VoxelBody is physics-side).
func _structural_update(center: Vector3i, from_pos: Vector3) -> void:
	var falling: Dictionary = StructuralSolver.solve(self, center)
	if falling.is_empty():
		return   # common case: nothing detaches, spawn nothing

	# Group the detaching cells into 6-neighbour connected components; each becomes
	# one body. Capture each cell's PACKED value BEFORE carving (so mixed grass/dirt/
	# stone and wood+leaf canopies keep their materials and, later, shape/state), then
	# carve the component and drop it as one loose body. from_pos kicks it away from
	# the breaker (Vector3.INF on a placement collapse = no kick).
	var seen: Dictionary = {}
	for start: Vector3i in falling.keys():
		if seen.has(start):
			continue
		var comp: Array[Vector3i] = []
		var cstack: Array[Vector3i] = [start]
		seen[start] = true
		while not cstack.is_empty():
			var c: Vector3i = cstack.pop_back()
			comp.append(c)
			for d: Vector3i in _NEIGHBORS_6:
				var nc := c + d
				if falling.has(nc) and not seen.has(nc):
					seen[nc] = true
					cstack.append(nc)
		var comp_ids: Dictionary = {}   # Vector3i -> int packed cell value
		for c: Vector3i in comp:
			comp_ids[c] = cell_value_at(c)
		for c: Vector3i in comp:
			_write_cell(c, 0)
		VoxelBody.spawn_loose(self, comp_ids, self, from_pos)

# --- per-joint reinforcement (STRUCTURAL-INTEGRITY §4.2/§7) ---------------------

## The canonical unordered joint key for the pair of 6-adjacent cells (a, b): the
## component-wise-smaller cell + the axis they differ on (0=x, 1=y, 2=z).
static func _joint_key(a: Vector3i, b: Vector3i) -> Vector4i:
	var axis := 0 if a.x != b.x else (1 if a.y != b.y else 2)
	return Vector4i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z), axis)

## Reinforcement id on the joint between 6-adjacent cells (a, b); 0 = unreinforced.
## The structural solver reads this for every joint's F_t/F_s/M₀ (StructuralModel).
func joint_mod(a: Vector3i, b: Vector3i) -> int:
	return int(_joint_mods.get(_joint_key(a, b), 0))

## Reinforce the joint between the two 6-adjacent cells with `reinf_id` (a
## StructuralModel reinforcement id; 0 clears it). Returns false if the cells are
## not 6-adjacent. One reinforcement per joint (placing a new one replaces the old).
func reinforce_joint(a: Vector3i, b: Vector3i, reinf_id: int) -> bool:
	var diff := b - a
	if absi(diff.x) + absi(diff.y) + absi(diff.z) != 1:
		return false
	if reinf_id == 0:
		_joint_mods.erase(_joint_key(a, b))
	else:
		_joint_mods[_joint_key(a, b)] = reinf_id
	return true

# --- analytic world queries (path-agnostic) ------------------------------------

## Walkable surface height (world y of the top of the ground) at (x, z), accounting
## for broken blocks from the TOP — used for spawning pillars and the grounded test.
func surface_y(x: float, z: float) -> float:
	return float(effective_height(int(floor(x)), int(floor(z))) + 1)

## The y the player should stand at in column (x, z) given their current feet
## height. Plain, NO-CLIMB floor: scan DOWN from the feet for the first solid block
## that has AIR directly above it (the actual standable surface) and stand on its
## top. Crucially it does NOT pop the player up to the column top when the feet cell
## is buried — walling into a hillside must not teleport the player onto the hilltop.
## Horizontal movement into terrain is now stopped by blocked() (the player queries
## it per-axis), so the feet are always at or just above an air-topped surface and a
## valid floor is always found; the scan honours dug shafts/tunnels below as well.
func floor_under(x: float, z: float, feet_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)   # in-cell footprint (ignored by full cubes; used by P5 shapes)
	var fz := z - float(zi)
	# Start at the feet directly (NO clamp to the noise top): players stand on trees
	# and placed towers ABOVE the heightmap, and clamping down would teleport them
	# off. Scan length is bounded by the fall distance — cheap.
	var start := int(floor(feet_y + 0.5))
	var y := start
	# Merged contract (INTEGRATION-DECISIONS §3): the per-cell test is `_occ_span`, so
	# non-solid materials (water) yield the empty span and are scanned THROUGH to the
	# seafloor, while a solid cell yields its filled interval — the floor is the top of
	# the first occupied cell that has an empty span directly above (its top = span.y;
	# 1.0 for a full cube ⇒ float(y+1), byte-identical to the old solid/air-above test).
	while y > -1024:
		var here := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if here != Vector2.ZERO and _occ_span(cell_value_at(Vector3i(xi, y + 1, zi)), fx, fz) == Vector2.ZERO:
			return float(y) + here.y
		y -= 1
	return float(effective_height(xi, zi) + 1)

## Max in-cell rise a walker may auto-step over without being blocked (SVS §5.2). A
## full cube's rise is 1.0 m > STEP_MAX, so every full cube still blocks (byte-identical
## to flat/blocky ground); a ramp/slab surface `<= STEP_MAX` above the feet is walked
## up, not blocked (the deliberate half-slab-as-stairs side effect).
const STEP_MAX := 0.55
## Player standing body height (feet → head) used for the headroom test.
const _BODY_HEIGHT := 1.8
const _EPS := 1e-6

## True if the player cannot stand at column (floor(x), floor(z)) with feet at feet_y
## because the standable surface just ahead is too tall to step onto (> STEP_MAX above
## the feet) OR the body would clip a solid cell overhead (SUB-VOXEL-SMOOTHING §5.2).
## Composes over the merged `floor_under`/`_occ_span`, so the material gate comes for
## free (water never blocks) and shapes auto-step. BYTE-IDENTICAL for the current
## all-full-cube world: a full cube ahead raises the standable surface 1.0 m (> STEP_MAX
## → wall), a body span overlapping the ground finds its surface far above the buried
## feet (→ wall), and open air raises nothing (→ not blocked).
func blocked(x: float, z: float, feet_y: float) -> bool:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	# Standable height at the target column, allowing an auto-step up to STEP_MAX.
	var top := floor_under(x, z, feet_y + STEP_MAX)
	if top - feet_y > STEP_MAX:
		return true                                    # rise too big → wall (a full cube's 1.0 always is)
	# Headroom above the (possibly auto-stepped) floor: the body must not clip a solid
	# cell in (top, top + body height) at this footprint.
	return not _headroom_clear(xi, zi, fx, fz, top)

## True if the player's body column (top .. top + body height) at footprint (fx, fz)
## in column (xi, zi) is clear of solid occupancy (SVS §5.2). The cell whose top the
## player stands on ends exactly at `top`, so it never counts as a clip (its interval
## upper bound == top, tested with an epsilon bias). A TOP-anchored slab / full cube
## overhead correctly blocks standing.
func _headroom_clear(xi: int, zi: int, fx: float, fz: float, top: float) -> bool:
	var head := top + _BODY_HEIGHT
	var y := int(floor(top))
	var y_hi := int(floor(head - _EPS))
	while y <= y_hi:
		var sp := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if sp != Vector2.ZERO:
			var occ_lo := float(y) + sp.x
			var occ_hi := float(y) + sp.y
			if occ_hi > top + _EPS and occ_lo < head - _EPS:
				return false
		y += 1
	return true

func is_solid(pos: Vector3) -> bool:
	return cell_solid(Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z))))

## Voxel-DDA ray (Amanatides & Woo) against the heightmap. Returns
## {hit, voxel:Vector3i, normal:Vector3i, position:Vector3}.
##
## Merged contract (INTEGRATION-DECISIONS §3): the DDA cell walk is unchanged; each
## cell is tested by the MATERIAL gate first (`cell_solid` = solidity ≥ 0.5), so the
## ray passes THROUGH non-solid materials (water/lava) and targets what's behind
## them. A hit on a solid cell reports the cell-BOUNDARY crossing (today's fast path,
## exact for modifier 0). P5 SEAM: for a shaped (ramp) cell, `cell_solid` still gates
## entry, then an in-cell surface ray test (SVS §5.3) refines the hit point/normal
## within the cell — full cubes need no refinement, so the boundary hit stands.
func aimed_voxel(origin: Vector3, dir: Vector3, max_dist: float = 8.0) -> Dictionary:
	var d := dir.normalized()
	var cell := Vector3i(int(floor(origin.x)), int(floor(origin.y)), int(floor(origin.z)))
	var step := Vector3i(signi(int(sign(d.x))), signi(int(sign(d.y))), signi(int(sign(d.z))))
	var t_max := Vector3(_first_cross(origin.x, d.x), _first_cross(origin.y, d.y), _first_cross(origin.z, d.z))
	var t_delta := Vector3(
		INF if d.x == 0.0 else 1.0 / absf(d.x),
		INF if d.y == 0.0 else 1.0 / absf(d.y),
		INF if d.z == 0.0 else 1.0 / absf(d.z))
	var t := 0.0
	var normal := Vector3i.ZERO

	# The starting cell could already be solid (e.g. camera clipping ground).
	if _cell_solid(cell):
		return {"hit": true, "voxel": cell, "normal": Vector3i.UP,
			"position": origin}

	while t <= max_dist:
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x; t = t_max.x; t_max.x += t_delta.x
			normal = Vector3i(-step.x, 0, 0)
		elif t_max.y < t_max.z:
			cell.y += step.y; t = t_max.y; t_max.y += t_delta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			cell.z += step.z; t = t_max.z; t_max.z += t_delta.z
			normal = Vector3i(0, 0, -step.z)
		if _cell_solid(cell):
			var v := cell_value_at(cell)
			var m := CellCodec.modifier(v)
			if m == 0:
				return {"hit": true, "voxel": cell, "normal": normal,
					"position": origin + d * t}   # full cube: boundary hit (unchanged fast path)
			# Shaped cell (SVS §5.3): in-cell surface test. t is the entry into this
			# cell; the exit is the next boundary crossing on any axis.
			var t_out: float = minf(t_max.x, minf(t_max.y, t_max.z))
			var res := _ray_vs_partial(m, cell, origin, d, t, t_out, normal)
			if not res.is_empty():
				return res
			# Miss: the ray passed through the empty part of the cell — continue the DDA.
	return {"hit": false, "voxel": Vector3i.ZERO, "normal": Vector3i.ZERO,
		"position": origin + d * max_dist}

## In-cell ray test against a shaped (non-full) solid cell (SUB-VOXEL-SMOOTHING §5.3).
## The caller has already applied the material gate. Completeness: every boundary face
## of a corner-height shape is either on the cell boundary (covered by the entry-point
## occupancy test) or on the 1–2 surface triangles (covered by ray/plane tests). The
## reported `normal` stays axis-aligned (the DDA face for a boundary hit, UP/DOWN for a
## surface hit) to preserve the break/place adjacency contract; the true sloped normal
## is exposed as `surface_normal`. Empty dict = miss (the DDA continues).
func _ray_vs_partial(m: int, cell: Vector3i, origin: Vector3, d: Vector3,
		t_in: float, t_out: float, dda_normal: Vector3i) -> Dictionary:
	var base := Vector3(cell)
	var p_in := origin + d * t_in - base
	if ShapeCodec.occupied(m, p_in.x, p_in.y, p_in.z):
		return {"hit": true, "voxel": cell, "normal": dda_normal,
			"position": origin + d * t_in, "surface_normal": Vector3(dda_normal)}
	var place_n := Vector3i.UP if ShapeCodec.anchor(m) == ShapeCodec.ANCHOR_BOTTOM else Vector3i.DOWN
	var p0 := origin - base
	for tri: Dictionary in ShapeCodec.surface_tris(m):
		var pn: Vector3 = tri["normal"]
		var denom := d.dot(pn)
		if absf(denom) < 1e-9:
			continue                                   # ray parallel to the surface plane
		var th := (Vector3(tri["v0"]) - p0).dot(pn) / denom
		if th < t_in - _EPS or th > t_out + _EPS:
			continue                                   # plane hit outside this cell's ray span
		var hp := p0 + d * th
		if _point_in_tri_xz(hp, tri["v0"], tri["v1"], tri["v2"]):
			return {"hit": true, "voxel": cell, "normal": place_n,
				"position": origin + d * th, "surface_normal": pn}
	return {}

## True if the XZ projection of point `p` lies inside triangle (a, b, c) — the surface
## is a single-valued height field over XZ, so XZ containment is exact. Barycentric.
func _point_in_tri_xz(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var v0x := c.x - a.x
	var v0z := c.z - a.z
	var v1x := b.x - a.x
	var v1z := b.z - a.z
	var v2x := p.x - a.x
	var v2z := p.z - a.z
	var d00 := v0x * v0x + v0z * v0z
	var d01 := v0x * v1x + v0z * v1z
	var d11 := v1x * v1x + v1z * v1z
	var d20 := v2x * v0x + v2z * v0z
	var d21 := v2x * v1x + v2z * v1z
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 1e-12:
		return false                                   # degenerate triangle (no XZ area)
	var u := (d11 * d20 - d01 * d21) / denom
	var vv := (d00 * d21 - d01 * d20) / denom
	return u >= -_EPS and vv >= -_EPS and u + vv <= 1.0 + _EPS

# Internal alias kept for the collapse pass + DDA; delegates to the composed
# public query (edit overlay first, else generated terrain + trees), so removed
# cells are air and placed/tree cells are solid ray/collapse targets.
func _cell_solid(cell: Vector3i) -> bool:
	return cell_solid(cell)

## Render-only face-cull composition (INTEGRATION-DECISIONS §3): does the neighbour
## whose PACKED value is `nb_value` occlude the shared face of a cell in cull-group
## `my_group` (the viewed material's `transparency_index_of`)? True iff BOTH:
##   (1) the neighbour's MATERIAL occludes — it is solid AND its transparency index
##       is ≤ my_group (the transparency-index rule: an opaque neighbour always
##       occludes; you see THROUGH a more-transparent one, e.g. stone behind glass);
##   (2) its facing side profile fully covers the shared face (`face` = the
##       neighbour-direction index; modifier 0 ⇒ trivially full — today's fast path).
## Static/pure (no world state). For the current all-opaque, full-cube world this is
## exactly `cell_solid(neighbour)`, so it ships as the SEAM P3's translucent
## materials (glass/water) fill in — the fallback mesher's cull test is deliberately
## left on `cell_solid` until then (see chunk_mesher._emit_cube) to guarantee the
## byte-identical visual gate; the module path's culling is config (transparency_index),
## unchanged.
static func occludes_face(nb_value: int, my_group: int, face: int = 0) -> bool:
	var nb_mat := CellCodec.mat(nb_value)
	if BlockCatalog.solidity_of(nb_mat) < 0.5:
		return false                                   # air / water / lava never occlude
	if BlockCatalog.transparency_index_of(nb_mat) > my_group:
		return false                                   # see through a more-transparent neighbour
	return ShapeCodec.side_profile_full(CellCodec.modifier(nb_value), face)

# Distance along one axis to the first integer boundary in the ray's direction.
static func _first_cross(o: float, dir: float) -> float:
	if dir == 0.0:
		return INF
	var cell := floorf(o)
	if dir > 0.0:
		return (cell + 1.0 - o) / dir
	return (o - cell) / -dir
