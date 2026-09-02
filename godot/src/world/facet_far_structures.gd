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
const STRUCT_EPOCH_STILL := 0.5              # FP_STRUCT_REG_EPOCH: camera-parked tolerance (blocks) for the O(1) skip

# FP_STRUCT_CARDS (docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md) — the far-village impostor-card sink layout. Mirrors the
# far-tree card stride (12 TRANSFORM_3D + 4 custom = 16). STRUCT_CARD_PREC packs the per-GEN-record card params.
const STRUCT_CARD_STRIDE := 16                # MultiMesh floats/instance (12 transform + 4 custom)
const STRUCT_CARD_PREC := 12                  # precomputed floats/record: [is_card, arch, w_s, w_f, H, ox,oy,oz, fx,fy,fz, spare]

var _ring: Node3D = null
var _mi: MeshInstance3D = null                # LOD-A merged band mesh (one draw)
var _mesh: ArrayMesh = null
var _material: ShaderMaterial = null
var _shell_material: ShaderMaterial = null    # FP_STRUCT_SHELL_BAND: zone-B UNLIT vertex-colour material (never built off-flag)
var _active_fid := -1

# FP_STRUCT_CARDS: the impostor-card sink (all null / empty off-flag ⇒ byte-identical — never constructed / read). The
# card MMI rides the SAME ring the cube _mi rides, so placement / anchor / SN3 orbit transforms are inherited exactly.
# `_card_prec` keys a GEN record's root → its 12 precomputed card floats (filled in _resnapshot beside _centres — the
# REG_EPOCH coupling); root keying is sort-safe (the _rebuild nearest-first sort re-orders records) and never stale
# (the whole dict is rebuilt in _resnapshot, and _rebuild only looks up roots in the current snapshot). Risk 7 (§13).
var _card_mmi: MultiMeshInstance3D = null
var _card_mm: MultiMesh = null
var _card_mesh: ArrayMesh = null
var _card_material: ShaderMaterial = null
var _card_atlas: ImageTexture = null
var _card_prec: Dictionary = {}
var _live_cards := 0                           # last rebuild's live card instances (telemetry / gate read-back)
var _card_capped := false                      # last rebuild hit STRUCT_CARD_INST_MAX
var _dbg_card_us := 0                           # card-sink self-time inside the last _rebuild (µs) — st_crb_us
var _card_cbuf: PackedFloat32Array = PackedFloat32Array()       # persistent card instance buffer (reused, resized once — no per-rebuild 128 KB alloc). Gate read-back reads this directly (a second held reference would force a COW fork every rebuild).

# FP_STRUCT_CARD_STAGE / FP_STRUCT_CARD_ALT_BAND telemetry (all 0 off-flag). st_sort_us = _rebuild ordering time;
# st_mat_us = the last snapshot materialize (registry duplicate); st_prec_us = the last precompute drain pass.
var _dbg_sort_us := 0
var _dbg_mat_us := 0
var _dbg_prec_us := 0

# FP_STRUCT_CARD_STAGE (§6): double-buffered snapshot drain (all inert off-flag). `_snap_next/_centres_next/_card_prec_
# next/_snap_next_rev_sum` are the fill-in-progress buffers; the LIVE _snapshot/_centres/_card_prec keep rendering until
# the swap. `_snap_fill` is the drain cursor (−1 idle); `_snap_fill_ver` the version being filled; `_snap_ctx` the
# GenCtx cache persisted across passes (GATE_MEMO hits); `_snap_pending` true while a fill is in flight.
var _snap_next: Array = []
var _centres_next: PackedVector3Array = PackedVector3Array()
var _card_prec_next: Dictionary = {}
var _snap_next_rev_sum := 0
var _snap_fill := -1
var _snap_fill_ver := 0
var _snap_ctx: Dictionary = {}
var _snap_pending := false
# §2 churn coalescing: a fill, once started, is FINISHED (never restarted mid-flight); a version that drifts during a
# fill is caught up by the NEXT fill after the swap, rate-limited so records() materialize can't fire faster than
# STRUCT_STEP_MS. `_last_mat_ms` anchors that rate cap; `_dbg_snap_restarts` counts catch-up (post-swap re-)fills.
var _last_mat_ms := -1000000
var _snap_catch_up := false                    # the version drifted DURING the last fill (sustained drift, e.g. descent) ⇒ rate-limit the next fill
var _dbg_snap_restarts := 0

# FP_STRUCT_CARD_ALT_BAND (§8): the card altitude zone (0=S,1=B,2=O; −1 off) + current tier_fade + wake fade-in latch.
var _card_zone := -1
var _dbg_card_fade := 1.0
var _wake_t0 := 0                              # ms when the current wake fade-in started (0 = none)
var _prev_live_cards := 0                      # _live_cards before the last swap — detects the STRUCT_WAKE_JUMP
var _pending_wake_check := false               # a swap just landed — the next _rebuild tail evaluates the wake jump

# FP_STRUCT_SHELL_BAND A/B / gate read-back: last computed zone (0=S,1=B,2=O; -1 flag off) + the altitude the law saw.
var _dbg_shell_zone := -1
var _dbg_shell_h := 0.0
var _dbg_shell_offsurf := false

# wired queries (all Callables; unset ⇒ inert — the tier renders nothing / degrades, never crashes)
var _registry_query: Callable = Callable()    # () -> Array of structure records (StructureTracker.registry)
var _sampler: Callable = Callable()           # (fid, Vector3i) -> placed block id (WorldManager.structure_cell_at)
var _near_query: Callable = Callable()        # (fid, AABB) -> NearPresence COVERED|NOT_COVERED|UNKNOWABLE
var _edits_rev_query: Callable = Callable()   # () -> int (WorldManager.edit_count) — a chop re-arms within one step
var _version_query: Callable = Callable()     # FP_STRUCT_REG_EPOCH: () -> int registry version (WorldManager.structure_registry_version)

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
# FP_STRUCT_WALK_CALM (Lever 1): membership band-fingerprint. `_band_fp` is recomputed every _probe_pass (XOR of
# _root_hash × band-code over every registered structure); `_last_band_fp` is latched at each real rebuild. `_band`
# keys root -> last-latched band code (0=FLOOR,1=ANNULUS,2=BAND,3=OUT) for the FP_STRUCT_HANDOFF_HYST dead-band.
# All computed/read only under FP_STRUCT_WALK_CALM ⇒ byte-identical off.
var _band_fp := 0
var _last_band_fp := 0
var _band: Dictionary = {}

# FP_STRUCT_REG_EPOCH: the version-gated prelude cache (all inert off-flag — never read/written on the shipped path).
# `_snapshot` holds the ONE per-version registry materialization; `_centres[i]` is _snapshot[i]'s precomputed world
# centre (so _structure_centre → lattice_to_world64 is NOT re-run per step); `_snap_rev_sum` its rev-sum. `_last_
# version` latches the last materialized version; `_last_scan_cam` the camera at the last FULL probe (the O(1)-skip
# datum); `_annulus_empty_last` whether that probe found ZERO structures in the near-handoff annulus (⇒ no cull can
# arrive while parked). `_dbg_step_us` is the last step() prelude cost (µs) — surfaced in ALL flag states (telemetry).
var _snapshot: Array = []
var _centres: PackedVector3Array = PackedVector3Array()
var _snap_rev_sum := 0
var _last_version := -0x7fffffff
var _last_scan_cam := Vector3(NAN, NAN, NAN)
var _annulus_empty_last := false
var _dbg_step_us := 0

# FP_STRUCT_BAKE_STAGE drain state (inert off-flag: never set, never read on the shipped path)
var _bake_pending := false                    # un-baked in-band records remain — re-dispatch every frame
var _last_commit_ms := 0                      # merged-mesh commit cadence anchor (drain frames skip commits)
var _dbg_stage_passes := 0
var _dbg_stage_baked_last := 0
var _dbg_stage_ms_last := 0.0

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
	var head := _HEAD
	if CubeSphere.FP_STRUCT_CULL_BACK:                          # cull_disabled → cull_back (single occurrence in _HEAD)
		head = head.replace("cull_disabled", "cull_back")
	return head + VoxiLight.shade_glsl() + _TAIL

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
# FP_STRUCT_SHELL_BAND shell material — UNLIT vertex colour + a `tier_fade` screen-space dither DISSOLVE. The on-surface
# `_material` (voxi_shade, planet_centre uniform) renders BLACK in the orbital-shell frame off-surface (the defect fixed
# once for the reverted aggregate box, commit 276cebd `_make_agg_material`), so zone B renders the merged mesh with THIS
# material instead: ALBEDO = the baked per-house COLOR.rgb (BROWN), unshaded ⇒ no radial-normal black-out. tier_fade
# scales the whole-tier dissolve over [FT_SHELL_FADE_ALT, FT_SHELL_HIDE_ALT] (the far-trees `_ft_dither` discard,
# adapted from per-instance v_fade to one uniform since this is ONE merged mesh, not a MultiMesh). Only ever
# constructed under the flag ⇒ off is byte-identical (material_override stays `_material`, this object is never made).
const _SHELL_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float tier_fade = 1.0;
varying flat vec4 v_col;
float _sd_dither(vec2 fc) { return fract(sin(dot(floor(fc), vec2(12.9898, 78.233))) * 43758.5453); }
void vertex() { v_col = COLOR; }
void fragment() {
	if (_sd_dither(FRAGCOORD.xy) > tier_fade) discard;
	ALBEDO = v_col.rgb;
}
"

static func make_shell_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	var code := _SHELL_SHADER
	if CubeSphere.FP_STRUCT_CULL_BACK:                          # cull_disabled → cull_back
		code = code.replace("cull_disabled", "cull_back")
	if CubeSphere.FP_STRUCT_SHADER_LITE:                        # skip the per-fragment sin() dither when fully opaque (no-op discard)
		code = code.replace("if (_sd_dither(FRAGCOORD.xy) > tier_fade) discard;",
			"if (tier_fade < 1.0 && _sd_dither(FRAGCOORD.xy) > tier_fade) discard;")
	sh.code = code
	sm.shader = sh
	sm.set_shader_parameter("tier_fade", 1.0)
	return sm

# =====================================================================================================================
# FP_STRUCT_CARDS card shader (docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md §8) — HEAD + VoxiLight.shade_glsl() + TAIL, the
# far-tree card composition, PLUS the in-shader billboard-on-a-sphere + view-sector-select math (§8.1): the vertical
# quad faces the camera about the RADIAL up-axis and its atlas azimuth column is chosen from the house→camera azimuth
# in the house's (e_f, e_s) frame — so camera rotation / orbiting rewrites NOTHING on the CPU. The roof cap is a
# house-local tangent quad. ALBEDO = atlas.rgb · voxi_shade(radial n̂, sun_dir) (the ONE far-tier lighting law).
# Never read vertex COLOR (use_colors=false — the §1 gl_compat COLOR-slot rule). Only compiled under FP_STRUCT_CARDS.
#
# CRITICAL (world_vertex_coords): under this render_mode the vertex() shader RECEIVES VERTEX already in WORLD space
# (MODEL·local, ~planet-radius magnitude), so the unit-quad corner is reconstructed from UV/UV2 (lx = UV.x−0.5;
# billboard ly = 1−UV.y; cap lz = UV.y−0.5), NEVER read from VERTEX — VERTEX is only WRITTEN (the world position out).
# Azimuth sector: canonical x̂↦−e_f, ẑ↦+e_s ⇒ α = atan2(−sa, ca) (mirror of sa). Cap u is canonical +x̂ = −e_f ⇒ the
# local x is negated along mx. Tile UV is remapped onto the 3-px-pad inset (atlas_uv_lo/span) so no size/float pop.
# =====================================================================================================================
const _CARD_HEAD := "shader_type spatial;
render_mode cull_disabled, world_vertex_coords;
uniform sampler2D house_atlas : source_color, filter_nearest;
uniform vec3 planet_centre = vec3(0.0, 0.0, 0.0);
uniform float atlas_cols = 9.0;
uniform float atlas_rows = 10.0;
uniform float atlas_uv_lo = 0.109375;
uniform float atlas_uv_span = 0.78125;
"
const _CARD_TAIL := "varying vec2 v_uv;
varying vec3 v_n;
void vertex() {
	vec3 o  = MODEL_MATRIX[3].xyz;
	vec3 mx = MODEL_MATRIX[0].xyz;
	vec3 my = MODEL_MATRIX[1].xyz;
	vec3 mz = MODEL_MATRIX[2].xyz;
	float s   = length(mx);
	vec3 up_n = normalize(my);
	float arch = floor(INSTANCE_CUSTOM.x);
	float w_s  = INSTANCE_CUSTOM.y;
	float w_f  = INSTANCE_CUSTOM.z;
	float lx = UV.x - 0.5;
	vec3 vc  = CAMERA_POSITION_WORLD - o;
	vec3 fh  = vc - up_n * dot(vc, up_n);
	float fl = length(fh);
	fh = (fl > 1e-4) ? fh / fl : normalize(mx);
	vec3 wp; float col;
	if (UV2.x < 0.5) {
		float ly = 1.0 - UV.y;
		vec3 raxis = normalize(cross(up_n, fh));
		float ca = dot(fh, normalize(mx));
		float sa = dot(fh, normalize(mz));
		float halfw = 0.5 * (w_s * abs(ca) + w_f * abs(sa)) * s;
		wp = o + raxis * (lx * 2.0 * halfw) + my * ly;
		float alpha = atan(-sa, ca);
		float kk = floor(alpha * (8.0 / 6.2831853) + 0.5);
		col = mod(kk + 8.0, 8.0);
	} else {
		float lz = UV.y - 0.5;
		wp = o + mx * (-(lx) * w_f) + mz * (lz * w_s) + my;
		col = 8.0;
	}
	VERTEX = wp;
	vec2 uv_in = atlas_uv_lo + UV * atlas_uv_span;
	v_uv = vec2((col + uv_in.x) / atlas_cols, (arch + uv_in.y) / atlas_rows);
	v_n  = normalize(wp - planet_centre);
}
void fragment() {
	vec4 t = texture(house_atlas, v_uv);
	if (t.a < 0.5) discard;
	ALBEDO = t.rgb * voxi_shade(v_n, sun_dir);
}
"

## §8.3 Bayer 4×4 (no transcendental, opacity-guarded) — spliced into the fragment ONLY under FP_STRUCT_SHELL_BAND.
const _CARD_BAYER := "float _bayer4(vec2 fc) {
	int bx = int(mod(fc.x, 4.0));
	int by = int(mod(fc.y, 4.0));
	int bi = by * 4 + bx;
	float m[16] = float[](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	return (m[bi] + 0.5) / 16.0;
}
"

static func card_shader_code() -> String:
	var head := _CARD_HEAD
	var tail := _CARD_TAIL
	# NOTE (deviation from §11 arm B): the card shader stays cull_disabled even under FP_STRUCT_CULL_BACK. That lever
	# targets the CLOSED merged-cube house mesh (~80k tris); the vertical billboard is rebuilt to face the camera in
	# the vertex shader with a winding that flips with the view, so cull_back would hide it half the time (a hole). The
	# card tier is ~16k verts worst case (§9) — back-culling saves nothing measurable — so it is deliberately excluded.
	# §8.4: the whole-tier `tier_fade` dissolve (Bayer, guarded — §8.3) so cards dither out over the shell band as the
	# camera climbs to orbit (handoff to the fine-map roof skin). v_fade (per-instance, 1.0 in P0) × tier_fade (per step).
	if CubeSphere.FP_STRUCT_SHELL_BAND:
		head += "uniform float tier_fade = 1.0;\n"
		tail = tail.replace("varying vec3 v_n;", "varying vec3 v_n;\nvarying flat float v_fade;")
		tail = tail.replace("v_n  = normalize(wp - planet_centre);",
			"v_n  = normalize(wp - planet_centre);\n\tv_fade = INSTANCE_CUSTOM.w;")
		tail = tail.replace("if (t.a < 0.5) discard;",
			"if (t.a < 0.5) discard;\n\tfloat _f = v_fade * tier_fade;\n\tif (_f < 0.999 && _bayer4(FRAGCOORD.xy) > _f) discard;")
		tail = _CARD_BAYER + tail
	return head + VoxiLight.shade_glsl() + tail

static func make_card_material() -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = card_shader_code()
	sm.shader = sh
	# FP_FAR_TERMINATOR_WELD: seed from the shared last-live Sun (never the (1,0,0) fake-noon default).
	var seed := TierPlace.last_sun_dir() if CubeSphere.FP_FAR_TERMINATOR_WELD else Vector3(1.0, 0.0, 0.0)
	sm.set_shader_parameter("sun_dir", seed)
	sm.set_shader_parameter("atlas_cols", float(StructCardKit.COLS))
	sm.set_shader_parameter("atlas_rows", float(StructCardKit.ROWS))
	# P1-4 pad compensation: the raster puts tile content in the 3-px-pad inset (texels [PAD, TILE−PAD−1]); remap the
	# quad's tile-local UV [0,1] onto that inset (texel centres) so the house fills the quad edge-to-edge — no ~0.81×
	# shrink and no ~0.09·H float above the base (which the placement-parity anchor law exists to prevent).
	sm.set_shader_parameter("atlas_uv_lo", (float(StructCardKit.PAD) + 0.5) / float(StructCardKit.TILE))
	sm.set_shader_parameter("atlas_uv_span", (float(StructCardKit.TILE) - 2.0 * float(StructCardKit.PAD) - 1.0) / float(StructCardKit.TILE))
	if CubeSphere.FP_SHADE_UNIFIED:
		sm.set_shader_parameter("night_floor", VoxiLight.NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", VoxiLight.TERM_MU)
		sm.set_shader_parameter("moonshine", VoxiLight.MOONSHINE)
	return sm

## §5.1 the shared unit card mesh: 1 vertical billboard quad (side tile, UV2.x=0) + 1 roof cap quad (top tile,
## UV2.x=1) — 8 verts / 12 indices / 4 triangles. Local Y∈[0,1]; the quad extents are set per-instance in the shader.
static func _build_card_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	var h := 0.5
	# vertical billboard quad (X-Y plane): x∈{−0.5,+0.5}, y∈{0,1}; side atlas row (UV2.x = 0).
	_card_quad(verts, uvs, uv2s, idx, Vector3(-h, 0, 0), Vector3(h, 0, 0), Vector3(h, 1, 0), Vector3(-h, 1, 0), 0.0)
	# roof cap quad (X-Z plane at y=1): x,z∈{−0.5,+0.5}; top atlas row (UV2.x = 1). Wound +y-facing with the corner
	# order chosen so the flipped-v _card_quad UVs land +x̂→u / +ẑ→v on the top tile (min z ↔ UV.y=0 = tile top).
	_card_quad(verts, uvs, uv2s, idx, Vector3(-h, 1, h), Vector3(h, 1, h), Vector3(h, 1, -h), Vector3(-h, 1, -h), 1.0)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = uv2s
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

static func _card_quad(verts: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		idx: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, row: float) -> void:
	var base := verts.size()
	verts.push_back(a); verts.push_back(b); verts.push_back(c); verts.push_back(d)
	# UV: tile-local [0,1] with v flipped so local y=0 (the ground / near edge) samples tile-bottom (v=1) — the
	# atlas ground row (§4.2). For the cap (row 1) the same winding maps +x̂→u and +ẑ→v (v not physically flipped).
	uvs.push_back(Vector2(0, 1)); uvs.push_back(Vector2(1, 1)); uvs.push_back(Vector2(1, 0)); uvs.push_back(Vector2(0, 0))
	uv2s.push_back(Vector2(row, 0)); uv2s.push_back(Vector2(row, 0)); uv2s.push_back(Vector2(row, 0)); uv2s.push_back(Vector2(row, 0))
	idx.push_back(base + 0); idx.push_back(base + 1); idx.push_back(base + 2)
	idx.push_back(base + 0); idx.push_back(base + 2); idx.push_back(base + 3)

# =====================================================================================================================
# Construction — one MeshInstance3D child of the ring under FP_STRUCT_FAR (FacetFarRing.setup).
# =====================================================================================================================
func setup_instance(ring: Node3D, active_fid: int) -> void:
	_ring = ring
	_active_fid = active_fid
	_material = make_material()
	# FP_STRUCT_SHELL_BAND: build the zone-B UNLIT material only under the flag ⇒ off-flag this stays null and
	# material_override never changes (byte-identical). On-surface uses `_material`; zone B swaps to `_shell_material`.
	if CubeSphere.FP_STRUCT_SHELL_BAND:
		_shell_material = make_shell_material()
	_mesh = ArrayMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "FacetFarStructures"
	_mi.mesh = _mesh
	_mi.material_override = _material
	# Verts are placed in ring-local ABSOLUTE-planet coords the shader moves; a CPU AABB can't predict them, so pin a
	# huge custom AABB (the far-trees convention) so the node is never wrongly frustum-culled.
	_mi.custom_aabb = AABB(Vector3(-12000.0, -12000.0, -12000.0), Vector3(24000.0, 24000.0, 24000.0))
	ring.add_child(_mi)
	# FP_STRUCT_CARDS: the impostor-card sink — ONE MultiMeshInstance3D child of the SAME ring (§5.2). Built ONLY under
	# the flag ⇒ off-flag no node / no MultiMesh / no atlas / no shader compile (byte-identical, mirroring _shell_material).
	if CubeSphere.FP_STRUCT_CARDS:
		# §6 coupling: the card param precompute lives in _resnapshot, which only runs under FP_STRUCT_REG_EPOCH. Without
		# it, _card_prec stays empty ⇒ cards never appear (safe degrade, but not the intended arm). Warn once at setup.
		if not CubeSphere.FP_STRUCT_REG_EPOCH:
			push_warning("FacetFarStructures: FP_STRUCT_CARDS is ON without FP_STRUCT_REG_EPOCH — the card precompute runs in _resnapshot (REG_EPOCH-gated), so cards will not appear. Enable FP_STRUCT_REG_EPOCH in the same arm.")
		# S3 interlock (§9): the alt-band zone law needs the shell-band machinery + the epoch snapshot.
		if CubeSphere.FP_STRUCT_CARD_ALT_BAND and not (CubeSphere.FP_STRUCT_SHELL_BAND and CubeSphere.FP_STRUCT_REG_EPOCH):
			push_warning("FacetFarStructures: FP_STRUCT_CARD_ALT_BAND needs FP_STRUCT_CARDS+FP_STRUCT_SHELL_BAND+FP_STRUCT_REG_EPOCH — the extended card band has no effect otherwise.")
		# Codex P1f: the 2000-2400 fade + zone-O handoff is LOAD-BEARING on FP_STRUCT_LOD — without it, cards dissolve
		# into BARE TERRAIN above the band (no roof specks own the view). Warn so the deploy arm ships them together.
		if CubeSphere.FP_STRUCT_CARD_ALT_BAND and not CubeSphere.FP_STRUCT_LOD:
			push_warning("FacetFarStructures: FP_STRUCT_CARD_ALT_BAND without FP_STRUCT_LOD — cards fade into BARE TERRAIN above the band (no roof-skin specks). Ship FP_STRUCT_LOD in the same arm.")
		# S4 interlock (§9): staging lives inside the epoch prelude.
		if CubeSphere.FP_STRUCT_CARD_STAGE and not CubeSphere.FP_STRUCT_REG_EPOCH:
			push_warning("FacetFarStructures: FP_STRUCT_CARD_STAGE needs FP_STRUCT_REG_EPOCH — the staged snapshot + argsort live in the epoch prelude.")
		_card_material = make_card_material()
		_card_atlas = StructCardKit.build_atlas()
		_card_material.set_shader_parameter("house_atlas", _card_atlas)
		_card_mesh = _build_card_mesh()
		_card_mm = MultiMesh.new()
		_card_mm.transform_format = MultiMesh.TRANSFORM_3D
		_card_mm.use_colors = false                 # §1 COLOR-trap rule: no colour slot; the shader never reads COLOR
		_card_mm.use_custom_data = true             # BEFORE instance_count (the engine packs the layout then)
		_card_mm.mesh = _card_mesh
		_card_mm.instance_count = CubeSphere.STRUCT_CARD_INST_MAX
		_card_mm.visible_instance_count = 0
		_card_mmi = MultiMeshInstance3D.new()
		_card_mmi.name = "FacetFarStructCards"
		_card_mmi.multimesh = _card_mm
		_card_mmi.material_override = _card_material
		_card_mmi.custom_aabb = AABB(Vector3(-12000.0, -12000.0, -12000.0), Vector3(24000.0, 24000.0, 24000.0))
		ring.add_child(_card_mmi)

func set_active(new_fid: int) -> void:
	_active_fid = new_fid   # residency is camera-distance driven (rebuilt each step); crossing only re-seeds the centre

## FP_STRUCT_SHELL_BAND §3: the three-zone altitude visibility law (the far-trees `_apply_visibility` analogue). Off
## (or h<0 — the default keeps existing call sites on the shipped path) ⇒ the binary `_mi.visible = not offsurf`,
## byte-identical. ZONE S (on-surface): visible, radial voxi_shade `_material`. ZONE B (offsurf, h<HIDE): visible +
## LIVE under the UNLIT `_shell_material` (voxi_shade renders BLACK off-surface) with the tier_fade dissolve ramped
## over [FADE_ALT, HIDE_ALT]. ZONE O (h≥HIDE): hidden (the fine-map roof skin owns it). Returns the zone (0/1/2; -1 off).
func _apply_shell_visibility(offsurf: bool, h := -1.0) -> int:
	if not (CubeSphere.FP_STRUCT_SHELL_BAND and h >= 0.0):
		if _mi != null:
			_mi.visible = not offsurf
		if _card_mmi != null:                                      # FP_STRUCT_CARDS: mirror the binary suspend
			_card_mmi.visible = not offsurf
		_vis_abtest()
		return -1
	var zone := 0 if not offsurf else (1 if h < CubeSphere.FT_SHELL_HIDE_ALT else 2)
	if _mi != null:
		if zone == 0:
			_mi.visible = true
			_mi.material_override = _material                       # ZONE S: the radial voxi_shade material
		elif zone == 1:
			_mi.visible = true                                     # ZONE B: merged mesh stays live off-surface
			_mi.material_override = _shell_material                 # UNLIT vertex-colour ⇒ baked BROWN, not black
			if _shell_material != null:
				var tf := 1.0 - smoothstep(CubeSphere.FT_SHELL_FADE_ALT, CubeSphere.FT_SHELL_HIDE_ALT, h)
				_shell_material.set_shader_parameter("tier_fade", tf)
		else:
			_mi.visible = false                                    # ZONE O: hidden, skin owns the view
	# FP_STRUCT_CARDS (§8.4): the card tier stays LIVE + LIT off-surface on its OWN radial-shade material (no shell-
	# material swap — the card shader is not black off-surface); zone B ramps its tier_fade dissolve, zone O hides it.
	# FP_STRUCT_CARD_ALT_BAND (S3 §4): the CARD tier reclassifies INDEPENDENTLY of the cube zone — hide at STRUCT_CARD_
	# HIDE_ALT (2400 = STRUCT_FAR_MAX, where the set is empty by construction) with the dissolve re-anchored to
	# [STRUCT_CARD_FADE_ALT, STRUCT_CARD_HIDE_ALT]. Off ⇒ card_hide/card_fade_lo == the 600/520 cube thresholds ⇒
	# czone == zone and the shipped 600 fade verbatim (byte-identical).
	# #3 byte-off: the card-zone computation + telemetry live INSIDE the `_card_mmi != null` guard (the node exists only
	# under FP_STRUCT_CARDS) so a CARDS-off / ALT_BAND-off run does no new work here.
	if _card_mmi != null:
		var card_hide := CubeSphere.STRUCT_CARD_HIDE_ALT if CubeSphere.FP_STRUCT_CARD_ALT_BAND else CubeSphere.FT_SHELL_HIDE_ALT
		var card_fade_lo := CubeSphere.STRUCT_CARD_FADE_ALT if CubeSphere.FP_STRUCT_CARD_ALT_BAND else CubeSphere.FT_SHELL_FADE_ALT
		var czone := 0 if not offsurf else (1 if h < card_hide else 2)
		_card_zone = czone if CubeSphere.FP_STRUCT_CARD_ALT_BAND else -1
		if czone == 0:
			_card_mmi.visible = true
			# §8 fix b: zone S uses the wake fade too (an on-surface large swap / initial load must ramp, not pop).
			var f0 := _wake_fade()
			_dbg_card_fade = f0
			if _card_material != null:
				_card_material.set_shader_parameter("tier_fade", f0)
		elif czone == 1:
			_card_mmi.visible = true
			# S4 (§8): the wake fade-in multiplies the altitude term (1.0 unless a large set just swapped from empty).
			var ctf := (1.0 - smoothstep(card_fade_lo, card_hide, h)) * _wake_fade()
			_dbg_card_fade = ctf
			if _card_material != null:
				_card_material.set_shader_parameter("tier_fade", ctf)
		else:
			_card_mmi.visible = false
	_vis_abtest()
	return zone

## S4 (§8) the wake fade-in multiplier: 1.0 unless a staged swap just landed a large card set from an EMPTY state
## (`_wake_t0` latched atomically in _rebuild_staged, before the buffer publish), ramping 0→1 over STRUCT_WAKE_FADE_S.
## Only non-trivial under FP_STRUCT_CARD_STAGE (else `_wake_t0` stays 0 ⇒ 1.0). Driven from _apply_shell_visibility
## (every step, no rebuild) in BOTH zone S and zone B (§8 fix b).
func _wake_fade() -> float:
	if not CubeSphere.FP_STRUCT_CARD_STAGE or _wake_t0 == 0:
		return 1.0
	var t := float(Time.get_ticks_msec() - _wake_t0) / (CubeSphere.STRUCT_WAKE_FADE_S * 1000.0)
	return clampf(t, 0.0, 1.0)

## FP_STRUCT_VIS_ABTEST (Codex diagnostic): while the mesh WOULD be visible, blink it off for half of each period so a
## frozen observer can see whether the jerk follows the mesh's on-screen presence (⇒ render/GPU-bound) or persists while
## it's hidden (⇒ the registry/probe/bake path). Only suppresses an already-visible mesh; never forces one visible. Off ⇒
## no-op (byte-identical). Bake/registry/probe all keep running — this removes ONLY submission/rasterization.
func _vis_abtest() -> void:
	if not CubeSphere.FP_STRUCT_VIS_ABTEST or _mi == null or not _mi.visible:
		return
	_mi.visible = (int(Time.get_ticks_msec() / CubeSphere.STRUCT_VIS_ABTEST_PERIOD_MS) % 2) == 0

func set_sun_dir(sun_dir: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_dir", sun_dir)
	if _card_material != null:                     # FP_STRUCT_CARDS: the card tier shares the ONE Sun feed
		_card_material.set_shader_parameter("sun_dir", sun_dir)

func sun_dir_telemetry() -> Vector3:
	return (_material.get_shader_parameter("sun_dir") if _material != null else Vector3(1.0, 0.0, 0.0))

func set_registry_query(q: Callable) -> void: _registry_query = q
func set_sampler(q: Callable) -> void: _sampler = q
func set_near_query(q: Callable) -> void: _near_query = q
func set_edits_rev_query(q: Callable) -> void: _edits_rev_query = q
func set_version_query(q: Callable) -> void: _version_query = q   # FP_STRUCT_REG_EPOCH

## FP_STRUCT_REG_EPOCH: last step() prelude cost (µs). Present in all flag states (0 until step() runs) — a leaf int.
func step_us() -> int: return _dbg_step_us

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
	# FP_STRUCT_SHELL_BAND: the far-STRUCTURE three-zone altitude law (mirror of FP_FT_SHELL_BAND). h = camera radial
	# altitude from the SAME ring accessor the trees use (shell_cam_alt). shell_mode ⇒ off-surface but below the hide
	# line: the merged mesh stays VISIBLE + LIVE (fall through to the delta-gated rebuild so it stays correct across
	# crossings). Off (h defaults -1) ⇒ `_mi.visible = not offsurf` + off-surface early-return, byte-identical.
	var h := (_ring as FacetFarRing).shell_cam_alt() if CubeSphere.FP_STRUCT_SHELL_BAND else -1.0
	# FP_STRUCT_CARD_ALT_BAND (S3 §4): the freeze line moves to the card ceiling (2400) so the tier stays LIVE to the
	# distance envelope's edge; off ⇒ hide_alt == FT_SHELL_HIDE_ALT (600), the shipped freeze (byte-off — no fn call).
	var hide_alt := CubeSphere.FT_SHELL_HIDE_ALT
	if CubeSphere.FP_STRUCT_CARD_ALT_BAND:
		hide_alt = CubeSphere.STRUCT_CARD_HIDE_ALT
	var shell_mode := CubeSphere.FP_STRUCT_SHELL_BAND and offsurf and h < hide_alt
	_dbg_shell_zone = _apply_shell_visibility(offsurf, h)
	_dbg_shell_h = h
	_dbg_shell_offsurf = offsurf
	if offsurf and not shell_mode:
		return
	# FP_LOAD_DEFER settle gate + stream credit — no structure work during fresh-load pile-up (mirror of the trees).
	# FP_STRUCT_NEAR_GUARD §4.2 (#132): at credit 0 the same freeze leaves a far structure over its arrived near build
	# (double-render) and starves missing/dwell-restored structures. The guard relaxes ONLY the credit gate; the settle
	# gate, the STRUCT_STEP_MS rate cap and the delta gate below still bound the (cheap, per-rev-cached) rebuild, and its
	# _cull_emit pass fixes both sides. Off ⇒ the shipped `not credit_ok` return verbatim (byte-identical).
	if not _credit_gate_open(settled, credit_ok):
		return
	var now := Time.get_ticks_msec()
	# FP_STRUCT_BAKE_STAGE: while a staged drain is pending, step EVERY frame (the per-pass time box bounds the
	# cost); the merged-mesh COMMIT keeps the shipped STRUCT_STEP_MS cadence via _last_commit_ms in _rebuild.
	var draining := (CubeSphere.FP_STRUCT_BAKE_STAGE and _bake_pending) \
		or (CubeSphere.FP_STRUCT_CARD_STAGE and _snap_pending)   # S4: staged snapshot drains every frame while filling
	# FP_STRUCT_CARD_ALT_BAND (S3 §4): in the extended band (h ≥ 600) the view changes slowly — halve the prelude
	# cadence to STRUCT_SHELL_STEP_MS. Off / below 600 ⇒ STRUCT_STEP_MS (byte-identical). Drain frames bypass either.
	var cap_ms := CubeSphere.STRUCT_STEP_MS
	if CubeSphere.FP_STRUCT_CARD_ALT_BAND and h >= CubeSphere.FT_SHELL_HIDE_ALT:
		cap_ms = CubeSphere.STRUCT_SHELL_STEP_MS
	if not draining and now - _last_step_ms < cap_ms:
		return
	_last_step_ms = now
	# FP_STRUCT_REG_EPOCH: self-time the WHOLE prelude (registry materialize + probe pass + delta gate) — present in
	# ALL flag states so the un-gated spike is never invisible again (a usec read + one int write; no allocation).
	var _step_t0 := Time.get_ticks_usec()
	var centre := (_ring as FacetFarRing).render_centre()
	if _material != null:
		_material.set_shader_parameter("planet_centre", centre)
	if _card_material != null:                     # FP_STRUCT_CARDS: the card shader's radial normal uniform (§8.1)
		_card_material.set_shader_parameter("planet_centre", centre)
	var cam_abs := _cam_to_absolute(cam_render)
	if CubeSphere.FP_STRUCT_REG_EPOCH:
		# Version-gated prelude (far-trees parity, facet_far_trees.gd:802): O(1) when the registry version, camera and
		# handoff annulus are all quiescent; otherwise the probe pass over the CACHED snapshot with PRECOMPUTED centres.
		var need := _prelude_epoch(cam_abs, draining)
		_dbg_step_us = int(Time.get_ticks_usec() - _step_t0)
		if need:
			_rebuild(_snapshot, cam_abs, true)   # reg IS the snapshot ⇒ S2 precomputed-distance argsort off _centres
		return
	# --- shipped prelude (byte-identical off — verbatim lines, only the surrounding timer added) --------------------
	var reg: Array = _registry_query.call() if _registry_query.is_valid() else []
	# Pure probe pass (§7.3): fill _probe_cache + the change fingerprint + whether any cull is mid-transition. No streak
	# mutation here (streaks advance only in the real rebuild) so the HIDE/SHOW dwell counts 'consecutive rebuilds'.
	var rev_sum := 0
	for rec in reg:
		rev_sum += int(rec["rev"])
	var cover_fp := _probe_pass(reg, cam_abs)
	# Delta gate (the forest-fps law): rebuild only when an input drifted OR a cull transition is pending.
	var need_ship := _inputs_changed(cam_abs, reg.size(), rev_sum, cover_fp)
	_dbg_step_us = int(Time.get_ticks_usec() - _step_t0)
	if not need_ship:
		return
	_rebuild(reg, cam_abs)

func _cam_to_absolute(cam_render: Vector3) -> Vector3:
	if _ring == null:
		return cam_render
	return (_ring as Node3D).global_transform.affine_inverse() * cam_render

## FP_STRUCT_REG_EPOCH: the O(1)-gated prelude (only called under the flag ⇒ shipped prelude byte-identical off).
## Reads the registry version O(1); RE-MATERIALIZES the cached snapshot (+ precomputed world centres and rev-sum)
## only when the version drifted (or the version query is unwired — the safe always-refresh degrade). A same-version,
## camera-parked, no-cull-pending step whose LAST probe found an empty handoff annulus short-circuits in O(1) (no
## registry duplicate, no probe loop) — the parked-over-village fix. Otherwise it runs the probe pass over the CACHED
## snapshot with the PRECOMPUTED centres and returns the delta-gate verdict (whether _rebuild must run this step).
## NEVER-DROP: the version bumps on every registry mutation, so a real change forces a resnapshot + rebuild the same
## step; the O(1) skip is fenced by version == last, camera < STRUCT_EPOCH_STILL from the last full scan, cull not
## pending, and annulus empty — every avenue by which the committed set could change is covered.
func _prelude_epoch(cam_abs: Vector3, draining: bool) -> bool:
	var has_ver := _version_query.is_valid()
	var ver := int(_version_query.call()) if has_ver else -1
	# FP_STRUCT_CARD_STAGE (S4 §6): the staged double-buffered snapshot lives here (the epoch prelude). Off ⇒ the shipped
	# one-shot _resnapshot + O(1) skip below run verbatim (byte-identical).
	if CubeSphere.FP_STRUCT_CARD_STAGE:
		return _prelude_epoch_staged(cam_abs, ver, has_ver, draining)
	if not has_ver or ver != _last_version:
		_resnapshot(ver)                                   # a real change (or unknown version) ⇒ re-materialize
	elif not draining and not _cull_pending and _annulus_empty_last \
			and cam_abs.distance_to(_last_scan_cam) < STRUCT_EPOCH_STILL:
		return false                                       # version + camera + annulus quiescent ⇒ O(1) skip
	var cover_fp := _probe_pass(_snapshot, cam_abs, _centres)
	_last_scan_cam = cam_abs
	return _inputs_changed(cam_abs, _snapshot.size(), _snap_rev_sum, cover_fp)

## FP_STRUCT_CARD_STAGE (S4 §6): the staged epoch prelude. A version drift STARTS/RESTARTS a fill into the `_next`
## double-buffers WITHOUT touching the live snapshot (which keeps rendering, resident — §5). Each step while pending
## drains ≥ STRUCT_SNAP_STAGE_MIN records under a STRUCT_SNAP_STAGE_MS box; on convergence the buffers SWAP and one
## rebuild fires. While pending (pre-swap) the prelude returns false (no rebuild off a half-filled snapshot). When not
## pending it is the shipped O(1) skip + delta gate over the live snapshot — the stationary property is untouched.
func _prelude_epoch_staged(cam_abs: Vector3, ver: int, has_ver: bool, draining: bool) -> bool:
	var now := Time.get_ticks_msec()
	# §2 COALESCING: a fill in progress is FINISHED, never restarted mid-flight — a version that drifts during a fill is
	# caught up by the NEXT fill (after this swap), so under sustained drift the swap ALWAYS lands (no starvation) and
	# records() materialize happens ONCE PER FILL (not every frame — the old restart bug). The version query returns the
	# LATEST each step, so the catch-up picks up the newest.
	if _snap_pending:
		if _snap_drain():                                  # converged + swapped ⇒ probe + rebuild the NEW set
			# a version STILL ahead of what we just filled ⇒ it drifted DURING the fill (sustained drift, e.g. a fast
			# descent through crossings) ⇒ the NEXT fill is a rate-limited CATCH-UP. Otherwise the source is stable.
			_snap_catch_up = has_ver and ver != _last_version
			var cfp := _probe_pass(_snapshot, cam_abs, _centres)
			_last_scan_cam = cam_abs
			_inputs_changed(cam_abs, _snapshot.size(), _snap_rev_sum, cfp)   # latch; a swap always rebuilds
			return true
		return false                                       # still filling — the resident old snapshot renders (§5)
	# Not pending. Start a fill when the version drifted. A CATCH-UP fill (sustained drift) is rate-limited so records()
	# materialize can't fire faster than STRUCT_STEP_MS (§2); a FRESH fill (stable→drift, e.g. a player edit) or the
	# first-ever fill (empty) is NEVER delayed — the REG_EPOCH never-drop contract. `_dbg_snap_restarts` counts catch-ups.
	if not has_ver or ver != _last_version:
		if _snap_catch_up and not _snapshot.is_empty() and now - _last_mat_ms < CubeSphere.STRUCT_STEP_MS:
			return false                                   # rate-limit sustained-drift churn — render the resident set, retry next step
		if not _snapshot.is_empty():
			_dbg_snap_restarts += 1
		_snap_start_fill(ver)
		if _snap_drain():
			_snap_catch_up = has_ver and ver != _last_version
			var cfp2 := _probe_pass(_snapshot, cam_abs, _centres)
			_last_scan_cam = cam_abs
			_inputs_changed(cam_abs, _snapshot.size(), _snap_rev_sum, cfp2)
			return true
		return false
	# Version quiescent: the shipped O(1) stationary skip + delta gate over the live snapshot.
	_snap_catch_up = false
	if not draining and not _cull_pending and _annulus_empty_last \
			and cam_abs.distance_to(_last_scan_cam) < STRUCT_EPOCH_STILL:
		return false
	var cover_fp := _probe_pass(_snapshot, cam_abs, _centres)
	_last_scan_cam = cam_abs
	return _inputs_changed(cam_abs, _snapshot.size(), _snap_rev_sum, cover_fp)

## S4: begin (or restart) a staged fill at `ver`. Materializes the registry ONE-SHOT (§6.2, timed = st_mat_us) into
## `_snap_next`, sizes the next centres, clears the next prec, resets the drain cursor. Does NOT touch the live buffers.
func _snap_start_fill(ver: int) -> void:
	_last_mat_ms = Time.get_ticks_msec()                   # §2 rate-limit anchor (records() materialize cadence)
	var _mt0 := Time.get_ticks_usec()
	_snap_next = _registry_query.call() if _registry_query.is_valid() else []
	_dbg_mat_us = int(Time.get_ticks_usec() - _mt0)
	_centres_next = PackedVector3Array()
	_centres_next.resize(_snap_next.size())
	_card_prec_next = {}
	_snap_next_rev_sum = 0
	_snap_fill = 0
	_snap_fill_ver = ver
	_snap_ctx = {}
	_snap_pending = true

## S4: drain the per-record precompute (centre + card params) from `_snap_fill` forward — ≥ STRUCT_SNAP_STAGE_MIN
## records, then stop past STRUCT_SNAP_STAGE_MS. Returns true iff the fill reached the end and swapped this pass.
func _snap_drain() -> bool:
	var _pt0 := Time.get_ticks_usec()
	var done := 0
	var n := _snap_next.size()
	while _snap_fill < n:
		var rec: Dictionary = _snap_next[_snap_fill]
		_snap_next_rev_sum += int(rec["rev"])
		_centres_next[_snap_fill] = _structure_centre(rec)
		if CubeSphere.FP_STRUCT_CARDS:
			_card_prec_next[int(rec["root"])] = _precompute_card(rec, _snap_ctx)
		_snap_fill += 1
		done += 1
		if done >= CubeSphere.STRUCT_SNAP_STAGE_MIN \
				and float(Time.get_ticks_usec() - _pt0) * 0.001 >= CubeSphere.STRUCT_SNAP_STAGE_MS:
			break
	_dbg_prec_us = int(Time.get_ticks_usec() - _pt0)
	if _snap_fill >= n:
		_swap_snapshot()
		return true
	return false

## S4: swap the filled `_next` buffers into the live slots. Records the pre-swap live count (for the §8 wake jump) and
## arms the wake check for the immediately-following rebuild. Releases the next buffers so the live ones own the data.
func _swap_snapshot() -> void:
	_prev_live_cards = _live_cards
	_snapshot = _snap_next
	_centres = _centres_next
	if CubeSphere.FP_STRUCT_CARDS:
		_card_prec = _card_prec_next
	_snap_rev_sum = _snap_next_rev_sum
	_last_version = _snap_fill_ver
	_snap_pending = false
	_snap_fill = -1
	# arm the wake check only when there IS a card sink to fade (else _rebuild_staged's cube-only path never clears it).
	_pending_wake_check = CubeSphere.FP_STRUCT_CARDS
	_snap_next = []
	_centres_next = PackedVector3Array()
	_card_prec_next = {}

## FP_STRUCT_REG_EPOCH: materialize the registry snapshot for `ver` — the ONE per-version registry duplicate plus the
## per-record precompute (world centre + rev-sum) the stationary steps reuse. Called only when the version drifted, so
## the O(N) registry-duplicate + lattice_to_world64 cost is paid once per real change, not every ~250 ms step.
func _resnapshot(ver: int) -> void:
	_snapshot = _registry_query.call() if _registry_query.is_valid() else []
	_snap_rev_sum = 0
	_centres = PackedVector3Array()
	_centres.resize(_snapshot.size())
	# FP_STRUCT_CARDS (§6): the per-record card-param precompute lives HERE, index-parallel-in-spirit with _centres but
	# keyed by root (sort-safe). Rebuilt whole each version ⇒ no stale row can outlive its snapshot (risk 7). Off ⇒ the
	# clear/fill lines are skipped ⇒ the loop body is the shipped two lines (byte-identical).
	var ctx_cache: Dictionary = {}                 # FP_STRUCT_CARDS: ONE GenCtx per fid so the GATE_MEMO village memo hits across a village's houses
	if CubeSphere.FP_STRUCT_CARDS:
		_card_prec.clear()
	for i in range(_snapshot.size()):
		var rec: Dictionary = _snapshot[i]
		_snap_rev_sum += int(rec["rev"])
		_centres[i] = _structure_centre(rec)
		if CubeSphere.FP_STRUCT_CARDS:
			_card_prec[int(rec["root"])] = _precompute_card(rec, ctx_cache)
	_last_version = ver

## FP_STRUCT_CARDS (§6): the 12-float card param row for one record — [is_card, arch, w_s, w_f, H, ox,oy,oz, fx,fy,fz,
## spare]. is_card = 0 for any player-built (root ≥ 0) or non-GEN (source) record (they have no house_info and unique
## geometry — the cube path owns them at every distance, the load-bearing §6.1 guard). For a GEN record: recover
## (fid, hx, hz) by inverting pack_root, re-derive the house descriptor, canonicalize the archetype, resolve the
## door→forward/side axes + pre-swapped extents (§3.3), and the sphere-lifted base-centre origin + height (§5.3, the
## SAME lattice→world(+datum_lift) law as _ensure_bake so the cube→card swap never pops — risk 4). Only called under
## the flag (from _resnapshot). Cost: O(1) hashes + one lattice_to_world64 per record, once per registry version.
func _precompute_card(rec: Dictionary, ctx_cache: Dictionary = {}) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(STRUCT_CARD_PREC)
	var root := int(rec["root"])
	var source := int(rec.get("source", -1))
	if root >= 0 or source != StructureGen.SOURCE_GEN:
		out[0] = 0.0                                # player-built / non-GEN ⇒ never a card (cube path owns it)
		return out
	# A DAMAGED GEN house (rev bumped by an edit) must stay on the CUBE path so the hole shows — a pristine card would
	# hide the damage. Route rev != 0 through the cube sink (is_card 0). The version bump on note_edit re-runs this.
	if int(rec.get("rev", 0)) != 0:
		out[0] = 0.0
		return out
	var up := StructureGen.unpack_root(root)
	var fid := int(up[0]); var hx := int(up[1]); var hz := int(up[2])
	var ctx = ctx_cache.get(fid)
	if ctx == null:
		ctx = TerrainConfig.GenCtx.new(0, fid)
		ctx_cache[fid] = ctx
	var hi := StructureGen.house_info(hx, hz, ctx)
	if hi.is_empty():
		out[0] = 0.0                                # defensive: a record StructGenIndex emitted always has a house_info
		return out
	var arch := StructCardKit.arch_index(int(hi["roof"]), int(hi["wall_h"]), int(hi["gable_h"]))
	# §3.3 door → per-instance forward (e_f) / side extents. e_f from the owner facet's lattice basis (FP_FT_FRAME_WELD
	# lesson): the axes the near voxel house is aligned to, NEVER a world-axis tangent (risk 3).
	var fb := FacetAtlas.frame_basis(fid)
	var eu := fb.x                                  # ê_u (lattice x)
	var ew := fb.z                                  # ê_w (lattice z)
	var wdim := float(hi["w"]); var ddim := float(hi["d"])
	var e_f := -eu; var w_f := wdim; var w_s := ddim
	match int(hi["door"]):
		0: e_f = -eu; w_f = wdim; w_s = ddim        # door on −x
		1: e_f = eu;  w_f = wdim; w_s = ddim        # +x
		2: e_f = -ew; w_f = ddim; w_s = wdim        # −z
		3: e_f = ew;  w_f = ddim; w_s = wdim        # +z
	var bmin: Vector3i = rec["bmin"]
	var bmax: Vector3i = rec["bmax"]
	var cx := (float(bmin.x) + float(bmax.x) + 1.0) * 0.5
	var cz := (float(bmin.z) + float(bmax.z) + 1.0) * 0.5
	var by := float(bmin.y)                          # the BASE course (bottom) — the card quad rises from here to +H
	if CubeSphere.FP_FT_FRAME_WELD:
		by += FacetAtlas.datum_lift(fid, cx, cz)
	var w := FacetAtlas.lattice_to_world64(fid, cx, by, cz)
	var H := float(bmax.y - bmin.y + 1)
	out[0] = 1.0
	out[1] = float(arch)
	out[2] = w_s
	out[3] = w_f
	out[4] = H
	out[5] = float(w[0]); out[6] = float(w[1]); out[7] = float(w[2])
	out[8] = e_f.x; out[9] = e_f.y; out[10] = e_f.z
	out[11] = 0.0
	return out

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
	# FP_STRUCT_WALK_CALM (Lever 1): replace the raw 2-blk camera re-arm with a membership band-fingerprint. The camera
	# term survives only when the tri cap was hit last rebuild (_capped) — then nearest-first ORDERING is a genuine camera
	# term. Off ⇒ `(not false or _capped)` == true ⇒ the shipped `dist >= STRUCT_DELTA_MOVE` disjunct verbatim, and the
	# band-fp disjunct short-circuits on the const ⇒ byte-identical.
	# The camera term survives under WALK_CALM only when a nearest-first cap was hit last rebuild — the CUBE tri cap
	# (_capped) OR the CARD instance cap (_card_capped) — because then walking admits newly-closer records without any
	# band-edge crossing. Off-flag both are false and `not WALK_CALM` short-circuits ⇒ byte-identical.
	var changed := (not _have_rebuilt) \
		or (cam_abs.distance_to(_last_cam) >= STRUCT_DELTA_MOVE \
			and (not CubeSphere.FP_STRUCT_WALK_CALM or _capped or _card_capped)) \
		or (CubeSphere.FP_STRUCT_WALK_CALM and _band_fp != _last_band_fp) \
		or reg_count != _last_reg_count \
		or rev_sum != _last_rev_sum \
		or _current_edits_rev() != _last_edits_rev \
		or cover_fp != _last_cover_fp \
		or _cull_pending \
		or (CubeSphere.FP_STRUCT_BAKE_STAGE and _bake_pending)
	if changed:
		_have_rebuilt = true
		_last_cam = cam_abs
		_last_reg_count = reg_count
		_last_rev_sum = rev_sum
		_last_edits_rev = _current_edits_rev()
		_last_cover_fp = cover_fp
		_last_band_fp = _band_fp
	return changed

# --- near-handoff cull (§7.3) ---------------------------------------------------------------------------------------
var _cull_pending := false

## Pure pass: probe every in-annulus structure, cache the tri-state, XOR a stable hash over COVERED ones (the change
## fingerprint so a mesh landing under a still camera re-arms), and set `_cull_pending` if any probe disagrees with the
## committed visibility (so the streak can advance). NEVER mutates streaks. Returns the fingerprint.
func _probe_pass(reg: Array, cam_abs: Vector3, centres := PackedVector3Array()) -> int:
	_probe_cache.clear()
	_cull_pending = false
	_annulus_empty_last = true                    # FP_STRUCT_REG_EPOCH: set false below iff a structure is annulus-probed
	if not _near_query.is_valid():
		return 0
	var r0 := float(TerrainConfig.near_render_radius())
	var fp := 0
	var probes := 0
	# FP_STRUCT_REG_EPOCH: use the caller's PRECOMPUTED world centres (from _resnapshot) when they match, so this loop
	# does NOT re-run _structure_centre → lattice_to_world64 (a fresh 3-Variant Array) per record. Empty/mismatched
	# centres (every direct-call gate + the shipped step()) ⇒ per-record compute, byte-identical to before.
	var use_centres := centres.size() == reg.size()
	# FP_STRUCT_WALK_CALM (Lever 1): recompute the membership band-fingerprint over EVERY registered structure, folded
	# free into this existing distance loop. Only under the flag (byte-identical off — _band_fp stays 0, never read).
	if CubeSphere.FP_STRUCT_WALK_CALM:
		_band_fp = 0
	for i in range(reg.size()):
		var rec: Dictionary = reg[i]
		var fid: int = int(rec["fid"])
		var dist := (cam_abs.distance_to(centres[i]) if use_centres else _structure_dist(rec, cam_abs))
		if CubeSphere.FP_STRUCT_WALK_CALM:
			var root_b := int(rec["root"])
			var code := _band_code(dist, r0, int(_band.get(root_b, -1)))
			_band[root_b] = code
			_band_fp ^= _band_mix(_root_hash(root_b), code)
		# FP_STRUCT_NEAR_HOLD: the band floor is no longer probe-free — inside r0 the far model holds until
		# the near build actually covers it, so it MUST be probed (capped; past the cap ⇒ no cache entry ⇒
		# UNKNOWABLE ⇒ hold — the safe direction). Off ⇒ the shipped skip verbatim.
		var below_floor := dist < r0 and (not CubeSphere.FP_STRUCT_NEAR_HOLD or probes >= CubeSphere.STRUCT_HOLD_PROBE_CAP)
		if below_floor or dist > r0 + CULL_ANNULUS:
			continue                                   # band floor / beyond near reach — no probe
		var st := int(_near_query.call(fid, _footprint(rec)))
		probes += 1
		_probe_cache[int(rec["root"])] = st
		var hidden: bool = _cull.has(int(rec["root"])) and bool(_cull[int(rec["root"])]["hidden"])
		if st == NearPresence.COVERED:
			fp ^= _root_hash(int(rec["root"]))
			if not hidden:
				_cull_pending = true                   # will hide after the streak
		elif st == NearPresence.NOT_COVERED:
			if hidden:
				_cull_pending = true                   # will restore after the streak
	# FP_STRUCT_REG_EPOCH: an empty handoff annulus (no structure in [r0, r0+CULL_ANNULUS]) means no near-arrival cull
	# can fire while the camera is parked ⇒ a same-version stationary step is safe to skip in O(1). Off-flag: unread.
	_annulus_empty_last = probes == 0
	return fp

## Advance the cull streak for `rec` from its cached probe and return whether the far model is currently EMITTED.
## COVERED → hide after STRUCT_HIDE_STREAK; NOT_COVERED → restore after STRUCT_SHOW_STREAK; UNKNOWABLE → no change.
func _cull_emit(rec: Dictionary, cam_abs: Vector3, pre_dist := NAN) -> bool:
	var root := int(rec["root"])
	# S2 (FP_STRUCT_CARD_STAGE §7): reuse the caller's precomputed distance. The `is_nan` guard is behind the flag const
	# so the SHIPPED call site (`_cull_emit(rec, cam)`, pre_dist=NAN) short-circuits to the verbatim `_structure_dist`
	# self-compute — byte-off execution (no is_nan per record off-flag). Only _rebuild_staged passes a real pre_dist.
	var dist := pre_dist if (CubeSphere.FP_STRUCT_CARD_STAGE and not is_nan(pre_dist)) else _structure_dist(rec, cam_abs)
	var r0 := float(TerrainConfig.near_render_radius())
	if dist < r0:
		# FP_STRUCT_NEAR_HOLD (live defect: houses vanish during descent): the shipped floor drops the far
		# model on DISTANCE ALONE while the near build still lags the descent — a renderer-less house. Inside
		# r0, hide ONLY on an actual COVERED probe (positive = fact ⇒ streak 1, the far-trees law,
		# facet_far_trees.gd:546); NOT_COVERED while hidden restores after STRUCT_SHOW_STREAK (near unloaded ⇒
		# far returns); UNKNOWABLE never flips (shared invariant). Off ⇒ the shipped `return false` verbatim.
		if not CubeSphere.FP_STRUCT_NEAR_HOLD:
			return false
		var st0 := int(_probe_cache.get(root, NearPresence.UNKNOWABLE))
		var cs0: Dictionary = _cull.get(root, {"hidden": false, "cover": 0, "uncover": 0})
		if st0 == NearPresence.COVERED:
			cs0["hidden"] = true
			cs0["cover"] = 0; cs0["uncover"] = 0
		elif st0 == NearPresence.NOT_COVERED and bool(cs0["hidden"]):
			cs0["uncover"] = int(cs0["uncover"]) + 1
			if int(cs0["uncover"]) >= CubeSphere.STRUCT_SHOW_STREAK:
				cs0["hidden"] = false
				cs0["uncover"] = 0
		_cull[root] = cs0
		return not bool(cs0["hidden"])                 # HOLD: emitted until the near build actually covers it
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

## FP_STRUCT_WALK_CALM: mix a per-structure root hash with its band code into a stable, code-sensitive term. XOR-folded
## over all records ⇒ order-independent (nearest-first ordering is irrelevant) and the fold changes iff SOME structure's
## band code changed. Only called under the flag.
static func _band_mix(rh: int, code: int) -> int:
	var n := (rh ^ ((code + 1) * 2246822519)) & 0x7FFFFFFF
	n = ((n ^ (n >> 15)) * 2654435761) & 0x7FFFFFFF
	return n ^ (n >> 13)

## FP_STRUCT_WALK_CALM: classify a structure's camera distance into a band code (0=FLOOR dist<r0, 1=ANNULUS
## [r0, r0+CULL_ANNULUS], 2=BAND (annulus, STRUCT_FAR_MAX], 3=OUT). Under FP_STRUCT_HANDOFF_HYST (Lever 2c) the edges
## carry a state-keyed Schmitt dead-band (width STRUCT_HYST_W): a structure keeps `prev` unless the camera crosses the
## relevant edge by ±STRUCT_HYST_W, so a razor-edge camera can't oscillate the code (and thus the fingerprint). Only
## called under FP_STRUCT_WALK_CALM.
func _band_code(dist: float, r0: float, prev: int) -> int:
	var a := r0                                # FLOOR|ANNULUS edge
	var b := r0 + CULL_ANNULUS                 # ANNULUS|BAND edge
	var c := CubeSphere.STRUCT_FAR_MAX         # BAND|OUT edge
	# FP_STRUCT_CARDS (§7.3): split the BAND zone (code 2) at STRUCT_CARD_MIN into a CUBE sub-band (code 2, [b, e)) and
	# a CARD sub-band (code 4, [e, c]) so the fingerprint re-arms exactly once when a house crosses the cube↔card edge,
	# with the same Schmitt dead-band on the new edge. Off ⇒ `cards` false ⇒ codes 0..3 (byte-identical) — prev never 4.
	var cards := CubeSphere.FP_STRUCT_CARDS
	var e := CubeSphere.STRUCT_CARD_MIN        # CUBE|CARD split edge (only consulted under FP_STRUCT_CARDS)
	if CubeSphere.FP_STRUCT_HANDOFF_HYST:
		var w := CubeSphere.STRUCT_HYST_W
		# Bias each edge by ±w in the direction that keeps `prev` (Schmitt): a code below an edge only advances past
		# edge+w, a code at/above only retreats past edge−w. `prev == -1` (unseen) uses the raw edges.
		if prev == 0:   a += w
		elif prev == 1: a -= w; b += w
		elif prev == 2:
			b -= w
			if cards: e += w                   # cube sub-band sticks below the split
			else:     c += w
		elif prev == 4: e -= w; c += w         # card sub-band sticks above the split (only reachable under cards)
		elif prev == 3: c -= w
	if dist < a:
		return 0
	if dist <= b:
		return 1
	if cards:
		if dist < e:
			return 2                           # cube sub-band [b, e)
		if dist <= c:
			return 4                           # card sub-band [e, c]
		return 3
	if dist <= c:
		return 2
	return 3

# --- merged-band rebuild --------------------------------------------------------------------------------------------

## Rebuild the ONE merged LOD-A ArrayMesh: for each registered structure in the band [near_render_radius, STRUCT_FAR_MAX]
## that the near-handoff cull leaves visible, ensure its cached bake (re-baked on rev change) and append its ring-local
## verts/colours, nearest-first, under the STRUCT_FAR_TRIS_MAX cap. One surface swap.
func _rebuild(reg: Array, cam_abs: Vector3, use_centres := false) -> void:
	_dbg_rebuild_count += 1
	_evict_stale_bakes(reg)
	# S2/S4 (FP_STRUCT_CARD_STAGE §6-§7): the precomputed-distance argsort + wake path is EXCLUSIVELY in _rebuild_staged
	# (the timer, the distance buffer, the indexed argsort/reuse loop, the NAN-reuse cull calls, the staged telemetry,
	# the wake latch). Off ⇒ the shipped body below runs VERBATIM (pre-Stage-3) — NO new execution or allocation, so the
	# flag-off arm is a clean perf control (Codex P1e). Do not fold the two paths back together.
	if CubeSphere.FP_STRUCT_CARD_STAGE:
		_rebuild_staged(reg, cam_abs, use_centres)
		return
	# --- shipped path (pre-Stage-3, verbatim) -------------------------------------------------------------------------
	# nearest-first so the tri cap keeps the closest (most visible) structures
	var ordered := reg.duplicate()
	ordered.sort_custom(func(a, b): return _structure_dist(a, cam_abs) < _structure_dist(b, cam_abs))
	# FP_STRUCT_BAKE_STAGE: drain fresh bakes under the budget FIRST; on a bake-only frame (pending drain,
	# commit cadence not due) stop here — the resident merged mesh keeps drawing untouched (never a removal).
	if CubeSphere.FP_STRUCT_BAKE_STAGE:
		_drain_bakes(ordered, cam_abs)
		if _bake_pending and Time.get_ticks_msec() - _last_commit_ms < CubeSphere.STRUCT_STEP_MS:
			return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var tris := 0
	var count := 0
	var capped := false
	# FP_STRUCT_CARDS: the card sink. Reuses the PERSISTENT _card_cbuf (resized once) — no per-rebuild 128 KB alloc
	# (WASM dlmalloc convoy hygiene). A GEN house renders in EXACTLY ONE sink — cube OR card. Off ⇒ _card_cbuf is never
	# touched, the branches are skipped, and the cube accumulators / _ensure_bake / _commit_mesh run verbatim (byte-off).
	var cn := 0
	var ccapped := false
	var card_write_us := 0                              # accumulated card-sink write time (µs) — the whole write loop, not just the upload
	if CubeSphere.FP_STRUCT_CARDS:
		var need := CubeSphere.STRUCT_CARD_INST_MAX * STRUCT_CARD_STRIDE
		if _card_cbuf.size() != need:
			_card_cbuf.resize(need)
	for rec in ordered:
		var dist := _structure_dist(rec, cam_abs)
		if dist > CubeSphere.STRUCT_FAR_MAX:
			continue
		if not _cull_emit(rec, cam_abs):
			continue
		if CubeSphere.FP_STRUCT_CARDS and _card_eligible(rec, dist):
			if cn >= CubeSphere.STRUCT_CARD_INST_MAX:
				ccapped = true
				continue                                       # nearest-first: the cap keeps the closest houses
			var _wt0 := Time.get_ticks_usec()
			_write_card_inst(_card_cbuf, cn, _card_prec[int(rec["root"])])
			card_write_us += int(Time.get_ticks_usec() - _wt0)
			cn += 1
			count += 1
			continue                                           # a house renders in EXACTLY one sink
		# FP_STRUCT_CARDS: once the CUBE tri budget caps, keep scanning for later CARD-eligible records (cards do NOT
		# share the tri cap) instead of the shipped `break` — else a dense near cube area hides every farther GEN card.
		if CubeSphere.FP_STRUCT_CARDS and capped:
			continue
		if CubeSphere.FP_STRUCT_BAKE_STAGE and not _has_bake(rec):
			continue        # staged: never-yet-shown house — its addition waits for the drain (removals never wait)
		var bake := _ensure_bake(rec)
		if bake.is_empty() or int(bake["tris"]) == 0:
			continue
		if tris + int(bake["tris"]) > CubeSphere.struct_far_tris_max():   # FP_STRUCT_COARSE_FAR: 24k under the flag, else 80k
			capped = true
			if CubeSphere.FP_STRUCT_CARDS:
				continue                                       # cards on: keep scanning for card records past the cube cap
			break                                              # cards off: shipped behaviour (byte-identical)
		verts.append_array(bake["verts"])
		colors.append_array(bake["colors"])
		tris += int(bake["tris"])
		count += 1
	_commit_mesh(verts, colors)
	if CubeSphere.FP_STRUCT_CARDS and _card_mm != null:
		var _cu0 := Time.get_ticks_usec()
		_card_mm.set_buffer(_card_cbuf)                       # whole-buffer upload (the tree law — never set_instance_transform)
		_card_mm.visible_instance_count = cn
		_dbg_card_us = card_write_us + int(Time.get_ticks_usec() - _cu0)   # write loop + upload (st_crb_us)
		_live_cards = cn
		_card_capped = ccapped
	if CubeSphere.FP_STRUCT_BAKE_STAGE:
		_last_commit_ms = Time.get_ticks_msec()
	_live_structures = count
	_live_tris = tris
	_capped = capped
	if capped:
		print("  FacetFarStructures: STRUCT_FAR_TRIS_MAX (", CubeSphere.STRUCT_FAR_TRIS_MAX, ") hit (nearest-first) — coarsen or evict")

## S2/S4: the FP_STRUCT_CARD_STAGE _rebuild — a tie-stable precomputed-distance argsort off _centres (S2 §7, the sort
## bomb fix) + the wake fade-in latch ATOMIC with the buffer publish (S4 §8). Reached ONLY from _rebuild under the flag,
## so every construct here is flag-on-only (the flag-off arm never allocates the distance buffer or reads the clock).
func _rebuild_staged(reg: Array, cam_abs: Vector3, use_centres: bool) -> void:
	var _sort_t0 := Time.get_ticks_usec()
	var staged_sort := use_centres and reg.size() == _centres.size() and reg.size() > 0
	var ordered: Array
	var ordered_dist := PackedFloat32Array()
	if staged_sort:
		var n0 := reg.size()
		var order := []; order.resize(n0)                             # plain Array (PackedInt32Array has no sort_custom)
		var dcache := PackedFloat32Array(); dcache.resize(n0)
		for i in range(n0):
			dcache[i] = cam_abs.distance_to(_centres[i])
			order[i] = i
		# §5 tie-stable: equal distances break on ROOT, so the argsort is deterministic (and equals a keyed one-shot).
		order.sort_custom(func(a, b): return (dcache[a] < dcache[b]) if dcache[a] != dcache[b] else (int((reg[a] as Dictionary)["root"]) < int((reg[b] as Dictionary)["root"])))
		ordered = []; ordered.resize(n0)
		ordered_dist.resize(n0)
		for k in range(n0):
			ordered[k] = reg[order[k]]
			ordered_dist[k] = dcache[order[k]]
	else:
		ordered = reg.duplicate()
		ordered.sort_custom(func(a, b): return _structure_dist(a, cam_abs) < _structure_dist(b, cam_abs))
	_dbg_sort_us = int(Time.get_ticks_usec() - _sort_t0)
	if CubeSphere.FP_STRUCT_BAKE_STAGE:
		_drain_bakes(ordered, cam_abs)
		if _bake_pending and Time.get_ticks_msec() - _last_commit_ms < CubeSphere.STRUCT_STEP_MS:
			return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var tris := 0
	var count := 0
	var capped := false
	var cn := 0
	var ccapped := false
	var card_write_us := 0
	var need := CubeSphere.STRUCT_CARD_INST_MAX * STRUCT_CARD_STRIDE
	if CubeSphere.FP_STRUCT_CARDS and _card_cbuf.size() != need:
		_card_cbuf.resize(need)
	for k in range(ordered.size()):
		var rec: Dictionary = ordered[k]
		var dist := ordered_dist[k] if staged_sort else _structure_dist(rec, cam_abs)
		if dist > CubeSphere.STRUCT_FAR_MAX:
			continue
		if not _cull_emit(rec, cam_abs, dist if staged_sort else NAN):   # staged: reuse the precomputed dist (no recompute)
			continue
		if CubeSphere.FP_STRUCT_CARDS and _card_eligible(rec, dist):
			if cn >= CubeSphere.STRUCT_CARD_INST_MAX:
				ccapped = true
				continue
			var _wt0 := Time.get_ticks_usec()
			_write_card_inst(_card_cbuf, cn, _card_prec[int(rec["root"])])
			card_write_us += int(Time.get_ticks_usec() - _wt0)
			cn += 1
			count += 1
			continue
		if CubeSphere.FP_STRUCT_CARDS and capped:
			continue
		if CubeSphere.FP_STRUCT_BAKE_STAGE and not _has_bake(rec):
			continue
		var bake := _ensure_bake(rec)
		if bake.is_empty() or int(bake["tris"]) == 0:
			continue
		if tris + int(bake["tris"]) > CubeSphere.struct_far_tris_max():
			capped = true
			if CubeSphere.FP_STRUCT_CARDS:
				continue
			break
		verts.append_array(bake["verts"])
		colors.append_array(bake["colors"])
		tris += int(bake["tris"])
		count += 1
	_commit_mesh(verts, colors)
	# S4 wake (§8) — evaluate + clear BEFORE publishing (clears regardless of the CARDS branch, so the flag can't leak).
	var wake_now := _pending_wake_check and _prev_live_cards == 0 and cn >= CubeSphere.STRUCT_WAKE_JUMP
	_pending_wake_check = false
	if CubeSphere.FP_STRUCT_CARDS and _card_mm != null:
		# ATOMIC wake (§8 fix a): on an EMPTY→populated swap, latch the wake + write tier_fade = 0 BEFORE set_buffer, so
		# the freshly-published instances are never shown full-bright for one frame (the pop-then-fade blink). §8 fix c:
		# empty-only — a nonempty→grown set is NOT wake-faded (a global uniform can't smooth additions without blinking
		# the resident set). _apply_shell_visibility (every step) ramps tier_fade up from 0 over STRUCT_WAKE_FADE_S.
		if wake_now:
			_wake_t0 = Time.get_ticks_msec()
			if _card_material != null:
				_card_material.set_shader_parameter("tier_fade", 0.0)
		var _cu0 := Time.get_ticks_usec()
		_card_mm.set_buffer(_card_cbuf)
		_card_mm.visible_instance_count = cn
		_dbg_card_us = card_write_us + int(Time.get_ticks_usec() - _cu0)
		_live_cards = cn
		_card_capped = ccapped
	if CubeSphere.FP_STRUCT_BAKE_STAGE:
		_last_commit_ms = Time.get_ticks_msec()
	_live_structures = count
	_live_tris = tris
	_capped = capped
	if capped:
		print("  FacetFarStructures: STRUCT_FAR_TRIS_MAX (", CubeSphere.STRUCT_FAR_TRIS_MAX, ") hit (nearest-first) — coarsen or evict")

## FP_STRUCT_CARDS (§7.2): is this record a card this pass? True iff its precompute marked it a GEN house (is_card==1)
## AND its camera distance is at/beyond the cube→card split. Off-flag / no prec ⇒ false ⇒ the cube path (byte-off).
func _card_eligible(rec: Dictionary, dist: float) -> bool:
	var prec: Variant = _card_prec.get(int(rec["root"]))
	if prec == null or float((prec as PackedFloat32Array)[0]) < 0.5:
		return false
	return dist >= _card_split_lo(rec)

## §7.3 the split floor. Under WALK_CALM + HANDOFF_HYST the hysteretic band code owns it (code 4 = card sub-band ⇒
## eligible; code 2 = cube sub-band ⇒ never), so the sink assignment can only change WITH a re-commit (the band-fp
## drift), never mid-hysteresis; otherwise the raw STRUCT_CARD_MIN edge (the "cards-all-the-way" A/B arm sets it 0.0).
## CONFIG HAZARD: the retained inner cube band is [r0+CULL_ANNULUS, STRUCT_CARD_MIN). The served config r0=128
## (CURVED_RENDER_RADIUS_BLOCKS) ⇒ annulus top 192 < 320, so the band is non-empty. If a future config makes
## r0+CULL_ANNULUS ≥ STRUCT_CARD_MIN (e.g. the headless FLAT r0=256 ⇒ 320 == 320) the cube sub-band collapses and the
## card sub-band owns everything past the annulus — correct, but the parallax band the design keeps for near houses
## vanishes. Keep STRUCT_CARD_MIN > near_render_radius()+CULL_ANNULUS for the served arm.
func _card_split_lo(rec: Dictionary) -> float:
	if CubeSphere.FP_STRUCT_WALK_CALM and CubeSphere.FP_STRUCT_HANDOFF_HYST:
		var code := int(_band.get(int(rec["root"]), -1))
		if code == 4:
			return 0.0
		if code == 2:
			return INF
	return CubeSphere.STRUCT_CARD_MIN

## FP_STRUCT_CARDS (§5.3): pack ONE card instance from its precomputed params — a radial-up basis (X=e_f unit,
## Y=n̂·H, Z=e_s unit) at the sphere-lifted base centre; custom = (arch, w_s, w_f, fade=1.0). n̂ is the radial at the
## origin (the planet centre IS the origin in the absolute frame the origins live in). NEVER writes vertex COLOR.
func _write_card_inst(buf: PackedFloat32Array, slot: int, prec: PackedFloat32Array) -> void:
	var base := slot * STRUCT_CARD_STRIDE
	var arch := prec[1]
	var w_s := prec[2]
	var w_f := prec[3]
	var hh := prec[4]
	var o := Vector3(prec[5], prec[6], prec[7])
	var e_f := Vector3(prec[8], prec[9], prec[10])
	var n := o.normalized()
	var e_s := n.cross(e_f).normalized()
	var by := n * hh                                # Y column = radial-up × height-in-blocks (risk 3: never world-Y)
	# 3 rows of [e_f | n̂·H | e_s | origin]
	buf[base + 0] = e_f.x; buf[base + 1] = by.x; buf[base + 2] = e_s.x; buf[base + 3] = o.x
	buf[base + 4] = e_f.y; buf[base + 5] = by.y; buf[base + 6] = e_s.y; buf[base + 7] = o.y
	buf[base + 8] = e_f.z; buf[base + 9] = by.z; buf[base + 10] = e_s.z; buf[base + 11] = o.z
	buf[base + 12] = arch; buf[base + 13] = w_s; buf[base + 14] = w_f; buf[base + 15] = 1.0

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

## True iff `rec` has a CURRENT-rev cached bake (i.e. it is, or can instantly be, in the merged mesh).
func _has_bake(rec: Dictionary) -> bool:
	var cached: Variant = _baked.get(int(rec["root"]))
	return cached != null and int((cached as Dictionary)["rev"]) == int(rec["rev"])

## FP_STRUCT_BAKE_STAGE: nearest-first, time-boxed bake drain. Always bakes ≥ STRUCT_BAKE_STAGE_MIN fresh
## records (guaranteed forward progress ⇒ guaranteed convergence), then stops past STRUCT_BAKE_STAGE_MS.
## Sets _bake_pending iff un-baked in-band records remain. Byte-cap {} bakes are skipped without re-arming
## (the shipped NEVER-OOM degrade — they retry next pass at O(1) cost, exactly as today).
func _drain_bakes(ordered: Array, cam_abs: Vector3) -> void:
	_dbg_stage_passes += 1
	var t0 := Time.get_ticks_usec()
	var fresh := 0
	_bake_pending = false
	for rec in ordered:
		var _sd := _structure_dist(rec, cam_abs)
		if _sd > CubeSphere.STRUCT_FAR_MAX:
			continue
		if CubeSphere.FP_STRUCT_CARDS and _card_eligible(rec, _sd):
			continue        # card houses never enter the cube bake drain (they carry no decimated bake)
		if _has_bake(rec):
			continue
		if fresh >= CubeSphere.STRUCT_BAKE_STAGE_MIN \
				and float(Time.get_ticks_usec() - t0) * 0.001 >= CubeSphere.STRUCT_BAKE_STAGE_MS:
			_bake_pending = true
			break
		if _ensure_bake(rec).is_empty():
			continue
		fresh += 1
	_dbg_stage_baked_last = fresh
	_dbg_stage_ms_last = float(Time.get_ticks_usec() - t0) * 0.001

## Telemetry / gate read-back ({} off-flag — confound-free A/B, the shell_band_state() convention).
func bake_stage_state() -> Dictionary:
	if not CubeSphere.FP_STRUCT_BAKE_STAGE:
		return {}
	return {"st_pend": _bake_pending, "st_bk": _dbg_stage_baked_last,
			"st_bms": snappedf(_dbg_stage_ms_last, 0.1), "st_passes": _dbg_stage_passes,
			"st_live": _live_structures}

func _evict_stale_bakes(reg: Array) -> void:
	# FP_STRUCT_CARDS: card houses NEVER bake (they carry no _baked entry), so the shipped _baked-keyed reap below can't
	# drop their _band/_cull state — in a cards-all-the-way arm that grows unboundedly across facets. Under the flag,
	# sweep _band/_cull against the LIVE registry here (independent of _baked). Off ⇒ this block is skipped and the
	# shipped _baked-empty early-return + per-dropped-baked-root erase runs verbatim (byte-identical).
	if CubeSphere.FP_STRUCT_CARDS and (not _cull.is_empty() or not _band.is_empty()):
		var live0 := {}
		for rec in reg:
			live0[int(rec["root"])] = true
		_reap_dict_keys(_cull, live0)
		_reap_dict_keys(_band, live0)
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
		_band.erase(root)   # FP_STRUCT_WALK_CALM: bound the band-code dict to live structures (no-op key off-flag)

## Erase every key of `d` not present in `live` (bound a state dict to the live registry). Used for the card-root reap.
static func _reap_dict_keys(d: Dictionary, live: Dictionary) -> void:
	var drop: Array = []
	for k in d.keys():
		if not live.has(k):
			drop.append(k)
	for k in drop:
		d.erase(k)

# --- telemetry / ledger ---------------------------------------------------------------------------------------------
func rebuild_count() -> int: return _dbg_rebuild_count
func live_structures() -> int: return _live_structures
func live_tris() -> int: return _live_tris
func draw_count() -> int: return 1 + (1 if CubeSphere.FP_STRUCT_CARDS else 0)   # +1 card MMI under the flag (≤ 2 ledger)

# --- FP_STRUCT_CARDS telemetry / gate read-back (all {}/0 off-flag ⇒ confound-free A/B) -------------------------------
func live_cards() -> int: return _live_cards
func card_capped() -> bool: return _card_capped
func card_rebuild_us() -> int: return _dbg_card_us
func sort_us() -> int: return _dbg_sort_us                     # S2 gate read-back (G-ST-SORT)
func card_zone() -> int: return _card_zone                     # S3 gate read-back (G-ST-CALT)
func card_tier_fade() -> float: return _dbg_card_fade          # S3 gate read-back (G-ST-CALT)
func snap_pending() -> bool: return _snap_pending              # S4 gate read-back (G-ST-SNAPSTAGE)
func snap_fill() -> int: return _snap_fill
func snap_restarts() -> int: return _dbg_snap_restarts         # §2 gate read-back (churn coalescing)
func wake_t0() -> int: return _wake_t0                         # §8 gate read-back (wake latch)
func wake_fade() -> float: return _wake_fade()                 # §8 gate read-back (the ramp multiplier)
func debug_set_wake_t0(ms: int) -> void: _wake_t0 = ms         # §8 gate: manipulate the wake anchor to test the ramp without waiting
## The card material's live tier_fade uniform (the ATOMIC value _rebuild_staged writes before publish). -1 if no material.
func card_material_tier_fade() -> float:
	if _card_material == null:
		return -1.0
	return float(_card_material.get_shader_parameter("tier_fade"))
## Confound-free ring telemetry: st_ci (live card instances), st_cq (card cap hit), st_crb_us (card-sink self-time in
## the last _rebuild). {} with the flag off (never merged ⇒ byte-identical telemetry — the bake_stage_state precedent).
func card_state() -> Dictionary:
	if not CubeSphere.FP_STRUCT_CARDS:
		return {}
	var d := {"st_ci": _live_cards, "st_cq": _card_capped, "st_crb_us": _dbg_card_us}
	# S2/S4 (FP_STRUCT_CARD_STAGE): the spike-attribution counters + the staged-fill state.
	if CubeSphere.FP_STRUCT_CARD_STAGE:
		d["st_sort_us"] = _dbg_sort_us
		d["st_mat_us"] = _dbg_mat_us
		d["st_prec_us"] = _dbg_prec_us
		d["st_snap_pend"] = _snap_pending
		d["st_snap_fill"] = _snap_fill
		d["st_snap_restart"] = _dbg_snap_restarts       # §2: catch-up (post-swap re-)fills — target-lag under sustained drift
	# S3 (FP_STRUCT_CARD_ALT_BAND): the card altitude zone + current tier_fade.
	if CubeSphere.FP_STRUCT_CARD_ALT_BAND:
		d["st_czone"] = _card_zone
		d["st_cfade"] = snappedf(_dbg_card_fade, 0.01)
	return d
## Gate read-back: the persistent card instance buffer (slots [0, live_cards) are the last rebuild). Returned as a
## COW reference — the gate READS it (no fork); a production caller holds no second reference so the buffer is reused.
func debug_card_buffer() -> PackedFloat32Array: return _card_cbuf
func card_mmi_visible() -> bool: return _card_mmi != null and _card_mmi.visible
func card_shader_code_str() -> String: return card_shader_code()

## NEVER-OOM ledger (§8): baked models + the merged band mesh vertex buffer. Asserted ≤ STRUCT_BYTES_MAX by the gate.
func total_bytes() -> int:
	var mesh_b := 0
	if _mesh != null and _mesh.get_surface_count() > 0:
		var a := _mesh.surface_get_arrays(0)
		mesh_b = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * (3 * 4 + 4 * 4)
	# FP_STRUCT_CARDS (§10): the fixed card instance buffer + atlas + shared mesh + the per-record prec (bounded by the
	# registry itself). ≈ 0.5 MB + prec, well inside STRUCT_BYTES_MAX, while the _baked cube store SHRINKS (most GEN
	# houses never bake). Zero off-flag (the card node/atlas/prec are never constructed) ⇒ byte-identical ledger.
	var card_b := 0
	if CubeSphere.FP_STRUCT_CARDS:
		card_b = CubeSphere.STRUCT_CARD_INST_MAX * STRUCT_CARD_STRIDE * 4           # instance buffer (128 KB)
		card_b += StructCardKit.COLS * StructCardKit.TILE * StructCardKit.ROWS * StructCardKit.TILE * 4  # atlas RGBA8
		card_b += 12 * (3 * 4 + 2 * 4 + 2 * 4) + 12 * 4                             # 8 verts (pos+uv+uv2) + 12 idx — tiny
		card_b += _card_prec.size() * STRUCT_CARD_PREC * 4                          # per-record precompute
	return _baked_bytes + mesh_b + card_b

# --- FP_STRUCT_SHELL_BAND telemetry / gate hooks ---------------------------------------------------------------------
## Confound-free A/B probe of the zone law. {} with the flag off (never merged → byte-identical telemetry). st_zone:
## 0=S(surface), 1=B(shell band, mesh live off-surface), 2=O(orbit, hidden); st_shell = the zone-B UNLIT material is
## active (⇒ baked BROWN, not black); st_h = the altitude the law saw.
func shell_band_state() -> Dictionary:
	if not CubeSphere.FP_STRUCT_SHELL_BAND:
		return {}
	return {
		"st_zone": _dbg_shell_zone,
		"st_vis": (_mi != null and _mi.visible),
		"st_shell": (_mi != null and _mi.material_override == _shell_material),
		"st_off": _dbg_shell_offsurf,
		"st_h": snappedf(_dbg_shell_h, 0.1),
	}

## Gate hook (G-ST-SHELL): drive the zone-law visibility without a ring (mirror of the trees' debug_apply_visibility).
func debug_apply_shell_visibility(offsurf: bool, h := -1.0) -> int:
	return _apply_shell_visibility(offsurf, h)
func mi_visible() -> bool:
	return _mi != null and _mi.visible
## True iff the zone-B UNLIT vertex-colour material is currently bound (the brown-not-black guarantee).
func mi_material_is_shell() -> bool:
	return _mi != null and _mi.material_override == _shell_material
