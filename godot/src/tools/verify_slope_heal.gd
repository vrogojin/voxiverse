extends SceneTree
## verify_slope_heal — FP_SLOPE_MANIFEST_HEAL gate (docs/COSMOS-SHARP-SLOPE-FACET-PARITY-DESIGN.md §4).
##
## THE BUG (measured): FP_MANIFEST_SLICE defers _build_slope_manifest past generator construction, so every generator
## FREEZES the still-EMPTY slope ARID tables (C++ immutable Parameters / GDScript COW). The deferred cold bake reassigns
## the module's _slope_arid / _snow_slope_arid MEMBERS, but the already-built generators keep the old empty tables — so
## every generated SLOPE cell takes the cube fallback in the RENDER (a full-cube LADDER) while the analytic collision
## carves the true plane. FP_SLOPE_MANIFEST_HEAL rebuilds + swaps the whole generator (active terrain + pool slots) from
## the NOW-FILLED members at cold-bake stage 3, so the render finally emits the carved slope shapes.
##
## This gate stands up a real module_world under the FP_MANIFEST_SLICE lifecycle (needs the godot_voxel module; SKIPS
## otherwise) and drives it end to end (core bake → build generator → cold bake → heal), asserting on the pinned repro
## slope column facet 578 (13038, 8155), run 0x14665, whole targets (68,69,69,67), g=67, physics floor y=67:
##
##   G-SMH-CARVE-FIRES — the slope carve fires there on B_MOUNTAINS with targets (68,69,69,67); census fires > 0
##                       (guards the biome gate from silent drift; the worldgen carve, per §1, is intact).
##   G-SMH-STALE       — the ROOT cause, flag-independent: a generator built BEFORE the cold bake renders the run cells
##                       as CUBES both before AND after the members fill (frozen-table staleness) — proving nothing
##                       refreshes a live generator's frozen copy.
##   G-SMH-FROZEN      — flag on: _make_generator (the heal's call) reads the FILLED members ⇒ the rebuilt generator's
##                       FROZEN slope table size == the member size (> 0), snow-slope likewise, and model_count ==
##                       _library_model_count(). Under FP_CPPGEN this reads the compiled generator's get_setup_digest
##                       slope_arid_size / snow_slope_arid_size (patch 0007). This is the verify gap the design named.
##   G-SMH-PARITY      — flag on: generating the repro block through the HEALED generator emits SLOPE models at the run
##                       cells (in the slope table, != the STALE cube fallback); the slope silhouette's LOW corner ==
##                       g (67) == the analytic physics floor, while the STALE cube ladder tops out at 69 (gap 2, the
##                       sink). Render top == physics floor.
##   G-SMH-INSTALL     — the flag-under-test discriminator: after driving the lifecycle, the ACTUAL installed generator
##                       (module.get_generator() and every pool slot) has a FILLED frozen slope table when the flag is
##                       ON, and stays EMPTY (the shipped stale behaviour, byte-identical) when OFF.
##
## RUN (faceted + slice on; sed FP_CPPGEN + FP_SLOPE_MANIFEST_HEAL to taste, then revert):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_MANIFEST_SLICE := false/const FP_MANIFEST_SLICE := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_CPPGEN := false/const FP_CPPGEN := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_SLOPE_MANIFEST_HEAL := false/const FP_SLOPE_MANIFEST_HEAL := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_slope_heal.gd
## Exits 0 all-pass / 1 on any failure. SKIPS (pass) when the module is absent or FP_MANIFEST_SLICE is off (no staleness
## to heal). Run OFF (heal false) and ON (heal true) — all pass both.

const MW := preload("res://src/world/voxel_module/module_world.gd")

# The pinned repro column (facet-lattice coords on facet 578), per the design.
const PIN_FID := 578
const PIN_X := 13038
const PIN_Z := 8155
const PIN_TARGETS := Vector4i(68, 69, 69, 67)
const PIN_G := 67

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: ", m)
	else:
		_fail += 1
		print("  FAIL: ", m)

func _done(code: int) -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(code)

# The frozen slope-table SIZE of a generator — get_setup_digest (compiled C++) or the script member (GDScript).
func _gen_slope_size(gen: Object) -> int:
	if gen == null:
		return -1
	if gen.has_method("get_setup_digest"):
		return int((gen.call("get_setup_digest") as Dictionary).get("slope_arid_size", -1))
	var a: Variant = gen.get("slope_arid")
	return (a as PackedInt32Array).size() if a is PackedInt32Array else -1

func _gen_snow_slope_size(gen: Object) -> int:
	if gen == null:
		return -1
	if gen.has_method("get_setup_digest"):
		return int((gen.call("get_setup_digest") as Dictionary).get("snow_slope_arid_size", -1))
	var a: Variant = gen.get("snow_slope_arid")
	return (a as PackedInt32Array).size() if a is PackedInt32Array else -1

func _gen_model_count(gen: Object) -> int:
	if gen == null:
		return -1
	if gen.has_method("get_setup_digest"):
		return int((gen.call("get_setup_digest") as Dictionary).get("model_count", -1))
	return int(gen.get("model_count"))

# Generate the 16^3 block at `origin` through `gen`, exactly as verify_cppgen_buffer does (the TYPE channel holds the
# ARID the blocky mesher reads — terrain physics is analytic, so this buffer IS the render side).
func _gen_into(gen: Object, origin: Vector3i) -> Object:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", 16, 16, 16)
	buf.call("set_channel_depth", 0, 1)          # DEPTH_16_BIT — matches the live TYPE channel
	buf.call("fill", 0, 0)
	gen.call("generate_block", buf, Vector3(origin.x, origin.y, origin.z), 0)
	return buf

# The ARID emitted at world-lattice (x,y,z) in a freshly-generated block through `gen`.
func _emit_arid(gen: Object, x: int, y: int, z: int) -> int:
	var ox := (x >> 4) << 4
	var oy := (y >> 4) << 4
	var oz := (z >> 4) << 4
	var buf: Object = _gen_into(gen, Vector3i(ox, oy, oz))
	return int(buf.call("get_voxel", x - ox, y - oy, z - oz, 0))

func _initialize() -> void:
	print("=== verify_slope_heal (FP_SLOPE_MANIFEST_HEAL: G-SMH) ===")
	print("  flags: FP_SLOPE_MANIFEST_HEAL=%s FACETED=%s FP_CPPGEN=%s FP_MANIFEST_SLICE=%s FP_M1_POOL=%s" % [
		CubeSphere.FP_SLOPE_MANIFEST_HEAL, CubeSphere.FACETED, CubeSphere.FP_CPPGEN,
		CubeSphere.FP_MANIFEST_SLICE, CubeSphere.FP_M1_POOL])
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  SKIP: godot_voxel module absent (no VoxelTerrain)."); _done(0); return
	if not CubeSphere.FACETED:
		print("  SKIP: FACETED off — the repro is a faceted mountain slope (fid %d)." % PIN_FID); _done(0); return
	if not CubeSphere.FP_MANIFEST_SLICE:
		print("  SKIP: FP_MANIFEST_SLICE off — no deferred staleness to heal (synchronous bake is already correct).")
		_done(0); return

	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	if PIN_FID >= FacetAtlas.total_facet_count():
		print("  SKIP: facet %d absent (facet_count=%d)." % [PIN_FID, FacetAtlas.total_facet_count()]); _done(0); return
	TerrainConfig.set_active_facet(PIN_FID)

	# ---- G-SMH-CARVE-FIRES — the analytic carve (the worldgen, per §1, is intact) --------------------------------
	var srun: int = TerrainConfig.slope_run_of(PIN_X, PIN_Z)
	var fires: bool = TerrainConfig.slope_run_fires(srun)
	_ok(fires, "G-SMH-CARVE-FIRES — slope carve fires at fid %d (%d,%d), run 0x%x" % [PIN_FID, PIN_X, PIN_Z, srun])
	var g: int = int(TerrainConfig.column_profile(PIN_X, PIN_Z).x)
	var rng: Vector2i = TerrainConfig.slope_run_range(srun, g)          # (min target, max target) = (physics floor, cube-top)
	# Decode the 4 corner targets from the bottom run cell's modifier (public path): targets = lo + slope_deltas(m).
	var lo: int = rng.x
	var m_lo: int = TerrainConfig.slope_run_modifier_at(srun, g, lo)
	var targets: Vector4i = Vector4i(lo, lo, lo, lo) + CellCodec.slope_deltas(m_lo)
	print("  carve: g=%d range=%s targets=%s (pin expects g=%d targets=%s)" % [g, str(rng), str(targets), PIN_G, str(PIN_TARGETS)])
	_ok(g == PIN_G, "G-SMH-CARVE-FIRES — column height g == %d" % PIN_G)
	_ok(targets == PIN_TARGETS, "G-SMH-CARVE-FIRES — whole targets == %s" % str(PIN_TARGETS))
	_ok(rng.x == PIN_G, "G-SMH-CARVE-FIRES — physics floor (low corner) == g == %d" % PIN_G)
	# Census: slopes must fire on more than this one column across the facet's mountain flank.
	var census_fires := 0
	var lo_d: Vector2i = FacetAtlas.dom_min(PIN_FID)
	var hi_d: Vector2i = FacetAtlas.dom_max(PIN_FID)
	var cx := lo_d.x
	while cx <= hi_d.x:
		var cz := lo_d.y
		while cz <= hi_d.y:
			if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(cx, cz)):
				census_fires += 1
			cz += 8
		cx += 8
	_ok(census_fires > 0, "G-SMH-CARVE-FIRES — census: %d firing columns over the facet flank" % census_fires)

	# ---- Stand up the module under the FP_MANIFEST_SLICE lifecycle ----------------------------------------------
	var mw = MW.new()
	mw.name = "SlopeHealGate"
	get_root().add_child(mw)
	TerrainConfig.set_active_facet(PIN_FID)
	var ok: bool = mw.setup()
	_ok(ok, "module_world.setup() built terrain + core bake")
	if not ok:
		_done(1); return
	TerrainConfig.set_active_facet(PIN_FID)

	# Pre-bake: the slope MEMBER table is still empty (slice deferred it).
	var slope_member0: int = mw.manifest_baked_count("slope")
	_ok(slope_member0 == 0, "setup: slope member table DEFERRED (baked count == 0)")

	# The STALE generator — built now, before the cold bake, exactly as the boot-spawn / setup() one was. It freezes
	# the EMPTY slope table.
	var stale: Object = mw._make_generator(PIN_FID)
	_ok(stale != null, "built a pre-bake (stale) generator")
	_ok(_gen_slope_size(stale) == 0, "stale generator froze an EMPTY slope table (size 0)")
	# The run cells (y in [lo, hi-1]) — every one renders as a NON-air CUBE fallback (the ladder) through the stale gen.
	var run_cells: Array[int] = []
	for y in range(rng.x, rng.y):
		run_cells.append(y)
	_ok(run_cells.size() > 0, "run has %d slope cells (y in %s)" % [run_cells.size(), str(run_cells)])
	var stale_arids: Array[int] = []
	for y in run_cells:
		stale_arids.append(_emit_arid(stale, PIN_X, y, PIN_Z))
	var stale_all_nonair := true
	for a in stale_arids:
		if a == 0:
			stale_all_nonair = false
	_ok(stale_all_nonair, "stale run cells emit non-air (solid) ARIDs %s" % str(stale_arids))

	# ---- Drive the deferred cold bake to completion (fills the members; heals when the flag is on) ---------------
	TerrainConfig.set_active_facet(PIN_FID)
	mw.begin_deferred_manifest_bake()
	var iters := 0
	while mw.manifest_cold_pending() and iters < 60:
		mw._process(0.1)
		iters += 1
	var slope_member1: int = mw.manifest_baked_count("slope")
	print("  after deferred bake (%d frames): slope member baked=%d pending=%s" % [iters, slope_member1, mw.manifest_cold_pending()])
	_ok(not mw.manifest_cold_pending(), "deferred cold bake completed (pending cleared)")
	_ok(slope_member1 > 0, "cold bake FILLED the slope member table (baked count > 0)")

	# ---- G-SMH-STALE — the frozen-table staleness (flag-independent ROOT proof) ----------------------------------
	# Re-generate the run cells through the SAME stale generator: it STILL emits cubes (its frozen empty table never
	# saw the fill) even though the MEMBER table is now full — this is precisely why the ladder persists live.
	var slope_tab: PackedInt32Array = mw.get("_slope_arid")
	var stale_post: Array[int] = []
	var stale_post_all_cube := true
	for y in run_cells:
		var a := _emit_arid(stale, PIN_X, y, PIN_Z)
		stale_post.append(a)
		if slope_tab.has(a):
			stale_post_all_cube = false
	_ok(stale_post_all_cube, "G-SMH-STALE — stale generator STILL renders cubes post-fill (frozen staleness) %s" % str(stale_post))

	# ---- G-SMH-FROZEN — the heal's rebuild reads the FILLED members ----------------------------------------------
	var healed: Object = mw._make_generator(PIN_FID)
	_ok(healed != null, "built a post-bake (healed) generator")
	var member_slope_size: int = slope_tab.size()
	var member_snow_slope_size: int = (mw.get("_snow_slope_arid") as PackedInt32Array).size()
	print("  frozen sizes: healed slope=%d (member %d)  healed snow_slope=%d (member %d)  model_count %d (lib %d)" % [
		_gen_slope_size(healed), member_slope_size, _gen_snow_slope_size(healed), member_snow_slope_size,
		_gen_model_count(healed), mw._library_model_count()])
	_ok(_gen_slope_size(healed) == member_slope_size and member_slope_size > 0,
		"G-SMH-FROZEN — healed generator's FROZEN slope table == member (%d)" % member_slope_size)
	_ok(_gen_snow_slope_size(healed) == member_snow_slope_size,
		"G-SMH-FROZEN — healed generator's FROZEN snow-slope table == member (%d)" % member_snow_slope_size)
	_ok(_gen_model_count(healed) == mw._library_model_count(),
		"G-SMH-FROZEN — healed generator's model_count == library model count (%d)" % mw._library_model_count())

	# ---- G-SMH-PARITY — render top == physics floor (per-cell) ---------------------------------------------------
	# Through the HEALED generator each run cell emits a SLOPE model (in the slope table), != the stale cube. The slope
	# model's silhouette low corner == g (physics floor); the stale cube ladder tops out at rng.y (the sink of ~2).
	var healed_arids: Array[int] = []
	var healed_all_slope := true
	var changed_from_stale := true
	for i in run_cells.size():
		var y: int = run_cells[i]
		var a := _emit_arid(healed, PIN_X, y, PIN_Z)
		healed_arids.append(a)
		if not slope_tab.has(a):
			healed_all_slope = false
		if a == stale_arids[i]:
			changed_from_stale = false
	print("  render: stale run ARIDs=%s  healed run ARIDs=%s  slope_floor=%d cube_top=%d" % [
		str(stale_arids), str(healed_arids), rng.x, rng.y])
	_ok(healed_all_slope, "G-SMH-PARITY — healed run cells render SLOPE models (in the slope table)")
	_ok(changed_from_stale, "G-SMH-PARITY — the heal CHANGED the render at every run cell (cube -> slope)")
	_ok(rng.x == g, "G-SMH-PARITY — rendered slope LOW corner (%d) == physics floor g (%d)" % [rng.x, g])
	_ok(rng.y - rng.x >= 1, "G-SMH-PARITY — the stale cube ladder topped %d blocks ABOVE the physics floor (the sink)" % (rng.y - rng.x))

	# ---- G-SMH-INSTALL — the flag-under-test discriminator -------------------------------------------------------
	# The ACTUAL installed generator(s): filled when the heal ran (ON), empty (shipped stale, byte-identical) when OFF.
	var pool: Dictionary = mw._pool
	if not pool.is_empty():
		var all_healed := true
		var all_stale := true
		for fid in pool.keys():
			var sg: Object = (pool[fid] as Dictionary)["generator"]
			var sz := _gen_slope_size(sg)
			if sz <= 0:
				all_healed = false
			if sz != 0:
				all_stale = false
		if CubeSphere.FP_SLOPE_MANIFEST_HEAL:
			_ok(all_healed, "G-SMH-INSTALL(ON) — every pool slot's generator has a FILLED frozen slope table")
		else:
			_ok(all_stale, "G-SMH-INSTALL(OFF) — every pool slot's generator stayed EMPTY (shipped stale, byte-identical)")
	else:
		var live: Object = mw.get_generator()
		var live_sz := _gen_slope_size(live)
		print("  installed active generator frozen slope size = %d" % live_sz)
		if CubeSphere.FP_SLOPE_MANIFEST_HEAL:
			_ok(live_sz > 0, "G-SMH-INSTALL(ON) — the installed active generator has a FILLED frozen slope table (%d)" % live_sz)
		else:
			_ok(live_sz == 0, "G-SMH-INSTALL(OFF) — the installed active generator stayed EMPTY (shipped stale, byte-identical)")

	mw.queue_free()
	_done(1 if _fail > 0 else 0)
