extends SceneTree
## P1-STICKY perf probe — measures the FacetFarRing SYNC rebuild cost across a crossing sequence, so the sticky
## delta (bigger backstop set → bigger per-crossing rebuild) is quantified with the real T2e build/swap timer, NOT
## by eye. Drives the WORST case: FP_FARRING_FAST_REBUILD on (deployed assembler) + ASYNC off (force the main-thread
## sync fallback), FULL_COVER on. Run once with FP_TIER_STICKY_BACKSTOP true and once false; compare.
##
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_FARRING_FULL_COVER := false/const FP_FARRING_FULL_COVER := true/;\
##           s/const FP_FARRING_FAST_REBUILD := false/const FP_FARRING_FAST_REBUILD := true/' godot/src/cosmos/cube_sphere.gd
##   # (+ optionally FP_TIER_STICKY_BACKSTOP true)  then:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/probe_sticky_perf.gd

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

func _initialize() -> void:
	print("=== probe_sticky_perf (far-ring sync rebuild cost across crossings) ===")
	print("  flags: FACETED=%s FULL_COVER=%s FAST=%s ASYNC=%s STICKY=%s BACKSTOP_CELLS=%d STICKY_RING1_MAX=%d" % [
		str(CubeSphere.FACETED), str(CubeSphere.FP_FARRING_FULL_COVER), str(CubeSphere.FP_FARRING_FAST_REBUILD),
		str(CubeSphere.FP_FARRING_ASYNC_REBUILD), str(CubeSphere.FP_TIER_STICKY_BACKSTOP),
		CubeSphere.BACKSTOP_CELLS, CubeSphere.STICKY_RING1_MAX])
	TerrainConfig.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)

	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("take_events")   # discard the setup build event

	# Build a chain of seam-connected facets to cross through (a realistic walk across faces).
	var chain := _crossing_chain(active, 8)
	print("  crossing chain (%d facets): %s" % [chain.size(), str(chain)])

	var max_build := 0.0
	var sum_build := 0.0
	var max_swap := 0.0
	var n := 0
	var prev := active
	for to in chain:
		# The exact WorldManager crossing wiring: set_active(to) then sync the pool exclusion to the new neighbours.
		ring.call("set_active", to)
		var pool := _pool_for(to)          # active's live pool = its seam neighbours (mirrors pool_neighbour_fids)
		ring.call("set_pool_excluded", pool)
		ring.call("force_rebuild")         # SYNC main-thread rebuild (what the deferred _process would do off-frame)
		var evs: Array = ring.call("take_events")
		for e in evs:
			var b := float(e.get("build_ms", 0.0))
			var s := float(e.get("swap_ms", 0.0))
			max_build = maxf(max_build, b)
			sum_build += b
			max_swap = maxf(max_swap, s)
			n += 1
			print("    cross %d->%d : build=%.2fms swap=%.2fms verts=%d | sticky=%d backstop_cache=%d emitted_backstop=%d" % [
				prev, to, b, s, int(e.get("verts", 0)),
				int(ring.call("sticky_count")), int(ring.call("backstop_cache_size")), _emitted_backstop_count(ring, pool, to)])
		prev = to

	print("  ---- SYNC SUMMARY ----")
	print("  crossings=%d  max_build=%.2fms  avg_build=%.2fms  max_swap=%.2fms" % [n, max_build, (sum_build / maxf(1, n)), max_swap])
	print("  final sticky_count=%d  backstop_cache_size=%d" % [int(ring.call("sticky_count")), int(ring.call("backstop_cache_size"))])
	ring.free()

	# ---- ASYNC path: the DEPLOYED config (off-thread build; only the SWAP is main-thread). This is the live-relevant
	# cost. Measure the main-thread swap_ms (add_surface_from_arrays of the whole visible mesh) with the current STICKY.
	if OS.get_processor_count() > 1:
		_measure_async(active, chain)
	else:
		print("  (async path skipped: single core)")
	quit(0)

## The async path's ONLY main-thread cost is _swap_in_arrays → add_surface_from_arrays(N verts). Micro-benchmark it at
## the two committed sizes (sticky-off ≈173k, sticky-on ≈183k) so the sticky delta on the MAIN thread is bounded directly.
func _measure_async(_active: int, _chain: PackedInt32Array) -> void:
	print("  ---- ASYNC main-thread swap microbench (add_surface_from_arrays) ----")
	for verts in [173088, 183168]:
		var t := _time_surface_upload(verts)
		print("    add_surface_from_arrays(%d verts): %.2f ms (median of 5)" % [verts, t])
	# Warm-path spike check: a single plain (non-envelope) dense backstop cache build, the main-thread op sticky
	# enlarges (7 more facets). Must be << WARM_BUDGET_MS so _warm_front never overruns on one facet.
	var ring2: Node3D = FFR.new()
	get_root().add_child(ring2)
	ring2.call("setup", _active)
	var sample := _worst_relief_facet()
	var t0 := Time.get_ticks_usec()
	ring2.call("_ensure_backstop_cached", sample)
	var warm_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("    single plain dense-cache build (facet %d): %.2f ms  (WARM_BUDGET=%.1f ms)" % [sample, warm_ms, FFR.WARM_BUDGET_MS])
	ring2.free()

func _time_surface_upload(verts: int) -> float:
	var pos := PackedVector3Array(); pos.resize(verts)
	var col := PackedColorArray(); col.resize(verts)
	var nrm := PackedVector3Array(); nrm.resize(verts)
	for i in range(verts):
		pos[i] = Vector3(float(i % 97), float(i % 31), float(i % 53))
		col[i] = Color(0.4, 0.6, 0.3)
		nrm[i] = Vector3(0, 1, 0)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_NORMAL] = nrm
	var samples := []
	for _r in range(5):
		var t0 := Time.get_ticks_usec()
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	samples.sort()
	return samples[2]

## The set of facets a live pool would exclude for active `fid`: itself + its front-visible seam neighbours (mirrors
## module_world.pool_neighbour_fids at POOL_MAX_NEIGHBOURS=4). This is what set_pool_excluded receives each crossing.
func _pool_for(fid: int) -> PackedInt32Array:
	var out := PackedInt32Array([fid])
	for slot in range(4):
		var n := FA.seam_neighbour(fid, slot)
		if n >= 0 and not out.has(n):
			out.append(n)
	return out

## A chain of `count` facets, each a seam neighbour of the previous (a walk crossing seams).
func _crossing_chain(start: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var cur := start
	var visited := {start: true}
	for _i in range(count):
		var nxt := -1
		for slot in range(4):
			var n := FA.seam_neighbour(cur, slot)
			if n >= 0 and not visited.has(n):
				nxt = n; break
		if nxt < 0:
			break
		visited[nxt] = true
		out.append(nxt)
		cur = nxt
	return out

## The highest-relief facet (worst dense-cache build cost) — a coarse 3×3 relief scan over all facets.
func _worst_relief_facet() -> int:
	var k := FA.K
	var best_fid := 0
	var best := -1
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				var lo := 1 << 30
				var hi := -(1 << 30)
				for ci in range(4):
					var c := FA.facet_planar_corner(fid, ci)
					var d := Vector3(c[0], c[1], c[2]).normalized()
					var g := int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x)
					lo = mini(lo, g); hi = maxi(hi, g)
				if hi - lo > best:
					best = hi - lo; best_fid = fid
	return best_fid

func _emitted_backstop_count(ring: Node3D, pool: PackedInt32Array, active: int) -> int:
	# How many pool facets are drawn SUNK in the committed mesh (the make-before-break property).
	var c := 0
	for f in pool:
		if bool(ring.call("is_emitted_backstop", int(f))):
			c += 1
	return c
