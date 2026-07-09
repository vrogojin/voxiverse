extends SceneTree
## COSMOS-REAL-GEOMETRY-STUDY §8 gates — R1 far-layer BAKE. The class the shader could never test headlessly:
## the SHIPPED vertices. T1 bake-parity (baked far vertex + tile local origin == place_true == the epoch
## true position); T2 sampling-frame tie (the bake places each vertex at the true position of the cell the
## far builder actually SAMPLED); T3 wedge cull + no-hole (a corner tile drops only double-out triangles,
## the strips stay a connected surface); T4 seam-weld on REAL vertices (grid-adjacent baked verts ≤ 1.05
## cells — no crack where strips fold). Curved-only (loud-skip + exit 2 under FLAT).

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TP := preload("res://src/cosmos/cosmos_true_place.gd")
const FMB := preload("res://src/world/far/far_mesh_builder.gd")
const BEND := preload("res://src/cosmos/cosmos_bend.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _init() -> void:
	print("=== verify_cosmos_real (R1 far bake) FLAT_WORLD=", CS.FLAT_WORLD, " ===")
	if CS.FLAT_WORLD:
		print("  SKIPPED — real-geometry bake is curved-only; needs FLAT_WORLD=false. NOT A PASS.")
		print("==== VERIFY: SKIPPED (curved-only gate) ====")
		quit(2)
		return
	var chart: CHART = CHART.new(CS.HOME_BODY, 4, 0, 0)         # home face 4, corner origin → strips + wedge reachable
	var node_origin: Vector3 = chart.node_origin()             # far node position (Vector3.ZERO at org 0)
	var anchor := Vector3(40.0, 4.0, 40.0)                     # epoch bake anchor (near spawn)
	var frame := TP.bake_frame(chart, anchor)

	# ---- T1 bake-parity + T2 sampling-frame tie: a clean HOME tile (tc positive → no wedge) ----
	var home := FMB.build_arrays(0, Vector2i(2, 2))            # origin (512,512) → all home
	var baked := FMB.bake_arrays(home, chart, frame, node_origin)
	var lo: Vector3 = baked["local_origin"]
	var hv: PackedVector3Array = home["verts"]
	var bv: PackedVector3Array = baked["verts"]
	var t1 := 0.0
	var t2 := 0.0
	for k in range(0, hv.size(), 7):                            # sample every 7th vertex
		var v := hv[k]
		var w := Vector3(node_origin.x + v.x, v.y, node_origin.z + v.z)
		# T1: the shipped baked vertex, put back in world, equals place_true (catches node_origin / y bugs)
		t1 = maxf(t1, ((bv[k] + lo) - TP.place_true(chart, w, frame)).length())
		# T2: the vertex sits at the true position of the cell the far builder SAMPLED (raw = M_win·nodelocal)
		var raw := chart.raw_of(int(round(w.x)), int(round(w.z)))
		var samp := Vector2(float(chart.mw_a) * v.x + float(chart.mw_b) * v.z, float(chart.mw_c) * v.x + float(chart.mw_d) * v.z)
		t2 = maxf(t2, (Vector2(raw.x, raw.y) - samp).length())
	_ok(hv.size() > 100 and t1 < 1e-3, "T1 bake-parity: baked far vertex + local_origin == place_true (worst %.8f blk, %d verts)" % [t1, hv.size()])
	_ok(t2 < 1e-3, "T2 sampling-frame tie: raw_of(window) == M_win·node-local (bake matches what the far builder sampled; worst %.6f)" % t2)

	# ---- T3 wedge cull + no-hole: a CORNER tile (origin negative → interior double-out, edges strips) ----
	var corner := FMB.build_arrays(0, Vector2i(-1, -1))        # origin (-256,-256): both-out interior = wedge
	var cbaked := FMB.bake_arrays(corner, chart, frame, node_origin)
	var cidx: PackedInt32Array = cbaked["indices"]
	var cverts: PackedVector3Array = corner["verts"]
	# recompute wedge flags to assert no kept triangle references a wedge vertex
	var wedge := PackedByteArray(); wedge.resize(cverts.size())
	var n_wedge := 0
	for k in range(cverts.size()):
		var v := cverts[k]
		if TP.is_wedge(chart, node_origin.x + v.x, node_origin.z + v.z):
			wedge[k] = 1; n_wedge += 1
	var leaked := 0
	for ti in range(0, cidx.size(), 3):
		if wedge[cidx[ti]] == 1 or wedge[cidx[ti + 1]] == 1 or wedge[cidx[ti + 2]] == 1:
			leaked += 1
	_ok(int(cbaked["culled_tris"]) > 0 and n_wedge > 0, "T3 wedge present + culled (n_wedge %d, culled_tris %d)" % [n_wedge, int(cbaked["culled_tris"])])
	_ok(leaked == 0, "T3 no wedge leak: no kept triangle references a double-out vertex (leaked %d)" % leaked)
	_ok(cidx.size() > 0, "T3 no total hole: the corner tile still emits strip triangles (kept tris %d)" % (cidx.size() / 3))

	# ---- T4 seam-weld on REAL vertices: two neighbouring tiles' SHARED EDGE bakes to coincident world
	# points (the crack/overlap check the shader couldn't do). Home tile (x∈[0,256]) i=0 column vs West
	# tile (x∈[-256,0]) i=grid column — both at window x=0, so their baked+local_origin must coincide. ----
	var htile := FMB.build_arrays(0, Vector2i(0, 2))           # origin (0,512): x∈[0,256]
	var wtile := FMB.build_arrays(0, Vector2i(-1, 2))          # origin (-256,512): x∈[-256,0]; i=grid at x=0
	var hb := FMB.bake_arrays(htile, chart, frame, node_origin)
	var wb := FMB.bake_arrays(wtile, chart, frame, node_origin)
	var grid := int(htile["grid"]); var side := grid + 1
	var cell := float(htile["cell"])
	var hlo: Vector3 = hb["local_origin"]; var wlo: Vector3 = wb["local_origin"]
	var hbv: PackedVector3Array = hb["verts"]; var wbv: PackedVector3Array = wb["verts"]
	var weld := 0.0
	var welded := 0
	_ok(int(wb["culled_tris"]) == 0, "T4 west strip fully kept (a one-out strip has no wedge; culled %d)" % int(wb["culled_tris"]))
	for j in range(0, side):
		var hp := hbv[0 * side + j] + hlo                       # home i=0  (window x=0)
		var wp := wbv[grid * side + j] + wlo                    # west i=grid (window x=0) — same physical line
		weld = maxf(weld, (hp - wp).length() / cell)
		welded += 1
	_ok(welded > 50 and weld <= 1.05, "T4 seam-weld: neighbouring far tiles' shared edge coincides on real baked verts (worst %.6f cell, %d)" % [weld, welded])

	# ---- T5 rigid ALIGNMENT ROOT: player walked from the anchor; F must place the player's TRUE position
	# back at their scene position and re-level (their radial → +Y). Pure Transform3D. ----
	var player := Vector3(92.0, 4.0, 74.0)                      # walked ~66 blocks from the (40,4,40) anchor
	var F := TP.alignment_transform(chart, frame, player)
	var pe := TP.place_true(chart, player, frame)
	var mapped := F * pe
	_ok((mapped - player).length() < 1e-3, "T5 alignment: F·place_true(player) == player scene pos (%.8f blk)" % (mapped - player).length())
	var up_local := ((frame["mt"] as Basis) * TP.dir_of_window(chart, player.x, player.z)).normalized()
	var leveled := (F.basis * up_local).normalized()
	_ok((leveled - Vector3(0, 1, 0)).length() < 1e-4, "T5 level: the player's true radial rotates to +Y (horizon flat under the player; %.8f)" % (leveled - Vector3(0, 1, 0)).length())

	# ---- T6 near/far JOIN characterisation: aligned far-TRUE vs near CosmosBend (window-metric). Exact at
	# the camera; grows with distance as the honest window-vs-true METRIC divergence (study §4) — this is
	# the seam the ring-0 window-blend exists to smooth (T7), NOT a bug. Report the profile; assert only the
	# camera-exact join + monotonic growth (the metric signature).
	var rr := float(chart.radius)
	var at_cam := (F * TP.place_true(chart, player, frame)) - BEND.bend_point(player, player, rr)
	var jd := {}
	for dist: float in [4.0, 32.0, 80.0, 112.0]:
		var w := player + Vector3(dist, 0.0, 0.0)
		jd[dist] = ((F * TP.place_true(chart, w, frame)) - BEND.bend_point(w, player, rr)).length()
	_ok(at_cam.length() < 1e-3, "T6 join at camera: far-true == near-bend at the player (%.8f blk)" % at_cam.length())
	_ok(jd[4.0] < jd[32.0] and jd[32.0] < jd[80.0] and jd[80.0] < jd[112.0], "T6 residual is monotonic window/true metric divergence (the ring-0 blend's job)")
	print("  [join RAW] far-true vs near-bend gap @ {4,32,80,112} = %.4f, %.4f, %.4f, %.4f blk" % [jd[4.0], jd[32.0], jd[80.0], jd[112.0]])

	# ---- T7 RING-0 WINDOW-BLEND: with the blend, the far inner edge COINCIDES with the near field (s→0 at
	# r0) and reaches pure TRUE beyond the band (s→1). Bake a tile around the player with the blend and check
	# both regimes on real vertices. ----
	var r0 := 112.0
	var band := 24.0
	var blend := {"cam": player, "r0": r0, "band": band, "radius": rr, "align": F}
	var htile2 := FMB.build_arrays(0, Vector2i(0, 0))          # covers [0,256]² — contains the player + ring-0 band
	var bl := FMB.bake_arrays(htile2, chart, frame, node_origin, blend)
	var blo: Vector3 = bl["local_origin"]
	var blv: PackedVector3Array = bl["verts"]
	var hv2: PackedVector3Array = htile2["verts"]
	var inner_gap := 0.0; var inner_n := 0
	var outer_gap := 0.0; var outer_n := 0
	for k in range(hv2.size()):
		var v := hv2[k]
		var w := Vector3(node_origin.x + v.x, v.y, node_origin.z + v.z)
		var d := Vector2(w.x - player.x, w.z - player.z).length()
		var world := F * (blo + blv[k])
		if d <= r0 - 8.0 and d >= 8.0:                        # inside the blend inner edge → must match NEAR
			inner_gap = maxf(inner_gap, (world - BEND.bend_point(w, player, rr)).length()); inner_n += 1
		elif d >= r0 + band + 8.0:                            # beyond the band → must be pure TRUE
			outer_gap = maxf(outer_gap, (world - (F * TP.place_true(chart, w, frame))).length()); outer_n += 1
	_ok(inner_n > 20 and inner_gap < 0.02, "T7 blend inner edge: far COINCIDES with the near field inside r0 (worst %.5f blk, %d)" % [inner_gap, inner_n])
	_ok(outer_n > 20 and outer_gap < 1e-4, "T7 blend outer: pure true beyond the band (worst %.6f blk, %d)" % [outer_gap, outer_n])

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
