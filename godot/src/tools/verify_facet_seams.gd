extends SceneTree
## COSMOS FS0 (docs/COSMOS-FACET-SEAMS-DESIGN.md §6 / §8.1) — PIN the facet-junction seam bug.
##
## The pilot's #1 complaint is 8+-block height cliffs at every facet seam + see-through holes in the far
## shell. This gate REGRESSION-PINS the geometric root cause so FS1/FS2 can prove the reduction:
##
##  (a) Replicate _build_facet's MEAN-PLANE construction in f64 (independent of the atlas, so a perturbed
##      plane MOVES the number) and measure, over ALL 6912 Earth seams at R=6371:
##        - seam DATUM STEP    max|h_A − h_B| at the shared edge  (the cliff)   expect max ~5.30, p90 ~3.37, p50 ~1.14
##        - quad NON-PLANARITY max corner dev from own mean plane                expect ~2.77
##        - SAGITTA at centre  facet plane below the sphere datum                expect ~6.81
##        - far CHORD CRACK    shared edge projected onto each plane, matched-t  expect ~5.30  (the shell see-through)
##  (b) Prove every term is ∝ R by recomputing the whole thing at a sanity R=3072 — the ratio must be
##      6371/3072 = 2.0739 to f64 precision (the rescale amplified a latent discontinuity, exactly linearly).
##  (c) LIVE-PLACEMENT probe: through the REAL placement path (FacetAtlas.lattice_to_world64 + facet_profile),
##      place the SAME surface g on both sides of a seam's shared columns and assert the resulting radial-
##      altitude step matches the pure-geometry datum step — proving the mechanism, not just the geometry.
##
## FALSIFIABLE: the asserted numbers are the diagnosis. FS2 (FP_RADIAL_DATUM) must collapse the datum step
## to <=1 block; FS1 (FP_SHELL_WELD) must weld the chord crack to 0. If either fails to move these, the fix
## is wrong. This gate is FLAG-AGNOSTIC (it measures the base geometry) and must read the SAME ~5.30 with
## every FS flag OFF (G-DATUM-OFF in FS2 asserts this number returns).
##
## RUN (headless; the geometry needs no world boot, part (c) needs only the two warm_ups):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_facet_seams.gd
##   then REVERT the sed. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const K := 24

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# ------- f64 scalar vector helpers (NEVER route through Vector3/f32 — 5e-4 rel @ R=6371 ~= 3 blocks) -------
func _vdir(face: int, i: int, j: int, k: int) -> Array:
	var d := CosmosFacet.vertex_dir(face, i, j, k)   # f64 DVec3 unit
	return [d.x, d.y, d.z]
func _scale(a: Array, s: float) -> Array: return [a[0] * s, a[1] * s, a[2] * s]
func _sub(a: Array, b: Array) -> Array: return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
func _add(a: Array, b: Array) -> Array: return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
func _dot(a: Array, b: Array) -> float: return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
func _cross(a: Array, b: Array) -> Array:
	return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
func _len(a: Array) -> float: return sqrt(_dot(a, a))
func _norm(a: Array) -> Array:
	var l := _len(a)
	return [0.0, 0.0, 0.0] if l == 0.0 else [a[0] / l, a[1] / l, a[2] / l]
func _lerp3(a: Array, b: Array, t: float) -> Array:
	return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
func _proj(p: Array, c0: Array, n: Array) -> Array:
	return _sub(p, _scale(n, _dot(_sub(p, c0), n)))

# EXACT replication of FacetAtlas._build_facet's mean-plane construction. Returns [c0p, n] (both f64 Array3).
func _facet_plane(face: int, a: int, b: int, k: int, r: float) -> Array:
	var c0 := _scale(_vdir(face, a, b, k), r)
	var c1 := _scale(_vdir(face, a + 1, b, k), r)
	var c2 := _scale(_vdir(face, a + 1, b + 1, k), r)
	var c3 := _scale(_vdir(face, a, b + 1, k), r)
	var m := [(c0[0] + c1[0] + c2[0] + c3[0]) / 4.0, (c0[1] + c1[1] + c2[1] + c3[1]) / 4.0, (c0[2] + c1[2] + c2[2] + c3[2]) / 4.0]
	var n := _norm(_cross(_sub(c2, c0), _sub(c3, c1)))
	if _dot(n, m) < 0.0:
		n = [-n[0], -n[1], -n[2]]
	var c0p := _sub(c0, _scale(n, _dot(_sub(c0, m), n)))
	return [c0p, n]

# The neighbour facet (face,a,b) across slot (0=E,1=W,2=N,3=S) via CubeSphere.fold_cell (matches _neigh_ab).
func _neigh(face: int, a: int, b: int, slot: int, k: int) -> Array:
	var ni := a; var nj := b
	match slot:
		0: ni = a + 1
		1: ni = a - 1
		2: nj = b + 1
		_: nj = b - 1
	var fold: Dictionary = CubeSphere.fold_cell(face, ni, nj, k)
	return [int(fold["face"]), int(fold["i"]), int(fold["j"])]

# This facet's own shared-edge grid-vertex indices for slot: [i0,j0, i1,j1] (matches _seam_edge_ij).
func _edge_ij(a: int, b: int, slot: int) -> Array:
	match slot:
		0: return [a + 1, b, a + 1, b + 1]
		1: return [a, b, a, b + 1]
		2: return [a, b + 1, a + 1, b + 1]
		_: return [a, b, a + 1, b]

const _TS := [0.0, 0.25, 0.5, 0.75, 1.0]

# All seam-geometry stats at radius r (part a/b). Returns a Dictionary of the headline numbers.
func _seam_stats(r: float) -> Dictionary:
	var steps := PackedFloat64Array()
	var max_nonplan := 0.0
	var max_sagitta := 0.0
	var max_crack := 0.0
	for face in range(6):
		for a in range(K):
			for b in range(K):
				var pA := _facet_plane(face, a, b, K, r)
				var c0A: Array = pA[0]; var nA: Array = pA[1]
				# quad non-planarity: this facet's true corners' deviation from its own mean plane
				var cds := [_vdir(face, a, b, K), _vdir(face, a + 1, b, K), _vdir(face, a + 1, b + 1, K), _vdir(face, a, b + 1, K)]
				var csum := [0.0, 0.0, 0.0]
				for cd in cds:
					var dev: float = _dot(_sub(_scale(cd, r), c0A), nA)
					max_nonplan = maxf(max_nonplan, absf(dev))
					csum = _add(csum, cd)
				# sagitta at facet centre: the sphere point above the plane at the centre radial
				var cdir := _norm(csum)
				max_sagitta = maxf(max_sagitta, _dot(_sub(_scale(cdir, r), c0A), nA))
				for slot in range(4):
					var nb := _neigh(face, a, b, slot, K)
					var pB := _facet_plane(nb[0], nb[1], nb[2], K, r)
					var c0B: Array = pB[0]; var nB: Array = pB[1]
					var ev := _edge_ij(a, b, slot)
					var d0 := _vdir(face, ev[0], ev[1], K)
					var d1 := _vdir(face, ev[2], ev[3], K)
					# ONE datum-step value per seam = the worst mismatch along its shared edge (the cliff a
					# player sees). The percentiles are over these 13824 half-seam maxima (== 6912 seams ×2).
					var seam_step := 0.0
					for t in _TS:
						var q := _scale(_norm(_lerp3(d0, d1, t)), r)     # true edge arc point at radius r
						var hA: float = _dot(_sub(q, c0A), nA)
						var hB: float = _dot(_sub(q, c0B), nB)
						seam_step = maxf(seam_step, absf(hA - hB))        # the DATUM STEP (the cliff)
					steps.append(seam_step)
					# far CHORD CRACK: shared edge projected onto each plane, matched-t gap (the shell see-through)
					var e0 := _scale(d0, r); var e1 := _scale(d1, r)
					var pA0 := _proj(e0, c0A, nA); var pA1 := _proj(e1, c0A, nA)
					var pB0 := _proj(e0, c0B, nB); var pB1 := _proj(e1, c0B, nB)
					for t in _TS:
						var cA := _lerp3(pA0, pA1, t); var cB := _lerp3(pB0, pB1, t)
						max_crack = maxf(max_crack, _len(_sub(cA, cB)))
	var arr := steps.duplicate()
	arr.sort()
	var n := arr.size()
	return {
		"max": arr[n - 1], "p90": arr[int(0.90 * float(n - 1))], "p50": arr[int(0.50 * float(n - 1))],
		"nonplan": max_nonplan, "sagitta": max_sagitta, "crack": max_crack, "count": n,
	}

func _initialize() -> void:
	print("=== verify_facet_seams (FS0: pin the facet-junction seam bug) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()

	# ---- (a) the headline seam numbers at R=6371 ----
	var s6 := _seam_stats(FA.R_BLOCKS)
	print("  R=%.0f  seams=%d/2  datum step: max=%.3f p90=%.3f p50=%.3f  | non-planarity=%.3f  sagitta(centre)=%.3f  far-chord-crack=%.3f" % [
		FA.R_BLOCKS, s6["count"], s6["max"], s6["p90"], s6["p50"], s6["nonplan"], s6["sagitta"], s6["crack"]])
	_ok(absf(s6["max"] - 5.30) <= 0.10, "seam datum step max %.3f != 5.30 (the 8-block-cliff root)" % s6["max"])
	_ok(absf(s6["p90"] - 3.37) <= 0.15, "seam datum step p90 %.3f != 3.37" % s6["p90"])
	_ok(absf(s6["p50"] - 1.14) <= 0.15, "seam datum step p50 %.3f != 1.14" % s6["p50"])
	_ok(absf(s6["nonplan"] - 2.77) <= 0.10, "quad non-planarity %.3f != 2.77" % s6["nonplan"])
	_ok(absf(s6["sagitta"] - 6.81) <= 0.15, "sagitta(centre) %.3f != 6.81" % s6["sagitta"])
	_ok(absf(s6["crack"] - 5.30) <= 0.10, "far chord crack %.3f != 5.30 (the shell see-through)" % s6["crack"])

	# ---- (b) prove every term is EXACTLY ∝ R (the rescale amplified a latent discontinuity, linearly) ----
	var s3 := _seam_stats(3072.0)
	var ratio := FA.R_BLOCKS / 3072.0    # 2.07389...
	print("  R=3072  datum step max=%.3f  (ratio 6371/3072 = %.4f)" % [s3["max"], ratio])
	_ok(absf(s6["max"] / s3["max"] - ratio) <= 1.0e-3, "datum step not ∝R: %.5f != %.5f" % [s6["max"] / s3["max"], ratio])
	_ok(absf(s6["nonplan"] / s3["nonplan"] - ratio) <= 1.0e-3, "non-planarity not ∝R")
	_ok(absf(s6["sagitta"] / s3["sagitta"] - ratio) <= 1.0e-3, "sagitta not ∝R")
	_ok(absf(s6["crack"] / s3["crack"] - ratio) <= 1.0e-3, "chord crack not ∝R")

	# ---- (c) live-placement probe: the REAL lattice_to_world64 + facet_profile path reproduces the step ----
	_probe_live()

	# ================= COSMOS-FACET-SEAMS-V2 gates (FS2′ / FS-W / twist) =================
	_probe_datum_v2()      # G-D2-* : the CONTINUOUS datum lift collapses the seam step + is radial + mirror-exact
	_gate_corner_walk()    # G-CORNER-WALK : corner-commit resolves a grid-corner clear of the −3 ridge wall
	_gate_twist_frame()    # G-TWIST-FRAME + G-CROSS-HEADING : frame-aware reframe_twist preserves world heading
	await _gate_datum_collide()  # G-DATUM-COLLIDE : the physics floor the player stands on == the datum-baked render

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Live-placement mechanism proof: for EVERY seam, place the SAME surface g on both facets AT the true shared
## sphere edge point d̂ through the REAL placement function (FacetAtlas.world_to_lattice64 → lattice_to_world64)
## and take the radial-altitude difference. Same g at matched d̂ isolates the DATUM step from the cross-seam
## sampling term. The step must (i) reach cliff scale (>4.5, ~= the pinned 5.30 max) somewhere — proving the
## real placement path, not just the plane geometry, produces the cliffs — and (ii) agree everywhere with the
## pure-plane |h_A − h_B| prediction to sub-block (proving the mechanism is exactly the plane-datum mismatch).
func _probe_live() -> void:
	var r := FA.R_BLOCKS
	var max_obs := 0.0
	var max_disagree := 0.0
	var w_fidA := -1; var w_fidB := -1; var w_slot := -1; var w_pred := 0.0
	for face in range(6):
		for a in range(K):
			for b in range(K):
				var fidA := (face * K + a) * K + b
				var pA := _facet_plane(face, a, b, K, r)
				var c0A: Array = pA[0]; var nA: Array = pA[1]
				for slot in range(4):
					var nb := _neigh(face, a, b, slot, K)
					var fidB := FA.seam_neighbour(fidA, slot)
					var pB := _facet_plane(nb[0], nb[1], nb[2], K, r)
					var c0B: Array = pB[0]; var nB: Array = pB[1]
					var ev := _edge_ij(a, b, slot)
					var d0 := _vdir(face, ev[0], ev[1], K)
					var d1 := _vdir(face, ev[2], ev[3], K)
					# The datum step is ~0 at the edge midpoint (planes cross near the shared edge) and worst
					# toward the corners — sample along the edge (matching _seam_stats) and keep the worst.
					for t in _TS:
						var dm := _norm(_lerp3(d0, d1, t))
						var q := _scale(dm, r)                               # true shared sphere edge point
						var g := int(TerrainConfig.profile_at_dir(dm[0], dm[1], dm[2], r).x)
						# pure-plane datum step at this edge point
						var predicted: float = absf(_dot(_sub(q, c0A), nA) - _dot(_sub(q, c0B), nB))
						# REAL placement path: same g at matched d̂, radial altitude on each facet (no cell rounding)
						var la := FA.world_to_lattice64(fidA, q[0], q[1], q[2])
						var lb := FA.world_to_lattice64(fidB, q[0], q[1], q[2])
						var wa := FA.lattice_to_world64(fidA, la[0], float(g), la[2])
						var wb := FA.lattice_to_world64(fidB, lb[0], float(g), lb[2])
						var obs: float = absf(_len(wa) - _len(wb))
						max_disagree = maxf(max_disagree, absf(obs - predicted))
						if obs > max_obs:
							max_obs = obs; w_fidA = fidA; w_fidB = fidB; w_slot = slot; w_pred = predicted
	print("  live worst: A=%d slot=%d B=%d  observed step=%.3f  plane-predicted=%.3f  (max |obs−pred| over all seams=%.4f)" % [
		w_fidA, w_slot, w_fidB, max_obs, w_pred, max_disagree])
	_ok(max_obs > 4.5, "no seam reached cliff scale via the real placement path: max live step %.3f <= 4.5" % max_obs)
	_ok(max_disagree <= 1.0, "real placement disagrees with the plane-datum geometry by %.3f > 1.0" % max_disagree)

## The FS2′ C++ mirror formula (EXACT transcription of voxel_mesher_blocky.cpp::facet_datum_lift) recomputed in
## GDScript from FacetAtlas.datum_bake_params — so G-D2-SHAPE-MIRROR can assert it == FacetAtlas.datum_lift.
func _cpp_lift(params: Dictionary, X: float, Z: float) -> float:
	var o: PackedFloat64Array = params["o"]; var du: PackedFloat64Array = params["du"]
	var dv: PackedFloat64Array = params["dv"]; var nh: PackedFloat64Array = params["nhat"]
	var off: PackedInt32Array = params["off"]; var r: float = params["R"]
	var fx := X - float(off[0]); var fz := Z - float(off[1])
	var p0x := o[0] + fx * du[0] + fz * dv[0]
	var p0y := o[1] + fx * du[1] + fz * dv[1]
	var p0z := o[2] + fx * du[2] + fz * dv[2]
	var b := p0x * nh[0] + p0y * nh[1] + p0z * nh[2]
	var disc := b * b + r * r - (p0x * p0x + p0y * p0y + p0z * p0z)
	if disc < 0.0:
		disc = 0.0
	return -b + sqrt(disc)

## COSMOS FS2′ (docs/COSMOS-FACET-SEAMS-V2.md §2.3) — G-D2-*. The CONTINUOUS datum lift, applied through the REAL
## placement path, must (ON) collapse the seam step to ≤0.3, make the placed surface RADIAL (|len|≈R+g), stay
## CONTINUOUS between columns (gradient ≤0.06), and mirror the C++ bake formula EXACTLY; (OFF) leave the geometry
## byte-identical (the pinned 5.30 step returns — datum_lift ≡ 0). Reuses the _probe_live seam walk.
func _probe_datum_v2() -> void:
	var r := FA.R_BLOCKS
	var on := CubeSphere.FP_DATUM_BAKE
	var max_step := 0.0
	var max_radial := 0.0
	var max_grad := 0.0
	var max_mirror := 0.0
	for face in range(6):
		for a in range(K):
			for b in range(K):
				var fidA := (face * K + a) * K + b
				# G-D2-SHAPE-MIRROR + G-D2-CONT: the lift the near mesh bakes == datum_lift, and is smooth.
				var params := FA.datum_bake_params(fidA)
				if bool(params.get("enabled", false)):
					var cc := FA.centre_cell(fidA)
					var s00 := FA.datum_lift(fidA, float(cc.x) + 0.5, float(cc.y) + 0.5)
					var s10 := FA.datum_lift(fidA, float(cc.x) + 1.5, float(cc.y) + 0.5)
					var s01 := FA.datum_lift(fidA, float(cc.x) + 0.5, float(cc.y) + 1.5)
					max_grad = maxf(max_grad, maxf(absf(s10 - s00), absf(s01 - s00)))
					max_mirror = maxf(max_mirror, absf(_cpp_lift(params, float(cc.x) + 0.5, float(cc.y) + 0.5) - s00))
				for slot in range(4):
					var fidB := FA.seam_neighbour(fidA, slot)
					var ev := _edge_ij(a, b, slot)
					var d0 := _vdir(face, ev[0], ev[1], K)
					var d1 := _vdir(face, ev[2], ev[3], K)
					for t in _TS:
						var dm := _norm(_lerp3(d0, d1, t))
						var q := _scale(dm, r)
						var g := int(TerrainConfig.profile_at_dir(dm[0], dm[1], dm[2], r).x)
						var la := FA.world_to_lattice64(fidA, q[0], q[1], q[2])
						var lb := FA.world_to_lattice64(fidB, q[0], q[1], q[2])
						var sA := FA.datum_lift(fidA, la[0], la[2])
						var sB := FA.datum_lift(fidB, lb[0], lb[2])
						var wa := FA.lattice_to_world64(fidA, la[0], float(g) + sA, la[2])
						var wb := FA.lattice_to_world64(fidB, lb[0], float(g) + sB, lb[2])
						max_step = maxf(max_step, absf(_len(wa) - _len(wb)))
						max_radial = maxf(max_radial, absf(_len(wa) - (r + float(g))))
	print("  FS2′ (FP_DATUM_BAKE=%s): lifted seam step max=%.3f  radial |len−(R+g)| max=%.3f  s-gradient max=%.4f  mirror max=%s" % [
		str(on), max_step, max_radial, max_grad, str(max_mirror)])
	if on:
		_ok(max_step <= 0.30, "G-D2-SEAM: lifted seam step %.3f > 0.30 (datum did not collapse the cliff)" % max_step)
		_ok(max_radial <= 0.30, "G-D2-LIFT-RADIAL: placed surface not radial, |len−(R+g)| %.3f > 0.30" % max_radial)
		_ok(max_grad <= 0.06, "G-D2-CONT: s gradient %.4f > 0.06 (would terrace)" % max_grad)
		_ok(max_mirror <= 1.0e-9, "G-D2-SHAPE-MIRROR: C++ formula != datum_lift by %.2e" % max_mirror)
	else:
		_ok(absf(max_step - 5.30) <= 0.10, "G-D2-OFF: datum_lift≡0 must leave the 5.30 step; got %.3f" % max_step)

## COSMOS FS2′ (docs/COSMOS-FACET-SEAMS-V2.md §2.2.4) — G-DATUM-COLLIDE (the LIVE embed pin). The invariant: the
## surface the player SEES (the C++ near-mesh datum bake, y += s) and the surface they COLLIDE with (the analytic
## floor_under the player rests on) are the SAME height per column. Boots a real WorldManager on the spawn facet and,
## over a grid of columns, compares WorldManager.floor_under (collision, play space) against the INDEPENDENT render
## surface = cell-space content top (effective_height+1, NO datum) + the EXACT C++ per-vertex lift (_cpp_lift, the
## transcription of voxel_mesher_blocky.cpp). If any physics funnel dropped s while the mesh applied it (or vice-
## versa), the mismatch = s (up to ~6.9 blocks) and the player embeds. Must agree ≤ 0.10 block. Off ⇒ skipped.
func _gate_datum_collide() -> void:
	if not (CubeSphere.FP_DATUM_BAKE and CubeSphere.FACETED):
		print("  G-DATUM-COLLIDE: skipped (needs FP_DATUM_BAKE + FACETED sed-on)")
		return
	var fid := FA.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	var wm := WorldManager.new()
	wm.name = "SeamCollideWorld"
	get_root().add_child(wm)
	await process_frame
	await process_frame
	var cc := FA.centre_cell(fid)
	var params := FA.datum_bake_params(fid)
	var worst := 0.0
	var worst_s := 0.0
	var n := 0
	for dx in range(-30, 31, 4):
		for dz in range(-30, 31, 4):
			var x: int = cc.x + dx; var z: int = cc.y + dz
			# COLLISION: the analytic floor the player rests on (floor_under snaps position.y here) — play space, +s.
			var col_floor: float = wm.floor_under(float(x) + 0.5, float(z) + 0.5, 400.0)
			var s: float = FA.datum_lift(fid, float(x) + 0.5, float(z) + 0.5)
			# Restrict to FULL-CUBE surface columns (cell-space top is integer) so the independent render model
			# (effective_height+1 + C++ lift) is exact — a slab/ramp top (0.5) is a shape the physics + mesh both
			# render identically but this gate can't model without the mesher shape logic (out of scope: this pins
			# the LIFT, not the shape). Classify by the physics cell-space top; skip non-integer (shaped) columns.
			var cell_top_phys: float = col_floor - s
			if absf(cell_top_phys - round(cell_top_phys)) > 0.02:
				continue
			# RENDER (independent of the physics lift): cell-space full-cube top + the EXACT C++ near-mesh lift.
			var render_y: float = float(wm.effective_height(x, z) + 1) + _cpp_lift(params, float(x) + 0.5, float(z) + 0.5)
			worst = maxf(worst, absf(col_floor - render_y))
			worst_s = maxf(worst_s, s)
			n += 1
	print("  G-DATUM-COLLIDE: %d full-cube columns  worst |collision_floor − render_surface| = %.5f  (max s in play = %.3f)" % [
		n, worst, worst_s])
	_ok(n >= 20, "G-DATUM-COLLIDE: too few full-cube columns sampled (%d) to pin the invariant" % n)
	_ok(worst_s > 1.0, "G-DATUM-COLLIDE: no lifted column sampled (s≈0) — cannot prove the funnel applies the bake")
	_ok(worst <= 0.10, "G-DATUM-COLLIDE: physics floor != datum-baked render by %.4f > 0.10 (the live embed)" % worst)
	wm.queue_free()
	await process_frame

## COSMOS FS-W (docs/COSMOS-FACET-SEAMS-V2.md §3) — G-CORNER-WALK. At a facet-grid corner the single-edge landing
## fails containment (the shipped `continue` → the −3 ridge wall). WorldManager._corner_commit must instead resolve
## a destination BY DIRECTION whose reframed landing is CLEAR of the wall (min own_dist > FACET_WALL_EPS), matching
## facet_of_dir; and _past_ridge_deep must flag a deep-past position so the cooldown never strands the player. The
## helpers are flag-agnostic (pure geometry) so this runs without booting a world.
func _gate_corner_walk() -> void:
	var wm := WorldManager.new()
	var HYST: float = wm.FACET_CROSS_HYST
	var WALL: float = wm.FACET_WALL_EPS
	var exercised := 0
	var resolved := 0
	var deep_ok := 0
	# The +X+Z grid corner of each facet: a lattice column just past BOTH the E (slot 0) and N (slot 2) ridges.
	for fidA in range(min(FA.body_facet_count(0), 24)):
		var dmx := FA.dom_max(fidA)
		var g := int(TerrainConfig.facet_profile(fidA, dmx.x - 1, dmx.y - 1).x)
		var pos := Vector3(float(dmx.x) + 2.5, float(g), float(dmx.y) + 2.5)
		# Count how many of A's own ridges this position is past (needs ≥2 to be a genuine corner case).
		var crossed := 0
		for slot in 4:
			if FA.own_dist(fidA, slot, pos.x, pos.y, pos.z) < -HYST:
				crossed += 1
		if crossed < 2:
			continue
		exercised += 1
		if wm._past_ridge_deep(fidA, pos):
			deep_ok += 1
		var cc := wm._corner_commit(fidA, pos)
		if cc.is_empty():
			continue
		var to := int(cc["to"])
		var np: Array = cc["np"]
		# The committed landing must be CLEAR of the −3 ridge wall on every side (never strand into blocked()).
		var mind := INF
		for bslot in 4:
			mind = minf(mind, FA.own_dist(to, bslot, np[0], np[1], np[2]))
		# Direction oracle cross-check: the committed facet is the one the world direction lands in.
		var w := FA.lattice_to_world64(fidA, pos.x, pos.y, pos.z)
		var fdir := FA.facet_of_dir_body(FA.body_of_fid(fidA),
			CubeSphere.DVec3.new(w[0], w[1], w[2]).normalized())
		if mind > WALL and to == fdir:
			resolved += 1
	wm.free()
	print("  FS-W corner-commit: exercised=%d resolved(clear-of-wall & dir-correct)=%d deep-past=%d" % [
		exercised, resolved, deep_ok])
	_ok(exercised >= 4, "G-CORNER-WALK: too few grid-corner cases exercised (%d)" % exercised)
	_ok(resolved == exercised, "G-CORNER-WALK: %d/%d corners not resolved clear of the wall / dir-correct" % [resolved, exercised])
	_ok(deep_ok == exercised, "G-CORNER-WALK: _past_ridge_deep failed to flag %d deep-past corners" % (exercised - deep_ok))

## COSMOS FS2-V2 (docs/COSMOS-FACET-SEAMS-V2.md §5) — G-TWIST-FRAME. Under the fixed frame the player's WORLD state
## is frame_basis(fid)·local_state, so a crossing preserves it iff local_B = crossing_basis(A,B)·local_A. The about-
## UP action of crossing_basis(A,B) is a rotation by −yaw_delta (LIVE-verified in _gate_cross_heading below), so the
## world-preserving local twist is −yaw_delta for BOTH heading and velocity — NOT +yaw_delta (the shipped/legacy
## twist DOUBLE-twists under the fixed frame → the live crossing-heading glitch). Assert: shipped (off) = +yaw_delta
## (byte-identical legacy); KEEP_HEADING legacy = no twist; FRAME-AWARE+fixed = −yaw_delta REGARDLESS of keep_heading
## (the single correct world-preserving twist); FRAME-AWARE+legacy honours keep_heading. reframe_twist is a pure
## static — tested directly, all combinations.
func _gate_twist_frame() -> void:
	var yd := 0.7
	var y0 := 0.3
	var vel := Vector3(1.0, 0.0, 2.0)
	var want_plus := wrapf(y0 + yd, -PI, PI)     # legacy/shipped twist (frame off)
	var want_minus := wrapf(y0 - yd, -PI, PI)    # frame-aware world-preserving twist (frame on)
	var off: Array = Player.reframe_twist(y0, vel, yd, false, false, false)
	_ok(absf(wrapf(off[0] - want_plus, -PI, PI)) <= 1.0e-6, "twist off: shipped +yaw_delta not applied")
	var keep: Array = Player.reframe_twist(y0, vel, yd, true, false, false)
	_ok(keep[0] == y0 and keep[1] == vel, "twist KEEP_HEADING(legacy): heading/vel must be unchanged")
	var fa: Array = Player.reframe_twist(y0, vel, yd, true, true, true)
	_ok(absf(wrapf(fa[0] - want_minus, -PI, PI)) <= 1.0e-6 and fa[1].is_equal_approx(vel.rotated(Vector3.UP, -yd)),
		"G-TWIST-FRAME: frame-aware+fixed+keep must apply −yaw_delta (world-heading preserving), not +yaw_delta/no-twist")
	var fa_off: Array = Player.reframe_twist(y0, vel, yd, false, true, true)
	_ok(absf(wrapf(fa_off[0] - want_minus, -PI, PI)) <= 1.0e-6, "G-TWIST-FRAME: frame-aware+fixed(no keep) = −yaw_delta")
	var fal: Array = Player.reframe_twist(y0, vel, yd, true, true, false)
	_ok(fal[0] == y0 and fal[1] == vel, "G-TWIST-FRAME: frame-aware+LEGACY+keep must honour keep_heading (no twist)")
	_gate_cross_heading()

## COSMOS FS2-V2 (§5) — G-CROSS-HEADING (the LIVE regression pin). Assert WORLD-heading + WORLD-velocity CONTINUITY
## across a real crossing, computed through the ACTUAL FacetAtlas.frame_basis (not an assumed frame_yaw algebra).
## For every real seam with a non-degenerate dihedral, the player faces/moves in A's frame; after apply_reframe's
## twist the SAME physical world direction must result in B's frame. The frame-aware+fixed reframe_twist (−yaw_delta)
## must hold Δworld_heading ≤ 2° (residual = the intentionally-dropped dihedral tilt, player stays upright); the
## legacy +yaw_delta must FAIL continuity (≈2·|yaw_delta|) — proving the sign is what fixes it. Runs only when the
## fixed frame is engaged (the live combo); otherwise reports the algebra check above.
func _gate_cross_heading() -> void:
	if not (CubeSphere.FP_FIXED_FRAME and CubeSphere.FP_DATUM_BAKE):
		print("  G-CROSS-HEADING: skipped (needs FP_FIXED_FRAME + FP_DATUM_BAKE sed-on for the live combo)")
		return
	# pick a seam whose about-UP yaw_delta is clearly non-degenerate (|yd| in (0.2, 2.8) — not ~0, not ~π)
	var best_a := -1; var best_b := -1; var best_yd := 0.0; var best_err := INF
	for face in range(6):
		for a in range(0, K, 2):
			for b in range(0, K, 2):
				var fidA := (face * K + a) * K + b
				for slot in range(4):
					var fidB := FA.seam_neighbour(fidA, slot)
					if fidB < 0 or fidB == fidA:
						continue
					var ex: Vector3 = FA.crossing_basis(fidA, fidB) * Vector3(1.0, 0.0, 0.0)
					var yd := atan2(ex.z, ex.x)
					var e: float = absf(absf(yd) - 1.0)
					if absf(yd) > 0.2 and absf(yd) < 2.8 and e < best_err:
						best_err = e; best_yd = yd; best_a = fidA; best_b = fidB
	if best_a < 0:
		_ok(false, "G-CROSS-HEADING: no non-degenerate seam found (atlas not warmed?)")
		return
	var basisA := FA.frame_basis(best_a)
	var basisB := FA.frame_basis(best_b)
	var vel := Vector3(0.6, 0.0, 0.9)
	var worst_fix := 0.0
	var worst_legacy := 0.0
	for y0 in [0.0, 0.4, -1.1, 2.0]:
		# The player stays UPRIGHT (+Y up) and the dihedral tilt is carried by the frame/camera, so the preserved
		# invariant is the AZIMUTHAL heading in the local tangent plane — express each world direction back in A's
		# frame and compare atan2(z,x). (A raw 3D angle would count the intentionally-dropped dihedral tilt as error.)
		var wfA := basisA * (Basis(Vector3.UP, y0) * Vector3(0, 0, -1))       # world forward before
		var wvA := basisA * vel                                              # world velocity before
		var azfA := _tangent_az(basisA, wfA); var azvA := _tangent_az(basisA, wvA)
		# frame-aware+fixed twist (the FIX): −yaw_delta on heading + velocity
		var tw: Array = Player.reframe_twist(y0, vel, best_yd, true, true, true)
		var wfB := basisB * (Basis(Vector3.UP, tw[0]) * Vector3(0, 0, -1))
		var wvB: Vector3 = basisB * tw[1]
		var dfix_h: float = absf(rad_to_deg(wrapf(_tangent_az(basisA, wfB) - azfA, -PI, PI)))
		var dfix_v: float = absf(rad_to_deg(wrapf(_tangent_az(basisA, wvB) - azvA, -PI, PI)))
		worst_fix = maxf(worst_fix, maxf(dfix_h, dfix_v))
		# legacy +yaw_delta (the BUG): must NOT be continuous
		var wfL := basisB * (Basis(Vector3.UP, wrapf(y0 + best_yd, -PI, PI)) * Vector3(0, 0, -1))
		var dleg: float = absf(rad_to_deg(wrapf(_tangent_az(basisA, wfL) - azfA, -PI, PI)))
		worst_legacy = maxf(worst_legacy, dleg)
	print("  G-CROSS-HEADING: seam A=%d B=%d yaw_delta=%.4f  fix worst tangent-Δ=%.3f deg  legacy(+yd) worst=%.3f deg" % [
		best_a, best_b, best_yd, worst_fix, worst_legacy])
	_ok(worst_fix <= 2.0, "G-CROSS-HEADING: frame-aware −yaw_delta must hold world heading/velocity azimuth ≤2° (got %.2f)" % worst_fix)
	_ok(worst_legacy > 10.0, "G-CROSS-HEADING: legacy +yaw_delta should VISIBLY break continuity (got %.2f — sign fix not exercised)" % worst_legacy)

## The azimuth of world direction `w` inside frame `b`'s local tangent plane (about the local up) — atan2(z,x) of
## the direction re-expressed in the frame. The player's perceived heading under the fixed frame.
func _tangent_az(b: Basis, w: Vector3) -> float:
	var lv: Vector3 = b.transposed() * w
	return atan2(lv.z, lv.x)
