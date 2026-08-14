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
	_mi.visible = not offsurf   # P0: on-surface only (the ≥48-block orbit exception is P2/FP_STRUCT_LOD)
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
	return _baked_bytes + mesh_b
