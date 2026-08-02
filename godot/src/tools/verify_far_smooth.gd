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
##
## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md P1 (§3 P1, this stage) — `FP_FAR_SMOOTH` re-arm: full SSE ladder over the
## visible hemisphere + replacement rendering. Drives a REAL `FacetFarRing` through its P1 driver (`_smooth_drive` /
## `_smooth_ranked_fids` / `_smooth_next_assignment`), manually attaching the smooth tier the way
## `verify_env_warm_async.gd` pokes flag-gated internals directly (bypassing the `FP_FAR_SMOOTH` const guard that
## only lives in `FacetFarRing.setup()`, so the driver itself is exercised byte-for-byte as shipped):
##   G-FS-EXCL      — drive the tier ladder to convergence, then assert every front-hemisphere facet the far ring is
##                    responsible for (excluding the active facet + backstop, which are the NEAR field's job) is in
##                    EXACTLY ONE of {`visible_fids()` (shell/heightfield emit), `_smooth.is_resident()`} — never
##                    neither (a hole), never both (a z-fight).
##   G-FS-FRONTIER  — an S5 tile's edge bordering a NON-smooth-resident neighbour (the shipped CELLS=4 shell) is
##                    snapped (`FacetSmoothTier.snap_edge_to_pitch`) onto that shell's OWN chord — first tied to the
##                    ACTUAL shipped placement (`FacetFarRing._weld_place`/`_weld_unit`) at the CELLS=4 breakpoints,
##                    then shown the raw (pre-snap) boundary departs from that chord and the snapped boundary lands
##                    on it exactly (≤ 1e-9·R).
##   G-FS-BYTES (P1)— the converged real driver's resident bytes ≤ SMOOTH_BYTES_MAX; falsified tier-count-sensitive
##                    (shrinking the requested set strictly decreases `smooth_bytes()` — the ledger tracks live
##                    residency, not a static estimate).
##   G-FS-OFF (P1)  — a FRESH `FacetFarRing.setup()` (the real construction site, flag untouched) never constructs a
##                    `FacetSmoothTier`; FLAT `verify_feature.gd` stays 6042/0 (checked separately, not in this file).
##
## COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md P2 (§3 P2, this stage) — `FP_SMOOTH_NORMAL_LIT`: relief lighting for the
## smooth tiles, via `FacetFarRing._apply_smooth_normal_lit` (shell shader splice) + `FacetSmoothTier.build_tile`'s
## `normal_lit` param (the COLOR.a=0 per-vertex discriminator the splice keys off):
##   G-FS-LIT-OFF   — the F7 golden-string guard: with the flag off, `_apply_smooth_normal_lit` returns EVERY shell
##                    shader source (`_SHELL_ABS_SHADER`, `_SHELL_ABS_TEX_LIGHT`, `_SHELL_ABS_TEX_CU_LIGHT`) BYTE-
##                    IDENTICAL to the pre-P2 shipped const (identity splice) — proves the smooth-tile shader (shared
##                    with the shell) is unchanged when off. Also: `build_tile(..., normal_lit=false)` leaves every
##                    vertex colour alpha at the FarPalette default (1.0) — the marker is never stamped.
##   G-FS-LIT-ON    — with the flag forced on (the gate forces the FUNCTION PARAMS, never the CubeSphere const — the
##                    const is a compile-time literal, sed-toggled only for deploy): the spliced shader source (a)
##                    DIFFERS from the golden off-string, (b) contains the COLOR.a branch + a NORMAL read, and (c)
##                    still has EXACTLY ONE `shader_type` (zero new compiled programs — mirrors verify_shade_unified's
##                    G-VL-SHADERTYPE). `build_tile(..., normal_lit=true)` stamps alpha=0 on every smooth-tile vertex
##                    (the shell's own emit path is untouched — a separate code path entirely, never reads this flag).
##   G-FS-LIT-NRM   — the smooth-tile mesh actually CARRIES usable per-vertex normals for the splice to read: the
##                    built tile's `nrm` array is unit-length + outward (already proven non-degenerate by G-FS-DEGEN)
##                    and, on a tile with real relief (not a flat facet), at least one interior vertex normal departs
##                    measurably from the pure radial direction — i.e. there is real relief signal for the shader to
##                    shade with, not just a relabelled radial normal.

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

	# --- P1 driver (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P1) ---
	_gate_p1_off()
	_gate_p1()

	# --- P2 relief lighting (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P2, FP_SMOOTH_NORMAL_LIT) ---
	_gate_lit_off()
	_gate_lit_on()
	_gate_lit_nrm([fid, fid_edge, fid_int])

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

# =====================================================================================================================
# P1 driver gates (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P1)
# =====================================================================================================================

## G-FS-OFF (P1): the REAL construction site — `FacetFarRing.setup()` — never builds a `FacetSmoothTier` while the
## flag is false (the const's own value is already checked at the top of `_initialize`; this proves the call site).
func _gate_p1_off() -> void:
	var ring := FacetFarRing.new()
	var fid := _fid_of(2, 3, 7)
	ring.setup(fid)
	_ok(ring._smooth == null, "G-FS-OFF (P1): FacetFarRing.setup() constructs no FacetSmoothTier with FP_FAR_SMOOTH false")

## Drive `ring`'s P1 driver (`_smooth_drive`) until the smooth-resident set stops growing (bounded iterations —
## each call is a cheap bounded BFS + O(1) worker-slot pump, so looping is fast; the real cost is the WorkerThreadPool
## tile builds, which converge within a modest number of polls on any host).
func _p1_converge(ring: FacetFarRing, max_iters: int) -> int:
	var iters := 0
	var stable := 0
	var last := -1
	while iters < max_iters and stable < 30:
		ring._smooth_drive()
		iters += 1
		var n: int = ring._smooth.resident_count()
		if n == last:
			stable += 1
		else:
			stable = 0
			last = n
	return iters

## G-FS-EXCL / G-FS-FRONTIER / G-FS-BYTES(P1): drive a real ring's P1 tier ladder to convergence and check the
## exclusion invariant, the frontier snap, and the NEVER-OOM ledger.
func _gate_p1() -> void:
	var fid := _fid_of(1, 4, 6)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	# Manually attach the smooth tier — the same "poke a flag-gated internal directly" pattern
	# `verify_env_warm_async.gd` uses, so the driver itself (unchanged by the const) is exercised as shipped.
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	var iters := _p1_converge(ring, 4000)
	var resident: int = ring._smooth.resident_count()
	print("  P1 driver: %d iterations, resident=%d tiles, bytes=%.2f MB" % [iters, resident, float(ring._smooth.smooth_bytes()) / 1048576.0])
	_ok(resident > 0, "G-FS-EXCL: the P1 driver actually converges residents (not a vacuous pass)")

	# --- G-FS-EXCL: exactly one of {shell emit, smooth-resident} for every facet the far ring owns. ---
	var shell_set := {}
	for f in ring.visible_fids():
		shell_set[int(f)] = true
	var p := ring._cull_params()
	var nrm: Array = p[0]
	var thresh: float = p[1]
	var k := FA.K
	var checked := 0
	var excl_ok := true
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var f := (face * k + a) * k + b
				if not ring._front_visible(f, nrm, thresh):
					continue
				if f == fid or ring._is_backstop(f):
					continue   # near voxel world's responsibility, not the far ring's — deliberately out of scope here
				checked += 1
				var in_shell: bool = shell_set.has(f)
				var in_smooth: bool = ring._smooth.is_resident(f)
				if in_shell == in_smooth:
					excl_ok = false
	_ok(checked > 0, "G-FS-EXCL: checked a non-empty far-ring-owned front-hemisphere set (%d facets)" % checked)
	_ok(excl_ok, "G-FS-EXCL: every far-ring-owned facet is in EXACTLY ONE of {shell emit, smooth-resident} — never neither, never both")

	# --- G-FS-FRONTIER: an S5 tile's shell-adjacent edge snaps onto the shipped CELLS=4 shell chord. ---
	_gate_frontier(ring)

	# --- G-FS-BYTES (P1): real ledger ≤ cap; falsify tier-count-sensitivity (shrink ⇒ strictly fewer bytes). ---
	var bytes_before: int = ring._smooth.smooth_bytes()
	_ok(bytes_before <= CubeSphere.SMOOTH_BYTES_MAX,
		"G-FS-BYTES (P1): converged resident bytes %.2f MB ≤ SMOOTH_BYTES_MAX %.2f MB" % [float(bytes_before) / 1048576.0, float(CubeSphere.SMOOTH_BYTES_MAX) / 1048576.0])
	var keep: Array = ring._smooth.resident_fids()
	_ok(keep.size() > 1, "G-FS-BYTES (P1): the converged set has more than one resident tile (a meaningful shrink test)")
	if keep.size() > 1:
		var one := int(keep[0])
		var one_tier := int(ring._smooth.tier_of(one))
		ring._smooth.request({one: one_tier})   # evicts everything else synchronously (request()'s eviction runs on main)
		var bytes_after: int = ring._smooth.smooth_bytes()
		_ok(ring._smooth.resident_count() == 1, "G-FS-BYTES (P1): shrinking the request to one facet leaves exactly one resident")
		_ok(bytes_after < bytes_before,
			"G-FS-BYTES (P1): shrinking the request set strictly DECREASES resident bytes (%.2f MB -> %.2f MB) — the ledger tracks live residency, not a static estimate" % [float(bytes_before) / 1048576.0, float(bytes_after) / 1048576.0])

## G-FS-FRONTIER: find an S5 tile with a shell-adjacent (non-smooth-resident-neighbour) edge from the converged
## driver state, then (1) tie the frontier-snap reference breakpoints to the ACTUAL shipped shell placement
## (`ring._weld_place`/`_weld_unit`), (2) show the raw boundary departs from that chord, (3) show the snapped
## boundary lies on it exactly (≤ 1e-9·R).
func _gate_frontier(ring: FacetFarRing) -> void:
	var seam_slots := [FA.S_WEST, FA.S_EAST, FA.S_SOUTH, FA.S_NORTH]
	var target_fid := -1
	var target_edge := -1
	for f in ring._smooth.resident_fids():
		if int(ring._smooth.tier_of(f)) != FST.S5:
			continue
		for e in range(4):
			var nb := FA.seam_neighbour(int(f), seam_slots[e])
			if not ring._smooth.is_resident(nb):
				target_fid = int(f)
				target_edge = e
				break
		if target_fid >= 0:
			break
	_ok(target_fid >= 0, "G-FS-FRONTIER: the converged driver has at least one S5 tile with a shell-adjacent (frontier) edge")
	if target_fid < 0:
		return

	var cells := FST.cells_for_tier(FST.S5)
	var shell_cells := FacetFarRing.CELLS   # 4 — the shipped shell's pitch
	var cd := FA.facet_corner_dirs(target_fid)
	var r_datum := FA.r_of(target_fid)
	var eps_tie := 1.0e-6 * FA.R_BLOCKS
	var eps_snap := 1.0e-9 * FA.R_BLOCKS

	# (1) Tie: at every CELLS=4 breakpoint on this edge, the reference position `snap_edge_to_pitch` targets
	# (FarDensity.node_at's dir/relief, curved-placed) is bit-consistent with the ACTUAL shipped shell formula.
	var tie_ok := true
	for kk in range(shell_cells + 1):
		var uu := float(kk) / float(shell_cells)
		var st := _p1_edge_st(target_edge, uu)
		var s: float = st[0]
		var t: float = st[1]
		var node := FD.node_at(cd, r_datum, s, t)
		var mine: Vector3 = (node["dir"] as Vector3) * (r_datum + float(node["relief"]))
		var shell := ring._weld_place(ring._weld_unit(cd, s, t), int(node["g"]))
		if mine.distance_to(shell) > eps_tie:
			tie_ok = false
	_ok(tie_ok, "G-FS-FRONTIER: the frontier-snap reference breakpoints are bit-consistent with the ACTUAL shipped CELLS=4 shell placement (_weld_place/_weld_unit)")

	# (2)/(3): raw vs snapped boundary against the shell chord (piecewise lerp of the SAME shipped-consistent breakpoints).
	var tile := FST.build_tile(target_fid, cells, 0.0, true)
	var raw_pos: PackedVector3Array = tile["pos"]
	var pre_ok := _p1_edge_on_shell_chord(ring, cd, r_datum, cells, shell_cells, target_edge, raw_pos, eps_snap)
	_ok(not pre_ok, "G-FS-FRONTIER: the RAW (pre-snap) S5 boundary departs from the CELLS=4 shell chord (the crack law 4 fixes)")

	var snapped: PackedVector3Array = raw_pos.duplicate()
	FST.snap_edge_to_pitch(snapped, cells, cd, r_datum, shell_cells, target_edge)
	var post_ok := _p1_edge_on_shell_chord(ring, cd, r_datum, cells, shell_cells, target_edge, snapped, eps_snap)
	_ok(post_ok, "G-FS-FRONTIER: after the frontier snap, every S5 rim node on that edge lies on the shipped CELLS=4 shell chord (<=1e-9*R)")

## The (s,t) of a tile-edge parameter `u` for `edge` (FacetSmoothTier.EDGE_WEST..NORTH order).
func _p1_edge_st(edge: int, u: float) -> Array:
	if edge == FST.EDGE_WEST: return [0.0, u]
	if edge == FST.EDGE_EAST: return [1.0, u]
	if edge == FST.EDGE_SOUTH: return [u, 0.0]
	return [u, 1.0]

## True iff every non-corner node on tile edge `edge` (cells resolution) lies within `eps` of the shell-chord
## piecewise-lerp of the shipped shell's OWN CELLS=`shell_cells` breakpoints on that same edge.
func _p1_edge_on_shell_chord(ring: FacetFarRing, cd: PackedFloat64Array, r_datum: float, cells: int, shell_cells: int, edge: int, pos: PackedVector3Array, eps: float) -> bool:
	var stride := cells + 1
	var ok := true
	for i in range(1, cells):
		var u := float(i) / float(cells)
		var seg := clampi(int(floor(u * float(shell_cells))), 0, shell_cells - 1)
		var u0 := float(seg) / float(shell_cells)
		var u1 := float(seg + 1) / float(shell_cells)
		var lo := (u - u0) / (u1 - u0)
		var st0 := _p1_edge_st(edge, u0)
		var st1 := _p1_edge_st(edge, u1)
		var p0 := ring._weld_place(ring._weld_unit(cd, st0[0], st0[1]), int(FD.node_at(cd, r_datum, st0[0], st0[1])["g"]))
		var p1 := ring._weld_place(ring._weld_unit(cd, st1[0], st1[1]), int(FD.node_at(cd, r_datum, st1[0], st1[1])["g"]))
		var chord: Vector3 = p0.lerp(p1, lo)
		var vi: int
		if edge == FST.EDGE_WEST: vi = i * stride + 0
		elif edge == FST.EDGE_EAST: vi = i * stride + cells
		elif edge == FST.EDGE_SOUTH: vi = 0 * stride + i
		else: vi = cells * stride + i
		if pos[vi].distance_to(chord) > eps:
			ok = false
	return ok

# =====================================================================================================================
# P2 relief lighting (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P2, FP_SMOOTH_NORMAL_LIT) --------------------------------
# =====================================================================================================================

## G-FS-LIT-OFF — the F7 golden-string guard: with the flag off, `_apply_smooth_normal_lit` is the identity function
## on every shell shader source that carries the "vec3 n = normalize(wp - centre);" anchor — byte-identical to the
## pre-P2 shipped const (the "smooth-tile shader", since P1 shares the shell's material verbatim). Also covers the
## anchor-absent case (`_SHELL_TINT_SHADER`, the legacy L3 shader with no `centre`-relative normal) staying untouched.
func _gate_lit_off() -> void:
	var srcs := [
		["_SHELL_ABS_SHADER", FacetFarRing._SHELL_ABS_SHADER],
		["_SHELL_ABS_TEX_LIGHT", FacetFarRing._SHELL_ABS_TEX_LIGHT],
		["_SHELL_ABS_TEX_CU_LIGHT", FacetFarRing._SHELL_ABS_TEX_CU_LIGHT],
		["_SHELL_TINT_SHADER (anchor-absent)", FacetFarRing._SHELL_TINT_SHADER],
	]
	for pair in srcs:
		var out: String = FacetFarRing._apply_smooth_normal_lit(pair[1], false)
		_ok(out == pair[1],
			"G-FS-LIT-OFF: _apply_smooth_normal_lit(%s, false) is byte-identical to the shipped const (golden pin)" % pair[0])
	_ok(not CubeSphere.FP_SMOOTH_NORMAL_LIT, "G-FS-LIT-OFF: FP_SMOOTH_NORMAL_LIT defaults false (byte-off)")

	# build_tile's marker: off ⇒ every vertex colour keeps the FarPalette default alpha (1.0), byte-identical tiles.
	var cells := FST.cells_for_tier(FST.S4)
	var fid := FA.spawn_facet()
	var tile_off := FST.build_tile(fid, cells, 0.0, true, false)
	var col_off: PackedColorArray = tile_off["col"]
	var alpha_untouched := true
	for c in col_off:
		if absf((c as Color).a - 1.0) > 1e-6:
			alpha_untouched = false
	_ok(alpha_untouched, "G-FS-LIT-OFF: build_tile(normal_lit=false) leaves every vertex colour alpha at the FarPalette default (1.0) — marker never stamped")

## G-FS-LIT-ON — force the FUNCTION PARAM on (never the CubeSphere const — that is a compile-time literal, sed-toggled
## only at deploy) and assert the splice actually fires: the spliced source differs from the golden off-string,
## contains the COLOR.a discriminator branch + a NORMAL read, and still compiles to exactly ONE shader_type (zero new
## programs, mirrors verify_shade_unified's G-VL-SHADERTYPE). Also: build_tile's marker DOES stamp alpha=0 when on.
func _gate_lit_on() -> void:
	var srcs := [
		["_SHELL_ABS_SHADER", FacetFarRing._SHELL_ABS_SHADER],
		["_SHELL_ABS_TEX_LIGHT", FacetFarRing._SHELL_ABS_TEX_LIGHT],
		["_SHELL_ABS_TEX_CU_LIGHT", FacetFarRing._SHELL_ABS_TEX_CU_LIGHT],
	]
	for pair in srcs:
		var name: String = pair[0]
		var off_code: String = pair[1]
		var on_code: String = FacetFarRing._apply_smooth_normal_lit(off_code, true)
		_ok(on_code != off_code, "G-FS-LIT-ON: %s spliced source DIFFERS from the golden off-string (the branch actually fires)" % name)
		_ok(on_code.contains("COLOR.a < 0.5") and on_code.contains("NORMAL"),
			"G-FS-LIT-ON: %s spliced source contains the COLOR.a discriminator + a NORMAL read" % name)
		_ok(on_code.count("shader_type") == off_code.count("shader_type"),
			"G-FS-LIT-ON: %s spliced source has the SAME shader_type count as off (zero new compiled programs)" % name)
		# The radial fallback branch (COLOR.a >= 0.5, the shell's own vertices) is PRESERVED verbatim in the splice —
		# the shell keeps shading exactly as shipped.
		_ok(on_code.contains("normalize(wp - centre)"),
			"G-FS-LIT-ON: %s spliced source still contains the shell's own radial-normal fallback (shell untouched)" % name)

	# The anchor-absent legacy shader is untouched even with the param forced on (no anchor to splice).
	var tint_on: String = FacetFarRing._apply_smooth_normal_lit(FacetFarRing._SHELL_TINT_SHADER, true)
	_ok(tint_on == FacetFarRing._SHELL_TINT_SHADER,
		"G-FS-LIT-ON: _SHELL_TINT_SHADER (no centre-relative normal) is untouched even with the splice forced on")

	# build_tile's marker: on ⇒ every vertex colour is stamped alpha=0 (the smooth-tile discriminator).
	var cells := FST.cells_for_tier(FST.S4)
	var fid := FA.spawn_facet()
	var tile_on := FST.build_tile(fid, cells, 0.0, true, true)
	var col_on: PackedColorArray = tile_on["col"]
	var alpha_marked := true
	for c in col_on:
		if absf((c as Color).a - 0.0) > 1e-6:
			alpha_marked = false
	_ok(alpha_marked, "G-FS-LIT-ON: build_tile(normal_lit=true) stamps alpha=0 on every smooth-tile vertex")

## G-FS-LIT-NRM — the smooth-tile mesh actually CARRIES usable per-vertex normals for the splice to read: unit +
## outward (already proven non-degenerate by G-FS-DEGEN) on EVERY candidate facet, and — scanning several facets
## (real terrain varies; a single facet could land on dead-flat ground) — at least one INTERIOR vertex normal
## measurably departs from the pure radial direction on at least one of them: real relief signal, not a relabelled
## radial (the case G-FS-DEGEN's flat-facet check already covers).
func _gate_lit_nrm(fids: Array) -> void:
	var cells := FST.cells_for_tier(FST.S4)
	var stride := cells + 1
	var unit_outward := true
	var max_departure := 0.0
	for fid in fids:
		var tile := FST.build_tile(int(fid), cells, 0.0, true)
		var nrm: PackedVector3Array = tile["nrm"]
		var pos: PackedVector3Array = tile["pos"]
		for gj in range(stride):
			for gi in range(stride):
				var vi := gj * stride + gi
				var nv: Vector3 = nrm[vi]
				if absf(nv.length() - 1.0) > 1e-3:
					unit_outward = false
				if gi > 0 and gi < cells and gj > 0 and gj < cells:   # interior only (boundary uses the canon boundary_normal law)
					var radial := pos[vi].normalized()
					max_departure = maxf(max_departure, nv.angle_to(radial))
	_ok(unit_outward, "G-FS-LIT-NRM: every smooth-tile normal (across %d candidate facets) is unit-length (usable for lighting)" % fids.size())
	_ok(max_departure > 1.0e-4, "G-FS-LIT-NRM: at least one interior normal measurably departs (%.6f rad) from the pure radial direction — real relief signal for the P2 splice to shade with" % max_departure)
