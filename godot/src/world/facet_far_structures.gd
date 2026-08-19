class_name FacetFarStructures
extends RefCounted
## COSMOS STRUCTURES P0 (docs/COSMOS-STRUCTURES-DESIGN.md §7) — the far-render tier for player-built structures.
## A straight clone of the FacetFarTrees shape (owned/stepped/sun-fed by the ONE FacetFarRing), but because each
## structure is a UNIQUE geometry, it renders ONE MERGED ArrayMesh per LOD band (NOT a MultiMesh — the gl_compat
## MultiMesh colour-slot trap [[voxiverse-far-trees-colorfix]] is structurally avoided). P0 ships LOD-A only (≤ 1
## draw; the +2-draw ledger leaves room for the P2 LOD-B band).
##
## THE STACK (mirrors the single-mesh V2/G3 tiers): ONE MeshInstance3D child of the ring — verts are the structure's
## fid-lattice cells mapped through FacetAtlas.lattice_to_world64 into RING-LOCAL coords (exactly like FacetFarTrees'
## instance placement), so the ring's own placement transform / SN3 scaled placement / anchor shifts apply for free
## (orbit-frame correctness inherited). The radial voxi_shade normal comes from a `planet_centre` uniform refreshed
## from render_centre() each step (a plain mesh's MODEL_MATRIX carries the ring transform — same law as the trees).
##
## REBUILD-ON-CHANGE (§7.1, the FP_FAR_TREES_DELTA law from day one): the merged mesh is rebuilt only when an input
## drifted — camera moved past STRUCT_DELTA_MOVE, the registry rev-sum changed (a structure was built/damaged/removed),
## the edit revision changed, or the near-handoff cull is mid-transition. A per-structure BAKE is cached by (root, rev)
## so an unchanged structure never re-decimates; a damaged one (rev bump) re-bakes and shows the hole within ~1-2 s.
##
## NEAR-HANDOFF CULL (§7.3): the SHARED `NearPresence.covered` predicate (the SAME "near meshed here ⇒ hide the far
## impostor" law the far-trees cull uses) probes each structure's footprint bbox over the uncertainty annulus
## [near_render_radius(), +64]; COVERED (STRUCT_HIDE_STREAK) hides the far model, NOT_COVERED (STRUCT_SHOW_STREAK)
## restores it, UNKNOWABLE never flips state. Inside near_render_radius() the near field owns the view (band floor);
## beyond +64 near can't reach so the model is emitted unprobed.
##
## NEVER-OOM (§8): `total_bytes()` (baked models + the merged band mesh) asserted ≤ STRUCT_BYTES_MAX; the merged mesh
## is triangle-capped at STRUCT_FAR_TRIS_MAX (nearest-first fill). Off ⇒ never constructed (byte-identical).

const STRUCT_DELTA_MOVE := 2.0                # blocks of camera motion that re-arm a rebuild (FT_DELTA_MIN_MOVE analogue)
const CULL_ANNULUS := 64.0                    # §7.3 probe band width above near_render_radius() (the near-reach shell)

var _ring: Node3D = null
var _mi: MeshInstance3D = null                # LOD-A merged band mesh (one draw)
var _mesh: ArrayMesh = null
var _material: ShaderMaterial = null
var _active_fid := -1

# wired queries (all Callables; unset ⇒ inert — the tier renders nothing / degrades, never crashes)
var _registry_query: Callable = Callable()    # () -> Array of structure records (StructureTracker.registry)
var _sampler: Callable = Callable()           # (fid, Vector3i) -> placed block id (WorldManager.structure_cell_at)
var _near_query: Callable = Callable()        # (fid, AABB) -> NearPresence COVERED|NOT_COVERED|UNKNOWABLE
var _edits_rev_query: Callable = Callable()   # () -> int (WorldManager.edit_count) — a chop re-arms within one step

# per-structure baked models: root -> {rev, verts:PackedVector3Array (ring-local), colors:PackedColorArray, tris, bytes}
var _baked: Dictionary = {}
var _baked_bytes := 0
# near-handoff cull state: root -> {hidden:bool, cover:int, uncover:int}
var _cull: Dictionary = {}
var _probe_cache: Dictionary = {}             # root -> NearPresence state, filled in the pure step pass, read by rebuild

# delta-gate latch
var _have_rebuilt := false
var _last_cam := Vector3.ZERO
var _last_rev_sum := -1
var _last_reg_count := -1
var _last_edits_rev := -1
var _last_cover_fp := 0
var _last_step_ms := 0

# telemetry / gate read-back
var _dbg_rebuild_count := 0
var _live_structures := 0
var _live_tris := 0
var _capped := false

# --- P2 (FP_STRUCT_LOD): the orbit-resident AGGREGATE tier -----------------------------------------------------------
# §7.4: a lone house is sub-pixel from orbit, but a VILLAGE footprint (~100-192 blocks) subtends several device px even
# at low orbit. When shell_offsurface() suspends the per-house LOD-A mesh, this LOD-B mesh renders one coarse box per
# settlement AGGREGATE whose union-bbox max-extent ≥ STRUCT_ORBIT_MIN — GEN houses grouped by their STRUCT_V village
# cell (derived from the record bbox — make_record is untouched), player builds each their own aggregate. A never-cull
# ObjectLod beacon floor (STRUCT_LOD_BEACON_PX) scales a blob that would fall below the floor back up to it, so a distant
# settlement never fully vanishes. Own MeshInstance3D (the §7.4 "2 draws: LOD-A + LOD-B"); created ONLY under
# FP_STRUCT_LOD ⇒ flag-off is byte-identical (the offsurface `return` is unchanged when _mi_agg is null).
var _mi_agg: MeshInstance3D = null
var _mesh_agg: ArrayMesh = null
var _agg_material: ShaderMaterial = null
var _agg_have := false
var _agg_last_cam := Vector3.ZERO
var _agg_last_reg := -1
var _agg_last_rev := -1
var _agg_last_kpx := 0.0
var _agg_last_ms := 0
var _agg_last_offsurf := false
var _live_aggregates := 0

# =====================================================================================================================
# Shader — HEAD + VoxiLight.shade_glsl() + TAIL. Vertex-colour ALBEDO × voxi_shade(radial_n, sun_dir); planet_centre
# a uniform (kept in the ONE shader family with the far-trees mesh shader even though a plain mesh could use NORMAL).
# =====================================================================================================================
const _HEAD := "shader_type spatial;
render_mode cull_disabled;
uniform vec3 planet_centre = vec3(0.0, 0.0, 0.0);
"
const _TAIL := "varying flat vec4 v_col;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = normalize(wp - planet_centre);
	v_col = vec4(COLOR.rgb * voxi_shade(n, sun_dir), 1.0);
}
void fragment() {
	ALBEDO = v_col.rgb;
}
"

static func shader_code() -> String:
	return _HEAD + VoxiLight.shade_glsl() + _TAIL

static func make_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = shader_code()
	sm.shader = sh
	# FP_FAR_TERMINATOR_WELD: seed from the shared last-live Sun, never the (1,0,0) fake-noon default.
	var seed := TierPlace.last_sun_dir() if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
	sm.set_shader_parameter("sun_dir", seed)
	if CubeSphere.FP_SHADE_UNIFIED:
		sm.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		sm.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return sm

## P2 (FP_STRUCT_LOD): the aggregate LOD-B material — UNLIT vertex colour. A settlement marker seen from orbit needs no
## radial voxi_shade (and the per-house shader's planet_centre normal is unreliable in the orbital-shell frame, which the
## suspended-on-surface P0 tier never exercised → it shaded the blobs to night-floor black). Unlit is frame-independent
## and always legible; a day/night shade is a polish follow-up.
static func _make_agg_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled;\nvarying flat vec4 v_col;\nvoid vertex() { v_col = COLOR; }\nvoid fragment() { ALBEDO = v_col.rgb; }\n"
	sm.shader = sh
	return sm

# =====================================================================================================================
# Construction — one MeshInstance3D child of the ring under FP_STRUCT_FAR (FacetFarRing.setup).
# =====================================================================================================================
func setup_instance(ring: Node3D, active_fid: int) -> void:
	_ring = ring
	_active_fid = active_fid
	_material = make_material()
	_mesh = ArrayMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "FacetFarStructures"
	_mi.mesh = _mesh
	_mi.material_override = _material
	# Verts are placed in ring-local ABSOLUTE-planet coords the shader moves; a CPU AABB can't predict them, so pin a
	# huge custom AABB (the far-trees convention) so the node is never wrongly frustum-culled.
	_mi.custom_aabb = AABB(Vector3(-12000.0, -12000.0, -12000.0), Vector3(24000.0, 24000.0, 24000.0))
	ring.add_child(_mi)
	# P2 (FP_STRUCT_LOD): the orbit-resident aggregate LOD-B mesh — a sibling MeshInstance sharing the ONE shader family
	# (voxi_shade boxes). Created ONLY under the flag ⇒ off is byte-identical (offsurface still returns with _mi_agg null).
	if CubeSphere.FP_STRUCT_LOD:
		_agg_material = _make_agg_material()
		_mesh_agg = ArrayMesh.new()
		_mi_agg = MeshInstance3D.new()
		_mi_agg.name = "FacetFarStructuresAgg"
		_mi_agg.mesh = _mesh_agg
		_mi_agg.material_override = _agg_material
		_mi_agg.custom_aabb = _mi.custom_aabb
		_mi_agg.visible = false
		ring.add_child(_mi_agg)

func set_active(new_fid: int) -> void:
	_active_fid = new_fid   # residency is camera-distance driven (rebuilt each step); crossing only re-seeds the centre

func set_sun_dir(sun_dir: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)

func sun_dir_telemetry() -> Vector3:
	return (_material.get_shader_parameter("sun_dir") if _material != null else Vector3(1.0, 0.0, 0.0))

func set_registry_query(q: Callable) -> void: _registry_query = q
func set_sampler(q: Callable) -> void: _sampler = q
func set_near_query(q: Callable) -> void: _near_query = q
func set_edits_rev_query(q: Callable) -> void: _edits_rev_query = q

func _current_edits_rev() -> int:
	return int(_edits_rev_query.call()) if _edits_rev_query.is_valid() else 0

# =====================================================================================================================
# Step — suspend on-surface↔off-surface (structures show ON-surface only, mirror of the trees), settle-gate, rate-cap,
# push planet_centre, then (delta-gated) rebuild the merged band mesh over the registered structures.
# =====================================================================================================================
func step(settled := true, credit_ok := true, cam_render := Vector3.ZERO) -> void:
	if _mi == null:
		return
	var offsurf := (_ring as FacetFarRing).shell_offsurface()
	_mi.visible = not offsurf   # P0: per-house LOD-A on-surface only
	# P2 (FP_STRUCT_LOD): the aggregate LOD-B tier takes over the DISTANT band — a settlement emits an aggregate blob when
	# it is beyond the per-house band (dist > STRUCT_FAR_MAX) OR the per-house tier is suspended off-surface. The two sets
	# are disjoint (per-house owns [R0, STRUCT_FAR_MAX] on-surface), so no double-render, and it works in BOTH the dev-fly
	# and orbital-shell regimes. Off-flag (_mi_agg null) the whole block is skipped and the shipped `if offsurf: return`
	# runs verbatim ⇒ byte-identical.
	if _mi_agg != null:
		_mi_agg.visible = true
		_step_aggregates(settled, credit_ok, cam_render, offsurf)
	if offsurf:
		return
	# FP_LOAD_DEFER settle gate + stream credit — no structure work during fresh-load pile-up (mirror of the trees).
	# FP_STRUCT_NEAR_GUARD §4.2 (#132): at credit 0 the same freeze leaves a far structure over its arrived near build
	# (double-render) and starves missing/dwell-restored structures. The guard relaxes ONLY the credit gate; the settle
	# gate, the STRUCT_STEP_MS rate cap and the delta gate below still bound the (cheap, per-rev-cached) rebuild, and its
	# _cull_emit pass fixes both sides. Off ⇒ the shipped `not credit_ok` return verbatim (byte-identical).
	if not _credit_gate_open(settled, credit_ok):
		return
	var now := Time.get_ticks_msec()
	if now - _last_step_ms < CubeSphere.STRUCT_STEP_MS:
		return
	_last_step_ms = now
	var centre := (_ring as FacetFarRing).render_centre()
	if _material != null:
		_material.set_shader_parameter("planet_centre", centre)
	var cam_abs := _cam_to_absolute(cam_render)
	var reg: Array = _registry_query.call() if _registry_query.is_valid() else []
	# Pure probe pass (§7.3): fill _probe_cache + the change fingerprint + whether any cull is mid-transition. No streak
	# mutation here (streaks advance only in the real rebuild) so the HIDE/SHOW dwell counts 'consecutive rebuilds'.
	var rev_sum := 0
	for rec in reg:
		rev_sum += int(rec["rev"])
	var cover_fp := _probe_pass(reg, cam_abs)
	# Delta gate (the forest-fps law): rebuild only when an input drifted OR a cull transition is pending.
	if not _inputs_changed(cam_abs, reg.size(), rev_sum, cover_fp):
		return
	_rebuild(reg, cam_abs)

func _cam_to_absolute(cam_render: Vector3) -> Vector3:
	if _ring == null:
		return cam_render
	return (_ring as Node3D).global_transform.affine_inverse() * cam_render

## FP_STRUCT_NEAR_GUARD §4.2: may the step proceed past the settle/credit gate? The SETTLE gate always holds (no work
## during fresh-load pile-up). The credit gate holds too — UNLESS the guard is on, which admits the (rate-capped +
## delta-gated + per-rev-cached) structures step at credit 0 so the near-handoff cull + gap-fill can re-run. Off ⇒
## exactly `settled and credit_ok` (the shipped gate, byte-identical). Extracted so the gate can drive it directly.
func _credit_gate_open(settled: bool, credit_ok: bool) -> bool:
	return settled and (credit_ok or CubeSphere.FP_STRUCT_NEAR_GUARD)

## True (and re-latch) iff any rebuild input drifted since the last real rebuild, OR a near-handoff cull is mid-
## transition (a probe disagrees with the committed visibility — the streak still needs to advance, and a stable
## fingerprint would otherwise freeze it short of the threshold). First call always rebuilds.
func _inputs_changed(cam_abs: Vector3, reg_count: int, rev_sum: int, cover_fp: int) -> bool:
	var changed := (not _have_rebuilt) \
		or cam_abs.distance_to(_last_cam) >= STRUCT_DELTA_MOVE \
		or reg_count != _last_reg_count \
		or rev_sum != _last_rev_sum \
		or _current_edits_rev() != _last_edits_rev \
		or cover_fp != _last_cover_fp \
		or _cull_pending
	if changed:
		_have_rebuilt = true
		_last_cam = cam_abs
		_last_reg_count = reg_count
		_last_rev_sum = rev_sum
		_last_edits_rev = _current_edits_rev()
		_last_cover_fp = cover_fp
	return changed

# --- near-handoff cull (§7.3) ---------------------------------------------------------------------------------------
var _cull_pending := false

## Pure pass: probe every in-annulus structure, cache the tri-state, XOR a stable hash over COVERED ones (the change
## fingerprint so a mesh landing under a still camera re-arms), and set `_cull_pending` if any probe disagrees with the
## committed visibility (so the streak can advance). NEVER mutates streaks. Returns the fingerprint.
func _probe_pass(reg: Array, cam_abs: Vector3) -> int:
	_probe_cache.clear()
	_cull_pending = false
	if not _near_query.is_valid():
		return 0
	var r0 := float(TerrainConfig.near_render_radius())
	var fp := 0
	for rec in reg:
		var fid: int = int(rec["fid"])
		var dist := _structure_dist(rec, cam_abs)
		if dist < r0 or dist > r0 + CULL_ANNULUS:
			continue                                   # band floor / beyond near reach — no probe
		var st := int(_near_query.call(fid, _footprint(rec)))
		_probe_cache[int(rec["root"])] = st
		var hidden: bool = _cull.has(int(rec["root"])) and bool(_cull[int(rec["root"])]["hidden"])
		if st == NearPresence.COVERED:
			fp ^= _root_hash(int(rec["root"]))
			if not hidden:
				_cull_pending = true                   # will hide after the streak
		elif st == NearPresence.NOT_COVERED:
			if hidden:
				_cull_pending = true                   # will restore after the streak
	return fp

## Advance the cull streak for `rec` from its cached probe and return whether the far model is currently EMITTED.
## COVERED → hide after STRUCT_HIDE_STREAK; NOT_COVERED → restore after STRUCT_SHOW_STREAK; UNKNOWABLE → no change.
func _cull_emit(rec: Dictionary, cam_abs: Vector3) -> bool:
	var root := int(rec["root"])
	var dist := _structure_dist(rec, cam_abs)
	var r0 := float(TerrainConfig.near_render_radius())
	if dist < r0:
		return false                                   # band floor: the near field owns the view (no far model)
	if dist > r0 + CULL_ANNULUS:
		return true                                    # beyond near reach — emit, no cull
	var st := int(_probe_cache.get(root, NearPresence.UNKNOWABLE))
	var cs: Dictionary = _cull.get(root, {"hidden": false, "cover": 0, "uncover": 0})
	if st == NearPresence.COVERED:
		cs["cover"] = int(cs["cover"]) + 1
		cs["uncover"] = 0
		if int(cs["cover"]) >= CubeSphere.STRUCT_HIDE_STREAK:
			cs["hidden"] = true
	elif st == NearPresence.NOT_COVERED:
		cs["uncover"] = int(cs["uncover"]) + 1
		cs["cover"] = 0
		if int(cs["uncover"]) >= CubeSphere.STRUCT_SHOW_STREAK:
			cs["hidden"] = false
	# UNKNOWABLE: leave streaks + hidden unchanged (never flip on an unanswerable probe — the shared invariant).
	_cull[root] = cs
	return not bool(cs["hidden"])

func _footprint(rec: Dictionary) -> AABB:
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	return AABB(Vector3(bmin), Vector3(bmax - bmin) + Vector3.ONE)

func _structure_dist(rec: Dictionary, cam_abs: Vector3) -> float:
	return cam_abs.distance_to(_structure_centre(rec))

func _structure_centre(rec: Dictionary) -> Vector3:
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	var cx := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
	var cy := (float(bmin.y) + float(bmax.y) + 1.0) * 0.5
	var cz := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
	# FP_FT_FRAME_WELD §7: lift the distance-cull centre onto the sphere too, so it tracks the lifted model (datum_lift 0
	# unless FP_DATUM_BAKE → byte-identical off). Keeps the distance banding consistent with the welded verts above.
	if CubeSphere.FP_FT_FRAME_WELD:
		cy += FacetAtlas.datum_lift(int(rec["fid"]), cx, cz)
	var w := FacetAtlas.lattice_to_world64(int(rec["fid"]), cx, cy, cz)
	return Vector3(float(w[0]), float(w[1]), float(w[2]))

static func _root_hash(root: int) -> int:
	var n := (root * 2654435761) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	return n ^ (n >> 16)

# --- merged-band rebuild --------------------------------------------------------------------------------------------

## Rebuild the ONE merged LOD-A ArrayMesh: for each registered structure in the band [near_render_radius, STRUCT_FAR_MAX]
## that the near-handoff cull leaves visible, ensure its cached bake (re-baked on rev change) and append its ring-local
## verts/colours, nearest-first, under the STRUCT_FAR_TRIS_MAX cap. One surface swap.
func _rebuild(reg: Array, cam_abs: Vector3) -> void:
	_dbg_rebuild_count += 1
	_evict_stale_bakes(reg)
	# nearest-first so the tri cap keeps the closest (most visible) structures
	var ordered := reg.duplicate()
	ordered.sort_custom(func(a, b): return _structure_dist(a, cam_abs) < _structure_dist(b, cam_abs))
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var tris := 0
	var count := 0
	var capped := false
	for rec in ordered:
		var dist := _structure_dist(rec, cam_abs)
		if dist > CubeSphere.STRUCT_FAR_MAX:
			continue
		if not _cull_emit(rec, cam_abs):
			continue
		var bake := _ensure_bake(rec)
		if bake.is_empty() or int(bake["tris"]) == 0:
			continue
		if tris + int(bake["tris"]) > CubeSphere.STRUCT_FAR_TRIS_MAX:
			capped = true
			break
		verts.append_array(bake["verts"])
		colors.append_array(bake["colors"])
		tris += int(bake["tris"])
		count += 1
	_commit_mesh(verts, colors)
	_live_structures = count
	_live_tris = tris
	_capped = capped
	if capped:
		print("  FacetFarStructures: STRUCT_FAR_TRIS_MAX (", CubeSphere.STRUCT_FAR_TRIS_MAX, ") hit (nearest-first) — coarsen or evict")

func _commit_mesh(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	_mesh.clear_surfaces()
	if verts.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mesh.surface_set_material(0, _material)

## Ensure a cached bake for `rec` at its current rev; (re)decimate + face-cull + lattice→world if missing/stale. The
## verts are RING-LOCAL (lattice_to_world64) so the merged mesh needs no per-rebuild transform (the frame is frozen).
func _ensure_bake(rec: Dictionary) -> Dictionary:
	var root := int(rec["root"])
	var rev := int(rec["rev"])
	var cached: Variant = _baked.get(root)
	if cached != null and int((cached as Dictionary)["rev"]) == rev:
		return cached
	if cached != null:
		_baked_bytes -= int((cached as Dictionary)["bytes"])
	# NEVER-OOM guard: if the baked store is already at the ceiling, don't grow it (degrade — the model just isn't far-
	# rendered this pass; the tri cap + registry cap keep this rare).
	if _baked_bytes >= CubeSphere.STRUCT_BYTES_MAX:
		return {}
	var fid: int = int(rec["fid"])
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	if not _sampler.is_valid():
		return {}
	var dec := StructDecimator.decimate(fid, bmin, bmax, _sampler)
	var lat := StructDecimator.bake_lattice(dec)
	var lverts: PackedVector3Array = lat["verts"]
	var wverts := PackedVector3Array()
	wverts.resize(lverts.size())
	for i in range(lverts.size()):
		var v := lverts[i]
		# FP_FT_FRAME_WELD §7 (task #131): the far structure model was baked on the facet PLANE (no FS2′ datum lift), so it
		# floated/buried up to ±5.5 blk vs the near voxel build — the identical omission the far trees had. datum_lift
		# returns 0 unless FP_DATUM_BAKE (byte-identical off). Lift is along n̂; the lattice basis is already carried by
		# lattice_to_world64, so — unlike the trees — there is no separate orientation defect (each vert is placed directly).
		var vy := v.y
		if CubeSphere.FP_FT_FRAME_WELD:
			vy += FacetAtlas.datum_lift(fid, v.x, v.z)
		var w := FacetAtlas.lattice_to_world64(fid, v.x, vy, v.z)
		wverts[i] = Vector3(float(w[0]), float(w[1]), float(w[2]))
	var tris: int = int(lat["tris"])
	var bytes := wverts.size() * (3 * 4 + 4 * 4)   # pos (3 f32) + colour (4 f32) per vertex
	var out := {"rev": rev, "verts": wverts, "colors": lat["colors"], "tris": tris, "bytes": bytes}
	_baked[root] = out
	_baked_bytes += bytes
	return out

func _evict_stale_bakes(reg: Array) -> void:
	if _baked.is_empty():
		return
	var live := {}
	for rec in reg:
		live[int(rec["root"])] = true
	var drop: Array = []
	for root in _baked.keys():
		if not live.has(root):
			drop.append(root)
	for root in drop:
		_baked_bytes -= int(_baked[root]["bytes"])
		_baked.erase(root)
		_cull.erase(root)

# --- P2 aggregate tier (FP_STRUCT_LOD): the orbit-resident settlement blobs ------------------------------------------

## Off-surface step: settle/credit/rate/delta-gated rebuild of the aggregate LOD-B mesh. The camera intrinsics (fov +
## device height ⇒ K_px) come from the live Camera3D under the ring (the FacetFarObjects plumbing), so the beacon floor
## is a true angular-size floor. No camera ⇒ kpx 0 ⇒ blobs render at true size with no beacon scaling (still visible).
func _step_aggregates(settled: bool, credit_ok: bool, cam_render: Vector3, offsurf: bool) -> void:
	if not _credit_gate_open(settled, credit_ok):
		return
	var now := Time.get_ticks_msec()
	if now - _agg_last_ms < CubeSphere.STRUCT_STEP_MS:
		return
	_agg_last_ms = now
	var centre := (_ring as FacetFarRing).render_centre()
	if _material != null:
		_material.set_shader_parameter("planet_centre", centre)
	var cam_abs := _cam_to_absolute(cam_render)
	var reg: Array = _registry_query.call() if _registry_query.is_valid() else []
	var kpx := _camera_kpx()
	var rev_sum := 0
	for rec in reg:
		rev_sum += int(rec["rev"])
	# Delta gate (the forest-fps law, aggregate latch): rebuild only when the camera moved past STRUCT_DELTA_MOVE, the
	# registry count / rev-sum changed, the projection scale (kpx, i.e. fov/zoom) drifted, or the offsurf regime flipped
	# (which changes which settlements emit — all of them off-surface, only the > STRUCT_FAR_MAX ones on-surface).
	if _agg_have \
			and cam_abs.distance_to(_agg_last_cam) < STRUCT_DELTA_MOVE \
			and reg.size() == _agg_last_reg \
			and rev_sum == _agg_last_rev \
			and absf(kpx - _agg_last_kpx) < 0.5 \
			and offsurf == _agg_last_offsurf:
		return
	_agg_have = true
	_agg_last_cam = cam_abs
	_agg_last_reg = reg.size()
	_agg_last_rev = rev_sum
	_agg_last_kpx = kpx
	_agg_last_offsurf = offsurf
	_rebuild_aggregates(reg, cam_abs, kpx, offsurf)

## px-per-radian from the live Camera3D under the ring (0 if none — blobs then render at true size, no beacon scaling).
func _camera_kpx() -> float:
	if _ring == null:
		return 0.0
	var vp := (_ring as Node3D).get_viewport()
	if vp == null:
		return 0.0
	var cam := vp.get_camera_3d()
	if cam == null:
		return 0.0
	var vh := float(vp.get_visible_rect().size.y)
	return ObjectLod.k_px(vh, deg_to_rad(cam.fov))

## Group the registry into settlement aggregates, keep those whose union-bbox max-extent ≥ STRUCT_ORBIT_MIN, and emit one
## beacon-floored coarse box each into the merged LOD-B mesh (nearest-first under the shared tri cap).
func _rebuild_aggregates(reg: Array, cam_abs: Vector3, kpx: float, offsurf: bool) -> void:
	_dbg_rebuild_count += 1
	var groups := _aggregate_groups(reg)
	# nearest-first so the tri cap keeps the closest settlements
	groups.sort_custom(func(a, b): return cam_abs.distance_to(a["centre_w"]) < cam_abs.distance_to(b["centre_w"]))
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var tris := 0
	var count := 0
	for g in groups:
		# Disjoint handoff with the per-house LOD-A: on-surface it owns [R0, STRUCT_FAR_MAX], so the aggregate emits only
		# BEYOND that band; off-surface the per-house tier is suspended, so the aggregate emits every settlement.
		if not offsurf and cam_abs.distance_to(g["centre_w"]) <= CubeSphere.STRUCT_FAR_MAX:
			continue
		if tris + 12 > CubeSphere.STRUCT_FAR_TRIS_MAX:
			break
		_append_aggregate_box(verts, colors, g, cam_abs, kpx)
		tris += 12
		count += 1
	_commit_agg_mesh(verts, colors)
	_live_aggregates = count

## One aggregate per settlement: GEN houses grouped by their STRUCT_V village cell (derived from the record bbox — the
## record shape is untouched), each player structure its own aggregate. Returns [{fid, bmin, bmax, color, centre_w}] for
## groups meeting the STRUCT_ORBIT_MIN extent bar (a lone hut is correctly sub-pixel and excluded).
func _aggregate_groups(reg: Array) -> Array:
	var acc := {}
	for rec in reg:
		var fid: int = int(rec["fid"])
		var bmin: Vector3i = rec["bmin"]
		var bmax: Vector3i = rec["bmax"]
		var key: String
		if int(rec.get("source", -1)) == StructureGen.SOURCE_GEN:
			var vx := floori(float(bmin.x) / float(StructureGen.STRUCT_V))
			var vz := floori(float(bmin.z) / float(StructureGen.STRUCT_V))
			key = "g%d_%d_%d" % [fid, vx, vz]
		else:
			key = "p%d" % int(rec["root"])
		if acc.has(key):
			var e: Dictionary = acc[key]
			e["bmin"] = Vector3i(mini(e["bmin"].x, bmin.x), mini(e["bmin"].y, bmin.y), mini(e["bmin"].z, bmin.z))
			e["bmax"] = Vector3i(maxi(e["bmax"].x, bmax.x), maxi(e["bmax"].y, bmax.y), maxi(e["bmax"].z, bmax.z))
		else:
			acc[key] = {"fid": fid, "bmin": bmin, "bmax": bmax}
	var out: Array = []
	for key in acc.keys():
		var e: Dictionary = acc[key]
		var bmin: Vector3i = e["bmin"]
		var bmax: Vector3i = e["bmax"]
		var dx := bmax.x - bmin.x + 1
		var dy := bmax.y - bmin.y + 1
		var dz := bmax.z - bmin.z + 1
		if maxi(dx, maxi(dy, dz)) < CubeSphere.STRUCT_ORBIT_MIN:
			continue                                            # sub-pixel from orbit — honestly excluded
		var fid: int = int(e["fid"])
		var cx := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
		var cy := (float(bmin.y) + float(bmax.y) + 1.0) * 0.5
		var cz := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
		out.append({
			"fid": fid, "bmin": bmin, "bmax": bmax,
			"color": Color(0.45, 0.32, 0.20),                   # unlit tan-brown roofs — a settlement reads as buildings from orbit
			"centre_w": _lattice_world(fid, cx, cy, cz),
		})
	return out

## Append the 12-triangle box for aggregate `g`, beacon-floored: if its projected size falls below STRUCT_LOD_BEACON_PX,
## the box is scaled about its centroid (in lattice space) so it projects at exactly the floor (never-cull). Verts are
## ring-local (lattice_to_world64, datum-lifted like the per-house bake) so the frozen-frame merged mesh needs no transform.
func _append_aggregate_box(verts: PackedVector3Array, colors: PackedColorArray, g: Dictionary, cam_abs: Vector3, kpx: float) -> void:
	var fid: int = int(g["fid"])
	var bmin: Vector3i = g["bmin"]
	var bmax: Vector3i = g["bmax"]
	var cx := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
	var cy := (float(bmin.y) + float(bmax.y) + 1.0) * 0.5
	var cz := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
	var hx := (float(bmax.x) - float(bmin.x) + 1.0) * 0.5
	var hy := (float(bmax.y) - float(bmin.y) + 1.0) * 0.5
	var hz := (float(bmax.z) - float(bmin.z) + 1.0) * 0.5
	# Beacon floor: scale the half-extents so the box projects at ≥ STRUCT_LOD_BEACON_PX (ObjectLod law).
	var scale := 1.0
	if kpx > 0.0:
		var r := maxf(hx, maxf(hy, hz))
		var d := cam_abs.distance_to(g["centre_w"])
		var proj := ObjectLod.proj_px(r, d, kpx)
		if proj > 0.0 and proj < CubeSphere.STRUCT_LOD_BEACON_PX:
			scale = CubeSphere.STRUCT_LOD_BEACON_PX / proj
	hx *= scale
	hy *= scale
	hz *= scale
	# 8 corners in lattice space → ring-local world (datum-lifted y, exactly the per-house bake convention).
	var c := PackedVector3Array()
	c.resize(8)
	var i := 0
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				c[i] = _lattice_world(fid, cx + sx * hx, cy + sy * hy, cz + sz * hz)
				i += 1
	# corner index = (sx,sy,sz) bit pattern: bit2=sx, bit1=sy, bit0=sz. 6 faces, 12 tris, outward winding.
	var col: Color = g["color"]
	var faces := [
		[0, 1, 3, 2],   # -X
		[4, 6, 7, 5],   # +X
		[0, 4, 5, 1],   # -Y
		[2, 3, 7, 6],   # +Y
		[0, 2, 6, 4],   # -Z
		[1, 5, 7, 3],   # +Z
	]
	for f in faces:
		_quad(verts, colors, c[f[0]], c[f[1]], c[f[2]], c[f[3]], col)

func _quad(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	verts.append(a); verts.append(b); verts.append(c)
	verts.append(a); verts.append(c); verts.append(d)
	for _k in range(6):
		colors.append(col)

## Lattice (fid, x, y, z) → ring-local world, datum-lifted on y under FP_FT_FRAME_WELD (byte-identical off, 0 lift).
func _lattice_world(fid: int, x: float, y: float, z: float) -> Vector3:
	var vy := y
	if CubeSphere.FP_FT_FRAME_WELD:
		vy += FacetAtlas.datum_lift(fid, x, z)
	var w := FacetAtlas.lattice_to_world64(fid, x, vy, z)
	return Vector3(float(w[0]), float(w[1]), float(w[2]))

func _commit_agg_mesh(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	_mesh_agg.clear_surfaces()
	if verts.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	_mesh_agg.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mesh_agg.surface_set_material(0, _agg_material)

func live_aggregates() -> int: return _live_aggregates

# --- telemetry / ledger ---------------------------------------------------------------------------------------------
func rebuild_count() -> int: return _dbg_rebuild_count
func live_structures() -> int: return _live_structures
func live_tris() -> int: return _live_tris
func draw_count() -> int: return 1                     # P0: LOD-A only (≤ the +2 ledger; P2 adds LOD-B)

## NEVER-OOM ledger (§8): baked models + the merged band mesh vertex buffer. Asserted ≤ STRUCT_BYTES_MAX by the gate.
func total_bytes() -> int:
	var mesh_b := 0
	if _mesh != null and _mesh.get_surface_count() > 0:
		var a := _mesh.surface_get_arrays(0)
		mesh_b = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * (3 * 4 + 4 * 4)
	# P2 (FP_STRUCT_LOD): the aggregate LOD-B vertex buffer (null off ⇒ 0, byte-identical).
	if _mesh_agg != null and _mesh_agg.get_surface_count() > 0:
		var ag := _mesh_agg.surface_get_arrays(0)
		mesh_b += (ag[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * (3 * 4 + 4 * 4)
	return _baked_bytes + mesh_b
