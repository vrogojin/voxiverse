class_name FacetFarTrees
extends RefCounted
## COSMOS FAR-TREES (docs/COSMOS-FAR-TREES-DESIGN.md) — the far-terrain tree tier, owned/stepped by ONE
## `FacetFarRing` exactly like `FacetSmoothV2` / `FacetOrbitRelief`. RUNG 2 (P0, FP_FAR_TREES_CARDS): cross+cap CARD
## impostors. RUNG 1 (P1, FP_FAR_TREES_MESH): per-species face-merged voxel-archetype mini-meshes over
## [near_render_radius(), FAR_TREES_MESH_MAX) — cards then retreat to [FAR_TREES_MESH_MAX, FAR_TREES_CARD_MAX] with
## an EXCLUSIVE handoff at 448 (a tree renders in exactly one band). RUNG 3 (orbit) is the existing fine-map canopy
## texels (no code here). The ladder: near voxel (0-128) → archetype mesh (128-448) → cards (448-2400) → fine-map
## speckle. Everything is driven by the SAME `TreeGen`
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
const REC_FLOATS := 11                 # per-tree record: sunk-base(3) radial(3) species_col(1) trunk+hash(1) lattice-base(3)
# P2 (FP_FAR_TREES_FADE) tuning — all tier-local (no cube_sphere change). Off ⇒ none of these are consulted.
const FADE_NEAR_W := 24.0              # near→rung1 dither-in width (blocks) over [R0, R0+24] (design §4.2)
const FADE_BAND_W := 32.0             # rung1↔rung2 cross-dither half-width over [448±32] (design §4.2)
const THIN_START := 1200.0            # hash-survival thinning begins (blocks) — keep(d) ramps 1.0→THIN_MIN to CARD_MAX
const THIN_MIN := 0.15                # keep-fraction at the fog line (design §4.2)
const THIN_FADE := 0.06               # dithered-retirement half-width in the survival-hash domain (no pop as keep(d) crosses hue)
const FADE_EPS := 0.004               # below this the instance is dropped (fully faded / retired) — bounds the transient count
const BURY := 1.0                      # radial sink (blocks): trunk base buried so trees sit on the tier datum (§4.3)
const CANOPY_DIAM := 5.0               # horizontal card scale (blocks) — radius-2 canopy → ~5-block diameter
const CANOPY_EXTRA := 3.0              # blocks added over trunk_h for the total card height (canopy layers + cap)
const EVICT_DWELL_STEPS := 20          # dwell before an unwanted facet's cached list is evicted (V2 convention)
const MESH_STRIDE := 16                # rung-1 mesh MultiMesh buffer floats/instance (12 transform + 4 custom)
const MESH_STRIDE_CFIX := 20           # FP_FAR_TREES_COLORFIX: 12 transform + 4 COLOR (white) + 4 custom (RS layout)
const N_SPECIES := 6                   # OAK/BIRCH/SPRUCE/ACACIA/JUNGLE/CACTUS → atlas/mesh column = species-1

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

# --- P1 rung-1: per-species voxel-archetype mini-mesh band [R0, FAR_TREES_MESH_MAX) (FP_FAR_TREES_MESH) ---
# One MultiMeshInstance3D per species (≤6 draws), all sharing ONE material; per-species face-merged archetype mesh
# (from TreeGen.archetype_cells) with a UV2 trunk/canopy flag the shader uses for per-tree trunk-stretch. null / empty
# off (never constructed) ⇒ byte-identical.
var _mesh_material: ShaderMaterial = null
var _mesh_mmis: Array = []             # 6 MultiMeshInstance3D (one per species column)
var _mesh_mms: Array = []              # 6 MultiMesh
var _arch_meshes: Array = []           # 6 ArrayMesh archetypes
var _arch_trunk: PackedFloat32Array = PackedFloat32Array()   # 6 canonical archetype trunk heights (blocks)
var _mesh_live := 0                    # last rebuild's total live mesh instances (across species)
var _mesh_capped := false              # last rebuild hit FAR_TREES_MESH_TOTAL_MAX or a per-species alloc

## FP_FAR_TREES_COLORFIX §4.2: hide-until-first-rebuild-after-offsurf. On de-orbit `step()` sets visibility from
## `shell_offsurface()` BEFORE the settle gate, so the tier re-appears instantly with the PRE-ORBIT (frozen) instance
## set + stale band membership until FP_LOAD_DEFER settles. Latched true on any offsurf frame; cleared at the end of
## the first completed rebuild → visibility is `not offsurf and not _stale` (correct-or-nothing). Off ⇒ never consulted.
var _stale := false

# P2 (FP_FAR_TREES_FADE) edit-overlay chop filter: a main-thread Callable (fid:int, cell:Vector3i)->bool that returns
# true iff the player has an edit at that cell (chopped). Fed once by WorldManager; unset ⇒ no filter (P0/P1). Only
# consulted under FP_FAR_TREES_FADE, at rebuild (main thread), so reading WorldManager._edits is race-free.
var _chop_query: Callable = Callable()

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

## P2 (FP_FAR_TREES_FADE) card tail: adds a per-pixel dither DISCARD against the per-instance fade alpha
## (INSTANCE_CUSTOM.w) — a screen-space dissolve (no alpha-sort, gl_compat-safe) for the no-pop band cross-fades +
## hash-survival thinning. Everything else byte-identical to `_CARD_TAIL`. Off ⇒ `_CARD_TAIL` verbatim.
const _CARD_TAIL_FADE := "varying vec2 v_uv;
varying vec3 v_n;
varying float v_hue;
varying flat float v_fade;
float _ft_dither(vec2 fc) { return fract(sin(dot(floor(fc), vec2(12.9898, 78.233))) * 43758.5453); }
void vertex() {
	float col = INSTANCE_CUSTOM.x;
	float row = UV2.x;
	v_uv = vec2((col + UV.x) / atlas_cols, (row + UV.y) / atlas_rows);
	v_hue = INSTANCE_CUSTOM.y;
	v_fade = INSTANCE_CUSTOM.w;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_n = normalize(wp - planet_centre);
}
void fragment() {
	vec4 t = texture(tree_atlas, v_uv);
	if (t.a < 0.5) discard;
	if (_ft_dither(FRAGCOORD.xy) > v_fade) discard;
	float jit = 1.0 + (v_hue - 0.5) * 0.08;
	ALBEDO = t.rgb * voxi_shade(v_n, sun_dir) * jit;
}
"

## P3 (FP_FAR_TREES_SNOW) snow-tint header — a `snow_tint` uniform (the far-skin snow colour) the SNOW splice lerps
## the canopy toward. Injected only under the flag (byte-identical off).
const _SNOW_HEAD := "uniform vec3 snow_tint = vec3(0.90, 0.93, 0.97);
uniform float snow_amt = 0.6;
"

static func shader_code() -> String:
	var tail := _CARD_TAIL_FADE if CubeSphere.FP_FAR_TREES_FADE else _CARD_TAIL
	var head := _CARD_HEAD
	if CubeSphere.FP_FAR_TREES_SNOW:
		# Cards are ≤ a few px at their band; the trunk is sub-pixel, so lerp the whole card texel toward snow_tint
		# by the per-instance snow flag (INSTANCE_CUSTOM.z). Off ⇒ no snow uniform / no lerp (byte-identical).
		head += _SNOW_HEAD
		tail = tail.replace("varying float v_hue;", "varying float v_hue;\nvarying float v_snow;")
		tail = tail.replace("v_hue = INSTANCE_CUSTOM.y;", "v_hue = INSTANCE_CUSTOM.y;\n\tv_snow = INSTANCE_CUSTOM.z;")
		tail = tail.replace("ALBEDO = t.rgb * voxi_shade(v_n, sun_dir) * jit;",
			"ALBEDO = mix(t.rgb, snow_tint, v_snow * snow_amt) * voxi_shade(v_n, sun_dir) * jit;")
	return head + VoxiLight.shade_glsl() + tail

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
	if CubeSphere.FP_FAR_TREES_SNOW:
		var sc := BlockCatalog.color_of(BlockCatalog.id_of(&"snow_block"))
		sm.set_shader_parameter("snow_tint", Vector3(sc.r, sc.g, sc.b))
	# Unified: the ONE uniform set (values from VoxiLight — night_floor 0.06 == SHELL_NIGHT_FLOOR, moonshine floor).
	if CubeSphere.FP_SHADE_UNIFIED:
		sm.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		sm.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return sm

# =====================================================================================================================
# Rung-1 mesh shader (P1) — flat radial voxi_shade over the archetype's own vertex COLOR (no atlas). §5.3 trunk-stretch:
# each archetype vertex carries a UV2.x flag (0 = trunk column, 1 = canopy); the vertex shader stretches trunk verts
# and rigidly lifts canopy verts by INSTANCE_CUSTOM.x = (trunk_h − archetype_trunk_h), so ONE per-species mesh renders
# EXACT per-tree heights. INSTANCE_CUSTOM.y = hue jitter, .z = archetype_trunk_h (the stretch denominator). Radial
# normal via the planet_centre uniform (same MultiMesh-forced deviation as the cards — see the class doc).
# =====================================================================================================================
const _MESH_HEAD := "shader_type spatial;
render_mode cull_disabled;
uniform vec3 planet_centre = vec3(0.0, 0.0, 0.0);
"
const _MESH_TAIL := "varying flat vec4 v_col;
void vertex() {
	float flag = UV2.x;
	float delta = INSTANCE_CUSTOM.x;
	float arch = max(INSTANCE_CUSTOM.z, 1.0);
	vec3 v = VERTEX;
	if (flag < 0.5) { v.y += delta * clamp(v.y / arch, 0.0, 1.0); } else { v.y += delta; }
	VERTEX = v;
	vec3 wp = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
	vec3 n = normalize(wp - planet_centre);
	float jit = 1.0 + (INSTANCE_CUSTOM.y - 0.5) * 0.08;
	v_col = vec4(COLOR.rgb * voxi_shade(n, sun_dir) * jit, 1.0);
}
void fragment() {
	ALBEDO = v_col.rgb;
}
"

## P2 (FP_FAR_TREES_FADE) mesh tail: same per-pixel dither DISCARD against INSTANCE_CUSTOM.w. Byte-identical to
## `_MESH_TAIL` except the varying + discard. Off ⇒ `_MESH_TAIL` verbatim.
const _MESH_TAIL_FADE := "varying flat vec4 v_col;
varying flat float v_fade;
float _ft_dither(vec2 fc) { return fract(sin(dot(floor(fc), vec2(12.9898, 78.233))) * 43758.5453); }
void vertex() {
	float flag = UV2.x;
	float delta = INSTANCE_CUSTOM.x;
	float arch = max(INSTANCE_CUSTOM.z, 1.0);
	vec3 v = VERTEX;
	if (flag < 0.5) { v.y += delta * clamp(v.y / arch, 0.0, 1.0); } else { v.y += delta; }
	VERTEX = v;
	vec3 wp = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
	vec3 n = normalize(wp - planet_centre);
	float jit = 1.0 + (INSTANCE_CUSTOM.y - 0.5) * 0.08;
	v_col = vec4(COLOR.rgb * voxi_shade(n, sun_dir) * jit, 1.0);
	v_fade = INSTANCE_CUSTOM.w;
}
void fragment() {
	if (_ft_dither(FRAGCOORD.xy) > v_fade) discard;
	ALBEDO = v_col.rgb;
}
"

static func mesh_shader_code() -> String:
	var tail := _MESH_TAIL_FADE if CubeSphere.FP_FAR_TREES_FADE else _MESH_TAIL
	var head := _MESH_HEAD
	if CubeSphere.FP_FAR_TREES_SNOW:
		# The snow flag packs into the hue slot (INSTANCE_CUSTOM.y = hue + 2·snow); decode it, then lerp ONLY the
		# canopy verts (UV2.x flag == 1) toward snow_tint — snow dusts the leaves, not the trunk. Off ⇒ verbatim.
		head += _SNOW_HEAD
		tail = tail.replace("float jit = 1.0 + (INSTANCE_CUSTOM.y - 0.5) * 0.08;",
			"float _sn = step(1.5, INSTANCE_CUSTOM.y);\n\tfloat _hue = fract(INSTANCE_CUSTOM.y);\n\tfloat jit = 1.0 + (_hue - 0.5) * 0.08;")
		tail = tail.replace("v_col = vec4(COLOR.rgb * voxi_shade(n, sun_dir) * jit, 1.0);",
			"vec3 _alb = mix(COLOR.rgb, snow_tint, _sn * snow_amt * flag);\n\tv_col = vec4(_alb * voxi_shade(n, sun_dir) * jit, 1.0);")
	return head + VoxiLight.shade_glsl() + tail

static func make_mesh_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = mesh_shader_code()
	sm.shader = sh
	var seed := TierPlace.last_sun_dir() if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
	sm.set_shader_parameter("sun_dir", seed)
	if CubeSphere.FP_SHADE_UNIFIED:
		sm.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		sm.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	if CubeSphere.FP_FAR_TREES_SNOW:
		var sc := BlockCatalog.color_of(BlockCatalog.id_of(&"snow_block"))
		sm.set_shader_parameter("snow_tint", Vector3(sc.r, sc.g, sc.b))
	return sm

## FP_FAR_TREES_COLORFIX: the rung-1 mesh MultiMesh buffer stride (floats/instance). With the flag the MultiMesh is
## `use_colors=true, use_custom_data=true` → the RS layout is 12 xform + 4 COLOR + 4 CUSTOM = 20; off ⇒ the shipped
## 12 xform + 4 CUSTOM = 16 (byte-identical). ONE source of truth for every buffer size / write-base / ledger site.
static func mesh_stride() -> int:
	return MESH_STRIDE_CFIX if CubeSphere.FP_FAR_TREES_COLORFIX else MESH_STRIDE

# =====================================================================================================================
# P2 (FP_FAR_TREES_FADE) — the no-pop fade LAW, as pure static functions (ONE source of truth: `_rebuild_*` compute
# the per-instance alpha the dither shader dissolves against, and the gate asserts these same functions' properties).
# All distances are camera distance (blocks). Only consulted under FP_FAR_TREES_FADE.
# =====================================================================================================================

## Rung-1 mesh alpha: dither-IN over [R0, R0+FADE_NEAR_W] (near→mesh), cross-dither OUT over [448±FADE_BAND_W]
## (mesh→card). 1.0 in the fully-owned middle, tapering to 0 at both handoffs.
static func mesh_fade(d: float) -> float:
	var r0 := float(TerrainConfig.near_render_radius())
	var d1 := CubeSphere.FAR_TREES_MESH_MAX
	var fin := smoothstep(r0, r0 + FADE_NEAR_W, d)
	var fout := 1.0 - smoothstep(d1 - FADE_BAND_W, d1 + FADE_BAND_W, d)
	return clampf(fin * fout, 0.0, 1.0)

## keep-fraction keep(d): 1.0 until THIN_START, ramping to THIN_MIN at CARD_MAX (monotone non-increasing).
static func keep_frac(d: float) -> float:
	if d <= THIN_START:
		return 1.0
	var t := clampf((d - THIN_START) / (CubeSphere.FAR_TREES_CARD_MAX - THIN_START), 0.0, 1.0)
	return lerpf(1.0, THIN_MIN, t)

## Deterministic hash-survival alpha: a tree with survival hash `hue` stays lit while keep(d) > hue and DITHER-fades
## out as keep(d) crosses hue (no popping wave — the SAME high-hue trees always retire first, monotone in d).
static func thin_alpha(hue: float, d: float) -> float:
	return smoothstep(hue - THIN_FADE, hue + THIN_FADE, keep_frac(d))

## Rung-2 card alpha: dither-IN at the active handoff (cross-dither at 448 when rung-1 meshes are live, else the
## near-voxel handoff at R0) × the hash-survival thinning toward the fog line.
static func card_fade(d: float, hue: float) -> float:
	var fin: float
	if CubeSphere.FP_FAR_TREES_MESH:
		fin = smoothstep(CubeSphere.FAR_TREES_MESH_MAX - FADE_BAND_W, CubeSphere.FAR_TREES_MESH_MAX + FADE_BAND_W, d)
	else:
		fin = smoothstep(float(TerrainConfig.near_render_radius()), float(TerrainConfig.near_render_radius()) + FADE_NEAR_W, d)
	return clampf(fin * thin_alpha(hue, d), 0.0, 1.0)

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
	if CubeSphere.FP_FAR_TREES_MESH:
		_setup_mesh_band(ring)

## P1: build the 6 per-species archetype ArrayMeshes (from TreeGen.archetype_cells) + their MultiMeshInstance3D
## children (one draw each) sharing one material. Instance allocation FAR_TREES_MESH_INST_MAX/species; the live set
## is bounded FAR_TREES_MESH_TOTAL_MAX across species (nearest-first). Off ⇒ never called (byte-identical).
func _setup_mesh_band(ring: Node3D) -> void:
	_mesh_material = make_mesh_material()
	_arch_trunk.resize(N_SPECIES)
	var species := [TreeGen.SP_OAK, TreeGen.SP_BIRCH, TreeGen.SP_SPRUCE, TreeGen.SP_ACACIA, TreeGen.SP_JUNGLE, TreeGen.SP_CACTUS]
	for col in range(N_SPECIES):
		var built := _build_archetype_mesh(int(species[col]))
		var mesh: ArrayMesh = built["mesh"]
		_arch_trunk[col] = float(built["arch_trunk"])
		_arch_meshes.append(mesh)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		# FP_FAR_TREES_COLORFIX: enable the instance color slot (before instance_count, like use_custom_data) so the
		# gl_compat engine PACKS the color halves properly (from the explicit white quad `_write_mesh_inst` writes)
		# instead of leaving them holding repack garbage that the ungated `COLOR *= instance_color` multiplies in.
		mm.use_colors = CubeSphere.FP_FAR_TREES_COLORFIX
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = CubeSphere.FAR_TREES_MESH_INST_MAX
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "FacetFarTreesMesh%d" % col
		mmi.multimesh = mm
		mmi.material_override = _mesh_material
		mmi.custom_aabb = AABB(Vector3(-12000.0, -12000.0, -12000.0), Vector3(24000.0, 24000.0, 24000.0))
		ring.add_child(mmi)
		_mesh_mms.append(mm)
		_mesh_mmis.append(mmi)

func set_active(new_fid: int) -> void:
	_active_fid = new_fid   # residency is camera-distance driven (rebuilt each step); crossing only re-seeds the centre facet

## Feed the current Sun into the card material (world_manager hub, per frame). Notes the shared weld cache too.
func set_sun_dir(sun_dir: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)
	if _mesh_material != null:
		_mesh_material.set_shader_parameter("sun_dir", sun_dir)
	if CubeSphere.FP_FAR_TERMINATOR_WELD:
		_last_sun_dir = sun_dir

func sun_dir_telemetry() -> Vector3:
	return (_material.get_shader_parameter("sun_dir") if _material != null else Vector3(1.0, 0.0, 0.0))

## P2: wire the edit-overlay chop query (a WorldManager main-thread predicate). Off ⇒ never called (no filter).
func set_chop_query(q: Callable) -> void:
	_chop_query = q

## True iff the tree with lattice base (bx, gy, bz) in `fid` is chopped (its trunk-base cell edited). Only under
## FP_FAR_TREES_FADE with a live query; else false (P0/P1 — no filter). Main-thread (rebuild) call, race-free.
func _is_chopped(fid: int, bx: float, gy: float, bz: float) -> bool:
	if not CubeSphere.FP_FAR_TREES_FADE or not _chop_query.is_valid():
		return false
	return bool(_chop_query.call(fid, Vector3i(int(bx), int(gy) + 1, int(bz))))

# =====================================================================================================================
# Step — reap the enumeration worker, advance dwell eviction, suspend on-surface↔off-surface (inverted like G3),
# then (rate-capped, settled) dispatch the nearest missing facet's enumeration and rebuild the card buffer.
# =====================================================================================================================
## Set the tier's node visibility from the off-surface state. Off ⇒ EXACTLY `not offsurf` (byte-identical shipped
## behaviour). Under FP_FAR_TREES_COLORFIX (§4.2): any offsurf frame latches `_stale`, and the tier stays hidden
## on the offsurf→onsurf flip until the first completed rebuild clears the latch (correct-or-nothing, no stale-band
## garbage frame). Cleared by `_rebuild_*`'s caller (step / debug_rebuild) after the first real rebuild.
func _apply_visibility(offsurf: bool) -> void:
	if CubeSphere.FP_FAR_TREES_COLORFIX and offsurf:
		_stale = true
	var show := (not offsurf) and not (CubeSphere.FP_FAR_TREES_COLORFIX and _stale)
	if _mmi != null:
		_mmi.visible = show
	for mmi in _mesh_mmis:
		(mmi as MultiMeshInstance3D).visible = show

func step(settled := true, credit_ok := true, cam_render := Vector3.ZERO) -> void:
	_reap_enum()
	# NO far-over-near / orbit suspend (§4.2): trees show ON-surface only; off-surface the whole node is hidden and
	# the instance set is frozen (mirror of G3's off-surface-only visibility, inverted).
	var offsurf := (_ring as FacetFarRing).shell_offsurface()
	_apply_visibility(offsurf)
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
	var centre := (_ring as FacetFarRing).render_centre()
	if _material != null:
		_material.set_shader_parameter("planet_centre", centre)
	if _mesh_material != null:
		_mesh_material.set_shader_parameter("planet_centre", centre)
	var cam_abs := _cam_to_absolute(cam_render)
	var wanted := _wanted_facets(cam_abs)                  # Earth facets within the card band, nearest-first
	_advance_dwell(wanted)
	if _enum_fid < 0:
		_dispatch_nearest_missing(wanted)                 # one facet / job (paced under the settle gate)
	# Rung-1 meshes [R0, FAR_TREES_MESH_MAX) FIRST, so the cards can retreat to [FAR_TREES_MESH_MAX, CARD_MAX] — the
	# 448 handoff is EXCLUSIVE (a tree renders in exactly one band, no double). Off ⇒ cards keep the full [R0, CARD_MAX].
	if CubeSphere.FP_FAR_TREES_MESH:
		_rebuild_meshes(cam_abs, wanted)
	if CubeSphere.FP_FAR_TREES_CARDS:
		_rebuild_cards(cam_abs, wanted)
	# FP_FAR_TREES_COLORFIX §4.2: the first completed rebuild after an offsurf flip clears the hide latch — the next
	# `_apply_visibility` shows the (now correct-band) tier. Off ⇒ inert (_stale is never set). See `_apply_visibility`.
	if CubeSphere.FP_FAR_TREES_COLORFIX:
		_stale = false

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
			# P3 (FP_FAR_TREES_SNOW): the snow-dusted canopy fires on the EXACT far-skin snow-line predicate
			# (FarPalette.color_for / _snow_depth: g >= SEA_LEVEL AND ClimateModel.surface_temperature(g, t) < 0),
			# t = the column's climate temperature (column_profile.w) — so the far snow variant selects the SAME
			# columns the near voxel trees + terrain snow-cap. Gated on the flag ⇒ 0 with SNOW off (byte-identical).
			var snow := 0
			if CubeSphere.FP_FAR_TREES_SNOW and base.y >= TerrainConfig.SEA_LEVEL:
				var t_col := TerrainConfig.column_profile(base.x, base.z, ctx).w
				if ClimateModel.surface_temperature(base.y, t_col) < 0.0:
					snow = 1
			recs.push_back(sx); recs.push_back(sy); recs.push_back(sz)
			recs.push_back(rx); recs.push_back(ry); recs.push_back(rz)
			recs.push_back(float((species - 1) | (snow << 3)))     # low 3 bits = atlas column 0..5; bit 3 = snow flag
			recs.push_back(float(trunk_h) + hue)                    # floor = trunk_h, frac = hue jitter phase
			# Lattice base cell (bx, gy, bz) — the P2 edit-overlay chop filter matches the trunk-base cell (bx, gy+1, bz)
			# against WorldManager._edits via FacetAtlas.edit_key(fid, cell) at rebuild time (current edits, main thread).
			recs.push_back(float(base.x)); recs.push_back(float(base.y)); recs.push_back(float(base.z))
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
	# The card-band INNER radius is the ONE source of truth `card_inner_radius()`: FAR_TREES_MESH_MAX when rung-1
	# meshes own [R0, 448) (exclusive handoff at 448, no double-render), else the P0 full [R0, CARD_MAX] band. Under
	# FP_FAR_TREES_FADE the floor drops by FADE_BAND_W so the cards OVERLAP the mesh fade-out for the cross-dither.
	var fade := CubeSphere.FP_FAR_TREES_FADE
	var r0 := card_inner_radius() - (FADE_BAND_W if (fade and CubeSphere.FP_FAR_TREES_MESH) else 0.0)
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
			var packed: float = recs[o + 7]
			var trunk_h := floorf(packed)
			var hue := packed - trunk_h
			# P2 fade/thin: per-instance alpha the dither shader dissolves against; drop fully-faded/retired trees
			# (bounds the transient overlap count + far card count). FADE off ⇒ alpha 1.0 (no dither, hard band).
			var alpha := 1.0
			if fade:
				alpha = card_fade(dist, hue)
				if alpha <= FADE_EPS:
					continue
			# P2 chop filter: a chopped tree (trunk-base cell edited) never reappears far. No-op when FADE off / no query.
			if _is_chopped(int(fid), recs[o + 8], recs[o + 9], recs[o + 10]):
				continue
			var rx: float = recs[o + 3]; var ry: float = recs[o + 4]; var rz: float = recs[o + 5]
			var raw := int(recs[o + 6])
			var col := float(raw & 7)                     # low 3 bits = species atlas column
			var snow := 1.0 if (raw & 8) != 0 else 0.0    # bit 3 = P3 snow flag (always 0 with SNOW off)
			# .w carries the dither alpha under FADE (0.0 off); .z carries the snow flag (0.0 off) — byte-identical.
			_write_card(buf, n * CARD_STRIDE, sx, sy, sz, rx, ry, rz, trunk_h, col, hue, alpha if fade else 0.0, snow)
			n += 1
	_mm.set_buffer(buf)
	_mm.visible_instance_count = n
	_last_buf = buf
	_live_instances = n
	_capped = capped
	if capped:
		print("  FacetFarTrees: card cap ", cap, " hit (nearest-first fill) — increase FAR_TREES_CARD_INST_MAX or start thinning")

## Write ONE card instance: a radial-up basis (Y=radial, X/Z=stable tangents) scaled by canopy width + tree height,
## origin at the sunk base; custom data = (species_col, hue, 0, fade). `fade` is the dither alpha (1.0 = fully in;
## always 1.0 with FP_FAR_TREES_FADE off → byte-identical). Buffer = TRANSFORM_3D's 12 floats + the 4 custom floats.
func _write_card(buf: PackedFloat32Array, base: int, sx: float, sy: float, sz: float,
		rx: float, ry: float, rz: float, trunk_h: float, col: float, hue: float, fade := 1.0, snow := 0.0) -> void:
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
	buf[base + 12] = col; buf[base + 13] = hue; buf[base + 14] = snow; buf[base + 15] = fade

# --- P1 rung-1 mesh band rebuild ------------------------------------------------------------------------------------

var _last_mesh_bufs: Array = []        # per-species last mesh buffers (gate read-back only)

## Rebuild the 6 per-species mesh MultiMesh buffers: walk the wanted facets nearest-first, keep trees whose base
## camera distance is in [R0, FAR_TREES_MESH_MAX) (the mesh band — cards own [MESH_MAX, CARD_MAX]), bucket by
## species, fill nearest-first under the per-species allocation AND the FAR_TREES_MESH_TOTAL_MAX global live cap.
func _rebuild_meshes(cam_abs: Vector3, wanted: Array) -> void:
	var r0 := float(TerrainConfig.near_render_radius())
	var d1 := CubeSphere.FAR_TREES_MESH_MAX
	# Under FADE the mesh band extends UP by FADE_BAND_W so it overlaps the card fade-in for the 448 cross-dither.
	var fade := CubeSphere.FP_FAR_TREES_FADE
	var d1_hi := (d1 + FADE_BAND_W) if fade else d1
	var per_cap := CubeSphere.FAR_TREES_MESH_INST_MAX
	var total_cap := CubeSphere.FAR_TREES_MESH_TOTAL_MAX
	var bufs: Array = []
	var counts := PackedInt32Array(); counts.resize(N_SPECIES); counts.fill(0)
	var stride := mesh_stride()
	for c in range(N_SPECIES):
		var b := PackedFloat32Array(); b.resize(per_cap * stride); bufs.append(b)
	var total := 0
	var capped := false
	for fid in wanted:
		if total >= total_cap:
			capped = true
			break
		if not _cache.has(int(fid)):
			continue
		var recs: PackedFloat32Array = _cache[int(fid)]
		var m := recs.size() / REC_FLOATS
		for i in range(m):
			if total >= total_cap:
				capped = true
				break
			var o := i * REC_FLOATS
			var sx: float = recs[o + 0]; var sy: float = recs[o + 1]; var sz: float = recs[o + 2]
			var dx := sx - cam_abs.x; var dy := sy - cam_abs.y; var dz := sz - cam_abs.z
			var dist := sqrt(dx * dx + dy * dy + dz * dz)
			if dist < r0 or dist >= d1_hi:
				continue                      # outside the mesh band (near field owns <R0; cards own the far side)
			var alpha := 1.0
			if fade:
				alpha = mesh_fade(dist)
				if alpha <= FADE_EPS:
					continue                  # fully faded out past the 448 cross-dither → drop
			if _is_chopped(int(fid), recs[o + 8], recs[o + 9], recs[o + 10]):
				continue                      # chopped tree never reappears as a far mesh
			var raw := int(recs[o + 6])
			var col := raw & 7                # low 3 bits = species; bit 3 = P3 snow flag
			var snow := 1.0 if (raw & 8) != 0 else 0.0
			if col < 0 or col >= N_SPECIES:
				continue
			if counts[col] >= per_cap:
				capped = true
				continue                      # this species' alloc is full; other species may still fill
			var rx: float = recs[o + 3]; var ry: float = recs[o + 4]; var rz: float = recs[o + 5]
			var packed: float = recs[o + 7]
			var trunk_h := floorf(packed)
			var hue := packed - trunk_h
			var arch := _arch_trunk[col] if col < _arch_trunk.size() else 4.0
			_write_mesh_inst(bufs[col], counts[col] * stride, sx, sy, sz, rx, ry, rz, trunk_h - arch, hue, arch, alpha if fade else 0.0, snow)
			counts[col] += 1
			total += 1
	for c in range(N_SPECIES):
		var mm: MultiMesh = _mesh_mms[c]
		mm.set_buffer(bufs[c])
		mm.visible_instance_count = counts[c]
	_last_mesh_bufs = bufs
	_mesh_live = total
	_mesh_capped = capped
	if capped:
		print("  FacetFarTrees: mesh cap (", total_cap, " total / ", per_cap, " per-species) hit (nearest-first)")

## Write ONE archetype mesh instance: a UNIT radial-up basis (Y=radial, X/Z=tangents — block units, NO extra scale,
## the mesh is authored in blocks), origin at the sunk base; custom = (delta=trunk_h−arch, hue, arch_trunk, 0) for
## the shader's per-tree trunk-stretch. Same 12-transform-then-4-custom buffer layout as the cards.
func _write_mesh_inst(buf: PackedFloat32Array, base: int, sx: float, sy: float, sz: float,
		rx: float, ry: float, rz: float, delta: float, hue: float, arch: float, fade := 0.0, snow := 0.0) -> void:
	var r := Vector3(rx, ry, rz)
	var up := Vector3(0.0, 1.0, 0.0)
	if absf(r.dot(up)) > 0.99:
		up = Vector3(1.0, 0.0, 0.0)
	var t1 := r.cross(up).normalized()
	var t2 := r.cross(t1).normalized()
	buf[base + 0] = t1.x; buf[base + 1] = r.x; buf[base + 2] = t2.x; buf[base + 3] = sx
	buf[base + 4] = t1.y; buf[base + 5] = r.y; buf[base + 6] = t2.y; buf[base + 7] = sy
	buf[base + 8] = t1.z; buf[base + 9] = r.z; buf[base + 10] = t2.z; buf[base + 11] = sz
	# FP_FAR_TREES_COLORFIX: write an explicit WHITE (1,1,1,1) instance color at floats [12..15] so the gl_compat
	# engine packs the color slot to half(1,1,1,1) — the ungated `COLOR *= instance_color` (scene.glsl) then becomes
	# an identity ×1 instead of multiplying albedo by the repack garbage. Custom shifts to [16..19]. Off ⇒ custom at
	# [12..15] (the shipped 16-float layout, byte-identical) — no color slot exists.
	var co := base + 12
	if CubeSphere.FP_FAR_TREES_COLORFIX:
		buf[base + 12] = 1.0; buf[base + 13] = 1.0; buf[base + 14] = 1.0; buf[base + 15] = 1.0
		co = base + 16
	# custom .w carries the dither alpha under FADE (0.0 off). The snow flag (P3) has no spare custom slot, so it packs
	# into the hue slot: y = hue + 2·snow (hue ∈ [0,1) so the SNOW shader reads snow = step(1.5,y), hue = fract(y)).
	# SNOW off ⇒ snow 0 ⇒ y = hue. INSTANCE_CUSTOM still decodes from this (properly-packed) slot with use_colors=true.
	buf[co + 0] = delta; buf[co + 1] = hue + 2.0 * snow; buf[co + 2] = arch; buf[co + 3] = fade

## Build ONE species' archetype ArrayMesh from its `TreeGen.archetype_cells` cube set: exposed-face voxel meshing
## (internal faces between two solid cells culled). Per-vertex COLOR from BlockCatalog.color_of; UV2.x flag = 0 for
## trunk (log/cactus) cells, 1 for canopy (leaf) cells — the shader's trunk-stretch selector. `arch_trunk` = the
## tallest trunk-column cell (the stretch denominator). Returns {mesh, arch_trunk}.
func _build_archetype_mesh(species: int) -> Dictionary:
	var cells := TreeGen.archetype_cells(species)
	var trunk_ids := {BlockCatalog.WOOD: true}
	for nm in [&"birch_log", &"spruce_log", &"jungle_log", &"acacia_log", &"cactus"]:
		trunk_ids[BlockCatalog.id_of(nm)] = true
	var solid := {}
	var arch_trunk := 1
	for c in cells:
		var cv: Vector4i = c
		solid[Vector3i(cv.x, cv.y, cv.z)] = cv.w
		if trunk_ids.has(cv.w) and cv.x == 0 and cv.z == 0:
			arch_trunk = maxi(arch_trunk, cv.y)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for key in solid.keys():
		var p: Vector3i = key
		var id := int(solid[key])
		var flag := 0.0 if trunk_ids.has(id) else 1.0
		var colr := BlockCatalog.color_of(id); colr.a = 1.0
		for d in dirs:
			if solid.has(p + d):
				continue                       # internal face — culled
			_mesh_face(verts, cols, uv2, idx, Vector3(p.x, p.y, p.z), d, colr, flag)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return {"mesh": mesh, "arch_trunk": arch_trunk}

## Emit one cube face (2 tris, 4 verts) for the cube centred at `c` (spans ±0.5), facing unit axis `dir`.
func _mesh_face(verts: PackedVector3Array, cols: PackedColorArray, uv2: PackedVector2Array, idx: PackedInt32Array,
		c: Vector3, dir: Vector3i, colr: Color, flag: float) -> void:
	var dv := Vector3(dir.x, dir.y, dir.z)
	var u := Vector3(0, 1, 0) if dir.x != 0 else Vector3(1, 0, 0)
	var v := Vector3(0, 0, 1) if dir.y != 0 else (Vector3(0, 0, 1) if dir.x != 0 else Vector3(0, 1, 0))
	var fc := c + dv * 0.5
	var a := fc - u * 0.5 - v * 0.5
	var b := fc + u * 0.5 - v * 0.5
	var e := fc + u * 0.5 + v * 0.5
	var f := fc - u * 0.5 + v * 0.5
	var base := verts.size()
	verts.push_back(a); verts.push_back(b); verts.push_back(e); verts.push_back(f)
	for _k in range(4):
		cols.push_back(colr)
		uv2.push_back(Vector2(flag, 0.0))
	idx.push_back(base + 0); idx.push_back(base + 1); idx.push_back(base + 2)
	idx.push_back(base + 0); idx.push_back(base + 2); idx.push_back(base + 3)

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
	# P1 rung-1: 6 per-species mesh MultiMesh buffers (allocated at FAR_TREES_MESH_INST_MAX each) + the archetype
	# ArrayMeshes. Zero when the mesh band isn't built (FP_FAR_TREES_MESH off).
	var mesh_buf_b := 0
	if not _mesh_mms.is_empty():
		mesh_buf_b = N_SPECIES * CubeSphere.FAR_TREES_MESH_INST_MAX * mesh_stride() * 4  # +48 KB under COLORFIX (stride 20)
		for am in _arch_meshes:
			var mm := am as ArrayMesh
			if mm.get_surface_count() > 0:
				var a := mm.surface_get_arrays(0)
				mesh_buf_b += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * (3 + 4 + 2) * 4
	var lru_b := 0
	for fid in _cache.keys():
		lru_b += (_cache[fid] as PackedFloat32Array).size() * 4
	return buf_b + atlas_b + mesh_b + mesh_buf_b + lru_b

## The card-band INNER radius (ONE source of truth). FAR_TREES_MESH_MAX (448) when rung-1 meshes are live so the
## cards retreat past the exclusive handoff; else near_render_radius() — the P0 [128, CARD_MAX] band, BYTE-IDENTICAL
## with FP_FAR_TREES_MESH off (what's merged). Gate G-FT-MESH-HANDOFF asserts this in BOTH flag states.
func card_inner_radius() -> float:
	return CubeSphere.FAR_TREES_MESH_MAX if CubeSphere.FP_FAR_TREES_MESH else float(TerrainConfig.near_render_radius())

func live_instances() -> int: return _live_instances
func was_capped() -> bool: return _capped
func last_enum_ms() -> float: return _last_enum_ms
func cached_facets() -> int: return _cache.size()
func mesh_live_instances() -> int: return _mesh_live
func mesh_was_capped() -> bool: return _mesh_capped
func mesh_visible(col: int) -> int: return (_mesh_mms[col] as MultiMesh).visible_instance_count if col < _mesh_mms.size() else 0
func mesh_draw_count() -> int:
	var d := 0
	for c in range(_mesh_mms.size()):
		if (_mesh_mms[c] as MultiMesh).visible_instance_count > 0: d += 1
	return d
func mesh_arch_trunk(col: int) -> float: return _arch_trunk[col] if col < _arch_trunk.size() else 0.0
func mesh_tri_count(col: int) -> int:
	if col >= _arch_meshes.size(): return 0
	var mm := _arch_meshes[col] as ArrayMesh
	if mm.get_surface_count() == 0: return 0
	return (mm.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
func mesh_buffer(col: int) -> PackedFloat32Array:
	return _last_mesh_bufs[col] if col < _last_mesh_bufs.size() else PackedFloat32Array()

var _last_buf: PackedFloat32Array = PackedFloat32Array()   # last rebuilt card buffer (gate read-back only)

## Test hooks (gate-only): drive the card rebuild without a live FacetFarRing (no camera plumbing / no worker).
func debug_set_cache(fid: int, recs: PackedFloat32Array) -> void:
	_cache[int(fid)] = recs
	_touch_lru(int(fid))

func debug_rebuild(wanted: Array, cam_abs: Vector3) -> int:
	if CubeSphere.FP_FAR_TREES_MESH:
		_rebuild_meshes(cam_abs, wanted)
	_rebuild_cards(cam_abs, wanted)
	if CubeSphere.FP_FAR_TREES_COLORFIX:
		_stale = false                        # mirror step(): the first completed rebuild clears the hide latch
	return _live_instances

## FP_FAR_TREES_COLORFIX gate hooks (§4): drive the visibility latch + read the mesh MultiMesh color-slot state.
func debug_apply_visibility(offsurf: bool) -> void:
	_apply_visibility(offsurf)
func mmi_visible() -> bool:
	return _mmi != null and _mmi.visible
func is_stale() -> bool:
	return _stale
func mesh_uses_colors() -> bool:
	return (not _mesh_mms.is_empty()) and (_mesh_mms[0] as MultiMesh).use_colors

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
