extends SceneTree
## COSMOS far-ring full coverage gate (docs/COSMOS-FARRING-COVERAGE-DESIGN.md §6) — proves the "see-through gap" fix.
## The shipped far ring excludes the active facet + the live-pool `_excluded` neighbours, so beyond the ~128-block near
## disk on those facets the camera sees straight through to the opposite inner side of the globe. FP_FARRING_FULL_COVER
## draws ALL front-hemisphere facets, sinking the active + excluded ("backstop") facets radially so the opaque near
## voxels overdraw them. This gate runs headless with FACETED sed-toggled true and BRANCHES on the coverage flag:
##
##   flag ON  — G-FRC-COVER  every front-hemisphere facet INCLUDING the active + `_excluded` set is emitted (no hole).
##              G-FRC-NOPOKE the sunk backstop stays strictly below the near blocky surface for a mountain-foothill
##                           spawn sweep (per-block sampling) — the BACKSTOP_SINK/BACKSTOP_CELLS tuning oracle. If this
##                           fails in mountains, raise BACKSTOP_CELLS to 32 (keep sink 6) and re-run (design §3/§7).
##              G-FRC-BOUND  triangle_count ≤ whole-planet cap + the dense backstop cache ≤ 5 facets (NEVER-OOM: no
##                           growth with walk distance).
##   flag OFF — the byte-identity complement: the active + `_excluded` set are ABSENT from the emitted set and no
##              backstop cache is populated, so the "flag off ⇒ shipped ring" claim is checked in-process too.
##
## RUN (flag ON):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_FARRING_FULL_COVER := false/const FP_FARRING_FULL_COVER := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_farring_cover.gd
##   then REVERT the sed. RUN (flag OFF complement): sed FACETED only. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_farring_cover (far-ring full coverage: the see-through-gap fix) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	print("  atlas: k=%d, R=%.0f, active(spawn)=%d, near_render_radius=%d, FULL_COVER=%s, sink(derived)=%.2f, BACKSTOP_CELLS=%d" % [
		FA.K, FA.R_BLOCKS, active, TerrainConfig.near_render_radius(),
		str(CubeSphere.FP_FARRING_FULL_COVER), TierPlace.backstop_sink(), CubeSphere.BACKSTOP_CELLS])
	if CubeSphere.FP_FARRING_FULL_COVER:
		_gate_cover_on(active)
		_gate_nopoke(active)
		_gate_bound(active)
		_gate_parity(active)
	else:
		_gate_cover_off(active)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- shared geometry helpers (independent of the ring's private methods, so the gate is a true oracle) ---

## Facet centre direction — the average of the 4 planarized corners, normalized (matches FacetFarRing._facet_centre_dir).
func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(c[0], c[1], c[2])
	return s.normalized()

## Direction of facet-param (s,t) on `fid`: bilerp of the planar corners, normalized — the SAME mapping the ring uses
## to build its heightmap grid, so near g and the backstop grid are sampled in one consistent parameterization.
func _col_dir(fid: int, s: float, t: float) -> Vector3:
	var c0 := FA.facet_planar_corner(fid, 0)
	var c1 := FA.facet_planar_corner(fid, 1)
	var c2 := FA.facet_planar_corner(fid, 2)
	var c3 := FA.facet_planar_corner(fid, 3)
	var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
	var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
	var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
	return Vector3(bx, by, bz).normalized()

func _g_at(d: Vector3) -> int:
	return int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x)

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

## Arc distance (blocks) between two surface directions on the planet of radius R_BLOCKS.
func _arc(a: Vector3, b: Vector3) -> float:
	return FA.R_BLOCKS * acos(clampf(a.dot(b), -1.0, 1.0))

# ---------- G-FRC-COVER (flag ON): no front-hemisphere hole ----------
func _gate_cover_on(active: int) -> void:
	print("  --- G-FRC-COVER: every front-hemisphere facet (incl. active + excluded) is emitted ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	# exercise the excluded-as-backstop path: mark two edge neighbours live-pool-excluded (a crossing/pool state).
	var neigh := _edge_neighbours(active)
	ring.call("set_pool_excluded", neigh)
	ring.call("force_rebuild")
	var vis: PackedInt32Array = ring.call("visible_fids")
	var visset := {}
	for f in vis:
		visset[int(f)] = true
	# THE FIX: the active facet + every excluded neighbour are now drawn (previously the hole).
	_ok(visset.has(active) and bool(ring.call("is_emitted", active)) and bool(ring.call("is_backstop", active)),
		"G-FRC-COVER: active facet %d emitted as a backstop (was the hole)" % active)
	for n in neigh:
		var nf := int(n)
		_ok(visset.has(nf) and bool(ring.call("is_emitted", nf)) and bool(ring.call("is_backstop", nf)),
			"G-FRC-COVER: excluded neighbour %d emitted as a backstop" % nf)
	# emitted set == visible set (force_rebuild emits exactly visible_fids).
	_ok(int(ring.call("emitted_count")) == vis.size(),
		"G-FRC-COVER: emitted set == visible set (%d facets)" % vis.size())
	# no front-hemisphere hole: every CLEARLY-front facet (cd·nrm ≥ eps, off the terminator to avoid float flake) is drawn.
	var nrm := FA.facet_normal64(active)
	var nv := Vector3(nrm[0], nrm[1], nrm[2])
	var k := FA.K
	var checked := 0
	var missing := 0
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if _centre_dir(fid).dot(nv) >= 1.0e-4:
					checked += 1
					if not visset.has(fid):
						missing += 1
	_ok(missing == 0, "G-FRC-COVER: all %d clearly-front-hemisphere facets emitted (%d holes)" % [checked, missing])
	ring.free()

# ---------- G-FRC-COVER complement (flag OFF): byte-identity structural claim ----------
func _gate_cover_off(active: int) -> void:
	print("  --- G-FRC-COVER (flag off): active + excluded ABSENT (shipped ring, byte-identical) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var neigh := _edge_neighbours(active)
	ring.call("set_pool_excluded", neigh)
	ring.call("force_rebuild")
	var vis: PackedInt32Array = ring.call("visible_fids")
	var visset := {}
	for f in vis:
		visset[int(f)] = true
	_ok(not visset.has(active), "byte-identity: active facet %d ABSENT from the emitted set" % active)
	for n in neigh:
		_ok(not visset.has(int(n)), "byte-identity: excluded neighbour %d ABSENT from the emitted set" % int(n))
	# a non-excluded clearly-front neighbour of the active facet IS drawn (the ring still covers the rest).
	var second := _edge_neighbours(int(neigh[0]))     # a facet one further out, not in the excluded set
	var probe := -1
	var nrm := FA.facet_normal64(active)
	var nv := Vector3(nrm[0], nrm[1], nrm[2])
	for f in second:
		var ff := int(f)
		if ff != active and not neigh.has(ff) and _centre_dir(ff).dot(nv) >= 1.0e-4:
			probe = ff
			break
	_ok(probe >= 0 and visset.has(probe), "byte-identity: a non-excluded front facet %d is still emitted" % probe)
	_ok(int(ring.call("backstop_cache_size")) == 0, "byte-identity: no backstop cache populated (flag off ⇒ zero cost)")
	ring.free()

# ---------- G-FRC-NOPOKE (flag ON): the sunk backstop never rises above the near surface ----------
func _gate_nopoke(active: int) -> void:
	print("  --- G-FRC-NOPOKE: sunk backstop < near surface (mountain-foothill spawn sweep, per-block) ---")
	var cells := CubeSphere.BACKSTOP_CELLS
	var sink := TierPlace.backstop_sink()               # the DERIVED sink actually applied at emit (frac × cell size)
	var near := float(TerrainConfig.near_render_radius())
	var edge_blocks := (PI * 0.5 * FA.R_BLOCKS) / float(FA.K)     # ≈ 201 blocks per facet edge
	# spawn sweep: the active facet + the three worst-relief (mountainous) facets — the worst chord error lives there.
	var sweep := _worst_relief_facets(3)
	if not sweep.has(active):
		sweep.append(active)
	var worst := -1.0e30
	var worst_fid := -1
	var worst_near := 0
	var worst_bs := 0.0
	for fid in sweep:
		var g := _coarse_g_grid(fid, cells)               # (cells+1)² sampled backstop heights
		var centre := _centre_dir(fid)
		var steps := int(ceil(edge_blocks))               # ~per-block sampling along each facet axis
		for js in range(steps + 1):
			var t := float(js) / float(steps)
			for iss in range(steps + 1):
				var s := float(iss) / float(steps)
				var d := _col_dir(fid, s, t)
				if _arc(centre, d) > near:                # only columns the near disk actually covers
					continue
				var g_near := _g_at(d)
				var g_bs := _bilerp_cell(g, cells, s, t)  # coarse backstop height interpolated at this column
				var margin := (g_bs - sink) - float(g_near)   # want < 0: backstop strictly below near
				if margin > worst:
					worst = margin
					worst_fid = fid
					worst_near = g_near
					worst_bs = g_bs
	# margin < 0 ⇔ (g_bs - g_near) < sink everywhere: the chord error is cleared by the sink.
	_ok(worst < 0.0,
		"G-FRC-NOPOKE: backstop below near everywhere (worst margin %.2f blocks < 0; chord err %.2f vs sink %.1f, cells=%d, facet %d, near g=%d bs g=%.1f)"
		% [worst, worst + sink, sink, cells, worst_fid, worst_near, worst_bs])
	print("    NOPOKE worst chord error = %.2f blocks (need < derived sink = %.2f, margin %.2f); if it exceeds, raise BACKSTOP_CELLS to 32" % [worst + sink, sink, -worst])

# ---------- G-FRC-BOUND (flag ON): NEVER-OOM — bounded tris + bounded backstop cache ----------
func _gate_bound(active: int) -> void:
	print("  --- G-FRC-BOUND: bounded triangle count + backstop cache (no growth with walk distance) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	# a full pool-excluded set at the hard cap (POOL_MAX_NEIGHBOURS): the worst-case backstop count is 1 active + the cap.
	var excl := _edge_neighbours(active)
	ring.call("set_pool_excluded", excl)
	ring.call("force_rebuild")
	var tris := int(ring.call("triangle_count"))
	# whole-planet CELLS cap (6·K²·CELLS²·2) + the ≤5 dense backstop facets at BACKSTOP_CELLS — an upper bound independent
	# of the visible set / walk distance. FFR.CELLS = 4, backstop cap = 1 active + POOL_MAX_NEIGHBOURS.
	var backstop_cap := 1 + CubeSphere.POOL_MAX_NEIGHBOURS
	var whole_planet := 6 * FA.K * FA.K * FFR.CELLS * FFR.CELLS * 2
	var dense := backstop_cap * CubeSphere.BACKSTOP_CELLS * CubeSphere.BACKSTOP_CELLS * 2
	var tri_bound := whole_planet + dense
	_ok(tris <= tri_bound, "G-FRC-BOUND: triangle_count %d ≤ bound %d (whole-planet %d + %d dense backstop)" % [tris, tri_bound, whole_planet, dense])
	var bsz := int(ring.call("backstop_cache_size"))
	_ok(bsz <= backstop_cap, "G-FRC-BOUND: backstop cache %d facets ≤ cap %d (1 active + POOL_MAX_NEIGHBOURS)" % [bsz, backstop_cap])
	ring.free()

# ---------- G-FRC-PARITY (flag ON): the three assemblers agree WITH backstop facets present ----------
# Under FULL_COVER the sunk-dense backstop facets take a different code path in each assembler: _build_surfacetool /
# the async worker go through _emit_cached (per-vertex sink), _build_fast falls back to _append_backstop_tris (the memcpy
# is only for non-backstop). This asserts all three produce a bit-identical mesh (pos + col + globally-smoothed normals),
# so the compose rules hold and the denser+sunk geometry is emitted identically off-thread and on the fast path.
func _gate_parity(active: int) -> void:
	print("  --- G-FRC-PARITY: SurfaceTool == fast == async, WITH backstop facets in the set ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("set_pool_excluded", _edge_neighbours(active))     # ensure ≥1 backstop neighbour beyond the active facet
	var fids: PackedInt32Array = ring.call("visible_fids")
	# count the backstop facets actually in the emitted set (proves the denser path is genuinely exercised here).
	var nbackstop := 0
	for f in fids:
		if bool(ring.call("is_backstop", int(f))):
			nbackstop += 1
	_ok(nbackstop >= 1, "G-FRC-PARITY: %d backstop facets present in the visible set (dense path exercised)" % nbackstop)
	var slow: ArrayMesh = ring.call("_build_surfacetool", fids)   # warms both caches (per-vertex, canonical)
	var fast: ArrayMesh = ring.call("_build_fast", fids)          # memcpy non-backstop + _append_backstop_tris backstop
	# simulate _dispatch_async_rebuild's main-thread snapshot of the backstop role, then run the worker body inline.
	var bs := {}
	for f in fids:
		if bool(ring.call("is_backstop", int(f))):
			bs[int(f)] = true
	ring.set("_async_backstop", bs)
	ring.set("_async_fids", fids)
	ring.call("_async_build_worker")                             # off-thread body, inline (caches already warm)
	var async_arrays: Array = ring.get("_async_arrays")
	var async_mesh := ArrayMesh.new()
	if async_arrays.size() == Mesh.ARRAY_MAX and (async_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0:
		async_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, async_arrays)
	_ok(_meshes_equal(slow, fast), "G-FRC-PARITY: _build_fast bit-identical to _build_surfacetool (backstop memcpy fallback)")
	_ok(_meshes_equal(slow, async_mesh), "G-FRC-PARITY: async worker bit-identical to _build_surfacetool (off-thread sink)")
	# real tri count: (front-backstop) at CELLS + backstop at BACKSTOP_CELLS — confirms the density is genuinely applied.
	var expect := (fids.size() - nbackstop) * FFR.CELLS * FFR.CELLS * 2 + nbackstop * CubeSphere.BACKSTOP_CELLS * CubeSphere.BACKSTOP_CELLS * 2
	ring.call("force_rebuild")
	var real_tris := int(ring.call("triangle_count"))
	_ok(real_tris == expect, "G-FRC-PARITY: mesh tri count %d == %d (non-backstop@%d + %d backstop@%d — density applied)" % [
		real_tris, expect, FFR.CELLS, nbackstop, CubeSphere.BACKSTOP_CELLS])
	ring.free()

## Bit-identical surface-array compare (pos + col exact-approx, normals ≤ 1e-6) — the far-ring mesh-equivalence contract.
func _meshes_equal(a: ArrayMesh, b: ArrayMesh) -> bool:
	if a.get_surface_count() != b.get_surface_count():
		return false
	if a.get_surface_count() == 0:
		return true
	var aa := a.surface_get_arrays(0)
	var ab := b.surface_get_arrays(0)
	var va: PackedVector3Array = aa[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = ab[Mesh.ARRAY_VERTEX]
	var ca: PackedColorArray = aa[Mesh.ARRAY_COLOR]
	var cb: PackedColorArray = ab[Mesh.ARRAY_COLOR]
	var na: PackedVector3Array = aa[Mesh.ARRAY_NORMAL]
	var nb: PackedVector3Array = ab[Mesh.ARRAY_NORMAL]
	if va.size() != vb.size() or ca.size() != cb.size() or na.size() != nb.size():
		return false
	for i in range(va.size()):
		if not va[i].is_equal_approx(vb[i]) or not ca[i].is_equal_approx(cb[i]):
			return false
		if (na[i] - nb[i]).length() > 1.0e-6:
			return false
	return true

# --- gate-local sampling helpers ---

## The (cells+1)² grid of backstop heights g for facet `fid` — sampled EXACTLY as FacetFarRing._ensure_backstop_cached
## (bilerp planar corners → dir → profile_at_dir g), so this is a faithful reconstruction of the rendered backstop.
func _coarse_g_grid(fid: int, cells: int) -> PackedInt32Array:
	var stride := cells + 1
	var g := PackedInt32Array()
	g.resize(stride * stride)
	for gj in range(stride):
		for gi in range(stride):
			var d := _col_dir(fid, float(gi) / float(cells), float(gj) / float(cells))
			g[gj * stride + gi] = _g_at(d)
	return g

## Bilinear height of the coarse grid `g` at facet-param (s,t): find the containing cell, interpolate its 4 corner g's.
## Bilinear (vs the triangle split the mesh uses) is ≥ the triangle interpolation on a saddle, so it is a CONSERVATIVE
## poke oracle — if the bilinear surface stays below near, the actual (planar-triangle, sagitta-lower) backstop does too.
func _bilerp_cell(g: PackedInt32Array, cells: int, s: float, t: float) -> float:
	var stride := cells + 1
	var fs := clampf(s, 0.0, 1.0) * float(cells)
	var ft := clampf(t, 0.0, 1.0) * float(cells)
	var ci := mini(int(fs), cells - 1)
	var cj := mini(int(ft), cells - 1)
	var ls := fs - float(ci)
	var lt := ft - float(cj)
	var v00 := float(g[cj * stride + ci])
	var v10 := float(g[cj * stride + ci + 1])
	var v11 := float(g[(cj + 1) * stride + ci + 1])
	var v01 := float(g[(cj + 1) * stride + ci])
	return _bilerp(v00, v10, v11, v01, ls, lt)

## The active facet's 4 edge neighbours (seam neighbours), de-duplicated and in-range — the live-pool `_excluded` stand-in.
func _edge_neighbours(fid: int) -> Array:
	var out := []
	for slot in range(4):
		var n := FA.seam_neighbour(fid, slot)
		if n >= 0 and n != fid and not out.has(n):
			out.append(n)
	return out

## Rank facets by coarse relief range (max−min g over a cheap 3×3 sample) and return the `n` steepest — the mountains
## whose between-sample chord error is the worst case for backstop poke-through (the design's "mountain-foothill spawn").
func _worst_relief_facets(n: int) -> Array:
	var k := FA.K
	var ranked := []                       # [range, fid]
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				var lo := 1 << 30
				var hi := -(1 << 30)
				for gj in range(3):
					for gi in range(3):
						var g := _g_at(_col_dir(fid, float(gi) / 2.0, float(gj) / 2.0))
						lo = mini(lo, g)
						hi = maxi(hi, g)
				ranked.append([hi - lo, fid])
	ranked.sort_custom(func(x, y): return x[0] > y[0])
	var out := []
	for i in range(mini(n, ranked.size())):
		out.append(int(ranked[i][1]))
	return out
