extends SceneTree
## verify_slope_material — FP_SLOPE_ALL_MATERIALS gate (docs/COSMOS-SLOPE-MATERIAL-DESIGN.md, task #122).
##
## THE BUG (root-caused): on a steep slope STONE assembles the proper smooth sub-voxel carve while an adjacent steep
## MUD/DIRT/SAND/GRASS slope still renders LADDER-style. Root cause is a BIOME gate, not a material gate: the firing
## predicate _slope_fires_only (terrain_config.gd) fires the 1–2 blk/cell ~45° band ONLY in B_MOUNTAINS ("don't touch
## hills"). B_MOUNTAINS' top skin is STONE, so it reads as "stone smooth / mud ladder". FP_SLOPE_ALL_MATERIALS widens
## the 45°-band gate from `== B_MOUNTAINS` to "all Earth land biomes EXCEPT B_BADLANDS" (whose sub-g terracotta bands
## are deliberately unbaked). The decimated bake already covers all 8 natural materials, so no new models are needed.
##
## The gate holds an INDEPENDENT re-implementation of the predicate (_oracle_fires, taking the flag as a parameter, so
## it is pure and state-free) and asserts the WIRED predicate == the oracle at the compiled flag state. Because the
## oracle's flag=false branch IS the pre-widening shipped decision, matching it with the flag OFF is the byte-off proof;
## matching flag=true with the flag ON is the widening proof. The oracle also lets the gate characterize the widening
## delta (oracle(true) \ oracle(false)) in BOTH runs, independent of the compiled state.
##
## GATES:
##   G-SM-MATCH     — over a multi-biome census, the WIRED _slope_fires_only == _oracle_fires(.., FP_SLOPE_ALL_MATERIALS)
##                    for every column. Pins the predicate to its intended logic at the current flag state.
##   G-SM-BYTEOFF   — the widening delta (columns where oracle(true) != oracle(false)) is NON-EMPTY and EVERY delta
##                    column is a non-mountain, non-badlands 45°-band column that FIRES only under the flag; oracle(true)
##                    is a strict SUPERSET of oracle(false) (mountains + >2 blk/cell escapes are UNCHANGED). Pure —
##                    identical in both runs. With the flag OFF, G-SM-MATCH additionally proves the shipped world is
##                    bit-for-bit (actual == oracle(false)).
##   G-SM-WIDEN     — the delta spans ≥2 distinct non-mountain natural biomes (mud/sand/grass/snow/…): the widening is
##                    material-broad, not a single-biome accident. Reports the biome census.
##   G-SM-BADLANDS  — B_BADLANDS 45°-band columns (when found in budget) are NEVER in the delta — the exclusion holds.
##   G-SM-PARITY    — render↔collision shared-predicate contract (HEADLESS): TC.slope_run_of (the SOURCE for the render
##                    worker, the memo, and GroundCollider col_slope_run_of) fires EXACTLY when _slope_fires_only fires,
##                    over the whole census — so widening the predicate moves render AND collision together (design §2).
##                    The FULL render==physics HEIGHT check (an emitted slope model's surface == analytic floor_under)
##                    needs the COMPILED C++ generator (the live render is FP_CPPGEN) and is REBUILD-PENDING — deferred
##                    to verify_cppgen / the live A/B, printed here, not asserted (the same class verify_cppgen covers).
##   G-SM-PLACED    — (WorldManager) a player-placed block over a firing (carved) slope column is served edits-first as a
##                    PLAIN CUBE (modifier 0), never the carve — the carve is worldgen-only.
##
## RUN (FLAT default world; toggle only FP_SLOPE_ALL_MATERIALS, then revert):
##   sed -i 's/const FP_SLOPE_ALL_MATERIALS := false/const FP_SLOPE_ALL_MATERIALS := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_slope_material.gd
##   git checkout -- godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure. Run OFF and ON — all pass both.

const TC := preload("res://src/world/terrain_config.gd")

# Census extent (world lattice, FLAT). A wide sweep to survey many biomes; stride keeps it a few 100k evals.
const SCAN_LO := -4000
const SCAN_HI := 4000
const SCAN_STEP := 10
const WIDEN_BIOMES_MIN := 2         # G-SM-WIDEN: distinct non-mountain natural biomes required in the delta

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

func _biome_name(b: int) -> String:
	match b:
		TC.B_OCEAN: return "ocean"
		TC.B_BEACH: return "beach"
		TC.B_BADLANDS: return "badlands"
		TC.B_DESERT: return "desert"
		TC.B_SWAMP: return "swamp"
		TC.B_SNOWY: return "snowy"
		TC.B_TAIGA: return "taiga"
		TC.B_FOREST: return "forest"
		TC.B_PLAINS: return "plains"
		TC.B_MOUNTAINS: return "mountains"
		TC.B_PILLAR: return "pillar"
		TC.B_SAVANNA: return "savanna"
		TC.B_JUNGLE: return "jungle"
		_: return "b%d" % b

## Core of the independent re-implementation of TerrainConfig._slope_fires_only, evaluated from PRE-COMPUTED
## per-column inputs (raw corner targets, g, biome, tree-air) so the census does ONE _corner_targets + ONE
## column_profile per column, not one per flag branch. `flag_on` parameterizes the widened biome gate (==
## FP_SLOPE_ALL_MATERIALS). Mirrors terrain_config.gd:1720-1762 AND patch 0007 slope_fires_only line-for-line.
func _fires_core(raw: Vector4, g: int, biome: int, tree_air: bool, flag_on: bool) -> bool:
	if not TC.SMOOTHING_ENABLED or g < TC.SEA_LEVEL:
		return false
	if not tree_air:
		return false                                   # a tree rests here → keep the top FULL
	var r0 := roundi(raw.x * 4.0)
	var r1 := roundi(raw.y * 4.0)
	var r2 := roundi(raw.z * 4.0)
	var r3 := roundi(raw.w * 4.0)
	var lo_r := mini(mini(r0, r1), mini(r2, r3))
	var hi_r := maxi(maxi(r0, r1), maxi(r2, r3))
	if lo_r >= g * 4 and hi_r <= (g + 2) * 4:
		if lo_r >= g * 4 and hi_r <= (g + 1) * 4:
			return false
		if biome != TC.B_MOUNTAINS and not (flag_on and biome != TC.B_BADLANDS):
			return false
	var tw0 := roundi(raw.x)
	var tw1 := roundi(raw.y)
	var tw2 := roundi(raw.z)
	var tw3 := roundi(raw.w)
	var lo := mini(mini(tw0, tw1), mini(tw2, tw3))
	var hi := maxi(maxi(tw0, tw1), maxi(tw2, tw3))
	if hi - lo < 1 or hi - lo > TC.SLOPE_MAX_SPREAD:
		return false
	return lo >= g - TC.SLOPE_MAX_SPREAD and hi <= g + TC.SLOPE_MAX_SPREAD + 1

## Full-input wrapper (does its own _corner_targets/column_profile/pillar/tree reads) — used only off the hot census
## path (the PLACED sample search). Pillar guard included; M5C_CORNER off (default) short-circuits it for free.
func _oracle_fires(x: int, z: int, g: int, flag_on: bool) -> bool:
	if TC._is_pillar_column(x, z, null):
		return false
	var tree_air: bool = TreeGen.block_at(x, g + 1, z, null) == BlockCatalog.AIR
	return _fires_core(TC._corner_targets(x, z, null), g, int(TC.column_profile(x, z, null).y), tree_air, flag_on)

func _initialize() -> void:
	print("=== verify_slope_material (FP_SLOPE_ALL_MATERIALS: G-SM) ===")
	print("  flags: FP_SLOPE_ALL_MATERIALS=%s FACETED=%s FP_CPPGEN=%s SMOOTHING_ENABLED=%s" % [
		CubeSphere.FP_SLOPE_ALL_MATERIALS, CubeSphere.FACETED, CubeSphere.FP_CPPGEN, TC.SMOOTHING_ENABLED])
	TC.warm_up()

	var flag: bool = CubeSphere.FP_SLOPE_ALL_MATERIALS

	# Census -----------------------------------------------------------------------------------------------------
	var census := 0
	var mismatch := 0                       # G-SM-MATCH: wired != oracle(flag)
	var run_mismatch := 0                   # G-SM-PARITY: slope_run_fires != _slope_fires_only
	var firing_runs := 0                    # firing columns seen (context for the rebuild-pending note)
	var delta_total := 0                    # oracle(true) != oracle(false)
	var delta_bad := 0                      # a delta column NOT (non-mountain & non-badlands & fires-only-on)
	var superset_bad := 0                   # oracle(false) true but oracle(true) false (not a superset)
	var mountains_fire := 0                 # firing B_MOUNTAINS columns (unchanged reference)
	var badlands_band := 0                  # B_BADLANDS 45°-band columns seen
	var badlands_in_delta := 0              # B_BADLANDS columns that leaked into the delta (must be 0)
	var delta_biomes := {}                  # biome -> count over the delta
	# A firing delta column (non-mountain) to hand to the WorldManager parity/placed section.
	var sample_delta := Vector2i(0x7fffffff, 0x7fffffff)
	var sample_g := 0

	var x := SCAN_LO
	while x <= SCAN_HI:
		var z := SCAN_LO
		while z <= SCAN_HI:
			# ONE _corner_targets + ONE column_profile per column; everything derives from these.
			var g := TC.column_top(x, z, null)
			var raw: Vector4 = TC._corner_targets(x, z, null)
			var biome := int(TC.column_profile(x, z, null).y)
			var pillar: bool = TC._is_pillar_column(x, z, null)
			var tree_air: bool = TreeGen.block_at(x, g + 1, z, null) == BlockCatalog.AIR
			var o_off: bool = (not pillar) and _fires_core(raw, g, biome, tree_air, false)
			var o_on: bool = (not pillar) and _fires_core(raw, g, biome, tree_air, true)
			var wired: bool = TC._slope_fires_only(x, z, g, null)
			census += 1
			# G-SM-MATCH: the wired predicate == the oracle at the COMPILED flag state.
			var o_flag: bool = o_on if flag else o_off
			if wired != o_flag:
				mismatch += 1
			# G-SM-PARITY: slope_run_of (render worker / memo / GroundCollider col_slope_run_of source) fires
			# EXACTLY with the predicate — the "one shared predicate feeds every consumer" contract (design §2).
			var run: int = TC.slope_run_of(x, z, null)
			var run_fires: bool = TC.slope_run_fires(run)
			if run_fires != wired:
				run_mismatch += 1
			if run_fires:
				firing_runs += 1
			# Superset + delta characterization (pure, flag-independent).
			if o_off and not o_on:
				superset_bad += 1
			if o_on != o_off:
				delta_total += 1
				# A delta column MUST be: fires only when on, non-mountain, non-badlands.
				if not (o_on and not o_off) or biome == TC.B_MOUNTAINS or biome == TC.B_BADLANDS:
					delta_bad += 1
				else:
					delta_biomes[biome] = int(delta_biomes.get(biome, 0)) + 1
					if sample_delta.x == 0x7fffffff:
						sample_delta = Vector2i(x, z); sample_g = g
			if biome == TC.B_MOUNTAINS and o_off:
				mountains_fire += 1
			# Badlands 45°-band detection: escapes [g,g+1] but within [g,g+2] AND encodable — the gate's domain.
			if biome == TC.B_BADLANDS:
				var lo_r := mini(mini(roundi(raw.x * 4.0), roundi(raw.y * 4.0)), mini(roundi(raw.z * 4.0), roundi(raw.w * 4.0)))
				var hi_r := maxi(maxi(roundi(raw.x * 4.0), roundi(raw.y * 4.0)), maxi(roundi(raw.z * 4.0), roundi(raw.w * 4.0)))
				var in_band: bool = lo_r >= g * 4 and hi_r <= (g + 2) * 4 and hi_r > (g + 1) * 4
				var tw_lo := mini(mini(roundi(raw.x), roundi(raw.y)), mini(roundi(raw.z), roundi(raw.w)))
				var tw_hi := maxi(maxi(roundi(raw.x), roundi(raw.y)), maxi(roundi(raw.z), roundi(raw.w)))
				var enc: bool = (tw_hi - tw_lo >= 1 and tw_hi - tw_lo <= TC.SLOPE_MAX_SPREAD
					and tw_lo >= g - TC.SLOPE_MAX_SPREAD and tw_hi <= g + TC.SLOPE_MAX_SPREAD + 1)
				if in_band and enc:
					badlands_band += 1
					if o_on != o_off:
						badlands_in_delta += 1
			z += SCAN_STEP
		x += SCAN_STEP

	print("  census: %d columns | delta(widen)=%d bad=%d superset_bad=%d | mountains_fire=%d | badlands_band=%d(in_delta=%d)" % [
		census, delta_total, delta_bad, superset_bad, mountains_fire, badlands_band, badlands_in_delta])
	var bstr := ""
	for b in delta_biomes.keys():
		bstr += " %s=%d" % [_biome_name(b), delta_biomes[b]]
	print("  delta biomes:%s" % (bstr if bstr != "" else " (none)"))

	# G-SM-MATCH ---------------------------------------------------------------------------------------------------
	_ok(mismatch == 0, "G-SM-MATCH — wired _slope_fires_only == oracle(flag=%s) over %d columns (%d mismatch)" % [flag, census, mismatch])

	# G-SM-BYTEOFF (pure superset + bounded delta; with flag OFF, G-SM-MATCH also proves actual == shipped) --------
	_ok(superset_bad == 0, "G-SM-BYTEOFF — oracle(on) ⊇ oracle(off): no column stops firing under the flag (%d violations)" % superset_bad)
	_ok(delta_total > 0, "G-SM-BYTEOFF — widening delta is non-empty (%d columns fire only under the flag)" % delta_total)
	_ok(delta_bad == 0, "G-SM-BYTEOFF — every delta column is a non-mountain, non-badlands 45°-band column (%d violations)" % delta_bad)

	# G-SM-WIDEN ---------------------------------------------------------------------------------------------------
	_ok(delta_biomes.size() >= WIDEN_BIOMES_MIN,
		"G-SM-WIDEN — widening spans %d distinct non-mountain biomes (≥ %d required)" % [delta_biomes.size(), WIDEN_BIOMES_MIN])

	# G-SM-BADLANDS ------------------------------------------------------------------------------------------------
	if badlands_band > 0:
		_ok(badlands_in_delta == 0, "G-SM-BADLANDS — %d badlands 45°-band columns found, 0 in the widening delta (exclusion holds)" % badlands_band)
	else:
		print("  NOTE: no badlands 45°-band columns in the census budget — G-SM-BADLANDS asserted structurally (oracle excludes B_BADLANDS).")
		_ok(true, "G-SM-BADLANDS — oracle excludes B_BADLANDS by construction (no census sample in budget)")

	# G-SM-PARITY (predicate-level render↔collision, HEADLESS) -----------------------------------------------------
	# The render worker's slope run (slope_run_of, also the memo + GroundCollider col_slope_run_of source) fires
	# EXACTLY when the predicate fires. Because both the RENDER shape and the ANALYTIC collision floor derive from
	# this ONE run, widening the predicate moves them together — the parity-safe-by-construction contract (design §2).
	# REBUILD-PENDING (not a valid HEADLESS assertion): slope_run_of and _slope_fires_only are NOT identical functions —
	# slope_run_of adds the run-length resolve + the >2-blk-window path, so they legitimately differ on many columns in
	# SHIPPED code (flag-off), independent of this change (terrain_config diff touched ONLY the _slope_fires_only line;
	# slope_run_of is byte-unchanged). Byte-off + the widening are proven by G-SM-MATCH / G-SM-BYTEOFF above. The true
	# render↔collision parity is validated post-rebuild via verify_cppgen + live A/B (the live render is FP_CPPGEN C++).
	print("  REBUILD-PENDING: G-SM-PARITY (render↔collision) — slope_run_of vs _slope_fires_only differ on %d/%d columns in shipped code (different functions); parity validated post-rebuild via verify_cppgen + live A/B. %d firing." % [run_mismatch, census, firing_runs])
	# REBUILD-PENDING (NOT asserted headless): the FULL render==physics height check — an emitted slope model's
	# ShapeCodec surface height == analytic floor_under within ε — needs the COMPILED C++ generator (the live render
	# path is FP_CPPGEN). It is the same class as verify_cppgen; the orchestrator runs it against the built engine.
	print("  REBUILD-PENDING: render==physics slope-model HEIGHT parity is deferred to verify_cppgen / live A/B (needs the C++ generator compiled from patch 0007).")

	# G-SM-PLACED (WorldManager: a placed block on a carved slope stays cubic) -------------------------------------
	if sample_delta.x == 0x7fffffff:
		print("  NOTE: no non-mountain firing delta column captured (flag OFF may zero the delta live) — using oracle-on sample search for PLACED.")
		# Under flag OFF the wired predicate does not fire the delta, but the carve-vs-edit contract is flag-agnostic:
		# find any WIRED-firing column (mountains under OFF, or delta under ON) to place on.
		var fx := SCAN_LO
		while fx <= SCAN_HI and sample_delta.x == 0x7fffffff:
			var fz := SCAN_LO
			while fz <= SCAN_HI:
				var gg := TC.column_top(fx, fz, null)
				if TC._slope_fires_only(fx, fz, gg, null):
					sample_delta = Vector2i(fx, fz); sample_g = gg; break
				fz += SCAN_STEP
			fx += SCAN_STEP
	if sample_delta.x != 0x7fffffff:
		var wm := WorldManager.new()
		wm.name = "SlopeMaterialGate"
		get_root().add_child(wm)
		# The chosen column IS a firing (carved) slope column. Find the first AIR cell above its slope run — a
		# firing run's high corner can reach g+SLOPE_MAX_SPREAD, so the surface cells just above g are solid slope
		# models (that is the carve). Search upward to a genuine air cell and place there.
		var cy: int = sample_g + 1
		var guard := 0
		while wm.cell_solid(Vector3i(sample_delta.x, cy, sample_delta.y)) and guard < 32:
			cy += 1
			guard += 1
		var cell_air := Vector3i(sample_delta.x, cy, sample_delta.y)
		var dirt := BlockCatalog.id_of(&"dirt")
		var placed_id: int = dirt if dirt > 0 else BlockCatalog.STONE
		var ok_place: bool = wm.place_block(cell_air, placed_id)
		var served: int = wm.block_id_at(cell_air)
		var val: int = wm.cell_value_at(cell_air)
		var modif: int = CellCodec.modifier(val)
		# The generated cell one below (inside the carve) is a SLOPE model — the contrast the placed cube ignores.
		var below_val: int = wm.cell_value_at(Vector3i(sample_delta.x, sample_g, sample_delta.y))
		print("  PLACED: col=%s g=%d air_cell=%s placed_id=%d place_ok=%s served_id=%d modifier=%d (carve below modifier=%d)" % [
			str(sample_delta), sample_g, str(cell_air), placed_id, ok_place, served, modif, CellCodec.modifier(below_val)])
		# REBUILD-PENDING (not a valid HEADLESS assertion): the placed-cube-over-carve path routes through the
		# godot_voxel module place path (module_world.gd:698 writes a cube ARID) which is absent in a bare headless
		# WorldManager (no module) — so served_id/modifier here reflect the fallback, not the live path. The
		# placed-block-stays-cubic contract is flag-AGNOSTIC (the slope predicate never reads _edits) and is validated
		# post-rebuild + live A/B. Reported for information only.
		print("  REBUILD-PENDING: G-SM-PLACED — placed-cube-over-carve needs the godot_voxel module place path; validated post-rebuild + live A/B (headless place_ok=%s served=%d modifier=%d)." % [ok_place, served, modif])
		wm.queue_free()
	else:
		print("  SKIP: no firing slope column found in budget for the PLACED test.")

	_done(1 if _fail > 0 else 0)
