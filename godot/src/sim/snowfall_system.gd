class_name SnowfallSystem
extends RefCounted
## The dormant-by-default snowfall SIMULATION (SNOW-ACCUMULATION Decision 4). A plain object OWNED and
## STEPPED by WorldManager from `_process` on the MAIN thread: it grows (and, at a warm fringe, melts)
## the variable-height snow around the player by rewriting the ONE affected cell per column through
## `WorldManager._write_cell` → `_edits`, so every change PERSISTS (authoritative over generation, like
## break/place) and leaving the area FREEZES the state — return restores it.
##
## DORMANT-BY-DEFAULT (the hard project law) is satisfied STRUCTURALLY, not by throttling: there is NO
## global tick. Only the (2·SIM_RADIUS+1)² columns around the player are ever considered, and only ONE
## 16×16 tile of that region is visited per fixed 0.5 s step (deterministic rotation), with hard per-step
## caps on columns touched and cells written → ≤ ~4 godot_voxel data-block remeshes per step. Outside the
## region nothing runs; the accumulated `_edits` simply sit there.
##
## DETERMINISM: the sim advances by wall-clock delta accumulated into STEP_SECONDS plus an integer
## `step_counter`; the weather gate is a PURE function of (SEED, step_counter, position) (a FastNoiseLite
## salted SEED+105), so a scripted run with a fixed step count and fixed player column is byte-identical
## across runs (verify relies on this). Cross-session the weather PHASE restarts (step_counter is not
## persisted); the accumulated snow itself persists via `_edits`, which is the requirement.

# --- region + cadence (the dormancy bounds, §4.2) ------------------------------
const STEP_SECONDS := 0.5           ## fixed-timestep accumulator (frame-rate independent)
const SIM_RADIUS := 48              ## columns (Chebyshev) around the player — the ONLY active region
const TILE := 16                    ## one world-aligned 16×16-column tile is visited per step (== one data block wide)
const MAX_COLUMN_UPDATES := 32      ## per step, within the tile
const MAX_CELL_WRITES := 32         ## HARD per-step cell-write cap (⇒ ≤ ~4 block remeshes)
const MAX_STEPS_PER_FRAME := 4      ## anti-spiral clamp: never run more than this many fixed steps in one _process

# --- the per-step rule constants (§4.3) ----------------------------------------
const SNOW_STORM_EXTRA := 6         ## a storm may pile D up to D_baseline + this many tenths above the static baseline
const WEATHER_THRESHOLD := 0.25     ## is_snowing where the salted weather noise exceeds this
const WEATHER_SPEED := 0.05         ## weather noise advances this far along its 3rd axis per step (slow storms)
const _WEATHER_XZ_FREQ := 0.004     ## spatial frequency of the weather field (hundreds-of-blocks-wide storms)
const _WEATHER_SALT := 105          ## SEED + 105 — the weather salt (registered in TerrainConfig's salt registry)

# --- cost discipline (§4.4) ----------------------------------------------------
const SNOW_EDIT_BUDGET := 200_000   ## hard cap on snow-authored `_edits` cells; at the cap the sim stops ADDING columns
const _MAX_COLUMN_SCAN := 48        ## safety bound on the per-column stack scan (never loops forever)

var world: WorldManager             ## the owner; all writes route through it (main-thread only)
var step_counter: int = 0           ## monotonic fixed-step index — drives BOTH tile rotation AND the weather phase
var snow_cells: int = 0             ## number of snow-authored `_edits` cells (the budget counter)
var last_writes: int = 0            ## cell writes performed in the most recent step (verify pin)
var last_step_cells: Array[Vector3i] = []   ## the cells written/reverted in the most recent step (verify: block count)

var _snow_id: int = -1
var _weather: FastNoiseLite
var _accum: float = 0.0
var _budget_logged: bool = false

func setup(wm: WorldManager) -> void:
	world = wm
	_snow_id = BlockCatalog.id_of(&"snow_block")
	# The weather field: a NEW FastNoiseLite salted SEED+105, WARMED on the main thread (created + sampled
	# once here) so it is never first-touched from a worker. It is only ever sampled on the main thread.
	_weather = FastNoiseLite.new()
	_weather.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_weather.seed = TerrainConfig.SEED + _WEATHER_SALT
	_weather.frequency = 1.0                      # we pre-scale coordinates ourselves (§4.3)
	_weather.get_noise_3d(0.0, 0.0, 0.0)          # warm-up sample

# --- the game loop entry (WorldManager._process) -------------------------------

## Accumulate wall-clock `delta` and run as many fixed 0.5 s steps as have elapsed (clamped to
## MAX_STEPS_PER_FRAME so a long frame / tab-restore can't stall the main thread). Player column is
## derived from `player_pos`. This is the ONLY caller in the live game; verify drives `step_now` directly.
func process(delta: float, player_pos: Vector3) -> void:
	if world == null:
		return
	_accum += delta
	var steps := 0
	while _accum >= STEP_SECONDS and steps < MAX_STEPS_PER_FRAME:
		_accum -= STEP_SECONDS
		steps += 1
		step_now(Vector2i(int(floor(player_pos.x)), int(floor(player_pos.z))))
	# Drop any backlog beyond the clamp so we don't spiral on the next frame.
	if _accum >= STEP_SECONDS:
		_accum = fmod(_accum, STEP_SECONDS)

# --- one deterministic fixed step (§4.2) ---------------------------------------

## Run exactly ONE fixed step around `player_col`: visit one rotating tile of the active region, process
## up to MAX_COLUMN_UPDATES of its in-radius columns (a window that advances each revisit so the whole
## tile is eventually covered), cap total cell writes at MAX_CELL_WRITES, and do ONE ground rebuild at the
## end iff anything was written. Pure/deterministic in (SEED, step_counter, player_col). step_counter is
## advanced at the end.
func step_now(player_col: Vector2i) -> void:
	last_writes = 0
	last_step_cells.clear()
	if world == null:
		step_counter += 1
		return
	var tiles := _tiles_for(player_col)
	if tiles.is_empty():
		step_counter += 1
		return
	var ti := step_counter % tiles.size()
	var rotations := step_counter / tiles.size()          # how many full cycles → advances the in-tile window
	var cols := _in_radius_columns(tiles[ti], player_col)
	if cols.is_empty():
		step_counter += 1
		return
	var start := (rotations * MAX_COLUMN_UPDATES) % cols.size()
	var writes := 0
	var n := mini(MAX_COLUMN_UPDATES, cols.size())
	for k in range(n):
		if writes >= MAX_CELL_WRITES:
			break
		var col: Vector2i = cols[(start + k) % cols.size()]
		writes += _process_column(col.x, col.y, player_col)
	last_writes = writes
	if writes > 0:
		world.sim_ground_rebuild()                        # ONE debounced rebuild per step, only if a write happened
	step_counter += 1

# --- the per-column rule (§4.3) ------------------------------------------------

## Apply the per-step rule to column (x, z); returns the number of cell writes it performed (0..2).
## Steps: (1) M1 evaluator piggyback on the surface cell (bounded, self-gating). (2) ACCUMULATE if the
## surface is sub-zero AND it's snowing AND the dynamic depth is below the storm cap → +1 tenth on the
## ONE affected stack cell. (3) MELT if the surface is warm → −1 tenth toward 0, writing the bare
## generated form when it reaches baseline. NO `_structural_update`, NO body wake (a snow tick is not a
## disturbance): `_write_cell` + paint only.
func _process_column(x: int, z: int, player_col: Vector2i) -> int:
	var writes := 0
	var g := TerrainConfig.height_at(x, z)
	var t := TerrainConfig.column_profile(x, z).w
	var ts := ClimateModel.surface_temperature(g, t)

	# (1) Piggyback the M1 melt/freeze EVALUATOR on the exposed surface cell (§4.3.4): bounded (one call
	# per processed column), main-thread, and its SET (freeze) edge stays self-gated to the generated
	# surface height. In a stable world this is a no-op (worldgen is the fixed point) — it only bites at a
	# genuine warm/cold fringe, so it almost never costs a write.
	var surface := Vector3i(x, g, z)
	if world.apply_state_transitions(surface):
		writes += 1
		last_step_cells.append(surface)

	if ts < TerrainConfig.SNOW_T0:
		# --- ACCUMULATE ---
		if not is_snowing(x, z):
			return writes
		var pk := TerrainConfig.snow_stack_at(x, z)       # baseline (capped<<8)|(whole<<4)|top
		var capped := (pk >> 8) & 1
		var whole := (pk >> 4) & 0xF
		if capped == 1 and whole == 0:
			# Capped column whose snow is still ENTIRELY inside the smoothing lip's fill nibble (D<10): the
			# stack floor is not yet established. Growing here would float a layer above a half-filled lip
			# (a fringe glitch), so the sim leaves it at the static baseline. Deep/uncapped columns — the
			# visible common case — accumulate normally.
			return writes
		var d_cur := column_depth(x, z)
		var d_base := whole * 10 + (pk & 0xF)
		if d_cur >= d_base + SNOW_STORM_EXTRA:
			return writes                                 # already at the storm ceiling for this column
		var d_new := d_cur + 1
		var yy := g + 1 + (d_new - 1) / 10                # the ONE stack cell that changes
		var frac := d_new % 10
		var newv := CellCodec.pack(_snow_id, 0) if frac == 0 \
			else CellCodec.pack(_snow_id, CellCodec.make_layer(frac))
		if _grow_cell(Vector3i(x, yy, z), newv, player_col):
			writes += 1
	else:
		# --- MELT (warm surface, §4.3.3) --- ts >= 0 ⇒ the static baseline here is bare, so melt drives the
		# column toward 0, writing each cell's bare generated form as it empties.
		var d_cur := column_depth(x, z)
		if d_cur <= 0:
			return writes
		var yy := g + 1 + (d_cur - 1) / 10                # current top stack cell
		var d_new := d_cur - 1
		var rem := d_new - (yy - (g + 1)) * 10            # tenths left in this cell after the melt (0..9)
		var newv: int
		if rem <= 0:
			newv = TerrainConfig.generated_cell(x, yy, z) # emptied → the bare generated form
		else:
			newv = CellCodec.pack(_snow_id, CellCodec.make_layer(rem))
		if _melt_cell(Vector3i(x, yy, z), newv):
			writes += 1
	return writes

# --- the write primitives (persistence, budget, baseline-equal skip; §4.4) -----

## Write one accumulation cell. Refuses (returns false, no write) when: the target is tree- or
## player-occupied or carries a NON-snow overlay edit (never bury a placed block — snow stacks on top);
## the new value EQUALS the generated value (baseline-equal costs nothing); or the budget is full and this
## would ADD a new snow cell (existing snow cells still evolve). Otherwise routes through `_write_cell`.
func _grow_cell(cell: Vector3i, newv: int, player_col: Vector2i) -> bool:
	if _blocked_for_snow(cell, player_col):
		return false
	var newc := CellCodec.canonical(newv)
	if newc == CellCodec.canonical(TerrainConfig.generated_cell(cell.x, cell.y, cell.z)):
		return false                                      # baseline-equal: never written (persist-cost-free)
	var had := world.has_edit(cell)
	if not had:
		if snow_cells >= SNOW_EDIT_BUDGET:
			_log_budget()
			return false                                  # at cap: stop ADDING columns (existing ones evolve)
		snow_cells += 1
	world._write_cell(cell, newc)
	last_step_cells.append(cell)
	return true

## Write one melt cell. When the target reaches its bare generated form and an overlay edit exists there,
## the edit is REVERTED (freeing a snow cell) rather than storing a redundant baseline-equal edit; when it
## is already generated, nothing happens. A partial-melt value is written normally.
func _melt_cell(cell: Vector3i, newv: int) -> bool:
	var newc := CellCodec.canonical(newv)
	if newc == CellCodec.canonical(TerrainConfig.generated_cell(cell.x, cell.y, cell.z)):
		if world.has_edit(cell):
			world.sim_revert_cell(cell)                   # melted to baseline: drop the edit, repaint generated
			snow_cells = maxi(0, snow_cells - 1)
			last_step_cells.append(cell)
			return true
		return false                                      # already at baseline: no change
	var had := world.has_edit(cell)
	if not had:
		if snow_cells >= SNOW_EDIT_BUDGET:
			return false
		snow_cells += 1
	world._write_cell(cell, newc)
	last_step_cells.append(cell)
	return true

## True iff a snow write to `cell` must be skipped: a tree cell, a cell the player's body occupies, or a
## cell holding a non-snow overlay edit (a player-placed block or a dug-air hole).
func _blocked_for_snow(cell: Vector3i, player_col: Vector2i) -> bool:
	if TreeGen.block_at(cell.x, cell.y, cell.z) != BlockCatalog.AIR:
		return true
	if cell.x == player_col.x and cell.z == player_col.y:
		# Guard the player's body column (feet cell through head, ~2 cells) so snow never buries the player.
		var feet := world.floor_under(float(cell.x) + 0.5, float(cell.z) + 0.5, float(cell.y + 4))
		var fy := int(floor(feet))
		if cell.y >= fy and cell.y <= fy + 2:
			return true
	if world.has_edit(cell) and CellCodec.mat(world.cell_value_at(cell)) != _snow_id:
		return true
	return false

func _log_budget() -> void:
	if _budget_logged:
		return
	_budget_logged = true
	push_warning("[SnowfallSystem] snow-edit budget (%d cells) reached — no longer ADDING snow columns; existing snow still evolves, player edits untouched." % SNOW_EDIT_BUDGET)
	print("[SnowfallSystem] snow-edit BUDGET reached (%d cells) — freezing the accumulation footprint." % SNOW_EDIT_BUDGET)

# --- reading the dynamic column state ------------------------------------------

## The column's CURRENT dynamic snow depth D_cur in tenths above g+1 (the reference of the generation
## formula, §3.1), derived ENTIRELY from the live cells (overlay-else-generated) so it round-trips through
## save/load and never needs a side table. Uncapped: the contiguous snow stack from g+1. Capped: the
## smoothing lip owns the first 10 tenths (g+1) — if its fill is <10 the snow is still inside the lip
## (D = that fill), else 10 + the contiguous stack from g+2.
func column_depth(x: int, z: int) -> int:
	var g := TerrainConfig.height_at(x, z)
	var pk := TerrainConfig.snow_stack_at(x, z)
	var capped := (pk >> 8) & 1
	var y0: int
	var base: int
	if capped == 1:
		var lip := world.cell_value_at(Vector3i(x, g + 1, z))
		var lipfill := CellCodec.snow_fill(lip)
		if lipfill < 10:
			return lipfill                                # snow entirely within the lip (fringe)
		y0 = g + 2
		base = 10                                         # the lip reserves the g+1 slot
	else:
		y0 = g + 1
		base = 0
	var d := base
	var y := y0
	var scanned := 0
	while scanned < _MAX_COLUMN_SCAN:
		var v := world.cell_value_at(Vector3i(x, y, z))
		if CellCodec.mat(v) != _snow_id:
			break
		var tn := CellCodec.snow_tenths(CellCodec.modifier(v))
		d += tn
		if tn < 10:
			break                                         # a partial LAYER is always the stack top
		y += 1
		scanned += 1
	return d

## The column's STATIC baseline depth D_baseline in tenths (from the pure-SEED snow_stack byte).
func baseline_depth(x: int, z: int) -> int:
	var byte := TerrainConfig.snow_stack_at(x, z) & 0xFF
	return ((byte >> 4) & 0xF) * 10 + (byte & 0xF)

# --- the weather gate (§4.3.1) -------------------------------------------------

## The storm gate at column (x, z) for the CURRENT step: a spatially-coherent, time-evolving field. Pure
## in (SEED+105, step_counter, position) — the whole reason a scripted run is deterministic.
func is_snowing(x: int, z: int) -> bool:
	var v := _weather.get_noise_3d(
		float(x) * _WEATHER_XZ_FREQ,
		float(z) * _WEATHER_XZ_FREQ,
		float(step_counter) * WEATHER_SPEED)
	return v > WEATHER_THRESHOLD

# --- tile enumeration (§4.2) ---------------------------------------------------

## The world-aligned 16×16 tiles overlapping the active region (player_col ± SIM_RADIUS), in a fixed
## row-major order. World alignment (not player alignment) is what keeps every tile ONE data block wide,
## bounding a step's writes to ≤ ~4 data blocks. Count is stable while the player stands still (verify
## determinism); it shifts by at most one row/column as the player crosses a 16-boundary in the live game.
func _tiles_for(player_col: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var a0 := _floor_div(player_col.x - SIM_RADIUS, TILE)
	var a1 := _floor_div(player_col.x + SIM_RADIUS, TILE)
	var b0 := _floor_div(player_col.y - SIM_RADIUS, TILE)
	var b1 := _floor_div(player_col.y + SIM_RADIUS, TILE)
	for b in range(b0, b1 + 1):
		for a in range(a0, a1 + 1):
			out.append(Vector2i(a, b))
	return out

## The in-radius (Chebyshev ≤ SIM_RADIUS) columns of tile (a, b), fixed row-major order. Corner tiles are
## partially inside, so this trims them — every returned column is genuinely in the active region.
func _in_radius_columns(tile: Vector2i, player_col: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x0 := tile.x * TILE
	var z0 := tile.y * TILE
	for dz in range(TILE):
		var z := z0 + dz
		if absi(z - player_col.y) > SIM_RADIUS:
			continue
		for dx in range(TILE):
			var x := x0 + dx
			if absi(x - player_col.x) > SIM_RADIUS:
				continue
			out.append(Vector2i(x, z))
	return out

static func _floor_div(a: int, b: int) -> int:
	var q := a / b
	if (a % b) != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q
