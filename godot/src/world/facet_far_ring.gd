class_name FacetFarRing
extends Node3D
## COSMOS FP2 §5.2 / FP3 §6.1 — the planet rendered AROUND the active facet. Every non-active facet is drawn as
## a flat, low-res, terrain-coloured quad built (ONCE, cached) from its PLANARIZED corners in ABSOLUTE planet
## coords with radial relief (FP0's seam-glue). This node's transform = T_active⁻¹ (facet_transform(active)
## inverse), so the whole planet is re-placed into the active facet's flat render frame by ONE rigid transform —
## the player on the flat facet sees the faceted planet curve away, faces JOINING at the seams (no wedge).
##
## FP-S1(d) (docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md §4-R2 defect 4 / §8): a crossing's set_active USED to do a
## synchronous full 3456-facet rescan + re-emit + generate_normals + commit (plus first-time 25-noise-profile
## caching for every newly-front-hemisphere facet) in ONE main-thread frame — the same frame as the restream
## kickoff. That is a large part of the crossing stall. Now set_active is O(1): it updates ONLY the node transform
## (the mesh is in ABSOLUTE coords, so a rigid re-place keeps every cached facet correctly positioned) and marks a
## deferred rebuild. _process completes it OFF the crossing frame: it cache-warms newly-front-hemisphere facets
## under a per-frame ms budget (mirroring FarTerrain's discipline), then re-emits once. The headless gate drives it
## synchronously via force_rebuild(). Render-only, collision-free, voxel-worker-free (like FarTerrain).

const ENABLED := true
const CELLS := 4                     # heightmap cells per facet edge (far LOD) — k=24 facets are small
const RELIEF := 1.0                  # blocks of radial relief per (g − SEA_LEVEL)
const BACK_CULL := 0.0               # front hemisphere only — back-side facets sit below the surface horizon
const CAMERA_FAR := 9000.0           # the planet spans ~2R; the player camera far must reach it in faceted mode
const FOG_BEGIN := 2200.0            # fog only far out, so the whole planet reads
const WARM_BUDGET_MS := 3.0          # FP-S1(d): per-frame cache-warm budget for newly-front-hemisphere facets

var _active_fid := -1
var _mi: MeshInstance3D
var _pos_cache: Dictionary = {}      # fid -> PackedVector3Array (ABSOLUTE planet coords; built once per facet)
var _col_cache: Dictionary = {}      # fid -> PackedColorArray
var _centre_cache: Dictionary = {}   # FP-S1(d): fid -> Array[3] cached centre dir (cheap; no planar-corner recompute per rebuild)
# FP-S1(d) deferred-rebuild state
var _pending := false                # a crossing requested a rebuild; _process (or force_rebuild) completes it off-frame
var _emitted: Dictionary = {}        # fid -> true: the facets in the CURRENTLY committed mesh (visible-set gate check)
var _reemit_count := 0               # diagnostics: full re-emits done (gate: set_active does NOT re-emit synchronously)
# COSMOS FP-R0 SPIKE: facets rendered as REAL rotated voxel terrains (WorldManager fills this behind
# CubeSphere.FP_R0). Their flat quad is suppressed here so the real voxels don't z-fight the ring. Empty
# on the shipped build (FP_R0 off) → the ring draws every non-active facet exactly as before, byte-identical.
var _excluded: Dictionary = {}       # fid -> true (skipped in the visible set, same as the active facet is skipped)

func setup(active_fid: int) -> void:
	_active_fid = active_fid
	_mi = MeshInstance3D.new()
	_mi.name = "FacetFarRingMesh"
	_mi.material_override = _make_material()
	add_child(_mi)
	_rebuild_full()                  # initial build — synchronous (spawn is masked by the ShaderPrewarm hold)
	set_process(true)

## FP3 §6.1 / FP-S1(d) crossing: re-place the planet into facet `new_fid`'s render frame (rigid, O(1)) and DEFER the
## exclusion/terminator re-emit + any new-facet noise caching to _process (off the crossing frame, under a budget).
## The existing merged mesh is in ABSOLUTE coords, so the transform update alone keeps every cached facet correctly
## placed; only B's quad (now the active facet → should be excluded) and the just-left A's quad (now visible) plus a
## thin terminator band are transiently stale for the ≤1-2 frames until the deferred re-emit lands.
func set_active(new_fid: int) -> void:
	_active_fid = new_fid
	transform = FacetAtlas.facet_transform(_active_fid).affine_inverse()   # rigid re-place (cheap)
	_pending = true

## COSMOS FP-R0 SPIKE: hide these facets' flat quads (they are drawn as real rotated voxel terrains instead).
## Called only behind CubeSphere.FP_R0; on the shipped build nothing calls this so `_excluded` stays empty and the
## ring is byte-identical. Synchronous (a one-time spawn-setup call), unlike a crossing's deferred re-emit.
func set_excluded(fids: Array) -> void:
	_excluded.clear()
	for f in fids:
		_excluded[int(f)] = true
	force_rebuild()

## FP-M1c (docs/COSMOS-FP-M1-DESIGN.md §4.1): set the excluded flat-quad facets to the live neighbour pool and
## rebuild DEFERRED (budgeted _process) rather than synchronously — a pool spawn/retire/crossing must never pay a
## full ring regen on its own frame (§12.1c). No-op re-sets that leave the set unchanged skip the pending flag.
func set_pool_excluded(fids: Array) -> void:
	var next := {}
	for f in fids:
		next[int(f)] = true
	if next == _excluded:
		return
	_excluded = next
	_pending = true   # deferred rebuild (the crossing's set_active already re-placed the mesh rigidly)

## FP-S1(d): drive the deferred rebuild off the crossing frame. Cache-warm the newly-front-hemisphere facets under a
## per-frame ms budget; once they are all cached, do the single re-emit. Only active while a crossing is pending.
func _process(_dt: float) -> void:
	if not _pending:
		return
	var nrm := FacetAtlas.facet_normal64(_active_fid)
	if _warm_front(nrm):             # all front-hemisphere facets cached → safe to re-emit this frame
		_rebuild_full()

## Warm (noise-cache) every uncached front-hemisphere facet under WARM_BUDGET_MS. Returns true once none remain
## uncached (rebuild may proceed), false when the frame budget is spent (resume next frame). The scan itself is a
## cheap cached-dot classification; only _ensure_cached (25 sphere-profile samples) is budgeted.
func _warm_front(nrm: Array) -> bool:
	var k := FacetAtlas.K
	var t0 := Time.get_ticks_usec()
	var budget_us := int(WARM_BUDGET_MS * 1000.0)
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm):
					continue
				if _pos_cache.has(fid):
					continue
				_ensure_cached(fid)
				if Time.get_ticks_usec() - t0 > budget_us:
					return false     # budget spent — finish warming next frame
	return true

func _front_visible(fid: int, nrm: Array) -> bool:
	if fid == _active_fid:
		return false                 # the near voxel world already covers the active facet
	if _excluded.has(fid):
		return false                 # FP-R0 SPIKE: drawn as a real rotated voxel terrain, not a flat quad
	var cd := _centre_dir(fid)
	return cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] >= BACK_CULL

## The full scan + re-emit + commit (the OLD _rebuild). Runs at setup, from _process once warming completes, and
## from force_rebuild (the gate). NOT called synchronously by a crossing — that is the whole point of FP-S1(d).
func _rebuild_full() -> void:
	transform = FacetAtlas.facet_transform(_active_fid).affine_inverse()   # absolute → active-lattice render frame
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var k := FacetAtlas.K
	var nrm := FacetAtlas.facet_normal64(_active_fid)
	var tris := 0
	_emitted.clear()
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if not _front_visible(fid, nrm):
					continue
				_ensure_cached(fid)
				tris += _emit_cached(st, fid)
				_emitted[fid] = true
	st.generate_normals()
	_mi.mesh = st.commit()
	_reemit_count += 1
	_pending = false
	print("[FP2] facet far ring: %d triangles around facet %d (%d facets cached)" % [tris, _active_fid, _pos_cache.size()])

## FP-S1(d) gate helper: synchronously complete a pending deferred rebuild (what _process does over budgeted frames)
## so headless gates — which do not step frames — can assert the post-crossing visible set.
func force_rebuild() -> void:
	_rebuild_full()

# --- gate diagnostics ---
func is_rebuild_pending() -> bool: return _pending
func reemit_count() -> int: return _reemit_count
func is_emitted(fid: int) -> bool: return _emitted.has(fid)
func emitted_count() -> int: return _emitted.size()

# Compute + cache facet `fid`'s ABSOLUTE-coord terrain quad once (built from its planarized corners + radial relief).
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
			var prof := TerrainConfig.profile_at_dir(dx, dy, dz, FacetAtlas.R_BLOCKS)
			var g := int(prof.x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL)) * RELIEF
			pos.append(Vector3(bx + dx * relief, by + dy * relief, bz + dz * relief))   # ABSOLUTE (node placed by transform)
			col.append(FarPalette.color_for(g, int(prof.y), prof.w, g <= TerrainConfig.SEA_LEVEL))
	_pos_cache[fid] = pos
	_col_cache[fid] = col

func _emit_cached(st: SurfaceTool, fid: int) -> int:
	var pos: PackedVector3Array = _pos_cache[fid]
	var col: PackedColorArray = _col_cache[fid]
	var stride := CELLS + 1
	var n := 0
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
			n += 2
	return n

func _centre_dir(fid: int) -> Array:
	if _centre_cache.has(fid):
		return _centre_cache[fid]
	var cd := _facet_centre_dir(fid)
	_centre_cache[fid] = cd
	return cd

func _facet_centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _make_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED     # far ring: winding-agnostic (transforms may flip facets)
	m.roughness = 1.0
	return m

## Triangle count of the built ring mesh (gate).
func triangle_count() -> int:
	if _mi == null or _mi.mesh == null:
		return 0
	var mesh: ArrayMesh = _mi.mesh
	if mesh.get_surface_count() == 0:
		return 0
	var arr := mesh.surface_get_arrays(0)
	var vv: Variant = arr[Mesh.ARRAY_VERTEX]
	return (vv as PackedVector3Array).size() / 3
