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
