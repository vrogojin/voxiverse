class_name MoonFarRing
extends Node3D
## COSMOS-LOD-SKY M2 (docs/COSMOS-LOD-SKY-DESIGN.md §3/§4/§5) — the Moon's own coarse far ring, a
## BODY-PARAMETERIZED instance of the far-ring machinery for a NON-DOMINANT sky body. It reuses
## FacetFarRing's geometry construction VERBATIM in spirit — the planarized-corner bilerp grid, radial
## relief, and per-vertex palette colour (see FacetFarRing._ensure_cached / _emit_cached) — but STRIPPED
## of every near-field concern that only the dominant, walked-upon body has: no active facet, no live-pool
## exclusion, no backstop sink, no sticky roles, no shell camera-set law, no async double-buffer. A body in
## the SKY has no near voxel field over it, no active facet on it, and no pool, so those apparatus are
## structurally inapplicable here (that is why this is a focused second ring instance, per §4.2's "a second
## ring instance OR a body-parameterized ring", rather than threading a body param through FacetFarRing's
## 1099 lines and risking Earth's byte-identity).
##
## Genericity comes from FacetAtlas' body registry: the ring iterates ONE body's global fid range
## [fid_base, fid_end) at its own k_of, samples each facet cell direction at r_of (the Moon datum 1737),
## and routes the profile through TerrainConfig.moon_profile_at_dir + FarPalette.moon_color_for. The atlas
## already built the Moon's frames/polys under MULTI_BODY (warm_up loops all active bodies), so
## facet_planar_corner(fid, ci) and r_of(fid) work for a Moon fid with zero call-site churn.
##
## PLACEMENT: the mesh is built in ABSOLUTE Moon-body coords (centred at the Moon centre, radius ≈ 1737).
## CosmosSky places the node each frame to MATCH the Moon impostor EXACTLY — the same sky centre
## (cam + moon_dir·D_SKY) and the same angular radius (D_SKY·tan(moon_ang/2)), via a uniform scale about
## the camera. Because the ring's silhouette then equals the impostor's sphere to sub-pixel, the
## IMPOSTOR→RING handover is seamless by construction (SEAMLESS-SCALES / G-SSE-INV).
##
## LIFETIME / NEVER-OOM (§5): built WHOLE on promotion (build), FREED WHOLE on eviction (evict → caches
## cleared, mesh emptied → gpu_bytes()==cpu_bytes()==0). Nothing grows with time or approach count: the
## emitted set is bounded by the body's 6·k² facets, and only the front-hemisphere cap is cached. Budget
## (§3): ≤ 2.5 MB GPU + 0.94 MB CPU for the Moon (k=14, 1176 facets), inside the 32 MB far-tier ceiling.
##
## DEAD with FP_MOON_RING off — the node is never created (CosmosSky guards construction on the flag).

const CELLS := 4                         # heightmap cells per facet edge (far LOD) — matches FacetFarRing.CELLS
const RELIEF := 1.0                      # blocks of radial relief per (g − SEA_LEVEL) — matches FacetFarRing.RELIEF
## Front-cap half-angle (deg): emit facets whose centre direction lies within this of the sub-camera axis.
## 96° (a hair past the hemisphere) mirrors the shell doc's 96° cap — it covers the silhouette relief while
## keeping the emitted set (and thus GPU bytes) under the §3 budget for the Moon (6·14² facets).
const CAP_DEG := 96.0
## Accounting bytes per emitted vertex (position 12 + normal 12 + colour 16), the §3/§5 ledger's 40 B/vert.
const BYTES_PER_VERT := 40

var _bi := -1                            # active-body index in FacetAtlas' registry
var _fid_base := 0
var _fid_end := 0
var _r := 1.0                            # the body datum radius (blocks) — FacetAtlas.r_of for this body's fids
var _mi: MeshInstance3D = null
var _pos_cache: Dictionary = {}          # fid -> PackedVector3Array (ABSOLUTE body coords; built once per facet)
var _col_cache: Dictionary = {}          # fid -> PackedColorArray
var _centre_cache: Dictionary = {}       # fid -> Array[3] cached centre direction (cheap; reused across builds)
var _emitted: Dictionary = {}            # fid -> true: the facets in the currently committed mesh
var _built := false
var _last_axis: Array = [0.0, 0.0, 0.0]  # the cull axis of the last build (gate visibility)

## Bind this ring to active-body index `bi` (e.g. FacetAtlas.body_index("moon")) and create the reused
## MeshInstance + a lit vertex-colour material (the airless Moon needs no atmosphere/tint shader). Idempotent.
func setup(bi: int) -> void:
	_bi = bi
	_fid_base = FacetAtlas.fid_base(bi)
	_fid_end = _fid_base + FacetAtlas.body_facet_count(bi)
	_r = FacetAtlas.r_of(_fid_base)
	if _mi == null:
		_mi = MeshInstance3D.new()
		_mi.name = "MoonFarRingMesh"
		_mi.material_override = _make_material()
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)

## Build the whole front-hemisphere ring for the current `cull_axis` (unit [x,y,z], ABSOLUTE body coords —
## the direction from the body centre toward the camera). Emits every facet whose centre direction lies within
## CAP_DEG of the axis, in canonical fid order, then computes GLOBAL smooth normals (SurfaceTool, C++). Replaces
## any prior mesh (make-before-break: the old mesh stays assigned until this one is committed). Synchronous — a
## promotion is a rare event with minutes of slack at any approach gear (§2), and the Moon's ~650-facet cap is a
## few-ms build; there is no per-frame cost (only re-called on an actual promotion, not every frame).
func build(cull_axis: Array) -> void:
	_last_axis = cull_axis
	var cap_cos := cos(deg_to_rad(CAP_DEG))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emitted.clear()
	var any := false
	for fid in range(_fid_base, _fid_end):
		var cd := _centre_dir(fid)
		if cd[0] * cull_axis[0] + cd[1] * cull_axis[1] + cd[2] * cull_axis[2] < cap_cos:
			continue                                       # back / beyond-cap facet — culled
		_ensure_cached(fid)
		_emit_cached(st, fid)
		_emitted[fid] = true
		any = true
	if any:
		st.generate_normals()
		_mi.mesh = st.commit()
	else:
		_mi.mesh = ArrayMesh.new()
	_built = true

## Free the WHOLE ring (eviction / demote): drop the per-facet caches and empty the mesh so both the CPU cache
## bytes and the GPU mesh bytes return to zero. The reused MeshInstance node stays (O(1), re-buildable) — only
## the per-facet data is released. After this gpu_bytes()==cpu_bytes()==0 (the lifetime cap the gate asserts).
func evict() -> void:
	_pos_cache.clear()
	_col_cache.clear()
	_centre_cache.clear()                            # the whole ring is freed — the cheap centre index rebuilds on next build
	_emitted.clear()
	if _mi != null:
		_mi.mesh = ArrayMesh.new()
	_built = false

## Place the whole (absolute) ring mesh via one rigid+scale transform (CosmosSky computes it to match the
## Moon impostor exactly). Cheap, main-thread; the mesh/caches are untouched (ZERO bytes) — only this node's
## transform changes, exactly like FacetFarRing.apply_scaled_placement.
func place(xform: Transform3D) -> void:
	transform = xform

## The airless Moon material: a plain lit vertex-colour StandardMaterial3D (no atmosphere shell, no clouds,
## no terminator-tint shader — the shell tint is an Earth-atmosphere feature). CULL_DISABLED because the
## placement basis may flip winding under the uniform scale, like FacetFarRing's far material.
func _make_material() -> Material:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0
	return m

## Compute + cache facet `fid`'s ABSOLUTE-coord terrain quad once — the Moon twin of FacetFarRing._ensure_cached:
## the planarized corners (facet_planar_corner, body-aware via the atlas), a CELLS grid bilerped across them,
## each grid point normalized to its true direction and sampled at the Moon datum r_of via moon_profile_at_dir,
## with radial relief and a moon regolith/maria/highlands colour. Pure/deterministic (SEED_MOON worldgen only).
func _ensure_cached(fid: int) -> void:
	if _pos_cache.has(fid):
		return
	var c0 := FacetAtlas.facet_planar_corner(fid, 0)
	var c1 := FacetAtlas.facet_planar_corner(fid, 1)
	var c2 := FacetAtlas.facet_planar_corner(fid, 2)
	var c3 := FacetAtlas.facet_planar_corner(fid, 3)
	var stride := CELLS + 1
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(CELLS)
			var t := float(gj) / float(CELLS)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var prof := TerrainConfig.moon_profile_at_dir(dx, dy, dz, _r)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE (node placed by transform)
			col.append(FarPalette.moon_color_for(int(prof.y)))
	_pos_cache[fid] = pos
	_col_cache[fid] = col

## Emit facet `fid`'s cached CELLS grid as a tri soup (two tris per cell, same winding + per-vertex colours as
## FacetFarRing._emit_cached), so the global generate_normals smooths across facet seams identically.
func _emit_cached(st: SurfaceTool, fid: int) -> void:
	var pos: PackedVector3Array = _pos_cache[fid]
	var col: PackedColorArray = _col_cache[fid]
	var stride := CELLS + 1
	for gj in range(CELLS):
		for gi in range(CELLS):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			st.set_color(col[i0]); st.add_vertex(pos[i0])
			st.set_color(col[i2]); st.add_vertex(pos[i2])
			st.set_color(col[i1]); st.add_vertex(pos[i1])
			st.set_color(col[i1]); st.add_vertex(pos[i1])
			st.set_color(col[i2]); st.add_vertex(pos[i2])
			st.set_color(col[i3]); st.add_vertex(pos[i3])

func _centre_dir(fid: int) -> Array:
	if _centre_cache.has(fid):
		return _centre_cache[fid]
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	var cd := [s[0] / ln, s[1] / ln, s[2] / ln]
	_centre_cache[fid] = cd
	return cd

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

# ------- gate / telemetry accessors -------

func is_built() -> bool: return _built
func emitted_count() -> int: return _emitted.size()
func is_emitted(fid: int) -> bool: return _emitted.has(fid)
func cached_facet_count() -> int: return _pos_cache.size()
func fid_base() -> int: return _fid_base
func fid_end() -> int: return _fid_end
func last_axis() -> Array: return _last_axis

## Triangle count of the committed mesh (0 when evicted / never built).
func triangle_count() -> int:
	if _mi == null or _mi.mesh == null:
		return 0
	var mesh: Mesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return 0
	var arr := mesh.surface_get_arrays(0)
	var vv: Variant = arr[Mesh.ARRAY_VERTEX]
	return (vv as PackedVector3Array).size() / 3

## The GPU-resident mesh bytes: the committed vertex count × the 40 B/vert ledger (position + normal + colour).
## Matches BodyLod.ring_bytes' GPU accounting and the §3 budget. 0 when evicted (empty mesh).
func gpu_bytes() -> int:
	return triangle_count() * 3 * BYTES_PER_VERT

## The REAL committed mesh array bytes, summed from the surface arrays actually uploaded (VERTEX + NORMAL +
## COLOR). A direct measurement (not the ledger estimate) so the budget gate proves the true upload size. 0 evicted.
func mesh_array_bytes() -> int:
	if _mi == null or _mi.mesh == null:
		return 0
	var mesh: Mesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return 0
	var arr := mesh.surface_get_arrays(0)
	var total := 0
	for idx in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR]:
		var a: Variant = arr[idx]
		if a is PackedVector3Array:
			total += (a as PackedVector3Array).size() * 12
		elif a is PackedColorArray:
			total += (a as PackedColorArray).size() * 16
	return total

## The real CPU-side per-facet cache bytes (position grids + colour grids + centre-dir cache). 0 when evicted
## (the caches are cleared). This is the whole persistent CPU cost of the ring — nothing else is retained.
func cpu_bytes() -> int:
	var total := 0
	for fid in _pos_cache:
		total += (_pos_cache[fid] as PackedVector3Array).size() * 12
		total += (_col_cache[fid] as PackedColorArray).size() * 16
	total += _centre_cache.size() * 3 * 8                # cached centre dirs (3 f64 each)
	return total
