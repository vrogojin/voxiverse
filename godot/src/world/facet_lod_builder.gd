class_name FacetLodBuilder
extends RefCounted
## COSMOS FP-M2a (docs/COSMOS-FP-M2-DESIGN.md §4) — the off-terrain LOD build PRIMITIVE. ONE persistent
## background GDScript Thread turns a facet's LOD-ℓ slab into ArrayMeshes ENTIRELY off the voxel worker pool,
## productizing the FP-R0 probe recipe:
##   per-facet FROZEN probe generator (module_world.lod_probe_generator(fid)) → generate_block(buffer, origin, ℓ)
##   at stride 2^ℓ → a builder-owned VoxelMesherBlocky.build_mesh(buffer, [], {}) → ArrayMesh.
## No scene consumer at M2a (verify-only, dead code behind CubeSphere.FP_M2_LOD). FacetLodMesher (M2b) owns one
## of these, drains its done-queue, and applies the finished meshes under PlanetRoot on a bounded per-frame
## budget — the builder NEVER creates or attaches a Node (that is a main-thread step, §4.4).
##
## THREAD-SAFETY (§4.3): the probe generator + the mesher's library + the FacetAtlas/TerrainConfig tables it
## reads are all FROZEN before the thread runs; the builder is one more pure reader (proven safe for 4+ voxel
## workers). Every per-job object (VoxelBuffer, ArrayMesh) is thread-local. The generator is created/cached on
## the MAIN thread (it compiles source + freezes appearance tables) and only READ on the builder thread.

# ---- policy consts (M2a scope; §5's full const block lands with FacetLodMesher in M2b) ----
const LOD_MAX_TIER := 3            # shipped LOD tiers ℓ∈{1..3}; the quad is the ℓ=∞ tier, ℓ0 is live-terrain only
const LOD_FLOOR_Y := -24          # §4.2: proven min-visible-surface LOWER bound (mirror of MAX_SURFACE_Y's upper
                                  # bound). Below this the bottom pad generates solid → no bottom faces → no holes.
const TILE_MAX := 32              # interior buffer edge cap (matches the shipped mesh_block_size); tile when exceeded
const _BYTES_PER_VERT := 64       # blocky vertex: pos12+normal12+uv8+tangent16+color16 (the FP-R0 byte model)
const _BYTES_PER_INDEX := 4

# ---- state ----
var _mod: Object = null           # module_world (library + probe-generator factory)
var _mesher: Object = null        # builder-owned VoxelMesherBlocky sharing the baked library
var _gen_cache: Dictionary = {}   # fid -> frozen probe generator (built lazily on the MAIN thread)
var _thread: Thread = null
var _sem: Semaphore = null
var _queue_mutex: Mutex = null
var _queue: Array = []            # pending jobs (main → builder)
var _done_mutex: Mutex = null
var _done: Array = []             # finished tiles (builder → main)
var _running := false
var _build_count := 0            # diagnostics: total tile builds (guarded by _done_mutex)

## Wire the library + start the persistent builder thread. Returns false (safe no-op) when the flag is off or
## the module/mesher class is unavailable — the caller then simply never uses the LOD path.
func setup(module_world: Object) -> bool:
	if not CubeSphere.FP_M2_LOD:
		return false
	if not ClassDB.class_exists("VoxelMesherBlocky"):
		return false
	if module_world == null:
		return false
	_mod = module_world
	var lib: Object = module_world.call("lod_library")
	if lib == null:
		return false
	_mesher = ClassDB.instantiate("VoxelMesherBlocky")
	if _mesher == null:
		return false
	if _mesher.has_method("set_library"):
		_mesher.call("set_library", lib)
	else:
		_mesher.set("library", lib)
	_sem = Semaphore.new()
	_queue_mutex = Mutex.new()
	_done_mutex = Mutex.new()
	_queue = []
	_done = []
	_gen_cache = {}
	_build_count = 0
	_running = true
	_thread = Thread.new()
	_thread.start(_thread_loop)
	return true

## Is the builder live (thread started)? Cheap predicate for the caller / gate.
func is_running() -> bool:
	return _running and _thread != null

## The per-facet frozen probe generator (created once on the MAIN thread, cached). null if the module refuses.
func _generator_for(fid: int) -> Object:
	if _gen_cache.has(fid):
		return _gen_cache[fid]
	var gen: Object = _mod.call("lod_probe_generator", fid)
	_gen_cache[fid] = gen
	return gen

## Tile facet `fid`'s domain slab (xz = dom_min..dom_max, y = [LOD_FLOOR_Y, MAX_SURFACE_Y+max_above]) into
## ≤TILE_MAX³ LOD-stride blocks and enqueue them on the builder thread. MAIN thread only (touches _gen_cache).
## Each tile buffer is (nx+2, ny+2, nz+2) with origin = tile_corner − s so the 1-cell pad samples the
## neighbouring megablocks (correct face occlusion at same-ℓ tile seams). Returns the number of tiles enqueued.
func enqueue_facet(fid: int, lod: int, epoch: int = 0) -> int:
	if not is_running():
		return 0
	if lod < 1 or lod > LOD_MAX_TIER:
		return 0
	var gen: Object = _generator_for(fid)
	if gen == null:
		return 0
	var s := 1 << lod
	var dmin: Vector2i = FacetAtlas.dom_min(fid)
	var dmax: Vector2i = FacetAtlas.dom_max(fid)
	var max_above: int = max(TreeGen.MAX_ABOVE_SURFACE, TerrainConfig.SNOW_FILL_MAX_CELLS)
	var y_lo := LOD_FLOOR_Y
	var y_hi := TerrainConfig.MAX_SURFACE_Y + max_above
	var tile_span := TILE_MAX * s         # LOD0 lattice cells one full tile covers per axis
	var jobs := 0
	var tz := dmin.y
	while tz < dmax.y:
		var nz: int = mini(TILE_MAX, int(ceil(float(dmax.y - tz) / float(s))))
		var tx := dmin.x
		while tx < dmax.x:
			var nx: int = mini(TILE_MAX, int(ceil(float(dmax.x - tx) / float(s))))
			var ty := y_lo
			while ty < y_hi:
				var ny: int = mini(TILE_MAX, int(ceil(float(y_hi - ty) / float(s))))
				if nx > 0 and ny > 0 and nz > 0:
					_enqueue_one(fid, lod, s, gen, tx, ty, tz, nx, ny, nz, epoch)
					jobs += 1
				ty += tile_span
			tx += tile_span
		tz += tile_span
	return jobs

## Enqueue a SINGLE tile: interior edge `n` (≤ TILE_MAX) at LOD0 lattice corner (cx,cy,cz), tier `lod`. The raw
## build primitive that enqueue_facet is the whole-slab convenience over; the gate uses it for centred
## surface-straddling tiles. MAIN thread (touches _gen_cache). Returns false if the flag/module refuse.
func enqueue_tile(fid: int, lod: int, cx: int, cy: int, cz: int, n: int, epoch: int = 0) -> bool:
	if not is_running() or lod < 1 or lod > LOD_MAX_TIER or n <= 0:
		return false
	var gen: Object = _generator_for(fid)
	if gen == null:
		return false
	var e: int = mini(n, TILE_MAX)
	_enqueue_one(fid, lod, 1 << lod, gen, cx, cy, cz, e, e, e, epoch)
	return true

## COSMOS FP-M2b (§7.4) — enqueue a RIDGE-APRON job for the LOD↔LOD seam `slot` of owner facet `owner_fid`
## (ownership = the LOWER fid of the pair; the caller enforces it). The apron is a terrain-coloured strip built
## from the welded ring line at pitch `s_max` (the coarser side's stride), authored in the owner facet's lattice
## coords so it rides PlanetRoot rigidly with every other LOD mesh. Built on THIS builder thread as a job
## appendix — pure frozen-atlas data + profile_at_dir + FarPalette (all warmed before the thread runs), the same
## thread-safety class as generate_block. Returns false if the flag/thread is unavailable. MAIN thread only.
func enqueue_apron(owner_fid: int, slot: int, s_max: int) -> bool:
	if not is_running() or slot < 0 or slot > 3 or s_max < 2:
		return false
	var job := {"kind": "apron", "fid": owner_fid, "slot": slot, "s_max": s_max}
	_queue_mutex.lock()
	_queue.append(job)
	_queue_mutex.unlock()
	_sem.post()
	return true

func _enqueue_one(fid: int, lod: int, s: int, gen: Object, tx: int, ty: int, tz: int, nx: int, ny: int, nz: int, epoch: int = 0) -> void:
	var job := {
		"fid": fid, "lod": lod, "s": s, "gen": gen, "epoch": epoch,
		"tile": Vector3i(tx, ty, tz),          # LOD0 lattice corner (interior cell 0 origin)
		"ox": tx - s, "oy": ty - s, "oz": tz - s,   # buffer origin: 1-cell pad below the corner
		"nx": nx, "ny": ny, "nz": nz,
	}
	_queue_mutex.lock()
	_queue.append(job)
	_queue_mutex.unlock()
	_sem.post()

## The persistent builder loop — waits on the semaphore, builds ONE tile per wake, hands it to the done-queue.
## Never spawn-per-job; exits cleanly on shutdown (running=false + a wake post).
func _thread_loop() -> void:
	while true:
		_sem.wait()
		if not _running:
			return
		var job = null
		_queue_mutex.lock()
		if not _queue.is_empty():
			job = _queue.pop_front()
		_queue_mutex.unlock()
		if job == null:
			continue
		var res: Dictionary = _build_apron(job) if job.get("kind", "tile") == "apron" else _build_job(job)
		_done_mutex.lock()
		_done.append(res)
		_build_count += 1
		_done_mutex.unlock()

## Build ONE tile → ArrayMesh, entirely on the builder thread (pure reader). Records the thread id so the gate
## can prove it ran OFF the main thread. Buffer channel-depth 16-bit because ARIDs exceed 8 bits (FP-R0 recipe).
func _build_job(job: Dictionary) -> Dictionary:
	var nx: int = job["nx"]; var ny: int = job["ny"]; var nz: int = job["nz"]
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", nx + 2, ny + 2, nz + 2)
	buf.call("set_channel_depth", 0, 1)   # CHANNEL_TYPE, DEPTH_16_BIT
	var gen: Object = job["gen"]
	gen.call("generate_block", buf, Vector3(job["ox"], job["oy"], job["oz"]), job["lod"])
	var mesh: Mesh = _mesher.call("build_mesh", buf, [], {}) as Mesh
	var verts := 0
	var tris := 0
	if mesh != null:
		for si in range(mesh.get_surface_count()):
			var arr: Array = mesh.surface_get_arrays(si)
			var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			verts += pv.size()
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			tris += int(idx.size() / 3)
	return {
		"fid": job["fid"], "lod": job["lod"], "epoch": job.get("epoch", 0), "tile": job["tile"], "mesh": mesh,
		"verts": verts, "tris": tris, "bytes": verts * _BYTES_PER_VERT + (tris * 3) * _BYTES_PER_INDEX,
		"thread_id": OS.get_thread_caller_id(),
	}

## Build ONE ridge apron → a vertex-coloured ArrayMesh in the owner facet's LATTICE coords (§7.4), entirely on the
## builder thread (pure reader: frozen seam data + profile_at_dir + FarPalette, all warmed before the thread ran).
## Two quad strips (one per side, ridge line inward s_max) with the top snapped UP to the s_max megablock grid
## (ceil — overlap-not-gap) plus a short outer skirt tucking under the megablock walls, so a LOD↔LOD ridge shows
## NO hairline. Winding-agnostic (the applied material is CULL_DISABLED, like the far ring — the dihedral turn can
## flip a strip). Colours track FarPalette so the apron reads as the same terrain the neighbouring quads/LOD do.
func _build_apron(job: Dictionary) -> Dictionary:
	var owner: int = job["fid"]
	var slot: int = job["slot"]
	var s_max: int = job["s_max"]
	var fs := float(s_max)
	var ring: Array = FacetAtlas.seam_ring(owner, slot)
	var r0: Vector3 = ring[0]
	var r1: Vector3 = ring[1]
	var pl: Vector4 = FacetAtlas.seam_plane(owner, slot)                 # own(x,y,z)=A·x+B·y+C·z+D ≥ 0 interior
	var inward := Vector3(pl.x, 0.0, pl.z)                               # +own_dist horizontal (into owner) in lattice xz
	if inward.length() < 1.0e-9:
		inward = Vector3(1.0, 0.0, 0.0)
	inward = inward.normalized()
	var L0: Array = FacetAtlas.world_to_lattice64(owner, r0.x, r0.y, r0.z)
	var L1: Array = FacetAtlas.world_to_lattice64(owner, r1.x, r1.y, r1.z)
	var p0 := Vector3(float(L0[0]), float(L0[1]), float(L0[2]))
	var p1 := Vector3(float(L1[0]), float(L1[1]), float(L1[2]))
	var seglen := (p1 - p0).length()
	var nseg: int = maxi(1, int(ceil(seglen / fs)))
	var sea := TerrainConfig.SEA_LEVEL
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var down := Vector3(0.0, fs, 0.0)
	for i in range(nseg):
		var t0 := float(i) / float(nseg)
		var t1 := float(i + 1) / float(nseg)
		var a0 := p0.lerp(p1, t0)
		var a1 := p0.lerp(p1, t1)
		var w0 := r0.lerp(r1, t0); var d0 := w0.normalized()
		var w1 := r0.lerp(r1, t1); var d1 := w1.normalized()
		var prof0: Vector4 = TerrainConfig.profile_at_dir(d0.x, d0.y, d0.z, FacetAtlas.R_BLOCKS)
		var prof1: Vector4 = TerrainConfig.profile_at_dir(d1.x, d1.y, d1.z, FacetAtlas.R_BLOCKS)
		var g0 := int(prof0.x); var g1 := int(prof1.x)
		var top0 := float(int(ceil(float(g0) / fs)) * s_max)            # snap UP to the s_max megablock top grid
		var top1 := float(int(ceil(float(g1) / fs)) * s_max)
		var c0 := FarPalette.color_for(g0, int(prof0.y), prof0.w, g0 <= sea)
		var c1 := FarPalette.color_for(g1, int(prof1.y), prof1.w, g1 <= sea)
		var rA0 := Vector3(a0.x, top0, a0.z)                            # ridge, raised to the local surface top
		var rA1 := Vector3(a1.x, top1, a1.z)
		var oO0 := rA0 + inward * fs; var oO1 := rA1 + inward * fs      # owner-side outer (+own_dist s_max)
		var nO0 := rA0 - inward * fs; var nO1 := rA1 - inward * fs      # neighbour-side outer (−own_dist s_max)
		_apron_quad(st, rA0, oO0, oO1, rA1, c0, c0, c1, c1)            # owner top strip
		_apron_quad(st, nO0, rA0, rA1, nO1, c0, c0, c1, c1)            # neighbour top strip
		_apron_quad(st, oO0, oO0 - down, oO1 - down, oO1, c0, c0, c1, c1)  # owner outer skirt
		_apron_quad(st, nO0, nO0 - down, nO1 - down, nO1, c0, c0, c1, c1)  # neighbour outer skirt
	var mesh: ArrayMesh = st.commit()
	var verts := 0
	var tris := 0
	if mesh != null and mesh.get_surface_count() > 0:
		var arr: Array = mesh.surface_get_arrays(0)
		var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		verts = pv.size()
		tris = int(verts / 3)     # SurfaceTool triangle soup (no index() call) → ARRAY_INDEX is null; verts = 3·tris
	return {
		"fid": owner, "kind": "apron", "slot": slot, "s_max": s_max, "lod": 0, "tile": Vector3i.ZERO,
		"mesh": mesh, "verts": verts, "tris": tris,
		"bytes": verts * _BYTES_PER_VERT + (tris * 3) * _BYTES_PER_INDEX,
		"thread_id": OS.get_thread_caller_id(),
	}

## Two colour-interpolated triangles (a,b,c)+(a,c,d) for an apron quad — sample-0 verts take (ca,cb), sample-1 (cc,cd).
func _apron_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	st.set_color(ca); st.add_vertex(a)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cc); st.add_vertex(c)
	st.set_color(ca); st.add_vertex(a)
	st.set_color(cc); st.add_vertex(c)
	st.set_color(cd); st.add_vertex(d)

## Pop all finished tiles (MAIN thread). M2b applies these under a per-frame budget; the M2a gate collects them.
func drain_done() -> Array:
	if _done_mutex == null:
		return []
	_done_mutex.lock()
	var out := _done
	_done = []
	_done_mutex.unlock()
	return out

## Total tile builds completed since setup (diagnostics; G-M2-XPD in M2d asserts no rebuilds across a crossing).
func build_count() -> int:
	if _done_mutex == null:
		return 0
	_done_mutex.lock()
	var n := _build_count
	_done_mutex.unlock()
	return n

## Pending + in-flight job estimate (queued jobs not yet drained). MAIN thread.
func queued() -> int:
	if _queue_mutex == null:
		return 0
	_queue_mutex.lock()
	var n := _queue.size()
	_queue_mutex.unlock()
	return n

## Stop the thread and join. Wakes a waiting loop (running=false); a mid-build tile finishes first, then exits.
func shutdown() -> void:
	if _thread == null:
		return
	_running = false
	if _sem != null:
		_sem.post()
	_thread.wait_to_finish()
	_thread = null
