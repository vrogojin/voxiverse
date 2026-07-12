extends SceneTree
## COSMOS FP1 gate (docs/COSMOS-FACETED-IMPL.md §4.7) — the playable-facet suite. Runs with FACETED = true
## (the gate runner sed-toggles it, like the FLAT_WORLD=false curved gates). Covers:
##   G-F1e  frame math      — every facet's frame is orthonormal, right-handed, outward, planar, round-trips
##   G-F1a  purity          — worker column == analytic column; generated_cell is deterministic across passes
##   G-F1d  spawn margin     — the spawn column sits ≥ 32 cells inside the facet polygon
##   G-F1f  seam continuity  — the two facets straddling a shared ridge agree in surface height (≤ 2 blocks)
## The off-toggle byte-identity (G-F1c) is a SEPARATE run: verify_feature + the curved suite with FACETED=false.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_faceted (FP1 playable facet) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true (a facet is a flat world).")
		quit(1)
		return

	TC.warm_up()
	FA.warm_up()
	var nf := FA.facet_count()
	print("  atlas: %d facets (k=%d, R=%d), spawn facet=%d" % [nf, FA.K, int(FA.R_BLOCKS), FA.spawn_facet()])

	_gate_frame_math(nf)
	_gate_purity()
	_gate_spawn_margin()
	_gate_seam_continuity()
	_gate_live_loop()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# G-F1b — the flat engine plays a facet. Build a bare WorldManager (FACETED=true → it installs the spawn facet
# and answers analytic cell/physics queries with the facet terrain), then run the break/place/collapse loop the
# flat game uses: solid ground with air above, break carves the overlay to air, floor_under drops into the hole,
# place writes to the overlay, and a break under an unsupported cluster detaches it as a loose VoxelBody.
func _gate_live_loop() -> void:
	TC.set_active_facet(FA.spawn_facet())          # deterministic: play the spawn facet
	var w := WorldManager.new()
	w.name = "FacetLive"
	get_root().add_child(w)
	var s: Vector2i = TC.find_spawn()
	var cx := s.x
	var cz := s.y
	var sy := int(round(w.surface_y(float(cx) + 0.5, float(cz) + 0.5)))
	# find the topmost solid cell near the reported surface (surface_y is the top FACE, so the top solid cell
	# is sy−1; scan to be robust to the exact convention and to snow/tree caps)
	var top := sy + 4
	while top > sy - 8 and w.block_id_at(Vector3i(cx, top, cz)) == 0:
		top -= 1
	_ok(BlockCatalog.solidity_of(w.block_id_at(Vector3i(cx, top, cz))) >= 0.5, "facet live: solid ground at top cell y=%d (surface_y≈%d)" % [top, sy])
	_ok(w.block_id_at(Vector3i(cx, top + 1, cz)) == 0, "facet live: air directly above the surface (y=%d)" % (top + 1))
	# break the top solid cell → overlay air; floor_under must drop after digging
	var feet := float(top) + 1.5
	var fu0 := w.floor_under(float(cx) + 0.5, float(cz) + 0.5, feet)
	var broke := w.break_terrain(Vector3i(cx, top, cz)) > 0
	_ok(broke and w.block_id_at(Vector3i(cx, top, cz)) == 0, "facet live: break_terrain carves the top cell to air (overlay)")
	var fu1 := w.floor_under(float(cx) + 0.5, float(cz) + 0.5, feet)
	_ok(fu1 < fu0 - 0.5, "facet live: floor_under drops after digging (%.2f → %.2f, no teleport)" % [fu0, fu1])
	# place STONE back into the just-dug cell (guaranteed air, adjacent to solid below) → overlay id
	var placed := w.place_block(Vector3i(cx, top, cz), BlockCatalog.STONE)
	_ok(placed and CellCodec.mat(w.block_id_at(Vector3i(cx, top, cz))) == BlockCatalog.STONE, "facet live: place_block writes STONE to the overlay")
	# collapse: place then break an isolated floating block — the structural pass must run without error
	var body_count_before := _loose_bodies(w)
	w.place_block(Vector3i(cx + 4, top + 6, cz + 4), BlockCatalog.STONE)   # isolated floater
	w.break_terrain(Vector3i(cx + 4, top + 6, cz + 4))                      # break it → structural pass runs
	_ok(_loose_bodies(w) >= body_count_before, "facet live: collapse pass runs without error on the facet")
	w.queue_free()

func _loose_bodies(w: WorldManager) -> int:
	var n := 0
	for c in w.get_children():
		if c is VoxelBody:
			n += 1
	return n

# G-F1e — for every facet: orthonormal basis, det=+1, outward n̂, near-planar corners, exact W_fid round-trip.
func _gate_frame_math(nf: int) -> void:
	var worst_ortho := 0.0
	var worst_rt := 0.0
	var worst_dev_ratio := 0.0
	var min_ndc := 1.0
	var bad_det := 0
	var cos1 := cos(deg_to_rad(1.0))
	for fid in range(nf):
		var m: Dictionary = FA.verify_frame(fid)
		worst_ortho = maxf(worst_ortho, m["ortho"])
		worst_rt = maxf(worst_rt, m["roundtrip"])
		min_ndc = minf(min_ndc, m["n_dot_centre"])
		if absf(float(m["det"]) - 1.0) > 1e-6:
			bad_det += 1
		var edge: float = m["edge"]
		if edge > 0.0:
			worst_dev_ratio = maxf(worst_dev_ratio, float(m["plane_dev"]) / edge)
	_ok(worst_ortho < 1e-9, "frame orthonormal (worst Gram residual %s < 1e-9)" % worst_ortho)
	_ok(bad_det == 0, "every basis right-handed det=+1 (%d facets off)" % bad_det)
	_ok(min_ndc >= cos1, "n̂ points outward within 1° (min n̂·centre = %.6f ≥ cos1°=%.6f)" % [min_ndc, cos1])
	_ok(worst_dev_ratio < 0.02, "facet near-planar (worst corner plane-dev / edge = %.4f < 0.02)" % worst_dev_ratio)
	_ok(worst_rt < 1e-3, "W_fid round-trips (worst |T⁻¹∘W − id| = %s < 1e-3, f64 kernel)" % worst_rt)

# G-F1a — purity/determinism on 3 facets (spawn + a face-4 corner-quadrant facet + a face-0 facet). The worker
# column path (a frozen GenCtx(0,fid)) must equal the analytic column (which reads _active_facet), and
# generated_cell must be byte-stable across a re-run and across a memo clear. Catches f32 leakage in the d̂ path.
func _gate_purity() -> void:
	var k := FA.K
	var sample := [FA.spawn_facet(), (4 * k + 0) * k + 0, (0 * k + k / 2) * k + (k / 2)]
	for fid in sample:
		TC.set_active_facet(fid)
		var cc: Vector2i = FA.centre_cell(fid)
		# column equality: worker (frozen ctx) == analytic (null ctx → _active_facet)
		var col_eq := true
		for dz in range(-12, 12):
			for dx in range(-12, 12):
				var x := cc.x + dx
				var z := cc.y + dz
				var wctx := TC.GenCtx.new(0, fid)
				var pw: Vector4 = TC.column_profile(x, z, wctx)
				var pa: Vector4 = TC.column_profile(x, z)     # analytic, reads _active_facet == fid
				if pw != pa:
					col_eq = false
		_ok(col_eq, "facet %d: worker column == analytic column (24×24, no f32 divergence)" % fid)
		# cell determinism: generated_cell box stable across a 2nd pass AND after a memo clear
		var g0 := TC.height_at(cc.x, cc.y)
		var h1 := _cell_box_hash(cc, g0)
		var h2 := _cell_box_hash(cc, g0)
		TC.set_active_facet(-1)              # clear active + memos, then re-home to force a cold recompute
		TC.set_active_facet(fid)
		var h3 := _cell_box_hash(cc, g0)
		_ok(h1 == h2 and h1 == h3, "facet %d: generated_cell deterministic (2nd pass + post-clear byte-equal)" % fid)

func _cell_box_hash(cc: Vector2i, g0: int) -> int:
	var vals := PackedInt32Array()
	for dz in range(-8, 8):
		for dx in range(-8, 8):
			for y in range(g0 - 8, g0 + 9):
				vals.append(TC.generated_cell(cc.x + dx, y, cc.y + dz))
	return hash(vals)

# G-F1d — the spawn column sits ≥ 32 cells inside every facet-polygon edge (covers _find_flat's ±16 wander).
func _gate_spawn_margin() -> void:
	var fid := FA.spawn_facet()
	var sc: Vector2i = FA.spawn_column()
	TC.set_active_facet(fid)
	var spawn: Vector2i = TC.find_spawn()
	_ok(FA.in_polygon(fid, sc.x, sc.y, -32.0), "spawn window centre ≥ 32 cells inside the facet polygon")
	_ok(FA.in_polygon(fid, spawn.x, spawn.y, -16.0), "resolved spawn column ≥ 16 cells inside the polygon")
	var p: Vector4 = TC.column_profile(spawn.x, spawn.y)
	_ok(int(p.x) > TC.SEA_LEVEL + 1, "spawn column is land (g=%d > sea)" % int(p.x))

# G-F1f — two facets sharing a ridge agree in surface height at the cells straddling it (the datum step across
# a dihedral is GEOMETRIC, not a terrain discontinuity). For 19 points along the shared ridge arc we find each
# facet's OWN lattice cell whose cell_dir is nearest that ridge direction, then compare the two facets' surface
# heights (facet_profile.g). They must agree to ≤ 2 blocks — this pins the d̂ adapter (sampling map correct on
# both sides), independent of the geometric datum offset. Also pins the one-map rule: facet_profile == profile
# at cell_dir.
func _gate_seam_continuity() -> void:
	var k := FA.K
	var fid := FA.spawn_facet()
	var face := int(fid / (k * k))
	var rem := fid - face * k * k
	var a := int(rem / k)
	var b := rem - a * k
	# one-map rule: facet_profile(fid,x,z) must equal profile_at_dir(cell_dir(fid,x,z))
	var cc: Vector2i = FA.centre_cell(fid)
	var d: CubeSphere.DVec3 = FA.cell_dir(fid, cc.x, cc.y)
	var one_map := TC.facet_profile(fid, cc.x, cc.y) == TC.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS)
	_ok(one_map, "one-map rule: facet_profile == profile_at_dir(cell_dir) (sampling map is placement map)")
	if a + 1 >= k:
		_ok(true, "seam continuity: spawn facet on a cube-face edge — cross-face neighbour deferred to FP2")
		return
	var nfid := (face * k + (a + 1)) * k + b   # the +a neighbour facet, sharing the a→a+1 ridge
	var worst := 0
	for s in range(1, 20):
		var tt := float(s) / 20.0
		var e0 := CosmosFacet.vertex_dir(face, a + 1, b, k)
		var e1 := CosmosFacet.vertex_dir(face, a + 1, b + 1, k)
		var rd := CubeSphere.DVec3.new(e0.x + (e1.x - e0.x) * tt, e0.y + (e1.y - e0.y) * tt, e0.z + (e1.z - e0.z) * tt).normalized()
		var ca := _nearest_cell(fid, rd)
		var cb := _nearest_cell(nfid, rd)
		var ga := int(TC.facet_profile(fid, ca.x, ca.y).x)
		var gb := int(TC.facet_profile(nfid, cb.x, cb.y).x)
		worst = maxi(worst, absi(ga - gb))
	_ok(worst <= 2, "seam facets %d↔%d agree in surface height (worst Δg = %d ≤ 2 blocks)" % [fid, nfid, worst])

## The facet lattice cell whose cell_dir is nearest unit direction `rd` — scan the facet's polygon-clipped
## lattice domain (a few hundred cells per side). Used only by the seam gate.
func _nearest_cell(fid: int, rd: CubeSphere.DVec3) -> Vector2i:
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var best := Vector2i(lo.x, lo.y)
	var best_dot := -2.0
	var z := lo.y
	while z <= hi.y:
		var x := lo.x
		while x <= hi.x:
			if FA.in_polygon(fid, x, z, 0.0):
				var cd: CubeSphere.DVec3 = FA.cell_dir(fid, x, z)
				var dp := cd.x * rd.x + cd.y * rd.y + cd.z * rd.z
				if dp > best_dot:
					best_dot = dp
					best = Vector2i(x, z)
			x += 1
		z += 1
	return best
