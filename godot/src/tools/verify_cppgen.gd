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
		"gen_facet": -1,
		"flat_world": true,
		"cube_arid": cube_arid,
		"block_ids": block_ids,
		"model_count": 8,
		"waterlog": false,
	}

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
	_ok(bool(dg.get("flat_world", false)) and int(dg.get("gen_facet", 0)) == -1,
		"G-CG-TABLES — epoch (flat_world, gen_facet) crossed intact")
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
	var staged_prof: Vector4 = gen.call("column_profile", -1, 0, 0)
	_ok(is_nan(staged_prof.x) and is_nan(staged_prof.y),
		"G-CG-STAGED — column_profile returns NaN while staged (loud, not a plausible column)")
	var staged_cell: int = gen.call("resolve_cell", -1, 0, 0, 0)
	_ok(staged_cell == -1,
		"G-CG-STAGED — resolve_cell returns -1 while staged (never a packable cell value; 0 would mean AIR)")
	var staged_cols: Dictionary = gen.call("sample_columns", -1, PackedInt64Array([0]))
	_ok(staged_cols.has("heights") and staged_cols.has("biomes") \
			and staged_cols.has("water") and staged_cols.has("colors"),
		"G-CG-STAGED — sample_columns returns the §7.2 key set {heights,biomes,water,colors}")
	_ok(bool(staged_cols.get("staged", false)),
		"G-CG-STAGED — sample_columns is marked staged (this assert MUST be inverted when S2/S3 lands)")

	_done(0 if _fail == 0 else 1)

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
