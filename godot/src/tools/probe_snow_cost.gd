extends SceneTree
## COSMOS-FOREST-SNOW-PROC probe (design measurement, NOT a gate): attribute the per-column cost of one
## SnowfallSystem fixed step in a WARM (no-snow, melt-branch) region vs a COLD (accumulating) region, and
## micro-time each callee of _process_column so the design doc's budget is measured, not guessed.
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/probe_snow_cost.gd

const SS := preload("res://src/sim/snowfall_system.gd")
const WM := preload("res://src/world/world_manager.gd")

func _mk_world(nm: String) -> WorldManager:
	var w := WorldManager.new()
	w.name = nm
	get_root().add_child(w)
	# _ready is deferred past _initialize in a SceneTree script — wire the env now so
	# apply_state_transitions/sample take their live (non-null-env) path in the micro-split.
	if w.environment == null:
		w.environment = PerVoxelEnvironment.new()
	return w

## Find a region whose coarse mean surface temperature passes `pred`, preferring forest columns.
func _find_region(warm: bool, want_forest: bool) -> Vector2i:
	for i in range(1, 8000):
		var cx := i * 137
		var cz := i * 71
		var sum := 0.0
		var forest := 0
		var n := 0
		var offs: Array[int] = [-32, 0, 32]
		for dz in offs:
			for dx in offs:
				var x: int = cx + dx
				var z: int = cz + dz
				var g := TerrainConfig.height_at(x, z)
				var t: float = TerrainConfig.column_profile(x, z).w
				sum += ClimateModel.surface_temperature(g, t)
				if TerrainConfig.biome_at(x, z) == TerrainConfig.B_FOREST:
					forest += 1
				n += 1
		var mean := sum / float(n)
		if warm and mean > 10.0 and (not want_forest or forest >= 5):
			return Vector2i(cx, cz)
		if not warm and mean < -1.5:
			return Vector2i(cx, cz)
	return Vector2i(0, 0)

func _time_steps(w: WorldManager, col: Vector2i, k: int, label: String) -> void:
	var snow: SnowfallSystem = SS.new()
	snow.setup(w)
	var times: Array[float] = []
	var writes_total := 0
	for s in range(k):
		var t0 := Time.get_ticks_usec()
		snow.step_now(col)
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		writes_total += snow.last_writes
	times.sort()
	var total := 0.0
	for t in times: total += t
	print("  %s: steps=%d writes=%d  per-step ms min %.3f p50 %.3f p90 %.3f max %.3f mean %.3f" % [
		label, k, writes_total, times[0], times[k / 2], times[int(k * 0.9)], times[k - 1], total / float(k)])

func _micro(w: WorldManager, col: Vector2i, label: String) -> void:
	# The exact column set of ONE step (tile 0 of the region), timed callee-by-callee, N repeats.
	var snow: SnowfallSystem = SS.new()
	snow.setup(w)
	var cols := snow._ordered_step_columns(col)
	if cols.is_empty():
		print("  %s: EMPTY step" % label)
		return
	var reps := 20
	var acc := {"height_at": 0, "column_profile": 0, "snow_stack_at": 0, "surface_temp": 0,
		"apply_state_transitions": 0, "env_sample": 0, "column_depth": 0, "cell_value_g1": 0, "is_snowing": 0}
	for r in range(reps):
		for c in cols:
			var t0 := Time.get_ticks_usec()
			var g := TerrainConfig.height_at(c.x, c.y)
			var t1 := Time.get_ticks_usec()
			var tt: float = TerrainConfig.column_profile(c.x, c.y).w
			var t2 := Time.get_ticks_usec()
			var pk := TerrainConfig.snow_stack_at(c.x, c.y)
			var t3 := Time.get_ticks_usec()
			var ts := ClimateModel.surface_temperature(g, tt)
			var t4 := Time.get_ticks_usec()
			w.apply_state_transitions(Vector3i(c.x, g, c.y))
			var t5 := Time.get_ticks_usec()
			w.environment.sample(Vector3(float(c.x) + 0.5, float(g) + 0.5, float(c.y) + 0.5))
			var t6 := Time.get_ticks_usec()
			snow.column_depth(c.x, c.y)
			var t7 := Time.get_ticks_usec()
			w.cell_value_at(Vector3i(c.x, g + 1, c.y))
			var t8 := Time.get_ticks_usec()
			snow.is_snowing(c.x, c.y)
			var t9 := Time.get_ticks_usec()
			acc["height_at"] += t1 - t0
			acc["column_profile"] += t2 - t1
			acc["snow_stack_at"] += t3 - t2
			acc["surface_temp"] += t4 - t3
			acc["apply_state_transitions"] += t5 - t4
			acc["env_sample"] += t6 - t5
			acc["column_depth"] += t7 - t6
			acc["cell_value_g1"] += t8 - t7
			acc["is_snowing"] += t9 - t8
			if pk < -1: print(pk)  # keep pk/ts alive
			if ts < -10000.0: print(ts)
	var n := reps * cols.size()
	print("  %s: %d cols x %d reps — per-CALL µs:" % [label, cols.size(), reps])
	for k: String in acc:
		print("    %-24s %8.2f µs   (x32 cols = %.2f ms/step)" % [k, float(acc[k]) / float(n), float(acc[k]) / float(n) * 32.0 / 1000.0])

func _initialize() -> void:
	print("=== probe_snow_cost (COSMOS-FOREST-SNOW-PROC design measurement) ===")
	BlockCatalog.ensure_ready()
	var warm := _find_region(true, true)
	var cold := _find_region(false, false)
	print("  warm forest col = %s   cold col = %s" % [str(warm), str(cold)])
	var w := _mk_world("SnowProbe")
	# 49 tiles/region → run 60 steps so every tile of the rotation is visited at least once.
	_time_steps(w, warm, 60, "WARM forest step_now")
	_time_steps(w, cold, 60, "COLD step_now")
	_micro(w, warm, "WARM micro-split")
	_micro(w, cold, "COLD micro-split")
	quit(0)
