extends SceneTree
## verify_choplag — COSMOS-TREE-BUGS CHOP-LAG gate (docs/COSMOS-TREE-BUGS-DESIGN.md, "Addendum
## 2026-08-07"). Promotes probe_choplag.gd's S1/S5/S6 scenarios to assertions. Proves
## FP_CHOP_DEBRIS_CALM bounds how long a chopped WOOD canopy stays awake — closing the two
## pre-existing, now-EXPOSED cost sources FP_GRAV_BOX_COVER/FP_CHOP_COLLIDER_CARVE made observable
## (debris correctly STAYS instead of flying away/sinking in ~2s, so the machinery below finally runs
## long enough to be felt): (1) the missing wood awake-deadline (§12 — wood never auto-freezes, so
## `_refresh_dormancy` left `_physics_process` off for it FOREVER, defeating FP_TREEPHYS_BOUND's 8s
## deadline entirely), and (2) the sim/snowfall-cadence rebuild feeding the FAST 15/60-frame player-edit
## debounce, re-pointing shapes under a settling body every ~0.25-1.0s and jolting it back awake.
##
## Gates:
##   G-CL-QUIET  single wood chop, quiet world: dormant <= 4s (pins the already-healthy natural case —
##               Godot's own native sleep threshold gets there in ~2.4s regardless of this flag).
##   G-CL-DIRT   chop + sim_ground_rebuild every 30 frames (the snowfall cadence): dormant <=
##               TREEPHYS_MAX_ACTIVE_SEC + 4s; falsifier (flag OFF): "never in window" (~30s measured).
##               Once dormant, gc.update() cost per second stays near its idle baseline — nowhere near
##               the ~100-280 ms/s cost measured while the body is genuinely awake mid-churn.
##   G-CL-FELL   4 breaks 2s apart (the felling flow): every body dormant <= 10s after the LAST break;
##               falsifier (flag OFF): ~15.7s measured.
##
## RUN (sed FACETED+FP_M1_POOL+FP_FIXED_FRAME+FP_CLIMATE_BIOMES+FP_BIOME_SPACE_FIX+FP_GRAV_BOX_COVER+
##      FP_CHOP_COLLIDER_CARVE+FP_TREEPHYS_BOUND+FP_CHOP_DEBRIS_CALM all ON):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_choplag.gd 2>/dev/null | grep VERIFY
## Falsifier: same, ONLY FP_CHOP_DEBRIS_CALM sed'd back OFF — must go RED on G-CL-DIRT and G-CL-FELL
## (probe_choplag.gd already proved it measurably does: S5 23.7s / S6 30.0s "never in window").
## NOTE (fable-trees): Performance.TIME_PHYSICS_PROCESS is unreliable on this threaded build (reports
## ~200ms inside 16ms frames) — this gate measures wall-clock gc.update() timings and awake-window
## duration directly (Time.get_ticks_usec() + VoxelBody.is_awake()), never that monitor.
## Exits 0 all-pass / 1 on any failure.

# Comfortably above the worst post-dormant baseline measured (~2.3 ms/s native) and ~10x below the
# genuinely-awake mid-churn cost measured broken (100-280 ms/s) — a threshold that discriminates
# "fixed" from "broken", not a fragile exact pin on incidental per-call overhead.
const POST_DORMANT_GC_US_PER_SEC_MAX := 20000

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var w: WorldManager
var gc: Node
var host: Node

func _initialize() -> void:
	print("=== verify_choplag (COSMOS-TREE-BUGS CHOP-LAG) — FP_CHOP_DEBRIS_CALM=%s FP_TREEPHYS_BOUND=%s FP_GRAV_BOX_COVER=%s FP_CHOP_COLLIDER_CARVE=%s ===" % [
		str(CubeSphere.FP_CHOP_DEBRIS_CALM), str(CubeSphere.FP_TREEPHYS_BOUND),
		str(CubeSphere.FP_GRAV_BOX_COVER), str(CubeSphere.FP_CHOP_COLLIDER_CARVE)])
	TerrainConfig.warm_up()
	TreeGen.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	w = WorldManager.new()
	w.name = "ChopLagGateWM"
	get_root().add_child(w)
	for i in range(5):
		await process_frame
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	host = af if af != null else w
	for ch in host.get_children():
		if ch is GroundCollider:
			gc = ch
	var cc := FacetAtlas.centre_cell(fid)

	# Find 3 well-separated WOOD (oak, trunk id 4) trees within 170 of the centre — one per scenario, so
	# a break in one scenario's tree never touches another's.
	var wood_bases: Array = []
	for gx in range(floori(float(cc.x - 170) / 10.0), floori(float(cc.x + 170) / 10.0)):
		if wood_bases.size() >= 3:
			break
		for gz in range(floori(float(cc.y - 170) / 10.0), floori(float(cc.y + 170) / 10.0)):
			var tb := TreeGen.tree_base(gx, gz)
			if tb.y <= TerrainConfig.SEA_LEVEL:
				continue
			if absi(tb.x - cc.x) > 170 or absi(tb.z - cc.y) > 170:
				continue
			if _world_trunk_id(tb) != BlockCatalog.WOOD:
				continue
			var far_enough := true
			for b: Vector3i in wood_bases:
				if absi(tb.x - b.x) <= 20 and absi(tb.z - b.z) <= 20:
					far_enough = false
					break
			if far_enough:
				wood_bases.append(tb)
	print("  wood trees: %s" % str(wood_bases))
	if wood_bases.size() < 3:
		_ok(false, "found 3 well-separated wood trees within 170 of centre (got %d)" % wood_bases.size())
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1)
		return

	# G-CL-QUIET: single wood chop, quiet world.
	var r1 := await _scenario("G-CL-QUIET", wood_bases[0], 8, false, false)
	_ok(r1["slept_at"] >= 0.0 and r1["slept_at"] <= 4.0,
		"G-CL-QUIET: dormant <= 4s (got %s)" % _fmt_slept(r1["slept_at"]))

	# G-CL-DIRT: chop + background sim-dirt (the snowfall cadence, every 30 frames).
	var r2 := await _scenario("G-CL-DIRT", wood_bases[1], 40, true, false)
	var dirt_bound := CubeSphere.TREEPHYS_MAX_ACTIVE_SEC + 4.0
	_ok(r2["slept_at"] >= 0.0 and r2["slept_at"] <= dirt_bound,
		"G-CL-DIRT: dormant <= TREEPHYS_MAX_ACTIVE_SEC+4s=%.1fs (got %s)" % [dirt_bound, _fmt_slept(r2["slept_at"])])
	_ok(r2["post_dormant_gc_us_max_per_sec"] < POST_DORMANT_GC_US_PER_SEC_MAX,
		"G-CL-DIRT: post-dormant gc.update() stays near idle baseline (worst second %d us < %d)" % [
			r2["post_dormant_gc_us_max_per_sec"], POST_DORMANT_GC_US_PER_SEC_MAX])

	# G-CL-FELL: a break every 2s x4 (the felling flow) — every body dormant <= 10s after the LAST break.
	var r3 := await _scenario("G-CL-FELL", wood_bases[2], 30, false, true)
	_ok(r3["slept_at"] >= 0.0,
		"G-CL-FELL: body reaches dormant within the window (got %s)" % _fmt_slept(r3["slept_at"]))
	if r3["slept_at"] >= 0.0:
		var since_last_break: float = r3["slept_at"] - r3["last_break_t"]
		_ok(since_last_break <= 10.0,
			"G-CL-FELL: dormant <= 10s after the last break (last break t=%.1fs, slept t=%.1fs, delta=%.1fs)" % [
				r3["last_break_t"], r3["slept_at"], since_last_break])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _fmt_slept(t: float) -> String:
	return ("%.1fs" % t) if t >= 0.0 else "never in window"

## The trunk id as the WORLD sees it (block_id_at: datum shift + snow interception + junction), or 0.
func _world_trunk_id(tb: Vector3i) -> int:
	var sy := int(w.surface_y(float(tb.x) + 0.5, float(tb.z) + 0.5))
	for y in range(sy - 4, sy + 12):
		var id := w.block_id_at(Vector3i(tb.x, y, tb.z))
		if id == BlockCatalog.WOOD:
			return id
	return 0

func _free_bodies() -> void:
	for ch in host.get_children():
		if ch is VoxelBody:
			ch.queue_free()

## Run one chop scenario for up to `seconds` of physics time, mirroring probe_choplag.gd's mechanics
## exactly (real WorldManager, real GroundCollider gate/build, real break_terrain): open the gate with a
## marker, let the region build, go quiet, chop the two bottom trunk cells, then track the canopy body's
## awake window (optionally with background sim-dirt every 30 frames and/or a felling sequence of
## further breaks every 2s). Returns {slept_at, last_break_t, post_dormant_gc_us_max_per_sec}
## (slept_at = -1.0 if never dormant in the window).
func _scenario(tag: String, base: Vector3i, seconds: int, dirt: bool, fell: bool) -> Dictionary:
	_free_bodies()
	await physics_frame
	await physics_frame
	var player_pos := Vector3(float(base.x) + 2.5, w.surface_y(float(base.x) + 2.5, float(base.z) + 0.5), float(base.z) + 0.5)
	var marker: VoxelBody = VoxelBody.spawn_loose(host, {Vector3i(base.x + 4, int(player_pos.y) + 1, base.z): BlockCatalog.STONE}, w)
	for i in range(120):
		if gc != null:
			gc.call("update", player_pos)
		await physics_frame
	marker.queue_free()
	await physics_frame

	var ty0 := -0x40000000
	var sy := int(w.surface_y(float(base.x) + 0.5, float(base.z) + 0.5))
	for y in range(sy - 4, sy + 12):
		if w.block_id_at(Vector3i(base.x, y, base.z)) == BlockCatalog.WOOD:
			ty0 = y
			break
	if ty0 == -0x40000000:
		print("  [%s] (no trunk found in world view — skipping)" % tag)
		return {"slept_at": -1.0, "last_break_t": 0.0, "post_dormant_gc_us_max_per_sec": 0}
	var r1 := w.break_terrain(Vector3i(base.x, ty0, base.z), player_pos)
	var r2 := w.break_terrain(Vector3i(base.x, ty0 + 1, base.z), player_pos)
	print("  [%s] tree @ %s trunk y=%d.. broke ids %d,%d" % [tag, str(base), ty0, r1, r2])
	await physics_frame
	var body: VoxelBody = null
	for ch in host.get_children():
		if ch is VoxelBody and (body == null or (ch as VoxelBody).block_count() > body.block_count()):
			body = ch
	if body == null:
		print("  [%s] (no canopy body — skipping)" % tag)
		return {"slept_at": -1.0, "last_break_t": 0.0, "post_dormant_gc_us_max_per_sec": 0}

	var slept_at := -1.0
	var last_break_t := 0.0
	var gc_us_this_sec := 0
	var post_dormant_max := 0
	for step in range(seconds * 60):
		var t := step / 60.0
		if dirt and step % 30 == 0:
			w.sim_ground_rebuild()
		if fell and step % 120 == 0 and step > 0 and step <= 480:
			var by := -1
			for y in range(int(player_pos.y) - 4, int(player_pos.y) + 12):
				if w.block_id_at(Vector3i(base.x, y, base.z)) > 0:
					by = y
					break
			if by >= 0:
				w.break_terrain(Vector3i(base.x, by, base.z), player_pos)
				last_break_t = t
		var t0 := Time.get_ticks_usec()
		if gc != null:
			gc.call("update", player_pos)
		gc_us_this_sec += int(Time.get_ticks_usec() - t0)
		await physics_frame
		if step % 60 == 59:
			if slept_at >= 0.0:
				post_dormant_max = maxi(post_dormant_max, gc_us_this_sec)
			gc_us_this_sec = 0
		var awake_now := is_instance_valid(body) and body.is_awake()
		if not awake_now:
			slept_at = t if slept_at < 0.0 else slept_at
		else:
			slept_at = -1.0                     # a fell-triggered re-wake resets the dormancy clock
	print("  [%s] slept_at=%s" % [tag, _fmt_slept(slept_at)])
	return {"slept_at": slept_at, "last_break_t": last_break_t, "post_dormant_gc_us_max_per_sec": post_dormant_max}
