extends SceneTree
## COSMOS FP-R0 gate (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §8) — the multi-facet ROTATION KILL-SHOT
## spike, headless. Proves (A) godot_voxel streams+meshes a SECOND VoxelTerrain under a REAL orthonormal facet
## rotation (det=+1) with its own frozen-neighbour generator + own carve mesher + the shared baked library, all
## served by the ONE global VoxelViewer — with ZERO det==0 / affine_inverse spam (the falsified "cannot be
## rotated" constraint). And (B) a LOD-stride feasibility probe: generator-side stride-2^ℓ sampling feeding
## VoxelMesher.build_mesh (no terrain node), measuring build ms / tris / bytes per ℓ ∈ {0,1,2,3} and projecting
## the "real voxel blocks out to 512 across all in-range facets" web budget.
##
## RUN (FACETED + FP_R0 sed-toggled to true, like the other faceted gates):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_R0 := false/const FP_R0 := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fp_r0.gd 2> stderr.log
##   grep -Eic 'det==0|affine_inverse|Basis.invert' stderr.log   # MUST be 0 (the no-spam proof)
## then revert the sed. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# --- vertex byte model (blocky format: pos12 + normal12 + uv8 + tangent16 + color16) + int32 indices ------
const _BYTES_PER_VERT := 64
const _BYTES_PER_INDEX := 4

func _initialize() -> void:
	print("=== verify_fp_r0 (multi-facet rotation kill-shot + LOD-stride probe) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1); return
	if not CubeSphere.FP_R0:
		print("  FAIL: CubeSphere.FP_R0 is false — sed-toggle FP_R0 = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1); return
	if not ClassDB.class_exists("VoxelTerrain"):
		print("  FAIL: godot_voxel module absent (ClassDB has no VoxelTerrain) — FP-R0 needs the module binary.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1); return

	TerrainConfig.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	print("  atlas: %d facets (k=%d, R=%d), active(spawn) facet=%d, near_render_radius=%d" % [
		FA.facet_count(), FA.K, int(FA.R_BLOCKS), active, TerrainConfig.near_render_radius()])

	# Build THE active-facet module world directly (the one baked library + active terrain), add to the tree.
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	var ok_setup: bool = bool(mod.call("setup"))
	_ok(ok_setup, "module_world.setup() built the active-facet terrain + baked library")
	if not ok_setup:
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1); return

	# Pick a real edge-neighbour of the active facet (a shared ridge).
	var neighbour := -1
	var used_slot := -1
	for slot in range(4):
		var nb: int = FA.seam_neighbour(active, slot)
		if nb >= 0 and nb != active:
			neighbour = nb; used_slot = slot; break
	_ok(neighbour >= 0, "found an edge-neighbour facet of the active facet (slot %d → facet %d)" % [used_slot, neighbour])
	if neighbour < 0:
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1); return

	# ---------- A0: the parent transform is a REAL orthonormal basis, det=+1 (asserted FIRST) ----------
	var fm: Dictionary = FA.verify_frame(neighbour)
	var det: float = float(fm["det"])
	var ortho: float = float(fm["ortho"])
	_ok(absf(det - 1.0) < 1e-6, "A0: neighbour facet_transform basis is right-handed det=+1 (det=%.12f, |det-1|<1e-6)" % det)
	_ok(ortho < 1e-9, "A0: neighbour facet basis orthonormal (Gram residual %s < 1e-9)" % str(ortho))
	var xform: Transform3D = FA.facet_transform(neighbour)
	var bdet: float = xform.basis.determinant()
	_ok(absf(bdet - 1.0) < 1e-6, "A0: facet_transform(neighbour).basis.determinant() = %.12f (invertible, non-singular)" % bdet)

	# ---------- A1: the neighbour renders its OWN facet field (not a clone of the active field) ----------
	var cc: Vector2i = FA.centre_cell(neighbour)
	var g_prof: Vector4 = TerrainConfig.facet_profile(neighbour, cc.x, cc.y)
	var g := int(g_prof.x)
	print("  neighbour %d centre lattice cell=(%d,%d), surface g=%d" % [neighbour, cc.x, cc.y, g])
	var gen_nb: Object = mod.call("spike_lod_generator", neighbour)   # neighbour-frozen (probe gen; lod0 == shipped)
	var gen_act: Object = mod.call("spike_active_generator")          # active-frozen
	# solid content at the neighbour's own centre (a 16^3 core straddling its surface)
	var solid_nb := _count_solid(gen_nb, Vector3i(cc.x - 8, g - 8, cc.y - 8), 16)
	_ok(solid_nb > 0, "A1: neighbour generator emits solid voxels at its own centre surface (%d/%d cells solid)" % [solid_nb, 16 * 16 * 16])
	# air beyond its ridges: a column pushed far outside the facet polygon (past a ridge) must mask to all AIR
	var far := _beyond_ridge_cell(neighbour, cc)
	var solid_beyond := _count_solid(gen_nb, Vector3i(far.x, g - 8, far.y - 0), 16)
	# probe a vertical stack across the whole plausible surface band, not just near g, to be sure it's masked
	var solid_beyond2 := _count_solid(gen_nb, Vector3i(far.x, TerrainConfig.SEA_LEVEL - 8, far.y), 16)
	_ok(solid_beyond == 0 and solid_beyond2 == 0, "A1: neighbour masks its OWN ridges — a beyond-ridge column is all AIR (%d + %d solid)" % [solid_beyond, solid_beyond2])
	# not a clone: neighbour field vs active field over the SAME lattice box → different hashes
	var h_nb := _box_hash(gen_nb, Vector3i(cc.x - 8, g - 8, cc.y - 8), 16)
	var h_act := _box_hash(gen_act, Vector3i(cc.x - 8, g - 8, cc.y - 8), 16)
	_ok(h_nb != h_act, "A1: neighbour field ≠ active field over the same lattice box (h_nb=%d, h_act=%d)" % [h_nb, h_act])

	# ---------- A2: instantiate the rotated neighbour terrain, attach the ONE global viewer, stream+mesh ----------
	var mem0 := OS.get_static_memory_usage()
	var built: Dictionary = mod.call("spike_rotated_neighbour", neighbour, 96)
	_ok(not built.is_empty(), "A2: spike_rotated_neighbour built a second VoxelTerrain under the rotated parent")
	if built.is_empty():
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1); return
	var nb_terrain: Node3D = built["terrain"]
	var nb_parent: Node3D = built["parent"]
	var carve_enabled: bool = bool(built["carve_enabled"])
	print("  A2: carve mesher = %s (patch 0004 %s)" % [
		"ENABLED (neighbour ridge planes pushed)" if carve_enabled else "DISABLED",
		"present" if carve_enabled else "absent — sentinels cube-fall-back"])
	# confirm the rotated terrain's LIVE global basis really is the det=+1 rotation (engine carries it rigidly)
	await process_frame
	var live_det := nb_terrain.global_transform.basis.determinant()
	_ok(absf(live_det - 1.0) < 1e-6, "A2: live rotated terrain global basis det=%.12f (carried rigidly, non-singular)" % live_det)

	# place the ONE global VoxelViewer at the neighbour centre-surface WORLD point → the neighbour localizes it
	# into ≈(cx,g,cz) in its own lattice and streams its populated core; the active terrain localizes the same
	# world point into a foreign box (harmless). Viewers are engine-global; one serves every terrain (§3.1).
	var w_arr: Array = FA.lattice_to_world64(neighbour, float(cc.x), float(g + 2), float(cc.y))
	var holder := Node3D.new()
	holder.position = Vector3(w_arr[0], w_arr[1], w_arr[2])
	get_root().add_child(holder)
	mod.call("attach_viewer", holder)
	print("  A2: viewer world pos = (%.1f, %.1f, %.1f)" % [w_arr[0], w_arr[1], w_arr[2]])

	# pump frames until the neighbour's core is meshed (LOCAL-space AABB per §3.3(a)) or a wall-clock cap
	var core_half := 24.0
	var core := AABB(Vector3(cc.x - core_half, g - core_half, cc.y - core_half), Vector3(core_half * 2, core_half * 2, core_half * 2))
	var t_start := Time.get_ticks_msec()
	var meshed := false
	var frames := 0
	while (Time.get_ticks_msec() - t_start) < 45000:
		await process_frame
		frames += 1
		if nb_terrain.has_method("is_area_meshed") and bool(nb_terrain.call("is_area_meshed", core)):
			meshed = true
			break
	var mesh_ms := Time.get_ticks_msec() - t_start
	_ok(meshed, "A2: rotated neighbour reports is_area_meshed over its streamed core (local AABB) — %d frames, %d ms" % [frames, mesh_ms])

	# per-terrain memory delta (best obtainable headless: CPU static-heap; GPU VRAM is a dummy renderer here)
	var mem1 := OS.get_static_memory_usage()
	var mem_delta := mem1 - mem0
	var stats: Dictionary = {}
	if nb_terrain.has_method("get_statistics"):
		stats = nb_terrain.call("get_statistics")
	var meshed_blocks := int(stats.get("updated_blocks", 0))
	print("  A2 MEMORY: per-terrain static-heap delta = %d bytes (%.2f MB); updated_blocks(last-cycle)=%d; view=96, mesh_block=32³" % [
		mem_delta, mem_delta / 1048576.0, meshed_blocks])
	print("  A2 MEMORY: NOTE headless uses the dummy renderer → GPU VRAM not measurable here; Part B gives per-mesh CPU byte sizing for FP-M1's pool ceiling.")
	# anti-vacuous: is_area_meshed(true) requires blocks to exist AND be loaded (voxel_terrain.cpp:2072). Combined
	# with A1 (the same frozen field emits SOLID content in this core) and a real heap allocation, the streaming
	# genuinely populated + meshed solid geometry under the rotation — not an empty-region trivial "meshed".
	_ok(mem_delta > 1_000_000, "A2: rotated streaming did substantive work (%.2f MB heap allocated → real data blocks + meshes, not a vacuous empty-region pass)" % (mem_delta / 1048576.0))

	# ---------- B0: LOD0 byte-identity gate (the stride change must not perturb LOD0) ----------
	var gen_probe_active: Object = mod.call("spike_lod_generator", active)   # stride ON, active facet
	var identical := _lod0_identical(gen_act, gen_probe_active, Vector3i(cc.x - 16, g - 16, cc.y - 16), 34)
	_ok(identical, "B0: LOD0 output byte-identical with stride enabled (probe gen == shipped gen over a 34³ block)")

	# ---------- B1: LOD-stride feasibility probe — generate_block + build_mesh for ℓ ∈ {0,1,2,3} ----------
	print("  --- B: LOD-stride probe (generate_block stride-2^ℓ → build_mesh, no terrain node) ---")
	var lib: Object = mod.call("spike_library")
	var probe_mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	if probe_mesher.has_method("set_library"):
		probe_mesher.call("set_library", lib)
	else:
		probe_mesher.set("library", lib)
	var gen_probe: Object = mod.call("spike_lod_generator", neighbour)
	var N := 32                              # interior mesh-block edge (matches the shipped mesh_block_size)
	var per_lod: Array = []                  # [{lod, region, gen_ms, mesh_ms, verts, tris, bytes}]
	for lod in range(4):
		var s := 1 << lod
		var region := N * s                   # LOD0 voxels this one mesh covers per axis
		# center the (N+2)³ padded buffer on the neighbour centre surface; origin = interior corner − stride
		var corner := Vector3i(cc.x - region / 2, g - region / 2, cc.y - region / 2)
		var origin := Vector3(corner.x - s, corner.y - s, corner.z - s)
		var buf: Object = ClassDB.instantiate("VoxelBuffer")
		buf.call("create", N + 2, N + 2, N + 2)
		buf.call("set_channel_depth", 0, 1)   # CHANNEL_TYPE, DEPTH_16_BIT (ARIDs exceed 8-bit)
		var tg0 := Time.get_ticks_usec()
		gen_probe.call("generate_block", buf, origin, lod)   # the script-exposed VoxelGenerator API
		var gen_us := Time.get_ticks_usec() - tg0
		var tm0 := Time.get_ticks_usec()
		var mesh: Mesh = probe_mesher.call("build_mesh", buf, [], {}) as Mesh   # the script-exposed VoxelMesher API
		var mesh_us := Time.get_ticks_usec() - tm0
		var verts := 0
		var tris := 0
		if mesh != null:
			for si in range(mesh.get_surface_count()):
				var arr: Array = mesh.surface_get_arrays(si)
				var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				verts += pv.size()
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				tris += idx.size() / 3
		var bytes := verts * _BYTES_PER_VERT + (tris * 3) * _BYTES_PER_INDEX
		per_lod.append({"lod": lod, "s": s, "region": region, "gen_us": gen_us, "mesh_us": mesh_us, "verts": verts, "tris": tris, "bytes": bytes})
		print("    ℓ=%d stride=%-2d region=%3d³ blk | gen=%6.2f ms  mesh=%6.2f ms | verts=%6d tris=%6d | mesh≈%7.1f KB (%d B)" % [
			lod, s, region, gen_us / 1000.0, mesh_us / 1000.0, verts, tris, bytes / 1024.0, bytes])
		_ok(mesh != null and verts > 0, "B1 ℓ=%d: generate_block+build_mesh produced a non-empty blocky mesh (%d verts)" % [lod, verts])

	# ---------- B2: the 512-block reach projection (the user's "voxel LOD to 512 blocks" question) ----------
	_project_512(per_lod)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ----------------------------------------------------------------------------------------------

## Count solid (non-air material) cells in an n³ box at LOD0, via generate_block on `gen` (the script API).
func _count_solid(gen: Object, corner: Vector3i, n: int) -> int:
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

## hash of an n³ TYPE box at LOD0 (for the not-a-clone diff).
func _box_hash(gen: Object, corner: Vector3i, n: int) -> int:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", n, n, n)
	buf.call("set_channel_depth", 0, 1)
	gen.call("generate_block", buf, Vector3(corner.x, corner.y, corner.z), 0)
	var vals := PackedInt32Array()
	for z in range(n):
		for y in range(n):
			for x in range(n):
				vals.append(int(buf.call("get_voxel", x, y, z, 0)))
	return hash(vals)

## byte-identity of two generators' LOD0 output over an n³ block.
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

## A lattice column pushed well beyond the neighbour's polygon (past a ridge) — guaranteed masked to AIR.
func _beyond_ridge_cell(fid: int, centre: Vector2i) -> Vector2i:
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	# push 64 cells past the far edge on both axes → outside the polygon on at least one ridge
	return Vector2i(hi.x + 64, hi.y + 64)

## Project "real voxel blocks out to 512 blocks across all in-range facets" from the measured per-ℓ numbers.
func _project_512(per_lod: Array) -> void:
	print("  --- B2: 512-block reach projection (facet edge from k=%d, R=%d) ---" % [FA.K, int(FA.R_BLOCKS)])
	var edge := (PI / 2.0 * FA.R_BLOCKS) / float(FA.K)      # blocks per facet edge
	var reach := 512.0
	var rings := reach / edge                               # facet-widths within 512 blocks
	# square patch (upper bound) and disk estimate of in-range facets
	var half := int(ceil(rings))
	var patch := (2 * half + 1) * (2 * half + 1)
	var disk := int(round(PI * rings * rings)) + 1
	print("    facet edge ≈ %.1f blocks; 512 reach ≈ %.2f facet-widths; in-range facets: square-patch ≤ %d, disk ≈ %d" % [
		edge, rings, patch, disk])
	# per-facet mesh cost at a given ℓ: a facet surface is ≈ (edge/N_lod0)² mesh-blocks of the measured region.
	# The measured region at ℓ covers region=N·2^ℓ LOD0 blocks per axis, i.e. ONE mesh spans region² of facet
	# surface. So a full facet needs ceil(edge/region)² such meshes. Use the measured per-mesh verts/tris/bytes.
	var band := [
		{"name": "near  (0–200 blk)", "lod": 0},
		{"name": "mid   (200–400)  ", "lod": 1},
		{"name": "far   (400–512)  ", "lod": 2},
	]
	print("    per-facet cost by screen-space-error band (measured per-mesh × meshes-per-facet):")
	var total_tris := 0
	var total_bytes := 0
	# distribute in-range facets across bands by ring shell area (rough): near ~ self+ring1, mid ~ ring2, far ~ ring3
	var facets_in_band := [9, 16, max(0, disk - 25)]        # ~self+8, ~16, remainder within the disk
	for i in range(band.size()):
		var lod: int = band[i]["lod"]
		var m: Dictionary = per_lod[lod]
		var region: int = m["region"]
		var meshes_per_facet := int(ceil(edge / float(region)))
		meshes_per_facet = meshes_per_facet * meshes_per_facet
		var facet_tris := int(m["tris"]) * meshes_per_facet
		var facet_bytes := int(m["bytes"]) * meshes_per_facet
		var nfac: int = facets_in_band[i]
		total_tris += facet_tris * nfac
		total_bytes += facet_bytes * nfac
		print("      %s ℓ=%d: %d meshes/facet × %d tris = %d tris/facet, %.1f KB/facet × %d facets = %.1f MB" % [
			band[i]["name"], lod, meshes_per_facet, int(m["tris"]), facet_tris, facet_bytes / 1024.0, nfac, (facet_bytes * nfac) / 1048576.0])
	print("    PROJECTED TOTAL (all-LOD-mesh, pessimistic) to cover ~%d in-range facets at SSE-selected ℓ: %d tris, %.1f MB mesh (CPU-side arrays)" % [
		disk, total_tris, total_bytes / 1048576.0])
	# fairer model (the review's option (a)+(b) split): the NEAR ring (adjacent facets) are LIVE VoxelTerrains
	# (pool cap 1 active + ≤4 neighbours, each ~15 MB from A2), NOT LOD meshes — so the LOD-mesh layer only
	# carries the MID+FAR bands (ℓ≥1). That removes the dominant ℓ0 term.
	var m0: Dictionary = per_lod[0]
	var region0: int = m0["region"]
	var mpf0 := int(ceil(edge / float(region0))); mpf0 = mpf0 * mpf0
	var near_ll_bytes := int(m0["bytes"]) * mpf0 * int(facets_in_band[0])
	var lod_layer_bytes := total_bytes - near_ll_bytes
	var lod_layer_tris := total_tris - int(m0["tris"]) * mpf0 * int(facets_in_band[0])
	var pool_bytes := 5 * 15 * 1048576                    # 1 active + 4 neighbour live terrains @ ~15 MB (A2)
	print("    FAIRER SPLIT: near ring = live terrains (pool ≤5 × ~15 MB = %d MB); LOD-mesh layer (ℓ≥1) = %d tris, %.1f MB → combined %.1f MB" % [
		pool_bytes / 1048576, lod_layer_tris, lod_layer_bytes / 1048576.0, (pool_bytes + lod_layer_bytes) / 1048576.0])
	# verdict thresholds (web budget): triangles and mesh MB that a threaded WebGL2 build sustains.
	var tris_ok := total_tris < 6_000_000            # ~6M tris is a comfortable static-geometry ceiling on web
	var mb_ok := (total_bytes / 1048576.0) < 256.0   # keep the LOD cache well under the never-OOM heap ceiling
	_ok(tris_ok, "B2: projected 512-reach triangle budget %d < 6.0M (fits web static-geometry ceiling)" % total_tris)
	_ok(mb_ok, "B2: projected 512-reach mesh memory %.1f MB < 256 MB (fits the never-OOM heap ceiling with LRU headroom)" % (total_bytes / 1048576.0))
