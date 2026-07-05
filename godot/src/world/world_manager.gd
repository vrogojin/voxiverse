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
# Per-column monotonic high-water mark of the highest y ever PLACED (breaking a
# placed block does NOT lower it). Only bounds the collider's above-surface scan.
var _placed_top: Dictionary = {}      # Vector2i(x, z) -> int

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
	_collapse_unsupported(cell, from_pos)   # only from the player break — never a spawn
	if _ground != null:
		_ground.rebuild_now()
	return id

## Place one block of `block_id` into `cell`. Fails (returns false, no state
## change) if the cell is not air (composed query), block_id is invalid (<=0 or
## >= BlockCatalog.count()), or the material is non-solid (water/lava/powder_snow —
## WGC §6.3). On success writes the overlay, updates _placed_top,
## mirrors into the active render path and rebuilds the ground collider.
## Player-overlap is the CALLER's check (the world doesn't know where the player is).
func place_block(cell: Vector3i, block_id: int) -> bool:
	if block_id <= BlockCatalog.AIR or block_id >= BlockCatalog.count():
		return false
	if BlockCatalog.solidity_of(block_id) < 0.5:
		return false                       # no placing water/lava/powder_snow from the hotbar (WGC §6.3)
	if cell_solid(cell):
		return false
	_write_cell(cell, CellCodec.pack(block_id))   # full cube, default state
	var key := Vector2i(cell.x, cell.z)
	var prev: int = _placed_top.get(key, -0x40000000)
	if cell.y > prev:
		_placed_top[key] = cell.y
	if _ground != null:
		_ground.rebuild_now()
	return true

## THE single write choke point (VOXEL-DATA-STRUCTURE §7.2): the ONLY function
## that mutates a cell's overlay value. break/place/collapse all route here. It
## canonicalizes the packed value (air-zeroing + P5/P6 hooks), stores it in
## `_edits`, and mirrors the resulting MATERIAL into the active render path. Keeps
## every existing semantic — a bare id in, a bare id painted — while making the
## overlay shape/state-ready. (Metadata settlement lands in P1.)
func _write_cell(cell: Vector3i, packed: int) -> void:
	packed = CellCodec.canonical(packed)
	_edits[cell] = packed
	_paint_cell(cell, CellCodec.mat(packed))

## Mirror one cell's MATERIAL id into the active render path (0 = carve to air).
## Shared by _write_cell so the godot_voxel / fallback plumbing lives in one
## place. The caller (_write_cell) owns the `_edits` overlay; break/place own the
## ground rebuild.
func _paint_cell(cell: Vector3i, block_id: int) -> void:
	if using_module and _module_world != null:
		_module_world.call("set_cell", cell, block_id)
	elif _streamer != null:
		_streamer.remesh_cell(cell)

# --- terrain collapse (unsupported blocks fall) --------------------------------

## Half-extent of the square column region the collapse scan examines around a break.
const _COLLAPSE_RADIUS := 5

## The 6 axis neighbours, reused by the support flood-fill and the component grouping.
const _NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Local support analysis around a just-broken cell: any solid, non-broken terrain
## no longer connected (through solid cells) to the always-supported bottom row
## becomes falling rigid bodies. Cheap on the common case (flat digging undercuts
## nothing → the flood-fill reaches every cell → zero floaters → early return).
##
## MUST be called only from the player-initiated break_terrain, never from a spawn
## path, so it cannot recurse.
func _collapse_unsupported(center: Vector3i, from_pos: Vector3) -> void:
	var x0 := center.x - _COLLAPSE_RADIUS
	var x1 := center.x + _COLLAPSE_RADIUS
	var z0 := center.z - _COLLAPSE_RADIUS
	var z1 := center.z + _COLLAPSE_RADIUS

	# Vertical bounds: top = tallest column PLUS the max tree/placed height above the
	# surface (so canopies and player towers participate in the support analysis);
	# bottom = shortest column minus 2, a row solid in every column that connects to
	# the untouched bulk.
	var max_h := -0x3FFFFFFF
	var y_lo_top := 0x3FFFFFFF
	var placed_hi := -0x40000000
	var xi := x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var h := TerrainConfig.height_at(xi, zi)
			if h > max_h:
				max_h = h
			if h < y_lo_top:
				y_lo_top = h
			placed_hi = maxi(placed_hi, placed_top(xi, zi))
			zi += 1
		xi += 1
	var y_hi := maxi(max_h + TreeGen.MAX_ABOVE_SURFACE, placed_hi)
	var y_lo := y_lo_top - 2

	# Seed support from every solid cell on the region BOUNDARY shell — the bottom
	# row (deep bulk) AND the 4 side faces. A cell touching a side face connects to
	# untouched terrain OUTSIDE the search box, which we conservatively treat as
	# supported. Seeding only the bottom row would wrongly flag a shelf propped from
	# outside the box as floating and carve it away; biasing toward "supported" at
	# the boundary means we never destroy genuinely-supported terrain (a floater
	# from the dig sits near the box CENTRE, so it is still detected).
	var supported: Dictionary = {}
	var stack: Array[Vector3i] = []
	xi = x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var on_boundary := xi == x0 or xi == x1 or zi == z0 or zi == z1
			var y := y_lo
			while y <= y_hi:
				if (on_boundary or y == y_lo) and _cell_solid(Vector3i(xi, y, zi)):
					var seed := Vector3i(xi, y, zi)
					if not supported.has(seed):
						supported[seed] = true
						stack.append(seed)
				y += 1
			zi += 1
		xi += 1
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		for d: Vector3i in _NEIGHBORS_6:
			var nc := c + d
			if nc.x < x0 or nc.x > x1 or nc.z < z0 or nc.z > z1 or nc.y < y_lo or nc.y > y_hi:
				continue
			if supported.has(nc):
				continue
			if _cell_solid(nc):
				supported[nc] = true
				stack.append(nc)

	# Collect solid cells the flood never reached — these are floating.
	var floating: Dictionary = {}
	xi = x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var y := y_lo
			while y <= y_hi:
				var c := Vector3i(xi, y, zi)
				if _cell_solid(c) and not supported.has(c):
					floating[c] = true
				y += 1
			zi += 1
		xi += 1
	if floating.is_empty():
		return   # common case: nothing undercut, spawn nothing

	# Group floaters into 6-neighbour connected components; each becomes one body.
	var seen: Dictionary = {}
	for start: Vector3i in floating.keys():
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
				if floating.has(nc) and not seen.has(nc):
					seen[nc] = true
					cstack.append(nc)
		# Capture each cell's PACKED value BEFORE carving (so mixed grass/dirt/stone and
		# wood+leaf canopies keep their materials — and, once modifiers/state land, their
		# shape and variant too), then carve the component out of the terrain and drop it
		# as one loose body — VoxelBody projects materials + masses from the packed values
		# itself. A bare id is a valid packed value, so this is byte-identical today.
		# from_pos kicks the cluster away from the breaker.
		var comp_ids: Dictionary = {}   # Vector3i -> int packed cell value
		for c: Vector3i in comp:
			comp_ids[c] = cell_value_at(c)
		for c: Vector3i in comp:
			_write_cell(c, 0)
		VoxelBody.spawn_loose(self, comp_ids, self, from_pos)

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

## Max in-cell rise a walker may auto-step over without being blocked (SVS §5.2).
## P5 SEAM: once sub-cube shapes exist, `blocked` gains the SVS §5.2 floor-then-
## headroom auto-step (a ramp/slab surface `<= STEP_MAX` above the feet is walked
## up, not blocked). It is INERT for the current world — a full cube's rise is 1.0 m
## > STEP_MAX, so every full cube still blocks — so P2 keeps the plain body-span
## occupancy scan below (byte-identical) and defers the auto-step to when ramps land.
const STEP_MAX := 0.55

## True if any solid, non-broken terrain cell overlaps the player's vertical body
## span at column (floor(x), floor(z)). The player is ~1.8 m tall standing with feet
## at feet_y; the player agent calls this per-axis to stop horizontal movement into
## a wall (the terrain itself is collider-less, so nothing else does).
func blocked(x: float, z: float, feet_y: float) -> bool:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	var y_lo := int(floor(feet_y + 0.1))
	var y_hi := int(floor(feet_y + 1.7))
	var y := y_lo
	# Merged contract (INTEGRATION-DECISIONS §3): the per-cell test is `_occ_span`, so
	# a non-solid material (water) yields the empty span and does NOT block, while a
	# full cube (span (0,1) ≠ ZERO) blocks exactly as before — byte-identical to the
	# old `_cell_solid` body-span scan for the current all-full-cube world.
	while y <= y_hi:
		if _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz) != Vector2.ZERO:
			return true
		y += 1
	return false

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
			return {"hit": true, "voxel": cell, "normal": normal,
				"position": origin + d * t}
	return {"hit": false, "voxel": Vector3i.ZERO, "normal": Vector3i.ZERO,
		"position": origin + d * max_dist}

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
