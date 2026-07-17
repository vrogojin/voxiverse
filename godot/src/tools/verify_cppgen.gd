extends SceneTree
## verify_cppgen — COSMOS L5(a) truth gate (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.6).
##
## The port replaces the runtime-compiled GDScript generator with a compiled C++ one
## (VoxelGeneratorCosmos, engine patch 0007). Terrain physics is ANALYTIC — block_id_at/floor_under
## read TerrainConfig GDScript directly, and no collision meshes exist — so the C++ generator only
## ever produces RENDER buffers while GDScript stays the source of truth for queries. That means
## byte-equality between the two is not a quality metric, it is the ENTIRE argument that render and
## physics agree. This gate is the oracle for that argument. It is never weakened to make the port
## pass; if it goes red, the port is wrong.
##
## STAGE COVERAGE. The port lands in stages and this gate grows with them:
##   S1 (this file, now)  — the foundation gates below. The port's byte-equality argument rests on one
##                          load-bearing claim: that C++ and GDScript sample the SAME noise bit-for-bit.
##                          S1 tests that claim directly and early, because if it is false the whole
##                          approach is void and the cheapest possible moment to learn that is before
##                          any of resolve_cell is transcribed.
##   S2 (next)            — G-CG-PROFILE: C++ column_profile == GDScript column_profile over >= 1e5
##                          sampled columns.
##   S3                   — G-CG-EQUAL: the N-block cell-for-cell buffer equality gate (N >= 256)
##                          spanning biomes, depth bands, ridges/seams, coasts/liquid, tree stencils.
##
## S1 GATES:
##   G-CG-CLASS    the patched module binary actually carries the class. Guards against the project's
##                 known failure mode of trusting a build that silently didn't include the change.
##   G-CG-SETUP    setup() accepts the frozen epoch and reports itself ready.
##   G-CG-TABLES   the frozen tables crossed the GDScript->C++ boundary INTACT (sizes echoed back match
##                 what was sent). Asserted, not assumed: a silently-truncated table would produce
##                 plausible-but-wrong terrain, the exact failure class this port must not have.
##   G-CG-NOISE    THE LOAD-BEARING S1 GATE. For every noise in the stack, the value C++ reads through
##                 Noise::get_noise_2d/3d is EXACTLY equal (==, not approximately) to the value GDScript
##                 reads from the same object at the same coordinates. Exact equality is the right test
##                 and not a strict one: it is literally the same C++ function on the same instance, so
##                 anything other than bit-equality means an assumption about the marshalling boundary
##                 (float width, arg conversion) is broken — which would sink S2/S3 byte-equality.
##   G-CG-FALSIFY  the gate can FAIL. A comparison harness that has never been seen to go red is not
##                 evidence of anything; today a gate passed 9/0 while the authoritative gate failed,
##                 and R7's gate was only trustworthy because sabotaging it caught 43,635 mismatches.
##                 So G-CG-NOISE's own comparator is re-run here against a deliberately perturbed value
##                 and MUST reject it.
##
## Run (needs the patched module binary from scripts/build.sh):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_cppgen.gd
## Runs in FLAT mode; needs no faceted atlas. Does NOT require FP_CPPGEN to be on — it drives the C++
## class directly, so it gates the port while the flag stays OFF in the shipped build.

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: %s" % m)
	else:
		_fail += 1
		print("  FAIL: %s" % m)

func _done(code: int) -> void:
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(code)

func _initialize() -> void:
	print("=== verify_cppgen (COSMOS L5a: the C++ worldgen port — foundation gates) ===")

	# --- G-CG-CLASS ---------------------------------------------------------------------------------
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		print("  FAIL: G-CG-CLASS — VoxelGeneratorCosmos is not in this binary.")
		print("        The engine was built without patch 0007, or the build silently fell back to")
		print("        stock templates. Rebuild: scripts/build.sh --rebuild, then check BUILD-INFO.txt.")
		_fail += 1
		_done(1)
		return
	_ok(true, "G-CG-CLASS — VoxelGeneratorCosmos present in the module binary")

	var gen: Object = ClassDB.instantiate("VoxelGeneratorCosmos")
	if gen == null:
		_ok(false, "G-CG-CLASS — VoxelGeneratorCosmos failed to instantiate")
		_done(1)
		return

	# --- build the frozen epoch, exactly as module_world's loader will ------------------------------
	TerrainConfig.warm_up()                       # main-thread noise + id bake (the frozen-epoch contract)
	var ns := TerrainConfig.noise_stack()

	# S1 uses small stand-in appearance tables: the emit loop that consumes them lands in S3, and this
	# stage's job is to prove the BOUNDARY carries them, not to bake a real library. S3 swaps these for
	# the loader's real frozen bake.
	var cube_arid := PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7])
	var block_ids := TerrainConfig.appearance_surface_materials()

	# The epoch this gate freezes must MIRROR what module_world's loader will freeze at S4 — otherwise
	# the gate proves equality for a configuration that never ships. Faceted vs flat is read from the
	# same const the engine reads, so the FACETED sed-toggle exercises the facet path here too.
	var faceted: bool = CubeSphere.FACETED
	var fid: int = -1
	var atlas := {}
	if faceted:
		FacetAtlas.warm_up()
		atlas = FacetAtlas.frozen_atlas()
		fid = TerrainConfig.active_facet()
		if fid < 0:
			fid = 0
			TerrainConfig.set_active_facet(fid)

	var cfg := {
		"hills": ns["hills"],
		"detail": ns["detail"],
		"continent": ns["continent"],
		"temperature": ns["temperature"],
		"humidity": ns["humidity"],
		"mountain": ns["mountain"],
		"seed": ns["seed"],
		"gen_face": 0,
		"gen_n": 0,
		"gen_facet": fid,
		"flat_world": true,
		"faceted": faceted,
		"m5c_corner": CubeSphere.M5C_CORNER,
		"cube_arid": cube_arid,
		"block_ids": block_ids,
		"model_count": 8,
		"waterlog": false,
		# TreeGen ids: slope firing consults the tree stencil, so the S2 slope gate needs these.
		"id_wood": BlockCatalog.WOOD,
		"id_leaf": BlockCatalog.LEAF,
		"id_spruce_log": BlockCatalog.id_of(&"spruce_log"),
		"id_spruce_leaf": BlockCatalog.id_of(&"spruce_leaves"),
		"id_birch_log": BlockCatalog.id_of(&"birch_log"),
		"id_birch_leaf": BlockCatalog.id_of(&"birch_leaves"),
	}
	if faceted:
		cfg["facet_frame"] = atlas["facet_frame"]
		cfg["facet_off"] = atlas["facet_off"]
		cfg["facet_r_blocks"] = atlas["facet_r_blocks"]

	# --- G-CG-SETUP ---------------------------------------------------------------------------------
	var ok: bool = gen.call("setup", cfg)
	_ok(ok, "G-CG-SETUP — setup() accepted the frozen epoch")
	_ok(gen.call("is_ready"), "G-CG-SETUP — generator reports ready")
	if not ok:
		_done(1)
		return

	var dg: Dictionary = gen.call("get_setup_digest")

	# --- G-CG-TABLES --------------------------------------------------------------------------------
	_ok(int(dg.get("cube_arid_size", -1)) == cube_arid.size(),
		"G-CG-TABLES — cube_arid crossed intact (%d)" % cube_arid.size())
	_ok(int(dg.get("block_ids_size", -1)) == block_ids.size(),
		"G-CG-TABLES — block_ids crossed intact (%d)" % block_ids.size())
	_ok(int(dg.get("seed", -1)) == TerrainConfig.SEED,
		"G-CG-TABLES — seed crossed intact (%d)" % TerrainConfig.SEED)
	_ok(bool(dg.get("flat_world", false)) and int(dg.get("gen_facet", -99)) == fid,
		"G-CG-TABLES — epoch (flat_world=true, gen_facet=%d) crossed intact" % fid)
	_ok(bool(dg.get("noise_ok", false)), "G-CG-TABLES — all six noise refs held C++-side")

	# --- G-CG-NOISE — the load-bearing gate ---------------------------------------------------------
	# Same coordinates the C++ digest probes. Exact equality: same function, same instance.
	var probes := [
		["probe_continent_2d", ns["continent"].get_noise_2d(12.0, -7.0), "continent 2d"],
		["probe_continent_3d", ns["continent"].get_noise_3d(12.0, -7.0, 33.0), "continent 3d"],
		["probe_mountain_2d", ns["mountain"].get_noise_2d(12.0, -7.0), "mountain 2d"],
		["probe_hills_2d", ns["hills"].get_noise_2d(12.0, -7.0), "hills 2d"],
		["probe_detail_2d", ns["detail"].get_noise_2d(12.0, -7.0), "detail 2d"],
		["probe_temperature_2d", ns["temperature"].get_noise_2d(12.0, -7.0), "temperature 2d"],
		["probe_humidity_2d", ns["humidity"].get_noise_2d(12.0, -7.0), "humidity 2d"],
	]
	var noise_all_equal := true
	var noise_nondegenerate := 0
	for pr in probes:
		var key: String = pr[0]
		var gd_val: float = pr[1]
		var label: String = pr[2]
		if not dg.has(key):
			_ok(false, "G-CG-NOISE — %s: C++ digest is missing %s" % [label, key])
			noise_all_equal = false
			continue
		var cpp_val: float = dg[key]
		var eq := _bit_equal(cpp_val, gd_val)
		if not eq:
			noise_all_equal = false
		# Count probes that actually carry signal. Two zeros compare equal for free, so a stack of
		# degenerate samples would make G-CG-NOISE green while testing nothing.
		if absf(gd_val) > 1e-9:
			noise_nondegenerate += 1
		_ok(eq, "G-CG-NOISE — %s: C++ %s == GDScript %s" % [label, _f(cpp_val), _f(gd_val)])
	_ok(noise_all_equal,
		"G-CG-NOISE — the whole noise stack is bit-identical across the GDScript/C++ boundary")
	# The anti-vacuity gate for G-CG-NOISE. Without it, "all equal" would also be the verdict if every
	# probe read 0.0 — i.e. if the noises were unseeded, or the probe coordinates happened to land on a
	# lattice zero. Requiring most of the stack to carry real signal is what makes the equality mean
	# "same function on the same data" rather than "same constant".
	_ok(noise_nondegenerate >= probes.size() - 1,
		"G-CG-NOISE — %d/%d probes are non-degenerate (equality is not vacuous)"
			% [noise_nondegenerate, probes.size()])
	if not noise_all_equal:
		print("        ^ THIS SINKS THE PORT'S BYTE-EQUALITY ARGUMENT. Stop and report before")
		print("          transcribing resolve_cell: S2/S3 equality cannot hold on a drifting noise base.")

	# --- G-CG-FALSIFY — prove the comparator can reject -------------------------------------------
	# Feed G-CG-NOISE's own comparator a value perturbed by one ulp-ish delta and require a reject.
	# Without this, "7 PASS" only means the comparator ran, not that it discriminates.
	var truth: float = ns["continent"].get_noise_2d(12.0, -7.0)
	_ok(not _bit_equal(truth + 1e-7, truth),
		"G-CG-FALSIFY — comparator REJECTS a 1e-7 perturbation (it can fail)")
	_ok(not _bit_equal(truth * 1.0000001, truth),
		"G-CG-FALSIFY — comparator REJECTS a 1e-7 relative perturbation (it can fail)")
	_ok(_bit_equal(truth, truth),
		"G-CG-FALSIFY — comparator ACCEPTS the identical value (it is not vacuously red)")

	# --- G-CG-CONTRACT — the one-sampler law's interface, pinned from S1 ---------------------------
	# SEAMLESS-SCALES §7.2 requires the C++ core to serve ALL FOUR of: the worker path, batch column
	# sampling, scalar parity queries, and a purity contract. Pinning the shape now (while the bodies
	# are still staged) is the point: it stops S2/S3 quietly dropping an entry point and rebuilding a
	# GDScript-side sampler for the skin or the far ring — which is the bifurcation §7.1 forbids, and
	# whose seam would land on a facet ridge.
	for m in ["generate_block", "sample_columns", "column_profile", "resolve_cell"]:
		_ok(gen.has_method(m), "G-CG-CONTRACT — §7.2 entry point exposed: %s" % m)

	# --- G-CG-STAGED — the staged entry points fail LOUD, not plausibly --------------------------
	# While S2/S3 are unimplemented these return sentinels. The gate asserts they are UNMISTAKABLE
	# rather than plausible: a zeroed profile (height 0, biome 0) or an AIR cell would be silently
	# consumable by a caller — and a physics caller believing "air here" is the float-through bug this
	# port must never introduce. NaN and -1 cannot be mistaken for real answers.
	# column_profile went LIVE in S2, so its staged-NaN assert is inverted here rather than deleted:
	# the tripwire did its job (it went red the moment the body landed, forcing this edit), and the
	# replacement keeps the same guarantee pointing the other way -- a live entry point must never
	# hand back a poison value.
	var live_prof: Vector4 = gen.call("column_profile", fid, 0, 0)
	_ok(not is_nan(live_prof.x) and not is_nan(live_prof.y),
		"G-CG-STAGED — column_profile is LIVE (S2): returns a real profile, not the staged NaN")
	var staged_cell: int = gen.call("resolve_cell", -1, 0, 0, 0)
	_ok(staged_cell == -1,
		"G-CG-STAGED — resolve_cell returns -1 while staged (never a packable cell value; 0 would mean AIR)")
	var staged_cols: Dictionary = gen.call("sample_columns", -1, PackedInt64Array([0]))
	_ok(staged_cols.has("heights") and staged_cols.has("biomes") \
			and staged_cols.has("water") and staged_cols.has("colors"),
		"G-CG-STAGED — sample_columns returns the §7.2 key set {heights,biomes,water,colors}")
	_ok(bool(staged_cols.get("staged", false)),
		"G-CG-STAGED — sample_columns is marked staged (this assert MUST be inverted when S2/S3 lands)")

	_s2_column_gates(gen)

	_done(0 if _fail == 0 else 1)

## ------------------------------------------------------------------------------------------------
## S2 — the column-math gates. C++ column_profile / slope_run_of vs the GDScript twin over >= 1e5
## columns. This is the stage's whole point: the port is only allowed to be fast if it is EQUAL.
##
##   G-CG-PROFILE  every sampled column's Vector4(g, biome, c, t) is EXACTLY equal across the
##                 boundary. Exact, not approximate — both sides run the same noise on the same
##                 instance through the same narrowings, so any difference is a transcription bug
##                 (an int32 hash, a float intermediate, a missed f32 round-trip), not a wobble.
##   G-CG-SLOPE    every sampled column's packed SHARP-SLOPE run matches. This is the deeper test:
##                 slope firing consults the TreeGen stencil and a 3x3 of column heights, so it
##                 exercises the tree hashes, the corner-target f32 rounding and the quarter-grid
##                 integer predicate all at once.
##   G-CG-COVER    the sweep is not vacuous: it must span most biomes, include coast columns, and
##                 actually FIRE some slope runs and hit some tree-gated columns. A 1e5-column gate
##                 that only ever saw flat ocean would be green and worthless.
##
## MEASURED SENSITIVITY — what these gates catch, and the ONE thing they mostly don't. Established by
## deliberate sabotage of the C++ build, not by reasoning:
##   * drift in c/t (the UNFLOORED Vector4 components): caught totally. A 1e-7 RELATIVE perturbation
##     of `c` mismatched 102,400/102,400 columns. G-CG-PROFILE is maximally sensitive here.
##   * an int64 -> int32 hash mixer (cosmos_terrain.h trap 1): caught by G-CG-SLOPE, 3/102,400.
##     Note how FEW: the tree hashes only matter where a tree actually gates a slope, so the
##     coverage asserts above are what give this gate its teeth. Without them it would be luck.
##   * an f32 intermediate inside height_c (trap 2): **NOT caught — 0/640,000 columns.** This is a
##     real, characterised limit and not an oversight. height_c's output is int(floor(h)), so an f32
##     perturbation of h (ulp ~5e-6 at these magnitudes) only changes the answer when h lands within
##     an ulp of an integer: P ~ 1e-6 per column. More N does not fix it (640k was already tried).
##     Consequences, stated honestly: such a bug would surface as a ~1-in-a-million column being one
##     block off — which IS a render/physics divergence, just a rare one. The defences that actually
##     cover it are (a) using `double` uniformly by construction rather than by testing, which is why
##     trap 2 is documented at the top of cosmos_terrain.h, and (b) S3's cell gate, where a single
##     wrong g shifts that column's ENTIRE stack and so is caught by any cell of it.
## ------------------------------------------------------------------------------------------------
func _s2_column_gates(gen: Object) -> void:
	var faceted: bool = CubeSphere.FACETED
	var fid: int = TerrainConfig.active_facet() if faceted else -1

	# The sweep's shape differs by world topology, and that is not incidental — it is where the
	# coverage actually lives:
	#   FLAT   — one infinite plane. Biome variety comes from WANDERING, so anchor patches at the
	#            landmark finders (spawn/mountain/cold/coast) rather than at arbitrary offsets.
	#   FACETED— a facet is only ~200 blocks across, so four anchors land on near-identical terrain
	#            (measured: 2 biomes, 0 slope fires — G-CG-COVER caught exactly that and refused to
	#            call the sweep meaningful). On a sphere the variety is across FACETS: different
	#            facets sit at different latitudes, hence different climate. So sweep facets. This
	#            also exercises cell_dir against many different frozen frames, which is precisely
	#            where a frame indexing/sign error would surface — the class patch 0003 warns about.
	var sweeps: Array = []                # [[fid, cx, cz], ...]
	var span := 160
	if faceted:
		var nf: int = int(FacetAtlas.frozen_atlas()["facet_count"])
		# FIND facets that actually EXERCISE the machinery instead of striding blindly. A facet is only
		# ~200 blocks, and slopes fire only on steep (mountain) terrain, so a naive stride can — and did
		# — pick 24 flat facets and leave G-CG-SLOPE comparing 0 == 0 on every column (vacuously green).
		# So probe each facet's centre column for a slope fire, prioritise the ones that fire, then top
		# up to 24 with a stride for biome breadth. CENTRE each sweep on the facet's OWN domain: a
		# facet's local coords sit at its atlas offset, not 0, and sweeping around 0 samples columns
		# outside the facet where cell_dir extrapolates to junk. The probe uses the analytic path (cheap,
		# and only to CHOOSE facets — the byte-equality comparison below still uses the worker path).
		var firing: Array = []
		var f := 0
		while f < nf:
			var lo: Vector2i = FacetAtlas.dom_min(f)
			var hi: Vector2i = FacetAtlas.dom_max(f)
			var cx := (lo.x + hi.x) / 2
			var cz := (lo.y + hi.y) / 2
			TerrainConfig.set_active_facet(f)
			if TerrainConfig.slope_run_fires(TerrainConfig.slope_run_of(cx, cz)):
				firing.append([f, cx, cz])
				if firing.size() >= 12:
					break
			f += 1
		TerrainConfig.set_active_facet(fid)
		for e in firing:
			sweeps.append(e)
		var step: int = maxi(1, nf / 24)
		f = 0
		while f < nf and sweeps.size() < 24:
			var lo2: Vector2i = FacetAtlas.dom_min(f)
			var hi2: Vector2i = FacetAtlas.dom_max(f)
			sweeps.append([f, (lo2.x + hi2.x) / 2, (lo2.y + hi2.y) / 2])
			f += step
		span = int(ceil(sqrt(100000.0 / float(sweeps.size()))))  # keep the total >= 1e5
	else:
		for a in [TerrainConfig.find_spawn(), TerrainConfig.find_mountain(),
				TerrainConfig.find_cold(), TerrainConfig.find_coast()]:
			sweeps.append([-1, a.x, a.y])

	var n_cols := 0
	var prof_bad := 0
	var slope_bad := 0
	var first_prof_msg := ""
	var first_slope_msg := ""

	var biomes_seen := {}
	var coast_cols := 0
	var slope_fired := 0
	var tree_cols := 0

	for sw in sweeps:
		var sfid: int = sw[0]
		# The GDScript reference must be the WORKER path, not the analytic one: slope_run_of's
		# pcache == null branch reads the main-thread shape memo (_shape_entry) instead of the shared
		# predicate. module_world uses a GenCtx when faceted and a plain Dictionary memo when flat —
		# mirrored exactly, with a FRESH ctx per facet (a ctx is scoped to one facet by contract).
		var pcache = TerrainConfig.GenCtx.new(0, sfid) if faceted else {}
		for dz in range(span):
			for dx in range(span):
				var x: int = int(sw[1]) + dx - span / 2
				var z: int = int(sw[2]) + dz - span / 2
				n_cols += 1

				var gd_p: Vector4 = TerrainConfig.column_profile(x, z, pcache)
				var cpp_p: Vector4 = gen.call("column_profile", sfid, x, z)
				if not (cpp_p.x == gd_p.x and cpp_p.y == gd_p.y and cpp_p.z == gd_p.z and cpp_p.w == gd_p.w):
					prof_bad += 1
					if first_prof_msg == "":
						first_prof_msg = "(%d,%d) C++ (%s,%s,%s,%s) != GD (%s,%s,%s,%s)" % [x, z,
							_f(cpp_p.x), _f(cpp_p.y), _f(cpp_p.z), _f(cpp_p.w),
							_f(gd_p.x), _f(gd_p.y), _f(gd_p.z), _f(gd_p.w)]

				var gd_r: int = TerrainConfig.slope_run_of(x, z, pcache)
				var cpp_r: int = gen.call("slope_run_of", sfid, x, z)
				if cpp_r != gd_r:
					slope_bad += 1
					if first_slope_msg == "":
						first_slope_msg = "(%d,%d) C++ run 0x%x != GD run 0x%x" % [x, z, cpp_r, gd_r]

				# Coverage bookkeeping (from the GDScript side — the oracle).
				var g := int(gd_p.x)
				biomes_seen[int(gd_p.y)] = true
				if g >= TerrainConfig.SEA_LEVEL - 2 and g <= TerrainConfig.SEA_LEVEL + 2:
					coast_cols += 1
				if TerrainConfig.slope_run_fires(gd_r):
					slope_fired += 1
				if g > TerrainConfig.SEA_LEVEL and TreeGen.block_at(x, g + 1, z, pcache) != BlockCatalog.AIR:
					tree_cols += 1

	print("  ... swept %d columns across %d sweeps (faceted=%s, span=%d)" % [n_cols, sweeps.size(), faceted, span])

	_ok(n_cols >= 100000, "G-CG-COVER — swept %d columns (>= 1e5 required)" % n_cols)
	_ok(biomes_seen.size() >= 5,
		"G-CG-COVER — sweep spans %d distinct biomes: %s" % [biomes_seen.size(), str(biomes_seen.keys())])
	_ok(coast_cols > 0, "G-CG-COVER — sweep includes %d coast/sea-level columns" % coast_cols)
	_ok(slope_fired > 0, "G-CG-COVER — sweep FIRES %d SHARP-SLOPE runs (the predicate is exercised)" % slope_fired)
	_ok(tree_cols > 0, "G-CG-COVER — sweep hits %d tree-occupied columns (the stencil is exercised)" % tree_cols)

	_ok(prof_bad == 0, "G-CG-PROFILE — %d/%d columns mismatched%s"
		% [prof_bad, n_cols, ("" if prof_bad == 0 else ("; first: " + first_prof_msg))])
	_ok(slope_bad == 0, "G-CG-SLOPE — %d/%d slope runs mismatched%s"
		% [slope_bad, n_cols, ("" if slope_bad == 0 else ("; first: " + first_slope_msg))])

## Exact equality. NOT approximate: C++ and GDScript call the same const method on the same Noise
## instance, so any difference at all is a broken assumption about the marshalling boundary, not a
## tolerable numeric wobble. A tolerance here would hide precisely the drift this gate hunts.
func _bit_equal(a: float, b: float) -> bool:
	return a == b

## Full-precision float for the log. GDScript's `%` operator has no %g/%.17g — using one silently
## prints the raw format string and turns a numeric gate's output into noise, which is how a gate
## stops being readable evidence. String.num(v, 17) is the supported way to see every digit.
func _f(v: float) -> String:
	return String.num(v, 17)
