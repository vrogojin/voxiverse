extends SceneTree
## COSMOS-FRAME-ORIENTATION §8 G-D — directional-shape WORLD direction (bug #1). Curved mode only.
## For a firing slope reached through the fold from home face 4, the RENDERED downhill (the generated
## window-frame modifier, now rotated by J⁻¹ at the resolve boundary) must point the SAME physical way
## in the world as the TRUE-face downhill. Pre-fix the error was the edge D4 (90/180°); post-fix it is
## only the residual §4.6 metric-lie shear (small, ~0 mid-edge). Also: cross-epoch equality (home-4 folded
## render == home-F native render) and the 0° control edge (no rotation).

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# World tangent basis (∂dir/∂i, ∂dir/∂j) at face-cell (f,i,j) via finite differences of face_cell_to_dir.
func _tangents(f: int, i: float, j: float, n: int) -> Array:
	var dip: CubeSphere.DVec3 = CubeSphere.face_cell_to_dir(f, i + 1.0, j, n)
	var din: CubeSphere.DVec3 = CubeSphere.face_cell_to_dir(f, i - 1.0, j, n)
	var djp: CubeSphere.DVec3 = CubeSphere.face_cell_to_dir(f, i, j + 1.0, n)
	var djn: CubeSphere.DVec3 = CubeSphere.face_cell_to_dir(f, i, j - 1.0, n)
	var ti := Vector3(dip.x - din.x, dip.y - din.y, dip.z - din.z)
	var tj := Vector3(djp.x - djn.x, djp.y - djn.y, djp.z - djn.z)
	return [ti, tj]

# Downhill index-gradient of a slope modifier: -(uphill). corners (d00,d10,d11,d01).
func _grad(mod: int) -> Vector2:
	if not CellCodec.is_slope(mod):
		return Vector2.ZERO
	var d := CellCodec.slope_deltas(mod)
	var up_i := float((d.y + d.z) - (d.x + d.w)) * 0.5
	var up_j := float((d.w + d.z) - (d.x + d.y)) * 0.5
	return Vector2(-up_i, -up_j)

# World-space downhill vector = grad mapped through the tangent basis (grad.i*Ti + grad.j*Tj).
func _world_dir(grad: Vector2, tangs: Array) -> Vector3:
	var ti: Vector3 = tangs[0]
	var tj: Vector3 = tangs[1]
	return ti * grad.x + tj * grad.y

func _angle(a: Vector3, b: Vector3) -> float:
	if a.length() < 1e-9 or b.length() < 1e-9:
		return 0.0
	return rad_to_deg(a.angle_to(b))

func _init() -> void:
	print("=== verify_cosmos_dirshape (G-D — directional-shape world direction, bug #1) FLAT_WORLD=", CubeSphere.FLAT_WORLD, " ===")
	if CubeSphere.FLAT_WORLD:
		print("  SKIPPED — G-D needs FLAT_WORLD=false to exercise the curved fold/render. NOT A PASS.")
		print("==== VERIFY: SKIPPED (curved-only gate) ====")
		quit(2)                                     # sentinel: distinct from a real pass (0) or fail (1)
		return
	var n := CubeSphere.n_for(CubeSphere.HOME_BODY)
	var home := 4
	var side_name := {0: "EAST", 1: "WEST", 2: "NORTH", 3: "SOUTH"}
	for side in [CubeSphere.SIDE_WEST, CubeSphere.SIDE_EAST, CubeSphere.SIDE_NORTH, CubeSphere.SIDE_SOUTH]:
		var e := CubeSphere.edge_remap(home, side, n)
		var neighbour := int(e["b"])
		var strip := CubeSphere.strip_d4_to(home, neighbour, n)
		# Find a firing slope column just across this edge (window face-4 index out of range → folds to F).
		var found := false
		var report := ""
		for depth in range(2, 30, 2):
			for t in range(2, n - 2, 1):
				var wi := -1; var wj := -1
				match side:
					CubeSphere.SIDE_WEST:  wi = -depth;       wj = t
					CubeSphere.SIDE_EAST:  wi = n - 1 + depth; wj = t
					CubeSphere.SIDE_NORTH: wi = t;            wj = n - 1 + depth
					CubeSphere.SIDE_SOUTH: wi = t;            wj = -depth
				var g := CubeSphere.fold_cell(home, wi, wj, n)
				if int(g["face"]) != neighbour:
					continue
				var nf := neighbour; var ni := int(g["i"]); var nj := int(g["j"])
				# canonical slope modifier: native gen on F with M_win=I (jinv=0 → no rotation)
				TerrainConfig.set_active_face(nf); TerrainConfig.set_active_mwin_d4(0)
				var gg := int(TerrainConfig.column_profile(ni, nj).x)
				var run := TerrainConfig.slope_run_of(ni, nj)
				if not TerrainConfig.slope_run_fires(run):
					continue
				var rng := TerrainConfig.slope_run_range(run, gg)
				var yy := int(rng.x)
				# generated_cell_global is CANONICAL now (§6 refactor); the RENDER modifier = rotate_modifier(
				# canonical, analytic J⁻¹) at the window exit (what cell_value_at / the worker apply).
				var m_can := CellCodec.modifier(TerrainConfig.generated_cell_global(nf, ni, nj, yy))
				if not CellCodec.is_slope(m_can):
					continue
				# rendered from HOME-4 epoch (folded window index wi,wj): _active_face=4, M_win=I.
				TerrainConfig.set_active_frame(home, 0)
				var m_ren := ShapeCodec.rotate_modifier(m_can, TerrainConfig.analytic_jinv_d4(wi, wj))
				# rendered from HOME-F epoch (native ni,nj): _active_face=F, M_win = M_strip(4→F).
				TerrainConfig.set_active_frame(nf, strip)
				var m_ren_b := ShapeCodec.rotate_modifier(m_can, TerrainConfig.analytic_jinv_d4(ni, nj))
				TerrainConfig.set_active_frame(home, 0)

				# TRUE world downhill (canonical on F's tangents) vs RENDERED world downhill (home-4 window
				# = face-4 tangents at the out-of-range window index (wi,wj), the gnomonic overshoot the bend uses).
				var true_w := _world_dir(_grad(m_can), _tangents(nf, float(ni), float(nj), n))
				var ren_w := _world_dir(_grad(m_ren), _tangents(home, float(wi), float(wj), n))
				var err := _angle(true_w, ren_w)
				# Pre-fix reference: unrotated canonical placed in the window (what the bug did).
				var pre_w := _world_dir(_grad(m_can), _tangents(home, float(wi), float(wj), n))
				var pre_err := _angle(true_w, pre_w)

				_ok(err < 45.0, "[%s->F%d strip=%d] rendered downhill aligns with true (err=%.1f°, pre-fix err=%.1f°)" % [side_name[side], neighbour, strip, err, pre_err])
				_ok(m_ren == m_ren_b, "[%s] cross-epoch WORLD equality: home-4-folded render == home-F-native render" % side_name[side])
				if strip == 0:
					_ok(m_ren == m_can, "[%s] 0° edge: no rotation (render == canonical)" % side_name[side])
				else:
					_ok(m_ren != m_can or _grad(m_can) == Vector2.ZERO, "[%s] non-0° edge: render rotated off canonical" % side_name[side])
				report = "[%s->F%d] firing slope @(%d,%d) strip=%d err=%.1f° (pre %.1f°)" % [side_name[side], neighbour, ni, nj, strip, err, pre_err]
				found = true
				break
			if found: break
		if not found:
			report = "[%s->F%d] no firing slope found in the edge strip (skipped)" % [side_name[side], neighbour]
		print("  ", report)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
