extends SceneTree
## COSMOS FAR-RENDER-OVERHAUL Item B gate (docs/COSMOS-FAR-RENDER-OVERHAUL-DESIGN.md §2.8) — the SMOOTH far-terrain
## surface-net mesher (FP_FAR_SMOOTH). B1 scope: the pure mesher (FacetSmoothTier.build_tile over FarDensity), no
## render. Runs with FACETED = true (FLAT_WORLD = true), sed-toggled. Falsifiable assertions (each perturbed → FAIL):
##   G-FS-DEGEN  — on the heightfield density the net DEGENERATES to a displaced grid: exactly (cells+1)² vertices
##                 (one per column, NOT per edge-crossing) and 2·cells² tris; every vertex sits EXACTLY on its
##                 FarDensity node (round-trip pos equality) ⇒ no hallucinated volume geometry; all normals unit +
##                 outward (radial-aligned). Perturb: a per-edge-vertex mesher would give ≠(cells+1)² verts.
##   G-FS-BOUND  — no protrusion above / below truth: every vertex's recovered ground height g ∈ [g_min, g_max] over
##                 the tile footprint (+1 block ε); no NaN/Inf in any vertex. Perturb: wrong relief sign / stride bug
##                 places a vertex outside the column-height envelope.
##   G-FS-BYTES  — tile_bytes == the vertex-buffer arithmetic; a worst-case resident set (Σ tier caps × tier tile
##                 bytes) ≤ SMOOTH_BYTES_MAX (NEVER-OOM, fixed at creation).
##   G-FS-OFF    — FP_FAR_SMOOTH defaults false (byte-off: nothing constructs a FacetSmoothTier; FLAT stays 6042/0).
##
## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md P0 (§3 P0, this stage) extends the gate with the weld-exactness proofs:
##   G-FS-CANON       — DEMONSTRATE the pre-P0 defect (facet_planar_corner disagrees at a shared edge — the ∝R
##                      datum step, `facet_atlas.gd:420`), THEN assert the canon boundary dirs
##                      (`FacetAtlas.facet_corner_dirs`) of an adjacent pair — E/W/N/S via `seam_neighbour`,
##                      including a cross-face pair — agree (bit-equal in-face; ≤1e-9 cross-face, f64 rounding).
##   G-FS-WELD-EDGE   — two adjacent SAME-pitch (S4) tiles: their shared-boundary vertex sets are equal
##                      (≤ 1e-9·R_BLOCKS), tested across all 4 slots incl. the cross-face one.
##   G-FS-NRM-CONT    — boundary normals across those same pairs agree (≤ 1e-4).
##   G-FS-WELD-MIXED  — an S3 tile vs its (in-face) S4 neighbour: fine boundary nodes, after
##                      `FacetSmoothTier.snap_edges_to_coarse`, lie exactly on the coarse tile's own straight edge
##                      chord (and are shown to depart from it BEFORE the snap — the crack law 4 fixes).

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const FD := preload("res://src/world/far/far_density.gd")
const FST := preload("res://src/world/facet_smooth_tier.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_far_smooth (FAR-RENDER-OVERHAUL B1 / FP_FAR_SMOOTH + FAR-SMOOTH-GEOMETRY P0) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true) — sed-toggled.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	print("  FP_FAR_SMOOTH=%s, spawn facet=%d (K=%d, R=%.0f)" % [str(CubeSphere.FP_FAR_SMOOTH), fid, FA.K, FA.R_BLOCKS])

	_ok(not CubeSphere.FP_FAR_SMOOTH, "G-FS-OFF: FP_FAR_SMOOTH defaults false (byte-off; the mesher is inert until sed-ON)")

	# Exercise the mesher at every tier so the gate covers the whole ladder (S2 104 .. S5 13).
	for tier in [FST.S2, FST.S3, FST.S4, FST.S5]:
		var cells := FST.cells_for_tier(tier)
		_gate_degen(fid, cells, tier)
		_gate_bound(fid, cells, tier)
	_gate_bytes(fid)

	# --- P0 weld-exactness (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P0) ---
	# Fixture A: a facet sitting on a cube-FACE boundary (a=0) so its West neighbour is a CROSS-FACE pair, while
	# its East/North/South neighbours stay IN-FACE — one facet covers both cases for G-FS-CANON.
	var fid_edge := _fid_of(0, 0, 5)
	_gate_canon(fid_edge)
	# Fixture B: a facet fully INTERIOR to its face (all 4 neighbours in-face) — the plain case for the weld/normal
	# continuity + mixed-pitch gates (kept separate from the cross-face fixture so index correspondence is direct).
	var fid_int := _fid_of(0, 5, 5)
	_gate_weld_edge_nrm(fid_int)
	_gate_weld_mixed(fid_int, FA.S_EAST)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- fixture helper: Earth fid at local (face,a,b) ---
func _fid_of(face: int, a: int, b: int) -> int:
	return (face * FA.K + a) * FA.K + b

func _face_of(fid: int) -> int:
	var kb := FA.k_of(fid)
	var lf := fid - FA.fid_base_of(fid)
	return int(lf / (kb * kb))

# --- G-FS-DEGEN: the net collapses to a displaced grid, exact vertex/tri counts, vertices on their density nodes ---
func _gate_degen(fid: int, cells: int, tier: int) -> void:
	var tile := FST.build_tile(fid, cells)
	var pos: PackedVector3Array = tile["pos"]
	var nrm: PackedVector3Array = tile["nrm"]
	var idx: PackedInt32Array = tile["idx"]
	var stride := cells + 1
	_ok(pos.size() == stride * stride,
		"G-FS-DEGEN[t%d]: %d verts == (cells+1)²=%d (one per column — net degenerated to a grid)" % [tier, pos.size(), stride * stride])
	_ok(idx.size() == cells * cells * 6,
		"G-FS-DEGEN[t%d]: %d indices == 2·cells²·3=%d (no volumetric extra geometry)" % [tier, idx.size(), cells * cells * 6])
	# Every vertex sits EXACTLY on its FarDensity node (round-trip) + normals are unit & outward. Sample a spread of
	# nodes (checking all (cells+1)² for S2 would be slow but S3-S5 are cheap; sample a grid for S2).
	var corner_dirs := FA.facet_corner_dirs(fid)
	var r_datum := FA.r_of(fid)
	var step := maxi(1, cells / 16)
	var round_ok := true
	var norm_ok := true
	var inv := 1.0 / float(cells)
	for gj in range(0, stride, step):
		for gi in range(0, stride, step):
			var vi := gj * stride + gi
			var node := FD.node_at(corner_dirs, r_datum, float(gi) * inv, float(gj) * inv)
			if (pos[vi] - (node["pos"] as Vector3)).length() > 1e-3:
				round_ok = false
			var nv: Vector3 = nrm[vi]
			if absf(nv.length() - 1.0) > 1e-3:
				norm_ok = false
			if nv.dot(node["dir"] as Vector3) <= 0.0:   # outward-oriented
				norm_ok = false
	_ok(round_ok, "G-FS-DEGEN[t%d]: every sampled vertex lies exactly on its FarDensity node (no hallucinated relief)" % tier)
	_ok(norm_ok, "G-FS-DEGEN[t%d]: all sampled normals are unit-length + outward (radial-aligned gradient)" % tier)

# --- G-FS-BOUND: no protrusion above / below the column-height envelope; finite everywhere ---
func _gate_bound(fid: int, cells: int, tier: int) -> void:
	var corner_dirs := FA.facet_corner_dirs(fid)
	var r_datum := FA.r_of(fid)
	var stride := cells + 1
	var inv := 1.0 / float(cells)
	var g_min := 1 << 30
	var g_max := -(1 << 30)
	# Ground-truth envelope: sample g over the tile nodes.
	for gj in range(stride):
		for gi in range(stride):
			var g := int(FD.node_at(corner_dirs, r_datum, float(gi) * inv, float(gj) * inv)["g"])
			g_min = mini(g_min, g)
			g_max = maxi(g_max, g)
	var tile := FST.build_tile(fid, cells)
	var pos: PackedVector3Array = tile["pos"]
	var finite := true
	var in_env := true
	for gj in range(stride):
		for gi in range(stride):
			var vi := gj * stride + gi
			var p: Vector3 = pos[vi]
			if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
				finite = false
				continue
			# Recover the vertex's ground height g from its radial relief: relief = (p − planar)·dir, g = SEA + relief/RELIEF.
			var node := FD.node_at(corner_dirs, r_datum, float(gi) * inv, float(gj) * inv)
			var relief := (p - (node["planar"] as Vector3)).dot(node["dir"] as Vector3)
			var g_rec := int(round(float(TC.SEA_LEVEL) + relief / FD.RELIEF))
			if g_rec < g_min - 1 or g_rec > g_max + 1:
				in_env = false
	_ok(finite, "G-FS-BOUND[t%d]: every vertex is finite (no NaN/Inf)" % tier)
	_ok(in_env, "G-FS-BOUND[t%d]: every vertex g ∈ [%d, %d] envelope (no protrusion above/below truth)" % [tier, g_min, g_max])

# --- G-FS-BYTES: per-tile ledger arithmetic + NEVER-OOM worst-case resident set under SMOOTH_BYTES_MAX ---
func _gate_bytes(fid: int) -> void:
	var cells := FST.cells_for_tier(FST.S3)
	var tile := FST.build_tile(fid, cells)
	var nv := (tile["pos"] as PackedVector3Array).size()
	var ni := (tile["idx"] as PackedInt32Array).size()
	var expect := nv * (12 + 12 + 16 + 8 + 8) + ni * 4
	_ok(FST.tile_bytes(tile) == expect,
		"G-FS-BYTES: tile_bytes == vertex-buffer arithmetic (%d B, %.2f MB)" % [expect, float(expect) / 1048576.0])
	# Worst-case resident: each tier at its facet cap × that tier's full-facet tile bytes ≤ SMOOTH_BYTES_MAX.
	var worst := 0
	for pair in [[FST.S2, CubeSphere.SMOOTH_S2_MAX], [FST.S3, CubeSphere.SMOOTH_S3_MAX], [FST.S4, CubeSphere.SMOOTH_S4_MAX], [FST.S5, CubeSphere.SMOOTH_S5_MAX]]:
		var c := FST.cells_for_tier(pair[0])
		var vt := (c + 1) * (c + 1)
		var it := c * c * 6
		worst += int(pair[1]) * (vt * (12 + 12 + 16 + 8 + 8) + it * 4)
	_ok(worst <= CubeSphere.SMOOTH_BYTES_MAX,
		"G-FS-BYTES: worst-case resident %.2f MB ≤ SMOOTH_BYTES_MAX %.2f MB (NEVER-OOM)" % [float(worst) / 1048576.0, float(CubeSphere.SMOOTH_BYTES_MAX) / 1048576.0])

# --- P0 weld-exactness gates ---

## For each corner ciA of `cd_a` find the ciB of `cd_b` whose canon dir is nearest (order/orientation-agnostic —
## robust to any face-fold reindexing). Returns pairs [ciA, ciB] whose dirs coincide (a shared vertex); an edge
## shares exactly 2.
func _match_corners(cd_a: PackedFloat64Array, cd_b: PackedFloat64Array) -> Array:
	var pairs := []
	for ciA in range(4):
		var da := Vector3(cd_a[ciA * 3], cd_a[ciA * 3 + 1], cd_a[ciA * 3 + 2])
		var best_ciB := -1
		var best_d := 1.0e18
		for ciB in range(4):
			var db := Vector3(cd_b[ciB * 3], cd_b[ciB * 3 + 1], cd_b[ciB * 3 + 2])
			var d: float = da.distance_squared_to(db)
			if d < best_d:
				best_d = d
				best_ciB = ciB
		if best_d < 1.0e-12:
			pairs.append([ciA, best_ciB])
	return pairs

## G-FS-CANON: demonstrate the pre-P0 defect (facet_planar_corner disagrees at a shared edge), THEN assert the
## canon boundary dirs of every adjacent pair (E/W/N/S via seam_neighbour) agree — including whichever of those
## 4 slots crosses a cube face for this fixture.
func _gate_canon(fid: int) -> void:
	var slots := [FA.S_EAST, FA.S_WEST, FA.S_NORTH, FA.S_SOUTH]
	var cd_a := FA.facet_corner_dirs(fid)
	var face_a := _face_of(fid)
	var demonstrated_defect := false
	var canon_equal := true
	var cross_face_tested := false
	var pair_count := 0
	for slot in slots:
		var nb := FA.seam_neighbour(fid, slot)
		var cd_b := FA.facet_corner_dirs(nb)
		var pairs := _match_corners(cd_a, cd_b)
		_ok(pairs.size() == 2, "G-FS-CANON: slot %d neighbour (fid %d) shares exactly 2 canon corners (an edge)" % [slot, nb])
		var is_cross_face := _face_of(nb) != face_a
		if is_cross_face:
			cross_face_tested = true
		for pair in pairs:
			pair_count += 1
			var ciA: int = pair[0]
			var ciB: int = pair[1]
			var pa := FA.facet_planar_corner(fid, ciA)
			var pb := FA.facet_planar_corner(nb, ciB)
			var pd: float = Vector3(pa[0], pa[1], pa[2]).distance_to(Vector3(pb[0], pb[1], pb[2]))
			if pd > 1.0e-6:
				demonstrated_defect = true
			var da := Vector3(cd_a[ciA * 3], cd_a[ciA * 3 + 1], cd_a[ciA * 3 + 2])
			var db := Vector3(cd_b[ciB * 3], cd_b[ciB * 3 + 1], cd_b[ciB * 3 + 2])
			var eps := 1.0e-9 if is_cross_face else 0.0   # in-face: bit-equal; cross-face: agree to f64 rounding (§2 law 2)
			if da.distance_to(db) > eps:
				canon_equal = false
	_ok(demonstrated_defect,
		"G-FS-CANON: facet_planar_corner DISAGREES at a shared edge (the pre-P0 defect — the ∝R planarization step, facet_atlas.gd:420)")
	_ok(canon_equal,
		"G-FS-CANON: facet_corner_dirs (canon) AGREE at every one of %d shared-corner pairs (in-face bit-equal, cross-face ≤1e-9)" % pair_count)
	_ok(cross_face_tested, "G-FS-CANON: at least one tested neighbour pair crosses a cube face (fixture fid=%d, face=%d)" % [fid, face_a])

func _edge_indices(slot: int, cells: int, stride: int) -> Array:
	var idx := []
	match slot:
		FA.S_EAST:
			for gj in range(stride): idx.append(gj * stride + cells)
		FA.S_WEST:
			for gj in range(stride): idx.append(gj * stride + 0)
		FA.S_NORTH:
			for gi in range(stride): idx.append(cells * stride + gi)
		_:
			for gi in range(stride): idx.append(0 * stride + gi)
	return idx

func _all_boundary_indices(cells: int, stride: int) -> Array:
	var idx := []
	for gj in range(stride):
		idx.append(gj * stride + 0)
		idx.append(gj * stride + cells)
	for gi in range(stride):
		idx.append(0 * stride + gi)
		idx.append(cells * stride + gi)
	return idx

## G-FS-WELD-EDGE + G-FS-NRM-CONT: two adjacent SAME-pitch (S4) tiles → shared-boundary vertex sets equal
## (≤1e-9·R_BLOCKS) and boundary normals equal (≤1e-4), tested across all 4 slots (incl. whichever crosses a
## cube face for this fixture). Matching is by NEAREST vertex among the neighbour's full boundary (order/
## orientation-agnostic — robust to any cross-face reindexing) rather than an assumed index correspondence.
func _gate_weld_edge_nrm(fid: int) -> void:
	var cells := FST.cells_for_tier(FST.S4)
	var stride := cells + 1
	var tile_a := FST.build_tile(fid, cells, 0.0, true)
	var pos_a: PackedVector3Array = tile_a["pos"]
	var nrm_a: PackedVector3Array = tile_a["nrm"]
	var slots := [FA.S_EAST, FA.S_WEST, FA.S_NORTH, FA.S_SOUTH]
	var edge_ok := true
	var nrm_ok := true
	var pairs_tested := 0
	var eps_pos := 1.0e-9 * FA.R_BLOCKS
	for slot in slots:
		var nb := FA.seam_neighbour(fid, slot)
		var tile_b := FST.build_tile(nb, cells, 0.0, true)
		var pos_b: PackedVector3Array = tile_b["pos"]
		var nrm_b: PackedVector3Array = tile_b["nrm"]
		var edge_a := _edge_indices(slot, cells, stride)
		var boundary_b := _all_boundary_indices(cells, stride)
		for ia in edge_a:
			var pa: Vector3 = pos_a[ia]
			var best_ib := -1
			var best_d := 1.0e18
			for ib in boundary_b:
				var d: float = pa.distance_squared_to(pos_b[ib])
				if d < best_d:
					best_d = d
					best_ib = ib
			pairs_tested += 1
			if sqrt(best_d) > eps_pos:
				edge_ok = false
			if (nrm_a[ia] - nrm_b[best_ib]).length() > 1.0e-4:
				nrm_ok = false
	_ok(edge_ok,
		"G-FS-WELD-EDGE: same-pitch (S4, cells=%d) adjacent tiles share bit-equal boundary vertex sets (≤1e-9·R) across all 4 slots" % cells)
	_ok(nrm_ok, "G-FS-NRM-CONT: boundary normals agree (≤1e-4) across the same adjacent pairs")
	_ok(pairs_tested == stride * 4, "G-FS-WELD-EDGE: tested all %d boundary vertices (%d slots × %d)" % [stride * 4, 4, stride])

## G-FS-WELD-MIXED: an S3 (fine) tile vs its `slot`-side S4 (coarse) IN-FACE neighbour. First demonstrates that the
## raw (pre-snap) fine boundary departs from the coarse tile's own straight edge (true relief is non-linear between
## coarse samples), then applies `FacetSmoothTier.snap_edges_to_coarse` and asserts the snapped fine boundary lies
## EXACTLY on that coarse chord (and that the fine tile's own coarse-index vertices already bit-match the
## neighbour there, by the law-2 canon-dir weld — no snap needed at those).
func _gate_weld_mixed(fid: int, slot: int) -> void:
	var fine_cells := FST.cells_for_tier(FST.S3)     # 52
	var coarse_cells := FST.cells_for_tier(FST.S4)   # 26
	var cstride := fine_cells / coarse_cells
	var nb := FA.seam_neighbour(fid, slot)
	_ok(_face_of(nb) == _face_of(fid), "G-FS-WELD-MIXED: fixture neighbour is in-face (direct index correspondence)")
	var fine_tile := FST.build_tile(fid, fine_cells, 0.0, true)
	var coarse_tile := FST.build_tile(nb, coarse_cells, 0.0, true)
	var fpos: PackedVector3Array = fine_tile["pos"]
	var cpos: PackedVector3Array = coarse_tile["pos"]
	var fstride := fine_cells + 1
	var cstride2 := coarse_cells + 1
	# `slot` = EAST on `fid` ⇒ fid's gi=cells column corresponds (same t) to nb's gi=0 (WEST) column, since nb sits
	# at fid's a+1 (facet_atlas.gd `_neigh_ab`/`_seam_edge_ij` §2.5 convention).
	var had_gap := false
	for gj in range(1, fine_cells):
		if gj % cstride == 0:
			continue
		var j0 := gj / cstride
		var j1 := mini(j0 + 1, coarse_cells)
		var lo := float(gj - j0 * cstride) / float(cstride)
		var chord: Vector3 = cpos[j0 * cstride2 + 0].lerp(cpos[j1 * cstride2 + 0], lo)
		if fpos[gj * fstride + fine_cells].distance_to(chord) > 1.0e-6:
			had_gap = true
	_ok(had_gap,
		"G-FS-WELD-MIXED: raw S3 boundary (pre-snap) departs from the S4 neighbour's straight chord (the crack law 4 fixes)")

	var snapped: PackedVector3Array = fpos.duplicate()
	FST.snap_edges_to_coarse(snapped, fine_cells, coarse_cells)
	var on_chord := true
	var coarse_exact := true
	for gj in range(0, fine_cells + 1):
		var j0 := gj / cstride
		var j1 := mini(j0 + 1, coarse_cells)
		var lo := float(gj - j0 * cstride) / float(cstride)
		var chord: Vector3 = cpos[j0 * cstride2 + 0].lerp(cpos[j1 * cstride2 + 0], lo)
		if snapped[gj * fstride + fine_cells].distance_to(chord) > 1.0e-6:
			on_chord = false
		if gj % cstride == 0:
			if snapped[gj * fstride + fine_cells].distance_to(cpos[(gj / cstride) * cstride2 + 0]) > 1.0e-9 * FA.R_BLOCKS:
				coarse_exact = false
	_ok(on_chord,
		"G-FS-WELD-MIXED: snapped S3 boundary lies exactly on the S4 neighbour's own straight chord (crack-free mixed-pitch weld)")
	_ok(coarse_exact,
		"G-FS-WELD-MIXED: S3's own coarse-index vertices already bit-match the S4 neighbour there (law-2 canon-dir weld)")
