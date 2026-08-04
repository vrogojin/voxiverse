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
const FSK := preload("res://src/world/facet_skin_tier.gd")   # REVISION 6 (G-CSB-EQ): _build_cpp_gen for the native bake

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
	# Stage 1 scope: Q1 (idle driver) + T2 (snapshot-gen handshake). Stage 2 scope: T1 (off-thread, atomic tier-mesh
	# commits). Stage 3 scope: Q2 (slot indirection — kills the shell's re-emit-on-slot-change engine AND the
	# mesh-baked smooth-tile staleness). Stage 4 scope (this stage, the LAST one): T3 (neighbour-aware weld refresh).
	_ok(not CubeSphere.FP_SMOOTH_IDLE, "G-R3-OFF: FP_SMOOTH_IDLE defaults false (byte-off)")
	_ok(not CubeSphere.FP_SHELL_SNAP_GEN, "G-R3-OFF: FP_SHELL_SNAP_GEN defaults false (byte-off)")
	_ok(not CubeSphere.FP_SMOOTH_TXN, "G-R3-OFF: FP_SMOOTH_TXN defaults false (byte-off; step() takes the shipped ≤1-tier/frame main-thread path)")
	_ok(not CubeSphere.FP_SLOT_INDIRECT, "G-R3-OFF: FP_SLOT_INDIRECT defaults false (byte-off; UV2.y still carries the shipped _slot_of bake)")
	_ok(not CubeSphere.FP_SMOOTH_WELD_REFRESH, "G-R3-OFF: FP_SMOOTH_WELD_REFRESH defaults false (byte-off; _weld_refresh_neighbours is never called)")
	_gate_fs_quiesce()
	_gate_fs_nohole()
	_gate_fs_nohole_txn()
	_gate_fs_txn_thread()
	_gate_slot_indirect_shader()
	# fid_a=(4,7,8) picked by direct measurement (not fid_int) — a facet whose S3/S5 boundary-vs-chord gap at the
	# EAST edge is large (real mountainous relief, ~12.5 blocks measured), so the WITHOUT-fix crack assertion
	# (> the 4-block skirt) is robust rather than terrain-location-luck; fid_int's own gap there was only ~1 block.
	_gate_fs_weld_neighbour(_fid_of(4, 7, 8), FA.S_EAST)
	_gate_fs_quiesce_weld_refresh()
	_gate_fs_nohole_weld_refresh()

	# --- REVISION 4 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 4 — live triage: white far (Q2 shader
	# parse-kill), no rest fixpoint, night lighting"). Stage A: Q2' vertex-stage slot resolve (fixes the shader PARSE
	# ERROR the old fragment splice caused) + rounded decode. Stage B: FP_RING_QUIESCE (the shell's own emit/count
	# fixpoint at rest). Stage C (night-lighting residual) is NOT in scope here — conditional on a live re-check.
	_ok(not CubeSphere.FP_RING_QUIESCE, "G-R4-OFF: FP_RING_QUIESCE defaults false (byte-off; _noblack_guarantee/the two counters keep the shipped un-excluded checks)")
	_gate_vary_stage()
	_gate_slot_decode()
	_gate_quiesce_ring()

	# --- REVISION 5 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 5 — rest quiescence COMPLETION: the
	# residual re-emit train + the perpetual bake worker"). Stage C (ship first): FP_FINE_BAKE_SURFACE_PAUSE — pause
	# the whole-planet fine-tier dispatch on-surface. Stage A: FP_ENV_DEMAND_DISC — bound the floored env-convergence
	# set. Stage B: FP_WARM_EMIT_SPLIT — decouple env-warm from mesh re-emit (+ the cache-race hygiene fix). Stage D
	# (FP_RIM_CHEAP, §7.1) — the S2 collar warmup fix: RIM_FINE_MULT + RIM_ENV_RESID compensation, crescent-only
	# rebake, and warmup dispatch pacing.
	_ok(not CubeSphere.FP_FINE_BAKE_SURFACE_PAUSE, "G-R5-OFF: FP_FINE_BAKE_SURFACE_PAUSE defaults false (byte-off; the fine-tier dispatch loop is unconditional)")
	_ok(not CubeSphere.FP_ENV_DEMAND_DISC, "G-R5-OFF: FP_ENV_DEMAND_DISC defaults false (byte-off; the two counters + worker 'have' test keep the shipped un-bounded env demand)")
	_ok(not CubeSphere.FP_WARM_EMIT_SPLIT, "G-R5-OFF: FP_WARM_EMIT_SPLIT defaults false (byte-off; _surface_converge_emit always dispatches a real _begin_rebuild for every env-upgrade cycle)")
	_ok(not CubeSphere.FP_RIM_CHEAP, "G-R5-OFF: FP_RIM_CHEAP defaults false (byte-off; build_tile_rim/_rim_assign take the shipped full-rebuild/unpaced path)")
	_gate_tex_surf_pause()
	_gate_quiesce_surf()
	_gate_rim_mult()
	_gate_rim_crescent(fid_int)
	_gate_rim_pace()

	# --- REVISION 5 extension (warmup pacing for the S3/S4/S5 LADDER — Stage D/FP_RIM_CHEAP only paced the S2
	# collar; the bigger flood is the ladder's own cold-engage hop-ring target, up to 289 facets in one call) ---
	_ok(not CubeSphere.FP_SMOOTH_GROW_PACE, "G-R5-OFF: FP_SMOOTH_GROW_PACE defaults false (byte-off; the sticky_on branch hands the FULL hop-ring target to request() in one call)")
	_gate_grow_pace()

	# --- REVISION 6 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 6 — C++ smooth-tile-height bake") ---
	# FP_CPP_SMOOTH_BAKE: the smooth-tile per-node dir/g/biome/temp/relief/pos + boundary normals come from the
	# native VoxelGeneratorCosmos.bake_smooth_tile() instead of the GDScript FarDensity.node_at → profile_at_dir
	# convoy. build_tile/_rim read the baked arrays VERBATIM, so field-for-field bit-equality of the native bake
	# vs node_at ⇒ an IDENTICAL mesh by construction. (Needs the built module; skips with a clear FAIL if absent.)
	_ok(not CubeSphere.FP_CPP_SMOOTH_BAKE, "G-R6-OFF: FP_CPP_SMOOTH_BAKE defaults false (byte-off; build_tile/_rim take the GDScript node_at path, `gen` ignored)")
	_gate_cpp_smooth_bake(fid)          # interior facet — every tier of the ladder
	_gate_cpp_smooth_bake(fid_edge)     # a cross-face-boundary facet — native path exercised at a cube seam
	_gate_cpp_smooth_bake_weld(fid_edge, FA.S_WEST)   # law-2 survival: shared cross-face edge, native both sides

	# --- REVISION 7-VISUAL (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 7-VISUAL") ---
	# FP_RIM_NEAR_WELD: the S2 collar's visible annulus welds to the near block-top instead of the mis-scaled
	# env−sink that exposed an 8–20-block wall at the near cut-edge (the user's #1 immersion complaint).
	_ok(not CubeSphere.FP_RIM_NEAR_WELD, "G-RNW-OFF: FP_RIM_NEAR_WELD defaults false (byte-off; build_tile_rim takes the shipped env−sink law — the other G-RIM-* gates exercise it)")
	_gate_rim_near_weld(fid_int)

	# DEFECT 2 (FP_SMOOTH_HORIZON_COVER, §R7.3): extend the S5 reach so flat skin doesn't show inside the surface horizon.
	_ok(not CubeSphere.FP_SMOOTH_HORIZON_COVER, "G-SMOOTH-HORIZON-OFF: FP_SMOOTH_HORIZON_COVER defaults false (byte-off; smooth_s5_max()/hop() return the shipped 200/10)")
	_gate_smooth_horizon()

	# FP_SMOOTH_SNAP_SELFHEAL (#28): the sunk-facet disconnect fix — a stale-plan commit must re-queue a refresh.
	_ok(not CubeSphere.FP_SMOOTH_SNAP_SELFHEAL, "G-FS-SELFHEAL-OFF: FP_SMOOTH_SNAP_SELFHEAL defaults false (byte-off; step()'s commit self-check never runs)")
	_gate_snap_selfheal()

	# --- REVISION 7 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 7") ---
	# FP_SMOOTH_SLOT_MESH: kills the O(N²) whole-tier re-pack/re-upload commit hitch — per-tier fixed-capacity
	# slotted ArrayMesh + `RenderingServer.mesh_surface_update_vertex_region`/`_attribute_region` GPU region writes
	# instead of a from-scratch `add_surface_from_arrays` on every single tile commit. NOTE: the headless
	# RenderingServer is a DUMMY (no real GPU) — `mesh_surface_update_vertex_region`/`_attribute_region` are literal
	# no-ops there (`servers/rendering/dummy/storage/mesh_storage.h`), so these gates validate the PACKING/OFFSET
	# MATH, the refusal latch, and the commit-event SCHEDULING (all headless-checkable), but CANNOT confirm the
	# actual glBufferSubData upload lands/renders correctly on a real GPU — that is a live-only check.
	_ok(not CubeSphere.FP_SMOOTH_SLOT_MESH, "G-SLOT-OFF: FP_SMOOTH_SLOT_MESH defaults false (byte-off; step()/request()/_evict() all default their new slot_on param to this const)")
	_gate_slot_eq()
	_gate_slot_nohole()
	_gate_slot_budget()

	# --- FP_SMOOTH_TILE_SURF (SAFE replacement for FP_SMOOTH_SLOT_MESH — that path's RenderingServer region-write
	# calls hard-crashed the live web tab; per-tile MeshInstance3D/ArrayMesh nodes + consolidate-at-settle instead) ---
	_ok(not CubeSphere.FP_SMOOTH_TILE_SURF, "G-TILESURF-OFF: FP_SMOOTH_TILE_SURF defaults false (byte-off; step()/request()/_evict()/force_rebake() all default their new tile_surf_on param to this const)")
	_gate_tilesurf_cover()
	_gate_tilesurf_xor()
	_gate_tilesurf_consolidate()
	_gate_tilesurf_off()

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

## G-FS-QUIESCE (COMPLETE as of Q2 — the Q1 driver's own fixpoint counters PLUS the shell's slot-triggered re-emit
## engine, R3.1.b, AND the mesh-baked skin-slot staleness, R3.1.d). Four independent, non-vacuous sub-checks, each:
## (a) prove the counter/behaviour actually does real work during warm-up/perturbation (not a vacuous always-0
## counter or an always-true assertion), (b) prove it goes FLAT (zero further mutation, or zero re-emit) once
## nothing changes, (c) perturb and prove it moves again then re-settles (or, for the slot sub-gate, falsify with
## the flag off to prove the harness has teeth). REMAINING scope note (honest, not a gap): Q3's skin-CONTENT
## convergence bound (the whole-planet fine/band bake sweeps still repaint the visible disc for real wall-clock
## time even under Q2 — Q2 only stops that repainting from forcing MESH work) and T3's neighbour-aware weld
## refresh are LATER stages, not asserted here.
func _gate_fs_quiesce() -> void:
	print("  --- REVISION 3 G-FS-QUIESCE (complete, Q1+Q2): zero-work fixpoint at rest, slot changes never re-emit ---")
	_gate_fs_quiesce_driver()
	_gate_fs_quiesce_dwell()
	_gate_fs_quiesce_baker()
	_gate_fs_quiesce_slot()
	print("  NOTE (G-FS-QUIESCE remaining scope): Q3's skin-CONTENT convergence bound (the fine/band bake sweeps still")
	print("  repaint the visible disc for real wall-clock time — Q2 only stops that repaint from forcing MESH work) and")
	print("  T3's neighbour-aware weld refresh are LATER stages, not asserted here.")

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

## G-FS-QUIESCE (Q2, completes the gate): a close-up/band slot-map change must NOT force a front re-emit under
## FP_SLOT_INDIRECT (LAW S) — it only updates the tiny fid→slot lookup texture, never `_pending`/`_shell_gen`.
## Falsified WITHOUT the fix: the identical change DOES set `_pending` (the shipped R3.1.b re-emit engine). Also
## proves (b) the lookup texture tracks the LIVE map — never stale, even as the SAME fid's slot moves — and (c) a
## smooth tile's UV2.y payload is INVARIANT to a slot-map move once it carries the stable fid, CONTRASTED against
## the OLD frozen-slot payload, which DOES change per build call (the exact staleness class R3.1.d describes: a
## committed tile has no mechanism to pick up a new slot without an unrelated rebuild).
func _gate_fs_quiesce_slot() -> void:
	var fid := _fid_of(1, 8, 9)
	var other := FA.seam_neighbour(fid, FA.S_EAST)

	# (a) Non-vacuous baseline + falsification: WITHOUT the fix, a slot-map change DOES set `_pending`.
	var ring_off := FacetFarRing.new()
	ring_off.setup(fid)
	ring_off._pending = false
	ring_off._closeup_slots = {fid: 3}
	ring_off._on_slot_map_changed(false)
	_ok(ring_off._pending, "G-FS-QUIESCE-FALSIFY (Q2): WITHOUT the fix, a slot-map change DOES set `_pending` (forces a front re-emit) — proving the harness has teeth")
	ring_off.free()

	# (b) The fix: WITH FP_SLOT_INDIRECT forced on, the IDENTICAL slot-map change touches ONLY the lookup texture —
	# `_pending` stays false and `_shell_gen` (the commit tally) is untouched.
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._pending = false
	var gen_before: int = ring._shell_gen
	ring._closeup_slots = {fid: 3}
	ring._on_slot_map_changed(true)
	_ok(not ring._pending, "G-FS-QUIESCE (Q2): a close-up slot-map change does NOT set `_pending` under FP_SLOT_INDIRECT — no front re-emit")
	_ok(ring._shell_gen == gen_before, "G-FS-QUIESCE (Q2): `_shell_gen` is untouched by a slot-only change (never bumps for this)")

	# (c) The lookup texture reflects the LIVE map, non-vacuously (several distinct values, all read back correctly),
	# including the SAME fid's slot MOVING (the exact case that used to go stale on a committed smooth tile).
	var dims: Vector2i = ring._slot_indirect_dims()
	var w: int = dims.x
	var px1: Color = ring._slot_img.get_pixel(fid % w, int(fid / w))
	_ok(absf(px1.r - 3.0) < 1e-5, "G-FS-QUIESCE (Q2): the lookup texture holds the CURRENT slot (3) right after the push")
	ring._closeup_slots = {fid: 3, other: 9}   # a second, independent facet promoted (the close-up/band carousel moving on)
	ring._on_slot_map_changed(true)
	var px2: Color = ring._slot_img.get_pixel(other % w, int(other / w))
	_ok(absf(px2.r - 9.0) < 1e-5, "G-FS-QUIESCE (Q2): a NEW facet's slot reaches the texture on the next push (still live)")
	ring._closeup_slots = {fid: 11, other: 9}   # THIS fid's own slot moves (3 -> 11) — no rebuild anywhere, just a texture push
	ring._on_slot_map_changed(true)
	var px3: Color = ring._slot_img.get_pixel(fid % w, int(fid / w))
	_ok(absf(px3.r - 11.0) < 1e-5, "G-FS-QUIESCE (Q2): the SAME fid's slot MOVING (3 -> 11) is reflected on the next push — never stale")
	ring.free()

	# (d) The smooth-tile PAYLOAD itself: under Q2 the call site always stamps the stable fid (`FacetSmoothTier.
	# _build_worker`'s override) — INVARIANT no matter how many times the slot map moves in between. Contrast the
	# OLD frozen-slot payload (`_slot_of` baked in at build time): built once at slot=3, "rebuilt" later (a tier
	# change, a refresh — ANYTHING except the slot move itself) at slot=11 — DIFFERENT payload, but nothing in the
	# shipped driver re-triggers that rebuild purely because a slot moved, so a resident tile is stuck at whichever
	# slot happened to be live the last time it was (re)built for an unrelated reason — exactly R3.1.d.
	var cells := FST.cells_for_tier(FST.S4)
	var tile_q2_a := FST.build_tile(fid, cells, 0.0, true, false, float(fid))
	var tile_q2_b := FST.build_tile(fid, cells, 0.0, true, false, float(fid))
	var uv2_q2_a: PackedVector2Array = tile_q2_a["uv2"]
	var uv2_q2_b: PackedVector2Array = tile_q2_b["uv2"]
	_ok(uv2_q2_a[0].y == uv2_q2_b[0].y, "G-FS-QUIESCE (Q2): the smooth-tile UV2.y payload is INVARIANT (the stable fid) across any slot-map move")
	var tile_old_a := FST.build_tile(fid, cells, 0.0, true, false, 3.0)
	var tile_old_b := FST.build_tile(fid, cells, 0.0, true, false, 11.0)
	var uv2_old_a: PackedVector2Array = tile_old_a["uv2"]
	var uv2_old_b: PackedVector2Array = tile_old_b["uv2"]
	_ok(uv2_old_a[0].y != uv2_old_b[0].y, "G-FS-QUIESCE-FALSIFY (Q2): the OLD frozen-slot payload DOES differ once the slot moves — a committed tile built at the OLD value has no way to become 11 without an unrelated rebuild, proving Q2's stable-fid payload is the actual fix")

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

# =====================================================================================================================
# REVISION 3 STAGE 3 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 3" R3.4 Q2, FP_SLOT_INDIRECT) — LAW S:
# kill mesh-baked band/close-up skin slots. `_gate_fs_quiesce_slot` (folded into `_gate_fs_quiesce` above, completing
# it) proves a slot-map change never re-emits and the lookup texture never goes stale; `_gate_slot_indirect_shader`
# below is the golden-string pin on the shell/smooth shader splice. T3 (neighbour-aware weld refresh) and Q3 (skin-
# convergence bounding) are LATER stages, not gated here.
# =====================================================================================================================

## Golden shader-string pin (Q2, FP_SLOT_INDIRECT — the F7 lesson). With the flag off, `_apply_slot_indirect` is the
## identity function on EVERY assembled shell/smooth shader variant — including variants that never declare
## `v_slot`/`v_bslot` at all (the plain vertex-colour shell, the base tex shader with neither close-up nor band on):
## byte-identical to the committed Stage-2 string, PROVING the splice is inert off even when forced (String.replace
## of an absent anchor is a no-op). With it forced on, variants that DO declare `v_slot` and/or `v_bslot` gain the
## `slot_map` uniform + the `_slot_indirect` resolve call (spliced source DIFFERS from the golden off-string) while
## still compiling to exactly ONE `shader_type` (zero new compiled programs — mirrors G-FS-LIT-ON/G-VL-SHADERTYPE);
## variants WITHOUT those varyings stay untouched even with the flag forced on (nothing for Q2 to resolve there).
## NOTE: this is a STRING-LEVEL gate (matches every other golden-pin gate in this file) — actual GLSL compilation
## needs a real GPU context and is NOT exercised headless; flagged in the stage report as the one gl_compat-risk
## item that could not be fully verified without a live browser.
func _gate_slot_indirect_shader() -> void:
	print("  --- REVISION 3 Q2 golden shader-string pin (FP_SLOT_INDIRECT) ---")
	var no_slot_srcs := [
		["_SHELL_ABS_SHADER (no UV2 at all)", FacetFarRing._SHELL_ABS_SHADER],
		["base tex, no CU/no band", FacetFarRing.gate_tex_shader_raw(false)],
	]
	for pair in no_slot_srcs:
		var name: String = pair[0]
		var src: String = pair[1]
		var off: String = FacetFarRing._apply_slot_indirect(src, false)
		var on: String = FacetFarRing._apply_slot_indirect(src, true)
		_ok(off == src, "G-SLOT-OFF: %s is byte-identical off (golden pin)" % name)
		_ok(on == src, "G-SLOT-ON: %s has no v_slot/v_bslot — untouched even with the flag forced on (nothing to resolve, still a no-op splice)" % name)

	# NOTE: `gate_band_shader`'s band injection is itself gated behind the COMPILE-TIME-ONLY `FP_BLOCK_DETAIL` const
	# inside `_apply_block_detail` (no override param exists for it, unlike `band`/`shot`) — under this file's default
	# consts it is a no-op regardless of `band`, so it cannot supply a genuine v_bslot fixture here. `_apply_flatcolor`
	# has no such outer gate (the caller in `_make_material` decides whether to invoke it; the function itself always
	# does the splice when called) — applying it to BOTH the base and CU tex variants gives genuine v_bslot-only and
	# v_slot+v_bslot fixtures without needing to flip any compile-time const.
	var slot_srcs := [
		["CU tex (v_slot only)", FacetFarRing.gate_tex_shader_raw(true)],
		["flatcolor on base tex (v_bslot only)", FacetFarRing._apply_flatcolor(FacetFarRing._SHELL_ABS_TEX_SHADER)],
		["flatcolor on CU tex (v_slot + v_bslot)", FacetFarRing._apply_flatcolor(FacetFarRing._SHELL_ABS_TEX_CU_SHADER)],
	]
	for pair in slot_srcs:
		var name: String = pair[0]
		var off_code: String = pair[1]
		var off_result: String = FacetFarRing._apply_slot_indirect(off_code, false)
		_ok(off_result == off_code, "G-SLOT-OFF: %s is byte-identical off (golden pin)" % name)
		var on_code: String = FacetFarRing._apply_slot_indirect(off_code, true)
		_ok(on_code != off_code, "G-SLOT-ON: %s spliced source DIFFERS from the golden off-string (the branch actually fires)" % name)
		_ok(on_code.contains("uniform sampler2D slot_map") and on_code.contains("_slot_indirect("),
			"G-SLOT-ON: %s spliced source declares the lookup sampler + the resolve function/call" % name)
		_ok(on_code.count("shader_type") == off_code.count("shader_type"),
			"G-SLOT-ON: %s spliced source has the SAME shader_type count as off (zero new compiled programs)" % name)
	_ok(not CubeSphere.FP_SLOT_INDIRECT, "G-SLOT-OFF: FP_SLOT_INDIRECT defaults false (byte-off)")

# =====================================================================================================================
# REVISION 3 STAGE 4 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 3" R3.4 T3, FP_SMOOTH_WELD_REFRESH) — THE
# LAST STAGE. Neighbour-aware weld refresh closes R3.2.c: a tile's 4-edge boundary snap is FROZEN at request()/build
# time (`_snap_plan` at request(), applied once in `_build_worker`). `request()` keeps `_snap_plan`'s VALUE
# forward-fresh on every call (recomputed for everyone in `_want`), but nothing ever revisits an ALREADY-BUILT
# neighbour's geometry when that value changes — its edge stays snapped to whatever pitch was current when IT was
# last built, opening a T-junction crack the 4-block skirt can't always cover. G-FS-WELD-NEIGHBOUR drives TWO bare
# `FacetSmoothTier` instances directly (mirrors T1's "poke internals / force flags via function params" gates): two
# adjacent facets commit at the SAME pitch (S3, welded — G-FS-WELD-EDGE style), then ONE promotes to S5 (a real tier
# CHANGE, the biggest jump the ladder has besides S2, cstride=4 — a wide sampling gap so the crack is unmistakable).
# WITHOUT the fix the neighbour's tile is provably NEVER rebuilt and the post-promote boundary gap is shown to
# exceed the skirt (non-vacuous — the crack is demonstrated, not asserted by fiat); WITH the fix the neighbour gets
# a staggered, build-then-swap `request_refresh` (via the T1 atomic path when `FP_SMOOTH_TXN` is also on) and the
# boundary re-coincides on the NEW (S5) chord. G-FS-QUIESCE/G-FS-NOHOLE are re-run (forcing weld_refresh_on too) to
# prove T3 composes with the Q1 idle latch (zero refreshes at rest) and doesn't reopen the T1 no-hole proof.
# =====================================================================================================================

## Reverse-edge lookup: which of `nb`'s 4 tile-local edges (FacetSmoothTier.EDGE_WEST..NORTH convention) borders
## `fid`? Independently reimplemented here (not calling `FacetSmoothTier`'s own private helper) so the gate doesn't
## just retest the same code path it's trying to falsify.
func _tile_edge_facing(nb: int, fid: int) -> int:
	for e2 in range(4):
		if FA.seam_neighbour(nb, FST._EDGE_SEAM_SLOT[e2]) == fid:
			return e2
	return -1

func _opposite_fa_slot(slot: int) -> int:
	match slot:
		FA.S_EAST: return FA.S_WEST
		FA.S_WEST: return FA.S_EAST
		FA.S_NORTH: return FA.S_SOUTH
		_: return FA.S_NORTH

## Run the WITHOUT/WITH T3 scenario on a bare `FacetSmoothTier`. `weld_on` forces `FP_SMOOTH_WELD_REFRESH` via the
## function params (never the compile-time const, matching every other force-tested flag in this file). Both
## fixtures converge fully at S3/S3 first (a real TRANSITION is tested below, never the legitimate initial-ramp
## gap), then `fid_a` promotes to S5 while `nb` stays put at S3 — exactly the R3.2.c scenario.
func _run_weld_neighbour(fid_a: int, nb: int, weld_on: bool) -> Dictionary:
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)

	ft.request({fid_a: FST.S3, nb: FST.S3}, {}, false, weld_on)
	_converge_ft(ft, false)
	var warm_ok := ft.is_resident(fid_a) and ft.is_resident(nb) \
		and int(ft.tier_of(fid_a)) == FST.S3 and int(ft.tier_of(nb)) == FST.S3
	var nb_pos_before: PackedVector3Array = (ft._tiles[nb]["pos"] as PackedVector3Array).duplicate()

	# The churn: fid_a promotes S3 -> S5 (a real tier CHANGE). nb's OWN request stays S3 — untouched except for
	# whatever T3 does to it.
	ft.request({fid_a: FST.S5, nb: FST.S3}, {}, false, weld_on)
	for i in range(500):
		OS.delay_msec(2)
		ft.step(false, false, weld_on)

	var tier_a := int(ft.tier_of(fid_a)) if ft.is_resident(fid_a) else -1
	var tier_nb := int(ft.tier_of(nb)) if ft.is_resident(nb) else -1
	var nb_pos_after: PackedVector3Array = (ft._tiles[nb]["pos"] as PackedVector3Array).duplicate() if ft.is_resident(nb) else PackedVector3Array()
	var fid_a_pos_after: PackedVector3Array = (ft._tiles[fid_a]["pos"] as PackedVector3Array).duplicate() if ft.is_resident(fid_a) else PackedVector3Array()
	var rebuilt := nb_pos_before.size() != nb_pos_after.size()
	if not rebuilt:
		for k in range(nb_pos_before.size()):
			if nb_pos_before[k].distance_to(nb_pos_after[k]) > 1.0e-9:
				rebuilt = true
				break

	parent.free()
	return {"warm_ok": warm_ok, "nb_after": nb_pos_after, "fid_a_after": fid_a_pos_after,
		"rebuilt": rebuilt, "tier_a": tier_a, "tier_nb": tier_nb}

## G-FS-WELD-NEIGHBOUR (REVISION 3 T3, FP_SMOOTH_WELD_REFRESH): see the file-header block comment above for the
## full scenario. `fid_a`/`slot` mirror `_gate_weld_mixed`'s fixture convention (`slot` = fid_a's OWN edge facing
## its neighbour; an IN-FACE pair gives direct gi/gj index correspondence, no nearest-match needed).
func _gate_fs_weld_neighbour(fid_a: int, slot: int) -> void:
	print("  --- REVISION 3 T3 (FP_SMOOTH_WELD_REFRESH): neighbour-aware weld refresh closes the stale-snap-plan crack (R3.2.c) ---")
	var nb := FA.seam_neighbour(fid_a, slot)
	_ok(_face_of(nb) == _face_of(fid_a), "G-FS-WELD-NEIGHBOUR: fixture neighbour is in-face (direct index correspondence)")

	var fine_cells := FST.cells_for_tier(FST.S3)     # nb stays S3 throughout — the FINE side once fid_a promotes
	var coarse_cells := FST.cells_for_tier(FST.S5)   # fid_a's post-promote tier — the COARSE side (coarse-owns-edge)
	var cstride := fine_cells / coarse_cells
	var fine_stride := fine_cells + 1
	var coarse_stride := coarse_cells + 1
	var opp := _opposite_fa_slot(slot)
	var nb_edge_idx := _edge_indices(opp, fine_cells, fine_stride)
	var fid_a_edge_idx := _edge_indices(slot, coarse_cells, coarse_stride)

	# --- (A) WITHOUT the fix ---
	var off := _run_weld_neighbour(fid_a, nb, false)
	_ok(bool(off["warm_ok"]), "G-FS-WELD-NEIGHBOUR warm-up (off): initial S3/S3 residency converges (non-vacuous baseline)")
	_ok(int(off["tier_a"]) == FST.S5, "G-FS-WELD-NEIGHBOUR (off): fid_a actually promoted to S5 after the churn")
	_ok(int(off["tier_nb"]) == FST.S3, "G-FS-WELD-NEIGHBOUR (off): nb stays at S3 throughout (never itself re-tiered)")
	_ok(not bool(off["rebuilt"]), "G-FS-WELD-NEIGHBOUR-FALSIFY: WITHOUT the fix, the neighbour's tile is NEVER rebuilt after fid_a's tier change (the frozen boundary geometry — R3.2.c's exact staleness)")

	var nb_pos_off: PackedVector3Array = off["nb_after"]
	var fid_a_pos_off: PackedVector3Array = off["fid_a_after"]
	var max_gap_off := 0.0
	for gj in range(1, fine_cells):
		if gj % cstride == 0:
			continue
		var j0 := gj / cstride
		var j1 := mini(j0 + 1, coarse_cells)
		var lo := float(gj - j0 * cstride) / float(cstride)
		var chord: Vector3 = fid_a_pos_off[fid_a_edge_idx[j0]].lerp(fid_a_pos_off[fid_a_edge_idx[j1]], lo)
		var d: float = nb_pos_off[nb_edge_idx[gj]].distance_to(chord)
		if d > max_gap_off:
			max_gap_off = d
	_ok(max_gap_off > float(CubeSphere.SMOOTH_SKIRT_BLOCKS),
		"G-FS-WELD-NEIGHBOUR-FALSIFY: WITHOUT the fix, the post-promote boundary gap (%.3f blocks) EXCEEDS the %d-block skirt — the crack is real, non-vacuous" % [max_gap_off, CubeSphere.SMOOTH_SKIRT_BLOCKS])

	# --- (B) WITH the fix ---
	var on := _run_weld_neighbour(fid_a, nb, true)
	_ok(bool(on["warm_ok"]), "G-FS-WELD-NEIGHBOUR warm-up (on): the SAME initial S3/S3 residency converges (non-vacuous baseline)")
	_ok(int(on["tier_a"]) == FST.S5, "G-FS-WELD-NEIGHBOUR (on): fid_a actually promoted to S5 after the churn")
	_ok(int(on["tier_nb"]) == FST.S3, "G-FS-WELD-NEIGHBOUR (on): nb is REFRESHED in place, never re-tiered/evicted (residency untouched)")
	_ok(bool(on["rebuilt"]), "G-FS-WELD-NEIGHBOUR: WITH the fix, the neighbour's tile GETS rebuilt (request_refresh dispatched, build-then-swap)")

	var nb_pos_on: PackedVector3Array = on["nb_after"]
	var fid_a_pos_on: PackedVector3Array = on["fid_a_after"]
	var on_chord := true
	var coarse_exact := true
	var eps_pos := 1.0e-9 * FA.R_BLOCKS
	for gj in range(0, fine_cells + 1):
		var j0 := gj / cstride
		var j1 := mini(j0 + 1, coarse_cells)
		var lo := float(gj - j0 * cstride) / float(cstride)
		var chord: Vector3 = fid_a_pos_on[fid_a_edge_idx[j0]].lerp(fid_a_pos_on[fid_a_edge_idx[j1]], lo)
		if nb_pos_on[nb_edge_idx[gj]].distance_to(chord) > 1.0e-6:
			on_chord = false
		if gj % cstride == 0:
			if nb_pos_on[nb_edge_idx[gj]].distance_to(fid_a_pos_on[fid_a_edge_idx[j0]]) > eps_pos:
				coarse_exact = false
	_ok(on_chord, "G-FS-WELD-NEIGHBOUR: WITH the fix, the refreshed neighbour boundary lies exactly on fid_a's NEW (S5) chord — the crack closes")
	_ok(coarse_exact, "G-FS-WELD-NEIGHBOUR: the neighbour's coarse-index vertices bit-match fid_a's actual S5 tile there (≤1e-9·R — the P0 canon weld, not just the snap lerp)")

## G-FS-QUIESCE re-run (T3): a stationary scene (no tier changes) must trigger ZERO weld refreshes even with
## FP_SMOOTH_WELD_REFRESH forced on — `_weld_refresh_neighbours` is only ever reached from a real commit/eviction,
## so simply holding a converged residency steady must never call `request_refresh` again. Perturb (a real
## promote) must cause exactly the neighbour reweld count to move, then re-settle to zero further churn.
func _gate_fs_quiesce_weld_refresh() -> void:
	print("  --- REVISION 3 T3 (FP_SMOOTH_WELD_REFRESH) composes with the Q1 idle latch — zero refreshes at rest ---")
	var fid_a := _fid_of(3, 9, 2)
	var nb := FA.seam_neighbour(fid_a, FA.S_EAST)
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)

	ft.request({fid_a: FST.S3, nb: FST.S3}, {}, false, true)
	_converge_ft(ft, false)
	_ok(ft.is_resident(fid_a) and ft.is_resident(nb), "G-FS-QUIESCE (T3) warm-up: initial S3/S3 residency converges (non-vacuous baseline)")

	# Settle: re-issue the IDENTICAL request (idle_on forced true this time) + step for many frames — nothing
	# changed, so `_weld_refresh_neighbours` must never fire (no commit/eviction event occurs at all).
	for i in range(600):
		ft.request({fid_a: FST.S3, nb: FST.S3}, {}, true, true)
		ft.step(true, false, true)
	var refresh_before_perturb := ft._refresh.size()
	_ok(refresh_before_perturb == 0, "G-FS-QUIESCE (T3): ZERO queued weld refreshes over 600 settled frames at unchanged residency (%d)" % refresh_before_perturb)

	# Perturb: a real tier change on fid_a — nb MUST get a queued refresh, then (once dispatched+committed) the
	# refresh queue drains back to empty and stays there.
	ft.request({fid_a: FST.S5, nb: FST.S3}, {}, true, true)
	var saw_refresh := ft._refresh.has(nb)
	for i in range(500):
		OS.delay_msec(2)
		ft.request({fid_a: FST.S5, nb: FST.S3}, {}, true, true)
		ft.step(true, false, true)
		if ft._refresh.has(nb):
			saw_refresh = true
	_ok(saw_refresh, "G-FS-QUIESCE perturb (T3): a real neighbour tier change DOES queue a weld refresh (not permanently stuck at zero)")
	_ok(ft._refresh.is_empty(), "G-FS-QUIESCE (T3): the refresh queue drains back to empty once the reweld actually commits")

	# Re-settle: hold the post-promote state steady — zero further refreshes.
	for i in range(300):
		ft.request({fid_a: FST.S5, nb: FST.S3}, {}, true, true)
		ft.step(true, false, true)
	_ok(ft._refresh.is_empty(), "G-FS-QUIESCE (T3): re-settles to ZERO further weld refreshes once the promote is fully absorbed")
	parent.free()

## G-FS-NOHOLE re-run (T3): the SAME strengthened churn script as `_gate_fs_nohole_txn` (`_simulate_tier_commit` —
## NOT the real `request()`/`step()` dispatch path: under the shipped `FP_SMOOTH_MESH_INC`-off "break-before-make"
## law a tier change evicts IMMEDIATELY at `request()` time, long before its replacement build lands — an existing,
## orthogonal characteristic of that path, not something T3 introduces or is responsible for fixing; the ORIGINAL
## T1 gate already tests the "both tiers dirty together" moment this way for exactly that reason), but with T3's
## own hook (`ft._weld_refresh_neighbours`) invoked exactly as `step()`'s post-commit path would, plus a THIRD
## facet (`fid_c`) adjacent to the churning pair to prove the neighbour reweld itself composes safely with T1's
## atomic transaction — never a hole/z-fight, and the reweld actually lands (content changes, no evict).
func _gate_fs_nohole_weld_refresh() -> void:
	print("  --- REVISION 3 T3 composes with T1's no-hole guarantee (FP_SMOOTH_TXN + FP_SMOOTH_WELD_REFRESH both on) ---")
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var fid_a := _fid_of(2, 8, 4)
	var fid_b := _fid_of(2, 8, 5)
	var fid_c := _fid_of(2, 8, 6)   # adjacent to fid_b — the neighbour T3 should reweld once fid_b's tier moves

	ft.request({fid_a: FST.S4, fid_b: FST.S5, fid_c: FST.S3}, {}, false, true)
	_converge_ft(ft, true)
	var warm_committed := ft.committed_fids_snapshot()
	var warm_ok := true
	for fid in [fid_a, fid_b, fid_c]:
		var found := 0
		for t in range(4):
			if (warm_committed[t] as Dictionary).has(int(fid)):
				found += 1
		if found != 1:
			warm_ok = false
	_ok(warm_ok, "G-FS-NOHOLE (T1+T3) warm-up: initial population still converges to exactly-one-committed-tier coverage per facet")
	var fid_c_pos_before: PackedVector3Array = (ft._tiles[fid_c]["pos"] as PackedVector3Array).duplicate()

	# The churn: fid_a demotes S4->S5, fid_b promotes S5->S4 (compound, same 2 tiers, simulated together exactly as
	# a real FP_SMOOTH_MESH_INC-on commit would land) — then T3's own post-commit hook, exactly as `step()` invokes it.
	ft.request({fid_a: FST.S5, fid_b: FST.S4, fid_c: FST.S3}, {}, false, true)   # refreshes _snap_plan/_want only
	var tile_a := FST.build_tile(fid_a, FST.cells_for_tier(FST.S5), 0.0, true, false, -1.0)
	var tile_b := FST.build_tile(fid_b, FST.cells_for_tier(FST.S4), 0.0, true, false, -1.0)
	_simulate_tier_commit(ft, fid_a, FST.S5, tile_a)
	ft._weld_refresh_neighbours(fid_a)
	_simulate_tier_commit(ft, fid_b, FST.S4, tile_b)
	ft._weld_refresh_neighbours(fid_b)
	var queued_refresh := ft._refresh.has(fid_c)
	_ok(queued_refresh, "G-FS-NOHOLE (T1+T3): fid_b's tier change queues a `request_refresh` on its neighbour fid_c (T3 fires)")

	var hole := false
	var zfight := false
	var steps := 0
	for i in range(600):
		OS.delay_msec(2)
		ft.step(false, true, true)
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
	_ok(steps > 0, "G-FS-NOHOLE (T1+T3): drove %d churn steps (promote+demote+neighbour reweld, weld refresh live)" % steps)
	_ok(not hole, "G-FS-NOHOLE (T1+T3): FP_SMOOTH_TXN+FP_SMOOTH_WELD_REFRESH both on — NEVER a step where a resident facet is baked into ZERO committed tier meshes")
	_ok(not zfight, "G-FS-NOHOLE (T1+T3): NEVER a step where a resident facet is baked into TWO committed tier meshes at once")
	_ok(ft.is_resident(fid_c) and int(ft.tier_of(fid_c)) == FST.S3, "G-FS-NOHOLE (T1+T3): fid_c is REFRESHED in place (still S3, never evicted/re-tiered) while its boundary rewelds")
	var fid_c_pos_after: PackedVector3Array = (ft._tiles[fid_c]["pos"] as PackedVector3Array).duplicate()
	var fid_c_rebuilt := fid_c_pos_before.size() != fid_c_pos_after.size()
	if not fid_c_rebuilt:
		for k in range(fid_c_pos_before.size()):
			if fid_c_pos_before[k].distance_to(fid_c_pos_after[k]) > 1.0e-9:
				fid_c_rebuilt = true
				break
	_ok(fid_c_rebuilt, "G-FS-NOHOLE (T1+T3): fid_c's queued reweld actually commits (its geometry changes) by the end of the churn")
	parent.free()

# =====================================================================================================================
# REVISION 4 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 4" — live triage: white far (Q2 shader parse-kill),
# no rest fixpoint, night lighting). Stage A ships Q2' (vertex-stage slot resolve, fixes the shader PARSE ERROR the
# old fragment splice caused) + the rounded decode. Stage B ships FP_RING_QUIESCE (the shell's own emit/count
# fixpoint at rest). Stage C (night-lighting residual, FP_SMOOTH_NORMAL_LIT's two-normal law) is NOT in this scope —
# conditional on a live re-check after Stage A ships, per R4.5.
# =====================================================================================================================

## The ORIGINAL (broken) Q2 fragment splice, reproduced INLINE here for G-FS-VARY-STAGE's falsification half only —
## it is NOT restored to shipped source (facet_far_ring.gd's `_apply_slot_indirect` is the FIXED Q2' vertex-stage
## splice now). Mirrors the pre-fix code exactly: injects `v_slot = _slot_indirect(v_slot);` / `v_bslot = ...` (or
## the shared-fetch form when both exist) at the TOP of `void fragment() {` — reassigning a varying `vertex()`
## already assigned, the exact pattern Godot's shader compiler rejects (R4.1).
func _broken_splice_for_gate(code: String) -> String:
	var has_slot := code.find("varying float v_slot;") >= 0
	var has_bslot := code.find("varying float v_bslot;") >= 0
	if not has_slot and not has_bslot:
		return code
	code = code.replace(
		"uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n",
		"uniform sampler2DArray base_map : source_color, filter_linear_mipmap;\n" + FacetFarRing._SLOT_INDIRECT_UNIFORMS)
	var resolve := ""
	if has_slot and has_bslot:
		resolve = "\tfloat _rs = _slot_indirect(v_slot);\n\tv_slot = _rs;\n\tv_bslot = _rs;\n"
	elif has_slot:
		resolve = "\tv_slot = _slot_indirect(v_slot);\n"
	else:
		resolve = "\tv_bslot = _slot_indirect(v_bslot);\n"
	return code.replace("void fragment() {\n", "void fragment() {\n" + resolve)

## G-FS-VARY-STAGE (Stage A, catches R4.1's whole class): assemble the far-ring shader string for every reachable
## flag-combination variant (the same base fixtures `_gate_slot_indirect_shader` uses — the only ones this harness
## can produce a genuine v_slot/v_bslot fixture for without a compile-time sed, per that gate's own note — crossed
## with FP_SHADE_UNIFIED/FP_SMOOTH_NORMAL_LIT each forced on/off, since both accept the SAME gate-forcing override
## params `_apply_slot_indirect` itself uses) and LINT it: no declared varying may be assigned in both `vertex()`
## and `fragment()`/`light()` (Godot's own parse rule, R4.1). Non-vacuous: the ORIGINAL (pre-fix) fragment splice,
## reproduced inline above, DOES violate this on every variant that actually declares v_slot/v_bslot — proving the
## lint has teeth. This is the headless PROXY for a real GLSL parse (the dummy RenderingServer never parses
## `shader_set_code` — see G-FS-SHADER-COMPILE / R4.4's note; only a live browser or a real GPU context confirms
## compilation).
func _gate_vary_stage() -> void:
	print("  --- REVISION 4 G-FS-VARY-STAGE (Stage A): no varying assigned in both vertex() and fragment()/light() ---")
	var base_variants := [
		["_SHELL_ABS_SHADER (no UV2 at all)", FacetFarRing._SHELL_ABS_SHADER],
		["base tex, no CU/no band", FacetFarRing.gate_tex_shader_raw(false)],
		["CU tex (v_slot only)", FacetFarRing.gate_tex_shader_raw(true)],
		["flatcolor on base tex (v_bslot only)", FacetFarRing._apply_flatcolor(FacetFarRing._SHELL_ABS_TEX_SHADER)],
		["flatcolor on CU tex (v_slot + v_bslot)", FacetFarRing._apply_flatcolor(FacetFarRing._SHELL_ABS_TEX_CU_SHADER)],
	]
	# Broaden to "every flag combination" as far as this harness can force without a compile-time sed: cross each
	# base variant with FP_SHADE_UNIFIED / FP_SMOOTH_NORMAL_LIT each forced on/off.
	var variants := []
	for pair in base_variants:
		var name0: String = pair[0]
		var code0: String = pair[1]
		for unified in [false, true]:
			for lit in [false, true]:
				var code := FacetFarRing._apply_shade_unified(code0, unified)
				code = FacetFarRing._apply_smooth_normal_lit(code, lit)
				variants.append(["%s [shade_unified=%s, normal_lit=%s]" % [name0, unified, lit], code])

	var checked := 0
	for pair in variants:
		var name: String = pair[0]
		var code: String = pair[1]
		checked += 1
		var fixed_code := FacetFarRing._apply_slot_indirect(code, true)
		var viol := FacetFarRing.lint_varying_stage_conflicts(fixed_code)
		_ok(viol.is_empty(), "G-FS-VARY-STAGE: %s — the FIXED Q2' splice has NO varying assigned in both vertex() and fragment()/light() (found: %s)" % [name, str(viol)])
	_ok(checked > 0, "G-FS-VARY-STAGE: checked a non-empty variant set (%d variants)" % checked)

	# --- Non-vacuous: the ORIGINAL (pre-fix) fragment splice DOES violate the rule on every variant that actually
	# declares v_slot/v_bslot (variants with neither are an inert no-op splice either way — nothing to violate). ---
	var saw_violation := false
	var slot_variant_count := 0
	for pair in variants:
		var name: String = pair[0]
		var code: String = pair[1]
		if code.find("varying float v_slot;") < 0 and code.find("varying float v_bslot;") < 0:
			continue
		slot_variant_count += 1
		var broken_code := _broken_splice_for_gate(code)
		var viol := FacetFarRing.lint_varying_stage_conflicts(broken_code)
		if not viol.is_empty():
			saw_violation = true
		_ok(not viol.is_empty(), "G-FS-VARY-STAGE-FALSIFY: %s — the ORIGINAL (pre-fix) fragment splice DOES reassign a vertex-assigned varying (%s) — the lint has teeth" % [name, str(viol)])
	_ok(slot_variant_count > 0, "G-FS-VARY-STAGE-FALSIFY: at least one variant actually declares v_slot/v_bslot (non-vacuous fixture)")
	_ok(saw_violation, "G-FS-VARY-STAGE-FALSIFY: the pre-fix defect reproduces on at least one real variant")

	# Flag-off byte-identity: the lint finds nothing wrong in the shipped (flag-off, un-spliced) shader sources either.
	for pair in base_variants:
		var name: String = pair[0]
		var code: String = pair[1]
		var viol := FacetFarRing.lint_varying_stage_conflicts(code)
		_ok(viol.is_empty(), "G-FS-VARY-STAGE: %s — the shipped (flag-off) shader source has no cross-stage varying conflict on its own" % name)

## G-SLOT-DECODE (Stage A secondary defect): pure-GDScript sweep of the FIXED `_slot_indirect` decode (the headless
## mirror — no GLSL runs headless) across fid 0..facet_count()-1, perturbed by ±0.49 (the worst-case barycentric
## drift a constant-across-the-triangle varying could show), asserting it maps to the EXACT (fid % w, fid / w) texel
## `_push_slot_indirect` wrote that fid's slot at — no rounding-boundary off-by-one. Non-vacuous: the ORIGINAL
## (un-rounded `mod`/`floor`) decode gets a row-boundary fid WRONG under a downward perturbation — the exact
## truncation defect R4.1 root-caused in `_SLOT_INDIRECT_UNIFORMS`.
func _gate_slot_decode() -> void:
	print("  --- REVISION 4 G-SLOT-DECODE: rounded, integer-exact _slot_indirect decode (headless GLSL mirror) ---")
	var w := FacetFarRing.SLOT_TEX_W
	var n := FA.facet_count()
	var checked := 0
	var all_ok := true
	for fid in range(n):
		for delta in [0.0, 0.49, -0.49]:
			var raw: float = float(fid) + float(delta)
			if raw < 0.0:
				continue   # the sentinel domain (fid < 0 ⇒ "no slot") — not the col/row decode this gate scopes to
			var got := FacetFarRing.slot_indirect_decode(raw, w)
			var want := Vector2i(fid % w, fid / w)
			checked += 1
			if got != want:
				all_ok = false
	_ok(checked > 0, "G-SLOT-DECODE: swept a non-empty fid × perturbation range (%d checks, facet_count=%d)" % [checked, n])
	_ok(all_ok, "G-SLOT-DECODE: the FIXED rounded decode maps every fid±0.49 in 0..%d to its exact (fid %% %d, fid / %d) texel — no boundary off-by-one" % [n - 1, w, w])

	# Non-vacuous: the ORIGINAL un-rounded decode gets a ROW-BOUNDARY fid wrong under a downward perturbation.
	var boundary_fid := w   # fid = SLOT_TEX_W (=64 at K=24) — the first row boundary; well inside facet_count for any real K
	_ok(boundary_fid < n, "G-SLOT-DECODE fixture: SLOT_TEX_W(%d) < facet_count()(%d) — the boundary fixture is in-range" % [boundary_fid, n])
	if boundary_fid < n:
		var want_boundary := Vector2i(boundary_fid % w, boundary_fid / w)
		var naive_at_boundary := FacetFarRing.slot_indirect_decode_naive(float(boundary_fid) - 0.49, w)
		_ok(naive_at_boundary != want_boundary, "G-SLOT-DECODE-FALSIFY: the ORIGINAL un-rounded decode (mod/floor, no +0.5) gets fid=%d-0.49 WRONG (%s, expected %s) — the truncation defect this fix replaces" % [boundary_fid, str(naive_at_boundary), str(want_boundary)])
		var fixed_at_boundary := FacetFarRing.slot_indirect_decode(float(boundary_fid) - 0.49, w)
		_ok(fixed_at_boundary == want_boundary, "G-SLOT-DECODE: the FIXED decode gets the SAME boundary fixture exactly right (%s)" % str(fixed_at_boundary))

## G-FS-QUIESCE-RING (Stage B, catches R4.2's whole class — the fixpoint REV3's G-FS-QUIESCE gate missed: it only
## counted the SMOOTH DRIVER's own counters, never the shell's emit/count path where the loop actually lived). Drives
## a REAL FacetFarRing to the exact live scenario: the ACTIVE facet forced S2-smooth-resident (what FP_SMOOTH_RIM
## does live) while `FacetFarRing.setup()`'s OWN initial synchronous `_rebuild_full()` has already warmed every
## OTHER front-visible facet's shell cache — the active facet's cache is the ONE thing nothing in shipped code ever
## builds (the near voxel world owns it on the plain surface regime). Switches the ring into the camera-set/orbit
## cull regime (`_cam_set`, same axis+threshold `setup()`'s own build used) so the active facet is actually counted
## by `_front_visible`/the two counters — on the plain surface regime with FP_FARRING_FULL_COVER off it is
## unconditionally excluded from the far ring's bookkeeping altogether, which would make this scenario unreachable
## without a compile-time sed of FULL_COVER (this harness runs with FACETED only, matching every other gate in this
## file). Falsifies FP_RING_QUIESCE off (the counter never reaches 0; `_begin_rebuild_count` climbs over 240 frames
## — the shipped endless re-emit train reproduces) THEN proves the fix (the counter reaches 0 — the fixpoint EXISTS
## under the emit predicate — and a real 240-frame settle window does ZERO further rebuild/re-emit/pending work).
func _gate_quiesce_ring() -> void:
	print("  --- REVISION 4 G-FS-QUIESCE-RING (Stage B, FP_RING_QUIESCE): the shell's own emit/count fixpoint at rest ---")
	var fid_a := _fid_of(2, 10, 10)
	var ring := FacetFarRing.new()
	ring.setup(fid_a)   # ALSO runs the initial synchronous _rebuild_full() — warms every front-visible facet's cache
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)

	# Switch to the camera-set/orbit cull regime with the SAME axis+threshold setup()'s own build used, so the
	# already-warmed cache set is unaffected by the switch — only the active facet's own front-visibility changes.
	ring._emit_axis = FA.facet_normal64(fid_a)
	ring._emit_cos = FacetFarRing.BACK_CULL
	ring._cam_set = true
	ring._emit_floored_last = false
	var p := ring._cull_params()

	# Warm-up: converge the P1 smooth driver so the ACTIVE facet becomes S2-smooth-resident. `rim_on` (the 3rd arg)
	# MUST be forced true here — the sticky hop ladder (`_smooth_hop_assignment`) never assigns the active facet a
	# tier at all (it starts the BFS FROM active, tiering only its NEIGHBOURS); the active facet's OWN S2 residency
	# comes exclusively from `_rim_assign` (FP_SMOOTH_RIM, P3's near-collar), which is what reproduces the exact
	# live R4.2 scenario ("under FP_SMOOTH_RIM the ACTIVE facet is S2 smooth-resident").
	var iters := 0
	while iters < 20000 and not ring._smooth.is_settled():
		ring._smooth_drive(true, true, true, true, false)
		iters += 1
	_ok(ring._smooth.is_settled(), "G-FS-QUIESCE-RING warm-up: the smooth driver reaches settled (%d iterations)" % iters)
	_ok(ring._smooth.is_resident(fid_a), "G-FS-QUIESCE-RING warm-up: the ACTIVE facet is S2-smooth-resident (the exact R4.2 live scenario, non-vacuous)")
	_ok(ring._smooth.resident_count() > 1, "G-FS-QUIESCE-RING warm-up: at least one OTHER facet is also smooth-resident (a real S2+S3-scale ladder, non-vacuous)")
	_ok(ring._smooth_covered(fid_a), "G-FS-QUIESCE-RING warm-up: the shared `_smooth_covered` predicate agrees the active facet is covered")
	_ok(not ring._pos_cache.has(fid_a), "G-FS-QUIESCE-RING warm-up: the active facet's shell cache was never warmed (nothing in shipped code ever builds it) — the exact gap the OLD counting law never excluded")

	# --- (A) FALSIFY: FP_RING_QUIESCE forced OFF — the shipped counting/re-arm law reproduces: no fixpoint. ---
	var remaining_off := ring._count_uncached_visible(p, false)
	_ok(remaining_off > 0, "G-FS-QUIESCE-RING-FALSIFY: WITHOUT the fix, _count_uncached_visible(p) counts the smooth-covered active facet as still needing a cache (remaining=%d) — never reaches 0" % remaining_off)
	var begin_before_off: int = ring._begin_rebuild_count
	for i in range(240):
		ring._noblack_guarantee(p, false, true)   # noblack_on forced true — reproduces the live FP_FARRING_ACTIVE_NOBLACK+FULL_COVER deploy config
		ring._orbit_warm_async(p, false)
	var begin_after_off: int = ring._begin_rebuild_count
	_ok(begin_after_off > begin_before_off, "G-FS-QUIESCE-RING-FALSIFY: WITHOUT the fix, the IDENTICAL smooth-covered scenario CLIMBS _begin_rebuild_count over 240 frames (%d -> %d) — the shipped endless re-emit train reproduces" % [begin_before_off, begin_after_off])

	# --- (B) WITH the fix: the counter reaches 0 (the fixpoint EXISTS under the emit predicate), THEN a real
	# 240-frame settle window does ZERO further rebuild/re-emit/pending work. ---
	var remaining_on := ring._count_uncached_visible(p, true)
	_ok(remaining_on == 0, "G-FS-QUIESCE-RING: _count_uncached_visible(p) reaches 0 under FP_RING_QUIESCE with the active facet smooth-covered (the fixpoint EXISTS under the emit predicate)")
	_ok(ring._count_uncovered_visible(p, true) == 0, "G-FS-QUIESCE-RING: _count_uncovered_visible(p) also reaches 0 under FP_RING_QUIESCE")

	# Prime once (drains any leftover pending/first-engage transient left over from the (A) falsify run above), then
	# measure a REAL 240-frame settle window from a clean baseline.
	ring._noblack_guarantee(p, true, true)
	ring._orbit_warm_async(p, true)
	var begin0: int = ring._begin_rebuild_count
	var reemit0: int = ring._reemit_count
	var gen0: int = ring._shell_gen
	var pend_ever_true := false
	for i in range(240):
		ring._noblack_guarantee(p, true, true)
		ring._orbit_warm_async(p, true)
		if ring._pending:
			pend_ever_true = true
	var begin1: int = ring._begin_rebuild_count
	var reemit1: int = ring._reemit_count
	var gen1: int = ring._shell_gen
	_ok(begin1 == begin0, "G-FS-QUIESCE-RING: ZERO _begin_rebuild_count delta over 240 settled frames (%d -> %d)" % [begin0, begin1])
	_ok(reemit1 == reemit0, "G-FS-QUIESCE-RING: ZERO _reemit_count delta over 240 settled frames (%d -> %d)" % [reemit0, reemit1])
	_ok(gen1 == gen0, "G-FS-QUIESCE-RING: ZERO _shell_gen delta over 240 settled frames (%d -> %d)" % [gen0, gen1])
	_ok(not pend_ever_true, "G-FS-QUIESCE-RING: `_pending` (sh_pend) never flips true across any of the 240 settled frames")
	_ok(ring._count_uncached_visible(p, true) == 0, "G-FS-QUIESCE-RING: _count_uncached_visible(p) still 0 after the settle window (the fixpoint holds)")
	ring.free()

# =====================================================================================================
# REVISION 5 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 5 — rest quiescence COMPLETION")
# =====================================================================================================

## Fixture: a FacetFarRing switched into the FLOORED camera-set regime (θ_emit = 90° at the ground — R5.1's actual
## live residual regime), with the SAME axis+threshold `setup()`'s own initial synchronous rebuild used (so the
## already-warmed chord set is unaffected by the switch — mirrors `_gate_quiesce_ring`'s identical trick one section
## up, just floored instead of orbit).
func _mk_floored_ring(fid: int) -> FacetFarRing:
	var r := FacetFarRing.new()
	r.setup(fid)   # ALSO runs its own synchronous _rebuild_full() — warms every front-visible facet's CHORD cache
	r._emit_axis = FA.facet_normal64(fid)
	r._emit_cos = FacetFarRing.BACK_CULL
	r._cam_set = true
	r._emit_floored_last = true
	return r

## G-FS-QUIESCE-SURF (REVISION 5, replaces the orbit-only gap G-FS-QUIESCE-RING left): drives the LIVE FLOORED
## env-convergence loop — `_surface_converge_emit`'s FP_ENV_FLOORED_ASYNC branch (R5.1's ACTUAL residual driver,
## NOT the orbit branch G-FS-QUIESCE-RING exercises) — with every prerequisite forced via gate-forcing params
## (`fallback_on`, `floored_async_on`, `force_async`, `env_on`) so the REAL `_count_uncached_visible`/`_env_have`/
## `_ensure_cached` env-envelope law executes headless, with NO compile-time sed of FP_ENV_FALLBACK_EMIT/
## FP_ENV_FLOORED_ASYNC or the three consts `TierPlace.env_all_on()` folds together (FP_ENV_ALL/FP_FARRING_FULL_COVER/
## FP_SHELL_WELD). A cold floored engage (fresh `FacetFarRing.setup()` — chords already warmed by its own initial
## sync rebuild, but `_env_done`/`_benv_done` are EMPTY, exactly the state every live descent lands in) must latch
## within `ceil(demand/ENV_WARM_BATCH)+2` dispatches (demand = the FP_ENV_DEMAND_DISC-bounded set) with
## `_reemit_count` delta ≤ 2 (FP_WARM_EMIT_SPLIT: one initial coverage emit + one final env-converged emit), THEN
## holds a REAL 240-frame zero-delta settle window on `_begin_rebuild_count`/`_reemit_count`/`_shell_gen`/`_pending`.
## Falsifies BOTH ways: demand-disc forced off ⇒ the SAME dispatch budget that fully converges the fixed case
## leaves the cold engage UNCONVERGED (the live ~125-cycle stall reproduces, `_count_uncached_visible` degrading to
## the shipped un-bounded ~1500-facet demand); warm-split forced off ⇒ `_reemit_count` climbs with every warm batch
## instead of latching at ≤2 (the shipped fused warm+emit cadence).
func _gate_quiesce_surf() -> void:
	print("  --- REVISION 5 G-FS-QUIESCE-SURF (Stage A FP_ENV_DEMAND_DISC + Stage B FP_WARM_EMIT_SPLIT): the LIVE FLOORED env-convergence fixpoint at rest ---")
	var fid_a := _fid_of(2, 10, 10)
	var quiesce_on := true
	var fallback_on := true
	var floored_async_on := true
	var demand_on := true
	var warm_split_on := true
	var env_on := true

	var ring := _mk_floored_ring(fid_a)
	var p := ring._cull_params()
	_ok(ring._env_done.is_empty() and ring._benv_done.is_empty(), "G-FS-QUIESCE-SURF warm-up: a cold floored engage starts with EMPTY env dicts (chords only, from setup()'s own sync rebuild) — non-vacuous baseline")
	_ok(ring._env_async_floored_on(fallback_on, floored_async_on, true, env_on), "G-FS-QUIESCE-SURF warm-up: the forced params select the REAL floored-async branch (no const sed needed)")

	# --- (A) the FIXED case: cold-engage dispatch bound + reemit bound ------------------------------------------
	ring._surface_converge_emit(p, quiesce_on, demand_on, fallback_on, floored_async_on, warm_split_on, true, env_on)   # dispatch #1: coverage
	var begin0: int = ring._begin_rebuild_count
	var reemit0: int = ring._reemit_count
	var demand := ring._count_uncached_visible(p, quiesce_on, demand_on, fallback_on, floored_async_on)
	_ok(demand > 0, "G-FS-QUIESCE-SURF warm-up: the demand-bounded env set is non-empty after the coverage dispatch (demand=%d) — non-vacuous" % demand)
	var bound := int(ceil(float(demand) / float(FacetFarRing.ENV_WARM_BATCH))) + 2
	var dispatches := 1
	while ring._count_uncached_visible(p, quiesce_on, demand_on, fallback_on, floored_async_on) > 0 and dispatches < bound + 20:
		ring._surface_converge_emit(p, quiesce_on, demand_on, fallback_on, floored_async_on, warm_split_on, true, env_on)
		dispatches += 1
	ring._surface_converge_emit(p, quiesce_on, demand_on, fallback_on, floored_async_on, warm_split_on, true, env_on)   # the final env-converged re-emit (R5.B)
	dispatches += 1
	var remaining_final := ring._count_uncached_visible(p, quiesce_on, demand_on, fallback_on, floored_async_on)
	_ok(remaining_final == 0, "G-FS-QUIESCE-SURF: remaining latches to 0 (demand=%d, took %d dispatches)" % [demand, dispatches])
	_ok(dispatches <= bound, "G-FS-QUIESCE-SURF: cold floored engage latches within ceil(demand/ENV_WARM_BATCH)+2=%d dispatches (took %d)" % [bound, dispatches])
	var begin1: int = ring._begin_rebuild_count
	var reemit1: int = ring._reemit_count
	_ok(begin1 - begin0 <= bound, "G-FS-QUIESCE-SURF: _begin_rebuild_count delta <= bound (%d <= %d)" % [begin1 - begin0, bound])
	_ok(reemit1 - reemit0 <= 2, "G-FS-QUIESCE-SURF: _reemit_count delta <= 2 -- one initial coverage emit + one final env-converged emit (got %d)" % (reemit1 - reemit0))

	# --- settle window: 240 REAL frames of zero further work ----------------------------------------------------
	var begin_s0: int = ring._begin_rebuild_count
	var reemit_s0: int = ring._reemit_count
	var gen_s0: int = ring._shell_gen
	var pend_ever := false
	for i in range(240):
		ring._surface_converge_emit(p, quiesce_on, demand_on, fallback_on, floored_async_on, warm_split_on, true, env_on)
		if ring._pending:
			pend_ever = true
	_ok(ring._begin_rebuild_count == begin_s0, "G-FS-QUIESCE-SURF: ZERO _begin_rebuild_count delta over 240 settled frames (%d -> %d)" % [begin_s0, ring._begin_rebuild_count])
	_ok(ring._reemit_count == reemit_s0, "G-FS-QUIESCE-SURF: ZERO _reemit_count delta over 240 settled frames (%d -> %d)" % [reemit_s0, ring._reemit_count])
	_ok(ring._shell_gen == gen_s0, "G-FS-QUIESCE-SURF: ZERO _shell_gen delta over 240 settled frames (%d -> %d)" % [gen_s0, ring._shell_gen])
	_ok(not pend_ever, "G-FS-QUIESCE-SURF: `_pending` (sh_pend) never flips true across any of the 240 settled frames")
	_ok(ring._count_uncached_visible(p, quiesce_on, demand_on, fallback_on, floored_async_on) == 0, "G-FS-QUIESCE-SURF: remaining stays 0 after the settle window (the fixpoint holds)")
	ring.free()

	# --- (B) FALSIFY demand-disc off: the SAME dispatch budget leaves the cold engage UNCONVERGED -----------------
	var ring_nd := _mk_floored_ring(fid_a)
	var p_nd := ring_nd._cull_params()
	for i in range(bound):
		ring_nd._surface_converge_emit(p_nd, quiesce_on, false, fallback_on, floored_async_on, warm_split_on, true, env_on)
	var remaining_nd := ring_nd._count_uncached_visible(p_nd, quiesce_on, false, fallback_on, floored_async_on)
	_ok(remaining_nd > 0, "G-FS-QUIESCE-SURF-FALSIFY (FP_ENV_DEMAND_DISC off): the SAME %d-dispatch budget that fully converges the fixed case leaves the cold engage UNCONVERGED (remaining=%d) -- the live ~125-cycle stall reproduces" % [bound, remaining_nd])
	ring_nd.free()

	# --- (C) FALSIFY warm-split off: _reemit_count climbs with every warm batch instead of latching at <=2 --------
	var ring_ws := _mk_floored_ring(fid_a)
	var p_ws := ring_ws._cull_params()
	ring_ws._surface_converge_emit(p_ws, quiesce_on, demand_on, fallback_on, floored_async_on, false, true, env_on)
	var reemit_ws0: int = ring_ws._reemit_count
	var cycles := 0
	while ring_ws._count_uncached_visible(p_ws, quiesce_on, demand_on, fallback_on, floored_async_on) > 0 and cycles < bound + 10:
		ring_ws._surface_converge_emit(p_ws, quiesce_on, demand_on, fallback_on, floored_async_on, false, true, env_on)
		cycles += 1
	var reemit_ws1: int = ring_ws._reemit_count
	_ok(reemit_ws1 - reemit_ws0 > 2, "G-FS-QUIESCE-SURF-FALSIFY (FP_WARM_EMIT_SPLIT off): _reemit_count CLIMBS with every warm batch instead of latching at <=2 (delta=%d over %d cycles)" % [reemit_ws1 - reemit_ws0, cycles])
	ring_ws.free()

## REVISION 5 Stage C fixture helper: prime a FRESH FacetTexBaker's fine-map + single-slot parallel-bake state
## directly (bypassing the long `_pbm_on`/`_worker_on`/FP_SKIN_SSE/FP_CPP_TILE_BAKE prerequisite chain
## `_setup_parallel_band` normally requires — the same "poke flag-gated internals directly" technique used
## throughout this file for FacetFarRing) so `_update_band_parallel`'s fine-tier dispatch loop can be driven
## headless with a single slot (`_pbm_n = 1`).
func _prime_fine_map(b: FacetTexBaker) -> void:
	FarPalette.ensure_far_index_ready()
	b._fm_on = true
	b._fm_texels = CubeSphere.PLANET_MAP_TEXELS
	b._fm_quad = CubeSphere.PLANET_MAP_QUAD
	b._fm_page = b._fm_quad * b._fm_texels
	# Mirrors _setup_fine_map()'s own init: 24 L8 sub-page staging Images (_fine_commit's blit_rect target) + the
	# matching GPU array. Without this, _fine_commit indexes an EMPTY _fm_pages and the upload-throttle in
	# _update_band_parallel calls update_layer on a null _fm_tex.
	var imgs: Array[Image] = []
	for l in range(6 * 4):
		var im := Image.create(b._fm_page, b._fm_page, false, Image.FORMAT_L8)
		im.fill(Color(0.0, 0.0, 0.0, 1.0))
		b._fm_pages.append(im)
		imgs.append(im)
	b._fm_tex = Texture2DArray.new()
	b._fm_tex.create_from_images(imgs)
	b._pbm_n = 1
	b._pbm_fid = [-1]
	b._pbm_layer = [-1]
	b._pbm_task = [-1]
	b._pbm_bytes = [PackedByteArray()]
	b._pbm_lc = [PackedVector2Array()]
	b._pbm_nx = [0]
	b._pbm_ny = [0]
	b._pbm_mode = [0]
	b._pbm_cpp = [0]
	b._pbm_tile = [0]

## G-TEX-SURF-PAUSE (REVISION 5 Stage C, FP_FINE_BAKE_SURFACE_PAUSE): the FP_PLANET_MAP fine-tier dispatch loop
## (`FacetTexBaker._update_band_parallel`) must drain to ZERO new tasks while ON-SURFACE and RESUME off-surface.
## Falsifies: pause forced OFF ⇒ a fine task DISPATCHES even on-surface (the shipped perpetual-bake bug this
## revision fixes); pause forced ON ⇒ the slot drains to zero and STAYS there across many on-surface calls, resumes
## the instant `_offsurface` flips true, and an already-in-flight (off-surface-dispatched) task still COMMITS after
## landing back on-surface (the REAP is unconditional — only NEW dispatch is gated, matching R5.2's design). Also
## asserts `fm_baked`/`fm_want`/`fm_dirty` now exist in `tex_telemetry()` (the fine tier had NO telemetry at all —
## the blind spot that let the perpetual bake hide in the first place).
func _gate_tex_surf_pause() -> void:
	print("  --- REVISION 5 G-TEX-SURF-PAUSE (Stage C FP_FINE_BAKE_SURFACE_PAUSE): fine-tier dispatch pauses on-surface, resumes off-surface ---")
	var fid := FA.spawn_facet()
	var axis_v := _centre_dir(fid)
	var axis := [axis_v.x, axis_v.y, axis_v.z]

	# --- (A) FALSIFY: pause forced OFF -- a fine task dispatches even ON-SURFACE (the shipped perpetual-bake bug). ---
	var b_off := FacetTexBaker.new()
	b_off.setup(fid)
	_prime_fine_map(b_off)
	b_off._offsurface = false
	b_off._update_band_parallel(axis, false)
	_ok(b_off._pbm_busy_count() > 0, "G-TEX-SURF-PAUSE-FALSIFY: WITHOUT the fix, a fine-tier task DISPATCHES on-surface (busy=%d) -- the shipped perpetual bake reproduces" % b_off._pbm_busy_count())
	if int(b_off._pbm_task[0]) >= 0:
		WorkerThreadPool.wait_for_task_completion(int(b_off._pbm_task[0]))
	# FacetTexBaker extends RefCounted — no manual .free() (unlike FacetFarRing/Node3D elsewhere in this file);
	# it is collected automatically once `b_off` goes out of scope.

	# --- (B) WITH the fix: on-surface, the slot drains to 0 and STAYS 0 over repeated calls. ---
	var b := FacetTexBaker.new()
	b.setup(fid)
	_prime_fine_map(b)
	b._offsurface = false
	var stayed_drained := true
	for i in range(10):
		b._update_band_parallel(axis, true)
		if b._pbm_busy_count() != 0:
			stayed_drained = false
	_ok(stayed_drained, "G-TEX-SURF-PAUSE: on-surface, the fine-tier dispatch slot stays drained to 0 across 10 calls")
	_ok(b._fine_baked.is_empty(), "G-TEX-SURF-PAUSE: nothing got fine-baked on-surface under the pause")

	# --- (C) off-surface: dispatch resumes. ---
	b._offsurface = true
	b._update_band_parallel(axis, true)
	_ok(int(b._pbm_task[0]) >= 0, "G-TEX-SURF-PAUSE: off-surface, the fine-tier dispatch RESUMES (a task is queued)")
	# Poll completion WITHOUT reclaiming (`is_task_completed` only) -- `wait_for_task_completion` reclaims the task
	# ID, and calling it here THEN AGAIN inside (D)'s own reap (which also calls wait_for_task_completion once it
	# sees is_task_completed==true) double-reclaims the SAME id -> "ERROR: Invalid Task ID" and the second (real)
	# reap silently no-ops, leaving the slot stuck busy and nothing committed. Only the production reap loop may
	# ever reclaim a task id; the gate just waits for the flag.
	var task_id := int(b._pbm_task[0])
	var waited_ms := 0
	while task_id >= 0 and not WorkerThreadPool.is_task_completed(task_id) and waited_ms < 5000:
		OS.delay_msec(2)
		waited_ms += 2
	_ok(task_id < 0 or WorkerThreadPool.is_task_completed(task_id), "G-TEX-SURF-PAUSE warm-up: the off-surface fine-tier task completes (waited %d ms)" % waited_ms)

	# --- (D) flip BACK on-surface WHILE the (already-completed, un-reclaimed) task is pending reap -- the reap
	# still commits it; only NEW dispatch is gated, in-flight work always drains exactly once. ---
	b._offsurface = false
	b._update_band_parallel(axis, true)   # THIS call's reap loop is the ONLY wait_for_task_completion on this id
	_ok(b._fine_baked.size() > 0, "G-TEX-SURF-PAUSE: an off-surface-dispatched fine task still COMMITS after landing back on-surface (the reap is unconditional) -- %d baked" % b._fine_baked.size())
	_ok(b._pbm_busy_count() == 0, "G-TEX-SURF-PAUSE: back on-surface, no NEW task re-dispatches after the reap (%d busy)" % b._pbm_busy_count())

	var tel := b.tex_telemetry()
	_ok(tel.has("fm_baked") and tel.has("fm_want") and tel.has("fm_dirty"), "G-TEX-SURF-PAUSE: tex_telemetry() exposes fm_baked/fm_want/fm_dirty (the previously-invisible fine-tier sweep)")
	_ok(int(tel["fm_baked"]) == b._fine_baked.size(), "G-TEX-SURF-PAUSE: fm_baked matches _fine_baked.size() (%d)" % b._fine_baked.size())
	# FacetTexBaker extends RefCounted — no manual .free() needed.

## G-RIM-MULT (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D, §7.1 (i), FP_RIM_CHEAP): the coarsened S2
## envelope (`TierPlace.rim_fine_mult()`) stays a valid no-protrusion lower bound after `TierPlace.rim_env_resid()`
## is subtracted — proven the way the design instructs: the node-wise coarse-vs-fine (ENV_FINE_MULT=4 reference)
## delta is measured directly on a mountainous fixture, and RIM_ENV_RESID must cover its worst value. Since the
## mult=4 reference is ITSELF already proven ≤ true (the shipped G-RIM-ENV / G-NPT-* gates), coarse−resid ≤ fine
## ≤ true is a transitive, sufficient proof. Also exercises the FULL `build_tile_rim(cheap_on=true)` path end-to-
## end (mirroring `_gate_rim_env`'s existing style) to prove the integrated builder — not just the raw envelope
## function — carries the same margin. FALSIFY: the same coarse-vs-fine delta WITHOUT subtracting RIM_ENV_RESID
## (resid forced to 0) DOES exceed the fine reference — the check is not vacuously satisfied by construction.
func _gate_rim_mult() -> void:
	print("  --- G-RIM-MULT: FP_RIM_CHEAP coarsened S2 envelope stays no-protrusion after RIM_ENV_RESID compensation ---")
	var fid := _fid_of(4, 7, 8)   # the codebase's own "mountainous" fixture (verify_far_smooth.gd:159's own note)
	var cells := FST.cells_for_tier(FST.S2)

	# (A) raw envelope comparison: coarse (rim_fine_mult) vs the shipped ENV_FINE_MULT=4 reference.
	var env_fine := FacetFarRing._env_weld_grid(fid, cells, TierPlace.ENV_FINE_MULT)
	var pos_fine: PackedVector3Array = env_fine[0]
	var mult := TierPlace.rim_fine_mult()
	var env_coarse := FacetFarRing._env_weld_grid(fid, cells, mult)
	var pos_coarse: PackedVector3Array = env_coarse[0]
	var resid := TierPlace.rim_env_resid()
	var max_delta := -1.0e30
	var ok_after_resid := true
	var protrudes_without_resid := false
	for i in range(pos_fine.size()):
		var d: Vector3 = pos_fine[i].normalized()
		var delta: float = (pos_coarse[i] - pos_fine[i]).dot(d)   # +ve: coarse sits ABOVE the fine reference
		max_delta = maxf(max_delta, delta)
		if delta - resid > 1.0e-4:
			ok_after_resid = false
		if delta > 1.0e-4:
			protrudes_without_resid = true
	_ok(max_delta > 0.0, "G-RIM-MULT: measured a real coarse(mult=%d)-vs-fine(mult=4) envelope gap on the mountain fixture (max %.4f blocks) — non-trivial fixture" % [mult, max_delta])
	_ok(ok_after_resid, "G-RIM-MULT: (coarse − RIM_ENV_RESID=%.2f) <= the mult=4 reference at EVERY S2 node (worst residual %.4f) — no-protrusion preserved by construction" % [resid, max_delta])
	_ok(protrudes_without_resid, "G-RIM-MULT-FALSIFY: WITHOUT the RESID subtraction the coarse envelope DOES exceed the fine reference (max %.4f > 0) — the compensation is load-bearing, not vacuous" % max_delta)

	# (B) end-to-end: build_tile_rim(cheap_on=true) itself, mirroring _gate_rim_env's own no-protrusion check.
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var player_col: Vector3 = centre_node["pos"]
	var r_env := 80.0
	var feather := CubeSphere.RIM_FEATHER_BLOCKS
	var sink := TierPlace.backstop_sink()
	var tile := FST.build_tile_rim(fid, cells, player_col, r_env, feather, sink, CubeSphere.FP_SMOOTH_NORMAL_LIT, -1.0, true)
	var pos: PackedVector3Array = tile["pos"]
	var stride := cells + 1
	var inv := 1.0 / float(cells)
	var inside_checked := 0
	var min_margin := 1.0e30
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var node := FD.node_at(corner_dirs, r_datum, s, t)
			var true_pos: Vector3 = node["pos"]
			if true_pos.distance_to(player_col) > r_env:
				continue
			inside_checked += 1
			var vi := gj * stride + gi
			var dd: Vector3 = node["dir"]
			var true_relief := float(node["relief"])
			var rendered_relief := (pos[vi] - dd * r_datum).dot(dd)
			min_margin = minf(min_margin, true_relief - rendered_relief)
	_ok(inside_checked > 0, "G-RIM-MULT: %d end-to-end S2 vertices fall inside R_env=%.0f under cheap_on=true (exercises the disc branch)" % [inside_checked, r_env])
	_ok(min_margin >= -1.0e-3, "G-RIM-MULT: build_tile_rim(cheap_on=true) end-to-end never protrudes inside the disc (worst margin %.4f)" % min_margin)

## G-RIM-CRESCENT (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D, §7.1 (ii), FP_RIM_CHEAP): a crescent
## rebake (cached env + a prior committed tile, drift-tested reuse) reproduces a from-scratch full rebake AT THE
## SAME new column bit-for-bit (<=1e-4 blocks — the weld canon survives). Non-vacuous TWICE: (1) corrupting a
## deep-inside-the-disc node (guaranteed reuse-eligible — `dist==0` at the tile's own centre, the frozen
## `player_col`) in the cached tile shows up VERBATIM in the crescent output (proves reuse actually happens, not a
## dead code path) while the independent full rebake is unaffected (proves the two builds are compared honestly,
## not coincidentally equal); (2) corrupting a BOUNDARY node shows the crescent output is UNAFFECTED by the
## corruption (boundary nodes are ALWAYS freshly recomputed, guaranteeing the cross-facet weld can never go stale).
func _gate_rim_crescent(fid: int) -> void:
	print("  --- G-RIM-CRESCENT: crescent rebake == full rebake at the new column (bit-equal); stale-reuse falsified both ways ---")
	var cells := FST.cells_for_tier(FST.S2)
	var stride := cells + 1
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var old_col: Vector3 = centre_node["pos"]
	var r_env := 80.0
	var feather := CubeSphere.RIM_FEATHER_BLOCKS
	var sink := TierPlace.backstop_sink()

	# Initial (cache-less) bake at old_col, cheap_on=true — this IS the cache a real re-bake would consume.
	var tile0 := FST.build_tile_rim(fid, cells, old_col, r_env, feather, sink, CubeSphere.FP_SMOOTH_NORMAL_LIT, -1.0, true)
	var prev_env_pos: PackedVector3Array = tile0["rim_env_pos"]
	_ok(prev_env_pos.size() == stride * stride, "G-RIM-CRESCENT: build_tile_rim(cheap_on=true) returns a rim_env_pos cache of the right size (%d)" % prev_env_pos.size())

	# A representative drift (RIM_REBUILD_BLOCKS-scale — the real cadence gate's own trigger threshold).
	var new_col := old_col + Vector3(CubeSphere.RIM_REBUILD_BLOCKS, 0.0, 0.0)

	# (A) crescent rebake vs (B) an independent from-scratch full rebake AT new_col — must be bit-equal.
	var tile_crescent := FST.build_tile_rim(fid, cells, new_col, r_env, feather, sink, CubeSphere.FP_SMOOTH_NORMAL_LIT, -1.0, true, prev_env_pos, tile0, old_col)
	var tile_full := FST.build_tile_rim(fid, cells, new_col, r_env, feather, sink, CubeSphere.FP_SMOOTH_NORMAL_LIT, -1.0, true)
	var pos_c: PackedVector3Array = tile_crescent["pos"]
	var pos_f: PackedVector3Array = tile_full["pos"]
	var bit_equal := true
	var max_diff := 0.0
	for i in range(pos_c.size()):
		var dd: float = pos_c[i].distance_to(pos_f[i])
		max_diff = maxf(max_diff, dd)
		if dd > 1.0e-4:
			bit_equal = false
	_ok(bit_equal, "G-RIM-CRESCENT: crescent rebake position array is bit-equal (<=1e-4 blocks) to a from-scratch full rebake at the new column (max diff %.6f)" % max_diff)

	# (1) NON-VACUOUS reuse proof: corrupt the CENTRE node (dist-to-old_col == 0 -- deep inside, unconditionally
	# reuse-eligible) in a COPY of the cached tile, and show the crescent build reuses it VERBATIM while the
	# independent full rebake (unaffected) computes the correct value -- the two diverge exactly at that node.
	var centre_vi := (cells / 2) * stride + (cells / 2)
	var pos0: PackedVector3Array = tile0["pos"]
	var pos0_corrupt := pos0.duplicate()
	pos0_corrupt[centre_vi] += Vector3(1000.0, 0.0, 0.0)
	var tile0_corrupt := tile0.duplicate()
	tile0_corrupt["pos"] = pos0_corrupt
	var tile_reuse_check := FST.build_tile_rim(fid, cells, new_col, r_env, feather, sink, CubeSphere.FP_SMOOTH_NORMAL_LIT, -1.0, true, prev_env_pos, tile0_corrupt, old_col)
	var pos_rc: PackedVector3Array = tile_reuse_check["pos"]
	_ok(pos_rc[centre_vi].distance_to(pos0_corrupt[centre_vi]) < 1.0e-6,
		"G-RIM-CRESCENT-FALSIFY(reuse): the centre node's corrupted stale value IS reused verbatim by the crescent path (proves reuse genuinely happens, not a dead branch)")
	_ok(pos_rc[centre_vi].distance_to(pos_f[centre_vi]) > 500.0,
		"G-RIM-CRESCENT-FALSIFY(reuse): that reused-corrupted centre node DIFFERS from the correct full-rebake value by >500 blocks (a real divergence, not a coincidental match)")

	# (2) NON-VACUOUS boundary-safety proof: corrupt a BOUNDARY node (gi=0) the SAME way; the crescent build must
	# NOT reuse it (boundary nodes are unconditionally fresh every rebake) — the weld canon can never go stale.
	var boundary_vi := (cells / 2) * stride + 0
	var pos0_corrupt_b := pos0.duplicate()
	pos0_corrupt_b[boundary_vi] += Vector3(1000.0, 0.0, 0.0)
	var tile0_corrupt_b := tile0.duplicate()
	tile0_corrupt_b["pos"] = pos0_corrupt_b
	var tile_boundary_check := FST.build_tile_rim(fid, cells, new_col, r_env, feather, sink, CubeSphere.FP_SMOOTH_NORMAL_LIT, -1.0, true, prev_env_pos, tile0_corrupt_b, old_col)
	var pos_bc: PackedVector3Array = tile_boundary_check["pos"]
	_ok(pos_bc[boundary_vi].distance_to(pos0_corrupt_b[boundary_vi]) > 500.0,
		"G-RIM-CRESCENT: a corrupted BOUNDARY node is NOT reused (crescent output differs from the stale value by >500 blocks)")
	_ok(pos_bc[boundary_vi].distance_to(pos_f[boundary_vi]) < 1.0e-4,
		"G-RIM-CRESCENT: the (always-fresh) boundary node still matches the correct full-rebake value (<=1e-4) — the cross-facet weld canon survives corruption")

## G-RIM-PACE (COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md REVISION 5 Stage D, warmup pacing, FP_RIM_CHEAP): a cold
## engage's `_rim_assign` grants AT MOST ONE brand-new S2 slot per call under `cheap_on=true` (never the whole
## backstop-role set at once), and the stagger still converges to covering every rim-role facet within a bounded
## number of calls. FALSIFY: `cheap_on=false` (the shipped path) floods EVERY rim-role facet's S2 grant in the
## SAME single call — the exact warmup flood this flag exists to fix.
func _gate_rim_pace() -> void:
	print("  --- G-RIM-PACE: FP_RIM_CHEAP warmup S2 dispatch is staggered (<=1 new grant per RIM_PACE_FRAMES calls) ---")
	var fid := _fid_of(2, 6, 7)
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	var pool := PackedInt32Array()
	for slot in range(4):
		var nb := FA.seam_neighbour(fid, slot)
		if nb >= 0 and not pool.has(nb):
			pool.append(nb)
	ring.set_pool_excluded(pool)
	var rim_role_count := 1 + pool.size()   # active + live-pool
	_ok(rim_role_count >= 3, "G-RIM-PACE: fixture has %d rim-role facets (a real cold-engage flood scenario)" % rim_role_count)

	# (A) first call, cheap_on=true: exactly ONE brand-new S2 grant.
	var merged: Dictionary = ring._rim_assign({}, true)
	var s2_count := 0
	for f in merged.keys():
		if int(merged[f]) == FST.S2:
			s2_count += 1
	_ok(s2_count == 1, "G-RIM-PACE: cold-engage first call grants S2 to exactly 1 of %d rim-role facets (got %d)" % [rim_role_count, s2_count])

	# (B) FALSIFY: cheap_on=false floods every rim-role facet in the SAME single call (an independent ring instance
	# so its own pacing counters don't interfere with (A)'s).
	var ring2 := FacetFarRing.new()
	ring2.setup(fid)
	ring2._smooth = FST.new()
	ring2._smooth.setup_instance(ring2, null)
	ring2.set_pool_excluded(pool)
	var merged_off: Dictionary = ring2._rim_assign({}, false)
	var s2_count_off := 0
	for f in merged_off.keys():
		if int(merged_off[f]) == FST.S2:
			s2_count_off += 1
	_ok(s2_count_off == rim_role_count, "G-RIM-PACE-FALSIFY: cheap_on=false (shipped) grants ALL %d rim-role facets S2 in the SAME call (got %d) -- the flood this flag fixes" % [rim_role_count, s2_count_off])

	# (C) advance RIM_PACE_FRAMES more calls (repeating the identical request -- no other driver state moves): the
	# 2nd facet's grant should land, never more than 1 NEW grant per pacing window.
	for _i in range(CubeSphere.RIM_PACE_FRAMES):
		merged = ring._rim_assign({}, true)
	var granted_after_2 := 0
	for f in merged.keys():
		if int(merged[f]) == FST.S2:
			granted_after_2 += 1
	_ok(granted_after_2 == 2, "G-RIM-PACE: after RIM_PACE_FRAMES(%d) more calls exactly 2 facets are S2-granted (staggered, got %d)" % [CubeSphere.RIM_PACE_FRAMES, granted_after_2])

	# (D) keep advancing until every rim-role facet is granted -- the stagger converges, never stalls forever.
	var total_calls := CubeSphere.RIM_PACE_FRAMES
	var granted_final := granted_after_2
	var budget := CubeSphere.RIM_PACE_FRAMES * (rim_role_count + 2)
	while granted_final < rim_role_count and total_calls < budget:
		merged = ring._rim_assign({}, true)
		granted_final = 0
		for f in merged.keys():
			if int(merged[f]) == FST.S2:
				granted_final += 1
		total_calls += 1
	_ok(granted_final == rim_role_count, "G-RIM-PACE: the stagger eventually grants ALL %d rim-role facets S2 (got %d after %d calls) -- never stalls" % [rim_role_count, granted_final, total_calls])

## G-FS-GROW-PACE (REVISION 5 extension, warmup pacing for the S3/S4/S5 LADDER, FP_SMOOTH_GROW_PACE): a cold engage
## (empty resident set) grows the driver's REQUESTED set (`FacetSmoothTier._want`, what `_smooth_drive` actually
## hands to `request()`) gradually -- at most SMOOTH_GROW_PER_FRAME NEW facets per call, ring-1 (the near<->far seam)
## excepted, which is granted on the very first call -- instead of flooding the whole ~289-facet hop-ring target in
## one call. Proves: (A) FALSIFY -- grow_on=false floods the FULL target into `_want` in the SAME first call (the
## shipped warmup flood). (B)/(C) grow_on=true's first call is a small partial subset, and no single subsequent call
## ever grows `_want` by more than SMOOTH_GROW_PER_FRAME. (D) the grow reaches the FULL target within a bounded
## number of calls -- never stalls. (E) once fully grown it converges to REAL committed tiles, and composes with
## FP_SMOOTH_IDLE: zero further request() rebuilds over many settled frames while stationary (the idle latch is not
## permanently blocked by, nor prematurely triggered ahead of, the grow-pace queue). (F) ring-1 is never paced.
func _gate_grow_pace() -> void:
	print("  --- G-FS-GROW-PACE: FP_SMOOTH_GROW_PACE grows the driver's requested set gradually (<= SMOOTH_GROW_PER_FRAME new/call) ---")
	var fid := _fid_of(1, 11, 11)

	var probe := FacetFarRing.new()
	probe.setup(fid)
	var target: Dictionary = probe._smooth_hop_assignment(fid)
	probe.free()
	_ok(target.size() > CubeSphere.SMOOTH_GROW_PER_FRAME * 4, "G-FS-GROW-PACE: fixture's cold hop-ring target (%d facets) is well beyond a few pacing windows (non-vacuous flood scenario)" % target.size())

	# (A) FALSIFY: grow_on=false (shipped) floods the WHOLE target into `_want` in the SAME first call.
	var ring_off := FacetFarRing.new()
	ring_off.setup(fid)
	ring_off._smooth = FST.new()
	ring_off._smooth.setup_instance(ring_off, null)
	ring_off._active_fid = fid
	ring_off._smooth_drive(true, true, false, false, false, false)
	_ok(ring_off._smooth._want.size() == target.size(), "G-FS-GROW-PACE-FALSIFY: grow_on=false floods the FULL %d-facet target into _want in the SAME first call (got %d) -- the shipped warmup flood this flag fixes" % [target.size(), ring_off._smooth._want.size()])
	ring_off.free()

	# (B) first call, grow_on=true: `_want` is a small partial subset of the full target, never the flood.
	var ring := FacetFarRing.new()
	ring.setup(fid)
	ring._smooth = FST.new()
	ring._smooth.setup_instance(ring, null)
	ring._active_fid = fid
	ring._smooth_drive(true, true, false, false, false, true)
	var want1: int = ring._smooth._want.size()
	_ok(want1 > 0 and want1 < target.size(), "G-FS-GROW-PACE: first call under grow_on grants a partial subset of the %d-facet target (got %d) -- no flood" % [target.size(), want1])

	# (C) per-call growth is bounded: over the next many calls, `_want` never grows by more than
	# SMOOTH_GROW_PER_FRAME in any single subsequent call.
	var prev := want1
	var max_step := 0
	for i in range(400):
		ring._smooth_drive(true, true, false, false, false, true)
		var now: int = ring._smooth._want.size()
		max_step = maxi(max_step, now - prev)
		prev = now
		if now >= target.size():
			break
	_ok(max_step <= CubeSphere.SMOOTH_GROW_PER_FRAME, "G-FS-GROW-PACE: no single call ever grows _want by more than SMOOTH_GROW_PER_FRAME(%d) (observed max step %d)" % [CubeSphere.SMOOTH_GROW_PER_FRAME, max_step])

	# (D) the grow eventually reaches the FULL target -- never stalls.
	var budget := target.size() * 4 + 200
	var calls := 0
	while ring._smooth._want.size() < target.size() and calls < budget:
		ring._smooth_drive(true, true, false, false, false, true)
		calls += 1
	_ok(ring._smooth._want.size() == target.size(), "G-FS-GROW-PACE: the gradual grow reaches the FULL %d-facet target within a bounded number of calls (got %d after %d extra calls)" % [target.size(), ring._smooth._want.size(), calls])

	# (E) drive FacetSmoothTier.step() to REAL settle (worker builds actually commit against the fully-grown want),
	# then confirm ZERO further request()/_snap_plan rebuilds while stationary -- composes with FP_SMOOTH_IDLE
	# (mirrors G-FS-QUIESCE's driver check) -- the grow-pace queue neither blocks nor re-triggers the idle latch.
	var settle_iters := 0
	while settle_iters < 20000 and not ring._smooth.is_settled():
		ring._smooth_drive(true, true, false, false, false, true)
		settle_iters += 1
	_ok(ring._smooth.is_settled(), "G-FS-GROW-PACE warm-up: the fully-grown target actually converges to REAL committed tiles (%d iterations)" % settle_iters)
	var req_after_grow: int = ring._smooth.request_rebuild_count()
	for i in range(300):
		ring._smooth_drive(true, true, false, false, false, true)
	_ok(ring._smooth.request_rebuild_count() == req_after_grow, "G-FS-GROW-PACE: ZERO further request() rebuilds over 300 settled frames once fully grown + stationary (idle latch holds, %d -> %d)" % [req_after_grow, ring._smooth.request_rebuild_count()])
	_ok(ring._smooth.is_settled(), "G-FS-GROW-PACE: FacetSmoothTier stays settled at rest post-grow")
	ring.free()

	# (F) ring-1 fast path: active's direct (non-backstop) seam neighbours are granted on the VERY FIRST call, never
	# waiting on the pacing queue.
	var ring_fast := FacetFarRing.new()
	ring_fast.setup(fid)
	var ring1: Array = ring_fast._smooth_ring1_fids(fid)
	_ok(ring1.size() > 0, "G-FS-GROW-PACE: fixture has a non-empty ring-1 (non-vacuous fast-path check)")
	ring_fast._smooth = FST.new()
	ring_fast._smooth.setup_instance(ring_fast, null)
	ring_fast._active_fid = fid
	ring_fast._smooth_drive(true, true, false, false, false, true)
	var all_ring1_in := true
	for f in ring1:
		if not ring_fast._smooth._want.has(int(f)):
			all_ring1_in = false
	_ok(all_ring1_in, "G-FS-GROW-PACE: every ring-1 (active's direct seam-neighbour) facet is granted on the VERY FIRST call -- the near<->far seam is covered promptly, never paced")
	ring_fast.free()

## G-CSB-EQ (REVISION 6, FP_CPP_SMOOTH_BAKE): the native VoxelGeneratorCosmos.bake_smooth_tile() is bit-equal to
## FarDensity.node_at, FIELD FOR FIELD, over every tier of the ladder. build_tile/build_tile_rim read the baked
## arrays VERBATIM, so this node-level equality IS the whole proof: an identical mesh follows by construction.
## Falsified two ways (rotated corner order diverges; cells+1 changes the grid) + the refusal contract. Runs
## flag-independent (calls the method directly with an explicit gen — never the CubeSphere const, which is a
## compile-time literal). Needs the built module: a clear FAIL if bake_smooth_tile is absent.
func _gate_cpp_smooth_bake(fid: int) -> void:
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		_ok(false, "G-CSB-EQ[fid%d]: VoxelGeneratorCosmos module ABSENT — the native bake cannot be gated (rebuild the module engine with patch 0012)" % fid)
		return
	var gen: Object = FSK._build_cpp_gen(fid)
	_ok(gen != null, "G-CSB-EQ[fid%d]: native generator built + setup" % fid)
	if gen == null:
		return
	_ok(gen.has_method("bake_smooth_tile"), "G-CSB-EQ[fid%d]: generator exposes bake_smooth_tile (patch 0012 present)" % fid)
	if not gen.has_method("bake_smooth_tile"):
		return
	var corner_dirs := FA.facet_corner_dirs(fid)
	var r_datum := FA.r_of(fid)
	for tier in [FST.S2, FST.S3, FST.S4, FST.S5]:
		_cmp_bake_tier(gen, fid, corner_dirs, r_datum, FST.cells_for_tier(tier), tier)
	# Falsify 1: a rotated corner order must DIVERGE somewhere (the equality check is discriminating, not vacuous).
	var rot := PackedFloat64Array([
		corner_dirs[3], corner_dirs[4], corner_dirs[5], corner_dirs[6], corner_dirs[7], corner_dirs[8],
		corner_dirs[9], corner_dirs[10], corner_dirs[11], corner_dirs[0], corner_dirs[1], corner_dirs[2]])
	var cells5 := FST.cells_for_tier(FST.S5)
	var stride5 := cells5 + 1
	var brot: Dictionary = gen.call("bake_smooth_tile", rot, r_datum, cells5)
	var br_dir: PackedVector3Array = brot["dir"]
	var diff := false
	var inv5 := 1.0 / float(cells5)
	for gj in range(stride5):
		for gi in range(stride5):
			var node := FD.node_at(corner_dirs, r_datum, float(gi) * inv5, float(gj) * inv5)
			if br_dir[gj * stride5 + gi] != (node["dir"] as Vector3):
				diff = true
	_ok(diff, "G-CSB-EQ[fid%d falsify]: a ROTATED corner order yields a DIFFERENT bake" % fid)
	# Falsify 2: cells+1 changes the grid → (cells+2)^2 nodes (the grid law is honoured, not a fixed count).
	var bplus: Dictionary = gen.call("bake_smooth_tile", corner_dirs, r_datum, cells5 + 1)
	_ok((bplus["dir"] as PackedVector3Array).size() == (cells5 + 2) * (cells5 + 2),
		"G-CSB-EQ[fid%d falsify]: cells+1 → (cells+2)^2 grid" % fid)
	# Refusal contract (an empty dict → the caller falls back to the GDScript node_at loop).
	_ok((gen.call("bake_smooth_tile", corner_dirs, r_datum, 0) as Dictionary).is_empty(),
		"G-CSB-EQ[fid%d]: cells<=0 refuses (empty dict → node_at fallback)" % fid)
	_ok((gen.call("bake_smooth_tile", PackedFloat64Array([0.0, 0.0]), r_datum, cells5) as Dictionary).is_empty(),
		"G-CSB-EQ[fid%d]: corner_dirs.size()<12 refuses (empty dict)" % fid)

func _cmp_bake_tier(gen: Object, fid: int, corner_dirs: PackedFloat64Array, r_datum: float, cells: int, tier: int) -> void:
	var baked: Dictionary = gen.call("bake_smooth_tile", corner_dirs, r_datum, cells)
	var stride := cells + 1
	var n := stride * stride
	_ok(baked.has("dir") and (baked["dir"] as PackedVector3Array).size() == n,
		"G-CSB-EQ[t%d fid%d]: bake returns (cells+1)^2 = %d nodes" % [tier, fid, n])
	if not baked.has("dir"):
		return
	var b_dir: PackedVector3Array = baked["dir"]
	var b_g: PackedInt32Array = baked["g"]
	var b_biome: PackedInt32Array = baked["biome"]
	var b_temp: PackedFloat32Array = baked["temp"]
	var b_relief: PackedFloat32Array = baked["relief"]
	var b_pos: PackedVector3Array = baked["pos"]
	var b_planar: PackedVector3Array = baked["planar"]
	var b_bnrm: PackedVector3Array = baked["bnrm"]
	var inv := 1.0 / float(cells)
	var dir_ok := true
	var g_ok := true
	var biome_ok := true
	var temp_ok := true
	var relief_ok := true
	var pos_ok := true
	var planar_ok := true
	var bnrm_ok := true
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var vi := gj * stride + gi
			var node := FD.node_at(corner_dirs, r_datum, s, t)
			if b_dir[vi] != (node["dir"] as Vector3): dir_ok = false
			if b_g[vi] != int(node["g"]): g_ok = false
			if b_biome[vi] != int(node["biome"]): biome_ok = false
			if b_temp[vi] != float(node["temp"]): temp_ok = false
			if b_relief[vi] != float(node["relief"]): relief_ok = false
			if b_pos[vi] != (node["pos"] as Vector3): pos_ok = false
			if b_planar[vi] != (node["planar"] as Vector3): planar_ok = false
			if gi == 0 or gi == cells or gj == 0 or gj == cells:
				if b_bnrm[vi] != FD.boundary_normal(node["dir"], r_datum): bnrm_ok = false
	_ok(dir_ok, "G-CSB-EQ[t%d fid%d]: native dir == node_at dir (bit-equal, all %d nodes)" % [tier, fid, n])
	_ok(g_ok, "G-CSB-EQ[t%d fid%d]: native g == node_at g" % [tier, fid])
	_ok(biome_ok, "G-CSB-EQ[t%d fid%d]: native biome == node_at biome" % [tier, fid])
	_ok(temp_ok, "G-CSB-EQ[t%d fid%d]: native temp == node_at temp (bit-equal)" % [tier, fid])
	_ok(relief_ok, "G-CSB-EQ[t%d fid%d]: native relief == node_at relief (bit-equal)" % [tier, fid])
	_ok(pos_ok, "G-CSB-EQ[t%d fid%d]: native pos == node_at pos (bit-equal — the flat-path vertex)" % [tier, fid])
	_ok(planar_ok, "G-CSB-EQ[t%d fid%d]: native planar == node_at planar (bit-equal)" % [tier, fid])
	_ok(bnrm_ok, "G-CSB-EQ[t%d fid%d]: native boundary normal == FarDensity.boundary_normal (perimeter, bit-equal)" % [tier, fid])

## G-CSB-EQ-WELD (law-2 survival): two facets sharing a CROSS-FACE edge, BOTH baked through the NATIVE path, weld
## on their shared boundary vertices (≤1e-9·R). bake_smooth_tile is a pure function of the canon corner dirs and
## G-FS-CANON proves both facets pass the SAME canon dirs on the shared edge, so the native boundary nodes weld
## exactly as node_at's do (which G-FS-WELD-EDGE already passes at this tolerance). Nearest-match, order-agnostic.
func _gate_cpp_smooth_bake_weld(fid: int, slot: int) -> void:
	if not ClassDB.class_exists("VoxelGeneratorCosmos"):
		return   # the ABSENT case is already FAIL-reported by _gate_cpp_smooth_bake
	var gen: Object = FSK._build_cpp_gen(fid)
	if gen == null or not gen.has_method("bake_smooth_tile"):
		return
	var nb := FA.seam_neighbour(fid, slot)
	var cells := FST.cells_for_tier(FST.S4)
	var stride := cells + 1
	var ba: Dictionary = gen.call("bake_smooth_tile", FA.facet_corner_dirs(fid), FA.r_of(fid), cells)
	var bb: Dictionary = gen.call("bake_smooth_tile", FA.facet_corner_dirs(nb), FA.r_of(nb), cells)
	if not (ba.has("pos") and bb.has("pos")):
		_ok(false, "G-CSB-EQ-WELD: native bake produced pos arrays for both facets")
		return
	var pa: PackedVector3Array = ba["pos"]
	var pb: PackedVector3Array = bb["pos"]
	var edge_a := _edge_indices(slot, cells, stride)
	var nb_boundary := _all_boundary_indices(cells, stride)
	var cross_face := _face_of(nb) != _face_of(fid)
	var eps := (1.0e-9 * FA.R_BLOCKS) if cross_face else 0.0
	var weld_ok := true
	var max_gap := 0.0
	for ia in edge_a:
		var va: Vector3 = pa[ia]
		var best := 1.0e30
		for ib in nb_boundary:
			var d: float = va.distance_to(pb[ib])
			if d < best:
				best = d
		max_gap = maxf(max_gap, best)
		if best > eps:
			weld_ok = false
	_ok(cross_face, "G-CSB-EQ-WELD: fixture slot %d neighbour (fid %d) is a CROSS-FACE pair" % [slot, nb])
	_ok(weld_ok, "G-CSB-EQ-WELD: every native shared-edge vertex welds to the neighbour's native bake (≤1e-9·R, max gap %.3e)" % max_gap)

## G-RNW-STEP / G-RNW-NOPOKE (REVISION 7-VISUAL §R7.5, FP_RIM_NEAR_WELD): the S2 collar's VISIBLE annulus
## [r_near .. r_env] must weld to the near block-top (true − ε) instead of the shipped env−sink, so the near
## cut-edge wall collapses to ≤ ε. Uses the LIVE r_near/r_env (128/160) so the fixture exercises the exact band
## the user sees. FALSIFY: the SAME probe on the shipped law (weld off) reports the multi-block wall (≥4) — proves
## the gate can see the defect. NOPOKE: welded rim never rises above its column's near top (no z-fight).
func _gate_rim_near_weld(fid: int) -> void:
	print("  --- G-RNW-STEP: S2 near-collar visible annulus welds to the near block-top (no exposed height wall) ---")
	var cells := FST.cells_for_tier(FST.S2)
	var stride := cells + 1
	var r_datum := FA.r_of(fid)
	var corner_dirs := FA.facet_corner_dirs(fid)
	var centre_node := FD.node_at(corner_dirs, r_datum, 0.5, 0.5)
	var player_col: Vector3 = centre_node["pos"]
	var r_env := float(TC.near_render_radius()) + CubeSphere.RIM_STREAM_MARGIN   # 160 — the live disc radius
	var r_near := float(TC.near_render_radius())                                 # 128 — near coverage edge
	var feather := CubeSphere.RIM_FEATHER_BLOCKS
	var sink := TierPlace.backstop_sink()
	var inv := 1.0 / float(cells)
	# weld ON vs the shipped law (weld off), identical inputs, initial full bake (no cache).
	var weld := FST.build_tile_rim(fid, cells, player_col, r_env, feather, sink, false, -1.0, false, PackedVector3Array(), {}, Vector3.ZERO, null, true, r_near)
	var ship := FST.build_tile_rim(fid, cells, player_col, r_env, feather, sink, false, -1.0, false, PackedVector3Array(), {}, Vector3.ZERO, null, false, r_near)
	var wpos: PackedVector3Array = weld["pos"]
	var spos: PackedVector3Array = ship["pos"]
	var samples := 0
	var worst_weld_drop := 0.0
	var worst_protrude := -1.0e30
	var worst_ship_drop := 0.0
	for gj in range(stride):
		var t := float(gj) * inv
		for gi in range(stride):
			var s := float(gi) * inv
			var node := FD.node_at(corner_dirs, r_datum, s, t)
			var d: Vector3 = node["dir"]
			var true_pos: Vector3 = node["pos"]
			var dist := true_pos.distance_to(player_col)
			if dist < r_near or dist > r_env:
				continue          # only the VISIBLE annulus (near edge .. disc frontier)
			samples += 1
			var vi := gj * stride + gi
			var true_relief := float(node["relief"])
			var weld_relief := (wpos[vi] - d * r_datum).dot(d)
			worst_weld_drop = maxf(worst_weld_drop, true_relief - weld_relief)          # below near top (want ≤ ε)
			worst_protrude = maxf(worst_protrude, weld_relief - true_relief)             # above near top (want ≤ 0)
			var ship_relief := (spos[vi] - d * r_datum).dot(d)
			worst_ship_drop = maxf(worst_ship_drop, true_relief - ship_relief)           # the shipped wall
	_ok(samples >= 100, "G-RNW-STEP: %d S2 nodes fall in the visible annulus [%.0f..%.0f] (fixture exercises the wall band)" % [samples, r_near, r_env])
	_ok(worst_weld_drop <= CubeSphere.RIM_WELD_EPS + 1.0 + 1.0e-3, "G-RNW-STEP: welded rim sits ≤ ε+1 below the near block-top across the annulus (worst drop %.2f ≤ %.2f) — no exposed wall" % [worst_weld_drop, CubeSphere.RIM_WELD_EPS + 1.0])
	_ok(worst_protrude <= 1.0e-3, "G-RNW-NOPOKE: welded rim never rises above its column's near block-top (worst protrusion %.4f) — no z-fight/poke-through" % worst_protrude)
	_ok(worst_ship_drop >= 4.0, "G-RNW-STEP[falsify]: the SHIPPED env−sink law shows a ≥4-block drop in the SAME annulus (worst %.2f) — the gate sees the wall the user reported" % worst_ship_drop)


# =====================================================================================================================
# REVISION 7 (docs/COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md "REVISION 7") — FP_SMOOTH_SLOT_MESH gates. Every helper
# below drives a bare `FacetSmoothTier` (mirrors `_run_nohole_churn`/`_gate_fs_txn_thread`'s existing style) and
# forces `slot_on`/`budget_bytes` PER-CALL via the new trailing params on `step()`/`request()`/`_evict()` — never
# the `CubeSphere.FP_SMOOTH_SLOT_MESH` const itself (that stays sed-only, matching every other REVISION 3+ flag
# here). HEADLESS LIMIT (all three gates): the dummy RenderingServer's `mesh_surface_update_vertex_region`/
# `_attribute_region` are no-ops (no real GPU) — these gates prove the PACKING bytes, the OFFSET/slot math, the
# refusal latch, and the commit-event SCHEDULING are all correct; they cannot observe the actual uploaded pixels.
# =====================================================================================================================

## Mirrors `_simulate_tier_commit` (the existing REVISION 3 direct-poke helper) but additionally routes the
## transition through the REVISION 7 slot-mesh hooks (`_evict`'s slot-free + `_slot_commit_fid` + `_slot_flush_event`)
## exactly the way `step()`'s own reap loop does — so a gate can inject a tier-swap/refresh WITHOUT waiting on the
## real WorkerThreadPool build, while still exercising the real slot bookkeeping (not a shortcut around it).
func _simulate_tier_commit_slot(ft: FacetSmoothTier, fid: int, new_tier: int, tile: Dictionary, slot_on: bool) -> void:
	if ft._tiles.has(fid):
		if int(ft._tier_of[fid]) != new_tier:
			ft._evict(fid, slot_on)
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
	if slot_on and not ft._slot_mesh_failed:
		ft._slot_commit_fid(new_tier, fid, tile)
	ft._slot_flush_event()

## G-SLOT-EQ: the slot path's PER-TILE pack (what `_slot_commit_fid` blits into a slot) is byte-equal to that same
## tile's own byte range within the SHIPPED whole-tier concatenation (`_rebuild_tier_mesh`'s append order), packed
## through the identical engine packer. This is the enabling REVISION 7 property made concrete: every tile of a
## tier shares identical topology, so per-vertex packing (no cross-vertex coupling for our uncompressed flags=0
## format: VERTEX/NORMAL/COLOR/TEX_UV/TEX_UV2) commutes with "pack alone" vs. "pack as part of a bigger concat".
## FALSIFY: corrupting one tile's own data changes ITS packed bytes vs. the (uncorrupted) shipped reference slice —
## proves the comparison has real teeth, not a vacuous self-agreement.
func _gate_slot_eq() -> void:
	print("  --- REVISION 7 G-SLOT-EQ: slot-packed tile bytes == the shipped whole-tier packed bytes for the SAME tile (headless: packing/offset math only — see the file-header note on the dummy RS) ---")
	var tier := FST.S4
	var cells := FST.cells_for_tier(tier)
	var fid_a := _fid_of(2, 4, 4)
	var fid_b := _fid_of(2, 4, 5)   # a second, distinct tile — proves the slice-out-of-a-bigger-blob math, not just a 1-tile trivial case
	var tile_a := FST.build_tile(fid_a, cells, 0.0, true, false, -1.0)
	FST.append_skirt(tile_a, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
	var tile_b := FST.build_tile(fid_b, cells, 0.0, true, false, -1.0)
	FST.append_skirt(tile_b, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)

	# (A) the SLOT path's own per-tile pack — exactly what `_slot_commit_fid` would blit for each tile individually.
	var sd_a := FST._pack_tile_bytes(tile_a)
	var sd_b := FST._pack_tile_bytes(tile_b)
	_ok(sd_a.has("vertex_data") and sd_b.has("vertex_data"), "G-SLOT-EQ: both tiles pack cleanly (engine-side, no hand-rolled format)")

	# (B) the SHIPPED whole-tier concatenation (mirrors `_rebuild_tier_mesh`'s own append-with-index-offset loop),
	# packed as ONE surface — the reference this gate compares against.
	var P := PackedVector3Array(); var N := PackedVector3Array(); var C := PackedColorArray()
	var U := PackedVector2Array(); var U2 := PackedVector2Array(); var I := PackedInt32Array()
	for t in [tile_a, tile_b]:
		var base := P.size()
		P.append_array(t["pos"]); N.append_array(t["nrm"]); C.append_array(t["col"])
		U.append_array(t["uv"]); U2.append_array(t["uv2"])
		for idx in (t["idx"] as PackedInt32Array):
			I.append(base + idx)
	var shipped := {"pos": P, "nrm": N, "col": C, "uv": U, "uv2": U2, "idx": I}
	var sd_shipped := FST._pack_tile_bytes(shipped)
	_ok(sd_shipped.has("vertex_data"), "G-SLOT-EQ: the shipped whole-tier concatenation packs the same way")

	var format_match := int(sd_a.get("format", -1)) == int(sd_shipped.get("format", -2))
	_ok(format_match, "G-SLOT-EQ: per-tile pack format == whole-tier pack format (same array set + flags=0 ⇒ a slot's capacity surface can host either)")

	var vcount_shipped := int(sd_shipped.get("vertex_count", 0))
	# The "vertex_data" buffer is STRUCT-OF-ARRAYS, not one interleaved per-vertex row (confirmed in the engine
	# source, `mesh_surface_make_offsets_from_format`: the `+= r_vertex_element_size * p_vertex_len` offset bump
	# applies ONLY to ARRAY_NORMAL/ARRAY_TANGENT) — ALL positions come first (`total_verts * pos_stride` bytes),
	# THEN all normal+tangent data (`total_verts * nt_stride` bytes). A tile's OWN packed bytes are therefore two
	# separate sub-blocks too, and comparing against the shipped buffer means slicing EACH sub-block out of its
	# OWN region of the bigger buffer — never one contiguous "tile N's bytes" range. Mirrors
	# `FacetSmoothTier._ensure_slot_capacity`/`_slot_commit_fid`'s own split exactly.
	var pstride := int(RenderingServer.mesh_surface_get_format_vertex_stride(int(sd_shipped["format"]), vcount_shipped))
	var ntstride := int(RenderingServer.mesh_surface_get_format_normal_tangent_stride(int(sd_shipped["format"]), vcount_shipped))
	var n_a: int = (tile_a["pos"] as PackedVector3Array).size()
	var n_b: int = (tile_b["pos"] as PackedVector3Array).size()
	_ok(vcount_shipped == n_a + n_b, "G-SLOT-EQ: the shipped pack's vertex_count == tile A + tile B vertex counts (non-vacuous sizing, %d == %d+%d)" % [vcount_shipped, n_a, n_b])

	var vtx_shipped: PackedByteArray = sd_shipped["vertex_data"]
	var vtx_a: PackedByteArray = sd_a["vertex_data"]
	var vtx_b: PackedByteArray = sd_b["vertex_data"]
	# Position sub-block: contiguous [0, (n_a+n_b)*pstride) at the FRONT of the buffer.
	var pos_slice_a := vtx_shipped.slice(0, n_a * pstride)
	var pos_slice_b := vtx_shipped.slice(n_a * pstride, (n_a + n_b) * pstride)
	# Normal+tangent sub-block: contiguous [(n_a+n_b)*pstride, (n_a+n_b)*(pstride+ntstride)) at the BACK.
	var nt_base := (n_a + n_b) * pstride
	var nt_slice_a := vtx_shipped.slice(nt_base, nt_base + n_a * ntstride)
	var nt_slice_b := vtx_shipped.slice(nt_base + n_a * ntstride, nt_base + (n_a + n_b) * ntstride)
	# Tile A/B's OWN packed buffers carry the SAME two-sub-block shape at their own (smaller) vertex count.
	var pos_a := vtx_a.slice(0, n_a * pstride)
	var nt_a := vtx_a.slice(n_a * pstride, n_a * (pstride + ntstride))
	var pos_b := vtx_b.slice(0, n_b * pstride)
	var nt_b := vtx_b.slice(n_b * pstride, n_b * (pstride + ntstride))
	_ok(pos_slice_a.size() == pos_a.size() and pos_slice_a == pos_a, "G-SLOT-EQ: tile A's slot-packed POSITION sub-block is BYTE-EQUAL to its slice of the shipped whole-tier position sub-block")
	_ok(nt_slice_a.size() == nt_a.size() and nt_slice_a == nt_a, "G-SLOT-EQ: tile A's slot-packed NORMAL+TANGENT sub-block is BYTE-EQUAL to its slice of the shipped whole-tier normal+tangent sub-block")
	_ok(pos_slice_b.size() == pos_b.size() and pos_slice_b == pos_b, "G-SLOT-EQ: tile B's slot-packed POSITION sub-block is BYTE-EQUAL to its slice of the shipped whole-tier position sub-block")
	_ok(nt_slice_b.size() == nt_b.size() and nt_slice_b == nt_b, "G-SLOT-EQ: tile B's slot-packed NORMAL+TANGENT sub-block is BYTE-EQUAL to its slice of the shipped whole-tier normal+tangent sub-block")

	# --- FALSIFY: corrupt tile B's data and prove the comparison NOW differs (not a vacuous always-equal pass) ---
	var tile_b_bad := tile_b.duplicate(true)
	var pos_bad: PackedVector3Array = tile_b_bad["pos"]
	pos_bad[0] = pos_bad[0] + Vector3(37.0, 0.0, 0.0)   # a real, detectable corruption — not rounding noise
	tile_b_bad["pos"] = pos_bad
	var sd_b_bad := FST._pack_tile_bytes(tile_b_bad)
	var vtx_b_bad: PackedByteArray = sd_b_bad.get("vertex_data", PackedByteArray())
	var pos_b_bad := vtx_b_bad.slice(0, n_b * pstride) if vtx_b_bad.size() >= n_b * pstride else PackedByteArray()
	_ok(pos_b_bad.size() == 0 or pos_b_bad != pos_slice_b, "G-SLOT-EQ-FALSIFY: corrupting tile B's own position data changes its packed POSITION bytes vs. the (uncorrupted) shipped slice — the byte-equal check has teeth")

## G-SLOT-NOHOLE: replay the R3.2.a promote scenario THROUGH THE SLOT PATH — a tier-change swap (fid_a S4->S5,
## fid_b S5->S4, same 2 tiers, compound) plus an in-place refresh (fid_c, same tier) — and assert
## `committed_fids_snapshot()` never shows a resident fid in 0 tiers (a hole) or ≥2 tiers (a z-fight) across the
## whole churn. LAW T: the old-tier zero-blit and the new-tier write of ONE promote are staged into the SAME
## `_slot_cur_event` (by `_evict`'s slot-free then `step()`'s `_slot_commit_fid`, both before the `_slot_flush_event`
## that ends this fid's reap-loop iteration) and therefore always land in the SAME applied drain — never split.
func _run_nohole_churn_slot() -> Dictionary:
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var fid_a := _fid_of(3, 6, 9)
	var fid_b := _fid_of(3, 6, 10)
	var fid_c := _fid_of(3, 6, 11)

	# Initial population (converged first — the churn below must be a real TRANSITION, not the initial-ramp gap).
	var t_a0 := FST.build_tile(fid_a, FST.cells_for_tier(FST.S4), 0.0, true, false, -1.0)
	FST.append_skirt(t_a0, FST.cells_for_tier(FST.S4), CubeSphere.SMOOTH_SKIRT_BLOCKS)
	var t_b0 := FST.build_tile(fid_b, FST.cells_for_tier(FST.S5), 0.0, true, false, -1.0)
	FST.append_skirt(t_b0, FST.cells_for_tier(FST.S5), CubeSphere.SMOOTH_SKIRT_BLOCKS)
	var t_c0 := FST.build_tile(fid_c, FST.cells_for_tier(FST.S3), 0.0, true, false, -1.0)
	FST.append_skirt(t_c0, FST.cells_for_tier(FST.S3), CubeSphere.SMOOTH_SKIRT_BLOCKS)
	_simulate_tier_commit_slot(ft, fid_a, FST.S4, t_a0, true)
	_simulate_tier_commit_slot(ft, fid_b, FST.S5, t_b0, true)
	_simulate_tier_commit_slot(ft, fid_c, FST.S3, t_c0, true)
	for i in range(10):
		ft.step(false, false, false, true)   # drain any budget-deferred backlog from the initial population

	var warm_ok := not ft._slot_mesh_failed and ft.is_resident(fid_a) and ft.is_resident(fid_b) and ft.is_resident(fid_c)
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
	FST.append_skirt(tile_a, FST.cells_for_tier(FST.S5), CubeSphere.SMOOTH_SKIRT_BLOCKS)
	var tile_b := FST.build_tile(fid_b, FST.cells_for_tier(FST.S4), 0.0, true, false, -1.0)
	FST.append_skirt(tile_b, FST.cells_for_tier(FST.S4), CubeSphere.SMOOTH_SKIRT_BLOCKS)
	var tile_c := FST.build_tile(fid_c, FST.cells_for_tier(FST.S3), 0.0, true, false, -1.0)
	FST.append_skirt(tile_c, FST.cells_for_tier(FST.S3), CubeSphere.SMOOTH_SKIRT_BLOCKS)
	_simulate_tier_commit_slot(ft, fid_a, FST.S5, tile_a, true)
	_simulate_tier_commit_slot(ft, fid_b, FST.S4, tile_b, true)
	_simulate_tier_commit_slot(ft, fid_c, FST.S3, tile_c, true)

	var hole := false
	var zfight := false
	var steps := 0
	for i in range(50):
		ft.step(false, false, false, true)
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

	var refused := ft._slot_mesh_failed
	parent.free()
	return {"warm_ok": warm_ok, "hole": hole, "zfight": zfight, "steps": steps, "refused": refused}

func _gate_slot_nohole() -> void:
	print("  --- REVISION 7 G-SLOT-NOHOLE: a promote's old-slot-zero + new-slot-write land in the SAME step() call — no hole, no z-fight (headless: CPU/queue-level atomicity + committed_fids bookkeeping, not GPU pixels) ---")
	var r := _run_nohole_churn_slot()
	_ok(not bool(r["refused"]), "G-SLOT-NOHOLE: the slot path never hit the refusal latch on this scenario (packing/format validated clean end-to-end, headless)")
	_ok(bool(r["warm_ok"]), "G-SLOT-NOHOLE warm-up: initial population converges to exactly-one-committed-tier coverage per facet (non-vacuous baseline)")
	_ok(int(r["steps"]) > 0, "G-SLOT-NOHOLE: drove %d churn steps (compound promote+demote+refresh through the slot path)" % int(r["steps"]))
	_ok(not bool(r["hole"]), "G-SLOT-NOHOLE: NEVER a step where a resident facet is committed into ZERO tiers (no hole)")
	_ok(not bool(r["zfight"]), "G-SLOT-NOHOLE: NEVER a step where a resident facet is committed into TWO tiers at once (no z-fight)")

## G-SLOT-BUDGET: 4 independent whole commit-events queued before any drain; a budget sized for exactly ONE event's
## bytes applies exactly 1 per `step()` call, deferring the other 3 WHOLE (never a partial tile — the deferred
## count is always an INTEGER number of events, and the queue drains in exactly the remaining calls, proving no
## event was ever split or skipped). FALSIFY: a budget covering all 4 events applies them ALL in a single call —
## proves the small-budget deferral above is the BUDGET's doing, not some unrelated fixed per-call cap.
func _gate_slot_budget() -> void:
	print("  --- REVISION 7 G-SLOT-BUDGET: a multi-event commit exceeding the byte budget defers the OVERFLOW as WHOLE events, never a partial tile ---")
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var tier := FST.S4
	var cells := FST.cells_for_tier(tier)
	var fids := []
	for i in range(4):
		fids.append(_fid_of(1, 2, i))
	for fid in fids:
		var tile := FST.build_tile(fid, cells, 0.0, true, false, -1.0)
		FST.append_skirt(tile, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
		_simulate_tier_commit_slot(ft, fid, tier, tile, true)   # queue 4 independent whole events, nothing drained yet
	_ok(not ft._slot_mesh_failed, "G-SLOT-BUDGET setup: 4 independent commits packed clean (no refusal)")
	_ok((ft._slot_write_queue as Array).size() == 4, "G-SLOT-BUDGET setup: 4 queued whole commit-events, one per fid (non-vacuous — nothing auto-drained yet)")
	var per_event_bytes := 0
	var ev0: Array = ft._slot_write_queue[0]
	for w in ev0:
		var d: Dictionary = w
		per_event_bytes += (d["vtx_pos"] as PackedByteArray).size() + (d["vtx_nt"] as PackedByteArray).size() + (d.get("attr", PackedByteArray()) as PackedByteArray).size()
	_ok(per_event_bytes > 0, "G-SLOT-BUDGET setup: a single commit-event carries real packed bytes (%d)" % per_event_bytes)

	# --- (A) budget == exactly one event's size: 1 of 4 applies this call, 3 remain queued WHOLE ---
	ft.step(false, false, false, true, per_event_bytes)
	_ok(int(ft.slot_mesh_stats()["smooth_commit_defer"]) == 3, "G-SLOT-BUDGET: with budget == one event's size, exactly 1 of 4 events applied this step() — 3 deferred WHOLE (never 3.x partially-applied tiles)")

	# --- drain the rest: each subsequent 1-event-budget call frees exactly one more queued event ---
	var calls := 0
	while (ft._slot_write_queue as Array).size() > 0 and calls < 10:
		ft.step(false, false, false, true, per_event_bytes)
		calls += 1
	_ok((ft._slot_write_queue as Array).size() == 0, "G-SLOT-BUDGET: the backlog fully drains (%d further step() calls at a 1-event budget)" % calls)
	_ok(calls == 3, "G-SLOT-BUDGET: drained in EXACTLY the remaining 3 calls (4 events total, 1 already applied, 1/call thereafter) — no event split, none skipped")

	# --- FALSIFY: a budget covering all 4 events applies them ALL in ONE call (proves the small-budget deferral above is the BUDGET's doing) ---
	var ft2 := FST.new()
	ft2.setup_instance(parent, null)
	for fid in fids:
		var tile := FST.build_tile(fid, cells, 0.0, true, false, -1.0)
		FST.append_skirt(tile, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
		_simulate_tier_commit_slot(ft2, fid, tier, tile, true)
	ft2.step(false, false, false, true, per_event_bytes * 4 + 1)
	_ok((ft2._slot_write_queue as Array).is_empty(), "G-SLOT-BUDGET-FALSIFY: a budget covering all 4 events' bytes applies them ALL in one step() call (0 remaining) — the small-budget deferral above isn't a vacuous fixed per-call cap")
	parent.free()

# =====================================================================================================================
# FP_SMOOTH_TILE_SURF (SAFE replacement for FP_SMOOTH_SLOT_MESH — that path's RenderingServer region-write calls
# HARD-CRASHED the live web tab; see cube_sphere.gd's doc comment). Per-tile phase: each committed tile gets its OWN
# child MeshInstance3D under `_mi[tier]` (O(1) upload). Consolidate-at-settle: a tier unchanged for
# SMOOTH_TILE_CONSOLIDATE_FRAMES `step()` calls folds back into ONE merged mesh + frees its per-tile nodes. HEADLESS
# NOTE (unlike the slot-mesh gates above): this uses ONLY high-level MeshInstance3D/ArrayMesh — node tree membership,
# surface counts, and `.mesh` assignment are all REAL even on the dummy headless RenderingServer (only actual GPU
# pixels aren't), so these gates validate node counts, the merged-XOR-per-tile invariant, and consolidation timing
# directly — not just packing/offset math. Live-only unknown: steady-state fps/draw-call cost of the per-tile phase.
# =====================================================================================================================

## Mirrors `_simulate_tier_commit`/`_simulate_tier_commit_slot` (the existing direct-poke helpers) but routes the
## transition through the FP_SMOOTH_TILE_SURF hooks (`_evict(..., true)` + `_tile_surf_touch`) exactly the way
## `step()`'s own reap loop does — so a gate can inject a tier-swap/first-commit/refresh without waiting on the real
## WorkerThreadPool build, while still exercising the REAL per-tile-node bookkeeping (not a shortcut around it).
func _simulate_tier_commit_tile_surf(ft: FacetSmoothTier, fid: int, new_tier: int, tile: Dictionary) -> void:
	if ft._tiles.has(fid):
		if int(ft._tier_of[fid]) != new_tier:
			ft._evict(fid, false, true)   # tile_surf_on path: drops the OLD tier's per-tile node (or triggers its re-split)
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
	ft._tile_surf_touch(new_tier, fid, false)   # mirrors step()'s reap-loop commit branch under tile_surf_on

## The merged-XOR-per-tile invariant, checked directly against live instance state: `tier` must NEVER be drawing via
## BOTH its merged `_mi[tier].mesh` (non-empty) AND >=1 per-tile `_tile_mi` node at once (a double-draw / z-fight).
func _tile_surf_invariant_ok(ft: FacetSmoothTier, tier: int) -> bool:
	var mi: MeshInstance3D = ft._mi[tier]
	var merged_nonempty := mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0
	var per_tile_count := 0
	for fid in (ft._tile_mi as Dictionary).keys():
		if int(ft._tier_of.get(fid, -1)) == tier:
			per_tile_count += 1
	return not (merged_nonempty and per_tile_count > 0)

## G-TILESURF-COVER: after committing a set of tiles under the flag, the per-tile node count for that tier == its
## resident count (every resident tile is drawn exactly once, as a node) — and an evicted fid's node disappears
## (count drops), never leaking a stale draw.
func _gate_tilesurf_cover() -> void:
	print("  --- FP_SMOOTH_TILE_SURF G-TILESURF-COVER: per-tile node count == tier resident count; eviction frees the node ---")
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var tier := FST.S4
	var cells := FST.cells_for_tier(tier)
	var fids := []
	for i in range(5):
		fids.append(_fid_of(4, 1, i))
	for fid in fids:
		var tile := FST.build_tile(fid, cells, 0.0, true, false, -1.0)
		FST.append_skirt(tile, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
		_simulate_tier_commit_tile_surf(ft, fid, tier, tile)

	var resident_n := 0
	for fid in fids:
		if ft.is_resident(fid):
			resident_n += 1
	_ok(resident_n == fids.size(), "G-TILESURF-COVER setup: all %d committed tiles are resident (non-vacuous)" % fids.size())

	var node_count := 0
	for fid in (ft._tile_mi as Dictionary).keys():
		if int(ft._tier_of.get(fid, -1)) == tier:
			node_count += 1
	_ok(node_count == fids.size(), "G-TILESURF-COVER: per-tile node count (%d) == resident count (%d) for tier %d" % [node_count, fids.size(), tier])
	for fid in fids:
		_ok((ft._tile_mi as Dictionary).has(fid) and is_instance_valid(ft._tile_mi[fid]), "G-TILESURF-COVER: fid %d has its OWN valid per-tile MeshInstance3D" % fid)

	# --- FALSIFY-by-eviction: drop one fid — its node must be freed and the count must drop by exactly 1 ---
	var evicted: int = fids[0]
	ft._evict(evicted, false, true)
	_ok(not ft.is_resident(evicted), "G-TILESURF-COVER: the evicted fid is no longer resident")
	_ok(not (ft._tile_mi as Dictionary).has(evicted), "G-TILESURF-COVER: the evicted fid's per-tile node entry is gone from `_tile_mi`")
	var node_count_after := 0
	for fid in (ft._tile_mi as Dictionary).keys():
		if int(ft._tier_of.get(fid, -1)) == tier:
			node_count_after += 1
	_ok(node_count_after == fids.size() - 1, "G-TILESURF-COVER: per-tile node count dropped by exactly 1 after the eviction (%d -> %d)" % [fids.size(), node_count_after])
	parent.free()

## G-TILESURF-XOR: a tier draws its tiles EITHER via the merged mesh XOR via per-tile nodes, never both. Checked
## live through the whole per-tile-phase-then-committed flow above (never violated by construction), THEN falsified
## by deliberately forcing both representations non-empty at once — the invariant checker must catch it.
func _gate_tilesurf_xor() -> void:
	print("  --- FP_SMOOTH_TILE_SURF G-TILESURF-XOR: merged mesh XOR per-tile nodes, never both (no double-draw) ---")
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var tier := FST.S3
	var cells := FST.cells_for_tier(tier)
	var fids := []
	for i in range(3):
		fids.append(_fid_of(5, 2, i))
	for fid in fids:
		var tile := FST.build_tile(fid, cells, 0.0, true, false, -1.0)
		FST.append_skirt(tile, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
		_simulate_tier_commit_tile_surf(ft, fid, tier, tile)
	_ok(ft._tile_surf_active[tier], "G-TILESURF-XOR setup: the tier is in the per-tile (split) phase after 3 fresh commits")
	_ok(_tile_surf_invariant_ok(ft, tier), "G-TILESURF-XOR: per-tile phase — merged mesh is null/empty, per-tile nodes carry the draw (invariant holds)")

	# Consolidate it (folds to ONE merged mesh + frees the per-tile nodes) and re-check.
	ft._tile_surf_consolidate(tier)
	_ok(not ft._tile_surf_active[tier], "G-TILESURF-XOR: consolidation flips the tier out of the split phase")
	var mi: MeshInstance3D = ft._mi[tier]
	_ok(mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0, "G-TILESURF-XOR: the consolidated merged mesh actually carries geometry (non-vacuous)")
	_ok(_tile_surf_invariant_ok(ft, tier), "G-TILESURF-XOR: consolidated phase — per-tile nodes are gone, merged mesh carries the draw (invariant still holds)")

	# --- FALSIFY: deliberately break the invariant (force BOTH representations non-empty) and prove the checker catches it ---
	var bad_fid: int = fids[0]
	ft._tile_surf_set_node(tier, bad_fid)   # re-creates a per-tile node WITHOUT clearing the merged mesh first
	_ok(not _tile_surf_invariant_ok(ft, tier), "G-TILESURF-XOR-FALSIFY: a deliberately-broken state (merged mesh non-empty AND a per-tile node present) IS flagged by the invariant checker — it has teeth")
	parent.free()

## G-TILESURF-CONSOLIDATE: a tier stays in the per-tile (split) phase for as long as it keeps getting touched, and
## only folds to the merged mesh (0 per-tile nodes) once `SMOOTH_TILE_CONSOLIDATE_FRAMES` step() calls pass with NO
## further add/evict. FALSIFY: one call short of the threshold, it must still be split.
func _gate_tilesurf_consolidate() -> void:
	print("  --- FP_SMOOTH_TILE_SURF G-TILESURF-CONSOLIDATE: settle-consolidate folds per-tile nodes back to ONE merged mesh after the stable-frame threshold ---")
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var tier := FST.S5
	var cells := FST.cells_for_tier(tier)
	var fids := []
	for i in range(4):
		fids.append(_fid_of(2, 3, i))
	for fid in fids:
		var tile := FST.build_tile(fid, cells, 0.0, true, false, -1.0)
		FST.append_skirt(tile, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
		_simulate_tier_commit_tile_surf(ft, fid, tier, tile)
	_ok(ft._tile_surf_active[tier], "G-TILESURF-CONSOLIDATE setup: the tier starts split (per-tile phase) right after the commits")

	var threshold := int(CubeSphere.SMOOTH_TILE_CONSOLIDATE_FRAMES)
	# One call short of the threshold: still split (never consolidates early).
	for i in range(threshold - 1):
		ft.step(false, false, false, false, CubeSphere.SMOOTH_COMMIT_BUDGET_BYTES, true)
	_ok(ft._tile_surf_active[tier], "G-TILESURF-CONSOLIDATE-FALSIFY: %d calls (one short of the %d-call threshold) — tier is STILL split, not consolidated early" % [threshold - 1, threshold])
	var still_nodes := 0
	for fid in fids:
		if (ft._tile_mi as Dictionary).has(fid):
			still_nodes += 1
	_ok(still_nodes == fids.size(), "G-TILESURF-CONSOLIDATE-FALSIFY: all %d per-tile nodes are still present one call short of the threshold" % fids.size())

	# The one more call that crosses the threshold: folds to the merged mesh, frees every per-tile node.
	ft.step(false, false, false, false, CubeSphere.SMOOTH_COMMIT_BUDGET_BYTES, true)
	_ok(not ft._tile_surf_active[tier], "G-TILESURF-CONSOLIDATE: at the threshold, the tier folds OUT of the split phase")
	var nodes_after := 0
	for fid in fids:
		if (ft._tile_mi as Dictionary).has(fid):
			nodes_after += 1
	_ok(nodes_after == 0, "G-TILESURF-CONSOLIDATE: 0 per-tile nodes remain for this tier after consolidation (%d freed)" % fids.size())
	var mi: MeshInstance3D = ft._mi[tier]
	_ok(mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0, "G-TILESURF-CONSOLIDATE: the folded merged mesh carries real geometry (non-vacuous — all %d tiles' worth)" % fids.size())
	_ok(_tile_surf_invariant_ok(ft, tier), "G-TILESURF-CONSOLIDATE: merged-XOR-per-tile invariant holds post-consolidation")
	parent.free()

## G-TILESURF-OFF: with the flag off (the shipped default args — no gate ever forces `tile_surf_on` true on these
## call sites), the per-tile path never runs at all: a normal commit/evict/step() cycle leaves `_tile_mi` completely
## empty and `tile_surf_stats()` reports the path never fired — byte-identical to the pre-existing behaviour (the
## OTHER G-FS-*/G-SLOT-* gates above already exercise the legacy/txn/slot paths end-to-end with this flag off).
func _gate_tilesurf_off() -> void:
	print("  --- FP_SMOOTH_TILE_SURF G-TILESURF-OFF: flag off => the per-tile path never runs ---")
	var parent := Node3D.new()
	var ft := FST.new()
	ft.setup_instance(parent, null)
	var tier := FST.S4
	var cells := FST.cells_for_tier(tier)
	var fid_a := _fid_of(3, 4, 5)
	var fid_b := _fid_of(3, 4, 6)
	var tile_a := FST.build_tile(fid_a, cells, 0.0, true, false, -1.0)
	FST.append_skirt(tile_a, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
	var tile_b := FST.build_tile(fid_b, cells, 0.0, true, false, -1.0)
	FST.append_skirt(tile_b, cells, CubeSphere.SMOOTH_SKIRT_BLOCKS)
	# Drive the SHIPPED default-args commit path (mirrors `_simulate_tier_commit` — no tile_surf hook engaged).
	_simulate_tier_commit(ft, fid_a, tier, tile_a)
	_simulate_tier_commit(ft, fid_b, tier, tile_b)
	ft._evict(fid_a)   # default args: slot_on/tile_surf_on both default false
	for i in range(5):
		ft.step()   # default args: tile_surf_on defaults to CubeSphere.FP_SMOOTH_TILE_SURF (false)
	_ok((ft._tile_mi as Dictionary).is_empty(), "G-TILESURF-OFF: `_tile_mi` stays completely empty across a real commit/evict/step() cycle with the flag off")
	_ok(int(ft.tile_surf_stats()["smooth_tile_nodes"]) == 0, "G-TILESURF-OFF: tile_surf_stats() reports 0 per-tile nodes")
	_ok(int(ft.tile_surf_stats()["smooth_tile_surf_path"]) == 0, "G-TILESURF-OFF: tile_surf_stats() reports the per-tile path never fired")
	parent.free()

## G-SMOOTH-HORIZON (REVISION 7-VISUAL §R7.3, FP_SMOOTH_HORIZON_COVER): the S5 reach extension that covers the
## surface horizon so flat low-res skin doesn't show through. Byte-off (the effective cap/hop == the shipped consts
## with the flag off) + the horizon consts genuinely extend reach + NEVER-OOM (even the bumped cap fits the ledger).
## The actual "no skin inside the horizon" is a LIVE eyeball (headless can't render the skin/smooth frontier).
func _gate_smooth_horizon() -> void:
	print("  --- G-SMOOTH-HORIZON: S5 reach extension (DEFECT 2 low-res skin patch) — byte-off + extends-reach + NEVER-OOM ---")
	_ok(CubeSphere.smooth_s5_max() == CubeSphere.SMOOTH_S5_MAX,
		"G-SMOOTH-HORIZON-OFF: smooth_s5_max()==SMOOTH_S5_MAX(%d) with the flag off (byte-off)" % CubeSphere.SMOOTH_S5_MAX)
	_ok(CubeSphere.smooth_s5_hop() == CubeSphere.SMOOTH_STICKY_S5_HOP,
		"G-SMOOTH-HORIZON-OFF: smooth_s5_hop()==SMOOTH_STICKY_S5_HOP(%d) with the flag off (byte-off)" % CubeSphere.SMOOTH_STICKY_S5_HOP)
	_ok(CubeSphere.SMOOTH_S5_MAX_HORIZON > CubeSphere.SMOOTH_S5_MAX,
		"G-SMOOTH-HORIZON: SMOOTH_S5_MAX_HORIZON(%d) > SMOOTH_S5_MAX(%d) — the flag genuinely extends coverage (not a no-op)" % [CubeSphere.SMOOTH_S5_MAX_HORIZON, CubeSphere.SMOOTH_S5_MAX])
	_ok(CubeSphere.SMOOTH_STICKY_S5_HOP_HORIZON > CubeSphere.SMOOTH_STICKY_S5_HOP,
		"G-SMOOTH-HORIZON: hop reach HORIZON(%d) > shipped(%d)" % [CubeSphere.SMOOTH_STICKY_S5_HOP_HORIZON, CubeSphere.SMOOTH_STICKY_S5_HOP])
	# NEVER-OOM: even the BUMPED S5 residency's worst-case bytes stay within the SMOOTH_BYTES_MAX ledger that caps
	# real memory at runtime (so the cap bump can never OOM — the ledger refuses tiles past the byte ceiling).
	var s5_cells := FST.cells_for_tier(FST.S5)
	var verts := (s5_cells + 1) * (s5_cells + 1)
	var per_tile := verts * 60   # generous upper bound B/vert (pos+nrm+col+uv+uv2 + idx amortized); real ledger tile_bytes ≤ this
	var worst := CubeSphere.SMOOTH_S5_MAX_HORIZON * per_tile
	_ok(worst <= CubeSphere.SMOOTH_BYTES_MAX,
		"G-SMOOTH-HORIZON: worst-case bumped S5 (%d tiles × ≤%d B = %.1f MB) ≤ SMOOTH_BYTES_MAX (%.0f MB) — NEVER-OOM" % [CubeSphere.SMOOTH_S5_MAX_HORIZON, per_tile, worst / 1048576.0, CubeSphere.SMOOTH_BYTES_MAX / 1048576.0])

func _gate_noop() -> void:
	pass

## G-FS-SELFHEAL (REVISION 7-VISUAL #28, FP_SMOOTH_SNAP_SELFHEAL): the SUNK-FACET DISCONNECT fix. Deterministically
## INJECTS the race RESULT (not its timing): a settled facet A is re-committed via a completed worker slot whose
## frozen snap (`_s_snap`) is STALE while `_snap_plan[A]` has moved — exactly Fable's H1/H2. With the flag ON the
## commit self-check (built != plan) MUST re-queue `request_refresh(A)`; with it OFF (current code) it does NOT — so
## `_built_snap != _snap_plan` persists with no pending refresh = the eternal stale edge = the disconnect line. The
## OFF assertion IS the falsify (proves the gate catches the real bug).
func _gate_snap_selfheal() -> void:
	print("  --- G-FS-SELFHEAL: a stale-plan commit re-queues a refresh (closes the sunk-facet disconnect race) ---")
	for flag_on in [false, true]:
		var parent := Node3D.new()
		var ft := FST.new()
		ft.setup_instance(parent, null)
		var A := FA.spawn_facet()
		ft.request({A: FST.S4}, {}, false, false)
		_converge_ft(ft, false)
		if not ft.is_resident(A) or int(ft.tier_of(A)) != FST.S4:
			_ok(false, "G-FS-SELFHEAL[on=%s]: fixture A resident at S4" % str(flag_on)); parent.free(); continue
		var built: PackedInt32Array = (ft._built_snap.get(A, PackedInt32Array()) as PackedInt32Array).duplicate()
		if built.size() != 4:
			_ok(false, "G-FS-SELFHEAL[on=%s]: A has a 4-edge built snap to work from" % str(flag_on)); parent.free(); continue
		# The MOVED plan: identical to what A was built with EXCEPT one edge pitch — i.e. a neighbour changed tier
		# after A's build was dispatched, so `_snap_plan[A]` != `_built_snap[A]`.
		var moved := built.duplicate()
		moved[0] = int(moved[0]) + 1
		# Inject a completed worker slot that re-commits A with the STALE frozen snap (`built`, NOT `moved`).
		var tile_a: Dictionary = FST.build_tile(A, FST.cells_for_tier(FST.S4), 0.0, true)
		var task := WorkerThreadPool.add_task(Callable(self, "_gate_noop"))
		OS.delay_msec(25)   # let the no-op finish so the reap's is_task_completed(task) is true
		ft._s_fid[0] = A
		ft._s_tier[0] = FST.S4
		ft._s_result[0] = tile_a
		ft._s_snap[0] = built            # STALE dispatch plan
		ft._s_task[0] = task
		ft._want[A] = FST.S4
		ft._snap_plan[A] = moved         # the plan has moved on since A was dispatched
		ft._refresh.erase(A)             # H2: nothing pending (or it was eaten)
		# One step reaps the injected slot → commits A (built_snap := stale) → the self-check (flag on) fires.
		ft.step(false, false, false, false, CubeSphere.SMOOTH_COMMIT_BUDGET_BYTES, false, flag_on)
		var requeued: bool = ft._refresh.has(A)
		if flag_on:
			_ok(requeued, "G-FS-SELFHEAL[on]: a stale commit (built != plan) RE-QUEUES request_refresh(A) — the disconnect self-heals")
		else:
			_ok(not requeued, "G-FS-SELFHEAL[off/falsify]: WITHOUT the flag the stale commit leaves NO pending refresh — the eternal stale edge the user saw (proves the gate catches the real bug)")
		parent.free()
