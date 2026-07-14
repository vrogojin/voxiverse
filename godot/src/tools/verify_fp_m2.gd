extends SceneTree
## COSMOS FP-M2a gate (docs/COSMOS-FP-M2-DESIGN.md §12, §13) — the off-terrain LOD build pipeline + LOD0
## byte-identity. Runs headless with FACETED + FP_M2_LOD sed-toggled true (like verify_fp_r0's FP_R0). Proves:
##   G-M2-ID     LOD0 byte-identity — the probe generator (stride unlocked) equals the SHIPPED generator
##               voxel-for-voxel over ≥3 34³ boxes incl. a seam-STRADDLING one (where junction_modify does
##               real masking work) and a taller surface+canopy box. The stride wiring never perturbs ℓ0.
##   G-M2-BUILD  the off-thread pipeline (FacetLodBuilder) produces valid non-empty ArrayMeshes at ℓ∈{1,2,3}
##               for ≥3 facets (incl. one flanking a cube-corner singular vertex); every tile is built on the
##               BUILDER thread (thread-id != main); the active terrain's voxel-pool statistics are untouched
##               (pure-LOD build never routes through godot_voxel); one whole-facet enqueue_facet tiles a
##               multi-tile coherent facet. Per-tile time/tris/bytes recorded (the §1.3 table re-measured).
##   LOD_FLOOR_Y large-sample min-visible-surface bound (§4.2, beside MAX_SURFACE_Y's max bound).
##   thread-pool boot record (§4.3 / risk #1): worker-pool sizing printed; the +1 builder Thread started clean.
##
## RUN:
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_M2_LOD := false/const FP_M2_LOD := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fp_m2.gd 2> stderr.log
## then REVERT the sed. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FLB := preload("res://src/world/facet_lod_builder.gd")

const _BYTES_PER_VERT := 64
const _BYTES_PER_INDEX := 4

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_fp_m2 (FP-M2a: off-thread LOD build pipeline + LOD0 byte-identity) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FP_M2_LOD:
		print("  FAIL: CubeSphere.FP_M2_LOD is false — sed-toggle FP_M2_LOD = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent (ClassDB has no VoxelTerrain) — FP-M2a needs the module binary.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return

	TerrainConfig.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	var nf := FA.facet_count()
	print("  atlas: %d facets (k=%d, R=%d), active(spawn)=%d, near_render_radius=%d" % [
		nf, FA.K, int(FA.R_BLOCKS), active, TerrainConfig.near_render_radius()])

	# thread-pool boot record (§4.3 / risk #1). Headless can't read the WASM "thread pool is exhausted" boot
	# string (that is a live-web check when the flag is exercised on web); here we RECORD the sizing so the
	# builder's +1 script Thread accounting (voxel ≤10 + WTP 2 + audio 1 + voxel-IO 1 + builder 1 = 15 ≤ 16)
	# is visible, and assert the builder thread starts clean below (is_running).
	print("  [thread-pool] OS.get_processor_count()=%d ; the builder adds ONE persistent script Thread (NOT a "
		% OS.get_processor_count()
		+ "voxel worker). Live-web 'thread pool is exhausted' boot-log assert is deferred to the flag being "
		+ "exercised on web (M2a ships dead code, no deploy).")

	# Build the active-facet module world (baked library + shipped active generator).
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	var ok_setup: bool = bool(mod.call("setup"))
	_ok(ok_setup, "setup: module_world built the active-facet terrain + baked library")
	if not ok_setup:
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail]); quit(1); return

	# pick an edge-neighbour (shared ridge) and a cube-corner facet (singular-vertex-flanking).
	var neighbour := -1
	for slot in range(4):
		var nb: int = FA.seam_neighbour(active, slot)
		if nb >= 0 and nb != active:
			neighbour = nb; break
	_ok(neighbour >= 0, "setup: found an edge-neighbour facet of the active facet (facet %d)" % neighbour)
	var corner_fid := 0                      # face 0, (i,j)=(0,0) — a cube-corner facet (sharper seam orientation)
	print("  facets under test: active=%d, neighbour=%d, corner(singular-flank)=%d" % [active, neighbour, corner_fid])

	_gate_lod0_identity(mod, active)
	_gate_floor_y_bound(nf)
	await _gate_build(mod, active, neighbour, corner_fid)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-M2-ID: LOD0 byte-identity ----------
func _gate_lod0_identity(mod: Node3D, active: int) -> void:
	print("  --- G-M2-ID: LOD0 byte-identity (probe-stride gen == shipped gen) ---")
	var shipped: Object = mod.call("lod_shipped_generator")
	var probe: Object = mod.call("lod_probe_generator", active)
	_ok(shipped != null and probe != null, "G-M2-ID: shipped + probe generators available under FP_M2_LOD")
	if shipped == null or probe == null:
		return
	var cc: Vector2i = FA.centre_cell(active)
	var g := int(TerrainConfig.facet_profile(active, cc.x, cc.y).x)

	# box 1: centred on the surface (interior full cells)
	var c1 := Vector3i(cc.x - 16, g - 16, cc.y - 16)
	var s1 := _solid_count(probe, c1, 34)
	_ok(s1 > 0, "G-M2-ID box1(centre): non-trivial content (%d/%d solid)" % [s1, 34 * 34 * 34])
	_ok(_lod0_identical(shipped, probe, c1, 34), "G-M2-ID box1(centre): probe==shipped over 34³ (interior)")

	# box 2: seam-STRADDLING — halfway from centre to the far domain corner so the 34³ box crosses a ridge
	# (junction_modify masks part to AIR + keeps part solid → the meaningful lod0 test).
	var dmax: Vector2i = FA.dom_max(active)
	var mid := Vector2i((cc.x + dmax.x) / 2, (cc.y + dmax.y) / 2)
	var c2 := Vector3i(mid.x - 16, g - 16, mid.y - 16)
	var s2 := _solid_count(probe, c2, 34)
	var straddles := s2 > 0 and s2 < 34 * 34 * 34    # some solid AND some masked → a genuine straddle
	_ok(straddles, "G-M2-ID box2(seam-straddle): box crosses a ridge (%d/%d solid — mixed)" % [s2, 34 * 34 * 34])
	_ok(_lod0_identical(shipped, probe, c2, 34), "G-M2-ID box2(seam-straddle): probe==shipped over 34³ (masking path)")

	# box 3: taller surface+canopy span (above-surface tree/snow content included)
	var c3 := Vector3i(cc.x - 16, g - 4, cc.y - 16)
	_ok(_lod0_identical(shipped, probe, c3, 34), "G-M2-ID box3(surface+canopy): probe==shipped over 34³ (above-surface)")

# ---------- LOD_FLOOR_Y bound ----------
func _gate_floor_y_bound(nf: int) -> void:
	print("  --- LOD_FLOOR_Y bound (min visible surface ≥ %d) ---" % FLB.LOD_FLOOR_Y)
	var min_g := 0x7fffffff
	var min_fid := -1
	var min_cell := Vector2i.ZERO
	var step := 16                                   # coarse sweep of every facet's domain
	for fid in range(nf):
		var dmin: Vector2i = FA.dom_min(fid)
		var dmax: Vector2i = FA.dom_max(fid)
		var z := dmin.y
		while z <= dmax.y:
			var x := dmin.x
			while x <= dmax.x:
				var g := int(TerrainConfig.facet_profile(fid, x, z).x)
				if g < min_g:
					min_g = g; min_fid = fid; min_cell = Vector2i(x, z)
				x += step
			z += step
	print("  min sampled surface g = %d (facet %d, cell (%d,%d)); LOD_FLOOR_Y = %d" % [
		min_g, min_fid, min_cell.x, min_cell.y, FLB.LOD_FLOOR_Y])
	_ok(min_g > FLB.LOD_FLOOR_Y, "LOD_FLOOR_Y: min visible surface (%d) is strictly above the floor (%d) — the "
		% [min_g, FLB.LOD_FLOOR_Y] + "bottom pad row is always solid → no under-planet holes")

# ---------- G-M2-BUILD: off-thread pipeline ----------
func _gate_build(mod: Node3D, active: int, neighbour: int, corner_fid: int) -> void:
	print("  --- G-M2-BUILD: off-thread LOD build pipeline (ℓ∈{1,2,3}) ---")
	var builder = FLB.new()
	var ok := bool(builder.setup(mod))
	_ok(ok, "G-M2-BUILD: FacetLodBuilder.setup() wired the library + started the builder thread")
	_ok(builder.is_running(), "G-M2-BUILD: builder thread is running (the +1 pthread accounting slot)")
	if not ok:
		return

	var main_id := OS.get_main_thread_id()
	var term: Node3D = mod.call("lod_active_terrain")
	var stat_before := _stat_sum(term)

	# 3 facets × 3 tiers, centred surface-straddling single tiles (fast + guaranteed non-empty).
	var facets := [active, neighbour, corner_fid]
	var expected := 0
	for f in facets:
		var cc: Vector2i = FA.centre_cell(f)
		var g := int(TerrainConfig.facet_profile(f, cc.x, cc.y).x)
		for lod in [1, 2, 3]:
			var s: int = 1 << int(lod)
			var region: int = FLB.TILE_MAX * s
			var cx: int = cc.x - region / 2
			var cy: int = g - region / 2
			var cz: int = cc.y - region / 2
			if builder.enqueue_tile(f, int(lod), cx, cy, cz, FLB.TILE_MAX):
				expected += 1
	_ok(expected == 9, "G-M2-BUILD: enqueued 9 centred tiles (3 facets × ℓ∈{1,2,3})")

	var results: Array = await _drain(builder, expected, 180000)
	_ok(results.size() == expected, "G-M2-BUILD: builder produced all %d tiles (%d drained)" % [expected, results.size()])

	# per-tile asserts: non-empty, built off-main, within a sanity tri bound; group by (facet,ℓ) for the record.
	var all_off_main := true
	var all_nonempty := true
	var per := {}                                    # "fid:lod" -> {tris,bytes,gen_ok}
	for r in results:
		var tid: int = r["thread_id"]
		if tid == main_id: all_off_main = false
		if int(r["tris"]) <= 0: all_nonempty = false
		var key := "%d:%d" % [int(r["fid"]), int(r["lod"])]
		per[key] = {"tris": int(r["tris"]), "bytes": int(r["bytes"]), "mesh": r["mesh"]}
	for f in facets:
		for lod in [1, 2, 3]:
			var key := "%d:%d" % [f, lod]
			if per.has(key):
				var e: Dictionary = per[key]
				print("    facet %d ℓ=%d | tris=%6d bytes=%8d (%.1f KB) | mesh=%s" % [
					f, lod, int(e["tris"]), int(e["bytes"]), int(e["bytes"]) / 1024.0,
					"ArrayMesh" if e["mesh"] != null else "NULL"])
	_ok(all_off_main, "G-M2-BUILD: EVERY tile built on the BUILDER thread (thread-id != main %d)" % main_id)
	_ok(all_nonempty, "G-M2-BUILD: EVERY (facet,ℓ) tile produced a non-empty mesh (tris > 0)")

	# sanity tri bound: one 34³ blocky mesh cannot exceed ~ its cell count × 12 tris (grossly loose upper fence).
	var max_tris := 0
	for r in results:
		max_tris = maxi(max_tris, int(r["tris"]))
	var tri_bound := (FLB.TILE_MAX + 2) * (FLB.TILE_MAX + 2) * (FLB.TILE_MAX + 2) * 12
	_ok(max_tris > 0 and max_tris < tri_bound, "G-M2-BUILD: max tile tris %d within the sanity bound %d" % [max_tris, tri_bound])

	# voxel-pool statistics untouched — the builder never routes through godot_voxel.
	var stat_after := _stat_sum(term)
	print("    active-terrain statistics sum: before=%d after=%d (delta %d)" % [stat_before, stat_after, stat_after - stat_before])
	_ok(stat_after == stat_before, "G-M2-BUILD: active-terrain voxel-pool statistics UNCHANGED by the pure-LOD build (vox_gen untouched)")

	# whole-facet tiling: enqueue_facet tiles a multi-tile coherent facet (cheap ℓ2).
	var n_before := builder.build_count()
	var tiles := int(builder.enqueue_facet(active, 2))
	_ok(tiles > 1, "G-M2-BUILD: enqueue_facet(active, ℓ2) tiled the slab into %d tiles (multi-tile)" % tiles)
	var facet_results: Array = await _drain(builder, tiles, 180000)
	var facet_tris := 0
	var facet_off_main := true
	for r in facet_results:
		facet_tris += int(r["tris"])
		if int(r["thread_id"]) == main_id: facet_off_main = false
	_ok(facet_results.size() == tiles, "G-M2-BUILD: whole-facet build drained all %d tiles (%d)" % [tiles, facet_results.size()])
	_ok(facet_tris > 0, "G-M2-BUILD: whole-facet ℓ2 build produced solid geometry (%d tris total)" % facet_tris)
	_ok(facet_off_main, "G-M2-BUILD: whole-facet tiles all built off-main")
	_ok(builder.build_count() == n_before + facet_results.size(), "G-M2-BUILD: build_count ledger consistent (%d → %d)" % [n_before, builder.build_count()])

	builder.shutdown()
	_ok(not builder.is_running(), "G-M2-BUILD: builder thread joined cleanly on shutdown")

# ---------- helpers ----------
func _drain(builder, expected: int, timeout_ms: int) -> Array:
	var out := []
	var t0 := Time.get_ticks_msec()
	while out.size() < expected and (Time.get_ticks_msec() - t0) < timeout_ms:
		var batch: Array = builder.drain_done()
		for r in batch:
			out.append(r)
		await process_frame
	# final sweep
	for r in builder.drain_done():
		out.append(r)
	return out

func _stat_sum(term: Node3D) -> int:
	if term == null or not term.has_method("get_statistics"):
		return 0
	var st: Dictionary = term.call("get_statistics")
	var sum := 0
	for k in st.keys():
		var v = st[k]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			sum += int(v)
	return sum

func _solid_count(gen: Object, corner: Vector3i, n: int) -> int:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", n, n, n)
	buf.call("set_channel_depth", 0, 1)
	gen.call("generate_block", buf, Vector3(corner.x, corner.y, corner.z), 0)
	var solid := 0
	for z in range(n):
		for y in range(n):
			for x in range(n):
				if int(buf.call("get_voxel", x, y, z, 0)) != 0:
					solid += 1
	return solid

func _lod0_identical(a: Object, b: Object, corner: Vector3i, n: int) -> bool:
	var ba: Object = ClassDB.instantiate("VoxelBuffer")
	ba.call("create", n, n, n); ba.call("set_channel_depth", 0, 1)
	a.call("generate_block", ba, Vector3(corner.x, corner.y, corner.z), 0)
	var bb: Object = ClassDB.instantiate("VoxelBuffer")
	bb.call("create", n, n, n); bb.call("set_channel_depth", 0, 1)
	b.call("generate_block", bb, Vector3(corner.x, corner.y, corner.z), 0)
	for z in range(n):
		for y in range(n):
			for x in range(n):
				if int(ba.call("get_voxel", x, y, z, 0)) != int(bb.call("get_voxel", x, y, z, 0)):
					return false
	return true
