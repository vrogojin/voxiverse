class_name FacetFarObjects
extends RefCounted
## COSMOS-OBJECT-LOD P1 (docs/COSMOS-OBJECT-LOD-DESIGN.md, FP_OBJ_LOD_DEBRIS) — the far-render tier for discrete
## physical objects (VoxelBody debris now). It consumes the PURE P0 law (ObjectLod) — never re-derives it — and draws
## each far object as either a camera-facing CARD or a beacon DOT, via TWO MultiMeshes childed to the FacetFarRing so
## they inherit the ring's placement/scale for free (the frame the near cubes render in). P1 handles DOT + CARD only;
## the StructDecimator MESH rung is P2 (treated as CARD here), CLASS_SPACE beacons + planet occlusion are P3.
##
## MIRRORS FacetFarTrees (godot/src/world/facet_far_trees.gd) for every shipped-machinery invariant:
##  - two MultiMeshInstance3D children of the ring, `use_colors=false, use_custom_data=true` ⇒ stride 16
##    (12 TRANSFORM_3D floats + 4 INSTANCE_CUSTOM) — the SAME layout as the card MM (facet_far_trees.gd:43-45,463-466).
##    We deliberately DO NOT enable the color slot, side-stepping the gl_compat stride-20 colors+custom aliasing trap
##    (facet_far_trees.gd:375-379/493-496); the per-instance tint/alpha/size ride in INSTANCE_CUSTOM instead.
##  - whole-buffer `set_buffer` only, NEVER set_instance_transform after set_buffer (the no-op trap,
##    facet_far_trees.gd:704-706); `visible_instance_count` bounds the live set.
##  - a huge custom_aabb so the absolute-placed instances are never wrongly frustum-culled (facet_far_trees.gd:474).
##
## FRAME MAPPING (#131 frame-weld class, must-fix #2). Each object's `global_transform` is planet-absolute (Godot
## global space); the MMIs are children of the ring, which renders at `ring.global_transform`. So an instance whose
## buffer origin is P renders at `ring.global_transform · P`. To land it at the object's true world centre C we write
## P = ring.global_transform.affine_inverse() · C (the EXPLICIT map into the tier parent's space — round-trips for ANY
## ring rotation/scale/translation, so it survives a cube-face fold / SN3 scale). The gate asserts parent·P == C on a
## synthetic ring transform. The card SIZE is in WORLD units (the billboard reads INV_VIEW_MATRIX unit axes + a world
## half-size from INSTANCE_CUSTOM.x, NOT the model-matrix scale), so a scaled ring never distorts a debris speck.
##
## L0-HIDE (must-fix #1). While a far card/dot stands in for an object its own VoxelBody mesh must be HIDDEN. VoxelBody
## `_rebuild()` queue_frees + recreates that MeshInstance3D `visible=true`, silently undoing the hide — so we bump the
## body's `_obj_rev` there and RE-APPLY the hide here whenever the rev changes (or the desired state changes). A near
## (L0/FULL) object is shown (set_far_hidden(false)).
##
## NEVER-OOM (decision 3): the live instance set is bounded by ObjectLod caps AND a byte budget (priority = projected
## size descending, so the largest objects survive eviction). Dormant bodies snapshot once; awake bodies rewrite only
## when the accumulated screen-motion ≥ MOTION_EPS_PX (else the last buffer persists — no GPU churn on a still scene).

const STRIDE := 16                 # 12 TRANSFORM_3D floats + 4 INSTANCE_CUSTOM (use_colors=false) — mirrors card MM
const KIND_DOT := 0.0
const KIND_CARD := 1.0
const MOTION_EPS_PX := 0.5         # awake body rewrites only when its screen centre moved ≥ this (design §P1)
const CAM_EPS := 0.25              # camera move (blocks) that forces a rewrite regardless of per-object motion
# P3 (FP_OBJ_LOD_SPACE): clamp a CLASS_SPACE beacon to this eye-distance (blocks) so it never approaches the far
# plane. D_SKY (cosmos_sky.gd:27) is where the Sun/Moon impostors sit and is well inside the ≥9000 orbital clip —
# a distant space beacon placed among the sky shell is both depth-safe and thematically correct. Its on-screen
# angular size is preserved by beacon_placement regardless of the clamp (the gate asserts it).
const BEACON_CLAMP_DIST := 8000.0

# The shared unit billboard quad (corners at ±1 in XY, z=0) — one triangle pair. Built once; the vertex shader
# billboards + scales it by the per-instance world half-size, so the full quad spans 2·half_size (a diameter).
static var _quad_mesh: ArrayMesh = null

var _ring: Node3D = null
var _registry: ObjectRegistry = null
var _budget_bytes := ObjectLod.OBJ_LOD_BYTES_MAX
var _material: ShaderMaterial = null

# P3 (FP_OBJ_LOD_SPACE): occluding body spheres in the SAME world frame as the camera / object centres. Each entry
# is {"center": Vector3, "radius": float}. Empty ⇒ no occlusion test (the P1 default). Set per frame by the owner
# (WorldManager, planet render centre + voxel radius). Read only inside the FP_OBJ_LOD_SPACE branch ⇒ byte-off.
var _occluders: Array = []

# P3 live-debug (FP_OBJ_LOD_SPACE): a one-line diagnostic of the CLASS_SPACE object's frame state, surfaced by
# PerfHUD so it's readable in a screenshot (print() is browser-console-only). Written each _compute; empty off.
static var dbg := ""

var _dot_mmi: MultiMeshInstance3D = null
var _dot_mm: MultiMesh = null
var _card_mmi: MultiMeshInstance3D = null
var _card_mm: MultiMesh = null

# Per-object latched state (keyed by instance id).
var _prev_rep: Dictionary = {}         # id -> last ObjectLod rep (for rung_hyst latching)
var _far_hidden_state: Dictionary = {} # id -> bool last set_far_hidden requested
var _rev_seen: Dictionary = {}         # id -> body rev at the last hide application (must-fix #1)
var _last_center: Dictionary = {}      # id -> Vector3 world centre at the last buffer write (motion skip)

# Last-frame gate/telemetry read-back.
var _last_cam := Vector3(INF, INF, INF)
var _last_kpx := 0.0
var _last_ids: Array = []
var _dbg_card_live := 0
var _dbg_dot_live := 0
var _dbg_evicted := 0
var _dbg_rebuilds := 0

# =====================================================================================================================
# Shader — an unlit, camera-facing billboard. World-unit sizing (INV_VIEW_MATRIX axes × INSTANCE_CUSTOM.x) so the ring
# scale never distorts the card; per-pixel dither DISCARD against INSTANCE_CUSTOM.y (the fade alpha — gl_compat-safe,
# no alpha-sort, exactly the far-tree card dissolve); tint = debris_tint × INSTANCE_CUSTOM.z (brightness).
#   INSTANCE_CUSTOM = (world_half_size, fade_alpha, brightness, kind)
# =====================================================================================================================
const _SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 debris_tint = vec3(0.52, 0.47, 0.42);   // CARD: a lighter neutral rock/hull grey (was muddy brown 0.42,0.34,0.24)
uniform vec3 beacon_tint = vec3(1.00, 0.96, 0.86);   // DOT: a bright warm-white star/beacon so a distant space object POPS
varying flat float v_alpha;
varying flat float v_bright;
varying flat float v_kind;                            // INSTANCE_CUSTOM.w: 0 = DOT (beacon), 1 = CARD
float _obj_dither(vec2 fc) { return fract(sin(dot(floor(fc), vec2(12.9898, 78.233))) * 43758.5453); }
void vertex() {
	float hs = INSTANCE_CUSTOM.x;
	v_alpha = INSTANCE_CUSTOM.y;
	v_bright = INSTANCE_CUSTOM.z;
	v_kind = INSTANCE_CUSTOM.w;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 wpos = origin + (VERTEX.x * right + VERTEX.y * up) * hs;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(wpos, 1.0));
}
void fragment() {
	if (_obj_dither(FRAGCOORD.xy) > v_alpha) discard;
	vec3 tint = (v_kind < 0.5) ? beacon_tint : debris_tint;   // DOT = bright beacon, CARD = neutral hull
	ALBEDO = tint * v_bright;
}
"

static func make_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _SHADER
	sm.shader = sh
	return sm

static func _build_quad() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var v := [Vector3(-1, -1, 0), Vector3(-1, 1, 0), Vector3(1, 1, 0), Vector3(1, -1, 0)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3(0, 0, 1))
		st.add_vertex(v[i])
	var m := ArrayMesh.new()
	st.commit(m)
	return m

# =====================================================================================================================
# Construction
# =====================================================================================================================

func setup(ring: Node3D, registry: ObjectRegistry, budget_bytes := ObjectLod.OBJ_LOD_BYTES_MAX) -> void:
	_ring = ring
	_registry = registry
	_budget_bytes = mini(budget_bytes, ObjectLod.OBJ_LOD_BYTES_MAX)
	_material = make_material()
	if _quad_mesh == null:
		_quad_mesh = _build_quad()
	_dot_mm = _make_mm(ObjectLod.DOT_CAP)
	_dot_mmi = _make_mmi(_dot_mm, "FacetFarObjectsDots")
	_card_mm = _make_mm(ObjectLod.CARD_INST_CAP)
	_card_mmi = _make_mmi(_card_mm, "FacetFarObjectsCards")
	if ring != null:
		ring.add_child(_dot_mmi)
		ring.add_child(_card_mmi)

func _make_mm(cap: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false            # stride 16 (12 xform + 4 custom); side-steps the gl_compat colors+custom trap
	mm.use_custom_data = true
	mm.mesh = _quad_mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	return mm

func _make_mmi(mm: MultiMesh, node_name: String) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = _material
	# Instances are placed in the front hemisphere in absolute coords the CPU AABB can't predict — pin a huge custom
	# AABB so the node is never wrongly frustum-culled (facet_far_trees.gd:474).
	mmi.custom_aabb = AABB(Vector3(-12000.0, -12000.0, -12000.0), Vector3(24000.0, 24000.0, 24000.0))
	return mmi

# =====================================================================================================================
# Per-frame tick (live) — fetch the live Camera3D (fov + device height ⇒ K_px), dirty-gate, route + apply.
# =====================================================================================================================

## P3 (FP_OBJ_LOD_SPACE): set the occluding body spheres (world frame). Each entry {"center": Vector3, "radius":
## float}. Only consulted inside the FP_OBJ_LOD_SPACE / CLASS_SPACE branch — a no-op influence when the flag is off.
func set_occluders(occ: Array) -> void:
	_occluders = occ

## True iff the eye→center segment is blocked by ANY registered occluder body (P3 must-fix #4).
func _beacon_occluded(eye: Vector3, center: Vector3) -> bool:
	for b in _occluders:
		if ObjectLod.beacon_occluded(eye, center, b["center"] as Vector3, float(b["radius"])):
			return true
	return false

## `cam` is the live Camera3D. `viewport_h_px` is the device (drawable) viewport height. No-op if not set up.
func step(cam: Camera3D, viewport_h_px: float) -> void:
	if _ring == null or _registry == null or cam == null:
		return
	var kpx := ObjectLod.k_px(viewport_h_px, deg_to_rad(cam.fov))
	var cam_world := cam.global_transform.origin
	var parent := _ring.global_transform
	# Dirty gate: rewrite only when the camera moved, K_px changed, membership changed, or an awake body's screen
	# centre moved ≥ MOTION_EPS_PX / any rev changed. Otherwise the last buffers already hold (nothing to do).
	if not _is_dirty(cam_world, kpx):
		# Hides can still need re-application on a rev bump even if geometry is static — _apply handles that cheaply,
		# but _is_dirty already returns true on any rev change, so reaching here means hides are stable too.
		_last_cam = cam_world
		_last_kpx = kpx
		return
	var res := _compute(cam_world, kpx, parent)
	_apply(res, true)
	_last_cam = cam_world
	_last_kpx = kpx

## Gate/deterministic entry: route + apply UNCONDITIONALLY (no dirty skip) against an injected camera/K_px/parent, and
## return the full result for read-back. Used by verify_object_far.gd (no Camera3D / GPU needed).
func debug_route(cam_world: Vector3, kpx: float, parent: Transform3D) -> Dictionary:
	var res := _compute(cam_world, kpx, parent)
	_apply(res, true)
	_last_cam = cam_world
	_last_kpx = kpx
	return res

# =====================================================================================================================
# Core — pure routing (reads registry + latched prev-rep; no node/buffer mutation). Returns the plan _apply executes.
# =====================================================================================================================

func _compute(cam_world: Vector3, kpx: float, parent: Transform3D) -> Dictionary:
	var parent_inv := parent.affine_inverse()
	var ids := _registry.ids()
	if CubeSphere.FP_OBJ_LOD_SPACE:
		dbg = "objs=%d cam=(%.0f,%.0f,%.0f) noSPACE" % [ids.size(), cam_world.x, cam_world.y, cam_world.z]
	var cards: Array = []      # {id, proj, origin, hs, alpha, bright}
	var dots: Array = []
	var hide: Dictionary = {}  # id -> bool want_hidden
	var reps: Dictionary = {}  # id -> rep (for latching + gate)
	var revs: Dictionary = {}  # id -> body rev
	var centers: Dictionary = {}
	# Far candidates gathered first, then budget-sorted by proj desc so the largest survive eviction.
	var far: Array = []        # {id, kind, proj, origin, hs, alpha, bright, awake}
	for id in ids:
		var d: Dictionary = _registry.refresh(id)
		if d.is_empty():
			continue            # node freed — dropped by refresh
		var r: float = d["radius"]
		var extent: float = d["extent"]
		var cls: int = d["cls"]
		var center: Vector3 = d["center"]
		revs[id] = int(d["rev"])
		centers[id] = center
		if extent <= 0.0:
			hide[id] = false    # empty/degenerate — never hide
			reps[id] = ObjectLod.REP_FULL
			continue
		var dist := cam_world.distance_to(center)
		var rung := ObjectLod.rung_hyst(int(_prev_rep.get(id, ObjectLod.REP_FULL)), r, extent, dist, kpx)
		var rep: int = rung["rep"]
		var proj: float = rung["proj"]
		reps[id] = rep
		if CubeSphere.FP_OBJ_LOD_SPACE and cls == ObjectLod.CLASS_SPACE:
			dbg = "SPC c=(%.0f,%.0f,%.0f) cam=(%.0f,%.0f,%.0f) d=%.0f proj=%.1f rep=%s" % [
				center.x, center.y, center.z, cam_world.x, cam_world.y, cam_world.z, dist, proj, ObjectLod.REP_NAMES[rep]]
		if rep == ObjectLod.REP_FULL:
			hide[id] = false                                   # near — L0 renders its own mesh
			continue
		# Far rep. Its L0 mesh is hidden either way (it is beyond near range); whether it draws a card/dot depends on cull.
		hide[id] = true
		var cullr := ObjectLod.cull(cls, proj)
		if not bool(cullr["draw"]):
			continue                                            # debris faded fully out (< 0.5 px) — nothing drawn
		var alpha: float = float(cullr["fade"])
		var is_dot := (rep == ObjectLod.REP_DOT)
		var origin: Vector3                                     # #131 frame-weld: written in the ring's parent-local space
		var hs: float
		var bright := 1.0
		# P3 (FP_OBJ_LOD_SPACE): CLASS_SPACE never-cull beacon — planet occlusion + clamped-distance placement. Gated on
		# the const so with the flag off this branch is dead and the else path is byte-identical to P1 (and no CLASS_SPACE
		# object is ever registered when the flag is off anyway).
		if CubeSphere.FP_OBJ_LOD_SPACE and cls == ObjectLod.CLASS_SPACE:
			if _beacon_occluded(cam_world, center):
				continue                                        # behind the planet — emit no beacon row (stays L0-hidden)
			# on-screen size to preserve: the beacon dot floor for a dot, else the card's true angular size (proj).
			var screen_px: float = float(cullr["dot_px"]) if is_dot else proj
			var place := ObjectLod.beacon_placement(cam_world, center, screen_px, kpx, BEACON_CLAMP_DIST)
			origin = parent_inv * (place["origin"] as Vector3)  # map the CLAMPED world point into the ring's space
			hs = float(place["hs"])
			if is_dot:
				bright = ObjectLod.beacon_brightness(proj)      # flux-conserving p^2 dimming of a sub-pixel emitter
		else:
			origin = parent_inv * center                        # #131 frame-weld: explicit map into the ring's space
			if is_dot:
				# size the dot so its screen diameter == dot_px:  2*hs/d*kpx = dot_px  =>  hs = dot_px*d/(2*kpx)
				var dot_px: float = float(cullr["dot_px"])
				hs = (dot_px * dist / (2.0 * kpx)) if kpx > 0.0 else r
			else:
				hs = r                                          # card at the object's true angular size (2r/d*kpx)
		far.append({
			"id": id, "kind": (KIND_DOT if is_dot else KIND_CARD), "proj": proj,
			"origin": origin, "hs": hs, "alpha": alpha, "bright": bright, "awake": bool(d["awake"]),
		})
	# Budget: priority = proj desc; cap dots/cards by ObjectLod caps AND total bytes.
	far.sort_custom(func(a, b): return a["proj"] > b["proj"])
	var per_inst_bytes := STRIDE * 4
	var max_total := _budget_bytes / per_inst_bytes
	var n_card := 0
	var n_dot := 0
	var evicted := 0
	for e in far:
		var kept := false
		if (n_card + n_dot) < max_total:
			if e["kind"] == KIND_CARD and n_card < ObjectLod.CARD_INST_CAP:
				cards.append(e); n_card += 1; kept = true
			elif e["kind"] == KIND_DOT and n_dot < ObjectLod.DOT_CAP:
				dots.append(e); n_dot += 1; kept = true
		if not kept:
			evicted += 1        # over budget/cap: no far instance (but stays L0-hidden — never far-over-near)
	return {
		"cards": cards, "dots": dots, "hide": hide, "reps": reps, "revs": revs,
		"centers": centers, "parent": parent, "evicted": evicted,
	}

# =====================================================================================================================
# Apply — write the two MultiMesh buffers + drive set_far_hidden (with must-fix #1 rev re-application).
# =====================================================================================================================

func _apply(res: Dictionary, write_buffers: bool) -> void:
	# 1. L0 hide / show, re-applying on rev change (the mesh was recreated visible by _rebuild).
	var hide: Dictionary = res["hide"]
	var revs: Dictionary = res["revs"]
	for id in hide.keys():
		var want: bool = hide[id]
		var rev: int = int(revs.get(id, -1))
		var changed := (want != bool(_far_hidden_state.get(id, false))) or (rev != int(_rev_seen.get(id, -1)))
		if changed:
			var node: Object = instance_from_id(id)
			if node != null and node.has_method("set_far_hidden"):
				node.set_far_hidden(want)
			_far_hidden_state[id] = want
		_rev_seen[id] = rev
	# 2. latch reps for the next hysteresis step; forget objects no longer present.
	var reps: Dictionary = res["reps"]
	_prev_rep = reps.duplicate()
	var centers: Dictionary = res["centers"]
	# 3. write buffers.
	if write_buffers:
		var cbuf := _pack(res["cards"])
		var dbuf := _pack(res["dots"])
		_card_mm.set_buffer(cbuf)
		_card_mm.visible_instance_count = res["cards"].size()
		_dot_mm.set_buffer(dbuf)
		_dot_mm.visible_instance_count = res["dots"].size()
		_dbg_card_live = res["cards"].size()
		_dbg_dot_live = res["dots"].size()
		_dbg_evicted = res["evicted"]
		_dbg_rebuilds += 1
		# refresh motion baselines for the drawn set.
		for e in res["cards"]:
			_last_center[e["id"]] = centers.get(e["id"], Vector3.ZERO)
		for e in res["dots"]:
			_last_center[e["id"]] = centers.get(e["id"], Vector3.ZERO)
	_last_ids = revs.keys()

func _pack(rows: Array) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(rows.size() * STRIDE)
	var b := 0
	for e in rows:
		var o: Vector3 = e["origin"]
		# identity basis; billboard reads MODEL_MATRIX[3] (= parent·origin = world centre) + world-unit half-size.
		buf[b + 0] = 1.0; buf[b + 1] = 0.0; buf[b + 2] = 0.0; buf[b + 3] = o.x
		buf[b + 4] = 0.0; buf[b + 5] = 1.0; buf[b + 6] = 0.0; buf[b + 7] = o.y
		buf[b + 8] = 0.0; buf[b + 9] = 0.0; buf[b + 10] = 1.0; buf[b + 11] = o.z
		buf[b + 12] = e["hs"]; buf[b + 13] = e["alpha"]; buf[b + 14] = e["bright"]; buf[b + 15] = e["kind"]
		b += STRIDE
	return buf

# =====================================================================================================================
# Dirty gate — skip the rewrite when nothing the buffers depend on changed.
# =====================================================================================================================

func _is_dirty(cam_world: Vector3, kpx: float) -> bool:
	if not _last_cam.is_finite():
		return true                                            # first step
	if absf(kpx - _last_kpx) > 0.001:
		return true
	if cam_world.distance_to(_last_cam) > CAM_EPS:
		return true
	var ids := _registry.ids()
	if ids.size() != _last_ids.size():
		return true
	for id in ids:
		var d: Dictionary = _registry.refresh(id)
		if d.is_empty():
			return true
		if int(d["rev"]) != int(_rev_seen.get(id, -2147483648)):
			return true                                        # a _rebuild happened — re-apply the hide + rewrite
		if bool(d["awake"]):
			var center: Vector3 = d["center"]
			var last: Vector3 = _last_center.get(id, center)
			var dist := cam_world.distance_to(center)
			if dist > 0.0 and (center.distance_to(last) / dist * kpx) >= MOTION_EPS_PX:
				return true                                    # awake body moved ≥ 0.5 px on screen
	return false

# =====================================================================================================================
# Never-OOM ledger + telemetry
# =====================================================================================================================

## Fixed resident bytes: the two MultiMesh buffers (allocated at their caps) + the tiny shared quad. Bounded and well
## under OBJ_LOD_BYTES_MAX (dot 4096 + card 2048 instances × 16 floats × 4 B ≈ 384 KB).
func total_bytes() -> int:
	var dot_b := ObjectLod.DOT_CAP * STRIDE * 4
	var card_b := ObjectLod.CARD_INST_CAP * STRIDE * 4
	var quad_b := 6 * (3 + 3) * 4
	return dot_b + card_b + quad_b

func card_live() -> int: return _dbg_card_live
func dot_live() -> int: return _dbg_dot_live
func evicted() -> int: return _dbg_evicted
func rebuild_count() -> int: return _dbg_rebuilds
func last_buffer(kind_card: bool) -> PackedFloat32Array:
	var mm := _card_mm if kind_card else _dot_mm
	return mm.get_buffer() if mm != null else PackedFloat32Array()
