extends SceneTree
## COSMOS FS1 (docs/COSMOS-FACET-SEAMS-DESIGN.md §4 / §6) — the FP_SHELL_WELD gate: the far shell CLOSES.
##
## The shipped far ring builds each facet from its OWN planarized corners, so adjacent facets' shared-edge chords
## disagree by up to the ∝R datum step (5.30 @ R=6371) — a see-through slit along every seam. FP_SHELL_WELD emits
## every vertex RADIALLY from the SHARED cube-sphere corner dirs, so two facets sharing a grid edge compute the
## SAME edge vertices ⇒ the shell welds. This gate BRANCHES on the flag:
##
##   flag ON  — G-SHELL-WELD  every shared horizon↔horizon edge welds (A's edge verts all coincide with B's, ≤1e-3).
##              G-SHELL-T     a dense (BACKSTOP_CELLS) facet's shared edge is colinear with the CELLS=4 coarse chord
##                            (coarse-owns-edge T-junction) — its edge verts weld to a horizon 4-edge crack-free.
##              G-SHELL-UNDER the welded+sunk backstop stays strictly BELOW the near blocky surface (no poke-through).
##   flag OFF — the complement: the shipped planar path leaves the ~5.30 chord crack (proving the flag is what closes it).
##
## The welded shell is a fixed ABSOLUTE radial surface, so closure is viewpoint-independent — "no see-through at any
## altitude" is the direct geometric consequence of the shared-edge weld this gate proves (the look is live-only).
##
## RUN (flag ON):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_SHELL_WELD := false/const FP_SHELL_WELD := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_shell_weld.gd
##   then REVERT. RUN (flag OFF complement): sed FACETED only. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")
const CELLS := 4

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _ring: FacetFarRing

func _initialize() -> void:
	print("=== verify_shell_weld (FS1: the far shell closes) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	TerrainConfig.set_active_facet(FA.spawn_facet())
	_ring = FFR.new()      # accessors touch only frozen atlas data + caches; no scene / setup needed
	print("  atlas: k=%d, R=%.0f, CELLS=%d, BACKSTOP_CELLS=%d, sink=%.2f, FP_SHELL_WELD=%s" % [
		FA.K, FA.R_BLOCKS, CELLS, CubeSphere.BACKSTOP_CELLS, TierPlace.backstop_sink(), str(CubeSphere.FP_SHELL_WELD)])
	var worst := _horizon_seam_gap()
	if CubeSphere.FP_SHELL_WELD:
		print("  G-SHELL-WELD: worst horizon shared-edge gap over all %d seams = %.6f blocks" % [6 * FA.K * FA.K * 4, worst])
		_ok(worst <= 1.0e-3, "horizon seams do NOT weld: worst shared-edge gap %.4f > 1e-3" % worst)
		_gate_tjunction()
		_gate_under()
	else:
		print("  complement: worst horizon shared-edge gap (shipped planar path) = %.4f blocks" % worst)
		_ok(worst > 4.0, "shipped path shows no crack (worst gap %.4f) — the flag-off complement is wrong" % worst)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ------- edge / boundary extraction from a (cells+1)² position grid (index gj*stride + gi) -------
func _edge_verts(pos: PackedVector3Array, cells: int, slot: int) -> PackedVector3Array:
	var stride := cells + 1
	var out := PackedVector3Array()
	for i in range(cells + 1):
		match slot:
			0: out.append(pos[i * stride + cells])   # East  (gi=cells)
			1: out.append(pos[i * stride + 0])        # West  (gi=0)
			2: out.append(pos[cells * stride + i])    # North (gj=cells)
			_: out.append(pos[0 * stride + i])        # South (gj=0)
	return out

func _boundary_verts(pos: PackedVector3Array, cells: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for slot in range(4):
		out.append_array(_edge_verts(pos, cells, slot))
	return out

# Min distance from each vert of `a` to the point set `b` (the max is the weld gap of edge a against boundary b).
func _max_min_dist(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var worst := 0.0
	for va in a:
		var best := 1.0e18
		for vb in b:
			best = minf(best, va.distance_to(vb))
		worst = maxf(worst, best)
	return worst

## G-SHELL-WELD / complement: the worst shared-edge gap over ALL horizon seams — each facet's edge verts for slot
## must all coincide with the neighbour's boundary (welded) or, flag-off, disagree by the planar chord crack.
func _horizon_seam_gap() -> float:
	var worst := 0.0
	var n := 6 * FA.K * FA.K
	for fidA in range(n):
		var pa := _ring.horizon_positions(fidA)
		for slot in range(4):
			var fidB := FA.seam_neighbour(fidA, slot)
			if fidB < 0:
				continue
			var pb := _ring.horizon_positions(fidB)
			worst = maxf(worst, _max_min_dist(_edge_verts(pa, CELLS, slot), _boundary_verts(pb, CELLS)))
	return worst

# Distance from point p to the segment [a,b].
func _pt_seg(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 <= 0.0:
		return p.distance_to(a)
	var h := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * h)

## G-SHELL-T: the COARSE-OWNS-EDGE T-junction is crack-free. A dense (BACKSTOP_CELLS) facet's shared edge must
## (i) COINCIDE with the CELLS=4 coarse neighbour's edge at the coarse nodes (its coarse-index verts land on the
## horizon boundary, ≤1e-3), and (ii) be COLINEAR — every fine vert lies on the segment between its bracketing
## coarse verts (≤1e-3). Together the dense edge traces the SAME polyline as the horizon 4-edge ⇒ no T-junction hole.
func _gate_tjunction() -> void:
	var cells := CubeSphere.BACKSTOP_CELLS
	var cstride := cells / CELLS
	var coarse_gap := 0.0
	var colinear := 0.0
	for fidA in _sample_facets():
		var pa := _ring.backstop_raw_positions(fidA)     # dense welded cache
		for slot in range(4):
			var fidB := FA.seam_neighbour(fidA, slot)
			if fidB < 0:
				continue
			var ea := _edge_verts(pa, cells, slot)        # 17 dense edge verts
			var pb := _ring.horizon_positions(fidB)
			var bb := _boundary_verts(pb, CELLS)
			for i in range(ea.size()):
				# (ii) colinearity: fine vert i lies on [coarse c0, coarse c1]
				var c0 := (i / cstride) * cstride
				var c1 := mini(c0 + cstride, cells)
				colinear = maxf(colinear, _pt_seg(ea[i], ea[c0], ea[c1]))
				# (i) coincidence at the coarse nodes: a coarse-index vert lands on the horizon boundary
				if i % cstride == 0:
					var best := 1.0e18
					for vb in bb:
						best = minf(best, ea[i].distance_to(vb))
					coarse_gap = maxf(coarse_gap, best)
	print("  G-SHELL-T: coarse-node gap to horizon = %.6f, colinearity residual = %.6f blocks" % [coarse_gap, colinear])
	_ok(coarse_gap <= 1.0e-3, "dense coarse-node verts miss the horizon edge: %.4f > 1e-3" % coarse_gap)
	_ok(colinear <= 1.0e-3, "dense fine edge verts are NOT colinear with the coarse chord: %.4f > 1e-3" % colinear)

## G-SHELL-UNDER: the welded + sunk backstop stays strictly below the near blocky surface (no poke-through) — the
## §4.3 staging invariant that lets FS1 ship at the current uniform sink BEFORE the datum fix removes the sagitta.
func _gate_under() -> void:
	var sink := TierPlace.backstop_sink()
	var worst_poke := -1.0e18                     # max (backstop_alt − near_alt); must stay < 0
	for fidA in _sample_facets():
		var raw := _ring.backstop_raw_positions(fidA)
		for v in raw:
			var d := v.normalized()
			var back_alt := v.length() - sink                                  # sunk radial altitude
			# near surface radial altitude at this direction, via the REAL near placement (lattice_to_world64)
			var lat := FA.world_to_lattice64(fidA, d.x * FA.R_BLOCKS, d.y * FA.R_BLOCKS, d.z * FA.R_BLOCKS)
			var g := int(TerrainConfig.facet_profile(fidA, int(round(lat[0])), int(round(lat[2]))).x)
			var nw := FA.lattice_to_world64(fidA, lat[0], float(g), lat[2])
			var near_alt := sqrt(nw[0] * nw[0] + nw[1] * nw[1] + nw[2] * nw[2])
			worst_poke = maxf(worst_poke, back_alt - near_alt)
	print("  G-SHELL-UNDER: worst (backstop − near) altitude = %.3f blocks (sink=%.2f, must be < 0)" % [worst_poke, sink])
	_ok(worst_poke < 0.0, "welded backstop pokes through the near surface by %.3f (raise sink / BACKSTOP_CELLS)" % worst_poke)

## Spawn facet + its 4 seam neighbours — the backstop role footprint the gates exercise.
func _sample_facets() -> Array:
	var sp := FA.spawn_facet()
	var out := [sp]
	for slot in range(4):
		var nb := FA.seam_neighbour(sp, slot)
		if nb >= 0:
			out.append(nb)
	return out
