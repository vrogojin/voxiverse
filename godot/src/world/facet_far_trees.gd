class_name FacetFarTrees
extends RefCounted
## COSMOS FAR-TREES (docs/COSMOS-FAR-TREES-DESIGN.md) — the far-terrain tree tier, owned/stepped by ONE
## `FacetFarRing` exactly like `FacetSmoothV2` / `FacetOrbitRelief`. P0 ships RUNG 2 only: the cross+cap CARD
## impostor band over camera-distance [near_render_radius(), FAR_TREES_CARD_MAX] (rung 1 archetype meshes are P1;
## rung 3 is the existing fine-map canopy texels, no code here). Everything is driven by the SAME `TreeGen`
## placement hashes through the additive `TreeGen.tree_info` enumeration, so far cards align 1:1 with the near
## voxel trees by construction (the #1 correctness gate) — never by synchronisation.
##
## THE STACK (mirrors V2/G3):
##  - ONE `MultiMeshInstance3D` child of the ring (inherits the placement transform / anchor shifts / SN3 scaled
##    placement for orbit-frame correctness for free). One material, one draw. Instances are the visible bounded
##    card set, rebuilt (rate-capped) nearest-first under a hard cap.
##  - Per-facet tree enumeration runs OFF-THREAD (one facet / job, a single WTP slot), gated by the FP_LOAD_DEFER
##    settle latch so no tree work fires during fresh-load pile-up. Results cached in an LRU keyed by fid.
##  - Card textures are CPU-rasterised ONCE from `TreeGen.archetype_cells` (no viewport, no offline bake).
##
## CORRECTNESS FILTERS (§5.5): (1) NO far-over-near — a card is emitted only when its base camera distance ≥ R0,
## and the whole node SUSPENDS on-surface→off-surface inverted like G3 (trees show ON-surface only). (2) BODY GATE
## — enumeration scans Earth facets only, BEFORE any species selection (the Moon biome-id 11/12 alias trap,
## [[voxiverse-tree-bugs-rootcause]]). (3) FP_CLIMATE_BIOMES — reused verbatim inside `TreeGen.tree_info`
## (`_species_for`), so Earth deserts never grow phantom far-cacti with the flag off.
##
## LIGHTING (§5.3): the ONE radial law — `ALBEDO = tex.rgb · voxi_shade(n, sun_dir)`,
## `n = normalize(world_pos − planet_centre)` (NOT slope-shaded, user-rejected). `sun_dir` is pushed per frame
## from the world_manager hub; the material is seeded on build from `TierPlace.last_sun_dir()` so it never freezes
## at the (1,0,0) fake-noon default (FP_FAR_TERMINATOR_WELD). `planet_centre` is refreshed each step from the
## ring's `render_centre()` — a MultiMesh's per-instance MODEL·0 is the INSTANCE origin, NOT the body centre, so
## (unlike the single-mesh V2/G3) the radial normal must come from an explicit uniform, not MODEL·0. (Deviation
## from the design's "mirror V2/G3 MODEL·0" — the lighting LAW is identical; only the normal's source differs,
## forced by MultiMesh instancing.)
##
## NEVER-OOM (§6): `total_bytes()` (card buffer + atlas + mesh + facet LRU) is asserted ≤ `FAR_TREES_BYTES_MAX`.
## Instances are capped at `FAR_TREES_CARD_INST_MAX`, nearest-first, `log()`-warned when capped.

const G := 10                          # TreeGen tree-grid cell size (columns) — MUST equal TreeGen.G
const ATLAS_COLS := 8                  # card atlas columns (one per species slot; 6 used, 2 spare)
const ATLAS_ROWS := 2                  # row 0 = side (X-cross) view, row 1 = top (cap) view
const ATLAS_TILE := 32                 # texels per tile → atlas 256×64 RGBA8
const CARD_CUSTOM_FLOATS := 4          # MultiMesh custom-data floats/instance (use_colors=false)
const CARD_XFORM_FLOATS := 12          # TRANSFORM_3D floats/instance
const CARD_STRIDE := CARD_XFORM_FLOATS + CARD_CUSTOM_FLOATS   # 16 floats/instance (== §6 ledger)
const REC_FLOATS := 8                  # per-tree cache record: sunk-base(3) radial(3) species_col(1) trunk+hash(1)
const BURY := 1.0                      # radial sink (blocks): trunk base buried so trees sit on the tier datum (§4.3)
const CANOPY_DIAM := 5.0               # horizontal card scale (blocks) — radius-2 canopy → ~5-block diameter
const CANOPY_EXTRA := 3.0              # blocks added over trunk_h for the total card height (canopy layers + cap)
const EVICT_DWELL_STEPS := 20          # dwell before an unwanted facet's cached list is evicted (V2 convention)

# The shared card mesh (unit archetype: 2 vertical crossed quads + 1 horizontal cap quad; local Y∈[0,1], half-
# width 0.5). Built once; scaled/oriented per instance. UV = local tile coords [0,1]; UV2.x = 0 side / 1 top.
static var _card_mesh: ArrayMesh = null

## FP_FAR_TERMINATOR_WELD: the last live Sun any FacetFarTrees was fed (class-level static — outlives the tier
## across facet crossings). `make_material` also seeds from `TierPlace.last_sun_dir()`; this backs the tier's own
## refresh. (1,0,0) until the first `set_sun_dir`.
static var _last_sun_dir := Vector3(1.0, 0.0, 0.0)

var _ring: Node3D = null               # owning FacetFarRing — read-only (render_centre / shell_offsurface / global_transform)
var _mmi: MultiMeshInstance3D = null    # rung-2 card node (one draw)
var _mm: MultiMesh = null
var _material: ShaderMaterial = null
var _active_fid := -1
var _atlas: ImageTexture = null

# per-facet tree-list LRU (fid -> PackedFloat32Array of REC_FLOATS-stride records), dwell-evicted
var _cache: Dictionary = {}
var _leaving: Dictionary = {}          # fid -> dwell steps remaining
var _lru: Array = []                   # fids in touch order (front = oldest)

# single enumeration worker slot (one facet / job)
var _enum_fid := -1
var _enum_task := -1
var _enum_mutex: Mutex = null
var _enum_result = null

var _last_step_ms := 0
var _live_instances := 0               # last rebuild's visible instance count (ledger/telemetry)
var _capped := false                   # last rebuild hit FAR_TREES_CARD_INST_MAX
var _last_enum_ms := 0.0               # last enumeration wall cost (ms/facet — P0 gate records this)

# =====================================================================================================================
# Shader — HEAD + VoxiLight.shade_glsl() + TAIL. Alpha-scissor (discard), opaque (no sort), cull_disabled (the
# cross is double-sided). ALBEDO = atlas.rgb · voxi_shade(radial_n, sun_dir). planet_centre + sun_dir are uniforms.
# =====================================================================================================================
const _CARD_HEAD := "shader_type spatial;
render_mode cull_disabled;
uniform sampler2D tree_atlas : source_color, filter_nearest;
uniform vec3 planet_centre = vec3(0.0, 0.0, 0.0);
uniform float atlas_cols = 8.0;
uniform float atlas_rows = 2.0;
"
const _CARD_TAIL := "varying vec2 v_uv;
varying vec3 v_n;
varying float v_hue;
void vertex() {
	float col = INSTANCE_CUSTOM.x;
	float row = UV2.x;
	v_uv = vec2((col + UV.x) / atlas_cols, (row + UV.y) / atlas_rows);
	v_hue = INSTANCE_CUSTOM.y;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_n = normalize(wp - planet_centre);
}
void fragment() {
	vec4 t = texture(tree_atlas, v_uv);
	if (t.a < 0.5) discard;
	float jit = 1.0 + (v_hue - 0.5) * 0.08;
	ALBEDO = t.rgb * voxi_shade(v_n, sun_dir) * jit;
}
"

static func shader_code() -> String:
	return _CARD_HEAD + VoxiLight.shade_glsl() + _CARD_TAIL

static func make_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = shader_code()
	sm.shader = sh
	# FP_FAR_TERMINATOR_WELD (§5.3): seed from the shared last-live Sun, never the hardcoded (1,0,0). Off ⇒ (1,0,0).
	var seed := TierPlace.last_sun_dir() if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
	sm.set_shader_parameter("sun_dir", seed)
	sm.set_shader_parameter("atlas_cols", float(ATLAS_COLS))
	sm.set_shader_parameter("atlas_rows", float(ATLAS_ROWS))
	# Unified: the ONE uniform set (values from VoxiLight — night_floor 0.06 == SHELL_NIGHT_FLOOR, moonshine floor).
	if CubeSphere.FP_SHADE_UNIFIED:
		sm.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		sm.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return sm

# =====================================================================================================================
# Construction — one MultiMeshInstance3D child of the ring, one card material, the CPU-rasterised atlas, the shared
# unit card mesh. Called from FacetFarRing.setup under FP_FAR_TREES.
# =====================================================================================================================
func setup_instance(ring: Node3D, active_fid: int) -> void:
	_ring = ring
	_active_fid = active_fid
	_enum_mutex = Mutex.new()
	_material = make_material()
	_atlas = _build_atlas()
	_material.set_shader_parameter("tree_atlas", _atlas)
	if _card_mesh == null:
		_card_mesh = _build_card_mesh()
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = false
	_mm.use_custom_data = true
	_mm.mesh = _card_mesh
	_mm.instance_count = CubeSphere.FAR_TREES_CARD_INST_MAX
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "FacetFarTreesCards"
	_mmi.multimesh = _mm
	_mmi.material_override = _material
	# Instances are placed anywhere in the front hemisphere in ABSOLUTE coords (the shader/placement move them), so
	# the CPU-side AABB can't predict them — pin a huge custom AABB so the node is never wrongly frustum-culled.
	_mmi.custom_aabb = AABB(Vector3(-12000.0, -12000.0, -12000.0), Vector3(24000.0, 24000.0, 24000.0))
	ring.add_child(_mmi)

func set_active(new_fid: int) -> void:
	_active_fid = new_fid   # residency is camera-distance driven (rebuilt each step); crossing only re-seeds the centre facet

## Feed the current Sun into the card material (world_manager hub, per frame). Notes the shared weld cache too.
func set_sun_dir(sun_dir: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)
	if CubeSphere.FP_FAR_TERMINATOR_WELD:
		_last_sun_dir = sun_dir

func sun_dir_telemetry() -> Vector3:
	return (_material.get_shader_parameter("sun_dir") if _material != null else Vector3(1.0, 0.0, 0.0))

# =====================================================================================================================
# Step — reap the enumeration worker, advance dwell eviction, suspend on-surface↔off-surface (inverted like G3),
# then (rate-capped, settled) dispatch the nearest missing facet's enumeration and rebuild the card buffer.
# =====================================================================================================================
func step(settled := true, credit_ok := true, cam_render := Vector3.ZERO) -> void:
	_reap_enum()
	# NO far-over-near / orbit suspend (§4.2): trees show ON-surface only; off-surface the whole node is hidden and
	# the instance set is frozen (mirror of G3's off-surface-only visibility, inverted).
	var offsurf := (_ring as FacetFarRing).shell_offsurface()
	if _mmi != null:
		_mmi.visible = not offsurf
	if offsurf:
		return
	# FP_LOAD_DEFER settle gate: pre-settle we only reaped (a finished build still lands in the LRU); no dispatch,
	# no rebuild — no tree work during fresh-load pile-up. Post-settle the first rebuild waits on stream credit.
	if not settled or not credit_ok:
		return
	var now := Time.get_ticks_msec()
	if now - _last_step_ms < CubeSphere.FAR_TREES_STEP_MS:
		return
	_last_step_ms = now
	# Push the live body centre (render frame) so the radial normal can't go stale across a crossing / re-anchor.
	if _material != null:
		_material.set_shader_parameter("planet_centre", (_ring as FacetFarRing).render_centre())
	var cam_abs := _cam_to_absolute(cam_render)
	var wanted := _wanted_facets(cam_abs)                  # Earth facets within the card band, nearest-first
	_advance_dwell(wanted)
	if _enum_fid < 0:
		_dispatch_nearest_missing(wanted)                 # one facet / job (paced under the settle gate)
	if CubeSphere.FP_FAR_TREES_CARDS:
		_rebuild_cards(cam_abs, wanted)

# --- enumeration worker (one facet / job) ---------------------------------------------------------------------------

func _reap_enum() -> void:
	if _enum_fid < 0 or not WorkerThreadPool.is_task_completed(_enum_task):
		return
	WorkerThreadPool.wait_for_task_completion(_enum_task)
	var fid := _enum_fid
	_enum_mutex.lock()
	var recs = _enum_result
	_enum_result = null
	_enum_mutex.unlock()
	_enum_fid = -1
	_enum_task = -1
	if recs is PackedFloat32Array:
		_cache[fid] = recs
		_leaving.erase(fid)
		_touch_lru(fid)
		_evict_lru_overflow()

func _dispatch_nearest_missing(wanted: Array) -> void:
	for fid in wanted:
		if not _cache.has(int(fid)):
			_enum_fid = int(fid)
			_enum_result = null
			_enum_task = WorkerThreadPool.add_task(Callable(self, "_enum_worker").bind(int(fid)), true, "fartreesenum")
			return

## Worker-safe: reads only frozen FacetAtlas data + static TreeGen/TerrainConfig (a per-fid GenCtx homes every
## terrain/tree query on THIS facet — the same worker-safety pattern facet_tex_baker uses). Writes only
## `_enum_result` under the mutex.
func _enum_worker(fid: int) -> void:
	var t0 := Time.get_ticks_usec()
	var recs := PackedFloat32Array()
	var ctx = TerrainConfig.GenCtx.new(0, fid) if CubeSphere.FACETED else null
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	var gx0 := floori(float(dmin.x) / float(G))
	var gx1 := floori(float(dmax.x) / float(G))
	var gz0 := floori(float(dmin.y) / float(G))
	var gz1 := floori(float(dmax.y) / float(G))
	for gx in range(gx0, gx1 + 1):
		for gz in range(gz0, gz1 + 1):
			var info := TreeGen.tree_info(gx, gz, ctx)
			if info.is_empty():
				continue
			var base: Vector3i = info["base"]
			# Ownership: the base column belongs to EXACTLY one facet (the exact convex-quad interior) — this is
			# what guarantees the placement bijection (no double-trees at a shared facet border).
			if not FacetAtlas.in_polygon(fid, base.x, base.z, 0.0):
				continue
			var w := FacetAtlas.lattice_to_world64(fid, float(base.x), float(base.y), float(base.z))
			var wx := float(w[0]); var wy := float(w[1]); var wz := float(w[2])
			var rlen := sqrt(wx * wx + wy * wy + wz * wz)
			if rlen < 1.0e-6:
				continue
			var rx := wx / rlen; var ry := wy / rlen; var rz := wz / rlen
			# Radial sink by BURY so the trunk base sits on the tier datum (never rides a tier that protrudes, §4.3).
			var sx := wx - rx * BURY; var sy := wy - ry * BURY; var sz := wz - rz * BURY
			var species := int(info["species"])
			var trunk_h := int(info["trunk_h"])
			var hue := _hue01(gx, gz)
			recs.push_back(sx); recs.push_back(sy); recs.push_back(sz)
			recs.push_back(rx); recs.push_back(ry); recs.push_back(rz)
			recs.push_back(float(species - 1))                     # species enum 1..6 → atlas column 0..5
			recs.push_back(float(trunk_h) + hue)                    # floor = trunk_h, frac = hue jitter phase
	_last_enum_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	_enum_mutex.lock()
	_enum_result = recs
	_enum_mutex.unlock()

# --- wanted-facet set + LRU -----------------------------------------------------------------------------------------

## Earth facets whose surface centre is within FAR_TREES_CARD_MAX + facet-radius of the camera, nearest-first,
## capped to FAR_TREES_CACHE_FACETS. Iterates the Earth fid range ONLY (the body gate — no Moon facet is ever a
## candidate, so `_species_for`'s biome-id alias trap can never fire).
func _wanted_facets(cam_abs: Vector3) -> Array:
	var facet_radius := (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)   # ~417 blocks
	var reach := CubeSphere.FAR_TREES_CARD_MAX + facet_radius
	var reach2 := reach * reach
	var cand: Array = []
	var earth_n := 6 * FacetAtlas.K * FacetAtlas.K
	for fid in range(earth_n):
		var dmn := FacetAtlas.dom_min(fid)
		var dmx := FacetAtlas.dom_max(fid)
		var d := FacetAtlas.cell_dir(fid, (dmn.x + dmx.x) / 2, (dmn.y + dmx.y) / 2)   # facet surface-centre direction
		var cx := d.x * FacetAtlas.R_BLOCKS; var cy := d.y * FacetAtlas.R_BLOCKS; var cz := d.z * FacetAtlas.R_BLOCKS
		var dx := cx - cam_abs.x; var dy := cy - cam_abs.y; var dz := cz - cam_abs.z
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 <= reach2:
			cand.append([d2, fid])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for i in range(mini(cand.size(), CubeSphere.FAR_TREES_CACHE_FACETS)):
		out.append(int(cand[i][1]))
	return out

func _advance_dwell(wanted: Array) -> void:
	var wset := {}
	for fid in wanted:
		wset[int(fid)] = true
		_leaving.erase(int(fid))
	for fid in _cache.keys():
		if not wset.has(int(fid)) and not _leaving.has(int(fid)):
			_leaving[int(fid)] = EVICT_DWELL_STEPS
	var evict: Array = []
	for fid in _leaving.keys():
		var left := int(_leaving[fid]) - 1
		if left <= 0:
			evict.append(fid)
		else:
			_leaving[fid] = left
	for fid in evict:
		_leaving.erase(fid)
		_cache.erase(fid)
		_lru.erase(fid)

func _touch_lru(fid: int) -> void:
	_lru.erase(fid)
	_lru.append(fid)

func _evict_lru_overflow() -> void:
	while _lru.size() > CubeSphere.FAR_TREES_CACHE_FACETS:
		var old := int(_lru[0])
		_lru.remove_at(0)
		_cache.erase(old)
		_leaving.erase(old)

# --- card buffer rebuild (nearest-first, capped) --------------------------------------------------------------------

## Rebuild the ONE MultiMesh buffer: for each wanted facet (nearest-first) walk its cached trees, keep those whose
## base camera distance is in [R0, FAR_TREES_CARD_MAX] (R0 = near voxel edge — the near field owns closer trees →
## no far-over-near), emit a card transform + custom data, up to FAR_TREES_CARD_INST_MAX. One `set_buffer` upload.
func _rebuild_cards(cam_abs: Vector3, wanted: Array) -> void:
	var r0 := float(TerrainConfig.near_render_radius())
	var d2 := CubeSphere.FAR_TREES_CARD_MAX
	var cap := CubeSphere.FAR_TREES_CARD_INST_MAX
	var buf := PackedFloat32Array()
	buf.resize(cap * CARD_STRIDE)
	var n := 0
	var capped := false
	for fid in wanted:
		if n >= cap:
			capped = true
			break
		if not _cache.has(int(fid)):
			continue
		var recs: PackedFloat32Array = _cache[int(fid)]
		var m := recs.size() / REC_FLOATS
		for i in range(m):
			if n >= cap:
				capped = true
				break
			var o := i * REC_FLOATS
			var sx: float = recs[o + 0]; var sy: float = recs[o + 1]; var sz: float = recs[o + 2]
			var dx := sx - cam_abs.x; var dy := sy - cam_abs.y; var dz := sz - cam_abs.z
			var dist := sqrt(dx * dx + dy * dy + dz * dz)
			if dist < r0 or dist > d2:
				continue
			var rx: float = recs[o + 3]; var ry: float = recs[o + 4]; var rz: float = recs[o + 5]
			var col: float = recs[o + 6]
			var packed: float = recs[o + 7]
			var trunk_h := floorf(packed)
			var hue := packed - trunk_h
			_write_card(buf, n * CARD_STRIDE, sx, sy, sz, rx, ry, rz, trunk_h, col, hue)
			n += 1
	_mm.set_buffer(buf)
	_mm.visible_instance_count = n
	_last_buf = buf
	_live_instances = n
	_capped = capped
	if capped:
		print("  FacetFarTrees: card cap ", cap, " hit (nearest-first fill) — increase FAR_TREES_CARD_INST_MAX or start thinning")

## Write ONE card instance: a radial-up basis (Y=radial, X/Z=stable tangents) scaled by canopy width + tree height,
## origin at the sunk base; custom data = (species_col, hue, 0, 0). Buffer layout is TRANSFORM_3D's 12 floats
## (3 rows of the 3×4 augmented matrix) followed by the 4 custom-data floats.
func _write_card(buf: PackedFloat32Array, base: int, sx: float, sy: float, sz: float,
		rx: float, ry: float, rz: float, trunk_h: float, col: float, hue: float) -> void:
	var r := Vector3(rx, ry, rz)
	# stable tangent basis from the radial (avoid the world-up degeneracy near the poles)
	var up := Vector3(0.0, 1.0, 0.0)
	if absf(r.dot(up)) > 0.99:
		up = Vector3(1.0, 0.0, 0.0)
	var t1 := r.cross(up).normalized()
	var t2 := r.cross(t1).normalized()
	var hs := CANOPY_DIAM
	var vs := trunk_h + CANOPY_EXTRA
	var bx := t1 * hs          # local +X column (scaled)
	var by := r * vs           # local +Y column (radial-up, scaled)
	var bz := t2 * hs          # local +Z column (scaled)
	# 3 rows of [bx by bz | origin]
	buf[base + 0] = bx.x; buf[base + 1] = by.x; buf[base + 2] = bz.x; buf[base + 3] = sx
	buf[base + 4] = bx.y; buf[base + 5] = by.y; buf[base + 6] = bz.y; buf[base + 7] = sy
	buf[base + 8] = bx.z; buf[base + 9] = by.z; buf[base + 10] = bz.z; buf[base + 11] = sz
	buf[base + 12] = col; buf[base + 13] = hue; buf[base + 14] = 0.0; buf[base + 15] = 0.0

# --- geometry / atlas (one-time) ------------------------------------------------------------------------------------

## The shared unit card mesh: 2 vertical crossed quads (X-Y and Z-Y planes, the silhouette / side atlas row) + 1
## horizontal cap quad (X-Z plane at Y=0.7, the top atlas row). Local Y∈[0,1], half-width 0.5. cull_disabled makes
## each quad double-sided (6 tris/instance rendered both faces). UV = tile-local [0,1]; UV2.x = 0 side / 1 top.
func _build_card_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	var h := 0.5
	# vertical quad A (in X-Y, z=0), side row
	_quad(verts, uvs, uv2s, idx, Vector3(-h, 0, 0), Vector3(h, 0, 0), Vector3(h, 1, 0), Vector3(-h, 1, 0), 0.0)
	# vertical quad B (in Z-Y, x=0), side row
	_quad(verts, uvs, uv2s, idx, Vector3(0, 0, -h), Vector3(0, 0, h), Vector3(0, 1, h), Vector3(0, 1, -h), 0.0)
	# horizontal cap quad (in X-Z, y=0.7), top row
	var cy := 0.7
	_quad(verts, uvs, uv2s, idx, Vector3(-h, cy, -h), Vector3(h, cy, -h), Vector3(h, cy, h), Vector3(-h, cy, h), 1.0)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = uv2s
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _quad(verts: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, idx: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, row: float) -> void:
	var base := verts.size()
	verts.push_back(a); verts.push_back(b); verts.push_back(c); verts.push_back(d)
	# UV: local tile [0,1], v flipped so the mesh Y=0 (ground) samples tile-bottom (v=1)
	uvs.push_back(Vector2(0, 1)); uvs.push_back(Vector2(1, 1)); uvs.push_back(Vector2(1, 0)); uvs.push_back(Vector2(0, 0))
	uv2s.push_back(Vector2(row, 0)); uv2s.push_back(Vector2(row, 0)); uv2s.push_back(Vector2(row, 0)); uv2s.push_back(Vector2(row, 0))
	idx.push_back(base + 0); idx.push_back(base + 1); idx.push_back(base + 2)
	idx.push_back(base + 0); idx.push_back(base + 2); idx.push_back(base + 3)

## CPU-rasterise each species' side + top orthographic projection of its `TreeGen.archetype_cells` cube set into a
## 32² tile of the shared 256×64 atlas (side = row 0, top = row 1, column = species-1). Colours from
## `BlockCatalog.color_of` (the same source FarPalette resolves — colour-consistent with the near blocks + skin).
func _build_atlas() -> ImageTexture:
	var img := Image.create(ATLAS_COLS * ATLAS_TILE, ATLAS_ROWS * ATLAS_TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var species := [TreeGen.SP_OAK, TreeGen.SP_BIRCH, TreeGen.SP_SPRUCE, TreeGen.SP_ACACIA, TreeGen.SP_JUNGLE, TreeGen.SP_CACTUS]
	for si in range(species.size()):
		var sp := int(species[si])
		var cells := TreeGen.archetype_cells(sp)
		if cells.is_empty():
			continue
		_raster_tile(img, si * ATLAS_TILE, 0 * ATLAS_TILE, cells, false)      # side view (row 0)
		_raster_tile(img, si * ATLAS_TILE, 1 * ATLAS_TILE, cells, true)       # top view  (row 1)
	return ImageTexture.create_from_image(img)

## Rasterise one 32² tile. side=false → project (dx, y) [the X-cross silhouette, ground at tile bottom]; side=true
## → project (dx, dz) [the canopy cap seen from above, topmost cell wins the pixel]. Each cell paints a small block.
func _raster_tile(img: Image, ox: int, oy: int, cells: Array, top: bool) -> void:
	var minu := 1e9; var maxu := -1e9; var minv := 1e9; var maxv := -1e9
	for c in cells:
		var cv: Vector4i = c
		var u := float(cv.x)
		var v := (float(cv.z) if top else float(cv.y))
		minu = minf(minu, u); maxu = maxf(maxu, u)
		minv = minf(minv, v); maxv = maxf(maxv, v)
	var du := maxf(maxu - minu, 1.0)
	var dv := maxf(maxv - minv, 1.0)
	var pad := 3.0
	var span := float(ATLAS_TILE) - 2.0 * pad
	# For the top view, paint canopy-topmost last so it wins; sort by y ascending.
	var order := cells.duplicate()
	if top:
		order.sort_custom(func(a, b): return (a as Vector4i).y < (b as Vector4i).y)
	var blk := int(ceil(span / maxf(du, dv))) + 1
	for c in order:
		var cv: Vector4i = c
		var u := float(cv.x)
		var v := (float(cv.z) if top else float(cv.y))
		var fu := (u - minu) / du                       # 0..1 left→right
		var fv := (v - minv) / dv                       # 0..1
		var px := int(pad + fu * span)
		# side view: ground (min y) at tile BOTTOM (higher pixel row); flip v
		var py := int(pad + (1.0 - fv) * span) if not top else int(pad + fv * span)
		var colr := BlockCatalog.color_of(cv.w)
		colr.a = 1.0
		_fill_rect(img, ox + px, oy + py, blk, colr)

func _fill_rect(img: Image, x0: int, y0: int, sz: int, c: Color) -> void:
	for yy in range(y0, y0 + sz):
		if yy < 0 or yy >= img.get_height():
			continue
		for xx in range(x0, x0 + sz):
			if xx < 0 or xx >= img.get_width():
				continue
			img.set_pixel(xx, yy, c)

# --- frame helpers --------------------------------------------------------------------------------------------------

## Camera (render frame) → ABSOLUTE planet coords (the frame the enumerated tree positions + instance transforms
## live in). The card MMI is a child of the ring, so its instances render at ring.global_transform · P; inverting
## that maps the camera into the same absolute frame the cached positions use. On-surface the placement is rigid,
## so distances are frame-invariant either way.
func _cam_to_absolute(cam_render: Vector3) -> Vector3:
	if _ring == null:
		return cam_render
	return (_ring as Node3D).global_transform.affine_inverse() * cam_render

## A cheap per-tree jitter phase in [0,1) from the grid cell (hue jitter only — NOT a placement hash, so it need
## not match TreeGen; same integer-mix family for a stable, well-distributed value).
static func _hue01(gx: int, gz: int) -> float:
	var n := (gx * 374761393 + gz * 668265263 + 99 * 362437) & 0x7FFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7FFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65536.0

# --- NEVER-OOM ledger + telemetry -----------------------------------------------------------------------------------

## Resident bytes: the fixed-size card MultiMesh buffer (instance_count × stride) + atlas RGBA8 + the shared mesh +
## the live per-facet tree-list LRU. Asserted ≤ FAR_TREES_BYTES_MAX by the gate (§6).
func total_bytes() -> int:
	var buf_b := CubeSphere.FAR_TREES_CARD_INST_MAX * CARD_STRIDE * 4
	var atlas_b := ATLAS_COLS * ATLAS_TILE * ATLAS_ROWS * ATLAS_TILE * 4
	var mesh_b := 12 * (3 * 4 + 2 * 4 + 2 * 4) + 18 * 4    # 12 verts × (pos+uv+uv2) + 18 indices — tiny
	var lru_b := 0
	for fid in _cache.keys():
		lru_b += (_cache[fid] as PackedFloat32Array).size() * 4
	return buf_b + atlas_b + mesh_b + lru_b

func live_instances() -> int: return _live_instances
func was_capped() -> bool: return _capped
func last_enum_ms() -> float: return _last_enum_ms
func cached_facets() -> int: return _cache.size()

var _last_buf: PackedFloat32Array = PackedFloat32Array()   # last rebuilt card buffer (gate read-back only)

## Test hooks (gate-only): drive the card rebuild without a live FacetFarRing (no camera plumbing / no worker).
func debug_set_cache(fid: int, recs: PackedFloat32Array) -> void:
	_cache[int(fid)] = recs
	_touch_lru(int(fid))

func debug_rebuild(wanted: Array, cam_abs: Vector3) -> int:
	_rebuild_cards(cam_abs, wanted)
	return _live_instances

func debug_buffer() -> PackedFloat32Array:
	return _last_buf

## Test hook: synchronously enumerate a facet into the LRU (drives the gate without the worker thread).
func enumerate_facet_sync(fid: int) -> PackedFloat32Array:
	_enum_worker(fid)
	_enum_mutex.lock()
	var recs = _enum_result
	_enum_result = null
	_enum_mutex.unlock()
	if recs is PackedFloat32Array:
		_cache[fid] = recs
		_touch_lru(fid)
	return recs if recs is PackedFloat32Array else PackedFloat32Array()
