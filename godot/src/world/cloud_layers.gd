class_name CloudLayers
extends Node3D
## COSMOS CLIMATE W2 — the 3-layer semi-cubic cloud mesher (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §4).
## A read-only VIEW of the weather grid (engine rule 2): cloud geometry is a pure function of the grid's
## cloud-water field (via PerVoxelEnvironment.cloud_cover_dir) + the SEED+106 downscale noise. Blocky prisms in
## the terrain's own visual language (unshaded vertex-colour material like the far ring), NOT billboards or
## volumetrics.
##
## LOCAL-SURFACE FRAME (cloudfix 2026-07-19): the deploy renders the planet in the ORBITAL_SKY fixed frame —
## the planet centre is the scene ORIGIN and the local surface up at the camera is `cam.normalized()` (the exact
## convention CosmosSky uses for the Sun elevation / day-night ramp; the clouds share the player camera provider,
## so they MUST share the frame). Clouds are therefore a CURVED SHELL: each tile sits on the sphere of radius
## R_BLOCKS+altitude and its face normal IS the radial direction there, so the sheets lie horizontal OVER the
## terrain at every point of the dome instead of being an axis-aligned +Y slab (the "clouds protrude into space /
## 90° wrong" live bug — the old mesher built boxes in the global-Y frame, correct only at the north pole). The
## weather grid is a GLOBAL field over sphere DIRECTIONS, so cover is sampled by each tile's radial direction
## (works across facet boundaries, no window/lattice fold needed).
##
## ATMOSPHERE-GATED: clouds exist ONLY while the camera is within the atmosphere band (radial altitude ≤
## ATMO_TOP). In orbit/space the meshes are cleared — no clouds hang at orbital altitude ("rains in orbit" bug).
##
## NEVER-OOM (§8 rows 4–5): ONE camera-following, camera-snapped LATTICE×LATTICE tile dome per altitude band,
## meshed into a SINGLE reused CPU scratch (allocated once at worst-case capacity — no per-rebuild growth) then
## uploaded to one of exactly 3 ArrayMesh surfaces (3 draw calls total). A HARD vertex cap makes the worst
## case unconditional; greedy row-merge makes full overcast the CHEAPEST mesh, not the worst (G-W2-BYTES).
## Meshes rebuild incrementally: one layer per REBUILD_INTERVAL frames, round-robin, so no frame pays for
## more than one layer. Byte-bounded + draw-bounded + frame-orientation + altitude-gating are headless-proven;
## the cloud LOOK is LIVE-ONLY.

const _CLOUD_SALT := 106                ## SEED+106 — the cloud/precip downscale texture (TerrainConfig salt registry)

# --- lattice geometry (§4.1) ---------------------------------------------------
const LAYERS := 3
const TILE_BLOCKS := 32                 ## one cloud tile edge (blocks)
const LATTICE := 64                     ## tiles per side → a 2048-block cloud dome around the camera
const REBUILD_INTERVAL := 16            ## frames between a layer's rebuilds (round-robin, §4.2)
const CAP_VERTS := 24576                ## HARD per-layer vertex cap (§8 row 4) — emission stops here
const BOX_VERTS := 36                   ## verts one puffy box emits (lumpy top quad 6 + underside 6 + 4 sides 24)
const STORM_TILE_CAP := 64              ## W4: max cumulonimbus towers per rebuild (§4.2 — bounded extra verts)
const STORM_TOP := 256.0                ## W4: cumulonimbus tower top ALTITUDE (< ATMO_TOP); anvil forms near here
const STORM_TINT := Color(0.45, 0.47, 0.54)  ## dark storm-cloud vertex colour

# --- altitude bands (blocks; all below ATMO_TOP = 384) + type params (§4.2) ----
const ALT := [144.0, 216.0, 310.0]      ## L0 cumulus, L1 stratus, L2 cirrus base ALTITUDES (radial, above surface)
# --- VOLUME (clouds2 2026-07-20) ------------------------------------------------
# The pilot saw the clouds as flat PAPER: THICK was ~3 blocks against 32-block tiles, so the boxes read as
# sheets and merged runs got one flat lid. Each box is now a genuine puffy 3-D MASS — a closed prism with
# real vertical extent (THICK), a raised centre CROWN (the billow), per-corner top LUMPs (the chunky
# semi-cubic relief), and a bulged UNDERside — differentiated per type: cumulus fat & billowing, stratus
# flatter, cirrus thin & wispy. All tops stay < ATMO_TOP (384): L0 144+64+18≈226, L1 216+16, L2 310+7.
# The greedy row-merge and the hard vertex cap are untouched (BOX_VERTS is fixed at 42), so full overcast is
# still the cheapest mesh (≤ a few long runs) and NEVER-OOM still binds.
const THICK := [64.0, 16.0, 7.0]        ## slab body thickness per layer (base→top), blocks — the vertical extent
const TOPVAR := [22.0, 5.0, 2.0]        ## per-BOX top-height step (chunky stepped cloudscape between boxes)
const LUMP := [12.0, 3.0, 1.0]          ## per-CORNER top-height lump amplitude — the puffy relief on the lid
const UNDER := [12.0, 2.5, 0.5]         ## per-CORNER UNDERside bulge (base dips below the deck) — body from below/side
const THRESH := [0.18, 0.30, 0.12]      ## cloud-cover threshold for a tile to be present per layer
const BUMP := [2.5, 0.5, 0.3]           ## legacy per-box bump amplitude (still used by _quantize_top for the storm path)
const TINT := [Color(0.95, 0.96, 0.98), Color(0.80, 0.82, 0.86), Color(0.90, 0.92, 0.97)]

const NOISE_FREQ := 0.004               ## downscale-noise frequency in BLOCKS (sampled along the tangent world scale)

var _env: PerVoxelEnvironment = null
var _cam_provider: Node = null
var _noise: FastNoiseLite

var _meshes: Array[MeshInstance3D] = []
var _arr_meshes: Array[ArrayMesh] = []
# ONE reused CPU scratch (only one layer rebuilds per frame) — allocated once at the vertex cap.
var _sv := PackedVector3Array()
var _sc := PackedColorArray()

var _frame := 0
var _cursor := 0                        ## next layer to rebuild (round-robin)
var _emitted := [0, 0, 0]               ## last emitted vertex count per layer (gate/telemetry)
var _test_force := -1.0                 ## gate hook: ≥0 overrides cloud_cover with this value
var _test_storm := false                ## gate hook: force every L0 run convective (storm-cap test)
var _test_ignore_altitude := false      ## gate hook: build regardless of camera altitude (byte/draw/storm gates)
var _debug_cam := Vector3.ZERO          ## gate hook: an explicit camera scene position (headless has no provider)
var _has_debug_cam := false
var _storm_count := 0                   ## cumulonimbus towers emitted this rebuild (≤ STORM_TILE_CAP)

# --- per-rebuild local-surface frame (planet centre = scene origin; up = cam.normalized()); members so the
#     emit path allocates nothing (NEVER-OOM). Rebuilt at the head of every rebuild_layer.
var _up := Vector3.UP
var _t1 := Vector3.RIGHT
var _t2 := Vector3.BACK
var _R := FacetAtlas.R_BLOCKS

func setup(env: PerVoxelEnvironment, cam_provider: Node = null) -> void:
	_env = env
	_cam_provider = cam_provider
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = TerrainConfig.SEED + _CLOUD_SALT
	_noise.frequency = 1.0                            # we pre-scale coordinates ourselves
	_noise.get_noise_2d(0.0, 0.0)                     # warm-up
	_sv.resize(CAP_VERTS)
	_sc.resize(CAP_VERTS)
	for l in range(LAYERS):
		var mi := MeshInstance3D.new()
		mi.name = "CloudLayer%d" % l
		var am := ArrayMesh.new()
		mi.mesh = am
		mi.material_override = _make_material(l)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 4096.0                 # the mesh follows the camera; never frustum-cull it wrongly
		add_child(mi)
		_meshes.append(mi)
		_arr_meshes.append(am)

# COSMOS ATMO2 B3 (docs/COSMOS-ATMO2-DESIGN.md §2.3/§3.3 C-NEAR): the near-field daylight TWIN of the cloud
# material. Keeps the shipped unshaded vertex-colour × (white, α 0.82) look EXACTLY and multiplies the absolute
# day/night shade(μ), μ = normalize(world_pos)·ŝ (planet centre = scene origin, the same fixed frame the tiles
# are built in). shade=1 at noon ⇒ ALBEDO byte-equal to the StandardMaterial output; at night the clouds read
# moonlit/dark like the ground (the moonshine floor via near_shade) instead of staying bright white — the whole
# point. Same shade kernel as the ground twins (CosmosSky.near_shade). fog_disabled matches disable_fog=true.
# StandardMaterial fallback = flag off (byte-identical + the P3 gl_compat compile-failure backstop).
const _NEAR_DAYLIGHT_CLOUD_SHADER := "shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 0.82);
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float night_floor = 0.10;
uniform float term_mu = 0.12;
uniform float moonshine = 0.0;
varying vec3 v_wp;
varying vec4 v_col;
void vertex() { v_col = COLOR; v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float _day(float mu) { return smoothstep(-term_mu, term_mu, mu); }
void fragment() {
	vec3 nrm = normalize(v_wp);
	float mu = dot(nrm, normalize(sun_dir));
	float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);
	vec4 base = albedo_color * v_col;
	ALBEDO = base.rgb * shade;
	ALPHA = base.a;
}
"

func _make_material(_l: int) -> Material:
	# COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): the near-field daylight ShaderMaterial twin (keeps the vertex-colour ×
	# white-α look EXACTLY, darkens the clouds at night like the ground). Off ⇒ the shipped StandardMaterial verbatim.
	if CubeSphere.FP_NEAR_DAYLIGHT:
		var sh := Shader.new()
		sh.code = _NEAR_DAYLIGHT_CLOUD_SHADER
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.set_shader_parameter("albedo_color", Color(1, 1, 1, 0.82))
		sm.set_shader_parameter("night_floor", CosmosSky.NEAR_NIGHT_FLOOR)
		sm.set_shader_parameter("term_mu", CosmosSky.TERMINATOR_MU)
		sm.set_shader_parameter("sun_dir", Vector3(1.0, 0.0, 0.0))
		return sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED       # cheap on gl_compat, like the far ring
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.82)
	m.disable_fog = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

## COSMOS ATMO2 B3 (FP_NEAR_DAYLIGHT): feed the current Sun direction into the cloud daylight twins each frame
## (forwarded from CosmosSky via main.gd). No-op unless the flag is on and the layer materials are the twin ⇒
## flag-off is byte-identical (never wired; the StandardMaterial path is untouched).
func set_near_daylight_sun_dir(sun_dir: Vector3) -> void:
	if not CubeSphere.FP_NEAR_DAYLIGHT:
		return
	for mi in _meshes:
		var mat := mi.material_override
		if mat is ShaderMaterial:
			(mat as ShaderMaterial).set_shader_parameter("sun_dir", sun_dir)

func _process(_delta: float) -> void:
	_frame += 1
	if _frame % REBUILD_INTERVAL != 0:
		return
	rebuild_layer(_cursor)
	_cursor = (_cursor + 1) % LAYERS

## Radial altitude (blocks above the voxel surface) of the camera — the same signal CosmosSky ramps the sky on.
func _radial_altitude(cam: Vector3) -> float:
	return cam.length() - _R

## True while the camera sits inside the atmosphere band (clouds/precip exist only here — never in orbit/space).
func in_atmosphere(cam: Vector3) -> bool:
	if _test_ignore_altitude:
		return true
	return _radial_altitude(cam) <= CubeSphere.ATMO_TOP

## Build the local-surface tangent frame at the camera: up = radial (planet centre = scene origin), t1/t2 an
## orthonormal tangent pair. Stored in members so the per-tile emit path never allocates.
func _build_frame(cam: Vector3) -> void:
	_R = FacetAtlas.R_BLOCKS
	_up = cam.normalized() if cam.length() > 1.0 else Vector3.UP
	var ref := Vector3(0, 1, 0)
	if absf(_up.dot(ref)) > 0.99:
		ref = Vector3(1, 0, 0)
	_t1 = _up.cross(ref).normalized()
	_t2 = _up.cross(_t1).normalized()

## Radial direction (unit) at tangent offset (a, b) from the camera ground point — normalize the tangent-plane
## surface point (up·R + a·t1 + b·t2). This IS the local surface up at that tile, so a face built normal to it
## lies horizontal over the terrain there.
func _tile_dir(a: float, b: float) -> Vector3:
	return (_up * _R + _t1 * a + _t2 * b).normalized()

# ---------------------------------------------------------------------------------------
# Rebuild ONE layer into the shared scratch, then upload to its ArrayMesh (one surface, one draw). Greedy
# row-merge along +a (tangent x); a hard vertex cap. Camera-centred tangent dome so a moving player never
# forces a full re-emit (the dome shifts with the camera; the cloud PATTERN is direction-sampled so it stays
# put on the sphere). Cleared entirely above the atmosphere (no clouds in orbit).
# ---------------------------------------------------------------------------------------
func rebuild_layer(layer: int) -> void:
	var cam := _cam_origin()
	if not in_atmosphere(cam):
		_emitted[layer] = 0
		_upload(layer, 0)                             # clear: no clouds in space
		return
	_build_frame(cam)
	var half := LATTICE / 2
	var n := 0                                         # vertices written to the scratch
	var tint: Color = TINT[layer]
	_storm_count = 0
	for tz in range(LATTICE):
		if n >= CAP_VERTS:
			break
		var b0 := float(tz - half) * float(TILE_BLOCKS)
		var run_start := -1
		var tx := 0
		while tx <= LATTICE:
			var present := false
			if tx < LATTICE:
				var a_c := (float(tx - half) + 0.5) * float(TILE_BLOCKS)
				var b_c := b0 + 0.5 * float(TILE_BLOCKS)
				var cover := _cover_at(_tile_dir(a_c, b_c), layer)
				present = cover > float(THRESH[layer])
			if present and run_start < 0:
				run_start = tx
			elif not present and run_start >= 0:
				# close a run [run_start, tx) → one box, if it fits the cap.
				if n + BOX_VERTS <= CAP_VERTS:
					# W4: a convective L0 run becomes a towering cumulonimbus (capped count) — darker + taller.
					var storm := false
					if (CubeSphere.FP_STORMS or _test_storm) and layer == 0 and _storm_count < STORM_TILE_CAP:
						storm = _is_storm_run(run_start, tx, tz, half)
						if storm:
							_storm_count += 1
					n = _emit_box(n, run_start - half, tx - half, tz - half, layer, tint, storm)
				run_start = -1
			tx += 1
	_emitted[layer] = n
	_upload(layer, n)

## Cover value for radial direction `dir` and `layer`: the grid cloud water (via PerVoxelEnvironment) modulated
## by the SEED+106 downscale noise. The gate hook `_test_force` overrides the grid for synthetic full cover.
func _cover_at(dir: Vector3, layer: int) -> float:
	var base := _test_force
	if base < 0.0:
		base = _env.cloud_cover_dir(dir, layer) if _env != null else 0.0
	# noise MODULATES the grid base (ragged sub-cell edges), it never creates cloud from nothing — a clear
	# grid cell (base 0) stays clear, so clouds only cost geometry where the weather actually has cloud water.
	# Sampled along the world tangent scale (dir·R·freq) so the ragged edges are LOCKED to the sphere, not the
	# camera-following tile grid.
	var noise := _noise.get_noise_3dv(dir * (_R * NOISE_FREQ) + Vector3(0.0, 0.0, float(layer) * 13.0))
	return clampf(base * (1.0 + noise * 0.6), 0.0, 1.0)

## True iff the L0 run [c0,c1) at row tz is convective (a thunderstorm column) — the emergent grid flag (or the
## gate's forced-storm hook). Sampled at the run centre's radial direction. (c0,c1,tz are absolute tile indices.)
func _is_storm_run(c0: int, c1: int, tz: int, half: int) -> bool:
	if _test_storm:
		return true
	if _env == null:
		return false
	var a_c := (float((c0 + c1) / 2 - half) + 0.5) * float(TILE_BLOCKS)
	var b_c := (float(tz - half) + 0.5) * float(TILE_BLOCKS)
	return _env.is_convective_dir(_tile_dir(a_c, b_c))

## Emit one merged box spanning tile columns [cx0, cx1) at row cz (all CAMERA-CENTRED tile indices: 0 == the
## camera column) at the layer altitude, ON THE SHELL, as a CLOSED PUFFY PRISM (clouds2 volume). Each corner
## is placed radially (dir·radius, planet centre = scene origin) so the box lies curved over the terrain and
## its faces are normal to the radial. Geometry (36 verts): a per-corner LUMPY top lid (chunky puffy relief),
## a per-corner bulged UNDERside (real body when seen from below/side/orbit), and 4 side walls whose height is
## the layer THICKness — no longer a paper sheet. The lid's per-box height also steps (TOPVAR) so a run of
## boxes reads as a chunky cloudscape, not one flat plane. A convective run extrudes to a towering
## cumulonimbus (dark, top at STORM_TOP) — same 36-vert mesh, bounded extra height, no extra verts. The lid is
## emitted FIRST so the frame gate reads a top face (its normal stays ≈ radial: the per-corner lumps are small
## against the tile span, and merged runs are wide, so the lid is near-horizontal over the terrain).
func _emit_box(n: int, cx0: int, cx1: int, cz: int, layer: int, tint: Color, storm := false) -> int:
	var alt := float(ALT[layer])
	var thick := float(THICK[layer])
	var a0 := float(cx0) * float(TILE_BLOCKS)
	var a1 := float(cx1) * float(TILE_BLOCKS)
	var b0 := float(cz) * float(TILE_BLOCKS)
	var b1 := float(cz + 1) * float(TILE_BLOCKS)
	# per-BOX top base altitude: layer body height + a chunky stepped bump (or the tall storm top).
	var top_base := STORM_TOP if storm else alt + thick + _step(float(cx0), float(cz), layer, float(TOPVAR[layer]))
	var lump := 0.0 if storm else float(LUMP[layer])
	var under := float(UNDER[layer])
	var c := STORM_TINT if storm else tint
	var cs := c.darkened(0.15)
	# corner radial directions (shared by base + top)
	var d00 := _tile_dir(a0, b0)
	var d10 := _tile_dir(a1, b0)
	var d11 := _tile_dir(a1, b1)
	var d01 := _tile_dir(a0, b1)
	# per-corner top-lid radii (chunky puffy relief) and per-corner underside radii (base dips below the deck).
	var rt00 := _R + top_base + _lumpv(a0, b0, layer, lump)
	var rt10 := _R + top_base + _lumpv(a1, b0, layer, lump)
	var rt11 := _R + top_base + _lumpv(a1, b1, layer, lump)
	var rt01 := _R + top_base + _lumpv(a0, b1, layer, lump)
	var rb00 := _R + alt - _lumpv(a0, b0, layer, under)
	var rb10 := _R + alt - _lumpv(a1, b0, layer, under)
	var rb11 := _R + alt - _lumpv(a1, b1, layer, under)
	var rb01 := _R + alt - _lumpv(a0, b1, layer, under)
	# TOP lid (two tris) — emitted FIRST; normal ≈ radial (horizontal over the terrain).
	n = _quad(n, d00 * rt00, d10 * rt10, d11 * rt11, d01 * rt01, c)
	# BOTTOM (underside) — reversed winding so its normal faces DOWN (−radial); real body from below.
	n = _quad(n, d00 * rb00, d01 * rb01, d11 * rb11, d10 * rb10, cs)
	# four side walls (darker for depth): base → top along each edge — the vertical extent (thickness).
	n = _quad(n, d00 * rb00, d10 * rb10, d10 * rt10, d00 * rt00, cs)
	n = _quad(n, d10 * rb10, d11 * rb11, d11 * rt11, d10 * rt10, cs)
	n = _quad(n, d11 * rb11, d01 * rb01, d01 * rt01, d11 * rt11, cs)
	n = _quad(n, d01 * rb01, d00 * rb00, d00 * rt00, d01 * rt01, cs)
	return n

## A chunky per-corner height lump (blocks, ≥0) keyed on the corner's tangent-plane position (a, b) in blocks
## — quantized to half-blocks for the semi-cubic look. Amplitude 0 ⇒ 0 (storms flatten the lid to the tower).
func _lumpv(a: float, b: float, layer: int, amp: float) -> float:
	if amp <= 0.0:
		return 0.0
	var nz := _noise.get_noise_3d(a * 0.03, b * 0.03, float(layer) * 7.0)
	return round(maxf(0.0, nz) * amp * 2.0) * 0.5

## A chunky per-BOX height step (blocks, ≥0) keyed on the camera-centred tile indices (stable within a rebuild).
func _step(cx0: float, cz: float, layer: int, amp: float) -> float:
	var nz := _noise.get_noise_3d(cx0 * 0.6, cz * 0.6, float(layer) * 7.0 + 3.0)
	return round(maxf(0.0, nz) * amp * 2.0) * 0.5

## Top ALTITUDE (blocks above surface) of a box (storm/legacy path): layer altitude + a chunky quantized bump.
func _quantize_top(alt: float, thick: float, bump: float, cx0: int, cz: int, layer: int) -> float:
	var nz := _noise.get_noise_3d(float(cx0) * 0.6, float(cz) * 0.6, float(layer) * 7.0)
	var extra: float = round(maxf(0.0, nz) * bump * 2.0) * 0.5     # quantized to half-blocks
	return alt + thick + extra

## Append a quad (two CCW triangles, 6 verts) to the scratch with a flat colour. Bounds already checked.
func _quad(n: int, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> int:
	_sv[n] = a; _sc[n] = col; n += 1
	_sv[n] = b; _sc[n] = col; n += 1
	_sv[n] = c; _sc[n] = col; n += 1
	_sv[n] = a; _sc[n] = col; n += 1
	_sv[n] = c; _sc[n] = col; n += 1
	_sv[n] = d; _sc[n] = col; n += 1
	return n

## Upload the first `n` scratch vertices to layer's ArrayMesh (clear_surfaces + one add_surface — the far-
## ring rebuild pattern; no per-rebuild allocation beyond the slice views).
func _upload(layer: int, n: int) -> void:
	var am := _arr_meshes[layer]
	am.clear_surfaces()
	if n <= 0:
		return
	var surf := []
	surf.resize(Mesh.ARRAY_MAX)
	surf[Mesh.ARRAY_VERTEX] = _sv.slice(0, n)
	surf[Mesh.ARRAY_COLOR] = _sc.slice(0, n)
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)
	am.surface_set_material(0, _meshes[layer].material_override)

func _cam_origin() -> Vector3:
	if _cam_provider != null and _cam_provider.has_method("camera_global_transform"):
		return (_cam_provider.camera_global_transform() as Transform3D).origin
	if _has_debug_cam:
		return _debug_cam
	return global_transform.origin

# ---------------------------------------------------------------------------------------
# Gate / inspection support (headless verify_weather). Not on the live hot path.
# ---------------------------------------------------------------------------------------
func debug_set_camera(pos: Vector3) -> void:
	_debug_cam = pos
	_has_debug_cam = true
	global_transform = Transform3D(Basis.IDENTITY, pos)

func debug_force_cover(v: float) -> void:
	_test_force = v

func debug_force_storm(on: bool) -> void:
	_test_storm = on

## Gate hook: build regardless of camera radial altitude (so the byte/draw/storm gates can place the camera at
## arbitrary probe positions without the atmosphere gate zeroing the mesh). The live path never sets this.
func debug_ignore_altitude(on: bool) -> void:
	_test_ignore_altitude = on

## Gate hook: the local-surface up used at the current camera (radial, planet centre = scene origin).
func debug_up() -> Vector3:
	_build_frame(_cam_origin())
	return _up

## Gate hook: the shell-face normal at tangent offset (a, b) from the camera — the radial direction there. For
## the central tile (0,0) this equals the camera up; a face built with this normal lies horizontal over terrain.
func debug_shell_normal(a: float, b: float) -> Vector3:
	_build_frame(_cam_origin())
	return _tile_dir(a, b)

## Gate hook: the normal of the FIRST emitted top quad (verts 0..2), or ZERO if nothing emitted. Proves the
## live-emitted geometry is oriented to the radial, not the global +Y.
func debug_first_top_normal() -> Vector3:
	if _emitted_total() < 3:
		return Vector3.ZERO
	return (_sv[1] - _sv[0]).cross(_sv[2] - _sv[0]).normalized()

func _emitted_total() -> int:
	var t := 0
	for e in _emitted:
		t += int(e)
	return t

## Gate hook (G-CLOUD-VOLUME): radial min/max (blocks) over the first `count` scratch verts — the geometry of
## the LAST rebuilt layer. max−min is that layer's vertical extent (thickness), which must be non-zero (the
## boxes are prisms with body, not paper sheets). Call rebuild_layer(L) then pass emitted_verts(L).
func debug_scratch_radial_extent(count: int) -> Vector2:
	if count <= 0:
		return Vector2.ZERO
	var mn := INF
	var mx := 0.0
	for i in range(count):
		var r := _sv[i].length()
		mn = minf(mn, r)
		mx = maxf(mx, r)
	return Vector2(mn, mx)

## Gate hook (G-CLOUD-VOLUME): min and max |triangle-normal · up| over every emitted tri in the first `count`
## scratch verts. A closed prism yields BOTH near-radial faces (top/bottom, |·up|≈1) AND near-tangential side
## walls (|·up|≈0), so min < 0.5 proves the normals are NOT all radial-coplanar — i.e. the mesh has volume.
func debug_scratch_normal_updot(count: int, up: Vector3) -> Vector2:
	var mn := 1.0
	var mx := 0.0
	var i := 0
	while i + 3 <= count:
		var nrm := (_sv[i + 1] - _sv[i]).cross(_sv[i + 2] - _sv[i])
		if nrm.length() > 1.0e-6:
			var d := absf(nrm.normalized().dot(up))
			mn = minf(mn, d)
			mx = maxf(mx, d)
		i += 3
	return Vector2(mn, mx)

func storm_tower_count() -> int:
	return _storm_count

func rebuild_all_now() -> void:
	for l in range(LAYERS):
		rebuild_layer(l)

func emitted_verts(layer: int) -> int:
	return _emitted[layer]

func draw_count() -> int:
	var d := 0
	for am in _arr_meshes:
		d += am.get_surface_count()
	return d

func byte_report() -> Dictionary:
	var scratch := _sv.size() * 12 + _sc.size() * 16
	return {"scratch": scratch, "cap_verts": CAP_VERTS, "layers": LAYERS}
