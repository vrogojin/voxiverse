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

# COSMOS M2 — the floating-origin chart (docs/COSMOS-PLANET-TOPOLOGY.md §3.1/§3.2). NULL in
# FLAT_WORLD (the default): the edit store keys by Vector3i window cell and every query is
# BYTE-IDENTICAL to the pre-M2 flat world. Non-null ONLY in curved mode (installed in _ready when
# CubeSphere.FLAT_WORLD is false, or injected by the M2 verify): the `_edits`/`_meta` overlays then
# key by the 43-bit GLOBAL edit key (§1.3) so an edit is found again by its global identity across
# any origin re-anchor or home face, and worldgen reads the window-independent GLOBAL cell (§8.2).
var _chart: CosmosChart = null

var _streamer: ChunkStreamer          # fallback path
var _module_world: Node3D             # godot_voxel path
var _ground: GroundCollider           # local blocky physics collider
var _far: FarTerrain                  # far-distance analytic heightmap layer (LOD-DESIGN); null when disabled

# COSMOS M4 (§5.1): true while a home-face flip's near field is restreaming (MODULE path only). Set in
# maybe_flip_home_face, cleared in update_streaming once the module reports ramp_done() — at which point
# player edits are re-mirrored into the fresh terrain (§5.4) and the far handoff turbo is ended. Never set
# in FLAT_WORLD (no chart → no flip) or on the fallback path (it re-reads the overlay when it remeshes).
var _flip_settling := false

# COSMOS-CORNER-CANONICAL (#69) companion — the TOPOLOGY §5.3 edit-lock. SEPARABLE: set false (or delete
# this const + the guard in _write_cell) to drop it. When true, a write to a corner-quadrant window cell
# (double-out on the active chart) is REFUSED — the wedge is a per-window sampling of the canonical
# terrain (COSMOS-CORNER-CANONICAL §4.2/§4.3), so an edit there has no stable window identity to
# re-mirror (unfold_to_window returns not-found for the quadrant). Curved-only (guarded on `_chart`), so
# FLAT_WORLD stays byte-identical. Entangled with corner gate (c4): c4 checks store+read when this is
# false and refusal when true.
const CORNER_EDIT_LOCK := true

# The dormant-by-default snowfall SIMULATION (SNOW-ACCUMULATION Decision 4). Owned here and stepped from
# `_process` on the MAIN thread; it grows/melts the variable-height snow around the player by writing
# through the ONE choke point (`_write_cell` → `_edits`), so its output is persisted exactly like a
# break/place edit. It is INERT until the player's position has been reported at least once (so it never
# runs during the frozen prewarm, or in a headless world that has no player).
var _snowfall: SnowfallSystem
var _last_player_pos: Vector3 = Vector3.ZERO
var _have_player_pos: bool = false

# Terrain edit overlay: the gameplay source of truth (floor + raycast + collider +
# collapse consult it), mirrored into whichever render path runs. This one
# dictionary replaces the old `_removed` set: 0 = dug to air, >0 = solid cell.
# Values are PACKED cell values (CellCodec: material | modifier<<16 | state<<32);
# a bare block id is a valid packed value meaning "full cube, state 0", so every
# value stored today is already canonical and no migration is needed. 0 stays
# "dug to air". `cell_value_at(cell)` = edits-overlay-else-generated is THE cell
# query; `block_id_at` is its material projection.
var _edits: Dictionary = {}           # Vector3i -> int packed cell value (0 = air)
# Per-column edit INDEX (PERF, GroundCollider fast path): the set of columns Vector2i(x, z)
# that have ANY overlay entry (dug or placed). Edits never leave `_edits` (a dug cell stays
# as value 0), so this only grows — maintained in the single write choke point. The collider
# skips its per-cell overlay scan on columns absent here (their overlay is empty), collapsing
# the region's ~30k Vector3i lookups to the handful of genuinely-edited columns.
var _edit_columns: Dictionary = {}    # Vector2i(x, z) -> true
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

	# COSMOS M2 (§3.1/§3.2): in curved mode install the floating-origin chart on the home face at
	# the identity origin, so the overlay keys globally and the origin can re-anchor as the player
	# walks. FLAT_WORLD (the default) leaves `_chart` null → Vector3i keying → byte-identical.
	if not CubeSphere.FLAT_WORLD:
		_chart = CosmosChart.new(CubeSphere.HOME_BODY, CubeSphere.HOME_FACE, 0, 0)
		TerrainConfig.set_active_frame(_chart.face, CubeSphere.d4_of(_chart.m_win()))   # COSMOS-FRAME-ORIENTATION §6 (Q2d1): atomic face+M_win
		environment.set_chart(_chart)
		_m5_sync_frame()   # COSMOS M5a: push the chart table to the true-position shader (no-op when M5_RENDER off)

	if ClassDB.class_exists("VoxelTerrain"):
		_setup_module_path()
	if not using_module:
		_setup_fallback_path()

	# Local terrain physics collider (both render paths are collider-less).
	_ground = GroundCollider.new()
	_ground.name = "GroundCollider"
	add_child(_ground)
	_ground.setup(self)

	# The snowfall sim reads/writes the SAME overlay + generation both render paths derive from, so it is
	# path-agnostic. It is created here but stays inert until the player reports a position (see _process).
	_snowfall = SnowfallSystem.new()
	_snowfall.setup(self)
	# Far-distance terrain layer (LOD-DESIGN): render-only, collision-free, voxel-worker-free —
	# part of "the world" WorldManager owns. Path-agnostic (it reads only TerrainConfig/BlockCatalog/
	# ClimateModel), so it runs identically over the module world, the GDScript fallback and headless.
	# Gated on the single ENABLED const: false → no node, today's behaviour bit-for-bit.
	if FarTerrain.ENABLED:
		_far = FarTerrain.new()
		_far.name = "FarTerrain"
		add_child(_far)
		# COSMOS: the far layer renders in the GLOBAL-index frame, offset −(i_org, 0, j_org) so its
		# tiles sample the SAME global column the near voxel field renders at each world spot (Fable
		# Stage 1). At spawn the chart is at (0,0) → ZERO; kept in lockstep on re-anchor/flip below.
		# FLAT_WORLD (no chart) leaves it at ZERO → byte-identical to the pre-COSMOS far layer.
		if _chart != null:
			_far.position = _chart.node_origin()      # COSMOS-FRAME-ORIENTATION §5.3: −M_win⁻¹·org (=−org at spawn)
			_far.set_chart(_chart)                     # COSMOS R1 (M5_REAL): the far bakes/aligns against the chart

	path_selected.emit(using_module)
	print("[WorldManager] rendering path: ",
		"godot_voxel module" if using_module else "GDScript fallback")

	# COSMOS R1 DEV: hide the NEAR chunk render so the baked far layer can be inspected alone (render-only —
	# analytic physics + GroundCollider are untouched, so movement/collision are unchanged). Curved + dev only.
	if not CubeSphere.FLAT_WORLD and CubeSphere.DEV_HIDE_NEAR:
		# Module path: node visibility does NOT reach godot_voxel's RID mesh blocks, so collapse the module's
		# own streaming radius (max_view_distance) — the reliable lever — leaving only a tiny platform under
		# the player. Fallback path uses MeshInstance3D children, so plain node visibility works there.
		if _module_world != null and _module_world.has_method("set_render_hidden"):
			_module_world.call("set_render_hidden", true)
		if _streamer != null:
			_streamer.visible = false
		print("[WorldManager] DEV_HIDE_NEAR: near chunk render hidden (far layer isolated)")

## Step the dormant-by-default snowfall sim on the MAIN thread once the player position is known. It is a
## no-op with no player (headless verify drives the system directly) or while the prewarm keeps the player
## frozen (update_streaming — the only thing that sets _have_player_pos — is not called until unfrozen).
func _process(delta: float) -> void:
	if _snowfall != null and _have_player_pos:
		_snowfall.process(delta, _last_player_pos)

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
	# Latch the latest player position so _process can step the snowfall sim on the main thread. This is
	# also the gate that keeps the sim inert during the frozen prewarm (this is not called while frozen).
	_last_player_pos = player_pos
	_have_player_pos = true
	if _far != null:
		_far.update_center(player_pos)
	# COSMOS M4 (§5.1/§5.4): while a flip's near field restreams, poll the module's view-distance ramp;
	# once it finishes the near data blocks are loaded, so re-mirror player edits into the fresh render
	# (they were dropped by the pure-worldgen restream) and end the far handoff turbo. One-shot per flip.
	if _flip_settling:
		if _module_world == null or not _module_world.has_method("ramp_done") \
				or bool(_module_world.call("ramp_done")):
			_remirror_module_edits(player_pos)     # §5.4 — BEFORE release_cover so edits are up before the cover vanishes
			if _far != null:
				_far.end_handoff()
			# COSMOS M4 Stage 2 (§5.1): release the frozen near cover — it retires once the fresh field meshes
			# under the player. Module-guarded no-op on the fallback path / with the cover flag off.
			if _module_world != null and _module_world.has_method("release_cover"):
				_module_world.call("release_cover")
			_flip_settling = false

## Has the near terrain view around `center` finished MESHING (so it renders — and its GL pipeline
## compiles — behind the load overlay)? ShaderPrewarm PHASE 2 polls this to decide when to lift the
## overlay. On the MODULE path it asks godot_voxel (is_area_meshed) over a near box; on the FALLBACK
## path it returns true immediately (the fallback chunk format is already warmed by the prewarm grid,
## so no extra hold is needed). Half-extents cover the near, always-first-to-mesh view.
func initial_view_meshed(center: Vector3) -> bool:
	if using_module and _module_world != null and _module_world.has_method("area_meshed"):
		return bool(_module_world.call("area_meshed", center, Vector3(40.0, 32.0, 40.0)))
	return true                                     # fallback path / no module → no terrain-format hold

# --- terrain editing (block breaking + placing) --------------------------------

## THE composed cell query (VOXEL-DATA-STRUCTURE §7.1): edit overlay first, else
## generated terrain+trees. Returns the full PACKED cell value (material |
## modifier<<16 | state<<32); material/modifier/state are bit-projections of this
## one int, so they cannot desync. There is no second lookup that could disagree.
func cell_value_at(cell: Vector3i) -> int:
	var e: int = _edits.get(_edit_key(cell), -1)
	if e >= 0:
		return _overlay_window_modifier(cell, e)    # overlay: de-canon the directional modifier into the window frame (§6.4)
	if _chart == null:
		return TerrainConfig.generated_cell(cell.x, cell.y, cell.z)
	# COSMOS M2 (§3.1/§8.2): fold the window cell to its GLOBAL cell FIRST, then generate. Worldgen
	# is thereby a pure function of the global cell — window-INDEPENDENT — so it is byte-identical
	# no matter where the chart is anchored (the determinism the far-from-spawn streaming needs).
	var g := _chart.to_global(cell)
	var v := TerrainConfig.generated_cell_global(int(g["face"]), int(g["i"]), int(g["j"]), int(g["r"]))
	# COSMOS-FRAME-ORIENTATION §6: generated_cell_global is CANONICAL (true-face); rotate its directional
	# modifier into the window render frame HERE (the WM analytic boundary — the window cell is in hand so J
	# is derivable via the chart; the folded-true-cell inside TerrainConfig cannot derive it). No-op for a
	# full cube / identity orientation → byte-identical. Pairs with the overlay de-canon above.
	var m := CellCodec.modifier(v)
	if m == 0:
		return v
	var p := _chart.raw_of(cell.x, cell.z)
	return CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(m, TerrainConfig.analytic_jinv_d4(p.x, p.y)))

## COSMOS-FRAME-ORIENTATION §6.4: the overlay stores a placed DIRECTIONAL modifier in its CANONICAL
## (true-face) frame so it keeps its physical direction across a future home-face flip. These two helpers
## convert between the stored canonical frame and the CURRENT window render frame (jinv on read, J = −jinv
## on write). BOTH are a no-op for a full cube (modifier 0 — everything the hotbar places today), no chart,
## or identity orientation, so current gameplay + verify_feature's break/place loop stay byte-identical.
func _overlay_window_modifier(cell: Vector3i, v: int) -> int:
	if _chart == null or v <= 0 or CellCodec.modifier(v) == 0:
		return v
	var p := _chart.raw_of(cell.x, cell.z)
	var jinv := TerrainConfig.analytic_jinv_d4(p.x, p.y)
	if jinv == 0:
		return v
	return CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(CellCodec.modifier(v), jinv))

func _overlay_canon_modifier(cell: Vector3i, v: int) -> int:
	if _chart == null or v <= 0 or CellCodec.modifier(v) == 0:
		return v
	var p := _chart.raw_of(cell.x, cell.z)
	var jinv := TerrainConfig.analytic_jinv_d4(p.x, p.y)
	if jinv == 0:
		return v
	return CellCodec.with_modifier(v, ShapeCodec.rotate_modifier(CellCodec.modifier(v), (4 - jinv) % 4))

## COSMOS M2 (§1.3): THE overlay key for a window cell. FLAT_WORLD / no chart → the Vector3i window
## cell itself (byte-identical to the pre-M2 store). Curved → the 43-bit GLOBAL edit key, so an edit
## survives origin re-anchors and home-face flips (its key is its global identity, not its window
## position). Returned as a Variant because Dictionary keys are the Vector3i or the int transparently.
func _edit_key(cell: Vector3i) -> Variant:
	if _chart == null:
		return cell
	return _chart.to_global_key(cell)

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
	var sp := ShapeCodec.span(CellCodec.modifier(v), fx, fz)   # 2) SHAPE (modifier 0 -> (0,1))
	# 3) SNOW FILL (SNOW-ACCUMULATION §2.4): a filled ramp holds snow in its remainder up to the plane
	# `fill/10`, so the walkable surface is max(terrain shape, snow plane) — the player stands on the
	# combined surface everywhere by construction (floor_under/blocked/ceiling all compose against this).
	var fill := CellCodec.snow_fill(v)
	if fill != 0:
		return Vector2(0.0, maxf(sp.y, float(fill) / 10.0))
	return sp

## True if the cell was dug out (edit overlay says air). Used by fast column loops
## (fallback mesher tops, ground collider) that only care about air-vs-solid at/
## below the heightmap.
func is_removed(cell: Vector3i) -> bool:
	return _edits.get(_edit_key(cell), -1) == 0

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

## WINDOW-keyed view of the edit overlay (Vector3i window cell → PACKED value) for the fallback
## mesher (COSMOS M3 §4.3). In FLAT_WORLD / no chart the overlay IS Vector3i-keyed, so this returns
## it directly (byte-identical, zero copy). In curved mode `_edits` is GLOBAL-int-keyed, so this
## unfolds each edit's global cell back into the CURRENT window: a home-face cell is (i−i_org, r,
## j−j_org); a neighbour-face edit in an edge strip is unfolded via CubeSphere.unfold_to_window so a
## block built just across a seam still renders in the extended window. Edits whose global cell is
## not reachable in this window (far off-face / corner quadrant) are omitted — they render once the
## home face flips to their face (hard restream). Built on demand; the mesher already iterates the
## whole overlay, so this adds no asymptotic cost.
func placed_cells_window() -> Dictionary:
	if _chart == null:
		return _edits
	var out := {}
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var w := _chart.window_of_global(int(g["face"]), int(g["i"]), int(g["j"]))
		if bool(w["found"]):
			out[Vector3i(int(w["x"]), int(g["r"]), int(w["z"]))] = _edits[k]
	return out

## True if column (x, z) has ANY overlay edit (dug or placed) — the collider's fast-path gate
## (PERF): an unedited column's overlay is empty, so the collider skips its per-cell scan there.
func is_edited_column(x: int, z: int) -> bool:
	return _edit_columns.has(Vector2i(x, z))

# --- loose-body gate (PERF, GroundCollider exploration-jerkiness fix) ----------
# The ground collider exists ONLY to catch loose VoxelBodies; the player moves analytically and
# never touches it. So the collider is gated on whether any loose body is present/near — with none,
# it does zero rebuild work. Every loose VoxelBody is a DIRECT child of this WorldManager (both
# spawn paths — spawn_loose(self, …) and VoxelBody._spawn_detached via get_parent()), so the set is
# just the VoxelBody children; deriving it on demand (no signal/_ready dependency) is robust in the
# game AND the headless verify (where _ready is deferred). The set is tiny (typically 0–a few), so
# the per-frame scan is negligible.

## Metres around a terrain/body edit within which dormant debris is woken (dormant-by-default
## reactivation). Generous enough to catch a local debris pile so a whole small stack reactivates
## together; a rare taller stack self-heals on the next nearby edit.
const _WAKE_RADIUS := 6.0

## Number of active loose VoxelBodies (debris) in the world.
func active_body_count() -> int:
	var n := 0
	for c in get_children():
		if c is VoxelBody:
			n += 1
	return n

## True iff any loose VoxelBody exists at all (dormant or awake).
func has_active_bodies() -> bool:
	for c in get_children():
		if c is VoxelBody:
			return true
	return false

## Number of AWAKE (simulating) loose bodies — dormant (frozen / sleeping) debris is excluded.
func awake_body_count() -> int:
	var n := 0
	for c in get_children():
		if c is VoxelBody and (c as VoxelBody).is_awake():
			n += 1
	return n

## True iff an AWAKE loose VoxelBody is within `radius` columns (Chebyshev, horizontal) of `center`.
## THE collider gate (DORMANT-BY-DEFAULT): a FROZEN ground body or a SLEEPING wood body does NOT
## count, so once nearby debris settles the collider returns to idle even though the (now-static)
## bodies still sit there — a pile of settled debris near the player costs nothing. Only a moving/
## falling body keeps the collider active. A body's world column is its spawn cell offset by its
## rigid-body displacement (global_position), so a dropping/shoved body is tracked cheaply.
func has_active_bodies_near(center: Vector2i, radius: int) -> bool:
	for c in get_children():
		if not (c is VoxelBody):
			continue
		var vb := c as VoxelBody
		if vb.cells.is_empty() or not vb.is_awake():
			continue                        # emptied (mid-free) or DORMANT → does not hold the collider on
		var home := _body_home_column(vb)
		var gp := vb.global_position
		var wx := home.x + int(floor(gp.x))
		var wz := home.y + int(floor(gp.z))
		if maxi(absi(wx - center.x), absi(wz - center.y)) <= radius:
			return true
	return false

## The world column (wx, wz) of a representative AWAKE loose body within `radius` columns (Chebyshev)
## of `center`, or Vector2i(0x7fffffff, 0) if none. GroundCollider centres its bootstrap CORE on the
## actual faller (which may be a few blocks from the player — a break happens at reach distance)
## rather than on the player, so a small core reliably covers the body that needs ground. Mirrors the
## body-tracking of has_active_bodies_near exactly (same awake/home-column logic).
func active_body_column_near(center: Vector2i, radius: int) -> Vector2i:
	for c in get_children():
		if not (c is VoxelBody):
			continue
		var vb := c as VoxelBody
		if vb.cells.is_empty() or not vb.is_awake():
			continue
		var home := _body_home_column(vb)
		var gp := vb.global_position
		var wx := home.x + int(floor(gp.x))
		var wz := home.y + int(floor(gp.z))
		if maxi(absi(wx - center.x), absi(wz - center.y)) <= radius:
			return Vector2i(wx, wz)
	return Vector2i(0x7fffffff, 0)

## Wake every dormant loose body whose cells are within `radius` metres of world point `p` — the
## disturbance reactivation path (DORMANT-BY-DEFAULT): a break/collapse/placement near settled
## debris wakes it so it re-tests support and falls if undermined, else re-settles. Called on every
## terrain/body edit; comprehensive so a body can never be left floating with its support removed.
func wake_bodies_near(p: Vector3, radius: float) -> void:
	var r2 := radius * radius
	for c in get_children():
		if not (c is VoxelBody):
			continue
		var vb := c as VoxelBody
		if vb.cells.is_empty() or vb.is_awake():
			continue                        # already awake → nothing to do
		var xf := vb.global_transform
		for k: Vector3i in vb.cells:
			var wp: Vector3 = xf * Vector3(k.x + 0.5, k.y + 0.5, k.z + 0.5)
			if wp.distance_squared_to(p) <= r2:
				vb.wake()
				break                       # this body is awake now; move to the next
	return

## A representative local column (x, z) of a VoxelBody's cells (first key). Added to global_position
## it gives the body's current world column (coarse; enough for the gate radius).
func _body_home_column(vb: VoxelBody) -> Vector2i:
	for k: Vector3i in vb.cells:
		return Vector2i(k.x, k.z)
	return Vector2i(0, 0)

## Topmost still-solid column height at (x, z): the noise height, lowered past any
## blocks the player has broken from the top. Because every column is solid all
## the way down, this always finds a block — the ground is never hollow. (Ignores
## placed blocks ABOVE the heightmap; those are handled by placed_cells/placed_top.)
func effective_height(x: int, z: int) -> int:
	var h := col_height(x, z)
	while is_removed(Vector3i(x, h, z)):
		h -= 1
	return h

# --- COSMOS M3: curved-render integration — window→GLOBAL column projection (§4.3 / M2 follow-up) --
# The analytic curved-render consumers (the fallback mesher, GroundCollider, PerVoxelEnvironment)
# read TerrainConfig column functions on WINDOW coordinates. In curved mode a window column is NOT
# its global column (the floating origin offsets it, and near a seam it folds to a NEIGHBOUR face),
# so these MUST resolve the GLOBAL cell first or they build/read the wrong column at a non-zero
# origin. These wrappers convert window (x, z) → raw index via chart.raw_of (M_win, §5.3) — the edge fold happens
# inside TerrainConfig via LatticeNav when the column spills past an edge. FLAT_WORLD / no chart →
# the direct TerrainConfig call (byte-identical to the pre-M3 flat world).

## Surface height at WINDOW column (x, z), resolved on the GLOBAL cell (folds the origin, and an
## edge if the column spilled past one). Byte-identical to TerrainConfig.height_at in flat mode.
func col_height(x: int, z: int) -> int:
	if _chart == null:
		return TerrainConfig.height_at(x, z)
	var p := _chart.raw_of(x, z)                 # COSMOS-FRAME-ORIENTATION §5.3: window→raw via M_win
	return TerrainConfig.height_at(p.x, p.y)

## Column profile Vector4(g, biome, c, t) at WINDOW column (x, z), resolved on the GLOBAL cell.
func col_profile(x: int, z: int, pcache = null) -> Vector4:
	if _chart == null:
		return TerrainConfig.column_profile(x, z, pcache)
	var p := _chart.raw_of(x, z)
	return TerrainConfig.column_profile(p.x, p.y, pcache)

## Smoothing SURFACE modifier at WINDOW column (x, z), resolved on the GLOBAL cell (GroundCollider).
func col_surface_modifier(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.surface_modifier(x, z, pcache)
	var p := _chart.raw_of(x, z)
	# COSMOS-FRAME-ORIENTATION §6: rotate the directional modifier into the window render frame so the
	# collider matches the mesh (resolve_cell rotates identically). Identity jinv → byte-identical.
	return ShapeCodec.rotate_modifier(TerrainConfig.surface_modifier(p.x, p.y, pcache), TerrainConfig.analytic_window_d4())

## Smoothing CAP modifier at WINDOW column (x, z), resolved on the GLOBAL cell (GroundCollider).
func col_surface_cap_modifier(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.surface_cap_modifier(x, z, pcache)
	var p := _chart.raw_of(x, z)
	return ShapeCodec.rotate_modifier(TerrainConfig.surface_cap_modifier(p.x, p.y, pcache), TerrainConfig.analytic_window_d4())

## Packed snow stack (SNOW-ACCUMULATION §3.4) at WINDOW column (x, z), resolved on the GLOBAL cell so
## the collider's snow fill matches the surface/cap it folds. Byte-identical to TerrainConfig in flat mode.
func col_snow_stack_at(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.snow_stack_at(x, z, pcache)
	var p := _chart.raw_of(x, z)
	return TerrainConfig.snow_stack_at(p.x, p.y, pcache)

## Packed SLOPE run (SHARP-SLOPE §3.6) at WINDOW column (x, z), resolved on the GLOBAL cell (the run
## decode via slope_run_range/_modifier_at is pure arithmetic, so only this column fetch needs folding).
func col_slope_run_of(x: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TerrainConfig.slope_run_of(x, z, pcache)
	var p := _chart.raw_of(x, z)
	# COSMOS-FRAME-ORIENTATION §6: rotate the run's corner codes so the collider decodes the same rotated
	# slope the mesh renders (render == collision). lo/hi unchanged. Identity jinv → byte-identical.
	return TerrainConfig.rotate_slope_run(TerrainConfig.slope_run_of(p.x, p.y, pcache), TerrainConfig.analytic_window_d4())

## The tree-overlay block at WINDOW cell (x, y, z), resolved on the GLOBAL column. FLAT_WORLD →
## direct. Curved: keyed on the global (i, j) so the same tree is seen from any window/origin (the
## across-a-real-3D-seam identity of a tree straddling a face edge is fallback-grade, §4.6).
func tree_block_at(x: int, y: int, z: int, pcache = null) -> int:
	if _chart == null:
		return TreeGen.block_at(x, y, z, pcache)
	var p := _chart.raw_of(x, z)
	return TreeGen.block_at(p.x, y, p.y, pcache)

## The raw overlay value at WINDOW cell (folds to the global edit key), or −1 if unedited. THE
## point accessor the collider uses instead of `placed_cells().get(Vector3i, −1)` — that dict is
## GLOBAL-keyed in curved mode, so a window-Vector3i lookup would always miss (§1.3).
func overlay_at(cell: Vector3i) -> int:
	var e: int = _edits.get(_edit_key(cell), -1)
	if e < 0:
		return e
	return _overlay_window_modifier(cell, e)         # §6.4: de-canon into the window frame for the collider

## Break the block at `cell` (terrain, layers, tree cells, placed blocks alike).
## Returns the BROKEN BLOCK ID (>0) on success, 0 if the cell was already air.
## `from_pos` (the breaker's position) propagates to the collapse pass so any
## detached floating cluster gets a slight kick away from the breaker; pass
## Vector3.INF (default) for "no kick". Mirrors into the active render path, runs
## a local support analysis so undercut terrain drops as loose rigid bodies, then
## refreshes ground collision.
func break_terrain(cell: Vector3i, from_pos: Vector3 = Vector3.INF) -> int:
	if _edits.get(_edit_key(cell), -1) == 0 or not cell_solid(cell):
		return 0
	# Snow first (SNOW-ACCUMULATION §2.5): a snow-FILLED ramp yields its snow BEFORE the terrain
	# beneath. The first break clears the fill nibble AND the snow_capped skin (the snow is gone) and
	# returns snow_block; the terrain ramp is re-exposed (still supported → no structural update), and
	# the NEXT break takes the terrain. Digging thus removes worldgen snow without partial digging (§1.6).
	var v0: int = cell_value_at(cell)
	if CellCodec.snow_fill(v0) != 0:
		var bare := CellCodec.with_snow_fill(v0, 0)
		bare = CellCodec.with_state(bare, CellCodec.state(bare) & ~CellCodec.STATE_SNOW_CAPPED)
		_write_cell(cell, bare)
		wake_bodies_near(Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), _WAKE_RADIUS)
		if _ground != null:
			_ground.rebuild_now()
		return BlockCatalog.id_of(&"snow_block")
	var id: int = block_id_at(cell)     # capture the MATERIAL id BEFORE carving
	_write_cell(cell, 0)                # dig to air (0 = canonical air)
	_structural_update(cell, from_pos)  # only from the player break — never a spawn
	# Disturbance: wake dormant debris near the break so anything that just lost its support falls
	# (dormant-by-default reactivation). The new-body spawns from _structural_update are already awake.
	wake_bodies_near(Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), _WAKE_RADIUS)
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
	wake_bodies_near(Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), _WAKE_RADIUS)   # disturbance: reactivate nearby dormant debris
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
## `paint` (default true) mirrors the cell into the active render path immediately. It is
## set false ONLY by `load_bundle` on the module path, which coalesces the render into ONE
## bulk `try_set_block_data` pass (RMS §3.4) after the overlay is fully written — the overlay
## update itself (the gameplay truth) is unconditional.
func _write_cell(cell: Vector3i, packed: int, meta: Variant = null, paint: bool = true) -> void:
	# COSMOS-CORNER-CANONICAL (#69) companion edit-lock (SEPARABLE — see CORNER_EDIT_LOCK). Refuse a write
	# to a corner-quadrant window cell: the double-out wedge is a per-window sampling of canonical terrain
	# with no stable window identity to re-mirror. FLAT_WORLD (no chart) never reaches this → byte-identical.
	if CORNER_EDIT_LOCK and _chart != null:
		var _cp := _chart.raw_of(cell.x, cell.z)     # COSMOS-FRAME-ORIENTATION §5.3: window→raw via M_win
		if int(CubeSphere.fold_cell(_chart.face, _cp.x, _cp.y,
				CubeSphere.n_for(CubeSphere.HOME_BODY))["face"]) < 0:
			return
	packed = CellCodec.canonical(packed)
	# COSMOS M2: the overlay + metadata key by the global edit key in curved mode, by the Vector3i
	# window cell in FLAT_WORLD (byte-identical). `_edit_columns` stays WINDOW-keyed (a collider
	# fast-path index) and is re-keyed by −Δ on a re-anchor (_shift_window_bookkeeping).
	var ek: Variant = _edit_key(cell)
	if meta != null and BlockCatalog.has_block_entity(CellCodec.mat(packed)):
		_meta[ek] = meta                         # the one write that (re)sets metadata
	elif not _meta.is_empty():
		var old_meta: Variant = _meta.get(ek, null)
		if old_meta != null:
			_meta.erase(ek)                      # material change / break settles it
			block_entity_orphaned.emit(cell, old_meta)
	if not _edits.has(ek):
		_edit_columns[Vector2i(cell.x, cell.z)] = true   # first edit in this column (PERF index)
	# COSMOS-FRAME-ORIENTATION §6.4: store the directional modifier in its CANONICAL (true-face) frame so
	# it survives a flip; PAINT the window-frame value (the current render). No-op for a full cube.
	_edits[ek] = _overlay_canon_modifier(cell, packed)
	if paint:
		_paint_cell(cell, packed)

# --- snowfall-sim support (SNOW-ACCUMULATION Decision 4) ------------------------
# Three tiny primitives the SnowfallSystem composes over the ONE write choke point. It never bypasses
# `_write_cell`; these only add the read + the baseline-revert + the debounced rebuild it needs.

## True iff `cell` currently carries an overlay edit (dug air OR a placed/sim value). The sim uses this to
## tell an in-place snow bump (already an edit) from ADDING a new snow cell (budget accounting), and to
## refuse burying a NON-snow edit.
func has_edit(cell: Vector3i) -> bool:
	return _edits.has(_edit_key(cell))               # COSMOS: fold to the global edit key (byte-identical in FLAT_WORLD)

## Drop `cell`'s overlay edit so it reverts to its pure GENERATED value, and repaint that value into the
## active render path. The sim calls this when a melting snow cell reaches its bare baseline: storing a
## baseline-equal edit would be wasted (§4.4 "never write a cell whose new value equals its generated
## value"), so the edit is removed instead. Safe for snow (no metadata); `_edit_columns` intentionally
## keeps its entry (it only ever grows — a stale empty-overlay column just costs the collider one skip).
func sim_revert_cell(cell: Vector3i) -> void:
	# COSMOS: erase by the global edit key and repaint the folded generated value (cell_value_at falls
	# through to the folded worldgen once the edit is gone). Byte-identical to main in FLAT_WORLD.
	if _edits.erase(_edit_key(cell)):
		_paint_cell(cell, cell_value_at(cell))

## ONE debounced ground rebuild for the snowfall sim, run at a step's end iff a write happened (§4.3.5).
## The collider's own debounce coalesces further, and its loose-body gate means it does zero work unless a
## body is actually nearby — a settled pile near the player costs nothing.
func sim_ground_rebuild() -> void:
	if _ground != null:
		_ground.rebuild_now()

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
	_meta[_edit_key(cell)] = meta.duplicate(true)
	return true

## The block-entity METADATA document at `cell`; an EMPTY dict when the cell carries
## none. Returns a DEEP COPY — mutating it never changes the stored document (route
## real updates through `set_metadata`).
func get_metadata(cell: Vector3i) -> Dictionary:
	var m: Variant = _meta.get(_edit_key(cell), null)
	return (m as Dictionary).duplicate(true) if m != null else {}

## True iff `cell` currently carries a metadata document.
func has_metadata(cell: Vector3i) -> bool:
	return _meta.has(_edit_key(cell))

## Set the STATE axis (bits 32..47) of `cell`, keeping its material + modifier and
## PRESERVING any metadata (the one write that does — §11). Returns false on air.
## The state bits are canonicalized/validated through `CellCodec._validate_state`, which masks
## them against the material's declared `state_layout` (M1: undeclared bits silently drop to 0;
## an UNRESOLVED placeholder keeps its bits permissively).
func set_state(cell: Vector3i, state_bits: int) -> bool:
	var v := cell_value_at(cell)
	var mat := CellCodec.mat(v)
	if mat == BlockCatalog.AIR:
		return false                             # air carries no state
	var new_packed := CellCodec.pack(mat, CellCodec.modifier(v), state_bits)
	# Re-pass the existing document so the choke point KEEPS it (same material → still a
	# block-entity) rather than orphaning it: set_state is a behavioural, not material, edit.
	_write_cell(cell, new_packed, _meta.get(_edit_key(cell), null))
	return true

## Evaluate the material state machine at `cell` and, if a transition fires, apply the new STATE
## bits (M1 snowy-world ADR §4.2 — the melt/freeze EVALUATOR primitive). Returns true iff the cell's
## state changed. This is the live, dormant-by-default machine: there is NO periodic tick / global
## sweep / disturbance hook in M1 — worldgen already produces the fixed point of the transition
## (cap and melt share ONE zero crossing), so a call at a generated cell does nothing; a warm column
## holding a stray capped value melts it, a cold column caps bare grass. First-triggered transition
## wins; a target naming a `state_layout` bit SETS that bit, a target naming the DEFAULT state name
## CLEARS all layout bits (the snow melts back). The write routes through set_state → _write_cell →
## `_edits` (overlay-persisted, re-meshed), authoritative over generation — a melt can never be
## un-melted by re-streaming (same guarantee as break/place). MAIN THREAD ONLY (writes the
## non-thread-safe `_edits`); never call from the voxel worker. The SET (freeze) edge self-gates to
## the exposed generated surface cell so a buried cappable cell can't spuriously freeze; a future
## non-surface transition would need its own condition rather than reusing that gate.
func apply_state_transitions(cell: Vector3i) -> bool:
	var v := cell_value_at(cell)
	var mat := CellCodec.mat(v)
	if mat == BlockCatalog.AIR:
		return false
	var def := BlockCatalog.def_of(mat)
	if def == null:
		return false
	var st := def.get_default_state()
	if st == null or st.transitions.is_empty():
		return false
	if environment == null:
		return false                                 # sim query not wired (deferred _ready) — nothing to sample
	var mask := BlockCatalog.state_mask_of(mat)
	var state_bits := CellCodec.state(v)
	# A deposition state (snow_capped) only forms on the EXPOSED generated surface cell, never on
	# buried material: a buried cappable cell (stone/sand underground) reads sub-zero ground
	# temperature and would otherwise spuriously freeze, breaking the "worldgen is the fixed point"
	# invariant. So the SET (freeze) edge is gated to the generated surface height; the CLEAR (melt)
	# edge is ungated — clearing a stray bit anywhere is always safe. (M1 conservative gate; the M2
	# disturbance tick will define the exposed-surface set including edits.)
	var is_surface_cell := cell.y == TerrainConfig.height_at(cell.x, cell.z)
	var sample := environment.sample(Vector3(cell) + Vector3(0.5, 0.5, 0.5))
	for t: VoxelStateTransition in st.transitions:
		if not t.is_triggered(sample):
			continue
		var idx := def.state_layout.find(t.to_state)
		var new_bits: int
		if idx >= 0:
			if not is_surface_cell:
				continue                             # a SET edge only fires on the exposed surface cell
			new_bits = state_bits | (1 << idx)       # target is a STATE-axis bit → set it
		elif t.to_state == st.state_name:
			new_bits = state_bits & ~mask            # target is the default state → clear the layout bits
		else:
			continue                                 # unresolvable target → try the next transition
		# First TRIGGERED-and-resolvable transition wins (disjoint predicates make this safe): apply
		# it if it changes the state, else report no change (idempotent).
		if new_bits != state_bits:
			return set_state(cell, new_bits)
		return false
	return false

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

# --- COSMOS M2: the floating-origin chart + re-anchor (docs/COSMOS-PLANET-TOPOLOGY.md §3.2) -----
# The whole intra-face floating-origin mechanism. FLAT_WORLD keeps `_chart` null, so every method
# here is a byte-identical no-op (maybe_reanchor returns Vector3.ZERO, install_chart is never called
# by the live path). Curved mode installs a chart in _ready; the M2 verify injects one directly.

## Install (or replace) the floating-origin chart, switching the overlay to GLOBAL-key mode. Public
## so the verify suites can exercise the curved store without flipping the FLAT_WORLD const. Keeps
## TerrainConfig's active face and the per-voxel environment's chart in sync (§4.5 / §6.1) so the
## analytic curved-render queries fold window→global on the same face the choke points do.
func install_chart(chart: CosmosChart) -> void:
	_chart = chart
	if chart != null:
		TerrainConfig.set_active_frame(chart.face, CubeSphere.d4_of(chart.m_win()))   # COSMOS-FRAME-ORIENTATION §6 (Q2d1)
		if environment != null:
			environment.set_chart(chart)
		if _far != null:
			_far.set_chart(chart)   # COSMOS R1 (M5_REAL): keep the far's bake/align chart current
		_m5_sync_frame()   # COSMOS M5a: chart table (org/M_win/face axes) → true-position shader

## COSMOS M5a: push the per-FRAME camera frame (d̂_cam / y_cam / M_tangent + camera origin) into the
## true-position shader globals. Called by main.gd each frame in M5_RENDER mode. No-op without a chart.
func m5_push_camera(cam: Vector3) -> void:
	if _chart == null or not CubeSphere.M5_RENDER:
		return
	CosmosTruePlace.push_camera(_chart, cam)

## COSMOS R1 (M5_REAL): drive the far layer's per-frame rigid alignment root from the player position.
## Called each frame by main.gd in curved mode. No-op without the far / a chart.
func m5_real_update_far(player_pos: Vector3) -> void:
	if _far == null or _chart == null or not CubeSphere.M5_REAL:
		return
	_far.update_alignment(player_pos)

## COSMOS M5a: push the chart-orientation + 5-chart fold TABLE (org / M_win / face axes) into the true-
## position shader globals. Called after every frame change (init / install_chart / flip / reanchor).
## Guarded on M5_RENDER so the default (and the CosmosBend curved mode) never touch these globals.
func _m5_sync_frame() -> void:
	if _chart == null or not CubeSphere.M5_RENDER:
		return
	CosmosTruePlace.set_chart_table(_chart)   # single-writer: packs the table + applies to every M5 material this pass

## The active chart, or null in FLAT_WORLD. Read-only accessor.
func chart() -> CosmosChart:
	return _chart

## DEV (task #66): the 4 CUBE-FACE BORDER lines of the current home face, in WINDOW space, for the border
## overlay. The home face spans raw i,j ∈ [0, n]; each edge's two endpoints map to window space through the
## chart (COSMOS-FRAME-ORIENTATION §5.3: window = M_win⁻¹·(raw − org), the `window_of` helper). A C4 M_win
## keeps every edge axis-aligned but may SWAP which window axis it is constant along, so derive axis/pos/lo/hi
## from the mapped endpoints rather than assuming i↔x. M_win = I reproduces the old x=−i_org … lines exactly.
## Recomputed from the LIVE chart (org + M_win shift on re-anchor + flip), so callers poll each frame. Returns
## [] in FLAT_WORLD / with no chart. Each entry: {axis:"x"|"z", pos, lo, hi} — pos the constant window coord.
func cosmos_border_lines() -> Array:
	if _chart == null:
		return []
	var n := _chart.n
	var edges := [[Vector2i(0, 0), Vector2i(0, n)],   # raw i = 0 (WEST)
		[Vector2i(n, 0), Vector2i(n, n)],             # raw i = n (EAST)
		[Vector2i(0, 0), Vector2i(n, 0)],             # raw j = 0 (SOUTH)
		[Vector2i(0, n), Vector2i(n, n)]]             # raw j = n (NORTH)
	var out: Array = []
	for e: Array in edges:
		var w1: Vector2i = _chart.window_of(e[0].x, e[0].y)
		var w2: Vector2i = _chart.window_of(e[1].x, e[1].y)
		if w1.x == w2.x:                              # constant window x → a vertical "x" line over z
			out.append({"axis": "x", "pos": float(w1.x), "lo": float(mini(w1.y, w2.y)), "hi": float(maxi(w1.y, w2.y))})
		else:                                         # constant window z → a horizontal "z" line over x
			out.append({"axis": "z", "pos": float(w1.y), "lo": float(mini(w1.x, w2.x)), "hi": float(maxi(w1.x, w2.x))})
	return out

## DEV (task #75): window cells of the DOUBLE-OUT CORNER WEDGE near `center`, on a grid of `spacing`,
## within `span` half-extent — so the dev overlay can mark the known-weird corner quadrant DISTINCTLY (RED)
## and the user can tell the §4.6/§5.4 corner echo from a real bug while walking around. A wedge cell is one
## whose RAW index (raw_of, M_win) is out of range in BOTH axes → fold_cell returns face −1 (the same
## predicate the M4 edit-lock uses). Recomputed each frame from the LIVE chart so it tracks flips/re-anchors
## like the border pillars. Returns [] in FLAT_WORLD / no chart (the overlay is then never built — byte-identical).
func cosmos_wedge_cells(center: Vector3, span: float, spacing: float) -> Array:
	if _chart == null:
		return []
	var out: Array = []
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var cx := int(floor(center.x))
	var cz := int(floor(center.z))
	var step := maxi(int(spacing), 1)
	var half := int(span)
	var x := cx - half
	while x <= cx + half:
		var z := cz - half
		while z <= cz + half:
			var p := _chart.raw_of(x, z)
			if int(CubeSphere.fold_cell(_chart.face, p.x, p.y, n)["face"]) < 0:
				out.append(Vector2i(x, z))
			z += step
		x += step
	return out

## COSMOS M2 (§3.2): re-anchor the floating origin if the player has walked past the trigger.
## Returns the WORLD-space shift the caller (the player) must SUBTRACT from its position so the
## world stays continuous — Vector3.ZERO when there is no chart or no shift is due (FLAT_WORLD →
## byte-identical no-op). The shift is an EXACT INTEGER translation of the window origin: existing
## edits (global-keyed) are untouched, no cell changes its window identity relative to the player,
## no content re-streams (pop = 0). Render nodes carry window-space geometry, so they are translated
## by −Δ to keep their already-built meshes at the same world position while the origin moves.
func maybe_reanchor(player_pos: Vector3) -> Vector3:
	if _chart == null or not _chart.needs_reanchor(player_pos):
		return Vector3.ZERO
	var d := _chart.reanchor(player_pos)
	if d == Vector2i.ZERO:
		return Vector3.ZERO
	var shift := Vector3(float(d.x), 0.0, float(d.y))
	_shift_window_bookkeeping(d)
	if _module_world != null:
		_module_world.position -= shift
	if _streamer != null:
		_streamer.position -= shift
	if _ground != null:
		_ground.position -= shift
	# The far layer shares the near field's global-index frame, so it re-anchors by the SAME −Δ:
	# already-built (global-coord) tiles keep their world position and stay aligned with the near
	# surface (Fable Stage 1). Any live post-flip cover is a child, so it rides along automatically.
	if _far != null:
		_far.position -= shift
	_m5_sync_frame()   # COSMOS M5a: the reanchor moved _chart.org → refresh the true-position chart table
	return shift

## COSMOS M3 (§4.5): the home-face flip. When the player has crossed FLIP_HYST cells PAST a face
## edge, re-base the window onto the neighbour face (chart.flip) and HARD-RESTREAM the local region.
## Returns true iff a flip happened (FLAT_WORLD / no chart / not past an edge → false, a no-op).
##
## Teleport-free + edit-preserving BY CONSTRUCTION: chart.flip keeps the player's window position
## unchanged (its world point is the same global cell), and every edit is GLOBAL-keyed so it is
## found again by its unchanged key from the new home face. Worldgen determinism holds because a
## global cell resolves through _curved_profile identically regardless of which window/home face
## reaches it (§8.2). The fallback path drops + rebuilds its chunks at the normal budget; the module
## path keeps the analytic far field as cover during the drop (full dual-window handoff is M4).
func maybe_flip_home_face(player_pos: Vector3) -> bool:
	if _chart == null or not _chart.flip_needed(player_pos):
		return false
	var res := _chart.flip(player_pos)
	if not bool(res["ok"]):
		return false                                  # corner quadrant — deferred to M5
	# COSMOS-FRAME-ORIENTATION §5.1: chart.flip accumulated the crossed edge's D4 into M_win, so the
	# window frame is CONTINUOUS across the flip — no player/heading compensation is needed (Fix A #71
	# reverted). FLAT_WORLD never reaches here (no chart), so the flat path is unaffected.
	# Follow the new home face in the analytic/main-thread-generated worldgen queries (§4.5).
	TerrainConfig.set_active_frame(_chart.face, CubeSphere.d4_of(_chart.m_win()))   # COSMOS-FRAME-ORIENTATION §6 (Q2d1): atomic face+M_win, before restream
	_m5_sync_frame()   # COSMOS M5a: flip changed face + M_win → refresh the true-position chart table before restream
	# Re-base the WINDOW-space collider indices onto the new face's index map: the global-keyed
	# `_edits`/`_meta` are untouched (edits are preserved), but `_edit_columns`/`_placed_top` are
	# window-keyed PERF indices, so rebuild them by unfolding every edit's global cell back into the
	# new window (a home-face-only join now maps onto the neighbour face) — the collider stays exact.
	_rebuild_window_indices()
	# COSMOS frozen-epoch flip (COSMOS-AUDIT §3.2 item 4, F3): reposition the module so its voxel
	# coordinate frame maps to the NEW face's global indices (voxel = window − node.position = global
	# index; the flip re-bases i_org/j_org), then install a NEW generator epoch (new frozen gen_face)
	# and hard-restream so stale face-A meshes are dropped. The old generator is never mutated — any
	# in-flight worker task finishes on the old face and its block is discarded by the restream.
	if _module_world != null:
		# COSMOS M4 Stage 2 (§3.2): capture the wrapper's OLD-frame position BEFORE repositioning to the new
		# frame, and pass it to set_home_face so the flag-on cover can pin the old terrain at its old world
		# spot. Default-off ignores it (freed immediately); the 1-arg race-verify call still works.
		var old_mod_pos: Vector3 = _module_world.position
		_module_world.position = _chart.node_origin()   # COSMOS-FRAME-ORIENTATION §5.3: −M_win⁻¹·org
		if _module_world.has_method("set_home_face"):
			_module_world.call("set_home_face", _chart.face, old_mod_pos, _chart.m_win())
	# COSMOS M4 (§5.1): latch the flip-settling window (both render paths). update_streaming settles it once
	# the module reports ramp_done() — re-mirroring player edits into the fresh terrain (§5.4), ending the far
	# turbo, and releasing the cover. The fallback path (no module) settles immediately (re-mirror/release are
	# module-guarded no-ops there — ChunkStreamer re-reads the overlay when it remeshes).
	_flip_settling = true
	# Re-base the far layer onto the new face's global frame (Fable Stage 1). It stashes its still-
	# world-correct tiles as a cover so the horizon holds while the near field restreams behind it —
	# the intended visual bridge that keeps the seam crossing from blanking the mid-to-far distance.
	# COSMOS M4 (§2.2): then open the handoff turbo so the new frame's nearest ring-0 tiles build FIRST
	# and appear under the player in ~0.2–0.5 s (both render paths benefit from the nearest-first turbo).
	if _far != null:
		_far.rebase_to(_chart.node_origin(), _chart.m_win())   # COSMOS-FRAME-ORIENTATION §5.3: −M_win⁻¹·org + frozen epoch M_win
		_far.begin_handoff()
	# HARD RESTREAM the fallback streamer + collider (the module was restreamed by set_home_face above).
	_restream()
	# COSMOS M4 Stage 2 telemetry: report whether the frozen near cover was actually installed (flag-gated).
	var cover_on := _module_world != null and _module_world.has_method("cover_active") \
		and bool(_module_world.call("cover_active"))
	print("[WorldManager] home-face flip %d → %d (hard restream, handoff=%s, cover=%s)"
		% [int(res["from_face"]), int(res["to_face"]), "on" if _far != null else "off", "yes" if cover_on else "no"])
	return true

## Rebuild the window-keyed PERF indices (`_edit_columns`, `_placed_top`) from the global-keyed
## overlay after a home-face flip re-bases the window (§4.5). Every edit's global cell is unfolded
## back into the current window; edits whose cell is not reachable in this window (far off-face)
## simply do not index a column here — they re-index when the home face flips to their face. Keeps
## the collider's fast-path gate + above-surface scan exact after the flip.
func _rebuild_window_indices() -> void:
	_edit_columns = {}
	_placed_top = {}
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var win := _chart.window_of_global(int(g["face"]), int(g["i"]), int(g["j"]))
		if not bool(win["found"]):
			continue
		var col := Vector2i(int(win["x"]), int(win["z"]))
		_edit_columns[col] = true
		if int(_edits[k]) > 0:                            # a PLACED (non-air) cell raises the high-water mark
			var r := int(g["r"])
			var prev: int = _placed_top.get(col, -0x40000000)
			if r > prev:
				_placed_top[col] = r

## COSMOS M4 (§5.4): re-mirror player edits into the freshly-restreamed MODULE render. A home-face flip
## rebuilds the VoxelTerrain from PURE worldgen (set_home_face → restream), so player-placed/dug cells —
## still authoritative in the global-keyed `_edits` overlay (rule 1) — vanish from the RENDER until their
## region is next edited. This re-injects them once the near ramp has loaded the data blocks: unfold every
## edit's global cell back into the CURRENT window (the _rebuild_window_indices pattern), keep only those
## within the near render radius of the player horizontally (a set-voxel on an unloaded far block would
## only error-spam), and hand the window-cell → packed dict — dug-to-air cells (packed 0) INCLUDED so holes
## re-carve — to bulk_inject in ONE call. Gameplay/collision were always correct via the overlay; this
## closes a RENDER-only gap latent since M3. No-op in FLAT_WORLD / on the fallback path (no chart / module).
## Edits beyond the near radius re-mirror the way they always have — when their region is next edited/loaded.
func _remirror_module_edits(player_pos: Vector3) -> void:
	if _chart == null or _module_world == null or not _module_world.has_method("bulk_inject"):
		return
	var radius := float(TerrainConfig.near_render_radius())
	var collected := {}
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var win := _chart.window_of_global(int(g["face"]), int(g["i"]), int(g["j"]))
		if not bool(win["found"]):
			continue                                     # off the current extended window → re-mirrors when its region reloads
		var wx := int(win["x"])
		var wz := int(win["z"])
		# The near field renders window cells at world = window coordinate (the module node.position offset
		# maps window→global for the FROZEN generator, not for the player), so compare the window cell to the
		# player's world XZ directly — exactly the |window_xz − player_xz| test §5.4 specifies.
		if absf(float(wx) - player_pos.x) > radius or absf(float(wz) - player_pos.z) > radius:
			continue                                     # beyond the near field → its block is unloaded; skip (unchanged M3 behaviour)
		var wcell := Vector3i(wx, int(g["r"]), wz)
		collected[wcell] = _overlay_window_modifier(wcell, int(_edits[k]))   # §6.4: de-canon to the window render frame (0 included)
	if not collected.is_empty():
		_module_world.call("bulk_inject", collected)

## Drop and rebuild the near render + collider after a home-face flip (§4.5 hard restream). Guarded
## so it is a safe no-op in the headless verify (no streamer / module / collider nodes exist there).
func _restream() -> void:
	if _streamer != null and _streamer.has_method("restream"):
		_streamer.restream()
	# NOTE: the module path is restreamed by set_home_face() in maybe_flip_home_face (the epoch swap),
	# not here, so a flip installs the new generator epoch and drops old-face meshes in one step (F3).
	if _ground != null:
		_ground.rebuild_now()

## Re-key the WINDOW-space bookkeeping (which the global-keyed `_edits`/`_meta` are NOT part of) by
## −Δ so it stays consistent after an origin shift: a window column (x, z) becomes (x − Δi, z − Δj).
## These are collider/PERF indices only; the small dicts hold just the genuinely-edited columns.
func _shift_window_bookkeeping(d: Vector2i) -> void:
	var new_cols := {}
	for k: Vector2i in _edit_columns.keys():
		new_cols[k - d] = true
	_edit_columns = new_cols
	var new_top := {}
	for k: Vector2i in _placed_top.keys():
		new_top[k - d] = _placed_top[k]
	_placed_top = new_top
	if not _joint_mods.is_empty():
		var new_j := {}
		for k: Vector4i in _joint_mods.keys():
			new_j[Vector4i(k.x - d.x, k.y, k.z - d.y, k.w)] = _joint_mods[k]
		_joint_mods = new_j

# --- COSMOS M2: per-(body,face) region persistence (§1.1/§1.3) -----------------
# The curved twin of region_origin_of + save_edits/load_edits: the ZoneChunk region grid keyed by
# the GLOBAL region key (face, region_i, region_j, region_r). N is 32-aligned (§1.1) so no region
# straddles a face. These require an installed chart; the FLAT_WORLD Vector3i path above is
# untouched. Additive — nothing in the live loop calls them (byte-identical whether a save happens).

## The global region key (§1.3) of a window cell — THE per-(body,face) ZoneChunk key on the sphere.
func region_key_of(cell: Vector3i) -> int:
	return _chart.to_region_key(cell)

## Curved-mode region SAVE: compact the global-keyed overlay for the one 32³ region identified by
## `region_key` into a ZoneChunk. The region's local index order mirrors the window axes
## (x, y, z) = (i, r, j), matching the FLAT save_edits layout so a chunk reads back the same way.
func save_region(region_key: int) -> ZoneChunk:
	var zc := ZoneChunk.new()
	for k: int in _edits.keys():
		var g := CubeSphere.unpack_key(k)
		var gi := int(g["i"]); var gj := int(g["j"]); var gr := int(g["r"])
		if CubeSphere.region_key(int(g["face"]), gi, gj, gr) != region_key:
			continue
		var idx := ZoneChunk.local_index(gi & 31, posmod(gr, 32), gj & 31)
		zc.set_cell(idx, int(_edits[k]), _meta.get(k, null))
	return zc

## Curved-mode region LOAD: apply a ZoneChunk's cells back into the overlay for the region
## `region_key`, routing each through the single write choke point (so the global key AND metadata
## restore exactly). The chunk was saved by a global region key, so it re-materializes at the same
## GLOBAL cells regardless of the chart's CURRENT origin — the persistence twin of edit-survival.
func load_region(region_key: int, chunk: ZoneChunk, resolver: Callable = Callable()) -> void:
	var rface := CubeSphere.key_face(region_key)
	var ri := CubeSphere.key_i(region_key) << 5
	var rj := CubeSphere.key_j(region_key) << 5
	var rr := CubeSphere.key_r(region_key) * ZoneChunk.SIZE
	for idx: int in chunk.present_indices():
		var name := chunk.material_name_at(idx)
		var id := -1
		if resolver.is_valid():
			id = int(resolver.call(StringName(name)))
		else:
			id = BlockCatalog.id_of(StringName(name))
		if id < 0:
			id = BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
			push_error("WorldManager.load_region: unknown material name '%s' — substituting placeholder '%s'"
				% [name, ZoneChunk.PLACEHOLDER_MATERIAL])
		var packed := CellCodec.pack(id, chunk.modifier_at(idx), chunk.state_at(idx))
		var local := ZoneChunk.from_local_index(idx)
		# global cell → window cell (global − origin); _write_cell re-derives the same global key.
		var gi := ri + local.x
		var gr := rr + local.y
		var gj := rj + local.z
		if rface != _chart.face:
			continue                                # a region off the home face (M3 territory) is skipped
		# global (raw home-face) cell → window cell via M_win⁻¹ (COSMOS-FRAME-ORIENTATION §5.3); _write_cell
		# re-derives the same global key. Guarded above to the home face, so (gi,gj) are raw home-face indices.
		var wxy := _chart.window_of(gi, gj)
		var win := Vector3i(wxy.x, gr, wxy.y)
		_write_cell(win, packed, chunk.meta_at(idx))

# --- tier-3 persistence: ZoneChunk save/load (VOXEL-DATA-STRUCTURE §4/§5) -------
# The generated world is a pure function (tier 2) and is NEVER serialized; only the edit
# overlay — the world's deviations from that function — needs persisting. `save_edits`
# compacts the overlay (+ metadata) for one 32³ region into a ZoneChunk; `load_edits`
# applies one back through the single write choke point, so the overlay and metadata are
# restored identically. This is additive: nothing in the live break/place/collapse loop
# calls it, so gameplay is byte-identical whether or not a save ever happens.

## The 32-aligned min-corner cell of the ZoneChunk region that contains `cell`.
static func region_origin_of(cell: Vector3i) -> Vector3i:
	var s := ZoneChunk.SIZE
	return Vector3i(_floor_div(cell.x, s) * s, _floor_div(cell.y, s) * s, _floor_div(cell.z, s) * s)

static func _floor_div(a: int, b: int) -> int:
	# Floored (not truncated) integer division, so negative coordinates snap DOWN to their
	# region origin (−1 → −32 for SIZE 32, not 0), keeping regions a clean tiling of the grid.
	var q := a / b
	if (a % b) != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q

## Serialize the edit overlay (+ per-cell metadata) within the 32³ region whose min corner
## is `region_origin` (must be 32-aligned — use `region_origin_of`) into a ZoneChunk. Only
## edited cells occupy the chunk; unedited cells are absent and fall back to the generated
## function on load (tier composition, §4). A region with no edits yields a uniform (unset)
## chunk that serializes to a handful of bytes (§5.5).
func save_edits(region_origin: Vector3i) -> ZoneChunk:
	var zc := ZoneChunk.new()
	var s := ZoneChunk.SIZE
	# Union of edited cells and metadata-bearing cells in the region (a metadata cell is
	# always an edited block-entity cell today, but unioning is leak-proof regardless).
	var cells := {}
	for cell: Vector3i in _edits.keys():
		if _in_region(cell, region_origin, s):
			cells[cell] = true
	for cell: Vector3i in _meta.keys():
		if _in_region(cell, region_origin, s):
			cells[cell] = true
	for cell: Vector3i in cells.keys():
		var local := cell - region_origin
		var idx := ZoneChunk.local_index(local.x, local.y, local.z)
		zc.set_cell(idx, cell_value_at(cell), _meta.get(cell, null))
	return zc

## Apply a ZoneChunk's present cells back into the overlay at `region_origin`, routing every
## cell through the single write choke point (`_write_cell`) so the material/modifier/state
## axes AND the metadata document are restored exactly as saved. Materials resolve by NAME
## through `resolver` (a `Callable(name: StringName) -> int`; default `BlockCatalog.id_of`),
## so a chunk stays valid even if the runtime catalog assigns different dense ids than the
## saving session did (VDS §10.1). An unknown name resolves to a logged placeholder material
## (never a crash, never data loss of the shape/state bits — §16).
func load_edits(region_origin: Vector3i, chunk: ZoneChunk, resolver: Callable = Callable()) -> void:
	for idx: int in chunk.present_indices():
		var name := chunk.material_name_at(idx)
		var id := -1
		if resolver.is_valid():
			id = int(resolver.call(StringName(name)))
		else:
			id = BlockCatalog.id_of(StringName(name))
		if id < 0:
			id = BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
			push_error("WorldManager.load_edits: unknown material name '%s' — substituting placeholder '%s'"
				% [name, ZoneChunk.PLACEHOLDER_MATERIAL])
		var packed := CellCodec.pack(id, chunk.modifier_at(idx), chunk.state_at(idx))
		var local := ZoneChunk.from_local_index(idx)
		_write_cell(region_origin + local, packed, chunk.meta_at(idx))

static func _in_region(cell: Vector3i, origin: Vector3i, s: int) -> bool:
	return cell.x >= origin.x and cell.x < origin.x + s \
		and cell.y >= origin.y and cell.y < origin.y + s \
		and cell.z >= origin.z and cell.z < origin.z + s

# --- zone bundles: streamed material payloads (RMS §2.6/§3.4/§5) ----------------
# The final piece of runtime material streaming: a ZoneBundle packages one or more regions'
# edit overlay TOGETHER WITH the material documents the receiver needs (manifest), keyed by
# cross-session GMID, so acquiring a remote zone brings materials the local client has never
# seen. Dense LRIDs never travel — they are container-local, translated by GMID at the boundary
# (RMS §2.1). This is additive; nothing in the live loop calls it (gameplay is byte-identical).
# Transport / signing / trust are out of scope (RMS §9.3): this is the payload FORMAT only.

## Serialize the edit overlay (+ per-cell metadata) within `regions` (each a 32-aligned origin,
## use `region_origin_of`) into a self-contained ZoneBundle. Each present cell is recorded by its
## cross-session "<gmid>#<state>" key (`ZoneChunk.set_cell_keyed`), and every referenced material's
## document is gathered into the bundle manifest (from the content store when held, else
## reconstructed byte-identically from the catalog def, RMS §2.2). Regions with no edits are
## skipped. Container-local ids are compact (per-chunk palettes) and independent of this session's
## dense LRID assignment — the whole point (RMS §2.6).
func save_bundle(regions: Array) -> ZoneBundle:
	var bundle := ZoneBundle.new()
	var s := ZoneChunk.SIZE
	for region_origin: Vector3i in regions:
		var cells := {}
		for cell: Vector3i in _edits.keys():
			if _in_region(cell, region_origin, s):
				cells[cell] = true
		for cell: Vector3i in _meta.keys():
			if _in_region(cell, region_origin, s):
				cells[cell] = true
		if cells.is_empty():
			continue
		var zc := ZoneChunk.new()
		for cell: Vector3i in cells.keys():
			var v := cell_value_at(cell)
			var mat := CellCodec.mat(v)
			bundle.reference_material(mat)           # gather its manifest document (skips air)
			var local := cell - region_origin
			zc.set_cell_keyed(ZoneChunk.local_index(local.x, local.y, local.z),
				String(BlockCatalog.key_of(mat)), CellCodec.modifier(v), CellCodec.state(v),
				_meta.get(cell, null))
		bundle.add_chunk(region_origin, zc)
	return bundle

## Apply a ZoneBundle into this world (RMS §2.6/§3.4). First registers the manifest (dedup by
## GMID — an already-known material reuses its session LRID, an unknown one gets a fresh LRID,
## a key with no/rejected document degrades to an UNRESOLVED placeholder so data stays lossless,
## RMS §8). Then translates every chunk cell's container key → THIS session's LRID and applies
## it: the overlay (`_edits` + metadata) is updated through the single write choke point (rule-1
## truth, both paths). Render mirroring: on the module path one BULK `try_set_block_data` pass
## (F10); on the fallback path per-cell through `_write_cell`. Loose bodies / collapse are NOT
## re-run (a loaded zone is authored data, not a live edit); the ground collider is rebuilt once.
func load_bundle(bundle: ZoneBundle) -> void:
	bundle.register_manifest()
	var key_to_lrid := {}
	for key: String in bundle.id_map():
		key_to_lrid[key] = bundle.resolve_key(key)

	var placeholder_id := BlockCatalog.id_of(ZoneChunk.PLACEHOLDER_MATERIAL)
	var collected := {}                              # Vector3i -> int packed cell value
	var metas := {}                                  # Vector3i -> Dictionary
	for entry: Dictionary in bundle.chunks():
		var region_origin: Vector3i = entry["origin"]
		var chunk: ZoneChunk = entry["chunk"]
		for idx: int in chunk.present_indices():
			var key := chunk.material_name_at(idx)
			var lrid := int(key_to_lrid.get(key, -1))
			if lrid < 0:
				lrid = placeholder_id
				push_error("WorldManager.load_bundle: unresolvable key '%s' — substituting placeholder '%s'"
					% [key, ZoneChunk.PLACEHOLDER_MATERIAL])
			var world_cell := region_origin + ZoneChunk.from_local_index(idx)
			collected[world_cell] = CellCodec.pack(lrid, chunk.modifier_at(idx), chunk.state_at(idx))
			var m: Variant = chunk.meta_at(idx)
			if m != null:
				metas[world_cell] = m

	# Overlay is written for every cell (both paths). On the module path defer per-cell paint and
	# mirror the render in ONE bulk pass; on the fallback path _write_cell remeshes per cell.
	var use_bulk: bool = using_module and _module_world != null and _module_world.has_method("bulk_inject")
	for world_cell: Vector3i in collected.keys():
		_write_cell(world_cell, collected[world_cell], metas.get(world_cell, null), not use_bulk)
	if use_bulk:
		_module_world.call("bulk_inject", collected)
	if _ground != null:
		_ground.rebuild_now()

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
			# Strip the liquid overlay (WATER-SHORE §6) AND the snow fill/skin (SNOW-ACCUMULATION §2.5):
			# a detaching shore/snowy ramp must not take the ocean or a worldgen snow plane with it. Both
			# the liquid axis and the snow fill are worldgen/sim-owned; mass/mesh key off mat/modifier and
			# would ignore them, but the contract is "they never leave worldgen", so a detaching filled ramp
			# falls BARE (the M1 §5.5 accepted class) — dropped at the VoxelBody capture boundary.
			var cv := CellCodec.strip_liquid(cell_value_at(c))
			cv = CellCodec.with_snow_fill(cv, 0)
			comp_ids[c] = CellCodec.with_state(cv, CellCodec.state(cv) & ~CellCodec.STATE_SNOW_CAPPED)
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

## Lowest solid UNDERSIDE overhead a rising head sweeps into, or INF if clear. Scans
## every cell the head passes through — from `from_head_y` up to `to_head_y` — at the
## footprint (x, z), the upward mirror of `floor_under`'s downward scan, so a fast rise
## (frame hitch) cannot tunnel a thin ceiling. Each cell is tested by the shape-aware
## `_occ_span` (material gate for free: water/lava yield the empty span and are scanned
## THROUGH), and the returned value is the occupied cell's lower bound — a top-anchored
## slab stops the head at its true underside, a full cube at the integer cell floor. A
## cell whose occupancy starts at/below where the head already is (occ_lo < from_head_y)
## is ignored: the head is already clear there, only NEW occupancy overhead constrains
## the move. BYTE-IDENTICAL to a single full-cube point test for the current world.
func ceiling_scan(x: float, z: float, from_head_y: float, to_head_y: float) -> float:
	var xi := int(floor(x))
	var zi := int(floor(z))
	var fx := x - float(xi)
	var fz := z - float(zi)
	var y := int(floor(from_head_y))
	var y_hi := int(floor(to_head_y))
	while y <= y_hi:
		var sp := _occ_span(cell_value_at(Vector3i(xi, y, zi)), fx, fz)
		if sp != Vector2.ZERO:
			var occ_lo := float(y) + sp.x
			if occ_lo >= from_head_y - _EPS:
				return occ_lo
		y += 1
	return INF

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
