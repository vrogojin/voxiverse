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
const FLM := preload("res://src/world/facet_lod_mesher.gd")   # preload (not the global class_name) — headless --script parse scope
const SLC := preload("res://src/world/stream_load_controller.gd")
const WM := preload("res://src/world/world_manager.gd")       # M2d: the Z1-hybrid policy statics (z1_live_targets/promote_admit)
const FFR := preload("res://src/world/facet_far_ring.gd")    # L1: the far-ring node (G-L1-FARRING mesh-equivalence gate)

const _BYTES_PER_VERT := 64
const _BYTES_PER_INDEX := 4

## Deterministic synthetic load source for G-M2-CTRL (§6.5.7): the injected input the controller reads instead of the
## live Performance/VoxelEngine adapter. `frame_ms`/`backlog` are set by the gate to script a square wave — no wall
## clock, no machine-speed dependence, so the whole credit trace is bit-reproducible.
class _SquareWaveSource extends RefCounted:
	var frame_ms := 6.0
	var backlog := 0
	func poll() -> Dictionary:
		return {"frame_ms": frame_ms, "backlog": backlog}

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
	# This gate tests STANDALONE FacetLodMesher instances; the module's OWN mesher (created by setup under
	# FP_M1_POOL) is not the subject. If left ticking through the gate's frame-stepping it floods its builder
	# Thread with ℓ1 ring builds, and the end-of-gate teardown then blocks joining that Thread on an in-flight
	# tile (hang under the gate's own worker-thread load). Shut it down UP FRONT — its builder is still idle
	# here (no frame has ticked it yet), so this is instant — leaving it inert for the run. (module_world's
	# shipped _exit_tree teardown is unchanged and separately correct.)
	if mod.has_method("lod_mesher"):
		var _mm = mod.call("lod_mesher")
		if _mm != null:
			_mm.call("shutdown")
			print("  [setup] module-owned FacetLodMesher shut down (inert) — gate uses standalone instances")

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
	# --- FP-M2b gates: FacetLodMesher class + caps/LRU + ridge apron ---
	await _gate_frame(mod, active, neighbour)
	await _gate_caps(mod, active)
	_gate_cap_real_spend(mod, active)               # steelman C1: the hard cap binds on REAL bytes at spend
	await _gate_seam(mod, active)
	# --- FP-M2c gates: SSE selector + facet_of_dir + the load controller ---
	_gate_selector()
	_gate_dir(nf)
	_gate_ctrl(mod, active)
	_gate_ctrl_rawdt()                              # steelman W2: raw-dt sustain clamp
	_gate_ctrl_adaptive()                           # COSMOS-PERF L5: the adaptive floor-relative overload setpoint
	_gate_farring_equiv(active)                     # COSMOS-PERF L1: far-ring fast-rebuild mesh equivalence
	# --- FP-M2d gates: Z1-hybrid pool policy + promote/demote choreography ---
	_gate_policy()
	# --- CONTROLLER-FIX gate: the relief floor + geometric commit un-starve the controller (credit was pinned 0) ---
	await _gate_starve(mod, active, neighbour, corner_fid)
	await _gate_xpd(mod, active, neighbour)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	# Deterministic process teardown so headless EXITS (not just prints the tally). Under FP_M1_POOL the module
	# world's OWN FacetLodMesher owns a builder Thread; if `mod` is never freed, quit() does not run its
	# _exit_tree → that Thread stays parked in Semaphore.wait() forever, and a live GDScript Thread keeps the
	# process alive (hang-at-quit). Freeing `mod` runs module_world._exit_tree → _lod_mesher.shutdown() →
	# builder.shutdown() → the Thread wakes on _running=false and joins. (The sub-gate meshers already join their
	# own threads via shutdown() on every path.)
	if is_instance_valid(mod):
		if mod.get_parent() != null:
			mod.get_parent().remove_child(mod)
		mod.free()
	print("[verify_fp_m2] teardown complete — exiting %d" % (1 if _fail > 0 else 0))
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

	# The builder never routes through godot_voxel: a pure-LOD build must NOT push generation/meshing tasks onto the
	# active terrain's voxel worker pool. If it did, vox_gen/vox_mesh would jump by the built tile count (dozens+).
	# A tiny drift (a background per-frame VoxelTerrain bookkeeping counter ticking over the drain's frames — delta
	# ≤ a few, unrelated to the pool) is NOT pool routing, so tolerate that noise while still catching a real burst.
	var stat_after := _stat_sum(term)
	var stat_delta: int = absi(stat_after - stat_before)
	print("    active-terrain statistics sum: before=%d after=%d (delta %d)" % [stat_before, stat_after, stat_after - stat_before])
	_ok(stat_delta <= 8, "G-M2-BUILD: active-terrain voxel-pool statistics undisturbed by the pure-LOD build (Δ=%d ≤ 8 — no vox_gen burst)" % stat_delta)

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

# ---------- G-M2-FRAME: LOD placement round-trip (§8) ----------
func _gate_frame(mod: Node3D, active: int, neighbour: int) -> void:
	print("  --- G-M2-FRAME: LOD placement round-trip (orientation-correct under 2 active facets) ---")
	var mesher = FLM.new()
	get_root().add_child(mesher)
	var ok := bool(mesher.setup(mod))
	_ok(ok, "G-M2-FRAME: FacetLodMesher.setup() wired the builder + apron material")
	if not ok:
		mesher.free(); return
	var f := neighbour
	mesher.request(f, 3)                                  # ℓ3 = 1 tile per facet — fast + guaranteed non-empty
	var applied: bool = await _drive_mesher(mesher, f, 60000)
	_ok(applied, "G-M2-FRAME: facet %d LOD mesh built+applied (covered)" % f)
	if not applied:
		mesher.shutdown(); mesher.free(); return
	var node: Node3D = mesher.get_node_or_null("LodFacet_%d" % f)
	_ok(node != null, "G-M2-FRAME: LodFacet_%d node present under the mesher" % f)
	var tiles: Array = mesher.facet_tile_instances(f)
	_ok(tiles.size() > 0, "G-M2-FRAME: applied facet holds %d tile MeshInstance(s)" % tiles.size())
	if node == null or tiles.is_empty():
		mesher.shutdown(); mesher.free(); return
	var tf := FA.facet_transform(f)
	_ok(node.transform.is_equal_approx(tf), "G-M2-FRAME: LodFacet node transform == facet_transform(%d)" % f)
	# every sampled megablock vertex lands where lattice_to_world64 places its lattice cell (the live-block position).
	var worst := 0.0
	var lat0 := Vector3.ZERO
	var wref0 := Vector3.ZERO
	var got_sample := false
	for mi in tiles:
		var arr: Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)
		var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var lim: int = mini(pv.size(), 200)
		for i in range(lim):
			var v: Vector3 = pv[i]
			var lat: Vector3 = (mi as MeshInstance3D).transform * v          # tile + s·v (facet lattice coords)
			var wr: Array = FA.lattice_to_world64(f, lat.x, lat.y, lat.z)
			var wref := Vector3(float(wr[0]), float(wr[1]), float(wr[2]))
			worst = maxf(worst, (tf * lat - wref).length())
			if not got_sample:
				lat0 = lat; wref0 = wref; got_sample = true
	_ok(worst < 1.0e-1, "G-M2-FRAME: max vertex placement error %.4f blocks < 0.1 (facet_transform == lattice_to_world64)" % worst)
	# two-active invariance: the absolute planet point recovered from BOTH active facets' render frames is identical.
	var proot := Node3D.new()
	get_root().add_child(proot)
	get_root().remove_child(mesher)
	proot.add_child(mesher)
	var abs_pts: Array = []
	for a in [active, f]:
		proot.transform = FA.facet_transform(a).affine_inverse()
		var vglobal: Vector3 = (proot.transform * node.transform) * lat0     # render-frame position under active a
		abs_pts.append(FA.facet_transform(a) * vglobal)                       # re-express to absolute
	_ok(abs_pts[0].is_equal_approx(abs_pts[1]) and (abs_pts[0] - wref0).length() < 1.0e-1,
		"G-M2-FRAME: absolute vertex pos invariant across 2 active facets (Δ=%.4f) and == lattice_to_world64" % (abs_pts[0] - abs_pts[1]).length())
	mesher.shutdown()
	proot.queue_free()

# ---------- G-M2-CAPS: NEVER-OOM caps + LRU (§6.2) ----------
func _gate_caps(mod: Node3D, active: int) -> void:
	print("  --- G-M2-CAPS: hard caps + LRU (a request storm never exceeds the ceilings) ---")
	var cap_bytes := FLM.LOD_MAX_BYTES_MB * 1024 * 1024
	# ---- storm: 80 distinct facets at ℓ1 (the finest/heaviest tier) → byte + facet caps must both bind ----
	var m = FLM.new()
	get_root().add_child(m)
	if not bool(m.setup(mod)):
		_ok(false, "G-M2-CAPS: mesher setup"); m.free(); return
	var storm: Array = []
	var f := 0
	while storm.size() < 80 and f < FA.facet_count():
		if f != active:
			storm.append(f)
		f += 1
	for x in storm:
		m.request(x, 1, true)                            # dry: admission-only (no real build) — exercises caps synchronously
	var st: Dictionary = m.stats()
	var tracked := 0
	for x in storm:
		if m.is_covered(x) or m.is_building(x):
			tracked += 1
	_ok(tracked <= FLM.LOD_MAX_FACETS, "G-M2-CAPS: tracked facets %d ≤ LOD_MAX_FACETS %d" % [tracked, FLM.LOD_MAX_FACETS])
	_ok(int(st["tris"]) <= FLM.LOD_MAX_TRIS, "G-M2-CAPS: ledger tris %d ≤ LOD_MAX_TRIS %d" % [int(st["tris"]), FLM.LOD_MAX_TRIS])
	_ok(int(st["bytes"]) <= cap_bytes, "G-M2-CAPS: ledger bytes %d ≤ cap %d (%d MB)" % [int(st["bytes"]), cap_bytes, FLM.LOD_MAX_BYTES_MB])
	_ok(tracked < storm.size(), "G-M2-CAPS: storm exceeded caps → %d of %d requests degraded/denied to quad (no hole)" % [storm.size() - tracked, storm.size()])
	# no hole: a denied facet is NOT tracked → covered_fids() excludes it → the far ring keeps drawing its quad.
	var denied_untracked := true
	for x in storm:
		if not (m.is_covered(x) or m.is_building(x)):
			if m.covered_fids().has(x):
				denied_untracked = false
	_ok(denied_untracked, "G-M2-CAPS: every denied facet is absent from covered_fids() (quad stays — no hole)")
	m.shutdown(); m.free()
	# ---- LRU: never evict a WANTED facet to fund another WANTED one; evict non-wanted to fund a newcomer ----
	var m2 = FLM.new()
	get_root().add_child(m2)
	if not bool(m2.setup(mod)):
		_ok(false, "G-M2-CAPS: LRU mesher setup"); m2.shutdown(); m2.free(); return
	var picked: Array = []
	f = 0
	while picked.size() < FLM.LOD_MAX_FACETS and f < FA.facet_count():
		if f != active:
			picked.append(f)
		f += 1
	for x in picked:
		m2.request(x, 3, true)                            # dry → the FACET cap (64) binds, not bytes/tris
	var filled := 0
	for x in picked:
		if m2.is_covered(x) or m2.is_building(x):
			filled += 1
	_ok(filled == FLM.LOD_MAX_FACETS, "G-M2-CAPS: filled to the facet cap with wanted facets (%d)" % filled)
	var extra := f                                        # the next non-active facet id (all picked are wanted)
	m2.request(extra, 3, true)
	_ok(not (m2.is_covered(extra) or m2.is_building(extra)), "G-M2-CAPS: newcomer DENIED while every tracked facet is wanted (no wanted evicted)")
	var still := 0
	for x in picked:
		if m2.is_covered(x) or m2.is_building(x):
			still += 1
	_ok(still == FLM.LOD_MAX_FACETS, "G-M2-CAPS: all %d wanted facets retained (LRU never evicts wanted-for-wanted)" % still)
	m2._want.clear()                                     # white-box: the crossing made them non-wanted
	m2.request(extra, 3, true)
	_ok(m2.is_covered(extra) or m2.is_building(extra), "G-M2-CAPS: after wants cleared, LRU evicted a NON-wanted facet to admit the newcomer")
	var final_tracked := 0
	for x in (picked + [extra]):
		if m2.is_covered(x) or m2.is_building(x):
			final_tracked += 1
	_ok(final_tracked <= FLM.LOD_MAX_FACETS, "G-M2-CAPS: still ≤ facet cap after the LRU eviction (%d)" % final_tracked)
	m2.shutdown(); m2.free()

# ---------- G-M2-CAPS(C1): the HARD cap binds on REAL bytes at SPEND (steelman C1) ----------
# Admission uses an UPPER-FENCE estimate; a rugged facet / an apron can still overshoot the remaining headroom when the
# real mesh lands. _enforce_caps_after_spend (called at every swap + apron apply) must then evict NON-wanted LRU until
# the ACTUAL ledger is back under the caps — the cap can never be exceeded on materialized memory. White-box (the
# estimate cannot be forced below the real mesh through the pipeline, so we drive the reconcile with an injected
# over-spend and assert the invariant the swap-site relies on).
func _gate_cap_real_spend(mod: Node3D, active: int) -> void:
	print("  --- G-M2-CAPS(C1): the hard cap binds on REAL bytes at spend (over-spend evicts, never exceeds) ---")
	var m = FLM.new()
	get_root().add_child(m)
	if not bool(m.setup(mod)):
		_ok(false, "G-M2-CAPS(C1): mesher setup"); m.free(); return
	# populate a handful of REAL applied facets (their real bytes/tris land in the ledger + _cache).
	var picked: Array = []
	var f := 0
	while picked.size() < 4 and f < FA.facet_count():
		if f != active:
			picked.append(f)
		f += 1
	var all_up := true
	for x in picked:
		m.request(x, 3)
		if not await _drive_mesher(m, x, 60000):
			all_up = false
	_ok(all_up, "G-M2-CAPS(C1): %d real facets applied (ledger holds their measured bytes)" % picked.size())
	if not all_up:
		m.shutdown(); m.free(); return
	# keep ONE wanted; the rest become non-wanted (evictable). Then inject an over-spend (as if an applied mesh / apron
	# overshot its fence) that pushes BOTH ledgers just past the caps.
	var keep: int = picked[0]
	m._want.clear()
	m._want[keep] = 3
	# steelman re-review (67d6bc0 gap): a PROMOTING facet's held cover must be SPARED by LRU eviction even under cap
	# pressure (else a crossing opens a see-through hole over un-meshed live terrain). Mark picked[1] promoting AND make
	# it the OLDEST last_want_ms so it is the natural LRU victim — the _evict_one_non_wanted guard must protect it.
	# Set the promoting flag DIRECTLY (whitebox, like the ledger injection below): on_promote() would call
	# notify_pool_changed() and re-derive _want, wiping the keep we just set.
	var promo: int = picked[1]
	m._promoting[promo] = true
	m._cache[promo]["last_want_ms"] = 0
	var cap_bytes := FLM.LOD_MAX_BYTES_MB * 1024 * 1024
	m._ledger_bytes = cap_bytes + 1
	m._ledger_tris = FLM.LOD_MAX_TRIS + 1
	var covered_before := int(m.stats()["facets"])
	m._enforce_caps_after_spend(keep)               # the exact call the swap / apron-apply sites make (C1)
	var st: Dictionary = m.stats()
	_ok(int(st["bytes"]) <= cap_bytes and int(st["tris"]) <= FLM.LOD_MAX_TRIS,
		"G-M2-CAPS(C1): after an over-spend the reconcile drives the ledger BACK under the caps (bytes %d ≤ %d, tris %d ≤ %d)" % [
			int(st["bytes"]), cap_bytes, int(st["tris"]), FLM.LOD_MAX_TRIS])
	_ok(m.is_covered(keep), "G-M2-CAPS(C1): the WANTED facet was retained (a NON-wanted LRU facet was evicted first)")
	_ok(int(st["facets"]) < covered_before, "G-M2-CAPS(C1): a non-wanted facet was evicted to fund the over-spend (%d → %d)" % [covered_before, int(st["facets"])])
	_ok(m.is_covered(promo), "G-M2-CAPS(C1): the PROMOTING facet's held cover was SPARED by LRU eviction under cap pressure (no crossing hole) though it was the oldest non-wanted facet")
	m.shutdown(); m.free()

# ---------- G-M2-SEAM: erosion zero-protrusion + the ridge apron (§7.5) ----------
func _gate_seam(mod: Node3D, active: int) -> void:
	print("  --- G-M2-SEAM: erosion zero-protrusion + LOD↔LOD ridge apron (no hairline) ---")
	var m = FLM.new()
	get_root().add_child(m)
	if not bool(m.setup(mod)):
		_ok(false, "G-M2-SEAM: mesher setup"); m.free(); return
	# pick an adjacent LOD↔LOD pair (both non-active): A = a neighbour of active; B = a neighbour of A that isn't active.
	var A := -1
	for slot in range(4):
		var nb: int = FA.seam_neighbour(active, slot)
		if nb >= 0 and nb != active:
			A = nb; break
	var B := -1
	var slotAB := -1
	if A >= 0:
		for slot in range(4):
			var nb: int = FA.seam_neighbour(A, slot)
			if nb >= 0 and nb != active and nb != A:
				B = nb; slotAB = slot; break
	_ok(A >= 0 and B >= 0, "G-M2-SEAM: found an adjacent non-active LOD↔LOD pair (A=%d, B=%d)" % [A, B])
	if A < 0 or B < 0:
		m.shutdown(); m.free(); return
	var owner: int = mini(A, B)
	var nbr: int = maxi(A, B)
	# owner's slot facing the neighbour
	var oslot := -1
	for slot in range(4):
		if FA.seam_neighbour(owner, slot) == nbr:
			oslot = slot; break
	_ok(oslot >= 0, "G-M2-SEAM: owner facet %d has slot %d facing neighbour %d" % [owner, oslot, nbr])
	if oslot < 0:
		m.shutdown(); m.free(); return
	# build both sides at MIXED tiers (ℓ2 vs ℓ3 → s_max=8) so the apron spans a mixed-stride retreat gap on both
	# sides (identical apron/erosion logic to ℓ1-vs-ℓ2; the coarser tiers keep the headless gate fast).
	m.request(owner, 2)
	m.request(nbr, 3)
	var both: bool = await _drive_until(m, func(): return m.is_covered(owner) and m.is_covered(nbr), 120000)
	_ok(both, "G-M2-SEAM: both sides built+applied (owner ℓ%d, nbr ℓ%d)" % [m.lod_of(owner), m.lod_of(nbr)])
	if not both:
		m.shutdown(); m.free(); return
	# (a) zero protrusion: EVERY LOD megablock vertex is interior to all 4 of its facet's ridge planes (erosion).
	var worst_prot := 1.0e18
	for fid in [owner, nbr]:
		for mi in m.facet_tile_instances(fid):
			var arr: Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)
			var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var lim: int = mini(pv.size(), 400)
			for i in range(lim):
				var lat: Vector3 = (mi as MeshInstance3D).transform * pv[i]
				for slot in range(4):
					worst_prot = minf(worst_prot, FA.own_dist(fid, slot, lat.x, lat.y, lat.z))
	_ok(worst_prot >= -1.0e-2, "G-M2-SEAM(a): zero protrusion — min own_dist over all LOD verts = %.4f ≥ −0.01 (erosion holds)" % worst_prot)
	# apron reconciliation: the apron pass enqueues the LOD↔LOD apron on the owner; drive until it applies.
	var apron_up: bool = await _drive_until(m, func(): return m.apron_slots(owner).has(oslot), 120000)
	_ok(apron_up, "G-M2-SEAM(c): ridge apron present on owner %d slot %d (the LOD↔LOD seam)" % [owner, oslot])
	# (d) exactly one apron per seam: the neighbour (higher fid) owns NO apron on the reciprocal slot.
	var nslot := -1
	for slot in range(4):
		if FA.seam_neighbour(nbr, slot) == owner:
			nslot = slot; break
	_ok(nslot < 0 or not m.apron_slots(nbr).has(nslot), "G-M2-SEAM(d): single ownership — neighbour %d owns no reciprocal apron (lower fid owns)" % nbr)
	if apron_up:
		var s_max := 1 << maxi(m.lod_of(owner), m.lod_of(nbr))
		var amesh: Mesh = m.apron_mesh(owner, oslot)
		_ok(amesh != null and amesh.get_surface_count() > 0, "G-M2-SEAM: apron mesh non-empty (s_max=%d)" % s_max)
		if amesh != null and amesh.get_surface_count() > 0:
			# ridge line in owner lattice + inward (horizontal own-side) direction
			var ring: Array = FA.seam_ring(owner, oslot)
			var pl: Vector4 = FA.seam_plane(owner, oslot)
			var inward := Vector3(pl.x, 0.0, pl.z).normalized()
			var L0a: Array = FA.world_to_lattice64(owner, ring[0].x, ring[0].y, ring[0].z)
			var r0 := Vector3(float(L0a[0]), 0.0, float(L0a[2]))
			var arr: Array = amesh.surface_get_arrays(0)
			var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var max_off := -1.0e18
			var min_off := 1.0e18
			var max_perp := 0.0
			for i in range(pv.size()):
				var p := pv[i]
				var rel := Vector3(p.x - r0.x, 0.0, p.z - r0.z)      # horizontal offset from the ridge line
				var off := rel.dot(inward)                            # signed: + owner side, − neighbour side
				max_off = maxf(max_off, off); min_off = minf(min_off, off)
				max_perp = maxf(max_perp, absf(off))
			# (c) spans BOTH sides of the retreat gap, and every apron vertex stays within the ±s_max window.
			_ok(max_off > 0.5 and min_off < -0.5, "G-M2-SEAM(c): apron spans BOTH sides of the ridge (owner off=%.1f, nbr off=%.1f)" % [max_off, min_off])
			_ok(max_perp <= float(s_max) + 0.75, "G-M2-SEAM(c): every apron vertex within the ±s_max window (max |off|=%.2f ≤ %d)" % [max_perp, s_max])
	# W6: put the NEIGHBOUR into a promote-hold (its live terrain now streams under a held cover). WITHOUT the seam-polish
	# the owner's apron on the ridge facing it MUST be dropped (a both-sided apron there extends INTO the live facet and
	# z-fights its carve bevel). WITH FP_NEIGHBOUR_SEAM_POLISH (A1) it is instead REPLACED by a PLANE-CLAMPED apron: the
	# owner-side half only, so it fills the LOD-side shelf but every vertex stays on the owner side of the welded ridge
	# (own-side offset ≥ 0) and therefore still cannot protrude into / z-fight the live facet — the erosion invariant holds.
	if apron_up:
		m.on_promote(nbr)
		if CubeSphere.FP_NEIGHBOUR_SEAM_POLISH:
			var clamped: bool = await _drive_until(m, func(): return _apron_owner_side_only(m, owner, oslot), 30000)
			_ok(clamped, "G-M2-SEAM(W6): live<->LOD ridge apron is PLANE-CLAMPED to the owner side (no vertex crosses the ridge into the live facet)")
		else:
			var gone: bool = await _drive_until(m, func(): return not m.apron_slots(owner).has(oslot), 30000)
			_ok(gone, "G-M2-SEAM(W6): no apron on a live<->LOD ridge — the owner apron facing the promoting neighbour is dropped")
		m.end_promote(nbr)
	m.shutdown(); m.free()

## G-M2-SEAM(W6) / A1 helper: true iff owner's apron on `oslot` EXISTS and every vertex is on the OWNER side of the
## welded ridge plane — the plane-clamp invariant. Threshold −0.75 matches the LOD↔LOD gate's own sub-block ridge-drift
## tolerance (the seam plane has a small vertical component Bc, so a ridge vertex can sit ≤0.75 block off the plane);
## a both-sided (LOD↔LOD) apron has its neighbour outer strip at off ≈ −s_max ≤ −2 → false, while the clamped live↔LOD
## apron fills off ∈ [≈0, s_max] only (min_off ≈ the sub-block drift) → true. So it cleanly separates clamped from both-sided.
func _apron_owner_side_only(m, owner: int, oslot: int) -> bool:
	if not m.apron_slots(owner).has(oslot):
		return false
	var amesh: Mesh = m.apron_mesh(owner, oslot)
	if amesh == null or amesh.get_surface_count() == 0:
		return false
	var ring: Array = FA.seam_ring(owner, oslot)
	var pl: Vector4 = FA.seam_plane(owner, oslot)
	var inward := Vector3(pl.x, 0.0, pl.z).normalized()
	var L0a: Array = FA.world_to_lattice64(owner, ring[0].x, ring[0].y, ring[0].z)
	var r0 := Vector3(float(L0a[0]), 0.0, float(L0a[2]))
	var arr: Array = amesh.surface_get_arrays(0)
	var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if pv.is_empty():
		return false
	for i in range(pv.size()):
		var rel := Vector3(pv[i].x - r0.x, 0.0, pv[i].z - r0.z)
		if rel.dot(inward) < -0.75:
			return false                                        # a vertex reached the neighbour side (a full −s_max strip)
	return true

# ---------- G-M2-SEL: SSE selector (monotone + floor/cap + hysteresis + telescope) ----------
func _gate_selector() -> void:
	print("  --- G-M2-SEL: SSE selector (monotone in d, floor-1/cap-3, hysteresis, telescope) ---")
	var m = FLM.new()                                    # no setup() — the selector math needs no builder/module/tree
	var h := 1080.0
	var fov := deg_to_rad(70.0)
	# (1) MONOTONE in d + floor-1/cap-3 over a wide sweep (near walk → far orbit).
	var mono := true
	var prev := 0
	var floor_ok := true
	var cap_ok := true
	var d := 50.0
	while d <= 8000.0:
		var t := int(m.desired_tier(d, fov, h))
		if t < prev:
			mono = false
		if t < 1:
			floor_ok = false
		if t > FLM.LOD_MAX_TIER:
			cap_ok = false
		prev = t
		d *= 1.15
	_ok(mono, "G-M2-SEL: desired tier is MONOTONE non-decreasing in distance")
	_ok(floor_ok, "G-M2-SEL: desired tier never below the LOD floor 1 (ℓ0 is live-terrain only)")
	_ok(cap_ok, "G-M2-SEL: desired tier never above the cap LOD_MAX_TIER=%d (quad is ℓ=∞)" % FLM.LOD_MAX_TIER)
	_ok(int(m.desired_tier(50.0, fov, h)) == 1, "G-M2-SEL: near walk (d=50) desires ℓ1 (finest LOD)")
	_ok(int(m.desired_tier(8000.0, fov, h)) == FLM.LOD_MAX_TIER, "G-M2-SEL: far limb (d=8000) desires the cap ℓ%d" % FLM.LOD_MAX_TIER)
	# (2) the four regime archetypes (§6.2 worked thresholds, h=1080, fov 70°: ℓ1<514, ℓ2 from 1028, ℓ3 from 2056).
	_ok(int(m.desired_tier(700.0, fov, h)) == 1, "G-M2-SEL: walk regime d=700 → ℓ1 (t=%d)" % int(m.desired_tier(700.0, fov, h)))
	_ok(int(m.desired_tier(1500.0, fov, h)) == 2, "G-M2-SEL: low-flight d=1500 → ℓ2 (t=%d)" % int(m.desired_tier(1500.0, fov, h)))
	_ok(int(m.desired_tier(3000.0, fov, h)) == 3, "G-M2-SEL: near-orbit d=3000 → ℓ3 (t=%d)" % int(m.desired_tier(3000.0, fov, h)))
	# telescope: shrinking fov (zoom) RAISES the requested tier (finer ℓ, smaller number) for the SAME far facet.
	var wide := int(m.desired_tier(3000.0, deg_to_rad(70.0), h))
	var zoom := int(m.desired_tier(3000.0, deg_to_rad(20.0), h))
	_ok(zoom < wide, "G-M2-SEL: telescope (fov 70°→20° at d=3000) refines the tier ℓ%d → ℓ%d (finer)" % [wide, zoom])
	# (3) HYSTERESIS — two-threshold, ≤1 transition per direction across ONE boundary (the ℓ1/ℓ2 band).
	var up_lc := -1.0
	var up_transitions := 0
	var cur := 1
	var lc := 1.0
	while lc <= 2.9:
		var nt := int(m.hyst_tier(lc, cur))
		if nt != cur:
			up_transitions += 1
			if up_lc < 0.0:
				up_lc = lc
			cur = nt
		lc += 0.01
	var down_lc := -1.0
	var down_transitions := 0
	cur = 2
	lc = 2.9
	while lc >= 1.1:
		var nt := int(m.hyst_tier(lc, cur))
		if nt != cur:
			down_transitions += 1
			if down_lc < 0.0:
				down_lc = lc
			cur = nt
		lc -= 0.01
	_ok(up_transitions <= 1 and down_transitions <= 1,
		"G-M2-SEL: hysteresis yields ≤1 transition per direction (up=%d, down=%d — no thrash)" % [up_transitions, down_transitions])
	_ok(up_transitions == 1 and down_transitions == 1,
		"G-M2-SEL: exactly one transition each way across the ℓ1/ℓ2 boundary")
	_ok(up_lc > down_lc + 0.2,
		"G-M2-SEL: two DIFFERENT thresholds (promote-to-finer at ℓ_c=%.2f ≠ demote at ℓ_c=%.2f — the hysteresis gap)" % [down_lc, up_lc])
	m.free()

# ---------- G-M2-DIR: facet_of_dir round-trip (§10) ----------
func _gate_dir(nf: int) -> void:
	print("  --- G-M2-DIR: facet_of_dir round-trip over all %d facets + orbit-path sanity ---" % nf)
	var mismatches := 0
	var first_bad := -1
	for fid in range(nf):
		var cc: Vector2i = FA.centre_cell(fid)
		var d: CubeSphere.DVec3 = FA.cell_dir(fid, cc.x, cc.y)
		if int(FA.facet_of_dir(d)) != fid:
			mismatches += 1
			if first_bad < 0:
				first_bad = fid
	_ok(mismatches == 0, "G-M2-DIR: facet_of_dir(cell_dir(centre)) == fid for ALL %d facets (%d mismatches%s)" % [
		nf, mismatches, "" if first_bad < 0 else ", first fid=%d" % first_bad])
	# orbit-path sanity: the selector stays finite + monotone along a scripted ascent-to-orbit (no NaN/thrash off-surface).
	var m = FLM.new()
	var finite := true
	var mono := true
	var prev := -1
	var alt := 100.0
	while alt <= 12000.0:
		var t := int(m.desired_tier(alt, deg_to_rad(70.0), 1080.0))
		if t < 1 or t > FLM.LOD_MAX_TIER:
			finite = false
		if t < prev:
			mono = false
		prev = t
		alt *= 1.3
	_ok(finite and mono, "G-M2-DIR: selector finite + monotone along an ascent-to-orbit path (no NaN, no off-surface thrash)")
	m.free()

# ---------- G-M2-CTRL: the closed-loop load controller (synthetic square wave) ----------
func _gate_ctrl(mod: Node3D, active: int) -> void:
	print("  --- G-M2-CTRL: closed-loop load controller (deterministic synthetic square wave) ---")
	var ctrl = SLC.new()
	var src = _SquareWaveSource.new()
	ctrl.set_input_source(src)
	ctrl.set_adaptive(false)                              # L5: this gate asserts the ABSOLUTE-setpoint AIMD (adaptive is _gate_ctrl_adaptive)
	var DT := 1.0 / 60.0                                  # synthetic 60 fps clock — machine speed cannot perturb it
	var t := 0.0
	# (f) flag-off / inert byte-identity: a fresh/idle controller passes the shipped fixed values through unchanged.
	_ok(is_equal_approx(ctrl.credit(), 1.0) and is_equal_approx(ctrl.apply_budget_ms(2.0), 2.0)
			and int(ctrl.grant_count(2)) == 2 and is_equal_approx(ctrl.stream_pace(), 1.0),
		"G-M2-CTRL(f): inert controller = shipped defaults (credit 1, apply 2ms, grants 2, pace 1) — flag-off byte-identity")
	# settle LOW (headroom) → credit pins at 1.
	src.frame_ms = 6.0; src.backlog = 0
	for i in range(120):
		t += DT; ctrl.tick(t)
	_ok(is_equal_approx(ctrl.credit(), 1.0), "G-M2-CTRL: credit settles to 1 under sustained headroom")
	# (a) sustained OVERLOAD → credit falls to 0 within ≤4 control ticks; admissions measurably stop.
	src.frame_ms = 40.0                                  # well above CTRL_FRAME_BUDGET_MS=18
	var start_ticks := int(ctrl.stats()["ticks"])
	var ticks_to_zero := -1
	for i in range(120):
		t += DT; ctrl.tick(t)
		if ctrl.credit() == 0.0 and ticks_to_zero < 0:
			ticks_to_zero = int(ctrl.stats()["ticks"]) - start_ticks
			break
	_ok(ticks_to_zero >= 1 and ticks_to_zero <= 4, "G-M2-CTRL(a): credit → 0 within ≤4 ticks of sustained overload (%d ticks)" % ticks_to_zero)
	# CONTROLLER-FIX §P3a: at credit 0 the RELIEF surfaces 1-2 FLOOR (they buy coverage even under sustained overload) —
	# grant_count → 1, apply_budget_ms(2.0) → 0.5, relief_only() true — while the feedback surface 3 (pace) still closes.
	_ok(int(ctrl.grant_count(2)) == 1 and is_equal_approx(ctrl.apply_budget_ms(2.0), 0.5)
			and is_equal_approx(ctrl.stream_pace(), 0.0) and bool(ctrl.relief_only()),
		"G-M2-CTRL(a): at credit 0 surfaces 1-2 FLOOR (grants 1, apply 0.5ms, relief_only), surface 3 closes (pace 0)")
	# (c) no promote↔demote cycling: only ≥ CTRL_OVERLOAD_SUSTAIN_S (3s) of credit-0 overload trips a demote; a short
	# high pulse must not. We've been overloaded < 3s, so demote_pressure stays false (pause-first, never yanked).
	_ok(not ctrl.demote_pressure(), "G-M2-CTRL(c): short overload does NOT trip demote pressure (no promote↔demote cycle)")
	# (b) load removed → credit RECOVERS and admissions resume.
	src.frame_ms = 6.0
	for i in range(900):
		t += DT; ctrl.tick(t)
	_ok(ctrl.credit() >= 0.9, "G-M2-CTRL(b): credit recovers under restored headroom (%.2f ≥ 0.9)" % ctrl.credit())
	_ok(int(ctrl.grant_count(2)) > 0 and ctrl.apply_budget_ms(2.0) > 0.0, "G-M2-CTRL(b): admissions resume after recovery")
	# (d) the vox_gen > CTRL_BACKLOG_MAX feed-forward gate holds surfaces 3-4 at zero even at FULL frame headroom.
	src.frame_ms = 6.0; src.backlog = CubeSphere.CTRL_BACKLOG_MAX + 100
	for i in range(120):
		t += DT; ctrl.tick(t)
	_ok(ctrl.backlog_gated(), "G-M2-CTRL(d): backlog %d > %d closes the feed-forward gate" % [int(src.backlog), CubeSphere.CTRL_BACKLOG_MAX])
	_ok(is_equal_approx(ctrl.credit(), 1.0), "G-M2-CTRL(d): credit stays 1 (backlog gates surfaces 3-4, NOT the AIMD credit)")
	_ok(is_equal_approx(ctrl.stream_pace(), 0.0) and not ctrl.promote_admitted(),
		"G-M2-CTRL(d): surfaces 3-4 HELD at zero (pace 0, promote denied) despite full frame headroom")
	src.backlog = 0
	for i in range(30):
		t += DT; ctrl.tick(t)
	_ok(is_equal_approx(ctrl.stream_pace(), 1.0), "G-M2-CTRL(d): pace reopens to credit once the backlog drains")
	# (e) NEVER-OOM caps still BIND at full credit — a request storm cannot exceed the ledgers regardless of the controller.
	var m = FLM.new()
	get_root().add_child(m)
	if bool(m.setup(mod)):
		m.call("set_load_controller", ctrl)              # credit is 1 here (full) → grants are NOT throttled
		var storm := 0
		var f := 0
		while storm < 80 and f < FA.facet_count():
			if f != active:
				m.request(f, 1, true)                    # dry admission storm at the heaviest tier
				storm += 1
			f += 1
		var st: Dictionary = m.stats()
		var cap_bytes := FLM.LOD_MAX_BYTES_MB * 1024 * 1024
		_ok(int(st["tris"]) <= FLM.LOD_MAX_TRIS and int(st["bytes"]) <= cap_bytes,
			"G-M2-CTRL(e): at credit 1 the NEVER-OOM caps still bind (tris %d ≤ %d, bytes %d ≤ %d)" % [
				int(st["tris"]), FLM.LOD_MAX_TRIS, int(st["bytes"]), cap_bytes])
		m.shutdown()
	else:
		_ok(false, "G-M2-CTRL(e): mesher setup for the full-credit caps check")
	if is_instance_valid(m):
		m.free()

# ---------- G-M2-CTRL(W2): raw-dt sustain clamp (a background gap must not spuriously trip a sustained condition) ----------
func _gate_ctrl_rawdt() -> void:
	print("  --- G-M2-CTRL(W2): raw-dt sustain clamp (giant background tick never satisfies a sustain) ---")
	var DT := 1.0 / 60.0
	# headroom arm: partial imminent headroom-hold (< CTRL_PROMOTE_SUSTAIN_S), then ONE giant dt tick.
	var cw = SLC.new()
	var sw = _SquareWaveSource.new()
	cw.set_input_source(sw)
	cw.set_adaptive(false)                               # L5: W2 asserts absolute-path sustain clamps
	var tt := 0.0
	sw.frame_ms = 6.0; sw.backlog = 0                    # headroom → the imminent headroom-hold accrues
	for i in range(80):
		tt += DT; cw.tick(tt)
	var head_before := float(cw.stats()["headroom_hold_s"])
	_ok(head_before > 0.0 and not cw.promote_imminent_admitted(),
		"G-M2-CTRL(W2) setup: partial headroom hold accrued (%.2fs), not yet sustained" % head_before)
	tt += 100.0; cw.tick(tt)                             # ONE giant tick (100 s of wall clock in one frame)
	_ok(float(cw.stats()["headroom_hold_s"]) <= CubeSphere.CTRL_TICK_S + 1e-6 and not cw.promote_imminent_admitted(),
		"G-M2-CTRL(W2): a giant dt tick does NOT jump the headroom hold past threshold (discontinuity reset)")
	# overload arm: partial overload hold (< CTRL_OVERLOAD_SUSTAIN_S), then a giant tick must NOT trip sustained demote.
	var cw2 = SLC.new()
	var sw2 = _SquareWaveSource.new()
	cw2.set_input_source(sw2)
	cw2.set_adaptive(false)                              # L5: W2 asserts absolute-path sustain clamps
	var t2 := 0.0
	sw2.frame_ms = 40.0; sw2.backlog = 0                 # overload → credit → 0, overload-hold begins
	for i in range(120):
		t2 += DT; cw2.tick(t2)
	_ok(not cw2.demote_pressure(), "G-M2-CTRL(W2) setup: overloaded < CTRL_OVERLOAD_SUSTAIN_S — demote pressure not yet tripped")
	t2 += 100.0; cw2.tick(t2)                            # ONE giant tick
	_ok(not cw2.demote_pressure(), "G-M2-CTRL(W2): a giant dt tick does NOT instantly trip sustained demote pressure (no spurious demote on refocus)")

# ---------- G-M2-CTRL-ADAPTIVE (COSMOS-PERF L5): the floor-relative overload setpoint ----------
# The shipped absolute setpoint (18 ms) reads a 30-fps-floor client's HEALTHY 33 ms steady frame as permanent overload,
# pinning stream_credit at 0 all session (live telemetry). L5 makes the setpoint relative to the client's OWN floor.
# Deterministic: synthetic square-wave source + fixed-step injected clock; each controller pins its mode via set_adaptive.
func _gate_ctrl_adaptive() -> void:
	print("  --- G-M2-CTRL-ADAPTIVE (L5): floor-relative overload setpoint (deterministic square wave) ---")
	var DT := 1.0 / 60.0
	# (a) a 30-fps-FLOOR client at a STEADY 33 ms is NOT flagged overloaded (the un-starve fix).
	var c = SLC.new()
	var s = _SquareWaveSource.new()
	c.set_input_source(s)
	c.set_adaptive(true)
	var t := 0.0
	s.frame_ms = 33.0; s.backlog = 0                     # the healthy full-radius 2-vsync frame on a 30-fps client
	for i in range(200):
		t += DT; c.tick(t)
	var sp := float(c.stats()["setpoint_ms"])
	_ok(sp > 33.0 and sp <= CubeSphere.CTRL_ADAPTIVE_MAX_MS,
		"G-M2-CTRL-ADAPTIVE(a): setpoint tracks the client floor ABOVE a steady 33 ms (%.1f ms, floor_p10 %.1f)" % [sp, float(c.stats()["floor_p10_ms"])])
	_ok(not bool(c.stats()["overload"]) and is_equal_approx(c.credit(), 1.0),
		"G-M2-CTRL-ADAPTIVE(a): a steady 33 ms is NOT overload on a 33-ms-floor client (credit stays 1 — un-starved)")
	# (a') the SHIPPED absolute setpoint DOES pin credit 0 at the same steady 33 ms — the exact regression adaptive fixes.
	var cabs = SLC.new()
	var sabs = _SquareWaveSource.new()
	cabs.set_input_source(sabs)
	cabs.set_adaptive(false)
	var ta := 0.0
	sabs.frame_ms = 33.0; sabs.backlog = 0
	for i in range(200):
		ta += DT; cabs.tick(ta)
	_ok(cabs.credit() == 0.0 and bool(cabs.stats()["overload"]),
		"G-M2-CTRL-ADAPTIVE(a'): the absolute setpoint pins credit 0 at a steady 33 ms (the bug adaptive removes)")
	# (b) a genuine transient SPIKE above the floor still registers overload → credit dips (adaptive is not blind to hitches).
	s.frame_ms = 80.0                                    # a real hitch, well above the ~43 ms adaptive setpoint
	for i in range(120):
		t += DT; c.tick(t)
	_ok(c.credit() < 1.0 and bool(c.stats()["overload"]),
		"G-M2-CTRL-ADAPTIVE(b): a transient spike ABOVE the floor still trips overload (credit %.2f < 1)" % c.credit())
	_ok(float(c.stats()["floor_p10_ms"]) <= 34.0,
		"G-M2-CTRL-ADAPTIVE(b): the short spike does NOT pollute the best-floor (floor_p10 %.1f ≈ 33)" % float(c.stats()["floor_p10_ms"]))
	# (c) at the FAST end the adaptive setpoint clamps DOWN to the absolute budget → identical verdict to shipped (never stricter).
	var cf2 = SLC.new()
	var sf2 = _SquareWaveSource.new()
	cf2.set_input_source(sf2)
	cf2.set_adaptive(true)
	var tf := 0.0
	sf2.frame_ms = 6.0; sf2.backlog = 0                  # a 60-fps client: floor 6 → setpoint clamps UP to the 18 ms budget
	for i in range(200):
		tf += DT; cf2.tick(tf)
	_ok(is_equal_approx(float(cf2.stats()["setpoint_ms"]), CubeSphere.CTRL_FRAME_BUDGET_MS),
		"G-M2-CTRL-ADAPTIVE(c): a fast client's setpoint clamps to the absolute budget (%.1f ms) — never STRICTER than shipped" % CubeSphere.CTRL_FRAME_BUDGET_MS)
	sf2.frame_ms = 40.0                                  # 40 > 18 → overload on BOTH paths (adaptive ≡ absolute at the clamp)
	var zeroed := false
	for i in range(120):
		tf += DT; cf2.tick(tf)
		if cf2.credit() == 0.0:
			zeroed = true; break
	_ok(zeroed, "G-M2-CTRL-ADAPTIVE(c): at the clamped setpoint a 40 ms load still drives credit → 0 (adaptive ≡ absolute here)")

# ---------- G-L1-FARRING (COSMOS-PERF L1): far-ring fast-rebuild mesh equivalence ----------
# The FP_FARRING_FAST_REBUILD packed-array assembler must produce a VISUALLY EQUIVALENT mesh to the shipped SurfaceTool
# path: identical vertex count, identical per-vertex positions + colors (same winding), and per-face FLAT normals that
# match generate_normals(flip=false). Builds BOTH meshes for the same visible fid set (independent of the const) + a
# pool-exclusion variant, and compares the decompressed surface arrays.
func _gate_farring_equiv(active: int) -> void:
	print("  --- G-L1-FARRING (L1): far-ring fast-rebuild mesh equivalence (SurfaceTool vs packed arrays) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	_farring_compare(ring, "front-hemisphere")
	# pool-change path: exclude one visible facet (a neighbour spawn/retire) and re-compare.
	var vis: PackedInt32Array = ring.call("visible_fids")
	if vis.size() > 0:
		ring.call("set_pool_excluded", [int(vis[0])])
		_farring_compare(ring, "one facet excluded (pool change)")
	ring.free()

func _farring_compare(ring: Node3D, label: String) -> void:
	var fids: PackedInt32Array = ring.call("visible_fids")
	var slow: ArrayMesh = ring.call("_build_surfacetool", fids)
	var fast: ArrayMesh = ring.call("_build_fast", fids)
	var sc_a := slow.get_surface_count()
	var sc_b := fast.get_surface_count()
	if sc_a == 0 or sc_b == 0:
		_ok(sc_a == sc_b, "G-L1-FARRING [%s]: both empty ⇔ both empty (surfaces %d/%d)" % [label, sc_a, sc_b])
		return
	var aa := slow.surface_get_arrays(0)
	var ab := fast.surface_get_arrays(0)
	var va: PackedVector3Array = aa[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = ab[Mesh.ARRAY_VERTEX]
	var ca: PackedColorArray = aa[Mesh.ARRAY_COLOR]
	var cb: PackedColorArray = ab[Mesh.ARRAY_COLOR]
	var na: PackedVector3Array = aa[Mesh.ARRAY_NORMAL]
	var nb: PackedVector3Array = ab[Mesh.ARRAY_NORMAL]
	# vertex count (== tri count × 3): 32 tris/facet × 3 = 96 verts/facet on both.
	var verts_per_facet := FFR.CELLS * FFR.CELLS * 2 * 3
	_ok(va.size() == vb.size() and va.size() % 3 == 0 and va.size() == fids.size() * verts_per_facet,
		"G-L1-FARRING [%s]: identical vertex count (%d == %d = %d facets × %d)" % [label, va.size(), vb.size(), fids.size(), verts_per_facet])
	# positions: index-aligned (same fids, same order, same winding).
	var vert_ok := va.size() == vb.size()
	for i in range(mini(va.size(), vb.size())):
		if not va[i].is_equal_approx(vb[i]):
			vert_ok = false; break
	_ok(vert_ok, "G-L1-FARRING [%s]: per-vertex positions identical (same triangles + winding)" % label)
	# colors: the seam palette must be preserved exactly.
	var col_ok := ca.size() == cb.size()
	for i in range(mini(ca.size(), cb.size())):
		if not ca[i].is_equal_approx(cb[i]):
			col_ok = false; break
	_ok(col_ok, "G-L1-FARRING [%s]: per-vertex colors identical (seam palette preserved)" % label)
	# normals: BIT-IDENTICAL. The fast path computes normals with create_from + generate_normals over the SAME assembled
	# vertex list, so its GLOBAL smoothing (which merges vertices across facet SEAMS) equals the SurfaceTool path exactly.
	# A per-facet or flat shortcut would deviate ~0.1–0.4 at the seams; a FLIP ~2.0 — both far above this 1e-6 tolerance.
	var nrm_ok := na.size() == nb.size()
	var maxdev := 0.0
	for i in range(mini(na.size(), nb.size())):
		var d := (na[i] - nb[i]).length()
		if d > maxdev:
			maxdev = d
		if d > 1.0e-6:
			nrm_ok = false
	_ok(nrm_ok, "G-L1-FARRING [%s]: normals bit-identical to generate_normals (max dev %.8f — global smoothing preserved)" % [label, maxdev])
	# COSMOS-PERF STEP 2 (FP_FARRING_ASYNC_REBUILD): the OFF-THREAD worker body must produce a mesh byte-identical to the
	# synchronous path. It emits the same visible fids + generate_normals, then extracts the arrays via commit_to_arrays
	# (no mesh RID / RenderingServer) — the arrays the async main-thread swap builds an ArrayMesh from. Run the worker
	# body inline (pure CPU) and compare its swapped mesh to the synchronous `slow` mesh (pos/col/normal deviation 0.0).
	ring.set("_async_fids", fids)
	ring.call("_async_build_worker")
	var async_arrays: Array = ring.get("_async_arrays")
	var async_mesh := ArrayMesh.new()
	var vac := 0
	if async_arrays.size() == Mesh.ARRAY_MAX and (async_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0:
		async_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, async_arrays)
		vac = async_mesh.get_surface_count()
	if vac == 0:
		_ok(va.size() == 0, "G-L1-FARRING-ASYNC [%s]: empty visible set ⇔ empty async mesh" % label)
		return
	var da := async_mesh.surface_get_arrays(0)
	var vd: PackedVector3Array = da[Mesh.ARRAY_VERTEX]
	var cd: PackedColorArray = da[Mesh.ARRAY_COLOR]
	var nd: PackedVector3Array = da[Mesh.ARRAY_NORMAL]
	var async_ok := vd.size() == va.size() and cd.size() == ca.size() and nd.size() == na.size()
	var amax := 0.0
	for i in range(mini(vd.size(), va.size())):
		if not vd[i].is_equal_approx(va[i]) or not cd[i].is_equal_approx(ca[i]):
			async_ok = false
		var ad := (nd[i] - na[i]).length()
		if ad > amax:
			amax = ad
		if ad > 1.0e-6:
			async_ok = false
	_ok(async_ok, "G-L1-FARRING-ASYNC [%s]: off-thread worker mesh bit-identical to synchronous (nrm dev %.8f)" % [label, amax])

# ---------- G-M2-POLICY: Z1-hybrid live-terrain targets + promote admission (§3.2 / §6.5.3.4) ----------
func _gate_policy() -> void:
	print("  --- G-M2-POLICY: Z1-hybrid live-neighbour targets + promote admission ---")
	# arbitrary distinct facet ids for the PURE selector (z1_live_targets is over CubeSphere consts only).
	var A := 10; var B := 11; var C := 12; var D := 13
	# mid-edge walk: one ridge under D_WARM, the rest far → EXACTLY 1 live neighbour (the imminent).
	var mid: Array = WM.z1_live_targets({A: 40.0, B: 200.0, C: 210.0, D: 220.0}, false, [])
	_ok(mid.size() == 1 and int(mid[0]) == A, "G-M2-POLICY mid-edge: exactly 1 live neighbour (imminent)")
	# corner approach: TWO ridges within D_WARM2 (48) → 2 live neighbours.
	var corner: Array = WM.z1_live_targets({A: 20.0, B: 30.0, C: 210.0, D: 220.0}, false, [])
	_ok(corner.size() == 2 and corner.has(A) and corner.has(B), "G-M2-POLICY corner: 2 live neighbours (both < D_WARM2=48)")
	# a 2nd ridge inside D_WARM but OUTSIDE D_WARM2 does NOT add a 2nd live (walking mid-edge stays 1).
	var one2: Array = WM.z1_live_targets({A: 40.0, B: 80.0, C: 210.0, D: 220.0}, false, [])
	_ok(one2.size() == 1, "G-M2-POLICY: a 2nd ridge in [D_WARM2, D_WARM) stays 1 live (no spurious corner-second)")
	# diagonal never live: z1 only ever returns fids present in `want` (edge neighbours) — a diagonal is never in `want`.
	_ok(not corner.has(99), "G-M2-POLICY: a fid absent from `want` (a diagonal) is never a live target")
	# off-surface freeze (risk #6): 0 live neighbours even with two near ridges (a high-flyer must not thrash the pool).
	_ok(WM.z1_live_targets({A: 20.0, B: 30.0}, true, []).is_empty(), "G-M2-POLICY off-surface: 0 live neighbours (spawn freeze)")
	# switch margin (anti-thrash): a live incumbent B@75 is KEPT when challenger A@70 beats it by only 5 (< 16).
	var keep: Array = WM.z1_live_targets({A: 70.0, B: 75.0}, false, [B])
	_ok(keep.size() == 1 and int(keep[0]) == B, "G-M2-POLICY switch-margin: incumbent kept (challenger within 16 — no thrash)")
	# switch margin: incumbent B@75 is DISPLACED when challenger A@50 beats it by 25 (> 16).
	var sw: Array = WM.z1_live_targets({A: 50.0, B: 75.0}, false, [B])
	_ok(sw.size() == 1 and int(sw[0]) == A, "G-M2-POLICY switch-margin: incumbent displaced when beaten by > 16")
	# promote admission (surface 4): a backlog-gated controller DENIES a live spawn; a healthy one admits; null → admit.
	var cg = SLC.new()
	var sg = _SquareWaveSource.new()
	cg.set_input_source(sg)
	cg.set_adaptive(false)                              # L5: promote-admission is asserted on the absolute path
	var DT := 1.0 / 60.0
	var t := 0.0
	sg.frame_ms = 6.0; sg.backlog = CubeSphere.CTRL_BACKLOG_MAX + 100
	for i in range(120):
		t += DT; cg.tick(t)
	_ok(not WM.promote_admit(cg), "G-M2-POLICY: backlog-gated controller → NO live spawn admitted (promote_admit false)")
	sg.backlog = 0; sg.frame_ms = 6.0
	for i in range(300):
		t += DT; cg.tick(t)
	_ok(WM.promote_admit(cg), "G-M2-POLICY: drained + sustained headroom → live spawn admitted (promote_admit true)")
	_ok(WM.promote_admit(null), "G-M2-POLICY: null controller (flag-off) → admit (shipped FP-M1c behaviour)")
	# W1 — the IMMINENT target is EXEMPT from the raw vox_gen backlog gate (the ridge we are crossing must go full-res on
	# frame headroom alone), but the 2nd/corner target is NOT. Build a controller that is backlog-GATED yet has sustained
	# frame headroom: promote_admit_imminent → true (imminent spawns), promote_admit → false (2nd/corner is throttled).
	var ci = SLC.new()
	var si = _SquareWaveSource.new()
	ci.set_input_source(si)
	ci.set_adaptive(false)                              # L5: W1 imminent-exempt gate asserted on the absolute path
	var ti := 0.0
	si.frame_ms = 6.0                                   # full frame headroom (credit floats to 1, headroom-hold accrues)
	si.backlog = CubeSphere.CTRL_BACKLOG_MAX + 100      # vox_gen gate CLOSED throughout
	for i in range(300):
		ti += DT; ci.tick(ti)
	_ok(ci.backlog_gated(), "G-M2-POLICY(W1): backlog gate closed (vox_gen %d > %d)" % [int(si.backlog), CubeSphere.CTRL_BACKLOG_MAX])
	# CONTROLLER-FIX §P3b: assert the HEADROOM path specifically — an out-of-commit distance so the geometric commit does
	# not mask it (the commit path is asserted at credit 0 in G-M2-STARVE(c)).
	_ok(WM.promote_admit_imminent(ci, CubeSphere.POOL_D_COMMIT + 32.0), "G-M2-POLICY(W1): the IMMINENT target IS admitted despite the backlog gate (frame-headroom exempt, out of commit range)")
	_ok(not WM.promote_admit(ci), "G-M2-POLICY(W1): the 2nd/corner target is NOT admitted while backlog-gated (feed-forward throttle holds)")
	_ok(WM.promote_admit_imminent(null, CubeSphere.POOL_D_COMMIT + 32.0), "G-M2-POLICY(W1): null controller (flag-off) → imminent admit (shipped FP-M1c)")

# ---------- G-M2-STARVE: the relief floor + geometric commit un-starve the controller (§6.3 regression gate) ----------
# COSMOS-FP-M2-CONTROLLER-FIX §6.3 — the gate that would have caught the live starvation (credit pinned 0 for 437 s:
# zero LOD facets ever built, every crossing a pool-miss). Fixed-step injected clock + synthetic _SquareWaveSource
# throughout; NO wall clock in any decision. (a) pins the shipped deadlock as the precondition; (b) is the minimal
# catcher (the single assert that fails on shipped code); (c) the geometric commit; (d) end-to-end residency under
# starvation; (e) disjointness / no build↔demote hunt; (f) p90 ≡ max trace identity under a constant signal.
func _gate_starve(mod: Node3D, active: int, neighbour: int, corner_fid: int) -> void:
	print("  --- G-M2-STARVE: relief floor + geometric commit (credit-0 no longer inert) ---")
	var DT := 1.0 / 60.0
	# (a) reproduce the shipped STARVED state: sustained overload + heavy backlog → credit 0, both promote gates shut.
	var ctrl = SLC.new()
	var src = _SquareWaveSource.new()
	ctrl.set_input_source(src)
	ctrl.set_adaptive(false)                             # L5: STARVE asserts the ORTHOGONAL relief-floor fix at credit 0 (absolute path)
	src.frame_ms = 45.0; src.backlog = 900               # >> CTRL_FRAME_BUDGET_MS(18) and >> CTRL_BACKLOG_MAX(300)
	var t := 0.0
	for i in range(300):                                 # ≥12 control ticks (a control tick fires every ~15 frames)
		t += DT; ctrl.tick(t)
	_ok(ctrl.credit() == 0.0 and ctrl.backlog_gated()
			and not ctrl.promote_admitted() and not ctrl.promote_imminent_admitted(),
		"G-M2-STARVE(a): sustained overload+backlog pins credit 0, both promote gates shut (the shipped deadlock precondition)")
	# (b) THE MINIMAL CATCHER: under (a), surfaces 1-2 are still open at the RELIEF FLOOR (this single assert fails on shipped code).
	_ok(int(ctrl.grant_count(2)) == 1 and is_equal_approx(ctrl.apply_budget_ms(2.0), 0.5) and bool(ctrl.relief_only()),
		"G-M2-STARVE(b): under sustained overload the build/apply surfaces stay OPEN at the floor (grants 1, apply 0.5ms) — the fix")
	# (c) the imminent ridge still PROMOTES at credit 0 via the geometric commit; the politeness window + the corner/2nd throttle hold.
	_ok(WM.promote_admit_imminent(ctrl, CubeSphere.POOL_D_COMMIT - 1.0),
		"G-M2-STARVE(c): imminent promote ADMITTED at credit 0 inside POOL_D_COMMIT (geometric commit — no seam-burst)")
	_ok(not WM.promote_admit_imminent(ctrl, CubeSphere.POOL_D_COMMIT + 32.0),
		"G-M2-STARVE(c): imminent promote DEFERRED outside POOL_D_COMMIT at credit 0 (politeness window intact)")
	_ok(not WM.promote_admit(ctrl), "G-M2-STARVE(c): the corner/2nd promote stays throttled at credit 0 (feed-forward on optional volume)")
	# (f) p90 ≡ max under a CONSTANT signal → the AIMD credit trace equals the pre-change (window-max) constants.
	var cf = SLC.new()
	var sf = _SquareWaveSource.new()
	cf.set_input_source(sf)
	cf.set_adaptive(false)                               # L5: the p90≡max constant-signal trace is the absolute-path AIMD
	var tf := 0.0
	sf.frame_ms = 6.0; sf.backlog = 0
	for i in range(120):                                 # warm to credit 1 under sustained headroom
		tf += DT; cf.tick(tf)
	sf.frame_ms = 40.0                                   # constant overload → capture the multiplicative-decrease trace tick-by-tick
	var trace: Array = []
	var last_ticks := int(cf.stats()["ticks"])
	while trace.size() < 4 and tf < 120.0:
		tf += DT; cf.tick(tf)
		var nt := int(cf.stats()["ticks"])
		if nt > last_ticks:
			last_ticks = nt
			trace.append(cf.credit())
	var expect := [0.5, 0.25, 0.125, 0.0]                # 1.0 ×0.5/tick; 0.0625 ≤ _CREDIT_ZERO_SNAP(0.1) → snaps to 0
	var ident := trace.size() == expect.size()
	for i in range(expect.size()):
		if i >= trace.size() or not is_equal_approx(float(trace[i]), expect[i]):
			ident = false
	_ok(ident, "G-M2-STARVE(f): constant-signal credit trace == pre-change AIMD (p90 ≡ max) %s" % str(trace))
	# (d) end-to-end residency UNDER STARVATION: wire the starved controller into a REAL mesher, seed a want for an
	# uncovered facet, drive → the ℓ3 first cover MATERIALIZES. Live telemetry showed residency pinned at 0 for 437 s.
	var md = FLM.new()
	get_root().add_child(md)
	if bool(md.setup(mod)):
		md.call("set_load_controller", ctrl)             # ctrl is starved (credit 0, relief_only) from (a)
		md.call("set_imminent_fid", -1)
		md._want[neighbour] = 1                           # want a FINE tier; relief still covers a MESHLESS facet at ℓ3 first
		var covered: bool = await _drive_mesher(md, neighbour, 60000)
		_ok(covered and int(md.stats()["facets"]) >= 1,
			"G-M2-STARVE(d): a meshless facet is covered under sustained credit-0 starvation (residency %d ≥ 1)" % int(md.stats()["facets"]))
		md.shutdown()
	else:
		_ok(false, "G-M2-STARVE(d): mesher setup for the residency-under-starvation check")
	if is_instance_valid(md):
		md.free()
	# (e) disjointness / no build↔demote hunt: cover a non-imminent A and the imminent I at ℓ2 (direct, controller-free);
	# then wire the STARVED controller (relief_only) and assert (e1) a covered non-imminent facet wanting FINER is NOT
	# re-granted; (e2) demote coarsens A (not I) and A keeps its mesh; (e3) the imminent I is never the demote victim.
	var me = FLM.new()
	get_root().add_child(me)
	if bool(me.setup(mod)):
		var A := neighbour
		var Ic := corner_fid
		me.request(A, 2)
		var cA: bool = await _drive_mesher(me, A, 60000)
		me.request(Ic, 2)
		var cI: bool = await _drive_mesher(me, Ic, 60000)
		if cA and cI and me.lod_of(A) == 2 and me.lod_of(Ic) == 2:
			me.call("set_load_controller", ctrl)         # relief_only holds (credit 0 from (a))
			me.call("set_imminent_fid", Ic)
			# (e1) covered non-imminent A wants finer → the relief budgeter must NOT grant it (refinement stays credit-gated).
			me._want.clear(); me._want[A] = 1; me._want[Ic] = 2   # keep both wanted (no idle-out); Ic@cur → no self-regrant
			for i in range(40):
				me.tick(); await process_frame
			_ok(me.lod_of(A) == 2 and not me.is_building(A),
				"G-M2-STARVE(e1): a covered non-imminent facet is NOT refined in relief mode (held at ℓ%d)" % me.lod_of(A))
			# (e2/e3) demote: victim is A (Ic is imminent → §P3d spared); A keeps its mesh through the coarser rebuild; Ic stays ℓ2.
			me._want.clear()
			var covered_before := int(me.stats()["facets"])
			me.demote_pressure_relief()
			_ok(me.is_covered(A), "G-M2-STARVE(e2): the demote victim keeps a mesh during the coarser rebuild (no hole)")
			var coarsened: bool = await _drive_until(me, func(): return int(me.lod_of(A)) == 3, 60000)
			_ok(coarsened, "G-M2-STARVE(e2): demote_pressure_relief coarsened the NON-imminent victim A one tier (ℓ2 → ℓ3)")
			_ok(me.lod_of(Ic) == 2 and int(me.stats()["facets"]) == covered_before,
				"G-M2-STARVE(e3): the imminent ridge is SPARED by demote (held at ℓ2, residency %d unchanged)" % covered_before)
			# no re-grant while relief holds: A@ℓ3 wanting finer → stays ℓ3 (the only path back to finer needs credit ≥ FLOOR).
			me._want.clear(); me._want[A] = 1; me._want[Ic] = 2
			for i in range(40):
				me.tick(); await process_frame
			_ok(me.lod_of(A) == 3, "G-M2-STARVE(e): the coarsened victim is NOT re-refined while relief_only holds (ℓ%d — no hunting)" % me.lod_of(A))
		else:
			_ok(false, "G-M2-STARVE(e): setup — cover non-imminent A@ℓ2 (cA=%s ℓ%d) + imminent I@ℓ2 (cI=%s ℓ%d)" % [str(cA), me.lod_of(A), str(cI), me.lod_of(Ic)])
		me.shutdown()
	else:
		_ok(false, "G-M2-STARVE(e): mesher setup for the disjointness check")
	if is_instance_valid(me):
		me.free()

# ---------- G-M2-XPD: promote-hold / evict + redesignate (no rebuild, no teardown, pool-miss 0) (§9) ----------
func _gate_xpd(mod: Node3D, active: int, neighbour: int) -> void:
	print("  --- G-M2-XPD: promote-hold → evict + redesignate crossing (rigid, no rebuild, pool-miss 0) ---")
	# ---- Part A: the promote HOLD + evict state machine on a standalone mesher (no builder flood → hang-safe) ----
	var m = FLM.new()
	get_root().add_child(m)
	if not bool(m.setup(mod)):
		_ok(false, "G-M2-XPD: mesher setup"); m.free(); return
	var f := neighbour
	m.request(f, 3)                                          # ℓ3 = 1 tile — fast, guaranteed non-empty
	var applied: bool = await _drive_mesher(m, f, 60000)
	_ok(applied, "G-M2-XPD: facet %d covered (LOD mesh applied)" % f)
	if not applied:
		m.shutdown(); m.free(); return
	var build0 := int(m.stats()["builder_built"])
	m.on_promote(f)                                          # PROMOTE: hold the LOD cover while the live terrain streams
	_ok(m.is_promoting(f) and m.is_covered(f), "G-M2-XPD: on_promote HOLDS facet %d's LOD cover (covered + promoting)" % f)
	m.notify_pool_changed()                                  # a pool change must NOT evict the held cover (no gap)
	_ok(m.is_covered(f), "G-M2-XPD: held cover survives notify_pool_changed (no gap while streaming)")
	m.set_active_facet(active)                               # the crossing re-tier call: held cover moves rigidly, NO rebuild
	_ok(m.is_covered(f), "G-M2-XPD: held cover survives set_active_facet(other) (rigid — not evicted)")
	_ok(int(m.stats()["builder_built"]) == build0,
		"G-M2-XPD: the crossing re-tier (set_active_facet) enqueued NO rebuild (build_count %d unchanged)" % build0)
	m.evict(f)                                               # seam band meshed → complete the promote
	_ok(not m.is_covered(f) and not m.is_promoting(f), "G-M2-XPD: evict() completes the promote (cover dropped, hold lifted)")
	# the ACTIVE facet must NEVER carry a held cover: re-cover f, promote it, then make it active → force-evicted.
	m.request(f, 3)
	var re: bool = await _drive_mesher(m, f, 60000)
	if re:
		m.on_promote(f)
		m.set_active_facet(f)                               # f becomes active
		_ok(not m.is_covered(f) and not m.is_promoting(f),
			"G-M2-XPD: a promoting facet that goes ACTIVE is force-evicted (active never carries LOD)")
	else:
		_ok(false, "G-M2-XPD: re-cover facet %d for the active-force-evict check" % f)
	# ---- C4: promote then RETIRE-before-complete. end_promote() lifts the HOLD without evicting (the facet is a normal
	# LOD neighbour again); the once-held cover must then be normally manageable (idle/LRU can free it) — NOT pinned
	# forever (the world_manager premature `_promote_pending.erase` bug left `_promoting[fid]` set → an orphan mesh). ----
	m.set_active_facet(active)                               # reset: f is a neighbour again
	m.request(f, 3)
	var reC: bool = await _drive_mesher(m, f, 60000)
	if reC:
		m.on_promote(f)
		_ok(m.is_promoting(f) and m.is_covered(f), "G-M2-XPD(C4): facet %d promote-held (covered + promoting)" % f)
		m.end_promote(f)                                    # == module_world.lod_end_promote on a retire-before-complete
		_ok(not m.is_promoting(f) and m.is_covered(f), "G-M2-XPD(C4): end_promote lifts the hold, mesh KEPT (not evicted, not pinned-promoting)")
		m._want.clear()                                     # white-box: the facet is no longer wanted (retired + walked on)
		m.set_active_facet(active)                          # a re-tier now frees the un-held, unwanted cover
		_ok(not m.is_covered(f), "G-M2-XPD(C4): the un-held cover is freeable — no orphan LOD mesh pinned after promote-retire")
	else:
		_ok(false, "G-M2-XPD(C4): re-cover facet %d for the promote-retire check" % f)
	m.shutdown(); m.free()
	# ---- Part B: redesignate on the real module pool is a HIT (pool-miss 0), ONE transform write, no teardown ----
	_ok(int(mod.call("pool_active")) == active, "G-M2-XPD: module pool active == %d before the crossing" % active)
	var spawned := bool(mod.call("pool_spawn", neighbour))
	_ok(spawned and bool(mod.call("pool_has", neighbour)),
		"G-M2-XPD: pre-spawned the crossing target %d (controlled, non-outrunning sequence)" % neighbour)
	if spawned:
		var t_to_before = mod.call("pool_terrain", neighbour)
		var t_from = mod.call("pool_terrain", active)
		var hit := bool(mod.call("redesignate", neighbour))
		_ok(hit, "G-M2-XPD: redesignate(%d) is a POOL HIT (controlled crossing — strict pool-miss == 0)" % neighbour)
		_ok(int(mod.call("pool_active")) == neighbour, "G-M2-XPD: pool active flipped to %d after redesignate" % neighbour)
		var proot: Node3D = mod.get_node_or_null("PlanetRoot")
		_ok(proot != null and proot.transform.is_equal_approx(FA.facet_transform(neighbour).affine_inverse()),
			"G-M2-XPD: ONE PlanetRoot transform write == facet_transform(to)⁻¹ (the rigid crossing)")
		var t_to_after = mod.call("pool_terrain", neighbour)
		_ok(t_to_after == t_to_before and is_instance_valid(t_from) and bool(mod.call("pool_has", active)),
			"G-M2-XPD: NO teardown — `to`+`from` terrains persist ((fid,cell) edit keys continuous across the crossing)")

# ---------- helpers ----------
func _drive_mesher(mesher, fid: int, timeout_ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(mesher.is_covered(fid)) and (Time.get_ticks_msec() - t0) < timeout_ms:
		mesher.tick()
		await process_frame
	return bool(mesher.is_covered(fid))

func _drive_until(mesher, cond: Callable, timeout_ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()) and (Time.get_ticks_msec() - t0) < timeout_ms:
		mesher.tick()
		await process_frame
	return bool(cond.call())

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
