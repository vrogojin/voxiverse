class_name FacetSmoothV2
extends RefCounted
## docs/COSMOS-FAR-SMOOTH-V2-DESIGN.md §4 V2-1 (FP_SMOOTH_V2) — the minimal-proof phase of the smooth-far V2
## CLEAN-SLATE RESET. This is a NEW, separate subsystem: it does NOT touch `facet_smooth_tier.gd` (the old
## S2..S5 ladder, `FP_FAR_SMOOTH`) — that file and its flags are left byte-for-byte untouched.
##
## THE THREE DESIGN DECISIONS (§0):
##   1. ONE uniform pitch (`CubeSphere.V2_CELLS` cells/facet edge, no ladder). Residency is a PURE function of the
##      active facet: a hop-BFS annulus `hop ∈ [V2_HOP_B..V2_HOP_H]` over `FacetAtlas.seam_neighbour` (§2.2 LAW
##      R-A, now degenerate-simple — no tiers, no snap plans, no exclusion, no rim). A shared-edge boundary vertex
##      is `f(shared canon corner dirs [FacetAtlas static data], i/cells [a global const])` — nothing mutable,
##      nothing neighbour-dependent — so two facets weld bit-identically BY CONSTRUCTION (§1.1); there is no
##      ordering/race class left to have (G-V2-PURE asserts this as byte-equality under permuted build order).
##   2. Per-cell FLAT colour (§2.3), zero textures. Each 8-block cell is painted the ONE colour of its own
##      provoking node's baked (g, biome, temp) → `FarPalette.color_for` — carried through a `flat` COLOR varying
##      (GLSL ES 3.0 last-vertex-provoking convention). No baked skin map ever touches this geometry.
##   3. Draws OVER the shell — no emit-exclusion. The far-ring shell keeps emitting every facet exactly as shipped;
##      this mesh is a second, small, always-later-drawn surface parented under the SAME ring node (shares its
##      placement transform), covering the shell's flat cells with real relief inside the annulus.
##
## SAFETY (non-negotiable, hard-won this session): every mesh commit is a WHOLE-SURFACE `ArrayMesh` rebuild via the
## SAFE high-level API — `ArrayMesh.new()` + `add_surface_from_arrays` + `mi.mesh = mesh`. NEVER
## `RenderingServer.mesh_surface_update_vertex_region`/`_attribute_region` (those abort ANGLE/WebGL2 with an
## uncatchable WASM crash — the REV-7 slot-mesh lesson `facet_smooth_tier.gd`'s `FP_SMOOTH_SLOT_MESH` learned the
## hard way; this reset does not repeat it). The resident set is bounded (≤ ~40 tiles in the V2-1 hop-[2..3] band,
## ≈9.6 MB), residency changes only on a facet crossing (infrequent), so one whole-surface rebuild per commit
## event is cheap. There is exactly ONE draw call, ONE material, ONE MeshInstance3D for the whole annulus.
##
## Off (`CubeSphere.FP_SMOOTH_V2 == false`) ⇒ `FacetSmoothV2` is never constructed by `FacetFarRing` ⇒ byte-
## identical (FLAT verify_feature.gd 6042/0). Gates: verify_far_smooth.gd (G-V2-WELD/G-V2-PURE/G-V2-COLOUR/G-V2-OFF).

# =====================================================================================================================
# PURE / STATIC / WORKER-SAFE — no instance state read. These are the functions the gates call directly, headless,
# with no FacetSmoothV2 instance at all (mirrors how verify_far_smooth.gd calls FacetSmoothTier.build_tile directly).
# =====================================================================================================================

## Skirt drop (blocks) — a thin radially-inward curtain along all 4 tile edges so a sub-pixel weld-rounding gap (or
## a momentarily-absent neighbour tile mid-warmup) reveals this skirt, never a see-through hole. Cosmetic only —
## not asserted by any gate (the weld law itself, G-V2-WELD, is what proves boundary vertices actually agree).
const SKIRT_DROP_BLOCKS := 4.0

enum { EDGE_WEST = 0, EDGE_EAST = 1, EDGE_SOUTH = 2, EDGE_NORTH = 3 }

## Build ONE tile's surface arrays for facet `fid` at `cells` cells/edge, via the native `bake_smooth_tile` (already
## shipped, byte-equal, read-only under an RWLockRead — worker-safe). `gen` is a frozen VoxelGeneratorCosmos built
## ONCE by the caller (any fid — the noise stack/material tables are facet-INDEPENDENT; `bake_smooth_tile` takes
## the corner dirs/r_datum/cells explicitly, so ONE `gen` instance bakes tiles for every fid in the resident set,
## exactly as the shipped ladder's `_cpp_gen` already does). Returns {} (a refusal) if `gen` is null or the native
## call doesn't return the expected-size `dir` array (module absent / not ready) — the caller must never commit an
## empty tile as resident.
##   pos : PackedVector3Array (cells+1)²   block-top-exact (the native bake's own `pos`, already the P0 canon-dir
##                                          radial placement — no re-derivation, no rounding beyond the native bake).
##   nrm : PackedVector3Array              RADIAL direction (`dir`) at every node — V2-1 is radial-shade-only
##                                          near-parity (§2.2); a real per-cell relief normal is V2-2 (FP_SMOOTH_V2_LIT).
##   col : PackedColorArray                `FarPalette.skin_color(...)` (FP_SKIN_BLOCK_COLOR-aware; shipped ⇒
##                                          FarPalette.color_for(g, biome, temp, water) verbatim) of THIS node's
##                                          own baked values — becomes the per-CELL flat colour by construction
##                                          (§2.3 below).
##   idx : PackedInt32Array 2 tris/cell     BOTH triangles of cell (gi,gj) end at node (gi+1,gj+1) — see the winding
##                                          comment in the loop below (the whole provoking-vertex trick).
static func build_tile(fid: int, cells: int, gen: Object) -> Dictionary:
	if gen == null:
		return {}
	FarPalette.ensure_ready()
	var r_datum := FacetAtlas.r_of(fid)
	var corner_dirs := FacetAtlas.facet_corner_dirs(fid)
	var stride := cells + 1
	var n := stride * stride
	var baked: Dictionary = gen.call("bake_smooth_tile", corner_dirs, r_datum, cells)
	if not baked.has("dir") or (baked["dir"] as PackedVector3Array).size() != n:
		return {}   # refusal: generator not ready / method missing / malformed request
	var b_dir: PackedVector3Array = baked["dir"]
	var b_g: PackedInt32Array = baked["g"]
	var b_biome: PackedInt32Array = baked["biome"]
	var b_temp: PackedFloat32Array = baked["temp"]
	var b_pos: PackedVector3Array = baked["pos"]
	# `planar`/`bnrm` are ALSO in the native return dict (VoxelGeneratorCosmos::bake_smooth_tile) — unused here:
	# V2-1 has no mixed-pitch frontier to snap (`planar`) and shades by the radial `dir`, not a boundary normal
	# (`bnrm`, a P2/S2-collar-only concern in the old ladder).

	var pos := PackedVector3Array(); pos.resize(n)
	var nrm := PackedVector3Array(); nrm.resize(n)
	var col := PackedColorArray(); col.resize(n)
	for vi in range(n):
		pos[vi] = b_pos[vi]
		nrm[vi] = b_dir[vi]
		var g := int(b_g[vi])
		var d := b_dir[vi]
		col[vi] = FarPalette.skin_color(fid, d.x * r_datum, d.y * r_datum, d.z * r_datum, g, int(b_biome[vi]), float(b_temp[vi]))

	var idx := PackedInt32Array()
	idx.resize(cells * cells * 6)
	var ii := 0
	for gj in range(cells):
		for gi in range(cells):
			var v00 := gj * stride + gi
			var v10 := v00 + 1
			var v01 := v00 + stride
			var v11 := v01 + 1
			# §2.3 PROVOKING-VERTEX LAW: a plain `(v00,v10,v11)+(v00,v11,v01)` split has tri A end at v11 but tri B
			# end at v01 — two DIFFERENT provoking vertices for the same cell. Tri B here is instead listed as
			# `(v01,v00,v11)` — a CYCLIC ROTATION of `(v00,v11,v01)` (same 3 vertices, same winding/normal, just a
			# different starting vertex), so its LAST vertex is now v11 too. Both triangles of cell (gi,gj) end at
			# v11 = node(gi+1,gj+1), and no OTHER cell's triangles end there ⇒ under GLSL ES 3.0's mandatory
			# last-vertex-provoking `flat` interpolation, node(gi+1,gj+1)'s own COLOR is exactly cell (gi,gj)'s
			# flat colour, on a fully shared/indexed grid, at zero extra vertices. Row-0/col-0 nodes are never
			# provoking; their COLOR is written (same law as every other node) but never read by the fragment stage.
			idx[ii] = v00; idx[ii + 1] = v10; idx[ii + 2] = v11
			idx[ii + 3] = v01; idx[ii + 4] = v00; idx[ii + 5] = v11
			ii += 6
			# V2-2 (FP_SMOOTH_V2_LIT): overwrite the PROVOKING node's normal with this cell's own geometric face
			# normal — the same provoking-vertex convention COLOR already uses, so the `flat`-interpolated shade a
			# cell's fragment reads matches the FLAT colour it's painted (one shade value per 8-block cell, real
			# relief instead of the radial-only V2-1 shade). `bnrm` from the native bake is perimeter-only (interior
			# = zero) so it is NEVER used here — this is derived purely from the already-baked `pos`. Off ⇒ this
			# whole block never runs; `nrm` stays the shipped radial `b_dir` set above (byte-identical).
			if CubeSphere.FP_SMOOTH_V2_LIT:
				var fn: Vector3 = (pos[v10] - pos[v00]).cross(pos[v01] - pos[v00])
				if fn.length() > 0.0:
					fn = fn.normalized()
					if fn.dot(pos[v11].normalized()) < 0.0:
						fn = -fn
					nrm[v11] = fn
				# else: a degenerate cell (zero-area) — leave v11's normal at its shipped radial value.

	var tile := {"pos": pos, "nrm": nrm, "col": col, "idx": idx}
	_append_skirt(tile, cells, SKIRT_DROP_BLOCKS)
	return tile

## The always-on crack backstop (mirrors `FacetSmoothTier.append_skirt`'s law 5, minus the uv/uv2 attributes this
## no-texture geometry never carries). Appends a thin radially-inward curtain along all 4 edges of an already-built
## tile, `drop` blocks below the true surface (pos.normalized() IS the outward radial in planet-centred coords).
## Mutates `tile`'s packed arrays in place; worker-safe (touches only this tile's own arrays).
static func _append_skirt(tile: Dictionary, cells: int, drop: float) -> void:
	var pos: PackedVector3Array = tile["pos"]
	var nrm: PackedVector3Array = tile["nrm"]
	var col: PackedColorArray = tile["col"]
	var idx: PackedInt32Array = tile["idx"]
	var stride := cells + 1
	for edge in range(4):
		var e := _edge_indices(edge, cells, stride)
		var base := pos.size()
		for vi in e:
			var p: Vector3 = pos[vi]
			var d := p.normalized()
			pos.append(p - d * drop)
			nrm.append(nrm[vi])
			col.append(col[vi])
		for k in range(e.size() - 1):
			var a0: int = e[k]
			var a1: int = e[k + 1]
			var b0 := base + k
			var b1 := base + k + 1
			idx.append(a0); idx.append(a1); idx.append(b1)
			idx.append(a0); idx.append(b1); idx.append(b0)
	tile["pos"] = pos
	tile["nrm"] = nrm
	tile["col"] = col
	tile["idx"] = idx

static func _edge_indices(edge: int, cells: int, stride: int) -> Array:
	var out := []
	match edge:
		EDGE_WEST:
			for gj in range(stride): out.append(gj * stride + 0)
		EDGE_EAST:
			for gj in range(stride): out.append(gj * stride + cells)
		EDGE_SOUTH:
			for gi in range(stride): out.append(0 * stride + gi)
		_:
			for gi in range(stride): out.append(cells * stride + gi)
	return out

## §2.2 LAW R-A (degenerate-simple): the resident-set target — every facet at BFS hop-distance ∈ [hop_b..hop_h]
## from `active`, via `FacetAtlas.seam_neighbour` over the 4 cardinal slots (the SAME graph `FacetFarRing.
## _smooth_hop_assignment` already BFSes for the old ladder). PURE function of `active` alone; nearest-first order
## (BFS level order) — the caller dispatches builds in this order so the inner ring fills before the outer one.
static func hop_annulus(active: int, hop_b: int, hop_h: int) -> Array:
	var visited := {active: true}
	var frontier := [active]
	var slots := [FacetAtlas.S_EAST, FacetAtlas.S_WEST, FacetAtlas.S_NORTH, FacetAtlas.S_SOUTH]
	var out := []
	var hop := 0
	while not frontier.is_empty() and hop < hop_h:
		hop += 1
		var next_frontier := []
		for fid in frontier:
			for slot in slots:
				var nb := FacetAtlas.seam_neighbour(int(fid), slot)
				if nb < 0 or visited.has(nb):
					continue
				visited[nb] = true
				next_frontier.append(nb)
				if hop >= hop_b:
					out.append(nb)
		frontier = next_frontier
	return out

## §1.1 the RACE-FREEDOM theorem, made mechanical: merge an ARBITRARY `{fid -> tile}` resident dict into ONE set of
## surface arrays, concatenating tiles in ASCENDING fid order — a fixed canonical order that depends on the SET of
## resident fids alone, never on the Dictionary's insertion order (which tracks worker-completion order and can
## permute run to run). Two resident sets containing the SAME fids therefore merge to BYTE-EQUAL arrays regardless
## of build/insertion order (G-V2-PURE). PURE — no instance state, no RenderingServer/Node access; the gates call
## this directly with hand-built `{fid -> build_tile(...)}` dicts.
static func merge_tiles(tiles: Dictionary) -> Dictionary:
	var fids := tiles.keys()
	fids.sort()
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for fid in fids:
		var tile: Dictionary = tiles[fid]
		if tile.is_empty():
			continue
		var base := pos.size()
		var tpos: PackedVector3Array = tile["pos"]
		var tnrm: PackedVector3Array = tile["nrm"]
		var tcol: PackedColorArray = tile["col"]
		var tidx: PackedInt32Array = tile["idx"]
		pos.append_array(tpos)
		nrm.append_array(tnrm)
		col.append_array(tcol)
		var n := tidx.size()
		for k in range(n):
			idx.append(tidx[k] + base)
	return {"pos": pos, "nrm": nrm, "col": col, "idx": idx}

## Resident byte cost of a built tile (NEVER-OOM ledger). pos/nrm 12 B each, col 16 B, idx 4 B — no uv/uv2 (this
## geometry carries no texture attributes at all).
static func tile_bytes(tile: Dictionary) -> int:
	if tile.is_empty():
		return 0
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	return nv * (12 + 12 + 16) + ni * 4

# =====================================================================================================================
# THE V2-1 SHADER (LIVE-PROBE-REQUIRED — see the class doc + the orchestrator report: the headless dummy
# RenderingServer never parses shader source, so this is unverified until a real ANGLE/WebGL2 frame compiles it).
# ONE ShaderMaterial, unshaded/vertex-lit, radial-shade only (near-parity, §2.2): the SAME day/night/terminator/
# moonshine law as the shipped far-ring shell (`VoxiLight.SHADE_GLSL`/`voxi_shade`, string-included — pure
# concatenation, no new law), computed from the TRUE planet-radial normal `n = normalize(wp − MODEL·0)` (matches
# the shell's own `_SHELL_ABS_SHADER`). The ONLY new thing is the COLOR varying's `flat` interpolation qualifier —
# GLSL ES 3.0 (WebGL2/ANGLE, our floor) mandates `flat` + last-vertex-provoking convention, and Godot's shader
# language supports it (`shader_language.h` TK_INTERPOLATION_FLAT); the grammar is `varying flat <type> <name>;`
# (interpolation qualifier AFTER `varying`, BEFORE the type — confirmed against `servers/rendering/shader_language.
# cpp`'s TK_VARYING/is_token_interpolation parse path, NOT `flat varying ...`). `v_col` carries `COLOR.rgb ×
# voxi_shade(n, sun_dir)` — the shade/tint is evaluated once per vertex but the WHOLE varying is `flat`, so the
# fragment always reads the shade/tint value AT THE PROVOKING VERTEX (a per-cell-quantized approximation of
# shading, consistent with the hard 8-block quantized COLOR paint — not a smooth gradient).
# =====================================================================================================================

const _V2_SHADER_HEAD := "shader_type spatial;
render_mode unshaded, cull_disabled;
"
const _V2_SHADER_TAIL := "varying flat vec4 v_col;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n = normalize(wp - centre);
	v_col = vec4(COLOR.rgb * voxi_shade(n, sun_dir), 1.0);
}
void fragment() {
	ALBEDO = v_col.rgb;
}
"

## V2-2 (FP_SMOOTH_V2_LIT) — LIVE-PROBE-REQUIRED: the ONLY difference from `_V2_SHADER_TAIL` is where the vertex
## body derives its shading normal `n` FROM — the shipped body re-derives the TRUE planet-radial direction
## (`wp - centre`), ignoring whatever the mesh's own NORMAL attribute carries; this LIT body instead reads the
## mesh NORMAL (the per-cell face normal `build_tile` stamps onto each provoking node under the flag) transformed
## into world space, so a sloped cell's `flat`-interpolated shade reflects its REAL relief instead of the radial
## direction. Everything else — `shader_type`/`render_mode`, the `VoxiLight.shade_glsl()` include, the `varying
## flat vec4 v_col;` declaration, and `fragment()` — is byte-identical to the OFF tail. GLSL ES 3.0 legal: NORMAL
## is a plain vertex-stage input (vec3), `MODEL_MATRIX * vec4(NORMAL, 0.0)` is the standard direction-only
## transform (w=0 drops translation), matching the convention Godot's own spatial shaders use for normals.
const _V2_SHADER_TAIL_LIT := "varying flat vec4 v_col;
void vertex() {
	vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_col = vec4(COLOR.rgb * voxi_shade(n, sun_dir), 1.0);
}
void fragment() {
	ALBEDO = v_col.rgb;
}
"

## The full shader source: HEAD (shader_type/render_mode) + the shared `VoxiLight.shade_glsl()` snippet (declares
## sun_dir/night_floor/term_mu/moonshine + voxi_shade — string-composed exactly like `TierPlace`/`facet_far_ring.gd`
## already do under FP_SHADE_UNIFIED) + TAIL (the flat COLOR varying + vertex/fragment). Composed in a FUNCTION
## (not a top-level `const` concatenation) so it always reads `VoxiLight`'s CURRENT snippet — e.g. picks up
## `FP_TWILIGHT_AMBIENT`'s ambient-floor splice for free, with zero duplicated lighting law. V2-2
## (FP_SMOOTH_V2_LIT): swaps in `_V2_SHADER_TAIL_LIT` (relief-normal shading) — off ⇒ `_V2_SHADER_TAIL` verbatim,
## the exact shipped V2-1 string (byte-identical shader source when the flag is off).
static func shader_code() -> String:
	var tail := _V2_SHADER_TAIL_LIT if CubeSphere.FP_SMOOTH_V2_LIT else _V2_SHADER_TAIL
	return _V2_SHADER_HEAD + VoxiLight.shade_glsl() + tail

## FP_FAR_TERMINATOR_WELD: the last live Sun direction any FacetSmoothV2 instance was fed via `set_sun_dir`
## (a class-level static — the annulus is rebuilt on facet crossings, so this outlives any one instance).
## Read by `make_material` to seed a REBUILT material with the live Sun instead of the hardcoded (1,0,0)
## fake-noon default. Off ⇒ never written, `make_material` never reads it ⇒ byte-identical.
static var _last_sun_dir := Vector3(1.0, 0.0, 0.0)

## Public (not `_`-prefixed): `FacetOrbitRelief` (docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md §1.6) reuses this
## verbatim for its own material — G3's mesh carries real per-vertex relief normals (unlike V2's flat/radial
## shading), so the LIT shader family this already builds is exactly where that information gets used, with
## zero new shader source.
static func make_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = shader_code()
	sm.shader = sh
	# FP_FAR_TERMINATOR_WELD (docs/COSMOS-FAR-TERMINATOR-DESIGN.md §4.1): seed from the last live Sun this class
	# was told about, not the hardcoded default — kills the "frozen fake-noon" gap on a facet-crossing rebuild.
	# Off ⇒ the shipped hardcoded seed verbatim (byte-identical; _last_sun_dir stays at its own (1,0,0) default).
	var seed := _last_sun_dir if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
	sm.set_shader_parameter("sun_dir", seed)
	return sm

# =====================================================================================================================
# THE INSTANCE — owned by ONE FacetFarRing under FP_SMOOTH_V2. ONE MeshInstance3D, ONE material, ONE draw. Builds
# happen off-thread (WorkerThreadPool, a small fixed slot pool, single-writer discipline mirroring
# `FacetSmoothTier._build_worker`/`_s_result`); the merge + ArrayMesh commit happens on MAIN (safe: only the SAFE
# high-level API, see the class doc). Residency is a pure function of `_active_fid` (§2.2); a short dwell delays
# eviction of a facet that just left the annulus (avoids thrashing right at the hop boundary).
# =====================================================================================================================

const EVICT_DWELL_STEPS := 20   ## step() calls a facet is kept resident-but-unwanted before it's actually evicted

var _mi: MeshInstance3D = null
var _material: ShaderMaterial = null
var _cpp_gen: Object = null           ## frozen VoxelGeneratorCosmos, built ONCE in setup_instance; read-only in workers
var _cells: int = CubeSphere.V2_CELLS
var _hop_b: int = CubeSphere.V2_HOP_B
var _hop_h: int = CubeSphere.V2_HOP_H

var _active_fid := -1
var _want: Dictionary = {}            ## fid -> true (the current residency target)
var _want_order: Array = []           ## the SAME fids, nearest-first BFS order (dispatch priority)
var _tiles: Dictionary = {}           ## fid -> tile dict (resident, committed on main)
var _leaving: Dictionary = {}         ## fid -> dwell steps remaining before eviction (fid no longer in `_want`)
var _dirty := false                   ## a commit/evict landed since the last mesh rebuild

# worker slots (single-writer of _s_fid/_s_task on main pre-dispatch; the worker writes only _s_result[i] under the mutex)
var _sn := 0
var _s_fid: PackedInt32Array = PackedInt32Array()
var _s_task: PackedInt32Array = PackedInt32Array()
var _s_result: Array = []
var _s_mutex: Mutex = null

var _last_commit_ms := 0.0

# FP_LOAD_DEFER (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 1): settle-freeze bookkeeping. `_first_commit_done` gates the
# FIRST post-settle commit on stream_credit (so the deferred backlog can't fire on one frame). `_dispatch_count` /
# `_commit_count` are gate counters (G-FL-GATE asserts both == 0 while deferred). All inert with the flag off.
var _first_commit_done := false
var _dispatch_count := 0
var _commit_count := 0

# FP_SMOOTH_V2_PACE (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 2): wall-clock ms of the last commit — the G3 rate-cap
# anchor (distinct from `_last_commit_ms`, which is the last commit's COST/duration). Inert with the flag off.
var _last_commit_wall_ms := 0
# FP_SMOOTH_V2_ASYNC_MERGE (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 2): a SINGLE off-thread merge slot. `_merge_task`
# is the in-flight WTP task id (-1 = idle); the worker writes `_merge_result` (the merged array dict) under
# `_merge_mutex`; main reaps it next step(). Never stacked (one merge at a time). All inert with the flag off.
var _merge_task := -1
var _merge_result = null
var _merge_mutex: Mutex = null

## Construct the ONE MeshInstance3D (child of `ring`, sharing its placement transform — like the old ladder's
## `_smooth`), the frozen native generator, and the worker slot pool; seed `_want`/`_want_order` for `active_fid`.
## `ring` is the owning FacetFarRing (any Node3D works — only `add_child`/transform inheritance is used).
func setup_instance(ring: Node3D, active_fid: int) -> void:
	_active_fid = active_fid
	_material = make_material()
	_mi = MeshInstance3D.new()
	_mi.name = "FacetSmoothV2Mesh"
	_mi.mesh = ArrayMesh.new()
	ring.add_child(_mi)
	_cpp_gen = FacetSkinTier._build_cpp_gen(active_fid)
	# V2-3a (FP_SMOOTH_V2_REACH): reach one hop further so more of the far field is real relief, not flat skin.
	# Off ⇒ `_hop_h` stays `CubeSphere.V2_HOP_H` (byte-identical). `_hop_b` is untouched either way.
	_hop_h = CubeSphere.V2_HOP_H_REACH if CubeSphere.FP_SMOOTH_V2_REACH else CubeSphere.V2_HOP_H
	_sn = clampi(OS.get_processor_count() - 1, 1, CubeSphere.SMOOTH_BUILD_SLOTS)
	_s_fid = PackedInt32Array(); _s_fid.resize(_sn); _s_fid.fill(-1)
	_s_task = PackedInt32Array(); _s_task.resize(_sn); _s_task.fill(-1)
	_s_result.resize(_sn)
	_s_mutex = Mutex.new()
	_merge_mutex = Mutex.new()   # FP_SMOOTH_V2_ASYNC_MERGE: guards the single off-thread merge slot (idle off the flag)
	_recompute_want(active_fid)

func _recompute_want(active: int) -> void:
	var order := hop_annulus(active, _hop_b, _hop_h)
	var new_want := {}
	for fid in order:
		new_want[int(fid)] = true
	for fid in new_want.keys():
		_leaving.erase(fid)   # back in range — cancel any pending dwell-eviction
	for fid in _tiles.keys():
		if not new_want.has(fid) and not _leaving.has(fid):
			_leaving[fid] = EVICT_DWELL_STEPS
	_want = new_want
	_want_order = order

## §2.2: the ONLY time residency is recomputed — a facet crossing. Pure function of `new_fid` alone (no camera
## coupling, no per-frame re-ranking). No-op if the active facet didn't actually change.
func set_active(new_fid: int) -> void:
	if new_fid == _active_fid:
		return
	_active_fid = new_fid
	_cpp_gen = FacetSkinTier._build_cpp_gen(new_fid)
	_recompute_want(new_fid)

## Reap finished builds, advance dwell evictions, dispatch new builds into free worker slots (nearest-first from
## `_want_order`), then commit ONE whole-surface ArrayMesh rebuild if anything changed this call. Cheap at rest
## (no dirty tiles, no in-flight slots, no wanted-not-resident fid ⇒ every loop below is a fast no-op scan).
##
## FP_LOAD_DEFER (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 1): pre-settle (`settled == false`) this is the WS1a
## suspend the `FacetOrbitRelief.step()` already proves — the reap loop ALWAYS runs (free the worker slot, land
## the tile, mark dirty so nothing dangles across the freeze), then it returns BEFORE eviction/dispatch/commit:
## the resident mesh stays frozen and the worker seats belong to the near field's load window. Post-settle it
## resumes paced: dispatch runs immediately (workers are free by then) but the FIRST commit waits until
## `credit_ok` (`stream_credit > 0`) so the deferred backlog cannot fire on one frame. Both args default true ⇒
## the sole caller with the flag off (and any no-arg caller) runs the shipped path verbatim, and the freeze
## itself is gated on `CubeSphere.FP_LOAD_DEFER` so a `settled == false` passed with the flag off is inert.
##
## FP_SMOOTH_V2_PACE / FP_SMOOTH_V2_ASYNC_MERGE (docs/COSMOS-FAST-LOAD-DESIGN.md Phase 2): the commit is (a) rate-
## capped to `SMOOTH_V2_COMMIT_MS` apart (dirty accumulates — the G3 pattern), and (b) its ~630k-index merge runs
## off-thread on a snapshot, the main thread paying only the GPU upload at reap. Both self-gate off their flags ⇒
## commit-every-reap, synchronous merge on main (byte-identical) when off.
func step(settled := true, credit_ok := true) -> void:
	if _sn == 0:
		return
	var deferred := CubeSphere.FP_LOAD_DEFER and not settled
	for i in range(_sn):
		if int(_s_fid[i]) < 0 or not WorkerThreadPool.is_task_completed(int(_s_task[i])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(_s_task[i]))
		var fid := int(_s_fid[i])
		_s_mutex.lock()
		var tile = _s_result[i]
		_s_result[i] = null
		_s_mutex.unlock()
		_s_fid[i] = -1
		_s_task[i] = -1
		if tile != null and not (tile as Dictionary).is_empty() and _want.has(fid):
			_tiles[fid] = tile
			_leaving.erase(fid)
			_dirty = true
		# else: a refusal (module absent/not ready) or `_want` moved while it built — discard silently; the
		# fid stays in `_want_order` so a later step() call will simply re-dispatch it.
	# FP_SMOOTH_V2_ASYNC_MERGE: reap a completed off-thread merge — the main thread pays ONLY the GPU upload here
	# (`add_surface_from_arrays` + `_mi.mesh =`), never the ~630k-index concat. Reaped like any build (always, even
	# when deferred/frozen — but pre-settle no merge is ever dispatched, so this is a fast no-op then). Off ⇒ inert.
	if CubeSphere.FP_SMOOTH_V2_ASYNC_MERGE and _merge_task >= 0 and WorkerThreadPool.is_task_completed(_merge_task):
		WorkerThreadPool.wait_for_task_completion(_merge_task)
		_merge_task = -1
		_merge_mutex.lock()
		var merged = _merge_result
		_merge_result = null
		_merge_mutex.unlock()
		if merged != null:
			var t0 := Time.get_ticks_usec()
			_build_and_swap(merged)
			_last_commit_ms = (Time.get_ticks_usec() - t0) / 1000.0   # main pays ONLY the apply, not the merge
			_first_commit_done = true
			_commit_count += 1
	if deferred:
		return   # WS1a: pre-settle — no eviction, no dispatch, no commit. Frozen; `_dirty` accumulates for the settle resume.
	if not _leaving.is_empty():
		var to_evict := []
		for fid in _leaving.keys():
			var left := int(_leaving[fid]) - 1
			if left <= 0:
				to_evict.append(fid)
			else:
				_leaving[fid] = left
		for fid in to_evict:
			_leaving.erase(fid)
			if _tiles.has(fid):
				_tiles.erase(fid)
				_dirty = true
	for fid in _want_order:
		var f := int(fid)
		if _tiles.has(f) or _inflight(f):
			continue
		var slot := _free_slot()
		if slot < 0:
			break   # no free worker slot this call — the remainder waits for a later step()
		_s_fid[slot] = f
		_s_task[slot] = WorkerThreadPool.add_task(Callable(self, "_build_worker").bind(slot), true, "smoothv2tile")
		_dispatch_count += 1
	if _dirty:
		# FP_LOAD_DEFER: the FIRST commit after the settle-freeze lifts waits for the near field to stop starving
		# (`credit_ok` = stream_credit > 0) so the accumulated backlog can't fire on one frame. Gated on the flag ⇒
		# off, this is `false` and the commit is unconditional (byte-identical); once one commit lands the gate is spent.
		if CubeSphere.FP_LOAD_DEFER and not _first_commit_done and not credit_ok:
			return
		# FP_SMOOTH_V2_ASYNC_MERGE: single-slot — if a merge is already in flight, hold (do NOT consume the pace
		# window below); `_dirty` stays set and a later step() dispatches once the in-flight merge reaps. Off ⇒ inert.
		if CubeSphere.FP_SMOOTH_V2_ASYNC_MERGE and _merge_task >= 0:
			return
		# FP_SMOOTH_V2_PACE: rate-cap commits to SMOOTH_V2_COMMIT_MS apart (the EXACT G3 pattern — FacetOrbitRelief.
		# should_commit). Dirty accumulates; a later step() retries once the window opens. Off ⇒ commit-every-reap.
		if CubeSphere.FP_SMOOTH_V2_PACE:
			var now_ms := Time.get_ticks_msec()
			if not FacetOrbitRelief.should_commit(_dirty, now_ms, _last_commit_wall_ms, CubeSphere.SMOOTH_V2_COMMIT_MS):
				return
			_last_commit_wall_ms = now_ms
		if CubeSphere.FP_SMOOTH_V2_ASYNC_MERGE:
			# Dispatch the merge off-thread on a SHALLOW snapshot (immutable-once-landed tiles; the worker reads only
			# its bound copy). `_commit_count`/`_first_commit_done` advance at the REAP above, when the upload lands.
			var snapshot := _tiles.duplicate()
			_merge_task = WorkerThreadPool.add_task(Callable(self, "_merge_worker").bind(snapshot), true, "smoothv2merge")
			_dirty = false
		else:
			_commit()
			_dirty = false
			_first_commit_done = true
			_commit_count += 1

func _free_slot() -> int:
	for i in range(_sn):
		if int(_s_fid[i]) < 0:
			return i
	return -1

func _inflight(fid: int) -> bool:
	for i in range(_sn):
		if int(_s_fid[i]) == fid:
			return true
	return false

## WorkerThreadPool-dispatched (off MAIN): build one tile. Only reads `_s_fid[i]` (written by main before dispatch,
## untouched until reaped) + `_cells`/`_cpp_gen` (frozen at setup/crossing time) — never touches `_tiles`/`_want`/
## any other main-thread-owned state. Writes only `_s_result[i]`, mutex-guarded (mirrors `FacetSmoothTier._build_worker`).
func _build_worker(i: int) -> void:
	var fid := int(_s_fid[i])
	var tile := build_tile(fid, _cells, _cpp_gen)
	_s_mutex.lock()
	_s_result[i] = tile
	_s_mutex.unlock()

## The ONE commit path: merge every resident tile (canonical ascending-fid order, §1.1) into one set of arrays and
## rebuild the ONE ArrayMesh surface from scratch — `ArrayMesh.new()` + `add_surface_from_arrays` + `mi.mesh =
## mesh`, the SAFE high-level API. NEVER a RenderingServer region/RID call. Runs on MAIN (the only thread allowed
## to touch `_mi`, a Node).
func _commit() -> void:
	var t0 := Time.get_ticks_usec()
	var merged := merge_tiles(_tiles)
	_build_and_swap(merged)
	_last_commit_ms = (Time.get_ticks_usec() - t0) / 1000.0

## Build ONE ArrayMesh surface from already-merged arrays and swap it onto `_mi` — the SAFE high-level API
## (`ArrayMesh.new()` + `add_surface_from_arrays` + `mi.mesh =`), NEVER a RenderingServer region/RID call (the REV-7
## ANGLE/WebGL2 law). Split out of `_commit` so the FP_SMOOTH_V2_ASYNC_MERGE reap can pay JUST this apply on main
## (the merge having run off-thread) — the sync `_commit` wraps merge+apply and times the whole thing exactly as
## shipped. MAIN-only (touches `_mi`, a Node).
func _build_and_swap(merged: Dictionary) -> void:
	var mesh := ArrayMesh.new()
	var pos: PackedVector3Array = merged["pos"]
	if pos.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = merged["nrm"]
		arrays[Mesh.ARRAY_COLOR] = merged["col"]
		arrays[Mesh.ARRAY_INDEX] = merged["idx"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, _material)
	_mi.mesh = mesh

## FP_SMOOTH_V2_ASYNC_MERGE (WorkerThreadPool-dispatched, off MAIN): merge the bound `snapshot` (a shallow duplicate
## of `_tiles` taken on main pre-dispatch — the worker reads only its own copy; the tile arrays are immutable once
## landed) into one set of surface arrays via the PURE static `merge_tiles`, then hand the result back under the
## mutex. Never touches `_mi`/`_tiles`/`_want` or any other main-thread state (single-writer discipline, mirrors
## `_build_worker`). Byte-identical to the sync `merge_tiles(_tiles)` for the same resident set (G-FL-MERGE-EQ).
func _merge_worker(snapshot: Dictionary) -> void:
	var merged := merge_tiles(snapshot)
	_merge_mutex.lock()
	_merge_result = merged
	_merge_mutex.unlock()

func resident_count() -> int:
	return _tiles.size()

func commit_ms() -> float:
	return _last_commit_ms

## FP_LOAD_DEFER gate counters (verify_fast_load.gd G-FL-GATE asserts both stay 0 while the settle latch is held false).
func dispatch_count() -> int:
	return _dispatch_count

func commit_count() -> int:
	return _commit_count

func is_resident(fid: int) -> bool:
	return _tiles.has(fid)

## Feed the current Sun direction into THIS material (a separate ShaderMaterial from the shell's — see the class
## doc's shader section) so its day/night/terminator shade tracks live time. No-op if the material isn't built yet.
func set_sun_dir(sun_dir: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)
	# FP_FAR_TERMINATOR_WELD: also record the live value in the class-level cache so the NEXT rebuilt instance
	# (facet crossing) seeds from it in `make_material` instead of the hardcoded default. Off ⇒ no-op write to
	# a var `make_material` never reads ⇒ byte-identical.
	if CubeSphere.FP_FAR_TERMINATOR_WELD:
		_last_sun_dir = sun_dir

## FP_FAR_TERMINATOR_WELD telemetry: THIS instance's live `sun_dir` uniform (the sun-echo, `sd_v2`) — lets a live
## A/B confirm the smooth-v2 annulus tracks the same Sun as the shell/near field. (1,0,0) sentinel if unbuilt.
func sun_dir_telemetry() -> Vector3:
	return (_material.get_shader_parameter("sun_dir") if _material != null else Vector3(1.0, 0.0, 0.0))
