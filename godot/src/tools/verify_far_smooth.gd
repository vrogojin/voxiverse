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

	# --- P3 near-collar (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3, FP_SMOOTH_RIM) ---
	_ok(not CubeSphere.FP_SMOOTH_RIM, "G-RIM-OFF: FP_SMOOTH_RIM defaults false (byte-off; `_rim_assign` is never called)")
	_gate_rim_env(fid_int)
	_gate_rim_weld(fid_int)
	_gate_rim_mbb()

	# --- REVISION 2 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 2 — live-failure root-cause + fix") ---
	_ok(not CubeSphere.FP_SMOOTH_STICKY, "G-R2-OFF: FP_SMOOTH_STICKY defaults false (byte-off)")
	_ok(not CubeSphere.FP_SMOOTH_MESH_INC, "G-R2-OFF: FP_SMOOTH_MESH_INC defaults false (byte-off)")
	_ok(not CubeSphere.FP_SMOOTH_SKIN_SLOT, "G-R2-OFF: FP_SMOOTH_SKIN_SLOT defaults false (byte-off)")
	_gate_fs_stable()
	_gate_fs_cover()
	_gate_fs_tier_adj()
	_gate_fs_colour()
	_gate_nf_height()
	_gate_fs_churn()

	# --- REVISION 3 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 3 — quiescence + no-hole commit model") ---
	# Stage 1 scope: Q1 (idle driver) + T2 (snapshot-gen handshake). Stage 2 scope (this stage): T1 (off-thread,
	# atomic tier-mesh commits). Q2 (slot indirection) and T3 (neighbour-aware weld refresh) are LATER stages — not
	# gated here.
	_ok(not CubeSphere.FP_SMOOTH_IDLE, "G-R3-OFF: FP_SMOOTH_IDLE defaults false (byte-off)")
	_ok(not CubeSphere.FP_SHELL_SNAP_GEN, "G-R3-OFF: FP_SHELL_SNAP_GEN defaults false (byte-off)")
	_ok(not CubeSphere.FP_SMOOTH_TXN, "G-R3-OFF: FP_SMOOTH_TXN defaults false (byte-off; step() takes the shipped ≤1-tier/frame main-thread path)")
	_gate_fs_quiesce()
	_gate_fs_nohole()
	_gate_fs_nohole_txn()
	_gate_fs_txn_thread()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- fixture helper: Earth fid at local (face,a,b) ---
func _fid_of(face: int, a: int, b: int) -> int:
	return (face * FA.K + a) * FA.K + b

func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(c[0], c[1], c[2])
	return s.normalized()

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

# =====================================================================================================================
# P3 near-collar gates (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md §3 P3, FP_SMOOTH_RIM) --------------------------------------
# =====================================================================================================================

## G-RIM-ENV — the envelope-inside-disc no-protrusion proof for `FacetSmoothTier.build_tile_rim`: every S2 vertex
## strictly inside R_env sits ≥ ε (`TierPlace.backstop_sink()`) below the true analytic surface — the SAME
## min-envelope construction proof `_env_weld_grid` already carries for the coarse-horizon/dense-backstop tiers
## (verify_no_protrusion.gd's G-NPT-*), generalized to S2's 104-cell pitch (the builder is cells-parametrized, reused
## verbatim). FALSIFY: a deliberately-broken build (sink forced NEGATIVE, which pushes the vertex artificially UP)
## DOES protrude at the SAME vertices — proving the check actually catches a real violation, not vacuously green.
func _gate_rim_env(fid: int) -> void:
	print("  --- G-RIM-ENV: S2 near-collar — every vertex inside R_env sits at min-envelope minus ε (never protrudes) ---")
	var cells := FST.cells_for_tier(FST.S2)
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var player_col: Vector3 = centre_node["pos"]
	var r_env := 80.0
	var feather := CubeSphere.RIM_FEATHER_BLOCKS
	var sink := TierPlace.backstop_sink()
	var stride := cells + 1
	var inv := 1.0 / float(cells)

	var tile := FST.build_tile_rim(fid, cells, player_col, r_env, feather, sink)
	var pos: PackedVector3Array = tile["pos"]
	var bad_tile := FST.build_tile_rim(fid, cells, player_col, r_env, feather, -5000.0)   # deliberately-broken contrast
	var bad_pos: PackedVector3Array = bad_tile["pos"]

	var inside_checked := 0
	var min_margin := 1.0e30
	var min_bad_margin := 1.0e30
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var node := FD.node_at(corner_dirs, r_datum, s, t)
			var true_pos: Vector3 = node["pos"]
			if true_pos.distance_to(player_col) > r_env:
				continue    # only assert the STRICT ε-margin claim strictly inside the disc (w == 0 exactly there)
			inside_checked += 1
			var vi := gj * stride + gi
			var d: Vector3 = node["dir"]
			var true_relief := float(node["relief"])
			var rendered_relief := (pos[vi] - d * r_datum).dot(d)
			min_margin = minf(min_margin, true_relief - rendered_relief)
			var bad_relief := (bad_pos[vi] - d * r_datum).dot(d)
			min_bad_margin = minf(min_bad_margin, true_relief - bad_relief)
	_ok(inside_checked > 0, "G-RIM-ENV: %d S2 vertices fall strictly inside R_env=%.0f (fixture exercises the disc branch)" % [inside_checked, r_env])
	_ok(min_margin >= sink - 1.0e-3, "G-RIM-ENV: every inside-disc S2 vertex sits >= eps=%.2f below true (worst margin %.3f) — never protrudes through the near blocky terrain" % [sink, min_margin])
	_ok(min_bad_margin < 0.0, "G-RIM-ENV-FALSIFY: a deliberately-broken build (sink forced negative) DOES protrude (worst margin %.3f < 0) — the check is not vacuous" % min_bad_margin)

## G-RIM-WELD — two S2 tiles spanning the disc (built with the SAME frozen player_col/r_env/feather — the batch
## contract `_rim_assign`/`FacetSmoothTier.set_rim_params` freezes) share bit-equal shared-boundary vertices: the
## feather is position-keyed, so identical world position + identical frozen inputs ⇒ identical blend on both sides.
func _gate_rim_weld(fid: int) -> void:
	print("  --- G-RIM-WELD: two S2 tiles built with the SAME frozen player-column/R_env/feather weld at their shared edge ---")
	var cells := FST.cells_for_tier(FST.S2)
	var stride := cells + 1
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var player_col: Vector3 = centre_node["pos"]
	var r_env := 80.0
	var feather := CubeSphere.RIM_FEATHER_BLOCKS
	var sink := TierPlace.backstop_sink()
	var tile_a := FST.build_tile_rim(fid, cells, player_col, r_env, feather, sink)
	var pos_a: PackedVector3Array = tile_a["pos"]
	var slots := [FA.S_EAST, FA.S_WEST, FA.S_NORTH, FA.S_SOUTH]
	var edge_ok := true
	var pairs_tested := 0
	var eps_pos := 1.0e-6 * FA.R_BLOCKS
	for slot in slots:
		var nb := FA.seam_neighbour(fid, slot)
		var tile_b := FST.build_tile_rim(nb, cells, player_col, r_env, feather, sink)
		var pos_b: PackedVector3Array = tile_b["pos"]
		var edge_a := _edge_indices(slot, cells, stride)
		var boundary_b := _all_boundary_indices(cells, stride)
		for ia in edge_a:
			var pa: Vector3 = pos_a[ia]
			var best_d := 1.0e18
			for ib in boundary_b:
				best_d = minf(best_d, pa.distance_squared_to(pos_b[ib]))
			pairs_tested += 1
			if sqrt(best_d) > eps_pos:
				edge_ok = false
	_ok(pairs_tested == stride * 4, "G-RIM-WELD: tested all %d boundary vertices across 4 slots" % (stride * 4))
	_ok(edge_ok, "G-RIM-WELD: S2 tiles built with the SAME frozen player-column/R_env/feather share bit-equal boundary vertices (<=1e-6*R) — the blend survives the weld canon")

## G-RIM-MBB — drives a REAL ring's P3 driver (pool + S2 assignment), including a deliberate mid-run REBUILD-CADENCE
## churn (the player column jumps > RIM_REBUILD_BLOCKS, forcing `force_rebake` on every resident S2 tile), and
## asserts every backstop-role facet (active ∪ live-pool) is, on EVERY step, in EXACTLY ONE of {the far ring's own
## emit set (`visible_fids()`), a resident S2 tile} — never neither (a hole), never both (a z-fight). This is the
## G-FS-EXCL invariant extended to precisely the set G-FS-EXCL deliberately skips ("near voxel world's
## responsibility... deliberately out of scope there"). Driven OFF-SURFACE (`shell_set_camera_abs(floored=false)`,
## the G-NPT-ORBIT technique) so `visible_fids()`'s active/excluded skip is disengaged and a backstop-role facet's
## presence there is governed PURELY by the law-6 S2-residency exclusion under test — sed-independent of
## FP_FARRING_FULL_COVER (whose sunk-quad emit is the real deploy target, but needs its own sed run — see
## verify_no_protrusion.gd's precondition — to exercise; the underlying make-before-break MECHANISM under test here,
## visible_fids()'s law-6 filter vs `_rim_assign`/`force_rebake`, is identical either way). Pokes `_rim_assign`
## directly (bypassing the `FP_SMOOTH_RIM` compile-time guard) — the same "poke a flag-gated internal directly"
## pattern `verify_env_warm_async.gd` uses and this very file's `_gate_p1` already relies on for `ring._smooth`.
func _gate_rim_mbb() -> void:
	print("  --- G-RIM-MBB: backstop-role facets are NEVER without a drawable role (ring emit XOR resident S2) ---")
	var fid := _fid_of(3, 8, 9)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	var pool := PackedInt32Array()
	for slot in range(4):
		var nb := FA.seam_neighbour(fid, slot)
		if nb >= 0:
			pool.append(nb)
	ring.set_pool_excluded(pool)
	var c := _centre_dir(fid)
	ring.shell_set_camera_abs([c.x, c.y, c.z], FA.R_BLOCKS + 1323.0, false)
	_ok(bool(ring._shell_orbit()), "G-RIM-MBB: ring engaged into the off-surface regime (active/excluded skip disengaged)")

	var probe := PackedInt32Array([fid])
	for f in pool:
		probe.append(int(f))

	var col_a := c * (FA.R_BLOCKS + 5.0)
	var col_b := _centre_dir(int(pool[0])) * (FA.R_BLOCKS + 5.0)
	ring.set_player_column(col_a)

	var never_neither := true
	var never_both := true
	var ever_s2 := false
	var steps := 0
	for iter in range(300):
		if iter == 150:
			ring.set_player_column(col_b)   # §2.1 cadence churn: drift > RIM_REBUILD_BLOCKS ⇒ force_rebake fires
		var ranked = ring._smooth_ranked_fids(ring._active_fid)
		var assign = ring._smooth_next_assignment(ranked)
		assign = ring._rim_assign(assign)
		ring._smooth.request(assign)
		ring._smooth.step()
		ring._smooth.consume_changed()
		steps += 1
		var visible := {}
		for f in ring.visible_fids():
			visible[int(f)] = true
		for f in probe:
			var in_visible: bool = visible.has(int(f))
			var in_s2: bool = ring._smooth.is_resident(int(f)) and int(ring._smooth.tier_of(int(f))) == FST.S2
			if in_s2:
				ever_s2 = true
			if not in_visible and not in_s2:
				never_neither = false
			if in_visible and in_s2:
				never_both = false
	_ok(steps > 0, "G-RIM-MBB: drove %d steps of the P3 driver (incl. a mid-run rebuild-cadence churn)" % steps)
	_ok(ever_s2, "G-RIM-MBB: at least one backstop-role facet converged to a resident S2 tile (not a vacuous pass)")
	_ok(never_neither, "G-RIM-MBB: every backstop-role facet is drawn every step (ring emit or resident S2) — never neither (no hole)")
	_ok(never_both, "G-RIM-MBB: never both the ring emit AND a resident S2 tile simultaneously (no z-fight)")
	ring.free()

# =====================================================================================================================
# REVISION 2 gates (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 2 — live-failure root-cause + fix") ----------
# These encode what the P0-P3 gates above MISSED (§ R.3): camera-coupled residency (G-FS-STABLE), the stale-shell
# hole window (G-FS-COVER, replacing the weak set-level G-FS-EXCL with a COMMITTED-mesh check), skin parity
# (G-FS-COLOUR), the equal-height rim (G-NF-HEIGHT — THE acceptance gate), tier-ladder adjacency + code arbitration
# (G-FS-TIER-ADJ), and build/discard churn (G-FS-CHURN). All new flags (FP_SMOOTH_STICKY/MESH_INC/SKIN_SLOT) are
# poked as INTERNAL functions directly (the same "poke a flag-gated internal directly" pattern G-FS-LIT-ON /
# G-RIM-MBB already use above), since GDScript consts are compile-time and this file runs with every REVISION 2 flag
# at its shipped default (false) — the const-off byte-identity is asserted separately (G-R2-OFF above / FLAT run).
# =====================================================================================================================

## Manual-orchestration equivalent of `FacetFarRing._smooth_drive()` under FP_SMOOTH_STICKY (always) and, optionally,
## FP_SMOOTH_RIM / FP_SMOOTH_MESH_INC — bypasses the compile-time const guards by calling the same private helpers
## `_smooth_drive` itself would call (mirrors `_gate_rim_mbb`'s existing inline orchestration of the LEGACY driver).
func _sticky_drive_step(ring: FacetFarRing, use_rim: bool, use_mesh_inc: bool) -> void:
	if ring._active_fid != ring._sticky_active_fid:
		ring._sticky_target = ring._smooth_hop_assignment(ring._active_fid)
		ring._sticky_active_fid = ring._active_fid
	var assign := ring._sticky_apply_dwell(ring._sticky_target)
	if use_rim:
		assign = ring._rim_assign(assign)
	if use_mesh_inc:
		assign = ring._mesh_inc_gate(assign)
	ring._smooth.request(assign)
	ring._smooth.step()
	ring._smooth.consume_changed()

func _dict_eq(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k) or b[k] != a[k]:
			return false
	return true

## G-FS-STABLE (LAW R-A, the user's #1 ask) — drive the driver over a scripted path (facet crossings + camera/heading
## turns at a FIXED position); assert NO facet flips more than the crossings warrant, and ZERO evictions caused by a
## camera turn alone. First FALSIFIES the failure mode being fixed (the LEGACY camera-culled ranking genuinely
## changes under a pure axis turn), then proves the NEW hop-ring assignment does not.
func _gate_fs_stable() -> void:
	print("  --- REVISION 2 G-FS-STABLE: hop-ring residency is camera-independent; changes ONLY at a facet crossing ---")
	var fid_a := _fid_of(1, 8, 8)
	var ring := FacetFarRing.new()
	ring.setup(fid_a)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)

	# (1) FALSIFY the failure this law replaces: the LEGACY per-frame camera-culled ranking DOES change on a pure
	# camera-axis turn (no crossing, no player movement) — establishes the contrast is real, not a strawman.
	ring.shell_set_camera_abs([1.0, 0.0, 0.0], FA.R_BLOCKS + 50.0, true)
	var ranked1 := ring._smooth_ranked_fids(fid_a)
	ring.shell_set_camera_abs([0.0, 1.0, 0.0], FA.R_BLOCKS + 50.0, true)
	var ranked2 := ring._smooth_ranked_fids(fid_a)
	_ok(ranked1 != ranked2,
		"G-FS-STABLE-FALSIFY: the LEGACY camera-culled _smooth_ranked_fids result CHANGES on a pure camera turn — the exact root cause (R.1.a.2) R-A replaces, not a strawman")

	# (2) R-A: the hop-ring target is IDENTICAL across the SAME camera turns (no _front_visible/cull-axis dependency
	# anywhere in `_smooth_hop_assignment`).
	var target1 := ring._smooth_hop_assignment(fid_a)
	ring.shell_set_camera_abs([1.0, 0.0, 0.0], FA.R_BLOCKS + 50.0, true)
	var target2 := ring._smooth_hop_assignment(fid_a)
	ring.shell_set_camera_abs([0.0, 0.0, 1.0], FA.R_BLOCKS + 50.0, true)
	var target3 := ring._smooth_hop_assignment(fid_a)
	ring.shell_set_camera_abs([0.7071, 0.7071, 0.0], FA.R_BLOCKS + 50.0, true)
	var target4 := ring._smooth_hop_assignment(fid_a)
	_ok(target1.size() > 3, "G-FS-STABLE: hop assignment is non-trivial (%d facets, non-vacuous)" % target1.size())
	_ok(_dict_eq(target1, target2) and _dict_eq(target2, target3) and _dict_eq(target3, target4),
		"G-FS-STABLE: the hop-ring assignment is BIT-IDENTICAL across 4 different camera axes at the same active facet (R-A: camera-independent by construction)")

	# (3) drive the full sticky (+ mesh-inc) pipeline through repeated camera turns at a FIXED active facet; assert
	# the converged resident set is unchanged by a further sweep of turns (zero turn-caused churn end-to-end).
	var axes := [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [0.7071, 0.7071, 0.0]]
	var snap_after: Dictionary = {}
	for pass_i in range(2):
		for axis in axes:
			ring.shell_set_camera_abs(axis, FA.R_BLOCKS + 50.0, true)
			for k in range(300):
				_sticky_drive_step(ring, false, true)
		var snap := {}
		for f in ring._smooth.resident_fids():
			snap[int(f)] = int(ring._smooth.tier_of(f))
		if pass_i == 0:
			snap_after = snap
		else:
			_ok(snap.size() > 0, "G-FS-STABLE: the driven resident set is non-empty (non-vacuous end-to-end drive)")
			_ok(_dict_eq(snap_after, snap),
				"G-FS-STABLE: the FULL driven resident set is UNCHANGED after a second complete sweep of camera turns at the same active facet (zero turn-caused evictions end-to-end)")

	# (4) a REAL crossing DOES change the target (the mechanism is not frozen forever — it tracks the active facet).
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	ring._active_fid = fid_b
	var target_b := ring._smooth_hop_assignment(fid_b)
	_ok(not _dict_eq(target1, target_b),
		"G-FS-STABLE: the hop-ring target DOES change across a real facet crossing (residency tracks the active facet, not frozen)")
	ring.free()

## G-FS-COVER (rendered coverage, COMMITTED-mesh level — replaces the weak set-level G-FS-EXCL, R.1.a.3's stale-
## shell hole window). Drives real crossings through the sticky+mesh-inc pipeline with periodic REAL shell commits
## (`force_rebuild`, mirroring the batched/debounced cadence); every facet the driver has ever targeted must, at
## EVERY subsequent step, be drawn by >=1 COMMITTED mesh: `is_emitted` (the shell's LAST ACTUAL commit, not a live
## recompute of `visible_fids()`) OR a currently-resident smooth tile. A stale-shell/evicted-tile hole fails this.
func _gate_fs_cover() -> void:
	print("  --- REVISION 2 G-FS-COVER: every facet ever targeted is drawn by >=1 COMMITTED mesh (not merely 'in a set') ---")
	var fid_a := _fid_of(2, 6, 6)
	var ring := FacetFarRing.new()
	ring.setup(fid_a)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	ring.force_rebuild()

	var watch := {}
	var cover_ok := true
	var checked_steps := 0
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	var fid_c := FA.seam_neighbour(fid_b, FA.S_NORTH)
	var crossings := [fid_a, fid_b, fid_c]
	for c in crossings:
		ring._active_fid = int(c)
		for step in range(150):
			_sticky_drive_step(ring, false, true)
			for f in ring._sticky_target.keys():
				watch[int(f)] = true
			if step % 4 == 0:
				ring.force_rebuild()   # a real, periodic shell commit (mirrors the batched re-emit cadence)
			checked_steps += 1
			for f in watch.keys():
				var committed: bool = ring.is_emitted(int(f)) or ring._smooth.is_resident(int(f))
				if not committed:
					cover_ok = false
	_ok(watch.size() > 3, "G-FS-COVER: exercised a meaningful watch-set across %d crossings (%d facets ever targeted)" % [crossings.size(), watch.size()])
	_ok(checked_steps > 0, "G-FS-COVER: drove %d steps" % checked_steps)
	_ok(cover_ok, "G-FS-COVER: every facet ever targeted by the sticky driver is, at EVERY subsequent step, drawn by >=1 COMMITTED mesh — never a stale-shell hole during the leaving handshake")
	ring.free()

## G-FS-TIER-ADJ — adjacent resident facets differ by <=1 tier (no patchwork holes); no shell/blocky facet strictly
## inside the smooth disc (LAW R-E: `FacetBlockLodLadder.assign_levels` never classifies a smooth-owned facet).
func _gate_fs_tier_adj() -> void:
	print("  --- REVISION 2 G-FS-TIER-ADJ: adjacent hop-ring tiers differ by <=1; no blocky-LOD facet inside the smooth disc ---")
	var fid := _fid_of(0, 10, 10)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	var target := ring._smooth_hop_assignment(fid)
	var adj_ok := true
	var pairs_tested := 0
	var slots := [FA.S_EAST, FA.S_WEST, FA.S_NORTH, FA.S_SOUTH]
	for f in target.keys():
		var t: int = int(target[f])
		for slot in slots:
			var nb := FA.seam_neighbour(int(f), slot)
			if not target.has(nb):
				continue
			pairs_tested += 1
			if absi(t - int(target[nb])) > 1:
				adj_ok = false
	_ok(pairs_tested > 0, "G-FS-TIER-ADJ: tested %d adjacent hop-ring-assigned pairs (non-vacuous)" % pairs_tested)
	_ok(adj_ok, "G-FS-TIER-ADJ: every adjacent pair of hop-ring-assigned facets differs by <=1 tier")

	# R-E code arbitration: FacetBlockLodLadder.assign_levels must never classify a facet the smooth tier owns. Use
	# only the NEAR S3 ring (hop<=2) as the "smooth-owned" set for this check — the full hop<=10 `target` would
	# swallow the ladder's ENTIRE (much closer-in) BFS reach and make "classified a non-empty set" vacuously true
	# for the wrong reason (nothing left to classify at all, not "arbitration correctly excluded it").
	var near_owned := {}
	for f in target.keys():
		if int(target[f]) == FST.S3:
			near_owned[int(f)] = true
	var ladder := FacetBlockLodLadder.new()
	ladder.set_smooth_query(func(f): return near_owned.has(int(f)))
	var by_level := ladder.assign_levels(fid)
	var leaked := false
	var total_classified := 0
	for lvl in by_level:
		for f in by_level[lvl]:
			total_classified += 1
			if near_owned.has(int(f)):
				leaked = true
	_ok(total_classified > 0, "G-FS-TIER-ADJ: the ladder classified a non-empty set (the arbitration check isn't vacuous)")
	_ok(not leaked, "G-FS-TIER-ADJ (LAW R-E): FacetBlockLodLadder.assign_levels NEVER classifies a smooth-resident facet into a blocky level — code-level arbitration, not deploy-sed")
	# FALSIFY: without the query wired (the pre-R-E state), the SAME smooth-owned facets DO get classified —
	# proving the check is not vacuously true regardless of wiring.
	var ladder_unwired := FacetBlockLodLadder.new()
	var by_level_unwired := ladder_unwired.assign_levels(fid)
	var leaked_unwired := false
	for lvl in by_level_unwired:
		for f in by_level_unwired[lvl]:
			if near_owned.has(int(f)):
				leaked_unwired = true
	_ok(leaked_unwired, "G-FS-TIER-ADJ-FALSIFY: WITHOUT the R-E query wired, the ladder DOES classify smooth-owned facets — proves set_smooth_query is the thing actually preventing the leak above")
	ladder.free()
	ladder_unwired.free()
	ring.free()

## G-FS-COLOUR (LAW R-C, skin parity) — a smooth tile's per-vertex UV2 skin slot equals the shell's `_slot_of` slot
## for that column; a hard-coded `(face,-1)` tile (the pre-R-C defect — the grey lump) FAILS this.
func _gate_fs_colour() -> void:
	print("  --- REVISION 2 G-FS-COLOUR: smooth tile skin slot == shell skin slot for that column (kills the grey lump) ---")
	var fid := _fid_of(1, 3, 3)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._band_slot_snapshot[fid] = 7   # force a nonzero (real, non-default) band slot so parity is a meaningful test
	var slot: float = ring._slot_of(fid)
	_ok(absf(slot - float(64 + 7)) < 1e-6, "G-FS-COLOUR: fixture band slot resolves to the expected UV2.y (%.1f)" % slot)

	var cells := FST.cells_for_tier(FST.S4)
	var tile_parity := FST.build_tile(fid, cells, 0.0, true, false, slot)
	var uv2: PackedVector2Array = tile_parity["uv2"]
	var parity_ok := true
	for v in uv2:
		if absf((v as Vector2).y - slot) > 1e-6:
			parity_ok = false
	_ok(parity_ok, "G-FS-COLOUR: build_tile(slot=%.1f) stamps the SAME slot on every vertex — parity with the shell's _slot_of for this column" % slot)

	# FALSIFY: the pre-R-C hard-coded default (-1, no slot arg) must NOT match the real band slot.
	var tile_default := FST.build_tile(fid, cells, 0.0, true, false)
	var uv2_default: PackedVector2Array = tile_default["uv2"]
	var mismatch := false
	for v in uv2_default:
		if absf((v as Vector2).y - slot) > 1e-6:
			mismatch = true
	_ok(mismatch, "G-FS-COLOUR-FALSIFY: the pre-R-C hard-coded (face,-1) tile does NOT match the real band slot (%.1f) — exactly the grey-lump defect this gate must catch" % slot)

	# build_tile_rim (the S2 collar) carries the SAME parity.
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var tile_rim := FST.build_tile_rim(fid, FST.cells_for_tier(FST.S2), centre_node["pos"], 80.0, CubeSphere.RIM_FEATHER_BLOCKS, TierPlace.backstop_sink(), false, slot)
	var uv2_rim: PackedVector2Array = tile_rim["uv2"]
	var rim_parity_ok := true
	for v in uv2_rim:
		if absf((v as Vector2).y - slot) > 1e-6:
			rim_parity_ok = false
	_ok(rim_parity_ok, "G-FS-COLOUR: build_tile_rim(slot=%.1f) ALSO carries the same skin-slot parity on the S2 collar" % slot)
	ring.free()

## G-NF-HEIGHT (LAW R-D — THE acceptance gate): the far tier's boundary-ring vertex height == the near ground truth
## `g` for that column. Three parts: (a) FALSIFY — quantify the LEGACY interim gap (the plain full sink, R.1.d's
## "FAR renders below NEAR"); (b) R-D's reduced interim ε-sink (pre-first-S2-commit) is a measured, wired-through
## improvement; (c) once an S2 tile exists — a PURE function of its frozen inputs, so this holds at EVERY call,
## "including every not-yet-converged" driver state by construction — every vertex beyond the feather (the boundary
## ring, where near voxels do NOT occupy the column) equals TRUE height EXACTLY. Strictly INSIDE R_env (under the
## player's own near voxels) height is intentionally <= true (no-protrusion), never claimed equal — see the report.
func _gate_nf_height() -> void:
	print("  --- REVISION 2 G-NF-HEIGHT (the acceptance gate): far boundary-ring height == near truth, incl. mid-stream ---")
	var fid := _fid_of(2, 9, 9)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)

	# (a)/(b): compare the LEGACY full-sink emit against the R-D reduced-interim-sink emit for the SAME (uncommitted)
	# facet — both are radial pushes of the SAME underlying `_bpos_cache[fid]` truth reference, so their difference
	# is EXACTLY the sink amount (no confounders).
	_ok(int(ring._smooth.tier_of(fid)) != FST.S2, "G-NF-HEIGHT fixture: no S2 tile resident yet (testing the pre-commit interim floor)")
	var legacy_positions := ring.backstop_rendered_positions(fid)        # plain full sink (pre-R-D)
	var interim_positions := ring.backstop_rendered_positions_live(fid, true)  # R-D reduced ε-sink (rim_on forced — poke the internal, not the const)
	_ok(TierPlace.backstop_sink_rim() < TierPlace.backstop_sink(),
		"G-NF-HEIGHT: R-D's interim ε-sink (%.2f blk) is strictly smaller than the legacy full sink (%.2f blk) — a real, quantified improvement" % [TierPlace.backstop_sink_rim(), TierPlace.backstop_sink()])
	var expect_gap := TierPlace.backstop_sink() - TierPlace.backstop_sink_rim()
	var wired_ok := true
	for i in range(legacy_positions.size()):
		var gap: float = legacy_positions[i].distance_to(interim_positions[i])
		if absf(gap - expect_gap) > 1e-3:
			wired_ok = false
	_ok(wired_ok, "G-NF-HEIGHT: the LIVE emit actually narrows the pre-commit interim gap by exactly (legacy_sink - rim_sink) = %.2f blocks, end-to-end (not just at the formula level)" % expect_gap)

	# (c) THE hard equality: once an S2 tile is built (a pure function — holds unconditionally, i.e. at every driver
	# state including not-yet-converged), every vertex beyond R_env+feather equals TRUE height EXACTLY.
	var cells := FST.cells_for_tier(FST.S2)
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var player_col: Vector3 = centre_node["pos"]
	var r_env := 60.0
	var feather := CubeSphere.RIM_FEATHER_BLOCKS
	var sink := TierPlace.backstop_sink()
	var rim_tile := FST.build_tile_rim(fid, cells, player_col, r_env, feather, sink)
	var true_tile := FST.build_tile(fid, cells, 0.0, true)
	var rim_pos: PackedVector3Array = rim_tile["pos"]
	var true_pos: PackedVector3Array = true_tile["pos"]
	var beyond_checked := 0
	var equal_ok := true
	var inside_never_above := true
	for i in range(rim_pos.size()):
		var dist := true_pos[i].distance_to(player_col)
		if dist > r_env + feather:
			beyond_checked += 1
			if rim_pos[i].distance_to(true_pos[i]) > 1.0e-4:
				equal_ok = false
		elif dist <= r_env:
			# inside the disc: intentionally <= true (no-protrusion), never above it — the complementary law, not
			# claimed equal (near voxels occupy this column; see the report's disclosed scope of this gate).
			var d: Vector3 = true_pos[i].normalized()
			if (rim_pos[i] - true_pos[i]).dot(d) > 1.0e-3:
				inside_never_above = false
	_ok(beyond_checked > 0, "G-NF-HEIGHT: %d vertices sampled beyond the feather (the boundary-ring claim is non-vacuous)" % beyond_checked)
	_ok(equal_ok, "G-NF-HEIGHT: EVERY committed-S2-tile vertex beyond R_env+feather equals TRUE near-ground height EXACTLY (<=1e-4 blk) — far == near at the boundary ring, by construction, at any driver state")
	_ok(inside_never_above, "G-NF-HEIGHT: strictly inside R_env the S2 vertex NEVER rises above true height (the complementary no-protrusion law — not claimed equal, since near voxels occupy that column)")
	ring.free()

## G-FS-CHURN (work budget) — over a driven path: builds-per-facet <=2 for every currently-resident facet, 0
## discarded builds. First falsifies non-vacuously (a contrived want-moved-mid-flight scenario DOES discard).
func _gate_fs_churn() -> void:
	print("  --- REVISION 2 G-FS-CHURN: builds-per-facet <=2, 0 discarded builds, over a driven sticky+mesh-inc path ---")
	var fid_a := _fid_of(0, 8, 8)
	var ring := FacetFarRing.new()
	ring.setup(fid_a)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)

	# (1) FALSIFY non-vacuous: a want-moved-mid-flight scenario DOES increment discarded_count. `OS.delay_msec`
	# between polls gives the background WorkerThreadPool task REAL wall-clock time to finish (a tight zero-delay
	# poll loop can spin thousands of times before the OS thread gets scheduled at all, which is what starved the
	# very first version of this check) — never touches WorkerThreadPool directly (that stays FacetSmoothTier's job).
	var probe_fid := FA.seam_neighbour(fid_a, FA.S_EAST)
	ring._smooth.request({int(probe_fid): FST.S3})
	ring._smooth.step()          # dispatches the build (worker task now in flight)
	ring._smooth.request({})     # `_want` no longer includes probe_fid WHILE its build is still in flight
	var waited_ms := 0
	while ring._smooth.discarded_count() == 0 and waited_ms < 4000:
		OS.delay_msec(2)
		ring._smooth.step()
		waited_ms += 2
	_ok(ring._smooth.discarded_count() >= 1, "G-FS-CHURN-FALSIFY: a want-moved-mid-flight scenario DOES increment discarded_count (%d) — the counter is not dead code" % ring._smooth.discarded_count())

	# (2) drive the REAL sticky+mesh-inc path across a crossing and assert the budget.
	var ring2 := FacetFarRing.new()
	ring2.setup(fid_a)
	ring2._smooth = FST.new()
	ring2._smooth.setup_instance(ring2, null)
	for step in range(2000):
		_sticky_drive_step(ring2, false, true)
	var fid_b := FA.seam_neighbour(fid_a, FA.S_WEST)
	ring2._active_fid = fid_b
	for step in range(2000):
		_sticky_drive_step(ring2, false, true)
	var over_budget := false
	var max_dispatch := 0
	var resident_n: int = ring2._smooth.resident_fids().size()
	for f in ring2._smooth.resident_fids():
		var dc: int = ring2._smooth.dispatch_count(int(f))
		max_dispatch = maxi(max_dispatch, dc)
		if dc > 2:
			over_budget = true
	_ok(resident_n > 0, "G-FS-CHURN: the driven path converged a non-empty resident set (%d tiles)" % resident_n)
	_ok(not over_budget, "G-FS-CHURN: every currently-resident facet was built <=2 times across the driven crossing (max observed: %d)" % max_dispatch)
	_ok(ring2._smooth.discarded_count() == 0, "G-FS-CHURN: ZERO discarded builds over the sticky+mesh-inc driven path (make-before-break never throws away a finished tile)")
	ring.free()
	ring2.free()

# =====================================================================================================================
# REVISION 3 STAGE 1 gates (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 3 — quiescence + no-hole commit
# model", laws Q1 `FP_SMOOTH_IDLE` + T2 `FP_SHELL_SNAP_GEN` ONLY — T1/Q2/Q3 are LATER stages, not gated here). Both
# flags are poked via defaulted function PARAMETERS (`_smooth_drive`/`request`/`step`/`_mesh_inc_gate`/
# `_recompute_want_sse`/`_recompute_band_want_sse` all take an `..._on := CubeSphere.FP_..._FLAG` param) — the SAME
# "poke a flag-gated internal directly" pattern this file already relies on throughout (the consts themselves stay
# compile-time false, so FLAT `verify_feature` is unaffected by anything in this section).
# =====================================================================================================================

## G-FS-QUIESCE (partial — the Q1 DRIVER's contribution only; scope per the stage brief). Three independent,
## non-vacuous sub-checks, each: (a) prove the counter actually does real work during warm-up/perturbation (not a
## vacuous always-0 counter), (b) prove it goes FLAT (zero further mutation) once nothing changes, (c) perturb and
## prove it moves again then re-settles. The skin/shell re-emit engines (R3.1.a/b) and the mesh-baked skin-slot
## staleness (R3.1.d) are Q2/T1/Q3's job — NOT asserted zero here; those subsystems still churn at rest until those
## LATER stages ship (an honest scope note, not a gap in THIS gate).
func _gate_fs_quiesce() -> void:
	print("  --- REVISION 3 G-FS-QUIESCE (partial, Q1 driver): zero-work fixpoint at rest ---")
	_gate_fs_quiesce_driver()
	_gate_fs_quiesce_dwell()
	_gate_fs_quiesce_baker()
	print("  NOTE (G-FS-QUIESCE scope): asserts 0 delta on request()/_snap_plan rebuilds, step()'s own settle latch, the")
	print("  dwell-scan mutation counter, and the baker's SSE want-recompute counters — the Q1 driver counters this")
	print("  stage controls. The shell's OWN full re-emit engine (R3.1.a/b: skin-convergence sweeps + close-up/band")
	print("  commits forcing a full shell rebuild) and the mesh-baked skin-slot staleness (R3.1.d) are Q2/T1/Q3 — a")
	print("  live/real session still shows unrelated texture-driven shell re-emits + _shell_gen churn until those ship.")

## G-FS-QUIESCE (driver): `FacetSmoothTier.request()`/`_snap_plan` + `step()`'s own settle latch reach a zero-work
## fixpoint at a FIXED active facet (dwell deliberately kept empty here — the isolated dwell-mutation counter is
## covered by `_gate_fs_quiesce_dwell` below, so this scenario cleanly isolates the request/step counters).
func _gate_fs_quiesce_driver() -> void:
	var fid_a := _fid_of(1, 5, 12)
	var ring := FacetFarRing.new()
	ring.setup(fid_a)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	ring._active_fid = fid_a

	# Warm-up + converge (idle_on, sticky_on, mesh_inc_on all forced true via params; rim/skin-slot left off — this
	# gate is scoped to the hop-ring/request/step counters, not the S2 collar or skin parity). Drive until
	# FacetSmoothTier.step() itself reports settled (bounded — the shared global WorkerThreadPool may be contended by
	# earlier gates in this same run, so a fixed iteration count isn't reliable; a stability POLL is).
	var iters := 0
	while iters < 20000 and not ring._smooth.is_settled():
		ring._smooth_drive(true, true, false, true, false)
		iters += 1
	_ok(ring._smooth.is_settled(), "G-FS-QUIESCE warm-up (driver): the driven pipeline actually reaches settled (%d iterations) — a precondition for the rest of this gate" % iters)
	var req_warm: int = ring._smooth.request_rebuild_count()
	_ok(req_warm > 0, "G-FS-QUIESCE warm-up (driver): request()/_snap_plan actually rebuilt (%d times) while converging — non-vacuous baseline" % req_warm)

	# Settle: N more frames, nothing changes. The driver must do ZERO further request()/_snap_plan work, and
	# FacetSmoothTier.step() itself must latch settled (its own O(_sn) reap / O(res) _next_want / O(4) dirty scan skip).
	for i in range(600):
		ring._smooth_drive(true, true, false, true, false)
	var req_settled: int = ring._smooth.request_rebuild_count()
	_ok(req_settled == req_warm, "G-FS-QUIESCE: ZERO request()/_snap_plan rebuilds over 600 settled frames at a fixed active facet (%d -> %d)" % [req_warm, req_settled])
	_ok(ring._smooth.is_settled(), "G-FS-QUIESCE: FacetSmoothTier.step() itself latches _settled (its own reap/dispatch/dirty scan skips too)")

	# Perturb: a REAL facet crossing must re-trigger request() work, then re-settle.
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	ring._active_fid = fid_b
	ring._smooth_drive(true, true, false, true, false)
	var req_mid: int = ring._smooth.request_rebuild_count()
	_ok(req_mid > req_settled, "G-FS-QUIESCE perturb (driver): a facet crossing re-triggers request() work (%d -> %d) — the idle gate is not permanently stuck" % [req_settled, req_mid])
	for i in range(600):
		ring._smooth_drive(true, true, false, true, false)
	var req_final: int = ring._smooth.request_rebuild_count()
	_ok(req_final == req_mid, "G-FS-QUIESCE: re-settles to ZERO further request() work after the perturbation (%d -> %d)" % [req_mid, req_final])
	ring.free()

## G-FS-QUIESCE (dwell): `_sticky_apply_dwell`'s `_dwell_mutation_count` in isolation — a facet falling out of target
## starts its dwell timer (a mutation), holding steady mutates NO further, re-entering target cancels it (a mutation),
## and holding steady again mutates no further. Pokes `_smooth._tiles`/`_tier_of` directly (bypassing the real async
## build) so `resident_fids()` has something to iterate — deterministic, no wall-clock wait needed (the dwell TIMEOUT
## itself is exercised by the shipped REV2 gates; this one is scoped to the MUTATION COUNTER's own fixpoint).
func _gate_fs_quiesce_dwell() -> void:
	var fid := _fid_of(0, 14, 3)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	var f := FA.seam_neighbour(fid, FA.S_EAST)
	ring._smooth._tiles[int(f)] = {}
	ring._smooth._tier_of[int(f)] = FST.S3

	var before := ring._dwell_mutation_count
	var empty_target := {}   # `f` is resident but NOT in target — the fall-out scenario
	ring._sticky_apply_dwell(empty_target)
	var after_fallout := ring._dwell_mutation_count
	_ok(after_fallout > before, "G-FS-QUIESCE warm-up (dwell): a facet falling out of target starts its dwell timer (mutation counted, %d -> %d) — non-vacuous baseline" % [before, after_fallout])

	for i in range(50):
		ring._sticky_apply_dwell(empty_target)
	var after_hold := ring._dwell_mutation_count
	_ok(after_hold == after_fallout, "G-FS-QUIESCE: ZERO further dwell mutations while the SAME facet just holds (not yet elapsed, not re-entering target) over 50 calls (%d -> %d)" % [after_fallout, after_hold])

	# Perturb: the facet RE-ENTERS target (e.g. a crossing brought it back into range) — cancels the stale timer.
	var target_with_f := {int(f): FST.S3}
	ring._sticky_apply_dwell(target_with_f)
	var after_reenter := ring._dwell_mutation_count
	_ok(after_reenter > after_hold, "G-FS-QUIESCE perturb (dwell): re-entering target cancels the stale timer (mutation counted, %d -> %d)" % [after_hold, after_reenter])
	for i in range(50):
		ring._sticky_apply_dwell(target_with_f)
	var after_settle := ring._dwell_mutation_count
	_ok(after_settle == after_reenter, "G-FS-QUIESCE: re-settles to ZERO further dwell mutations once back in target over 50 calls (%d -> %d)" % [after_reenter, after_settle])
	ring.free()

## G-FS-QUIESCE (baker): `_recompute_want_sse`/`_recompute_band_want_sse`'s NEW axis+cam_dist hold gate (mirrors the
## angular `_recompute_want`'s hold at facet_tex_baker.gd:835 — the SSE path had NO hold at all). Held at an
## unchanged (axis, cam_dist): zero further recomputes; perturbed past half a facet's width: re-triggers, then
## re-settles. Calls the baker methods directly (no FP_SKIN_SSE/FP_FACET_TEX_CLOSEUP/FP_BAND_BLOCK_MAP wiring needed
## — `setup()` initializes `_k`/`_base_all`/`_centre_pack` unconditionally).
func _gate_fs_quiesce_baker() -> void:
	var fid := FA.spawn_facet()
	var axis := _centre_dir(fid)
	var axis_arr := [axis.x, axis.y, axis.z]
	var cam_dist := FA.R_BLOCKS + 3000.0
	var facet_ang := (PI * 0.5) / float(FA.K)
	var half_width := FA.R_BLOCKS * facet_ang * 0.5

	# --- close-up SSE want (_recompute_want_sse) ---
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker._recompute_want_sse(axis_arr, cam_dist, true)   # first call — always real work (empty _cu_want, no hold possible)
	var cu_before := baker.recompute_want_count()
	_ok(cu_before > 0, "G-FS-QUIESCE warm-up (baker close-up): _recompute_want_sse did real work on the first call — non-vacuous baseline (%d)" % cu_before)
	for i in range(50):
		baker._recompute_want_sse(axis_arr, cam_dist, true)   # IDENTICAL axis/cam_dist every call — held throughout
	var cu_after := baker.recompute_want_count()
	_ok(cu_after == cu_before, "G-FS-QUIESCE: ZERO further _recompute_want_sse work over 50 calls with an unchanged axis/cam_dist (%d -> %d)" % [cu_before, cu_after])
	baker._recompute_want_sse(axis_arr, cam_dist - half_width - 1.0, true)   # perturb: cam_dist moves past half a facet width
	var cu_mid := baker.recompute_want_count()
	_ok(cu_mid > cu_after, "G-FS-QUIESCE perturb (baker close-up): a cam_dist move past half a facet width re-triggers _recompute_want_sse (%d -> %d)" % [cu_after, cu_mid])
	for i in range(50):
		baker._recompute_want_sse(axis_arr, cam_dist - half_width - 1.0, true)
	var cu_final := baker.recompute_want_count()
	_ok(cu_final == cu_mid, "G-FS-QUIESCE: re-settles to ZERO further _recompute_want_sse work after the perturbation (%d -> %d)" % [cu_mid, cu_final])

	# --- band SSE want (_recompute_band_want_sse) — the SAME hold gate, briefer check. Uses a CLOSE cam_dist (well
	# inside CLOSEUP_NEAR/BAND_PROMOTE_DIST) so the fixture facet is actually a non-empty band candidate — otherwise
	# `_bm_want` stays permanently empty and the `not _bm_want.is_empty()` hold-gate guard would never engage
	# (a real trap this test hit during development: cam_dist=3000 is well past the band's much shorter promote
	# range, unlike the close-up test above whose CLOSEUP_FAR=4000 threshold DOES reach that far).
	var band_cam_dist := FA.R_BLOCKS + 500.0
	var baker2 := FacetTexBaker.new()
	baker2.setup(fid)
	baker2._recompute_band_want_sse(fid, axis_arr, band_cam_dist, true)
	var bm_before := baker2.recompute_band_want_count()
	_ok(bm_before > 0, "G-FS-QUIESCE warm-up (baker band): _recompute_band_want_sse did real work on the first call — non-vacuous baseline (%d)" % bm_before)
	for i in range(50):
		baker2._recompute_band_want_sse(fid, axis_arr, band_cam_dist, true)
	var bm_after := baker2.recompute_band_want_count()
	_ok(bm_after == bm_before, "G-FS-QUIESCE: ZERO further _recompute_band_want_sse work over 50 calls with an unchanged axis/cam_dist (%d -> %d)" % [bm_before, bm_after])
	baker2._recompute_band_want_sse(fid, axis_arr, band_cam_dist - half_width - 1.0, true)
	var bm_mid := baker2.recompute_band_want_count()
	_ok(bm_mid > bm_after, "G-FS-QUIESCE perturb (baker band): a cam_dist move past half a facet width re-triggers _recompute_band_want_sse (%d -> %d)" % [bm_after, bm_mid])

## G-FS-NOHOLE (partial — the T2 commit-generation handshake). Directly pokes the snap-gen bookkeeping (the same
## "poke a flag-gated internal directly" pattern used throughout this file) to reproduce the EXACT race R3.2.b
## describes: a facet is marked leaving, then a STALE build — one whose `visible_fids()` snapshot was taken BEFORE
## the mark — commits (every commit bumps `_shell_gen`, but this one's `_last_committed_snap_gen` stays behind the
## mark since its OWN snapshot predates it). Asserts the facet stays resident (no premature evict / hole) until a
## build whose snapshot POSTDATES the mark actually commits. FALSIFY: the identical script with `snap_gen_on` forced
## false (the shipped `_shell_gen`-at-mark law) DOES evict on the stale commit — proving the race is real and this
## gate has teeth, not merely a restatement of the fix.
func _gate_fs_nohole() -> void:
	print("  --- REVISION 3 G-FS-NOHOLE (partial, T2): a STALE in-flight commit must NOT prematurely evict a leaving facet ---")
	var fid := _fid_of(2, 11, 4)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	var f := FA.seam_neighbour(fid, FA.S_EAST)
	ring._smooth._tiles[int(f)] = {}
	ring._smooth._tier_of[int(f)] = FST.S3   # poke `f` smooth-resident directly — _mesh_inc_gate only reads resident_fids()/tier_of()
	var empty_assign := {}   # `f` is NOT in the driver's current want — the leaving scenario

	# --- (A) the FIX: snap_gen_on forced true ---
	ring._snap_gen = 5
	ring._last_committed_snap_gen = 5
	var out1 := ring._mesh_inc_gate(empty_assign, true)   # marks leaving: mark = _snap_gen + 1 = 6
	_ok(out1.has(int(f)), "G-FS-NOHOLE: the facet is held resident the instant it's marked leaving (make-before-break, unchanged from REV2)")
	_ok(int(ring._smooth_leaving[int(f)]) == 6, "G-FS-NOHOLE: marked with mark = _snap_gen+1 = 6 — the earliest snapshot generation that CAN include the re-inclusion")

	# A STALE build commits: dispatched BEFORE the mark (its own frozen snapshot used gen 5), only NOW finishes and
	# commits — every commit bumps _shell_gen (the OLD law's only signal), but _last_committed_snap_gen stays at 5
	# (its snapshot never advanced) since this build's OWN gen was 5, not >= the mark.
	ring._shell_gen += 1
	var out2 := ring._mesh_inc_gate(empty_assign, true)
	_ok(out2.has(int(f)), "G-FS-NOHOLE: a STALE commit (_shell_gen advanced, but _last_committed_snap_gen(5) < mark(6)) does NOT evict — no premature hole")

	# A genuinely POST-mark build now dispatches (bumps _snap_gen to the mark value) and commits.
	ring._snap_gen = 6
	ring._last_committed_snap_gen = 6
	var out3 := ring._mesh_inc_gate(empty_assign, true)
	_ok(not out3.has(int(f)), "G-FS-NOHOLE: once a build whose snapshot POSTDATES the mark actually commits (_last_committed_snap_gen(6) >= mark(6)), the facet is finally safe to drop")

	# --- (B) FALSIFY: the identical script with snap_gen_on forced FALSE (the shipped _shell_gen-at-mark law) ---
	ring._smooth_leaving.clear()
	ring._shell_gen = 5
	var out1b := ring._mesh_inc_gate(empty_assign, false)   # marked at _shell_gen = 5 (the OLD law)
	_ok(out1b.has(int(f)), "G-FS-NOHOLE-FALSIFY setup: the facet is held resident the instant it's marked (same make-before-break)")
	ring._shell_gen += 1   # the SAME stale commit as (A) above
	var out2b := ring._mesh_inc_gate(empty_assign, false)
	_ok(not out2b.has(int(f)), "G-FS-NOHOLE-FALSIFY: WITHOUT the fix (snap_gen_on off), the exact SAME stale commit DOES evict the facet prematurely — proving the race is real and this gate has teeth")
	ring.free()

# =====================================================================================================================
# REVISION 3 STAGE 2 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 3" R3.4 T1, FP_SMOOTH_TXN) — the
# tier-mesh COMMIT transaction. G-FS-NOHOLE strengthened (below) proves the ATOMIC swap at the committed-MESH level
# (not merely `_tiles`/`is_resident`, which already flipped atomically pre-T1 and was never the bug); G-FS-TXN-THREAD
# proves the heavy per-element concatenation actually left MAIN. Both drive `FacetSmoothTier` directly (the same
# "poke a flag-gated internal / call the function with the flag forced" pattern this whole file uses), since
# `FP_SMOOTH_TXN`'s dispatch/residency DECISION (FP_SMOOTH_MESH_INC, REV2 R-B — whether a tier-change swap holds the
# OLD tile resident instead of evicting it up front) is a separate, already-shipped/gated concern; T1's own scope is
# strictly the tier-mesh APPLY half once both old+new tiers are ALREADY dirtied by the same commit event — so the
# churn script below reproduces exactly that moment directly (`_simulate_tier_commit`, mirroring step()'s own
# reap-commit bookkeeping) rather than re-deriving it through the MESH_INC-gated dispatch path.
# =====================================================================================================================

## Directly reproduce step()'s own reap-commit bookkeeping (facet_smooth_tier.gd ~:655-669) for a fid that is ALREADY
## resident at a DIFFERENT tier — i.e. exactly the state right after a real worker tile finishes for a tier-change:
## the OLD tier's tile is dropped (`_evict`, which dirties+bumps the OLD tier) and the NEW tile lands (dirtying+
## bumping the NEW tier) in the SAME call — reproducing "a commit that moves a facet between tiers dirties BOTH tier
## meshes" (R3.2.a) without needing FP_SMOOTH_MESH_INC's dispatch decision (a separate, already-shipped concern).
func _simulate_tier_commit(ft: FacetSmoothTier, fid: int, new_tier: int, tile: Dictionary) -> void:
	if ft._tiles.has(fid):
		if int(ft._tier_of[fid]) != new_tier:
			ft._evict(fid)
		else:
			ft._bytes -= FST.tile_bytes(ft._tiles[fid])
			ft._tiles.erase(fid)
	var tb := FST.tile_bytes(tile)
	ft._tiles[fid] = tile
	ft._tier_of[fid] = new_tier
	ft._bytes += tb
	ft._dirty_tier[new_tier] = true
	ft._tier_change_seq[new_tier] = int(ft._tier_change_seq[new_tier]) + 1
	ft._changed = true

## Drive `FacetSmoothTier.step()` (`idle_on` forced false — Q1 is orthogonal to T1) until residency stops growing —
## the T1-scoped equivalent of `_p1_converge`, operating on a bare instance rather than a full `FacetFarRing`. The
## `OS.delay_msec` between polls gives the background WorkerThreadPool task REAL wall-clock time to finish (mirrors
## `_gate_fs_churn`'s note above: a tight zero-delay poll loop over a nearly-free `step()` call can spin thousands of
## times before the OS ever schedules the worker thread at all).
func _converge_ft(ft: FacetSmoothTier, txn_on: bool, max_iters := 2000) -> int:
	var iters := 0
	var stable := 0
	var last := -1
	while iters < max_iters and stable < 30:
		OS.delay_msec(2)
		ft.step(false, txn_on)
		iters += 1
		var n := ft.resident_count()
		if n == last:
			stable += 1
		else:
			stable = 0
			last = n
	return iters

## G-FS-NOHOLE (strengthened, T1): drive a churn script with BOTH a promote and a demote landing in ONE commit event
## (fid_a S4->S5, fid_b S5->S4 — a compound swap across the SAME two tiers, so the failure mode below hits both
## classes at once) plus an in-place REFRESH (fid_c, same tier), then assert on EVERY subsequent `step()` call that
## every resident fid is baked into EXACTLY ONE tier's CURRENTLY COMMITTED mesh (`committed_fids_snapshot()`):
## found==0 is a HOLE (drawn nowhere — mid-swap, see-through to the backstop); found>=2 is a Z-FIGHT (two different-
## pitch tier surfaces drawn for the same facet at once). found==1 at the facet's PREVIOUS (not-yet-updated) tier is
## explicitly NOT a violation — LAW T mandates the OLD surface keeps drawing until the NEW one commits, which is
## exactly what a legitimate in-flight transaction looks like.
func _run_nohole_churn(txn_on: bool) -> Dictionary:
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var fid_a := _fid_of(4, 6, 9)
	var fid_b := _fid_of(4, 6, 10)
	var fid_c := _fid_of(4, 6, 11)

	# Initial population: fid_a@S4, fid_b@S5, fid_c@S3 — converge FULLY first, so the churn below tests a real
	# TRANSITION (an already-committed facet moving/refreshing), never the (legitimate) initial-ramp gap before a
	# facet's first-ever commit.
	ft.request({fid_a: FST.S4, fid_b: FST.S5, fid_c: FST.S3})
	_converge_ft(ft, txn_on)
	var warm_ok := ft.is_resident(fid_a) and ft.is_resident(fid_b) and ft.is_resident(fid_c)
	var warm_committed := ft.committed_fids_snapshot()
	for fid in [fid_a, fid_b, fid_c]:
		var found := 0
		for t in range(4):
			if (warm_committed[t] as Dictionary).has(int(fid)):
				found += 1
		if found != 1:
			warm_ok = false

	# The churn: fid_a S4->S5 (demote), fid_b S5->S4 (promote) — ONE compound commit across the SAME 2 tiers — plus
	# an in-place refresh of fid_c at its current tier (S3).
	var tile_a := FST.build_tile(fid_a, FST.cells_for_tier(FST.S5), 0.0, true, false, -1.0)
	var tile_b := FST.build_tile(fid_b, FST.cells_for_tier(FST.S4), 0.0, true, false, -1.0)
	var tile_c := FST.build_tile(fid_c, FST.cells_for_tier(FST.S3), 0.0, true, false, -1.0)
	_simulate_tier_commit(ft, fid_a, FST.S5, tile_a)
	_simulate_tier_commit(ft, fid_b, FST.S4, tile_b)
	_simulate_tier_commit(ft, fid_c, FST.S3, tile_c)   # same-tier "refresh"

	var hole := false
	var zfight := false
	var steps := 0
	for i in range(400):
		OS.delay_msec(2)   # real wall-clock time for the WorkerThreadPool concat task(s) to actually run — see _converge_ft
		ft.step(false, txn_on)
		steps += 1
		var snap := ft.committed_fids_snapshot()
		for fid in [fid_a, fid_b, fid_c]:
			if not ft.is_resident(fid):
				continue
			var found := 0
			for t in range(4):
				if (snap[t] as Dictionary).has(int(fid)):
					found += 1
			if found == 0:
				hole = true
			elif found > 1:
				zfight = true
		if hole or zfight:
			break

	parent.free()
	return {"warm_ok": warm_ok, "hole": hole, "zfight": zfight, "steps": steps}

func _gate_fs_nohole_txn() -> void:
	print("  --- REVISION 3 G-FS-NOHOLE (strengthened, T1): tier-mesh commits are ATOMIC at the COMMITTED-MESH level — no hole, no z-fight ---")

	# --- (A) WITH the fix: FP_SMOOTH_TXN forced on ---
	var on := _run_nohole_churn(true)
	_ok(bool(on["warm_ok"]), "G-FS-NOHOLE (T1) warm-up: initial population converges to exactly-one-committed-tier coverage for every facet (non-vacuous baseline)")
	_ok(int(on["steps"]) > 0, "G-FS-NOHOLE (T1): drove %d churn steps (compound promote+demote+refresh)" % int(on["steps"]))
	_ok(not bool(on["hole"]), "G-FS-NOHOLE (T1): FP_SMOOTH_TXN on — NEVER a step where a resident facet is baked into ZERO committed tier meshes (no hole)")
	_ok(not bool(on["zfight"]), "G-FS-NOHOLE (T1): FP_SMOOTH_TXN on — NEVER a step where a resident facet is baked into TWO committed tier meshes at once (no z-fight)")

	# --- (B) FALSIFY: the IDENTICAL churn script with FP_SMOOTH_TXN forced OFF (the shipped ≤1-tier/frame path) ---
	var off := _run_nohole_churn(false)
	_ok(bool(off["warm_ok"]), "G-FS-NOHOLE-FALSIFY (T1) warm-up: initial population converges the same way with the flag off (non-vacuous baseline)")
	_ok(bool(off["hole"]) or bool(off["zfight"]), "G-FS-NOHOLE-FALSIFY (T1): WITHOUT the fix (txn_on false), the IDENTICAL compound promote+demote churn DOES produce a hole and/or a z-fight — the shipped ≤1-tier/frame commit loop has exactly the R3.2.a window this gate is built to catch")

## G-FS-TXN-THREAD (T1): the heavy per-element tier-mesh concatenation (`_rebuild_tier_mesh`'s O(tier resident count)
## append loop, ~:707-708 pre-T1) must run on the WORKER, not MAIN, once FP_SMOOTH_TXN is on. Drives a real multi-tier
## build burst (3 facets across 3 different tiers, converged from empty) and checks the two telemetry counters
## directly. FALSIFY: the identical script with the flag off DOES run the main-thread concat path.
func _gate_fs_txn_thread() -> void:
	print("  --- REVISION 3 G-FS-TXN-THREAD (T1): the heavy tier-mesh concat runs on the WORKER, never MAIN ---")
	var parent := Node3D.new()
	var fid_a := _fid_of(5, 3, 3)
	var fid_b := _fid_of(5, 3, 4)
	var fid_c := _fid_of(5, 3, 5)

	# --- (A) WITH T1: FP_SMOOTH_TXN forced on ---
	var ft_on := FST.new()
	ft_on.setup_instance(parent, null)
	ft_on.request({fid_a: FST.S4, fid_b: FST.S5, fid_c: FST.S3})
	_converge_ft(ft_on, true)
	_ok(ft_on.resident_count() == 3, "G-FS-TXN-THREAD warm-up: the driven 3-facet/3-tier burst actually converged (non-vacuous, %d resident)" % ft_on.resident_count())
	_ok(ft_on.worker_concat_count() > 0, "G-FS-TXN-THREAD: with FP_SMOOTH_TXN on, the off-thread `_concat_tier_worker` ran (%d times)" % ft_on.worker_concat_count())
	_ok(ft_on.main_concat_count() == 0, "G-FS-TXN-THREAD: with FP_SMOOTH_TXN on, the main-thread `_rebuild_tier_mesh` NEVER ran (0 calls) — the O(res) per-element append loop stayed off MAIN")

	# --- (B) FALSIFY: the IDENTICAL script with FP_SMOOTH_TXN forced OFF (the shipped main-thread path) ---
	var ft_off := FST.new()
	ft_off.setup_instance(parent, null)
	ft_off.request({fid_a: FST.S4, fid_b: FST.S5, fid_c: FST.S3})
	_converge_ft(ft_off, false)
	_ok(ft_off.resident_count() == 3, "G-FS-TXN-THREAD-FALSIFY warm-up: the SAME 3-facet/3-tier burst converges with the flag off (non-vacuous, %d resident)" % ft_off.resident_count())
	_ok(ft_off.main_concat_count() > 0, "G-FS-TXN-THREAD-FALSIFY: WITHOUT the fix (txn_on false), the IDENTICAL driven scenario runs the main-thread concat %d times — proving the counter has teeth, not a vacuous 0-vs-0" % ft_off.main_concat_count())
	_ok(ft_off.worker_concat_count() == 0, "G-FS-TXN-THREAD-FALSIFY: WITHOUT the fix, the off-thread concat path never ran (0 calls)")
	parent.free()
