class_name CloudLayers
extends Node3D
## COSMOS CLIMATE W2 — the 3-layer semi-cubic cloud mesher (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §4).
## A read-only VIEW of the weather grid (engine rule 2): cloud geometry is a pure function of the grid's
## cloud-water field (via PerVoxelEnvironment.cloud_cover) + the SEED+106 downscale noise. Blocky prisms in
## the terrain's own visual language (unshaded vertex-colour material like the far ring), NOT billboards or
## volumetrics.
##
## NEVER-OOM (§8 rows 4–5): ONE camera-following, world-snapped 64×64 tile lattice per altitude band, meshed
## into a SINGLE reused CPU scratch (allocated once at worst-case capacity — no per-rebuild growth) then
## uploaded to one of exactly 3 ArrayMesh surfaces (3 draw calls total). A HARD vertex cap makes the worst
## case unconditional; greedy row-merge makes full overcast the CHEAPEST mesh, not the worst (G-W2-BYTES).
## Meshes rebuild incrementally: one layer per REBUILD_INTERVAL frames, round-robin, so no frame pays for
## more than one layer. Byte-bounded + draw-bounded are headless-proven; the cloud LOOK is LIVE-ONLY.

const _CLOUD_SALT := 106                ## SEED+106 — the cloud/precip downscale texture (TerrainConfig salt registry)

# --- lattice geometry (§4.1) ---------------------------------------------------
const LAYERS := 3
const TILE_BLOCKS := 32                 ## one cloud tile edge (blocks)
const LATTICE := 64                     ## tiles per side → a 2048-block cloud dome around the camera
const REBUILD_INTERVAL := 16            ## frames between a layer's rebuilds (round-robin, §4.2)
const CAP_VERTS := 24576                ## HARD per-layer vertex cap (§8 row 4) — emission stops here
const STORM_TILE_CAP := 64              ## W4: max cumulonimbus towers per rebuild (§4.2 — bounded extra verts)
const STORM_TOP := 256.0                ## W4: cumulonimbus tower top (< L1); anvil forms near here
const STORM_TINT := Color(0.45, 0.47, 0.54)  ## dark storm-cloud vertex colour

# --- altitude bands (blocks; all below ATMO_TOP = 384) + type params (§4.2) ----
const ALT := [144.0, 216.0, 310.0]      ## L0 cumulus, L1 stratus, L2 cirrus base heights
const THICK := [3.0, 1.0, 0.6]          ## slab thickness per layer
const THRESH := [0.18, 0.30, 0.12]      ## cloud-cover threshold for a tile to be present per layer
const BUMP := [2.5, 0.5, 0.3]           ## chunky top-height variation per layer (the semi-cubic look)
const TINT := [Color(0.95, 0.96, 0.98), Color(0.80, 0.82, 0.86), Color(0.90, 0.92, 0.97)]

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
var _storm_count := 0                   ## cumulonimbus towers emitted this rebuild (≤ STORM_TILE_CAP)

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

func _make_material(_l: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED       # cheap on gl_compat, like the far ring
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.82)
	m.disable_fog = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _process(_delta: float) -> void:
	_frame += 1
	if _frame % REBUILD_INTERVAL != 0:
		return
	rebuild_layer(_cursor)
	_cursor = (_cursor + 1) % LAYERS

# ---------------------------------------------------------------------------------------
# Rebuild ONE layer into the shared scratch, then upload to its ArrayMesh (one surface, one draw). Greedy
# row-merge along +x; a hard vertex cap. World-snapped to the tile grid so a moving player never forces a
# full re-emit (the mesh just shifts with the camera tile origin).
# ---------------------------------------------------------------------------------------
func rebuild_layer(layer: int) -> void:
	var cam := _cam_origin()
	var ox := int(floor(cam.x / float(TILE_BLOCKS))) - LATTICE / 2
	var oz := int(floor(cam.z / float(TILE_BLOCKS))) - LATTICE / 2
	var n := 0                                        # vertices written to the scratch
	var alt := float(ALT[layer])
	var thick := float(THICK[layer])
	var bump := float(BUMP[layer])
	var tint: Color = TINT[layer]
	_storm_count = 0
	for tz in range(LATTICE):
		if n >= CAP_VERTS:
			break
		var gz := oz + tz
		var wz := float(gz * TILE_BLOCKS)
		var run_start := -1
		var tx := 0
		while tx <= LATTICE:
			var present := false
			var cover := 0.0
			if tx < LATTICE:
				var gx := ox + tx
				var wx := float(gx * TILE_BLOCKS)
				cover = _cover_at(wx + 16.0, wz + 16.0, layer)
				present = cover > float(THRESH[layer])
			if present and run_start < 0:
				run_start = tx
			elif not present and run_start >= 0:
				# close a run [run_start, tx) → one box, if it fits the cap.
				if n + 30 <= CAP_VERTS:
					# W4: a convective L0 run becomes a towering cumulonimbus (capped count) — darker + taller.
					var storm := false
					if (CubeSphere.FP_STORMS or _test_storm) and layer == 0 and _storm_count < STORM_TILE_CAP:
						storm = _is_storm_run(ox + run_start, ox + tx, gz, alt)
						if storm:
							_storm_count += 1
					n = _emit_box(n, ox + run_start, ox + tx, gz, alt, thick, bump, tint, layer, storm)
				run_start = -1
			tx += 1
	_emitted[layer] = n
	_upload(layer, n)

## Cover value at world (wx, wz) for `layer`: the grid cloud water (via PerVoxelEnvironment) modulated by
## the SEED+106 downscale noise. The gate hook `_test_force` overrides the grid for synthetic full cover.
func _cover_at(wx: float, wz: float, layer: int) -> float:
	var base := _test_force
	if base < 0.0:
		base = _env.cloud_cover(Vector3(wx, ALT[layer], wz), layer) if _env != null else 0.0
	# noise MODULATES the grid base (ragged sub-cell edges), it never creates cloud from nothing — a clear
	# grid cell (base 0) stays clear, so clouds only cost geometry where the weather actually has cloud water.
	var noise := _noise.get_noise_3d(wx * 0.004, wz * 0.004, float(layer) * 13.0)
	return clampf(base * (1.0 + noise * 0.6), 0.0, 1.0)

## True iff the L0 run [x0,x1) at row tz is convective (a thunderstorm column) — the emergent grid flag
## (or the gate's forced-storm hook). Sampled at the run centre.
func _is_storm_run(x0: int, x1: int, tz: int, alt: float) -> bool:
	if _test_storm:
		return true
	if _env == null:
		return false
	var midx := (x0 + x1) / 2
	return _env.is_convective(Vector3(float(midx * TILE_BLOCKS) + 16.0, alt, float(tz * TILE_BLOCKS) + 16.0))

## Emit one merged box spanning tile columns [x0, x1) at row tz, at the layer altitude. Non-indexed
## triangles (top + 4 sides; the bottom is unseen from below the deck and skipped). A convective run
## extrudes to a towering cumulonimbus (dark, up to STORM_TOP) — same mesh, bounded extra height, no extra
## verts. Returns the new count.
func _emit_box(n: int, x0: int, x1: int, tz: int, alt: float, thick: float, bump: float, tint: Color, layer: int, storm := false) -> int:
	var wx0 := float(x0 * TILE_BLOCKS)
	var wx1 := float(x1 * TILE_BLOCKS)
	var wz0 := float(tz * TILE_BLOCKS)
	var wz1 := float((tz + 1) * TILE_BLOCKS)
	var h := STORM_TOP if storm else _quantize_top(alt, thick, bump, x0, tz, layer)
	var b := alt
	var c := STORM_TINT if storm else tint
	# top quad (two tris)
	n = _quad(n, Vector3(wx0, h, wz0), Vector3(wx1, h, wz0), Vector3(wx1, h, wz1), Vector3(wx0, h, wz1), c)
	# four sides (darker underside tint for depth)
	var cs := c.darkened(0.15)
	n = _quad(n, Vector3(wx0, b, wz0), Vector3(wx1, b, wz0), Vector3(wx1, h, wz0), Vector3(wx0, h, wz0), cs)
	n = _quad(n, Vector3(wx1, b, wz1), Vector3(wx0, b, wz1), Vector3(wx0, h, wz1), Vector3(wx1, h, wz1), cs)
	n = _quad(n, Vector3(wx0, b, wz1), Vector3(wx0, b, wz0), Vector3(wx0, h, wz0), Vector3(wx0, h, wz1), cs)
	n = _quad(n, Vector3(wx1, b, wz0), Vector3(wx1, b, wz1), Vector3(wx1, h, wz1), Vector3(wx1, h, wz0), cs)
	return n

## Top height (blocks) of a box: the layer altitude + a chunky, quantized noise bump (the semi-cubic look).
func _quantize_top(alt: float, thick: float, bump: float, x0: int, tz: int, layer: int) -> float:
	var nz := _noise.get_noise_3d(float(x0) * 0.6, float(tz) * 0.6, float(layer) * 7.0)
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
	return global_transform.origin

# ---------------------------------------------------------------------------------------
# Gate / inspection support (headless verify_climate). Not on the live hot path.
# ---------------------------------------------------------------------------------------
func debug_set_camera(pos: Vector3) -> void:
	global_transform = Transform3D(Basis.IDENTITY, pos)

func debug_force_cover(v: float) -> void:
	_test_force = v

func debug_force_storm(on: bool) -> void:
	_test_storm = on

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
